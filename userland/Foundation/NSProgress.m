/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSProgress, NSByteCountFormatter, NSISO8601DateFormatter,
 * NSDateComponentsFormatter, ordered-collection differences and
 * NSDistributedNotificationCenter (docs/design/FOUNDATION.md), against the
 * SDK's headers.
 *
 * Progress: a tree. A child stands for `pending` units of its parent; the
 * parent's fraction counts each child's fraction of those units, and a
 * finished child's units are added to the parent's completed count, as
 * Apple's are. fractionCompleted and the counts are KVO-observable.
 *
 * Formatters: English words (Apple's localize through ICU's measure
 * formats, which have no C API; other languages come later). Byte counts
 * are Apple's adaptive style: bytes, then KB with no decimals, MB with one,
 * GB and up with two, trailing zeros dropped.
 *
 * The distributed notification center is the local one Apple gives a
 * process without a window server connection (_NSLocalNotificationCenter);
 * a system-wide one needs a distnoted.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <math.h>

#include "Foundation_Finch.h"

/* MARK: - NSProgress */

NSProgressKind const NSProgressKindFile = @"NSProgressKindFile";
NSProgressUserInfoKey const NSProgressEstimatedTimeRemainingKey = @"NSProgressEstimatedTimeRemainingKey";
NSProgressUserInfoKey const NSProgressThroughputKey = @"NSProgressThroughputKey";
NSProgressUserInfoKey const NSProgressFileOperationKindKey = @"NSProgressFileOperationKindKey";
NSProgressFileOperationKind const NSProgressFileOperationKindDownloading = @"NSProgressFileOperationKindDownloading";
NSProgressFileOperationKind const NSProgressFileOperationKindDecompressingAfterDownloading = @"NSProgressFileOperationKindDecompressingAfterDownloading";
NSProgressFileOperationKind const NSProgressFileOperationKindReceiving = @"NSProgressFileOperationKindReceiving";
NSProgressFileOperationKind const NSProgressFileOperationKindCopying = @"NSProgressFileOperationKindCopying";
NSProgressFileOperationKind const NSProgressFileOperationKindUploading = @"NSProgressFileOperationKindUploading";
NSProgressFileOperationKind const NSProgressFileOperationKindDuplicating = @"NSProgressFileOperationKindDuplicating";
NSProgressUserInfoKey const NSProgressFileURLKey = @"NSProgressFileURLKey";
NSProgressUserInfoKey const NSProgressFileTotalCountKey = @"NSProgressFileTotalCountKey";
NSProgressUserInfoKey const NSProgressFileCompletedCountKey = @"NSProgressFileCompletedCountKey";
NSProgressUserInfoKey const NSProgressFileAnimationImageKey = @"NSProgressFileAnimationImageKey";
NSProgressUserInfoKey const NSProgressFileAnimationImageOriginalRectKey = @"NSProgressFileAnimationImageOriginalRectKey";
NSProgressUserInfoKey const NSProgressFileIconKey = @"NSProgressFileIconKey";

@interface NSProgress () {
    NSProgress *_parent;            /* not retained */
    int64_t _pendingInParent;       /* the parent's units this progress stands for */
    NSMutableArray *_children;
    int64_t _total, _completed;
    BOOL _cancelled, _paused, _cancellable, _pausable;
    NSString *_description, *_additional;
    NSMutableDictionary *_info;
    NSString *_kindValue;
    void (^_cancellation)(void), (^_pausing)(void), (^_resuming)(void);
    int64_t _currentPending;        /* while current: units for the next implicit child */
}
- (void)childChanged;
@end

static NSString *const CurrentProgressKey = @"NSProgressCurrent";

@implementation NSProgress

+ (NSProgress *)currentProgress { return [[[NSThread currentThread] threadDictionary] objectForKey:CurrentProgressKey]; }

+ (NSProgress *)progressWithTotalUnitCount:(int64_t)unitCount
{
    NSProgress *p = [[[NSProgress alloc] initWithParent:[NSProgress currentProgress] userInfo:nil] autorelease];
    p.totalUnitCount = unitCount;
    return p;
}

+ (NSProgress *)discreteProgressWithTotalUnitCount:(int64_t)unitCount
{
    NSProgress *p = [[[NSProgress alloc] initWithParent:nil userInfo:nil] autorelease];
    p.totalUnitCount = unitCount;
    return p;
}

+ (NSProgress *)progressWithTotalUnitCount:(int64_t)unitCount parent:(NSProgress *)parent pendingUnitCount:(int64_t)portion
{
    NSProgress *p = [self discreteProgressWithTotalUnitCount:unitCount];
    [parent addChild:p withPendingUnitCount:portion];
    return p;
}

- (instancetype)init { return [self initWithParent:nil userInfo:nil]; }

- (instancetype)initWithParent:(NSProgress *)parent userInfo:(NSDictionary *)userInfo
{
    if ((self = [super init])) {
        _children = [NSMutableArray new];
        _info = userInfo ? [userInfo mutableCopy] : [NSMutableDictionary new];
        _cancellable = YES;
        /* The current progress adopts the first progress made while it is current. */
        if (parent && parent == [NSProgress currentProgress] && parent->_currentPending) {
            [parent addChild:self withPendingUnitCount:parent->_currentPending];
            parent->_currentPending = 0;
        } else if (parent) {
            [parent addChild:self withPendingUnitCount:0];
        }
    }
    return self;
}

