/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's keychain: SecItem and the SecKeychain calls over a file store.
 *
 * There is no securityd and no encryption yet (docs/design/SECURITY.md). A
 * keychain is a binary property list, readable only by its owner (0600 in a
 * 0700 directory), holding each item's attributes (under Apple's attribute
 * keys: acct, svce, labl, ...) and its secret (v_Data). The default keychain
 * is ~/Library/Keychains/login.keychain-finch. Every call reads the file
 * under an flock(2), so processes see each other's changes. Items behave as
 * on macOS's file keychains: the same primary keys (errSecDuplicateItem), the
 * same match and return rules, errSecItemNotFound when nothing matches.
 */
#include "SecInternal.h"
#include <Security/SecKeychainSearch.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <pwd.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static bool isType(CFTypeRef o, CFTypeID t)
{
	return o && CFGetTypeID(o) == t;
}

/* ---- Keychain and item objects ---- */

typedef struct {
	CFRuntimeBase base;
	CFStringRef path;
} Keychain;

typedef struct {
	CFRuntimeBase base;
	SecKeychainRef keychain;
	CFStringRef itemClass;
	int64_t id;
} Item;

static void keychainFree(CFTypeRef o)
{
	CFRelease(((Keychain *)o)->path);
}
static Boolean keychainEqual(CFTypeRef a, CFTypeRef b)
{
	return CFEqual(((Keychain *)a)->path, ((Keychain *)b)->path);
}
static CFHashCode keychainHash(CFTypeRef a)
{
	return CFHash(((Keychain *)a)->path);
}
static CFStringRef keychainDescription(CFTypeRef o)
{
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SecKeychain %p: %@>"), o, ((Keychain *)o)->path);
}
CFTypeID SecKeychainGetTypeID(void)
{
	static CFTypeID id;
	static const CFRuntimeClass cls = {0, "SecKeychain", NULL, NULL, keychainFree, keychainEqual,
	    keychainHash, NULL, keychainDescription};
	return _SecRegisterClass(&id, &cls);
}
static void itemFree(CFTypeRef o)
{
	CFRelease(((Item *)o)->keychain);
	CFRelease(((Item *)o)->itemClass);
}
static Boolean itemEqual(CFTypeRef a, CFTypeRef b)
{
	return ((Item *)a)->id == ((Item *)b)->id && CFEqual(((Item *)a)->keychain, ((Item *)b)->keychain);
}
static CFHashCode itemHash(CFTypeRef a)
{
	return (CFHashCode)((Item *)a)->id;
}
SEC_DEFINE_TYPE(SecKeychainItemGetTypeID, "SecKeychainItem", itemFree, itemEqual, itemHash)

static CFStringRef homeDirectory(void)
{
	const char *home = getenv("HOME");
	if (!home || !*home) {
		struct passwd *pw = getpwuid(getuid());
		home = pw ? pw->pw_dir : "/var/root";
	}
	return CFStringCreateWithCString(NULL, home, kCFStringEncodingUTF8);
}

/* Relative keychain paths are relative to ~/Library/Keychains, as Apple's. */
static CFStringRef absolutePath(const char *path)
{
	if (path[0] == '/')
		return CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
	CFStringRef home = homeDirectory();
	CFStringRef p = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/Library/Keychains/%s"), home, path);
	CFRelease(home);
	return p;
}

static SecKeychainRef keychainCreate(CFStringRef path)
{
	Keychain *k = (Keychain *)_SecCreateInstance(SecKeychainGetTypeID(), sizeof(*k));
	k->path = CFRetain(path);
	return (SecKeychainRef)k;
}

static SecKeychainRef defaultKeychain(void)
{
	CFStringRef home = homeDirectory();
	CFStringRef p = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/Library/Keychains/login.keychain-finch"), home);
	SecKeychainRef k = keychainCreate(p);
	CFRelease(p);
	CFRelease(home);
	return k;
}

static bool pathOf(SecKeychainRef kc, char *buf, size_t size)
{
	return CFStringGetFileSystemRepresentation(((Keychain *)kc)->path, buf, size);
}

/* ---- The file ---- */

typedef struct {
	int fd;
	CFMutableDictionaryRef db;
	CFMutableArrayRef items;
	bool dirty;
} Store;

static void mkdirs(const char *path)
{
	char dir[PATH_MAX];
	strlcpy(dir, path, sizeof(dir));
	char *slash = strrchr(dir, '/');
	if (!slash || slash == dir)
		return;
	*slash = 0;
	struct stat st;
	if (stat(dir, &st) == 0)
		return;
	mkdirs(dir);
	mkdir(dir, 0700);
}

/* Opens a keychain file, locked. create: make it if missing (the default
 * keychain is made on first write). */
static OSStatus storeOpen(SecKeychainRef kc, bool write, bool create, Store *s)
{
	char path[PATH_MAX];
	memset(s, 0, sizeof(*s));
	s->fd = -1;
	if (!pathOf(kc, path, sizeof(path)))
		return errSecParam;
	if (create)
		mkdirs(path);
	s->fd = open(path, (write ? O_RDWR : O_RDONLY) | (create ? O_CREAT : 0) | O_CLOEXEC, 0600);
	if (s->fd < 0)
		return errno == ENOENT ? errSecNoSuchKeychain : errSecIO;
	if (flock(s->fd, write ? LOCK_EX : LOCK_SH) < 0) {
		close(s->fd);
		s->fd = -1;
		return errSecIO;
	}
	struct stat st;
	fstat(s->fd, &st);
	if (st.st_size > 0) {
		CFMutableDataRef d = CFDataCreateMutable(NULL, st.st_size);
		CFDataSetLength(d, st.st_size);
		ssize_t n = pread(s->fd, CFDataGetMutableBytePtr(d), st.st_size, 0);
		CFPropertyListRef p = n == st.st_size
		    ? CFPropertyListCreateWithData(NULL, d, kCFPropertyListMutableContainersAndLeaves, NULL, NULL)
		    : NULL;
		CFRelease(d);
		if (!p || !isType(p, CFDictionaryGetTypeID()) ||
		    !isType(CFDictionaryGetValue(p, CFSTR("items")), CFArrayGetTypeID())) {
			if (p)
				CFRelease(p);
			close(s->fd);
			s->fd = -1;
			return errSecInvalidKeychain;
		}
		s->db = (CFMutableDictionaryRef)p;
		s->items = (CFMutableArrayRef)CFDictionaryGetValue(s->db, CFSTR("items"));
	} else {
		s->db = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		s->items = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		CFDictionarySetValue(s->db, CFSTR("items"), s->items);
		CFRelease(s->items);
		int v = 1;
		CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
		CFDictionarySetValue(s->db, CFSTR("version"), n);
		CFRelease(n);
		s->dirty = write;
	}
	return 0;
}

static OSStatus storeClose(Store *s)
{
	OSStatus st = 0;
	if (s->fd >= 0 && s->dirty) {
		CFDataRef d = CFPropertyListCreateData(NULL, s->db, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
		if (!d || ftruncate(s->fd, 0) < 0 ||
		    pwrite(s->fd, CFDataGetBytePtr(d), CFDataGetLength(d), 0) != CFDataGetLength(d))
			st = errSecIO;
		else
			fsync(s->fd);
		if (d)
			CFRelease(d);
	}
	if (s->db)
		CFRelease(s->db);
	if (s->fd >= 0)
		close(s->fd);
	s->fd = -1;
	s->db = NULL;
	return st;
}

static int64_t nextID(Store *s)
{
	int64_t n = 1;
	CFNumberRef v = CFDictionaryGetValue(s->db, CFSTR("next"));
	if (isType(v, CFNumberGetTypeID()))
		CFNumberGetValue(v, kCFNumberSInt64Type, &n);
	int64_t next = n + 1;
	CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt64Type, &next);
	CFDictionarySetValue(s->db, CFSTR("next"), nv);
	CFRelease(nv);
	return n;
}

static int64_t itemID(CFDictionaryRef item)
{
	int64_t n = 0;
	CFNumberRef v = CFDictionaryGetValue(item, CFSTR("_id"));
	if (isType(v, CFNumberGetTypeID()))
		CFNumberGetValue(v, kCFNumberSInt64Type, &n);
	return n;
}

static CFIndex findID(Store *s, int64_t id)
{
	for (CFIndex i = 0; i < CFArrayGetCount(s->items); i++)
		if (itemID(CFArrayGetValueAtIndex(s->items, i)) == id)
			return i;
	return kCFNotFound;
}

/* ---- Callbacks ---- */

typedef struct Callback {
	SecKeychainCallback fn;
	SecKeychainEventMask mask;
	void *context;
	struct Callback *next;
} Callback;
static Callback *callbacks;
static pthread_mutex_t callbackLock = PTHREAD_MUTEX_INITIALIZER;

static void notify(SecKeychainEvent event, SecKeychainRef kc, SecKeychainItemRef item)
{
	pthread_mutex_lock(&callbackLock);
	for (Callback *c = callbacks; c; c = c->next) {
		if (!(c->mask & (1u << event)))
			continue;
		SecKeychainCallback fn = c->fn;
		void *ctx = c->context;
		if (kc)
			CFRetain(kc);
		if (item)
			CFRetain(item);
		dispatch_async(dispatch_get_main_queue(), ^{
			SecKeychainCallbackInfo info = {SEC_KEYCHAIN_SETTINGS_VERS1, item, kc, getpid()};
			fn(event, &info, ctx);
			if (kc)
				CFRelease(kc);
			if (item)
				CFRelease(item);
		});
	}
	pthread_mutex_unlock(&callbackLock);
}

