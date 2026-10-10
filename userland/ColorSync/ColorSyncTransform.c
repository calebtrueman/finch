/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ColorSync transforms: a profile sequence, converting pixels from the first profile's
 * device space through D50 XYZ to the last's. Matrix/curve RGB, gray, Lab and XYZ
 * profiles are converted here, as Apple's ColorSync converts them (relative
 * colorimetric, floats left unclamped, integers clamped); profiles built from lookup
 * tables (CMYK, most printer and camera profiles) go through skcms.
 */
#include "ColorSyncInternal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* --- curves --- */

float
cs_curve_eval(const skcms_Curve *c, float x)
{
    if (c->table_entries == 0)
        return skcms_TransferFunction_eval(&c->parametric, x);
    uint32_t n = c->table_entries;
    if (x <= 0)
        x = 0;
    if (x >= 1)
        x = 1;
    float ix = x * (float)(n - 1);
    uint32_t lo = (uint32_t)ix, hi = lo + 1 < n ? lo + 1 : lo;
    float t = ix - (float)lo, a, b;
    if (c->table_8) {
        a = c->table_8[lo] / 255.0f;
        b = c->table_8[hi] / 255.0f;
    } else {
        const uint8_t *p = c->table_16;
        a = (float)(p[2 * lo] << 8 | p[2 * lo + 1]) / 65535.0f;
        b = (float)(p[2 * hi] << 8 | p[2 * hi + 1]) / 65535.0f;
    }
    return a + (b - a) * t;
}

/* A table's inverse, by bisection (tables are monotonic). */
static float
curve_invert(const skcms_Curve *c, float y)
{
    float lo = 0, hi = 1;
    bool rising = cs_curve_eval(c, 1) >= cs_curve_eval(c, 0);
    for (int i = 0; i < 32; i++) {
        float mid = (lo + hi) / 2, v = cs_curve_eval(c, mid);
        if ((v < y) == rising)
            lo = mid;
        else
            hi = mid;
    }
    return (lo + hi) / 2;
}

/* --- models --- */

static void
mat_invert(const double m[9], double out[9])
{
    double det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) +
                 m[2] * (m[3] * m[7] - m[4] * m[6]);
    if (det == 0)
        det = 1e-12;
    out[0] = (m[4] * m[8] - m[5] * m[7]) / det;
    out[1] = (m[2] * m[7] - m[1] * m[8]) / det;
    out[2] = (m[1] * m[5] - m[2] * m[4]) / det;
    out[3] = (m[5] * m[6] - m[3] * m[8]) / det;
    out[4] = (m[0] * m[8] - m[2] * m[6]) / det;
    out[5] = (m[2] * m[3] - m[0] * m[5]) / det;
    out[6] = (m[3] * m[7] - m[4] * m[6]) / det;
    out[7] = (m[1] * m[6] - m[0] * m[7]) / det;
    out[8] = (m[0] * m[4] - m[1] * m[3]) / det;
}

static const double kD50White[3] = {0.9642, 1.0, 0.8249};

void
cs_model_init_pcs(cs_model *m, uint32_t pcs)
{
    memset(m, 0, sizeof *m);
    m->kind = pcs == 'Lab ' ? CS_MODEL_LAB : CS_MODEL_XYZ;
    m->channels = 3;
}

/* The BT.709 camera curve (an OETF's inverse), which Rec. 709 and Rec. 2020 profiles
   carry. */
static bool
is_709_curve(const skcms_Curve *c)
{
    const skcms_TransferFunction *f = &c->parametric;
    return c->table_entries == 0 && fabsf(f->g - 2.2222f) < 0.01f && fabsf(f->a - 0.9097f) < 0.002f &&
           fabsf(f->c - 0.2222f) < 0.002f && fabsf(f->d - 0.0810f) < 0.002f;
}

bool
cs_model_init(cs_model *m, ColorSyncProfileRef prof, bool as_destination)
{
    return cs_model_init_with_options(m, prof, as_destination, true);
}

