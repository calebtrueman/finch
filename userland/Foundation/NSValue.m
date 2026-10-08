/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSValue and NSNumber (docs/design/FOUNDATION.md), against the SDK's
 * declarations. Numbers are CFNumbers (and the two CFBooleans), whose classes
 * __NSCFNumber and __NSCFBoolean are CoreFoundation's subclasses of NSNumber;
 * +alloc returns NSPlaceholderNumber, which makes them. Other values are
 * NSConcreteValue: the bytes and their type encoding.
 *
 * Also clang's constant number literals (@42, @2.5 in code built for macOS
 * 26): NSConstantIntegerNumber, NSConstantFloatNumber,
 * NSConstantDoubleNumber, with Apple's layouts, which the compiler emits.
 *
 * NSNumber's abstract methods work from -objCType and -getValue:, so any
 * subclass that implements those two works; the CF-backed ones override the
 * accessors with CFNumberGetValue.
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <math.h>
#include <string.h>

#include "Foundation_Finch.h"

/* MARK: - Scalar conversion */

/* A number's value, whatever its encoding: as a long long, an unsigned long
 * long and a double, from the bytes -getValue: gives. */
typedef struct {
    long long s;
    unsigned long long u;
    double d;
    BOOL isFloat, isUnsigned;
} Scalar;

static Scalar
scalar(const char *type, const void *p)
{
    Scalar v = { 0, 0, 0, NO, NO };
    switch (*type) {
    case 'c': v.s = *(const char *)p; break;
    case 'C': v.u = *(const unsigned char *)p; v.isUnsigned = YES; break;
    case 'B': v.u = *(const _Bool *)p; v.isUnsigned = YES; break;
    case 's': v.s = *(const short *)p; break;
    case 'S': v.u = *(const unsigned short *)p; v.isUnsigned = YES; break;
    case 'i': v.s = *(const int *)p; break;
    case 'I': v.u = *(const unsigned int *)p; v.isUnsigned = YES; break;
    case 'l': v.s = *(const long *)p; break;
    case 'L': v.u = *(const unsigned long *)p; v.isUnsigned = YES; break;
    case 'q': v.s = *(const long long *)p; break;
    case 'Q': v.u = *(const unsigned long long *)p; v.isUnsigned = YES; break;
    case 'f': v.d = *(const float *)p; v.isFloat = YES; break;
    case 'd': v.d = *(const double *)p; v.isFloat = YES; break;
    default: break;
    }
    if (v.isFloat) {
        v.s = isnan(v.d) ? 0 : v.d >= 0x1p63 ? LLONG_MAX : v.d <= -0x1p63 ? LLONG_MIN : (long long)v.d;
        v.u = v.d < 0 ? (unsigned long long)v.s : v.d >= 0x1p64 ? ULLONG_MAX : (unsigned long long)v.d;
    } else if (v.isUnsigned) {
        v.s = (long long)v.u;
        v.d = (double)v.u;
    } else {
        v.u = (unsigned long long)v.s;
        v.d = (double)v.s;
    }
    return v;
}

/* MARK: - NSValue */

@interface NSConcreteValue : NSValue {
    unsigned long long _specialFlags;
    void *typeInfo;                 /* the type encoding, then the bytes */
}
@end

@interface NSPlaceholderValue : NSValue
@end
@interface NSPlaceholderNumber : NSPlaceholderValue
@end

static NSPlaceholderValue *valuePlaceholder;
static NSPlaceholderNumber *numberPlaceholder;


@implementation NSValue

+ (void)initialize
{
    if (self == [NSValue class]) {
        valuePlaceholder = class_createInstance([NSPlaceholderValue class], 0);
        numberPlaceholder = class_createInstance([NSPlaceholderNumber class], 0);
    }
}

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSValue class]) return (id)valuePlaceholder;
    if (self == [NSNumber class]) return (id)numberPlaceholder;
    return [super allocWithZone:zone];
}

- (void)getValue:(void *)value size:(NSUInteger)size { [self getValue:value]; }
- (void)getValue:(void *)value { FinchAbstract(self, _cmd); }
- (const char *)objCType { FinchAbstract(self, _cmd); }

