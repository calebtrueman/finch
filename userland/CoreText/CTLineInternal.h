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
    bool delegated;                    /* a run delegate's: its metrics, and nothing drawn */
    CGFloat delegate_ascent, delegate_descent;
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
/* A CTRunDelegate's ascent, descent and width (false if `d` isn't one). */
CT_PRIVATE bool CTRunDelegateGetMetrics(CFTypeRef d, CGFloat *ascent, CGFloat *descent, CGFloat *width);
/* A run's ascent and descent: its delegate's, else its font's. */
CT_PRIVATE CGFloat CTRunAscent(const struct __CTRun *r);
CT_PRIVATE CGFloat CTRunDescent(const struct __CTRun *r);

#endif
