/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-init's bootstrap server: the Mach service registry that launchd
 * provides on macOS (docs/design/XPC.md X4, docs/design/SERVICES.md). It speaks
 * launchd's wire format (docs/design/XPC-protocol.md, "Bootstrap"), so libxpc's
 * bootstrap_look_up, bootstrap_check_in and XPC Mach-service connections work
 * unchanged.
 *
 * Two kinds of service:
 *
 *   Declared (a job's MachServices). The name exists from the moment the job
 *   is loaded: finch-init allocates the port and holds its receive right, so
 *   clients can look it up and send to it before the job runs. A message
 *   arriving on a held port asks the job manager to launch the job (demand
 *   hook). Only the job's own process may check in; it receives the receive
 *   right, and finch-init asks the kernel for a port-destroyed notification
 *   first, so when the job exits the right comes back to finch-init with any
 *   unread messages still queued. Clients' send rights stay valid across
 *   job restarts.
 *
 *   Dynamic (checked in by any process, no declaration). check_in creates
 *   it; it disappears when its owner's receive right is destroyed.
 *
 * Threads: registry state is touched only on the caller's serial queue. A
 * request thread receives bootstrap requests and handles each on that queue;
 * a demand thread waits on the port set of held declared ports.
 */

#include <errno.h>
#include <mach/mach.h>
#include <mach/notify.h>
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
	mach_port_t port;           /* send right, always; plus the receive right while held */
	void *owner;                /* declaring job, or NULL for a dynamic service */
	bool held;                  /* finch-init holds the receive right */
	struct service *next;
};

static struct service *services;
static dispatch_queue_t queue;
static struct bootstrapd_hooks hooks;
static mach_port_t demand_set;       /* held declared ports waiting for a first message */
static mach_port_t notify_port;      /* port-destroyed notifications return receive rights here */

static void
service_free(struct service *s)
{
	mach_port_deallocate(mach_task_self(), s->port);
	free(s);
}

static struct service *
find(const char *name)
{
	struct service **pp = &services, *s;
	mach_port_type_t type;

	while ((s = *pp) != NULL) {
		if (strcmp(s->name, name) == 0) {
			if (s->owner != NULL ||
			    (mach_port_type(mach_task_self(), s->port, &type) == KERN_SUCCESS &&
			    (type & MACH_PORT_TYPE_SEND))) {
				return s;
			}
			/* Dynamic service whose owner is gone: forget it. */
			*pp = s->next;
			service_free(s);
			return NULL;
		}
		pp = &s->next;
	}
	return NULL;
}

static struct service *
find_port(mach_port_t port)
{
	for (struct service *s = services; s != NULL; s = s->next) {
		if (s->port == port) {
			return s;
		}
	}
	return NULL;
}

/* Watch a held declared port for its first message. */
static void
arm(struct service *s)
{
	if (s->owner != NULL && s->held) {
		mach_port_insert_member(mach_task_self(), s->port, demand_set);
	}
}

static void
disarm(struct service *s)
{
	mach_port_extract_member(mach_task_self(), s->port, demand_set);   /* ok if not a member */
}

#pragma mark - Routines

static kern_return_t
check_in(const char *name, pid_t pid, xpc_object_t reply)
{
	struct service *s = find(name);
	mach_port_t port, previous = MACH_PORT_NULL;
	xpc_object_t recv;

	if (s != NULL && s->owner != NULL) {
		if (!s->held) {
			return BOOTSTRAP_SERVICE_ACTIVE;
		}
		if (hooks.may_check_in == NULL || !hooks.may_check_in(s->owner, pid)) {
			return BOOTSTRAP_NOT_PRIVILEGED;
		}
		/* When the job's copy of the receive right dies, it comes back here. */
		if (mach_port_request_notification(mach_task_self(), s->port, MACH_NOTIFY_PORT_DESTROYED, 0,
		        notify_port, MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous) != KERN_SUCCESS) {
			return BOOTSTRAP_NO_MEMORY;
		}
		if (MACH_PORT_VALID(previous)) {
			mach_port_deallocate(mach_task_self(), previous);
		}
		disarm(s);
		s->held = false;
		recv = xpc_mach_recv_create(s->port);   /* the reply moves the receive right */
		xpc_dictionary_set_value(reply, "port", recv);
		xpc_release(recv);
		return BOOTSTRAP_SUCCESS;
	}
	if (s != NULL) {
		return BOOTSTRAP_SERVICE_ACTIVE;
	}
	/* Dynamic service. */
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
		return BOOTSTRAP_NO_MEMORY;
	}
	if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS ||
	    (s = calloc(1, sizeof(*s))) == NULL) {
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
		return BOOTSTRAP_NO_MEMORY;
	}
	strlcpy(s->name, name, sizeof(s->name));
	s->port = port;
	s->next = services;
	services = s;
	recv = xpc_mach_recv_create(port);
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
	send = xpc_mach_send_create(s->port);   /* copies a send right */
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
	pid_t pid;
	kern_return_t kr;

	if (reply == NULL) {
		return;   /* not a routine: nothing to answer */
	}
	xpc_dictionary_get_audit_token(request, &token);
	pid = (pid_t)token.val[5];
	if (name == NULL || strnlen(name, sizeof(name_t)) >= sizeof(name_t)) {
		kr = BOOTSTRAP_BAD_COUNT;
	} else if (routine == ROUTINE_CHECK_IN) {
		kr = check_in(name, pid, reply);
	} else if (routine == ROUTINE_LOOK_UP) {
		kr = look_up(name, reply);
	} else {
		kr = BOOTSTRAP_NOT_PRIVILEGED;   /* routine not implemented */
	}
	xpc_dictionary_set_int64(reply, "error", kr);
	xpc_dictionary_set_int64(reply, "req_pid", pid);
	xpc_dictionary_set_int64(reply, "rec_execcnt", 0);
	xpc_pipe_routine_reply(reply);
	xpc_release(reply);
}

