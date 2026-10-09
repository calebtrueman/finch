/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * XPC connections (step X3b): clients, listeners and peers over Mach, using
 * the protocol Apple's libxpc speaks (docs/design/XPC-protocol.md):
 *
 *   client --'w00t' [S: MOVE_RECEIVE, C: MAKE_SEND]--> service/listener port
 *   client --msg 0x10000000 (+ send-once reply right)--> S   (server's end)
 *   server --msg 0x10000000--> C                             (client's end)
 *   server --reply 0x20000000--> send-once reply right
 *
 * Each connection has a serial queue (targeting the caller's queue) on which
 * every event handler call happens, and a dispatch source on its receive
 * port. Death detection uses Mach notifications: a client watches S with a
 * dead-name notification; a peer watches S with a no-senders notification.
 */

#include <Block.h>
#include <bsm/audit.h>
#include <dispatch/dispatch.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

enum xpc_conn_kind { XPC_CONN_CLIENT, XPC_CONN_LISTENER, XPC_CONN_PEER };

struct xpc_connection_s {
	XPC_OBJECT_HEADER;
	os_unfair_lock lock;
	enum xpc_conn_kind kind;
	char *name;                     /* service name, or NULL */
	bool from_endpoint;             /* client of an endpoint (no reconnect) */
	bool connected;                 /* client: handshake sent */
	bool canceled;
	bool activated;                 /* resumed at least once */
	int suspend_count;              /* starts at 1 (created suspended) */

	mach_port_t service_port;       /* client: send right to the listener */
	mach_port_t send_port;          /* client: S (send); peer: C (send) */
	mach_port_t recv_port;          /* client: C; peer: S; listener: listen port */

	dispatch_queue_t queue;         /* serial; events run here */
	dispatch_queue_t target;        /* user target queue (retained) */
	dispatch_source_t source;       /* MACH_RECV on recv_port */
	xpc_handler_t handler;          /* copied block */

	void *context;
	xpc_finalizer_t finalizer;
	audit_token_t audit;            /* sender of the last message received */
};

extern const struct _xpc_type_s _xpc_type_connection;

static void _xpc_connection_deliver(struct xpc_connection_s *c, xpc_object_t event);
static void _xpc_connection_start_source(struct xpc_connection_s *c);
static void _xpc_connection_teardown(struct xpc_connection_s *c);
static void _xpc_connection_activate(struct xpc_connection_s *c);

#pragma mark - Lifecycle

static struct xpc_connection_s *
_xpc_connection_alloc(enum xpc_conn_kind kind, const char *name, dispatch_queue_t target)
{
	struct xpc_connection_s *c = _xpc_object_alloc(XPC_TYPE_CONNECTION, sizeof(*c));

	memset((char *)c + sizeof(struct xpc_object_s), 0, sizeof(*c) - sizeof(struct xpc_object_s));
	c->lock = OS_UNFAIR_LOCK_INIT;
	c->kind = kind;
	c->name = name ? strdup(name) : NULL;
	c->suspend_count = 1;
	c->target = target ? target : dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
	dispatch_retain(c->target);
	/* Not dispatch_queue_create_with_target: that fixes the target, and
	 * xpc_connection_set_target_queue must be able to change it. */
	c->queue = dispatch_queue_create(name ? name : "org.finch.xpc.connection", DISPATCH_QUEUE_SERIAL);
	dispatch_set_target_queue(c->queue, c->target);
	/* Connections are created suspended: no events until xpc_connection_resume. */
	dispatch_suspend(c->queue);
	c->send_port = c->recv_port = c->service_port = MACH_PORT_NULL;
	return c;
}

XPC_INTERNAL void
_xpc_connection_dispose(xpc_object_t obj)
{
	struct xpc_connection_s *c = obj;

	if (c->finalizer) {
		c->finalizer(c->context);
	}
	_xpc_connection_teardown(c);
	if (c->handler) {
		Block_release(c->handler);
	}
	/* dispatch objects must not be released while suspended. */
	while (c->suspend_count-- > 0) {
		dispatch_resume(c->queue);
	}
	dispatch_release(c->queue);
	dispatch_release(c->target);
	free(c->name);
}

/* Release ports (receive side via the source's cancel handler). */
static void
_xpc_connection_teardown(struct xpc_connection_s *c)
{
	if (c->source) {
		dispatch_source_cancel(c->source);
		dispatch_release(c->source);
		c->source = NULL;
	} else if (MACH_PORT_VALID(c->recv_port)) {
		mach_port_mod_refs(mach_task_self(), c->recv_port, MACH_PORT_RIGHT_RECEIVE, -1);
	}
	c->recv_port = MACH_PORT_NULL;
	if (MACH_PORT_VALID(c->send_port)) {
		mach_port_deallocate(mach_task_self(), c->send_port);
	}
	c->send_port = MACH_PORT_NULL;
	if (MACH_PORT_VALID(c->service_port)) {
		mach_port_deallocate(mach_task_self(), c->service_port);
	}
	c->service_port = MACH_PORT_NULL;
	c->connected = false;
}

#pragma mark - Creation

xpc_connection_t
xpc_connection_create(const char *name, dispatch_queue_t targetq)
{
	struct xpc_connection_s *c;
	mach_port_t port;

	if (name != NULL) {
		/* Named, non-Mach XPC services (app-bundled .xpc) are a non-goal for
		 * now; treat the name as a Mach service. */
		return xpc_connection_create_mach_service(name, targetq, 0);
	}
	/* Anonymous listener: a fresh receive right; reach it via an endpoint. */
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
		return NULL;
	}
	c = _xpc_connection_alloc(XPC_CONN_LISTENER, NULL, targetq);
	c->recv_port = port;
	return (xpc_connection_t)c;
}

#include <servers/bootstrap.h>   /* bootstrap.c */

xpc_connection_t
xpc_connection_create_mach_service(const char *name, dispatch_queue_t targetq, uint64_t flags)
{
	struct xpc_connection_s *c;

	if (flags & XPC_CONNECTION_MACH_SERVICE_LISTENER) {
		mach_port_t port = MACH_PORT_NULL;
		if (bootstrap_check_in(bootstrap_port, name, &port) != KERN_SUCCESS) {
			return NULL;
		}
		c = _xpc_connection_alloc(XPC_CONN_LISTENER, name, targetq);
		c->recv_port = port;
		return (xpc_connection_t)c;
	}
	/* Client: looked up at connect time (and again after interruptions). */
	return (xpc_connection_t)_xpc_connection_alloc(XPC_CONN_CLIENT, name, targetq);
}

xpc_connection_t
xpc_connection_create_from_endpoint(xpc_endpoint_t endpoint)
{
	struct xpc_connection_s *c;
	mach_port_t port = xpc_endpoint_copy_listener_port_4sim((xpc_object_t)endpoint);

	if (!MACH_PORT_VALID(port)) {
		return NULL;
	}
	c = _xpc_connection_alloc(XPC_CONN_CLIENT, NULL, NULL);
	c->service_port = port;
	c->from_endpoint = true;
	return (xpc_connection_t)c;
}

xpc_endpoint_t
xpc_endpoint_create(xpc_connection_t connection)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;

	if (c->kind != XPC_CONN_LISTENER || !MACH_PORT_VALID(c->recv_port)) {
		return NULL;
	}
	/* A new send right to the listener port. */
	if (mach_port_insert_right(mach_task_self(), c->recv_port, c->recv_port,
	        MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
		return NULL;
	}
	return (xpc_endpoint_t)_xpc_endpoint_adopt(c->recv_port);
}

#pragma mark - Client connect (handshake)

/* Called with c->lock held. */
static bool
_xpc_connection_connect_locked(struct xpc_connection_s *c)
{
	mach_port_t S = MACH_PORT_NULL, C = MACH_PORT_NULL, prev;
	kern_return_t kr;
	struct {
		mach_msg_header_t h;
		mach_msg_body_t body;
		mach_msg_port_descriptor_t d[2];
	} hs;

	if (c->connected || c->canceled) {
		return c->connected;
	}
	if (!MACH_PORT_VALID(c->service_port)) {
		if (c->from_endpoint || c->name == NULL ||
		    bootstrap_look_up(bootstrap_port, c->name, &c->service_port) != KERN_SUCCESS) {
			return false;
		}
	}
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &S) != KERN_SUCCESS ||
	    mach_port_insert_right(mach_task_self(), S, S, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS ||
	    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &C) != KERN_SUCCESS) {
		return false;
	}
	memset(&hs, 0, sizeof(hs));
	hs.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
	hs.h.msgh_size = sizeof(hs);
	hs.h.msgh_remote_port = c->service_port;
	hs.h.msgh_id = (mach_msg_id_t)XPC_MSGID_HANDSHAKE;
	hs.body.msgh_descriptor_count = 2;
	hs.d[0] = (mach_msg_port_descriptor_t){ .name = S, .disposition = MACH_MSG_TYPE_MOVE_RECEIVE,
	    .type = MACH_MSG_PORT_DESCRIPTOR };
	hs.d[1] = (mach_msg_port_descriptor_t){ .name = C, .disposition = MACH_MSG_TYPE_MAKE_SEND,
	    .type = MACH_MSG_PORT_DESCRIPTOR };
	kr = mach_msg(&hs.h, MACH_SEND_MSG, sizeof(hs), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
	if (kr != MACH_MSG_SUCCESS) {
		mach_port_mod_refs(mach_task_self(), S, MACH_PORT_RIGHT_RECEIVE, -1);
		mach_port_deallocate(mach_task_self(), S);
		mach_port_mod_refs(mach_task_self(), C, MACH_PORT_RIGHT_RECEIVE, -1);
		if (!c->from_endpoint) {
			/* Stale lookup: forget the service port and retry next time. */
			mach_port_deallocate(mach_task_self(), c->service_port);
			c->service_port = MACH_PORT_NULL;
		}
		return false;
	}
	/* We now hold only a send right named S. Learn of the server's death. */
	mach_port_request_notification(mach_task_self(), S, MACH_NOTIFY_DEAD_NAME, 0, C,
	    MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
	if (MACH_PORT_VALID(prev)) {
		mach_port_deallocate(mach_task_self(), prev);
	}
	c->send_port = S;
	c->recv_port = C;
	c->connected = true;
	return true;
}

static bool
_xpc_connection_ensure_connected(struct xpc_connection_s *c)
{
	bool ok;
	bool start = false;

	os_unfair_lock_lock(&c->lock);
	if (c->kind != XPC_CONN_CLIENT) {
		ok = !c->canceled;
	} else {
		bool was = c->connected;
		ok = _xpc_connection_connect_locked(c);
		start = ok && !was;
	}
	os_unfair_lock_unlock(&c->lock);
	if (start) {
		_xpc_connection_start_source(c);
	}
	return ok;
}

#pragma mark - Receiving

static void
_xpc_connection_set_remote(xpc_object_t dict, struct xpc_connection_s *c, mach_msg_header_t *h)
{
	struct _xpc_dictionary_s *d = dict;

	if (MACH_PORT_VALID(h->msgh_remote_port) &&
	    MACH_MSGH_BITS_REMOTE(h->msgh_bits) == MACH_MSG_TYPE_PORT_SEND_ONCE) {
		d->reply_port = h->msgh_remote_port;   /* answered via create_reply */
	} else if (MACH_PORT_VALID(h->msgh_remote_port)) {
		mach_port_deallocate(mach_task_self(), h->msgh_remote_port);
	}
	d->connection = xpc_retain((xpc_object_t)c);
	(void)d;
}

/* A new peer from a listener's 'w00t'. */
static void
_xpc_listener_accept(struct xpc_connection_s *listener, mach_msg_header_t *h)
{
	const mach_msg_body_t *body = (const mach_msg_body_t *)(h + 1);
	const mach_msg_port_descriptor_t *d = (const mach_msg_port_descriptor_t *)(body + 1);
	struct xpc_connection_s *peer;
	mach_port_t prev;

	if (!(h->msgh_bits & MACH_MSGH_BITS_COMPLEX) || body->msgh_descriptor_count != 2 ||
	    d[0].type != MACH_MSG_PORT_DESCRIPTOR || d[1].type != MACH_MSG_PORT_DESCRIPTOR ||
	    d[0].disposition != MACH_MSG_TYPE_PORT_RECEIVE ||
	    d[1].disposition != MACH_MSG_TYPE_PORT_SEND) {
		mach_msg_destroy(h);
		return;
	}
	peer = _xpc_connection_alloc(XPC_CONN_PEER, listener->name, listener->target);
	peer->recv_port = d[0].name;
	peer->send_port = d[1].name;
	peer->connected = true;
	peer->audit = listener->audit;   /* the client, which sent the handshake */
	/* Learn when the client is gone (its send rights to S all die). */
	mach_port_request_notification(mach_task_self(), peer->recv_port, MACH_NOTIFY_NO_SENDERS,
	    0, peer->recv_port, MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev);
	if (MACH_PORT_VALID(prev)) {
		mach_port_deallocate(mach_task_self(), prev);
	}
	_xpc_connection_deliver(listener, (xpc_object_t)peer);   /* consumes */
}

/* Drain the receive port (runs on c->queue). */
static void
_xpc_connection_receive(struct xpc_connection_s *c)
{
	for (;;) {
		mach_msg_header_t *h = NULL;
		kern_return_t kr = _xpc_message_receive(c->recv_port, MACH_RCV_TIMEOUT, 0, &h);

		if (kr != MACH_MSG_SUCCESS) {
			return;
		}
		mach_msg_audit_trailer_t *t = (mach_msg_audit_trailer_t *)
		    ((uint8_t *)h + round_msg(h->msgh_size));
		c->audit = t->msgh_audit;

		switch (h->msgh_id) {
		case XPC_MSGID_HANDSHAKE:
			if (c->kind == XPC_CONN_LISTENER) {
				_xpc_listener_accept(c, h);
			} else {
				mach_msg_destroy(h);
			}
			break;
		case XPC_MSGID_MESSAGE:
		case XPC_MSGID_PIPE_ROUTINE: {
			xpc_object_t dict = _xpc_message_decode(h);
			if (dict != NULL) {
				_xpc_connection_set_remote(dict, c, h);
				_xpc_connection_deliver(c, dict);
			} else if (MACH_PORT_VALID(h->msgh_remote_port)) {
				mach_port_deallocate(mach_task_self(), h->msgh_remote_port);
			}
			break;
		}
		case MACH_NOTIFY_DEAD_NAME: {
			/* Client: the server's end died. */
			mach_dead_name_notification_t *n = (mach_dead_name_notification_t *)h;
			/* The notification's reference to the dead name. It may already be
			 * gone: a client in the same task as its listener can see the
			 * notification after canceling (the name is then reused or
			 * invalid, and deallocating it trips a Mach port guard). */
			mach_port_type_t type = 0;
			if (mach_port_type(mach_task_self(), n->not_port, &type) == KERN_SUCCESS &&
			    (type & MACH_PORT_TYPE_DEAD_NAME)) {
				mach_port_deallocate(mach_task_self(), n->not_port);
			}
			os_unfair_lock_lock(&c->lock);
			bool gone = c->canceled;
			os_unfair_lock_unlock(&c->lock);
			if (gone) {
				free(h);
				return;
			}
			os_unfair_lock_lock(&c->lock);
			bool reconnectable = !c->from_endpoint && c->name != NULL;
			os_unfair_lock_unlock(&c->lock);
			if (reconnectable) {
				/* Drop this session; the next send performs a new handshake. */
				_xpc_connection_deliver(c, (xpc_object_t)XPC_ERROR_CONNECTION_INTERRUPTED);
				os_unfair_lock_lock(&c->lock);
				dispatch_source_t s = c->source;
				c->source = NULL;
				mach_port_deallocate(mach_task_self(), c->send_port);
				c->send_port = MACH_PORT_NULL;
				c->connected = false;
				mach_port_deallocate(mach_task_self(), c->service_port);
				c->service_port = MACH_PORT_NULL;
				os_unfair_lock_unlock(&c->lock);
				if (s) {
					dispatch_source_cancel(s);   /* releases C */
					dispatch_release(s);
				}
				free(h);
				return;
			}
			xpc_connection_cancel((xpc_connection_t)c);
			free(h);
			return;
		}
		case MACH_NOTIFY_NO_SENDERS:
			/* Peer: the client is gone. */
			xpc_connection_cancel((xpc_connection_t)c);
			free(h);
			return;
		default:
			mach_msg_destroy(h);
			break;
		}
		free(h);
	}
}

static void
_xpc_connection_start_source(struct xpc_connection_s *c)
{
	dispatch_source_t s;
	mach_port_t port;

	os_unfair_lock_lock(&c->lock);
	if (c->source != NULL || !MACH_PORT_VALID(c->recv_port) || c->canceled) {
		os_unfair_lock_unlock(&c->lock);
		return;
	}
	port = c->recv_port;
	s = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, c->queue);
	c->source = s;
	os_unfair_lock_unlock(&c->lock);

	xpc_retain((xpc_object_t)c);   /* held by the source until it's canceled */
	dispatch_source_set_event_handler(s, ^{
		_xpc_connection_receive(c);
	});
	dispatch_source_set_cancel_handler(s, ^{
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
		xpc_release((xpc_object_t)c);
	});
	dispatch_resume(s);
}

/* Call the event handler on the connection queue; consumes `event`. */
static void
_xpc_connection_deliver(struct xpc_connection_s *c, xpc_object_t event)
{
	xpc_retain((xpc_object_t)c);
	dispatch_async(c->queue, ^{
		xpc_handler_t handler = NULL;
		os_unfair_lock_lock(&c->lock);
		if (c->handler) {
			handler = Block_copy(c->handler);
		}
		os_unfair_lock_unlock(&c->lock);
		if (handler) {
			handler(event);
			Block_release(handler);
		}
		xpc_release(event);
		xpc_release((xpc_object_t)c);
	});
}

#pragma mark - Public API

void
xpc_connection_set_event_handler(xpc_connection_t connection, xpc_handler_t handler)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;
	xpc_handler_t old;

	os_unfair_lock_lock(&c->lock);
	old = c->handler;
	c->handler = Block_copy(handler);
	os_unfair_lock_unlock(&c->lock);
	if (old) {
		Block_release(old);
	}
}

