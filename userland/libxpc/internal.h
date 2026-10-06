/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Finch libxpc: internal definitions. See docs/design/XPC.md.
 *
 * Every XPC object is an Objective-C object whose class is OS_xpc_<type>
 * (a subclass of OS_xpc_object, which subclasses libdispatch's OS_object).
 * The exported type symbols (_xpc_type_<type>) alias those classes, so
 * xpc_get_type() is object_getClass(). The object header is libdispatch's
 * os_object header: isa, ref_cnt, xref_cnt.
 */

#ifndef FINCH_XPC_INTERNAL_H
#define FINCH_XPC_INTERNAL_H

#include <ptrauth.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <uuid/uuid.h>
#include <xpc/xpc.h>

#define XPC_INTERNAL __attribute__((visibility("hidden")))

/* Same layout as libdispatch's _OS_OBJECT_HEADER. */
#define XPC_OBJECT_HEADER \
	const void *__ptrauth_objc_isa_pointer xo_isa; \
	int volatile xo_ref_cnt; \
	int volatile xo_xref_cnt

/* Reference count of statically allocated (immortal) objects. */
#define XPC_GLOBAL_REFCNT INT_MAX

/* Initialiser for a static object of class `type` (e.g. XPC_TYPE_BOOL). */
#define XPC_STATIC_HEADER(type) \
	.xo_isa = (type), .xo_ref_cnt = XPC_GLOBAL_REFCNT, .xo_xref_cnt = XPC_GLOBAL_REFCNT

struct xpc_object_s {
	XPC_OBJECT_HEADER;
};

/* Struct tags match the incomplete types the SDK headers declare. */
struct _xpc_bool_s {
	XPC_OBJECT_HEADER;
	bool value;
};

struct xpc_int64_s {
	XPC_OBJECT_HEADER;
	int64_t value;
};

struct xpc_uint64_s {
	XPC_OBJECT_HEADER;
	uint64_t value;
};

struct xpc_double_s {
	XPC_OBJECT_HEADER;
	double value;
};

struct xpc_date_s {
	XPC_OBJECT_HEADER;
	int64_t value;              /* nanoseconds since the Unix epoch */
};

struct xpc_uuid_s {
	XPC_OBJECT_HEADER;
	uuid_t value;
};

struct xpc_fd_s {
	XPC_OBJECT_HEADER;
	int fd;                     /* owned; closed on dispose */
};

struct xpc_null_s {
	XPC_OBJECT_HEADER;
};

struct xpc_string_s {
	XPC_OBJECT_HEADER;
	size_t length;
	const char *ptr;            /* points at storage[] or, if static, a literal */
	char storage[];
};

struct xpc_data_s {
	XPC_OBJECT_HEADER;
	size_t length;
	const void *ptr;            /* points at storage[] */
	uint8_t storage[];
};

struct xpc_array_s {
	XPC_OBJECT_HEADER;
	size_t count;
	size_t capacity;
	xpc_object_t *items;        /* each retained */
};

struct xpc_dict_entry_s {
	char *key;                  /* NULL = deleted slot */
	xpc_object_t value;         /* retained */
	uint32_t hash;
};

/*
 * Dictionaries keep entries in insertion order. Small ones are searched
 * linearly; once they grow past XPC_DICT_INDEX_THRESHOLD an open-addressing
 * index (of entry positions) is built. Errors are dictionaries too, of class
 * OS_xpc_error.
 */
#define XPC_DICT_INDEX_THRESHOLD 8

struct _xpc_dictionary_s {
	XPC_OBJECT_HEADER;
	size_t count;               /* live entries */
	size_t used;                /* entries[] slots used (live + deleted) */
	size_t capacity;
	struct xpc_dict_entry_s *entries;
	uint32_t *index;            /* index_size slots: entry position + 1, 0 = empty */
	size_t index_size;
};

/* object.m */
XPC_INTERNAL xpc_object_t _xpc_object_alloc(xpc_type_t type, size_t size);
XPC_INTERNAL void _xpc_object_dispose(xpc_object_t obj);

/* Hashing / comparison / description helpers (values.c, description.c) */
XPC_INTERNAL uint32_t _xpc_hash_bytes(const void *bytes, size_t length);
XPC_INTERNAL void _xpc_dictionary_dispose(struct _xpc_dictionary_s *dict);
XPC_INTERNAL void _xpc_array_dispose(struct xpc_array_s *array);
XPC_INTERNAL bool _xpc_dictionary_equal(xpc_object_t a, xpc_object_t b);
XPC_INTERNAL bool _xpc_array_equal(xpc_object_t a, xpc_object_t b);
XPC_INTERNAL xpc_object_t _xpc_dictionary_copy(xpc_object_t dict);
XPC_INTERNAL xpc_object_t _xpc_array_copy(xpc_object_t array);
XPC_INTERNAL xpc_object_t _xpc_string_create_with_length(const char *s, size_t length);

static inline xpc_type_t
_xpc_type(xpc_object_t obj)
{
	return xpc_get_type(obj);
}

#endif /* FINCH_XPC_INTERNAL_H */
