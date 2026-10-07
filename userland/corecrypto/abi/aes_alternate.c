/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/aes.h>
#include "ccmode.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
int aes_v8_set_encrypt_key(const unsigned char *, int, AES_KEY *);
int aes_v8_set_decrypt_key(const unsigned char *, int, AES_KEY *);
void aes_v8_encrypt(const unsigned char *, unsigned char *, const AES_KEY *);
void aes_v8_decrypt(const unsigned char *, unsigned char *, const AES_KEY *);
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}
static int keybits(size_t n)
{
	if (n == 16 || n == 24 || n == 32)
		n *= 8;
	return n == 128 || n == 192 || n == 256 ? (int)n : 0;
}
static int ltc_init(const struct ccmode_ecb *m, void *p, size_t n, const void *k)
{
	(void)m;
	int bits = keybits(n);
	if (!bits)
		return -7;
	AES_KEY enc, dec;
	aes_v8_set_encrypt_key(k, bits, &enc);
	aes_v8_set_decrypt_key(k, bits, &dec);
	size_t bytes = 16 * (enc.rounds + 1);
	memcpy(p, enc.rd_key, bytes);
	uint32_t last = 16 * enc.rounds;
	memcpy((char *)p + 240, &last, 4);
	memcpy((char *)p + 244, dec.rd_key, bytes);
	memcpy((char *)p + 484, &last, 4);
	wipe(&enc, sizeof(enc));
	wipe(&dec, sizeof(dec));
	return 0;
}
static int ltc_crypt(const void *p, size_t n, const void *in, void *out, int dec)
{
	AES_KEY key;
	uint32_t last;
	const char *ctx = (const char *)p + (dec ? 244 : 0);
	memcpy(&last, ctx + 240, 4);
	if (last != 160 && last != 192 && last != 224)
		return -7;
	key.rounds = last / 16;
	memcpy(key.rd_key, ctx, last + 16);
	while (n--) {
		if (dec)
			aes_v8_decrypt(in, out, &key);
		else
			aes_v8_encrypt(in, out, &key);
		in = (const char *)in + 16;
		out = (char *)out + 16;
	}
	wipe(&key, sizeof(key));
	return 0;
}
static int ltc_enc(const void *p, size_t n, const void *i, void *o)
{
	return ltc_crypt(p, n, i, o, 0);
}
static int ltc_dec(const void *p, size_t n, const void *i, void *o)
{
	return ltc_crypt(p, n, i, o, 1);
}
static void round_key(const void *p, size_t round, void *out)
{
	memcpy(out, (const char *)p + round * 16, 16);
}
struct ecb_extended {
	struct ccmode_ecb base;
	void (*round_key)(const void *, size_t, void *);
	size_t implementation;
};
EXPORT const struct ecb_extended ccaes_ltc_ecb_encrypt_mode = {
    {488, 16, ltc_init, ltc_enc}, round_key, 11};
EXPORT const struct ecb_extended ccaes_ltc_ecb_decrypt_mode = {
    {488, 16, ltc_init, ltc_dec}, NULL, 11};
static int gladman_init(void *p, size_t n, const void *k, int dec)
{
	int bits = keybits(n);
	if (!bits)
		return -7;
	AES_KEY key;
	if (dec)
		aes_v8_set_decrypt_key(k, bits, &key);
	else
		aes_v8_set_encrypt_key(k, bits, &key);
	for (int r = 0; r <= key.rounds; r++)
		memcpy(
		    (char *)p + r * 16, (char *)key.rd_key + (dec ? key.rounds - r : r) * 16, 16);
	uint32_t rounds = key.rounds, one = 1;
	memcpy((char *)p + 240, &rounds, 4);
	memcpy((char *)p + 260, &one, 4);
	wipe(&key, sizeof(key));
	return 0;
}
static int gladman_enc_init(const struct ccmode_cbc *m, void *p, size_t n, const void *k)
{
	(void)m;
	return gladman_init(p, n, k, 0);
}
static int gladman_dec_init(const struct ccmode_cbc *m, void *p, size_t n, const void *k)
{
	(void)m;
	return gladman_init(p, n, k, 1);
}
static int gladman_crypt(
    const void *p, void *iv, size_t n, const void *input, void *output, int dec)
{
	AES_KEY key;
	uint32_t rounds;
	memcpy(&rounds, (const char *)p + 240, 4);
	if (rounds != 10 && rounds != 12 && rounds != 14)
		return -7;
	key.rounds = rounds;
	for (unsigned r = 0; r <= rounds; r++)
		memcpy(
		    (char *)key.rd_key + r * 16, (const char *)p + (dec ? rounds - r : r) * 16, 16);
	const unsigned char *in = input;
	unsigned char *out = output, *chain = iv, tmp[16], save[16];
	while (n--) {
		if (dec) {
			memcpy(save, in, 16);
			aes_v8_decrypt(in, tmp, &key);
			for (size_t i = 0; i < 16; i++)
				out[i] = tmp[i] ^ chain[i];
			memcpy(chain, save, 16);
		} else {
			for (size_t i = 0; i < 16; i++)
				tmp[i] = in[i] ^ chain[i];
			aes_v8_encrypt(tmp, out, &key);
			memcpy(chain, out, 16);
		}
		in += 16;
		out += 16;
	}
	wipe(&key, sizeof(key));
	wipe(tmp, 16);
	wipe(save, 16);
	return 0;
}
static int gladman_enc(const void *p, void *v, size_t n, const void *i, void *o)
{
	return gladman_crypt(p, v, n, i, o, 0);
}
static int gladman_dec(const void *p, void *v, size_t n, const void *i, void *o)
{
	return gladman_crypt(p, v, n, i, o, 1);
}
EXPORT const struct ccmode_cbc ccaes_gladman_cbc_encrypt_mode = {
    264, 16, gladman_enc_init, gladman_enc, NULL};
EXPORT const struct ccmode_cbc ccaes_gladman_cbc_decrypt_mode = {
    264, 16, gladman_dec_init, gladman_dec, NULL};
EXPORT int ccaes_unwind(size_t n, const void *key, void *out)
{
	if (n != 32)
		return -70;
	AES_KEY k;
	aes_v8_set_encrypt_key(key, 256, &k);
	memcpy(out, (const char *)k.rd_key + 224, 16);
	memcpy((char *)out + 16, (const char *)k.rd_key + 208, 16);
	wipe(&k, sizeof(k));
	return 0;
}
