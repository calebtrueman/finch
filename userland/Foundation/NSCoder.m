/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSCoder, the abstract coder (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSCoder.h>, and NSObject's coding hooks (classForCoder and
 * friends). Concrete coders implement the primitives; everything else here
 * is built from them, as Apple's is: typed keyed methods from the 64-bit
 * ones, secure decoding from -decodeObjectOfClasses:forKey:, geometry as
 * strings ("{1, 2}") under keys.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

@implementation NSCoder

/* MARK: Primitives (subclasses) */

- (void)encodeValueOfObjCType:(const char *)type at:(const void *)addr { FinchAbstract(self, _cmd); }
- (void)encodeDataObject:(NSData *)data { FinchAbstract(self, _cmd); }
- (NSData *)decodeDataObject { FinchAbstract(self, _cmd); }
- (void)decodeValueOfObjCType:(const char *)type at:(void *)data size:(NSUInteger)size { FinchAbstract(self, _cmd); }
- (NSInteger)versionForClassName:(NSString *)className { FinchAbstract(self, _cmd); }
- (void)decodeValueOfObjCType:(const char *)type at:(void *)data
{
    NSUInteger size;
    NSGetSizeAndAlignment(type, &size, NULL);
    [self decodeValueOfObjCType:type at:data size:size];
}

/* MARK: Unkeyed, from the primitives */

- (void)encodeObject:(id)object { [self encodeValueOfObjCType:@encode(id) at:&object]; }
- (void)encodeRootObject:(id)rootObject { [self encodeObject:rootObject]; }
- (void)encodeBycopyObject:(id)anObject { [self encodeObject:anObject]; }
- (void)encodeByrefObject:(id)anObject { [self encodeObject:anObject]; }
- (void)encodeConditionalObject:(id)object { [self encodeObject:object]; }

- (id)decodeObject
{
    id o = nil;
    [self decodeValueOfObjCType:@encode(id) at:&o size:sizeof(o)];
    return [o autorelease];
}

- (id)decodeTopLevelObjectAndReturnError:(NSError **)error
{
    @try {
        return [self decodeObject];
    } @catch (NSException *e) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError
            userInfo:@{ NSDebugDescriptionErrorKey: [e reason] ? [e reason] : @"" }];
        return nil;
    }
}

- (void)encodeValuesOfObjCTypes:(const char *)types, ...
{
    va_list ap;
    va_start(ap, types);
    for (const char *t = types; *t; t = NSGetSizeAndAlignment(t, NULL, NULL))
        [self encodeValueOfObjCType:t at:va_arg(ap, void *)];
    va_end(ap);
}

- (void)decodeValuesOfObjCTypes:(const char *)types, ...
{
    va_list ap;
    va_start(ap, types);
    for (const char *t = types; *t; t = NSGetSizeAndAlignment(t, NULL, NULL))
        [self decodeValueOfObjCType:t at:va_arg(ap, void *)];
    va_end(ap);
}

- (void)encodeArrayOfObjCType:(const char *)type count:(NSUInteger)count at:(const void *)array
{
    NSUInteger size;
    NSGetSizeAndAlignment(type, &size, NULL);
    for (NSUInteger i = 0; i < count; i++) [self encodeValueOfObjCType:type at:(const char *)array + i * size];
}

- (void)decodeArrayOfObjCType:(const char *)itemType count:(NSUInteger)count at:(void *)array
{
    NSUInteger size;
    NSGetSizeAndAlignment(itemType, &size, NULL);
    for (NSUInteger i = 0; i < count; i++) [self decodeValueOfObjCType:itemType at:(char *)array + i * size size:size];
}

- (void)encodeBytes:(const void *)byteaddr length:(NSUInteger)length
{
    unsigned int n = (unsigned int)length;
    [self encodeValueOfObjCType:@encode(unsigned int) at:&n];
    [self encodeArrayOfObjCType:@encode(char) count:length at:byteaddr];
}

- (void *)decodeBytesWithReturnedLength:(NSUInteger *)lengthp
{
    unsigned int n = 0;
    [self decodeValueOfObjCType:@encode(unsigned int) at:&n size:sizeof(n)];
    NSMutableData *d = [NSMutableData dataWithLength:n];
    [self decodeArrayOfObjCType:@encode(char) count:n at:[d mutableBytes]];
    if (lengthp) *lengthp = n;
    return [d mutableBytes];
}

- (void *)decodeBytesWithMinimumLength:(NSUInteger)length
{
    NSUInteger n = 0;
    void *b = [self decodeBytesWithReturnedLength:&n];
    return n >= length ? b : NULL;
}

- (void)encodePropertyList:(id)aPropertyList { [self encodeObject:aPropertyList]; }
- (id)decodePropertyList { return [self decodeObject]; }
- (void)setObjectZone:(NSZone *)zone { }
- (NSZone *)objectZone { return NULL; }
- (unsigned int)systemVersion { return 1000; }

/* MARK: Keyed */

- (BOOL)allowsKeyedCoding { return NO; }

#define KEYED_ONLY \
    FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: this method can only be called by subclasses that support keyed coding", \
        object_getClassName(self), sel_getName(_cmd))

