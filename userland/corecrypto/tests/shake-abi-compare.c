/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccxof.h"
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
		fputc('\n', stderr);
	}
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
typedef void (*init_fn)(const struct ccxof_info *, void *);
typedef void (*absorb_fn)(const struct ccxof_info *, void *, size_t, const void *);
typedef void (*squeeze_fn)(const struct ccxof_info *, void *, size_t, void *);
typedef void (*one_fn)(size_t, const void *, size_t, void *);
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
	absorb_fn absorb[2];
	squeeze_fn squeeze[2];
	for (int i = 0; i < 2; i++) {
		init[i] = sym(h[i], "ccxof_init");
		absorb[i] = sym(h[i], "ccxof_absorb");
		squeeze[i] = sym(h[i], "ccxof_squeeze");
	}
	if (init[0] == init[1])
		return 2;
	unsigned char input[2048];
	for (size_t i = 0; i < sizeof(input); i++)
		input[i] = i * 7 + 3;
	const size_t lengths[] = {
	    0, 1, 15, 16, 135, 136, 137, 167, 168, 169, 271, 272, 273, 335, 336, 337, 1024, 2048};
	const size_t pieces[] = {0, 1, 17, 135, 136, 137, 167, 168, 169, 511};
	for (int algorithm = 0; algorithm < 2; algorithm++) {
		const struct ccxof_info *di[2];
		one_fn one[2];
		for (int i = 0; i < 2; i++) {
			const struct ccxof_info *(*get)(void) =
			    sym(h[i], algorithm ? "ccshake256_xi" : "ccshake128_xi");
			di[i] = get();
			one[i] = sym(h[i], algorithm ? "ccshake256" : "ccshake128");
		}
		same("descriptor sizes", di[0], di[1], 2 * sizeof(size_t));
		for (size_t l = 0; l < sizeof(lengths) / sizeof(*lengths); l++)
			for (int desc = 0; desc < 2; desc++)
				for (int mix = 0; mix < 8; mix++) {
					_Alignas(16) unsigned char ctx[448], host[448];
					memset(ctx, 0xa5, sizeof(ctx));
					memset(host, 0xa5, sizeof(host));
					init[mix & 1](di[desc], ctx);
					init[0](di[0], host);
					same("init state", ctx, host, sizeof(ctx));
					size_t pos = 0;
					absorb[(mix >> 1) & 1](di[desc], ctx, 0, NULL);
					absorb[0](di[0], host, 0, NULL);
					while (pos < lengths[l]) {
						size_t take = 1 + (pos * 71 + lengths[l]) % 191;
						if (take > lengths[l] - pos)
							take = lengths[l] - pos;
						absorb[(mix >> 1) & 1](
						    di[desc], ctx, take, input + pos);
						absorb[0](di[0], host, take, input + pos);
						pos += take;
						same("absorb state/guards", ctx, host, sizeof(ctx));
					}
					for (size_t p = 0; p < sizeof(pieces) / sizeof(*pieces);
					    p++) {
						unsigned char out[2][544];
						memset(out, 0xa5, sizeof(out));
						squeeze[(mix >> 2) & 1](
						    di[desc], ctx, pieces[p], out[1] + 8);
						squeeze[0](di[0], host, pieces[p], out[0] + 8);
						same("squeeze bytes/guards", out[0], out[1],
						    sizeof(out[0]));
						same(
						    "squeeze state/guards", ctx, host, sizeof(ctx));
					}
				}
		for (size_t a = 0; a < sizeof(lengths) / sizeof(*lengths); a++)
			for (size_t b = 0; b < sizeof(lengths) / sizeof(*lengths); b++) {
				unsigned char out[2][2080];
				memset(out, 0xa5, sizeof(out));
				for (int i = 0; i < 2; i++)
					one[i](lengths[a], input, lengths[b], out[i] + 8);
				same("one shot bytes/guards", out[0], out[1], sizeof(out[0]));
			}
		/* Callback arguments and state are public parts of the descriptor. */
		for (size_t blocks = 0; blocks < 4; blocks++)
			for (size_t last = 0; last < di[0]->block_size; last++) {
				_Alignas(16) unsigned char state[2][224];
				memset(state, 0xa5, sizeof(state));
				for (int i = 0; i < 2; i++) {
					di[i]->init(di[i], state[i]);
					di[i]->absorb(di[i], state[i], blocks, input);
					di[i]->absorb_last(di[i], state[i], last, input + 600);
				}
				same(
				    "callbacks absorb state", state[0], state[1], sizeof(state[0]));
				for (size_t n = 0; n < 400; n += 53) {
					unsigned char out[2][448];
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++)
						di[i]->squeeze(di[i], state[i], n, out[i] + 8);
					same("callback squeeze output", out[0], out[1],
					    sizeof(out[0]));
					same("callback squeeze state", state[0], state[1],
					    sizeof(state[0]));
				}
			}
	}
	printf("SHAKE ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
