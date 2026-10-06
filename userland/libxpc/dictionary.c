/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * XPC dictionaries (and errors, which are dictionaries of class OS_xpc_error).
 * Entries keep insertion order; lookups are linear for small dictionaries and
 * use an open-addressing index above XPC_DICT_INDEX_THRESHOLD entries.
 */

#include <stdlib.h>
#include <string.h>

#include "internal.h"

static struct _xpc_dictionary_s *
_xpc_dict(xpc_object_t obj)
{
	xpc_type_t t;

	if (obj == NULL) {
		return NULL;
	}
	t = xpc_get_type(obj);
	return (t == XPC_TYPE_DICTIONARY || t == XPC_TYPE_ERROR) ? (struct _xpc_dictionary_s *)obj : NULL;
}

static uint32_t
_xpc_key_hash(const char *key)
{
	return _xpc_hash_bytes(key, strlen(key));
}

/* Rebuild the index from live entries (also compacts out deleted ones). */
static void
_xpc_dict_rebuild(struct _xpc_dictionary_s *d)
{
	size_t w = 0;

	for (size_t r = 0; r < d->used; r++) {
		if (d->entries[r].key != NULL) {
			d->entries[w++] = d->entries[r];
		}
	}
	d->used = w;

	free(d->index);
	d->index = NULL;
	d->index_size = 0;
	if (d->count <= XPC_DICT_INDEX_THRESHOLD) {
		return;
	}
	d->index_size = 16;
	while (d->index_size < d->count * 2) {
		d->index_size *= 2;
	}
	d->index = calloc(d->index_size, sizeof(uint32_t));
	if (d->index == NULL) {
		abort();
	}
	for (size_t i = 0; i < d->used; i++) {
		size_t slot = d->entries[i].hash & (d->index_size - 1);
		while (d->index[slot] != 0) {
			slot = (slot + 1) & (d->index_size - 1);
		}
		d->index[slot] = (uint32_t)i + 1;
	}
}

/* Position of `key` in entries[], or -1. */
static ssize_t
_xpc_dict_find(struct _xpc_dictionary_s *d, const char *key, uint32_t hash)
{
	if (d->index == NULL) {
		for (size_t i = 0; i < d->used; i++) {
			const struct xpc_dict_entry_s *e = &d->entries[i];
			/* No hash check here: static dictionaries (the error
			 * singletons) don't carry precomputed hashes. */
			if (e->key != NULL && strcmp(e->key, key) == 0) {
				return (ssize_t)i;
			}
		}
		return -1;
	}
	for (size_t slot = hash & (d->index_size - 1);; slot = (slot + 1) & (d->index_size - 1)) {
		uint32_t pos = d->index[slot];
		if (pos == 0) {
			return -1;
		}
		const struct xpc_dict_entry_s *e = &d->entries[pos - 1];
		if (e->key != NULL && e->hash == hash && strcmp(e->key, key) == 0) {
			return (ssize_t)(pos - 1);
		}
	}
}

static void
_xpc_dict_insert(struct _xpc_dictionary_s *d, const char *key, uint32_t hash, xpc_object_t value)
{
	if (d->used == d->capacity) {
		size_t cap = d->capacity ? d->capacity * 2 : 4;
		d->entries = reallocf(d->entries, cap * sizeof(*d->entries));
		if (d->entries == NULL) {
			abort();
		}
		d->capacity = cap;
	}
	d->entries[d->used].key = strdup(key);
	d->entries[d->used].value = xpc_retain(value);
	d->entries[d->used].hash = hash;
	d->used++;
	d->count++;

	if (d->count > XPC_DICT_INDEX_THRESHOLD &&
	    (d->index == NULL || d->used * 2 > d->index_size)) {
		_xpc_dict_rebuild(d);
	} else if (d->index != NULL) {
		size_t slot = hash & (d->index_size - 1);
		while (d->index[slot] != 0) {
			slot = (slot + 1) & (d->index_size - 1);
		}
		d->index[slot] = (uint32_t)d->used;
	}
}

xpc_object_t
xpc_dictionary_create(const char *const *keys, xpc_object_t const *values, size_t count)
{
	struct _xpc_dictionary_s *d = _xpc_object_alloc(XPC_TYPE_DICTIONARY, sizeof(*d));

	d->count = d->used = d->capacity = d->index_size = 0;
	d->entries = NULL;
	d->index = NULL;
	d->reply_port = MACH_PORT_NULL;
	d->reply_msgid = 0;
	d->connection = NULL;
	d->msgid = 0;
	d->has_audit = false;
	for (size_t i = 0; i < count; i++) {
		xpc_dictionary_set_value(d, keys[i], values[i]);
	}
	return d;
}

