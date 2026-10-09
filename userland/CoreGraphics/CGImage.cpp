/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGImage: pixel data from a data provider in any of CG's layouts (1 to 32
 * bits per component, integer or float, either byte order, alpha first or
 * last, premultiplied or not, decode arrays), image masks, masked images
 * and masking colours. Drawing turns an image into a Skia image once and
 * caches it: the common 8-bit layouts are wrapped as they are; the rest are
 * unpacked into RGBA.
 */
#include "CGImageInternal.h"
#include "CGPixels.h"
#include "CGSkia.h"
#include "include/codec/SkCodec.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkData.h"
#include "include/core/SkImage.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkStream.h"
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t cache_lock = PTHREAD_MUTEX_INITIALIZER;

static void
image_finalize(CFTypeRef cf)
{
    struct CGImage *im = (struct CGImage *)cf;
    if (im->space)
        CFRelease(im->space);
    if (im->provider)
        CFRelease(im->provider);
    if (im->mask)
        CFRelease(im->mask);
    if (im->data)
        CFRelease(im->data);
    free(im->decode);
    free(im->masking);
    if (im->skimage)
        ((SkImage *)im->skimage)->unref();
}

static CFStringRef
image_desc(CFTypeRef cf)
{
    CGImageRef im = (CGImageRef)cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CGImage %p> (IP)\n\t<<CGColorSpace %p>>\n\t\twidth = %zu, height = %zu, bpc = %zu, bpp = %zu, row bytes = %zu "),
                                    im, im->space, im->width, im->height, im->bpc, im->bpp, im->bpr);
}

static const CGRuntimeClass image_class = {
    0, "CGImage", NULL, NULL, image_finalize, NULL, NULL, NULL, image_desc, NULL, NULL, 0,
};
static CFTypeID image_type;

CFTypeID
CGImageGetTypeID(void)
{
    return CGTypeRegister(&image_class, &image_type);
}

static struct CGImage *
image_new(void)
{
    return (struct CGImage *)CGTypeCreateInstance(CGImageGetTypeID(), sizeof(struct CGImage));
}

static size_t
alpha_slots(CGImageAlphaInfo a)
{
    return a == kCGImageAlphaNone || a == kCGImageAlphaOnly ? 0 : 1;
}

static bool
valid_bpc(size_t bpc, bool fl)
{
    if (fl)
        return bpc == 16 || bpc == 32;
    return bpc == 1 || bpc == 2 || bpc == 4 || bpc == 5 || bpc == 8 || bpc == 16 || bpc == 32;
}

static struct CGImage *
image_create(size_t w, size_t h, size_t bpc, size_t bpp, size_t bpr, CGColorSpaceRef space, CGBitmapInfo info,
             CGDataProviderRef provider, const CGFloat *decode, bool interpolate, CGColorRenderingIntent intent,
             bool mask)
{
    if (!provider || !w || !h)
        return NULL;
    bool fl = info & kCGBitmapFloatComponents;
    if (!valid_bpc(bpc, fl))
        return NULL;
    size_t n = mask ? 1 : space ? CGColorSpaceGetNumberOfComponents(space) : 0;
    if (!mask && (!space || space->kind == CG_SPACE_PATTERN))
        return NULL;
    CGImageAlphaInfo a = (CGImageAlphaInfo)(info & kCGBitmapAlphaInfoMask);
    size_t comps = n + (mask ? 0 : alpha_slots(a));
    if (bpp < bpc * comps && bpc != 5)
        return NULL;
    if (bpr < (w * bpp + 7) / 8)
        return NULL;
    struct CGImage *im = image_new();
    im->width = w, im->height = h, im->bpc = bpc, im->bpp = bpp, im->bpr = bpr;
    im->space = space ? (CGColorSpaceRef)CFRetain(space) : NULL;
    im->info = info;
    im->provider = (CGDataProviderRef)CFRetain(provider);
    im->interpolate = interpolate;
    im->intent = intent;
    im->is_mask = mask;
    if (decode) {
        im->decode = (CGFloat *)malloc(2 * n * sizeof(CGFloat));
        memcpy(im->decode, decode, 2 * n * sizeof(CGFloat));
    }
    return im;
}

