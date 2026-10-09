/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cg-draw-test: CoreGraphics drawing, compared with reference renders
 * made by Apple's CoreGraphics (cg-draw-reference.bin, written on macOS
 * with --write). Each scene prints one line: "ok", or what differs.
 *
 * Rasterizers antialias edges differently, so the comparison is exact
 * (within 2 levels of 255) only where the reference is flat (a pixel and
 * its 8 neighbours the same); on edges it bounds the mean difference and
 * the share of pixels that differ a lot.
 *
 *   finch-cg-draw-test [--no-path] [reference]
 *   finch-cg-draw-test --write reference     (on macOS, against Apple's CG)
 */
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

enum { FMT_RGBA, FMT_ARGB, FMT_BGRA, FMT_GRAY, FMT_GRAYA, FMT_RGBA16, FMT_RGBAF, FMT_CMYK, FMT_ALPHA };

typedef struct {
    int fmt;
    CGContextRef ctx;
    size_t w, h;
} Canvas;

static Canvas
canvas(int fmt, size_t w, size_t h)
{
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB(), gray = CGColorSpaceCreateDeviceGray();
    CGColorSpaceRef cmyk = CGColorSpaceCreateDeviceCMYK();
    Canvas c = {fmt, NULL, w, h};
    switch (fmt) {
    case FMT_RGBA: c.ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, rgb, kCGImageAlphaPremultipliedLast); break;
    case FMT_ARGB: c.ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, rgb, kCGImageAlphaPremultipliedFirst); break;
    case FMT_BGRA:
        c.ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, rgb, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        break;
    case FMT_GRAY: c.ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, gray, kCGImageAlphaNone); break;
    case FMT_GRAYA: c.ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, gray, kCGImageAlphaPremultipliedLast); break;
    case FMT_RGBA16: c.ctx = CGBitmapContextCreate(NULL, w, h, 16, 0, rgb, kCGImageAlphaPremultipliedLast); break;
    case FMT_RGBAF:
        c.ctx = CGBitmapContextCreate(NULL, w, h, 32, 0, rgb,
                                      kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents | kCGBitmapByteOrder32Little);
        break;
    case FMT_CMYK: c.ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cmyk, kCGImageAlphaNone); break;
    case FMT_ALPHA: c.ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, NULL, kCGImageAlphaOnly); break;
    }
    CGColorSpaceRelease(rgb), CGColorSpaceRelease(gray), CGColorSpaceRelease(cmyk);
    if (!c.ctx) {
        fprintf(stderr, "no context for format %d\n", fmt);
        exit(1);
    }
    return c;
}

/* The canvas as 8-bit RGBA (unpremultiplied colour is not needed: compare premultiplied). */
static unsigned char *
pixels(Canvas c)
{
    unsigned char *out = calloc(c.w * c.h, 4);
    const unsigned char *d = CGBitmapContextGetData(c.ctx);
    size_t bpr = CGBitmapContextGetBytesPerRow(c.ctx);
    for (size_t y = 0; y < c.h; y++)
        for (size_t x = 0; x < c.w; x++) {
            const unsigned char *p = d + y * bpr;
            unsigned char *o = out + 4 * (y * c.w + x);
            switch (c.fmt) {
            case FMT_RGBA: memcpy(o, p + 4 * x, 4); break;
            case FMT_ARGB: o[0] = p[4 * x + 1], o[1] = p[4 * x + 2], o[2] = p[4 * x + 3], o[3] = p[4 * x]; break;
            case FMT_BGRA: o[0] = p[4 * x + 2], o[1] = p[4 * x + 1], o[2] = p[4 * x], o[3] = p[4 * x + 3]; break;
            case FMT_GRAY: o[0] = o[1] = o[2] = p[x], o[3] = 255; break;
            case FMT_GRAYA: o[0] = o[1] = o[2] = p[2 * x], o[3] = p[2 * x + 1]; break;
            case FMT_RGBA16:
                for (int k = 0; k < 4; k++)
                    o[k] = (unsigned char)lround(((p[8 * x + 2 * k] << 8) | p[8 * x + 2 * k + 1]) / 257.0);
                break;
            case FMT_RGBAF:
                for (int k = 0; k < 4; k++) {
                    float f;
                    memcpy(&f, p + 16 * x + 4 * k, 4);
                    o[k] = (unsigned char)lround(fmin(1, fmax(0, f)) * 255);
                }
                break;
            case FMT_CMYK:
                for (int k = 0; k < 4; k++)
                    o[k] = p[4 * x + k];
                break;
            case FMT_ALPHA: o[0] = o[1] = o[2] = 0, o[3] = p[x]; break;
            }
        }
    return out;
}

