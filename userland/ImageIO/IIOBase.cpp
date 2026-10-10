/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Shared pieces: CF type registration, decoded pixels to CGImage and back
 * (any CGImage layout read as floats, for thumbnails and encoders), ICC
 * profile names, and EXIF (TIFF) reading and writing.
 */
#include "ImageIOInternal.h"
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string>

/* ---- CF types ------------------------------------------------------------ */

static pthread_mutex_t register_lock = PTHREAD_MUTEX_INITIALIZER;

CFTypeID
IIOTypeRegister(const IIORuntimeClass *cls, CFTypeID *slot)
{
    CFTypeID id = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (id)
        return id;
    pthread_mutex_lock(&register_lock);
    id = __atomic_load_n(slot, __ATOMIC_RELAXED);
    if (!id) {
        id = _CFRuntimeRegisterClass(cls);
        __atomic_store_n(slot, id, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&register_lock);
    return id;
}

void *
IIOTypeCreateInstance(CFTypeID type, size_t size)
{
    void *obj = (void *)_CFRuntimeCreateInstance(NULL, type, size - sizeof(IIORuntimeBase), NULL);
    if (obj)
        memset((char *)obj + sizeof(IIORuntimeBase), 0, size - sizeof(IIORuntimeBase));
    return obj;
}

CFNumberRef
IIONumberI32(int32_t v)
{
    return CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
}

CFNumberRef
IIONumberF64(double v)
{
    return CFNumberCreate(NULL, kCFNumberFloat64Type, &v);
}

bool
IIOGetDouble(CFDictionaryRef d, CFStringRef key, double *out)
{
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    if (!v)
        return false;
    if (CFGetTypeID(v) == CFNumberGetTypeID())
        return CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, out);
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
        *out = CFBooleanGetValue((CFBooleanRef)v);
        return true;
    }
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        *out = CFStringGetDoubleValue((CFStringRef)v);
        return true;
    }
    return false;
}

bool
IIOGetBool(CFDictionaryRef d, CFStringRef key)
{
    double v;
    return IIOGetDouble(d, key, &v) && v != 0;
}

void
IIOAddDelay(IIODict &d, double unclamped)
{
    d.f64(kCGImagePropertyGIFDelayTime, unclamped < 0.011 ? 0.1 : unclamped);
    d.f64(kCGImagePropertyGIFUnclampedDelayTime, unclamped);
}

IIOCodec::~IIOCodec()
{
    reset();
}

void
IIOCodec::reset()
{
    for (CFDictionaryRef p : props)
        if (p)
            CFRelease(p);
    props.clear();
    ready.clear();
    orientation.clear();
    count = 0;
    if (container)
        CFRelease(container);
    container = NULL;
}

/* ---- pixels ---------------------------------------------------------------- */

CGImageRef
IIOPixels::image()
{
    CFDataRef d = CFDataCreate(NULL, data.data(), (CFIndex)data.size());
    std::vector<uint8_t>().swap(data);
    CGDataProviderRef p = CGDataProviderCreateWithCFData(d);
    CFRelease(d);
    CGImageRef im = CGImageCreate(w, h, bpc, bpp, bpr, space, info, p, NULL, true, intent);
    CGDataProviderRelease(p);
    return im;
}

static double
half_to_double(uint16_t v)
{
    int e = (v >> 10) & 31, m = v & 1023;
    double f = e == 0 ? ldexp(m, -24) : e == 31 ? (m ? NAN : INFINITY) : ldexp(m + 1024, e - 25);
    return v & 0x8000 ? -f : f;
}

