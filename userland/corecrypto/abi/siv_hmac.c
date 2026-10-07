/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "siv_hmac.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
struct sh_ctx {
	const struct ccmode_siv_hmac *m;
	size_t key_n, tag_n, state;
	unsigned char mac_key[32], ctr_key[32], hmac[504];
};
extern const struct ccmode_ctr *ccaes_ctr_crypt_mode(void);
extern int ccctr_one_shot(
    const struct ccmode_ctr *, size_t, const void *, const void *, size_t, const void *, void *);
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}
static int reset(void *p)
{
	struct sh_ctx *c = p;
	cchmac_init(c->m->di, c->hmac, c->key_n / 2, c->mac_key);
	c->state = 2;
	return 0;
}
static int init(const struct ccmode_siv_hmac *m, void *p, size_t n, const void *k, size_t tn)
{
	struct sh_ctx *c = p;
	c->m = m;
	if ((n != 32 && n != 48 && n != 64) || n / 2 > m->di->state_size)
		return -70;
	if (tn > m->di->output_size)
		return -100;
	if (tn < 20)
		return -101;
	if (m->ctr->ecb_block_size != 16)
		return -70;
	c->key_n = n;
	memcpy(c->ctr_key, k, n / 2);
	memcpy(c->mac_key, (const char *)k + n / 2, n / 2);
	c->tag_n = tn;
	return reset(c);
}
static void auth_backend(struct sh_ctx *c, size_t n, const void *p, unsigned char type)
{
	unsigned char tail[9];
	for (size_t i = 0; i < 8; i++)
		tail[i] = n >> (56 - i * 8);
	tail[8] = type;
	cchmac_update(c->m->di, c->hmac, n, p);
	cchmac_update(c->m->di, c->hmac, 9, tail);
}
static int auth(void *p, size_t n, const void *in)
{
	struct sh_ctx *c = p;
	if (c->state != 2 && c->state != 4)
		return -68;
	if (!n)
		return -103;
	auth_backend(c, n, in, 'A');
	c->state = 4;
	return 0;
}
static int nonce(void *p, size_t n, const void *in)
{
	struct sh_ctx *c = p;
	if (c->state != 2 && c->state != 4)
		return -68;
	if (!n)
		return -102;
	auth_backend(c, n, in, 'N');
	c->state = 6;
	return 0;
}
static int finish(struct sh_ctx *c, size_t n, const void *in, void *tag)
{
	if (c->state != 2 && c->state != 4 && c->state != 6) {
		c->state = 255;
		return -68;
	}
	unsigned char full[c->m->di->output_size];
	if (!n && c->state == 2) {
		const unsigned char empty[4] = {1, 2, 3, 4};
		cchmac(c->m->di, c->key_n / 2, c->mac_key, 4, empty, full);
	} else {
		auth_backend(c, n, in, 'P');
		cchmac_final(c->m->di, c->hmac, full);
	}
	memcpy(tag, full, c->tag_n);
	wipe(full, sizeof(full));
	c->state = 5;
	return 0;
}
static int temp_key(struct sh_ctx *c, unsigned char key[32], const void *tag)
{
	unsigned char iv[16], zero[64] = {0}, stream[64];
	memcpy(iv, tag, 16);
	iv[15] &= 0x7f;
	int r = ccctr_one_shot(c->m->ctr, c->key_n / 2, c->ctr_key, iv, c->key_n, zero, stream);
	/* Keep the first half of each AES block. The host leaves holes for 48/64-byte
       master keys; completing every byte avoids dependence on old stack data. */
	for (size_t i = 0; i < c->key_n / 16; i++)
		memcpy(key + i * 8, stream + i * 16, 8);
	wipe(iv, 16);
	wipe(stream, sizeof(stream));
	return r;
}
static int encrypt(void *p, size_t n, const void *in, void *out)
{
	struct sh_ctx *c = p;
	if (c->m->ctr->ecb_block_size != 16)
		return -70;
	unsigned char tag[64], key[32], iv[16];
	int r = finish(c, n, in, tag);
	if (r)
		return r;
	memcpy(iv, tag, 16);
	r = temp_key(c, key, tag);
	if (!r) {
		iv[8] &= 0x7f;
		iv[12] &= 0x7f;
		r = ccctr_one_shot(c->m->ctr, c->key_n / 2, key, iv, n, in, (char *)out + c->tag_n);
	}
	if (r) {
		wipe(out, n + c->tag_n);
		reset(c);
	} else
		memcpy(out, tag, c->tag_n);
	wipe(tag, sizeof(tag));
	wipe(key, sizeof(key));
	wipe(iv, 16);
	return r;
}
static int decrypt(void *p, size_t n, const void *in, void *out)
{
	struct sh_ctx *c = p;
	if (c->m->ctr->ecb_block_size != 16)
		return -70;
	if (c->state != 2 && c->state != 4 && c->state != 6)
		return -68;
	if (n < c->tag_n)
		return -67;
	size_t pn = n - c->tag_n;
	unsigned char tag[64], check[64], key[32], iv[16];
	memcpy(tag, in, c->tag_n);
	memcpy(iv, tag, 16);
	int r = temp_key(c, key, tag);
	if (!r) {
		iv[8] &= 0x7f;
		iv[12] &= 0x7f;
		r = ccctr_one_shot(
		    c->m->ctr, c->key_n / 2, key, iv, pn, (const char *)in + c->tag_n, out);
		int rr = finish(c, pn, out, check);
		unsigned diff = r | rr;
		for (size_t i = 0; i < c->tag_n; i++)
			diff |= tag[i] ^ check[i];
		r = diff ? -104 : 0;
	}
	if (r) {
		wipe(out, pn);
		reset(c);
		r = -104;
	}
	wipe(tag, sizeof(tag));
	wipe(check, sizeof(check));
	wipe(key, sizeof(key));
	wipe(iv, 16);
	return r;
}
static void factory(
    struct ccmode_siv_hmac *m, const struct ccdigest_info *d, const struct ccmode_ctr *t, int dec)
{
	*m = (struct ccmode_siv_hmac){
	    600, 1, init, nonce, auth, dec ? decrypt : encrypt, reset, d, t};
}
EXPORT void ccmode_factory_siv_hmac_encrypt(
    struct ccmode_siv_hmac *m, const struct ccdigest_info *d, const struct ccmode_ctr *t)
{
	factory(m, d, t, 0);
}
EXPORT void ccmode_factory_siv_hmac_decrypt(
    struct ccmode_siv_hmac *m, const struct ccdigest_info *d, const struct ccmode_ctr *t)
{
	factory(m, d, t, 1);
}
EXPORT const struct ccmode_siv_hmac *ccaes_siv_hmac_sha256_encrypt_mode(void)
{
	static struct ccmode_siv_hmac m;
	factory(&m, ccsha256_di(), ccaes_ctr_crypt_mode(), 0);
	return &m;
}
EXPORT const struct ccmode_siv_hmac *ccaes_siv_hmac_sha256_decrypt_mode(void)
{
	static struct ccmode_siv_hmac m;
	factory(&m, ccsha256_di(), ccaes_ctr_crypt_mode(), 1);
	return &m;
}
EXPORT size_t ccsiv_hmac_context_size(const struct ccmode_siv_hmac *m)
{
	return m->size;
}
EXPORT size_t ccsiv_hmac_block_size(const struct ccmode_siv_hmac *m)
{
	return m->block_size;
}
EXPORT size_t ccsiv_hmac_ciphertext_size(const void *p, size_t n)
{
	return n + ((const struct sh_ctx *)p)->tag_n;
}
EXPORT size_t ccsiv_hmac_plaintext_size(const void *p, size_t n)
{
	size_t t = ((const struct sh_ctx *)p)->tag_n;
	return n < t ? 0 : n - t;
}
EXPORT int ccsiv_hmac_init(
    const struct ccmode_siv_hmac *m, void *c, size_t n, const void *k, size_t t)
{
	return m->init(m, c, n, k, t);
}
EXPORT int ccsiv_hmac_aad(const struct ccmode_siv_hmac *m, void *c, size_t n, const void *p)
{
	return m->aad(c, n, p);
}
EXPORT int ccsiv_hmac_set_nonce(const struct ccmode_siv_hmac *m, void *c, size_t n, const void *p)
{
	return m->nonce(c, n, p);
}
EXPORT int ccsiv_hmac_crypt(
    const struct ccmode_siv_hmac *m, void *c, size_t n, const void *p, void *o)
{
	return m->crypt(c, n, p, o);
}
EXPORT int ccsiv_hmac_reset(const struct ccmode_siv_hmac *m, void *c)
{
	return m->reset(c);
}
EXPORT int ccsiv_hmac_one_shot(const struct ccmode_siv_hmac *m, size_t kn, const void *k, size_t tn,
    size_t nn, const void *nonce_data, size_t an, const void *aad, size_t n, const void *in,
    void *out)
{
	_Alignas(16) unsigned char c[m->size];
	int r = m->init(m, c, kn, k, tn);
	if (!r && (unsigned)an)
		r = m->aad(c, (unsigned)an, aad);
	if (!r && (unsigned)nn)
		r = m->nonce(c, (unsigned)nn, nonce_data);
	if (!r)
		r = m->crypt(c, n, in, out);
	wipe(c, m->size);
	return r;
}
