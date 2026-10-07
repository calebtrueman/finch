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
	if (memcmp(a, b, n) && failures++ < 12)
		fprintf(stderr, "%s differs\n", name);
}
static void result(const char *name, int a, int b)
{
	same(name, &a, &b, sizeof(a));
}
static void *sym(void *h, const char *name)
{
	void *p = dlsym(h, name);
	if (!p) {
		fprintf(stderr, "%s: %s\n", name, dlerror());
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
	typedef int (*once_fn)(const struct ccmode_cbc *, size_t, const void *, const void *,
	    size_t, const void *, void *);
	once_fn once[2] = {sym(h[0], "cccbc_one_shot"), sym(h[1], "cccbc_one_shot")};
	if (once[0] == once[1])
		return 2;
	unsigned char key[256], input[256], initial[16];
	for (size_t i = 0; i < 256; i++) {
		key[i] = (unsigned char)i;
		input[i] = (unsigned char)(i * 71 + 5);
	}
	for (size_t i = 0; i < 16; i++)
		initial[i] = (unsigned char)(i * 11);
	const size_t lengths[] = {0, 1, 15, 16, 17, 24, 32, 33, 128, 192, 256};
	const size_t counts[] = {0, 1, 2, 7, 16};
	const char *names[] = {"ccaes_cbc_encrypt_mode", "ccaes_cbc_decrypt_mode"};
	for (int d = 0; d < 2; d++) {
		const struct ccmode_cbc *(*get[2])(void) = {
		    sym(h[0], names[d]), sym(h[1], names[d])};
		const struct ccmode_cbc *m[2] = {get[0](), get[1]()};
		same("sizes", m[0], m[1], 16);
		for (size_t k = 0; k < sizeof(lengths) / sizeof(*lengths); k++) {
			_Alignas(16) unsigned char ctx[2][272];
			int r[2];
			memset(ctx, 0xa5, sizeof(ctx));
			for (int i = 0; i < 2; i++)
				r[i] = m[i]->init(m[i], ctx[i], lengths[k], key);
			result("init", r[0], r[1]);
			same("context and guard", ctx[0], ctx[1], 272);
			for (size_t c = 0; c < sizeof(counts) / sizeof(*counts); c++)
				for (int zero = 0; zero < 2; zero++) {
					unsigned char reference[272], out[272], iv[32],
					    expected_iv[32];
					const void *start = zero ? NULL : initial;
					memset(reference, 0x5a, sizeof(reference));
					int ref = once[0](m[0], lengths[k], key, start, counts[c],
					    input, reference);
					for (int caller = 0; caller < 2; caller++)
						for (int desc = 0; desc < 2; desc++) {
							memset(out, 0x5a, sizeof(out));
							int actual =
							    once[caller](m[desc], lengths[k], key,
							        start, counts[c], input, out);
							/* The host's AES callback leaves its return register
                     * unchanged for zero blocks. Check output in that case;
                     * its return value depends on the temporary context address. */
							if (counts[c] || r[0])
								result("one shot", ref, actual);
							same("one shot bytes", reference, out,
							    sizeof(out));
						}
					if (r[0])
						continue;
					memset(expected_iv, 0x6b, sizeof(expected_iv));
					if (start)
						memcpy(expected_iv, start, 16);
					else
						memset(expected_iv, 0, 16);
					m[0]->cbc(ctx[0], expected_iv, counts[c], input, out);
					for (int caller = 0; caller < 2; caller++)
						for (int context = 0; context < 2; context++)
							for (int inplace = 0; inplace < 2;
							    inplace++) {
								memset(iv, 0x6b, sizeof(iv));
								if (start)
									memcpy(iv, start, 16);
								else
									memset(iv, 0, 16);
								memset(out, 0x5a, sizeof(out));
								if (inplace)
									memcpy(out, input,
									    sizeof(input));
								const unsigned char *in =
								    inplace ? out : input;
								for (size_t b = 0; b < counts[c];
								    b++)
									result("split block", 0,
									    m[caller]->cbc(
									        ctx[context], iv, 1,
									        in + 16 * b,
									        out + 16 * b));
								same("split bytes", reference, out,
								    counts[c] * 16);
								same("chain and guard", expected_iv,
								    iv, sizeof(iv));
							}
				}
		}
	}
	/* Share one ECB descriptor to make pointer bytes comparable as well. */
	for (int direction = 0; direction < 2; direction++)
		for (int provider = 0; provider < 2; provider++) {
			const struct ccmode_ecb *(*get)(void) = sym(h[provider],
			    direction ? "ccaes_ecb_decrypt_mode" : "ccaes_ecb_encrypt_mode");
			const struct ccmode_ecb *e = get();
			struct ccmode_cbc m[2];
			for (int i = 0; i < 2; i++) {
				void (*factory)(struct ccmode_cbc *, const struct ccmode_ecb *) =
				    sym(h[i],
				        direction ? "ccmode_factory_cbc_decrypt"
				                  : "ccmode_factory_cbc_encrypt");
				factory(&m[i], e);
			}
			same("factory sizes", m, m + 1, 16);
			_Alignas(16) unsigned char ctx[2][288];
			memset(ctx, 0xa5, sizeof(ctx));
			for (int i = 0; i < 2; i++)
				result("factory init", 0, m[i].init(&m[i], ctx[i], 32, key));
			same("factory context", ctx[0], ctx[1], sizeof(ctx[0]));
			unsigned char reference[272], refiv[32];
			memset(reference, 0x5a, sizeof(reference));
			memset(refiv, 0x6b, sizeof(refiv));
			memcpy(refiv, initial, 16);
			result(
			    "factory reference", 0, m[0].cbc(ctx[0], refiv, 16, input, reference));
			for (int caller = 0; caller < 2; caller++)
				for (int context = 0; context < 2; context++)
					for (int inplace = 0; inplace < 2; inplace++) {
						unsigned char out[272], iv[32];
						memset(out, 0x5a, sizeof(out));
						memset(iv, 0x6b, sizeof(iv));
						memcpy(iv, initial, 16);
						if (inplace)
							memcpy(out, input, sizeof(input));
						result("factory mixed", 0,
						    m[caller].cbc(ctx[context], iv, 16,
						        inplace ? out : input, out));
						same("factory output", reference, out, sizeof(out));
						same("factory IV", refiv, iv, sizeof(iv));
					}
		}
	printf("CBC ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
