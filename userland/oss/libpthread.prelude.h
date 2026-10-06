/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into libpthread (tools/build-oss.sh): declarations that
 * Apple's internal headers provide but the published ones don't.
 */
#ifndef __ASSEMBLER__
#include <stdbool.h>

/* Defined and exported by libsystem_kernel (libsyscall/wrappers/_libkernel_init.c). */
extern bool _os_xbs_chrooted;
#endif
