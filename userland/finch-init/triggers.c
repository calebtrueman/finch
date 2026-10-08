/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Launch-on-demand triggers for finch-init's jobs, with launchd's keys:
 *
 *   StartInterval           start every N seconds
 *   StartCalendarInterval   start when the time matches a dictionary (or any of
 *                           an array of them) of Minute, Hour, Day, Weekday,
 *                           Month; missing keys match anything, as in cron
 *   WatchPaths              start when one of the paths changes
 *   QueueDirectories        start while one of the directories isn't empty
 *   Sockets                 finch-init creates and listens on the sockets, and
 *                           starts the job when one is ready. The job inherits
 *                           them; launch_activate_socket(3) and the check-in
 *                           reply (libxpc) name them by the job's keys.
 *
 * A trigger only starts a job that isn't running (job_start ignores the rest).
 * Everything runs on finch-init's serial queue.
 */

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <dirent.h>
#include <unistd.h>

#include "triggers.h"

#define WATCH_RETRY_SEC 5   /* how often to look for a watched path that doesn't exist yet */

static char **
string_array(xpc_object_t plist, const char *key, bool *ok)
{
	xpc_object_t a = xpc_dictionary_get_value(plist, key);
	char **out;
	size_t n;

	if (a == NULL) {
		return NULL;
	}
	if (xpc_get_type(a) == XPC_TYPE_STRING) {   /* launchd accepts a single string */
		out = calloc(2, sizeof(char *));
		out[0] = strdup(xpc_string_get_string_ptr(a));
		return out;
	}
	if (xpc_get_type(a) != XPC_TYPE_ARRAY) {
		*ok = false;
		return NULL;
	}
	n = xpc_array_get_count(a);
	out = calloc(n + 1, sizeof(char *));
	for (size_t i = 0, k = 0; i < n; i++) {
		const char *p = xpc_array_get_string(a, i);
		if (p != NULL) out[k++] = strdup(p);
	}
	return out;
}

static void
free_strings(char **a)
{
	for (char **p = a; p && *p; p++) free(*p);
	free(a);
}

#pragma mark - Parsing

bool
triggers_parse(struct job *j, xpc_object_t plist)
{
	xpc_object_t cal = xpc_dictionary_get_value(plist, "StartCalendarInterval");
	xpc_object_t socks = xpc_dictionary_get_value(plist, "Sockets");
	bool ok = true;

	j->start_interval = (int)xpc_dictionary_get_int64(plist, "StartInterval");
	if (cal != NULL && xpc_get_type(cal) == XPC_TYPE_DICTIONARY) {
		j->calendar = xpc_array_create(&cal, 1);
	} else if (cal != NULL && xpc_get_type(cal) == XPC_TYPE_ARRAY) {
		j->calendar = xpc_retain(cal);
	} else if (cal != NULL) {
		ok = false;
	}
	j->watch_paths = string_array(plist, "WatchPaths", &ok);
	j->queue_dirs = string_array(plist, "QueueDirectories", &ok);
	if (socks != NULL && xpc_get_type(socks) == XPC_TYPE_DICTIONARY) {
		/* Only the names here; the sockets are created when the job is armed. */
		j->sockets = calloc(xpc_dictionary_get_count(socks), sizeof(struct job_socket));
		xpc_dictionary_apply(socks, ^bool(const char *name, xpc_object_t value) {
			(void)value;
			j->sockets[j->nsockets++].name = strdup(name);
			return true;
		});
	} else if (socks != NULL) {
		ok = false;
	}
	if (!ok) {
		log_fn("%s: invalid launch trigger keys", j->label);
	}
	return ok;
}

void
triggers_free(struct job *j)
{
	if (j->calendar) xpc_release(j->calendar);
	free_strings(j->watch_paths);
	free_strings(j->queue_dirs);
	for (size_t i = 0; i < j->nsockets; i++) {
		free(j->sockets[i].name);
		free(j->sockets[i].fds);
		for (size_t k = 0; j->sockets[i].unlink_paths && k < j->sockets[i].nfds; k++) {
			free(j->sockets[i].unlink_paths[k]);
		}
		free(j->sockets[i].unlink_paths);
	}
	free(j->sockets);
	free(j->sources);
	free(j->socket_sources);
}

#pragma mark - Sockets

static int
sock_type(xpc_object_t d)
{
	const char *t = xpc_dictionary_get_string(d, "SockType");

	if (t == NULL || strcmp(t, "stream") == 0) return SOCK_STREAM;
	if (strcmp(t, "dgram") == 0) return SOCK_DGRAM;
	if (strcmp(t, "seqpacket") == 0) return SOCK_SEQPACKET;
	return -1;
}

