/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGContext over a Skia canvas: the graphics state, the current path (kept
 * in the context's default user space, as Apple's is kept in device space),
 * clipping, painting paths, rects and images, transparency layers and
 * shadows. CGBitmapContext supplies the canvas (CGBitmapContext.cpp).
 *
 * Coordinates: user space is y up; the device is y down, with the base
 * transform [1 0 0 -1 0 height] between the default user space and pixels.
 */
#include "CGContextInternal.h"
#include "include/core/SkColorFilter.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPathEffect.h"
#include "include/core/SkPathUtils.h"
#include "include/core/SkRRect.h"
#include "include/core/SkSamplingOptions.h"
#include "include/effects/SkDashPathEffect.h"
#include "include/effects/SkImageFilters.h"
#include "src/core/SkCanvasPriv.h"  /* the clip reset CG needs */
#include <math.h>
#include <new>

#pragma mark - CF type

CG_PRIVATE void CGBitmapContextFinalize(CGContextRef c);
CG_PRIVATE void CGContextSyncFromClient(CGContextRef c, const SkIRect &r);
CG_PRIVATE void CGContextSyncToClient(CGContextRef c, const SkIRect &r);

static void
gstate_release(CGGState &g)
{
    if (g.fill)
        CFRelease(g.fill);
    if (g.stroke)
        CFRelease(g.stroke);
    if (g.shadow_color)
        CFRelease(g.shadow_color);
    if (g.font)
        CFRelease(g.font);
    if (g.fill_pattern_space)
        CFRelease(g.fill_pattern_space);
    if (g.stroke_pattern_space)
        CFRelease(g.stroke_pattern_space);
}

static void
gstate_retain(CGGState &g)
{
    if (g.fill)
        CFRetain(g.fill);
    if (g.stroke)
        CFRetain(g.stroke);
    if (g.shadow_color)
        CFRetain(g.shadow_color);
    if (g.font)
        CFRetain(g.font);
    if (g.fill_pattern_space)
        CFRetain(g.fill_pattern_space);
    if (g.stroke_pattern_space)
        CFRetain(g.stroke_pattern_space);
}

static void
context_finalize(CFTypeRef cf)
{
    struct CGContext *c = (struct CGContext *)cf;
    if (c->stack) {
        for (auto &g : *c->stack)
            gstate_release(g);
        delete c->stack;
    }
    if (c->path)
        CFRelease(c->path);
    if (c->type == CG_CONTEXT_BITMAP)
        CGBitmapContextFinalize(c);
    delete c->surface;
    delete c->work;
    delete c->skspace;
    if (c->space)
        CFRelease(c->space);
    if (c->draw_space)
        CFRelease(c->draw_space);
}

static CFStringRef
context_desc(CFTypeRef cf)
{
    struct CGContext *c = (struct CGContext *)cf;
    const char *type = c->type == CG_CONTEXT_BITMAP ? "kCGContextTypeBitmap"
                       : c->type == CG_CONTEXT_PDF  ? "kCGContextTypePDF"
                                                    : "kCGContextTypeLayer";
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CGContext %p [%s]>"), c, type);
}

static const CGRuntimeClass context_class = {
    0, "CGContext", NULL, NULL, context_finalize, NULL, NULL, NULL, context_desc, NULL, NULL, 0,
};
static CFTypeID context_type;

CFTypeID
CGContextGetTypeID(void)
{
    return CGTypeRegister(&context_class, &context_type);
}

CG_PRIVATE struct CGContext *
CGContextCreateBase(int type, size_t width, size_t height)
{
    struct CGContext *c = (struct CGContext *)CGTypeCreateInstance(CGContextGetTypeID(), sizeof(struct CGContext));
    c->type = type;
    c->width = width, c->height = height;
    c->stack = new std::vector<CGGState>(1);
    CGGState &g = c->stack->back();
    g.ctm = CGAffineTransformIdentity;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGFloat black[2] = {0, 1};
    g.fill = CGColorCreate(gray, black);
    g.stroke = CGColorCreate(gray, black);
    CFRelease(gray);
    g.line_width = 1;
    g.miter_limit = 10;
    g.flatness = 0.5;
    g.cap = kCGLineCapButt;
    g.join = kCGLineJoinMiter;
    g.alpha = 1;
    g.blend = kCGBlendModeNormal;
    g.interpolation = kCGInterpolationDefault;
    g.antialias = g.allows_antialias = true;
    g.smooth_fonts = g.allows_smoothing = g.subpixel_position = g.allows_subpixel_position = true;
    g.subpixel_quantize = g.allows_subpixel_quantize = true;
    g.intent = kCGRenderingIntentDefault;
    g.clip = CGRectMake(0, 0, width, height);
    g.font_size = 0;
    g.text_mode = kCGTextFill;
    c->base_ctm = CGAffineTransformMake(1, 0, 0, -1, 0, height);
    c->path = CGPathCreateMutable();
    c->text_matrix = CGAffineTransformIdentity;
    return c;
}

CGContextRef
CGContextRetain(CGContextRef c)
{
    return c ? (CGContextRef)CFRetain(c) : NULL;
}

void
CGContextRelease(CGContextRef c)
{
    if (c)
        CFRelease(c);
}

void CGContextFlush(CGContextRef c) {}
void CGContextSynchronize(CGContextRef c) {}
void CGContextSynchronizeAttributes(CGContextRef c) {}

#pragma mark - Graphics state

void
CGContextSaveGState(CGContextRef c)
{
    if (!c)
        return;
    CGGState copy = CGContextState(c);
    copy.layer = false;
    gstate_retain(copy);
    c->stack->push_back(copy);
    if (c->canvas)
        c->canvas->save();
}

void
CGContextRestoreGState(CGContextRef c)
{
    if (!c || c->stack->size() <= 1)
        return;
    if (CGContextState(c).layer)
        return;  /* a transparency layer is open: CGContextEndTransparencyLayer pops it */
    gstate_release(CGContextState(c));
    c->stack->pop_back();
    if (c->canvas)
        c->canvas->restore();
}

static CGAffineTransform
user_to_device(CGContextRef c)
{
    return CGAffineTransformConcat(CGContextState(c).ctm, c->base_ctm);
}

void
CGContextScaleCTM(CGContextRef c, CGFloat sx, CGFloat sy)
{
    if (c)
        CGContextState(c).ctm = CGAffineTransformScale(CGContextState(c).ctm, sx, sy);
}

void
CGContextTranslateCTM(CGContextRef c, CGFloat tx, CGFloat ty)
{
    if (c)
        CGContextState(c).ctm = CGAffineTransformTranslate(CGContextState(c).ctm, tx, ty);
}

