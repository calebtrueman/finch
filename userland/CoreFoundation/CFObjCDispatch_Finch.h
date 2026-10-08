/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CoreFoundation's dispatch to Objective-C objects, as Apple's CF has it
 * (docs/design/FOUNDATION.md). CF compiles as Objective-C, and CFInternal.h
 * includes this in place of swift-corelibs' empty macros (patches/0003).
 *
 * A CF function handed an object CF didn't make (an NSArray subclass passed
 * to CFArrayGetCount, say) sends it the matching message instead:
 *
 *   CF_OBJC_FUNCDISPATCHV(typeID, ret, (NSArray *)array, count)
 *       -> if array isn't a CF object of typeID: return [array count]
 *
 * An object is CF's when its class is the one CF's class table holds for
 * the type its CFRuntimeBase records (or, for strings, CFSTR's constant-string
 * class). Anything else, tagged pointers included, is Objective-C. Reading
 * _cfinfo from an ObjC object reads its first ivar (heap blocks are at least
 * 16 bytes); a wrong type ID read that way fails the class comparison.
 *
 * The messages sent are declared, with Foundation's signatures, in
 * CFObjCMessages_Finch.h.
 */
#ifndef CF_OBJC_DISPATCH_FINCH_H
#define CF_OBJC_DISPATCH_FINCH_H

#include <objc/runtime.h>
#include "CFObjCMessages_Finch.h"

extern int __CFConstantStringClassReference[];
extern id objc_retain(id);
extern void objc_release(id);
CF_EXPORT CFTypeID __CFGenericTypeID(const void *cf);

CF_INLINE Boolean
__CFFinchIsCFClassForType(Class cls, CFTypeID typeID)
{
    if (typeID >= __CFRuntimeClassTableSize) return false;
    if ((uintptr_t)cls == __CFISAForTypeID(typeID)) return true;
    return typeID == _kCFRuntimeIDCFString && cls == (Class)(void *)__CFConstantStringClassReference;
}

/* arm64 tagged pointers have the top bit set (objc4's _objc_isTaggedPointer). */
CF_INLINE Boolean __CFFinchIsTagged(const void *obj) { return (intptr_t)obj < 0; }

/* Is obj, given to a function for CF type typeID, an ObjC object? */
CF_INLINE Boolean
__CFFinchIsObjC(CFTypeID typeID, const void *obj)
{
    if (__CFFinchIsTagged(obj)) return true;
    return !__CFFinchIsCFClassForType(object_getClass((id)obj), typeID);
}

/* Is obj, of any CF type, an ObjC object? */
CF_INLINE Boolean
__CFFinchTypeIsObjC(const void *obj)
{
    if (__CFFinchIsTagged(obj)) return true;
    CFTypeID typeID = __CFGenericTypeID(obj);
    return !__CFFinchIsCFClassForType(object_getClass((id)obj), typeID);
}

/* The result of a message, retained as a CF "Copy"/"Create" result is. */
CF_INLINE CFTypeRef
__CFFinchRetainedResult(id result)
{
    return result ? (CFTypeRef)objc_retain(result) : NULL;
}

CF_INLINE CFTypeRef __CFFinchObjCRetain(CFTypeRef cf) { return (CFTypeRef)objc_retain((id)cf); }
CF_INLINE void __CFFinchObjCRelease(CFTypeRef cf) { objc_release((id)cf); }
CF_INLINE CFStringRef
__CFFinchObjCCopyDescription(CFTypeRef cf)
{
    return (CFStringRef)__CFFinchRetainedResult([(id)cf description]);
}

#define CF_IS_OBJC(typeID, obj) (__CFFinchIsObjC((typeID), (const void *)(obj)))
#define CF_OBJC_FUNCDISPATCHV(typeID, rettype, obj, ...) do { \
        if (CF_IS_OBJC(typeID, obj)) return (rettype)[obj __VA_ARGS__]; \
    } while (0)
#define CF_OBJC_RETAINED_FUNCDISPATCHV(typeID, rettype, obj, ...) do { \
        if (CF_IS_OBJC(typeID, obj)) return (rettype)__CFFinchRetainedResult([obj __VA_ARGS__]); \
    } while (0)
#define CF_OBJC_CALLV(obj, ...) [obj __VA_ARGS__]

#define CFTYPE_IS_OBJC(obj) (__CFFinchTypeIsObjC((const void *)(obj)))
#define CFTYPE_OBJC_FUNCDISPATCH0(rettype, obj, sel) do { \
        if (CFTYPE_IS_OBJC(obj)) return (rettype)[(id)(obj) sel]; \
    } while (0)
#define CFTYPE_OBJC_FUNCDISPATCH1(rettype, obj, sel, a1) do { \
        if (CFTYPE_IS_OBJC(obj)) return (rettype)[(id)(obj) sel(id)(a1)]; \
    } while (0)

#endif
