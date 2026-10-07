/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "cche.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
static size_t poly_size(const struct he_ring *r, unsigned skip)
{
	size_t n = 0;
	for (unsigned i = 0; i < r->l; i++) {
		unsigned bits = 64 - __builtin_clzll(finch_he_modulus(r, i));
		if (skip >= bits)
			return 0;
		n += ((bits - skip) * (size_t)r->n + 7) / 8;
	}
	return n;
}
static int poly_write(void *out, const struct he_poly *p, unsigned skip)
{
	if (skip && p->ctx->l != 1)
		return -7;
	unsigned char *b = out;
	for (unsigned i = 0; i < p->ctx->l; i++) {
		unsigned bits = 64 - __builtin_clzll(finch_he_modulus(p->ctx, i));
		if (skip >= bits)
			return -7;
		size_t n = ((bits - skip) * (size_t)p->ctx->n + 7) / 8;
		int rc =
		    finch_he_pack(n, b, p->ctx->n, p->data + (size_t)i * p->ctx->n, bits, skip);
		if (rc)
			return rc;
		b += n;
	}
	return 0;
}
int finch_he_poly_read(struct he_poly *p, const void *in, unsigned skip)
{
	if (skip && p->ctx->l != 1)
		return -7;
	const unsigned char *b = in;
	for (unsigned i = 0; i < p->ctx->l; i++) {
		unsigned bits = 64 - __builtin_clzll(finch_he_modulus(p->ctx, i));
		if (skip >= bits)
			return -7;
		size_t n = ((bits - skip) * (size_t)p->ctx->n + 7) / 8;
		int rc =
		    finch_he_unpack(p->ctx->n, p->data + (size_t)i * p->ctx->n, n, b, bits, skip);
		if (rc)
			return rc;
		b += n;
	}
	return 0;
}
EXPORT size_t cche_serialize_ciphertext_coeff_nbytes(
    const struct he_cipher *c, const uint32_t *skip)
{
	size_t n = 2;
	const struct he_poly *p = (void *)c->data;
	for (unsigned i = 0; i < c->npolys; i++)
		n += poly_size(p->ctx, skip ? skip[i] : 0);
	return n;
}
EXPORT size_t cche_serialize_ciphertext_eval_nbytes(const struct he_cipher *c)
{
	return cche_serialize_ciphertext_coeff_nbytes(c, NULL);
}
EXPORT size_t cche_serialize_seeded_ciphertext_coeff_nbytes(const struct he_cipher *c)
{
	const struct he_poly *p = (void *)c->data;
	return poly_size(p->ctx, 0);
}
EXPORT size_t cche_serialize_seeded_ciphertext_eval_nbytes(const struct he_cipher *c)
{
	return cche_serialize_seeded_ciphertext_coeff_nbytes(c);
}
EXPORT void cche_serialize_ciphertext_coeff_max_nskip_lsbs(uint32_t *out, const struct he_cipher *c)
{
	memset(out, 0, c->npolys * 4);
	if (c->npolys == 2) {
		out[0] = c->params->skip[0];
		out[1] = c->params->skip[1];
	}
}
EXPORT int cche_serialize_ciphertext_coeff(
    size_t n, void *out, const struct he_cipher *c, const uint32_t *skip)
{
	if (n != cche_serialize_ciphertext_coeff_nbytes(c, skip) || c->npolys > 65535)
		return -7;
	if (skip &&
	    (c->npolys != 2 || skip[0] > c->params->skip[0] || skip[1] > c->params->skip[1]))
		return -7;
	unsigned char *b = out;
	b[0] = c->npolys;
	b[1] = c->npolys >> 8;
	b += 2;
	for (unsigned i = 0; i < c->npolys; i++) {
		const struct he_poly *p = finch_he_poly((void *)c, i);
		unsigned s = skip ? skip[i] : 0;
		int rc = poly_write(b, p, s);
		if (rc)
			return rc;
		b += poly_size(p->ctx, s);
	}
	return 0;
}
EXPORT int cche_serialize_ciphertext_eval(size_t n, void *out, const struct he_cipher *c)
{
	return cche_serialize_ciphertext_coeff(n, out, c, NULL);
}
EXPORT int cche_deserialize_ciphertext_coeff(struct he_cipher *c, size_t n, const void *in,
    const struct he_params *p, unsigned l, unsigned np, uint64_t correction, const uint32_t *skip)
{
	if (!l || l > p->l)
		return -7;
	c->params = p;
	c->npolys = np;
	c->correction = correction;
	struct he_ring *r = finch_he_ring(p, l);
	for (unsigned i = 0; i < np; i++) {
		struct he_poly *poly = (void *)(c->data + i * (8 + 8 * (size_t)r->n * r->l));
		poly->ctx = r;
	}
	if (n != cche_serialize_ciphertext_coeff_nbytes(c, skip) || n < 2)
		return -7;
	const unsigned char *b = in;
	if ((unsigned)(b[0] | b[1] << 8) != np)
		return -7;
	b += 2;
	for (unsigned i = 0; i < np; i++) {
		struct he_poly *poly = finch_he_poly(c, i);
		unsigned s = skip ? skip[i] : 0;
		int rc = finch_he_poly_read(poly, b, s);
		if (rc)
			return rc;
		b += poly_size(r, s);
	}
	return 0;
}
EXPORT int cche_deserialize_ciphertext_eval(struct he_cipher *c, size_t n, const void *in,
    const struct he_params *p, unsigned l, unsigned np, uint64_t correction)
{
	return cche_deserialize_ciphertext_coeff(c, n, in, p, l, np, correction, NULL);
}
EXPORT int cche_serialize_seeded_ciphertext_coeff(size_t n, void *out, const struct he_cipher *c)
{
	if (n != cche_serialize_seeded_ciphertext_coeff_nbytes(c) || c->npolys != 2)
		return -7;
	return poly_write(out, (const void *)c->data, 0);
}
EXPORT int cche_serialize_seeded_ciphertext_eval(size_t n, void *out, const struct he_cipher *c)
{
	return cche_serialize_seeded_ciphertext_coeff(n, out, c);
}
