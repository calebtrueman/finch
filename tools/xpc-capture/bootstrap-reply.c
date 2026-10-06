/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * bootstrap-reply: find the reply format Apple's libxpc accepts for
 * bootstrap routines 207 (look_up) and 206 (check_in). This program plays
 * launchd on *Finch's* libxpc (Apple's xpc_pipe_receive rejects routine
 * requests). It answers bootstrap-child, an ordinary program on Apple's
 * libxpc, which reports what it got and proves the right works by using it.
 *
 *   bootstrap-reply <reply-key-for-port> <path to bootstrap-child>
 */

#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>

int xpc_pipe_receive(mach_port_t port, xpc_object_t *message);
int xpc_pipe_routine_reply(xpc_object_t reply);
xpc_object_t xpc_mach_send_create(mach_port_t port);
xpc_object_t xpc_mach_recv_create(mach_port_t port);

int
main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	const char *key = argc > 1 ? argv[1] : "port";
	mach_port_t fake, service;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &fake);
	mach_port_insert_right(mach_task_self(), fake, fake, MACH_MSG_TYPE_MAKE_SEND);
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &service);
	mach_port_insert_right(mach_task_self(), service, service, MACH_MSG_TYPE_MAKE_SEND);
	task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, fake);
	pid_t pid = fork();
	if (pid == 0) {
		execl(argv[2], argv[2], (char *)NULL);   /* bootstrap-child (Apple libxpc) */
		_exit(127);
	}
	for (int i = 0; i < 2; i++) {
		xpc_object_t req = NULL;
		int rc;
		while ((rc = xpc_pipe_receive(fake, &req)) == 35) {
		}
		if (rc != 0) {
			printf("parent: xpc_pipe_receive rc=%d\n", rc);
			break;
		}
		char *d = xpc_copy_description(req);
		printf("parent: request %d: %.200s\n", i, d);
		xpc_object_t reply = xpc_dictionary_create_reply(req);
		xpc_dictionary_set_int64(reply, "error", 0);
		if (i == 0) {
			xpc_object_t s = xpc_mach_send_create(service);
			xpc_dictionary_set_value(reply, key, s);
		} else {
			mach_port_t r;
			mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &r);
			xpc_object_t rr = xpc_mach_recv_create(r);
			xpc_dictionary_set_value(reply, key, rr);
		}
		printf("parent: routine_reply rc=%d\n", xpc_pipe_routine_reply(reply));
	}
	mach_msg_header_t h;
	kern_return_t kr = mach_msg(&h, MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_LARGE, 0, sizeof(h), service, 2000, 0);
	printf("parent: service port got message: kr=0x%x id=0x%x\n", kr, kr == 0 ? h.msgh_id : 0);
	int st;
	waitpid(pid, &st, 0);
	return 0;
}
