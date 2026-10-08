/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's libcompression: Apple's public compression API (<compression.h>)
 * over open codecs. LZFSE is Apple's own open-source release; LZ4, Brotli,
 * zlib and liblzma are the upstream libraries.
 *
 * Formats, as <compression.h> documents them and Apple's library produces:
 *   COMPRESSION_LZ4      LZ4 blocks in Apple's frame: "bv41" (raw size,
 *                        payload size, payload), "bv4-" (raw size, bytes),
 *                        ending in "bv4$". Blocks hold 64 KiB of input and
 *                        may refer back into the previous block.
 *   COMPRESSION_LZ4_RAW  a bare LZ4 block (buffer API only).
 *   COMPRESSION_ZLIB     raw DEFLATE (RFC 1951), level 5.
 *   COMPRESSION_LZMA     an xz stream, preset 6, no integrity check.
 *   COMPRESSION_LZFSE    LZFSE's own block stream.
 *   COMPRESSION_BROTLI   Brotli, quality 2.
 * COMPRESSION_LZBITMAP is Apple's undocumented format; Finch reports it as
 * unsupported (0 from the buffer calls, an error from compression_stream_init).
 *
 * The stream state behind compression_stream.state is a struct cs. zlib,
 * liblzma and Brotli stream natively. LZ4 and LZFSE go through a pending
 * output buffer: LZ4 a block at a time; the LZFSE encoder, like Apple's,
 * takes all its input before it writes anything; the LZFSE decoder streams
 * with a sliding window over its output.
 */
#include <compression.h>
#include <errno.h>
#include <lzma.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "brotli/decode.h"
#include "brotli/encode.h"
#include "lz4.h"
#include "lzfse.h"
#include "lzfse_internal.h"

#define LZ4_BLOCK       65536
#define LZ4_MAGIC_COMP  0x31347662u     /* "bv41" */
#define LZ4_MAGIC_RAW   0x2d347662u     /* "bv4-" */
#define LZ4_MAGIC_END   0x24347662u     /* "bv4$" */
#define LZFSE_MAGIC_RAW 0x2d787662u     /* "bvx-" */
#define LZFSE_MAGIC_END 0x24787662u     /* "bvx$" */
/* Output the LZFSE decoder keeps behind its write position: more than the
 * longest LZFSE (262,139) or LZVN (65,535) match distance. */
#define LZFSE_WINDOW    (512 * 1024)

struct cs {
	compression_stream_operation op;
	compression_algorithm alg;
	bool done, failed;
	/* Accumulated input, [ipos, ilen) not yet used (LZ4, LZFSE). */
	uint8_t *in;
	size_t ipos, ilen, icap;
	/* Pending output, [opos, olen) not yet handed out (LZ4, LZFSE). */
	uint8_t *out;
	size_t opos, olen, ocap;
	union {
		z_stream z;
		lzma_stream x;
		BrotliEncoderState *be;
		BrotliDecoderState *bd;
		struct {                        /* LZ4 encoder: double-buffered blocks */
			LZ4_stream_t *ls;
			uint8_t *blocks;
			int cur;
		} lz4;
		lzfse_decoder_state *fd;
	} u;
};

static bool
grow(uint8_t **buf, size_t *cap, size_t need)
{
	if (need <= *cap)
		return true;
	size_t n = *cap ? *cap : 4096;
	while (n < need)
		n *= 2;
	uint8_t *p = realloc(*buf, n);
	if (!p)
		return false;
	*buf = p;
	*cap = n;
	return true;
}

static bool
append_in(struct cs *s, const uint8_t *p, size_t n)
{
	if (s->ipos > 0) {
		memmove(s->in, s->in + s->ipos, s->ilen - s->ipos);
		s->ilen -= s->ipos;
		s->ipos = 0;
	}
	if (!grow(&s->in, &s->icap, s->ilen + n))
		return false;
	memcpy(s->in + s->ilen, p, n);
	s->ilen += n;
	return true;
}

static bool
append_out(struct cs *s, const void *p, size_t n)
{
	if (s->opos > 0 && s->opos == s->olen)
		s->opos = s->olen = 0;
	if (!grow(&s->out, &s->ocap, s->olen + n))
		return false;
	memcpy(s->out + s->olen, p, n);
	s->olen += n;
	return true;
}

