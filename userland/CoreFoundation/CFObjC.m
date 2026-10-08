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
#include "CFObjCClasses_Finch.h"

CF_EXPORT Boolean __CFStringIsMutable(CFStringRef str);

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

/* CFString as an NSMutableString (Foundation's class, linked upward as
 * Apple's CF does). NSString's primitives, its fast paths, and mutation,
 * over CF; Foundation's NSString methods do the rest through CF too. */
@interface __NSCFString : NSMutableString
@end
@implementation __NSCFString
FINCH_CF_OBJECT_MEMORY
- (Class)classForCoder { return objc_getClass(__CFStringIsMutable((CFStringRef)self) ? "NSMutableString" : "NSString"); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }
- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (BOOL)isEqualToString:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (BOOL)isNSString__ { return YES; }
- (NSUInteger)length { return (NSUInteger)CFStringGetLength((CFStringRef)self); }
- (unichar)characterAtIndex:(NSUInteger)idx
{
    CFIndex n = CFStringGetLength((CFStringRef)self);
    if (idx >= (NSUInteger)n)
        __CFFinchRaise(NSRangeException, "-[__NSCFString characterAtIndex:]: Range or index out of bounds");
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
- (id)description { return self; }
- (id)copyWithZone:(struct _NSZone *)zone
{
    if (!__CFStringIsMutable((CFStringRef)self)) return (id)CFRetain((CFTypeRef)self);
    return (id)CFStringCreateCopy(NULL, (CFStringRef)self);
}
- (id)mutableCopyWithZone:(struct _NSZone *)zone
{
    return (id)CFStringCreateMutableCopy(NULL, 0, (CFStringRef)self);
}

static void
check_mutable(id self, SEL _cmd)
{
    if (!__CFStringIsMutable((CFStringRef)self))
        __CFFinchRaise(NSInvalidArgumentException, "Attempt to mutate immutable object with %s", sel_getName(_cmd));
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string
{
    check_mutable(self, _cmd);
    CFIndex n = CFStringGetLength((CFStringRef)self);
    if (range.location > (NSUInteger)n || range.length > (NSUInteger)n - range.location)
        __CFFinchRaise(NSRangeException, "-[__NSCFString replaceCharactersInRange:withString:]: Range or index out of bounds");
    CFStringReplace((CFMutableStringRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length),
        string ? (CFStringRef)string : CFSTR(""));
}
- (void)appendString:(NSString *)string
{
    check_mutable(self, _cmd);
    if (!string) __CFFinchRaise(NSInvalidArgumentException, "-[__NSCFString appendString:]: nil argument");
    CFStringAppend((CFMutableStringRef)self, (CFStringRef)string);
}
- (void)appendCharacters:(const unichar *)chars length:(NSUInteger)length
{
    check_mutable(self, _cmd);
    CFStringAppendCharacters((CFMutableStringRef)self, chars, (CFIndex)length);
}
- (void)insertString:(NSString *)string atIndex:(NSUInteger)idx
{
    check_mutable(self, _cmd);
    if (idx > (NSUInteger)CFStringGetLength((CFStringRef)self))
        __CFFinchRaise(NSRangeException, "-[__NSCFString insertString:atIndex:]: Range or index out of bounds");
    CFStringInsert((CFMutableStringRef)self, (CFIndex)idx, (CFStringRef)string);
}
- (void)deleteCharactersInRange:(NSRange)range { [self replaceCharactersInRange:range withString:(NSString *)CFSTR("")]; }
- (void)setString:(NSString *)string
{
    check_mutable(self, _cmd);
    CFStringReplaceAll((CFMutableStringRef)self, string ? (CFStringRef)string : CFSTR(""));
}
@end

@interface __NSCFConstantString : __NSCFString
@end
@implementation __NSCFConstantString
- (BOOL)isNSCFConstantString__ { return YES; }
/* Constant strings live for the life of the image. */
- (instancetype)retain { return self; }
- (oneway void)release { }
- (NSUInteger)retainCount { return NSUIntegerMax; }
- (id)copyWithZone:(struct _NSZone *)zone { return self; }
@end

/* CFNumber and CFBoolean as NSNumbers (Foundation's class, linked upward):
 * -objCType and -getValue: are what NSNumber's accessors build on. */
CF_EXPORT CFNumberType _CFNumberGetType2(CFNumberRef number);
#define FINCH_SINT128 ((CFNumberType)17)   /* kCFNumberSInt128Type, CFNumber_Private.h */

/* Unsigned values above LLONG_MAX are 128-bit CFNumbers: "Q", as Apple's. */
static const char *
number_objc_type(CFNumberRef n)
{
    switch (_CFNumberGetType2(n)) {
    case FINCH_SINT128: return "Q";
    case kCFNumberSInt8Type: case kCFNumberCharType: return "c";
    case kCFNumberSInt16Type: case kCFNumberShortType: return "s";
    case kCFNumberSInt32Type: case kCFNumberIntType: return "i";
    case kCFNumberFloat32Type: case kCFNumberFloatType: return "f";
    case kCFNumberFloat64Type: case kCFNumberDoubleType: return "d";
    case kCFNumberCGFloatType: return "d";
    case kCFNumberLongType: case kCFNumberNSIntegerType: case kCFNumberCFIndexType: return "q";
    default: return "q";
    }
}

@interface __NSCFNumber : NSNumber
@end
@implementation __NSCFNumber
FINCH_CF_OBJECT_MEMORY
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }
- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (BOOL)isNSNumber__ { return YES; }
- (const char *)objCType { return number_objc_type((CFNumberRef)self); }
- (void)getValue:(void *)value
{
    CFNumberRef n = (CFNumberRef)self;
    switch (*number_objc_type(n)) {
    case 'c': CFNumberGetValue(n, kCFNumberCharType, value); break;
    case 's': CFNumberGetValue(n, kCFNumberShortType, value); break;
    case 'i': CFNumberGetValue(n, kCFNumberIntType, value); break;
    case 'f': CFNumberGetValue(n, kCFNumberFloatType, value); break;
    case 'd': CFNumberGetValue(n, kCFNumberDoubleType, value); break;
    case 'Q': {
        struct { int64_t high; uint64_t low; } s128;
        CFNumberGetValue(n, FINCH_SINT128, &s128);
        memcpy(value, &s128.low, sizeof(s128.low));
        break;
    }
    default: CFNumberGetValue(n, kCFNumberLongLongType, value); break;
    }
}
- (void)getValue:(void *)value size:(NSUInteger)size { [self getValue:value]; }
- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }
@end

