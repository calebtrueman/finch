/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks, failures;
static void same(const char *n, const void *a, const void *b, size_t z)
{
	checks++;
	if (memcmp(a, b, z) && failures++ < 12)
		fprintf(stderr, "%s differs\n", n);
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
int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	void *h[2] = {
	    dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL | RTLD_FIRST),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST)};
	if (!h[0] || !h[1])
		return 2;
	typedef int (*once_fn)(const struct ccmode_xts *, size_t, const void *, const void *,
	    const void *, size_t, const void *, void *);
	once_fn once[2] = {sym(h[0], "ccxts_one_shot"), sym(h[1], "ccxts_one_shot")};
	if (once[0] == once[1])
		return 2;
	unsigned char key[256], tkey[256], iv[16], input[1040];
	for (size_t i = 0; i < 256; i++) {
		key[i] = (unsigned char)(i * 17 + 3);
		tkey[i] = (unsigned char)(i * 31 + 9);
	}
	for (size_t i = 0; i < 16; i++)
		iv[i] = (unsigned char)(i * 5 + 3);
	for (size_t i = 0; i < 1040; i++)
		input[i] = (unsigned char)(i * 67 + 7);
	const size_t keys[] = {16, 24, 32, 128, 192, 256}, counts[] = {0, 1, 2, 7, 16, 65};
	for (int direction = 0; direction < 2; direction++) {
		const struct ccmode_xts *(*get[2])(void) = {
		    sym(h[0], direction ? "ccaes_xts_decrypt_mode" : "ccaes_xts_encrypt_mode"),
		    sym(h[1], direction ? "ccaes_xts_decrypt_mode" : "ccaes_xts_encrypt_mode")};
		const struct ccmode_xts *m[2] = {get[0](), get[1]()};
		same("descriptor sizes", m[0], m[1], 24);
		same(
		    "implementation", &m[0]->implementation, &m[1]->implementation, sizeof(size_t));
		for (size_t k = 0; k < 6; k++)
			for (int equal = 0; equal < 2; equal++) {
				_Alignas(16) unsigned char ctx[2][544];
				memset(ctx, 0xa5, sizeof(ctx));
				int r[2];
				for (int i = 0; i < 2; i++)
					r[i] = m[i]->init(
					    m[i], ctx[i], keys[k], key, equal ? key : tkey);
				result("key result", r[0], r[1]);
				same("key state and guard", ctx[0] + 16, ctx[1] + 16, 528);
				for (size_t n = 0; n < 6; n++) {
					unsigned char reference[1056], out[1056];
					memset(reference, 0x5a, sizeof(reference));
					int expected = once[0](m[0], keys[k], key,
					    equal ? key : tkey, iv, counts[n], input, reference);
					for (int caller = 0; caller < 2; caller++)
						for (int desc = 0; desc < 2; desc++) {
							memset(out, 0x5a, sizeof(out));
							result("one shot", expected,
							    once[caller](m[desc], keys[k], key,
							        equal ? key : tkey, iv, counts[n],
							        input, out));
							same("one shot output", reference, out,
							    sizeof(out));
						}
					if (r[0])
						continue;
					for (int caller = 0; caller < 2; caller++)
						for (int context = 0; context < 2; context++)
							for (int inplace = 0; inplace < 2;
							    inplace++) {
								_Alignas(
								    16) unsigned char tweak[48],
								    ref_tweak[48];
								memset(tweak, 0xa5, sizeof(tweak));
								memset(ref_tweak, 0xa5,
								    sizeof(ref_tweak));
								result("set tweak", 0,
								    m[caller]->set_tweak(
								        ctx[context], tweak, iv));
								m[0]->set_tweak(
								    ctx[0], ref_tweak, iv);
								same("tweak state", ref_tweak,
								    tweak, 48);
								memset(out, 0x5a, sizeof(out));
								if (inplace)
									memcpy(out, input,
									    sizeof(input));
								m[0]->xts(ctx[0], ref_tweak,
								    counts[n], input, out);
								if (inplace)
									memcpy(out, input,
									    sizeof(input));
								else
									memset(
									    out, 0x5a, sizeof(out));
								size_t first = counts[n] / 2;
								void *p = m[caller]->xts(
								    ctx[context], tweak, first,
								    inplace ? out : input, out);
								checks++;
								if (p != tweak + 8)
									failures++;
								p = m[1 - caller]->xts(ctx[context],
								    tweak, counts[n] - first,
								    (inplace ? out : input) +
								        16 * first,
								    out + 16 * first);
								checks++;
								if (p != tweak + 8)
									failures++;
								same("split result", reference, out,
								    counts[n] * 16);
								same("split tweak and guard",
								    ref_tweak, tweak, 48);
							}
				}
				if (!r[0])
					for (int caller = 0; caller < 2; caller++) {
						_Alignas(16) unsigned char tweak[48], before[48],
						    out[32];
						memset(tweak, 0xa5, 48);
						memset(out, 0x5a, 32);
						m[caller]->set_tweak(ctx[caller], tweak, iv);
						uint64_t blocks = 1048576;
						memcpy(tweak, &blocks, 8);
						memcpy(before, tweak, 48);
						checks++;
						if (m[caller]->xts(
						        ctx[caller], tweak, 1, input, out) != NULL)
							failures++;
						same("limit unchanged", before, tweak, 48);
						unsigned char untouched[32];
						memset(untouched, 0x5a, 32);
						same("limit output", untouched, out, 32);
					}
			}
		for (int provider = 0; provider < 2; provider++) {
			struct ccmode_xts generated[2];
			for (int i = 0; i < 2; i++) {
				void (*factory)(struct ccmode_xts *, const struct ccmode_ecb *,
				    const struct ccmode_ecb *) = sym(h[i],
				    direction ? "ccmode_factory_xts_decrypt"
				              : "ccmode_factory_xts_encrypt");
				factory(
				    generated + i, m[provider]->custom, m[provider]->custom_tweak);
			}
			same("factory sizes", generated, generated + 1, 24);
			same("factory tail", &generated[0].custom, &generated[1].custom, 24);
			unsigned char out[2][1056];
			memset(out, 0x5a, sizeof(out));
			for (int i = 0; i < 2; i++)
				result("factory crypt", 0,
				    once[i](generated + i, 32, key, tkey, iv, 65, input, out[i]));
			same("factory output", out[0], out[1], 1056);
		}
	}
	printf("XTS ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
