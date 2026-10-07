/* SPDX-License-Identifier: MIT OR Apache-2.0
 * SIGMA authenticated exchanges and the Exclave packet session format.
 */
#include "ccsigma.h"
#include "ccmode.h"
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#define API __attribute__((visibility("default")))
extern int ccec_generate_key_fips(ccec_const_cp_t, struct ccrng_state *, struct ccec_ctx *);
extern int ccec_x963_import_priv(ccec_const_cp_t, size_t, const void *, struct ccec_ctx *);
extern size_t ccec_compressed_x962_export_pub_size(ccec_const_cp_t);
extern int ccec_compressed_x962_export_pub(const struct ccec_ctx *, void *);
extern int ccec_compressed_x962_import_pub(
    ccec_const_cp_t, size_t, const void *, struct ccec_ctx *);
extern int ccec_sign_composite(
    const struct ccec_ctx *, size_t, const void *, void *, void *, struct ccrng_state *);
extern int ccec_verify_composite(
    const struct ccec_ctx *, size_t, const void *, const void *, const void *, bool *);
extern int ccecdh_compute_shared_secret(
    const struct ccec_ctx *, const struct ccec_ctx *, size_t *, void *, struct ccrng_state *);
extern const struct ccmode_cbc *ccaes_cbc_encrypt_mode(void);
extern const struct ccmode_ccm *ccaes_ccm_encrypt_mode(void);
extern const struct ccmode_ccm *ccaes_ccm_decrypt_mode(void);
extern int cccmac_one_shot_generate(
    const struct ccmode_cbc *, size_t, const void *, size_t, const void *, size_t, void *);
extern int ccccm_one_shot(const struct ccmode_ccm *, size_t, const void *, size_t, const void *,
    size_t, const void *, void *, size_t, const void *, size_t, void *);
extern int ccnistkdf_ctr_cmac(const struct ccmode_cbc *, unsigned, size_t, const void *, size_t,
    const void *, size_t, const void *, size_t, size_t, void *);
extern void cchmac(
    const struct ccdigest_info *, size_t, const void *, size_t, const void *, void *);
extern int cchkdf_extract(
    const struct ccdigest_info *, size_t, const void *, size_t, const void *, void *);
extern int cchkdf_expand(
    const struct ccdigest_info *, size_t, const void *, size_t, const void *, size_t, void *);
