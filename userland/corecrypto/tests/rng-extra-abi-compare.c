/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccrng.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x)                                                                                   \
	do {                                                                                       \
		if (!(x)) {                                                                        \
			fprintf(stderr, "line %d failed: %s\n", __LINE__, #x);                     \
			exit(1);                                                                   \
		}                                                                                  \
	} while (0)
int main(int argc, char **argv)
{
	CHECK(argc == 2);
	void *lib[2] = {dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)};
	CHECK(lib[0] && lib[1]);
	int (*pb[2])(void *, size_t, size_t, const void *, size_t, const void *, unsigned long);
	int (*ec[2])(void *, size_t, const void *);
	int (*rs[2])(
	    void *, size_t, const uint64_t *, size_t, const uint64_t *, size_t, const uint64_t *);
	void (*next[2])(void *, size_t);
	int (*init[2])(void *, size_t, const void *, const char *);
	void (*done[2])(void *);
	for (int j = 0; j < 2; j++) {
		pb[j] = dlsym(lib[j], "ccrng_pbkdf2_prng_init");
		ec[j] = dlsym(lib[j], "ccrng_ecfips_test_init");
		rs[j] = dlsym(lib[j], "ccrng_rsafips_test_init");
		next[j] = dlsym(lib[j], "ccrng_rsafips_test_set_next");
		init[j] = dlsym(lib[j], "ccrng_test_init");
		done[j] = dlsym(lib[j], "ccrng_test_done");
		Dl_info info;
		CHECK(dladdr((void *)init[j], &info));
		if (j)
			CHECK(strstr(info.dli_fname, argv[1]));
	}
	unsigned char seed[256];
	for (size_t i = 0; i < 256; i++)
		seed[i] = i * 13;
	for (size_t n = 0; n < 120; n++) {
		_Alignas(16) unsigned char c[2][4144], out[2][200];
		memset(c, 0xa5, sizeof(c));
		memset(out, 0xb5, sizeof(out));
		for (int j = 0; j < 2; j++)
			CHECK(!pb[j](c[j], n, 23, seed, 11, seed + 30, 7));
		CHECK(!memcmp(c[0] + 8, c[1] + 8, 4136));
		size_t steps[] = {n / 2, n - n / 2, 1, 0};
		for (size_t s = 0; s < 4; s++) {
			int r[2];
			for (int j = 0; j < 2; j++) {
				struct ccrng_state *rng = (void *)c[j];
				r[j] = rng->generate(rng, steps[s], out[j]);
			}
			CHECK(r[0] == r[1]);
			CHECK(!memcmp(out[0], out[1], 200));
			CHECK(!memcmp(c[0] + 8, c[1] + 8, 4136));
		}
	}
	for (size_t n = 0; n < 32; n++) {
		unsigned char c[2][48], out[2][200];
		memset(c, 0xa5, sizeof(c));
		memset(out, 0xb5, sizeof(out));
		for (int j = 0; j < 2; j++)
			CHECK(!ec[j](c[j], n, seed));
		CHECK(!memcmp(c[0] + 8, c[1] + 8, 40));
		for (size_t z = 0; z < 100; z++) {
			int r[2];
			for (int j = 0; j < 2; j++) {
				struct ccrng_state *rng = (void *)c[j];
				r[j] = rng->generate(rng, z, out[j]);
			}
			CHECK(r[0] == r[1]);
			CHECK(!memcmp(out[0], out[1], 200));
		}
	}
	for (size_t n = 16; n <= 64; n += 16)
		for (int named = 0; named < 2; named++) {
			unsigned char c[2][96], out[2][200];
			memset(c, 0xa5, sizeof(c));
			for (int j = 0; j < 2; j++)
				CHECK(!init[j](c[j], n, seed, named ? "same-test" : NULL));
			for (size_t z = 0; z < 100; z++) {
				for (int j = 0; j < 2; j++) {
					struct ccrng_state *rng = (void *)c[j];
					CHECK(!rng->generate(rng, z, out[j]));
				}
				CHECK(!memcmp(out[0], out[1], z));
			}
			for (int j = 0; j < 2; j++) {
				done[1 - j](c[j]);
				CHECK(!*(void **)(c[j] + 64));
			}
		}
	uint64_t v0[] = {0x123456789abcdefULL, 0x42}, v1[] = {0xffff}, v2[] = {1, 2, 3};
	for (size_t n = 1; n < 32; n++) {
		unsigned char c[2][88], out[2][64];
		memset(c, 0xa5, sizeof(c));
		memset(out, 0xb5, sizeof(out));
		for (int j = 0; j < 2; j++) {
			CHECK(!rs[j](c[j], 2, v0, 1, v1, 3, v2));
			next[1 - j](c[j], 0);
		}
		for (int turn = 0; turn < 3; turn++) {
			int r[2];
			for (int j = 0; j < 2; j++) {
				struct ccrng_state *rng = (void *)c[j];
				r[j] = rng->generate(rng, n, out[j]);
			}
			CHECK(r[0] == r[1]);
			CHECK(!memcmp(out[0], out[1], 64));
			CHECK(!memcmp(c[0] + 8, c[1] + 8, 80));
		}
	}
	puts("Extra RNGs: host streams/state, partial reads, test DRBG, cleanup and errors match");
	return 0;
}
