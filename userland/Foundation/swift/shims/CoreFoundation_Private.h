// SPDX-License-Identifier: MIT OR Apache-2.0
// CoreFoundation_Private: the private CF functions swift-foundation
// (FOUNDATION_FRAMEWORK) calls. Finch's Foundation implements each
// (userland/Foundation, NSForSwiftFoundation.m).
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>

CF_ASSUME_NONNULL_BEGIN
CF_EXTERN_C_BEGIN

// Start forwarding a system (Darwin) notification to the local center.
CF_EXPORT void _CFNotificationCenterInitializeDependentNotificationIfNecessary(CFStringRef name);

// The current application's preferences (all domains it sees), as one
// dictionary. *wouldDeadlock is set when they couldn't be read safely.
CF_EXPORT CFDictionaryRef __CFXPreferencesCopyCurrentApplicationStateWithDeadlockAvoidance(Boolean *wouldDeadlock);   // +1


// CFUniChar (CF's Unicode tables).
typedef uint32_t UTF32Char;
CF_EXPORT CFIndex CFUniCharDecomposeCharacter(UTF32Char character, UTF32Char *convertedChars, CFIndex maxBufferLength);
CF_EXPORT CFIndex CFUniCharCompatibilityDecompose(UTF32Char *convertedChars, CFIndex length, CFIndex maxBufferLength);

// URL components, percent-encoded or decoded (+1). Built on the public
// byte-range API.
static inline CFStringRef _Nullable __FinchCFURLCopyComponent(CFURLRef url, CFURLComponentType component,
                                                              Boolean removePercentEscapes) {
    CFRange range = CFURLGetByteRangeForComponent(url, component, NULL);
    if (range.location == kCFNotFound) return NULL;
    CFIndex length = CFURLGetBytes(url, NULL, 0);
    if (length <= 0) return NULL;
    UInt8 *bytes = (UInt8 *)malloc((size_t)length);
    CFURLGetBytes(url, bytes, length);
    CFStringRef raw = CFStringCreateWithBytes(kCFAllocatorDefault, bytes + range.location, range.length,
                                              kCFStringEncodingUTF8, false);
    free(bytes);
    if (!raw || !removePercentEscapes) return raw;
    CFStringRef decoded = CFURLCreateStringByReplacingPercentEscapes(kCFAllocatorDefault, raw, CFSTR(""));
    CFRelease(raw);
    return decoded;
}
static inline CFStringRef _Nullable _CFURLCopyUserName(CFURLRef url, Boolean removePercentEscapes) {
    return __FinchCFURLCopyComponent(url, kCFURLComponentUser, removePercentEscapes);
}
static inline CFStringRef _Nullable _CFURLCopyPassword(CFURLRef url, Boolean removePercentEscapes) {
    return __FinchCFURLCopyComponent(url, kCFURLComponentPassword, removePercentEscapes);
}
static inline CFStringRef _Nullable _CFURLCopyHostName(CFURLRef url, Boolean removePercentEscapes) {
    return __FinchCFURLCopyComponent(url, kCFURLComponentHost, removePercentEscapes);
}
static inline CFStringRef _Nullable _CFURLCopyPath(CFURLRef url, Boolean removePercentEscapes) {
    return __FinchCFURLCopyComponent(url, kCFURLComponentPath, removePercentEscapes);
}
static inline CFStringRef _Nullable _CFURLCopyQueryString(CFURLRef url, Boolean removePercentEscapes) {
    return __FinchCFURLCopyComponent(url, kCFURLComponentQuery, removePercentEscapes);
}
static inline CFStringRef _Nullable _CFURLCopyFragment(CFURLRef url, Boolean removePercentEscapes) {
    return __FinchCFURLCopyComponent(url, kCFURLComponentFragment, removePercentEscapes);
}
static inline CFURLRef _CFURLCreateCopyAppendingPathComponent(CFURLRef url, CFStringRef pathComponent,
                                                              Boolean isDirectory) {
    return CFURLCreateCopyAppendingPathComponent(kCFAllocatorDefault, url, pathComponent, isDirectory);
}

// A CFURL for a URL string swift-foundation has already parsed (Apple's CF
// takes the component ranges too; Finch's parses again).
static inline CFURLRef _CFURLCreateWithRangesAndFlags(CFStringRef string, const CFRange *ranges, UInt8 numberOfRanges,
                                                      UInt32 flags, CFURLRef _Nullable baseURL) CF_RETURNS_RETAINED {
    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, string, baseURL);
    if (url) return url;
    CFIndex length = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8);
    UInt8 *bytes = (UInt8 *)malloc((size_t)length + 1);
    CFIndex used = 0;
    CFStringGetBytes(string, CFRangeMake(0, CFStringGetLength(string)), kCFStringEncodingUTF8, 0, false, bytes, length, &used);
    url = CFURLCreateWithBytes(kCFAllocatorDefault, bytes, used, kCFStringEncodingUTF8, baseURL);
    free(bytes);
    return url ? url : CFURLCreateWithString(kCFAllocatorDefault, CFSTR("about:blank"), NULL);
}

