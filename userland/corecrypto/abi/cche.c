/* SPDX-License-Identifier: MIT OR Apache-2.0
 * HE parameter layout, modular transforms, and plaintext encoding. */
#include "cche.h"
#include "cczp.h"
#include <openssl/bn.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#define EXPORT __attribute__((visibility("default")))
struct parameter {
	uint64_t t;
	uint32_t n, l, skip[2];
	uint64_t q[5];
	size_t bytes;
};
static const struct parameter parameters[] = {
    {17, 8, 5, {9, 5}, {0x200b1, 0x200e1, 0x20171, 0x201a1, 0x20221}, 8128},
    {525313, 512, 4, {36, 29},
        {0x800000000003401, 0x800000000004001, 0x800000000005c01, 0x80000000000bc01}, 105424},
    {4099, 4096, 3, {11, 3}, {0x7ff6001, 0xfff0001, 0xffee001}, 448656},
    {2199023288321, 8192, 3, {11, 0}, {0x7ffffffffb4001, 0x7fffffffeac001, 0x7fffffffe90001},
        858256},
    {536903681, 8192, 3, {22, 13}, {0x7ffffffffb4001, 0x7fffffffeac001, 0x7fffffffe90001}, 858256},
    {268582913, 8192, 3, {23, 14}, {0x7ffffffffb4001, 0x7fffffffeac001, 0x7fffffffe90001}, 858256},
    {17, 4096, 3, {19, 11}, {0x7ff6001, 0xfff0001, 0xffee001}, 448656},
    {8404993, 8192, 3, {28, 19}, {0x7ffffffffb4001, 0x7fffffffeac001, 0x7fffffffe90001}, 858256},
    {16411, 8192, 3, {11, 2}, {0x1ffd4001, 0xfffffffffffc001, 0xffffffffffe8001}, 858256},
    {33832961, 8192, 3, {11, 2}, {0xfffffdc001, 0xfffffffffffc001, 0xffffffffffe8001}, 858256},
    {557057, 8192, 3, {6, 0}, {0xfff0001, 0xfffffffffffc001, 0xffffffffffe8001}, 858256},
    {11, 4096, 3, {9, 0}, {0xa001, 0x1fffec001, 0x1fffea001}, 448656},
    {16417, 16, 1, {42, 38}, {0xfffffffffffc001}, 5120},
    {37, 4096, 3, {18, 10}, {0x7ff6001, 0xfff0001, 0xffee001}, 448656},
    {40961, 4096, 3, {9, 0}, {0x7ff6001, 0xfff0001, 0xffee001}, 448656},
    {65537, 4096, 3, {8, 0}, {0x7ff6001, 0xfff0001, 0xffee001}, 448656},
    {11, 4096, 3, {20, 12}, {0x7ff6001, 0xfff0001, 0xffee001}, 448656}};
