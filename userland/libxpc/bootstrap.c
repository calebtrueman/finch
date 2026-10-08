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

/*
 * Domains (docs/design/SERVICES.md): finch-init's system domain and per-user
 * domains under it. These ask finch-init with control requests ({op, ...}
 * pipe routines on a domain's port; errno results).
 */
static xpc_object_t
_bootstrap_control(mach_port_t bp, xpc_object_t req, kern_return_t *kr)
{
	xpc_object_t reply = NULL;
	int rc = _xpc_pipe_routine_port(bp, XPC_MSGID_PIPE_ROUTINE, req, &reply, NULL);

	if (rc != 0) {
		*kr = rc == EPIPE ? MACH_SEND_INVALID_DEST : BOOTSTRAP_UNKNOWN_SERVICE;
		return NULL;
	}
	*kr = _bootstrap_error(xpc_dictionary_get_int64(reply, "error"));
	if (*kr != BOOTSTRAP_SUCCESS) {
		xpc_release(reply);
		return NULL;
	}
	return reply;
}

/* A control request whose reply carries a "port" send right. */
static kern_return_t
_bootstrap_control_port(mach_port_t bp, xpc_object_t req, mach_port_t *port)
{
	kern_return_t kr;
	xpc_object_t reply = _bootstrap_control(bp, req, &kr), p;

	*port = MACH_PORT_NULL;
	if (reply != NULL) {
		p = xpc_dictionary_get_value(reply, "port");
		if (p != NULL && xpc_get_type(p) == XPC_TYPE_MACH_SEND) {
			*port = xpc_mach_send_copy_right(p);
		}
		kr = MACH_PORT_VALID(*port) ? BOOTSTRAP_SUCCESS : BOOTSTRAP_UNKNOWN_SERVICE;
		xpc_release(reply);
	}
	return kr;
}

/* The parent domain's port; the system domain is its own parent. Leaving a
 * user domain needs root. */
kern_return_t
bootstrap_parent(mach_port_t bp, mach_port_t *parent_port)
{
	xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
	kern_return_t kr;

	xpc_dictionary_set_string(req, "op", "parent");
	kr = _bootstrap_control_port(bp, req, parent_port);
	xpc_release(req);
	return kr;
}

kern_return_t bootstrap_get_root(mach_port_t bp, mach_port_t *root_bp);

