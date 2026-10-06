/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * ffs/ffsl/fls/flsl for libsystem_platform. Apple's published libplatform
 * only has the "ll" variants; the shipping library also exports these, and
 * libsystem_c imports fls/flsl. Semantics per ffs(3): bit positions are
 * 1-based, 0 means no bits set.
 */

#include <strings.h>

int
ffs(int mask)
{
	return mask == 0 ? 0 : __builtin_ctz((unsigned int)mask) + 1;
}

int
ffsl(long mask)
{
	return mask == 0 ? 0 : __builtin_ctzl((unsigned long)mask) + 1;
}

int
fls(int mask)
{
	return mask == 0 ? 0 : 32 - __builtin_clz((unsigned int)mask);
}

int
flsl(long mask)
{
	return mask == 0 ? 0 : 64 - __builtin_clzl((unsigned long)mask);
}