- (instancetype)initWithBytes:(const void *)value objCType:(const char *)type { return [self init]; }
- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)coder { }
+ (BOOL)supportsSecureCoding { return YES; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (BOOL)isNSValue__ { return YES; }

- (BOOL)isEqualToValue:(NSValue *)value
{
    if (value == self) return YES;
    if (!value || strcmp([self objCType], [value objCType])) return NO;
    NSUInteger size;
    NSGetSizeAndAlignment([self objCType], &size, NULL);
    void *a = calloc(1, size + 1), *b = calloc(1, size + 1);
    [self getValue:a size:size];
    [value getValue:b size:size];
    BOOL eq = memcmp(a, b, size) == 0;
    free(a);
    free(b);
    return eq;
}

- (BOOL)isEqual:(id)object
{
    return object == self || ([object isKindOfClass:[NSValue class]] && [self isEqualToValue:object]);
}

- (NSUInteger)hash
{
    NSUInteger size, h = 0;
    NSGetSizeAndAlignment([self objCType], &size, NULL);
    unsigned char *b = calloc(1, size + 1);
    [self getValue:b size:size];
    for (NSUInteger i = 0; i < size; i++) h = h * 31 + b[i];
    free(b);
    return h;
}

/* Apple's: the geometry types and NSRange by name, anything else as its
 * bytes ("{length = 4, bytes = 0x05000000}"). */
- (NSString *)description
{
    const char *t = [self objCType];
    NSUInteger size;
    NSGetSizeAndAlignment(t, &size, NULL);
    unsigned char *b = calloc(1, size + 16);
    [self getValue:b size:size];
    NSString *d;
    if (!strcmp(t, "{_NSRange=QQ}")) {
        NSRange r = *(NSRange *)b;
        d = [NSString stringWithFormat:@"NSRange: {%lu, %lu}", (unsigned long)r.location, (unsigned long)r.length];
    } else if (!strcmp(t, "{CGPoint=dd}")) {
        d = [@"NSPoint: " stringByAppendingString:NSStringFromPoint(*(NSPoint *)b)];
    } else if (!strcmp(t, "{CGSize=dd}")) {
        d = [@"NSSize: " stringByAppendingString:NSStringFromSize(*(NSSize *)b)];
    } else if (!strcmp(t, "{CGRect={CGPoint=dd}{CGSize=dd}}")) {
        d = [@"NSRect: " stringByAppendingString:NSStringFromRect(*(NSRect *)b)];
    } else if (!strcmp(t, "{NSEdgeInsets=dddd}")) {
        double *e = (double *)b;
        d = [NSString stringWithFormat:@"NSEdgeInsets: {%g, %g, %g, %g}", e[0], e[1], e[2], e[3]];
    } else {
        d = [[NSData dataWithBytes:b length:size] description];
    }
    free(b);
    return d;
}

@end

@implementation NSValue (NSValueCreation)
+ (NSValue *)valueWithBytes:(const void *)value objCType:(const char *)type
{
    return [[[NSConcreteValue alloc] initWithBytes:value objCType:type] autorelease];
}
+ (NSValue *)value:(const void *)value withObjCType:(const char *)type { return [self valueWithBytes:value objCType:type]; }
@end

@implementation NSValue (NSValueExtensionMethods)
+ (NSValue *)valueWithNonretainedObject:(id)anObject { return [self valueWithBytes:&anObject objCType:@encode(void *)]; }
- (id)nonretainedObjectValue { void *p = NULL; [self getValue:&p size:sizeof(p)]; return (id)p; }
+ (NSValue *)valueWithPointer:(const void *)pointer { return [self valueWithBytes:&pointer objCType:@encode(void *)]; }
- (void *)pointerValue { void *p = NULL; [self getValue:&p size:sizeof(p)]; return p; }
@end

@implementation NSValue (NSValueRangeExtensions)
+ (NSValue *)valueWithRange:(NSRange)range { return [self valueWithBytes:&range objCType:@encode(NSRange)]; }
- (NSRange)rangeValue { NSRange r = { 0, 0 }; [self getValue:&r size:sizeof(r)]; return r; }
@end

@implementation NSConcreteValue

/* The encoding without field names: {_NSRange="location"Q"length"Q} is
 * {_NSRange=QQ}, as Apple's NSValue keeps it. */
static char *
strip_names(const char *type)
{
    char *out = malloc(strlen(type) + 1), *o = out;
    for (const char *t = type; *t; t++) {
        if (*t == '"') {
            const char *end = strchr(t + 1, '"');
            if (!end) break;
            t = end;
            continue;
        }
        *o++ = *t;
    }
    *o = 0;
    return out;
}

- (instancetype)initWithBytes:(const void *)value objCType:(const char *)rawType
{
    char *stripped = strip_names(rawType);
    const char *type = stripped;
    if ((self = [super init])) {
        NSUInteger size, tl = strlen(type) + 1;
        NSGetSizeAndAlignment(type, &size, NULL);
        _specialFlags = size;
        typeInfo = malloc(tl + size);
        memcpy(typeInfo, type, tl);
        memcpy((char *)typeInfo + tl, value, size);
    }
    free(stripped);
    return self;
}

- (const char *)objCType { return typeInfo; }

- (void)getValue:(void *)value
{
    memcpy(value, (char *)typeInfo + strlen(typeInfo) + 1, (size_t)_specialFlags);
}

- (void)getValue:(void *)value size:(NSUInteger)size
{
    memcpy(value, (char *)typeInfo + strlen(typeInfo) + 1, MIN(size, (NSUInteger)_specialFlags));
}

- (void)dealloc
{
    free(typeInfo);
    [super dealloc];
}

@end

/* MARK: - NSNumber */

@implementation NSNumber

- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }

