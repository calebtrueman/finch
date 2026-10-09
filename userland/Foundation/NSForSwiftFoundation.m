/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The Objective-C side of Foundation's Swift half (swift/overlay.sh). Apple's
 * Foundation compiles swift-foundation into itself (FOUNDATION_FRAMEWORK),
 * which calls private Objective-C and CF API; Finch's declarations of that
 * API are in swift/shims (_ForSwiftFoundation.h, Foundation_Private.h,
 * CoreFoundation_Private.h) and this file implements what they declare,
 * plus the public classes and constants the Swift half refers to that
 * Finch's Foundation didn't have yet (NSPersonNameComponents,
 * NSFileSecurity, NSLocalizedNumberFormatRule, the Markdown and inflection
 * attribute names).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <os/log.h>

#import "swift/shims/_ForSwiftFoundation.h"

/* MARK: - The class-cluster bridges */

/* swift-foundation's _NSSwiftCalendar, _NSSwiftLocale and _NSSwiftTimeZone
 * (NSCalendar, NSLocale and NSTimeZone implemented over Calendar, Locale and
 * TimeZone) subclass these. They make an ordinary instance (not the
 * cluster's placeholder) and route the public methods that take
 * nil-tolerant arguments to the primitives the Swift subclass overrides. */

/* (NSObject's -init does nothing; NSCalendar and NSLocale mark theirs unavailable.) */
@implementation _NSCalendarBridge
@dynamic timeZone;   /* the Swift subclass implements it */
- (instancetype)initWithCheckedCalendarIdentifier:(NSCalendarIdentifier)ident { return self; }
- (NSDate *)dateFromComponents:(NSDateComponents *)comps { return comps ? [self _dateFromComponents:comps] : nil; }
- (NSDateComponents *)components:(NSCalendarUnit)unitFlags fromDate:(NSDate *)date
{
    return date ? [self _components:unitFlags fromDate:date] : nil;
}
- (NSDateComponents *)componentsInTimeZone:(NSTimeZone *)timezone fromDate:(NSDate *)date
{
    return (timezone && date) ? [self _componentsInTimeZone:timezone fromDate:date] : nil;
}
- (void)enumerateDatesStartingAfterDate:(NSDate *)start matchingComponents:(NSDateComponents *)comps
                                options:(NSCalendarOptions)opts
                             usingBlock:(void (NS_NOESCAPE ^)(NSDate *, BOOL, BOOL *))block
{
    if (start && comps && block) [self _enumerateDatesStartingAfterDate:start matchingComponents:comps options:opts usingBlock:block];
}
/* Overridden by the Swift subclass. */
- (NSDate *)_dateFromComponents:(NSDateComponents *)comps { [self doesNotRecognizeSelector:_cmd]; return nil; }
- (NSDateComponents *)_components:(NSCalendarUnit)unitFlags fromDate:(NSDate *)date { [self doesNotRecognizeSelector:_cmd]; return nil; }
- (NSDateComponents *)_componentsInTimeZone:(NSTimeZone *)timezone fromDate:(NSDate *)date { [self doesNotRecognizeSelector:_cmd]; return nil; }
- (void)_enumerateDatesStartingAfterDate:(NSDate *)start matchingComponents:(NSDateComponents *)comps
                                 options:(NSCalendarOptions)opts
                              usingBlock:(void (NS_NOESCAPE ^)(NSDate *, BOOL, BOOL *))block
{
    [self doesNotRecognizeSelector:_cmd];
}
@end

@implementation _NSLocaleBridge
- (instancetype)initWithLocaleIdentifier:(NSString *)string { return self; }
@end

@implementation _NSTimeZoneBridge
- (instancetype)init { return [super init]; }
@end

/* What an autoupdating calendar or locale archives as (classForCoder). */
@implementation _NSAutoCalendar
+ (instancetype)allocWithZone:(struct _NSZone *)zone { return (id)[[NSCalendar autoupdatingCurrentCalendar] retain]; }
@end
@implementation NSAutoLocale
+ (instancetype)allocWithZone:(struct _NSZone *)zone { return (id)[[NSLocale autoupdatingCurrentLocale] retain]; }
@end