void
xpc_connection_set_target_queue(xpc_connection_t connection, dispatch_queue_t targetq)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;

	if (targetq == NULL) {
		targetq = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
	}
	dispatch_set_target_queue(c->queue, targetq);
}

void
xpc_connection_resume(xpc_connection_t connection)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;
	bool resume_queue = false, first = false;

	os_unfair_lock_lock(&c->lock);
	if (c->suspend_count > 0) {
		c->suspend_count--;
		resume_queue = true;
		if (c->suspend_count == 0 && !c->activated) {
			c->activated = first = true;
		}
	}
	os_unfair_lock_unlock(&c->lock);
	if (resume_queue) {
		dispatch_resume(c->queue);
	}
	if (first) {
		_xpc_connection_activate(c);
	}
}

void
xpc_connection_suspend(xpc_connection_t connection)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;

	os_unfair_lock_lock(&c->lock);
	c->suspend_count++;
	os_unfair_lock_unlock(&c->lock);
	dispatch_suspend(c->queue);
}

void
xpc_connection_cancel(xpc_connection_t connection)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;
	dispatch_source_t s;
	mach_port_t send, service, recv;

	os_unfair_lock_lock(&c->lock);
	if (c->canceled) {
		os_unfair_lock_unlock(&c->lock);
		return;
	}
	c->canceled = true;
	s = c->source;
	c->source = NULL;
	send = c->send_port;
	service = c->service_port;
	recv = s ? MACH_PORT_NULL : c->recv_port;   /* without a source, release here */
	c->send_port = c->service_port = c->recv_port = MACH_PORT_NULL;
	c->connected = false;
	os_unfair_lock_unlock(&c->lock);

	if (s) {
		dispatch_source_cancel(s);
		dispatch_release(s);
	}
	if (MACH_PORT_VALID(recv)) {
		mach_port_mod_refs(mach_task_self(), recv, MACH_PORT_RIGHT_RECEIVE, -1);
	}
	if (MACH_PORT_VALID(send)) {
		if (c->kind == XPC_CONN_CLIENT) {
			/* No dead-name notification for a name we're giving up. */
			mach_port_t prev = MACH_PORT_NULL;
			if (mach_port_request_notification(mach_task_self(), send, MACH_NOTIFY_DEAD_NAME, 0,
			        MACH_PORT_NULL, MACH_MSG_TYPE_MAKE_SEND_ONCE, &prev) == KERN_SUCCESS && MACH_PORT_VALID(prev)) {
				mach_port_deallocate(mach_task_self(), prev);
			}
		}
		mach_port_deallocate(mach_task_self(), send);
	}
	if (MACH_PORT_VALID(service)) {
		mach_port_deallocate(mach_task_self(), service);
	}
	/* The last event a connection's handler sees. */
	_xpc_connection_deliver(c, (xpc_object_t)XPC_ERROR_CONNECTION_INVALID);
}

