/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into Libc (tools/build-oss.sh): dyld version constants that
 * Apple's internal <mach-o/dyld_priv.h> carries but the published one doesn't.
 */
#ifndef __ASSEMBLER__
#include <mach-o/finch_dyld_versions.h>
#endif