OSStatus SecKeychainAddCallback(SecKeychainCallback fn, SecKeychainEventMask mask, void *context)
{
	if (!fn)
		return errSecParam;
	pthread_mutex_lock(&callbackLock);
	for (Callback *c = callbacks; c; c = c->next)
		if (c->fn == fn) {
			pthread_mutex_unlock(&callbackLock);
			return errSecDuplicateCallback;
		}
	Callback *c = calloc(1, sizeof(*c));
	*c = (Callback){fn, mask, context, callbacks};
	callbacks = c;
	pthread_mutex_unlock(&callbackLock);
	return 0;
}

OSStatus SecKeychainRemoveCallback(SecKeychainCallback fn)
{
	pthread_mutex_lock(&callbackLock);
	for (Callback **p = &callbacks; *p; p = &(*p)->next)
		if ((*p)->fn == fn) {
			Callback *c = *p;
			*p = c->next;
			free(c);
			pthread_mutex_unlock(&callbackLock);
			return 0;
		}
	pthread_mutex_unlock(&callbackLock);
	return errSecInvalidCallback;
}

/* ---- Keychain calls ---- */

static atomic_bool interactionAllowed = true;

OSStatus SecKeychainGetUserInteractionAllowed(Boolean *state)
{
	if (!state)
		return errSecParam;
	*state = atomic_load(&interactionAllowed);
	return 0;
}

OSStatus SecKeychainSetUserInteractionAllowed(Boolean state)
{
	atomic_store(&interactionAllowed, state);
	return 0;
}

OSStatus SecKeychainCreate(const char *pathName, UInt32 passwordLength, const void *password,
    Boolean promptUser, SecAccessRef initialAccess, SecKeychainRef *keychain)
{
	if (!pathName || !keychain)
		return errSecParam;
	*keychain = NULL;
	CFStringRef path = absolutePath(pathName);
	SecKeychainRef kc = keychainCreate(path);
	CFRelease(path);
	char p[PATH_MAX];
	pathOf(kc, p, sizeof(p));
	mkdirs(p);
	int fd = open(p, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
	if (fd < 0) {
		CFRelease(kc);
		return errno == EEXIST ? errSecDuplicateKeychain : errSecIO;
	}
	close(fd);
	Store s;
	OSStatus st = storeOpen(kc, true, false, &s);
	if (st == 0)
		st = storeClose(&s);
	if (st) {
		CFRelease(kc);
		return st;
	}
	*keychain = kc;
	notify(kSecKeychainListChangedEvent, kc, NULL);
	return 0;
}

OSStatus SecKeychainOpen(const char *pathName, SecKeychainRef *keychain)
{
	if (!pathName || !keychain)
		return errSecParam;
	CFStringRef path = absolutePath(pathName);
	*keychain = keychainCreate(path);
	CFRelease(path);
	return 0;
}

OSStatus SecKeychainDelete(SecKeychainRef keychainOrArray)
{
	if (!keychainOrArray)
		return errSecInvalidKeychain;
	if (isType(keychainOrArray, CFArrayGetTypeID())) {
		CFArrayRef a = (CFArrayRef)keychainOrArray;
		for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
			OSStatus st = SecKeychainDelete((SecKeychainRef)CFArrayGetValueAtIndex(a, i));
			if (st)
				return st;
		}
		return 0;
	}
	if (!isType(keychainOrArray, SecKeychainGetTypeID()))
		return errSecInvalidKeychain;
	char p[PATH_MAX];
	pathOf(keychainOrArray, p, sizeof(p));
	if (unlink(p) < 0)
		return errSecNoSuchKeychain;
	notify(kSecKeychainListChangedEvent, keychainOrArray, NULL);
	return 0;
}

OSStatus SecKeychainCopyDefault(SecKeychainRef *keychain)
{
	if (!keychain)
		return errSecParam;
	*keychain = defaultKeychain();
	return 0;
}

OSStatus SecKeychainCopyDomainDefault(SecPreferencesDomain domain, SecKeychainRef *keychain)
{
	return SecKeychainCopyDefault(keychain);
}

OSStatus SecKeychainCopyLogin(SecKeychainRef *keychain)
{
	return SecKeychainCopyDefault(keychain);
}

OSStatus SecKeychainSetDefault(SecKeychainRef keychain)
{
	return isType(keychain, SecKeychainGetTypeID()) ? 0 : errSecParam;
}

OSStatus SecKeychainCopySearchList(CFArrayRef *searchList)
{
	if (!searchList)
		return errSecParam;
	SecKeychainRef kc = defaultKeychain();
	*searchList = CFArrayCreate(NULL, (const void **)&kc, 1, &kCFTypeArrayCallBacks);
	CFRelease(kc);
	return 0;
}

OSStatus SecKeychainCopyDomainSearchList(SecPreferencesDomain domain, CFArrayRef *searchList)
{
	return SecKeychainCopySearchList(searchList);
}

OSStatus SecKeychainSetSearchList(CFArrayRef searchList)
{
	return isType(searchList, CFArrayGetTypeID()) ? 0 : errSecParam;
}

OSStatus SecKeychainGetPath(SecKeychainRef keychain, UInt32 *ioPathLength, char *pathName)
{
	if (!ioPathLength || !pathName)
		return errSecParam;
	SecKeychainRef kc = keychain ? (SecKeychainRef)CFRetain(keychain) : defaultKeychain();
	if (!isType(kc, SecKeychainGetTypeID())) {
		CFRelease(kc);
		return errSecInvalidKeychain;
	}
	char p[PATH_MAX];
	pathOf(kc, p, sizeof(p));
	CFRelease(kc);
	size_t n = strlen(p);
	if (n + 1 > *ioPathLength)
		return errSecBufferTooSmall;
	memcpy(pathName, p, n + 1);
	*ioPathLength = (UInt32)n;
	return 0;
}

OSStatus SecKeychainGetStatus(SecKeychainRef keychain, SecKeychainStatus *status)
{
	if (!status)
		return errSecParam;
	SecKeychainRef kc = keychain ? (SecKeychainRef)CFRetain(keychain) : defaultKeychain();
	char p[PATH_MAX];
	pathOf(kc, p, sizeof(p));
	CFRelease(kc);
	if (access(p, F_OK) < 0)
		return errSecNoSuchKeychain;
	*status = kSecUnlockStateStatus | (access(p, R_OK) == 0 ? kSecReadPermStatus : 0) |
	    (access(p, W_OK) == 0 ? kSecWritePermStatus : 0);
	return 0;
}

/* Finch's keychains aren't encrypted: locking and unlocking always succeed. */
OSStatus SecKeychainLock(SecKeychainRef keychain)
{
	return 0;
}
OSStatus SecKeychainLockAll(void)
{
	return 0;
}
OSStatus SecKeychainUnlock(SecKeychainRef keychain, UInt32 passwordLength, const void *password, Boolean usePassword)
{
	return 0;
}
OSStatus SecKeychainGetVersion(UInt32 *returnVers)
{
	if (!returnVers)
		return errSecParam;
	*returnVers = 0x00010000;
	return 0;
}
OSStatus SecKeychainGetPreferenceDomain(SecPreferencesDomain *domain)
{
	if (!domain)
		return errSecParam;
	*domain = kSecPreferencesDomainUser;
	return 0;
}
OSStatus SecKeychainSetPreferenceDomain(SecPreferencesDomain domain)
{
	return 0;
}

/* ---- Items: attributes and matching ---- */

static CFStringRef const kClass = CFSTR("class");
static CFStringRef const kID = CFSTR("_id");
static CFStringRef const kSync = CFSTR("sync");

static bool isClass(CFTypeRef c)
{
	return isType(c, CFStringGetTypeID()) &&
	    (CFEqual(c, kSecClassGenericPassword) || CFEqual(c, kSecClassInternetPassword) ||
	        CFEqual(c, kSecClassCertificate) || CFEqual(c, kSecClassKey) || CFEqual(c, kSecClassIdentity));
}

/* Attribute keys are Apple's four-letter (or so) names; query controls have
 * prefixes (r_, m_, u_, v_) or are class. */
static bool isAttributeKey(CFStringRef k)
{
	if (!isType(k, CFStringGetTypeID()) || CFEqual(k, kClass))
		return false;
	if (CFStringGetLength(k) > 2 && CFStringGetCharacterAtIndex(k, 1) == '_')
		return false;
	return true;
}

static const CFStringRef *primaryKeys(CFStringRef cls)
{
	static const CFStringRef genp[] = {CFSTR("acct"), CFSTR("svce"), NULL};
	static const CFStringRef inet[] = {CFSTR("acct"), CFSTR("sdmn"), CFSTR("srvr"), CFSTR("ptcl"),
	    CFSTR("atyp"), CFSTR("port"), CFSTR("path"), NULL};
	static const CFStringRef cert[] = {CFSTR("ctyp"), CFSTR("issr"), CFSTR("slnr"), NULL};
	static const CFStringRef keys[] = {CFSTR("kcls"), CFSTR("klbl"), CFSTR("atag"), CFSTR("type"), CFSTR("bsiz"), NULL};
	if (CFEqual(cls, kSecClassGenericPassword))
		return genp;
	if (CFEqual(cls, kSecClassInternetPassword))
		return inet;
	if (CFEqual(cls, kSecClassCertificate))
		return cert;
	return keys;
}

static bool sameValue(CFTypeRef a, CFTypeRef b)
{
	if (!a || !b)
		return a == b;
	/* A port or type given as a number matches a stored number. */
	return CFEqual(a, b);
}

static bool duplicate(Store *s, CFDictionaryRef item, int64_t except)
{
	CFStringRef cls = CFDictionaryGetValue(item, kClass);
	const CFStringRef *keys = primaryKeys(cls);
	for (CFIndex i = 0; i < CFArrayGetCount(s->items); i++) {
		CFDictionaryRef other = CFArrayGetValueAtIndex(s->items, i);
		if (itemID(other) == except || !CFEqual(CFDictionaryGetValue(other, kClass), cls))
			continue;
		bool same = sameValue(CFDictionaryGetValue(item, kSync), CFDictionaryGetValue(other, kSync)) ||
		    (!CFDictionaryGetValue(item, kSync) && CFDictionaryGetValue(other, kSync) == kCFBooleanFalse);
		for (int k = 0; same && keys[k]; k++)
			same = sameValue(CFDictionaryGetValue(item, keys[k]), CFDictionaryGetValue(other, keys[k]));
		if (same)
			return true;
	}
	return false;
}

