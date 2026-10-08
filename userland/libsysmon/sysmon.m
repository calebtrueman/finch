/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsysmon: tables of process statistics for pgrep, pkill and the like.
 * macOS's library asks the sysmond daemon (com.apple.sysmond); Finch's builds
 * process tables in the calling process from libproc and sysctl, so there is
 * no daemon and a process sees what its own privileges allow (sysmond runs as
 * root). The object model matches Apple's: OS_object subclasses, a request
 * with a bit array of attributes, and rows whose values sit in an XPC array in
 * attribute order. System-wide and coalition requests (types 2 and 3) report
 * an error.
 */

#import <objc/NSObject.h>
#import <os/object.h>
#import <os/object_private.h>
#include <Block.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <xpc/xpc.h>

#define API __attribute__((visibility("default")))

API const char *SYSMON_XPC_SERVICE_NAME = "com.apple.sysmond";
API const char *SYSMON_XPC_KEY_TYPE = "Type";
API const char *SYSMON_XPC_KEY_ATTRIBUTES = "Attributes";
API const char *SYSMON_XPC_KEY_FLAGS = "Flags";
API const char *SYSMON_XPC_REPLY_KEY_TIMESTAMP = "Timestamp";
API const char *SYSMON_XPC_REPLY_KEY_HEADER = "Header";
API const char *SYSMON_XPC_REPLY_KEY_TABLE = "Table";

/* Attributes per request type (bit-array bytes), as Apple's library sizes them. */
static const size_t attribute_bytes[] = { 10, 5, 2 };

enum {
	ATTR_FLAGS = 1, ATTR_PID = 4, ATTR_PPID = 5, ATTR_UID = 6, ATTR_RUID = 8, ATTR_RGID = 9,
	ATTR_COMM = 12, ATTR_PGID = 15, ATTR_TDEV = 17, ATTR_START = 20, ATTR_ARGUMENTS = 44,
};

/* Layouts follow Apple's object sizes and the field offsets its accessors use. */
struct os_header {
	const void *isa;
	int32_t ref, xref;
};

struct bits {
	size_t size;
	uint8_t data[];
};

struct sysmon_request_s {
	struct os_header os;
	dispatch_queue_t queue;                  /* 0x10 */
	void (^handler)(void *);                 /* 0x18 */
	void (^error_handler)(void *, const char *); /* 0x20 */
	dispatch_source_t timer;                 /* 0x28: Apple's XPC connection */
	void *unused[3];                         /* 0x30 */
	uint64_t type;                           /* 0x48 */
	struct bits *attributes;                 /* 0x50 */
	size_t attribute_bytes;                  /* 0x58 */
	uint64_t flags;                          /* 0x60 */
	uint64_t interval;                       /* 0x68 */
};

struct sysmon_table_s {
	struct os_header os;
	uint64_t timestamp;                      /* 0x10 */
	uint64_t reserved;
	uint64_t count;                          /* 0x20 */
	struct sysmon_row_s **rows;              /* 0x28 */
};

struct sysmon_row_s {
	struct os_header os;
	struct bits *attributes;                 /* 0x10 */
	xpc_object_t values;                     /* 0x18 */
};

/* libdispatch's object runtime, on the plain structs above. */
#define OBJ(p) ((_os_object_t)(void *)(p))
#define OS_RETAIN(p) ((void *)_os_object_retain(OBJ(p)))
#define OS_RELEASE(p) _os_object_release(OBJ(p))

/* OS_object's teardown hook (libdispatch). */
@interface OS_object (FinchSysmon)
- (void)_dispose;
@end

__attribute__((visibility("default")))
@interface OS_sysmon_object : OS_object
@end
@implementation OS_sysmon_object
@end

__attribute__((visibility("default")))
@interface OS_sysmon_request : OS_sysmon_object
@end
@implementation OS_sysmon_request
- (void)_dispose
{
	struct sysmon_request_s *r = (__bridge void *)self;

	if (r->timer) {
		dispatch_source_cancel(r->timer);
		dispatch_release(r->timer);
	}
	if (r->queue)
		dispatch_release(r->queue);
	if (r->handler)
		Block_release(r->handler);
	if (r->error_handler)
		Block_release(r->error_handler);
	free(r->attributes);
	[super _dispose];
}
@end

