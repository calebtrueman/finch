/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Code signing queries: SecStaticCode, SecCode and SecTask.
 *
 * Finch reads code signatures itself, from the Mach-O file: the embedded
 * signature superblob, its code directories (cdhash, identifier, flags, team),
 * requirements, entitlements and CMS signature. Validation is real: every
 * code page hash, the special slots (Info.plist, requirements, resources,
 * entitlements), a bundle's sealed resources, and the CMS signature over the
 * code directory. What Finch can't do is trust: it has no Apple root
 * certificates, so "anchor apple" and "anchor trusted" are never satisfied,
 * and ad-hoc code (which is all Finch builds) is valid but anchored nowhere,
 * as on macOS. Dynamic validity (SecCodeCheckValidity) checks the running
 * code's file on disk; the kernel's own state is reported in kSecCodeInfoStatus.
 */
#include "SecCodeInternal.h"
#include <openssl/cms.h>
#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <bsm/libbsm.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_STATUS 0
#define CS_VALID 0x00000001

enum {
	kSlotCodeDirectory = 0, kSlotInfo = 1, kSlotRequirements = 2, kSlotResources = 3,
	kSlotEntitlements = 5, kSlotEntitlementsDER = 7, kSlotAlternateCD = 0x1000, kSlotCMS = 0x10000,
};
#define kSuperBlobMagic 0xfade0cc0u
#define kCodeDirectoryMagic 0xfade0c02u
#define kEntitlementsMagic 0xfade7171u

static uint32_t be32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static bool isType(CFTypeRef o, CFTypeID t)
{
	return o && CFGetTypeID(o) == t;
}

/* ---- Static code ---- */

typedef struct {
	CFRuntimeBase base;
	CFURLRef path;            /* as created: a bundle or a file */
	CFURLRef executable;      /* the main executable */
	CFDictionaryRef infoPlist;
	CFURLRef bundle;          /* NULL for a lone file */
	bool appBundle;
	CFDataRef file;           /* the executable's bytes */
	CFStringRef format;
	/* the chosen slice */
	size_t sliceOffset, sliceSize;
	bool macho;
	/* signature */
	bool isSigned;
	const uint8_t *sig;
	size_t sigLength;
	const uint8_t *cd;        /* best code directory */
	size_t cdLength;
	CFMutableArrayRef cdhashes;
	CFMutableArrayRef digestAlgorithms;
	CFDataRef unique;
	uint8_t hashType;
	uint32_t flags, platform;
	CFStringRef identifier, teamID;
	const uint8_t *requirements;
	size_t requirementsLength;
	CFDataRef entitlementsBlob;
	CFDictionaryRef entitlements;
	CFDataRef cms;
	CFArrayRef certificates;
} StaticCode;

static void staticFree(CFTypeRef o)
{
	StaticCode *s = (StaticCode *)o;
	CFTypeRef refs[] = {s->path, s->executable, s->infoPlist, s->bundle, s->file, s->format, s->cdhashes,
	    s->digestAlgorithms, s->unique, s->identifier, s->teamID, s->entitlementsBlob, s->entitlements, s->cms,
	    s->certificates};
	for (size_t i = 0; i < sizeof(refs) / sizeof(*refs); i++)
		if (refs[i])
			CFRelease(refs[i]);
}
static Boolean staticEqual(CFTypeRef a, CFTypeRef b)
{
	StaticCode *x = (StaticCode *)a, *y = (StaticCode *)b;
	return CFEqual(x->executable, y->executable) && x->sliceOffset == y->sliceOffset;
}
static CFHashCode staticHash(CFTypeRef a)
{
	return CFHash(((StaticCode *)a)->executable);
}
SEC_DEFINE_TYPE(SecStaticCodeGetTypeID, "SecStaticCode", staticFree, staticEqual, staticHash)

static CFDataRef digest(const EVP_MD *md, const void *p, size_t n)
{
	unsigned char out[EVP_MAX_MD_SIZE];
	unsigned int len = 0;
	if (!EVP_Digest(p, n, out, &len, md, NULL))
		return NULL;
	return CFDataCreate(NULL, out, len);
}

CFDataRef _SecCodeCopySHA1(CFDataRef data)
{
	return digest(EVP_sha1(), CFDataGetBytePtr(data), CFDataGetLength(data));
}

static const EVP_MD *hashFor(uint8_t type, size_t *size)
{
	switch (type) {
	case 1: *size = 20; return EVP_sha1();
	case 2: *size = 32; return EVP_sha256();
	case 3: *size = 20; return EVP_sha256();   /* SHA-256 truncated to 20 bytes */
	case 4: *size = 48; return EVP_sha384();
	default: *size = 0; return NULL;
	}
}

/* Apple's preference among code directory hash types. */
static int hashRank(uint8_t type)
{
	switch (type) {
	case 2: return 5;
	case 3: return 4;
	case 4: return 3;
	case 1: return 1;
	default: return 0;
	}
}

static const char *archName(cpu_type_t type, cpu_subtype_t sub)
{
	sub &= ~CPU_SUBTYPE_MASK;
	switch (type) {
	case CPU_TYPE_ARM64: return sub == CPU_SUBTYPE_ARM64E ? "arm64e" : "arm64";
	case CPU_TYPE_X86_64: return sub == CPU_SUBTYPE_X86_64_H ? "x86_64h" : "x86_64";
	case CPU_TYPE_ARM64_32: return "arm64_32";
	case CPU_TYPE_ARM: return "arm";
	case CPU_TYPE_I386: return "i386";
	default: return "unknown";
	}
}

