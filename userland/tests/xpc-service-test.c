/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-xpc-service-test: two processes meet through the bootstrap server
 * (finch-init on Finch). The parent spawns itself as an XPC Mach-service
 * listener, waits for the name to appear, then talks to it with a connection
 * and a session. Run inside the VM; exits 0 on success.
 *
 *   finch-xpc-service-test ondemand    a LaunchDaemon started on demand
 *   finch-xpc-service-test useragent   run in a user's domain (su): a LaunchAgent
 *                                      started on demand, as that user
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
#define ONDEMAND "org.finch.test.ondemand"   /* declared by org.finch.test.ondemand.plist */
#define AGENT "org.finch.test.agent"         /* declared by the LaunchAgent org.finch.test.agent.plist */
#define SYSTEM_SERVICE "com.apple.system.notification_center"   /* notifyd, a system daemon */

/* <vproc_priv.h> */
typedef void *vproc_err_t;
vproc_err_t vproc_swap_integer(void *vp, int key, int64_t *inval, int64_t *outval);
#define VPROC_GSK_MGR_UID 3

extern char **environ;

/* Launched by finch-init on demand: check in, answer, exit when asked. */
static int
daemon_main(const char *service)
{
	xpc_connection_t l = xpc_connection_create_mach_service(service, NULL,
	    XPC_CONNECTION_MACH_SERVICE_LISTENER);

	if (l == NULL) {
		fprintf(stderr, "daemon %d: check-in failed\n", getpid());
		return 1;
	}
	xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
		xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
			if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
			xpc_object_t r = xpc_dictionary_create_reply(msg);
			xpc_dictionary_set_int64(r, "server_pid", getpid());
			xpc_dictionary_set_int64(r, "server_uid", getuid());
			xpc_connection_send_message(peer, r);
			xpc_release(r);
			if (xpc_dictionary_get_bool(msg, "exit")) {
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
				    dispatch_get_main_queue(), ^{ exit(0); });
			}
		});
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(l);
	dispatch_main();
}

static int64_t
ask_pid_uid(xpc_connection_t c, bool and_exit, int64_t *uid)
{
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0), r;
	int64_t pid = -1;

	xpc_dictionary_set_bool(m, "exit", and_exit);
	r = xpc_connection_send_message_with_reply_sync(c, m);
	if (xpc_get_type(r) == XPC_TYPE_DICTIONARY) {
		pid = xpc_dictionary_get_int64(r, "server_pid");
		if (uid) *uid = xpc_dictionary_get_int64(r, "server_uid");
	}
	xpc_release(r);
	xpc_release(m);
	return pid;
}

static int64_t
ask_pid(xpc_connection_t c, bool and_exit)
{
	return ask_pid_uid(c, and_exit, NULL);
}

/* In a user's domain (entered through pam_launchd, e.g. with su): the user's
 * agent starts on demand as the user, and system services stay visible. */
static int
useragent_main(void)
{
	mach_port_t sp = MACH_PORT_NULL;
	int64_t mgr_uid = -1, server_uid = -1;
	int failures = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	bool ok = vproc_swap_integer(NULL, VPROC_GSK_MGR_UID, NULL, &mgr_uid) == NULL && mgr_uid == getuid();
	printf("domain manager uid %lld, running as %d: %s\n", mgr_uid, getuid(), ok ? "ok" : "WRONG");
	failures += !ok;

	kern_return_t kr = bootstrap_look_up(bootstrap_port, SYSTEM_SERVICE, &sp);
	printf("system service %s visible: %s\n", SYSTEM_SERVICE, kr == BOOTSTRAP_SUCCESS ? "yes" : "NO");
	failures += kr != BOOTSTRAP_SUCCESS;

	kr = bootstrap_look_up(bootstrap_port, AGENT, &sp);
	printf("agent service %s visible: %s\n", AGENT, kr == BOOTSTRAP_SUCCESS ? "yes" : "NO");
	failures += kr != BOOTSTRAP_SUCCESS;

	xpc_connection_t c = xpc_connection_create_mach_service(AGENT, NULL, 0);
	xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(c);
	int64_t pid = ask_pid_uid(c, true, &server_uid);
	ok = pid > 0 && server_uid == getuid();
	printf("agent launched on demand: pid %lld, uid %lld: %s\n", pid, server_uid, ok ? "ok" : "WRONG");
	failures += !ok;

	printf("%s\n", failures ? "FAILED" : "PASSED: per-user LaunchAgent via finch-init");
	return failures != 0;
}

/* Client side of the on-demand test. */
static int
ondemand_main(void)
{
	mach_port_t sp = MACH_PORT_NULL;
	int failures = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	kern_return_t kr = bootstrap_look_up(bootstrap_port, ONDEMAND, &sp);
	printf("declared service visible before launch: %s\n", kr == BOOTSTRAP_SUCCESS ? "yes" : "NO");
	failures += kr != BOOTSTRAP_SUCCESS;

	xpc_connection_t c = xpc_connection_create_mach_service(ONDEMAND, NULL, 0);
	xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(c);
	int64_t first = ask_pid(c, false);
	int64_t again = ask_pid(c, true);   /* same instance; then it exits */
	printf("launched on demand: pid %lld, answered again by %lld: %s\n", first, again,
	    first > 0 && again == first ? "ok" : "WRONG");
	failures += !(first > 0 && again == first);

	sleep(1);
	int64_t relaunched = -1;
	for (int i = 0; i < 3 && relaunched <= 0; i++) {   /* the first send may see the interruption */
		relaunched = ask_pid(c, false);
	}
	printf("after it exited, same connection relaunched it: pid %lld: %s\n", relaunched,
	    relaunched > 0 && relaunched != first ? "ok" : "WRONG");
	failures += !(relaunched > 0 && relaunched != first);

	printf("%s\n", failures ? "FAILED" : "PASSED: on-demand launch via finch-init");
	return failures != 0;
}

static int
serve(void)
{
	fprintf(stderr, "server %d: starting (bootstrap port 0x%x)\n", getpid(), bootstrap_port);
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
	fprintf(stderr, "server %d: listening\n", getpid());
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
	if (argc > 1 && strcmp(argv[1], "daemon") == 0) {
		return daemon_main(argc > 2 ? argv[2] : ONDEMAND);
	}
	if (argc > 1 && strcmp(argv[1], "ondemand") == 0) {
		return ondemand_main();
	}
	if (argc > 1 && strcmp(argv[1], "useragent") == 0) {
		return useragent_main();
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	printf("bootstrap look_up before the service exists: %s\n",
	    bootstrap_strerror(bootstrap_look_up(bootstrap_port, SERVICE, &sp)));
	if (_NSGetExecutablePath(self, &self_len) != 0 ||
	    posix_spawn(&child, self, NULL, NULL, child_argv, environ) != 0) {
		printf("FAILED: spawn\n");
		return 1;
	}
	int waited_ms = 0;
	for (; waited_ms < 30000 && bootstrap_look_up(bootstrap_port, SERVICE, &sp) != BOOTSTRAP_SUCCESS; waited_ms += 50) {
		usleep(50000);
	}
	printf("service registered by pid %d: %s (after %d ms)\n", child, MACH_PORT_VALID(sp) ? "yes" : "NO", waited_ms);
	if (!MACH_PORT_VALID(sp)) {
		pid_t w = waitpid(child, &status, WNOHANG);
		printf("server pid %d: %s (status 0x%x)\n", child,
		    w == child ? "exited" : w == 0 ? "still running" : "unknown", w == child ? status : 0);
	}
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
