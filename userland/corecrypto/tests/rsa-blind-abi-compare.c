/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccrsa.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
struct suite {
	size_t bits;
	const struct ccdigest_info *(*di)(void);
	size_t salt_size;
};
static int random_(struct ccrng_state *r, size_t n, void *p)
{
	(void)r;
	arc4random_buf(p, n);
	return 0;
}
static int sequence(struct ccrng_state *r, size_t n, void *p)
{
	(void)r;
	memset(p, 0x51, n);
	return 0;
}
static unsigned count, fail;
#define CK(x)                                                                                      \
	do {                                                                                       \
		count++;                                                                           \
		if (!(x)) {                                                                        \
			fail++;                                                                    \
			fprintf(stderr, "line %d: %s\n", __LINE__, #x);                            \
		}                                                                                  \
	} while (0)
#define LOAD(ret, name, args)                                                                      \
	ret(*h_##name) args = dlsym(h, #name);                                                     \
	ret(*f_##name) args = dlsym(f, #name)
int main(int argc, char **argv)
{
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", 2),
	     *f = dlopen(argc > 1 ? argv[1] : "build/userland/corecrypto/rsa-test.dylib", 2);
	if (!h || !f) {
		puts(dlerror());
		return 2;
	}
	LOAD(int, ccrsa_generate_key,
	    (size_t, ccrsa_ctx *, size_t, const void *, struct ccrng_state *));
	(void)f_ccrsa_generate_key;
	LOAD(int, ccrsabssa_blind_message,
	    (const struct suite *, const ccrsa_ctx *, const void *, size_t, void *, size_t, void *,
	        size_t, struct ccrng_state *));
	LOAD(int, ccrsabssa_sign_blinded_message,
	    (const struct suite *, const ccrsa_ctx *, const void *, size_t, void *, size_t,
	        struct ccrng_state *));
	LOAD(int, ccrsabssa_unblind_signature,
	    (const struct suite *, const ccrsa_ctx *, const void *, size_t, const void *, size_t,
	        const void *, size_t, void *, size_t));
	struct ccrng_state rng = {random_}, seq = {sequence};
	unsigned char e[] = {1, 0, 1};
	const char *names[] = {"ccrsabssa_ciphersuite_rsa2048_sha384",
	    "ccrsabssa_ciphersuite_rsa3072_sha384", "ccrsabssa_ciphersuite_rsa4096_sha384"};
	for (unsigned i = 0; i < 3; i++) {
		const struct suite *hs = dlsym(h, names[i]), *fs = dlsym(f, names[i]);
		CK(hs->bits == fs->bits);
		CK(hs->salt_size == fs->salt_size);
		cc_unit key[4096] = {0};
		ccrsa_ctx *k = (void *)key;
		CK(h_ccrsa_generate_key(hs->bits, k, 3, e, &rng) == 0);
		size_t n = hs->bits / 8;
		unsigned char hi[512], fi[512], hb[512], fb[512], hbs[512], fbs[512], hsig[512],
		    fsig[512];
		int a = h_ccrsabssa_blind_message(hs, k, "message", 7, hi, n, hb, n, &seq),
		    b = f_ccrsabssa_blind_message(fs, k, "message", 7, fi, n, fb, n, &seq);
		CK(a == b);
		CK(a == 0);
		CK(!memcmp(hi, fi, n));
		CK(!memcmp(hb, fb, n));
		a = h_ccrsabssa_sign_blinded_message(hs, k, fb, n, hbs, n, &rng);
		b = f_ccrsabssa_sign_blinded_message(fs, k, hb, n, fbs, n, &rng);
		CK(a == b);
		CK(a == 0);
		CK(!memcmp(hbs, fbs, n));
		a = h_ccrsabssa_unblind_signature(hs, k, fi, n, fbs, n, "message", 7, hsig, n);
		b = f_ccrsabssa_unblind_signature(fs, k, hi, n, hbs, n, "message", 7, fsig, n);
		CK(a == b);
		CK(a == 0);
		CK(!memcmp(hsig, fsig, n));
		a = h_ccrsabssa_unblind_signature(hs, k, fi, n, fbs, n, "changed", 7, hsig, n);
		b = f_ccrsabssa_unblind_signature(fs, k, hi, n, hbs, n, "changed", 7, fsig, n);
		if (a != b)
			fprintf(stderr, "bad msg: host=%d finch=%d\n", a, b);
		CK(a == b);
		CK(a != 0);
		CK(!memcmp(hsig, fsig, n));
		CK(h_ccrsabssa_blind_message(hs, k, "message", 7, hi, n - 1, hb, n, &seq) ==
		    f_ccrsabssa_blind_message(fs, k, "message", 7, fi, n - 1, fb, n, &seq));
	}
	printf("Blind RSA ABI: %u checks, %u failures\n", count, fail);
	return !!fail;
}