/* Picks the slice this machine would run: arm64e, then arm64, then the first. */
static bool chooseSlice(StaticCode *s, CFMutableStringRef format)
{
	const uint8_t *p = CFDataGetBytePtr(s->file);
	size_t n = CFDataGetLength(s->file);
	if (n < 4)
		return false;
	uint32_t magic = *(const uint32_t *)p;
	if (magic == MH_MAGIC_64 || magic == MH_MAGIC) {
		const struct mach_header *h = (const void *)p;
		s->sliceOffset = 0;
		s->sliceSize = n;
		CFStringAppendFormat(format, NULL, CFSTR("Mach-O thin (%s)"), archName(h->cputype, h->cpusubtype));
		return true;
	}
	if (be32(p) == FAT_MAGIC || be32(p) == FAT_MAGIC_64) {
		bool is64 = be32(p) == FAT_MAGIC_64;
		uint32_t count = be32(p + 4);
		int best = -1, bestRank = -1;
		CFStringAppendCString(format, "Mach-O universal (", kCFStringEncodingUTF8);
		for (uint32_t i = 0; i < count; i++) {
			const uint8_t *a = p + 8 + i * (is64 ? 32 : 20);
			if (a + (is64 ? 32 : 20) > p + n)
				return false;
			cpu_type_t type = (cpu_type_t)be32(a);
			cpu_subtype_t sub = (cpu_subtype_t)be32(a + 4);
			CFStringAppendFormat(format, NULL, CFSTR("%s%s"), i ? " " : "", archName(type, sub));
			int rank = type == CPU_TYPE_ARM64 ? ((sub & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E ? 3 : 2) : 1;
			if (rank > bestRank) {
				bestRank = rank;
				best = (int)i;
			}
		}
		CFStringAppendCString(format, ")", kCFStringEncodingUTF8);
		if (best < 0)
			return false;
		const uint8_t *a = p + 8 + best * (is64 ? 32 : 20);
		if (is64) {
			s->sliceOffset = ((uint64_t)be32(a + 8) << 32) | be32(a + 12);
			s->sliceSize = ((uint64_t)be32(a + 16) << 32) | be32(a + 20);
		} else {
			s->sliceOffset = be32(a + 8);
			s->sliceSize = be32(a + 12);
		}
		return s->sliceOffset + s->sliceSize <= n;
	}
	return false;
}

static const uint8_t *slice(StaticCode *s)
{
	return CFDataGetBytePtr(s->file) + s->sliceOffset;
}

/* Finds the embedded signature in the chosen slice. */
static void findSignature(StaticCode *s)
{
	const uint8_t *base = slice(s);
	const struct mach_header_64 *h = (const void *)base;
	if (s->sliceSize < sizeof(*h) || (h->magic != MH_MAGIC_64 && h->magic != MH_MAGIC))
		return;
	s->macho = true;
	size_t off = h->magic == MH_MAGIC_64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
	for (uint32_t i = 0; i < h->ncmds && off + sizeof(struct load_command) <= s->sliceSize; i++) {
		const struct load_command *lc = (const void *)(base + off);
		if (lc->cmdsize < sizeof(*lc) || off + lc->cmdsize > s->sliceSize)
			return;
		if (lc->cmd == LC_CODE_SIGNATURE) {
			const struct linkedit_data_command *cs = (const void *)lc;
			if ((size_t)cs->dataoff + cs->datasize <= s->sliceSize && cs->datasize >= 12) {
				s->sig = base + cs->dataoff;
				s->sigLength = cs->datasize;
			}
			return;
		}
		off += lc->cmdsize;
	}
}

static const uint8_t *blobAt(StaticCode *s, uint32_t slot, size_t *length)
{
	if (!s->sig || be32(s->sig) != kSuperBlobMagic)
		return NULL;
	uint32_t count = be32(s->sig + 8);
	size_t total = be32(s->sig + 4);
	if (total > s->sigLength)
		total = s->sigLength;
	for (uint32_t i = 0; i < count && 12 + 8 * (i + 1) <= total; i++) {
		if (be32(s->sig + 12 + 8 * i) != slot)
			continue;
		uint32_t off = be32(s->sig + 16 + 8 * i);
		if (off + 8 > total)
			return NULL;
		size_t len = be32(s->sig + off + 4);
		if (off + len > total)
			return NULL;
		*length = len;
		return s->sig + off;
	}
	return NULL;
}

static CFStringRef cdString(const uint8_t *cd, size_t cdLength, uint32_t off)
{
	if (!off || off >= cdLength)
		return NULL;
	size_t n = strnlen((const char *)cd + off, cdLength - off);
	return CFStringCreateWithBytes(NULL, cd + off, n, kCFStringEncodingUTF8, false);
}

static void readSignature(StaticCode *s)
{
	findSignature(s);
	size_t len;
	int bestRank = -1;
	s->cdhashes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	s->digestAlgorithms = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	uint32_t slots[] = {kSlotCodeDirectory, kSlotAlternateCD, kSlotAlternateCD + 1, kSlotAlternateCD + 2,
	    kSlotAlternateCD + 3, kSlotAlternateCD + 4};
	for (size_t i = 0; i < sizeof(slots) / sizeof(*slots); i++) {
		const uint8_t *cd = blobAt(s, slots[i], &len);
		if (!cd || len < 44 || be32(cd) != kCodeDirectoryMagic)
			continue;
		uint8_t type = cd[37];
		size_t size;
		const EVP_MD *md = hashFor(type, &size);
		if (!md)
			continue;
		CFDataRef full = digest(md, cd, len);
		CFDataRef h = CFDataCreate(NULL, CFDataGetBytePtr(full), 20);
		CFRelease(full);
		CFArrayAppendValue(s->cdhashes, h);
		int t = type;
		CFNumberRef tn = CFNumberCreate(NULL, kCFNumberIntType, &t);
		CFArrayAppendValue(s->digestAlgorithms, tn);
		CFRelease(tn);
		if (hashRank(type) > bestRank) {
			bestRank = hashRank(type);
			s->cd = cd;
			s->cdLength = len;
			s->hashType = type;
			if (s->unique)
				CFRelease(s->unique);
			s->unique = CFRetain(h);
		}
		CFRelease(h);
	}
	if (!s->cd)
		return;
	s->isSigned = true;
	uint32_t version = be32(s->cd + 8);
	s->flags = be32(s->cd + 12);
	s->platform = s->cd[38];
	s->identifier = cdString(s->cd, s->cdLength, be32(s->cd + 20));
	if (version >= 0x20200 && s->cdLength >= 52)
		s->teamID = cdString(s->cd, s->cdLength, be32(s->cd + 48));
	s->requirements = blobAt(s, kSlotRequirements, &s->requirementsLength);
	const uint8_t *ent = blobAt(s, kSlotEntitlements, &len);
	if (ent && be32(ent) == kEntitlementsMagic && len > 8) {
		s->entitlementsBlob = CFDataCreate(NULL, ent, len);
		CFDataRef xml = CFDataCreate(NULL, ent + 8, len - 8);
		CFPropertyListRef p = CFPropertyListCreateWithData(NULL, xml, 0, NULL, NULL);
		CFRelease(xml);
		if (isType(p, CFDictionaryGetTypeID()))
			s->entitlements = p;
		else if (p)
			CFRelease(p);
	}
	const uint8_t *cms = blobAt(s, kSlotCMS, &len);
	if (cms && len > 8)
		s->cms = CFDataCreate(NULL, cms + 8, len - 8);
}

static OSStatus readFile(CFURLRef url, CFDataRef *out)
{
	char path[PATH_MAX];
	if (!CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path)))
		return errSecCSStaticCodeNotFound;
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return errSecCSStaticCodeNotFound;
	struct stat st;
	if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
		close(fd);
		return errSecCSStaticCodeNotFound;
	}
	CFMutableDataRef d = CFDataCreateMutable(NULL, st.st_size);
	CFDataSetLength(d, st.st_size);
	ssize_t got = pread(fd, CFDataGetMutableBytePtr(d), st.st_size, 0);
	close(fd);
	if (got != st.st_size) {
		CFRelease(d);
		return errSecCSStaticCodeNotFound;
	}
	*out = d;
	return 0;
}

