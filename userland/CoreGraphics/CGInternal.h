/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch CoreGraphics internals: CF runtime registration for CG's types, as on
 * macOS, where every CG object is a CF object (CFRetain, CFGetTypeID and
 * CFCopyDescription work, and ObjC sees it as __NSCFType).
 */
#ifndef CG_INTERNAL_H
#define CG_INTERNAL_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Internal to the framework (the export list exports every other CG* symbol). */
#define CG_PRIVATE __attribute__((visibility("hidden")))

/* Finch's CoreFoundation's runtime (swift-corelibs CFRuntime.h layout). */
typedef struct {
    uintptr_t cfisa;
    uint64_t cfinfoa;  /* atomic in CF */
} CGRuntimeBase;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef cf);
    CFTypeRef (*copy)(CFAllocatorRef allocator, CFTypeRef cf);
    void (*finalize)(CFTypeRef cf);
    Boolean (*equal)(CFTypeRef cf1, CFTypeRef cf2);
    CFHashCode (*hash)(CFTypeRef cf);
    CFStringRef (*copyFormattingDesc)(CFTypeRef cf, CFDictionaryRef formatOptions);
    CFStringRef (*copyDebugDesc)(CFTypeRef cf);
    void (*reclaim)(CFTypeRef cf);
    uint32_t (*refcount)(intptr_t op, CFTypeRef cf);
    uintptr_t requiredAlignment;
} CGRuntimeClass;

CFTypeID _CFRuntimeRegisterClass(const CGRuntimeClass *cls);
CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes,
                                   unsigned char *category);

/*
 * Register a CG type once and return its type ID. `cls` must be static.
 * Instances are created with CGTypeCreateInstance(typeID, sizeof(struct)):
 * the struct starts with a CGRuntimeBase, and the rest is zeroed.
 */
CG_PRIVATE CFTypeID CGTypeRegister(const CGRuntimeClass *cls, CFTypeID *slot);
CG_PRIVATE void *CGTypeCreateInstance(CFTypeID type, size_t size);

/* "<CGFoo 0x...>" plus an optional suffix, as Apple's descriptions start. */
CG_PRIVATE CFStringRef CGTypeCopyDescriptionPrefix(CFTypeRef cf, const char *name);

/* Write to a data consumer. */
CG_PRIVATE size_t CGDataConsumerPutBytesInternal(CGDataConsumerRef c, const void *bytes, size_t count);

#ifdef __cplusplus
}
#endif

#endif
