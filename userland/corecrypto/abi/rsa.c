/* SPDX-License-Identifier: MIT OR Apache-2.0
 * RSA operations backed by OpenSSL. The caller-owned layout was measured
 * from the installed system library, without using Apple source code.
 */
#define OPENSSL_SUPPRESS_DEPRECATED
#include "ccrsa.h"
#include "ccdrbg.h"
#include <openssl/rsa.h>
#include <openssl/bn.h>
#include <openssl/rand.h>
#include <openssl/hmac.h>
#include <openssl/sha.h>
#include <openssl/crypto.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <limits.h>
#define API __attribute__((visibility("default")))
API const unsigned char CCRSA_PKCS1_FAULT_CANARY[16] = {
    0xea, 0xc5, 0x4a, 0x7c, 0x9f, 0x28, 0xdf, 0x10, 0xb6, 0xe9, 0x3e, 0xb9, 0x1c, 0xd3, 0x3a, 0xc5};
API const unsigned char CCRSA_PSS_FAULT_CANARY[16] = {
    0xef, 0x49, 0xba, 0x59, 0x22, 0xfe, 0x10, 0xdd, 0x84, 0x4f, 0x24, 0xd6, 0xad, 0xc0, 0xa9, 0x93};
API void *ccrsa_ctx_public(void *k)
{
	return k;
}
API struct cczp *ccrsa_ctx_private_zp(const ccrsa_ctx *k)
{
	return finch_rsa_p(k);
}
API size_t ccrsa_block_size(const ccrsa_ctx *k)
{
	return ccn_write_uint_size(k->n, k->data);
}
API size_t ccrsa_pubkeylength(const ccrsa_ctx *k)
{
	return k->bitlen;
}
API size_t ccrsa_n_from_size(size_t n)
{
	return (n + 7) / 8;
}
API size_t ccrsa_sizeof_n_from_size(size_t n)
{
	return (n + 7) & ~(size_t)7;
}
API void *ccrsa_block_start(size_t n, void *p, int clear)
{
	size_t z = ((n + 7) & ~(size_t)7) - n;
	if (clear)
		memset(p, 0, z);
	return (char *)p + z;
}
API int ccrsa_init_pub(ccrsa_ctx *k, const cc_unit *n, const cc_unit *e)
{
	memmove(k->data, n, k->n * 8);
	int r = finch_cczp_init(k, 1);
	memmove(finch_rsa_e(k), e, k->n * 8);
	return r;
}
API int ccrsa_make_pub(ccrsa_ctx *k, size_t en, const void *e, size_t nn, const void *n)
{
	if (ccn_read_uint(k->n, k->data, nn, n) || ccn_read_uint(k->n, finch_rsa_e(k), en, e))
		return -23;
	return finch_cczp_init(k, 1);
}
static BIGNUM *bn(size_t n, const cc_unit *p)
{
	if (n > INT_MAX / 8)
		return NULL;
	return BN_lebin2bn((const void *)p, (int)n * 8, NULL);
}
static int put(size_t n, cc_unit *p, const BIGNUM *b)
{
	return n <= INT_MAX / 8 && BN_bn2lebinpad(b, (void *)p, (int)n * 8) >= 0;
}
static RSA *rsa(const ccrsa_ctx *k, int priv)
{
	RSA *r = RSA_new();
	BIGNUM *n = bn(k->n, k->data), *e = bn(k->n, finch_rsa_e(k)),
	       *d = priv ? bn(k->n, finch_rsa_d(k)) : NULL;
	if (!r || !n || !e || (priv && !d)) {
		RSA_free(r);
		BN_clear_free(n);
		BN_clear_free(e);
		BN_clear_free(d);
		return NULL;
	}
	RSA_set0_key(r, n, e, d);
	if (priv) {
		struct cczp *p = finch_rsa_p(k), *q = finch_rsa_q(k);
		if (!p->n || !q->n) {
			RSA_free(r);
			return NULL;
		}
		RSA_set0_factors(r, bn(p->n, p->data), bn(q->n, q->data));
		RSA_set0_crt_params(r, bn(p->n, finch_rsa_dp(k)), bn(q->n, finch_rsa_dq(k)),
		    bn(p->n, finch_rsa_qinv(k)));
	}
	return r;
}
static int crypt(const ccrsa_ctx *k, cc_unit *out, const cc_unit *in, int priv)
{
	if (!k->n || ccn_cmp(k->n, in, k->data) >= 0)
		return -23;
	if (!priv) {
		BN_CTX *c = BN_CTX_new();
		BIGNUM *x = bn(k->n, in), *n = bn(k->n, k->data), *e = bn(k->n, finch_rsa_e(k)),
		       *y = BN_new();
		int ok = c && x && n && e && y && !BN_is_zero(e) && BN_mod_exp(y, x, e, n, c) &&
		    put(k->n, out, y);
		BN_clear_free(x);
		BN_free(n);
		BN_free(e);
		BN_clear_free(y);
		BN_CTX_free(c);
		return ok ? 0 : -23;
	}
	RSA *r = rsa(k, 1);
	size_t n = ccrsa_block_size(k);
	unsigned char *a = malloc(n), *b = malloc(n);
	int ret = -13;
	if (r && a && b) {
		ccn_write_uint_padded_ct(k->n, in, n, a);
		int z = RSA_private_decrypt((int)n, a, b, r, RSA_NO_PADDING);
		if (z == (int)n)
			ret = ccn_read_uint(k->n, out, n, b);
		else
			ret = -23;
	}
	if (a)
		OPENSSL_clear_free(a, n);
	if (b)
		OPENSSL_clear_free(b, n);
	RSA_free(r);
	return ret;
}
API int ccrsa_pub_crypt(const ccrsa_ctx *k, cc_unit *r, const cc_unit *s)
{
	return crypt(k, r, s, 0);
}
API int ccrsa_priv_crypt(const ccrsa_ctx *k, cc_unit *r, const cc_unit *s)
{
	return crypt(k, r, s, 1);
}
static int install(ccrsa_ctx *k, const BIGNUM *e, const BIGNUM *pa, const BIGNUM *qa)
{
	const BIGNUM *p = pa, *q = qa;
	if (BN_cmp(p, q) < 0) {
		p = qa;
		q = pa;
	}
	BN_CTX *c = BN_CTX_new();
	BIGNUM *n = BN_new(), *pm = BN_dup(p), *qm = BN_dup(q), *phi = BN_new(), *d = BN_new(),
	       *dp = BN_new(), *dq = BN_new(), *qi = BN_new(), *g = BN_new();
	int ret = -23;
	if (!c || !n || !pm || !qm || !phi || !d || !dp || !dq || !qi || !g)
		goto done;
	if (BN_cmp(p, q) == 0 || !BN_is_odd(p) || !BN_is_odd(q) ||
	    BN_num_bits(p) - BN_num_bits(q) > 2 || !BN_is_odd(e) || BN_num_bits(e) < 2)
		goto done;
	if (!BN_mul(n, p, q, c) || BN_num_bits(n) > (int)k->n * 64 || !BN_sub_word(pm, 1) ||
	    !BN_sub_word(qm, 1) || !BN_gcd(g, pm, qm, c) || !BN_mul(phi, pm, qm, c) ||
	    !BN_div(phi, NULL, phi, g, c) || !BN_mod_inverse(d, e, phi, c) ||
	    !BN_nnmod(dp, d, pm, c) || !BN_nnmod(dq, d, qm, c) || !BN_mod_inverse(qi, q, p, c))
		goto done;
	struct cczp *zp = finch_rsa_p(k);
	zp->n = (BN_num_bits(p) + 63) / 64;
	put(zp->n, zp->data, p);
	if (finch_cczp_init(zp, 0))
		goto done;
	struct cczp *zq = finch_rsa_q(k);
	zq->n = (BN_num_bits(q) + 63) / 64;
	put(zq->n, zq->data, q);
	if (finch_cczp_init(zq, 0))
		goto done;
	if (!put(k->n, k->data, n) || !put(k->n, finch_rsa_e(k), e) ||
	    !put(k->n, finch_rsa_d(k), d) || !put(zp->n, finch_rsa_dp(k), dp) ||
	    !put(zq->n, finch_rsa_dq(k), dq) || !put(zp->n, finch_rsa_qinv(k), qi))
		goto done;
	ret = finch_cczp_init(k, 1);
done:
	BN_free(n);
	BN_clear_free(pm);
	BN_clear_free(qm);
	BN_clear_free(phi);
	BN_clear_free(d);
	BN_clear_free(dp);
	BN_clear_free(dq);
	BN_clear_free(qi);
	BN_clear_free(g);
	BN_CTX_free(c);
	return ret;
}
API int ccrsa_make_priv(
    ccrsa_ctx *k, size_t en, const void *eb, size_t pn, const void *pb, size_t qn, const void *qb)
{
	BIGNUM *e = BN_bin2bn(eb, (int)en, NULL), *p = BN_bin2bn(pb, (int)pn, NULL),
	       *q = BN_bin2bn(qb, (int)qn, NULL);
	int r = e && p && q ? install(k, e, p, q) : -13;
	BN_free(e);
	BN_clear_free(p);
	BN_clear_free(q);
	return r;
}
static int component(size_t n, const cc_unit *p, void *b, size_t *s)
{
	size_t z = ccn_write_uint_size(n, p);
	if (*s < z)
		return -1;
	*s = z;
	ccn_write_uint(n, p, z, b);
	return 0;
}
API int ccrsa_get_pubkey_components(const ccrsa_ctx *k, void *n, size_t *nn, void *e, size_t *en)
{
	int r = component(k->n, k->data, n, nn);
	return r ? r : component(k->n, finch_rsa_e(k), e, en);
}
API int ccrsa_get_fullkey_components(const ccrsa_ctx *k, void *n, size_t *nn, void *d, size_t *dn,
    void *p, size_t *pn, void *q, size_t *qn)
{
	struct cczp *zp = finch_rsa_p(k), *zq = finch_rsa_q(k);
	int r = component(zp->n, zp->data, p, pn);
	if (!r)
		r = component(zq->n, zq->data, q, qn);
	if (!r)
		r = component(k->n, k->data, n, nn);
	return r ? r : component(k->n, finch_rsa_d(k), d, dn);
}
API void ccrsa_dump_public_key(const ccrsa_ctx *k)
{
	ccn_lprint(k->n, "n", k->data);
	ccn_lprint(k->n, "e", finch_rsa_e(k));
}
API void ccrsa_dump_full_key(const ccrsa_ctx *k)
{
	ccrsa_dump_public_key(k);
	ccn_lprint(k->n, "d", finch_rsa_d(k));
}
static int random_bytes(struct ccrng_state *r, size_t n, void *b)
{
	return r ? r->generate(r, n, b) : (RAND_bytes(b, (int)n) == 1 ? 0 : -1);
}
static unsigned mr_rounds(unsigned bits)
{
	return bits > 1535 ? 4 : bits > 1023 ? 5 : bits > 511 ? 7 : 16;
}
static int probable_prime(const BIGNUM *p, unsigned rounds, struct ccrng_state *r, BN_CTX *c)
{
	if (!BN_is_odd(p))
		return BN_is_word(p, 2);
	if (BN_num_bits(p) < 2)
		return 0;
	/* Trial division keeps callbacks out of obviously composite candidates. */
	for (unsigned d = 3, found = 0; found < 255; d += 2) {
		unsigned smallprime = 1;
		for (unsigned j = 3; j * j <= d; j += 2)
			if (d % j == 0) {
				smallprime = 0;
				break;
			}
		if (!smallprime)
			continue;
		found++;
		if (BN_mod_word(p, d) == 0)
			return BN_is_word(p, d);
	}
	BN_CTX_start(c);
	BIGNUM *pm = BN_CTX_get(c), *odd = BN_CTX_get(c), *a = BN_CTX_get(c), *v = BN_CTX_get(c);
	int ret = -13;
	if (!v)
		goto done;
	BN_copy(pm, p);
	BN_sub_word(pm, 1);
	BN_copy(odd, pm);
	unsigned powers = 0;
	while (!BN_is_bit_set(odd, 0)) {
		BN_rshift1(odd, odd);
		powers++;
	}
	unsigned bits = (unsigned)BN_num_bits(p) + 64;
	size_t n = ((bits + 63) / 64) * 8;
	unsigned char *bytes = malloc(n);
	if (!bytes)
		goto done;
	ret = 1;
	for (unsigned i = 0; i < rounds; i++) {
		unsigned tries;
		for (tries = 0; tries < 100; tries++) {
			ret = random_bytes(r, n, bytes);
			if (ret)
				goto clear;
			BN_lebin2bn(bytes, (int)n, a);
			BN_mask_bits(a, (int)bits);
			BN_nnmod(a, a, p, c);
			if (!BN_is_zero(a) && !BN_is_one(a))
				break;
		}
		if (tries == 100) {
			ret = -1;
			goto clear;
		}
		if (!BN_mod_exp_mont_consttime(v, a, odd, p, c, NULL)) {
			ret = -13;
			goto clear;
		}
		if (BN_is_one(v) || BN_cmp(v, pm) == 0) {
			ret = 1;
			continue;
		}
		unsigned j;
		for (j = 1; j < powers; j++) {
			BN_mod_sqr(v, v, p, c);
			if (BN_cmp(v, pm) == 0)
				break;
		}
		if (j == powers) {
			ret = 0;
			goto clear;
		}
		ret = 1;
	}
clear:
	OPENSSL_clear_free(bytes, n);
done:
	BN_CTX_end(c);
	return ret;
}
static int prime(BIGNUM *p, unsigned bits, const BIGNUM *e, struct ccrng_state *r,
    struct ccrng_state *mr, BN_CTX *c)
{
	size_t n = ((bits + 63) / 64) * 8;
	unsigned char *b = malloc(n);
	BIGNUM *t = BN_new(), *g = BN_new();
	int ret = -13;
	if (!b || !t || !g)
		goto done;
	for (unsigned i = 0; i < 100000; i++) {
		ret = random_bytes(r, n, b);
		if (ret)
			break;
		BN_lebin2bn(b, (int)n, p);
		BN_mask_bits(p, (int)bits);
		BN_set_bit(p, (int)bits - 1);
		BN_set_bit(p, (int)bits - 2);
		BN_set_bit(p, 0);
		BN_copy(t, p);
		BN_sub_word(t, 1);
		if (BN_gcd(g, t, e, c) && BN_is_one(g)) {
			int valid = probable_prime(p, mr_rounds(bits), mr, c);
			if (valid < 0) {
				ret = valid;
				goto done;
			}
			if (valid == 1) {
				ret = 0;
				goto done;
			}
		}
	}
	if (!ret)
		ret = -23;
done:
	if (b)
		OPENSSL_clear_free(b, n);
	BN_clear_free(t);
	BN_clear_free(g);
	return ret;
}
static int generate_key(size_t bits, ccrsa_ctx *k, size_t en, const void *eb, struct ccrng_state *r,
    struct ccrng_state *mr)
{
	if (bits < 512 || bits > 8192 || en > INT_MAX)
		return -23;
	k->n = (bits + 63) / 64;
	BIGNUM *e = BN_bin2bn(eb, (int)en, NULL), *p = BN_new(), *q = BN_new();
	BN_CTX *c = BN_CTX_new();
	int ret = -13;
	if (!e || !p || !q || !c)
		goto done;
	if (!BN_is_odd(e) || BN_num_bits(e) < 2) {
		ret = -23;
		goto done;
	}
	ret = prime(p, (unsigned)bits / 2 + 1, e, r, mr, c);
	if (!ret)
		ret = prime(q, (unsigned)(bits - bits / 2 - 1), e, r, mr, c);
	if (!ret)
		ret = install(k, e, p, q);
done:
	BN_free(e);
	BN_clear_free(p);
	BN_clear_free(q);
	BN_CTX_free(c);
	return ret;
}
API int ccrsa_generate_key(
    size_t bits, ccrsa_ctx *k, size_t en, const void *e, struct ccrng_state *r)
{
	return generate_key(bits, k, en, e, r, r);
}
API int ccrsa_recover_priv(ccrsa_ctx *k, size_t nn, const void *nb, size_t en, const void *eb,
    size_t dn, const void *db, struct ccrng_state *r)
{
	(void)r;
	k->n = (nn + 7) / 8;
	BN_CTX *c = BN_CTX_new();
	BIGNUM *n = BN_bin2bn(nb, (int)nn, NULL), *e = BN_bin2bn(eb, (int)en, NULL),
	       *d = BN_bin2bn(db, (int)dn, NULL), *t = BN_new(), *a = BN_new(), *x = BN_new(),
	       *y = BN_new(), *v = BN_new(), *p = BN_new(), *q = BN_new();
	int ret = -23;
	if (!c || !n || !e || !d || !t || !a || !x || !y || !v || !p || !q)
		goto done;
	if (!BN_mul(t, d, e, c) || !BN_sub_word(t, 1) || BN_is_zero(t) || BN_is_odd(t) ||
	    !BN_is_odd(n))
		goto done;
	unsigned s = 0;
	while (!BN_is_bit_set(t, 0)) {
		BN_rshift1(t, t);
		s++;
	}
	BN_copy(v, n);
	BN_sub_word(v, 1);
	for (unsigned base = 2; base < 1000; base++) {
		BN_set_word(a, base);
		if (!BN_mod_exp(x, a, t, n, c))
			break;
		if (BN_is_one(x) || BN_cmp(x, v) == 0)
			continue;
		for (unsigned j = 0; j < s; j++) {
			if (!BN_mod_sqr(y, x, n, c))
				goto done;
			if (BN_is_one(y)) {
				BN_sub_word(x, 1);
				if (BN_gcd(p, x, n, c) && !BN_is_one(p) && BN_cmp(p, n) &&
				    BN_div(q, NULL, n, p, c)) {
					ret = install(k, e, p, q);
					goto done;
				}
				break;
			}
			if (BN_cmp(y, v) == 0)
				break;
			BN_copy(x, y);
		}
	}
done:
	BN_CTX_free(c);
	BN_free(n);
	BN_free(e);
	BN_clear_free(d);
	BN_clear_free(t);
	BN_clear_free(a);
	BN_clear_free(x);
	BN_clear_free(y);
	BN_clear_free(v);
	BN_clear_free(p);
	BN_clear_free(q);
	return ret;
}
API int ccrsa_emsa_pkcs1v15_encode(
    size_t n, unsigned char *out, size_t dn, const void *d, const unsigned char *oid)
{
	size_t on = oid ? oid[1] : 0, tn = dn + (oid ? on + 10 : 0);
	if (dn > 255 || on > 251 || tn > n || n - tn < 11 || (oid && tn > 126))
		return -7;
	out[0] = 0;
	out[1] = 1;
	size_t ps = n - tn - 3;
	memset(out + 2, 255, ps);
	out[2 + ps] = 0;
	unsigned char *p = out + 3 + ps;
	if (oid) {
		*p++ = 0x30;
		*p++ = (unsigned char)(tn - 2);
		*p++ = 0x30;
		*p++ = (unsigned char)(on + 4);
		memcpy(p, oid, on + 2);
		p += on + 2;
		*p++ = 5;
		*p++ = 0;
		*p++ = 4;
		*p++ = (unsigned char)dn;
	}
	memcpy(p, d, dn);
	return 0;
}
API int ccrsa_emsa_pkcs1v15_verify(
    size_t n, const unsigned char *em, size_t dn, const void *d, const unsigned char *oid)
{
	size_t on = oid ? oid[1] : 0, tn = dn + (oid ? on + 10 : 0);
	if (tn > n || n - tn < 11)
		return -23;
	unsigned bad = em[0] | (em[1] ^ 1);
	size_t end = n - tn - 1;
	for (size_t i = 2; i < end; i++)
		bad |= em[i] ^ 255;
	bad |= em[end];
	const unsigned char *p = em + end + 1;
	if (oid) {
		bad |= p[0] ^ 0x30;
		bad |= p[1] ^ (unsigned)(tn - 2);
		bad |= p[2] ^ 0x30;
		bad |= p[3] ^ (unsigned)(on + 4);
		bad |= CRYPTO_memcmp(p + 4, oid, on + 2) != 0;
		p += on + 6;
		bad |= p[0] ^ 5;
		bad |= p[1];
		bad |= p[2] ^ 4;
		bad |= p[3] ^ (unsigned)dn;
		p += 4;
	}
	bad |= CRYPTO_memcmp(p, d, dn) != 0;
	return bad & 255;
}
API int ccrsa_sign_pkcs1v15(const ccrsa_ctx *k, const unsigned char *oid, size_t dn, const void *d,
    size_t *sn, unsigned char *s)
{
	size_t n = ccrsa_block_size(k);
	if (*sn < n)
		return -23;
	*sn = n;
	unsigned char *b = malloc(n);
	cc_unit *x = calloc(k->n, 8);
	if (!b || !x) {
		free(b);
		free(x);
		return -13;
	}
	int ret = ccrsa_emsa_pkcs1v15_encode(n, b, dn, d, oid);
	if (!ret)
		ret = ccn_read_uint(k->n, x, n, b);
	if (!ret)
		ret = ccrsa_priv_crypt(k, x, x);
	if (!ret)
		ccn_write_uint_padded_ct(k->n, x, n, s);
	OPENSSL_clear_free(b, n);
	OPENSSL_clear_free(x, k->n * 8);
	return ret;
}
static int verify15(const ccrsa_ctx *k, const unsigned char *oid, size_t dn, const void *d,
    size_t sn, const void *s, void *canary, int shortok)
{
	if (canary)
		memset(canary, 0, 16);
	size_t n = ccrsa_block_size(k);
	if (sn > n || (!shortok && sn != n))
		return -23;
	unsigned char *b = malloc(n);
	cc_unit *x = calloc(k->n, 8);
	if (!b || !x) {
		free(b);
		free(x);
		return -13;
	}
	int ret = ccn_read_uint(k->n, x, sn, s);
	if (!ret)
		ret = ccrsa_pub_crypt(k, x, x);
	if (!ret) {
		ccn_write_uint_padded_ct(k->n, x, n, b);
		ret = ccrsa_emsa_pkcs1v15_verify(n, b, dn, d, oid);
		if (canary && dn && n >= dn + 11) {
			unsigned char *ca = canary;
			const unsigned char *da = d, *db = b + n - dn;
			memcpy(ca, CCRSA_PKCS1_FAULT_CANARY, 16);
			for (size_t i = 0; i < 16; i++)
				ca[i] ^= da[i % dn] ^ db[i % dn];
			for (size_t i = 16; i < dn; i++)
				ca[i % 16] ^= da[i] ^ db[i];
		}
		if (ret)
			ret = -146;
	}
	free(b);
	free(x);
	return ret;
}
API int ccrsa_verify_pkcs1v15_digest(const ccrsa_ctx *k, const unsigned char *oid, size_t dn,
    const void *d, size_t sn, const void *s, void *c)
{
	return verify15(k, oid, dn, d, sn, s, c, 0);
}
API int ccrsa_verify_pkcs1v15(const ccrsa_ctx *k, const unsigned char *oid, size_t dn,
    const void *d, size_t sn, const void *s, bool *valid)
{
	int ret = verify15(k, oid, dn, d, sn, s, NULL, 0);
	*valid = !ret;
	return ret == -146 ? 0 : ret;
}
API int ccrsa_verify_pkcs1v15_allowshortsigs(const ccrsa_ctx *k, const unsigned char *oid,
    size_t dn, const void *d, size_t sn, const void *s, bool *valid)
{
	int ret = verify15(k, oid, dn, d, sn, s, NULL, 1);
	*valid = !ret;
	return ret == -146 ? 0 : ret;
}
API int ccrsa_sign_pkcs1v15_msg(const ccrsa_ctx *k, const struct ccdigest_info *di, size_t n,
    const void *m, size_t *sn, void *s)
{
	unsigned char *d = malloc(di->output_size);
	if (!d)
		return -13;
	ccdigest(di, n, m, d);
	int ret = ccrsa_sign_pkcs1v15(k, di->oid, di->output_size, d, sn, s);
	OPENSSL_clear_free(d, di->output_size);
	return ret;
}
API int ccrsa_verify_pkcs1v15_msg(const ccrsa_ctx *k, const struct ccdigest_info *di, size_t n,
    const void *m, size_t sn, const void *s, void *c)
{
	unsigned char *d = malloc(di->output_size);
	if (!d)
		return -13;
	ccdigest(di, n, m, d);
	int ret = verify15(k, di->oid, di->output_size, d, sn, s, c, 0);
	free(d);
	return ret;
}
static int mgf(
    const struct ccdigest_info *di, size_t sn, const void *seed, size_t n, unsigned char *out)
{
	size_t h = di->output_size;
	if (!h || h > 1024 || sn > SIZE_MAX - 4)
		return -23;
	unsigned char *b = malloc(sn + 4), *d = malloc(h);
	if (!b || !d) {
		free(b);
		free(d);
		return -13;
	}
	memcpy(b, seed, sn);
	for (uint32_t i = 0; n; i++) {
		b[sn] = i >> 24;
		b[sn + 1] = i >> 16;
		b[sn + 2] = i >> 8;
		b[sn + 3] = i;
		ccdigest(di, sn + 4, b, d);
		size_t z = n < h ? n : h;
		memcpy(out, d, z);
		out += z;
		n -= z;
	}
	OPENSSL_clear_free(b, sn + 4);
	OPENSSL_clear_free(d, h);
	return 0;
}
API int ccrsa_emsa_pss_encode(const struct ccdigest_info *di, const struct ccdigest_info *md,
    size_t salt_n, const void *salt, size_t dn, const void *d, size_t bits, unsigned char *out)
{
	size_t n = (bits + 7) / 8, h = di->output_size;
	if (dn != h || n < h + 2 || salt_n > n - h - 2)
		return -25;
	size_t db = n - h - 1;
	unsigned char *m = calloc(1, 8 + h + salt_n), *mask = malloc(db);
	if (!m || !mask) {
		free(m);
		free(mask);
		return -13;
	}
	memcpy(m + 8, d, h);
	memcpy(m + 8 + h, salt, salt_n);
	ccdigest(di, 8 + h + salt_n, m, out + db);
	memset(out, 0, db);
	out[db - salt_n - 1] = 1;
	memcpy(out + db - salt_n, salt, salt_n);
	int ret = mgf(md, h, out + db, db, mask);
	if (!ret) {
		for (size_t i = 0; i < db; i++)
			out[i] ^= mask[i];
		out[0] &= 0xff >> (8 * n - bits);
		out[n - 1] = 0xbc;
	}
	OPENSSL_clear_free(m, 8 + h + salt_n);
	OPENSSL_clear_free(mask, db);
	return ret;
}
static int pss_decode(const struct ccdigest_info *di, const struct ccdigest_info *md, size_t salt_n,
    size_t dn, const void *d, size_t bits, const unsigned char *em, unsigned char *canary)
{
	size_t n = (bits + 7) / 8, h = di->output_size;
	if (dn != h || n < h + 2 || salt_n > n - h - 2)
		return -26;
	size_t db = n - h - 1;
	unsigned char *b = malloc(db), *m = calloc(1, 8 + h + salt_n), *hash = malloc(h);
	if (!b || !m || !hash) {
		free(b);
		free(m);
		free(hash);
		return -13;
	}
	int ret = mgf(md, h, em + db, db, b);
	unsigned bad = em[n - 1] ^ 0xbc;
	bad |= em[0] & (0xff << (8 - (8 * n - bits)));
	for (size_t i = 0; i < db; i++)
		b[i] ^= em[i];
	b[0] &= 0xff >> (8 * n - bits);
	for (size_t i = 0; i < db - salt_n - 1; i++)
		bad |= b[i];
	bad |= b[db - salt_n - 1] ^ 1;
	memcpy(m + 8, d, h);
	memcpy(m + 8 + h, b + db - salt_n, salt_n);
	ccdigest(di, 8 + h + salt_n, m, hash);
	bad |= CRYPTO_memcmp(hash, em + db, h);
	if (canary) {
		memcpy(canary, CCRSA_PSS_FAULT_CANARY, 16);
		for (size_t i = 0; i < 16; i++)
			canary[i] ^= hash[i % h] ^ em[db + i % h];
		for (size_t i = 16; i < h; i++)
			canary[i % 16] ^= hash[i] ^ em[db + i];
	}
	if (!ret && bad)
		ret = -26;
	OPENSSL_clear_free(b, db);
	OPENSSL_clear_free(m, 8 + h + salt_n);
	free(hash);
	return ret;
}
API int ccrsa_emsa_pss_decode(const struct ccdigest_info *di, const struct ccdigest_info *md,
    size_t salt_n, size_t dn, const void *d, size_t bits, const unsigned char *em)
{
	return pss_decode(di, md, salt_n, dn, d, bits, em, NULL);
}
API int ccrsa_sign_pss(const ccrsa_ctx *k, const struct ccdigest_info *di,
    const struct ccdigest_info *md, size_t salt_n, struct ccrng_state *r, size_t dn, const void *d,
    size_t *sn, unsigned char *s)
{
	size_t n = ccrsa_block_size(k), em_n = (k->bitlen + 6) / 8;
	if (*sn < n || dn != di->output_size)
		return -23;
	*sn = n;
	unsigned char *salt = malloc(salt_n ? salt_n : 1), *em = malloc(em_n);
	cc_unit *x = calloc(k->n, 8);
	if (!salt || !em || !x) {
		free(salt);
		free(em);
		free(x);
		return -13;
	}
	int ret = random_bytes(r, salt_n, salt);
	if (!ret)
		ret = ccrsa_emsa_pss_encode(di, md, salt_n, salt, dn, d, k->bitlen - 1, em);
	if (!ret)
		ret = ccn_read_uint(k->n, x, em_n, em);
	if (!ret)
		ret = ccrsa_priv_crypt(k, x, x);
	if (!ret)
		ccn_write_uint_padded_ct(k->n, x, n, s);
	OPENSSL_clear_free(salt, salt_n);
	OPENSSL_clear_free(em, em_n);
	OPENSSL_clear_free(x, k->n * 8);
	return ret;
}
API int ccrsa_verify_pss_digest(const ccrsa_ctx *k, const struct ccdigest_info *di,
    const struct ccdigest_info *md, size_t dn, const void *d, size_t sn, const void *s,
    size_t salt_n, void *c)
{
	unsigned char ca[16] = {0};
	if (c)
		memset(c, 0, 16);
	size_t n = ccrsa_block_size(k), em_n = (k->bitlen + 6) / 8;
	if (sn != n || dn != di->output_size)
		return -23;
	cc_unit *x = calloc(k->n, 8);
	unsigned char *b = malloc(n);
	if (!x || !b) {
		free(x);
		free(b);
		return -13;
	}
	int ret = ccn_read_uint(k->n, x, sn, s);
	if (!ret)
		ret = ccrsa_pub_crypt(k, x, x);
	if (!ret) {
		ccn_write_uint_padded_ct(k->n, x, n, b);
		if (n > em_n && b[0])
			ret = -26;
		else {
			ret = pss_decode(di, md, salt_n, dn, d, k->bitlen - 1, b + n - em_n, ca);
			ret ^= 0x3a;
			for (unsigned i = 0; i < 16; i++)
				ret ^= ca[i];
		}
	}
	if (c)
		memcpy(c, ca, 16);
	free(x);
	free(b);
	return ret;
}
API int ccrsa_sign_pss_msg(const ccrsa_ctx *k, const struct ccdigest_info *di,
    const struct ccdigest_info *md, size_t salt_n, struct ccrng_state *r, size_t n, const void *m,
    size_t *sn, void *s)
{
	unsigned char *d = malloc(di->output_size);
	if (!d)
		return -13;
	ccdigest(di, n, m, d);
	int ret = ccrsa_sign_pss(k, di, md, salt_n, r, di->output_size, d, sn, s);
	OPENSSL_clear_free(d, di->output_size);
	return ret;
}
API int ccrsa_verify_pss_msg(const ccrsa_ctx *k, const struct ccdigest_info *di,
    const struct ccdigest_info *md, size_t n, const void *m, size_t sn, const void *s,
    size_t salt_n, void *c)
{
	unsigned char *d = malloc(di->output_size);
	if (!d)
		return -13;
	ccdigest(di, n, m, d);
	int ret = ccrsa_verify_pss_digest(k, di, md, di->output_size, d, sn, s, salt_n, c);
	free(d);
	return ret;
}
API int ccrsa_eme_pkcs1v15_encode(
    struct ccrng_state *r, size_t n, cc_unit *out, size_t mn, const void *m)
{
	if (n < 11 || mn > n - 11)
		return -23;
	unsigned char *b = malloc(n);
	if (!b)
		return -13;
	size_t ps = n - mn - 3;
	b[0] = 0;
	b[1] = 2;
	int ret = random_bytes(r, ps, b + 2);
	for (size_t i = 0; !ret && i < ps; i++) {
		unsigned tries = 0;
		while (!b[2 + i] && !ret) {
			if (++tries > 1024) {
				ret = -23;
				break;
			}
			ret = random_bytes(r, 1, b + 2 + i);
		}
	}
	b[2 + ps] = 0;
	memcpy(b + 3 + ps, m, mn);
	if (!ret)
		ret = ccn_read_uint((n + 7) / 8, out, n, b);
	OPENSSL_clear_free(b, n);
	return ret;
}
struct rejection_drbg {
	unsigned char k[32], v[32];
};
static void reject_hmac(const unsigned char *k, const void *m, size_t n, unsigned char *out)
{
	unsigned int z;
	HMAC(EVP_sha256(), k, 32, m, n, out, &z);
}
static void reject_update(struct rejection_drbg *r, const unsigned char *seed, size_t sn)
{
	unsigned char b[160];
	for (unsigned i = 0; i < (sn ? 2u : 1u); i++) {
		memcpy(b, r->v, 32);
		b[32] = (unsigned char)i;
		if (sn)
			memcpy(b + 33, seed, sn);
		reject_hmac(r->k, b, 33 + sn, r->k);
		reject_hmac(r->k, r->v, 32, r->v);
	}
	OPENSSL_cleanse(b, sizeof(b));
}
static void reject_generate(struct rejection_drbg *r, size_t n, void *out)
{
	unsigned char *p = out;
	while (n) {
		reject_hmac(r->k, r->v, 32, r->v);
		size_t z = n < 32 ? n : 32;
		memcpy(p, r->v, z);
		p += z;
		n -= z;
	}
	reject_update(r, NULL, 0);
}
static int decode15(const unsigned char *key, size_t *mn, void *m, size_t n, const cc_unit *in)
{
	if (n < 11 || *mn < n)
		return -23;
	unsigned char *b = malloc(n), *fallback = malloc(n - 11);
	if (!b || !fallback) {
		free(b);
		free(fallback);
		return -13;
	}
	ccn_write_uint_padded_ct((n + 7) / 8, in, n, b);
	unsigned char seed[105];
	memcpy(seed, key, 32);
	SHA256(b, n, seed + 32);
	memcpy(seed + 64, "ccrsa_eme_pkcs1v15_decode_generate_random", 41);
	struct rejection_drbg r = {{0}, {0}};
	memset(r.v, 1, 32);
	reject_update(&r, seed, sizeof(seed));
	reject_generate(&r, n - 11, fallback);
	uint64_t bound = n - 10, mask = UINT64_MAX >> __builtin_clzll(bound), offset;
	do {
		reject_generate(&r, 8, &offset);
		offset &= mask;
	} while (offset >= bound);
	size_t pos = n - 1;
	unsigned found = 0;
	for (size_t i = 2; i < n; i++) {
		unsigned zero = b[i] == 0;
		size_t take = (size_t)0 - (size_t)(zero && !found);
		pos = (pos & ~take) | (i & take);
		found |= zero;
	}
	unsigned valid = (b[0] == 0) & (b[1] == 2) & found & (pos >= 10);
	size_t goodmask = (size_t)0 - (size_t)valid;
	size_t len = ((n - pos - 1) & goodmask) | ((n - 11 - offset) & ~goodmask);
	/* Scan both sources so malformed padding does not choose a memory address. */
	unsigned char *out = m;
	for (size_t i = 0; i < *mn; i++) {
		unsigned char v = 0;
		for (size_t j = 0; j < n; j++)
			v |= b[j] & (unsigned char)(0 - (int)(valid && (j == pos + 1 + i)));
		for (size_t j = 0; j < n - 11; j++)
			v |= fallback[j] & (unsigned char)(0 - (int)(!valid && (j == offset + i)));
		out[i] = v;
	}
	*mn = len;
	OPENSSL_clear_free(b, n);
	OPENSSL_clear_free(fallback, n - 11);
	OPENSSL_cleanse(seed, sizeof(seed));
	OPENSSL_cleanse(&r, sizeof(r));
	return 0;
}
static unsigned char rejection_key[32];
static int rejection_ready;
static pthread_once_t rejection_once = PTHREAD_ONCE_INIT;
static void rejection_init(void)
{
	rejection_ready = RAND_bytes(rejection_key, sizeof(rejection_key)) == 1;
}
API int ccrsa_eme_pkcs1v15_decode(size_t *mn, void *m, size_t n, cc_unit *in)
{
	pthread_once(&rejection_once, rejection_init);
	return rejection_ready ? decode15(rejection_key, mn, m, n, in) : -1;
}
API int ccrsa_eme_pkcs1v15_decode_safe(
    const ccrsa_ctx *k, size_t *mn, void *m, size_t n, cc_unit *in)
{
	unsigned char key[32];
	SHA256((const void *)finch_rsa_d(k), k->n * 8, key);
	int ret = decode15(key, mn, m, n, in);
	OPENSSL_cleanse(key, sizeof(key));
	return ret;
}
API int ccrsa_oaep_encode_parameter(const struct ccdigest_info *di, struct ccrng_state *r, size_t n,
    cc_unit *out, size_t mn, const void *m, size_t ln, const void *label)
{
	size_t h = di->output_size;
	if (n < 2 * h + 2 || mn > n - 2 * h - 2)
		return -23;
	size_t db = n - h - 1;
	unsigned char *b = calloc(1, n), *mask = malloc(db > h ? db : h);
	if (!b || !mask) {
		free(b);
		free(mask);
		return -13;
	}
	unsigned char *seed = b + 1, *d = b + 1 + h;
	int ret = random_bytes(r, h, seed);
	ccdigest(di, ln, label, d);
	d[db - mn - 1] = 1;
	memcpy(d + db - mn, m, mn);
	if (!ret)
		ret = mgf(di, h, seed, db, mask);
	if (!ret) {
		for (size_t i = 0; i < db; i++)
			d[i] ^= mask[i];
		ret = mgf(di, db, d, h, mask);
	}
	if (!ret) {
		for (size_t i = 0; i < h; i++)
			seed[i] ^= mask[i];
		ret = ccn_read_uint((n + 7) / 8, out, n, b);
	}
	OPENSSL_clear_free(b, n);
	OPENSSL_clear_free(mask, db > h ? db : h);
	return ret;
}
API int ccrsa_oaep_encode(const struct ccdigest_info *di, struct ccrng_state *r, size_t n,
    cc_unit *out, size_t mn, const void *m)
{
	return ccrsa_oaep_encode_parameter(di, r, n, out, mn, m, 0, NULL);
}
API int ccrsa_oaep_decode_parameter(const struct ccdigest_info *di, size_t *mn, void *m, size_t n,
    cc_unit *in, size_t ln, const void *label)
{
	size_t h = di->output_size;
	if (n < 2 * h + 2)
		return -23;
	size_t db = n - h - 1;
	unsigned char *b = malloc(n), *mask = malloc(db > h ? db : h), *hash = malloc(h);
	if (!b || !mask || !hash) {
		free(b);
		free(mask);
		free(hash);
		return -13;
	}
	ccn_write_uint_padded_ct((n + 7) / 8, in, n, b);
	ccn_swap((n + 7) / 8, in);
	unsigned char *seed = b + 1, *d = b + h + 1;
	int ret = mgf(di, db, d, h, mask);
	for (size_t i = 0; i < h; i++)
		seed[i] ^= mask[i];
	if (!ret)
		ret = mgf(di, h, seed, db, mask);
	for (size_t i = 0; i < db; i++)
		d[i] ^= mask[i];
	ccdigest(di, ln, label, hash);
	unsigned bad = b[0] | CRYPTO_memcmp(hash, d, h);
	size_t pos = db;
	unsigned found = 0;
	for (size_t i = h; i < db; i++) {
		unsigned is1 = d[i] == 1, is0 = d[i] == 0;
		bad |= (!found) && !is0 && !is1;
		if (!found && is1)
			pos = i;
		found |= is1;
	}
	bad |= !found;
	size_t len = found ? db - pos - 1 : 0;
	if (bad || len > *mn)
		ret = -23;
	if (!ret) {
		memcpy(m, d + pos + 1, len);
		*mn = len;
	}
	OPENSSL_clear_free(b, n);
	OPENSSL_clear_free(mask, db > h ? db : h);
	free(hash);
	return ret;
}
API int ccrsa_oaep_decode(
    const struct ccdigest_info *di, size_t *mn, void *m, size_t n, cc_unit *in)
{
	return ccrsa_oaep_decode_parameter(di, mn, m, n, in, 0, NULL);
}
API int ccrsa_encrypt_eme_pkcs1v15(
    const ccrsa_ctx *k, struct ccrng_state *r, size_t *cn, void *c, size_t mn, const void *m)
{
	size_t n = ccrsa_block_size(k);
	if (!n)
		return -28;
	if (*cn < n)
		return -23;
	*cn = n;
	cc_unit *x = calloc(k->n, 8);
	if (!x)
		return -13;
	int ret = ccrsa_eme_pkcs1v15_encode(r, n, x, mn, m);
	if (!ret)
		ret = ccrsa_pub_crypt(k, x, x);
	if (!ret)
		ccn_write_uint_padded_ct(k->n, x, n, c);
	OPENSSL_clear_free(x, k->n * 8);
	return ret;
}
API int ccrsa_decrypt_eme_pkcs1v15(
    const ccrsa_ctx *k, size_t *mn, void *m, size_t cn, const void *c)
{
	size_t n = ccrsa_block_size(k);
	if (cn < n || *mn < n)
		return -23;
	cc_unit *x = calloc(k->n, 8);
	if (!x)
		return -13;
	int ret = ccn_read_uint(k->n, x, cn, c);
	if (!ret)
		ret = ccrsa_priv_crypt(k, x, x);
	if (!ret)
		ret = ccrsa_eme_pkcs1v15_decode_safe(k, mn, m, n, x);
	OPENSSL_clear_free(x, k->n * 8);
	return ret;
}
API int ccrsa_encrypt_oaep(const ccrsa_ctx *k, const struct ccdigest_info *di,
    struct ccrng_state *r, size_t *cn, void *c, size_t mn, const void *m, size_t ln, const void *l)
{
	size_t n = ccrsa_block_size(k);
	if (*cn < n)
		return -23;
	*cn = n;
	cc_unit *x = calloc(k->n, 8);
	if (!x)
		return -13;
	int ret = ccrsa_oaep_encode_parameter(di, r, n, x, mn, m, ln, l);
	if (!ret)
		ret = ccrsa_pub_crypt(k, x, x);
	if (!ret)
		ccn_write_uint_padded_ct(k->n, x, n, c);
	OPENSSL_clear_free(x, k->n * 8);
	return ret;
}
API int ccrsa_decrypt_oaep(const ccrsa_ctx *k, const struct ccdigest_info *di, size_t *mn, void *m,
    size_t cn, const void *c, size_t ln, const void *l)
{
	size_t n = ccrsa_block_size(k);
	if (n < 2 * di->output_size + 2)
		return -24;
	if (cn < n || *mn < n - 2 * di->output_size - 2)
		return -23;
	cc_unit *x = calloc(k->n, 8);
	if (!x)
		return -13;
	int ret = ccn_read_uint(k->n, x, cn, c);
	if (!ret)
		ret = ccrsa_priv_crypt(k, x, x);
	if (!ret)
		ret = ccrsa_oaep_decode_parameter(di, mn, m, n, x, ln, l);
	OPENSSL_clear_free(x, k->n * 8);
	return ret;
}