/* The bundle an executable path lies in (X.app/Contents/MacOS/X), if any. */
static CFURLRef enclosingBundle(const char *exe)
{
	char path[PATH_MAX];
	strlcpy(path, exe, sizeof(path));
	char *macos = strstr(path, "/Contents/MacOS/");
	if (!macos || strchr(macos + strlen("/Contents/MacOS/"), '/'))
		return NULL;
	*macos = 0;
	return CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), true);
}

static OSStatus staticCreate(CFURLRef url, SecStaticCodeRef *out)
{
	*out = NULL;
	char path[PATH_MAX];
	struct stat st;
	if (!url || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path)) || stat(path, &st) < 0)
		return errSecCSStaticCodeNotFound;
	StaticCode *s = (StaticCode *)_SecCreateInstance(SecStaticCodeGetTypeID(), sizeof(*s));
	s->path = CFRetain(url);
	if (S_ISDIR(st.st_mode)) {
		CFBundleRef b = CFBundleCreate(NULL, url);
		CFURLRef exe = b ? CFBundleCopyExecutableURL(b) : NULL;
		if (!exe) {
			if (b)
				CFRelease(b);
			CFRelease(s);
			return errSecCSBadBundleFormat;
		}
		s->bundle = CFRetain(url);
		s->executable = CFURLCopyAbsoluteURL(exe);
		CFRelease(exe);
		CFDictionaryRef info = CFBundleGetInfoDictionary(b);
		if (info) {
			s->infoPlist = CFDictionaryCreateCopy(NULL, info);
			CFTypeRef type = CFDictionaryGetValue(info, CFSTR("CFBundlePackageType"));
			s->appBundle = type && CFEqual(type, CFSTR("APPL"));
		}
		CFRelease(b);
	} else
		s->executable = CFRetain(url);
	OSStatus err = readFile(s->executable, &s->file);
	if (err) {
		CFRelease(s);
		return err;
	}
	CFMutableStringRef format = CFStringCreateMutable(NULL, 0);
	if (chooseSlice(s, format))
		readSignature(s);
	if (s->bundle)
		CFStringInsert(format, 0, s->appBundle ? CFSTR("app bundle with ") : CFSTR("bundle with "));
	s->format = format;
	if (!s->cdhashes)
		s->cdhashes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	*out = (SecStaticCodeRef)s;
	return 0;
}

OSStatus SecStaticCodeCreateWithPath(CFURLRef path, SecCSFlags flags, SecStaticCodeRef *staticCode)
{
	if (!staticCode)
		return errSecCSInvalidObjectRef;
	return staticCreate(path, staticCode);
}

OSStatus SecStaticCodeCreateWithPathAndAttributes(CFURLRef path, SecCSFlags flags, CFDictionaryRef attributes,
    SecStaticCodeRef *staticCode)
{
	return SecStaticCodeCreateWithPath(path, flags, staticCode);
}

/* ---- Validation ---- */

static bool hashMatches(const uint8_t *expected, size_t size, const EVP_MD *md, const void *data, size_t n)
{
	CFDataRef h = digest(md, data, n);
	bool ok = h && memcmp(CFDataGetBytePtr(h), expected, size) == 0;
	if (h)
		CFRelease(h);
	return ok;
}

static bool zero(const uint8_t *p, size_t n)
{
	for (size_t i = 0; i < n; i++)
		if (p[i])
			return false;
	return true;
}

/* The hash a special slot (-slot) records, or NULL if the directory has none. */
static const uint8_t *specialSlot(StaticCode *s, uint32_t slot, size_t *size, const EVP_MD **md)
{
	*md = hashFor(s->hashType, size);
	uint32_t hashOffset = be32(s->cd + 16), nSpecial = be32(s->cd + 24);
	if (slot > nSpecial || hashOffset < slot * *size)
		return NULL;
	const uint8_t *h = s->cd + hashOffset - slot * *size;
	return zero(h, *size) ? NULL : h;
}

static OSStatus checkFileSlot(StaticCode *s, uint32_t slot, CFURLRef file)
{
	size_t size;
	const EVP_MD *md;
	const uint8_t *h = specialSlot(s, slot, &size, &md);
	if (!h)
		return 0;
	CFDataRef d = NULL;
	if (!file || readFile(file, &d))
		return slot == kSlotResources ? errSecCSResourcesNotFound : errSecCSInfoPlistFailed;
	bool ok = hashMatches(h, size, md, CFDataGetBytePtr(d), CFDataGetLength(d));
	CFRelease(d);
	return ok ? 0 : slot == kSlotResources ? errSecCSResourcesInvalid : errSecCSInfoPlistFailed;
}