bool
IIOReadImage(CGImageRef im, IIOFloatImage &out)
{
    size_t w = CGImageGetWidth(im), h = CGImageGetHeight(im), bpc = CGImageGetBitsPerComponent(im),
           bpp = CGImageGetBitsPerPixel(im), bpr = CGImageGetBytesPerRow(im);
    CGColorSpaceRef cs = CGImageGetColorSpace(im);
    CGBitmapInfo info = CGImageGetBitmapInfo(im);
    if (!cs || !w || !h)
        return false;
    CGImageAlphaInfo ai = (CGImageAlphaInfo)(info & kCGBitmapAlphaInfoMask);
    uint32_t order = info & kCGBitmapByteOrderMask;
    bool fl = info & kCGBitmapFloatComponents;
    bool indexed = CGColorSpaceGetModel(cs) == kCGColorSpaceModelIndexed;
    CGColorSpaceRef base = indexed ? CGColorSpaceGetBaseColorSpace(cs) : cs;
    size_t nb = CGColorSpaceGetNumberOfComponents(base);
    size_t nc = indexed ? 1 : nb;
    std::vector<uint8_t> table;
    if (indexed) {
        table.resize(CGColorSpaceGetColorTableCount(cs) * nb);
        CGColorSpaceGetColorTable(cs, table.data());
    }
    bool has_alpha = ai == kCGImageAlphaPremultipliedLast || ai == kCGImageAlphaPremultipliedFirst ||
                     ai == kCGImageAlphaLast || ai == kCGImageAlphaFirst;
    bool premul = ai == kCGImageAlphaPremultipliedLast || ai == kCGImageAlphaPremultipliedFirst;
    bool slot = ai != kCGImageAlphaNone && ai != kCGImageAlphaOnly;
    bool first = ai == kCGImageAlphaPremultipliedFirst || ai == kCGImageAlphaFirst || ai == kCGImageAlphaNoneSkipFirst;
    size_t nslots = nc + (slot ? 1 : 0);
    if (bpc != 1 && bpc != 2 && bpc != 4 && bpc != 8 && bpc != 16 && bpc != 32)
        return false;
    if (bpp < nslots * bpc)
        return false;

    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(im));
    if (!data)
        return false;
    if ((size_t)CFDataGetLength(data) < bpr * (h - 1) + (w * bpp + 7) / 8) {
        CFRelease(data);
        return false;
    }
    const uint8_t *bytes = CFDataGetBytePtr(data);
    out.w = w, out.h = h, out.n = nb, out.alpha = has_alpha;
    out.px.assign(w * h * (nb + 1), 0);
    if (out.space)
        CGColorSpaceRelease(out.space);
    out.space = CGColorSpaceRetain(base);
    bool little = order == kCGBitmapByteOrder16Little || order == kCGBitmapByteOrder32Little;
    if (bpc == 32 && order == kCGBitmapByteOrderDefault)
        little = true;  /* host order */
    size_t pixel_bytes = bpp / 8;
    double v[8];
    for (size_t y = 0; y < h; y++) {
        const uint8_t *row = bytes + y * bpr;
        for (size_t x = 0; x < w; x++) {
            uint8_t px[16];
            if (bpc < 8) {
                for (size_t s = 0; s < nslots; s++) {
                    size_t bit = x * bpp + s * bpc;
                    unsigned u = 0;
                    for (size_t i = 0; i < bpc; i++, bit++)
                        u = u << 1 | ((row[bit / 8] >> (7 - bit % 8)) & 1);
                    v[s] = indexed ? u : u / (double)((1u << bpc) - 1);
                }
            } else {
                memcpy(px, row + x * pixel_bytes, pixel_bytes > 16 ? 16 : pixel_bytes);
                if (bpc == 8 && little && (pixel_bytes == 2 || pixel_bytes == 4))
                    for (size_t i = 0; i < pixel_bytes / 2; i++) {
                        uint8_t t = px[i];
                        px[i] = px[pixel_bytes - 1 - i];
                        px[pixel_bytes - 1 - i] = t;
                    }
                for (size_t s = 0; s < nslots; s++) {
                    const uint8_t *c = px + s * (bpc / 8);
                    if (bpc == 8) {
                        v[s] = indexed ? c[0] : c[0] / 255.0;
                    } else if (bpc == 16) {
                        uint16_t u = little ? (uint16_t)(c[0] | c[1] << 8) : (uint16_t)(c[0] << 8 | c[1]);
                        v[s] = fl ? half_to_double(u) : indexed ? u : u / 65535.0;
                    } else {
                        uint32_t u = little ? (uint32_t)(c[0] | c[1] << 8 | c[2] << 16 | (uint32_t)c[3] << 24)
                                            : (uint32_t)((uint32_t)c[0] << 24 | c[1] << 16 | c[2] << 8 | c[3]);
                        float f;
                        memcpy(&f, &u, 4);
                        v[s] = fl ? f : u / 4294967295.0;
                    }
                }
            }
            double *o = out.at(x, y);
            double a = 1;
            size_t c0 = first && slot ? 1 : 0;
            if (has_alpha)
                a = first ? v[0] : v[nc];
            if (indexed) {
                size_t idx = (size_t)v[c0];
                for (size_t k = 0; k < nb; k++)
                    o[k] = idx * nb + k < table.size() ? table[idx * nb + k] / 255.0 : 0;
            } else {
                for (size_t k = 0; k < nb; k++) {
                    double c = v[c0 + k];
                    if (premul)
                        c = a > 0 ? c / a : 0;
                    o[k] = c > 1 && !fl ? 1 : c;
                }
            }
            o[nb] = a;
        }
    }
    CFRelease(data);
    return true;
}

/* ---- colour ------------------------------------------------------------ */

static uint32_t
be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
}

static CFStringRef copy_icc_tag_text(const uint8_t *p, size_t n, const char *sig);

/* The profile's name: Apple's localized 'dscm' tag when it has one, else 'desc'. */
CFStringRef
IIOCopyICCDescription(const uint8_t *p, size_t n)
{
    CFStringRef s = copy_icc_tag_text(p, n, "dscm");
    return s ? s : copy_icc_tag_text(p, n, "desc");
}

static CFStringRef
copy_icc_tag_text(const uint8_t *p, size_t n, const char *sig)
{
    if (n < 132)
        return NULL;
    uint32_t count = be32(p + 128);
    for (uint32_t i = 0; i < count && 132 + 12 * (i + 1) <= n; i++) {
        const uint8_t *e = p + 132 + 12 * i;
        if (memcmp(e, sig, 4))
            continue;
        uint32_t off = be32(e + 4), size = be32(e + 8);
        if (off > n || size > n - off || size < 12)
            return NULL;
        const uint8_t *t = p + off;
        if (!memcmp(t, "desc", 4)) {
            uint32_t len = be32(t + 8);
            if (len > size - 12)
                len = size - 12;
            while (len && !t[12 + len - 1])
                len--;
            return CFStringCreateWithBytes(NULL, t + 12, len, kCFStringEncodingISOLatin1, false);
        }
        if (!memcmp(t, "mluc", 4) && size >= 28) {
            uint32_t nrec = be32(t + 8), rsize = be32(t + 12);
            if (!nrec || rsize < 12)
                return NULL;
            /* prefer en-US, else the first record */
            const uint8_t *r = t + 16;
            for (uint32_t k = 0; k < nrec && 16 + (k + 1) * rsize <= size; k++)
                if (!memcmp(t + 16 + k * rsize, "enUS", 4)) {
                    r = t + 16 + k * rsize;
                    break;
                }
            uint32_t len = be32(r + 4), o = be32(r + 8);
            if (o > size || len > size - o)
                return NULL;
            while (len >= 2 && !t[o + len - 1] && !t[o + len - 2])
                len -= 2;
            return CFStringCreateWithBytes(NULL, t + o, len, kCFStringEncodingUTF16BE, false);
        }
        return NULL;
    }
    return NULL;
}

