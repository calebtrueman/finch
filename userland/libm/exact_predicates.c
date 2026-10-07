/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Exact geometry predicates for inputs whose magnitudes span more than
 * Shewchuk's adaptive predicates can handle without underflow (apple_simd.c
 * uses those for everything else). Every coordinate is an integer times
 * 2^emin, so after dividing out 2^emin the determinant is an exact integer
 * expression, evaluated here with fixed-size signed bignums. Degree-5
 * determinants over the whole double range need about 11,000 bits.
 */

#include <stdint.h>

#define LIMBS 360   /* 32-bit limbs: 11,520 bits */

typedef struct {
	int sign;        /* -1, 0, +1 */
	int n;           /* limbs in use */
	uint32_t d[LIMBS];
} big;

static void big_zero(big *a) { a->sign = 0; a->n = 0; }

static void big_trim(big *a)
{
	while (a->n > 0 && a->d[a->n - 1] == 0)
		a->n--;
	if (a->n == 0)
		a->sign = 0;
}

/* |a| <=> |b| */
static int mag_cmp(const big *a, const big *b)
{
	if (a->n != b->n)
		return a->n < b->n ? -1 : 1;
	for (int i = a->n - 1; i >= 0; i--)
		if (a->d[i] != b->d[i])
			return a->d[i] < b->d[i] ? -1 : 1;
	return 0;
}

/* r = |a| + |b| (magnitudes) */
static void mag_add(big *r, const big *a, const big *b)
{
	int n = a->n > b->n ? a->n : b->n;
	uint64_t carry = 0;
	for (int i = 0; i < n; i++) {
		uint64_t s = carry + (i < a->n ? a->d[i] : 0) + (i < b->n ? b->d[i] : 0);
		r->d[i] = (uint32_t)s;
		carry = s >> 32;
	}
	r->n = n;
	if (carry && n < LIMBS)
		r->d[r->n++] = (uint32_t)carry;
}

/* r = |a| - |b|, requires |a| >= |b| */
static void mag_sub(big *r, const big *a, const big *b)
{
	int64_t borrow = 0;
	for (int i = 0; i < a->n; i++) {
		int64_t s = (int64_t)a->d[i] - borrow - (i < b->n ? b->d[i] : 0);
		borrow = s < 0;
		r->d[i] = (uint32_t)(s + (borrow << 32));
	}
	r->n = a->n;
}

/* r = a + sb*b (sb = +1 or -1); r may alias a. */
static void big_addsub(big *r, const big *a, const big *b, int sb)
{
	int bs = b->sign * sb;
	if (b->sign == 0) { if (r != a) *r = *a; return; }
	if (a->sign == 0) { *r = *b; r->sign = bs; return; }
	big t;
	if (a->sign == bs) {
		mag_add(&t, a, b);
		t.sign = bs;
	} else {
		int c = mag_cmp(a, b);
		if (c == 0) { big_zero(r); return; }
		if (c > 0) { mag_sub(&t, a, b); t.sign = a->sign; }
		else { mag_sub(&t, b, a); t.sign = bs; }
	}
	big_trim(&t);
	*r = t;
}

static void big_mul(big *r, const big *a, const big *b)
{
	big t;
	if (a->sign == 0 || b->sign == 0) { big_zero(r); return; }
	int n = a->n + b->n;
	if (n > LIMBS) n = LIMBS;   /* cannot happen for degree <= 5 */
	for (int i = 0; i < n; i++)
		t.d[i] = 0;
	for (int i = 0; i < a->n; i++) {
		uint64_t carry = 0;
		for (int j = 0; j < b->n && i + j < n; j++) {
			uint64_t p = (uint64_t)a->d[i] * b->d[j] + t.d[i + j] + carry;
			t.d[i + j] = (uint32_t)p;
			carry = p >> 32;
		}
		for (int k = i + b->n; carry && k < n; k++) {
			uint64_t s = (uint64_t)t.d[k] + carry;
			t.d[k] = (uint32_t)s;
			carry = s >> 32;
		}
	}
	t.n = n;
	t.sign = a->sign * b->sign;
	big_trim(&t);
	*r = t;
}

