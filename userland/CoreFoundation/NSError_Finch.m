/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * __NSCFError: CFError as an NSError (Foundation's class, linked upward),
 * so errors CF makes answer NSError's methods, as Apple's do. Foundation's
 * NSError builds its descriptions on -domain, -code and -userInfo, which
 * this class gets from CF.
 */
#include "CFObjCClasses_Finch.h"

@interface __NSCFError : NSError
@end

@implementation __NSCFError

FINCH_CF_OBJECT_MEMORY

- (NSString *)domain { return (NSString *)CFErrorGetDomain((CFErrorRef)self); }
- (NSInteger)code { return (NSInteger)CFErrorGetCode((CFErrorRef)self); }

- (NSDictionary *)userInfo
{
    CFDictionaryRef info = CFErrorCopyUserInfo((CFErrorRef)self);
    return info ? [(id)info autorelease] : [(id)CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) autorelease];
}

- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }

@end

CF_PRIVATE Class
__CFFinchErrorClass(void)
{
    return [__NSCFError class];
}
