/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * bootstrap_* (Mach service registry client). On macOS these live in libxpc
 * and talk to launchd. In Finch they'll talk to finch-init (step X4,
 * docs/design/XPC.md). Until then, every name is unknown.
 */

#include <mach/mach_error.h>
#include <servers/bootstrap.h>

#include "internal.h"

kern_return_t
bootstrap_look_up(mach_port_t bp, const name_t service_name, mach_port_t *sp)
{
	(void)bp; (void)service_name;
	*sp = MACH_PORT_NULL;
	return BOOTSTRAP_UNKNOWN_SERVICE;
}

kern_return_t
bootstrap_check_in(mach_port_t bp, const name_t service_name, mach_port_t *sp)
{
	(void)bp; (void)service_name;
	*sp = MACH_PORT_NULL;
	return BOOTSTRAP_UNKNOWN_SERVICE;
}

kern_return_t bootstrap_look_up2(mach_port_t bp, const name_t service_name, mach_port_t *sp,
    pid_t target_pid, uint64_t flags);

kern_return_t
bootstrap_look_up2(mach_port_t bp, const name_t service_name, mach_port_t *sp,
    pid_t target_pid, uint64_t flags)
{
	(void)target_pid; (void)flags;
	return bootstrap_look_up(bp, service_name, sp);
}

/* Finch has a single bootstrap domain: every port's parent is itself. */
kern_return_t
bootstrap_parent(mach_port_t bp, mach_port_t *parent_port)
{
	if (mach_port_mod_refs(mach_task_self(), bp, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) {
		return BOOTSTRAP_NOT_PRIVILEGED;
	}
	*parent_port = bp;
	return BOOTSTRAP_SUCCESS;
}

const char *
bootstrap_strerror(kern_return_t r)
{
	switch (r) {
	case BOOTSTRAP_SUCCESS: return "Success";
	case BOOTSTRAP_NOT_PRIVILEGED: return "Permission denied";
	case BOOTSTRAP_NAME_IN_USE:
	case BOOTSTRAP_SERVICE_ACTIVE: return "Service name already exists";
	case BOOTSTRAP_UNKNOWN_SERVICE: return "Unknown service name";
	case BOOTSTRAP_BAD_COUNT: return "Too many lookups were requested in one request";
	case BOOTSTRAP_NO_MEMORY: return "Out of memory";
	case BOOTSTRAP_NO_CHILDREN: return "Subset not found";
	default: return mach_error_string(r);
	}
}

/* <vproc.h> (liblaunch, part of libxpc): no global launchd keys on Finch yet. */
typedef void *vproc_t;
typedef void *vproc_err_t;
vproc_err_t vproc_swap_integer(vproc_t vp, int key, int64_t *inval, int64_t *outval);

vproc_err_t
vproc_swap_integer(vproc_t vp, int key, int64_t *inval, int64_t *outval)
{
	(void)vp; (void)key; (void)inval;
	if (outval) {
		*outval = 0;
	}
	return (vproc_err_t)vproc_swap_integer;   /* non-NULL = error, as in liblaunch */
}
