/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGGradient, CGFunction and CGShading, and drawing them: Skia's linear,
 * two-point conical and sweep gradients. CG extends a gradient past either
 * end independently, which Skia's tile modes can't express, so the
 * gradient's domain is stretched far past each end that extends (holding
 * the end colour) and left transparent (decal) past the others.
 */
#include "CGContextInternal.h"
#include "include/effects/SkGradient.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <vector>

#pragma mark - CGGradient

struct CGGradient {
    CGRuntimeBase base;
    CGColorSpaceRef space;
    size_t count;
    CGFloat *locations;
    CGFloat *components;  /* count * (n + 1) */
    float headroom;
};

static void
gradient_finalize(CFTypeRef cf)
{
    struct CGGradient *g = (struct CGGradient *)cf;
    if (g->space)
        CFRelease(g->space);
    free(g->locations);
    free(g->components);
}

static CFStringRef
gradient_desc(CFTypeRef cf)
{
    return CGTypeCopyDescriptionPrefix(cf, "CGGradient");
}

static const CGRuntimeClass gradient_class = {
    0, "CGGradient", NULL, NULL, gradient_finalize, NULL, NULL, NULL, gradient_desc, NULL, NULL, 0,
};
static CFTypeID gradient_type;

CFTypeID
CGGradientGetTypeID(void)
{
    return CGTypeRegister(&gradient_class, &gradient_type);
}

static struct CGGradient *
gradient_new(CGColorSpaceRef space, size_t count)
{
    struct CGGradient *g = (struct CGGradient *)CGTypeCreateInstance(CGGradientGetTypeID(), sizeof(struct CGGradient));
    g->space = (CGColorSpaceRef)CFRetain(space);
    g->count = count;
    g->locations = (CGFloat *)calloc(count, sizeof(CGFloat));
    g->components = (CGFloat *)calloc(count * (space->n + 1), sizeof(CGFloat));
    g->headroom = 1;
    return g;
}

static void
fill_locations(struct CGGradient *g, const CGFloat *locations)
{
    for (size_t i = 0; i < g->count; i++)
        g->locations[i] = locations ? locations[i] : g->count > 1 ? (CGFloat)i / (g->count - 1) : 0;
}

CGGradientRef
CGGradientCreateWithColorComponents(CGColorSpaceRef space, const CGFloat *components, const CGFloat *locations,
                                    size_t count)
{
    if (!space || !components || !count || space->kind == CG_SPACE_PATTERN || space->kind == CG_SPACE_INDEXED)
        return NULL;
    struct CGGradient *g = gradient_new(space, count);
    memcpy(g->components, components, count * (space->n + 1) * sizeof(CGFloat));
    fill_locations(g, locations);
    return g;
}

CGGradientRef
CGGradientCreateWithContentHeadroom(float headroom, CGColorSpaceRef space, const CGFloat *components,
                                    const CGFloat *locations, size_t count)
{
    struct CGGradient *g = (struct CGGradient *)CGGradientCreateWithColorComponents(space, components, locations, count);
    if (g)
        g->headroom = headroom;
    return g;
}

CGGradientRef
CGGradientCreateWithColors(CGColorSpaceRef space, CFArrayRef colors, const CGFloat *locations)
{
    if (!colors || !CFArrayGetCount(colors))
        return NULL;
    CGColorSpaceRef target = space ? (CGColorSpaceRef)CFRetain(space) : CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    size_t count = (size_t)CFArrayGetCount(colors);
    struct CGGradient *g = gradient_new(target, count);
    size_t n = target->n;
    for (size_t i = 0; i < count; i++) {
        CGColorRef c = (CGColorRef)CFArrayGetValueAtIndex(colors, (CFIndex)i);
        CGColorSpaceConvertComponents(c->space, c->comps, target, g->components + i * (n + 1));
        g->components[i * (n + 1) + n] = c->comps[c->n - 1];
    }
    fill_locations(g, locations);
    CFRelease(target);
    return g;
}

CGGradientRef CGGradientRetain(CGGradientRef g) { return g ? (CGGradientRef)CFRetain(g) : NULL; }
void CGGradientRelease(CGGradientRef g) { if (g) CFRelease(g); }
float CGGradientGetContentHeadroom(CGGradientRef g) { return g ? g->headroom : 0; }

#pragma mark - CGFunction

struct CGFunction {
    CGRuntimeBase base;
    void *info;
    size_t domain_dim, range_dim;
    CGFloat *domain, *range;
    CGFunctionCallbacks callbacks;
};

static void
function_finalize(CFTypeRef cf)
{
    struct CGFunction *f = (struct CGFunction *)cf;
    if (f->callbacks.releaseInfo)
        f->callbacks.releaseInfo(f->info);
    free(f->domain);
    free(f->range);
}

