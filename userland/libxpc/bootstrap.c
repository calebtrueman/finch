/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * bootstrap_* (Mach service registry client). On macOS these live in libxpc
 * and talk to launchd; on Finch they talk to finch-init's bootstrap server,
 * using launchd's wire format (docs/design/XPC-protocol.md, "Bootstrap"):
 * an xpc_pipe routine with msgh_id 0x40000000 | routine whose request is a
 * dictionary {handle, flags, name, type = 7, domain-port[, instance, targetpid]}
 * and whose reply carries "error" and, on success, "port".
 */

#include <errno.h>
#include <mach/mach_error.h>
#include <servers/bootstrap.h>
#include <string.h>

#include "internal.h"

#define BOOTSTRAP_ROUTINE_CHECK_IN  206
#define BOOTSTRAP_ROUTINE_LOOK_UP   207
#define BOOTSTRAP_TYPE_MACH_SERVICE 7

xpc_object_t xpc_mach_send_create(mach_port_t port);
mach_port_t xpc_mach_send_copy_right(xpc_object_t xsend);
mach_port_t xpc_mach_recv_extract_right(xpc_object_t xrecv);

/* Replies carry Mach bootstrap codes (finch-init) or errno-style codes (launchd). */
static kern_return_t
_bootstrap_error(int64_t e)
{
	if (e == 0) {
		return BOOTSTRAP_SUCCESS;
	}
	if (e >= BOOTSTRAP_NOT_PRIVILEGED && e <= BOOTSTRAP_NO_CHILDREN) {
		return (kern_return_t)e;
	}
	switch (e) {
	case EPERM: return BOOTSTRAP_NOT_PRIVILEGED;
	case EEXIST: case EBUSY: return BOOTSTRAP_SERVICE_ACTIVE;
	case ENOMEM: return BOOTSTRAP_NO_MEMORY;
	default: return BOOTSTRAP_UNKNOWN_SERVICE;
	}
}

static kern_return_t
_bootstrap_routine(mach_port_t bp, uint32_t routine, const char *name, bool look_up,
    pid_t target_pid, uint64_t flags, mach_port_t *sp)
{
	xpc_object_t req, reply = NULL, port;
	kern_return_t kr;
	int rc;

	*sp = MACH_PORT_NULL;
	if (name == NULL || strnlen(name, sizeof(name_t)) >= sizeof(name_t)) {
		return BOOTSTRAP_BAD_COUNT;
	}
	req = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_uint64(req, "handle", 0);
	xpc_dictionary_set_uint64(req, "flags", flags);
	xpc_dictionary_set_string(req, "name", name);
	xpc_dictionary_set_uint64(req, "type", BOOTSTRAP_TYPE_MACH_SERVICE);
	if (look_up) {
		uuid_t none = { 0 };
		xpc_dictionary_set_uuid(req, "instance", none);
		xpc_dictionary_set_int64(req, "targetpid", target_pid);
	}
	port = xpc_mach_send_create(bp);
	if (port != NULL) {
		xpc_dictionary_set_value(req, "domain-port", port);
		xpc_release(port);
	}
	rc = _xpc_pipe_routine_port(bp, XPC_MSGID_PIPE_ROUTINE | routine, req, &reply, NULL);
	xpc_release(req);
	if (rc != 0) {
		/* No bootstrap server (or it dropped the request). */
		return rc == EPIPE ? MACH_SEND_INVALID_DEST : BOOTSTRAP_UNKNOWN_SERVICE;
	}
	kr = _bootstrap_error(xpc_dictionary_get_int64(reply, "error"));
	if (kr == BOOTSTRAP_SUCCESS) {
		port = xpc_dictionary_get_value(reply, "port");
		if (look_up && port != NULL && xpc_get_type(port) == XPC_TYPE_MACH_SEND) {
			*sp = xpc_mach_send_copy_right(port);
		} else if (!look_up && port != NULL && xpc_get_type(port) == XPC_TYPE_MACH_RECV) {
			*sp = xpc_mach_recv_extract_right(port);
		}
		if (!MACH_PORT_VALID(*sp)) {
			kr = BOOTSTRAP_UNKNOWN_SERVICE;
		}
	}
	xpc_release(reply);
	return kr;
}

kern_return_t
bootstrap_look_up(mach_port_t bp, const name_t service_name, mach_port_t *sp)
{
	return _bootstrap_routine(bp, BOOTSTRAP_ROUTINE_LOOK_UP, service_name, true, 0, 0, sp);
}

kern_return_t
bootstrap_check_in(mach_port_t bp, const name_t service_name, mach_port_t *sp)
{
	return _bootstrap_routine(bp, BOOTSTRAP_ROUTINE_CHECK_IN, service_name, false, 0, 0, sp);
}

kern_return_t bootstrap_look_up2(mach_port_t bp, const name_t service_name, mach_port_t *sp,
    pid_t target_pid, uint64_t flags);

kern_return_t
bootstrap_look_up2(mach_port_t bp, const name_t service_name, mach_port_t *sp,
    pid_t target_pid, uint64_t flags)
{
	return _bootstrap_routine(bp, BOOTSTRAP_ROUTINE_LOOK_UP, service_name, true, target_pid, flags, sp);
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
