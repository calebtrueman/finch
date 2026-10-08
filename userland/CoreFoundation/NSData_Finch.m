/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSData and NSMutableData, which Apple's CoreFoundation hosts
 * (docs/design/FOUNDATION.md), with __NSCFData, the class of every CFData.
 * Primitives: -length and -bytes; -mutableBytes and -setLength: for the
 * mutable class. +alloc returns __NSPlaceholderData, which makes CFData.
 * Reading and writing files is Foundation's (a category there).
 */
#include "CFObjCClasses_Finch.h"

@interface NSData () <NSCopying, NSMutableCopying>
+ (instancetype)data;
+ (instancetype)dataWithBytes:(const void *)bytes length:(NSUInteger)length;
+ (instancetype)dataWithBytesNoCopy:(void *)bytes length:(NSUInteger)length;
+ (instancetype)dataWithBytesNoCopy:(void *)bytes length:(NSUInteger)length freeWhenDone:(BOOL)free;
+ (instancetype)dataWithData:(NSData *)data;
- (instancetype)init;
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length;
- (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)length;
- (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)length freeWhenDone:(BOOL)free;
- (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)length deallocator:(void (^)(void *bytes, NSUInteger length))deallocator;
- (instancetype)initWithData:(NSData *)data;
- (void)getBytes:(void *)buffer length:(NSUInteger)length;
- (BOOL)isEqualToData:(NSData *)other;
- (NSData *)subdataWithRange:(NSRange)range;
- (void)enumerateByteRangesUsingBlock:(void (^)(const void *bytes, NSRange range, BOOL *stop))block;
@end

@interface NSMutableData ()
+ (instancetype)dataWithCapacity:(NSUInteger)capacity;
+ (instancetype)dataWithLength:(NSUInteger)length;
- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (instancetype)initWithLength:(NSUInteger)length;
- (void)appendData:(NSData *)data;
- (void)resetBytesInRange:(NSRange)range;
- (void)setData:(NSData *)data;
@end

@interface __NSPlaceholderData : NSMutableData
@end
@interface __NSCFData : NSMutableData
@end

CF_PRIVATE Boolean _CFDataIsMutable(CFDataRef data);   /* CFData.c (patch 0003) */

static __NSPlaceholderData *immutablePlaceholder, *mutablePlaceholder;

CF_PRIVATE Class
__CFFinchInitializeDataClasses(void)
{
    immutablePlaceholder = class_createInstance([__NSPlaceholderData class], 0);
    mutablePlaceholder = class_createInstance([__NSPlaceholderData class], 0);
    return [__NSCFData class];
}

static void
check_range(id self, SEL _cmd, NSRange range, NSUInteger length)
{
    if (range.location > length || range.length > length - range.location)
        __CFFinchRaise(NSRangeException, "*** " FINCH_METHOD_FMT ": range {%lu, %lu} exceeds data length %lu",
            FINCH_METHOD_ARGS, (unsigned long)range.location, (unsigned long)range.length, (unsigned long)length);
}

/* MARK: - NSData */

@implementation NSData

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSData class]) return (id)immutablePlaceholder;
    if (self == [NSMutableData class]) return (id)mutablePlaceholder;
    return [super allocWithZone:zone];
}

+ (instancetype)data { return [[[self alloc] init] autorelease]; }
+ (instancetype)dataWithBytes:(const void *)bytes length:(NSUInteger)length
{
    return [[[self alloc] initWithBytes:bytes length:length] autorelease];
}
+ (instancetype)dataWithBytesNoCopy:(void *)bytes length:(NSUInteger)length
{
    return [[[self alloc] initWithBytesNoCopy:bytes length:length] autorelease];
}
+ (instancetype)dataWithBytesNoCopy:(void *)bytes length:(NSUInteger)length freeWhenDone:(BOOL)f
{
    return [[[self alloc] initWithBytesNoCopy:bytes length:length freeWhenDone:f] autorelease];
}
+ (instancetype)dataWithData:(NSData *)data { return [[[self alloc] initWithData:data] autorelease]; }