static size_t field(ccec_const_cp_t cp)
{
	return (cp->bitlen + 7) / 8;
}
static unsigned char *key_at(struct ccsigma_ctx *s, size_t index)
{
	size_t offset = 0;
	for (size_t j = 0; j < index; j++)
		offset += s->info->key_sizes[j];
	return s->info->keys(s) + offset;
}
API int ccsigma_init(
    const struct ccsigma_info *i, struct ccsigma_ctx *s, unsigned role, struct ccrng_state *r)
{
	s->info = i;
	s->role = role;
	return ccec_generate_key_fips(i->kex_cp, r, i->kex(s));
}
API int ccsigma_set_signing_function(struct ccsigma_ctx *s, ccsigma_sign_fn fn, void *context)
{
	s->sign = fn;
	s->sign_context = context;
	return 0;
}
static int local_sign(
    void *context, size_t n, const void *hash, size_t *sn, void *out, struct ccrng_state *r)
{
	struct ccsigma_ctx *s = context;
	if (*sn < s->info->signature_size)
		return -7;
	*sn = s->info->signature_size;
	return ccec_sign_composite(
	    s->info->sign_key(s), n, hash, out, (char *)out + field(s->info->sign_cp), r);
}
API int ccsigma_import_signing_key(struct ccsigma_ctx *s, size_t n, const void *in)
{
	int r = ccec_x963_import_priv(s->info->sign_cp, n, in, s->info->sign_key(s));
	if (!r)
		ccsigma_set_signing_function(s, local_sign, s);
	return r;
}
API int ccsigma_import_peer_verification_key(struct ccsigma_ctx *s, size_t n, const void *in)
{
	return ccec_x963_import_pub(s->info->sign_cp, n, in, s->info->peer_sign_key(s));
}
API int ccsigma_export_key_share(struct ccsigma_ctx *s, size_t *n, void *out)
{
	size_t z = ccec_compressed_x962_export_pub_size(s->info->kex_cp);
	int r = -7;
	if (*n >= z) {
		*n = z;
		r = ccec_compressed_x962_export_pub(s->info->kex(s), out);
	}
	if (r)
		OPENSSL_cleanse(out, *n);
	return r;
}
API int ccsigma_import_peer_key_share(struct ccsigma_ctx *s, size_t n, const void *in)
{
	return ccec_compressed_x962_import_pub(s->info->kex_cp, n, in, s->info->peer_kex(s));
}
API unsigned ccsigma_peer_role(struct ccsigma_ctx *s)
{
	return s->role == 0;
}
API struct ccec_ctx *ccsigma_kex_init_ctx(struct ccsigma_ctx *s)
{
	return s->role == 0 ? s->info->kex(s) : s->info->peer_kex(s);
}
API struct ccec_ctx *ccsigma_kex_resp_ctx(struct ccsigma_ctx *s)
{
	return s->role == 1 ? s->info->kex(s) : s->info->peer_kex(s);
}
API int ccsigma_derive_session_keys(
    struct ccsigma_ctx *s, size_t n, const void *in, struct ccrng_state *r)
{
	unsigned char shared[32];
	size_t size = field(s->info->kex_cp);
	if (size > sizeof shared)
		return -5;
	int ret =
	    ccecdh_compute_shared_secret(s->info->kex(s), s->info->peer_kex(s), &size, shared, r);
	if (!ret)
		ret = s->info->derive(s, size, shared, n, in);
	OPENSSL_cleanse(shared, sizeof shared);
	return ret;
}
API int ccsigma_compute_mac(
    struct ccsigma_ctx *s, size_t index, size_t n, const void *in, void *out)
{
	if (index >= s->info->key_count)
		return -7;
	return s->info->mac(s, s->info->key_sizes[index], key_at(s, index), n, in, out);
}
API int ccsigma_sign(
    struct ccsigma_ctx *s, void *out, size_t n, const void *in, struct ccrng_state *r)
{
	unsigned char hash[64];
	if (s->info->di->output_size > sizeof hash)
		return -5;
	int ret = s->info->mac_digest(s, s->role, n, in, hash);
	size_t z = s->info->signature_size;
	if (!ret)
		ret = s->sign(s->sign_context, s->info->di->output_size, hash, &z, out, r);
	OPENSSL_cleanse(hash, sizeof hash);
	return ret;
}
API int ccsigma_verify(struct ccsigma_ctx *s, const void *sig, size_t n, const void *in)
{
	unsigned char hash[64];
	if (s->info->di->output_size > sizeof hash)
		return -5;
	int ret = s->info->mac_digest(s, ccsigma_peer_role(s), n, in, hash);
	if (ret)
		return ret;
	size_t w = field(s->info->sign_cp), nl = s->info->sign_cp->n;
	const struct cczp *q = (const void *)((const char *)s->info->sign_cp + 32 + 40 * nl);
	BIGNUM *a = BN_bin2bn(sig, (int)w, NULL),
	       *b = BN_bin2bn((const unsigned char *)sig + w, (int)w, NULL),
	       *order = BN_lebin2bn((void *)q->data, (int)nl * 8, NULL);
	if (!a || !b || !order)
		ret = -13;
	else if (BN_is_zero(a) || BN_is_zero(b) || BN_cmp(a, order) >= 0 || BN_cmp(b, order) >= 0)
		ret = -7;
	else {
		bool valid = false;
		ret = ccec_verify_composite(s->info->peer_sign_key(s), s->info->di->output_size,
		    hash, sig, (const char *)sig + w, &valid);
		if (!ret && !valid)
			ret = -146;
	}
	BN_free(a);
	BN_free(b);
	BN_free(order);
	OPENSSL_cleanse(hash, sizeof hash);
	return ret;
}
API int ccsigma_seal(struct ccsigma_ctx *s, size_t ki, size_t vi, size_t an, const void *aad,
    size_t n, const void *in, void *out, void *tag)
{
	if (ki >= s->info->key_count || vi >= s->info->key_count)
		return -7;
	unsigned char *iv = key_at(s, vi);
	int r = s->info->seal(s, s->info->key_sizes[ki], key_at(s, ki), s->info->key_sizes[vi], iv,
	    an, aad, n, in, out, tag);
	if (!r)
		s->info->next_iv(s->info->key_sizes[vi], iv);
	return r;
}
API int ccsigma_open(struct ccsigma_ctx *s, size_t ki, size_t vi, size_t an, const void *aad,
    size_t n, const void *in, void *out, const void *tag)
{
	if (s->info->tag_size > 16)
		return -5;
	if (ki >= s->info->key_count || vi >= s->info->key_count)
		return -7;
	unsigned char *iv = key_at(s, vi), copy[16];
	memcpy(copy, tag, s->info->tag_size);
	int r = s->info->open(s, s->info->key_sizes[ki], key_at(s, ki), s->info->key_sizes[vi], iv,
	    an, aad, n, in, out, copy);
	if (!r)
		s->info->next_iv(s->info->key_sizes[vi], iv);
	return r;
}
API int ccsigma_clear_key(struct ccsigma_ctx *s, size_t i)
{
	if (i >= s->info->key_count)
		return -7;
	OPENSSL_cleanse(key_at(s, i), s->info->key_sizes[i]);
	return 0;
}
API void ccsigma_clear(struct ccsigma_ctx *s)
{
	s->info->clear(s);
}
API int ccsigma_session_init(struct ccsigma_ctx *s, size_t i, size_t n, const void *in,
    const struct ccsigma_session_info *info, struct ccsigma_session_ctx *tx,
    struct ccsigma_session_ctx *rx)
{
	if (i >= s->info->key_count)
		return -7;
	tx->info = rx->info = info;
	tx->direction = 0;
	rx->direction = 1;
	return info->init(s->role, s->info->key_sizes[i], key_at(s, i), n, in, tx, rx);
}
API int ccsigma_session_seal(struct ccsigma_session_ctx *s, size_t an, const void *aad, size_t n,
    const void *in, void *out, void *tag, uint64_t *sequence)
{
	if (s->direction)
		return -86;
	int r = s->info->seal(s, an, aad, n, in, out, tag);
	if (r) {
		if (out)
			OPENSSL_cleanse(out, n);
		if (tag)
			OPENSSL_cleanse(tag, s->info->tag_size);
	} else {
		*sequence = s->info->get_sequence(s);
		s->info->advance(s);
	}
	return r;
}
API int ccsigma_session_open(struct ccsigma_session_ctx *s, size_t an, const void *aad, size_t n,
    const void *in, void *out, const void *tag, uint64_t sequence)
{
	if (s->direction != 1)
		return -86;
	if (sequence < s->info->get_sequence(s))
		return -7;
	int r = s->info->open(s, an, aad, n, in, out, tag, sequence);
	if (r) {
		if (out)
			OPENSSL_cleanse(out, n);
	} else {
		if (sequence > s->info->get_sequence(s))
			s->info->set_sequence(s, sequence);
		s->info->advance(s);
	}
	return r;
}
API int ccsigma_session_export(struct ccsigma_session_ctx *s, size_t n, void *out)
{
	if (n < s->info->serialized_size())
		return -7;
	return s->info->export(s, out);
}
API int ccsigma_session_import(
    const struct ccsigma_session_info *i, struct ccsigma_session_ctx *s, size_t n, const void *in)
{
	if (n < i->serialized_size())
		return -7;
	s->info = i;
	return i->import(s, in);
}
API void ccsigma_session_clear(struct ccsigma_session_ctx *s)
{
	s->info->clear(s);
}
/* The preset contexts share the same key slots. */
static struct ccec_ctx *kex(struct ccsigma_ctx *s)
{
	return (void *)((char *)s + 32);
}
static struct ccec_ctx *peer_kex(struct ccsigma_ctx *s)
{
	return (void *)((char *)s + 176);
}
static struct ccec_ctx *sign_key(struct ccsigma_ctx *s)
{
	return (void *)((char *)s + 288);
}
static struct ccec_ctx *peer_sign_key(struct ccsigma_ctx *s)
{
	return (void *)((char *)s + 432);
}
static unsigned char *keys(struct ccsigma_ctx *s)
{
	return (void *)((char *)s + 544);
}
static void next_iv(size_t n, void *iv)
{
	unsigned char *p = iv;
	while (n)
		if (++p[--n])
			break;
}
static void clear_mfi(struct ccsigma_ctx *s)
{
	OPENSSL_cleanse(s, 752);
}
static void clear_ep(struct ccsigma_ctx *s)
{
	OPENSSL_cleanse(s, 816);
}
struct mfi_info {
	struct ccsigma_info base;
	const void *salt;
	size_t salt_size;
	const void *label;
	size_t label_size;
	const void *context;
	size_t context_size;
	const void *signature;
	size_t signature_size;
};
struct ep_info {
	struct ccsigma_info base;
	const struct ccdigest_info *kdf_di;
	const void *salt;
	size_t salt_size;
	const void *context;
	size_t context_size;
	const void *signature;
	size_t signature_size;
};
static int transcript_keys(struct ccsigma_ctx *s, const void *prefix, size_t pn, size_t n,
    const void *in, unsigned char *out, size_t *outn)
{
	size_t w = ccec_compressed_x962_export_pub_size(s->info->kex_cp);
	if (pn > 256 || w > (256 - pn) / 2 || n > 256 - pn - 2 * w)
		return -7;
	memcpy(out, prefix, pn);
	int r = ccec_compressed_x962_export_pub(ccsigma_kex_init_ctx(s), out + pn);
	if (!r)
		r = ccec_compressed_x962_export_pub(ccsigma_kex_resp_ctx(s), out + pn + w);
	if (!r) {
		memcpy(out + pn + 2 * w, in, n);
		*outn = pn + 2 * w + n;
	}
	return r;
}
static int mfi_derive(
    struct ccsigma_ctx *s, size_t n, const void *secret, size_t cn, const void *ctx)
{
	const struct mfi_info *i = (const void *)s->info;
	unsigned char seed[16], info[256];
	size_t in = 0;
	int r = transcript_keys(s, i->context, i->context_size, cn, ctx, info, &in);
	if (!r)
		r = cccmac_one_shot_generate(
		    ccaes_cbc_encrypt_mode(), i->salt_size, i->salt, n, secret, 16, seed);
	if (!r)
		r = ccnistkdf_ctr_cmac(ccaes_cbc_encrypt_mode(), 32, 16, seed, i->label_size,
		    i->label, in, info, s->info->keys_size, 4, s->info->keys(s));
	OPENSSL_cleanse(seed, sizeof seed);
	return r;
}
static int ep_derive(
    struct ccsigma_ctx *s, size_t n, const void *secret, size_t cn, const void *ctx)
{
	const struct ep_info *i = (const void *)s->info;
	unsigned char seed[64], info[256];
	size_t in = 0;
	int r = transcript_keys(s, i->context, i->context_size, cn, ctx, info, &in);
	if (!r)
		r = cchkdf_extract(i->kdf_di, i->salt_size, i->salt, n, secret, seed);
	if (!r)
		r = cchkdf_expand(
		    i->kdf_di, 32, seed, in, info, s->info->keys_size, s->info->keys(s));
	OPENSSL_cleanse(seed, sizeof seed);
	return r;
}
static int mfi_mac(
    struct ccsigma_ctx *s, size_t kn, const void *k, size_t n, const void *in, void *out)
{
	return cccmac_one_shot_generate(
	    ccaes_cbc_encrypt_mode(), kn, k, n, in, s->info->mac_size, out);
}
static int ep_mac(
    struct ccsigma_ctx *s, size_t kn, const void *k, size_t n, const void *in, void *out)
{
	const struct ep_info *i = (const void *)s->info;
	if (s->info->mac_size != i->kdf_di->output_size)
		return -7;
	cchmac(i->kdf_di, kn, k, n, in, out);
	return 0;
}
static int mac_digest(struct ccsigma_ctx *s, unsigned role, size_t n, const void *in, void *out,
    const void *prefix, size_t pn)
{
	if (role > 1)
		return -7;
	size_t w = ccec_compressed_x962_export_pub_size(s->info->kex_cp);
	if (w > 33)
		return -5;
	unsigned char dctx[256], pub[33], mac[64];
	if (s->info->mac_size > sizeof mac)
		return -5;
	const struct ccdigest_info *d = s->info->di;
	ccdigest_init(d, dctx);
	ccdigest_update(d, dctx, pn, prefix);
	ccec_compressed_x962_export_pub(ccsigma_kex_init_ctx(s), pub);
	ccdigest_update(d, dctx, w, pub);
	ccec_compressed_x962_export_pub(ccsigma_kex_resp_ctx(s), pub);
	ccdigest_update(d, dctx, w, pub);
	int r = ccsigma_compute_mac(s, s->info->mac_key_index[role], n, in, mac);
	if (!r) {
		ccdigest_update(d, dctx, s->info->mac_size, mac);
		d->final(d, dctx, out);
	}
	OPENSSL_cleanse(dctx, sizeof dctx);
	OPENSSL_cleanse(mac, sizeof mac);
	return r;
}
static int mfi_mac_digest(struct ccsigma_ctx *s, unsigned role, size_t n, const void *in, void *out)
{
	const struct mfi_info *i = (const void *)s->info;
	return mac_digest(s, role, n, in, out, i->signature, i->signature_size);
}
static int ep_mac_digest(struct ccsigma_ctx *s, unsigned role, size_t n, const void *in, void *out)
{
	const struct ep_info *i = (const void *)s->info;
	return mac_digest(s, role, n, in, out, i->signature, i->signature_size);
}
static int aead_seal(struct ccsigma_ctx *s, size_t kn, const void *k, size_t vn, const void *v,
    size_t an, const void *a, size_t n, const void *in, void *out, void *tag)
{
	return ccccm_one_shot(
	    ccaes_ccm_encrypt_mode(), kn, k, vn, v, n, in, out, an, a, s->info->tag_size, tag);
}
static int aead_open(struct ccsigma_ctx *s, size_t kn, const void *k, size_t vn, const void *v,
    size_t an, const void *a, size_t n, const void *in, void *out, const void *tag)
{
	if (s->info->tag_size > 16)
		return -5;
	unsigned char actual[16];
	int r = ccccm_one_shot(
	    ccaes_ccm_decrypt_mode(), kn, k, vn, v, n, in, out, an, a, s->info->tag_size, actual);
	if (!r && CRYPTO_memcmp(tag, actual, s->info->tag_size))
		r = -2;
	OPENSSL_cleanse(actual, sizeof actual);
	return r;
}
static struct mfi_info mfi, nvm;
static struct ep_info ep;
static pthread_once_t info_once = PTHREAD_ONCE_INIT;
static const size_t mfi_sizes[] = {16, 12, 16, 16, 12, 16, 12, 16, 12, 16, 16, 12, 16, 12},
                    nvm_sizes[] = {16, 12, 16, 0, 0, 16, 12, 16, 12, 16, 0, 0, 16, 12},
                    ep_sizes[] = {32, 12, 32, 12, 32, 32, 32, 12, 32, 12, 32};
