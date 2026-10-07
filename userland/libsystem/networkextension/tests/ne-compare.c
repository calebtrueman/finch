/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * ne-compare: calls Apple's libsystem_networkextension and Finch's the same
 * way and compares the results: data symbols, name tables, the functions
 * macOS implements as constants, logging switches, the configuration
 * generation, and sessions for configurations that don't exist (status,
 * info, and the event a cancel delivers). Sessions are never started.
 * Whether configurations are present depends on the host, so those answers
 * aren't compared.
 *
 *   ne-compare <path to Finch's libsystem_networkextension.dylib>
 */

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uuid/uuid.h>
#include <xpc/xpc.h>

typedef void *ne_session_t;

struct api {
	void *h;
	const char *(*status_name)(int);
	const char *(*type_name)(int);
	const char *(*info_name)(int);
	const char *(*stop_name)(int);
	ne_session_t (*create)(const uuid_t, int);
	void (*retain)(ne_session_t);
	void (*release)(ne_session_t);
	void (*cancel)(ne_session_t);
	void (*set_event_handler)(ne_session_t, dispatch_queue_t, void (^)(int, void *));
	void (*get_status)(ne_session_t, dispatch_queue_t, void (^)(int));
	void (*get_info)(ne_session_t, int, dispatch_queue_t, void (^)(xpc_object_t));
	void (*send_barrier)(ne_session_t);
	uint64_t (*generation)(void);
};

static void load(struct api *a, const char *path)
{
	a->h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!a->h) {
		fprintf(stderr, "dlopen %s: %s\n", path, dlerror());
		exit(2);
	}
#define S(f, n) do { *(void **)&a->f = dlsym(a->h, n); if (!a->f) { fprintf(stderr, "%s: missing %s\n", path, n); exit(2); } } while (0)
	S(status_name, "ne_session_status_to_string");
	S(type_name, "ne_session_type_to_string");
	S(info_name, "ne_session_info_type_to_string");
	S(stop_name, "ne_session_stop_reason_to_string");
	S(create, "ne_session_create");
	S(retain, "ne_session_retain");
	S(release, "ne_session_release");
	S(cancel, "ne_session_cancel");
	S(set_event_handler, "ne_session_set_event_handler");
	S(get_status, "ne_session_get_status");
	S(get_info, "ne_session_get_info");
	S(send_barrier, "ne_session_send_barrier");
	S(generation, "ne_get_configuration_generation");
#undef S
}

static struct api apple, finch;
static long checks, failures;

static void check_str(const char *what, const char *x, const char *y)
{
	checks++;
	if ((x == NULL) != (y == NULL) || (x && strcmp(x, y))) {
		failures++;
		if (failures <= 40)
			printf("FAIL %s: apple [%s] finch [%s]\n", what, x ? x : "(null)", y ? y : "(null)");
	}
}

static void check_u64(const char *what, uint64_t x, uint64_t y)
{
	checks++;
	if (x != y) {
		failures++;
		if (failures <= 40)
			printf("FAIL %s: apple %llu finch %llu\n", what, x, y);
	}
}

static void data_symbols(void)
{
	const char *u64[] = { "NE_TRACKER_MAX_BACKTRACE_SIZE", "NE_TRACKER_MAX_PROCNAME_SIZE" };
	for (int i = 0; i < 2; i++)
		check_u64(u64[i], *(uint64_t *)dlsym(apple.h, u64[i]), *(uint64_t *)dlsym(finch.h, u64[i]));
	const char *b[] = { "g_ne_read_uuid_cache", "g_ne_uuid_cache_hit" };
	for (int i = 0; i < 2; i++)
		check_u64(b[i], *(uint8_t *)dlsym(apple.h, b[i]), *(uint8_t *)dlsym(finch.h, b[i]));
	const char *u[] = { "ne_privacy_dns_netagent_id", "ne_privacy_proxy_netagent_id" };
	for (int i = 0; i < 2; i++) {
		char x[37], y[37];
		uuid_unparse(dlsym(apple.h, u[i]), x);
		uuid_unparse(dlsym(finch.h, u[i]), y);
		check_str(u[i], x, y);
	}
}