/* A file in a bundle: under Contents/ (macOS bundles), or at the top (flat). */
static CFURLRef bundleFile(StaticCode *s, CFStringRef relative)
{
	if (!s->bundle)
		return NULL;
	CFStringRef rel = CFStringCreateWithFormat(NULL, NULL, CFSTR("Contents/%@"), relative);
	CFURLRef u = CFURLCreateCopyAppendingPathComponent(NULL, s->bundle, rel, false);
	CFRelease(rel);
	char p[PATH_MAX];
	if (u && CFURLGetFileSystemRepresentation(u, true, (UInt8 *)p, sizeof(p)) && access(p, F_OK) == 0)
		return u;
	if (u)
		CFRelease(u);
	return CFURLCreateCopyAppendingPathComponent(NULL, s->bundle, relative, false);
}

/* The bundle's sealed resources (_CodeSignature/CodeResources, files2). */
static OSStatus checkResources(StaticCode *s)
{
	CFURLRef cr = bundleFile(s, CFSTR("_CodeSignature/CodeResources"));
	CFDataRef d = NULL;
	OSStatus err = cr ? readFile(cr, &d) : errSecCSResourcesNotFound;
	if (cr)
		CFRelease(cr);
	if (err) {
		size_t size;
		const EVP_MD *md;
		return specialSlot(s, kSlotResources, &size, &md) ? errSecCSResourcesNotFound : 0;
	}
	CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, d, 0, NULL, NULL);
	CFRelease(d);
	CFDictionaryRef files = isType(plist, CFDictionaryGetTypeID()) ? CFDictionaryGetValue(plist, CFSTR("files2")) : NULL;
	err = 0;
	if (isType(files, CFDictionaryGetTypeID())) {
		CFIndex n = CFDictionaryGetCount(files);
		const void **keys = malloc(sizeof(void *) * n), **values = malloc(sizeof(void *) * n);
		CFDictionaryGetKeysAndValues(files, keys, values);
		for (CFIndex i = 0; !err && i < n; i++) {
			CFTypeRef v = values[i];
			CFDataRef h2 = NULL, h1 = NULL;
			bool optional = false;
			if (isType(v, CFDataGetTypeID()))
				h1 = v;
			else if (isType(v, CFDictionaryGetTypeID())) {
				if (CFDictionaryGetValue(v, CFSTR("symlink")) || CFDictionaryGetValue(v, CFSTR("cdhash")) ||
				    CFDictionaryGetValue(v, CFSTR("requirement")))
					continue;   /* symlinks and nested code: not checked here */
				h2 = CFDictionaryGetValue(v, CFSTR("hash2"));
				h1 = CFDictionaryGetValue(v, CFSTR("hash"));
				optional = CFDictionaryGetValue(v, CFSTR("optional")) == kCFBooleanTrue;
			}
			CFURLRef f = bundleFile(s, keys[i]);
			CFDataRef content = NULL;
			if (!f || readFile(f, &content)) {
				if (!optional)
					err = errSecCSBadResource;
			} else if (isType(h2, CFDataGetTypeID())) {
				if (!hashMatches(CFDataGetBytePtr(h2), CFDataGetLength(h2), EVP_sha256(), CFDataGetBytePtr(content), CFDataGetLength(content)))
					err = errSecCSBadResource;
			} else if (isType(h1, CFDataGetTypeID())) {
				if (!hashMatches(CFDataGetBytePtr(h1), CFDataGetLength(h1), EVP_sha1(), CFDataGetBytePtr(content), CFDataGetLength(content)))
					err = errSecCSBadResource;
			}
			if (content)
				CFRelease(content);
			if (f)
				CFRelease(f);
		}
		free(keys);
		free(values);
	}
	if (plist)
		CFRelease(plist);
	return err;
}

/* The CMS signature: verified over the code directory; its certificates
 * collected leaf first. Chains aren't checked against any root store. */
static OSStatus checkCMS(StaticCode *s)
{
	if (!s->cms || CFDataGetLength(s->cms) == 0)
		return 0;
	const unsigned char *p = CFDataGetBytePtr(s->cms);
	CMS_ContentInfo *cms = d2i_CMS_ContentInfo(NULL, &p, CFDataGetLength(s->cms));
	if (!cms)
		return (s->flags & kSecCodeSignatureAdhoc) ? 0 : errSecCSSignatureFailed;
	BIO *content = BIO_new_mem_buf(s->cd, (int)s->cdLength);
	int ok = CMS_verify(cms, NULL, NULL, content, NULL, CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY);
	BIO_free(content);
	if (!s->certificates) {
		STACK_OF(X509) *certs = CMS_get1_certs(cms);
		STACK_OF(X509) *signers = ok ? CMS_get0_signers(cms) : NULL;
		CFMutableArrayRef chain = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		X509 *cur = signers && sk_X509_num(signers) ? sk_X509_value(signers, 0) : (certs && sk_X509_num(certs) ? sk_X509_value(certs, 0) : NULL);
		for (int depth = 0; cur && depth < 10; depth++) {
			unsigned char *der = NULL;
			int n = i2d_X509(cur, &der);
			CFDataRef d = n > 0 ? CFDataCreate(NULL, der, n) : NULL;
			OPENSSL_free(der);
			SecCertificateRef c = d ? SecCertificateCreateWithData(NULL, d) : NULL;
			if (d)
				CFRelease(d);
			if (c) {
				CFArrayAppendValue(chain, c);
				CFRelease(c);
			}
			if (X509_check_issued(cur, cur) == X509_V_OK)
				break;
			X509 *next = NULL;
			for (int i = 0; certs && i < sk_X509_num(certs); i++)
				if (X509_check_issued(sk_X509_value(certs, i), cur) == X509_V_OK && sk_X509_value(certs, i) != cur)
					next = sk_X509_value(certs, i);
			cur = next;
		}
		s->certificates = chain;
		OSSL_STACK_OF_X509_free(certs);
	}
	CMS_ContentInfo_free(cms);
	return ok ? 0 : errSecCSSignatureFailed;
}