@interface __NSCFBoolean : NSNumber
@end
@implementation __NSCFBoolean
- (BOOL)isNSNumber__ { return YES; }
- (instancetype)retain { return self; }
- (oneway void)release { }
- (NSUInteger)retainCount { return NSUIntegerMax; }
- (void)dealloc { }
- (CFTypeID)_cfTypeID { return CFBooleanGetTypeID(); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }
- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (const char *)objCType { return "c"; }
- (void)getValue:(void *)value { *(char *)value = CFBooleanGetValue((CFBooleanRef)self) ? 1 : 0; }
- (void)getValue:(void *)value size:(NSUInteger)size { [self getValue:value]; }
- (BOOL)boolValue { return CFBooleanGetValue((CFBooleanRef)self); }
- (id)copyWithZone:(struct _NSZone *)zone { return self; }
@end

/* CFCharacterSet as an NSMutableCharacterSet (Foundation's class, linked
 * upward). Mutating an immutable set (a predefined one, say) raises. */
CF_PRIVATE Boolean _CFCharacterSetIsMutable(CFCharacterSetRef cset);   /* CFCharacterSet.c (patch 0003) */

@interface __NSCFCharacterSet : NSMutableCharacterSet
@end
@implementation __NSCFCharacterSet
FINCH_CF_OBJECT_MEMORY
- (Class)classForCoder
{
    return objc_getClass(_CFCharacterSetIsMutable((CFCharacterSetRef)self) ? "NSMutableCharacterSet" : "NSCharacterSet");
}
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }
- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (BOOL)characterIsMember:(unichar)c { return CFCharacterSetIsCharacterMember((CFCharacterSetRef)self, c); }
- (BOOL)longCharacterIsMember:(UTF32Char)c { return CFCharacterSetIsLongCharacterMember((CFCharacterSetRef)self, c); }
- (BOOL)hasMemberInPlane:(uint8_t)plane { return CFCharacterSetHasMemberInPlane((CFCharacterSetRef)self, plane); }
- (BOOL)isSupersetOfSet:(id)other { return CFCharacterSetIsSupersetOfSet((CFCharacterSetRef)self, (CFCharacterSetRef)other); }
- (id)invertedSet { return [(id)CFCharacterSetCreateInvertedSet(NULL, (CFCharacterSetRef)self) autorelease]; }
- (id)bitmapRepresentation { return [(id)CFCharacterSetCreateBitmapRepresentation(NULL, (CFCharacterSetRef)self) autorelease]; }
- (id)copyWithZone:(struct _NSZone *)zone
{
    if (!_CFCharacterSetIsMutable((CFCharacterSetRef)self)) return (id)CFRetain((CFTypeRef)self);
    return (id)CFCharacterSetCreateCopy(NULL, (CFCharacterSetRef)self);
}
- (id)mutableCopyWithZone:(struct _NSZone *)zone { return (id)CFCharacterSetCreateMutableCopy(NULL, (CFCharacterSetRef)self); }

