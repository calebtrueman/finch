/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * TIFF, read and written by Finch (docs/design/IMAGEIO.md, "TIFF").
 *
 * Reading: every IFD is a frame. Strips or tiles, contiguous or planar;
 * uncompressed, LZW (with the horizontal predictor), PackBits and Deflate;
 * 1-16 bits per sample; white- or black-is-zero gray, RGB, palette and CMYK,
 * with associated or unassociated alpha. Images come out as Apple's do: gray
 * in Generic Gray Gamma 2.2, RGB as RGBX (or premultiplied RGBA) in sRGB,
 * 16-bit samples little-endian, an embedded ICC profile used when there is one.
 *
 * Writing: Apple's layout, big-endian ("MM"). Per image, its strips (as many
 * rows as fit 128 KB of the source image's rows), then its IFD, then the values that don't fit
 * in their entries (resolutions, bits per sample, strip byte counts and
 * offsets, sample formats). Tags: width, height, bits per sample,
 * compression, photometric, fill order, strip offsets, orientation, samples
 * per pixel, rows per strip, strip byte counts, resolutions (unless 72 dpi),
 * planar configuration, resolution unit, predictor (LZW), extra samples
 * (associated alpha) and sample format. LZW and PackBits are encoded as
 * libtiff encodes them, so the bytes match Apple's.
 */
#include "ImageIOInternal.h"
#include <algorithm>
#include <math.h>
#include <string.h>
#include <zlib.h>

