/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-init's bootstrap server (userland/finch-init/bootstrapd.c) against
 * Finch libxpc's bootstrap client, in one process: registry rules, rights,
 * owner death, and XPC Mach-service connections and sessions resolved through
 * the server.
 */

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "../../finch-init/bootstrapd.h"

typedef struct xpc_pipe_s *xpc_pipe_t;
xpc_pipe_t xpc_pipe_create_from_port(mach_port_t port, uint64_t flags);
int xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply);
kern_return_t bootstrap_look_up2(mach_port_t bp, const name_t name, mach_port_t *sp, pid_t pid, uint64_t flags);

static int failures, checks;
#define CHECK(cond) do { checks++; if (!(cond)) { failures++; \
	printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); fflush(stdout); } } while (0)

static bool
has_right(mach_port_t name, mach_port_type_t right)
{
	mach_port_type_t t = 0;
	return mach_port_type(mach_task_self(), name, &t) == KERN_SUCCESS && (t & right);
}

static void
test_registry(mach_port_t bp)
{
	mach_port_t recv = MACH_PORT_NULL, send = MACH_PORT_NULL, again = MACH_PORT_NULL;
	char long_name[200];

	CHECK(bootstrap_look_up(bp, "org.finch.test.a", &send) == BOOTSTRAP_UNKNOWN_SERVICE);
	CHECK(send == MACH_PORT_NULL);

	CHECK(bootstrap_check_in(bp, "org.finch.test.a", &recv) == BOOTSTRAP_SUCCESS);
	CHECK(has_right(recv, MACH_PORT_TYPE_RECEIVE));
	CHECK(bootstrap_check_in(bp, "org.finch.test.a", &again) == BOOTSTRAP_SERVICE_ACTIVE);

	/* A looked-up send right reaches the checked-in receive right. */
	CHECK(bootstrap_look_up(bp, "org.finch.test.a", &send) == BOOTSTRAP_SUCCESS);
	CHECK(has_right(send, MACH_PORT_TYPE_SEND));
	mach_msg_header_t h = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0),
	    .msgh_size = sizeof(h), .msgh_remote_port = send, .msgh_id = 0x1234 };
	CHECK(mach_msg(&h, MACH_SEND_MSG, sizeof(h), 0, 0, 0, 0) == KERN_SUCCESS);
	struct { mach_msg_header_t h; mach_msg_trailer_t t; } in;
	CHECK(mach_msg(&in.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(in), recv, 2000, 0) == KERN_SUCCESS);
	CHECK(in.h.msgh_id == 0x1234);
	mach_port_deallocate(mach_task_self(), send);

	/* Owner death: the name becomes free again. */
	mach_port_mod_refs(mach_task_self(), recv, MACH_PORT_RIGHT_RECEIVE, -1);
	CHECK(bootstrap_look_up(bp, "org.finch.test.a", &send) == BOOTSTRAP_UNKNOWN_SERVICE);
	CHECK(bootstrap_check_in(bp, "org.finch.test.a", &recv) == BOOTSTRAP_SUCCESS);
	mach_port_mod_refs(mach_task_self(), recv, MACH_PORT_RIGHT_RECEIVE, -1);

	/* look_up2 is the same routine. */
	CHECK(bootstrap_check_in(bp, "org.finch.test.b", &recv) == BOOTSTRAP_SUCCESS);
	CHECK(bootstrap_look_up2(bp, "org.finch.test.b", &send, 0, 0) == BOOTSTRAP_SUCCESS);
	mach_port_deallocate(mach_task_self(), send);
	mach_port_mod_refs(mach_task_self(), recv, MACH_PORT_RIGHT_RECEIVE, -1);

	/* Names must fit name_t. */
	memset(long_name, 'x', sizeof(long_name) - 1);
	long_name[sizeof(long_name) - 1] = '\0';
	CHECK(bootstrap_look_up(bp, long_name, &send) == BOOTSTRAP_BAD_COUNT);

	/* No server behind the port: an error, not a hang. */
	mach_port_t dead;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &dead);
	mach_port_insert_right(mach_task_self(), dead, dead, MACH_MSG_TYPE_MAKE_SEND);
	mach_port_mod_refs(mach_task_self(), dead, MACH_PORT_RIGHT_RECEIVE, -1);
	CHECK(bootstrap_look_up(dead, "org.finch.test.a", &send) != BOOTSTRAP_SUCCESS);
	mach_port_deallocate(mach_task_self(), dead);
}

