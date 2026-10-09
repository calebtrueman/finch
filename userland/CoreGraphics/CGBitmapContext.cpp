/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGBitmapContext: a context drawing into memory in one of the layouts
 * Apple's accepts. Skia draws the common ones in place (RGBA/BGRA 8-bit,
 * gray 8-bit, alpha 8-bit, 16-bit and float RGBA little-endian); for the
 * others (ARGB, 5-bit, big-endian 16-bit and float, gray with alpha, 16-bit
 * and float gray, CMYK) it draws into a work buffer that is converted from
 * and back to the client's bytes around each operation.
 */
#include "CGContextInternal.h"
#include <stdlib.h>
#include <string.h>

CG_PRIVATE struct CGContext *CGContextCreateBase(int type, size_t width, size_t height);

void
CGBitmapContextFinalize(CGContextRef c)
{
    if (c->release)
        c->release(c->release_info, c->data);
    if (c->owns_data)
        free(c->data);
}

/* Is (bpc, bpp, model, info) one of the layouts Apple's accepts? */
static bool
supported(size_t bpc, size_t bpp, CGColorSpaceRef space, CGBitmapInfo info)
{
    CGImageAlphaInfo a = (CGImageAlphaInfo)(info & kCGBitmapAlphaInfoMask);
    bool fl = info & kCGBitmapFloatComponents;
    uint32_t order = info & kCGBitmapByteOrderMask;
    if (a == kCGImageAlphaOnly)
        return !space && bpc == 8 && bpp == 8 && !fl;
    if (!space)
        return false;
    CGColorSpaceModel model = CGColorSpaceGetModel(space);
    if (space->extended && !fl)
        return false;
    bool none = a == kCGImageAlphaNone;
    bool premul_last = a == kCGImageAlphaPremultipliedLast, skip_last = a == kCGImageAlphaNoneSkipLast;
    switch (model) {
    case kCGColorSpaceModelRGB:
        if (bpc == 8 && bpp == 32 && !fl)
            return premul_last || skip_last || a == kCGImageAlphaPremultipliedFirst || a == kCGImageAlphaNoneSkipFirst;
        if (bpc == 5 && bpp == 16 && !fl)
            return a == kCGImageAlphaNoneSkipFirst;
        if (bpc == 16 && bpp == 64)
            return (premul_last || skip_last) && (!fl || order == kCGBitmapByteOrder16Little);
        if (bpc == 32 && bpp == 128)
            return fl && (premul_last || skip_last);
        return false;
    case kCGColorSpaceModelMonochrome:
        if (bpc == 8 && bpp == 8 && !fl)
            return none;
        if (bpc == 8 && bpp == 16 && !fl)
            return premul_last;
        if (bpc == 16 && bpp == 16 && !fl)
            return none;
        if (bpc == 32 && bpp == 32)
            return fl && none;
        return false;
    case kCGColorSpaceModelCMYK:
        if (!none)
            return false;
        return (bpc == 8 && bpp == 32 && !fl) || (bpc == 16 && bpp == 64 && !fl) || (bpc == 32 && bpp == 128 && fl);
    default:
        return false;
    }
}

static size_t
bits_per_pixel(size_t bpc, CGColorSpaceRef space, CGBitmapInfo info)
{
    CGImageAlphaInfo a = (CGImageAlphaInfo)(info & kCGBitmapAlphaInfoMask);
    if (a == kCGImageAlphaOnly)
        return bpc;
    if (bpc == 5)
        return 16;
    size_t n = space ? CGColorSpaceGetNumberOfComponents(space) : 0;
    return bpc * (n + (a == kCGImageAlphaNone ? 0 : 1));
}