xpc_object_t
xpc_dictionary_create_empty(void)
{
	return xpc_dictionary_create(NULL, NULL, 0);
}

void
_xpc_dictionary_dispose(struct _xpc_dictionary_s *d)
{
	for (size_t i = 0; i < d->used; i++) {
		if (d->entries[i].key != NULL) {
			free(d->entries[i].key);
			xpc_release(d->entries[i].value);
		}
	}
	free(d->entries);
	free(d->index);
	if (MACH_PORT_VALID(d->reply_port)) {
		/* An unanswered request: dropping the send-once right tells the sender. */
		mach_port_deallocate(mach_task_self(), d->reply_port);
	}
	if (d->connection) {
		xpc_release(d->connection);
	}
}

size_t
xpc_dictionary_get_count(xpc_object_t xdict)
{
	struct _xpc_dictionary_s *d = _xpc_dict(xdict);
	return d ? d->count : 0;
}

void
xpc_dictionary_set_value(xpc_object_t xdict, const char *key, xpc_object_t value)
{
	struct _xpc_dictionary_s *d = _xpc_dict(xdict);
	uint32_t hash;
	ssize_t pos;

	if (d == NULL || key == NULL) {
		return;
	}
	hash = _xpc_key_hash(key);
	pos = _xpc_dict_find(d, key, hash);
	if (value == NULL) {
		/* Setting NULL removes the key. */
		if (pos >= 0) {
			free(d->entries[pos].key);
			xpc_release(d->entries[pos].value);
			d->entries[pos].key = NULL;
			d->count--;
			_xpc_dict_rebuild(d);
		}
		return;
	}
	if (pos >= 0) {
		xpc_object_t old = d->entries[pos].value;
		d->entries[pos].value = xpc_retain(value);
		xpc_release(old);
		return;
	}
	_xpc_dict_insert(d, key, hash, value);
}

xpc_object_t
xpc_dictionary_get_value(xpc_object_t xdict, const char *key)
{
	struct _xpc_dictionary_s *d = _xpc_dict(xdict);
	ssize_t pos;

	if (d == NULL || key == NULL) {
		return NULL;
	}
	pos = _xpc_dict_find(d, key, _xpc_key_hash(key));
	return pos >= 0 ? d->entries[pos].value : NULL;
}

bool
xpc_dictionary_apply(xpc_object_t xdict, xpc_dictionary_applier_t applier)
{
	struct _xpc_dictionary_s *d = _xpc_dict(xdict);

	if (d == NULL) {
		return true;
	}
	for (size_t i = 0; i < d->used; i++) {
		if (d->entries[i].key != NULL && !applier(d->entries[i].key, d->entries[i].value)) {
			return false;
		}
	}
	return true;
}

xpc_object_t
_xpc_dictionary_copy(xpc_object_t xdict)
{
	struct _xpc_dictionary_s *d = _xpc_dict(xdict);
	xpc_object_t copy = xpc_dictionary_create(NULL, NULL, 0);

	for (size_t i = 0; i < d->used; i++) {
		if (d->entries[i].key != NULL) {
			xpc_object_t c = xpc_copy(d->entries[i].value);
			xpc_dictionary_set_value(copy, d->entries[i].key, c);
			xpc_release(c);
		}
	}
	return copy;
}

bool
_xpc_dictionary_equal(xpc_object_t xa, xpc_object_t xb)
{
	struct _xpc_dictionary_s *a = _xpc_dict(xa), *b = _xpc_dict(xb);

	if (a->count != b->count) {
		return false;
	}
	for (size_t i = 0; i < a->used; i++) {
		if (a->entries[i].key == NULL) {
			continue;
		}
		xpc_object_t other = xpc_dictionary_get_value(xb, a->entries[i].key);
		if (other == NULL || !xpc_equal(a->entries[i].value, other)) {
			return false;
		}
	}
	return true;
}

#pragma mark - Typed setters and getters

static void
_xpc_dictionary_set_new(xpc_object_t d, const char *key, xpc_object_t value)
{
	if (value != NULL) {
		xpc_dictionary_set_value(d, key, value);
		xpc_release(value);
	}
}

