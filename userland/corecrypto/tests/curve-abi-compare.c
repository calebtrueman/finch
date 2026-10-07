/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccdigest.h"
#include "../abi/ccrng.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define F(H, N, T) ((T)dlsym(H, #N))
#define C(X)                                                                                       \
	do {                                                                                       \
		if (!(X)) {                                                                        \
			fprintf(stderr, "FAIL %d: %s\n", __LINE__, #X);                            \
			exit(1);                                                                   \
		}                                                                                  \
		checks++;                                                                          \
	} while (0)
static int checks;
static int gen(struct ccrng_state *r, size_t n, void *p)
{
	(void)r;
	memset(p, 0x57, n);
	return 0;
}
static int fail(struct ccrng_state *r, size_t n, void *p)
{
	(void)r;
	(void)n;
	(void)p;
	return -123;
}
typedef int (*pubfn)(void *, const void *);
typedef int (*dhfn)(void *, const void *, const void *);
typedef int (*rdhfn)(struct ccrng_state *, void *, const void *, const void *);
typedef int (*privfn)(struct ccrng_state *, void *);
typedef int (*rpubfn)(struct ccrng_state *, void *, const void *);
typedef int (*epubfn)(const void *, void *, const void *);
typedef int (*esignfn)(const void *, void *, size_t, const void *, const void *, const void *);
typedef int (*everifyfn)(const void *, size_t, const void *, const void *, const void *);
int main(int argc, char **argv)
{
	C(argc == 2);
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	     *f = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	C(h && f);
	struct ccrng_state r = {gen}, bad = {fail};
	unsigned char a[64] = {1}, b[64] = {3}, hp[64], fp[64], hs[114], fs[114], zero[64] = {0};
	C(!F(h, cccurve25519_make_priv, privfn)(&r, a));
	C(!F(f, cccurve25519_make_priv, privfn)(&r, b));
	C(!memcmp(a, b, 32));
	C(!F(h, cccurve25519_make_pub, pubfn)(hp, a));
	C(!F(f, cccurve25519_make_pub, pubfn)(fp, a));
	C(!memcmp(hp, fp, 32));
	C(!F(h, cccurve25519, dhfn)(hs, a, hp));
	C(!F(f, cccurve25519, dhfn)(fs, a, fp));
	C(!memcmp(hs, fs, 32));
	int he = F(h, cccurve25519, dhfn)(hs, a, zero), fe = F(f, cccurve25519, dhfn)(fs, a, zero);
	printf("X25519 low-order errors %d %d\n", he, fe);
	C(he == fe);
	C(F(h, cccurve25519_make_pub_with_rng, rpubfn)(&bad, hp, a) ==
	    F(f, cccurve25519_make_pub_with_rng, rpubfn)(&bad, fp, a));
	const void *di = ((const void *(*)(void))dlsym(h, "ccsha512_di"))();
	C(!F(h, cced25519_make_pub, epubfn)(di, hp, a));
	C(!F(f, cced25519_make_pub, epubfn)(di, fp, a));
	C(!memcmp(hp, fp, 32));
	C(!F(h, cced25519_sign, esignfn)(di, hs, 3, "abc", hp, a));
	C(!F(f, cced25519_sign, esignfn)(di, fs, 3, "abc", fp,
	    a)); /* Host mixes fresh randomness into its nonce; signatures need not match. */
	C(!F(h, cced25519_verify, everifyfn)(di, 3, "abc", fs, fp));
	C(!F(f, cced25519_verify, everifyfn)(di, 3, "abc", hs, hp));
	hs[0] ^= 1;
	he = F(h, cced25519_verify, everifyfn)(di, 3, "abc", hs, hp);
	fe = F(f, cced25519_verify, everifyfn)(di, 3, "abc", hs, hp);
	printf("Ed25519 bad-signature errors %d %d\n", he, fe);
	C(he == fe);
	C(!F(h, cccurve448_make_priv, privfn)(&r, a));
	C(!F(f, cccurve448_make_priv, privfn)(&r, b));
	C(!memcmp(a, b, 56));
	C(!F(h, cccurve448_make_pub, rpubfn)(&r, hp, a));
	C(!F(f, cccurve448_make_pub, rpubfn)(&r, fp, a));
	C(!memcmp(hp, fp, 56));
	C(!F(h, cccurve448, rdhfn)(&r, hs, a, hp));
	C(!F(f, cccurve448, rdhfn)(&r, fs, a, fp));
	C(!memcmp(hs, fs, 56));
	typedef int (*s448)(
	    struct ccrng_state *, void *, size_t, const void *, const void *, const void *);
	typedef int (*v448)(size_t, const void *, const void *, const void *);
	C(!F(h, cced448_make_pub, rpubfn)(&r, hp, a));
	C(!F(f, cced448_make_pub, rpubfn)(&r, fp, a));
	C(!memcmp(hp, fp, 57));
	C(!F(h, cced448_sign, s448)(&r, hs, 3, "abc", hp, a));
	C(!F(f, cced448_sign, s448)(&r, fs, 3, "abc", fp, a));
	C(!F(h, cced448_verify, v448)(3, "abc", fs, fp));
	C(!F(f, cced448_verify, v448)(3, "abc", hs, hp));
	hs[0] ^= 1;
	C(F(h, cced448_verify, v448)(3, "abc", hs, hp) ==
	    F(f, cced448_verify, v448)(3, "abc", hs, hp));
	printf("%d Curve25519/448 and Ed25519/448 checks passed\n", checks);
}
