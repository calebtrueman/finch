/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CGColor's representation, shared with the context. */
#ifndef CG_COLOR_INTERNAL_H
#define CG_COLOR_INTERNAL_H

#include "CGColorSpaceInternal.h"

#define CG_COLOR_MAX_COMPONENTS 33

struct CGColor {
    CGRuntimeBase base;
    CGColorSpaceRef space;
    CGPatternRef pattern;
    size_t n;  /* components including alpha */
    CGFloat comps[CG_COLOR_MAX_COMPONENTS];
    float headroom;
};

#ifdef __cplusplus
extern "C" {
#endif
/* The colour's components converted to `target` (an RGB space), plus alpha. */
CG_PRIVATE void CGColorGetRGBA(CGColorRef c, CGColorSpaceRef target, CGFloat out[4]);
#ifdef __cplusplus
}
#endif

#endif
