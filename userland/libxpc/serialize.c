/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * XPC wire format (step X2), compatible with Apple's libxpc. Layout as
 * recorded from macOS 26.4 by tools/xpc-capture (fixtures in tests/fixtures):
 *
 *   message   := u32 magic 0x42133742, u32 version 5, dictionary
 *   object    := u32 type, body
 *   null      0x1000  (no body)
 *   bool      0x2000  u32
 *   int64     0x3000  i64        uint64 0x4000 u64
 *   double    0x5000  f64        date   0x7000 i64 (ns since epoch)
 *   data      0x8000  u32 len, bytes, pad to 4
 *   string    0x9000  u32 len (incl. NUL), bytes, pad to 4
 *   uuid      0xa000  16 bytes
 *   array     0xe000  u32 body length, u32 count, objects
 *   dictionary 0xf000 u32 body length, u32 count, (key NUL-terminated pad 4, object)*
 *
 * All integers are little-endian; everything is 4-byte aligned. Body lengths
 * count the bytes after the length field. Port-carrying types (fd, mach
 * send/receive, endpoint, shmem) travel as Mach descriptors and arrive with
 * the transport (step X3).
 *
 * The decoder parses data from other processes: every read is bounds-checked
 * and nesting depth is limited.
 */

#include <stdlib.h>
#include <string.h>

#include "internal.h"

#define XPC_SERIAL_MAGIC        0x42133742u
#define XPC_SERIAL_VERSION      5u
#define XPC_SERIAL_MAX_DEPTH    128

enum {
	XPC_WIRE_NULL       = 0x1000,
	XPC_WIRE_BOOL       = 0x2000,
	XPC_WIRE_INT64      = 0x3000,
	XPC_WIRE_UINT64     = 0x4000,
	XPC_WIRE_DOUBLE     = 0x5000,
	XPC_WIRE_DATE       = 0x7000,
	XPC_WIRE_DATA       = 0x8000,
	XPC_WIRE_STRING     = 0x9000,
	XPC_WIRE_UUID       = 0xa000,
	XPC_WIRE_ARRAY      = 0xe000,
	XPC_WIRE_DICTIONARY = 0xf000,
};

static inline size_t
pad4(size_t n)
{
	return (n + 3) & ~(size_t)3;
}

#pragma mark - Encoder

struct wbuf {
	uint8_t *p;
	size_t len, cap;
	bool failed;
};

static void
w_reserve(struct wbuf *w, size_t n)
{
	size_t cap;

	if (w->len + n <= w->cap) {
		return;
	}
	cap = w->cap ? w->cap : 256;
	while (cap < w->len + n) {
		cap *= 2;
	}
	w->p = reallocf(w->p, cap);
	if (w->p == NULL) {
		abort();
	}
	w->cap = cap;
}

static void
w_bytes(struct wbuf *w, const void *b, size_t n)
{
	w_reserve(w, pad4(n));
	memcpy(w->p + w->len, b, n);
	memset(w->p + w->len + n, 0, pad4(n) - n);
	w->len += pad4(n);
}

static void
w_u32(struct wbuf *w, uint32_t v)
{
	w_bytes(w, &v, 4);   /* arm64 is little-endian, as is the wire */
}

static void
w_u64(struct wbuf *w, uint64_t v)
{
	w_bytes(w, &v, 8);
}

/* Reserve a u32 length slot; returns its offset. */
static size_t
w_len_slot(struct wbuf *w)
{
	size_t off = w->len;
	w_u32(w, 0);
	return off;
}

static void
w_len_fill(struct wbuf *w, size_t slot)
{
	uint32_t body = (uint32_t)(w->len - slot - 4);
	memcpy(w->p + slot, &body, 4);
}

static void encode(struct wbuf *w, xpc_object_t o);