/* The abstract class (for subclasses): everything from -objCType and -getValue:. */
- (Scalar)_finchScalar
{
    unsigned char b[16] = { 0 };
    [self getValue:b size:sizeof(b)];
    return scalar([self objCType], b);
}

- (char)charValue { return (char)[self _finchScalar].s; }
- (unsigned char)unsignedCharValue { return (unsigned char)[self _finchScalar].u; }
- (short)shortValue { return (short)[self _finchScalar].s; }
- (unsigned short)unsignedShortValue { return (unsigned short)[self _finchScalar].u; }
- (int)intValue { return (int)[self _finchScalar].s; }
- (unsigned int)unsignedIntValue { return (unsigned int)[self _finchScalar].u; }
- (long)longValue { return (long)[self _finchScalar].s; }
- (unsigned long)unsignedLongValue { return (unsigned long)[self _finchScalar].u; }
- (long long)longLongValue { return [self _finchScalar].s; }
- (unsigned long long)unsignedLongLongValue { return [self _finchScalar].u; }
- (float)floatValue { return (float)[self _finchScalar].d; }
- (double)doubleValue { return [self _finchScalar].d; }
- (BOOL)boolValue { Scalar v = [self _finchScalar]; return v.isFloat ? v.d != 0 : v.u != 0; }
- (NSInteger)integerValue { return (NSInteger)[self _finchScalar].s; }
- (NSUInteger)unsignedIntegerValue { return (NSUInteger)[self _finchScalar].u; }

- (NSString *)stringValue { return [self descriptionWithLocale:nil]; }
- (NSString *)description { return [self descriptionWithLocale:nil]; }

- (NSString *)descriptionWithLocale:(id)locale
{
    const char *t = [self objCType];
    Scalar v = [self _finchScalar];
    if (*t == 'c' || *t == 'B') {
        if (*t == 'B') return v.u ? @"1" : @"0";
        return [NSString stringWithFormat:@"%d", (int)v.s];
    }
    if (*t == 'f') return [NSString stringWithFormat:@"%0.7g", v.d];
    if (*t == 'd') return [NSString stringWithFormat:@"%0.16g", v.d];
    if (v.isUnsigned) return [NSString stringWithFormat:@"%llu", v.u];
    return [NSString stringWithFormat:@"%lld", v.s];
}

- (NSComparisonResult)compare:(NSNumber *)other
{
    Scalar a = [self _finchScalar], b = [other _finchScalar];
    if (a.isFloat || b.isFloat) {
        if (a.d < b.d) return NSOrderedAscending;
        if (a.d > b.d) return NSOrderedDescending;
        return NSOrderedSame;
    }
    if (a.isUnsigned && b.isUnsigned) return a.u < b.u ? NSOrderedAscending : a.u > b.u ? NSOrderedDescending : NSOrderedSame;
    if (a.isUnsigned && a.u > LLONG_MAX) return NSOrderedDescending;
    if (b.isUnsigned && b.u > LLONG_MAX) return NSOrderedAscending;
    return a.s < b.s ? NSOrderedAscending : a.s > b.s ? NSOrderedDescending : NSOrderedSame;
}

- (BOOL)isEqualToNumber:(NSNumber *)number { return number && [self compare:number] == NSOrderedSame; }
- (BOOL)isEqual:(id)object
{
    return object == self || ([object isKindOfClass:[NSNumber class]] && [self isEqualToNumber:object]);
}
- (NSUInteger)hash { return CFHash((CFTypeRef)[NSNumber numberWithDouble:[self doubleValue]]); }
- (CFTypeID)_cfTypeID { return CFNumberGetTypeID(); }
- (BOOL)isNSNumber__ { return YES; }

