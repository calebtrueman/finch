/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Local Security objects use OpenSSL for key parsing and certificate checks.
 * There is no implicit trust store: a caller must supply trusted roots. */
#include "SecInternal.h"
#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/rsa.h>
#include <openssl/ec.h>
#include <openssl/rand.h>
#include <openssl/bio.h>
#include <time.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>

static pthread_mutex_t typeLock = PTHREAD_MUTEX_INITIALIZER;
CFTypeID _SecRegisterClass(CFTypeID *slot, const CFRuntimeClass *cls)
{
	pthread_mutex_lock(&typeLock);
	if (!*slot)
		*slot = _CFRuntimeRegisterClass(cls);
	pthread_mutex_unlock(&typeLock);
	return *slot;
}
CFTypeRef _SecCreateInstance(CFTypeID type, size_t size)
{
	return _CFRuntimeCreateInstance(NULL, type, size - sizeof(CFRuntimeBase), NULL);
}
CFErrorRef _SecCreateError(OSStatus status, CFStringRef description)
{
	CFDictionaryRef info = description
	    ? CFDictionaryCreate(NULL, (const void *[]){kCFErrorDescriptionKey},
	          (const void *[]){description}, 1, &kCFTypeDictionaryKeyCallBacks,
	          &kCFTypeDictionaryValueCallBacks)
	    : NULL;
	CFErrorRef e = CFErrorCreate(NULL, kCFErrorDomainOSStatus, status, info);
	if (info)
		CFRelease(info);
	return e;
}
bool _SecSetError(CFErrorRef *e, OSStatus s, CFStringRef d)
{
	if (e)
		*e = _SecCreateError(s, d);
	return false;
}
/* Error messages: Resources/en.lproj/SecErrorMessages.strings, generated at
 * build time from Apple's headers by Apple's generateErrStrings.pl. */
static CFDictionaryRef errorStrings;
static void loadErrorStrings(void)
{
	Dl_info info;
	if (!dladdr((const void *)loadErrorStrings, &info) || !info.dli_fname)
		return;
	char path[PATH_MAX];
	const char *slash = strrchr(info.dli_fname, '/');
	if (!slash)
		return;
	snprintf(path, sizeof(path), "%.*s/Resources/en.lproj/SecErrorMessages.strings",
	    (int)(slash - info.dli_fname), info.dli_fname);
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(
	    NULL, (const UInt8 *)path, strlen(path), false);
	CFReadStreamRef stream = url ? CFReadStreamCreateWithFile(NULL, url) : NULL;
	if (stream && CFReadStreamOpen(stream)) {
		CFPropertyListRef plist =
		    CFPropertyListCreateWithStream(NULL, stream, 0, 0, NULL, NULL);
		if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID())
			errorStrings = plist;
		else if (plist)
			CFRelease(plist);
		CFReadStreamClose(stream);
	}
	if (stream)
		CFRelease(stream);
	if (url)
		CFRelease(url);
}
CFStringRef _SecCopyErrorString(OSStatus s)
{
	static pthread_once_t once = PTHREAD_ONCE_INIT;
	pthread_once(&once, loadErrorStrings);
	if (!errorStrings)
		return NULL;
	CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), (int)s);
	CFStringRef v = CFDictionaryGetValue(errorStrings, key);
	CFRelease(key);
	return v && CFGetTypeID(v) == CFStringGetTypeID() ? CFRetain(v) : NULL;
}
CFStringRef SecCopyErrorMessageString(OSStatus s, void *reserved)
{
	CFStringRef r = _SecCopyErrorString(s);
	return r ? r : CFStringCreateWithFormat(NULL, NULL, CFSTR("OSStatus %d"), (int)s);
}
const SecRandomRef kSecRandomDefault = NULL;
int SecRandomCopyBytes(SecRandomRef random, size_t count, void *bytes)
{
	if (random || (!bytes && count))
		return errSecParam;
	if (count)
		arc4random_buf(bytes, count);
	return 0;
}