static OSStatus checkPages(StaticCode *s, CFIndex limit)
{
	size_t size;
	const EVP_MD *md = hashFor(s->hashType, &size);
	uint32_t hashOffset = be32(s->cd + 16), nCode = be32(s->cd + 28);
	uint64_t codeLimit = be32(s->cd + 32);
	uint32_t version = be32(s->cd + 8);
	if (version >= 0x20300 && s->cdLength >= 64) {
		uint64_t limit64 = ((uint64_t)be32(s->cd + 56) << 32) | be32(s->cd + 60);
		if (limit64)
			codeLimit = limit64;
	}
	uint8_t pageShift = s->cd[39];
	size_t pageSize = pageShift ? (size_t)1 << pageShift : codeLimit;
	if (!md || codeLimit > s->sliceSize || hashOffset + (size_t)nCode * size > s->cdLength)
		return errSecCSSignatureFailed;
	const uint8_t *base = slice(s);
	for (uint32_t i = 0; i < nCode; i++) {
		size_t start = (size_t)i * pageSize;
		if (start >= codeLimit)
			break;
		size_t n = codeLimit - start < pageSize ? codeLimit - start : pageSize;
		if (!hashMatches(s->cd + hashOffset + (size_t)i * size, size, md, base + start, n))
			return errSecCSSignatureFailed;
	}
	(void)limit;
	return 0;
}

static void context(StaticCode *s, SecCodeContext *ctx)
{
	memset(ctx, 0, sizeof(*ctx));
	ctx->identifier = s->identifier;
	ctx->cdhashes = s->cdhashes;
	ctx->infoPlist = s->infoPlist;
	ctx->entitlements = s->entitlements;
	ctx->certificates = s->certificates && CFArrayGetCount(s->certificates) ? s->certificates : NULL;
	ctx->platform = s->platform;
}

static OSStatus validate(StaticCode *s, SecCSFlags flags, SecRequirementRef req)
{
	if (!s->isSigned)
		return errSecCSUnsigned;
	OSStatus err = checkPages(s, 0);
	if (!err && s->requirements) {
		size_t size;
		const EVP_MD *md;
		const uint8_t *h = specialSlot(s, kSlotRequirements, &size, &md);
		if (h && !hashMatches(h, size, md, s->requirements, s->requirementsLength))
			err = errSecCSSignatureFailed;
	}
	if (!err && s->entitlementsBlob) {
		size_t size;
		const EVP_MD *md;
		const uint8_t *h = specialSlot(s, kSlotEntitlements, &size, &md);
		if (h && !hashMatches(h, size, md, CFDataGetBytePtr(s->entitlementsBlob), CFDataGetLength(s->entitlementsBlob)))
			err = errSecCSSignatureFailed;
	}
	if (!err && s->bundle) {
		CFURLRef info = bundleFile(s, CFSTR("Info.plist"));
		err = checkFileSlot(s, kSlotInfo, info);
		if (info)
			CFRelease(info);
		if (!err) {
			CFURLRef cr = bundleFile(s, CFSTR("_CodeSignature/CodeResources"));
			err = checkFileSlot(s, kSlotResources, cr);
			if (cr)
				CFRelease(cr);
		}
		if (!err && !(flags & kSecCSDoNotValidateResources))
			err = checkResources(s);
	}
	if (!err)
		err = checkCMS(s);
	if (!err && req) {
		SecCodeContext ctx;
		context(s, &ctx);
		if (!_SecRequirementEvaluate(req, &ctx))
			err = errSecCSReqFailed;
	}
	return err;
}

static OSStatus withErrors(OSStatus err, CFErrorRef *errors)
{
	if (errors)
		*errors = err ? _SecCreateError(err, NULL) : NULL;
	return err;
}

OSStatus SecStaticCodeCheckValidityWithErrors(SecStaticCodeRef staticCode, SecCSFlags flags,
    SecRequirementRef requirement, CFErrorRef *errors)
{
	if (!isType(staticCode, SecStaticCodeGetTypeID()) || (requirement && !isType(requirement, SecRequirementGetTypeID())))
		return withErrors(errSecCSInvalidObjectRef, errors);
	StaticCode *s = (StaticCode *)staticCode;
	OSStatus err = validate(s, flags, requirement);
	if (!err && (flags & kSecCSCheckAllArchitectures) && s->file) {
		/* Every slice of a universal binary. */
		const uint8_t *p = CFDataGetBytePtr(s->file);
		if (be32(p) == FAT_MAGIC) {
			uint32_t count = be32(p + 4);
			for (uint32_t i = 0; !err && i < count; i++) {
				StaticCode copy = *s;
				copy.sliceOffset = be32(p + 8 + i * 20 + 8);
				copy.sliceSize = be32(p + 8 + i * 20 + 12);
				copy.sig = NULL;
				copy.cd = NULL;
				copy.unique = NULL;
				copy.cdhashes = NULL;
				copy.digestAlgorithms = NULL;
				copy.identifier = copy.teamID = NULL;
				copy.entitlementsBlob = NULL;
				copy.entitlements = NULL;
				copy.cms = NULL;
				copy.certificates = NULL;
				copy.isSigned = false;
				if (copy.sliceOffset + copy.sliceSize > (size_t)CFDataGetLength(s->file))
					return withErrors(errSecCSSignatureFailed, errors);
				readSignature(&copy);
				err = validate(&copy, flags, requirement);
				CFTypeRef refs[] = {copy.unique, copy.cdhashes, copy.digestAlgorithms, copy.identifier, copy.teamID,
				    copy.entitlementsBlob, copy.entitlements, copy.cms, copy.certificates};
				for (size_t r = 0; r < sizeof(refs) / sizeof(*refs); r++)
					if (refs[r])
						CFRelease(refs[r]);
			}
		}
	}
	return withErrors(err, errors);
}

