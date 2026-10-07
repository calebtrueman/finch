/* SPDX-License-Identifier: MIT OR Apache-2.0
 * The exported suites use the older HKDF-based hash-to-curve wire format.
 * The later RFC 9380 XMD suites deliberately have different identifiers.
 */
#include "cch2c.h"
#include "ccdigest.h"
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/obj_mac.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <string.h>
#include <stdlib.h>
#define API __attribute__((visibility("default")))
extern int cchkdf_extract(
    const struct ccdigest_info *, size_t, const void *, size_t, const void *, void *);
extern int cchkdf_expand(
    const struct ccdigest_info *, size_t, const void *, size_t, const void *, size_t, void *);
static EC_GROUP *group(ccec_const_cp_t cp)
{
	int nid = cp->bitlen == 256 ? NID_X9_62_prime256v1
	    : cp->bitlen == 384     ? NID_secp384r1
	    : cp->bitlen == 521     ? NID_secp521r1
	                            : 0;
	return nid ? EC_GROUP_new_by_curve_name(nid) : NULL;
}
static int hash_base(const struct cch2c_info *info, size_t dn, const void *dst, size_t mn,
    const void *msg, unsigned counter, cc_unit *out, int sae)
{
	ccec_const_cp_t cp = info->cp();
	const struct ccdigest_info *di = info->di();
	unsigned char prk[64], uniform[128], input[256], label[25];
	size_t ln;
	if (di->output_size > sizeof(prk) || info->l > sizeof(uniform))
		return -7;
	int rc;
	if (sae) {
		memcpy(label, "SAE Hash to Element u1 P1", 25);
		label[21] = (unsigned char)('1' + counter);
		label[24] = (unsigned char)('1' + counter);
		ln = 25;
		rc = cchkdf_extract(di, dn, dst, mn, msg, prk);
	} else {
		if (mn > 255)
			return -7;
		if (mn)
			memcpy(input, msg, mn);
		input[mn] = 0;
		memcpy(label, "H2C", 3);
		label[3] = (unsigned char)counter;
		label[4] = 1;
		ln = 5;
		rc = cchkdf_extract(di, dn, dst, mn + 1, input, prk);
	}
	if (!rc)
		rc = cchkdf_expand(di, di->output_size, prk, ln, label, info->l, uniform);
	if (!rc) {
		BN_CTX *c = BN_CTX_new();
		BIGNUM *p = BN_lebin2bn((const void *)cp->data, (int)(8 * cp->n), NULL),
		       *u = BN_bin2bn(uniform, (int)info->l, NULL);
		int ok = c && p && u && BN_nnmod(u, u, p, c) &&
		    BN_bn2lebinpad(u, (void *)out, (int)(8 * cp->n)) >= 0;
		BN_clear_free(p);
		BN_clear_free(u);
		BN_CTX_free(c);
		if (!ok)
			rc = -7;
	}
	OPENSSL_cleanse(prk, sizeof(prk));
	OPENSSL_cleanse(uniform, sizeof(uniform));
	OPENSSL_cleanse(input, sizeof(input));
	return rc;
}
static int hash_rfc(void *w, const struct cch2c_info *i, size_t dn, const void *d, size_t mn,
    const void *m, unsigned ctr, cc_unit *out)
{
	(void)w;
	return hash_base(i, dn, d, mn, m, ctr, out, 0);
}
static int hash_sae(void *w, const struct cch2c_info *i, size_t dn, const void *d, size_t mn,
    const void *m, unsigned ctr, cc_unit *out)
{
	(void)w;
	return hash_base(i, dn, d, mn, m, ctr, out, 1);
}
/* Simplified SWU for the supported prime curves (all have A = -3). */
static int map_sswu(void *w, const struct cch2c_info *i, const cc_unit *input, struct ccec_ctx *out)
{
	(void)w;
	ccec_const_cp_t cp = i->cp();
	EC_GROUP *g = group(cp);
	BN_CTX *c = BN_CTX_new();
	int rc = -7;
	if (!g || !c) {
		EC_GROUP_free(g);
		BN_CTX_free(c);
		return -13;
	}
	BN_CTX_start(c);
	BIGNUM *p = BN_CTX_get(c), *a = BN_CTX_get(c), *b = BN_CTX_get(c), *z = BN_CTX_get(c),
	       *u = BN_CTX_get(c), *t = BN_CTX_get(c), *den = BN_CTX_get(c), *x = BN_CTX_get(c),
	       *gx = BN_CTX_get(c), *y = BN_CTX_get(c), *factor = BN_CTX_get(c);
	if (!factor || !EC_GROUP_get_curve(g, p, a, b, c) ||
	    !BN_lebin2bn((const void *)input, (int)(8 * cp->n), u) || !BN_set_word(z, i->z) ||
	    !BN_sub(z, p, z))
		goto done;
	if (!BN_mod_sqr(t, u, p, c) || !BN_mod_mul(t, t, z, p, c) || !BN_mod_sqr(den, t, p, c) ||
	    !BN_mod_add(den, den, t, p, c))
		goto done;
	if (BN_is_zero(den)) {
		if (!BN_mod_inverse(x, z, p, c) || !BN_sub(x, p, x))
			goto done;
	} else {
		if (!BN_mod_inverse(x, den, p, c) || !BN_add_word(x, 1))
			goto done;
	}
	if (!BN_mod_inverse(factor, a, p, c) || !BN_mod_mul(factor, factor, b, p, c) ||
	    !BN_sub(factor, p, factor) || !BN_mod_mul(x, x, factor, p, c))
		goto done;
	if (!BN_mod_sqr(gx, x, p, c) || !BN_mod_add(gx, gx, a, p, c) ||
	    !BN_mod_mul(gx, gx, x, p, c) || !BN_mod_add(gx, gx, b, p, c))
		goto done;
	if (!BN_mod_sqrt(y, gx, p, c)) {
		ERR_clear_error();
		if (!BN_mod_mul(x, x, t, p, c) || !BN_mod_sqr(gx, x, p, c) ||
		    !BN_mod_add(gx, gx, a, p, c) || !BN_mod_mul(gx, gx, x, p, c) ||
		    !BN_mod_add(gx, gx, b, p, c) || !BN_mod_sqrt(y, gx, p, c))
			goto done;
	}
	if (BN_is_odd(u) != BN_is_odd(y) && !BN_sub(y, p, y))
		goto done;
	out->cp = cp;
	if (BN_bn2lebinpad(x, (void *)out->data, (int)(8 * cp->n)) < 0 ||
	    BN_bn2lebinpad(y, (void *)(out->data + cp->n), (int)(8 * cp->n)) < 0)
		goto done;
	memset(out->data + 2 * cp->n, 0, 8 * cp->n);
	out->data[2 * cp->n] = 1;
	rc = 0;
done:
	BN_CTX_end(c);
	BN_CTX_free(c);
	EC_GROUP_free(g);
	return rc;
}
/* Each supported group has cofactor one; every valid point is in the group. */
static int clear_cofactor(const struct cch2c_info *i, struct ccec_ctx *p)
{
	(void)i;
	(void)p;
	return 0;
}
static int encode_ro(void *w, const struct cch2c_info *i, size_t dn, const void *dst, size_t mn,
    const void *msg, struct ccec_ctx *out)
{
	cc_unit u[9], v[9];
	_Alignas(16) unsigned char a[232] = {0}, b[232] = {0};
	struct ccec_ctx *ka = (void *)a, *kb = (void *)b;
	ccec_const_cp_t cp = i->cp();
	if (cp->n > 9)
		return -7;
	out->cp = cp;
	int rc = i->hash(w, i, dn, dst, mn, msg, 0, u);
	if (!rc)
		rc = i->hash(w, i, dn, dst, mn, msg, 1, v);
	if (!rc)
		rc = i->map(w, i, u, ka);
	if (!rc)
		rc = i->map(w, i, v, kb);
	if (rc)
		goto done;
	EC_GROUP *g = group(cp);
	BN_CTX *c = BN_CTX_new();
	EC_POINT *p = g ? EC_POINT_new(g) : NULL, *q = g ? EC_POINT_new(g) : NULL;
	BIGNUM *x = BN_new(), *y = BN_new();
	rc = -7;
	if (p && q && c && x && y && BN_lebin2bn((const void *)ka->data, (int)(8 * cp->n), x) &&
	    BN_lebin2bn((const void *)(ka->data + cp->n), (int)(8 * cp->n), y) &&
	    EC_POINT_set_affine_coordinates(g, p, x, y, c) &&
	    BN_lebin2bn((const void *)kb->data, (int)(8 * cp->n), x) &&
	    BN_lebin2bn((const void *)(kb->data + cp->n), (int)(8 * cp->n), y) &&
	    EC_POINT_set_affine_coordinates(g, q, x, y, c) && EC_POINT_add(g, p, p, q, c) &&
	    EC_POINT_get_affine_coordinates(g, p, x, y, c)) {
		BN_bn2lebinpad(x, (void *)out->data, (int)(8 * cp->n));
		BN_bn2lebinpad(y, (void *)(out->data + cp->n), (int)(8 * cp->n));
		memset(out->data + 2 * cp->n, 0, 8 * cp->n);
		out->data[2 * cp->n] = 1;
		rc = i->clear(i, out);
	}
	BN_clear_free(x);
	BN_clear_free(y);
	EC_POINT_free(p);
	EC_POINT_free(q);
	EC_GROUP_free(g);
	BN_CTX_free(c);
done:
	OPENSSL_cleanse(u, sizeof(u));
	OPENSSL_cleanse(v, sizeof(v));
	OPENSSL_cleanse(a, sizeof(a));
	OPENSSL_cleanse(b, sizeof(b));
	return rc;
}
API const struct cch2c_info cch2c_p256_sha256_sswu_ro_info = {"P256-SHA256-SSWU-RO-", 48, 10,
    ccec_cp_256, ccsha256_di, hash_rfc, map_sswu, clear_cofactor, encode_ro};
