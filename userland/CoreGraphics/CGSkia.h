/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Bridges from CG's types to Skia's. */
#ifndef CG_SKIA_H
#define CG_SKIA_H

#include "CGPathInternal.h"
#include "CGImageInternal.h"
#include "include/core/SkBlendMode.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkImage.h"
#include "include/core/SkMatrix.h"
#include "include/core/SkPath.h"

CG_PRIVATE sk_sp<SkColorSpace> CGSkColorSpace(CGColorSpaceRef cs);
CG_PRIVATE SkMatrix CGSkMatrix(const CGAffineTransform &t);
CG_PRIVATE CGAffineTransform CGFromSkMatrix(const SkMatrix &m);
CG_PRIVATE SkPath CGSkPath(CGPathRef path, const CGAffineTransform *t, bool evenOdd);
CG_PRIVATE CGMutablePathRef CGPathFromSkPath(const SkPath &path);
CG_PRIVATE sk_sp<SkImage> CGImageGetSkImage(CGImageRef im);

#endif
