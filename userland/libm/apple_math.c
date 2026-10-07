/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Apple-specific scalar interfaces of libsystem_m, around FreeBSD msun:
 * <fenv.h> with Apple's arm64 fenv_t ({fpsr, fpcr}), the classification
 * helpers <math.h>'s macros call, __sinpi/__cospi/__tanpi, __sincos and the
 * struct-returning __sincos*_stret, __exp10, and the version and
 * error-handling queries. Values and layouts follow macOS 26.4's
 * <math.h>/<fenv.h> and library.
 */

#include <fenv.h>
#include <float.h>
#include <stddef.h>
#include <stdint.h>

/* Not <math.h>: it defines the __inline_* helpers as static inline
 * functions, and this file exports them. Values from <math.h>. */
#define FP_NAN          1
#define FP_INFINITE     2
#define FP_ZERO         3
#define FP_NORMAL       4
#define FP_SUBNORMAL    5
#define MATH_ERREXCEPT  2
struct __float2 { float __sinval; float __cosval; };
struct __double2 { double __sinval; double __cosval; };
double pow(double, double);
float powf(float, float);

#define EXPORT __attribute__((visibility("default")))

/* CORE-MATH's (correctly rounded) and msun's. */
double cr_sinpi(double), cr_cospi(double), cr_tanpi(double), cr_exp10(double), cr_lgamma(double);
float cr_sinpif(float), cr_cospif(float), cr_tanpif(float), cr_exp10f(float), cr_lgammaf(float);
void cr_sincos(double, double *, double *);
void cr_sincosf(float, float *, float *);
double scalbn(double, int);
float scalbnf(float, int);
extern int signgam;

/* ---- version and error handling ---- */

EXPORT const char __Libm_version[] = "@(#) Libm-3312.100.1 Finch (FreeBSD msun 14.5)";

/* math_errhandling: MATH_ERREXCEPT. Exceptions are raised; errno isn't set. */
EXPORT int __math_errhandling(void) { return MATH_ERREXCEPT; }

/* ---- fenv (arm64: FPSR holds the exception flags, FPCR the modes) ---- */

static inline uint64_t get_fpsr(void) { uint64_t v; __asm__ volatile("mrs %0, fpsr" : "=r"(v)); return v; }
static inline uint64_t get_fpcr(void) { uint64_t v; __asm__ volatile("mrs %0, fpcr" : "=r"(v)); return v; }
static inline void set_fpsr(uint64_t v) { __asm__ volatile("msr fpsr, %0" :: "r"(v)); }
static inline void set_fpcr(uint64_t v) { __asm__ volatile("msr fpcr, %0" :: "r"(v)); }

#define ROUND_MASK 0x00C00000ull

EXPORT const fenv_t _FE_DFL_ENV = { 0, 0 };
EXPORT const fenv_t _FE_DFL_DISABLE_DENORMS_ENV = { 0, 0x01000000 };   /* FPCR.FZ */

EXPORT int feclearexcept(int excepts)
{
	set_fpsr(get_fpsr() & ~(uint64_t)(excepts & FE_ALL_EXCEPT));
	return 0;
}

EXPORT int fegetexceptflag(fexcept_t *flagp, int excepts)
{
	*flagp = (fexcept_t)(get_fpsr() & (uint64_t)(excepts & FE_ALL_EXCEPT));
	return 0;
}

EXPORT int fesetexceptflag(const fexcept_t *flagp, int excepts)
{
	uint64_t mask = (uint64_t)(excepts & FE_ALL_EXCEPT);
	set_fpsr((get_fpsr() & ~mask) | (*flagp & mask));
	return 0;
}

/* Raise by computing an operation that signals each exception (so traps
 * fire if enabled), then make sure the flags are set. */
EXPORT int feraiseexcept(int excepts)
{
	volatile double zero = 0.0, one = 1.0, big = DBL_MAX, tiny = DBL_MIN, r;
	if (excepts & FE_INVALID) r = zero / zero;
	if (excepts & FE_DIVBYZERO) r = one / zero;
	if (excepts & FE_OVERFLOW) r = big * big;
	if (excepts & FE_UNDERFLOW) r = tiny * tiny;
	if (excepts & FE_INEXACT) r = one + tiny;
	(void)r;
	set_fpsr(get_fpsr() | (uint64_t)(excepts & FE_ALL_EXCEPT));
	return 0;
}