void
CGContextRotateCTM(CGContextRef c, CGFloat angle)
{
    if (c)
        CGContextState(c).ctm = CGAffineTransformRotate(CGContextState(c).ctm, angle);
}

void
CGContextConcatCTM(CGContextRef c, CGAffineTransform t)
{
    if (c)
        CGContextState(c).ctm = CGAffineTransformConcat(t, CGContextState(c).ctm);
}

CGAffineTransform
CGContextGetCTM(CGContextRef c)
{
    return c ? CGContextState(c).ctm : CGAffineTransformIdentity;
}

CGAffineTransform
CGContextGetUserSpaceToDeviceSpaceTransform(CGContextRef c)
{
    return c ? user_to_device(c) : CGAffineTransformIdentity;
}

CGPoint
CGContextConvertPointToDeviceSpace(CGContextRef c, CGPoint p)
{
    return c ? CGPointApplyAffineTransform(p, user_to_device(c)) : p;
}

/* Solved directly rather than through the inverse, as Apple's is (it rounds differently). */
CGPoint
CGContextConvertPointToUserSpace(CGContextRef c, CGPoint p)
{
    if (!c)
        return p;
    CGAffineTransform t = user_to_device(c);
    CGFloat det = t.a * t.d - t.b * t.c;
    if (det == 0)
        return p;
    CGFloat dx = p.x - t.tx, dy = p.y - t.ty;
    return CGPointMake((t.d * dx - t.c * dy) / det, (t.a * dy - t.b * dx) / det);
}



CGSize
CGContextConvertSizeToDeviceSpace(CGContextRef c, CGSize s)
{
    return c ? CGSizeApplyAffineTransform(s, user_to_device(c)) : s;
}

CGSize
CGContextConvertSizeToUserSpace(CGContextRef c, CGSize s)
{
    return c ? CGSizeApplyAffineTransform(s, CGAffineTransformInvert(user_to_device(c))) : s;
}

CGRect
CGContextConvertRectToDeviceSpace(CGContextRef c, CGRect r)
{
    return c ? CGRectApplyAffineTransform(r, user_to_device(c)) : r;
}

CGRect
CGContextConvertRectToUserSpace(CGContextRef c, CGRect r)
{
    return c ? CGRectApplyAffineTransform(r, CGAffineTransformInvert(user_to_device(c))) : r;
}

void CGContextSetLineWidth(CGContextRef c, CGFloat w) { if (c && w >= 0) CGContextState(c).line_width = w; }
void CGContextSetLineCap(CGContextRef c, CGLineCap cap) { if (c) CGContextState(c).cap = cap; }
void CGContextSetLineJoin(CGContextRef c, CGLineJoin join) { if (c) CGContextState(c).join = join; }
void CGContextSetMiterLimit(CGContextRef c, CGFloat limit) { if (c) CGContextState(c).miter_limit = limit; }
void CGContextSetFlatness(CGContextRef c, CGFloat f) { if (c) CGContextState(c).flatness = f; }
void CGContextSetAlpha(CGContextRef c, CGFloat a) { if (c) CGContextState(c).alpha = fmin(1, fmax(0, a)); }
void CGContextSetBlendMode(CGContextRef c, CGBlendMode mode) { if (c) CGContextState(c).blend = mode; }
void CGContextSetRenderingIntent(CGContextRef c, CGColorRenderingIntent i) { if (c) CGContextState(c).intent = i; }
void CGContextSetShouldAntialias(CGContextRef c, bool v) { if (c) CGContextState(c).antialias = v; }
void CGContextSetAllowsAntialiasing(CGContextRef c, bool v) { if (c) CGContextState(c).allows_antialias = v; }
void CGContextSetShouldSmoothFonts(CGContextRef c, bool v) { if (c) CGContextState(c).smooth_fonts = v; }
void CGContextSetAllowsFontSmoothing(CGContextRef c, bool v) { if (c) CGContextState(c).allows_smoothing = v; }
void CGContextSetShouldSubpixelPositionFonts(CGContextRef c, bool v) { if (c) CGContextState(c).subpixel_position = v; }
void CGContextSetAllowsFontSubpixelPositioning(CGContextRef c, bool v) { if (c) CGContextState(c).allows_subpixel_position = v; }
void CGContextSetShouldSubpixelQuantizeFonts(CGContextRef c, bool v) { if (c) CGContextState(c).subpixel_quantize = v; }
void CGContextSetAllowsFontSubpixelQuantization(CGContextRef c, bool v) { if (c) CGContextState(c).allows_subpixel_quantize = v; }

void
CGContextSetInterpolationQuality(CGContextRef c, CGInterpolationQuality q)
{
    if (c)
        CGContextState(c).interpolation = q;
}

CGInterpolationQuality
CGContextGetInterpolationQuality(CGContextRef c)
{
    return c ? CGContextState(c).interpolation : kCGInterpolationDefault;
}

void
CGContextSetLineDash(CGContextRef c, CGFloat phase, const CGFloat *lengths, size_t count)
{
    if (!c)
        return;
    CGGState &g = CGContextState(c);
    g.dash_phase = phase;
    g.dashes.assign(lengths, lengths ? lengths + count : lengths);
}

void
CGContextSetShadowWithColor(CGContextRef c, CGSize offset, CGFloat blur, CGColorRef color)
{
    if (!c)
        return;
    CGGState &g = CGContextState(c);
    g.shadow_offset = offset;
    g.shadow_blur = fmax(0, blur);
    if (g.shadow_color)
        CFRelease(g.shadow_color);
    g.shadow_color = color ? (CGColorRef)CFRetain(color) : NULL;
}

void
CGContextSetShadow(CGContextRef c, CGSize offset, CGFloat blur)
{
    /* black with 1/3 alpha, as Apple's */
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGFloat v[2] = {0, 1.0 / 3};
    CGColorRef color = CGColorCreate(gray, v);
    CGContextSetShadowWithColor(c, offset, blur, color);
    CFRelease(color);
    CFRelease(gray);
}

void CGContextSetPatternPhase(CGContextRef c, CGSize phase) { if (c) CGContextState(c).pattern_phase = phase; }
bool CGContextSetEDRTargetHeadroom(CGContextRef c, float headroom) { return false; }
float CGContextGetEDRTargetHeadroom(CGContextRef c) { return 1; }

#pragma mark - Colours

static void
set_color(CGColorRef *slot, CGColorRef color)
{
    if (!color)
        return;
    CFRetain(color);
    if (*slot)
        CFRelease(*slot);
    *slot = color;
}

