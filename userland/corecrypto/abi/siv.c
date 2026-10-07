/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "siv.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
struct siv_ctx {
	const struct ccmode_siv *mode;
	size_t key_size, state;
	unsigned char mac_key[32], ctr_key[32], d[16];
};
extern const struct ccmode_cbc *ccaes_cbc_encrypt_mode(void);
extern const struct ccmode_ctr *ccaes_ctr_crypt_mode(void);
extern int cccmac_init(const struct ccmode_cbc *, void *, size_t, const void *);
extern int cccmac_update(void *, size_t, const void *);
extern int cccmac_final_generate(void *, size_t, void *);
extern int cccmac_one_shot_generate(
    const struct ccmode_cbc *, size_t, const void *, size_t, const void *, size_t, void *);
extern int ccctr_one_shot(
    const struct ccmode_ctr *, size_t, const void *, const void *, size_t, const void *, void *);
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}
static void dbl(unsigned char *d)
{
	unsigned top = d[0] >> 7, carry = 0;
	for (size_t i = 16; i--;) {
		unsigned next = d[i] >> 7;
		d[i] = (d[i] << 1) | carry;
		carry = next;
	}
	d[15] ^= (0 - top) & 0x87;
}
static int mac(struct siv_ctx *c, size_t n, const void *p, void *out)
{
	return cccmac_one_shot_generate(c->mode->cbc, c->key_size / 2, c->mac_key, n, p, 16, out);
}
static int reset(void *p)
{
	struct siv_ctx *c = p;
	if (c->mode->cbc->block_size != 16)
		return -70;
	unsigned char zero[16] = {0};
	mac(c, 16, zero, c->d);
	c->state = 2;
	return 0;
}
static int init(const struct ccmode_siv *m, void *p, size_t n, const void *key)
{
	struct siv_ctx *c = p;
	c->mode = m;
	if (n != 32 && n != 48 && n != 64)
		return -70;
	c->key_size = n;
	if (m->cbc->block_size != 16)
		return -70;
	memcpy(c->mac_key, key, n / 2);
	memcpy(c->ctr_key, (const char *)key + n / 2, n / 2);
	return reset(p);
}
static int auth(void *p, size_t n, const void *in)
{
	struct siv_ctx *c = p;
	if (c->mode->cbc->block_size != 16)
		return -70;
	if (!n)
		return 0;
	unsigned char tag[16];
	dbl(c->d);
	mac(c, n, in, tag);
	for (size_t i = 0; i < 16; i++)
		c->d[i] ^= tag[i];
	c->state = 4;
	wipe(tag, 16);
	return 0;
}
static int finish(struct siv_ctx *c, size_t n, const void *input, unsigned char tag[16])
{
	if (c->mode->cbc->block_size != 16) {
		c->state = 255;
		return -70;
	}
	if (c->state != 2 && c->state != 4) {
		c->state = 255;
		return -68;
	}
	const unsigned char *in = input;
	unsigned char tail[32] = {0};
	if (n >= 16) {
		size_t prefix = (n & ~(size_t)15) - 16, left = n - prefix;
		memcpy(tail, in + prefix, left);
		for (size_t i = 0; i < 16; i++)
			tail[left - 16 + i] ^= c->d[i];
		const struct ccmode_cbc *cbc = c->mode->cbc;
		size_t z = 80 + cbc->size + cbc->block_size;
		_Alignas(16) unsigned char ctx[z];
		cccmac_init(cbc, ctx, c->key_size / 2, c->mac_key);
		cccmac_update(ctx, prefix, in);
		cccmac_update(ctx, left, tail);
		cccmac_final_generate(ctx, 16, tag);
		wipe(ctx, z);
	} else if (!n && c->state == 2) {
		tail[15] = 1;
		mac(c, 16, tail, tag);
	} else {
		dbl(c->d);
		if (n)
			memcpy(tail, in, n);
		tail[n] = 0x80;
		for (size_t i = 0; i < 16; i++)
			tail[i] ^= c->d[i];
		mac(c, 16, tail, tag);
	}
	wipe(tail, sizeof(tail));
	c->state = 5;
	return 0;
}
static int encrypt(void *p, size_t n, const void *in, void *out)
{
	struct siv_ctx *c = p;
	if (c->mode->cbc->block_size != 16)
		return -70;
	if ((uintptr_t)in - 16 < (uintptr_t)out && (uintptr_t)out < (uintptr_t)in + n)
		return -105;
	unsigned char tag[16];
	int r = finish(c, n, in, tag);
	if (r)
		return r;
	memcpy(c->d, tag, 16);
	c->d[8] &= 0x7f;
	c->d[12] &= 0x7f;
	r = ccctr_one_shot(
	    c->mode->ctr, c->key_size / 2, c->ctr_key, c->d, n, in, (unsigned char *)out + 16);
	memcpy(out, tag, 16);
	if (r)
		wipe(out, n + 16);
	wipe(tag, 16);
	return r;
}
static int decrypt(void *p, size_t n, const void *in, void *out)
{
	struct siv_ctx *c = p;
	if (c->mode->cbc->block_size != 16)
		return -70;
	if (c->state != 2 && c->state != 4)
		return -68;
	if (n < 16)
		return -67;
	unsigned char tag[16], iv[16], check[16];
	memcpy(tag, in, 16);
	memcpy(iv, in, 16);
	iv[8] &= 0x7f;
	iv[12] &= 0x7f;
	int r = ccctr_one_shot(c->mode->ctr, c->key_size / 2, c->ctr_key, iv, n - 16,
	    (const unsigned char *)in + 16, out);
	if (!r)
		r = finish(c, n - 16, out, check);
	if (!r) {
		unsigned diff = 0;
		for (size_t i = 0; i < 16; i++)
			diff |= check[i] ^ tag[i];
		if (diff)
			r = -69;
	}
	if (r)
		wipe(out, n - 16);
	wipe(tag, 16);
	wipe(iv, 16);
	wipe(check, 16);
	return r;
}
static void factory(
    struct ccmode_siv *m, const struct ccmode_cbc *b, const struct ccmode_ctr *t, int dec)
{
	*m = (struct ccmode_siv){104, 1, init, auth, auth, dec ? decrypt : encrypt, reset, b, t};
}
EXPORT void ccmode_factory_siv_encrypt(
    struct ccmode_siv *m, const struct ccmode_cbc *b, const struct ccmode_ctr *t)
{
	factory(m, b, t, 0);
}
EXPORT void ccmode_factory_siv_decrypt(
    struct ccmode_siv *m, const struct ccmode_cbc *b, const struct ccmode_ctr *t)
{
	factory(m, b, t, 1);
}
EXPORT const struct ccmode_siv *ccaes_siv_encrypt_mode(void)
{
	static struct ccmode_siv m;
	factory(&m, ccaes_cbc_encrypt_mode(), ccaes_ctr_crypt_mode(), 0);
	return &m;
}
EXPORT const struct ccmode_siv *ccaes_siv_decrypt_mode(void)
{
	static struct ccmode_siv m;
	factory(&m, ccaes_cbc_encrypt_mode(), ccaes_ctr_crypt_mode(), 1);
	return &m;
}
EXPORT size_t ccsiv_context_size(const struct ccmode_siv *m)
{
	return m->size;
}
EXPORT size_t ccsiv_block_size(const struct ccmode_siv *m)
{
	return m->block_size;
}
EXPORT size_t ccsiv_ciphertext_size(const struct ccmode_siv *m, size_t n)
{
	return n + m->cbc->block_size;
}
EXPORT size_t ccsiv_plaintext_size(const struct ccmode_siv *m, size_t n)
{
	return n < m->cbc->block_size ? 0 : n - m->cbc->block_size;
}
EXPORT int ccsiv_init(const struct ccmode_siv *m, void *c, size_t n, const void *k)
{
	return m->init(m, c, n, k);
}
EXPORT int ccsiv_set_nonce(const struct ccmode_siv *m, void *c, size_t n, const void *p)
{
	return m->nonce(c, n, p);
}
EXPORT int ccsiv_aad(const struct ccmode_siv *m, void *c, size_t n, const void *p)
{
	return m->aad(c, n, p);
}
EXPORT int ccsiv_crypt(const struct ccmode_siv *m, void *c, size_t n, const void *p, void *o)
{
	return m->crypt(c, n, p, o);
}
EXPORT int ccsiv_reset(const struct ccmode_siv *m, void *c)
{
	return m->reset(c);
}
EXPORT int ccsiv_one_shot(const struct ccmode_siv *m, size_t kn, const void *k, size_t nn,
    const void *nonce, size_t an, const void *aad, size_t n, const void *in, void *out)
{
	_Alignas(16) unsigned char c[m->size];
	int r = m->init(m, c, kn, k);
	if (!r)
		r = m->nonce(c, (unsigned)nn, nonce);
	if (!r)
		r = m->aad(c, (unsigned)an, aad);
	if (!r)
		r = m->crypt(c, n, in, out);
	wipe(c, m->size);
	return r;
}
