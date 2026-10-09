/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Authorization Services and security sessions, without a security server.
 *
 * Rights and rules come from Apple's published authorization database
 * (Security's OSX/authd/authorization.plist, installed in the framework's
 * Resources), evaluated in-process: "allow" rules are granted, "deny" rules
 * denied, and rules that would need a user to authenticate are granted to
 * root (allow-root) or to members of the rule's group when the rule doesn't
 * ask for authentication. Anything that would need an authentication dialog
 * fails as Apple's does when interaction isn't possible: without
 * kAuthorizationFlagExtendRights, errAuthorizationDenied; without
 * kAuthorizationFlagInteractionAllowed, errAuthorizationInteractionNotAllowed;
 * and, since Finch has no SecurityAgent yet, errAuthorizationDenied otherwise.
 * External forms work within a process only (no authd to hand them across).
 */
#include "SecInternal.h"
#include <Security/AuthSession.h>
#include <Security/AuthorizationDB.h>
#include <bsm/audit.h>
#include <bsm/audit_session.h>
#include <dlfcn.h>
#include <grp.h>
#include <limits.h>
#include <pthread.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

struct AuthorizationOpaqueRef {
	uint32_t magic;
	uint8_t token[32];
	struct AuthorizationOpaqueRef *next;
};
#define kAuthMagic 0x46415554u   /* 'FAUT' */

static pthread_mutex_t authLock = PTHREAD_MUTEX_INITIALIZER;
static struct AuthorizationOpaqueRef *allRefs;

static bool validRef(AuthorizationRef a)
{
	bool ok = false;
	pthread_mutex_lock(&authLock);
	for (struct AuthorizationOpaqueRef *r = allRefs; r; r = r->next)
		if (r == a && r->magic == kAuthMagic)
			ok = true;
	pthread_mutex_unlock(&authLock);
	return ok;
}

/* ---- The rules database ---- */

static CFDictionaryRef database;

static void loadDatabase(void)
{
	Dl_info info;
	if (!dladdr((const void *)loadDatabase, &info) || !info.dli_fname)
		return;
	const char *slash = strrchr(info.dli_fname, '/');
	char path[PATH_MAX];
	snprintf(path, sizeof(path), "%.*s/Resources/authorization.plist", (int)(slash - info.dli_fname), info.dli_fname);
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
	CFReadStreamRef stream = CFReadStreamCreateWithFile(NULL, url);
	if (stream && CFReadStreamOpen(stream)) {
		CFPropertyListRef p = CFPropertyListCreateWithStream(NULL, stream, 0, 0, NULL, NULL);
		if (p && CFGetTypeID(p) == CFDictionaryGetTypeID())
			database = p;
		else if (p)
			CFRelease(p);
		CFReadStreamClose(stream);
	}
	if (stream)
		CFRelease(stream);
	CFRelease(url);
}

static CFDictionaryRef section(CFStringRef name)
{
	static pthread_once_t once = PTHREAD_ONCE_INIT;
	pthread_once(&once, loadDatabase);
	CFDictionaryRef d = database ? CFDictionaryGetValue(database, name) : NULL;
	return d && CFGetTypeID(d) == CFDictionaryGetTypeID() ? d : NULL;
}

/* A right's definition: an exact match, else the longest wildcard ("prefix.")
 * that begins the name, else the default ("") right. */
static CFDictionaryRef rightDefinition(const char *name, bool fallback)
{
	CFDictionaryRef rights = section(CFSTR("rights"));
	if (!rights)
		return NULL;
	CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	CFDictionaryRef d = key ? CFDictionaryGetValue(rights, key) : NULL;
	if (key)
		CFRelease(key);
	if (d)
		return d;
	char prefix[1024];
	strlcpy(prefix, name, sizeof(prefix));
	for (char *dot = strrchr(prefix, '.'); dot; dot = strrchr(prefix, '.')) {
		dot[1] = 0;
		CFStringRef k = CFStringCreateWithCString(NULL, prefix, kCFStringEncodingUTF8);
		d = CFDictionaryGetValue(rights, k);
		CFRelease(k);
		if (d)
			return d;
		*dot = 0;
	}
	return fallback ? CFDictionaryGetValue(rights, CFSTR("")) : NULL;
}

static bool boolValue(CFDictionaryRef d, CFStringRef key, bool def)
{
	CFTypeRef v = CFDictionaryGetValue(d, key);
	return v && CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue(v) : def;
}

static bool inGroup(CFStringRef group)
{
	char name[256];
	if (!group || !CFStringGetCString(group, name, sizeof(name), kCFStringEncodingUTF8))
		return false;
	struct group *g = getgrnam(name);
	if (!g)
		return false;
	gid_t groups[NGROUPS_MAX];
	int n = getgroups(NGROUPS_MAX, groups);
	for (int i = 0; i < n; i++)
		if (groups[i] == g->gr_gid)
			return true;
	return getegid() == g->gr_gid;
}