void CGContextSetFillColorWithColor(CGContextRef c, CGColorRef color) { if (c) set_color(&CGContextState(c).fill, color); }
void CGContextSetStrokeColorWithColor(CGContextRef c, CGColorRef color) { if (c) set_color(&CGContextState(c).stroke, color); }

static void
set_space(CGColorRef *slot, CGColorSpaceRef space)
{
    if (!space)
        return;
    /* the initial colour of a space: 0 for each component (1 for CMYK's... no: black), alpha 1 */
    CGFloat v[CG_COLOR_MAX_COMPONENTS] = {0};
    size_t n = CGColorSpaceGetNumberOfComponents(space);
    if (CGColorSpaceGetModel(space) == kCGColorSpaceModelCMYK)
        v[3] = 1;
    v[n] = 1;
    CGColorRef color = space->kind == CG_SPACE_PATTERN ? NULL : CGColorCreate(space, v);
    if (color) {
        set_color(slot, color);
        CFRelease(color);
    }
}

static void
remember_pattern_space(CGColorSpaceRef *slot, CGColorSpaceRef s)
{
    if (*slot)
        CFRelease(*slot);
    *slot = s && s->kind == CG_SPACE_PATTERN ? (CGColorSpaceRef)CFRetain(s) : NULL;
}

void
CGContextSetFillColorSpace(CGContextRef c, CGColorSpaceRef s)
{
    if (!c || !s)
        return;
    remember_pattern_space(&CGContextState(c).fill_pattern_space, s);
    set_space(&CGContextState(c).fill, s);
}

void
CGContextSetStrokeColorSpace(CGContextRef c, CGColorSpaceRef s)
{
    if (!c || !s)
        return;
    remember_pattern_space(&CGContextState(c).stroke_pattern_space, s);
    set_space(&CGContextState(c).stroke, s);
}

static void
set_components(CGColorRef *slot, const CGFloat *v)
{
    if (!v || !*slot)
        return;
    CGColorRef color = CGColorCreate(CGColorGetColorSpace(*slot), v);
    if (color) {
        set_color(slot, color);
        CFRelease(color);
    }
}

void CGContextSetFillColor(CGContextRef c, const CGFloat *v) { if (c) set_components(&CGContextState(c).fill, v); }
void CGContextSetStrokeColor(CGContextRef c, const CGFloat *v) { if (c) set_components(&CGContextState(c).stroke, v); }

static void
set_device(CGColorRef *slot, CGColorSpaceRef (*make)(void), const CGFloat *v)
{
    CGColorSpaceRef s = make();
    CGColorRef color = CGColorCreate(s, v);
    set_color(slot, color);
    CFRelease(color);
    CFRelease(s);
}

void
CGContextSetGrayFillColor(CGContextRef c, CGFloat gray, CGFloat alpha)
{
    CGFloat v[2] = {gray, alpha};
    if (c)
        set_device(&CGContextState(c).fill, CGColorSpaceCreateDeviceGray, v);
}

void
CGContextSetGrayStrokeColor(CGContextRef c, CGFloat gray, CGFloat alpha)
{
    CGFloat v[2] = {gray, alpha};
    if (c)
        set_device(&CGContextState(c).stroke, CGColorSpaceCreateDeviceGray, v);
}

void
CGContextSetRGBFillColor(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    CGFloat v[4] = {r, g, b, a};
    if (c)
        set_device(&CGContextState(c).fill, CGColorSpaceCreateDeviceRGB, v);
}

void
CGContextSetRGBStrokeColor(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    CGFloat v[4] = {r, g, b, a};
    if (c)
        set_device(&CGContextState(c).stroke, CGColorSpaceCreateDeviceRGB, v);
}

void
CGContextSetCMYKFillColor(CGContextRef c, CGFloat cy, CGFloat m, CGFloat y, CGFloat k, CGFloat a)
{
    CGFloat v[5] = {cy, m, y, k, a};
    if (c)
        set_device(&CGContextState(c).fill, CGColorSpaceCreateDeviceCMYK, v);
}

void
CGContextSetCMYKStrokeColor(CGContextRef c, CGFloat cy, CGFloat m, CGFloat y, CGFloat k, CGFloat a)
{
    CGFloat v[5] = {cy, m, y, k, a};
    if (c)
        set_device(&CGContextState(c).stroke, CGColorSpaceCreateDeviceCMYK, v);
}

#pragma mark - The current path

void CGContextBeginPath(CGContextRef c)
{
    if (!c)
        return;
    CFRelease(c->path);
    c->path = CGPathCreateMutable();
}

void
CGContextMoveToPoint(CGContextRef c, CGFloat x, CGFloat y)
{
    if (c)
        CGPathMoveToPoint(c->path, &CGContextState(c).ctm, x, y);
}

void
CGContextAddLineToPoint(CGContextRef c, CGFloat x, CGFloat y)
{
    if (c)
        CGPathAddLineToPoint(c->path, &CGContextState(c).ctm, x, y);
}

void
CGContextAddCurveToPoint(CGContextRef c, CGFloat cp1x, CGFloat cp1y, CGFloat cp2x, CGFloat cp2y, CGFloat x, CGFloat y)
{
    if (c)
        CGPathAddCurveToPoint(c->path, &CGContextState(c).ctm, cp1x, cp1y, cp2x, cp2y, x, y);
}

void
CGContextAddQuadCurveToPoint(CGContextRef c, CGFloat cpx, CGFloat cpy, CGFloat x, CGFloat y)
{
    if (c)
        CGPathAddQuadCurveToPoint(c->path, &CGContextState(c).ctm, cpx, cpy, x, y);
}

void CGContextClosePath(CGContextRef c) { if (c) CGPathCloseSubpath(c->path); }
void CGContextAddRect(CGContextRef c, CGRect r) { if (c) CGPathAddRect(c->path, &CGContextState(c).ctm, r); }

void
CGContextAddRects(CGContextRef c, const CGRect *rects, size_t count)
{
    if (c)
        CGPathAddRects(c->path, &CGContextState(c).ctm, rects, count);
}

void
CGContextAddLines(CGContextRef c, const CGPoint *points, size_t count)
{
    if (c)
        CGPathAddLines(c->path, &CGContextState(c).ctm, points, count);
}

void CGContextAddEllipseInRect(CGContextRef c, CGRect r) { if (c) CGPathAddEllipseInRect(c->path, &CGContextState(c).ctm, r); }

