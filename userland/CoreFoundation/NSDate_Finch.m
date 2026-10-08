/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSDate, which Apple's CoreFoundation hosts (docs/design/FOUNDATION.md),
 * with __NSDate, the class of every CFDate (Apple's name for its concrete
 * date). The primitive is -timeIntervalSinceReferenceDate; +alloc on NSDate
 * returns __NSPlaceholderDate, whose -init... make CFDates. Calendars and
 * formatters are elsewhere; -description is Apple's fixed format,
 * "2001-01-01 00:00:00 +0000".
 */
#include "CFObjCClasses_Finch.h"
#include <math.h>
#include <time.h>

#define NSTimeIntervalSince1970 978307200.0
typedef double NSTimeInterval;

@interface NSDate () <NSCopying>
+ (instancetype)date;
+ (instancetype)dateWithTimeIntervalSinceNow:(NSTimeInterval)secs;
+ (instancetype)dateWithTimeIntervalSinceReferenceDate:(NSTimeInterval)ti;
+ (instancetype)dateWithTimeIntervalSince1970:(NSTimeInterval)secs;
+ (instancetype)dateWithTimeInterval:(NSTimeInterval)secs sinceDate:(NSDate *)date;
+ (instancetype)distantFuture;
+ (instancetype)distantPast;
+ (NSTimeInterval)timeIntervalSinceReferenceDate;
- (instancetype)init;
- (instancetype)initWithTimeIntervalSinceReferenceDate:(NSTimeInterval)ti;
- (instancetype)initWithTimeIntervalSinceNow:(NSTimeInterval)secs;
- (instancetype)initWithTimeIntervalSince1970:(NSTimeInterval)secs;
- (instancetype)initWithTimeInterval:(NSTimeInterval)secs sinceDate:(NSDate *)date;
- (NSTimeInterval)timeIntervalSinceNow;
- (NSTimeInterval)timeIntervalSince1970;
- (BOOL)isEqualToDate:(NSDate *)other;
- (NSDate *)earlierDate:(NSDate *)other;
- (NSDate *)laterDate:(NSDate *)other;
- (instancetype)dateByAddingTimeInterval:(NSTimeInterval)ti;
@end

@interface __NSPlaceholderDate : NSDate
@end
@interface __NSDate : NSDate
@end

static __NSPlaceholderDate *placeholder;

CF_PRIVATE Class
__CFFinchInitializeDateClasses(void)
{
    placeholder = class_createInstance([__NSPlaceholderDate class], 0);
    return [__NSDate class];
}

@implementation NSDate

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSDate class]) return (id)placeholder;
    return [super allocWithZone:zone];
}

+ (NSTimeInterval)timeIntervalSinceReferenceDate { return CFAbsoluteTimeGetCurrent(); }
+ (instancetype)date { return [[[self alloc] init] autorelease]; }
+ (instancetype)dateWithTimeIntervalSinceNow:(NSTimeInterval)secs
{
    return [[[self alloc] initWithTimeIntervalSinceNow:secs] autorelease];
}
+ (instancetype)dateWithTimeIntervalSinceReferenceDate:(NSTimeInterval)ti
{
    return [[[self alloc] initWithTimeIntervalSinceReferenceDate:ti] autorelease];
}
+ (instancetype)dateWithTimeIntervalSince1970:(NSTimeInterval)secs
{
    return [[[self alloc] initWithTimeIntervalSince1970:secs] autorelease];
}
+ (instancetype)dateWithTimeInterval:(NSTimeInterval)secs sinceDate:(NSDate *)date
{
    return [[[self alloc] initWithTimeInterval:secs sinceDate:date] autorelease];
}
/* Apple's: 4001-01-01 and 0001-01-01 (proleptic Gregorian), in seconds. */
+ (instancetype)distantFuture { return [self dateWithTimeIntervalSinceReferenceDate:63113904000.0]; }
+ (instancetype)distantPast { return [self dateWithTimeIntervalSinceReferenceDate:-63114076800.0]; }

