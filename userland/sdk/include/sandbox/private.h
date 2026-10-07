/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <sandbox/private.h>: libsystem_sandbox's private sandbox_check() family
 * (Finch's <sandbox.h> includes it too).
 *
 * The filter-type values were verified on macOS 26.4 by asking
 * sandbox_check() under a sandbox-exec profile that denies one path and one
 * notification name: 1 matched only the path, 9 only the notification.
 */

#ifndef _FINCH_SANDBOX_PRIVATE_H_
#define _FINCH_SANDBOX_PRIVATE_H_

#include <sandbox.h>
#include <bsm/audit.h>
#include <mach/message.h>
#include <sys/types.h>

__BEGIN_DECLS

enum sandbox_filter_type {
	SANDBOX_FILTER_NONE = 0,
	SANDBOX_FILTER_PATH = 1,
	SANDBOX_FILTER_NOTIFICATION = 9,
};

/* Flags OR'd into the filter type (exported constants). */
extern const enum sandbox_filter_type SANDBOX_CHECK_NO_REPORT;
extern const enum sandbox_filter_type SANDBOX_CHECK_CANONICAL;
extern const enum sandbox_filter_type SANDBOX_CHECK_NOFOLLOW;

/* 0 if `operation` is allowed for the process, 1 if denied, -1 on error. */
int sandbox_check(pid_t pid, const char *operation, enum sandbox_filter_type type, ...);
int sandbox_check_by_audit_token(audit_token_t token, const char *operation,
    enum sandbox_filter_type type, ...);

__END_DECLS

#endif
