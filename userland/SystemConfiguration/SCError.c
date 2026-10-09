/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* SCError, SCErrorString and SCCopyLastError, with Apple's messages and the
 * same fallbacks (strerror, bootstrap and Mach error strings). */
#include "SCFinch.h"
#include <errno.h>
#include <mach/mach_error.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <string.h>

static _Thread_local int lastError;

void _SCErrorSet(int error)
{
	lastError = error;
}

int SCError(void)
{
	return lastError;
}

CFTypeRef _SCCreateInstance(CFTypeID type, size_t size)
{
	return _CFRuntimeCreateInstance(NULL, type, size - sizeof(CFRuntimeBase), NULL);
}

static const struct {
	int status;
	const char *message;
} messages[] = {
	{kSCStatusAccessError, "Permission denied"},
	{kSCStatusConnectionIgnore, "Network connection information not available at this time"},
	{kSCStatusConnectionNoService, "Network service for connection not available"},
	{kSCStatusFailed, "Failed!"},
	{kSCStatusInvalidArgument, "Invalid argument"},
	{kSCStatusKeyExists, "Key already defined"},
	{kSCStatusLocked, "Lock already held"},
	{kSCStatusMaxLink, "Maximum link count exceeded"},
	{kSCStatusNeedLock, "Lock required for this operation"},
	{kSCStatusNoStoreServer, "Configuration daemon not (no longer) available"},
	{kSCStatusNoStoreSession, "Configuration daemon session not active"},
	{kSCStatusNoConfigFile, "Configuration file not found"},
	{kSCStatusNoKey, "No such key"},
	{kSCStatusNoLink, "No such link"},
	{kSCStatusNoPrefsSession, "Preference session not active"},
	{kSCStatusNotifierActive, "Notifier is currently active"},
	{kSCStatusOK, "Success!"},
	{kSCStatusPrefsBusy, "Preferences update currently in progress"},
	{kSCStatusReachabilityUnknown, "Network reachability cannot be determined"},
	{kSCStatusStale, "Write attempted on stale version of object"},
};

const char *SCErrorString(int status)
{
	for (size_t i = 0; i < sizeof(messages) / sizeof(*messages); i++)
		if (messages[i].status == status)
			return messages[i].message;
	if (status > 0 && status <= ELAST)
		return strerror(status);
	if (status >= BOOTSTRAP_SUCCESS && status <= BOOTSTRAP_NO_MEMORY)
		return bootstrap_strerror(status);
	const char *err = mach_error_string(status);
	return err ? err : strerror(status);
}

CFErrorRef SCCopyLastError(void)
{
	int code = lastError;
	CFStringRef domain = kCFErrorDomainMach;
	CFMutableDictionaryRef info = NULL;
	for (size_t i = 0; i < sizeof(messages) / sizeof(*messages); i++)
		if (messages[i].status == code) {
			domain = kCFErrorDomainSystemConfiguration;
			info = CFDictionaryCreateMutable(NULL, 0, &kCFCopyStringDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			CFStringRef s = CFStringCreateWithCString(NULL, messages[i].message, kCFStringEncodingASCII);
			CFDictionarySetValue(info, kCFErrorDescriptionKey, s);
			CFRelease(s);
			break;
		}
	if (!info && code > 0 && code <= ELAST)
		domain = kCFErrorDomainPOSIX;
	CFErrorRef e = CFErrorCreate(NULL, domain, code, info);
	if (info)
		CFRelease(info);
	return e;
}
