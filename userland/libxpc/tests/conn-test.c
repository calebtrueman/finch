/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Connection tests (step X3b): Finch<->Finch, Apple client -> Finch listener,
 * Finch client -> Apple listener. Apple's API comes from the system libxpc
 * via dlsym; objects only cross between the two over Mach messages.
 */

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_object_t endpoint);
xpc_object_t xpc_endpoint_create_mach_port_4sim(mach_port_t port);

static int failures, checks;
#define CHECK(cond) do { checks++; if (!(cond)) { failures++; \
	printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); fflush(stdout); } } while (0)

#define WAIT(sem) (dispatch_semaphore_wait((sem), dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0)

/* Apple's implementations. */
static struct {
	xpc_connection_t (*connection_create)(const char *, dispatch_queue_t);
	xpc_connection_t (*connection_create_from_endpoint)(xpc_endpoint_t);
	void (*connection_set_event_handler)(xpc_connection_t, xpc_handler_t);
	void (*connection_resume)(xpc_connection_t);
	void (*connection_cancel)(xpc_connection_t);
	xpc_object_t (*connection_send_message_with_reply_sync)(xpc_connection_t, xpc_object_t);
	void (*connection_send_message)(xpc_connection_t, xpc_object_t);
	xpc_endpoint_t (*endpoint_create)(xpc_connection_t);
	mach_port_t (*endpoint_copy_listener_port_4sim)(xpc_object_t);
	xpc_object_t (*endpoint_create_mach_port_4sim)(mach_port_t);
	xpc_object_t (*dictionary_create)(const char *const *, xpc_object_t const *, size_t);
	xpc_object_t (*dictionary_create_reply)(xpc_object_t);
	void (*dictionary_set_string)(xpc_object_t, const char *, const char *);
	const char *(*dictionary_get_string)(xpc_object_t, const char *);
	xpc_type_t (*get_type)(xpc_object_t);
	xpc_type_t type_dictionary, type_connection;
	void (*release)(xpc_object_t);
} apple;

static void
load_apple(void)
{
	void *h = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY | RTLD_NOLOAD);
#define SYM(field, name) apple.field = dlsym(h, name)
	SYM(connection_create, "xpc_connection_create");
	SYM(connection_create_from_endpoint, "xpc_connection_create_from_endpoint");
	SYM(connection_set_event_handler, "xpc_connection_set_event_handler");
	SYM(connection_resume, "xpc_connection_resume");
	SYM(connection_cancel, "xpc_connection_cancel");
	SYM(connection_send_message_with_reply_sync, "xpc_connection_send_message_with_reply_sync");
	SYM(connection_send_message, "xpc_connection_send_message");
	SYM(endpoint_create, "xpc_endpoint_create");
	SYM(endpoint_copy_listener_port_4sim, "xpc_endpoint_copy_listener_port_4sim");
	SYM(endpoint_create_mach_port_4sim, "xpc_endpoint_create_mach_port_4sim");
	SYM(dictionary_create, "xpc_dictionary_create");
	SYM(dictionary_create_reply, "xpc_dictionary_create_reply");
	SYM(dictionary_set_string, "xpc_dictionary_set_string");
	SYM(dictionary_get_string, "xpc_dictionary_get_string");
	SYM(get_type, "xpc_get_type");
	SYM(release, "xpc_release");
	apple.type_dictionary = dlsym(h, "_xpc_type_dictionary");
	apple.type_connection = dlsym(h, "_xpc_type_connection");
#undef SYM
}

/* A Finch echo server: replies "echo:<q>", pushes on "push", writes to fds. */
static xpc_connection_t
finch_echo_listener(dispatch_semaphore_t peer_gone)
{
	xpc_connection_t listener = xpc_connection_create(NULL, NULL);

	xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
		xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
			if (xpc_get_type(msg) == XPC_TYPE_ERROR) {
				if (msg == XPC_ERROR_CONNECTION_INVALID && peer_gone) {
					dispatch_semaphore_signal(peer_gone);
				}
				return;
			}
			const char *q = xpc_dictionary_get_string(msg, "q");
			int fd = xpc_dictionary_dup_fd(msg, "fd");
			if (fd >= 0) {
				write(fd, "via-conn", 8);
				close(fd);
			}
			if (q && strcmp(q, "push") == 0) {
				xpc_object_t p = xpc_dictionary_create(NULL, NULL, 0);
				xpc_dictionary_set_string(p, "pushed", "yes");
				xpc_connection_send_message(peer, p);
				xpc_release(p);
			}
			xpc_object_t r = xpc_dictionary_create_reply(msg);
			if (r) {
				char buf[128];
				snprintf(buf, sizeof(buf), "echo:%s", q ? q : "");
				xpc_dictionary_set_string(r, "a", buf);
				xpc_connection_send_message(peer, r);
				xpc_release(r);
			}
		});
		xpc_connection_resume(peer);
	});
	xpc_connection_resume(listener);
	return listener;
}

static void
test_finch_finch(void)
{
	dispatch_semaphore_t gone = dispatch_semaphore_create(0), pushed = dispatch_semaphore_create(0),
	    async_reply = dispatch_semaphore_create(0), client_invalid = dispatch_semaphore_create(0);
	xpc_connection_t listener = finch_echo_listener(gone);
	xpc_endpoint_t ep = xpc_endpoint_create(listener);
	xpc_connection_t client = xpc_connection_create_from_endpoint(ep);
	__block bool got_push = false;

	xpc_connection_set_event_handler(client, ^(xpc_object_t e) {
		if (xpc_get_type(e) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_string(e, "pushed")) {
			got_push = true;
			dispatch_semaphore_signal(pushed);
		} else if (e == XPC_ERROR_CONNECTION_INVALID) {
			dispatch_semaphore_signal(client_invalid);
		}
	});
	xpc_connection_resume(client);

	/* Sync reply. */
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(m, "q", "sync");
	xpc_object_t r = xpc_connection_send_message_with_reply_sync(client, m);
	CHECK(xpc_get_type(r) == XPC_TYPE_DICTIONARY && strcmp(xpc_dictionary_get_string(r, "a"), "echo:sync") == 0);
	xpc_release(r);

	/* Async reply on a given queue. */
	__block bool async_ok = false;
	xpc_dictionary_set_string(m, "q", "async");
	xpc_connection_send_message_with_reply(client, m, dispatch_get_global_queue(0, 0), ^(xpc_object_t rep) {
		async_ok = xpc_get_type(rep) == XPC_TYPE_DICTIONARY &&
		    strcmp(xpc_dictionary_get_string(rep, "a"), "echo:async") == 0;
		dispatch_semaphore_signal(async_reply);
	});
	CHECK(WAIT(async_reply) && async_ok);

	/* Server -> client push, plus an fd carried over the connection. */
	int fds[2];
	char buf[16] = { 0 };
	pipe(fds);
	xpc_dictionary_set_string(m, "q", "push");
	xpc_dictionary_set_fd(m, "fd", fds[1]);
	close(fds[1]);
	xpc_connection_send_message(client, m);
	CHECK(WAIT(pushed) && got_push);
	CHECK(read(fds[0], buf, sizeof(buf) - 1) == 8 && strcmp(buf, "via-conn") == 0);
	close(fds[0]);

	/* Many concurrent requests. */
	__block int ok = 0;
	dispatch_group_t g = dispatch_group_create();
	for (int i = 0; i < 200; i++) {
		dispatch_group_enter(g);
		xpc_object_t q = xpc_dictionary_create(NULL, NULL, 0);
		xpc_dictionary_set_string(q, "q", "many");
		xpc_connection_send_message_with_reply(client, q, dispatch_get_global_queue(0, 0), ^(xpc_object_t rep) {
			if (xpc_get_type(rep) == XPC_TYPE_DICTIONARY) __atomic_fetch_add(&ok, 1, __ATOMIC_RELAXED);
			dispatch_group_leave(g);
		});
		xpc_release(q);
	}
	CHECK(dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 && ok == 200);

	/* Client cancel: the client sees INVALID; the peer learns via no-senders. */
	xpc_connection_cancel(client);
	CHECK(WAIT(client_invalid));
	CHECK(WAIT(gone));

	xpc_release(m);
	xpc_release(client);
	xpc_connection_cancel(listener);
	xpc_release(ep);
	xpc_release(listener);
}

static void
test_apple_client_finch_listener(void)
{
	xpc_connection_t listener = finch_echo_listener(NULL);
	xpc_endpoint_t ep = xpc_endpoint_create(listener);
	mach_port_t port = xpc_endpoint_copy_listener_port_4sim(ep);

	xpc_object_t aep = apple.endpoint_create_mach_port_4sim(port);
	xpc_connection_t ac = apple.connection_create_from_endpoint(aep);
	apple.connection_set_event_handler(ac, ^(xpc_object_t e) { (void)e; });
	apple.connection_resume(ac);
	xpc_object_t m = apple.dictionary_create(NULL, NULL, 0);
	apple.dictionary_set_string(m, "q", "from-apple");
	xpc_object_t r = apple.connection_send_message_with_reply_sync(ac, m);
	CHECK(apple.get_type(r) == apple.type_dictionary &&
	    strcmp(apple.dictionary_get_string(r, "a"), "echo:from-apple") == 0);
	apple.release(r);
	apple.release(m);
	apple.connection_cancel(ac);
	xpc_connection_cancel(listener);
}

static void
test_finch_client_apple_listener(void)
{
	xpc_connection_t al = apple.connection_create(NULL, NULL);
	apple.connection_set_event_handler(al, ^(xpc_object_t peer) {
		if (apple.get_type(peer) != apple.type_connection) return;
		apple.connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t msg) {
			if (apple.get_type(msg) != apple.type_dictionary) return;
			xpc_object_t r = apple.dictionary_create_reply(msg);
			if (r) {
				char buf[128];
				snprintf(buf, sizeof(buf), "apple-echo:%s", apple.dictionary_get_string(msg, "q"));
				apple.dictionary_set_string(r, "a", buf);
				apple.connection_send_message((xpc_connection_t)peer, r);
				apple.release(r);
			}
		});
		apple.connection_resume((xpc_connection_t)peer);
	});
	apple.connection_resume(al);
	mach_port_t port = apple.endpoint_copy_listener_port_4sim(apple.endpoint_create(al));

	xpc_object_t ep = xpc_endpoint_create_mach_port_4sim(port);
	xpc_connection_t c = xpc_connection_create_from_endpoint((xpc_endpoint_t)ep);
	xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
	xpc_connection_resume(c);
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(m, "q", "from-finch");
	xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
	CHECK(xpc_get_type(r) == XPC_TYPE_DICTIONARY &&
	    strcmp(xpc_dictionary_get_string(r, "a") ?: "", "apple-echo:from-finch") == 0);
	xpc_release(r);
	xpc_release(m);
	xpc_connection_cancel(c);
	apple.connection_cancel(al);
}

int
main(void)
{
	load_apple();
	test_finch_finch();
	test_apple_client_finch_listener();
	test_finch_client_apple_listener();
	printf("%s: %d/%d connection checks passed\n", failures ? "FAILED" : "PASSED",
	    checks - failures, checks);
	return failures != 0;
}
