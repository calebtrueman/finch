/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSCoding for Foundation's value and collection classes
 * (docs/design/FOUNDATION.md), with Apple's keys, so archives move between
 * Finch and macOS:
 *
 *   NSMutableString  NS.string (in place)        NSArray, NSSet   NS.objects
 *   NSMutableData    NS.data (in place)          NSDictionary     NS.keys, NS.objects
 *   NSDate           NS.time                     NSURL            NS.base, NS.relative
 *   NSValue          NS.special + NS.rangeval.*, NS.pointval, NS.sizeval,
 *                    NS.rectval, NS.edgeval.*; others $0 (type), $1 (value)
 *   NSError          NSDomain, NSCode, NSUserInfo
 *   NSException      NS.name, NS.reason, NS.userinfo
 *   NSIndexSet       NSRangeCount + NSLocation/NSLength, or NSRangeData
 *                    (LEB128 location/length pairs)
 *   NSCharacterSet   NSString, NSRange, NSBuiltinID or NSBitmap, as CF says
 *   NSLocale         NS.identifier          NSTimeZone  NS.name, NS.data
 *   NSCalendar       NS.identifier, NS.locale, NS.timezone, NS.firstwkdy, NS.mindays
 *   NSDateComponents NS.<field> for each field that is set
 *
 * Plain strings, numbers and data never get here: the archiver stores them
 * as plist values.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

typedef CF_ENUM(CFIndex, CFCharacterSetKeyedCodingType) {
    kCFCharacterSetKeyedCodingTypeBitmap = 1,
    kCFCharacterSetKeyedCodingTypeBuiltin = 2,
    kCFCharacterSetKeyedCodingTypeRange = 3,
    kCFCharacterSetKeyedCodingTypeString = 4,
    kCFCharacterSetKeyedCodingTypeBuiltinAndBitmap = 5
};
CF_EXPORT CFCharacterSetKeyedCodingType _CFCharacterSetGetKeyedCodingType(CFCharacterSetRef cset);
CF_EXPORT CFCharacterSetPredefinedSet _CFCharacterSetGetKeyedCodingBuiltinType(CFCharacterSetRef cset);
CF_EXPORT CFRange _CFCharacterSetGetKeyedCodingRange(CFCharacterSetRef cset);
CF_EXPORT CFStringRef _CFCharacterSetCreateKeyedCodingString(CFCharacterSetRef cset);
CF_EXPORT bool _CFCharacterSetIsInverted(CFCharacterSetRef cset);

static NSSet *
plist_classes(void)
{
    return [NSSet setWithObjects:[NSArray class], [NSDictionary class], [NSString class], [NSNumber class], [NSDate class],
        [NSData class], [NSURL class], [NSNull class], nil];
}

static BOOL
requires_keyed(NSCoder *coder, id self, SEL _cmd)
{
    if ([coder allowsKeyedCoding]) return YES;
    FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: only keyed coders are supported", object_getClassName(self), sel_getName(_cmd));
}

/* MARK: - Strings and data */

@implementation NSString (FinchCoding)