- (void)dealloc
{
    [_children release];
    [_description release];
    [_additional release];
    [_info release];
    [_kindValue release];
    [_cancellation release];
    [_pausing release];
    [_resuming release];
    [super dealloc];
}

- (void)addChild:(NSProgress *)child withPendingUnitCount:(int64_t)inUnitCount
{
    [self willChangeValueForKey:@"fractionCompleted"];
    child->_parent = self;
    child->_pendingInParent = inUnitCount;
    [_children addObject:child];
    if (_cancelled) [child cancel];
    [self didChangeValueForKey:@"fractionCompleted"];
}

- (void)becomeCurrentWithPendingUnitCount:(int64_t)unitCount
{
    _currentPending = unitCount;
    [[[NSThread currentThread] threadDictionary] setObject:self forKey:CurrentProgressKey];
}

- (void)resignCurrent
{
    /* Units no implicit child claimed count as done. */
    if (_currentPending) self.completedUnitCount = _completed + _currentPending;
    _currentPending = 0;
    if ([NSProgress currentProgress] == self) [[[NSThread currentThread] threadDictionary] removeObjectForKey:CurrentProgressKey];
}

- (void)performAsCurrentWithPendingUnitCount:(int64_t)unitCount usingBlock:(void (NS_NOESCAPE ^)(void))work
{
    [self becomeCurrentWithPendingUnitCount:unitCount];
    @try {
        work();
    } @finally {
        [self resignCurrent];
    }
}

- (int64_t)totalUnitCount { return _total; }
- (int64_t)completedUnitCount { return _completed; }

- (void)setTotalUnitCount:(int64_t)total
{
    [self willChangeValueForKey:@"fractionCompleted"];
    [self willChangeValueForKey:@"totalUnitCount"];
    _total = total;
    [self didChangeValueForKey:@"totalUnitCount"];
    [self didChangeValueForKey:@"fractionCompleted"];
    [self finishIfDone];
    [_parent childChanged];
}

- (void)setCompletedUnitCount:(int64_t)completed
{
    [self willChangeValueForKey:@"fractionCompleted"];
    [self willChangeValueForKey:@"completedUnitCount"];
    _completed = completed;
    [self didChangeValueForKey:@"completedUnitCount"];
    [self didChangeValueForKey:@"fractionCompleted"];
    [self finishIfDone];
    [_parent childChanged];
}

/* A finished child's units go to the parent's count. */
- (void)finishIfDone
{
    NSProgress *parent = _parent;
    if (!parent || ![self isFinished]) return;
    [[self retain] autorelease];
    int64_t units = _pendingInParent;
    _parent = nil;
    [parent->_children removeObjectIdenticalTo:self];
    parent.completedUnitCount = parent->_completed + units;
}

- (void)childChanged
{
    [self willChangeValueForKey:@"fractionCompleted"];
    [self didChangeValueForKey:@"fractionCompleted"];
    [_parent childChanged];
}

- (BOOL)isIndeterminate { return _total < 0 || (_total == 0 && _completed == 0); }
- (BOOL)isFinished { return _total > 0 ? _completed >= _total : (_total == 0 && _completed > 0); }

- (double)fractionCompleted
{
    if (_total <= 0) return 0;
    double done = (double)_completed;
    for (NSProgress *c in _children) done += [c fractionCompleted] * (double)c->_pendingInParent;
    return MIN(1.0, done / (double)_total);
}

- (NSString *)localizedDescription
{
    if (_description) return _description;
    NSNumberFormatter *f = [[[NSNumberFormatter alloc] init] autorelease];
    f.numberStyle = NSNumberFormatterPercentStyle;
    return [NSString stringWithFormat:@"%@ completed", [f stringFromNumber:@([self fractionCompleted])]];
}
- (void)setLocalizedDescription:(NSString *)s { [_description release]; _description = [s copy]; }

- (NSString *)localizedAdditionalDescription
{
    if (_additional) return _additional;
    if ([self isIndeterminate]) return @"";
    NSNumberFormatter *f = [[[NSNumberFormatter alloc] init] autorelease];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    return [NSString stringWithFormat:@"%@ of %@", [f stringFromNumber:@(_completed)], [f stringFromNumber:@(_total)]];
}
- (void)setLocalizedAdditionalDescription:(NSString *)s { [_additional release]; _additional = [s copy]; }

- (BOOL)isCancellable { return _cancellable; }
- (void)setCancellable:(BOOL)flag { _cancellable = flag; }
- (BOOL)isPausable { return _pausable; }
- (void)setPausable:(BOOL)flag { _pausable = flag; }
- (BOOL)isCancelled { return _cancelled || [_parent isCancelled]; }
- (BOOL)isPaused { return _paused || [_parent isPaused]; }
- (BOOL)isOld { return NO; }
- (NSProgress *)progress { return self; }

