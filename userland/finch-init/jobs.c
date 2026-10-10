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
 *   UserName, GroupName, ThrottleInterval, Disabled, and the launch-on-demand
 *   triggers StartInterval, StartCalendarInterval, WatchPaths,
 *   QueueDirectories and Sockets (triggers.c), and for agents
 *   LimitLoadToSessionType.
 *
 * Jobs live in domains: the system domain (LaunchDaemons, created at boot)
 * and a domain per user (LaunchAgents, created on first request: pam_launchd's
 * bootstrap_look_up_per_user, `launchctl asuser`, or `launchctl bootstrap
 * user/<uid>`). An agent runs as its domain's user with the domain's bootstrap
 * port, so it and its children find the user's services, then the system's.
 *
 * Unknown keys are ignored. Everything runs on finch-init's serial queue.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "bootstrapd.h"
#include "jobs.h"
#include "triggers.h"

xpc_object_t xpc_create_from_plist(const void *data, size_t length);
xpc_object_t xpc_mach_send_create(mach_port_t port);

/* posix_spawn extensions (<spawn_private.h>): run the child as another user. */
int posix_spawnattr_set_uid_np(const posix_spawnattr_t *attr, uid_t uid);
int posix_spawnattr_set_gid_np(const posix_spawnattr_t *attr, gid_t gid);
int posix_spawnattr_set_groups_np(const posix_spawnattr_t *attr, int ngroups, gid_t *gidarray, uid_t gmuid);

/* Where a user domain's agents come from, in order; then ~/Library/LaunchAgents. */
static const char *const agent_dirs[] = {
	"/System/Library/Finch/LaunchAgents",   /* Finch's own agents */
	"/Library/LaunchAgents",                /* third-party agents, as on macOS */
};

static struct job_domain system_domain = { .name = "system" };
static struct job_domain *user_domains;
static struct job *jobs;
dispatch_queue_t queue;
static bool shutting_down;
void (*log_fn)(const char *fmt, ...);

static char *
dup_string(xpc_object_t dict, const char *key)
{
	const char *s = xpc_dictionary_get_string(dict, key);
	return s ? strdup(s) : NULL;
}

void
job_free(struct job *j)
{
	triggers_free(j);
	free(j->label);
	free(j->program);
	for (char **a = j->argv; a && *a; a++) free(*a);
	free(j->argv);
	if (j->env) xpc_release(j->env);
	free(j->cwd); free(j->stdin_path); free(j->stdout_path); free(j->stderr_path);
	free(j->user); free(j->group);
	free(j->path);
	free(j);
}

/*
 * May an agent load into a user domain? LimitLoadToSessionType is a string or
 * an array of them. Finch has no graphical (Aqua) session yet, so a user's
 * one domain stands in for both user/<uid> (Background) and gui/<uid>
 * (Aqua, the default): agents for either load. LoginWindow, StandardIO and
 * System agents don't.
 */
static bool
agent_session_ok(xpc_object_t plist)
{
	xpc_object_t v = xpc_dictionary_get_value(plist, "LimitLoadToSessionType");
	__block bool ok = false;

	if (v == NULL) {
		return true;
	}
	if (xpc_get_type(v) == XPC_TYPE_STRING) {
		const char *t = xpc_string_get_string_ptr(v);
		return strcmp(t, "Aqua") == 0 || strcmp(t, "Background") == 0;
	}
	if (xpc_get_type(v) == XPC_TYPE_ARRAY) {
		xpc_array_apply(v, ^bool(size_t i, xpc_object_t t) {
			(void)i;
			if (xpc_get_type(t) == XPC_TYPE_STRING && (strcmp(xpc_string_get_string_ptr(t), "Aqua") == 0 ||
			    strcmp(xpc_string_get_string_ptr(t), "Background") == 0)) {
				ok = true;
			}
			return !ok;
		});
	}
	return ok;
}

