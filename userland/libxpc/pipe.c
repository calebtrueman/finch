/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * xpc_pipe: synchronous request/response over Mach (libxpc private API, used
 * by e.g. Libinfo to talk to directory services). Wire protocol: requests are
 * msgh_id 0x40000000 with a send-once reply right, one-way messages
 * 0x10000000, replies 0x20000000 (docs/design/XPC-protocol.md).
 */

#include <errno.h>
#include <stdlib.h>

#include "internal.h"

struct xpc_pipe_s {
	XPC_OBJECT_HEADER;
	mach_port_t port;           /* owned send right to the server */
};

extern const struct _xpc_type_s _xpc_type_pipe;
#define XPC_TYPE_PIPE (&_xpc_type_pipe)

typedef struct xpc_pipe_s *xpc_pipe_t;

/* Same names and signatures as Apple's private exports. */
xpc_pipe_t xpc_pipe_create_from_port(mach_port_t port, uint64_t flags);
void xpc_pipe_invalidate(xpc_pipe_t pipe);
int xpc_pipe_simpleroutine(xpc_pipe_t pipe, xpc_object_t message);
int xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply);
int xpc_pipe_routine_with_flags(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply, uint64_t flags);
int xpc_pipe_receive(mach_port_t port, xpc_object_t *message);
int xpc_pipe_routine_reply(xpc_object_t reply);

static int
_xpc_errno_from_kr(kern_return_t kr)
{
	switch (kr) {
	case MACH_MSG_SUCCESS: return 0;
	case MACH_SEND_INVALID_DEST:
	case MACH_RCV_PORT_DIED: return EPIPE;
	case MACH_SEND_TIMED_OUT:
	case MACH_RCV_TIMED_OUT: return ETIMEDOUT;
	case KERN_INVALID_ARGUMENT: return EINVAL;
	default: return EIO;
	}
}

XPC_INTERNAL void
_xpc_pipe_dispose(xpc_object_t obj)
{
	struct xpc_pipe_s *pipe = obj;

	if (MACH_PORT_VALID(pipe->port)) {
		mach_port_deallocate(mach_task_self(), pipe->port);
	}
}

/* Takes an additional send right; the caller keeps its own. */
xpc_pipe_t
xpc_pipe_create_from_port(mach_port_t port, uint64_t flags)
{
	struct xpc_pipe_s *pipe;

	(void)flags;
	if (!MACH_PORT_VALID(port) ||
	    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) {
		return NULL;
	}
	pipe = _xpc_object_alloc(XPC_TYPE_PIPE, sizeof(*pipe));
	pipe->port = port;
	return pipe;
}

void
xpc_pipe_invalidate(xpc_pipe_t pipe)
{
	if (MACH_PORT_VALID(pipe->port)) {
		mach_port_deallocate(mach_task_self(), pipe->port);
	}
	pipe->port = MACH_PORT_DEAD;
}

int
xpc_pipe_simpleroutine(xpc_pipe_t pipe, xpc_object_t message)
{
	if (!MACH_PORT_VALID(pipe->port)) {
		return EPIPE;
	}
	return _xpc_errno_from_kr(_xpc_message_send(pipe->port, MACH_MSG_TYPE_COPY_SEND,
	    message, XPC_MSGID_MESSAGE, MACH_PORT_NULL, 0, 0, MACH_MSG_TIMEOUT_NONE));
}

static pid_t
_xpc_trailer_pid(mach_msg_header_t *h)
{
	mach_msg_audit_trailer_t *t = (void *)((uint8_t *)h + round_msg(h->msgh_size));
	return t->msgh_trailer_size >= sizeof(*t) ? (pid_t)t->msgh_audit.val[5] : -1;
}

