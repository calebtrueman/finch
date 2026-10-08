/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The messages CoreFoundation sends to Objective-C objects passed to CF
 * functions (CFObjCDispatch_Finch.h), declared with Foundation's signatures
 * so the compiler passes arguments and reads results as Foundation's
 * methods do. Public methods follow the SDK's Foundation headers; the
 * private ones Foundation implements for CF (_cf..., __getValue:..., the
 * NSCalendar and NSTimeZone absolute-time calls) take what CF passes.
 *
 * Only the selectors CF sends are here. Finch's Foundation implements them.
 */
#ifndef CF_OBJC_MESSAGES_FINCH_H
#define CF_OBJC_MESSAGES_FINCH_H

#include <stdarg.h>
#import <objc/NSObject.h>

typedef struct _NSRange { NSUInteger location, length; } NSRange;
CF_INLINE NSRange NSMakeRange(NSUInteger loc, NSUInteger len) { NSRange r = { loc, len }; return r; }
typedef NSUInteger NSCalendarUnit;
typedef NSUInteger NSStringCompareOptions;
typedef NSInteger NSTimeZoneNameStyle;
typedef unsigned short unichar;
struct NSFastEnumerationState_;

@class NSString, NSMutableString, NSArray, NSMutableArray, NSDictionary, NSMutableDictionary,
    NSSet, NSMutableSet, NSData, NSMutableData, NSDate, NSNumber, NSLocale, NSTimeZone,
    NSCalendar, NSCharacterSet, NSMutableCharacterSet, NSAttributedString, NSStream, NSPort,
    NSMutableAttributedString, NSURL, NSError, NSTimer, NSInputStream, NSOutputStream, NSMachPort;

@interface NSObject (FinchCFMessages)
- (CFTypeID)_cfTypeID;
- (id)copyWithZone:(struct _NSZone *)zone;
- (id)_cfMutableCopy;
- (id)copy;
- (id)mutableCopy;
- (NSUInteger)count;
- (NSUInteger)length;
- (void)removeAllObjects;
- (id)objectForKey:(id)key;
- (NSUInteger)countForObject:(id)object;
- (BOOL)containsObject:(id)object;
- (void)addObject:(id)object;
- (void)setObject:(id)object;
- (void)open;
- (void)close;
- (CFStreamStatus)streamStatus;
- (CFErrorRef)streamError;
- (CFStreamError)_cfStreamError;
- (id)propertyForKey:(NSString *)key;
- (BOOL)setProperty:(id)property forKey:(NSString *)key;
- (CFComparisonResult)compare:(id)other;
- (NSUInteger)countByEnumeratingWithState:(struct NSFastEnumerationState_ *)state
                                  objects:(id __unsafe_unretained *)buffer count:(NSUInteger)len;
@end

@interface NSArray : NSObject
- (id)objectAtIndex:(NSUInteger)idx;
- (void)getObjects:(id *)objects range:(NSRange)range;
@end

@interface NSMutableArray : NSArray
- (void)setObject:(id)object atIndex:(NSUInteger)idx;
- (void)insertObject:(id)object atIndex:(NSUInteger)idx;
- (void)exchangeObjectAtIndex:(NSUInteger)idx1 withObjectAtIndex:(NSUInteger)idx2;
- (void)removeObjectAtIndex:(NSUInteger)idx;
- (void)replaceObjectsInRange:(NSRange)range withObjects:(const id *)objects count:(NSUInteger)count;
@end

@interface NSDictionary : NSObject
- (BOOL)__getValue:(id *)value forKey:(id)key;
- (NSUInteger)countForKey:(id)key;
- (BOOL)containsKey:(id)key;
- (void)getObjects:(id *)objects andKeys:(id *)keys;
- (void)__apply:(void (*)(const void *, const void *, void *))applier context:(void *)context;
@end

@interface NSMutableDictionary : NSDictionary
- (void)__addObject:(id)object forKey:(id)key;
- (void)__setObject:(id)object forKey:(id)key;
- (void)replaceObject:(id)object forKey:(id)key;
- (void)removeObjectForKey:(id)key;
@end

@interface NSSet : NSObject
- (BOOL)__getValue:(id *)value forObj:(id)object;
- (id)member:(id)object;
- (void)getObjects:(id *)objects;
- (void)__applyValues:(void (*)(const void *, void *))applier context:(void *)context;
@end

@interface NSMutableSet : NSSet
- (void)removeObject:(id)object;
- (void)replaceObject:(id)object;
@end

@interface NSData : NSObject
- (const void *)bytes;
- (void)getBytes:(void *)buffer range:(NSRange)range;
@end

