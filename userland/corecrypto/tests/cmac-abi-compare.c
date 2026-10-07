/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks, failures;
static void same(const char *name, const void *a, const void *b, size_t n)
{
	checks++;
	if (memcmp(a, b, n) && failures++ < 12) {
		fprintf(stderr, "%s differs", name);
		for (size_t i = 0; i < n; i++)
			if (((const unsigned char *)a)[i] != ((const unsigned char *)b)[i]) {
				fprintf(stderr, " at %zu (%02x/%02x)", i,
				    ((const unsigned char *)a)[i], ((const unsigned char *)b)[i]);
				break;
			}
		fprintf(stderr, "\n");
	}
}
static void result(const char *n, int a, int b)
{
	same(n, &a, &b, sizeof(a));
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
typedef int (*init_fn)(const struct ccmode_cbc *, void *, size_t, const void *);
typedef int (*update_fn)(void *, size_t, const void *);
typedef int (*final_fn)(void *, size_t, void *);
typedef int (*oneshot_fn)(
    const struct ccmode_cbc *, size_t, const void *, size_t, const void *, size_t, void *);
int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	void *h[2] = {
	    dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL | RTLD_FIRST),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST)};
	if (!h[0] || !h[1])
		return 2;
	init_fn init[2];
	update_fn update[2];
	final_fn final[2], verify[2];
	oneshot_fn one[2], oneverify[2];
	for (int i = 0; i < 2; i++) {
		init[i] = sym(h[i], "cccmac_init");
		update[i] = sym(h[i], "cccmac_update");
		final[i] = sym(h[i], "cccmac_final_generate");
		verify[i] = sym(h[i], "cccmac_final_verify");
		one[i] = sym(h[i], "cccmac_one_shot_generate");
		oneverify[i] = sym(h[i], "cccmac_one_shot_verify");
	}
	if (init[0] == init[1])
		return 2;
	unsigned char key[64], input[600];
	for (size_t i = 0; i < 64; i++)
		key[i] = i * 7;
	for (size_t i = 0; i < 600; i++)
		input[i] = i * 13 + 5;
	const size_t keys[] = {0, 15, 16, 24, 32, 33, 128},
	             lengths[] = {0, 1, 15, 16, 17, 31, 32, 33, 63, 127, 256, 511, 600};
	for (int provider = 0; provider < 2; provider++) {
		const struct ccmode_cbc *(*get)(void) = sym(h[provider], "ccaes_cbc_encrypt_mode");
		const struct ccmode_cbc *cbc = get();
		for (size_t k = 0; k < sizeof(keys) / sizeof(*keys); k++)
			for (size_t n = 0; n < sizeof(lengths) / sizeof(*lengths); n++)
				for (size_t tag = 0; tag <= 17; tag++) {
					_Alignas(16) unsigned char ctx[2][640];
					unsigned char out[2][48];
					int r[2];
					memset(ctx, 0xa5, sizeof(ctx));
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++)
						r[i] = init[i](cbc, ctx[i], keys[k], key);
					result("init result", r[0], r[1]);
					same("init state/guards", ctx[0], ctx[1], 640);
					if (r[0])
						continue;
					size_t first = lengths[n] / 2;
					for (int i = 0; i < 2; i++)
						r[i] = update[i](ctx[i], first, input);
					result("update result", r[0], r[1]);
					same("update state/guards", ctx[0], ctx[1], 640);
					/* Continue each saved state with the other implementation. */
					for (int i = 0; i < 2; i++)
						r[i] = update[1 - i](
						    ctx[i], lengths[n] - first, input + first);
					result("mixed update result", r[0], r[1]);
					same("mixed update state/guards", ctx[0], ctx[1], 640);
					for (int i = 0; i < 2; i++)
						r[i] = final[i](ctx[i], tag, out[i] + 8);
					result("final result", r[0], r[1]);
					same("final bytes/guards", out[0], out[1], 48);
					same("cleared state/guards", ctx[0], ctx[1], 640);
					unsigned char saved[48];
					memcpy(saved, out[0], 48);
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++)
						r[i] = one[i](cbc, keys[k], key, lengths[n], input,
						    tag, out[i] + 8);
					result("one shot result", r[0], r[1]);
					same("one shot bytes/guards", out[0], out[1], 48);
					same("split equals one shot", out[1], saved, 48);
					if (tag > 16)
						continue;
					for (int altered = 0; altered < 2; altered++) {
						unsigned char mac[16];
						memcpy(mac, out[0] + 8, 16);
						if (altered && tag)
							mac[tag - 1] ^= 1;
						for (int i = 0; i < 2; i++)
							r[i] = oneverify[i](cbc, keys[k], key,
							    lengths[n], input, tag, mac);
						result("one shot verify", r[0], r[1]);
						memset(ctx, 0xa5, sizeof(ctx));
						for (int i = 0; i < 2; i++) {
							init[i](cbc, ctx[i], keys[k], key);
							update[i](ctx[i], lengths[n], input);
							r[i] = verify[1 - i](ctx[i], tag, mac);
						}
						result("mixed verify", r[0], r[1]);
						same("verify clears state", ctx[0], ctx[1], 640);
					}
				}
		_Alignas(16) unsigned char ctx[2][640];
		memset(ctx, 0xa5, sizeof(ctx));
		for (int i = 0; i < 2; i++) {
			init[i](cbc, ctx[i], 16, key);
			result("NULL update", 0, update[i](ctx[i], 9, NULL));
		}
		same("NULL update state", ctx[0], ctx[1], 640);
	}
	for (int provider = 0; provider < 2; provider++) {
		const struct ccmode_cbc *(*get)(void) = sym(h[provider], "ccaes_cbc_encrypt_mode");
		const struct ccmode_cbc *cbc = get();
		typedef int (*fixed_fn)(const struct ccmode_cbc *, unsigned, size_t, const void *,
		    size_t, const void *, size_t, void *);
		typedef int (*derive_fn)(const struct ccmode_cbc *, unsigned, size_t, const void *,
		    size_t, const void *, size_t, const void *, size_t, size_t, void *);
		fixed_fn fixed[2];
		derive_fn derive[2];
		for (int i = 0; i < 2; i++) {
			fixed[i] = sym(h[i], "ccnistkdf_ctr_cmac_fixed");
			derive[i] = sym(h[i], "ccnistkdf_ctr_cmac");
		}
		const unsigned widths[] = {0, 1, 7, 8, 16, 24, 31, 32, 33, 64};
		for (size_t w = 0; w < 10; w++)
			for (size_t k = 16; k <= 32; k += 8)
				for (size_t n = 0; n < sizeof(lengths) / sizeof(*lengths); n++) {
					unsigned char out[2][640];
					int r[2];
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++)
						r[i] = fixed[i](cbc, widths[w], k, key, 19, input,
						    lengths[n], out[i] + 8);
					result("CMAC KDF fixed result", r[0], r[1]);
					same("CMAC KDF fixed bytes/guards", out[0], out[1], 640);
					for (size_t lenbytes = 0; lenbytes <= 5; lenbytes++) {
						memset(out, 0xa5, sizeof(out));
						for (int i = 0; i < 2; i++)
							r[i] = derive[i](cbc, widths[w], k, key, 19,
							    input, 23, input + 19, lengths[n],
							    lenbytes, out[i] + 8);
						result("CMAC KDF result", r[0], r[1]);
						same("CMAC KDF bytes/guards", out[0], out[1], 640);
					}
				}
		for (size_t n = 4079; n <= 4081; n++) {
			unsigned char out[2][4112];
			int r[2];
			memset(out, 0xa5, sizeof(out));
			for (int i = 0; i < 2; i++)
				r[i] = fixed[i](cbc, 8, 16, key, 19, input, n, out[i] + 8);
			result("CMAC KDF counter limit", r[0], r[1]);
			same("CMAC KDF counter limit guards", out[0], out[1], 4112);
		}
	}
	/* RFC 4493 section 4: independent published examples. */
	const unsigned char vector_key[] = {0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab,
	    0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c};
	const unsigned char vector_input[] = {0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9,
	    0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a, 0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac,
	    0x9c, 0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51, 0x30, 0xc8, 0x1c, 0x46, 0xa3,
	    0x5c, 0xe4, 0x11, 0xe5, 0xfb, 0xc1, 0x19, 0x1a, 0x0a, 0x52, 0xef, 0xf6, 0x9f, 0x24,
	    0x45, 0xdf, 0x4f, 0x9b, 0x17, 0xad, 0x2b, 0x41, 0x7b, 0xe6, 0x6c, 0x37, 0x10};
	const unsigned char tags[] = {0xbb, 0x1d, 0x69, 0x29, 0xe9, 0x59, 0x37, 0x28, 0x7f, 0xa3,
	    0x7d, 0x12, 0x9b, 0x75, 0x67, 0x46, 0x07, 0x0a, 0x16, 0xb4, 0x6b, 0x4d, 0x41, 0x44,
	    0xf7, 0x9b, 0xdd, 0x9d, 0xd0, 0x4a, 0x28, 0x7c, 0xdf, 0xa6, 0x67, 0x47, 0xde, 0x9a,
	    0xe6, 0x30, 0x30, 0xca, 0x32, 0x61, 0x14, 0x97, 0xc8, 0x27, 0x51, 0xf0, 0xbe, 0xbf,
	    0x7e, 0x3b, 0x9d, 0x92, 0xfc, 0x49, 0x74, 0x17, 0x79, 0x36, 0x3c, 0xfe};
	const size_t vector_lengths[] = {0, 16, 40, 64};
	const struct ccmode_cbc *(*get_vector)(void) = sym(h[1], "ccaes_cbc_encrypt_mode");
	for (size_t i = 0; i < 4; i++) {
		unsigned char tag[16];
		result("CMAC RFC result", 0,
		    one[1](get_vector(), 16, vector_key, vector_lengths[i], vector_input, 16, tag));
		same("CMAC RFC tag", tag, tags + i * 16, 16);
	}
	printf("CMAC ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
