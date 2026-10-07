/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libm-compare: Finch's libsystem_m against Apple's, function by function,
 * on special values plus random inputs across the exponent range.
 *
 * Fails on:
 *  - exact operations (rounding, fabs, sqrt, fmod, remainder, fma, frexp,
 *    ldexp, nextafter, min/max, the _Float16 functions...) differing from
 *    Apple bit for bit;
 *  - special-value class or sign differences in the real scalar functions;
 *  - classification, fenv, matrix inverses beyond a relative tolerance.
 * Geometry-predicate signs that differ from Apple's are dumped and decided
 * with exact rational arithmetic by geometry_judge.py (Apple's float
 * predicates and some extreme-range double cases are inexact).
 * Reports (doesn't fail on) ulp distances from Apple's transcendental
 * results: Apple isn't the reference. Finch's real functions are CORE-MATH
 * (correctly rounded); judge.py checks them against high-precision values
 * (LIBM_DUMP=<file>, then python judge.py <file> --check). Complex functions
 * follow C's Annex G (C23) where Apple's differ; see ../README.md.
 *
 *   libm-compare <path to Finch's libsystem_m.dylib>
 */

#include <complex.h>
#include <dlfcn.h>
#include <fenv.h>
#include <float.h>
#include <math.h>
#include <simd/simd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *ha, *hf;
static FILE *dump;   /* LIBM_DUMP=<file>: every disagreement, for an mpmath judge */

static void dumpd(const char *name, int nargs, double x, double y, double a, double b)
{
	if (dump) fprintf(dump, "%s %d %a %a %a %a\n", name, nargs, x, y, a, b);
}
static unsigned long checks, failures;
static int verbose;


static void *sym(void *h, const char *name)
{
	void *p = dlsym(h, name);
	if (!p) { fprintf(stderr, "missing %s\n", name); exit(2); }
	return p;
}

static uint64_t seed = 0x243f6a8885a308d3ull;
static uint64_t rnd(void) { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed; }

static void fail(const char *fn, const char *what)
{
	if (failures++ < 40)
		fprintf(stderr, "FAIL %s: %s\n", fn, what);
}

/* ---- ulp distance ---- */

static int64_t dord(double x) { int64_t i; memcpy(&i, &x, 8); return i < 0 ? INT64_MIN - i : i; }
static int32_t ford(float x) { int32_t i; memcpy(&i, &x, 4); return i < 0 ? INT32_MIN - i : i; }

/* Distance in ulps, or -1 if the special-value classes differ. */
static double dulp(double a, double b)
{
	if (isnan(a) || isnan(b)) return (isnan(a) && isnan(b)) ? 0 : -1;
	if (isinf(a) || isinf(b) || a == 0 || b == 0) {
		if (memcmp(&a, &b, 8) == 0) return 0;
		/* zero vs tiny nonzero: still measure, but signs of zero must match */
		if (a == 0 && b == 0) return -1;
		if (isinf(a) || isinf(b)) return -1;
	}
	double d = (double)(dord(a) - dord(b));
	return d < 0 ? -d : d;
}

static double fulp(float a, float b)
{
	if (isnan(a) || isnan(b)) return (isnan(a) && isnan(b)) ? 0 : -1;
	if (isinf(a) || isinf(b) || a == 0 || b == 0) {
		if (memcmp(&a, &b, 4) == 0) return 0;
		if (a == 0 && b == 0) return -1;
		if (isinf(a) || isinf(b)) return -1;
	}
	double d = (double)(ford(a) - ford(b));
	return d < 0 ? -d : d;
}

/* ---- inputs ---- */

static const double specials[] = {
	0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, 10.0, 0.1, 1e-300, -1e-300, 4.9e-324, -4.9e-324, 2.2250738585072014e-308,
	1e300, -1e300, DBL_MAX, -DBL_MAX, INFINITY, -INFINITY, NAN, M_PI, M_PI_2, -M_PI_2, 3 * M_PI_2, 1e22, 710.0, -745.0,
	709.78, 1024.0, -1075.0, 0.25, 1.5, 100.5, -3.5, 1e-8, 6.5, 1e15 + 0.5, 4503599627370496.5,
};
#define NSPECIAL (sizeof(specials) / sizeof(specials[0]))

/* Random double: a spread of magnitudes, sometimes small integers or halves. */
static double rd(int i)
{
	if (i < (int)NSPECIAL) return specials[i];
	uint64_t r = rnd();
	switch (r % 6) {
	case 0: { double d; uint64_t b = rnd(); memcpy(&d, &b, 8); return d; }           /* any bit pattern */
	case 1: return ldexp((double)(int64_t)rnd(), (int)(rnd() % 80) - 100);            /* |x| ~ 1e-19..1e5 */
	case 2: return (double)((int64_t)(rnd() % 2000) - 1000) / 2;                   /* halves */
	case 3: return ldexp((double)(rnd() >> 11), -53) * 20 - 10;                    /* [-10, 10) */
	case 4: return ldexp((double)(rnd() >> 11), -53) * 2 - 1;                      /* [-1, 1) */
	default: return ldexp((double)(int64_t)rnd(), (int)(rnd() % 300) - 300);
	}
}

static float rf(int i) { return (float)rd(i); }

/* ---- function tables ---- */

typedef double (*d1)(double);
typedef float (*f1)(float);
typedef double (*d2)(double, double);
typedef float (*f2)(float, float);

struct stat { const char *name; double max; double at; int count; int exact; int shown; };

static void report(struct stat *s)
{
	if (verbose || s->max > 0)
		printf("  %-14s max %4.0f ulp%s\n", s->name, s->max, s->exact ? " (exact)" : "");
}

/* The results being judged, for failure reports. */
static double cur_a, cur_b;
static int informational;   /* complex and simd results: report only */
static unsigned long geometry_differences;   /* judged exactly by geometry_judge.py */

static void judge(struct stat *s, double u, double input)
{
	checks++;
	/* Exact functions must match; others fail only on special-value
	 * class/sign differences (u < 0) in real scalar functions. */
	int bad = (s->exact && u != 0) || (u < 0 && !informational);
	if (u > s->max) { s->max = u; s->at = input; }
	if (bad) {
		failures++;
		if (s->shown++ < 3)
			fprintf(stderr, "FAIL %-12s x=%-24a apple=%-24a finch=%a\n", s->name, input, cur_a, cur_b);
	}
}
#define DULP(a, b) (cur_a = (a), cur_b = (b), dulp(cur_a, cur_b))
#define FULP(a, b) (cur_a = (a), cur_b = (b), fulp((float)cur_a, (float)cur_b))

static const char *exact_names[] = {
	"ceil", "floor", "trunc", "round", "rint", "nearbyint", "fabs", "sqrt", "logb", "fmod", "remainder",
	"fmin", "fmax", "fdim", "nextafter", "copysign", "ceilf", "floorf", "truncf", "roundf", "rintf",
	"nearbyintf", "fabsf", "sqrtf", "logbf", "fmodf", "remainderf", "fminf", "fmaxf", "fdimf", "nextafterf",
	"copysignf", NULL,
};

static int is_exact(const char *n)
{
	for (int i = 0; exact_names[i]; i++)
		if (!strcmp(exact_names[i], n)) return 1;
	return 0;
}

static void test_d1(const char *name)
{
	d1 a = sym(ha, name), b = sym(hf, name);
	struct stat s = { name, 0, 0, 0, is_exact(name) };
	for (int i = 0; i < 40000; i++) {
		double x = rd(i), ra = a(x), rb = b(x), u = dulp(ra, rb);
		if (u < 0 || u > 1) dumpd(name, 1, x, 0, ra, rb);
		judge(&s, DULP(ra, rb), x);
	}
	report(&s);
}

static void test_f1(const char *name)
{
	f1 a = sym(ha, name), b = sym(hf, name);
	struct stat s = { name, 0, 0, 0, is_exact(name) };
	for (int i = 0; i < 40000; i++) {
		float x = rf(i), ra = a(x), rb = b(x);
		double u = fulp(ra, rb);
		if (u < 0 || u > 1) dumpd(name, 1, x, 0, ra, rb);
		judge(&s, FULP(ra, rb), x);
	}
	report(&s);
}

static void test_d2(const char *name)
{
	d2 a = sym(ha, name), b = sym(hf, name);
	struct stat s = { name, 0, 0, 0, is_exact(name) };
	for (int i = 0; i < 40000; i++) {
		double x = rd(i % 997 == 0 ? (int)(rnd() % NSPECIAL) : 1000), y = rd(i < (int)NSPECIAL ? i : 1000);
		double ra = a(x, y), rb = b(x, y), u = dulp(ra, rb);
		if (u < 0 || u > 1) dumpd(name, 2, x, y, ra, rb);
		judge(&s, DULP(ra, rb), x);
	}
	report(&s);
}

static void test_f2(const char *name)
{
	f2 a = sym(ha, name), b = sym(hf, name);
	struct stat s = { name, 0, 0, 0, is_exact(name) };
	for (int i = 0; i < 40000; i++) {
		float x = rf(i % 997 == 0 ? (int)(rnd() % NSPECIAL) : 1000), y = rf(i < (int)NSPECIAL ? i : 1000);
		float ra = a(x, y), rb = b(x, y);
		double u = fulp(ra, rb);
		if (u < 0 || u > 1) dumpd(name, 2, x, y, ra, rb);
		judge(&s, FULP(ra, rb), x);
	}
	report(&s);
}

static void test_misc(void)
{
	/* fma, frexp, ldexp, modf, remquo, ilogb, lrint, llround, scalbn, nan */
	double (*fa)(double, double, double) = sym(ha, "fma"), (*ff)(double, double, double) = sym(hf, "fma");
	double (*fra)(double, int *) = sym(ha, "frexp"), (*frf)(double, int *) = sym(hf, "frexp");
	double (*la)(double, int) = sym(ha, "ldexp"), (*lf)(double, int) = sym(hf, "ldexp");
	double (*ma)(double, double *) = sym(ha, "modf"), (*mf)(double, double *) = sym(hf, "modf");
	double (*ra)(double, double, int *) = sym(ha, "remquo"), (*rf_)(double, double, int *) = sym(hf, "remquo");
	int (*ia)(double) = sym(ha, "ilogb"), (*if_)(double) = sym(hf, "ilogb");
	long (*lra)(double) = sym(ha, "lrint"), (*lrf)(double) = sym(hf, "lrint");
	long long (*lla)(double) = sym(ha, "llround"), (*llf)(double) = sym(hf, "llround");
	struct stat s = { "fma/frexp/...", 0, 0, 0, 1 };
	for (int i = 0; i < 40000; i++) {
		double x = rd(i), y = rd(1000), z = rd(1000);
		judge(&s, DULP(fa(x, y, z), ff(x, y, z)), x);
		int ea = 0, ef = 0;
		judge(&s, DULP(fra(x, &ea), frf(x, &ef)), x);
		checks++; if (ea != ef) fail("frexp", "exponent");
		int n = (int)(rnd() % 4200) - 2100;
		judge(&s, DULP(la(x, n), lf(x, n)), x);
		double pa = 0, pf = 0;
		judge(&s, DULP(ma(x, &pa), mf(x, &pf)), x);
		judge(&s, DULP(pa, pf), x);
		int qa = 0, qf = 0;
		judge(&s, DULP(ra(x, y, &qa), rf_(x, y, &qf)), x);
		/* C requires the sign and at least the low 3 bits of the quotient.
		 * For huge quotients whose low bits are 0, Apple returns 0 (no
		 * sign); msun keeps the sign. Both have the same low bits. */
		checks++;
		if ((qa & 7) != (qf & 7) || ((qa < 0) != (qf < 0) && qa != 0 && qf != 0)) {
			char buf[128];
			snprintf(buf, sizeof(buf), "x=%a y=%a apple q=%d finch q=%d", x, y, qa, qf);
			fail("remquo", buf);
		}
		checks++; if (ia(x) != if_(x)) fail("ilogb", "value");
		if (fabs(x) < 1e18) {
			checks++; if (lra(x) != lrf(x)) fail("lrint", "value");
			checks++; if (lla(x) != llf(x)) fail("llround", "value");
		}
	}
	double (*na)(const char *) = sym(ha, "nan"), (*nf)(const char *) = sym(hf, "nan");
	const char *tags[] = { "", "1", "0x7", "123456", "abc", "0xfffffffffffff" };
	for (size_t i = 0; i < sizeof(tags) / sizeof(tags[0]); i++) {
		double a = na(tags[i]), b = nf(tags[i]);
		checks++; if (memcmp(&a, &b, 8)) fail("nan", tags[i]);
	}
	report(&s);
}

static void test_classify(void)
{
	static const char *fns[] = { "__fpclassifyd", "__isnand", "__isinfd", "__isfinited", "__isnormald", "__signbitd",
	                             "__inline_isnand", "__inline_signbitd", NULL };
	for (int f = 0; fns[f]; f++) {
		int (*a)(double) = sym(ha, fns[f]), (*b)(double) = sym(hf, fns[f]);
		for (int i = 0; i < 4000; i++) {
			double x = rd(i);
			checks++; if (a(x) != b(x)) { fail(fns[f], "value"); break; }
		}
	}
	int (*ea)(void) = sym(ha, "__math_errhandling"), (*eb)(void) = sym(hf, "__math_errhandling");
	checks++; if (ea() != eb()) fail("__math_errhandling", "value");
}

static void test_complex(void)
{
	informational = 1;
	static const char *fns[] = { "cexp", "clog", "csqrt", "csin", "ccos", "ctan", "csinh", "ccosh", "ctanh",
	                             "casin", "cacos", "catan", "casinh", "cacosh", "catanh", "cproj", NULL };
	for (int f = 0; fns[f]; f++) {
		double complex (*a)(double complex) = sym(ha, fns[f]), (*b)(double complex) = sym(hf, fns[f]);
		struct stat s = { fns[f], 0, 0, 0, 0 };
		for (int i = 0; i < 20000; i++) {
			double complex z = CMPLX(rd(i % NSPECIAL == 0 ? 1000 : i), rd(1000));
			double complex ra = a(z), rb = b(z);
			double ur = dulp(creal(ra), creal(rb)), ui = dulp(cimag(ra), cimag(rb));
			if (dump && (ur < 0 || ur > 1 || ui < 0 || ui > 1))
				fprintf(dump, "%s c %a %a %a %a %a %a\n", fns[f], creal(z), cimag(z), creal(ra), cimag(ra), creal(rb), cimag(rb));
			judge(&s, DULP(creal(ra), creal(rb)), creal(z));
			judge(&s, DULP(cimag(ra), cimag(rb)), cimag(z));
		}
		report(&s);
	}
	double complex (*pa)(double complex, double complex) = sym(ha, "cpow"), (*pb)(double complex, double complex) = sym(hf, "cpow");
	struct stat s = { "cpow", 0, 0, 0, 0 };
	for (int i = 0; i < 20000; i++) {
		double complex z = CMPLX(rd(1000), rd(1000)), w = CMPLX(rd(1000) / 4, rd(1000) / 4);
		if (fabs(creal(z)) > 1e10 || fabs(cimag(z)) > 1e10) continue;
		double complex ra = pa(z, w), rb = pb(z, w);
		/* cpow is pow-via-exp/log: both libraries lose accuracy near overflow
		 * and cancellation; compare loosely. */
		double ur = dulp(creal(ra), creal(rb)), ui = dulp(cimag(ra), cimag(rb));
		checks++;
		if (ur < 0 || ui < 0) continue;   /* cpow special values: unspecified by C (report only) */
		if (ur > s.max) s.max = ur;
		if (ui > s.max) s.max = ui;
	}
	report(&s);
	informational = 0;
}

static void test_f16(void)
{
	static const char *u[] = { "__fabsf16", "__ceilf16", "__floorf16", "__truncf16", "__roundf16", "__rintf16", "__sqrtf16", NULL };
	static const char *b[] = { "__copysignf16", "__fmaxf16", "__fminf16", "__hypotf16", "__nextafterf16", NULL };
	for (int f = 0; u[f]; f++) {
		_Float16 (*pa)(_Float16) = sym(ha, u[f]), (*pb)(_Float16) = sym(hf, u[f]);
		for (uint32_t h = 0; h < 65536; h++) {
			_Float16 x; uint16_t hb = (uint16_t)h; memcpy(&x, &hb, 2);
			_Float16 ra = pa(x), rb = pb(x);
			checks++;
			if (memcmp(&ra, &rb, 2) && !(ra != ra && rb != rb)) { fail(u[f], "differs"); break; }
		}
	}
	for (int f = 0; b[f]; f++) {
		_Float16 (*pa)(_Float16, _Float16) = sym(ha, b[f]), (*pb)(_Float16, _Float16) = sym(hf, b[f]);
		for (int i = 0; i < 200000; i++) {
			uint16_t x0 = (uint16_t)rnd(), y0 = (uint16_t)rnd();
			_Float16 x, y; memcpy(&x, &x0, 2); memcpy(&y, &y0, 2);
			_Float16 ra = pa(x, y), rb = pb(x, y);
			checks++;
			if (memcmp(&ra, &rb, 2) && !(ra != ra && rb != rb)) { fail(b[f], "differs"); break; }
		}
	}
	_Float16 (*fa)(_Float16, _Float16, _Float16) = sym(ha, "__fmaf16"), (*fb)(_Float16, _Float16, _Float16) = sym(hf, "__fmaf16");
	for (int i = 0; i < 200000; i++) {
		uint16_t x0 = (uint16_t)rnd(), y0 = (uint16_t)rnd(), z0 = (uint16_t)rnd();
		_Float16 x, y, z; memcpy(&x, &x0, 2); memcpy(&y, &y0, 2); memcpy(&z, &z0, 2);
		_Float16 ra = fa(x, y, z), rb = fb(x, y, z);
		checks++;
		if (memcmp(&ra, &rb, 2) && !(ra != ra && rb != rb)) { fail("__fmaf16", "differs"); break; }
	}
}

static void test_simd(void)
{
	/* Apple's vector functions don't always keep the sign of zero that its
	 * scalar ones do (e.g. sin(-0) lane gives +0); Finch's lanes are the
	 * scalar functions. */
	informational = 1;
	static const char *fns[] = { "_simd_sin_d2", "_simd_exp_d2", "_simd_log_d2", "_simd_cbrt_d2", "_simd_tanpi_d2",
	                             "_simd_exp10_d2", "_simd_tgamma_d2", NULL };
	for (int f = 0; fns[f]; f++) {
		simd_double2 (*a)(simd_double2) = sym(ha, fns[f]), (*b)(simd_double2) = sym(hf, fns[f]);
		struct stat s = { fns[f], 0, 0, 0, 0 };
		for (int i = 0; i < 20000; i++) {
			simd_double2 x = { rd(i), rd(1000) }, ra = a(x), rb = b(x);
			judge(&s, DULP(ra.x, rb.x), x.x);
			judge(&s, DULP(ra.y, rb.y), x.y);
		}
		report(&s);
	}
	simd_float4 (*a)(simd_float4) = sym(ha, "_simd_sin_f4"), (*b)(simd_float4) = sym(hf, "_simd_sin_f4");
	struct stat s = { "_simd_sin_f4", 0, 0, 0, 0 };
	for (int i = 0; i < 20000; i++) {
		simd_float4 x = { rf(i), rf(1000), rf(1000), rf(1000) }, ra = a(x), rb = b(x);
		for (int l = 0; l < 4; l++) judge(&s, FULP(ra[l], rb[l]), x[l]);
	}
	report(&s);
	informational = 0;
}

static void test_invert(void)
{
	simd_double4x4 (*a)(simd_double4x4) = sym(ha, "__invert_d4"), (*b)(simd_double4x4) = sym(hf, "__invert_d4");
	simd_float3x3 (*fa)(simd_float3x3) = sym(ha, "__invert_f3"), (*fb)(simd_float3x3) = sym(hf, "__invert_f3");
	double worst = 0, worstf = 0;
	for (int i = 0; i < 20000; i++) {
		simd_double4x4 m;
		simd_float3x3 mf;
		for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) m.columns[c][r] = rd(1000) / 3;
		for (int c = 0; c < 3; c++) for (int r = 0; r < 3; r++) mf.columns[c][r] = (float)(rd(1000) / 3);
		simd_double4x4 ra = a(m), rb = b(m);
		simd_float3x3 rfa = fa(mf), rfb = fb(mf);
		double scale = 0, diff = 0;
		for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) {
			scale = fmax(scale, fabs(ra.columns[c][r]));
			diff = fmax(diff, fabs(ra.columns[c][r] - rb.columns[c][r]));
		}
		if (scale > 0 && isfinite(scale) && scale < 1e8) worst = fmax(worst, diff / scale);
		scale = diff = 0;
		for (int c = 0; c < 3; c++) for (int r = 0; r < 3; r++) {
			scale = fmax(scale, fabs(rfa.columns[c][r]));
			diff = fmax(diff, fabs(rfa.columns[c][r] - rfb.columns[c][r]));
		}
		if (scale > 0 && isfinite(scale) && scale < 1e4) worstf = fmax(worstf, diff / scale);
		checks += 2;
	}
	printf("  __invert_d4    max relative difference %.2e\n  __invert_f3    max relative difference %.2e\n", worst, worstf);
	if (worst > 1e-9) fail("__invert_d4", "relative difference");
	if (worstf > 1e-3) fail("__invert_f3", "relative difference");
}

