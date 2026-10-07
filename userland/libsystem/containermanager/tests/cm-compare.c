/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * cm-compare: calls Apple's libsystem_containermanager and Finch's the same
 * way and compares the results: data symbols, error codes and descriptions,
 * error objects, class helpers, entitlement parsing, and the lookups an
 * unsandboxed process makes (Apple's answers come from containermanagerd).
 * Only lookups that change nothing are made: never pass a true "create"
 * argument (the third of the *_for_current_user lookups), or containermanagerd
 * creates real containers for this executable on the host.
 *
 *   cm-compare <path to Finch's libsystem_containermanager.dylib>
 */

#include <dlfcn.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

typedef xpc_object_t (^reader_t)(const char *);

struct api {
	void *h;
	const char *(*err_desc)(uint64_t);
	bool (*is_fs)(uint64_t);
	bool (*is_fatal)(uint64_t);
	void *(*err_create)(uint64_t, uint64_t, const char *, int, const char *);
	void *(*err_copy)(void *);
	void (*err_free)(void *);
	uint64_t (*err_type)(void *);
	uint64_t (*err_category)(void *);
	const char *(*err_path)(void *);
	int (*err_errno)(void *);
	const char *(*err_message)(void *);
	char *(*err_describe)(void *);
	uint64_t (*normalized)(uint64_t);
	bool (*data_subdir)(uint64_t);
	bool (*randomized)(uint64_t);
	bool (*randomized_here)(uint64_t);
	xpc_object_t (*ents_ids)(const char *, uint64_t, uint64_t, reader_t);
	char *(*path_cu)(uint64_t, const char *, bool, bool, void *, uint64_t *);
	void *(*obj_cu)(uint64_t, const char *, bool, bool, void *, uint64_t *);
	char *(*path_platform)(uint64_t, const char *, void *, bool, bool, void *, uint64_t *);
	void *(*from_path)(const char *, void **, uint64_t *);
	uint64_t (*delete_all)(const char *);
	char *(*group_path)(const char *, uint64_t *);
	xpc_object_t (*group_paths_cu)(void *, uint64_t *);
	xpc_object_t (*group_paths_ents)(xpc_object_t, uint64_t, uint64_t *);
	xpc_object_t (*group_paths_4ls)(xpc_object_t, uint64_t, uint64_t, uint64_t *);
	void *(*q_create)(void);
	void (*q_free)(void *);
	void (*q_class)(void *, uint64_t);
	void (*q_ids)(void *, xpc_object_t);
	void (*q_flags)(void *, uint64_t);
	void (*q_persona)(void *, const char *);
	void *(*q_single)(void *);
	void *(*q_error)(void *);
	char *(*sandbox_token)(void *);
};

static void load(struct api *a, const char *path)
{
	a->h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!a->h) {
		fprintf(stderr, "dlopen %s: %s\n", path, dlerror());
		exit(2);
	}
#define S(f, n) do { *(void **)&a->f = dlsym(a->h, n); if (!a->f) { fprintf(stderr, "%s: missing %s\n", path, n); exit(2); } } while (0)
	S(err_desc, "container_get_error_description");
	S(is_fs, "container_error_is_file_system_error");
	S(is_fatal, "container_error_is_fatal");
	S(err_create, "container_error_create_with_message");
	S(err_copy, "container_error_copy");
	S(err_free, "container_error_free");
	S(err_type, "container_error_get_type");
	S(err_category, "container_error_get_category");
	S(err_path, "container_error_get_path");
	S(err_errno, "container_error_get_posix_errno");
	S(err_message, "container_error_get_message");
	S(err_describe, "container_error_copy_unlocalized_description");
	S(normalized, "container_class_normalized");
	S(data_subdir, "container_class_supports_data_subdirectory");
	S(randomized, "container_class_supports_randomized_path");
	S(randomized_here, "container_class_supports_randomized_path_on_current_platform");
	S(ents_ids, "container_entitlements_copy_container_identifiers");
	S(path_cu, "container_create_or_lookup_path_for_current_user");
	S(obj_cu, "container_create_or_lookup_for_current_user");
	S(path_platform, "container_create_or_lookup_path_for_platform");
	S(from_path, "container_copy_from_path");
	S(delete_all, "container_delete_all_data_container_content_for_current_user");
	S(group_path, "container_create_or_lookup_app_group_path_by_app_group_identifier");
	S(group_paths_cu, "container_create_or_lookup_app_group_paths_for_current_user");
	S(group_paths_ents, "container_create_or_lookup_app_group_paths_from_entitlements");
	S(group_paths_4ls, "container_create_or_lookup_app_group_paths_from_entitlements_4ls");
	S(q_create, "container_query_create");
	S(q_free, "container_query_free");
	S(q_class, "container_query_set_class");
	S(q_ids, "container_query_set_identifiers");
	S(q_flags, "container_query_operation_set_flags");
	S(q_persona, "container_query_set_persona_unique_string");
	S(q_single, "container_query_get_single_result");
	S(q_error, "container_query_get_last_error");
	S(sandbox_token, "container_copy_sandbox_token");
#undef S
}

