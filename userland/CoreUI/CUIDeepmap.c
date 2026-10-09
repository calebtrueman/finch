/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Deepmap2: the lossless image codec actool uses for most bitmaps in compiled
 * asset catalogs (CSI compression type 11). Written from Finch's own analysis
 * of real catalogs; docs/design/ASSETS.md describes the format.
 *
 * A stream is a 12-byte header ("dmp2", encoding, flag, 10, pixel format,
 * tile width and height as u16), a palette for the palette encoding, then
 * each tile as a u32 length and its bytes, left to right, top to bottom.
 * Encodings:
 *   1 none      the pixels, untiled
 *   2 default   per-pixel alpha plane, a predictor per row, and the colour as
 *               reversible YCoCg (gray: Y) in 16-bit residuals split into a
 *               high-byte and a low-byte plane, all LZVN or LZFSE compressed
 *   3 lossless  the pixels, LZVN or LZFSE compressed
 *   4 palette   up to 256 colours and a byte per pixel (plus an alpha plane
 *               when the entries are 3 bytes), LZVN or LZFSE compressed
 * Small payloads (under 4 KiB decoded) are raw LZVN streams; larger ones are
 * LZFSE ("bvx2"). Raw LZVN is decoded by wrapping it in an LZFSE "bvxn"
 * block, which every libcompression understands.
 */
#include "CUIPrivate.h"
#include <compression.h>
#include <stdlib.h>
#include <string.h>

enum { DM_NONE = 1, DM_DEFAULT = 2, DM_LOSSLESS = 3, DM_PALETTE = 4 };

/* Bytes per pixel of the formats: gray, gray+alpha, RGB, RGBA in 8 bits and in half floats. */
static unsigned
dm_pixel_size(unsigned fmt)
{
	switch (fmt) {
	case 1: return 1;
	case 2: return 2;
	case 3: return 3;
	case 4: return 4;
	case 17: return 2;
	case 18: return 4;
	case 19: return 6;
	case 20: return 8;
	}
	return 0;
}

static bool dm_has_alpha(unsigned fmt) { return fmt == 2 || fmt == 4 || fmt == 18 || fmt == 20; }
static bool dm_is_gray(unsigned fmt) { return fmt == 1 || fmt == 2 || fmt == 17 || fmt == 18; }

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

/* Decode an LZVN (raw) or LZFSE (bvx-framed) payload of exactly n bytes. */
bool
cui_lz_decode(const uint8_t *src, size_t srclen, uint8_t *dst, size_t n)
{
	if (srclen >= 4 && src[0] == 'b' && src[1] == 'v' && src[2] == 'x')
		return compression_decode_buffer(dst, n, src, srclen, NULL, COMPRESSION_LZFSE) == n;
	/* raw LZVN: frame it as one "bvxn" block */
	uint8_t *blk = malloc(srclen + 16);
	if (!blk)
		return false;
	memcpy(blk, "bvxn", 4);
	uint32_t w = (uint32_t)n, l = (uint32_t)srclen;
	for (int i = 0; i < 4; i++)
		blk[4 + i] = (uint8_t)(w >> (8 * i)), blk[8 + i] = (uint8_t)(l >> (8 * i));
	memcpy(blk + 12, src, srclen);
	memcpy(blk + 12 + srclen, "bvx$", 4);
	/* one spare byte: a decoder that fills the buffer exactly reports n */
	uint8_t *tmp = malloc(n + 1);
	size_t got = tmp ? compression_decode_buffer(tmp, n + 1, blk, srclen + 16, NULL, COMPRESSION_LZFSE) : 0;
	if (got == n)
		memcpy(dst, tmp, n);
	free(tmp);
	free(blk);
	return got == n;
}

typedef struct {
	unsigned fmt, encoding, flag, depth;
	unsigned tile_w, tile_h;
	unsigned npal, pal_entry;
	uint8_t pal[256 * 4];
} dm_header;

/* MARK: - Default encoding */

/* The 16-bit values of one row from the high- and low-byte planes, sign in the low bit. */
static void
row_values(int16_t *out, size_t n, const uint8_t *hi, const uint8_t *lo)
{
	for (size_t i = 0; i < n; i++) {
		unsigned v = (unsigned)lo[i] | (unsigned)hi[i] << 8;
		int m = (int)(v >> 1);
		out[i] = (int16_t)((lo[i] & 1) ? -m : m);
	}
}

