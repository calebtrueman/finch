/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_m's <simd/...> and _Float16 interfaces:
 *  - _Float16 math (__ceilf16 ...): computed in float or double, where the
 *    wider result rounds once to the correct half-precision value;
 *  - vector math (_simd_<fn>_d2/_f4, __sin_d2 ...): the scalar function on
 *    each lane;
 *  - matrix inverses (__invert_*): adjugate over determinant, in double;
 *  - the matrix_identity_* constants;
 *  - geometry predicates (_simd_orient/incircle/insphere_*): Shewchuk's
 *    adaptive-precision predicates (public domain), so the sign is always
 *    exact. Float and half inputs convert to double exactly.
 * Declarations are the SDK's (<simd/simd.h>, <math.h>).
 */

#include <math.h>
#include <simd/simd.h>
#include <stdint.h>

#define EXPORT __attribute__((visibility("default")))

/* ---- _Float16 ---- */

EXPORT _Float16 __fabsf16(_Float16 x) { return (_Float16)__builtin_fabsf((float)x); }
EXPORT _Float16 __copysignf16(_Float16 x, _Float16 y) { return (_Float16)__builtin_copysignf((float)x, (float)y); }
EXPORT _Float16 __ceilf16(_Float16 x) { return (_Float16)__builtin_ceilf((float)x); }
EXPORT _Float16 __floorf16(_Float16 x) { return (_Float16)__builtin_floorf((float)x); }
EXPORT _Float16 __truncf16(_Float16 x) { return (_Float16)__builtin_truncf((float)x); }
EXPORT _Float16 __roundf16(_Float16 x) { return (_Float16)__builtin_roundf((float)x); }
EXPORT _Float16 __rintf16(_Float16 x) { return (_Float16)__builtin_rintf((float)x); }
EXPORT _Float16 __fmaxf16(_Float16 x, _Float16 y) { return (_Float16)__builtin_fmaxf((float)x, (float)y); }
EXPORT _Float16 __fminf16(_Float16 x, _Float16 y) { return (_Float16)__builtin_fminf((float)x, (float)y); }
/* float's 24-bit significand covers twice half's 11 plus two bits, so the
 * float result rounds correctly to half. */
EXPORT _Float16 __sqrtf16(_Float16 x) { return (_Float16)__builtin_sqrtf((float)x); }
EXPORT _Float16 __hypotf16(_Float16 x, _Float16 y) { return (_Float16)hypotf((float)x, (float)y); }
/* x*y is exact in double; one rounding to double then to half. */
EXPORT _Float16 __fmaf16(_Float16 x, _Float16 y, _Float16 z) { return (_Float16)__builtin_fma((double)x, (double)y, (double)z); }

EXPORT _Float16 __nextafterf16(_Float16 x, _Float16 y)
{
	if (x != x || y != y)
		return (_Float16)((float)x + (float)y);       /* NaN */
	if (x == y)
		return y;
	unsigned short b;
	__builtin_memcpy(&b, &x, 2);
	if (x == 0)
		b = (unsigned short)((y > 0 ? 0 : 0x8000) | 1);
	else if ((x < y) == (x > 0))
		b++;
	else
		b--;
	_Float16 r;
	__builtin_memcpy(&r, &b, 2);
	return r;
}

/* ---- vector math: the scalar function on each lane ---- */

#define V1(name, fn, fnf)                                                                   \
	EXPORT simd_double2 _simd_##name##_d2(simd_double2 x) { return (simd_double2){ fn(x.x), fn(x.y) }; } \
	EXPORT simd_float4 _simd_##name##_f4(simd_float4 x) { return (simd_float4){ fnf(x.x), fnf(x.y), fnf(x.z), fnf(x.w) }; }
#define V2(name, fn, fnf)                                                                   \
	EXPORT simd_double2 _simd_##name##_d2(simd_double2 x, simd_double2 y) { return (simd_double2){ fn(x.x, y.x), fn(x.y, y.y) }; } \
	EXPORT simd_float4 _simd_##name##_f4(simd_float4 x, simd_float4 y) {                    \
		return (simd_float4){ fnf(x.x, y.x), fnf(x.y, y.y), fnf(x.z, y.z), fnf(x.w, y.w) }; }

