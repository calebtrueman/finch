/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Smaller parts of Foundation (docs/design/FOUNDATION.md), against the SDK's
 * headers: zones and memory pages, NSDebug.h's switches, HFS type codes, the
 * constants Apple exports that have no class of their own here yet,
 * NSAssertionHandler (what NSAssert calls), NSIndexPath, NSDateInterval,
 * NSAffineTransform and NSValueTransformer.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <execinfo.h>
#include <malloc/malloc.h>
#include <mach/mach.h>
#include <math.h>
#include <os/log.h>
#include <sys/sysctl.h>

#include "Foundation_Finch.h"

/* MARK: - Constants */

double NSFoundationVersionNumber = 4424.1;

NSErrorDomain const NSMachErrorDomain = @"NSMachErrorDomain";
NSErrorDomain const NSURLErrorDomain = @"NSURLErrorDomain";
NSString *const NSURLErrorFailingURLErrorKey = @"NSErrorFailingURLKey";
NSString *const NSURLErrorFailingURLStringErrorKey = @"NSErrorFailingURLStringKey";
NSString *const NSErrorFailingURLStringKey = @"NSErrorFailingURLStringKey";
NSString *const NSURLErrorFailingURLPeerTrustErrorKey = @"NSURLErrorFailingURLPeerTrustErrorKey";
NSString *const NSURLErrorBackgroundTaskCancelledReasonKey = @"NSURLErrorBackgroundTaskCancelledReasonKey";
NSString *const NSURLErrorNetworkUnavailableReasonKey = @"NSURLErrorNetworkUnavailableReasonKey";
NSErrorUserInfoKey const NSUserStringVariantErrorKey = @"NSUserStringVariant";
NSString *const NSDetailedErrorsKey = @"NSDetailedErrors";
NSString *const NSInvalidValueErrorKey = @"NSInvalidValue";
NSString *const NSDescriptionErrorKey = @"NSDescription";
NSString *const NSSourceFilePathErrorKey = @"NSSourceFilePathErrorKey";
NSString *const NSDestinationFilePathErrorKey = @"NSDestinationFilePath";
NSString *const NSFileManagerUnmountDissentingProcessIdentifierErrorKey = @"NSFileManagerUnmountDissentingProcessIdentifierErrorKey";

NSExceptionName const NSInconsistentArchiveException = @"NSInconsistentArchiveException";
NSExceptionName const NSObjectInaccessibleException = @"NSObjectInaccessibleException";
NSExceptionName const NSObjectNotAvailableException = @"NSObjectNotAvailableException";
NSExceptionName const NSOldStyleException = @"NSOldStyleException";
NSExceptionName const NSPortTimeoutException = @"NSPortTimeoutException";
NSExceptionName const NSInvalidSendPortException = @"NSInvalidSendPortException";
NSExceptionName const NSInvalidReceivePortException = @"NSInvalidReceivePortException";
NSExceptionName const NSPortSendException = @"NSPortSendException";
NSExceptionName const NSPortReceiveException = @"NSPortReceiveException";
NSExceptionName const NSFileHandleOperationException = @"NSFileHandleOperationException";
NSExceptionName const NSFailedAuthenticationException = @"NSFailedAuthenticationException";
NSExceptionName const NSOperationNotSupportedForKeyException = @"NSOperationNotSupportedForKeyException";
NSExceptionName const NSInvocationOperationVoidResultException = @"NSInvocationOperationVoidResultException";
NSExceptionName const NSInvocationOperationCancelledException = @"NSInvalidOperationCancelledException";
NSString *const NSUnknownKeyException = @"NSUnknownKeyException";

NSFileProtectionType const NSFileProtectionNone = @"NSFileProtectionNone";
NSFileProtectionType const NSFileProtectionComplete = @"NSFileProtectionComplete";
NSFileProtectionType const NSFileProtectionCompleteUnlessOpen = @"NSFileProtectionCompleteUnlessOpen";
NSFileProtectionType const NSFileProtectionCompleteUntilFirstUserAuthentication = @"NSFileProtectionCompleteUntilFirstUserAuthentication";
NSFileProtectionType const NSFileProtectionCompleteWhenUserInactive = @"NSFileProtectionCompleteWhenUserInactive";
NSFileProtectionType const NSFileProtectionCompleteUntilUserAuthentication = @"NSFileProtectionCompleteUntilUserAuthentication";
NSFileProtectionType const NSFileProtectionWriteOnly = @"NSFileProtectionWriteOnly";
NSFileAttributeKey const NSFileExtendedAttributes = @"NSFileExtendedAttributes";