CFStringRef
IIOCopyProfileName(CGColorSpaceRef cs)
{
    if (!cs)
        return NULL;
    CFDataRef icc = CGColorSpaceCopyICCData(cs);
    if (!icc)
        return NULL;
    CFStringRef s = IIOCopyICCDescription(CFDataGetBytePtr(icc), CFDataGetLength(icc));
    CFRelease(icc);
    return s;
}

CGColorSpaceRef
IIOSpaceFromICC(const uint8_t *p, size_t n, CGColorSpaceModel want)
{
    CFDataRef d = CFDataCreate(NULL, p, (CFIndex)n);
    CGColorSpaceRef cs = CGColorSpaceCreateWithICCData(d);
    CFRelease(d);
    if (cs && CGColorSpaceGetModel(cs) != want) {
        CGColorSpaceRelease(cs);
        cs = NULL;
    }
    return cs;
}

/* ---- EXIF ---------------------------------------------------------------- */

namespace {

enum Kind { K_STR, K_INT, K_DBL, K_INTS, K_COMMENT };
struct Tag {
    uint16_t tag;
    const CFStringRef *key;
    Kind kind;
};

const Tag tiff_tags[] = {
    {0x0103, &kCGImagePropertyTIFFCompression, K_INT},
    {0x0106, &kCGImagePropertyTIFFPhotometricInterpretation, K_INT},
    {0x010d, &kCGImagePropertyTIFFDocumentName, K_STR},
    {0x010e, &kCGImagePropertyTIFFImageDescription, K_STR},
    {0x010f, &kCGImagePropertyTIFFMake, K_STR},
    {0x0110, &kCGImagePropertyTIFFModel, K_STR},
    {0x0112, &kCGImagePropertyTIFFOrientation, K_INT},
    {0x011a, &kCGImagePropertyTIFFXResolution, K_DBL},
    {0x011b, &kCGImagePropertyTIFFYResolution, K_DBL},
    {0x0128, &kCGImagePropertyTIFFResolutionUnit, K_INT},
    {0x012d, &kCGImagePropertyTIFFTransferFunction, K_INTS},
    {0x0131, &kCGImagePropertyTIFFSoftware, K_STR},
    {0x0132, &kCGImagePropertyTIFFDateTime, K_STR},
    {0x013b, &kCGImagePropertyTIFFArtist, K_STR},
    {0x013c, &kCGImagePropertyTIFFHostComputer, K_STR},
    {0x013e, &kCGImagePropertyTIFFWhitePoint, K_DBL},
    {0x013f, &kCGImagePropertyTIFFPrimaryChromaticities, K_DBL},
    {0x0142, &kCGImagePropertyTIFFTileWidth, K_INT},
    {0x0143, &kCGImagePropertyTIFFTileLength, K_INT},
    {0x8298, &kCGImagePropertyTIFFCopyright, K_STR},
};

const Tag exif_tags[] = {
    {0x829a, &kCGImagePropertyExifExposureTime, K_DBL},
    {0x829d, &kCGImagePropertyExifFNumber, K_DBL},
    {0x8822, &kCGImagePropertyExifExposureProgram, K_INT},
    {0x8824, &kCGImagePropertyExifSpectralSensitivity, K_STR},
    {0x8827, &kCGImagePropertyExifISOSpeedRatings, K_INTS},
    {0x8830, &kCGImagePropertyExifSensitivityType, K_INT},
    {0x9000, &kCGImagePropertyExifVersion, K_INTS},
    {0x9003, &kCGImagePropertyExifDateTimeOriginal, K_STR},
    {0x9004, &kCGImagePropertyExifDateTimeDigitized, K_STR},
    {0x9010, &kCGImagePropertyExifOffsetTime, K_STR},
    {0x9011, &kCGImagePropertyExifOffsetTimeOriginal, K_STR},
    {0x9012, &kCGImagePropertyExifOffsetTimeDigitized, K_STR},
    {0x9101, &kCGImagePropertyExifComponentsConfiguration, K_INTS},
    {0x9102, &kCGImagePropertyExifCompressedBitsPerPixel, K_DBL},
    {0x9201, &kCGImagePropertyExifShutterSpeedValue, K_DBL},
    {0x9202, &kCGImagePropertyExifApertureValue, K_DBL},
    {0x9203, &kCGImagePropertyExifBrightnessValue, K_DBL},
    {0x9204, &kCGImagePropertyExifExposureBiasValue, K_DBL},
    {0x9205, &kCGImagePropertyExifMaxApertureValue, K_DBL},
    {0x9206, &kCGImagePropertyExifSubjectDistance, K_DBL},
    {0x9207, &kCGImagePropertyExifMeteringMode, K_INT},
    {0x9208, &kCGImagePropertyExifLightSource, K_INT},
    {0x9209, &kCGImagePropertyExifFlash, K_INT},
    {0x920a, &kCGImagePropertyExifFocalLength, K_DBL},
    {0x9214, &kCGImagePropertyExifSubjectArea, K_INTS},
    {0x9286, &kCGImagePropertyExifUserComment, K_COMMENT},
    {0x9290, &kCGImagePropertyExifSubsecTime, K_STR},
    {0x9291, &kCGImagePropertyExifSubsecTimeOriginal, K_STR},
    {0x9292, &kCGImagePropertyExifSubsecTimeDigitized, K_STR},
    {0xa000, &kCGImagePropertyExifFlashPixVersion, K_INTS},
    {0xa001, &kCGImagePropertyExifColorSpace, K_INT},
    {0xa002, &kCGImagePropertyExifPixelXDimension, K_INT},
    {0xa003, &kCGImagePropertyExifPixelYDimension, K_INT},
    {0xa20e, &kCGImagePropertyExifFocalPlaneXResolution, K_DBL},
    {0xa20f, &kCGImagePropertyExifFocalPlaneYResolution, K_DBL},
    {0xa210, &kCGImagePropertyExifFocalPlaneResolutionUnit, K_INT},
    {0xa217, &kCGImagePropertyExifSensingMethod, K_INT},
    {0xa401, &kCGImagePropertyExifCustomRendered, K_INT},
    {0xa402, &kCGImagePropertyExifExposureMode, K_INT},
    {0xa403, &kCGImagePropertyExifWhiteBalance, K_INT},
    {0xa404, &kCGImagePropertyExifDigitalZoomRatio, K_DBL},
    {0xa405, &kCGImagePropertyExifFocalLenIn35mmFilm, K_INT},
    {0xa406, &kCGImagePropertyExifSceneCaptureType, K_INT},
    {0xa408, &kCGImagePropertyExifContrast, K_INT},
    {0xa409, &kCGImagePropertyExifSaturation, K_INT},
    {0xa40a, &kCGImagePropertyExifSharpness, K_INT},
    {0xa420, &kCGImagePropertyExifImageUniqueID, K_STR},
    {0xa430, &kCGImagePropertyExifCameraOwnerName, K_STR},
    {0xa431, &kCGImagePropertyExifBodySerialNumber, K_STR},
    {0xa432, &kCGImagePropertyExifLensSpecification, K_DBL},
    {0xa433, &kCGImagePropertyExifLensMake, K_STR},
    {0xa434, &kCGImagePropertyExifLensModel, K_STR},
    {0xa435, &kCGImagePropertyExifLensSerialNumber, K_STR},
};

const Tag gps_tags[] = {
    {0x0000, &kCGImagePropertyGPSVersion, K_INTS},
    {0x0001, &kCGImagePropertyGPSLatitudeRef, K_STR},
    {0x0002, &kCGImagePropertyGPSLatitude, K_DBL},
    {0x0003, &kCGImagePropertyGPSLongitudeRef, K_STR},
    {0x0004, &kCGImagePropertyGPSLongitude, K_DBL},
    {0x0005, &kCGImagePropertyGPSAltitudeRef, K_INT},
    {0x0006, &kCGImagePropertyGPSAltitude, K_DBL},
    {0x0007, &kCGImagePropertyGPSTimeStamp, K_DBL},
    {0x000c, &kCGImagePropertyGPSSpeedRef, K_STR},
    {0x000d, &kCGImagePropertyGPSSpeed, K_DBL},
    {0x0010, &kCGImagePropertyGPSImgDirectionRef, K_STR},
    {0x0011, &kCGImagePropertyGPSImgDirection, K_DBL},
    {0x001d, &kCGImagePropertyGPSDateStamp, K_STR},
};

struct Reader {
    const uint8_t *p;
    size_t n;
    bool le;
    uint16_t u16(size_t o) const { return o + 2 > n ? 0 : le ? (uint16_t)(p[o] | p[o + 1] << 8) : (uint16_t)(p[o] << 8 | p[o + 1]); }
    uint32_t u32(size_t o) const
    {
        if (o + 4 > n)
            return 0;
        return le ? (uint32_t)(p[o] | p[o + 1] << 8 | p[o + 2] << 16 | (uint32_t)p[o + 3] << 24)
                  : (uint32_t)((uint32_t)p[o] << 24 | p[o + 1] << 16 | p[o + 2] << 8 | p[o + 3]);
    }
};

/* "0221" -> (2, 2, 1), "0220" -> (2, 2), as Apple's ExifVersion reads. */
CFArrayRef
version_array(const char *v)
{
    int parts[3] = {(v[0] - '0') * 10 + (v[1] - '0'), v[2] - '0', v[3] - '0'};
    int n = parts[2] ? 3 : 2;
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, n, &kCFTypeArrayCallBacks);
    for (int i = 0; i < n; i++) {
        CFNumberRef num = IIONumberI32(parts[i]);
        CFArrayAppendValue(a, num);
        CFRelease(num);
    }
    return a;
}