- (void (^)(void))cancellationHandler { return _cancellation; }
- (void)setCancellationHandler:(void (^)(void))h { [_cancellation release]; _cancellation = [h copy]; }
- (void (^)(void))pausingHandler { return _pausing; }
- (void)setPausingHandler:(void (^)(void))h { [_pausing release]; _pausing = [h copy]; }
- (void (^)(void))resumingHandler { return _resuming; }
- (void)setResumingHandler:(void (^)(void))h { [_resuming release]; _resuming = [h copy]; }

- (void)cancel
{
    if (_cancelled) return;
    [self willChangeValueForKey:@"cancelled"];
    _cancelled = YES;
    [self didChangeValueForKey:@"cancelled"];
    if (_cancellation) _cancellation();
    for (NSProgress *c in [[_children copy] autorelease]) [c cancel];
}

- (void)pause
{
    if (_paused) return;
    [self willChangeValueForKey:@"paused"];
    _paused = YES;
    [self didChangeValueForKey:@"paused"];
    if (_pausing) _pausing();
    for (NSProgress *c in [[_children copy] autorelease]) [c pause];
}

- (void)resume
{
    if (!_paused) return;
    [self willChangeValueForKey:@"paused"];
    _paused = NO;
    [self didChangeValueForKey:@"paused"];
    if (_resuming) _resuming();
    for (NSProgress *c in [[_children copy] autorelease]) [c resume];
}

- (NSDictionary *)userInfo { return [[_info copy] autorelease]; }
- (void)setUserInfoObject:(id)objectOrNil forKey:(NSProgressUserInfoKey)key
{
    [self willChangeValueForKey:@"userInfo"];
    if (objectOrNil) [_info setObject:objectOrNil forKey:key];
    else [_info removeObjectForKey:key];
    [self didChangeValueForKey:@"userInfo"];
}

- (NSProgressKind)kind { return _kindValue; }
- (void)setKind:(NSProgressKind)kind { [_kindValue release]; _kindValue = [kind copy]; }

#define INFO_PROPERTY(type, getter, setter, key) \
    - (type)getter { return [_info objectForKey:key]; } \
    - (void)setter:(type)value { [self setUserInfoObject:value forKey:key]; }
INFO_PROPERTY(NSNumber *, estimatedTimeRemaining, setEstimatedTimeRemaining, NSProgressEstimatedTimeRemainingKey)
INFO_PROPERTY(NSNumber *, throughput, setThroughput, NSProgressThroughputKey)
INFO_PROPERTY(NSProgressFileOperationKind, fileOperationKind, setFileOperationKind, NSProgressFileOperationKindKey)
INFO_PROPERTY(NSURL *, fileURL, setFileURL, NSProgressFileURLKey)
INFO_PROPERTY(NSNumber *, fileTotalCount, setFileTotalCount, NSProgressFileTotalCountKey)
INFO_PROPERTY(NSNumber *, fileCompletedCount, setFileCompletedCount, NSProgressFileCompletedCountKey)
#undef INFO_PROPERTY

- (void)publish { }
- (void)unpublish { }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s: %p> : Parent: %p (portion: %lld) / Fraction completed: %.4f / Completed: %lld of %lld",
        object_getClassName(self), self, _parent, _pendingInParent, [self fractionCompleted], _completed, _total];
}

@end

/* MARK: - NSByteCountFormatter */

@implementation NSByteCountFormatter

@synthesize allowedUnits = _fUnits, countStyle = _fStyle, allowsNonnumericFormatting = _fNonnumeric, includesUnit = _fUnit,
    includesCount = _fCount, includesActualByteCount = _fActual, adaptive = _fAdaptive, zeroPadsFractionDigits = _fZeroPads,
    formattingContext = _fContext;

- (instancetype)init
{
    if ((self = [super init])) {
        _fNonnumeric = YES;
        _fUnit = YES;
        _fCount = YES;
        _fAdaptive = YES;
        _fStyle = NSByteCountFormatterCountStyleFile;
    }
    return self;
}

+ (NSString *)stringFromByteCount:(long long)byteCount countStyle:(NSByteCountFormatterCountStyle)countStyle
{
    NSByteCountFormatter *f = [[[NSByteCountFormatter alloc] init] autorelease];
    f.countStyle = countStyle;
    return [f stringFromByteCount:byteCount];
}

static NSString *
trimmed_number(double v, int decimals)
{
    NSNumberFormatter *f = [[[NSNumberFormatter alloc] init] autorelease];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    f.locale = [NSLocale currentLocale];
    f.minimumFractionDigits = 0;
    f.maximumFractionDigits = (NSUInteger)decimals;
    f.roundingMode = NSNumberFormatterRoundHalfEven;
    return [f stringFromNumber:@(v)];
}

