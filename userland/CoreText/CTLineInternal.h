/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CTLine's and CTRun's representations, shared with the typesetter and frames. */
#ifndef CT_LINE_INTERNAL_H
#define CT_LINE_INTERNAL_H

#include "CTInternal.h"

struct __CTRun {
    CTRuntimeBase base;
    CFDictionaryRef attributes;
    CTFontRef font;
    CFRange range;
    CTRunStatus status;
    CGAffineTransform text_matrix;
    std::vector<CGGlyph> *glyphs;
    std::vector<CGPoint> *positions;   /* from the line's origin */
    std::vector<CGSize> *advances;
    std::vector<CFIndex> *indices;     /* into the attributed string */
    double width;
    double tracking;                   /* added after each glyph */
};

struct __CTLine {
    CTRuntimeBase base;
    CFAttributedStringRef string;
    CFRange range;
    CFArrayRef runs;                   /* visual order */
    CFIndex glyph_count;
    double width, trailing_whitespace;
    CGFloat ascent, descent, leading;
    std::vector<CGFloat> *carets;      /* offset of each string index, and of the end */
};

CT_PRIVATE CTFontRef CTDefaultFont(void);
CT_PRIVATE CTLineRef CTLineCreateWithAttributedSubstring(CFAttributedStringRef string, CFRange range);
CT_PRIVATE CTLineRef CTLineCreateSlice(CTLineRef whole, CFRange range);
CT_PRIVATE bool CTLineHasRightToLeft(CTLineRef l);

#endif
