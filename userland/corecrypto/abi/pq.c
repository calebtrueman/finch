/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#define OPENSSL_SUPPRESS_DEPRECATED
#include "ccpq.h"
#include <openssl/evp.h>
#include <openssl/params.h>
#include <openssl/crypto.h>
#include <string.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
#include <crypto/ml_kem.h>
#pragma clang diagnostic pop
#define EXPORT __attribute__((visibility("default")))

static int xwing(const struct cckem_info *info)
{
	return info->public_size == 1216;
}
static int kyber(const struct cckem_info *info)
{
	return info->seed_size == 32 && !xwing(info);
}
static const char *algorithm(const struct cckem_info *info)
{
	return info->public_size == 1568 ? "ML-KEM-1024" : "ML-KEM-768";
}
static EVP_PKEY *import_key(const char *name, const char *part, const void *bytes, size_t n)
{
	EVP_PKEY *key = NULL;
	EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_name(NULL, name, NULL);
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
static int seeded_key(
    const char *name, const void *seed, size_t n, void *pub, size_t pn, void *priv, size_t sn)
{
	EVP_PKEY *key = import_key(name, "seed", seed, n);
	size_t written;
	int ok = key && EVP_PKEY_get_octet_string_param(key, "pub", pub, pn, &written) > 0 &&
	    written == pn && EVP_PKEY_get_octet_string_param(key, "priv", priv, sn, &written) > 0 &&
	    written == sn;
	EVP_PKEY_free(key);
	return ok ? 0 : -1;
}
static int hash(const EVP_MD *md, const void *in, size_t n, void *out, size_t on, int xof)
{
	EVP_MD_CTX *ctx = EVP_MD_CTX_new();
	int ok = ctx && EVP_DigestInit_ex(ctx, md, NULL) > 0 && EVP_DigestUpdate(ctx, in, n) > 0;
	if (ok)
		ok = xof ? EVP_DigestFinalXOF(ctx, out, on) > 0
		         : EVP_DigestFinal_ex(ctx, out, NULL) > 0;
	EVP_MD_CTX_free(ctx);
	return ok ? 0 : -1;
}
static int curve_public(const void *secret, void *pub)
{
	EVP_PKEY *key = EVP_PKEY_new_raw_private_key_ex(NULL, "X25519", NULL, secret, 32);
	size_t n = 32;
	int ok = key && EVP_PKEY_get_raw_public_key(key, pub, &n) > 0;
	EVP_PKEY_free(key);
	return ok ? 0 : -1;
}
static int curve_shared(const void *secret, const void *pub, void *out)
{
	EVP_PKEY *key = EVP_PKEY_new_raw_private_key_ex(NULL, "X25519", NULL, secret, 32);
	EVP_PKEY *peer = EVP_PKEY_new_raw_public_key_ex(NULL, "X25519", NULL, pub, 32);
	EVP_PKEY_CTX *ctx = key ? EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL) : NULL;
	size_t n = 32;
	int ok = ctx && peer && EVP_PKEY_derive_init(ctx) > 0 &&
	    EVP_PKEY_derive_set_peer(ctx, peer) > 0 && EVP_PKEY_derive(ctx, out, &n) > 0;
	EVP_PKEY_CTX_free(ctx);
	EVP_PKEY_free(peer);
	EVP_PKEY_free(key);
	return ok ? 0 : -1;
}
static int combine(
    const void *kem, const void *curve, const void *ephemeral, const void *pub, void *shared)
{
	unsigned char input[134];
	memcpy(input, kem, 32);
	memcpy(input + 32, curve, 32);
	memcpy(input + 64, ephemeral, 32);
	memcpy(input + 96, pub, 32);
	memcpy(input + 128, "\\.//^\\", 6);
	int status = hash(EVP_sha3_256(), input, sizeof input, shared, 32, 0);
	OPENSSL_cleanse(input, sizeof input);
	return status;
}
/* The host's older Kyber record omits ML-KEM's rank byte when deriving
 * the two matrix seeds. Its remaining KEM steps match ML-KEM. This adapter
 * changes only that seed hash; polynomial work stays in the pinned backend. */
