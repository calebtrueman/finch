/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccec.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define L(H, N, T) ((T)dlsym(H, #N))
static int checks;
#define C(X)                                                                                       \
	do {                                                                                       \
		if (!(X)) {                                                                        \
			fprintf(stderr, "line %d: %s\n", __LINE__, #X);                            \
			exit(1);                                                                   \
		}                                                                                  \
		checks++;                                                                          \
	} while (0)
static int random_fill(struct ccrng_state *r, size_t n, void *p)
{
	(void)r;
	arc4random_buf(p, n);
	return 0;
}
static int constant_fill(struct ccrng_state *r, size_t n, void *p)
{
	(void)r;
	memset(p, 27, n);
	return 0;
}
static struct ccrng_state rng = {random_fill}, fixed = {constant_fill};
typedef const struct cczp *(*cpfn)(size_t);
typedef int (*genfn)(const struct cczp *, struct ccrng_state *, void *);
typedef int (*wrapfn)(const void *, void *, unsigned, unsigned, size_t, const void *, const void *,
    const void *, const void *, struct ccrng_state *);
typedef int (*unwrapfn)(const void *, size_t *, void *, unsigned, void *, const void *,
    const void *, const void *, size_t, const void *);
typedef size_t (*sizefn)(const void *, unsigned, size_t);
typedef int (*signfn)(const void *, size_t, const void *, void *, void *, struct ccrng_state *);
int main(int argc, char **argv)
{
	C(argc == 2);
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	     *f = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!f)
		puts(dlerror());
	C(h && f);
	const char *cn[] = {"ccec_rfc6637_dh_curve_p256", "ccec_rfc6637_dh_curve_p521"},
	           *wn[] = {"ccec_rfc6637_wrap_sha256_kek_aes128",
	               "ccec_rfc6637_wrap_sha512_kek_aes256"},
	           *un[] = {"ccec_rfc6637_unwrap_sha256_kek_aes128",
	               "ccec_rfc6637_unwrap_sha512_kek_aes256"};
	unsigned char k[304] = {0}, fingerprint[20] = {1}, key[36];
	for (int i = 0; i < 36; i++)
		key[i] = (unsigned char)i;
	for (int ci = 0; ci < 2; ci++) {
		const struct cczp *cp = L(h, ccec_get_cp, cpfn)(ci ? 521 : 256);
		C(!L(h, ccec_generate_key, genfn)(cp, &rng, k));
		unsigned char rr[66], ss[66], fr[66], fs[66], hash[32] = {42};
		C(!L(h, ccec_sign_composite_hedged, signfn)(k, 32, hash, rr, ss, &fixed));
		C(!L(f, ccec_sign_composite_hedged, signfn)(k, 32, hash, fr, fs, &fixed));
		C(!memcmp(rr, fr, (cp->bitlen + 7) / 8) && !memcmp(ss, fs, (cp->bitlen + 7) / 8));
		for (int wi = 0; wi < 2; wi++)
			for (unsigned flags = 0; flags < 4; flags++)
				for (int kn = 0; kn <= 36; kn += 12)
					for (int mask = 0; mask < 4; mask++) {
						void *desc = (mask & 1) ? h : f,
						     *wrapper = (mask & 2) ? h : f,
						     *unwrap = (mask & 2) ? f : h;
						size_t n = L(h, ccec_rfc6637_wrap_key_size, sizefn)(
						    k, flags, kn);
						C(n ==
						    L(f, ccec_rfc6637_wrap_key_size, sizefn)(
						        k, flags, kn));
						unsigned char wrapped[300] = {0}, out[40], alg = 0;
						C(!L(wrapper, ccec_rfc6637_wrap_key, wrapfn)(k,
						    wrapped, flags, 9, kn, key, dlsym(desc, cn[ci]),
						    dlsym(desc, wn[wi]), fingerprint, &rng));
						size_t outn = sizeof out;
						int rc = L(
						    unwrap, ccec_rfc6637_unwrap_key, unwrapfn)(k,
						    &outn, out, flags, &alg, dlsym(desc, cn[ci]),
						    dlsym(desc, un[wi]), fingerprint, n, wrapped);
						if (rc)
							fprintf(stderr,
							    "ci %d wi %d flags %u kn %d mask %d unwrap %d\n",
							    ci, wi, flags, kn, mask, rc);
						C(!rc);
						C(outn == (size_t)kn && alg == 9 &&
						    !memcmp(out, key, kn));
					}
	}
	for (int ci = 0; ci < 2; ci++) {
		const struct cczp *cp = L(h, ccec_get_cp, cpfn)(ci ? 521 : 256);
		unsigned char original[304] = {0}, gen[304] = {0}, pub[304] = {0},
		              entropy[80] = {12}, wrapped[300], out[40];
		C(!L(h, ccec_generate_key, genfn)(cp, &rng, original));
		typedef int (*divfn)(const struct cczp *, const void *, size_t, const void *,
		    struct ccrng_state *, void *, void *);
		C(!L(f, ccec_diversify_pub, divfn)(cp, original, 80, entropy, &rng, gen, pub));
		typedef int (*divwrapfn)(const void *, const void *, void *, unsigned, unsigned,
		    size_t, const void *, const void *, const void *, const void *,
		    struct ccrng_state *);
		for (int mask = 0; mask < 4; mask++) {
			void *wr = mask & 1 ? h : f, *uw = mask & 2 ? h : f;
			size_t n = L(h, ccec_rfc6637_wrap_key_size, sizefn)(pub, 0, 32);
			C(!L(wr, ccec_rfc6637_wrap_key_diversified, divwrapfn)(gen, pub, wrapped, 0,
			    9, 32, key, dlsym(f, cn[ci]), dlsym(f, wn[ci]), fingerprint, &rng));
			size_t outn = sizeof out;
			unsigned char alg = 0;
			C(!L(uw, ccec_rfc6637_unwrap_key, unwrapfn)(original, &outn, out, 0, &alg,
			    dlsym(f, cn[ci]), dlsym(f, un[ci]), fingerprint, n, wrapped));
			C(outn == 32 && alg == 9 && !memcmp(out, key, 32));
			wrapped[n - 1] ^= 1;
			outn = sizeof out;
			C(L(uw, ccec_rfc6637_unwrap_key, unwrapfn)(original, &outn, out, 0, &alg,
			      dlsym(f, cn[ci]), dlsym(f, un[ci]), fingerprint, n, wrapped) != 0);
		}
	}
	printf("ECC wrap: %d checks passed\n", checks);
}