- (NSString *)stringFromByteCount:(long long)byteCount
{
    BOOL binary = _fStyle == NSByteCountFormatterCountStyleBinary || _fStyle == NSByteCountFormatterCountStyleMemory;
    double unit = binary ? 1024.0 : 1000.0;
    static NSString *names[] = { @"bytes", @"KB", @"MB", @"GB", @"TB", @"PB", @"EB", @"ZB", @"YB" };
    NSByteCountFormatterUnits allowed = _fUnits ? _fUnits : NSByteCountFormatterUseAll;
    if (byteCount == 0 && _fNonnumeric && allowed == NSByteCountFormatterUseAll) return _fUnit ? @"Zero KB" : @"0";
    double v = fabs((double)byteCount);
    int level = 0;
    /* The largest allowed unit the count reaches (or the smallest allowed). */
    int chosen = -1;
    for (int i = 0; i <= 8; i++) {
        if (!(allowed & (1u << i)) && allowed != NSByteCountFormatterUseAll) continue;
        if (chosen < 0 || v >= pow(unit, i)) chosen = i;
    }
    level = chosen < 0 ? 0 : chosen;
    double scaled = v / pow(unit, level);
    if (byteCount < 0) scaled = -scaled;
    int decimals = level <= 1 ? 0 : level == 2 ? 1 : 2;
    NSString *num = level == 0 ? trimmed_number(scaled, 0) : trimmed_number(scaled, decimals);
    if (!_fUnit) return num;
    if (!_fCount) return level == 0 ? (byteCount == 1 ? @"byte" : @"bytes") : names[level];
    if (level == 0) return [NSString stringWithFormat:@"%@ %@", num, llabs(byteCount) == 1 ? @"byte" : @"bytes"];
    return [NSString stringWithFormat:@"%@ %@", num, names[level]];
}

- (NSString *)stringForObjectValue:(id)obj
{
    return [obj isKindOfClass:[NSNumber class]] ? [self stringFromByteCount:[obj longLongValue]] : nil;
}

@end

/* MARK: - NSISO8601DateFormatter */

@implementation NSISO8601DateFormatter

- (instancetype)init
{
    if ((self = [super init])) {
        _timeZone = [[NSTimeZone timeZoneForSecondsFromGMT:0] retain];
        _formatOptions = NSISO8601DateFormatWithInternetDateTime;
    }
    return self;
}

- (void)dealloc
{
    [_timeZone release];
    [super dealloc];
}

+ (BOOL)supportsSecureCoding { return YES; }
- (NSTimeZone *)timeZone { return _timeZone; }
- (void)setTimeZone:(NSTimeZone *)tz { [_timeZone release]; _timeZone = [(tz ? tz : [NSTimeZone timeZoneForSecondsFromGMT:0]) copy]; }
- (NSISO8601DateFormatOptions)formatOptions { return _formatOptions; }
- (void)setFormatOptions:(NSISO8601DateFormatOptions)options { _formatOptions = options; }

/* The ICU pattern for a set of options. */
static NSString *
iso_pattern(NSISO8601DateFormatOptions o, NSTimeZone *tz)
{
    NSMutableString *p = [NSMutableString string];
    BOOL dash = (o & NSISO8601DateFormatWithDashSeparatorInDate) != 0, colon = (o & NSISO8601DateFormatWithColonSeparatorInTime) != 0;
    if (o & NSISO8601DateFormatWithYear) [p appendString:(o & NSISO8601DateFormatWithWeekOfYear) ? @"YYYY" : @"yyyy"];
    if (o & NSISO8601DateFormatWithMonth) [p appendFormat:@"%@MM", dash && [p length] ? @"-" : @""];
    if (o & NSISO8601DateFormatWithWeekOfYear) [p appendFormat:@"%@'W'ww", dash && [p length] ? @"-" : @""];
    if (o & NSISO8601DateFormatWithDay) {
        if (o & NSISO8601DateFormatWithWeekOfYear) [p appendFormat:@"%@ee", dash && [p length] ? @"-" : @""];
        else if (o & NSISO8601DateFormatWithMonth) [p appendFormat:@"%@dd", dash && [p length] ? @"-" : @""];
        else [p appendFormat:@"%@DDD", dash && [p length] ? @"-" : @""];
    }
    if (o & NSISO8601DateFormatWithTime) {
        if ([p length]) [p appendString:(o & NSISO8601DateFormatWithSpaceBetweenDateAndTime) ? @" " : @"'T'"];
        [p appendFormat:@"HH%@mm%@ss", colon ? @":" : @"", colon ? @":" : @""];
        if (o & NSISO8601DateFormatWithFractionalSeconds) [p appendString:@".SSS"];
    }
    if (o & NSISO8601DateFormatWithTimeZone) {
        if ([tz secondsFromGMT] == 0) [p appendString:@"'Z'"];
        else [p appendString:(o & NSISO8601DateFormatWithColonSeparatorInTimeZone) ? @"xxx" : @"xx"];
    }
    return p;
}

static NSDateFormatter *
iso_formatter(NSISO8601DateFormatOptions options, NSTimeZone *tz)
{
    NSDateFormatter *f = [[[NSDateFormatter alloc] init] autorelease];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierISO8601];
    f.timeZone = tz;
    f.dateFormat = iso_pattern(options, tz);
    return f;
}

- (NSString *)stringFromDate:(NSDate *)date { return [iso_formatter(_formatOptions, _timeZone) stringFromDate:date]; }

- (NSDate *)dateFromString:(NSString *)string
{
    NSDate *d = [iso_formatter(_formatOptions, _timeZone) dateFromString:string];
    if (!d && (_formatOptions & NSISO8601DateFormatWithTimeZone)) {
        /* A zone other than Z. */
        NSDateFormatter *f = iso_formatter(_formatOptions, [NSTimeZone timeZoneForSecondsFromGMT:3600]);
        d = [f dateFromString:string];
    }
    return d;
}

