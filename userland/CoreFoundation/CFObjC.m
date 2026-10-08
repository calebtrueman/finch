/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CoreFoundation's Objective-C classes (docs/design/COREFOUNDATION.md).
 *
 * Every CF object is an Objective-C object: its isa (CFRuntimeBase._cfisa,
 * signed with objc's isa schema on arm64e) is the class registered for its
 * type in CF's class table. These are the classes Apple's CoreFoundation
 * uses for that, with the same names, so ObjC code can message, retain and
 * release CF objects (and ARC can manage them):
 *
 *   __NSCFType             any CF type without a class of its own
 *   __NSCFString           CFString (and __NSCFConstantString, CFSTR's class,
 *                          which ___CFConstantStringClassReference aliases)
 *   __NSCFNumber           CFNumber
 *   __NSCFBoolean          CFBoolean (kCFBooleanTrue/False)
 *   NSNull                 CFNull (kCFNull)
 *
 * Each forwards memory management, equality, hashing and description to CF.
 * Apple's __NSCFString and __NSCFBoolean subclass Foundation's
 * NSMutableString and NSNumber; Finch has no Foundation yet, so these
 * subclass NSObject until it does.
 *
 * The ObjC-to-CF direction (an NSArray created in ObjC passed to
 * CFArrayGetCount) is the next step: CF_IS_OBJC dispatch.
 *
 * Built without ARC: these classes implement retain and release.
 */

#include "CFInternal.h"
#include "CFRuntime_Internal.h"

#import <objc/NSObject.h>
#import <objc/runtime.h>

@interface __NSCFType : NSObject
@end

@implementation __NSCFType

- (instancetype)retain { return (id)CFRetain((CFTypeRef)self); }
- (oneway void)release { CFRelease((CFTypeRef)self); }
- (NSUInteger)retainCount { return (NSUInteger)CFGetRetainCount((CFTypeRef)self); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }
- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (CFTypeID)_cfTypeID { return CFGetTypeID((CFTypeRef)self); }

/* Weak references: objc asks classes with custom retain/release. */
- (BOOL)_tryRetain { return _CFTryRetain((CFTypeRef)self) != NULL; }
- (BOOL)_isDeallocating { return _CFIsDeallocating((CFTypeRef)self); }
- (BOOL)allowsWeakReference { return !_CFIsDeallocating((CFTypeRef)self); }
- (BOOL)retainWeakReference { return _CFTryRetain((CFTypeRef)self) != NULL; }

- (id)description { return [(id)CFCopyDescription((CFTypeRef)self) autorelease]; }
- (id)debugDescription { return [self description]; }

/* CF frees its objects itself (CFRelease); ObjC never deallocates them. */
- (void)dealloc { }

@end

@interface __NSCFString : __NSCFType
@end
@implementation __NSCFString
@end

@interface __NSCFConstantString : __NSCFString
@end
@implementation __NSCFConstantString
/* Constant strings live for the life of the image. */
- (instancetype)retain { return self; }
- (oneway void)release { }
- (NSUInteger)retainCount { return NSUIntegerMax; }
@end

@interface __NSCFNumber : __NSCFType
@end
@implementation __NSCFNumber
@end

@interface __NSCFBoolean : __NSCFType
@end
@implementation __NSCFBoolean
- (instancetype)retain { return self; }
- (oneway void)release { }
- (NSUInteger)retainCount { return NSUIntegerMax; }
@end

@interface NSNull : __NSCFType
+ (NSNull *)null;
@end
@implementation NSNull
+ (NSNull *)null { return (NSNull *)kCFNull; }
- (instancetype)retain { return self; }
- (oneway void)release { }
- (NSUInteger)retainCount { return NSUIntegerMax; }
@end

/* Store `cls` in the class-table slot for `type`, signed as CF reads it
 * back (_GetCFRuntimeObjcClassAtIndex). */
static void
set_class(CFTypeID type, Class cls)
{
    uintptr_t value = (uintptr_t)cls;
#if __has_feature(ptrauth_intrinsics)
    void const *const slot = &__CFRuntimeObjCClassTable[type];
    value = (uintptr_t)ptrauth_sign_unauthenticated((void *)value, ptrauth_key_process_dependent_data,
        ___CFRUNTIME_OBJC_CLASSTABLE_PTRAUTH_DISCRIMINATOR(slot));
#endif
    atomic_store_explicit(&__CFRuntimeObjCClassTable[type], value, memory_order_relaxed);
}

/* Called first thing in __CFInitialize (patches/), before any CF object is
 * made: every type gets __NSCFType, then the types with classes of their own. */
CF_PRIVATE void
__CFFinchInitializeObjC(void)
{
    Class generic = [__NSCFType class];
    for (CFTypeID type = 0; type < __CFRuntimeClassTableSize; type++) {
        set_class(type, generic);
    }
    set_class(_kCFRuntimeIDCFString, [__NSCFString class]);
    set_class(_kCFRuntimeIDCFNumber, [__NSCFNumber class]);
    set_class(_kCFRuntimeIDCFBoolean, [__NSCFBoolean class]);
    set_class(_kCFRuntimeIDCFNull, [NSNull class]);
}
