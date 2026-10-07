/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Shared-context layouts observed from the host. Arithmetic comes from OpenSSL. */
#define OPENSSL_SUPPRESS_DEPRECATED
#include "ccdh.h"
#include <openssl/bn.h>
#include <openssl/dh.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#define API __attribute__((visibility("default")))
API size_t ccdh_gp_size(size_t bytes)
{
	return 40 + ((4 * bytes + 28) & ~(size_t)31);
}
API size_t ccdh_gp_n(const struct cczp *g)
{
	return g->n;
}
API size_t ccdh_ccn_size(const struct cczp *g)
{
	return 8 * g->n;
}
API cc_unit *ccdh_gp_prime(const struct cczp *g)
{
	return (cc_unit *)g->data;
}
API cc_unit *ccdh_gp_g(const struct cczp *g)
{
	return (cc_unit *)((char *)g + 32 + 16 * g->n);
}
API cc_unit *ccdh_gp_order(const struct cczp *g)
{
	return (cc_unit *)((char *)g + 32 + 24 * g->n);
}
API size_t ccdh_gp_l(const struct cczp *g)
{
	return *(size_t *)((char *)g + 32 + 32 * g->n);
}
API size_t ccdh_gp_order_bitlen(const struct cczp *g)
{
	return ccn_bitlen(g->n, ccdh_gp_order(g));
}
API void ccdh_ctx_init(const struct cczp *g, struct ccdh_ctx *c)
{
	c->gp = g;
}
API struct ccdh_ctx *ccdh_ctx_public(struct ccdh_ctx *c)
{
	return c;
}
API size_t ccdh_export_pub_size(const struct ccdh_ctx *c)
{
	return c->gp->n * 8;
}
API void ccdh_export_pub(const struct ccdh_ctx *c, void *out)
{
	ccn_write_uint_padded_ct(c->gp->n, c->data, c->gp->n * 8, out);
}
static BIGNUM *from(const cc_unit *u, size_t n)
{
	return n > INT_MAX / 8 ? NULL : BN_lebin2bn((const unsigned char *)u, (int)(8 * n), NULL);
}
static int put(const BIGNUM *b, cc_unit *u, size_t n)
{
	return BN_bn2lebinpad(b, (unsigned char *)u, (int)(8 * n)) == (int)(8 * n);
}
static int power(const struct cczp *g, cc_unit *out, const cc_unit *base, const cc_unit *exp)
{
	BIGNUM *p = from(g->data, g->n), *a = from(base, g->n), *x = from(exp, g->n), *r = BN_new();
	BN_CTX *c = BN_CTX_new();
	int ok = p && a && x && r && c && BN_mod_exp_mont_consttime(r, a, x, p, c, NULL) &&
	    put(r, out, g->n);
	BN_free(p);
	BN_free(a);
	BN_clear_free(x);
	BN_clear_free(r);
	BN_CTX_free(c);
	return ok ? 0 : -46;
}
API int ccdh_import_pub(const struct cczp *g, size_t n, const void *in, struct ccdh_ctx *c)
{
	c->gp = g;
	if (ccn_read_uint(g->n, c->data, n, in))
		return -52;
	return ccn_cmp(g->n, c->data, g->data) < 0 ? 0 : -49;
}
API int ccdh_import_priv(const struct cczp *g, size_t n, const void *in, struct ccdh_ctx *c)
{
	c->gp = g;
	cc_unit *x = c->data + g->n;
	if (ccn_read_uint(g->n, x, n, in))
		return -52;
	if (ccn_cmp(g->n, x, g->data) >= 0)
		return -49;
	return power(g, c->data, ccdh_gp_g(g), x);
}
API int ccdh_import_full(
    const struct cczp *g, size_t xn, const void *x, size_t yn, const void *y, struct ccdh_ctx *c)
{
	c->gp = g;
	if (ccn_read_uint(g->n, c->data + g->n, xn, x))
		return -52;
	if (ccn_cmp(g->n, c->data + g->n, g->data) >= 0)
		return -49;
	return ccdh_import_pub(g, yn, y, c);
}
/* RFC groups are supplied by OpenSSL, without copying any vendor tables. */
static pthread_once_t groups_once = PTHREAD_ONCE_INIT;
static uint64_t groups[11][517];
static void make_groups(void)
{
	BIGNUM *(*prime[8])(BIGNUM *) = {BN_get_rfc2409_prime_768, BN_get_rfc2409_prime_1024,
	    BN_get_rfc3526_prime_1536, BN_get_rfc3526_prime_2048, BN_get_rfc3526_prime_3072,
	    BN_get_rfc3526_prime_4096, BN_get_rfc3526_prime_6144, BN_get_rfc3526_prime_8192};
	size_t lens[8] = {160, 160, 240, 320, 420, 480, 540, 620};
	for (int i = 0; i < 11; i++) {
		DH *d = NULL;
		BIGNUM *owned = NULL;
		const BIGNUM *p, *q = NULL, *gen = NULL;
		if (i == 0) {
			owned = NULL;
			BN_hex2bn(&owned,
			    "FFFFFFFFFFFFFFFF6575089BA8F8373BD4A0DF17FCCDB09A94619E6E28FCCDA366C505DBBEAF8DDC552A24E169EE3091BB1332A71044F868332DDEFDAAE97663CBF608FB894C7297B7996E88529B1A37EC14AD084D0A476DFFFFFFFFFFFFFFFF");
			p = owned;
		} else if (i < 8)
			p = owned = prime[i](NULL);
		else {
			d = i == 8   ? DH_get_1024_160()
			    : i == 9 ? DH_get_2048_224()
			             : DH_get_2048_256();
			if (!d)
				abort();
			DH_get0_pqg(d, &p, &q, &gen);
		}
		if (!p)
			abort();
		struct cczp *g = (void *)groups[i];
		g->n = ((size_t)BN_num_bits(p) + 63) / 64;
		put(p, g->data, g->n);
		if (finch_cczp_init(g, 0))
			abort();
		if (gen)
			put(gen, ccdh_gp_g(g), g->n);
		else
			*ccdh_gp_g(g) = 2;
		if (q)
			put(q, ccdh_gp_order(g), g->n);
		*(size_t *)((char *)g + 32 + 32 * g->n) = i < 8 ? lens[i] : 0;
		BN_free(owned);
		DH_free(d);
	}
}
#define GROUP(NAME, I)                                                                             \
	API const struct cczp *ccdh_gp_##NAME(void)                                                \
	{                                                                                          \
		pthread_once(&groups_once, make_groups);                                           \
		return (const void *)groups[I];                                                    \
	}
