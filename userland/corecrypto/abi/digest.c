/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Reuse Finch's SHA compression code under the layout expected by existing
 * macOS binaries. The older, private dyld interface stays unchanged.
 */
#define ccdigest_info finch_static_digest_info
#define ccdigest_ctx finch_static_digest_ctx
#define ccdigest_init finch_static_digest_init
#define ccdigest_update finch_static_digest_update
#define ccdigest_final finch_static_digest_final
#define ccdigest_clear finch_static_digest_clear
#define ccdigest finch_static_digest
#define ccsha1_di finch_static_sha1_di
#define ccsha224_di finch_static_sha224_di
#define ccsha256_di finch_static_sha256_di
#define ccsha384_di finch_static_sha384_di
#define ccsha512_di finch_static_sha512_di
#include "../digest.c"
#undef ccdigest_info
#undef ccdigest_ctx
#undef ccdigest_init
#undef ccdigest_update
#undef ccdigest_final
#undef ccdigest_clear
#undef ccdigest
#undef ccsha1_di
#undef ccsha224_di
#undef ccsha256_di
#undef ccsha384_di
#undef ccsha512_di

#include "ccdigest.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))

_Static_assert(offsetof(struct ccdigest_info, initial_state) == 40, "initial state offset");
_Static_assert(offsetof(struct ccdigest_info, compress) == 48, "compression offset");
_Static_assert(offsetof(struct ccdigest_info, final) == 56, "final offset");

static uint32_t *pending(const struct ccdigest_info *di, void *ctx)
{
	return (uint32_t *)(ccdigest_data(di, ctx) + di->block_size);
}

EXPORT void ccdigest_init(const struct ccdigest_info *di, void *ctx)
{
	memcpy(ccdigest_state_u8(di, ctx), di->initial_state, di->state_size);
	*(uint64_t *)ctx = 0;
	*pending(di, ctx) = 0;
}

EXPORT void ccdigest_update(
    const struct ccdigest_info *di, void *ctx, size_t len, const void *input)
{
	unsigned char *state = ccdigest_state_u8(di, ctx), *buffer = ccdigest_data(di, ctx);
	uint32_t *used = pending(di, ctx);
	const unsigned char *data = input;
	if (*used >= di->block_size)
		*used = 0;
	while (len) {
		size_t take;
		if (!*used && len > di->block_size) {
			size_t blocks = len / di->block_size;
			take = blocks * di->block_size;
			di->compress(state, blocks, data);
			*(uint64_t *)ctx += (uint64_t)take * 8;
		} else {
			take = di->block_size - *used;
			if (take > len)
				take = len;
			memcpy(buffer + *used, data, take);
			*used += (uint32_t)take;
			if (*used == di->block_size) {
				di->compress(state, 1, buffer);
				*(uint64_t *)ctx += (uint64_t)*used * 8;
				*used = 0;
			}
		}
		data += take;
		len -= take;
	}
}

static void final_be(const struct ccdigest_info *di, void *ctx, unsigned char *output)
{
	if (*pending(di, ctx) >= di->block_size)
		*pending(di, ctx) = 0;
	size_t size = ccdigest_di_size(di);
	_Alignas(16) unsigned char scratch[size];
	memcpy(scratch, ctx, size);
	unsigned char *buffer = ccdigest_data(di, scratch);
	void *state = ccdigest_state_u8(di, scratch);
	size_t used = *pending(di, scratch);
	uint64_t bits = *(uint64_t *)scratch + used * 8;
	size_t reserve = di->block_size == 128 ? 16 : 8;
	buffer[used++] = 0x80;
	if (used > di->block_size - reserve) {
		memset(buffer + used, 0, di->block_size - used);
		di->compress(state, 1, buffer);
		used = 0;
	}
	memset(buffer + used, 0, di->block_size - used);
	put64(buffer + di->block_size - 8, bits);
	di->compress(state, 1, buffer);
	if (di->block_size == 128) {
		for (size_t i = 0; i < di->output_size / 8; i++)
			put64(output + i * 8, ((uint64_t *)state)[i]);
	} else {
		for (size_t i = 0; i < di->output_size / 4; i++)
			put32(output + i * 4, ((uint32_t *)state)[i]);
	}
	zero(scratch, size);
}

EXPORT void ccdigest(const struct ccdigest_info *di, size_t len, const void *input, void *output)
{
	size_t size = ccdigest_di_size(di);
	_Alignas(16) unsigned char context[size];
	ccdigest_init(di, context);
	ccdigest_update(di, context, len, input);
	di->final(di, context, output);
	zero(context, size);
}

static void sha1_blocks(void *state, size_t count, const void *data)
{
	const unsigned char *p = data;
	while (count--) {
		sha1_compress(state, p);
		p += 64;
	}
}
static void sha256_blocks(void *state, size_t count, const void *data)
{
	const unsigned char *p = data;
	while (count--) {
		sha256_compress(state, p);
		p += 64;
	}
}
static void sha512_blocks(void *state, size_t count, const void *data)
{
	const unsigned char *p = data;
	while (count--) {
		sha512_compress(state, p);
		p += 128;
	}
}