bool
cs_model_init_with_options(cs_model *m, ColorSyncProfileRef prof, bool as_destination, bool use_709_oetf)
{
    memset(m, 0, sizeof *m);
    uint32_t space = cs_profile_space(prof);
    if (space == 'Lab ' || space == 'XYZ ') {
        cs_model_init_pcs(m, space);
        return true;
    }
    size_t n;
    const uint8_t *b = cs_profile_bytes(prof, &n);
    m->bytes = calloc(1, n + 8); /* skcms reads a little past the end */
    memcpy(m->bytes, b, n);
    if (!skcms_Parse(m->bytes, n, &m->icc)) {
        cs_model_free(m);
        return false;
    }
    if ((space == 'RGB ' || space == 'GRAY') && m->icc.has_trc && m->icc.has_toXYZD50) {
        m->kind = space == 'GRAY' ? CS_MODEL_GRAY : CS_MODEL_RGB;
        m->channels = space == 'GRAY' ? 1 : 3;
        for (int i = 0; i < 3; i++) {
            m->curve[i] = m->icc.trc[i];
            /* Like Apple's, a display shows Rec. 709 video with BT.1886's pure 2.4 gamma
               rather than the camera curve, unless the transform asks for that. */
            if (!use_709_oetf && is_709_curve(&m->curve[i]))
                m->curve[i].parametric = (skcms_TransferFunction){2.4f, 1, 0, 0, 0, 0, 0};
            if (m->curve[i].table_entries == 0)
                m->has_inverse[i] = skcms_TransferFunction_invert(&m->curve[i].parametric, &m->inverse[i]);
            for (int j = 0; j < 3; j++)
                m->m[3 * i + j] = m->icc.toXYZD50.vals[i][j];
        }
        /* Colorants stored as s15Fixed16 add up to a white a little off D50; like
           Apple's, each row is scaled so device white lands on D50 exactly. */
        for (int r = 0; r < 3; r++) {
            double sum = m->m[3 * r] + m->m[3 * r + 1] + m->m[3 * r + 2];
            if (fabs(sum / kD50White[r] - 1) < 0.005)
                for (int c = 0; c < 3; c++)
                    m->m[3 * r + c] *= kD50White[r] / sum;
        }
        mat_invert(m->m, m->minv);
        return true;
    }
    int channels = skcms_GetInputChannelCount(&m->icc);
    if ((as_destination ? m->icc.has_B2A : m->icc.has_A2B) && (channels == 3 || channels == 4)) {
        m->kind = CS_MODEL_LUT;
        m->channels = channels;
        return true;
    }
    cs_model_free(m);
    return false;
}

void
cs_model_free(cs_model *m)
{
    free(m->bytes);
    m->bytes = NULL;
}

static double
lab_f(double t)
{
    const double e = 216.0 / 24389.0, k = 24389.0 / 27.0;
    return t > e ? cbrt(t) : (k * t + 16) / 116;
}

static double
lab_finv(double f)
{
    const double e = 6.0 / 29.0;
    return f > e ? f * f * f : 3 * e * e * (f - 4.0 / 29.0);
}

/* `in` holds `n` pixels of the model's channels; `xyz` gets three floats each. */
static void
to_xyz(const cs_model *m, float *in, float *xyz, size_t n)
{
    switch (m->kind) {
    case CS_MODEL_RGB:
        for (size_t i = 0; i < n; i++) {
            double lin[3];
            for (int c = 0; c < 3; c++)
                lin[c] = cs_curve_eval(&m->curve[c], in[3 * i + c]);
            for (int r = 0; r < 3; r++)
                xyz[3 * i + r] = (float)(m->m[3 * r] * lin[0] + m->m[3 * r + 1] * lin[1] + m->m[3 * r + 2] * lin[2]);
        }
        break;
    case CS_MODEL_GRAY:
        for (size_t i = 0; i < n; i++) {
            double y = cs_curve_eval(&m->curve[0], in[i]);
            for (int c = 0; c < 3; c++)
                xyz[3 * i + c] = (float)(y * kD50White[c]);
        }
        break;
    case CS_MODEL_LAB:
        for (size_t i = 0; i < n; i++) {
            double L = in[3 * i] * 100.0, a = (in[3 * i + 1] - 0.5) * 255.0, b = (in[3 * i + 2] - 0.5) * 255.0;
            double fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
            xyz[3 * i] = (float)(lab_finv(fx) * kD50White[0]);
            xyz[3 * i + 1] = (float)(lab_finv(fy) * kD50White[1]);
            xyz[3 * i + 2] = (float)(lab_finv(fz) * kD50White[2]);
        }
        break;
    case CS_MODEL_XYZ:
        memcpy(xyz, in, n * 3 * sizeof(float));
        break;
    case CS_MODEL_LUT:
        if (m->icc.data_color_space == skcms_Signature_CMYK) /* skcms takes CMYK inverted */
            for (size_t i = 0; i < 4 * n; i++)
                in[i] = 1 - in[i];
        skcms_Transform(in, m->channels == 4 ? skcms_PixelFormat_RGBA_ffff : skcms_PixelFormat_RGB_fff,
                        skcms_AlphaFormat_Unpremul, &m->icc, xyz, skcms_PixelFormat_RGB_fff,
                        skcms_AlphaFormat_Unpremul, skcms_XYZD50_profile(), n);
        break;
    }
}