V1(acos, acos, acosf) V1(acosh, acosh, acoshf) V1(asin, asin, asinf) V1(asinh, asinh, asinhf)
V1(atan, atan, atanf) V1(atanh, atanh, atanhf) V1(cbrt, cbrt, cbrtf) V1(cos, cos, cosf)
V1(cosh, cosh, coshf) V1(cospi, __cospi, __cospif) V1(erf, erf, erff) V1(erfc, erfc, erfcf)
V1(exp, exp, expf) V1(exp10, __exp10, __exp10f) V1(exp2, exp2, exp2f) V1(expm1, expm1, expm1f)
V1(lgamma, lgamma, lgammaf) V1(log, log, logf) V1(log10, log10, log10f) V1(log1p, log1p, log1pf)
V1(log2, log2, log2f) V1(round, round, roundf) V1(sin, sin, sinf) V1(sinh, sinh, sinhf)
V1(sinpi, __sinpi, __sinpif) V1(tan, tan, tanf) V1(tanh, tanh, tanhf) V1(tanpi, __tanpi, __tanpif)
V1(tgamma, tgamma, tgammaf)
V2(atan2, atan2, atan2f) V2(fmod, fmod, fmodf) V2(hypot, hypot, hypotf)
V2(nextafter, nextafter, nextafterf) V2(pow, pow, powf) V2(remainder, remainder, remainderf)

EXPORT simd_double2 _simd_fma_d2(simd_double2 x, simd_double2 y, simd_double2 z)
{
	return (simd_double2){ fma(x.x, y.x, z.x), fma(x.y, y.y, z.y) };
}

EXPORT simd_float4 _simd_fma_f4(simd_float4 x, simd_float4 y, simd_float4 z)
{
	return (simd_float4){ fmaf(x.x, y.x, z.x), fmaf(x.y, y.y, z.y), fmaf(x.z, y.z, z.z), fmaf(x.w, y.w, z.w) };
}

EXPORT void _simd_sincos_d2(simd_double2 x, simd_double2 *s, simd_double2 *c)
{
	*s = _simd_sin_d2(x);
	*c = _simd_cos_d2(x);
}

EXPORT void _simd_sincos_f4(simd_float4 x, simd_float4 *s, simd_float4 *c)
{
	*s = _simd_sin_f4(x);
	*c = _simd_cos_f4(x);
}

EXPORT void _simd_sincospi_d2(simd_double2 x, simd_double2 *s, simd_double2 *c)
{
	*s = _simd_sinpi_d2(x);
	*c = _simd_cospi_d2(x);
}

EXPORT void _simd_sincospi_f4(simd_float4 x, simd_float4 *s, simd_float4 *c)
{
	*s = _simd_sinpi_f4(x);
	*c = _simd_cospi_f4(x);
}

/* Older names the same functions also have. */
EXPORT simd_double2 __sin_d2(simd_double2 x) { return _simd_sin_d2(x); }
EXPORT simd_double2 __cos_d2(simd_double2 x) { return _simd_cos_d2(x); }
EXPORT simd_float4 __sin_f4(simd_float4 x) { return _simd_sin_f4(x); }
EXPORT simd_float4 __cos_f4(simd_float4 x) { return _simd_cos_f4(x); }

/* ---- matrices ---- */

EXPORT const simd_double2x2 matrix_identity_double2x2 = { .columns = { { 1, 0 }, { 0, 1 } } };
EXPORT const simd_double3x3 matrix_identity_double3x3 = { .columns = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } };
EXPORT const simd_double4x4 matrix_identity_double4x4 = { .columns = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } };
EXPORT const simd_float2x2 matrix_identity_float2x2 = { .columns = { { 1, 0 }, { 0, 1 } } };
EXPORT const simd_float3x3 matrix_identity_float3x3 = { .columns = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } };
EXPORT const simd_float4x4 matrix_identity_float4x4 = { .columns = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } };
EXPORT const simd_half2x2 matrix_identity_half2x2 = { .columns = { { 1, 0 }, { 0, 1 } } };
EXPORT const simd_half3x3 matrix_identity_half3x3 = { .columns = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } };
EXPORT const simd_half4x4 matrix_identity_half4x4 = { .columns = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } };

/* Inverses by adjugate / determinant, in double; a singular matrix gives
 * infinities or NaNs, as division by a zero determinant does. m[c][r] is
 * column c, row r. */