/* The system domain's port, climbing from `bp`. */
kern_return_t
bootstrap_get_root(mach_port_t bp, mach_port_t *root_bp)
{
	mach_port_t cur = bp, parent;
	kern_return_t kr;

	*root_bp = MACH_PORT_NULL;
	if (mach_port_mod_refs(mach_task_self(), cur, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) {
		return BOOTSTRAP_NOT_PRIVILEGED;
	}
	for (;;) {
		if ((kr = bootstrap_parent(cur, &parent)) != BOOTSTRAP_SUCCESS) {
			mach_port_deallocate(mach_task_self(), cur);
			return kr;
		}
		if (parent == cur) {   /* same port, same name: the top */
			mach_port_deallocate(mach_task_self(), parent);
			*root_bp = cur;
			return BOOTSTRAP_SUCCESS;
		}
		mach_port_deallocate(mach_task_self(), cur);
		cur = parent;
	}
}

kern_return_t bootstrap_look_up_per_user(mach_port_t bp, const name_t service_name, uid_t target_user,
    mach_port_t *sp);

/*
 * `service_name` in user `target_user`'s domain, or with a NULL name the
 * domain's port itself (pam_launchd). finch-init creates the domain, and loads
 * the user's agents, on first use. Root may ask for any user; others only for
 * themselves.
 */
kern_return_t
bootstrap_look_up_per_user(mach_port_t bp, const name_t service_name, uid_t target_user, mach_port_t *sp)
{
	xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
	mach_port_t user_bp;
	kern_return_t kr;

	*sp = MACH_PORT_NULL;
	xpc_dictionary_set_string(req, "op", "per-user");
	xpc_dictionary_set_uint64(req, "uid", target_user);
	kr = _bootstrap_control_port(bp, req, &user_bp);
	xpc_release(req);
	if (kr != BOOTSTRAP_SUCCESS || service_name == NULL) {
		*sp = user_bp;
		return kr;
	}
	kr = bootstrap_look_up(user_bp, service_name, sp);
	mach_port_deallocate(mach_task_self(), user_bp);
	return kr;
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

/* <vproc.h>, <vproc_priv.h> (liblaunch, part of libxpc). */
typedef void *vproc_t;
typedef void *vproc_err_t;
#define VPROC_GSK_MGR_UID 3
#define VPROC_GSK_MGR_PID 4
#define VPROC_GSK_IS_MANAGED 5
vproc_err_t vproc_swap_integer(vproc_t vp, int key, int64_t *inval, int64_t *outval);
vproc_err_t _vproc_post_fork_ping(void);
vproc_err_t _vprocmgr_switch_to_session(const char *target_session, uint64_t flags);
vproc_err_t _vprocmgr_move_subset_to_user(uid_t target_user, const char *session_type, uint64_t flags);

/* Reads the uid (MGR_UID) or pid (MGR_PID) of the caller's domain manager,
 * or whether the caller is a job finch-init started (IS_MANAGED: aslmanager
 * and other daemons serve their Mach services only then). Other keys, and
 * setting values, aren't supported. NULL on success. */
vproc_err_t
vproc_swap_integer(vproc_t vp, int key, int64_t *inval, int64_t *outval)
{
	vproc_err_t failed = (vproc_err_t)vproc_swap_integer;   /* non-NULL = error, as in liblaunch */
	(void)vp;

	if (outval) {
		*outval = 0;
	}
	if (inval != NULL || outval == NULL) {
		return failed;
	}
	if (key == VPROC_GSK_MGR_PID) {
		*outval = 1;   /* finch-init manages every domain */
		return NULL;
	}
	if (key == VPROC_GSK_IS_MANAGED) {
		/* finch-init describes the caller's job, if it is one. */
		xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0), reply;
		kern_return_t kr;
		xpc_dictionary_set_string(req, "op", "checkin");
		reply = _bootstrap_control(bootstrap_port, req, &kr);
		xpc_release(req);
		*outval = reply != NULL;
		if (reply != NULL) {
			xpc_release(reply);
		} else if (kr != BOOTSTRAP_UNKNOWN_SERVICE) {
			return failed;   /* no answer, rather than "not a job" (ESRCH) */
		}
		return NULL;
	}
	if (key == VPROC_GSK_MGR_UID) {
		xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0), reply;
		kern_return_t kr;
		xpc_dictionary_set_string(req, "op", "domain");
		reply = _bootstrap_control(bootstrap_port, req, &kr);
		xpc_release(req);
		if (reply == NULL) {
			return failed;
		}
		*outval = (int64_t)xpc_dictionary_get_uint64(reply, "uid");
		xpc_release(reply);
		return NULL;
	}
	return failed;
}

/* launchd took this after fork to attach the child; finch-init needs nothing. */
vproc_err_t
_vproc_post_fork_ping(void)
{
	return NULL;
}

/* A user has one domain on Finch, standing in for every session type
 * (Background, Aqua), so there's no other session to move to. */
vproc_err_t
_vprocmgr_switch_to_session(const char *target_session, uint64_t flags)
{
	(void)target_session; (void)flags;
	return NULL;
}

/* Make the caller's bootstrap port `target_user`'s domain (root only). */
vproc_err_t
_vprocmgr_move_subset_to_user(uid_t target_user, const char *session_type, uint64_t flags)
{
	mach_port_t root, user_bp;
	(void)session_type; (void)flags;

	if (bootstrap_get_root(bootstrap_port, &root) != BOOTSTRAP_SUCCESS) {
		return (vproc_err_t)_vprocmgr_move_subset_to_user;
	}
	kern_return_t kr = bootstrap_look_up_per_user(root, NULL, target_user, &user_bp);
	mach_port_deallocate(mach_task_self(), root);
	if (kr != BOOTSTRAP_SUCCESS ||
	    task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, user_bp) != KERN_SUCCESS) {
		if (kr == BOOTSTRAP_SUCCESS) mach_port_deallocate(mach_task_self(), user_bp);
		return (vproc_err_t)_vprocmgr_move_subset_to_user;
	}
	mach_port_deallocate(mach_task_self(), bootstrap_port);
	bootstrap_port = user_bp;
	return NULL;
}
