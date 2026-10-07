/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/siv_hmac.h"
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
	void *lib[2] = {dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)};
	CHECK(lib[0] && lib[1]);
	const struct ccmode_siv_hmac *m[2][2];
	for (int j = 0; j < 2; j++)
		for (int d = 0; d < 2; d++) {
			void *f = dlsym(lib[j],
			    d ? "ccaes_siv_hmac_sha256_decrypt_mode"
			      : "ccaes_siv_hmac_sha256_encrypt_mode");
			CHECK(f);
			Dl_info info;
			CHECK(dladdr(f, &info));
			if (j)
				CHECK(strstr(info.dli_fname, argv[1]));
			m[j][d] = ((const struct ccmode_siv_hmac *(*)(void))f)();
		}
	CHECK(m[0][0]->size == m[1][0]->size);
	CHECK(m[0][0]->block_size == m[1][0]->block_size);
	unsigned char key[64], in[128], aad[64], nonce[32];
	for (size_t i = 0; i < 64; i++)
		key[i] = i * 7, aad[i] = i * 3;
	for (size_t i = 0; i < 128; i++)
		in[i] = i * 11;
	for (size_t i = 0; i < 32; i++)
		nonce[i] = i * 5;
	for (size_t tn = 20; tn <= 32; tn++)
		for (size_t n = 0; n < 96; n++)
			for (int a = 0; a < 3; a++) {
				_Alignas(16) unsigned char c[2][624], out[2][192], pt[2][128];
				memset(c, 0xa5, sizeof(c));
				memset(out, 0xb5, sizeof(out));
				for (int j = 0; j < 2; j++) {
					CHECK(!m[j][0]->init(m[j][0], c[j], 32, key, tn));
					if (a)
						CHECK(!m[j][0]->aad(c[j], 31, aad));
					if (a > 1)
						CHECK(!m[j][0]->nonce(c[j], 13, nonce));
				}
				same(c[0], c[1], 624);
				for (int j = 0; j < 2; j++)
					CHECK(!m[j][0]->crypt(c[j], n, in, out[j]));
				CHECK(!memcmp(out[0], out[1], 192));
				same(c[0], c[1], 624);
				for (int j = 0; j < 2; j++) {
					CHECK(!m[j][1]->init(m[j][1], c[j], 32, key, tn));
					if (a)
						CHECK(!m[j][1]->aad(c[j], 31, aad));
					if (a > 1)
						CHECK(!m[j][1]->nonce(c[j], 13, nonce));
					CHECK(!m[1 - j][1]->crypt(c[j], n + tn, out[j], pt[j]));
					CHECK(!memcmp(pt[j], in, n));
				}
				same(c[0], c[1], 624);
				for (int j = 0; j < 2; j++) {
					CHECK(!m[j][1]->reset(c[j]));
					if (a)
						CHECK(!m[j][1]->aad(c[j], 31, aad));
					if (a > 1)
						CHECK(!m[j][1]->nonce(c[j], 13, nonce));
					out[j][0] ^= 1;
					CHECK(m[j][1]->crypt(c[j], n + tn, out[j], pt[j]) == -104);
					for (size_t i = 0; i < n; i++)
						CHECK(!pt[j][i]);
				}
				same(c[0], c[1], 624);
			}
	/* The host leaves gaps in its temporary key for these sizes. Test our fully
    filled key for stable output and round trips, rather than copying that bug. */
	for (size_t kn = 48; kn <= 64; kn += 16)
		for (size_t n = 0; n < 96; n++) {
			unsigned char c[600], ct[2][128], pt[128];
			for (int j = 0; j < 2; j++) {
				CHECK(!m[1][0]->init(m[1][0], c, kn, key, 32));
				CHECK(!m[1][0]->crypt(c, n, in, ct[j]));
			}
			CHECK(!memcmp(ct[0], ct[1], n + 32));
			CHECK(!m[1][1]->init(m[1][1], c, kn, key, 32));
			CHECK(!m[1][1]->crypt(c, n + 32, ct[0], pt));
			CHECK(!memcmp(pt, in, n));
		}
	for (size_t kn = 0; kn < 70; kn++)
		for (size_t tn = 0; tn < 36; tn++) {
			unsigned char c[2][624];
			memset(c, 0xa5, sizeof(c));
			int a = m[0][0]->init(m[0][0], c[0], kn, key, tn),
			    b = m[1][0]->init(m[1][0], c[1], kn, key, tn);
			CHECK(a == b);
			same(c[0], c[1], 624);
		}
	puts(
	    "SIV-HMAC: host output/state/cross-use and errors match for 32-byte keys; larger keys have stable safe round trips");
	return 0;
}
