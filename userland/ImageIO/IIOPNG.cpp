/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * PNG: properties from the chunks before the first IDAT, pixels from libpng's
 * progressive reader (so truncated and incremental data give the rows that
 * have arrived), in the layouts Apple's ImageIO returns:
 *
 *   gray 1-8 bit      8 bpp gray         gray 16    16 bpp, little-endian
 *   gray + alpha      16 bpp, alpha last (32 bpp at 16 bits)
 *   RGB 8             32 bpp RGBX (kCGImageAlphaNoneSkipLast)
 *   RGB 16            48 bpp, little-endian
 *   RGBA              alpha last, not premultiplied
 *   palette           8 bpp indexed over sRGB (RGBA when it has tRNS)
 */
#include "ImageIOInternal.h"
#include <math.h>
#include <png.h>
#include <setjmp.h>
#include <string>
#include <zlib.h>

namespace {

uint32_t
be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
}

struct Header {
    uint32_t w = 0, h = 0;
    int depth = 0, ctype = 0, interlace = 0;
    bool trns = false, srgb = false, gama = false, chrm = false, phys = false;
    int srgb_intent = 0, phys_unit = 0;
    uint32_t gamma = 0, chrm_v[8] = {}, ppx = 0, ppy = 0;
    std::vector<uint8_t> icc;
    std::vector<uint8_t> exif;
    std::string xmp;
    bool ready = false;
};

bool
inflate_all(const uint8_t *p, size_t n, std::vector<uint8_t> &out)
{
    z_stream z = {};
    if (inflateInit(&z) != Z_OK)
        return false;
    z.next_in = (Bytef *)p;
    z.avail_in = (uInt)n;
    uint8_t buf[4096];
    int r;
    do {
        z.next_out = buf;
        z.avail_out = sizeof buf;
        r = inflate(&z, Z_NO_FLUSH);
        out.insert(out.end(), buf, buf + (sizeof buf - z.avail_out));
        if (out.size() > (16u << 20))
            break;
    } while (r == Z_OK);
    inflateEnd(&z);
    return r == Z_STREAM_END;
}

struct TextKey {
    const char *keyword;
    const CFStringRef *key;
};
const TextKey text_keys[] = {
    {"Title", &kCGImagePropertyPNGTitle},       {"Author", &kCGImagePropertyPNGAuthor},
    {"Description", &kCGImagePropertyPNGDescription}, {"Copyright", &kCGImagePropertyPNGCopyright},
    {"Creation Time", &kCGImagePropertyPNGCreationTime}, {"Software", &kCGImagePropertyPNGSoftware},
    {"Disclaimer", &kCGImagePropertyPNGDisclaimer}, {"Warning", &kCGImagePropertyPNGWarning},
    {"Source", &kCGImagePropertyPNGSource},     {"Comment", &kCGImagePropertyPNGComment},
};

void
text_chunk(const char *type, const uint8_t *d, uint32_t len, IIODict &png, IIODict &iptc, IIODict &exif,
           std::string &xmp)
{
    const uint8_t *nul = (const uint8_t *)memchr(d, 0, len);
    if (!nul)
        return;
    std::string keyword((const char *)d, nul - d);
    const uint8_t *v = nul + 1;
    size_t vlen = len - (v - d);
    std::vector<uint8_t> text;
    CFStringEncoding enc = kCFStringEncodingISOLatin1;
    if (!strcmp(type, "tEXt")) {
        text.assign(v, v + vlen);
    } else if (!strcmp(type, "zTXt")) {
        if (vlen < 1 || !inflate_all(v + 1, vlen - 1, text))
            return;
    } else { /* iTXt: flag, method, language\0, translated keyword\0, text */
        if (vlen < 2)
            return;
        bool compressed = v[0];
        const uint8_t *e = v + 2, *end = v + vlen;
        for (int k = 0; k < 2; k++) {
            e = (const uint8_t *)memchr(e, 0, end - e);
            if (!e)
                return;
            e++;
        }
        if (compressed) {
            if (!inflate_all(e, end - e, text))
                return;
        } else {
            text.assign(e, end);
        }
        enc = kCFStringEncodingUTF8;
    }
    if (keyword == "XML:com.adobe.xmp") {
        xmp.assign((const char *)text.data(), text.size());
        return;
    }
    for (const TextKey &t : text_keys) {
        if (keyword != t.keyword)
            continue;
        png.str(*t.key, (const char *)text.data(), text.size(), enc);
        if (keyword == "Title")
            iptc.str(kCGImagePropertyIPTCObjectName, (const char *)text.data(), text.size(), enc);
        if (keyword == "Comment")
            exif.str(kCGImagePropertyExifUserComment, (const char *)text.data(), text.size(), enc);
    }
}