- (NSString *)stringForObjectValue:(id)obj { return [obj isKindOfClass:[NSDate class]] ? [self stringFromDate:obj] : nil; }

+ (NSString *)stringFromDate:(NSDate *)date timeZone:(NSTimeZone *)timeZone formatOptions:(NSISO8601DateFormatOptions)formatOptions
{
    return [iso_formatter(formatOptions, timeZone) stringFromDate:date];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_timeZone forKey:@"NS.timeZone"];
    [coder encodeInteger:(NSInteger)_formatOptions forKey:@"NS.formatOptions"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        NSTimeZone *tz = [coder decodeObjectOfClass:[NSTimeZone class] forKey:@"NS.timeZone"];
        if (tz) self.timeZone = tz;
        _formatOptions = (NSISO8601DateFormatOptions)[coder decodeIntegerForKey:@"NS.formatOptions"];
    }
    return self;
}

@end

/* MARK: - NSDateComponentsFormatter */

@implementation NSDateComponentsFormatter

@synthesize unitsStyle = _fStyle, allowedUnits = _fUnits, zeroFormattingBehavior = _fZero, calendar = _fCalendar,
    referenceDate = _fReference, allowsFractionalUnits = _fFractional, maximumUnitCount = _fMaxUnits,
    collapsesLargestUnit = _fCollapse, includesApproximationPhrase = _fApprox, includesTimeRemainingPhrase = _fRemaining,
    formattingContext = _fContext;

- (instancetype)init
{
    if ((self = [super init])) _fZero = NSDateComponentsFormatterZeroFormattingBehaviorDefault;
    return self;
}

- (void)dealloc
{
    [_fCalendar release];
    [_fReference release];
    [super dealloc];
}

typedef struct {
    NSCalendarUnit unit;
    double seconds;
    const char *full, *fulls, *shortName, *abbreviated, *brief;
} Unit;

static const Unit units[] = {
    { NSCalendarUnitYear, 31536000, "year", "years", "yr", "y", "yr" },
    { NSCalendarUnitMonth, 2592000, "month", "months", "mth", "mo", "mth" },
    { NSCalendarUnitWeekOfMonth, 604800, "week", "weeks", "wk", "w", "wk" },
    { NSCalendarUnitDay, 86400, "day", "days", "day", "d", "day" },
    { NSCalendarUnitHour, 3600, "hour", "hours", "hr", "h", "hr" },
    { NSCalendarUnitMinute, 60, "minute", "minutes", "min", "m", "min" },
    { NSCalendarUnitSecond, 1, "second", "seconds", "sec", "s", "sec" },
};

static NSString *
spelled(long n)
{
    NSNumberFormatter *f = [[[NSNumberFormatter alloc] init] autorelease];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    f.numberStyle = NSNumberFormatterSpellOutStyle;
    return [f stringFromNumber:@(n)];
}

- (NSString *)stringFromTimeInterval:(NSTimeInterval)ti
{
    NSCalendarUnit allowed = _fUnits ? _fUnits : (NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitWeekOfMonth | NSCalendarUnitDay |
                                                 NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond);
    if (!_fUnits) allowed &= ~(NSCalendarUnitWeekOfMonth | NSCalendarUnitMonth | NSCalendarUnitYear);
    BOOL negative = ti < 0;
    double left = fabs(round(ti));
    long values[7] = { 0 };
    for (int i = 0; i < 7; i++) {
        if (!(allowed & units[i].unit)) continue;
        values[i] = (long)floor(left / units[i].seconds);
        left -= (double)values[i] * units[i].seconds;
    }
    BOOL pad = (_fZero & NSDateComponentsFormatterZeroFormattingBehaviorPad) != 0;
    if (_fStyle == NSDateComponentsFormatterUnitsStylePositional) {
        /* h:mm:ss, with days as "1d" ahead, as Apple's. */
        NSMutableString *s = [NSMutableString string];
        int first = -1;
        for (int i = 0; i < 7; i++) {
            if (!(allowed & units[i].unit) || units[i].unit < NSCalendarUnitHour) continue;
            if (first < 0 && !values[i] && !pad && units[i].unit != NSCalendarUnitMinute) continue;
            [s appendFormat:first < 0 ? (pad ? @"%02ld" : @"%ld") : @":%02ld", values[i]];
            if (first < 0) first = i;
        }
        for (int i = 3; i >= 0; i--)
            if ((allowed & units[i].unit) && values[i]) [s insertString:[NSString stringWithFormat:@"%ld%s ", values[i], units[i].abbreviated] atIndex:0];
        return negative ? [@"-" stringByAppendingString:s] : s;
    }
    NSMutableArray *parts = [NSMutableArray array];
    NSInteger shown = 0;
    for (int i = 0; i < 7; i++) {
        if (!(allowed & units[i].unit)) continue;
        if (!values[i] && !pad) continue;
        if (_fMaxUnits && shown >= _fMaxUnits) break;
        long v = values[i];
        switch (_fStyle) {
        case NSDateComponentsFormatterUnitsStyleAbbreviated: [parts addObject:[NSString stringWithFormat:@"%ld%s", v, units[i].abbreviated]]; break;
        case NSDateComponentsFormatterUnitsStyleShort: [parts addObject:[NSString stringWithFormat:@"%ld %s", v, units[i].shortName]]; break;
        case NSDateComponentsFormatterUnitsStyleBrief: [parts addObject:[NSString stringWithFormat:@"%ld%s", v, units[i].brief]]; break;
        case NSDateComponentsFormatterUnitsStyleSpellOut:
            [parts addObject:[NSString stringWithFormat:@"%@ %s", spelled(v), v == 1 ? units[i].full : units[i].fulls]];
            break;
        default: [parts addObject:[NSString stringWithFormat:@"%ld %s", v, v == 1 ? units[i].full : units[i].fulls]]; break;
        }
        shown++;
    }
    if (![parts count]) {
        int smallest = 6;
        for (int i = 6; i >= 0; i--) if (allowed & units[i].unit) { smallest = i; break; }
        if (_fStyle == NSDateComponentsFormatterUnitsStyleAbbreviated) return [NSString stringWithFormat:@"0%s", units[smallest].abbreviated];
        return [NSString stringWithFormat:@"0 %s", _fStyle == NSDateComponentsFormatterUnitsStyleShort ? units[smallest].shortName : units[smallest].fulls];
    }
    NSString *sep = (_fStyle == NSDateComponentsFormatterUnitsStyleAbbreviated || _fStyle == NSDateComponentsFormatterUnitsStyleBrief) ? @" " : @", ";
    NSString *s = [parts componentsJoinedByString:sep];
    if (_fApprox) s = [@"About " stringByAppendingString:s];
    if (_fRemaining) s = [s stringByAppendingString:@" remaining"];
    return negative ? [@"-" stringByAppendingString:s] : s;
}