/* The old NSUserDefaults date and number keys (NSUserDefaults.h). */
#define DEFAULTS_KEY(NAME) NSString *const NAME = @#NAME;
DEFAULTS_KEY(NSWeekDayNameArray)
DEFAULTS_KEY(NSShortWeekDayNameArray)
DEFAULTS_KEY(NSMonthNameArray)
DEFAULTS_KEY(NSShortMonthNameArray)
DEFAULTS_KEY(NSTimeFormatString)
DEFAULTS_KEY(NSDateFormatString)
DEFAULTS_KEY(NSTimeDateFormatString)
DEFAULTS_KEY(NSShortTimeDateFormatString)
DEFAULTS_KEY(NSCurrencySymbol)
DEFAULTS_KEY(NSThousandsSeparator)
DEFAULTS_KEY(NSInternationalCurrencyString)
DEFAULTS_KEY(NSDecimalDigits)
DEFAULTS_KEY(NSAMPMDesignation)
DEFAULTS_KEY(NSHourNameDesignations)
DEFAULTS_KEY(NSYearMonthWeekDesignations)
DEFAULTS_KEY(NSEarlierTimeDesignations)
DEFAULTS_KEY(NSLaterTimeDesignations)
DEFAULTS_KEY(NSThisDayDesignations)
DEFAULTS_KEY(NSNextDayDesignations)
DEFAULTS_KEY(NSNextNextDayDesignations)
DEFAULTS_KEY(NSPriorDayDesignations)
DEFAULTS_KEY(NSDateTimeOrdering)
DEFAULTS_KEY(NSShortDateFormatString)
DEFAULTS_KEY(NSPositiveCurrencyFormatString)
DEFAULTS_KEY(NSNegativeCurrencyFormatString)
#undef DEFAULTS_KEY

/* MARK: - NSDebug.h */

BOOL NSDebugEnabled = NO;
BOOL NSZombieEnabled = NO;
BOOL NSDeallocateZombies = NO;
BOOL NSKeepAllocationStatistics = NO;
BOOL NSHangOnUncaughtException = NO;

BOOL NSIsFreedObject(id anObject) { return NO; }
void NSRecordAllocationEvent(int eventType, id object) { }

NSUInteger
NSCountFrames(void)
{
    void *frames[256];
    int n = backtrace(frames, 256);
    return n > 1 ? (NSUInteger)(n - 1) : 0;
}

void *
NSReturnAddress(NSUInteger frame)
{
    void *frames[256];
    int n = backtrace(frames, 256);
    return (NSInteger)frame + 1 < n ? frames[frame + 1] : NULL;
}

void *
NSFrameAddress(NSUInteger frame)
{
    void **fp = __builtin_frame_address(0);
    for (NSUInteger i = 0; fp && i <= frame; i++) fp = *fp;
    return fp;
}

/* MARK: - Zones and pages (NSZone.h): malloc zones underneath. */

NSZone *NSDefaultMallocZone(void) { return (NSZone *)malloc_default_zone(); }

NSZone *
NSCreateZone(NSUInteger startSize, NSUInteger granularity, BOOL canFree)
{
    return (NSZone *)malloc_create_zone(startSize, 0);
}

void NSRecycleZone(NSZone *zone) { if ((malloc_zone_t *)zone != malloc_default_zone()) malloc_destroy_zone((malloc_zone_t *)zone); }
void NSSetZoneName(NSZone *zone, NSString *name) { malloc_set_zone_name(zone ? (malloc_zone_t *)zone : malloc_default_zone(), [name UTF8String]); }