- (void)encodeWithCoder:(NSCoder *)coder
{
    if ([coder allowsKeyedCoding]) {
        [coder _finchEncodePlist:[NSString stringWithString:self] forKey:@"NS.string"];
    } else {
        NSData *d = [self dataUsingEncoding:NSUTF8StringEncoding];
        [coder encodeBytes:[d bytes] length:[d length]];
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *s;
    if ([coder allowsKeyedCoding]) {
        s = [coder decodeObjectOfClass:[NSString class] forKey:@"NS.string"];
        if (![s isKindOfClass:[NSString class]]) {
            NSUInteger n = 0;
            const uint8_t *b = [coder decodeBytesForKey:@"NS.bytes" returnedLength:&n];
            s = b ? [[[NSString alloc] initWithBytes:b length:n encoding:NSUTF8StringEncoding] autorelease] : nil;
        }
    } else {
        NSUInteger n = 0;
        void *b = [coder decodeBytesWithReturnedLength:&n];
        s = [[[NSString alloc] initWithBytes:b length:n encoding:NSUTF8StringEncoding] autorelease];
    }
    if (!s) { [self release]; return nil; }
    return [self initWithString:s];
}

@end

@implementation NSMutableString (FinchCoding)
- (Class)classForCoder { return [NSMutableString class]; }
@end

@implementation NSData (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSData class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    if ([coder allowsKeyedCoding]) [coder _finchEncodePlist:[NSData dataWithData:self] forKey:@"NS.data"];
    else [coder encodeDataObject:self];   /* Apple's: an int count, then the bytes as a char array */
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *d = nil;
    if ([coder allowsKeyedCoding]) {
        d = [coder decodeObjectOfClass:[NSData class] forKey:@"NS.data"];
        if (![d isKindOfClass:[NSData class]]) {
            NSUInteger n = 0;
            const uint8_t *b = [coder decodeBytesForKey:@"NS.bytes" returnedLength:&n];
            d = b ? [NSData dataWithBytes:b length:n] : [NSData data];
        }
    } else {
        d = [coder decodeDataObject];
        if (self == [NSData allocWithZone:NULL]) {   /* the immutable placeholder */
            /* as Apple's: the coder's data object itself (mutable) */
            [self release];
            return [d retain];
        }
    }
    return [self initWithData:d];
}

@end

@implementation NSMutableData (FinchCoding)
- (Class)classForCoder { return [NSMutableData class]; }
@end

/* MARK: - Collections */

static NSArray *
decode_objects(NSCoder *coder, NSString *key, NSString *legacyPrefix)
{
    if ([coder containsValueForKey:key]) return [coder _finchDecodeArrayOfObjectsForKey:key];
    NSMutableArray *a = [NSMutableArray array];
    for (NSUInteger i = 0;; i++) {
        NSString *k = [NSString stringWithFormat:@"%@%lu", legacyPrefix, (unsigned long)i];
        if (![coder containsValueForKey:k]) break;
        id o = [coder decodeObjectForKey:k];
        if (!o) return nil;
        [a addObject:o];
    }
    return a;
}

@implementation NSArray (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSArray class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding]) {
        int n = (int)[self count];
        [coder encodeValueOfObjCType:@encode(int) at:&n];
        for (id o in self) [coder encodeObject:o];
        return;
    }
    [coder _finchEncodeArrayOfObjects:self forKey:@"NS.objects"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSArray *a;
    if ([coder allowsKeyedCoding]) {
        a = decode_objects(coder, @"NS.objects", @"NS.object.");
    } else {
        int n = 0;
        [coder decodeValueOfObjCType:@encode(int) at:&n size:sizeof(n)];
        NSMutableArray *m = [NSMutableArray arrayWithCapacity:n > 0 ? (NSUInteger)n : 0];
        for (int i = 0; i < n; i++) {
            id o = [coder decodeObject];
            if (o) [m addObject:o];
        }
        a = m;
    }
    if (!a) { [self release]; return nil; }
    return [self initWithArray:a];
}

@end

@implementation NSMutableArray (FinchCoding)
- (Class)classForCoder { return [NSMutableArray class]; }
@end

