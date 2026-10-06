/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Wire-format tests (step X2) against Apple's serializations recorded by
 * tools/xpc-capture: decode Apple's bytes, re-encode, compare; then fuzz the
 * decoder with truncations and byte corruption.
 *
 *   serial-test tests/fixtures/apple-25E253.txt
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

void *xpc_make_serialization(xpc_object_t obj, size_t *len);
xpc_object_t xpc_create_from_serialization(const void *data, size_t len);

static int failures, checks;

#define CHECK(cond, name) do {                                        \
	checks++;                                                     \
	if (!(cond)) {                                                \
		failures++;                                           \
		printf("FAIL [%s] %s:%d: %s\n", name, __FILE__, __LINE__, #cond); \
	}                                                             \
} while (0)

static size_t
unhex(const char *hex, unsigned char *out, size_t cap)
{
	size_t n = 0;

	while (hex[0] && hex[1] && hex[0] != '\n' && n < cap) {
		unsigned v;
		sscanf(hex, "%2x", &v);
		out[n++] = (unsigned char)v;
		hex += 2;
	}
	return n;
}

/* Value checks for samples whose content we know. */
static void
check_value(const char *name, xpc_object_t d)
{
	xpc_object_t v = xpc_dictionary_get_value(d, "v");

	if (strcmp(name, "int64") == 0) CHECK(xpc_int64_get_value(v) == -42, name);
	if (strcmp(name, "uint64") == 0) CHECK(xpc_uint64_get_value(v) == 0xfedcba9876543210ULL, name);
	if (strcmp(name, "double") == 0) CHECK(xpc_double_get_value(v) == 2.5, name);
	if (strcmp(name, "date") == 0) CHECK(xpc_date_get_value(v) == 1759752000000000000LL, name);
	if (strcmp(name, "bool_true") == 0) CHECK(v == XPC_BOOL_TRUE, name);
	if (strcmp(name, "bool_false") == 0) CHECK(v == XPC_BOOL_FALSE, name);
	if (strcmp(name, "null") == 0) CHECK(xpc_get_type(v) == XPC_TYPE_NULL, name);
	if (strcmp(name, "string") == 0) CHECK(strcmp(xpc_string_get_string_ptr(v), "finch") == 0, name);
	if (strcmp(name, "string_empty") == 0) CHECK(xpc_string_get_length(v) == 0, name);
	if (strcmp(name, "data") == 0) CHECK(xpc_data_get_length(v) == 5 &&
	    memcmp(xpc_data_get_bytes_ptr(v), "\xde\xad\xbe\xef\x42", 5) == 0, name);
	if (strcmp(name, "uuid") == 0) CHECK(xpc_uuid_get_bytes(v)[0] == 0x01 &&
	    xpc_uuid_get_bytes(v)[15] == 0x10, name);
	if (strcmp(name, "array") == 0) CHECK(xpc_array_get_count(v) == 3 &&
	    xpc_array_get_int64(v, 0) == 1 && strcmp(xpc_array_get_string(v, 1), "two") == 0 &&
	    xpc_array_get_bool(v, 2), name);
	if (strcmp(name, "nested") == 0) CHECK(xpc_dictionary_get_uint64(
	    xpc_dictionary_get_dictionary(d, "inner"), "n") == 7 &&
	    strcmp(xpc_dictionary_get_string(d, "key_longer_than_4"), "x") == 0, name);
}

static void
fuzz(const char *name, const unsigned char *bytes, size_t len)
{
	unsigned char *copy = malloc(len);

	/* Every truncation must be rejected or parsed, never crash. */
	for (size_t n = 0; n < len; n++) {
		xpc_object_t o = xpc_create_from_serialization(bytes, n);
		if (o) xpc_release(o);
	}
	/* Random corruption of each byte position. */
	srand(1234);
	for (int round = 0; round < 5000; round++) {
		memcpy(copy, bytes, len);
		copy[(size_t)rand() % len] = (unsigned char)rand();
		copy[(size_t)rand() % len] = (unsigned char)rand();
		xpc_object_t o = xpc_create_from_serialization(copy, len);
		if (o) xpc_release(o);
	}
	free(copy);
	CHECK(1, name);   /* reaching here means no crash */
}

int
main(int argc, char **argv)
{
	char line[8192], name[64];
	unsigned char apple[4096];
	FILE *f = fopen(argc > 1 ? argv[1] : "tests/fixtures/apple-25E253.txt", "r");
	int samples = 0;

	if (f == NULL) {
		perror("fixtures");
		return 2;
	}
	while (fgets(line, sizeof(line), f)) {
		char *hex;
		if (line[0] == '#' || sscanf(line, "%63s", name) != 1) continue;
		hex = strchr(line, ' ');
		if (hex == NULL) continue;
		size_t alen = unhex(hex + 1, apple, sizeof(apple));
		samples++;

		xpc_object_t decoded = xpc_create_from_serialization(apple, alen);
		CHECK(decoded != NULL, name);
		if (decoded == NULL) continue;
		check_value(name, decoded);

		size_t olen = 0;
		unsigned char *ours = xpc_make_serialization(decoded, &olen);
		CHECK(ours != NULL, name);
		if (strcmp(name, "nested") == 0) {
			/* Apple orders multi-key dictionaries by hash; compare meaning. */
			xpc_object_t again = xpc_create_from_serialization(ours, olen);
			CHECK(again != NULL && xpc_equal(again, decoded), name);
			if (again) xpc_release(again);
		} else {
			CHECK(olen == alen && memcmp(ours, apple, alen) == 0, name);
		}
		free(ours);
		xpc_release(decoded);
		fuzz(name, apple, alen);
	}
	fclose(f);
	printf("%s: %d/%d checks passed over %d Apple samples\n",
	    failures ? "FAILED" : "PASSED", checks - failures, checks, samples);
	return failures != 0;
}
