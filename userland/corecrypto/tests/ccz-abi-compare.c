/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccz.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks, failures;
static void same(const char *n, const void *a, const void *b, size_t z)
{
	checks++;
	if (memcmp(a, b, z) && failures++ < 20)
		fprintf(stderr, "%s differs\n", n);
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
	X(read_radix)                                                                              \
	X(write_radix) X(write_radix_size) X(size) X(init) X(free) X(n) X(capacity) X(sign)        \
	    X(set_n) X(set_sign) X(set_capacity) X(set) X(seti) X(zero) X(neg) X(bitlen)           \
	        X(trailing_zeros) X(is_zero) X(is_one) X(is_negative) X(bit) X(set_bit) X(cmp)     \
	            X(cmpi) X(read_uint) X(write_uint_size) X(write_int_size) X(write_uint)        \
	                X(write_int)
#define FIELD(n) __typeof__(&ccz_##n) fn_##n;
struct api {
	ALL(FIELD)
};
struct events {
	size_t allocations, reallocations, frees, oldsize, newsize, freeunits;
};
static void *allocate(void *context, size_t size)
{
	struct events *e = context;
	e->allocations++;
	e->newsize = size;
	void *p = malloc(size);
	if (!p)
		abort();
	memset(p, 0xa5, size);
	return p;
}
static void *reallocate(void *context, size_t oldsize, void *p, size_t size)
{
	struct events *e = context;
	e->reallocations++;
	e->oldsize = oldsize;
	e->newsize = size;
	p = realloc(p, size);
	if (!p)
		abort();
	if (size > oldsize)
		memset((unsigned char *)p + oldsize, 0xa5, size - oldsize);
	return p;
}
static void deallocate(void *context, size_t units, void *p)
{
	struct events *e = context;
	e->frees++;
	e->freeunits = units;
	free(p);
}
static void compare(struct api *f, struct ccz *z, struct events *events)
{
	struct ccz a = z[0], b = z[1];
	a.isa = b.isa = NULL;
	a.units = b.units = NULL;
	same("context", &a, &b, sizeof(a));
	same("allocator calls", events, events + 1, sizeof(events[0]));
	if (z[0].units && z[1].units && f[0].fn_capacity(z) == f[1].fn_capacity(z + 1))
		same("allocated bytes", z[0].units, z[1].units, f[0].fn_capacity(z) * 8);
#define QUERY(n) num(#n, f[0].fn_##n(z), f[1].fn_##n(z + 1));
	QUERY(n)
	QUERY(capacity) QUERY(sign) QUERY(bitlen) QUERY(trailing_zeros) QUERY(is_zero) QUERY(is_one)
	    QUERY(is_negative) QUERY(write_uint_size) QUERY(write_int_size) size_t bits =
	        f[0].fn_bitlen(z);
	for (size_t bit = 0; bit <= bits + 2; bit += 17)
		num("bit", f[0].fn_bit(z, bit), f[1].fn_bit(z + 1, bit));
	uint64_t integers[] = {0, 1, 127, 128, UINT64_MAX};
	for (size_t j = 0; j < 5; j++)
		num("cmpi", f[0].fn_cmpi(z, integers[j]), f[1].fn_cmpi(z + 1, integers[j]));
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
	num("size", f[0].fn_size(), f[1].fn_size());
	for (int trial = 0; trial < 64; trial++) {
		struct ccz z[2];
		struct events events[2] = {{0}};
		struct ccz_class cls[2];
		memset(z, 0x5a, sizeof(z));
		for (int i = 0; i < 2; i++) {
			cls[i] = (struct ccz_class){events + i, allocate, reallocate, deallocate};
			f[i].fn_init(cls + i, z + i);
		}
		compare(f, z, events);
		size_t capacities[] = {0, 1, 31, 32, 33, 63, 64, 65, 95, 96, 128};
		for (size_t j = 0; j < sizeof(capacities) / sizeof(capacities[0]); j++) {
			for (int i = 0; i < 2; i++)
				f[i].fn_set_capacity(z + i, capacities[j]);
			compare(f, z, events);
		}
		uint64_t values[] = {0, 1, 127, 128, 255, 256, UINT64_MAX, UINT64_C(1) << 63};
		for (size_t j = 0; j < 8; j++) {
			for (int i = 0; i < 2; i++)
				f[i].fn_seti(z + i, values[j]);
			compare(f, z, events);
			for (int sign = -1; sign <= 1; sign++) {
				for (int i = 0; i < 2; i++)
					f[i].fn_set_sign(z + i, sign);
				compare(f, z, events);
				for (int i = 0; i < 2; i++)
					f[i].fn_neg(z + i);
				compare(f, z, events);
			}
		}
		unsigned char input[256];
		for (size_t j = 0; j < sizeof(input); j++)
			input[j] = (unsigned char)(j * 29 + trial);
		if (trial % 5 == 0)
			memset(input, 0, sizeof(input));
		for (size_t size = 0; size <= sizeof(input); size += 7) {
			for (int i = 0; i < 2; i++)
				f[i].fn_read_uint(z + i, size, input);
			compare(f, z, events);
			for (size_t capacity = 0; capacity <= size + 2; capacity++) {
				unsigned char out[2][280];
				memset(out, 0xa5, sizeof(out));
				for (int i = 0; i < 2; i++)
					f[i].fn_write_uint(z + i, capacity, out[i] + 8);
				if (memcmp(out, out + 1, sizeof(out[0])) && !failures) {
					fprintf(stderr,
					    "first output trial=%d input=%zu capacity=%zu host=",
					    trial, size, capacity);
					for (size_t k = 0; k < capacity + 4; k++)
						fprintf(stderr, "%02x", out[0][8 + k]);
					fprintf(stderr, " finch=");
					for (size_t k = 0; k < capacity + 4; k++)
						fprintf(stderr, "%02x", out[1][8 + k]);
					fprintf(stderr, "\n");
				}
				same("unsigned output and guards", out, out + 1, sizeof(out[0]));
				if (capacity) {
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++)
						f[i].fn_write_int(z + i, capacity, out[i] + 8);
					same("signed output and guards", out, out + 1,
					    sizeof(out[0]));
				}
			}
		}
		for (size_t bit = 0; bit < 5000; bit += 127) {
			for (int i = 0; i < 2; i++)
				f[i].fn_set_bit(z + i, bit, trial % 3);
			compare(f, z, events);
		}
		for (int i = 0; i < 2; i++)
			f[i].fn_zero(z + i);
		compare(f, z, events);
		for (int i = 0; i < 2; i++)
			f[i].fn_set_n(z + i, 4);
		compare(f, z, events);
		for (int i = 0; i < 2; i++)
			f[i].fn_free(z + i);
		struct ccz a = z[0], b = z[1];
		a.isa = b.isa = NULL;
		a.units = b.units = NULL;
		same("free leaves context", &a, &b, sizeof(a));
		same("free callback", events, events + 1, sizeof(events[0]));
	}
	/* Copy contexts between libraries in both directions, with either sign. */
	for (int source = 0; source < 2; source++)
		for (int dest = 0; dest < 2; dest++)
			for (int preallocate = 0; preallocate < 2; preallocate++) {
				struct events event = {0};
				struct ccz_class cls = {&event, allocate, reallocate, deallocate};
				struct ccz a, b;
				f[source].fn_init(&cls, &a);
				f[dest].fn_init(&cls, &b);
				f[source].fn_seti(&a, 0xfedcba9876543210);
				f[source].fn_neg(&a);
				if (preallocate)
					f[dest].fn_set_capacity(&b, 1);
				f[dest].fn_set(&b, &a);
				num("mixed copy magnitude", a.units[0], b.units[0]);
				num("mixed copy sign", f[dest].fn_sign(&b), preallocate ? -1 : 1);
				f[dest].fn_set(&b, &b);
				num("self copy", a.units[0], b.units[0]);
				num("mixed compare", f[source].fn_cmp(&a, &b),
				    f[dest].fn_cmp(&a, &b));
				f[dest].fn_free(&a);
				f[source].fn_free(&b);
			}
	const char *texts[] = {"", "+", "-", "0", "0000", "-0000", "+0001", "-1",
	    "123456789012345678901234567890", "DEADBEEF", "deadBEEF", "-000ABC", "12x34",
	    "ffffzfff", " 12", "12 ", "0x10"};
	unsigned bases[] = {0, 2, 8, 10, 16, 36};
	for (size_t t = 0; t < sizeof(texts) / sizeof(texts[0]); t++)
		for (size_t base = 0; base < sizeof(bases) / sizeof(bases[0]); base++) {
			struct ccz z[2];
			struct events events[2] = {{0}};
			struct ccz_class cls[2];
			int status[2];
			memset(z, 0x5a, sizeof(z));
			for (int i = 0; i < 2; i++) {
				cls[i] = (struct ccz_class){
				    events + i, allocate, reallocate, deallocate};
				f[i].fn_init(cls + i, z + i);
				f[i].fn_seti(z + i, 0xabcdef);
				status[i] = f[i].fn_read_radix(
				    z + i, strlen(texts[t]), texts[t], bases[base]);
			}
			num("read radix status", status[0], status[1]);
			compare(f, z, events);
			for (size_t outputbase = 0; outputbase < sizeof(bases) / sizeof(bases[0]);
			    outputbase++) {
				num("radix output size",
				    f[0].fn_write_radix_size(z, bases[outputbase]),
				    f[1].fn_write_radix_size(z + 1, bases[outputbase]));
				for (size_t cap = 0; cap < 40; cap++) {
					unsigned char out[2][64];
					memset(out, 0xa5, sizeof(out));
					for (int i = 0; i < 2; i++)
						status[i] = f[i].fn_write_radix(z + i, cap,
						    (char *)out[i] + 8, bases[outputbase]);
					num("write radix status", status[0], status[1]);
					same("radix output and guards", out, out + 1,
					    sizeof(out[0]));
				}
			}
			for (int i = 0; i < 2; i++)
				f[i].fn_free(z + i);
		}
	printf("CCZ storage ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