static int sgn(double v) { return (v > 0) - (v < 0); }

/* Same sign, where Apple's has one: Apple's float/half predicates return NaN
 * when the exact value overflows the type (its own double versions, like
 * Finch's, return the signed overflow). */
static int same_sign(double apple, double finch) { return isnan(apple) || sgn(apple) == sgn(finch); }

/* Finite coordinates for the predicates. */
static double rg(void)
{
	double v;
	do v = rd(1000); while (!isfinite(v));
	return v;
}

static void gdump(const char *fn, double a, double f, int n, const double *c)
{
	if (!dump) return;
	fprintf(dump, "%s %a %a", fn, a, f);
	for (int k = 0; k < n; k++) fprintf(dump, " %a", c[k]);
	fprintf(dump, "\n");
}

static void test_geometry(void)
{
	double (*o2a)(simd_double2, simd_double2, simd_double2) = sym(ha, "_simd_orient_pd2"), (*o2b)(simd_double2, simd_double2, simd_double2) = sym(hf, "_simd_orient_pd2");
	double (*v2a)(simd_double2, simd_double2) = sym(ha, "_simd_orient_vd2"), (*v2b)(simd_double2, simd_double2) = sym(hf, "_simd_orient_vd2");
	double (*o3a)(const double *) = sym(ha, "_simd_orient_pd3"), (*o3b)(const double *) = sym(hf, "_simd_orient_pd3");
	double (*v3a)(const double *) = sym(ha, "_simd_orient_vd3"), (*v3b)(const double *) = sym(hf, "_simd_orient_vd3");
	double (*ica)(simd_double2, simd_double2, simd_double2, simd_double2) = sym(ha, "_simd_incircle_pd2"), (*icb)(simd_double2, simd_double2, simd_double2, simd_double2) = sym(hf, "_simd_incircle_pd2");
	double (*isa)(const double *) = sym(ha, "_simd_insphere_pd3"), (*isb)(const double *) = sym(hf, "_simd_insphere_pd3");
	float (*f2a)(simd_float2, simd_float2, simd_float2) = sym(ha, "_simd_orient_pf2"), (*f2b)(simd_float2, simd_float2, simd_float2) = sym(hf, "_simd_orient_pf2");
	float (*f3a)(simd_float3, simd_float3, simd_float3, simd_float3) = sym(ha, "_simd_orient_pf3"), (*f3b)(simd_float3, simd_float3, simd_float3, simd_float3) = sym(hf, "_simd_orient_pf3");
	float (*fsa)(simd_float3, simd_float3, simd_float3, simd_float3, simd_float3) = sym(ha, "_simd_insphere_pf3"), (*fsb)(simd_float3, simd_float3, simd_float3, simd_float3, simd_float3) = sym(hf, "_simd_insphere_pf3");
	for (int i = 0; i < 200000; i++) {
		/* Near-degenerate inputs: points on a line/plane/circle plus tiny perturbations. */
		int degenerate = i % 3 == 0;
		double base = (double)(int)(rnd() % 100), t = ldexp((double)(int64_t)rnd(), -63 - (int)(rnd() % 40));
		simd_double2 a = { rg(), rg() }, b = { rg(), rg() }, c;
		c = degenerate ? (simd_double2){ a.x + (b.x - a.x) * 3, a.y + (b.y - a.y) * 3 + t } : (simd_double2){ rg(), rg() };
		checks++;
		if (!same_sign(o2a(a, b, c), o2b(a, b, c))) {
			gdump("orient_pd2", o2a(a, b, c), o2b(a, b, c), 6, (double[]){ a.x, a.y, b.x, b.y, c.x, c.y });
			geometry_differences++;
		}
		checks++;
		if (!same_sign(v2a(a, b), v2b(a, b))) {
			gdump("orient_vd2", v2a(a, b), v2b(a, b), 4, (double[]){ a.x, a.y, b.x, b.y });
			geometry_differences++;
		}
		simd_double2 x = degenerate ? (simd_double2){ base, base + t } : (simd_double2){ rg(), rg() };
		checks++;
		if (!same_sign(ica(x, a, b, c), icb(x, a, b, c))) {
			gdump("incircle_pd2", ica(x, a, b, c), icb(x, a, b, c), 8, (double[]){ x.x, x.y, a.x, a.y, b.x, b.y, c.x, c.y });
			geometry_differences++;
		}
		simd_double3 p[5];
		for (int k = 0; k < 5; k++) p[k] = (simd_double3){ rg(), rg(), rg() };
		if (degenerate) p[3] = p[0] + (p[1] - p[0]) * 2 + (p[2] - p[0]) * 3 + (simd_double3){ 0, 0, t };
		checks++;
		if (!same_sign(o3a((const double *)p), o3b((const double *)p))) {
			gdump("orient_pd3", o3a((const double *)p), o3b((const double *)p), 12,
			    (double[]){ p[0].x, p[0].y, p[0].z, p[1].x, p[1].y, p[1].z, p[2].x, p[2].y, p[2].z, p[3].x, p[3].y, p[3].z });
			geometry_differences++;
		}
		checks++;
		if (!same_sign(v3a((const double *)p), v3b((const double *)p))) {
			gdump("orient_vd3", v3a((const double *)p), v3b((const double *)p), 9,
			    (double[]){ p[0].x, p[0].y, p[0].z, p[1].x, p[1].y, p[1].z, p[2].x, p[2].y, p[2].z });
			geometry_differences++;
		}
		checks++;
		if (!same_sign(isa((const double *)p), isb((const double *)p))) {
			double c[15];
			for (int k = 0; k < 5; k++) { c[3 * k] = p[k].x; c[3 * k + 1] = p[k].y; c[3 * k + 2] = p[k].z; }
			gdump("insphere_pd3", isa((const double *)p), isb((const double *)p), 15, c);
			geometry_differences++;
		}
		simd_float2 fa_ = { (float)a.x, (float)a.y }, fb_ = { (float)b.x, (float)b.y }, fc = { (float)c.x, (float)c.y };
		checks++;
		if (!same_sign(f2a(fa_, fb_, fc), f2b(fa_, fb_, fc))) {
			gdump("orient_pf2", f2a(fa_, fb_, fc), f2b(fa_, fb_, fc), 6, (double[]){ fa_.x, fa_.y, fb_.x, fb_.y, fc.x, fc.y });
			geometry_differences++;
		}
		simd_float3 q[5];
		for (int k = 0; k < 5; k++) q[k] = (simd_float3){ (float)p[k].x, (float)p[k].y, (float)p[k].z };
		double qc[15];
		for (int k = 0; k < 5; k++) { qc[3 * k] = q[k].x; qc[3 * k + 1] = q[k].y; qc[3 * k + 2] = q[k].z; }
		checks++;
		if (!same_sign(f3a(q[0], q[1], q[2], q[3]), f3b(q[0], q[1], q[2], q[3]))) {
			gdump("orient_pf3", f3a(q[0], q[1], q[2], q[3]), f3b(q[0], q[1], q[2], q[3]), 12, qc);
			geometry_differences++;
		}
		checks++;
		if (!same_sign(fsa(q[0], q[1], q[2], q[3], q[4]), fsb(q[0], q[1], q[2], q[3], q[4]))) {
			gdump("insphere_pf3", fsa(q[0], q[1], q[2], q[3], q[4]), fsb(q[0], q[1], q[2], q[3], q[4]), 15, qc);
			geometry_differences++;
		}
	}
}