CGImageRef
CGImageCreate(size_t width, size_t height, size_t bitsPerComponent, size_t bitsPerPixel, size_t bytesPerRow,
              CGColorSpaceRef space, CGBitmapInfo bitmapInfo, CGDataProviderRef provider, const CGFloat *decode,
              bool shouldInterpolate, CGColorRenderingIntent intent)
{
    CGImageAlphaInfo a = (CGImageAlphaInfo)(bitmapInfo & kCGBitmapAlphaInfoMask);
    if (a == kCGImageAlphaOnly && !space)
        return image_create(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, NULL, 0, provider, decode,
                            shouldInterpolate, intent, true);
    return image_create(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, space, bitmapInfo, provider,
                        decode, shouldInterpolate, intent, false);
}

CGImageRef
CGImageMaskCreate(size_t width, size_t height, size_t bitsPerComponent, size_t bitsPerPixel, size_t bytesPerRow,
                  CGDataProviderRef provider, const CGFloat *decode, bool shouldInterpolate)
{
    if (bitsPerComponent > 8 || bitsPerPixel != bitsPerComponent)
        return NULL;
    return image_create(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, NULL, 0, provider, decode,
                        shouldInterpolate, kCGRenderingIntentDefault, true);
}

CG_PRIVATE CGImageRef
CGImageCreateFromBytes(size_t w, size_t h, size_t bpc, size_t bpp, size_t bpr, CGColorSpaceRef space,
                       CGBitmapInfo info, CFDataRef data, const CGFloat *decode, bool mask)
{
    CGDataProviderRef p = CGDataProviderCreateWithCFData(data);
    struct CGImage *im = image_create(w, h, bpc, bpp, bpr, space, info, p, decode, true, kCGRenderingIntentDefault, mask);
    CFRelease(p);
    return im;
}

CGImageRef
CGImageCreateCopy(CGImageRef im)
{
    return im ? (CGImageRef)CFRetain(im) : NULL;
}

static struct CGImage *
image_clone(CGImageRef im)
{
    struct CGImage *c = image_create(im->width, im->height, im->bpc, im->bpp, im->bpr, im->space, im->info,
                                     im->provider, im->decode, im->interpolate, im->intent, im->is_mask);
    if (c && im->mask)
        c->mask = (CGImageRef)CFRetain(im->mask);
    if (c && im->masking) {
        size_t n = CGColorSpaceGetNumberOfComponents(im->space);
        c->masking = (CGFloat *)malloc(2 * n * sizeof(CGFloat));
        memcpy(c->masking, im->masking, 2 * n * sizeof(CGFloat));
    }
    return c;
}

CGImageRef
CGImageCreateCopyWithColorSpace(CGImageRef im, CGColorSpaceRef space)
{
    if (!im || !space || im->is_mask || CGColorSpaceGetNumberOfComponents(space) != CGColorSpaceGetNumberOfComponents(im->space))
        return NULL;
    struct CGImage *c = image_clone(im);
    if (c) {
        CFRelease(c->space);
        c->space = (CGColorSpaceRef)CFRetain(space);
    }
    return c;
}