static CGImageRef
checkerboard(size_t n, int cells)
{
    unsigned char *px = malloc(n * n * 4);
    for (size_t y = 0; y < n; y++)
        for (size_t x = 0; x < n; x++) {
            int on = ((x * cells / n) + (y * cells / n)) % 2;
            unsigned char *p = px + 4 * (y * n + x);
            p[0] = on ? 220 : 20, p[1] = on ? 40 : 160, p[2] = (unsigned char)(x * 255 / (n - 1)), p[3] = 255;
        }
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, px, n * n * 4, NULL);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGImageRef im = CGImageCreate(n, n, 8, 32, n * 4, rgb, kCGImageAlphaNoneSkipLast, prov, NULL, false,
                                  kCGRenderingIntentDefault);
    CGColorSpaceRelease(rgb);
    CGDataProviderRelease(prov);
    return im;
}

typedef void (*SceneFn)(CGContextRef c);

static void
s_rect(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 1, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(8, 8, 32, 16));
}

static void
s_rect_fraction(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 0, 0.5, 1, 1);
    CGContextFillRect(c, CGRectMake(7.3, 9.6, 30.5, 20.25));
}

static void
s_ellipse(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 0.2, 0.8, 0.3, 1);
    CGContextFillEllipseInRect(c, CGRectMake(6, 10, 50, 36));
}

static void
s_stroke(CGContextRef c)
{
    CGContextSetRGBStrokeColor(c, 0, 0, 0.6, 1);
    CGContextSetLineWidth(c, 5);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextMoveToPoint(c, 8, 8);
    CGContextAddLineToPoint(c, 56, 20);
    CGContextAddLineToPoint(c, 20, 56);
    CGContextStrokePath(c);
}

static void
s_miter(CGContextRef c)
{
    CGContextSetRGBStrokeColor(c, 0.5, 0, 0.5, 1);
    CGContextSetLineWidth(c, 6);
    CGContextMoveToPoint(c, 10, 10);
    CGContextAddLineToPoint(c, 32, 50);
    CGContextAddLineToPoint(c, 54, 10);
    CGContextClosePath(c);
    CGContextStrokePath(c);
}

static void
s_dash(CGContextRef c)
{
    CGFloat dash[] = {8, 4, 2, 4};
    CGContextSetRGBStrokeColor(c, 0.8, 0.4, 0, 1);
    CGContextSetLineWidth(c, 3);
    CGContextSetLineDash(c, 3, dash, 4);
    CGContextStrokeRect(c, CGRectMake(8, 8, 48, 40));
}

static void
s_evenodd(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 0.1, 0.1, 0.1, 1);
    CGContextAddEllipseInRect(c, CGRectMake(4, 4, 56, 56));
    CGContextAddEllipseInRect(c, CGRectMake(18, 18, 28, 28));
    CGContextEOFillPath(c);
}

static void
s_winding(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 0.1, 0.3, 0.1, 1);
    CGContextAddEllipseInRect(c, CGRectMake(4, 4, 56, 56));
    CGContextAddEllipseInRect(c, CGRectMake(18, 18, 28, 28));
    CGContextFillPath(c);
}

static void
s_alpha_blend(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 1, 1, 0, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 64, 64));
    CGContextSetAlpha(c, 0.5);
    CGContextSetRGBFillColor(c, 0, 0, 1, 1);
    CGContextFillRect(c, CGRectMake(8, 8, 32, 32));
    CGContextSetAlpha(c, 1);
    CGContextSetBlendMode(c, kCGBlendModeMultiply);
    CGContextSetRGBFillColor(c, 1, 0, 1, 0.8);
    CGContextFillRect(c, CGRectMake(24, 24, 32, 32));
}

