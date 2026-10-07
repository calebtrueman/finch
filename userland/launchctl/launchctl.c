/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * launchctl: inspect and manage finch-init's jobs (docs/design/SERVICES.md).
 * Apple's launchctl is closed and speaks launchd's private protocol; this one
 * accepts the commonly used macOS syntax and talks to finch-init with control
 * requests over the bootstrap port.
 *
 *   launchctl list [label]
 *   launchctl print system | system/<label>
 *   launchctl start|stop <label>
 *   launchctl kickstart [-k] system/<label>
 *   launchctl kill <signal> system/<label>
 *   launchctl load <plist>...          launchctl bootstrap system <plist>...
 *   launchctl unload <plist>...        launchctl bootout system/<label> | system <plist>
 */

#include <errno.h>
#include <limits.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

typedef struct xpc_pipe_s *xpc_pipe_t;
xpc_pipe_t xpc_pipe_create_from_port(mach_port_t port, uint64_t flags);
int xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply);
xpc_object_t xpc_create_from_plist(const void *data, size_t length);

static int
request(xpc_object_t req, xpc_object_t *reply_out)
{
	xpc_pipe_t pipe = xpc_pipe_create_from_port(bootstrap_port, 0);
	xpc_object_t reply = NULL;
	int rc, err;

	if (pipe == NULL || (rc = xpc_pipe_routine(pipe, req, &reply)) != 0) {
		fprintf(stderr, "launchctl: can't reach finch-init: %s\n",
		    pipe == NULL ? "no bootstrap port" : strerror(rc));
		exit(EXIT_FAILURE);
	}
	xpc_release((xpc_object_t)pipe);
	err = (int)xpc_dictionary_get_int64(reply, "error");
	if (reply_out) {
		*reply_out = reply;
	} else {
		xpc_release(reply);
	}
	return err;
}

static xpc_object_t
make(const char *op, const char *label)
{
	xpc_object_t r = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_string(r, "op", op);
	if (label) xpc_dictionary_set_string(r, "label", label);
	return r;
}

/* "system/<label>" -> "<label>"; plain labels are accepted too. */
static const char *
target_label(const char *target)
{
	const char *slash = strchr(target, '/');
	if (slash == NULL) return target;
	if (strncmp(target, "system/", 7) != 0) {
		fprintf(stderr, "launchctl: only the system domain exists on Finch: %s\n", target);
		exit(EXIT_FAILURE);
	}
	return slash + 1;
}

static int
report(const char *what, int err)
{
	if (err != 0) {
		fprintf(stderr, "launchctl: %s: %s\n", what,
		    err == ESRCH ? "No such process (job not loaded or not running)" :
		    err == EPERM ? "Operation not permitted (needs root)" : strerror(err));
		return 1;
	}
	return 0;
}

static int
simple(const char *op, const char *label)
{
	xpc_object_t r = make(op, label);
	int err = request(r, NULL);
	xpc_release(r);
	return report(label, err);
}

static void
print_status(xpc_object_t job)
{
	if (xpc_dictionary_get_value(job, "last_exit") != NULL) {
		printf("%lld", xpc_dictionary_get_int64(job, "last_exit"));
	} else {
		printf("-");
	}
}

static int
cmd_list(const char *label)
{
	xpc_object_t r = make(label ? "print" : "list", label), reply;
	int err = request(r, &reply);

	xpc_release(r);
	if (err != 0) {
		xpc_release(reply);
		return report(label ? label : "list", err);
	}
	if (label == NULL) {
		printf("PID\tStatus\tLabel\n");
		xpc_array_apply(xpc_dictionary_get_value(reply, "jobs"), ^bool(size_t i, xpc_object_t job) {
			(void)i;
			int64_t pid = xpc_dictionary_get_int64(job, "pid");
			if (pid > 0) printf("%lld\t", pid); else printf("-\t");
			print_status(job);
			printf("\t%s\n", xpc_dictionary_get_string(job, "label"));
			return true;
		});
	} else {
		xpc_object_t job = xpc_dictionary_get_value(reply, "job");
		/* macOS prints a plist-ish dictionary for `list <label>`. */
		printf("{\n\t\"Label\" = \"%s\";\n", xpc_dictionary_get_string(job, "label"));
		if (xpc_dictionary_get_int64(job, "pid") > 0) {
			printf("\t\"PID\" = %lld;\n", xpc_dictionary_get_int64(job, "pid"));
		}
		if (xpc_dictionary_get_value(job, "last_exit") != NULL) {
			printf("\t\"LastExitStatus\" = %lld;\n", xpc_dictionary_get_int64(job, "last_exit"));
		}
		printf("\t\"Program\" = \"%s\";\n};\n", xpc_dictionary_get_string(job, "program"));
	}
	xpc_release(reply);
	return 0;
}

