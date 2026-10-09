/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch CoreText internals: CF runtime registration (as in CoreGraphics),
 * the font representation shared by fonts, descriptors and layout, and
 * font-file table access.
 */
#ifndef CT_INTERNAL_H
#define CT_INTERNAL_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <vector>

#define CT_PRIVATE __attribute__((visibility("hidden")))

extern "C" {
typedef struct {
    uintptr_t cfisa;
    uint64_t cfinfoa;
} CTRuntimeBase;

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
} CTRuntimeClass;

CFTypeID _CFRuntimeRegisterClass(const CTRuntimeClass *cls);
CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes, unsigned char *category);

/* Finch CoreGraphics' accessor for a CGFont's file data and variation coordinates. */
CFDataRef CGFontFinchCopyData(CGFontRef f, CFIndex *axisCount, double *coords, CFIndex maxCoords);
}

CT_PRIVATE CFTypeID CTTypeRegister(const CTRuntimeClass *cls, CFTypeID *slot);
/* A zeroed instance whose struct starts with a CTRuntimeBase. */
CT_PRIVATE void *CTTypeCreateInstance(CFTypeID type, size_t size);

#pragma mark - Fonts

struct __CTFont {
    CTRuntimeBase base;
    CGFontRef cg;
    CFDataRef data;
    const uint8_t *bytes;
    size_t length;
    void *face;        /* FT_Face, unscaled */
    void *hb;          /* hb_font_t at units-per-em scale */
    int upem;
    CGFloat size;
    CGAffineTransform matrix;
    CTFontDescriptorRef descriptor;
    std::vector<double> *coords;
};

/* A table of the font's file (face 0), or NULL. */
CT_PRIVATE const uint8_t *CTFontTable(CTFontRef f, uint32_t tag, size_t *length);
/* A name-table string (Windows Unicode first, then Mac Roman). */
CT_PRIVATE CFStringRef CTFontNameString(CTFontRef f, uint16_t nameID);
/* The font with this PostScript, full or family name, if installed or registered in this process. */
CT_PRIVATE CGFontRef CTFontRegistryCopyGraphicsFont(CFStringRef name);
CT_PRIVATE void CTFontRegistryAddGraphicsFont(CGFontRef font);
/* Lock around FreeType calls on a face. */
CT_PRIVATE void CTFontLockFace(CTFontRef f);
CT_PRIVATE void CTFontUnlockFace(CTFontRef f);

static inline uint16_t
ct_be16(const uint8_t *p)
{
    return (uint16_t)(p[0] << 8 | p[1]);
}

static inline uint32_t
ct_be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

#endif
