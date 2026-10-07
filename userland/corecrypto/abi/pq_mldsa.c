/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccpq.h"
#include <openssl/evp.h>
#include <openssl/params.h>
#include <openssl/crypto.h>
#include <string.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
/* The pinned backend exposes polynomial helpers needed for the fault canary. */
#include "../../../build/src/openssl/crypto/ml_dsa/ml_dsa_key.h"
#include "../../../build/src/openssl/crypto/ml_dsa/ml_dsa_matrix.h"
#include "../../../build/src/openssl/crypto/ml_dsa/ml_dsa_sign.h"
#include "../../../build/src/openssl/crypto/ml_dsa/ml_dsa_hash.h"
#pragma clang diagnostic pop
#define EXPORT __attribute__((visibility("default")))

/* These three callbacks are part of the public parameter record. They pack
 * small signed coefficients and reject out-of-range random samples. */
static void pack(unsigned char *out, const int32_t *in, unsigned eta, unsigned bits)
{
	unsigned acc = 0, used = 0;
	for (unsigned i = 0; i < 256; i++) {
		acc |= (eta - (uint32_t)in[i]) << used;
		used += bits;
		while (used >= 8) {
			*out++ = (unsigned char)acc;
			acc >>= 8;
			used -= 8;
		}
	}
}
static void unpack(int32_t *out, const unsigned char *in, unsigned eta, unsigned bits)
{
	unsigned acc = 0, used = 0, mask = (1u << bits) - 1;
	for (unsigned i = 0; i < 256; i++) {
		while (used < bits) {
			acc |= (unsigned)*in++ << used;
			used += 8;
		}
		out[i] = (int32_t)eta - (int32_t)(acc & mask);
		acc >>= bits;
		used -= bits;
	}
}
static unsigned sample(const unsigned char *in, int32_t *out, unsigned count, unsigned eta)
{
	for (unsigned i = 0; i < 136 && count < 256; i++) {
		unsigned a = in[i] & 15, b = in[i] >> 4;
		if (a < (eta == 2 ? 15u : 9u))
			out[count++] = (int32_t)eta - (int32_t)(eta == 2 ? a % 5 : a);
		if (count < 256 && b < (eta == 2 ? 15u : 9u))
			out[count++] = (int32_t)eta - (int32_t)(eta == 2 ? b % 5 : b);
	}
	return count;
}
static void pack2(unsigned char *o, const int32_t *i)
{
	pack(o, i, 2, 3);
}
static void pack4(unsigned char *o, const int32_t *i)
{
	pack(o, i, 4, 4);
}
static void unpack2(int32_t *o, const unsigned char *i)
{
	unpack(o, i, 2, 3);
}
static void unpack4(int32_t *o, const unsigned char *i)
{
	unpack(o, i, 4, 4);
}
static unsigned sample2(const unsigned char *i, int32_t *o, unsigned n)
{
	return sample(i, o, n, 2);
}
static unsigned sample4(const unsigned char *i, int32_t *o, unsigned n)
{
	return sample(i, o, n, 4);
}
static const struct ccmldsa_params params65 = {
    1, 6, 5, 49, 192, 196, 55, 128, pack4, unpack4, sample4, 5984, 4032, 1952, 3309};
static const struct ccmldsa_params params87 = {
    1, 8, 7, 60, 256, 120, 75, 96, pack2, unpack2, sample2, 7488, 4896, 2592, 4627};
