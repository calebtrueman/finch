/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Minimal <corecrypto/ccsha2.h> for Finch: the ccdigest SHA-256 subset that
 * libSystem components use (e.g. libmalloc derives allocator randomisation
 * with it). It isn't Apple's corecrypto, which is closed. This is a
 * self-contained, header-only SHA-256 per FIPS 180-4, so users don't link
 * libcorecrypto at all.
 *
 * Supported: CCSHA256_OUTPUT_SIZE, ccsha256_di(), ccdigest_di_decl(),
 * ccdigest_init(), ccdigest_update(), ccdigest_final(), ccdigest_di_clear().
 */

#ifndef _FINCH_CORECRYPTO_CCSHA2_H_
#define _FINCH_CORECRYPTO_CCSHA2_H_

#include <stddef.h>
#include <stdint.h>

#define CCSHA256_OUTPUT_SIZE 32
#define CCSHA256_BLOCK_SIZE  64

struct ccdigest_info {
	size_t output_size;
	size_t block_size;
};

struct _finch_sha256_ctx {
	uint32_t h[8];
	uint64_t total;                         /* bytes hashed so far */
	uint8_t  block[CCSHA256_BLOCK_SIZE];
	size_t   used;                          /* bytes buffered in block */
};

static inline const struct ccdigest_info *
ccsha256_di(void)
{
	static const struct ccdigest_info info = { CCSHA256_OUTPUT_SIZE, CCSHA256_BLOCK_SIZE };
	return &info;
}

#define _FINCH_ROR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static inline void
_finch_sha256_compress(uint32_t h[8], const uint8_t blk[CCSHA256_BLOCK_SIZE])
{
	static const uint32_t k[64] = {
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
	};
	uint32_t w[64], a, b, c, d, e, f, g, hh, t1, t2;
	int i;

	for (i = 0; i < 16; i++) {
		w[i] = (uint32_t)blk[4 * i] << 24 | (uint32_t)blk[4 * i + 1] << 16 |
		    (uint32_t)blk[4 * i + 2] << 8 | blk[4 * i + 3];
	}
	for (i = 16; i < 64; i++) {
		uint32_t s0 = _FINCH_ROR32(w[i - 15], 7) ^ _FINCH_ROR32(w[i - 15], 18) ^ (w[i - 15] >> 3);
		uint32_t s1 = _FINCH_ROR32(w[i - 2], 17) ^ _FINCH_ROR32(w[i - 2], 19) ^ (w[i - 2] >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; hh = h[7];
	for (i = 0; i < 64; i++) {
		t1 = hh + (_FINCH_ROR32(e, 6) ^ _FINCH_ROR32(e, 11) ^ _FINCH_ROR32(e, 25)) +
		    ((e & f) ^ (~e & g)) + k[i] + w[i];
		t2 = (_FINCH_ROR32(a, 2) ^ _FINCH_ROR32(a, 13) ^ _FINCH_ROR32(a, 22)) +
		    ((a & b) ^ (a & c) ^ (b & c));
		hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static inline void
_finch_sha256_init(struct _finch_sha256_ctx *ctx)
{
	static const uint32_t iv[8] = {
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
		0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
	};
	for (int i = 0; i < 8; i++) {
		ctx->h[i] = iv[i];
	}
	ctx->total = 0;
	ctx->used = 0;
}

static inline void
_finch_sha256_update(struct _finch_sha256_ctx *ctx, size_t len, const void *data)
{
	const uint8_t *p = (const uint8_t *)data;

	ctx->total += len;
	while (len > 0) {
		size_t take = CCSHA256_BLOCK_SIZE - ctx->used;
		if (take > len) {
			take = len;
		}
		for (size_t i = 0; i < take; i++) {
			ctx->block[ctx->used + i] = p[i];
		}
		ctx->used += take;
		p += take;
		len -= take;
		if (ctx->used == CCSHA256_BLOCK_SIZE) {
			_finch_sha256_compress(ctx->h, ctx->block);
			ctx->used = 0;
		}
	}
}

static inline void
_finch_sha256_final(struct _finch_sha256_ctx *ctx, void *out)
{
	uint64_t bits = ctx->total * 8;
	uint8_t *o = (uint8_t *)out;
	uint8_t pad = 0x80, zero = 0, len_be[8];

	_finch_sha256_update(ctx, 1, &pad);
	while (ctx->used != CCSHA256_BLOCK_SIZE - 8) {
		_finch_sha256_update(ctx, 1, &zero);
	}
	for (int i = 0; i < 8; i++) {
		len_be[i] = (uint8_t)(bits >> (56 - 8 * i));
	}
	_finch_sha256_update(ctx, 8, len_be);
	for (int i = 0; i < 8; i++) {
		o[4 * i] = (uint8_t)(ctx->h[i] >> 24);
		o[4 * i + 1] = (uint8_t)(ctx->h[i] >> 16);
		o[4 * i + 2] = (uint8_t)(ctx->h[i] >> 8);
		o[4 * i + 3] = (uint8_t)ctx->h[i];
	}
}

static inline void
_finch_sha256_clear(struct _finch_sha256_ctx *ctx)
{
	volatile uint8_t *p = (volatile uint8_t *)ctx;
	for (size_t i = 0; i < sizeof(*ctx); i++) {
		p[i] = 0;
	}
}

/* ccdigest API (SHA-256 is the only digest provided). */
#define ccdigest_di_decl(_di, _name)            struct _finch_sha256_ctx _name[1]
#define ccdigest_init(_di, _ctx)                _finch_sha256_init(_ctx)
#define ccdigest_update(_di, _ctx, _len, _data) _finch_sha256_update((_ctx), (_len), (_data))
#define ccdigest_final(_di, _ctx, _out)         _finch_sha256_final((_ctx), (_out))
#define ccdigest_di_clear(_di, _ctx)            _finch_sha256_clear(_ctx)

#endif /* _FINCH_CORECRYPTO_CCSHA2_H_ */