static struct job *
job_from_plist(struct job_domain *d, xpc_object_t plist, const char *path)
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
	if (d != &system_domain && !agent_session_ok(plist)) {
		return NULL;
	}
	j = calloc(1, sizeof(*j));
	j->domain = d;
	j->label = dup_string(plist, "Label");
	j->path = strdup(path);
	j->last_exit = INT_MIN;
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
	if (d == &system_domain) {
		j->user = dup_string(plist, "UserName");
		j->group = dup_string(plist, "GroupName");
	} else {
		j->user = strdup(d->user);   /* an agent runs as its user; UserName is ignored, as in launchd */
	}
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
	if (!triggers_parse(j, plist)) {
		job_free(j);
		return NULL;
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
job_find_label(struct job_domain *d, const char *label)
{
	for (struct job *j = jobs; j != NULL; j = j->next) {
		if (j->domain == d && strcmp(j->label, label) == 0) return j;
	}
	return NULL;
}

#pragma mark - Spawning

static int
add_open(posix_spawn_file_actions_t *fa, int fd, const char *path, int flags)
{
	return posix_spawn_file_actions_addopen(fa, fd, path, flags, 0644);
}


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
	triggers_inherit(j, &fa);
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
	if (j->domain != &system_domain) {
		/* Else it inherits finch-init's: the system domain's. */
		posix_spawnattr_setspecialport_np(&attr, j->domain->port, TASK_BOOTSTRAP_PORT);
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
	j->runs++;
	triggers_started(j);
}

/* Start now, or after the throttle interval if it last started too recently. */
void
job_start(struct job *j)
{
	time_t now = time(NULL);
	time_t ready = j->started + j->throttle;

	if (j->pid > 0 || j->start_pending || j->unloading || shutting_down) {
		return;
	}
	if (j->started != 0 && now < ready) {
		j->start_pending = true;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ready - now) * NSEC_PER_SEC), queue, ^{
			j->start_pending = false;
			if (j->unloading) {
				job_free(j);   /* unloaded while waiting; not running, so nothing else refers to it */
			} else {
				job_start(j);
			}
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

static int control_hook(void *context, xpc_object_t request, xpc_object_t reply, const audit_token_t *token);

const struct bootstrapd_hooks jobs_bootstrap_hooks = {
	.demand = demand_hook,
	.may_check_in = may_check_in_hook,
	.control = control_hook,
};

#pragma mark - Loading

/*
 * Load one plist into `d`. With `strict`, the file must belong to the domain's
 * user (or root) and not be writable by others, as launchd requires of
 * ~/Library/LaunchAgents.
 */
static int job_load_plist(struct job_domain *d, xpc_object_t plist, const char *path, struct job **out);

static int
job_load_file(struct job_domain *d, const char *path, bool strict, struct job **out)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC | (strict ? O_NOFOLLOW : 0));
	struct stat st;
	xpc_object_t plist = NULL;
	char *buf;

	if (out) *out = NULL;
	if (fd < 0) return errno;
	if (strict && (fstat(fd, &st) != 0 || (st.st_uid != d->uid && st.st_uid != 0) ||
	    (st.st_mode & (S_IWGRP | S_IWOTH)))) {
		log_fn("%s: not loaded: must belong to %s or root and be writable only by its owner",
		    path, d->user);
		close(fd);
		return EPERM;
	}
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
		return EINVAL;
	}
	return job_load_plist(d, plist, path, out);
}

