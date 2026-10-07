/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccdrbg.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define LOAD(ret, name, args)                                                                      \
	ret(*h_##name) args = dlsym(h, #name);                                                     \
	ret(*f_##name) args = dlsym(f, #name)
static int count, failed;
#define CK(x)                                                                                      \
	do {                                                                                       \
		count++;                                                                           \
		if (!(x)) {                                                                        \
			failed++;                                                                  \
			fprintf(stderr, "line %d: %s\n", __LINE__, #x);                            \
		}                                                                                  \
	} while (0)
int main(int argc, char **argv)
{
	void *h = dlopen("/usr/lib/system/libcorecrypto.dylib", 2),
	     *f = dlopen(argc > 1 ? argv[1] : "build/userland/corecrypto/rsa-test.dylib", 2);
	if (!h || !f) {
		puts(dlerror());
		return 2;
	}
	LOAD(void, ccdrbg_factory_nisthmac,
	    (struct ccdrbg_info *, const struct ccdrbg_custom_hmac *));
	LOAD(
	    void, ccdrbg_factory_nistctr, (struct ccdrbg_info *, const struct ccdrbg_custom_ctr *));
	LOAD(int, ccdrbg_df_bc_init, (struct ccdrbg_df *, const struct ccmode_cbc *, size_t));
	LOAD(const struct ccmode_cbc *, ccaes_cbc_encrypt_mode, (void));
	LOAD(const struct ccmode_ctr *, ccaes_ctr_crypt_mode, (void));
	unsigned char entropy[64], nonce[32], extra[100], a[65540], b[65540], hs[1024], fs[1024];
	for (int i = 0; i < 64; i++)
		entropy[i] = i;
	for (int i = 0; i < 32; i++)
		nonce[i] = i + 33;
	for (int i = 0; i < 100; i++)
		extra[i] = i + 77;
	const char *digests[] = {
	    "ccsha1_di", "ccsha224_di", "ccsha256_di", "ccsha384_di", "ccsha512_di"};
	for (unsigned kind = 0; kind < 5 + 6; kind++)
		for (unsigned cross = 0; cross < 2; cross++) {
			struct ccdrbg_info hi, fi;
			struct ccdrbg_custom_hmac hc, fc;
			struct ccdrbg_custom_ctr hcc, fcc;
			struct ccdrbg_df hdf, fdf;
			size_t en = 32;
			if (kind < 5) {
				const struct ccdigest_info *(*hd)(void) = dlsym(h, digests[kind]),
				                           *(*fd)(void) = dlsym(f, digests[kind]);
				hc = (struct ccdrbg_custom_hmac){hd(), 1};
				fc = (struct ccdrbg_custom_hmac){cross ? hd() : fd(), 1};
				h_ccdrbg_factory_nisthmac(&hi, &hc);
				f_ccdrbg_factory_nisthmac(&fi, &fc);
			} else {
				size_t key = 16 + 8 * ((kind - 5) % 3);
				int df = (kind - 5) / 3;
				hcc = (struct ccdrbg_custom_ctr){
				    h_ccaes_ctr_crypt_mode(), key, 1, df ? &hdf : NULL};
				fcc = (struct ccdrbg_custom_ctr){
				    cross ? h_ccaes_ctr_crypt_mode() : f_ccaes_ctr_crypt_mode(),
				    key, 1, df ? &fdf : NULL};
				if (df) {
					CK(h_ccdrbg_df_bc_init(
					       &hdf, h_ccaes_cbc_encrypt_mode(), key) == 0);
					CK(f_ccdrbg_df_bc_init(&fdf,
					       cross ? h_ccaes_cbc_encrypt_mode()
					             : f_ccaes_cbc_encrypt_mode(),
					       key) == 0);
					struct ccdrbg_df_input in[] = {
					    {entropy, 43}, {nonce, 17}, {extra, 33}};
					for (unsigned len = 0; len < 65; len++) {
						CK(hdf.derive(&hdf, 3, in, len, a) ==
						    fdf.derive(&fdf, 3, in, len, b));
						CK(!memcmp(a, b, len));
					}
				} else
					en = key + 16;
				h_ccdrbg_factory_nistctr(&hi, &hcc);
				f_ccdrbg_factory_nistctr(&fi, &fcc);
			}
			CK(hi.size == fi.size);
			memset(hs, 0xa5, sizeof(hs));
			memset(fs, 0xa5, sizeof(fs));
			CK(hi.init(&hi, hs, en, entropy, 16, nonce, 11, extra) ==
			    fi.init(&fi, fs, en, entropy, 16, nonce, 11, extra));
			if (kind < 5)
				CK(!memcmp(hs + 8, fs + 8, hi.size - 8));
			else {
				CK(!memcmp(hs, fs, 56));
				CK(!memcmp(hs + 64, fs + 64, 16));
			}
			size_t lens[] = {0, 1, 15, 16, 17, 31, 32, 33, 100, 65536};
			for (unsigned j = 0; j < 10; j++) {
				size_t len = lens[j];
				CK(hi.generate(hs, len, a, j % 2 ? 13 : 0, extra) ==
				    fi.generate(fs, len, b, j % 2 ? 13 : 0, extra));
				CK(!memcmp(a, b, len));
				if (kind < 5)
					CK(!memcmp(hs + 8, fs + 8, hi.size - 8));
				else
					CK(!memcmp(hs, fs, 56));
			}
			CK(hi.reseed(hs, en, entropy, 11, extra) ==
			    fi.reseed(fs, en, entropy, 11, extra));
			CK(hi.generate(hs, 100, a, 0, NULL) == fi.generate(fs, 100, b, 0, NULL));
			CK(!memcmp(a, b, 100));
			/* Both callback sets can continue the other library's state. */
			unsigned char saved[1024];
			memcpy(saved, hs, hi.size);
			CK(fi.generate(hs, 100, a, 7, extra) ==
			    hi.generate(saved, 100, b, 7, extra));
			CK(!memcmp(a, b, 100));
			memcpy(saved, fs, fi.size);
			CK(hi.generate(fs, 100, a, 7, extra) ==
			    fi.generate(saved, 100, b, 7, extra));
			CK(!memcmp(a, b, 100));
			CK(hi.generate(hs, 65537, a, 0, NULL) ==
			    fi.generate(fs, 65537, b, 0, NULL));
			CK(hi.generate(hs, 1, a, 65537, extra) ==
			    fi.generate(fs, 1, b, 65537, extra));
			hi.done(hs);
			fi.done(fs);
			if (kind < 5)
				CK(!memcmp(hs + 8, fs + 8, hi.size - 8));
			else
				CK(!memcmp(hs, fs, 56));
		}
	printf("DRBG ABI: %d checks, %d failures\n", count, failed);
	return !!failed;
}