const size_t type_size[] = {0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8};

double
value_at(const Reader &r, uint16_t type, size_t o)
{
    switch (type) {
    case 1: case 7: return r.p[o];
    case 6: return (int8_t)r.p[o];
    case 3: return r.u16(o);
    case 8: return (int16_t)r.u16(o);
    case 4: return r.u32(o);
    case 9: return (int32_t)r.u32(o);
    case 5: { uint32_t d = r.u32(o + 4); return d ? (double)r.u32(o) / d : 0; }
    case 10: { int32_t d = (int32_t)r.u32(o + 4); return d ? (double)(int32_t)r.u32(o) / d : 0; }
    default: return 0;
    }
}

void
read_ifd(const Reader &r, size_t off, const Tag *tags, size_t ntags, IIODict &d, size_t *exif_ifd, size_t *gps_ifd,
         int depth)
{
    if (off + 2 > r.n || depth > 2)
        return;
    uint16_t count = r.u16(off);
    for (uint16_t i = 0; i < count; i++) {
        size_t e = off + 2 + 12 * (size_t)i;
        if (e + 12 > r.n)
            return;
        uint16_t tag = r.u16(e), type = r.u16(e + 2);
        uint32_t cnt = r.u32(e + 4);
        if (type == 0 || type > 12)
            continue;
        size_t size = type_size[type] * (size_t)cnt;
        size_t vo = size <= 4 ? e + 8 : r.u32(e + 8);
        if (vo > r.n || size > r.n - vo)
            continue;
        if (tag == 0x8769 && exif_ifd) {
            *exif_ifd = r.u32(e + 8);
            continue;
        }
        if (tag == 0x8825 && gps_ifd) {
            *gps_ifd = r.u32(e + 8);
            continue;
        }
        const Tag *t = NULL;
        for (size_t k = 0; k < ntags; k++)
            if (tags[k].tag == tag)
                t = &tags[k];
        if (!t)
            continue;
        Kind kind = t->kind;
        if (kind == K_DBL && cnt > 1)
            kind = K_INTS;  /* arrays of rationals */
        switch (kind) {
        case K_STR: {
            size_t len = size;
            while (len && !r.p[vo + len - 1])
                len--;
            d.str(*t->key, (const char *)r.p + vo, len);
            break;
        }
        case K_COMMENT: {
            if (size < 8)
                break;
            size_t len = size - 8;
            const char *s = (const char *)r.p + vo + 8;
            while (len && (!s[len - 1] || s[len - 1] == ' '))
                len--;
            d.str(*t->key, s, len, memcmp(r.p + vo, "UNICODE", 7) ? kCFStringEncodingUTF8
                                                                   : (r.le ? kCFStringEncodingUTF16LE : kCFStringEncodingUTF16BE));
            break;
        }
        case K_INT:
            d.i32(*t->key, (int32_t)value_at(r, type, vo));
            break;
        case K_DBL:
            d.f64(*t->key, value_at(r, type, vo));
            break;
        case K_INTS: {
            CFMutableArrayRef a = CFArrayCreateMutable(NULL, cnt, &kCFTypeArrayCallBacks);
            bool version = tag == 0x9000 || tag == 0xa000;
            if (version && cnt == 4) {
                char v[5] = {(char)r.p[vo], (char)r.p[vo + 1], (char)r.p[vo + 2], (char)r.p[vo + 3], 0};
                d.set(*t->key, version_array(v));
                CFRelease(a);
                break;
            }
            for (uint32_t k = 0; k < cnt && k < 64; k++) {
                double v = value_at(r, type, vo + k * type_size[type]);
                if (version && type == 7)
                    v -= '0';
                CFNumberRef num = type == 5 || type == 10 ? IIONumberF64(v) : IIONumberI32((int32_t)v);
                CFArrayAppendValue(a, num);
                CFRelease(num);
            }
            d.set(*t->key, a);
            break;
        }
        }
    }
}

