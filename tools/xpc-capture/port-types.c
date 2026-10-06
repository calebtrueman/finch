/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * port-types: wire codes and descriptor dispositions Apple's libxpc uses for
 * port-carrying values (mach send right, endpoint, fd) inside a message.
 */
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <stdio.h>
#include <unistd.h>
#include <xpc/xpc.h>

typedef void *xpc_pipe_t;
xpc_pipe_t xpc_pipe_create_from_port(mach_port_t port, uint64_t flags);
int xpc_pipe_simpleroutine(xpc_pipe_t pipe, xpc_object_t message);
xpc_object_t xpc_mach_send_create(mach_port_t port);

static void
send_and_dump(mach_port_t rcv, xpc_pipe_t p, const char *label, xpc_object_t value)
{
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_value(m, "v", value);
	xpc_pipe_simpleroutine(p, m);

	union { mach_msg_header_t h; uint8_t b[8192]; } msg;
	if (mach_msg(&msg.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(msg), rcv, 1000, 0)) {
		printf("%s: no message\n", label);
		return;
	}
	const uint8_t *body = (const uint8_t *)(&msg.h + 1);
	printf("%s:", label);
	if (msg.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
		const mach_msg_body_t *b = (const void *)body;
		const mach_msg_port_descriptor_t *d = (const void *)(b + 1);
		for (unsigned i = 0; i < b->msgh_descriptor_count; i++)
			printf(" desc[%u]{type=%u disp=%u}", i, d[i].type, d[i].disposition);
		body = (const uint8_t *)(d + b->msgh_descriptor_count);
	}
	printf(" payload=");
	for (const uint8_t *q = body; q < (const uint8_t *)&msg.h + msg.h.msgh_size; q++) printf("%02x", *q);
	printf("\n");
}

int
main(void)
{
	mach_port_t rcv, other;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rcv);
	mach_port_insert_right(mach_task_self(), rcv, rcv, MACH_MSG_TYPE_MAKE_SEND);
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &other);
	mach_port_insert_right(mach_task_self(), other, other, MACH_MSG_TYPE_MAKE_SEND);
	xpc_pipe_t p = xpc_pipe_create_from_port(rcv, 0);

	send_and_dump(rcv, p, "mach_send", xpc_mach_send_create(other));
	xpc_connection_t l = xpc_connection_create(NULL, dispatch_get_main_queue());
	xpc_connection_set_event_handler(l, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(l);
	send_and_dump(rcv, p, "endpoint", xpc_endpoint_create(l));
	int fd = open("/dev/null", O_RDONLY);
	send_and_dump(rcv, p, "fd", xpc_fd_create(fd));
	close(fd);
	return 0;
}