/* What CF sends to numbers it didn't make (CFNumber.c). */
- (CFNumberType)_cfNumberType
{
    switch (*[self objCType]) {
    case 'c': case 'B': return kCFNumberCharType;
    case 'C': case 's': return kCFNumberShortType;
    case 'S': case 'i': return kCFNumberIntType;
    case 'f': return kCFNumberFloatType;
    case 'd': return kCFNumberDoubleType;
    default: return kCFNumberLongLongType;
    }
}

- (BOOL)_getValue:(void *)value forType:(CFNumberType)type
{
    Scalar v = [self _finchScalar];
    switch (type) {
    case kCFNumberSInt8Type: case kCFNumberCharType: *(int8_t *)value = (int8_t)v.s; break;
    case kCFNumberSInt16Type: case kCFNumberShortType: *(int16_t *)value = (int16_t)v.s; break;
    case kCFNumberSInt32Type: case kCFNumberIntType: *(int32_t *)value = (int32_t)v.s; break;
    case kCFNumberFloat32Type: case kCFNumberFloatType: *(float *)value = (float)v.d; break;
    case kCFNumberFloat64Type: case kCFNumberDoubleType: case kCFNumberCGFloatType: *(double *)value = v.d; break;
    default: *(int64_t *)value = v.s; break;
    }
    return YES;
}

- (CFComparisonResult)_reverseCompare:(NSNumber *)other { return (CFComparisonResult)-[self compare:other]; }

@end

@implementation NSNumber (NSNumberCreation)

#define FACTORY(NAME, INIT, TYPE) \
    + (NSNumber *)NAME:(TYPE)value { return [[[self alloc] INIT:value] autorelease]; }
FACTORY(numberWithChar, initWithChar, char)
FACTORY(numberWithUnsignedChar, initWithUnsignedChar, unsigned char)
FACTORY(numberWithShort, initWithShort, short)
FACTORY(numberWithUnsignedShort, initWithUnsignedShort, unsigned short)
FACTORY(numberWithInt, initWithInt, int)
FACTORY(numberWithUnsignedInt, initWithUnsignedInt, unsigned int)
FACTORY(numberWithLong, initWithLong, long)
FACTORY(numberWithUnsignedLong, initWithUnsignedLong, unsigned long)
FACTORY(numberWithLongLong, initWithLongLong, long long)
FACTORY(numberWithUnsignedLongLong, initWithUnsignedLongLong, unsigned long long)
FACTORY(numberWithFloat, initWithFloat, float)
FACTORY(numberWithDouble, initWithDouble, double)
FACTORY(numberWithBool, initWithBool, BOOL)
FACTORY(numberWithInteger, initWithInteger, NSInteger)
FACTORY(numberWithUnsignedInteger, initWithUnsignedInteger, NSUInteger)
#undef FACTORY

@end

/* The abstract NSNumber's -init...: subclasses store what they like. */
@implementation NSNumber (FinchAbstractInit)
#define INIT(NAME, TYPE) - (NSNumber *)NAME:(TYPE)value { return [super init]; }
INIT(initWithChar, char)
INIT(initWithUnsignedChar, unsigned char)
INIT(initWithShort, short)
INIT(initWithUnsignedShort, unsigned short)
INIT(initWithInt, int)
INIT(initWithUnsignedInt, unsigned int)
INIT(initWithLong, long)
INIT(initWithUnsignedLong, unsigned long)
INIT(initWithLongLong, long long)
INIT(initWithUnsignedLongLong, unsigned long long)
INIT(initWithFloat, float)
INIT(initWithDouble, double)
INIT(initWithBool, BOOL)
INIT(initWithInteger, NSInteger)
INIT(initWithUnsignedInteger, NSUInteger)
#undef INIT
@end

/* MARK: - Placeholders */

@implementation NSPlaceholderValue