/* Replies created with xpc_dictionary_create_reply go to their reply right. */
static bool
_xpc_send_reply_if_reply(xpc_object_t message)
{
	struct _xpc_dictionary_s *d = message;
	mach_port_t rp;

	if (d->reply_msgid != XPC_MSGID_REPLY || !MACH_PORT_VALID(d->reply_port)) {
		return false;
	}
	rp = d->reply_port;
	d->reply_port = MACH_PORT_NULL;
	if (_xpc_message_send(rp, MACH_MSG_TYPE_MOVE_SEND_ONCE, message, XPC_MSGID_REPLY,
	        MACH_PORT_NULL, 0, 0, MACH_MSG_TIMEOUT_NONE) != MACH_MSG_SUCCESS) {
		mach_port_deallocate(mach_task_self(), rp);
	}
	return true;
}

void
xpc_connection_send_message(xpc_connection_t connection, xpc_object_t message)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;
	mach_port_t dest;

	if (xpc_get_type(message) != XPC_TYPE_DICTIONARY || _xpc_send_reply_if_reply(message)) {
		return;
	}
	if (!_xpc_connection_ensure_connected(c)) {
		return;
	}
	os_unfair_lock_lock(&c->lock);
	dest = c->send_port;
	if (MACH_PORT_VALID(dest)) {
		mach_port_mod_refs(mach_task_self(), dest, MACH_PORT_RIGHT_SEND, 1);
	}
	os_unfair_lock_unlock(&c->lock);
	if (MACH_PORT_VALID(dest)) {
		_xpc_message_send(dest, MACH_MSG_TYPE_MOVE_SEND, message, XPC_MSGID_MESSAGE,
		    MACH_PORT_NULL, 0, 0, MACH_MSG_TIMEOUT_NONE);
	}
}