static void
print_kv(const char *key, xpc_object_t job, const char *field)
{
	const char *s = xpc_dictionary_get_string(job, field);
	if (s) printf("\t%s = %s\n", key, s);
}

static int
cmd_print(const char *target)
{
	if (strcmp(target, "system") == 0) {
		xpc_object_t r = make("list", NULL), reply;
		int err = request(r, &reply);
		xpc_release(r);
		if (err != 0) return report("system", err);
		printf("system = {\n\tjobs = {\n");
		xpc_array_apply(xpc_dictionary_get_value(reply, "jobs"), ^bool(size_t i, xpc_object_t job) {
			(void)i;
			int64_t pid = xpc_dictionary_get_int64(job, "pid");
			if (pid > 0) printf("\t\t%8lld\t", pid); else printf("\t\t%8s\t", "-");
			print_status(job);
			printf("\t%s\n", xpc_dictionary_get_string(job, "label"));
			return true;
		});
		printf("\t}\n}\n");
		xpc_release(reply);
		return 0;
	}

	const char *label = target_label(target);
	xpc_object_t r = make("print", label), reply;
	int err = request(r, &reply);
	xpc_release(r);
	if (err != 0) {
		xpc_release(reply);
		return report(label, err);
	}
	xpc_object_t job = xpc_dictionary_get_value(reply, "job");
	printf("system/%s = {\n", label);
	print_kv("path", job, "path");
	print_kv("state", job, "state");
	print_kv("program", job, "program");
	printf("\targuments = {\n");
	xpc_array_apply(xpc_dictionary_get_value(job, "arguments"), ^bool(size_t i, xpc_object_t a) {
		(void)i;
		printf("\t\t%s\n", xpc_string_get_string_ptr(a));
		return true;
	});
	printf("\t}\n");
	if (xpc_dictionary_get_int64(job, "pid") > 0) printf("\tpid = %lld\n", xpc_dictionary_get_int64(job, "pid"));
	printf("\truns = %lld\n", xpc_dictionary_get_int64(job, "runs"));
	if (xpc_dictionary_get_value(job, "last_exit") != NULL) {
		int64_t e = xpc_dictionary_get_int64(job, "last_exit");
		if (e < 0) printf("\tlast exit = %s (signal %lld)\n", strsignal((int)-e), -e);
		else printf("\tlast exit code = %lld\n", e);
	} else {
		printf("\tlast exit code = (never exited)\n");
	}
	printf("\trun at load = %s\n", xpc_dictionary_get_bool(job, "run_at_load") ? "yes" : "no");
	print_kv("keepalive", job, "keepalive");
	printf("\tthrottle interval = %lld s\n", xpc_dictionary_get_int64(job, "throttle"));
	print_kv("user", job, "user");
	print_kv("group", job, "group");
	print_kv("working directory", job, "working_directory");
	print_kv("stdout path", job, "stdout");
	print_kv("stderr path", job, "stderr");
	printf("\tendpoints = {\n");
	xpc_array_apply(xpc_dictionary_get_value(job, "services"), ^bool(size_t i, xpc_object_t s) {
		(void)i;
		printf("\t\t\"%s\"\n\t\t\tstate = %s", xpc_dictionary_get_string(s, "name"),
		    xpc_dictionary_get_bool(s, "active") ? "active" : "waiting for first message");
		if (xpc_dictionary_get_value(s, "queued") != NULL) {
			printf(", %llu queued", xpc_dictionary_get_uint64(s, "queued"));
		}
		printf("\n");
		return true;
	});
	printf("\t}\n}\n");
	xpc_release(reply);
	return 0;
}

/* The Label of a plist file, for `unload <path>` / `bootout system <path>`. */
static char *
plist_label(const char *path)
{
	FILE *f = fopen(path, "r");
	char *buf, *label = NULL;
	long n;
	xpc_object_t p;

	if (f == NULL) return NULL;
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	rewind(f);
	if (n <= 0 || n > (1 << 20) || (buf = malloc((size_t)n)) == NULL) {
		fclose(f);
		return NULL;
	}
	if (fread(buf, 1, (size_t)n, f) == (size_t)n && (p = xpc_create_from_plist(buf, (size_t)n)) != NULL) {
		const char *l = xpc_get_type(p) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_string(p, "Label") : NULL;
		label = l ? strdup(l) : NULL;
		xpc_release(p);
	}
	free(buf);
	fclose(f);
	return label;
}

