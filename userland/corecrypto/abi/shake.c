/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccxof.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
extern size_t SHA3_absorb(uint64_t state[5][5], const void *, size_t, size_t);
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}
static void shake_init(const struct ccxof_info *xi, void *state)
{
	memset(state, 0, xi->state_size);
}
static void shake_absorb(const struct ccxof_info *xi, void *state, size_t blocks, const void *input)
{
	SHA3_absorb(state, input, blocks * xi->block_size, xi->block_size);
}
static void shake_absorb_last(
    const struct ccxof_info *xi, void *memory, size_t size, const void *input)
{
	unsigned char *state = memory;
	const unsigned char *in = input;
	for (size_t i = 0; i < size; i++)
		state[i] ^= in[i];
	state[size] ^= 0x1f;
	state[xi->block_size - 1] ^= 0x80;
}
static void shake_squeeze(const struct ccxof_info *xi, void *state, size_t size, void *output)
{
	unsigned char zero[xi->block_size], *out = output;
	memset(zero, 0, sizeof(zero));
	while (size) {
		SHA3_absorb(state, zero, sizeof(zero), sizeof(zero));
		size_t take = size < xi->block_size ? size : xi->block_size;
		memcpy(out, state, take);
		out += take;
		size -= take;
	}
}
static const struct ccxof_info shake128 = {
    200, 168, shake_init, shake_absorb, shake_absorb_last, shake_squeeze};
static const struct ccxof_info shake256 = {
    200, 136, shake_init, shake_absorb, shake_absorb_last, shake_squeeze};
EXPORT const struct ccxof_info *ccshake128_xi(void)
{
	return &shake128;
}
EXPORT const struct ccxof_info *ccshake256_xi(void)
{
	return &shake256;
}
EXPORT void ccxof_init(const struct ccxof_info *xi, void *ctx)
{
	memset(ctx, 0, 8);
	xi->init(xi, (unsigned char *)ctx + 8 + xi->block_size);
}
EXPORT void ccxof_absorb(const struct ccxof_info *xi, void *ctx, size_t size, const void *input)
{
	uint32_t *used = ctx;
	unsigned char *buffer = (unsigned char *)ctx + 8, *state = buffer + xi->block_size;
	const unsigned char *in = input;
	if (*used) {
		size_t take = xi->block_size - *used;
		if (take > size)
			take = size;
		if (take) {
			memcpy(buffer + *used, in, take);
			in += take;
			size -= take;
			*used += (uint32_t)take;
		}
		if (*used == xi->block_size) {
			xi->absorb(xi, state, 1, buffer);
			*used = 0;
		}
	}
	size_t blocks = size / xi->block_size;
	if (blocks) {
		xi->absorb(xi, state, blocks, in);
		in += blocks * xi->block_size;
		size -= blocks * xi->block_size;
	}
	if (size) {
		memcpy(buffer, in, size);
		*used = (uint32_t)size;
	}
}
EXPORT void ccxof_squeeze(const struct ccxof_info *xi, void *ctx, size_t size, void *output)
{
	uint32_t *used = ctx, *squeezed = used + 1;
	unsigned char *buffer = (unsigned char *)ctx + 8, *state = buffer + xi->block_size,
	              *out = output;
	if (!*squeezed) {
		xi->absorb_last(xi, state, *used, buffer);
		*used = 0;
		*squeezed = 1;
	}
	while (size) {
		if (!*used) {
			xi->squeeze(xi, state, xi->block_size, buffer);
			*used = (uint32_t)xi->block_size;
		}
		size_t take = size < *used ? size : *used;
		memcpy(out, buffer + xi->block_size - *used, take);
		out += take;
		size -= take;
		*used -= (uint32_t)take;
	}
}
static void shake(
    const struct ccxof_info *xi, size_t size, const void *input, size_t output_size, void *output)
{
	_Alignas(16) unsigned char ctx[8 + xi->block_size + xi->state_size];
	ccxof_init(xi, ctx);
	ccxof_absorb(xi, ctx, size, input);
	ccxof_squeeze(xi, ctx, output_size, output);
	wipe(ctx, sizeof(ctx));
}
EXPORT void ccshake128(size_t n, const void *in, size_t z, void *out)
{
	shake(&shake128, n, in, z, out);
}
EXPORT void ccshake256(size_t n, const void *in, size_t z, void *out)
{
	shake(&shake256, n, in, z, out);
}
