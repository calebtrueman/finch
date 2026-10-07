/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The rest of the libxpc surface that libSystem's own libraries import:
 * the libSystem initializer and fork hooks, entitlements (from the kernel's
 * code-signing blob), bundles, pipe-by-name, dispatch-data and audit-token
 * accessors, and the policy queries Finch answers itself (no app sandbox yet,
 * no event publishers yet).
 */

#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "internal.h"

/* <System/sys/codesign.h> */
#define CS_OPS_ENTITLEMENTS_BLOB 7
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
int csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize,
    audit_token_t *token);

#pragma mark - libSystem hooks

/* Called by libSystem's initializer (Libsystem init.c). */
void _libxpc_initializer(void);
void xpc_atfork_prepare(void);
void xpc_atfork_parent(void);
void xpc_atfork_child(void);

/* libsystem_kernel declares bootstrap_port but leaves it unset; libxpc fills
 * it in, at startup and again in a forked child (whose port space is new). */
static void
_xpc_fetch_bootstrap_port(void)
{
	mach_port_t bp = MACH_PORT_NULL;

	if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bp) == KERN_SUCCESS) {
		bootstrap_port = bp;
	}
}

void
_libxpc_initializer(void)
{
	_xpc_fetch_bootstrap_port();
}

void
xpc_atfork_prepare(void)
{
}

void
xpc_atfork_parent(void)
{
}

void
xpc_atfork_child(void)
{
	/* Connections and pipes don't survive fork (their rights stayed in the
	 * parent); only the bootstrap port is re-established. */
	_xpc_fetch_bootstrap_port();
}

#pragma mark - Entitlements

/* Entitlements blob: big-endian magic 0xfade7171, big-endian length, XML plist. */
static xpc_object_t
_xpc_entitlements_from_csops(pid_t pid, audit_token_t *token)
{
	uint32_t header[2] = { 0, 0 };
	uint32_t len;
	uint8_t *buf;
	xpc_object_t ents;
	int rc;

	rc = token ? csops_audittoken(pid, CS_OPS_ENTITLEMENTS_BLOB, header, sizeof(header), token)
	           : csops(pid, CS_OPS_ENTITLEMENTS_BLOB, header, sizeof(header));
	if (rc == 0) {
		return NULL;   /* fits in 8 bytes: no entitlements */
	}
	if (errno != ERANGE) {
		return NULL;
	}
	len = ntohl(header[1]);
	if (len < 8 || len > 16 << 20) {
		return NULL;
	}
	buf = malloc(len);
	if (buf == NULL) {
		return NULL;
	}
	rc = token ? csops_audittoken(pid, CS_OPS_ENTITLEMENTS_BLOB, buf, len, token)
	           : csops(pid, CS_OPS_ENTITLEMENTS_BLOB, buf, len);
	ents = rc == 0 ? xpc_create_from_plist(buf + 8, len - 8) : NULL;
	free(buf);
	return ents;
}

xpc_object_t xpc_copy_entitlements_for_self(void);
xpc_object_t xpc_copy_entitlement_for_self(const char *key);
xpc_object_t xpc_copy_entitlement_for_token(const char *key, audit_token_t *token);

xpc_object_t
xpc_copy_entitlements_for_self(void)
{
	return _xpc_entitlements_from_csops(getpid(), NULL);
}

xpc_object_t
xpc_copy_entitlement_for_self(const char *key)
{
	xpc_object_t ents = xpc_copy_entitlements_for_self(), v = NULL;

	if (ents != NULL) {
		v = xpc_dictionary_get_value(ents, key);
		if (v) xpc_retain(v);
		xpc_release(ents);
	}
	return v;
}

/* A NULL token means the calling process (libnotify relies on this). */
xpc_object_t
xpc_copy_entitlement_for_token(const char *key, audit_token_t *token)
{
	xpc_object_t ents, v = NULL;

	if (token == NULL) {
		return xpc_copy_entitlement_for_self(key);
	}
	ents = _xpc_entitlements_from_csops((pid_t)token->val[5], token);

	if (ents != NULL) {
		v = xpc_dictionary_get_value(ents, key);
		if (v) xpc_retain(v);
		xpc_release(ents);
	}
	return v;
}

xpc_object_t
xpc_connection_copy_entitlement_value(xpc_connection_t connection, const char *key)
{
	audit_token_t token;

	xpc_connection_get_audit_token(connection, &token);
	return xpc_copy_entitlement_for_token(key, &token);
}

#pragma mark - Policy queries

/* Finch has no app sandbox yet: nothing is sandboxed. */
bool _xpc_runtime_is_app_sandboxed(void);
bool _xpc_runtime_process_has_entered_sandbox(void);

bool
_xpc_runtime_is_app_sandboxed(void)
{
	return false;
}

bool
_xpc_runtime_process_has_entered_sandbox(void)
{
	return false;
}

/* Walks a serialized message without materialising it; nothing uses the
 * result on Finch yet, so report "not traversed". */
bool xpc_traverse_serialized_data(const void *data, size_t length, void *context, void *visitor);

bool
xpc_traverse_serialized_data(const void *data, size_t length, void *context, void *visitor)
{
	(void)data; (void)length; (void)context; (void)visitor;
	return false;
}

#pragma mark - Connections

void __xpc_connection_set_logging(xpc_connection_t connection, bool enabled);
void xpc_connection_set_target_uid(xpc_connection_t connection, uid_t uid);
void xpc_connection_activate(xpc_connection_t connection);

void
__xpc_connection_set_logging(xpc_connection_t connection, bool enabled)
{
	(void)connection; (void)enabled;
}

