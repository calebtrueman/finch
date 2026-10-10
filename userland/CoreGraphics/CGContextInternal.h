/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CGContext's representation, shared by the context types (bitmap, PDF, layers). */
#ifndef CG_CONTEXT_INTERNAL_H
#define CG_CONTEXT_INTERNAL_H

#include "CGColorInternal.h"
#include "CGPixels.h"
#include "CGSkia.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkFont.h"
#include "include/core/SkSurface.h"
#include <vector>

struct CGGState {
    CGAffineTransform ctm;        /* user space to the context's default user space */
    CGColorRef fill, stroke;      /* retained */
    CGColorSpaceRef fill_pattern_space, stroke_pattern_space;  /* set by a pattern colour space, until the pattern */
    CGFloat line_width, miter_limit, flatness;
    CGLineCap cap;
    CGLineJoin join;
    CGFloat dash_phase;
    std::vector<CGFloat> dashes;
    CGFloat alpha;
    CGBlendMode blend;
    CGSize shadow_offset;
    CGFloat shadow_blur;
    CGColorRef shadow_color;      /* NULL: no shadow */
    CGInterpolationQuality interpolation;
    bool antialias, allows_antialias;
    bool smooth_fonts, allows_smoothing, subpixel_position, allows_subpixel_position;
    int font_smoothing_style; /* Apple's private style; 48 by default, as Apple's */
    bool subpixel_quantize, allows_subpixel_quantize;
    CGColorRenderingIntent intent;
    CGRect clip;                  /* clip bounds, in the default user space */
    CGFontRef font;               /* retained */
    CGFloat font_size, char_spacing;
    CGTextDrawingMode text_mode;
    CGSize pattern_phase;
    bool layer;                   /* this level began a transparency layer */
};

enum { CG_CONTEXT_BITMAP, CG_CONTEXT_PDF, CG_CONTEXT_LAYER };

struct CGContext {
    CGRuntimeBase base;
    int type;
    /* bitmap */
    void *data;
    bool owns_data;
    CGBitmapContextReleaseDataCallback release;
    void *release_info;
    size_t width, height, bpc, bpp, bpr;
    CGColorSpaceRef space;        /* NULL for alpha-only */
    CGBitmapInfo info;
    /* Skia */
    sk_sp<SkSurface> *surface;
    SkCanvas *canvas;
    SkBitmap *work;               /* drawing buffer when Skia can't draw the client's layout */
    sk_sp<SkColorSpace> *skspace;
    CGColorSpaceRef draw_space;   /* the space paint colours are converted to */
    /* state */
    std::vector<CGGState> *stack;
    CGAffineTransform base_ctm;   /* default user space to device (the flip) */
    CGMutablePathRef path;        /* in default user space */
    CGAffineTransform text_matrix;
    void *pdf;                    /* PDF context state */
};

/* Fill the clip with a shader given in user space, with the state's alpha, blend mode and shadow. */
CG_PRIVATE void CGContextPaintShader(CGContextRef c, sk_sp<SkShader> shader);
/* A colour's components converted to the context's drawing space, as Skia takes them. */
CG_PRIVATE SkColor4f CGContextConvertComponents(CGContextRef c, CGColorSpaceRef space, const CGFloat *components);
CG_PRIVATE CGAffineTransform CGContextUserToDevice(CGContextRef c);
/* Paint, or clip to, a path given in user space, leaving the current path alone. */
CG_PRIVATE void CGContextDrawUserPath(CGContextRef c, CGPathRef path, CGPathDrawingMode mode);
CG_PRIVATE void CGContextClipToUserPath(CGContextRef c, CGPathRef path, bool evenOdd);
/* Draw glyphs in their colour forms, `m` mapping Skia's glyph space (y down) to the device (CGContext.cpp). */
CG_PRIVATE void CGContextDrawColorGlyphs(CGContextRef c, const SkFont &font, const SkGlyphID *glyphs,
                                         const SkPoint *positions, size_t count, const SkMatrix &m);

static inline CGGState &
CGContextState(CGContextRef c)
{
    return c->stack->back();
}

#endif
