/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGPattern and CGLayer. A pattern's cell is drawn by its callback into a
 * context that records a Skia picture, which becomes a repeating shader; the
 * pattern matrix maps the cell to the default user space, unaffected by the
 * CTM. An uncoloured pattern's cell is a stencil painted in the colour given
 * with it. A CGLayer is an offscreen bitmap context drawn back as an image.
 */
#include "CGContextInternal.h"
#include "include/core/SkColorFilter.h"
#include "include/core/SkPicture.h"
#include "include/core/SkPictureRecorder.h"
#include "include/core/SkShader.h"
#include <math.h>
#include <pthread.h>

CG_PRIVATE struct CGContext *CGContextCreateBase(int type, size_t width, size_t height);
CG_PRIVATE SkColor4f CGContextColor(CGContextRef c, CGColorRef color);

struct CGPattern {
    CGRuntimeBase base;
    void *info;
    CGRect bounds;
    CGAffineTransform matrix;
    CGFloat xstep, ystep;
    CGPatternTiling tiling;
    bool colored;
    CGPatternCallbacks callbacks;
    SkPicture *picture;  /* the recorded cell */
};

static pthread_mutex_t picture_lock = PTHREAD_MUTEX_INITIALIZER;

static void
pattern_finalize(CFTypeRef cf)
{
    struct CGPattern *p = (struct CGPattern *)cf;
    if (p->callbacks.releaseInfo)
        p->callbacks.releaseInfo(p->info);
    if (p->picture)
        p->picture->unref();
}

