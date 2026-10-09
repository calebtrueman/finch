/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CGContext's representation, shared by the context types (bitmap, PDF, layers). */
#ifndef CG_CONTEXT_INTERNAL_H
#define CG_CONTEXT_INTERNAL_H

#include "CGColorInternal.h"
#include "CGPixels.h"
#include "CGSkia.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkSurface.h"
#include <vector>

struct CGGState {
    CGAffineTransform ctm;        /* user space to the context's default user space */
    CGColorRef fill, stroke;      /* retained */
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

static inline CGGState &
CGContextState(CGContextRef c)
{
    return c->stack->back();
}

#endif