static int deterministic_generate(struct ccrng_state *r, size_t n, void *out)
{
	struct ccrng_drbg_state *s = (void *)r;
	return s->info->generate(s->state, n, out, 0, NULL);
}
API int ccrsa_generate_key_deterministic(size_t bits, ccrsa_ctx *k, size_t en, const void *e,
    size_t entropy_n, const void *entropy, size_t nonce_n, const void *nonce, unsigned flags,
    struct ccrng_state *mr)
{
	if (flags != 1)
		return -7;
	extern const struct ccmode_cbc *ccaes_cbc_encrypt_mode(void);
	extern const struct ccmode_ctr *ccaes_ctr_crypt_mode(void);
	struct ccdrbg_df df;
	int ret = ccdrbg_df_bc_init(&df, ccaes_cbc_encrypt_mode(), 16);
	if (ret)
		return ret;
	struct ccdrbg_custom_ctr custom = {ccaes_ctr_crypt_mode(), 16, 0, &df};
	struct ccdrbg_info info;
	ccdrbg_factory_nistctr(&info, &custom);
	struct ccdrbg_ctr_state state;
	ret = info.init(&info, &state, entropy_n, entropy, nonce_n, nonce, 0, NULL);
	if (!ret) {
		struct ccrng_drbg_state r = {{deterministic_generate}, &info, &state};
		ret = generate_key(bits, k, en, e, &r.rng, mr);
	}
	info.done(&state);
	OPENSSL_cleanse(&df, sizeof(df));
	return ret;
}