static struct api apple, finch;
static long checks, failures;

static void check_str(const char *what, const char *x, const char *y)
{
	checks++;
	if ((x == NULL) != (y == NULL) || (x && strcmp(x, y))) {
		failures++;
		if (failures <= 400)
			printf("FAIL %s: apple [%s] finch [%s]\n", what, x ? x : "(null)", y ? y : "(null)");
	}
}

static void check_u64(const char *what, uint64_t x, uint64_t y)
{
	checks++;
	if (x != y) {
		failures++;
		if (failures <= 400)
			printf("FAIL %s: apple %llu finch %llu\n", what, x, y);
	}
}

/* The strings of an XPC array (or a placeholder for other values). */
static char *strings_of(xpc_object_t v)
{
	char *s = NULL;
	size_t n = 0;
	FILE *f = open_memstream(&s, &n);
	if (!v)
		fputs("NULL", f);
	else if (xpc_get_type(v) == XPC_TYPE_ARRAY) {
		fputs("[", f);
		for (size_t i = 0; i < xpc_array_get_count(v); i++) {
			const char *e = xpc_array_get_string(v, i);
			fprintf(f, "%s%s", i ? "," : "", e ? e : "<non-string>");
		}
		fputs("]", f);
	} else if (xpc_get_type(v) == XPC_TYPE_DICTIONARY)
		fprintf(f, "dict(%zu)", xpc_dictionary_get_count(v));
	else
		fputs("other", f);
	fclose(f);
	return s;
}

static void data_symbols(void)
{
	const char *u32[] = { "CONTAINER_CURRENT_MOBILE_UID", "CONTAINER_SYSTEM_UID", "CONTAINER_INSTALLATION_UID" };
	for (int i = 0; i < 3; i++)
		check_u64(u32[i], *(uint32_t *)dlsym(apple.h, u32[i]), *(uint32_t *)dlsym(finch.h, u32[i]));
	const char *u64[] = { "CONTAINER_NOTIFY_GENERATION_INITIAL", "CONTAINER_NOTIFY_GENERATION_INVALID" };
	for (int i = 0; i < 2; i++)
		check_u64(u64[i], *(uint64_t *)dlsym(apple.h, u64[i]), *(uint64_t *)dlsym(finch.h, u64[i]));
	const char *str[] = { "CONTAINER_PERSONA_PRIMARY", "CONTAINER_PERSONA_CURRENT", "CONTAINER_NOTIFY_USER_INVALIDATED" };
	for (int i = 0; i < 3; i++)
		check_str(str[i], *(const char **)dlsym(apple.h, str[i]), *(const char **)dlsym(finch.h, str[i]));
	const char **an = dlsym(apple.h, "CONTAINER_CLASS_NAMES"), **fn = dlsym(finch.h, "CONTAINER_CLASS_NAMES");
	for (int i = 0; i < 16; i++)
		check_str("CONTAINER_CLASS_NAMES", an[i], fn[i]);
	/* Each seam pointer starts at its default table. */
	const char *seams[][2] = {
		{ "gCMContainerSeam", "CMCONTAINERSEAM_DEFAULT" }, { "gCMDispatchSeam", "CMDISPATCHSEAM_DEFAULT" },
		{ "gCMFSSeam", "CMFSSEAM_DEFAULT" }, { "gCMNotifySeam", "CMNOTIFYSEAM_DEFAULT" },
		{ "gCMPWDSeam", "CMPWDSEAM_DEFAULT" }, { "gCMQuarantineSeam", "CMQUARANTINESEAM_DEFAULT" },
		{ "gCMSandboxSeam", "CMSANDBOXSEAM_DEFAULT" },
	};
	for (int i = 0; i < 7; i++)
		check_u64(seams[i][0], *(void **)dlsym(apple.h, seams[i][0]) == dlsym(apple.h, seams[i][1]),
		    *(void **)dlsym(finch.h, seams[i][0]) == dlsym(finch.h, seams[i][1]));
}

