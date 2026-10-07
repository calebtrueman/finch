/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccpq.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(X)                                                                                   \
	do {                                                                                       \
		if (!(X)) {                                                                        \
			fprintf(stderr, "FAIL %d %s: %s\n", __LINE__, name, #X);                   \
			exit(1);                                                                   \
		}                                                                                  \
	} while (0)
struct rng {
	struct ccrng_state state;
	unsigned counter;
	size_t consumed;
};
static int bytes(struct ccrng_state *state, size_t n, void *out)
{
	struct rng *r = (void *)state;
	unsigned char *p = out;
	for (size_t i = 0; i < n; i++)
		p[i] = (unsigned char)r->counter++;
	r->consumed += n;
	return 0;
}
static int failed_rng(struct ccrng_state *r, size_t n, void *out)
{
	(void)r;
	(void)n;
	(void)out;
	return -42;
}
int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	void *h[2] = {dlopen("/usr/lib/system/libcorecrypto.dylib", 2),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)};
	const char *name = "open";
	CHECK(h[0] && h[1]);
	const char *names[] = {"cckem_mlkem768", "cckem_mlkem1024", "cckem_xwing_mlkem768x25519",
	    "cckem_kyber768", "cckem_kyber1024"};
	unsigned char storage[2][8192], seed[2][64], ciphertext[2][1600], shared[2][64],
	    recovered[2][64], exported[2][4096];
	struct cckem_ctx *c[2] = {(void *)storage[0], (void *)storage[1]};
	for (unsigned which = 0; which < 5; which++) {
		name = names[which];
		const struct cckem_info *m[2];
		for (int j = 0; j < 2; j++) {
			const struct cckem_info *(*get)(void) = dlsym(h[j], name);
			CHECK(get);
			if (j) {
				Dl_info origin;
				CHECK(dladdr((void *)get, &origin));
				CHECK(strstr(origin.dli_fname, "libcorecrypto.dylib") == NULL);
			}
			m[j] = get();
		}
		CHECK(!memcmp(m[0], m[1], 6 * sizeof(size_t)));
		for (unsigned trial = 0; trial < 4; trial++) {
			struct rng rng[2] = {{{bytes}, trial, 0}, {{bytes}, trial, 0}};
			for (int j = 0; j < 2; j++) {
				memset(storage[j], 0xa5, 8192);
				memset(c[j], 0, 8 + m[j]->full_size);
				c[j]->info = m[j];
				CHECK(!m[j]->generate_seed(c[j], seed[j], &rng[j].state));
				CHECK(storage[j][8 + m[j]->full_size] == 0xa5);
			}
			CHECK(rng[0].consumed == rng[1].consumed);
			CHECK(!memcmp(seed[0], seed[1], m[0]->seed_size));
			CHECK(!memcmp(c[0]->key, c[1]->key, m[0]->full_size));
			for (int j = 0; j < 2; j++) {
				memset(ciphertext[j], 0xa5, 1600);
				memset(shared[j], 0xa5, 64);
				CHECK(!m[j]->encapsulate(
				    c[1 - j], ciphertext[j], shared[j], &rng[j].state));
			}
			CHECK(rng[0].consumed == rng[1].consumed);
			CHECK(!memcmp(ciphertext[0], ciphertext[1], 1600));
			CHECK(!memcmp(shared[0], shared[1], 64));
			for (int j = 0; j < 2; j++) {
				memset(recovered[j], 0xa5, 64);
				CHECK(
				    !m[j]->decapsulate(c[1 - j], ciphertext[1 - j], recovered[j]));
				CHECK(!memcmp(recovered[j], shared[0], 64));
			}
			ciphertext[0][4] ^= 1;
			ciphertext[1][4] ^= 1;
			for (int j = 0; j < 2; j++)
				CHECK(
				    !m[j]->decapsulate(c[1 - j], ciphertext[1 - j], recovered[j]));
			CHECK(!memcmp(recovered[0], recovered[1], 64));
			CHECK(memcmp(recovered[0], shared[0], 32));
			for (int private = 0; private < 2; private++) {
				size_t lengths[2] = {4096, 4096};
				for (int j = 0; j < 2; j++) {
					memset(exported[j], 0xa5, 4096);
					CHECK(
					    !(private ? m[j]->export_private : m[j]->export_public)(
					        c[1 - j], &lengths[j], exported[j]));
				}
				CHECK(lengths[0] == lengths[1]);
				CHECK(!memcmp(exported[0], exported[1], 4096));
				for (int j = 0; j < 2; j++) {
					memset(storage[j], 0xa5, 8192);
					CHECK(
					    !(private ? m[j]->import_private : m[j]->import_public)(
					        m[j], lengths[1 - j], exported[1 - j], c[j]));
				}
				CHECK(!memcmp(c[0]->key, c[1]->key,
				    private ? m[0]->full_size : m[0]->public_size));
			}
		}
		/* Seed derivation uses an extra random rejection key only for Kyber. */
		for (int j = 0; j < 2; j++) {
			memset(storage[j], 0xa5, 8192);
			memset(c[j], 0, 8 + m[j]->full_size);
			c[j]->info = m[j];
			for (size_t i = 0; i < 64; i++)
				seed[j][i] = (unsigned char)i;
			struct rng r = {{bytes}, 71, 0};
			CHECK(!m[j]->derive(c[j], seed[j], &r.state));
		}
		CHECK(!memcmp(c[0]->key, c[1]->key, m[0]->full_size));
		struct ccrng_state bad = {failed_rng};
		for (int op = 0; op < 3; op++) {
			int status[2];
			for (int j = 0; j < 2; j++) {
				memset(ciphertext[j], 0xa5, 1600);
				memset(shared[j], 0xa5, 64);
				status[j] = op == 0 ? m[j]->generate(c[j], &bad)
				    : op == 1
				    ? m[j]->generate_seed(c[j], ciphertext[j], &bad)
				    : m[j]->encapsulate(c[j], ciphertext[j], shared[j], &bad);
			}
			CHECK(status[0] == status[1]);
			CHECK(!memcmp(ciphertext[0], ciphertext[1], 1600));
			CHECK(!memcmp(shared[0], shared[1], 64));
		}
		unsigned char saved[2][2];
		for (int j = 0; j < 2; j++) {
			memcpy(saved[j], c[j]->key, 2);
			c[j]->key[0] = 255;
			c[j]->key[1] = 255;
		}
		int rejected[2];
		for (int j = 0; j < 2; j++) {
			struct rng r = {{bytes}, 55, 0};
			memset(ciphertext[j], 0xa5, 1600);
			memset(shared[j], 0xa5, 64);
			rejected[j] = m[j]->encapsulate(c[j], ciphertext[j], shared[j], &r.state);
			memcpy(c[j]->key, saved[j], 2);
		}
		if (rejected[0] != rejected[1])
			fprintf(stderr, "bad key statuses %d %d\n", rejected[0], rejected[1]);
		CHECK(rejected[0] == rejected[1]);
		CHECK(rejected[0] != 0);
		CHECK(!memcmp(ciphertext[0], ciphertext[1], 1600));
		CHECK(!memcmp(shared[0], shared[1], 64));
		typedef int (*encfn)(
		    const struct cckem_ctx *, size_t, void *, size_t, void *, struct ccrng_state *);
		typedef int (*decfn)(
		    const struct cckem_ctx *, size_t, const void *, size_t, void *);
		typedef int (*derivefn)(
		    struct cckem_ctx *, size_t, const void *, struct ccrng_state *);
		for (int j = 0; j < 2; j++) {
			encfn enc = dlsym(h[j], "cckem_encapsulate");
			decfn dec = dlsym(h[j], "cckem_decapsulate");
			derivefn d = dlsym(h[j], "cckem_derive_key_from_seed");
			CHECK(enc(c[j], m[j]->ciphertext_size - 1, ciphertext[j], 32, shared[j],
			          &bad) == -7);
			CHECK(dec(c[j], m[j]->ciphertext_size, ciphertext[j], 31, shared[j]) == -7);
			CHECK(d(c[j], m[j]->seed_size - 1, seed[j], &bad) == -7);
		}
		printf(
		    "%s: seeded keys, cross-used contexts, ciphertext, shared secret, damaged ciphertext and imports match\n",
		    name);
	}
}