- (NSString *)stringFromDate:(NSDate *)startDate toDate:(NSDate *)endDate
{
    return [self stringFromTimeInterval:[endDate timeIntervalSinceDate:startDate]];
}

- (NSString *)stringFromDateComponents:(NSDateComponents *)c
{
    NSTimeInterval t = 0;
    if (c.day != NSDateComponentUndefined) t += c.day * 86400.0;
    if (c.hour != NSDateComponentUndefined) t += c.hour * 3600.0;
    if (c.minute != NSDateComponentUndefined) t += c.minute * 60.0;
    if (c.second != NSDateComponentUndefined) t += (double)c.second;
    if (c.weekOfMonth != NSDateComponentUndefined) t += c.weekOfMonth * 604800.0;
    return [self stringFromTimeInterval:t];
}

+ (NSString *)localizedStringFromDateComponents:(NSDateComponents *)components unitsStyle:(NSDateComponentsFormatterUnitsStyle)unitsStyle
{
    NSDateComponentsFormatter *f = [[[NSDateComponentsFormatter alloc] init] autorelease];
    f.unitsStyle = unitsStyle;
    return [f stringFromDateComponents:components];
}

- (NSString *)stringForObjectValue:(id)obj
{
    if ([obj isKindOfClass:[NSNumber class]]) return [self stringFromTimeInterval:[obj doubleValue]];
    if ([obj isKindOfClass:[NSDateComponents class]]) return [self stringFromDateComponents:obj];
    return nil;
}

- (BOOL)getObjectValue:(id *)obj forString:(NSString *)string errorDescription:(NSString **)error { return NO; }

@end

/* MARK: - Ordered collection differences */

@implementation NSOrderedCollectionChange {
    id _object;
    NSCollectionChangeType _type;
    NSUInteger _index, _associated;
}

+ (NSOrderedCollectionChange *)changeWithObject:(id)anObject type:(NSCollectionChangeType)type index:(NSUInteger)index
{
    return [[[self alloc] initWithObject:anObject type:type index:index associatedIndex:NSNotFound] autorelease];
}

+ (NSOrderedCollectionChange *)changeWithObject:(id)anObject type:(NSCollectionChangeType)type index:(NSUInteger)index associatedIndex:(NSUInteger)associatedIndex
{
    return [[[self alloc] initWithObject:anObject type:type index:index associatedIndex:associatedIndex] autorelease];
}

- (instancetype)initWithObject:(id)anObject type:(NSCollectionChangeType)type index:(NSUInteger)index
{
    return [self initWithObject:anObject type:type index:index associatedIndex:NSNotFound];
}

- (instancetype)initWithObject:(id)anObject type:(NSCollectionChangeType)type index:(NSUInteger)index associatedIndex:(NSUInteger)associatedIndex
{
    if ((self = [super init])) {
        _object = [anObject retain];
        _type = type;
        _index = index;
        _associated = associatedIndex;
    }
    return self;
}

- (void)dealloc { [_object release]; [super dealloc]; }
- (id)object { return _object; }
- (NSCollectionChangeType)changeType { return _type; }
- (NSUInteger)index { return _index; }
- (NSUInteger)associatedIndex { return _associated; }

@end

@implementation NSOrderedCollectionDifference {
    NSArray *_insertions, *_removals;
}

