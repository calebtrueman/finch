/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "chacha.h"
#include <stdbool.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
static void wipe(void *ptr, size_t size)
{
	volatile unsigned char *p = ptr;
	while (size--)
		*p++ = 0;
}
static uint32_t load32(const void *p)
{
	uint32_t x;
	memcpy(&x, p, 4);
	return x;
}
static void store32(void *p, uint32_t x)
{
	memcpy(p, &x, 4);
}
static uint32_t rotate(uint32_t x, unsigned n)
{
	return (x << n) | (x >> (32 - n));
}
static void quarter(uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d)
{
	*a += *b;
	*d = rotate(*d ^ *a, 16);
	*c += *d;
	*b = rotate(*b ^ *c, 12);
	*a += *b;
	*d = rotate(*d ^ *a, 8);
	*c += *d;
	*b = rotate(*b ^ *c, 7);
}
static void block(struct ccchacha20_ctx *ctx, unsigned char output[64])
{
	uint32_t x[16];
	memcpy(x, ctx->state, sizeof(x));
	for (unsigned round = 0; round < 10; round++) {
		for (unsigned i = 0; i < 4; i++)
			quarter(x + i, x + 4 + i, x + 8 + i, x + 12 + i);
		for (unsigned i = 0; i < 4; i++)
			quarter(
			    x + i, x + 4 + (i + 1) % 4, x + 8 + (i + 2) % 4, x + 12 + (i + 3) % 4);
	}
	for (unsigned i = 0; i < 16; i++)
		store32(output + 4 * i, x[i] + ctx->state[i]);
	ctx->state[12]++;
	wipe(x, sizeof(x));
}
EXPORT int ccchacha20_reset(struct ccchacha20_ctx *ctx)
{
	ctx->state[12] = 0;
	ctx->used = 0;
	return 0;
}
EXPORT int ccchacha20_init(struct ccchacha20_ctx *ctx, const void *key)
{
	static const unsigned char constant[] = "expand 32-byte k";
	memcpy(ctx->state, constant, 16);
	memcpy(ctx->state + 4, key, 32);
	return ccchacha20_reset(ctx);
}
EXPORT int ccchacha20_setnonce(struct ccchacha20_ctx *ctx, const void *nonce)
{
	memcpy(ctx->state + 13, nonce, 12);
	return 0;
}
EXPORT int ccchacha20_setcounter(struct ccchacha20_ctx *ctx, uint32_t counter)
{
	ctx->state[12] = counter;
	return 0;
}
EXPORT int ccchacha20_update(
    struct ccchacha20_ctx *ctx, size_t size, const void *input, void *output)
{
	const unsigned char *in = input;
	unsigned char *out = output;
	if (ctx->used) {
		if (ctx->used > 64)
			return -7;
		size_t take = 64 - ctx->used;
		if (take > size)
			take = size;
		for (size_t i = 0; i < take; i++)
			out[i] = in[i] ^ ctx->pad[ctx->used + i];
		ctx->used += take;
		size -= take;
		if (take) {
			in += take;
			out += take;
		}
	}
	while (size >= 64) {
		unsigned char pad[64];
		block(ctx, pad);
		for (size_t i = 0; i < 64; i++)
			out[i] = in[i] ^ pad[i];
		wipe(pad, sizeof(pad));
		in += 64;
		out += 64;
		size -= 64;
	}
	if (size) {
		block(ctx, ctx->pad);
		for (size_t i = 0; i < size; i++)
			out[i] = in[i] ^ ctx->pad[i];
		ctx->used = size;
	}
	return 0;
}
EXPORT int ccchacha20_final(struct ccchacha20_ctx *ctx)
{
	wipe(ctx, sizeof(*ctx));
	return 0;
}
EXPORT int ccchacha20(
    const void *key, const void *nonce, uint32_t counter, size_t size, const void *in, void *out)
{
	struct ccchacha20_ctx ctx;
	ccchacha20_init(&ctx, key);
	ccchacha20_setnonce(&ctx, nonce);
	ccchacha20_setcounter(&ctx, counter);
	int result = ccchacha20_update(&ctx, size, in, out);
	ccchacha20_final(&ctx);
	return result;
}

