/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Shamir sharing. Context and wire layouts were measured against the host;
 * polynomial arithmetic uses OpenSSL, with no vendor implementation copied. */
#include "ccss.h"
#include <openssl/bn.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#define API __attribute__((visibility("default")))
API size_t ccss_sizeof_parameters(size_t n)
{
	return 48 + ((2 * n + 14) & ~(size_t)15);
}
API size_t ccss_sizeof_generator(const struct ccss_parameters *p)
{
	return 16 + 8 * p->prime.n * p->threshold;
}
API size_t ccss_sizeof_share(const struct ccss_parameters *p)
{
	return 16 + 8 * p->prime.n;
}
API size_t ccss_sizeof_share_bag(const struct ccss_parameters *p)
{
	return 16 + 8 * (p->prime.n + 1) * p->threshold;
}
API size_t ccss_shamir_parameters_maximum_secret_length(const struct ccss_parameters *p)
{
	return p->prime.n * 8 - 1;
}
API int ccss_shamir_parameters_init(
    struct ccss_parameters *p, size_t n, const void *bytes, uint32_t t)
{
	if (t < 2)
		return -125;
	p->prime.n = (n + 7) / 8;
	int r = ccn_read_uint(p->prime.n, p->prime.data, n, bytes);
	if (r)
		return r;
	if ((r = finch_cczp_init(&p->prime, 0)))
		return r;
	if (ccn_bitlen(p->prime.n, p->prime.data) <= 32 && p->prime.data[0] <= t)
		return -128;
	p->threshold = t;
	return 0;
}
API void ccss_shamir_share_init(struct ccss_value *s, const struct ccss_parameters *p)
{
	s->prime = &p->prime;
}
API void ccss_shamir_share_bag_init(struct ccss_bag *b, const struct ccss_parameters *p)
{
	b->parameters = p;
	b->count = 0;
}
API bool csss_shamir_share_bag_can_recover_secret(const struct ccss_bag *b)
{
	return b->count >= b->parameters->threshold;
}
static BIGNUM *get(const cc_unit *x, size_t n)
{
	return n > INT_MAX / 8 ? NULL : BN_lebin2bn((const void *)x, (int)(n * 8), NULL);
}
static int put(const BIGNUM *x, cc_unit *out, size_t n)
{
	return BN_bn2lebinpad(x, (void *)out, (int)(n * 8)) == (int)(n * 8);
}
static int encode(const struct cczp *p, cc_unit *out, size_t n, const void *bytes)
{
	int r = ccn_read_uint(p->n, out, n, bytes);
	if (!r && ccn_cmp(p->n, out, p->data) >= 0)
		r = -120;
	if (r)
		memset(out, 0, p->n * 8);
	return r;
}
static int initialize(struct ccss_value *g, const struct ccss_parameters *p,
    struct ccrng_state *rng, size_t n, const void *secret, int loose)
{
	g->prime = &p->prime;
	g->index = p->threshold - 1;
	if (!loose && n >= (p->prime.bitlen + 7) / 8)
		return -120;
	size_t bits = p->prime.bitlen + 64, words = (bits + 63) / 64;
	cc_unit *raw = calloc(words, 8);
	BIGNUM *mod = get(p->prime.data, p->prime.n), *v = BN_new(), *a = BN_new();
	BN_CTX *c = BN_CTX_new();
	int ret = -13;
	if (!raw || !mod || !v || !a || !c)
		goto done;
	for (uint32_t i = 0; i < p->threshold; i++) {
		ret = rng->generate(rng, words * 8, raw);
		if (ret)
			goto done;
		if (bits % 64)
			raw[words - 1] &= (UINT64_C(1) << (bits % 64)) - 1;
		if (i == g->index)
			BN_sub_word(mod, 1);
		if (!BN_lebin2bn((void *)raw, (int)(words * 8), a) || !BN_nnmod(v, a, mod, c)) {
			ret = -13;
			goto done;
		}
		if (i == g->index)
			BN_add_word(v, 1);
		if (!put(v, g->data + i * p->prime.n, p->prime.n)) {
			ret = -13;
			goto done;
		}
	}
	ret = encode(&p->prime, g->data, n, secret);
done:
	if (raw) {
		memset(raw, 0, words * 8);
		free(raw);
	}
	BN_clear_free(v);
	BN_clear_free(a);
	BN_free(mod);
	BN_CTX_free(c);
	return ret;
}
API int ccss_shamir_share_generator_init(struct ccss_value *g, const struct ccss_parameters *p,
    struct ccrng_state *r, const void *s, size_t n)
{
	return initialize(g, p, r, n, s, 0);
}
API int ccss_shamir_share_generator_init_with_secrets_less_than_prime(struct ccss_value *g,
    const struct ccss_parameters *p, struct ccrng_state *r, const void *s, size_t n)
{
	return initialize(g, p, r, n, s, 1);
}
static int same(const struct cczp *a, const struct cczp *b)
{
	size_t n = a->n > b->n ? a->n : b->n;
	for (size_t i = 0; i < n; i++)
		if ((i < a->n ? a->data[i] : 0) != (i < b->n ? b->data[i] : 0))
			return 0;
	return 1;
}
API int ccss_shamir_share_generator_generate_share(
    const struct ccss_value *g, uint32_t x, struct ccss_value *s)
{
	if (!x || (g->prime->bitlen <= 32 && x >= g->prime->data[0]))
		return -131;
	if (!same(g->prime, s->prime))
		return -130;
	size_t n = g->prime->n;
	BIGNUM *p = get(g->prime->data, n), *v = get(g->data + g->index * n, n), *a = NULL,
	       *bx = BN_new();
	BN_CTX *c = BN_CTX_new();
	int ret = -13;
	if (!p || !v || !bx || !c || !BN_set_word(bx, x))
		goto done;
	for (uint32_t i = g->index; i > 0; i--) {
		a = get(g->data + (i - 1) * n, n);
		if (!a || !BN_mod_mul(v, v, bx, p, c) || !BN_mod_add(v, v, a, p, c))
			goto done;
		BN_clear_free(a);
		a = NULL;
	}
	if (put(v, s->data, s->prime->n)) {
		s->index = x;
		ret = 0;
	}
done:
	BN_free(p);
	BN_clear_free(v);
	BN_clear_free(a);
	BN_free(bx);
	BN_CTX_free(c);
	return ret;
}
API size_t ccss_shamir_share_sizeof_y(const struct ccss_value *s)
{
	return s->prime->n * 8;
}
API int ccss_shamir_share_export(const struct ccss_value *s, uint32_t *x, void *y, size_t n)
{
	int r = ccn_write_uint_padded_ct(s->prime->n, s->data, n, y);
	if (r < 0)
		return r;
	*x = s->index;
	return 0;
}
API int ccss_shamir_share_import(struct ccss_value *s, uint32_t x, const void *y, size_t n)
{
	int r = encode(s->prime, s->data, n, y);
	if (!r)
		s->index = x;
	return r;
}
API int ccss_shamir_share_bag_add_share(struct ccss_bag *b, const struct ccss_value *s)
{
	const struct ccss_parameters *p = b->parameters;
	if (b->count >= p->threshold)
		return -126;
	if (!same(&p->prime, s->prime))
		return -130;
	size_t stride = p->prime.n + 1;
	for (uint32_t i = 0; i < b->count; i++)
		if ((uint32_t)b->data[i * stride] == s->index)
			return -127;
	cc_unit *out = b->data + b->count * stride;
	memcpy(out, &s->index, 4);
	memcpy(out + 1, s->data, p->prime.n * 8);
	b->count++;
	return 0;
}
API int ccss_shamir_share_bag_recover_secret(const struct ccss_bag *b, void *out, size_t len)
{
	if (!csss_shamir_share_bag_can_recover_secret(b))
		return -121;
	size_t n = b->parameters->prime.n, stride = n + 1;
	BN_CTX *c = BN_CTX_new();
	BIGNUM *p = get(b->parameters->prime.data, n), *sum = BN_new(), *term = BN_new(),
	       *num = BN_new(), *den = BN_new(), *xi = BN_new(), *xj = BN_new(), *diff = BN_new(),
	       *inv = NULL;
	int ret = -13;
	if (!c || !p || !sum || !term || !num || !den || !xi || !xj || !diff)
		goto done;
	BN_zero(sum);
	for (uint32_t i = 0; i < b->count; i++) {
		BN_one(num);
		BN_one(den);
		BN_set_word(xi, (uint32_t)b->data[i * stride]);
		for (uint32_t j = 0; j < b->count; j++)
			if (i != j) {
				BN_set_word(xj, (uint32_t)b->data[j * stride]);
				if (BN_cmp(xi, xj) == 0) {
					ret = -124;
					goto done;
				}
				if (!BN_mod_sub(diff, xj, xi, p, c) ||
				    !BN_mod_mul(den, den, diff, p, c) ||
				    !BN_mod_mul(num, num, xj, p, c))
					goto done;
			}
		inv = BN_mod_inverse(NULL, den, p, c);
		if (!inv) {
			ret = -124;
			goto done;
		}
		if (!BN_lebin2bn((const void *)(b->data + i * stride + 1), (int)(n * 8), term) ||
		    !BN_mod_mul(term, term, num, p, c) || !BN_mod_mul(term, term, inv, p, c) ||
		    !BN_mod_add(sum, sum, term, p, c))
			goto done;
		BN_clear_free(inv);
		inv = NULL;
	}
	if (len < (size_t)BN_num_bytes(sum)) {
		ret = -7;
		goto done;
	}
	if (len > INT_MAX)
		goto done;
	ret = BN_bn2binpad(sum, out, (int)len) == (int)len ? 0 : -7;
done:
	BN_CTX_free(c);
	BN_free(p);
	BN_clear_free(sum);
	BN_clear_free(term);
	BN_clear_free(num);
	BN_clear_free(den);
	BN_free(xi);
	BN_free(xj);
	BN_clear_free(diff);
	BN_clear_free(inv);
	return ret;
}
API bool ccss_sizeof_shamir_share_generator_serialization(const struct ccss_value *g, size_t *out)
{
	size_t count = (size_t)g->index + 2, n = g->prime->n;
	if (n > SIZE_MAX / 8 || count > (SIZE_MAX - 9) / (n * 8))
		return false;
	*out = 9 + count * n * 8;
	return true;
}
static void be32(unsigned char *p, uint32_t v)
{
	p[0] = v >> 24;
	p[1] = v >> 16;
	p[2] = v >> 8;
	p[3] = v;
}
static uint32_t read32(const unsigned char *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
API int ccss_shamir_share_generator_serialize(size_t cap, void *out, const struct ccss_value *g)
{
	size_t need;
	if (!ccss_sizeof_shamir_share_generator_serialization(g, &need) || cap < need)
		return -7;
	unsigned char *p = out;
	p[0] = 1;
	size_t width = g->prime->n * 8;
	if (width > UINT32_MAX)
		return -12;
	be32(p + 1, (uint32_t)width);
	be32(p + 5, g->index);
	ccn_write_uint_padded_ct(g->prime->n, g->prime->data, width, p + 9);
	for (size_t i = 0; i <= (size_t)g->index; i++)
		ccn_write_uint_padded_ct(
		    g->prime->n, g->data + i * g->prime->n, width, p + 9 + (i + 1) * width);
	return 0;
}
API int ccss_shamir_share_generator_deserialize(
    struct ccss_value *g, const struct ccss_parameters *par, size_t len, const void *in)
{
	g->prime = &par->prime;
	g->index = par->threshold - 1;
	const unsigned char *p = in;
	if (len < 10 || p[0] != 1)
		return -7;
	size_t width = read32(p + 1);
	if (!width || (width + 7) / 8 != par->prime.n)
		return -7;
	g->index = read32(p + 5);
	if (g->index == UINT32_MAX || g->index + 1 != par->threshold ||
	    len != 9 + ((size_t)g->index + 2) * width)
		return -7;
	cc_unit *tmp = calloc(par->prime.n, 8);
	if (!tmp)
		return -13;
	int ret = -7;
	if (ccn_read_uint(par->prime.n, tmp, width, p + 9) ||
	    ccn_cmp(par->prime.n, tmp, par->prime.data))
		goto done;
	for (size_t i = 0; i <= (size_t)g->index; i++)
		if (encode(g->prime, g->data + i * par->prime.n, width, p + 9 + (i + 1) * width))
			goto done;
	ret = 0;
done:
	free(tmp);
	return ret;
}
API const unsigned char CCSS_PRIME_P192[24] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
API const unsigned char CCSS_PRIME_P224[28] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01};
API const unsigned char CCSS_PRIME_P256[32] = {0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
API const unsigned char CCSS_PRIME_P384[48] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff};
API const unsigned char CCSS_PRIME_P521[66] = {0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
