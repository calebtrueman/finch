/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Scalar and byte-string XPC types: null, bool, int64, uint64, double, date,
 * uuid, fd, string, data. Plus the generic copy / equal / hash.
 */

#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include "internal.h"

#pragma mark - Singletons

const struct _xpc_bool_s _xpc_bool_true = {
	XPC_STATIC_HEADER(XPC_TYPE_BOOL), .value = true,
};
const struct _xpc_bool_s _xpc_bool_false = {
	XPC_STATIC_HEADER(XPC_TYPE_BOOL), .value = false,
};
static const struct xpc_null_s _xpc_null = {
	XPC_STATIC_HEADER(XPC_TYPE_NULL),
};

#pragma mark - Hashing

/* FNV-1a, 32-bit. */
uint32_t
_xpc_hash_bytes(const void *bytes, size_t length)
{
	const uint8_t *p = bytes;
	uint32_t h = 2166136261u;

	while (length--) {
		h ^= *p++;
		h *= 16777619u;
	}
	return h;
}

#pragma mark - null / bool

xpc_object_t
xpc_null_create(void)
{
	return (xpc_object_t)&_xpc_null;
}

xpc_object_t
xpc_bool_create(bool value)
{
	return (xpc_object_t)(value ? XPC_BOOL_TRUE : XPC_BOOL_FALSE);
}

bool
xpc_bool_get_value(xpc_object_t xbool)
{
	if (xpc_get_type(xbool) != XPC_TYPE_BOOL) {
		return false;
	}
	return ((const struct _xpc_bool_s *)xbool)->value;
}

#pragma mark - Numbers and dates

