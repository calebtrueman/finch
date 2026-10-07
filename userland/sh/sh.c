/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * /bin/sh: the macOS shell "variant" launcher. /private/var/select/sh names
 * the shell that provides /bin/sh (bash, dash or zsh; bash when the link is
 * absent), and this program execs it with the caller's argv unchanged, so
 * the shell sees argv[0] "sh" and runs in its POSIX mode. Messages match
 * Apple's launcher. One deliberate difference: when not even /bin/bash can be
 * executed, this exits 126 instead of reporting success.
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SELECT_PATH "/private/var/select/sh"
#define DEFAULT_SHELL "/bin/bash"

static const char *const variants[] = { "/bin/bash", "/bin/dash", "/bin/zsh" };

int
main(int argc, char *argv[])
{
	char target[1024];
	const char *shell = DEFAULT_SHELL;
	ssize_t n;
	int err;

	(void)argc;
	n = readlink(SELECT_PATH, target, sizeof(target) - 1);
	if (n >= 0) {
		target[n] = '\0';
		for (size_t i = 0; i < sizeof(variants) / sizeof(variants[0]); i++) {
			if (strcmp(variants[i], target) == 0) {
				shell = target;
			}
		}
		if (shell != target) {
			fprintf(stderr, "Unrecognized shell referenced in %s: %s\n", SELECT_PATH, target);
		}
	} else if (errno != ENOENT) {
		fprintf(stderr, "Error opening %s: %s\n", SELECT_PATH, strerror(errno));
	}

	execv(shell, argv);
	err = errno;
	fprintf(stderr, "Failed to exec %s as variant for /bin/sh (%d: %s).", shell, err,
	    strerror(err));
	if (strcmp(shell, DEFAULT_SHELL) != 0) {
		fprintf(stderr, " Falling back to %s.\n", DEFAULT_SHELL);
		execv(DEFAULT_SHELL, argv);
		err = errno;
		fprintf(stderr, "Failed to exec %s as variant for /bin/sh (%d: %s).\n", DEFAULT_SHELL,
		    err, strerror(err));
	} else {
		fputc('\n', stderr);
	}
	return 126;
}
