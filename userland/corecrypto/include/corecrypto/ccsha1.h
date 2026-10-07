/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#ifndef _FINCH_CORECRYPTO_CCSHA1_H_
#define _FINCH_CORECRYPTO_CCSHA1_H_

#include <corecrypto/ccdigest.h>

__BEGIN_DECLS

#define CCSHA1_OUTPUT_SIZE 20
const struct ccdigest_info *ccsha1_di(void);

__END_DECLS

#endif
