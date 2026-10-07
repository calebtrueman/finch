/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#ifndef FINCH_BOOTSTRAPD_H
#define FINCH_BOOTSTRAPD_H

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <xpc/xpc.h>

/* Callbacks into the job manager, called on the server's queue. */
struct bootstrapd_hooks {
	/* A message arrived for a declared service of `owner` that isn't running. */
	void (*demand)(void *owner);
	/* May process `pid` check in the declared services of `owner`? */
	bool (*may_check_in)(void *owner, pid_t pid);
};

/* Start the bootstrap server; registry state lives on the serial queue `q`.
 * Returns the bootstrap port (with a send right for the caller), or
 * MACH_PORT_NULL on failure. */
mach_port_t bootstrapd_start(dispatch_queue_t q, const struct bootstrapd_hooks *hooks);

/* Reserve `name` for `owner` (a job). Call on the server's queue.
 * Returns 0, EEXIST, EINVAL or ENOMEM. */
int bootstrapd_declare(const char *name, void *owner);

/* `owner` exited: watch its held services for demand again. On the queue. */
void bootstrapd_rearm(void *owner);

/* Answer one request received with xpc_pipe_receive. On the queue. */
void bootstrapd_handle(xpc_object_t request);

#endif
