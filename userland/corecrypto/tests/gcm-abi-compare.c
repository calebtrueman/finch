/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks, failures;
static size_t key_length, iv_length, auth_length, text_length;
static int direction;
static void same(const char *name, const void *a, const void *b, size_t n)
{
	checks++;
	if (memcmp(a, b, n) && failures++ < 12) {
		fprintf(stderr, "%s differs: direction%d key%zu iv%zu aad%zu text%zu\n", name,
		    direction, key_length, iv_length, auth_length, text_length);
		for (size_t i = 0; i < n; i++)
			if (((const unsigned char *)a)[i] != ((const unsigned char *)b)[i]) {
				fprintf(stderr, " first byte %zu: %02x/%02x\n", i,
				    ((const unsigned char *)a)[i], ((const unsigned char *)b)[i]);
				break;
			}
	}
}
static void result(const char *n, int a, int b)
{
	same(n, &a, &b, sizeof(a));
}
static void state(const void *a, const void *b)
{
	same("state head", a, b, 104);
	same("state tail", (const unsigned char *)a + 120, (const unsigned char *)b + 120, 648);
}
static void *sym(void *h, const char *n)
{
	void *p = dlsym(h, n);
	if (!p) {
		fprintf(stderr, "%s\n", dlerror());
		exit(2);
	}
	return p;
}
int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	void *h[2] = {
	    dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL | RTLD_FIRST),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST)};
	if (!h[0] || !h[1]) {
		fprintf(stderr, "%s\n", dlerror());
		return 2;
	}
	unsigned char key[32], iv[64], auth[64], input[256];
	for (size_t i = 0; i < 32; i++)
		key[i] = (unsigned char)(i * 17 + 3);
	for (size_t i = 0; i < 64; i++) {
		iv[i] = (unsigned char)(i * 31 + 7);
		auth[i] = (unsigned char)(i * 13 + 9);
	}
	for (size_t i = 0; i < 256; i++)
		input[i] = (unsigned char)(i * 67 + 23);
	const size_t keys[] = {16, 24, 32}, ivs[] = {1, 8, 12, 15, 16, 17, 33},
	             aads[] = {0, 1, 15, 16, 17, 33},
	             texts[] = {0, 1, 15, 16, 17, 31, 32, 127, 256};
	for (direction = 0; direction < 2; direction++) {
		const char *name = direction ? "ccaes_gcm_decrypt_mode" : "ccaes_gcm_encrypt_mode";
		const struct ccmode_gcm *(*get[2])(void) = {sym(h[0], name), sym(h[1], name)};
		const struct ccmode_gcm *m[2] = {get[0](), get[1]()};
		if (m[0] == m[1])
			return 2;
		same("descriptor", m[0], m[1], 24);
		for (size_t k = 0; k < 3; k++)
			for (size_t v = 0; v < 7; v++)
				for (size_t a = 0; a < 6; a++)
					for (size_t t = 0; t < 9; t++) {
						key_length = keys[k];
						iv_length = ivs[v];
						auth_length = aads[a];
						text_length = texts[t];
						_Alignas(16) unsigned char ctx[5][768];
						unsigned char out[5][272], tags[5][32];
						memset(ctx, 0xa5, sizeof(ctx));
						memset(out, 0x5a, sizeof(out));
						memset(tags, 0x7b, sizeof(tags));
						for (int c = 0; c < 5; c++) {
							int creator = c == 0 ? 0 : (c - 1) / 2,
							    caller = c == 0 ? 0 : (c - 1) % 2;
							result("init", 0,
							    m[creator]->init(m[creator], ctx[c],
							        key_length, key));

							result("iv", 0,
							    m[caller]->set_iv(
							        ctx[c], iv_length, iv));
							/* Reference initialization for each step is checked below,
                 * after all contexts have reached that step. */
						}
						for (int c = 1; c < 5; c++)
							state(ctx[0], ctx[c]);
						for (int step = 0; step < 2; step++) {
							size_t start = step ? auth_length / 2 : 0,
							       n = step ? auth_length - start
							                : auth_length / 2;
							for (int c = 0; c < 5; c++) {
								int caller =
								    c == 0 ? 0 : (c - 1) % 2;
								result("aad", 0,
								    m[caller]->aad(
								        ctx[c], n, auth + start));
							}
							for (int c = 1; c < 5; c++)
								state(ctx[0], ctx[c]);
						}
						for (int step = 0; step < 2; step++) {
							size_t start = step ? text_length / 2 : 0,
							       n = step ? text_length - start
							                : text_length / 2;
							for (int c = 0; c < 5; c++) {
								int caller =
								    c == 0 ? 0 : (c - 1) % 2;
								result("crypt", 0,
								    m[caller]->gcm(ctx[c], n,
								        input + start,
								        out[c] + start));
							}
							for (int c = 1; c < 5; c++) {
								state(ctx[0], ctx[c]);
								same("output", out[0], out[c],
								    sizeof(out[0]));
							}
						}
						int expected = m[0]->finalize(ctx[0], 16, tags[0]);
						for (int c = 1; c < 5; c++) {
							int caller = (c - 1) % 2;
							result("finalize", expected,
							    m[caller]->finalize(
							        ctx[c], 16, tags[c]));
							state(ctx[0], ctx[c]);
							same("tag and guard", tags[0], tags[c], 32);
							result("late aad", -68,
							    m[caller]->aad(ctx[c], 0, NULL));
							result("late crypt", -68,
							    m[caller]->gcm(ctx[c], 0, NULL, NULL));
							result("late finalize", -68,
							    m[caller]->finalize(
							        ctx[c], 16, tags[c]));
						}
						for (int c = 0; c < 5; c++) {
							int caller = c == 0 ? 0 : (c - 1) % 2;
							result(
							    "reset", 0, m[caller]->reset(ctx[c]));
						}
						for (int c = 1; c < 5; c++)
							state(ctx[0], ctx[c]);
					}
	}
	typedef int (*once_fn)(const struct ccmode_gcm *, size_t, const void *, size_t,
	    const void *, size_t, const void *, size_t, const void *, void *, size_t, void *);
	once_fn once[2] = {sym(h[0], "ccgcm_one_shot"), sym(h[1], "ccgcm_one_shot")};
	const struct ccmode_gcm *mode[2][2];
	for (int provider = 0; provider < 2; provider++)
		for (int d = 0; d < 2; d++) {
			const struct ccmode_gcm *(*get)(void) = sym(
			    h[provider], d ? "ccaes_gcm_decrypt_mode" : "ccaes_gcm_encrypt_mode");
			mode[provider][d] = get();
		}
	unsigned char zero[32] = {0}, cipher[32], tag[32];
	const unsigned char known_cipher[16] = {0x03, 0x88, 0xda, 0xce, 0x60, 0xb6, 0xa3, 0x92,
	    0xf3, 0x28, 0xc2, 0xb9, 0x71, 0xb2, 0xfe, 0x78};
	const unsigned char known_tag[16] = {0xab, 0x6e, 0x47, 0xd4, 0x2c, 0xec, 0x13, 0xbd, 0xf5,
	    0x3a, 0x67, 0xb2, 0x12, 0x57, 0xbd, 0xdf};
	for (int caller = 0; caller < 2; caller++)
		for (int descriptor = 0; descriptor < 2; descriptor++) {
			memset(cipher, 0x5a, sizeof(cipher));
			memset(tag, 0x7b, sizeof(tag));
			result("known encryption", 0,
			    once[caller](mode[descriptor][0], 16, zero, 12, zero, 0, NULL, 16, zero,
			        cipher, 16, tag));
			same("known cipher", known_cipher, cipher, 16);
			same("known tag", known_tag, tag, 16);
		}
	const size_t tag_sizes[] = {0, 1, 4, 8, 12, 16, 17, 32};
	for (size_t z = 0; z < sizeof(tag_sizes) / sizeof(*tag_sizes); z++)
		for (int tamper = 0; tamper < 3; tamper++) {
			unsigned char altered[16], supplied[32], reference[32], reference_tag[32],
			    out[32], out_tag[32];
			memcpy(altered, known_cipher, 16);
			memset(supplied, 0x7b, 32);
			memcpy(supplied, known_tag, 16);
			if (tamper == 1)
				supplied[0] ^= 1;
			if (tamper == 2)
				altered[0] ^= 1;
			memset(reference, 0x5a, 32);
			memcpy(reference_tag, supplied, 32);
			int expected = once[0](mode[0][1], 16, zero, 12, zero, 0, NULL, 16, altered,
			    reference, tag_sizes[z], reference_tag);
			for (int caller = 0; caller < 2; caller++)
				for (int descriptor = 0; descriptor < 2; descriptor++) {
					memset(out, 0x5a, 32);
					memcpy(out_tag, supplied, 32);
					result("tag verification", expected,
					    once[caller](mode[descriptor][1], 16, zero, 12, zero, 0,
					        NULL, 16, altered, out, tag_sizes[z], out_tag));
					same("verified plaintext", reference, out, 32);
					same("verified tag", reference_tag, out_tag, 32);
				}
		}
	for (int provider = 0; provider < 2; provider++) {
		int (*init_iv)(const struct ccmode_gcm *, void *, size_t, const void *,
		    const void *) = sym(h[provider], "ccgcm_init_with_iv");
		int (*inc_iv)(const struct ccmode_gcm *, void *, void *) =
		    sym(h[provider], "ccgcm_inc_iv");
		for (int desc = 0; desc < 2; desc++) {
			_Alignas(16) unsigned char ctx[768];
			memset(ctx, 0xa5, sizeof(ctx));
			unsigned char nonce[16];
			memset(nonce, 0xff, 16);
			result("init with IV", 0, init_iv(mode[desc][0], ctx, 16, zero, nonce));
			result("inc without reset", -68, inc_iv(mode[desc][0], ctx, nonce));
			result("reset before inc", 0, mode[desc][0]->reset(ctx));
			result("set locked IV", -68, mode[desc][0]->set_iv(ctx, 12, zero));
			result("inc after reset", 0, inc_iv(mode[desc][0], ctx, nonce));
			const unsigned char expected_nonce[16] = {
			    255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255};
			same("incremented IV and guard", expected_nonce, nonce, 16);
		}
	}
	for (int caller = 0; caller < 2; caller++)
		for (int desc = 0; desc < 2; desc++) {
			_Alignas(16) unsigned char ctx[768];
			memset(ctx, 0xa5, sizeof(ctx));
			const struct ccmode_gcm *m = mode[desc][0], *op = mode[caller][0];
			result("state init", 0, m->init(m, ctx, 16, zero));
			result("aad before IV", -68, op->aad(ctx, 0, NULL));
			result("update before IV", -68, op->gcm(ctx, 0, NULL, NULL));
			result("final before IV", -68, op->finalize(ctx, 16, tag));
			result("empty IV", -68, op->set_iv(ctx, 0, zero));
			result("null IV", -68, op->set_iv(ctx, 12, NULL));
			result("good IV", 0, op->set_iv(ctx, 12, zero));
			result("second IV", -68, op->set_iv(ctx, 12, zero));
			uint64_t limit = UINT64_C(0xfffffffe0);
			memcpy(ctx + 96, &limit, 8);
			result("text limit", -67, op->gcm(ctx, 1, zero, cipher));
			limit = UINT64_MAX;
			memcpy(ctx + 96, &limit, 8);
			result("length overflow", -67, op->gcm(ctx, 1, zero, cipher));
		}
	for (int caller = 0; caller < 2; caller++)
		for (int desc = 0; desc < 2; desc++) {
			unsigned char data[32], mac[32];
			memset(data, 0, 16);
			memset(data + 16, 0x5a, 16);
			memset(mac, 0x7b, 32);
			result("in-place encrypt", 0,
			    once[caller](mode[desc][0], 16, zero, 12, zero, 0, NULL, 16, data, data,
			        16, mac));
			same("in-place cipher", known_cipher, data, 16);
			result("in-place decrypt", 0,
			    once[caller](mode[desc][1], 16, zero, 12, zero, 0, NULL, 16, data, data,
			        16, mac));
			same("in-place plain", zero, data, 16);
			unsigned char guard[16];
			memset(guard, 0x5a, 16);
			same("in-place guard", guard, data + 16, 16);
		}
	once_fn legacy[2] = {
	    sym(h[0], "ccgcm_one_shot_legacy"), sym(h[1], "ccgcm_one_shot_legacy")};
	for (int null_iv = 0; null_iv < 2; null_iv++) {
		unsigned char ref[32], ref_tag[32];
		memset(ref, 0x5a, 32);
		memset(ref_tag, 0x7b, 32);
		const void *nonce = null_iv ? NULL : zero;
		size_t n = null_iv ? 12 : 0;
		int expected =
		    legacy[0](mode[0][0], 16, zero, n, nonce, 0, NULL, 16, zero, ref, 16, ref_tag);
		for (int caller = 0; caller < 2; caller++)
			for (int desc = 0; desc < 2; desc++) {
				unsigned char out[32], mac[32];
				memset(out, 0x5a, 32);
				memset(mac, 0x7b, 32);
				result("legacy empty IV", expected,
				    legacy[caller](mode[desc][0], 16, zero, n, nonce, 0, NULL, 16,
				        zero, out, 16, mac));
				same("legacy output", ref, out, 32);
				same("legacy tag", ref_tag, mac, 32);
			}
	}
	for (int d = 0; d < 2; d++)
		for (int provider = 0; provider < 2; provider++) {
			const struct ccmode_ecb *(*get)(void) =
			    sym(h[provider], "ccaes_ecb_encrypt_mode");
			const struct ccmode_ecb *e = get();
			struct ccmode_gcm m[2];
			for (int i = 0; i < 2; i++) {
				void (*factory)(struct ccmode_gcm *, const struct ccmode_ecb *) =
				    sym(h[i],
				        d ? "ccmode_factory_gcm_decrypt"
				          : "ccmode_factory_gcm_encrypt");
				factory(m + i, e);
			}
			same("factory descriptor", m, m + 1, 24);
			_Alignas(16) unsigned char ctx[2][768];
			unsigned char out[2][272], mac[2][32];
			memset(ctx, 0xa5, sizeof(ctx));
			memset(out, 0x5a, sizeof(out));
			memset(mac, 0x7b, sizeof(mac));
			for (int i = 0; i < 2; i++) {
				result("factory init", 0, m[i].init(m + i, ctx[i], 24, key));
				result("factory IV", 0, m[i].set_iv(ctx[i], 17, iv));
				result("factory AAD", 0, m[i].aad(ctx[i], 33, auth));
				result("factory crypt", 0, m[i].gcm(ctx[i], 127, input, out[i]));
			}
			state(ctx[0], ctx[1]);
			same("factory output", out[0], out[1], 272);
			result("factory tag result", m[0].finalize(ctx[0], 16, mac[0]),
			    m[1].finalize(ctx[1], 16, mac[1]));
			state(ctx[0], ctx[1]);
			same("factory tag", mac[0], mac[1], 32);
		}
	printf("GCM ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