GROUP(apple768, 0)
GROUP(rfc2409group02, 1) GROUP(rfc3526group05, 2) GROUP(rfc3526group14, 3) GROUP(rfc3526group15, 4)
    GROUP(rfc3526group16, 5) GROUP(rfc3526group17, 6) GROUP(rfc3526group18, 7)
        GROUP(rfc5114_MODP_1024_160, 8) GROUP(rfc5114_MODP_2048_224, 9) GROUP(rfc5114_MODP_2048_256,
            10) static int check_peer(const struct cczp *g, const struct ccdh_ctx *c)
{
	if (g->n != c->gp->n || ccn_cmp(g->n, g->data, c->gp->data))
		return -53;
	if (!(g->data[0] & 1))
		return -51;
	BIGNUM *p = from(g->data, g->n), *y = from(c->data, g->n),
	       *q = from(ccdh_gp_order(g), g->n), *v = BN_new();
	BN_CTX *b = BN_CTX_new();
	int ret = -13;
	if (!p || !y || !q || !v || !b)
		goto done;
	BN_sub_word(p, 1);
	ret = -49;
	if (BN_cmp(y, BN_value_one()) <= 0 || BN_cmp(y, p) >= 0)
		goto done;
	if (!BN_is_zero(q)) {
		BN_add_word(p, 1);
		if (!BN_mod_exp(v, y, q, p, b) || !BN_is_one(v))
			goto done;
	}
	ret = 0;
done:
	BN_free(p);
	BN_free(y);
	BN_free(q);
	BN_free(v);
	BN_CTX_free(b);
	return ret;
}
static int blinded_power(const struct cczp *g, cc_unit *out, const cc_unit *base,
    const cc_unit *exp, struct ccrng_state *rng)
{
	if (ccn_cmp(g->n, exp, g->data) >= 0)
		return -7;
	unsigned char seed[24];
	if (!rng)
		return -7;
	int ret = rng->generate(rng, 16, seed);
	if (!ret)
		ret = rng->generate(rng, 8, seed + 16);
	if (ret) {
		memset(seed, 0, sizeof seed);
		return ret;
	}
	BIGNUM *p = from(g->data, g->n), *m = BN_new(), *a = from(base, g->n), *x = from(exp, g->n),
	       *r = BN_new(), *factor = BN_lebin2bn(seed, 8, NULL),
	       *offset = BN_lebin2bn(seed + 8, 16, NULL);
	BN_CTX *c = BN_CTX_new();
	ret = -13;
	if (p && m && a && x && r && factor && offset && c) {
		BN_set_bit(factor, 0);
		BN_set_bit(factor, 63);
		int ok = BN_mul(m, p, factor, c) && BN_mul(offset, offset, p, c) &&
		    BN_add(a, a, offset) && BN_nnmod(a, a, m, c) &&
		    BN_mod_exp_mont_consttime(r, a, x, m, c, NULL) && BN_nnmod(r, r, p, c) &&
		    put(r, out, g->n);
		ret = ok ? 0 : -46;
	}
	BN_free(p);
	BN_clear_free(m);
	BN_clear_free(a);
	BN_clear_free(x);
	BN_clear_free(r);
	BN_clear_free(factor);
	BN_clear_free(offset);
	BN_CTX_free(c);
	volatile unsigned char *w = seed;
	for (size_t i = 0; i < sizeof seed; i++)
		w[i] = 0;
	return ret;
}
API int ccdh_compute_shared_secret(const struct ccdh_ctx *priv, const struct ccdh_ctx *pub,
    size_t *len, void *out, struct ccrng_state *rng)
{
	const struct cczp *g = priv->gp;
	if (*len < (g->bitlen + 7) / 8)
		return -52;
	int e = check_peer(g, pub);
	if (e)
		return e;
	cc_unit *s = calloc(g->n, 8);
	if (!s)
		return -13;
	e = blinded_power(g, s, pub->data, priv->data + g->n, rng);
	if (!e) {
		BIGNUM *v = from(s, g->n), *p = from(g->data, g->n);
		if (!v || !p)
			e = -13;
		else {
			BN_sub_word(p, 1);
			if (BN_cmp(v, BN_value_one()) <= 0 || BN_cmp(v, p) == 0) {
				*len = 0;
				e = -52;
			} else {
				*len = ccn_write_uint_size(g->n, s);
				ccn_write_uint(g->n, s, *len, out);
			}
		}
		BN_clear_free(v);
		BN_free(p);
	}
	volatile cc_unit *w = s;
	for (size_t i = 0; i < g->n; i++)
		w[i] = 0;
	free(s);
	return e;
}
API int ccdh_generate_key(const struct cczp *g, struct ccrng_state *rng, struct ccdh_ctx *c)
{
	c->gp = g;
	cc_unit *x = c->data + g->n;
	memset(x, 0, g->n * 8);
	size_t l = ccdh_gp_l(g), qbits = ccdh_gp_order_bitlen(g),
	       bits = qbits ? qbits
	    : l             ? l
	                    : g->bitlen;
	if (l > g->bitlen)
		return -51;
	if (!rng || !bits)
		return -7;
	BIGNUM *limit = from(qbits ? ccdh_gp_order(g) : g->data, g->n);
	if (!limit)
		return -13;
	BN_sub_word(limit, 2);
	int ret = -47;
	for (unsigned trial = 0; trial <= 100; trial++) {
		size_t words = (bits + 63) / 64;
		ret = rng->generate(rng, words * 8, x);
		if (ret)
			break;
		if (bits % 64)
			x[words - 1] &= (UINT64_C(1) << (bits % 64)) - 1;
		if (!qbits && l) {
			ccn_set_bit(x, l - 1, 1);
			ret = 0;
			break;
		}
		BIGNUM *v = from(x, g->n);
		if (!v) {
			ret = -13;
			break;
		}
		int valid = !BN_is_zero(v) && BN_cmp(v, limit) <= 0;
		BN_clear_free(v);
		if (valid) {
			ret = 0;
			break;
		}
		ret = -47;
	}
	BN_free(limit);
	if (ret)
		return ret;
	ret = power(g, c->data, ccdh_gp_g(g), x);
	if (ret)
		return ret;
	ret = check_peer(g, c);
	if (ret)
		return ret;
	/* Check that the generated public and private values agree on a shared key. */
	cc_unit *tmp = calloc(4 * g->n, 8);
	if (!tmp)
		return -13;
	cc_unit *peer = tmp + g->n, *a = peer + g->n, *b = a + g->n;
	tmp[0] = 19;
	ret = power(g, peer, ccdh_gp_g(g), tmp);
	if (!ret)
		ret = blinded_power(g, a, peer, x, rng);
	if (!ret)
		ret = power(g, b, c->data, tmp);
	if (!ret && ccn_cmp(g->n, a, b))
		ret = -54;
	volatile cc_unit *w = tmp;
	for (size_t i = 0; i < 4 * g->n; i++)
		w[i] = 0;
	free(tmp);
	return ret ? -54 : 0;
}
API int ccdh_init_gp_from_bytes(struct cczp *g, size_t capacity, size_t pn, const void *pbytes,
    size_t gn, const void *gbytes, size_t qn, const void *qbytes, size_t l)
{
	int e = ccn_read_uint(capacity, g->data, pn, pbytes);
	if (e)
		return e;
	size_t n = capacity;
	while (n && !g->data[n - 1])
		n--;
	g->n = n;
	e = ccn_read_uint(n, ccdh_gp_g(g), gn, gbytes);
	if (e)
		return e;
	pthread_once(&groups_once, make_groups);
	for (size_t i = 0; i < 11; i++) {
		const struct cczp *known = (const void *)groups[i];
		if (known->n == n && !ccn_cmp(n, known->data, g->data) &&
		    !ccn_cmp(n, ccdh_gp_g(known), ccdh_gp_g(g))) {
			memcpy(g, known, 40 + 32 * n);
			if (l && !ccdh_gp_l(g))
				*(size_t *)((char *)g + 32 + 32 * n) = l < 160 ? 160 : l;
			return 0;
		}
	}
	BIGNUM *p = from(g->data, n), *q = NULL;
	BN_CTX *c = BN_CTX_new();
	if (!p || !c) {
		BN_free(p);
		BN_CTX_free(c);
		return -13;
	}
	int prime = BN_check_prime(p, c, NULL);
	if (prime != 1) {
		e = -166;
		goto done;
	}
	*(size_t *)((char *)g + 32 + 32 * n) = 0;
	if (qbytes) {
		e = ccn_read_uint(n, ccdh_gp_order(g), qn, qbytes);
		if (e)
			goto done;
		q = from(ccdh_gp_order(g), n);
		if (!q) {
			e = -13;
			goto done;
		}
		if (BN_check_prime(q, c, NULL) != 1) {
			e = -167;
			goto done;
		}
	} else {
		memset(ccdh_gp_order(g), 0, n * 8);
		if (l)
			*(size_t *)((char *)g + 32 + 32 * n) = l < 160 ? 160 : l;
		if (!BN_is_odd(p)) {
			e = -7;
			goto done;
		}
		q = BN_dup(p);
		if (!q) {
			e = -13;
			goto done;
		}
		BN_rshift1(q, q);
		if (BN_check_prime(q, c, NULL) != 1) {
			e = -168;
			goto done;
		}
	}
	e = finch_cczp_init(g, 0);
done:
	BN_free(p);
	BN_free(q);
	BN_CTX_free(c);
	return e;
}
#include "ccder.h"
API size_t ccder_encode_dhparams_size(const struct cczp *g)
{
	size_t body =
	    ccder_sizeof_integer(g->n, g->data) + ccder_sizeof_integer(g->n, ccdh_gp_g(g));
	size_t l = ccdh_gp_l(g);
	if (l)
		body += ccder_sizeof_uint64(l);
	return ccder_sizeof(CCDER_SEQUENCE, body);
}
API unsigned char *ccder_encode_dhparams(
    const struct cczp *g, unsigned char *start, unsigned char *end)
{
	unsigned char *p = end;
	size_t l = ccdh_gp_l(g);
	if (l)
		p = ccder_encode_uint64(l, start, p);
	p = ccder_encode_integer(g->n, ccdh_gp_g(g), start, p);
	p = ccder_encode_integer(g->n, g->data, start, p);
	return ccder_encode_constructed_tl(CCDER_SEQUENCE, end, start, p);
}
API const unsigned char *ccder_decode_dhparams(
    struct cczp *g, const unsigned char *start, const unsigned char *end)
{
	size_t n = g->n;
	const unsigned char *body_end = end;
	const unsigned char *p = ccder_decode_constructed_tl(CCDER_SEQUENCE, &body_end, start, end);
	p = ccder_decode_uint(n, g->data, p, body_end);
	if (p && finch_cczp_init(g, 0))
		return NULL;
	p = ccder_decode_uint(n, ccdh_gp_g(g), p, body_end);
	pthread_once(&groups_once, make_groups);
	int known = 0;
	for (size_t i = 0; i < 11; i++) {
		const struct cczp *k = (const void *)groups[i];
		if (k->n == n && !ccn_cmp(n, k->data, g->data) &&
		    !ccn_cmp(n, ccdh_gp_g(k), ccdh_gp_g(g))) {
			memcpy(g, k, 40 + 32 * n);
			known = 1;
			break;
		}
	}
	if (!known)
		memset(ccdh_gp_order(g), 0, n * 8);
	uint64_t l = 0;
	const unsigned char *q = ccder_decode_uint64(&l, p, body_end);
	if (q)
		p = q;
	*(size_t *)((char *)g + 32 + 32 * n) = l ? (l < 160 ? 160 : l) : 0;
	return p;
}