/* Generate primes with auxiliary prime factors using the procedure in
 * FIPS 186-4, appendix B.3.6. */
static int random_bn(BIGNUM *x, unsigned bits, struct ccrng_state *r)
{
	size_t n = ((bits + 63) / 64) * 8;
	unsigned char *b = malloc(n);
	if (!b)
		return -13;
	int ret = random_bytes(r, n, b);
	if (!ret) {
		BN_lebin2bn(b, (int)n, x);
		BN_mask_bits(x, (int)bits);
		BN_set_bit(x, (int)bits - 1);
	}
	OPENSSL_clear_free(b, n);
	return ret;
}
static int aux_prime(
    BIGNUM *p, unsigned bits, struct ccrng_state *r, struct ccrng_state *mr, BN_CTX *c)
{
	int ret = random_bn(p, bits, r);
	if (ret)
		return ret;
	BN_set_bit(p, 0);
	for (unsigned i = 0; i < bits * 20; i++) {
		int v = probable_prime(p, bits > 200 ? 44 : bits > 170 ? 41 : 38, mr, c);
		if (v < 0)
			return v;
		if (v == 1)
			return 0;
		if (!BN_add_word(p, 2))
			return -22;
	}
	return -22;
}
static int fips_prime(BIGNUM *p, BIGNUM *x, unsigned bits, unsigned aux, const BIGNUM *e,
    struct ccrng_state *r, struct ccrng_state *mr, BN_CTX *c)
{
	BN_CTX_start(c);
	BIGNUM *r1 = BN_CTX_get(c), *r2 = BN_CTX_get(c), *prod = BN_CTX_get(c),
	       *residue = BN_CTX_get(c), *tmp = BN_CTX_get(c), *g = BN_CTX_get(c),
	       *lower = BN_CTX_get(c);
	int ret = -13;
	if (!lower)
		goto done;
	BN_hex2bn(&lower, "B504F333F9DE6484597D89B3754ABE9F1D6F60BA893BA84CED17AC8583339915");
	if (bits >= 256)
		BN_lshift(lower, lower, (int)bits - 256);
	else
		BN_rshift(lower, lower, 256 - (int)bits);
	for (unsigned outer = 0; outer < 100; outer++) {
		ret = aux_prime(r1, aux, r, mr, c);
		if (ret)
			goto done;
		ret = aux_prime(r2, aux, r, mr, c);
		if (ret)
			goto done;
		if (!BN_mod_inverse(tmp, r1, r2, c)) {
			ret = -32;
			continue;
		}
		BN_sub(tmp, r2, tmp);
		BN_lshift1(r1, r1);
		BN_mul(prod, r1, r2, c);
		BN_mul(residue, r1, tmp, c);
		BN_add_word(residue, 1);
		BN_nnmod(residue, residue, prod, c);
		for (unsigned tries = 0; tries < 100; tries++) {
			unsigned attempt;
			for (attempt = 0; attempt < 100; attempt++) {
				ret = random_bn(x, bits, r);
				if (ret)
					goto done;
				if (BN_cmp(x, lower) >= 0)
					break;
			}
			if (attempt == 100) {
				ret = -32;
				break;
			}
			BN_nnmod(tmp, x, prod, c);
			BN_mod_sub(tmp, residue, tmp, prod, c);
			BN_add(p, x, tmp);
			for (unsigned i = 0; i < 5 * bits; i++) {
				if (BN_num_bits(p) > (int)bits)
					break;
				BN_copy(tmp, p);
				BN_sub_word(tmp, 1);
				BN_gcd(g, tmp, e, c);
				if (BN_is_one(g)) {
					int v = probable_prime(p, mr_rounds(bits), mr, c);
					if (v < 0) {
						ret = v;
						goto done;
					}
					if (v == 1) {
						ret = 0;
						goto done;
					}
				}
				BN_add(p, p, prod);
				ret = -31;
			}
		}
	}
done:
	BN_CTX_end(c);
	return ret;
}
API int ccrsa_generate_fips186_key(size_t bits, ccrsa_ctx *k, size_t en, const void *eb,
    struct ccrng_state *r, struct ccrng_state *mr)
{
	if (bits > 8192)
		return -23;
	if (bits < 512)
		return -28;
	k->n = (bits + 63) / 64;
	BN_CTX *c = BN_CTX_new();
	BIGNUM *e = BN_bin2bn(eb, (int)en, NULL), *p = BN_new(), *q = BN_new(), *xp = BN_new(),
	       *xq = BN_new(), *delta = BN_new(), *bound = BN_new();
	int ret = -13;
	if (!c || !e || !p || !q || !xp || !xq || !delta || !bound)
		goto done;
	if (!BN_is_odd(e) || BN_num_bits(e) < 17 || BN_num_bits(e) > 256) {
		ret = -28;
		goto done;
	}
	unsigned pb = (unsigned)(bits + 1) / 2, qb = (unsigned)bits - pb,
	         ab = bits <= 1024 ? 101
	    : bits <= 3070         ? 141
	    : bits <= 4094         ? 171
	                           : 201;
	for (unsigned attempts = 0; attempts < 100; attempts++) {
		ret = fips_prime(p, xp, pb, ab, e, r, mr, c);
		if (ret)
			break;
		BN_one(bound);
		BN_lshift(bound, bound, (int)pb - 100);
		for (unsigned tries = 0; tries < 100; tries++) {
			ret = fips_prime(q, xq, qb, ab, e, r, mr, c);
			if (ret)
				break;
			BN_sub(delta, p, q);
			BN_set_negative(delta, 0);
			if (BN_cmp(delta, bound) <= 0) {
				ret = -39;
				continue;
			}
			BN_sub(delta, xp, xq);
			BN_set_negative(delta, 0);
			if (BN_cmp(delta, bound) > 0)
				break;
			ret = -39;
		}
		if (ret)
			break;
		ret = install(k, e, p, q);
		if (ret)
			break;
		if (ccn_bitlen(k->n, finch_rsa_d(k)) > pb)
			break;
	}
done:
	BN_CTX_free(c);
	BN_free(e);
	BN_clear_free(p);
	BN_clear_free(q);
	BN_clear_free(xp);
	BN_clear_free(xq);
	BN_clear_free(delta);
	BN_clear_free(bound);
	return ret;
}
struct ccrsabssa_ciphersuite {
	size_t bits;
	const struct ccdigest_info *(*di)(void);
	size_t salt_size;
};
API const struct ccrsabssa_ciphersuite ccrsabssa_ciphersuite_rsa2048_sha384 = {
    2048, ccsha384_di, 48};
