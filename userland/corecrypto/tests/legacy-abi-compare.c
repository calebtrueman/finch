/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/legacy_ciphers.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(X)                                                                                   \
	do {                                                                                       \
		if (!(X)) {                                                                        \
			fprintf(stderr, "FAIL line %d: %s (%s)\n", __LINE__, #X, name);            \
			exit(1);                                                                   \
		}                                                                                  \
	} while (0)
int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	void *h[2] = {dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)};
	char name[100];
	CHECK(h[0] && h[1]);
	unsigned char key[256], in[128], iv[16], ctx[2][8192], out[2][128];
	for (int i = 0; i < 256; i++)
		key[i] = i;
	for (int i = 0; i < 128; i++)
		in[i] = i * 3;
	memset(iv, 9, sizeof iv);
	char *family[] = {"ccdes", "ccdes3", "ccrc2", "cccast", "ccblowfish"};
	char *mode[] = {"ecb_encrypt", "ecb_decrypt", "cbc_encrypt", "cbc_decrypt", "ctr_crypt",
	    "cfb_encrypt", "cfb_decrypt", "cfb8_encrypt", "cfb8_decrypt", "ofb_crypt"};
	size_t lengths[] = {8, 24, 16, 16, 32};
	for (int f = 0; f < 5; f++)
		for (int mo = 0; mo < 10; mo++) {
			snprintf(name, sizeof name, "%s_%s_mode", family[f], mode[mo]);
			for (int j = 0; j < 2; j++) {
				const void *(*get)(void) = dlsym(h[j], name);
				CHECK(get);
				memset(ctx[j], 0xa5, sizeof ctx[j]);
				memset(out[j], 0, sizeof out[j]);
				if (mo < 2) {
					const struct ccmode_ecb *m = get();
					CHECK(!m->init(m, ctx[j], lengths[f], key));
					CHECK(!m->ecb(ctx[j], 8, in, out[j]));
					CHECK(ctx[j][m->size] == 0xa5);
				} else if (mo < 4) {
					const struct ccmode_cbc *m = get();
					unsigned char chain[8];
					memcpy(chain, iv, 8);
					CHECK(!m->init(m, ctx[j], lengths[f], key));
					CHECK(!m->cbc(ctx[j], chain, 8, in, out[j]));
					CHECK(ctx[j][m->size] == 0xa5);
				} else if (mo == 4) {
					const struct ccmode_ctr *m = get();
					CHECK(!m->init(m, ctx[j], lengths[f], key, iv));
					CHECK(!m->ctr(ctx[j], 7, in, out[j]));
					CHECK(!m->ctr(ctx[j], 57, in + 7, out[j] + 7));
					CHECK(ctx[j][m->size] == 0xa5);
				} else {
					const struct ccmode_stream *m = get();
					CHECK(!m->init(m, ctx[j], lengths[f], key, iv));
					CHECK(!m->crypt(ctx[j], 7, in, out[j]));
					CHECK(!m->crypt(ctx[j], 57, in + 7, out[j] + 7));
					CHECK(ctx[j][m->size] == 0xa5);
				}
			}
			CHECK(!memcmp(out[0], out[1], 64));
		}
	/* Compare the full key layout and use each side's state on the other side. */
	for (int f = 0; f < 5; f++)
		for (int direction = 0; direction < 2; direction++) {
			snprintf(name, sizeof name, "%s_ecb_%s_mode", family[f],
			    direction ? "decrypt" : "encrypt");
			const struct ccmode_ecb *m[2];
			for (int j = 0; j < 2; j++) {
				const struct ccmode_ecb *(*get)(void) = dlsym(h[j], name);
				m[j] = get();
			}
			CHECK(m[0]->size == m[1]->size);
			for (int trial = 0; trial < 32; trial++) {
				for (int i = 0; i < 256; i++)
					key[i] = (unsigned char)(i * 7 + trial * 13);
				for (int j = 0; j < 2; j++) {
					memset(ctx[j], 0xa5, sizeof ctx[j]);
					CHECK(!m[j]->init(m[j], ctx[j], lengths[f], key));
				}
				CHECK(!memcmp(ctx[0], ctx[1], m[0]->size));
				for (int j = 0; j < 2; j++)
					CHECK(!m[j]->ecb(ctx[1 - j], 8, in, out[j]));
				CHECK(!memcmp(out[0], out[1], 64));
			}
		}
	for (int f = 0; f < 5; f++) {
		snprintf(name, sizeof name, "%s_ecb_encrypt_mode", family[f]);
		const struct ccmode_ecb *m[2];
		for (int j = 0; j < 2; j++) {
			const struct ccmode_ecb *(*get)(void) = dlsym(h[j], name);
			m[j] = get();
		}
		for (size_t kn = 0; kn <= 140; kn++) {
			int status[2];
			for (int j = 0; j < 2; j++) {
				memset(ctx[j], 0xa5, sizeof ctx[j]);
				status[j] = m[j]->init(m[j], ctx[j], kn, key);
			}
			CHECK(status[0] == status[1]);
			if (memcmp(ctx[0], ctx[1], m[0]->size))
				fprintf(stderr, "key length %zu\n", kn);
			CHECK(!memcmp(ctx[0], ctx[1], m[0]->size));
			CHECK(ctx[0][m[0]->size] == 0xa5 && ctx[1][m[1]->size] == 0xa5);
		}
		if (f == 1) {
			for (int equal = 0; equal < 3; equal++) {
				for (int i = 0; i < 24; i++)
					key[i] = i;
				memcpy(key + (equal == 2 ? 8 : 0), key + (equal == 0 ? 8 : 16), 8);
				int status[2];
				for (int j = 0; j < 2; j++)
					status[j] = m[j]->init(m[j], ctx[j], 24, key);
				CHECK(status[0] == -1 && status[1] == -1);
				CHECK(!memcmp(ctx[0], ctx[1], m[0]->size));
			}
		}
	}
	strcpy(name, "DES checksum");
	typedef unsigned long (*sumfn)(
	    const void *, void *, size_t, const void *, size_t, const void *);
	sumfn sums[2] = {dlsym(h[0], "ccdes_cbc_cksum"), dlsym(h[1], "ccdes_cbc_cksum")};
	for (size_t n = 0; n < 100; n++) {
		unsigned long sumsout[2];
		for (int j = 0; j < 2; j++) {
			memset(out[j], 0xa5, sizeof out[j]);
			sumsout[j] = sums[j](in, out[j], n, key, 8, iv);
		}
		CHECK(sumsout[0] == sumsout[1]);
		CHECK(!memcmp(out[0], out[1], sizeof out[0]));
	}
	strcpy(name, "DES parity");
	void (*parity[2])(void *, size_t) = {
	    dlsym(h[0], "ccdes_key_set_odd_parity"), dlsym(h[1], "ccdes_key_set_odd_parity")};
	int (*weak[2])(const void *, size_t) = {
	    dlsym(h[0], "ccdes_key_is_weak"), dlsym(h[1], "ccdes_key_is_weak")};
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 128; i++)
			out[j][i] = i;
		parity[j](out[j], 128);
	}
	CHECK(!memcmp(out[0], out[1], 128));
	for (int i = 0; i < 256; i++) {
		memset(key, i, 8);
		CHECK(weak[0](key, 8) == weak[1](key, 8));
	}
	strcpy(name, "RC4");
	const struct ccrc4_info *r[2];
	for (int j = 0; j < 2; j++) {
		const struct ccrc4_info *(*get)(void) = dlsym(h[j], "ccrc4");
		r[j] = get();
		r[j]->init(ctx[j], 16, key);
		r[j]->crypt(ctx[j], 19, in, out[j]);
	}
	CHECK(!memcmp(ctx[0], ctx[1], r[0]->size));
	r[0]->crypt(ctx[1], 45, in + 19, out[1] + 19);
	r[1]->crypt(ctx[0], 45, in + 19, out[0] + 19);
	CHECK(!memcmp(out[0], out[1], 64));
	puts(
	    "Legacy cipher output: 50 modes, byte-identical key layouts, cross-used block/RC4 contexts and DES helpers passed");
	return 0;
}