void
read_header(const uint8_t *p, size_t n, Header &h, IIODict *pngd, IIODict *iptc, IIODict *exifd)
{
    size_t o = 8;
    while (o + 8 <= n) {
        uint32_t len = be32(p + o);
        char type[5] = {(char)p[o + 4], (char)p[o + 5], (char)p[o + 6], (char)p[o + 7], 0};
        if (!strcmp(type, "IDAT")) {
            h.ready = h.w != 0;
            return;
        }
        if (len > n || o + 12 + (size_t)len > n)
            return;
        const uint8_t *d = p + o + 8;
        if (!strcmp(type, "IHDR") && len >= 13) {
            h.w = be32(d), h.h = be32(d + 4), h.depth = d[8], h.ctype = d[9], h.interlace = d[12];
        } else if (!strcmp(type, "tRNS")) {
            h.trns = true;
        } else if (!strcmp(type, "sRGB") && len >= 1) {
            h.srgb = true, h.srgb_intent = d[0];
        } else if (!strcmp(type, "gAMA") && len >= 4) {
            h.gama = true, h.gamma = be32(d);
        } else if (!strcmp(type, "cHRM") && len >= 32) {
            h.chrm = true;
            for (int i = 0; i < 8; i++)
                h.chrm_v[i] = be32(d + 4 * i);
        } else if (!strcmp(type, "pHYs") && len >= 9) {
            h.phys = true, h.ppx = be32(d), h.ppy = be32(d + 4), h.phys_unit = d[8];
        } else if (!strcmp(type, "iCCP")) {
            const uint8_t *nul = (const uint8_t *)memchr(d, 0, len);
            if (nul && nul + 2 <= d + len) {
                h.icc.clear();
                if (!inflate_all(nul + 2, d + len - (nul + 2), h.icc))
                    h.icc.clear();
            }
        } else if (!strcmp(type, "eXIf")) {
            h.exif.assign(d, d + len);
        } else if (pngd && (!strcmp(type, "tEXt") || !strcmp(type, "zTXt") || !strcmp(type, "iTXt"))) {
            text_chunk(type, d, len, *pngd, *iptc, *exifd, h.xmp);
        }
        o += 12 + (size_t)len;
    }
}

bool
gray_type(int ctype)
{
    return ctype == 0 || ctype == 4;
}

const uint32_t srgb_chrm[8] = {31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000};

bool
srgb_gamma(uint32_t g)
{
    return fabs(g - 45455.0) < 100;
}