API const struct cch2c_info cch2c_p384_sha512_sswu_ro_info = {"P384-SHA512-SSWU-RO-", 72, 12,
    ccec_cp_384, ccsha512_di, hash_rfc, map_sswu, clear_cofactor, encode_ro};
API const struct cch2c_info cch2c_p521_sha512_sswu_ro_info = {"P521-SHA512-SSWU-RO-", 96, 4,
    ccec_cp_521, ccsha512_di, hash_rfc, map_sswu, clear_cofactor, encode_ro};
API const struct cch2c_info cch2c_p256_sha256_sae_compat_info = {
    NULL, 48, 10, ccec_cp_256, ccsha256_di, hash_sae, map_sswu, clear_cofactor, encode_ro};
API const struct cch2c_info cch2c_p384_sha384_sae_compat_info = {
    NULL, 72, 12, ccec_cp_384, ccsha384_di, hash_sae, map_sswu, clear_cofactor, encode_ro};
struct workspace {
	cc_unit *mem;
	size_t count, used;
	cc_unit *(*alloc)(struct workspace *, size_t);
	void (*free)(struct workspace *);
};
static cc_unit *allocate(struct workspace *w, size_t n)
{
	if (n > w->count - w->used)
		abort();
	cc_unit *p = w->mem + w->used;
	w->used += n;
	return p;
}
static void release(struct workspace *w)
{
	(void)w;
}
API int cch2c(const struct cch2c_info *i, size_t dn, const void *dst, size_t mn, const void *msg,
    struct ccec_ctx *out)
{
	if (!dn)
		return -7;
	cc_unit mem[4096];
	struct workspace w = {mem, 4096, 0, allocate, release};
	int rc = i->encode(&w, i, dn, dst, mn, msg, out);
	OPENSSL_cleanse(mem, sizeof(mem));
	return rc;
}
API const char *cch2c_name(const struct cch2c_info *i)
{
	return i->name;
}
API int map_to_curve_sswu(const struct cch2c_info *i, const cc_unit *input, struct ccec_ctx *out)
{
	return map_sswu(NULL, i, input, out);
}