/* What a search covers: the keychains and the filters. */
typedef struct {
	CFStringRef itemClass;   /* NULL: any (persistent-reference lookups) */
	CFMutableArrayRef keychains;
	CFDictionaryRef query;
	int64_t onlyID;          /* a persistent reference or item ref: that item */
	SecKeychainRef onlyKeychain;
	CFDataRef certData;      /* kSecValueRef of a certificate */
	CFIndex limit;           /* -1: all */
	bool syncAny, syncOnly;
} Search;

static CFDataRef persistentRef(SecKeychainRef kc, int64_t id)
{
	CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
	CFDataAppendBytes(d, (const UInt8 *)"FNKC", 4);
	CFDataAppendBytes(d, (const UInt8 *)&id, sizeof(id));
	char p[PATH_MAX];
	pathOf(kc, p, sizeof(p));
	CFDataAppendBytes(d, (const UInt8 *)p, strlen(p));
	return d;
}

static bool parsePersistentRef(CFDataRef d, SecKeychainRef *kc, int64_t *id)
{
	if (!isType(d, CFDataGetTypeID()) || CFDataGetLength(d) <= 12 || memcmp(CFDataGetBytePtr(d), "FNKC", 4))
		return false;
	memcpy(id, CFDataGetBytePtr(d) + 4, sizeof(*id));
	CFStringRef path = CFStringCreateWithBytes(NULL, CFDataGetBytePtr(d) + 12, CFDataGetLength(d) - 12,
	    kCFStringEncodingUTF8, false);
	if (!path)
		return false;
	*kc = keychainCreate(path);
	CFRelease(path);
	return true;
}

static OSStatus searchInit(Search *s, CFDictionaryRef query, bool defaultAll)
{
	memset(s, 0, sizeof(*s));
	s->query = query;
	s->limit = defaultAll ? -1 : 1;
	s->keychains = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFTypeRef pref = CFDictionaryGetValue(query, kSecValuePersistentRef);
	CFTypeRef vref = CFDictionaryGetValue(query, kSecValueRef);
	if (pref) {
		if (!parsePersistentRef(pref, &s->onlyKeychain, &s->onlyID))
			return errSecItemNotFound;
		CFArrayAppendValue(s->keychains, s->onlyKeychain);
	} else if (vref && isType(vref, SecKeychainItemGetTypeID())) {
		Item *it = (Item *)vref;
		s->onlyID = it->id;
		s->onlyKeychain = (SecKeychainRef)CFRetain(it->keychain);
		s->itemClass = it->itemClass;
		CFArrayAppendValue(s->keychains, it->keychain);
	}
	if (!s->onlyID) {
		s->itemClass = CFDictionaryGetValue(query, kClass);
		if (!isClass(s->itemClass))
			return errSecParam;
		if (vref && isType(vref, SecCertificateGetTypeID()))
			s->certData = SecCertificateCopyData((SecCertificateRef)vref);
		CFTypeRef list = CFDictionaryGetValue(query, kSecMatchSearchList);
		CFTypeRef use = CFDictionaryGetValue(query, kSecUseKeychain);
		if (isType(list, CFArrayGetTypeID())) {
			for (CFIndex i = 0; i < CFArrayGetCount(list); i++)
				if (isType(CFArrayGetValueAtIndex(list, i), SecKeychainGetTypeID()))
					CFArrayAppendValue(s->keychains, CFArrayGetValueAtIndex(list, i));
		} else if (isType(use, SecKeychainGetTypeID()))
			CFArrayAppendValue(s->keychains, use);
		else {
			SecKeychainRef kc = defaultKeychain();
			CFArrayAppendValue(s->keychains, kc);
			CFRelease(kc);
		}
	}
	CFTypeRef limit = CFDictionaryGetValue(query, kSecMatchLimit);
	if (limit) {
		if (CFEqual(limit, kSecMatchLimitAll))
			s->limit = -1;
		else if (CFEqual(limit, kSecMatchLimitOne))
			s->limit = 1;
		else if (isType(limit, CFNumberGetTypeID()))
			CFNumberGetValue(limit, kCFNumberCFIndexType, &s->limit);
		else
			return errSecParam;
	}
	CFTypeRef sync = CFDictionaryGetValue(query, kSecAttrSynchronizable);
	if (sync && CFEqual(sync, kSecAttrSynchronizableAny))
		s->syncAny = true;
	else if (sync == kCFBooleanTrue || (isType(sync, CFNumberGetTypeID()) && CFBooleanGetValue(sync)))
		s->syncOnly = true;
	return 0;
}

static void searchFree(Search *s)
{
	if (s->keychains)
		CFRelease(s->keychains);
	if (s->onlyKeychain)
		CFRelease(s->onlyKeychain);
	if (s->certData)
		CFRelease(s->certData);
}

static bool truthy(CFTypeRef v)
{
	if (v == kCFBooleanTrue)
		return true;
	if (isType(v, CFNumberGetTypeID())) {
		int n = 0;
		CFNumberGetValue(v, kCFNumberIntType, &n);
		return n != 0;
	}
	return false;
}

static bool matches(Search *s, CFDictionaryRef item)
{
	if (s->onlyID)
		return itemID(item) == s->onlyID;
	if (!CFEqual(CFDictionaryGetValue(item, kClass), s->itemClass))
		return false;
	bool synced = truthy(CFDictionaryGetValue(item, kSync));
	if (!s->syncAny && synced != s->syncOnly)
		return false;
	if (s->certData && !sameValue(CFDictionaryGetValue(item, kSecValueData), s->certData))
		return false;
	CFIndex n = CFDictionaryGetCount(s->query);
	const void **keys = malloc(sizeof(void *) * n), **values = malloc(sizeof(void *) * n);
	CFDictionaryGetKeysAndValues(s->query, keys, values);
	bool ok = true;
	for (CFIndex i = 0; ok && i < n; i++) {
		if (!isAttributeKey(keys[i]) || CFEqual(keys[i], kSync) || CFEqual(keys[i], kSecAttrAccess) ||
		    CFEqual(keys[i], kSecAttrAccessGroup) || CFEqual(keys[i], kSecAttrAccessible) ||
		    CFEqual(keys[i], kSecAttrAccessControl) || CFEqual(keys[i], CFSTR("nleg")))
			continue;
		ok = sameValue(CFDictionaryGetValue(item, keys[i]), values[i]);
	}
	free(keys);
	free(values);
	return ok;
}

/* ---- Results ---- */

static CFTypeRef refFor(SecKeychainRef kc, CFDictionaryRef item);

static CFDictionaryRef attributesOf(CFDictionaryRef item)
{
	CFMutableDictionaryRef a = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFIndex n = CFDictionaryGetCount(item);
	const void **keys = malloc(sizeof(void *) * n), **values = malloc(sizeof(void *) * n);
	CFDictionaryGetKeysAndValues(item, keys, values);
	for (CFIndex i = 0; i < n; i++)
		if ((isAttributeKey(keys[i]) && !CFEqual(keys[i], kID)) || CFEqual(keys[i], kClass))
			CFDictionarySetValue(a, keys[i], values[i]);
	free(keys);
	free(values);
	return a;
}

/* One result in the shape the query asks for: a single return type gives
 * that value, several a dictionary. */
static CFTypeRef resultFor(CFDictionaryRef query, SecKeychainRef kc, CFDictionaryRef item)
{
	bool data = truthy(CFDictionaryGetValue(query, kSecReturnData));
	bool attrs = truthy(CFDictionaryGetValue(query, kSecReturnAttributes));
	bool ref = truthy(CFDictionaryGetValue(query, kSecReturnRef));
	bool pref = truthy(CFDictionaryGetValue(query, kSecReturnPersistentRef));
	int count = data + attrs + ref + pref;
	if (count == 0)
		return refFor(kc, item);
	if (count == 1) {
		if (data) {
			CFTypeRef v = CFDictionaryGetValue(item, kSecValueData);
			return v ? CFRetain(v) : CFDataCreate(NULL, NULL, 0);
		}
		if (attrs)
			return attributesOf(item);
		if (ref)
			return refFor(kc, item);
		return persistentRef(kc, itemID(item));
	}
	CFMutableDictionaryRef d;
	if (attrs) {
		CFDictionaryRef a = attributesOf(item);
		d = CFDictionaryCreateMutableCopy(NULL, 0, a);
		CFRelease(a);
	} else
		d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (data) {
		CFTypeRef v = CFDictionaryGetValue(item, kSecValueData);
		if (v)
			CFDictionarySetValue(d, kSecValueData, v);
	}
	if (ref) {
		CFTypeRef r = refFor(kc, item);
		if (r) {
			CFDictionarySetValue(d, kSecValueRef, r);
			CFRelease(r);
		}
	}
	if (pref) {
		CFDataRef p = persistentRef(kc, itemID(item));
		CFDictionarySetValue(d, kSecValuePersistentRef, p);
		CFRelease(p);
	}
	return d;
}

/* ---- Certificates, keys and identities in the store ---- */

static void setNumber(CFMutableDictionaryRef d, CFStringRef k, int v)
{
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
	CFDictionarySetValue(d, k, n);
	CFRelease(n);
}