/* A calibrated space for gAMA (and cHRM) values other than sRGB's and linear. */
CGColorSpaceRef
calibrated(const Header &h, bool gray)
{
    const uint32_t *c = h.chrm ? h.chrm_v : srgb_chrm;
    double xy[8];
    for (int i = 0; i < 8; i++)
        xy[i] = c[i] * .00001;
    CGFloat white[3] = {xy[0] / xy[1], 1, (1 - xy[0] - xy[1]) / xy[1]}, black[3] = {0, 0, 0};
    CGFloat g = h.gamma ? 100000.0 / h.gamma : 2.2;
    if (gray)
        return CGColorSpaceCreateCalibratedGray(white, black, g);
    /* primaries' XYZ, scaled so they sum to the white point */
    double P[3][3];
    for (int i = 0; i < 3; i++) {
        double x = xy[2 + 2 * i], y = xy[3 + 2 * i];
        P[0][i] = x / y, P[1][i] = 1, P[2][i] = (1 - x - y) / y;
    }
    double det = P[0][0] * (P[1][1] * P[2][2] - P[1][2] * P[2][1]) - P[0][1] * (P[1][0] * P[2][2] - P[1][2] * P[2][0]) +
                 P[0][2] * (P[1][0] * P[2][1] - P[1][1] * P[2][0]);
    if (fabs(det) < 1e-12)
        return CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    double inv[3][3] = {
        {(P[1][1] * P[2][2] - P[1][2] * P[2][1]) / det, (P[0][2] * P[2][1] - P[0][1] * P[2][2]) / det,
         (P[0][1] * P[1][2] - P[0][2] * P[1][1]) / det},
        {(P[1][2] * P[2][0] - P[1][0] * P[2][2]) / det, (P[0][0] * P[2][2] - P[0][2] * P[2][0]) / det,
         (P[0][2] * P[1][0] - P[0][0] * P[1][2]) / det},
        {(P[1][0] * P[2][1] - P[1][1] * P[2][0]) / det, (P[0][1] * P[2][0] - P[0][0] * P[2][1]) / det,
         (P[0][0] * P[1][1] - P[0][1] * P[1][0]) / det},
    };
    double S[3];
    for (int i = 0; i < 3; i++)
        S[i] = inv[i][0] * white[0] + inv[i][1] * white[1] + inv[i][2] * white[2];
    CGFloat m[9], gamma[3] = {g, g, g};
    for (int i = 0; i < 3; i++)
        for (int r = 0; r < 3; r++)
            m[3 * i + r] = P[r][i] * S[i];
    return CGColorSpaceCreateCalibratedRGB(white, black, gamma, m);
}

/* The colour space PNG's chunks describe, and whether Apple names its profile. */
CGColorSpaceRef
png_space(const Header &h, bool *named)
{
    bool gray = gray_type(h.ctype);
    *named = false;
    if (!h.icc.empty()) {
        CGColorSpaceRef cs = IIOSpaceFromICC(h.icc.data(), h.icc.size(),
                                             gray ? kCGColorSpaceModelMonochrome : kCGColorSpaceModelRGB);
        if (cs) {
            *named = true;
            return cs;
        }
    }
    if (h.srgb || (h.gama && (h.gamma == 100000 || srgb_gamma(h.gamma))) || (h.ctype == 3 && !h.trns))
        *named = true;
    if (!h.srgb && h.gama && h.gamma && h.gamma != 100000 && !srgb_gamma(h.gamma)) {
        *named = true;
        return calibrated(h, gray);
    }
    if (gray)
        return CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    if (!h.srgb && h.gama && h.gamma == 100000)
        return CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    return CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
}


} // namespace