EXPORT int fetestexcept(int excepts)
{
	return (int)(get_fpsr() & (uint64_t)(excepts & FE_ALL_EXCEPT));
}

EXPORT int fegetround(void)
{
	return (int)(get_fpcr() & ROUND_MASK);
}

/* An invalid mode is returned as the (nonzero) failure value, as Apple's does. */
EXPORT int fesetround(int round)
{
	if ((uint64_t)(unsigned)round & ~ROUND_MASK)
		return round;
	set_fpcr((get_fpcr() & ~ROUND_MASK) | (uint64_t)round);
	return 0;
}

EXPORT int fegetenv(fenv_t *envp)
{
	envp->__fpsr = get_fpsr();
	envp->__fpcr = get_fpcr();
	return 0;
}

EXPORT int feholdexcept(fenv_t *envp)
{
	fegetenv(envp);
	set_fpsr(envp->__fpsr & ~(uint64_t)FE_ALL_EXCEPT);
	/* Non-stop mode: disable exception traps. */
	set_fpcr(envp->__fpcr & ~(uint64_t)(__fpcr_trap_invalid | __fpcr_trap_divbyzero |
	    __fpcr_trap_overflow | __fpcr_trap_underflow | __fpcr_trap_inexact | __fpcr_trap_denormal));
	return 0;
}

EXPORT int fesetenv(const fenv_t *envp)
{
	set_fpsr(envp->__fpsr);
	set_fpcr(envp->__fpcr);
	return 0;
}

EXPORT int feupdateenv(const fenv_t *envp)
{
	uint64_t raised = get_fpsr() & FE_ALL_EXCEPT;
	fesetenv(envp);
	feraiseexcept((int)raised);
	return 0;
}

/* FLT_ROUNDS: 0 toward zero, 1 nearest, 2 upward, 3 downward. */
EXPORT int __fegetfltrounds(void)
{
	switch (fegetround()) {
	case FE_TONEAREST: return 1;
	case FE_UPWARD: return 2;
	case FE_DOWNWARD: return 3;
	case FE_TOWARDZERO: return 0;
	default: return -1;
	}
}

/* ---- classification ----
 * These are Apple-private helpers, so they match Apple's library exactly.
 * One quirk: the exported __isnormal* (and __inline_isnormal*) are true for
 * subnormals too, as macOS 26.4's are; <math.h>'s isnormal() macro, compiled
 * inline, gives the C answer. */

static inline uint64_t dbits(double x) { uint64_t u; __builtin_memcpy(&u, &x, 8); return u; }
static inline uint32_t fbits(float x) { uint32_t u; __builtin_memcpy(&u, &x, 4); return u; }

#define CLASSIFY(bits, expmask, manmask)                                        \
	((((bits) & (expmask)) == (expmask)) ? (((bits) & (manmask)) ? FP_NAN : FP_INFINITE) : \
	 (((bits) & (expmask)) == 0) ? (((bits) & (manmask)) ? FP_SUBNORMAL : FP_ZERO) : FP_NORMAL)

EXPORT int __fpclassifyd(double x) { uint64_t b = dbits(x); return CLASSIFY(b, 0x7ff0000000000000ull, 0x000fffffffffffffull); }
EXPORT int __fpclassifyf(float x) { uint32_t b = fbits(x); return CLASSIFY(b, 0x7f800000u, 0x007fffffu); }
EXPORT int __fpclassifyl(long double x) { return __fpclassifyd((double)x); }

#define CLASS_FNS(suffix, T, classify)                                                          \
	EXPORT int __isfinite##suffix(T x) { int c = classify(x); return c != FP_NAN && c != FP_INFINITE; } \
	EXPORT int __isinf##suffix(T x) { return classify(x) == FP_INFINITE; }                  \
	EXPORT int __isnan##suffix(T x) { return classify(x) == FP_NAN; }                       \
	EXPORT int __isnormal##suffix(T x) { int c = classify(x); return c == FP_NORMAL || c == FP_SUBNORMAL; } \
	EXPORT int __inline_isfinite##suffix(T x) { return __isfinite##suffix(x); }            \
	EXPORT int __inline_isinf##suffix(T x) { return __isinf##suffix(x); }                  \
	EXPORT int __inline_isnan##suffix(T x) { return __isnan##suffix(x); }                  \
	EXPORT int __inline_isnormal##suffix(T x) { return __isnormal##suffix(x); }

