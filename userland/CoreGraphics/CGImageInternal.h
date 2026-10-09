/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CGImage's representation, shared with the context. */
#ifndef CG_IMAGE_INTERNAL_H
#define CG_IMAGE_INTERNAL_H

#include "CGColorSpaceInternal.h"

#define CG_MAX_COMPONENTS 32

struct CGImage {
    CGRuntimeBase base;
    size_t width, height, bpc, bpp, bpr;
    CGColorSpaceRef space;  /* NULL for masks */
    CGBitmapInfo info;
    CGDataProviderRef provider;
    CGFloat *decode;
    bool interpolate;
    CGColorRenderingIntent intent;
    bool is_mask;
    CGImageRef mask;        /* CGImageCreateWithMask */
    CGFloat *masking;       /* CGImageCreateWithMaskingColors */
    CFStringRef uttype;
    float headroom;
    CFDataRef data;         /* the provider's bytes, read once */
    void *skimage;          /* cached SkImage */
};

#ifdef __cplusplus
extern "C" {
#endif
/* The provider's bytes (cached). */
CG_PRIVATE CFDataRef CGImageCopyBytes(CGImageRef im);
/* An image over a copy of `data`, as a bitmap context makes them. */
CG_PRIVATE CGImageRef CGImageCreateFromBytes(size_t w, size_t h, size_t bpc, size_t bpp, size_t bpr,
                                             CGColorSpaceRef space, CGBitmapInfo info, CFDataRef data,
                                             const CGFloat *decode, bool mask);
#ifdef __cplusplus
}
#endif

#endif