#define MASK26 UINT32_C(0x3ffffff)
EXPORT int ccpoly1305_init(struct ccpoly1305_ctx *ctx, const void *key)
{
	const unsigned char *p = key;
	uint32_t a = load32(p), b = load32(p + 4), c = load32(p + 8), d = load32(p + 12);
	ctx->r[0] = a & MASK26;
	ctx->r[1] = ((a >> 26) | (b << 6)) & 0x3ffff03;
	ctx->r[2] = ((b >> 20) | (c << 12)) & 0x3ffc0ff;
	ctx->r[3] = ((c >> 14) | (d << 18)) & 0x3f03fff;
	ctx->r[4] = (d >> 8) & 0xfffff;
	for (unsigned i = 0; i < 4; i++)
		ctx->r5[i] = ctx->r[i + 1] * 5;
	memset(ctx->h, 0, sizeof(ctx->h));
	ctx->used = 0;
	memcpy(ctx->key, p + 16, 16);
	return 0;
}
static void poly_block(struct ccpoly1305_ctx *ctx, const unsigned char *input, size_t size)
{
	unsigned char padded[17] = {0};
	memcpy(padded, input, size);
	padded[size] = 1;
	uint32_t a = load32(padded), b = load32(padded + 4), c = load32(padded + 8),
	         d = load32(padded + 12);
	uint32_t h[5] = {ctx->h[0] + (a & MASK26), ctx->h[1] + (((a >> 26) | (b << 6)) & MASK26),
	    ctx->h[2] + (((b >> 20) | (c << 12)) & MASK26),
	    ctx->h[3] + (((c >> 14) | (d << 18)) & MASK26),
	    ctx->h[4] + (d >> 8) + ((uint32_t)padded[16] << 24)};
	uint64_t products[5] = {0};
	for (unsigned i = 0; i < 5; i++)
		for (unsigned j = 0; j < 5; j++) {
			unsigned sum = i + j;
			products[sum % 5] += (uint64_t)h[i] * ctx->r[j] * (sum >= 5 ? 5 : 1);
		}
	for (unsigned i = 0; i < 4; i++) {
		ctx->h[i] = (uint32_t)products[i] & MASK26;
		products[i + 1] += products[i] >> 26;
	}
	ctx->h[4] = (uint32_t)products[4] & MASK26;
	ctx->h[0] += (uint32_t)(products[4] >> 26) * 5;
	wipe(padded, sizeof(padded));
	wipe(h, sizeof(h));
	wipe(products, sizeof(products));
}
EXPORT int ccpoly1305_update(struct ccpoly1305_ctx *ctx, size_t size, const void *input)
{
	const unsigned char *in = input;
	if (ctx->used > 15)
		return -7;
	if (ctx->used) {
		size_t take = 16 - ctx->used;
		if (take > size)
			take = size;
		if (take) {
			memcpy(ctx->buffer + ctx->used, in, take);
			in += take;
		}
		ctx->used += take;
		size -= take;
		if (ctx->used == 16) {
			poly_block(ctx, ctx->buffer, 16);
			ctx->used = 0;
		}
	}
	while (size >= 16) {
		poly_block(ctx, in, 16);
		in += 16;
		size -= 16;
	}
	if (size) {
		memcpy(ctx->buffer, in, size);
		ctx->used = size;
	}
	return 0;
}
EXPORT int ccpoly1305_final(struct ccpoly1305_ctx *ctx, void *output)
{
	if (ctx->used > 15)
		return -7;
	if (ctx->used)
		poly_block(ctx, ctx->buffer, ctx->used);
	uint32_t h[5];
	memcpy(h, ctx->h, sizeof(h));
	for (unsigned i = 0; i < 4; i++) {
		h[i + 1] += h[i] >> 26;
		h[i] &= MASK26;
	}
	h[0] += (h[4] >> 26) * 5;
	h[4] &= MASK26;
	uint32_t reduced[5];
	uint64_t carry = 5;
	for (unsigned i = 0; i < 5; i++) {
		carry += h[i];
		reduced[i] = (uint32_t)carry & MASK26;
		carry >>= 26;
	}
	uint32_t use_reduced = 0 - (uint32_t)carry;
	for (unsigned i = 0; i < 5; i++)
		ctx->h[i] = (reduced[i] & use_reduced) | (h[i] & ~use_reduced);
	uint32_t words[4] = {ctx->h[0] | (ctx->h[1] << 26), (ctx->h[1] >> 6) | (ctx->h[2] << 20),
	    (ctx->h[2] >> 12) | (ctx->h[3] << 14), (ctx->h[3] >> 18) | (ctx->h[4] << 8)};
	carry = 0;
	for (unsigned i = 0; i < 4; i++) {
		carry += (uint64_t)words[i] + load32(ctx->key + 4 * i);
		store32((unsigned char *)output + 4 * i, (uint32_t)carry);
		carry >>= 32;
	}
	wipe(h, sizeof(h));
	wipe(reduced, sizeof(reduced));
	wipe(words, sizeof(words));
	return 0;
}
EXPORT int ccpoly1305(const void *key, size_t size, const void *input, void *tag)
{
	struct ccpoly1305_ctx ctx;
	ccpoly1305_init(&ctx, key);
	ccpoly1305_update(&ctx, size, input);
	int result = ccpoly1305_final(&ctx, tag);
	wipe(&ctx, sizeof(ctx));
	return result;
}

