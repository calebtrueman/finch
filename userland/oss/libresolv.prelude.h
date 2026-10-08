/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into libresolv (tools/build-oss.sh): the dyld version-set
 * constants (dyld_2024_SU_E_os_versions, ...) Apple's internal dyld_priv.h
 * defines and the published one doesn't (tools/gen-dyld-versions.py).
 */
#ifndef __ASSEMBLER__
#include <mach-o/finch_dyld_versions.h>
#endif