static void
s_blend_modes(CGContextRef c)
{
    CGBlendMode modes[] = {kCGBlendModeScreen, kCGBlendModeOverlay, kCGBlendModeDarken, kCGBlendModeLighten,
                           kCGBlendModeDifference, kCGBlendModeXOR, kCGBlendModeSourceIn, kCGBlendModeDestinationOver};
    for (int i = 0; i < 8; i++) {
        CGRect r = CGRectMake((i % 4) * 16, (i / 4) * 32, 16, 32);
        CGContextSetBlendMode(c, kCGBlendModeNormal);
        CGContextSetRGBFillColor(c, 0.2, 0.6, 0.9, 0.7);
        CGContextFillRect(c, CGRectInset(r, 0, 6));
        CGContextSetBlendMode(c, modes[i]);
        CGContextSetRGBFillColor(c, 0.9, 0.3, 0.1, 0.6);
        CGContextFillRect(c, CGRectInset(r, 3, 0));
    }
}

static void
s_clip(CGContextRef c)
{
    CGContextAddEllipseInRect(c, CGRectMake(8, 8, 48, 48));
    CGContextClip(c);
    CGContextSetRGBFillColor(c, 0.9, 0.1, 0.1, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 40, 64));
    CGContextSetRGBFillColor(c, 0.1, 0.1, 0.9, 1);
    CGContextFillRect(c, CGRectMake(40, 0, 24, 64));
}

static void
s_clip_rects(CGContextRef c)
{
    CGRect rs[] = {CGRectMake(4, 4, 20, 20), CGRectMake(30, 30, 30, 10)};
    CGContextClipToRects(c, rs, 2);
    CGContextSaveGState(c);
    CGContextClipToRect(c, CGRectMake(10, 0, 50, 64));
    CGContextSetRGBFillColor(c, 0, 0.7, 0.7, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 64, 64));
    CGContextRestoreGState(c);
    CGContextSetRGBFillColor(c, 0.7, 0.7, 0, 0.5);
    CGContextFillRect(c, CGRectMake(0, 0, 64, 64));
}

static void
s_transform(CGContextRef c)
{
    CGContextTranslateCTM(c, 32, 32);
    CGContextRotateCTM(c, M_PI / 6);
    CGContextScaleCTM(c, 1.5, 0.75);
    CGContextSetRGBFillColor(c, 0.3, 0.3, 0.9, 1);
    CGContextFillRect(c, CGRectMake(-15, -15, 30, 30));
    CGContextSetRGBStrokeColor(c, 0, 0, 0, 1);
    CGContextSetLineWidth(c, 2);
    CGContextStrokeRect(c, CGRectMake(-15, -15, 30, 30));
}

static void
s_curves(CGContextRef c)
{
    CGContextSetRGBStrokeColor(c, 0.2, 0.2, 0.2, 1);
    CGContextSetRGBFillColor(c, 0.9, 0.7, 0.2, 1);
    CGContextSetLineWidth(c, 2);
    CGContextMoveToPoint(c, 6, 32);
    CGContextAddCurveToPoint(c, 16, 70, 48, -6, 58, 32);
    CGContextAddQuadCurveToPoint(c, 32, 64, 6, 32);
    CGContextDrawPath(c, kCGPathFillStroke);
    CGContextAddArc(c, 32, 32, 10, 0, 3, 0);
    CGContextStrokePath(c);
}

static void
s_image_none(CGContextRef c)
{
    CGImageRef im = checkerboard(8, 4);
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(0, 0, 64, 64), im);
    CGImageRelease(im);
}

static void
s_image_1to1(CGContextRef c)
{
    CGImageRef im = checkerboard(32, 4);
    CGContextDrawImage(c, CGRectMake(16, 8, 32, 32), im);
    CGImageRelease(im);
}

static void
s_image_flip(CGContextRef c)
{
    /* drawn into a flipped CTM, as views often do */
    CGImageRef im = checkerboard(16, 2);
    CGContextTranslateCTM(c, 0, 64);
    CGContextScaleCTM(c, 1, -1);
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(8, 4, 48, 32), im);
    CGImageRelease(im);
}

static void
s_image_mask(CGContextRef c)
{
    static unsigned char bits[8] = {0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81};
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, bits, 8, NULL);
    CGImageRef mask = CGImageMaskCreate(8, 8, 1, 1, 1, prov, NULL, false);
    CGContextSetRGBFillColor(c, 0.9, 0.2, 0.5, 1);
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(0, 0, 64, 64), mask);
    CGImageRelease(mask);
    CGDataProviderRelease(prov);
}