- (void)encodeObject:(id)object forKey:(NSString *)key { KEYED_ONLY; }
- (void)encodeConditionalObject:(id)object forKey:(NSString *)key { [self encodeObject:object forKey:key]; }
- (void)encodeBool:(BOOL)value forKey:(NSString *)key { KEYED_ONLY; }
- (void)encodeInt:(int)value forKey:(NSString *)key { [self encodeInt64:value forKey:key]; }
- (void)encodeInt32:(int32_t)value forKey:(NSString *)key { [self encodeInt64:value forKey:key]; }
- (void)encodeInt64:(int64_t)value forKey:(NSString *)key { KEYED_ONLY; }
- (void)encodeInteger:(NSInteger)value forKey:(NSString *)key { [self encodeInt64:value forKey:key]; }
- (void)encodeFloat:(float)value forKey:(NSString *)key { [self encodeDouble:value forKey:key]; }
- (void)encodeDouble:(double)value forKey:(NSString *)key { KEYED_ONLY; }
- (void)encodeBytes:(const uint8_t *)bytes length:(NSUInteger)length forKey:(NSString *)key { KEYED_ONLY; }

- (BOOL)containsValueForKey:(NSString *)key { KEYED_ONLY; }
- (id)decodeObjectForKey:(NSString *)key { KEYED_ONLY; }
- (BOOL)decodeBoolForKey:(NSString *)key { KEYED_ONLY; }
- (int)decodeIntForKey:(NSString *)key { return (int)[self decodeInt64ForKey:key]; }
- (int32_t)decodeInt32ForKey:(NSString *)key { return (int32_t)[self decodeInt64ForKey:key]; }
- (int64_t)decodeInt64ForKey:(NSString *)key { KEYED_ONLY; }
- (NSInteger)decodeIntegerForKey:(NSString *)key { return (NSInteger)[self decodeInt64ForKey:key]; }
- (float)decodeFloatForKey:(NSString *)key { return (float)[self decodeDoubleForKey:key]; }
- (double)decodeDoubleForKey:(NSString *)key { KEYED_ONLY; }
- (const uint8_t *)decodeBytesForKey:(NSString *)key returnedLength:(NSUInteger *)lengthp { KEYED_ONLY; }

- (const uint8_t *)decodeBytesForKey:(NSString *)key minimumLength:(NSUInteger)length
{
    NSUInteger n = 0;
    const uint8_t *b = [self decodeBytesForKey:key returnedLength:&n];
    return b && n >= length ? b : NULL;
}

- (id)decodeTopLevelObjectForKey:(NSString *)key error:(NSError **)error
{
    return [self decodeTopLevelObjectOfClasses:nil forKey:key error:error];
}

/* MARK: Secure coding */

- (BOOL)requiresSecureCoding { return NO; }
- (NSSet *)allowedClasses { return nil; }
- (NSDecodingFailurePolicy)decodingFailurePolicy { return NSDecodingFailurePolicyRaiseException; }
- (NSError *)error { return nil; }

- (void)failWithError:(NSError *)error
{
    FinchRaise(NSInvalidUnarchiveOperationException, "%s", [[error description] UTF8String]);
}

- (id)decodeObjectOfClass:(Class)aClass forKey:(NSString *)key
{
    return [self decodeObjectOfClasses:aClass ? [NSSet setWithObject:aClass] : nil forKey:key];
}

- (id)decodeObjectOfClasses:(NSSet *)classes forKey:(NSString *)key { return [self decodeObjectForKey:key]; }

- (id)decodeTopLevelObjectOfClass:(Class)aClass forKey:(NSString *)key error:(NSError **)error
{
    return [self decodeTopLevelObjectOfClasses:aClass ? [NSSet setWithObject:aClass] : nil forKey:key error:error];
}

- (id)decodeTopLevelObjectOfClasses:(NSSet *)classes forKey:(NSString *)key error:(NSError **)error
{
    if (error) *error = nil;
    @try {
        id o = classes ? [self decodeObjectOfClasses:classes forKey:key] : [self decodeObjectForKey:key];
        if (!o && error) *error = [self error];
        return o;
    } @catch (NSException *e) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError
            userInfo:@{ NSDebugDescriptionErrorKey: [e reason] ? [e reason] : @"" }];
        return nil;
    }
}

static BOOL
all_kind_of(id<NSFastEnumeration> objects, NSSet *classes)
{
    for (id o in objects) {
        BOOL ok = NO;
        for (Class c in classes) if ([o isKindOfClass:c]) { ok = YES; break; }
        if (!ok) return NO;
    }
    return YES;
}

- (NSArray *)decodeArrayOfObjectsOfClass:(Class)cls forKey:(NSString *)key
{
    return [self decodeArrayOfObjectsOfClasses:[NSSet setWithObject:cls] forKey:key];
}

- (NSArray *)decodeArrayOfObjectsOfClasses:(NSSet *)classes forKey:(NSString *)key
{
    NSArray *a = [self decodeObjectOfClasses:[classes setByAddingObject:[NSArray class]] forKey:key];
    if (a && (![a isKindOfClass:[NSArray class]] || !all_kind_of(a, classes))) return nil;
    return a;
}