void
CGContextAddArc(CGContextRef c, CGFloat x, CGFloat y, CGFloat radius, CGFloat start, CGFloat end, int clockwise)
{
    /* the context's "clockwise" is in its flipped device sense */
    if (c)
        CGPathAddArc(c->path, &CGContextState(c).ctm, x, y, radius, start, end, clockwise != 0);
}

void
CGContextAddArcToPoint(CGContextRef c, CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, CGFloat radius)
{
    if (c)
        CGPathAddArcToPoint(c->path, &CGContextState(c).ctm, x1, y1, x2, y2, radius);
}

void
CGContextAddPath(CGContextRef c, CGPathRef path)
{
    if (c && path)
        CGPathAddPath(c->path, &CGContextState(c).ctm, path);
}

bool
CGContextIsPathEmpty(CGContextRef c)
{
    return !c || CGPathIsEmpty(c->path);
}

/* The current path in user space. */
static CGPathRef
user_path(CGContextRef c)
{
    CGAffineTransform inv = CGAffineTransformInvert(CGContextState(c).ctm);
    return CGPathCreateCopyByTransformingPath(c->path, &inv);
}

CGPoint
CGContextGetPathCurrentPoint(CGContextRef c)
{
    if (!c || CGPathIsEmpty(c->path))
        return CGPointZero;
    return CGPointApplyAffineTransform(CGPathGetCurrentPoint(c->path), CGAffineTransformInvert(CGContextState(c).ctm));
}

CGRect
CGContextGetPathBoundingBox(CGContextRef c)
{
    if (!c || CGPathIsEmpty(c->path))
        return CGRectNull;
    CGPathRef p = user_path(c);
    CGRect r = CGPathGetBoundingBox(p);
    CFRelease(p);
    return r;
}

CGPathRef
CGContextCopyPath(CGContextRef c)
{
    return c ? user_path(c) : NULL;
}

/* The paint a stroke of the current state uses (user-space geometry). */
static void
stroke_paint(CGContextRef c, SkPaint &paint)
{
    CGGState &g = CGContextState(c);
    paint.setStyle(SkPaint::kStroke_Style);
    paint.setStrokeWidth((float)g.line_width);
    paint.setStrokeMiter((float)g.miter_limit);
    paint.setStrokeCap(g.cap == kCGLineCapRound ? SkPaint::kRound_Cap
                       : g.cap == kCGLineCapSquare ? SkPaint::kSquare_Cap : SkPaint::kButt_Cap);
    paint.setStrokeJoin(g.join == kCGLineJoinRound ? SkPaint::kRound_Join
                        : g.join == kCGLineJoinBevel ? SkPaint::kBevel_Join : SkPaint::kMiter_Join);
    if (!g.dashes.empty()) {
        std::vector<float> intervals;
        bool any = false;
        for (CGFloat d : g.dashes)
            intervals.push_back((float)d), any |= d > 0;
        if (intervals.size() % 2)
            intervals.insert(intervals.end(), intervals.begin(), intervals.end());
        if (any)
            paint.setPathEffect(SkDashPathEffect::Make(intervals, (float)g.dash_phase));
    }
}

void
CGContextReplacePathWithStrokedPath(CGContextRef c)
{
    if (!c || CGPathIsEmpty(c->path))
        return;
    CGPathRef up = user_path(c);
    SkPath src = CGSkPath(up, NULL, false), dst;
    CFRelease(up);
    SkPaint paint;
    stroke_paint(c, paint);
    if (CGContextState(c).line_width == 0)
        paint.setStrokeWidth(0.0001f);
    dst = skpathutils::FillPathWithPaint(src, paint);
    CGMutablePathRef stroked = CGPathFromSkPath(dst);
    CFRelease(c->path);
    c->path = CGPathCreateMutable();
    CGPathAddPath(c->path, &CGContextState(c).ctm, stroked);
    CFRelease(stroked);
}

bool
CGContextPathContainsPoint(CGContextRef c, CGPoint point, CGPathDrawingMode mode)
{
    if (!c || CGPathIsEmpty(c->path))
        return false;
    CGPoint p = CGPointApplyAffineTransform(point, CGContextState(c).ctm);
    bool eo = mode == kCGPathEOFill || mode == kCGPathEOFillStroke;
    bool fill = mode != kCGPathStroke;
    if (fill && CGPathContainsPoint(c->path, NULL, p, eo))
        return true;
    if (mode == kCGPathStroke || mode == kCGPathFillStroke || mode == kCGPathEOFillStroke) {
        CGPathRef up = user_path(c);
        SkPaint paint;
        stroke_paint(c, paint);
        SkPath stroked = skpathutils::FillPathWithPaint(CGSkPath(up, NULL, false), paint);
        CFRelease(up);
        return stroked.contains((float)point.x, (float)point.y);
    }
    return false;
}

#pragma mark - Painting

static SkBlendMode
sk_blend(CGBlendMode m)
{
    switch (m) {
    case kCGBlendModeMultiply: return SkBlendMode::kMultiply;
    case kCGBlendModeScreen: return SkBlendMode::kScreen;
    case kCGBlendModeOverlay: return SkBlendMode::kOverlay;
    case kCGBlendModeDarken: return SkBlendMode::kDarken;
    case kCGBlendModeLighten: return SkBlendMode::kLighten;
    case kCGBlendModeColorDodge: return SkBlendMode::kColorDodge;
    case kCGBlendModeColorBurn: return SkBlendMode::kColorBurn;
    case kCGBlendModeSoftLight: return SkBlendMode::kSoftLight;
    case kCGBlendModeHardLight: return SkBlendMode::kHardLight;
    case kCGBlendModeDifference: return SkBlendMode::kDifference;
    case kCGBlendModeExclusion: return SkBlendMode::kExclusion;
    case kCGBlendModeHue: return SkBlendMode::kHue;
    case kCGBlendModeSaturation: return SkBlendMode::kSaturation;
    case kCGBlendModeColor: return SkBlendMode::kColor;
    case kCGBlendModeLuminosity: return SkBlendMode::kLuminosity;
    case kCGBlendModeClear: return SkBlendMode::kClear;
    case kCGBlendModeCopy: return SkBlendMode::kSrc;
    case kCGBlendModeSourceIn: return SkBlendMode::kSrcIn;
    case kCGBlendModeSourceOut: return SkBlendMode::kSrcOut;
    case kCGBlendModeSourceAtop: return SkBlendMode::kSrcATop;
    case kCGBlendModeDestinationOver: return SkBlendMode::kDstOver;
    case kCGBlendModeDestinationIn: return SkBlendMode::kDstIn;
    case kCGBlendModeDestinationOut: return SkBlendMode::kDstOut;
    case kCGBlendModeDestinationAtop: return SkBlendMode::kDstATop;
    case kCGBlendModeXOR: return SkBlendMode::kXor;
    case kCGBlendModePlusLighter: return SkBlendMode::kPlus;
    case kCGBlendModePlusDarker: return SkBlendMode::kMultiply;  /* approximation */
    default: return SkBlendMode::kSrcOver;
    }
}