static void test_fenv(void)
{
	int (*sra)(int) = sym(ha, "fesetround"), (*srb)(int) = sym(hf, "fesetround");
	int (*gra)(void) = sym(ha, "fegetround"), (*grb)(void) = sym(hf, "fegetround");
	int (*rea)(int) = sym(ha, "feraiseexcept"), (*reb)(int) = sym(hf, "feraiseexcept");
	int (*tea)(int) = sym(ha, "fetestexcept"), (*teb)(int) = sym(hf, "fetestexcept");
	int (*cea)(int) = sym(ha, "feclearexcept"), (*ceb)(int) = sym(hf, "feclearexcept");
	int (*fra)(void) = sym(ha, "__fegetfltrounds"), (*frb)(void) = sym(hf, "__fegetfltrounds");
	int modes[] = { FE_TONEAREST, FE_UPWARD, FE_DOWNWARD, FE_TOWARDZERO, 12345 };
	for (int i = 0; i < 5; i++) {
		int a = sra(modes[i]), ga = gra(), fla = fra();
		sra(FE_TONEAREST);
		int b = srb(modes[i]), gb = grb(), flb = frb();
		srb(FE_TONEAREST);
		checks++; if (a != b || ga != gb || fla != flb) fail("fesetround/fegetround", "mode");
	}
	for (int e = 0; e <= FE_ALL_EXCEPT; e++) {
		if (e & ~FE_ALL_EXCEPT) continue;
		cea(FE_ALL_EXCEPT); rea(e); int ta = tea(FE_ALL_EXCEPT); cea(FE_ALL_EXCEPT);
		ceb(FE_ALL_EXCEPT); reb(e); int tb = teb(FE_ALL_EXCEPT); ceb(FE_ALL_EXCEPT);
		checks++; if (ta != tb) fail("feraiseexcept/fetestexcept", "flags");
	}
	const fenv_t *da = sym(ha, "_FE_DFL_ENV"), *db = sym(hf, "_FE_DFL_ENV");
	const fenv_t *za = sym(ha, "_FE_DFL_DISABLE_DENORMS_ENV"), *zb = sym(hf, "_FE_DFL_DISABLE_DENORMS_ENV");
	checks += 2;
	if (memcmp(da, db, sizeof(fenv_t))) fail("_FE_DFL_ENV", "value");
	if (memcmp(za, zb, sizeof(fenv_t))) fail("_FE_DFL_DISABLE_DENORMS_ENV", "value");
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: libm-compare <finch libsystem_m.dylib> [-v]\n"); return 2; }
	verbose = argc > 2 && !strcmp(argv[2], "-v");
	if (getenv("LIBM_DUMP")) dump = fopen(getenv("LIBM_DUMP"), "w");
	ha = dlopen("/usr/lib/system/libsystem_m.dylib", RTLD_NOW | RTLD_LOCAL);
	hf = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!ha || !hf || ha == hf) { fprintf(stderr, "libm-compare: %s\n", dlerror()); return 2; }

	static const char *u[] = { "acos", "asin", "atan", "acosh", "asinh", "atanh", "cbrt", "cos", "sin", "tan", "cosh",
	                           "sinh", "tanh", "exp", "exp2", "expm1", "log", "log10", "log1p", "log2", "erf", "erfc",
	                           "tgamma", "lgamma", "sqrt", "ceil", "floor", "trunc", "round", "rint", "nearbyint",
	                           "fabs", "logb", "__sinpi", "__cospi", "__tanpi", "__exp10", "j0", "j1", "y0", "y1", NULL };
	static const char *b[] = { "atan2", "pow", "hypot", "fmod", "remainder", "fmin", "fmax", "fdim", "nextafter", "copysign", NULL };
	printf("double:\n");
	for (int i = 0; u[i]; i++) test_d1(u[i]);
	for (int i = 0; b[i]; i++) test_d2(b[i]);
	test_misc();
	printf("float:\n");
	for (int i = 0; u[i]; i++) {
		if (!strncmp(u[i], "j", 1) || !strncmp(u[i], "y", 1)) continue;
		char name[32];
		snprintf(name, sizeof(name), "%sf", u[i]);
		test_f1(name);
	}
	for (int i = 0; b[i]; i++) {
		char name[32];
		snprintf(name, sizeof(name), "%sf", b[i]);
		test_f2(name);
	}
	printf("complex:\n");
	test_complex();
	printf("other:\n");
	test_classify();
	test_f16();
	test_simd();
	test_invert();
	test_geometry();
	test_fenv();
	printf("libm-compare: %lu checks, %lu failures (%lu geometry-predicate differences from Apple: run geometry_judge.py)\n",
	    checks, failures, geometry_differences);
	return failures != 0;
}
