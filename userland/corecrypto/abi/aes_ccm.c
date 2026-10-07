/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccmode.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
struct ccm_key {
	const struct ccmode_ecb *ecb;
	unsigned char key[];
};
struct ccm_nonce {
	unsigned char counter[16], mac[16], tag_pad[16], stream_pad[16];
	uint32_t state, stream_used, mac_used, padding;
	size_t nonce_size, tag_size;
};
_Static_assert(sizeof(struct ccm_nonce) == 96, "CCM nonce size");
static void wipe(void *p, size_t n)
{
	volatile unsigned char *b = p;
	while (n--)
		*b++ = 0;
}
static void block(const struct ccm_key *k, const void *in, void *out)
{
	k->ecb->ecb(k->key, 1, in, out);
}
static int init(const struct ccmode_ccm *m, void *context, size_t n, const void *key)
{
	struct ccm_key *k = context;
	k->ecb = m->custom;
	return k->ecb->init(k->ecb, k->key, n, key);
}
static int reset(const void *key, void *nonce)
{
	(void)key;
	struct ccm_nonce *s = nonce;
	wipe(s->tag_pad, 16);
	wipe(s->stream_pad, 16);
	s->state = 1;
	s->stream_used = 0;
	s->mac_used = 0;
	s->nonce_size = 0;
	s->tag_size = 0;
	return 0;
}
static int set_iv(const void *key, void *nonce, size_t iv_size, const void *iv, size_t tag_size,
    size_t aad_size, size_t text_size)
{
	const struct ccm_key *k = key;
	struct ccm_nonce *s = nonce;
	if (k->ecb->block_size != 16)
		return -1;
	s->state = 1;
	wipe(s->stream_pad, 16);
	s->stream_used = 0;
	if (tag_size < 4 || tag_size > 16 || (tag_size & 1) || iv_size < 7 || iv_size > 13 ||
	    aad_size > UINT32_MAX)
		return -1;
	size_t width = 15 - iv_size;
	if (width < 8 && (text_size >> (8 * width)))
		return -1;
	s->nonce_size = iv_size;
	s->tag_size = tag_size;
	s->mac[0] = (unsigned char)(((tag_size - 2) * 4) | (aad_size ? 64 : 0) | (width - 1));
	memcpy(s->mac + 1, iv, iv_size);
	for (size_t i = 0; i < width; i++) {
		s->mac[15 - i] = (unsigned char)text_size;
		text_size >>= 8;
	}
	block(k, s->mac, s->mac);
	s->counter[0] = (unsigned char)(width - 1);
	memcpy(s->counter + 1, iv, iv_size);
	memset(s->counter + 1 + iv_size, 0, width);
	block(k, s->counter, s->tag_pad);
	s->mac_used = 0;
	s->state = aad_size ? 4 : 5;
	if (aad_size) {
		unsigned char header[6];
		size_t count;
		if (aad_size < 0xff00) {
			header[0] = (unsigned char)(aad_size >> 8);
			header[1] = (unsigned char)aad_size;
			count = 2;
		} else {
			header[0] = 255;
			header[1] = 254;
			for (size_t i = 0; i < 4; i++)
				header[5 - i] = (unsigned char)(aad_size >> (8 * i));
			count = 6;
		}
		for (size_t i = 0; i < count; i++)
			s->mac[i] ^= header[i];
		s->mac_used = (uint32_t)count;
	}
	return 0;
}
static void macdata(const struct ccm_key *k, struct ccm_nonce *s, size_t n, const void *input)
{
	const unsigned char *in = input;
	while (n--) {
		s->mac[s->mac_used++] ^= *in++;
		if (s->mac_used == 16) {
			block(k, s->mac, s->mac);
			s->mac_used = 0;
		}
	}
}
static int aad(const void *key, void *nonce, size_t n, const void *input)
{
	struct ccm_nonce *s = nonce;
	if (n && s->state != 4)
		return -68;
	macdata(key, s, n, input);
	return 0;
}
static int crypt(
    const void *key, void *nonce, size_t n, const void *input, void *output, int decrypt, int fast)
{
	const struct ccm_key *k = key;
	struct ccm_nonce *s = nonce;
	if (s->state == 4) {
		if (s->mac_used) {
			block(k, s->mac, s->mac);
			s->mac_used = 0;
		}
		s->state = 5;
	} else if (s->state != 5)
		return -68;
	const unsigned char *in = input;
	unsigned char *out = output;
	while (n) {
		if (fast && !s->stream_used && n >= 16) {
			unsigned char pad[16], plain[16];
			for (size_t i = 16; i > s->nonce_size + 1; i--)
				if (++s->counter[i - 1])
					break;
			block(k, s->counter, pad);
			for (size_t i = 0; i < 16; i++) {
				unsigned char source = in[i], dest = source ^ pad[i];
				plain[i] = decrypt ? dest : source;
				out[i] = dest;
			}
			macdata(k, s, 16, plain);
			wipe(pad, 16);
			wipe(plain, 16);
			in += 16;
			out += 16;
			n -= 16;
			continue;
		}
		n--;
		if (!s->stream_used) {
			for (size_t i = 16; i > s->nonce_size + 1; i--)
				if (++s->counter[i - 1])
					break;
			block(k, s->counter, s->stream_pad);
		}
		unsigned char source = *in++, dest = source ^ s->stream_pad[s->stream_used];
		unsigned char plain = decrypt ? dest : source;
		macdata(k, s, 1, &plain);
		*out++ = dest;
		s->stream_used = (s->stream_used + 1) % 16;
	}
	return 0;
}
static int encrypt(const void *k, void *n, size_t z, const void *i, void *o)
{
	return crypt(k, n, z, i, o, 0, 1);
}
static int decrypt(const void *k, void *n, size_t z, const void *i, void *o)
{
	return crypt(k, n, z, i, o, 1, 1);
}
static int generic_encrypt(const void *k, void *n, size_t z, const void *i, void *o)
{
	return crypt(k, n, z, i, o, 0, 0);
}
static int generic_decrypt(const void *k, void *n, size_t z, const void *i, void *o)
{
	return crypt(k, n, z, i, o, 1, 0);
}
static int finalize(const void *key, void *nonce, void *tag)
{
	const struct ccm_key *k = key;
	struct ccm_nonce *s = nonce;
	if (s->state == 1)
		return -68;
	if (s->mac_used)
		block(k, s->mac, s->mac);
	for (size_t i = 0; i < 16; i++)
		s->tag_pad[i] ^= s->mac[i];
	memcpy(tag, s->tag_pad, s->tag_size);
	return 0;
}
extern const struct ccmode_ecb ccaes_arm_ecb_encrypt_mode;
static const struct ccmode_ccm enc = {
    272, 96, 1, init, set_iv, aad, encrypt, finalize, reset, &ccaes_arm_ecb_encrypt_mode, 1, {0}};
