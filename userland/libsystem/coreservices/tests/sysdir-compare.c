/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Differential test: every sysdir directory 0..300 under several domain
 * masks, Apple's libsystem_coreservices against Finch's.
 *   sysdir-compare <finch libsystem_coreservices.dylib>
 */
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sysdir.h>

typedef unsigned (*start_fn)(unsigned, unsigned);
typedef unsigned (*next_fn)(unsigned, char *);

static int
collect(start_fn start, next_fn next, unsigned dir, unsigned mask, char *out, size_t size)
{
	char path[PATH_MAX];
	int n = 0;
	out[0] = '\0';
	unsigned st = start(dir, mask);
	while (st != 0 && n < 64 && (st = next(st, path)) != 0) {
		strlcat(out, path, size);
		strlcat(out, "|", size);
		n++;
	}
	return n;
}

int
main(int argc, char **argv)
{
	void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!h) { fprintf(stderr, "%s\n", dlerror()); return 2; }
	start_fn fs = (start_fn)dlsym(h, "sysdir_start_search_path_enumeration");
	next_fn fn = (next_fn)dlsym(h, "sysdir_get_next_search_path_enumeration");
	unsigned masks[] = { 1, 2, 4, 8, 3, 5, 0xffff, 0x0fff };
	char a[16384], b[16384];
	int cases = 0, bad = 0, paths = 0;
	for (unsigned dir = 0; dir <= 300; dir++) {
		for (unsigned m = 0; m < sizeof(masks) / sizeof(masks[0]); m++) {
			paths += collect((start_fn)sysdir_start_search_path_enumeration,
			    (next_fn)sysdir_get_next_search_path_enumeration, dir, masks[m], a, sizeof(a));
			collect(fs, fn, dir, masks[m], b, sizeof(b));
			cases++;
			if (strcmp(a, b) != 0) {
				if (++bad <= 200) printf("DIFF dir=%u mask=0x%x\n  apple: %s\n  finch: %s\n", dir, masks[m], a, b);
			}
		}
	}
	printf("%s: %d (directory, mask) cases, %d paths, %d differ\n", bad ? "FAILED" : "PASSED", cases, paths, bad);
	return bad != 0;
}
