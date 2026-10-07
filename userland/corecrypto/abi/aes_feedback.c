/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccmode.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
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
static const struct ccmode_ecb *ecb(void *ctx)
{
	const struct ccmode_ecb *e;
	memcpy(&e, ctx, 8);
	return e;
}
static int setup(
    const struct ccmode_stream *m, void *ctx, size_t n, const void *key, const void *iv, int kind)
{
	const struct ccmode_ecb *e = m->custom;
	size_t block = e->block_size, r = rounded(block);
	unsigned char *pad = (unsigned char *)ctx + (kind == 8 ? 8 : 16),
	              *chain = kind == 0 ? pad : pad + r, *keys = chain + r;
	memcpy(ctx, &e, 8);
	if (iv)
		memcpy(chain, iv, block);
	else
		memset(chain, 0, block);
	if (kind != 8)
		memcpy((unsigned char *)ctx + 8, &block, 8);
	int status = e->init(e, keys, n, key);
	if (kind == 8 && !status)
		status = e->ecb(keys, 1, chain, pad);
	return status;
}
static int cfb_init(const struct ccmode_stream *m, void *c, size_t n, const void *k, const void *iv)
{
	return setup(m, c, n, k, iv, 1);
}
static int cfb8_init(
    const struct ccmode_stream *m, void *c, size_t n, const void *k, const void *iv)
{
	return setup(m, c, n, k, iv, 8);
}
static int ofb_init(const struct ccmode_stream *m, void *c, size_t n, const void *k, const void *iv)
{
	return setup(m, c, n, k, iv, 0);
}
static int feedback(void *ctx, size_t n, const void *input, void *output, int decrypt, int aes)
{
	const struct ccmode_ecb *e = ecb(ctx);
	size_t used, block = e->block_size, r = rounded(block);
	memcpy(&used, (unsigned char *)ctx + 8, 8);
	unsigned char *pad = (unsigned char *)ctx + 16, *chain = pad + r, *keys = chain + r;
	const unsigned char *in = input;
	unsigned char *out = output;
	unsigned char temporary[block ? block : 1];
	while (n) {
		/* The host's AES fast path leaves the saved pad alone for whole
         * blocks. Generic descriptors retain the last computed pad. */
		if (aes && used == block && n >= block) {
			e->ecb(keys, 1, chain, temporary);
			for (size_t i = 0; i < block; i++) {
				unsigned char source = in[i], dest = source ^ temporary[i];
				out[i] = dest;
				chain[i] = decrypt ? source : dest;
			}
			in += block;
			out += block;
			n -= block;
			continue;
		}
		if (used == block) {
			e->ecb(keys, 1, chain, pad);
			used = 0;
		}
		unsigned char source = *in++, dest = source ^ pad[used];
		*out++ = dest;
		chain[used++] = decrypt ? source : dest;
		n--;
	}
	memcpy((unsigned char *)ctx + 8, &used, 8);
	wipe(temporary, sizeof(temporary));
	return 0;
}
static int cfb_encrypt(void *c, size_t n, const void *i, void *o)
{
	return feedback(c, n, i, o, 0, 0);
}
static int cfb_decrypt(void *c, size_t n, const void *i, void *o)
{
	return feedback(c, n, i, o, 1, 0);
}
static int aes_cfb_encrypt(void *c, size_t n, const void *i, void *o)
{
	return feedback(c, n, i, o, 0, 1);
}
static int aes_cfb_decrypt(void *c, size_t n, const void *i, void *o)
{
	return feedback(c, n, i, o, 1, 1);
}
static int feedback8(void *ctx, size_t n, const void *input, void *output, int decrypt)
{
	const struct ccmode_ecb *e = ecb(ctx);
	size_t block = e->block_size, r = rounded(block);
	unsigned char *pad = (unsigned char *)ctx + 8, *chain = pad + r, *keys = chain + r;
	const unsigned char *in = input;
	unsigned char *out = output;
	while (n--) {
		unsigned char source = *in++, dest = source ^ pad[0];
		*out++ = dest;
		memmove(chain, chain + 1, block - 1);
		chain[block - 1] = decrypt ? source : dest;
		e->ecb(keys, 1, chain, pad);
	}
	return 0;
}
static int cfb8_encrypt(void *c, size_t n, const void *i, void *o)
{
	return feedback8(c, n, i, o, 0);
}
static int cfb8_decrypt(void *c, size_t n, const void *i, void *o)
{
	return feedback8(c, n, i, o, 1);
}
static int ofb_crypt(void *ctx, size_t n, const void *input, void *output)
{
	const struct ccmode_ecb *e = ecb(ctx);
	size_t used, block = e->block_size;
	memcpy(&used, (unsigned char *)ctx + 8, 8);
	unsigned char *pad = (unsigned char *)ctx + 16, *keys = pad + rounded(block);
	const unsigned char *in = input;
	unsigned char *out = output;
	while (n--) {
		if (used == block) {
			e->ecb(keys, 1, pad, pad);
			used = 0;
		}
		*out++ = *in++ ^ pad[used++];
	}
	memcpy((unsigned char *)ctx + 8, &used, 8);
	return 0;
}
extern const struct ccmode_ecb ccaes_arm_ecb_encrypt_mode;
EXPORT const struct ccmode_stream ccaes_arm_cfb_encrypt_mode = {
    748, 1, cfb_init, aes_cfb_encrypt, &ccaes_arm_ecb_encrypt_mode};