static const CGRuntimeClass function_class = {
    0, "CGFunction", NULL, NULL, function_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID function_type;

CFTypeID
CGFunctionGetTypeID(void)
{
    return CGTypeRegister(&function_class, &function_type);
}

CGFunctionRef
CGFunctionCreate(void *info, size_t domainDimension, const CGFloat *domain, size_t rangeDimension, const CGFloat *range,
                 const CGFunctionCallbacks *callbacks)
{
    if (!callbacks || !callbacks->evaluate || (domainDimension && !domain) || callbacks->version != 0)
        return NULL;
    struct CGFunction *f = (struct CGFunction *)CGTypeCreateInstance(CGFunctionGetTypeID(), sizeof(struct CGFunction));
    f->info = info;
    f->domain_dim = domainDimension;
    f->range_dim = rangeDimension;
    if (domain) {
        f->domain = (CGFloat *)malloc(2 * domainDimension * sizeof(CGFloat));
        memcpy(f->domain, domain, 2 * domainDimension * sizeof(CGFloat));
    }
    if (range) {
        f->range = (CGFloat *)malloc(2 * rangeDimension * sizeof(CGFloat));
        memcpy(f->range, range, 2 * rangeDimension * sizeof(CGFloat));
    }
    f->callbacks = *callbacks;
    return f;
}

CGFunctionRef CGFunctionRetain(CGFunctionRef f) { return f ? (CGFunctionRef)CFRetain(f) : NULL; }
void CGFunctionRelease(CGFunctionRef f) { if (f) CFRelease(f); }

#pragma mark - CGShading

struct CGShading {
    CGRuntimeBase base;
    bool radial;
    CGColorSpaceRef space;
    CGPoint start, end;
    CGFloat start_radius, end_radius;
    CGFunctionRef function;
    bool extend_start, extend_end;
    float headroom;
};

static void
shading_finalize(CFTypeRef cf)
{
    struct CGShading *s = (struct CGShading *)cf;
    if (s->space)
        CFRelease(s->space);
    if (s->function)
        CFRelease(s->function);
}

static const CGRuntimeClass shading_class = {
    0, "CGShading", NULL, NULL, shading_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID shading_type;

CFTypeID
CGShadingGetTypeID(void)
{
    return CGTypeRegister(&shading_class, &shading_type);
}

static CGShadingRef
shading_new(bool radial, CGColorSpaceRef space, CGPoint start, CGFloat r0, CGPoint end, CGFloat r1, CGFunctionRef f,
            bool es, bool ee)
{
    if (!space || !f || space->kind == CG_SPACE_PATTERN || space->kind == CG_SPACE_INDEXED)
        return NULL;
    struct CGShading *s = (struct CGShading *)CGTypeCreateInstance(CGShadingGetTypeID(), sizeof(struct CGShading));
    s->radial = radial;
    s->space = (CGColorSpaceRef)CFRetain(space);
    s->start = start, s->end = end;
    s->start_radius = r0, s->end_radius = r1;
    s->function = (CGFunctionRef)CFRetain(f);
    s->extend_start = es, s->extend_end = ee;
    s->headroom = 1;
    return s;
}

CGShadingRef
CGShadingCreateAxial(CGColorSpaceRef space, CGPoint start, CGPoint end, CGFunctionRef f, bool es, bool ee)
{
    return shading_new(false, space, start, 0, end, 0, f, es, ee);
}

CGShadingRef
CGShadingCreateRadial(CGColorSpaceRef space, CGPoint start, CGFloat r0, CGPoint end, CGFloat r1, CGFunctionRef f, bool es,
                      bool ee)
{
    return shading_new(true, space, start, r0, end, r1, f, es, ee);
}

CGShadingRef
CGShadingCreateAxialWithContentHeadroom(float headroom, CGColorSpaceRef space, CGPoint start, CGPoint end,
                                        CGFunctionRef f, bool es, bool ee)
{
    struct CGShading *s = (struct CGShading *)CGShadingCreateAxial(space, start, end, f, es, ee);
    if (s)
        s->headroom = headroom;
    return s;
}

CGShadingRef
CGShadingCreateRadialWithContentHeadroom(float headroom, CGColorSpaceRef space, CGPoint start, CGFloat r0, CGPoint end,
                                         CGFloat r1, CGFunctionRef f, bool es, bool ee)
{
    struct CGShading *s = (struct CGShading *)CGShadingCreateRadial(space, start, r0, end, r1, f, es, ee);
    if (s)
        s->headroom = headroom;
    return s;
}

CGShadingRef CGShadingRetain(CGShadingRef s) { return s ? (CGShadingRef)CFRetain(s) : NULL; }
void CGShadingRelease(CGShadingRef s) { if (s) CFRelease(s); }
float CGShadingGetContentHeadroom(CGShadingRef s) { return s ? s->headroom : 0; }

#pragma mark - Drawing

namespace {
/* Colour stops in [0, 1], in the context's drawing space. */
struct Stops {
    std::vector<SkColor4f> colors;
    std::vector<float> pos;
};
}  // namespace

/*
 * CG interpolates in the gradient's colour space. When that isn't the
 * space the context draws in, interpolate there densely and convert each
 * sample, rather than converting the stops.
 */
static Stops
gradient_stops(CGContextRef c, CGGradientRef g)
{
    Stops s;
    size_t n = g->space->n;
    CGColorSpaceRef draw = c->draw_space;
    bool same = !draw || draw == g->space || (draw->named && draw->named == g->space->named) ||
                (draw->kind == CG_SPACE_DEVICE_RGB && g->space->kind == CG_SPACE_DEVICE_RGB);
    if (!same && g->count > 1) {
        std::vector<size_t> order(g->count);
        for (size_t i = 0; i < g->count; i++)
            order[i] = i;
        std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return g->locations[a] < g->locations[b]; });
        const int samples = 256;
        for (int i = 0; i < samples; i++) {
            double t = (double)i / (samples - 1);
            size_t k = 0;
            while (k + 1 < order.size() && g->locations[order[k + 1]] < t)
                k++;
            const CGFloat *a = g->components + order[k] * (n + 1);
            const CGFloat *b = g->components + order[k + 1 < order.size() ? k + 1 : k] * (n + 1);
            double la = g->locations[order[k]], lb = g->locations[order[k + 1 < order.size() ? k + 1 : k]];
            double f = lb > la ? fmin(1, fmax(0, (t - la) / (lb - la))) : 0;
            CGFloat v[CG_COLOR_MAX_COMPONENTS + 1];
            for (size_t j = 0; j <= n; j++)
                v[j] = a[j] + f * (b[j] - a[j]);
            s.colors.push_back(CGContextConvertComponents(c, g->space, v));
            s.pos.push_back((float)t);
        }
        return s;
    }
    std::vector<size_t> order(g->count);
    for (size_t i = 0; i < g->count; i++)
        order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return g->locations[a] < g->locations[b]; });
    for (size_t i : order) {
        s.colors.push_back(CGContextConvertComponents(c, g->space, g->components + i * (n + 1)));
        s.pos.push_back((float)fmin(1, fmax(0, g->locations[i])));
    }
    if (s.colors.size() == 1) {
        s.colors.push_back(s.colors[0]);
        s.pos = {0, 1};
    }
    return s;
}