OSStatus SecStaticCodeCheckValidity(SecStaticCodeRef staticCode, SecCSFlags flags, SecRequirementRef requirement)
{
	return SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, NULL);
}

/* Finch's kernel maps code pages as dyld and the pager validate them. */
OSStatus SecCodeMapMemory(SecStaticCodeRef code, SecCSFlags flags)
{
	return isType(code, SecStaticCodeGetTypeID()) ? 0 : errSecCSInvalidObjectRef;
}

/* ---- Running code ---- */

typedef struct {
	CFRuntimeBase base;
	pid_t pid;
	SecStaticCodeRef staticCode;   /* NULL for the kernel */
} Code;

static void codeFree(CFTypeRef o)
{
	if (((Code *)o)->staticCode)
		CFRelease(((Code *)o)->staticCode);
}
static Boolean codeEqual(CFTypeRef a, CFTypeRef b)
{
	return ((Code *)a)->pid == ((Code *)b)->pid;
}
static CFHashCode codeHash(CFTypeRef a)
{
	return (CFHashCode)((Code *)a)->pid;
}
SEC_DEFINE_TYPE(SecCodeGetTypeID, "SecCode", codeFree, codeEqual, codeHash)

static OSStatus staticForPID(pid_t pid, SecStaticCodeRef *out)
{
	char path[PROC_PIDPATHINFO_MAXSIZE];
	uint32_t size = sizeof(path);
	if (pid == getpid() ? _NSGetExecutablePath(path, &size) != 0 : proc_pidpath(pid, path, sizeof(path)) <= 0)
		return errSecCSNoSuchCode;
	char real[PATH_MAX];
	if (realpath(path, real))
		strlcpy(path, real, sizeof(path));
	CFURLRef url = enclosingBundle(path);
	if (!url)
		url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
	OSStatus err = staticCreate(url, out);
	CFRelease(url);
	return err;
}

static OSStatus codeForPID(pid_t pid, SecCodeRef *out)
{
	*out = NULL;
	if (pid != 0 && kill(pid, 0) < 0 && errno == ESRCH)
		return errSecCSNoSuchCode;
	Code *c = (Code *)_SecCreateInstance(SecCodeGetTypeID(), sizeof(*c));
	c->pid = pid;
	if (pid) {
		OSStatus err = staticForPID(pid, &c->staticCode);
		if (err) {
			CFRelease(c);
			return err;
		}
	}
	*out = (SecCodeRef)c;
	return 0;
}

OSStatus SecCodeCopySelf(SecCSFlags flags, SecCodeRef *self)
{
	if (!self)
		return errSecCSInvalidObjectRef;
	return codeForPID(getpid(), self);
}

OSStatus SecCodeCopyStaticCode(SecCodeRef code, SecCSFlags flags, SecStaticCodeRef *staticCode)
{
	if (!isType(code, SecCodeGetTypeID()) || !staticCode)
		return errSecCSInvalidObjectRef;
	if (!((Code *)code)->staticCode)
		return errSecCSStaticCodeNotFound;
	*staticCode = (SecStaticCodeRef)CFRetain(((Code *)code)->staticCode);
	return 0;
}

/* Every process's host is the kernel. */
OSStatus SecCodeCopyHost(SecCodeRef guest, SecCSFlags flags, SecCodeRef *host)
{
	if (!isType(guest, SecCodeGetTypeID()) || !host)
		return errSecCSInvalidObjectRef;
	if (((Code *)guest)->pid == 0) {
		*host = NULL;
		return 0;
	}
	return codeForPID(0, host);
}

OSStatus SecCodeCopyGuestWithAttributes(SecCodeRef host, CFDictionaryRef attributes, SecCSFlags flags, SecCodeRef *guest)
{
	if (!guest)
		return errSecCSInvalidObjectRef;
	*guest = NULL;
	pid_t pid = -1;
	CFTypeRef p = attributes ? CFDictionaryGetValue(attributes, kSecGuestAttributePid) : NULL;
	CFTypeRef token = attributes ? CFDictionaryGetValue(attributes, kSecGuestAttributeAudit) : NULL;
	if (isType(p, CFNumberGetTypeID()))
		CFNumberGetValue(p, kCFNumberIntType, &pid);
	else if (isType(token, CFDataGetTypeID()) && CFDataGetLength(token) == sizeof(audit_token_t)) {
		audit_token_t t;
		memcpy(&t, CFDataGetBytePtr(token), sizeof(t));
		pid = audit_token_to_pid(t);
	} else
		return errSecCSUnsupportedGuestAttributes;
	if (pid <= 0)
		return errSecCSNoSuchCode;
	return codeForPID(pid, guest);
}

OSStatus SecCodeCreateWithPID(pid_t pid, SecCSFlags flags, SecCodeRef *process)
{
	if (!process)
		return errSecCSInvalidObjectRef;
	return codeForPID(pid, process);
}

static StaticCode *staticOf(CFTypeRef code)
{
	if (isType(code, SecStaticCodeGetTypeID()))
		return (StaticCode *)code;
	if (isType(code, SecCodeGetTypeID()))
		return (StaticCode *)((Code *)code)->staticCode;
	return NULL;
}

OSStatus SecCodeCheckValidityWithErrors(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement, CFErrorRef *errors)
{
	if (!isType(code, SecCodeGetTypeID()))
		return withErrors(errSecCSInvalidObjectRef, errors);
	StaticCode *s = staticOf(code);
	if (!s)
		return withErrors(0, errors);   /* the kernel */
	return withErrors(validate(s, flags | kSecCSDoNotValidateResources, requirement), errors);
}

OSStatus SecCodeCheckValidity(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement)
{
	return SecCodeCheckValidityWithErrors(code, flags, requirement, NULL);
}

OSStatus SecCodeCopyPath(SecStaticCodeRef code, SecCSFlags flags, CFURLRef *path)
{
	StaticCode *s = staticOf(code);
	if (!s || !path)
		return errSecCSInvalidObjectRef;
	*path = CFRetain(s->bundle ? s->bundle : s->executable);
	return 0;
}