- (instancetype)retain { return self; }
- (oneway void)release { }
- (instancetype)autorelease { return self; }
- (NSUInteger)retainCount { return NSUIntegerMax; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
- (void)dealloc { }
#pragma clang diagnostic pop

- (instancetype)initWithBytes:(const void *)value objCType:(const char *)type
{
    return (id)[[NSConcreteValue alloc] initWithBytes:value objCType:type];
}

@end

static id
cfnumber(CFNumberType type, const void *value)
{
    return (id)CFNumberCreate(NULL, type, value);
}

@implementation NSPlaceholderNumber

/* Unsigned values beyond the signed range of their size go in the next
 * larger signed type, as CFNumber has no unsigned types (Apple's does the
 * same; above LLONG_MAX it keeps the bits as a 128-bit CFNumber). */
- (NSNumber *)initWithChar:(char)v { return cfnumber(kCFNumberCharType, &v); }
- (NSNumber *)initWithUnsignedChar:(unsigned char)v { short s = v; return cfnumber(kCFNumberShortType, &s); }
- (NSNumber *)initWithShort:(short)v { return cfnumber(kCFNumberShortType, &v); }
- (NSNumber *)initWithUnsignedShort:(unsigned short)v { int i = v; return cfnumber(kCFNumberIntType, &i); }
- (NSNumber *)initWithInt:(int)v { return cfnumber(kCFNumberIntType, &v); }
- (NSNumber *)initWithUnsignedInt:(unsigned int)v { long long l = v; return cfnumber(kCFNumberLongLongType, &l); }
- (NSNumber *)initWithLong:(long)v { return cfnumber(kCFNumberLongType, &v); }
- (NSNumber *)initWithUnsignedLong:(unsigned long)v { return [self initWithUnsignedLongLong:v]; }
- (NSNumber *)initWithLongLong:(long long)v { return cfnumber(kCFNumberLongLongType, &v); }
- (NSNumber *)initWithUnsignedLongLong:(unsigned long long)v
{
    if (v <= LLONG_MAX) { long long l = (long long)v; return cfnumber(kCFNumberLongLongType, &l); }
    struct { int64_t high; uint64_t low; } s128 = { 0, v };
    return cfnumber((CFNumberType)17 /* kCFNumberSInt128Type */, &s128);
}
- (NSNumber *)initWithFloat:(float)v { return cfnumber(kCFNumberFloatType, &v); }
- (NSNumber *)initWithDouble:(double)v { return cfnumber(kCFNumberDoubleType, &v); }
- (NSNumber *)initWithBool:(BOOL)v { return (id)CFRetain(v ? kCFBooleanTrue : kCFBooleanFalse); }
- (NSNumber *)initWithInteger:(NSInteger)v { return cfnumber(kCFNumberNSIntegerType, &v); }
- (NSNumber *)initWithUnsignedInteger:(NSUInteger)v { return [self initWithUnsignedLongLong:v]; }

@end

/* MARK: - Constant literals */

/* Layouts as clang emits them (and as Apple's classes declare). */
@interface NSConstantIntegerNumber : NSNumber {
    const char *_encoding;
    long long _value;
}
@end
@interface NSConstantFloatNumber : NSNumber {
    float _value;
}
@end
@interface NSConstantDoubleNumber : NSNumber {
    double _value;
}
@end

#define CONSTANT_MEMORY \
    - (instancetype)retain { return self; } \
    - (oneway void)release { } \
    - (instancetype)autorelease { return self; } \
    - (NSUInteger)retainCount { return NSUIntegerMax; } \
    - (id)copyWithZone:(NSZone *)zone { return self; }

@implementation NSConstantIntegerNumber
CONSTANT_MEMORY
- (const char *)objCType { return _encoding; }
- (void)getValue:(void *)value
{
    NSUInteger size;
    NSGetSizeAndAlignment(_encoding, &size, NULL);
    switch (size) {
    case 1: *(int8_t *)value = (int8_t)_value; break;
    case 2: *(int16_t *)value = (int16_t)_value; break;
    case 4: *(int32_t *)value = (int32_t)_value; break;
    default: *(int64_t *)value = _value; break;
    }
}
- (void)getValue:(void *)value size:(NSUInteger)size { [self getValue:value]; }
@end

@implementation NSConstantFloatNumber
CONSTANT_MEMORY
- (const char *)objCType { return "f"; }
- (void)getValue:(void *)value { *(float *)value = _value; }
- (void)getValue:(void *)value size:(NSUInteger)size { [self getValue:value]; }
@end

@implementation NSConstantDoubleNumber
CONSTANT_MEMORY
- (const char *)objCType { return "d"; }
- (void)getValue:(void *)value { *(double *)value = _value; }
- (void)getValue:(void *)value size:(NSUInteger)size { [self getValue:value]; }
@end
