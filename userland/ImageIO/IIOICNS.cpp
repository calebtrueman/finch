/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ICNS (com.apple.icns), Mac app icons: an "icns" header, then typed
 * entries. As Apple's ImageIO reads them, each entry Finch can decode is an
 * image, largest first: PNG entries (ic07-ic14, icp4-icp6, the @2x types at
 * 144 dpi) through the PNG decoder, and the run-length-encoded ARGB entries
 * (ic04, ic05). Each image's properties name its type
 * (kCGImagePropertyICNSIndexSelector); the file's list them under
 * {FileContents}. JPEG 2000 and the old pre-10.7 entries are left out.
 */
#include "ImageIOInternal.h"

#include <algorithm>
#include <string.h>

namespace {

struct Kind {
    char type[5];
    size_t pixels;
    int dpi;
};

const Kind kinds[] = {
    {"icp4", 16, 72},   {"icp5", 32, 72},   {"icp6", 64, 72},   {"ic07", 128, 72}, {"ic08", 256, 72},
    {"ic09", 512, 72},  {"ic10", 1024, 144}, {"ic11", 32, 144},  {"ic12", 64, 144}, {"ic13", 256, 144},
    {"ic14", 512, 144}, {"ic04", 16, 72},   {"ic05", 32, 72},
};

struct Icon {
    char type[5];
    size_t pixels, offset, size;
    int dpi;
    bool png;
};

const uint8_t png_sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};

uint32_t
be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* ARGB entries: "ARGB", then each channel (A, R, G, B) run-length encoded: a byte under 0x80 copies
 * that many plus one bytes, one from 0x80 repeats the next byte that many minus 0x80 plus three times. */
bool
decode_argb(const uint8_t *d, size_t n, size_t w, IIOPixels &out)
{
    if (n < 4 || memcmp(d, "ARGB", 4))
        return false;
    size_t total = w * w;
    std::vector<uint8_t> ch(4 * total);
    size_t i = 4, o = 0;
    while (o < ch.size() && i < n) {
        uint8_t c = d[i++];
        if (c < 0x80) {
            size_t run = (size_t)c + 1;
            if (i + run > n || o + run > ch.size())
                return false;
            memcpy(&ch[o], d + i, run);
            i += run, o += run;
        } else {
            size_t run = (size_t)c - 0x80 + 3;
            if (i >= n || o + run > ch.size())
                return false;
            memset(&ch[o], d[i++], run);
            o += run;
        }
    }
    if (o != ch.size())
        return false;
    out.alloc(w, w, 8, 32);
    out.info = kCGImageAlphaLast | kCGBitmapByteOrderDefault;
    out.set_space(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    for (size_t k = 0; k < total; k++) {
        uint8_t *px = &out.data[k * 4];
        px[0] = ch[total + k];
        px[1] = ch[2 * total + k];
        px[2] = ch[3 * total + k];
        px[3] = ch[k];
    }
    return true;
}

CFStringRef
cf(const char *s)
{
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingASCII);
}

struct ICNSCodec : IIOCodec {
    std::vector<Icon> icons;

    void parse(const uint8_t *p, size_t n, bool final) override
    {
        reset();
        icons.clear();
        if (n < 8 || memcmp(p, "icns", 4))
            return;
        size_t end = std::min((size_t)be32(p + 4), n);
        for (size_t off = 8; off + 8 <= end;) {
            size_t len = be32(p + off + 4);
            if (len < 8)
                break;
            for (const Kind &k : kinds)
                if (!memcmp(p + off, k.type, 4) && off + len <= n) {
                    Icon ic;
                    memcpy(ic.type, k.type, 5);
                    ic.pixels = k.pixels, ic.dpi = k.dpi, ic.offset = off + 8, ic.size = len - 8;
                    ic.png = ic.size >= 8 && !memcmp(p + ic.offset, png_sig, 8);
                    if (ic.png || !memcmp(p + ic.offset, "ARGB", 4))
                        icons.push_back(ic);
                }
            off += len;
        }
        std::stable_sort(icons.begin(), icons.end(), [](const Icon &a, const Icon &b) { return a.pixels > b.pixels; });
        CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (const Icon &ic : icons) {
            IIODict d;
            if (ic.png) {
                bool r;
                int o;
                CFDictionaryRef pp = IIOPNGCopyProperties(p + ic.offset, ic.size, &r, &o);
                if (pp) {
                    CFDictionaryApplyFunction(pp, [](const void *k, const void *v, void *ctx) {
                        CFDictionarySetValue((CFMutableDictionaryRef)ctx, k, v);
                    }, d.d);
                    CFRelease(pp);
                }
            } else {
                d.set(kCGImagePropertyColorModel, CFRetain(kCGImagePropertyColorModelRGB));
                d.i32(kCGImagePropertyDepth, 8);
                d.b(kCGImagePropertyHasAlpha, true);
                d.i32(kCGImagePropertyPixelWidth, (int32_t)ic.pixels);
                d.i32(kCGImagePropertyPixelHeight, (int32_t)ic.pixels);
                d.set(kCGImagePropertyProfileName, cf("sRGB IEC61966-2.1"));
            }
            d.i32(kCGImagePropertyDPIWidth, ic.dpi);
            d.i32(kCGImagePropertyDPIHeight, ic.dpi);
            d.set(CFSTR("kCGImagePropertyICNSIndexSelector"), cf(ic.type));
            count++;
            ready.push_back(true);
            props.push_back(d.copy());
            orientation.push_back(0);
            IIODict entry;
            entry.i32(kCGImagePropertyDPIHeight, ic.dpi);
            entry.i32(kCGImagePropertyDPIWidth, ic.dpi);
            entry.set(CFSTR("IconType"), cf(ic.type));
            entry.i32(kCGImagePropertyPixelHeight, (int32_t)ic.pixels);
            entry.i32(kCGImagePropertyPixelWidth, (int32_t)ic.pixels);
            CFDictionaryRef e = entry.copy();
            CFArrayAppendValue(list, e);
            CFRelease(e);
        }
        IIODict contents, c;
        contents.i32(CFSTR("ImageCount"), (int32_t)icons.size());
        contents.set(CFSTR("Images"), list);
        c.sub(CFSTR("{FileContents}"), contents);
        container = c.copy();
        (void)final;
    }

    bool decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out) override
    {
        if (i >= icons.size())
            return false;
        const Icon &ic = icons[i];
        if (ic.offset + ic.size > n)
            return false;
        if (ic.png)
            return IIOPNGDecode(p + ic.offset, ic.size, out);
        return decode_argb(p + ic.offset, ic.size, ic.pixels, out);
    }
};

} // namespace

IIOCodec *
IIOCodecCreateICNS()
{
    return new ICNSCodec;
}
