/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Access objects: SecAccess, SecACL, SecTrustedApplication (the file
 * keychain's access lists) and SecAccessControl (data-protection keychain
 * access). Finch's keychain doesn't enforce access lists yet
 * (docs/design/SECURITY.md): these objects are made, inspected and attached
 * as on macOS, and record what the caller asked for.
 */
#include "SecInternal.h"
#include <mach-o/dyld.h>
#include <limits.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static bool isType(CFTypeRef o, CFTypeID t)
{
	return o && CFGetTypeID(o) == t;
}

/* ---- Trusted applications ---- */

typedef struct {
	CFRuntimeBase base;
	CFDataRef data;   /* the path, or the group name */
	bool group;
} TrustedApp;
static void appFree(CFTypeRef o)
{
	CFRelease(((TrustedApp *)o)->data);
}
SEC_DEFINE_TYPE(SecTrustedApplicationGetTypeID, "SecTrustedApplication", appFree, NULL, NULL)

static SecTrustedApplicationRef appCreate(const char *s, bool group)
{
	TrustedApp *a = (TrustedApp *)_SecCreateInstance(SecTrustedApplicationGetTypeID(), sizeof(*a));
	a->data = CFDataCreate(NULL, (const UInt8 *)s, strlen(s));
	a->group = group;
	return (SecTrustedApplicationRef)a;
}

OSStatus SecTrustedApplicationCreateFromPath(const char *path, SecTrustedApplicationRef *app)
{
	if (!app)
		return errSecParam;
	char self[PATH_MAX];
	uint32_t size = sizeof(self);
	if (!path) {
		if (_NSGetExecutablePath(self, &size) != 0)
			return errSecParam;
		path = self;
	}
	*app = appCreate(path, false);
	return 0;
}

OSStatus SecTrustedApplicationCreateApplicationGroup(const char *groupName, SecCertificateRef anchor,
    SecTrustedApplicationRef *app)
{
	if (!groupName || !app)
		return errSecParam;
	*app = appCreate(groupName, true);
	return 0;
}

OSStatus SecTrustedApplicationCopyData(SecTrustedApplicationRef appRef, CFDataRef *data)
{
	if (!isType(appRef, SecTrustedApplicationGetTypeID()) || !data)
		return errSecParam;
	*data = CFRetain(((TrustedApp *)appRef)->data);
	return 0;
}

OSStatus SecTrustedApplicationSetData(SecTrustedApplicationRef appRef, CFDataRef data)
{
	if (!isType(appRef, SecTrustedApplicationGetTypeID()) || !isType(data, CFDataGetTypeID()))
		return errSecParam;
	CFRelease(((TrustedApp *)appRef)->data);
	((TrustedApp *)appRef)->data = CFDataCreateCopy(NULL, data);
	return 0;
}

/* ---- ACLs and access ---- */

typedef struct {
	CFRuntimeBase base;
	CFStringRef description;
	CFArrayRef apps;
	CFArrayRef authorizations;
} ACL;
static void aclFree(CFTypeRef o)
{
	ACL *a = (ACL *)o;
	if (a->description)
		CFRelease(a->description);
	if (a->apps)
		CFRelease(a->apps);
	if (a->authorizations)
		CFRelease(a->authorizations);
}
SEC_DEFINE_TYPE(SecACLGetTypeID, "SecACL", aclFree, NULL, NULL)

typedef struct {
	CFRuntimeBase base;
	CFMutableArrayRef acls;
} Access;
static void accessFree(CFTypeRef o)
{
	CFRelease(((Access *)o)->acls);
}
SEC_DEFINE_TYPE(SecAccessGetTypeID, "SecAccess", accessFree, NULL, NULL)

static ACL *aclCreate(CFStringRef description, CFArrayRef apps, CFArrayRef authorizations)
{
	ACL *a = (ACL *)_SecCreateInstance(SecACLGetTypeID(), sizeof(*a));
	a->description = description ? CFRetain(description) : CFSTR("");
	a->apps = apps ? CFArrayCreateCopy(NULL, apps) : NULL;
	a->authorizations = authorizations ? CFArrayCreateCopy(NULL, authorizations) : NULL;
	return a;
}

OSStatus SecAccessCreate(CFStringRef descriptor, CFArrayRef trustedlist, SecAccessRef *accessRef)
{
	if (!accessRef || (descriptor && !isType(descriptor, CFStringGetTypeID())))
		return errSecParam;
	Access *a = (Access *)_SecCreateInstance(SecAccessGetTypeID(), sizeof(*a));
	a->acls = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFArrayRef apps = trustedlist;
	SecTrustedApplicationRef self = NULL;
	if (!apps) {
		/* NULL: the calling application is trusted. */
		SecTrustedApplicationCreateFromPath(NULL, &self);
		apps = CFArrayCreate(NULL, (const void **)&self, 1, &kCFTypeArrayCallBacks);
	}
	ACL *decrypt = aclCreate(descriptor, apps, NULL);
	CFArrayAppendValue(a->acls, decrypt);
	CFRelease(decrypt);
	if (self) {
		CFRelease(self);
		CFRelease(apps);
	}
	*accessRef = (SecAccessRef)a;
	return 0;
}