namespace {

/* ---- reading the structure ---------------------------------------------- */

struct Reader {
    const uint8_t *p;
    size_t n;
    bool le;
    uint16_t u16(size_t o) const
    {
        if (o + 2 > n) return 0;
        return le ? (uint16_t)(p[o] | p[o + 1] << 8) : (uint16_t)(p[o] << 8 | p[o + 1]);
    }
    uint32_t u32(size_t o) const
    {
        if (o + 4 > n) return 0;
        return le ? (uint32_t)(p[o] | p[o + 1] << 8 | p[o + 2] << 16 | (uint32_t)p[o + 3] << 24)
                  : (uint32_t)((uint32_t)p[o] << 24 | p[o + 1] << 16 | p[o + 2] << 8 | p[o + 3]);
    }
};

size_t
type_size(uint16_t type)
{
    switch (type) {
    case 1: case 2: case 6: case 7: return 1;
    case 3: case 8: return 2;
    case 4: case 9: case 11: return 4;
    case 5: case 10: case 12: return 8;
    default: return 0;
    }
}

/* An entry's values as unsigned integers (rationals as numerator/denominator). */
struct Entry {
    uint16_t type = 0;
    uint32_t count = 0;
    size_t offset = 0;   /* of the values */
    bool present = false;
};

struct IFD {
    size_t at = 0;
    uint32_t width = 0, height = 0, spp = 1, compression = 1, photometric = 1, planar = 1, predictor = 1;
    uint32_t rows_per_strip = 0xffffffff, tile_w = 0, tile_h = 0, fill_order = 1, orientation = 0;
    std::vector<uint32_t> bps, offsets, counts, extra, sample_format;
    std::vector<uint16_t> colormap;
    double xres = 0, yres = 0;
    uint32_t resunit = 2;
    const uint8_t *icc = NULL;
    size_t icc_len = 0;
    bool tiled() const { return tile_w && tile_h; }
};

uint32_t
value(const Reader &r, const Entry &e, uint32_t i)
{
    size_t o = e.offset + i * type_size(e.type);
    switch (e.type) {
    case 1: case 7: return o < r.n ? r.p[o] : 0;
    case 3: return r.u16(o);
    case 4: return r.u32(o);
    case 8: return (uint32_t)(int16_t)r.u16(o);
    case 9: return r.u32(o);
    default: return 0;
    }
}

std::vector<uint32_t>
values(const Reader &r, const Entry &e)
{
    std::vector<uint32_t> v;
    if (!e.present) return v;
    for (uint32_t i = 0; i < e.count && i < 1 << 24; i++) v.push_back(value(r, e, i));
    return v;
}

double
rational(const Reader &r, const Entry &e)
{
    if (!e.present || (e.type != 5 && e.type != 10)) return e.present ? value(r, e, 0) : 0;
    uint32_t num = r.u32(e.offset), den = r.u32(e.offset + 4);
    return den ? (double)num / den : 0;
}

/* The IFD at `at`; false if it isn't one. `next` is the following IFD's offset. */
bool
read_ifd(const Reader &r, size_t at, IFD &f, size_t *next)
{
    if (at < 8 || at + 2 > r.n) return false;
    uint16_t n = r.u16(at);
    if (at + 2 + (size_t)n * 12 + 4 > r.n) return false;
    f.at = at;
    Entry e[65536 > 0 ? 1 : 1];
    (void)e;
    Entry bps, offsets, counts, extra, sf, cmap, tiles_o, tiles_c, xres, yres;
    for (uint16_t i = 0; i < n; i++) {
        size_t o = at + 2 + (size_t)i * 12;
        Entry x;
        uint16_t tag = r.u16(o);
        x.type = r.u16(o + 2);
        x.count = r.u32(o + 4);
        size_t size = type_size(x.type) * (size_t)x.count;
        if (!type_size(x.type) || x.count > r.n) continue;
        x.offset = size <= 4 ? o + 8 : r.u32(o + 8);
        if (x.offset + size > r.n) continue;
        x.present = true;
        switch (tag) {
        case 256: f.width = value(r, x, 0); break;
        case 257: f.height = value(r, x, 0); break;
        case 258: bps = x; break;
        case 259: f.compression = value(r, x, 0); break;
        case 262: f.photometric = value(r, x, 0); break;
        case 266: f.fill_order = value(r, x, 0); break;
        case 273: offsets = x; break;
        case 274: f.orientation = value(r, x, 0); break;
        case 277: f.spp = value(r, x, 0); break;
        case 278: f.rows_per_strip = value(r, x, 0); break;
        case 279: counts = x; break;
        case 282: xres = x; break;
        case 283: yres = x; break;
        case 284: f.planar = value(r, x, 0); break;
        case 296: f.resunit = value(r, x, 0); break;
        case 317: f.predictor = value(r, x, 0); break;
        case 320: cmap = x; break;
        case 322: f.tile_w = value(r, x, 0); break;
        case 323: f.tile_h = value(r, x, 0); break;
        case 324: tiles_o = x; break;
        case 325: tiles_c = x; break;
        case 338: extra = x; break;
        case 339: sf = x; break;
        case 34675: f.icc = r.p + x.offset; f.icc_len = size; break;
        }
    }
    f.bps = values(r, bps);
    if (f.bps.empty()) f.bps.push_back(1);
    while (f.bps.size() < f.spp) f.bps.push_back(f.bps[0]);
    f.offsets = values(r, f.tiled() ? tiles_o : offsets);
    f.counts = values(r, f.tiled() ? tiles_c : counts);
    f.extra = values(r, extra);
    f.sample_format = values(r, sf);
    for (uint32_t c : values(r, cmap)) f.colormap.push_back((uint16_t)c);
    f.xres = rational(r, xres);
    f.yres = rational(r, yres);
    if (next) *next = r.u32(at + 2 + (size_t)n * 12);
    return f.width && f.height && f.width < (1u << 20) && f.height < (1u << 20);
}

/* ---- decompression --------------------------------------------------------- */

bool
unpackbits(const uint8_t *p, size_t n, std::vector<uint8_t> &out, size_t want)
{
    size_t i = 0;
    while (i < n && out.size() < want) {
        int8_t c = (int8_t)p[i++];
        if (c >= 0) {
            size_t k = (size_t)c + 1;
            if (i + k > n) k = n - i;
            out.insert(out.end(), p + i, p + i + k);
            i += k;
        } else if (c != -128) {
            if (i >= n) break;
            out.insert(out.end(), (size_t)(1 - c), p[i++]);
        }
    }
    return true;
}

/* TIFF's LZW: MSB-first codes of 9-12 bits, 256 clear, 257 end, switching width one code early. */
bool
unlzw(const uint8_t *p, size_t n, std::vector<uint8_t> &out, size_t want)
{
    struct Code { uint16_t prefix; uint8_t ch; uint16_t len; };
    std::vector<Code> table(4096);
    for (int i = 0; i < 256; i++) table[i] = {0xffff, (uint8_t)i, 1};
    size_t bit = 0;
    int width = 9, next = 258, old = -1;
    std::vector<uint8_t> buf;
    auto emit = [&](int code) {
        buf.resize(table[code].len);
        for (int c = code, k = table[code].len - 1; k >= 0; k--, c = table[c].prefix) buf[k] = table[c].ch;
        out.insert(out.end(), buf.begin(), buf.end());
    };
    while (out.size() < want && bit + width <= n * 8) {
        int code = 0;
        for (int k = 0; k < width; k++, bit++) code = code << 1 | ((p[bit >> 3] >> (7 - (bit & 7))) & 1);
        if (code == 257) break;
        if (code == 256) {
            width = 9, next = 258, old = -1;
            continue;
        }
        if (old < 0) {
            if (code > 255) return false;
            emit(code);
            old = code;
            continue;
        }
        if (code < next) {
            emit(code);
            if (next < 4096) {
                int c = code;
                while (table[c].prefix != 0xffff) c = table[c].prefix;
                table[next] = {(uint16_t)old, table[c].ch, (uint16_t)(table[old].len + 1)};
                next++;
            }
        } else if (code == next && next < 4096) {
            int c = old;
            while (table[c].prefix != 0xffff) c = table[c].prefix;
            table[next] = {(uint16_t)old, table[c].ch, (uint16_t)(table[old].len + 1)};
            next++;
            emit(code);
        } else {
            return false;
        }
        old = code;
        if (next + 1 >= (1 << width) && width < 12) width++;
    }
    return true;
}

bool
uninflate(const uint8_t *p, size_t n, std::vector<uint8_t> &out, size_t want)
{
    z_stream z = {};
    if (inflateInit(&z) != Z_OK) return false;
    size_t start = out.size();
    out.resize(start + want);
    z.next_in = (Bytef *)p;
    z.avail_in = (uInt)n;
    z.next_out = out.data() + start;
    z.avail_out = (uInt)want;
    int r = inflate(&z, Z_FINISH);
    out.resize(start + (want - z.avail_out));
    inflateEnd(&z);
    return r == Z_STREAM_END || r == Z_OK || r == Z_BUF_ERROR;
}

/* One strip or tile's bytes, decompressed to `want` bytes (short ones padded with zeros). */
bool
decompress(const IFD &f, const uint8_t *p, size_t n, size_t want, std::vector<uint8_t> &out)
{
    out.clear();
    out.reserve(want);
    bool ok;
    switch (f.compression) {
    case 1: out.assign(p, p + std::min(n, want)); ok = true; break;
    case 5: ok = unlzw(p, n, out, want); break;
    case 32773: ok = unpackbits(p, n, out, want); break;
    case 8: case 32946: ok = uninflate(p, n, out, want); break;
    default: return false;
    }
    out.resize(want, 0);
    if (f.fill_order == 2 && f.compression == 1)
        for (uint8_t &b : out) b = (uint8_t)(((b * 0x0802LU & 0x22110LU) | (b * 0x8020LU & 0x88440LU)) * 0x10101LU >> 16);
    return ok;
}

/* Undo the horizontal predictor on rows of `w` pixels of `spp` samples of `bits` bits (file byte order). */
void
unpredict(uint8_t *d, size_t rows, size_t w, size_t spp, size_t bits, bool le)
{
    size_t row_bytes = w * spp * bits / 8;
    for (size_t y = 0; y < rows; y++) {
        uint8_t *r = d + y * row_bytes;
        if (bits == 8) {
            for (size_t i = spp; i < w * spp; i++) r[i] = (uint8_t)(r[i] + r[i - spp]);
        } else if (bits == 16) {
            for (size_t i = spp; i < w * spp; i++) {
                uint8_t *a = r + i * 2, *b = r + (i - spp) * 2;
                uint16_t va = le ? (uint16_t)(a[0] | a[1] << 8) : (uint16_t)(a[0] << 8 | a[1]);
                uint16_t vb = le ? (uint16_t)(b[0] | b[1] << 8) : (uint16_t)(b[0] << 8 | b[1]);
                uint16_t v = (uint16_t)(va + vb);
                if (le) a[0] = (uint8_t)v, a[1] = (uint8_t)(v >> 8);
                else a[0] = (uint8_t)(v >> 8), a[1] = (uint8_t)v;
            }
        }
    }
}

/* ---- the image's layout --------------------------------------------------- */

enum Kind { GRAY, RGB, PALETTE, CMYK };

struct Layout {
    Kind kind = GRAY;
    size_t colors = 1;   /* colour samples per pixel */
    bool alpha = false, associated = false;
    size_t bits = 8;     /* per sample in the file */
    size_t out_bits = 8; /* per component in the image */
};

bool
layout_of(const IFD &f, Layout &l)
{
    l.bits = f.bps[0];
    for (uint32_t b : f.bps)
        if (b != l.bits) return false;
    if (!(l.bits == 1 || l.bits == 2 || l.bits == 4 || l.bits == 8 || l.bits == 16)) return false;
    if (!f.sample_format.empty() && f.sample_format[0] != 1 && f.sample_format[0] != 2) return false;
    switch (f.photometric) {
    case 0: case 1: l.kind = GRAY, l.colors = 1; break;
    case 2: l.kind = RGB, l.colors = 3; break;
    case 3: l.kind = PALETTE, l.colors = 1; break;
    case 5: l.kind = CMYK, l.colors = 4; break;
    default: return false;
    }
    if (f.spp < l.colors) return false;
    if (f.spp > l.colors) {
        uint32_t e = f.extra.empty() ? 0 : f.extra[0];
        l.alpha = e == 1 || e == 2 || (f.extra.empty() && l.kind != CMYK);
        l.associated = e == 1;
    }
    if (l.kind == PALETTE && (l.bits > 8 || f.colormap.size() < 3u << l.bits)) return false;
    l.out_bits = l.bits == 16 && l.kind != PALETTE ? 16 : 8;
    return true;
}

/* A sample of `bits` bits at index `i` of a row (file byte order), scaled to 8 or 16 bits. */
uint32_t
sample(const uint8_t *row, size_t i, size_t bits, size_t out_bits, bool le)
{
    uint32_t v;
    switch (bits) {
    case 16: v = le ? (uint32_t)(row[i * 2] | row[i * 2 + 1] << 8) : (uint32_t)(row[i * 2] << 8 | row[i * 2 + 1]); break;
    case 8: v = row[i]; break;
    default: {
        size_t bit = i * bits;
        v = (row[bit >> 3] >> (8 - bits - (bit & 7))) & ((1u << bits) - 1);
        if (out_bits == 8) v = v * 255 / ((1u << bits) - 1);
        return v;
    }
    }
    if (bits == 16 && out_bits == 8) v >>= 8;
    return v;
}

struct TIFFCodec : IIOCodec {
    std::vector<IFD> ifds;