static void
s_clip_mask(CGContextRef c)
{
    static unsigned char ramp[16 * 16];
    for (int i = 0; i < 256; i++)
        ramp[i] = (unsigned char)((i % 16) * 17);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, ramp, sizeof ramp, NULL);
    CGImageRef im = CGImageCreate(16, 16, 8, 8, 16, gray, kCGImageAlphaNone, prov, NULL, false, kCGRenderingIntentDefault);
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextClipToMask(c, CGRectMake(0, 0, 64, 64), im);
    CGContextSetRGBFillColor(c, 0, 0.4, 0.8, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 64, 64));
    CGImageRelease(im);
    CGDataProviderRelease(prov);
    CGColorSpaceRelease(gray);
}

static void
s_clear(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 0.4, 0.8, 0.4, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 64, 64));
    CGContextClearRect(c, CGRectMake(16, 16, 32, 24));
}

static void
s_shadow(CGContextRef c)
{
    CGContextSetShadow(c, CGSizeMake(6, -6), 4);
    CGContextSetRGBFillColor(c, 0.2, 0.5, 0.9, 1);
    CGContextFillRect(c, CGRectMake(12, 20, 28, 28));
}

static void
s_shadow_color(CGContextRef c)
{
    CGColorRef red = CGColorCreateSRGB(1, 0, 0, 0.8);
    CGContextSetShadowWithColor(c, CGSizeMake(-4, 4), 0, red);
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillEllipseInRect(c, CGRectMake(16, 12, 32, 32));
    CGColorRelease(red);
}

static void
s_layer(CGContextRef c)
{
    CGContextSetAlpha(c, 0.5);
    CGContextBeginTransparencyLayer(c, NULL);
    CGContextSetRGBFillColor(c, 1, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(8, 8, 32, 32));
    CGContextSetRGBFillColor(c, 0, 0, 1, 1);
    CGContextFillRect(c, CGRectMake(24, 24, 32, 32));
    CGContextEndTransparencyLayer(c);
}

static void
s_no_antialias(CGContextRef c)
{
    CGContextSetShouldAntialias(c, false);
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillEllipseInRect(c, CGRectMake(6.5, 8.25, 50, 40));
}

static void
s_colors(CGContextRef c)
{
    CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGColorRef p3green = CGColorCreate(p3, (CGFloat[]){0.2, 0.8, 0.3, 1});
    CGContextSetFillColorWithColor(c, p3green);
    CGContextFillRect(c, CGRectMake(0, 0, 32, 64));
    CGContextSetGrayFillColor(c, 0.5, 1);
    CGContextFillRect(c, CGRectMake(32, 0, 32, 32));
    /* (CMYK colours aren't compared: Apple converts them with its Generic CMYK profile, which Finch doesn't have) */
    CGColorRef srgb = CGColorCreateSRGB(0.9, 0.3, 0.6, 0.75);
    CGContextSetFillColorWithColor(c, srgb);
    CGContextFillRect(c, CGRectMake(32, 32, 32, 32));
    CGColorRelease(srgb);
    CGColorRelease(p3green);
    CGColorSpaceRelease(p3);
}


static CGGradientRef
rainbow(void)
{
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = {1, 0, 0, 1, 0, 1, 0, 0.6, 0, 0, 1, 1};
    CGFloat locs[] = {0, 0.4, 1};
    CGGradientRef g = CGGradientCreateWithColorComponents(rgb, comps, locs, 3);
    CGColorSpaceRelease(rgb);
    return g;
}

static void
s_linear(CGContextRef c)
{
    CGGradientRef g = rainbow();
    CGContextDrawLinearGradient(c, g, CGPointMake(16, 10), CGPointMake(48, 50), 0);
    CGGradientRelease(g);
}