API const struct ccrsabssa_ciphersuite ccrsabssa_ciphersuite_rsa3072_sha384 = {
    3072, ccsha384_di, 48};
API const struct ccrsabssa_ciphersuite ccrsabssa_ciphersuite_rsa4096_sha384 = {
    4096, ccsha384_di, 48};
API int ccrsabssa_blind_message(const struct ccrsabssa_ciphersuite *cs, const ccrsa_ctx *k,
    const void *msg, size_t msg_n, void *inverse, size_t inverse_n, void *blinded, size_t blinded_n,
    struct ccrng_state *rng)
{
	size_t n = ccrsa_block_size(k);
	if (k->bitlen != cs->bits || inverse_n != n || blinded_n != n)
		return -7;
	const struct ccdigest_info *di = cs->di();
	unsigned char *salt = malloc(cs->salt_size ? cs->salt_size : 1), *em = malloc(n),
	              *random = malloc((k->n + 1) * 8), *hash = malloc(di->output_size);
	BN_CTX *c = BN_CTX_new();
	BIGNUM *p = bn(k->n, k->data), *e = bn(k->n, finch_rsa_e(k)), *a = BN_new(),
	       *inv = BN_new(), *rad = BN_new(), *m = BN_new(), *y = BN_new(), *pm = BN_new();
	int ret = -13;
	if (!salt || !em || !random || !hash || !c || !p || !e || !a || !inv || !rad || !m || !y ||
	    !pm)
		goto done;
	ccdigest(di, msg_n, msg, hash);
	ret = random_bytes(rng, cs->salt_size, salt);
	if (ret)
		goto done;
	ret = ccrsa_emsa_pss_encode(
	    di, di, cs->salt_size, salt, di->output_size, hash, k->bitlen - 1, em);
	if (ret)
		goto done;
	ret = random_bytes(rng, (k->n + 1) * 8, random);
	if (ret)
		goto done;
	BN_lebin2bn(random, (int)(k->n + 1) * 8, a);
	BN_mask_bits(a, (int)k->bitlen + 64);
	BN_copy(pm, p);
	BN_sub_word(pm, 1);
	BN_nnmod(a, a, pm, c);
	BN_add_word(a, 1);
	/* The system samples the factor in the modulus's Montgomery domain. */
	BN_one(rad);
	BN_lshift(rad, rad, (int)k->n * 64);
	if (!BN_mod_inverse(rad, rad, p, c) || !BN_mod_mul(a, a, rad, p, c) ||
	    !BN_mod_inverse(inv, a, p, c)) {
		ret = -7;
		goto done;
	}
	BN_bin2bn(em, (int)n, m);
	if (!BN_mod_exp(y, a, e, p, c) || !BN_mod_mul(y, y, m, p, c) ||
	    BN_bn2binpad(y, blinded, (int)n) < 0 || BN_bn2binpad(inv, inverse, (int)n) < 0) {
		ret = -7;
		goto done;
	}
	ret = 0;
done:
	if (salt)
		OPENSSL_clear_free(salt, cs->salt_size);
	if (em)
		OPENSSL_clear_free(em, n);
	if (random)
		OPENSSL_clear_free(random, (k->n + 1) * 8);
	if (hash)
		OPENSSL_clear_free(hash, di->output_size);
	BN_CTX_free(c);
	BN_free(p);
	BN_free(e);
	BN_clear_free(a);
	BN_clear_free(inv);
	BN_clear_free(rad);
	BN_clear_free(m);
	BN_clear_free(y);
	BN_clear_free(pm);
	return ret;
}
API int ccrsabssa_sign_blinded_message(const struct ccrsabssa_ciphersuite *cs, const ccrsa_ctx *k,
    const void *msg, size_t mn, void *sig, size_t sn, struct ccrng_state *rng)
{
	size_t n = ccrsa_block_size(k);
	if (k->bitlen != cs->bits || mn != n || sn != n)
		return -7;
	cc_unit *x = calloc(k->n, 8);
	if (!x)
		return -13;
	int ret = ccn_read_uint(k->n, x, mn, msg);
	if (ret || ccn_cmp(k->n, x, k->data) >= 0) {
		free(x);
		return -7;
	}
	/* Consume the caller's entropy in a real RSA blinding step. */
	BN_CTX *c = BN_CTX_new();
	BIGNUM *p = bn(k->n, k->data), *e = bn(k->n, finch_rsa_e(k)), *a = BN_new(), *v = BN_new(),
	       *inv = BN_new(), *m = bn(k->n, x);
	unsigned char *random = malloc(n);
	ret = -13;
	if (!c || !p || !e || !a || !v || !inv || !m || !random)
		goto done;
	for (unsigned i = 0; i < 100; i++) {
		ret = random_bytes(rng, n, random);
		if (ret)
			goto done;
		BN_bin2bn(random, (int)n, a);
		BN_nnmod(a, a, p, c);
		if (!BN_is_zero(a) && BN_mod_inverse(inv, a, p, c))
			break;
		if (i == 99) {
			ret = -7;
			goto done;
		}
	}
	if (!BN_mod_exp(v, a, e, p, c) || !BN_mod_mul(v, v, m, p, c) || !put(k->n, x, v)) {
		ret = -7;
		goto done;
	}
	ret = ccrsa_priv_crypt(k, x, x);
	if (ret)
		goto done;
	BN_lebin2bn((void *)x, (int)k->n * 8, v);
	if (!BN_mod_mul(v, v, inv, p, c) || BN_bn2binpad(v, sig, (int)n) < 0)
		ret = -7;
done:
	OPENSSL_clear_free(x, k->n * 8);
	if (random)
		OPENSSL_clear_free(random, n);
	BN_CTX_free(c);
	BN_free(p);
	BN_free(e);
	BN_clear_free(a);
	BN_clear_free(v);
	BN_clear_free(inv);
	BN_clear_free(m);
	return ret;
}
API int ccrsabssa_unblind_signature(const struct ccrsabssa_ciphersuite *cs, const ccrsa_ctx *k,
    const void *inverse, size_t in, const void *blinded, size_t bn_, const void *msg, size_t mn,
    void *sig, size_t sn)
{
	size_t n = ccrsa_block_size(k);
	if (k->bitlen != cs->bits || in != n || bn_ != n || sn != n)
		return -7;
	BN_CTX *c = BN_CTX_new();
	BIGNUM *p = bn(k->n, k->data), *a = BN_bin2bn(inverse, (int)in, NULL),
	       *b = BN_bin2bn(blinded, (int)bn_, NULL), *v = BN_new();
	int ret = -13;
	if (!c || !p || !a || !b || !v)
		goto done;
	if (!BN_mod_mul(v, a, b, p, c) || BN_bn2binpad(v, sig, (int)n) < 0) {
		ret = -7;
		goto done;
	}
	const struct ccdigest_info *di = cs->di();
	ret = ccrsa_verify_pss_msg(k, di, di, mn, msg, sn, sig, cs->salt_size, NULL);
done:
	BN_CTX_free(c);
	BN_free(p);
	BN_clear_free(a);
	BN_clear_free(b);
	BN_clear_free(v);
	return ret;
}