/* The Skia colour type that draws the client's layout in place, if any. */
static SkColorType
native_type(size_t bpc, size_t bpp, CGColorSpaceRef space, CGBitmapInfo info, SkAlphaType *at)
{
    CGImageAlphaInfo a = (CGImageAlphaInfo)(info & kCGBitmapAlphaInfoMask);
    uint32_t order = info & kCGBitmapByteOrderMask;
    bool fl = info & kCGBitmapFloatComponents;
    bool opaque = a == kCGImageAlphaNoneSkipLast || a == kCGImageAlphaNoneSkipFirst || a == kCGImageAlphaNone;
    *at = opaque ? kOpaque_SkAlphaType : kPremul_SkAlphaType;
    if (a == kCGImageAlphaOnly) {
        *at = kPremul_SkAlphaType;
        return kAlpha_8_SkColorType;
    }
    CGColorSpaceModel model = CGColorSpaceGetModel(space);
    if (model == kCGColorSpaceModelRGB && bpc == 8 && bpp == 32) {
        bool big = order == kCGBitmapByteOrderDefault || order == kCGBitmapByteOrder32Big;
        if (big && a == kCGImageAlphaPremultipliedLast)
            return kRGBA_8888_SkColorType;
        if (big && a == kCGImageAlphaNoneSkipLast)
            return kRGB_888x_SkColorType;
        if (order == kCGBitmapByteOrder32Little && (a == kCGImageAlphaPremultipliedFirst || a == kCGImageAlphaNoneSkipFirst))
            return kBGRA_8888_SkColorType;
        return kUnknown_SkColorType;
    }
    if (model == kCGColorSpaceModelRGB && bpc == 16 && bpp == 64 && order == kCGBitmapByteOrder16Little)
        return fl ? kRGBA_F16_SkColorType : kR16G16B16A16_unorm_SkColorType;
    if (model == kCGColorSpaceModelRGB && bpc == 32 && fl && order == kCGBitmapByteOrder32Little)
        return kRGBA_F32_SkColorType;
    if (model == kCGColorSpaceModelMonochrome && bpc == 8 && bpp == 8)
        return kGray_8_SkColorType;
    return kUnknown_SkColorType;
}

CGContextRef
CGBitmapContextCreateWithData(void *data, size_t width, size_t height, size_t bpc, size_t bpr, CGColorSpaceRef space,
                              uint32_t info, CGBitmapContextReleaseDataCallback release, void *release_info)
{
    if (!width || !height || width > 0x7fffff || height > 0x7fffff)
        return NULL;
    if (space && (space->kind == CG_SPACE_INDEXED || space->kind == CG_SPACE_PATTERN))
        return NULL;
    size_t bpp = bits_per_pixel(bpc, space, info);
    if (!supported(bpc, bpp, space, info))
        return NULL;
    size_t min_bpr = (width * bpp + 7) / 8;
    if (bpr == 0) {
        if (data)
            bpr = min_bpr;
        else
            bpr = (min_bpr + 31) & ~(size_t)31;
    } else if (bpr < min_bpr || (bpp >= 8 && bpr % (bpp / 8))) {
        return NULL;
    }
    struct CGContext *c = CGContextCreateBase(CG_CONTEXT_BITMAP, width, height);
    if (!data) {
        data = calloc(height, bpr);
        if (!data) {
            CFRelease(c);
            return NULL;
        }
        c->owns_data = true;
    }
    c->data = data;
    c->release = release;
    c->release_info = release_info;
    c->bpc = bpc, c->bpp = bpp, c->bpr = bpr;
    c->space = space ? (CGColorSpaceRef)CFRetain(space) : NULL;
    if (bpc == 5)
        info |= kCGImagePixelFormatRGB555;
    c->info = info;
    if (space) {
        CGColorSpaceModel model = CGColorSpaceGetModel(space);
        c->draw_space = model == kCGColorSpaceModelCMYK ? CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
                                                        : (CGColorSpaceRef)CFRetain(space);
        c->skspace = new sk_sp<SkColorSpace>(CGSkColorSpace(c->draw_space));
    }
    SkAlphaType at;
    SkColorType ct = native_type(bpc, bpp, space, info, &at);
    sk_sp<SkColorSpace> skcs = c->skspace ? *c->skspace : nullptr;
    sk_sp<SkSurface> surface;
    if (ct != kUnknown_SkColorType) {
        SkImageInfo ii = SkImageInfo::Make((int)width, (int)height, ct, at, skcs);
        surface = SkSurfaces::WrapPixels(ii, data, bpr);
    } else {
        bool wide = bpc > 8;
        SkImageInfo ii = SkImageInfo::Make((int)width, (int)height, wide ? kRGBA_F32_SkColorType : kRGBA_8888_SkColorType,
                                           kPremul_SkAlphaType, skcs);
        c->work = new SkBitmap();
        c->work->allocPixels(ii);
        c->work->eraseColor(SK_ColorTRANSPARENT);
        surface = SkSurfaces::WrapPixels(ii, c->work->getPixels(), c->work->rowBytes());
    }
    if (!surface) {
        CFRelease(c);
        return NULL;
    }
    c->surface = new sk_sp<SkSurface>(surface);
    c->canvas = surface->getCanvas();
    return c;
}

