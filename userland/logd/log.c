/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * log(1) for Finch: shows the messages finch-logd stores (logstore.h).
 *
 *   log show   [options]   print stored messages
 *   log stream [options]   print new messages as they arrive (^C to stop)
 *
 * Options, as in macOS's log(1):
 *   --last <n>[s|m|h|d]    only the last n seconds/minutes/hours/days (show)
 *   --process <name|pid>   only this process
 *   --subsystem <name>     only this subsystem
 *   --category <name>      only this category
 *   --type <type>          only default, info, debug, error or fault messages
 *   --info, --debug        include Info (and Debug) messages
 *   --style default|compact|syslog
 *
 * Predicates (--predicate) aren't supported yet.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "logstore.h"

enum style { STYLE_DEFAULT, STYLE_COMPACT, STYLE_SYSLOG };

static struct {
	uint64_t since_ns;
	const char *process;
	pid_t pid;
	const char *subsystem, *category;
	int type;                    /* -1: any (subject to info/debug) */
	bool info, debug;
	enum style style;
	bool header_done;
} opt = { .type = -1 };

static const char *
type_name(uint8_t t)
{
	switch (t) {
	case 0: return "Default";
	case 1: return "Info";
	case 2: return "Debug";
	case 16: return "Error";
	case 17: return "Fault";
	default: return "?";
	}
}

static int
type_from_name(const char *s)
{
	static const char *names[] = { "default", "info", "debug", "error", "fault" };
	static const int values[] = { 0, 1, 2, 16, 17 };
	for (size_t i = 0; i < 5; i++) {
		if (strcasecmp(s, names[i]) == 0) return values[i];
	}
	return -2;
}

static bool
wanted(const struct logstore_record *r, const char *process, const char *subsystem,
    const char *category)
{
	if (r->time_ns < opt.since_ns) return false;
	if (opt.type >= 0) {
		if (r->type != opt.type) return false;
	} else if ((r->type == 1 && !opt.info && !opt.debug) || (r->type == 2 && !opt.debug)) {
		return false;
	}
	if (opt.pid > 0 && r->pid != opt.pid) return false;
	if (opt.process && opt.pid <= 0 && strcmp(process, opt.process) != 0) return false;
	if (opt.subsystem && strcmp(subsystem, opt.subsystem) != 0) return false;
	if (opt.category && strcmp(category, opt.category) != 0) return false;
	return true;
}

static void
print_record(const struct logstore_record *r)
{
	const char *process = r->strings;
	const char *subsystem = process + r->process_len + 1;
	const char *category = subsystem + r->subsystem_len + 1;
	const char *message = category + r->category_len + 1;
	char stamp[64], zone[8];
	time_t secs = (time_t)(r->time_ns / 1000000000ull);
	struct tm tm;

	if (!wanted(r, process, subsystem, category)) return;
	localtime_r(&secs, &tm);
	strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm);
	strftime(zone, sizeof(zone), "%z", &tm);
	if (!opt.header_done && opt.style == STYLE_DEFAULT) {
		printf("%-31s %-10s %-11s %-6s %s\n", "Timestamp", "Thread", "Type", "PID", "Message");
	}
	opt.header_done = true;
	switch (opt.style) {
	case STYLE_COMPACT:
		printf("%s.%03llu %-2.2s %s[%d] ", stamp, (unsigned long long)(r->time_ns / 1000000 % 1000),
		    type_name(r->type), process, r->pid);
		break;
	case STYLE_SYSLOG:
		printf("%s.%06llu%s localhost %s[%d]: ", stamp,
		    (unsigned long long)(r->time_ns / 1000 % 1000000), zone, process, r->pid);
		break;
	default:
		printf("%s.%06llu%s %-#10llx %-11s %-6d %s: ", stamp,
		    (unsigned long long)(r->time_ns / 1000 % 1000000), zone,
		    (unsigned long long)r->thread, type_name(r->type), r->pid, process);
		break;
	}
	if (*subsystem) {
		printf("[%s:%s] ", subsystem, category);
	}
	printf("%s\n", message);
}

/* Print the records in fd from its current offset; returns the new offset. */
static off_t
print_from(int fd, off_t at)
{
	struct logstore_record head;
	char *buf = NULL;
	size_t cap = 0;

	for (;;) {
		if (pread(fd, &head, sizeof(head), at) != (ssize_t)sizeof(head)) break;
		if (head.size < sizeof(head) || head.size > (1u << 20)) break;   /* not a record */
		if (cap < head.size) {
			buf = realloc(buf, head.size);
			cap = head.size;
		}
		if (pread(fd, buf, head.size, at) != (ssize_t)head.size) break;  /* still being written */
		buf[head.size - 1] = 0;
		print_record((const struct logstore_record *)buf);
		at += head.size;
	}
	free(buf);
	fflush(stdout);
	return at;
}