CFDictionaryRef
IIOPNGCopyProperties(const uint8_t *p, size_t n, bool *ready, int *orientation)
{
    Header h;
    IIODict png, iptc, exifd;
    read_header(p, n, h, &png, &iptc, &exifd);
    *ready = h.ready;
    *orientation = 0;
    if (!h.ready)
        return NULL;
    IIODict d;
    bool gray = gray_type(h.ctype);
    d.str(kCGImagePropertyColorModel, gray ? "Gray" : "RGB", gray ? 4 : 3);
    d.i64(kCGImagePropertyDepth, h.depth);
    d.i64(kCGImagePropertyPixelWidth, h.w);
    d.i64(kCGImagePropertyPixelHeight, h.h);
    if (h.ctype == 4 || h.ctype == 6 || h.trns)
        d.b(kCGImagePropertyHasAlpha, true);
    if (h.ctype == 3 && !h.trns)
        d.b(kCGImagePropertyIsIndexed, true);
    bool named;
    CGColorSpaceRef cs = png_space(h, &named);
    if (named) {
        CFStringRef name = !h.icc.empty() ? IIOCopyICCDescription(h.icc.data(), h.icc.size()) : NULL;
        if (!name && !CGColorSpaceGetName(cs))
            name = CFStringCreateWithCString(NULL, gray ? "Calibrated Gray Colorspace" : "Calibrated RGB Colorspace",
                                             kCFStringEncodingASCII);
        if (!name)
            name = IIOCopyProfileName(cs);
        d.set(kCGImagePropertyProfileName, name);
    }
    CGColorSpaceRelease(cs);

    png.i32(kCGImagePropertyPNGInterlaceType, h.interlace);
    if (h.srgb || h.gama)
        png.f64(kCGImagePropertyPNGGamma, (h.gama ? h.gamma : 45455) * .00001);
    if (h.srgb || h.chrm) {
        CFMutableArrayRef a = CFArrayCreateMutable(NULL, 8, &kCFTypeArrayCallBacks);
        for (int i = 0; i < 8; i++) {
            CFNumberRef v = IIONumberF64((h.chrm ? h.chrm_v[i] : srgb_chrm[i]) * .00001);
            CFArrayAppendValue(a, v);
            CFRelease(v);
        }
        png.set(kCGImagePropertyPNGChromaticities, a);
    }
    if (h.srgb)
        png.i32(kCGImagePropertyPNGsRGBIntent, h.srgb_intent);
    if (h.phys && h.phys_unit == 1) {
        png.i32(kCGImagePropertyPNGXPixelsPerMeter, (int32_t)h.ppx);
        png.i32(kCGImagePropertyPNGYPixelsPerMeter, (int32_t)h.ppy);
        d.f32(kCGImagePropertyDPIWidth, (float)round(h.ppx * 0.0254));
        d.f32(kCGImagePropertyDPIHeight, (float)round(h.ppy * 0.0254));
    } else if (h.phys && h.ppx) {
        png.f32(kCGImagePropertyPNGPixelsAspectRatio, (float)h.ppy / (float)h.ppx);
    }
    IIOExif e;
    bool have_exif = !h.exif.empty() && IIOParseExif(h.exif.data(), h.exif.size(), e);
    if (!h.xmp.empty()) {
        IIOParseXMP(h.xmp.data(), h.xmp.size(), e);
        have_exif = true;
    }
    double colorspace;
    if (!named && !gray && IIOGetDouble(e.exif.d, kCGImagePropertyExifColorSpace, &colorspace) && colorspace == 1)
        d.str(kCGImagePropertyProfileName, "sRGB IEC61966-2.1", 17);
    if (!e.creator_tool.empty())
        png.str(kCGImagePropertyPNGSoftware, e.creator_tool.data(), e.creator_tool.size());
    if (have_exif) {
        /* text-derived Exif keys (UserComment) join the chunk's */
        CFIndex k = CFDictionaryGetCount(exifd.d);
        if (k) {
            std::vector<const void *> keys(k), vals(k);
            CFDictionaryGetKeysAndValues(exifd.d, keys.data(), vals.data());
            for (CFIndex i = 0; i < k; i++)
                CFDictionarySetValue(e.exif.d, keys[i], vals[i]);
        }
        IIOAddExif(d, e, !(h.phys && h.phys_unit == 1));
        *orientation = e.orientation;
    } else {
        d.sub(kCGImagePropertyExifDictionary, exifd);
    }
    d.sub(kCGImagePropertyIPTCDictionary, iptc);
    d.sub(kCGImagePropertyPNGDictionary, png);
    return d.copy();
}

