/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSUserDefaults, which Apple's CoreFoundation hosts
 * (docs/design/FOUNDATION.md), over CFPreferences. A value is looked up in
 * the argument domain (-key value on the command line, the value read as a
 * property list when it is one), then the app's (or suite's) domain and the
 * global domain (CFPreferences searches both), then the registration
 * domain (-registerDefaults:). The typed getters convert as Apple's do.
 * Changes post NSUserDefaultsDidChangeNotification.
 */
#include "CFObjCClasses_Finch.h"
#include <crt_externs.h>
#include "CFPreferences.h"

@interface NSObject (FinchDefaults)
+ (id)defaultCenter;
- (void)postNotificationName:(id)name object:(id)object;
- (id)stringValue;
- (NSInteger)integerValue;
- (double)doubleValue;
- (float)floatValue;
- (BOOL)boolValue;
@end
@interface NSArray (FinchDefaults)
- (NSUInteger)count;
@end
@interface NSNumber (FinchDefaults)
+ (id)numberWithInteger:(NSInteger)v;
+ (id)numberWithDouble:(double)v;
+ (id)numberWithFloat:(float)v;
+ (id)numberWithBool:(BOOL)v;
@end
@interface NSURL (FinchDefaults)
+ (id)fileURLWithPath:(id)path;
+ (id)URLWithString:(id)s;
- (id)absoluteString;
- (BOOL)isFileURL;
- (id)path;
@end

static BOOL
is_kind(id o, const char *cls)
{
    Class c = objc_getClass(cls);
    return o && c && [o isKindOfClass:c];
}

@interface NSUserDefaults : NSObject {
    CFStringRef _app;
    CFMutableDictionaryRef _registration;
    CFMutableDictionaryRef _volatile;
}
@end

static CFDictionaryRef arguments;

/* "-key value" pairs from the command line, values parsed as property lists
 * ("-flag YES" stays the string "YES", as on macOS). */
static CFDictionaryRef
argument_domain(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        int argc = *_NSGetArgc();
        char **argv = *_NSGetArgv();
        for (int i = 1; i + 1 < argc; i++) {
            if (argv[i][0] != '-' || argv[i][1] == 0 || argv[i][1] == '-') continue;
            CFStringRef key = CFStringCreateWithCString(NULL, argv[i] + 1, kCFStringEncodingUTF8);
            CFStringRef raw = CFStringCreateWithCString(NULL, argv[i + 1], kCFStringEncodingUTF8);
            CFTypeRef value = raw;
            CFDataRef data = CFDataCreate(NULL, (const UInt8 *)argv[i + 1], (CFIndex)strlen(argv[i + 1]));
            CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
            if (plist && CFGetTypeID(plist) != CFStringGetTypeID()) value = plist;
            if (key && value) CFDictionarySetValue(d, key, value);
            if (plist) CFRelease(plist);
            CFRelease(data);
            if (raw) CFRelease(raw);
            if (key) CFRelease(key);
            i++;
        }
        arguments = d;
    });
    return arguments;
}

static void
set_entry(const void *key, const void *value, void *dict)
{
    CFDictionarySetValue((CFMutableDictionaryRef)dict, key, value);
}

static NSUserDefaults *standard;

@implementation NSUserDefaults

+ (instancetype)standardUserDefaults
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ standard = [[NSUserDefaults alloc] init]; });
    return standard;
}

