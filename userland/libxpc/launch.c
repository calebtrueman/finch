/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * liblaunch's data API (<launch.h>) and launch_msg(), which macOS keeps in
 * libxpc for older daemons (syslogd, for one). launch_data_t is a plain tree;
 * its layout is private, as on macOS.
 *
 * launch_msg() answers LAUNCH_KEY_CHECKIN: finch-init's "checkin" control
 * request names the caller's job and its MachServices, and the receive
 * rights come from bootstrap_check_in, as a job using the newer API gets
 * them. The reply has the shape launchd's has: {Label, MachServices: {name:
 * machport}, Sockets: {name: [fd]}}. A job inherits its sockets from
 * finch-init, which reports their descriptors; launch_activate_socket() asks
 * the same way. Other requests fail with ENOTSUP.
 */

#include <errno.h>
#include <launch.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "internal.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"   /* all of <launch.h> is */

struct _launch_data {
	launch_data_type_t type;
	union {
		struct {
			launch_data_t *items;   /* dictionaries: key, value, key, value, ... */
			size_t count;
		};
		struct {
			void *bytes;            /* strings (with NUL) and opaque data */
			size_t size;
		};
		long long number;
		double real;
		bool boolean;
		int fd;
		mach_port_t port;
		int err;
	};
};

launch_data_t
launch_data_alloc(launch_data_type_t type)
{
	launch_data_t d = calloc(1, sizeof(*d));

	if (d) {
		d->type = type;
	}
	return d;
}

launch_data_type_t
launch_data_get_type(const launch_data_t d)
{
	return d->type;
}

/* <launch.h> declares launch_data_free's argument nonnull, which lets the
 * compiler drop a NULL check there; empty slots are freed through this. */
static void
data_free(launch_data_t d)
{
	if (d == NULL) {
		return;
	}
	switch (d->type) {
	case LAUNCH_DATA_DICTIONARY:
	case LAUNCH_DATA_ARRAY:
		for (size_t i = 0; i < d->count; i++) {
			data_free(d->items[i]);
		}
		free(d->items);
		break;
	case LAUNCH_DATA_STRING:
	case LAUNCH_DATA_OPAQUE:
		free(d->bytes);
		break;
	default:
		break;
	}
	free(d);
}

void
launch_data_free(launch_data_t d)
{
	data_free(d);
}

launch_data_t
launch_data_copy(launch_data_t d)
{
	launch_data_t c = launch_data_alloc(d->type);

	if (c == NULL) {
		return NULL;
	}
	*c = *d;
	switch (d->type) {
	case LAUNCH_DATA_DICTIONARY:
	case LAUNCH_DATA_ARRAY:
		c->items = calloc(d->count ? d->count : 1, sizeof(launch_data_t));
		for (size_t i = 0; i < d->count; i++) {
			c->items[i] = d->items[i] ? launch_data_copy(d->items[i]) : NULL;
		}
		break;
	case LAUNCH_DATA_STRING:
	case LAUNCH_DATA_OPAQUE:
		c->bytes = malloc(d->size ? d->size : 1);
		memcpy(c->bytes, d->bytes, d->size);
		break;
	default:
		break;
	}
	return c;
}

static bool
grow(launch_data_t d, size_t count)
{
	launch_data_t *items = realloc(d->items, count * sizeof(launch_data_t));

	if (items == NULL) {
		return false;
	}
	for (size_t i = d->count; i < count; i++) {
		items[i] = NULL;
	}
	d->items = items;
	d->count = count;
	return true;
}

#pragma mark Dictionaries

bool
launch_data_dict_insert(launch_data_t dict, const launch_data_t value, const char *key)
{
	if (dict->type != LAUNCH_DATA_DICTIONARY) {
		return false;
	}
	for (size_t i = 0; i < dict->count; i += 2) {
		if (strcmp(dict->items[i]->bytes, key) == 0) {
			data_free(dict->items[i + 1]);
			dict->items[i + 1] = value;
			return true;
		}
	}
	size_t n = dict->count;
	if (!grow(dict, n + 2)) {
		return false;
	}
	dict->items[n] = launch_data_new_string(key);
	dict->items[n + 1] = value;
	return true;
}

