/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CGColorSpace's representation and colour conversion, shared with CGColor and the context. */
#ifndef CG_COLORSPACE_INTERNAL_H
#define CG_COLORSPACE_INTERNAL_H

#include "CGInternal.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ICC parametric curve: y = (a x + b)^g + e for x >= d, else c x + f. */
typedef struct {
    int kind;  /* CG_TF_PARAM, CG_TF_PQ, CG_TF_HLG */
    double g, a, b, c, d, e, f;
} CGTransferFn;

enum { CG_TF_PARAM, CG_TF_PQ, CG_TF_HLG };

enum {
    CG_SPACE_DEVICE_RGB,
    CG_SPACE_DEVICE_GRAY,
    CG_SPACE_DEVICE_CMYK,
    CG_SPACE_MATRIX,   /* RGB or gray: transfer functions and colorants (named, calibrated, or from ICC) */
    CG_SPACE_LAB,
    CG_SPACE_XYZ,
    CG_SPACE_CMYK,     /* generic CMYK (converted naively, like device CMYK) */
    CG_SPACE_ICC_LUT,  /* ICC profile with lookup tables, converted through skcms */
    CG_SPACE_INDEXED,
    CG_SPACE_PATTERN,
};

struct CGColorSpace {
    CGRuntimeBase base;
    int kind;
    CGColorSpaceModel model;
    size_t n;
    int named;             /* index into the named-space table + 1, or 0 */
    const char *desc;      /* profile description, for named or ICC spaces */
    bool calibrated;
    bool extended;
    bool wide;
    CGTransferFn trc[3];   /* per channel; gray uses trc[0] */
    double toXYZ[9];       /* linear RGB to XYZ (D50), row-major */
    double fromXYZ[9];
    double white[3], black[3], range[4];
    CGColorSpaceRef base_space;
    unsigned char *table;
    size_t table_count;
    CFDataRef icc;         /* as given, or generated on demand */
    void *profile;         /* skcms_ICCProfile, for CG_SPACE_ICC_LUT */
};

/* Convert components (without alpha) between spaces: colorimetric, D50. */
CG_PRIVATE void CGColorSpaceConvertComponents(CGColorSpaceRef src, const CGFloat *in, CGColorSpaceRef dst,
                                              CGFloat *out);
/* Linear XYZ (D50) of components, and back (clamped unless the space is extended). */
CG_PRIVATE void CGColorSpaceToXYZ(CGColorSpaceRef cs, const CGFloat *in, double xyz[3]);
CG_PRIVATE void CGColorSpaceFromXYZ(CGColorSpaceRef cs, const double xyz[3], CGFloat *out);
/* The space a colour lands in when matched to `cs` (device spaces resolve to sRGB / Gray Gamma 2.2). */
CG_PRIVATE CGColorSpaceRef CGColorSpaceResolveDevice(CGColorSpaceRef cs);
/* "<CGColorSpace 0x...> (...)" */
CG_PRIVATE CFStringRef CGColorSpaceCopyDebugDescription(CGColorSpaceRef cs);

#ifdef __cplusplus
}
#endif

#endif