static void
add_fd(struct job_socket *s, int fd, const char *unlink_path)
{
	s->fds = realloc(s->fds, (s->nfds + 1) * sizeof(int));
	s->unlink_paths = realloc(s->unlink_paths, (s->nfds + 1) * sizeof(char *));
	s->fds[s->nfds] = fd;
	s->unlink_paths[s->nfds] = unlink_path ? strdup(unlink_path) : NULL;
	s->nfds++;
}

/* One socket description (a dictionary of launchd's Sock* keys). */
static void
create_socket(struct job *j, struct job_socket *s, xpc_object_t d)
{
	int type = sock_type(d), fd;
	bool passive = xpc_dictionary_get_value(d, "SockPassive") == NULL ||
	    xpc_dictionary_get_bool(d, "SockPassive");
	const char *path = xpc_dictionary_get_string(d, "SockPathName");
	const char *family = xpc_dictionary_get_string(d, "SockFamily");

	if (type < 0 || !passive) {
		log_fn("%s: socket %s: only passive stream/dgram/seqpacket sockets are supported",
		    j->label, s->name);
		return;
	}
	if (path != NULL || (family && strcmp(family, "Unix") == 0)) {
		struct sockaddr_un sun = { .sun_family = AF_UNIX };
		if (path == NULL || strlen(path) >= sizeof(sun.sun_path)) {
			log_fn("%s: socket %s: bad SockPathName", j->label, s->name);
			return;
		}
		strlcpy(sun.sun_path, path, sizeof(sun.sun_path));
		sun.sun_len = (unsigned char)SUN_LEN(&sun);
		if ((fd = socket(AF_UNIX, type, 0)) < 0) {
			log_fn("%s: socket %s: %s", j->label, s->name, strerror(errno));
			return;
		}
		unlink(path);
		if (bind(fd, (struct sockaddr *)&sun, sun.sun_len) != 0 ||
		    (type != SOCK_DGRAM && listen(fd, SOMAXCONN) != 0)) {
			log_fn("%s: socket %s: %s: %s", j->label, s->name, path, strerror(errno));
			close(fd);
			return;
		}
		if (xpc_dictionary_get_value(d, "SockPathMode") != NULL) {
			chmod(path, (mode_t)xpc_dictionary_get_int64(d, "SockPathMode"));
		}
		fcntl(fd, F_SETFD, FD_CLOEXEC);
		add_fd(s, fd, path);
		return;
	}

	/* Internet: SockNodeName (default any), SockServiceName (name or number). */
	struct addrinfo hints = { .ai_flags = AI_PASSIVE, .ai_socktype = type }, *res, *ai;
	char port[32];
	const char *service = xpc_dictionary_get_string(d, "SockServiceName");
	xpc_object_t svc = xpc_dictionary_get_value(d, "SockServiceName");
	int err;

	if (service == NULL && svc != NULL && xpc_get_type(svc) == XPC_TYPE_INT64) {
		snprintf(port, sizeof(port), "%lld", (long long)xpc_int64_get_value(svc));
		service = port;
	}
	hints.ai_family = family == NULL ? AF_UNSPEC : strcmp(family, "IPv4") == 0 ? AF_INET :
	    strcmp(family, "IPv6") == 0 ? AF_INET6 : AF_UNSPEC;
	if (service == NULL) {
		log_fn("%s: socket %s: no SockServiceName or SockPathName", j->label, s->name);
		return;
	}
	if ((err = getaddrinfo(xpc_dictionary_get_string(d, "SockNodeName"), service, &hints, &res)) != 0) {
		log_fn("%s: socket %s: %s", j->label, s->name, gai_strerror(err));
		return;
	}
	for (ai = res; ai != NULL; ai = ai->ai_next) {
		int one = 1;
		if ((fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol)) < 0) {
			continue;
		}
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		if (ai->ai_family == AF_INET6) {
			setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one));
		}
		if (bind(fd, ai->ai_addr, ai->ai_addrlen) != 0 ||
		    (type != SOCK_DGRAM && listen(fd, SOMAXCONN) != 0)) {
			log_fn("%s: socket %s: %s", j->label, s->name, strerror(errno));
			close(fd);
			continue;
		}
		fcntl(fd, F_SETFD, FD_CLOEXEC);
		add_fd(s, fd, NULL);
	}
	freeaddrinfo(res);
}

static void
listen_sockets(struct job *j, bool on)
{
	if (j->sockets_listening == on) {
		return;
	}
	for (size_t i = 0; i < j->nsocket_sources; i++) {
		if (on) dispatch_resume(j->socket_sources[i]);
		else dispatch_suspend(j->socket_sources[i]);
	}
	j->sockets_listening = on;
}

