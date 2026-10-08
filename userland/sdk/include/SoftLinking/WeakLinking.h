/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <SoftLinking/WeakLinking.h>: Apple-internal macro (not published) that
 * redeclares an already-declared function or variable as a weak import, so
 * its address is NULL at run time when the library that defines it is absent.
 *
 *   WEAK_LINK_FORCE_IMPORT(symbol);
 *   ...
 *   if (symbol != NULL) symbol(...);
 */
#ifndef _FINCH_WEAKLINKING_H_
#define _FINCH_WEAKLINKING_H_

#define WEAK_LINK_FORCE_IMPORT(sym) \
	extern __typeof__(sym) sym __attribute__((weak_import))

#endif /* !_FINCH_WEAKLINKING_H_ */