static void names(void)
{
	char what[64];
	for (int v = -300; v < 300; v++) {
		snprintf(what, sizeof(what), "status name %d", v);
		check_str(what, apple.status_name(v), finch.status_name(v));
		snprintf(what, sizeof(what), "type name %d", v);
		check_str(what, apple.type_name(v), finch.type_name(v));
		snprintf(what, sizeof(what), "info name %d", v);
		check_str(what, apple.info_name(v), finch.info_name(v));
		snprintf(what, sizeof(what), "stop reason %d", v);
		check_str(what, apple.stop_name(v), finch.stop_name(v));
	}
}

/* Functions without arguments whose answers don't depend on the host's
 * network extension configurations. */
static void constants(void)
{
	const char *fns[] = {
		"ne_session_use_as_system_vpn", "ne_tracker_check_is_hostname_blocked",
		"ne_tracker_should_save_stacktrace", "ne_tracker_copy_current_stacktrace",
		"ne_tracker_get_disposition", "ne_session_policy_match_get_service_type",
		"ne_session_policy_match_get_service_action", "ne_session_service_get_dns_service_id",
		"nelog_is_info_logging_enabled", "nelog_is_debug_logging_enabled",
		"nelog_is_extra_vpn_logging_enabled", "ne_session_is_safeboot",
	};
	for (size_t i = 0; i < sizeof(fns) / sizeof(fns[0]); i++) {
		uint64_t (*x)(void) = dlsym(apple.h, fns[i]), (*y)(void) = dlsym(finch.h, fns[i]);
		/* bool and int results: compare the low 32 bits. */
		check_u64(fns[i], x() & 0xffffffff, y() & 0xffffffff);
	}
	for (int i = 0; i < 3; i++)
		check_u64("ne_get_configuration_generation", apple.generation(), finch.generation());
}

/* One session's observable behavior, as a log. */
static char *session_log(struct api *a, int type)
{
	char *log = NULL;
	size_t n = 0;
	FILE *f = open_memstream(&log, &n);
	dispatch_queue_t q = dispatch_queue_create("ne-compare", NULL);
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	uuid_t u;
	uuid_generate(u);
	ne_session_t s = a->create(u, type);
	fprintf(f, "create %s\n", s ? "ok" : "NULL");
	if (s) {
		__block int events = 0;
		a->set_event_handler(s, q, ^(int ev, void *data) {
			fprintf(f, "event %d data %s\n", ev, data ? "set" : "NULL");
			events++;
			dispatch_semaphore_signal(done);
		});
		a->get_status(s, q, ^(int st) { fprintf(f, "status %d\n", st); dispatch_semaphore_signal(done); });
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
		for (int it = 0; it < 7; it++) {
			a->get_info(s, it, q, ^(xpc_object_t info) {
				fprintf(f, "info %d %s\n", it, info ? "set" : "NULL");
				dispatch_semaphore_signal(done);
			});
			dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
		}
		a->retain(s);
		a->send_barrier(s);
		a->release(s);
		a->cancel(s);
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
		/* Nothing more arrives after the cancel event. */
		dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4));
		dispatch_sync(q, ^{ fprintf(f, "events %d\n", events); });
		a->release(s);
	}
	fclose(f);
	return log;
}

static void sessions(void)
{
	char what[64];
	for (int type = 0; type < 14; type++) {
		char *x = session_log(&apple, type), *y = session_log(&finch, type);
		snprintf(what, sizeof(what), "session type %d", type);
		check_str(what, x, y);
		free(x);
		free(y);
	}
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: ne-compare <Finch's libsystem_networkextension.dylib>\n");
		return 2;
	}
	load(&apple, "/usr/lib/system/libsystem_networkextension.dylib");
	load(&finch, argv[1]);
	if (apple.h == finch.h) {
		fprintf(stderr, "ne-compare: %s loaded as Apple's library\n", argv[1]);
		return 2;
	}
	data_symbols();
	names();
	constants();
	sessions();
	printf("ne-compare: %ld checks, %ld failures\n", checks, failures);
	return failures != 0;
}
