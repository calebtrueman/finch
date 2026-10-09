// SPDX-License-Identifier: MIT OR Apache-2.0
// What the ObjectiveC overlay (objc4's ObjectiveC/ObjectiveC.swift) uses of
// objc4's runtime/objc-internal.h, with objc4's declarations.
#pragma once
#include <objc/runtime.h>
#include <stddef.h>

typedef struct objc_class_enumerator {
    const void * _Nullable image;
    const char * _Nullable namePrefix;
#if __swift__
    void       * _Nullable conformingTo;
#else
    Protocol   * _Nullable conformingTo;
#endif
    Class        _Nullable subclassing;
    size_t      namePrefixLen;
    const Class _Nonnull * _Nullable imageClassList;
    size_t                           imageClassNdx;
    size_t                           imageClassCount;
} objc_class_enumerator_t;

OBJC_EXPORT void _objc_beginClassEnumeration(const void * _Nullable image,
    const char * _Nullable namePrefix, Protocol * _Nullable conformingTo,
    Class _Nullable subclassing, objc_class_enumerator_t * _Nonnull enumerator);
OBJC_EXPORT Class _Nullable _objc_enumerateNextClass(objc_class_enumerator_t * _Nonnull enumerator);
OBJC_EXPORT void _objc_endClassEnumeration(objc_class_enumerator_t * _Nonnull enumerator);
OBJC_EXPORT void * _Nonnull _objc_autoreleasePoolPush(void);
OBJC_EXPORT void _objc_autoreleasePoolPop(void * _Nonnull context);