static const struct ccmode_ccm dec = {
    272, 96, 1, init, set_iv, aad, decrypt, finalize, reset, &ccaes_arm_ecb_encrypt_mode, 0, {0}};
EXPORT const struct ccmode_ccm *ccaes_ccm_encrypt_mode(void)
{
	return &enc;
}
EXPORT const struct ccmode_ccm *ccaes_ccm_decrypt_mode(void)
{
	return &dec;
}
EXPORT void ccmode_factory_ccm_encrypt(struct ccmode_ccm *m, const struct ccmode_ecb *e)
{
	*m = enc;
	m->size = 8 + ((e->size + 7) & ~(size_t)7) + ((e->block_size + 7) & ~(size_t)7);
	m->custom = e;
	m->ccm = generic_encrypt;
}
EXPORT void ccmode_factory_ccm_decrypt(struct ccmode_ccm *m, const struct ccmode_ecb *e)
{
	ccmode_factory_ccm_encrypt(m, e);
	m->ccm = generic_decrypt;
	m->encdec = 0;
}
EXPORT size_t ccccm_context_size(const struct ccmode_ccm *m)
{
	return m->size;
}
EXPORT size_t ccccm_nonce_size(const struct ccmode_ccm *m)
{
	return m->nonce_size;
}
EXPORT size_t ccccm_block_size(const struct ccmode_ccm *m)
{
	return m->block_size;
}
EXPORT int ccccm_init(const struct ccmode_ccm *m, void *c, size_t n, const void *k)
{
	return m->init(m, c, n, k);
}
EXPORT int ccccm_set_iv(const struct ccmode_ccm *m, const void *c, void *nonce, size_t n,
    const void *iv, size_t tagsize, size_t aadsize, size_t textsize)
{
	return m->set_iv(c, nonce, n, iv, tagsize, aadsize, textsize);
}
EXPORT int ccccm_cbcmac(
    const struct ccmode_ccm *m, const void *c, void *nonce, size_t n, const void *in)
{
	return m->aad(c, nonce, n, in);
}
EXPORT int ccccm_aad(
    const struct ccmode_ccm *m, const void *c, void *nonce, size_t n, const void *in)
{
	return m->aad(c, nonce, n, in);
}
EXPORT int ccccm_update(
    const struct ccmode_ccm *m, const void *c, void *nonce, size_t n, const void *in, void *out)
{
	return m->ccm(c, nonce, n, in, out);
}
EXPORT int ccccm_encrypt(
    const struct ccmode_ccm *m, const void *c, void *nonce, size_t n, const void *in, void *out)
{
	return m->encdec == 1 ? m->ccm(c, nonce, n, in, out) : -68;
}
EXPORT int ccccm_decrypt(
    const struct ccmode_ccm *m, const void *c, void *nonce, size_t n, const void *in, void *out)
{
	return !(m->encdec & 1) ? m->ccm(c, nonce, n, in, out) : -68;
}
EXPORT int ccccm_finalize(const struct ccmode_ccm *m, const void *c, void *nonce, void *tag)
{
	return m->finalize(c, nonce, tag);
}
EXPORT int ccccm_finalize_and_generate_tag(
    const struct ccmode_ccm *m, const void *c, void *nonce, void *tag)
{
	return m->encdec == 1 ? m->finalize(c, nonce, tag) : -68;
}
EXPORT int ccccm_finalize_and_verify_tag(
    const struct ccmode_ccm *m, const void *c, void *nonce, const void *tag)
{
	if (m->encdec & 1)
		return -68;
	unsigned char expected[16];
	int r = m->finalize(c, nonce, expected);
	if (!r) {
		const struct ccm_nonce *s = nonce;
		const unsigned char *t = tag;
		unsigned char diff = 0;
		for (size_t i = 0; i < s->tag_size; i++)
			diff |= expected[i] ^ t[i];
		if (diff)
			r = -69;
	}
	wipe(expected, sizeof(expected));
	return r;
}
EXPORT int ccccm_reset(const struct ccmode_ccm *m, const void *c, void *nonce)
{
	return m->reset(c, nonce);
}
static int one_shot(const struct ccmode_ccm *m, size_t ksize, const void *k, size_t ivsize,
    const void *iv, size_t n, const void *in, void *out, size_t aadsize, const void *auth,
    size_t tagsize, void *tag, int verify)
{
	_Alignas(16) unsigned char c[m->size], nonce[m->nonce_size];
	int r = m->init(m, c, ksize, k);
	if (!r)
		r = m->set_iv(c, nonce, ivsize, iv, tagsize, aadsize, n);
	if (!r)
		r = m->aad(c, nonce, aadsize, auth);
	if (!r)
		r = m->ccm(c, nonce, n, in, out);
	if (!r)
		r = verify ? ccccm_finalize_and_verify_tag(m, c, nonce, tag)
		           : m->finalize(c, nonce, tag);
	wipe(c, sizeof(c));
	wipe(nonce, sizeof(nonce));
	return r;
}
EXPORT int ccccm_one_shot(const struct ccmode_ccm *m, size_t ksize, const void *k, size_t ivsize,
    const void *iv, size_t n, const void *in, void *out, size_t aadsize, const void *auth,
    size_t tagsize, void *tag)
{
	return one_shot(m, ksize, k, ivsize, iv, n, in, out, aadsize, auth, tagsize, tag, 0);
}
EXPORT int ccccm_one_shot_encrypt(const struct ccmode_ccm *m, size_t ksize, const void *k,
    size_t ivsize, const void *iv, size_t n, const void *in, void *out, size_t aadsize,
    const void *auth, size_t tagsize, void *tag)
{
	return m->encdec == 1
	    ? one_shot(m, ksize, k, ivsize, iv, n, in, out, aadsize, auth, tagsize, tag, 0)
	    : -68;
}
EXPORT int ccccm_one_shot_decrypt(const struct ccmode_ccm *m, size_t ksize, const void *k,
    size_t ivsize, const void *iv, size_t n, const void *in, void *out, size_t aadsize,
    const void *auth, size_t tagsize, void *tag)
{
	return !(m->encdec & 1)
	    ? one_shot(m, ksize, k, ivsize, iv, n, in, out, aadsize, auth, tagsize, tag, 1)
	    : -68;
}
