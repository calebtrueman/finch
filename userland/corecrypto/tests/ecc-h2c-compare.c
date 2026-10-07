/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccec.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define C(X)                                                                                       \
	do {                                                                                       \
		if (!(X)) {                                                                        \
			fprintf(stderr, "FAIL %d: %s\n", __LINE__, #X);                            \
			exit(1);                                                                   \
		}                                                                                  \
		checks++;                                                                          \
	} while (0)
typedef int (*hashfn)(const void *, size_t, const void *, size_t, const void *, void *);
static int checks;
int main(int argc, char **argv)
{
	C(argc == 2);
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	     *f = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!f)
		fprintf(stderr, "%s\n", dlerror());
	C(h && f);
	hashfn hh = dlsym(h, "cch2c"), fh = dlsym(f, "cch2c");
	const char *names[] = {"cch2c_p256_sha256_sswu_ro_info", "cch2c_p384_sha512_sswu_ro_info",
	    "cch2c_p521_sha512_sswu_ro_info", "cch2c_p256_sha256_sae_compat_info",
	    "cch2c_p384_sha384_sae_compat_info"};
	unsigned char msg[256];
	for (int j = 0; j < 256; j++)
		msg[j] = (unsigned char)(j * 13 + 7);
	for (int i = 0; i < 5; i++) {
		void *hi = dlsym(h, names[i]), *fi = dlsym(f, names[i]);
		C(hi && fi);
		for (size_t n = 0; n <= 256; n = n < 3 ? n + 1 : n + 63) {
			unsigned char a[232] = {0}, b[232] = {0}, x[232] = {0};
			int hr = hh(hi, 3, "dst", n, msg, a), fr = fh(fi, 3, "dst", n, msg, b);
			C(hr == fr);
			if (!hr) {
				struct ccec_ctx *ka = (void *)a, *kb = (void *)b;
				C(ka->cp->n == kb->cp->n &&
				    !memcmp(a + 16, b + 16, 16 * ka->cp->n));
				C(!hh(fi, 3, "dst", n, msg, x));
				C(!memcmp(a + 16, x + 16, 16 * ka->cp->n));
				C(!fh(hi, 3, "dst", n, msg, x));
				C(!memcmp(a + 16, x + 16, 16 * ka->cp->n));
			}
		}
		C(hh(hi, 0, NULL, 3, msg, msg) == -7);
		C(fh(fi, 0, NULL, 3, msg, msg) == -7);
		printf("%s passed\n", names[i]);
	}
	printf("%d hash-to-curve checks passed\n", checks);
}
