/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccdigest.h"
#include "../abi/ccrng.h"
#include <dlfcn.h>
#include <os/lock.h>
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
struct api {
	int (*init)(void *, const struct ccdigest_info *, unsigned);
	int (*seed)(void *, size_t, void *);
	int (*add)(void *, unsigned, size_t, const void *, bool *);
	int (*reset)(void *);
	int (*rng)(void *, struct ccrng_state *);
	int (*list)(void *, size_t, void **);
	int (*lock)(void *, void *, os_unfair_lock_t);
};
static int generate(struct ccrng_state *r, size_t n, void *out)
{
	(void)r;
	memset(out, 0x42, n);
	return 0;
}
int main(int argc, char **argv)
{
	CHECK(argc == 2);
	void *lib[2] = {dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW | RTLD_LOCAL),
	    dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)};
	CHECK(lib[0] && lib[1]);
	struct api a[2];
	for (int j = 0; j < 2; j++) {
		a[j] = (struct api){dlsym(lib[j], "ccentropy_digest_init"),
		    dlsym(lib[j], "ccentropy_get_seed"), dlsym(lib[j], "ccentropy_add_entropy"),
		    dlsym(lib[j], "ccentropy_reset"), dlsym(lib[j], "ccentropy_rng_init"),
		    dlsym(lib[j], "ccentropy_list_init"), dlsym(lib[j], "ccentropy_lock_init")};
		Dl_info info;
		CHECK(dladdr((void *)a[j].init, &info));
		if (j)
			CHECK(strstr(info.dli_fname, argv[1]));
	}
	const char *digests[] = {"ccsha1_di", "ccsha256_di", "ccsha512_di"};
	unsigned char input[160];
	for (size_t i = 0; i < 160; i++)
		input[i] = i * 13;
	for (size_t d = 0; d < 3; d++) {
		const struct ccdigest_info *di =
		    ((const struct ccdigest_info *(*)(void))dlsym(lib[0], digests[d]))();
		for (size_t n = 0; n <= di->output_size + 1; n++)
			for (unsigned need = 0; need < 64; need += 7) {
				_Alignas(16) unsigned char c[2][400], out[2][80];
				memset(c, 0xa5, sizeof(c));
				memset(out, 0xc5, sizeof(out));
				for (int j = 0; j < 2; j++) {
					CHECK(!a[j].init(c[j], di, need));
					CHECK(a[j].seed(c[j], n, out[j]) ==
					    (n > di->output_size ? -5
					            : need       ? -10
					                         : 0));
				}
				CHECK(!memcmp(c[0] + 8, c[1] + 8, 392));
				CHECK(!memcmp(out[0], out[1], 80));
				for (int turn = 0; turn < 5; turn++) {
					bool ready[2];
					for (int j = 0; j < 2; j++) {
						CHECK(
						    !a[1 - j].add(c[j], turn == 4 ? UINT32_MAX : 17,
						        turn * 31, input, &ready[j]));
					}
					CHECK(ready[0] == ready[1]);
					CHECK(!memcmp(c[0] + 8, c[1] + 8, 392));
					int r[2];
					for (int j = 0; j < 2; j++)
						r[j] = a[1 - j].seed(c[j], n, out[j]);
					CHECK(r[0] == r[1]);
					CHECK(!memcmp(out[0], out[1], 80));
					CHECK(!memcmp(c[0] + 8, c[1] + 8, 392));
				}
				for (int j = 0; j < 2; j++)
					CHECK(!a[j].reset(c[j]));
				CHECK(!memcmp(c[0] + 8, c[1] + 8, 392));
			}
	}
	for (int j = 0; j < 2; j++) {
		unsigned char c[400], r[32], list[32], locked[32], out[32];
		struct ccrng_state rng = {generate};
		const struct ccdigest_info *di =
		    ((const struct ccdigest_info *(*)(void))dlsym(lib[0], "ccsha256_di"))();
		CHECK(!a[j].init(c, di, 50));
		CHECK(!a[j].rng(r, &rng));
		void *sources[] = {c, r};
		CHECK(!a[j].list(list, 2, sources));
		CHECK(!a[1 - j].seed(list, 32, out));
		for (size_t i = 0; i < 32; i++)
			CHECK(out[i] == 0x42);
		bool ready = true;
		CHECK(a[j].add(list, 4, 3, input, &ready) == -173 && !ready);
		CHECK(a[j].reset(list) == -173);
		CHECK(!a[j].list(list, 0, sources));
		memset(out, 0xa5, 32);
		CHECK(a[j].seed(list, 32, out) == -1);
		for (size_t i = 0; i < 32; i++)
			CHECK(!out[i]);
		os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
		CHECK(!a[j].lock(locked, c, &lock));
		CHECK(!a[1 - j].add(locked, 50, 12, input, &ready) && ready);
		CHECK(!a[1 - j].seed(locked, 32, out));
		CHECK(!a[1 - j].reset(locked));
	}
	puts(
	    "Entropy: digest state, thresholds, saturation, mixed calls, source lists, locks and errors match");
	return 0;
}
