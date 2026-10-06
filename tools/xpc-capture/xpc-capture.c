/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * xpc-capture: record how Apple's libxpc serializes XPC objects, as golden
 * fixtures for Finch's wire-format implementation (docs/design/XPC.md, X2).
 * Runs on a real Mac against the system libxpc.
 *
 *   xpc-capture > userland/libxpc/tests/fixtures/apple-<build>.txt
 *
 * Output: one sample per line, "<name> <hex bytes>".
 */

#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <xpc/xpc.h>

/* Private libxpc serialization API (exported by Apple's libxpc). */
void *xpc_make_serialization(xpc_object_t obj, size_t *len);

static void
emit(const char *name, xpc_object_t obj)
{
	size_t len = 0;
	const unsigned char *p = xpc_make_serialization(obj, &len);

	printf("%s ", name);
	for (size_t i = 0; p != NULL && i < len; i++) {
		printf("%02x", p[i]);
	}
	printf("\n");
}

/* Wrap a value in a one-key dictionary (the top level must be a dictionary). */
static void
emit_value(const char *name, xpc_object_t value)
{
	xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_value(d, "v", value);
	emit(name, d);
	xpc_release(d);
	xpc_release(value);
}

int
main(void)
{
	char build[64] = "?";
	size_t blen = sizeof(build);
	const uuid_t uu = { 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	                    0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 };
	const unsigned char bytes[] = { 0xde, 0xad, 0xbe, 0xef, 0x42 };

	sysctlbyname("kern.osversion", build, &blen, NULL, 0);
	printf("# Apple libxpc serialization samples, macOS build %s (tools/xpc-capture)\n", build);

	emit("empty_dict", xpc_dictionary_create(NULL, NULL, 0));
	emit_value("null", xpc_null_create());
	emit_value("bool_true", xpc_bool_create(true));
	emit_value("bool_false", xpc_bool_create(false));
	emit_value("int64", xpc_int64_create(-42));
	emit_value("uint64", xpc_uint64_create(0xfedcba9876543210ULL));
	emit_value("double", xpc_double_create(2.5));
	emit_value("date", xpc_date_create(1759752000000000000LL));
	emit_value("data", xpc_data_create(bytes, sizeof(bytes)));
	emit_value("data_empty", xpc_data_create(NULL, 0));
	emit_value("string", xpc_string_create("finch"));
	emit_value("string_4", xpc_string_create("abc"));     /* exactly 4 with NUL */
	emit_value("string_empty", xpc_string_create(""));
	emit_value("uuid", xpc_uuid_create(uu));

	xpc_object_t arr = xpc_array_create(NULL, 0);
	xpc_array_set_int64(arr, XPC_ARRAY_APPEND, 1);
	xpc_array_set_string(arr, XPC_ARRAY_APPEND, "two");
	xpc_array_set_bool(arr, XPC_ARRAY_APPEND, true);
	emit_value("array", arr);

	xpc_object_t nested = xpc_dictionary_create(NULL, NULL, 0);
	xpc_object_t inner = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_uint64(inner, "n", 7);
	xpc_dictionary_set_value(nested, "inner", inner);
	xpc_dictionary_set_string(nested, "key_longer_than_4", "x");
	xpc_release(inner);
	emit("nested", nested);
	xpc_release(nested);
	return 0;
}
