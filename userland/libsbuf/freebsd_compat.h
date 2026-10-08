/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * FreeBSD <sys/cdefs.h> and <sys/param.h> helpers that FreeBSD's sbuf code
 * uses and Darwin's headers don't define (userland/libsbuf/build.sh).
 */
#ifndef FINCH_LIBSBUF_FREEBSD_COMPAT_H
#define FINCH_LIBSBUF_FREEBSD_COMPAT_H

#include <stdarg.h>
#include <sys/param.h>

#define __va_list va_list
#ifndef roundup2
#define roundup2(x, y) (((x) + ((y) - 1)) & (~((__typeof__(x))(y) - 1)))
#endif
#ifndef __predict_false
#define __predict_false(x) __builtin_expect((x), 0)
#define __predict_true(x)  __builtin_expect((x), 1)
#endif

#endif
