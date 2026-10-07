/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * crt-compare: differential test of Finch's libcompiler_rt against Apple's.
 * Calls each exported arithmetic builtin through both libraries on the same
 * inputs (edge cases plus random values) and compares bit patterns.
 *
 *   crt-compare <path to Finch's libcompiler_rt.dylib>
 */

#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef __int128 ti;
typedef unsigned __int128 tu;

static void *apple, *finch;
static unsigned long checks, failures;

static void *sym(void *h, const char *name)
{
	void *p = dlsym(h, name);
	if (p == NULL) {
		fprintf(stderr, "missing %s\n", name);
		exit(2);
	}
	return p;
}

static uint64_t state = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void)
{
	state ^= state << 13;
	state ^= state >> 7;
	state ^= state << 17;
	return state;
}

static void fail(const char *fn, const char *detail)
{
	if (failures++ < 20)
		fprintf(stderr, "FAIL %s: %s\n", fn, detail);
}

#define SAME(fn, a, b) do {                                              \
	checks++;                                                        \
	if (memcmp(&(a), &(b), sizeof(a)) != 0) fail(fn, "results differ"); \
} while (0)

/* Interesting 128-bit values: zero, ones, signs, powers of two, random. */
static tu pick128(int i)
{
	static const tu fixed[] = {
		0, 1, 2, 3, 7, 10, (tu)-1, (tu)-2, (tu)1 << 63, (tu)1 << 64, (tu)1 << 127,
		((tu)1 << 127) - 1, (tu)UINT64_MAX, ((tu)UINT64_MAX << 64), (tu)0x123456789abcdefull,
	};
	int n = sizeof(fixed) / sizeof(fixed[0]);
	if (i < n)
		return fixed[i];
	tu v = ((tu)rnd() << 64) | rnd();
	switch (rnd() % 4) {
	case 0: return v >> (rnd() % 128);
	case 1: return (tu)(uint64_t)v;
	default: return v;
	}
}

static double pickd(int i)
{
	static const double fixed[] = {
		0.0, -0.0, 1.0, -1.0, 0.5, 1e300, -1e300, 1.7e38, 3.4e38, 1e-310, INFINITY, -INFINITY, NAN,
		9.2233720368547758e18, 1.8446744073709552e19, 1.7014118346046923e38, -1.7014118346046923e38,
		3.402823669209385e38, 65504.0, 65520.0, 6.1e-5, 5.96e-8,
	};
	int n = sizeof(fixed) / sizeof(fixed[0]);
	if (i < n)
		return fixed[i];
	uint64_t bits = rnd();
	double d;
	memcpy(&d, &bits, sizeof(d));
	return d;
}

static void test_int128(void)
{
	const char *bin[] = { "__divti3", "__modti3", "__udivti3", "__umodti3" };
	for (int f = 0; f < 4; f++) {
		tu (*a)(tu, tu) = sym(apple, bin[f]), (*b)(tu, tu) = sym(finch, bin[f]);
		for (int i = 0; i < 20000; i++) {
			tu x = pick128(i % 200 == 0 ? i / 200 : 100), y = pick128(i % 15);
			if (y == 0) y = 1;
			if (f < 2 && (ti)y == -1 && (ti)x == (ti)((tu)1 << 127)) continue;  /* overflow traps */
			tu ra = a(x, y), rb = b(x, y);
			SAME(bin[f], ra, rb);
		}
	}
	tu (*ua)(tu, tu, tu *) = sym(apple, "__udivmodti4"), (*ub)(tu, tu, tu *) = sym(finch, "__udivmodti4");
	for (int i = 0; i < 20000; i++) {
		tu x = pick128(100), y = pick128(i % 30) | 1, rema, remb;
		tu qa = ua(x, y, &rema), qb = ub(x, y, &remb);
		SAME("__udivmodti4", qa, qb);
		SAME("__udivmodti4 rem", rema, remb);
	}
	int (*ca)(ti) = sym(apple, "__clzti2"), (*cb)(ti) = sym(finch, "__clzti2");
	for (int i = 0; i < 5000; i++) {
		ti x = (ti)pick128(i < 15 ? i : 100);
		if (x == 0) continue;  /* undefined */
		int ra = ca(x), rb = cb(x);
		SAME("__clzti2", ra, rb);
	}
}