@implementation NSDictionary (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSDictionary class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSArray *keys = [self allKeys];
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:[keys count]];
    for (id k in keys) [values addObject:[self objectForKey:k]];
    if (![coder allowsKeyedCoding]) {
        int n = (int)[keys count];
        [coder encodeValueOfObjCType:@encode(int) at:&n];
        for (NSUInteger i = 0; i < (NSUInteger)n; i++) {
            [coder encodeObject:[keys objectAtIndex:i]];
            [coder encodeObject:[values objectAtIndex:i]];
        }
        return;
    }
    [coder _finchEncodeArrayOfObjects:keys forKey:@"NS.keys"];
    [coder _finchEncodeArrayOfObjects:values forKey:@"NS.objects"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSArray *keys, *values;
    if ([coder allowsKeyedCoding]) {
        keys = decode_objects(coder, @"NS.keys", @"NS.key.");
        values = decode_objects(coder, @"NS.objects", @"NS.object.");
    } else {
        int n = 0;
        [coder decodeValueOfObjCType:@encode(int) at:&n size:sizeof(n)];
        NSMutableArray *k = [NSMutableArray array], *v = [NSMutableArray array];
        for (int i = 0; i < n; i++) {
            id key = [coder decodeObject], value = [coder decodeObject];
            if (key && value) { [k addObject:key]; [v addObject:value]; }
        }
        keys = k;
        values = v;
    }
    if (!keys || !values || [keys count] != [values count]) { [self release]; return nil; }
    return [self initWithObjects:values forKeys:keys];
}

@end

@implementation NSMutableDictionary (FinchCoding)
- (Class)classForCoder { return [NSMutableDictionary class]; }
@end

@implementation NSSet (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSSet class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding]) {
        unsigned n = (unsigned)[self count];
        [coder encodeValueOfObjCType:@encode(unsigned) at:&n];
        for (id o in self) [coder encodeObject:o];
        return;
    }
    [coder _finchEncodeArrayOfObjects:[self allObjects] forKey:@"NS.objects"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSArray *a;
    if ([coder allowsKeyedCoding]) {
        a = decode_objects(coder, @"NS.objects", @"NS.object.");
    } else {
        unsigned n = 0;
        [coder decodeValueOfObjCType:@encode(unsigned) at:&n size:sizeof(n)];
        NSMutableArray *m = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) {
            id o = [coder decodeObject];
            if (o) [m addObject:o];
        }
        a = m;
    }
    if (!a) { [self release]; return nil; }
    return [self initWithArray:a];
}

@end

@implementation NSMutableSet (FinchCoding)
- (Class)classForCoder { return [NSMutableSet class]; }
@end

/* MARK: - NSNull, NSDate, NSURL */

@implementation NSNull (FinchCoding)
+ (instancetype)allocWithZone:(NSZone *)zone { return (id)kCFNull; }
+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSNull class]; }
- (void)encodeWithCoder:(NSCoder *)coder { }
- (instancetype)initWithCoder:(NSCoder *)coder { return (id)kCFNull; }
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@implementation NSDate (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSDate class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSTimeInterval t = [self timeIntervalSinceReferenceDate];
    if ([coder allowsKeyedCoding]) [coder encodeDouble:t forKey:@"NS.time"];
    else [coder encodeValueOfObjCType:@encode(double) at:&t];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSTimeInterval t = 0;
    if ([coder allowsKeyedCoding]) t = [coder decodeDoubleForKey:@"NS.time"];
    else [coder decodeValueOfObjCType:@encode(double) at:&t size:sizeof(t)];
    return [self initWithTimeIntervalSinceReferenceDate:t];
}

@end

@implementation NSURL (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSURL class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding]) {
        /* Apple's: whether there's a base, the base, then the relative string */
        NSURL *base = [self baseURL];
        char hasBase = base != nil;
        [coder encodeValueOfObjCType:@encode(char) at:&hasBase];
        if (base) [coder encodeObject:base];
        [coder encodeObject:[self relativeString]];
        return;
    }
    [coder encodeObject:[self baseURL] forKey:@"NS.base"];
    [coder encodeObject:[self relativeString] forKey:@"NS.relative"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSURL *base = nil;
    NSString *relative;
    if (![coder allowsKeyedCoding]) {
        char hasBase = 0;
        [coder decodeValueOfObjCType:@encode(char) at:&hasBase size:sizeof(hasBase)];
        if (hasBase) base = [coder decodeObject];
        relative = [coder decodeObject];
        if (!relative) { [self release]; return nil; }
        return [self initWithString:relative relativeToURL:base];
    }
    base = [coder decodeObjectOfClass:[NSURL class] forKey:@"NS.base"];
    relative = [coder decodeObjectOfClass:[NSString class] forKey:@"NS.relative"];
    if (!relative) { [self release]; return nil; }
    return [self initWithString:relative relativeToURL:base];
}

