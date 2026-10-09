/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Reading and writing pixels in CG's layouts: 1 to 32 bits per component,
 * integer or float (half or single), either byte order, alpha first or last.
 * Components are logical (colour components, then alpha), normalised to
 * [0, 1] for integers.
 */
#ifndef CG_PIXELS_H
#define CG_PIXELS_H

#include "CGInternal.h"
#include <math.h>
#include <string.h>

struct CGPixelLayout {
    size_t bpc, bpp, bpr, ncomp;  /* ncomp: colour components (0 for alpha-only) */
    bool fl;
    uint32_t order;               /* kCGBitmapByteOrder* */
    CGImageAlphaInfo alpha;

    static CGPixelLayout make(size_t bpc, size_t bpp, size_t bpr, size_t ncomp, CGBitmapInfo info)
    {
        CGPixelLayout l;
        l.bpc = bpc, l.bpp = bpp, l.bpr = bpr, l.ncomp = ncomp;
        l.fl = info & kCGBitmapFloatComponents;
        l.order = info & kCGBitmapByteOrderMask;
        l.alpha = (CGImageAlphaInfo)(info & kCGBitmapAlphaInfoMask);
        return l;
    }

    bool has_alpha() const
    {
        return alpha == kCGImageAlphaPremultipliedLast || alpha == kCGImageAlphaPremultipliedFirst ||
               alpha == kCGImageAlphaLast || alpha == kCGImageAlphaFirst || alpha == kCGImageAlphaOnly;
    }
    bool premultiplied() const
    {
        return alpha == kCGImageAlphaPremultipliedLast || alpha == kCGImageAlphaPremultipliedFirst;
    }
    bool alpha_first() const
    {
        return alpha == kCGImageAlphaPremultipliedFirst || alpha == kCGImageAlphaFirst ||
               alpha == kCGImageAlphaNoneSkipFirst;
    }
    bool has_slot() const { return alpha != kCGImageAlphaNone && alpha != kCGImageAlphaOnly; }

    /* Physical slot of logical component k (colour 0..ncomp-1, alpha = ncomp). */
    size_t slot(size_t k) const
    {
        if (alpha == kCGImageAlphaOnly)
            return 0;
        if (!has_slot())
            return k;
        if (alpha_first())
            return k == ncomp ? 0 : k + 1;
        return k;
    }

    bool little() const { return order == kCGBitmapByteOrder16Little || order == kCGBitmapByteOrder32Little; }

    /* bpc 5: a 16-bit pixel, 1 bit of padding (first or last) and 5 bits per colour */
    unsigned get16(const uint8_t *p) const { return little() ? (unsigned)(p[0] | p[1] << 8) : (unsigned)(p[0] << 8 | p[1]); }
    void put16(uint8_t *p, unsigned v) const
    {
        if (little())
            p[0] = (uint8_t)v, p[1] = (uint8_t)(v >> 8);
        else
            p[0] = (uint8_t)(v >> 8), p[1] = (uint8_t)v;
    }

    /* Byte offset of a physical slot of 8-bit components, after byte-order swapping of the pixel. */
    size_t byte_index(size_t s) const
    {
        size_t pixel_bytes = bpp / 8;
        if ((order == kCGBitmapByteOrder32Little && pixel_bytes == 4) ||
            (order == kCGBitmapByteOrder16Little && pixel_bytes == 2))
            return pixel_bytes - 1 - s;
        return s;
    }