static void
s_linear_extend(CGContextRef c)
{
    CGGradientRef g = rainbow();
    CGContextDrawLinearGradient(c, g, CGPointMake(16, 10), CGPointMake(48, 50),
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
}

static void
s_linear_before(CGContextRef c)
{
    CGGradientRef g = rainbow();
    CGContextAddEllipseInRect(c, CGRectMake(4, 4, 56, 56));
    CGContextClip(c);
    CGContextDrawLinearGradient(c, g, CGPointMake(20, 32), CGPointMake(44, 32), kCGGradientDrawsBeforeStartLocation);
    CGGradientRelease(g);
}

static void
s_radial(CGContextRef c)
{
    CGGradientRef g = rainbow();
    CGContextDrawRadialGradient(c, g, CGPointMake(32, 32), 4, CGPointMake(32, 32), 26, 0);
    CGGradientRelease(g);
}

static void
s_radial_two(CGContextRef c)
{
    CGGradientRef g = rainbow();
    CGContextDrawRadialGradient(c, g, CGPointMake(24, 26), 2, CGPointMake(36, 36), 22,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
}

static void
s_radial_after(CGContextRef c)
{
    CGGradientRef g = rainbow();
    CGContextDrawRadialGradient(c, g, CGPointMake(32, 32), 0, CGPointMake(32, 32), 16, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
}

static void
s_gradient_colors(CGContextRef c)
{
    CGColorRef a = CGColorCreateSRGB(1, 1, 1, 1), b = CGColorCreateGenericGray(0.2, 1);
    const void *cs[] = {a, b};
    CFArrayRef arr = CFArrayCreate(NULL, cs, 2, &kCFTypeArrayCallBacks);
    CGGradientRef g = CGGradientCreateWithColors(NULL, arr, NULL);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, 0), CGPointMake(64, 0), 0);
    CGGradientRelease(g);
    CFRelease(arr);
    CGColorRelease(a);
    CGColorRelease(b);
}

static void
s_conic(CGContextRef c)
{
    CGGradientRef g = rainbow();
    CGContextDrawConicGradient(c, g, CGPointMake(32, 32), M_PI / 4);
    CGGradientRelease(g);
}

static void
ramp(void *info, const CGFloat *in, CGFloat *out)
{
    CGFloat t = in[0];
    out[0] = t, out[1] = 1 - t, out[2] = 0.5 + 0.5 * sin(t * 6), out[3] = 1;
}

static void
s_shading(CGContextRef c)
{
    CGFloat domain[2] = {0, 1}, range[8] = {0, 1, 0, 1, 0, 1, 0, 1};
    CGFunctionCallbacks cb = {0, ramp, NULL};
    CGFunctionRef f = CGFunctionCreate(NULL, 1, domain, 4, range, &cb);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGShadingRef sh = CGShadingCreateAxial(rgb, CGPointMake(8, 8), CGPointMake(56, 30), f, false, true);
    CGContextDrawShading(c, sh);
    CGShadingRelease(sh);
    sh = CGShadingCreateRadial(rgb, CGPointMake(20, 44), 2, CGPointMake(20, 44), 14, f, true, false);
    CGContextDrawShading(c, sh);
    CGShadingRelease(sh);
    CGColorSpaceRelease(rgb);
    CGFunctionRelease(f);
}

static void
cell(void *info, CGContextRef c)
{
    CGContextSetRGBFillColor(c, 0.9, 0.5, 0.1, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 6, 6));
    CGContextSetRGBFillColor(c, 0.1, 0.3, 0.8, 1);
    CGContextFillEllipseInRect(c, CGRectMake(5, 5, 6, 6));
}

static void
stencil_cell(void *info, CGContextRef c)
{
    CGContextFillRect(c, CGRectMake(0, 0, 4, 8));
}

static void
s_pattern(CGContextRef c)
{
    CGPatternCallbacks cb = {0, cell, NULL};
    CGPatternRef p = CGPatternCreate(NULL, CGRectMake(0, 0, 12, 12), CGAffineTransformMakeTranslation(2, 3), 12, 12,
                                     kCGPatternTilingConstantSpacing, true, &cb);
    CGColorSpaceRef ps = CGColorSpaceCreatePattern(NULL);
    CGContextSetFillColorSpace(c, ps);
    CGFloat alpha = 1;
    CGContextSetFillPattern(c, p, &alpha);
    CGContextScaleCTM(c, 2, 2);  /* the pattern isn't scaled with the CTM */
    CGContextFillRect(c, CGRectMake(2, 2, 26, 26));
    CGColorSpaceRelease(ps);
    CGPatternRelease(p);
}

static void
s_pattern_stencil(CGContextRef c)
{
    CGPatternCallbacks cb = {0, stencil_cell, NULL};
    /* (rotated cells space slightly differently on Apple's: not compared) */
    CGPatternRef p = CGPatternCreate(NULL, CGRectMake(0, 0, 8, 8), CGAffineTransformMake(1.5, 0, 0, 1.25, 3, 1), 8, 8,
                                     kCGPatternTilingConstantSpacing, false, &cb);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB(), ps = CGColorSpaceCreatePattern(rgb);
    CGContextSetFillColorSpace(c, ps);
    CGFloat comps[4] = {0.2, 0.6, 0.2, 1};
    CGContextSetFillPattern(c, p, comps);
    CGContextFillEllipseInRect(c, CGRectMake(4, 4, 56, 56));
    CGColorSpaceRelease(ps);
    CGColorSpaceRelease(rgb);
    CGPatternRelease(p);
}

