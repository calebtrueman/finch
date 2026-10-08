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

/* Type tests Apple's CoreFoundation adds to NSObject, which each class
 * answers for itself (os_log's %@ formatting asks them, for one). */
@implementation NSObject (FinchCFTypeTests)
- (BOOL)isNSObject__ { return YES; }
- (BOOL)isNSString__ { return NO; }
- (BOOL)isNSCFConstantString__ { return NO; }
- (BOOL)isNSNumber__ { return NO; }
- (BOOL)isNSValue__ { return NO; }
- (BOOL)isNSArray__ { return NO; }
- (BOOL)isNSDictionary__ { return NO; }
- (BOOL)isNSSet__ { return NO; }
- (BOOL)isNSOrderedSet__ { return NO; }
- (BOOL)isNSData__ { return NO; }
- (BOOL)isNSDate__ { return NO; }
- (BOOL)isNSTimeZone__ { return NO; }
- (BOOL)isNSURL__ { return NO; }
@end

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
/* NSString's primitives and fast paths over CFString. The rest of NSString
 * is Foundation's, on these (docs/design/FOUNDATION.md). */
@implementation __NSCFString
- (BOOL)isNSString__ { return YES; }
- (NSUInteger)length { return (NSUInteger)CFStringGetLength((CFStringRef)self); }
- (unichar)characterAtIndex:(NSUInteger)idx
{
    return CFStringGetCharacterAtIndex((CFStringRef)self, (CFIndex)idx);
}
- (void)getCharacters:(unichar *)buffer range:(NSRange)range
{
    CFStringGetCharacters((CFStringRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length), buffer);
}
- (const UniChar *)_fastCharacterContents { return CFStringGetCharactersPtr((CFStringRef)self); }
- (const char *)_fastCStringContents:(BOOL)nullTerminated
{
    return CFStringGetCStringPtr((CFStringRef)self, kCFStringEncodingASCII);
}
- (CFStringEncoding)_fastestEncodingInCFStringEncoding { return CFStringGetFastestEncoding((CFStringRef)self); }
- (CFStringEncoding)_smallestEncodingInCFStringEncoding { return CFStringGetSmallestEncoding((CFStringRef)self); }
- (BOOL)_getCString:(char *)buffer maxLength:(NSUInteger)max encoding:(CFStringEncoding)encoding
{
    return CFStringGetCString((CFStringRef)self, buffer, (CFIndex)max + 1, encoding);
}
- (const char *)UTF8String
{
    const char *fast = CFStringGetCStringPtr((CFStringRef)self, kCFStringEncodingUTF8);
    if (fast) return fast;
    CFIndex n = CFStringGetMaximumSizeForEncoding(CFStringGetLength((CFStringRef)self), kCFStringEncodingUTF8) + 1;
    CFMutableDataRef d = CFDataCreateMutable(NULL, n);
    CFDataSetLength(d, n);
    char *p = (char *)CFDataGetMutableBytePtr(d);
    if (!CFStringGetCString((CFStringRef)self, p, n, kCFStringEncodingUTF8)) p[0] = 0;
    [(id)d autorelease];
    return p;
}
- (id)description { return self; }
- (id)copyWithZone:(struct _NSZone *)zone { return (id)CFStringCreateCopy(NULL, (CFStringRef)self); }
- (id)mutableCopyWithZone:(struct _NSZone *)zone
{
    return (id)CFStringCreateMutableCopy(NULL, 0, (CFStringRef)self);
}
- (BOOL)isEqualToString:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
@end

@interface __NSCFConstantString : __NSCFString
@end
@implementation __NSCFConstantString
- (BOOL)isNSCFConstantString__ { return YES; }
/* Constant strings live for the life of the image. */
- (instancetype)retain { return self; }
- (oneway void)release { }
- (NSUInteger)retainCount { return NSUIntegerMax; }
@end

@interface __NSCFNumber : __NSCFType
@end
@implementation __NSCFNumber
- (BOOL)isNSNumber__ { return YES; }
@end

@interface __NSCFBoolean : __NSCFType
@end
@implementation __NSCFBoolean
- (BOOL)isNSNumber__ { return YES; }
- (instancetype)retain { return self; }
- (oneway void)release { }
- (NSUInteger)retainCount { return NSUIntegerMax; }
@end

@interface NSNull : __NSCFType
+ (NSNull *)null;
@end
@implementation NSNull
+ (NSNull *)null { return (NSNull *)kCFNull; }
- (id)description { return (id)CFSTR("<null>"); }
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

    /* The classes CF hosts for Foundation (NS*_Finch.m). */
    extern Class __CFFinchInitializeArrayClasses(void), __CFFinchInitializeDictionaryClasses(void),
        __CFFinchInitializeSetClasses(void), __CFFinchInitializeDataClasses(void),
        __CFFinchInitializeDateClasses(void);
    extern void __CFFinchInstallExceptionHandler(void), __CFFinchInstallForwardHandler(void);
    set_class(_kCFRuntimeIDCFArray, __CFFinchInitializeArrayClasses());
    set_class(_kCFRuntimeIDCFDictionary, __CFFinchInitializeDictionaryClasses());
    set_class(_kCFRuntimeIDCFSet, __CFFinchInitializeSetClasses());
    set_class(_kCFRuntimeIDCFData, __CFFinchInitializeDataClasses());
    set_class(_kCFRuntimeIDCFDate, __CFFinchInitializeDateClasses());
    __CFFinchInstallExceptionHandler();
    __CFFinchInstallForwardHandler();
}