static void
drain(struct cs *s, compression_stream *st)
{
	size_t n = s->olen - s->opos;
	if (n > st->dst_size)
		n = st->dst_size;
	memcpy(st->dst_ptr, s->out + s->opos, n);
	st->dst_ptr += n;
	st->dst_size -= n;
	s->opos += n;
}

static void
put32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

static uint32_t
get32(const uint8_t *p)
{
	return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* MARK: - zlib */

static compression_status
zlib_process(struct cs *s, compression_stream *st, bool fin)
{
	z_stream *z = &s->u.z;
	z->next_in = (Bytef *)st->src_ptr;
	z->avail_in = (uInt)(st->src_size > UINT_MAX ? UINT_MAX : st->src_size);
	z->next_out = st->dst_ptr;
	z->avail_out = (uInt)(st->dst_size > UINT_MAX ? UINT_MAX : st->dst_size);
	uInt in0 = z->avail_in, out0 = z->avail_out;
	int r = s->op == COMPRESSION_STREAM_ENCODE
	    ? deflate(z, fin && z->avail_in == st->src_size ? Z_FINISH : Z_NO_FLUSH)
	    : inflate(z, Z_NO_FLUSH);
	st->src_ptr += in0 - z->avail_in;
	st->src_size -= in0 - z->avail_in;
	st->dst_ptr += out0 - z->avail_out;
	st->dst_size -= out0 - z->avail_out;
	if (r == Z_STREAM_END) {
		s->done = true;
		return COMPRESSION_STATUS_END;
	}
	if (r == Z_OK || r == Z_BUF_ERROR)
		return COMPRESSION_STATUS_OK;
	return COMPRESSION_STATUS_ERROR;
}

/* MARK: - LZMA */

static compression_status
lzma_process(struct cs *s, compression_stream *st, bool fin)
{
	lzma_stream *x = &s->u.x;
	x->next_in = st->src_ptr;
	x->avail_in = st->src_size;
	x->next_out = st->dst_ptr;
	x->avail_out = st->dst_size;
	lzma_ret r = lzma_code(x, s->op == COMPRESSION_STREAM_ENCODE && fin ? LZMA_FINISH : LZMA_RUN);
	st->src_ptr = x->next_in;
	st->src_size = x->avail_in;
	st->dst_ptr = x->next_out;
	st->dst_size = x->avail_out;
	if (r == LZMA_STREAM_END) {
		s->done = true;
		return COMPRESSION_STATUS_END;
	}
	if (r == LZMA_OK || r == LZMA_BUF_ERROR)
		return COMPRESSION_STATUS_OK;
	return COMPRESSION_STATUS_ERROR;
}

/* MARK: - Brotli */

static compression_status
brotli_process(struct cs *s, compression_stream *st, bool fin)
{
	size_t in = st->src_size, out = st->dst_size;
	const uint8_t *ip = st->src_ptr;
	uint8_t *op = st->dst_ptr;
	compression_status ret = COMPRESSION_STATUS_OK;
	if (s->op == COMPRESSION_STREAM_ENCODE) {
		if (!BrotliEncoderCompressStream(s->u.be,
		    fin ? BROTLI_OPERATION_FINISH : BROTLI_OPERATION_PROCESS, &in, &ip, &out, &op, NULL))
			ret = COMPRESSION_STATUS_ERROR;
		else if (BrotliEncoderIsFinished(s->u.be))
			ret = COMPRESSION_STATUS_END;
	} else {
		switch (BrotliDecoderDecompressStream(s->u.bd, &in, &ip, &out, &op, NULL)) {
		case BROTLI_DECODER_RESULT_SUCCESS:
			ret = COMPRESSION_STATUS_END;
			break;
		case BROTLI_DECODER_RESULT_ERROR:
			ret = COMPRESSION_STATUS_ERROR;
			break;
		default:
			break;
		}
	}
	st->src_ptr = ip;
	st->src_size = in;
	st->dst_ptr = op;
	st->dst_size = out;
	if (ret == COMPRESSION_STATUS_END)
		s->done = true;
	return ret;
}

/* MARK: - LZ4 frame */

/* Compress the block in the current half of the double buffer; the previous
 * half stays in place as the dictionary it may refer to. */
static bool
lz4_emit_block(struct cs *s, size_t n)
{
	const uint8_t *blk = s->u.lz4.blocks + (size_t)s->u.lz4.cur * LZ4_BLOCK;
	uint8_t hdr[12];
	int bound = LZ4_compressBound((int)n);
	if (!grow(&s->out, &s->ocap, s->olen + 12 + (size_t)bound))
		return false;
	int c = LZ4_compress_fast_continue(s->u.lz4.ls, (const char *)blk,
	    (char *)s->out + s->olen + 12, (int)n, bound, 1);
	if (c > 0 && (size_t)c < n) {
		put32(hdr, LZ4_MAGIC_COMP);
		put32(hdr + 4, (uint32_t)n);
		put32(hdr + 8, (uint32_t)c);
		memcpy(s->out + s->olen, hdr, 12);
		s->olen += 12 + (size_t)c;
	} else {
		put32(hdr, LZ4_MAGIC_RAW);
		put32(hdr + 4, (uint32_t)n);
		if (!append_out(s, hdr, 8) || !append_out(s, blk, n))
			return false;
	}
	s->u.lz4.cur ^= 1;
	return true;
}

static bool
lz4_encode(struct cs *s, compression_stream *st, bool fin)
{
	/* s->ilen counts the bytes in the current block. */
	while (st->src_size > 0) {
		size_t n = LZ4_BLOCK - s->ilen;
		if (n > st->src_size)
			n = st->src_size;
		memcpy(s->u.lz4.blocks + (size_t)s->u.lz4.cur * LZ4_BLOCK + s->ilen, st->src_ptr, n);
		s->ilen += n;
		st->src_ptr += n;
		st->src_size -= n;
		if (s->ilen == LZ4_BLOCK) {
			if (!lz4_emit_block(s, LZ4_BLOCK))
				return false;
			s->ilen = 0;
		}
	}
	if (fin) {
		uint8_t end[4];
		if (s->ilen > 0 && !lz4_emit_block(s, s->ilen))
			return false;
		s->ilen = 0;
		put32(end, LZ4_MAGIC_END);
		if (!append_out(s, end, 4))
			return false;
		s->done = true;
	}
	return true;
}

static bool
lz4_decode(struct cs *s, compression_stream *st)
{
	if (!append_in(s, st->src_ptr, st->src_size))
		return false;
	st->src_ptr += st->src_size;
	st->src_size = 0;
	for (;;) {
		const uint8_t *p = s->in + s->ipos;
		size_t avail = s->ilen - s->ipos;
		if (avail < 4)
			return true;
		uint32_t magic = get32(p);
		if (magic == LZ4_MAGIC_END) {
			s->ipos += 4;
			s->done = true;
			return true;
		}
		/* Keep 64 KiB of output before the block for back-references. */
		if (s->opos > 2 * LZ4_BLOCK) {
			size_t keep = s->opos - LZ4_BLOCK;
			memmove(s->out, s->out + keep, s->olen - keep);
			s->olen -= keep;
			s->opos -= keep;
		}
		if (magic == LZ4_MAGIC_RAW) {
			if (avail < 8 || avail - 8 < get32(p + 4))
				return true;
			uint32_t n = get32(p + 4);
			if (!grow(&s->out, &s->ocap, s->olen + n))
				return false;
			memcpy(s->out + s->olen, p + 8, n);
			s->olen += n;
			s->ipos += 8 + (size_t)n;
		} else if (magic == LZ4_MAGIC_COMP) {
			if (avail < 12 || avail - 12 < get32(p + 8))
				return true;
			uint32_t raw = get32(p + 4), pay = get32(p + 8);
			if (raw > INT_MAX || pay > INT_MAX || !grow(&s->out, &s->ocap, s->olen + raw))
				return false;
			size_t dict = s->olen < LZ4_BLOCK ? s->olen : LZ4_BLOCK;
			int r = LZ4_decompress_safe_usingDict((const char *)p + 12, (char *)s->out + s->olen,
			    (int)pay, (int)raw, (const char *)s->out + s->olen - dict, (int)dict);
			if (r != (int)raw)
				return false;
			s->olen += raw;
			s->ipos += 12 + (size_t)pay;
		} else {
			return false;
		}
	}
}

/* MARK: - LZFSE */

/* Raw blocks, for input LZFSE's encoder won't fit in its output buffer. */
static size_t
lzfse_store(uint8_t *dst, size_t cap, const uint8_t *src, size_t n)
{
	size_t blocks = n / UINT32_MAX + 1, need = blocks * 8 + n + 4, o = 0;
	if (need > cap)
		return 0;
	do {
		uint32_t b = n > UINT32_MAX ? UINT32_MAX : (uint32_t)n;
		put32(dst + o, LZFSE_MAGIC_RAW);
		put32(dst + o + 4, b);
		memcpy(dst + o + 8, src, b);
		o += 8 + b;
		src += b;
		n -= b;
	} while (n > 0);
	put32(dst + o, LZFSE_MAGIC_END);
	return o + 4;
}

static size_t
lzfse_encode(uint8_t *dst, size_t cap, const uint8_t *src, size_t n, void *scratch)
{
	size_t r = n ? lzfse_encode_buffer(dst, cap, src, n, scratch) : 0;
	return r ? r : lzfse_store(dst, cap, src, n);
}

static bool
lzfse_encode_stream(struct cs *s, compression_stream *st, bool fin)
{
	if (!append_in(s, st->src_ptr, st->src_size))
		return false;
	st->src_ptr += st->src_size;
	st->src_size = 0;
	if (!fin)
		return true;
	size_t cap = s->ilen + s->ilen / 64 + 1024;
	if (!grow(&s->out, &s->ocap, cap))
		return false;
	s->olen = lzfse_encode(s->out, cap, s->in, s->ilen, NULL);
	s->opos = 0;
	free(s->in);
	s->in = NULL;
	s->ilen = s->icap = 0;
	s->done = true;
	return s->olen != 0;
}

static bool
lzfse_decode_stream(struct cs *s, compression_stream *st)
{
	lzfse_decoder_state *d = s->u.fd;
	/* The decoder's pointers are into s->in and s->out, which move: keep
	 * offsets across the buffer changes. Input is compacted only between
	 * blocks; mid-block, the decoder holds offsets relative to its start. */
	size_t src_off = (size_t)(d->src - d->src_begin);
	if (d->block_magic == LZFSE_NO_BLOCK_MAGIC && src_off > 0) {
		memmove(s->in, s->in + src_off, s->ilen - src_off);
		s->ilen -= src_off;
		src_off = 0;
	}
	if (!append_in(s, st->src_ptr, st->src_size))
		return false;
	st->src_ptr += st->src_size;
	st->src_size = 0;
	for (;;) {
		if (s->opos > 2 * LZFSE_WINDOW) {
			size_t keep = s->opos - LZFSE_WINDOW;
			memmove(s->out, s->out + keep, s->olen - keep);
			s->olen -= keep;
			s->opos -= keep;
		}
		if (!grow(&s->out, &s->ocap, s->olen + LZFSE_WINDOW))
			return false;
		d->src_begin = s->in;
		d->src = s->in + src_off;
		d->src_end = s->in + s->ilen;
		d->dst_begin = s->out;
		d->dst = s->out + s->olen;
		d->dst_end = s->out + s->ocap;
		int r = lzfse_decode(d);
		src_off = (size_t)(d->src - d->src_begin);
		s->olen = (size_t)(d->dst - s->out);
		if (r == LZFSE_STATUS_OK) {
			s->done = true;
			return true;
		}
		if (r == LZFSE_STATUS_SRC_EMPTY)
			return true;
		if (r != LZFSE_STATUS_DST_FULL)
			return false;
		/* DST_FULL: the loop grows the buffer and carries on. */
		if (!grow(&s->out, &s->ocap, s->ocap * 2))
			return false;
	}
}

/* MARK: - Stream API */

compression_status
compression_stream_init(compression_stream *st, compression_stream_operation op,
    compression_algorithm alg)
{
	if (!st || (op != COMPRESSION_STREAM_ENCODE && op != COMPRESSION_STREAM_DECODE))
		return COMPRESSION_STATUS_ERROR;
	struct cs *s = calloc(1, sizeof(*s));
	if (!s)
		return COMPRESSION_STATUS_ERROR;
	s->op = op;
	s->alg = alg;
	bool enc = op == COMPRESSION_STREAM_ENCODE, ok = false;
	switch (alg) {
	case COMPRESSION_ZLIB:
		ok = (enc ? deflateInit2(&s->u.z, 5, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY)
		          : inflateInit2(&s->u.z, -15)) == Z_OK;
		break;
	case COMPRESSION_LZMA:
		s->u.x = (lzma_stream)LZMA_STREAM_INIT;
		ok = (enc ? lzma_easy_encoder(&s->u.x, 6, LZMA_CHECK_NONE)
		          : lzma_stream_decoder(&s->u.x, UINT64_MAX, 0)) == LZMA_OK;
		break;
	case COMPRESSION_BROTLI:
		if (enc) {
			s->u.be = BrotliEncoderCreateInstance(NULL, NULL, NULL);
			ok = s->u.be && BrotliEncoderSetParameter(s->u.be, BROTLI_PARAM_QUALITY, 2);
		} else {
			ok = (s->u.bd = BrotliDecoderCreateInstance(NULL, NULL, NULL)) != NULL;
		}
		break;
	case COMPRESSION_LZ4:
		if (enc) {
			s->u.lz4.ls = LZ4_createStream();
			s->u.lz4.blocks = malloc(2 * LZ4_BLOCK);
			ok = s->u.lz4.ls && s->u.lz4.blocks;
		} else {
			ok = true;
		}
		break;
	case COMPRESSION_LZFSE:
		ok = enc || (s->u.fd = calloc(1, sizeof(lzfse_decoder_state))) != NULL;
		break;
	default:
		break;
	}
	st->state = s;
	if (!ok) {
		compression_stream_destroy(st);
		return COMPRESSION_STATUS_ERROR;
	}
	return COMPRESSION_STATUS_OK;
}

compression_status
compression_stream_process(compression_stream *st, int flags)
{
	struct cs *s = st ? st->state : NULL;
	if (!s || s->failed)
		return COMPRESSION_STATUS_ERROR;
	bool fin = flags & COMPRESSION_STREAM_FINALIZE;
	compression_status r;
	switch (s->alg) {
	case COMPRESSION_ZLIB:
		r = s->done ? COMPRESSION_STATUS_END : zlib_process(s, st, fin);
		break;
	case COMPRESSION_LZMA:
		r = s->done ? COMPRESSION_STATUS_END : lzma_process(s, st, fin);
		break;
	case COMPRESSION_BROTLI:
		r = s->done ? COMPRESSION_STATUS_END : brotli_process(s, st, fin);
		break;
	default:
		drain(s, st);
		if (!s->done) {
			bool ok;
			if (s->alg == COMPRESSION_LZ4)
				ok = s->op == COMPRESSION_STREAM_ENCODE ? lz4_encode(s, st, fin) : lz4_decode(s, st);
			else
				ok = s->op == COMPRESSION_STREAM_ENCODE ? lzfse_encode_stream(s, st, fin)
				                                         : lzfse_decode_stream(s, st);
			if (!ok) {
				s->failed = true;
				return COMPRESSION_STATUS_ERROR;
			}
			drain(s, st);
		}
		r = s->done && s->opos == s->olen ? COMPRESSION_STATUS_END : COMPRESSION_STATUS_OK;
		break;
	}
	if (r == COMPRESSION_STATUS_ERROR)
		s->failed = true;
	return r;
}

compression_status
compression_stream_destroy(compression_stream *st)
{
	struct cs *s = st ? st->state : NULL;
	if (!s)
		return COMPRESSION_STATUS_ERROR;
	bool enc = s->op == COMPRESSION_STREAM_ENCODE;
	switch (s->alg) {
	case COMPRESSION_ZLIB:
		enc ? deflateEnd(&s->u.z) : inflateEnd(&s->u.z);
		break;
	case COMPRESSION_LZMA:
		lzma_end(&s->u.x);
		break;
	case COMPRESSION_BROTLI:
		if (enc && s->u.be)
			BrotliEncoderDestroyInstance(s->u.be);
		else if (!enc && s->u.bd)
			BrotliDecoderDestroyInstance(s->u.bd);
		break;
	case COMPRESSION_LZ4:
		if (enc) {
			LZ4_freeStream(s->u.lz4.ls);
			free(s->u.lz4.blocks);
		}
		break;
	case COMPRESSION_LZFSE:
		free(s->u.fd);
		break;
	default:
		break;
	}
	free(s->in);
	free(s->out);
	free(s);
	st->state = NULL;
	return COMPRESSION_STATUS_OK;
}

/* MARK: - Buffer API */

size_t
compression_encode_scratch_buffer_size(compression_algorithm alg)
{
	return alg == COMPRESSION_LZFSE ? lzfse_encode_scratch_size() : 0;
}

size_t
compression_decode_scratch_buffer_size(compression_algorithm alg)
{
	return alg == COMPRESSION_LZFSE ? lzfse_decode_scratch_size() : 0;
}

/* Run a whole buffer through a stream. Returns the bytes written, or 0 if
 * encoding didn't finish in dst_size (decoding keeps what fits). */
static size_t
buffer_via_stream(compression_stream_operation op, compression_algorithm alg,
    uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size)
{
	compression_stream st;
	if (compression_stream_init(&st, op, alg) != COMPRESSION_STATUS_OK)
		return 0;
	st.src_ptr = src;
	st.src_size = src_size;
	st.dst_ptr = dst;
	st.dst_size = dst_size;
	compression_status r;
	do {
		size_t in = st.src_size, out = st.dst_size;
		r = compression_stream_process(&st, COMPRESSION_STREAM_FINALIZE);
		if (r == COMPRESSION_STATUS_OK && in == st.src_size && out == st.dst_size)
			break;                      /* no progress: dst full, or input truncated */
	} while (r == COMPRESSION_STATUS_OK && st.dst_size > 0);
	size_t n = dst_size - st.dst_size;
	compression_stream_destroy(&st);
	/* Apple's library returns what fits of a truncated decode for LZ4 and
	 * zlib (and LZFSE, above), but 0 for LZMA and Brotli. */
	if (op == COMPRESSION_STREAM_ENCODE || alg == COMPRESSION_LZMA || alg == COMPRESSION_BROTLI)
		return r == COMPRESSION_STATUS_END ? n : 0;
	return r == COMPRESSION_STATUS_ERROR ? 0 : n;
}

size_t
compression_encode_buffer(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size,
    void *scratch, compression_algorithm alg)
{
	switch (alg) {
	case COMPRESSION_LZ4_RAW:
		if (src_size > INT_MAX || dst_size == 0)
			return 0;
		return (size_t)LZ4_compress_default((const char *)src, (char *)dst, (int)src_size,
		    dst_size > INT_MAX ? INT_MAX : (int)dst_size);
	case COMPRESSION_LZFSE:
		return lzfse_encode(dst, dst_size, src, src_size, scratch);
	default:
		return buffer_via_stream(COMPRESSION_STREAM_ENCODE, alg, dst, dst_size, src, src_size);
	}
}

size_t
compression_decode_buffer(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size,
    void *scratch, compression_algorithm alg)
{
	switch (alg) {
	case COMPRESSION_LZ4_RAW: {
		if (src_size > INT_MAX)
			return 0;
		int cap = dst_size > INT_MAX ? INT_MAX : (int)dst_size;
		int r = LZ4_decompress_safe_partial((const char *)src, (char *)dst, (int)src_size, cap, cap);
		return r < 0 ? 0 : (size_t)r;
	}
	case COMPRESSION_LZFSE:
		return lzfse_decode_buffer(dst, dst_size, src, src_size, scratch);
	default:
		return buffer_via_stream(COMPRESSION_STREAM_DECODE, alg, dst, dst_size, src, src_size);
	}
}