static SecRequirementRef designated(StaticCode *s)
{
	if (!s->isSigned)
		return NULL;
	if (s->requirements) {
		SecRequirementRef r = _SecRequirementsCopyType(s->requirements, s->requirementsLength, kSecDesignatedRequirementType);
		if (r)
			return r;
	}
	CFStringRef text = NULL;
	if (s->certificates && CFArrayGetCount(s->certificates) && s->identifier) {
		SecCertificateRef root = (SecCertificateRef)CFArrayGetValueAtIndex(s->certificates, CFArrayGetCount(s->certificates) - 1);
		CFDataRef der = SecCertificateCopyData(root);
		CFDataRef h = _SecCodeCopySHA1(der);
		CFMutableStringRef hex = CFStringCreateMutable(NULL, 0);
		for (CFIndex i = 0; h && i < CFDataGetLength(h); i++)
			CFStringAppendFormat(hex, NULL, CFSTR("%02x"), CFDataGetBytePtr(h)[i]);
		text = CFStringCreateWithFormat(NULL, NULL, CFSTR("identifier \"%@\" and certificate root = H\"%@\""), s->identifier, hex);
		CFRelease(hex);
		if (h)
			CFRelease(h);
		CFRelease(der);
	} else {
		CFMutableStringRef hex = CFStringCreateMutable(NULL, 0);
		for (CFIndex i = 0; i < CFDataGetLength(s->unique); i++)
			CFStringAppendFormat(hex, NULL, CFSTR("%02x"), CFDataGetBytePtr(s->unique)[i]);
		text = CFStringCreateWithFormat(NULL, NULL, CFSTR("cdhash H\"%@\""), hex);
		CFRelease(hex);
	}
	SecRequirementRef r = NULL;
	SecRequirementCreateWithString(text, kSecCSDefaultFlags, &r);
	CFRelease(text);
	return r;
}

OSStatus SecCodeCopyDesignatedRequirement(SecStaticCodeRef code, SecCSFlags flags, SecRequirementRef *requirement)
{
	StaticCode *s = staticOf(code);
	if (!s || !requirement)
		return errSecCSInvalidObjectRef;
	*requirement = designated(s);
	return *requirement ? 0 : errSecCSUnsigned;
}

static void setNumber(CFMutableDictionaryRef d, CFStringRef k, uint32_t v)
{
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
	CFDictionarySetValue(d, k, n);
	CFRelease(n);
}

OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *information)
{
	StaticCode *s = staticOf(code);
	if (!s || !information)
		return errSecCSInvalidObjectRef;
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(d, kSecCodeInfoMainExecutable, s->executable);
	if (isType(code, SecCodeGetTypeID()) && (flags & kSecCSDynamicInformation)) {
		uint32_t status = 0;
		if (csops(((Code *)code)->pid, CS_OPS_STATUS, &status, sizeof(status)) == 0)
			setNumber(d, kSecCodeInfoStatus, status);
	}
	if (!s->isSigned) {
		*information = d;
		return 0;
	}
	checkCMS(s);   /* collects the certificates */
	CFDictionarySetValue(d, kSecCodeInfoIdentifier, s->identifier ? s->identifier : CFSTR(""));
	setNumber(d, kSecCodeInfoFlags, s->flags);
	CFDictionarySetValue(d, kSecCodeInfoFormat, s->format);
	CFDictionarySetValue(d, kSecCodeInfoSource, CFSTR("embedded"));
	CFDictionarySetValue(d, kSecCodeInfoUnique, s->unique);
	CFDictionarySetValue(d, kSecCodeInfoCdHashes, s->cdhashes);
	setNumber(d, kSecCodeInfoDigestAlgorithm, s->hashType);
	CFDictionarySetValue(d, kSecCodeInfoDigestAlgorithms, s->digestAlgorithms);
	if (s->platform)
		setNumber(d, kSecCodeInfoPlatformIdentifier, s->platform);
	if (s->infoPlist)
		CFDictionarySetValue(d, kSecCodeInfoPList, s->infoPlist);
	if (flags & kSecCSSigningInformation) {
		if (s->cms && CFDataGetLength(s->cms))
			CFDictionarySetValue(d, kSecCodeInfoCMS, s->cms);
		if (s->teamID)
			CFDictionarySetValue(d, kSecCodeInfoTeamIdentifier, s->teamID);
		if (s->certificates && CFArrayGetCount(s->certificates))
			CFDictionarySetValue(d, kSecCodeInfoCertificates, s->certificates);
	}
	if (flags & kSecCSRequirementInformation) {
		if (s->requirements) {
			CFStringRef text = _SecRequirementsCopyText(s->requirements, s->requirementsLength);
			CFDictionarySetValue(d, kSecCodeInfoRequirements, text);
			CFRelease(text);
			CFDataRef data = CFDataCreate(NULL, s->requirements, s->requirementsLength);
			CFDictionarySetValue(d, kSecCodeInfoRequirementData, data);
			CFRelease(data);
		}
		SecRequirementRef dr = designated(s);
		if (dr) {
			CFDictionarySetValue(d, kSecCodeInfoDesignatedRequirement, dr);
			CFDictionarySetValue(d, kSecCodeInfoImplicitDesignatedRequirement, dr);
			CFRelease(dr);
		}
		if (s->entitlementsBlob)
			CFDictionarySetValue(d, kSecCodeInfoEntitlements, s->entitlementsBlob);
		if (s->entitlements)
			CFDictionarySetValue(d, kSecCodeInfoEntitlementsDict, s->entitlements);
	}
	*information = d;
	return 0;
}

/* ---- Certificate fields for requirements ---- */

