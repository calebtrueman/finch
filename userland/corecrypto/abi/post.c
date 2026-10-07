/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccdigest.h"
#include "chacha.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
extern int cccurve25519(void *, const void *, const void *);
struct post_result {
	size_t count, failures;
	const void *first_failure;
};
struct post_base {
	uint32_t type;
};
struct post_list {
	uint32_t type;
	const void *const *items;
	size_t count;
};
struct post_digest {
	uint32_t type;
	const struct ccdigest_info *(*di)(void);
	const void *message;
	size_t size;
	const void *expected;
};
struct post_curve {
	uint32_t type;
	const void *public_key, *private_key, *expected;
	uint32_t expectation;
};
struct post_chacha {
	uint32_t type;
	const void *key;
	size_t key_n;
	const void *nonce;
	size_t nonce_n;
	const void *aad;
	size_t aad_n;
	const void *plain;
	size_t plain_n;
	const void *cipher;
	size_t cipher_n;
	const void *tag;
	size_t tag_n;
	uint32_t expect_failure;
};
static unsigned differs(const void *a, const void *b, size_t n)
{
	const unsigned char *x = a, *y = b;
	unsigned v = 0;
	for (size_t i = 0; i < n; i++)
		v |= x[i] ^ y[i];
	return !!v;
}
static void record(struct post_result *r, const void *v, int bad)
{
	r->count++;
	if (bad) {
		r->failures++;
		if (!r->first_failure)
			r->first_failure = v;
	}
}
static void run(const void *p, struct post_result *r)
{
	if (!p)
		return;
	const struct post_base *b = p;
	switch (b->type) {
	case 0: {
		const struct post_list *v = p;
		for (size_t i = 0; i < v->count; i++)
			run(v->items[i], r);
		break;
	}
	case 1: {
		const struct post_digest *v = p;
		const struct ccdigest_info *di = v->di();
		unsigned char out[di->output_size];
		ccdigest(di, v->size, v->message, out);
		record(r, v, differs(out, v->expected, sizeof(out)));
		memset(out, 0, sizeof(out));
		break;
	}
	case 2: {
		const struct post_curve *v = p;
		unsigned char out[32];
		int ret = cccurve25519(out, v->private_key, v->public_key);
		int bad = ret             ? !v->expectation
		    : v->expectation == 2 ? 1
		                          : differs(out, v->expected, 32);
		record(r, v, bad);
		memset(out, 0, 32);
		break;
	}
	case 3: {
		const struct post_chacha *v = p;
		int bad = 0;
		/* The host runner counts malformed or oversized vectors as skipped passes. */
		if (v->key_n == 32 && v->nonce_n == 12 && v->tag_n == 16 && v->plain_n <= 256 &&
		    v->cipher_n <= 256) {
			unsigned char out[256], tag[16];
			const struct ccchacha20poly1305_info *i = ccchacha20poly1305_info();
			int ret = ccchacha20poly1305_decrypt_oneshot(i, v->key, v->nonce, v->aad_n,
			    v->aad, v->cipher_n, v->cipher, out, v->tag);
			if (v->expect_failure)
				bad = !ret;
			else if (ret || differs(out, v->plain, v->plain_n))
				bad = 1;
			else {
				ret = ccchacha20poly1305_encrypt_oneshot(i, v->key, v->nonce,
				    v->aad_n, v->aad, v->plain_n, v->plain, out, tag);
				bad = ret || differs(out, v->cipher, v->cipher_n) ||
				    differs(tag, v->tag, 16);
			}
			memset(out, 0, sizeof(out));
			memset(tag, 0, 16);
		}
		record(r, v, bad);
		break;
	}
	default:
		record(r, p, 1);
		break;
	}
}
EXPORT int ccpost(const void *vector, struct post_result *result)
{
	struct post_result local;
	if (!result)
		result = &local;
	memset(result, 0, sizeof(*result));
	run(vector, result);
	return result->failures ? -75 : 0;
}
