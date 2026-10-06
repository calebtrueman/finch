/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-xpc-service-test: two processes meet through the bootstrap server
 * (finch-init on Finch). The parent spawns itself as an XPC Mach-service
 * listener, waits for the name to appear, then talks to it with a connection
 * and a session. Run inside the VM; exits 0 on success.
 */

#include <dispatch/dispatch.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define SERVICE "org.finch.test.xpc-service"

extern char **environ;

static int
serve(void)
{
	xpc_connection_t l = xpc_connection_create_mach_service(SERVICE, NULL,
	    XPC_CONNECTION_MACH_SERVICE_LISTENER);

	xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
		xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
			if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
			xpc_object_t r = xpc_dictionary_create_reply(msg);
			xpc_dictionary_set_int64(r, "answer", xpc_dictionary_get_int64(msg, "x") * 2);
			xpc_dictionary_set_int64(r, "server_pid", getpid());
			xpc_connection_send_message(peer, r);
			xpc_release(r);
		});
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(l);
	dispatch_main();
}

int
main(int argc, char **argv)
{
	char self[PATH_MAX];
	uint32_t self_len = sizeof(self);
	char *child_argv[] = { argv[0], "serve", NULL };
	mach_port_t sp = MACH_PORT_NULL;
	int failures = 0, status;
	pid_t child;

	if (argc > 1 && strcmp(argv[1], "serve") == 0) {
		return serve();
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	printf("bootstrap look_up before the service exists: %s\n",
	    bootstrap_strerror(bootstrap_look_up(bootstrap_port, SERVICE, &sp)));
	if (_NSGetExecutablePath(self, &self_len) != 0 ||
	    posix_spawn(&child, self, NULL, NULL, child_argv, environ) != 0) {
		printf("FAILED: spawn\n");
		return 1;
	}
	for (int i = 0; i < 100 && bootstrap_look_up(bootstrap_port, SERVICE, &sp) != BOOTSTRAP_SUCCESS; i++) {
		usleep(50000);
	}
	printf("service registered by pid %d: %s\n", child, MACH_PORT_VALID(sp) ? "yes" : "NO");
	failures += !MACH_PORT_VALID(sp);

	xpc_connection_t c = xpc_connection_create_mach_service(SERVICE, NULL, 0);
	xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(c);
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_int64(m, "x", 21);
	xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
	bool ok = xpc_get_type(r) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_int64(r, "answer") == 42 &&
	    xpc_dictionary_get_int64(r, "server_pid") == child;
	printf("connection: 21 * 2 = %lld from pid %lld: %s\n", xpc_dictionary_get_int64(r, "answer"),
	    xpc_dictionary_get_int64(r, "server_pid"), ok ? "ok" : "WRONG");
	failures += !ok;

	xpc_rich_error_t err = NULL;
	xpc_session_t s = xpc_session_create_mach_service(SERVICE, NULL, 0, &err);
	xpc_dictionary_set_int64(m, "x", 50);
	xpc_object_t r2 = s ? xpc_session_send_message_with_reply_sync(s, m, &err) : NULL;
	ok = r2 != NULL && xpc_dictionary_get_int64(r2, "answer") == 100;
	printf("session: 50 * 2 = %lld: %s\n", r2 ? xpc_dictionary_get_int64(r2, "answer") : -1, ok ? "ok" : "WRONG");
	failures += !ok;

	/* The service dies with its owner, and the name is released. */
	kill(child, SIGTERM);
	waitpid(child, &status, 0);
	mach_port_t gone = MACH_PORT_NULL;
	kern_return_t kr = bootstrap_look_up(bootstrap_port, SERVICE, &gone);
	printf("after the server exits, look_up: %s\n", bootstrap_strerror(kr));
	failures += kr != BOOTSTRAP_UNKNOWN_SERVICE;

	printf("%s\n", failures ? "FAILED" : "PASSED: XPC service over the Finch bootstrap server");
	return failures != 0;
}