CGContextRef
CGBitmapContextCreate(void *data, size_t width, size_t height, size_t bpc, size_t bpr, CGColorSpaceRef space,
                      uint32_t info)
{
    return CGBitmapContextCreateWithData(data, width, height, bpc, bpr, space, info, NULL, NULL);
}

#pragma mark - The work buffer

static CGPixelLayout
client_layout(CGContextRef c)
{
    size_t n = c->space ? CGColorSpaceGetNumberOfComponents(c->space) : 0;
    return CGPixelLayout::make(c->bpc, c->bpp, c->bpr, n, c->info);
}

static void
cmyk_to_rgb(const double *cmyk, double *rgb)
{
    for (int i = 0; i < 3; i++)
        rgb[i] = (1 - fmin(1, cmyk[i])) * (1 - fmin(1, cmyk[3]));
}

static void
rgb_to_cmyk(const double *rgb, double *cmyk)
{
    double k = 1 - fmax(rgb[0], fmax(rgb[1], rgb[2]));
    for (int i = 0; i < 3; i++)
        cmyk[i] = k >= 1 ? 0 : (1 - rgb[i] - k) / (1 - k);
    cmyk[3] = k;
}

/* Linear-light luminance of a gray context's RGB (its curve, sRGB primaries). */
static double
gray_of(CGContextRef c, const double *rgb)
{
    if (rgb[0] == rgb[1] && rgb[1] == rgb[2])
        return rgb[0];
    CGFloat in[3] = {rgb[0], rgb[1], rgb[2]}, out[1];
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceConvertComponents(srgb, in, c->space, out);
    CFRelease(srgb);
    return out[0];
}

void
CGContextSyncFromClient(CGContextRef c, const SkIRect &r)
{
    CGPixelLayout l = client_layout(c);
    bool wide = c->work->colorType() == kRGBA_F32_SkColorType;
    CGColorSpaceModel model = CGColorSpaceGetModel(c->space);
    for (int y = r.top(); y < r.bottom(); y++) {
        const uint8_t *row = (const uint8_t *)c->data + (size_t)y * c->bpr;
        for (int x = r.left(); x < r.right(); x++) {
            double comps[5], rgba[4];
            for (size_t k = 0; k < l.ncomp; k++)
                comps[k] = l.get(row, (size_t)x, k);
            double a = l.has_alpha() ? l.get(row, (size_t)x, l.ncomp) : 1;
            if (model == kCGColorSpaceModelCMYK) {
                cmyk_to_rgb(comps, rgba);
            } else if (model == kCGColorSpaceModelMonochrome) {
                rgba[0] = rgba[1] = rgba[2] = comps[0];
            } else {
                rgba[0] = comps[0], rgba[1] = comps[1], rgba[2] = comps[2];
            }
            if (!l.premultiplied())
                for (int k = 0; k < 3; k++)
                    rgba[k] *= a;
            rgba[3] = a;
            if (wide) {
                float *p = (float *)c->work->getAddr(x, y);
                for (int k = 0; k < 4; k++)
                    p[k] = (float)rgba[k];
            } else {
                uint8_t *p = (uint8_t *)c->work->getAddr(x, y);
                for (int k = 0; k < 4; k++)
                    p[k] = (uint8_t)lround(fmin(1, fmax(0, rgba[k])) * 255);
            }
        }
    }
}

