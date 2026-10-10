/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Web services (private SPI Apple's CoreFoundation exports): which provider serves a
 * kind of web service, such as web search, for "Search With ..." menu items. The
 * user's choice is the NSPreferredWebServices preference (a dictionary of service
 * types to provider dictionaries, in the global domain), else NSDefaultWebServices,
 * else Finch's default; the out-parameter says whether it was the user's.
 */

#include <CoreFoundation/CoreFoundation.h>

CF_EXPORT const CFStringRef kCFWebServicesProviderDefaultDisplayNameKey;
CF_EXPORT const CFStringRef kCFWebServicesProviderIdentifierKey;
CF_EXPORT const CFStringRef kCFWebServicesTypeWebSearch;
const CFStringRef kCFWebServicesProviderDefaultDisplayNameKey = CFSTR("NSDefaultDisplayName");
const CFStringRef kCFWebServicesProviderIdentifierKey = CFSTR("NSProviderIdentifier");
const CFStringRef kCFWebServicesTypeWebSearch = CFSTR("NSWebServicesProviderWebSearch");

CF_EXPORT CFDictionaryRef _CFWebServicesCopyProviderInfo(CFStringRef serviceType, Boolean *outIsUserSelection);

static CFDictionaryRef
provider_for_key(CFStringRef serviceType, CFStringRef key)
{
    CFPropertyListRef all = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                                   kCFPreferencesAnyHost);
    CFDictionaryRef result = NULL;
    if (all && CFGetTypeID(all) == CFDictionaryGetTypeID()) {
        CFTypeRef p = CFDictionaryGetValue(all, serviceType);
        if (p && CFGetTypeID(p) == CFDictionaryGetTypeID())
            result = CFRetain(p);
    }
    if (all)
        CFRelease(all);
    return result;
}

CFDictionaryRef
_CFWebServicesCopyProviderInfo(CFStringRef serviceType, Boolean *outIsUserSelection)
{
    if (outIsUserSelection)
        *outIsUserSelection = false;
    if (!serviceType)
        return NULL;
    CFDictionaryRef p = provider_for_key(serviceType, CFSTR("NSPreferredWebServices"));
    if (p) {
        if (outIsUserSelection)
            *outIsUserSelection = true;
        return p;
    }
    p = provider_for_key(serviceType, CFSTR("NSDefaultWebServices"));
    if (p)
        return p;
    if (!CFEqual(serviceType, kCFWebServicesTypeWebSearch))
        return NULL;
    /* Apple's default, so apps' menus read as they do on macOS */
    const void *keys[] = {kCFWebServicesProviderDefaultDisplayNameKey, kCFWebServicesProviderIdentifierKey};
    const void *values[] = {CFSTR("Google"), CFSTR("com.google.www")};
    return CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
