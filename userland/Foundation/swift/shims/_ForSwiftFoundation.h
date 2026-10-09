// SPDX-License-Identifier: MIT OR Apache-2.0
// _ForSwiftFoundation: the Objective-C SPI swift-foundation uses when it is
// built into Foundation.framework (FOUNDATION_FRAMEWORK). Apple's Foundation
// provides these privately; Finch's Foundation (userland/Foundation,
// NSForSwiftFoundation.m) implements what is declared here. The declarations
// follow what the Swift sources call.
#pragma once
#import <Foundation/Foundation.h>
#import "FoundationShimSupport.h"
#import "CoreFoundation_Private.h"
#import "Foundation_Private.h"
#import <os/log.h>
#include <errno.h>
#include <fcntl.h>

NS_ASSUME_NONNULL_BEGIN

// Abstract superclasses of swift-foundation's Swift subclasses of the class
// clusters (_NSSwiftURL, _NSSwiftCalendar, ...). They add nothing but an
// initializer that doesn't go through the cluster's placeholder; the Swift
// subclass overrides the primitive methods.
@interface _NSURLBridge : NSURL
- (instancetype)init NS_DESIGNATED_INITIALIZER;
@end

@interface _NSCalendarBridge : NSCalendar
- (nullable instancetype)initWithCheckedCalendarIdentifier:(NSCalendarIdentifier)ident NS_DESIGNATED_INITIALIZER;
@property (nullable, copy) NSTimeZone *timeZone;
// The primitives the bridge's public methods call (nil arguments allowed there).
- (nullable NSDate *)_dateFromComponents:(NSDateComponents *)comps;
- (NSDateComponents *)_components:(NSCalendarUnit)unitFlags fromDate:(NSDate *)date;
- (NSDateComponents *)_componentsInTimeZone:(NSTimeZone *)timezone fromDate:(NSDate *)date;
- (void)_enumerateDatesStartingAfterDate:(NSDate *)start matchingComponents:(NSDateComponents *)comps
                                 options:(NSCalendarOptions)opts
                              usingBlock:(void (NS_NOESCAPE ^)(NSDate * _Nullable date, BOOL exactMatch, BOOL *stop))block;
@end

// The class an autoupdating current calendar archives as.
@interface _NSAutoCalendar : NSCalendar
@end

@interface _NSLocaleBridge : NSLocale
- (instancetype)initWithLocaleIdentifier:(NSString *)string NS_DESIGNATED_INITIALIZER;
@end

@interface _NSTimeZoneBridge : NSTimeZone
- (instancetype)init NS_DESIGNATED_INITIALIZER;
@end

// The class the autoupdating local time zone archives as.
@interface __NSLocalTimeZone : NSTimeZone
@end

@interface _NSURLComponentsBridge : NSURLComponents
- (instancetype)init NS_DESIGNATED_INITIALIZER;
@end

@interface _NSURLQueryItemBridge : NSURLQueryItem
- (instancetype)initWithName:(NSString *)name value:(nullable NSString *)value NS_DESIGNATED_INITIALIZER;
@end

// Which URL implementation Swift uses: swift-foundation's parser for URL
// (as Apple's), and CF's CFURL for NSURL (Finch's NSURL is CF's).
static inline BOOL _foundation_swift_url_feature_enabled(void) { return YES; }
static inline BOOL _foundation_swift_nsurl_feature_enabled(void) { return NO; }

@interface NSBundle (NSBundleForSwiftFoundation)
- (nullable id)_objectForUnlocalizedInfoDictionaryKey:(NSString *)key;   // the raw Info.plist value
@end
// An Info.plist boolean as Foundation reads them: YES/NO, true/false, 1/0.
static inline BOOL _generouslyInterpretedInfoDictionaryBoolean(id _Nullable value) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)value;
        return [s caseInsensitiveCompare:@"YES"] == NSOrderedSame || [s caseInsensitiveCompare:@"true"] == NSOrderedSame
            || [s integerValue] != 0;
    }
    return NO;
}

// NSDateComponents state with no public accessor.
FOUNDATION_EXPORT NSInteger __NSDateComponentsWeek(NS_NON_BRIDGED(NSDateComponents *) dc);
FOUNDATION_EXPORT void __NSDateComponentsSetWeek(NS_NON_BRIDGED(NSDateComponents *) dc, NSInteger week);
FOUNDATION_EXPORT BOOL __NSDateComponentsIsLeapMonthSet(NS_NON_BRIDGED(NSDateComponents *) dc);
FOUNDATION_EXPORT BOOL __NSDateComponentsIsRepeatedDaySet(NS_NON_BRIDGED(NSDateComponents *) dc);

// File reading and writing.
FOUNDATION_EXPORT NSString * const NSFileAttributeStringEncoding;   // the com.apple.TextEncoding xattr
FOUNDATION_EXPORT BOOL _NSFileCompressionTypeIsSafeForMapping(const char *path);

// Sandbox- and data-protection-aware file creation. Finch has no sandbox
// extensions or file protection classes yet: these are the plain versions.
static inline int _NSOpenFileDescriptor_Protected(const char *path, NSInteger flags,
                                                 NSDataWritingOptions options, mode_t mode) {
    return open(path, (int)flags, mode);
}
static inline char * _Nullable _amkrtemp(const char *path) {
    errno = ENOTSUP;   // callers fall back to mkstemp
    return NULL;
}
static inline NSDataWritingOptions _NSDataWritingOptionsForRelocatedAtomicWrite(NSDataWritingOptions options,
                                                                                 NSString *path) {
    return options;
}
FOUNDATION_EXPORT NSErrorUserInfoKey const NSUserStringVariantErrorKey;
FOUNDATION_EXPORT NSErrorUserInfoKey const NSSourceFilePathErrorKey;
FOUNDATION_EXPORT NSErrorUserInfoKey const NSDestinationFilePathErrorKey;

@interface NSFileManager (NSFileManagerForSwiftFoundation)
- (nullable NSURL *)_URLForTrashingItemAtURL:(NSURL *)url create:(BOOL)create error:(NSError **)error;
- (nullable NSURL *)_URLForReplacingItemAtURL:(NSURL *)url error:(NSError **)error;
- (nullable id<NSFileManagerDelegate>)_safeDelegate;   // the delegate, retained
// iCloud Drive's evicted ("faulted out") documents; Finch has no iCloud.
- (BOOL)_handleFaultedOutCloudDocFromSource:(NSURL *)source toDestination:(NSURL *)destination
                                    handled:(BOOL *)handled error:(NSError **)error;
@end

// A directory's entry names, as -[NSFileManager contentsOfDirectoryAtPath:error:].
FOUNDATION_EXPORT NSArray<NSString *> * _Nullable _NSDirectoryContentsFromCFURLEnumeratorError(
    NSURL *url, NSArray<NSURLResourceKey> * _Nullable keys, NSUInteger options, BOOL namesOnly,
    NSError * _Nullable * _Nullable error);

// A two-index NSIndexPath.
FOUNDATION_EXPORT NSIndexPath *_NSIndexPathCreateFromIndexes(NSInteger index1, NSInteger index2) NS_RETURNS_RETAINED;

// The current process's code signing identifier (Finch: its bundle identifier).
FOUNDATION_EXPORT NSString * _Nullable _NSCodeSigningIdentifierForCurrentProcess(void);

// Foundation's os_log handles (subsystem com.apple.Foundation).
FOUNDATION_EXPORT os_log_t _NSOSLog(void);
FOUNDATION_EXPORT os_log_t _NSRuntimeIssuesLog(void);

NS_ASSUME_NONNULL_END