static void
encode(struct wbuf *w, xpc_object_t o)
{
	xpc_type_t t = xpc_get_type(o);

	if (t == XPC_TYPE_NULL) {
		w_u32(w, XPC_WIRE_NULL);
	} else if (t == XPC_TYPE_BOOL) {
		w_u32(w, XPC_WIRE_BOOL);
		w_u32(w, xpc_bool_get_value(o));
	} else if (t == XPC_TYPE_INT64) {
		w_u32(w, XPC_WIRE_INT64);
		w_u64(w, (uint64_t)xpc_int64_get_value(o));
	} else if (t == XPC_TYPE_UINT64) {
		w_u32(w, XPC_WIRE_UINT64);
		w_u64(w, xpc_uint64_get_value(o));
	} else if (t == XPC_TYPE_DOUBLE) {
		double d = xpc_double_get_value(o);
		w_u32(w, XPC_WIRE_DOUBLE);
		w_bytes(w, &d, 8);
	} else if (t == XPC_TYPE_DATE) {
		w_u32(w, XPC_WIRE_DATE);
		w_u64(w, (uint64_t)xpc_date_get_value(o));
	} else if (t == XPC_TYPE_DATA) {
		w_u32(w, XPC_WIRE_DATA);
		w_u32(w, (uint32_t)xpc_data_get_length(o));
		w_bytes(w, xpc_data_get_bytes_ptr(o), xpc_data_get_length(o));
	} else if (t == XPC_TYPE_STRING) {
		w_u32(w, XPC_WIRE_STRING);
		w_u32(w, (uint32_t)xpc_string_get_length(o) + 1);
		w_bytes(w, xpc_string_get_string_ptr(o), xpc_string_get_length(o) + 1);
	} else if (t == XPC_TYPE_UUID) {
		w_u32(w, XPC_WIRE_UUID);
		w_bytes(w, xpc_uuid_get_bytes(o), 16);
	} else if (t == XPC_TYPE_ARRAY) {
		w_u32(w, XPC_WIRE_ARRAY);
		size_t slot = w_len_slot(w);
		w_u32(w, (uint32_t)xpc_array_get_count(o));
		xpc_array_apply(o, ^bool(size_t i, xpc_object_t v) {
			encode(w, v);
			return true;
		});
		w_len_fill(w, slot);
	} else if (t == XPC_TYPE_DICTIONARY) {
		w_u32(w, XPC_WIRE_DICTIONARY);
		size_t slot = w_len_slot(w);
		w_u32(w, (uint32_t)xpc_dictionary_get_count(o));
		xpc_dictionary_apply(o, ^bool(const char *k, xpc_object_t v) {
			w_bytes(w, k, strlen(k) + 1);
			encode(w, v);
			return true;
		});
		w_len_fill(w, slot);
	} else {
		/* fds, ports, errors, connections: not representable inline. */
		w->failed = true;
	}
}

void *
xpc_make_serialization(xpc_object_t object, size_t *length)
{
	struct wbuf w = { NULL, 0, 0, false };

	if (xpc_get_type(object) != XPC_TYPE_DICTIONARY) {
		return NULL;   /* the top level of a message is a dictionary */
	}
	w_u32(&w, XPC_SERIAL_MAGIC);
	w_u32(&w, XPC_SERIAL_VERSION);
	encode(&w, object);
	if (w.failed) {
		free(w.p);
		return NULL;
	}
	if (length) {
		*length = w.len;
	}
	return w.p;
}

#pragma mark - Decoder

struct rbuf {
	const uint8_t *p;
	size_t len, off;
};

static bool
r_take(struct rbuf *r, void *out, size_t n)
{
	if (n > r->len - r->off || pad4(n) > r->len - r->off) {
		return false;
	}
	if (out) {
		memcpy(out, r->p + r->off, n);
	}
	r->off += pad4(n);
	return true;
}

static bool
r_u32(struct rbuf *r, uint32_t *v)
{
	return r_take(r, v, 4);
}

/* A NUL-terminated string within the remaining bytes, padded to 4. */
static const char *
r_cstring(struct rbuf *r)
{
	const char *s = (const char *)r->p + r->off;
	const void *nul = memchr(s, '\0', r->len - r->off);

	if (nul == NULL || !r_take(r, NULL, (size_t)((const char *)nul - s) + 1)) {
		return NULL;
	}
	return s;
}

static xpc_object_t decode(struct rbuf *r, int depth);