launch_data_t
launch_data_dict_lookup(const launch_data_t dict, const char *key)
{
	if (dict->type != LAUNCH_DATA_DICTIONARY) {
		return NULL;
	}
	for (size_t i = 0; i < dict->count; i += 2) {
		if (strcmp(dict->items[i]->bytes, key) == 0) {
			return dict->items[i + 1];
		}
	}
	return NULL;
}

bool
launch_data_dict_remove(launch_data_t dict, const char *key)
{
	if (dict->type != LAUNCH_DATA_DICTIONARY) {
		return false;
	}
	for (size_t i = 0; i < dict->count; i += 2) {
		if (strcmp(dict->items[i]->bytes, key) == 0) {
			data_free(dict->items[i]);
			data_free(dict->items[i + 1]);
			memmove(&dict->items[i], &dict->items[i + 2],
			    (dict->count - i - 2) * sizeof(launch_data_t));
			dict->count -= 2;
			return true;
		}
	}
	return false;
}

void
launch_data_dict_iterate(const launch_data_t dict, launch_data_dict_iterator_t iterator, void *ctx)
{
	if (dict->type != LAUNCH_DATA_DICTIONARY) {
		return;
	}
	for (size_t i = 0; i < dict->count; i += 2) {
		iterator(dict->items[i + 1], dict->items[i]->bytes, ctx);
	}
}

size_t
launch_data_dict_get_count(const launch_data_t dict)
{
	return dict->type == LAUNCH_DATA_DICTIONARY ? dict->count / 2 : 0;
}

#pragma mark Arrays

bool
launch_data_array_set_index(launch_data_t array, const launch_data_t value, size_t index)
{
	if (array->type != LAUNCH_DATA_ARRAY) {
		return false;
	}
	if (index >= array->count && !grow(array, index + 1)) {
		return false;
	}
	data_free(array->items[index]);
	array->items[index] = value;
	return true;
}

launch_data_t
launch_data_array_get_index(const launch_data_t array, size_t index)
{
	if (array->type != LAUNCH_DATA_ARRAY || index >= array->count) {
		return NULL;
	}
	return array->items[index];
}

size_t
launch_data_array_get_count(const launch_data_t array)
{
	return array->type == LAUNCH_DATA_ARRAY ? array->count : 0;
}

#pragma mark Scalars

#define SCALAR(name, ctype, member, TYPE)                                        \
	launch_data_t launch_data_new_##name(ctype v)                            \
	{                                                                        \
		launch_data_t d = launch_data_alloc(TYPE);                       \
		if (d) d->member = v;                                            \
		return d;                                                        \
	}                                                                        \
	bool launch_data_set_##name(launch_data_t d, ctype v)                    \
	{                                                                        \
		d->member = v;                                                   \
		return true;                                                     \
	}                                                                        \
	ctype launch_data_get_##name(const launch_data_t d)                      \
	{                                                                        \
		return d->member;                                                \
	}

SCALAR(fd, int, fd, LAUNCH_DATA_FD)
SCALAR(machport, mach_port_t, port, LAUNCH_DATA_MACHPORT)
SCALAR(integer, long long, number, LAUNCH_DATA_INTEGER)
SCALAR(bool, bool, boolean, LAUNCH_DATA_BOOL)
SCALAR(real, double, real, LAUNCH_DATA_REAL)
SCALAR(errno, int, err, LAUNCH_DATA_ERRNO)

static bool
set_bytes(launch_data_t d, const void *bytes, size_t size)
{
	void *copy = malloc(size ? size : 1);

	if (copy == NULL) {
		return false;
	}
	memcpy(copy, bytes, size);
	free(d->bytes);
	d->bytes = copy;
	d->size = size;
	return true;
}

launch_data_t
launch_data_new_string(const char *s)
{
	launch_data_t d = launch_data_alloc(LAUNCH_DATA_STRING);

	if (d && !set_bytes(d, s, strlen(s) + 1)) {
		free(d);
		return NULL;
	}
	return d;
}

bool
launch_data_set_string(launch_data_t d, const char *s)
{
	return set_bytes(d, s, strlen(s) + 1);
}

const char *
launch_data_get_string(const launch_data_t d)
{
	return d->type == LAUNCH_DATA_STRING ? d->bytes : NULL;
}

launch_data_t
launch_data_new_opaque(const void *bytes, size_t size)
{
	launch_data_t d = launch_data_alloc(LAUNCH_DATA_OPAQUE);

	if (d && !set_bytes(d, bytes, size)) {
		free(d);
		return NULL;
	}
	return d;
}

bool
launch_data_set_opaque(launch_data_t d, const void *bytes, size_t size)
{
	return set_bytes(d, bytes, size);
}

void *
launch_data_get_opaque(const launch_data_t d)
{
	return d->type == LAUNCH_DATA_OPAQUE ? d->bytes : NULL;
}

size_t
launch_data_get_opaque_size(const launch_data_t d)
{
	return d->type == LAUNCH_DATA_OPAQUE ? d->size : 0;
}

#pragma mark launch_msg

/* finch-init's description of the caller's job (a reply to retain), or NULL with errno set. */
static xpc_object_t
copy_own_job(xpc_object_t *reply_out)
{
	xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0), reply = NULL, job;
	int rc;

	xpc_dictionary_set_string(req, "op", "checkin");
	rc = _xpc_pipe_routine_port(bootstrap_port, XPC_MSGID_PIPE_ROUTINE, req, &reply, NULL);
	xpc_release(req);
	if (rc == 0) {
		rc = (int)xpc_dictionary_get_int64(reply, "error");
	}
	job = rc == 0 ? xpc_dictionary_get_value(reply, "job") : NULL;
	if (job == NULL) {
		if (reply) {
			xpc_release(reply);
		}
		errno = rc ? rc : ESRCH;
		return NULL;
	}
	*reply_out = reply;
	return job;
}

static launch_data_t
checkin(void)
{
	xpc_object_t reply, job = copy_own_job(&reply), services, sockets;
	launch_data_t result, mach;

	if (job == NULL) {
		return NULL;
	}

	result = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
	launch_data_dict_insert(result,
	    launch_data_new_string(xpc_dictionary_get_string(job, "label")), LAUNCH_JOBKEY_LABEL);
	mach = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
	services = xpc_dictionary_get_value(job, "services");
	for (size_t i = 0; services && i < xpc_array_get_count(services); i++) {
		const char *name = xpc_dictionary_get_string(xpc_array_get_value(services, i), "name");
		mach_port_t port = MACH_PORT_NULL;
		if (name && bootstrap_check_in(bootstrap_port, name, &port) == KERN_SUCCESS) {
			launch_data_dict_insert(mach, launch_data_new_machport(port), name);
		}
	}
	launch_data_dict_insert(result, mach, LAUNCH_JOBKEY_MACHSERVICES);
	sockets = xpc_dictionary_get_value(job, "sockets");
	if (sockets != NULL) {
		launch_data_t socks = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
		xpc_dictionary_apply(sockets, ^bool(const char *name, xpc_object_t fds) {
			launch_data_t a = launch_data_alloc(LAUNCH_DATA_ARRAY);
			for (size_t i = 0; i < xpc_array_get_count(fds); i++) {
				launch_data_array_set_index(a,
				    launch_data_new_fd((int)xpc_array_get_int64(fds, i)), i);
			}
			launch_data_dict_insert(socks, a, name);
			return true;
		});
		launch_data_dict_insert(result, socks, LAUNCH_JOBKEY_SOCKETS);
	}
	xpc_release(reply);
	return result;
}

/* launch_activate_socket(3): the descriptors of the caller's socket `name`. */
int
launch_activate_socket(const char *name, int **fds, size_t *count)
{
	xpc_object_t reply, job = copy_own_job(&reply), sockets, list;

	*fds = NULL;
	*count = 0;
	if (job == NULL) {
		return errno == ESRCH ? ESRCH : errno;
	}
	sockets = xpc_dictionary_get_value(job, "sockets");
	list = sockets ? xpc_dictionary_get_value(sockets, name) : NULL;
	if (list == NULL || xpc_array_get_count(list) == 0) {
		xpc_release(reply);
		return ENOENT;
	}
	*count = xpc_array_get_count(list);
	*fds = malloc(*count * sizeof(int));
	for (size_t i = 0; i < *count; i++) {
		(*fds)[i] = (int)xpc_array_get_int64(list, i);
	}
	xpc_release(reply);
	return 0;
}

launch_data_t
launch_msg(const launch_data_t request)
{
	if (request->type == LAUNCH_DATA_STRING && strcmp(request->bytes, LAUNCH_KEY_CHECKIN) == 0) {
		return checkin();
	}
	errno = ENOTSUP;
	return NULL;
}