/* Designated initializer for subclasses; the abstract class stores nothing. */
- (instancetype)initWithTimeIntervalSinceReferenceDate:(NSTimeInterval)ti { return [super init]; }
- (instancetype)init { return [self initWithTimeIntervalSinceReferenceDate:CFAbsoluteTimeGetCurrent()]; }
- (instancetype)initWithTimeIntervalSinceNow:(NSTimeInterval)secs
{
    return [self initWithTimeIntervalSinceReferenceDate:CFAbsoluteTimeGetCurrent() + secs];
}
- (instancetype)initWithTimeIntervalSince1970:(NSTimeInterval)secs
{
    return [self initWithTimeIntervalSinceReferenceDate:secs - NSTimeIntervalSince1970];
}
- (instancetype)initWithTimeInterval:(NSTimeInterval)secs sinceDate:(NSDate *)date
{
    return [self initWithTimeIntervalSinceReferenceDate:[date timeIntervalSinceReferenceDate] + secs];
}

- (NSTimeInterval)timeIntervalSinceReferenceDate
{
    __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s timeIntervalSinceReferenceDate]!",
        FINCH_METHOD_ARGS, object_getClassName(self));
}

- (NSTimeInterval)timeIntervalSinceDate:(NSDate *)other
{
    return [self timeIntervalSinceReferenceDate] - [other timeIntervalSinceReferenceDate];
}
- (NSTimeInterval)timeIntervalSinceNow { return [self timeIntervalSinceReferenceDate] - CFAbsoluteTimeGetCurrent(); }
- (NSTimeInterval)timeIntervalSince1970 { return [self timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970; }

- (CFComparisonResult)compare:(NSDate *)other
{
    NSTimeInterval a = [self timeIntervalSinceReferenceDate], b = [other timeIntervalSinceReferenceDate];
    return a < b ? kCFCompareLessThan : a > b ? kCFCompareGreaterThan : kCFCompareEqualTo;
}

- (BOOL)isEqualToDate:(NSDate *)other
{
    return other && [self timeIntervalSinceReferenceDate] == [other timeIntervalSinceReferenceDate];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    return other && [other isKindOfClass:[NSDate class]] && [self isEqualToDate:other];
}

- (NSUInteger)hash { return (NSUInteger)(long)[self timeIntervalSinceReferenceDate]; }

- (NSDate *)earlierDate:(NSDate *)other { return [self compare:other] == kCFCompareGreaterThan ? other : self; }
- (NSDate *)laterDate:(NSDate *)other { return [self compare:other] == kCFCompareLessThan ? other : self; }

- (instancetype)dateByAddingTimeInterval:(NSTimeInterval)ti
{
    return [[[[self class] alloc] initWithTimeIntervalSinceReferenceDate:[self timeIntervalSinceReferenceDate] + ti] autorelease];
}

- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }

- (id)description
{
    double t = floor([self timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970);
    time_t secs = (time_t)t;
    struct tm tm;
    char buf[64];
    gmtime_r(&secs, &tm);
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S +0000", &tm);
    return [(id)CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8) autorelease];
}

- (CFTypeID)_cfTypeID { return CFDateGetTypeID(); }
- (BOOL)isNSDate__ { return YES; }

@end

@implementation __NSPlaceholderDate

FINCH_IMMORTAL_MEMORY

- (instancetype)initWithTimeIntervalSinceReferenceDate:(NSTimeInterval)ti
{
    return (id)CFDateCreate(NULL, ti);
}

@end

@implementation __NSDate

FINCH_CF_OBJECT_MEMORY

/* Instances are CFDates: [[date class] alloc] goes through the placeholder. */
+ (instancetype)allocWithZone:(struct _NSZone *)zone { return (id)placeholder; }

- (NSTimeInterval)timeIntervalSinceReferenceDate { return CFDateGetAbsoluteTime((CFDateRef)self); }
- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }

@end