static void inverse2(const double m[2][2], double r[2][2])
{
	double det = m[0][0] * m[1][1] - m[1][0] * m[0][1];
	double inv = 1.0 / det;
	r[0][0] = m[1][1] * inv;
	r[0][1] = -m[0][1] * inv;
	r[1][0] = -m[1][0] * inv;
	r[1][1] = m[0][0] * inv;
}

static void inverse3(const double m[3][3], double r[3][3])
{
	double c00 = m[1][1] * m[2][2] - m[2][1] * m[1][2];
	double c01 = m[2][1] * m[0][2] - m[0][1] * m[2][2];
	double c02 = m[0][1] * m[1][2] - m[1][1] * m[0][2];
	double det = m[0][0] * c00 + m[1][0] * c01 + m[2][0] * c02;
	double inv = 1.0 / det;
	r[0][0] = c00 * inv;
	r[0][1] = c01 * inv;
	r[0][2] = c02 * inv;
	r[1][0] = (m[2][0] * m[1][2] - m[1][0] * m[2][2]) * inv;
	r[1][1] = (m[0][0] * m[2][2] - m[2][0] * m[0][2]) * inv;
	r[1][2] = (m[1][0] * m[0][2] - m[0][0] * m[1][2]) * inv;
	r[2][0] = (m[1][0] * m[2][1] - m[2][0] * m[1][1]) * inv;
	r[2][1] = (m[2][0] * m[0][1] - m[0][0] * m[2][1]) * inv;
	r[2][2] = (m[0][0] * m[1][1] - m[1][0] * m[0][1]) * inv;
}

static void inverse4(const double m[4][4], double r[4][4])
{
	/* a = m as rows-of-columns; cofactor expansion with 2x2 sub-determinants. */
	double s0 = m[0][0] * m[1][1] - m[1][0] * m[0][1];
	double s1 = m[0][0] * m[1][2] - m[1][0] * m[0][2];
	double s2 = m[0][0] * m[1][3] - m[1][0] * m[0][3];
	double s3 = m[0][1] * m[1][2] - m[1][1] * m[0][2];
	double s4 = m[0][1] * m[1][3] - m[1][1] * m[0][3];
	double s5 = m[0][2] * m[1][3] - m[1][2] * m[0][3];
	double c5 = m[2][2] * m[3][3] - m[3][2] * m[2][3];
	double c4 = m[2][1] * m[3][3] - m[3][1] * m[2][3];
	double c3 = m[2][1] * m[3][2] - m[3][1] * m[2][2];
	double c2 = m[2][0] * m[3][3] - m[3][0] * m[2][3];
	double c1 = m[2][0] * m[3][2] - m[3][0] * m[2][2];
	double c0 = m[2][0] * m[3][1] - m[3][0] * m[2][1];
	double det = s0 * c5 - s1 * c4 + s2 * c3 + s3 * c2 - s4 * c1 + s5 * c0;
	double inv = 1.0 / det;
	r[0][0] = (m[1][1] * c5 - m[1][2] * c4 + m[1][3] * c3) * inv;
	r[0][1] = (-m[0][1] * c5 + m[0][2] * c4 - m[0][3] * c3) * inv;
	r[0][2] = (m[3][1] * s5 - m[3][2] * s4 + m[3][3] * s3) * inv;
	r[0][3] = (-m[2][1] * s5 + m[2][2] * s4 - m[2][3] * s3) * inv;
	r[1][0] = (-m[1][0] * c5 + m[1][2] * c2 - m[1][3] * c1) * inv;
	r[1][1] = (m[0][0] * c5 - m[0][2] * c2 + m[0][3] * c1) * inv;
	r[1][2] = (-m[3][0] * s5 + m[3][2] * s2 - m[3][3] * s1) * inv;
	r[1][3] = (m[2][0] * s5 - m[2][2] * s2 + m[2][3] * s1) * inv;
	r[2][0] = (m[1][0] * c4 - m[1][1] * c2 + m[1][3] * c0) * inv;
	r[2][1] = (-m[0][0] * c4 + m[0][1] * c2 - m[0][3] * c0) * inv;
	r[2][2] = (m[3][0] * s4 - m[3][1] * s2 + m[3][3] * s0) * inv;
	r[2][3] = (-m[2][0] * s4 + m[2][1] * s2 - m[2][3] * s0) * inv;
	r[3][0] = (-m[1][0] * c3 + m[1][1] * c1 - m[1][2] * c0) * inv;
	r[3][1] = (m[0][0] * c3 - m[0][1] * c1 + m[0][2] * c0) * inv;
	r[3][2] = (-m[3][0] * s3 + m[3][1] * s1 - m[3][2] * s0) * inv;
	r[3][3] = (m[2][0] * s3 - m[2][1] * s1 + m[2][2] * s0) * inv;
}