- (instancetype)init { return [super init]; }
/* For subclasses: the abstract class stores nothing. */
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length { return [self init]; }
- (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)length
{
    return [self initWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}
- (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)length freeWhenDone:(BOOL)f
{
    id result = [self initWithBytes:bytes length:length];
    if (f) free(bytes);
    return result;
}
- (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)length deallocator:(void (^)(void *, NSUInteger))d
{
    id result = [self initWithBytes:bytes length:length];
    if (d) d(bytes, length);
    return result;
}
- (instancetype)initWithData:(NSData *)data { return [self initWithBytes:[data bytes] length:[data length]]; }

#define ABSTRACT(sig, name) \
    sig { __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s " name "]!", \
        FINCH_METHOD_ARGS, object_getClassName(self)); }
ABSTRACT(- (NSUInteger)length, "length")
ABSTRACT(- (const void *)bytes, "bytes")
#undef ABSTRACT

- (void)getBytes:(void *)buffer length:(NSUInteger)length
{
    NSUInteger n = [self length];
    memcpy(buffer, [self bytes], length < n ? length : n);
}

- (void)getBytes:(void *)buffer range:(NSRange)range
{
    check_range(self, _cmd, range, [self length]);
    memcpy(buffer, (const char *)[self bytes] + range.location, range.length);
}

- (BOOL)isEqualToData:(NSData *)other
{
    if (other == self) return YES;
    NSUInteger n = [self length];
    return [other length] == n && memcmp([self bytes], [other bytes], n) == 0;
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    return other && [other isKindOfClass:[NSData class]] && [self isEqualToData:other];
}

- (NSUInteger)hash
{
    return (NSUInteger)CFHashBytes((UInt8 *)[self bytes], (CFIndex)([self length] < 80 ? [self length] : 80));
}

- (NSData *)subdataWithRange:(NSRange)range
{
    check_range(self, _cmd, range, [self length]);
    return [NSData dataWithBytes:(const char *)[self bytes] + range.location length:range.length];
}

- (void)enumerateByteRangesUsingBlock:(void (^)(const void *, NSRange, BOOL *))block
{
    BOOL stop = NO;
    block([self bytes], NSMakeRange(0, [self length]), &stop);
}

- (id)copyWithZone:(struct _NSZone *)zone { return [[NSData alloc] initWithData:self]; }
- (id)mutableCopyWithZone:(struct _NSZone *)zone { return [[NSMutableData alloc] initWithData:self]; }

/* "{length = 5, bytes = 0x0102abcdef}", with the middle elided past 24 bytes
 * as Apple's does: "{length = 100, bytes = 0x00010203 ... 5c5d5e5f }". */
- (id)description
{
    NSUInteger n = [self length];
    const unsigned char *p = [self bytes];
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    CFStringAppendFormat(s, NULL, CFSTR("{length = %lu, bytes = 0x"), (unsigned long)n);
    if (n <= 24) {
        for (NSUInteger i = 0; i < n; i++) CFStringAppendFormat(s, NULL, CFSTR("%02x"), p[i]);
        CFStringAppend(s, CFSTR("}"));
    } else {
        for (NSUInteger i = 0; i < 8; i++) CFStringAppendFormat(s, NULL, CFSTR("%02x"), p[i]);
        CFStringAppend(s, CFSTR(" ... "));
        for (NSUInteger i = n - 8; i < n; i++) CFStringAppendFormat(s, NULL, CFSTR("%02x"), p[i]);
        CFStringAppend(s, CFSTR(" }"));
    }
    return [(id)s autorelease];
}

- (CFTypeID)_cfTypeID { return CFDataGetTypeID(); }
- (BOOL)isNSData__ { return YES; }

@end

/* MARK: - NSMutableData */

@implementation NSMutableData

+ (instancetype)dataWithCapacity:(NSUInteger)capacity { return [[[self alloc] initWithCapacity:capacity] autorelease]; }
+ (instancetype)dataWithLength:(NSUInteger)length { return [[[self alloc] initWithLength:length] autorelease]; }
- (instancetype)initWithCapacity:(NSUInteger)capacity { return [self init]; }
- (instancetype)initWithLength:(NSUInteger)length
{
    if ((self = [self initWithCapacity:length])) [self setLength:length];
    return self;
}

#define ABSTRACT(sig, name) \
    sig { __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s " name "]!", \
        FINCH_METHOD_ARGS, object_getClassName(self)); }
ABSTRACT(- (void *)mutableBytes, "mutableBytes")
ABSTRACT(- (void)setLength:(NSUInteger)length, "setLength:")
#undef ABSTRACT

- (const void *)bytes { return [self mutableBytes]; }
- (void)increaseLengthBy:(NSUInteger)extra { [self setLength:[self length] + extra]; }

- (void)appendBytes:(const void *)bytes length:(NSUInteger)length
{
    NSUInteger n = [self length];
    [self setLength:n + length];
    memmove((char *)[self mutableBytes] + n, bytes, length);
}

- (void)appendData:(NSData *)data { [self appendBytes:[data bytes] length:[data length]]; }

- (void)replaceBytesInRange:(NSRange)range withBytes:(const void *)bytes length:(NSUInteger)length
{
    NSUInteger n = [self length];
    check_range(self, _cmd, range, n);
    if (length != range.length) {
        if (length > range.length) [self setLength:n + length - range.length];
        char *p = [self mutableBytes];
        memmove(p + range.location + length, p + range.location + range.length, n - range.location - range.length);
        if (length < range.length) [self setLength:n - (range.length - length)];
    }
    if (bytes) memmove((char *)[self mutableBytes] + range.location, bytes, length);
    else memset((char *)[self mutableBytes] + range.location, 0, length);
}

- (void)replaceBytesInRange:(NSRange)range withBytes:(const void *)bytes
{
    [self replaceBytesInRange:range withBytes:bytes length:range.length];
}

- (void)resetBytesInRange:(NSRange)range
{
    check_range(self, _cmd, range, [self length]);
    memset((char *)[self mutableBytes] + range.location, 0, range.length);
}

- (void)setData:(NSData *)data
{
    [data retain];
    [self setLength:0];
    [self appendData:data];
    [data release];
}

- (id)copyWithZone:(struct _NSZone *)zone { return [[NSData alloc] initWithData:self]; }

@end

/* MARK: - __NSPlaceholderData */

@implementation __NSPlaceholderData

FINCH_IMMORTAL_MEMORY

- (instancetype)init { return [self initWithBytes:NULL length:0]; }

- (instancetype)initWithCapacity:(NSUInteger)capacity { return (id)CFDataCreateMutable(NULL, 0); }

- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length
{
    if (self != mutablePlaceholder) return (id)CFDataCreate(NULL, bytes, (CFIndex)length);
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    if (length) CFDataAppendBytes(d, bytes, (CFIndex)length);
    return (id)d;
}

- (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)length freeWhenDone:(BOOL)f
{
    if (self == mutablePlaceholder) {
        id result = [self initWithBytes:bytes length:length];
        if (f) free(bytes);
        return result;
    }
    return (id)CFDataCreateWithBytesNoCopy(NULL, bytes, (CFIndex)length, f ? kCFAllocatorMalloc : kCFAllocatorNull);
}

- (NSUInteger)length { return 0; }

@end

/* MARK: - __NSCFData */

@implementation __NSCFData

FINCH_CF_OBJECT_MEMORY

/* Instances are CF objects: [[obj class] alloc] goes through the placeholder. */
+ (instancetype)allocWithZone:(struct _NSZone *)zone { return (id)mutablePlaceholder; }

- (NSUInteger)length { return (NSUInteger)CFDataGetLength((CFDataRef)self); }
- (const void *)bytes { return CFDataGetBytePtr((CFDataRef)self); }

- (void)getBytes:(void *)buffer range:(NSRange)range
{
    check_range(self, _cmd, range, (NSUInteger)CFDataGetLength((CFDataRef)self));
    CFDataGetBytes((CFDataRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length), buffer);
}

- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }

static BOOL
is_mutable(id self)
{
    return _CFDataIsMutable((CFDataRef)self);
}

- (Class)classForCoder { return is_mutable(self) ? [NSMutableData class] : [NSData class]; }

- (id)copyWithZone:(struct _NSZone *)zone
{
    if (!is_mutable(self)) return [self retain];
    return (id)CFDataCreateCopy(NULL, (CFDataRef)self);
}

- (id)mutableCopyWithZone:(struct _NSZone *)zone { return (id)CFDataCreateMutableCopy(NULL, 0, (CFDataRef)self); }

static void
check_mutable(id self, SEL _cmd)
{
    if (!is_mutable(self))
        __CFFinchRaise(NSInternalInconsistencyException, FINCH_METHOD_FMT ": mutating method sent to immutable object",
            FINCH_METHOD_ARGS);
}

- (void *)mutableBytes { check_mutable(self, _cmd); return CFDataGetMutableBytePtr((CFMutableDataRef)self); }
- (void)setLength:(NSUInteger)length { check_mutable(self, _cmd); CFDataSetLength((CFMutableDataRef)self, (CFIndex)length); }
- (void)increaseLengthBy:(NSUInteger)extra
{
    check_mutable(self, _cmd);
    CFDataIncreaseLength((CFMutableDataRef)self, (CFIndex)extra);
}
- (void)appendBytes:(const void *)bytes length:(NSUInteger)length
{
    check_mutable(self, _cmd);
    CFDataAppendBytes((CFMutableDataRef)self, bytes, (CFIndex)length);
}

- (void)replaceBytesInRange:(NSRange)range withBytes:(const void *)bytes length:(NSUInteger)length
{
    check_mutable(self, _cmd);
    check_range(self, _cmd, range, (NSUInteger)CFDataGetLength((CFDataRef)self));
    if (bytes) {
        CFDataReplaceBytes((CFMutableDataRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length), bytes, (CFIndex)length);
    } else {
        void *zeros = calloc(1, length ? length : 1);
        CFDataReplaceBytes((CFMutableDataRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length), zeros, (CFIndex)length);
        free(zeros);
    }
}

@end
