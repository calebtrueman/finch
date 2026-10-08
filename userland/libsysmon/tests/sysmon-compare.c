/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * sysmon-compare: check Finch's libsysmon process tables against the kernel's
 * own process records (sysctl KERN_PROC_ALL, a different path from the
 * proc_pidinfo calls libsysmon uses), and exercise the API. Apple's libsysmon
 * can't be the oracle: sysmond only answers clients with an Apple-signed
 * entitlement.
 *
 *   sysmon-compare /path/to/finch/libsysmon.dylib
 */

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <libproc.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sysmon.h>
#include <unistd.h>

static unsigned checks, failures;

#define CHECK(cond, ...)                                              \
	do {                                                          \
		checks++;                                             \
		if (!(cond)) {                                        \
			if (++failures <= 25) {                       \
				fprintf(stderr, "FAIL: " __VA_ARGS__); \
				fputc('\n', stderr);                  \
			}                                             \
		}                                                     \
	} while (0)

struct lib {
	void *(*create)(uint64_t, void (^)(void *, const char *));
	void (*add)(void *, uint32_t);
	void (*add_many)(void *, ...);
	void (*execute)(void *);
	void (*set_interval)(void *, uint64_t);
	void (*cancel)(void *);
	uint64_t (*count)(void *);
	void *(*row)(void *, uint64_t);
	void *(*copy_row)(void *, uint64_t);
	void (*table_apply)(void *, bool (^)(void *));
	xpc_object_t (*value)(void *, uint32_t);
	void (*row_apply)(void *, bool (^)(uint32_t, xpc_object_t));
	void *(*retain)(void *);
	void (*release)(void *);
};

static void
load(struct lib *l, const char *path)
{
	void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);

	if (h == NULL) {
		fprintf(stderr, "%s\n", dlerror());
		exit(2);
	}
#define L(f, n)                                              \
	if ((l->f = dlsym(h, n)) == NULL) {                  \
		fprintf(stderr, "missing %s in %s\n", n, path); \
		exit(2);                                     \
	}
	L(create, "sysmon_request_create_with_error");
	L(add, "sysmon_request_add_attribute");
	L(add_many, "sysmon_request_add_attributes");
	L(execute, "sysmon_request_execute");
	L(set_interval, "sysmon_request_set_interval");
	L(cancel, "sysmon_request_cancel");
	L(count, "sysmon_table_get_count");
	L(row, "sysmon_table_get_row");
	L(copy_row, "sysmon_table_copy_row");
	L(table_apply, "sysmon_table_apply");
	L(value, "sysmon_row_get_value");
	L(row_apply, "sysmon_row_apply");
	L(retain, "sysmon_retain");
	L(release, "sysmon_release");
#undef L
}

static const uint32_t attrs[] = { SYSMON_ATTR_PROC_PID, SYSMON_ATTR_PROC_FLAGS,
	SYSMON_ATTR_PROC_UID, SYSMON_ATTR_PROC_COMM, SYSMON_ATTR_PROC_ARGUMENTS,
	SYSMON_ATTR_PROC_RUID, SYSMON_ATTR_PROC_RGID, SYSMON_ATTR_PROC_PPID,
	SYSMON_ATTR_PROC_PGID, SYSMON_ATTR_PROC_TDEV, SYSMON_ATTR_PROC_START };
#define NATTRS (sizeof(attrs) / sizeof(attrs[0]))

static void *
table(struct lib *l, bool variadic, const char **error)
{
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block void *result = NULL;
	__block const char *err = NULL;
	void *req = l->create(SYSMON_REQUEST_TYPE_PROCESS, ^(void *t, const char *e) {
		if (t != NULL)
			result = l->retain(t);
		else
			err = e ? strdup(e) : "(null)";
		dispatch_semaphore_signal(done);
	});

	if (variadic) {
		l->add_many(req, attrs[0], attrs[1], attrs[2], attrs[3], attrs[4], attrs[5], attrs[6],
		    attrs[7], attrs[8], attrs[9], attrs[10], 0);
	} else {
		for (size_t i = 0; i < NATTRS; i++)
			l->add(req, attrs[i]);
	}
	l->execute(req);
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	l->release(req);
	if (error)
		*error = err;
	return result;
}

