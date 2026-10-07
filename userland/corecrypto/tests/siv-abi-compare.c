/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/siv.h"
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
static void same(const unsigned char *a, const unsigned char *b, size_t n)
{
	for (size_t i = 8; i < n; i++)
		if (a[i] != b[i]) {
			fprintf(stderr, "state mismatch at %zu: %02x %02x\n", i, a[i], b[i]);
			exit(1);
		}
}
int main(int argc, char **argv)
{
	CHECK(argc == 2);
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	     *f = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	CHECK(h && f);
	const struct ccmode_siv *m[2][2];
	for (int i = 0; i < 2; i++)
		for (int d = 0; d < 2; d++) {
			void *fn = dlsym(
			    i ? f : h, d ? "ccaes_siv_decrypt_mode" : "ccaes_siv_encrypt_mode");
			Dl_info info;
			CHECK(dladdr(fn, &info));
			if (i)
				CHECK(strstr(info.dli_fname, argv[1]));
			m[i][d] = ((const struct ccmode_siv *(*)(void))fn)();
		}
	CHECK(m[0][0]->size == m[1][0]->size);
	CHECK(m[0][0]->block_size == m[1][0]->block_size);
	unsigned char key[64], in[256], aad[64], nonce[32];
	for (size_t i = 0; i < 64; i++)
		key[i] = i * 13 + 7, aad[i] = i * 3;
	for (size_t i = 0; i < 256; i++)
		in[i] = i * 7;
	for (size_t i = 0; i < 32; i++)
		nonce[i] = i * 5;
	for (size_t kn = 32; kn <= 64; kn += 16)
		for (size_t n = 0; n < 128; n++)
			for (int a = 0; a < 3; a++) {
				_Alignas(16) unsigned char ctx[2][128], ct[2][288], pt[2][256];
				memset(ctx, 0xa5, sizeof(ctx));
				memset(ct, 0xb7, sizeof(ct));
				for (int j = 0; j < 2; j++) {
					CHECK(!m[j][0]->init(m[j][0], ctx[j], kn, key));
					if (a)
						CHECK(!m[j][0]->nonce(ctx[j], 13, nonce));
					if (a > 1)
						CHECK(!m[j][0]->aad(ctx[j], 31, aad));
				}
				same(ctx[0], ctx[1], 128);
				for (int j = 0; j < 2; j++)
					CHECK(!m[j][0]->crypt(ctx[j], n, in, ct[j]));
				CHECK(!memcmp(ct[0], ct[1], sizeof(ct[0])));
				same(ctx[0], ctx[1], 128);
				for (int j = 0; j < 2; j++)
					CHECK(m[j][0]->crypt(ctx[j], n, in, ct[j]) == -68);
				same(ctx[0], ctx[1], 128);
				for (int j = 0; j < 2; j++) {
					CHECK(!m[j][1]->init(m[j][1], ctx[j], kn, key));
					if (a)
						CHECK(!m[j][1]->nonce(ctx[j], 13, nonce));
					if (a > 1)
						CHECK(!m[j][1]->aad(ctx[j], 31, aad));
					CHECK(!m[1 - j][1]->crypt(ctx[j], n + 16, ct[j], pt[j]));
					CHECK(!memcmp(in, pt[j], n));
				}
				same(ctx[0], ctx[1], 128);
				for (int j = 0; j < 2; j++) {
					CHECK(!m[j][1]->reset(ctx[j]));
					if (a)
						CHECK(!m[j][1]->nonce(ctx[j], 13, nonce));
					if (a > 1)
						CHECK(!m[j][1]->aad(ctx[j], 31, aad));
					ct[j][0] ^= 1;
					memset(pt[j], 0xa5, 256);
					CHECK(m[j][1]->crypt(ctx[j], n + 16, ct[j], pt[j]) == -69);
					for (size_t k = 0; k < n; k++)
						CHECK(!pt[j][k]);
				}
				same(ctx[0], ctx[1], 128);
			}
	puts("SIV: host bytes, state, cross-library use, guards and bad tags match");
	return 0;
}
