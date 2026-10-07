/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#ifndef _FINCH_CCSHA1_H_
#define _FINCH_CCSHA1_H_
#include <corecrypto/ccdigest.h>
#define CCSHA1_OUTPUT_SIZE CC_SHA1_DIGEST_LENGTH
static inline const struct ccdigest_info *
ccsha1_di(void)
{
	static const struct ccdigest_info di = { CC_SHA1_DIGEST_LENGTH, FINCH_CC_SHA1 };
	return &di;
}
#endif
