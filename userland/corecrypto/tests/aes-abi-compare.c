/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Compare key bytes and encrypted/decrypted blocks, including contexts
 * created by one library and used by the other.
 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
static void same(const char *name, const void *a, const void *b, size_t n)
{
	checks++;
	if (memcmp(a, b, n)) {
		if (failures++ < 12)
			fprintf(stderr, "%s differs\n", name);
	}
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
	if (!h[0] || !h[1]) {
		fprintf(stderr, "%s\n", dlerror());
		return 2;
	}
	typedef int (*once_fn)(
	    const struct ccmode_ecb *, size_t, const void *, size_t, const void *, void *);
	once_fn once[2] = {sym(h[0], "ccecb_one_shot"), sym(h[1], "ccecb_one_shot")};
	if (once[0] == once[1])
		return 2;
	const char *names[] = {"ccaes_ecb_encrypt_mode", "ccaes_ecb_decrypt_mode"};
	const size_t keys[] = {0, 1, 15, 16, 17, 23, 24, 25, 31, 32, 33, 128, 192, 256};
	const size_t counts[] = {0, 1, 2, 7, 16};
	unsigned char key[256], input[256];
	for (size_t i = 0; i < sizeof(key); i++) {
		key[i] = (unsigned char)i;
		input[i] = (unsigned char)(i * 67 + 19);
	}
	for (int direction = 0; direction < 2; direction++) {
		const struct ccmode_ecb *(*get[2])(void) = {
		    sym(h[0], names[direction]), sym(h[1], names[direction])};
		const struct ccmode_ecb *mode[2] = {get[0](), get[1]()};
		same("mode sizes", mode[0], mode[1], 2 * sizeof(size_t));
		for (size_t k = 0; k < sizeof(keys) / sizeof(*keys); k++) {
			_Alignas(16) unsigned char ctx[2][256];
			memset(ctx, 0xa5, sizeof(ctx));
			int r[2];
			for (int i = 0; i < 2; i++)
				r[i] = mode[i]->init(mode[i], ctx[i], keys[k], key);
			result("key result", r[0], r[1]);
			if (memcmp(ctx[0], ctx[1], sizeof(ctx[0]))) {
				fprintf(stderr, "%s key length %zu:", names[direction], keys[k]);
				for (size_t p = 0; p < sizeof(ctx[0]); p++)
					if (ctx[0][p] != ctx[1][p])
						fprintf(stderr, " %zu:%02x/%02x", p, ctx[0][p],
						    ctx[1][p]);
				fputc('\n', stderr);
			}
			same("key bytes and guard", ctx[0], ctx[1], sizeof(ctx[0]));
			for (size_t c = 0; c < sizeof(counts) / sizeof(*counts); c++) {
				unsigned char reference[272], out[272];
				memset(reference, 0x5a, sizeof(reference));
				int reference_result =
				    once[0](mode[0], keys[k], key, counts[c], input, reference);
				for (int caller = 0; caller < 2; caller++) {
					for (int descriptor = 0; descriptor < 2; descriptor++) {
						memset(out, 0x5a, sizeof(out));
						int current = once[caller](mode[descriptor],
						    keys[k], key, counts[c], input, out);
						result(
						    "one-shot result", reference_result, current);
						same("one-shot bytes and guard", reference, out,
						    sizeof(out));
					}
				}
				if (r[0])
					continue;
				for (int caller = 0; caller < 2; caller++) {
					for (int context = 0; context < 2; context++) {
						memset(out, 0x5a, sizeof(out));
						result("mixed blocks", 0,
						    mode[caller]->ecb(
						        ctx[context], counts[c], input, out));
						same("mixed blocks and guard", reference, out,
						    sizeof(out));
						memcpy(out, input, sizeof(input));
						result("in-place blocks", 0,
						    mode[caller]->ecb(
						        ctx[context], counts[c], out, out));
						same("in-place output", reference, out,
						    counts[c] * 16);
					}
				}
			}
		}
	}
	printf("AES ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