    void parse(const uint8_t *p, size_t n, bool final) override
    {
        reset();
        ifds.clear();
        if (n < 8 || !((p[0] == 'I' && p[1] == 'I') || (p[0] == 'M' && p[1] == 'M'))) return;
        Reader r = {p, n, p[0] == 'I'};
        if (r.u16(2) != 42) return;
        size_t at = r.u32(4);
        for (int guard = 0; at && guard < 4096; guard++) {
            IFD f;
            size_t next = 0;
            if (!read_ifd(r, at, f, &next)) break;
            ifds.push_back(f);
            at = next;
        }
        count = ifds.size();
        for (size_t i = 0; i < count; i++) {
            const IFD &f = ifds[i];
            Layout l;
            bool known = layout_of(f, l);
            IIODict d;
            if (known) {
                static const char *models[] = {"Gray", "RGB", "RGB", "CMYK"};
                d.str(kCGImagePropertyColorModel, models[l.kind], strlen(models[l.kind]));
            }
            d.i64(kCGImagePropertyDepth, (int64_t)f.bps[0]);
            d.i64(kCGImagePropertyPixelWidth, f.width);
            d.i64(kCGImagePropertyPixelHeight, f.height);
            if (known && l.alpha) d.b(kCGImagePropertyHasAlpha, true);
            if (known && l.kind == PALETTE) d.b(kCGImagePropertyIsIndexed, true);
            if (f.icc) {
                CFStringRef name = IIOCopyICCDescription(f.icc, f.icc_len);
                if (name) d.set(kCGImagePropertyProfileName, name);
            }
            IIOExif e;
            IIOParseTIFFIFD(p, n, f.at, e);
            IIOAddExif(d, e, true);
            props.push_back(d.copy());
            ready.push_back(final || f.offsets.empty() || f.offsets.back() + (f.counts.empty() ? 0 : f.counts.back()) <= n);
            orientation.push_back(f.orientation ? (int)f.orientation : 1);
        }
        IIODict c;
        c.i64(kCGImagePropertyFileSize, (int64_t)n);
        container = c.copy();
    }

