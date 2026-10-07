/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <libamfi.h>: dyld's view of AppleMobileFileIntegrity. The flag values are
 * those dyld's own source uses when built without this header
 * (dyld/DyldProcessConfig.cpp); Finch implements the call in
 * userland/dyld/amfi.c.
 */

#ifndef _FINCH_LIBAMFI_H_
#define _FINCH_LIBAMFI_H_

#include <fcntl.h>      /* dyld relies on libamfi.h for O_* */
#include <stdint.h>
#include <sys/cdefs.h>

enum {
	AMFI_DYLD_INPUT_PROC_IN_SIMULATOR    = (1 << 0),
	AMFI_DYLD_INPUT_PROC_HAS_RESTRICT_SEG = (1 << 1),   /* values from macOS 26.4's dyld */
	AMFI_DYLD_INPUT_PROC_IS_ENCRYPTED    = (1 << 2),
};

enum amfi_dyld_policy_output_flag_set {
	AMFI_DYLD_OUTPUT_ALLOW_AT_PATH                  = (1 << 0),
	AMFI_DYLD_OUTPUT_ALLOW_PATH_VARS                = (1 << 1),
	AMFI_DYLD_OUTPUT_ALLOW_CUSTOM_SHARED_CACHE      = (1 << 2),
	AMFI_DYLD_OUTPUT_ALLOW_FALLBACK_PATHS           = (1 << 3),
	AMFI_DYLD_OUTPUT_ALLOW_PRINT_VARS               = (1 << 4),
	AMFI_DYLD_OUTPUT_ALLOW_FAILED_LIBRARY_INSERTION = (1 << 5),
	AMFI_DYLD_OUTPUT_ALLOW_LIBRARY_INTERPOSING      = (1 << 6),
	AMFI_DYLD_OUTPUT_ALLOW_EMBEDDED_VARS            = (1 << 7),
	AMFI_DYLD_OUTPUT_ALLOW_DEVELOPMENT_VARS         = (1 << 8),
	AMFI_DYLD_OUTPUT_ALLOW_LIBSYSTEM_OVERRIDE       = (1 << 9),
};

__BEGIN_DECLS
/* 0, or an errno value. */
int amfi_check_dyld_policy_self(uint64_t input_flags, uint64_t *output_flags);
__END_DECLS

#endif