@interface NSMutableData : NSData
- (void *)mutableBytes;
- (void)setLength:(NSUInteger)length;
- (void)increaseLengthBy:(NSUInteger)extra;
- (void)appendBytes:(const void *)bytes length:(NSUInteger)length;
- (void)replaceBytesInRange:(NSRange)range withBytes:(const void *)bytes length:(NSUInteger)length;
@end

@interface NSDate : NSObject
- (CFTimeInterval)timeIntervalSinceReferenceDate;
- (CFTimeInterval)timeIntervalSinceDate:(NSDate *)other;
@end

@interface NSNumber : NSObject
- (CFNumberType)_cfNumberType;
- (BOOL)_getValue:(void *)value forType:(CFNumberType)type;
- (BOOL)boolValue;
- (CFComparisonResult)_reverseCompare:(NSNumber *)other;
@end

@interface NSString : NSObject
- (unichar)characterAtIndex:(NSUInteger)idx;
- (void)getCharacters:(unichar *)buffer range:(NSRange)range;
- (const UniChar *)_fastCharacterContents;
- (const char *)_fastCStringContents:(BOOL)nullTerminated;
- (BOOL)_getCString:(char *)buffer maxLength:(NSUInteger)max encoding:(CFStringEncoding)encoding;
- (CFStringEncoding)_fastestEncodingInCFStringEncoding;
- (CFStringEncoding)_smallestEncodingInCFStringEncoding;
- (BOOL)_encodingCantBeStoredInEightBitCFString;
- (id)_createSubstringWithRange:(NSRange)range;
- (void)getLineStart:(NSUInteger *)start end:(NSUInteger *)end contentsEnd:(NSUInteger *)contentsEnd forRange:(NSRange)range;
- (void)getParagraphStart:(NSUInteger *)start end:(NSUInteger *)end contentsEnd:(NSUInteger *)contentsEnd forRange:(NSRange)range;
@end

@interface NSMutableString : NSString
- (void)appendString:(NSString *)string;
- (void)appendCharacters:(const unichar *)chars length:(NSUInteger)length;
- (void)_cfAppendCString:(const unsigned char *)cString length:(NSInteger)length;
- (void)insertString:(NSString *)string atIndex:(NSUInteger)idx;
- (void)deleteCharactersInRange:(NSRange)range;
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string;
- (void)setString:(NSString *)string;
- (NSUInteger)replaceOccurrencesOfString:(NSString *)target withString:(NSString *)replacement
    options:(NSStringCompareOptions)options range:(NSRange)range;
- (void)_cfLowercase:(const void *)locale;
- (void)_cfUppercase:(const void *)locale;
- (void)_cfCapitalize:(const void *)locale;
- (void)_cfNormalize:(CFStringNormalizationForm)form;
- (void)_cfPad:(CFStringRef)pad length:(uint32_t)length padIndex:(uint32_t)index;
- (void)_cfTrim:(CFStringRef)trim;
- (void)_cfTrimWS;
@end

@interface NSAttributedString : NSObject
- (NSString *)string;
- (NSDictionary *)attributesAtIndex:(NSUInteger)loc effectiveRange:(NSRange *)range;
- (NSDictionary *)attributesAtIndex:(NSUInteger)loc longestEffectiveRange:(NSRange *)range inRange:(NSRange)limit;
- (id)attribute:(NSString *)name atIndex:(NSUInteger)loc effectiveRange:(NSRange *)range;
- (id)attribute:(NSString *)name atIndex:(NSUInteger)loc longestEffectiveRange:(NSRange *)range inRange:(NSRange)limit;
- (id)_createAttributedSubstringWithRange:(NSRange)range;
@end

@interface NSMutableAttributedString : NSAttributedString
- (NSMutableString *)mutableString;
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string;
- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)string;
- (void)setAttributes:(NSDictionary *)attrs range:(NSRange)range;
- (void)addAttribute:(NSString *)name value:(id)value range:(NSRange)range;
- (void)addAttributes:(NSDictionary *)attrs range:(NSRange)range;
- (void)removeAttribute:(NSString *)name range:(NSRange)range;
- (void)beginEditing;
- (void)endEditing;
@end

@interface NSCharacterSet : NSObject
- (BOOL)longCharacterIsMember:(UTF32Char)c;
- (BOOL)hasMemberInPlane:(uint8_t)plane;
- (NSCharacterSet *)invertedSet;
- (CFCharacterSetRef)_expandedCFCharacterSet;
- (CFDataRef)_retainedBitmapRepresentation;
@end

@interface NSMutableCharacterSet : NSCharacterSet
- (void)addCharactersInRange:(NSRange)range;
- (void)removeCharactersInRange:(NSRange)range;
- (void)addCharactersInString:(NSString *)string;
- (void)removeCharactersInString:(NSString *)string;
- (void)formUnionWithCharacterSet:(NSCharacterSet *)set;
- (void)formIntersectionWithCharacterSet:(NSCharacterSet *)set;
- (void)invert;
@end

