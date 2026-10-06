/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Interoperability: Finch's libxpc against Apple's, over real Mach messages,
 * in one process. Finch's API is linked normally; Apple's is fetched from the
 * system libxpc with dlsym. Objects never cross libraries in memory, only over
 * the wire, as between two processes.
 */

#include <dlfcn.h>
#include <errno.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

typedef void *xpc_pipe_t;
xpc_pipe_t xpc_pipe_create_from_port(mach_port_t port, uint64_t flags);
int xpc_pipe_simpleroutine(xpc_pipe_t pipe, xpc_object_t message);
int xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply);
int xpc_pipe_receive(mach_port_t port, xpc_object_t *message);
int xpc_pipe_routine_reply(xpc_object_t reply);

/* Apple's implementations. */
static struct {
	xpc_object_t (*dictionary_create)(const char *const *, xpc_object_t const *, size_t);
	void (*dictionary_set_string)(xpc_object_t, const char *, const char *);
	const char *(*dictionary_get_string)(xpc_object_t, const char *);
	void (*dictionary_set_fd)(xpc_object_t, const char *, int);
	int (*dictionary_dup_fd)(xpc_object_t, const char *);
	xpc_object_t (*dictionary_create_reply)(xpc_object_t);
	void (*release)(xpc_object_t);
	xpc_pipe_t (*pipe_create_from_port)(mach_port_t, uint64_t);
	int (*pipe_routine)(xpc_pipe_t, xpc_object_t, xpc_object_t *);
	int (*pipe_receive)(mach_port_t, xpc_object_t *);
	int (*pipe_routine_reply)(xpc_object_t);
} apple;

static int failures, checks;
#define CHECK(cond) do { checks++; if (!(cond)) { failures++; \
	printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static mach_port_t
new_port(void)
{
	mach_port_t p;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
	mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
	return p;
}

static void
load_apple(void)
{
	void *h = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY | RTLD_NOLOAD);
#define SYM(field, name) apple.field = dlsym(h, name)
	SYM(dictionary_create, "xpc_dictionary_create");
	SYM(dictionary_set_string, "xpc_dictionary_set_string");
	SYM(dictionary_get_string, "xpc_dictionary_get_string");
	SYM(dictionary_set_fd, "xpc_dictionary_set_fd");
	SYM(dictionary_dup_fd, "xpc_dictionary_dup_fd");
	SYM(dictionary_create_reply, "xpc_dictionary_create_reply");
	SYM(release, "xpc_release");
	SYM(pipe_create_from_port, "xpc_pipe_create_from_port");
	SYM(pipe_routine, "xpc_pipe_routine");
	SYM(pipe_receive, "xpc_pipe_receive");
	SYM(pipe_routine_reply, "xpc_pipe_routine_reply");
#undef SYM
}

/* Apple server: answer one request with "pong:<q>", and write to any fd sent. */
static void *
apple_server(void *arg)
{
	mach_port_t port = (mach_port_t)(uintptr_t)arg;
	xpc_object_t req = NULL;

	/* Apple's xpc_pipe_receive returns EAGAIN when the wait is interrupted
	 * (e.g. by ASan suspending threads); callers retry. */
	int rc;
	while ((rc = apple.pipe_receive(port, &req)) == EAGAIN) {
	}
	if (rc != 0 || req == NULL) {
		printf("apple_server: pipe_receive failed (%d)\n", rc);
		fflush(stdout);
		return NULL;
	}
	char answer[128];
	snprintf(answer, sizeof(answer), "pong:%s", apple.dictionary_get_string(req, "q"));
	int fd = apple.dictionary_dup_fd(req, "fd");
	if (fd >= 0) {
		write(fd, "from-apple", 10);
		close(fd);
	}
	xpc_object_t reply = apple.dictionary_create_reply(req);
	if (getenv("INTEROP_DEBUG")) { printf("apple_server: got request, reply=%p\n", reply); fflush(stdout); }
	apple.dictionary_set_string(reply, "a", answer);
	int rrc = apple.pipe_routine_reply(reply);
	if (getenv("INTEROP_DEBUG")) { printf("apple_server: routine_reply rc=%d\n", rrc); fflush(stdout); }
	apple.release(reply);
	apple.release(req);
	return NULL;
}