enum { kGranted, kDenied, kNeedsAuthentication };

static int evaluateRule(CFDictionaryRef rule, int depth)
{
	if (!rule || depth > 10)
		return kDenied;
	CFStringRef cls = CFDictionaryGetValue(rule, CFSTR("class"));
	if (cls && CFEqual(cls, CFSTR("allow")))
		return kGranted;
	if (cls && CFEqual(cls, CFSTR("deny")))
		return kDenied;
	if (cls && CFEqual(cls, CFSTR("rule"))) {
		CFTypeRef names = CFDictionaryGetValue(rule, CFSTR("rule"));
		CFDictionaryRef rules = section(CFSTR("rules"));
		if (names && CFGetTypeID(names) == CFStringGetTypeID())
			names = CFArrayCreate(NULL, &names, 1, &kCFTypeArrayCallBacks);
		else if (names && CFGetTypeID(names) == CFArrayGetTypeID())
			CFRetain(names);
		else
			return kDenied;
		CFIndex count = CFArrayGetCount(names), k = count;
		CFNumberRef kn = CFDictionaryGetValue(rule, CFSTR("k"));
		if (kn && CFGetTypeID(kn) == CFNumberGetTypeID())
			CFNumberGetValue(kn, kCFNumberCFIndexType, &k);
		CFIndex granted = 0;
		int result = kDenied;
		for (CFIndex i = 0; i < count; i++) {
			CFDictionaryRef sub = rules ? CFDictionaryGetValue(rules, CFArrayGetValueAtIndex(names, i)) : NULL;
			int r = evaluateRule(sub, depth + 1);
			if (r == kGranted)
				granted++;
			else if (r == kNeedsAuthentication)
				result = kNeedsAuthentication;
		}
		CFRelease(names);
		return granted >= k ? kGranted : result;
	}
	/* user and evaluate-mechanisms: a person would authenticate. */
	if (geteuid() == 0 && boolValue(rule, CFSTR("allow-root"), false))
		return kGranted;
	if (cls && CFEqual(cls, CFSTR("user")) && !boolValue(rule, CFSTR("authenticate-user"), true) &&
	    inGroup(CFDictionaryGetValue(rule, CFSTR("group"))))
		return kGranted;
	if (geteuid() == 0 && cls && CFEqual(cls, CFSTR("evaluate-mechanisms")))
		return kGranted;
	return kNeedsAuthentication;
}

/* A right's rule: the right itself, or the named rule(s) it points to. */
static int evaluateRight(const char *name)
{
	CFDictionaryRef def = rightDefinition(name, true);
	return def ? evaluateRule(def, 0) : kNeedsAuthentication;
}

/* ---- Authorization calls ---- */

static AuthorizationItemSet *copyItems(const AuthorizationRights *rights)
{
	AuthorizationItemSet *set = calloc(1, sizeof(*set));
	UInt32 n = rights ? rights->count : 0;
	set->items = calloc(n ? n : 1, sizeof(AuthorizationItem));
	for (UInt32 i = 0; i < n; i++) {
		const AuthorizationItem *src = &rights->items[i];
		AuthorizationItem *dst = &set->items[set->count++];
		dst->name = src->name ? strdup(src->name) : NULL;
		dst->flags = src->flags;
		if (src->value && src->valueLength) {
			dst->value = malloc(src->valueLength);
			memcpy(dst->value, src->value, src->valueLength);
			dst->valueLength = src->valueLength;
		}
	}
	return set;
}

OSStatus AuthorizationFreeItemSet(AuthorizationItemSet *set)
{
	if (!set)
		return errAuthorizationInvalidSet;
	for (UInt32 i = 0; i < set->count; i++) {
		free((void *)set->items[i].name);
		free(set->items[i].value);
	}
	free(set->items);
	free(set);
	return errAuthorizationSuccess;
}

OSStatus AuthorizationCopyRights(AuthorizationRef authorization, const AuthorizationRights *rights,
    const AuthorizationEnvironment *environment, AuthorizationFlags flags, AuthorizationRights **authorizedRights)
{
	if (authorizedRights)
		*authorizedRights = NULL;
	if (!validRef(authorization))
		return errAuthorizationInvalidRef;
	if (rights && rights->count && !rights->items)
		return errAuthorizationInvalidSet;
	for (UInt32 i = 0; rights && i < rights->count; i++) {
		if (!rights->items[i].name)
			return errAuthorizationInvalidSet;
		int r = evaluateRight(rights->items[i].name);
		if (r == kDenied)
			return errAuthorizationDenied;
		if (r == kNeedsAuthentication) {
			if (!(flags & kAuthorizationFlagExtendRights))
				return errAuthorizationDenied;
			if (!(flags & kAuthorizationFlagInteractionAllowed))
				return errAuthorizationInteractionNotAllowed;
			return errAuthorizationDenied;   /* no SecurityAgent to ask */
		}
	}
	if (authorizedRights && !(flags & kAuthorizationFlagPreAuthorize))
		*authorizedRights = copyItems(rights);
	else if (authorizedRights)
		*authorizedRights = copyItems(rights);
	return errAuthorizationSuccess;
}

