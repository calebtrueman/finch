/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * FreeBSD's machine <_fpmath.h> for Apple arm64, where long double is the
 * IEEE double and both bytes and words are little-endian. (FreeBSD's arm
 * header picks big-endian word order unless __VFP_FP__ or __ARM_EABI__ is
 * defined; neither is on arm64, which swapped msun's bit-field views.)
 */
#ifndef FINCH__FPMATH_H
#define FINCH__FPMATH_H

#define _IEEE_WORD_ORDER _LITTLE_ENDIAN

union IEEEl2bits {
	long double e;
	struct {
		unsigned int manl : 32;
		unsigned int manh : 20;
		unsigned int exp : 11;
		unsigned int sign : 1;
	} bits;
};

#define LDBL_NBIT 0
#define LDBL_IMPLICIT_NBIT
#define mask_nbit_l(u) ((void)0)

#define LDBL_MANH_SIZE 20
#define LDBL_MANL_SIZE 32

#define LDBL_TO_ARRAY32(u, a) do {			\
	(a)[0] = (uint32_t)(u).bits.manl;		\
	(a)[1] = (uint32_t)(u).bits.manh;		\
} while (0)

#endif