/* The local (default) time zone, followed as it changes. */
@implementation __NSLocalTimeZone
- (NSTimeZone *)_current { return [NSTimeZone defaultTimeZone]; }
- (NSString *)name { return [[self _current] name]; }
- (NSData *)data { return [[self _current] data]; }
- (NSInteger)secondsFromGMTForDate:(NSDate *)aDate { return [[self _current] secondsFromGMTForDate:aDate]; }
- (NSString *)abbreviationForDate:(NSDate *)aDate { return [[self _current] abbreviationForDate:aDate]; }
- (BOOL)isDaylightSavingTimeForDate:(NSDate *)aDate { return [[self _current] isDaylightSavingTimeForDate:aDate]; }
- (NSTimeInterval)daylightSavingTimeOffsetForDate:(NSDate *)aDate { return [[self _current] daylightSavingTimeOffsetForDate:aDate]; }
- (NSDate *)nextDaylightSavingTimeTransitionAfterDate:(NSDate *)aDate
{
    return [[self _current] nextDaylightSavingTimeTransitionAfterDate:aDate];
}
- (NSString *)description { return [NSString stringWithFormat:@"Local Time Zone (%@)", [[self _current] description]]; }
- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }
@end

/* MARK: - Private methods of the public classes */

@implementation NSFileManager (NSFileManagerForSwiftFoundation)
- (BOOL)getFileSystemRepresentation:(char *)buffer maxLength:(NSInteger)maxLength withPath:(NSString *)path
{
    return [path getFileSystemRepresentation:buffer maxLength:(NSUInteger)maxLength];
}
/* The trash for a file: the user's ~/.Trash for their own volume. */
- (NSURL *)_URLForTrashingItemAtURL:(NSURL *)url create:(BOOL)create error:(NSError **)error
{
    NSURL *trash = [[NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES] URLByAppendingPathComponent:@".Trash" isDirectory:YES];
    if (create && ![self createDirectoryAtURL:trash withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return trash;
}
/* A fresh directory to build a replacement for the item in (on the same
 * volume, so the replacement can be renamed into place). */
- (NSURL *)_URLForReplacingItemAtURL:(NSURL *)url error:(NSError **)error
{
    NSString *dir = [[url path] stringByDeletingLastPathComponent];
    NSString *tmpl = [dir stringByAppendingPathComponent:@".finch-replacement.XXXXXX"];
    char path[PATH_MAX];
    if (![tmpl getFileSystemRepresentation:path maxLength:sizeof path] || !mkdtemp(path)) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return nil;
    }
    return [NSURL fileURLWithFileSystemRepresentation:path isDirectory:YES relativeToURL:nil];
}
- (id<NSFileManagerDelegate>)_safeDelegate { return [[self.delegate retain] autorelease]; }
- (BOOL)_handleFaultedOutCloudDocFromSource:(NSURL *)source toDestination:(NSURL *)destination
                                    handled:(BOOL *)handled error:(NSError **)error
{
    if (handled) *handled = NO;
    return YES;
}
@end

@implementation NSURL (NSURLForSwiftFoundation)
- (CFURLRef)_cfurl { return (CFURLRef)self; }
- (NSURL *)_trueSelf { return self; }
- (NSString *)_parameterString { return nil; }
@end

@implementation NSLocale (NSLocaleForSwiftFoundation)
+ (NSArray<NSString *> *)systemLanguages { return @[ @"en" ]; }
- (NSString *)localizedStringForCurrencySymbol:(NSString *)currencySymbol
{
    return [self displayNameForKey:NSLocaleCurrencySymbol value:currencySymbol];
}
- (id)_prefForKey:(NSString *)key { return nil; }
- (NSString *)_numberingSystem { return @"latn"; }
- (NSString *)_identifierCapturingPreferences { return [self localeIdentifier]; }
@end

@implementation NSString (NSStringForSwiftFoundation)
- (const char *)_fastCStringContents:(BOOL)nullTerminationRequired
{
    return CFStringGetCStringPtr((CFStringRef)self, kCFStringEncodingASCII);
}
@end

@implementation NSBundle (NSBundleForSwiftFoundation)
- (id)_objectForUnlocalizedInfoDictionaryKey:(NSString *)key { return [[self infoDictionary] objectForKey:key]; }
@end

/* MARK: - Functions */

NSInteger __NSDateComponentsWeek(id dc) { return [(NSDateComponents *)dc week]; }
void __NSDateComponentsSetWeek(id dc, NSInteger week) { [(NSDateComponents *)dc setWeek:week]; }
BOOL __NSDateComponentsIsLeapMonthSet(id dc) { return [[dc valueForKey:@"_leapMonthSet"] boolValue]; }
BOOL __NSDateComponentsIsRepeatedDaySet(id dc) { return NO; }

NSIndexPath *_NSIndexPathCreateFromIndexes(NSInteger index1, NSInteger index2)
{
    NSUInteger indexes[2] = { (NSUInteger)index1, (NSUInteger)index2 };
    return [[NSIndexPath alloc] initWithIndexes:indexes length:2];
}

NSString *const NSFileAttributeStringEncoding = @"com.apple.TextEncoding";
BOOL _NSFileCompressionTypeIsSafeForMapping(const char *path) { return YES; }

NSArray<NSString *> *_NSDirectoryContentsFromCFURLEnumeratorError(NSURL *url, NSArray<NSURLResourceKey> *keys,
                                                                 NSUInteger options, BOOL namesOnly, NSError **error)
{
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[url path] error:error];
}

