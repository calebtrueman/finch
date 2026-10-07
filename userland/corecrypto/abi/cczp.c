/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "cczp.h"
#include <openssl/bn.h>
#include <string.h>
#include <stdlib.h>
#define API __attribute__((visibility("default")))
API size_t cczp_n(const struct cczp *z)
{
	return z->n;
}
API size_t cczp_bitlen(const struct cczp *z)
{
	return z->bitlen;
}
API cc_unit *cczp_prime(const struct cczp *z)
{
	return (cc_unit *)z->data;
}
static int calc(
    const struct cczp *z, cc_unit *r, const cc_unit *a, const cc_unit *b, int op, int mm)
{
	BN_CTX *c = BN_CTX_new();
	BIGNUM *p = BN_lebin2bn((void *)z->data, (int)z->n * 8, NULL),
	       *x = BN_lebin2bn((void *)a, (int)z->n * 8 * (op == 3 ? 2 : 1), NULL),
	       *y = b ? BN_lebin2bn((void *)b, (int)z->n * 8, NULL) : NULL, *v = BN_new(),
	       *rad = BN_new();
	int ok = 0;
	if (!c || !p || !x || !v || !rad || (b && !y))
		goto done;
	switch (op) {
	case 0:
		ok = BN_mod_add(v, x, y, p, c);
		break;
	case 1:
		ok = BN_mod_sub(v, x, y, p, c);
		break;
	case 2:
		ok = BN_mod_mul(v, x, y, p, c);
		break;
	case 3:
		ok = BN_nnmod(v, x, p, c);
		break;
	case 4:
		ok = BN_mod_inverse(v, x, p, c) != NULL;
		break;
	case 5:
		ok = BN_mod_sqrt(v, x, p, c) != NULL;
		break;
	default:
		ok = BN_copy(v, x) != NULL;
	}
	if (ok && mm) {
		BN_one(rad);
		BN_lshift(rad, rad, (int)z->n * 64);
		if (mm < 0)
			ok = BN_mod_inverse(rad, rad, p, c) != NULL;
		if (ok)
			ok = BN_mod_mul(v, v, rad, p, c);
	}
	if (ok)
		ok = BN_bn2lebinpad(v, (void *)r, (int)z->n * 8) >= 0;
done:
	BN_clear_free(p);
	BN_clear_free(x);
	BN_clear_free(y);
	BN_clear_free(v);
	BN_clear_free(rad);
	BN_CTX_free(c);
	return ok ? 0 : -7;
}
#define BIN(name, op, mm)                                                                          \
	static void name(                                                                          \
	    void *w, const struct cczp *z, cc_unit *r, const cc_unit *a, const cc_unit *b)         \
	{                                                                                          \
		(void)w;                                                                           \
		calc(z, r, a, b, op, mm);                                                          \
	}
BIN(add, 0, 0)
BIN(sub, 1, 0) BIN(mul, 2, 0)
    BIN(mmul, 2, -1) static void sqr(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	mul(w, z, r, a, a);
}
static void msqr(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	mmul(w, z, r, a, a);
}
static void mod(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	(void)w;
	calc(z, r, a, NULL, 3, 0);
}
static void mmod(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	(void)w;
	calc(z, r, a, NULL, 3, -1);
}
static int inv(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	(void)w;
	if (ccn_cmp(z->n, a, z->data) >= 0)
		return -7;
	return calc(z, r, a, NULL, 4, 0);
}
static int minv(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	(void)w;
	int e = calc(z, r, a, NULL, 4, 1);
	return e ? e : calc(z, r, r, NULL, 6, 1);
}
static int sqrtp(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	(void)w;
	return calc(z, r, a, NULL, 5, 0);
}
static void copy(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	(void)w;
	memmove(r, a, z->n * 8);
}
static void to(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	(void)w;
	calc(z, r, a, NULL, 6, 1);
}
static void from(void *w, const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	(void)w;
	calc(z, r, a, NULL, 6, -1);
}
static const struct cczp_funcs normal = {add, sub, mul, sqr, mod, inv, sqrtp, copy, copy};
static const struct cczp_funcs mont = {add, sub, mmul, msqr, mmod, minv, sqrtp, to, from};
int finch_cczp_init(struct cczp *z, int mm)
{
	if (!z || !z->n || !(z->data[0] & 1) || ccn_bitlen(z->n, z->data) < 2)
		return -7;
	z->bitlen = ccn_bitlen(z->n, z->data);
	z->funcs = mm ? &mont : &normal;
	cc_unit inverse = 1;
	for (int i = 0; i < 6; i++)
		inverse *= 2 - z->data[0] * inverse;
	z->data[z->n] = -inverse;
	BN_CTX *c = BN_CTX_new();
	BIGNUM *p = BN_lebin2bn((void *)z->data, (int)z->n * 8, NULL), *r = BN_new();
	int ok = c && p && r && BN_one(r) && BN_lshift(r, r, (int)z->n * 128) &&
	    BN_nnmod(r, r, p, c) &&
	    BN_bn2lebinpad(r, (void *)(z->data + z->n + 1), (int)z->n * 8) >= 0;
	BN_free(p);
	BN_free(r);
	BN_CTX_free(c);
	return ok ? 0 : -13;
}
/* A bounded scratch area lets a caller-provided function table run too. */
struct workspace {
	cc_unit *mem;
	size_t count, used;
	cc_unit *(*alloc)(struct workspace *, size_t);
	void (*free)(struct workspace *);
};
static cc_unit *ws_alloc(struct workspace *w, size_t n)
{
	if (n > w->count - w->used)
		abort();
	cc_unit *p = w->mem + w->used;
	w->used += n;
	return p;
}
static void ws_free(struct workspace *w)
{
	(void)w;
}
static int dispatch(const struct cczp *z, cc_unit *r, const cc_unit *a, const cc_unit *b, int op)
{
	if (!z || !z->n || z->n > SIZE_MAX / 512 || !z->funcs)
		return -7;
	struct workspace w = {0};
	w.count = 64 * z->n + 64;
	w.mem = calloc(w.count, 8);
	w.alloc = ws_alloc;
	w.free = ws_free;
	if (!w.mem)
		return -13;
	int ret = 0;
	switch (op) {
	case 0:
		z->funcs->add(&w, z, r, a, b);
		break;
	case 1:
		z->funcs->sub(&w, z, r, a, b);
		break;
	case 2:
		z->funcs->mul(&w, z, r, a, b);
		break;
	case 3:
		z->funcs->mod(&w, z, r, a);
		break;
	case 4:
		ret = z->funcs->inv(&w, z, r, a);
		break;
	}
	memset(w.mem, 0, w.count * 8);
	free(w.mem);
	return ret;
}
API int cczp_add(const struct cczp *z, cc_unit *r, const cc_unit *a, const cc_unit *b)
{
	return dispatch(z, r, a, b, 0);
}
API int cczp_sub(const struct cczp *z, cc_unit *r, const cc_unit *a, const cc_unit *b)
{
	return dispatch(z, r, a, b, 1);
}
API int cczp_mul(const struct cczp *z, cc_unit *r, const cc_unit *a, const cc_unit *b)
{
	return dispatch(z, r, a, b, 2);
}
API int cczp_mod(const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	return dispatch(z, r, a, NULL, 3);
}
API int cczp_inv(const struct cczp *z, cc_unit *r, const cc_unit *a)
{
	return dispatch(z, r, a, NULL, 4);
}
