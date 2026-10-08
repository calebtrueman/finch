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

/*
 * Domains. Each is a bootstrap namespace with its own port: the system domain,
 * and per-user domains under it (docs/design/SERVICES.md). A process's
 * bootstrap port names its domain. Look-ups fall back to the parent domain;
 * check-ins register in the caller's own. The API names a domain by its port.
 */

/* Callbacks into the job manager, called on the server's queue. */
struct bootstrapd_hooks {
	/* A message arrived for a declared service of `owner` that isn't running. */
	void (*demand)(void *owner);
	/* May process `pid` check in the declared services of `owner`? */
	bool (*may_check_in)(void *owner, pid_t pid);
	/* A control request (a pipe routine carrying "op") arrived on the port of
	 * the domain created with `context`; fills `reply`, returns its error. */
	int (*control)(void *context, xpc_object_t request, xpc_object_t reply, const audit_token_t *token);
};

/* Start the bootstrap server with its system domain (whose context is
 * `context`); registry state lives on the serial queue `q`. Returns the
 * system domain's port (with a send right for the caller), or MACH_PORT_NULL
 * on failure. Call it off the queue. */
mach_port_t bootstrapd_start(dispatch_queue_t q, const struct bootstrapd_hooks *hooks, void *context);

/* Create a domain under the domain `parent`. Returns its port (with a send
 * right for the caller), or MACH_PORT_NULL. On the queue. */
mach_port_t bootstrapd_domain_create(mach_port_t parent, void *context);

/* Destroy a domain made by bootstrapd_domain_create: its services go, and
 * requests on its port fail. Undeclare its jobs' services first. On the queue. */
void bootstrapd_domain_destroy(mach_port_t domain);

/* Reserve `name` in `domain` for `owner` (a job). Call on the server's queue.
 * Returns 0, EEXIST, EINVAL, ESRCH (no such domain) or ENOMEM. */
int bootstrapd_declare(mach_port_t domain, const char *name, void *owner);

/* Remove `owner`'s declared services. On the queue. */
void bootstrapd_undeclare(void *owner);

/* Append a dictionary per service of `owner` to the array `out`: name,
 * active (checked in), queued (messages waiting while held). On the queue. */
void bootstrapd_describe(void *owner, xpc_object_t out);

/* `owner` exited: watch its held services for demand again. On the queue. */
void bootstrapd_rearm(void *owner);

#endif
