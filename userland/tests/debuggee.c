/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-debuggee: a process other tools may inspect (signed with
 * get-task-allow), for testing gcore, lskq and the like in the VM. Sleeps for
 * the given number of seconds (default 60) with a known marker in memory.
 *
 *   finch-debuggee [seconds] &
 *   gcore -o /tmp/core $!
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

volatile const char marker[] = "finch-debuggee marker";

int
main(int argc, char **argv)
{
	unsigned seconds = argc > 1 ? (unsigned)atoi(argv[1]) : 60;

	printf("finch-debuggee: pid %d, %s\n", getpid(), (const char *)marker);
	fflush(stdout);
	sleep(seconds);
	return 0;
}
