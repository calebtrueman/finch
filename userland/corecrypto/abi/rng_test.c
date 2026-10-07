/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccdrbg.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
extern int ccpbkdf2_hmac(const struct ccdigest_info *, size_t, const void *, size_t, const void *,
    unsigned long, size_t, void *);
extern const struct ccmode_cbc *ccaes_cbc_encrypt_mode(void);
extern const struct ccmode_ctr *ccaes_ctr_crypt_mode(void);
struct pbkdf_rng {
	struct ccrng_state rng;
	size_t remaining;
	unsigned char bytes[4096];
};
static int pbkdf_generate(struct ccrng_state *r, size_t n, void *out)
{
	struct pbkdf_rng *c = (void *)r;
	if (n > c->remaining)
		return -10;
	memcpy(out, c->bytes + 4096 - c->remaining, n);
	c->remaining -= n;
	return 0;
}
EXPORT int ccrng_pbkdf2_prng_init(void *p, size_t n, size_t pn, const void *password, size_t sn,
    const void *salt, unsigned long rounds)
{
	struct pbkdf_rng *c = p;
	if (n > 4096) {
		c->remaining = 0;
		return -7;
	}
	c->rng.generate = pbkdf_generate;
	c->remaining = n;
	return ccpbkdf2_hmac(ccsha256_di(), pn, password, sn, salt, rounds, n, c->bytes + 4096 - n);
}
static int ec_generate(struct ccrng_state *r, size_t n, void *out)
{
	struct ccrng_sequence_state *c = (void *)r;
	if (!c->length)
		return -5;
	unsigned borrow = 1;
	unsigned char *o = out;
	for (size_t i = 0; i < n; i++) {
		size_t at = (c->length - 1 - i) % c->length;
		unsigned v = (unsigned)c->bytes[at] - borrow;
		o[i] = v;
		borrow = (v >> 15) & 1;
	}
	return 0;
}
EXPORT int ccrng_ecfips_test_init(void *p, size_t n, const void *seed)
{
	struct ccrng_sequence_state *c = p;
	c->rng.generate = ec_generate;
	c->bytes = seed;
	c->length = n;
	return 0;
}
struct rsa_rng {
	struct ccrng_state rng;
	size_t reserved, index, next;
	struct {
		size_t n;
		const uint64_t *value;
	} values[3];
};
static int rsa_generate(struct ccrng_state *r, size_t n, void *out)
{
	struct rsa_rng *c = (void *)r;
	size_t index = c->index < 3 ? c->index : 2,
	       words = c->index < 3 ? c->values[index].n : c->next;
	const uint64_t *p = c->values[index].value;
	/* Invalid exhausted scripts must fail rather than loop or read through a count. */
	if (!words)
		return -5;
	while (words && !p[words - 1])
		words--;
	size_t bytes = words ? (words - 1) * 8 + (64 - __builtin_clzll(p[words - 1]) + 7) / 8 : 0;
	if (n < bytes)
		return -5;
	memcpy(out, p, bytes);
	memset((char *)out + bytes, 0, n - bytes);
	c->index++;
	return 0;
}
EXPORT int ccrng_rsafips_test_init(void *p, size_t an, const uint64_t *a, size_t bn,
    const uint64_t *b, size_t cn, const uint64_t *c)
{
	struct rsa_rng *r = p;
	r->rng.generate = rsa_generate;
	r->index = r->next = 0;
	r->values[0].n = an;
	r->values[0].value = a;
	r->values[1].n = bn;
	r->values[1].value = b;
	r->values[2].n = cn;
	r->values[2].value = c;
	return 0;
}
EXPORT void ccrng_rsafips_test_set_next(void *p, size_t n)
{
	((struct rsa_rng *)p)->next = n;
}
struct test_rng {
	struct ccrng_state rng;
	struct ccdrbg_info info;
	void *state;
};
static struct ccdrbg_df test_df;
static struct ccdrbg_custom_ctr test_custom;
static pthread_once_t test_once = PTHREAD_ONCE_INIT;
static int test_setup_result;
static void test_setup(void)
{
	test_setup_result = ccdrbg_df_bc_init(&test_df, ccaes_cbc_encrypt_mode(), 16);
	test_custom = (struct ccdrbg_custom_ctr){ccaes_ctr_crypt_mode(), 16, 0, &test_df};
}
static int test_generate(struct ccrng_state *r, size_t n, void *out)
{
	struct test_rng *c = (void *)r;
	return ccdrbg_generate(&c->info, c->state, n, out, 0, NULL);
}
EXPORT int ccrng_test_init(void *p, size_t n, const void *seed, const char *name)
{
	struct test_rng *c = p;
	c->rng.generate = test_generate;
	pthread_once(&test_once, test_setup);
	if (test_setup_result)
		return test_setup_result;
	ccdrbg_factory_nistctr(&c->info, &test_custom);
	c->state = malloc(2 * c->info.size);
	if (!c->state)
		return -13;
	if (!name)
		name = "";
	return ccdrbg_init(&c->info, c->state, n, seed, n, seed, strlen(name), name);
}
EXPORT void ccrng_test_done(void *p)
{
	struct test_rng *c = p;
	if (c->state) {
		ccdrbg_done(&c->info, c->state);
		free(c->state);
		c->state = NULL;
	}
}