static void certificateAttributes(CFMutableDictionaryRef item, SecCertificateRef c)
{
	CFDataRef der = SecCertificateCopyData(c);
	CFDictionarySetValue(item, kSecValueData, der);
	CFRelease(der);
	setNumber(item, CFSTR("ctyp"), 1);   /* CSSM_CERT_X_509v3 */
	setNumber(item, CFSTR("cenc"), 3);   /* CSSM_CERT_ENCODING_DER */
	if (!CFDictionaryGetValue(item, CFSTR("labl"))) {
		CFStringRef label = SecCertificateCopySubjectSummary(c);
		if (label) {
			CFDictionarySetValue(item, CFSTR("labl"), label);
			CFRelease(label);
		}
	}
	CFDataRef subj = _SecCertificateCopyNameDER(c, false), issr = _SecCertificateCopyNameDER(c, true);
	CFDataRef slnr = SecCertificateCopySerialNumberData(c, NULL), pkhh = _SecCertificateCopyPublicKeySHA1(c);
	if (subj) { CFDictionarySetValue(item, CFSTR("subj"), subj); CFRelease(subj); }
	if (issr) { CFDictionarySetValue(item, CFSTR("issr"), issr); CFRelease(issr); }
	if (slnr) { CFDictionarySetValue(item, CFSTR("slnr"), slnr); CFRelease(slnr); }
	if (pkhh) { CFDictionarySetValue(item, CFSTR("pkhh"), pkhh); CFRelease(pkhh); }
	CFArrayRef emails = NULL;
	if (SecCertificateCopyEmailAddresses(c, &emails) == 0 && emails) {
		if (CFArrayGetCount(emails))
			CFDictionarySetValue(item, CFSTR("alis"), CFArrayGetValueAtIndex(emails, 0));
		CFRelease(emails);
	}
}

static void keyAttributes(CFMutableDictionaryRef item, SecKeyRef k)
{
	CFDictionaryRef a = SecKeyCopyAttributes(k);
	CFDataRef ext = SecKeyCopyExternalRepresentation(k, NULL);
	if (ext) {
		CFDictionarySetValue(item, kSecValueData, ext);
		CFRelease(ext);
	}
	CFStringRef copy[] = {kSecAttrKeyType, kSecAttrKeyClass, kSecAttrKeySizeInBits, kSecAttrEffectiveKeySize,
	    kSecAttrApplicationLabel, kSecAttrCanEncrypt, kSecAttrCanDecrypt, kSecAttrCanSign, kSecAttrCanVerify,
	    kSecAttrCanDerive};
	for (size_t i = 0; a && i < sizeof(copy) / sizeof(*copy); i++)
		if (!CFDictionaryGetValue(item, copy[i]) && CFDictionaryGetValue(a, copy[i]))
			CFDictionarySetValue(item, copy[i], CFDictionaryGetValue(a, copy[i]));
	CFDictionarySetValue(item, kSecAttrIsPermanent, kCFBooleanTrue);
	if (a)
		CFRelease(a);
}

static SecKeyRef keyFromItem(CFDictionaryRef item)
{
	CFDataRef d = CFDictionaryGetValue(item, kSecValueData);
	if (!d)
		return NULL;
	CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef keys[] = {kSecAttrKeyType, kSecAttrKeyClass};
	for (int i = 0; i < 2; i++) {
		CFTypeRef v = CFDictionaryGetValue(item, keys[i]);
		if (v)
			CFDictionarySetValue(attrs, keys[i], v);
	}
	SecKeyRef k = SecKeyCreateWithData(d, attrs, NULL);
	CFRelease(attrs);
	return k;
}

static CFTypeRef refFor(SecKeychainRef kc, CFDictionaryRef item)
{
	CFStringRef cls = CFDictionaryGetValue(item, kClass);
	if (CFEqual(cls, kSecClassCertificate))
		return SecCertificateCreateWithData(NULL, CFDictionaryGetValue(item, kSecValueData));
	if (CFEqual(cls, kSecClassKey))
		return keyFromItem(item);
	if (CFEqual(cls, kSecClassIdentity)) {
		SecCertificateRef c = SecCertificateCreateWithData(NULL, CFDictionaryGetValue(item, kSecValueData));
		CFDictionaryRef keyItem = CFDictionaryGetValue(item, CFSTR("_key"));
		SecKeyRef k = keyItem ? keyFromItem(keyItem) : NULL;
		SecIdentityRef ident = c && k ? _SecIdentityCreate(c, k) : NULL;
		if (c)
			CFRelease(c);
		if (k)
			CFRelease(k);
		return ident;
	}
	Item *it = (Item *)_SecCreateInstance(SecKeychainItemGetTypeID(), sizeof(*it));
	it->keychain = (SecKeychainRef)CFRetain(kc);
	it->itemClass = CFRetain(cls);
	it->id = itemID(item);
	return (CFTypeRef)it;
}

/* Identities aren't stored: they're certificates whose public key matches a
 * private key's application label. The search yields synthetic items. */
static CFArrayRef identitiesIn(Store *st)
{
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(st->items); i++) {
		CFDictionaryRef cert = CFArrayGetValueAtIndex(st->items, i);
		if (!CFEqual(CFDictionaryGetValue(cert, kClass), kSecClassCertificate))
			continue;
		CFDataRef pkhh = CFDictionaryGetValue(cert, CFSTR("pkhh"));
		for (CFIndex j = 0; pkhh && j < CFArrayGetCount(st->items); j++) {
			CFDictionaryRef key = CFArrayGetValueAtIndex(st->items, j);
			if (!CFEqual(CFDictionaryGetValue(key, kClass), kSecClassKey) ||
			    !sameValue(CFDictionaryGetValue(key, kSecAttrKeyClass), kSecAttrKeyClassPrivate) ||
			    !sameValue(CFDictionaryGetValue(key, kSecAttrApplicationLabel), pkhh))
				continue;
			CFMutableDictionaryRef ident = CFDictionaryCreateMutableCopy(NULL, 0, cert);
			CFDictionarySetValue(ident, kClass, kSecClassIdentity);
			CFDictionarySetValue(ident, CFSTR("_key"), key);
			CFArrayAppendValue(out, ident);
			CFRelease(ident);
		}
	}
	return out;
}

/* ---- SecItem ---- */

typedef OSStatus (^ItemVisitor)(Store *store, SecKeychainRef kc, CFMutableDictionaryRef item, CFIndex index, bool *stop);

/* Runs visit on each matching item, in each keychain of the search. */
static OSStatus forEachMatch(Search *s, bool write, CFIndex *found, ItemVisitor visit)
{
	*found = 0;
	bool stop = false;
	for (CFIndex k = 0; !stop && k < CFArrayGetCount(s->keychains); k++) {
		SecKeychainRef kc = (SecKeychainRef)CFArrayGetValueAtIndex(s->keychains, k);
		Store st;
		OSStatus err = storeOpen(kc, write, false, &st);
		if (err == errSecNoSuchKeychain)
			continue;
		if (err)
			return err;
		/* A snapshot: visitors may remove items (they find them by ID). */
		CFArrayRef idents = s->itemClass && CFEqual(s->itemClass, kSecClassIdentity)
		    ? identitiesIn(&st)
		    : CFArrayCreateCopy(NULL, st.items);
		CFArrayRef pool = idents;
		for (CFIndex i = 0; !stop && i < CFArrayGetCount(pool); i++) {
			CFMutableDictionaryRef item = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(pool, i);
			if (!matches(s, item))
				continue;
			err = visit(&st, kc, item, findID(&st, itemID(item)), &stop);
			if (err) {
				CFRelease(idents);
				storeClose(&st);
				return err;
			}
			(*found)++;
			if (s->limit > 0 && *found >= s->limit)
				stop = true;
		}
		CFRelease(idents);
		err = storeClose(&st);
		if (err)
			return err;
	}
	return 0;
}

OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result)
{
	if (result)
		*result = NULL;
	if (!isType(query, CFDictionaryGetTypeID()))
		return errSecParam;
	Search s;
	OSStatus err = searchInit(&s, query, false);
	if (err) {
		searchFree(&s);
		return err;
	}
	/* Apple's file keychains don't return the data of more than one item. */
	if (s.limit != 1 && truthy(CFDictionaryGetValue(query, kSecReturnData))) {
		searchFree(&s);
		return errSecParam;
	}
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFIndex found = 0;
	err = forEachMatch(&s, false, &found, ^OSStatus(Store *st, SecKeychainRef kc, CFMutableDictionaryRef item, CFIndex i, bool *stop) {
		if (result) {
			CFTypeRef r = resultFor(query, kc, item);
			if (r) {
				CFArrayAppendValue(out, r);
				CFRelease(r);
			}
		}
		return 0;
	});
	bool one = s.limit == 1;
	searchFree(&s);
	if (!err && found == 0)
		err = errSecItemNotFound;
	if (!err && result) {
		if (one)
			*result = CFArrayGetCount(out) ? CFRetain(CFArrayGetValueAtIndex(out, 0)) : NULL;
		else
			*result = CFRetain(out);
	}
	CFRelease(out);
	return err;
}

static CFAbsoluteTime now(void)
{
	return CFAbsoluteTimeGetCurrent();
}

/* Adds a prepared item (class, attributes, v_Data) to a keychain. */
static OSStatus addItem(SecKeychainRef kc, CFMutableDictionaryRef item, CFDictionaryRef query, CFTypeRef *result,
    SecKeychainItemRef *itemRef)
{
	Store st;
	OSStatus err = storeOpen(kc, true, true, &st);
	if (err)
		return err;
	if (duplicate(&st, item, 0)) {
		storeClose(&st);
		return errSecDuplicateItem;
	}
	int64_t id = nextID(&st);
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
	CFDictionarySetValue(item, kID, n);
	CFRelease(n);
	CFDateRef date = CFDateCreate(NULL, now());
	if (!CFDictionaryGetValue(item, CFSTR("cdat")))
		CFDictionarySetValue(item, CFSTR("cdat"), date);
	CFDictionarySetValue(item, CFSTR("mdat"), date);
	CFRelease(date);
	CFArrayAppendValue(st.items, item);
	st.dirty = true;
	err = storeClose(&st);
	if (err)
		return err;
	if (result && query)
		*result = resultFor(query, kc, item);
	CFTypeRef ref = refFor(kc, item);
	if (itemRef)
		*itemRef = isType(ref, SecKeychainItemGetTypeID()) ? (SecKeychainItemRef)CFRetain(ref) : NULL;
	notify(kSecAddEvent, kc, isType(ref, SecKeychainItemGetTypeID()) ? (SecKeychainItemRef)ref : NULL);
	if (ref)
		CFRelease(ref);
	return 0;
}