NSString *
NSZoneName(NSZone *zone)
{
    const char *n = malloc_get_zone_name(zone ? (malloc_zone_t *)zone : malloc_default_zone());
    return n ? [NSString stringWithUTF8String:n] : @"";
}

NSZone *NSZoneFromPointer(void *ptr) { return (NSZone *)malloc_zone_from_ptr(ptr); }
void *NSZoneMalloc(NSZone *zone, NSUInteger size) { return malloc_zone_malloc(zone ? (malloc_zone_t *)zone : malloc_default_zone(), size); }
void *NSZoneCalloc(NSZone *zone, NSUInteger n, NSUInteger size) { return malloc_zone_calloc(zone ? (malloc_zone_t *)zone : malloc_default_zone(), n, size); }
void *NSZoneRealloc(NSZone *zone, void *ptr, NSUInteger size) { return malloc_zone_realloc(zone ? (malloc_zone_t *)zone : malloc_default_zone(), ptr, size); }
void NSZoneFree(NSZone *zone, void *ptr) { if (ptr) free(ptr); }
void *NSAllocateCollectable(NSUInteger size, NSUInteger options) { return calloc(1, size); }
void *NSReallocateCollectable(void *ptr, NSUInteger size, NSUInteger options) { return realloc(ptr, size); }

NSUInteger NSPageSize(void) { return (NSUInteger)vm_page_size; }
NSUInteger NSLogPageSize(void) { return (NSUInteger)__builtin_ctzl(vm_page_size); }
NSUInteger NSRoundUpToMultipleOfPageSize(NSUInteger bytes) { return (bytes + vm_page_size - 1) & ~((NSUInteger)vm_page_size - 1); }
NSUInteger NSRoundDownToMultipleOfPageSize(NSUInteger bytes) { return bytes & ~((NSUInteger)vm_page_size - 1); }

