/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "cche.h"
#include "ccrng.h"
#include <openssl/crypto.h>
#include <stdlib.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
struct he_relin {
	const struct he_params *p;
	unsigned char data[];
};
struct he_galois {
	const struct he_params *p;
	uint32_t count, pad;
	unsigned char data[];
};
int cche_encrypt_zero_symmetric_eval(struct he_cipher *, const struct he_params *,
    const struct he_poly *, unsigned, void *, struct ccrng_state *);
size_t cche_param_ctx_key_ctx_poly_nbytes(const struct he_params *);
int cche_serialize_seeded_ciphertext_eval(size_t, void *, const struct he_cipher *);
int cche_deserialize_seeded_ciphertext_eval(struct he_cipher *, size_t, const void *, const void *,
    const struct he_params *, unsigned, uint64_t);
static size_t cipher_size(const struct he_params *p)
{
	return 24 + 2 * (8 + 8 * (size_t)p->n * p->l);
}
static unsigned key_count(const struct he_params *p)
{
	return p->l > 1 ? p->l - 1 : 1;
}
static struct he_cipher *relin_cipher(struct he_relin *k, unsigned i)
{
	return (void *)(k->data + i * cipher_size(k->p));
}
static struct he_cipher *galois_cipher(struct he_galois *k, unsigned elt, unsigned i)
{
	return (void *)(k->data + ((k->count * 4 + 7) & ~(size_t)7) +
	    (elt * key_count(k->p) + i) * cipher_size(k->p));
}
EXPORT size_t cche_relin_key_sizeof(const struct he_params *p)
{
	return 8 + key_count(p) * cipher_size(p);
}
EXPORT size_t cche_galois_key_sizeof(const struct he_params *p, unsigned nel)
{
	return 16 + ((4 * (size_t)nel + 7) & ~(size_t)7) + nel * key_count(p) * cipher_size(p);
}
static int add_key(struct he_cipher *c, const struct he_poly *image, unsigned limb)
{
	const struct he_params *p = c->params;
	struct he_poly *c0 = (void *)c->data;
	uint64_t q = p->q[limb], factor = p->q[p->l - 1] % q;
	for (unsigned j = 0; j < p->n; j++) {
		size_t i = (size_t)limb * p->n + j;
		c0->data[i] = (c0->data[i] + finch_he_mul(factor, image->data[i], q)) % q;
	}
	return 0;
}
EXPORT int cche_relin_key_generate(struct he_relin *out, const struct he_poly *sk,
    const struct he_params *p, unsigned seedn, void *seeds, struct ccrng_state *rng)
{
	if (p->l < 2 || (seedn && seedn != 32 * (p->l - 1)))
		return -7;
	out->p = p;
	size_t pn = 8 + 8 * (size_t)p->n * p->l;
	struct he_poly *sq = malloc(pn);
	if (!sq)
		return -13;
	sq->ctx = sk->ctx;
	for (unsigned k = 0; k < p->l; k++)
		for (unsigned j = 0; j < p->n; j++) {
			size_t i = (size_t)k * p->n + j;
			sq->data[i] = finch_he_mul(sk->data[i], sk->data[i], p->q[k]);
		}
	int rc = 0;
	for (unsigned k = 0; k < p->l - 1 && !rc; k++) {
		struct he_cipher *c = relin_cipher(out, k);
		rc = cche_encrypt_zero_symmetric_eval(
		    c, p, sk, p->l, seeds ? (unsigned char *)seeds + 32 * k : NULL, rng);
		if (!rc)
			rc = add_key(c, sq, k);
	}
	OPENSSL_clear_free(sq, pn);
	return rc;
}
EXPORT int cche_relin_key_save(unsigned n, void *out, const struct he_relin *key)
{
	const struct he_params *p = key->p;
	size_t bytes = cche_param_ctx_key_ctx_poly_nbytes(p);
	if (p->l < 2 || n != (p->l - 1) * bytes)
		return -7;
	for (unsigned i = 0; i < p->l - 1; i++) {
		int rc = cche_serialize_seeded_ciphertext_eval(
		    bytes, (unsigned char *)out + i * bytes, relin_cipher((void *)key, i));
		if (rc)
			return rc;
	}
	return 0;
}
EXPORT int cche_relin_key_load(struct he_relin *out, const struct he_params *p, unsigned n,
    const void *in, unsigned seedn, const void *seeds)
{
	size_t bytes = cche_param_ctx_key_ctx_poly_nbytes(p);
	if (p->l < 2 || n != (p->l - 1) * bytes || seedn != 32 * (p->l - 1))
		return -7;
	out->p = p;
	for (unsigned i = 0; i < p->l - 1; i++) {
		int rc = cche_deserialize_seeded_ciphertext_eval(relin_cipher(out, i), bytes,
		    (const unsigned char *)in + i * bytes, (const unsigned char *)seeds + 32 * i, p,
		    p->l, 1);
		if (rc)
			return rc;
	}
	return 0;
}
static unsigned reverse(unsigned x, unsigned lg)
{
	unsigned r = 0;
	for (unsigned j = 0; j < lg; j++) {
		r = (r << 1) | (x & 1);
		x >>= 1;
	}
	return r;
}
static int eval_galois(struct he_poly *out, const struct he_poly *in, unsigned elt)
{
	unsigned n = in->ctx->n, lg = 31 - __builtin_clz(n);
	if (elt < 3 || !(elt & 1) || elt >= 2 * n || out == in)
		return -7;
	out->ctx = in->ctx;
	for (unsigned k = 0; k < in->ctx->l; k++)
		for (unsigned j = 0; j < n; j++) {
			unsigned exponent = (2 * reverse(j, lg) + 1) * elt % (2 * n);
			out->data[(size_t)k * n + j] =
			    in->data[(size_t)k * n + reverse((exponent - 1) / 2, lg)];
		}
	return 0;
}
static int valid_elts(const struct he_params *p, unsigned n, const uint32_t *elts)
{
	if (!n || p->l < 2)
		return 0;
	for (unsigned i = 0; i < n; i++) {
		if (elts[i] < 3 || !(elts[i] & 1) || elts[i] >= 2 * p->n)
			return 0;
		for (unsigned j = 0; j < i; j++)
			if (elts[j] == elts[i])
				return 0;
	}
	return 1;
}
EXPORT int cche_galois_key_generate(struct he_galois *out, unsigned nel, const uint32_t *elts,
    const struct he_poly *sk, const struct he_params *p, unsigned seedn, void *seeds,
    struct ccrng_state *rng)
{
	if (!valid_elts(p, nel, elts) || (seedn && seedn != 32 * nel * (p->l - 1)))
		return -7;
	out->p = p;
	out->count = nel;
	memcpy(out->data, elts, nel * 4);
	size_t pn = 8 + 8 * (size_t)p->n * p->l;
	struct he_poly *image = malloc(pn);
	if (!image)
		return -13;
	int rc = 0;
	for (unsigned g = 0; g < nel && !rc; g++) {
		rc = eval_galois(image, sk, elts[g]);
		for (unsigned k = 0; k < p->l - 1 && !rc; k++) {
			struct he_cipher *c = galois_cipher(out, g, k);
			rc = cche_encrypt_zero_symmetric_eval(c, p, sk, p->l,
			    seeds ? (unsigned char *)seeds + 32 * (g * (p->l - 1) + k) : NULL, rng);
			if (!rc)
				rc = add_key(c, image, k);
		}
	}
	OPENSSL_clear_free(image, pn);
	return rc;
}
EXPORT int cche_galois_key_save(unsigned n, void *out, const struct he_galois *key)
{
	const struct he_params *p = key->p;
	size_t bytes = cche_param_ctx_key_ctx_poly_nbytes(p);
	if (n != key->count * (p->l - 1) * bytes)
		return -7;
	for (unsigned g = 0; g < key->count; g++)
		for (unsigned i = 0; i < p->l - 1; i++) {
			int rc = cche_serialize_seeded_ciphertext_eval(bytes,
			    (unsigned char *)out + (g * (p->l - 1) + i) * bytes,
			    galois_cipher((void *)key, g, i));
			if (rc)
				return rc;
		}
	return 0;
}
EXPORT int cche_galois_key_load(struct he_galois *out, unsigned nel, const uint32_t *elts,
    const struct he_params *p, unsigned n, const void *in, unsigned seedn, const void *seeds)
{
	size_t bytes = cche_param_ctx_key_ctx_poly_nbytes(p);
	if (!valid_elts(p, nel, elts) || n != nel * (p->l - 1) * bytes ||
	    seedn != 32 * nel * (p->l - 1))
		return -7;
	out->p = p;
	out->count = nel;
	memcpy(out->data, elts, nel * 4);
	for (unsigned g = 0; g < nel; g++)
		for (unsigned i = 0; i < p->l - 1; i++) {
			unsigned ix = g * (p->l - 1) + i;
			int rc = cche_deserialize_seeded_ciphertext_eval(galois_cipher(out, g, i),
			    bytes, (const unsigned char *)in + ix * bytes,
			    (const unsigned char *)seeds + 32 * ix, p, p->l, 1);
			if (rc)
				return rc;
		}
	return 0;
}
EXPORT int cche_ciphertext_apply_galois(
    struct he_cipher *out, const struct he_cipher *in, unsigned elt, const struct he_galois *key)
{
	const struct he_params *p = in->params;
	const struct he_poly *ip = (void *)in->data;
	unsigned n = p->n, l = ip->ctx->l, L = p->l, index = key->count;
	if (out == in || in->npolys != 2 || key->p != p || L < 2 || l != L - 1)
		return -7;
	for (unsigned g = 0; g < key->count; g++)
		if (((const uint32_t *)key->data)[g] == elt) {
			index = g;
			break;
		}
	if (index == key->count)
		return -7;
	size_t cn = 24 + 2 * (8 + 8 * (size_t)n * l), pn = 8 + 8 * (size_t)n * L;
	memcpy(out, in, cn);
	for (unsigned pol = 0; pol < 2; pol++) {
		const struct he_poly *a = finch_he_poly((void *)in, pol);
		struct he_poly *b = finch_he_poly(out, pol);
		for (unsigned k = 0; k < l; k++)
			for (unsigned j = 0; j < n; j++) {
				unsigned e = j * elt % (2 * n);
				uint64_t v = a->data[(size_t)k * n + j];
				b->data[(size_t)k * n + e % n] = e >= n && v ? p->q[k] - v : v;
			}
	}
	struct he_poly *acc[2] = {calloc(1, pn), calloc(1, pn)}, *tmp = malloc(8 + 8 * (size_t)n);
	struct he_ring *one = malloc(finch_he_ring_size(n));
	if (!acc[0] || !acc[1] || !tmp || !one) {
		free(acc[0]);
		free(acc[1]);
		free(tmp);
		free(one);
		return -13;
	}
	acc[0]->ctx = acc[1]->ctx = finch_he_ring(p, L);
	const struct he_poly *c1 = finch_he_poly(out, 1);
	int rc = 0;
	for (unsigned k = 0; k < L && !rc; k++) {
		const struct he_ring *r = finch_he_ring(p, k + 1);
		memcpy(one, r, finch_he_ring_size(n));
		one->l = 1;
		one->next = NULL;
		tmp->ctx = one;
		uint64_t q = p->q[k];
		for (unsigned i = 0; i < l && !rc; i++) {
			for (unsigned j = 0; j < n; j++)
				tmp->data[j] = c1->data[(size_t)i * n + j] % q;
			rc = finch_he_ntt(tmp, 0);
			const struct he_cipher *kc = galois_cipher((void *)key, index, i);
			for (unsigned pol = 0; pol < 2; pol++) {
				const struct he_poly *kp = finch_he_poly((void *)kc, pol);
				for (unsigned j = 0; j < n; j++) {
					size_t ix = (size_t)k * n + j;
					acc[pol]->data[ix] =
					    (acc[pol]->data[ix] +
					        finch_he_mul(tmp->data[j], kp->data[ix], q)) %
					    q;
				}
			}
		}
	}
	for (unsigned pol = 0; pol < 2 && !rc; pol++)
		rc = finch_he_ntt(acc[pol], 1);
	if (!rc) {
		uint64_t last = p->q[L - 1], tinverse = finch_he_pow(last % p->t, p->t - 2, p->t);
		for (unsigned pol = 0; pol < 2; pol++) {
			struct he_poly *z = finch_he_poly(out, pol);
			for (unsigned k = 0; k < l; k++) {
				uint64_t q = p->q[k], qi = finch_he_pow(last % q, q - 2, q);
				for (unsigned j = 0; j < n; j++) {
					uint64_t r = acc[pol]->data[(size_t)(L - 1) * n + j], sub;
					if (p->scheme == 1)
						sub =
						    r > last / 2 ? (q - (last - r) % q) % q : r % q;
					else {
						uint64_t u = finch_he_mul(
						    (p->t - r % p->t) % p->t, tinverse, p->t);
						sub = (r % q + finch_he_mul(u, last, q)) % q;
					}
					uint64_t v = finch_he_mul(
					    (acc[pol]->data[(size_t)k * n + j] + q - sub) % q, qi,
					    q);
					size_t ix = (size_t)k * n + j;
					z->data[ix] = pol ? v : (z->data[ix] + v) % q;
				}
			}
		}
	}
	OPENSSL_clear_free(acc[0], pn);
	OPENSSL_clear_free(acc[1], pn);
	OPENSSL_clear_free(tmp, 8 + 8 * (size_t)n);
	free(one);
	return rc;
}