static void copyAttributes(CFMutableDictionaryRef item, CFDictionaryRef attrs)
{
	CFIndex n = CFDictionaryGetCount(attrs);
	const void **keys = malloc(sizeof(void *) * n), **values = malloc(sizeof(void *) * n);
	CFDictionaryGetKeysAndValues(attrs, keys, values);
	for (CFIndex i = 0; i < n; i++) {
		if (CFEqual(keys[i], kSecValueData))
			CFDictionarySetValue(item, keys[i], values[i]);
		else if (isAttributeKey(keys[i]) && !CFEqual(keys[i], kSecAttrAccess) &&
		    !CFEqual(keys[i], kSecAttrAccessControl) && !CFEqual(keys[i], kID) &&
		    !CFEqual(keys[i], CFSTR("_key"))) {
			if (CFEqual(keys[i], kSync) && CFEqual(values[i], kSecAttrSynchronizableAny))
				continue;
			CFDictionarySetValue(item, keys[i], values[i]);
		}
	}
	free(keys);
	free(values);
}

static void defaultLabel(CFMutableDictionaryRef item)
{
	CFStringRef cls = CFDictionaryGetValue(item, kClass);
	if (CFDictionaryGetValue(item, CFSTR("labl")))
		return;
	CFTypeRef v = CFEqual(cls, kSecClassGenericPassword) ? CFDictionaryGetValue(item, CFSTR("svce"))
	    : CFEqual(cls, kSecClassInternetPassword)        ? CFDictionaryGetValue(item, CFSTR("srvr"))
	                                                     : NULL;
	if (v)
		CFDictionarySetValue(item, CFSTR("labl"), v);
}

OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result)
{
	if (result)
		*result = NULL;
	if (!isType(attributes, CFDictionaryGetTypeID()))
		return errSecParam;
	CFStringRef cls = CFDictionaryGetValue(attributes, kClass);
	CFTypeRef value = CFDictionaryGetValue(attributes, kSecValueRef);
	if (!cls && value) {
		cls = isType(value, SecCertificateGetTypeID()) ? kSecClassCertificate
		    : isType(value, SecKeyGetTypeID())          ? kSecClassKey
		    : isType(value, SecIdentityGetTypeID())     ? kSecClassIdentity
		                                                : NULL;
	}
	if (!isClass(cls))
		return errSecParam;
	SecKeychainRef kc = NULL;
	CFTypeRef use = CFDictionaryGetValue(attributes, kSecUseKeychain);
	kc = isType(use, SecKeychainGetTypeID()) ? (SecKeychainRef)CFRetain(use) : defaultKeychain();
	if (CFEqual(cls, kSecClassIdentity)) {
		/* An identity is stored as its certificate and its private key. */
		SecCertificateRef c = NULL;
		SecKeyRef k = NULL;
		OSStatus err = isType(value, SecIdentityGetTypeID()) ? SecIdentityCopyCertificate((SecIdentityRef)value, &c) : errSecParam;
		if (!err)
			err = SecIdentityCopyPrivateKey((SecIdentityRef)value, &k);
		if (!err) {
			CFMutableDictionaryRef ci = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			CFDictionarySetValue(ci, kClass, kSecClassCertificate);
			certificateAttributes(ci, c);
			err = addItem(kc, ci, NULL, NULL, NULL);
			CFRelease(ci);
			if (!err || err == errSecDuplicateItem) {
				CFMutableDictionaryRef ki = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
				CFDictionarySetValue(ki, kClass, kSecClassKey);
				keyAttributes(ki, k);
				OSStatus kerr = addItem(kc, ki, NULL, NULL, NULL);
				CFRelease(ki);
				err = err ? err : kerr;
			}
		}
		if (c)
			CFRelease(c);
		if (k)
			CFRelease(k);
		if (!err && result)
			*result = CFRetain(value);
		CFRelease(kc);
		return err;
	}
	CFMutableDictionaryRef item = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(item, kClass, cls);
	copyAttributes(item, attributes);
	OSStatus err = 0;
	if (CFEqual(cls, kSecClassCertificate)) {
		SecCertificateRef c = isType(value, SecCertificateGetTypeID()) ? (SecCertificateRef)CFRetain(value)
		    : isType(CFDictionaryGetValue(attributes, kSecValueData), CFDataGetTypeID())
		    ? SecCertificateCreateWithData(NULL, CFDictionaryGetValue(attributes, kSecValueData))
		    : NULL;
		if (c) {
			certificateAttributes(item, c);
			CFRelease(c);
		} else
			err = errSecParam;
	} else if (CFEqual(cls, kSecClassKey)) {
		if (isType(value, SecKeyGetTypeID()))
			keyAttributes(item, (SecKeyRef)value);
		else if (!CFDictionaryGetValue(item, kSecValueData))
			err = errSecParam;
	} else {
		defaultLabel(item);
		if (!CFDictionaryGetValue(item, kSecValueData)) {
			CFDataRef empty = CFDataCreate(NULL, NULL, 0);
			CFDictionarySetValue(item, kSecValueData, empty);
			CFRelease(empty);
		}
	}
	if (!err)
		err = addItem(kc, item, attributes, result, NULL);
	CFRelease(item);
	CFRelease(kc);
	return err;
}

OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate)
{
	if (!isType(query, CFDictionaryGetTypeID()) || !isType(attributesToUpdate, CFDictionaryGetTypeID()))
		return errSecParam;
	Search s;
	OSStatus err = searchInit(&s, query, true);
	if (err) {
		searchFree(&s);
		return err;
	}
	CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFIndex found = 0;
	err = forEachMatch(&s, true, &found, ^OSStatus(Store *st, SecKeychainRef kc, CFMutableDictionaryRef item, CFIndex i, bool *stop) {
		if (i == kCFNotFound)
			return errSecItemNotFound;
		/* (An identity updates its certificate.) */
		CFMutableDictionaryRef updated = CFDictionaryCreateMutableCopy(NULL, 0, CFArrayGetValueAtIndex(st->items, i));
		copyAttributes(updated, attributesToUpdate);
		if (duplicate(st, updated, itemID(item))) {
			CFRelease(updated);
			return errSecDuplicateItem;
		}
		CFDateRef date = CFDateCreate(NULL, now());
		CFDictionarySetValue(updated, CFSTR("mdat"), date);
		CFRelease(date);
		CFArraySetValueAtIndex(st->items, i, updated);
		st->dirty = true;
		CFTypeRef ref = refFor(kc, updated);
		if (isType(ref, SecKeychainItemGetTypeID()))
			CFArrayAppendValue(changed, ref);
		if (ref)
			CFRelease(ref);
		CFRelease(updated);
		return 0;
	});
	searchFree(&s);
	if (!err && found == 0)
		err = errSecItemNotFound;
	for (CFIndex i = 0; !err && i < CFArrayGetCount(changed); i++) {
		Item *it = (Item *)CFArrayGetValueAtIndex(changed, i);
		notify(kSecUpdateEvent, it->keychain, (SecKeychainItemRef)it);
	}
	CFRelease(changed);
	return err;
}

OSStatus SecItemDelete(CFDictionaryRef query)
{
	if (!isType(query, CFDictionaryGetTypeID()))
		return errSecParam;
	Search s;
	OSStatus err = searchInit(&s, query, true);
	if (err) {
		searchFree(&s);
		return err;
	}
	bool identities = s.itemClass && CFEqual(s.itemClass, kSecClassIdentity);
	CFMutableArrayRef gone = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFIndex found = 0;
	err = forEachMatch(&s, true, &found, ^OSStatus(Store *st, SecKeychainRef kc, CFMutableDictionaryRef item, CFIndex i, bool *stop) {
		CFTypeRef ref = identities ? NULL : refFor(kc, item);
		if (isType(ref, SecKeychainItemGetTypeID()))
			CFArrayAppendValue(gone, ref);
		if (ref)
			CFRelease(ref);
		if (identities) {
			/* Deleting an identity deletes its certificate and key. */
			int64_t certID = itemID(item), keyID = itemID(CFDictionaryGetValue(item, CFSTR("_key")));
			CFIndex ci = findID(st, certID);
			if (ci != kCFNotFound)
				CFArrayRemoveValueAtIndex(st->items, ci);
			CFIndex ki = findID(st, keyID);
			if (ki != kCFNotFound)
				CFArrayRemoveValueAtIndex(st->items, ki);
		} else {
			CFIndex at = findID(st, itemID(item));
			if (at != kCFNotFound)
				CFArrayRemoveValueAtIndex(st->items, at);
		}
		st->dirty = true;
		return 0;
	});
	searchFree(&s);
	if (!err && found == 0)
		err = errSecItemNotFound;
	for (CFIndex i = 0; !err && i < CFArrayGetCount(gone); i++) {
		Item *it = (Item *)CFArrayGetValueAtIndex(gone, i);
		notify(kSecDeleteEvent, it->keychain, (SecKeychainItemRef)it);
	}
	CFRelease(gone);
	return err;
}

/* ---- The SecKeychainItem calls ---- */

