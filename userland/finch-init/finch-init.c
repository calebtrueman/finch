/*
 * finch-init: Finch's PID 1.
 *
 * Copyright (c) 2026 The Finch Project.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Apple's launchd is closed source (and, as of macOS 26, written in Swift on top
 * of the closed Swift runtime), so Finch brings its own init. This first version
 * does the minimum a usable system needs from PID 1:
 *
 *   1. attach to /dev/console,
 *   2. publish the OS version sysctls from SystemVersion.plist,
 *   3. serve the Mach bootstrap namespace (bootstrapd.c), which every process
 *      inherits as its bootstrap port,
 *   4. run /etc/finch/rc if present (one-shot boot script),
 *   5. load launchd job plists and run them: at load, kept alive, or on
 *      demand when a message arrives for their Mach services (jobs.c),
 *   6. keep an interactive login shell (zsh, else bash) alive on the console,
 *      respawning it on exit,
 *   7. reap every orphaned process re-parented to PID 1.
 *
 * Service supervision, mounting, and IPC bootstrap (Mach bootstrap port) come
 * later; see docs/ROADMAP.md, Phase 1.
 *
 * On DEVELOPMENT kernels this is selected with the boot-arg launchdsuffix=finch,
 * which makes xnu exec /usr/appleinternal/sbin/launchd.finch as PID 1.
 */

#include <errno.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

#include "bootstrapd.h"
#include "jobs.h"

#define FINCH_INIT_VERSION "0.0.1"
#define CONSOLE            "/dev/console"
#define RC_SCRIPT          "/etc/finch/rc"
#define SYSTEM_VERSION     "/System/Library/CoreServices/SystemVersion.plist"
#define DEFAULT_SHELL      "/bin/zsh"   /* as on macOS */
#define FALLBACK_SHELL     "/bin/bash"
#define RESPAWN_DELAY_SEC  1

/* Job plist directories, in load order (launchd's format). */
static const char *const job_dirs[] = {
	"/System/Library/Finch/LaunchDaemons",   /* Finch's own services */
	"/Library/LaunchDaemons",                /* third-party daemons, as on macOS */
};

static dispatch_queue_t init_queue;   /* registry, jobs and the console shell */
static pid_t console_shell;

/*
 * Log to the console. The console is opened afresh for every message: when the
 * console shell (the session leader, whose controlling terminal it is) exits,
 * the kernel revokes the terminal, and every descriptor open on it, including
 * any finch-init held, stops working.
 */
static void
logmsg(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	int n, fd;

	n = snprintf(line, sizeof(line), "finch-init: ");
	va_start(ap, fmt);
	n += vsnprintf(line + n, sizeof(line) - (size_t)n - 1, fmt, ap);
	va_end(ap);
	if (n > (int)sizeof(line) - 2) {
		n = (int)sizeof(line) - 2;
	}
	line[n++] = '\n';
	fd = open(CONSOLE, O_WRONLY | O_NOCTTY | O_CLOEXEC);
	if (fd >= 0) {
		(void)write(fd, line, (size_t)n);
		close(fd);
	} else {
		(void)write(STDERR_FILENO, line, (size_t)n);
	}
}

static void
attach_console(void)
{
	int fd = open(CONSOLE, O_RDWR | O_NOCTTY);

	if (fd < 0) {
		return; /* Nowhere to log; keep going with whatever fds we inherited. */
	}
	dup2(fd, STDIN_FILENO);
	dup2(fd, STDOUT_FILENO);
	dup2(fd, STDERR_FILENO);
	if (fd > STDERR_FILENO) {
		close(fd);
	}
}

