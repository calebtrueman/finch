/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CSI renditions, the values of a catalog's RENDITIONS tree (little-endian):
 *
 *   0    "ISTC" (CTSI), version (1)
 *   8    rendition flags (bit 2 vector-based, bits 3-4 template rendering
 *        mode: 1 template, 2 automatic)
 *   12   width, height in pixels; scale x 100
 *   24   pixel format ('ARGB', 'GA8 ', 'RGBW', 'PDF ', 'SVG ', 'DATA', 'JPEG', 'HEIF', 0)
 *   28   colour space id (1 sRGB, 2 gray gamma 2.2, 3 Display P3, 4 extended
 *        sRGB, 5 extended linear sRGB, 6 extended gray)
 *   32   modification time, u16 layout, u16 0, name[128]
 *   168  TLV length, u32 1, u32 0, payload length
 *   184  TLVs (type, length, value), then the payload
 *
 * Payloads: "MLEC" (CELM) bitmaps, "DWAR" (RAWD) raw data (PDF, SVG, data
 * assets, JPEG/HEIF images), "RLOC" (COLR) colours. Image renditions in an
 * atlas carry no payload but an "INLK" TLV naming the atlas and the frame.
 */
#include "CUIPrivate.h"
#include <compression.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

bool
cui_csi_parse(const uint8_t *p, uint32_t len, cui_csi *c)
{
	memset(c, 0, sizeof *c);
	if (len < 184 || memcmp(p, "ISTC", 4) != 0)
		return false;
	c->version = rd32(p + 4), c->flags = rd32(p + 8);
	c->width = rd32(p + 12), c->height = rd32(p + 16), c->scale100 = rd32(p + 20);
	c->pixel_format = rd32(p + 24), c->colorspace = rd32(p + 28) & 0xff;
	c->layout = rd16(p + 36);
	memcpy(c->name, p + 40, 128);
	uint32_t tl = rd32(p + 168), dl = rd32(p + 180);
	if (tl > len - 184)
		return false;
	c->tlv = p + 184, c->tlv_len = tl;
	c->data = p + 184 + tl;
	c->data_len = dl <= len - 184 - tl ? dl : len - 184 - tl;
	return true;
}

const uint8_t *
cui_csi_tlv(const cui_csi *c, uint32_t type, uint32_t *len)
{
	for (uint32_t o = 0; o + 8 <= c->tlv_len;) {
		uint32_t t = rd32(c->tlv + o), l = rd32(c->tlv + o + 4);
		if (l > c->tlv_len - o - 8)
			break;
		if (t == type) {
			*len = l;
			return c->tlv + o + 8;
		}
		o += 8 + l;
	}
	return NULL;
}

/* MARK: - Bitmaps */

static unsigned
format_bpp(uint32_t f)
{
	switch (f) {
	case CUI_FOURCC('A', 'R', 'G', 'B'): return 4;
	case CUI_FOURCC('G', 'A', '8', ' '): return 2;
	case CUI_FOURCC('R', 'G', 'B', 'W'): return 8;
	case CUI_FOURCC('G', 'A', '1', '6'): return 4;
	}
	return 0;
}

/* Apple's run-length rows: a u32 per run, high bit set for a repeated element, low 24 bits the count. */
static bool
rle_row(const uint8_t *p, const uint8_t *end, uint8_t *dst, size_t count, unsigned esize)
{
	size_t x = 0;
	while (x < count) {
		if (end - p < 4)
			return false;
		uint32_t ctl = rd32(p);
		size_t n = ctl & 0xffffff;
		p += 4;
		if (n > count - x)
			n = count - x;
		if (ctl & 0x80000000u) {
			if ((size_t)(end - p) < esize)
				return false;
			for (size_t i = 0; i < n; i++)
				memcpy(dst + (x + i) * esize, p, esize);
			p += esize;
		} else {
			if ((size_t)(end - p) < n * esize)
				return false;
			memcpy(dst + x * esize, p, n * esize);
			p += (ctl & 0xffffff) * (size_t)esize;
		}
		x += n;
	}
	return true;
}