int
_xpc_pipe_routine_port(mach_port_t port, uint32_t msgid, xpc_object_t message,
    xpc_object_t *reply, pid_t *sender_pid)
{
	mach_port_t rp = MACH_PORT_NULL;
	mach_msg_header_t *h = NULL;
	kern_return_t kr;

	*reply = NULL;
	if (!MACH_PORT_VALID(port)) {
		return EPIPE;
	}
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rp) != KERN_SUCCESS) {
		return ENOMEM;
	}
	kr = _xpc_message_send(port, MACH_MSG_TYPE_COPY_SEND, message,
	    msgid, rp, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0, MACH_MSG_TIMEOUT_NONE);
	if (kr == MACH_MSG_SUCCESS) {
		/* If the server drops the request, the send-once right dies and the
		 * kernel delivers a send-once notification here instead of a reply. */
		kr = _xpc_message_receive(rp, 0, MACH_MSG_TIMEOUT_NONE, &h);
	}
	if (kr == MACH_MSG_SUCCESS) {
		if (h->msgh_id == (mach_msg_id_t)XPC_MSGID_REPLY) {
			if (sender_pid) {
				*sender_pid = _xpc_trailer_pid(h);
			}
			*reply = _xpc_message_decode(h);
		} else {
			mach_msg_destroy(h);
		}
		free(h);
		kr = *reply ? KERN_SUCCESS : MACH_RCV_PORT_DIED;
	}
	mach_port_mod_refs(mach_task_self(), rp, MACH_PORT_RIGHT_RECEIVE, -1);
	return _xpc_errno_from_kr(kr);
}

int
xpc_pipe_routine_with_flags(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply, uint64_t flags)
{
	(void)flags;
	return _xpc_pipe_routine_port(pipe->port, XPC_MSGID_PIPE_ROUTINE, message, reply, NULL);
}

int
xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply)
{
	return xpc_pipe_routine_with_flags(pipe, message, reply, 0);
}

/* Server side: wait for one request on `port`. */
int
xpc_pipe_receive(mach_port_t port, xpc_object_t *message)
{
	mach_msg_header_t *h = NULL;
	kern_return_t kr = _xpc_message_receive(port, 0, MACH_MSG_TIMEOUT_NONE, &h);
	struct _xpc_dictionary_s *d;

	*message = NULL;
	if (kr != MACH_MSG_SUCCESS) {
		return _xpc_errno_from_kr(kr);
	}
	d = _xpc_message_decode(h);
	if (d != NULL) {
		mach_msg_audit_trailer_t *t = (void *)((uint8_t *)h + round_msg(h->msgh_size));
		d->msgid = (uint32_t)h->msgh_id;
		if (t->msgh_trailer_size >= sizeof(*t)) {
			d->has_audit = true;
			d->audit = t->msgh_audit;
		}
	}
	if (d != NULL && MACH_PORT_VALID(h->msgh_remote_port) &&
	    MACH_MSGH_BITS_REMOTE(h->msgh_bits) == MACH_MSG_TYPE_PORT_SEND_ONCE) {
		d->reply_port = h->msgh_remote_port;   /* answered via create_reply */
	} else if (MACH_PORT_VALID(h->msgh_remote_port)) {
		mach_port_deallocate(mach_task_self(), h->msgh_remote_port);
	}
	free(h);
	*message = d;
	return d ? 0 : EINVAL;
}

/* Send a reply created with xpc_dictionary_create_reply(). */
int
xpc_pipe_routine_reply(xpc_object_t reply)
{
	struct _xpc_dictionary_s *d = reply;
	mach_port_t rp;
	kern_return_t kr;

	if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY || !MACH_PORT_VALID(d->reply_port)) {
		return EINVAL;
	}
	rp = d->reply_port;
	d->reply_port = MACH_PORT_NULL;
	kr = _xpc_message_send(rp, MACH_MSG_TYPE_MOVE_SEND_ONCE, reply, XPC_MSGID_REPLY,
	    MACH_PORT_NULL, 0, 0, MACH_MSG_TIMEOUT_NONE);
	if (kr != MACH_MSG_SUCCESS) {
		mach_port_deallocate(mach_task_self(), rp);
	}
	return _xpc_errno_from_kr(kr);
}

/* Finch SPI for finch-init's bootstrap server: the routine number of a request
 * received with xpc_pipe_receive (launchd-style msgh_id 0x40000000 | routine),
 * or 0 for a plain pipe request. */
uint32_t finch_xpc_pipe_request_routine(xpc_object_t request);

uint32_t
finch_xpc_pipe_request_routine(xpc_object_t request)
{
	struct _xpc_dictionary_s *d = request;

	if (xpc_get_type(request) != XPC_TYPE_DICTIONARY ||
	    (d->msgid & 0xff000000u) != XPC_MSGID_PIPE_ROUTINE) {
		return 0;
	}
	return d->msgid & 0x00ffffffu;
}