static void
arm_sockets(struct job *j, xpc_object_t plist_sockets)
{
	size_t total = 0;

	for (size_t i = 0; i < j->nsockets; i++) {
		struct job_socket *s = &j->sockets[i];
		xpc_object_t v = xpc_dictionary_get_value(plist_sockets, s->name);
		if (v != NULL && xpc_get_type(v) == XPC_TYPE_ARRAY) {
			for (size_t k = 0; k < xpc_array_get_count(v); k++) {
				create_socket(j, s, xpc_array_get_value(v, k));
			}
		} else if (v != NULL && xpc_get_type(v) == XPC_TYPE_DICTIONARY) {
			create_socket(j, s, v);
		}
		total += s->nfds;
	}
	j->socket_sources = calloc(total ? total : 1, sizeof(dispatch_source_t));
	for (size_t i = 0; i < j->nsockets; i++) {
		for (size_t k = 0; k < j->sockets[i].nfds; k++) {
			dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
			    (uintptr_t)j->sockets[i].fds[k], 0, queue);
			int fd = j->sockets[i].fds[k];
			dispatch_source_set_event_handler(src, ^{
				if (!j->unloading) job_start(j);
			});
			dispatch_source_set_cancel_handler(src, ^{
				close(fd);
			});
			j->socket_sources[j->nsocket_sources++] = src;   /* created suspended */
		}
	}
	listen_sockets(j, j->pid <= 0);
}

void
triggers_inherit(struct job *j, posix_spawn_file_actions_t *fa)
{
	for (size_t i = 0; i < j->nsockets; i++) {
		for (size_t k = 0; k < j->sockets[i].nfds; k++) {
			posix_spawn_file_actions_addinherit_np(fa, j->sockets[i].fds[k]);
		}
	}
}

#pragma mark - Timers and watchers

static void
add_source(struct job *j, dispatch_source_t src)
{
	j->sources = realloc(j->sources, (j->nsources + 1) * sizeof(dispatch_source_t));
	j->sources[j->nsources++] = src;
	dispatch_resume(src);
}

static bool
calendar_matches(xpc_object_t entry, const struct tm *tm)
{
	static const struct { const char *key; int offset; } fields[] = {
		{ "Minute", offsetof(struct tm, tm_min) }, { "Hour", offsetof(struct tm, tm_hour) },
		{ "Day", offsetof(struct tm, tm_mday) }, { "Weekday", offsetof(struct tm, tm_wday) },
		{ "Month", offsetof(struct tm, tm_mon) },
	};

	if (xpc_get_type(entry) != XPC_TYPE_DICTIONARY) {
		return false;
	}
	for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
		xpc_object_t v = xpc_dictionary_get_value(entry, fields[i].key);
		int now = *(const int *)((const char *)tm + fields[i].offset), want;
		if (v == NULL) continue;
		want = (int)xpc_int64_get_value(v);
		if (strcmp(fields[i].key, "Month") == 0) now += 1;              /* 1-12 */
		if (strcmp(fields[i].key, "Weekday") == 0 && want == 7) want = 0; /* 0 and 7 are Sunday */
		if (want != now) return false;
	}
	return true;
}

static bool
directory_has_entries(const char *path)
{
	DIR *d = opendir(path);
	struct dirent *e;
	bool found = false;

	if (d == NULL) return false;
	while (!found && (e = readdir(d)) != NULL) {
		found = strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0;
	}
	closedir(d);
	return found;
}

static bool
queue_nonempty(struct job *j)
{
	for (char **p = j->queue_dirs; p && *p; p++) {
		if (directory_has_entries(*p)) return true;
	}
	return false;
}

static void watch_path(struct job *j, const char *path, bool queue_dir, bool appeared);

/* Watch `path` (a WatchPaths entry or a queue directory). If it doesn't exist,
 * look again every few seconds; if it's replaced, watch the new one. A path
 * that appears counts as a change (`appeared`). */
static void
watch_path(struct job *j, const char *path, bool queue_dir, bool appeared)
{
	int fd = open(path, O_EVTONLY | O_CLOEXEC);
	char *copy = strdup(path);

	if (fd < 0) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, WATCH_RETRY_SEC * NSEC_PER_SEC), queue, ^{
			if (!j->unloading) watch_path(j, copy, queue_dir, true);
			free(copy);
		});
		return;
	}
	dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
	    DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB |
	    DISPATCH_VNODE_LINK | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
	    queue);
	dispatch_source_set_event_handler(src, ^{
		unsigned long what = dispatch_source_get_data(src);
		if (j->unloading) return;
		if (!queue_dir || directory_has_entries(copy)) job_start(j);
		if (what & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
			/* The path now names something else (or nothing): watch it afresh. */
			dispatch_source_cancel(src);
			watch_path(j, copy, queue_dir, true);
		}
	});
	dispatch_source_set_cancel_handler(src, ^{
		close(fd);
	});
	add_source(j, src);
	if (appeared && (!queue_dir || directory_has_entries(copy))) {
		job_start(j);
	}
}