void xpc_dictionary_set_bool(xpc_object_t d, const char *k, bool v) { xpc_dictionary_set_value(d, k, xpc_bool_create(v)); }
void xpc_dictionary_set_int64(xpc_object_t d, const char *k, int64_t v) { _xpc_dictionary_set_new(d, k, xpc_int64_create(v)); }
void xpc_dictionary_set_uint64(xpc_object_t d, const char *k, uint64_t v) { _xpc_dictionary_set_new(d, k, xpc_uint64_create(v)); }
void xpc_dictionary_set_double(xpc_object_t d, const char *k, double v) { _xpc_dictionary_set_new(d, k, xpc_double_create(v)); }
void xpc_dictionary_set_date(xpc_object_t d, const char *k, int64_t v) { _xpc_dictionary_set_new(d, k, xpc_date_create(v)); }
void xpc_dictionary_set_data(xpc_object_t d, const char *k, const void *b, size_t n) { _xpc_dictionary_set_new(d, k, xpc_data_create(b, n)); }
void xpc_dictionary_set_string(xpc_object_t d, const char *k, const char *s) { _xpc_dictionary_set_new(d, k, xpc_string_create(s)); }
void xpc_dictionary_set_uuid(xpc_object_t d, const char *k, const uuid_t u) { _xpc_dictionary_set_new(d, k, xpc_uuid_create(u)); }
void xpc_dictionary_set_fd(xpc_object_t d, const char *k, int fd) { _xpc_dictionary_set_new(d, k, xpc_fd_create(fd)); }

bool xpc_dictionary_get_bool(xpc_object_t d, const char *k) { xpc_object_t v = xpc_dictionary_get_value(d, k); return v ? xpc_bool_get_value(v) : 0; }
int64_t xpc_dictionary_get_int64(xpc_object_t d, const char *k) { xpc_object_t v = xpc_dictionary_get_value(d, k); return v ? xpc_int64_get_value(v) : 0; }
uint64_t xpc_dictionary_get_uint64(xpc_object_t d, const char *k) { xpc_object_t v = xpc_dictionary_get_value(d, k); return v ? xpc_uint64_get_value(v) : 0; }
double xpc_dictionary_get_double(xpc_object_t d, const char *k) { xpc_object_t v = xpc_dictionary_get_value(d, k); return v ? xpc_double_get_value(v) : 0; }
int64_t xpc_dictionary_get_date(xpc_object_t d, const char *k) { xpc_object_t v = xpc_dictionary_get_value(d, k); return v ? xpc_date_get_value(v) : 0; }
const char *xpc_dictionary_get_string(xpc_object_t d, const char *k) { xpc_object_t v = xpc_dictionary_get_value(d, k); return v ? xpc_string_get_string_ptr(v) : NULL; }
const uint8_t *xpc_dictionary_get_uuid(xpc_object_t d, const char *k) { xpc_object_t v = xpc_dictionary_get_value(d, k); return v ? xpc_uuid_get_bytes(v) : NULL; }
int xpc_dictionary_dup_fd(xpc_object_t d, const char *k) { xpc_object_t v = xpc_dictionary_get_value(d, k); return v ? xpc_fd_dup(v) : 0; }

const void *
xpc_dictionary_get_data(xpc_object_t d, const char *k, size_t *length)
{
	xpc_object_t v = xpc_dictionary_get_value(d, k);

	if (v == NULL) {
		if (length) {
			*length = 0;
		}
		return NULL;
	}
	if (length) {
		*length = xpc_data_get_length(v);
	}
	return xpc_data_get_bytes_ptr(v);
}

xpc_object_t
xpc_dictionary_get_dictionary(xpc_object_t d, const char *k)
{
	xpc_object_t v = xpc_dictionary_get_value(d, k);
	return v && xpc_get_type(v) == XPC_TYPE_DICTIONARY ? v : NULL;
}

xpc_object_t
xpc_dictionary_get_array(xpc_object_t d, const char *k)
{
	xpc_object_t v = xpc_dictionary_get_value(d, k);
	return v && xpc_get_type(v) == XPC_TYPE_ARRAY ? v : NULL;
}

#pragma mark - Replies

xpc_object_t
xpc_dictionary_create_reply(xpc_object_t original)
{
	struct _xpc_dictionary_s *req = _xpc_dict(original), *reply;

	if (req == NULL || !MACH_PORT_VALID(req->reply_port)) {
		return NULL;   /* not a request expecting a reply (or already answered) */
	}
	reply = xpc_dictionary_create(NULL, NULL, 0);
	/* The reply takes over the request's send-once right. */
	reply->reply_port = req->reply_port;
	reply->reply_msgid = XPC_MSGID_REPLY;
	req->reply_port = MACH_PORT_NULL;
	return reply;
}

bool
xpc_dictionary_expects_reply(xpc_object_t xdict)
{
	struct _xpc_dictionary_s *d = _xpc_dict(xdict);
	return d != NULL && MACH_PORT_VALID(d->reply_port) && d->reply_msgid == 0;
}