/* Unknown routines are refused, and replies identify the requester. */
static void
test_reply_fields(mach_port_t bp)
{
	xpc_pipe_t pipe = xpc_pipe_create_from_port(bp, 0);
	xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0), reply = NULL;

	xpc_dictionary_set_string(req, "name", "org.finch.test.a");
	CHECK(xpc_pipe_routine(pipe, req, &reply) == 0);
	CHECK(reply != NULL && xpc_dictionary_get_int64(reply, "error") == BOOTSTRAP_NOT_PRIVILEGED);
	CHECK(reply != NULL && xpc_dictionary_get_int64(reply, "req_pid") == getpid());
	if (reply) xpc_release(reply);
	xpc_release(req);
	xpc_release((xpc_object_t)pipe);
}

/* XPC services resolved through the server: a listener checks in, clients look up. */
static void
test_xpc_services(void)
{
	dispatch_queue_t q = dispatch_queue_create("listener", NULL);
	xpc_connection_t listener = xpc_connection_create_mach_service("org.finch.test.svc", q,
	    XPC_CONNECTION_MACH_SERVICE_LISTENER);

	xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
		xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
			if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
			xpc_object_t r = xpc_dictionary_create_reply(msg);
			xpc_dictionary_set_int64(r, "answer", xpc_dictionary_get_int64(msg, "x") * 2);
			xpc_connection_send_message(peer, r);
			xpc_release(r);
		});
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(listener);

	xpc_connection_t client = xpc_connection_create_mach_service("org.finch.test.svc", NULL, 0);
	xpc_connection_set_event_handler(client, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(client);
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_int64(m, "x", 21);
	xpc_object_t r = xpc_connection_send_message_with_reply_sync(client, m);
	CHECK(xpc_get_type(r) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_int64(r, "answer") == 42);
	xpc_release(r);

	/* The session API over the same service. */
	xpc_rich_error_t err = NULL;
	xpc_session_t s = xpc_session_create_mach_service("org.finch.test.svc", NULL, 0, &err);
	CHECK(s != NULL && err == NULL);
	if (s) {
		xpc_dictionary_set_int64(m, "x", 50);
		r = xpc_session_send_message_with_reply_sync(s, m, &err);
		CHECK(r != NULL && xpc_dictionary_get_int64(r, "answer") == 100);
		if (r) xpc_release(r);
		xpc_session_cancel(s);
	}

	/* A second listener for a live name is refused (the check-in fails). */
	mach_port_t recv = MACH_PORT_NULL;
	CHECK(bootstrap_check_in(bootstrap_port, "org.finch.test.svc", &recv) == BOOTSTRAP_SERVICE_ACTIVE);

	xpc_release(m);
	xpc_connection_cancel(client);
	xpc_connection_cancel(listener);
}

int
main(void)
{
	mach_port_t bp = bootstrapd_start();

	setvbuf(stdout, NULL, _IONBF, 0);
	CHECK(bp != MACH_PORT_NULL);
	test_registry(bp);
	test_reply_fields(bp);

	bootstrap_port = bp;   /* XPC Mach-service connections use the global */
	test_xpc_services();

	printf("%s: %d/%d bootstrap checks passed\n", failures ? "FAILED" : "PASSED",
	    checks - failures, checks);
	return failures != 0;
}