CGImageRef
CGImageCreateWithImageInRect(CGImageRef im, CGRect rect)
{
    if (!im)
        return NULL;
    CGRect r = CGRectIntersection(CGRectIntegral(rect), CGRectMake(0, 0, im->width, im->height));
    if (CGRectIsNull(r) || CGRectIsEmpty(r))
        return NULL;
    size_t x = (size_t)r.origin.x, y = (size_t)r.origin.y, w = (size_t)r.size.width, h = (size_t)r.size.height;
    CFDataRef all = CGImageCopyBytes(im);
    if (!all)
        return NULL;
    CFDataRef sub;
    size_t bpr = im->bpr;
    if (im->bpp % 8 == 0) {
        size_t start = y * im->bpr + x * im->bpp / 8, len = (h - 1) * im->bpr + w * im->bpp / 8;
        if (start + len > (size_t)CFDataGetLength(all)) {
            CFRelease(all);
            return NULL;
        }
        sub = CFDataCreate(NULL, CFDataGetBytePtr(all) + start, (CFIndex)len);
    } else {
        /* sub-byte pixels: repack the rows */
        bpr = (w * im->bpp + 7) / 8;
        CFMutableDataRef m = CFDataCreateMutable(NULL, (CFIndex)(bpr * h));
        CFDataSetLength(m, (CFIndex)(bpr * h));
        uint8_t *out = CFDataGetMutableBytePtr(m);
        memset(out, 0, bpr * h);
        const uint8_t *in = CFDataGetBytePtr(all);
        for (size_t row = 0; row < h; row++)
            for (size_t bit = 0; bit < w * im->bpp; bit++) {
                size_t src = (x * im->bpp + bit);
                int v = (in[(y + row) * im->bpr + src / 8] >> (7 - src % 8)) & 1;
                out[row * bpr + bit / 8] |= (uint8_t)(v << (7 - bit % 8));
            }
        sub = m;
    }
    CFRelease(all);
    CGDataProviderRef p = CGDataProviderCreateWithCFData(sub);
    CFRelease(sub);
    struct CGImage *c = image_create(w, h, im->bpc, im->bpp, bpr, im->space, im->info, p, im->decode,
                                     im->interpolate, im->intent, im->is_mask);
    CFRelease(p);
    if (c && im->mask)
        c->mask = (CGImageRef)CFRetain(im->mask);
    return c;
}

CGImageRef
CGImageCreateWithMask(CGImageRef im, CGImageRef mask)
{
    if (!im || !mask || im->is_mask)
        return NULL;
    if (!mask->is_mask && (!mask->space || CGColorSpaceGetModel(mask->space) != kCGColorSpaceModelMonochrome))
        return NULL;
    struct CGImage *c = image_clone(im);
    if (c) {
        if (c->mask)
            CFRelease(c->mask);
        c->mask = (CGImageRef)CFRetain(mask);
    }
    return c;
}

CGImageRef
CGImageCreateWithMaskingColors(CGImageRef im, const CGFloat *components)
{
    if (!im || !components || im->is_mask || alpha_slots(CGImageGetAlphaInfo(im)) ||
        im->space->kind == CG_SPACE_INDEXED)
        return NULL;
    struct CGImage *c = image_clone(im);
    if (c) {
        size_t n = CGColorSpaceGetNumberOfComponents(im->space);
        free(c->masking);
        c->masking = (CGFloat *)malloc(2 * n * sizeof(CGFloat));
        memcpy(c->masking, components, 2 * n * sizeof(CGFloat));
    }
    return c;
}

CGImageRef
CGImageRetain(CGImageRef im)
{
    return im ? (CGImageRef)CFRetain(im) : NULL;
}

void
CGImageRelease(CGImageRef im)
{
    if (im)
        CFRelease(im);
}