// The executable's path.
CF_EXPORT const char * _Nullable _CFProcessPath(void);

// Values of the locale preferences in a preferences dictionary (from
// __CFXPreferencesCopyCurrentApplicationStateWithDeadlockAvoidance), each
// +1 and only when of the expected type.
static inline CFTypeRef _Nullable __FinchCFLocalePrefsCopy(CFDictionaryRef prefs, CFStringRef key, CFTypeID type) {
    CFTypeRef v = CFDictionaryGetValue(prefs, key);
    if (!v || CFGetTypeID(v) != type) return NULL;
    return CFRetain(v);
}
static inline CFArrayRef _Nullable __CFLocalePrefsCopyAppleLanguages(CFDictionaryRef prefs) {
    return (CFArrayRef)__FinchCFLocalePrefsCopy(prefs, CFSTR("AppleLanguages"), CFArrayGetTypeID());
}
static inline CFStringRef _Nullable __CFLocalePrefsCopyAppleLocale(CFDictionaryRef prefs) {
    return (CFStringRef)__FinchCFLocalePrefsCopy(prefs, CFSTR("AppleLocale"), CFStringGetTypeID());
}
static inline CFStringRef _Nullable __CFLocalePrefsCopyAppleCollationOrder(CFDictionaryRef prefs) {
    return (CFStringRef)__FinchCFLocalePrefsCopy(prefs, CFSTR("AppleCollationOrder"), CFStringGetTypeID());
}
static inline CFStringRef _Nullable __CFLocalePrefsCopyCountry(CFDictionaryRef prefs) {
    return (CFStringRef)__FinchCFLocalePrefsCopy(prefs, CFSTR("Country"), CFStringGetTypeID());
}
#define FINCH_LOCALE_PREFS_DICT(fn, key) \
    static inline CFDictionaryRef _Nullable fn(CFDictionaryRef prefs) { \
        return (CFDictionaryRef)__FinchCFLocalePrefsCopy(prefs, CFSTR(key), CFDictionaryGetTypeID()); \
    }
FINCH_LOCALE_PREFS_DICT(__CFLocalePrefsCopyAppleICUDateTimeSymbols, "AppleICUDateTimeSymbols")
FINCH_LOCALE_PREFS_DICT(__CFLocalePrefsCopyAppleICUDateFormatStrings, "AppleICUDateFormatStrings")
FINCH_LOCALE_PREFS_DICT(__CFLocalePrefsCopyAppleICUTimeFormatStrings, "AppleICUTimeFormatStrings")
FINCH_LOCALE_PREFS_DICT(__CFLocalePrefsCopyAppleICUNumberFormatStrings, "AppleICUNumberFormatStrings")
FINCH_LOCALE_PREFS_DICT(__CFLocalePrefsCopyAppleICUNumberSymbols, "AppleICUNumberSymbols")
FINCH_LOCALE_PREFS_DICT(__CFLocalePrefsCopyAppleFirstWeekday, "AppleFirstWeekday")
FINCH_LOCALE_PREFS_DICT(__CFLocalePrefsCopyAppleMinDaysInFirstWeek, "AppleMinDaysInFirstWeek")
#undef FINCH_LOCALE_PREFS_DICT

/// A boolean preference: `key` set (to a boolean, or to the string `match`).
static inline Boolean __FinchCFLocalePrefsBool(CFDictionaryRef prefs, CFStringRef key,
                                               CFStringRef _Nullable match, Boolean *exists) {
    CFTypeRef v = CFDictionaryGetValue(prefs, key);
    *exists = v != NULL;
    if (!v) return false;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)v);
    if (match && CFGetTypeID(v) == CFStringGetTypeID()) return CFEqual(v, match);
    *exists = false;
    return false;
}
static inline Boolean __CFLocalePrefsAppleMetricUnitsIsMetric(CFDictionaryRef prefs, Boolean *exists) {
    return __FinchCFLocalePrefsBool(prefs, CFSTR("AppleMetricUnits"), NULL, exists);
}
static inline Boolean __CFLocalePrefsAppleMeasurementUnitsIsCm(CFDictionaryRef prefs, Boolean *exists) {
    return __FinchCFLocalePrefsBool(prefs, CFSTR("AppleMeasurementUnits"), CFSTR("Centimeters"), exists);
}
static inline Boolean __CFLocalePrefsAppleTemperatureUnitIsC(CFDictionaryRef prefs, Boolean *exists) {
    return __FinchCFLocalePrefsBool(prefs, CFSTR("AppleTemperatureUnit"), CFSTR("Celsius"), exists);
}
static inline Boolean __CFLocalePrefsAppleForce24HourTime(CFDictionaryRef prefs, Boolean *exists) {
    return __FinchCFLocalePrefsBool(prefs, CFSTR("AppleICUForce24HourTime"), NULL, exists);
}
static inline Boolean __CFLocalePrefsAppleForce12HourTime(CFDictionaryRef prefs, Boolean *exists) {
    return __FinchCFLocalePrefsBool(prefs, CFSTR("AppleICUForce12HourTime"), NULL, exists);
}

CF_EXTERN_C_END
CF_ASSUME_NONNULL_END
