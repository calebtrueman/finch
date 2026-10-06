/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * mach-capture: record the raw Mach messages Apple's libxpc sends, as ground
 * truth for Finch's XPC transport (docs/design/XPC.md, X3). Apple's libxpc
 * sends to a receive right this program owns (via xpc_pipe_create_from_port
 * and xpc_endpoint_create_mach_port_4sim + xpc_connection_create_from_endpoint),
 * and each message is dumped: header, descriptors, payload hex.
 */

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

/* Private libxpc API exported by Apple's libxpc. */
typedef void *xpc_pipe_t;
xpc_pipe_t xpc_pipe_create_from_port(mach_port_t port, uint64_t flags);
int xpc_pipe_simpleroutine(xpc_pipe_t pipe, xpc_object_t message);
int xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply);
xpc_object_t xpc_endpoint_create_mach_port_4sim(mach_port_t port);

static mach_port_t rcv;
static mach_port_t w00t_recv = MACH_PORT_NULL;   /* receive right from the handshake */
static mach_port_t w00t_send = MACH_PORT_NULL;   /* send right back to the client */

static const char *
disposition_name(unsigned d)
{
	switch (d) {
	case MACH_MSG_TYPE_MOVE_RECEIVE: return "move-receive";
	case MACH_MSG_TYPE_MOVE_SEND: return "move-send";
	case MACH_MSG_TYPE_MOVE_SEND_ONCE: return "move-send-once";
	case MACH_MSG_TYPE_COPY_SEND: return "copy-send";
	case MACH_MSG_TYPE_MAKE_SEND: return "make-send";
	case MACH_MSG_TYPE_MAKE_SEND_ONCE: return "make-send-once";
	case 0: return "none";
	default: return "?";
	}
}

/* Receive one message (or time out) and dump it. */
static bool
dump_on(mach_port_t port, const char *label, int timeout_ms)
{
	union {
		mach_msg_header_t hdr;
		uint8_t buf[65536];
	} msg;
	kern_return_t kr = mach_msg(&msg.hdr, MACH_RCV_MSG | MACH_RCV_TIMEOUT |
	    MACH_RCV_LARGE, 0, sizeof(msg), port, (mach_msg_timeout_t)timeout_ms, MACH_PORT_NULL);

	if (kr != KERN_SUCCESS) {
		printf("[%s] no message (0x%x)\n", label, kr);
		return false;
	}
	mach_msg_header_t *h = &msg.hdr;
	printf("[%s] size=%u id=0x%x bits=0x%08x remote=%s local=%s voucher=%s complex=%d\n",
	    label, h->msgh_size, h->msgh_id, h->msgh_bits,
	    disposition_name(MACH_MSGH_BITS_REMOTE(h->msgh_bits)),
	    disposition_name(MACH_MSGH_BITS_LOCAL(h->msgh_bits)),
	    disposition_name(MACH_MSGH_BITS_VOUCHER(h->msgh_bits)),
	    (h->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0);

	const uint8_t *body = (const uint8_t *)(h + 1);
	if (h->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
		const mach_msg_body_t *b = (const mach_msg_body_t *)body;
		const mach_msg_descriptor_t *d = (const mach_msg_descriptor_t *)(b + 1);
		printf("  descriptors=%u\n", b->msgh_descriptor_count);
		for (unsigned i = 0; i < b->msgh_descriptor_count; i++) {
			unsigned type = d->type.type;
			if (type == MACH_MSG_PORT_DESCRIPTOR) {
				printf("  [%u] port disposition=%s\n", i,
				    disposition_name(d->port.disposition));
				if (h->msgh_id == 0x77303074 && i == 0) w00t_recv = d->port.name;
				if (h->msgh_id == 0x77303074 && i == 1) w00t_send = d->port.name;
				d = (const mach_msg_descriptor_t *)((const uint8_t *)d + sizeof(d->port));
			} else if (type == MACH_MSG_OOL_DESCRIPTOR || type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
				printf("  [%u] ool size=%u\n", i, d->out_of_line.size);
				d = (const mach_msg_descriptor_t *)((const uint8_t *)d + sizeof(d->out_of_line));
			} else {
				printf("  [%u] descriptor type %u\n", i, type);
				break;
			}
		}
		body = (const uint8_t *)d;
	}
	size_t n = (size_t)((const uint8_t *)h + h->msgh_size - body);
	printf("  payload(%zu)=", n);
	for (size_t i = 0; i < n; i++) {
		printf("%02x", body[i]);
	}
	printf("\n");
	fflush(stdout);
	/* Release any rights we received, except the handshake's (kept to listen). */
	if (h->msgh_id != 0x77303074) {
		mach_msg_destroy(h);
	}
	return true;
}

static bool
dump(const char *label, int timeout_ms)
{
	return dump_on(rcv, label, timeout_ms);
}

int
main(void)
{
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rcv);
	mach_port_insert_right(mach_task_self(), rcv, rcv, MACH_MSG_TYPE_MAKE_SEND);

	/* 1. Pipe: one-way message. */
	xpc_pipe_t pipe = xpc_pipe_create_from_port(rcv, 0);
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(m, "hi", "finch");
	xpc_pipe_simpleroutine(pipe, m);
	dump("pipe-simpleroutine", 1000);

	/* 2. Pipe: message carrying an fd (a fileport descriptor). */
	int fd = open("/dev/null", O_RDONLY);
	xpc_dictionary_set_fd(m, "fd", fd);
	close(fd);
	xpc_pipe_simpleroutine(pipe, m);
	dump("pipe-simpleroutine-fd", 1000);

	/* 3. Pipe: request expecting a reply (we never answer; the client times out). */
	dispatch_async(dispatch_get_global_queue(0, 0), ^{
		xpc_object_t r = xpc_dictionary_create(NULL, NULL, 0);
		xpc_object_t reply = NULL;
		xpc_dictionary_set_int64(r, "op", 1);
		xpc_pipe_routine(pipe, r, &reply);
	});
	dump("pipe-routine", 2000);

	/* 4. Connection to an endpoint wrapping our port. */
	xpc_object_t ep = xpc_endpoint_create_mach_port_4sim(rcv);
	xpc_connection_t c = xpc_connection_create_from_endpoint((xpc_endpoint_t)ep);
	xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(c);
	xpc_object_t cm = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(cm, "hello", "world");
	xpc_connection_send_message(c, cm);
	dump("connection-handshake", 1000);
	if (w00t_recv != MACH_PORT_NULL) {
		/* The client sends its messages to the receive right it handed us. */
		while (dump_on(w00t_recv, "connection-message", 1000)) {
		}
		/* 5. Connection: message expecting a reply. */
		xpc_connection_send_message_with_reply(c, cm, dispatch_get_global_queue(0, 0),
		    ^(xpc_object_t r) { (void)r; });
		while (dump_on(w00t_recv, "connection-with-reply", 1000)) {
		}
		/* 6. Synchronous request with a barrier, then cancel. */
		xpc_connection_cancel(c);
		while (dump_on(w00t_recv, "connection-after-cancel", 1000)) {
		}
	}
	return 0;
}