+ (void)resetStandardUserDefaults
{
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

- (instancetype)init { return [self initWithSuiteName:nil]; }

- (instancetype)initWithSuiteName:(id)suite
{
    if ((self = [super init])) {
        _app = suite ? CFStringCreateCopy(NULL, (CFStringRef)suite) : (CFStringRef)CFRetain(kCFPreferencesCurrentApplication);
        _registration = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        _volatile = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    return self;
}

- (instancetype)initWithUser:(id)username { return [self initWithSuiteName:nil]; }

- (void)dealloc
{
    CFRelease(_app);
    CFRelease(_registration);
    CFRelease(_volatile);
    [super dealloc];
}

/* Key-value coding reads and writes defaults, as Apple's does (bindings and
   apps use valueForKey: on the defaults directly). */
- (id)valueForKey:(NSString *)key { return [self objectForKey:key]; }
- (void)setValue:(id)value forKey:(NSString *)key
{
    if (value)
        [self setObject:value forKey:key];
    else
        [self removeObjectForKey:key];
}

- (id)objectForKey:(id)key
{
    if (!key) return nil;
    CFTypeRef v = CFDictionaryGetValue(argument_domain(), key);
    if (v) return (id)v;
    CFPropertyListRef p = CFPreferencesCopyAppValue((CFStringRef)key, _app);
    if (p) return [(id)p autorelease];
    return (id)CFDictionaryGetValue(_registration, key);
}

static void
changed(NSUserDefaults *self)
{
    Class center = objc_getClass("NSNotificationCenter");
    [[center defaultCenter] postNotificationName:(id)CFSTR("NSUserDefaultsDidChangeNotification") object:self];
}

- (void)setObject:(id)value forKey:(id)key
{
    if (!key) __CFFinchRaise(NSInvalidArgumentException, "*** -[NSUserDefaults setObject:forKey:]: attempt to insert nil key");
    if (value && !CFPropertyListIsValid((CFPropertyListRef)value, kCFPropertyListBinaryFormat_v1_0))
        __CFFinchRaise(NSInvalidArgumentException, "Attempt to insert non-property list object %@ for key %@", value, key);
    CFPreferencesSetAppValue((CFStringRef)key, (CFPropertyListRef)value, _app);
    changed(self);
}

- (void)removeObjectForKey:(id)key { [self setObject:nil forKey:key]; }

- (id)stringForKey:(id)key
{
    id v = [self objectForKey:key];
    if (is_kind(v, "NSString")) return v;
    if (is_kind(v, "NSNumber")) return [v stringValue];
    return nil;
}
- (id)arrayForKey:(id)key { id v = [self objectForKey:key]; return is_kind(v, "NSArray") ? v : nil; }
- (id)dictionaryForKey:(id)key { id v = [self objectForKey:key]; return is_kind(v, "NSDictionary") ? v : nil; }
- (id)dataForKey:(id)key { id v = [self objectForKey:key]; return is_kind(v, "NSData") ? v : nil; }
- (id)stringArrayForKey:(id)key
{
    id v = [self arrayForKey:key];
    for (id o in v)
        if (!is_kind(o, "NSString")) return nil;
    return v;
}

static BOOL
numeric(id v)
{
    return is_kind(v, "NSNumber") || is_kind(v, "NSString");
}

- (NSInteger)integerForKey:(id)key { id v = [self objectForKey:key]; return numeric(v) ? [v integerValue] : 0; }
- (float)floatForKey:(id)key { id v = [self objectForKey:key]; return numeric(v) ? [v floatValue] : 0; }
- (double)doubleForKey:(id)key { id v = [self objectForKey:key]; return numeric(v) ? [v doubleValue] : 0; }
- (BOOL)boolForKey:(id)key
{
    id v = [self objectForKey:key];
    if (is_kind(v, "NSString")) {
        CFStringRef s = (CFStringRef)v;
        if (CFStringCompare(s, CFSTR("YES"), kCFCompareCaseInsensitive) == kCFCompareEqualTo ||
            CFStringCompare(s, CFSTR("true"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) return YES;
        return [v integerValue] != 0;
    }
    return is_kind(v, "NSNumber") ? [v boolValue] : NO;
}

- (id)URLForKey:(id)key
{
    id v = [self objectForKey:key];
    if (is_kind(v, "NSString")) {
        Class url = objc_getClass("NSURL");
        return CFStringHasPrefix((CFStringRef)v, CFSTR("/")) || CFStringHasPrefix((CFStringRef)v, CFSTR("~"))
            ? [url fileURLWithPath:v] : [url URLWithString:v];
    }
    return nil;
}

- (void)setInteger:(NSInteger)v forKey:(id)key { [self setObject:[objc_getClass("NSNumber") numberWithInteger:v] forKey:key]; }
- (void)setFloat:(float)v forKey:(id)key { [self setObject:[objc_getClass("NSNumber") numberWithFloat:v] forKey:key]; }
- (void)setDouble:(double)v forKey:(id)key { [self setObject:[objc_getClass("NSNumber") numberWithDouble:v] forKey:key]; }
- (void)setBool:(BOOL)v forKey:(id)key { [self setObject:(id)(v ? kCFBooleanTrue : kCFBooleanFalse) forKey:key]; }
- (void)setURL:(id)url forKey:(id)key
{
    [self setObject:url ? ([url isFileURL] ? [url path] : [url absoluteString]) : nil forKey:key];
}

- (void)registerDefaults:(id)registrationDictionary
{
    CFDictionaryApplyFunction((CFDictionaryRef)registrationDictionary, set_entry, _registration);
}

- (BOOL)synchronize { return CFPreferencesAppSynchronize(_app); }

- (id)dictionaryRepresentation
{
    CFMutableDictionaryRef all = CFDictionaryCreateMutableCopy(NULL, 0, _registration);
    CFDictionaryRef global = CFPreferencesCopyMultiple(NULL, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFDictionaryRef app = CFPreferencesCopyMultiple(NULL, _app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFDictionaryRef src[] = { global, app, argument_domain() };
    for (int i = 0; i < 3; i++)
        if (src[i]) CFDictionaryApplyFunction(src[i], set_entry, all);
    if (global) CFRelease(global);
    if (app) CFRelease(app);
    return [(id)all autorelease];
}

- (id)persistentDomainForName:(id)domain
{
    CFDictionaryRef d = CFPreferencesCopyMultiple(NULL, (CFStringRef)domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (d && CFDictionaryGetCount(d) == 0) { CFRelease(d); return nil; }
    return d ? [(id)d autorelease] : nil;
}

- (void)setPersistentDomain:(id)domain forName:(id)name
{
    [self removePersistentDomainForName:name];
    CFPreferencesSetMultiple((CFDictionaryRef)domain, NULL, (CFStringRef)name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize((CFStringRef)name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    changed(self);
}

- (void)removePersistentDomainForName:(id)name
{
    CFArrayRef keys = CFPreferencesCopyKeyList((CFStringRef)name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        CFPreferencesSetMultiple(NULL, keys, (CFStringRef)name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keys);
    }
    CFPreferencesSynchronize((CFStringRef)name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    changed(self);
}

- (id)volatileDomainForName:(id)name
{
    return (id)CFDictionaryGetValue(_volatile, name);
}

- (void)setVolatileDomain:(id)domain forName:(id)name
{
    if (CFDictionaryContainsKey(_volatile, name))
        __CFFinchRaise(NSInvalidArgumentException, "*** -[NSUserDefaults setVolatileDomain:forName:]: A domain named %@ already exists", name);
    CFDictionarySetValue(_volatile, name, domain);
}

- (void)removeVolatileDomainForName:(id)name { CFDictionaryRemoveValue(_volatile, name); }

- (id)volatileDomainNames
{
    CFIndex n = CFDictionaryGetCount(_volatile);
    const void **keys = malloc(((size_t)n + 1) * sizeof(void *));
    CFDictionaryGetKeysAndValues(_volatile, keys, NULL);
    CFArrayRef a = CFArrayCreate(NULL, keys, n, &kCFTypeArrayCallBacks);
    free(keys);
    return [(id)a autorelease];
}

- (void)addSuiteNamed:(id)suite { CFPreferencesAddSuitePreferencesToApp(_app, (CFStringRef)suite); }
- (void)removeSuiteNamed:(id)suite { CFPreferencesRemoveSuitePreferencesFromApp(_app, (CFStringRef)suite); }
- (BOOL)objectIsForcedForKey:(id)key { return NO; }
- (BOOL)objectIsForcedForKey:(id)key inDomain:(id)domain { return NO; }

@end