    bool decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out) override
    {
        if (i >= ifds.size()) return false;
        const IFD &f = ifds[i];
        Layout l;
        if (!layout_of(f, l)) return false;
        bool le = p[0] == 'I';
        size_t w = f.width, h = f.height;
        size_t planes = f.planar == 2 ? f.spp : 1, spp_chunk = f.planar == 2 ? 1 : f.spp;
        size_t cw = f.tiled() ? f.tile_w : w, ch = f.tiled() ? f.tile_h : std::min<size_t>(f.rows_per_strip ? f.rows_per_strip : h, h);
        size_t across = (w + cw - 1) / cw, down = (h + ch - 1) / ch;
        size_t chunk_row = (cw * spp_chunk * l.bits + 7) / 8;
        if (f.offsets.size() < across * down * planes) return false;
        /* the file's samples, as rows of all samples per pixel (planes merged), file bit layout */
        size_t row_samples = w * f.spp;
        std::vector<uint32_t> samples(row_samples * h, 0);
        std::vector<uint8_t> buf;
        for (size_t plane = 0; plane < planes; plane++)
            for (size_t ty = 0; ty < down; ty++)
                for (size_t tx = 0; tx < across; tx++) {
                    size_t k = (plane * down + ty) * across + tx;
                    size_t off = f.offsets[k], cnt = k < f.counts.size() ? f.counts[k] : n - off;
                    if (off >= n) continue;
                    cnt = std::min(cnt, n - off);
                    size_t rows = f.tiled() ? ch : std::min(ch, h - ty * ch);
                    if (!decompress(f, p + off, cnt, chunk_row * rows, buf)) return false;
                    if (f.predictor == 2) unpredict(buf.data(), rows, cw, spp_chunk, l.bits, le);
                    for (size_t y = 0; y < rows && ty * ch + y < h; y++) {
                        const uint8_t *row = buf.data() + y * chunk_row;
                        for (size_t x = 0; x < cw && tx * cw + x < w; x++)
                            for (size_t s = 0; s < spp_chunk; s++) {
                                size_t si = f.planar == 2 ? plane : s;
                                samples[(ty * ch + y) * row_samples + (tx * cw + x) * f.spp + si] =
                                    sample(row, x * spp_chunk + s, l.bits, l.out_bits, le);
                            }
                    }
                }
        /* to Apple's image layout */
        uint32_t maxv = l.out_bits == 16 ? 65535 : 255;
        auto put = [&](uint8_t *d, size_t idx, uint32_t v) {
            if (l.out_bits == 16) d[idx * 2] = (uint8_t)v, d[idx * 2 + 1] = (uint8_t)(v >> 8);
            else d[idx] = (uint8_t)v;
        };
        if (l.kind == GRAY) {
            size_t comps = l.alpha ? 2 : 1;
            out.alloc(w, h, l.out_bits, comps * l.out_bits);
            out.info = (l.alpha ? (l.associated ? kCGImageAlphaPremultipliedLast : kCGImageAlphaLast) : kCGImageAlphaNone) |
                       (l.out_bits == 16 ? kCGBitmapByteOrder16Little : 0);
            for (size_t y = 0; y < h; y++)
                for (size_t x = 0; x < w; x++) {
                    const uint32_t *s = &samples[y * row_samples + x * f.spp];
                    uint8_t *d = out.data.data() + y * out.bpr;
                    uint32_t g = f.photometric == 0 ? maxv - s[0] : s[0];
                    put(d, x * comps, g);
                    if (l.alpha) put(d, x * comps + 1, s[1]);
                }
            out.set_space(f.icc ? IIOSpaceFromICC(f.icc, f.icc_len, kCGColorSpaceModelMonochrome) : NULL);
            if (!out.space) out.set_space(CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2));
            return true;
        }
        if (l.kind == CMYK) {
            out.alloc(w, h, l.out_bits, 4 * l.out_bits);
            out.info = l.out_bits == 16 ? kCGBitmapByteOrder16Little : 0;
            for (size_t y = 0; y < h; y++)
                for (size_t x = 0; x < w; x++)
                    for (size_t c = 0; c < 4; c++)
                        put(out.data.data() + y * out.bpr, x * 4 + c, samples[y * row_samples + x * f.spp + c]);
            out.set_space(f.icc ? IIOSpaceFromICC(f.icc, f.icc_len, kCGColorSpaceModelCMYK) : NULL);
            if (!out.space) out.set_space(CGColorSpaceCreateWithName(kCGColorSpaceGenericCMYK));
            return true;
        }
        /* RGB and palette: RGBX, or RGBA */
        out.alloc(w, h, l.out_bits, 4 * l.out_bits);
        out.info = (l.alpha ? (l.associated ? kCGImageAlphaPremultipliedLast : kCGImageAlphaLast) : kCGImageAlphaNoneSkipLast) |
                   (l.out_bits == 16 ? kCGBitmapByteOrder16Little : 0);
        size_t entries = l.kind == PALETTE ? (size_t)1 << l.bits : 0;
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++) {
                const uint32_t *s = &samples[y * row_samples + x * f.spp];
                uint8_t *d = out.data.data() + y * out.bpr;
                uint32_t rgb[3];
                if (l.kind == PALETTE) {
                    /* the sample was scaled to 8 bits; the index is the raw value */
                    uint32_t index = l.bits == 8 ? s[0] : s[0] * ((1u << l.bits) - 1) / 255;
                    for (int c = 0; c < 3; c++) rgb[c] = f.colormap[c * entries + std::min<size_t>(index, entries - 1)] >> 8;
                } else {
                    rgb[0] = s[0], rgb[1] = s[1], rgb[2] = s[2];
                }
                for (int c = 0; c < 3; c++) put(d, x * 4 + c, rgb[c]);
                put(d, x * 4 + 3, l.alpha ? s[l.colors] : maxv);
            }
        out.set_space(f.icc ? IIOSpaceFromICC(f.icc, f.icc_len, kCGColorSpaceModelRGB) : NULL);
        if (!out.space) out.set_space(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
        return true;
    }
};

