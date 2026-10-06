/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * bootstrap-child: an ordinary program on Apple's libxpc that looks up and
 * checks in a service via its (inherited) bootstrap port. Driven by
 * bootstrap-reply, which plays launchd.
 */
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <unistd.h>

int
main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	alarm(10);
	mach_port_t sp = MACH_PORT_NULL;
	kern_return_t kr = bootstrap_look_up(bootstrap_port, "org.finch.test", &sp);
	printf("child: look_up kr=0x%x port=0x%x\n", kr, sp);
	if (kr == 0) {
		mach_msg_header_t h = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0),
		    .msgh_size = sizeof(h), .msgh_remote_port = sp, .msgh_id = 0x1234 };
		printf("child: ping service kr=0x%x\n", mach_msg(&h, MACH_SEND_MSG, sizeof(h), 0, 0, 0, 0));
	}
	mach_port_t cp = MACH_PORT_NULL;
	kr = bootstrap_check_in(bootstrap_port, "org.finch.test", &cp);
	mach_port_type_t t = 0;
	mach_port_type(mach_task_self(), cp, &t);
	printf("child: check_in kr=0x%x has_receive_right=%d\n", kr, (t & MACH_PORT_TYPE_RECEIVE) != 0);
	return 0;
}