/* Undo the row predictor: 0 none, 1 Paeth (chosen on the first channel), 2 left, 3 up, 4 mean. */
static void
unpredict(int pred, const int16_t *res, const int16_t *prev, int16_t *out, size_t n)
{
	switch (pred) {
	case 1:
		for (size_t i = 0; i < 3 && i < n; i++)
			out[i] = (int16_t)(res[i] + prev[i]);
		for (size_t i = 3; i + 2 < n; i += 3) {
			int a = out[i - 3], b = prev[i], c = prev[i - 3];
			int pa = abs(b - c), pb = abs(a - c);
			const int16_t *src = pa > pb ? prev + i : out + i - 3;
			out[i] = (int16_t)(res[i] + (pa > pb ? b : a));
			out[i + 1] = (int16_t)(res[i + 1] + src[1]);
			out[i + 2] = (int16_t)(res[i + 2] + src[2]);
		}
		break;
	case 2:
		for (size_t i = 0; i < n; i++)
			out[i] = (int16_t)(res[i] + (i >= 3 ? out[i - 3] : 0));
		break;
	case 3:
		for (size_t i = 0; i < n; i++)
			out[i] = (int16_t)(res[i] + prev[i]);
		break;
	case 4:
		for (size_t i = 0; i < n; i++) {
			if (i < 3) {
				out[i] = (int16_t)(res[i] + prev[i]);
				continue;
			}
			int t = out[i - 3] + prev[i] + 1;
			t += (int)((unsigned)t >> 31);
			out[i] = (int16_t)(res[i] + (t >> 1));
		}
		break;
	default:
		memcpy(out, res, n * sizeof *out);
		break;
	}
}

/* Reversible YCoCg to the stored channel order; chroma is kept halved when the stream's flag is set. */
static inline void
ycocg(const int16_t *ycc, unsigned shift, int *c0, int *c1, int *c2)
{
	int y = ycc[0];
	int co = (int)((uint16_t)ycc[1]) << shift, cg = (int)((uint16_t)ycc[2]) << shift;
	int hcg = (int16_t)(cg + ((cg & 0x8000) >> 15)) >> 1;
	int t = y - hcg;
	int g = cg + t;
	int hco = (int16_t)(co + ((co & 0x8000) >> 15)) >> 1;
	int b = t - hco;
	*c0 = b + co, *c1 = g, *c2 = b;
}

static uint16_t
half(float f)
{
	_Float16 h = (_Float16)f;
	uint16_t u;
	memcpy(&u, &h, 2);
	return u;
}

static void
convert_row(const dm_header *h, const uint8_t *alpha, const int16_t *ycc, uint8_t *dst, size_t w)
{
	unsigned shift = h->flag ? 1 : 0;
	float k = 1.0f / (float)(1u << (h->depth - 1));
	for (size_t x = 0; x < w; x++, ycc += 3) {
		int c0, c1, c2;
		switch (h->fmt) {
		case 1: dst[x] = (uint8_t)ycc[0]; break;
		case 2:
			dst[2 * x] = (uint8_t)ycc[0];
			dst[2 * x + 1] = alpha[x];
			break;
		case 3:
		case 4: {
			ycocg(ycc, shift, &c0, &c1, &c2);
			uint8_t *p = dst + x * (h->fmt == 4 ? 4 : 3);
			p[0] = (uint8_t)c0, p[1] = (uint8_t)c1, p[2] = (uint8_t)c2;
			if (h->fmt == 4)
				p[3] = alpha[x];
			break;
		}
		case 17:
		case 18: {
			uint16_t *p = (uint16_t *)(dst + x * (h->fmt == 18 ? 4 : 2));
			p[0] = half((float)ycc[0] * k);
			if (h->fmt == 18) {
				float a = (float)alpha[x] * (1.0f / 255);
				p[1] = half(a >= 1 ? 1 : a);
			}
			break;
		}
		default: { /* 19, 20 */
			ycocg(ycc, shift, &c0, &c1, &c2);
			uint16_t *p = (uint16_t *)(dst + x * (h->fmt == 20 ? 8 : 6));
			p[0] = half((float)(int16_t)c0 * k);
			p[1] = half((float)(int16_t)c1 * k);
			p[2] = half((float)(int16_t)c2 * k);
			if (h->fmt == 20) {
				float a = (float)alpha[x] * (1.0f / 255);
				p[3] = half(a >= 1 ? 1 : a);
			}
			break;
		}
		}
	}
}

static bool
decode_default(const dm_header *h, const uint8_t *src, size_t len, uint8_t *dst, size_t rowbytes, size_t w, size_t hgt)
{
	size_t planes = dm_is_gray(h->fmt) ? 1 : 3;
	size_t asize = dm_has_alpha(h->fmt) ? w * hgt : 0;
	size_t raw = asize + hgt + 2 * planes * w * hgt;
	size_t rawpad = (raw + 15) & ~(size_t)15;
	uint8_t *buf = malloc(rawpad);
	int16_t *rows = calloc(3 * 3 * w + 3, sizeof(int16_t));
	bool ok = buf && rows && cui_lz_decode(src, len, buf, rawpad);
	if (ok) {
		const uint8_t *alpha = buf, *preds = buf + asize, *hi = preds + hgt, *lo = hi + planes * w * hgt;
		int16_t *prev = rows, *cur = rows + 3 * w, *res = rows + 6 * w;
		int16_t *vals = planes == 3 ? res : cur;  /* gray rows widen to Y,0,0 */
		for (size_t y = 0; y < hgt; y++) {
			memcpy(prev, cur, 3 * w * sizeof(int16_t));
			if (planes == 3)
				row_values(res, 3 * w, hi + y * 3 * w, lo + y * 3 * w);
			else {
				row_values(vals, w, hi + y * w, lo + y * w);
				for (size_t x = w; x-- > 0;)
					res[3 * x] = vals[x], res[3 * x + 1] = 0, res[3 * x + 2] = 0;
			}
			unpredict(preds[y], res, prev, cur, 3 * w);
			convert_row(h, alpha + y * w, cur, dst + y * rowbytes, w);
		}
	}
	free(buf);
	free(rows);
	return ok;
}