static void
setup_environment(void)
{
	setenv("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
	setenv("HOME", "/var/root", 0);
	setenv("SHELL", DEFAULT_SHELL, 0);
	setenv("TERM", "vt100", 0);
	umask(022);
}

/*
 * Child-side setup for a console program: own session, console as the
 * controlling terminal, default signal dispositions.
 */
static void
exec_on_console(const char *path, char *const argv[])
{
	sigset_t none;
	int fd;

	sigemptyset(&none);
	sigprocmask(SIG_SETMASK, &none, NULL);
	signal(SIGINT, SIG_DFL);
	signal(SIGQUIT, SIG_DFL);
	signal(SIGTSTP, SIG_DFL);

	setsid();
	fd = open(CONSOLE, O_RDWR);
	if (fd >= 0) {
		ioctl(fd, TIOCSCTTY, 0);
		dup2(fd, STDIN_FILENO);
		dup2(fd, STDOUT_FILENO);
		dup2(fd, STDERR_FILENO);
		if (fd > STDERR_FILENO) {
			close(fd);
		}
	}
	execv(path, argv);
	logmsg("exec %s failed: %s", path, strerror(errno));
	_exit(127);
}

static pid_t
spawn_on_console(const char *path, char *const argv[])
{
	pid_t pid = fork();

	if (pid == 0) {
		exec_on_console(path, argv);
	}
	if (pid < 0) {
		logmsg("fork for %s failed: %s", path, strerror(errno));
	}
	return pid;
}

/* Wait for `target`, reaping any other children (orphans) along the way. */
static int
wait_for(pid_t target)
{
	int status;
	pid_t pid;

	for (;;) {
		pid = waitpid(-1, &status, 0);
		if (pid == target) {
			return status;
		}
		if (pid < 0 && errno != EINTR) {
			return -1;
		}
	}
}

static void
describe_exit(const char *what, int status)
{
	if (WIFEXITED(status)) {
		logmsg("%s exited with status %d", what, WEXITSTATUS(status));
	} else if (WIFSIGNALED(status)) {
		logmsg("%s killed by signal %d", what, WTERMSIG(status));
	}
}

/* Become the bootstrap server; children inherit the port across fork/exec. */
static void
start_bootstrap_server(void)
{
	mach_port_t port;

	init_queue = dispatch_queue_create("org.finch.init", DISPATCH_QUEUE_SERIAL);
	jobs_init(init_queue, logmsg);
	port = bootstrapd_start(init_queue, &jobs_bootstrap_hooks);
	if (port == MACH_PORT_NULL) {
		logmsg("bootstrap server failed to start; Mach services unavailable");
		return;
	}
	/* Children inherit the task's bootstrap port. finch-init's own
	 * bootstrap_port global stays MACH_PORT_NULL on purpose: a lookup from
	 * PID 1 (e.g. getpwnam -> Libinfo -> opendirectoryd) would be served on
	 * the very queue making it, and deadlock. Without a bootstrap port,
	 * PID 1's own Libinfo lookups use the files module. */
	task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, port);
}

static void
load_jobs(void)
{
	dispatch_sync(init_queue, ^{
		int n = 0;
		for (size_t i = 0; i < sizeof(job_dirs) / sizeof(job_dirs[0]); i++) {
			n += jobs_load_dir(job_dirs[i]);
		}
		if (n > 0) {
			logmsg("loaded %d job%s", n, n == 1 ? "" : "s");
		}
		jobs_start_all();
	});
}

/* Login shell on the console: argv[0] is "-<name>". zsh is re-checked each time. */
static void
start_console_shell(void)
{
	bool have_zsh = access(DEFAULT_SHELL, X_OK) == 0;
	const char *path = have_zsh ? DEFAULT_SHELL : FALLBACK_SHELL;
	char *argv[] = { have_zsh ? "-zsh" : "-bash", "-i", NULL };

	setenv("SHELL", path, 1);
	console_shell = spawn_on_console(path, argv);
	if (console_shell <= 0) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, RESPAWN_DELAY_SEC * NSEC_PER_SEC),
		    init_queue, ^{ start_console_shell(); });
	}
}

/* Reap every exited child: the console shell, jobs, and orphans. */
static void
reap_children(void)
{
	pid_t pid;
	int status;

	while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
		if (pid == console_shell) {
			console_shell = 0;
			if (jobs_shutting_down()) {
				continue;   /* no new shell while the system goes down */
			}
			describe_exit("console shell", status);
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, RESPAWN_DELAY_SEC * NSEC_PER_SEC),
			    init_queue, ^{ start_console_shell(); });
		} else {
			jobs_child_exited(pid, status);   /* else an orphan: just reaped */
		}
	}
}