void
CGContextSyncToClient(CGContextRef c, const SkIRect &r)
{
    CGPixelLayout l = client_layout(c);
    bool wide = c->work->colorType() == kRGBA_F32_SkColorType;
    CGColorSpaceModel model = CGColorSpaceGetModel(c->space);
    for (int y = r.top(); y < r.bottom(); y++) {
        uint8_t *row = (uint8_t *)c->data + (size_t)y * c->bpr;
        for (int x = r.left(); x < r.right(); x++) {
            double rgba[4];
            if (wide) {
                const float *p = (const float *)c->work->getAddr(x, y);
                for (int k = 0; k < 4; k++)
                    rgba[k] = p[k];
            } else {
                const uint8_t *p = (const uint8_t *)c->work->getAddr(x, y);
                for (int k = 0; k < 4; k++)
                    rgba[k] = p[k] / 255.0;
            }
            double a = rgba[3];
            bool premul = l.premultiplied();
            double unpremul[3];
            for (int k = 0; k < 3; k++)
                unpremul[k] = a > 0 ? rgba[k] / a : 0;
            double comps[5];
            if (model == kCGColorSpaceModelCMYK) {
                rgb_to_cmyk(unpremul, comps);
                premul = false;
            } else if (model == kCGColorSpaceModelMonochrome) {
                comps[0] = gray_of(c, unpremul);
                if (premul)
                    comps[0] *= a;
            } else {
                for (int k = 0; k < 3; k++)
                    comps[k] = premul ? rgba[k] : unpremul[k];
            }
            for (size_t k = 0; k < l.ncomp; k++)
                l.set(row, (size_t)x, k, comps[k]);
            if (l.has_alpha())
                l.set(row, (size_t)x, l.ncomp, a);
            else if (l.has_slot())
                l.set(row, (size_t)x, l.ncomp, 1);
        }
    }
}

#pragma mark - Getters

static bool
is_bitmap(CGContextRef c)
{
    return c && c->type == CG_CONTEXT_BITMAP;
}

void *CGBitmapContextGetData(CGContextRef c) { return is_bitmap(c) ? c->data : NULL; }
size_t CGBitmapContextGetWidth(CGContextRef c) { return is_bitmap(c) ? c->width : 0; }
size_t CGBitmapContextGetHeight(CGContextRef c) { return is_bitmap(c) ? c->height : 0; }
size_t CGBitmapContextGetBitsPerComponent(CGContextRef c) { return is_bitmap(c) ? c->bpc : 0; }
size_t CGBitmapContextGetBitsPerPixel(CGContextRef c) { return is_bitmap(c) ? c->bpp : 0; }
size_t CGBitmapContextGetBytesPerRow(CGContextRef c) { return is_bitmap(c) ? c->bpr : 0; }
CGColorSpaceRef CGBitmapContextGetColorSpace(CGContextRef c) { return is_bitmap(c) ? c->space : NULL; }
CGBitmapInfo CGBitmapContextGetBitmapInfo(CGContextRef c) { return is_bitmap(c) ? c->info : 0; }

CGImageAlphaInfo
CGBitmapContextGetAlphaInfo(CGContextRef c)
{
    return is_bitmap(c) ? (CGImageAlphaInfo)(c->info & kCGBitmapAlphaInfoMask) : kCGImageAlphaNone;
}

CGImageRef
CGBitmapContextCreateImage(CGContextRef c)
{
    if (!is_bitmap(c))
        return NULL;
    CFDataRef bytes = CFDataCreate(NULL, (const UInt8 *)c->data, (CFIndex)(c->bpr * c->height));
    CGImageRef im;
    if ((c->info & kCGBitmapAlphaInfoMask) == kCGImageAlphaOnly) {
        /* an image mask: alpha 1 (sample 1) is painted, hence the inverted decode */
        CGFloat decode[2] = {1, 0};
        im = CGImageCreateFromBytes(c->width, c->height, c->bpc, c->bpp, c->bpr, NULL, 0, bytes, decode, true);
    } else {
        CGBitmapInfo info = c->info;
        /* multi-byte floats with the default order are big-endian, and the image says so */
        if ((info & kCGBitmapFloatComponents) && c->bpc == 32 && !(info & kCGBitmapByteOrderMask))
            info |= kCGBitmapByteOrder32Big;
        im = CGImageCreateFromBytes(c->width, c->height, c->bpc, c->bpp, c->bpr, c->space, info, bytes, NULL, false);
    }
    CFRelease(bytes);
    return im;
}