EXPORT const struct ccmode_stream ccaes_arm_cfb_decrypt_mode = {
    748, 1, cfb_init, aes_cfb_decrypt, &ccaes_arm_ecb_encrypt_mode};
static const struct ccmode_stream cfb8_enc = {
    288, 1, cfb8_init, cfb8_encrypt, &ccaes_arm_ecb_encrypt_mode};
static const struct ccmode_stream cfb8_dec = {
    288, 1, cfb8_init, cfb8_decrypt, &ccaes_arm_ecb_encrypt_mode};
EXPORT const struct ccmode_stream ccaes_arm_ofb_crypt_mode = {
    504, 1, ofb_init, ofb_crypt, &ccaes_arm_ecb_encrypt_mode};
EXPORT const struct ccmode_stream *ccaes_cfb_encrypt_mode(void)
{
	return &ccaes_arm_cfb_encrypt_mode;
}
EXPORT const struct ccmode_stream *ccaes_cfb_decrypt_mode(void)
{
	return &ccaes_arm_cfb_decrypt_mode;
}
EXPORT const struct ccmode_stream *ccaes_cfb8_encrypt_mode(void)
{
	return &cfb8_enc;
}
EXPORT const struct ccmode_stream *ccaes_cfb8_decrypt_mode(void)
{
	return &cfb8_dec;
}
EXPORT const struct ccmode_stream *ccaes_ofb_crypt_mode(void)
{
	return &ccaes_arm_ofb_crypt_mode;
}
EXPORT void ccmode_factory_cfb_encrypt(struct ccmode_stream *m, const struct ccmode_ecb *e)
{
	*m = ccaes_arm_cfb_encrypt_mode;
	m->size = 16 + 2 * rounded(e->block_size) + rounded(e->size);
	m->crypt = cfb_encrypt;
	m->custom = e;
}
EXPORT void ccmode_factory_cfb_decrypt(struct ccmode_stream *m, const struct ccmode_ecb *e)
{
	ccmode_factory_cfb_encrypt(m, e);
	m->crypt = cfb_decrypt;
}
EXPORT void ccmode_factory_cfb8_encrypt(struct ccmode_stream *m, const struct ccmode_ecb *e)
{
	*m = cfb8_enc;
	m->size = 8 + 2 * rounded(e->block_size) + rounded(e->size);
	m->custom = e;
}
EXPORT void ccmode_factory_cfb8_decrypt(struct ccmode_stream *m, const struct ccmode_ecb *e)
{
	ccmode_factory_cfb8_encrypt(m, e);
	m->crypt = cfb8_decrypt;
}
EXPORT void ccmode_factory_ofb_crypt(struct ccmode_stream *m, const struct ccmode_ecb *e)
{
	*m = ccaes_arm_ofb_crypt_mode;
	m->size = 16 + rounded(e->block_size) + rounded(e->size);
	m->custom = e;
}
#define STREAM_WRAPPERS(prefix)                                                                    \
	EXPORT size_t prefix##_context_size(const struct ccmode_stream *m)                         \
	{                                                                                          \
		return m->size;                                                                    \
	}                                                                                          \
	EXPORT size_t prefix##_block_size(const struct ccmode_stream *m)                           \
	{                                                                                          \
		return m->block_size;                                                              \
	}                                                                                          \
	EXPORT int prefix##_init(                                                                  \
	    const struct ccmode_stream *m, void *c, size_t n, const void *k, const void *iv)       \
	{                                                                                          \
		return m->init(m, c, n, k, iv);                                                    \
	}                                                                                          \
	EXPORT int prefix##_update(                                                                \
	    const struct ccmode_stream *m, void *c, size_t n, const void *i, void *o)              \
	{                                                                                          \
		return m->crypt(c, n, i, o);                                                       \
	}                                                                                          \
	EXPORT int prefix##_one_shot(const struct ccmode_stream *m, size_t ksize, const void *k,   \
	    const void *iv, size_t n, const void *i, void *o)                                      \
	{                                                                                          \
		_Alignas(16) unsigned char c[m->size];                                             \
		int r = m->init(m, c, ksize, k, iv);                                               \
		if (!r)                                                                            \
			r = m->crypt(c, n, i, o);                                                  \
		wipe(c, sizeof(c));                                                                \
		return r;                                                                          \
	}
STREAM_WRAPPERS(cccfb)
STREAM_WRAPPERS(cccfb8)
STREAM_WRAPPERS(ccofb)
