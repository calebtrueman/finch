/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#ifndef _FINCH_CORECRYPTO_CCSHA2_H_
#define _FINCH_CORECRYPTO_CCSHA2_H_

#include <corecrypto/ccdigest.h>

__BEGIN_DECLS

#define CCSHA224_OUTPUT_SIZE 28
#define CCSHA256_OUTPUT_SIZE 32
#define CCSHA384_OUTPUT_SIZE 48
#define CCSHA512_OUTPUT_SIZE 64

const struct ccdigest_info *ccsha224_di(void);
const struct ccdigest_info *ccsha256_di(void);
const struct ccdigest_info *ccsha384_di(void);
const struct ccdigest_info *ccsha512_di(void);

__END_DECLS

#endif
