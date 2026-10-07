/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-launch-bench: where does process launch time go? Spawns itself N
 * times; each child reports how long after the kernel created it main() ran
 * (exec + dyld + library initializers), and the parent measures each spawn
 * to reap (adds teardown).
 *
 *   finch-launch-bench [count]
 */

#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static double
now_ms(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1e3 + tv.tv_usec / 1e3;
}

static double
start_ms(pid_t pid)
{
	struct kinfo_proc kp;
	size_t len = sizeof(kp);
	int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };

	if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0) return 0;
	return kp.kp_proc.p_starttime.tv_sec * 1e3 + kp.kp_proc.p_starttime.tv_usec / 1e3;
}

int
main(int argc, char **argv)
{
	if (argc > 1 && strcmp(argv[1], "--child") == 0) {
		printf("%.1f %u\n", now_ms() - start_ms(getpid()), _dyld_image_count());
		return 0;
	}
	int n = argc > 1 ? atoi(argv[1]) : 5;
	char self[1024];
	uint32_t size = sizeof(self);
	_NSGetExecutablePath(self, &size);
	double to_main = 0, total = 0;
	unsigned images = 0;
	for (int i = 0; i < n; i++) {
		int fds[2];
		pipe(fds);
		posix_spawn_file_actions_t fa;
		posix_spawn_file_actions_init(&fa);
		posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
		char *args[] = { self, "--child", NULL };
		pid_t pid;
		double t0 = now_ms();
		posix_spawn(&pid, self, &fa, NULL, args, environ);
		close(fds[1]);
		char buf[64] = { 0 };
		read(fds[0], buf, sizeof(buf) - 1);
		close(fds[0]);
		int st;
		waitpid(pid, &st, 0);
		double t = now_ms() - t0, m = atof(buf);
		images = (unsigned)atoi(strchr(buf, ' ') ? strchr(buf, ' ') + 1 : "0");
		to_main += m;
		total += t;
		posix_spawn_file_actions_destroy(&fa);
	}
	printf("%d launches, %u images loaded: avg %.0f ms to main(), %.0f ms spawn-to-reap\n",
	    n, images, to_main / n, total / n);
	return 0;
}