static int
show(void)
{
	int shown = 0;
	const char *files[] = { LOGSTORE_PATH ".0", LOGSTORE_PATH };

	for (size_t i = 0; i < 2; i++) {
		int fd = open(files[i], O_RDONLY | O_CLOEXEC);
		if (fd < 0) continue;
		print_from(fd, 0);
		close(fd);
		shown++;
	}
	if (shown == 0) {
		fprintf(stderr, "log: no log store at %s (is finch-logd running?)\n", LOGSTORE_PATH);
		return 1;
	}
	return 0;
}

static int
stream(void)
{
	int kq = kqueue();
	off_t at = -1;   /* -1: start at the end of the current file (only new messages) */
	struct stat st;

	if (opt.style == STYLE_DEFAULT) {
		printf("Filtering the log data using the given options\n");
	}
	for (;;) {
		int fd = open(LOGSTORE_PATH, O_RDONLY | O_CLOEXEC);
		if (fd < 0) {
			sleep(1);
			at = 0;   /* when it appears, it's all new */
			continue;
		}
		fstat(fd, &st);
		ino_t ino = st.st_ino;
		if (at < 0) at = st.st_size;
		struct kevent ev;
		EV_SET(&ev, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
		    NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME, 0, NULL);
		kevent(kq, &ev, 1, NULL, 0, NULL);
		for (;;) {
			struct timespec tick = { 1, 0 };
			at = print_from(fd, at);
			kevent(kq, NULL, 0, &ev, 1, &tick);
			if (stat(LOGSTORE_PATH, &st) != 0 || st.st_ino != ino) {
				print_from(fd, at);   /* rotated: finish this file, then follow the new one */
				break;
			}
		}
		close(fd);
		at = 0;
	}
}

static uint64_t
parse_last(const char *s)
{
	char *end;
	double n = strtod(s, &end);
	uint64_t unit = 1;

	if (end == s || n < 0) return 0;
	switch (*end) {
	case 'd': unit = 86400; break;
	case 'h': unit = 3600; break;
	case 'm': unit = 60; break;
	case 's': case 0: unit = 1; break;
	default: return 0;
	}
	struct timespec now;
	clock_gettime(CLOCK_REALTIME, &now);
	uint64_t now_ns = (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
	uint64_t back = (uint64_t)(n * (double)unit * 1e9);
	return back > now_ns ? 0 : now_ns - back;
}

static int
usage(void)
{
	fprintf(stderr,
	    "usage: log show [--last <n>[s|m|h|d]] [filters]\n"
	    "       log stream [filters]\n"
	    "filters: --process <name|pid> --subsystem <s> --category <c> --type <t> --info --debug\n"
	    "         --style default|compact|syslog\n");
	return 64;
}

int
main(int argc, char **argv)
{
	if (argc < 2) return usage();
	for (int i = 2; i < argc; i++) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (strcmp(a, "--info") == 0) opt.info = true;
		else if (strcmp(a, "--debug") == 0) opt.debug = true;
		else if (strcmp(a, "--last") == 0 && v) { opt.since_ns = parse_last(v); i++; }
		else if (strcmp(a, "--process") == 0 && v) {
			char *end;
			long pid = strtol(v, &end, 10);
			if (*end == 0) opt.pid = (pid_t)pid; else opt.process = v;
			i++;
		}
		else if (strcmp(a, "--subsystem") == 0 && v) { opt.subsystem = v; i++; }
		else if (strcmp(a, "--category") == 0 && v) { opt.category = v; i++; }
		else if (strcmp(a, "--type") == 0 && v) {
			if ((opt.type = type_from_name(v)) == -2) return usage();
			i++;
		}
		else if (strcmp(a, "--style") == 0 && v) {
			opt.style = strcmp(v, "compact") == 0 ? STYLE_COMPACT : strcmp(v, "syslog") == 0 ? STYLE_SYSLOG : STYLE_DEFAULT;
			i++;
		}
		else if (strcmp(a, "--predicate") == 0) {
			fprintf(stderr, "log: --predicate isn't supported on Finch yet\n");
			return 64;
		}
		else return usage();
	}
	if (strcmp(argv[1], "show") == 0) return show();
	if (strcmp(argv[1], "stream") == 0) return stream();
	return usage();
}
