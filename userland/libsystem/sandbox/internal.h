/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Shared declarations for Finch's libsystem_sandbox.
 */

#ifndef FINCH_SANDBOX_INTERNAL_H
#define FINCH_SANDBOX_INTERNAL_H

#include <mach/message.h>   /* audit_token_t */
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/types.h>

#define EXPORT __attribute__((visibility("default")))

/* libsystem_kernel: __mac_syscall under the name Apple's library imports. */
int __sandbox_ms(const char *policy, int call, void *arg);

/* libsystem_platform's async-signal-safe string and log helpers. */
typedef void *_SIMPLE_STRING;
_SIMPLE_STRING _simple_salloc(void);
int _simple_vsprintf(_SIMPLE_STRING, const char *, va_list);
const char *_simple_string(_SIMPLE_STRING);
void _simple_sfree(_SIMPLE_STRING);
void _simple_asl_log(int level, const char *facility, const char *message);
int _simple_dprintf(int fd, const char *fmt, ...);
#define ASL_LEVEL_CRIT 2

void sandbox_warn(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif
