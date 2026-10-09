/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * BMP and ICO. Uncompressed bitmaps are read here, in Apple's layouts: 24-
 * and 32-bit as RGBX (kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast,
 * the fourth byte of a 32-bit pixel kept as it is), 1-8 bit as 8-bit indexed
 * over sRGB. Compressed and bit-field bitmaps go to Skia's BMP codec. ICO
 * entries are PNGs or DIBs (with their AND masks), largest first.
 */
#include "ImageIOInternal.h"
#include "include/codec/SkBmpDecoder.h"
#include "include/codec/SkCodec.h"
#include "include/core/SkData.h"
#include "include/core/SkImageInfo.h"
#include <algorithm>
#include <math.h>

namespace {

uint16_t
le16(const uint8_t *p)
{
    return (uint16_t)(p[0] | p[1] << 8);
}

uint32_t
le32(const uint8_t *p)
{
    return (uint32_t)(p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24);
}

struct DIB {
    uint32_t hsize = 0, compression = 0, clr_used = 0, alpha_mask = 0;
    int32_t w = 0, h = 0, ppx = 0, ppy = 0;
    int bpp = 0;
    bool core = false;
};

bool
read_dib(const uint8_t *p, size_t n, DIB &d)
{
    if (n < 12)
        return false;
    d.hsize = le32(p);
    if (d.hsize == 12) {
        d.core = true;
        d.w = le16(p + 4), d.h = (int16_t)le16(p + 6), d.bpp = le16(p + 10);
        return true;
    }
    if (d.hsize < 40 || n < 40)
        return false;
    d.w = (int32_t)le32(p + 4), d.h = (int32_t)le32(p + 8), d.bpp = le16(p + 14);
    d.compression = le32(p + 16);
    d.ppx = (int32_t)le32(p + 24), d.ppy = (int32_t)le32(p + 28);
    d.clr_used = le32(p + 32);
    if (d.hsize >= 56 && n >= 56)
        d.alpha_mask = le32(p + 52);
    return d.w > 0 && d.h != 0;
}

float
bmp_dpi(int32_t ppm)
{
    float dpi = (float)(ppm * 0.0254);
    if (fabsf(dpi - 72) < 0.1f)
        return 72;
    if (fabsf(dpi - 96) < 0.1f)
        return 96;
    return dpi;
}

/*
 * Decode an uncompressed DIB: `p` is the header, palette follows it, the
 * pixels are at `pix`. ICO DIBs have twice the height (XOR then AND mask).
 */
bool
decode_dib(const uint8_t *p, size_t n, size_t pix, bool ico, IIOPixels &out)
{
    DIB d;
    if (!read_dib(p, n, d) || (d.compression != 0 && !(d.compression == 3 && ico && d.bpp == 32)))
        return false;
    if (d.bpp != 1 && d.bpp != 4 && d.bpp != 8 && d.bpp != 24 && d.bpp != 32)
        return false;
    size_t w = d.w, h = ico ? (size_t)std::abs(d.h) / 2 : (size_t)std::abs(d.h);
    bool bottom_up = d.h > 0;
    if (!w || !h || (uint64_t)w * h > (1u << 28))
        return false;
    size_t entry = d.core ? 3 : 4;
    size_t npal = d.bpp <= 8 ? (d.clr_used && d.clr_used <= (1u << d.bpp) ? d.clr_used : 1u << d.bpp) : 0;
    size_t pal_off = d.hsize + (d.compression == 3 && d.hsize == 40 ? 12 : 0);
    if (pal_off + npal * entry > n)
        npal = pal_off < n ? (n - pal_off) / entry : 0;
    size_t stride = (w * d.bpp + 31) / 32 * 4;
    auto row = [&](size_t y) -> const uint8_t * {
        size_t r = bottom_up ? h - 1 - y : y;
        size_t o = pix + r * stride;
        return o + stride <= n ? p + o : NULL;
    };
    uint8_t table[256 * 3] = {};
    for (size_t i = 0; i < npal; i++) {
        const uint8_t *e = p + pal_off + i * entry;
        table[3 * i] = e[2], table[3 * i + 1] = e[1], table[3 * i + 2] = e[0];
    }
    auto index = [&](const uint8_t *r, size_t x) -> unsigned {
        size_t bit = x * d.bpp;
        return (r[bit / 8] >> (8 - d.bpp - bit % 8)) & ((1u << d.bpp) - 1);
    };

    if (ico) {
        out.alloc(w, h, 8, 32);
        out.info = kCGImageAlphaLast;
        bool any_alpha = false;
        for (size_t y = 0; y < h; y++) {
            const uint8_t *r = row(y);
            if (!r)
                continue;
            uint8_t *o = &out.data[y * out.bpr];
            for (size_t x = 0; x < w; x++, o += 4) {
                if (d.bpp == 32) {
                    o[0] = r[4 * x + 2], o[1] = r[4 * x + 1], o[2] = r[4 * x], o[3] = r[4 * x + 3];
                    any_alpha |= o[3] != 0;
                } else if (d.bpp == 24) {
                    o[0] = r[3 * x + 2], o[1] = r[3 * x + 1], o[2] = r[3 * x], o[3] = 0xff;
                } else {
                    unsigned i = index(r, x);
                    o[0] = table[3 * i], o[1] = table[3 * i + 1], o[2] = table[3 * i + 2], o[3] = 0xff;
                }
            }
        }
        if (d.bpp != 32 || !any_alpha) {
            size_t mstride = (w + 31) / 32 * 4, mpix = pix + stride * h;
            for (size_t y = 0; y < h; y++) {
                size_t o = mpix + (bottom_up ? h - 1 - y : y) * mstride;
                if (o + mstride > n)
                    continue;
                for (size_t x = 0; x < w; x++)
                    out.data[y * out.bpr + 4 * x + 3] = ((p[o + x / 8] >> (7 - x % 8)) & 1) ? 0 : 0xff;
            }
        }
        out.set_space(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
        return true;
    }

    if (d.bpp <= 8) {
        out.alloc(w, h, 8, 8);
        out.info = kCGImageAlphaNone;
        for (size_t y = 0; y < h; y++) {
            const uint8_t *r = row(y);
            if (r)
                for (size_t x = 0; x < w; x++)
                    out.data[y * out.bpr + x] = (uint8_t)index(r, x);
        }
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        out.set_space(CGColorSpaceCreateIndexed(srgb, npal ? npal - 1 : 0, table));
        CGColorSpaceRelease(srgb);
        out.intent = kCGRenderingIntentDefault;
        return true;
    }
    out.alloc(w, h, 8, 32);
    out.info = kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast;
    for (size_t y = 0; y < h; y++) {
        const uint8_t *r = row(y);
        if (!r)
            continue;
        uint8_t *o = &out.data[y * out.bpr];
        for (size_t x = 0; x < w; x++, o += 4) {
            const uint8_t *s = r + x * (d.bpp / 8);
            o[0] = s[2], o[1] = s[1], o[2] = s[0], o[3] = d.bpp == 32 ? s[3] : 0xff;
        }
    }
    out.set_space(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    return true;
}

CFDictionaryRef
dib_props(const DIB &d, bool ico)
{
    IIODict p;
    p.str(kCGImagePropertyColorModel, "RGB", 3);
    p.i64(kCGImagePropertyDepth, 8);
    if (ico || d.alpha_mask)
        p.b(kCGImagePropertyHasAlpha, true);
    if (!ico && d.bpp <= 8) {
        p.b(kCGImagePropertyIsIndexed, true);
        p.str(kCGImagePropertyProfileName, "sRGB IEC61966-2.1", 17);
    }
    p.i64(kCGImagePropertyPixelWidth, d.w);
    p.i64(kCGImagePropertyPixelHeight, ico ? std::abs(d.h) / 2 : std::abs(d.h));
    if (!ico && d.ppx > 0 && d.ppy > 0) {
        p.f32(kCGImagePropertyDPIWidth, bmp_dpi(d.ppx));
        p.f32(kCGImagePropertyDPIHeight, bmp_dpi(d.ppy));
    }
    return p.copy();
}

struct BMPCodec : IIOCodec {
    void parse(const uint8_t *p, size_t n, bool final) override
    {
        reset();
        DIB d;
        count = 1;
        orientation.push_back(0);
        bool ok = n >= 14 && read_dib(p + 14, n - 14, d);
        ready.push_back(ok);
        props.push_back(ok ? dib_props(d, false) : NULL);
    }
    bool decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out) override
    {
        if (n < 14 + 40 && n < 14 + 12)
            return false;
        size_t off = le32(p + 10);
        if (off >= 14 && decode_dib(p + 14, n - 14, off - 14, false, out))
            return true;
        SkCodec::Result r;
        std::unique_ptr<SkCodec> codec = SkBmpDecoder::Decode(SkData::MakeWithCopy(p, n), &r);
        if (!codec)
            return false;
        SkISize size = codec->getInfo().dimensions();
        bool opaque = codec->getInfo().alphaType() == kOpaque_SkAlphaType;
        out.alloc(size.width(), size.height(), 8, 32);
        out.info = kCGBitmapByteOrder32Big | (opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaLast);
        SkImageInfo info = SkImageInfo::Make(size, kRGBA_8888_SkColorType, opaque ? kOpaque_SkAlphaType : kUnpremul_SkAlphaType);
        SkCodec::Result res = codec->getPixels(info, out.data.data(), out.bpr);
        if (res != SkCodec::kSuccess && res != SkCodec::kIncompleteInput && res != SkCodec::kErrorInInput)
            return false;
        out.set_space(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
        return true;
    }
};

/* ---- ICO --------------------------------------------------------------------- */

struct Entry {
    size_t w, bpp, size, offset;
};

const uint8_t png_sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};

struct ICOCodec : IIOCodec {
    std::vector<Entry> entries;
    void parse(const uint8_t *p, size_t n, bool final) override
    {
        reset();
        entries.clear();
        if (n < 6)
            return;
        size_t num = le16(p + 4);
        for (size_t i = 0; i < num && 6 + 16 * (i + 1) <= n; i++) {
            const uint8_t *e = p + 6 + 16 * i;
            entries.push_back({e[0] ? e[0] : 256u, le16(e + 6), le32(e + 8), le32(e + 12)});
        }
        std::stable_sort(entries.begin(), entries.end(), [](const Entry &a, const Entry &b) { return a.w > b.w; });
        for (const Entry &e : entries) {
            count++;
            orientation.push_back(0);
            if (e.offset > n || e.size > n - e.offset) {
                ready.push_back(false);
                props.push_back(NULL);
                continue;
            }
            const uint8_t *d = p + e.offset;
            if (e.size >= 8 && !memcmp(d, png_sig, 8)) {
                bool r;
                int o;
                props.push_back(IIOPNGCopyProperties(d, e.size, &r, &o));
                ready.push_back(r);
            } else {
                DIB dib;
                bool ok = read_dib(d, e.size, dib);
                ready.push_back(ok);
                props.push_back(ok ? dib_props(dib, true) : NULL);
            }
        }
    }
    bool decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out) override
    {
        if (i >= entries.size())
            return false;
        const Entry &e = entries[i];
        if (e.offset > n || e.size > n - e.offset)
            return false;
        const uint8_t *d = p + e.offset;
        if (e.size >= 8 && !memcmp(d, png_sig, 8))
            return IIOPNGDecode(d, e.size, out);
        DIB dib;
        if (!read_dib(d, e.size, dib))
            return false;
        size_t npal = dib.bpp <= 8 ? (dib.clr_used ? dib.clr_used : 1u << dib.bpp) : 0;
        return decode_dib(d, e.size, dib.hsize + npal * 4, true, out);
    }
};

} // namespace

IIOCodec *
IIOCodecCreateBMP()
{
    return new BMPCodec;
}

IIOCodec *
IIOCodecCreateICO()
{
    return new ICOCodec;
}