/* A colour's components in the context's drawing space, plus alpha. */
CG_PRIVATE SkColor4f
CGContextColor(CGContextRef c, CGColorRef color)
{
    if (!c->draw_space)
        return SkColor4f{0, 0, 0, (float)CGColorGetAlpha(color)};
    CGFloat out[CG_COLOR_MAX_COMPONENTS];
    CGColorSpaceConvertComponents(color->space, color->comps, c->draw_space, out);
    CGFloat a = color->comps[color->n - 1];
    if (CGColorSpaceGetModel(c->draw_space) == kCGColorSpaceModelMonochrome)
        return SkColor4f{(float)out[0], (float)out[0], (float)out[0], (float)a};
    return SkColor4f{(float)out[0], (float)out[1], (float)out[2], (float)a};
}

SkColor4f
CGContextConvertComponents(CGContextRef c, CGColorSpaceRef space, const CGFloat *v)
{
    size_t n = CGColorSpaceGetNumberOfComponents(space);
    if (!c->draw_space)
        return SkColor4f{0, 0, 0, (float)v[n]};
    CGFloat out[CG_COLOR_MAX_COMPONENTS];
    CGColorSpaceConvertComponents(space, v, c->draw_space, out);
    if (CGColorSpaceGetModel(c->draw_space) == kCGColorSpaceModelMonochrome)
        return SkColor4f{(float)out[0], (float)out[0], (float)out[0], (float)v[n]};
    return SkColor4f{(float)out[0], (float)out[1], (float)out[2], (float)v[n]};
}

CGAffineTransform
CGContextUserToDevice(CGContextRef c)
{
    return user_to_device(c);
}

CG_PRIVATE sk_sp<SkShader> CGPatternShader(CGContextRef c, CGColorRef color, const CGAffineTransform &to_canvas);
CG_PRIVATE void CGPatternDrawCells(CGContextRef c, CGColorRef color, const SkPath &path, const SkPaint &paint,
                                   const CGAffineTransform &default_to_canvas);

/*
 * The paint for a colour: `default_to_canvas` maps the default user space
 * to the space the canvas will draw in (identity when filling in the
 * default user space), which places pattern cells.
 */
static void
base_paint(CGContextRef c, SkPaint &paint, CGColorRef color,
           const CGAffineTransform &default_to_canvas = CGAffineTransformIdentity)
{
    CGGState &g = CGContextState(c);
    if (color && CGColorGetPattern(color)) {
        paint.setColor(SkColor4f{0, 0, 0, (float)g.alpha});
        paint.setShader(CGPatternShader(c, color, default_to_canvas));
    } else {
        SkColor4f col = color ? CGContextColor(c, color) : SkColor4f{0, 0, 0, 1};
        col.fA *= (float)g.alpha;
        paint.setColor(col, c->skspace ? c->skspace->get() : nullptr);
    }
    paint.setBlendMode(sk_blend(g.blend));
    paint.setAntiAlias(g.antialias && g.allows_antialias);
}

/*
 * Bracket a drawing operation: pick the device bounds it can touch (for
 * contexts drawing into a work buffer), and apply the state's shadow as a
 * layer. The shadow's offset and blur are in the default user space, not
 * affected by the CTM.
 */
namespace {
struct Op {
    CGContextRef c;
    SkIRect bounds;
    bool layer = false;

    Op(CGContextRef ctx, SkRect device) : c(ctx)
    {
        CGGState &g = CGContextState(c);
        SkRect r = device;
        if (g.shadow_color && CGColorGetAlpha(g.shadow_color) > 0) {
            SkRect s = device.makeOffset((float)g.shadow_offset.width, (float)-g.shadow_offset.height);
            float out = (float)(3 * g.shadow_blur / 2 + 1);
            s.outset(out, out);
            r.join(s);
        }
        r.outset(2, 2);
        bounds = r.roundOut();
        if (!bounds.intersect(SkIRect::MakeWH((int)c->width, (int)c->height)))
            bounds = SkIRect::MakeEmpty();
        if (c->work && !bounds.isEmpty())
            CGContextSyncFromClient(c, bounds);
        if (g.shadow_color && CGColorGetAlpha(g.shadow_color) > 0) {
            SkPaint lp;
            SkColor4f sc = CGContextColor(c, g.shadow_color);
            sc.fA *= (float)g.alpha;
            float sigma = (float)(g.shadow_blur / 2);
            lp.setImageFilter(SkImageFilters::DropShadow((float)g.shadow_offset.width, (float)-g.shadow_offset.height,
                                                         sigma, sigma, sc, c->skspace ? *c->skspace : nullptr,
                                                         nullptr));
            c->canvas->save();
            c->canvas->resetMatrix();
            c->canvas->saveLayer(nullptr, &lp);
            layer = true;
        }
    }
    ~Op()
    {
        if (layer) {
            c->canvas->restore();
            c->canvas->restore();
        }
        if (c->work && !bounds.isEmpty())
            CGContextSyncToClient(c, bounds);
    }
};
}  // namespace

static SkRect
device_bounds(CGContextRef c, const SkPath &path, const SkMatrix &m, float stroke)
{
    SkRect r = path.getBounds();
    r.outset(stroke, stroke);
    return m.mapRect(r);
}

/*
 * Without antialiasing, Apple's CG fills every pixel the shape touches at
 * all (not only those whose centres it covers). Coverage is rendered at 4x
 * with antialiasing, and a pixel is in if any of its 16 subpixels is; the
 * result is painted through that mask with the paint's colour, alpha and
 * blend mode.
 */