/* Load a job from its property list (released here), as from the file at `path`. */
static int
job_load_plist(struct job_domain *d, xpc_object_t plist, const char *path, struct job **out)
{
	xpc_object_t services;
	struct job *j;

	if (out) *out = NULL;
	j = job_from_plist(d, plist, path);
	if (j == NULL) {
		xpc_release(plist);
		return EINVAL;
	}
	if (job_find_label(d, j->label) != NULL) {
		log_fn("%s: job %s is already loaded in %s", path, j->label, d->name);
		job_free(j);
		xpc_release(plist);
		return EEXIST;
	}
	if (j != NULL) {
		services = xpc_dictionary_get_value(plist, "MachServices");
		if (services != NULL && xpc_get_type(services) == XPC_TYPE_DICTIONARY) {
			xpc_dictionary_apply(services, ^bool(const char *name, xpc_object_t value) {
				(void)value;   /* ResetAtClose, HideUntilCheckIn: not supported yet */
				int err = bootstrapd_declare(d->port, name, j);
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
		triggers_arm(j);
	}
	xpc_release(plist);
	if (out) *out = j;
	return 0;
}

static int
plist_name(const struct dirent *d)
{
	size_t n = strlen(d->d_name);
	return d->d_name[0] != '.' && n > 6 && strcmp(d->d_name + n - 6, ".plist") == 0;
}

mach_port_t
jobs_init(dispatch_queue_t q, void (*log)(const char *fmt, ...))
{
	queue = q;
	log_fn = log;
	system_domain.port = bootstrapd_start(q, &jobs_bootstrap_hooks, &system_domain);
	return system_domain.port;
}

static int
load_dir(struct job_domain *d, const char *dir, bool strict)
{
	struct dirent **names;
	int n = scandir(dir, &names, plist_name, alphasort), loaded = 0;
	char path[PATH_MAX];

	for (int i = 0; i < n; i++) {
		struct job *before = jobs;
		snprintf(path, sizeof(path), "%s/%s", dir, names[i]->d_name);
		job_load_file(d, path, strict, NULL);
		loaded += jobs != before;
		free(names[i]);
	}
	if (n > 0) free(names);
	return loaded;
}

int
jobs_load_dir(const char *dir)
{
	return load_dir(&system_domain, dir, false);
}

static bool
starts_at_load(const struct job *j)
{
	return j->run_at_load || j->keepalive == KEEPALIVE_ALWAYS || j->keepalive == KEEPALIVE_ON_FAILURE;
}

static void
start_domain(struct job_domain *d)
{
	for (struct job *j = jobs; j != NULL; j = j->next) {
		if (j->domain == d && starts_at_load(j)) {
			job_start(j);
		}
	}
}

void
jobs_start_all(void)
{
	start_domain(&system_domain);
}

#pragma mark - User domains

static struct job_domain *
user_domain_find(uid_t uid)
{
	for (struct job_domain *d = user_domains; d != NULL; d = d->next) {
		if (d->uid == uid) return d;
	}
	return NULL;
}

/* The user's domain, created (and its agents loaded and started) if needed.
 * NULL with *err set if the user doesn't exist or the domain can't be made. */
static struct job_domain *
user_domain(uid_t uid, int *err)
{
	struct job_domain *d = user_domain_find(uid);
	struct passwd *pw;
	char dir[PATH_MAX];
	int n = 0;

	if (d != NULL) {
		return d;
	}
	if (uid == 0 || (pw = getpwuid(uid)) == NULL) {
		*err = uid == 0 ? EINVAL : ESRCH;   /* root's agents would run in the system domain */
		return NULL;
	}
	d = calloc(1, sizeof(*d));
	snprintf(d->name, sizeof(d->name), "user/%u", uid);
	d->uid = uid;
	d->user = strdup(pw->pw_name);
	d->home = strdup(pw->pw_dir);
	d->port = bootstrapd_domain_create(system_domain.port, d);
	if (d->port == MACH_PORT_NULL) {
		free(d->user); free(d->home); free(d);
		*err = ENOMEM;
		return NULL;
	}
	d->next = user_domains;
	user_domains = d;
	for (size_t i = 0; i < sizeof(agent_dirs) / sizeof(agent_dirs[0]); i++) {
		n += load_dir(d, agent_dirs[i], false);
	}
	snprintf(dir, sizeof(dir), "%s/Library/LaunchAgents", d->home);
	n += load_dir(d, dir, true);
	log_fn("%s: domain for %s created, %d agent%s", d->name, d->user, n, n == 1 ? "" : "s");
	start_domain(d);
	return d;
}

static void job_remove(struct job *j);

/* `launchctl bootout user/<uid>`: stop its agents and close the domain. */
static void
user_domain_remove(struct job_domain *d)
{
	struct job *j = jobs, *next;

	for (; j != NULL; j = next) {
		next = j->next;
		if (j->domain == d) job_remove(j);
	}
	for (struct job_domain **pp = &user_domains; *pp != NULL; pp = &(*pp)->next) {
		if (*pp == d) {
			*pp = d->next;
			break;
		}
	}
	bootstrapd_domain_destroy(d->port);
	log_fn("%s: domain removed", d->name);
	free(d->user); free(d->home); free(d);
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
	j->last_exit = WIFSIGNALED(status) ? -WTERMSIG(status) : WEXITSTATUS(status);
	if (j->unloading) {
		job_free(j);
		return true;
	}
	success = WIFEXITED(status) && WEXITSTATUS(status) == 0;
	if (WIFSIGNALED(status) && WTERMSIG(status) != SIGTERM && WTERMSIG(status) != SIGKILL) {
		log_fn("%s: killed by signal %d", j->label, WTERMSIG(status));
	} else if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
		log_fn("%s: exited with status %d", j->label, WEXITSTATUS(status));
	}
	restart = !shutting_down && (j->keepalive == KEEPALIVE_ALWAYS ||
	    (j->keepalive == KEEPALIVE_ON_SUCCESS && success) ||
	    (j->keepalive == KEEPALIVE_ON_FAILURE && !success));
	if (restart) {
		job_start(j);
	}
	triggers_exited(j);
	/* Its services' receive rights come back via port-destroyed; watch them again. */
	bootstrapd_rearm(j);
	return true;
}

#pragma mark - Control (launchctl)

static void
job_remove(struct job *j)
{
	for (struct job **pp = &jobs; *pp != NULL; pp = &(*pp)->next) {
		if (*pp == j) {
			*pp = j->next;
			break;
		}
	}
	bootstrapd_undeclare(j);
	triggers_disarm(j);
	j->unloading = true;
	j->domain = NULL;   /* the domain may go before the process does */
	if (j->pid > 0) {
		kill(j->pid, SIGTERM);   /* freed when it exits */
	} else if (!j->start_pending) {
		job_free(j);             /* else freed when the pending start fires */
	}
}

static const char *
job_state(const struct job *j)
{
	return j->pid > 0 ? "running" : j->start_pending ? "waiting to restart" : "not running";
}

static xpc_object_t
job_describe(struct job *j)
{
	xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0), a, svc;

	xpc_dictionary_set_string(d, "label", j->label);
	xpc_dictionary_set_string(d, "domain", j->domain->name);
	xpc_dictionary_set_string(d, "path", j->path);
	xpc_dictionary_set_string(d, "program", j->program);
	a = xpc_array_create(NULL, 0);
	for (char **p = j->argv; *p; p++) xpc_array_set_string(a, XPC_ARRAY_APPEND, *p);
	xpc_dictionary_set_value(d, "arguments", a);
	xpc_release(a);
	xpc_dictionary_set_string(d, "state", job_state(j));
	xpc_dictionary_set_int64(d, "pid", j->pid);
	xpc_dictionary_set_int64(d, "runs", j->runs);
	if (j->last_exit != INT_MIN) {
		xpc_dictionary_set_int64(d, "last_exit", j->last_exit);
	}
	xpc_dictionary_set_bool(d, "run_at_load", j->run_at_load);
	xpc_dictionary_set_string(d, "keepalive", (const char *[]){ "no", "always",
	    "after successful exit", "after failed exit" }[j->keepalive]);
	xpc_dictionary_set_int64(d, "throttle", j->throttle);
	if (j->user) xpc_dictionary_set_string(d, "user", j->user);
	if (j->group) xpc_dictionary_set_string(d, "group", j->group);
	if (j->cwd) xpc_dictionary_set_string(d, "working_directory", j->cwd);
	if (j->stdout_path) xpc_dictionary_set_string(d, "stdout", j->stdout_path);
	if (j->stderr_path) xpc_dictionary_set_string(d, "stderr", j->stderr_path);
	svc = xpc_array_create(NULL, 0);
	bootstrapd_describe(j, svc);
	xpc_dictionary_set_value(d, "services", svc);
	xpc_release(svc);
	triggers_describe(j, d);
	return d;
}

/*
 * The domain a request names with "domain" ("system", "user/<uid>", or
 * "gui/<uid>", which is the same domain on Finch), or else the domain whose
 * port it arrived on. With `create`, a user domain is made if needed (if the
 * caller may). NULL with *err set if there's no such domain.
 */
static struct job_domain *
target_domain(struct job_domain *here, xpc_object_t request, uid_t euid, bool create, int *err)
{
	const char *name = xpc_dictionary_get_string(request, "domain");
	char *end;
	unsigned long uid;

	*err = ESRCH;
	if (name == NULL) return here;
	if (strcmp(name, "system") == 0) return &system_domain;
	if (strncmp(name, "user/", 5) == 0) name += 5;
	else if (strncmp(name, "gui/", 4) == 0) name += 4;
	else return NULL;
	uid = strtoul(name, &end, 10);
	if (*name == '\0' || *end != '\0' || uid > UINT32_MAX) {
		*err = EINVAL;
		return NULL;
	}
	if (!create || user_domain_find((uid_t)uid) != NULL) {
		return user_domain_find((uid_t)uid);
	}
	if (euid != 0 && euid != uid) {
		*err = EPERM;
		return NULL;
	}
	return user_domain((uid_t)uid, err);
}

static bool
may_read(const struct job_domain *d, uid_t euid)
{
	return d == &system_domain || euid == 0 || euid == d->uid;
}

static bool
may_change(const struct job_domain *d, uid_t euid)
{
	return euid == 0 || (d != &system_domain && euid == d->uid);
}


/*
 * An app's XPC service (libxpc asks when the app connects to one by name):
 * the .xpc bundle must be in the caller's own app, in Contents/XPCServices. Its
 * job runs the bundle's executable as the caller's user, on demand, serving the
 * Mach service named by its CFBundleIdentifier, in the caller's domain. One job
 * per service and domain: a second app instance shares the first's.
 */
static int
xpc_service_load(void *context, const char *path, const audit_token_t *token, xpc_object_t reply)
{
	struct job_domain *d = context;
	pid_t pid = (pid_t)token->val[5];
	uid_t euid = (uid_t)token->val[1];
	char caller[PROC_PIDPATHINFO_MAXSIZE], contents[PATH_MAX], real[PATH_MAX], plist_path[PATH_MAX];
	const char *id, *exe, *macos;
	xpc_object_t info, job, services, args;
	struct passwd *pw;
	struct job *loaded;
	char *buf;
	int fd, err;
	struct stat st;

	if (path == NULL || realpath(path, real) == NULL) return ENOENT;
	/* the caller's bundle: .../X.app/Contents/MacOS/exe -> .../X.app/Contents */
	if (proc_pidpath(pid, caller, sizeof(caller)) <= 0 || (macos = strstr(caller, "/Contents/MacOS/")) == NULL) {
		return EPERM;
	}
	snprintf(contents, sizeof(contents), "%.*s/Contents/XPCServices/", (int)(macos - caller), caller);
	if (strncmp(real, contents, strlen(contents)) != 0 || strchr(real + strlen(contents), '/') != NULL) {
		return EPERM;
	}
	snprintf(plist_path, sizeof(plist_path), "%s/Contents/Info.plist", real);
	if ((fd = open(plist_path, O_RDONLY | O_CLOEXEC)) < 0) return errno;
	info = NULL;
	if (fstat(fd, &st) == 0 && st.st_size > 0 && st.st_size < (1 << 20) && (buf = malloc((size_t)st.st_size)) != NULL) {
		if (read(fd, buf, (size_t)st.st_size) == st.st_size) info = xpc_create_from_plist(buf, (size_t)st.st_size);
		free(buf);
	}
	close(fd);
	if (info == NULL || xpc_get_type(info) != XPC_TYPE_DICTIONARY ||
	    (id = xpc_dictionary_get_string(info, "CFBundleIdentifier")) == NULL ||
	    (exe = xpc_dictionary_get_string(info, "CFBundleExecutable")) == NULL || strchr(exe, '/') != NULL) {
		if (info) xpc_release(info);
		return EINVAL;
	}
	xpc_dictionary_set_string(reply, "label", id);
	if (job_find_label(d, id) != NULL) {
		xpc_release(info);
		return 0;   /* already there */
	}
	job = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(job, "Label", id);
	snprintf(plist_path, sizeof(plist_path), "%s/Contents/MacOS/%s", real, exe);
	xpc_dictionary_set_string(job, "Program", plist_path);
	args = xpc_array_create(NULL, 0);
	xpc_array_set_string(args, XPC_ARRAY_APPEND, plist_path);
	xpc_dictionary_set_value(job, "ProgramArguments", args);
	xpc_release(args);
	services = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_bool(services, id, true);
	xpc_dictionary_set_value(job, "MachServices", services);
	xpc_release(services);
	if (d == &system_domain && (pw = getpwuid(euid)) != NULL) {
		xpc_dictionary_set_string(job, "UserName", pw->pw_name);
	}
	xpc_release(info);
	err = job_load_plist(d, job, real, &loaded);
	return err == EEXIST ? 0 : err;
}

/*
 * Requests: {op, domain?, label?, path?, signal?, kill?, uid?}. Each acts on a
 * domain (target_domain). Anyone may read the system domain and a user its
 * own; changes need root, or for a user domain its user. Errors are errno values.
 */
static int
control_hook(void *context, xpc_object_t request, xpc_object_t reply, const audit_token_t *token)
{
	const char *op = xpc_dictionary_get_string(request, "op");
	const char *label = xpc_dictionary_get_string(request, "label");
	uid_t euid = (uid_t)token->val[1];
	bool load = strcmp(op, "load") == 0;
	struct job_domain *d;
	struct job *j;
	int err;

	if (strcmp(op, "per-user") == 0) {
		/* bootstrap_look_up_per_user(): the user's domain port, made if needed. */
		uid_t uid = (uid_t)xpc_dictionary_get_uint64(request, "uid");
		if (euid != 0 && euid != uid) return EPERM;
		if ((d = user_domain(uid, &err)) == NULL) return err;
		xpc_object_t port = xpc_mach_send_create(d->port);
		xpc_dictionary_set_value(reply, "port", port);
		xpc_release(port);
		return 0;
	}
	if (strcmp(op, "checkin") == 0) {
		/* The caller's own job (launch_msg(LAUNCH_KEY_CHECKIN) in libxpc):
		 * its label and declared services, which it then checks in itself. */
		pid_t pid = (pid_t)token->val[5];
		for (struct job *k = jobs; k != NULL; k = k->next) {
			if (k->pid == pid && !k->unloading) {
				xpc_object_t desc = job_describe(k);
				xpc_dictionary_set_value(reply, "job", desc);
				xpc_release(desc);
				return 0;
			}
		}
		return ESRCH;
	}
	if (strcmp(op, "xpc-service") == 0) {
		/* An XPC service in the caller's app bundle, started on demand. */
		return xpc_service_load(context, xpc_dictionary_get_string(request, "path"), token, reply);
	}
	if (strcmp(op, "reboot") == 0) {
		int howto = (int)xpc_dictionary_get_uint64(request, "howto");
		if (euid != 0) return EPERM;
		if (shutting_down) return EALREADY;
		/* Reply first; the sequence runs on the queue after this request. */
		dispatch_async(queue, ^{ jobs_shutdown(howto); });
		return 0;
	}
	if ((d = target_domain(context, request, euid, load, &err)) == NULL) {
		return err;
	}
	if (strcmp(op, "domain") == 0) {
		/* launchctl manageruid / managername, vproc's VPROC_GSK_MGR_UID. */
		xpc_dictionary_set_string(reply, "name", d->name);
		xpc_dictionary_set_uint64(reply, "uid", d->uid);
		xpc_dictionary_set_string(reply, "session", d == &system_domain ? "System" : "Background");
		return 0;
	}
	if (!may_read(d, euid)) {
		return EPERM;
	}
	j = label ? job_find_label(d, label) : NULL;
	if (strcmp(op, "list") == 0) {
		xpc_object_t a = xpc_array_create(NULL, 0);
		for (struct job *k = jobs; k != NULL; k = k->next) {
			if (k->domain != d) continue;
			xpc_object_t desc = xpc_dictionary_create(NULL, NULL, 0);
			xpc_dictionary_set_string(desc, "label", k->label);
			xpc_dictionary_set_int64(desc, "pid", k->pid);
			if (k->last_exit != INT_MIN) xpc_dictionary_set_int64(desc, "last_exit", k->last_exit);
			xpc_array_append_value(a, desc);
			xpc_release(desc);
		}
		xpc_dictionary_set_string(reply, "domain", d->name);
		xpc_dictionary_set_value(reply, "jobs", a);
		xpc_release(a);
		return 0;
	}
	if (strcmp(op, "print") == 0) {
		if (j == NULL) return ESRCH;
		xpc_object_t desc = job_describe(j);
		xpc_dictionary_set_value(reply, "job", desc);
		xpc_release(desc);
		return 0;
	}
	if (!may_change(d, euid)) {
		return EPERM;
	}
	if (load) {
		const char *path = xpc_dictionary_get_string(request, "path");
		struct job *loaded;
		if (path == NULL) return EINVAL;
		err = job_load_file(d, path, false, &loaded);
		if (err == 0 && starts_at_load(loaded)) {
			job_start(loaded);
		}
		if (err == 0) xpc_dictionary_set_string(reply, "label", loaded->label);
		return err;
	}
	if (strcmp(op, "remove-domain") == 0) {
		if (d == &system_domain) return EINVAL;
		user_domain_remove(d);
		return 0;
	}
	if (j == NULL) {
		return ESRCH;
	}
	if (strcmp(op, "unload") == 0) {
		job_remove(j);
		return 0;
	}
	if (strcmp(op, "start") == 0) {
		job_start(j);
		return 0;
	}
	if (strcmp(op, "kickstart") == 0) {
		if (j->pid > 0) {
			if (!xpc_dictionary_get_bool(request, "kill")) return EALREADY;
			/* Restart: kill now, and start again as soon as it's gone. */
			kill(j->pid, SIGKILL);
			j->started = 0;   /* no throttle for an explicit restart */
			pid_t old = j->pid;
			dispatch_async(queue, ^{
				int status;
				if (j->pid == old && waitpid(old, &status, 0) == old) jobs_child_exited(old, status);
				job_start(j);
			});
			return 0;
		}
		j->started = 0;
		job_start(j);
		return 0;
	}
	if (strcmp(op, "stop") == 0 || strcmp(op, "kill") == 0) {
		int sig = strcmp(op, "stop") == 0 ? SIGTERM : (int)xpc_dictionary_get_int64(request, "signal");
		if (j->pid <= 0) return ESRCH;
		if (sig <= 0 || sig >= NSIG) return EINVAL;
		return kill(j->pid, sig) == 0 ? 0 : errno;
	}
	return ENOTSUP;
}

#pragma mark - Shutdown

#define JOB_EXIT_TIMEOUT_SEC   20   /* launchd's default ExitTimeOut */
#define PROCESS_GRACE_SEC       5   /* after SIGTERM to everything else */
#define POLL_MS               100

bool
jobs_shutting_down(void)
{
	return shutting_down;
}

static bool
any_job_running(void)
{
	for (struct job *j = jobs; j != NULL; j = j->next) {
		if (j->pid > 0) return true;
	}
	return false;
}

/* Poll `done()` every POLL_MS; after it holds or `timeout_sec` passes, run `next`. */
static void
wait_until(bool (^done)(void), int timeout_sec, dispatch_block_t next)
{
	__block int left = timeout_sec * 1000 / POLL_MS;
	dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, POLL_MS * NSEC_PER_MSEC),
	    POLL_MS * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(t, ^{
		if (done() || --left <= 0) {
			dispatch_source_cancel(t);
			dispatch_release(t);
			next();
		}
	});
	dispatch_resume(t);
}