/* Send `message` with a fresh reply port; returns the port (receive right) or NULL. */
static mach_port_t
_xpc_connection_send_request(struct xpc_connection_s *c, xpc_object_t message)
{
	mach_port_t rp = MACH_PORT_NULL, dest;
	kern_return_t kr;

	if (!_xpc_connection_ensure_connected(c) ||
	    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp) != KERN_SUCCESS) {
		return MACH_PORT_NULL;
	}
	os_unfair_lock_lock(&c->lock);
	dest = c->send_port;
	if (MACH_PORT_VALID(dest)) {
		mach_port_mod_refs(mach_task_self(), dest, MACH_PORT_RIGHT_SEND, 1);
	}
	os_unfair_lock_unlock(&c->lock);
	if (!MACH_PORT_VALID(dest)) {
		mach_port_mod_refs(mach_task_self(), rp, MACH_PORT_RIGHT_RECEIVE, -1);
		return MACH_PORT_NULL;
	}
	kr = _xpc_message_send(dest, MACH_MSG_TYPE_MOVE_SEND, message, XPC_MSGID_MESSAGE,
	    rp, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0, MACH_MSG_TIMEOUT_NONE);
	if (kr != MACH_MSG_SUCCESS) {
		mach_port_mod_refs(mach_task_self(), rp, MACH_PORT_RIGHT_RECEIVE, -1);
		return MACH_PORT_NULL;
	}
	return rp;
}