static void
draw_covering(CGContextRef c, const SkPath &path, SkPaint paint, const SkRect &device_bounds)
{
    if (paint.isAntiAlias()) {
        c->canvas->drawPath(path, paint);
        return;
    }
    SkIRect b = device_bounds.roundOut();
    if (!b.intersect(SkIRect::MakeWH((int)c->width, (int)c->height)))
        return;
    const int S = 4;
    SkBitmap hi;
    hi.allocPixels(SkImageInfo::MakeA8(b.width() * S, b.height() * S));
    hi.eraseColor(SK_ColorTRANSPARENT);
    SkCanvas hc(hi);
    SkMatrix m = c->canvas->getTotalMatrix();
    m.postTranslate((float)-b.left(), (float)-b.top());
    m.postScale(S, S);
    hc.setMatrix(m);
    SkPaint cover = paint;
    cover.setAntiAlias(true);
    cover.setColor(SK_ColorBLACK);
    cover.setBlendMode(SkBlendMode::kSrcOver);
    hc.drawPath(path, cover);
    SkBitmap mask;
    mask.allocPixels(SkImageInfo::MakeA8(b.width(), b.height()));
    for (int y = 0; y < b.height(); y++)
        for (int x = 0; x < b.width(); x++) {
            bool any = false;
            for (int sy = 0; sy < S && !any; sy++)
                for (int sx = 0; sx < S && !any; sx++)
                    any = *hi.getAddr8(x * S + sx, y * S + sy) != 0;
            *mask.getAddr8(x, y) = any ? 255 : 0;
        }
    mask.setImmutable();
    SkPaint fill = paint;
    fill.setStyle(SkPaint::kFill_Style);
    fill.setPathEffect(nullptr);
    c->canvas->save();
    c->canvas->resetMatrix();
    c->canvas->drawImage(mask.asImage(), (float)b.left(), (float)b.top(), SkSamplingOptions(), &fill);
    c->canvas->restore();
}

static void
draw_path(CGContextRef c, CGPathDrawingMode mode)
{
    if (!c->canvas || CGPathIsEmpty(c->path))
        return;
    CGGState &g = CGContextState(c);
    bool eo = mode == kCGPathEOFill || mode == kCGPathEOFillStroke;
    bool fill = mode == kCGPathFill || mode == kCGPathEOFill || mode == kCGPathFillStroke || mode == kCGPathEOFillStroke;
    bool stroke = mode == kCGPathStroke || mode == kCGPathFillStroke || mode == kCGPathEOFillStroke;
    SkMatrix base = CGSkMatrix(c->base_ctm), user = CGSkMatrix(user_to_device(c));
    SkPath fill_path = CGSkPath(c->path, NULL, eo);
    SkPath stroke_path;
    CGAffineTransform inv = CGAffineTransformInvert(g.ctm);
    bool singular = g.ctm.a * g.ctm.d - g.ctm.b * g.ctm.c == 0;
    if (stroke && !singular)
        stroke_path = CGSkPath(c->path, &inv, false);
    SkRect bounds = device_bounds(c, fill_path, base, 0);
    if (stroke && !singular) {
        float w = (float)(g.line_width * fmax(1, g.miter_limit)) + 1;
        bounds.join(device_bounds(c, stroke_path, user, w));
    }
    Op op(c, bounds);
    if (fill) {
        SkPaint paint;
        base_paint(c, paint, g.fill);
        c->canvas->setMatrix(base);
        if (CGColorGetPattern(g.fill))
            CGPatternDrawCells(c, g.fill, fill_path, paint, CGAffineTransformIdentity);
        else
            draw_covering(c, fill_path, paint, bounds);
    }
    if (stroke && !singular) {
        SkPaint paint;
        base_paint(c, paint, g.stroke, inv);
        stroke_paint(c, paint);
        c->canvas->setMatrix(user);
        if (CGColorGetPattern(g.stroke)) {
            SkPath outline = skpathutils::FillPathWithPaint(stroke_path, paint);
            CGPatternDrawCells(c, g.stroke, outline, paint, inv);
        } else {
            draw_covering(c, stroke_path, paint, bounds);
        }
    }
}

void
CGContextDrawPath(CGContextRef c, CGPathDrawingMode mode)
{
    if (!c)
        return;
    draw_path(c, mode);
    CGContextBeginPath(c);
}

void CGContextFillPath(CGContextRef c) { CGContextDrawPath(c, kCGPathFill); }
void CGContextEOFillPath(CGContextRef c) { CGContextDrawPath(c, kCGPathEOFill); }
void CGContextStrokePath(CGContextRef c) { CGContextDrawPath(c, kCGPathStroke); }

/* Draw a path without touching the current one. */
static void
draw_temporary(CGContextRef c, CGPathRef user_space_path, CGPathDrawingMode mode)
{
    if (!c)
        return;
    CGMutablePathRef saved = c->path;
    c->path = CGPathCreateMutable();
    CGPathAddPath(c->path, &CGContextState(c).ctm, user_space_path);
    draw_path(c, mode);
    CFRelease(c->path);
    c->path = saved;
}

void
CGContextDrawUserPath(CGContextRef c, CGPathRef path, CGPathDrawingMode mode)
{
    draw_temporary(c, path, mode);
}

void
CGContextFillRect(CGContextRef c, CGRect r)
{
    CGPathRef p = CGPathCreateWithRect(r, NULL);
    draw_temporary(c, p, kCGPathFill);
    CFRelease(p);
}

void
CGContextFillRects(CGContextRef c, const CGRect *rects, size_t count)
{
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddRects(p, NULL, rects, count);
    draw_temporary(c, p, kCGPathFill);
    CFRelease(p);
}

/* From (maxX, minY) the other way round from CGPathAddRect, as Apple's (dashes show it). */
void
CGContextStrokeRect(CGContextRef c, CGRect r)
{
    r = CGRectStandardize(r);
    CGFloat x0 = r.origin.x, y0 = r.origin.y, x1 = x0 + r.size.width, y1 = y0 + r.size.height;
    CGPoint pts[4] = {{x1, y0}, {x0, y0}, {x0, y1}, {x1, y1}};
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddLines(p, NULL, pts, 4);
    CGPathCloseSubpath(p);
    draw_temporary(c, p, kCGPathStroke);
    CFRelease(p);
}

void
CGContextStrokeRectWithWidth(CGContextRef c, CGRect r, CGFloat width)
{
    if (!c)
        return;
    CGFloat saved = CGContextState(c).line_width;
    CGContextState(c).line_width = width;
    CGContextStrokeRect(c, r);
    CGContextState(c).line_width = saved;
}

void
CGContextClearRect(CGContextRef c, CGRect r)
{
    if (!c || !c->canvas)
        return;
    SkMatrix m = CGSkMatrix(user_to_device(c));
    SkRect rect = SkRect::MakeXYWH((float)r.origin.x, (float)r.origin.y, (float)r.size.width, (float)r.size.height);
    CGColorRef saved_shadow = CGContextState(c).shadow_color;
    CGContextState(c).shadow_color = NULL;
    {
        Op op(c, m.mapRect(rect));
        SkPaint paint;
        paint.setBlendMode(SkBlendMode::kClear);
        paint.setAntiAlias(CGContextState(c).antialias && CGContextState(c).allows_antialias);
        c->canvas->setMatrix(m);
        c->canvas->drawRect(rect, paint);
    }
    CGContextState(c).shadow_color = saved_shadow;
}