static const uint32_t initial1[] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0};
static const uint32_t initial224[] = {
    0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939, 0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4};
static const uint32_t initial256[] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
static const uint64_t initial384[] = {0xcbbb9d5dc1059ed8ULL, 0x629a292a367cd507ULL,
    0x9159015a3070dd17ULL, 0x152fecd8f70e5939ULL, 0x67332667ffc00b31ULL, 0x8eb44a8768581511ULL,
    0xdb0c2e0d64f98fa7ULL, 0x47b5481dbefa4fa4ULL};
static const uint64_t initial512[] = {0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
    0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL, 0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
    0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL};
static const unsigned char oid1[] = {6, 5, 0x2b, 0x0e, 3, 2, 0x1a};
#define SHA2_OID(n, id)                                                                            \
	static const unsigned char oid##n[] = {6, 9, 0x60, 0x86, 0x48, 1, 0x65, 3, 4, 2, id}
SHA2_OID(224, 4);
SHA2_OID(256, 1);
SHA2_OID(384, 2);
SHA2_OID(512, 3);
#define DI(n, out, block, comp, impl)                                                              \
	EXPORT const struct ccdigest_info ccsha##n##_ltc_di = {out, sizeof(initial##n), block,     \
	    sizeof(oid##n), oid##n, initial##n, comp, final_be, impl, 0};                          \
	EXPORT const struct ccdigest_info *ccsha##n##_di(void)                                     \
	{                                                                                          \
		return &ccsha##n##_ltc_di;                                                         \
	}
DI(1, 20, 64, sha1_blocks, 31)
DI(224, 28, 64, sha256_blocks, 0)
DI(256, 32, 64, sha256_blocks, 1)
DI(384, 48, 128, sha512_blocks, 41)
DI(512, 64, 128, sha512_blocks, 51)

static const uint64_t initial512_256[] = {0x22312194fc2bf72cULL, 0x9f555fa3c84c64c2ULL,
    0x2393b86b6f53b151ULL, 0x963877195940eabdULL, 0x96283ee2a88effe3ULL, 0xbe5e1e2553863992ULL,
    0x2b0199fc2c85b8aaULL, 0x0eb72ddc81c52ca2ULL};
SHA2_OID(512_256, 6);
DI(512_256, 32, 128, sha512_blocks, 0)

EXPORT void ccdigest_parallel(const struct ccdigest_info *di, size_t size, const void *input_a,
    void *output_a, const void *input_b, void *output_b)
{
	/* Keep both inputs live until both are consumed, including when an output
     * shares storage with the other input. The ABI does not require SIMD. */
	_Alignas(16) unsigned char a[ccdigest_di_size(di)], b[sizeof(a)];
	ccdigest_init(di, a);
	ccdigest_init(di, b);
	ccdigest_update(di, a, size, input_a);
	ccdigest_update(di, b, size, input_b);
	di->final(di, a, output_a);
	di->final(di, b, output_b);
	zero(a, sizeof(a));
	zero(b, sizeof(b));
}

EXPORT const void *ccoid_payload(const void *oid)
{
	return oid;
}
EXPORT size_t ccoid_size(const void *oid)
{
	return ((const unsigned char *)oid)[1] + 2;
}
EXPORT int ccoid_equal(const void *a, const void *b)
{
	if (!a || !b)
		return a == b;
	size_t size = ccoid_size(a);
	return size == ccoid_size(b) && !memcmp(a, b, size);
}
#include <stdarg.h>
EXPORT const struct ccdigest_info *ccdigest_oid_lookup(const void *oid, ...)
{
	va_list list;
	va_start(list, oid);
	const struct ccdigest_info *di;
	while ((di = va_arg(list, const struct ccdigest_info *)))
		if (ccoid_equal(di->oid, oid))
			break;
	va_end(list);
	return di;
}

/* Callers also take the addresses of named implementation descriptors. The
 * identifiers and state layout are preserved; Finch shares its block code. */
#define VARIANT(n, suffix, out, block, comp, impl)                                                 \
	EXPORT const struct ccdigest_info ccsha##n##_##suffix##_di = {out, sizeof(initial##n),     \
	    block, sizeof(oid##n), oid##n, initial##n, comp, final_be, impl, NULL};
VARIANT(1, eay, 20, 64, sha1_blocks, 0)
VARIANT(1, vng_arm, 20, 64, sha1_blocks, 32)
VARIANT(224, vng_arm, 28, 64, sha256_blocks, 0)
VARIANT(256, vng_arm64neon, 32, 64, sha256_blocks, 3)
VARIANT(256, vng_arm, 32, 64, sha256_blocks, 2)
VARIANT(384, vng_arm, 48, 128, sha512_blocks, 42)
VARIANT(384, vng_arm_hw, 48, 128, sha512_blocks, 57)
VARIANT(512, vng_arm, 64, 128, sha512_blocks, 52)
VARIANT(512, vng_arm_hw, 64, 128, sha512_blocks, 56)
VARIANT(512_256, vng_arm, 32, 128, sha512_blocks, 0)
VARIANT(512_256, vng_arm_hw, 32, 128, sha512_blocks, 0)
