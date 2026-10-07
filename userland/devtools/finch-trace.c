/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-trace: where does a process's time go? Records kernel trace (kdebug)
 * events while running a command, then summarizes them for that command's
 * process(es):
 *
 *   - dyld's own launch phases (dyld emits DBG_DYLD timing events: map image,
 *     attach code signature, apply fixups, ObjC setup, each initializer, ...)
 *   - synchronous exceptions (on arm64 that's mostly page faults), with time
 *   - BSD system calls, by number, with time
 *
 *   finch-trace [-v] command [args...]
 *
 * Needs root and a kernel with kdebug (Finch's DEVELOPMENT kernel). Apple's
 * ktrace/fs_usage are closed; this uses the kdebug sysctls directly
 * (<sys/kdebug_private.h>).
 */

#include <errno.h>
#include <mach/mach_time.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

/* <sys/sysctl.h> KERN_KDEBUG operations (xnu private). */
#define KERN_KDEBUG           24
#define KERN_KDENABLE         3
#define KERN_KDSETBUF         4
#define KERN_KDGETBUF         5
#define KERN_KDSETUP          6
#define KERN_KDREMOVE         7
#define KERN_KDREADTR         10
#define KERN_KDTHRMAP         12
#define KERN_KDSET_TYPEFILTER 22
#define KDEBUG_ENABLE_TRACE   0x1
#define TYPEFILTER_BYTES      ((256 * 256) / 8)

typedef struct {
	uint64_t timestamp;
	uint64_t arg1, arg2, arg3, arg4, arg5;   /* arg5: thread id */
	uint32_t debugid;
	uint32_t cpuid;
	uint64_t unused;
} kd_buf;

typedef struct {
	int nkdbufs, nolog;
	unsigned int flags;
	int nkdthreads, bufid;
} kbufinfo_t;

typedef struct {
	uint64_t thread;
	int valid;   /* pid */
	char command[20];
} kd_threadmap;

#define CLASS(id)     (((id) >> 24) & 0xff)
#define SUBCLASS(id)  (((id) >> 16) & 0xff)
#define CODE(id)      (((id) >> 2) & 0x3fff)
#define FUNC(id)      ((id) & 0x3)
#define DBG_FUNC_START 1
#define DBG_FUNC_END   2

#define DBG_MACH 1
#define DBG_MACH_EXCP_SYNC_ARM 0x03
#define DBG_BSD 4
#define DBG_BSD_EXCP_SC 0x0C
#define DBG_TRACE 7
#define DBG_TRACE_DATA 0
#define TRACE_DATA_NEWTHREAD_CODE 1   /* arg1 = new thread, arg2 = its pid */
#define TRACE_DATA_EXEC_CODE 2        /* arg1 = pid, on the exec'ing thread */
#define DBG_DYLD 31
#define DBG_DYLD_INTERNAL 7
#define DBG_DYLD_API 8

static const char *dyld_phase[] = {
	[0] = "static initializers", [1] = "launch executable", [2] = "map image",
	[3] = "apply fixups", [4] = "attach code signature", [5] = "build closure",
	[6] = "add-image callbacks", [7] = "remove-image callbacks", [8] = "objc init",
	[9] = "objc map", [10] = "apply interposing", [13] = "bootstrap start",
	[14] = "validate closure",
};

static int
kd(int op, int value, void *buf, size_t *len)
{
	int mib[4] = { CTL_KERN, KERN_KDEBUG, op, value };
	size_t zero = 0;
	return sysctl(mib, 4, buf, len ? len : &zero, NULL, 0);
}

struct stat_entry { uint64_t count, total; uint64_t open[64]; int depth; };
static struct stat_entry dyld_stats[16], exc_stat, sc_stats[600];
static uint64_t first_ts, last_ts;

static void
account(struct stat_entry *e, uint32_t func, uint64_t ts)
{
	if (func == DBG_FUNC_START) {
		if (e->depth < 64) e->open[e->depth] = ts;
		e->depth++;
	} else if (func == DBG_FUNC_END && e->depth > 0) {
		e->depth--;
		if (e->depth < 64) {
			e->count++;
			e->total += ts - e->open[e->depth];
		}
	}
}

int
main(int argc, char **argv)
{
	bool verbose = false;
	int argi = 1;
	if (argi < argc && strcmp(argv[argi], "-v") == 0) { verbose = true; argi++; }
	if (argi >= argc) {
		fprintf(stderr, "usage: finch-trace [-v] command [args...]\n");
		return 64;
	}

	/* Set up: 1M events, filter to the classes we summarize. */
	kd(KERN_KDENABLE, 0, NULL, NULL);
	kd(KERN_KDREMOVE, 0, NULL, NULL);
	if (kd(KERN_KDSETBUF, 1 << 20, NULL, NULL) != 0 || kd(KERN_KDSETUP, 0, NULL, NULL) != 0) {
		fprintf(stderr, "finch-trace: kdebug setup failed: %s (root? DEVELOPMENT kernel?)\n", strerror(errno));
		return 1;
	}
	uint8_t *filter = calloc(1, TYPEFILTER_BYTES);
#define ALLOW(cls, sub) (filter[((cls) << 8 | (sub)) / 8] |= (uint8_t)(1 << (((cls) << 8 | (sub)) % 8)))
	ALLOW(DBG_TRACE, DBG_TRACE_DATA);
	ALLOW(DBG_MACH, DBG_MACH_EXCP_SYNC_ARM);
	ALLOW(DBG_BSD, DBG_BSD_EXCP_SC);
	ALLOW(DBG_DYLD, DBG_DYLD_INTERNAL);
	ALLOW(DBG_DYLD, DBG_DYLD_API);
	size_t flen = TYPEFILTER_BYTES;
	{
		int mib[3] = { CTL_KERN, KERN_KDEBUG, KERN_KDSET_TYPEFILTER };
		if (sysctl(mib, 3, filter, &flen, NULL, 0) != 0) {
			fprintf(stderr, "finch-trace: typefilter: %s\n", strerror(errno));
			return 1;
		}
	}

	/* Run the command with tracing on. */
	extern char **environ;
	pid_t pid;
	uint64_t t0 = mach_absolute_time();
	kd(KERN_KDENABLE, KDEBUG_ENABLE_TRACE, NULL, NULL);
	int rc = posix_spawnp(&pid, argv[argi], NULL, NULL, argv + argi, environ);
	int status = 0;
	if (rc == 0) waitpid(pid, &status, 0);
	kd(KERN_KDENABLE, 0, NULL, NULL);
	uint64_t t1 = mach_absolute_time();
	if (rc != 0) {
		fprintf(stderr, "finch-trace: %s: %s\n", argv[argi], strerror(rc));
		return 1;
	}

	/* Thread map: which threads belong to the traced pid. */
	kbufinfo_t info;
	size_t ilen = sizeof(info);
	kd(KERN_KDGETBUF, 0, &info, &ilen);
	size_t tlen = (size_t)(info.nkdthreads > 0 ? info.nkdthreads : 4096) * sizeof(kd_threadmap);
	kd_threadmap *map = malloc(tlen);
	if (kd(KERN_KDTHRMAP, 0, map, &tlen) != 0) tlen = 0;
	size_t nthreads = tlen / sizeof(kd_threadmap);

	/* Read events. */
	size_t n = (size_t)info.nkdbufs;
	kd_buf *ev = malloc(n * sizeof(kd_buf));
	/* KDREADTR returns at most one chunk per call: read until it's drained. */
	size_t got = 0;
	while (got < n) {
		size_t chunk = n - got;   /* in: capacity in events; out: events read */
		if (kd(KERN_KDREADTR, 0, ev + got, &chunk) != 0) {
			fprintf(stderr, "finch-trace: read: %s\n", strerror(errno));
			return 1;
		}
		if (chunk == 0) break;
		got += chunk;
	}
	kd(KERN_KDREMOVE, 0, NULL, NULL);

	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
#define MS(t) ((double)(t) * tb.numer / tb.denom / 1e6)

	/* The kdebug thread map is a snapshot from setup time, so threads of the
	 * command (created later) come from NEWTHREAD/EXEC events in the trace. */
	uint64_t *tids = calloc(4096, sizeof(uint64_t));
	size_t ntids = 0;
	for (size_t k = 0; k < nthreads; k++) {
		if (map[k].valid == pid && ntids < 4096) tids[ntids++] = map[k].thread;
	}
	for (size_t i = 0; i < got; i++) {
		uint32_t id = ev[i].debugid;
		if (CLASS(id) != DBG_TRACE || SUBCLASS(id) != DBG_TRACE_DATA || ntids >= 4096) continue;
		if (CODE(id) == TRACE_DATA_NEWTHREAD_CODE && (pid_t)ev[i].arg2 == pid) tids[ntids++] = ev[i].arg1;
		if (CODE(id) == TRACE_DATA_EXEC_CODE && (pid_t)ev[i].arg1 == pid) tids[ntids++] = ev[i].arg5;
	}

	size_t mine = 0;
	for (size_t i = 0; i < got; i++) {
		kd_buf *e = &ev[i];
		bool ours = false;
		for (size_t k = 0; k < ntids; k++) {
			if (tids[k] == e->arg5) { ours = true; break; }
		}
		if (!ours) continue;
		mine++;
		if (first_ts == 0) first_ts = e->timestamp;
		last_ts = e->timestamp;
		uint32_t id = e->debugid, cls = CLASS(id), sub = SUBCLASS(id), code = CODE(id), fn = FUNC(id);
		if (cls == DBG_DYLD && sub == DBG_DYLD_INTERNAL && code < 16) {
			account(&dyld_stats[code], fn, e->timestamp);
			if (verbose && fn == DBG_FUNC_END && code == 0) {
				printf("  initializer done at +%.1f ms (arg1=0x%llx)\n", MS(e->timestamp - first_ts), e->arg1);
			}
		} else if (cls == DBG_MACH && sub == DBG_MACH_EXCP_SYNC_ARM) {
			account(&exc_stat, fn, e->timestamp);
		} else if (cls == DBG_BSD && sub == DBG_BSD_EXCP_SC && code < 600) {
			account(&sc_stats[code], fn, e->timestamp);
		}
	}

	printf("finch-trace: %s (pid %d) exited with status %d after %.1f ms wall\n",
	    argv[argi], pid, WIFEXITED(status) ? WEXITSTATUS(status) : -1, MS(t1 - t0));
	printf("  %zu of %zu events (buffer %d) are the command's, on %zu threads (span %.1f ms)%s\n",
	    mine, got, info.nkdbufs, ntids, MS(last_ts - first_ts),
	    got >= n ? "  [buffer full: events were lost]" : "");
	printf("\n  dyld phases (count, total ms; nested phases overlap):\n");
	for (int c = 0; c < 16; c++) {
		if (dyld_stats[c].count == 0) continue;
		printf("    %-24s %6llu %10.1f\n", dyld_phase[c] ? dyld_phase[c] : "?", dyld_stats[c].count,
		    MS(dyld_stats[c].total));
	}
	printf("\n  synchronous exceptions (faults): %llu, %.1f ms\n", exc_stat.count, MS(exc_stat.total));
	printf("\n  top system calls (count, total ms):\n");
	for (int shown = 0; shown < 8; shown++) {
		int best = -1;
		for (int c = 0; c < 600; c++) {
			if (sc_stats[c].count && (best < 0 || sc_stats[c].total > sc_stats[best].total)) best = c;
		}
		if (best < 0) break;
		printf("    syscall %-4d %6llu %10.1f\n", best, sc_stats[best].count, MS(sc_stats[best].total));
		sc_stats[best].count = 0;
	}
	return 0;
}
