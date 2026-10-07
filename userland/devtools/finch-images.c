/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-images: print every image loaded in this process (what a minimal
 * libSystem program pulls in), one path per line, optionally after dlopen()ing
 * extra libraries given as arguments.
 */

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (dlopen(argv[i], RTLD_NOW) == NULL) {
			fprintf(stderr, "finch-images: %s\n", dlerror());
		}
	}
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		printf("%s\n", _dyld_get_image_name(i));
	}
	return 0;
}
