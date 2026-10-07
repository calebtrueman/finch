/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#ifndef _FINCH_CCSHA2_H_
#define _FINCH_CCSHA2_H_
#include <corecrypto/ccdigest.h>
#define CCSHA256_OUTPUT_SIZE CC_SHA256_DIGEST_LENGTH
#define CCSHA384_OUTPUT_SIZE CC_SHA384_DIGEST_LENGTH
static inline const struct ccdigest_info *
ccsha256_di(void)
{
	static const struct ccdigest_info di = { CC_SHA256_DIGEST_LENGTH, FINCH_CC_SHA256 };
	return &di;
}
static inline const struct ccdigest_info *
ccsha384_di(void)
{
	static const struct ccdigest_info di = { CC_SHA384_DIGEST_LENGTH, FINCH_CC_SHA384 };
	return &di;
}
#endif