EXPORT uint64_t cche_encryption_params_plaintext_modulus(unsigned id)
{
	return id < 17 ? parameters[id].t : 0;
}
EXPORT uint32_t cche_encryption_params_polynomial_degree(unsigned id)
{
	return id < 17 ? parameters[id].n : 0;
}
EXPORT uint32_t cche_encryption_params_coefficient_nmoduli(unsigned id)
{
	return id < 17 ? parameters[id].l : 0;
}
EXPORT void cche_encryption_params_coefficient_moduli(size_t n, uint64_t *out, unsigned id)
{
	if (id < 17) {
		if (n > parameters[id].l)
			n = parameters[id].l;
		memcpy(out, parameters[id].q, n * 8);
	}
}
EXPORT size_t cche_param_ctx_sizeof(unsigned id)
{
	return id < 17 ? parameters[id].bytes : 0;
}
EXPORT uint32_t cche_param_ctx_he_scheme(const struct he_params *p)
{
	return p->scheme;
}
EXPORT uint64_t cche_param_ctx_plaintext_modulus(const struct he_params *p)
{
	return p->t;
}
EXPORT uint32_t cche_param_ctx_polynomial_degree(const struct he_params *p)
{
	return p->n;
}
EXPORT uint32_t cche_param_ctx_key_ctx_nmoduli(const struct he_params *p)
{
	return p->l;
}
EXPORT uint32_t cche_param_ctx_ciphertext_ctx_nmoduli(const struct he_params *p)
{
	return p->l > 1 ? p->l - 1 : 1;
}
EXPORT const uint64_t *cche_param_ctx_coefficient_moduli(const struct he_params *p)
{
	return p->q;
}
EXPORT bool cche_param_ctx_supports_simd_encoding(const struct he_params *p)
{
	return p->t % (2 * p->n) == 1;
}
size_t finch_he_ring_size(uint32_t n)
{
	return 168 + 16 * (size_t)n + 48 * (n < 128 ? n : 128);
}
struct he_ring *finch_he_ring(const struct he_params *p, uint32_t l)
{
	return (void *)((unsigned char *)p + 40 + 8 * p->l + (p->l - l) * finch_he_ring_size(p->n));
}
struct he_ring *finch_he_plain_ring(const struct he_params *p)
{
	return finch_he_ring(p, 0);
}
struct he_poly *finch_he_poly(struct he_cipher *c, uint32_t i)
{
	struct he_poly *p = (void *)c->data;
	return (void *)(c->data + i * (8 + 8 * (size_t)p->ctx->n * p->ctx->l));
}
uint64_t finch_he_modulus(const struct he_ring *r, uint32_t i)
{
	while (r->l > i + 1)
		r = r->next;
	return r->mod[0];
}
uint64_t finch_he_mul(uint64_t a, uint64_t b, uint64_t q)
{
	return (uint64_t)((__uint128_t)a * b % q);
}
uint64_t finch_he_pow(uint64_t a, uint64_t b, uint64_t q)
{
	uint64_t r = 1;
	for (; b; b >>= 1, a = finch_he_mul(a, a, q))
		if (b & 1)
			r = finch_he_mul(r, a, q);
	return r;
}
static unsigned reverse(unsigned v, unsigned bits)
{
	unsigned r = 0;
	while (bits--) {
		r = (r << 1) | (v & 1);
		v >>= 1;
	}
	return r;
}
static uint64_t root(uint64_t q, unsigned n)
{
	uint64_t w = 0;
	for (uint64_t i = 2; i < q; i++) {
		w = finch_he_pow(i, (q - 1) / (2 * n), q);
		if (finch_he_pow(w, n, q) == q - 1)
			break;
	}
	uint64_t step = finch_he_mul(w, w, q), best = w, x = w;
	for (unsigned i = 1; i < n; i++) {
		x = finch_he_mul(x, step, q);
		if (x < best)
			best = x;
	}
	return best;
}
static void mulmod(uint64_t *out, uint64_t q, uint64_t a)
{
	out[0] = q;
	out[1] = a;
	out[2] = (uint64_t)(((__uint128_t)a << 64) / q);
}
int finch_he_ring_init(struct he_ring *r, unsigned n, unsigned l, uint64_t q, struct he_ring *next)
{
	memset(r, 0, finch_he_ring_size(n));
	r->n = n;
	r->l = l;
	r->next = next;
	r->mod[0] = q;
	r->mod[1] = (uint64_t)(((__uint128_t)1 << 64) / q);
	__uint128_t recip = (~(__uint128_t)0) / q;
	r->mod[2] = recip;
	r->mod[3] = recip >> 64;
	BN_CTX *bc = BN_CTX_new();
	BIGNUM *a = BN_new(), *b = BN_new(), *d = BN_new();
	int ok = bc && a && b && d && BN_one(a) && BN_lshift(a, a, 128 + 64 - __builtin_clzll(q)) &&
	    BN_set_word(b, q) && BN_add_word(a, q - 1) && BN_div(d, NULL, a, b, bc);
	if (ok) {
		BN_one(a);
		BN_lshift(a, a, 128);
		ok = BN_sub(d, d, a);
		if (ok)
			BN_bn2lebinpad(d, (void *)(r->mod + 4), 16);
	}
	BN_free(a);
	BN_free(b);
	BN_free(d);
	BN_CTX_free(bc);
	if (!ok)
		return -1;
	struct cczp *z = (void *)r->data;
	z->n = 1;
	z->data[0] = q;
	if (finch_cczp_init(z, 0))
		return -1;
	r->ntt = q % (2 * n) == 1;
	if (!r->ntt)
		return 0;
	unsigned lg = 31 - __builtin_clz(n), m = n < 128 ? n : 128;
	uint64_t w = root(q, n), winv = finch_he_pow(w, q - 2, q), x = 1;
	uint64_t *f = (void *)((unsigned char *)r + 168), *fm = f + n, *iv = fm + 3 * m,
	         *im = iv + n;
	for (unsigned i = 0; i < n; i++) {
		f[reverse(i, lg)] = x;
		x = finch_he_mul(x, w, q);
	}
	for (unsigned i = 1; i < m; i++)
		mulmod(fm + 3 * i, q, f[i]);
	iv[0] = 1;
	x = 1;
	unsigned k = 1;
	for (unsigned batch = n / 2; batch; batch /= 2) {
		for (unsigned i = batch; i < 2 * batch; i++) {
			x = finch_he_mul(x, winv, q);
			iv[reverse(i, lg)] = x;
		}
		k += batch;
	}
	(void)k;
	for (unsigned i = 0; i < m && i < n - 1; i++)
		mulmod(im + 3 * i, q, iv[n - 1 - i]);
	uint64_t ni = finch_he_pow(n, q - 2, q);
	mulmod(r->inv_n, q, ni);
	mulmod(r->inv_last, q, finch_he_mul(ni, iv[n - 1], q));
	return 0;
}
/* Tables following the ring contexts are filled by the arithmetic layer. */
int finch_he_extra_init(struct he_params *);
EXPORT int cche_param_ctx_init(struct he_params *p, unsigned scheme, unsigned id)
{
	if (id >= 17 || (scheme != 1 && scheme != 2))
		return -7;
	const struct parameter *v = parameters + id;
	memset(p, 0, v->bytes);
	p->scheme = scheme;
	p->t = v->t;
	p->n = v->n;
	p->l = v->l;
	p->skip[0] = v->skip[0];
	p->skip[1] = v->skip[1];
	memcpy(p->q, v->q, 8 * v->l);
	uint32_t *chain = (void *)(p->q + p->l);
	chain[0] = p->n;
	chain[1] = p->l;
	for (unsigned l = p->l; l; l--) {
		int rc = finch_he_ring_init(finch_he_ring(p, l), p->n, l, p->q[l - 1],
		    l > 1 ? finch_he_ring(p, l - 1) : NULL);
		if (rc)
			return rc;
	}
	int rc = finch_he_ring_init(finch_he_plain_ring(p), p->n, 1, p->t, NULL);
	if (rc)
		return rc;
	uint32_t *map =
	    (void *)((unsigned char *)finch_he_plain_ring(p) + finch_he_ring_size(p->n));
	unsigned lg = 31 - __builtin_clz(p->n), power = 1;
	for (unsigned i = 0; i < p->n / 2; i++) {
		map[i] = reverse((power - 1) / 2, lg);
		map[p->n / 2 + i] = reverse((2 * p->n - power - 1) / 2, lg);
		power = power * 3 % (2 * p->n);
	}
	return finch_he_extra_init(p);
}
int finch_he_ntt(struct he_poly *p, int inverse)
{
	unsigned n = p->ctx->n, l = p->ctx->l;
	if (!p->ctx->ntt)
		return -7;
	for (unsigned limb = 0; limb < l; limb++) {
		uint64_t q = finch_he_modulus(p->ctx, limb), w = root(q, n);
		uint64_t *values = p->data + (size_t)limb * n, *roots = malloc(n * 8);
		if (!roots)
			return -13;
		unsigned lg = 31 - __builtin_clz(n);
		uint64_t x = 1;
		for (unsigned i = 0; i < n; i++) {
			roots[reverse(i, lg)] = x;
			x = finch_he_mul(x, w, q);
		}
		if (!inverse) {
			for (unsigned m = 1, t = n / 2; m < n; m *= 2, t /= 2)
				for (unsigned i = 0; i < m; i++) {
					uint64_t z = roots[m + i];
					for (unsigned j = 2 * i * t; j < (2 * i + 1) * t; j++) {
						uint64_t a = values[j],
						         b = finch_he_mul(values[j + t], z, q);
						values[j] = (a + b) % q;
						values[j + t] = (a + q - b) % q;
					}
				}
		} else {
			for (unsigned m = n / 2, t = 1; m; m /= 2, t *= 2)
				for (unsigned i = 0; i < m; i++) {
					uint64_t z = finch_he_pow(roots[m + i], q - 2, q);
					for (unsigned j = 2 * i * t; j < (2 * i + 1) * t; j++) {
						uint64_t a = values[j], b = values[j + t];
						values[j] = (a + b) % q;
						values[j + t] = finch_he_mul((a + q - b) % q, z, q);
					}
				}
			uint64_t ni = finch_he_pow(n, q - 2, q);
			for (unsigned i = 0; i < n; i++)
				values[i] = finch_he_mul(values[i], ni, q);
		}
		free(roots);
	}
	return 0;
}
EXPORT size_t cche_plaintext_sizeof(const struct he_params *p)
{
	return 8 + 8 * (size_t)p->n;
}
EXPORT size_t cche_secret_key_sizeof(const struct he_params *p)
{
	return 8 + 8 * (size_t)p->n * p->l;
}
EXPORT size_t cche_ciphertext_sizeof(const struct he_params *p, uint32_t l, uint32_t npolys)
{
	return 24 + npolys * (8 + 8 * (size_t)p->n * l);
}
EXPORT size_t cche_dcrt_plaintext_sizeof(const struct he_params *p, uint32_t l)
{
	return 8 + 8 * (size_t)p->n * l;
}
EXPORT size_t cche_rng_seed_sizeof(void)
{
	return 32;
}
EXPORT uint32_t cche_ciphertext_fresh_npolys(void)
{
	return 2;
}
EXPORT uint64_t cche_ciphertext_fresh_correction_factor(void)
{
	return 1;
}
EXPORT uint64_t cche_ciphertext_correction_factor(const struct he_cipher *c)
{
	return c->correction;
}
EXPORT size_t cche_param_ctx_key_ctx_poly_nbytes(const struct he_params *p)
{
	size_t total = 0;
	for (unsigned i = 0; i < p->l; i++)
		total += ((64 - __builtin_clzll(p->q[i])) * (size_t)p->n + 7) / 8;
	return total;
}
EXPORT int cche_param_ctx_plaintext_modulus_inverse(
    uint64_t *out, const struct he_params *p, uint64_t value)
{
	BIGNUM *t = BN_new(), *a = BN_new();
	BN_CTX *c = BN_CTX_new();
	BIGNUM *inv = NULL;
	if (t && a && c && BN_set_word(t, p->t) && BN_set_word(a, value))
		inv = BN_mod_inverse(NULL, a, t, c);
	int rc = inv ? 0 : -7;
	if (inv)
		*out = BN_get_word(inv);
	BN_clear_free(inv);
	BN_free(a);
	BN_free(t);
	BN_CTX_free(c);
	return rc;
}
int finch_he_pack(size_t bn, void *out, size_t cn, const uint64_t *in, unsigned bits, unsigned skip)
{
	if (bits <= skip || bits > 64)
		return -7;
	unsigned b = bits - skip;
	if (cn > SIZE_MAX / b || bn > SIZE_MAX / 8)
		return -7;
	if (bn != (cn * b + 7) / 8 && cn != (bn * 8 + b - 1) / b)
		return -7;
	memset(out, 0, bn);
	for (size_t i = 0; i < bn * 8 && i < cn * b; i++) {
		unsigned bit = (in[i / b] >> (bits - 1 - i % b)) & 1;
		((unsigned char *)out)[i / 8] |= bit << (7 - i % 8);
	}
	return 0;
}
int finch_he_unpack(
    size_t cn, uint64_t *out, size_t bn, const void *in, unsigned bits, unsigned skip)
{
	if (bits <= skip || bits > 64)
		return -7;
	unsigned b = bits - skip;
	if (cn > SIZE_MAX / b || bn > SIZE_MAX / 8)
		return -7;
	if (bn != (cn * b + 7) / 8 && cn != (bn * 8 + b - 1) / b)
		return -7;
	memset(out, 0, cn * 8);
	for (size_t i = 0; i < bn * 8 && i < cn * b; i++)
		out[i / b] |= (uint64_t)((((const unsigned char *)in)[i / 8] >> (7 - i % 8)) & 1)
		    << (bits - 1 - i % b);
	return 0;
}
EXPORT int cche_bytes_to_coeffs(size_t cn, uint64_t *out, size_t bn, const void *in, unsigned bits)
{
	return finch_he_unpack(cn, out, bn, in, bits, 0);
}
EXPORT int cche_coeffs_to_bytes(size_t bn, void *out, size_t cn, const uint64_t *in, unsigned bits)
{
	return finch_he_pack(bn, out, cn, in, bits, 0);
}
EXPORT int cche_encode_poly_uint64(
    struct he_poly *out, const struct he_params *p, uint32_t n, const uint64_t *in)
{
	out->ctx = finch_he_plain_ring(p);
	if (n > p->n)
		return -7;
	for (unsigned i = 0; i < n; i++) {
		if (in[i] >= p->t)
			return -7;
		out->data[i] = in[i];
	}
	memset(out->data + n, 0, 8 * (p->n - n));
	return 0;
}
EXPORT int cche_decode_poly_uint64(uint32_t n, uint64_t *out, const struct he_poly *p)
{
	if (n > p->ctx->n)
		return -7;
	for (unsigned i = 0; i < n; i++) {
		if (p->data[i] >= p->ctx->mod[0])
			return -1;
		out[i] = p->data[i];
	}
	return 0;
}
EXPORT int cche_encode_simd_uint64(
    struct he_poly *out, const struct he_params *p, uint32_t n, const uint64_t *in)
{
	out->ctx = finch_he_plain_ring(p);
	if (n > p->n || !out->ctx->ntt)
		return -7;
	const uint32_t *map = (void *)((unsigned char *)out->ctx + finch_he_ring_size(p->n));
	memset(out->data, 0, p->n * 8);
	for (unsigned i = 0; i < n; i++) {
		if (in[i] >= p->t)
			return -7;
		out->data[map[i]] = in[i];
	}
	return finch_he_ntt(out, 1);
}
EXPORT int cche_encode_simd_int64(
    struct he_poly *out, const struct he_params *p, uint32_t n, const int64_t *in)
{
	if (n > p->n)
		return -7;
	uint64_t *v = malloc(n ? n * 8 : 1);
	if (!v)
		return -13;
	int rc = 0;
	for (unsigned i = 0; i < n; i++) {
		if (in[i] < -(int64_t)(p->t / 2) || in[i] > (int64_t)(p->t / 2)) {
			rc = -7;
			break;
		}
		v[i] = in[i] < 0 ? p->t - (uint64_t)(-in[i]) : (uint64_t)in[i];
	}
	if (!rc)
		rc = cche_encode_simd_uint64(out, p, n, v);
	free(v);
	return rc;
}
EXPORT int cche_encode_simd_reduced_int64(
    struct he_poly *out, const struct he_params *p, uint32_t n, const int64_t *in)
{
	if (n > p->n)
		return -7;
	uint64_t *v = malloc(n ? n * 8 : 1);
	if (!v)
		return -13;
	for (unsigned i = 0; i < n; i++) {
		int64_t z = in[i] % (int64_t)p->t;
		v[i] = z < 0 ? p->t + z : (uint64_t)z;
	}
	int rc = cche_encode_simd_uint64(out, p, n, v);
	free(v);
	return rc;
}
EXPORT int cche_decode_simd_uint64(
    const struct he_params *p, uint32_t n, uint64_t *out, const struct he_poly *in)
{
	if (n > p->n)
		return -7;
	struct he_poly *tmp = malloc(8 + 8 * (size_t)p->n);
	if (!tmp)
		return -13;
	memcpy(tmp, in, 8 + 8 * (size_t)p->n);
	int rc = finch_he_ntt(tmp, 0);
	if (!rc) {
		const uint32_t *map =
		    (void *)((unsigned char *)finch_he_plain_ring(p) + finch_he_ring_size(p->n));
		for (unsigned i = 0; i < n; i++)
			out[i] = tmp->data[map[i]];
	}
	free(tmp);
	return rc;
}
EXPORT int cche_decode_simd_int64(
    const struct he_params *p, uint32_t n, int64_t *out, const struct he_poly *in)
{
	int rc = cche_decode_simd_uint64(p, n, (uint64_t *)out, in);
	if (!rc)
		for (unsigned i = 0; i < n; i++)
			if ((uint64_t)out[i] > p->t / 2)
				out[i] -= p->t;
	return rc;
}
EXPORT int cche_ciphertext_fwd_ntt(struct he_cipher *c)
{
	for (unsigned i = 0; i < c->npolys; i++) {
		int rc = finch_he_ntt(finch_he_poly(c, i), 0);
		if (rc)
			return rc;
	}
	return 0;
}
EXPORT int cche_ciphertext_inv_ntt(struct he_cipher *c)
{
	for (unsigned i = 0; i < c->npolys; i++) {
		int rc = finch_he_ntt(finch_he_poly(c, i), 1);
		if (rc)
			return rc;
	}
	return 0;
}