static void errors(void)
{
	char what[128];
	for (uint64_t c = 0; c < 400; c++) {
		snprintf(what, sizeof(what), "error description %llu", c);
		check_str(what, apple.err_desc(c), finch.err_desc(c));
		snprintf(what, sizeof(what), "is_file_system_error %llu", c);
		check_u64(what, apple.is_fs(c), finch.is_fs(c));
		snprintf(what, sizeof(what), "is_fatal %llu", c);
		check_u64(what, apple.is_fatal(c), finch.is_fatal(c));
	}
	check_u64("get_type(NULL)", apple.err_type(NULL), finch.err_type(NULL));
	check_str("describe(NULL)", apple.err_describe(NULL), finch.err_describe(NULL));

	const char *paths[] = { NULL, "/tmp/p", "/a b/[c]" };
	const char *msgs[] = { NULL, "", "hello", "x; y" };
	const int errnos[] = { 0, 1, 2, 13, 63, 999 };
	const uint64_t types[] = { 0, 1, 21, 55, 72, 169, 170, 500 };
	for (int ti = 0; ti < 8; ti++)
		for (uint64_t cat = 0; cat < 6; cat++)
			for (int pi = 0; pi < 3; pi++)
				for (int ei = 0; ei < 6; ei++)
					for (int mi = 0; mi < 4; mi++) {
						void *x = apple.err_create(cat, types[ti], paths[pi], errnos[ei], msgs[mi]);
						void *y = finch.err_create(cat, types[ti], paths[pi], errnos[ei], msgs[mi]);
						void *xc = apple.err_copy(x), *yc = finch.err_copy(y);
						snprintf(what, sizeof(what), "error(%llu,%llu,%s,%d,%s)", cat, types[ti],
						    paths[pi] ? paths[pi] : "NULL", errnos[ei], msgs[mi] ? msgs[mi] : "NULL");
						check_u64(what, apple.err_type(x), finch.err_type(y));
						check_u64(what, apple.err_category(x), finch.err_category(y));
						check_str(what, apple.err_path(x), finch.err_path(y));
						check_u64(what, apple.err_errno(x), finch.err_errno(y));
						check_str(what, apple.err_message(x), finch.err_message(y));
						char *dx = apple.err_describe(x), *dy = finch.err_describe(y);
						check_str(what, dx, dy);
						free(dx); free(dy);
						dx = apple.err_describe(xc); dy = finch.err_describe(yc);
						check_str(what, dx, dy);
						free(dx); free(dy);
						apple.err_free(x); finch.err_free(y);
						apple.err_free(xc); finch.err_free(yc);
					}
}