NSString *_NSCodeSigningIdentifierForCurrentProcess(void) { return [[NSBundle mainBundle] bundleIdentifier]; }

os_log_t _NSOSLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.apple.Foundation", "general"); });
    return log;
}

os_log_t _NSRuntimeIssuesLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.apple.runtime-issues", "Foundation"); });
    return log;
}

/* Finch's CF posts its locale and time zone notifications locally already. */
void _CFNotificationCenterInitializeDependentNotificationIfNecessary(CFStringRef name) {}

/* The preferences an application sees: its own domain over the global one. */
CFDictionaryRef __CFXPreferencesCopyCurrentApplicationStateWithDeadlockAvoidance(Boolean *wouldDeadlock)
{
    if (wouldDeadlock) *wouldDeadlock = false;
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                              &kCFTypeDictionaryValueCallBacks);
    CFStringRef apps[2] = { kCFPreferencesAnyApplication, kCFPreferencesCurrentApplication };
    for (int i = 0; i < 2; i++) {
        CFArrayRef keys = CFPreferencesCopyKeyList(apps[i], kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (!keys) continue;
        CFDictionaryRef values = CFPreferencesCopyMultiple(keys, apps[i], kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (values) {
            CFIndex n = CFDictionaryGetCount(values);
            const void **k = malloc(sizeof(void *) * (size_t)n), **v = malloc(sizeof(void *) * (size_t)n);
            CFDictionaryGetKeysAndValues(values, k, v);
            for (CFIndex j = 0; j < n; j++) CFDictionarySetValue(result, k[j], v[j]);
            free(k);
            free(v);
            CFRelease(values);
        }
        CFRelease(keys);
    }
    return result;
}

/* MARK: - Attribute names (NSAttributedString.h), with Apple's values */

NSAttributedStringKey const NSInflectionAgreementArgumentAttributeName = @"NSInflectionAgreementArgument";
NSAttributedStringKey const NSInflectionAgreementConceptAttributeName = @"NSInflectionAgreementConcept";
NSAttributedStringKey const NSInflectionAlternativeAttributeName = @"NSInflectionAlternative";
NSAttributedStringKey const NSInflectionReferentConceptAttributeName = @"NSInflectionReferentConcept";
NSAttributedStringKey const NSInflectionRuleAttributeName = @"NSInflect";
NSAttributedStringKey const NSInlinePresentationIntentAttributeName = @"NSInlinePresentationIntent";
NSAttributedStringKey const NSListItemDelimiterAttributeName = @"NSListItemDelimiter";
NSAttributedStringKey const NSLocalizedNumberFormatAttributeName = @"NSLocalizedNumberFormat";
NSAttributedStringKey const NSMarkdownSourcePositionAttributeName = @"NSMarkdownSourcePosition";
NSAttributedStringKey const NSMorphologyAttributeName = @"NSMorphology";
NSAttributedStringKey const NSPresentationIntentAttributeName = @"NSPresentationIntent";

/* MARK: - Classes */

@implementation NSPersonNameComponents {
    NSString *_namePrefix, *_givenName, *_middleName, *_familyName, *_nameSuffix, *_nickname;
    NSPersonNameComponents *_phoneticRepresentation;
}
@synthesize namePrefix = _namePrefix, givenName = _givenName, middleName = _middleName, familyName = _familyName,
            nameSuffix = _nameSuffix, nickname = _nickname, phoneticRepresentation = _phoneticRepresentation;
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithNamePrefix:(NSString *)namePrefix givenName:(NSString *)givenName middleName:(NSString *)middleName
                        familyName:(NSString *)familyName nameSuffix:(NSString *)nameSuffix nickname:(NSString *)nickname
{
    if ((self = [super init])) {
        _namePrefix = [namePrefix copy];
        _givenName = [givenName copy];
        _middleName = [middleName copy];
        _familyName = [familyName copy];
        _nameSuffix = [nameSuffix copy];
        _nickname = [nickname copy];
    }
    return self;
}
- (void)dealloc
{
    [_namePrefix release]; [_givenName release]; [_middleName release]; [_familyName release];
    [_nameSuffix release]; [_nickname release]; [_phoneticRepresentation release];
    [super dealloc];
}
- (id)copyWithZone:(struct _NSZone *)zone
{
    NSPersonNameComponents *c = [[NSPersonNameComponents alloc] initWithNamePrefix:_namePrefix givenName:_givenName
        middleName:_middleName familyName:_familyName nameSuffix:_nameSuffix nickname:_nickname];
    c.phoneticRepresentation = _phoneticRepresentation;
    return c;
}
static NSString *const PNCKeys[] = { @"NS.namePrefix", @"NS.givenName", @"NS.middleName", @"NS.familyName",
                                     @"NS.nameSuffix", @"NS.nickname" };
- (NSString **)_slots:(NSUInteger)i
{
    NSString **slots[] = { &_namePrefix, &_givenName, &_middleName, &_familyName, &_nameSuffix, &_nickname };
    return slots[i];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    for (NSUInteger i = 0; i < 6; i++) if (*[self _slots:i]) [coder encodeObject:*[self _slots:i] forKey:PNCKeys[i]];
    if (_phoneticRepresentation) [coder encodeObject:_phoneticRepresentation forKey:@"NS.phoneticRepresentation"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        for (NSUInteger i = 0; i < 6; i++)
            *[self _slots:i] = [[coder decodeObjectOfClass:[NSString class] forKey:PNCKeys[i]] copy];
        _phoneticRepresentation = [[coder decodeObjectOfClass:[NSPersonNameComponents class]
                                                      forKey:@"NS.phoneticRepresentation"] retain];
    }
    return self;
}
- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSPersonNameComponents class]]) return NO;
    NSPersonNameComponents *o = other;
    for (NSUInteger i = 0; i < 6; i++) {
        NSString *a = *[self _slots:i], *b = *[o _slots:i];
        if (a != b && ![a isEqual:b]) return NO;
    }
    return _phoneticRepresentation == o->_phoneticRepresentation || [_phoneticRepresentation isEqual:o->_phoneticRepresentation];
}
- (NSUInteger)hash { return [_givenName hash] ^ [_familyName hash]; }
@end

/* A file's ownership, mode and ACL (Apple's bridges to CFFileSecurity). */
@implementation NSFileSecurity
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }
@end

/* The number format of a localized number in an attributed string. Finch has
 * the automatic rule only. */
@implementation NSLocalizedNumberFormatRule
+ (instancetype)automatic { return [[[self alloc] init] autorelease]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }
- (BOOL)isEqual:(id)other { return [other isKindOfClass:[NSLocalizedNumberFormatRule class]]; }
- (NSUInteger)hash { return 0x4c4e46; }
@end