static const unsigned char mfi_salt[] = {0xb6, 0x3f, 0xd4, 0x30, 0x48, 0x2f, 0x6d, 0x50, 0x62, 0x41,
    0x99, 0xe9, 0x88, 0x81, 0xb1, 0xf6},
                           nvm_salt[] = {4, 0x2b, 0x29, 0x81, 0xa1, 0x87, 0xcb, 0x0d, 0x72, 0x90,
                               0x76, 0x1b, 0x33, 0xe5, 0x84, 0x0e},
                           ep_salt[] = {0x97, 0xdb, 0x43, 0x68, 0xee, 0xf3, 0x28, 0x42, 0x48, 0xff,
                               0x80, 0x61, 0xdc, 0xd4, 0xb4, 0x70, 0x80, 0x47, 0x86, 0x24, 0xd4,
                               0x4e, 0x6c, 0xff, 0x6a, 0xe5, 0x31, 0xb4, 0x3b, 0x3f, 0x8b, 0xfe},
                           mfi_prefix = 1, nvm_prefix = 2;
static void init_info(void)
{
	struct ccsigma_info common = {ccec_cp_256(), kex, peer_kex, ccec_cp_256(), ccsha256_di(),
	    64, sign_key, peer_sign_key, 14, mfi_sizes, 200, keys, mfi_derive, 16, mfi_mac, {9, 2},
	    mfi_mac_digest, 16, aead_seal, aead_open, next_iv, clear_mfi};
	mfi = (struct mfi_info){common, mfi_salt, 16,
	    "MFi 4.0 SIGMA-I Authentication Key Expansion", 44, &mfi_prefix, 1, &mfi_prefix, 1};
	nvm = (struct mfi_info){common, nvm_salt, 16, "MFi 4.0 NVM Authentication Key Expansion",
	    40, &nvm_prefix, 1, &nvm_prefix, 1};
	nvm.base.key_sizes = nvm_sizes;
	nvm.base.keys_size = 144;
	common.key_count = 11;
	common.key_sizes = ep_sizes;
	common.keys_size = 272;
	common.derive = ep_derive;
	common.mac_size = 32;
	common.mac = ep_mac;
	common.mac_key_index[0] = 4;
	common.mac_key_index[1] = 5;
	common.mac_digest = ep_mac_digest;
	common.clear = clear_ep;
	ep = (struct ep_info){common, ccsha256_di(), ep_salt, 32, "Exclave Pairing v1 SIGMA KDF",
	    28, "Exclave Pairing v1 SIGMA Sign", 29};
}
API const struct ccsigma_info *ccsigma_mfi_info(void)
{
	pthread_once(&info_once, init_info);
	return &mfi.base;
}
API const struct ccsigma_info *ccsigma_mfi_nvm_info(void)
{
	pthread_once(&info_once, init_info);
	return &nvm.base;
}
API const struct ccsigma_info *ccsigma_exclave_pairing_info(void)
{
	pthread_once(&info_once, init_info);
	return &ep.base;
}
static void nonce(const struct ccsigma_session_ctx *s, uint64_t seq, unsigned char out[12])
{
	memcpy(out, s->iv, 12);
	for (unsigned i = 0; i < 8; i++)
		out[11 - i] ^= (unsigned char)(seq >> (8 * i));
}
static int session_seal(struct ccsigma_session_ctx *s, size_t an, const void *a, size_t n,
    const void *in, void *out, void *tag)
{
	if (s->sequence == UINT64_MAX)
		return -12;
	unsigned char iv[12];
	nonce(s, s->sequence, iv);
	return ccccm_one_shot(
	    ccaes_ccm_encrypt_mode(), 32, s->key, 12, iv, n, in, out, an, a, 16, tag);
}
static int session_open(struct ccsigma_session_ctx *s, size_t an, const void *a, size_t n,
    const void *in, void *out, const void *tag, uint64_t seq)
{
	if (seq == UINT64_MAX)
		return -12;
	if (s->info->tag_size > 16)
		return -5;
	unsigned char iv[12], actual[16];
	nonce(s, seq, iv);
	int r = ccccm_one_shot(
	    ccaes_ccm_decrypt_mode(), 32, s->key, 12, iv, n, in, out, an, a, 16, actual);
	if (!r && CRYPTO_memcmp(actual, tag, s->info->tag_size))
		r = -2;
	OPENSSL_cleanse(actual, sizeof actual);
	return r;
}
static uint64_t get_sequence(struct ccsigma_session_ctx *s)
{
	return s->sequence;
}
static void set_sequence(struct ccsigma_session_ctx *s, uint64_t n)
{
	s->sequence = n;
}
static void advance(struct ccsigma_session_ctx *s)
{
	s->sequence++;
}
static int session_derive(struct ccsigma_session_ctx *s, size_t kn, const void *k,
    const char *label, size_t n, const void *in)
{
	if (kn != 32)
		return -7;
	unsigned char seed[64], info[32], result[44];
	memcpy(info, label, 13);
	memcpy(info + 13, in, n);
	int r = cchkdf_extract(s->info->di, 0, NULL, 32, k, seed);
	if (!r)
		r = cchkdf_expand(
		    s->info->di, s->info->di->output_size, seed, 13 + n, info, 44, result);
	if (!r) {
		memcpy(s->key, result, 32);
		memcpy(s->iv, result + 32, 12);
		s->sequence = 0;
	}
	OPENSSL_cleanse(seed, sizeof seed);
	OPENSSL_cleanse(info, sizeof info);
	OPENSSL_cleanse(result, sizeof result);
	return r;
}
static int duplex_init(unsigned role, size_t kn, const void *k, size_t n, const void *in,
    struct ccsigma_session_ctx *tx, struct ccsigma_session_ctx *rx)
{
	if (n > 19 || role > 1)
		return -7;
	int r = session_derive(tx, kn, k, role ? "ep r traffic" : "ep i traffic", n, in);
	if (!r)
		r = session_derive(rx, kn, k, role ? "ep i traffic" : "ep r traffic", n, in);
	return r;
}
static int session_import(struct ccsigma_session_ctx *s, const void *in)
{
	const unsigned char *b = in;
	if (b[0] != 1 || b[1] > 1)
		return -7;
	s->direction = b[1];
	memcpy(s->key, b + 2, 32);
	memcpy(s->iv, b + 34, 12);
	s->sequence = 0;
	for (unsigned j = 0; j < 8; j++)
		s->sequence = (s->sequence << 8) | b[46 + j];
	return 0;
}
static size_t session_size(void)
{
	return 54;
}
static int session_export(struct ccsigma_session_ctx *s, void *out)
{
	unsigned char *b = out;
	b[0] = 1;
	b[1] = s->direction;
	memcpy(b + 2, s->key, 32);
	memcpy(b + 34, s->iv, 12);
	for (unsigned j = 0; j < 8; j++)
		b[53 - j] = (unsigned char)(s->sequence >> (8 * j));
	return 0;
}
static void session_clear(struct ccsigma_session_ctx *s)
{
	OPENSSL_cleanse(s, sizeof *s);
}
static struct ccsigma_session_info session_info;
static pthread_once_t session_once = PTHREAD_ONCE_INIT;
static void init_session_info(void)
{
	session_info = (struct ccsigma_session_info){ccsha256_di(), 16, session_seal, session_open,
	    get_sequence, set_sequence, advance, duplex_init, session_import, session_size,
	    session_export, session_clear};
}
API const struct ccsigma_session_info *ccsigma_exclave_pairing_session_info(void)
{
	pthread_once(&session_once, init_session_info);
	return &session_info;
}
