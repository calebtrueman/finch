/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into CORE-MATH sources. CORE-MATH's pow and atan2 keep a
 * last-resort path for an input their proofs say can't occur, which prints
 * a message and calls exit(1). A system math library must never print or
 * exit, so that path returns msun's result instead (FINCH_CM_FALLBACK, set
 * per file by build.sh). lgamma's sign goes to a private variable;
 * lgamma()/lgamma_r() set the sign themselves (apple_math.c).
 */
#ifndef FINCH_CM_HOOKS_H
#define FINCH_CM_HOOKS_H
#include <stdio.h>
#include <stdlib.h>
#define printf(...) ((void)0)
#ifdef FINCH_CM_FALLBACK
double __finch_msun_pow(double, double);
double __finch_msun_atan2(double, double);
#define exit(status) return FINCH_CM_FALLBACK
#endif
#define signgam __finch_cr_signgam
extern int __finch_cr_signgam;
#endif