- (instancetype)initWithChanges:(NSArray<NSOrderedCollectionChange *> *)changes
{
    if ((self = [super init])) {
        NSMutableArray *ins = [NSMutableArray array], *rem = [NSMutableArray array];
        for (NSOrderedCollectionChange *c in changes) [(c.changeType == NSCollectionChangeInsert ? ins : rem) addObject:c];
        [ins sortUsingComparator:^NSComparisonResult(NSOrderedCollectionChange *a, NSOrderedCollectionChange *b) { return [@(a.index) compare:@(b.index)]; }];
        [rem sortUsingComparator:^NSComparisonResult(NSOrderedCollectionChange *a, NSOrderedCollectionChange *b) { return [@(a.index) compare:@(b.index)]; }];
        _insertions = [ins copy];
        _removals = [rem copy];
    }
    return self;
}

- (instancetype)initWithInsertIndexes:(NSIndexSet *)inserts insertedObjects:(NSArray *)insertedObjects removeIndexes:(NSIndexSet *)removes removedObjects:(NSArray *)removedObjects
{
    return [self initWithInsertIndexes:inserts insertedObjects:insertedObjects removeIndexes:removes removedObjects:removedObjects additionalChanges:@[]];
}

- (instancetype)initWithInsertIndexes:(NSIndexSet *)inserts insertedObjects:(NSArray *)insertedObjects removeIndexes:(NSIndexSet *)removes
                       removedObjects:(NSArray *)removedObjects additionalChanges:(NSArray<NSOrderedCollectionChange *> *)changes
{
    NSMutableArray *all = [NSMutableArray arrayWithArray:changes];
    __block NSUInteger i = 0;
    [inserts enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [all addObject:[NSOrderedCollectionChange changeWithObject:i < [insertedObjects count] ? insertedObjects[i] : nil type:NSCollectionChangeInsert index:idx]];
        i++;
    }];
    i = 0;
    [removes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [all addObject:[NSOrderedCollectionChange changeWithObject:i < [removedObjects count] ? removedObjects[i] : nil type:NSCollectionChangeRemove index:idx]];
        i++;
    }];
    return [self initWithChanges:all];
}

- (void)dealloc
{
    [_insertions release];
    [_removals release];
    [super dealloc];
}

- (NSArray *)insertions { return _insertions; }
- (NSArray *)removals { return _removals; }
- (BOOL)hasChanges { return [_insertions count] || [_removals count]; }

/* Removals (highest index first), then insertions, as Apple's enumerates. */
- (NSArray *)allChanges
{
    NSMutableArray *a = [NSMutableArray arrayWithArray:[[_removals reverseObjectEnumerator] allObjects]];
    [a addObjectsFromArray:_insertions];
    return a;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    if (state->state == 0) {
        state->extra[1] = (unsigned long)(uintptr_t)[[self allChanges] retain];
        [(id)(uintptr_t)state->extra[1] autorelease];
    }
    return [(NSArray *)(uintptr_t)state->extra[1] countByEnumeratingWithState:state objects:buffer count:len];
}

- (NSOrderedCollectionDifference *)differenceByTransformingChangesWithBlock:(NSOrderedCollectionChange<id> *(NS_NOESCAPE ^)(NSOrderedCollectionChange<id> *))block
{
    NSMutableArray *changes = [NSMutableArray array];
    for (NSOrderedCollectionChange *c in [self allChanges]) [changes addObject:block(c)];
    return [[[NSOrderedCollectionDifference alloc] initWithChanges:changes] autorelease];
}

- (instancetype)inverseDifference
{
    NSMutableArray *changes = [NSMutableArray array];
    for (NSOrderedCollectionChange *c in [self allChanges])
        [changes addObject:[NSOrderedCollectionChange changeWithObject:c.object type:c.changeType == NSCollectionChangeInsert ? NSCollectionChangeRemove : NSCollectionChangeInsert
                                                                 index:c.index associatedIndex:c.associatedIndex]];
    return [[[NSOrderedCollectionDifference alloc] initWithChanges:changes] autorelease];
}

@end

/* The longest common subsequence of `old` and `new`: what isn't in it was
 * removed (by old index) or inserted (by new index). */
static NSOrderedCollectionDifference *
difference(NSArray *new, NSArray *old, BOOL (^equal)(id, id))
{
    NSUInteger n = [old count], m = [new count];
    NSUInteger *lcs = calloc((n + 1) * (m + 1), sizeof(NSUInteger));
#define L(i, j) lcs[(i) * (m + 1) + (j)]
    for (NSInteger i = (NSInteger)n - 1; i >= 0; i--)
        for (NSInteger j = (NSInteger)m - 1; j >= 0; j--)
            L(i, j) = equal(old[i], new[j]) ? L(i + 1, j + 1) + 1 : MAX(L(i + 1, j), L(i, j + 1));
    NSMutableArray *changes = [NSMutableArray array];
    NSUInteger i = 0, j = 0;
    while (i < n || j < m) {
        if (i < n && j < m && equal(old[i], new[j])) { i++; j++; }
        else if (j < m && (i >= n || L(i, j + 1) >= L(i + 1, j))) { [changes addObject:[NSOrderedCollectionChange changeWithObject:new[j] type:NSCollectionChangeInsert index:j]]; j++; }
        else { [changes addObject:[NSOrderedCollectionChange changeWithObject:old[i] type:NSCollectionChangeRemove index:i]]; i++; }
    }
#undef L
    free(lcs);
    return [[[NSOrderedCollectionDifference alloc] initWithChanges:changes] autorelease];
}