/* The integer x / 2^emin (exact: emin is the smallest exponent of any input). */
static void big_from(big *r, double x, int emin)
{
	big_zero(r);
	if (x == 0)
		return;
	uint64_t bits;
	__builtin_memcpy(&bits, &x, 8);
	int sign = (bits >> 63) ? -1 : 1;
	int e = (int)((bits >> 52) & 0x7ff);
	uint64_t m = bits & 0x000fffffffffffffull;
	if (e == 0) e = 1; else m |= 1ull << 52;
	int shift = (e - 1075) - emin;   /* value = m * 2^(e-1075) */
	int limb = shift / 32, bit = shift % 32;
	for (int i = 0; i < LIMBS; i++) r->d[i] = 0;
	unsigned __int128 v = (unsigned __int128)m << bit;
	for (int i = 0; i < 4 && limb + i < LIMBS; i++)
		r->d[limb + i] = (uint32_t)(v >> (32 * i));
	r->n = limb + 4 < LIMBS ? limb + 4 : LIMBS;
	r->sign = sign;
	big_trim(r);
}

/* Lowest exponent (of the least significant set bit's weight) over inputs. */
static int min_exponent(const double *c, int n)
{
	int emin = 100000;
	for (int i = 0; i < n; i++) {
		if (c[i] == 0) continue;
		uint64_t bits;
		__builtin_memcpy(&bits, &c[i], 8);
		int e = (int)((bits >> 52) & 0x7ff);
		if (e == 0) e = 1;
		int w = e - 1075;
		if (w < emin) emin = w;
	}
	return emin == 100000 ? 0 : emin;
}

/* ---- determinants on coordinate differences ---- */

/* | ax ay | */
/* | bx by |  = ax*by - ay*bx */
static void det2(big *r, const big *ax, const big *ay, const big *bx, const big *by)
{
	big t, u;
	big_mul(&t, ax, by);
	big_mul(&u, ay, bx);
	big_addsub(r, &t, &u, -1);
}

static void det3(big *r, const big m[3][3])
{
	big minor, t, acc;
	big_zero(&acc);
	det2(&minor, &m[1][1], &m[1][2], &m[2][1], &m[2][2]);
	big_mul(&t, &m[0][0], &minor);
	big_addsub(&acc, &acc, &t, +1);
	det2(&minor, &m[1][0], &m[1][2], &m[2][0], &m[2][2]);
	big_mul(&t, &m[0][1], &minor);
	big_addsub(&acc, &acc, &t, -1);
	det2(&minor, &m[1][0], &m[1][1], &m[2][0], &m[2][1]);
	big_mul(&t, &m[0][2], &minor);
	big_addsub(&acc, &acc, &t, +1);
	*r = acc;
}

static int sign_of(const big *b) { return b->sign; }

/* Static scratch would make these non-reentrant; the bignums live on the
 * stack (a few tens of KB at most). */

/* Sign of orient2d(a, b, c): det | a-c ; b-c |. Points are 2 doubles each. */
int __finch_exact_orient2d(const double *a, const double *b, const double *c)
{
	double v[6] = { a[0], a[1], b[0], b[1], c[0], c[1] };
	int emin = min_exponent(v, 6);
	big A[2], B[2], C[2], d[4];
	for (int i = 0; i < 2; i++) {
		big_from(&A[i], a[i], emin);
		big_from(&B[i], b[i], emin);
		big_from(&C[i], c[i], emin);
	}
	big_addsub(&d[0], &A[0], &C[0], -1);
	big_addsub(&d[1], &A[1], &C[1], -1);
	big_addsub(&d[2], &B[0], &C[0], -1);
	big_addsub(&d[3], &B[1], &C[1], -1);
	big r;
	det2(&r, &d[0], &d[1], &d[2], &d[3]);
	return sign_of(&r);
}

