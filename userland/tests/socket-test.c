/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-socket-test: launchd socket activation under finch-init.
 *
 *   finch-socket-test daemon        the job (org.finch.test.socket): takes its
 *                                   "Listeners" sockets with launch_activate_socket,
 *                                   checks they match launch_msg's check-in, and
 *                                   answers one connection with "hello <pid>"
 *   finch-socket-test connect PATH  the client: connects (starting the job on
 *                                   demand) and prints what it reads
 */
#include <execinfo.h>
#include <launch.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* A crash in the job would otherwise only show as "killed by signal" in the VM. */
static void
crashed(int sig)
{
	void *frames[32];
	int n = backtrace(frames, 32);
	dprintf(STDERR_FILENO, "finch-socket-test: signal %d\n", sig);
	backtrace_symbols_fd(frames, n, STDERR_FILENO);
	_exit(128 + sig);
}

static int
daemon_main(void)
{
	signal(SIGSEGV, crashed);
	signal(SIGBUS, crashed);
	int *fds = NULL;
	size_t count = 0;
	int err = launch_activate_socket("Listeners", &fds, &count);

	if (err != 0 || count == 0) {
		fprintf(stderr, "launch_activate_socket: %s\n", strerror(err));
		return 1;
	}
	launch_data_t req = launch_data_new_string(LAUNCH_KEY_CHECKIN);
	launch_data_t job = launch_msg(req);
	launch_data_free(req);
	launch_data_t socks = job ? launch_data_dict_lookup(job, LAUNCH_JOBKEY_SOCKETS) : NULL;
	launch_data_t list = socks ? launch_data_dict_lookup(socks, "Listeners") : NULL;
	if (list == NULL || launch_data_array_get_count(list) != count ||
	    launch_data_get_fd(launch_data_array_get_index(list, 0)) != fds[0]) {
		fprintf(stderr, "check-in doesn't match launch_activate_socket\n");
		return 1;
	}
	launch_data_free(job);

	int c = accept(fds[0], NULL, NULL);
	if (c < 0) {
		perror("accept");
		return 1;
	}
	char msg[64];
	int n = snprintf(msg, sizeof(msg), "hello %d\n", getpid());
	write(c, msg, (size_t)n);
	close(c);
	return 0;
}

static int
connect_main(const char *path)
{
	struct sockaddr_un sun = { .sun_family = AF_UNIX };
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	char buf[64];
	ssize_t n;

	strlcpy(sun.sun_path, path, sizeof(sun.sun_path));
	if (connect(fd, (struct sockaddr *)&sun, sizeof(sun)) != 0) {
		perror("connect");
		return 1;
	}
	n = read(fd, buf, sizeof(buf) - 1);
	if (n <= 0) {
		fprintf(stderr, "finch-socket-test: no reply\n");
		return 1;
	}
	buf[n] = 0;
	printf("finch-socket-test: %s", buf);
	return strncmp(buf, "hello ", 6) != 0;
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "daemon") == 0) return daemon_main();
	if (argc == 3 && strcmp(argv[1], "connect") == 0) return connect_main(argv[2]);
	fprintf(stderr, "usage: finch-socket-test daemon | connect PATH\n");
	return 2;
}