void
xpc_connection_set_target_uid(xpc_connection_t connection, uid_t uid)
{
	/* Per-user launchd domains don't exist on Finch yet. */
	(void)connection; (void)uid;
}

/* Activating an inactive connection == its first resume. */
void
xpc_connection_activate(xpc_connection_t connection)
{
	xpc_connection_resume(connection);
}

#pragma mark - Data and dictionaries

xpc_object_t
xpc_data_create_with_dispatch_data(dispatch_data_t ddata)
{
	const void *bytes = NULL;
	size_t len = 0;
	dispatch_data_t map = dispatch_data_create_map(ddata, &bytes, &len);
	xpc_object_t d = xpc_data_create(bytes, len);

	dispatch_release(map);
	return d;
}

void xpc_dictionary_get_audit_token(xpc_object_t xdict, audit_token_t *token);

void
xpc_dictionary_get_audit_token(xpc_object_t xdict, audit_token_t *token)
{
	struct _xpc_dictionary_s *d = xdict;

	memset(token, 0, sizeof(*token));
	if (xpc_get_type(xdict) != XPC_TYPE_DICTIONARY) {
		return;
	}
	if (d->connection != NULL) {
		xpc_connection_get_audit_token((xpc_connection_t)d->connection, token);
	} else if (d->has_audit) {
		*token = d->audit;   /* pipe request */
	}
}

#pragma mark - Pipes by name

typedef void *xpc_pipe_t;
xpc_pipe_t xpc_pipe_create(const char *name, uint64_t flags);
xpc_pipe_t xpc_pipe_create_from_port(mach_port_t port, uint64_t flags);

xpc_pipe_t
xpc_pipe_create(const char *name, uint64_t flags)
{
	mach_port_t port = MACH_PORT_NULL;
	xpc_pipe_t pipe;

	if (bootstrap_look_up(bootstrap_port, name, &port) != KERN_SUCCESS) {
		return NULL;
	}
	pipe = xpc_pipe_create_from_port(port, flags);
	mach_port_deallocate(mach_task_self(), port);
	return pipe;
}

#pragma mark - Bundles

struct xpc_bundle_s {
	XPC_OBJECT_HEADER;
	char *path;
	xpc_object_t info;          /* Info.plist dictionary, or NULL */
	int error;
};

extern const struct _xpc_type_s _xpc_type_bundle;
#define XPC_TYPE_BUNDLE (&_xpc_type_bundle)
typedef struct xpc_bundle_s *xpc_bundle_t;

XPC_INTERNAL void
_xpc_bundle_dispose(xpc_object_t obj)
{
	struct xpc_bundle_s *b = obj;

	free(b->path);
	if (b->info) {
		xpc_release(b->info);
	}
}

static xpc_object_t
_xpc_read_plist_file(const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	struct stat st;
	xpc_object_t o = NULL;

	if (fd < 0) {
		return NULL;
	}
	if (fstat(fd, &st) == 0 && st.st_size > 0 && st.st_size < (16 << 20)) {
		char *buf = malloc((size_t)st.st_size);
		if (buf && read(fd, buf, (size_t)st.st_size) == st.st_size) {
			o = xpc_create_from_plist(buf, (size_t)st.st_size);
		}
		free(buf);
	}
	close(fd);
	return o;
}

xpc_bundle_t xpc_bundle_create(const char *path, unsigned int flags);
xpc_bundle_t xpc_bundle_create_main(void);
int xpc_bundle_get_error(xpc_bundle_t bundle);
xpc_object_t xpc_bundle_get_info_dictionary(xpc_bundle_t bundle);
const char *xpc_bundle_get_property(xpc_bundle_t bundle, unsigned int property);
const char *xpc_bundle_get_path(xpc_bundle_t bundle);

xpc_bundle_t
xpc_bundle_create(const char *path, unsigned int flags)
{
	struct xpc_bundle_s *b = _xpc_object_alloc(XPC_TYPE_BUNDLE, sizeof(*b));
	char plist[PATH_MAX];

	(void)flags;
	b->path = strdup(path);
	b->info = NULL;
	snprintf(plist, sizeof(plist), "%s/Contents/Info.plist", path);   /* macOS bundle */
	b->info = _xpc_read_plist_file(plist);
	if (b->info == NULL) {
		snprintf(plist, sizeof(plist), "%s/Info.plist", path);    /* shallow bundle */
		b->info = _xpc_read_plist_file(plist);
	}
	b->error = b->info ? 0 : ENOENT;
	return b;
}

/* The bundle containing the main executable (…/X.app/Contents/MacOS/X). */
xpc_bundle_t
xpc_bundle_create_main(void)
{
	char exe[PATH_MAX], real[PATH_MAX];
	uint32_t size = sizeof(exe);
	char *p;

	if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, real) == NULL) {
		return NULL;
	}
	p = strstr(real, "/Contents/MacOS/");
	if (p == NULL) {
		return NULL;   /* not in a bundle */
	}
	*p = '\0';
	return xpc_bundle_create(real, 0);
}

int
xpc_bundle_get_error(xpc_bundle_t bundle)
{
	return bundle ? bundle->error : EINVAL;
}

xpc_object_t
xpc_bundle_get_info_dictionary(xpc_bundle_t bundle)
{
	return bundle ? bundle->info : NULL;
}

const char *
xpc_bundle_get_path(xpc_bundle_t bundle)
{
	return bundle ? bundle->path : NULL;
}

/* Apple's property enum isn't public; unknown properties are NULL. */
const char *
xpc_bundle_get_property(xpc_bundle_t bundle, unsigned int property)
{
	(void)bundle; (void)property;
	return NULL;
}
