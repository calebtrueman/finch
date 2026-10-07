/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccn.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
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
static uint64_t seed = 0x9e3779b97f4a7c15ULL;
static uint64_t random_word(void)
{
	seed ^= seed << 13;
	seed ^= seed >> 7;
	seed ^= seed << 17;
	return seed;
}
#define FUNCTIONS(X)                                                                               \
	X(add)                                                                                     \
	X(add1) X(sub) X(bitlen) X(cmp) X(cmpn) X(read_uint) X(write_uint_size) X(write_int_size)  \
	    X(write_uint) X(write_int) X(write_uint_padded) X(write_uint_padded_ct) X(zero)        \
	        X(seti) X(set_bit) X(swap) X(xor) X(print) X(lprint)
#define FIELD(n) __typeof__(&ccn_##n) n;
struct api {
	FUNCTIONS(FIELD)
};
#undef FIELD
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
#define LOAD(n) f[i].n = sym(h[i], "ccn_" #n);
		FUNCTIONS(LOAD)
#undef LOAD
	}
	if (f[0].add == f[1].add)
		return 2;
	uint64_t a[18], b[18], out[2][20];
	unsigned char bytes[160];
	for (size_t n = 0; n <= 16; n++)
		for (unsigned pattern = 0; pattern < 100; pattern++) {
			for (size_t i = 0; i < 18; i++) {
				a[i] = random_word();
				b[i] = random_word();
				if (pattern < 4) {
					a[i] = pattern & 1 ? UINT64_MAX : 0;
					b[i] = pattern & 2 ? UINT64_MAX : 0;
				}
				if (pattern >= 4 && pattern < 68) {
					a[i] = i == 0 ? UINT64_C(1) << (pattern - 4) : 0;
					b[i] = a[i] - 1;
				}
				if (pattern == 68)
					b[i] = a[i];
			}
			size_t z[2];
			for (int i = 0; i < 2; i++)
				z[i] = f[i].bitlen(n, a);
			same("bit length", z, z + 1, sizeof(size_t));
			for (int i = 0; i < 2; i++)
				z[i] = f[i].write_uint_size(n, a);
			same("uint size", z, z + 1, sizeof(size_t));
			for (int i = 0; i < 2; i++)
				z[i] = f[i].write_int_size(n, a);
			same("int size", z, z + 1, sizeof(size_t));
			result("compare", f[0].cmp(n, a, b), f[1].cmp(n, a, b));
			for (size_t nb = 0; nb <= 16; nb++)
				result("compare unequal widths", f[0].cmpn(n, a, nb, b),
				    f[1].cmpn(n, a, nb, b));
			for (int operation = 0; operation < 3; operation++)
				for (int inplace = 0; inplace < 3; inplace++) {
					uint64_t carry[2];
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++) {
						if (inplace)
							memcpy(out[i] + 1, inplace == 1 ? a : b,
							    n * 8);
						const uint64_t *left =
						                   inplace == 1 ? out[i] + 1 : a,
						               *right =
						                   inplace == 2 ? out[i] + 1 : b;
						if (operation == 0)
							carry[i] =
							    f[i].add(n, out[i] + 1, left, right);
						else if (operation == 1)
							carry[i] =
							    f[i].sub(n, out[i] + 1, left, right);
						else
							carry[i] =
							    f[i].add1(n, out[i] + 1, left, b[0]);
					}
					same("arithmetic carry", carry, carry + 1, 8);
					same("arithmetic output/guards", out[0], out[1],
					    sizeof(out[0]));
				}
			memset(out, 0xa5, sizeof(out));
			for (int i = 0; i < 2; i++)
				f[i].xor(n, out[i] + 1, a, b);
			same("xor", out[0], out[1], sizeof(out[0]));
			for (int i = 0; i < 2; i++) {
				memcpy(out[i] + 1, a, n * 8);
				f[i].swap(n, out[i] + 1);
			}
			same("byte swap", out[0], out[1], sizeof(out[0]));
			for (int i = 0; i < 2; i++)
				f[i].zero(n, out[i] + 1);
			same("zero", out[0], out[1], sizeof(out[0]));
			if (n) {
				for (int i = 0; i < 2; i++)
					f[i].seti(n, out[i] + 1, a[0]);
				same("set integer", out[0], out[1], sizeof(out[0]));
			}
			for (size_t size = 0; size <= n * 8 + 3; size++) {
				unsigned char written[2][160];
				int r[2];
				memset(written, 0xa5, sizeof(written));
				for (int i = 0; i < 2; i++)
					f[i].write_uint(n, a, size, written[i] + 8);
				same("write uint", written[0], written[1], sizeof(written[0]));
				if (size) {
					memset(written, 0xa5, sizeof(written));
					for (int i = 0; i < 2; i++)
						f[i].write_int(n, a, size, written[i] + 8);
					same("write int", written[0], written[1],
					    sizeof(written[0]));
				}
				memset(written, 0xa5, sizeof(written));
				for (int i = 0; i < 2; i++)
					r[i] =
					    f[i].write_uint_padded_ct(n, a, size, written[i] + 8);
				result("padded result", r[0], r[1]);
				same("padded bytes/guards", written[0], written[1],
				    sizeof(written[0]));
				memset(written, 0xa5, sizeof(written));
				for (int i = 0; i < 2; i++)
					z[i] = f[i].write_uint_padded(n, a, size, written[i] + 8);
				same("legacy padded result", z, z + 1, sizeof(size_t));
				same("legacy padded bytes/guards", written[0], written[1],
				    sizeof(written[0]));
			}
			for (size_t i = 0; i < sizeof(bytes); i++)
				bytes[i] = pattern < 2 ? 0 : (unsigned char)random_word();
			for (size_t size = 0; size <= n * 8 + 3; size++) {
				int r[2];
				memset(out, 0xa5, sizeof(out));
				for (int i = 0; i < 2; i++)
					r[i] = f[i].read_uint(n, out[i] + 1, size, bytes);
				result("read result", r[0], r[1]);
				same("read output/guards", out[0], out[1], sizeof(out[0]));
			}
		}
	for (size_t bit = 0; bit < 1024; bit++)
		for (uint64_t value = 0; value < 3; value++) {
			memset(out, 0xa5, sizeof(out));
			for (int i = 0; i < 2; i++)
				f[i].set_bit(out[i] + 1, bit, value);
			same("set bit", out[0], out[1], sizeof(out[0]));
		}
	memset(out, 0xa5, sizeof(out));
	for (int i = 0; i < 2; i++)
		result("huge padded size", -7, f[i].write_uint_padded_ct(1, a, INT32_MAX, out[i]));
	same("huge output guard", out[0], out[1], sizeof(out[0]));
	for (int i = 0; i < 2; i++)
		result("huge limb count", -7,
		    f[i].write_uint_padded_ct(INT32_MAX / 8 + 1ULL, a, 0, out[i]));
	same("huge limb guard", out[0], out[1], sizeof(out[0]));
	f[1].seti(0, out[1], 1);
	f[1].write_int(1, a, 0, out[1]);
	same("safe zero sizes", out[0], out[1], sizeof(out[0]));
	/* Keep debug output off the test log while comparing its exact bytes. */
	for (size_t n = 0; n <= 16; n++) {
		char printed[2][4096];
		memset(printed, 0, sizeof(printed));
		for (int i = 0; i < 2; i++) {
			FILE *file = tmpfile();
			if (!file)
				return 2;
			fflush(stderr);
			int saved = dup(STDERR_FILENO);
			if (saved < 0)
				return 2;
			if (dup2(fileno(file), STDERR_FILENO) < 0)
				return 2;
			f[i].print(n, a);
			f[i].lprint(n, "number", a);
			fflush(stderr);
			if (dup2(saved, STDERR_FILENO) < 0)
				return 2;
			close(saved);
			rewind(file);
			fread(printed[i], 1, sizeof(printed[i]) - 1, file);
			fclose(file);
		}
		same("print formatting", printed[0], printed[1], sizeof(printed[0]));
	}
	printf("CCN ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
