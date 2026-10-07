/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * dyld's AMFI policy query. Apple links dyld with a closed static library
 * for this. It is a thin wrapper over the AMFI MAC policy's syscall
 * interface, which Finch reimplements here.
 * (Behaviour read from macOS 26.4's dyld: AMFI policy call 90 takes
 * { input flags, pointer to output flags }.)
 */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <libamfi.h>

int __mac_syscall(const char *policy, int call, void *arg);

#define AMFI_CALL_CHECK_DYLD_POLICY_SELF 90

int
amfi_check_dyld_policy_self(uint64_t input_flags, uint64_t *output_flags)
{
	if (output_flags == NULL)
		return EINVAL;
	*output_flags = 0;
	uint64_t out = 0;
	struct {
		uint64_t input_flags;
		uint64_t *output_flags;
	} args = { input_flags, &out };
	int ret = __mac_syscall("AMFI", AMFI_CALL_CHECK_DYLD_POLICY_SELF, &args);
	if (ret != 0)
		ret = errno;
	*output_flags = out;
	return ret;
}