static void
run_rc_script(void)
{
	char *argv[] = { "sh", RC_SCRIPT, NULL };
	struct stat st;
	pid_t pid;
	int status;

	if (stat(RC_SCRIPT, &st) != 0) {
		return;
	}
	logmsg("running %s", RC_SCRIPT);
	pid = spawn_on_console("/bin/sh", argv);
	if (pid > 0) {
		status = wait_for(pid);
		if (status != 0) {
			describe_exit(RC_SCRIPT, status);
		}
	}
}

/*
 * Find <key>key</key><string>VALUE</string> in an XML plist. Good enough for
 * SystemVersion.plist; init can't depend on CoreFoundation.
 */
static int
plist_string(const char *xml, const char *key, char *out, size_t outlen)
{
	char needle[128];
	const char *p, *end;
	size_t len;

	snprintf(needle, sizeof(needle), "<key>%s</key>", key);
	if ((p = strstr(xml, needle)) == NULL ||
	    (p = strstr(p + strlen(needle), "<string>")) == NULL) {
		return -1;
	}
	p += strlen("<string>");
	if ((end = strstr(p, "</string>")) == NULL) {
		return -1;
	}
	len = (size_t)(end - p);
	if (len >= outlen) {
		return -1;
	}
	memcpy(out, p, len);
	out[len] = '\0';
	return 0;
}

/*
 * xnu lets PID 1 set these once at boot (launchd's job on macOS). Userland
 * reads them through sysctl, e.g. sw_vers and Foundation's
 * operatingSystemVersion.
 */
static void
publish_os_version(void)
{
	static const struct {
		const char *plist_key;
		const char *sysctl;
	} map[] = {
		{ "ProductBuildVersion", "kern.osversion" },
		{ "ProductVersion", "kern.osproductversion" },
		{ "ReleaseType", "kern.osreleasetype" },
		{ "iOSSupportVersion", "kern.iossupportversion" },
	};
	char xml[16384], value[256];
	ssize_t n;
	size_t i;
	int fd;

	fd = open(SYSTEM_VERSION, O_RDONLY);
	if (fd < 0) {
		logmsg("no %s; OS version sysctls left unset", SYSTEM_VERSION);
		return;
	}
	n = read(fd, xml, sizeof(xml) - 1);
	close(fd);
	if (n <= 0) {
		return;
	}
	xml[n] = '\0';

	for (i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
		if (plist_string(xml, map[i].plist_key, value, sizeof(value)) != 0) {
			continue;
		}
		if (sysctlbyname(map[i].sysctl, NULL, NULL, value, strlen(value) + 1) != 0) {
			logmsg("setting %s failed: %s", map[i].sysctl, strerror(errno));
		}
	}
}

static void
print_banner(void)
{
	/* Brand colours (branding/BRAND.md): Finch Green and Slate, 24-bit ANSI. */
	static const char green[] = "\033[1;38;2;72;107;82m";
	static const char slate[] = "\033[38;2;154;160;166m";
	static const char reset[] = "\033[0m";
	struct utsname u;

	printf("\n  %sfinch%s\n  %sAn open OS for Apple Silicon%s\n\n",
	    green, reset, slate, reset);
	printf("Finch init %s (pid %d)\n", FINCH_INIT_VERSION, getpid());
	if (uname(&u) == 0) {
		printf("%s%s%s\n\n", slate, u.version, reset);
	}
	fflush(stdout);
}

int
main(void)
{
	dispatch_source_t sigchld;

	/* PID 1 must never die from a stray keyboard signal on the console. */
	signal(SIGINT, SIG_IGN);
	signal(SIGQUIT, SIG_IGN);
	signal(SIGTSTP, SIG_IGN);
	signal(SIGHUP, SIG_IGN);

	attach_console();
	publish_os_version();
	setup_environment();
	print_banner();
	if (getpid() != 1) {
		logmsg("warning: not running as PID 1");
	}

	start_bootstrap_server();
	run_rc_script();   /* synchronous: services start after it */

	/* From here on everything happens on init_queue. SIGCHLD keeps its
	 * default disposition (SIG_IGN would auto-reap and lose exit statuses). */
	sigchld = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGCHLD, 0, init_queue);
	dispatch_source_set_event_handler(sigchld, ^{ reap_children(); });
	dispatch_resume(sigchld);

	load_jobs();
	dispatch_async(init_queue, ^{
		start_console_shell();
		reap_children();   /* anything that exited before the source was armed */
	});
	dispatch_main();
}