namespace {

struct Decode {
    jmp_buf jb;
    IIOPixels *out;
    size_t rowbytes;
};

void
png_error_fn(png_structp png, png_const_charp msg)
{
    Decode *d = (Decode *)png_get_error_ptr(png);
    longjmp(d->jb, 1);
}

void
png_warn_fn(png_structp, png_const_charp)
{
}

void
info_fn(png_structp png, png_infop info)
{
    Decode *d = (Decode *)png_get_progressive_ptr(png);
    png_uint_32 w, h;
    int depth, ctype, interlace;
    png_get_IHDR(png, info, &w, &h, &depth, &ctype, &interlace, NULL, NULL);
    bool trns = png_get_valid(png, info, PNG_INFO_tRNS);
    size_t bpc = depth == 16 ? 16 : 8, bpp;
    CGBitmapInfo bi;
    IIOPixels &o = *d->out;
    if (ctype == PNG_COLOR_TYPE_PALETTE) {
        if (trns) {
            png_set_palette_to_rgb(png);
            png_set_tRNS_to_alpha(png);
            bpc = 8, bpp = 32, bi = kCGImageAlphaLast;
        } else {
            png_set_packing(png);
            bpc = 8, bpp = 8, bi = kCGImageAlphaNone;
        }
    } else if (ctype == PNG_COLOR_TYPE_GRAY || ctype == PNG_COLOR_TYPE_GRAY_ALPHA) {
        if (depth < 8)
            png_set_expand_gray_1_2_4_to_8(png);
        bool alpha = ctype == PNG_COLOR_TYPE_GRAY_ALPHA || trns;
        if (trns)
            png_set_tRNS_to_alpha(png);
        bpp = bpc * (alpha ? 2 : 1);
        bi = alpha ? kCGImageAlphaLast : kCGImageAlphaNone;
    } else {
        bool alpha = ctype == PNG_COLOR_TYPE_RGB_ALPHA || trns;
        if (trns)
            png_set_tRNS_to_alpha(png);
        if (alpha) {
            bpp = bpc * 4, bi = kCGImageAlphaLast;
        } else if (bpc == 8) {
            png_set_filler(png, 0xff, PNG_FILLER_AFTER);
            bpp = 32, bi = kCGImageAlphaNoneSkipLast;
        } else {
            bpp = 48, bi = kCGImageAlphaNone;
        }
    }
    if (bpc == 16) {
        png_set_swap(png);
        bi |= kCGBitmapByteOrder16Little;
    }
    if (interlace != PNG_INTERLACE_NONE)
        png_set_interlace_handling(png);
    png_read_update_info(png, info);
    o.alloc(w, h, bpc, bpp);
    o.info = bi;
    d->rowbytes = png_get_rowbytes(png, info);
    if (d->rowbytes > o.bpr)
        longjmp(d->jb, 1);
    if (ctype == PNG_COLOR_TYPE_PALETTE && !trns) {
        png_colorp pal;
        int npal = 0;
        png_get_PLTE(png, info, &pal, &npal);
        std::vector<uint8_t> table(256 * 3, 0);
        for (int i = 0; i < npal && i < 256; i++)
            table[3 * i] = pal[i].red, table[3 * i + 1] = pal[i].green, table[3 * i + 2] = pal[i].blue;
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        o.set_space(CGColorSpaceCreateIndexed(srgb, 255, table.data()));
        CGColorSpaceRelease(srgb);
        o.intent = kCGRenderingIntentDefault;
    }
}

void
row_fn(png_structp png, png_bytep row, png_uint_32 y, int pass)
{
    Decode *d = (Decode *)png_get_progressive_ptr(png);
    IIOPixels &o = *d->out;
    if (!row || y >= o.h)
        return;
    png_progressive_combine_row(png, o.data.data() + y * o.bpr, row);
}

} // namespace