static void
s_cglayer(CGContextRef c)
{
    CGLayerRef l = CGLayerCreateWithContext(c, CGSizeMake(16, 16), NULL);
    CGContextRef lc = CGLayerGetContext(l);
    CGContextSetRGBFillColor(lc, 0.7, 0.1, 0.4, 1);
    CGContextFillEllipseInRect(lc, CGRectMake(0, 0, 16, 16));
    CGContextSetRGBFillColor(lc, 1, 1, 1, 1);
    CGContextFillRect(lc, CGRectMake(6, 6, 4, 4));
    CGContextDrawLayerAtPoint(c, CGPointMake(4, 40), l);
    CGContextDrawLayerAtPoint(c, CGPointMake(40, 4), l);
    CGContextDrawLayerInRect(c, CGRectMake(20, 16, 24, 24), l);
    CGLayerRelease(l);
}

static CGFontRef
test_font(void)
{
    static CGFontRef font;
    if (font)
        return font;
    const char *dirs[] = {getenv("FINCH_TEST_FONTS"), "/usr/local/share/finch/test-fonts",
                          "build/src/skia/resources/fonts", "../../build/src/skia/resources/fonts"};
    for (unsigned i = 0; i < sizeof dirs / sizeof dirs[0] && !font; i++) {
        if (!dirs[i])
            continue;
        char path[1024];
        snprintf(path, sizeof path, "%s/Roboto-Regular.ttf", dirs[i]);
        CGDataProviderRef p = CGDataProviderCreateWithFilename(path);
        if (p) {
            font = CGFontCreateWithDataProvider(p);
            CGDataProviderRelease(p);
        }
    }
    if (!font) {
        fprintf(stderr, "no test font\n");
        exit(1);
    }
    return font;
}

static const CGGlyph word[] = {44, 73, 70, 76, 80, 3, 59, 82};

static void
s_text(CGContextRef c)
{
    CGContextSetFont(c, test_font());
    CGContextSetFontSize(c, 18);
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGPoint pos[8];
    for (int i = 0; i < 8; i++)
        pos[i] = CGPointMake(2 + 7.5 * i, 24);
    CGContextShowGlyphsAtPositions(c, word, pos, 8);
}

static void
s_text_modes(CGContextRef c)
{
    CGContextSetFont(c, test_font());
    CGContextSetFontSize(c, 30);
    CGContextSetRGBStrokeColor(c, 0.8, 0, 0, 1);
    CGContextSetRGBFillColor(c, 0, 0, 0.8, 1);
    CGContextSetLineWidth(c, 1.5);
    CGContextSetTextDrawingMode(c, kCGTextFillStroke);
    CGContextShowGlyphsAtPoint(c, 2, 34, word, 3);
    CGContextSetTextDrawingMode(c, kCGTextStroke);
    CGContextShowGlyphsAtPoint(c, 4, 6, word + 3, 2);
}

static void
s_text_matrix(CGContextRef c)
{
    CGContextSetFont(c, test_font());
    CGContextSetFontSize(c, 16);
    CGContextSetTextMatrix(c, CGAffineTransformMake(1, 0.3, -0.2, 1.2, 0, 0));
    CGContextSetCharacterSpacing(c, 2);
    CGContextSetRGBFillColor(c, 0.1, 0.5, 0.1, 1);
    CGContextShowGlyphsAtPoint(c, 4, 10, word, 8);
}

static void
s_text_clip(CGContextRef c)
{
    CGContextSetFont(c, test_font());
    CGContextSetFontSize(c, 44);
    CGContextSetTextDrawingMode(c, kCGTextClip);
    CGContextShowGlyphsAtPoint(c, 2, 14, word, 2);
    CGGradientRef g = rainbow();
    CGContextDrawLinearGradient(c, g, CGPointMake(0, 0), CGPointMake(64, 64), 0);
    CGGradientRelease(g);
}

