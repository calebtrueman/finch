/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGColorSpace: device, named (ICC-based), calibrated, Lab, indexed and
 * pattern spaces, with colorimetric conversion through XYZ (D50).
 *
 * Named spaces carry the colorimetry of the standards they name (sRGB,
 * Display P3, BT.709/2020/2100, Adobe RGB (1998), ROMM, ACEScg, DCI-P3)
 * and of Apple's generic spaces as macOS describes them (Generic RGB:
 * gamma 1.8 with its own primaries; "Gray Gamma 2.2": the sRGB curve).
 * Their ICC profiles are generated here, not copied. ICC data is parsed
 * with skcms (Skia's); a profile matching a named space becomes that space.
 */
#include "CGColorSpaceInternal.h"
#include "modules/skcms/skcms.h"
#include <CommonCrypto/CommonDigest.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

#pragma mark - Names

#define NAME(n) const CFStringRef n = CFSTR(#n);
extern "C" {
NAME(kCGColorSpaceGenericGray)
NAME(kCGColorSpaceGenericRGB)
NAME(kCGColorSpaceGenericCMYK)
NAME(kCGColorSpaceDisplayP3)
NAME(kCGColorSpaceGenericRGBLinear)
NAME(kCGColorSpaceAdobeRGB1998)
NAME(kCGColorSpaceSRGB)
NAME(kCGColorSpaceGenericGrayGamma2_2)
NAME(kCGColorSpaceGenericXYZ)
NAME(kCGColorSpaceGenericLab)
NAME(kCGColorSpaceACESCGLinear)
NAME(kCGColorSpaceITUR_709)
NAME(kCGColorSpaceITUR_709_PQ)
NAME(kCGColorSpaceITUR_709_HLG)
NAME(kCGColorSpaceITUR_2020)
NAME(kCGColorSpaceITUR_2020_sRGBGamma)
NAME(kCGColorSpaceROMMRGB)
NAME(kCGColorSpaceDCIP3)
NAME(kCGColorSpaceLinearITUR_2020)
NAME(kCGColorSpaceExtendedITUR_2020)
NAME(kCGColorSpaceExtendedLinearITUR_2020)
NAME(kCGColorSpaceLinearDisplayP3)
NAME(kCGColorSpaceExtendedDisplayP3)
NAME(kCGColorSpaceExtendedLinearDisplayP3)
NAME(kCGColorSpaceITUR_2100_PQ)
NAME(kCGColorSpaceITUR_2100_HLG)
NAME(kCGColorSpaceDisplayP3_PQ)
NAME(kCGColorSpaceDisplayP3_HLG)
NAME(kCGColorSpaceITUR_2020_PQ)
NAME(kCGColorSpaceITUR_2020_HLG)
NAME(kCGColorSpaceDisplayP3_PQ_EOTF)
NAME(kCGColorSpaceITUR_2020_PQ_EOTF)
NAME(kCGColorSpaceExtendedSRGB)
NAME(kCGColorSpaceLinearSRGB)
NAME(kCGColorSpaceExtendedLinearSRGB)
NAME(kCGColorSpaceExtendedGray)
NAME(kCGColorSpaceLinearGray)
NAME(kCGColorSpaceExtendedLinearGray)
NAME(kCGColorSpaceCoreMedia709)
NAME(kCGColorSpaceExtendedRange)
}

enum Trc { T_SRGB, T_LINEAR, T_G18, T_ADOBE, T_709, T_2020, T_ROMM, T_DCI, T_CM709, T_PQ, T_HLG, T_NONE };
enum Prim { P_SRGB, P_P3, P_2020, P_ADOBE, P_GENERIC, P_GENERIC_LINEAR, P_ACES, P_ROMM, P_DCI, P_NONE };

/* Colorants, adapted to D50 (Bradford), as the profiles carry them. */
static const double prims[][9] = {
    /* rX gX bX / rY gY bY / rZ gZ bZ */
    {0.436066, 0.385147, 0.143066, 0.222488, 0.716873, 0.060608, 0.013916, 0.097076, 0.714096},
    {0.515121, 0.291977, 0.157104, 0.241196, 0.692245, 0.066574, -0.001053, 0.041885, 0.784073},
    {0.673477, 0.165665, 0.125046, 0.279037, 0.675339, 0.045609, -0.001938, 0.029984, 0.796844},
    {0.609741, 0.205276, 0.149185, 0.311111, 0.625671, 0.063217, 0.019470, 0.060867, 0.744568},
    {0.454300, 0.353348, 0.156647, 0.241913, 0.673630, 0.084457, 0.014893, 0.090637, 0.719574},
    {0.454300, 0.353302, 0.156601, 0.242599, 0.674393, 0.083405, 0.014801, 0.090393, 0.719498},
    {0.689880, 0.149765, 0.124557, 0.284515, 0.671692, 0.043793, -0.006042, 0.010010, 0.820938},
    {0.797668, 0.135193, 0.031357, 0.288040, 0.711884, 0.000092, 0.000000, 0.000000, 0.825195},
    {0.486160, 0.323853, 0.154190, 0.226685, 0.710327, 0.062988, -0.000809, 0.043228, 0.782471},
};

static const double D50[3] = {0.9642, 1.0, 0.8249};

struct Named {
    CFStringRef const *name;
    int id;
    int kind;
    CGColorSpaceModel model;
    const char *desc;
    Trc trc;
    Prim prim;
    bool extended, wide;
    CFStringRef const *lin, *ext, *extlin, *std;
    CFStringRef const *alias_of;
};

#define M CG_SPACE_MATRIX
static const Named named_spaces[] = {
    {&kCGColorSpaceGenericGray, 0, M, kCGColorSpaceModelMonochrome, "Generic Gray Profile", T_G18, P_NONE, false, false},
    {&kCGColorSpaceGenericRGB, 0, M, kCGColorSpaceModelRGB, "Generic RGB Profile", T_G18, P_GENERIC, false, false},
    {&kCGColorSpaceGenericCMYK, 0, CG_SPACE_CMYK, kCGColorSpaceModelCMYK, "Generic CMYK Profile", T_NONE, P_NONE, false, false},
    {&kCGColorSpaceDisplayP3, 7, M, kCGColorSpaceModelRGB, "Display P3", T_SRGB, P_P3, false, true,
     &kCGColorSpaceLinearDisplayP3, &kCGColorSpaceExtendedDisplayP3, &kCGColorSpaceExtendedLinearDisplayP3},
    {&kCGColorSpaceGenericRGBLinear, 0, M, kCGColorSpaceModelRGB, "Generic RGB Linear Profile", T_LINEAR, P_GENERIC_LINEAR, false, false},
    {&kCGColorSpaceAdobeRGB1998, 14, M, kCGColorSpaceModelRGB, "Adobe RGB (1998)", T_ADOBE, P_ADOBE, false, true},
    {&kCGColorSpaceSRGB, 15, M, kCGColorSpaceModelRGB, "sRGB IEC61966-2.1", T_SRGB, P_SRGB, false, false,
     &kCGColorSpaceLinearSRGB, &kCGColorSpaceExtendedSRGB, &kCGColorSpaceExtendedLinearSRGB},
    {&kCGColorSpaceGenericGrayGamma2_2, 1, M, kCGColorSpaceModelMonochrome, "Generic Gray Gamma 2.2 Profile", T_SRGB, P_NONE, false, false,
     &kCGColorSpaceLinearGray, &kCGColorSpaceExtendedGray, &kCGColorSpaceExtendedLinearGray},
    {&kCGColorSpaceGenericXYZ, 6, CG_SPACE_XYZ, kCGColorSpaceModelXYZ, "Generic XYZ Profile", T_NONE, P_NONE, true, false},
    {&kCGColorSpaceGenericLab, 5, CG_SPACE_LAB, kCGColorSpaceModelLab, "Generic Lab color space", T_NONE, P_NONE, false, false},
    {&kCGColorSpaceACESCGLinear, 19, M, kCGColorSpaceModelRGB, "ACES CG Linear (Academy Color Encoding System AP1)", T_LINEAR, P_ACES, false, true},
    {&kCGColorSpaceITUR_709, 20, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.709-5", T_709, P_SRGB, false, false,
     &kCGColorSpaceLinearSRGB, NULL, &kCGColorSpaceExtendedLinearSRGB},
    {&kCGColorSpaceITUR_709_PQ, 21, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.709-5; SMPTE ST 2084 PQ", T_PQ, P_SRGB, false, false,
     &kCGColorSpaceLinearSRGB, NULL, &kCGColorSpaceExtendedLinearSRGB},
    {&kCGColorSpaceITUR_709_HLG, 22, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.709-5; ARIB STD-B67 HLG", T_HLG, P_SRGB, false, false,
     &kCGColorSpaceLinearSRGB, NULL, &kCGColorSpaceExtendedLinearSRGB},
    {&kCGColorSpaceITUR_2020, 23, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.2020-1", T_2020, P_2020, false, true,
     &kCGColorSpaceLinearITUR_2020, &kCGColorSpaceExtendedITUR_2020, &kCGColorSpaceExtendedLinearITUR_2020},
    {&kCGColorSpaceITUR_2020_sRGBGamma, 27, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.2020-1; sRGB Gamma", T_SRGB, P_2020, false, true,
     &kCGColorSpaceLinearITUR_2020, NULL, &kCGColorSpaceExtendedLinearITUR_2020},
    {&kCGColorSpaceROMMRGB, 30, M, kCGColorSpaceModelRGB, "ROMM RGB: ISO 22028-2:2013", T_ROMM, P_ROMM, false, true},
    {&kCGColorSpaceDCIP3, 31, M, kCGColorSpaceModelRGB, "SMPTE RP 431-2-2007 DCI (P3)", T_DCI, P_DCI, false, true},
    {&kCGColorSpaceLinearITUR_2020, 24, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.2020-1 Linear", T_LINEAR, P_2020, false, true,
     &kCGColorSpaceLinearITUR_2020, &kCGColorSpaceExtendedLinearITUR_2020, &kCGColorSpaceExtendedLinearITUR_2020},
    {&kCGColorSpaceExtendedITUR_2020, 25, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.2020-1", T_2020, P_2020, true, true,
     &kCGColorSpaceExtendedLinearITUR_2020, &kCGColorSpaceExtendedITUR_2020, &kCGColorSpaceExtendedLinearITUR_2020, &kCGColorSpaceITUR_2020},
    {&kCGColorSpaceExtendedLinearITUR_2020, 26, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.2020-1 Linear", T_LINEAR, P_2020, true, true,
     &kCGColorSpaceExtendedLinearITUR_2020, &kCGColorSpaceExtendedLinearITUR_2020, &kCGColorSpaceExtendedLinearITUR_2020, &kCGColorSpaceLinearITUR_2020},
    {&kCGColorSpaceLinearDisplayP3, 9, M, kCGColorSpaceModelRGB, "Display P3 Linear", T_LINEAR, P_P3, false, true,
     &kCGColorSpaceLinearDisplayP3, &kCGColorSpaceExtendedLinearDisplayP3, &kCGColorSpaceExtendedLinearDisplayP3},
    {&kCGColorSpaceExtendedDisplayP3, 8, M, kCGColorSpaceModelRGB, "Display P3", T_SRGB, P_P3, true, true,
     &kCGColorSpaceExtendedLinearDisplayP3, &kCGColorSpaceExtendedDisplayP3, &kCGColorSpaceExtendedLinearDisplayP3, &kCGColorSpaceDisplayP3},
    {&kCGColorSpaceExtendedLinearDisplayP3, 10, M, kCGColorSpaceModelRGB, "Display P3 Linear", T_LINEAR, P_P3, true, true,
     &kCGColorSpaceExtendedLinearDisplayP3, &kCGColorSpaceExtendedLinearDisplayP3, &kCGColorSpaceExtendedLinearDisplayP3, &kCGColorSpaceLinearDisplayP3},
    {&kCGColorSpaceITUR_2100_PQ, 28, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.2100 PQ", T_PQ, P_2020, false, true,
     &kCGColorSpaceLinearITUR_2020, NULL, &kCGColorSpaceExtendedLinearITUR_2020},
    {&kCGColorSpaceITUR_2100_HLG, 29, M, kCGColorSpaceModelRGB, "Rec. ITU-R BT.2100 HLG", T_HLG, P_2020, false, true,
     &kCGColorSpaceLinearITUR_2020, NULL, &kCGColorSpaceExtendedLinearITUR_2020},
    {&kCGColorSpaceDisplayP3_PQ, 11, M, kCGColorSpaceModelRGB, "Display P3; SMPTE ST 2084 PQ", T_PQ, P_P3, false, true,
     &kCGColorSpaceLinearDisplayP3, NULL, &kCGColorSpaceExtendedLinearDisplayP3},
    {&kCGColorSpaceDisplayP3_HLG, 12, M, kCGColorSpaceModelRGB, "Display P3; ARIB STD-B67 HLG", T_HLG, P_P3, false, true,
     &kCGColorSpaceLinearDisplayP3, NULL, &kCGColorSpaceExtendedLinearDisplayP3},
    {&kCGColorSpaceExtendedSRGB, 16, M, kCGColorSpaceModelRGB, "sRGB IEC61966-2.1", T_SRGB, P_SRGB, true, true,
     &kCGColorSpaceExtendedLinearSRGB, &kCGColorSpaceExtendedSRGB, &kCGColorSpaceExtendedLinearSRGB, &kCGColorSpaceSRGB},
    {&kCGColorSpaceLinearSRGB, 17, M, kCGColorSpaceModelRGB, "sRGB IEC61966-2.1 Linear", T_LINEAR, P_SRGB, false, false,
     &kCGColorSpaceLinearSRGB, &kCGColorSpaceExtendedLinearSRGB, &kCGColorSpaceExtendedLinearSRGB},
    {&kCGColorSpaceExtendedLinearSRGB, 18, M, kCGColorSpaceModelRGB, "sRGB IEC61966-2.1 Linear", T_LINEAR, P_SRGB, true, true,
     &kCGColorSpaceExtendedLinearSRGB, &kCGColorSpaceExtendedLinearSRGB, &kCGColorSpaceExtendedLinearSRGB, &kCGColorSpaceLinearSRGB},
    {&kCGColorSpaceExtendedGray, 2, M, kCGColorSpaceModelMonochrome, "Generic Gray Gamma 2.2 Profile", T_SRGB, P_NONE, true, false,
     &kCGColorSpaceExtendedLinearGray, &kCGColorSpaceExtendedGray, &kCGColorSpaceExtendedLinearGray, &kCGColorSpaceGenericGrayGamma2_2},
    {&kCGColorSpaceLinearGray, 3, M, kCGColorSpaceModelMonochrome, "Linear Gray", T_LINEAR, P_NONE, false, false,
     &kCGColorSpaceLinearGray, &kCGColorSpaceExtendedLinearGray, &kCGColorSpaceExtendedLinearGray},
    {&kCGColorSpaceExtendedLinearGray, 4, M, kCGColorSpaceModelMonochrome, "Linear Gray", T_LINEAR, P_NONE, true, false,
     &kCGColorSpaceExtendedLinearGray, &kCGColorSpaceExtendedLinearGray, &kCGColorSpaceExtendedLinearGray, &kCGColorSpaceLinearGray},
    {&kCGColorSpaceCoreMedia709, 32, M, kCGColorSpaceModelRGB, "HDTV", T_CM709, P_SRGB, false, false},
    /* aliases */
    {&kCGColorSpaceDisplayP3_PQ_EOTF, 0, 0, kCGColorSpaceModelUnknown, NULL, T_NONE, P_NONE, false, false,
     NULL, NULL, NULL, NULL, &kCGColorSpaceDisplayP3_PQ},
    {&kCGColorSpaceITUR_2020_PQ_EOTF, 0, 0, kCGColorSpaceModelUnknown, NULL, T_NONE, P_NONE, false, false,
     NULL, NULL, NULL, NULL, &kCGColorSpaceITUR_2100_PQ},
    {&kCGColorSpaceITUR_2020_PQ, 0, 0, kCGColorSpaceModelUnknown, NULL, T_NONE, P_NONE, false, false,
     NULL, NULL, NULL, NULL, &kCGColorSpaceITUR_2100_PQ},
    {&kCGColorSpaceITUR_2020_HLG, 0, 0, kCGColorSpaceModelUnknown, NULL, T_NONE, P_NONE, false, false,
     NULL, NULL, NULL, NULL, &kCGColorSpaceITUR_2100_HLG},
};
#undef M
static const int named_count = sizeof named_spaces / sizeof named_spaces[0];

static CGTransferFn
transfer_for(Trc t)
{
    switch (t) {
    case T_SRGB: return {CG_TF_PARAM, 2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045, 0, 0};
    case T_G18: return {CG_TF_PARAM, 1.8, 1, 0, 0, 0, 0, 0};
    case T_ADOBE: return {CG_TF_PARAM, 2.2, 1, 0, 0, 0, 0, 0};
    case T_709: return {CG_TF_PARAM, 1 / 0.45, 1 / 1.099, 0.099 / 1.099, 1 / 4.5, 0.081, 0, 0};
    case T_2020: return {CG_TF_PARAM, 1 / 0.45, 1 / 1.0993, 0.0993 / 1.0993, 1 / 4.5, 0.08145, 0, 0};
    case T_ROMM: return {CG_TF_PARAM, 1.8, 1, 0, 1 / 16.0, 1 / 512.0, 0, 0};
    case T_DCI: return {CG_TF_PARAM, 2.6, 1, 0, 0, 0, 0, 0};
    case T_CM709: return {CG_TF_PARAM, 1.961, 1, 0, 0, 0, 0, 0};
    case T_PQ: return {CG_TF_PQ, 1, 1, 0, 0, 0, 0, 0};
    case T_HLG: return {CG_TF_HLG, 1, 1, 0, 0, 0, 0, 0};
    default: return {CG_TF_PARAM, 1, 1, 0, 0, 0, 0, 0};
    }
}

#pragma mark - Transfer functions and matrices

static double
tf_eval1(const CGTransferFn &t, double x)
{
    switch (t.kind) {
    case CG_TF_PQ: {
        const double m1 = 2610 / 16384.0, m2 = 2523 / 4096.0 * 128, c1 = 3424 / 4096.0, c2 = 2413 / 4096.0 * 32,
                     c3 = 2392 / 4096.0 * 32;
        double p = pow(fmax(x, 0), 1 / m2);
        return pow(fmax(p - c1, 0) / (c2 - c3 * p), 1 / m1);
    }
    case CG_TF_HLG: {
        const double a = 0.17883277, b = 0.28466892, c = 0.55991073;
        return x <= 0.5 ? x * x / 3 : (exp((x - c) / a) + b) / 12;
    }
    default:
        if (x >= t.d)
            return pow(t.a * x + t.b, t.g) + t.e;
        return t.c * x + t.f;
    }
}

static double
tf_inv1(const CGTransferFn &t, double y)
{
    switch (t.kind) {
    case CG_TF_PQ: {
        const double m1 = 2610 / 16384.0, m2 = 2523 / 4096.0 * 128, c1 = 3424 / 4096.0, c2 = 2413 / 4096.0 * 32,
                     c3 = 2392 / 4096.0 * 32;
        double p = pow(fmax(y, 0), m1);
        return pow((c1 + c2 * p) / (1 + c3 * p), m2);
    }
    case CG_TF_HLG: {
        const double a = 0.17883277, b = 0.28466892, c = 0.55991073;
        return y <= 1 / 12.0 ? sqrt(3 * fmax(y, 0)) : a * log(12 * y - b) + c;
    }
    default: {
        double yd = t.d > 0 ? pow(t.a * t.d + t.b, t.g) + t.e : t.f;
        if (y >= yd || t.c == 0) {
            double v = y - t.e;
            return ((v > 0 ? pow(v, 1 / t.g) : 0) - t.b) / t.a;
        }
        return (y - t.f) / t.c;
    }
    }
}

static double
tf_eval(const CGTransferFn &t, double x, bool extended)
{
    if (extended && x < 0)
        return -tf_eval1(t, -x);
    return tf_eval1(t, x);
}

static double
tf_inv(const CGTransferFn &t, double y, bool extended)
{
    if (extended && y < 0)
        return -tf_inv1(t, -y);
    return tf_inv1(t, y);
}

static void
mat_mul(const double m[9], const double v[3], double out[3])
{
    double r[3];
    for (int i = 0; i < 3; i++)
        r[i] = m[3 * i] * v[0] + m[3 * i + 1] * v[1] + m[3 * i + 2] * v[2];
    out[0] = r[0], out[1] = r[1], out[2] = r[2];
}

static void
mat_mul3(const double a[9], const double b[9], double out[9])
{
    double r[9];
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            r[3 * i + j] = a[3 * i] * b[j] + a[3 * i + 1] * b[3 + j] + a[3 * i + 2] * b[6 + j];
    memcpy(out, r, sizeof r);
}

static bool
mat_inv(const double m[9], double out[9])
{
    double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (det == 0)
        return false;
    double r[9] = {(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                   (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                   (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det};
    memcpy(out, r, sizeof r);
    return true;
}

/* Bradford adaptation from `white` to D50. */
static void
bradford_to_d50(const double white[3], double out[9])
{
    static const double B[9] = {0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296};
    double Binv[9], src[3], dst[3];
    mat_inv(B, Binv);
    mat_mul(B, white, src);
    mat_mul(B, D50, dst);
    double S[9] = {dst[0] / src[0], 0, 0, 0, dst[1] / src[1], 0, 0, 0, dst[2] / src[2]};
    double t[9];
    mat_mul3(S, B, t);
    mat_mul3(Binv, t, out);
}

#pragma mark - CF type

static void
space_finalize(CFTypeRef cf)
{
    struct CGColorSpace *cs = (struct CGColorSpace *)cf;
    if (cs->base_space)
        CFRelease(cs->base_space);
    free(cs->table);
    if (cs->icc)
        CFRelease(cs->icc);
    free(cs->profile);
}

static const char *
model_name(CGColorSpaceModel m)
{
    switch (m) {
    case kCGColorSpaceModelMonochrome: return "kCGColorSpaceModelMonochrome";
    case kCGColorSpaceModelRGB: return "kCGColorSpaceModelRGB";
    case kCGColorSpaceModelCMYK: return "kCGColorSpaceModelCMYK";
    case kCGColorSpaceModelLab: return "kCGColorSpaceModelLab";
    case kCGColorSpaceModelDeviceN: return "kCGColorSpaceModelDeviceN";
    case kCGColorSpaceModelIndexed: return "kCGColorSpaceModelIndexed";
    case kCGColorSpaceModelPattern: return "kCGColorSpaceModelPattern";
    case kCGColorSpaceModelXYZ: return "kCGColorSpaceModelXYZ";
    default: return "kCGColorSpaceModelUnknown";
    }
}

static CFStringRef
lab_detail(CGColorSpaceRef cs, const char *desc)
{
    char buf[256];
    snprintf(buf, sizeof buf, "%s%swhite point [%.4f, %.4f, %.4f] range [%.1f %.1f, %.1f %.1f]", desc ? desc : "",
             desc ? "; " : "", cs->white[0], cs->white[1], cs->white[2], cs->range[0], cs->range[1], cs->range[2],
             cs->range[3]);
    return CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
}

CFStringRef
CGColorSpaceCopyDebugDescription(CGColorSpaceRef cs)
{
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    CFStringAppendFormat(s, NULL, CFSTR("<CGColorSpace %p> ("), cs);
    switch (cs->kind) {
    case CG_SPACE_DEVICE_RGB: CFStringAppend(s, CFSTR("kCGColorSpaceDeviceRGB")); break;
    case CG_SPACE_DEVICE_GRAY: CFStringAppend(s, CFSTR("kCGColorSpaceDeviceGray")); break;
    case CG_SPACE_DEVICE_CMYK: CFStringAppend(s, CFSTR("kCGColorSpaceDeviceCMYK")); break;
    case CG_SPACE_INDEXED: {
        CFStringRef base = CGColorSpaceCopyDebugDescription(cs->base_space);
        CFStringAppendFormat(s, NULL, CFSTR("kCGColorSpaceIndexed; base %@"), base);
        CFRelease(base);
        break;
    }
    case CG_SPACE_PATTERN: CFStringAppend(s, CFSTR("kCGColorSpacePattern")); break;
    case CG_SPACE_LAB: {
        CFStringRef d = lab_detail(cs, cs->desc);
        CFStringAppendFormat(s, NULL, CFSTR("kCGColorSpaceLAB; %@"), d);
        CFRelease(d);
        break;
    }
    default:
        if (cs->calibrated) {
            CFStringAppend(s, cs->model == kCGColorSpaceModelMonochrome ? CFSTR("kCGColorSpaceCalibratedGray")
                                                                         : CFSTR("kCGColorSpaceCalibratedRGB"));
            break;
        }
        CFStringAppendFormat(s, NULL, CFSTR("kCGColorSpaceICCBased; %s; %s"), model_name(cs->model),
                             cs->desc ? cs->desc : "");
        if (cs->extended)
            CFStringAppend(s, CFSTR("; extended range"));
        break;
    }
    CFStringAppend(s, CFSTR(")"));
    return s;
}

static CFStringRef
space_desc(CFTypeRef cf)
{
    return CGColorSpaceCopyDebugDescription((CGColorSpaceRef)cf);
}

static Boolean
space_equal(CFTypeRef a, CFTypeRef b)
{
    CGColorSpaceRef x = (CGColorSpaceRef)a, y = (CGColorSpaceRef)b;
    if (x->kind != y->kind || x->model != y->model || x->n != y->n || x->named != y->named ||
        x->extended != y->extended)
        return false;
    if (x->named)
        return true;
    if (x->kind == CG_SPACE_INDEXED)
        return CFEqual(x->base_space, y->base_space) && x->table_count == y->table_count &&
               !memcmp(x->table, y->table, x->table_count * x->base_space->n);
    if (x->kind == CG_SPACE_PATTERN)
        return x->base_space == y->base_space || (x->base_space && y->base_space && CFEqual(x->base_space, y->base_space));
    if (x->icc && y->icc)
        return CFEqual(x->icc, y->icc);
    return !memcmp(x->toXYZ, y->toXYZ, sizeof x->toXYZ) && !memcmp(x->trc, y->trc, sizeof x->trc) &&
           !memcmp(x->white, y->white, sizeof x->white);
}

static CFHashCode
space_hash(CFTypeRef cf)
{
    CGColorSpaceRef cs = (CGColorSpaceRef)cf;
    return (CFHashCode)(cs->kind * 31 + cs->model * 7 + cs->named);
}

static const CGRuntimeClass space_class = {
    0, "CGColorSpace", NULL, NULL, space_finalize, space_equal, space_hash, NULL, space_desc, NULL, NULL, 0,
};
static CFTypeID space_type;

CFTypeID
CGColorSpaceGetTypeID(void)
{
    return CGTypeRegister(&space_class, &space_type);
}

static struct CGColorSpace *
space_new(int kind, CGColorSpaceModel model, size_t n)
{
    struct CGColorSpace *cs =
        (struct CGColorSpace *)CGTypeCreateInstance(CGColorSpaceGetTypeID(), sizeof(struct CGColorSpace));
    cs->kind = kind;
    cs->model = model;
    cs->n = n;
    for (int i = 0; i < 3; i++)
        cs->trc[i] = transfer_for(T_LINEAR);
    memcpy(cs->white, D50, sizeof D50);
    return cs;
}

/*
 * Colorants as the profile's s15Fixed16 values, scaled so that white
 * (1, 1, 1) maps to D50 exactly: neutrals stay neutral between spaces, as
 * with Apple's CMM.
 */
static void
set_matrix(struct CGColorSpace *cs, const double m[9])
{
    for (int r = 0; r < 3; r++) {
        double row[3], sum = 0;
        for (int c = 0; c < 3; c++)
            sum += row[c] = round(m[3 * r + c] * 65536) / 65536;
        for (int c = 0; c < 3; c++)
            cs->toXYZ[3 * r + c] = sum != 0 ? row[c] * D50[r] / sum : row[c];
    }
    mat_inv(cs->toXYZ, cs->fromXYZ);
}

#pragma mark - Device and named spaces

static pthread_mutex_t singletons_lock = PTHREAD_MUTEX_INITIALIZER;
static struct CGColorSpace *named_singletons[64];
static struct CGColorSpace *device_rgb, *device_gray, *device_cmyk;

static struct CGColorSpace *
make_named(int i)
{
    const Named &e = named_spaces[i];
    struct CGColorSpace *cs = space_new(e.kind, e.model, e.model == kCGColorSpaceModelMonochrome ? 1
                                                          : e.model == kCGColorSpaceModelCMYK ? 4 : 3);
    cs->named = i + 1;
    cs->desc = e.desc;
    cs->extended = e.extended;
    cs->wide = e.wide;
    if (e.kind == CG_SPACE_MATRIX) {
        CGTransferFn t = transfer_for(e.trc);
        cs->trc[0] = cs->trc[1] = cs->trc[2] = t;
        if (e.prim != P_NONE)
            set_matrix(cs, prims[e.prim]);
    }
    if (e.kind == CG_SPACE_LAB) {
        cs->range[0] = cs->range[2] = -128;
        cs->range[1] = cs->range[3] = 128;
    }
    return cs;
}

static int
named_index(CFStringRef name)
{
    if (!name)
        return -1;
    for (int i = 0; i < named_count; i++)
        if (CFEqual(name, *named_spaces[i].name)) {
            if (named_spaces[i].alias_of)
                return named_index(*named_spaces[i].alias_of);
            return i;
        }
    return -1;
}

static CGColorSpaceRef
named_space(int i)
{
    pthread_mutex_lock(&singletons_lock);
    if (!named_singletons[i])
        named_singletons[i] = make_named(i);
    CGColorSpaceRef cs = named_singletons[i];
    pthread_mutex_unlock(&singletons_lock);
    return (CGColorSpaceRef)CFRetain(cs);
}

static CGColorSpaceRef
named_space_by_name(CFStringRef name)
{
    int i = named_index(name);
    return i < 0 ? NULL : named_space(i);
}

static CGColorSpaceRef
device_space(struct CGColorSpace **slot, int kind, CGColorSpaceModel model, size_t n)
{
    pthread_mutex_lock(&singletons_lock);
    if (!*slot)
        *slot = space_new(kind, model, n);
    CGColorSpaceRef cs = *slot;
    pthread_mutex_unlock(&singletons_lock);
    return (CGColorSpaceRef)CFRetain(cs);
}

CGColorSpaceRef
CGColorSpaceCreateDeviceRGB(void)
{
    return device_space(&device_rgb, CG_SPACE_DEVICE_RGB, kCGColorSpaceModelRGB, 3);
}

CGColorSpaceRef
CGColorSpaceCreateDeviceGray(void)
{
    return device_space(&device_gray, CG_SPACE_DEVICE_GRAY, kCGColorSpaceModelMonochrome, 1);
}

CGColorSpaceRef
CGColorSpaceCreateDeviceCMYK(void)
{
    return device_space(&device_cmyk, CG_SPACE_DEVICE_CMYK, kCGColorSpaceModelCMYK, 4);
}

CGColorSpaceRef
CGColorSpaceCreateWithName(CFStringRef name)
{
    if (!name)
        return NULL;
    if (CFEqual(name, CFSTR("kCGColorSpaceDeviceRGB")))
        return CGColorSpaceCreateDeviceRGB();
    if (CFEqual(name, CFSTR("kCGColorSpaceDeviceGray")))
        return CGColorSpaceCreateDeviceGray();
    if (CFEqual(name, CFSTR("kCGColorSpaceDeviceCMYK")))
        return CGColorSpaceCreateDeviceCMYK();
    return named_space_by_name(name);
}

CGColorSpaceRef
CGColorSpaceRetain(CGColorSpaceRef cs)
{
    return cs ? (CGColorSpaceRef)CFRetain(cs) : NULL;
}

void
CGColorSpaceRelease(CGColorSpaceRef cs)
{
    if (cs)
        CFRelease(cs);
}

CFStringRef
CGColorSpaceGetName(CGColorSpaceRef cs)
{
    if (!cs)
        return NULL;
    switch (cs->kind) {
    case CG_SPACE_DEVICE_RGB: return CFSTR("kCGColorSpaceDeviceRGB");
    case CG_SPACE_DEVICE_GRAY: return CFSTR("kCGColorSpaceDeviceGray");
    case CG_SPACE_DEVICE_CMYK: return CFSTR("kCGColorSpaceDeviceCMYK");
    case CG_SPACE_PATTERN: return cs->base_space ? NULL : CFSTR("kCGColorSpaceColoredPattern");
    }
    return cs->named ? *named_spaces[cs->named - 1].name : NULL;
}

CFStringRef
CGColorSpaceCopyName(CGColorSpaceRef cs)
{
    CFStringRef name = CGColorSpaceGetName(cs);
    return name ? (CFStringRef)CFRetain(name) : NULL;
}

size_t
CGColorSpaceGetNumberOfComponents(CGColorSpaceRef cs)
{
    return cs ? cs->n : 0;
}

CGColorSpaceModel
CGColorSpaceGetModel(CGColorSpaceRef cs)
{
    return cs ? cs->model : kCGColorSpaceModelUnknown;
}

CGColorSpaceRef
CGColorSpaceGetBaseColorSpace(CGColorSpaceRef cs)
{
    return cs ? cs->base_space : NULL;
}

CGColorSpaceRef
CGColorSpaceCopyBaseColorSpace(CGColorSpaceRef cs)
{
    return cs && cs->base_space ? (CGColorSpaceRef)CFRetain(cs->base_space) : NULL;
}

size_t
CGColorSpaceGetColorTableCount(CGColorSpaceRef cs)
{
    return cs ? cs->table_count : 0;
}

void
CGColorSpaceGetColorTable(CGColorSpaceRef cs, uint8_t *table)
{
    if (cs && table && cs->table)
        memcpy(table, cs->table, cs->table_count * cs->base_space->n);
}

static const Named *
entry(CGColorSpaceRef cs)
{
    return cs && cs->named ? &named_spaces[cs->named - 1] : NULL;
}

bool
CGColorSpaceIsWideGamutRGB(CGColorSpaceRef cs)
{
    return cs && cs->model == kCGColorSpaceModelRGB && cs->wide;
}

static bool
is_pq(CGColorSpaceRef cs)
{
    return cs && cs->kind == CG_SPACE_MATRIX && cs->trc[0].kind == CG_TF_PQ;
}

static bool
is_hlg(CGColorSpaceRef cs)
{
    return cs && cs->kind == CG_SPACE_MATRIX && cs->trc[0].kind == CG_TF_HLG;
}

bool CGColorSpaceIsPQBased(CGColorSpaceRef cs) { return is_pq(cs); }
bool CGColorSpaceIsHLGBased(CGColorSpaceRef cs) { return is_hlg(cs); }
bool CGColorSpaceIsHDR(CGColorSpaceRef cs) { return is_pq(cs) || is_hlg(cs); }
bool CGColorSpaceUsesITUR_2100TF(CGColorSpaceRef cs) { return is_pq(cs) || is_hlg(cs); }

bool
CGColorSpaceSupportsOutput(CGColorSpaceRef cs)
{
    return cs && cs->kind != CG_SPACE_INDEXED && cs->kind != CG_SPACE_PATTERN;
}

bool
CGColorSpaceUsesExtendedRange(CGColorSpaceRef cs)
{
    return cs && cs->extended;
}

/* An unnamed copy of a matrix space, linear and/or extended. */
static CGColorSpaceRef
matrix_variant(CGColorSpaceRef cs, bool linear, bool extended)
{
    struct CGColorSpace *v = space_new(CG_SPACE_MATRIX, cs->model, cs->n);
    memcpy(v->trc, cs->trc, sizeof v->trc);
    memcpy(v->toXYZ, cs->toXYZ, sizeof v->toXYZ);
    memcpy(v->fromXYZ, cs->fromXYZ, sizeof v->fromXYZ);
    memcpy(v->white, cs->white, sizeof v->white);
    v->desc = cs->desc;
    v->extended = extended;
    v->wide = extended ? cs->model == kCGColorSpaceModelRGB : cs->wide;
    if (linear)
        for (int i = 0; i < 3; i++)
            v->trc[i] = transfer_for(T_LINEAR);
    return v;
}

/* which: 0 linearized, 1 extended, 2 extended linearized, 3 standard range */
static CGColorSpaceRef
variant(CGColorSpaceRef cs, int which)
{
    if (!cs)
        return NULL;
    const Named *e = entry(cs);
    if (e) {
        CFStringRef const *target = which == 0 ? e->lin : which == 1 ? e->ext : which == 2 ? e->extlin : e->std;
        if (target)
            return named_space_by_name(*target);
    }
    if (which == 3) {
        if (!e && cs->extended && cs->kind == CG_SPACE_MATRIX)
            return matrix_variant(cs, false, false);
        return CGColorSpaceRetain(cs);
    }
    if (cs->kind != CG_SPACE_MATRIX || is_pq(cs) || is_hlg(cs))
        return NULL;
    bool linear = which != 1, extended = which != 0 || cs->extended;
    return matrix_variant(cs, linear, extended);
}

CGColorSpaceRef CGColorSpaceCreateLinearized(CGColorSpaceRef cs) { return variant(cs, 0); }
CGColorSpaceRef CGColorSpaceCreateExtended(CGColorSpaceRef cs) { return variant(cs, 1); }
CGColorSpaceRef CGColorSpaceCreateExtendedLinearized(CGColorSpaceRef cs) { return variant(cs, 2); }
CGColorSpaceRef CGColorSpaceCreateCopyWithStandardRange(CGColorSpaceRef cs) { return variant(cs, 3); }

#pragma mark - Calibrated, Lab, indexed, pattern

CGColorSpaceRef
CGColorSpaceCreateCalibratedGray(const CGFloat whitePoint[3], const CGFloat blackPoint[3], CGFloat gamma)
{
    if (!whitePoint || whitePoint[1] != 1 || whitePoint[0] <= 0 || whitePoint[2] <= 0)
        return NULL;
    struct CGColorSpace *cs = space_new(CG_SPACE_MATRIX, kCGColorSpaceModelMonochrome, 1);
    cs->calibrated = true;
    for (int i = 0; i < 3; i++) {
        cs->white[i] = whitePoint[i];
        cs->black[i] = blackPoint ? blackPoint[i] : 0;
    }
    cs->trc[0] = cs->trc[1] = cs->trc[2] = (CGTransferFn){CG_TF_PARAM, gamma, 1, 0, 0, 0, 0, 0};
    return cs;
}

CGColorSpaceRef
CGColorSpaceCreateCalibratedRGB(const CGFloat whitePoint[3], const CGFloat blackPoint[3], const CGFloat gamma[3],
                                const CGFloat matrix[9])
{
    if (!whitePoint || whitePoint[1] != 1 || whitePoint[0] <= 0 || whitePoint[2] <= 0)
        return NULL;
    struct CGColorSpace *cs = space_new(CG_SPACE_MATRIX, kCGColorSpaceModelRGB, 3);
    cs->calibrated = true;
    for (int i = 0; i < 3; i++) {
        cs->white[i] = whitePoint[i];
        cs->black[i] = blackPoint ? blackPoint[i] : 0;
        cs->trc[i] = (CGTransferFn){CG_TF_PARAM, gamma ? gamma[i] : 1, 1, 0, 0, 0, 0, 0};
    }
    /* matrix: columns are the XYZ of red, green and blue (PDF's CalRGB order) */
    double m[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    if (matrix)
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++)
                m[3 * r + c] = matrix[3 * c + r];
    double adapt[9], w[3] = {whitePoint[0], whitePoint[1], whitePoint[2]};
    bradford_to_d50(w, adapt);
    mat_mul3(adapt, m, m);
    set_matrix(cs, m);
    return cs;
}

CGColorSpaceRef
CGColorSpaceCreateLab(const CGFloat whitePoint[3], const CGFloat blackPoint[3], const CGFloat range[4])
{
    if (!whitePoint || whitePoint[1] != 1 || whitePoint[0] <= 0 || whitePoint[2] <= 0)
        return NULL;
    struct CGColorSpace *cs = space_new(CG_SPACE_LAB, kCGColorSpaceModelLab, 3);
    for (int i = 0; i < 3; i++) {
        cs->white[i] = whitePoint[i];
        cs->black[i] = blackPoint ? blackPoint[i] : 0;
    }
    for (int i = 0; i < 4; i++)
        cs->range[i] = range ? range[i] : (i & 1 ? 100 : -100);
    return cs;
}

CGColorSpaceRef
CGColorSpaceCreateIndexed(CGColorSpaceRef base, size_t lastIndex, const unsigned char *table)
{
    if (!base || !table || lastIndex > 255 || base->kind == CG_SPACE_PATTERN || base->kind == CG_SPACE_INDEXED)
        return NULL;
    struct CGColorSpace *cs = space_new(CG_SPACE_INDEXED, kCGColorSpaceModelIndexed, 1);
    cs->base_space = (CGColorSpaceRef)CFRetain(base);
    cs->table_count = lastIndex + 1;
    cs->table = (unsigned char *)malloc(cs->table_count * base->n);
    memcpy(cs->table, table, cs->table_count * base->n);
    return cs;
}

CGColorSpaceRef
CGColorSpaceCreatePattern(CGColorSpaceRef base)
{
    struct CGColorSpace *cs = space_new(CG_SPACE_PATTERN, kCGColorSpaceModelPattern, base ? base->n : 0);
    if (base)
        cs->base_space = (CGColorSpaceRef)CFRetain(base);
    return cs;
}

CGColorSpaceRef
CGColorSpaceCreateWithPlatformColorSpace(const void *ref)
{
    return NULL;  /* ColorSync profiles: not on Finch */
}

CGColorSpaceRef
CGColorSpaceCreateWithColorSyncProfile(ColorSyncProfileRef profile, CFDictionaryRef options)
{
    return NULL;
}

#pragma mark - ICC parsing

static const char *
icc_description(const uint8_t *d, size_t len)
{
    if (len < 132)
        return NULL;
    uint32_t n = (uint32_t)d[128] << 24 | d[129] << 16 | d[130] << 8 | d[131];
    for (uint32_t i = 0; i < n && 132 + 12 * (i + 1) <= len; i++) {
        const uint8_t *t = d + 132 + 12 * i;
        if (memcmp(t, "desc", 4))
            continue;
        uint32_t off = (uint32_t)t[4] << 24 | t[5] << 16 | t[6] << 8 | t[7];
        uint32_t sz = (uint32_t)t[8] << 24 | t[9] << 16 | t[10] << 8 | t[11];
        if (off + sz > len || sz < 12)
            return NULL;
        const uint8_t *b = d + off;
        static char buf[8][256];
        static int slot;
        char *out = buf[slot++ & 7];
        if (!memcmp(b, "desc", 4)) {
            uint32_t cnt = (uint32_t)b[8] << 24 | b[9] << 16 | b[10] << 8 | b[11];
            if (cnt > sz - 12)
                cnt = sz - 12;
            snprintf(out, 256, "%.*s", (int)cnt, (const char *)b + 12);
            return strdup(out);  /* kept for the space's lifetime */
        }
        if (!memcmp(b, "mluc", 4) && sz >= 28) {
            uint32_t slen = (uint32_t)b[20] << 24 | b[21] << 16 | b[22] << 8 | b[23];
            uint32_t soff = (uint32_t)b[24] << 24 | b[25] << 16 | b[26] << 8 | b[27];
            if (soff + slen > sz)
                return NULL;
            size_t k = 0;
            for (uint32_t j = 0; j + 1 < slen && k < 255; j += 2) {
                uint16_t ch = (uint16_t)(b[soff + j] << 8 | b[soff + j + 1]);
                out[k++] = ch < 128 ? (char)ch : '?';
            }
            out[k] = 0;
            return strdup(out);  /* kept for the space's lifetime */
        }
    }
    return NULL;
}

static bool
curve_to_tf(const skcms_Curve *c, CGTransferFn *out)
{
    skcms_TransferFunction tf;
    if (c->table_entries == 0) {
        tf = c->parametric;
    } else {
        float err;
        if (!skcms_ApproximateCurve(c, &tf, &err))
            return false;
    }
    *out = (CGTransferFn){CG_TF_PARAM, tf.g, tf.a, tf.b, tf.c, tf.d, tf.e, tf.f};
    return true;
}

/* The named space this matrix space is, if any (non-extended, matrix spaces). */
static int
match_named(const struct CGColorSpace *cs)
{
    static const double xs[] = {0.02, 0.05, 0.1, 0.2, 0.35, 0.5, 0.65, 0.8, 1.0};
    for (int i = 0; i < named_count; i++) {
        const Named &e = named_spaces[i];
        if (e.alias_of || e.kind != CG_SPACE_MATRIX || e.extended || e.model != cs->model)
            continue;
        if (e.trc == T_PQ || e.trc == T_HLG)
            continue;
        if (e.model == kCGColorSpaceModelRGB) {
            bool ok = true;
            for (int k = 0; k < 9 && ok; k++)
                ok = fabs(prims[e.prim][k] - cs->toXYZ[k]) < 0.002;
            if (!ok)
                continue;
        }
        CGTransferFn t = transfer_for(e.trc);
        bool ok = true;
        for (double x : xs)
            for (int ch = 0; ch < (int)cs->n && ok; ch++)
                ok = fabs(tf_eval1(t, x) - tf_eval1(cs->trc[ch], x)) < 0.003;
        if (ok)
            return i;
    }
    return -1;
}

/*
 * SHA-256 fingerprints of the profiles Apple's CG hands out for its named
 * spaces (hashes only: the profiles aren't Finch's to ship). Apple names an
 * ICC-based space only when its data is one of those exactly; Finch also
 * names exact copies of the profiles it generates.
 */
static const struct {
    const char *sha256;
    CFStringRef const *name;
} apple_profiles[] = {
    {"7a06987f2d7e458e98fa744c4acad9f3610f3c895c04a98179970d380d8a46e8", &kCGColorSpaceACESCGLinear},
    {"304f569a83c1e5eddaddac54e99ed03339333db013738bb499ab64f049887e28", &kCGColorSpaceAdobeRGB1998},
    {"a1096ca47d80ba9df7f9f8fa87a0b9446d9b6a2c94ab11e4144495616b1eb29b", &kCGColorSpaceCoreMedia709},
    {"651a3f9c51ac383fa0a099374bd1e5030f45e6dc6af2520eadb151c0dc8fe3df", &kCGColorSpaceDCIP3},
    {"3a168ff9230c9feb394544e58a2ebf15601534eebd9680149886107882b14270", &kCGColorSpaceDisplayP3_HLG},
    {"aa36691d3056a6ddb4ed3d59e3ea98d6fff0a0f0328bc6dd34011d73e0a30bcb", &kCGColorSpaceDisplayP3_PQ},
    {"0ff6958f98684c61f6bbdce1368ddeaf3873baf84545baba482e920d92a914c0", &kCGColorSpaceDisplayP3},
    {"73d504558e7d03ef4ff2676ba62c7553ee5bd856b45da2d330e33e012ad61fb3", &kCGColorSpaceGenericGrayGamma2_2},
    {"cbbe4e27855cdc4af796895db3c99c52bd1a727b70fdd458168d3ae570250a03", &kCGColorSpaceITUR_2020},
    {"bceef6e3d4457bd368146d745ff203fa5adf50aa65460d1a9f3437e2387e7a82", &kCGColorSpaceLinearDisplayP3},
    {"81107f536845d11fdd67ed62b3588bc27776a0e8b8ca787751538fd30d490d9a", &kCGColorSpaceLinearGray},
    {"d3c1c5ca635a45b9bf1a9c69804f4a064b94e8b82a8c42ce272470aa5ecad2c2", &kCGColorSpaceLinearITUR_2020},
    {"42d1e258eddfda5492ad878a0077e1365c9662cfe90789c9663333f24bf3c3ff", &kCGColorSpaceLinearSRGB},
    {"2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e", &kCGColorSpaceSRGB},
    {"0c8a584b288a306eac9e1d3f1e68bc1b64331c717ceb051420e6257f17b3509a", &kCGColorSpaceGenericCMYK},
    {"0ef4da994a2b833d54af2d4ecbb2c6654b7198ad9e6bd80ed86d684e54fd37d3", &kCGColorSpaceGenericGray},
    {"9ba83e9a54788f7a5d22b367bcf4461179798b81d80a7d2cf855a60c93dee09b", &kCGColorSpaceGenericLab},
    {"49429d4dd70f439f6fa47a298e5ffbd280375d2cbd18708b1e05a34aafe5d219", &kCGColorSpaceGenericRGB},
    {"0a11a32e7f42a26fb50d4850c070e4cf59a6eabeaaeae5a2c8a0c4c78d415469", &kCGColorSpaceGenericRGBLinear},
    {"358fecec016b7c44d0e2af5e608c7c3f4aef834c2beb8fce6859e724a1b8a39e", &kCGColorSpaceGenericXYZ},
    {"d2a121c2b94409b82be7c59595ed5a9a90c8fa8d805ce282d9bfd950799bda12", &kCGColorSpaceITUR_2020_sRGBGamma},
    {"7c717549eec7134079950211e768d00a5a42fc4f4a7a1149723227e4bf7519fb", &kCGColorSpaceITUR_2100_HLG},
    {"63cd9f4a8443c71df3633aa0a2ec4594aa8fbca23b1a3231b517bc726a567b16", &kCGColorSpaceITUR_2100_PQ},
    {"d62ddfb7805428a137e4e7f48657b37e429c8ee677ac12a8ad5cc9b1e33bc4d7", &kCGColorSpaceITUR_709_HLG},
    {"20d91982bcc869410ea08f96c40ee11c561b71de07b6ebdde540ec88e7361613", &kCGColorSpaceITUR_709_PQ},
    {"c6f7fab7a70c5236059813295f05eb5fbf3d6f5a03335fbf1b548fce430b035b", &kCGColorSpaceITUR_709},
    {"bf6680b188c0fb882e6094ea5d5ac94cc13cca6f252a98bed1be855c58bb616a", &kCGColorSpaceROMMRGB},
};

static CGColorSpaceRef
named_for_bytes(CFDataRef data)
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(data), (CC_LONG)CFDataGetLength(data), digest);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    for (auto &p : apple_profiles)
        if (!strcmp(p.sha256, hex))
            return named_space_by_name(*p.name);
    return NULL;
}

static CGColorSpaceRef
create_with_icc(CFDataRef data)
{
    if (!data)
        return NULL;
    if (CGColorSpaceRef named = named_for_bytes(data))
        return named;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    size_t len = (size_t)CFDataGetLength(data);
    skcms_ICCProfile profile;
    if (!skcms_Parse(bytes, len, &profile))
        return NULL;
    struct CGColorSpace *cs = NULL;
    switch (profile.data_color_space) {
    case skcms_Signature_RGB:
        if (profile.has_trc && profile.has_toXYZD50) {
            cs = space_new(CG_SPACE_MATRIX, kCGColorSpaceModelRGB, 3);
            for (int i = 0; i < 3; i++)
                if (!curve_to_tf(&profile.trc[i], &cs->trc[i])) {
                    CFRelease(cs);
                    cs = NULL;
                    break;
                }
            if (cs) {
                double m[9];
                for (int r = 0; r < 3; r++)
                    for (int c = 0; c < 3; c++)
                        m[3 * r + c] = profile.toXYZD50.vals[r][c];
                set_matrix(cs, m);
            }
        }
        break;
    case skcms_Signature_Gray:
        if (profile.has_trc) {
            cs = space_new(CG_SPACE_MATRIX, kCGColorSpaceModelMonochrome, 1);
            if (!curve_to_tf(&profile.trc[0], &cs->trc[0])) {
                CFRelease(cs);
                cs = NULL;
            } else {
                cs->trc[1] = cs->trc[2] = cs->trc[0];
            }
        }
        break;
    default:
        break;
    }
    if (cs) {
        /* only an exact copy of a named space's own profile becomes that space, as with Apple's */
        int named = match_named(cs);
        if (named >= 0) {
            CGColorSpaceRef candidate = named_space(named);
            CFDataRef own = CGColorSpaceCopyICCData(candidate);
            bool same = own && CFEqual(own, data);
            if (own)
                CFRelease(own);
            if (same) {
                CFRelease(cs);
                return candidate;
            }
            CFRelease(candidate);
        }
    } else if (profile.has_A2B) {
        CGColorSpaceModel model;
        size_t n;
        switch (profile.data_color_space) {
        case skcms_Signature_RGB: model = kCGColorSpaceModelRGB, n = 3; break;
        case skcms_Signature_CMYK: model = kCGColorSpaceModelCMYK, n = 4; break;
        case skcms_Signature_Gray: model = kCGColorSpaceModelMonochrome, n = 1; break;
        case skcms_Signature_Lab: model = kCGColorSpaceModelLab, n = 3; break;
        case skcms_Signature_XYZ: model = kCGColorSpaceModelXYZ, n = 3; break;
        default: return NULL;
        }
        cs = space_new(CG_SPACE_ICC_LUT, model, n);
        cs->profile = malloc(sizeof profile);
        memcpy(cs->profile, &profile, sizeof profile);
    } else {
        return NULL;
    }
    cs->icc = CFDataCreateCopy(NULL, data);
    /* skcms points into the data: re-parse against our copy */
    if (cs->profile)
        skcms_Parse(CFDataGetBytePtr(cs->icc), (size_t)CFDataGetLength(cs->icc), (skcms_ICCProfile *)cs->profile);
    cs->desc = icc_description(CFDataGetBytePtr(cs->icc), len);
    if (cs->model == kCGColorSpaceModelRGB && cs->kind == CG_SPACE_MATRIX) {
        /* wide: a primary falls outside sRGB */
        CGColorSpaceRef srgb = named_space(named_index(kCGColorSpaceSRGB));
        for (int ch = 0; ch < 3 && !cs->wide; ch++) {
            double xyz[3], lin[3];
            for (int r = 0; r < 3; r++)
                xyz[r] = cs->toXYZ[3 * r + ch];
            mat_mul(srgb->fromXYZ, xyz, lin);
            for (int k = 0; k < 3; k++)
                if (lin[k] < -0.001 || lin[k] > 1.001)
                    cs->wide = true;
        }
        CFRelease(srgb);
    }
    return cs;
}

CGColorSpaceRef
CGColorSpaceCreateWithICCData(CFTypeRef data)
{
    if (!data || CFGetTypeID(data) != CFDataGetTypeID())
        return NULL;
    return create_with_icc((CFDataRef)data);
}

CGColorSpaceRef
CGColorSpaceCreateWithICCProfile(CFDataRef data)
{
    return create_with_icc(data);
}

CGColorSpaceRef
CGColorSpaceCreateICCBased(size_t nComponents, const CGFloat *range, CGDataProviderRef profile, CGColorSpaceRef alternate)
{
    CFDataRef data = profile ? CGDataProviderCopyData(profile) : NULL;
    CGColorSpaceRef cs = data ? create_with_icc(data) : NULL;
    if (data)
        CFRelease(data);
    if (cs && cs->n != nComponents) {
        CFRelease(cs);
        cs = NULL;
    }
    if (!cs && alternate && alternate->n == nComponents)
        cs = (CGColorSpaceRef)CFRetain(alternate);
    return cs;
}

#pragma mark - ICC generation

namespace {
struct Writer {
    std::vector<uint8_t> b;
    void u32(uint32_t v) { for (int i = 3; i >= 0; i--) b.push_back((uint8_t)(v >> (8 * i))); }
    void u16(uint16_t v) { b.push_back((uint8_t)(v >> 8)), b.push_back((uint8_t)v); }
    void sig(const char *s) { b.insert(b.end(), s, s + 4); }
    void s15(double v) { u32((uint32_t)(int32_t)lround(v * 65536)); }
    void pad() { while (b.size() % 4) b.push_back(0); }
};
}

static std::vector<uint8_t>
tag_mluc(const char *text)
{
    Writer w;
    w.sig("mluc"), w.u32(0), w.u32(1), w.u32(12), w.sig("enUS");
    size_t n = strlen(text);
    w.u32((uint32_t)(2 * n)), w.u32(28);
    for (size_t i = 0; i < n; i++)
        w.u16((uint8_t)text[i]);
    return w.b;
}

static std::vector<uint8_t>
tag_xyz(double x, double y, double z)
{
    Writer w;
    w.sig("XYZ "), w.u32(0), w.s15(x), w.s15(y), w.s15(z);
    return w.b;
}

static std::vector<uint8_t>
tag_curve(const CGTransferFn &t)
{
    Writer w;
    if (t.kind == CG_TF_PARAM) {
        w.sig("para"), w.u32(0), w.u16(4), w.u16(0);
        for (double v : {t.g, t.a, t.b, t.c, t.d, t.e, t.f})
            w.s15(v);
    } else {
        w.sig("curv"), w.u32(0), w.u32(1024);
        for (int i = 0; i < 1024; i++)
            w.u16((uint16_t)lround(fmin(1, fmax(0, tf_eval1(t, i / 1023.0))) * 65535));
    }
    return w.b;
}

/* lutAtoBType with B curves only (identity), or a CLUT from `fn` for n inputs. */
static std::vector<uint8_t>
tag_atob(int in, int grid, void (*fn)(const double *in, double *pcs))
{
    Writer w;
    w.sig("mAB "), w.u32(0), w.b.push_back((uint8_t)in), w.b.push_back(3), w.u16(0);
    size_t offsets = w.b.size();
    for (int i = 0; i < 5; i++)
        w.u32(0);
    auto identity_curve = [&]() { w.sig("curv"), w.u32(0), w.u32(0); };
    auto set = [&](int slot, size_t value) {
        for (int i = 0; i < 4; i++)
            w.b[offsets + 4 * slot + i] = (uint8_t)(value >> (24 - 8 * i));
    };
    set(0, w.b.size());  /* B curves */
    for (int i = 0; i < 3; i++)
        identity_curve();
    if (fn) {
        set(3, w.b.size());  /* CLUT */
        for (int i = 0; i < 16; i++)
            w.b.push_back(i < in ? (uint8_t)grid : 0);
        w.b.push_back(2), w.b.push_back(0), w.b.push_back(0), w.b.push_back(0);
        int total = 1;
        for (int i = 0; i < in; i++)
            total *= grid;
        for (int idx = 0; idx < total; idx++) {
            double v[4] = {0}, pcs[3];
            int rem = idx;
            for (int i = in - 1; i >= 0; i--)
                v[i] = (rem % grid) / (double)(grid - 1), rem /= grid;
            fn(v, pcs);
            for (int k = 0; k < 3; k++)
                w.u16((uint16_t)lround(fmin(1, fmax(0, pcs[k])) * 65535));
        }
        w.pad();
        set(4, w.b.size());  /* A curves */
        for (int i = 0; i < in; i++)
            identity_curve();
    }
    return w.b;
}

static void
cmyk_to_pcs_xyz(const double *in, double *pcs)
{
    CGFloat comps[4] = {in[0], in[1], in[2], in[3]}, rgb[3];
    CGColorSpaceRef cmyk = CGColorSpaceCreateDeviceCMYK(), srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceConvertComponents(cmyk, comps, srgb, rgb);
    double xyz[3];
    CGColorSpaceToXYZ(srgb, rgb, xyz);
    for (int k = 0; k < 3; k++)
        pcs[k] = xyz[k] * 32768.0 / 65535.0;  /* XYZ PCS: 1.0 is 0x8000 */
    CFRelease(cmyk), CFRelease(srgb);
}

static CFDataRef
build_icc(CGColorSpaceRef cs)
{
    const char *space, *pcs = "XYZ ", *cls = "mntr";
    std::vector<std::pair<const char *, std::vector<uint8_t>>> tags;
    const char *desc = cs->desc ? cs->desc : cs->model == kCGColorSpaceModelMonochrome ? "Calibrated Gray" : "Calibrated RGB";
    tags.push_back({"desc", tag_mluc(desc)});
    tags.push_back({"cprt", tag_mluc("No copyright, use freely")});
    tags.push_back({"wtpt", tag_xyz(D50[0], D50[1], D50[2])});
    switch (cs->kind) {
    case CG_SPACE_MATRIX:
        if (cs->model == kCGColorSpaceModelMonochrome) {
            space = "GRAY";
            tags.push_back({"kTRC", tag_curve(cs->trc[0])});
        } else {
            space = "RGB ";
            const char *xyz[3] = {"rXYZ", "gXYZ", "bXYZ"}, *trc[3] = {"rTRC", "gTRC", "bTRC"};
            for (int c = 0; c < 3; c++)
                tags.push_back({xyz[c], tag_xyz(cs->toXYZ[c], cs->toXYZ[3 + c], cs->toXYZ[6 + c])});
            for (int c = 0; c < 3; c++)
                tags.push_back({trc[c], tag_curve(cs->trc[c])});
        }
        break;
    case CG_SPACE_LAB:
        space = pcs = "Lab ", cls = "spac";
        tags.push_back({"A2B0", tag_atob(3, 0, NULL)});
        tags.push_back({"B2A0", tag_atob(3, 0, NULL)});
        break;
    case CG_SPACE_XYZ:
        space = "XYZ ", cls = "spac";
        tags.push_back({"A2B0", tag_atob(3, 0, NULL)});
        tags.push_back({"B2A0", tag_atob(3, 0, NULL)});
        break;
    case CG_SPACE_CMYK:
        space = "CMYK", cls = "scnr";
        tags.push_back({"A2B0", tag_atob(4, 9, cmyk_to_pcs_xyz)});
        break;
    default:
        return NULL;
    }
    Writer w;
    w.b.resize(128, 0);
    w.u32((uint32_t)tags.size());
    size_t table = w.b.size();
    w.b.resize(table + 12 * tags.size(), 0);
    for (size_t i = 0; i < tags.size(); i++) {
        w.pad();
        size_t off = w.b.size();
        w.b.insert(w.b.end(), tags[i].second.begin(), tags[i].second.end());
        uint8_t *t = &w.b[table + 12 * i];
        memcpy(t, tags[i].first, 4);
        for (int k = 0; k < 4; k++) {
            t[4 + k] = (uint8_t)(off >> (24 - 8 * k));
            t[8 + k] = (uint8_t)(tags[i].second.size() >> (24 - 8 * k));
        }
    }
    w.pad();
    /* header */
    size_t size = w.b.size();
    uint8_t *h = w.b.data();
    for (int k = 0; k < 4; k++)
        h[k] = (uint8_t)(size >> (24 - 8 * k));
    h[8] = 4, h[9] = 0x30;
    memcpy(h + 12, cls, 4), memcpy(h + 16, space, 4), memcpy(h + 20, pcs, 4);
    h[24] = (2026 >> 8) & 0xff, h[25] = 2026 & 0xff, h[27] = 1, h[29] = 1;
    memcpy(h + 36, "acsp", 4);
    Writer ill;
    ill.s15(D50[0]), ill.s15(D50[1]), ill.s15(D50[2]);
    memcpy(h + 68, ill.b.data(), 12);
    memcpy(h + 80, "fnch", 4);
    return CFDataCreate(NULL, w.b.data(), (CFIndex)w.b.size());
}

CFDataRef
CGColorSpaceCopyICCData(CGColorSpaceRef cs)
{
    if (!cs)
        return NULL;
    switch (cs->kind) {
    case CG_SPACE_DEVICE_RGB:
    case CG_SPACE_DEVICE_GRAY:
    case CG_SPACE_DEVICE_CMYK:
    case CG_SPACE_INDEXED:
    case CG_SPACE_PATTERN:
        return NULL;
    }
    struct CGColorSpace *m = (struct CGColorSpace *)cs;
    if (!__atomic_load_n(&m->icc, __ATOMIC_ACQUIRE)) {
        CFDataRef built = build_icc(cs);  /* outside the lock: it may create spaces */
        CFDataRef expected = NULL;
        if (!built || !__atomic_compare_exchange_n(&m->icc, &expected, built, false, __ATOMIC_ACQ_REL,
                                                   __ATOMIC_ACQUIRE)) {
            if (built)
                CFRelease(built);
        }
    }
    return m->icc ? (CFDataRef)CFRetain(m->icc) : NULL;
}

CFDataRef
CGColorSpaceCopyICCProfile(CGColorSpaceRef cs)
{
    return CGColorSpaceCopyICCData(cs);
}

#pragma mark - Property lists

CFPropertyListRef
CGColorSpaceCopyPropertyList(CGColorSpaceRef cs)
{
    if (!cs)
        return NULL;
    const Named *e = entry(cs);
    if (e && e->id) {
        int id = e->id;
        return CFNumberCreate(NULL, kCFNumberSInt32Type, &id);
    }
    if (e)
        return CFRetain(*e->name);
    switch (cs->kind) {
    case CG_SPACE_DEVICE_RGB: return CFRetain(kCGColorSpaceSRGB);
    case CG_SPACE_DEVICE_GRAY: return CFRetain(kCGColorSpaceGenericGrayGamma2_2);
    case CG_SPACE_DEVICE_CMYK: return CFRetain(kCGColorSpaceGenericCMYK);
    }
    return CGColorSpaceCopyICCData(cs);
}

CGColorSpaceRef
CGColorSpaceCreateWithPropertyList(CFPropertyListRef plist)
{
    if (!plist)
        return NULL;
    CFTypeID t = CFGetTypeID(plist);
    if (t == CFNumberGetTypeID()) {
        int id = 0;
        CFNumberGetValue((CFNumberRef)plist, kCFNumberIntType, &id);
        for (int i = 0; i < named_count; i++)
            if (named_spaces[i].id == id && id)
                return named_space(i);
        return NULL;
    }
    if (t == CFStringGetTypeID())
        return CGColorSpaceCreateWithName((CFStringRef)plist);
    if (t == CFDataGetTypeID())
        return create_with_icc((CFDataRef)plist);
    return NULL;
}

#pragma mark - Conversion

CGColorSpaceRef
CGColorSpaceResolveDevice(CGColorSpaceRef cs)
{
    switch (cs->kind) {
    case CG_SPACE_DEVICE_RGB: return named_space(named_index(kCGColorSpaceSRGB));
    case CG_SPACE_DEVICE_GRAY: return named_space(named_index(kCGColorSpaceGenericGrayGamma2_2));
    default: return (CGColorSpaceRef)CFRetain(cs);
    }
}

static void
lab_to_xyz(const double lab[3], const double white[3], double xyz[3])
{
    double fy = (lab[0] + 16) / 116, fx = fy + lab[1] / 500, fz = fy - lab[2] / 200;
    auto finv = [](double t) { return t > 6.0 / 29 ? t * t * t : 3 * (6.0 / 29) * (6.0 / 29) * (t - 4.0 / 29); };
    xyz[0] = white[0] * finv(fx), xyz[1] = white[1] * finv(fy), xyz[2] = white[2] * finv(fz);
}

static void
xyz_to_lab(const double xyz[3], const double white[3], double lab[3])
{
    auto f = [](double t) { return t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116; };
    double fx = f(xyz[0] / white[0]), fy = f(xyz[1] / white[1]), fz = f(xyz[2] / white[2]);
    lab[0] = 116 * fy - 16, lab[1] = 500 * (fx - fy), lab[2] = 200 * (fy - fz);
}

static void
cmyk_to_rgb(const CGFloat *in, CGFloat rgb[3])
{
    for (int i = 0; i < 3; i++)
        rgb[i] = (1 - fmin(1, in[i])) * (1 - fmin(1, in[3]));
}

void
CGColorSpaceToXYZ(CGColorSpaceRef cs, const CGFloat *in, double xyz[3])
{
    switch (cs->kind) {
    case CG_SPACE_DEVICE_RGB:
    case CG_SPACE_DEVICE_GRAY: {
        CGColorSpaceRef r = CGColorSpaceResolveDevice(cs);
        CGColorSpaceToXYZ(r, in, xyz);
        CFRelease(r);
        return;
    }
    case CG_SPACE_DEVICE_CMYK:
    case CG_SPACE_CMYK: {
        CGFloat rgb[3];
        cmyk_to_rgb(in, rgb);
        CGColorSpaceRef r = named_space(named_index(kCGColorSpaceSRGB));
        CGColorSpaceToXYZ(r, rgb, xyz);
        CFRelease(r);
        return;
    }
    case CG_SPACE_MATRIX:
        if (cs->model == kCGColorSpaceModelMonochrome) {
            double y = tf_eval(cs->trc[0], in[0], cs->extended);
            for (int i = 0; i < 3; i++)
                xyz[i] = y * D50[i];
        } else {
            double lin[3];
            for (int i = 0; i < 3; i++)
                lin[i] = tf_eval(cs->trc[i], in[i], cs->extended);
            mat_mul(cs->toXYZ, lin, xyz);
        }
        return;
    case CG_SPACE_LAB: {
        double lab[3] = {in[0], in[1], in[2]}, w[9], x[3];
        lab_to_xyz(lab, cs->white, x);
        bradford_to_d50(cs->white, w);
        mat_mul(w, x, xyz);
        return;
    }
    case CG_SPACE_XYZ:
        xyz[0] = in[0], xyz[1] = in[1], xyz[2] = in[2];
        return;
    case CG_SPACE_ICC_LUT: {
        float src[4] = {0}, dst[3];
        for (size_t i = 0; i < cs->n; i++)
            src[i] = (float)in[i];
        skcms_PixelFormat fmt = cs->n == 4 ? skcms_PixelFormat_RGBA_ffff : cs->n == 1 ? skcms_PixelFormat_G_8
                                                                                       : skcms_PixelFormat_RGB_fff;
        uint8_t g8 = (uint8_t)lround(fmin(1, fmax(0, in[0])) * 255);
        if (skcms_Transform(cs->n == 1 ? (const void *)&g8 : (const void *)src, fmt, skcms_AlphaFormat_Unpremul,
                            (const skcms_ICCProfile *)cs->profile, dst, skcms_PixelFormat_RGB_fff,
                            skcms_AlphaFormat_Unpremul, skcms_XYZD50_profile(), 1)) {
            xyz[0] = dst[0], xyz[1] = dst[1], xyz[2] = dst[2];
        } else {
            xyz[0] = xyz[1] = xyz[2] = 0;
        }
        return;
    }
    case CG_SPACE_INDEXED: {
        long idx = lround(in[0]);
        if (idx < 0)
            idx = 0;
        if (idx >= (long)cs->table_count)
            idx = (long)cs->table_count - 1;
        CGFloat comps[4];
        for (size_t i = 0; i < cs->base_space->n; i++)
            comps[i] = cs->table[idx * cs->base_space->n + i] / 255.0;
        CGColorSpaceToXYZ(cs->base_space, comps, xyz);
        return;
    }
    default:
        xyz[0] = xyz[1] = xyz[2] = 0;
    }
}

static CGFloat
clamp_unless(bool extended, double v)
{
    return extended ? v : fmin(1, fmax(0, v));
}

void
CGColorSpaceFromXYZ(CGColorSpaceRef cs, const double xyz[3], CGFloat *out)
{
    switch (cs->kind) {
    case CG_SPACE_DEVICE_RGB:
    case CG_SPACE_DEVICE_GRAY: {
        CGColorSpaceRef r = CGColorSpaceResolveDevice(cs);
        CGColorSpaceFromXYZ(r, xyz, out);
        CFRelease(r);
        return;
    }
    case CG_SPACE_DEVICE_CMYK:
    case CG_SPACE_CMYK: {
        CGColorSpaceRef r = named_space(named_index(kCGColorSpaceSRGB));
        CGFloat rgb[3];
        CGColorSpaceFromXYZ(r, xyz, rgb);
        CFRelease(r);
        double k = 1 - fmax(rgb[0], fmax(rgb[1], rgb[2]));
        for (int i = 0; i < 3; i++)
            out[i] = k >= 1 ? 0 : (1 - rgb[i] - k) / (1 - k);
        out[3] = k;
        return;
    }
    case CG_SPACE_MATRIX:
        if (cs->model == kCGColorSpaceModelMonochrome) {
            out[0] = clamp_unless(cs->extended, tf_inv(cs->trc[0], xyz[1], cs->extended));
        } else {
            double lin[3];
            mat_mul(cs->fromXYZ, xyz, lin);
            for (int i = 0; i < 3; i++) {
                double l = cs->extended ? lin[i] : fmin(1, fmax(0, lin[i]));
                out[i] = clamp_unless(cs->extended, tf_inv(cs->trc[i], l, cs->extended));
            }
        }
        return;
    case CG_SPACE_LAB: {
        double w[9], winv[9], x[3], lab[3];
        bradford_to_d50(cs->white, w);
        mat_inv(w, winv);
        mat_mul(winv, xyz, x);
        xyz_to_lab(x, cs->white, lab);
        out[0] = fmin(100, fmax(0, lab[0]));
        out[1] = fmin(cs->range[1], fmax(cs->range[0], lab[1]));
        out[2] = fmin(cs->range[3], fmax(cs->range[2], lab[2]));
        return;
    }
    case CG_SPACE_XYZ:
        out[0] = xyz[0], out[1] = xyz[1], out[2] = xyz[2];
        return;
    case CG_SPACE_ICC_LUT: {
        float src[3] = {(float)xyz[0], (float)xyz[1], (float)xyz[2]}, dst[4] = {0};
        skcms_PixelFormat fmt = cs->n == 4 ? skcms_PixelFormat_RGBA_ffff : skcms_PixelFormat_RGB_fff;
        if (cs->n != 1 && skcms_Transform(src, skcms_PixelFormat_RGB_fff, skcms_AlphaFormat_Unpremul,
                                          skcms_XYZD50_profile(), dst, fmt, skcms_AlphaFormat_Unpremul,
                                          (const skcms_ICCProfile *)cs->profile, 1)) {
            for (size_t i = 0; i < cs->n; i++)
                out[i] = dst[i];
        } else {
            for (size_t i = 0; i < cs->n; i++)
                out[i] = 0;
        }
        return;
    }
    case CG_SPACE_INDEXED: {
        double best = INFINITY;
        out[0] = 0;
        for (size_t i = 0; i < cs->table_count; i++) {
            CGFloat idx = (CGFloat)i;
            double x[3];
            CGColorSpaceToXYZ(cs, &idx, x);
            double d = (x[0] - xyz[0]) * (x[0] - xyz[0]) + (x[1] - xyz[1]) * (x[1] - xyz[1]) +
                       (x[2] - xyz[2]) * (x[2] - xyz[2]);
            if (d < best)
                best = d, out[0] = idx;
        }
        return;
    }
    default:
        for (size_t i = 0; i < cs->n; i++)
            out[i] = 0;
    }
}

void
CGColorSpaceConvertComponents(CGColorSpaceRef src, const CGFloat *in, CGColorSpaceRef dst, CGFloat *out)
{
    if (src == dst || (src->named && src->named == dst->named)) {
        for (size_t i = 0; i < dst->n; i++)
            out[i] = in[i];
        return;
    }
    double xyz[3];
    CGColorSpaceToXYZ(src, in, xyz);
    CGColorSpaceFromXYZ(dst, xyz, out);
}
