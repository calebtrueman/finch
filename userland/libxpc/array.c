/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * XPC arrays.
 */

#include <stdlib.h>
#include <string.h>

#include "internal.h"

static struct xpc_array_s *
_xpc_array(xpc_object_t obj)
{
	return xpc_get_type(obj) == XPC_TYPE_ARRAY ? (struct xpc_array_s *)obj : NULL;
}

static void
_xpc_array_reserve(struct xpc_array_s *a, size_t want)
{
	size_t cap;

	if (want <= a->capacity) {
		return;
	}
	cap = a->capacity ? a->capacity * 2 : 8;
	while (cap < want) {
		cap *= 2;
	}
	a->items = reallocf(a->items, cap * sizeof(xpc_object_t));
	if (a->items == NULL) {
		abort();
	}
	a->capacity = cap;
}

xpc_object_t
xpc_array_create(xpc_object_t const *objects, size_t count)
{
	struct xpc_array_s *a = _xpc_object_alloc(XPC_TYPE_ARRAY, sizeof(*a));

	a->count = 0;
	a->capacity = 0;
	a->items = NULL;
	_xpc_array_reserve(a, count);
	for (size_t i = 0; i < count; i++) {
		a->items[a->count++] = xpc_retain(objects[i]);
	}
	return a;
}

xpc_object_t
xpc_array_create_empty(void)
{
	return xpc_array_create(NULL, 0);
}

void
_xpc_array_dispose(struct xpc_array_s *a)
{
	for (size_t i = 0; i < a->count; i++) {
		xpc_release(a->items[i]);
	}
	free(a->items);
}

size_t
xpc_array_get_count(xpc_object_t xarray)
{
	struct xpc_array_s *a = _xpc_array(xarray);
	return a ? a->count : 0;
}

void
xpc_array_set_value(xpc_object_t xarray, size_t index, xpc_object_t value)
{
	struct xpc_array_s *a = _xpc_array(xarray);
	xpc_object_t old;

	if (a == NULL || value == NULL) {
		return;
	}
	if (index == XPC_ARRAY_APPEND) {
		xpc_array_append_value(xarray, value);
		return;
	}
	if (index >= a->count) {
		abort();   /* out of bounds: Apple's libxpc crashes too */
	}
	old = a->items[index];
	a->items[index] = xpc_retain(value);
	xpc_release(old);
}

void
xpc_array_append_value(xpc_object_t xarray, xpc_object_t value)
{
	struct xpc_array_s *a = _xpc_array(xarray);

	if (a == NULL || value == NULL) {
		return;
	}
	_xpc_array_reserve(a, a->count + 1);
	a->items[a->count++] = xpc_retain(value);
}

xpc_object_t
xpc_array_get_value(xpc_object_t xarray, size_t index)
{
	struct xpc_array_s *a = _xpc_array(xarray);

	if (a == NULL || index >= a->count) {
		return NULL;
	}
	return a->items[index];
}

bool
xpc_array_apply(xpc_object_t xarray, xpc_array_applier_t applier)
{
	struct xpc_array_s *a = _xpc_array(xarray);

	if (a == NULL) {
		return true;
	}
	for (size_t i = 0; i < a->count; i++) {
		if (!applier(i, a->items[i])) {
			return false;
		}
	}
	return true;
}

xpc_object_t
_xpc_array_copy(xpc_object_t xarray)
{
	struct xpc_array_s *a = _xpc_array(xarray);
	xpc_object_t copy = xpc_array_create(NULL, 0);

	for (size_t i = 0; i < a->count; i++) {
		xpc_object_t c = xpc_copy(a->items[i]);
		xpc_array_append_value(copy, c);
		xpc_release(c);
	}
	return copy;
}

bool
_xpc_array_equal(xpc_object_t xa, xpc_object_t xb)
{
	struct xpc_array_s *a = xa, *b = xb;

	if (a->count != b->count) {
		return false;
	}
	for (size_t i = 0; i < a->count; i++) {
		if (!xpc_equal(a->items[i], b->items[i])) {
			return false;
		}
	}
	return true;
}

