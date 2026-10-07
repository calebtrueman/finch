/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_containermanager: the client side of app containers (sandboxed
 * apps' private directories, app groups, system containers). On macOS the
 * work is done by Apple's closed containermanagerd; this library asks it over
 * XPC. Finch has no container daemon yet (FINCH-NOT-YET), so every lookup
 * answers the way macOS 26.4 answers an unsandboxed, unentitled process:
 * nothing is found, entitlement-gated requests are refused, and app group
 * paths are computed under the home directory. Error codes, error objects
 * and their descriptions, class helpers and the entitlement parsing match
 * Apple's library (tests/cm-compare.c checks them against it).
 *
 * The exports nothing in the system calls are in stubs.c.
 */

#include <Block.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include <xpc/xpc.h>

#include "errors.h"

#define EXPORT __attribute__((visibility("default")))

/* ---- data ---- */

EXPORT const uint32_t CONTAINER_CURRENT_MOBILE_UID = 1;
EXPORT const uint32_t CONTAINER_SYSTEM_UID = 499;
EXPORT const uint32_t CONTAINER_INSTALLATION_UID = 33;
EXPORT const uint64_t CONTAINER_NOTIFY_GENERATION_INITIAL = 1000;
EXPORT const uint64_t CONTAINER_NOTIFY_GENERATION_INVALID = UINT64_MAX;
EXPORT const char *const CONTAINER_PERSONA_PRIMARY = "com.apple.containermanager.primary-persona";
EXPORT const char *const CONTAINER_PERSONA_CURRENT = "com.apple.containermanager.current-persona";
EXPORT const char *const CONTAINER_NOTIFY_USER_INVALIDATED = "com.apple.containermanagerd.user-invalidated";
EXPORT const char *const CONTAINER_CLASS_NAMES[16] = {
	NULL, "app", "appData", "plugin", "pluginData", "vpn", "vpnData", "appGroup",
	"framework", "xpcService", "daemon", "tempDir", "systemData", "systemGroup",
	"perUserApp", NULL,
};

/* Error types used here. */
enum {
	E_SUCCESS = 1,
	E_NIL_IDENTIFIER = 18,
	E_UNDEFINED_CONTAINER_CLASS = 20,
	E_CONTAINER_NOT_FOUND = 21,
	E_INVALID_ARGUMENT = 38,
	E_NOT_ENTITLED = 55,
	E_UNSUPPORTED = 72,
	E_NOT_ENTITLED_FOR_APP_GROUPS = 143,
};
#define CATEGORY_DAEMON 3

static void set_err(uint64_t *err, uint64_t v)
{
	if (err)
		*err = v;
}

/* ---- error codes ---- */

#define NERRORS (sizeof(container_error_names) / sizeof(container_error_names[0]))

EXPORT const char *container_get_error_description(uint64_t code)
{
	return code < NERRORS ? container_error_names[code] : "UNKNOWN";
}

EXPORT bool container_error_is_fatal(uint64_t code)
{
	(void)code;
	return false;
}

/* The codes Apple counts as file-system failures. */
static const uint8_t fs_errors[] = {
	2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 17, 22, 23, 25, 26, 27, 28, 30,
	32, 33, 34, 35, 36, 37, 41, 42, 43, 48, 56, 61, 62, 63, 64, 66, 70, 71,
	82, 84, 85, 86, 87, 92, 102, 103, 104, 105, 106, 109, 122, 123, 125,
	127, 129, 130, 132, 144, 145, 146, 152, 153, 160, 162, 163, 169,
};

EXPORT bool container_error_is_file_system_error(uint64_t code)
{
	for (size_t i = 0; i < sizeof(fs_errors); i++)
		if (fs_errors[i] == code)
			return true;
	return false;
}

/* ---- error objects (Apple's layout: callers may read fields directly) ---- */

typedef struct container_error {
	uint64_t type;
	uint64_t category;
	char *path;
	int posix_errno;
	char *message;
	void *owner_query;
	void *owner_references;
	void *owner_notify;
} container_error_t;

EXPORT void container_error_reinitialize(container_error_t *e, uint64_t category, uint64_t type,
    const char *path, int posix_errno, const char *message)
{
	free(e->path);
	free(e->message);
	e->type = type;
	e->category = category;
	e->path = path ? strndup(path, 1024) : NULL;
	e->posix_errno = posix_errno;
	e->message = message ? strdup(message) : NULL;
}

EXPORT container_error_t *container_error_create_with_message(uint64_t category, uint64_t type,
    const char *path, int posix_errno, const char *message)
{
	container_error_t *e = calloc(1, sizeof(*e));
	if (e)
		container_error_reinitialize(e, category, type, path, posix_errno, message);
	return e;
}

EXPORT container_error_t *container_error_create(uint64_t category, uint64_t type,
    const char *path, int posix_errno)
{
	return container_error_create_with_message(category, type, path, posix_errno, NULL);
}

EXPORT container_error_t *container_error_copy(const container_error_t *e)
{
	return container_error_create_with_message(e->category, e->type, e->path, e->posix_errno, e->message);
}

EXPORT void container_error_free(container_error_t *e)
{
	/* An error owned by a query, references or notify object is theirs to free. */
	if (!e || e->owner_query || e->owner_references || e->owner_notify)
		return;
	free(e->path);
	free(e->message);
	free(e);
}

EXPORT uint64_t container_error_get_type(const container_error_t *e) { return e ? e->type : E_SUCCESS; }
EXPORT uint64_t container_error_get_category(const container_error_t *e) { return e->category; }
EXPORT const char *container_error_get_path(const container_error_t *e) { return e->path; }
EXPORT int container_error_get_posix_errno(const container_error_t *e) { return e->posix_errno; }
EXPORT const char *container_error_get_message(const container_error_t *e) { return e->message; }

EXPORT char *container_error_copy_unlocalized_description(const container_error_t *e)
{
	char *s = NULL;
	if (!e)
		return NULL;
	const char *msg = e->message ? e->message : "";
	if (e->posix_errno)
		asprintf(&s, "%llu→(%llu) %s at path [%s] with errno (%d) %s; %s",
		    e->category, e->type, container_get_error_description(e->type),
		    e->path ? e->path : "(null)", e->posix_errno, strerror(e->posix_errno), msg);
	else
		asprintf(&s, "%llu→(%llu) %s; %s", e->category, e->type,
		    container_get_error_description(e->type), msg);
	return s;
}

/* ---- classes ---- */

EXPORT uint64_t container_class_normalized(uint64_t c)
{
	return (c == 4 || c == 6 || c == 9 || c == 11) ? 2 : c;
}

EXPORT bool container_class_supports_data_subdirectory(uint64_t c)
{
	return c == 2 || c == 4 || c == 6 || c == 9 || c == 10 || c == 11;
}

EXPORT bool container_class_supports_randomized_path(uint64_t c)
{
	(void)c;
	return true;
}

EXPORT bool container_class_supports_randomized_path_on_current_platform(uint64_t c)
{
	return !(c == 2 || c == 4 || c == 6 || c == 7 || c == 9 || c == 11);
}

/* ---- container objects ---- */

/* Finch never has a container to hand out (no daemon), so no object is ever
 * created; the accessors callers use accept NULL. */
typedef struct container_object {
	char *path;
	char *identifier;
	uint64_t class;
	char *sandbox_token;
} container_object_t;

EXPORT const char *container_get_path(const container_object_t *o) { return o ? o->path : NULL; }
EXPORT const char *container_get_identifier(const container_object_t *o) { return o ? o->identifier : NULL; }

EXPORT char *container_copy_sandbox_token(const container_object_t *o)
{
	if (!o || !o->identifier || o->class < 1 || o->class > 14 || !o->sandbox_token)
		return NULL;
	return strndup(o->sandbox_token, 2048);
}

EXPORT void container_free_object(container_object_t *o)
{
	if (!o)
		return;
	free(o->path);
	free(o->identifier);
	free(o->sandbox_token);
	free(o);
}

/* ---- queries ---- */

typedef struct container_query {
	container_error_t *last_error;   /* Apple's first field too */
	uint64_t class;
	uint64_t flags;
	xpc_object_t identifiers;
	char *persona;
} container_query_t;

EXPORT container_query_t *container_query_create(void)
{
	return calloc(1, sizeof(container_query_t));
}

static void query_set_error(container_query_t *q, uint64_t category, uint64_t type)
{
	if (q->last_error) {
		q->last_error->owner_query = NULL;
		container_error_free(q->last_error);
	}
	q->last_error = container_error_create(category, type, NULL, 0);
	if (q->last_error)
		q->last_error->owner_query = q;
}

EXPORT void container_query_free(container_query_t *q)
{
	if (!q)
		return;
	if (q->last_error) {
		q->last_error->owner_query = NULL;
		container_error_free(q->last_error);
	}
	if (q->identifiers)
		xpc_release(q->identifiers);
	free(q->persona);
	free(q);
}

EXPORT void container_query_set_class(container_query_t *q, uint64_t c) { q->class = c; }
EXPORT void container_query_operation_set_flags(container_query_t *q, uint64_t f) { q->flags = f; }

EXPORT void container_query_set_identifiers(container_query_t *q, xpc_object_t ids)
{
	if (ids)
		xpc_retain(ids);
	if (q->identifiers)
		xpc_release(q->identifiers);
	q->identifiers = ids;
}

EXPORT void container_query_set_persona_unique_string(container_query_t *q, const char *p)
{
	free(q->persona);
	q->persona = p ? strdup(p) : NULL;
}

EXPORT container_error_t *container_query_get_last_error(const container_query_t *q)
{
	return q->last_error;
}

/* Nothing is found. Classes the platform doesn't have are unsupported;
 * asking for named containers, or daemon containers, is refused, as macOS
 * refuses an unentitled process; a query for all containers of another class
 * finds none. */
EXPORT container_object_t *container_query_get_single_result(container_query_t *q)
{
	uint64_t type = 0;
	if (q->class < 1 || q->class > 14)
		type = E_INVALID_ARGUMENT;
	else if (q->class == 3 || q->class == 5 || q->class == 8 || q->class >= 12)
		type = E_UNSUPPORTED;
	else if (q->class == 10 || q->identifiers)
		type = E_NOT_ENTITLED;
	if (type)
		query_set_error(q, CATEGORY_DAEMON, type);
	return NULL;
}

/* ---- lookups ---- */

static const char *home_directory(void)
{
	static char home[1024];
	if (!home[0]) {
		struct passwd pw, *res = NULL;
		char buf[4096];
		if (getpwuid_r(geteuid(), &pw, buf, sizeof(buf), &res) == 0 && res && res->pw_dir)
			strlcpy(home, res->pw_dir, sizeof(home));
	}
	return home[0] ? home : NULL;
}

EXPORT const char *container_pwd_get_cached_current_user_home_path(void)
{
	return home_directory();
}

/* The error macOS gives an unsandboxed process looking up its own container. */
static uint64_t current_user_lookup_error(uint64_t class, const char *identifier)
{
	if (class < 1 || class > 14)
		return E_UNDEFINED_CONTAINER_CLASS;
	switch (class) {
	case 3: case 5: case 8: case 12: case 13: case 14:
		return E_UNSUPPORTED;
	case 7: case 10:
		return E_NOT_ENTITLED;
	default:
		return identifier ? E_NOT_ENTITLED : E_CONTAINER_NOT_FOUND;
	}
}

EXPORT char *container_create_or_lookup_path_for_current_user(uint64_t class, const char *identifier,
    bool create, bool flag, void *reserved, uint64_t *err)
{
	(void)create; (void)flag; (void)reserved;
	set_err(err, current_user_lookup_error(class, identifier));
	return NULL;
}

EXPORT container_object_t *container_create_or_lookup_for_current_user(uint64_t class, const char *identifier,
    bool create, bool flag, void *reserved, uint64_t *err)
{
	(void)create; (void)flag; (void)reserved;
	set_err(err, current_user_lookup_error(class, identifier));
	return NULL;
}

EXPORT char *container_create_or_lookup_path_for_platform(uint64_t class, const char *identifier,
    void *platform, bool create, bool flag, void *reserved, uint64_t *err)
{
	(void)platform; (void)create; (void)flag; (void)reserved;
	set_err(err, current_user_lookup_error(class, identifier));
	return NULL;
}

EXPORT container_object_t *container_copy_from_path(const char *path, container_object_t **out, uint64_t *err)
{
	struct stat st;
	(void)out;
	if (!path)
		set_err(err, E_INVALID_ARGUMENT);
	else   /* Apple asks the sandbox first, which refuses paths that don't exist. */
		set_err(err, lstat(path, &st) == 0 ? E_CONTAINER_NOT_FOUND : E_NOT_ENTITLED);
	return NULL;
}

EXPORT uint64_t container_delete_all_data_container_content_for_current_user(const char *identifier)
{
	return identifier ? E_NOT_ENTITLED : E_NIL_IDENTIFIER;
}

/* App groups live in ~/Library/Group Containers/<group>; the path is
 * returned whether or not the directory exists (nothing is created). */
EXPORT char *container_create_or_lookup_app_group_path_by_app_group_identifier(const char *group, uint64_t *err)
{
	const char *home = home_directory();
	char *p = NULL;
	if (!group || !*group) {
		set_err(err, E_INVALID_ARGUMENT);
		return NULL;
	}
	if (!strcmp(group, ".") || !strcmp(group, "..")) {
		set_err(err, 138);   /* INVALID_IDENTIFIER */
		return NULL;
	}
	if (!home || asprintf(&p, "%s/Library/Group Containers/%s", home, group) < 0) {
		set_err(err, 102);   /* USER_HOME_DIRECTORY_MISSING */
		return NULL;
	}
	for (char *c = p + strlen(home) + sizeof("/Library/Group Containers/") - 1; *c; c++)
		if (*c == '/' || *c == ':')
			*c = '-';
	return p;   /* *err is left alone on success */
}

EXPORT xpc_object_t container_create_or_lookup_app_group_paths_for_current_user(void *reserved, uint64_t *err)
{
	(void)reserved; (void)err;
	return xpc_dictionary_create(NULL, NULL, 0);
}

/* The paths of the app groups an entitlement set names. Without a daemon to
 * vouch for them, a non-empty list is refused (as macOS refuses an
 * unentitled caller); the list itself is checked first, as Apple does. */
static xpc_object_t group_paths_from_entitlements(xpc_object_t ents, uint64_t *err)
{
	xpc_object_t groups = ents ? xpc_dictionary_get_value(ents, "com.apple.security.application-groups") : NULL;
	if (!groups || xpc_get_type(groups) != XPC_TYPE_ARRAY) {
		set_err(err, E_NOT_ENTITLED_FOR_APP_GROUPS);
		return NULL;
	}
	size_t n = xpc_array_get_count(groups);
	for (size_t i = 0; i < n; i++)
		if (xpc_get_type(xpc_array_get_value(groups, i)) != XPC_TYPE_STRING) {
			set_err(err, 110);   /* INVALID_QUERY_OBJECT, as Apple reports it */
			return NULL;
		}
	if (n == 0)
		return xpc_dictionary_create(NULL, NULL, 0);
	set_err(err, E_NOT_ENTITLED);
	return NULL;
}

EXPORT xpc_object_t container_create_or_lookup_app_group_paths_from_entitlements(xpc_object_t ents,
    uint64_t flags, uint64_t *err)
{
	(void)flags;
	return group_paths_from_entitlements(ents, err);
}

EXPORT xpc_object_t container_create_or_lookup_app_group_paths_from_entitlements_4ls(xpc_object_t ents,
    uint64_t a, uint64_t b, uint64_t *err)
{
	(void)a; (void)b;
	return group_paths_from_entitlements(ents, err);
}

/* ---- entitlements ---- */

typedef xpc_object_t (^entitlement_read_handler_t)(const char *key);

static void append_strings(xpc_object_t out, xpc_object_t v)
{
	if (xpc_get_type(v) != XPC_TYPE_ARRAY)
		return;
	for (size_t i = 0; i < xpc_array_get_count(v); i++) {
		xpc_object_t s = xpc_array_get_value(v, i);
		if (xpc_get_type(s) == XPC_TYPE_STRING)
			xpc_array_append_value(out, s);
	}
}

/* Strings from the array entitlement key, if present. */
static bool read_strings(xpc_object_t out, entitlement_read_handler_t read, const char *key)
{
	xpc_object_t v = read(key);
	if (!v)
		return false;
	append_strings(out, v);
	xpc_release(v);
	return true;
}

static void append_if_true(xpc_object_t out, entitlement_read_handler_t read, const char *key,
    const char *identifier)
{
	xpc_object_t v = read(key);
	if (!v)
		return;
	if (xpc_bool_get_value(v)) {
		xpc_object_t s = xpc_string_create(identifier);
		xpc_array_append_value(out, s);
		xpc_release(s);
	}
	xpc_release(v);
}

/* The container identifiers a process with these entitlements (read through
 * the handler, which returns retained values) may use for a class. */
EXPORT xpc_object_t container_entitlements_copy_container_identifiers(const char *identifier,
    uint64_t class, uint64_t flags, entitlement_read_handler_t read)
{
	xpc_object_t out = xpc_array_create(NULL, 0);
	if (!read || flags)
		return out;   /* SPI misuse */
	switch (class) {
	case 1: case 2: case 4: case 14: {
		xpc_object_t s = xpc_string_create(identifier);
		xpc_array_append_value(out, s);
		xpc_release(s);
		break;
	}
	case 7:
		read_strings(out, read, "com.apple.security.application-groups");
		read_strings(out, read, "com.apple.private.security.restricted-application-groups");
		break;
	case 10:
		append_if_true(out, read, "com.apple.private.security.daemon-container", identifier);
		break;
	case 12:
		append_if_true(out, read, "com.apple.security.system-container", identifier);
		break;
	case 13:
		if (!read_strings(out, read, "com.apple.security.system-groups"))
			read_strings(out, read, "com.apple.security.system-group-containers");
		break;
	default:
		break;   /* not a valid class */
	}
	return out;
}
