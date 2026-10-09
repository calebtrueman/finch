// SPDX-License-Identifier: MIT OR Apache-2.0
// Foundation_Private: the Objective-C SPI of Foundation's private headers
// that swift-foundation (FOUNDATION_FRAMEWORK) calls. Finch's Foundation
// implements each (userland/Foundation, NSForSwiftFoundation.m).
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, NSFileManagerCopyOptions) {
    NSFileManagerCopyOptionsAllowRunningResultInPlace = 1UL << 0,
};
typedef NS_OPTIONS(NSUInteger, NSFileManagerMoveOptions) {
    NSFileManagerMoveOptionsAllowRunningResultInPlace = 1UL << 0,
};

// Search path directories and domains beyond the public ones. Finch's
// values sit above the public ranges; sysdir answers only public ones.
typedef NS_ENUM(NSUInteger, NSSearchPathDirectory_Private) {
    NSSearchPathDirectory_PrivateHomeDirectory = 1001,
};
typedef NS_OPTIONS(NSUInteger, NSSearchPathDomainMask_Private) {
    NSSearchPathDomainMask_PrivateSharedUserDomainMask = 1UL << 16,
    NSSearchPathDomainMask_PrivatePartitionedSystemDomainMask = 1UL << 17,
    NSSearchPathDomainMask_PrivateAppCryptexDomainMask = 1UL << 18,
    NSSearchPathDomainMask_PrivateOsCryptexDomainMask = 1UL << 19,
};

@interface NSLocale (NSLocalePrivateForSwift)
+ (NSArray<NSString *> *)systemLanguages;   // languages the system is localized in
- (nullable NSString *)localizedStringForCurrencySymbol:(NSString *)currencySymbol;
- (nullable id)_prefForKey:(NSString *)key;
- (null_unspecified NSString *)_numberingSystem;
- (NSString *)_identifierCapturingPreferences;
@end
// The class an autoupdating current locale archives as.
@interface NSAutoLocale : NSLocale
@end
FOUNDATION_EXPORT NSLocaleKey const NSLocaleCalendarIdentifier;
FOUNDATION_EXPORT NSLocaleKey const NSLocaleTemperatureUnit;
FOUNDATION_EXPORT NSString * const NSLocaleMeasurementSystemMetric;
FOUNDATION_EXPORT NSString * const NSLocaleMeasurementSystemUS;
FOUNDATION_EXPORT NSString * const NSLocaleMeasurementSystemUK;
FOUNDATION_EXPORT NSString * const NSLocaleTemperatureUnitCelsius;
FOUNDATION_EXPORT NSString * const NSLocaleTemperatureUnitFahrenheit;

@interface NSString (NSStringPrivateForSwift)
- (nullable const unichar *)_fastCharacterContents;   // the UTF-16 buffer, when there is one
- (nullable const char *)_fastCStringContents:(BOOL)nullTerminationRequired;   // the 8-bit buffer, when there is one
@end

@interface NSURL (NSURLPrivateForSwift)
- (CFURLRef)_cfurl;   // the URL as a CFURL (not retained)
- (NSURL *)_trueSelf;   // the URL itself (not a file reference proxy)
@property (nullable, readonly, copy) NSString *_parameterString;
@end
// NSURL's deprecated ;parameter component; Finch keeps it in the path.
static inline BOOL __NSURLSupportDeprecatedParameterComponent(void) { return NO; }

@interface NSFileManager (NSFileManagerPrivateForSwift)
- (BOOL)getFileSystemRepresentation:(char *)buffer maxLength:(NSInteger)maxLength withPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