    double get(const uint8_t *row, size_t x, size_t k) const
    {
        size_t s = slot(k);
        if (bpc < 5) {
            size_t bit = x * bpp + s * bpc;
            unsigned v = 0;
            for (size_t i = 0; i < bpc; i++, bit++)
                v = v << 1 | ((row[bit / 8] >> (7 - bit % 8)) & 1);
            return v / (double)((1u << bpc) - 1);
        }
        if (bpc == 5) {
            unsigned v = get16(row + 2 * x);
            if (k == ncomp)
                return 1;
            int shift = (alpha_first() ? 10 : 11) - 5 * (int)k;
            return ((v >> shift) & 31) / 31.0;
        }
        size_t bytes = bpc / 8;
        const uint8_t *c = row + x * (bpp / 8) + (bytes == 1 ? byte_index(s) : s * bytes);
        switch (bytes) {
        case 1:
            return c[0] / 255.0;
        case 2: {
            uint16_t v = little() ? (uint16_t)(c[0] | c[1] << 8) : (uint16_t)(c[0] << 8 | c[1]);
            if (!fl)
                return v / 65535.0;
            int e = (v >> 10) & 31, m = v & 1023;
            double f = e == 0 ? ldexp(m, -24) : e == 31 ? (m ? NAN : INFINITY) : ldexp(m + 1024, e - 25);
            return v & 0x8000 ? -f : f;
        }
        case 4: {
            uint32_t v = little() ? (uint32_t)(c[0] | c[1] << 8 | c[2] << 16 | (uint32_t)c[3] << 24)
                                  : ((uint32_t)c[0] << 24 | (uint32_t)c[1] << 16 | (uint32_t)c[2] << 8 | c[3]);
            if (fl) {
                float f;
                memcpy(&f, &v, 4);
                return f;
            }
            return v / 4294967295.0;
        }
        }
        return 0;
    }

    void set(uint8_t *row, size_t x, size_t k, double v) const
    {
        size_t s = slot(k);
        if (bpc < 5) {
            unsigned max = (1u << bpc) - 1, q = (unsigned)lround(fmin(1, fmax(0, v)) * max);
            size_t bit = x * bpp + s * bpc;
            for (size_t i = 0; i < bpc; i++, bit++) {
                unsigned b = (q >> (bpc - 1 - i)) & 1;
                row[bit / 8] = (uint8_t)((row[bit / 8] & ~(1 << (7 - bit % 8))) | b << (7 - bit % 8));
            }
            return;
        }
        if (bpc == 5) {
            if (k == ncomp)
                return;
            uint8_t *p = row + 2 * x;
            unsigned w = get16(p);
            int shift = (alpha_first() ? 10 : 11) - 5 * (int)k;
            unsigned q = (unsigned)lround(fmin(1, fmax(0, v)) * 31);
            w = (w & ~(31u << shift)) | q << shift;
            put16(p, w);
            return;
        }
        size_t bytes = bpc / 8;
        uint8_t *c = row + x * (bpp / 8) + (bytes == 1 ? byte_index(s) : s * bytes);
        switch (bytes) {
        case 1:
            c[0] = (uint8_t)lround(fmin(1, fmax(0, v)) * 255);
            return;
        case 2: {
            uint16_t q;
            if (fl) {
                /* float to half */
                float f = (float)v;
                uint32_t b;
                memcpy(&b, &f, 4);
                uint32_t sign = (b >> 16) & 0x8000;
                int e = (int)((b >> 23) & 255) - 127 + 15;
                uint32_t m = b & 0x7fffff;
                if (((b >> 23) & 255) == 255)
                    q = (uint16_t)(sign | 0x7c00 | (m ? 0x200 : 0));
                else if (e >= 31)
                    q = (uint16_t)(sign | 0x7c00);
                else if (e <= 0)
                    q = e < -10 ? (uint16_t)sign : (uint16_t)(sign | ((m | 0x800000) >> (14 - e)));
                else
                    q = (uint16_t)(sign | (uint32_t)e << 10 | m >> 13);
            } else {
                q = (uint16_t)lround(fmin(1, fmax(0, v)) * 65535);
            }
            if (little())
                c[0] = (uint8_t)q, c[1] = (uint8_t)(q >> 8);
            else
                c[0] = (uint8_t)(q >> 8), c[1] = (uint8_t)q;
            return;
        }
        case 4: {
            uint32_t q;
            if (fl) {
                float f = (float)v;
                memcpy(&q, &f, 4);
            } else {
                q = (uint32_t)llround(fmin(1, fmax(0, v)) * 4294967295.0);
            }
            if (little())
                c[0] = (uint8_t)q, c[1] = (uint8_t)(q >> 8), c[2] = (uint8_t)(q >> 16), c[3] = (uint8_t)(q >> 24);
            else
                c[0] = (uint8_t)(q >> 24), c[1] = (uint8_t)(q >> 16), c[2] = (uint8_t)(q >> 8), c[3] = (uint8_t)q;
            return;
        }
        }
    }
};

#endif