EXPORT const struct ccmldsa_params *ccmldsa65(void)
{
	return &params65;
}
EXPORT const struct ccmldsa_params *ccmldsa87(void)
{
	return &params87;
}
static const char *algorithm(const struct ccmldsa_params *p)
{
	return p->k == 6 ? "ML-DSA-65" : "ML-DSA-87";
}
static EVP_PKEY *import_key(
    const struct ccmldsa_params *p, const char *part, const void *bytes, size_t n)
{
	EVP_PKEY *key = NULL;
	EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_name(NULL, algorithm(p), NULL);
	OSSL_PARAM params[] = {OSSL_PARAM_octet_string(part, (void *)bytes, n), OSSL_PARAM_END};
	int selection = !strcmp(part, "pub") ? EVP_PKEY_PUBLIC_KEY : EVP_PKEY_KEYPAIR;
	if (!ctx || EVP_PKEY_fromdata_init(ctx) <= 0 ||
	    EVP_PKEY_fromdata(ctx, &key, selection, params) <= 0) {
		EVP_PKEY_free(key);
		key = NULL;
	}
	EVP_PKEY_CTX_free(ctx);
	return key;
}
EXPORT size_t ccmldsa_sizeof_full_ctx(const struct ccmldsa_params *p)
{
	return p->full_size + 8;
}
EXPORT size_t ccmldsa_sizeof_pub_ctx(const struct ccmldsa_params *p)
{
	return p->public_size + 8;
}
EXPORT void ccmldsa_full_ctx_init(struct ccmldsa_ctx *c, const struct ccmldsa_params *p)
{
	memset(c, 0, p->full_size + 8);
	c->params = p;
}
EXPORT void ccmldsa_pub_ctx_init(struct ccmldsa_ctx *c, const struct ccmldsa_params *p)
{
	memset(c, 0, p->public_size + 8);
	c->params = p;
}
EXPORT struct ccmldsa_ctx *ccmldsa_public_ctx(struct ccmldsa_ctx *c)
{
	return c;
}
#define SIZE(NAME, FIELD)                                                                          \
	EXPORT size_t ccmldsa_##NAME##_nbytes_params(const struct ccmldsa_params *p)               \
	{                                                                                          \
		return p->FIELD;                                                                   \
	}                                                                                          \
	EXPORT size_t ccmldsa_##NAME##_nbytes_ctx(const struct ccmldsa_ctx *c)                     \
	{                                                                                          \
		return c->params->FIELD;                                                           \
	}