void
CGContextFillEllipseInRect(CGContextRef c, CGRect r)
{
    CGPathRef p = CGPathCreateWithEllipseInRect(r, NULL);
    draw_temporary(c, p, kCGPathFill);
    CFRelease(p);
}

void
CGContextStrokeEllipseInRect(CGContextRef c, CGRect r)
{
    CGPathRef p = CGPathCreateWithEllipseInRect(r, NULL);
    draw_temporary(c, p, kCGPathStroke);
    CFRelease(p);
}

void
CGContextStrokeLineSegments(CGContextRef c, const CGPoint *points, size_t count)
{
    CGMutablePathRef p = CGPathCreateMutable();
    for (size_t i = 0; points && i + 1 < count; i += 2) {
        CGPathMoveToPoint(p, NULL, points[i].x, points[i].y);
        CGPathAddLineToPoint(p, NULL, points[i + 1].x, points[i + 1].y);
    }
    draw_temporary(c, p, kCGPathStroke);
    CFRelease(p);
}

void
CGContextPaintShader(CGContextRef c, sk_sp<SkShader> shader)
{
    if (!c || !c->canvas || !shader)
        return;
    CGGState &g = CGContextState(c);
    Op op(c, SkRect::MakeWH((float)c->width, (float)c->height));
    SkPaint paint;
    paint.setShader(std::move(shader));
    paint.setAlphaf((float)g.alpha);
    paint.setBlendMode(sk_blend(g.blend));
    paint.setDither(false);
    c->canvas->setMatrix(CGSkMatrix(user_to_device(c)));
    c->canvas->drawPaint(paint);
}

#pragma mark - Clipping

static void
clip_device_rect(CGContextRef c, CGRect device)
{
    CGGState &g = CGContextState(c);
    g.clip = CGRectIntersection(g.clip, device);
}

static void
clip_path(CGContextRef c, bool eo)
{
    if (CGPathIsEmpty(c->path)) {
        clip_device_rect(c, CGRectNull);
        if (c->canvas) {
            c->canvas->resetMatrix();
            c->canvas->clipRect(SkRect::MakeEmpty());
        }
        return;
    }
    clip_device_rect(c, CGPathGetPathBoundingBox(c->path));
    if (c->canvas) {
        CGGState &g = CGContextState(c);
        c->canvas->setMatrix(CGSkMatrix(c->base_ctm));
        c->canvas->clipPath(CGSkPath(c->path, NULL, eo), g.antialias && g.allows_antialias);
    }
}

void
CGContextClip(CGContextRef c)
{
    if (!c)
        return;
    clip_path(c, false);
    CGContextBeginPath(c);
}

void
CGContextEOClip(CGContextRef c)
{
    if (!c)
        return;
    clip_path(c, true);
    CGContextBeginPath(c);
}

void
CGContextClipToUserPath(CGContextRef c, CGPathRef path, bool evenOdd)
{
    if (!c)
        return;
    CGMutablePathRef saved = c->path;
    c->path = CGPathCreateMutable();
    if (path)
        CGPathAddPath(c->path, &CGContextState(c).ctm, path);
    clip_path(c, evenOdd);
    CFRelease(c->path);
    c->path = saved;
}

void
CGContextClipToRect(CGContextRef c, CGRect r)
{
    if (!c)
        return;
    CGMutablePathRef saved = c->path;
    c->path = CGPathCreateMutable();
    CGPathAddRect(c->path, &CGContextState(c).ctm, r);
    clip_path(c, false);
    CFRelease(c->path);
    c->path = saved;
}

void
CGContextClipToRects(CGContextRef c, const CGRect *rects, size_t count)
{
    if (!c)
        return;
    CGMutablePathRef saved = c->path;
    c->path = CGPathCreateMutable();
    CGPathAddRects(c->path, &CGContextState(c).ctm, rects, count);
    clip_path(c, false);
    CFRelease(c->path);
    c->path = saved;
}

void
CGContextResetClip(CGContextRef c)
{
    if (!c)
        return;
    CGContextState(c).clip = CGRectMake(0, 0, c->width, c->height);
    if (c->canvas)
        SkCanvasPriv::ResetClip(c->canvas);
}

CGRect
CGContextGetClipBoundingBox(CGContextRef c)
{
    if (!c)
        return CGRectNull;
    CGRect clip = CGContextState(c).clip;
    if (CGRectIsNull(clip) || CGRectIsEmpty(clip))
        return CGRectNull;
    return CGRectApplyAffineTransform(clip, CGAffineTransformInvert(CGContextState(c).ctm));
}

/* Image drawn upright into `rect` (user space): the image's first row at the top. */
static SkMatrix
image_matrix(CGContextRef c, CGRect rect, CGFloat w, CGFloat h)
{
    CGAffineTransform t = CGAffineTransformMake(rect.size.width / w, 0, 0, -rect.size.height / h, rect.origin.x,
                                                rect.origin.y + rect.size.height);
    return CGSkMatrix(CGAffineTransformConcat(t, user_to_device(c)));
}

static SkSamplingOptions
sampling(CGContextRef c, CGImageRef image)
{
    CGInterpolationQuality q = CGContextState(c).interpolation;
    if (q == kCGInterpolationNone || (image && !image->interpolate && q == kCGInterpolationDefault))
        return SkSamplingOptions(SkFilterMode::kNearest);
    if (q == kCGInterpolationLow)
        return SkSamplingOptions(SkFilterMode::kLinear);
    if (q == kCGInterpolationHigh)
        return SkSamplingOptions(SkCubicResampler::Mitchell());
    return SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear);
}

void
CGContextClipToMask(CGContextRef c, CGRect rect, CGImageRef mask)
{
    if (!c || !mask)
        return;
    clip_device_rect(c, CGRectApplyAffineTransform(rect, CGContextState(c).ctm));
    if (!c->canvas)
        return;
    sk_sp<SkImage> image = CGImageGetSkImage(mask);
    if (!image)
        return;
    /* an image mask paints where samples are 0; a gray image's samples are its alpha */
    SkMatrix m = image_matrix(c, rect, mask->width, mask->height);
    SkMatrix inv;
    if (!m.invert(&inv))
        return;
    sk_sp<SkShader> shader;
    if (mask->is_mask) {
        shader = image->makeShader(SkTileMode::kDecal, SkTileMode::kDecal, sampling(c, mask), &m);
    } else {
        /* the gray value becomes the alpha */
        float matrix[20] = {0};
        matrix[15] = 1;
        shader = image->makeShader(SkTileMode::kDecal, SkTileMode::kDecal, sampling(c, mask), &m)
                     ->makeWithColorFilter(SkColorFilters::Matrix(matrix));
    }
    c->canvas->resetMatrix();
    c->canvas->clipShader(shader);
}

