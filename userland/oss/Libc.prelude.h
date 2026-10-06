/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into Libc (tools/build-oss.sh): declarations Apple's internal
 * headers carry but the published ones don't.
 */
#ifndef __ASSEMBLER__
#include <stdbool.h>
#include <mach-o/finch_dyld_versions.h>

/* Set by libsystem_kernel's initializer when running in a build chroot (used
 * by libdarwin's os_variant). Exported by libsystem_kernel. */
extern bool _os_xbs_chrooted;
#endif
