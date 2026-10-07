/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccdigest.h"
#include <openssl/evp.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#define API __attribute__((visibility("default")))
extern int ccpbkdf2_hmac(const struct ccdigest_info *, size_t, const void *, size_t, const void *,
    uint64_t, size_t, void *);
extern void cc_clear(size_t, void *);
API int ccmgf(
    const struct ccdigest_info *d, size_t outlen, void *out, size_t seedlen, const void *seed)
{
	if (!d || !d->output_size)
		return -7;
	size_t ctxlen = ccdigest_di_size(d);
	unsigned char *ctx = malloc(ctxlen), *hash = malloc(d->output_size);
	if (!ctx || !hash) {
		free(ctx);
		free(hash);
		return -13;
	}
	/* The last digest is written first, as on the host, including overlapping buffers. */
	size_t full = outlen / d->output_size, rem = outlen % d->output_size;
	for (size_t pass = full + 1; pass; pass--) {
		size_t index = pass - 1, take = index == full ? rem : d->output_size;
		if (!take)
			continue;
		unsigned char count[4] = {(unsigned char)(index >> 24),
		    (unsigned char)(index >> 16), (unsigned char)(index >> 8),
		    (unsigned char)index};
		ccdigest_init(d, ctx);
		ccdigest_update(d, ctx, seedlen, seed);
		ccdigest_update(d, ctx, 4, count);
		d->final(d, ctx, hash);
		memcpy((unsigned char *)out + index * d->output_size, hash, take);
	}
	cc_clear(ctxlen, ctx);
	cc_clear(d->output_size, hash);
	free(ctx);
	free(hash);
	return 0;
}
API int64_t ccscrypt_storage_size(uint64_t N, uint32_t r, uint32_t p)
{
	uint32_t block = r << 7;
	if (!r || !N || (N & (N - 1)) || p > (block ? UINT32_C(0xffffffe0) / block : 0))
		return -7;
	__uint128_t size =
	    (__uint128_t)128 * r * p + (__uint128_t)256 * r + (__uint128_t)128 * r * N;
	return size > INT64_MAX ? -12 : (int64_t)size;
}
static uint32_t rot(uint32_t x, unsigned n)
{
	return (x << n) | (x >> (32 - n));
}
static void salsa8(uint32_t b[16])
{
	uint32_t x[16];
	memcpy(x, b, 64);
#define STEP(a, b, c, d)                                                                           \
	x[b] ^= rot(x[a] + x[d], 7);                                                               \
	x[c] ^= rot(x[b] + x[a], 9);                                                               \
	x[d] ^= rot(x[c] + x[b], 13);                                                              \
	x[a] ^= rot(x[d] + x[c], 18)
	for (int i = 0; i < 4; i++) {
		STEP(0, 4, 8, 12);
		STEP(5, 9, 13, 1);
		STEP(10, 14, 2, 6);
		STEP(15, 3, 7, 11);
		STEP(0, 1, 2, 3);
		STEP(5, 6, 7, 4);
		STEP(10, 11, 8, 9);
		STEP(15, 12, 13, 14);
	}
#undef STEP
	for (int i = 0; i < 16; i++)
		b[i] += x[i];
	cc_clear(sizeof x, x);
}
static void blockmix(uint32_t *b, uint32_t *y, uint32_t r)
{
	uint32_t x[16];
	memcpy(x, b + (2 * (size_t)r - 1) * 16, 64);
	for (size_t i = 0; i < 2 * (size_t)r; i++) {
		for (int k = 0; k < 16; k++)
			x[k] ^= b[i * 16 + k];
		salsa8(x);
		memcpy(y + ((i / 2) + (i % 2) * r) * 16, x, 64);
	}
	memcpy(b, y, 128 * (size_t)r);
	cc_clear(sizeof x, x);
}
API int ccscrypt(size_t password_len, const void *password, size_t salt_len, const void *salt,
    void *scratch, uint64_t N, uint32_t r, uint32_t p, size_t out_len, void *out)
{
	int64_t storage = ccscrypt_storage_size(N, r, p);
	if (storage < 0)
		return (int)storage;
	if (out_len > UINT64_C(0xfffffffe0))
		return -7;
	int ok;
	if (!p) {
		ok =
		    !ccpbkdf2_hmac(ccsha256_di(), password_len, password, 0, NULL, 1, out_len, out);
	} else if (N == 1) {
		size_t chunk = 128 * (size_t)r, total = chunk * p;
		unsigned char *b = scratch, *y = b + total, *v = y + 2 * chunk;
		ok = !ccpbkdf2_hmac(
		    ccsha256_di(), password_len, password, salt_len, salt, 1, total, b);
		if (ok) {
			for (uint32_t i = 0; i < p; i++) {
				unsigned char *x = b + i * chunk;
				memcpy(v, x, chunk);
				blockmix((void *)x, (void *)y, r);
				for (size_t j = 0; j < chunk; j++)
					x[j] ^= v[j];
				blockmix((void *)x, (void *)y, r);
			}
			ok = !ccpbkdf2_hmac(
			    ccsha256_di(), password_len, password, total, b, 1, out_len, out);
		}
	} else
		ok = EVP_PBE_scrypt(
		    password, password_len, salt, salt_len, N, r, p, UINT64_MAX, out, out_len);
	if (ok)
		cc_clear((size_t)storage, scratch);
	return ok ? 0 : -1;
}