void *
NSAllocateMemoryPages(NSUInteger bytes)
{
    vm_address_t addr = 0;
    if (vm_allocate(mach_task_self(), &addr, NSRoundUpToMultipleOfPageSize(bytes), VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return (void *_Nonnull)0;
    return (void *)addr;
}

void NSDeallocateMemoryPages(void *ptr, NSUInteger bytes) { vm_deallocate(mach_task_self(), (vm_address_t)ptr, NSRoundUpToMultipleOfPageSize(bytes)); }
void NSCopyMemoryPages(const void *source, void *dest, NSUInteger bytes) { memmove(dest, source, bytes); }

NSUInteger
NSRealMemoryAvailable(void)
{
    uint64_t mem = 0;
    size_t len = sizeof(mem);
    sysctlbyname("hw.memsize", &mem, &len, NULL, 0);
    return (NSUInteger)mem;
}

/* MARK: - HFS type codes: "'TEXT'" */

NSString *
NSFileTypeForHFSTypeCode(OSType code)
{
    char c[4] = { (char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code };
    return [NSString stringWithFormat:@"'%.4s'", c];
}

OSType
NSHFSTypeCodeFromFileType(NSString *fileType)
{
    const char *s = [fileType UTF8String];
    if (!s || strlen(s) != 6 || s[0] != '\'' || s[5] != '\'') return 0;
    return (OSType)((unsigned char)s[1] << 24 | (unsigned char)s[2] << 16 | (unsigned char)s[3] << 8 | (unsigned char)s[4]);
}

NSString *NSHFSTypeOfFile(NSString *fullFilePath) { return nil; }

/* MARK: - NSAssertionHandler */

NSString *const NSAssertionHandlerKey = @"NSAssertionHandler";

@implementation NSAssertionHandler

+ (NSAssertionHandler *)currentHandler
{
    NSMutableDictionary *d = [[NSThread currentThread] threadDictionary];
    NSAssertionHandler *h = [d objectForKey:NSAssertionHandlerKey];
    if (!h) {
        h = [[[NSAssertionHandler alloc] init] autorelease];
        [d setObject:h forKey:NSAssertionHandlerKey];
    }
    return h;
}

/* Log to os_log as Apple's does, then raise NSInternalInconsistencyException
 * with the assertion's message. */
static void
fail(NSString *where, NSString *file, NSInteger line, NSString *format, va_list ap)
{
    os_log_error(OS_LOG_DEFAULT, "*** Assertion failure in %{public}s, %{public}s:%ld", [where UTF8String], [file UTF8String], (long)line);
    NSString *reason = format ? [[[NSString alloc] initWithFormat:format arguments:ap] autorelease] : @"";
    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:reason userInfo:nil];
}

- (void)handleFailureInMethod:(SEL)selector object:(id)object file:(NSString *)fileName lineNumber:(NSInteger)line description:(NSString *)format, ...
{
    BOOL cls = object && object_isClass(object);
    NSString *where = [NSString stringWithFormat:@"%c[%s %s]", cls ? '+' : '-', object_getClassName(object), sel_getName(selector)];
    va_list ap;
    va_start(ap, format);
    fail(where, fileName, line, format, ap);
    va_end(ap);
}

- (void)handleFailureInFunction:(NSString *)functionName file:(NSString *)fileName lineNumber:(NSInteger)line description:(NSString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    fail(functionName, fileName, line, format, ap);
    va_end(ap);
}

@end

/* MARK: - NSIndexPath */

@implementation NSIndexPath {
    NSUInteger *_indexes;
    NSUInteger _length;
}

+ (BOOL)supportsSecureCoding { return YES; }
+ (instancetype)indexPathWithIndex:(NSUInteger)index { return [[[self alloc] initWithIndex:index] autorelease]; }
+ (instancetype)indexPathWithIndexes:(const NSUInteger [])indexes length:(NSUInteger)length
{
    return [[[self alloc] initWithIndexes:indexes length:length] autorelease];
}

- (instancetype)init { return [self initWithIndexes:NULL length:0]; }
- (instancetype)initWithIndex:(NSUInteger)index { return [self initWithIndexes:&index length:1]; }

- (instancetype)initWithIndexes:(const NSUInteger [])indexes length:(NSUInteger)length
{
    if ((self = [super init])) {
        _length = length;
        _indexes = malloc((length + 1) * sizeof(NSUInteger));
        if (length) memcpy(_indexes, indexes, length * sizeof(NSUInteger));
    }
    return self;
}

- (void)dealloc
{
    free(_indexes);
    [super dealloc];
}

- (NSUInteger)length { return _length; }
- (NSUInteger)indexAtPosition:(NSUInteger)position { return position < _length ? _indexes[position] : NSNotFound; }

- (NSIndexPath *)indexPathByAddingIndex:(NSUInteger)index
{
    NSUInteger *n = malloc((_length + 1) * sizeof(NSUInteger));
    memcpy(n, _indexes, _length * sizeof(NSUInteger));
    n[_length] = index;
    NSIndexPath *p = [NSIndexPath indexPathWithIndexes:n length:_length + 1];
    free(n);
    return p;
}

- (NSIndexPath *)indexPathByRemovingLastIndex
{
    return [NSIndexPath indexPathWithIndexes:_indexes length:_length ? _length - 1 : 0];
}

- (void)getIndexes:(NSUInteger *)indexes range:(NSRange)positionRange
{
    if (NSMaxRange(positionRange) > _length)
        FinchRaise(NSRangeException, "*** -[NSIndexPath getIndexes:range:]: range %s exceeds length %lu",
            [NSStringFromRange(positionRange) UTF8String], (unsigned long)_length);
    memcpy(indexes, _indexes + positionRange.location, positionRange.length * sizeof(NSUInteger));
}

- (void)getIndexes:(NSUInteger *)indexes { memcpy(indexes, _indexes, _length * sizeof(NSUInteger)); }

- (NSComparisonResult)compare:(NSIndexPath *)other
{
    NSUInteger n = MIN(_length, [other length]);
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger a = _indexes[i], b = [other indexAtPosition:i];
        if (a != b) return a < b ? NSOrderedAscending : NSOrderedDescending;
    }
    return _length < [other length] ? NSOrderedAscending : _length > [other length] ? NSOrderedDescending : NSOrderedSame;
}

- (BOOL)isEqual:(id)object
{
    return object == self || ([object isKindOfClass:[NSIndexPath class]] && [self compare:object] == NSOrderedSame);
}

- (NSUInteger)hash
{
    NSUInteger h = _length;
    for (NSUInteger i = 0; i < _length; i++) h = h * 31 + _indexes[i];
    return h;
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

/* Apple's: "<NSIndexPath: 0x...> {length = 3, path = 1 - 4 - 2}". */
- (NSString *)description
{
    NSMutableArray *parts = [NSMutableArray arrayWithCapacity:_length];
    for (NSUInteger i = 0; i < _length; i++) [parts addObject:[NSString stringWithFormat:@"%lu", (unsigned long)_indexes[i]]];
    return [NSString stringWithFormat:@"<%s: %p> {length = %lu, path = %@}", object_getClassName(self), self, (unsigned long)_length,
        [parts componentsJoinedByString:@" - "]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:(NSInteger)_length forKey:@"NSIndexPathLength"];
    if (_length == 1) {
        [coder encodeInteger:(NSInteger)_indexes[0] forKey:@"NSIndexPathValue"];
    } else if (_length > 1) {
        NSMutableData *d = [NSMutableData data];
        for (NSUInteger i = 0; i < _length; i++) {
            NSUInteger v = _indexes[i];
            do {
                uint8_t b = v & 0x7F;
                v >>= 7;
                if (v) b |= 0x80;
                [d appendBytes:&b length:1];
            } while (v);
        }
        [coder encodeObject:d forKey:@"NSIndexPathData"];
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSUInteger length = (NSUInteger)[coder decodeIntegerForKey:@"NSIndexPathLength"];
    if (length == 1) {
        NSUInteger v = (NSUInteger)[coder decodeIntegerForKey:@"NSIndexPathValue"];
        return [self initWithIndexes:&v length:1];
    }
    NSData *d = [coder decodeObjectOfClass:[NSData class] forKey:@"NSIndexPathData"];
    NSUInteger *idx = calloc(length + 1, sizeof(NSUInteger));
    const uint8_t *p = [d bytes], *end = p + [d length];
    for (NSUInteger i = 0; i < length && p < end; i++) {
        NSUInteger v = 0;
        for (int shift = 0; p < end && shift < 64; shift += 7) {
            uint8_t b = *p++;
            v |= (NSUInteger)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
        }
        idx[i] = v;
    }
    id r = [self initWithIndexes:idx length:length];
    free(idx);
    return r;
}

@end

/* MARK: - NSDateInterval */

@interface _NSConcreteDateInterval : NSDateInterval
@end

@implementation NSDateInterval {
    NSDate *_start;
    NSTimeInterval _duration;
}

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSDateInterval class]) return [_NSConcreteDateInterval allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init { return [self initWithStartDate:[NSDate date] duration:0]; }

- (instancetype)initWithStartDate:(NSDate *)startDate duration:(NSTimeInterval)duration
{
    if (duration < 0) FinchRaise(NSInternalInconsistencyException, "Cannot create an NSDateInterval with a negative duration");
    if ((self = [super init])) {
        _start = [startDate copy];
        _duration = duration;
    }
    return self;
}

- (instancetype)initWithStartDate:(NSDate *)startDate endDate:(NSDate *)endDate
{
    return [self initWithStartDate:startDate duration:[endDate timeIntervalSinceDate:startDate]];
}

- (void)dealloc
{
    [_start release];
    [super dealloc];
}

- (NSDate *)startDate { return _start; }
- (NSDate *)endDate { return [_start dateByAddingTimeInterval:_duration]; }
- (NSTimeInterval)duration { return _duration; }

- (NSComparisonResult)compare:(NSDateInterval *)other
{
    NSComparisonResult r = [_start compare:[other startDate]];
    if (r != NSOrderedSame) return r;
    return _duration < [other duration] ? NSOrderedAscending : _duration > [other duration] ? NSOrderedDescending : NSOrderedSame;
}

- (BOOL)isEqualToDateInterval:(NSDateInterval *)other { return [self compare:other] == NSOrderedSame; }
- (BOOL)isEqual:(id)object { return object == self || ([object isKindOfClass:[NSDateInterval class]] && [self isEqualToDateInterval:object]); }
- (NSUInteger)hash { return [_start hash] ^ (NSUInteger)_duration; }

- (BOOL)containsDate:(NSDate *)date
{
    NSTimeInterval t = [date timeIntervalSinceDate:_start];
    return t >= 0 && t <= _duration;
}

- (BOOL)intersectsDateInterval:(NSDateInterval *)other
{
    return [self containsDate:[other startDate]] || [self containsDate:[other endDate]] || [other containsDate:_start];
}

- (NSDateInterval *)intersectionWithDateInterval:(NSDateInterval *)other
{
    if (![self intersectsDateInterval:other]) return nil;
    NSDate *start = [[_start laterDate:[other startDate]] retain];
    NSDate *end = [[self endDate] earlierDate:[other endDate]];
    NSDateInterval *r = [[[NSDateInterval alloc] initWithStartDate:start endDate:end] autorelease];
    [start release];
    return r;
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

/* Apple's: "<_NSConcreteDateInterval: 0x...> (Start Date) ... + (Duration) 3600.000000 seconds = (End Date) ...". */
- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s: %p> (Start Date) %@ + (Duration) %f seconds = (End Date) %@", object_getClassName(self), self,
        _start, _duration, [self endDate]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_start forKey:@"NS.startDate"];
    [coder encodeDouble:_duration forKey:@"NS.duration"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSDate *start = [coder decodeObjectOfClass:[NSDate class] forKey:@"NS.startDate"];
    return [self initWithStartDate:start ? start : [NSDate dateWithTimeIntervalSinceReferenceDate:0] duration:[coder decodeDoubleForKey:@"NS.duration"]];
}

@end

@implementation _NSConcreteDateInterval
@end

/* MARK: - NSAffineTransform */

/* Points are row vectors: p' = p M, with M = [m11 m12 0; m21 m22 0; tX tY 1].
 * Each operation is applied before the transform already there, as Apple's
 * is: translate, then rotate, then scale moves a point by the scale first. */
static NSAffineTransformStruct
multiply(NSAffineTransformStruct a, NSAffineTransformStruct b)
{
    NSAffineTransformStruct r;
    r.m11 = a.m11 * b.m11 + a.m12 * b.m21;
    r.m12 = a.m11 * b.m12 + a.m12 * b.m22;
    r.m21 = a.m21 * b.m11 + a.m22 * b.m21;
    r.m22 = a.m21 * b.m12 + a.m22 * b.m22;
    r.tX = a.tX * b.m11 + a.tY * b.m21 + b.tX;
    r.tY = a.tX * b.m12 + a.tY * b.m22 + b.tY;
    return r;
}

@implementation NSAffineTransform {
    NSAffineTransformStruct _t;
}

+ (BOOL)supportsSecureCoding { return YES; }
+ (NSAffineTransform *)transform { return [[[self alloc] init] autorelease]; }

- (instancetype)init
{
    if ((self = [super init])) _t = (NSAffineTransformStruct){ 1, 0, 0, 1, 0, 0 };
    return self;
}

- (instancetype)initWithTransform:(NSAffineTransform *)transform
{
    if ((self = [self init])) _t = [transform transformStruct];
    return self;
}

- (NSAffineTransformStruct)transformStruct { return _t; }
- (void)setTransformStruct:(NSAffineTransformStruct)s { _t = s; }

- (void)prependStruct:(NSAffineTransformStruct)op { _t = multiply(op, _t); }
- (void)translateXBy:(CGFloat)dx yBy:(CGFloat)dy { [self prependStruct:(NSAffineTransformStruct){ 1, 0, 0, 1, dx, dy }]; }
- (void)rotateByRadians:(CGFloat)angle
{
    CGFloat c = cos(angle), s = sin(angle);
    [self prependStruct:(NSAffineTransformStruct){ c, s, -s, c, 0, 0 }];
}
- (void)rotateByDegrees:(CGFloat)angle { [self rotateByRadians:angle * M_PI / 180]; }
- (void)scaleBy:(CGFloat)scale { [self scaleXBy:scale yBy:scale]; }
- (void)scaleXBy:(CGFloat)sx yBy:(CGFloat)sy { [self prependStruct:(NSAffineTransformStruct){ sx, 0, 0, sy, 0, 0 }]; }
- (void)appendTransform:(NSAffineTransform *)transform { _t = multiply(_t, [transform transformStruct]); }
- (void)prependTransform:(NSAffineTransform *)transform { _t = multiply([transform transformStruct], _t); }

- (void)invert
{
    CGFloat det = _t.m11 * _t.m22 - _t.m12 * _t.m21;
    if (det == 0) FinchRaise(NSInternalInconsistencyException, "NSAffineTransform: Transform has no inverse");
    NSAffineTransformStruct i;
    i.m11 = _t.m22 / det;
    i.m12 = -_t.m12 / det;
    i.m21 = -_t.m21 / det;
    i.m22 = _t.m11 / det;
    i.tX = -(_t.tX * i.m11 + _t.tY * i.m21);
    i.tY = -(_t.tX * i.m12 + _t.tY * i.m22);
    _t = i;
}

- (NSPoint)transformPoint:(NSPoint)p
{
    return NSMakePoint(_t.m11 * p.x + _t.m21 * p.y + _t.tX, _t.m12 * p.x + _t.m22 * p.y + _t.tY);
}

- (NSSize)transformSize:(NSSize)s
{
    return NSMakeSize(_t.m11 * s.width + _t.m21 * s.height, _t.m12 * s.width + _t.m22 * s.height);
}

- (id)copyWithZone:(NSZone *)zone { return [[NSAffineTransform allocWithZone:zone] initWithTransform:self]; }
- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[NSAffineTransform class]]) return NO;
    NSAffineTransformStruct o = [object transformStruct];
    return !memcmp(&o, &_t, sizeof(o));
}
- (NSUInteger)hash { return (NSUInteger)(_t.m11 * 7 + _t.m22 * 13 + _t.tX * 17 + _t.tY * 19); }