CFTypeRef _SecCodeCopyCertificateField(SecCertificateRef cert, uint32_t op, const uint8_t *key, size_t keyLength)
{
	CFDataRef der = SecCertificateCopyData(cert);
	const unsigned char *p = CFDataGetBytePtr(der);
	X509 *x = d2i_X509(NULL, &p, CFDataGetLength(der));
	CFRelease(der);
	if (!x)
		return NULL;
	CFTypeRef result = NULL;
	if (op == 11 /* opCertField: "subject.XX" */) {
		char field[256];
		size_t n = keyLength < sizeof(field) - 1 ? keyLength : sizeof(field) - 1;
		memcpy(field, key, n);
		field[n] = 0;
		const char *attr = field + strlen("subject.");
		static const struct {
			const char *name;
			int nid;
		} names[] = {{"CN", NID_commonName}, {"C", NID_countryName}, {"D", NID_description},
		    {"L", NID_localityName}, {"O", NID_organizationName}, {"OU", NID_organizationalUnitName},
		    {"ST", NID_stateOrProvinceName}, {"STREET", NID_streetAddress}, {"UID", NID_userId},
		    {"email", NID_pkcs9_emailAddress}};
		for (size_t i = 0; i < sizeof(names) / sizeof(*names); i++) {
			if (strcmp(attr, names[i].name))
				continue;
			X509_NAME *name = X509_get_subject_name(x);
			int at = X509_NAME_get_index_by_NID(name, names[i].nid, -1);
			if (at >= 0) {
				unsigned char *utf8 = NULL;
				int len = ASN1_STRING_to_UTF8(&utf8, X509_NAME_ENTRY_get_data(X509_NAME_get_entry(name, at)));
				if (len >= 0)
					result = CFStringCreateWithBytes(NULL, utf8, len, kCFStringEncodingUTF8, false);
				OPENSSL_free(utf8);
			}
		}
	} else {
		/* An extension (or policy) by OID: present or not. */
		ASN1_OBJECT *oid = NULL;
		unsigned char buf[300];
		if (keyLength + 2 <= sizeof(buf)) {
			buf[0] = 0x06;
			buf[1] = (unsigned char)keyLength;
			memcpy(buf + 2, key, keyLength);
			const unsigned char *q = buf;
			oid = d2i_ASN1_OBJECT(NULL, &q, keyLength + 2);
		}
		if (oid) {
			if (op == 17 /* opCertPolicy */) {
				CERTIFICATEPOLICIES *pols = X509_get_ext_d2i(x, NID_certificate_policies, NULL, NULL);
				for (int i = 0; pols && i < sk_POLICYINFO_num(pols); i++)
					if (OBJ_cmp(sk_POLICYINFO_value(pols, i)->policyid, oid) == 0)
						result = CFRetain(kCFBooleanTrue);
				CERTIFICATEPOLICIES_free(pols);
			} else if (X509_get_ext_by_OBJ(x, oid, -1) >= 0)
				result = CFRetain(kCFBooleanTrue);
			ASN1_OBJECT_free(oid);
		}
	}
	X509_free(x);
	return result;
}

/* ---- SecTask ---- */

typedef struct {
	CFRuntimeBase base;
	pid_t pid;
	audit_token_t token;
	bool haveToken;
} Task;
SEC_DEFINE_TYPE(SecTaskGetTypeID, "SecTask", NULL, NULL, NULL)

SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator)
{
	Task *t = (Task *)_SecCreateInstance(SecTaskGetTypeID(), sizeof(*t));
	t->pid = getpid();
	return (SecTaskRef)t;
}

SecTaskRef SecTaskCreateWithAuditToken(CFAllocatorRef allocator, audit_token_t token)
{
	Task *t = (Task *)_SecCreateInstance(SecTaskGetTypeID(), sizeof(*t));
	t->pid = audit_token_to_pid(token);
	t->token = token;
	t->haveToken = true;
	return (SecTaskRef)t;
}

CFStringRef _SecCodeCopyIdentifierForPID(pid_t pid)
{
	SecStaticCodeRef s = NULL;
	if (staticForPID(pid, &s))
		return NULL;
	CFStringRef id = ((StaticCode *)s)->identifier ? CFRetain(((StaticCode *)s)->identifier) : NULL;
	CFRelease(s);
	return id;
}

CFDictionaryRef _SecCodeCopyEntitlementsForPID(pid_t pid)
{
	SecStaticCodeRef s = NULL;
	if (staticForPID(pid, &s))
		return NULL;
	CFDictionaryRef e = ((StaticCode *)s)->entitlements ? CFRetain(((StaticCode *)s)->entitlements) : NULL;
	CFRelease(s);
	return e;
}

CFStringRef SecTaskCopySigningIdentifier(SecTaskRef task, CFErrorRef *error)
{
	if (error)
		*error = NULL;
	if (!isType(task, SecTaskGetTypeID()))
		return NULL;
	return _SecCodeCopyIdentifierForPID(((Task *)task)->pid);
}

CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{
	if (error)
		*error = NULL;
	if (!isType(task, SecTaskGetTypeID()) || !entitlement)
		return NULL;
	CFDictionaryRef ents = _SecCodeCopyEntitlementsForPID(((Task *)task)->pid);
	CFTypeRef v = ents ? CFDictionaryGetValue(ents, entitlement) : NULL;
	if (v)
		CFRetain(v);
	if (ents)
		CFRelease(ents);
	return v;
}

CFDictionaryRef SecTaskCopyValuesForEntitlements(SecTaskRef task, CFArrayRef entitlements, CFErrorRef *error)
{
	if (error)
		*error = NULL;
	if (!isType(task, SecTaskGetTypeID()) || !isType(entitlements, CFArrayGetTypeID()))
		return NULL;
	CFDictionaryRef ents = _SecCodeCopyEntitlementsForPID(((Task *)task)->pid);
	CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	for (CFIndex i = 0; ents && i < CFArrayGetCount(entitlements); i++) {
		CFTypeRef k = CFArrayGetValueAtIndex(entitlements, i);
		CFTypeRef v = CFDictionaryGetValue(ents, k);
		if (v)
			CFDictionarySetValue(out, k, v);
	}
	if (ents)
		CFRelease(ents);
	return out;
}

uint32_t SecTaskGetCodeSignStatus(SecTaskRef task)
{
	uint32_t status = 0;
	if (isType(task, SecTaskGetTypeID()))
		csops(((Task *)task)->pid, CS_OPS_STATUS, &status, sizeof(status));
	return status;
}