bool CGImageIsMask(CGImageRef im) { return im && im->is_mask; }
size_t CGImageGetWidth(CGImageRef im) { return im ? im->width : 0; }
size_t CGImageGetHeight(CGImageRef im) { return im ? im->height : 0; }
size_t CGImageGetBitsPerComponent(CGImageRef im) { return im ? im->bpc : 0; }
size_t CGImageGetBitsPerPixel(CGImageRef im) { return im ? im->bpp : 0; }
size_t CGImageGetBytesPerRow(CGImageRef im) { return im ? im->bpr : 0; }
CGColorSpaceRef CGImageGetColorSpace(CGImageRef im) { return im ? im->space : NULL; }
CGBitmapInfo CGImageGetBitmapInfo(CGImageRef im) { return im ? im->info : 0; }
CGDataProviderRef CGImageGetDataProvider(CGImageRef im) { return im ? im->provider : NULL; }
const CGFloat *CGImageGetDecode(CGImageRef im) { return im ? im->decode : NULL; }
bool CGImageGetShouldInterpolate(CGImageRef im) { return im && im->interpolate; }
CGColorRenderingIntent CGImageGetRenderingIntent(CGImageRef im) { return im ? im->intent : kCGRenderingIntentDefault; }
CFStringRef CGImageGetUTType(CGImageRef im) { return im ? im->uttype : NULL; }
float CGImageGetContentHeadroom(CGImageRef im) { return im ? im->headroom : 0; }
bool CGImageShouldToneMap(CGImageRef im) { return false; }
bool CGImageContainsImageSpecificToneMappingMetadata(CGImageRef im) { return false; }

CGImageAlphaInfo
CGImageGetAlphaInfo(CGImageRef im)
{
    return im ? (CGImageAlphaInfo)(im->info & kCGBitmapAlphaInfoMask) : kCGImageAlphaNone;
}

CGImageByteOrderInfo
CGImageGetByteOrderInfo(CGImageRef im)
{
    return im ? (CGImageByteOrderInfo)(im->info & kCGBitmapByteOrderMask) : kCGImageByteOrderDefault;
}

CGImagePixelFormatInfo
CGImageGetPixelFormatInfo(CGImageRef im)
{
    return im ? (CGImagePixelFormatInfo)(im->info & kCGImagePixelFormatMask) : kCGImagePixelFormatPacked;
}

CFDataRef
CGImageCopyBytes(CGImageRef im)
{
    pthread_mutex_lock(&cache_lock);
    if (!im->data)
        ((struct CGImage *)im)->data = CGDataProviderCopyData(im->provider);
    CFDataRef d = im->data ? (CFDataRef)CFRetain(im->data) : NULL;
    pthread_mutex_unlock(&cache_lock);
    return d;
}

#pragma mark - Unpacking

namespace {

struct Reader {
    const uint8_t *data;
    size_t len, row_bytes;
    CGPixelLayout l;
    size_t ncomp;
    CGImageAlphaInfo alpha;

    /* Logical component k of pixel (x, y): colour 0..ncomp-1, alpha ncomp. */
    double comp(size_t x, size_t y, size_t k) const
    {
        if (y * l.bpr + row_bytes > len)
            return 0;
        return l.get(data + y * l.bpr, x, k);
    }
};

}  // namespace

/* Colour components (decoded) and alpha (unpremultiplied) of each pixel. */
static void
read_pixel(const Reader &r, const CGFloat *decode, size_t x, size_t y, double *colour, double *alpha)
{
    for (size_t k = 0; k < r.ncomp; k++) {
        double v = r.comp(x, y, k);
        if (decode)
            v = decode[2 * k] + v * (decode[2 * k + 1] - decode[2 * k]);
        colour[k] = v;
    }
    double a = r.l.has_alpha() ? r.comp(x, y, r.ncomp) : 1;
    if (r.l.premultiplied() && a > 0)
        for (size_t k = 0; k < r.ncomp; k++)
            colour[k] /= a;
    *alpha = a;
}

static Reader
reader_for(CGImageRef im, CFDataRef bytes)
{
    Reader r;
    r.data = CFDataGetBytePtr(bytes);
    r.len = (size_t)CFDataGetLength(bytes);
    r.ncomp = im->is_mask ? 1 : CGColorSpaceGetNumberOfComponents(im->space);
    r.l = CGPixelLayout::make(im->bpc, im->bpp, im->bpr, r.ncomp, im->is_mask ? 0 : im->info);
    r.alpha = r.l.alpha;
    r.row_bytes = (im->width * im->bpp + 7) / 8;
    return r;
}