SIZE(pubkey, public_size)
SIZE(privkey, private_size) SIZE(signature, signature_size) EXPORT size_t
    ccmldsa_seed_nbytes_params(const struct ccmldsa_params *p)
{
	(void)p;
	return 32;
}
EXPORT size_t ccmldsa_seed_nbytes_ctx(const struct ccmldsa_ctx *c)
{
	(void)c;
	return 32;
}
EXPORT size_t ccmldsa_hash_nbytes_params(const struct ccmldsa_params *p)
{
	(void)p;
	return 64;
}
EXPORT size_t ccmldsa_hash_nbytes_ctx(const struct ccmldsa_ctx *c)
{
	(void)c;
	return 64;
}
EXPORT int ccmldsa_export_pubkey(const struct ccmldsa_ctx *c, size_t n, void *out)
{
	if (n != c->params->public_size)
		return -7;
	memcpy(out, c->key, n);
	return 0;
}
EXPORT int ccmldsa_export_privkey(const struct ccmldsa_ctx *c, size_t n, void *out)
{
	if (n != c->params->private_size)
		return -7;
	memcpy(out, c->key + c->params->public_size, n);
	return 0;
}
EXPORT int ccmldsa_import_pubkey(
    const struct ccmldsa_params *p, size_t n, const void *in, struct ccmldsa_ctx *c)
{
	if (n != p->public_size)
		return -7;
	ccmldsa_pub_ctx_init(c, p);
	memcpy(c->key, in, n);
	return 0;
}
EXPORT int ccmldsa_import_privkey(
    const struct ccmldsa_params *p, size_t n, const void *in, struct ccmldsa_ctx *c)
{
	if (n != p->private_size)
		return -7;
	ccmldsa_full_ctx_init(c, p);
	memcpy(c->key + p->public_size, in, n);
	return 0;
}
EXPORT int ccmldsa_derive_key_from_seed(struct ccmldsa_ctx *c, size_t n, const void *seed)
{
	if (n != 32)
		return -7;
	const struct ccmldsa_params *p = c->params;
	size_t written;
	EVP_PKEY *key = import_key(p, "seed", seed, n);
	int ok = key &&
	    EVP_PKEY_get_octet_string_param(key, "pub", c->key, p->public_size, &written) > 0 &&
	    written == p->public_size &&
	    EVP_PKEY_get_octet_string_param(
	        key, "priv", c->key + p->public_size, p->private_size, &written) > 0 &&
	    written == p->private_size;
	EVP_PKEY_free(key);
	return ok ? 0 : -1;
}
EXPORT int ccmldsa_generate_key_with_seed(
    struct ccmldsa_ctx *c, size_t n, void *seed, struct ccrng_state *rng)
{
	if (n != 32)
		return -7;
	int status = rng->generate(rng, n, seed);
	return status ? status : ccmldsa_derive_key_from_seed(c, n, seed);
}
EXPORT int ccmldsa_generate_key(struct ccmldsa_ctx *c, struct ccrng_state *rng)
{
	unsigned char seed[32];
	int status = ccmldsa_generate_key_with_seed(c, 32, seed, rng);
	OPENSSL_cleanse(seed, sizeof seed);
	return status;
}
static int prehash(const struct ccmldsa_ctx *c, void *out, size_t n, const void *message,
    size_t context_n, const void *context)
{
	unsigned char tr[64], prefix[2] = {0, (unsigned char)context_n};
	EVP_MD_CTX *md = EVP_MD_CTX_new();
	int ok = md && EVP_DigestInit_ex(md, EVP_shake256(), NULL) > 0 &&
	    EVP_DigestUpdate(md, c->key, c->params->public_size) > 0 &&
	    EVP_DigestFinalXOF(md, tr, 64) > 0;
	if (ok)
		ok = EVP_DigestInit_ex(md, EVP_shake256(), NULL) > 0 &&
		    EVP_DigestUpdate(md, tr, 64) > 0;
	if (ok && c->params->version == 1)
		ok = EVP_DigestUpdate(md, prefix, 2) > 0 &&
		    EVP_DigestUpdate(md, context, context_n) > 0;
	if (ok)
		ok = EVP_DigestUpdate(md, message, n) > 0 && EVP_DigestFinalXOF(md, out, 64) > 0;
	EVP_MD_CTX_free(md);
	OPENSSL_cleanse(tr, sizeof tr);
	return ok ? 0 : -1;
}
EXPORT int ccmldsa_prehash_with_context(const struct ccmldsa_ctx *c, size_t hn, void *out, size_t n,
    const void *message, size_t cn, const void *context)
{
	if (hn != 64 || cn > 255)
		return -7;
	return prehash(c, out, n, message, cn, context);
}
EXPORT int ccmldsa_prehash(
    const struct ccmldsa_ctx *c, size_t hn, void *out, size_t n, const void *message)
{
	return ccmldsa_prehash_with_context(c, hn, out, n, message, 0, NULL);
}
static int sign_message(const struct ccmldsa_ctx *c, size_t sn, void *signature, size_t n,
    const void *message, size_t cn, const void *context, const void *entropy, int mu)
{
	if (sn != c->params->signature_size)
		return -7;
	EVP_PKEY *key =
	    import_key(c->params, "priv", c->key + c->params->public_size, c->params->private_size);
	EVP_PKEY_CTX *ctx = key ? EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL) : NULL;
	EVP_SIGNATURE *sig = EVP_SIGNATURE_fetch(NULL, algorithm(c->params), NULL);
	OSSL_PARAM params[] = {
	    OSSL_PARAM_octet_string("context-string", (void *)(context ? context : ""), cn),
	    OSSL_PARAM_octet_string("test-entropy", (void *)entropy, 32), OSSL_PARAM_int("mu", &mu),
	    OSSL_PARAM_END};
	int ok = ctx && sig && EVP_PKEY_sign_message_init(ctx, sig, params) > 0 &&
	    EVP_PKEY_sign(ctx, signature, &sn, message, n) > 0;
	EVP_SIGNATURE_free(sig);
	EVP_PKEY_CTX_free(ctx);
	EVP_PKEY_free(key);
	return ok ? 0 : -1;
}
EXPORT int ccmldsa_sign_with_context(const struct ccmldsa_ctx *c, size_t sn, void *sig, size_t n,
    const void *message, size_t cn, const void *context, struct ccrng_state *rng)
{
	unsigned char entropy[32];
	int status = cn > 255 ? -7 : rng->generate(rng, 32, entropy);
	if (!status)
		status = sign_message(c, sn, sig, n, message, cn, context, entropy, 0);
	if (status)
		OPENSSL_cleanse(sig, c->params->signature_size);
	OPENSSL_cleanse(entropy, sizeof entropy);
	return status;
}
EXPORT int ccmldsa_sign(const struct ccmldsa_ctx *c, size_t sn, void *sig, size_t n,
    const void *message, struct ccrng_state *rng)
{
	return ccmldsa_sign_with_context(c, sn, sig, n, message, 0, NULL, rng);
}
EXPORT int ccmldsa_sign_prehashed(const struct ccmldsa_ctx *c, size_t sn, void *sig, size_t hn,
    const void *mu, struct ccrng_state *rng)
{
	if (hn != 64)
		return -7;
	unsigned char entropy[32];
	int status = rng->generate(rng, 32, entropy);
	if (!status)
		status = sign_message(c, sn, sig, hn, mu, 0, NULL, entropy, 1);
	OPENSSL_cleanse(entropy, sizeof entropy);
	return status;
}
/* Compute the checked challenge as well as the result. The host's canary
 * folds that challenge against the signature; a boolean result alone cannot
 * reproduce the failure bytes. All polynomial work uses the pinned backend. */
