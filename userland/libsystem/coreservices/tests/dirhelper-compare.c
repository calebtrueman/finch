/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The per-user /var/folders paths: Apple's __user_local_dirname and
 * _dirhelper (via confstr) against Finch's, for this user.
 *   dirhelper-compare <finch libsystem_coreservices.dylib>
 */
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

char *__user_local_dirname(uid_t uid, int which, char *path, size_t pathlen);
char *_dirhelper(int which, char *path, size_t pathlen);

int
main(int argc, char **argv)
{
	void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!h) { fprintf(stderr, "%s\n", dlerror()); return 2; }
	char *(*ours)(uid_t, int, char *, size_t) = dlsym(h, "__user_local_dirname");
	char *(*ours_dh)(int, char *, size_t) = dlsym(h, "_dirhelper");
	int bad = 0;
	for (int which = 0; which <= 2; which++) {
		char a[PATH_MAX] = "", b[PATH_MAX] = "", c[PATH_MAX] = "", d[PATH_MAX] = "";
		__user_local_dirname(getuid(), which, a, sizeof(a));
		ours(getuid(), which, b, sizeof(b));
		_dirhelper(which, c, sizeof(c));
		ours_dh(which, d, sizeof(d));
		int ok = strcmp(a, b) == 0 && strcmp(c, d) == 0;
		bad += !ok;
		printf("%s which=%d %s %s\n", ok ? "same" : "DIFF", which, ok ? b : a, ok ? d : b);
	}
	printf("%s\n", bad ? "FAILED" : "PASSED: per-user directories match");
	return bad != 0;
}