static float
curve_inverse(const cs_model *m, int c, float y)
{
    if (m->has_inverse[c])
        return skcms_TransferFunction_eval(&m->inverse[c], y);
    return curve_invert(&m->curve[c], y);
}

static void
from_xyz(const cs_model *m, const float *xyz, float *out, size_t n)
{
    switch (m->kind) {
    case CS_MODEL_RGB:
        for (size_t i = 0; i < n; i++) {
            const float *v = xyz + 3 * i;
            for (int c = 0; c < 3; c++) {
                double lin = m->minv[3 * c] * v[0] + m->minv[3 * c + 1] * v[1] + m->minv[3 * c + 2] * v[2];
                out[3 * i + c] = curve_inverse(m, c, (float)lin);
            }
        }
        break;
    case CS_MODEL_GRAY:
        for (size_t i = 0; i < n; i++)
            out[i] = curve_inverse(m, 0, xyz[3 * i + 1]);
        break;
    case CS_MODEL_LAB:
        for (size_t i = 0; i < n; i++) {
            double fx = lab_f(xyz[3 * i] / kD50White[0]), fy = lab_f(xyz[3 * i + 1] / kD50White[1]),
                   fz = lab_f(xyz[3 * i + 2] / kD50White[2]);
            out[3 * i] = (float)((116 * fy - 16) / 100);
            out[3 * i + 1] = (float)(500 * (fx - fy) / 255 + 0.5);
            out[3 * i + 2] = (float)(200 * (fy - fz) / 255 + 0.5);
        }
        break;
    case CS_MODEL_XYZ:
        memcpy(out, xyz, n * 3 * sizeof(float));
        break;
    case CS_MODEL_LUT:
        skcms_Transform(xyz, skcms_PixelFormat_RGB_fff, skcms_AlphaFormat_Unpremul, skcms_XYZD50_profile(), out,
                        m->channels == 4 ? skcms_PixelFormat_RGBA_ffff : skcms_PixelFormat_RGB_fff,
                        skcms_AlphaFormat_Unpremul, &m->icc, n);
        if (m->icc.data_color_space == skcms_Signature_CMYK)
            for (size_t i = 0; i < 4 * n; i++)
                out[i] = 1 - out[i];
        break;
    }
}

/* --- the type --- */

struct ColorSyncTransform {
    CFRuntimeBase base;
    CFArrayRef sequence;
    CFMutableDictionaryRef properties;
    cs_model src, dst;
    uint32_t src_space, dst_space;
};

static CFTypeID transform_type;

static void
transform_finalize(CFTypeRef cf)
{
    struct ColorSyncTransform *t = (struct ColorSyncTransform *)cf;
    if (t->sequence)
        CFRelease(t->sequence);
    if (t->properties)
        CFRelease(t->properties);
    cs_model_free(&t->src);
    cs_model_free(&t->dst);
}

