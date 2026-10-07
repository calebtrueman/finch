/* SPDX-License-Identifier: MIT OR Apache-2.0
 * OpenSSL supplies the MD4, MD5, RIPEMD-160 and Keccak block transforms.
 * This file keeps the caller-owned state in the measured corecrypto layout.
 */
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/md4.h>
#include <openssl/md5.h>
#include <openssl/ripemd.h>
#include "ccdigest.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}

#define LEGACY_BLOCKS(name, type, transform, state_bytes)                                          \
	static void name(void *state, size_t count, const void *input)                             \
	{                                                                                          \
		type ctx = {0};                                                                    \
		const unsigned char *in = input;                                                   \
		memcpy(&ctx, state, state_bytes);                                                  \
		while (count--) {                                                                  \
			transform(&ctx, in);                                                       \
			in += 64;                                                                  \
		}                                                                                  \
		memcpy(state, &ctx, state_bytes);                                                  \
		wipe(&ctx, sizeof(ctx));                                                           \
	}
LEGACY_BLOCKS(md4_blocks, MD4_CTX, MD4_Transform, 16)
LEGACY_BLOCKS(md5_blocks, MD5_CTX, MD5_Transform, 16)
LEGACY_BLOCKS(rmd160_blocks, RIPEMD160_CTX, RIPEMD160_Transform, 20)

static void final_le(const struct ccdigest_info *di, void *ctx, unsigned char *output)
{
	uint32_t *pending = (void *)(ccdigest_data(di, ctx) + di->block_size);
	if (*pending >= di->block_size)
		*pending = 0;
	_Alignas(16) unsigned char scratch[ccdigest_di_size(di)];
	memcpy(scratch, ctx, sizeof(scratch));
	unsigned char *buffer = ccdigest_data(di, scratch);
	void *state = ccdigest_state_u8(di, scratch);
	size_t used = *pending;
	uint64_t bits = *(uint64_t *)scratch + used * 8;
	buffer[used++] = 0x80;
	if (used > di->block_size - 8) {
		memset(buffer + used, 0, di->block_size - used);
		di->compress(state, 1, buffer);
		used = 0;
	}
	memset(buffer + used, 0, di->block_size - used);
	for (unsigned i = 0; i < 8; i++)
		buffer[di->block_size - 8 + i] = bits >> (i * 8);
	di->compress(state, 1, buffer);
	memcpy(output, state, di->output_size);
	wipe(scratch, sizeof(scratch));
}
static const uint32_t initial_md[] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476};
static const uint32_t initial_rmd[] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0};
static const unsigned char oid_md4[] = {6, 8, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 2, 4};
static const unsigned char oid_md5[] = {6, 8, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 2, 5};
static const unsigned char oid_rmd[] = {6, 5, 0x2b, 0x24, 3, 2, 1};
EXPORT const struct ccdigest_info ccmd4_ltc_di = {
    16, 16, 64, sizeof(oid_md4), oid_md4, initial_md, md4_blocks, final_le, 0, 0};
EXPORT const struct ccdigest_info ccmd5_ltc_di = {
    16, 16, 64, sizeof(oid_md5), oid_md5, initial_md, md5_blocks, final_le, 0, 0};
EXPORT const struct ccdigest_info ccrmd160_ltc_di = {
    20, 20, 64, sizeof(oid_rmd), oid_rmd, initial_rmd, rmd160_blocks, final_le, 0, 0};
EXPORT const struct ccdigest_info *ccmd5_di(void)
{
	return &ccmd5_ltc_di;
}

/* OpenSSL's ARM implementation uses the same 25 little-endian state words. */
extern size_t SHA3_absorb(uint64_t state[5][5], const void *, size_t, size_t);
extern void SHA3_squeeze(uint64_t state[5][5], unsigned char *, size_t, size_t, int);
static void sha3_final(const struct ccdigest_info *di, void *ctx, unsigned char *output)
{
	uint32_t *pending = (void *)(ccdigest_data(di, ctx) + di->block_size);
	if (*pending >= di->block_size)
		*pending = 0;
	_Alignas(16) unsigned char scratch[ccdigest_di_size(di)];
	memcpy(scratch, ctx, sizeof(scratch));
	unsigned char *buffer = ccdigest_data(di, scratch);
	void *state = ccdigest_state_u8(di, scratch);
	memset(buffer + *pending, 0, di->block_size - *pending);
	buffer[*pending] = 6;
	buffer[di->block_size - 1] |= 0x80;
	di->compress(state, 1, buffer);
	SHA3_squeeze(state, output, di->output_size, di->block_size, 0);
	wipe(scratch, sizeof(scratch));
}
static const uint64_t initial_sha3[25] = {0};
#define SHA3(n, rate, oid_id)                                                                      \
	static void sha3_##n##_blocks(void *state, size_t count, const void *input)                \
	{                                                                                          \
		SHA3_absorb(state, input, count * rate, rate);                                     \
	}                                                                                          \
	static void sha3_##n##_parallel(                                                           \
	    void *a, size_t na, const void *in_a, void *b, size_t nb, const void *in_b)            \
	{                                                                                          \
		(void)nb;                                                                          \
		sha3_##n##_blocks(a, na, in_a);                                                    \
		sha3_##n##_blocks(b, na, in_b);                                                    \
	}                                                                                          \
	static const unsigned char oid_sha3_##n[] = {                                              \
	    6, 9, 0x60, 0x86, 0x48, 1, 0x65, 3, 4, 2, oid_id};                                     \
	static const struct ccdigest_info sha3_##n##_descriptor = {n / 8, 200, rate, 11,           \
	    oid_sha3_##n, initial_sha3, sha3_##n##_blocks, sha3_final, 61, sha3_##n##_parallel};   \
	EXPORT const struct ccdigest_info *ccsha3_##n##_di(void)                                   \
	{                                                                                          \
		return &sha3_##n##_descriptor;                                                     \
	}
