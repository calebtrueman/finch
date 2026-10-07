/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-init's job manager: loads launchd job plists and runs the jobs
 * (docs/design/SERVICES.md). The plist format is launchd's, so existing
 * LaunchDaemons work unchanged. Supported keys:
 *
 *   Label, Program, ProgramArguments, MachServices, RunAtLoad, KeepAlive
 *   (bool, or a dictionary with SuccessfulExit), EnvironmentVariables,
 *   WorkingDirectory, StandardInPath, StandardOutPath, StandardErrorPath,
 *   UserName, GroupName, ThrottleInterval, Disabled.
 *
 * Unknown keys are ignored. Everything runs on finch-init's serial queue.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "bootstrapd.h"
#include "jobs.h"

xpc_object_t xpc_create_from_plist(const void *data, size_t length);

/* posix_spawn extensions (<spawn_private.h>): run the child as another user. */
int posix_spawnattr_set_uid_np(const posix_spawnattr_t *attr, uid_t uid);
int posix_spawnattr_set_gid_np(const posix_spawnattr_t *attr, gid_t gid);
int posix_spawnattr_set_groups_np(const posix_spawnattr_t *attr, int ngroups, gid_t *gidarray, uid_t gmuid);

#define DEFAULT_THROTTLE_SEC 10   /* launchd's ThrottleInterval default */

enum keepalive { KEEPALIVE_NO, KEEPALIVE_ALWAYS, KEEPALIVE_ON_SUCCESS, KEEPALIVE_ON_FAILURE };

struct job {
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
	struct job *next;
};

static struct job *jobs;
static dispatch_queue_t queue;
static void (*log_fn)(const char *fmt, ...);

static char *
dup_string(xpc_object_t dict, const char *key)
{
	const char *s = xpc_dictionary_get_string(dict, key);
	return s ? strdup(s) : NULL;
}

static void
job_free(struct job *j)
{
	free(j->label);
	free(j->program);
	for (char **a = j->argv; a && *a; a++) free(*a);
	free(j->argv);
	if (j->env) xpc_release(j->env);
	free(j->cwd); free(j->stdin_path); free(j->stdout_path); free(j->stderr_path);
	free(j->user); free(j->group);
	free(j);
}

static struct job *
job_from_plist(xpc_object_t plist, const char *path)
{
	struct job *j;
	xpc_object_t args, keepalive;

	if (xpc_get_type(plist) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_string(plist, "Label") == NULL) {
		log_fn("%s: not a job (no Label)", path);
		return NULL;
	}
	if (xpc_dictionary_get_bool(plist, "Disabled")) {
		return NULL;
	}
	j = calloc(1, sizeof(*j));
	j->label = dup_string(plist, "Label");
	j->program = dup_string(plist, "Program");
	args = xpc_dictionary_get_value(plist, "ProgramArguments");
	if (args != NULL && xpc_get_type(args) == XPC_TYPE_ARRAY && xpc_array_get_count(args) > 0) {
		size_t n = xpc_array_get_count(args);
		j->argv = calloc(n + 1, sizeof(char *));
		for (size_t i = 0; i < n; i++) {
			const char *a = xpc_array_get_string(args, i);
			j->argv[i] = strdup(a ? a : "");
		}
	}
	if (j->program == NULL && j->argv != NULL) {
		j->program = strdup(j->argv[0]);
	}
	if (j->program == NULL) {
		log_fn("%s: job %s has no Program or ProgramArguments", path, j->label);
		job_free(j);
		return NULL;
	}
	if (j->argv == NULL) {
		j->argv = calloc(2, sizeof(char *));
		j->argv[0] = strdup(j->program);
	}
	j->env = xpc_dictionary_get_value(plist, "EnvironmentVariables");
	if (j->env != NULL && xpc_get_type(j->env) == XPC_TYPE_DICTIONARY) {
		xpc_retain(j->env);
	} else {
		j->env = NULL;
	}
	j->cwd = dup_string(plist, "WorkingDirectory");
	j->stdin_path = dup_string(plist, "StandardInPath");
	j->stdout_path = dup_string(plist, "StandardOutPath");
	j->stderr_path = dup_string(plist, "StandardErrorPath");
	j->user = dup_string(plist, "UserName");
	j->group = dup_string(plist, "GroupName");
	j->run_at_load = xpc_dictionary_get_bool(plist, "RunAtLoad");
	j->throttle = DEFAULT_THROTTLE_SEC;
	if (xpc_dictionary_get_value(plist, "ThrottleInterval") != NULL) {
		j->throttle = (int)xpc_dictionary_get_int64(plist, "ThrottleInterval");
	}
	keepalive = xpc_dictionary_get_value(plist, "KeepAlive");
	if (keepalive != NULL && xpc_get_type(keepalive) == XPC_TYPE_BOOL) {
		j->keepalive = xpc_bool_get_value(keepalive) ? KEEPALIVE_ALWAYS : KEEPALIVE_NO;
	} else if (keepalive != NULL && xpc_get_type(keepalive) == XPC_TYPE_DICTIONARY) {
		xpc_object_t se = xpc_dictionary_get_value(keepalive, "SuccessfulExit");
		if (se != NULL && xpc_get_type(se) == XPC_TYPE_BOOL) {
			j->keepalive = xpc_bool_get_value(se) ? KEEPALIVE_ON_SUCCESS : KEEPALIVE_ON_FAILURE;
		} else {
			/* Other conditions (PathState, NetworkState, ...) aren't supported: keep it alive. */
			j->keepalive = KEEPALIVE_ALWAYS;
		}
	}
	return j;
}

