/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * SHA-1, SHA-224/256 and SHA-384/512 (FIPS 180-4) behind Finch's
 * corecrypto digest interface. No libSystem dependencies: dyld links this
 * statically.
 */

#include <corecrypto/ccdigest.h>
#include <corecrypto/ccsha1.h>
#include <corecrypto/ccsha2.h>

#define ROTL32(x, n) (((x) << (n)) | ((x) >> (32 - (n))))
#define ROTR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define ROTR64(x, n) (((x) >> (n)) | ((x) << (64 - (n))))

static void zero(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}

static uint32_t be32(const unsigned char *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint64_t be64(const unsigned char *p)
{
	return (uint64_t)be32(p) << 32 | be32(p + 4);
}

static void put32(unsigned char *p, uint32_t v)
{
	p[0] = (unsigned char)(v >> 24);
	p[1] = (unsigned char)(v >> 16);
	p[2] = (unsigned char)(v >> 8);
	p[3] = (unsigned char)v;
}

static void put64(unsigned char *p, uint64_t v)
{
	put32(p, (uint32_t)(v >> 32));
	put32(p + 4, (uint32_t)v);
}

/* ---- 32-bit-word family: SHA-1, SHA-224, SHA-256 (64-byte blocks) ---- */

struct state32 {
	uint32_t h[8];
	uint64_t length;            /* bytes hashed */
	unsigned char block[64];
	size_t used;
};

static void sha1_compress(uint32_t h[8], const unsigned char *block)
{
	uint32_t w[80];
	for (int i = 0; i < 16; i++)
		w[i] = be32(block + 4 * i);
	for (int i = 16; i < 80; i++)
		w[i] = ROTL32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
	uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
	for (int i = 0; i < 80; i++) {
		uint32_t f, k;
		if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
		else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
		else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
		else { f = b ^ c ^ d; k = 0xca62c1d6; }
		uint32_t t = ROTL32(a, 5) + f + e + k + w[i];
		e = d; d = c; c = ROTL32(b, 30); b = a; a = t;
	}
	h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

static const uint32_t K256[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static void sha256_compress(uint32_t h[8], const unsigned char *block)
{
	uint32_t w[64];
	for (int i = 0; i < 16; i++)
		w[i] = be32(block + 4 * i);
	for (int i = 16; i < 64; i++) {
		uint32_t s0 = ROTR32(w[i - 15], 7) ^ ROTR32(w[i - 15], 18) ^ (w[i - 15] >> 3);
		uint32_t s1 = ROTR32(w[i - 2], 17) ^ ROTR32(w[i - 2], 19) ^ (w[i - 2] >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
	for (int i = 0; i < 64; i++) {
		uint32_t S1 = ROTR32(e, 6) ^ ROTR32(e, 11) ^ ROTR32(e, 25);
		uint32_t ch = (e & f) ^ (~e & g);
		uint32_t t1 = hh + S1 + ch + K256[i] + w[i];
		uint32_t S0 = ROTR32(a, 2) ^ ROTR32(a, 13) ^ ROTR32(a, 22);
		uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
		uint32_t t2 = S0 + maj;
		hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static void update32(struct state32 *s, size_t len, const void *data,
    void (*compress)(uint32_t[8], const unsigned char *))
{
	const unsigned char *p = data;
	s->length += len;
	while (len > 0) {
		if (s->used == 0 && len >= 64) {
			compress(s->h, p);
			p += 64;
			len -= 64;
			continue;
		}
		size_t n = 64 - s->used;
		if (n > len)
			n = len;
		for (size_t i = 0; i < n; i++)
			s->block[s->used + i] = p[i];
		s->used += n;
		p += n;
		len -= n;
		if (s->used == 64) {
			compress(s->h, s->block);
			s->used = 0;
		}
	}
}

static void final32(struct state32 *s, unsigned char *out, int words,
    void (*compress)(uint32_t[8], const unsigned char *))
{
	uint64_t bits = s->length * 8;
	s->block[s->used++] = 0x80;
	if (s->used > 56) {
		while (s->used < 64)
			s->block[s->used++] = 0;
		compress(s->h, s->block);
		s->used = 0;
	}
	while (s->used < 56)
		s->block[s->used++] = 0;
	put64(s->block + 56, bits);
	compress(s->h, s->block);
	for (int i = 0; i < words; i++)
		put32(out + 4 * i, s->h[i]);
}

static void sha1_init(void *st)
{
	struct state32 *s = st;
	static const uint32_t iv[5] = { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 };
	zero(s, sizeof(*s));
	for (int i = 0; i < 5; i++)
		s->h[i] = iv[i];
}
static void sha1_update(void *st, size_t len, const void *d) { update32(st, len, d, sha1_compress); }
static void sha1_final(void *st, unsigned char *out) { final32(st, out, 5, sha1_compress); }

static void sha224_init(void *st)
{
	struct state32 *s = st;
	static const uint32_t iv[8] = { 0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939,
	                                0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4 };
	zero(s, sizeof(*s));
	for (int i = 0; i < 8; i++)
		s->h[i] = iv[i];
}
static void sha256_init(void *st)
{
	struct state32 *s = st;
	static const uint32_t iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	                                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
	zero(s, sizeof(*s));
	for (int i = 0; i < 8; i++)
		s->h[i] = iv[i];
}
static void sha256_update(void *st, size_t len, const void *d) { update32(st, len, d, sha256_compress); }
static void sha224_final(void *st, unsigned char *out) { final32(st, out, 7, sha256_compress); }
static void sha256_final(void *st, unsigned char *out) { final32(st, out, 8, sha256_compress); }

/* ---- 64-bit-word family: SHA-384, SHA-512 (128-byte blocks) ---- */

struct state64 {
	uint64_t h[8];
	uint64_t length;            /* bytes hashed (< 2^64 is plenty) */
	unsigned char block[128];
	size_t used;
};

static const uint64_t K512[80] = {
	0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
	0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL, 0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
	0xd807aa98a3030242ULL, 0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
	0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
	0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL, 0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
	0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
	0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
	0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL, 0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
	0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
	0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
	0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL, 0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
	0xd192e819d6ef5218ULL, 0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
	0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
	0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL, 0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
	0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
	0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
	0xca273eceea26619cULL, 0xd186b8c721c0c207ULL, 0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
	0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
	0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
	0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL, 0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL,
};

static void sha512_compress(uint64_t h[8], const unsigned char *block)
{
	uint64_t w[80];
	for (int i = 0; i < 16; i++)
		w[i] = be64(block + 8 * i);
	for (int i = 16; i < 80; i++) {
		uint64_t s0 = ROTR64(w[i - 15], 1) ^ ROTR64(w[i - 15], 8) ^ (w[i - 15] >> 7);
		uint64_t s1 = ROTR64(w[i - 2], 19) ^ ROTR64(w[i - 2], 61) ^ (w[i - 2] >> 6);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	uint64_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
	for (int i = 0; i < 80; i++) {
		uint64_t S1 = ROTR64(e, 14) ^ ROTR64(e, 18) ^ ROTR64(e, 41);
		uint64_t ch = (e & f) ^ (~e & g);
		uint64_t t1 = hh + S1 + ch + K512[i] + w[i];
		uint64_t S0 = ROTR64(a, 28) ^ ROTR64(a, 34) ^ ROTR64(a, 39);
		uint64_t maj = (a & b) ^ (a & c) ^ (b & c);
		uint64_t t2 = S0 + maj;
		hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static void sha512_update(void *st, size_t len, const void *data)
{
	struct state64 *s = st;
	const unsigned char *p = data;
	s->length += len;
	while (len > 0) {
		if (s->used == 0 && len >= 128) {
			sha512_compress(s->h, p);
			p += 128;
			len -= 128;
			continue;
		}
		size_t n = 128 - s->used;
		if (n > len)
			n = len;
		for (size_t i = 0; i < n; i++)
			s->block[s->used + i] = p[i];
		s->used += n;
		p += n;
		len -= n;
		if (s->used == 128) {
			sha512_compress(s->h, s->block);
			s->used = 0;
		}
	}
}

static void final64(struct state64 *s, unsigned char *out, int words)
{
	uint64_t bits = s->length * 8;
	s->block[s->used++] = 0x80;
	if (s->used > 112) {
		while (s->used < 128)
			s->block[s->used++] = 0;
		sha512_compress(s->h, s->block);
		s->used = 0;
	}
	while (s->used < 112)
		s->block[s->used++] = 0;
	put64(s->block + 112, s->length >> 61);   /* high 64 bits of the 128-bit bit count */
	put64(s->block + 120, bits);
	sha512_compress(s->h, s->block);
	for (int i = 0; i < words; i++)
		put64(out + 8 * i, s->h[i]);
}

static void sha384_init(void *st)
{
	struct state64 *s = st;
	static const uint64_t iv[8] = {
		0xcbbb9d5dc1059ed8ULL, 0x629a292a367cd507ULL, 0x9159015a3070dd17ULL, 0x152fecd8f70e5939ULL,
		0x67332667ffc00b31ULL, 0x8eb44a8768581511ULL, 0xdb0c2e0d64f98fa7ULL, 0x47b5481dbefa4fa4ULL,
	};
	zero(s, sizeof(*s));
	for (int i = 0; i < 8; i++)
		s->h[i] = iv[i];
}
static void sha512_init(void *st)
{
	struct state64 *s = st;
	static const uint64_t iv[8] = {
		0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
		0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL, 0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL,
	};
	zero(s, sizeof(*s));
	for (int i = 0; i < 8; i++)
		s->h[i] = iv[i];
}
static void sha384_final(void *st, unsigned char *out) { final64(st, out, 6); }
static void sha512_final(void *st, unsigned char *out) { final64(st, out, 8); }

_Static_assert(sizeof(struct state32) <= CCDIGEST_MAX_STATE_SIZE, "state32 fits");
_Static_assert(sizeof(struct state64) <= CCDIGEST_MAX_STATE_SIZE, "state64 fits");

static const struct ccdigest_info di_sha1 = { 20, sizeof(struct state32), 64, sha1_init, sha1_update, sha1_final };
static const struct ccdigest_info di_sha224 = { 28, sizeof(struct state32), 64, sha224_init, sha256_update, sha224_final };
static const struct ccdigest_info di_sha256 = { 32, sizeof(struct state32), 64, sha256_init, sha256_update, sha256_final };
static const struct ccdigest_info di_sha384 = { 48, sizeof(struct state64), 128, sha384_init, sha512_update, sha384_final };
static const struct ccdigest_info di_sha512 = { 64, sizeof(struct state64), 128, sha512_init, sha512_update, sha512_final };

const struct ccdigest_info *ccsha1_di(void) { return &di_sha1; }
const struct ccdigest_info *ccsha224_di(void) { return &di_sha224; }
const struct ccdigest_info *ccsha256_di(void) { return &di_sha256; }
const struct ccdigest_info *ccsha384_di(void) { return &di_sha384; }
const struct ccdigest_info *ccsha512_di(void) { return &di_sha512; }

void ccdigest_init(const struct ccdigest_info *di, ccdigest_ctx *ctx) { di->init(ctx->opaque); }

void ccdigest_update(const struct ccdigest_info *di, ccdigest_ctx *ctx, size_t len, const void *data)
{
	di->update(ctx->opaque, len, data);
}

void ccdigest_final(const struct ccdigest_info *di, ccdigest_ctx *ctx, unsigned char *digest)
{
	di->final(ctx->opaque, digest);
}

void ccdigest_clear(const struct ccdigest_info *di, ccdigest_ctx *ctx)
{
	(void)di;
	zero(ctx->opaque, sizeof(ctx->opaque));
}

void ccdigest(const struct ccdigest_info *di, size_t len, const void *data, void *digest)
{
	ccdigest_ctx ctx;
	ccdigest_init(di, &ctx);
	ccdigest_update(di, &ctx, len, data);
	ccdigest_final(di, &ctx, digest);
	ccdigest_clear(di, &ctx);
}