static int verify_canary(const struct ccmldsa_ctx *c, const void *signature,
    const unsigned char mu[64], unsigned char canary[16])
{
	static const unsigned char good[16] = {0x43, 0x4c, 0xeb, 0xbf, 0xdf, 0x72, 0xed, 0xc3, 0x87,
	    0xfd, 0xc7, 0x81, 0xa0, 0x22, 0xd5, 0xd9};
	unsigned k = c->params->k, l = c->params->l;
	ML_DSA_KEY *key =
	    ossl_ml_dsa_key_new(NULL, NULL, k == 6 ? EVP_PKEY_ML_DSA_65 : EVP_PKEY_ML_DSA_87);
	EVP_MD_CTX *md = EVP_MD_CTX_new();
	size_t count = 1 + k * l + 3 * k + l;
	POLY *polys = OPENSSL_malloc(count * sizeof(POLY));
	int status = -13;
	if (!key || !md || !polys)
		goto done;
	status = -146;
	if (!ossl_ml_dsa_pk_decode(key, c->key, c->params->public_size))
		goto done;
	POLY *cursor = polys, *challenge = cursor++;
	MATRIX matrix;
	matrix_init(&matrix, cursor, k, l);
	cursor += k * l;
	unsigned char given[64], computed[64], encoded[1024];
	ML_DSA_SIG sig;
	vector_init(&sig.hint, cursor, k);
	cursor += k;
	vector_init(&sig.z, cursor, l);
	cursor += l;
	sig.c_tilde = given;
	sig.c_tilde_len = c->params->strength / 4;
	VECTOR work, product;
	vector_init(&work, cursor, k);
	cursor += k;
	vector_init(&product, cursor, k);
	if (!ossl_ml_dsa_sig_decode(&sig, signature, c->params->signature_size, key->params))
		goto done;
	if (vector_max(&sig.z) >= (uint32_t)(key->params->gamma1 - key->params->beta))
		goto done;
	if (!matrix_expand_A(md, key->shake128_md, key->rho, &matrix) ||
	    !poly_sample_in_ball_ntt(
	        challenge, given, sig.c_tilde_len, md, key->shake256_md, key->params->tau))
		goto done;
	vector_scale_power2_round_ntt(&key->t1, &product);
	vector_mult_scalar(&product, challenge, &product);
	vector_ntt(&sig.z);
	matrix_mult_vector(&matrix, &sig.z, &work);
	vector_sub(&work, &product, &work);
	vector_ntt_inverse(&work);
	vector_use_hint(&sig.hint, &work, key->params->gamma2, &work);
	if (!ossl_ml_dsa_w1_encode(&work, key->params->gamma2, encoded, k * 128) ||
	    !shake_xof_2(md, key->shake256_md, mu, 64, encoded, k * 128, computed, sig.c_tilde_len))
		goto done;
	memcpy(canary, good, 16);
	for (size_t i = 0; i < sig.c_tilde_len; i++)
		canary[i % 16] ^= given[i] ^ computed[i];
	status = CRYPTO_memcmp(given, computed, sig.c_tilde_len) ? -146 : 0;
done:
	OPENSSL_free(polys);
	EVP_MD_CTX_free(md);
	ossl_ml_dsa_key_free(key);
	return status;
}
static int verify_message(const struct ccmldsa_ctx *c, size_t sn, const void *signature, size_t n,
    const void *message, size_t cn, const void *context, void *canary, int mu)
{
	if (cn > 255)
		return -7;
	if (canary)
		memset(canary, 0, 16);
	if (sn != c->params->signature_size)
		return -7;
	if (canary) {
		unsigned char hash[64];
		int status = 0;
		if (mu)
			memcpy(hash, message, 64);
		else
			status = prehash(c, hash, n, message, cn, context);
		if (!status)
			status = verify_canary(c, signature, hash, canary);
		OPENSSL_cleanse(hash, sizeof hash);
		return status;
	}
	EVP_PKEY *key = import_key(c->params, "pub", c->key, c->params->public_size);
	EVP_PKEY_CTX *ctx = key ? EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL) : NULL;
	EVP_SIGNATURE *sig = EVP_SIGNATURE_fetch(NULL, algorithm(c->params), NULL);
	OSSL_PARAM params[] = {
	    OSSL_PARAM_octet_string("context-string", (void *)(context ? context : ""), cn),
	    OSSL_PARAM_int("mu", &mu), OSSL_PARAM_END};
	int ok = ctx && sig && EVP_PKEY_verify_message_init(ctx, sig, params) > 0 &&
	    EVP_PKEY_verify(ctx, signature, sn, message, n) > 0;
	EVP_SIGNATURE_free(sig);
	EVP_PKEY_CTX_free(ctx);
	EVP_PKEY_free(key);
	return ok ? 0 : -146;
}
EXPORT int ccmldsa_verify_with_context_and_canary(const struct ccmldsa_ctx *c, size_t sn,
    const void *sig, size_t n, const void *message, size_t cn, const void *context, void *canary)
{
	return verify_message(c, sn, sig, n, message, cn, context, canary, 0);
}
EXPORT int ccmldsa_verify_with_context(const struct ccmldsa_ctx *c, size_t sn, const void *sig,
    size_t n, const void *message, size_t cn, const void *context)
{
	return verify_message(c, sn, sig, n, message, cn, context, NULL, 0);
}
EXPORT int ccmldsa_verify_with_canary(const struct ccmldsa_ctx *c, size_t sn, const void *sig,
    size_t n, const void *message, void *canary)
{
	return verify_message(c, sn, sig, n, message, 0, NULL, canary, 0);
}
EXPORT int ccmldsa_verify(
    const struct ccmldsa_ctx *c, size_t sn, const void *sig, size_t n, const void *message)
{
	return verify_message(c, sn, sig, n, message, 0, NULL, NULL, 0);
}
EXPORT int ccmldsa_verify_prehashed_with_canary(const struct ccmldsa_ctx *c, size_t sn,
    const void *sig, size_t hn, const void *mu, void *canary)
{
	if (hn != 64)
		return -7;
	return verify_message(c, sn, sig, hn, mu, 0, NULL, canary, 1);
}
EXPORT int ccmldsa_verify_prehashed(
    const struct ccmldsa_ctx *c, size_t sn, const void *sig, size_t hn, const void *mu)
{
	return ccmldsa_verify_prehashed_with_canary(c, sn, sig, hn, mu, NULL);
}