bool
IIOPNGDecode(const uint8_t *p, size_t n, IIOPixels &out)
{
    Header h;
    read_header(p, n, h, NULL, NULL, NULL);
    if (!h.ready || !h.w || !h.h || (uint64_t)h.w * h.h > (1u << 28))
        return false;
    Decode d;
    d.out = &out;
    d.rowbytes = 0;
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, &d, png_error_fn, png_warn_fn);
    if (!png)
        return false;
    png_infop info = png_create_info_struct(png);
    volatile bool ok = false;
    if (!setjmp(d.jb)) {
        png_set_crc_action(png, PNG_CRC_QUIET_USE, PNG_CRC_QUIET_USE);
        png_set_user_limits(png, 0x7fffffff, 0x7fffffff);
        png_set_progressive_read_fn(png, &d, info_fn, row_fn, NULL);
        png_process_data(png, info, (png_bytep)p, n);
        ok = true;
    } else {
        ok = !out.data.empty();  /* partial: the rows so far */
    }
    png_destroy_read_struct(&png, &info, NULL);
    if (!ok)
        return false;
    if (!out.space) {
        bool named;
        out.set_space(png_space(h, &named));
    }
    return true;
}

namespace {

struct PNGCodec : IIOCodec {
    void parse(const uint8_t *p, size_t n, bool final) override
    {
        reset();
        count = 1;
        bool r;
        int o;
        CFDictionaryRef d = IIOPNGCopyProperties(p, n, &r, &o);
        ready.push_back(r);
        props.push_back(d);
        orientation.push_back(o);
    }
    bool decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out) override { return IIOPNGDecode(p, n, out); }
};

} // namespace

IIOCodec *
IIOCodecCreatePNG()
{
    return new PNGCodec;
}

/* ---- encoding -------------------------------------------------------------- */

namespace {

struct Encode {
    jmp_buf jb;
    std::vector<uint8_t> *out;
};

void
enc_error(png_structp png, png_const_charp)
{
    longjmp(((Encode *)png_get_error_ptr(png))->jb, 1);
}

void
enc_write(png_structp png, png_bytep data, size_t len)
{
    std::vector<uint8_t> *o = ((Encode *)png_get_io_ptr(png))->out;
    o->insert(o->end(), data, data + len);
}

void
enc_flush(png_structp)
{
}

} // namespace