static void classes(void)
{
	char what[64];
	for (uint64_t c = 0; c < 40; c++) {
		snprintf(what, sizeof(what), "class %llu", c);
		check_u64(what, apple.normalized(c), finch.normalized(c));
		check_u64(what, apple.data_subdir(c), finch.data_subdir(c));
		check_u64(what, apple.randomized(c), finch.randomized(c));
		check_u64(what, apple.randomized_here(c), finch.randomized_here(c));
	}
}

static xpc_object_t strings(int n, ...)
{
	xpc_object_t a = xpc_array_create(NULL, 0);
	va_list ap;
	va_start(ap, n);
	for (int i = 0; i < n; i++)
		xpc_array_set_string(a, XPC_ARRAY_APPEND, va_arg(ap, const char *));
	va_end(ap);
	return a;
}

static void entitlements(void)
{
	/* Entitlement sets, each read through a handler that logs the keys asked for. */
	xpc_object_t sets[4];
	for (int i = 0; i < 4; i++)
		sets[i] = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_value(sets[1], "com.apple.security.application-groups", strings(2, "group.a", "group.b"));
	xpc_dictionary_set_value(sets[1], "com.apple.private.security.restricted-application-groups", strings(1, "group.r"));
	xpc_dictionary_set_value(sets[1], "com.apple.security.system-groups", strings(1, "systemgroup.a"));
	xpc_dictionary_set_value(sets[1], "com.apple.security.system-group-containers", strings(1, "systemgroup.b"));
	xpc_dictionary_set_bool(sets[1], "com.apple.private.security.daemon-container", true);
	xpc_dictionary_set_bool(sets[1], "com.apple.security.system-container", true);
	xpc_dictionary_set_string(sets[2], "com.apple.security.application-groups", "not-an-array");
	xpc_dictionary_set_bool(sets[2], "com.apple.private.security.daemon-container", false);
	xpc_dictionary_set_bool(sets[2], "com.apple.security.system-container", false);
	xpc_dictionary_set_value(sets[2], "com.apple.security.system-group-containers", strings(2, "s.1", "s.2"));
	xpc_object_t mixed = strings(1, "group.m");
	xpc_array_set_int64(mixed, XPC_ARRAY_APPEND, 7);
	xpc_array_set_string(mixed, XPC_ARRAY_APPEND, "group.n");
	xpc_dictionary_set_value(sets[3], "com.apple.private.security.restricted-application-groups", mixed);
	xpc_dictionary_set_string(sets[3], "com.apple.security.system-groups", "not-an-array");
	xpc_dictionary_set_value(sets[3], "com.apple.security.system-group-containers", strings(1, "unused"));

	char what[96];
	const char *ids[] = { "org.finch.id", "", "a.b.c" };
	for (int si = 0; si < 4; si++)
		for (uint64_t cls = 0; cls < 17; cls++)
			for (int ii = 0; ii < 3; ii++)
				for (uint64_t flags = 0; flags < 2; flags++) {
					char *log[2] = { NULL, NULL };
					xpc_object_t out[2];
					struct api *a[2] = { &apple, &finch };
					for (int k = 0; k < 2; k++) {
						size_t n = 0;
						FILE *f = open_memstream(&log[k], &n);
						xpc_object_t d = sets[si];
						out[k] = a[k]->ents_ids(ids[ii], cls, flags, ^xpc_object_t(const char *key) {
							fprintf(f, "%s;", key);
							xpc_object_t v = xpc_dictionary_get_value(d, key);
							return v ? xpc_retain(v) : NULL;
						});
						fclose(f);
					}
					snprintf(what, sizeof(what), "entitlement identifiers set %d class %llu id %d flags %llu", si, cls, ii, flags);
					char *x = strings_of(out[0]), *y = strings_of(out[1]);
					check_str(what, x, y);
					check_str(what, log[0], log[1]);
					free(x); free(y); free(log[0]); free(log[1]);
					xpc_release(out[0]); xpc_release(out[1]);
				}
	xpc_object_t x = apple.ents_ids("id", 7, 0, NULL), y = finch.ents_ids("id", 7, 0, NULL);
	char *sx = strings_of(x), *sy = strings_of(y);
	check_str("entitlement identifiers without a handler", sx, sy);
	free(sx); free(sy);
}