static NSArray *
apply_difference(NSArray *base, NSOrderedCollectionDifference *diff)
{
    NSMutableArray *a = [[base mutableCopy] autorelease];
    for (NSOrderedCollectionChange *c in [[diff removals] reverseObjectEnumerator]) {
        if (c.index >= [a count]) return nil;
        [a removeObjectAtIndex:c.index];
    }
    for (NSOrderedCollectionChange *c in [diff insertions]) {
        if (c.index > [a count]) return nil;
        [a insertObject:c.object atIndex:c.index];
    }
    return a;
}

@implementation NSArray (NSArrayDiffing)

- (NSOrderedCollectionDifference *)differenceFromArray:(NSArray *)other withOptions:(NSOrderedCollectionDifferenceCalculationOptions)options
                                  usingEquivalenceTest:(BOOL (NS_NOESCAPE ^)(id, id))block
{
    return difference(self, other, block);
}

- (NSOrderedCollectionDifference *)differenceFromArray:(NSArray *)other withOptions:(NSOrderedCollectionDifferenceCalculationOptions)options
{
    return difference(self, other, ^BOOL(id a, id b) { return [a isEqual:b]; });
}

- (NSOrderedCollectionDifference *)differenceFromArray:(NSArray *)other { return [self differenceFromArray:other withOptions:0]; }
- (NSArray *)arrayByApplyingDifference:(NSOrderedCollectionDifference *)difference { return apply_difference(self, difference); }

@end

@implementation NSMutableArray (NSMutableArrayDiffing)
- (void)applyDifference:(NSOrderedCollectionDifference *)diff
{
    NSArray *r = apply_difference(self, diff);
    if (r) [self setArray:r];
}
@end

@implementation NSOrderedSet (NSOrderedSetDiffing)

- (NSOrderedCollectionDifference *)differenceFromOrderedSet:(NSOrderedSet *)other withOptions:(NSOrderedCollectionDifferenceCalculationOptions)options
                                       usingEquivalenceTest:(BOOL (NS_NOESCAPE ^)(id, id))block
{
    return difference([self array], [other array], block);
}

- (NSOrderedCollectionDifference *)differenceFromOrderedSet:(NSOrderedSet *)other withOptions:(NSOrderedCollectionDifferenceCalculationOptions)options
{
    return difference([self array], [other array], ^BOOL(id a, id b) { return [a isEqual:b]; });
}

- (NSOrderedCollectionDifference *)differenceFromOrderedSet:(NSOrderedSet *)other { return [self differenceFromOrderedSet:other withOptions:0]; }

- (NSOrderedSet *)orderedSetByApplyingDifference:(NSOrderedCollectionDifference *)diff
{
    NSArray *r = apply_difference([self array], diff);
    return r ? [NSOrderedSet orderedSetWithArray:r] : nil;
}

@end

@implementation NSMutableOrderedSet (NSMutableOrderedSetDiffing)
- (void)applyDifference:(NSOrderedCollectionDifference *)diff
{
    NSArray *r = apply_difference([self array], diff);
    if (!r) return;
    [self removeAllObjects];
    [self addObjectsFromArray:r];
}
@end

/* MARK: - NSDistributedNotificationCenter */

NSDistributedNotificationCenterType const NSLocalNotificationCenterType = @"NSLocalNotificationCenterType";

@interface _NSLocalNotificationCenter : NSDistributedNotificationCenter
@end
@implementation _NSLocalNotificationCenter
@end

@implementation NSDistributedNotificationCenter

+ (NSDistributedNotificationCenter *)notificationCenterForType:(NSDistributedNotificationCenterType)notificationCenterType
{
    static NSDistributedNotificationCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [[_NSLocalNotificationCenter alloc] init]; });
    return center;
}

+ (NSDistributedNotificationCenter *)defaultCenter { return [self notificationCenterForType:NSLocalNotificationCenterType]; }

- (BOOL)suspended { return NO; }
- (void)setSuspended:(BOOL)suspended { }

- (void)addObserver:(id)observer selector:(SEL)selector name:(NSNotificationName)name object:(NSString *)object
 suspensionBehavior:(NSNotificationSuspensionBehavior)suspensionBehavior
{
    [self addObserver:observer selector:selector name:name object:object];
}

- (void)postNotificationName:(NSNotificationName)name object:(NSString *)object userInfo:(NSDictionary *)userInfo deliverImmediately:(BOOL)deliverImmediately
{
    [self postNotificationName:name object:object userInfo:userInfo];
}

- (void)postNotificationName:(NSNotificationName)name object:(NSString *)object userInfo:(NSDictionary *)userInfo options:(NSDistributedNotificationOptions)options
{
    [self postNotificationName:name object:object userInfo:userInfo];
}

@end