static void test_conversions(void)
{
	const char *fromd[] = { "__fixdfti", "__fixunsdfti" };
	const char *froms[] = { "__fixsfti", "__fixunssfti" };
	for (int f = 0; f < 2; f++) {
		tu (*a)(double) = sym(apple, fromd[f]), (*b)(double) = sym(finch, fromd[f]);
		tu (*sa)(float) = sym(apple, froms[f]), (*sb)(float) = sym(finch, froms[f]);
		for (int i = 0; i < 20000; i++) {
			double d = pickd(i < 22 ? i : 100);
			if (i >= 22 && (rnd() & 1)) d = ldexp((double)(int64_t)rnd(), (int)(rnd() % 140) - 70);
			tu ra = a(d), rb = b(d);
			SAME(fromd[f], ra, rb);
			float s = (float)d;
			tu rsa = sa(s), rsb = sb(s);
			SAME(froms[f], rsa, rsb);
		}
	}
	const char *tod[] = { "__floattidf", "__floatuntidf" }, *tos[] = { "__floattisf", "__floatuntisf" };
	for (int f = 0; f < 2; f++) {
		double (*a)(tu) = sym(apple, tod[f]), (*b)(tu) = sym(finch, tod[f]);
		float (*sa)(tu) = sym(apple, tos[f]), (*sb)(tu) = sym(finch, tos[f]);
		for (int i = 0; i < 20000; i++) {
			tu x = pick128(i < 15 ? i : 100);
			double ra = a(x), rb = b(x);
			SAME(tod[f], ra, rb);
			float rsa = sa(x), rsb = sb(x);
			SAME(tos[f], rsa, rsb);
		}
	}
}

static void test_half(void)
{
	float (*ea)(uint16_t) = sym(apple, "__extendhfsf2"), (*eb)(uint16_t) = sym(finch, "__extendhfsf2");
	float (*ga)(uint16_t) = sym(apple, "__gnu_h2f_ieee"), (*gb)(uint16_t) = sym(finch, "__gnu_h2f_ieee");
	for (uint32_t h = 0; h <= 0xffff; h++) {
		float ra = ea((uint16_t)h), rb = eb((uint16_t)h);
		SAME("__extendhfsf2", ra, rb);
		ra = ga((uint16_t)h), rb = gb((uint16_t)h);
		SAME("__gnu_h2f_ieee", ra, rb);
	}
	uint16_t (*ta)(float) = sym(apple, "__truncsfhf2"), (*tb)(float) = sym(finch, "__truncsfhf2");
	uint16_t (*fa)(float) = sym(apple, "__gnu_f2h_ieee"), (*fb)(float) = sym(finch, "__gnu_f2h_ieee");
	uint16_t (*da)(double) = sym(apple, "__truncdfhf2"), (*db)(double) = sym(finch, "__truncdfhf2");
	for (int i = 0; i < 200000; i++) {
		uint32_t bits = (uint32_t)rnd();
		float f;
		memcpy(&f, &bits, sizeof(f));
		uint16_t ra = ta(f), rb = tb(f);
		SAME("__truncsfhf2", ra, rb);
		ra = fa(f), rb = fb(f);
		SAME("__gnu_f2h_ieee", ra, rb);
		double d = pickd(i < 22 ? i : 100);
		if (i >= 22 && (rnd() & 1)) d = ldexp((double)(int32_t)rnd(), (int)(rnd() % 60) - 50);
		ra = da(d), rb = db(d);
		SAME("__truncdfhf2", ra, rb);
	}
}

