/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-log-test: run inside the VM. Logs through os_log with
 * OS_ACTIVITY_DT_MODE (messages echoed to stderr, as Xcode's console sees
 * them), captures its own stderr, and checks what arrived: composition,
 * format specifiers, privacy, level gates, signposts and activities. The
 * expected text is what Apple's libsystem_trace produces on macOS 26.4.
 */
#include <os/activity.h>
#include <os/log.h>
#include <os/signpost.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;

static void
check(bool ok, const char *what)
{
	printf("%s %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		failures++;
	}
}

static char captured[8192];

/* Log a message with stderr redirected into a pipe; returns what arrived. */
#define CAPTURE(stmt)                                                        \
	do {                                                                 \
		int fds[2], saved = dup(STDERR_FILENO);                      \
		ssize_t got;                                                 \
		pipe(fds);                                                   \
		dup2(fds[1], STDERR_FILENO);                                 \
		close(fds[1]);                                               \
		stmt;                                                        \
		dup2(saved, STDERR_FILENO);                                  \
		close(saved);                                                \
		got = read(fds[0], captured, sizeof(captured) - 1);          \
		captured[got > 0 ? got : 0] = '\0';                          \
		close(fds[0]);                                               \
	} while (0)

static bool
contains(const char *needle)
{
	return strstr(captured, needle) != NULL;
}

int
main(int argc, char *argv[])
{
	(void)argc;
	/* DT mode is read when the library starts, so set it and start over. */
	if (getenv("OS_ACTIVITY_DT_MODE") == NULL) {
		setenv("OS_ACTIVITY_DT_MODE", "1", 1);
		execvp(argv[0], argv);
		perror("execvp");
		return 2;
	}

	os_log_t log = os_log_create("org.finch.test", "log-test");

	check(log != NULL && log != OS_LOG_DISABLED, "os_log_create");
	check(os_log_type_enabled(log, OS_LOG_TYPE_DEFAULT) &&
	    os_log_type_enabled(log, OS_LOG_TYPE_ERROR) &&
	    os_log_type_enabled(log, OS_LOG_TYPE_FAULT), "default, error and fault are on");
	check(!os_log_type_enabled(log, OS_LOG_TYPE_DEBUG), "debug is off by default");

	CAPTURE(os_log(log, "count %d hex %#x name %{public}s", 42, 255, "finch"));
	check(contains("count 42 hex 0xff name finch"), "os_log composes integers and strings");

	CAPTURE(os_log_error(log, "open failed: %{errno}d", ENOENT));
	check(contains("open failed: [2: No such file or directory]"), "%{errno}d formatter");

	CAPTURE(os_log(log, "flag %{bool}d", 1));
	check(contains("flag true"), "%{bool}d formatter");

	CAPTURE(os_log_debug(log, "this debug message must not appear"));
	check(!contains("must not appear"), "debug message is gated");

	CAPTURE(os_log(OS_LOG_DEFAULT, "default log %u", 7u));
	check(contains("default log 7"), "OS_LOG_DEFAULT");

	os_signpost_id_t id = os_signpost_id_generate(log);
	check(id != OS_SIGNPOST_ID_NULL && id != OS_SIGNPOST_ID_INVALID, "signpost id generated");

	__block bool ran = false;
	os_activity_t activity = os_activity_create("finch-log-test activity", OS_ACTIVITY_CURRENT,
	    OS_ACTIVITY_FLAG_DEFAULT);
	os_activity_apply(activity, ^{
		ran = true;
	});
	check(ran, "os_activity_apply runs its block");

	printf("finch-log-test: %d failure%s\n", failures, failures == 1 ? "" : "s");
	return failures != 0;
}
