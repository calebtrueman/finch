/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccrng.h"
#include <openssl/evp.h>
#include <openssl/crypto.h>
#include <string.h>
static int pub(int id, size_t n, void *out, const void *priv)
{
	EVP_PKEY *k = EVP_PKEY_new_raw_private_key(id, NULL, priv, n);
	size_t len = n;
	int ok = k && EVP_PKEY_get_raw_public_key(k, out, &len);
	EVP_PKEY_free(k);
	return ok ? 0 : -1;
}
static int shared(int id, size_t n, void *out, const void *priv, const void *peer)
{
	EVP_PKEY *k = EVP_PKEY_new_raw_private_key(id, NULL, priv, n),
	         *p = EVP_PKEY_new_raw_public_key(id, NULL, peer, n);
	EVP_PKEY_CTX *c = k ? EVP_PKEY_CTX_new(k, NULL) : NULL;
	size_t len = n;
	int ok = c && p && EVP_PKEY_derive_init(c) > 0 && EVP_PKEY_derive_set_peer(c, p) > 0 &&
	    EVP_PKEY_derive(c, out, &len) > 0;
	if (!ok)
		memset(out, 0, n);
	EVP_PKEY_CTX_free(c);
	EVP_PKEY_free(k);
	EVP_PKEY_free(p);
	return ok ? 0 : -7;
}
/* These callbacks provide the host API's masking entropy. OpenSSL performs its
 * own constant-time ladder; errors from the caller still stop the operation. */
static int check_rng(struct ccrng_state *r)
{
	unsigned char b[32];
	if (!r || !r->generate)
		return -7;
	int rc = r->generate(r, sizeof(b), b);
	OPENSSL_cleanse(b, sizeof(b));
	return rc;
}
__attribute__((visibility("default"))) int cccurve25519(
    void *out, const void *priv, const void *peer)
{
	return shared(EVP_PKEY_X25519, 32, out, priv, peer);
}
__attribute__((visibility("default"))) int cccurve25519_with_rng(
    struct ccrng_state *r, void *out, const void *priv, const void *peer)
{
	int rc = check_rng(r);
	return rc ? rc : cccurve25519(out, priv, peer);
}
__attribute__((visibility("default"))) int cccurve25519_make_priv(
    struct ccrng_state *r, unsigned char *priv)
{
	if (!r || !r->generate)
		return -7;
	int rc = r->generate(r, 32, priv);
	if (!rc) {
		priv[0] &= 248;
		priv[31] = (priv[31] & 63) | 64;
	}
	return rc;
}
__attribute__((visibility("default"))) int cccurve25519_make_pub(void *out, const void *priv)
{
	return pub(EVP_PKEY_X25519, 32, out, priv);
}
__attribute__((visibility("default"))) int cccurve25519_make_pub_with_rng(
    struct ccrng_state *r, void *out, const void *priv)
{
	int rc = check_rng(r);
	return rc ? rc : cccurve25519_make_pub(out, priv);
}
__attribute__((visibility("default"))) int cccurve25519_make_key_pair(
    struct ccrng_state *r, void *out, unsigned char *priv)
{
	int rc = cccurve25519_make_priv(r, priv);
	return rc ? rc : cccurve25519_make_pub_with_rng(r, out, priv);
}
__attribute__((visibility("default"))) int cccurve448(
    struct ccrng_state *r, void *out, const void *priv, const void *peer)
{
	int rc = check_rng(r);
	return rc ? rc : shared(EVP_PKEY_X448, 56, out, priv, peer);
}
__attribute__((visibility("default"))) int cccurve448_make_priv(
    struct ccrng_state *r, unsigned char *priv)
{
	if (!r || !r->generate)
		return -7;
	int rc = r->generate(r, 56, priv);
	if (!rc) {
		priv[0] &= 252;
		priv[55] |= 128;
	}
	return rc;
}
__attribute__((visibility("default"))) int cccurve448_make_pub(
    struct ccrng_state *r, void *out, const void *priv)
{
	int rc = check_rng(r);
	return rc ? rc : pub(EVP_PKEY_X448, 56, out, priv);
}
__attribute__((visibility("default"))) int cccurve448_make_key_pair(
    struct ccrng_state *r, void *out, unsigned char *priv)
{
	int rc = cccurve448_make_priv(r, priv);
	return rc ? rc : cccurve448_make_pub(r, out, priv);
}