static Stops
shading_stops(CGContextRef c, CGShadingRef sh)
{
    Stops s;
    CGFunctionRef f = sh->function;
    size_t n = sh->space->n;
    CGFloat d0 = f->domain ? f->domain[0] : 0, d1 = f->domain ? f->domain[1] : 1;
    const int samples = 256;
    for (int i = 0; i < samples; i++) {
        CGFloat t = (CGFloat)i / (samples - 1), in = d0 + t * (d1 - d0);
        CGFloat out[CG_COLOR_MAX_COMPONENTS + 1];
        for (size_t k = 0; k <= n; k++)
            out[k] = k == n ? 1 : 0;
        f->callbacks.evaluate(f->info, &in, out);
        if (f->range)
            for (size_t k = 0; k < f->range_dim && k <= n; k++)
                out[k] = fmin(f->range[2 * k + 1], fmax(f->range[2 * k], out[k]));
        if (f->range_dim < n + 1)
            out[n] = 1;
        s.colors.push_back(CGContextConvertComponents(c, sh->space, out));
        s.pos.push_back((float)t);
    }
    return s;
}

/* Stretch [0, 1] to [tmin, tmax], holding the end colours outside [0, 1]. */
static void
stretch(Stops &s, double tmin, double tmax)
{
    double span = tmax - tmin;
    for (float &p : s.pos)
        p = (float)((p - tmin) / span);
    if (tmin < 0) {
        s.colors.insert(s.colors.begin(), s.colors.front());
        s.pos.insert(s.pos.begin(), 0);
    }
    if (tmax > 1) {
        s.colors.push_back(s.colors.back());
        s.pos.push_back(1);
    }
}