static uint64_t
u64(struct lib *l, void *row, uint32_t a)
{
	xpc_object_t v = l->value(row, a);

	return v ? xpc_uint64_get_value(v) : UINT64_MAX;
}

int
main(int argc, char **argv)
{
	struct lib finch;
	const char *err;

	if (argc != 2) {
		fprintf(stderr, "usage: sysmon-compare finch-libsysmon.dylib\n");
		return 2;
	}
	load(&finch, argv[1]);

	/* The kernel's view, for comparison. */
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t size = 0;
	sysctl(mib, 3, NULL, &size, NULL, 0);
	size += 64 * sizeof(struct kinfo_proc);
	struct kinfo_proc *kp = malloc(size);
	sysctl(mib, 3, kp, &size, NULL, 0);
	size_t nkp = size / sizeof(*kp);

	for (int variadic = 0; variadic < 2; variadic++) {
		void *t = table(&finch, variadic, &err);
		unsigned compared = 0;

		CHECK(t != NULL, "process table (error: %s)", err ? err : "-");
		if (t == NULL)
			continue;
		for (size_t k = 0; k < nkp; k++) {
			struct extern_proc *p = &kp[k].kp_proc;
			struct eproc *e = &kp[k].kp_eproc;
			void *row = NULL;

			for (uint64_t i = 0; i < finch.count(t) && row == NULL; i++) {
				if (u64(&finch, finch.row(t, i), SYSMON_ATTR_PROC_PID) == (uint64_t)p->p_pid)
					row = finch.row(t, i);
			}
			if (row == NULL || p->p_pid == 0 || p->p_stat == SZOMB)
				continue;   /* raced; kernel_task and zombies have no process info */
			compared++;
			pid_t pid = p->p_pid;
			CHECK(u64(&finch, row, SYSMON_ATTR_PROC_PPID) == (uint64_t)e->e_ppid, "pid %d ppid", pid);
			CHECK(u64(&finch, row, SYSMON_ATTR_PROC_PGID) == (uint64_t)e->e_pgid, "pid %d pgid", pid);
			CHECK(u64(&finch, row, SYSMON_ATTR_PROC_UID) == (uint64_t)e->e_ucred.cr_uid, "pid %d uid", pid);
			CHECK(u64(&finch, row, SYSMON_ATTR_PROC_RUID) == (uint64_t)e->e_pcred.p_ruid, "pid %d ruid", pid);
			CHECK(u64(&finch, row, SYSMON_ATTR_PROC_RGID) == (uint64_t)e->e_pcred.p_rgid, "pid %d rgid", pid);
			CHECK(u64(&finch, row, SYSMON_ATTR_PROC_TDEV) == (uint64_t)(uint32_t)e->e_tdev, "pid %d tdev", pid);
			xpc_object_t comm = finch.value(row, SYSMON_ATTR_PROC_COMM);
			/* sysmond reports the 15-character comm (pgrep -l shows the same). */
			CHECK(comm && strncmp(xpc_string_get_string_ptr(comm), p->p_comm, MAXCOMLEN - 1) == 0,
			    "pid %d comm", pid);
			uint64_t flags = u64(&finch, row, SYSMON_ATTR_PROC_FLAGS);
			CHECK(((flags & PROC_FLAG_SYSTEM) != 0) == ((p->p_flag & P_SYSTEM) != 0) &&
			    ((flags & PROC_FLAG_CONTROLT) != 0) == ((p->p_flag & P_CONTROLT) != 0),
			    "pid %d flags %#llx vs p_flag %#x", pid, (unsigned long long)flags, p->p_flag);
			xpc_object_t start = finch.value(row, SYSMON_ATTR_PROC_START);
			CHECK(start && xpc_date_get_value(start) ==
			    (int64_t)p->p_starttime.tv_sec * 1000000000LL + p->p_starttime.tv_usec * 1000LL,
			    "pid %d start", pid);

			/* row_apply: the requested attributes, ascending, values as get_value gives them. */
			__block uint32_t last = 0, visited = 0;
			__block bool ok = true;
			finch.row_apply(row, ^bool(uint32_t a, xpc_object_t v) {
				ok = ok && (visited == 0 || a > last) && v == finch.value(row, a);
				last = a;
				visited++;
				return true;
			});
			CHECK(ok && visited == NATTRS, "pid %d row_apply (%u attributes)", pid, visited);
		}
		CHECK(compared > 10, "only %u processes compared", compared);

		/* Our own argv comes back exactly. */
		for (uint64_t i = 0; i < finch.count(t); i++) {
			void *row = finch.row(t, i);

			if (u64(&finch, row, SYSMON_ATTR_PROC_PID) != (uint64_t)getpid())
				continue;
			xpc_object_t args = finch.value(row, SYSMON_ATTR_PROC_ARGUMENTS);
			CHECK(args && xpc_array_get_count(args) == (size_t)argc &&
			    strcmp(xpc_array_get_string(args, 0), argv[0]) == 0 &&
			    strcmp(xpc_array_get_string(args, 1), argv[1]) == 0, "own arguments");
		}

		__block uint64_t n = 0;
		finch.table_apply(t, ^bool(void *r) {
			(void)r;
			n++;
			return false;   /* every row is visited regardless, as Apple's does */
		});
		CHECK(n == finch.count(t), "table_apply visited %llu of %llu", (unsigned long long)n,
		    (unsigned long long)finch.count(t));
		void *copy = finch.copy_row(t, 0);
		finch.release(t);
		CHECK(finch.value(copy, SYSMON_ATTR_PROC_PID) != NULL, "a copied row outlives its table");
		finch.release(copy);
		printf("variadic=%d: %u processes compared with the kernel's records\n", variadic, compared);
	}

	/* An attribute nobody requested has no value. */
	{
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		__block void *t = NULL;
		void *req = finch.create(SYSMON_REQUEST_TYPE_PROCESS, ^(void *tab, const char *e) {
			(void)e;
			t = finch.retain(tab);
			dispatch_semaphore_signal(done);
		});
		finch.add(req, SYSMON_ATTR_PROC_PID);
		finch.execute(req);
		dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
		finch.release(req);
		CHECK(finch.value(finch.row(t, 0), SYSMON_ATTR_PROC_COMM) == NULL, "unrequested attribute");
		finch.release(t);
	}

	/* A periodic request delivers repeatedly until cancelled. */
	{
		dispatch_semaphore_t tick = dispatch_semaphore_create(0);
		__block int deliveries = 0;
		void *req = finch.create(SYSMON_REQUEST_TYPE_PROCESS, ^(void *tab, const char *e) {
			(void)tab;
			(void)e;
			deliveries++;
			dispatch_semaphore_signal(tick);
		});
		finch.add(req, SYSMON_ATTR_PROC_PID);
		finch.set_interval(req, 100);   /* rounds up to 500 ms */
		finch.execute(req);
		for (int i = 0; i < 3; i++)
			dispatch_semaphore_wait(tick, DISPATCH_TIME_FOREVER);
		finch.cancel(req);
		finch.release(req);
		CHECK(deliveries >= 3, "periodic deliveries: %d", deliveries);
	}

	/* System-wide and coalition requests report an error without sysmond. */
	{
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		__block bool got_table = true, got_error = false;
		void *req = finch.create(2, ^(void *tab, const char *e) {
			got_table = tab != NULL;
			got_error = e != NULL;
			dispatch_semaphore_signal(done);
		});
		finch.execute(req);
		dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
		finch.release(req);
		CHECK(!got_table && got_error, "type 2 reports an error");
	}

	printf("libsysmon: %u checks, %u failures\n", checks, failures);
	return failures != 0;
}