static bool
rle_decode(const uint8_t *src, size_t len, uint8_t *dst, size_t rowbytes, size_t rows)
{
	if (len < 12)
		return false;
	uint32_t type = rd32(src), w = rd32(src + 4), h = rd32(src + 8);
	unsigned esize = type < 3 ? 1 : type == 3 ? 2 : 4;
	size_t count = type == 6 ? 4 * (size_t)w : type == 5 ? 2 * (size_t)w : w;
	if (h < rows || 12 + 4 * (size_t)h > len || count * esize > rowbytes)
		return false;
	for (size_t y = 0; y < rows; y++) {
		uint32_t off = rd32(src + 12 + 4 * y);
		if (off >= len || !rle_row(src + off, src + len, dst + y * rowbytes, count, esize))
			return false;
	}
	return true;
}

static bool
inflate_all(const uint8_t *src, size_t len, uint8_t *dst, size_t n)
{
	z_stream z;
	memset(&z, 0, sizeof z);
	if (inflateInit2(&z, 15 + 32) != Z_OK)  /* gzip or zlib */
		return false;
	z.next_in = (Bytef *)src, z.avail_in = (uInt)len;
	z.next_out = dst, z.avail_out = (uInt)n;
	int r = inflate(&z, Z_FINISH);
	size_t got = n - z.avail_out;
	inflateEnd(&z);
	return (r == Z_STREAM_END || r == Z_OK || r == Z_BUF_ERROR) && got == n;
}

/* One block of rows, compressed as the CELM header says. */
/* Rows stored srcrow bytes apart (the rendition's row bytes) into rows rowbytes apart. */
static bool
unpad(const uint8_t *src, size_t srcrow, uint8_t *dst, size_t rowbytes, size_t rows)
{
	for (size_t y = 0; y < rows; y++)
		memmove(dst + y * rowbytes, src + y * srcrow, rowbytes);
	return true;
}

static bool
decode_block(uint32_t comp, const uint8_t *src, size_t len, uint8_t *dst, size_t rowbytes, size_t srcrow, size_t w,
             size_t rows, unsigned bpp)
{
	size_t n = srcrow * rows;
	bool ok;
	uint8_t *tmp;
	switch (comp) {
	case 0:  /* uncompressed */
		return len >= n && unpad(src, srcrow, dst, rowbytes, rows);
	case 1:  /* RLE */
		return rle_decode(src, len, dst, rowbytes, rows);
	case 2:  /* zip */
	case 3:  /* LZVN */
	case 4:  /* LZFSE */
		if (!(tmp = malloc(n ? n : 1)))
			return false;
		ok = comp == 2 ? inflate_all(src, len, tmp, n) : cui_lz_decode(src, len, tmp, n);
		if (ok)
			unpad(tmp, srcrow, dst, rowbytes, rows);
		free(tmp);
		return ok;
	case 11:  /* deepmap2, behind a 16-byte header: version, format, length, 0 */
		if (len < 16 || rd32(src) >= 2)
			return false;
		{
			size_t dl = rd32(src + 8) <= len - 16 ? rd32(src + 8) : len - 16;
			return cui_deepmap2_decode(src + 16, dl, dst, rowbytes, w, rows);
		}
	}
	return false;
}

bool
cui_csi_decode_bitmap(const cui_csi *c, cui_bitmap *out)
{
	memset(out, 0, sizeof *out);
	unsigned bpp = format_bpp(c->pixel_format);
	if (!bpp || !c->width || !c->height || c->data_len < 16 || memcmp(c->data, "MLEC", 4) != 0)
		return false;
	uint32_t flags = rd32(c->data + 4), comp = rd32(c->data + 8), length = rd32(c->data + 12);
	size_t w = c->width, h = c->height, rowbytes = w * bpp, srcrow = rowbytes;
	uint32_t tl;
	const uint8_t *t = cui_csi_tlv(c, CUI_TLV_ROWBYTES, &tl);  /* stored rows may be padded */
	if (t && tl >= 4 && rd32(t) >= rowbytes)
		srcrow = rd32(t);
	uint8_t *px = calloc(h, rowbytes);
	if (!px)
		return false;
	const uint8_t *p = c->data + 16, *end = c->data + c->data_len;
	bool ok = true;
	if (flags & 1) {  /* chunks of rows: "KCBC", 0, 0, rows, length */
		size_t y = 0;
		for (uint32_t i = 0; ok && i < length && y < h; i++) {
			if (end - p < 20 || memcmp(p, "KCBC", 4) != 0) {
				ok = false;
				break;
			}
			size_t rows = rd32(p + 12), cl = rd32(p + 16);
			if (cl > (size_t)(end - p - 20) || rows > h - y)
				ok = false;
			else
				ok = decode_block(comp, p + 20, cl, px + y * rowbytes, rowbytes, srcrow, w, rows, bpp);
			y += rows;
			p += 20 + cl;
		}
		ok = ok && y == h;
	} else {
		size_t l = length <= (size_t)(end - p) ? length : (size_t)(end - p);
		ok = decode_block(comp, p, l, px, rowbytes, srcrow, w, h, bpp);
	}
	if (!ok) {
		free(px);
		return false;
	}
	out->pixels = px, out->width = w, out->height = h, out->rowbytes = rowbytes, out->bpp = bpp;
	out->format = c->pixel_format;
	out->opaque = (flags >> 1) & 1;
	out->native = comp == 0;
	return true;
}