static void lookups(void)
{
	char what[96];
	const char *ids[] = { NULL, "org.finch.cm-compare.nonexistent" };
	for (uint64_t cls = 0; cls < 17; cls++)
		for (int ii = 0; ii < 2; ii++)
			{
				uint64_t ex = 99, ey = 99;
				char *px = apple.path_cu(cls, ids[ii], false, false, NULL, &ex);
				char *py = finch.path_cu(cls, ids[ii], false, false, NULL, &ey);
				snprintf(what, sizeof(what), "path_for_current_user(%llu, %s)", cls, ids[ii] ? "id" : "NULL");
				check_str(what, px, py);
				check_u64(what, ex, ey);
				ex = ey = 99;
				void *ox = apple.obj_cu(cls, ids[ii], false, false, NULL, &ex);
				void *oy = finch.obj_cu(cls, ids[ii], false, false, NULL, &ey);
				snprintf(what, sizeof(what), "for_current_user(%llu, %s)", cls, ids[ii] ? "id" : "NULL");
				check_u64(what, ox != NULL, oy != NULL);
				check_u64(what, ex, ey);
			}
	for (uint64_t p = 0; p < 17; p++)
		for (int ii = 0; ii < 2; ii++) {
			uint64_t ex = 99, ey = 99;
			char *px = apple.path_platform(p, ids[ii], NULL, false, false, NULL, &ex);
			char *py = finch.path_platform(p, ids[ii], NULL, false, false, NULL, &ey);
			snprintf(what, sizeof(what), "path_for_platform(%llu, %s)", p, ids[ii] ? "id" : "NULL");
			check_str(what, px, py);
			check_u64(what, ex, ey);
		}
	const char *paths[] = { NULL, "/", "/tmp", "/nonexistent/x" };
	for (int i = 0; i < 4; i++) {
		uint64_t ex = 99, ey = 99;
		void *outx = (void *)1, *outy = (void *)1;
		void *ox = apple.from_path(paths[i], &outx, &ex), *oy = finch.from_path(paths[i], &outy, &ey);
		snprintf(what, sizeof(what), "copy_from_path(%s)", paths[i] ? paths[i] : "NULL");
		check_u64(what, ox != NULL, oy != NULL);
		check_u64(what, ex, ey);
		check_u64(what, (uintptr_t)outx, (uintptr_t)outy);
	}
	/* Deleting the content of a container that can't exist changes nothing. */
	for (int ii = 0; ii < 2; ii++)
		check_u64("delete_all_data_container_content", apple.delete_all(ids[ii]), finch.delete_all(ids[ii]));

	const char *groups[] = { "group.org.finch.cm-compare", "x", "a/b", "/a//b/", "..", ".", "", "a:b", "a b", "../../x", NULL };
	for (int i = 0; i < 11; i++) {
		uint64_t ex = 99, ey = 99;
		char *px = apple.group_path(groups[i], &ex), *py = finch.group_path(groups[i], &ey);
		check_str("app_group_path", px, py);
		check_u64("app_group_path error", ex, ey);
	}
	uint64_t ex = 99, ey = 99;
	xpc_object_t x = apple.group_paths_cu(NULL, &ex), y = finch.group_paths_cu(NULL, &ey);
	char *sx = strings_of(x), *sy = strings_of(y);
	check_str("app_group_paths_for_current_user", sx, sy);
	check_u64("app_group_paths_for_current_user error", ex, ey);
	free(sx); free(sy);

	xpc_object_t ents = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_value(ents, "com.apple.security.application-groups", strings(1, "group.a"));
	xpc_object_t empty_groups = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_value(empty_groups, "com.apple.security.application-groups", xpc_array_create(NULL, 0));
	xpc_object_t bad_groups = xpc_dictionary_create(NULL, NULL, 0);
	xpc_object_t bad = strings(1, "group.a");
	xpc_array_set_int64(bad, XPC_ARRAY_APPEND, 3);
	xpc_dictionary_set_value(bad_groups, "com.apple.security.application-groups", bad);
	xpc_object_t string_groups = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(string_groups, "com.apple.security.application-groups", "group.a");
	xpc_object_t restricted_only = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_value(restricted_only, "com.apple.private.security.restricted-application-groups", strings(1, "group.r"));
	xpc_object_t inputs[] = { NULL, ents, xpc_dictionary_create(NULL, NULL, 0), empty_groups, bad_groups,
	    string_groups, restricted_only };
	for (size_t i = 0; i < sizeof(inputs) / sizeof(inputs[0]); i++) {
		ex = ey = 99;
		x = apple.group_paths_ents(inputs[i], 0, &ex);
		y = finch.group_paths_ents(inputs[i], 0, &ey);
		sx = strings_of(x); sy = strings_of(y);
		check_str("app_group_paths_from_entitlements", sx, sy);
		check_u64("app_group_paths_from_entitlements error", ex, ey);
		free(sx); free(sy);
		ex = ey = 99;
		x = apple.group_paths_4ls(inputs[i], 0, 0, &ex);
		y = finch.group_paths_4ls(inputs[i], 0, 0, &ey);
		sx = strings_of(x); sy = strings_of(y);
		check_str("app_group_paths_from_entitlements_4ls", sx, sy);
		check_u64("app_group_paths_from_entitlements_4ls error", ex, ey);
		free(sx); free(sy);
	}
	check_u64("copy_sandbox_token(NULL)", apple.sandbox_token(NULL) != NULL, finch.sandbox_token(NULL) != NULL);
}

