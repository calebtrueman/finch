/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "cche.h"
#include <openssl/bn.h>
#include <string.h>
int finch_he_ring_init(struct he_ring *, unsigned, unsigned, uint64_t, struct he_ring *);
static void mm(uint64_t *out, uint64_t q, uint64_t x)
{
	out[0] = q;
	out[1] = x;
	out[2] = (uint64_t)(((__uint128_t)x << 64) / q);
}
static uint64_t inverse(uint64_t x, uint64_t q)
{
	return finch_he_pow(x, q - 2, q);
}
static size_t base_size(unsigned l)
{
	return 48 + 128 * (size_t)l;
}
static int base_init(
    unsigned char *out, const struct he_params *p, unsigned l, struct he_ring *target)
{
	const uint64_t m = ((uint64_t)1 << 61) - 1;
	uint64_t *t = (void *)out;
	*(const struct he_ring **)(out) = finch_he_ring(p, l);
	*(const struct he_ring **)(out + 8) = target;
	BN_CTX *bc = BN_CTX_new();
	if (!bc)
		return -13;
	BN_CTX_start(bc);
	BIGNUM *Q = BN_CTX_get(bc), *hat = BN_CTX_get(bc), *qi = BN_CTX_get(bc);
	int rc = -1;
	if (!qi || !BN_one(Q))
		goto done;
	for (unsigned i = 0; i < l; i++)
		if (!BN_mul_word(Q, p->q[i]))
			goto done;
	uint64_t qt = BN_mod_word(Q, p->t), qm = BN_mod_word(Q, m);
	mm(t + 2, p->t, qt);
	t[5] = m % p->t;
	t[6] = inverse(t[5], p->t);
	t[7] = p->t - inverse(qt, p->t);
	t[8] = m - inverse(qm, m);
	mm(t + 9, p->t, inverse(p->q[l - 1] % p->t, p->t));
	uint64_t *mods = t + 12, *inv = mods + 6 * l, *prod = inv + 3 * l, *last = prod + l,
	         *lastinv = last + 3 * (l - 1);
	for (unsigned i = 0; i < l; i++) {
		if (!BN_set_word(qi, p->q[i]) || !BN_div(hat, NULL, Q, qi, bc))
			goto done;
		mm(mods + 3 * i, p->t, BN_mod_word(hat, p->t));
		mm(mods + 3 * (l + i), m, BN_mod_word(hat, m));
		mm(inv + 3 * i, p->q[i], inverse(BN_mod_word(hat, p->q[i]), p->q[i]));
		prod[i] = finch_he_mul(p->t, m, p->q[i]);
		if (i + 1 < l) {
			uint64_t v = p->q[l - 1] % p->q[i];
			mm(last + 3 * i, p->q[i], v);
			mm(lastinv + 3 * i, p->q[i], inverse(v, p->q[i]));
		}
	}
	rc = 0;
done:
	BN_CTX_end(bc);
	BN_CTX_free(bc);
	return rc;
}
int finch_he_extra_init(struct he_params *p)
{
	size_t rs = finch_he_ring_size(p->n);
	unsigned char *d = (void *)((unsigned char *)finch_he_plain_ring(p) + rs +
	    ((4 * (size_t)p->n + 7) & ~(size_t)7));
	*(struct he_params **)d = p;
	uint32_t *chain = (void *)(d + 8);
	chain[0] = p->n;
	chain[1] = 2;
	struct he_ring *r2 = (void *)(d + 16), *r1 = (void *)(d + 16 + rs);
	int rc = finch_he_ring_init(r2, p->n, 2, ((uint64_t)1 << 61) - 1, r1);
	if (!rc)
		rc = finch_he_ring_init(r1, p->n, 1, p->t, NULL);
	if (rc)
		return rc;
	unsigned char *b = d + 16 + 2 * rs;
	for (unsigned l = 1; l <= p->l; l++) {
		rc = base_init(b, p, l, r2);
		if (rc)
			return rc;
		b += base_size(l);
	}
	BN_CTX *bc = BN_CTX_new();
	if (!bc)
		return -13;
	BN_CTX_start(bc);
	BIGNUM *Q = BN_CTX_get(bc), *quot = BN_CTX_get(bc), *t = BN_CTX_get(bc);
	if (!t || !BN_one(Q) || !BN_set_word(t, p->t)) {
		BN_CTX_end(bc);
		BN_CTX_free(bc);
		return -1;
	}
	for (unsigned l = 1; l <= p->l; l++) {
		BN_mul_word(Q, p->q[l - 1]);
		BN_div(quot, NULL, Q, t, bc);
		uint64_t *v = (void *)b;
		*(struct he_params **)b = p;
		*(struct he_ring **)(b + 8) = finch_he_ring(p, l);
		v[2] = BN_mod_word(Q, p->t);
		v[3] = (p->t + 1) / 2;
		for (unsigned i = 0; i < l; i++) {
			v[4 + i] = BN_mod_word(quot, p->q[i]);
			v[4 + l + i] = p->q[i] - p->t;
		}
		b += 32 + 16 * l;
	}
	BN_CTX_end(bc);
	BN_CTX_free(bc);
	return 0;
}