static int
cmd_load(char **paths, int n)
{
	int failures = 0;
	for (int i = 0; i < n; i++) {
		char abs[PATH_MAX];
		xpc_object_t r = make("load", NULL);
		xpc_dictionary_set_string(r, "path", realpath(paths[i], abs) ? abs : paths[i]);
		int err = request(r, NULL);
		xpc_release(r);
		failures += report(paths[i], err == EEXIST ? EEXIST : err);
	}
	return failures != 0;
}

static int
cmd_unload_paths(char **paths, int n)
{
	int failures = 0;
	for (int i = 0; i < n; i++) {
		char *label = plist_label(paths[i]);
		if (label == NULL) {
			fprintf(stderr, "launchctl: %s: not a job plist\n", paths[i]);
			failures++;
			continue;
		}
		failures += simple("unload", label);
		free(label);
	}
	return failures != 0;
}

static int
parse_signal(const char *s)
{
	if (s[0] >= '0' && s[0] <= '9') return atoi(s);
	if (strncasecmp(s, "SIG", 3) == 0) s += 3;
	for (int i = 1; i < NSIG; i++) {
		if (strcasecmp(s, sys_signame[i]) == 0) return i;
	}
	return -1;
}

static int
usage(void)
{
	fprintf(stderr,
	    "usage: launchctl list [label]\n"
	    "       launchctl print system | system/<label>\n"
	    "       launchctl start | stop <label>\n"
	    "       launchctl kickstart [-k] system/<label>\n"
	    "       launchctl kill <signal> system/<label>\n"
	    "       launchctl load | unload <plist>...\n"
	    "       launchctl bootstrap system <plist>...\n"
	    "       launchctl bootout system/<label> | system <plist>...\n"
	    "       launchctl version\n");
	return 64;
}

int
main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : NULL;

	if (cmd == NULL || strcmp(cmd, "help") == 0) {
		return usage();
	}
	if (strcmp(cmd, "version") == 0) {
		printf("Finch launchctl (finch-init service manager)\n");
		return 0;
	}
	if (strcmp(cmd, "list") == 0) {
		return cmd_list(argc > 2 ? argv[2] : NULL);
	}
	if (strcmp(cmd, "print") == 0 && argc == 3) {
		return cmd_print(argv[2]);
	}
	if ((strcmp(cmd, "start") == 0 || strcmp(cmd, "stop") == 0) && argc == 3) {
		return simple(cmd, argv[2]);
	}
	if (strcmp(cmd, "kickstart") == 0 && argc >= 3) {
		bool k = argc == 4 && strcmp(argv[2], "-k") == 0;
		const char *label = target_label(argv[argc - 1]);
		xpc_object_t r = make("kickstart", label);
		xpc_dictionary_set_bool(r, "kill", k);
		int err = request(r, NULL);
		xpc_release(r);
		if (err == EALREADY) {
			fprintf(stderr, "launchctl: %s is already running (use -k to restart it)\n", label);
			return 1;
		}
		return report(label, err);
	}
	if (strcmp(cmd, "kill") == 0 && argc == 4) {
		int sig = parse_signal(argv[2]);
		if (sig <= 0) {
			fprintf(stderr, "launchctl: unknown signal %s\n", argv[2]);
			return 1;
		}
		const char *label = target_label(argv[3]);
		xpc_object_t r = make("kill", label);
		xpc_dictionary_set_int64(r, "signal", sig);
		int err = request(r, NULL);
		xpc_release(r);
		return report(label, err);
	}
	if (strcmp(cmd, "load") == 0 && argc >= 3) {
		int first = (strcmp(argv[2], "-w") == 0) ? 3 : 2;   /* -w (persist enable) is accepted, not needed */
		return cmd_load(argv + first, argc - first);
	}
	if (strcmp(cmd, "unload") == 0 && argc >= 3) {
		int first = (strcmp(argv[2], "-w") == 0) ? 3 : 2;
		return cmd_unload_paths(argv + first, argc - first);
	}
	if (strcmp(cmd, "bootstrap") == 0 && argc >= 4 && strcmp(argv[2], "system") == 0) {
		return cmd_load(argv + 3, argc - 3);
	}
	if (strcmp(cmd, "bootout") == 0 && argc >= 3) {
		if (strcmp(argv[2], "system") == 0 && argc >= 4) {
			return cmd_unload_paths(argv + 3, argc - 3);
		}
		return simple("unload", target_label(argv[2]));
	}
	return usage();
}