/* Sign of Shewchuk's orient3d(a, b, c, d): det | a-d ; b-d ; c-d |. */
int __finch_exact_orient3d(const double *a, const double *b, const double *c, const double *d)
{
	double v[12] = { a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2], d[0], d[1], d[2] };
	int emin = min_exponent(v, 12);
	const double *p[3] = { a, b, c };
	big m[3][3], D[3], t;
	for (int k = 0; k < 3; k++)
		big_from(&D[k], d[k], emin);
	for (int r = 0; r < 3; r++)
		for (int k = 0; k < 3; k++) {
			big_from(&t, p[r][k], emin);
			big_addsub(&m[r][k], &t, &D[k], -1);
		}
	big r;
	det3(&r, m);
	return sign_of(&r);
}

/* Sign of Shewchuk's incircle(a, b, c, d): with rows (x-d, y-d, |p-d|^2)
 * for p in a, b, c, the 3x3 determinant. */
int __finch_exact_incircle(const double *a, const double *b, const double *c, const double *d)
{
	double v[8] = { a[0], a[1], b[0], b[1], c[0], c[1], d[0], d[1] };
	int emin = min_exponent(v, 8);
	const double *p[3] = { a, b, c };
	big m[3][3], D[2], t, sq;
	for (int k = 0; k < 2; k++)
		big_from(&D[k], d[k], emin);
	for (int r = 0; r < 3; r++) {
		for (int k = 0; k < 2; k++) {
			big_from(&t, p[r][k], emin);
			big_addsub(&m[r][k], &t, &D[k], -1);
		}
		big_mul(&m[r][2], &m[r][0], &m[r][0]);
		big_mul(&sq, &m[r][1], &m[r][1]);
		big_addsub(&m[r][2], &m[r][2], &sq, +1);
	}
	big r;
	det3(&r, m);
	return sign_of(&r);
}

/* Sign of Shewchuk's insphere(a, b, c, d, e): with rows
 * (x-e, y-e, z-e, |p-e|^2) for p in a, b, c, d, the 4x4 determinant
 * (Shewchuk's sign: positive when e is inside a positively oriented a,b,c,d). */
int __finch_exact_insphere(const double *a, const double *b, const double *c, const double *d, const double *e)
{
	double v[15] = { a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2], d[0], d[1], d[2], e[0], e[1], e[2] };
	int emin = min_exponent(v, 15);
	const double *p[4] = { a, b, c, d };
	big m[4][4], E[3], t, sq;
	for (int k = 0; k < 3; k++)
		big_from(&E[k], e[k], emin);
	for (int r = 0; r < 4; r++) {
		for (int k = 0; k < 3; k++) {
			big_from(&t, p[r][k], emin);
			big_addsub(&m[r][k], &t, &E[k], -1);
		}
		big_mul(&m[r][3], &m[r][0], &m[r][0]);
		big_mul(&sq, &m[r][1], &m[r][1]);
		big_addsub(&m[r][3], &m[r][3], &sq, +1);
		big_mul(&sq, &m[r][2], &m[r][2]);
		big_addsub(&m[r][3], &m[r][3], &sq, +1);
	}
	/* Expand along the last column: sum (-1)^(r+3) * m[r][3] * minor(r, 3). */
	big acc, minor, prod;
	big_zero(&acc);
	for (int r = 0; r < 4; r++) {
		big sub[3][3];
		for (int i = 0, rr = 0; i < 4; i++) {
			if (i == r) continue;
			for (int k = 0; k < 3; k++)
				sub[rr][k] = m[i][k];
			rr++;
		}
		det3(&minor, sub);
		big_mul(&prod, &m[r][3], &minor);
		big_addsub(&acc, &acc, &prod, ((r + 3) & 1) ? -1 : +1);
	}
	return sign_of(&acc);
}
