/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccmode.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
struct xts_key {
	const struct ccmode_ecb *data, *tweak;
	unsigned char keys[];
};
struct xts_tweak {
	uint64_t blocks;
	unsigned char value[16];
};
static size_t rounded(size_t n)
{
	return (n + 7) & ~(size_t)7;
}
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}
static int key_sched(
    const struct ccmode_xts *m, void *context, size_t n, const void *key, const void *tweak_key)
{
	struct xts_key *ctx = context;
	ctx->data = m->custom;
	ctx->tweak = m->custom_tweak;
	int r = ctx->data->init(ctx->data, ctx->keys, n, key);
	int t = ctx->tweak->init(ctx->data, ctx->keys + rounded(ctx->data->size), n, tweak_key);
	return r ? r : t;
}
static int init(
    const struct ccmode_xts *m, void *ctx, size_t n, const void *key, const void *tweak_key)
{
	const unsigned char *a = key, *b = tweak_key;
	unsigned char diff = 0;
	for (size_t i = 0; i < n; i++)
		diff |= a[i] ^ b[i];
	int r = m->key_sched(m, ctx, n, key, tweak_key);
	if (r)
		return r;
	return n && !diff ? -164 : 0;
}
static int set_tweak(const void *context, void *tweak, const void *iv)
{
	const struct xts_key *ctx = context;
	struct xts_tweak *t = tweak;
	t->blocks = 0;
	return ctx->tweak->ecb(ctx->keys + rounded(ctx->data->size), 1, iv, t->value);
}
static void *crypt(const void *context, void *tweak, size_t n, const void *input, void *output)
{
	const struct xts_key *ctx = context;
	struct xts_tweak *t = tweak;
	if (t->blocks > 1048576 || n > 1048576 - t->blocks)
		return NULL;
	t->blocks += n;
	const unsigned char *in = input;
	unsigned char *out = output, block[16];
	while (n--) {
		for (size_t i = 0; i < 16; i++)
			block[i] = in[i] ^ t->value[i];
		ctx->data->ecb(ctx->keys, 1, block, block);
		for (size_t i = 0; i < 16; i++)
			out[i] = block[i] ^ t->value[i];
		unsigned carry = 0;
		for (size_t i = 0; i < 16; i++) {
			unsigned v = ((unsigned)t->value[i] << 1) | carry;
			t->value[i] = (unsigned char)v;
			carry = v >> 8;
		}
		t->value[0] ^= (unsigned char)((0u - carry) & 0x87);
		in += 16;
		out += 16;
	}
	wipe(block, sizeof(block));
	return t->value;
}
extern const struct ccmode_ecb ccaes_arm_ecb_encrypt_mode, ccaes_arm_ecb_decrypt_mode;
EXPORT const struct ccmode_xts ccaes_arm_xts_encrypt_mode = {512, 24, 16, init, key_sched,
    set_tweak, crypt, &ccaes_arm_ecb_encrypt_mode, &ccaes_arm_ecb_encrypt_mode, 22};
EXPORT const struct ccmode_xts ccaes_arm_xts_decrypt_mode = {512, 24, 16, init, key_sched,
    set_tweak, crypt, &ccaes_arm_ecb_decrypt_mode, &ccaes_arm_ecb_encrypt_mode, 22};
EXPORT const struct ccmode_xts *ccaes_xts_encrypt_mode(void)
{
	return &ccaes_arm_xts_encrypt_mode;
}
EXPORT const struct ccmode_xts *ccaes_xts_decrypt_mode(void)
{
	return &ccaes_arm_xts_decrypt_mode;
}
EXPORT void ccmode_factory_xts_encrypt(
    struct ccmode_xts *m, const struct ccmode_ecb *e, const struct ccmode_ecb *t)
{
	*m = ccaes_arm_xts_encrypt_mode;
	m->size = 16 + 2 * rounded(e->size);
	m->tweak_size = 8 + rounded(e->block_size);
	m->block_size = e->block_size;
	m->custom = e;
	m->custom_tweak = t;
	m->implementation = 21;
}
EXPORT void ccmode_factory_xts_decrypt(
    struct ccmode_xts *m, const struct ccmode_ecb *e, const struct ccmode_ecb *t)
{
	ccmode_factory_xts_encrypt(m, e, t);
}
EXPORT size_t ccxts_context_size(const struct ccmode_xts *m)
{
	return m->size;
}
EXPORT size_t ccxts_block_size(const struct ccmode_xts *m)
{
	return m->block_size;
}
EXPORT int ccxts_init(
    const struct ccmode_xts *m, void *ctx, size_t n, const void *key, const void *tweak_key)
{
	return m->init(m, ctx, n, key, tweak_key);
}
EXPORT int ccxts_set_tweak(const struct ccmode_xts *m, const void *ctx, void *tweak, const void *iv)
{
	return m->set_tweak(ctx, tweak, iv);
}
EXPORT void *ccxts_update(
    const struct ccmode_xts *m, const void *ctx, void *tweak, size_t n, const void *in, void *out)
{
	return m->xts(ctx, tweak, n, in, out);
}
EXPORT int ccxts_one_shot(const struct ccmode_xts *m, size_t key_size, const void *key,
    const void *tweak_key, const void *iv, size_t n, const void *in, void *out)
{
	_Alignas(16) unsigned char ctx[m->size], tweak[m->tweak_size];
	int r = m->init(m, ctx, key_size, key, tweak_key);
	if (!r)
		r = m->set_tweak(ctx, tweak, iv);
	if (!r && !m->xts(ctx, tweak, n, in, out))
		r = -7;
	wipe(ctx, sizeof(ctx));
	wipe(tweak, sizeof(tweak));
	return r;
}