/* Mask coverage at image pixel (x, y): 1 = painted. */
static double
mask_coverage(CGImageRef mask, const Reader &mr, size_t x, size_t y, size_t w, size_t h)
{
    size_t mx = x * mask->width / w, my = y * mask->height / h;
    double c[4], a;
    read_pixel(mr, mask->is_mask ? NULL : mask->decode, mx, my, c, &a);
    double v = c[0];
    if (mask->is_mask && mask->decode)
        v = mask->decode[0] + v * (mask->decode[1] - mask->decode[0]);
    return mask->is_mask ? 1 - v : v;
}

static void
release_cfdata(const void *, void *ctx)
{
    CFRelease((CFDataRef)ctx);
}

static sk_sp<SkImage>
wrap_direct(CGImageRef im, CFDataRef bytes)
{
    if (im->is_mask || im->decode || im->masking || im->mask || im->bpc != 8)
        return nullptr;
    CGColorSpaceRef cs = im->space;
    bool rgb = cs->kind == CG_SPACE_DEVICE_RGB || (cs->kind == CG_SPACE_MATRIX && cs->model == kCGColorSpaceModelRGB);
    bool gray = cs->kind == CG_SPACE_DEVICE_GRAY || (cs->kind == CG_SPACE_MATRIX && cs->model == kCGColorSpaceModelMonochrome);
    CGImageAlphaInfo a = CGImageGetAlphaInfo(im);
    uint32_t order = im->info & kCGBitmapByteOrderMask;
    SkColorType ct = kUnknown_SkColorType;
    SkAlphaType at = kPremul_SkAlphaType;
    if (rgb && im->bpp == 32) {
        bool big = order == kCGBitmapByteOrderDefault || order == kCGBitmapByteOrder32Big;
        bool little = order == kCGBitmapByteOrder32Little;
        if (big && (a == kCGImageAlphaPremultipliedLast || a == kCGImageAlphaLast || a == kCGImageAlphaNoneSkipLast))
            ct = kRGBA_8888_SkColorType;
        else if (little && (a == kCGImageAlphaPremultipliedFirst || a == kCGImageAlphaFirst || a == kCGImageAlphaNoneSkipFirst))
            ct = kBGRA_8888_SkColorType;
        if (a == kCGImageAlphaLast || a == kCGImageAlphaFirst)
            at = kUnpremul_SkAlphaType;
        else if (a == kCGImageAlphaNoneSkipLast || a == kCGImageAlphaNoneSkipFirst)
            at = kOpaque_SkAlphaType;
        if (ct == kRGBA_8888_SkColorType && at == kOpaque_SkAlphaType)
            ct = kRGB_888x_SkColorType;
    } else if (gray && im->bpp == 8 && a == kCGImageAlphaNone) {
        ct = kGray_8_SkColorType;
        at = kOpaque_SkAlphaType;
    }
    if (ct == kUnknown_SkColorType || (size_t)CFDataGetLength(bytes) < (im->height - 1) * im->bpr + im->width * im->bpp / 8)
        return nullptr;
    CFRetain(bytes);
    sk_sp<SkData> data = SkData::MakeWithProc(CFDataGetBytePtr(bytes), (size_t)CFDataGetLength(bytes), release_cfdata,
                                              (void *)bytes);
    SkImageInfo info = SkImageInfo::Make((int)im->width, (int)im->height, ct, at, CGSkColorSpace(cs));
    return SkImages::RasterFromData(info, std::move(data), im->bpr);
}