static void
check_mutable_set(id self, SEL _cmd)
{
    if (!_CFCharacterSetIsMutable((CFCharacterSetRef)self))
        __CFFinchRaise(NSInternalInconsistencyException, FINCH_METHOD_FMT ": mutating method sent to immutable object",
            FINCH_METHOD_ARGS);
}
- (void)addCharactersInRange:(NSRange)r
{
    check_mutable_set(self, _cmd);
    CFCharacterSetAddCharactersInRange((CFMutableCharacterSetRef)self, CFRangeMake((CFIndex)r.location, (CFIndex)r.length));
}
- (void)removeCharactersInRange:(NSRange)r
{
    check_mutable_set(self, _cmd);
    CFCharacterSetRemoveCharactersInRange((CFMutableCharacterSetRef)self, CFRangeMake((CFIndex)r.location, (CFIndex)r.length));
}
- (void)addCharactersInString:(id)s
{
    check_mutable_set(self, _cmd);
    CFCharacterSetAddCharactersInString((CFMutableCharacterSetRef)self, (CFStringRef)s);
}
- (void)removeCharactersInString:(id)s
{
    check_mutable_set(self, _cmd);
    CFCharacterSetRemoveCharactersInString((CFMutableCharacterSetRef)self, (CFStringRef)s);
}
- (void)formUnionWithCharacterSet:(id)other
{
    check_mutable_set(self, _cmd);
    CFCharacterSetUnion((CFMutableCharacterSetRef)self, (CFCharacterSetRef)other);
}
- (void)formIntersectionWithCharacterSet:(id)other
{
    check_mutable_set(self, _cmd);
    CFCharacterSetIntersect((CFMutableCharacterSetRef)self, (CFCharacterSetRef)other);
}
- (void)invert
{
    check_mutable_set(self, _cmd);
    CFCharacterSetInvert((CFMutableCharacterSetRef)self);
}
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

/* NSBlock, which Apple's CoreFoundation hosts: libclosure's block classes
 * (__NSStackBlock__ and friends, in libsystem_blocks) are made with NSObject
 * as their superclass, and CF makes NSBlock their superclass when it
 * initializes (libclosure's data.m says so). It gives blocks -copy and
 * -invoke. */
extern void *_Block_copy(const void *block);
extern Class class_setSuperclass(Class cls, Class newSuper);

@interface NSBlock : NSObject
@end
@implementation NSBlock
- (id)copy { return (id)_Block_copy(self); }
- (id)copyWithZone:(struct _NSZone *)zone { return (id)_Block_copy(self); }
- (void)invoke { ((void (^)(void))self)(); }
- (id)debugDescription { return [self description]; }
@end

static void
reparent_blocks(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const char *names[] = { "__NSStackBlock__", "__NSMallocBlock__", "__NSAutoBlock__", "__NSGlobalBlock__" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Class c = objc_getClass(names[i]);
        if (c && class_getSuperclass(c) != [NSBlock class]) class_setSuperclass(c, [NSBlock class]);
    }
#pragma clang diagnostic pop
}

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
    set_class(_kCFRuntimeIDCFCharacterSet, [__NSCFCharacterSet class]);

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
    extern void __CFFinchInitializeRunLoopClasses(void);
    extern Class __CFFinchTimerClass(void);
    __CFFinchInitializeRunLoopClasses();
    extern void __CFFinchInitializeLocaleClasses(Class *, Class *, Class *);
    Class locale, zone, calendar;
    __CFFinchInitializeLocaleClasses(&locale, &zone, &calendar);
    set_class(_kCFRuntimeIDCFLocale, locale);
    set_class(_kCFRuntimeIDCFTimeZone, zone);
    set_class(_kCFRuntimeIDCFCalendar, calendar);
    extern Class __CFFinchInitializeURLClasses(void);
    set_class(_kCFRuntimeIDCFURL, __CFFinchInitializeURLClasses());
    set_class(_kCFRuntimeIDCFRunLoopTimer, __CFFinchTimerClass());
    __CFFinchInstallExceptionHandler();
    __CFFinchInstallForwardHandler();
    reparent_blocks();
}