__attribute__((visibility("default")))
@interface OS_sysmon_table : OS_sysmon_object
@end
@implementation OS_sysmon_table
- (void)_dispose
{
	struct sysmon_table_s *t = (__bridge void *)self;

	for (uint64_t i = 0; i < t->count; i++)
		OS_RELEASE(t->rows[i]);
	free(t->rows);
	[super _dispose];
}
@end

__attribute__((visibility("default")))
@interface OS_sysmon_row : OS_sysmon_object
@end
@implementation OS_sysmon_row
- (void)_dispose
{
	struct sysmon_row_s *r = (__bridge void *)self;

	free(r->attributes);
	if (r->values)
		xpc_release(r->values);
	[super _dispose];
}
@end

API void *
sysmon_request_alloc(void)
{
	return (void *)_os_object_alloc((__bridge void *)[OS_sysmon_request class],
	    sizeof(struct sysmon_request_s));
}

API void *
sysmon_table_alloc(void)
{
	return (void *)_os_object_alloc((__bridge void *)[OS_sysmon_table class],
	    sizeof(struct sysmon_table_s));
}

API void *
sysmon_row_alloc(void)
{
	return (void *)_os_object_alloc((__bridge void *)[OS_sysmon_row class],
	    sizeof(struct sysmon_row_s));
}

API void *
sysmon_retain(void *object)
{
	return OS_RETAIN(object);
}

API void
sysmon_release(void *object)
{
	OS_RELEASE(object);
}

/* ---- requests ---- */

static struct sysmon_request_s *
request_create(uint64_t type)
{
	struct sysmon_request_s *r = sysmon_request_alloc();

	r->type = type;
	r->queue = dispatch_queue_create("com.apple.sysmon.request", DISPATCH_QUEUE_SERIAL);
	return r;
}

API void *
sysmon_request_create(uint64_t type, void (^handler)(void *))
{
	struct sysmon_request_s *r = request_create(type);

	r->handler = Block_copy(handler);
	return r;
}

API void *
sysmon_request_create_with_error(uint64_t type, void (^handler)(void *, const char *))
{
	struct sysmon_request_s *r = request_create(type);

	r->error_handler = Block_copy(handler);
	return r;
}

API void
sysmon_request_add_attribute(struct sysmon_request_s *r, uint32_t attribute)
{
	if (r->attributes == NULL) {
		if (r->type < 1 || r->type > 3)
			return;
		r->attribute_bytes = attribute_bytes[r->type - 1];
		r->attributes = calloc(1, sizeof(struct bits) + r->attribute_bytes);
		if (r->attributes == NULL)
			return;
		r->attributes->size = r->attribute_bytes;
	}
	if (attribute / 8 >= r->attribute_bytes)
		return;   /* Apple's logs this and ignores it */
	r->attributes->data[attribute / 8] |= (uint8_t)(1u << (attribute % 8));
}

API void
sysmon_request_add_attributes(struct sysmon_request_s *r, ...)
{
	va_list ap;
	uint32_t attribute;

	va_start(ap, r);
	while ((attribute = va_arg(ap, uint32_t)) != 0)
		sysmon_request_add_attribute(r, attribute);
	va_end(ap);
}

API void
sysmon_request_set_flags(struct sysmon_request_s *r, uint64_t flags)
{
	r->flags = flags;
}

API void
sysmon_request_set_interval(struct sysmon_request_s *r, uint64_t interval_ms)
{
	uint64_t rounded;

	if (interval_ms < 500) {
		rounded = 500;
	} else {
		/* To the nearest multiple of 500 (ties round up). */
		rounded = interval_ms / 500 * 500;
		if (interval_ms - rounded >= 500 - (interval_ms - rounded))
			rounded += 500;
	}
	r->interval = rounded;
}

/* ---- process tables ---- */

static bool
has(const struct bits *b, uint32_t attribute)
{
	return b != NULL && attribute / 8 < b->size && (b->data[attribute / 8] >> (attribute % 8)) & 1;
}