#pragma mark - Declared services

int
bootstrapd_declare(const char *name, void *owner)
{
	struct service *s;
	mach_port_t port;

	if (strnlen(name, sizeof(name_t)) >= sizeof(name_t)) {
		return EINVAL;
	}
	if (find(name) != NULL) {
		return EEXIST;
	}
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
		return ENOMEM;
	}
	if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS ||
	    (s = calloc(1, sizeof(*s))) == NULL) {
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
		return ENOMEM;
	}
	strlcpy(s->name, name, sizeof(s->name));
	s->port = port;
	s->owner = owner;
	s->held = true;
	s->next = services;
	services = s;
	arm(s);
	return 0;
}

void
bootstrapd_rearm(void *owner)
{
	for (struct service *s = services; s != NULL; s = s->next) {
		if (s->owner == owner) {
			arm(s);
		}
	}
}

/* A held declared port has a message waiting (it stays queued). */
static void
demand(mach_port_t port)
{
	struct service *s = find_port(port);

	if (s != NULL && s->owner != NULL && s->held && hooks.demand != NULL) {
		hooks.demand(s->owner);
	}
}

/* A job's receive right died in its process and came back to us. */
static void
port_returned(void)
{
	union {
		mach_port_destroyed_notification_t n;
		uint8_t buf[sizeof(mach_port_destroyed_notification_t) + MAX_TRAILER_SIZE];
	} m;
	struct service *s;
	mach_port_t port;

	while (mach_msg(&m.n.not_header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(m), notify_port, 0,
	    MACH_PORT_NULL) == MACH_MSG_SUCCESS) {
		if (m.n.not_header.msgh_id != MACH_NOTIFY_PORT_DESTROYED) {
			mach_msg_destroy(&m.n.not_header);
			continue;
		}
		/* Same port as our send right, so the same name in our space. */
		port = m.n.not_port.name;
		s = find_port(port);
		if (s == NULL || s->owner == NULL) {
			mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
			continue;
		}
		s->held = true;
		arm(s);
	}
}

#pragma mark - Threads

static void *
request_thread(void *arg)
{
	mach_port_t port = (mach_port_t)(uintptr_t)arg;
	xpc_object_t request;
	int rc;

	pthread_setname_np("bootstrap");
	for (;;) {
		rc = xpc_pipe_receive(port, &request);
		if (rc == 0) {
			dispatch_sync(queue, ^{ bootstrapd_handle(request); });
			xpc_release(request);
		} else if (rc != EAGAIN && rc != EINTR && rc != EINVAL) {
			return NULL;   /* port gone */
		}
	}
}

/*
 * Wait for a message on any held declared port without receiving it: a
 * 16-byte buffer is smaller than any message, so the kernel reports
 * MACH_RCV_TOO_LARGE, names the port (MACH_RCV_LARGE_IDENTITY) and leaves
 * the message queued for the job.
 */
static void *
demand_thread(void *arg)
{
	(void)arg;
	pthread_setname_np("bootstrap-demand");
	for (;;) {
		union { mach_msg_header_t h; uint8_t b[16]; } m;
		kern_return_t kr = mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_LARGE_IDENTITY,
		    0, 16, demand_set, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
		if (kr == MACH_RCV_TOO_LARGE) {
			mach_port_t port = m.h.msgh_local_port;
			/* Stop watching until the job has had its chance (else we'd spin). */
			mach_port_extract_member(mach_task_self(), port, demand_set);
			dispatch_async(queue, ^{ demand(port); });
		} else if (kr == MACH_MSG_SUCCESS) {
			mach_msg_destroy(&m.h);   /* can't happen with a 16-byte buffer */
		} else if (kr != MACH_RCV_INTERRUPTED) {
			return NULL;
		}
	}
}

mach_port_t
bootstrapd_start(dispatch_queue_t q, const struct bootstrapd_hooks *h)
{
	mach_port_t port;
	pthread_t thread;
	dispatch_source_t returned;

	queue = q;
	if (h != NULL) {
		hooks = *h;
	}
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &demand_set) != KERN_SUCCESS ||
	    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &notify_port) != KERN_SUCCESS ||
	    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
		return MACH_PORT_NULL;
	}
	if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
		return MACH_PORT_NULL;
	}
	returned = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, notify_port, 0, queue);
	dispatch_source_set_event_handler(returned, ^{ port_returned(); });
	dispatch_resume(returned);
	if (pthread_create(&thread, NULL, request_thread, (void *)(uintptr_t)port) != 0) {
		return MACH_PORT_NULL;
	}
	pthread_detach(thread);
	if (pthread_create(&thread, NULL, demand_thread, NULL) != 0) {
		return MACH_PORT_NULL;
	}
	pthread_detach(thread);
	return port;
}