/* ---- writing ----------------------------------------------------------------- */

struct Out {
    std::vector<uint8_t> &b;
    void u8(uint8_t v) { b.push_back(v); }
    void u16(uint16_t v) { b.push_back((uint8_t)(v >> 8)), b.push_back((uint8_t)v); }
    void u32(uint32_t v) { u16((uint16_t)(v >> 16)), u16((uint16_t)v); }
    void at16(size_t o, uint16_t v) { b[o] = (uint8_t)(v >> 8), b[o + 1] = (uint8_t)v; }
    void at32(size_t o, uint32_t v) { at16(o, (uint16_t)(v >> 16)), at16(o + 2, (uint16_t)v); }
    void align() { if (b.size() & 1) b.push_back(0); }
};

/* libtiff's PackBits encoder, one row at a time. */
void
packbits_row(const uint8_t *bp, size_t cc, std::vector<uint8_t> &o)
{
    enum { BASE, LITERAL, RUN, LITERAL_RUN } state = BASE;
    size_t lastliteral = 0;
    while (cc > 0) {
        uint8_t b = *bp++;
        cc--;
        long n = 1;
        for (; cc > 0 && b == *bp; cc--, bp++) n++;
    again:
        switch (state) {
        case BASE:
            if (n > 1) {
                state = RUN;
                if (n > 128) {
                    o.push_back((uint8_t)-127), o.push_back(b);
                    n -= 128;
                    goto again;
                }
                o.push_back((uint8_t)-(n - 1)), o.push_back(b);
            } else {
                lastliteral = o.size();
                o.push_back(0), o.push_back(b);
                state = LITERAL;
            }
            break;
        case LITERAL:
            if (n > 1) {
                state = LITERAL_RUN;
                if (n > 128) {
                    o.push_back((uint8_t)-127), o.push_back(b);
                    n -= 128;
                    goto again;
                }
                o.push_back((uint8_t)-(n - 1)), o.push_back(b);
            } else {
                if (++o[lastliteral] == 127) state = BASE;
                o.push_back(b);
            }
            break;
        case RUN:
            if (n > 1) {
                if (n > 128) {
                    o.push_back((uint8_t)-127), o.push_back(b);
                    n -= 128;
                    goto again;
                }
                o.push_back((uint8_t)-(n - 1)), o.push_back(b);
            } else {
                lastliteral = o.size();
                o.push_back(0), o.push_back(b);
                state = LITERAL;
            }
            break;
        case LITERAL_RUN:
            /* a run of two after a literal joins the literal */
            if (n == 1 && o[o.size() - 2] == (uint8_t)-1 && o[lastliteral] < 126) {
                state = (o[lastliteral] += 2) == 127 ? BASE : LITERAL;
                o[o.size() - 2] = o[o.size() - 1];
            } else {
                state = RUN;
            }
            goto again;
        }
    }
}