static void queries(void)
{
	char what[96];
	for (uint64_t cls = 0; cls < 17; cls++)
		for (int with_ids = 0; with_ids < 2; with_ids++)
			for (int with_persona = 0; with_persona < 2; with_persona++) {
				void *q[2] = { apple.q_create(), finch.q_create() };
				struct api *a[2] = { &apple, &finch };
				void *r[2], *e[2];
				for (int k = 0; k < 2; k++) {
					a[k]->q_class(q[k], cls);
					a[k]->q_flags(q[k], 0);
					if (with_persona)
						a[k]->q_persona(q[k], "com.apple.containermanager.current-persona");
					if (with_ids) {
						xpc_object_t ids = strings(1, "org.finch.cm-compare.nonexistent");
						a[k]->q_ids(q[k], ids);
						xpc_release(ids);
					}
					r[k] = a[k]->q_single(q[k]);
					e[k] = a[k]->q_error(q[k]);
				}
				snprintf(what, sizeof(what), "query class %llu ids %d persona %d", cls, with_ids, with_persona);
				check_u64(what, r[0] != NULL, r[1] != NULL);
				check_u64(what, e[0] != NULL, e[1] != NULL);
				if (e[0] && e[1]) {
					check_u64(what, apple.err_type(e[0]), finch.err_type(e[1]));
					check_u64(what, apple.err_category(e[0]), finch.err_category(e[1]));
					/* Freeing an error a query owns is ignored. */
					apple.err_free(e[0]);
					finch.err_free(e[1]);
					check_u64(what, apple.err_type(apple.q_error(q[0])), finch.err_type(finch.q_error(q[1])));
				}
				apple.q_free(q[0]);
				finch.q_free(q[1]);
			}
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: cm-compare <Finch's libsystem_containermanager.dylib>\n");
		return 2;
	}
	load(&apple, "/usr/lib/system/libsystem_containermanager.dylib");
	load(&finch, argv[1]);
	if (apple.h == finch.h) {
		fprintf(stderr, "cm-compare: %s loaded as Apple's library\n", argv[1]);
		return 2;
	}
	data_symbols();
	errors();
	classes();
	entitlements();
	lookups();
	queries();
	printf("cm-compare: %ld checks, %ld failures\n", checks, failures);
	return failures != 0;
}