#pragma mark - Images

CG_PRIVATE void
CGContextDrawSkImage(CGContextRef c, CGRect rect, CGImageRef image, sk_sp<SkImage> sk, bool tiled)
{
    if (!c->canvas || !sk)
        return;
    CGGState &g = CGContextState(c);
    SkMatrix m = image_matrix(c, rect, sk->width(), sk->height());
    SkPaint paint;
    base_paint(c, paint, image && image->is_mask ? g.fill : NULL);
    if (!(image && image->is_mask)) {
        SkColor4f col = {0, 0, 0, (float)g.alpha};
        paint.setColor(col);
    }
    SkRect dev = tiled ? SkRect::Make(SkIRect::MakeWH((int)c->width, (int)c->height))
                       : m.mapRect(SkRect::MakeIWH(sk->width(), sk->height()));
    Op op(c, dev);
    if (tiled) {
        paint.setShader(sk->makeShader(SkTileMode::kRepeat, SkTileMode::kRepeat, sampling(c, image), &m));
        c->canvas->resetMatrix();
        c->canvas->drawPaint(paint);
    } else {
        c->canvas->setMatrix(m);
        c->canvas->drawImage(sk, 0, 0, sampling(c, image), &paint);
    }
}

void
CGContextDrawImage(CGContextRef c, CGRect rect, CGImageRef image)
{
    if (!c || !image)
        return;
    CGContextDrawSkImage(c, CGRectStandardize(rect), image, CGImageGetSkImage(image), false);
}

void
CGContextDrawTiledImage(CGContextRef c, CGRect rect, CGImageRef image)
{
    if (!c || !image)
        return;
    CGContextDrawSkImage(c, CGRectStandardize(rect), image, CGImageGetSkImage(image), true);
}

bool
CGContextDrawImageApplyingToneMapping(CGContextRef c, CGRect r, CGImageRef image, CGToneMapping method,
                                      CFDictionaryRef options)
{
    CGContextDrawImage(c, r, image);
    return true;
}

#pragma mark - Transparency layers

void
CGContextBeginTransparencyLayerWithRect(CGContextRef c, CGRect rect, CFDictionaryRef auxInfo)
{
    if (!c)
        return;
    CGGState &g = CGContextState(c);
    SkPaint lp;
    lp.setAlphaf((float)g.alpha);
    lp.setBlendMode(sk_blend(g.blend));
    if (g.shadow_color && CGColorGetAlpha(g.shadow_color) > 0) {
        SkColor4f sc = CGContextColor(c, g.shadow_color);
        float sigma = (float)(g.shadow_blur / 2);
        lp.setImageFilter(SkImageFilters::DropShadow((float)g.shadow_offset.width, (float)-g.shadow_offset.height,
                                                     sigma, sigma, sc, c->skspace ? *c->skspace : nullptr, nullptr));
    }
    if (c->work)
        CGContextSyncFromClient(c, SkIRect::MakeWH((int)c->width, (int)c->height));
    CGGState copy = g;
    gstate_retain(copy);
    copy.layer = true;
    copy.alpha = 1;
    copy.blend = kCGBlendModeNormal;
    if (copy.shadow_color)
        CFRelease(copy.shadow_color);
    copy.shadow_color = NULL;
    c->stack->push_back(copy);
    if (c->canvas) {
        c->canvas->save();
        c->canvas->resetMatrix();
        if (CGRectIsNull(rect) || CGRectIsInfinite(rect)) {
            c->canvas->saveLayer(nullptr, &lp);
        } else {
            SkRect b = CGSkMatrix(user_to_device(c)).mapRect(
                SkRect::MakeXYWH((float)rect.origin.x, (float)rect.origin.y, (float)rect.size.width, (float)rect.size.height));
            c->canvas->saveLayer(&b, &lp);
        }
    }
}

void
CGContextBeginTransparencyLayer(CGContextRef c, CFDictionaryRef auxInfo)
{
    CGContextBeginTransparencyLayerWithRect(c, CGRectNull, auxInfo);
}

void
CGContextEndTransparencyLayer(CGContextRef c)
{
    if (!c || c->stack->size() <= 1)
        return;
    /* pop gstates saved inside the layer, then the layer */
    while (c->stack->size() > 1 && !CGContextState(c).layer)
        CGContextRestoreGState(c);
    if (!CGContextState(c).layer)
        return;
    gstate_release(CGContextState(c));
    c->stack->pop_back();
    if (c->canvas) {
        c->canvas->restore();  /* the layer */
        c->canvas->restore();
    }
    if (c->work)
        CGContextSyncToClient(c, SkIRect::MakeWH((int)c->width, (int)c->height));
}

#pragma mark - Text state (drawing glyphs comes with CoreText)

void
CGContextSetTextMatrix(CGContextRef c, CGAffineTransform t)
{
    if (c)
        c->text_matrix = t;
}

CGAffineTransform
CGContextGetTextMatrix(CGContextRef c)
{
    return c ? c->text_matrix : CGAffineTransformIdentity;
}

void
CGContextSetTextPosition(CGContextRef c, CGFloat x, CGFloat y)
{
    if (c)
        c->text_matrix.tx = x, c->text_matrix.ty = y;
}

CGPoint
CGContextGetTextPosition(CGContextRef c)
{
    return c ? CGPointMake(c->text_matrix.tx, c->text_matrix.ty) : CGPointZero;
}

void CGContextSetCharacterSpacing(CGContextRef c, CGFloat s) { if (c) CGContextState(c).char_spacing = s; }
void CGContextSetTextDrawingMode(CGContextRef c, CGTextDrawingMode m) { if (c) CGContextState(c).text_mode = m; }
void CGContextSetFontSize(CGContextRef c, CGFloat size) { if (c) CGContextState(c).font_size = size; }

void
CGContextSetFont(CGContextRef c, CGFontRef font)
{
    if (!c || !font)
        return;
    CFRetain(font);
    if (CGContextState(c).font)
        CFRelease(CGContextState(c).font);
    CGContextState(c).font = font;
}
