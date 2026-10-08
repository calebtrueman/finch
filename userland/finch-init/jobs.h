/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#ifndef FINCH_JOBS_H
#define FINCH_JOBS_H

#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <sys/types.h>

#include "bootstrapd.h"

/* Start the bootstrap server (bootstrapd.c) with the job manager's hooks. All
 * other job functions run on `q`, the server's queue. Returns the system
 * domain's bootstrap port, or MACH_PORT_NULL. Call it off the queue. */
mach_port_t jobs_init(dispatch_queue_t q, void (*log)(const char *fmt, ...));

/* Load every *.plist in `dir` into the system domain and declare its
 * MachServices. Returns the number of jobs loaded. */
int jobs_load_dir(const char *dir);

/* Start RunAtLoad and KeepAlive jobs. */
void jobs_start_all(void);

/* Stop every job and process, sync, and reboot(2) with `howto` (RB_*).
 * Asynchronous: runs on the queue. Requested by reboot3() via launchctl's
 * control channel. */
void jobs_shutdown(int howto);
bool jobs_shutting_down(void);

/* A child exited. Returns false if it wasn't a job. */
bool jobs_child_exited(pid_t pid, int status);

#endif