OSStatus SecAccessCopyACLList(SecAccessRef accessRef, CFArrayRef *aclList)
{
	if (!isType(accessRef, SecAccessGetTypeID()) || !aclList)
		return errSecParam;
	*aclList = CFArrayCreateCopy(NULL, ((Access *)accessRef)->acls);
	return 0;
}

CFArrayRef SecAccessCopyMatchingACLList(SecAccessRef accessRef, CFTypeRef authorizationTag)
{
	return isType(accessRef, SecAccessGetTypeID()) ? CFArrayCreateCopy(NULL, ((Access *)accessRef)->acls) : NULL;
}

OSStatus SecACLCreateWithSimpleContents(SecAccessRef access, CFArrayRef applicationList, CFStringRef description,
    SecKeychainPromptSelector promptSelector, SecACLRef *newAcl)
{
	if (!isType(access, SecAccessGetTypeID()) || !newAcl)
		return errSecParam;
	ACL *acl = aclCreate(description, applicationList, NULL);
	CFArrayAppendValue(((Access *)access)->acls, acl);
	*newAcl = (SecACLRef)acl;
	return 0;
}

OSStatus SecACLCopyContents(SecACLRef acl, CFArrayRef *applicationList, CFStringRef *description,
    SecKeychainPromptSelector *promptSelector)
{
	if (!isType(acl, SecACLGetTypeID()))
		return errSecParam;
	ACL *a = (ACL *)acl;
	if (applicationList)
		*applicationList = a->apps ? CFRetain(a->apps) : NULL;
	if (description)
		*description = CFRetain(a->description);
	if (promptSelector)
		*promptSelector = 0;
	return 0;
}

OSStatus SecACLSetContents(SecACLRef acl, CFArrayRef applicationList, CFStringRef description,
    SecKeychainPromptSelector promptSelector)
{
	if (!isType(acl, SecACLGetTypeID()))
		return errSecParam;
	ACL *a = (ACL *)acl;
	if (a->apps)
		CFRelease(a->apps);
	a->apps = applicationList ? CFArrayCreateCopy(NULL, applicationList) : NULL;
	if (description) {
		CFRelease(a->description);
		a->description = CFRetain(description);
	}
	return 0;
}

CFArrayRef SecACLCopyAuthorizations(SecACLRef acl)
{
	if (!isType(acl, SecACLGetTypeID()))
		return NULL;
	ACL *a = (ACL *)acl;
	return a->authorizations ? CFRetain(a->authorizations) : CFArrayCreate(NULL, (const void *[]){kSecACLAuthorizationAny}, 1, &kCFTypeArrayCallBacks);
}

OSStatus SecACLUpdateAuthorizations(SecACLRef acl, CFArrayRef authorizations)
{
	if (!isType(acl, SecACLGetTypeID()))
		return errSecParam;
	ACL *a = (ACL *)acl;
	if (a->authorizations)
		CFRelease(a->authorizations);
	a->authorizations = authorizations ? CFArrayCreateCopy(NULL, authorizations) : NULL;
	return 0;
}

OSStatus SecACLRemove(SecACLRef aclRef)
{
	return isType(aclRef, SecACLGetTypeID()) ? 0 : errSecParam;
}

/* ---- Access control (data-protection keychain) ---- */

typedef struct {
	CFRuntimeBase base;
	CFTypeRef protection;
	SecAccessControlCreateFlags flags;
} AccessControl;
static void acFree(CFTypeRef o)
{
	CFRelease(((AccessControl *)o)->protection);
}
static Boolean acEqual(CFTypeRef a, CFTypeRef b)
{
	return ((AccessControl *)a)->flags == ((AccessControl *)b)->flags &&
	    CFEqual(((AccessControl *)a)->protection, ((AccessControl *)b)->protection);
}
SEC_DEFINE_TYPE(SecAccessControlGetTypeID, "SecAccessControl", acFree, acEqual, NULL)

SecAccessControlRef SecAccessControlCreateWithFlags(CFAllocatorRef allocator, CFTypeRef protection,
    SecAccessControlCreateFlags flags, CFErrorRef *error)
{
	CFTypeRef valid[] = {kSecAttrAccessibleWhenUnlocked, kSecAttrAccessibleAfterFirstUnlock,
	    kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
	    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecAttrAccessibleAlways, kSecAttrAccessibleAlwaysThisDeviceOnly};
	bool ok = false;
	for (size_t i = 0; protection && i < sizeof(valid) / sizeof(*valid); i++)
		ok = ok || CFEqual(protection, valid[i]);
	if (!ok) {
		_SecSetError(error, errSecParam, NULL);
		return NULL;
	}
	AccessControl *a = (AccessControl *)_SecCreateInstance(SecAccessControlGetTypeID(), sizeof(*a));
	a->protection = CFRetain(protection);
	a->flags = flags;
	return (SecAccessControlRef)a;
}