static xpc_object_t
arguments(pid_t pid)
{
	int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
	size_t size = 0;
	char *buf, *p, *end;
	int argc;
	xpc_object_t array;

	if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int))
		return NULL;
	if ((buf = malloc(size)) == NULL)
		return NULL;
	if (sysctl(mib, 3, buf, &size, NULL, 0) != 0 || size < sizeof(int)) {
		free(buf);
		return NULL;
	}
	memcpy(&argc, buf, sizeof(argc));
	p = buf + sizeof(argc);
	end = buf + size;
	p += strnlen(p, (size_t)(end - p));           /* executable path */
	while (p < end && *p == '\0')
		p++;
	array = xpc_array_create(NULL, 0);
	for (int i = 0; i < argc && p < end; i++) {
		size_t n = strnlen(p, (size_t)(end - p));

		xpc_array_set_string(array, XPC_ARRAY_APPEND, p);
		p += n + 1;
	}
	free(buf);
	return array;
}

/*
 * What a row can say about a process. Unprivileged, full bsdinfo is refused for
 * other users' processes; the short form (same flags, ids and 15-character
 * comm, as sysmond reports them) and the kernel's kinfo_proc (start time,
 * terminal) are not.
 */
struct procinfo {
	pid_t pid;
	bool have;
	uint64_t flags, ppid, pgid, uid, ruid, rgid, tdev;
	char comm[MAXCOMLEN];
	int64_t start_ns;
};

static bool
procinfo(pid_t pid, struct procinfo *pi)
{
	struct proc_bsdinfo bi;
	struct proc_bsdshortinfo si;
	struct kinfo_proc kp;
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
	size_t size = sizeof(kp);

	memset(pi, 0, sizeof(*pi));
	pi->pid = pid;
	if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof(bi)) == sizeof(bi)) {
		pi->flags = bi.pbi_flags;
		pi->ppid = bi.pbi_ppid;
		pi->pgid = bi.pbi_pgid;
		pi->uid = bi.pbi_uid;
		pi->ruid = bi.pbi_ruid;
		pi->rgid = bi.pbi_rgid;
		pi->tdev = (uint32_t)bi.e_tdev;
		memcpy(pi->comm, bi.pbi_comm, sizeof(pi->comm));
		pi->start_ns = (int64_t)bi.pbi_start_tvsec * 1000000000LL + (int64_t)bi.pbi_start_tvusec * 1000;
		return pi->have = true;
	}
	if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof(si)) != sizeof(si) ||
	    sysctl(mib, 4, &kp, &size, NULL, 0) != 0 || size != sizeof(kp))
		return false;
	pi->flags = si.pbsi_flags;
	pi->ppid = si.pbsi_ppid;
	pi->pgid = si.pbsi_pgid;
	pi->uid = si.pbsi_uid;
	pi->ruid = si.pbsi_ruid;
	pi->rgid = si.pbsi_rgid;
	pi->tdev = (uint32_t)kp.kp_eproc.e_tdev;
	memcpy(pi->comm, si.pbsi_comm, sizeof(pi->comm));
	pi->comm[sizeof(pi->comm) - 1] = '\0';
	pi->start_ns = (int64_t)kp.kp_proc.p_starttime.tv_sec * 1000000000LL +
	    (int64_t)kp.kp_proc.p_starttime.tv_usec * 1000;
	return pi->have = true;
}

static xpc_object_t
value(uint32_t attribute, const struct procinfo *pi)
{
	if (attribute == ATTR_PID)
		return xpc_uint64_create((uint64_t)pi->pid);
	if (attribute == ATTR_ARGUMENTS)
		return arguments(pi->pid);
	if (!pi->have)
		return NULL;
	switch (attribute) {
	case ATTR_FLAGS: return xpc_uint64_create(pi->flags);
	case ATTR_PPID: return xpc_uint64_create(pi->ppid);
	case ATTR_UID: return xpc_uint64_create(pi->uid);
	case ATTR_RUID: return xpc_uint64_create(pi->ruid);
	case ATTR_RGID: return xpc_uint64_create(pi->rgid);
	case ATTR_PGID: return xpc_uint64_create(pi->pgid);
	case ATTR_TDEV: return xpc_uint64_create(pi->tdev);
	case ATTR_COMM: return xpc_string_create(pi->comm);
	case ATTR_START: return xpc_date_create(pi->start_ns);
	default: return NULL;   /* not provided without sysmond */
	}
}