@end

/* MARK: - NSValue */

enum {
    SPECIAL_POINT = 1,
    SPECIAL_SIZE = 2,
    SPECIAL_RECT = 3,
    SPECIAL_RANGE = 4,
    SPECIAL_EDGE_INSETS = 12,
};

/* A number from a non-keyed coder: the value's type (a C string), then the
 * value. Returned retained. */
static NSNumber *
decode_number(NSCoder *coder)
{
    char *type = NULL;
    [coder decodeValueOfObjCType:@encode(char *) at:&type size:sizeof(type)];
    if (!type) return nil;
    NSString *keep = [NSString stringWithUTF8String:type];
    union { char c; unsigned char C; short s; unsigned short S; int i; unsigned I; long l; unsigned long L;
            long long q; unsigned long long Q; float f; double d; BOOL B; } v = { 0 };
    [coder decodeValueOfObjCType:[keep UTF8String] at:&v size:sizeof(v)];
    NSNumber *n;
    switch ([keep UTF8String][0]) {
    case 'c': n = [NSNumber numberWithChar:v.c]; break;
    case 'C': n = [NSNumber numberWithUnsignedChar:v.C]; break;
    case 'B': n = [NSNumber numberWithBool:v.B]; break;
    case 's': n = [NSNumber numberWithShort:v.s]; break;
    case 'S': n = [NSNumber numberWithUnsignedShort:v.S]; break;
    case 'i': n = [NSNumber numberWithInt:v.i]; break;
    case 'I': n = [NSNumber numberWithUnsignedInt:v.I]; break;
    case 'l': n = [NSNumber numberWithLong:v.l]; break;
    case 'L': n = [NSNumber numberWithUnsignedLong:v.L]; break;
    case 'q': n = [NSNumber numberWithLongLong:v.q]; break;
    case 'Q': n = [NSNumber numberWithUnsignedLongLong:v.Q]; break;
    case 'f': n = [NSNumber numberWithFloat:v.f]; break;
    case 'd': n = [NSNumber numberWithDouble:v.d]; break;
    default: n = nil;
    }
    return [n retain];
}

@implementation NSValue (FinchCoding)

