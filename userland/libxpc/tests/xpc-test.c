/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Unit tests for Finch libxpc's object model (step X1). Runs on the host
 * against the @rpath test build. Every xpc_* call binds to Finch's library
 * (two-level namespace), even though the system libxpc is also loaded.
 */

#include <fcntl.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

static int failures, checks;

#define CHECK(cond) do {                                             \
	checks++;                                                    \
	if (!(cond)) {                                               \
		failures++;                                          \
		printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
	}                                                            \
} while (0)

static void
test_types(void)
{
	xpc_object_t s = xpc_string_create("finch");

	/* _xpc_type_string is the class OS_xpc_string. */
	CHECK(xpc_get_type(s) == XPC_TYPE_STRING);
	CHECK(strcmp(class_getName((Class)XPC_TYPE_STRING), "OS_xpc_string") == 0);
	CHECK(strcmp(class_getName(class_getSuperclass((Class)XPC_TYPE_STRING)), "OS_xpc_object") == 0);
	CHECK(strcmp(class_getName(class_getSuperclass(class_getSuperclass((Class)XPC_TYPE_STRING))), "OS_object") == 0);
	CHECK(strcmp(xpc_type_get_name(XPC_TYPE_DICTIONARY), "dictionary") == 0);
	xpc_release(s);
}

static void
test_scalars(void)
{
	xpc_object_t i = xpc_int64_create(-42), u = xpc_uint64_create(UINT64_MAX);
	xpc_object_t d = xpc_double_create(2.5), b = xpc_bool_create(true);
	uuid_t uu;

	CHECK(xpc_int64_get_value(i) == -42);
	CHECK(xpc_uint64_get_value(u) == UINT64_MAX);
	CHECK(xpc_double_get_value(d) == 2.5);
	CHECK(b == XPC_BOOL_TRUE && xpc_bool_get_value(b));
	CHECK(xpc_bool_create(false) == XPC_BOOL_FALSE);
	CHECK(xpc_null_create() == xpc_null_create());
	CHECK(xpc_int64_get_value(d) == 0);              /* wrong type -> 0 */

	uuid_generate(uu);
	xpc_object_t xu = xpc_uuid_create(uu);
	CHECK(memcmp(xpc_uuid_get_bytes(xu), uu, sizeof(uu)) == 0);

	xpc_object_t c = xpc_copy(i);
	CHECK(c != i && xpc_equal(c, i) && xpc_hash(c) == xpc_hash(i));
	CHECK(!xpc_equal(i, u));

	xpc_release(i); xpc_release(u); xpc_release(d); xpc_release(xu); xpc_release(c);
	xpc_release(b);   /* immortal: must be harmless */
}

static void
test_strings_data(void)
{
	xpc_object_t s = xpc_string_create_with_format("%s-%d", "finch", 7);
	CHECK(strcmp(xpc_string_get_string_ptr(s), "finch-7") == 0);
	CHECK(xpc_string_get_length(s) == 7);

	uint8_t bytes[300], out[10];
	for (int k = 0; k < 300; k++) bytes[k] = (uint8_t)k;
	xpc_object_t data = xpc_data_create(bytes, sizeof(bytes));
	CHECK(xpc_data_get_length(data) == 300);
	CHECK(memcmp(xpc_data_get_bytes_ptr(data), bytes, 300) == 0);
	CHECK(xpc_data_get_bytes(data, out, 295, 10) == 5 && out[0] == (uint8_t)295);
	xpc_release(s); xpc_release(data);
}