/* libtiff's LZW encoder: clear first, 9-12 bit codes, width up when the next code passes the width's maximum,
 * cleared when the table fills or the compression ratio stops improving (checked every 10000 bytes). */
void
lzw_encode(const uint8_t *bp, size_t cc, std::vector<uint8_t> &o)
{
    enum { CLEAR = 256, EOI = 257, FIRST = 258, BITS_MIN = 9, BITS_MAX = 12, CHECK_GAP = 10000 };
    const long CODE_MAX = (1L << BITS_MAX) - 1;
    struct Hash { long hash; int code; };
    const int HSIZE = 9001, HSHIFT = 13 - 8;
    std::vector<Hash> tab(HSIZE);
    auto cl_hash = [&] { for (Hash &h : tab) h.hash = -1; };
    cl_hash();
    long nextdata = 0, nextbits = 0, outcount = 0, incount = 0, checkpoint = CHECK_GAP, ratio = 0;
    int nbits = BITS_MIN, free_ent = FIRST;
    long maxcode = (1L << BITS_MIN) - 1;
    long ent = -1;
    auto put = [&](long c) {
        nextdata = (nextdata << nbits) | c;
        nextbits += nbits;
        o.push_back((uint8_t)(nextdata >> (nextbits - 8)));
        nextbits -= 8;
        if (nextbits >= 8) {
            o.push_back((uint8_t)(nextdata >> (nextbits - 8)));
            nextbits -= 8;
        }
        outcount += nbits;
    };
    auto reset = [&] {
        cl_hash();
        ratio = 0, incount = 0, outcount = 0;
        free_ent = FIRST;
        put(CLEAR);
        nbits = BITS_MIN;
        maxcode = (1L << BITS_MIN) - 1;
    };
    if (cc > 0) {
        put(CLEAR);
        ent = *bp++;
        cc--;
        incount++;
    }
    while (cc > 0) {
        int c = *bp++;
        cc--;
        incount++;
        long fcode = ((long)c << BITS_MAX) + ent;
        int h = (int)((c << HSHIFT) ^ ent);
        if (tab[h].hash == fcode) {
            ent = tab[h].code;
            continue;
        }
        if (tab[h].hash >= 0) {
            int disp = HSIZE - h;
            if (h == 0) disp = 1;
            bool found = false;
            do {
                if ((h -= disp) < 0) h += HSIZE;
                if (tab[h].hash == fcode) {
                    ent = tab[h].code;
                    found = true;
                    break;
                }
            } while (tab[h].hash >= 0);
            if (found) continue;
        }
        put(ent);
        ent = c;
        tab[h].code = free_ent++;
        tab[h].hash = fcode;
        if (free_ent == CODE_MAX - 1) {
            reset();
        } else if (free_ent > maxcode) {
            nbits++;
            maxcode = (1L << nbits) - 1;
        } else if (incount >= checkpoint) {
            checkpoint = incount + CHECK_GAP;
            long rat;
            if (incount > 0x007fffff) {
                rat = outcount >> 8;
                rat = rat == 0 ? 0x7fffffff : incount / rat;
            } else {
                rat = (incount << 8) / outcount;
            }
            if (rat <= ratio) reset();
            else ratio = rat;
        }
    }
    if (ent != -1) {
        put(ent);
        free_ent++;
        if (free_ent == CODE_MAX - 1) {
            outcount = 0;
            put(CLEAR);
            nbits = BITS_MIN;
        } else if (free_ent > maxcode) {
            nbits++;
        }
    }
    put(EOI);
    if (nextbits > 0) o.push_back((uint8_t)((nextdata << (8 - nextbits)) & 0xff));
}

/* An image's samples as the file stores them: 8- or 16-bit (big-endian), RGB(A) or gray(A),
 * alpha associated (premultiplied) or not. */
struct Samples {
    size_t w = 0, h = 0, spp = 0, bits = 8;
    bool rgb = true, alpha = false, associated = true;
    size_t source_bpr = 0;   /* the CGImage's bytes per row (strips are sized by it, as Apple's) */
    std::vector<uint8_t> d;  /* rows, w * spp * bits / 8 bytes each */
};

