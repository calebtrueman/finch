/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSProxy (docs/design/FOUNDATION.md), against the SDK's <Foundation/NSProxy.h>:
 * a root class that implements memory management, -class, -isProxy and
 * -description itself and forwards everything else (including
 * -isKindOfClass: and -respondsToSelector:, as Apple's does) through
 * -methodSignatureForSelector: and -forwardInvocation:, which subclasses
 * implement. Forwarding is CF's (NSInvocation_Finch.m), which libobjc calls
 * for any object.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include "Foundation_Finch.h"

/* libobjc's root-class reference counting. */
id _objc_rootRetain(id obj);
void _objc_rootRelease(id obj);
id _objc_rootAutorelease(id obj);
NSUInteger _objc_rootRetainCount(id obj);
void _objc_rootDealloc(id obj);
BOOL _objc_rootTryRetain(id obj);
BOOL _objc_rootIsDeallocating(id obj);

@implementation NSProxy

+ (void)load { }
+ (void)initialize { }
+ (id)alloc { return [self allocWithZone:NULL]; }
+ (id)allocWithZone:(NSZone *)zone { return class_createInstance(self, 0); }
+ (Class)class { return self; }
+ (BOOL)respondsToSelector:(SEL)aSelector { return class_respondsToSelector(object_getClass((id)self), aSelector); }
+ (NSString *)description { return [NSString stringWithUTF8String:class_getName(self)]; }
+ (NSString *)debugDescription { return [self description]; }
+ (BOOL)isProxy { return NO; }
+ (id)retain { return self; }
+ (oneway void)release { }
+ (id)autorelease { return self; }
+ (NSUInteger)retainCount { return NSUIntegerMax; }
+ (Class)superclass { return class_getSuperclass(self); }
+ (BOOL)conformsToProtocol:(Protocol *)protocol
{
    for (Class c = self; c; c = class_getSuperclass(c))
        if (class_conformsToProtocol(c, protocol)) return YES;
    return NO;
}

- (Class)class { return object_getClass(self); }
- (Class)superclass { return class_getSuperclass(object_getClass(self)); }
- (id)self { return self; }
- (struct _NSZone *)zone { return NULL; }
- (BOOL)isProxy { return YES; }

- (id)retain { return _objc_rootRetain(self); }
- (oneway void)release { _objc_rootRelease(self); }
- (id)autorelease { return _objc_rootAutorelease(self); }
- (NSUInteger)retainCount { return _objc_rootRetainCount(self); }
- (BOOL)_tryRetain { return _objc_rootTryRetain(self); }
- (BOOL)_isDeallocating { return _objc_rootIsDeallocating(self); }
- (BOOL)allowsWeakReference { return !_objc_rootIsDeallocating(self); }
- (BOOL)retainWeakReference { return _objc_rootTryRetain(self); }
- (void)dealloc { _objc_rootDealloc(self); }
- (void)finalize { }

- (NSUInteger)hash { return (NSUInteger)(uintptr_t)self; }
- (BOOL)isEqual:(id)object { return object == self; }

/* Apple's: the real class and the address. */
- (NSString *)description { return [NSString stringWithFormat:@"<%s: %p>", object_getClassName(self), self]; }
- (NSString *)debugDescription { return [self description]; }

- (id)performSelector:(SEL)aSelector { return ((id (*)(id, SEL))objc_msgSend)(self, aSelector); }
- (id)performSelector:(SEL)aSelector withObject:(id)object { return ((id (*)(id, SEL, id))objc_msgSend)(self, aSelector, object); }
- (id)performSelector:(SEL)aSelector withObject:(id)object1 withObject:(id)object2
{
    return ((id (*)(id, SEL, id, id))objc_msgSend)(self, aSelector, object1, object2);
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    FinchRaise(NSInvalidArgumentException, "*** -[NSProxy forwardInvocation:] called!");
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    FinchRaise(NSInvalidArgumentException, "*** -[NSProxy methodSignatureForSelector:] called!");
}

@end