static void
test_containers(void)
{
	xpc_object_t dict = xpc_dictionary_create(NULL, NULL, 0);
	char key[32];

	/* Enough keys to switch from linear search to the hashed index. */
	for (int k = 0; k < 200; k++) {
		snprintf(key, sizeof(key), "key%d", k);
		xpc_dictionary_set_int64(dict, key, k);
	}
	CHECK(xpc_dictionary_get_count(dict) == 200);
	CHECK(xpc_dictionary_get_int64(dict, "key137") == 137);
	xpc_dictionary_set_int64(dict, "key137", -1);                    /* replace */
	CHECK(xpc_dictionary_get_int64(dict, "key137") == -1 && xpc_dictionary_get_count(dict) == 200);
	xpc_dictionary_set_value(dict, "key5", NULL);                    /* remove */
	CHECK(xpc_dictionary_get_value(dict, "key5") == NULL && xpc_dictionary_get_count(dict) == 199);
	CHECK(xpc_dictionary_get_int64(dict, "key199") == 199);

	__block int seen = 0, first = -1;
	xpc_dictionary_apply(dict, ^bool(const char *k, xpc_object_t v) {
		if (first < 0) first = (int)xpc_int64_get_value(v);   /* insertion order */
		seen++;
		return true;
	});
	CHECK(seen == 199 && first == 0);

	xpc_object_t arr = xpc_array_create(NULL, 0);
	xpc_array_set_string(arr, XPC_ARRAY_APPEND, "a");
	xpc_array_append_value(arr, dict);
	xpc_array_set_bool(arr, XPC_ARRAY_APPEND, true);
	CHECK(xpc_array_get_count(arr) == 3);
	CHECK(strcmp(xpc_array_get_string(arr, 0), "a") == 0);
	CHECK(xpc_array_get_dictionary(arr, 1) == dict);
	CHECK(xpc_array_get_bool(arr, 2));

	xpc_object_t nested = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_value(nested, "list", arr);
	xpc_dictionary_set_string(nested, "name", "finch");
	xpc_object_t copy = xpc_copy(nested);
	CHECK(copy != nested && xpc_equal(copy, nested));
	xpc_dictionary_set_string(copy, "name", "sparrow");
	CHECK(!xpc_equal(copy, nested));                                  /* deep copy */
	CHECK(strcmp(xpc_dictionary_get_string(nested, "name"), "finch") == 0);

	char *desc = xpc_copy_description(nested);
	CHECK(desc != NULL && strstr(desc, "\"name\" => <string:") != NULL);
	free(desc);

	xpc_release(copy); xpc_release(nested); xpc_release(arr); xpc_release(dict);
}

static void
test_errors(void)
{
	CHECK(xpc_get_type(XPC_ERROR_CONNECTION_INVALID) == XPC_TYPE_ERROR);
	CHECK(strcmp(xpc_dictionary_get_string(XPC_ERROR_CONNECTION_INVALID,
	    XPC_ERROR_KEY_DESCRIPTION), "Connection invalid") == 0);
	CHECK(strcmp(xpc_dictionary_get_string(XPC_ERROR_CONNECTION_INTERRUPTED,
	    XPC_ERROR_KEY_DESCRIPTION), "Connection interrupted") == 0);
	xpc_retain(XPC_ERROR_CONNECTION_INVALID);
	xpc_release(XPC_ERROR_CONNECTION_INVALID);
}

static void
test_fd(void)
{
	int fd = open("/dev/null", O_RDONLY);
	xpc_object_t x = xpc_fd_create(fd);
	close(fd);
	int d = xpc_fd_dup(x);
	CHECK(d >= 0 && fcntl(d, F_GETFD) >= 0);
	close(d);
	xpc_release(x);
}

/* Lots of create/release cycles: catches refcount and dispose bugs. */
static void
test_churn(void)
{
	for (int n = 0; n < 20000; n++) {
		xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
		xpc_dictionary_set_string(d, "s", "x");
		xpc_object_t a = xpc_array_create(&d, 1);
		xpc_release(d);
		xpc_release(xpc_copy(a));
		xpc_release(a);
	}
	CHECK(1);
}

int
main(void)
{
	test_types();
	test_scalars();
	test_strings_data();
	test_containers();
	test_errors();
	test_fd();
	test_churn();
	printf("%s: %d/%d checks passed\n", failures ? "FAILED" : "PASSED",
	    checks - failures, checks);
	return failures != 0;
}