/* A reply, or (send-once notification / failure) the interrupted error. A
 * reply also tells the client who the server is (its audit token). */
static xpc_object_t
_xpc_connection_take_reply(struct xpc_connection_s *c, mach_port_t rp, mach_msg_option_t opts)
{
	mach_msg_header_t *h = NULL;
	xpc_object_t reply = NULL;

	if (_xpc_message_receive(rp, opts, 0, &h) == MACH_MSG_SUCCESS) {
		if (h->msgh_id == (mach_msg_id_t)XPC_MSGID_REPLY) {
			reply = _xpc_message_decode(h);
			if (reply != NULL) {
				mach_msg_audit_trailer_t *t = (mach_msg_audit_trailer_t *)
				    ((uint8_t *)h + round_msg(h->msgh_size));
				os_unfair_lock_lock(&c->lock);
				c->audit = t->msgh_audit;
				os_unfair_lock_unlock(&c->lock);
			}
		} else {
			mach_msg_destroy(h);   /* e.g. MACH_NOTIFY_SEND_ONCE: request dropped */
		}
		free(h);
	}
	return reply ? reply : xpc_retain((xpc_object_t)XPC_ERROR_CONNECTION_INTERRUPTED);
}

void
xpc_connection_send_message_with_reply(xpc_connection_t connection, xpc_object_t message,
    dispatch_queue_t replyq, xpc_handler_t handler)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;
	mach_port_t rp = _xpc_connection_send_request(c, message);
	dispatch_queue_t q = replyq ? replyq : c->queue;
	xpc_handler_t h = Block_copy(handler);

	if (!MACH_PORT_VALID(rp)) {
		dispatch_async(q, ^{
			h((xpc_object_t)XPC_ERROR_CONNECTION_INVALID);
			Block_release(h);
		});
		return;
	}
	dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, rp, 0, q);
	xpc_retain((xpc_object_t)c);   /* until the reply (or its failure) is in */
	dispatch_source_set_event_handler(s, ^{
		xpc_object_t reply = _xpc_connection_take_reply(c, rp, MACH_RCV_TIMEOUT);
		dispatch_source_cancel(s);
		h(reply);
		xpc_release(reply);
	});
	dispatch_source_set_cancel_handler(s, ^{
		mach_port_mod_refs(mach_task_self(), rp, MACH_PORT_RIGHT_RECEIVE, -1);
		Block_release(h);
		dispatch_release(s);
		xpc_release((xpc_object_t)c);
	});
	dispatch_resume(s);
}