void
exif_finish(IIOExif &out)
{
    double v;
    if (IIOGetDouble(out.tiff.d, kCGImagePropertyTIFFOrientation, &v))
        out.orientation = (int)v;
    if (IIOGetDouble(out.tiff.d, kCGImagePropertyTIFFXResolution, &v))
        out.xres = v;
    if (IIOGetDouble(out.tiff.d, kCGImagePropertyTIFFYResolution, &v))
        out.yres = v;
    out.resunit = IIOGetDouble(out.tiff.d, kCGImagePropertyTIFFResolutionUnit, &v) ? (int)v : 2;
}

/* XMP dates (2014-06-20T15:09:16+02:00) as EXIF writes them (2014:06:20 15:09:16). */
std::string
exif_date(const std::string &v)
{
    if (v.size() < 10 || v[4] != '-' || v[7] != '-')
        return v;
    std::string d = v.substr(0, 4) + ":" + v.substr(5, 2) + ":" + v.substr(8, 2);
    std::string hh = "00", mm = "00", ss = "00";
    if (v.size() >= 16 && v[10] == 'T' && v[13] == ':') {
        hh = v.substr(11, 2), mm = v.substr(14, 2);
        if (v.size() >= 19 && v[16] == ':')
            ss = v.substr(17, 2);
        else if (v.size() == 16)
            return "";  /* Apple skips minute-precision times without a zone */
    }
    return d + " " + hh + ":" + mm + ":" + ss;
}

void
xmp_value(IIOExif &e, const std::string &prefix, const std::string &name, const std::string &value)
{
    const Tag *tags = NULL;
    size_t ntags = 0;
    IIODict *d = NULL;
    std::string key = name, v = value;
    if (prefix == "xmp") {
        /* ModifyDate and CreatorTool reach {TIFF} only beside tiff: properties */
        if (name == "ModifyDate")
            tags = tiff_tags, ntags = sizeof tiff_tags / sizeof *tiff_tags, d = &e.xmp_tiff, key = "DateTime";
        else if (name == "CreateDate")
            tags = exif_tags, ntags = sizeof exif_tags / sizeof *exif_tags, d = &e.exif, key = "DateTimeDigitized";
        else if (name == "CreatorTool")
            tags = tiff_tags, ntags = sizeof tiff_tags / sizeof *tiff_tags, d = &e.xmp_tiff, key = "Software";
        else
            return;
    } else if (prefix == "tiff") {
        tags = tiff_tags, ntags = sizeof tiff_tags / sizeof *tiff_tags, d = &e.tiff;
    } else if (prefix == "exif") {
        tags = exif_tags, ntags = sizeof exif_tags / sizeof *exif_tags, d = &e.exif;
    } else {
        return;
    }
    if (key.find("Date") != std::string::npos) {
        v = exif_date(v);
        if (v.empty())
            return;
    }
    for (size_t i = 0; i < ntags; i++) {
        CFStringRef k = *tags[i].key;
        char buf[128];
        if (!CFStringGetCString(k, buf, sizeof buf, kCFStringEncodingASCII) || key != buf)
            continue;
        if (CFDictionaryContainsKey(d->d, k))
            return;  /* EXIF wins */
        switch (tags[i].kind) {
        case K_STR:
        case K_COMMENT:
            d->str(k, v.data(), v.size());
            break;
        case K_INT:
            d->i32(k, atoi(v.c_str()));
            break;
        case K_DBL: {
            double num = atof(v.c_str());
            size_t slash = v.find('/');
            if (slash != std::string::npos) {
                double den = atof(v.c_str() + slash + 1);
                num = den ? num / den : 0;
            }
            d->f64(k, num);
            break;
        }
        case K_INTS:
            if ((key == "ExifVersion" || key == "FlashPixVersion") && v.size() == 4)
                d->set(k, version_array(v.c_str()));
            break;
        }
        if (prefix != "xmp" || name == "CreateDate")
            e.xmp_props++;
        if (prefix == "tiff")
            e.xmp_tiff_props++;
        return;
    }
}

} // namespace