static bool
no_other_processes(void)
{
	/* kill(-1) signals every process we may signal except ourselves (PID 1). */
	return kill(-1, 0) == -1 && errno == ESRCH;
}

static void
finish(int howto)
{
	log_fn("all processes stopped; %s", (howto & RB_HALT) ? "halting" : "rebooting");
	if (!(howto & RB_NOSYNC)) {
		sync();
	}
	reboot(howto);
	log_fn("reboot(2) failed: %s", strerror(errno));
}

void
jobs_shutdown(int howto)
{
	if (shutting_down) return;
	shutting_down = true;
	log_fn("shutting down (%s)", (howto & RB_HALT) ? "halt" : "reboot");

	/* 1. Jobs first, each with its exit timeout. */
	for (struct job *j = jobs; j != NULL; j = j->next) {
		if (j->pid > 0) kill(j->pid, SIGTERM);
	}
	wait_until(^bool { return !any_job_running(); }, JOB_EXIT_TIMEOUT_SEC, ^{
		for (struct job *j = jobs; j != NULL; j = j->next) {
			if (j->pid > 0) {
				log_fn("%s: didn't exit in %d s; killing it", j->label, JOB_EXIT_TIMEOUT_SEC);
				kill(j->pid, SIGKILL);
			}
		}
		/* 2. Everything else: shells, orphans. */
		kill(-1, SIGTERM);
		wait_until(^bool { return no_other_processes(); }, PROCESS_GRACE_SEC, ^{
			kill(-1, SIGKILL);
			wait_until(^bool { return no_other_processes(); }, 2, ^{
				finish(howto);
			});
		});
	});
}
