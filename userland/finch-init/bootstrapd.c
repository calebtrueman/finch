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
 * Services live in domains: the system domain, and per-user domains under it.
 * Each domain has its own port, which its processes inherit as their
 * bootstrap port, so the port a request arrives on names the caller's
 * domain. A look-up searches the caller's domain, then its parent; a check-in
 * registers in the caller's domain only.
 *
 * Threads: registry state is touched only on the caller's serial queue. Each
 * domain has a request thread that receives its bootstrap requests and
 * handles each on that queue (and frees the domain once it's destroyed); a
 * demand thread waits on the port set of every domain's held declared ports.
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

struct domain {
	mach_port_t port;           /* receive right and one send right */
	struct domain *parent;      /* NULL for the system domain */
	struct service *services;
	void *context;              /* the job manager's, passed to the control hook */
	bool dead;                  /* destroyed; its request thread frees it */
	struct domain *next;
};

static struct domain *domains;  /* the system domain is last */
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

/* `name` in `d` itself. */
static struct service *
find_in(struct domain *d, const char *name)
{
	struct service **pp = &d->services, *s;
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

/* `name` as `d`'s processes see it: in `d`, else in its ancestors. */
static struct service *
find(struct domain *d, const char *name)
{
	struct service *s = NULL;

	for (; d != NULL && s == NULL; d = d->parent) {
		s = find_in(d, name);
	}
	return s;
}

static struct service *
find_port(mach_port_t port)
{
	for (struct domain *d = domains; d != NULL; d = d->next) {
		for (struct service *s = d->services; s != NULL; s = s->next) {
			if (s->port == port) {
				return s;
			}
		}
	}
	return NULL;
}

static struct domain *
domain_for_port(mach_port_t port)
{
	for (struct domain *d = domains; d != NULL; d = d->next) {
		if (d->port == port) {
			return d;
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
check_in(struct domain *d, const char *name, pid_t pid, xpc_object_t reply)
{
	struct service *s = find_in(d, name);
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
	s->next = d->services;
	d->services = s;
	recv = xpc_mach_recv_create(port);
	xpc_dictionary_set_value(reply, "port", recv);
	xpc_release(recv);
	return BOOTSTRAP_SUCCESS;
}

static kern_return_t
look_up(struct domain *d, const char *name, xpc_object_t reply)
{
	struct service *s = find(d, name);
	xpc_object_t send;

	if (s == NULL) {
		return BOOTSTRAP_UNKNOWN_SERVICE;
	}
	send = xpc_mach_send_create(s->port);   /* copies a send right */
	xpc_dictionary_set_value(reply, "port", send);
	xpc_release(send);
	return BOOTSTRAP_SUCCESS;
}

/* bootstrap_parent(): the parent domain's port (the system domain is its own
 * parent). Only root may climb out of its domain, as with launchd. */
static int
parent(struct domain *d, const audit_token_t *token, xpc_object_t reply)
{
	xpc_object_t send;

	if (d->parent != NULL && token->val[1] != 0) {
		return EPERM;
	}
	send = xpc_mach_send_create(d->parent ? d->parent->port : d->port);
	xpc_dictionary_set_value(reply, "port", send);
	xpc_release(send);
	return 0;
}

static void
handle(struct domain *d, xpc_object_t request)
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
	if (d == NULL) {
		kr = BOOTSTRAP_UNKNOWN_SERVICE;   /* the domain was destroyed */
	} else if (routine == 0 && xpc_dictionary_get_string(request, "op") != NULL) {
		/* finch-init control request (launchctl, libxpc); answered by the job manager. */
		if (strcmp(xpc_dictionary_get_string(request, "op"), "parent") == 0) {
			kr = parent(d, &token, reply);
		} else {
			kr = hooks.control != NULL ? hooks.control(d->context, request, reply, &token) :
			    BOOTSTRAP_NOT_PRIVILEGED;
		}
	} else if (name == NULL || strnlen(name, sizeof(name_t)) >= sizeof(name_t)) {
		kr = BOOTSTRAP_BAD_COUNT;
	} else if (routine == ROUTINE_CHECK_IN) {
		kr = check_in(d, name, pid, reply);
	} else if (routine == ROUTINE_LOOK_UP) {
		kr = look_up(d, name, reply);
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
bootstrapd_declare(mach_port_t domain, const char *name, void *owner)
{
	struct domain *d = domain_for_port(domain);
	struct service *s;
	mach_port_t port;

	if (d == NULL) {
		return ESRCH;
	}
	if (strnlen(name, sizeof(name_t)) >= sizeof(name_t)) {
		return EINVAL;
	}
	if (find_in(d, name) != NULL) {
		return EEXIST;   /* a name in the parent may be shadowed, as in launchd */
	}
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
		return ENOMEM;
	}
	if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS ||
	    (s = calloc(1, sizeof(*s))) == NULL) {
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
		return ENOMEM;
	}
	/* Messages wait here until the job checks in: every process registers with the log
	 * service as it starts, for one. A full queue (5 messages by default) would block
	 * them all, and the job too, if it sends to its own service before checking in. */
	mach_port_limits_t limits = {.mpl_qlimit = MACH_PORT_QLIMIT_LARGE};
	(void)mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits,
	    MACH_PORT_LIMITS_INFO_COUNT);
	strlcpy(s->name, name, sizeof(s->name));
	s->port = port;
	s->owner = owner;
	s->held = true;
	s->next = d->services;
	d->services = s;
	arm(s);
	return 0;
}

void
bootstrapd_rearm(void *owner)
{
	for (struct domain *d = domains; d != NULL; d = d->next) {
		for (struct service *s = d->services; s != NULL; s = s->next) {
			if (s->owner == owner) {
				arm(s);
			}
		}
	}
}

/* Remove one service from its domain's list (already unlinked by the caller). */
static void
service_drop(struct service *s)
{
	disarm(s);
	if (s->owner != NULL && s->held) {
		mach_port_mod_refs(mach_task_self(), s->port, MACH_PORT_RIGHT_RECEIVE, -1);
	}
	service_free(s);
}

/* Forget `owner`'s services (its job is being unloaded). Clients' send rights
 * die once the receive right is gone; one that a running job holds comes back
 * through port-destroyed, finds no service, and is destroyed then. */
void
bootstrapd_undeclare(void *owner)
{
	for (struct domain *d = domains; d != NULL; d = d->next) {
		struct service **pp = &d->services, *s;

		while ((s = *pp) != NULL) {
			if (s->owner != owner) {
				pp = &s->next;
				continue;
			}
			*pp = s->next;
			service_drop(s);
		}
	}
}

void
bootstrapd_describe(void *owner, xpc_object_t out)
{
	for (struct domain *d = domains; d != NULL; d = d->next) {
		for (struct service *s = d->services; s != NULL; s = s->next) {
			if (s->owner != owner) continue;
			xpc_object_t desc = xpc_dictionary_create(NULL, NULL, 0);
			mach_port_status_t st;
			mach_msg_type_number_t n = MACH_PORT_RECEIVE_STATUS_COUNT;

			xpc_dictionary_set_string(desc, "name", s->name);
			xpc_dictionary_set_bool(desc, "active", !s->held);
			if (s->held && mach_port_get_attributes(mach_task_self(), s->port, MACH_PORT_RECEIVE_STATUS,
			        (mach_port_info_t)&st, &n) == KERN_SUCCESS) {
				xpc_dictionary_set_uint64(desc, "queued", st.mps_msgcount);
			}
			xpc_array_append_value(out, desc);
			xpc_release(desc);
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
	struct domain *d = arg;
	mach_port_t port = d->port;
	xpc_object_t request;
	__block bool dead = false;
	int rc;

	pthread_setname_np("bootstrap");
	while (!dead) {
		rc = xpc_pipe_receive(port, &request);
		if (rc == 0) {
			dispatch_sync(queue, ^{
				dead = d->dead;
				handle(dead ? NULL : d, request);
			});
			xpc_release(request);
		} else if (rc != EAGAIN && rc != EINTR && rc != EINVAL) {
			break;   /* port gone: the domain was destroyed */
		}
	}
	/* Only this thread may still refer to a destroyed domain. */
	dispatch_sync(queue, ^{
		if (d->dead) free(d);
	});
	return NULL;
}

static mach_port_t
domain_create(struct domain *parent_domain, void *context)
{
	struct domain *d;
	mach_port_t port;
	pthread_t thread;

	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
		return MACH_PORT_NULL;
	}
	if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS ||
	    (d = calloc(1, sizeof(*d))) == NULL) {
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
		return MACH_PORT_NULL;
	}
	d->port = port;
	d->parent = parent_domain;
	d->context = context;
	if (pthread_create(&thread, NULL, request_thread, d) != 0) {
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
		mach_port_deallocate(mach_task_self(), port);
		free(d);
		return MACH_PORT_NULL;
	}
	pthread_detach(thread);
	d->next = domains;
	domains = d;
	return port;
}

mach_port_t
bootstrapd_domain_create(mach_port_t parent_port, void *context)
{
	struct domain *p = domain_for_port(parent_port);
	return p != NULL ? domain_create(p, context) : MACH_PORT_NULL;
}

void
bootstrapd_domain_destroy(mach_port_t port)
{
	struct domain **pp, *d = NULL;
	struct service *s;

	for (pp = &domains; *pp != NULL; pp = &(*pp)->next) {
		if ((*pp)->port == port && (*pp)->parent != NULL) {
			d = *pp;
			*pp = d->next;
			break;
		}
	}
	if (d == NULL) {
		return;
	}
	while ((s = d->services) != NULL) {
		d->services = s->next;
		service_drop(s);
	}
	d->dead = true;
	/* Its request thread's receive fails now, and it frees `d`. Processes'
	 * send rights to the port become dead names. */
	mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
	mach_port_deallocate(mach_task_self(), port);
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
bootstrapd_start(dispatch_queue_t q, const struct bootstrapd_hooks *h, void *context)
{
	pthread_t thread;
	dispatch_source_t returned;

	queue = q;
	if (h != NULL) {
		hooks = *h;
	}
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &demand_set) != KERN_SUCCESS ||
	    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &notify_port) != KERN_SUCCESS) {
		return MACH_PORT_NULL;
	}
	returned = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, notify_port, 0, queue);
	dispatch_source_set_event_handler(returned, ^{ port_returned(); });
	dispatch_resume(returned);
	if (pthread_create(&thread, NULL, demand_thread, NULL) != 0) {
		return MACH_PORT_NULL;
	}
	pthread_detach(thread);
	/* Domains are created on the queue, like every other registry change. */
	__block mach_port_t port;
	dispatch_sync(q, ^{ port = domain_create(NULL, context); });
	return port;
}