static sk_sp<SkImage>
unpack(CGImageRef im, CFDataRef bytes)
{
    size_t w = im->width, h = im->height;
    Reader r = reader_for(im, bytes);
    if (im->is_mask) {
        /* A8: painted where the (decoded) sample is 0 */
        SkImageInfo info = SkImageInfo::MakeA8((int)w, (int)h);
        SkBitmap bm;
        bm.allocPixels(info);
        for (size_t y = 0; y < h; y++) {
            uint8_t *row = (uint8_t *)bm.getAddr(0, (int)y);
            for (size_t x = 0; x < w; x++) {
                double v = r.comp(x, y, 0);
                if (im->decode)
                    v = im->decode[0] + v * (im->decode[1] - im->decode[0]);
                row[x] = (uint8_t)lround(fmin(1, fmax(0, 1 - v)) * 255);
            }
        }
        bm.setImmutable();
        return bm.asImage();
    }
    CGColorSpaceRef cs = im->space;
    CGColorSpaceRef pixel_space = cs->kind == CG_SPACE_INDEXED ? cs->base_space : cs;
    bool direct_rgb = pixel_space->kind == CG_SPACE_DEVICE_RGB ||
                      (pixel_space->kind == CG_SPACE_MATRIX && pixel_space->model == kCGColorSpaceModelRGB);
    bool direct_gray = pixel_space->kind == CG_SPACE_DEVICE_GRAY ||
                       (pixel_space->kind == CG_SPACE_MATRIX && pixel_space->model == kCGColorSpaceModelMonochrome);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    sk_sp<SkColorSpace> skcs = CGSkColorSpace(direct_rgb || direct_gray ? pixel_space : srgb);
    bool wide = im->bpc > 8 || (im->info & kCGBitmapFloatComponents) || pixel_space->extended;
    SkImageInfo info = SkImageInfo::Make((int)w, (int)h, wide ? kRGBA_F32_SkColorType : kRGBA_8888_SkColorType,
                                         kUnpremul_SkAlphaType, skcs);
    SkBitmap bm;
    bm.allocPixels(info);
    Reader mr = {};
    CFDataRef mask_bytes = NULL;
    if (im->mask) {
        mask_bytes = CGImageCopyBytes(im->mask);
        mr = reader_for(im->mask, mask_bytes);
    }
    size_t n = CGColorSpaceGetNumberOfComponents(cs);
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            double c[CG_MAX_COMPONENTS], a, rgba[4];
            read_pixel(r, im->decode, x, y, c, &a);
            if (im->masking) {
                bool inside = true;
                for (size_t k = 0; k < n && inside; k++) {
                    double scale = (im->info & kCGBitmapFloatComponents) ? 1 : (double)((1u << (im->bpc == 32 ? 31 : im->bpc)) - 1);
                    double v = c[k] * scale;
                    inside = v >= im->masking[2 * k] && v <= im->masking[2 * k + 1];
                }
                if (inside)
                    a = 0;
            }
            if (im->mask)
                a *= mask_coverage(im->mask, mr, x, y, w, h);
            if (cs->kind == CG_SPACE_INDEXED) {
                long idx = lround(c[0] * (im->decode ? 1 : (double)((1u << im->bpc) - 1)));
                if (idx < 0)
                    idx = 0;
                if (idx >= (long)cs->table_count)
                    idx = (long)cs->table_count - 1;
                for (size_t k = 0; k < cs->base_space->n; k++)
                    c[k] = cs->table[idx * cs->base_space->n + k] / 255.0;
            }
            if (direct_rgb) {
                rgba[0] = c[0], rgba[1] = c[1], rgba[2] = c[2];
            } else if (direct_gray) {
                rgba[0] = rgba[1] = rgba[2] = c[0];
            } else {
                CGFloat in[CG_MAX_COMPONENTS], out[4];
                for (size_t k = 0; k < pixel_space->n; k++)
                    in[k] = c[k];
                CGColorSpaceConvertComponents(pixel_space, in, srgb, out);
                rgba[0] = out[0], rgba[1] = out[1], rgba[2] = out[2];
            }
            rgba[3] = a;
            if (wide) {
                float *p = (float *)bm.getAddr((int)x, (int)y);
                for (int k = 0; k < 4; k++)
                    p[k] = (float)rgba[k];
            } else {
                uint8_t *p = (uint8_t *)bm.getAddr((int)x, (int)y);
                for (int k = 0; k < 4; k++)
                    p[k] = (uint8_t)lround(fmin(1, fmax(0, rgba[k])) * 255);
            }
        }
    }
    if (mask_bytes)
        CFRelease(mask_bytes);
    CFRelease(srgb);
    bm.setImmutable();
    return bm.asImage();
}