@interface NSLocale : NSObject
- (NSString *)localeIdentifier;
- (CFDictionaryRef)_prefs;
- (NSString *)_copyDisplayNameForKey:(id)key value:(id)value;
- (BOOL)_doesNotRequireSpecialCaseHandling;
- (void)_setDoesNotRequireSpecialCaseHandling;
@end

@interface NSTimeZone : NSObject
- (NSString *)name;
- (NSData *)data;
- (NSString *)localizedName:(NSTimeZoneNameStyle)style locale:(NSLocale *)locale;
- (CFTimeInterval)_daylightSavingTimeOffsetForAbsoluteTime:(CFAbsoluteTime)at;
- (CFAbsoluteTime)_nextDaylightSavingTimeTransitionAfterAbsoluteTime:(CFAbsoluteTime)at;
@end

@interface NSCalendar : NSObject
- (NSString *)calendarIdentifier;
- (CFLocaleRef)_copyLocale;
- (CFTimeZoneRef)_copyTimeZone;
- (CFDateRef)_copyGregorianStartDate;
- (void)_setGregorianStartDate:(NSDate *)date;
- (void)setLocale:(NSLocale *)locale;
- (void)setTimeZone:(NSTimeZone *)tz;
- (NSUInteger)firstWeekday;
- (void)setFirstWeekday:(NSUInteger)day;
- (NSUInteger)minimumDaysInFirstWeek;
- (void)setMinimumDaysInFirstWeek:(NSUInteger)days;
- (CFRange)_minimumRangeOfUnit:(NSCalendarUnit)unit;
- (CFRange)_maximumRangeOfUnit:(NSCalendarUnit)unit;
- (CFRange)_rangeOfUnit:(NSCalendarUnit)smaller inUnit:(NSCalendarUnit)bigger forAT:(CFAbsoluteTime)at;
- (CFIndex)_ordinalityOfUnit:(NSCalendarUnit)smaller inUnit:(NSCalendarUnit)bigger forAT:(CFAbsoluteTime)at;
- (BOOL)_rangeOfUnit:(NSCalendarUnit)unit startTime:(CFAbsoluteTime *)start interval:(CFTimeInterval *)interval
    forAT:(CFAbsoluteTime)at;
- (BOOL)_composeAbsoluteTime:(CFAbsoluteTime *)at :(const unsigned char *)desc :(va_list)args;
- (BOOL)_decomposeAbsoluteTime:(CFAbsoluteTime)at :(const unsigned char *)desc :(va_list)args;
- (BOOL)_addComponents:(CFAbsoluteTime *)at :(CFOptionFlags)options :(const unsigned char *)desc :(va_list)args;
- (BOOL)_diffComponents:(CFAbsoluteTime)start :(CFAbsoluteTime)result :(CFOptionFlags)options
    :(const unsigned char *)desc :(va_list)args;
@end

@interface NSURL : NSObject
- (CFURLRef)_cfurl;
- (NSURL *)baseURL;
- (NSURL *)absoluteURL;
- (NSString *)relativeString;
- (NSString *)scheme;
- (NSString *)host;
- (NSNumber *)port;
- (NSString *)user;
- (NSString *)password;
- (NSString *)query;
- (NSString *)fragment;
- (BOOL)isFileReferenceURL;
@end

@interface NSError : NSObject
- (NSString *)domain;
- (NSInteger)code;
- (NSDictionary *)userInfo;
- (NSString *)localizedDescription;
- (NSString *)localizedFailureReason;
- (NSString *)localizedRecoverySuggestion;
@end

@interface NSTimer : NSObject
- (CFAbsoluteTime)_cffireTime;
- (CFTimeInterval)timeInterval;
- (CFTimeInterval)tolerance;
- (void)setTolerance:(CFTimeInterval)tolerance;
- (BOOL)isValid;
- (void)invalidate;
@end

@interface NSPort : NSObject
- (BOOL)isValid;
- (void)invalidate;
@end

@interface NSMachPort : NSPort
- (mach_port_t)machPort;
@end

@interface NSStream : NSObject
@end

@interface NSInputStream : NSStream
- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)length;
- (BOOL)getBuffer:(uint8_t **)buffer length:(NSUInteger *)length;
- (BOOL)hasBytesAvailable;
@end

@interface NSOutputStream : NSStream
- (NSInteger)write:(const uint8_t *)buffer maxLength:(NSUInteger)length;
- (BOOL)hasSpaceAvailable;
@end

#endif
