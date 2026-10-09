/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * GIF (wuffs) and WebP (libwebp) through Skia's codecs, which composite
 * animation frames over the ones before them. Properties come from Finch's
 * own reading of the containers, with Apple's keys: frame delays (clamped as
 * Apple clamps them), loop counts, canvas sizes.
 */
#include "ImageIOInternal.h"
#include "include/codec/SkCodec.h"
#include "include/codec/SkGifDecoder.h"
#include "include/codec/SkWebpDecoder.h"
#include "include/core/SkData.h"
#include "include/core/SkImageInfo.h"
#include <webp/decode.h>

namespace {

bool
skia_decode(std::unique_ptr<SkCodec> codec, size_t i, bool opaque, IIOPixels &out)
{
    if (!codec)
        return false;
    SkISize size = codec->getInfo().dimensions();
    if (size.isEmpty() || (uint64_t)size.width() * size.height() > (1u << 28))
        return false;
    int frames = codec->getFrameCount();
    if (i > 0 && (int)i >= frames)
        return false;
    out.alloc(size.width(), size.height(), 8, 32);
    out.info = opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaLast;
    SkImageInfo info = SkImageInfo::Make(size, kRGBA_8888_SkColorType, opaque ? kOpaque_SkAlphaType : kUnpremul_SkAlphaType);
    SkCodec::Options opts;
    opts.fFrameIndex = (int)i;
    SkCodec::Result r = codec->getPixels(info, out.data.data(), out.bpr, &opts);
    if (r != SkCodec::kSuccess && r != SkCodec::kIncompleteInput && r != SkCodec::kErrorInInput)
        return false;
    out.set_space(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    return true;
}

/* ---- GIF --------------------------------------------------------------------- */

struct GIFFrame {
    int delay = 0;  /* hundredths */
    bool complete = false;
};

struct GIFInfo {
    bool header = false, gct = false, netscape = false;
    int w = 0, h = 0, loops = 1;
    std::vector<GIFFrame> frames;
};

/* Skip data sub-blocks from o; returns the offset after the terminator, or 0. */
size_t
skip_blocks(const uint8_t *p, size_t n, size_t o)
{
    while (o < n) {
        size_t len = p[o];
        if (!len)
            return o + 1;
        o += 1 + len;
    }
    return 0;
}

void
gif_read(const uint8_t *p, size_t n, GIFInfo &g)
{
    if (n < 13 || memcmp(p, "GIF8", 4))
        return;
    g.header = true;
    g.w = p[6] | p[7] << 8, g.h = p[8] | p[9] << 8;
    g.gct = p[10] & 0x80;
    size_t o = 13 + (g.gct ? 3u << ((p[10] & 7) + 1) : 0);
    int delay = 0;
    while (o < n) {
        uint8_t b = p[o];
        if (b == 0x3b)
            return;
        if (b == 0x21) {
            if (o + 2 > n)
                return;
            uint8_t label = p[o + 1];
            if (label == 0xf9 && o + 8 <= n && p[o + 2] >= 4) {
                delay = p[o + 4] | p[o + 5] << 8;
            } else if (label == 0xff && o + 14 <= n && p[o + 2] == 11 && !memcmp(p + o + 3, "NETSCAPE2.0", 11)) {
                if (o + 19 <= n && p[o + 14] >= 3 && p[o + 15] == 1) {
                    g.netscape = true;
                    g.loops = p[o + 16] | p[o + 17] << 8;
                }
            }
            size_t e = skip_blocks(p, n, o + 2);
            if (!e)
                return;
            o = e;
        } else if (b == 0x2c) {
            if (o + 10 > n)
                return;
            uint8_t flags = p[o + 9];
            size_t d = o + 10 + ((flags & 0x80) ? 3u << ((flags & 7) + 1) : 0);
            GIFFrame f;
            f.delay = delay;
            delay = 0;
            g.frames.push_back(f);
            if (d + 1 > n)
                return;
            size_t e = skip_blocks(p, n, d + 1);
            if (!e)
                return;
            g.frames.back().complete = true;
            o = e;
        } else {
            return;
        }
    }
}

struct GIFCodec : IIOCodec {
    void parse(const uint8_t *p, size_t n, bool final) override
    {
        reset();
        GIFInfo g;
        gif_read(p, n, g);
        if (!g.header)
            return;
        IIODict c, gif;
        CFMutableArrayRef info = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (const GIFFrame &f : g.frames) {
            if (!final && !f.complete)
                break;
            IIODict d, fd;
            d.str(kCGImagePropertyColorModel, "RGB", 3);
            d.i64(kCGImagePropertyDepth, 8);
            d.b(kCGImagePropertyHasAlpha, true);
            d.i64(kCGImagePropertyPixelWidth, g.w);
            d.i64(kCGImagePropertyPixelHeight, g.h);
            d.str(kCGImagePropertyProfileName, "sRGB IEC61966-2.1", 17);
            IIOAddDelay(fd, f.delay / 100.0);
            CFArrayAppendValue(info, fd.d);
            d.sub(kCGImagePropertyGIFDictionary, fd);
            props.push_back(d.copy());
            ready.push_back(true);
            orientation.push_back(0);
            count++;
        }
        gif.i32(kCGImagePropertyGIFCanvasPixelHeight, g.h);
        gif.i32(kCGImagePropertyGIFCanvasPixelWidth, g.w);
        gif.set(kCGImagePropertyGIFFrameInfoArray, info);
        gif.b(kCGImagePropertyGIFHasGlobalColorMap, g.gct);
        gif.i32(kCGImagePropertyGIFLoopCount, g.loops);
        c.sub(kCGImagePropertyGIFDictionary, gif);
        container = c.copy();
    }
    bool decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out) override
    {
        SkCodec::Result r;
        return skia_decode(SkGifDecoder::Decode(SkData::MakeWithCopy(p, n), &r), i, false, out);
    }
};

/* ---- WebP -------------------------------------------------------------------- */

struct WebPCodec : IIOCodec {
    bool alpha = false;
    void parse(const uint8_t *p, size_t n, bool final) override
    {
        reset();
        WebPBitstreamFeatures f;
        if (WebPGetFeatures(p, n, &f) != VP8_STATUS_OK)
            return;
        alpha = f.has_alpha;
        IIODict c, webp;
        CFMutableArrayRef info = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        std::vector<double> delays;
        int loops = 1;
        if (f.has_animation) {
            SkCodec::Result r;
            std::unique_ptr<SkCodec> codec = SkWebpDecoder::Decode(SkData::MakeWithCopy(p, n), &r);
            if (codec) {
                for (const SkCodec::FrameInfo &fi : codec->getFrameInfo())
                    delays.push_back(fi.fDuration / 1000.0);
                int rep = codec->getRepetitionCount();
                loops = rep < 0 ? 0 : rep;
            }
        } else {
            delays.push_back(0);
        }
        for (double delay : delays) {
            IIODict d, fd;
            d.str(kCGImagePropertyColorModel, "RGB", 3);
            d.i64(kCGImagePropertyDepth, 8);
            if (f.has_alpha)
                d.b(kCGImagePropertyHasAlpha, true);
            d.i64(kCGImagePropertyPixelWidth, f.width);
            d.i64(kCGImagePropertyPixelHeight, f.height);
            IIOAddDelay(fd, delay);
            CFArrayAppendValue(info, fd.d);
            if (f.has_animation)
                d.sub(kCGImagePropertyWebPDictionary, fd);
            props.push_back(d.copy());
            ready.push_back(true);
            orientation.push_back(0);
            count++;
        }
        webp.i32(kCGImagePropertyWebPCanvasPixelHeight, f.height);
        webp.i32(kCGImagePropertyWebPCanvasPixelWidth, f.width);
        webp.set(kCGImagePropertyWebPFrameInfoArray, info);
        webp.i32(kCGImagePropertyWebPLoopCount, loops);
        c.sub(kCGImagePropertyWebPDictionary, webp);
        container = c.copy();
    }
    bool decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out) override
    {
        SkCodec::Result r;
        return skia_decode(SkWebpDecoder::Decode(SkData::MakeWithCopy(p, n), &r), i, !alpha, out);
    }
};

} // namespace

IIOCodec *
IIOCodecCreateGIF()
{
    return new GIFCodec;
}

IIOCodec *
IIOCodecCreateWebP()
{
    return new WebPCodec;
}