typedef struct {
	CFRuntimeBase base;
	X509 *cert;
} Certificate;
typedef struct {
	CFRuntimeBase base;
	EVP_PKEY *key;
	bool private;
} Key;
typedef struct {
	CFRuntimeBase base;
	CFDictionaryRef properties;
} Policy;
typedef struct {
	CFRuntimeBase base;
	CFArrayRef certs, anchors, policies;
	CFArrayRef chain;   /* built by the last evaluation */
	CFDateRef date;
	CFIndex result;
	OSStatus status;
} Trust;
static void certFree(CFTypeRef o)
{
	X509_free(((Certificate *)o)->cert);
}
static void keyFree(CFTypeRef o)
{
	EVP_PKEY_free(((Key *)o)->key);
}
static void policyFree(CFTypeRef o)
{
	CFRelease(((Policy *)o)->properties);
}
static void trustFree(CFTypeRef o)
{
	Trust *t = (Trust *)o;
	if (t->certs)
		CFRelease(t->certs);
	if (t->anchors)
		CFRelease(t->anchors);
	if (t->policies)
		CFRelease(t->policies);
	if (t->date)
		CFRelease(t->date);
	if (t->chain)
		CFRelease(t->chain);
}
static Boolean certEqual(CFTypeRef a, CFTypeRef b)
{
	return X509_cmp(((Certificate *)a)->cert, ((Certificate *)b)->cert) == 0;
}
static CFHashCode certHash(CFTypeRef a)
{
	unsigned char digest[EVP_MAX_MD_SIZE];
	unsigned int n = 0;
	X509_digest(((Certificate *)a)->cert, EVP_sha1(), digest, &n);
	CFHashCode h = 0;
	memcpy(&h, digest, sizeof(h));
	return h;
}
static Boolean keyEqual(CFTypeRef a, CFTypeRef b)
{
	Key *x = (Key *)a, *y = (Key *)b;
	if (x->private != y->private || EVP_PKEY_base_id(x->key) != EVP_PKEY_base_id(y->key))
		return false;
	return EVP_PKEY_eq(x->key, y->key) == 1;
}
static CFHashCode keyHash(CFTypeRef a)
{
	return (CFHashCode)EVP_PKEY_bits(((Key *)a)->key) ^ ((Key *)a)->private;
}
#define TYPE(Name, Finalizer, Equal, Hash)                                                         \
	CFTypeID Sec##Name##GetTypeID(void)                                                        \
	{                                                                                          \
		static CFTypeID id;                                                                \
		static const CFRuntimeClass cls = {                                                \
		    0, "Sec" #Name, NULL, NULL, Finalizer, Equal, Hash, NULL, NULL};               \
		return _SecRegisterClass(&id, &cls);                                               \
	}
TYPE(Certificate, certFree, certEqual, certHash)
TYPE(Key, keyFree, keyEqual, keyHash)
TYPE(Policy, policyFree, NULL, NULL)
TYPE(Trust, trustFree, NULL, NULL)
static bool valid(CFTypeRef o, CFTypeID t)
{
	return o && CFGetTypeID(o) == t;
}
SecCertificateRef SecCertificateCreateWithData(CFAllocatorRef allocator, CFDataRef data)
{
	if (!valid(data, CFDataGetTypeID()))
		return NULL;
	const unsigned char *p = CFDataGetBytePtr(data), *start = p;
	X509 *x = d2i_X509(NULL, &p, CFDataGetLength(data));
	if (!x || p != start + CFDataGetLength(data)) {
		X509_free(x);
		return NULL;
	}
	Certificate *c = (Certificate *)_SecCreateInstance(SecCertificateGetTypeID(), sizeof(*c));
	if (!c) {
		X509_free(x);
		return NULL;
	}
	c->cert = x;
	return (SecCertificateRef)c;
}
CFDataRef SecCertificateCopyData(SecCertificateRef ref)
{
	if (!valid(ref, SecCertificateGetTypeID()))
		return NULL;
	unsigned char *out = NULL;
	int n = i2d_X509(((Certificate *)ref)->cert, &out);
	CFDataRef d = n > 0 ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_free(out);
	return d;
}
static CFStringRef copyASN1String(const ASN1_STRING *s)
{
	unsigned char *out = NULL;
	int len = ASN1_STRING_to_UTF8(&out, s);
	CFStringRef r =
	    len >= 0 ? CFStringCreateWithBytes(NULL, out, len, kCFStringEncodingUTF8, false) : NULL;
	OPENSSL_free(out);
	return r;
}
/* The last attribute of this type, as Apple's SecCertificateCopyCommonName. */
static CFStringRef copyName(X509_NAME *n, int nid)
{
	int i = -1, last = -1;
	while ((i = X509_NAME_get_index_by_NID(n, nid, i)) >= 0)
		last = i;
	if (last < 0)
		return NULL;
	return copyASN1String(X509_NAME_ENTRY_get_data(X509_NAME_get_entry(n, last)));
}
OSStatus SecCertificateCopyCommonName(SecCertificateRef c, CFStringRef *out)
{
	if (!out || !valid(c, SecCertificateGetTypeID()))
		return errSecParam;
	*out = copyName(X509_get_subject_name(((Certificate *)c)->cert), NID_commonName);
	return *out ? 0 : -26276 /* errSecInternal (SecBasePriv.h) */;
}
static CFArrayRef copySANStrings(X509 *x, int type)
{
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	GENERAL_NAMES *names = X509_get_ext_d2i(x, NID_subject_alt_name, NULL, NULL);
	for (int i = 0; names && i < sk_GENERAL_NAME_num(names); i++) {
		GENERAL_NAME *g = sk_GENERAL_NAME_value(names, i);
		if (g->type != type)
			continue;
		CFStringRef v = copyASN1String(g->d.ia5);
		if (v) {
			CFArrayAppendValue(a, v);
			CFRelease(v);
		}
	}
	GENERAL_NAMES_free(names);
	return a;
}
/* Subject summary, as Apple's: the common name, else an email address, else
 * the organizational unit or organization, else a DNS name. */
CFStringRef SecCertificateCopySubjectSummary(SecCertificateRef c)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return NULL;
	X509 *x = ((Certificate *)c)->cert;
	X509_NAME *n = X509_get_subject_name(x);
	CFStringRef r = copyName(n, NID_commonName);
	if (!r)
		r = copyName(n, NID_pkcs9_emailAddress);
	if (!r) {
		CFArrayRef e = copySANStrings(x, GEN_EMAIL);
		if (CFArrayGetCount(e))
			r = CFRetain(CFArrayGetValueAtIndex(e, 0));
		CFRelease(e);
	}
	if (!r)
		r = copyName(n, NID_organizationalUnitName);
	if (!r)
		r = copyName(n, NID_organizationName);
	if (!r) {
		CFArrayRef e = copySANStrings(x, GEN_DNS);
		if (CFArrayGetCount(e))
			r = CFRetain(CFArrayGetValueAtIndex(e, 0));
		CFRelease(e);
	}
	return r;
}
CFStringRef SecCertificateCopyLongDescription(CFAllocatorRef a, SecCertificateRef c, CFErrorRef *e)
{
	return SecCertificateCopySubjectSummary(c);
}
CFStringRef SecCertificateCopyShortDescription(CFAllocatorRef a, SecCertificateRef c, CFErrorRef *e)
{
	return SecCertificateCopySubjectSummary(c);
}
OSStatus SecCertificateCopyEmailAddresses(SecCertificateRef c, CFArrayRef *out)
{
	if (!out || !valid(c, SecCertificateGetTypeID()))
		return errSecParam;
	X509 *x = ((Certificate *)c)->cert;
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	X509_NAME *n = X509_get_subject_name(x);
	for (int i = -1; (i = X509_NAME_get_index_by_NID(n, NID_pkcs9_emailAddress, i)) >= 0;) {
		CFStringRef v = copyASN1String(X509_NAME_ENTRY_get_data(X509_NAME_get_entry(n, i)));
		if (v) {
			CFArrayAppendValue(a, v);
			CFRelease(v);
		}
	}
	CFArrayRef san = copySANStrings(x, GEN_EMAIL);
	CFArrayAppendArray(a, san, CFRangeMake(0, CFArrayGetCount(san)));
	CFRelease(san);
	*out = a;
	return 0;
}
CFDataRef SecCertificateCopySerialNumberData(SecCertificateRef c, CFErrorRef *e)
{
	if (!valid(c, SecCertificateGetTypeID())) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	const ASN1_INTEGER *s = X509_get0_serialNumber(((Certificate *)c)->cert);
	return CFDataCreate(NULL, ASN1_STRING_get0_data(s), ASN1_STRING_length(s));
}
CFDataRef SecCertificateCopySerialNumber(SecCertificateRef c, CFErrorRef *e)
{
	return SecCertificateCopySerialNumberData(c, e);
}
static CFAbsoluteTime asn1Time(const ASN1_TIME *t)
{
	struct tm tm;
	if (!t || !ASN1_TIME_to_tm(t, &tm))
		return 0;
	return (CFAbsoluteTime)timegm(&tm) - kCFAbsoluteTimeIntervalSince1970;
}
CFDateRef SecCertificateCopyNotValidBeforeDate(SecCertificateRef c)
{
	return valid(c, SecCertificateGetTypeID())
	    ? CFDateCreate(NULL, asn1Time(X509_get0_notBefore(((Certificate *)c)->cert)))
	    : NULL;
}
CFDateRef SecCertificateCopyNotValidAfterDate(SecCertificateRef c)
{
	return valid(c, SecCertificateGetTypeID())
	    ? CFDateCreate(NULL, asn1Time(X509_get0_notAfter(((Certificate *)c)->cert)))
	    : NULL;
}
CFDataRef SecCertificateCopyNormalizedIssuerSequence(SecCertificateRef c)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return NULL;
	unsigned char *out = NULL;
	int n = i2d_X509_NAME(X509_get_issuer_name(((Certificate *)c)->cert), &out);
	CFDataRef d = n > 0 ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_free(out);
	return d;
}
CFDataRef SecCertificateCopyNormalizedSubjectSequence(SecCertificateRef c)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return NULL;
	unsigned char *out = NULL;
	int n = i2d_X509_NAME(X509_get_subject_name(((Certificate *)c)->cert), &out);
	CFDataRef d = n > 0 ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_free(out);
	return d;
}
/* Internal accessors for the keychain. */
CFDataRef _SecCertificateCopyNameDER(SecCertificateRef c, bool issuer)
{
	return issuer ? SecCertificateCopyNormalizedIssuerSequence(c)
	              : SecCertificateCopyNormalizedSubjectSequence(c);
}
CFDataRef _SecCertificateCopyPublicKeySHA1(SecCertificateRef c)
{
	if (!valid(c, SecCertificateGetTypeID()))
		return NULL;
	unsigned char md[EVP_MAX_MD_SIZE];
	unsigned int n = 0;
	if (!X509_pubkey_digest(((Certificate *)c)->cert, EVP_sha1(), md, &n))
		return NULL;
	return CFDataCreate(NULL, md, n);
}
static SecKeyRef wrapKey(EVP_PKEY *p, bool secret)
{
	if (!p)
		return NULL;
	Key *k = (Key *)_SecCreateInstance(SecKeyGetTypeID(), sizeof(*k));
	if (!k) {
		EVP_PKEY_free(p);
		return NULL;
	}
	k->key = p;
	k->private = secret;
	return (SecKeyRef)k;
}
SecKeyRef SecCertificateCopyKey(SecCertificateRef c)
{
	return valid(c, SecCertificateGetTypeID())
	    ? wrapKey(X509_get_pubkey(((Certificate *)c)->cert), false)
	    : NULL;
}
OSStatus SecCertificateCopyPublicKey(SecCertificateRef c, SecKeyRef *out)
{
	if (!out)
		return errSecParam;
	*out = SecCertificateCopyKey(c);
	return *out ? 0 : errSecDecode;
}
SecKeyRef SecKeyCreateWithData(CFDataRef d, CFDictionaryRef attrs, CFErrorRef *e)
{
	if (!valid(d, CFDataGetTypeID()) || !valid(attrs, CFDictionaryGetTypeID())) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	bool secret = CFEqual(
	    CFDictionaryGetValue(attrs, kSecAttrKeyClass) ?: kCFNull, kSecAttrKeyClassPrivate);
	CFTypeRef type = CFDictionaryGetValue(attrs, kSecAttrKeyType);
	if (!type ||
	    (!CFEqual(type, kSecAttrKeyTypeRSA) &&
	        !CFEqual(type, kSecAttrKeyTypeECSECPrimeRandom))) {
		_SecSetError(e, errSecParam, CFSTR("Unsupported key type."));
		return NULL;
	}
	if (CFDictionaryGetValue(attrs, kSecAttrIsPermanent) == kCFBooleanTrue ||
	    CFDictionaryContainsKey(attrs, kSecAttrTokenID)) {
		_SecSetError(e, errSecNotAvailable,
		    CFSTR("Persistent and hardware keys need a keychain service."));
		return NULL;
	}
	const unsigned char *p = CFDataGetBytePtr(d), *start = p;
	long n = CFDataGetLength(d);
	EVP_PKEY *k = NULL;
	if (type && CFEqual(type, kSecAttrKeyTypeECSECPrimeRandom)) {
		long pub = secret ? (n == 97 ? 65 : n == 145 ? 97 : n == 199 ? 133 : 0) : n;
		int nid = pub == 65 ? NID_X9_62_prime256v1
		    : pub == 97     ? NID_secp384r1
		    : pub == 133    ? NID_secp521r1
		                    : 0;
		EC_KEY *ec = nid ? EC_KEY_new_by_curve_name(nid) : NULL;
		if (ec) {
			const EC_GROUP *g = EC_KEY_get0_group(ec);
			EC_POINT *point = EC_POINT_new(g);
			int ok = point && EC_POINT_oct2point(g, point, p, pub, NULL) &&
			    EC_KEY_set_public_key(ec, point);
			if (secret && ok) {
				BIGNUM *b = BN_bin2bn(p + pub, n - pub, NULL);
				ok = b && EC_KEY_set_private_key(ec, b);
				BN_clear_free(b);
			}
			if (ok && EC_KEY_check_key(ec)) {
				k = EVP_PKEY_new();
				EVP_PKEY_assign_EC_KEY(k, ec);
				ec = NULL;
			}
			EC_POINT_free(point);
			EC_KEY_free(ec);
		}
	} else {
		k = secret ? d2i_AutoPrivateKey(NULL, &p, n)
		           : d2i_PublicKey(EVP_PKEY_RSA, NULL, &p, n);
		if (!k && !secret) {
			p = start;
			k = d2i_PUBKEY(NULL, &p, n);
		}
		if (k && (p != start + n || EVP_PKEY_base_id(k) != EVP_PKEY_RSA)) {
			EVP_PKEY_free(k);
			k = NULL;
		}
	}
	if (!k) {
		_SecSetError(e, errSecParam, CFSTR("The key data could not be decoded."));
		return NULL;
	}
	return wrapKey(k, secret);
}
SecKeyRef SecKeyCreateRandomKey(CFDictionaryRef attrs, CFErrorRef *e)
{
	if (!valid(attrs, CFDictionaryGetTypeID())) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	CFTypeRef type = CFDictionaryGetValue(attrs, kSecAttrKeyType);
	if (!type ||
	    (!CFEqual(type, kSecAttrKeyTypeRSA) &&
	        !CFEqual(type, kSecAttrKeyTypeECSECPrimeRandom))) {
		_SecSetError(e, errSecParam, CFSTR("Unsupported key type."));
		return NULL;
	}
	if (CFDictionaryGetValue(attrs, kSecAttrIsPermanent) == kCFBooleanTrue ||
	    CFDictionaryContainsKey(attrs, kSecAttrTokenID)) {
		_SecSetError(e, errSecNotAvailable,
		    CFSTR("Persistent and hardware keys need a keychain service."));
		return NULL;
	}
	bool ec = type && CFEqual(type, kSecAttrKeyTypeECSECPrimeRandom);
	int bits = ec ? 256 : 2048;
	CFNumberRef value = CFDictionaryGetValue(attrs, kSecAttrKeySizeInBits);
	if (value && CFGetTypeID(value) == CFNumberGetTypeID())
		CFNumberGetValue(value, kCFNumberIntType, &bits);
	if ((ec && bits != 256 && bits != 384 && bits != 521) ||
	    (!ec && (bits < 1024 || bits > 8192))) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new_id(ec ? EVP_PKEY_EC : EVP_PKEY_RSA, NULL);
	EVP_PKEY *p = NULL;
	int ok = c && EVP_PKEY_keygen_init(c) > 0;
	if (ok)
		ok = ec ? EVP_PKEY_CTX_set_ec_paramgen_curve_nid(c,
		              bits == 256       ? NID_X9_62_prime256v1
		                  : bits == 384 ? NID_secp384r1
		                                : NID_secp521r1) > 0
		        : EVP_PKEY_CTX_set_rsa_keygen_bits(c, bits) > 0;
	if (ok)
		ok = EVP_PKEY_keygen(c, &p) > 0;
	EVP_PKEY_CTX_free(c);
	if (!ok) {
		EVP_PKEY_free(p);
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	return wrapKey(p, true);
}
CFDataRef SecKeyCopyExternalRepresentation(SecKeyRef ref, CFErrorRef *e)
{
	if (!valid(ref, SecKeyGetTypeID())) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	Key *k = (Key *)ref;
	unsigned char *out = NULL;
	int n = 0;
	CFDataRef result = NULL;
	if (EVP_PKEY_base_id(k->key) == EVP_PKEY_EC) {
		EC_KEY *ec = EVP_PKEY_get1_EC_KEY(k->key);
		const EC_GROUP *g = EC_KEY_get0_group(ec);
		size_t pub = EC_POINT_point2oct(
		    g, EC_KEY_get0_public_key(ec), POINT_CONVERSION_UNCOMPRESSED, NULL, 0, NULL);
		size_t bytes = (EC_GROUP_get_degree(g) + 7) / 8;
		out = OPENSSL_malloc(pub + (k->private ? bytes : 0));
		if (out) {
			EC_POINT_point2oct(g, EC_KEY_get0_public_key(ec),
			    POINT_CONVERSION_UNCOMPRESSED, out, pub, NULL);
			if (k->private)
				BN_bn2binpad(EC_KEY_get0_private_key(ec), out + pub, bytes);
			n = pub + (k->private ? bytes : 0);
		}
		EC_KEY_free(ec);
	} else
		n = k->private ? i2d_PrivateKey(k->key, &out) : i2d_PublicKey(k->key, &out);
	if (n > 0)
		result = CFDataCreate(NULL, out, n);
	OPENSSL_clear_free(out, n > 0 ? (size_t)n : 0);
	if (!result)
		_SecSetError(e, errSecDecode, NULL);
	return result;
}
SecKeyRef SecKeyCopyPublicKey(SecKeyRef ref)
{
	if (!valid(ref, SecKeyGetTypeID()))
		return NULL;
	unsigned char *out = NULL;
	int n = i2d_PUBKEY(((Key *)ref)->key, &out);
	const unsigned char *p = out;
	EVP_PKEY *k = n > 0 ? d2i_PUBKEY(NULL, &p, n) : NULL;
	OPENSSL_free(out);
	return wrapKey(k, false);
}
size_t SecKeyGetBlockSize(SecKeyRef ref)
{
	return valid(ref, SecKeyGetTypeID()) ? (EVP_PKEY_bits(((Key *)ref)->key) + 7) / 8 : 0;
}
/* Only named algorithms below are accepted. Unknown names never fall back to a
 * weaker hash or padding mode. */
typedef struct {
	const EVP_MD *md;
	int padding;
	bool message;
	bool ec;
	bool encrypt;
} Algorithm;
static bool algorithm(SecKeyAlgorithm a, Algorithm *out)
{
	if (!a || CFGetTypeID(a) != CFStringGetTypeID())
		return false;
	memset(out, 0, sizeof(*out));
#define ALG(symbol, hash, pad, msg, curve, enc)                                                    \
	if (CFEqual(a, symbol)) {                                                                  \
		*out = (Algorithm){hash, pad, msg, curve, enc};                                    \
		return true;                                                                       \
	}
#define RSASIG(H, md)                                                                              \
	ALG(kSecKeyAlgorithmRSASignatureMessagePKCS1v15##H, md, RSA_PKCS1_PADDING, true, false, false) \
	ALG(kSecKeyAlgorithmRSASignatureDigestPKCS1v15##H, md, RSA_PKCS1_PADDING, false, false, false) \
	ALG(kSecKeyAlgorithmRSASignatureMessagePSS##H, md, RSA_PKCS1_PSS_PADDING, true, false, false)  \
	ALG(kSecKeyAlgorithmRSASignatureDigestPSS##H, md, RSA_PKCS1_PSS_PADDING, false, false, false)  \
	ALG(kSecKeyAlgorithmECDSASignatureMessageX962##H, md, 0, true, true, false)                \
	ALG(kSecKeyAlgorithmECDSASignatureDigestX962##H, md, 0, false, true, false)                \
	ALG(kSecKeyAlgorithmRSAEncryptionOAEP##H, md, RSA_PKCS1_OAEP_PADDING, false, false, true)
	RSASIG(SHA1, EVP_sha1())
	RSASIG(SHA224, EVP_sha224())
	RSASIG(SHA256, EVP_sha256())
	RSASIG(SHA384, EVP_sha384())
	RSASIG(SHA512, EVP_sha512())
	ALG(kSecKeyAlgorithmECDSASignatureDigestX962, NULL, 0, false, true, false)
	ALG(kSecKeyAlgorithmECDSASignatureRFC4754, NULL, 0, false, true, false)
	ALG(kSecKeyAlgorithmRSAEncryptionPKCS1, NULL, RSA_PKCS1_PADDING, false, false, true)
	ALG(kSecKeyAlgorithmRSAEncryptionRaw, NULL, RSA_NO_PADDING, false, false, true)
	ALG(kSecKeyAlgorithmRSASignatureRaw, NULL, RSA_NO_PADDING, false, false, false)
	ALG(kSecKeyAlgorithmRSASignatureDigestPKCS1v15Raw, NULL, RSA_PKCS1_PADDING, false, false, false)
#undef RSASIG
#undef ALG
	return false;
}
static bool isEC(Key *k)
{
	return EVP_PKEY_base_id(k->key) == EVP_PKEY_EC;
}
/* The same answers Apple's gives: an RSA private key signs and verifies and
 * decrypts; an RSA public key verifies, encrypts and decrypts (raw RSA); an EC
 * private key signs and exchanges keys, an EC public key verifies. */
Boolean SecKeyIsAlgorithmSupported(SecKeyRef ref, SecKeyOperationType op, SecKeyAlgorithm alg)
{
	if (!valid(ref, SecKeyGetTypeID()))
		return false;
	Key *k = (Key *)ref;
	Algorithm a;
	if (op == kSecKeyOperationTypeKeyExchange)
		return isEC(k) && k->private &&
		    (CFEqual(alg, kSecKeyAlgorithmECDHKeyExchangeStandard) ||
		        CFEqual(alg, kSecKeyAlgorithmECDHKeyExchangeCofactor));
	if (!algorithm(alg, &a) || a.ec != isEC(k))
		return false;
	switch (op) {
	case kSecKeyOperationTypeSign:
		return !a.encrypt && k->private;
	case kSecKeyOperationTypeVerify:
		return !a.encrypt && (!k->private || !isEC(k));
	case kSecKeyOperationTypeEncrypt:
		return a.encrypt && !k->private;
	case kSecKeyOperationTypeDecrypt:
		return a.encrypt;
	default:
		return false;
	}
}
static int configure(EVP_PKEY_CTX *c, Algorithm a, bool crypt)
{
	int ok = 1;
	if (!a.ec) {
		ok = EVP_PKEY_CTX_set_rsa_padding(c, a.padding) > 0;
		if (ok && a.padding == RSA_PKCS1_PSS_PADDING)
			ok = EVP_PKEY_CTX_set_rsa_pss_saltlen(c, RSA_PSS_SALTLEN_DIGEST) > 0;
		if (ok && crypt && a.padding == RSA_PKCS1_OAEP_PADDING)
			ok = EVP_PKEY_CTX_set_rsa_oaep_md(c, a.md) > 0 &&
			    EVP_PKEY_CTX_set_rsa_mgf1_md(c, a.md) > 0;
	}
	/* PKCS#1 v1.5 signatures carry their DigestInfo in the input (pkcs1Input). */
	if (ok && !crypt && a.md && a.padding != RSA_PKCS1_PADDING)
		ok = EVP_PKEY_CTX_set_signature_md(c, a.md) > 0;
	return ok;
}
/* The bytes the key operates on: the digest (hashing a message first), and
 * for PKCS#1 v1.5 the DigestInfo around it. Apple's doesn't check the length
 * of a PKCS#1 digest; ECDSA and PSS digests must match the hash. */
static CFDataRef signInput(Algorithm a, CFDataRef d)
{
	if (!valid(d, CFDataGetTypeID()))
		return NULL;
	unsigned char buf[EVP_MAX_MD_SIZE];
	const unsigned char *p = CFDataGetBytePtr(d);
	size_t n = CFDataGetLength(d);
	if (a.message) {
		unsigned int len = 0;
		if (!EVP_Digest(p, n, buf, &len, a.md, NULL))
			return NULL;
		p = buf;
		n = len;
	} else if (a.md && a.padding != RSA_PKCS1_PADDING && n != (size_t)EVP_MD_get_size(a.md))
		return NULL;
	CFMutableDataRef out = CFDataCreateMutable(NULL, 0);
	if (a.padding == RSA_PKCS1_PADDING && a.md) {
		static const unsigned char sha1[] = {0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03,
		    0x02, 0x1a, 0x05, 0x00, 0x04, 0x14};
		unsigned char prefix[19] = {0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
		    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20};
		int nid = EVP_MD_get_type(a.md);
		if (nid == NID_sha1)
			CFDataAppendBytes(out, sha1, sizeof(sha1));
		else {
			int mdlen = EVP_MD_get_size(a.md);
			prefix[1] = 0x11 + mdlen;
			prefix[14] = nid == NID_sha256 ? 1 : nid == NID_sha384 ? 2 : nid == NID_sha512 ? 3 : 4;
			prefix[18] = mdlen;
			CFDataAppendBytes(out, prefix, sizeof(prefix));
		}
	}
	CFDataAppendBytes(out, p, n);
	return out;
}
CFDataRef SecKeyCreateSignature(SecKeyRef ref, SecKeyAlgorithm alg, CFDataRef data, CFErrorRef *e)
{
	Algorithm a;
	if (!SecKeyIsAlgorithmSupported(ref, kSecKeyOperationTypeSign, alg) ||
	    !algorithm(alg, &a)) {
		_SecSetError(e, errSecParam, CFSTR("Algorithm not supported by the key"));
		return NULL;
	}
	CFDataRef in = signInput(a, data);
	if (!in) {
		_SecSetError(e, errSecParam, NULL);
		return NULL;
	}
	const unsigned char *p = CFDataGetBytePtr(in);
	size_t n = CFDataGetLength(in);
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(((Key *)ref)->key, NULL);
	size_t size = 0;
	int ok = c && EVP_PKEY_sign_init(c) > 0 && configure(c, a, false) &&
	    EVP_PKEY_sign(c, NULL, &size, p, n) > 0;
	unsigned char *out = ok ? OPENSSL_malloc(size) : NULL;
	ok = out && EVP_PKEY_sign(c, out, &size, p, n) > 0;
	CFDataRef result = ok ? CFDataCreate(NULL, out, size) : NULL;
	OPENSSL_free(out);
	EVP_PKEY_CTX_free(c);
	CFRelease(in);
	if (!result)
		_SecSetError(e, errSecParam, NULL);
	return result;
}
Boolean SecKeyVerifySignature(
    SecKeyRef ref, SecKeyAlgorithm alg, CFDataRef data, CFDataRef sig, CFErrorRef *e)
{
	Algorithm a;
	if (!valid(sig, CFDataGetTypeID()) ||
	    !SecKeyIsAlgorithmSupported(ref, kSecKeyOperationTypeVerify, alg) ||
	    !algorithm(alg, &a))
		return _SecSetError(e, errSecParam, CFSTR("Algorithm not supported by the key"));
	CFDataRef in = signInput(a, data);
	if (!in)
		return _SecSetError(e, errSecParam, NULL);
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(((Key *)ref)->key, NULL);
	int ok = c && EVP_PKEY_verify_init(c) > 0 && configure(c, a, false) &&
	    EVP_PKEY_verify(c, CFDataGetBytePtr(sig), CFDataGetLength(sig), CFDataGetBytePtr(in),
	        CFDataGetLength(in)) == 1;
	EVP_PKEY_CTX_free(c);
	CFRelease(in);
	return ok ? true : _SecSetError(e, errSecVerifyFailed, NULL);
}
static CFDataRef keyCrypt(
    SecKeyRef ref, SecKeyAlgorithm alg, CFDataRef data, CFErrorRef *e, bool decrypt)
{
	Algorithm a;
	if (!valid(data, CFDataGetTypeID()) ||
	    !SecKeyIsAlgorithmSupported(
	        ref, decrypt ? kSecKeyOperationTypeDecrypt : kSecKeyOperationTypeEncrypt, alg) ||
	    !algorithm(alg, &a)) {
		_SecSetError(e, errSecParam, CFSTR("Algorithm not supported by the key"));
		return NULL;
	}
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(((Key *)ref)->key, NULL);
	int ok = c && (decrypt ? EVP_PKEY_decrypt_init(c) : EVP_PKEY_encrypt_init(c)) > 0 &&
	    configure(c, a, true);
	size_t n = 0;
	const unsigned char *p = CFDataGetBytePtr(data);
	size_t len = CFDataGetLength(data);
	if (ok)
		ok = (decrypt ? EVP_PKEY_decrypt(c, NULL, &n, p, len)
		              : EVP_PKEY_encrypt(c, NULL, &n, p, len)) > 0;
	unsigned char *out = ok ? OPENSSL_malloc(n) : NULL;
	if (out)
		ok = (decrypt ? EVP_PKEY_decrypt(c, out, &n, p, len)
		              : EVP_PKEY_encrypt(c, out, &n, p, len)) > 0;
	else
		ok = 0;
	CFDataRef r = ok ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_clear_free(out, n);
	EVP_PKEY_CTX_free(c);
	if (!r)
		_SecSetError(e, decrypt ? errSecDecode : errSecParam, NULL);
	return r;
}
CFDataRef SecKeyCreateEncryptedData(SecKeyRef k, SecKeyAlgorithm a, CFDataRef d, CFErrorRef *e)
{
	return keyCrypt(k, a, d, e, false);
}
CFDataRef SecKeyCreateDecryptedData(SecKeyRef k, SecKeyAlgorithm a, CFDataRef d, CFErrorRef *e)
{
	return keyCrypt(k, a, d, e, true);
}
CFDictionaryRef SecKeyCopyAttributes(SecKeyRef ref)
{
	if (!valid(ref, SecKeyGetTypeID()))
		return NULL;
	Key *k = (Key *)ref;
	int bits = EVP_PKEY_bits(k->key);
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &bits);
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	bool ec = isEC(k), priv = k->private;
	CFDictionarySetValue(d, kSecAttrKeyType, ec ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA);
	CFDictionarySetValue(d, kSecAttrKeyClass, priv ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic);
	CFDictionarySetValue(d, kSecAttrKeySizeInBits, n);
	CFDictionarySetValue(d, kSecAttrEffectiveKeySize, n);
	CFDictionarySetValue(d, kSecAttrCanEncrypt, !priv && !ec ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanDecrypt, priv && !ec ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanSign, priv ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanVerify, !priv ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanDerive, priv && ec ? kCFBooleanTrue : kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrIsPermanent, kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanWrap, kCFBooleanFalse);
	CFDictionarySetValue(d, kSecAttrCanUnwrap, kCFBooleanFalse);
	/* The application label is the SHA-1 of the public key bits, as Apple's. */
	SecKeyRef pub = priv ? SecKeyCopyPublicKey(ref) : (SecKeyRef)CFRetain(ref);
	CFDataRef bitsData = pub ? SecKeyCopyExternalRepresentation(pub, NULL) : NULL;
	if (bitsData) {
		unsigned char md[20];
		unsigned int len = 0;
		EVP_Digest(CFDataGetBytePtr(bitsData), CFDataGetLength(bitsData), md, &len, EVP_sha1(), NULL);
		CFDataRef label = CFDataCreate(NULL, md, len);
		CFDictionarySetValue(d, kSecAttrApplicationLabel, label);
		CFRelease(label);
		CFRelease(bitsData);
	}
	if (pub)
		CFRelease(pub);
	CFRelease(n);
	return d;
}
OSStatus SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey)
{
	CFErrorRef e = NULL;
	SecKeyRef priv = SecKeyCreateRandomKey(parameters, &e);
	if (!priv) {
		OSStatus st = e ? (OSStatus)CFErrorGetCode(e) : errSecParam;
		if (e)
			CFRelease(e);
		return st;
	}
	if (publicKey)
		*publicKey = SecKeyCopyPublicKey(priv);
	if (privateKey)
		*privateKey = priv;
	else
		CFRelease(priv);
	return 0;
}
SecPolicyRef SecPolicyCreateWithProperties(CFTypeRef oid, CFDictionaryRef properties)
{
	if (!valid(oid, CFStringGetTypeID()) ||
	    (properties && !valid(properties, CFDictionaryGetTypeID())))
		return NULL;
	Policy *p = (Policy *)_SecCreateInstance(SecPolicyGetTypeID(), sizeof(*p));
	CFMutableDictionaryRef d = properties
	    ? CFDictionaryCreateMutableCopy(NULL, 0, properties)
	    : CFDictionaryCreateMutable(
	          NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(d, kSecPolicyOid, oid);
	/* As Apple's: a server (non-client) policy doesn't record kSecPolicyClient. */
	if (CFDictionaryGetValue(d, kSecPolicyClient) == kCFBooleanFalse)
		CFDictionaryRemoveValue(d, kSecPolicyClient);
	p->properties = d;
	return (SecPolicyRef)p;
}
SecPolicyRef SecPolicyCreateBasicX509(void)
{
	return SecPolicyCreateWithProperties(kSecPolicyAppleX509Basic, NULL);
}
SecPolicyRef SecPolicyCreateSSL(Boolean server, CFStringRef hostname)
{
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (!server)
		CFDictionarySetValue(d, kSecPolicyClient, kCFBooleanTrue);
	if (hostname)
		CFDictionarySetValue(d, kSecPolicyName, hostname);
	SecPolicyRef p = SecPolicyCreateWithProperties(kSecPolicyAppleSSL, d);
	CFRelease(d);
	return p;
}
SecPolicyRef SecPolicyCreateWithOID(CFTypeRef oid)
{
	return SecPolicyCreateWithProperties(oid, NULL);
}
/* Revocation isn't checked (no network fetching, no OCSP responder cache):
 * the policy exists so it can be passed along, and constrains nothing. */
SecPolicyRef SecPolicyCreateRevocation(CFOptionFlags flags)
{
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberCFIndexType, &flags);
	CFDictionarySetValue(d, kSecPolicyRevocationFlags, n);
	CFRelease(n);
	SecPolicyRef p = SecPolicyCreateWithProperties(kSecPolicyAppleRevocation, d);
	CFRelease(d);
	return p;
}
CFDictionaryRef SecPolicyCopyProperties(SecPolicyRef p)
{
	return valid(p, SecPolicyGetTypeID()) ? CFRetain(((Policy *)p)->properties) : NULL;
}
static CFArrayRef asArray(CFTypeRef o, CFTypeID type)
{
	if (valid(o, type))
		return CFArrayCreate(NULL, &o, 1, &kCFTypeArrayCallBacks);
	if (!valid(o, CFArrayGetTypeID()) || CFArrayGetCount(o) == 0)
		return NULL;
	for (CFIndex i = 0; i < CFArrayGetCount(o); i++)
		if (!valid(CFArrayGetValueAtIndex(o, i), type))
			return NULL;
	return CFArrayCreateCopy(NULL, o);
}
OSStatus SecTrustCreateWithCertificates(CFTypeRef certs, CFTypeRef policies, SecTrustRef *out)
{
	if (!out)
		return errSecParam;
	*out = NULL;
	CFArrayRef c = asArray(certs, SecCertificateGetTypeID()),
	           p = asArray(policies, SecPolicyGetTypeID());
	if (!c || !p) {
		if (c)
			CFRelease(c);
		if (p)
			CFRelease(p);
		return errSecParam;
	}
	Trust *t = (Trust *)_SecCreateInstance(SecTrustGetTypeID(), sizeof(*t));
	t->certs = c;
	t->policies = p;
	t->result = kSecTrustResultInvalid;
	*out = (SecTrustRef)t;
	return 0;
}
OSStatus SecTrustSetAnchorCertificates(SecTrustRef ref, CFArrayRef anchors)
{
	if (!valid(ref, SecTrustGetTypeID()) || !valid(anchors, CFArrayGetTypeID()))
		return errSecParam;
	for (CFIndex i = 0; i < CFArrayGetCount(anchors); i++)
		if (!valid(CFArrayGetValueAtIndex(anchors, i), SecCertificateGetTypeID()))
			return errSecParam;
	Trust *t = (Trust *)ref;
	if (t->anchors)
		CFRelease(t->anchors);
	t->anchors = CFArrayCreateCopy(NULL, anchors);
	t->result = kSecTrustResultInvalid;
	return 0;
}
OSStatus SecTrustSetAnchorCertificatesOnly(SecTrustRef ref, Boolean only)
{
	return valid(ref, SecTrustGetTypeID()) ? 0 : errSecParam;
}
OSStatus SecTrustSetNetworkFetchAllowed(SecTrustRef ref, Boolean allowed)
{
	return valid(ref, SecTrustGetTypeID()) ? (allowed ? errSecUnimplemented : 0) : errSecParam;
}
OSStatus SecTrustSetVerifyDate(SecTrustRef ref, CFDateRef date)
{
	if (!valid(ref, SecTrustGetTypeID()) || !valid(date, CFDateGetTypeID()))
		return errSecParam;
	Trust *t = (Trust *)ref;
	if (t->date)
		CFRelease(t->date);
	t->date = CFRetain(date);
	t->result = kSecTrustResultInvalid;
	return 0;
}
/* OpenSSL's verification errors as Apple's trust errors. */
static OSStatus trustStatus(int err)
{
	switch (err) {
	case X509_V_OK:
		return 0;
	case X509_V_ERR_CERT_HAS_EXPIRED:
		return errSecCertificateExpired;
	case X509_V_ERR_CERT_NOT_YET_VALID:
		return errSecCertificateNotValidYet;
	case X509_V_ERR_HOSTNAME_MISMATCH:
	case X509_V_ERR_IP_ADDRESS_MISMATCH:
		return errSecHostNameMismatch;
	case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT:
	case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY:
	case X509_V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE:
		return errSecCreateChainFailed;
	case X509_V_ERR_INVALID_PURPOSE:
		return errSecInvalidExtendedKeyUsage;
	case X509_V_ERR_CERT_SIGNATURE_FAILURE:
		return errSecInvalidSignature;
	case X509_V_ERR_INVALID_CA:
		return errSecNoBasicConstraints;
	default:
		return errSecNotTrusted;
	}
}
static void setChain(Trust *t, STACK_OF(X509) *chain)
{
	if (t->chain)
		CFRelease(t->chain);
	t->chain = NULL;
	if (!chain)
		return;
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (int i = 0; i < sk_X509_num(chain); i++) {
		X509 *x = sk_X509_value(chain, i);
		SecCertificateRef found = NULL;
		/* Hand back the caller's objects where the chain uses them. */
		CFArrayRef pools[] = {t->certs, t->anchors};
		for (int p = 0; p < 2 && !found; p++)
			for (CFIndex j = 0; pools[p] && j < CFArrayGetCount(pools[p]) && !found; j++) {
				Certificate *c = (Certificate *)CFArrayGetValueAtIndex(pools[p], j);
				if (X509_cmp(c->cert, x) == 0)
					found = (SecCertificateRef)c;
			}
		if (found)
			CFArrayAppendValue(a, found);
		else {
			Certificate *c = (Certificate *)_SecCreateInstance(SecCertificateGetTypeID(), sizeof(*c));
			X509_up_ref(x);
			c->cert = x;
			CFArrayAppendValue(a, c);
			CFRelease(c);
		}
	}
	t->chain = a;
}
static bool evaluate(Trust *t)
{
	X509_STORE *s = X509_STORE_new();
	X509_STORE_CTX *c = X509_STORE_CTX_new();
	STACK_OF(X509) *chain = sk_X509_new_null();
	int ok = s && c && chain;
	int err = X509_V_ERR_UNSPECIFIED;
	/* There's no system root store (docs/design/SECURITY.md): only the anchors
	 * the caller sets are trusted. */
	for (CFIndex i = 0; ok && t->anchors && i < CFArrayGetCount(t->anchors); i++)
		X509_STORE_add_cert(s, ((Certificate *)CFArrayGetValueAtIndex(t->anchors, i))->cert);
	for (CFIndex i = 1; ok && i < CFArrayGetCount(t->certs); i++)
		sk_X509_push(chain, ((Certificate *)CFArrayGetValueAtIndex(t->certs, i))->cert);
	if (ok)
		ok = X509_STORE_CTX_init(c, s, ((Certificate *)CFArrayGetValueAtIndex(t->certs, 0))->cert, chain);
	if (ok) {
		X509_VERIFY_PARAM *p = X509_STORE_CTX_get0_param(c);
		time_t when = (time_t)((t->date ? CFDateGetAbsoluteTime(t->date) : CFAbsoluteTimeGetCurrent()) +
		    kCFAbsoluteTimeIntervalSince1970);
		X509_VERIFY_PARAM_set_time(p, when);
		for (CFIndex i = 0; ok && i < CFArrayGetCount(t->policies); i++) {
			CFDictionaryRef props = ((Policy *)CFArrayGetValueAtIndex(t->policies, i))->properties;
			CFTypeRef oid = CFDictionaryGetValue(props, kSecPolicyOid);
			if (CFEqual(oid, kSecPolicyAppleSSL)) {
				bool client = CFDictionaryGetValue(props, kSecPolicyClient) == kCFBooleanTrue;
				X509_VERIFY_PARAM_set_purpose(p, client ? X509_PURPOSE_SSL_CLIENT : X509_PURPOSE_SSL_SERVER);
				CFStringRef host = CFDictionaryGetValue(props, kSecPolicyName);
				char name[1024];
				if (host && CFStringGetCString(host, name, sizeof(name), kCFStringEncodingUTF8)) {
					ASN1_OCTET_STRING *ip = a2i_IPADDRESS(name);
					if (ip) {
						X509_VERIFY_PARAM_set1_ip_asc(p, name);
						ASN1_OCTET_STRING_free(ip);
					} else
						X509_VERIFY_PARAM_set1_host(p, name, 0);
				}
			} else if (CFEqual(oid, kSecPolicyAppleSMIME))
				X509_VERIFY_PARAM_set_purpose(p, X509_PURPOSE_SMIME_SIGN);
			else if (!CFEqual(oid, kSecPolicyAppleX509Basic) && !CFEqual(oid, kSecPolicyAppleRevocation) &&
			    !CFEqual(oid, kSecPolicyAppleCodeSigning)) {
				ok = 0;
				err = X509_V_ERR_UNSPECIFIED;
			}
		}
		if (ok) {
			ok = X509_verify_cert(c) == 1;
			err = X509_STORE_CTX_get_error(c);
		}
		STACK_OF(X509) *built = X509_STORE_CTX_get1_chain(c);
		setChain(t, built);
		OSSL_STACK_OF_X509_free(built);
	}
	t->status = ok ? 0 : trustStatus(err == X509_V_OK ? X509_V_ERR_UNSPECIFIED : err);
	t->result = ok ? kSecTrustResultUnspecified : kSecTrustResultRecoverableTrustFailure;
	sk_X509_free(chain);
	X509_STORE_CTX_free(c);
	X509_STORE_free(s);
	return ok;
}
bool SecTrustEvaluateWithError(SecTrustRef ref, CFErrorRef *e)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return _SecSetError(e, errSecParam, NULL);
	Trust *t = (Trust *)ref;
	if (evaluate(t))
		return true;
	CFStringRef msg = _SecCopyErrorString(t->status);
	_SecSetError(e, t->status, msg);
	if (msg)
		CFRelease(msg);
	return false;
}
OSStatus SecTrustEvaluate(SecTrustRef t, SecTrustResultType *out)
{
	if (!valid(t, SecTrustGetTypeID()))
		return errSecParam;
	evaluate((Trust *)t);
	if (out)
		*out = ((Trust *)t)->result;
	return 0;
}
OSStatus SecTrustEvaluateAsyncWithError(SecTrustRef t, dispatch_queue_t queue, SecTrustWithErrorCallback result)
{
	if (!valid(t, SecTrustGetTypeID()) || !queue || !result)
		return errSecParam;
	CFRetain(t);
	dispatch_async(queue, ^{
		CFErrorRef e = NULL;
		bool ok = SecTrustEvaluateWithError(t, &e);
		result(t, ok, e);
		if (e)
			CFRelease(e);
		CFRelease(t);
	});
	return 0;
}
OSStatus SecTrustGetTrustResult(SecTrustRef t, SecTrustResultType *out)
{
	if (!out || !valid(t, SecTrustGetTypeID()))
		return errSecParam;
	*out = ((Trust *)t)->result;
	return 0;
}
static CFArrayRef currentChain(Trust *t)
{
	return t->chain ? t->chain : t->certs;
}
CFIndex SecTrustGetCertificateCount(SecTrustRef t)
{
	return valid(t, SecTrustGetTypeID()) ? CFArrayGetCount(currentChain((Trust *)t)) : 0;
}
SecCertificateRef SecTrustGetCertificateAtIndex(SecTrustRef t, CFIndex i)
{
	return valid(t, SecTrustGetTypeID()) && i >= 0 && i < SecTrustGetCertificateCount(t)
	    ? (SecCertificateRef)CFArrayGetValueAtIndex(currentChain((Trust *)t), i)
	    : NULL;
}
CFArrayRef SecTrustCopyCertificateChain(SecTrustRef t)
{
	if (!valid(t, SecTrustGetTypeID()))
		return NULL;
	if (!((Trust *)t)->chain)
		evaluate((Trust *)t);
	return CFArrayCreateCopy(NULL, currentChain((Trust *)t));
}
CFDictionaryRef SecTrustCopyResult(SecTrustRef t)
{
	if (!valid(t, SecTrustGetTypeID()))
		return NULL;
	CFIndex r = ((Trust *)t)->result;
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberCFIndexType, &r);
	CFDictionaryRef d = CFDictionaryCreate(NULL, (const void *[]){kSecTrustResultValue}, (const void *[]){n}, 1,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(n);
	return d;
}
/* Serialized trust: a binary property list of the certificates, anchors,
 * policy properties and verify date. Finch's own format (Apple's is a DER
 * plist from securityd's encoding); round trips within Finch. */
CFDataRef SecTrustSerialize(SecTrustRef ref, CFErrorRef *error)
{
	if (!valid(ref, SecTrustGetTypeID())) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	Trust *t = (Trust *)ref;
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFArrayRef lists[] = {t->certs, t->anchors};
	CFStringRef names[] = {CFSTR("certificates"), CFSTR("anchors")};
	for (int i = 0; i < 2; i++) {
		if (!lists[i])
			continue;
		CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		for (CFIndex j = 0; j < CFArrayGetCount(lists[i]); j++) {
			CFDataRef der = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(lists[i], j));
			CFArrayAppendValue(a, der);
			CFRelease(der);
		}
		CFDictionarySetValue(d, names[i], a);
		CFRelease(a);
	}
	CFMutableArrayRef pols = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex j = 0; j < CFArrayGetCount(t->policies); j++)
		CFArrayAppendValue(pols, ((Policy *)CFArrayGetValueAtIndex(t->policies, j))->properties);
	CFDictionarySetValue(d, CFSTR("policies"), pols);
	CFRelease(pols);
	if (t->date)
		CFDictionarySetValue(d, CFSTR("date"), t->date);
	CFDataRef out = CFPropertyListCreateData(NULL, d, kCFPropertyListBinaryFormat_v1_0, 0, error);
	CFRelease(d);
	return out;
}
SecTrustRef SecTrustDeserialize(CFDataRef data, CFErrorRef *error)
{
	CFPropertyListRef d = valid(data, CFDataGetTypeID())
	    ? CFPropertyListCreateWithData(NULL, data, 0, NULL, NULL)
	    : NULL;
	SecTrustRef trust = NULL;
	if (d && CFGetTypeID(d) == CFDictionaryGetTypeID()) {
		CFArrayRef certData = CFDictionaryGetValue(d, CFSTR("certificates"));
		CFArrayRef anchorData = CFDictionaryGetValue(d, CFSTR("anchors"));
		CFArrayRef polProps = CFDictionaryGetValue(d, CFSTR("policies"));
		CFMutableArrayRef certs = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		CFMutableArrayRef anchors = anchorData ? CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks) : NULL;
		CFMutableArrayRef pols = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		bool ok = valid(certData, CFArrayGetTypeID()) && valid(polProps, CFArrayGetTypeID());
		for (int pass = 0; ok && pass < 2; pass++) {
			CFArrayRef src = pass ? anchorData : certData;
			CFMutableArrayRef dst = pass ? anchors : certs;
			for (CFIndex i = 0; ok && src && i < CFArrayGetCount(src); i++) {
				SecCertificateRef c = SecCertificateCreateWithData(NULL, CFArrayGetValueAtIndex(src, i));
				ok = c != NULL;
				if (c) {
					CFArrayAppendValue(dst, c);
					CFRelease(c);
				}
			}
		}
		for (CFIndex i = 0; ok && i < CFArrayGetCount(polProps); i++) {
			CFDictionaryRef props = CFArrayGetValueAtIndex(polProps, i);
			ok = valid(props, CFDictionaryGetTypeID()) && CFDictionaryGetValue(props, kSecPolicyOid);
			if (ok) {
				SecPolicyRef p = SecPolicyCreateWithProperties(CFDictionaryGetValue(props, kSecPolicyOid), props);
				CFArrayAppendValue(pols, p);
				CFRelease(p);
			}
		}
		if (ok && SecTrustCreateWithCertificates(certs, pols, &trust) == 0) {
			if (anchors)
				SecTrustSetAnchorCertificates(trust, anchors);
			CFDateRef date = CFDictionaryGetValue(d, CFSTR("date"));
			if (valid(date, CFDateGetTypeID()))
				SecTrustSetVerifyDate(trust, date);
		}
		CFRelease(certs);
		CFRelease(pols);
		if (anchors)
			CFRelease(anchors);
	}
	if (d)
		CFRelease(d);
	if (!trust)
		_SecSetError(error, errSecDecode, NULL);
	return trust;
}
SecKeyRef SecTrustCopyKey(SecTrustRef t)
{
	return SecCertificateCopyKey(SecTrustGetCertificateAtIndex(t, 0));
}
SecKeyRef SecTrustCopyPublicKey(SecTrustRef t)
{
	return SecTrustCopyKey(t);
}
OSStatus SecTrustSetPolicies(SecTrustRef ref, CFTypeRef policies)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return errSecParam;
	CFArrayRef p = asArray(policies, SecPolicyGetTypeID());
	if (!p)
		return errSecParam;
	Trust *t = (Trust *)ref;
	CFRelease(t->policies);
	t->policies = p;
	t->result = kSecTrustResultInvalid;
	return 0;
}
OSStatus SecTrustCopyPolicies(SecTrustRef ref, CFArrayRef *out)
{
	if (!valid(ref, SecTrustGetTypeID()) || !out)
		return errSecParam;
	*out = CFArrayCreateCopy(NULL, ((Trust *)ref)->policies);
	return 0;
}
OSStatus SecTrustCopyCustomAnchorCertificates(SecTrustRef ref, CFArrayRef *out)
{
	if (!valid(ref, SecTrustGetTypeID()) || !out)
		return errSecParam;
	*out = ((Trust *)ref)->anchors ? CFArrayCreateCopy(NULL, ((Trust *)ref)->anchors) : NULL;
	return 0;
}
CFAbsoluteTime SecTrustGetVerifyTime(SecTrustRef ref)
{
	if (!valid(ref, SecTrustGetTypeID()))
		return 0;
	return ((Trust *)ref)->date ? CFDateGetAbsoluteTime(((Trust *)ref)->date)
	                            : CFAbsoluteTimeGetCurrent();
}
/* SecCertificateCopyValues: the property dictionaries Apple's returns, keyed
 * by OID, each {type, label, value}. Sections hold arrays of properties. */
static CFDictionaryRef property(CFStringRef type, CFStringRef label, CFTypeRef value)
{
	const void *keys[] = {kSecPropertyKeyType, kSecPropertyKeyLabel, kSecPropertyKeyValue};
	const void *values[] = {type, label, value};
	return CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
}
static void addProperty(CFMutableArrayRef a, CFStringRef type, CFStringRef label, CFTypeRef value)
{
	if (!value)
		return;
	CFDictionaryRef d = property(type, label, value);
	CFArrayAppendValue(a, d);
	CFRelease(d);
}
static CFStringRef copyOIDString(const ASN1_OBJECT *o)
{
	char buf[128];
	OBJ_obj2txt(buf, sizeof(buf), o, 1);
	return CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
}
static CFArrayRef copyNameProperties(X509_NAME *n)
{
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (int i = 0; i < X509_NAME_entry_count(n); i++) {
		X509_NAME_ENTRY *e = X509_NAME_get_entry(n, i);
		CFStringRef label = copyOIDString(X509_NAME_ENTRY_get_object(e));
		CFStringRef value = copyASN1String(X509_NAME_ENTRY_get_data(e));
		addProperty(a, kSecPropertyTypeString, label, value);
		CFRelease(label);
		if (value)
			CFRelease(value);
	}
	return a;
}
static CFStringRef copyHexString(const unsigned char *p, size_t n)
{
	CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
	for (size_t i = 0; i < n; i++)
		CFStringAppendFormat(s, NULL, i ? CFSTR(" %02X") : CFSTR("%02X"), p[i]);
	return s;
}
static void setValue(CFMutableDictionaryRef d, CFArrayRef wanted, CFStringRef oid, CFStringRef type,
    CFStringRef label, CFTypeRef value)
{
	if (!value || (wanted && !CFArrayContainsValue(wanted, CFRangeMake(0, CFArrayGetCount(wanted)), oid)))
		return;
	CFDictionaryRef p = property(type, label, value);
	CFDictionarySetValue(d, oid, p);
	CFRelease(p);
}
CFDictionaryRef SecCertificateCopyValues(SecCertificateRef ref, CFArrayRef oids, CFErrorRef *error)
{
	if (!valid(ref, SecCertificateGetTypeID()) || (oids && !valid(oids, CFArrayGetTypeID()))) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	X509 *x = ((Certificate *)ref)->cert;
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(
	    NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef version = CFStringCreateWithFormat(NULL, NULL, CFSTR("%ld"), X509_get_version(x) + 1);
	setValue(d, oids, kSecOIDX509V1Version, kSecPropertyTypeString, CFSTR("Version"), version);
	CFRelease(version);
	const ASN1_INTEGER *serial = X509_get0_serialNumber(x);
	CFStringRef sn = copyHexString(ASN1_STRING_get0_data(serial), ASN1_STRING_length(serial));
	setValue(d, oids, kSecOIDX509V1SerialNumber, kSecPropertyTypeString, CFSTR("Serial Number"), sn);
	CFRelease(sn);
	CFArrayRef subject = copyNameProperties(X509_get_subject_name(x));
	setValue(d, oids, kSecOIDX509V1SubjectName, kSecPropertyTypeSection, CFSTR("Subject Name"), subject);
	CFRelease(subject);
	CFArrayRef issuer = copyNameProperties(X509_get_issuer_name(x));
	setValue(d, oids, kSecOIDX509V1IssuerName, kSecPropertyTypeSection, CFSTR("Issuer Name"), issuer);
	CFRelease(issuer);
	CFAbsoluteTime nb = asn1Time(X509_get0_notBefore(x)), na = asn1Time(X509_get0_notAfter(x));
	CFNumberRef nbn = CFNumberCreate(NULL, kCFNumberDoubleType, &nb);
	CFNumberRef nan = CFNumberCreate(NULL, kCFNumberDoubleType, &na);
	setValue(d, oids, kSecOIDX509V1ValidityNotBefore, kSecPropertyTypeNumber, CFSTR("Not Valid Before"), nbn);
	setValue(d, oids, kSecOIDX509V1ValidityNotAfter, kSecPropertyTypeNumber, CFSTR("Not Valid After"), nan);
	CFRelease(nbn);
	CFRelease(nan);
	const X509_ALGOR *alg = NULL;
	X509_get0_signature(NULL, &alg, x);
	if (alg) {
		CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		const ASN1_OBJECT *obj = NULL;
		X509_ALGOR_get0(&obj, NULL, NULL, alg);
		CFStringRef o = copyOIDString(obj);
		addProperty(a, kSecPropertyTypeString, CFSTR("Algorithm"), o);
		CFRelease(o);
		setValue(d, oids, kSecOIDX509V1SignatureAlgorithm, kSecPropertyTypeSection,
		    CFSTR("Signature Algorithm"), a);
		CFRelease(a);
	}
	/* Extensions: each a section of its printed form. */
	for (int i = 0; i < X509_get_ext_count(x); i++) {
		X509_EXTENSION *ext = X509_get_ext(x, i);
		CFStringRef oid = copyOIDString(X509_EXTENSION_get_object(ext));
		CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		addProperty(a, kSecPropertyTypeString, CFSTR("Critical"),
		    X509_EXTENSION_get_critical(ext) ? CFSTR("Yes") : CFSTR("No"));
		BIO *bio = BIO_new(BIO_s_mem());
		if (bio && X509V3_EXT_print(bio, ext, 0, 0) > 0) {
			char *text = NULL;
			long len = BIO_get_mem_data(bio, &text);
			CFStringRef v = CFStringCreateWithBytes(NULL, (const UInt8 *)text, len, kCFStringEncodingUTF8, false);
			addProperty(a, kSecPropertyTypeString, CFSTR("Value"), v);
			if (v)
				CFRelease(v);
		}
		BIO_free(bio);
		setValue(d, oids, oid, kSecPropertyTypeSection, oid, a);
		CFRelease(a);
		CFRelease(oid);
	}
	return d;
}
CFDataRef SecKeyCopyKeyExchangeResult(SecKeyRef ref, SecKeyAlgorithm alg, SecKeyRef other,
    CFDictionaryRef parameters, CFErrorRef *error)
{
	if (!SecKeyIsAlgorithmSupported(ref, kSecKeyOperationTypeKeyExchange, alg) ||
	    !valid(other, SecKeyGetTypeID())) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	EVP_PKEY_CTX *c = EVP_PKEY_CTX_new(((Key *)ref)->key, NULL);
	size_t n = 0;
	int ok = c && EVP_PKEY_derive_init(c) > 0 &&
	    EVP_PKEY_derive_set_peer(c, ((Key *)other)->key) > 0 &&
	    EVP_PKEY_derive(c, NULL, &n) > 0;
	unsigned char *out = ok ? OPENSSL_malloc(n) : NULL;
	ok = out && EVP_PKEY_derive(c, out, &n) > 0;
	CFDataRef result = ok ? CFDataCreate(NULL, out, n) : NULL;
	OPENSSL_clear_free(out, n);
	EVP_PKEY_CTX_free(c);
	if (!result)
		_SecSetError(error, errSecParam, NULL);
	return result;
}