static void
s_text_flipped(CGContextRef c)
{
    CGContextTranslateCTM(c, 0, 64);
    CGContextScaleCTM(c, 1, -1);
    CGContextSetTextMatrix(c, CGAffineTransformMakeScale(1, -1));
    CGContextSetFont(c, test_font());
    CGContextSetFontSize(c, 14);
    CGContextSetGrayFillColor(c, 0.2, 1);
    CGContextShowGlyphsAtPoint(c, 3, 20, word, 6);
}

typedef struct {
    const char *name;
    int fmt;
    SceneFn fn;
} Scene;

static const Scene scenes[] = {
    {"rect", FMT_RGBA, s_rect},
    {"rect fraction", FMT_RGBA, s_rect_fraction},
    {"ellipse", FMT_RGBA, s_ellipse},
    {"stroke round", FMT_RGBA, s_stroke},
    {"stroke miter", FMT_RGBA, s_miter},
    {"dash", FMT_RGBA, s_dash},
    {"even-odd", FMT_RGBA, s_evenodd},
    {"winding", FMT_RGBA, s_winding},
    {"alpha and multiply", FMT_RGBA, s_alpha_blend},
    {"blend modes", FMT_RGBA, s_blend_modes},
    {"clip", FMT_RGBA, s_clip},
    {"clip rects", FMT_RGBA, s_clip_rects},
    {"transform", FMT_RGBA, s_transform},
    {"curves", FMT_RGBA, s_curves},
    {"image scaled, no interpolation", FMT_RGBA, s_image_none},
    {"image 1:1", FMT_RGBA, s_image_1to1},
    {"image in flipped CTM", FMT_RGBA, s_image_flip},
    {"image mask", FMT_RGBA, s_image_mask},
    {"clip to mask", FMT_RGBA, s_clip_mask},
    {"clear rect", FMT_RGBA, s_clear},
    {"shadow", FMT_RGBA, s_shadow},
    {"shadow colour, no blur", FMT_RGBA, s_shadow_color},
    {"transparency layer", FMT_RGBA, s_layer},
    {"no antialiasing", FMT_RGBA, s_no_antialias},
    {"colour spaces", FMT_RGBA, s_colors},
    {"ellipse ARGB", FMT_ARGB, s_ellipse},
    {"ellipse BGRA", FMT_BGRA, s_ellipse},
    {"ellipse gray", FMT_GRAY, s_ellipse},
    {"ellipse gray+alpha", FMT_GRAYA, s_ellipse},
    {"ellipse 16-bit", FMT_RGBA16, s_ellipse},
    {"ellipse float", FMT_RGBAF, s_ellipse},
    {"ellipse alpha only", FMT_ALPHA, s_ellipse},
    {"colours ARGB", FMT_ARGB, s_colors},
    {"colours gray", FMT_GRAY, s_colors},
    {"image ARGB", FMT_ARGB, s_image_none},
    {"stroke 16-bit", FMT_RGBA16, s_stroke},
    {"linear gradient", FMT_RGBA, s_linear},
    {"linear gradient extended", FMT_RGBA, s_linear_extend},
    {"linear gradient before start, clipped", FMT_RGBA, s_linear_before},
    {"radial gradient", FMT_RGBA, s_radial},
    {"radial gradient, two centres, extended", FMT_RGBA, s_radial_two},
    {"radial gradient after end", FMT_RGBA, s_radial_after},
    {"gradient from colours", FMT_RGBA, s_gradient_colors},
    {"conic gradient", FMT_RGBA, s_conic},
    {"shadings", FMT_RGBA, s_shading},
    {"linear gradient gray", FMT_GRAY, s_linear},
    {"coloured pattern", FMT_RGBA, s_pattern},
    {"uncoloured pattern", FMT_RGBA, s_pattern_stencil},
    {"CGLayer", FMT_RGBA, s_cglayer},
    {"glyphs", FMT_RGBA, s_text},
    {"text drawing modes", FMT_RGBA, s_text_modes},
    {"text matrix and spacing", FMT_RGBA, s_text_matrix},
    {"text clip", FMT_RGBA, s_text_clip},
    {"text in flipped CTM", FMT_RGBA, s_text_flipped},
};
#define NSCENES (sizeof scenes / sizeof scenes[0])
#define SIZE 64

static unsigned char *
render(const Scene *s)
{
    Canvas c = canvas(s->fmt, SIZE, SIZE);
    s->fn(c.ctx);
    unsigned char *px = pixels(c);
    CGContextRelease(c.ctx);
    return px;
}

