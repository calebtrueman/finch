/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into FreeBSD msun sources when building Finch's
 * libsystem_m: the FreeBSD <sys/cdefs.h> and <sys/endian.h> pieces msun
 * uses that Apple's headers don't have. Aliases (__weak_reference) are made
 * by the linker's alias list instead (userland/libm/build.sh).
 */
#ifndef FINCH_FREEBSD_COMPAT_H
#define FINCH_FREEBSD_COMPAT_H

#include <sys/cdefs.h>
#include <machine/endian.h>
#include <stdint.h>
#include <limits.h>
#ifndef __INT_MAX
#define __INT_MAX INT_MAX
#define __INT_MIN INT_MIN
#endif
#include <sys/types.h>

#define __FBSDID(s)
/* FreeBSD's __CONCAT expands its arguments first (two-level); Apple's
 * pastes them as written. msun relies on the expansion. */
#undef __CONCAT
#define __finch_concat1(x, y) x ## y
#define __CONCAT(x, y) __finch_concat1(x, y)
#define __weak_reference(sym, alias)
#define __strong_reference(sym, alias)
#ifndef __BSD_VISIBLE
#define __BSD_VISIBLE 1
#endif
#ifndef __ISO_C_VISIBLE
#define __ISO_C_VISIBLE 2023
#endif
#ifndef __XSI_VISIBLE
#define __XSI_VISIBLE 700
#endif
#ifndef __POSIX_VISIBLE
#define __POSIX_VISIBLE 200809
#endif
#ifndef _LITTLE_ENDIAN
#define _LITTLE_ENDIAN 1234
#define _BIG_ENDIAN 4321
#define _BYTE_ORDER _LITTLE_ENDIAN
#endif
/* msun token-pastes these (0x1.8p ## LDBL_MANT_DIG): FreeBSD's <float.h>
 * defines them as plain numbers, Apple's as other macros. */
#include <float.h>
#undef FLT_MANT_DIG
#undef DBL_MANT_DIG
#undef LDBL_MANT_DIG
#define FLT_MANT_DIG 24
#define DBL_MANT_DIG 53
#define LDBL_MANT_DIG 53

#ifndef __GNUC_PREREQ__
#define __GNUC_PREREQ__(ma, mi) (__GNUC__ > (ma) || (__GNUC__ == (ma) && __GNUC_MINOR__ >= (mi)))
#endif
/* FreeBSD <machine/_types.h>: arm64 evaluates float and double in their own
 * precision (FLT_EVAL_METHOD 0). */
typedef double __double_t;
typedef float __float_t;
/* msun keys its complex helpers on FreeBSD's <complex.h> guard. */
#include <complex.h>
#ifndef _COMPLEX_H
#define _COMPLEX_H
#endif
#ifndef CMPLX
#define CMPLX(x, y) __builtin_complex((double)(x), (double)(y))
#define CMPLXF(x, y) __builtin_complex((float)(x), (float)(y))
#define CMPLXL(x, y) __builtin_complex((long double)(x), (long double)(y))
#endif

/* Other FreeBSD <sys/cdefs.h> attributes msun uses. */
#ifndef __always_inline
#define __always_inline __inline __attribute__((__always_inline__))
#endif
#ifndef __noinline
#define __noinline __attribute__((__noinline__))
#endif
#ifndef __predict_true
#define __predict_true(exp) __builtin_expect((exp), 1)
#define __predict_false(exp) __builtin_expect((exp), 0)
#endif
#ifndef __aligned
#define __aligned(x) __attribute__((__aligned__(x)))
#endif
#ifndef __packed
#define __packed __attribute__((__packed__))
#endif

/* libsystem_m doesn't use libc: msun's nan() parsing gets ASCII hex-digit
 * tests instead of <ctype.h>'s rune-table inlines (apple_math.c). */
#include <ctype.h>
int __finch_isxdigit(int c);
#undef isxdigit
#define isxdigit(c) __finch_isxdigit(c)
#undef digittoint
#define digittoint(c) ((c) <= '9' ? (c) - '0' : ((c) | 32) - 'a' + 10)

#ifndef __pure2
#define __pure2 __attribute__((__const__))
#endif
#endif
