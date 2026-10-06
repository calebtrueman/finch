/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * server-capture: the reverse of mach-capture. Apple's libxpc runs an
 * anonymous listener; this program talks to it as a raw-Mach client (w00t
 * handshake, then messages) and records what the Apple server sends back:
 * replies, and unsolicited messages to the client.
 */

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <xpc/xpc.h>

mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_object_t endpoint);
void *xpc_make_serialization(xpc_object_t obj, size_t *len);

#define XPC_MSGID_HANDSHAKE 0x77303074   /* 'w00t' */
#define XPC_MSGID_MESSAGE   0x10000000

static void
dump(mach_port_t port, const char *label)
{
	union { mach_msg_header_t h; uint8_t b[65536]; } m;
	kern_return_t kr = mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_LARGE,
	    0, sizeof(m), port, 2000, MACH_PORT_NULL);

	if (kr != KERN_SUCCESS) {
		printf("[%s] no message (0x%x)\n", label, kr);
		return;
	}
	printf("[%s] size=%u id=0x%x bits=0x%08x reply-disp=%u complex=%d\n", label,
	    m.h.msgh_size, m.h.msgh_id, m.h.msgh_bits, MACH_MSGH_BITS_REMOTE(m.h.msgh_bits),
	    (m.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0);
	const uint8_t *body = (const uint8_t *)(&m.h + 1);
	if (m.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
		const mach_msg_body_t *b = (const mach_msg_body_t *)body;
		printf("  descriptors=%u\n", b->msgh_descriptor_count);
		body = (const uint8_t *)(b + 1) + b->msgh_descriptor_count * sizeof(mach_msg_port_descriptor_t);
	}
	size_t n = (size_t)((const uint8_t *)&m.h + m.h.msgh_size - body);
	printf("  payload(%zu)=", n);
	for (size_t i = 0; i < n; i++) printf("%02x", body[i]);
	printf("\n");
	mach_msg_destroy(&m.h);
}

/* Send a CPX@ message (Mach payload magic) built from `dict`. */
static void
send_message(mach_port_t dest, xpc_object_t dict, mach_port_t reply_once)
{
	size_t len = 0;
	uint8_t *ser = xpc_make_serialization(dict, &len);
	struct { mach_msg_header_t h; uint8_t b[4096]; } m = { 0 };

	memcpy(m.b, ser, len);
	memcpy(m.b, "CPX@", 4);                       /* serialization magic -> message magic */
	m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
	    reply_once ? MACH_MSG_TYPE_MAKE_SEND_ONCE : 0);
	m.h.msgh_size = (mach_msg_size_t)(sizeof(m.h) + len);
	m.h.msgh_remote_port = dest;
	m.h.msgh_local_port = reply_once;
	m.h.msgh_id = XPC_MSGID_MESSAGE;
	kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG, m.h.msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
	printf("(sent message, kr=0x%x)\n", kr);
}

int
main(void)
{
	dispatch_queue_t q = dispatch_queue_create("server", NULL);
	xpc_connection_t listener = xpc_connection_create(NULL, q);

	xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
		xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
			if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
			if (xpc_dictionary_get_bool(msg, "want_reply")) {
				xpc_object_t r = xpc_dictionary_create_reply(msg);
				xpc_dictionary_set_string(r, "answer", "yes");
				xpc_connection_send_message(peer, r);
			} else {
				xpc_object_t push = xpc_dictionary_create(NULL, NULL, 0);
				xpc_dictionary_set_string(push, "push", "x");
				xpc_connection_send_message(peer, push);
			}
		});
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(listener);
	mach_port_t lport = xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_create(listener));

	/* Raw client: A = server's receive end (we keep a send right), B = ours. */
	mach_port_t A, B, C;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &A);
	mach_port_insert_right(mach_task_self(), A, A, MACH_MSG_TYPE_MAKE_SEND);
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &B);

	struct {
		mach_msg_header_t h;
		mach_msg_body_t body;
		mach_msg_port_descriptor_t d[2];
	} hs = { 0 };
	hs.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
	hs.h.msgh_size = sizeof(hs);
	hs.h.msgh_remote_port = lport;
	hs.h.msgh_id = XPC_MSGID_HANDSHAKE;
	hs.body.msgh_descriptor_count = 2;
	hs.d[0] = (mach_msg_port_descriptor_t){ .name = A, .disposition = MACH_MSG_TYPE_MOVE_RECEIVE, .type = MACH_MSG_PORT_DESCRIPTOR };
	hs.d[1] = (mach_msg_port_descriptor_t){ .name = B, .disposition = MACH_MSG_TYPE_MAKE_SEND, .type = MACH_MSG_PORT_DESCRIPTOR };
	printf("(handshake kr=0x%x)\n", mach_msg(&hs.h, MACH_SEND_MSG, sizeof(hs), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL));

	/* A request with a reply port. */
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &C);
	xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_bool(req, "want_reply", true);
	send_message(A, req, C);
	dump(C, "server-reply");

	/* A one-way message that makes the server push to us. */
	xpc_object_t one = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(one, "hello", "server");
	send_message(A, one, MACH_PORT_NULL);
	dump(B, "server-push");
	return 0;
}