void
IIOParseXMP(const char *p, size_t n, IIOExif &out)
{
    /* Apple uses a packet only when it has TIFF or Exif properties. */
    IIOExif e;
    std::string x(p, n);
    static const char *prefixes[] = {"xmp:", "xap:", "tiff:", "exif:"};  /* xap: is xmp: in older packets */
    for (const char *pf : prefixes) {
        size_t plen = strlen(pf);
        for (size_t at = x.find(pf); at != std::string::npos; at = x.find(pf, at + 1)) {
            if (at && (isalnum((unsigned char)x[at - 1]) || x[at - 1] == ':' || x[at - 1] == '/'))
                continue;
            size_t ne = at + plen;
            while (ne < x.size() && (isalnum((unsigned char)x[ne]) || x[ne] == '_'))
                ne++;
            std::string name = x.substr(at + plen, ne - at - plen), value;
            if (name.empty())
                continue;
            if (x.compare(ne, 2, "=\"") == 0) {
                size_t end = x.find('"', ne + 2);
                if (end == std::string::npos)
                    continue;
                value = x.substr(ne + 2, end - ne - 2);
            } else if (at && x[at - 1] == '<' && ne < x.size() && x[ne] == '>') {
                size_t end = x.find('<', ne + 1);
                if (end == std::string::npos || x.compare(end, 2, "</") != 0)
                    continue;
                value = x.substr(ne + 1, end - ne - 1);
            } else {
                continue;
            }
            bool xmp = !strcmp(pf, "xmp:") || !strcmp(pf, "xap:");
            xmp_value(e, xmp ? "xmp" : std::string(pf, plen - 1), name, value);
            if (xmp && name == "CreatorTool")
                out.creator_tool = value;
            if (xmp && name == "CreateDate")
                out.create_date = value;
        }
    }
    if (!e.xmp_props)
        return;
    IIODict *from[] = {&e.tiff, &e.exif, &e.xmp_tiff}, *to[] = {&out.tiff, &out.exif, &out.tiff};
    for (int i = 0; i < (e.xmp_tiff_props ? 3 : 2); i++) {
        CFIndex k = CFDictionaryGetCount(from[i]->d);
        std::vector<const void *> keys(k), vals(k);
        CFDictionaryGetKeysAndValues(from[i]->d, keys.data(), vals.data());
        for (CFIndex j = 0; j < k; j++)
            if (!CFDictionaryContainsKey(to[i]->d, keys[j]))
                CFDictionarySetValue(to[i]->d, keys[j], vals[j]);
    }
    exif_finish(out);
}

bool
IIOParseExif(const uint8_t *p, size_t n, IIOExif &out)
{
    if (n < 8 || !((p[0] == 'I' && p[1] == 'I') || (p[0] == 'M' && p[1] == 'M')))
        return false;
    Reader r = {p, n, p[0] == 'I'};
    if (r.u16(2) != 42)
        return false;
    return IIOParseTIFFIFD(p, n, r.u32(4), out);
}

bool
IIOParseTIFFIFD(const uint8_t *p, size_t n, size_t ifd, IIOExif &out)
{
    if (n < 8 || !((p[0] == 'I' && p[1] == 'I') || (p[0] == 'M' && p[1] == 'M')))
        return false;
    Reader r = {p, n, p[0] == 'I'};
    size_t exif = 0, gps = 0;
    read_ifd(r, ifd, tiff_tags, sizeof tiff_tags / sizeof *tiff_tags, out.tiff, &exif, &gps, 0);
    if (exif)
        read_ifd(r, exif, exif_tags, sizeof exif_tags / sizeof *exif_tags, out.exif, NULL, NULL, 1);
    if (gps)
        read_ifd(r, gps, gps_tags, sizeof gps_tags / sizeof *gps_tags, out.gps, NULL, NULL, 1);
    exif_finish(out);
    return true;
}

void
IIOAddExif(IIODict &props, IIOExif &e, bool dpi)
{
    if (e.orientation >= 1 && e.orientation <= 8)
        props.i32(kCGImagePropertyOrientation, e.orientation);
    if (dpi && e.xres > 0 && e.yres > 0 && e.resunit == 2) {
        props.f32(kCGImagePropertyDPIWidth, (float)e.xres);
        props.f32(kCGImagePropertyDPIHeight, (float)e.yres);
    } else if (dpi && e.xres > 0 && e.yres > 0 && e.resunit == 3) {
        /* centimetres: Apple reports these as doubles, rounded near whole numbers */
        double x = e.xres * 2.54, y = e.yres * 2.54;
        props.f64(kCGImagePropertyDPIWidth, fabs(x - round(x)) < 0.01 ? round(x) : x);
        props.f64(kCGImagePropertyDPIHeight, fabs(y - round(y)) < 0.01 ? round(y) : y);
    }
    props.sub(kCGImagePropertyTIFFDictionary, e.tiff);
    props.sub(kCGImagePropertyExifDictionary, e.exif);
    props.sub(kCGImagePropertyGPSDictionary, e.gps);
}

