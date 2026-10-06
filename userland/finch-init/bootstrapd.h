/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#ifndef FINCH_BOOTSTRAPD_H
#define FINCH_BOOTSTRAPD_H

#include <mach/mach.h>
#include <xpc/xpc.h>

/* Start the bootstrap server on a new thread. Returns its port (with a send
 * right for the caller), or MACH_PORT_NULL on failure. */
mach_port_t bootstrapd_start(void);

/* Answer one request received with xpc_pipe_receive. */
void bootstrapd_handle(xpc_object_t request);

#endif