- (void)encodeWithCoder:(NSCoder *)coder
{
    float f[6] = { (float)_t.m11, (float)_t.m12, (float)_t.m21, (float)_t.m22, (float)_t.tX, (float)_t.tY };
    [coder encodeBytes:(const uint8_t *)f length:sizeof(f) forKey:@"NSTransformStruct"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        NSUInteger n = 0;
        const float *f = (const float *)[coder decodeBytesForKey:@"NSTransformStruct" returnedLength:&n];
        if (f && n >= 6 * sizeof(float)) _t = (NSAffineTransformStruct){ f[0], f[1], f[2], f[3], f[4], f[5] };
    }
    return self;
}

@end

/* MARK: - NSValueTransformer */

NSValueTransformerName const NSNegateBooleanTransformerName = @"NSNegateBoolean";
NSValueTransformerName const NSIsNilTransformerName = @"NSIsNil";
NSValueTransformerName const NSIsNotNilTransformerName = @"NSIsNotNil";
NSValueTransformerName const NSUnarchiveFromDataTransformerName = @"NSUnarchiveFromData";
NSValueTransformerName const NSKeyedUnarchiveFromDataTransformerName = @"NSKeyedUnarchiveFromData";
NSValueTransformerName const NSSecureUnarchiveFromDataTransformerName = @"NSSecureUnarchiveFromData";

