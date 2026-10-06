/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * __sme_memcpy/memmove/memset/memchr: string routines callable while the CPU
 * is in SME streaming mode (Apple M4+), where Advanced SIMD (NEON)
 * instructions are illegal. Apple's versions aren't published. These are
 * plain scalar loops; the recipe compiles this file with -mgeneral-regs-only
 * so the compiler can't vectorize them.
 */

#include <stddef.h>
#include <stdint.h>

void *__sme_memcpy(void *dst, const void *src, size_t n);
void *__sme_memmove(void *dst, const void *src, size_t n);
void *__sme_memset(void *dst, int c, size_t n);
const void *__sme_memchr(const void *s, int c, size_t n);

void *
__sme_memcpy(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;

	while (n--) {
		*d++ = *s++;
	}
	return dst;
}

void *
__sme_memmove(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;

	if ((uintptr_t)d - (uintptr_t)s >= n) {
		return __sme_memcpy(dst, src, n);   /* no harmful overlap */
	}
	while (n--) {
		d[n] = s[n];
	}
	return dst;
}

void *
__sme_memset(void *dst, int c, size_t n)
{
	unsigned char *d = dst;

	while (n--) {
		*d++ = (unsigned char)c;
	}
	return dst;
}

const void *
__sme_memchr(const void *s, int c, size_t n)
{
	const unsigned char *p = s;

	for (; n; n--, p++) {
		if (*p == (unsigned char)c) {
			return p;
		}
	}
	return NULL;
}