void AuthorizationCopyRightsAsync(AuthorizationRef authorization, const AuthorizationRights *rights,
    const AuthorizationEnvironment *environment, AuthorizationFlags flags, AuthorizationAsyncCallback callbackBlock)
{
	AuthorizationRights *granted = NULL;
	OSStatus st = AuthorizationCopyRights(authorization, rights, environment, flags, &granted);
	callbackBlock(st, granted);
}

OSStatus AuthorizationCreate(const AuthorizationRights *rights, const AuthorizationEnvironment *environment,
    AuthorizationFlags flags, AuthorizationRef *authorization)
{
	if (flags & ~(kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPartialRights |
	                 kAuthorizationFlagDestroyRights | kAuthorizationFlagPreAuthorize | kAuthorizationFlagSkipInternalAuth |
	                 kAuthorizationFlagNoData))
		return errAuthorizationInvalidFlags;
	struct AuthorizationOpaqueRef *a = calloc(1, sizeof(*a));
	a->magic = kAuthMagic;
	arc4random_buf(a->token, sizeof(a->token));
	pthread_mutex_lock(&authLock);
	a->next = allRefs;
	allRefs = a;
	pthread_mutex_unlock(&authLock);
	OSStatus st = errAuthorizationSuccess;
	if (rights && rights->count)
		st = AuthorizationCopyRights(a, rights, environment, flags, NULL);
	if (st || !authorization) {
		AuthorizationFree(a, kAuthorizationFlagDefaults);
		return st;
	}
	*authorization = a;
	return errAuthorizationSuccess;
}

OSStatus AuthorizationFree(AuthorizationRef authorization, AuthorizationFlags flags)
{
	pthread_mutex_lock(&authLock);
	for (struct AuthorizationOpaqueRef **p = &allRefs; *p; p = &(*p)->next)
		if (*p == authorization) {
			*p = authorization->next;
			pthread_mutex_unlock(&authLock);
			struct AuthorizationOpaqueRef *a = (struct AuthorizationOpaqueRef *)authorization;
			a->magic = 0;
			free(a);
			return errAuthorizationSuccess;
		}
	pthread_mutex_unlock(&authLock);
	return errAuthorizationInvalidRef;
}

OSStatus AuthorizationCopyInfo(AuthorizationRef authorization, AuthorizationString tag, AuthorizationItemSet **info)
{
	if (!validRef(authorization))
		return errAuthorizationInvalidRef;
	if (!info)
		return errAuthorizationInvalidPointer;
	/* No credentials are ever acquired, so there's no context to report. */
	*info = copyItems(NULL);
	return errAuthorizationSuccess;
}

OSStatus AuthorizationMakeExternalForm(AuthorizationRef authorization, AuthorizationExternalForm *extForm)
{
	if (!validRef(authorization))
		return errAuthorizationInvalidRef;
	if (!extForm)
		return errAuthorizationInvalidPointer;
	memcpy(extForm->bytes, authorization->token, kAuthorizationExternalFormLength);
	return errAuthorizationSuccess;
}

OSStatus AuthorizationCreateFromExternalForm(const AuthorizationExternalForm *extForm, AuthorizationRef *authorization)
{
	if (!extForm || !authorization)
		return errAuthorizationInvalidPointer;
	pthread_mutex_lock(&authLock);
	struct AuthorizationOpaqueRef *found = NULL;
	for (struct AuthorizationOpaqueRef *r = allRefs; r; r = r->next)
		if (!memcmp(r->token, extForm->bytes, kAuthorizationExternalFormLength))
			found = r;
	pthread_mutex_unlock(&authLock);
	if (!found)
		return errAuthorizationInvalidRef;
	/* A second reference to the same authorization (its own handle). */
	struct AuthorizationOpaqueRef *a = calloc(1, sizeof(*a));
	a->magic = kAuthMagic;
	memcpy(a->token, found->token, sizeof(a->token));
	pthread_mutex_lock(&authLock);
	a->next = allRefs;
	allRefs = a;
	pthread_mutex_unlock(&authLock);
	*authorization = a;
	return errAuthorizationSuccess;
}

