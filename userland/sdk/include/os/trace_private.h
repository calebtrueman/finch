/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <os/trace_private.h>: the libsystem_trace mode switch. The mode bits are
 * the ones xnu documents in osfmk/atm/atm_types.h (ATM_TRACE_*).
 */

#ifndef __OS_TRACE_PRIVATE_H__
#define __OS_TRACE_PRIVATE_H__

#include <os/trace.h>
#include <stdint.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

#define OS_TRACE_MODE_DISABLE 0x0100   /* don't initialize logging in this process */
#define OS_TRACE_MODE_OFF     0x0400   /* don't write messages to log buffers */

void os_trace_set_mode(uint32_t mode);

__END_DECLS

#endif