/* Finch server: the same, with Finch's implementation. */
static void *
finch_server(void *arg)
{
	mach_port_t port = (mach_port_t)(uintptr_t)arg;
	xpc_object_t req = NULL;

	int rc;
	while ((rc = xpc_pipe_receive(port, &req)) == EAGAIN) {
	}
	if (rc != 0 || req == NULL) {
		printf("finch_server: pipe_receive failed (%d)\n", rc);
		fflush(stdout);
		return NULL;
	}
	char answer[128];
	snprintf(answer, sizeof(answer), "pong:%s", xpc_dictionary_get_string(req, "q"));
	int fd = xpc_dictionary_dup_fd(req, "fd");
	if (fd >= 0) {
		write(fd, "from-finch", 10);
		close(fd);
	}
	xpc_object_t reply = xpc_dictionary_create_reply(req);
	xpc_dictionary_set_string(reply, "a", answer);
	xpc_pipe_routine_reply(reply);
	xpc_release(reply);
	xpc_release(req);
	return NULL;
}

static void
test_finch_client_apple_server(void)
{
	mach_port_t port = new_port();
	pthread_t t;
	int fds[2];
	char buf[32] = { 0 };

	pipe(fds);
	pthread_create(&t, NULL, apple_server, (void *)(uintptr_t)port);

	xpc_pipe_t p = xpc_pipe_create_from_port(port, 0);
	xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0), reply = NULL;
	xpc_dictionary_set_string(req, "q", "finch");
	xpc_dictionary_set_fd(req, "fd", fds[1]);
	close(fds[1]);
	CHECK(xpc_pipe_routine(p, req, &reply) == 0);
	CHECK(reply != NULL && strcmp(xpc_dictionary_get_string(reply, "a"), "pong:finch") == 0);
	pthread_join(t, NULL);
	CHECK(read(fds[0], buf, sizeof(buf) - 1) == 10 && strcmp(buf, "from-apple") == 0);
	close(fds[0]);
	if (reply) xpc_release(reply);
	xpc_release(req);
	xpc_release(p);
}

static void
test_apple_client_finch_server(void)
{
	mach_port_t port = new_port();
	pthread_t t;
	int fds[2];
	char buf[32] = { 0 };

	pipe(fds);
	pthread_create(&t, NULL, finch_server, (void *)(uintptr_t)port);

	xpc_pipe_t p = apple.pipe_create_from_port(port, 0);
	xpc_object_t req = apple.dictionary_create(NULL, NULL, 0), reply = NULL;
	apple.dictionary_set_string(req, "q", "apple");
	apple.dictionary_set_fd(req, "fd", fds[1]);
	close(fds[1]);
	CHECK(apple.pipe_routine(p, req, &reply) == 0);
	CHECK(reply != NULL && strcmp(apple.dictionary_get_string(reply, "a"), "pong:apple") == 0);
	pthread_join(t, NULL);
	CHECK(read(fds[0], buf, sizeof(buf) - 1) == 10 && strcmp(buf, "from-finch") == 0);
	close(fds[0]);
	if (reply) apple.release(reply);
	apple.release(req);
}

/* One-way message, Finch -> Finch, carrying a Mach send right. */
static void
test_simpleroutine_with_port(void)
{
	mach_port_t port = new_port(), carried = new_port();
	xpc_pipe_t p = xpc_pipe_create_from_port(port, 0);
	xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0), got = NULL;

	xpc_dictionary_set_mach_send(m, "right", carried);
	CHECK(xpc_pipe_simpleroutine(p, m) == 0);
	CHECK(xpc_pipe_receive(port, &got) == 0 && got != NULL);
	mach_port_t r = got ? xpc_dictionary_copy_mach_send(got, "right") : MACH_PORT_NULL;
	CHECK(r == carried);   /* same task: the name is the same right */
	if (got) xpc_release(got);
	xpc_release(m);
	xpc_release(p);
}

int
main(void)
{
	load_apple();
	if (apple.pipe_routine == NULL) {
		printf("cannot load Apple's libxpc\n");
		return 2;
	}
	test_finch_client_apple_server();
	test_apple_client_finch_server();
	test_simpleroutine_with_port();
	printf("%s: %d/%d interop checks passed\n", failures ? "FAILED" : "PASSED",
	    checks - failures, checks);
	return failures != 0;
}