#pragma mark - Typed setters and getters

/* Store a freshly created object (consumes the creation reference). */
static void
_xpc_array_set_new(xpc_object_t xarray, size_t index, xpc_object_t value)
{
	if (value != NULL) {
		xpc_array_set_value(xarray, index, value);
		xpc_release(value);
	}
}

void xpc_array_set_bool(xpc_object_t a, size_t i, bool v) { xpc_array_set_value(a, i, xpc_bool_create(v)); }
void xpc_array_set_int64(xpc_object_t a, size_t i, int64_t v) { _xpc_array_set_new(a, i, xpc_int64_create(v)); }
void xpc_array_set_uint64(xpc_object_t a, size_t i, uint64_t v) { _xpc_array_set_new(a, i, xpc_uint64_create(v)); }
void xpc_array_set_double(xpc_object_t a, size_t i, double v) { _xpc_array_set_new(a, i, xpc_double_create(v)); }
void xpc_array_set_date(xpc_object_t a, size_t i, int64_t v) { _xpc_array_set_new(a, i, xpc_date_create(v)); }
void xpc_array_set_data(xpc_object_t a, size_t i, const void *b, size_t n) { _xpc_array_set_new(a, i, xpc_data_create(b, n)); }
void xpc_array_set_string(xpc_object_t a, size_t i, const char *s) { _xpc_array_set_new(a, i, xpc_string_create(s)); }
void xpc_array_set_uuid(xpc_object_t a, size_t i, const uuid_t u) { _xpc_array_set_new(a, i, xpc_uuid_create(u)); }
void xpc_array_set_fd(xpc_object_t a, size_t i, int fd) { _xpc_array_set_new(a, i, xpc_fd_create(fd)); }

bool xpc_array_get_bool(xpc_object_t a, size_t i) { xpc_object_t v = xpc_array_get_value(a, i); return v ? xpc_bool_get_value(v) : 0; }
int64_t xpc_array_get_int64(xpc_object_t a, size_t i) { xpc_object_t v = xpc_array_get_value(a, i); return v ? xpc_int64_get_value(v) : 0; }
uint64_t xpc_array_get_uint64(xpc_object_t a, size_t i) { xpc_object_t v = xpc_array_get_value(a, i); return v ? xpc_uint64_get_value(v) : 0; }
double xpc_array_get_double(xpc_object_t a, size_t i) { xpc_object_t v = xpc_array_get_value(a, i); return v ? xpc_double_get_value(v) : 0; }
int64_t xpc_array_get_date(xpc_object_t a, size_t i) { xpc_object_t v = xpc_array_get_value(a, i); return v ? xpc_date_get_value(v) : 0; }
const char *xpc_array_get_string(xpc_object_t a, size_t i) { xpc_object_t v = xpc_array_get_value(a, i); return v ? xpc_string_get_string_ptr(v) : NULL; }
const uint8_t *xpc_array_get_uuid(xpc_object_t a, size_t i) { xpc_object_t v = xpc_array_get_value(a, i); return v ? xpc_uuid_get_bytes(v) : NULL; }
int xpc_array_dup_fd(xpc_object_t a, size_t i) { xpc_object_t v = xpc_array_get_value(a, i); return v ? xpc_fd_dup(v) : 0; }

const void *
xpc_array_get_data(xpc_object_t a, size_t i, size_t *length)
{
	xpc_object_t v = xpc_array_get_value(a, i);

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
xpc_array_get_array(xpc_object_t a, size_t i)
{
	xpc_object_t v = xpc_array_get_value(a, i);
	return v && xpc_get_type(v) == XPC_TYPE_ARRAY ? v : NULL;
}

xpc_object_t
xpc_array_get_dictionary(xpc_object_t a, size_t i)
{
	xpc_object_t v = xpc_array_get_value(a, i);
	return v && xpc_get_type(v) == XPC_TYPE_DICTIONARY ? v : NULL;
}