xpc_object_t
xpc_connection_send_message_with_reply_sync(xpc_connection_t connection, xpc_object_t message)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;
	mach_port_t rp = _xpc_connection_send_request(c, message);
	xpc_object_t reply;

	if (!MACH_PORT_VALID(rp)) {
		return xpc_retain((xpc_object_t)XPC_ERROR_CONNECTION_INVALID);
	}
	reply = _xpc_connection_take_reply(c, rp, 0);
	mach_port_mod_refs(mach_task_self(), rp, MACH_PORT_RIGHT_RECEIVE, -1);
	return reply;
}

void
xpc_connection_send_barrier(xpc_connection_t connection, dispatch_block_t barrier)
{
	struct xpc_connection_s *c = (struct xpc_connection_s *)connection;
	dispatch_block_t b = Block_copy(barrier);

	/* Sends are synchronous, so everything sent before this call is out. */
	dispatch_async(c->queue, ^{
		b();
		Block_release(b);
	});
}

/* Resuming a client connects it (Apple sends the handshake on resume). */
static void
_xpc_connection_activate(struct xpc_connection_s *c)
{
	if (c->kind == XPC_CONN_CLIENT) {
		_xpc_connection_ensure_connected(c);
	} else {
		_xpc_connection_start_source(c);
	}
}