bool
samples_of(CGImageRef im, Samples &s)
{
    s.w = CGImageGetWidth(im), s.h = CGImageGetHeight(im);
    s.source_bpr = CGImageGetBytesPerRow(im);
    size_t bpc = CGImageGetBitsPerComponent(im), bpp = CGImageGetBitsPerPixel(im), bpr = CGImageGetBytesPerRow(im);
    CGColorSpaceRef cs = CGImageGetColorSpace(im);
    CGBitmapInfo info = CGImageGetBitmapInfo(im);
    CGImageAlphaInfo ai = (CGImageAlphaInfo)(info & kCGBitmapAlphaInfoMask);
    uint32_t order = info & kCGBitmapByteOrderMask;
    CGColorSpaceModel model = cs ? CGColorSpaceGetModel(cs) : kCGColorSpaceModelUnknown;
    bool direct = !(info & kCGBitmapFloatComponents) && (bpc == 8 || bpc == 16) &&
                  (model == kCGColorSpaceModelRGB || model == kCGColorSpaceModelMonochrome);
    size_t colors = model == kCGColorSpaceModelRGB ? 3 : 1;
    bool has_alpha = ai != kCGImageAlphaNone && ai != kCGImageAlphaNoneSkipLast && ai != kCGImageAlphaNoneSkipFirst;
    size_t comps = colors + (ai == kCGImageAlphaNone ? 0 : 1);
    if (direct && bpp != comps * bpc) direct = false;
    if (direct && ai == kCGImageAlphaOnly) direct = false;
    if (direct) {
        CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(im));
        if (!data) return false;
        const uint8_t *p = CFDataGetBytePtr(data);
        size_t len = (size_t)CFDataGetLength(data);
        s.rgb = colors == 3, s.alpha = has_alpha, s.bits = bpc;
        s.associated = ai == kCGImageAlphaPremultipliedLast || ai == kCGImageAlphaPremultipliedFirst;
        s.spp = colors + (has_alpha ? 1 : 0);
        bool first = ai == kCGImageAlphaFirst || ai == kCGImageAlphaPremultipliedFirst || ai == kCGImageAlphaNoneSkipFirst;
        size_t bytes = bpc / 8, pixel = bpp / 8;
        bool little = bpc == 16 ? order == kCGBitmapByteOrder16Little : (order == kCGBitmapByteOrder32Little);
        s.d.resize(s.w * s.spp * bytes * s.h);
        uint8_t *o = s.d.data();
        for (size_t y = 0; y < s.h; y++) {
            if (y * bpr + s.w * pixel > len) break;
            for (size_t x = 0; x < s.w; x++) {
                const uint8_t *px = p + y * bpr + x * pixel;
                uint8_t tmp[16];
                memcpy(tmp, px, pixel);
                if (bpc == 8 && little && pixel == 4) std::reverse(tmp, tmp + 4);
                auto comp = [&](size_t i) -> uint32_t {
                    if (bpc == 8) return tmp[i];
                    return little ? (uint32_t)(tmp[2 * i] | tmp[2 * i + 1] << 8) : (uint32_t)(tmp[2 * i] << 8 | tmp[2 * i + 1]);
                };
                size_t base = first && ai != kCGImageAlphaNone ? 1 : 0;
                uint32_t v[4];
                for (size_t c = 0; c < colors; c++) v[c] = comp(base + c);
                if (has_alpha) v[colors] = comp(first ? 0 : colors);
                for (size_t c = 0; c < s.spp; c++) {
                    if (bytes == 2) *o++ = (uint8_t)(v[c] >> 8), *o++ = (uint8_t)v[c];
                    else *o++ = (uint8_t)v[c];
                }
            }
        }
        CFRelease(data);
        return true;
    }
    /* anything else: 8-bit, through the float reader, premultiplied */
    IIOFloatImage f;
    if (!IIOReadImage(im, f)) return false;
    s.rgb = f.n != 1, s.alpha = f.alpha, s.associated = true, s.bits = 8;
    s.spp = (s.rgb ? 3 : 1) + (s.alpha ? 1 : 0);
    s.d.resize(s.w * s.spp * s.h);
    uint8_t *o = s.d.data();
    for (size_t y = 0; y < s.h; y++)
        for (size_t x = 0; x < s.w; x++) {
            double *px = f.at(x, y);
            double a = px[f.n];
            double rgb[3];
            if (f.n == 4) {
                for (int c = 0; c < 3; c++) rgb[c] = (1 - px[c]) * (1 - px[3]);
            } else if (f.n == 1) {
                rgb[0] = px[0];
            } else {
                for (int c = 0; c < 3; c++) rgb[c] = px[c];
            }
            for (size_t c = 0; c < (s.rgb ? 3u : 1u); c++) *o++ = (uint8_t)lround(std::clamp(rgb[c] * (s.alpha ? a : 1), 0.0, 1.0) * 255);
            if (s.alpha) *o++ = (uint8_t)lround(std::clamp(a, 0.0, 1.0) * 255);
        }
    return true;
}

void
rational_value(Out &o, double v)
{
    if (v == floor(v) && v < 4294967295.0) {
        o.u32((uint32_t)v), o.u32(1);
    } else {
        o.u32((uint32_t)lround(v * 10000)), o.u32(10000);
    }
}

} // namespace

IIOCodec *
IIOCodecCreateTIFF()
{
    return new TIFFCodec;
}