static CFStringRef classForItemClass(SecItemClass c)
{
	switch (c) {
	case kSecGenericPasswordItemClass:
		return kSecClassGenericPassword;
	case kSecInternetPasswordItemClass:
		return kSecClassInternetPassword;
	case kSecCertificateItemClass:
		return kSecClassCertificate;
	case kSecPublicKeyItemClass:
	case kSecPrivateKeyItemClass:
	case kSecSymmetricKeyItemClass:
		return kSecClassKey;
	default:
		return NULL;
	}
}

static SecItemClass itemClassFor(CFDictionaryRef item)
{
	CFStringRef c = CFDictionaryGetValue(item, kClass);
	if (CFEqual(c, kSecClassGenericPassword))
		return kSecGenericPasswordItemClass;
	if (CFEqual(c, kSecClassInternetPassword))
		return kSecInternetPasswordItemClass;
	if (CFEqual(c, kSecClassCertificate))
		return kSecCertificateItemClass;
	CFTypeRef kcls = CFDictionaryGetValue(item, kSecAttrKeyClass);
	if (kcls && CFEqual(kcls, kSecAttrKeyClassPrivate))
		return kSecPrivateKeyItemClass;
	if (kcls && CFEqual(kcls, kSecAttrKeyClassSymmetric))
		return kSecSymmetricKeyItemClass;
	return kSecPublicKeyItemClass;
}

/* Legacy attribute tags are the four-character codes the keys spell. */
static CFStringRef keyForTag(UInt32 tag)
{
	char c[5] = {(char)(tag >> 24), (char)(tag >> 16), (char)(tag >> 8), (char)tag, 0};
	return CFStringCreateWithCString(NULL, c, kCFStringEncodingMacRoman);
}

enum { kNumber, kString, kDate, kFourCC, kData };
static int tagFormat(UInt32 tag)
{
	switch (tag) {
	case kSecCreationDateItemAttr:
	case kSecModDateItemAttr:
		return kDate;
	case kSecPortItemAttr:
	case kSecCreatorItemAttr:
	case kSecTypeItemAttr:
	case kSecInvisibleItemAttr:
	case kSecNegativeItemAttr:
	case kSecCustomIconItemAttr:
	case kSecScriptCodeItemAttr:
		return kNumber;
	case kSecProtocolItemAttr:
	case kSecAuthenticationTypeItemAttr:
		return kFourCC;
	case kSecGenericItemAttr:
		return kData;
	default:
		return kString;
	}
}

static CFTypeRef valueFromAttribute(const SecKeychainAttribute *a)
{
	switch (tagFormat(a->tag)) {
	case kNumber:
	case kFourCC: {
		UInt32 v = 0;
		if (a->data && a->length >= 4)
			memcpy(&v, a->data, 4);
		else if (a->data && a->length == 1)
			v = *(const UInt8 *)a->data;
		if (tagFormat(a->tag) == kFourCC)
			return keyForTag(v);
		return CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
	}
	case kDate:
		return NULL;   /* dates are the keychain's to set */
	case kData:
		return CFDataCreate(NULL, a->data, a->length);
	default:
		return CFStringCreateWithBytes(NULL, a->data, a->length, kCFStringEncodingUTF8, false);
	}
}

static void *attributeBytes(CFTypeRef v, UInt32 tag, UInt32 *length)
{
	*length = 0;
	if (!v)
		return NULL;
	if (isType(v, CFStringGetTypeID())) {
		if (tagFormat(tag) == kFourCC) {
			char c[5] = {0};
			CFStringGetCString(v, c, sizeof(c), kCFStringEncodingMacRoman);
			UInt32 code = ((UInt32)(UInt8)c[0] << 24) | ((UInt32)(UInt8)c[1] << 16) | ((UInt32)(UInt8)c[2] << 8) | (UInt8)c[3];
			UInt32 *p = malloc(4);
			*p = code;
			*length = 4;
			return p;
		}
		CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(v), kCFStringEncodingUTF8) + 1;
		char *p = malloc(max);
		CFStringGetCString(v, p, max, kCFStringEncodingUTF8);
		*length = (UInt32)strlen(p);
		return p;
	}
	if (isType(v, CFNumberGetTypeID()) || isType(v, CFBooleanGetTypeID())) {
		UInt32 *p = malloc(4);
		*p = truthy(v) && isType(v, CFBooleanGetTypeID()) ? 1 : 0;
		if (isType(v, CFNumberGetTypeID()))
			CFNumberGetValue(v, kCFNumberSInt32Type, p);
		*length = 4;
		return p;
	}
	if (isType(v, CFDataGetTypeID())) {
		*length = (UInt32)CFDataGetLength(v);
		void *p = malloc(*length ? *length : 1);
		memcpy(p, CFDataGetBytePtr(v), *length);
		return p;
	}
	if (isType(v, CFDateGetTypeID())) {
		/* "YYYYMMDDhhmmssZ" and a NUL, as CSSM's time strings. */
		CFGregorianDate g = CFAbsoluteTimeGetGregorianDate(CFDateGetAbsoluteTime(v), NULL);
		char *p = malloc(16);
		snprintf(p, 16, "%04d%02d%02d%02d%02d%02dZ", (int)g.year, g.month, g.day, g.hour, g.minute, (int)g.second);
		*length = 16;
		return p;
	}
	return NULL;
}

/* Reads an item by reference: a copy of its stored dictionary. */
static OSStatus loadItem(SecKeychainItemRef ref, CFMutableDictionaryRef *out)
{
	*out = NULL;
	if (!isType(ref, SecKeychainItemGetTypeID()))
		return errSecInvalidItemRef;
	Item *it = (Item *)ref;
	Store st;
	OSStatus err = storeOpen(it->keychain, false, false, &st);
	if (err)
		return err == errSecNoSuchKeychain ? errSecInvalidItemRef : err;
	CFIndex i = findID(&st, it->id);
	if (i != kCFNotFound)
		*out = CFDictionaryCreateMutableCopy(NULL, 0, CFArrayGetValueAtIndex(st.items, i));
	storeClose(&st);
	return *out ? 0 : errSecInvalidItemRef;
}

static OSStatus modifyItem(SecKeychainItemRef ref, const SecKeychainAttributeList *attrList, UInt32 length,
    const void *data, bool setData)
{
	if (!isType(ref, SecKeychainItemGetTypeID()))
		return errSecInvalidItemRef;
	Item *it = (Item *)ref;
	Store st;
	OSStatus err = storeOpen(it->keychain, true, false, &st);
	if (err)
		return err == errSecNoSuchKeychain ? errSecInvalidItemRef : err;
	CFIndex i = findID(&st, it->id);
	if (i == kCFNotFound) {
		storeClose(&st);
		return errSecInvalidItemRef;
	}
	CFMutableDictionaryRef item = CFDictionaryCreateMutableCopy(NULL, 0, CFArrayGetValueAtIndex(st.items, i));
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		CFTypeRef v = valueFromAttribute(&attrList->attr[a]);
		CFStringRef key = keyForTag(attrList->attr[a].tag);
		if (v) {
			CFDictionarySetValue(item, key, v);
			CFRelease(v);
		}
		CFRelease(key);
	}
	if (setData) {
		CFDataRef d = CFDataCreate(NULL, data, length);
		CFDictionarySetValue(item, kSecValueData, d);
		CFRelease(d);
	}
	if (duplicate(&st, item, it->id)) {
		CFRelease(item);
		storeClose(&st);
		return errSecDuplicateItem;
	}
	CFDateRef date = CFDateCreate(NULL, now());
	CFDictionarySetValue(item, CFSTR("mdat"), date);
	CFRelease(date);
	CFArraySetValueAtIndex(st.items, i, item);
	CFRelease(item);
	st.dirty = true;
	err = storeClose(&st);
	if (!err)
		notify(kSecUpdateEvent, it->keychain, ref);
	return err;
}

OSStatus SecKeychainItemModifyContent(SecKeychainItemRef itemRef, const SecKeychainAttributeList *attrList,
    UInt32 length, const void *data)
{
	return modifyItem(itemRef, attrList, length, data, data != NULL);
}

OSStatus SecKeychainItemModifyAttributesAndData(SecKeychainItemRef itemRef, const SecKeychainAttributeList *attrList,
    UInt32 length, const void *data)
{
	return modifyItem(itemRef, attrList, length, data, data != NULL);
}

static void *copySecret(CFDictionaryRef item, UInt32 *length)
{
	CFDataRef d = CFDictionaryGetValue(item, kSecValueData);
	*length = d ? (UInt32)CFDataGetLength(d) : 0;
	void *p = malloc(*length + 1);
	if (d)
		memcpy(p, CFDataGetBytePtr(d), *length);
	((char *)p)[*length] = 0;
	return p;
}

OSStatus SecKeychainItemCopyContent(SecKeychainItemRef itemRef, SecItemClass *itemClass,
    SecKeychainAttributeList *attrList, UInt32 *length, void **outData)
{
	CFMutableDictionaryRef item;
	OSStatus err = loadItem(itemRef, &item);
	if (err)
		return err;
	if (itemClass)
		*itemClass = itemClassFor(item);
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		CFStringRef key = keyForTag(attrList->attr[a].tag);
		attrList->attr[a].data = attributeBytes(CFDictionaryGetValue(item, key), attrList->attr[a].tag, &attrList->attr[a].length);
		CFRelease(key);
	}
	if (outData) {
		*outData = copySecret(item, length);
	} else if (length)
		*length = 0;
	CFRelease(item);
	return 0;
}

