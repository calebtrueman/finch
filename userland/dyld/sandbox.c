/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * sandbox_check() for dyld. Apple links dyld with a static copy of its
 * closed libsandbox. dyld needs one question answered: may this process
 * make Unix syscall N ("syscall-unix" with SANDBOX_FILTER_SYSCALL_NUMBER).
 * This is the Sandbox MAC policy's check call as macOS 26.4's dyld makes it:
 * __mac_syscall("Sandbox", 2, request), with a 0xa0-byte request of
 *   +0x00 result pointer   +0x08 pid   +0x10 operation
 *   +0x18 filter kind      +0x20 filter argument   +0x28 flags
 * Filter type 14 (syscall number) is kind 65; flag bit 30 of the type
 * (SANDBOX_CHECK_NO_REPORT) is request flag 1.
 */

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <sys/types.h>
#include <sandbox/private.h>

int __mac_syscall(const char *policy, int call, void *arg);

const enum sandbox_filter_type SANDBOX_CHECK_NO_REPORT = (enum sandbox_filter_type)0x40000000;

#define SANDBOX_CALL_CHECK          2
#define SANDBOX_KIND_SYSCALL_NUMBER 65

struct sandbox_check_request {
	uint64_t *result;
	int64_t pid;
	const char *operation;
	uint64_t filter_kind;
	uint64_t filter_arg;
	uint64_t flags;
	uint64_t reserved[14];
};
_Static_assert(sizeof(struct sandbox_check_request) == 0xa0, "request size");

int
sandbox_check(pid_t pid, const char *operation, enum sandbox_filter_type type, ...)
{
	uint64_t result = 0;
	struct sandbox_check_request req = { .result = &result, .pid = pid, .operation = operation };
	uint32_t t = (uint32_t)type;
	if (t & (1u << 30))
		req.flags |= 1;                 /* SANDBOX_CHECK_NO_REPORT */

	va_list ap;
	va_start(ap, type);
	switch (t & 0x81ffffffu) {
	case SANDBOX_FILTER_NONE:
		break;
	case SANDBOX_FILTER_SYSCALL_NUMBER:
		req.filter_kind = SANDBOX_KIND_SYSCALL_NUMBER;
		req.filter_arg = (uint32_t)va_arg(ap, int);
		break;
	default:                                /* not needed by dyld */
		va_end(ap);
		errno = EINVAL;
		return -1;
	}
	va_end(ap);

	if (__mac_syscall("Sandbox", SANDBOX_CALL_CHECK, &req) != 0)
		return -1;
	return result != 0;
}
