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
    std::vector<uint8_t> *color;   /* per glyph: 0 not yet known, 1 outline only, 2 has a colour form */
};

CG_PRIVATE sk_sp<SkTypeface> CGFontGetTypeface(CGFontRef f);
/* Whether the glyph has a colour form (COLR, CBDT or sbix), drawn by Skia rather than as an outline. */
CG_PRIVATE bool CGFontGlyphIsColor(CGFontRef f, CGGlyph glyph);
/* A glyph's outline from FreeType in font units (y up), or NULL: for the COLR glyphs Skia gives no outline for. */
CG_PRIVATE CGPathRef CGFontCopyGlyphOutline(CGFontRef f, CGGlyph glyph);
/* The bytes of the installed font with this PostScript name (CGFontRegistry.cpp). */
CG_PRIVATE CFDataRef CGFontRegistryCopyDataForName(CFStringRef postscript_name);

#endif