static void test_complex_pow(void)
{
	_Complex double (*ma)(double, double, double, double) = sym(apple, "__muldc3");
	_Complex double (*mb)(double, double, double, double) = sym(finch, "__muldc3");
	_Complex float (*sa)(float, float, float, float) = sym(apple, "__mulsc3");
	_Complex float (*sb)(float, float, float, float) = sym(finch, "__mulsc3");
	for (int i = 0; i < 50000; i++) {
		double v[4];
		for (int k = 0; k < 4; k++) v[k] = pickd((rnd() % 3) ? 100 : (int)(rnd() % 22));
		_Complex double ra = ma(v[0], v[1], v[2], v[3]), rb = mb(v[0], v[1], v[2], v[3]);
		/* NaN payloads may differ; compare NaN-ness, then bits. */
		double a2[2] = { __real__ ra, __imag__ ra }, b2[2] = { __real__ rb, __imag__ rb };
		checks++;
		for (int k = 0; k < 2; k++)
			if (isnan(a2[k]) != isnan(b2[k]) || (!isnan(a2[k]) && memcmp(&a2[k], &b2[k], 8)))
				{ fail("__muldc3", "results differ"); break; }
		_Complex float rsa = sa(v[0], v[1], v[2], v[3]), rsb = sb(v[0], v[1], v[2], v[3]);
		float fa2[2] = { __real__ rsa, __imag__ rsa }, fb2[2] = { __real__ rsb, __imag__ rsb };
		checks++;
		for (int k = 0; k < 2; k++)
			if (isnan(fa2[k]) != isnan(fb2[k]) || (!isnan(fa2[k]) && memcmp(&fa2[k], &fb2[k], 4)))
				{ fail("__mulsc3", "results differ"); break; }
	}
	double (*pa)(double, int) = sym(apple, "__powidf2"), (*pb)(double, int) = sym(finch, "__powidf2");
	float (*qa)(float, int) = sym(apple, "__powisf2"), (*qb)(float, int) = sym(finch, "__powisf2");
	for (int i = 0; i < 50000; i++) {
		double d = pickd(i < 22 ? i : 100);
		if (i >= 22 && (rnd() & 1)) d = ldexp((double)(int32_t)rnd(), -30);
		int e = (int)(rnd() % 80) - 40;
		if (i % 1000 == 0) e = (int)rnd();
		double ra = pa(d, e), rb = pb(d, e);
		SAME("__powidf2", ra, rb);
		float rsa = qa((float)d, e), rsb = qb((float)d, e);
		SAME("__powisf2", rsa, rsb);
	}
}

static void test_atomics(void)
{
	/* Same results through both libraries, sized and generic (locked). */
	struct big { char b[24]; };
	void (*la)(size_t, void *, void *, int) = sym(finch, "__atomic_load");
	void (*sa)(size_t, void *, void *, int) = sym(finch, "__atomic_store");
	void (*xa)(size_t, void *, void *, void *, int) = sym(finch, "__atomic_exchange");
	int (*cas)(size_t, void *, void *, void *, int, int) = sym(finch, "__atomic_compare_exchange");
	struct big obj, v, out, expected;
	memset(&obj, 1, sizeof(obj));
	memset(&v, 2, sizeof(v));
	sa(sizeof(obj), &obj, &v, 5);
	la(sizeof(obj), &obj, &out, 5);
	checks++;
	if (memcmp(&out, &v, sizeof(v))) fail("__atomic_store/load", "generic");
	memset(&v, 3, sizeof(v));
	xa(sizeof(obj), &obj, &v, &out, 5);
	checks++;
	if (out.b[0] != 2 || obj.b[23] != 3) fail("__atomic_exchange", "generic");
	memset(&expected, 3, sizeof(expected));
	memset(&v, 4, sizeof(v));
	checks++;
	if (!cas(sizeof(obj), &obj, &expected, &v, 5, 5) || obj.b[0] != 4) fail("__atomic_compare_exchange", "success");
	checks++;
	if (cas(sizeof(obj), &obj, &expected, &v, 5, 5) || expected.b[0] != 4) fail("__atomic_compare_exchange", "failure");

	uint32_t (*fadd)(uint32_t *, uint32_t, int) = sym(finch, "__atomic_fetch_add_4");
	uint32_t x = 40;
	checks++;
	if (fadd(&x, 2, 5) != 40 || x != 42) fail("__atomic_fetch_add_4", "value");
	int (*lf)(size_t, void *) = sym(finch, "__atomic_is_lock_free");
	int (*lfa)(size_t, void *) = sym(apple, "__atomic_is_lock_free");
	for (size_t s = 1; s <= 32; s++) {
		int ra = lfa(s, NULL), rb = lf(s, NULL);
		SAME("__atomic_is_lock_free", ra, rb);
	}
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: crt-compare <finch libcompiler_rt.dylib>\n");
		return 2;
	}
	apple = dlopen("/usr/lib/system/libcompiler_rt.dylib", RTLD_NOW | RTLD_LOCAL);
	finch = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!apple || !finch || apple == finch) {
		fprintf(stderr, "crt-compare: %s\n", apple == finch ? "same library loaded twice" : dlerror());
		return 2;
	}
	test_int128();
	test_conversions();
	test_half();
	test_complex_pow();
	test_atomics();
	printf("crt-compare: %lu checks, %lu failures\n", checks, failures);
	return failures != 0;
}