static struct job *
job_find_pid(pid_t pid)
{
	for (struct job *j = jobs; j != NULL; j = j->next) {
		if (j->pid == pid) return j;
	}
	return NULL;
}

static struct job *
job_find_label(const char *label)
{
	for (struct job *j = jobs; j != NULL; j = j->next) {
		if (strcmp(j->label, label) == 0) return j;
	}
	return NULL;
}

#pragma mark - Spawning

static int
add_open(posix_spawn_file_actions_t *fa, int fd, const char *path, int flags)
{
	return posix_spawn_file_actions_addopen(fa, fd, path, flags, 0644);
}

static void job_start(struct job *j);

static void
job_spawn(struct job *j)
{
	posix_spawn_file_actions_t fa;
	posix_spawnattr_t attr;
	sigset_t none, all;
	extern char **environ;
	char **envp;
	size_t n = 0, i = 0;
	struct passwd *pw = NULL;
	struct group *gr = NULL;
	int rc;

	if (j->user != NULL && (pw = getpwnam(j->user)) == NULL) {
		log_fn("%s: unknown UserName %s; not starting", j->label, j->user);
		return;
	}
	if (j->group != NULL && (gr = getgrnam(j->group)) == NULL) {
		log_fn("%s: unknown GroupName %s; not starting", j->label, j->group);
		return;
	}

	/* Environment: finch-init's, plus XPC_SERVICE_NAME (as launchd sets it), plus the job's. */
	for (char **e = environ; *e; e++) n++;
	n += 2 + (j->env ? xpc_dictionary_get_count(j->env) : 0);
	if (pw != NULL) n += 3;
	envp = calloc(n + 1, sizeof(char *));
	for (char **e = environ; *e; e++) {
		if (strncmp(*e, "XPC_SERVICE_NAME=", 17) != 0) envp[i++] = strdup(*e);
	}
	asprintf(&envp[i++], "XPC_SERVICE_NAME=%s", j->label);
	if (pw != NULL) {
		asprintf(&envp[i++], "USER=%s", pw->pw_name);
		asprintf(&envp[i++], "LOGNAME=%s", pw->pw_name);
		asprintf(&envp[i++], "HOME=%s", pw->pw_dir);
	}
	if (j->env != NULL) {
		__block size_t k = i;
		xpc_dictionary_apply(j->env, ^bool(const char *key, xpc_object_t value) {
			if (xpc_get_type(value) == XPC_TYPE_STRING) {
				asprintf(&envp[k++], "%s=%s", key, xpc_string_get_string_ptr(value));
			}
			return true;
		});
		i = k;
	}
	envp[i] = NULL;

	posix_spawn_file_actions_init(&fa);
	add_open(&fa, STDIN_FILENO, j->stdin_path ? j->stdin_path : "/dev/null", O_RDONLY);
	add_open(&fa, STDOUT_FILENO, j->stdout_path ? j->stdout_path : "/dev/null",
	    O_WRONLY | O_CREAT | O_APPEND);
	add_open(&fa, STDERR_FILENO, j->stderr_path ? j->stderr_path : "/dev/null",
	    O_WRONLY | O_CREAT | O_APPEND);
	if (j->cwd != NULL) {
		posix_spawn_file_actions_addchdir(&fa, j->cwd);
	}
	posix_spawnattr_init(&attr);
	sigemptyset(&none);
	sigfillset(&all);
	posix_spawnattr_setsigmask(&attr, &none);
	posix_spawnattr_setsigdefault(&attr, &all);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF |
	    POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);
	if (gr != NULL || pw != NULL) {
		gid_t gid = gr ? gr->gr_gid : pw->pw_gid;
		gid_t groups[NGROUPS_MAX];
		int ngroups = NGROUPS_MAX;

		posix_spawnattr_set_gid_np(&attr, gid);
		/* Supplementary groups, as initgroups(3) would set them. */
		if (pw == NULL || getgrouplist(pw->pw_name, (int)gid, (int *)groups, &ngroups) != 0) {
			groups[0] = gid;
			ngroups = 1;
		}
		posix_spawnattr_set_groups_np(&attr, ngroups, groups, pw ? pw->pw_uid : 0);
	}
	if (pw != NULL) {
		posix_spawnattr_set_uid_np(&attr, pw->pw_uid);
	}

	rc = posix_spawn(&j->pid, j->program, &fa, &attr, j->argv, envp);
	posix_spawn_file_actions_destroy(&fa);
	posix_spawnattr_destroy(&attr);
	for (char **e = envp; *e; e++) free(*e);
	free(envp);
	if (rc != 0) {
		j->pid = 0;
		log_fn("%s: spawning %s failed: %s", j->label, j->program, strerror(rc));
		return;
	}
	j->started = time(NULL);
}