@interface _NSNegateBooleanTransformer : NSValueTransformer @end
@interface _NSIsNilTransformer : NSValueTransformer @end
@interface _NSIsNotNilTransformer : NSValueTransformer @end
@interface _NSKeyedUnarchiveFromDataTransformer : NSValueTransformer @end
@interface _NSUnarchiveFromDataTransformer : _NSKeyedUnarchiveFromDataTransformer @end

static NSMutableDictionary *transformers;

@implementation NSValueTransformer

static void
register_builtins(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        transformers = [NSMutableDictionary new];
        [transformers setObject:[[_NSNegateBooleanTransformer new] autorelease] forKey:NSNegateBooleanTransformerName];
        [transformers setObject:[[_NSIsNilTransformer new] autorelease] forKey:NSIsNilTransformerName];
        [transformers setObject:[[_NSIsNotNilTransformer new] autorelease] forKey:NSIsNotNilTransformerName];
        [transformers setObject:[[_NSUnarchiveFromDataTransformer new] autorelease] forKey:NSUnarchiveFromDataTransformerName];
        [transformers setObject:[[_NSKeyedUnarchiveFromDataTransformer new] autorelease] forKey:NSKeyedUnarchiveFromDataTransformerName];
        [transformers setObject:[[NSSecureUnarchiveFromDataTransformer new] autorelease] forKey:NSSecureUnarchiveFromDataTransformerName];
    });
}