static struct sysmon_table_s *
process_table(const struct bits *attributes)
{
	struct sysmon_table_s *t = sysmon_table_alloc();
	int capacity = proc_listallpids(NULL, 0) + 64, n;
	pid_t *pids;

	t->timestamp = mach_absolute_time();
	if (capacity <= 64 || (pids = calloc((size_t)capacity, sizeof(pid_t))) == NULL)
		return t;
	n = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
	t->rows = calloc((size_t)(n > 0 ? n : 1), sizeof(*t->rows));
	for (int i = 0; i < n && t->rows; i++) {
		struct procinfo pi;
		bool have = procinfo(pids[i], &pi);
		struct sysmon_row_s *row;
		size_t bytes = sizeof(struct bits) + (attributes ? attributes->size : 0);

		if (!have && kill(pids[i], 0) != 0 && errno == ESRCH)
			continue;   /* exited meanwhile */
		row = sysmon_row_alloc();
		row->attributes = calloc(1, bytes);
		if (attributes && row->attributes)
			memcpy(row->attributes, attributes, bytes);
		row->values = xpc_array_create(NULL, 0);
		for (uint32_t a = 0; attributes && a < attributes->size * 8; a++) {
			if (!has(attributes, a))
				continue;
			xpc_object_t v = value(a, &pi);

			xpc_array_append_value(row->values, v ? v : xpc_null_create());
			if (v)
				xpc_release(v);
		}
		t->rows[t->count++] = row;
	}
	free(pids);
	return t;
}

static void
deliver(struct sysmon_request_s *r)
{
	if (r->type != 1) {
		if (r->error_handler)
			r->error_handler(NULL, "request type not supported without sysmond");
		else if (r->handler)
			r->handler(NULL);
		return;
	}
	struct sysmon_table_s *t = process_table(r->attributes);

	if (r->error_handler)
		r->error_handler(t, NULL);
	else if (r->handler)
		r->handler(t);
	OS_RELEASE(t);
}

API void
sysmon_request_execute(struct sysmon_request_s *r)
{
	OS_RETAIN(r);
	if (r->interval == 0) {
		dispatch_async(r->queue, ^{
			deliver(r);
			OS_RELEASE(r);
		});
		return;
	}
	r->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, r->queue);
	dispatch_source_set_timer(r->timer, dispatch_time(DISPATCH_TIME_NOW, 0),
	    r->interval * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(r->timer, ^{
		deliver(r);
	});
	dispatch_source_set_cancel_handler(r->timer, ^{
		OS_RELEASE(r);
	});
	dispatch_resume(r->timer);
}

API void
sysmon_request_cancel(struct sysmon_request_s *r)
{
	if (r->timer)
		dispatch_source_cancel(r->timer);
}

/* ---- tables and rows ---- */

API uint64_t
sysmon_table_get_count(struct sysmon_table_s *t)
{
	return t->count;
}

API void *
sysmon_table_get_row(struct sysmon_table_s *t, uint64_t index)
{
	return t->rows[index];
}

API void *
sysmon_table_copy_row(struct sysmon_table_s *t, uint64_t index)
{
	return OS_RETAIN(t->rows[index]);
}

API uint64_t
sysmon_table_get_timestamp(struct sysmon_table_s *t)
{
	return t->timestamp;
}

API void
sysmon_table_apply(struct sysmon_table_s *t, bool (^applier)(void *))
{
	/* As Apple's: every row, whatever the applier returns. */
	for (uint64_t i = 0; i < t->count; i++)
		applier(t->rows[i]);
}

API xpc_object_t
sysmon_row_get_value(struct sysmon_row_s *row, uint32_t attribute)
{
	size_t rank = 0;
	xpc_object_t v;

	if (!has(row->attributes, attribute))
		return NULL;
	for (uint32_t a = 0; a < attribute; a++)
		rank += has(row->attributes, a);
	v = xpc_array_get_value(row->values, rank);
	return v == xpc_null_create() ? NULL : v;
}

API void
sysmon_row_apply(struct sysmon_row_s *row, bool (^applier)(uint32_t, xpc_object_t))
{
	size_t rank = 0;

	for (uint32_t a = 0; row->attributes && a < row->attributes->size * 8; a++) {
		if (!has(row->attributes, a))
			continue;
		xpc_object_t v = xpc_array_get_value(row->values, rank++);

		if (!applier(a, v == xpc_null_create() ? NULL : v))
			break;
	}
}

/* sysmond's server side: there is no sysmond on Finch. */
API xpc_object_t
_sysmon_build_reply_with_diff(void *table, void *previous, uint64_t flags)
{
	(void)table;
	(void)previous;
	(void)flags;
	return NULL;
}