#define INVERT(name, MT, n, inverse)                                    \
	EXPORT MT name(MT x)                                                \
	{                                                                   \
		double m[n][n], r[n][n];                                    \
		for (int c = 0; c < n; c++)                                 \
			for (int i = 0; i < n; i++)                         \
				m[c][i] = (double)x.columns[c][i];          \
		inverse((const double (*)[n])m, r);                         \
		MT out;                                                     \
		for (int c = 0; c < n; c++)                                 \
			for (int i = 0; i < n; i++)                         \
				out.columns[c][i] = r[c][i];                \
		return out;                                                 \
	}

INVERT(__invert_d2, simd_double2x2, 2, inverse2)
INVERT(__invert_d3, simd_double3x3, 3, inverse3)
INVERT(__invert_d4, simd_double4x4, 4, inverse4)
INVERT(__invert_f2, simd_float2x2, 2, inverse2)
INVERT(__invert_f3, simd_float3x3, 3, inverse3)
INVERT(__invert_f4, simd_float4x4, 4, inverse4)
INVERT(__invert_h2, simd_half2x2, 2, inverse2)
INVERT(__invert_h3, simd_half3x3, 3, inverse3)
INVERT(__invert_h4, simd_half4x4, 4, inverse4)

/* ---- geometry predicates (Shewchuk, predicates.c) ---- */

void exactinit(void);
double orient2d(double *pa, double *pb, double *pc);
double orient3d(double *pa, double *pb, double *pc, double *pd);
double incircle(double *pa, double *pb, double *pc, double *pd);
double insphere(double *pa, double *pb, double *pc, double *pd, double *pe);

/* exactinit() computes the predicates' error bounds; it's deterministic,
 * so concurrent first calls just store the same values. (No static
 * initializer: Apple's libsystem_m has none.) */
static int predicates_ready;
static inline void predicates_init(void)
{
	if (!__atomic_load_n(&predicates_ready, __ATOMIC_ACQUIRE)) {
		exactinit();
		__atomic_store_n(&predicates_ready, 1, __ATOMIC_RELEASE);
	}
}

/* Narrow a double result keeping its sign: a nonzero value never becomes 0. */
static float to_float(double v)
{
	float f = (float)v;
	return (f == 0 && v != 0) ? __builtin_copysignf(0x1p-149f, (float)v) : f;
}

static _Float16 to_half(double v)
{
	_Float16 h = (_Float16)v;
	return (h == 0 && v != 0) ? (_Float16)__builtin_copysignf(0x1p-24f, (float)v) : h;
}

/*
 * Shewchuk's predicates are exact only while no intermediate product
 * overflows or underflows. The determinants are homogeneous (degree 2 for
 * orient2d, 3 for orient3d, 4 for incircle, 5 for insphere), so scaling every
 * coordinate by 2^k scales the result by 2^(k*degree) > 0: the sign is
 * unchanged and the scaling itself is exact. Coordinates are brought to a
 * magnitude near 2^limit for their degree, and the result is scaled back
 * (saturating to the signed overflow or the smallest subnormal).
 */
static int exponent_of(double x)
{
	if (x == 0 || x != x || __builtin_isinf(x))
		return 0;
	int e;
	(void)__builtin_frexp(x, &e);
	return e;
}

static double scale2(double x, int k)
{
	/* x * 2^k without libm (k may be large). */
	while (k > 1000) { x *= 0x1p1000; k -= 1000; }
	while (k < -1000) { x *= 0x1p-1000; k += 1000; }
	uint64_t bits = (uint64_t)(k + 1023) << 52;
	double p;
	__builtin_memcpy(&p, &bits, 8);
	return x * p;
}

