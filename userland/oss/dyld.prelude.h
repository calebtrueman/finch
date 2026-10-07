/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into dyld and libdyld: the same macros Apple's internal
 * headers supply that the cache builder needs (tools/dsc/prelude.h).
 */
#include "../../tools/dsc/prelude.h"

/* Apple's internal headers bring in the TPRO/RWX toggles that lsl/Allocator.h
 * and libdyld call without including them. */
#if !defined(__ASSEMBLER__)
#include <os/thread_self_restrict.h>
#endif