static const CGRuntimeClass pattern_class = {
    0, "CGPattern", NULL, NULL, pattern_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID pattern_type;

CFTypeID
CGPatternGetTypeID(void)
{
    return CGTypeRegister(&pattern_class, &pattern_type);
}

CGPatternRef
CGPatternCreate(void *info, CGRect bounds, CGAffineTransform matrix, CGFloat xStep, CGFloat yStep, CGPatternTiling tiling,
                bool isColored, const CGPatternCallbacks *callbacks)
{
    if (!callbacks || !callbacks->drawPattern)
        return NULL;
    struct CGPattern *p = (struct CGPattern *)CGTypeCreateInstance(CGPatternGetTypeID(), sizeof(struct CGPattern));
    p->info = info;
    p->bounds = CGRectStandardize(bounds);
    p->matrix = matrix;
    p->xstep = xStep ? fabs(xStep) : p->bounds.size.width;
    p->ystep = yStep ? fabs(yStep) : p->bounds.size.height;
    p->tiling = tiling;
    p->colored = isColored;
    p->callbacks = *callbacks;
    return p;
}

CGPatternRef CGPatternRetain(CGPatternRef p) { return p ? (CGPatternRef)CFRetain(p) : NULL; }
void CGPatternRelease(CGPatternRef p) { if (p) CFRelease(p); }

/* Record the cell once, in pattern space, drawing as the target context would. */
static sk_sp<SkPicture>
cell_picture(CGContextRef target, CGPatternRef p)
{
    pthread_mutex_lock(&picture_lock);
    SkPicture *cached = p->picture;
    if (cached)
        cached->ref();
    pthread_mutex_unlock(&picture_lock);
    if (cached)
        return sk_sp<SkPicture>(cached);
    SkPictureRecorder recorder;
    SkRect cull = SkRect::MakeXYWH((float)p->bounds.origin.x, (float)p->bounds.origin.y, (float)p->bounds.size.width,
                                   (float)p->bounds.size.height);
    SkCanvas *canvas = recorder.beginRecording(cull);
    struct CGContext *c = CGContextCreateBase(CG_CONTEXT_LAYER, (size_t)ceil(cull.right()), (size_t)ceil(cull.bottom()));
    c->canvas = canvas;
    c->base_ctm = CGAffineTransformIdentity;  /* record in pattern space itself */
    CGContextState(c).clip = p->bounds;
    if (target->draw_space)
        c->draw_space = (CGColorSpaceRef)CFRetain(target->draw_space);
    if (target->skspace)
        c->skspace = new sk_sp<SkColorSpace>(*target->skspace);
    canvas->clipRect(cull);
    p->callbacks.drawPattern(p->info, c);
    c->canvas = NULL;
    CFRelease(c);
    sk_sp<SkPicture> picture = recorder.finishRecordingAsPicture();
    pthread_mutex_lock(&picture_lock);
    if (!p->picture) {
        picture->ref();
        ((struct CGPattern *)p)->picture = picture.get();
    }
    pthread_mutex_unlock(&picture_lock);
    return picture;
}

sk_sp<SkShader>
CGPatternShader(CGContextRef c, CGColorRef color, const CGAffineTransform &default_to_canvas)
{
    CGPatternRef p = CGColorGetPattern(color);
    sk_sp<SkPicture> picture = cell_picture(c, p);
    CGSize phase = CGContextState(c).pattern_phase;
    CGAffineTransform local = CGAffineTransformConcat(p->matrix, CGAffineTransformMakeTranslation(phase.width, phase.height));
    local = CGAffineTransformConcat(local, default_to_canvas);
    SkMatrix m = CGSkMatrix(local);
    SkRect tile = SkRect::MakeXYWH((float)p->bounds.origin.x, (float)p->bounds.origin.y, (float)p->xstep, (float)p->ystep);
    sk_sp<SkShader> shader = picture->makeShader(SkTileMode::kRepeat, SkTileMode::kRepeat, SkFilterMode::kLinear, &m, &tile);
    if (!p->colored) {
        /* a stencil: the cell's coverage in the colour given with the pattern */
        CGColorSpaceRef base = CGColorGetColorSpace(color)->base_space;
        SkColor4f col = {0, 0, 0, 1};
        if (base) {
            CGFloat v[CG_COLOR_MAX_COMPONENTS];
            for (size_t k = 0; k < color->n; k++)
                v[k] = color->comps[k];
            CGColorRef stencil = CGColorCreate(base, v);
            if (stencil) {
                col = CGContextColor(c, stencil);
                CFRelease(stencil);
            }
        }
        shader = shader->makeWithColorFilter(
            SkColorFilters::Blend(col, c->skspace ? *c->skspace : nullptr, SkBlendMode::kSrcIn));
    }
    return shader;
}

/*
 * Paint `path` (in the canvas's current space) with a pattern colour the way
 * Apple's CG does: each cell drawn on its own, clipped to the shape, so
 * antialiased cell edges show where cells meet. `default_to_canvas` maps the
 * default user space to the canvas's current space.
 */
CG_PRIVATE void
CGPatternDrawCells(CGContextRef c, CGColorRef color, const SkPath &path, const SkPaint &paint,
                   const CGAffineTransform &default_to_canvas)
{
    CGPatternRef p = CGColorGetPattern(color);
    sk_sp<SkPicture> picture = cell_picture(c, p);
    SkCanvas *canvas = c->canvas;
    CGSize phase = CGContextState(c).pattern_phase;
    CGAffineTransform t = CGAffineTransformConcat(p->matrix, CGAffineTransformMakeTranslation(phase.width, phase.height));
    t = CGAffineTransformConcat(t, default_to_canvas);
    /* the cells that can touch the shape */
    CGAffineTransform inv = CGAffineTransformInvert(t);
    SkRect b = path.getBounds();
    CGRect area = CGRectApplyAffineTransform(CGRectMake(b.left(), b.top(), b.width(), b.height()), inv);
    double x0 = p->bounds.origin.x, y0 = p->bounds.origin.y;
    long i0 = (long)floor((area.origin.x - x0 - p->bounds.size.width) / p->xstep) - 1;
    long i1 = (long)ceil((CGRectGetMaxX(area) - x0) / p->xstep) + 1;
    long j0 = (long)floor((area.origin.y - y0 - p->bounds.size.height) / p->ystep) - 1;
    long j1 = (long)ceil((CGRectGetMaxY(area) - y0) / p->ystep) + 1;
    if ((i1 - i0) * (j1 - j0) > 100000)
        return;
    SkPaint cell;
    cell.setAlphaf(paint.getAlphaf());
    cell.setBlendMode(paint.getBlendMode_or(SkBlendMode::kSrcOver));
    if (!p->colored) {
        CGColorSpaceRef base = CGColorGetColorSpace(color)->base_space;
        SkColor4f col = {0, 0, 0, 1};
        if (base) {
            CGColorRef stencil = CGColorCreate(base, color->comps);
            if (stencil) {
                col = CGContextColor(c, stencil);
                CFRelease(stencil);
            }
        }
        cell.setColorFilter(SkColorFilters::Blend(col, c->skspace ? *c->skspace : nullptr, SkBlendMode::kSrcIn));
    }
    bool plain = p->colored && cell.getAlphaf() == 1 && cell.asBlendMode() == SkBlendMode::kSrcOver;
    canvas->save();
    canvas->clipPath(path, paint.isAntiAlias());
    SkMatrix base = CGSkMatrix(t);
    for (long j = j0; j <= j1; j++)
        for (long i = i0; i <= i1; i++) {
            SkMatrix m = base;
            m.preTranslate((float)(i * p->xstep), (float)(j * p->ystep));
            canvas->drawPicture(picture.get(), &m, plain ? nullptr : &cell);
        }
    canvas->restore();
}

static void
set_pattern(CGColorRef *slot, CGColorSpaceRef remembered, CGPatternRef pattern, const CGFloat *components)
{
    CGColorSpaceRef space = remembered ? remembered : *slot ? CGColorGetColorSpace(*slot) : NULL;
    CGColorSpaceRef pattern_space = space && space->kind == CG_SPACE_PATTERN ? (CGColorSpaceRef)CFRetain(space)
                                                                              : CGColorSpaceCreatePattern(NULL);
    CGColorRef color = CGColorCreateWithPattern(pattern_space, pattern, components);
    CFRelease(pattern_space);
    if (!color)
        return;
    if (*slot)
        CFRelease(*slot);
    *slot = color;
}

void
CGContextSetFillPattern(CGContextRef c, CGPatternRef pattern, const CGFloat *components)
{
    if (c && pattern)
        set_pattern(&CGContextState(c).fill, CGContextState(c).fill_pattern_space, pattern, components);
}

void
CGContextSetStrokePattern(CGContextRef c, CGPatternRef pattern, const CGFloat *components)
{
    if (c && pattern)
        set_pattern(&CGContextState(c).stroke, CGContextState(c).stroke_pattern_space, pattern, components);
}

#pragma mark - CGLayer

struct CGLayer {
    CGRuntimeBase base;
    CGContextRef context;
    CGSize size;
};

static void
layer_finalize(CFTypeRef cf)
{
    struct CGLayer *l = (struct CGLayer *)cf;
    if (l->context)
        CFRelease(l->context);
}

static const CGRuntimeClass layer_class = {
    0, "CGLayer", NULL, NULL, layer_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID layer_type;

CFTypeID
CGLayerGetTypeID(void)
{
    return CGTypeRegister(&layer_class, &layer_type);
}

CGLayerRef
CGLayerCreateWithContext(CGContextRef context, CGSize size, CFDictionaryRef auxiliaryInfo)
{
    if (!context || size.width <= 0 || size.height <= 0)
        return NULL;
    CGColorSpaceRef space = context->space && CGColorSpaceGetModel(context->space) == kCGColorSpaceModelRGB
                                ? (CGColorSpaceRef)CFRetain(context->space)
                                : CGColorSpaceCreateDeviceRGB();
    CGContextRef lc = CGBitmapContextCreate(NULL, (size_t)ceil(size.width), (size_t)ceil(size.height), 8, 0, space,
                                            kCGImageAlphaPremultipliedLast);
    CFRelease(space);
    if (!lc)
        return NULL;
    struct CGLayer *l = (struct CGLayer *)CGTypeCreateInstance(CGLayerGetTypeID(), sizeof(struct CGLayer));
    l->context = lc;
    l->size = size;
    return l;
}

CGLayerRef CGLayerRetain(CGLayerRef l) { return l ? (CGLayerRef)CFRetain(l) : NULL; }
void CGLayerRelease(CGLayerRef l) { if (l) CFRelease(l); }
CGSize CGLayerGetSize(CGLayerRef l) { return l ? l->size : CGSizeZero; }
CGContextRef CGLayerGetContext(CGLayerRef l) { return l ? l->context : NULL; }

void
CGContextDrawLayerInRect(CGContextRef c, CGRect rect, CGLayerRef layer)
{
    if (!c || !layer)
        return;
    CGImageRef im = CGBitmapContextCreateImage(layer->context);
    CGInterpolationQuality q = CGContextGetInterpolationQuality(c);
    CGContextDrawImage(c, rect, im);
    (void)q;
    CGImageRelease(im);
}

void
CGContextDrawLayerAtPoint(CGContextRef c, CGPoint point, CGLayerRef layer)
{
    if (layer)
        CGContextDrawLayerInRect(c, CGRectMake(point.x, point.y, layer->size.width, layer->size.height), layer);
}