/* Scale n coordinates in place; returns k (coordinates were multiplied by 2^k). */
static int normalize(double *c, int n, int limit)
{
	int emax = -100000;
	for (int i = 0; i < n; i++)
		if (c[i] != 0 && exponent_of(c[i]) > emax)
			emax = exponent_of(c[i]);
	if (emax == -100000)
		return 0;
	int k = limit - emax;
	for (int i = 0; i < n; i++)
		c[i] = scale2(c[i], k);
	return k;
}

static double unscale(double v, int k, int degree)
{
	if (v == 0 || v != v)
		return v;
	long e = -(long)k * degree;
	if (e > 2100) e = 2100;
	if (e < -2200) e = -2200;
	double r = scale2(v, (int)e);
	if (r == 0)
		r = __builtin_copysign(0x1p-1074, v);   /* keep the sign */
	return r;
}

/* Inputs spanning more than this many binary orders of magnitude can
 * underflow inside the adaptive predicates even after scaling; their sign
 * comes from exact integer arithmetic (exact_predicates.c). */
#define WIDE_RANGE 200

int __finch_exact_orient2d(const double *, const double *, const double *);
int __finch_exact_orient3d(const double *, const double *, const double *, const double *);
int __finch_exact_incircle(const double *, const double *, const double *, const double *);
int __finch_exact_insphere(const double *, const double *, const double *, const double *, const double *);

static int wide_range(const double *c, int n)
{
	int lo = 100000, hi = -100000;
	for (int i = 0; i < n; i++) {
		if (c[i] == 0) continue;
		int e = exponent_of(c[i]);
		if (e < lo) lo = e;
		if (e > hi) hi = e;
	}
	return hi - lo > WIDE_RANGE;
}

/* The approximate value with the exact sign. */
static double with_sign(double approx, int sign)
{
	if (sign == 0)
		return 0.0;
	double m = __builtin_fabs(approx);
	if (m == 0 || m != m)
		m = 0x1p-1074;
	return sign > 0 ? m : -m;
}

/* Signs follow <simd/geometry.h>: orient is positive for counterclockwise
 * (2d) or right-handed (3d); incircle/insphere are positive when x is
 * inside. */
static double orient_v2(const double x[2], const double y[2])
{
	predicates_init();
	double c[4] = { x[0], x[1], y[0], y[1] }, o[2] = { 0, 0 };
	int wide = wide_range(c, 4), sign = wide ? __finch_exact_orient2d(o, x, y) : 0;
	int k = normalize(c, 4, 400);
	double r = unscale(orient2d(o, c, c + 2), k, 2);
	return wide ? with_sign(r, sign) : r;
}

static double orient_v3(const double x[3], const double y[3], const double z[3])
{
	predicates_init();
	double c[9] = { x[0], x[1], x[2], y[0], y[1], y[2], z[0], z[1], z[2] }, o[3] = { 0, 0, 0 };
	int wide = wide_range(c, 9), sign = wide ? __finch_exact_orient3d(x, y, z, o) : 0;
	int k = normalize(c, 9, 250);
	double r = unscale(orient3d(c, c + 3, c + 6, o), k, 3);
	return wide ? with_sign(r, sign) : r;
}

static double orient_p2(const double a[2], const double b[2], const double c[2])
{
	predicates_init();
	double p[6] = { a[0], a[1], b[0], b[1], c[0], c[1] };
	int wide = wide_range(p, 6), sign = wide ? __finch_exact_orient2d(a, b, c) : 0;
	int k = normalize(p, 6, 400);
	double r = unscale(orient2d(p, p + 2, p + 4), k, 2);
	return wide ? with_sign(r, sign) : r;
}

static double orient_p3(const double a[3], const double b[3], const double c[3], const double d[3])
{
	predicates_init();
	double p[12] = { a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2], d[0], d[1], d[2] };
	int wide = wide_range(p, 12), sign = wide ? __finch_exact_orient3d(a, b, c, d) : 0;
	int k = normalize(p, 12, 250);
	double r = unscale(orient3d(p, p + 3, p + 6, p + 9), k, 3);
	return wide ? with_sign(r, sign) : r;
}

static double incircle_p2(const double x[2], const double a[2], const double b[2], const double c[2])
{
	predicates_init();
	double p[8] = { a[0], a[1], b[0], b[1], c[0], c[1], x[0], x[1] };
	int wide = wide_range(p, 8), sign = wide ? __finch_exact_incircle(a, b, c, x) : 0;
	int k = normalize(p, 8, 180);
	double r = unscale(incircle(p, p + 2, p + 4, p + 6), k, 4);
	return wide ? with_sign(r, sign) : r;
}

