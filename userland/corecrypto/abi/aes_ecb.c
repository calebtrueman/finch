/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Apple Silicon AES contexts hold round keys in forward order, followed
 * by the byte offset of the last round key. OpenSSL's ARM AES instructions
 * use the same bytes but count rounds and reverse the decryption keys.
 */
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/aes.h>
#include <stdint.h>
#include <string.h>
#include "ccmode.h"
#define EXPORT __attribute__((visibility("default")))

/* These routines are pinned with OpenSSL, not taken from the host library. */
int aes_v8_set_encrypt_key(const unsigned char *, int, AES_KEY *);
int aes_v8_set_decrypt_key(const unsigned char *, int, AES_KEY *);
void aes_v8_encrypt(const unsigned char *, unsigned char *, const AES_KEY *);
void aes_v8_decrypt(const unsigned char *, unsigned char *, const AES_KEY *);

struct aes_context {
	unsigned char keys[240];
	uint32_t last;
};
_Static_assert(sizeof(struct aes_context) == 244, "AES context size");
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}

static int setup(void *context, size_t length, const void *key, int decrypt)
{
	if (length == 16 || length == 24 || length == 32)
		length *= 8;
	if (length != 128 && length != 192 && length != 256)
		return -7;
	AES_KEY expanded;
	int r = decrypt ? aes_v8_set_decrypt_key(key, (int)length, &expanded)
	                : aes_v8_set_encrypt_key(key, (int)length, &expanded);
	if (r) {
		wipe(&expanded, sizeof(expanded));
		return -7;
	}
	struct aes_context *ctx = context;
	const unsigned char *keys = (const void *)expanded.rd_key;
	for (int round = 0; round <= expanded.rounds; round++)
		memcpy(ctx->keys + 16 * round,
		    keys + 16 * (decrypt ? expanded.rounds - round : round), 16);
	if (length == 192) {
		/* Apple's expansion finishes its six-word group, leaving two
         * extra words after the last round. Preserve those visible bytes. */
		AES_KEY forward;
		const unsigned char *f = keys;
		if (decrypt) {
			aes_v8_set_encrypt_key(key, 192, &forward);
			f = (const void *)forward.rd_key;
		}
		for (size_t i = 0; i < 4; i++) {
			ctx->keys[208 + i] = f[184 + i] ^ f[204 + i];
			ctx->keys[212 + i] = f[188 + i] ^ ctx->keys[208 + i];
		}
		wipe(&forward, sizeof(forward));
	}
	ctx->last = (uint32_t)expanded.rounds * 16;
	wipe(&expanded, sizeof(expanded));
	return 0;
}
static int encrypt_init(const struct ccmode_ecb *mode, void *ctx, size_t n, const void *key)
{
	(void)mode;
	return setup(ctx, n, key, 0);
}
static int decrypt_init(const struct ccmode_ecb *mode, void *ctx, size_t n, const void *key)
{
	(void)mode;
	return setup(ctx, n, key, 1);
}

static int crypt(const void *context, size_t count, const void *input, void *output, int decrypt)
{
	const struct aes_context *ctx = context;
	if (ctx->last != 160 && ctx->last != 192 && ctx->last != 224)
		return -7;
	AES_KEY expanded;
	expanded.rounds = (int)ctx->last / 16;
	unsigned char *keys = (void *)expanded.rd_key;
	for (int round = 0; round <= expanded.rounds; round++)
		memcpy(keys + 16 * round,
		    ctx->keys + 16 * (decrypt ? expanded.rounds - round : round), 16);
	const unsigned char *in = input;
	unsigned char *out = output;
	while (count--) {
		if (decrypt)
			aes_v8_decrypt(in, out, &expanded);
		else
			aes_v8_encrypt(in, out, &expanded);
		in += 16;
		out += 16;
	}
	wipe(&expanded, sizeof(expanded));
	return 0;
}
static int encrypt_blocks(const void *ctx, size_t n, const void *in, void *out)
{
	return crypt(ctx, n, in, out, 0);
}
static int decrypt_blocks(const void *ctx, size_t n, const void *in, void *out)
{
	return crypt(ctx, n, in, out, 1);
}

EXPORT const struct ccmode_ecb ccaes_arm_ecb_encrypt_mode = {244, 16, encrypt_init, encrypt_blocks};
EXPORT const struct ccmode_ecb ccaes_arm_ecb_decrypt_mode = {244, 16, decrypt_init, decrypt_blocks};
EXPORT const struct ccmode_ecb *ccaes_ecb_encrypt_mode(void)
{
	return &ccaes_arm_ecb_encrypt_mode;
}
EXPORT const struct ccmode_ecb *ccaes_ecb_decrypt_mode(void)
{
	return &ccaes_arm_ecb_decrypt_mode;
}
EXPORT size_t ccecb_context_size(const struct ccmode_ecb *mode)
{
	return mode->size;
}
EXPORT size_t ccecb_block_size(const struct ccmode_ecb *mode)
{
	return mode->block_size;
}
EXPORT int ccecb_init(const struct ccmode_ecb *mode, void *ctx, size_t n, const void *key)
{
	return mode->init(mode, ctx, n, key);
}
EXPORT int ccecb_update(
    const struct ccmode_ecb *mode, const void *ctx, size_t n, const void *in, void *out)
{
	return mode->ecb(ctx, n, in, out);
}
EXPORT int ccecb_one_shot_explicit(const struct ccmode_ecb *mode, size_t key_size,
    size_t block_size, size_t count, const void *key, const void *in, void *out)
{
	if (block_size != mode->block_size)
		return -7;
	_Alignas(16) unsigned char context[mode->size];
	int r = mode->init(mode, context, key_size, key);
	if (!r)
		r = mode->ecb(context, count, in, out);
	wipe(context, sizeof(context));
	return r;
}
EXPORT int ccecb_one_shot(const struct ccmode_ecb *mode, size_t key_size, const void *key,
    size_t count, const void *in, void *out)
{
	return ccecb_one_shot_explicit(mode, key_size, mode->block_size, count, key, in, out);
}