SHA3(224, 144, 7)
SHA3(256, 136, 8)
SHA3(384, 104, 9)
SHA3(512, 72, 10)

/* MD2's fixed substitution table, specified in RFC 1319. The complete
 * 48-byte work array and 16-byte checksum remain visible in this ABI. */
static const unsigned char md2_substitution[256] = {41, 46, 67, 201, 162, 216, 124, 1, 61, 54, 84,
    161, 236, 240, 6, 19, 98, 167, 5, 243, 192, 199, 115, 140, 152, 147, 43, 217, 188, 76, 130, 202,
    30, 155, 87, 60, 253, 212, 224, 22, 103, 66, 111, 24, 138, 23, 229, 18, 190, 78, 196, 214, 218,
    158, 222, 73, 160, 251, 245, 142, 187, 47, 238, 122, 169, 104, 121, 145, 21, 178, 7, 63, 148,
    194, 16, 137, 11, 34, 95, 33, 128, 127, 93, 154, 90, 144, 50, 39, 53, 62, 204, 231, 191, 247,
    151, 3, 255, 25, 48, 179, 72, 165, 181, 209, 215, 94, 146, 42, 172, 86, 170, 198, 79, 184, 56,
    210, 150, 164, 125, 182, 118, 252, 107, 226, 156, 116, 4, 241, 69, 157, 112, 89, 100, 113, 135,
    32, 134, 91, 207, 101, 230, 45, 168, 2, 27, 96, 37, 173, 174, 176, 185, 246, 28, 70, 97, 105,
    52, 64, 126, 15, 85, 71, 163, 35, 221, 81, 175, 58, 195, 92, 249, 206, 186, 197, 234, 38, 44,
    83, 13, 110, 133, 40, 132, 9, 211, 223, 205, 244, 65, 129, 77, 82, 106, 220, 55, 200, 108, 193,
    171, 250, 36, 225, 123, 8, 12, 189, 177, 74, 120, 136, 149, 139, 227, 99, 232, 109, 233, 203,
    213, 254, 59, 0, 29, 57, 242, 239, 183, 14, 102, 88, 208, 228, 166, 119, 114, 248, 235, 117, 75,
    10, 49, 68, 80, 180, 143, 237, 31, 26, 219, 153, 141, 51, 159, 17, 131, 20};
static void md2_transform(unsigned char state[64], const unsigned char input[16])
{
	for (unsigned i = 0; i < 16; i++) {
		state[16 + i] = input[i];
		state[32 + i] = input[i] ^ state[i];
	}
	unsigned char carry = 0;
	for (unsigned round = 0; round < 18; round++) {
		for (unsigned i = 0; i < 48; i++) {
			state[i] ^= md2_substitution[carry];
			carry = state[i];
		}
		carry += round;
	}
}
static void md2_blocks(void *memory, size_t count, const void *input)
{
	unsigned char *state = memory;
	const unsigned char *in = input;
	while (count--) {
		md2_transform(state, in);
		unsigned char carry = state[63];
		for (unsigned i = 0; i < 16; i++) {
			state[48 + i] ^= md2_substitution[in[i] ^ carry];
			carry = state[48 + i];
		}
		in += 16;
	}
}
static void md2_final(const struct ccdigest_info *di, void *ctx, unsigned char *out)
{
	_Alignas(16) unsigned char scratch[ccdigest_di_size(di)];
	memcpy(scratch, ctx, sizeof(scratch));
	unsigned char *buffer = ccdigest_data(di, scratch), *state = ccdigest_state_u8(di, scratch);
	uint32_t used = *(uint32_t *)(buffer + di->block_size);
	if (used < 16)
		memset(buffer + used, 16 - used, 16 - used);
	md2_blocks(state, 1, buffer);
	memcpy(buffer, state + 48, 16);
	md2_transform(state, buffer);
	memcpy(out, state, 16);
	wipe(scratch, sizeof(scratch));
}
static const unsigned char initial_md2[64] = {0};
static const unsigned char oid_md2[] = {6, 8, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 2, 2};
EXPORT const struct ccdigest_info ccmd2_ltc_di = {
    16, 64, 16, 10, oid_md2, initial_md2, md2_blocks, md2_final, 0, 0};