- (NSDictionary *)decodeDictionaryWithKeysOfClass:(Class)keyCls objectsOfClass:(Class)objectCls forKey:(NSString *)key
{
    return [self decodeDictionaryWithKeysOfClasses:[NSSet setWithObject:keyCls] objectsOfClasses:[NSSet setWithObject:objectCls] forKey:key];
}

- (NSDictionary *)decodeDictionaryWithKeysOfClasses:(NSSet *)keyClasses objectsOfClasses:(NSSet *)objectClasses forKey:(NSString *)key
{
    NSSet *all = [[keyClasses setByAddingObjectsFromSet:objectClasses] setByAddingObject:[NSDictionary class]];
    NSDictionary *d = [self decodeObjectOfClasses:all forKey:key];
    if (d && (![d isKindOfClass:[NSDictionary class]] || !all_kind_of([d allKeys], keyClasses) || !all_kind_of([d allValues], objectClasses)))
        return nil;
    return d;
}

- (id)decodePropertyListForKey:(NSString *)key
{
    NSSet *plist = [NSSet setWithObjects:[NSArray class], [NSDictionary class], [NSString class], [NSNumber class], [NSDate class], [NSData class], nil];
    return [self decodeObjectOfClasses:plist forKey:key];
}

/* MARK: Finch's archiver hooks (Foundation_Finch.h), for other coders */

- (void)_finchEncodePlist:(id)value forKey:(NSString *)key { [self encodeObject:value forKey:key]; }
- (void)_finchEncodeArrayOfObjects:(NSArray *)objects forKey:(NSString *)key { [self encodeObject:objects forKey:key]; }
- (NSArray *)_finchDecodeArrayOfObjectsForKey:(NSString *)key { return [self decodeObjectForKey:key]; }

@end

/* MARK: - Geometry */

@implementation NSCoder (NSGeometryCoding)
- (void)encodePoint:(NSPoint)point { [self encodeValueOfObjCType:@encode(NSPoint) at:&point]; }
- (NSPoint)decodePoint { NSPoint p; [self decodeValueOfObjCType:@encode(NSPoint) at:&p size:sizeof(p)]; return p; }
- (void)encodeSize:(NSSize)size { [self encodeValueOfObjCType:@encode(NSSize) at:&size]; }
- (NSSize)decodeSize { NSSize s; [self decodeValueOfObjCType:@encode(NSSize) at:&s size:sizeof(s)]; return s; }
- (void)encodeRect:(NSRect)rect { [self encodeValueOfObjCType:@encode(NSRect) at:&rect]; }
- (NSRect)decodeRect { NSRect r; [self decodeValueOfObjCType:@encode(NSRect) at:&r size:sizeof(r)]; return r; }
@end

@implementation NSCoder (NSGeometryKeyedCoding)
- (void)encodePoint:(NSPoint)point forKey:(NSString *)key { [self encodeObject:NSStringFromPoint(point) forKey:key]; }
- (void)encodeSize:(NSSize)size forKey:(NSString *)key { [self encodeObject:NSStringFromSize(size) forKey:key]; }
- (void)encodeRect:(NSRect)rect forKey:(NSString *)key { [self encodeObject:NSStringFromRect(rect) forKey:key]; }
- (NSPoint)decodePointForKey:(NSString *)key { return NSPointFromString([self decodeObjectOfClass:[NSString class] forKey:key]); }
- (NSSize)decodeSizeForKey:(NSString *)key { return NSSizeFromString([self decodeObjectOfClass:[NSString class] forKey:key]); }
- (NSRect)decodeRectForKey:(NSString *)key { return NSRectFromString([self decodeObjectOfClass:[NSString class] forKey:key]); }
@end

/* MARK: - NSObject's coding hooks */

static CFMutableDictionaryRef versions;

@implementation NSObject (NSCoderMethods)

+ (NSInteger)version
{
    return versions ? (NSInteger)(intptr_t)CFDictionaryGetValue(versions, (const void *)self) : 0;
}

+ (void)setVersion:(NSInteger)aVersion
{
    if (!versions) versions = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    CFDictionarySetValue(versions, (const void *)self, (const void *)(intptr_t)aVersion);
}

- (Class)classForCoder { return [self class]; }
- (id)replacementObjectForCoder:(NSCoder *)coder { return self; }
- (id)awakeAfterUsingCoder:(NSCoder *)coder { return self; }

@end

@implementation NSObject (NSKeyedArchiverObjectSubstitution)
- (Class)classForKeyedArchiver { return [self classForCoder]; }
- (id)replacementObjectForKeyedArchiver:(NSKeyedArchiver *)archiver { return [self replacementObjectForCoder:archiver]; }
+ (NSArray<NSString *> *)classFallbacksForKeyedArchiver { return nil; }
@end

@implementation NSObject (NSKeyedUnarchiverObjectSubstitution)
+ (Class)classForKeyedUnarchiver { return self; }
@end