static CFStringRef
transform_description(CFTypeRef cf)
{
    struct ColorSyncTransform *t = (struct ColorSyncTransform *)cf;
    CFStringRef a = cs_string_from_sig(t->src_space), b = cs_string_from_sig(t->dst_space);
    CFStringRef s = CFStringCreateWithFormat(NULL, NULL, CFSTR("<ColorSyncTransform %p [%@ -> %@]>"), cf, a, b);
    CFRelease(a);
    CFRelease(b);
    return s;
}

static const CFRuntimeClass transform_class = {
    0, "ColorSyncTransform", NULL, NULL, transform_finalize, NULL, NULL, NULL, transform_description, NULL, NULL, 0,
};

CFTypeID
ColorSyncTransformGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ transform_type = _CFRuntimeRegisterClass(&transform_class); });
    return transform_type;
}

static ColorSyncProfileRef
sequence_profile(CFTypeRef entry)
{
    if (!entry)
        return NULL;
    if (CFGetTypeID(entry) == ColorSyncProfileGetTypeID())
        return entry;
    if (CFGetTypeID(entry) == CFDictionaryGetTypeID()) {
        CFTypeRef p = CFDictionaryGetValue(entry, kColorSyncProfile);
        if (p && CFGetTypeID(p) == ColorSyncProfileGetTypeID())
            return p;
    }
    return NULL;
}

ColorSyncTransformRef
ColorSyncTransformCreate(CFArrayRef profileSequence, CFDictionaryRef options)
{
    CFIndex count = profileSequence ? CFArrayGetCount(profileSequence) : 0;
    if (count < 1)
        return NULL;
    ColorSyncProfileRef first = sequence_profile(CFArrayGetValueAtIndex(profileSequence, 0));
    ColorSyncProfileRef last = sequence_profile(CFArrayGetValueAtIndex(profileSequence, count - 1));
    if (!first || !last)
        return NULL;
    struct ColorSyncTransform *t = (struct ColorSyncTransform *)_CFRuntimeCreateInstance(
        NULL, ColorSyncTransformGetTypeID(), sizeof(*t) - sizeof(CFRuntimeBase), NULL);
    if (!t)
        return NULL;
    t->sequence = CFArrayCreateCopy(NULL, profileSequence);
    t->properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (options)
        CFDictionaryApplyFunction(options, (CFDictionaryApplierFunction)CFDictionarySetValue, t->properties);
    CFTypeRef oetf = options ? CFDictionaryGetValue(options, kColorSyncTransformUseITU709OETF) : NULL;
    bool use_709_oetf = oetf && CFGetTypeID(oetf) == CFBooleanGetTypeID() && CFBooleanGetValue(oetf);
    t->src_space = cs_profile_space(first);
    if (!cs_model_init_with_options(&t->src, first, false, use_709_oetf)) {
        CFRelease(t);
        return NULL;
    }
    if (count == 1) {
        /* device to PCS: the profile's own connection space */
        t->dst_space = cs_profile_pcs(first) == 'Lab ' ? 'Lab ' : 'XYZ ';
        cs_model_init_pcs(&t->dst, t->dst_space);
    } else {
        t->dst_space = cs_profile_space(last);
        if (!cs_model_init_with_options(&t->dst, last, true, use_709_oetf)) {
            CFRelease(t);
            return NULL;
        }
    }
    return t;
}