static const struct ccchacha20poly1305_info info = {0};
EXPORT const struct ccchacha20poly1305_info *ccchacha20poly1305_info(void)
{
	return &info;
}
EXPORT int ccchacha20poly1305_reset(
    const struct ccchacha20poly1305_info *unused, struct ccchacha20poly1305_ctx *ctx)
{
	(void)unused;
	ccchacha20_reset(&ctx->chacha);
	ctx->aad_size = ctx->text_size = 0;
	ctx->state = 1;
	return 0;
}
EXPORT int ccchacha20poly1305_init(const struct ccchacha20poly1305_info *unused,
    struct ccchacha20poly1305_ctx *ctx, const void *key)
{
	ccchacha20_init(&ctx->chacha, key);
	return ccchacha20poly1305_reset(unused, ctx);
}
EXPORT int ccchacha20poly1305_setnonce(const struct ccchacha20poly1305_info *unused,
    struct ccchacha20poly1305_ctx *ctx, const void *nonce)
{
	(void)unused;
	if (ctx->state != 1)
		return 1;
	ccchacha20_setnonce(&ctx->chacha, nonce);
	unsigned char key[64];
	block(&ctx->chacha, key);
	ccpoly1305_init(&ctx->poly, key);
	wipe(key, sizeof(key));
	ctx->state = 2;
	return 0;
}
EXPORT int ccchacha20poly1305_incnonce(
    const struct ccchacha20poly1305_info *unused, struct ccchacha20poly1305_ctx *ctx, void *nonce)
{
	(void)unused;
	(void)ctx;
	(void)nonce;
	return 1;
}
EXPORT int ccchacha20poly1305_aad(const struct ccchacha20poly1305_info *unused,
    struct ccchacha20poly1305_ctx *ctx, size_t size, const void *input)
{
	(void)unused;
	if (ctx->state != 2)
		return 1;
	ccpoly1305_update(&ctx->poly, size, input);
	ctx->aad_size += size;
	return 0;
}
static void finish_aad(struct ccchacha20poly1305_ctx *ctx, unsigned state)
{
	static const unsigned char zero[16] = {0};
	if (ctx->state == 2) {
		ccpoly1305_update(&ctx->poly, (0 - ctx->aad_size) & 15, zero);
		ctx->state = (unsigned char)state;
	}
}
static int authenticated_crypt(
    struct ccchacha20poly1305_ctx *ctx, size_t size, const void *input, void *output, bool decrypt)
{
	unsigned state = decrypt ? 4 : 3;
	finish_aad(ctx, state);
	if (ctx->state != state || size > UINT64_C(0x3fffffffc0) ||
	    ctx->text_size > UINT64_C(0x3fffffffc0) - size)
		return 1;
	if (decrypt)
		ccpoly1305_update(&ctx->poly, size, input);
	ccchacha20_update(&ctx->chacha, size, input, output);
	if (!decrypt)
		ccpoly1305_update(&ctx->poly, size, output);
	ctx->text_size += size;
	return 0;
}
EXPORT int ccchacha20poly1305_encrypt(const struct ccchacha20poly1305_info *unused,
    struct ccchacha20poly1305_ctx *ctx, size_t size, const void *input, void *output)
{
	(void)unused;
	return authenticated_crypt(ctx, size, input, output, false);
}
EXPORT int ccchacha20poly1305_decrypt(const struct ccchacha20poly1305_info *unused,
    struct ccchacha20poly1305_ctx *ctx, size_t size, const void *input, void *output)
{
	(void)unused;
	return authenticated_crypt(ctx, size, input, output, true);
}
static int finish_tag(struct ccchacha20poly1305_ctx *ctx, void *tag, unsigned state)
{
	static const unsigned char zero[16] = {0};
	finish_aad(ctx, state);
	if (ctx->state != state)
		return 1;
	ccpoly1305_update(&ctx->poly, (0 - ctx->text_size) & 15, zero);
	ccpoly1305_update(&ctx->poly, 8, &ctx->aad_size);
	ccpoly1305_update(&ctx->poly, 8, &ctx->text_size);
	ccpoly1305_final(&ctx->poly, tag);
	ctx->state = 5;
	return 0;
}
EXPORT int ccchacha20poly1305_finalize(
    const struct ccchacha20poly1305_info *unused, struct ccchacha20poly1305_ctx *ctx, void *tag)
{
	(void)unused;
	return finish_tag(ctx, tag, 3);
}
EXPORT int ccchacha20poly1305_verify(const struct ccchacha20poly1305_info *unused,
    struct ccchacha20poly1305_ctx *ctx, const void *tag)
{
	(void)unused;
	unsigned char actual[16];
	int result = finish_tag(ctx, actual, 4);
	if (result)
		return result;
	unsigned difference = 0;
	for (unsigned i = 0; i < 16; i++)
		difference |= actual[i] ^ ((const unsigned char *)tag)[i];
	wipe(actual, sizeof(actual));
	return difference ? -1 : 0;
}
EXPORT int ccchacha20poly1305_encrypt_oneshot(const struct ccchacha20poly1305_info *di,
    const void *key, const void *nonce, size_t aad_size, const void *aad, size_t size,
    const void *input, void *output, void *tag)
{
	struct ccchacha20poly1305_ctx ctx = {0};
	ccchacha20poly1305_init(di, &ctx, key);
	ccchacha20poly1305_setnonce(di, &ctx, nonce);
	ccchacha20poly1305_aad(di, &ctx, aad_size, aad);
	int result = ccchacha20poly1305_encrypt(di, &ctx, size, input, output);
	if (!result)
		result = ccchacha20poly1305_finalize(di, &ctx, tag);
	wipe(&ctx, sizeof(ctx));
	return result;
}
EXPORT int ccchacha20poly1305_decrypt_oneshot(const struct ccchacha20poly1305_info *di,
    const void *key, const void *nonce, size_t aad_size, const void *aad, size_t size,
    const void *input, void *output, const void *tag)
{
	struct ccchacha20poly1305_ctx ctx = {0};
	ccchacha20poly1305_init(di, &ctx, key);
	ccchacha20poly1305_setnonce(di, &ctx, nonce);
	ccchacha20poly1305_aad(di, &ctx, aad_size, aad);
	int result = ccchacha20poly1305_decrypt(di, &ctx, size, input, output);
	if (!result)
		result = ccchacha20poly1305_verify(di, &ctx, tag);
	wipe(&ctx, sizeof(ctx));
	return result;
}