/* MARK: - Raw data, colours, links */

uint8_t *
cui_csi_raw_data(const cui_csi *c, size_t *len)
{
	if (c->data_len < 12 || memcmp(c->data, "DWAR", 4) != 0)
		return NULL;
	uint32_t flags = rd32(c->data + 4), l = rd32(c->data + 8);
	if (l > c->data_len - 12)
		l = c->data_len - 12;
	const uint8_t *src = c->data + 12;
	if ((flags & 1) && l >= 4 && memcmp(src, "bvx", 3) == 0) {  /* LZFSE */
		for (size_t cap = 4 * (size_t)l + 4096; cap < ((size_t)1 << 31); cap *= 4) {
			uint8_t *out = malloc(cap);
			if (!out)
				return NULL;
			size_t n = compression_decode_buffer(out, cap, src, l, NULL, COMPRESSION_LZFSE);
			if (n && n < cap) {
				*len = n;
				return out;
			}
			free(out);
			if (!n)
				return NULL;
		}
		return NULL;
	}
	uint8_t *out = malloc(l ? l : 1);
	if (out) {
		memcpy(out, src, l);
		*len = l;
	}
	return out;
}

/* "RLOC", version, colour space (u8), flags (u8: 1 = system colour name follows), 0, count, doubles[count],
 * then for a system colour: "RLOC", 1, name length, name. */
bool
cui_csi_color(const cui_csi *c, unsigned *space, double *comps, unsigned *ncomps, char *sysname, size_t sysname_len)
{
	if (c->data_len < 16 || memcmp(c->data, "RLOC", 4) != 0)
		return false;
	uint32_t n = rd32(c->data + 12);
	if (n > 8 || 16 + 8 * (size_t)n > c->data_len)
		return false;
	*space = c->data[8];
	for (uint32_t i = 0; i < n; i++)
		memcpy(&comps[i], c->data + 16 + 8 * i, 8);
	*ncomps = n;
	if (sysname_len)
		sysname[0] = 0;
	const uint8_t *t = c->data + 16 + 8 * (size_t)n;
	size_t rest = c->data_len - 16 - 8 * (size_t)n;
	if ((c->data[9] & 1) && rest >= 12 && memcmp(t, "RLOC", 4) == 0) {
		uint32_t l = rd32(t + 8);
		if (l <= rest - 12 && l < sysname_len) {
			memcpy(sysname, t + 12, l);
			sysname[l] = 0;
		}
	}
	return true;
}

/* "KLNI" (INLK), 0, the frame (x, y, width, height), u16 layout, u32 key length, (attribute, value) u16 pairs */
bool
cui_csi_link(const cui_csi *c, cui_key *key, uint32_t frame[4], unsigned *layout)
{
	uint32_t l;
	const uint8_t *p = cui_csi_tlv(c, CUI_TLV_LINK, &l);
	if (!p || l < 30 || memcmp(p, "KLNI", 4) != 0)
		return false;
	for (int i = 0; i < 4; i++)
		frame[i] = rd32(p + 8 + 4 * i);
	if (layout)
		*layout = rd16(p + 24);
	uint32_t kl = rd32(p + 26);
	if (kl > l - 30)
		kl = l - 30;
	memset(key, 0, sizeof *key);
	for (uint32_t o = 0; o + 4 <= kl; o += 4) {
		uint16_t a = rd16(p + 30 + o), v = rd16(p + 32 + o);
		if (a && a < CUI_ATTR_MAX)
			key->v[a] = v;
	}
	return true;
}

unsigned
cui_csi_image_layout(const cui_csi *c)
{
	cui_key k;
	uint32_t f[4];
	unsigned layout;
	if (c->layout == CUI_LAYOUT_INTERNAL_LINK && cui_csi_link(c, &k, f, &layout))
		return layout;
	return c->layout;
}