OSStatus SecKeychainItemCopyAttributesAndData(SecKeychainItemRef itemRef, SecKeychainAttributeInfo *info,
    SecItemClass *itemClass, SecKeychainAttributeList **attrList, UInt32 *length, void **outData)
{
	CFMutableDictionaryRef item;
	OSStatus err = loadItem(itemRef, &item);
	if (err)
		return err;
	if (itemClass)
		*itemClass = itemClassFor(item);
	if (attrList) {
		UInt32 n = info ? info->count : 0;
		SecKeychainAttributeList *list = calloc(1, sizeof(*list));
		list->count = n;
		list->attr = calloc(n ? n : 1, sizeof(SecKeychainAttribute));
		for (UInt32 a = 0; a < n; a++) {
			UInt32 tag = info->tag[a];
			CFStringRef key = keyForTag(tag);
			list->attr[a].tag = tag;
			list->attr[a].data = attributeBytes(CFDictionaryGetValue(item, key), tag, &list->attr[a].length);
			CFRelease(key);
		}
		*attrList = list;
	}
	if (outData)
		*outData = copySecret(item, length);
	else if (length)
		*length = 0;
	CFRelease(item);
	return 0;
}

OSStatus SecKeychainItemFreeAttributesAndData(SecKeychainAttributeList *attrList, void *data)
{
	if (attrList) {
		for (UInt32 a = 0; a < attrList->count; a++)
			free(attrList->attr[a].data);
		free(attrList->attr);
		free(attrList);
	}
	free(data);
	return 0;
}

OSStatus SecKeychainItemFreeContent(SecKeychainAttributeList *attrList, void *data)
{
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		free(attrList->attr[a].data);
		attrList->attr[a].data = NULL;
	}
	free(data);
	return 0;
}

OSStatus SecKeychainItemCreateFromContent(SecItemClass itemClass, SecKeychainAttributeList *attrList,
    UInt32 length, const void *data, SecKeychainRef keychainRef, SecAccessRef initialAccess,
    SecKeychainItemRef *itemRef)
{
	if (itemRef)
		*itemRef = NULL;
	CFStringRef cls = classForItemClass(itemClass);
	if (!cls || cls == kSecClassCertificate || cls == kSecClassKey)
		return errSecParam;
	CFMutableDictionaryRef item = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(item, kClass, cls);
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		CFTypeRef v = valueFromAttribute(&attrList->attr[a]);
		CFStringRef key = keyForTag(attrList->attr[a].tag);
		if (v) {
			CFDictionarySetValue(item, key, v);
			CFRelease(v);
		}
		CFRelease(key);
	}
	defaultLabel(item);
	CFDataRef d = CFDataCreate(NULL, data, data ? length : 0);
	CFDictionarySetValue(item, kSecValueData, d);
	CFRelease(d);
	SecKeychainRef kc = keychainRef ? (SecKeychainRef)CFRetain(keychainRef) : defaultKeychain();
	OSStatus err = isType(kc, SecKeychainGetTypeID()) ? addItem(kc, item, NULL, NULL, itemRef) : errSecInvalidKeychain;
	CFRelease(kc);
	CFRelease(item);
	return err;
}

OSStatus SecKeychainItemDelete(SecKeychainItemRef itemRef)
{
	if (!isType(itemRef, SecKeychainItemGetTypeID()))
		return errSecInvalidItemRef;
	Item *it = (Item *)itemRef;
	Store st;
	OSStatus err = storeOpen(it->keychain, true, false, &st);
	if (err)
		return err == errSecNoSuchKeychain ? errSecInvalidItemRef : err;
	CFIndex i = findID(&st, it->id);
	if (i == kCFNotFound) {
		storeClose(&st);
		return errSecInvalidItemRef;
	}
	CFArrayRemoveValueAtIndex(st.items, i);
	st.dirty = true;
	err = storeClose(&st);
	if (!err)
		notify(kSecDeleteEvent, it->keychain, itemRef);
	return err;
}

OSStatus SecKeychainItemCopyKeychain(SecKeychainItemRef itemRef, SecKeychainRef *keychainRef)
{
	if (!isType(itemRef, SecKeychainItemGetTypeID()) || !keychainRef)
		return errSecParam;
	*keychainRef = (SecKeychainRef)CFRetain(((Item *)itemRef)->keychain);
	return 0;
}

OSStatus SecKeychainItemCreatePersistentReference(SecKeychainItemRef itemRef, CFDataRef *persistentItemRef)
{
	if (!isType(itemRef, SecKeychainItemGetTypeID()) || !persistentItemRef)
		return errSecParam;
	*persistentItemRef = persistentRef(((Item *)itemRef)->keychain, ((Item *)itemRef)->id);
	return 0;
}

OSStatus SecKeychainItemCopyFromPersistentReference(CFDataRef persistentItemRef, SecKeychainItemRef *itemRef)
{
	if (!itemRef)
		return errSecParam;
	SecKeychainRef kc = NULL;
	int64_t id = 0;
	if (!parsePersistentRef(persistentItemRef, &kc, &id))
		return errSecItemNotFound;
	Store st;
	OSStatus err = storeOpen(kc, false, false, &st);
	if (!err) {
		CFIndex i = findID(&st, id);
		*itemRef = i == kCFNotFound ? NULL : (SecKeychainItemRef)refFor(kc, CFArrayGetValueAtIndex(st.items, i));
		storeClose(&st);
		err = *itemRef ? 0 : errSecItemNotFound;
	}
	CFRelease(kc);
	return err;
}

OSStatus SecKeychainItemCreateCopy(SecKeychainItemRef itemRef, SecKeychainRef destKeychainRef,
    SecAccessRef initialAccess, SecKeychainItemRef *itemCopy)
{
	CFMutableDictionaryRef item;
	OSStatus err = loadItem(itemRef, &item);
	if (err)
		return err;
	CFDictionaryRemoveValue(item, kID);
	CFDictionaryRemoveValue(item, CFSTR("cdat"));
	SecKeychainRef kc = destKeychainRef ? (SecKeychainRef)CFRetain(destKeychainRef) : defaultKeychain();
	err = addItem(kc, item, NULL, NULL, itemCopy);
	CFRelease(kc);
	CFRelease(item);
	return err;
}

OSStatus SecKeychainItemCopyAccess(SecKeychainItemRef itemRef, SecAccessRef *access)
{
	if (!isType(itemRef, SecKeychainItemGetTypeID()) || !access)
		return errSecParam;
	return SecAccessCreate(CFSTR(""), NULL, access);
}

OSStatus SecKeychainItemSetAccess(SecKeychainItemRef itemRef, SecAccessRef access)
{
	return isType(itemRef, SecKeychainItemGetTypeID()) ? 0 : errSecParam;
}

/* ---- Passwords by name ---- */

static OSStatus findPassword(CFTypeRef keychainOrArray, CFMutableDictionaryRef query, UInt32 *length,
    void **data, SecKeychainItemRef *itemRef)
{
	if (length)
		*length = 0;
	if (data)
		*data = NULL;
	if (itemRef)
		*itemRef = NULL;
	if (keychainOrArray) {
		if (isType(keychainOrArray, CFArrayGetTypeID()))
			CFDictionarySetValue(query, kSecMatchSearchList, keychainOrArray);
		else if (isType(keychainOrArray, SecKeychainGetTypeID())) {
			CFArrayRef a = CFArrayCreate(NULL, &keychainOrArray, 1, &kCFTypeArrayCallBacks);
			CFDictionarySetValue(query, kSecMatchSearchList, a);
			CFRelease(a);
		} else
			return errSecParam;
	}
	CFDictionarySetValue(query, kSecReturnRef, kCFBooleanTrue);
	CFTypeRef ref = NULL;
	OSStatus err = SecItemCopyMatching(query, &ref);
	if (err)
		return err;
	if (data) {
		CFMutableDictionaryRef item;
		err = loadItem((SecKeychainItemRef)ref, &item);
		if (!err) {
			*data = copySecret(item, length);
			CFRelease(item);
		}
	}
	if (!err && itemRef)
		*itemRef = (SecKeychainItemRef)CFRetain(ref);
	CFRelease(ref);
	return err;
}

static void setBytes(CFMutableDictionaryRef d, CFStringRef key, UInt32 len, const char *bytes)
{
	if (!bytes || !len)
		return;
	CFStringRef s = CFStringCreateWithBytes(NULL, (const UInt8 *)bytes, len, kCFStringEncodingUTF8, false);
	if (s) {
		CFDictionarySetValue(d, key, s);
		CFRelease(s);
	}
}

OSStatus SecKeychainFindGenericPassword(CFTypeRef keychainOrArray, UInt32 serviceNameLength,
    const char *serviceName, UInt32 accountNameLength, const char *accountName, UInt32 *passwordLength,
    void **passwordData, SecKeychainItemRef *itemRef)
{
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(q, kClass, kSecClassGenericPassword);
	setBytes(q, kSecAttrService, serviceNameLength, serviceName);
	setBytes(q, kSecAttrAccount, accountNameLength, accountName);
	OSStatus err = findPassword(keychainOrArray, q, passwordLength, passwordData, itemRef);
	CFRelease(q);
	return err;
}

OSStatus SecKeychainAddGenericPassword(SecKeychainRef keychain, UInt32 serviceNameLength, const char *serviceName,
    UInt32 accountNameLength, const char *accountName, UInt32 passwordLength, const void *passwordData,
    SecKeychainItemRef *itemRef)
{
	SecKeychainAttribute attrs[] = {
	    {kSecServiceItemAttr, serviceNameLength, (void *)serviceName},
	    {kSecAccountItemAttr, accountNameLength, (void *)accountName},
	};
	SecKeychainAttributeList list = {2, attrs};
	return SecKeychainItemCreateFromContent(kSecGenericPasswordItemClass, &list, passwordLength, passwordData,
	    keychain, NULL, itemRef);
}

static void setFourCC(CFMutableDictionaryRef d, CFStringRef key, UInt32 code)
{
	if (!code)
		return;
	CFStringRef s = keyForTag(code);
	CFDictionarySetValue(d, key, s);
	CFRelease(s);
}

