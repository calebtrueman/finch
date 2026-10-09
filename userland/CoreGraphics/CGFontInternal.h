/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CGFont's representation, shared with text drawing and CoreText. */
#ifndef CG_FONT_INTERNAL_H
#define CG_FONT_INTERNAL_H

#include "CGInternal.h"
#include "include/core/SkTypeface.h"
#include <vector>

struct CGFont {
    CGRuntimeBase base;
    CFDataRef data;
    const uint8_t *bytes;
    size_t length;
    void *face;                    /* FT_Face */
    void *typeface;                /* SkTypeface, made on demand */
    int units_per_em;
    size_t glyph_count;
    std::vector<double> *coords;   /* variation design coordinates, by fvar axis */
    CFDictionaryRef variations;
};

CG_PRIVATE sk_sp<SkTypeface> CGFontGetTypeface(CGFontRef f);
/* The bytes of the installed font with this PostScript name (CGFontRegistry.cpp). */
CG_PRIVATE CFDataRef CGFontRegistryCopyDataForName(CFStringRef postscript_name);

#endif