struct digest_adapter {
	EVP_MD_CTX *inner;
};
static int adapter_init(EVP_MD_CTX *ctx)
{
	struct digest_adapter *a = EVP_MD_CTX_get0_md_data(ctx);
	a->inner = EVP_MD_CTX_new();
	return a->inner && EVP_DigestInit_ex(a->inner, EVP_sha3_512(), NULL) > 0;
}
static int adapter_update(EVP_MD_CTX *ctx, const void *in, size_t n)
{
	struct digest_adapter *a = EVP_MD_CTX_get0_md_data(ctx);
	/* KeyGen's sole G input is d followed by the public rank byte. */
	return EVP_DigestUpdate(a->inner, in, n == 33 ? 32 : n) > 0;
}
static int adapter_final(EVP_MD_CTX *ctx, unsigned char *out)
{
	struct digest_adapter *a = EVP_MD_CTX_get0_md_data(ctx);
	return EVP_DigestFinal_ex(a->inner, out, NULL) > 0;
}
static int adapter_cleanup(EVP_MD_CTX *ctx)
{
	struct digest_adapter *a = EVP_MD_CTX_get0_md_data(ctx);
	EVP_MD_CTX_free(a->inner);
	a->inner = NULL;
	return 1;
}
static int adapter_copy(EVP_MD_CTX *to, const EVP_MD_CTX *from)
{
	struct digest_adapter *a = EVP_MD_CTX_get0_md_data(to);
	const struct digest_adapter *b = EVP_MD_CTX_get0_md_data(from);
	a->inner = EVP_MD_CTX_new();
	return a->inner && EVP_MD_CTX_copy_ex(a->inner, b->inner) > 0;
}
static EVP_MD *adapter(void)
{
	EVP_MD *md = EVP_MD_meth_new(NID_undef, NID_undef);
	if (!md)
		return NULL;
	int ok = EVP_MD_meth_set_input_blocksize(md, 72) && EVP_MD_meth_set_result_size(md, 64) &&
	    EVP_MD_meth_set_app_datasize(md, sizeof(struct digest_adapter)) &&
	    EVP_MD_meth_set_init(md, adapter_init) && EVP_MD_meth_set_update(md, adapter_update) &&
	    EVP_MD_meth_set_final(md, adapter_final) &&
	    EVP_MD_meth_set_cleanup(md, adapter_cleanup) && EVP_MD_meth_set_copy(md, adapter_copy);
	if (!ok) {
		EVP_MD_meth_free(md);
		return NULL;
	}
	return md;
}
static ML_KEM_KEY *bare_kyber(const struct cckem_info *info)
{
	return ossl_ml_kem_key_new(
	    NULL, NULL, info->public_size == 1568 ? EVP_PKEY_ML_KEM_1024 : EVP_PKEY_ML_KEM_768);
}
static int kyber_key(const struct cckem_info *info, const void *seed, void *pub, void *secret)
{
	ML_KEM_KEY *key = bare_kyber(info);
	EVP_MD *md = adapter();
	int ok = 0;
	if (key && md) {
		EVP_MD_free(key->sha3_512_md);
		key->sha3_512_md = md;
		md = NULL;
		ok = ossl_ml_kem_set_seed(seed, 64, key) &&
		    ossl_ml_kem_genkey(pub, info->public_size, key) &&
		    ossl_ml_kem_encode_private_key(secret, info->private_size, key);
	}
	EVP_MD_meth_free(md);
	ossl_ml_kem_key_free(key);
	return ok ? 0 : -1;
}
static int derive(struct cckem_ctx *ctx, const void *seed, struct ccrng_state *rng)
{
	const struct cckem_info *info = ctx->info;
	unsigned char *secret = ctx->key + info->public_size;
	if (kyber(info)) {
		unsigned char full_seed[64];
		memcpy(full_seed, seed, 32);
		int status = rng->generate(rng, 32, full_seed + 32);
		if (!status)
			status = kyber_key(info, full_seed, ctx->key, secret);
		OPENSSL_cleanse(full_seed, 64);
		return status;
	}
	if (!xwing(info))
		return seeded_key(algorithm(info), seed, 64, ctx->key, info->public_size, secret,
		    info->private_size);
	unsigned char expanded[96];
	int status = hash(EVP_shake256(), seed, 32, expanded, sizeof expanded, 1);
	if (!status)
		status = seeded_key("ML-KEM-768", expanded, 64, ctx->key, 1184, secret, 2400);
	if (!status)
		status = curve_public(expanded + 64, ctx->key + 1184);
	if (!status) {
		memcpy(secret + 2400, expanded + 64, 32);
		memcpy(secret + 2432, seed, 32);
	}
	OPENSSL_cleanse(expanded, sizeof expanded);
	return status;
}
static int generate_seed(struct cckem_ctx *ctx, void *seed, struct ccrng_state *rng)
{
	if (kyber(ctx->info)) {
		unsigned char full_seed[64];
		int status = rng->generate(rng, 64, full_seed);
		if (!status)
			status = kyber_key(
			    ctx->info, full_seed, ctx->key, ctx->key + ctx->info->public_size);
		if (!status)
			memcpy(seed, full_seed, 32);
		OPENSSL_cleanse(full_seed, 64);
		return status;
	}
	int status = rng->generate(rng, ctx->info->seed_size, seed);
	return status ? (xwing(ctx->info) ? -1 : status) : derive(ctx, seed, rng);
}
static int generate(struct cckem_ctx *ctx, struct ccrng_state *rng)
{
	unsigned char seed[64];
	int status = generate_seed(ctx, seed, rng);
	OPENSSL_cleanse(seed, sizeof seed);
	return status;
}
static int kem_encapsulate(const struct cckem_info *info, const void *pub, const void *entropy,
    void *ciphertext, void *shared)
{
	size_t pn = info->public_size == 1568 ? 1568 : 1184;
	size_t cn = pn == 1568 ? 1568 : 1088, sn = 32;
	EVP_PKEY *key = import_key(algorithm(info), "pub", pub, pn);
	EVP_PKEY_CTX *ctx = key ? EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL) : NULL;
	OSSL_PARAM params[] = {
	    OSSL_PARAM_octet_string("ikme", (void *)entropy, 32), OSSL_PARAM_END};
	int ok = ctx && EVP_PKEY_encapsulate_init(ctx, params) > 0 &&
	    EVP_PKEY_encapsulate(ctx, ciphertext, &cn, shared, &sn) > 0;
	EVP_PKEY_CTX_free(ctx);
	EVP_PKEY_free(key);
	return ok ? 0 : -7;
}
static int encapsulate(
    const struct cckem_ctx *ctx, void *ciphertext, void *shared, struct ccrng_state *rng)
{
	unsigned char entropy[64], kem[32], curve[32];
	const struct cckem_info *info = ctx->info;
	int status = rng->generate(rng, xwing(info) ? 64 : 32, entropy);
	if (status && xwing(info))
		status = -1;
	if (!status)
		status = kem_encapsulate(
		    info, ctx->key, entropy, ciphertext, xwing(info) ? kem : shared);
	if (!status && xwing(info)) {
		unsigned char *ephemeral = (unsigned char *)ciphertext + 1088;
		status = curve_public(entropy + 32, ephemeral);
		if (!status)
			status = curve_shared(entropy + 32, ctx->key + 1184, curve);
		if (!status)
			status = combine(kem, curve, ephemeral, ctx->key + 1184, shared);
	}
	OPENSSL_cleanse(entropy, sizeof entropy);
	OPENSSL_cleanse(kem, sizeof kem);
	OPENSSL_cleanse(curve, sizeof curve);
	return status;
}
static int kem_decapsulate(
    const struct cckem_info *info, const void *secret, const void *ciphertext, void *shared)
{
	size_t sn = info->public_size == 1568 ? 3168 : 2400;
	size_t cn = sn == 3168 ? 1568 : 1088, on = 32;
	EVP_PKEY *key = import_key(algorithm(info), "priv", secret, sn);
	EVP_PKEY_CTX *ctx = key ? EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL) : NULL;
	int ok = ctx && EVP_PKEY_decapsulate_init(ctx, NULL) > 0 &&
	    EVP_PKEY_decapsulate(ctx, shared, &on, ciphertext, cn) > 0;
	EVP_PKEY_CTX_free(ctx);
	EVP_PKEY_free(key);
	return ok ? 0 : -7;
}
static int decapsulate(const struct cckem_ctx *ctx, const void *ciphertext, void *shared)
{
	const struct cckem_info *info = ctx->info;
	const unsigned char *secret = ctx->key + info->public_size;
	if (!xwing(info))
		return kem_decapsulate(info, secret, ciphertext, shared);
	unsigned char kem[32], curve[32];
	const unsigned char *ephemeral = (const unsigned char *)ciphertext + 1088;
	int status = kem_decapsulate(info, secret, ciphertext, kem);
	if (!status)
		status = curve_shared(secret + 2400, ephemeral, curve);
	if (!status)
		status = combine(kem, curve, ephemeral, ctx->key + 1184, shared);
	OPENSSL_cleanse(kem, sizeof kem);
	OPENSSL_cleanse(curve, sizeof curve);
	return status;
}
EXPORT size_t cckem_sizeof_full_ctx(const struct cckem_info *info)
{
	return 8 + info->full_size;
}
EXPORT size_t cckem_sizeof_pub_ctx(const struct cckem_info *info)
{
	return 8 + info->public_size;
}
EXPORT void cckem_full_ctx_init(struct cckem_ctx *ctx, const struct cckem_info *info)
{
	memset(ctx, 0, 8 + info->full_size);
	ctx->info = info;
}
EXPORT void cckem_pub_ctx_init(struct cckem_ctx *ctx, const struct cckem_info *info)
{
	memset(ctx, 0, 8 + info->public_size);
	ctx->info = info;
}
EXPORT struct cckem_ctx *cckem_public_ctx(struct cckem_ctx *ctx)
{
	return ctx;
}
static int export_public(const struct cckem_ctx *ctx, size_t *n, void *out)
{
	if (*n < ctx->info->public_size)
		return -7;
	*n = ctx->info->public_size;
	memcpy(out, ctx->key, *n);
	return 0;
}
static int export_private(const struct cckem_ctx *ctx, size_t *n, void *out)
{
	if (*n < ctx->info->private_size)
		return -7;
	*n = ctx->info->private_size;
	memcpy(out, ctx->key + ctx->info->public_size + (xwing(ctx->info) ? 2432 : 0), *n);
	return 0;
}
static int import_public(
    const struct cckem_info *info, size_t n, const void *in, struct cckem_ctx *ctx)
{
	if (n != info->public_size)
		return -7;
	cckem_pub_ctx_init(ctx, info);
	memcpy(ctx->key, in, n);
	return 0;
}
static int import_private(
    const struct cckem_info *info, size_t n, const void *in, struct cckem_ctx *ctx)
{
	if (n != info->private_size)
		return -7;
	cckem_full_ctx_init(ctx, info);
	if (xwing(info))
		return derive(ctx, in, NULL);
	memcpy(ctx->key + info->public_size, in, n);
	return 0;
}
#define INFO(NAME, FULL, PRIV, PUB, CT, SEED)                                                      \
	static const struct cckem_info NAME##_info = {FULL, PRIV, PUB, CT, 32, SEED, generate,     \
	    generate_seed, derive, encapsulate, decapsulate, export_public, import_public,         \
	    export_private, import_private};                                                       \
	EXPORT const struct cckem_info *NAME(void)                                                 \
	{                                                                                          \
		return &NAME##_info;                                                               \
	}
