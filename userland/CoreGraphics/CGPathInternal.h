/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CGPath's representation, shared with the context and the Skia bridge. */
#ifndef CG_PATH_INTERNAL_H
#define CG_PATH_INTERNAL_H

#include "CGInternal.h"
#include <vector>

struct CGPathElem {
    CGPathElementType type;
    CGPoint p[3];
};

struct CGPath {
    CGRuntimeBase base;
    std::vector<CGPathElem> *elems;
    CGPoint start, current;
    bool has_current;
    bool is_mutable;
};

static inline int
CGPathElemPointCount(CGPathElementType type)
{
    switch (type) {
    case kCGPathElementMoveToPoint:
    case kCGPathElementAddLineToPoint:
        return 1;
    case kCGPathElementAddQuadCurveToPoint:
        return 2;
    case kCGPathElementAddCurveToPoint:
        return 3;
    default:
        return 0;
    }
}

CG_PRIVATE void CGPathFlatten(CGPathRef path, const CGAffineTransform *m, CGFloat tolerance,
                   std::vector<std::vector<CGPoint>> &out);

#endif