CLASS_FNS(d, double, __fpclassifyd)
CLASS_FNS(f, float, __fpclassifyf)
CLASS_FNS(l, long double, __fpclassifyl)

EXPORT int __signbitd(double x) { return (int)(dbits(x) >> 63); }
EXPORT int __signbitf(float x) { return (int)(fbits(x) >> 31); }
EXPORT int __signbitl(long double x) { return __signbitd((double)x); }
EXPORT int __inline_signbitd(double x) { return __signbitd(x); }
EXPORT int __inline_signbitf(float x) { return __signbitf(x); }
EXPORT int __inline_signbitl(long double x) { return __signbitl(x); }

/* Legacy BSD isinf() and isnan(), still exported as functions. */
EXPORT int isinf(double x) { return __isinfd(x); }
EXPORT int isnan(double x) { return __isnand(x); }

/* ---- functions FreeBSD keeps in libc ---- */

EXPORT double fabs(double x) { return __builtin_fabs(x); }

EXPORT double ldexp(double x, int n) { return scalbn(x, n); }
EXPORT float ldexpf(float x, int n) { return scalbnf(x, n); }

EXPORT double modf(double x, double *iptr)
{
	double i = __builtin_trunc(x);
	*iptr = i;
	if (__isinfd(x))
		return __builtin_copysign(0.0, x);
	return __builtin_copysign(x - i, x);
}

/* ---- pi-scaled trigonometry, sincos, exp10 (CORE-MATH) ---- */

EXPORT double __sinpi(double x) { return cr_sinpi(x); }
EXPORT double __cospi(double x) { return cr_cospi(x); }
EXPORT double __tanpi(double x) { return cr_tanpi(x); }
EXPORT float __sinpif(float x) { return cr_sinpif(x); }
EXPORT float __cospif(float x) { return cr_cospif(x); }
EXPORT float __tanpif(float x) { return cr_tanpif(x); }

EXPORT void __sincos(double x, double *s, double *c) { cr_sincos(x, s, c); }
EXPORT void __sincosf(float x, float *s, float *c) { cr_sincosf(x, s, c); }
EXPORT void __sincospi(double x, double *s, double *c) { *s = cr_sinpi(x); *c = cr_cospi(x); }
EXPORT void __sincospif(float x, float *s, float *c) { *s = cr_sinpif(x); *c = cr_cospif(x); }

EXPORT struct __double2 __sincos_stret(double x) { struct __double2 r; cr_sincos(x, &r.__sinval, &r.__cosval); return r; }
EXPORT struct __float2 __sincosf_stret(float x) { struct __float2 r; cr_sincosf(x, &r.__sinval, &r.__cosval); return r; }
EXPORT struct __double2 __sincospi_stret(double x) { struct __double2 r = { cr_sinpi(x), cr_cospi(x) }; return r; }
EXPORT struct __float2 __sincospif_stret(float x) { struct __float2 r = { cr_sinpif(x), cr_cospif(x) }; return r; }

EXPORT double __exp10(double x) { return cr_exp10(x); }
EXPORT float __exp10f(float x) { return cr_exp10f(x); }

/* ---- lgamma: CORE-MATH's value, the sign of Gamma(x) here ---- */

/* CORE-MATH stores a sign of its own; lgamma/lgamma_r set it below. */
__attribute__((visibility("hidden"))) int __finch_cr_signgam;

/* Sign of Gamma(x): negative exactly for x < 0 with an odd floor. Poles
 * (zero and the negative integers) report +1, except -0 (-1); NaN +1. */
static int gamma_sign(double x)
{
	if (x == 0)
		return __builtin_signbit(x) ? -1 : 1;
	if (!(x < 0))
		return 1;
	double f = __builtin_floor(x);
	if (f == x)
		return 1;
	double half = f * 0.5;
	return half != __builtin_floor(half) ? -1 : 1;
}

EXPORT double lgamma_r(double x, int *sign) { *sign = gamma_sign(x); return cr_lgamma(x); }
EXPORT float lgammaf_r(float x, int *sign) { *sign = gamma_sign(x); return cr_lgammaf(x); }
EXPORT double lgamma(double x) { return lgamma_r(x, &signgam); }
EXPORT float lgammaf(float x) { return lgammaf_r(x, &signgam); }