/* How far past an end a gradient must extend to cover the context: in lengths of the gradient. */
static double
reach(CGContextRef c, CGPoint a, CGPoint b)
{
    CGAffineTransform t = CGContextUserToDevice(c);
    CGPoint da = CGPointApplyAffineTransform(a, t), db = CGPointApplyAffineTransform(b, t);
    double len = hypot(db.x - da.x, db.y - da.y);
    double diag = hypot((double)c->width, (double)c->height) * 2;
    return len > 0 ? diag / len + 2 : 1e4;
}

static sk_sp<SkShader>
linear_shader(CGContextRef c, Stops s, CGPoint p0, CGPoint p1, bool before, bool after)
{
    double k = reach(c, p0, p1);
    double tmin = before ? -k : 0, tmax = after ? 1 + k : 1;
    stretch(s, tmin, tmax);
    SkPoint pts[2] = {SkPoint::Make((float)(p0.x + tmin * (p1.x - p0.x)), (float)(p0.y + tmin * (p1.y - p0.y))),
                      SkPoint::Make((float)(p0.x + tmax * (p1.x - p0.x)), (float)(p0.y + tmax * (p1.y - p0.y)))};
    SkGradient grad(SkGradient::Colors(s.colors, s.pos, SkTileMode::kDecal, c->skspace ? *c->skspace : nullptr), {});
    return SkShaders::LinearGradient(pts, grad);
}

static sk_sp<SkShader>
radial_shader(CGContextRef c, Stops s, CGPoint c0, CGFloat r0, CGPoint c1, CGFloat r1, bool before, bool after)
{
    double dr = r1 - r0;
    double k = reach(c, CGPointZero, CGPointMake(fmax(fabs(dr), hypot(c1.x - c0.x, c1.y - c0.y)), 0));
    double tmin = 0, tmax = 1;
    if (before)
        tmin = dr > 0 ? fmax(-k, -r0 / dr) : -k;
    if (after)
        tmax = dr < 0 ? fmin(1 + k, -r0 / dr) : 1 + k;
    stretch(s, tmin, tmax);
    auto at = [&](double t) {
        return SkPoint::Make((float)(c0.x + t * (c1.x - c0.x)), (float)(c0.y + t * (c1.y - c0.y)));
    };
    float ra = (float)fmax(0, r0 + tmin * dr), rb = (float)fmax(0, r0 + tmax * dr);
    SkGradient grad(SkGradient::Colors(s.colors, s.pos, SkTileMode::kDecal, c->skspace ? *c->skspace : nullptr), {});
    return SkShaders::TwoPointConicalGradient(at(tmin), ra, at(tmax), rb, grad);
}

void
CGContextDrawLinearGradient(CGContextRef c, CGGradientRef g, CGPoint start, CGPoint end, CGGradientDrawingOptions options)
{
    if (!c || !g)
        return;
    CGContextPaintShader(c, linear_shader(c, gradient_stops(c, g), start, end,
                                          options & kCGGradientDrawsBeforeStartLocation,
                                          options & kCGGradientDrawsAfterEndLocation));
}

void
CGContextDrawRadialGradient(CGContextRef c, CGGradientRef g, CGPoint startCenter, CGFloat startRadius, CGPoint endCenter,
                            CGFloat endRadius, CGGradientDrawingOptions options)
{
    if (!c || !g)
        return;
    CGContextPaintShader(c, radial_shader(c, gradient_stops(c, g), startCenter, startRadius, endCenter, endRadius,
                                          options & kCGGradientDrawsBeforeStartLocation,
                                          options & kCGGradientDrawsAfterEndLocation));
}

void
CGContextDrawConicGradient(CGContextRef c, CGGradientRef g, CGPoint center, CGFloat angle)
{
    if (!c || !g)
        return;
    Stops s = gradient_stops(c, g);
    SkGradient grad(SkGradient::Colors(s.colors, s.pos, SkTileMode::kClamp, c->skspace ? *c->skspace : nullptr), {});
    /* a full turn from `angle`: rotate the sweep (Skia's doesn't wrap below its start angle) */
    SkMatrix rot = SkMatrix::RotateDeg((float)(angle * 180 / M_PI), SkPoint::Make((float)center.x, (float)center.y));
    CGContextPaintShader(c, SkShaders::SweepGradient(SkPoint::Make((float)center.x, (float)center.y), grad, &rot));
}

void
CGContextDrawShading(CGContextRef c, CGShadingRef sh)
{
    if (!c || !sh)
        return;
    Stops s = shading_stops(c, sh);
    if (sh->radial)
        CGContextPaintShader(c, radial_shader(c, s, sh->start, sh->start_radius, sh->end, sh->end_radius,
                                              sh->extend_start, sh->extend_end));
    else
        CGContextPaintShader(c, linear_shader(c, s, sh->start, sh->end, sh->extend_start, sh->extend_end));
}
