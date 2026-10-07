/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
struct config {
	void *di, *rng, *mode;
	uint32_t key, tag, options;
};
struct api {
	int (*es)(void *, void *, void *, void *, size_t, size_t, unsigned);
	int (*ds)(void *, void *, void *, size_t, size_t, unsigned);
	int (*enc)(void *, void *, size_t, const void *, size_t, const void *, size_t, const void *,
	    size_t *, void *);
	int (*dec)(void *, void *, size_t, const void *, size_t, const void *, size_t, const void *,
	    size_t *, void *);
	int (*encs)(void *, void *, void *, size_t, const void *, size_t, const void *, size_t,
	    const void *, size_t, const void *, size_t *, void *);
	int (*decs)(void *, void *, size_t, const void *, size_t, const void *, size_t,
	    const void *, size_t, const void *, size_t *, void *);
};
static int tests;
#define CHECK(x)                                                                                   \
	do {                                                                                       \
		tests++;                                                                           \
		if (!(x)) {                                                                        \
			fprintf(stderr, "line %d: %s\n", __LINE__, #x);                            \
			exit(1);                                                                   \
		}                                                                                  \
	} while (0)
static void load(void *h, struct api *a)
{
	a->es = dlsym(h, "ccecies_encrypt_gcm_setup");
	a->ds = dlsym(h, "ccecies_decrypt_gcm_setup");
	a->enc = dlsym(h, "ccecies_encrypt_gcm");
	a->dec = dlsym(h, "ccecies_decrypt_gcm");
	a->encs = dlsym(h, "ccecies_encrypt_gcm_from_shared_secret");
	a->decs = dlsym(h, "ccecies_decrypt_gcm_from_shared_secret");
}
int main(int argc, char **argv)
{
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	     *f = dlopen(argc > 1 ? argv[1] : "/tmp/ecc-ecies-test.dylib", RTLD_NOW | RTLD_LOCAL);
	CHECK(h && f);
	struct api a[2];
	load(h, &a[0]);
	load(f, &a[1]);
	void *(*rng)(int *) = dlsym(h, "ccrng");
	void *(*di)(void) = dlsym(h, "ccsha256_di");
	void *(*em)(void) = dlsym(h, "ccaes_gcm_encrypt_mode");
	void *(*dm)(void) = dlsym(h, "ccaes_gcm_decrypt_mode");
	int (*gen)(void *, void *, void *) = dlsym(h, "ccec_generate_key");
	int (*dh)(void *, void *, size_t *, void *, void *) =
	    dlsym(h, "ccecdh_compute_shared_secret");
	unsigned bits[] = {192, 224, 256, 384, 521};
	for (unsigned b = 0; b < 5; b++) {
		char name[40];
		snprintf(name, sizeof name, "ccec_cp_%u", bits[b]);
		void *(*cpf)(void) = dlsym(h, name);
		void *cp = cpf();
		_Alignas(16) unsigned char key[400], eph[400];
		CHECK(gen(cp, rng(NULL), key) == 0);
		CHECK(gen(cp, rng(NULL), eph) == 0);
		unsigned char secret[66];
		size_t zn = sizeof(secret);
		CHECK(dh(eph, key, &zn, secret, rng(NULL)) == 0);
		for (unsigned option = 2; option <= 54; option++) {
			if (!(option & 6) || (option & 0x21) == 0x21)
				continue;
			size_t sn = (option & 1) ? 0 : 5;
			unsigned char message[37], cipher[256], plain[64];
			memset(message, 0x43, sizeof message);
			struct config e[2], d[2];
			for (int i = 0; i < 2; i++) {
				CHECK(a[i].es(&e[i], di(), rng(NULL), em(), 16, 16, option) == 0);
				CHECK(a[i].ds(&d[i], di(), dm(), 16, 16, option) == 0);
			}
			for (int i = 0; i < 2; i++) {
				size_t cn = sizeof(cipher);
				int rc = a[i].enc(key, &e[i], sizeof message, message, sn, "extra",
				    3, "aad", &cn, cipher);
				if (rc) {
					fprintf(stderr, "enc b%u o%u i%d rc%d\n", bits[b], option,
					    i, rc);
					return 1;
				}
				CHECK(rc == 0);
				for (int j = 0; j < 2; j++) {
					size_t pn = sizeof plain;
					rc = a[j].dec(key, &d[j], cn, cipher, sn, "extra", 3, "aad",
					    &pn, plain);
					if (rc) {
						fprintf(stderr, "dec b%u o%u i%d j%d rc%d\n",
						    bits[b], option, i, j, rc);
						return 1;
					}
					CHECK(rc == 0 && pn == sizeof message &&
					    !memcmp(message, plain, pn));
				}
				cipher[cn - 1] ^= 1;
				size_t pn = sizeof plain;
				CHECK(a[i].dec(key, &d[i], cn, cipher, sn, "extra", 3, "aad", &pn,
				          plain) != 0);
				for (size_t j = 0; j < pn; j++)
					CHECK(plain[j] == 0);
			}
			if (option & 0x21) {
				unsigned char c0[256], c1[256];
				size_t n0 = 256, n1 = 256;
				CHECK(a[0].encs(key, &e[0], eph, zn, secret, sizeof message,
				          message, sn, "extra", 3, "aad", &n0, c0) == 0);
				CHECK(a[1].encs(key, &e[1], eph, zn, secret, sizeof message,
				          message, sn, "extra", 3, "aad", &n1, c1) == 0);
				CHECK(n0 == n1 && !memcmp(c0, c1, n0));
				for (int i = 0; i < 2; i++) {
					size_t pn = sizeof plain;
					CHECK(a[i].decs(cp, &d[i], zn, secret, n0, c0, sn, "extra",
					          3, "aad", &pn, plain) == 0);
					CHECK(pn == sizeof message && !memcmp(plain, message, pn));
				}
			}
		}
	}
	printf("ECIES: %d checks passed\n", tests);
	return 0;
}