/* ---- support msun objects need, kept out of libsystem_c ---- */

/* Apple's <ctype.h> inlines reach into libc's rune tables; msun's nan()
 * parsing only needs ASCII hex digits (freebsd_compat.h maps them here). */
__attribute__((visibility("hidden"))) int __finch_isxdigit(int c)
{
	return (c >= '0' && c <= '9') || ((c | 32) >= 'a' && (c | 32) <= 'f');
}

__attribute__((visibility("hidden"))) void *memset(void *s, int c, size_t n)
{
	volatile unsigned char *p = s;
	while (n--) *p++ = (unsigned char)c;
	return s;
}

/* Struct copies (exact_predicates.c) compile to memcpy calls. */
__attribute__((visibility("hidden"))) void *memcpy(void *restrict d, const void *restrict s, size_t n)
{
	unsigned char *dp = d;
	const unsigned char *sp = s;
	uint64_t *d8 = d;
	const uint64_t *s8 = s;
	if ((((uintptr_t)d | (uintptr_t)s) & 7) == 0) {
		while (n >= 8) {
			*d8++ = *s8++;
			n -= 8;
		}
		dp = (unsigned char *)d8;
		sp = (const unsigned char *)s8;
	}
	while (n--)
		*(volatile unsigned char *)dp++ = *sp++;
	return d;
}

__attribute__((visibility("hidden"))) void bzero(void *s, size_t n)
{
	memset(s, 0, n);
}

/* FreeBSD's <math.h> classification macros call these; not exported. */
__attribute__((visibility("hidden"))) int __isinf(double x) { return __isinfd(x); }
__attribute__((visibility("hidden"))) int __isfinite(double x) { return __isfinited(x); }
__attribute__((visibility("hidden"))) int __isnormal(double x) { return __isnormald(x); }
__attribute__((visibility("hidden"))) int __signbit(double x) { return __signbitd(x); }

/* fmin/fmax as the arm64 FMINNM/FMAXNM instructions compute them (as
 * Apple's do): a quiet NaN is ignored, a signaling NaN gives a NaN, and
 * -0 < +0. */
EXPORT double fmin(double x, double y) { double r; __asm__("fminnm %d0, %d1, %d2" : "=w"(r) : "w"(x), "w"(y)); return r; }
EXPORT double fmax(double x, double y) { double r; __asm__("fmaxnm %d0, %d1, %d2" : "=w"(r) : "w"(x), "w"(y)); return r; }
EXPORT float fminf(float x, float y) { float r; __asm__("fminnm %s0, %s1, %s2" : "=w"(r) : "w"(x), "w"(y)); return r; }
EXPORT float fmaxf(float x, float y) { float r; __asm__("fmaxnm %s0, %s1, %s2" : "=w"(r) : "w"(x), "w"(y)); return r; }

/* ---- nan(): Apple's tag rules ---- */

/* The tag is an unsigned integer as strtoull reads it with base 0 (decimal,
 * 0-prefixed octal, 0x-prefixed hex), wrapping modulo 2^64; anything else
 * (a sign, spaces, other characters) gives payload 0. The payload fills the
 * significand below the quiet bit. */
static uint64_t nan_payload(const char *tag)
{
	const unsigned char *p = (const unsigned char *)tag;
	unsigned base = 10;
	uint64_t v = 0;
	if (!p || !*p)
		return 0;
	if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
		base = 16;
		p += 2;
		if (!*p)
			return 0;
	} else if (p[0] == '0') {
		base = 8;
	}
	for (; *p; p++) {
		unsigned d;
		if (*p >= '0' && *p <= '9')
			d = *p - '0';
		else if ((*p | 32) >= 'a' && (*p | 32) <= 'f')
			d = (*p | 32) - 'a' + 10;
		else
			return 0;
		if (d >= base)
			return 0;
		v = v * base + d;
	}
	return v;
}

EXPORT double nan(const char *tag)
{
	uint64_t bits = 0x7ff8000000000000ull | (nan_payload(tag) & 0x000fffffffffffffull);
	double d;
	__builtin_memcpy(&d, &bits, 8);
	return d;
}

EXPORT float nanf(const char *tag)
{
	uint32_t bits = 0x7fc00000u | (uint32_t)(nan_payload(tag) & 0x003fffffu);
	float f;
	__builtin_memcpy(&f, &bits, 4);
	return f;
}
