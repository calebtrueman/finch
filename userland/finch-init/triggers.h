/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * A job (jobs.c) and its launch-on-demand triggers (triggers.c).
 */

#ifndef FINCH_TRIGGERS_H
#define FINCH_TRIGGERS_H

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <spawn.h>
#include <stdbool.h>
#include <time.h>
#include <xpc/xpc.h>

#define DEFAULT_THROTTLE_SEC 10   /* launchd's ThrottleInterval default */

enum keepalive { KEEPALIVE_NO, KEEPALIVE_ALWAYS, KEEPALIVE_ON_SUCCESS, KEEPALIVE_ON_FAILURE };

/* One entry of a job's Sockets dictionary: its listening descriptors. */
struct job_socket {
	char *name;
	int *fds;
	size_t nfds;
	char **unlink_paths;        /* Unix sockets finch-init created (one per fd, or NULL) */
};

/* A domain of jobs: the system domain (LaunchDaemons) or a user's (LaunchAgents). */
struct job_domain {
	char name[32];              /* "system", "user/<uid>" */
	uid_t uid;                  /* 0 for the system domain */
	char *user, *home;          /* user domains */
	mach_port_t port;           /* its bootstrap port (bootstrapd) */
	struct job_domain *next;
};

struct job {
	struct job_domain *domain;
	char *label;
	char *program;
	char **argv;
	xpc_object_t env;           /* EnvironmentVariables dictionary, or NULL */
	char *cwd, *stdin_path, *stdout_path, *stderr_path, *user, *group;
	bool run_at_load;
	enum keepalive keepalive;
	int throttle;
	int nservices;
	pid_t pid;
	time_t started;
	bool start_pending;         /* a throttled start is scheduled */
	char *path;                 /* plist it came from */
	int runs;                   /* times started */
	int last_exit;              /* exit status, or -signal; INT_MIN if never exited */
	bool unloading;             /* removed; freed when the process exits */
	struct job *next;

	/* Triggers (triggers.c). */
	int start_interval;         /* StartInterval seconds, or 0 */
	xpc_object_t calendar;      /* StartCalendarInterval entries (an array), or NULL */
	char **watch_paths;         /* WatchPaths, NULL-terminated */
	char **queue_dirs;          /* QueueDirectories, NULL-terminated */
	struct job_socket *sockets;
	size_t nsockets;
	dispatch_source_t *sources; /* timers and vnode watchers */
	size_t nsources;
	dispatch_source_t *socket_sources;   /* one per socket fd; resumed while not running */
	size_t nsocket_sources;
	bool sockets_listening;
};

/* From jobs.c. */
extern dispatch_queue_t queue;
extern void (*log_fn)(const char *fmt, ...);
void job_start(struct job *j);
void job_free(struct job *j);

/* Parse the trigger keys of `plist` into `j`. False (logged) if they're invalid. */
bool triggers_parse(struct job *j, xpc_object_t plist);
/* The job was loaded: create its sockets, timers and watchers. */
void triggers_arm(struct job *j);
/* The job was unloaded: stop them, close its sockets. */
void triggers_disarm(struct job *j);
/* Free what triggers_parse allocated. */
void triggers_free(struct job *j);
/* Let the job's process inherit its sockets. */
void triggers_inherit(struct job *j, posix_spawn_file_actions_t *fa);
/* The job's process started / exited. */
void triggers_started(struct job *j);
void triggers_exited(struct job *j);
/* Add the job's triggers to a description ({sockets: {name: [fd]}, ...}). */
void triggers_describe(struct job *j, xpc_object_t d);

#endif