ColorSyncTransformRef
ColorSyncTransformCreateWithName(CFStringRef fromProfile, CFStringRef toProfile)
{
    ColorSyncProfileRef a = ColorSyncProfileCreateWithName(fromProfile), b = ColorSyncProfileCreateWithName(toProfile);
    ColorSyncTransformRef t = NULL;
    if (a && b) {
        const void *keys[] = {kColorSyncProfile, kColorSyncRenderingIntent, kColorSyncTransformTag};
        const void *va[] = {a, kColorSyncRenderingIntentPerceptual, kColorSyncTransformDeviceToPCS};
        const void *vb[] = {b, kColorSyncRenderingIntentPerceptual, kColorSyncTransformPCSToDevice};
        CFDictionaryRef da = CFDictionaryCreate(NULL, keys, va, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionaryRef db = CFDictionaryCreate(NULL, keys, vb, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *seq[] = {da, db};
        CFArrayRef s = CFArrayCreate(NULL, seq, 2, &kCFTypeArrayCallBacks);
        t = ColorSyncTransformCreate(s, NULL);
        CFRelease(s);
        CFRelease(da);
        CFRelease(db);
    }
    if (a)
        CFRelease(a);
    if (b)
        CFRelease(b);
    return t;
}

CFArrayRef
ColorSyncTransformGetProfileSequence(ColorSyncTransformRef transform)
{
    return transform ? transform->sequence : NULL;
}

size_t
ColorSyncTransformGetSrcComponentCount(ColorSyncTransformRef transform)
{
    return transform ? (size_t)transform->src.channels : 0;
}

size_t
ColorSyncTransformGetDstComponentCount(ColorSyncTransformRef transform)
{
    return transform ? (size_t)transform->dst.channels : 0;
}

CFTypeRef
ColorSyncTransformCopyProperty(ColorSyncTransformRef transform, CFTypeRef key, CFDictionaryRef options)
{
    if (!transform || !key)
        return NULL;
    if (CFEqual(key, kColorSyncTransformSrcSpace))
        return cs_string_from_sig(transform->src_space);
    if (CFEqual(key, kColorSyncTransformDstSpace))
        return cs_string_from_sig(transform->dst_space);
    if (CFEqual(key, kColorSyncTransformProfileSequnce))
        return CFRetain(transform->sequence);
    CFTypeRef v = CFDictionaryGetValue(transform->properties, key);
    return v ? CFRetain(v) : NULL;
}

void
ColorSyncTransformSetProperty(ColorSyncTransformRef transform, CFTypeRef key, CFTypeRef property)
{
    if (!transform || !key)
        return;
    if (property)
        CFDictionarySetValue(transform->properties, key, property);
    else
        CFDictionaryRemoveValue(transform->properties, key);
}

/* --- pixel layouts --- */

typedef struct {
    ColorSyncDataDepth depth;
    int channels, components, size;
    int alpha_index; /* alpha's slot, or -1 */
    bool has_alpha, premultiplied, little;
} pixel_layout;

static bool
layout_init(pixel_layout *l, ColorSyncDataDepth depth, ColorSyncDataLayout layout, int channels)
{
    memset(l, 0, sizeof *l);
    l->depth = depth;
    l->channels = channels;
    switch (depth) {
    case kColorSync8BitInteger: l->size = 1; break;
    case kColorSync16BitInteger:
    case kColorSync16BitFloat: l->size = 2; break;
    case kColorSync32BitInteger:
    case kColorSync32BitFloat: l->size = 4; break;
    default: return false;
    }
    uint32_t alpha = layout & kColorSyncAlphaInfoMask, order = layout & kColorSyncByteOrderMask;
    bool slot = alpha != kColorSyncAlphaNone, first = false;
    switch (alpha) {
    case kColorSyncAlphaNone: break;
    case kColorSyncAlphaPremultipliedLast: l->has_alpha = l->premultiplied = true; break;
    case kColorSyncAlphaPremultipliedFirst: l->has_alpha = l->premultiplied = first = true; break;
    case kColorSyncAlphaLast: l->has_alpha = true; break;
    case kColorSyncAlphaFirst: l->has_alpha = first = true; break;
    case kColorSyncAlphaNoneSkipLast: break;
    case kColorSyncAlphaNoneSkipFirst: first = true; break;
    default: return false;
    }
    l->components = channels + (slot ? 1 : 0);
    l->alpha_index = slot ? (first ? 0 : channels) : -1;
    /* Apple's ignores the byte order for 8-bit components */
    if (l->size == 2)
        l->little = order != kColorSyncByteOrder16Big && order != kColorSyncByteOrder32Big;
    else
        l->little = order != kColorSyncByteOrder32Big && order != kColorSyncByteOrder16Big;
    return true;
}

static size_t
slot_offset(const pixel_layout *l, int slot)
{
    return (size_t)(slot * l->size);
}

/* Channel c is in slot c (alpha last) or c+1 (alpha first). */
static int
channel_slot(const pixel_layout *l, int c)
{
    return l->alpha_index == 0 ? c + 1 : c;
}

static float
read_component(const pixel_layout *l, const uint8_t *p)
{
    switch (l->depth) {
    case kColorSync8BitInteger:
        return p[0] / 255.0f;
    case kColorSync16BitInteger:
    case kColorSync16BitFloat: {
        uint16_t v = l->little ? (uint16_t)(p[0] | p[1] << 8) : (uint16_t)(p[0] << 8 | p[1]);
        if (l->depth == kColorSync16BitInteger)
            return v / 65535.0f;
        _Float16 h;
        memcpy(&h, &v, 2);
        return (float)h;
    }
    default: {
        uint32_t v = l->little ? (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24
                               : cs_be32(p);
        if (l->depth == kColorSync32BitInteger)
            return (float)(v / 4294967295.0);
        float f;
        memcpy(&f, &v, 4);
        return f;
    }
    }
}

/* 8-bit values are truncated from x * 256, as Apple's are. */
static uint8_t
quantize8(float x)
{
    float v = floorf(x * 256);
    return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
}

static void
write_component(const pixel_layout *l, uint8_t *p, float x)
{
    uint32_t v = 0;
    int bytes = l->size;
    switch (l->depth) {
    case kColorSync8BitInteger:
        p[0] = quantize8(x);
        return;
    case kColorSync16BitInteger:
        v = (uint32_t)lrintf(fminf(fmaxf(x, 0), 1) * 65535);
        break;
    case kColorSync16BitFloat: {
        _Float16 h = (_Float16)x;
        uint16_t u;
        memcpy(&u, &h, 2);
        v = u;
        break;
    }
    case kColorSync32BitInteger:
        v = (uint32_t)llrint(fmin(fmax(x, 0), 1) * 4294967295.0);
        break;
    default:
        memcpy(&v, &x, 4);
        break;
    }
    for (int i = 0; i < bytes; i++)
        p[l->little ? i : bytes - 1 - i] = (uint8_t)(v >> (8 * i));
}

bool
ColorSyncTransformConvert(ColorSyncTransformRef transform, size_t width, size_t height, void *dst,
                          ColorSyncDataDepth dstDepth, ColorSyncDataLayout dstLayout, size_t dstBytesPerRow,
                          const void *src, ColorSyncDataDepth srcDepth, ColorSyncDataLayout srcLayout,
                          size_t srcBytesPerRow, CFDictionaryRef options)
{
    pixel_layout in, out;
    if (!transform || !dst || !src || !layout_init(&in, srcDepth, srcLayout, transform->src.channels) ||
        !layout_init(&out, dstDepth, dstLayout, transform->dst.channels))
        return false;
    size_t in_pixel = (size_t)(in.components * in.size), out_pixel = (size_t)(out.components * out.size);
    float *dev = malloc(width * 4 * sizeof(float)), *alpha = malloc(width * sizeof(float));
    float *xyz = malloc(width * 3 * sizeof(float)), *res = malloc(width * 4 * sizeof(float));
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = (const uint8_t *)src + y * srcBytesPerRow;
        uint8_t *orow = (uint8_t *)dst + y * dstBytesPerRow;
        for (size_t x = 0; x < width; x++) {
            const uint8_t *p = row + x * in_pixel;
            float a = in.has_alpha ? read_component(&in, p + slot_offset(&in, in.alpha_index)) : 1;
            alpha[x] = a;
            for (int c = 0; c < in.channels; c++) {
                const uint8_t *q = p + slot_offset(&in, channel_slot(&in, c));
                float v = read_component(&in, q);
                if (in.premultiplied && a > 0) {
                    if (in.depth == kColorSync8BitInteger) /* as Apple's: truncated, and wrapping */
                        v = (uint8_t)(q[0] * 255 / (int)lrintf(a * 255)) / 255.0f;
                    else
                        v /= a;
                }
                dev[x * (size_t)in.channels + c] = v;
            }
        }
        to_xyz(&transform->src, dev, xyz, width);
        from_xyz(&transform->dst, xyz, res, width);
        for (size_t x = 0; x < width; x++) {
            uint8_t *p = orow + x * out_pixel;
            float a = alpha[x];
            for (int c = 0; c < out.channels; c++) {
                float v = res[x * (size_t)out.channels + c];
                if (out.depth != kColorSync32BitFloat && out.depth != kColorSync16BitFloat)
                    v = fminf(fmaxf(v, 0), 1);
                uint8_t *q = p + slot_offset(&out, channel_slot(&out, c));
                if (out.premultiplied)
                    v *= a;
                write_component(&out, q, v);
            }
            /* a skipped slot is left as it was */
            if (out.has_alpha)
                write_component(&out, p + slot_offset(&out, out.alpha_index), a);
        }
    }
    free(dev);
    free(alpha);
    free(xyz);
    free(res);
    return true;
}

/* --- CMMs: only the built-in one, which isn't handed out --- */

CFTypeID
ColorSyncCMMGetTypeID(void)
{
    static CFTypeID type;
    static const CFRuntimeClass cls = {0, "ColorSyncCMM", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{ type = _CFRuntimeRegisterClass(&cls); });
    return type;
}

ColorSyncCMMRef
ColorSyncCMMCreate(CFBundleRef cmmBundle)
{
    return NULL; /* third-party CMMs aren't loaded */
}

CFBundleRef
ColorSyncCMMGetBundle(ColorSyncCMMRef cmm)
{
    return NULL;
}

CFStringRef
ColorSyncCMMCopyLocalizedName(ColorSyncCMMRef cmm)
{
    return NULL;
}

CFStringRef
ColorSyncCMMCopyCMMIdentifier(ColorSyncCMMRef cmm)
{
    return NULL;
}

void
ColorSyncIterateInstalledCMMs(ColorSyncCMMIterateCallback callBack, void *userInfo)
{
}

CFTypeRef
ColorSyncCreateCodeFragment(CFArrayRef profileSequence, CFDictionaryRef options)
{
    /* transforms aren't described as code fragments: an empty one */
    return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

/* --- devices --- */

bool
ColorSyncRegisterDevice(CFStringRef deviceClass, CFUUIDRef deviceID, CFDictionaryRef deviceInfo)
{
    return true;
}

bool
ColorSyncUnregisterDevice(CFStringRef deviceClass, CFUUIDRef deviceID)
{
    return true;
}

bool
ColorSyncDeviceSetCustomProfiles(CFStringRef deviceClass, CFUUIDRef deviceID, CFDictionaryRef profileInfo)
{
    return false;
}

CFDictionaryRef
ColorSyncDeviceCopyDeviceInfo(CFStringRef deviceClass, CFUUIDRef devID)
{
    return NULL;
}

void
ColorSyncIterateDeviceProfiles(ColorSyncDeviceProfileIterateCallback callBack, void *userInfo)
{
}

/* A display's UUID: a fixed namespace with the display ID in its last four bytes. */
static const uint8_t kDisplayUUIDPrefix[12] = {0x46, 0x49, 0x4e, 0x43, 0x48, 0x2d, 0x44, 0x49, 0x80, 0x53, 0x50, 0x4c};

CFUUIDRef
CGDisplayCreateUUIDFromDisplayID(uint32_t displayID)
{
    CFUUIDBytes b;
    uint8_t *u = (uint8_t *)&b;
    memcpy(u, kDisplayUUIDPrefix, 12);
    u[12] = (uint8_t)(displayID >> 24), u[13] = (uint8_t)(displayID >> 16), u[14] = (uint8_t)(displayID >> 8),
    u[15] = (uint8_t)displayID;
    return CFUUIDCreateFromUUIDBytes(NULL, b);
}

uint32_t
CGDisplayGetDisplayIDFromUUID(CFUUIDRef uuid)
{
    if (!uuid)
        return 0;
    CFUUIDBytes b = CFUUIDGetUUIDBytes(uuid);
    const uint8_t *u = (const uint8_t *)&b;
    if (memcmp(u, kDisplayUUIDPrefix, 12))
        return 0;
    return (uint32_t)u[12] << 24 | (uint32_t)u[13] << 16 | (uint32_t)u[14] << 8 | u[15];
}

uint32_t
ColorSyncAPIVersion(void)
{
    return 0x0400; /* ColorSync 4 */
}