bool
IIOEncodeTIFF(const std::vector<CGImageRef> &images, const std::vector<IIOEncodeOptions> &opts, int compression,
              std::vector<uint8_t> &out)
{
    if (images.empty()) return false;
    if (compression != 1 && compression != 5 && compression != 32773) compression = 1;
    out.clear();
    Out o = {out};
    o.u8('M'), o.u8('M'), o.u16(42), o.u32(0);
    size_t link = 4;   /* where the next IFD's offset goes */
    for (size_t i = 0; i < images.size(); i++) {
        Samples s;
        if (!samples_of(images[i], s)) return false;
        const IIOEncodeOptions &opt = i < opts.size() ? opts[i] : opts.back();
        size_t row = s.w * s.spp * s.bits / 8;
        /* as Apple's: 128 KB of the source image's rows per strip */
        size_t source_bpr = s.source_bpr ? s.source_bpr : row;
        size_t rows_per_strip = std::max<size_t>(1, std::min<size_t>(s.h, 131072 / source_bpr));
        size_t strips = (s.h + rows_per_strip - 1) / rows_per_strip;
        std::vector<uint32_t> offsets, counts;
        for (size_t k = 0; k < strips; k++) {
            size_t rows = std::min(rows_per_strip, s.h - k * rows_per_strip);
            const uint8_t *src = s.d.data() + k * rows_per_strip * row;
            std::vector<uint8_t> enc;
            if (compression == 1) {
                enc.assign(src, src + rows * row);
            } else if (compression == 32773) {
                for (size_t y = 0; y < rows; y++) packbits_row(src + y * row, row, enc);
            } else {
                /* horizontal differencing first (predictor 2), on the samples as they are stored */
                std::vector<uint8_t> diff(src, src + rows * row);
                for (size_t y = 0; y < rows; y++) {
                    uint8_t *r = diff.data() + y * row;
                    if (s.bits == 8) {
                        for (size_t x = row; x-- > s.spp;) r[x] = (uint8_t)(r[x] - r[x - s.spp]);
                    } else {
                        for (size_t x = row / 2; x-- > s.spp;) {
                            uint16_t a = (uint16_t)(r[2 * x] << 8 | r[2 * x + 1]);
                            uint16_t b = (uint16_t)(r[2 * (x - s.spp)] << 8 | r[2 * (x - s.spp) + 1]);
                            uint16_t v = (uint16_t)(a - b);
                            r[2 * x] = (uint8_t)(v >> 8), r[2 * x + 1] = (uint8_t)v;
                        }
                    }
                }
                lzw_encode(diff.data(), diff.size(), enc);
            }
            offsets.push_back((uint32_t)out.size());
            counts.push_back((uint32_t)enc.size());
            out.insert(out.end(), enc.begin(), enc.end());
        }
        o.align();
        size_t ifd = out.size();
        o.at32(link, (uint32_t)ifd);
        bool dpi = opt.dpi_x > 0 && opt.dpi_y > 0 && !(opt.dpi_x == 72 && opt.dpi_y == 72);
        uint16_t n = (uint16_t)(14 + (dpi ? 2 : 0) + (compression == 5 ? 1 : 0) + (s.alpha ? 1 : 0));
        o.u16(n);
        /* the values that don't fit in their entries, after the IFD, in Apple's order */
        size_t extra = ifd + 2 + (size_t)n * 12 + 4;
        size_t xres_at = extra, yres_at = xres_at + (dpi ? 8 : 0);
        size_t bps_at = yres_at + (dpi ? 8 : 0);
        size_t bps_size = s.spp > 2 ? s.spp * 2 : 0;
        size_t counts_at = bps_at + (bps_size + 1) / 2 * 2;
        size_t counts_size = strips > 1 ? strips * 4 : 0;
        size_t offsets_at = counts_at + counts_size;
        size_t sf_at = offsets_at + counts_size;
        auto entry = [&](uint16_t tag, uint16_t type, uint32_t count, uint32_t value) {
            o.u16(tag), o.u16(type), o.u32(count);
            if (type == 3 && count == 1) o.u16((uint16_t)value), o.u16(0);
            else if (type == 3 && count == 2) o.u16((uint16_t)value), o.u16((uint16_t)value);
            else o.u32(value);
        };
        entry(256, 3, 1, (uint32_t)s.w);
        entry(257, 3, 1, (uint32_t)s.h);
        entry(258, 3, (uint32_t)s.spp, s.spp > 2 ? (uint32_t)bps_at : (uint32_t)s.bits);
        entry(259, 3, 1, (uint32_t)compression);
        entry(262, 3, 1, s.rgb ? 2 : 1);
        entry(266, 3, 1, 1);
        entry(273, 4, (uint32_t)strips, strips > 1 ? (uint32_t)offsets_at : offsets[0]);
        entry(274, 3, 1, (uint32_t)(opt.orientation ? opt.orientation : 1));
        entry(277, 3, 1, (uint32_t)s.spp);
        entry(278, 3, 1, (uint32_t)rows_per_strip);
        entry(279, 4, (uint32_t)strips, strips > 1 ? (uint32_t)counts_at : counts[0]);
        if (dpi) {
            entry(282, 5, 1, (uint32_t)xres_at);
            entry(283, 5, 1, (uint32_t)yres_at);
        }
        entry(284, 3, 1, 1);
        entry(296, 3, 1, 2);
        if (compression == 5) entry(317, 3, 1, 2);
        if (s.alpha) entry(338, 3, 1, s.associated ? 1 : 2);
        entry(339, 3, (uint32_t)s.spp, s.spp > 2 ? (uint32_t)sf_at : 1);
        link = out.size();
        o.u32(0);
        if (dpi) {
            rational_value(o, opt.dpi_x);
            rational_value(o, opt.dpi_y);
        }
        if (s.spp > 2) {
            for (size_t c = 0; c < s.spp; c++) o.u16((uint16_t)s.bits);
            o.align();
        }
        if (strips > 1) {
            for (uint32_t c : counts) o.u32(c);
            for (uint32_t f : offsets) o.u32(f);
        }
        if (s.spp > 2)
            for (size_t c = 0; c < s.spp; c++) o.u16(1);
        o.align();
    }
    return true;
}