- (Class)classForCoder { return [NSValue class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    const char *t = [self objCType];
    NSUInteger size;
    NSGetSizeAndAlignment(t, &size, NULL);
    void *b = calloc(1, size + 16);
    [self getValue:b size:size];
    if ([coder allowsKeyedCoding]) {
        if (!strcmp(t, @encode(NSRange))) {
            NSRange r = *(NSRange *)b;
            [coder encodeInt:SPECIAL_RANGE forKey:@"NS.special"];
            [coder encodeObject:@(r.length) forKey:@"NS.rangeval.length"];
            [coder encodeObject:@(r.location) forKey:@"NS.rangeval.location"];
            free(b);
            return;
        }
        if (!strcmp(t, @encode(NSPoint))) {
            [coder encodeInt:SPECIAL_POINT forKey:@"NS.special"];
            [coder encodeObject:NSStringFromPoint(*(NSPoint *)b) forKey:@"NS.pointval"];
            free(b);
            return;
        }
        if (!strcmp(t, @encode(NSSize))) {
            [coder encodeInt:SPECIAL_SIZE forKey:@"NS.special"];
            [coder encodeObject:NSStringFromSize(*(NSSize *)b) forKey:@"NS.sizeval"];
            free(b);
            return;
        }
        if (!strcmp(t, @encode(NSRect))) {
            [coder encodeInt:SPECIAL_RECT forKey:@"NS.special"];
            [coder encodeObject:NSStringFromRect(*(NSRect *)b) forKey:@"NS.rectval"];
            free(b);
            return;
        }
        if (!strcmp(t, @encode(NSEdgeInsets))) {
            NSEdgeInsets e = *(NSEdgeInsets *)b;
            [coder encodeInt:SPECIAL_EDGE_INSETS forKey:@"NS.special"];
            [coder encodeDouble:e.top forKey:@"NS.edgeval.top"];
            [coder encodeDouble:e.left forKey:@"NS.edgeval.left"];
            [coder encodeDouble:e.bottom forKey:@"NS.edgeval.bottom"];
            [coder encodeDouble:e.right forKey:@"NS.edgeval.right"];
            free(b);
            return;
        }
    }
    @try {
        [coder encodeValueOfObjCType:@encode(char *) at:&t];
        [coder encodeValueOfObjCType:t at:b];
    } @finally {
        free(b);
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ([coder allowsKeyedCoding] && [coder containsValueForKey:@"NS.special"]) {
        switch ([coder decodeIntForKey:@"NS.special"]) {
        case SPECIAL_RANGE: {
            NSRange r = NSMakeRange([[coder decodeObjectOfClass:[NSNumber class] forKey:@"NS.rangeval.location"] unsignedIntegerValue],
                [[coder decodeObjectOfClass:[NSNumber class] forKey:@"NS.rangeval.length"] unsignedIntegerValue]);
            return [self initWithBytes:&r objCType:@encode(NSRange)];
        }
        case SPECIAL_POINT: {
            NSPoint p = NSPointFromString([coder decodeObjectOfClass:[NSString class] forKey:@"NS.pointval"]);
            return [self initWithBytes:&p objCType:@encode(NSPoint)];
        }
        case SPECIAL_SIZE: {
            NSSize s = NSSizeFromString([coder decodeObjectOfClass:[NSString class] forKey:@"NS.sizeval"]);
            return [self initWithBytes:&s objCType:@encode(NSSize)];
        }
        case SPECIAL_RECT: {
            NSRect r = NSRectFromString([coder decodeObjectOfClass:[NSString class] forKey:@"NS.rectval"]);
            return [self initWithBytes:&r objCType:@encode(NSRect)];
        }
        case SPECIAL_EDGE_INSETS: {
            NSEdgeInsets e = { [coder decodeDoubleForKey:@"NS.edgeval.top"], [coder decodeDoubleForKey:@"NS.edgeval.left"],
                [coder decodeDoubleForKey:@"NS.edgeval.bottom"], [coder decodeDoubleForKey:@"NS.edgeval.right"] };
            return [self initWithBytes:&e objCType:@encode(NSEdgeInsets)];
        }
        default:
            [self release];
            return nil;
        }
    }
    if ([self isKindOfClass:objc_getClass("NSPlaceholderNumber")]) {
        /* [NSNumber alloc]'s placeholder is a value placeholder */
        [self release];
        return decode_number(coder);
    }
    char *type = NULL;
    [coder decodeValueOfObjCType:@encode(char *) at:&type size:sizeof(type)];
    if (!type) { [self release]; return nil; }
    NSString *keep = [NSString stringWithUTF8String:type];
    NSUInteger size;
    NSGetSizeAndAlignment([keep UTF8String], &size, NULL);
    void *b = calloc(1, size + 16);
    [coder decodeValueOfObjCType:[keep UTF8String] at:b size:size];
    id r = [self initWithBytes:b objCType:[keep UTF8String]];
    free(b);
    return r;
}

@end

@implementation NSNumber (FinchCoding)
- (Class)classForCoder { return [NSNumber class]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ([coder allowsKeyedCoding]) return [super initWithCoder:coder];
    [self release];
    return decode_number(coder);
}
@end

/* MARK: - NSError, NSException */

@implementation NSError (FinchCoding)

- (Class)classForCoder { return [NSError class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    [coder encodeObject:[self domain] forKey:@"NSDomain"];
    [coder encodeInteger:[self code] forKey:@"NSCode"];
    [coder encodeObject:[self userInfo] forKey:@"NSUserInfo"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    NSString *domain = [coder decodeObjectOfClass:[NSString class] forKey:@"NSDomain"];
    NSDictionary *info = [coder decodeObjectOfClasses:[plist_classes() setByAddingObject:[NSError class]] forKey:@"NSUserInfo"];
    if (!domain) { [self release]; return nil; }
    return [self initWithDomain:domain code:[coder decodeIntegerForKey:@"NSCode"] userInfo:info];
}

@end

@implementation NSException (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSException class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    [coder encodeObject:[self name] forKey:@"NS.name"];
    [coder encodeObject:[self reason] forKey:@"NS.reason"];
    [coder encodeObject:[self userInfo] forKey:@"NS.userinfo"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    return [self initWithName:[coder decodeObjectOfClass:[NSString class] forKey:@"NS.name"]
                       reason:[coder decodeObjectOfClass:[NSString class] forKey:@"NS.reason"]
                     userInfo:[coder decodeObjectOfClasses:plist_classes() forKey:@"NS.userinfo"]];
}

@end

/* MARK: - NSIndexSet */

static void
leb128(NSMutableData *d, NSUInteger v)
{
    do {
        uint8_t b = v & 0x7F;
        v >>= 7;
        if (v) b |= 0x80;
        [d appendBytes:&b length:1];
    } while (v);
}

static BOOL
read_leb128(const uint8_t **p, const uint8_t *end, NSUInteger *out)
{
    NSUInteger v = 0;
    for (int shift = 0; *p < end && shift < 64; shift += 7) {
        uint8_t b = *(*p)++;
        v |= (NSUInteger)(b & 0x7F) << shift;
        if (!(b & 0x80)) { *out = v; return YES; }
    }
    return NO;
}

@implementation NSIndexSet (FinchCoding)

- (void)encodeWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    NSMutableArray *ranges = [NSMutableArray array];
    [self enumerateRangesUsingBlock:^(NSRange r, BOOL *stop) { [ranges addObject:[NSValue valueWithRange:r]]; }];
    [coder encodeInteger:(NSInteger)[ranges count] forKey:@"NSRangeCount"];
    if ([ranges count] == 1) {
        NSRange r = [[ranges objectAtIndex:0] rangeValue];
        [coder encodeInteger:(NSInteger)r.location forKey:@"NSLocation"];
        [coder encodeInteger:(NSInteger)r.length forKey:@"NSLength"];
    } else if ([ranges count] > 1) {
        NSMutableData *d = [NSMutableData data];
        for (NSValue *v in ranges) {
            leb128(d, [v rangeValue].location);
            leb128(d, [v rangeValue].length);
        }
        [coder encodeObject:d forKey:@"NSRangeData"];
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
    NSInteger n = [coder decodeIntegerForKey:@"NSRangeCount"];
    if (n == 1) {
        [s addIndexesInRange:NSMakeRange((NSUInteger)[coder decodeIntegerForKey:@"NSLocation"], (NSUInteger)[coder decodeIntegerForKey:@"NSLength"])];
    } else if (n > 1) {
        NSData *d = [coder decodeObjectOfClass:[NSData class] forKey:@"NSRangeData"];
        const uint8_t *p = [d bytes], *end = p + [d length];
        for (NSInteger i = 0; i < n; i++) {
            NSUInteger loc, len;
            if (!read_leb128(&p, end, &loc) || !read_leb128(&p, end, &len)) { [self release]; return nil; }
            [s addIndexesInRange:NSMakeRange(loc, len)];
        }
    }
    return [self initWithIndexSet:s];
}

@end

/* MARK: - NSCharacterSet */

@implementation NSCharacterSet (FinchCoding)

- (void)encodeWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    CFCharacterSetRef cs = (CFCharacterSetRef)self;
    switch (_CFCharacterSetGetKeyedCodingType(cs)) {
    case kCFCharacterSetKeyedCodingTypeBuiltin:
        [coder encodeInteger:_CFCharacterSetGetKeyedCodingBuiltinType(cs) forKey:@"NSBuiltinID"];
        break;
    case kCFCharacterSetKeyedCodingTypeRange: {
        CFRange r = _CFCharacterSetGetKeyedCodingRange(cs);
        [coder encodeInt64:((int64_t)r.location << 32) | (int64_t)r.length forKey:@"NSRange"];
        break;
    }
    case kCFCharacterSetKeyedCodingTypeString: {
        CFStringRef s = _CFCharacterSetCreateKeyedCodingString(cs);
        [coder _finchEncodePlist:[NSString stringWithString:(NSString *)s] forKey:@"NSString"];
        CFRelease(s);
        break;
    }
    case kCFCharacterSetKeyedCodingTypeBuiltinAndBitmap:
        [coder encodeInteger:_CFCharacterSetGetKeyedCodingBuiltinType(cs) forKey:@"NSBuiltinID"];
        /* fall through */
    default:
        [coder _finchEncodePlist:[self bitmapRepresentation] forKey:@"NSBitmap"];
        break;
    }
    if (_CFCharacterSetIsInverted(cs) && _CFCharacterSetGetKeyedCodingType(cs) != kCFCharacterSetKeyedCodingTypeBitmap)
        [coder encodeBool:YES forKey:@"NSIsInverted"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    CFCharacterSetRef cs = NULL;
    if ([coder containsValueForKey:@"NSBitmap"]) {
        id bitmap = [coder decodeObjectOfClass:[NSData class] forKey:@"NSBitmap"];
        if ([bitmap isKindOfClass:[NSData class]]) cs = CFCharacterSetCreateWithBitmapRepresentation(NULL, (CFDataRef)bitmap);
    } else if ([coder containsValueForKey:@"NSBuiltinID"]) {
        CFCharacterSetRef b = CFCharacterSetGetPredefined((CFCharacterSetPredefinedSet)[coder decodeIntegerForKey:@"NSBuiltinID"]);
        cs = b ? CFRetain(b) : NULL;
    } else if ([coder containsValueForKey:@"NSRange"]) {
        int64_t v = [coder decodeInt64ForKey:@"NSRange"];
        cs = CFCharacterSetCreateWithCharactersInRange(NULL, CFRangeMake((CFIndex)(v >> 32), (CFIndex)(v & 0xFFFFFFFF)));
    } else {
        id s = [coder decodeObjectOfClass:[NSString class] forKey:@"NSString"];
        cs = CFCharacterSetCreateWithCharactersInString(NULL, (CFStringRef)([s isKindOfClass:[NSString class]] ? s : @""));
    }
    if (cs && [coder decodeBoolForKey:@"NSIsInverted"]) {
        CFCharacterSetRef inv = CFCharacterSetCreateInvertedSet(NULL, cs);
        CFRelease(cs);
        cs = inv;
    }
    /* +alloc gives one placeholder for each class. */
    BOOL mutable = self == [NSMutableCharacterSet allocWithZone:NULL];
    [self release];
    if (!cs) return nil;
    if (mutable) {
        CFMutableCharacterSetRef m = CFCharacterSetCreateMutableCopy(NULL, cs);
        CFRelease(cs);
        return (id)m;
    }
    return (id)cs;
}

@end

/* MARK: - Locales, time zones, calendars, date components */

@implementation NSLocale (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSLocale class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    [coder encodeObject:[self localeIdentifier] forKey:@"NS.identifier"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    NSString *ident = [coder decodeObjectOfClass:[NSString class] forKey:@"NS.identifier"];
    return [self initWithLocaleIdentifier:ident ? ident : @""];
}

@end

@implementation NSTimeZone (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSTimeZone class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    [coder encodeObject:[self name] forKey:@"NS.name"];
    [coder encodeObject:[self data] forKey:@"NS.data"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:@"NS.name"];
    NSData *data = [coder decodeObjectOfClass:[NSData class] forKey:@"NS.data"];
    if (!name) { [self release]; return nil; }
    return [self initWithName:name data:data];
}

@end

@implementation NSCalendar (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return [NSCalendar class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    [coder encodeObject:[self calendarIdentifier] forKey:@"NS.identifier"];
    [coder encodeObject:[self locale] forKey:@"NS.locale"];
    [coder encodeObject:[self timeZone] forKey:@"NS.timezone"];
    [coder encodeInteger:(NSInteger)[self firstWeekday] forKey:@"NS.firstwkdy"];
    [coder encodeInteger:(NSInteger)[self minimumDaysInFirstWeek] forKey:@"NS.mindays"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    NSString *ident = [coder decodeObjectOfClass:[NSString class] forKey:@"NS.identifier"];
    NSCalendar *c = ident ? [self initWithCalendarIdentifier:ident] : nil;
    if (!c) return nil;
    NSLocale *locale = [coder decodeObjectOfClass:[NSLocale class] forKey:@"NS.locale"];
    NSTimeZone *tz = [coder decodeObjectOfClass:[NSTimeZone class] forKey:@"NS.timezone"];
    if (locale) [c setLocale:locale];
    if (tz) [c setTimeZone:tz];
    if ([coder containsValueForKey:@"NS.firstwkdy"]) [c setFirstWeekday:(NSUInteger)[coder decodeIntegerForKey:@"NS.firstwkdy"]];
    if ([coder containsValueForKey:@"NS.mindays"]) [c setMinimumDaysInFirstWeek:(NSUInteger)[coder decodeIntegerForKey:@"NS.mindays"]];
    return c;
}

@end

#define COMPONENT_FIELDS(X) \
    X(era, Era) X(year, Year) X(month, Month) X(day, Day) X(hour, Hour) X(minute, Minute) X(second, Second) \
    X(nanosecond, Nanosecond) X(weekday, Weekday) X(weekdayOrdinal, WeekdayOrdinal) X(quarter, Quarter) \
    X(weekOfMonth, WeekOfMonth) X(weekOfYear, WeekOfYear)

@implementation NSDateComponents (FinchCoding)

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
#define ENCODE(name, Name) \
    if ([self name] != NSDateComponentUndefined) [coder encodeInteger:[self name] forKey:@"NS." #name];
    COMPONENT_FIELDS(ENCODE)
#undef ENCODE
    if ([self yearForWeekOfYear] != NSDateComponentUndefined) [coder encodeInteger:[self yearForWeekOfYear] forKey:@"NS.yearForWOY"];
    [coder encodeInteger:[self isLeapMonth] ? 1 : 0 forKey:@"NS.leapMonth"];
    [coder encodeBool:NO forKey:@"NS.repeatedDay"];
    if ([self calendar]) [coder encodeObject:[self calendar] forKey:@"NS.calendar"];
    if ([self timeZone]) [coder encodeObject:[self timeZone] forKey:@"NS.timezone"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    requires_keyed(coder, self, _cmd);
    if (!(self = [self init])) return nil;
#define DECODE(name, Name) \
    if ([coder containsValueForKey:@"NS." #name]) [self set##Name:[coder decodeIntegerForKey:@"NS." #name]];
    COMPONENT_FIELDS(DECODE)
#undef DECODE
    if ([coder containsValueForKey:@"NS.yearForWOY"]) [self setYearForWeekOfYear:[coder decodeIntegerForKey:@"NS.yearForWOY"]];
    if ([coder decodeIntegerForKey:@"NS.leapMonth"]) [self setLeapMonth:YES];
    NSCalendar *cal = [coder decodeObjectOfClass:[NSCalendar class] forKey:@"NS.calendar"];
    NSTimeZone *tz = [coder decodeObjectOfClass:[NSTimeZone class] forKey:@"NS.timezone"];
    if (cal) [self setCalendar:cal];
    if (tz) [self setTimeZone:tz];
    return self;
}

@end