+ (void)setValueTransformer:(NSValueTransformer *)transformer forName:(NSValueTransformerName)name
{
    register_builtins();
    @synchronized (transformers) {
        if (transformer) [transformers setObject:transformer forKey:name];
        else [transformers removeObjectForKey:name];
    }
}

/* A registered transformer, else a new instance of the class by that name. */
+ (NSValueTransformer *)valueTransformerForName:(NSValueTransformerName)name
{
    register_builtins();
    @synchronized (transformers) {
        NSValueTransformer *t = [transformers objectForKey:name];
        if (t) return t;
        Class c = NSClassFromString(name);
        if (c && [c isSubclassOfClass:[NSValueTransformer class]]) {
            t = [[c new] autorelease];
            [transformers setObject:t forKey:name];
        }
        return t;
    }
}

+ (NSArray<NSValueTransformerName> *)valueTransformerNames
{
    register_builtins();
    @synchronized (transformers) {
        return [transformers allKeys];
    }
}

+ (Class)transformedValueClass { return [NSObject class]; }
+ (BOOL)allowsReverseTransformation { return YES; }
- (id)transformedValue:(id)value { return value; }

- (id)reverseTransformedValue:(id)value
{
    if (![[self class] allowsReverseTransformation])
        FinchRaise(NSInvalidArgumentException, "%s: reverse transformation not allowed", object_getClassName(self));
    return [self transformedValue:value];
}