sk_sp<SkImage>
CGImageGetSkImage(CGImageRef im)
{
    pthread_mutex_lock(&cache_lock);
    SkImage *cached = (SkImage *)im->skimage;
    if (cached)
        cached->ref();
    pthread_mutex_unlock(&cache_lock);
    if (cached)
        return sk_sp<SkImage>(cached);
    CFDataRef bytes = CGImageCopyBytes(im);
    if (!bytes)
        return nullptr;
    sk_sp<SkImage> image = wrap_direct(im, bytes);
    if (!image)
        image = unpack(im, bytes);
    CFRelease(bytes);
    if (!image)
        return nullptr;
    pthread_mutex_lock(&cache_lock);
    if (!im->skimage) {
        image->ref();
        ((struct CGImage *)im)->skimage = image.get();
    }
    pthread_mutex_unlock(&cache_lock);
    return image;
}

#pragma mark - PNG and JPEG

static CGImageRef
decode_with_codec(CGDataProviderRef source, const CGFloat *decode, bool interpolate, CGColorRenderingIntent intent)
{
    CFDataRef bytes = source ? CGDataProviderCopyData(source) : NULL;
    if (!bytes)
        return NULL;
    sk_sp<SkData> data = SkData::MakeWithCopy(CFDataGetBytePtr(bytes), (size_t)CFDataGetLength(bytes));
    CFRelease(bytes);
    std::unique_ptr<SkCodec> codec = SkCodec::MakeFromData(data);
    if (!codec)
        return NULL;
    SkImageInfo info = codec->getInfo();
    bool opaque = info.alphaType() == kOpaque_SkAlphaType;
    SkImageInfo out = SkImageInfo::Make(info.width(), info.height(), kRGBA_8888_SkColorType,
                                        opaque ? kOpaque_SkAlphaType : kUnpremul_SkAlphaType, SkColorSpace::MakeSRGB());
    size_t bpr = out.minRowBytes();
    CFMutableDataRef pixels = CFDataCreateMutable(NULL, (CFIndex)(bpr * info.height()));
    CFDataSetLength(pixels, (CFIndex)(bpr * info.height()));
    if (codec->getPixels(out, CFDataGetMutableBytePtr(pixels), bpr) != SkCodec::kSuccess) {
        CFRelease(pixels);
        return NULL;
    }
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef p = CGDataProviderCreateWithCFData(pixels);
    CFRelease(pixels);
    CGImageRef im = image_create((size_t)info.width(), (size_t)info.height(), 8, 32, bpr, srgb,
                                 opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaLast, p, decode, interpolate,
                                 intent, false);
    CFRelease(p);
    CFRelease(srgb);
    return im;
}

CGImageRef
CGImageCreateWithPNGDataProvider(CGDataProviderRef source, const CGFloat *decode, bool shouldInterpolate,
                                 CGColorRenderingIntent intent)
{
    return decode_with_codec(source, decode, shouldInterpolate, intent);
}

CGImageRef
CGImageCreateWithJPEGDataProvider(CGDataProviderRef source, const CGFloat *decode, bool shouldInterpolate,
                                  CGColorRenderingIntent intent)
{
    return decode_with_codec(source, decode, shouldInterpolate, intent);
}