/* Start now, or after the throttle interval if it last started too recently. */
static void
job_start(struct job *j)
{
	time_t now = time(NULL);
	time_t ready = j->started + j->throttle;

	if (j->pid > 0 || j->start_pending) {
		return;
	}
	if (j->started != 0 && now < ready) {
		j->start_pending = true;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ready - now) * NSEC_PER_SEC), queue, ^{
			j->start_pending = false;
			job_start(j);
		});
		return;
	}
	job_spawn(j);
}

#pragma mark - Hooks from the bootstrap server

static void
demand_hook(void *owner)
{
	job_start(owner);
}

static bool
may_check_in_hook(void *owner, pid_t pid)
{
	return pid > 0 && ((struct job *)owner)->pid == pid;
}

const struct bootstrapd_hooks jobs_bootstrap_hooks = {
	.demand = demand_hook,
	.may_check_in = may_check_in_hook,
};

#pragma mark - Loading

static void
job_load_file(const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	struct stat st;
	xpc_object_t plist = NULL, services;
	struct job *j;
	char *buf;

	if (fd < 0) return;
	if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size < (1 << 20) &&
	    (buf = malloc((size_t)st.st_size)) != NULL) {
		if (read(fd, buf, (size_t)st.st_size) == st.st_size) {
			plist = xpc_create_from_plist(buf, (size_t)st.st_size);
		}
		free(buf);
	}
	close(fd);
	if (plist == NULL) {
		log_fn("%s: not a property list", path);
		return;
	}
	j = job_from_plist(plist, path);
	if (j != NULL && job_find_label(j->label) != NULL) {
		log_fn("%s: job %s is already loaded", path, j->label);
		job_free(j);
		j = NULL;
	}
	if (j != NULL) {
		services = xpc_dictionary_get_value(plist, "MachServices");
		if (services != NULL && xpc_get_type(services) == XPC_TYPE_DICTIONARY) {
			xpc_dictionary_apply(services, ^bool(const char *name, xpc_object_t value) {
				(void)value;   /* ResetAtClose, HideUntilCheckIn: not supported yet */
				int err = bootstrapd_declare(name, j);
				if (err == 0) {
					j->nservices++;
				} else {
					log_fn("%s: can't declare %s: %s", j->label, name, strerror(err));
				}
				return true;
			});
		}
		j->next = jobs;
		jobs = j;
	}
	xpc_release(plist);
}

static int
plist_name(const struct dirent *d)
{
	size_t n = strlen(d->d_name);
	return d->d_name[0] != '.' && n > 6 && strcmp(d->d_name + n - 6, ".plist") == 0;
}

void
jobs_init(dispatch_queue_t q, void (*log)(const char *fmt, ...))
{
	queue = q;
	log_fn = log;
}

int
jobs_load_dir(const char *dir)
{
	struct dirent **names;
	int n = scandir(dir, &names, plist_name, alphasort), loaded = 0;
	char path[PATH_MAX];

	for (int i = 0; i < n; i++) {
		struct job *before = jobs;
		snprintf(path, sizeof(path), "%s/%s", dir, names[i]->d_name);
		job_load_file(path);
		loaded += jobs != before;
		free(names[i]);
	}
	if (n > 0) free(names);
	return loaded;
}

void
jobs_start_all(void)
{
	for (struct job *j = jobs; j != NULL; j = j->next) {
		if (j->run_at_load || j->keepalive == KEEPALIVE_ALWAYS || j->keepalive == KEEPALIVE_ON_FAILURE) {
			job_start(j);
		}
	}
}

bool
jobs_child_exited(pid_t pid, int status)
{
	struct job *j = job_find_pid(pid);
	bool success, restart;

	if (j == NULL) {
		return false;
	}
	j->pid = 0;
	success = WIFEXITED(status) && WEXITSTATUS(status) == 0;
	if (WIFSIGNALED(status) && WTERMSIG(status) != SIGTERM && WTERMSIG(status) != SIGKILL) {
		log_fn("%s: killed by signal %d", j->label, WTERMSIG(status));
	} else if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
		log_fn("%s: exited with status %d", j->label, WEXITSTATUS(status));
	}
	restart = j->keepalive == KEEPALIVE_ALWAYS ||
	    (j->keepalive == KEEPALIVE_ON_SUCCESS && success) ||
	    (j->keepalive == KEEPALIVE_ON_FAILURE && !success);
	if (restart) {
		job_start(j);
	}
	/* Its services' receive rights come back via port-destroyed; watch them again. */
	bootstrapd_rearm(j);
	return true;
}
