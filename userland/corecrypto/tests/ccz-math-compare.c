/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccz.h"
#include "../abi/ccrng.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks, failures;
static const char *operation;
static void same(const char *n, const void *a, const void *b, size_t z)
{
	checks++;
	if (memcmp(a, b, z) && failures++ < 30)
		fprintf(stderr, "%s: %s differs\n", operation, n);
}
static void num(const char *n, uint64_t a, uint64_t b)
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
#define ALL(X)                                                                                     \
	X(init)                                                                                    \
	X(free) X(seti) X(set_sign) X(set) X(read_uint) X(add) X(sub) X(mul) X(addi) X(subi)       \
	    X(muli) X(lsl) X(lsr) X(divmod) X(mod) X(mulmod) X(expmod) X(is_prime) X(random_bits)
#define FIELD(n) __typeof__(&ccz_##n) fn_##n;
struct api {
	ALL(FIELD)
};
static void *allocate(void *c, size_t n)
{
	(void)c;
	void *p = malloc(n + 16);
	if (!p)
		abort();
	memset(p, 0xa5, n + 16);
	return p;
}
static void *reallocate(void *c, size_t old, void *p, size_t n)
{
	(void)c;
	p = realloc(p, n + 16);
	if (!p)
		abort();
	if (n > old)
		memset((unsigned char *)p + old, 0xa5, n + 16 - old);
	return p;
}
static void deallocate(void *c, size_t n, void *p)
{
	(void)c;
	unsigned char *guard = (unsigned char *)p + n * 8;
	for (int i = 0; i < 16; i++)
		if (guard[i] != 0xa5) {
			fprintf(stderr, "allocation guard changed\n");
			exit(3);
		}
	free(p);
}
static const struct ccz_class cls = {NULL, allocate, reallocate, deallocate};
static void compare(struct ccz *a, struct ccz *b, int allbytes)
{
	struct ccz x = *a, y = *b;
	x.isa = y.isa = NULL;
	x.units = y.units = NULL;
	same("context", &x, &y, sizeof(x));
	if (a->n == b->n && a->n)
		same("value", a->units, b->units, a->n * 8);
	size_t ca = a->capacity < 0 ? -(int64_t)a->capacity : a->capacity,
	       cb = b->capacity < 0 ? -(int64_t)b->capacity : b->capacity;
	if (allbytes && ca == cb && a->units && b->units)
		same("saved bytes", a->units, b->units, ca * 8);
}
static void initialize(struct api *f, struct ccz *z, size_t na, size_t nb, int signs)
{
	unsigned char input[256];
	for (size_t i = 0; i < sizeof(input); i++)
		input[i] = (unsigned char)(i * 39 + na * 7 + nb);
	memset(z, 0x5a, sizeof(*z) * 4);
	for (int j = 0; j < 4; j++)
		f->fn_init(&cls, z + j);
	f->fn_read_uint(z, na, input);
	input[0] ^= 0x71;
	f->fn_read_uint(z + 1, nb, input);
	f->fn_set_sign(z, (signs & 1) ? -1 : 1);
	f->fn_set_sign(z + 1, (signs & 2) ? -1 : 1);
	f->fn_seti(z + 2, 17);
	f->fn_seti(z + 3, 19);
}
struct mockrng {
	struct ccrng_state base;
	size_t size;
	int error;
};
static int generate(struct ccrng_state *r, size_t n, void *out)
{
	struct mockrng *m = (void *)r;
	m->size = n;
	if (!m->error)
		for (size_t i = 0; i < n; i++)
			((unsigned char *)out)[i] = (unsigned char)(i * 31 + 0xf7);
	return m->error;
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
	struct api f[2];
	for (int i = 0; i < 2; i++) {
#define LOAD(n) f[i].fn_##n = sym(h[i], "ccz_" #n);
		ALL(LOAD)
	}
	const size_t lengths[] = {0, 1, 7, 8, 9, 16, 31, 32, 64, 127};
	for (size_t a = 0; a < 10; a++)
		for (size_t b = 0; b < 10; b++)
			for (int signs = 0; signs < 4; signs++)
				for (int alias = 0; alias < 3; alias++)
					for (int op = 0; op < 7; op++) {
						struct ccz z[2][4];
						int dest = alias ? alias - 1 : 2;
						operation = (const char *[]){"add", "sub", "mul",
						    "mod", "divmod", "mulmod", "expmod"}[op];
						int result[2] = {0};
						for (int i = 0; i < 2; i++) {
							initialize(f + i, z[i], lengths[a],
							    lengths[b], signs);
							switch (op) {
							case 0:
								f[i].fn_add(
								    z[i] + dest, z[i], z[i] + 1);
								break;
							case 1:
								f[i].fn_sub(
								    z[i] + dest, z[i], z[i] + 1);
								break;
							case 2:
								f[i].fn_mul(
								    z[i] + dest, z[i], z[i] + 1);
								break;
							case 3:
								f[i].fn_mod(
								    z[i] + dest, z[i], z[i] + 1);
								break;
							case 4:
								f[i].fn_divmod(z[i] + dest,
								    z[i] + 3, z[i], z[i] + 1);
								break;
							case 5:
								f[i].fn_mulmod(z[i] + dest, z[i],
								    z[i] + 1, z[i] + 3);
								break;
							case 6:
								result[i] =
								    f[i].fn_expmod(z[i] + dest,
								        z[i], z[i] + 1, z[i] + 3);
								break;
							}
						}
						if (op != 6 || (lengths[b] && alias != 2)) {
							num("result", result[0], result[1]);
							compare(z[0] + dest, z[1] + dest, op <= 2);
						}
						if (op == 4)
							compare(z[0] + 3, z[1] + 3, 0);
						for (int i = 0; i < 2; i++)
							for (int j = 0; j < 4; j++)
								f[i].fn_free(z[i] + j);
					}
	const uint32_t small[] = {0, 1, 127, UINT32_MAX};
	for (size_t a = 0; a < 10; a++)
		for (size_t v = 0; v < 4; v++)
			for (int sign = 0; sign < 2; sign++)
				for (int alias = 0; alias < 2; alias++)
					for (int op = 0; op < 3; op++) {
						/* The system subtract-immediate call reads past an empty value for
         * 0 - 0. Finch handles it without reading an input word. */
						if (op == 1 && !lengths[a] && !small[v])
							continue;
						struct ccz z[2][4];
						int dest = alias ? 0 : 2;
						operation =
						    (const char *[]){"addi", "subi", "muli"}[op];
						for (int i = 0; i < 2; i++) {
							initialize(
							    f + i, z[i], lengths[a], 1, sign);
							(op == 0          ? f[i].fn_addi
							        : op == 1 ? f[i].fn_subi
							                  : f[i].fn_muli)(
							    z[i] + dest, z[i], small[v]);
						}
						compare(z[0] + dest, z[1] + dest, 1);
						for (int i = 0; i < 2; i++)
							for (int j = 0; j < 4; j++)
								f[i].fn_free(z[i] + j);
					}
	const size_t shifts[] = {0, 1, 7, 63, 64, 65, 127, 128, 511, 2048};
	for (size_t a = 0; a < 10; a++)
		for (size_t s = 0; s < 10; s++)
			for (int sign = 0; sign < 2; sign++)
				for (int alias = 0; alias < 2; alias++)
					for (int op = 0; op < 2; op++) {
						struct ccz z[2][4];
						int dest = alias ? 0 : 2;
						operation = op ? "right shift" : "left shift";
						for (int i = 0; i < 2; i++) {
							initialize(
							    f + i, z[i], lengths[a], 1, sign);
							(op ? f[i].fn_lsr : f[i].fn_lsl)(
							    z[i] + dest, z[i], shifts[s]);
						}
						compare(z[0] + dest, z[1] + dest, 1);
						for (int i = 0; i < 2; i++)
							for (int j = 0; j < 4; j++)
								f[i].fn_free(z[i] + j);
					}
	for (uint64_t value = 0; value < 100; value++) {
		struct ccz z[2];
		bool result[2];
		operation = "prime";
		for (int i = 0; i < 2; i++) {
			f[i].fn_init(&cls, z + i);
			f[i].fn_seti(z + i, value);
			result[i] = f[i].fn_is_prime(z + i, 5);
			f[i].fn_free(z + i);
		}
		num("result", result[0], result[1]);
	}
	for (size_t bits = 1; bits <= 1024; bits++)
		for (int error = 0; error < 2; error++) {
			struct ccz z[2];
			struct mockrng rng[2];
			int result[2];
			operation = "random bits";
			memset(z, 0x5a, sizeof(z));
			for (int i = 0; i < 2; i++) {
				f[i].fn_init(&cls, z + i);
				rng[i] = (struct mockrng){{generate}, 0, error ? -77 : 0};
				result[i] = f[i].fn_random_bits(z + i, bits, &rng[i].base);
			}
			num("result", result[0], result[1]);
			num("requested bytes", rng[0].size, rng[1].size);
			compare(z, z + 1, 1);
			for (int i = 0; i < 2; i++)
				f[i].fn_free(z + i);
		}
	for (uint64_t modulus = 1; modulus <= 37; modulus++) {
		struct ccz z[2][4];
		int result[2];
		operation = "power modulus";
		for (int i = 0; i < 2; i++) {
			initialize(f + i, z[i], 1, 1, 0);
			f[i].fn_seti(z[i], 3);
			f[i].fn_seti(z[i] + 1, 5);
			f[i].fn_seti(z[i] + 3, modulus);
			result[i] = f[i].fn_expmod(z[i] + 2, z[i], z[i] + 1, z[i] + 3);
		}
		num("result", result[0], result[1]);
		compare(z[0] + 2, z[1] + 2, 1);
		for (int i = 0; i < 2; i++)
			for (int j = 0; j < 4; j++)
				f[i].fn_free(z[i] + j);
	}
	/* The system returns m-1 for exponent zero and can overwrite an aliased
     * exponent. Check Finch's mathematical result for these cases instead. */
	struct ccz known[4];
	initialize(f + 1, known, 1, 1, 0);
	operation = "power edge cases";
	f[1].fn_seti(known, 3);
	f[1].fn_seti(known + 1, 0);
	f[1].fn_seti(known + 3, 19);
	num("zero exponent status", f[1].fn_expmod(known + 2, known, known + 1, known + 3), 0);
	num("zero exponent value", known[2].units[0], 1);
	f[1].fn_seti(known + 1, 5);
	num("aliased exponent status", f[1].fn_expmod(known + 1, known, known + 1, known + 3), 0);
	num("aliased exponent value", known[1].units[0], 15);
	for (int j = 0; j < 4; j++)
		f[1].fn_free(known + j);
	printf("CCZ math ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
