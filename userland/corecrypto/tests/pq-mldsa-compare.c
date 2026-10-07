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
struct api {
	const struct ccmldsa_params *(*params)(void);
	int (*derive)(struct ccmldsa_ctx *, size_t, const void *);
	int (*prehash)(
	    const struct ccmldsa_ctx *, size_t, void *, size_t, const void *, size_t, const void *);
	int (*sign)(const struct ccmldsa_ctx *, size_t, void *, size_t, const void *, size_t,
	    const void *, struct ccrng_state *);
	int (*signhash)(
	    const struct ccmldsa_ctx *, size_t, void *, size_t, const void *, struct ccrng_state *);
	int (*verify)(const struct ccmldsa_ctx *, size_t, const void *, size_t, const void *,
	    size_t, const void *, void *);
	int (*verifyhash)(
	    const struct ccmldsa_ctx *, size_t, const void *, size_t, const void *, void *);
};
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
	unsigned char storage[2][8192], seed[32], sig[2][5000], digest[2][80], canary[2][32],
	    message[256], context[256];
	struct ccmldsa_ctx *c[2] = {(void *)storage[0], (void *)storage[1]};
	for (int i = 0; i < 256; i++) {
		message[i] = i;
		context[i] = i * 7;
	}
	for (int variant = 0; variant < 2; variant++) {
		name = variant ? "ccmldsa87" : "ccmldsa65";
		struct api a[2];
		const struct ccmldsa_params *p[2];
		for (int j = 0; j < 2; j++) {
			a[j].params = dlsym(h[j], name);
			if (j) {
				Dl_info origin;
				CHECK(dladdr((void *)a[j].params, &origin));
				CHECK(strstr(origin.dli_fname, "libcorecrypto.dylib") == NULL);
			}
			p[j] = a[j].params();
			a[j].derive = dlsym(h[j], "ccmldsa_derive_key_from_seed");
			a[j].prehash = dlsym(h[j], "ccmldsa_prehash_with_context");
			a[j].sign = dlsym(h[j], "ccmldsa_sign_with_context");
			a[j].signhash = dlsym(h[j], "ccmldsa_sign_prehashed");
			a[j].verify = dlsym(h[j], "ccmldsa_verify_with_context_and_canary");
			a[j].verifyhash = dlsym(h[j], "ccmldsa_verify_prehashed_with_canary");
		}
		CHECK(!memcmp(p[0], p[1], 32));
		CHECK(!memcmp(&p[0]->full_size, &p[1]->full_size, 32));
		for (unsigned trial = 0; trial < 4; trial++) {
			for (int i = 0; i < 32; i++)
				seed[i] = i + trial * 13;
			for (int j = 0; j < 2; j++) {
				memset(storage[j], 0xa5, 8192);
				memset(c[j], 0, p[j]->full_size + 8);
				c[j]->params = p[1 - j];
				CHECK(!a[j].derive(c[j], 32, seed));
				CHECK(storage[j][p[j]->full_size + 8] == 0xa5);
			}
			CHECK(!memcmp(c[0]->key, c[1]->key, p[0]->full_size));
			size_t cn = trial == 3 ? 255 : trial * 13, mn = trial * 67;
			for (int j = 0; j < 2; j++) {
				memset(digest[j], 0xa5, 80);
				CHECK(!a[j].prehash(
				    c[1 - j], 64, digest[j], mn, message, cn, context));
			}
			CHECK(!memcmp(digest[0], digest[1], 80));
			for (int hashed = 0; hashed < 2; hashed++) {
				struct rng rng[2] = {{{bytes}, trial, 0}, {{bytes}, trial, 0}};
				for (int j = 0; j < 2; j++) {
					memset(sig[j], 0xa5, 5000);
					int status = hashed
					    ? a[j].signhash(c[1 - j], p[j]->signature_size, sig[j],
					          64, digest[j], &rng[j].state)
					    : a[j].sign(c[1 - j], p[j]->signature_size, sig[j], mn,
					          message, cn, context, &rng[j].state);
					if (status)
						fprintf(stderr,
						    "sign side %d hashed %d status %d\n", j, hashed,
						    status);
					CHECK(!status);
				}
				CHECK(rng[0].consumed == rng[1].consumed);
				CHECK(!memcmp(sig[0], sig[1], 5000));
				for (int j = 0; j < 2; j++) {
					memset(canary[j], 0xa5, 32);
					CHECK(!(hashed
					        ? a[j].verifyhash(c[1 - j], p[j]->signature_size,
					              sig[1 - j], 64, digest[1 - j], canary[j])
					        : a[j].verify(c[1 - j], p[j]->signature_size,
					              sig[1 - j], mn, message, cn, context,
					              canary[j])));
				}
				CHECK(!memcmp(canary[0], canary[1], 32));
				sig[0][0] ^= 1;
				sig[1][0] ^= 1;
				for (int j = 0; j < 2; j++) {
					memset(canary[j], 0xa5, 32);
					int status = hashed
					    ? a[j].verifyhash(c[1 - j], p[j]->signature_size,
					          sig[1 - j], 64, digest[1 - j], canary[j])
					    : a[j].verify(c[1 - j], p[j]->signature_size,
					          sig[1 - j], mn, message, cn, context, canary[j]);
					CHECK(status == -146);
					CHECK(canary[j][16] == 0xa5);
				}
				CHECK(!memcmp(canary[0], canary[1], 32));
			}
		}
		/* Damaged packed coefficients and hints must fail without a good canary. */
		for (int trial = 0; trial < 32; trial++) {
			size_t at_byte = (size_t)trial * 139 % p[0]->signature_size;
			sig[0][at_byte] ^= 0x80;
			memcpy(sig[1], sig[0], 5000);
			int status[2];
			for (int j = 0; j < 2; j++) {
				memset(canary[j], 0xa5, 32);
				status[j] = a[j].verify(c[1 - j], p[j]->signature_size, sig[1 - j],
				    7, message, 0, NULL, canary[j]);
			}
			CHECK(status[0] == status[1]);
			CHECK(status[0] != 0);
			CHECK(!memcmp(canary[0], canary[1], 32));
		}
		struct ccrng_state bad = {failed_rng};
		for (int trial = 0; trial < 3; trial++) {
			int status[2];
			for (int j = 0; j < 2; j++) {
				memset(sig[j], 0xa5, 5000);
				struct rng r = {{bytes}, 0, 0};
				status[j] = a[j].sign(c[1 - j], p[j]->signature_size - (trial == 1),
				    sig[j], 3, message, trial == 2 ? 256 : 0, context,
				    trial == 0 ? &bad : &r.state);
			}
			CHECK(status[0] == status[1]);
			CHECK(!memcmp(sig[0], sig[1], 5000));
		}
		printf(
		    "%s: seeded contexts, mixed parameter callbacks, prehash, signatures, both canary paths, damaged signatures and RNG/size failures match\n",
		    name);
	}
}