const char *
xpc_connection_get_name(xpc_connection_t connection)
{
	return ((struct xpc_connection_s *)connection)->name;
}

/* audit_token_t layout (bsm): val[1] euid, val[2] egid, val[5] pid, val[6] asid. */
uid_t
xpc_connection_get_euid(xpc_connection_t connection)
{
	return (uid_t)((struct xpc_connection_s *)connection)->audit.val[1];
}

gid_t
xpc_connection_get_egid(xpc_connection_t connection)
{
	return (gid_t)((struct xpc_connection_s *)connection)->audit.val[2];
}

pid_t
xpc_connection_get_pid(xpc_connection_t connection)
{
	return (pid_t)((struct xpc_connection_s *)connection)->audit.val[5];
}

au_asid_t
xpc_connection_get_asid(xpc_connection_t connection)
{
	return (au_asid_t)((struct xpc_connection_s *)connection)->audit.val[6];
}

/* Private: the full audit token of the peer's last message. */
void
xpc_connection_get_audit_token(xpc_connection_t connection, audit_token_t *token)
{
	*token = ((struct xpc_connection_s *)connection)->audit;
}

void
xpc_connection_set_context(xpc_connection_t connection, void *context)
{
	((struct xpc_connection_s *)connection)->context = context;
}

void *
xpc_connection_get_context(xpc_connection_t connection)
{
	return ((struct xpc_connection_s *)connection)->context;
}

void
xpc_connection_set_finalizer_f(xpc_connection_t connection, xpc_finalizer_t finalizer)
{
	((struct xpc_connection_s *)connection)->finalizer = finalizer;
}

xpc_connection_t
xpc_dictionary_get_remote_connection(xpc_object_t xdict)
{
	if (xpc_get_type(xdict) != XPC_TYPE_DICTIONARY) {
		return NULL;
	}
	return (xpc_connection_t)((struct _xpc_dictionary_s *)xdict)->connection;
}