static double insphere_p3(const double x[3], const double a[3], const double b[3], const double c[3], const double d[3])
{
	predicates_init();
	double p[15] = { a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2], d[0], d[1], d[2], x[0], x[1], x[2] };
	int wide = wide_range(p, 15), sign = wide ? __finch_exact_insphere(a, b, c, d, x) : 0;
	int k = normalize(p, 15, 140);
	double r = unscale(insphere(p, p + 3, p + 6, p + 9, p + 12), k, 5);
	return wide ? with_sign(r, sign) : r;
}

#define D2(v) ((const double[2]){ (double)(v).x, (double)(v).y })
#define D3(v) ((const double[3]){ (double)(v).x, (double)(v).y, (double)(v).z })

EXPORT double _simd_orient_vd2(simd_double2 x, simd_double2 y) { return orient_v2(D2(x), D2(y)); }
EXPORT float _simd_orient_vf2(simd_float2 x, simd_float2 y) { return to_float(orient_v2(D2(x), D2(y))); }
EXPORT _Float16 _simd_orient_vh2(simd_half2 x, simd_half2 y) { return to_half(orient_v2(D2(x), D2(y))); }

/* The double 3d forms take an array of simd_double3 (4 doubles apart). */
EXPORT double _simd_orient_vd3(const double *v) { return orient_v3(v, v + 4, v + 8); }
EXPORT float _simd_orient_vf3(simd_float3 x, simd_float3 y, simd_float3 z) { return to_float(orient_v3(D3(x), D3(y), D3(z))); }
EXPORT _Float16 _simd_orient_vh3(simd_half3 x, simd_half3 y, simd_half3 z) { return to_half(orient_v3(D3(x), D3(y), D3(z))); }

EXPORT double _simd_orient_pd2(simd_double2 a, simd_double2 b, simd_double2 c) { return orient_p2(D2(a), D2(b), D2(c)); }
EXPORT float _simd_orient_pf2(simd_float2 a, simd_float2 b, simd_float2 c) { return to_float(orient_p2(D2(a), D2(b), D2(c))); }
EXPORT _Float16 _simd_orient_ph2(simd_half2 a, simd_half2 b, simd_half2 c) { return to_half(orient_p2(D2(a), D2(b), D2(c))); }

EXPORT double _simd_orient_pd3(const double *p) { return orient_p3(p, p + 4, p + 8, p + 12); }
EXPORT float _simd_orient_pf3(simd_float3 a, simd_float3 b, simd_float3 c, simd_float3 d)
{
	return to_float(orient_p3(D3(a), D3(b), D3(c), D3(d)));
}
EXPORT _Float16 _simd_orient_ph3(simd_half3 a, simd_half3 b, simd_half3 c, simd_half3 d)
{
	return to_half(orient_p3(D3(a), D3(b), D3(c), D3(d)));
}

EXPORT double _simd_incircle_pd2(simd_double2 x, simd_double2 a, simd_double2 b, simd_double2 c)
{
	return incircle_p2(D2(x), D2(a), D2(b), D2(c));
}
EXPORT float _simd_incircle_pf2(simd_float2 x, simd_float2 a, simd_float2 b, simd_float2 c)
{
	return to_float(incircle_p2(D2(x), D2(a), D2(b), D2(c)));
}
EXPORT _Float16 _simd_incircle_ph2(simd_half2 x, simd_half2 a, simd_half2 b, simd_half2 c)
{
	return to_half(incircle_p2(D2(x), D2(a), D2(b), D2(c)));
}

EXPORT double _simd_insphere_pd3(const double *p) { return insphere_p3(p, p + 4, p + 8, p + 12, p + 16); }
EXPORT float _simd_insphere_pf3(simd_float3 x, simd_float3 a, simd_float3 b, simd_float3 c, simd_float3 d)
{
	return to_float(insphere_p3(D3(x), D3(a), D3(b), D3(c), D3(d)));
}
EXPORT _Float16 _simd_insphere_ph3(simd_half3 x, simd_half3 a, simd_half3 b, simd_half3 c, simd_half3 d)
{
	return to_half(insphere_p3(D3(x), D3(a), D3(b), D3(c), D3(d)));
}