INFO(cckem_kyber768, 3584, 2400, 1184, 1088, 32)
INFO(cckem_kyber1024, 4736, 3168, 1568, 1568, 32)
INFO(cckem_mlkem768, 3584, 2400, 1184, 1088, 64)
INFO(cckem_mlkem1024, 4736, 3168, 1568, 1568, 64)
INFO(cckem_xwing_mlkem768x25519, 3680, 32, 1216, 1120, 32)
#define SIZE(NAME, FIELD)                                                                          \
	EXPORT size_t cckem_##NAME##_nbytes_info(const struct cckem_info *info)                    \
	{                                                                                          \
		return info->FIELD;                                                                \
	}                                                                                          \
	EXPORT size_t cckem_##NAME##_nbytes_ctx(const struct cckem_ctx *ctx)                       \
	{                                                                                          \
		return ctx->info->FIELD;                                                           \
	}
SIZE(pubkey, public_size)
SIZE(privkey, private_size) SIZE(encapsulated_key, ciphertext_size) SIZE(shared_key, shared_size)
    SIZE(seed, seed_size) EXPORT
    int cckem_generate_key(struct cckem_ctx *ctx, struct ccrng_state *rng)
{
	return ctx->info->generate(ctx, rng);
}
EXPORT int cckem_generate_key_with_seed(
    struct cckem_ctx *ctx, size_t n, void *seed, struct ccrng_state *rng)
{
	return n == ctx->info->seed_size ? ctx->info->generate_seed(ctx, seed, rng) : -7;
}
EXPORT int cckem_derive_key_from_seed(
    struct cckem_ctx *ctx, size_t n, const void *seed, struct ccrng_state *rng)
{
	return n == ctx->info->seed_size ? ctx->info->derive(ctx, seed, rng) : -7;
}
EXPORT int cckem_encapsulate(const struct cckem_ctx *ctx, size_t cn, void *ciphertext, size_t sn,
    void *shared, struct ccrng_state *rng)
{
	return cn == ctx->info->ciphertext_size && sn == ctx->info->shared_size
	    ? ctx->info->encapsulate(ctx, ciphertext, shared, rng)
	    : -7;
}
EXPORT int cckem_decapsulate(
    const struct cckem_ctx *ctx, size_t cn, const void *ciphertext, size_t sn, void *shared)
{
	return cn == ctx->info->ciphertext_size && sn == ctx->info->shared_size
	    ? ctx->info->decapsulate(ctx, ciphertext, shared)
	    : -7;
}
EXPORT int cckem_export_pubkey(const struct cckem_ctx *ctx, size_t *n, void *out)
{
	return ctx->info->export_public(ctx, n, out);
}
EXPORT int cckem_export_privkey(const struct cckem_ctx *ctx, size_t *n, void *out)
{
	return ctx->info->export_private(ctx, n, out);
}
EXPORT int cckem_import_pubkey(
    const struct cckem_info *info, size_t n, const void *in, struct cckem_ctx *ctx)
{
	return info->import_public(info, n, in, ctx);
}
EXPORT int cckem_import_privkey(
    const struct cckem_info *info, size_t n, const void *in, struct cckem_ctx *ctx)
{
	return info->import_private(info, n, in, ctx);
}
