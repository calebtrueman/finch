/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccdigest.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
#define CHECK(x)                                                                                   \
	do {                                                                                       \
		checks++;                                                                          \
		if (!(x)) {                                                                        \
			fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x);                            \
			exit(1);                                                                   \
		}                                                                                  \
	} while (0)
int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	void *h[2] = {dlopen("/usr/lib/system/libcorecrypto.dylib", 2),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)};
	CHECK(h[0] && h[1]);
	int64_t (*size[2])(uint64_t, uint32_t, uint32_t);
	int (*scrypt[2])(size_t, const void *, size_t, const void *, void *, uint64_t, uint32_t,
	    uint32_t, size_t, void *);
	int (*mgf[2])(const struct ccdigest_info *, size_t, void *, size_t, const void *);
	for (int j = 0; j < 2; j++) {
		size[j] = dlsym(h[j], "ccscrypt_storage_size");
		scrypt[j] = dlsym(h[j], "ccscrypt");
		mgf[j] = dlsym(h[j], "ccmgf");
		CHECK(size[j] && scrypt[j] && mgf[j]);
	}
	uint32_t vals[] = {0, 1, 2, 3, 8, 1024, UINT32_MAX, UINT32_C(0x2000000)};
	for (unsigned k = 0; k < 64; k++)
		for (unsigned a = 0; a < sizeof vals / sizeof vals[0]; a++)
			for (unsigned b = 0; b < sizeof vals / sizeof vals[0]; b++) {
				uint64_t N = UINT64_C(1) << k;
				CHECK(size[0](N, vals[a], vals[b]) == size[1](N, vals[a], vals[b]));
				CHECK(size[0](N + 1, vals[a], vals[b]) ==
				    size[1](N + 1, vals[a], vals[b]));
			}
	unsigned char out[2][160];
	for (uint64_t N = 1; N <= 64; N *= 2)
		for (uint32_t r = 1; r <= 3; r++)
			for (uint32_t p = 0; p <= 2; p++)
				for (size_t len = 1; len < 100; len += 31) {
					int64_t cap = size[0](N, r, p);
					CHECK(cap > 0);
					void *scratch[2];
					int ret[2];
					for (int j = 0; j < 2; j++) {
						scratch[j] = malloc(cap + 16);
						memset(scratch[j], 0xa5, cap + 16);
						memset(out[j], 0xa5, sizeof out[j]);
						ret[j] = scrypt[j](8, "password", 4, "salt",
						    scratch[j], N, r, p, len, out[j]);
					}
					if (ret[0] != ret[1] ||
					    memcmp(out[0], out[1], sizeof out[0]))
						fprintf(stderr, "N%llu r%u p%u len%zu ret%d %d\n",
						    (unsigned long long)N, r, p, len, ret[0],
						    ret[1]);
					CHECK(ret[0] == ret[1]);
					CHECK(!memcmp(out[0], out[1], sizeof out[0]));
					CHECK(!memcmp(scratch[0], scratch[1], cap + 16));
					free(scratch[0]);
					free(scratch[1]);
				}
	const char *names[] = {"ccsha1_di", "ccsha256_di", "ccsha512_di"};
	unsigned char seed[80];
	for (int i = 0; i < 80; i++)
		seed[i] = i * 7;
	for (int d = 0; d < 3; d++) {
		const struct ccdigest_info *di[2];
		for (int j = 0; j < 2; j++) {
			const struct ccdigest_info *(*get)(void) = dlsym(h[j], names[d]);
			di[j] = get();
		}
		for (size_t sn = 0; sn <= 80; sn += 10)
			for (size_t len = 0; len <= 128; len++) {
				for (int j = 0; j < 2; j++) {
					memset(out[j], 0xa5, sizeof out[j]);
					CHECK(!mgf[j](di[1 - j], len, out[j], sn, seed));
				}
				CHECK(!memcmp(out[0], out[1], sizeof out[0]));
			}
	}
	printf("Extra KDF: %u checks passed\n", checks);
}