void
triggers_arm(struct job *j)
{
	if (j->start_interval > 0) {
		dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
		uint64_t interval = (uint64_t)j->start_interval * NSEC_PER_SEC;
		dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval,
		    NSEC_PER_SEC / 10);
		dispatch_source_set_event_handler(t, ^{
			if (!j->unloading) job_start(j);
		});
		add_source(j, t);
	}
	if (j->calendar != NULL) {
		/* Check at the start of every minute. */
		dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
		time_t now = time(NULL);
		dispatch_source_set_timer(t, dispatch_walltime(&(struct timespec){ now - now % 60 + 60, 0 }, 0),
		    60 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
		dispatch_source_set_event_handler(t, ^{
			time_t at = time(NULL);
			struct tm tm;
			localtime_r(&at, &tm);
			for (size_t i = 0; !j->unloading && i < xpc_array_get_count(j->calendar); i++) {
				if (calendar_matches(xpc_array_get_value(j->calendar, i), &tm)) {
					job_start(j);
					break;
				}
			}
		});
		add_source(j, t);
	}
	for (char **p = j->watch_paths; p && *p; p++) {
		watch_path(j, *p, false, false);
	}
	for (char **p = j->queue_dirs; p && *p; p++) {
		watch_path(j, *p, true, false);
	}
	if (j->nsockets > 0) {
		/* The socket descriptions are in the plist, which jobs.c doesn't keep. */
		xpc_object_t plist = NULL;
		int fd = open(j->path, O_RDONLY | O_CLOEXEC);
		struct stat st;
		if (fd >= 0 && fstat(fd, &st) == 0 && st.st_size > 0 && st.st_size < (1 << 20)) {
			char *buf = malloc((size_t)st.st_size);
			if (buf && read(fd, buf, (size_t)st.st_size) == st.st_size) {
				extern xpc_object_t xpc_create_from_plist(const void *, size_t);
				plist = xpc_create_from_plist(buf, (size_t)st.st_size);
			}
			free(buf);
		}
		if (fd >= 0) close(fd);
		if (plist != NULL) {
			arm_sockets(j, xpc_dictionary_get_value(plist, "Sockets"));
			xpc_release(plist);
		}
	}
	if (queue_nonempty(j)) {
		job_start(j);
	}
}

void
triggers_disarm(struct job *j)
{
	for (size_t i = 0; i < j->nsources; i++) {
		dispatch_source_cancel(j->sources[i]);
		dispatch_release(j->sources[i]);
	}
	j->nsources = 0;
	listen_sockets(j, true);   /* a suspended source can't be released */
	for (size_t i = 0; i < j->nsocket_sources; i++) {
		dispatch_source_cancel(j->socket_sources[i]);
		dispatch_release(j->socket_sources[i]);
	}
	j->nsocket_sources = 0;
	for (size_t i = 0; i < j->nsockets; i++) {
		struct job_socket *s = &j->sockets[i];
		for (size_t k = 0; k < s->nfds; k++) {
			if (s->unlink_paths[k]) unlink(s->unlink_paths[k]);   /* closed by its source's cancel handler */
		}
		s->nfds = 0;
	}
}

void
triggers_started(struct job *j)
{
	listen_sockets(j, false);   /* the job handles its sockets now */
}

void
triggers_exited(struct job *j)
{
	if (j->unloading) {
		return;
	}
	listen_sockets(j, true);
	/* launchd keeps starting a QueueDirectories job while its queue isn't empty. */
	if (j->pid <= 0 && queue_nonempty(j)) {
		job_start(j);
	}
}

void
triggers_describe(struct job *j, xpc_object_t d)
{
	if (j->nsockets > 0) {
		xpc_object_t socks = xpc_dictionary_create(NULL, NULL, 0);
		for (size_t i = 0; i < j->nsockets; i++) {
			xpc_object_t fds = xpc_array_create(NULL, 0);
			for (size_t k = 0; k < j->sockets[i].nfds; k++) {
				xpc_array_set_int64(fds, XPC_ARRAY_APPEND, j->sockets[i].fds[k]);
			}
			xpc_dictionary_set_value(socks, j->sockets[i].name, fds);
			xpc_release(fds);
		}
		xpc_dictionary_set_value(d, "sockets", socks);
		xpc_release(socks);
	}
	if (j->start_interval > 0) {
		xpc_dictionary_set_int64(d, "start_interval", j->start_interval);
	}
	if (j->calendar != NULL) {
		xpc_dictionary_set_value(d, "calendar", j->calendar);
	}
}