#define XPC_SCALAR(name, ctype, TYPE)                                         \
	xpc_object_t                                                          \
	xpc_##name##_create(ctype value)                                      \
	{                                                                     \
		struct xpc_##name##_s *o = _xpc_object_alloc(TYPE, sizeof(*o)); \
		o->value = value;                                             \
		return o;                                                     \
	}                                                                     \
	ctype                                                                 \
	xpc_##name##_get_value(xpc_object_t obj)                              \
	{                                                                     \
		if (xpc_get_type(obj) != TYPE) {                              \
			return 0;                                             \
		}                                                             \
		return ((struct xpc_##name##_s *)obj)->value;                 \
	}

XPC_SCALAR(int64, int64_t, XPC_TYPE_INT64)
XPC_SCALAR(uint64, uint64_t, XPC_TYPE_UINT64)
XPC_SCALAR(double, double, XPC_TYPE_DOUBLE)
XPC_SCALAR(date, int64_t, XPC_TYPE_DATE)

xpc_object_t
xpc_date_create_from_current(void)
{
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return xpc_date_create((int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000);
}

#pragma mark - uuid

xpc_object_t
xpc_uuid_create(const uuid_t uuid)
{
	struct xpc_uuid_s *o = _xpc_object_alloc(XPC_TYPE_UUID, sizeof(*o));

	memcpy(o->value, uuid, sizeof(uuid_t));
	return o;
}

const uint8_t *
xpc_uuid_get_bytes(xpc_object_t xuuid)
{
	if (xpc_get_type(xuuid) != XPC_TYPE_UUID) {
		return NULL;
	}
	return ((struct xpc_uuid_s *)xuuid)->value;
}

#pragma mark - fd

xpc_object_t
xpc_fd_create(int fd)
{
	int dup_fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
	struct xpc_fd_s *o;

	if (dup_fd < 0) {
		return NULL;
	}
	o = _xpc_object_alloc(XPC_TYPE_FD, sizeof(*o));
	o->fd = dup_fd;
	return o;
}

int
xpc_fd_dup(xpc_object_t xfd)
{
	if (xpc_get_type(xfd) != XPC_TYPE_FD) {
		return -1;
	}
	return fcntl(((struct xpc_fd_s *)xfd)->fd, F_DUPFD_CLOEXEC, 0);
}

#pragma mark - string

xpc_object_t
_xpc_string_create_with_length(const char *s, size_t length)
{
	struct xpc_string_s *o = _xpc_object_alloc(XPC_TYPE_STRING,
	    sizeof(*o) + length + 1);

	memcpy(o->storage, s, length);
	o->storage[length] = '\0';
	o->length = length;
	o->ptr = o->storage;
	return o;
}

xpc_object_t
xpc_string_create(const char *string)
{
	return _xpc_string_create_with_length(string, strlen(string));
}

xpc_object_t
xpc_string_create_with_format_and_arguments(const char *fmt, va_list ap)
{
	char *s = NULL;
	xpc_object_t o;
	int n = vasprintf(&s, fmt, ap);

	if (n < 0) {
		return NULL;
	}
	o = _xpc_string_create_with_length(s, (size_t)n);
	free(s);
	return o;
}

xpc_object_t
xpc_string_create_with_format(const char *fmt, ...)
{
	va_list ap;
	xpc_object_t o;

	va_start(ap, fmt);
	o = xpc_string_create_with_format_and_arguments(fmt, ap);
	va_end(ap);
	return o;
}

size_t
xpc_string_get_length(xpc_object_t xstring)
{
	if (xpc_get_type(xstring) != XPC_TYPE_STRING) {
		return 0;
	}
	return ((struct xpc_string_s *)xstring)->length;
}

const char *
xpc_string_get_string_ptr(xpc_object_t xstring)
{
	if (xpc_get_type(xstring) != XPC_TYPE_STRING) {
		return NULL;
	}
	return ((struct xpc_string_s *)xstring)->ptr;
}

#pragma mark - data

xpc_object_t
xpc_data_create(const void *bytes, size_t length)
{
	struct xpc_data_s *o = _xpc_object_alloc(XPC_TYPE_DATA, sizeof(*o) + length);

	if (length > 0 && bytes != NULL) {
		memcpy(o->storage, bytes, length);
	}
	o->length = length;
	o->ptr = o->storage;
	return o;
}

size_t
xpc_data_get_length(xpc_object_t xdata)
{
	if (xpc_get_type(xdata) != XPC_TYPE_DATA) {
		return 0;
	}
	return ((struct xpc_data_s *)xdata)->length;
}

const void *
xpc_data_get_bytes_ptr(xpc_object_t xdata)
{
	if (xpc_get_type(xdata) != XPC_TYPE_DATA) {
		return NULL;
	}
	return ((struct xpc_data_s *)xdata)->ptr;
}

size_t
xpc_data_get_bytes(xpc_object_t xdata, void *buffer, size_t off, size_t length)
{
	struct xpc_data_s *d = xdata;
	size_t n;

	if (xpc_get_type(xdata) != XPC_TYPE_DATA || off > d->length) {
		return 0;
	}
	n = d->length - off < length ? d->length - off : length;
	memcpy(buffer, (const uint8_t *)d->ptr + off, n);
	return n;
}

#pragma mark - Generic copy / equal / hash

xpc_object_t
xpc_copy(xpc_object_t object)
{
	xpc_type_t t = xpc_get_type(object);

	if (t == XPC_TYPE_DICTIONARY) {
		return _xpc_dictionary_copy(object);
	}
	if (t == XPC_TYPE_ARRAY) {
		return _xpc_array_copy(object);
	}
	if (t == XPC_TYPE_STRING) {
		return _xpc_string_create_with_length(xpc_string_get_string_ptr(object),
		           xpc_string_get_length(object));
	}
	if (t == XPC_TYPE_DATA) {
		return xpc_data_create(xpc_data_get_bytes_ptr(object), xpc_data_get_length(object));
	}
	if (t == XPC_TYPE_INT64) {
		return xpc_int64_create(xpc_int64_get_value(object));
	}
	if (t == XPC_TYPE_UINT64) {
		return xpc_uint64_create(xpc_uint64_get_value(object));
	}
	if (t == XPC_TYPE_DOUBLE) {
		return xpc_double_create(xpc_double_get_value(object));
	}
	if (t == XPC_TYPE_DATE) {
		return xpc_date_create(xpc_date_get_value(object));
	}
	if (t == XPC_TYPE_UUID) {
		return xpc_uuid_create(xpc_uuid_get_bytes(object));
	}
	if (t == XPC_TYPE_FD) {
		return xpc_fd_create(((struct xpc_fd_s *)object)->fd);
	}
	/* bool, null, errors: immutable or immortal; share them. */
	return xpc_retain(object);
}

bool
xpc_equal(xpc_object_t a, xpc_object_t b)
{
	xpc_type_t t = xpc_get_type(a);

	if (a == b) {
		return true;
	}
	if (t != xpc_get_type(b)) {
		return false;
	}
	if (t == XPC_TYPE_DICTIONARY || t == XPC_TYPE_ERROR) {
		return _xpc_dictionary_equal(a, b);
	}
	if (t == XPC_TYPE_ARRAY) {
		return _xpc_array_equal(a, b);
	}
	if (t == XPC_TYPE_STRING) {
		return xpc_string_get_length(a) == xpc_string_get_length(b) &&
		       memcmp(xpc_string_get_string_ptr(a), xpc_string_get_string_ptr(b),
		           xpc_string_get_length(a)) == 0;
	}
	if (t == XPC_TYPE_DATA) {
		return xpc_data_get_length(a) == xpc_data_get_length(b) &&
		       memcmp(xpc_data_get_bytes_ptr(a), xpc_data_get_bytes_ptr(b),
		           xpc_data_get_length(a)) == 0;
	}
	if (t == XPC_TYPE_INT64 || t == XPC_TYPE_DATE) {
		return ((struct xpc_int64_s *)a)->value == ((struct xpc_int64_s *)b)->value;
	}
	if (t == XPC_TYPE_UINT64) {
		return xpc_uint64_get_value(a) == xpc_uint64_get_value(b);
	}
	if (t == XPC_TYPE_DOUBLE) {
		return xpc_double_get_value(a) == xpc_double_get_value(b);
	}
	if (t == XPC_TYPE_UUID) {
		return uuid_compare(xpc_uuid_get_bytes(a), xpc_uuid_get_bytes(b)) == 0;
	}
	if (t == XPC_TYPE_BOOL) {
		return xpc_bool_get_value(a) == xpc_bool_get_value(b);
	}
	if (t == XPC_TYPE_NULL) {
		return true;
	}
	return false;   /* fds and other handles compare by identity */
}

size_t
xpc_hash(xpc_object_t object)
{
	xpc_type_t t = xpc_get_type(object);

	if (t == XPC_TYPE_STRING) {
		return _xpc_hash_bytes(xpc_string_get_string_ptr(object), xpc_string_get_length(object));
	}
	if (t == XPC_TYPE_DATA) {
		return _xpc_hash_bytes(xpc_data_get_bytes_ptr(object), xpc_data_get_length(object));
	}
	if (t == XPC_TYPE_INT64 || t == XPC_TYPE_UINT64 || t == XPC_TYPE_DATE) {
		return (size_t)((struct xpc_uint64_s *)object)->value;
	}
	if (t == XPC_TYPE_DOUBLE) {
		double d = xpc_double_get_value(object);
		return _xpc_hash_bytes(&d, sizeof(d));
	}
	if (t == XPC_TYPE_UUID) {
		return _xpc_hash_bytes(xpc_uuid_get_bytes(object), sizeof(uuid_t));
	}
	if (t == XPC_TYPE_BOOL) {
		return xpc_bool_get_value(object);
	}
	if (t == XPC_TYPE_DICTIONARY || t == XPC_TYPE_ARRAY) {
		/* Containers hash by size: equal containers have equal counts. */
		return t == XPC_TYPE_ARRAY ? xpc_array_get_count(object) : xpc_dictionary_get_count(object);
	}
	return (size_t)(uintptr_t)object;
}