/* A sub-buffer of `len` bytes for a container body. */
static bool
r_sub(struct rbuf *r, struct rbuf *sub)
{
	uint32_t body;

	if (!r_u32(r, &body) || body > r->len - r->off) {
		return false;
	}
	sub->p = r->p + r->off;
	sub->len = body;
	sub->off = 0;
	r->off += body;
	return true;
}

static xpc_object_t
decode(struct rbuf *r, int depth)
{
	uint32_t type, u32;
	uint64_t u64;

	if (depth > XPC_SERIAL_MAX_DEPTH || !r_u32(r, &type)) {
		return NULL;
	}
	switch (type) {
	case XPC_WIRE_NULL:
		return xpc_null_create();
	case XPC_WIRE_BOOL:
		return r_u32(r, &u32) ? xpc_bool_create(u32 != 0) : NULL;
	case XPC_WIRE_INT64:
		return r_take(r, &u64, 8) ? xpc_int64_create((int64_t)u64) : NULL;
	case XPC_WIRE_UINT64:
		return r_take(r, &u64, 8) ? xpc_uint64_create(u64) : NULL;
	case XPC_WIRE_DOUBLE: {
		double d;
		return r_take(r, &d, 8) ? xpc_double_create(d) : NULL;
	}
	case XPC_WIRE_DATE:
		return r_take(r, &u64, 8) ? xpc_date_create((int64_t)u64) : NULL;
	case XPC_WIRE_DATA: {
		const uint8_t *bytes;
		if (!r_u32(r, &u32)) {
			return NULL;
		}
		bytes = r->p + r->off;
		return r_take(r, NULL, u32) ? xpc_data_create(bytes, u32) : NULL;
	}
	case XPC_WIRE_STRING: {
		const char *s;
		if (!r_u32(r, &u32) || u32 == 0) {
			return NULL;
		}
		s = (const char *)r->p + r->off;
		/* The declared length includes the NUL, which must be there. */
		if (!r_take(r, NULL, u32) || s[u32 - 1] != '\0') {
			return NULL;
		}
		return _xpc_string_create_with_length(s, strnlen(s, u32 - 1));
	}
	case XPC_WIRE_UUID: {
		uuid_t uu;
		return r_take(r, uu, 16) ? xpc_uuid_create(uu) : NULL;
	}
	case XPC_WIRE_ARRAY: {
		struct rbuf sub;
		xpc_object_t a;
		if (!r_sub(r, &sub) || !r_u32(&sub, &u32)) {
			return NULL;
		}
		a = xpc_array_create(NULL, 0);
		for (uint32_t i = 0; i < u32; i++) {
			xpc_object_t v = decode(&sub, depth + 1);
			if (v == NULL) {
				xpc_release(a);
				return NULL;
			}
			xpc_array_append_value(a, v);
			xpc_release(v);
		}
		return a;
	}
	case XPC_WIRE_DICTIONARY: {
		struct rbuf sub;
		xpc_object_t d;
		if (!r_sub(r, &sub) || !r_u32(&sub, &u32)) {
			return NULL;
		}
		d = xpc_dictionary_create(NULL, NULL, 0);
		for (uint32_t i = 0; i < u32; i++) {
			const char *k = r_cstring(&sub);
			xpc_object_t v = k ? decode(&sub, depth + 1) : NULL;
			if (v == NULL) {
				xpc_release(d);
				return NULL;
			}
			xpc_dictionary_set_value(d, k, v);
			xpc_release(v);
		}
		return d;
	}
	default:
		return NULL;   /* unknown or port-carrying type (X3) */
	}
}

xpc_object_t
xpc_create_from_serialization(const void *data, size_t length)
{
	struct rbuf r = { data, length, 0 };
	uint32_t magic, version;
	xpc_object_t o;

	if (data == NULL || !r_u32(&r, &magic) || !r_u32(&r, &version) ||
	    magic != XPC_SERIAL_MAGIC || version != XPC_SERIAL_VERSION) {
		return NULL;
	}
	o = decode(&r, 0);
	if (o != NULL && xpc_get_type(o) != XPC_TYPE_DICTIONARY) {
		xpc_release(o);
		return NULL;
	}
	return o;
}