OSStatus SecKeychainFindInternetPassword(CFTypeRef keychainOrArray, UInt32 serverNameLength, const char *serverName,
    UInt32 securityDomainLength, const char *securityDomain, UInt32 accountNameLength, const char *accountName,
    UInt32 pathLength, const char *path, UInt16 port, SecProtocolType protocol, SecAuthenticationType authenticationType,
    UInt32 *passwordLength, void **passwordData, SecKeychainItemRef *itemRef)
{
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(q, kClass, kSecClassInternetPassword);
	setBytes(q, kSecAttrServer, serverNameLength, serverName);
	setBytes(q, kSecAttrSecurityDomain, securityDomainLength, securityDomain);
	setBytes(q, kSecAttrAccount, accountNameLength, accountName);
	setBytes(q, kSecAttrPath, pathLength, path);
	if (port) {
		int p = port;
		CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &p);
		CFDictionarySetValue(q, kSecAttrPort, n);
		CFRelease(n);
	}
	setFourCC(q, kSecAttrProtocol, protocol);
	if (authenticationType != kSecAuthenticationTypeAny)
		setFourCC(q, kSecAttrAuthenticationType, authenticationType);
	OSStatus err = findPassword(keychainOrArray, q, passwordLength, passwordData, itemRef);
	CFRelease(q);
	return err;
}

OSStatus SecKeychainAddInternetPassword(SecKeychainRef keychain, UInt32 serverNameLength, const char *serverName,
    UInt32 securityDomainLength, const char *securityDomain, UInt32 accountNameLength, const char *accountName,
    UInt32 pathLength, const char *path, UInt16 port, SecProtocolType protocol, SecAuthenticationType authenticationType,
    UInt32 passwordLength, const void *passwordData, SecKeychainItemRef *itemRef)
{
	UInt32 p32 = port;
	SecKeychainAttribute attrs[8];
	UInt32 n = 0;
	attrs[n++] = (SecKeychainAttribute){kSecServerItemAttr, serverNameLength, (void *)serverName};
	if (securityDomainLength)
		attrs[n++] = (SecKeychainAttribute){kSecSecurityDomainItemAttr, securityDomainLength, (void *)securityDomain};
	attrs[n++] = (SecKeychainAttribute){kSecAccountItemAttr, accountNameLength, (void *)accountName};
	if (pathLength)
		attrs[n++] = (SecKeychainAttribute){kSecPathItemAttr, pathLength, (void *)path};
	if (port)
		attrs[n++] = (SecKeychainAttribute){kSecPortItemAttr, 4, &p32};
	if (protocol)
		attrs[n++] = (SecKeychainAttribute){kSecProtocolItemAttr, 4, &protocol};
	if (authenticationType)
		attrs[n++] = (SecKeychainAttribute){kSecAuthenticationTypeItemAttr, 4, &authenticationType};
	SecKeychainAttributeList list = {n, attrs};
	return SecKeychainItemCreateFromContent(kSecInternetPasswordItemClass, &list, passwordLength, passwordData,
	    keychain, NULL, itemRef);
}

/* ---- Searches (deprecated API) ---- */

typedef struct {
	CFRuntimeBase base;
	CFArrayRef results;
	CFIndex next;
} KCSearch;
static void searchObjFree(CFTypeRef o)
{
	if (((KCSearch *)o)->results)
		CFRelease(((KCSearch *)o)->results);
}
SEC_DEFINE_TYPE(SecKeychainSearchGetTypeID, "SecKeychainSearch", searchObjFree, NULL, NULL)

OSStatus SecKeychainSearchCreateFromAttributes(CFTypeRef keychainOrArray, SecItemClass itemClass,
    const SecKeychainAttributeList *attrList, SecKeychainSearchRef *searchRef)
{
	if (!searchRef)
		return errSecParam;
	CFStringRef cls = classForItemClass(itemClass);
	if (!cls)
		return errSecParam;
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(q, kClass, cls);
	CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitAll);
	CFDictionarySetValue(q, kSecReturnRef, kCFBooleanTrue);
	for (UInt32 a = 0; attrList && a < attrList->count; a++) {
		CFTypeRef v = valueFromAttribute(&attrList->attr[a]);
		CFStringRef key = keyForTag(attrList->attr[a].tag);
		if (v) {
			CFDictionarySetValue(q, key, v);
			CFRelease(v);
		}
		CFRelease(key);
	}
	if (isType(keychainOrArray, SecKeychainGetTypeID())) {
		CFArrayRef a = CFArrayCreate(NULL, &keychainOrArray, 1, &kCFTypeArrayCallBacks);
		CFDictionarySetValue(q, kSecMatchSearchList, a);
		CFRelease(a);
	} else if (isType(keychainOrArray, CFArrayGetTypeID()))
		CFDictionarySetValue(q, kSecMatchSearchList, keychainOrArray);
	CFTypeRef results = NULL;
	SecItemCopyMatching(q, &results);
	CFRelease(q);
	KCSearch *s = (KCSearch *)_SecCreateInstance(SecKeychainSearchGetTypeID(), sizeof(*s));
	s->results = results;
	*searchRef = (SecKeychainSearchRef)s;
	return 0;
}

OSStatus SecKeychainSearchCopyNext(SecKeychainSearchRef searchRef, SecKeychainItemRef *itemRef)
{
	if (!isType(searchRef, SecKeychainSearchGetTypeID()) || !itemRef)
		return errSecParam;
	KCSearch *s = (KCSearch *)searchRef;
	if (!s->results || s->next >= CFArrayGetCount(s->results))
		return errSecItemNotFound;
	*itemRef = (SecKeychainItemRef)CFRetain(CFArrayGetValueAtIndex(s->results, s->next++));
	return 0;
}

/* ---- Identities ---- */

typedef struct {
	CFRuntimeBase base;
	SecCertificateRef certificate;
	SecKeyRef key;
} Identity;
static void identityFree(CFTypeRef o)
{
	CFRelease(((Identity *)o)->certificate);
	CFRelease(((Identity *)o)->key);
}
static Boolean identityEqual(CFTypeRef a, CFTypeRef b)
{
	return CFEqual(((Identity *)a)->certificate, ((Identity *)b)->certificate) &&
	    CFEqual(((Identity *)a)->key, ((Identity *)b)->key);
}
static CFHashCode identityHash(CFTypeRef a)
{
	return CFHash(((Identity *)a)->certificate);
}
SEC_DEFINE_TYPE(SecIdentityGetTypeID, "SecIdentity", identityFree, identityEqual, identityHash)

SecIdentityRef _SecIdentityCreate(SecCertificateRef cert, SecKeyRef key)
{
	Identity *i = (Identity *)_SecCreateInstance(SecIdentityGetTypeID(), sizeof(*i));
	i->certificate = (SecCertificateRef)CFRetain(cert);
	i->key = (SecKeyRef)CFRetain(key);
	return (SecIdentityRef)i;
}

SecIdentityRef SecIdentityCreate(CFAllocatorRef allocator, SecCertificateRef certificate, SecKeyRef privateKey)
{
	if (!isType(certificate, SecCertificateGetTypeID()) || !isType(privateKey, SecKeyGetTypeID()))
		return NULL;
	return _SecIdentityCreate(certificate, privateKey);
}

OSStatus SecIdentityCreateWithCertificate(CFTypeRef keychainOrArray, SecCertificateRef certificateRef,
    SecIdentityRef *identityRef)
{
	if (!isType(certificateRef, SecCertificateGetTypeID()) || !identityRef)
		return errSecParam;
	*identityRef = NULL;
	CFDataRef label = _SecCertificateCopyPublicKeySHA1(certificateRef);
	CFMutableDictionaryRef q = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(q, kClass, kSecClassKey);
	CFDictionarySetValue(q, kSecAttrKeyClass, kSecAttrKeyClassPrivate);
	if (label) {
		CFDictionarySetValue(q, kSecAttrApplicationLabel, label);
		CFRelease(label);
	}
	CFDictionarySetValue(q, kSecReturnRef, kCFBooleanTrue);
	if (isType(keychainOrArray, CFArrayGetTypeID()))
		CFDictionarySetValue(q, kSecMatchSearchList, keychainOrArray);
	else if (isType(keychainOrArray, SecKeychainGetTypeID())) {
		CFArrayRef a = CFArrayCreate(NULL, &keychainOrArray, 1, &kCFTypeArrayCallBacks);
		CFDictionarySetValue(q, kSecMatchSearchList, a);
		CFRelease(a);
	}
	CFTypeRef key = NULL;
	OSStatus err = SecItemCopyMatching(q, &key);
	CFRelease(q);
	if (!err) {
		*identityRef = _SecIdentityCreate(certificateRef, (SecKeyRef)key);
		CFRelease(key);
	}
	return err;
}

OSStatus SecIdentityCopyCertificate(SecIdentityRef identityRef, SecCertificateRef *certificateRef)
{
	if (!isType(identityRef, SecIdentityGetTypeID()) || !certificateRef)
		return errSecParam;
	*certificateRef = (SecCertificateRef)CFRetain(((Identity *)identityRef)->certificate);
	return 0;
}

OSStatus SecIdentityCopyPrivateKey(SecIdentityRef identityRef, SecKeyRef *privateKeyRef)
{
	if (!isType(identityRef, SecIdentityGetTypeID()) || !privateKeyRef)
		return errSecParam;
	*privateKeyRef = (SecKeyRef)CFRetain(((Identity *)identityRef)->key);
	return 0;
}

SecIdentityRef SecIdentityCopyPreferred(CFStringRef name, CFArrayRef keyUsage, CFArrayRef validIssuers)
{
	return NULL;
}

OSStatus SecIdentityCopySystemIdentity(CFStringRef domain, SecIdentityRef *idRef, CFStringRef *actualDomain)
{
	if (idRef)
		*idRef = NULL;
	return errSecItemNotFound;
}