/* MARK: - Lossless and palette */

static bool
decode_lossless(const dm_header *h, const uint8_t *src, size_t len, uint8_t *dst, size_t rowbytes, size_t w, size_t hgt)
{
	size_t bpp = dm_pixel_size(h->fmt), n = w * hgt * bpp;
	uint8_t *buf = malloc(n ? n : 1);
	bool ok = buf && cui_lz_decode(src, len, buf, n);
	for (size_t y = 0; ok && y < hgt; y++)
		memcpy(dst + y * rowbytes, buf + y * w * bpp, w * bpp);
	free(buf);
	return ok;
}

static bool
decode_palette(const dm_header *h, const uint8_t *src, size_t len, uint8_t *dst, size_t rowbytes, size_t w, size_t hgt)
{
	size_t np = w * hgt;
	bool split = h->pal_entry == 3;            /* 3-byte entries: an alpha plane, then the indexes */
	bool wide = !split && h->npal > 256;       /* 16-bit indexes */
	size_t n = (split || wide) ? 2 * np : np;
	uint8_t *buf = malloc(n ? n : 1);
	bool ok = buf && cui_lz_decode(src, len, buf, n);
	for (size_t y = 0; ok && y < hgt; y++)
		for (size_t x = 0; x < w; x++) {
			size_t i = y * w + x;
			unsigned idx = wide ? rd16(buf + 2 * i) : split ? buf[np + i] : buf[i];
			if (!split && idx >= h->npal) {
				ok = false;
				break;
			}
			uint8_t *p = dst + y * rowbytes + 4 * x;
			memcpy(p, h->pal + 4 * (idx & 255), 4);
			if (split)
				p[3] = buf[i];
		}
	free(buf);
	return ok;
}

/* MARK: - Streams */

static size_t
read_header(dm_header *h, const uint8_t *p, size_t len)
{
	if (len < 12 || memcmp(p, "dmp2", 4) != 0)
		return 0;
	memset(h, 0, sizeof *h);
	h->encoding = p[4], h->flag = p[5], h->depth = p[6], h->fmt = p[7];
	h->tile_w = rd16(p + 8), h->tile_h = rd16(p + 10);
	if (h->depth == 0 || h->depth > 16)
		h->depth = 10;
	if (h->encoding != DM_PALETTE)
		return 12;
	if (len < 16 || h->fmt != 4)
		return 0;
	h->npal = rd16(p + 12), h->pal_entry = rd16(p + 14);
	if (h->npal > 256 || (h->pal_entry != 3 && h->pal_entry != 4) || len < 16 + 4 * (size_t)h->npal)
		return 0;
	memcpy(h->pal, p + 16, 4 * (size_t)h->npal);
	return 16 + 4 * (size_t)h->npal;
}

unsigned
cui_deepmap2_format(const uint8_t *src, size_t len)
{
	return len >= 8 && memcmp(src, "dmp2", 4) == 0 ? src[7] : 0;
}

bool
cui_deepmap2_decode(const uint8_t *src, size_t len, uint8_t *dst, size_t rowbytes, size_t width, size_t height)
{
	dm_header h;
	size_t off = read_header(&h, src, len);
	unsigned bpp = off ? dm_pixel_size(h.fmt) : 0;
	if (!bpp || h.encoding < DM_NONE || h.encoding > DM_PALETTE)
		return false;
	src += off, len -= off;
	if (h.encoding == DM_NONE) {
		if (len < width * height * bpp)
			return false;
		for (size_t y = 0; y < height; y++)
			memcpy(dst + y * rowbytes, src + y * width * bpp, width * bpp);
		return true;
	}
	if (!h.tile_w || !h.tile_h)
		return false;
	for (size_t ty = 0; ty < height; ty += h.tile_h)
		for (size_t tx = 0; tx < width; tx += h.tile_w) {
			if (len < 4)
				return false;
			size_t tl = rd32(src);
			src += 4, len -= 4;
			if (tl > len)
				return false;
			size_t tw = width - tx < h.tile_w ? width - tx : h.tile_w;
			size_t th = height - ty < h.tile_h ? height - ty : h.tile_h;
			uint8_t *d = dst + ty * rowbytes + tx * bpp;
			bool ok = h.encoding == DM_DEFAULT    ? decode_default(&h, src, tl, d, rowbytes, tw, th)
			          : h.encoding == DM_LOSSLESS ? decode_lossless(&h, src, tl, d, rowbytes, tw, th)
			                                      : decode_palette(&h, src, tl, d, rowbytes, tw, th);
			if (!ok)
				return false;
			src += tl, len -= tl;
		}
	return true;
}
