/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Differential test of xpc_create_from_plist against Apple's: both parse the
 * same files; Apple's result is serialized with Apple's libxpc and decoded by
 * Finch's, then compared with xpc_equal. Then fuzzes Finch's parser with
 * truncations and corruptions.
 *
 *   plist-test <file>...
 */

#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

xpc_object_t xpc_create_from_plist(const void *data, size_t length);
xpc_object_t xpc_create_from_serialization(const void *data, size_t len);

static struct {
	xpc_object_t (*create_from_plist)(const void *, size_t);
	void *(*make_serialization)(xpc_object_t, size_t *);
	xpc_type_t (*get_type)(xpc_object_t);
	xpc_type_t type_dictionary;
	void (*release)(xpc_object_t);
} apple;

int
main(int argc, char **argv)
{
	void *h = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY | RTLD_NOLOAD);
	apple.create_from_plist = dlsym(h, "xpc_create_from_plist");
	apple.make_serialization = dlsym(h, "xpc_make_serialization");
	apple.get_type = dlsym(h, "xpc_get_type");
	apple.release = dlsym(h, "xpc_release");
	apple.type_dictionary = dlsym(h, "_xpc_type_dictionary");

	int files = 0, compared = 0, equal = 0, both_null = 0, mismatched = 0, fuzzed = 0;
	srand(42);
	for (int i = 1; i < argc; i++) {
		int fd = open(argv[i], O_RDONLY);
		struct stat st;
		if (fd < 0 || fstat(fd, &st) != 0 || st.st_size < 8 || st.st_size > 4 << 20) {
			if (fd >= 0) close(fd);
			continue;
		}
		size_t len = (size_t)st.st_size;
		uint8_t *data = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
		close(fd);
		if (data == MAP_FAILED) continue;
		files++;

		xpc_object_t ours = xpc_create_from_plist(data, len);
		xpc_object_t theirs = apple.create_from_plist(data, len);
		if (ours == NULL && theirs == NULL) {
			both_null++;
		} else if (theirs != NULL && apple.get_type(theirs) == apple.type_dictionary) {
			size_t slen = 0;
			void *ser = apple.make_serialization(theirs, &slen);
			xpc_object_t bridged = ser ? xpc_create_from_serialization(ser, slen) : NULL;
			if (bridged != NULL) {
				compared++;
				if (ours != NULL && xpc_equal(ours, bridged)) {
					equal++;
				} else {
					mismatched++;
					printf("MISMATCH %s (ours=%s)\n", argv[i], ours ? "object" : "NULL");
				}
				xpc_release(bridged);
			}
			free(ser);
		}
		if (ours) xpc_release(ours);
		if (theirs) apple.release(theirs);

		/* Fuzz: truncations at a few points, and random corruption. */
		uint8_t *copy = malloc(len);
		for (int round = 0; round < 200; round++) {
			size_t n = len;
			memcpy(copy, data, len);
			if (round < 20) {
				n = (size_t)rand() % len;
			} else {
				for (int k = 0; k < 3; k++) copy[(size_t)rand() % len] = (uint8_t)rand();
			}
			xpc_object_t o = xpc_create_from_plist(copy, n);
			if (o) xpc_release(o);
			fuzzed++;
		}
		free(copy);
		munmap(data, len);
	}
	printf("%s: %d files, %d compared with Apple (%d equal, %d mismatched), "
	    "%d rejected by both, %d fuzz inputs survived\n",
	    mismatched ? "FAILED" : "PASSED", files, compared, equal, mismatched, both_null, fuzzed);
	return mismatched != 0;
}