OSStatus AuthorizationRightGet(const char *rightName, CFDictionaryRef *rightDefinitionOut)
{
	if (!rightName)
		return errAuthorizationInvalidPointer;
	CFDictionaryRef d = rightDefinition(rightName, false);
	if (!d)
		return errAuthorizationDenied;
	if (rightDefinitionOut)
		*rightDefinitionOut = CFDictionaryCreateCopy(NULL, d);
	return errAuthorizationSuccess;
}

OSStatus AuthorizationRightSet(AuthorizationRef authRef, const char *rightName, CFTypeRef rightDefinition,
    CFStringRef descriptionKey, CFBundleRef bundle, CFStringRef localeTableName)
{
	/* The database is Apple's published one, read-only. */
	return validRef(authRef) ? errAuthorizationDenied : errAuthorizationInvalidRef;
}

OSStatus AuthorizationRightRemove(AuthorizationRef authRef, const char *rightName)
{
	return validRef(authRef) ? errAuthorizationDenied : errAuthorizationInvalidRef;
}

/* Runs a tool as root, which only a process that's already root can do here. */
OSStatus AuthorizationExecuteWithPrivileges(AuthorizationRef authorization, const char *pathToTool,
    AuthorizationFlags options, char *const *arguments, FILE **communicationsPipe)
{
	if (!validRef(authorization))
		return errAuthorizationInvalidRef;
	if (!pathToTool)
		return errAuthorizationInvalidPointer;
	if (geteuid() != 0)
		return errAuthorizationDenied;
	int fds[2];
	if (communicationsPipe && pipe(fds) < 0)
		return errAuthorizationToolExecuteFailure;
	pid_t pid = fork();
	if (pid < 0)
		return errAuthorizationToolExecuteFailure;
	if (pid == 0) {
		if (communicationsPipe) {
			dup2(fds[1], 0);
			dup2(fds[1], 1);
			close(fds[0]);
			close(fds[1]);
		}
		int argc = 0;
		while (arguments && arguments[argc])
			argc++;
		char **argv = calloc(argc + 2, sizeof(char *));
		argv[0] = (char *)pathToTool;
		for (int i = 0; i < argc; i++)
			argv[i + 1] = arguments[i];
		execv(pathToTool, argv);
		_exit(127);
	}
	if (communicationsPipe) {
		close(fds[1]);
		*communicationsPipe = fdopen(fds[0], "r+");
	}
	return errAuthorizationSuccess;
}

OSStatus AuthorizationCopyPrivilegedReference(AuthorizationRef *authorization, AuthorizationFlags flags)
{
	return errAuthorizationInvalidRef;
}

/* ---- Security sessions: the audit session ---- */

OSStatus SessionGetInfo(SecuritySessionId session, SecuritySessionId *sessionId, SessionAttributeBits *attributes)
{
	auditinfo_addr_t info;
	memset(&info, 0, sizeof(info));
	if (session == callerSecuritySession) {
		if (getaudit_addr(&info, sizeof(info)) < 0)
			return errSessionInternal;
	} else {
		info.ai_asid = (au_asid_t)session;
		if (audit_session_self() == MACH_PORT_NULL)
			return errSessionInvalidId;
	}
	if (sessionId)
		*sessionId = (SecuritySessionId)info.ai_asid;
	if (attributes)
		*attributes = (SessionAttributeBits)(info.ai_flags &
		    (sessionIsRoot | sessionHasGraphicAccess | sessionHasTTY | sessionIsRemote));
	return errSessionSuccess;
}

OSStatus SessionCreate(SessionCreationFlags flags, SessionAttributeBits attributes)
{
	auditinfo_addr_t info;
	memset(&info, 0, sizeof(info));
	if (getaudit_addr(&info, sizeof(info)) < 0)
		return errSessionInternal;
	info.ai_asid = AU_ASSIGN_ASID;
	info.ai_flags = attributes & (sessionHasGraphicAccess | sessionHasTTY | sessionIsRemote);
	return setaudit_addr(&info, sizeof(info)) < 0 ? errSessionAuthorizationDenied : errSessionSuccess;
}

/* ---- Gatekeeper's assessment control ---- */

/* Finch has no assessment service: assessments are off (as with spctl
 * --master-disable), and nothing else is supported. */
Boolean SecAssessmentControl(CFStringRef control, void *arguments, CFErrorRef *errors)
{
	if (errors)
		*errors = NULL;
	if (control && (CFEqual(control, CFSTR("ui-status")) || CFEqual(control, CFSTR("ui-get-devid")) ||
	                   CFEqual(control, CFSTR("ui-get-devid-local")))) {
		if (arguments)
			*(CFBooleanRef *)arguments = kCFBooleanFalse;
		return true;
	}
	if (errors)
		*errors = _SecCreateError(errSecCSUnimplemented, NULL);
	return false;
}
