/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <corecrypto/cc_priv.h>: the part libSystem's initializer uses, corecrypto's
 * fork hooks (Libsystem-1356 init.c). Exported by libcorecrypto.
 */

#ifndef _CORECRYPTO_CC_PRIV_H_
#define _CORECRYPTO_CC_PRIV_H_

#include <sys/cdefs.h>

__BEGIN_DECLS

void cc_atfork_prepare(void);
void cc_atfork_parent(void);
void cc_atfork_child(void);

__END_DECLS

#endif