bool
IIOEncodePNG(CGImageRef im, const IIOEncodeOptions &opt, std::vector<uint8_t> &out)
{
    CGColorSpaceRef cs = CGImageGetColorSpace(im);
    if (!cs)
        return false;
    size_t w = CGImageGetWidth(im), h = CGImageGetHeight(im);
    bool indexed = CGColorSpaceGetModel(cs) == kCGColorSpaceModelIndexed && CGImageGetBitsPerComponent(im) <= 8;
    std::vector<uint8_t> rows;
    int ctype, depth = 8;
    size_t rb;
    CGColorSpaceRef base = indexed ? CGColorSpaceGetBaseColorSpace(cs) : cs;
    bool gray = CGColorSpaceGetModel(base) == kCGColorSpaceModelMonochrome;
    std::vector<uint8_t> table;
    if (indexed) {
        if (CGColorSpaceGetModel(base) != kCGColorSpaceModelRGB)
            return false;
        size_t bpc = CGImageGetBitsPerComponent(im), bpr = CGImageGetBytesPerRow(im);
        CFDataRef d = CGDataProviderCopyData(CGImageGetDataProvider(im));
        if (!d || (size_t)CFDataGetLength(d) < bpr * (h - 1) + (w * CGImageGetBitsPerPixel(im) + 7) / 8) {
            if (d)
                CFRelease(d);
            return false;
        }
        rb = w;
        rows.resize(rb * h);
        const uint8_t *src = CFDataGetBytePtr(d);
        size_t bpp = CGImageGetBitsPerPixel(im);
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++) {
                size_t bit = x * bpp;
                unsigned v = 0;
                for (size_t i = 0; i < bpc; i++, bit++)
                    v = v << 1 | ((src[y * bpr + bit / 8] >> (7 - bit % 8)) & 1);
                rows[y * rb + x] = (uint8_t)v;
            }
        CFRelease(d);
        table.resize(CGColorSpaceGetColorTableCount(cs) * 3);
        CGColorSpaceGetColorTable(cs, table.data());
        ctype = PNG_COLOR_TYPE_PALETTE;
    } else {
        IIOFloatImage f;
        if (!IIOReadImage(im, f) || (f.n != 1 && f.n != 3))
            return false;
        depth = CGImageGetBitsPerComponent(im) > 8 ? 16 : 8;
        size_t nc = f.n + (f.alpha ? 1 : 0);
        ctype = f.n == 1 ? (f.alpha ? PNG_COLOR_TYPE_GRAY_ALPHA : PNG_COLOR_TYPE_GRAY)
                         : (f.alpha ? PNG_COLOR_TYPE_RGB_ALPHA : PNG_COLOR_TYPE_RGB);
        rb = w * nc * depth / 8;
        rows.resize(rb * h);
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++) {
                double *px = f.at(x, y);
                for (size_t k = 0; k < nc; k++) {
                    double v = k < f.n ? px[k] : px[f.n];
                    v = v < 0 ? 0 : v > 1 ? 1 : v;
                    uint8_t *o = &rows[y * rb + (x * nc + k) * depth / 8];
                    if (depth == 8) {
                        o[0] = (uint8_t)lround(v * 255);
                    } else {
                        unsigned u = (unsigned)lround(v * 65535);
                        o[0] = (uint8_t)(u >> 8), o[1] = (uint8_t)u;
                    }
                }
            }
    }

    Encode e;
    e.out = &out;
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, &e, enc_error, png_warn_fn);
    if (!png)
        return false;
    png_infop info = png_create_info_struct(png);
    volatile bool ok = false;
    if (!setjmp(e.jb)) {
        png_set_write_fn(png, &e, enc_write, enc_flush);
        png_set_IHDR(png, info, (png_uint_32)w, (png_uint_32)h, depth, ctype,
                     opt.interlace ? PNG_INTERLACE_ADAM7 : PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT,
                     PNG_FILTER_TYPE_DEFAULT);
        if (indexed) {
            png_color pal[256];
            size_t np = table.size() / 3;
            for (size_t i = 0; i < np && i < 256; i++)
                pal[i].red = table[3 * i], pal[i].green = table[3 * i + 1], pal[i].blue = table[3 * i + 2];
            png_set_PLTE(png, info, pal, (int)(np > 256 ? 256 : np));
        } else {
            CFStringRef name = CGColorSpaceGetName(base);
            if (name && CFEqual(name, kCGColorSpaceSRGB)) {
                png_set_sRGB(png, info, PNG_sRGB_INTENT_PERCEPTUAL);
            } else {
                CFDataRef icc = CGColorSpaceCopyICCData(base);
                if (icc) {
                    char pname[80] = "ICC Profile";
                    if (name)
                        CFStringGetCString(name, pname, sizeof pname, kCFStringEncodingASCII);
                    png_set_iCCP(png, info, pname, PNG_COMPRESSION_TYPE_BASE, CFDataGetBytePtr(icc),
                                 (png_uint_32)CFDataGetLength(icc));
                    CFRelease(icc);
                }
            }
        }
        if (opt.dpi_x > 0 && opt.dpi_y > 0)
            png_set_pHYs(png, info, (png_uint_32)lround(opt.dpi_x / 0.0254), (png_uint_32)lround(opt.dpi_y / 0.0254),
                         PNG_RESOLUTION_METER);
        std::vector<uint8_t> exif = IIOMakeExif(w, h, !gray, opt.orientation, opt.dpi_x, opt.dpi_y);
        png_set_eXIf_1(png, info, (png_uint_32)exif.size(), exif.data());
        png_write_info(png, info);
        int passes = opt.interlace ? png_set_interlace_handling(png) : 1;
        for (int pass = 0; pass < passes; pass++)
            for (size_t y = 0; y < h; y++)
                png_write_row(png, &rows[y * rb]);
        png_write_end(png, info);
        ok = true;
    }
    png_destroy_write_struct(&png, &info);
    return ok;
}
