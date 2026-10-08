/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSUUID (docs/design/FOUNDATION.md), against the SDK's <Foundation/NSUUID.h>,
 * over libSystem's uuid functions. NSUUID is abstract; __NSConcreteUUID,
 * Apple's name, holds the bytes. The description is the uppercase string.
 */
#import <Foundation/Foundation.h>
#include <uuid/uuid.h>

#include "Foundation_Finch.h"

@interface __NSConcreteUUID : NSUUID {
    uuid_t _bytes;
}
@end

@implementation NSUUID

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSUUID class]) return [__NSConcreteUUID allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (instancetype)UUID { return [[[self alloc] init] autorelease]; }

- (void)getUUIDBytes:(uuid_t)uuid { FinchAbstract(self, _cmd); }

- (NSString *)UUIDString
{
    uuid_t b;
    uuid_string_t s;
    [self getUUIDBytes:b];
    uuid_unparse_upper(b, s);
    return [NSString stringWithUTF8String:s];
}

- (NSString *)description { return [self UUIDString]; }
- (NSString *)debugDescription { return [NSString stringWithFormat:@"<%s %p> %@", object_getClassName(self), self, [self UUIDString]]; }

- (NSComparisonResult)compare:(NSUUID *)other
{
    uuid_t a, b;
    [self getUUIDBytes:a];
    [other getUUIDBytes:b];
    int c = memcmp(a, b, sizeof(uuid_t));
    return c < 0 ? NSOrderedAscending : c > 0 ? NSOrderedDescending : NSOrderedSame;
}

- (BOOL)isEqual:(id)other
{
    return other == self || ([other isKindOfClass:[NSUUID class]] && [self compare:other] == NSOrderedSame);
}

- (NSUInteger)hash
{
    uuid_t b;
    [self getUUIDBytes:b];
    NSUInteger h = 0;
    for (int i = 0; i < 16; i++) h = h * 31 + b[i];
    return h;
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    uuid_t b;
    [self getUUIDBytes:b];
    [coder encodeBytes:b length:sizeof(b) forKey:@"NS.uuidbytes"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSUInteger n = 0;
    const uint8_t *b = [coder decodeBytesForKey:@"NS.uuidbytes" returnedLength:&n];
    if (!b || n != sizeof(uuid_t)) { [self release]; return nil; }
    return [self initWithUUIDBytes:b];
}

@end

@implementation __NSConcreteUUID

- (instancetype)init
{
    if ((self = [super init])) uuid_generate_random(_bytes);
    return self;
}

- (instancetype)initWithUUIDString:(NSString *)string
{
    if ((self = [super init])) {
        const char *s = [string UTF8String];
        if (!s || strlen(s) != 36 || uuid_parse(s, _bytes) != 0) { [self release]; return nil; }
    }
    return self;
}

- (instancetype)initWithUUIDBytes:(const uuid_t)bytes
{
    if ((self = [super init])) {
        if (bytes) memcpy(_bytes, bytes, sizeof(uuid_t));
    }
    return self;
}

- (void)getUUIDBytes:(uuid_t)uuid { memcpy(uuid, _bytes, sizeof(uuid_t)); }

@end
