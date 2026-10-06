/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-init's bootstrap server: the Mach service registry that launchd
 * provides on macOS (docs/design/XPC.md, X4). It speaks launchd's wire format
 * (docs/design/XPC-protocol.md, "Bootstrap"), so libxpc's bootstrap_look_up,
 * bootstrap_check_in and XPC Mach-service connections work unchanged.
 *
 * Rules:
 *   - check_in(name) creates the service if it doesn't exist (or its previous
 *     owner died) and hands the caller the receive right; the server keeps a
 *     send right. Checking in a live service someone else owns is refused.
 *   - look_up(name) returns a send right, or BOOTSTRAP_UNKNOWN_SERVICE.
 *   - A service whose receive right is destroyed (its owner exited) is
 *     forgotten the next time anyone asks for it.
 *
 * FINCH-NOT-YET: declared services (launchd plists' MachServices, which
 * reserve a name, queue messages and launch the job on demand), per-service
 * ownership policy, and per-user domains. Any process may check in any name
 * that isn't live.
 */

#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#include "bootstrapd.h"

#define ROUTINE_CHECK_IN 206
#define ROUTINE_LOOK_UP  207

/* libxpc private API (also exported by Apple's libxpc). */
int xpc_pipe_receive(mach_port_t port, xpc_object_t *message);
int xpc_pipe_routine_reply(xpc_object_t reply);
xpc_object_t xpc_mach_send_create(mach_port_t port);
xpc_object_t xpc_mach_recv_create(mach_port_t port);
void xpc_dictionary_get_audit_token(xpc_object_t xdict, audit_token_t *token);
/* Finch libxpc SPI. */
uint32_t finch_xpc_pipe_request_routine(xpc_object_t request);

struct service {
	char name[sizeof(name_t)];
	mach_port_t send;           /* the server's send right (dead name once the owner exits) */
	struct service *next;
};

static struct service *services;   /* touched only by the server thread */

static struct service *
find(const char *name)
{
	struct service **pp = &services, *s;
	mach_port_type_t type;

	while ((s = *pp) != NULL) {
		if (strcmp(s->name, name) == 0) {
			if (mach_port_type(mach_task_self(), s->send, &type) == KERN_SUCCESS &&
			    (type & MACH_PORT_TYPE_SEND)) {
				return s;
			}
			/* Owner gone: forget it. */
			mach_port_deallocate(mach_task_self(), s->send);
			*pp = s->next;
			free(s);
			return NULL;
		}
		pp = &s->next;
	}
	return NULL;
}

static kern_return_t
check_in(const char *name, xpc_object_t reply)
{
	struct service *s;
	mach_port_t port;
	xpc_object_t recv;

	if (find(name) != NULL) {
		return BOOTSTRAP_SERVICE_ACTIVE;
	}
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
		return BOOTSTRAP_NO_MEMORY;
	}
	if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS ||
	    (s = calloc(1, sizeof(*s))) == NULL) {
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
		return BOOTSTRAP_NO_MEMORY;
	}
	strlcpy(s->name, name, sizeof(s->name));
	s->send = port;
	s->next = services;
	services = s;
	recv = xpc_mach_recv_create(port);   /* moves the receive right to the caller */
	xpc_dictionary_set_value(reply, "port", recv);
	xpc_release(recv);
	return BOOTSTRAP_SUCCESS;
}

static kern_return_t
look_up(const char *name, xpc_object_t reply)
{
	struct service *s = find(name);
	xpc_object_t send;

	if (s == NULL) {
		return BOOTSTRAP_UNKNOWN_SERVICE;
	}
	send = xpc_mach_send_create(s->send);   /* copies a send right */
	xpc_dictionary_set_value(reply, "port", send);
	xpc_release(send);
	return BOOTSTRAP_SUCCESS;
}

void
bootstrapd_handle(xpc_object_t request)
{
	uint32_t routine = finch_xpc_pipe_request_routine(request);
	const char *name = xpc_dictionary_get_string(request, "name");
	xpc_object_t reply = xpc_dictionary_create_reply(request);
	audit_token_t token;
	kern_return_t kr;

	if (reply == NULL) {
		return;   /* not a routine: nothing to answer */
	}
	if (name == NULL || strnlen(name, sizeof(name_t)) >= sizeof(name_t)) {
		kr = BOOTSTRAP_BAD_COUNT;
	} else if (routine == ROUTINE_CHECK_IN) {
		kr = check_in(name, reply);
	} else if (routine == ROUTINE_LOOK_UP) {
		kr = look_up(name, reply);
	} else {
		kr = BOOTSTRAP_NOT_PRIVILEGED;   /* routine not implemented */
	}
	xpc_dictionary_get_audit_token(request, &token);
	xpc_dictionary_set_int64(reply, "error", kr);
	xpc_dictionary_set_int64(reply, "req_pid", (int64_t)token.val[5]);
	xpc_dictionary_set_int64(reply, "rec_execcnt", 0);
	xpc_pipe_routine_reply(reply);
	xpc_release(reply);
}

static void *
serve(void *arg)
{
	mach_port_t port = (mach_port_t)(uintptr_t)arg;
	xpc_object_t request;
	int rc;

	pthread_setname_np("bootstrap");
	for (;;) {
		rc = xpc_pipe_receive(port, &request);
		if (rc == 0) {
			bootstrapd_handle(request);
			xpc_release(request);
		} else if (rc != EAGAIN && rc != EINTR && rc != EINVAL) {
			return NULL;   /* port gone */
		}
	}
}

mach_port_t
bootstrapd_start(void)
{
	mach_port_t port;
	pthread_t thread;

	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
		return MACH_PORT_NULL;
	}
	if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS ||
	    pthread_create(&thread, NULL, serve, (void *)(uintptr_t)port) != 0) {
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
		return MACH_PORT_NULL;
	}
	pthread_detach(thread);
	return port;
}