namespace {

struct Writer {
    std::vector<uint8_t> b;
    void u16(uint16_t v) { b.push_back(v >> 8), b.push_back((uint8_t)v); }
    void u32(uint32_t v) { u16(v >> 16), u16((uint16_t)v); }
    void entry(uint16_t tag, uint16_t type, uint32_t count, uint32_t value)
    {
        u16(tag), u16(type), u32(count);
        if (type == 3 && count == 1)
            u16((uint16_t)value), u16(0);
        else
            u32(value);
    }
};

} // namespace

std::vector<uint8_t>
IIOMakeExif(size_t w, size_t h, bool rgb, int orientation, double dpi_x, double dpi_y)
{
    bool dpi = dpi_x > 0 && dpi_y > 0;
    uint16_t n0 = (orientation ? 1 : 0) + (dpi ? 3 : 0) + 1;
    uint16_t n1 = (rgb ? 1 : 0) + 2;
    uint32_t ifd0 = 8, rationals = ifd0 + 2 + 12 * n0 + 4, exif = rationals + (dpi ? 16 : 0);
    Writer o;
    o.b = {'M', 'M', 0, 42};
    o.u32(ifd0);
    o.u16(n0);
    if (orientation)
        o.entry(0x0112, 3, 1, (uint32_t)orientation);
    if (dpi) {
        o.entry(0x011a, 5, 1, rationals);
        o.entry(0x011b, 5, 1, rationals + 8);
        o.entry(0x0128, 3, 1, 2);
    }
    o.entry(0x8769, 4, 1, exif);
    o.u32(0);
    if (dpi) {
        o.u32((uint32_t)lround(dpi_x)), o.u32(1);
        o.u32((uint32_t)lround(dpi_y)), o.u32(1);
    }
    o.u16(n1);
    if (rgb)
        o.entry(0xa001, 3, 1, 1);
    o.entry(0xa002, 4, 1, (uint32_t)w);
    o.entry(0xa003, 4, 1, (uint32_t)h);
    o.u32(0);
    return o.b;
}

/* ---- IPTC (Photoshop image resources) -------------------------------------- */

namespace {

struct IPTCKey {
    uint8_t dataset;
    const CFStringRef *key;
    bool array;
};

const IPTCKey iptc_keys[] = {
    {3, &kCGImagePropertyIPTCObjectTypeReference, false}, {4, &kCGImagePropertyIPTCObjectAttributeReference, true},
    {5, &kCGImagePropertyIPTCObjectName, false},          {7, &kCGImagePropertyIPTCEditStatus, false},
    {8, &kCGImagePropertyIPTCEditorialUpdate, false},     {10, &kCGImagePropertyIPTCUrgency, false},
    {12, &kCGImagePropertyIPTCSubjectReference, true},    {15, &kCGImagePropertyIPTCCategory, false},
    {20, &kCGImagePropertyIPTCSupplementalCategory, true}, {22, &kCGImagePropertyIPTCFixtureIdentifier, false},
    {25, &kCGImagePropertyIPTCKeywords, true},            {26, &kCGImagePropertyIPTCContentLocationCode, true},
    {27, &kCGImagePropertyIPTCContentLocationName, true}, {30, &kCGImagePropertyIPTCReleaseDate, false},
    {35, &kCGImagePropertyIPTCReleaseTime, false},        {37, &kCGImagePropertyIPTCExpirationDate, false},
    {38, &kCGImagePropertyIPTCExpirationTime, false},     {40, &kCGImagePropertyIPTCSpecialInstructions, false},
    {42, &kCGImagePropertyIPTCActionAdvised, false},      {45, &kCGImagePropertyIPTCReferenceService, true},
    {47, &kCGImagePropertyIPTCReferenceDate, true},       {50, &kCGImagePropertyIPTCReferenceNumber, true},
    {55, &kCGImagePropertyIPTCDateCreated, false},        {60, &kCGImagePropertyIPTCTimeCreated, false},
    {62, &kCGImagePropertyIPTCDigitalCreationDate, false}, {63, &kCGImagePropertyIPTCDigitalCreationTime, false},
    {65, &kCGImagePropertyIPTCOriginatingProgram, false}, {70, &kCGImagePropertyIPTCProgramVersion, false},
    {75, &kCGImagePropertyIPTCObjectCycle, false},        {80, &kCGImagePropertyIPTCByline, true},
    {85, &kCGImagePropertyIPTCBylineTitle, true},         {90, &kCGImagePropertyIPTCCity, false},
    {92, &kCGImagePropertyIPTCSubLocation, false},        {95, &kCGImagePropertyIPTCProvinceState, false},
    {100, &kCGImagePropertyIPTCCountryPrimaryLocationCode, false},
    {101, &kCGImagePropertyIPTCCountryPrimaryLocationName, false},
    {103, &kCGImagePropertyIPTCOriginalTransmissionReference, false},
    {105, &kCGImagePropertyIPTCHeadline, false},          {110, &kCGImagePropertyIPTCCredit, false},
    {115, &kCGImagePropertyIPTCSource, false},            {116, &kCGImagePropertyIPTCCopyrightNotice, false},
    {118, &kCGImagePropertyIPTCContact, true},            {120, &kCGImagePropertyIPTCCaptionAbstract, false},
    {122, &kCGImagePropertyIPTCWriterEditor, true},       {130, &kCGImagePropertyIPTCImageType, false},
    {131, &kCGImagePropertyIPTCImageOrientation, false},  {135, &kCGImagePropertyIPTCLanguageIdentifier, false},
};

CFStringRef
iptc_string(const uint8_t *p, size_t n, bool utf8)
{
    CFStringRef s = CFStringCreateWithBytes(NULL, p, (CFIndex)n, kCFStringEncodingUTF8, false);
    if (!s && !utf8)
        s = CFStringCreateWithBytes(NULL, p, (CFIndex)n, kCFStringEncodingMacRoman, false);
    return s;
}

void
read_iptc(const uint8_t *p, size_t n, IIODict &d)
{
    bool utf8 = false;
    std::vector<std::pair<const IPTCKey *, CFStringRef>> values;
    for (size_t o = 0; o + 5 <= n;) {
        if (p[o] != 0x1c)
            break;
        uint8_t rec = p[o + 1], ds = p[o + 2];
        size_t len = (size_t)p[o + 3] << 8 | p[o + 4];
        o += 5;
        if (len & 0x8000 || o + len > n)
            break;
        if (rec == 1 && ds == 90 && len >= 3 && !memcmp(p + o, "\x1b%G", 3))
            utf8 = true;
        if (rec == 2)
            for (const IPTCKey &k : iptc_keys)
                if (k.dataset == ds) {
                    CFStringRef s = iptc_string(p + o, len, utf8);
                    if (s)
                        values.push_back({&k, s});
                }
        o += len;
    }
    for (auto &v : values) {
        if (v.first->array) {
            CFMutableArrayRef a = (CFMutableArrayRef)CFDictionaryGetValue(d.d, *v.first->key);
            if (!a) {
                a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
                CFDictionarySetValue(d.d, *v.first->key, a);
                CFRelease(a);
            }
            CFArrayAppendValue(a, v.second);
            CFRelease(v.second);
        } else {
            d.set(*v.first->key, v.second);
        }
    }
}

/* "20060127" + "134826-0800" -> "2006:01:27 13:48:26" */
CFStringRef
iptc_date(CFDictionaryRef d, CFStringRef date_key, CFStringRef time_key)
{
    CFStringRef date = (CFStringRef)CFDictionaryGetValue(d, date_key), time = (CFStringRef)CFDictionaryGetValue(d, time_key);
    char ds[32] = "", ts[32] = "000000";
    if (!date || !CFStringGetCString(date, ds, sizeof ds, kCFStringEncodingASCII) || strlen(ds) < 8)
        return NULL;
    if (time)
        CFStringGetCString(time, ts, sizeof ts, kCFStringEncodingASCII);
    if (strlen(ts) < 6)
        strcpy(ts, "000000");
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("%.4s:%.2s:%.2s %.2s:%.2s:%.2s"), ds, ds + 4, ds + 6, ts, ts + 2,
                                    ts + 4);
}

} // namespace