@end

@implementation _NSNegateBooleanTransformer
+ (Class)transformedValueClass { return [NSNumber class]; }
+ (BOOL)allowsReverseTransformation { return YES; }
- (id)transformedValue:(id)value { return [NSNumber numberWithBool:![value boolValue]]; }
@end

@implementation _NSIsNilTransformer
+ (Class)transformedValueClass { return [NSNumber class]; }
- (id)transformedValue:(id)value { return [NSNumber numberWithBool:value == nil]; }
@end

@implementation _NSIsNotNilTransformer
+ (Class)transformedValueClass { return [NSNumber class]; }
- (id)transformedValue:(id)value { return [NSNumber numberWithBool:value != nil]; }
@end

@implementation _NSKeyedUnarchiveFromDataTransformer
+ (Class)transformedValueClass { return [NSData class]; }
+ (BOOL)allowsReverseTransformation { return YES; }
- (id)transformedValue:(id)value
{
    return [value isKindOfClass:[NSData class]] ? [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:value error:NULL] : nil;
}
- (id)reverseTransformedValue:(id)value
{
    return value ? [NSKeyedArchiver archivedDataWithRootObject:value requiringSecureCoding:NO error:NULL] : nil;
}
@end

@implementation _NSUnarchiveFromDataTransformer
@end

@implementation NSSecureUnarchiveFromDataTransformer

+ (NSArray<Class> *)allowedTopLevelClasses
{
    return @[ [NSArray class], [NSDictionary class], [NSSet class], [NSString class], [NSNumber class], [NSDate class], [NSData class],
              [NSURL class], [NSUUID class], [NSNull class] ];
}

+ (Class)transformedValueClass { return [NSData class]; }
+ (BOOL)allowsReverseTransformation { return YES; }

- (id)transformedValue:(id)value
{
    if (![value isKindOfClass:[NSData class]]) return nil;
    return [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithArray:[[self class] allowedTopLevelClasses]] fromData:value error:NULL];
}

- (id)reverseTransformedValue:(id)value
{
    return value ? [NSKeyedArchiver archivedDataWithRootObject:value requiringSecureCoding:YES error:NULL] : nil;
}

@end