/* Glyph rasterizers differ more than shape rasterizers: text scenes allow more on edges. */
static int
compare(const char *name, const unsigned char *ref, const unsigned char *got)
{
    double edge_limit = strstr(name, "text") || strstr(name, "glyphs") ? 20 : 16;
    int interior_max = 0, edges = 0, bad = 0;
    double edge_sum = 0;
    for (int y = 0; y < SIZE; y++)
        for (int x = 0; x < SIZE; x++) {
            const unsigned char *r = ref + 4 * (y * SIZE + x), *g = got + 4 * (y * SIZE + x);
            int flat = 1;
            for (int dy = -1; dy <= 1 && flat; dy++)
                for (int dx = -1; dx <= 1 && flat; dx++) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= SIZE || ny >= SIZE)
                        continue;
                    flat = !memcmp(r, ref + 4 * (ny * SIZE + nx), 4);
                }
            int diff = 0;
            for (int k = 0; k < 4; k++)
                diff = abs(r[k] - g[k]) > diff ? abs(r[k] - g[k]) : diff;
            if (flat) {
                interior_max = diff > interior_max ? diff : interior_max;
            } else {
                edges++;
                edge_sum += diff;
                bad += diff > 96;
            }
        }
    if (getenv("CG_DRAW_DUMP") && strstr(name, getenv("CG_DRAW_DUMP")))
        for (int y = 0; y < SIZE; y++) {
            for (int x = 0; x < SIZE; x++)
                putchar(" .:-=+*#%@"[ref[4 * (y * SIZE + x) + 3] * 9 / 255]);
            printf("   ");
            for (int x = 0; x < SIZE; x++)
                putchar(" .:-=+*#%@"[got[4 * (y * SIZE + x) + 3] * 9 / 255]);
            printf("\n");
        }
    double edge_mean = edges ? edge_sum / edges : 0;
    int ok = interior_max <= 2 && edge_mean <= edge_limit && bad <= edges / 50 + 1;
    if (ok)
        printf("%s: ok\n", name);
    else
        printf("%s: DIFFERS (flat max %d, edge mean %.1f, edge outliers %d of %d)\n", name, interior_max, edge_mean, bad,
               edges);
    return ok;
}

int
main(int argc, char **argv)
{
    int no_path = 0;
    const char *write = NULL, *ref_path = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--no-path"))
            no_path = 1;
        else if (!strcmp(argv[i], "--write") && i + 1 < argc)
            write = argv[++i];
        else
            ref_path = argv[i];
    }
    Dl_info info;
    const char *cg = dladdr((void *)CGContextFillRect, &info) ? info.dli_fname : "?";
    if (!no_path)
        printf("CoreGraphics: %s\n", cg);
    size_t one = SIZE * SIZE * 4, total = one * NSCENES;
    if (write) {
        if (strncmp(cg, "/System/", 8)) {
            fprintf(stderr, "references come from Apple's CoreGraphics (this is %s)\n", cg);
            return 1;
        }
        unsigned char *all = malloc(total);
        for (size_t i = 0; i < NSCENES; i++) {
            unsigned char *px = render(&scenes[i]);
            memcpy(all + i * one, px, one);
            free(px);
        }
        uLongf zlen = compressBound(total);
        unsigned char *z = malloc(zlen);
        compress2(z, &zlen, all, total, 9);
        FILE *f = fopen(write, "wb");
        fwrite(z, 1, zlen, f);
        fclose(f);
        printf("wrote %zu scenes (%lu bytes)\n", NSCENES, (unsigned long)zlen);
        return 0;
    }
    if (!ref_path)
        ref_path = "/usr/local/share/finch/cg-draw-reference.bin";
    FILE *f = fopen(ref_path, "rb");
    if (!f) {
        printf("no reference at %s\n", ref_path);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long zlen = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *z = malloc((size_t)zlen), *all = malloc(total);
    fread(z, 1, (size_t)zlen, f);
    fclose(f);
    uLongf len = total;
    if (uncompress(all, &len, z, (uLong)zlen) != Z_OK || len != total) {
        printf("reference doesn't match these scenes: regenerate it with --write\n");
        return 1;
    }
    int failures = 0;
    for (size_t i = 0; i < NSCENES; i++) {
        unsigned char *px = render(&scenes[i]);
        failures += !compare(scenes[i].name, all + i * one, px);
        free(px);
    }
    return failures ? 1 : 0;
}