void
IIOParsePhotoshop(const uint8_t *p, size_t n, IIODict &iptc, IIOExif &e)
{
    size_t o = 0;
    while (o + 12 <= n && !memcmp(p + o, "8BIM", 4)) {
        uint16_t id = (uint16_t)(p[o + 4] << 8 | p[o + 5]);
        size_t nl = p[o + 6];
        size_t q = o + 6 + ((nl + 2) & ~(size_t)1);
        if (q + 4 > n)
            return;
        size_t size = be32(p + q);
        q += 4;
        if (size > n - q)
            return;
        if (id == 0x0404)
            read_iptc(p + q, size, iptc);
        o = q + ((size + 1) & ~(size_t)1);
    }
    /* XMP's creation date fills IPTC's digital creation date and time */
    const std::string &cd = e.create_date;
    if (cd.size() >= 22 && cd[4] == '-' && cd.find_first_of("+-", 19) != std::string::npos &&
        !CFDictionaryContainsKey(iptc.d, kCGImagePropertyIPTCDigitalCreationDate)) {
        std::string date = cd.substr(0, 4) + cd.substr(5, 2) + cd.substr(8, 2);
        iptc.str(kCGImagePropertyIPTCDigitalCreationDate, date.data(), date.size());
        if (cd.size() >= 16 && cd[10] == 'T') {
            std::string t = cd.substr(11, 2) + cd.substr(14, 2) + (cd.size() >= 19 && cd[16] == ':' ? cd.substr(17, 2) : "00");
            size_t z = cd.find_first_of("+-", 16);
            if (z != std::string::npos && cd.size() >= z + 6)
                t += cd.substr(z, 3) + cd.substr(z + 4, 2);
            iptc.str(kCGImagePropertyIPTCDigitalCreationTime, t.data(), t.size());
        }
    }
    CFStringRef dig = iptc_date(iptc.d, kCGImagePropertyIPTCDigitalCreationDate, kCGImagePropertyIPTCDigitalCreationTime);
    if (dig && !CFDictionaryContainsKey(e.exif.d, kCGImagePropertyExifDateTimeDigitized))
        CFDictionarySetValue(e.exif.d, kCGImagePropertyExifDateTimeDigitized, dig);
    if (dig)
        CFRelease(dig);
    CFStringRef orig = iptc_date(iptc.d, kCGImagePropertyIPTCDateCreated, kCGImagePropertyIPTCTimeCreated);
    if (orig && !CFDictionaryContainsKey(e.exif.d, kCGImagePropertyExifDateTimeOriginal))
        CFDictionarySetValue(e.exif.d, kCGImagePropertyExifDateTimeOriginal, orig);
    if (orig)
        CFRelease(orig);
}
