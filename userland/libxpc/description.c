/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * xpc_copy_description(): a human-readable rendering of an object tree, in
 * the general style of Apple's ("<type: 0x...> { ... }").
 */

#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

struct strbuf {
	char *buf;
	size_t len, cap;
};

static void
sb_printf(struct strbuf *sb, const char *fmt, ...)
{
	va_list ap;
	int n;

	for (;;) {
		va_start(ap, fmt);
		n = vsnprintf(sb->buf + sb->len, sb->cap - sb->len, fmt, ap);
		va_end(ap);
		if (n < 0) {
			return;
		}
		if (sb->len + (size_t)n < sb->cap) {
			sb->len += (size_t)n;
			return;
		}
		sb->cap = (sb->cap + (size_t)n + 1) * 2;
		sb->buf = reallocf(sb->buf, sb->cap);
		if (sb->buf == NULL) {
			abort();
		}
	}
}

static void
sb_indent(struct strbuf *sb, int depth)
{
	for (int i = 0; i < depth; i++) {
		sb_printf(sb, "\t");
	}
}

static void describe(struct strbuf *sb, xpc_object_t o, int depth);

static void
describe(struct strbuf *sb, xpc_object_t o, int depth)
{
	xpc_type_t t = xpc_get_type(o);
	const char *name = xpc_type_get_name(t);

	sb_printf(sb, "<%s: %p>", name, o);
	if (t == XPC_TYPE_DICTIONARY || t == XPC_TYPE_ERROR) {
		sb_printf(sb, " { count = %zu, contents =\n", xpc_dictionary_get_count(o));
		xpc_dictionary_apply(o, ^bool(const char *key, xpc_object_t value) {
			sb_indent(sb, depth + 1);
			sb_printf(sb, "\"%s\" => ", key);
			describe(sb, value, depth + 1);
			sb_printf(sb, "\n");
			return true;
		});
		sb_indent(sb, depth);
		sb_printf(sb, "}");
	} else if (t == XPC_TYPE_ARRAY) {
		sb_printf(sb, " { count = %zu, contents =\n", xpc_array_get_count(o));
		xpc_array_apply(o, ^bool(size_t i, xpc_object_t value) {
			sb_indent(sb, depth + 1);
			sb_printf(sb, "%zu: ", i);
			describe(sb, value, depth + 1);
			sb_printf(sb, "\n");
			return true;
		});
		sb_indent(sb, depth);
		sb_printf(sb, "}");
	} else if (t == XPC_TYPE_STRING) {
		sb_printf(sb, " { length = %zu, contents = \"%s\" }",
		    xpc_string_get_length(o), xpc_string_get_string_ptr(o));
	} else if (t == XPC_TYPE_DATA) {
		sb_printf(sb, " { length = %zu bytes }", xpc_data_get_length(o));
	} else if (t == XPC_TYPE_INT64) {
		sb_printf(sb, " %" PRId64, xpc_int64_get_value(o));
	} else if (t == XPC_TYPE_UINT64) {
		sb_printf(sb, " %" PRIu64, xpc_uint64_get_value(o));
	} else if (t == XPC_TYPE_DOUBLE) {
		sb_printf(sb, " %f", xpc_double_get_value(o));
	} else if (t == XPC_TYPE_DATE) {
		sb_printf(sb, " %" PRId64 " ns", xpc_date_get_value(o));
	} else if (t == XPC_TYPE_BOOL) {
		sb_printf(sb, " %s", xpc_bool_get_value(o) ? "true" : "false");
	} else if (t == XPC_TYPE_UUID) {
		uuid_string_t s;
		uuid_unparse_upper(xpc_uuid_get_bytes(o), s);
		sb_printf(sb, " %s", s);
	} else if (t == XPC_TYPE_FD) {
		sb_printf(sb, " { fd = %d }", ((struct xpc_fd_s *)o)->fd);
	}
}

char *
xpc_copy_description(xpc_object_t object)
{
	struct strbuf sb = { NULL, 0, 0 };

	sb.cap = 128;
	sb.buf = malloc(sb.cap);
	if (sb.buf == NULL) {
		return NULL;
	}
	sb.buf[0] = '\0';
	describe(&sb, object, 0);
	return sb.buf;
}
