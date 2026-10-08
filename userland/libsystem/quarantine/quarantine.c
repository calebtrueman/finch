/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libquarantine: Finch's implementation of Apple's quarantine API.
 *
 * Files. A file's quarantine record is the com.apple.quarantine extended
 * attribute: "FFFF;TTTTTTTT;agent;metadata" (hex flags < 0x2000, hex
 * timestamp, the agent that downloaded it, then everything else, usually an
 * event UUID). The serialized form (qtn_file_to_data / _init_with_data) is the
 * same text as a MAC label, prefixed "q/". The agent and metadata are escaped
 * as \xHH for control bytes, bytes >= 0x7f, space and " $ , / : ; [ \ ] { }.
 * Decoding turns \xHH into the byte and any other backslash into '?'.
 * Behavior, limits and errors match macOS 26.4's library; tests/qtn-compare.c
 * checks them against it.
 *
 * Applying a record writes the attribute as given. Apple's library applies it
 * through the closed Quarantine kernel policy, which also stamps the current
 * time, sets the agent from the calling app and adds policy flags (0x80,
 * 0x200). Finch has no quarantine policy yet (FINCH-NOT-YET).
 *
 * Processes. Process quarantine (files a process creates are quarantined
 * automatically) lives in Apple's closed Quarantine kernel policy. Finch can't
 * apply it yet: process objects work in memory, but no process is quarantined
 * and applying one fails with ENOTSUP (FINCH-NOT-YET).
 *
 * Responsibility (which app a helper process works for) is tracked by the
 * same kernel policy. On Finch every process is responsible for itself.
 */

#include <errno.h>
#include <pthread.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/xattr.h>
#include <unistd.h>

#define QTN_NOT_QUARANTINED   (-1)
#define QTN_FLAGS_LIMIT       0x2000
#define QTN_ID_MAX            256
#define QTN_METADATA_MAX      64
#define QTN_SERIALIZED_MAX    4096

const char _qtn_label_name[] = "q";
const char _qtn_xattr_name[] = "com.apple.quarantine";

struct qtn_record {
	uint32_t flags;
	uint64_t timestamp;
	char identifier[QTN_ID_MAX];
	uint8_t metadata[QTN_METADATA_MAX + 1];   /* NUL after the bytes, for C-string callers */
	size_t metadata_size;
};

typedef struct qtn_record *qtn_file_t;
typedef struct qtn_record *qtn_proc_t;

#pragma mark - Text form

static bool
needs_escape(uint8_t c)
{
	return c < 0x21 || c >= 0x7f || strchr("\"$,/:;[\\]{}", c) != NULL;
}

/* Append `n` bytes of `s`, escaped; false if it doesn't fit. */
static bool
put_escaped(char *out, size_t size, size_t *pos, const uint8_t *s, size_t n)
{
	static const char hex[] = "0123456789abcdef";
	for (size_t i = 0; i < n; i++) {
		if (needs_escape(s[i])) {
			if (*pos + 4 >= size) return false;
			out[(*pos)++] = '\\';
			out[(*pos)++] = 'x';
			out[(*pos)++] = hex[s[i] >> 4];
			out[(*pos)++] = hex[s[i] & 15];
		} else {
			if (*pos + 1 >= size) return false;
			out[(*pos)++] = (char)s[i];
		}
	}
	return true;
}

static int
hexval(int c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

/* Decode [s, end) into out (up to max bytes); -1 if it doesn't fit. */
static ssize_t
unescape(const char *s, const char *end, uint8_t *out, size_t max)
{
	size_t n = 0;
	while (s < end) {
		uint8_t c = (uint8_t)*s++;
		if (c == '\\') {
			if (end - s >= 3 && s[0] == 'x' && hexval(s[1]) >= 0 && hexval(s[2]) >= 0) {
				c = (uint8_t)(hexval(s[1]) << 4 | hexval(s[2]));
				s += 3;
			} else {
				c = '?';
			}
		}
		if (n >= max) return -1;
		out[n++] = c;
	}
	return (ssize_t)n;
}

/*
 * scanf("%<width>x")-style: skip spaces (not counted), then up to `width`
 * characters of optional sign, optional 0x, hex digits. Stores the value as a
 * 32-bit unsigned (negative values wrap) and advances *p; false if no digit.
 */
static bool
scan_hex(const char **p, const char *end, int width, uint32_t *v)
{
	const char *s = *p;
	bool neg = false, digits = false;
	uint32_t val = 0;

	while (s < end && (*s == ' ' || (*s >= '\t' && *s <= '\r'))) s++;
	if (width > 0 && s < end && (*s == '+' || *s == '-')) {
		neg = *s == '-';
		s++;
		width--;
	}
	if (width >= 2 && end - s >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		s += 2;
		width -= 2;
		digits = true;   /* the 0 counts, as with scanf */
	}
	for (; width > 0 && s < end && hexval(*s) >= 0; s++, width--) {
		val = val << 4 | (uint32_t)hexval(*s);
		digits = true;
	}
	if (!digits) return false;
	*v = neg ? (uint32_t)-val : val;
	*p = s;
	return true;
}

/*
 * A record, as macOS 26.4's libquarantine reads it: "FFFF;TTTTTTTT" (flags
 * and timestamp, scanf-style %4x and %8x), then ";agent;metadata". If the
 * timestamp isn't followed by ';', "agent;metadata" is read from the start of
 * the label instead (so the agent is "q/<flags>"). Flags of 0 read as 1.
 */
static int
parse_record(struct qtn_record *r, const char *label, size_t len)
{
	const char *end = label + len, *s = label + 2, *semi;
	uint32_t flags, ts;
	ssize_t n;
	struct qtn_record t;

	/* As Apple's: a failed parse leaves the record reset (flags 0x0001,
	 * everything else empty); a successful one replaces it whole. */
	memset(r, 0, sizeof(*r));
	r->flags = 1;
	memset(&t, 0, sizeof(t));
	if (!scan_hex(&s, end, 4, &flags) || s >= end || *s != ';') return EINVAL;
	s++;
	if (!scan_hex(&s, end, 8, &ts)) return EINVAL;
	if (flags >= QTN_FLAGS_LIMIT) return EINVAL;
	t.flags = flags ? flags : 1;
	t.timestamp = ts;
	/* "agent;metadata" follows the timestamp's ';'; without one (a legacy
	 * record) it's read from the start of the label. */
	s = (s < end && *s == ';') ? s + 1 : label;
	if ((semi = memchr(s, ';', (size_t)(end - s))) == NULL) return EINVAL;
	if ((n = unescape(s, semi, (uint8_t *)t.identifier, QTN_ID_MAX - 1)) < 0) return ERANGE;
	t.identifier[n] = '\0';
	if ((n = unescape(semi + 1, end, t.metadata, QTN_METADATA_MAX)) < 0) return ERANGE;
	t.metadata_size = (size_t)n;
	t.metadata[n] = '\0';
	*r = t;
	return 0;
}

/* The record as text, without "q/"; returns its length, or -1 if it doesn't fit. */
static ssize_t
unparse_record(const struct qtn_record *r, char *out, size_t size)
{
	/* As Apple's: only the low 32 bits of the timestamp are written. */
	int n = snprintf(out, size, "%04x;%08x;", r->flags, (uint32_t)r->timestamp);
	size_t pos;
	if (n < 0 || (size_t)n >= size) return -1;
	pos = (size_t)n;
	if (!put_escaped(out, size, &pos, (const uint8_t *)r->identifier, strlen(r->identifier))) return -1;
	if (pos + 1 >= size) return -1;
	out[pos++] = ';';
	if (!put_escaped(out, size, &pos, r->metadata, r->metadata_size)) return -1;
	out[pos] = '\0';
	return (ssize_t)pos;
}

#pragma mark - Errors

const char *_qtn_error(int code);

const char *
_qtn_error(int code)
{
	return code == QTN_NOT_QUARANTINED ? "Item not quarantined" : strerror(code);
}

#pragma mark - File objects

static struct qtn_record *
record_alloc(void)
{
	struct qtn_record *r = calloc(1, sizeof(*r));
	return r;   /* as Apple's: all zero */
}

qtn_file_t _qtn_file_alloc(void);
void _qtn_file_free(qtn_file_t qf);
qtn_file_t _qtn_file_clone(qtn_file_t qf);
int _qtn_file_init(qtn_file_t qf);
int _qtn_file_init_with_data(qtn_file_t qf, const void *data, size_t len);
int _qtn_file_to_data(qtn_file_t qf, char *buf, size_t *len);
uint32_t _qtn_file_get_flags(qtn_file_t qf);
int _qtn_file_set_flags(qtn_file_t qf, uint32_t flags);
uint64_t _qtn_file_get_timestamp(qtn_file_t qf);
int _qtn_file_set_timestamp(qtn_file_t qf, uint64_t ts);
const char *_qtn_file_get_identifier(qtn_file_t qf);
int _qtn_file_set_identifier(qtn_file_t qf, const char *identifier);
const void *_qtn_file_get_metadata(qtn_file_t qf);
size_t _qtn_file_get_metadata_size(qtn_file_t qf);
int _qtn_file_set_metadata(qtn_file_t qf, const void *data, size_t len);

qtn_file_t _qtn_file_alloc(void) { return record_alloc(); }
void _qtn_file_free(qtn_file_t qf) { free(qf); }

qtn_file_t
_qtn_file_clone(qtn_file_t qf)
{
	qtn_file_t c = malloc(sizeof(*c));
	if (c) *c = *qf;
	return c;
}

int
_qtn_file_init(qtn_file_t qf)
{
	memset(qf, 0, sizeof(*qf));
	return 0;
}

int
_qtn_file_init_with_data(qtn_file_t qf, const void *data, size_t len)
{
	const char *s = data;
	if (len < 2 || s[0] != 'q' || s[1] != '/') {
		memset(qf, 0, sizeof(*qf));   /* reset, as parse_record does */
		qf->flags = 1;
		return EINVAL;
	}
	/* Serialized data may carry a trailing NUL (to_data counts one). */
	if (len > 2 && s[len - 1] == '\0') len--;
	return parse_record(qf, s, len);
}

int
_qtn_file_to_data(qtn_file_t qf, char *buf, size_t *len)
{
	char text[QTN_SERIALIZED_MAX];
	ssize_t n = unparse_record(qf, text, sizeof(text));
	if (n < 0 || (size_t)n + 2 >= *len) {
		*len = n < 0 ? 0 : (size_t)n + 3;
		return ERANGE;
	}
	buf[0] = 'q';
	buf[1] = '/';
	memcpy(buf + 2, text, (size_t)n + 1);
	*len = (size_t)n + 3;   /* as Apple's: length including the NUL */
	return 0;
}

uint32_t _qtn_file_get_flags(qtn_file_t qf) { return qf->flags; }

int
_qtn_file_set_flags(qtn_file_t qf, uint32_t flags)
{
	if (flags >= QTN_FLAGS_LIMIT) return EINVAL;
	qf->flags = flags;
	return 0;
}

uint64_t _qtn_file_get_timestamp(qtn_file_t qf) { return qf->timestamp; }
int _qtn_file_set_timestamp(qtn_file_t qf, uint64_t ts) { qf->timestamp = ts; return 0; }
const char *_qtn_file_get_identifier(qtn_file_t qf) { return qf->identifier; }

int
_qtn_file_set_identifier(qtn_file_t qf, const char *identifier)
{
	if (strlcpy(qf->identifier, identifier, sizeof(qf->identifier)) >= sizeof(qf->identifier)) {
		qf->identifier[0] = '\0';
		return ERANGE;
	}
	return 0;
}

const void *_qtn_file_get_metadata(qtn_file_t qf) { return qf->metadata; }
size_t _qtn_file_get_metadata_size(qtn_file_t qf) { return qf->metadata_size; }

int
_qtn_file_set_metadata(qtn_file_t qf, const void *data, size_t len)
{
	qf->metadata_size = 0;
	if (len > QTN_METADATA_MAX) return ERANGE;
	memcpy(qf->metadata, data, len);
	qf->metadata[len] = '\0';
	qf->metadata_size = len;
	return 0;
}

#pragma mark - Files on disk (the com.apple.quarantine attribute)

/* The attribute is the label without its "q/". */
static int
from_xattr(qtn_file_t qf, ssize_t n, const char *buf)
{
	char label[QTN_SERIALIZED_MAX + 2];
	if (n < 0) {
		/* As Apple's: only a path that can't be resolved is an error; any
		 * other failure to read the attribute means "not quarantined". */
		switch (errno) {
		case ENOENT: case ENOTDIR: case ENAMETOOLONG: case ELOOP: case EACCES: case EBADF:
			return errno;
		default:
			return QTN_NOT_QUARANTINED;
		}
	}
	if (n > 0 && buf[n - 1] == '\0') n--;
	label[0] = 'q';
	label[1] = '/';
	memcpy(label + 2, buf, (size_t)n);
	return parse_record(qf, label, (size_t)n + 2);
}

int _qtn_file_init_with_fd(qtn_file_t qf, int fd);
int _qtn_file_init_with_path(qtn_file_t qf, const char *path);
int _qtn_file_init_with_mount_point(qtn_file_t qf, const char *path);
int _qtn_file_init_with_disk_image_backing_store(qtn_file_t qf, const char *path);
int _qtn_file_apply_to_fd(qtn_file_t qf, int fd);
int _qtn_file_apply_to_path(qtn_file_t qf, const char *path);
int _qtn_file_apply_to_mount_point(qtn_file_t qf, const char *path);

int
_qtn_file_init_with_fd(qtn_file_t qf, int fd)
{
	char buf[QTN_SERIALIZED_MAX];
	return from_xattr(qf, fgetxattr(fd, _qtn_xattr_name, buf, sizeof(buf), 0, 0), buf);
}

int
_qtn_file_init_with_path(qtn_file_t qf, const char *path)
{
	char buf[QTN_SERIALIZED_MAX];
	return from_xattr(qf, getxattr(path, _qtn_xattr_name, buf, sizeof(buf), 0, 0), buf);
}

int
_qtn_file_apply_to_fd(qtn_file_t qf, int fd)
{
	char text[QTN_SERIALIZED_MAX];
	ssize_t n = unparse_record(qf, text, sizeof(text));
	if (n < 0) return ERANGE;
	return fsetxattr(fd, _qtn_xattr_name, text, (size_t)n, 0, 0) == 0 ? 0 : errno;
}

int
_qtn_file_apply_to_path(qtn_file_t qf, const char *path)
{
	char text[QTN_SERIALIZED_MAX];
	ssize_t n = unparse_record(qf, text, sizeof(text));
	if (n < 0) return ERANGE;
	return setxattr(path, _qtn_xattr_name, text, (size_t)n, 0, 0) == 0 ? 0 : errno;
}

/* Volume-wide quarantine (mounted disk images) is kept by the kernel policy:
 * FINCH-NOT-YET. No volume is quarantined. */
int _qtn_file_init_with_mount_point(qtn_file_t qf, const char *p) { (void)qf; (void)p; return QTN_NOT_QUARANTINED; }
int _qtn_file_init_with_disk_image_backing_store(qtn_file_t qf, const char *p) { (void)qf; (void)p; return QTN_NOT_QUARANTINED; }
int _qtn_file_apply_to_mount_point(qtn_file_t qf, const char *p) { (void)qf; (void)p; return ENOTSUP; }

#pragma mark - Process quarantine (kernel policy: FINCH-NOT-YET)

qtn_proc_t _qtn_proc_alloc(void);
void _qtn_proc_free(qtn_proc_t qp);
qtn_proc_t _qtn_proc_clone(qtn_proc_t qp);
int _qtn_proc_init(qtn_proc_t qp);
int _qtn_proc_init_with_self(qtn_proc_t qp);
int qtn_proc_init_with_pid(qtn_proc_t qp, pid_t pid);
int _qtn_proc_init_with_data(qtn_proc_t qp, const void *data, size_t len);
int _qtn_proc_to_data(qtn_proc_t qp, char *buf, size_t *len);
int _qtn_proc_apply_to_self(qtn_proc_t qp);
int _qtn_proc_apply_to_pid(qtn_proc_t qp, pid_t pid);
uint32_t _qtn_proc_get_flags(qtn_proc_t qp);
int _qtn_proc_set_flags(qtn_proc_t qp, uint32_t flags);
const char *_qtn_proc_get_identifier(qtn_proc_t qp);
int _qtn_proc_set_identifier(qtn_proc_t qp, const char *identifier);
const void *_qtn_proc_get_metadata(qtn_proc_t qp);
size_t _qtn_proc_get_metadata_size(qtn_proc_t qp);
int _qtn_proc_set_metadata(qtn_proc_t qp, const void *data, size_t len);
const char *_qtn_proc_get_path_exclusion_pattern(qtn_proc_t qp);
int _qtn_proc_set_path_exclusion_pattern(qtn_proc_t qp, const char *pattern);
const void *_qtn_proc_get_tracking_data(qtn_proc_t qp);
size_t _qtn_proc_get_tracking_size(qtn_proc_t qp);
int _qtn_proc_set_tracking_data(qtn_proc_t qp, const void *data, size_t len);

qtn_proc_t _qtn_proc_alloc(void) { return record_alloc(); }
void _qtn_proc_free(qtn_proc_t qp) { free(qp); }
qtn_proc_t _qtn_proc_clone(qtn_proc_t qp) { return _qtn_file_clone(qp); }
int _qtn_proc_init(qtn_proc_t qp) { return _qtn_file_init(qp); }
int _qtn_proc_init_with_self(qtn_proc_t qp) { (void)qp; return QTN_NOT_QUARANTINED; }
int qtn_proc_init_with_pid(qtn_proc_t qp, pid_t pid) { (void)qp; (void)pid; return QTN_NOT_QUARANTINED; }
int _qtn_proc_init_with_data(qtn_proc_t qp, const void *d, size_t len) { return _qtn_file_init_with_data(qp, d, len); }
int _qtn_proc_to_data(qtn_proc_t qp, char *buf, size_t *len) { return _qtn_file_to_data(qp, buf, len); }
int _qtn_proc_apply_to_self(qtn_proc_t qp) { (void)qp; return ENOTSUP; }
int _qtn_proc_apply_to_pid(qtn_proc_t qp, pid_t pid) { (void)qp; (void)pid; return ENOTSUP; }
uint32_t _qtn_proc_get_flags(qtn_proc_t qp) { return qp->flags; }
int _qtn_proc_set_flags(qtn_proc_t qp, uint32_t f) { return _qtn_file_set_flags(qp, f); }
const char *_qtn_proc_get_identifier(qtn_proc_t qp) { return qp->identifier; }
int _qtn_proc_set_identifier(qtn_proc_t qp, const char *id) { return _qtn_file_set_identifier(qp, id); }
const void *_qtn_proc_get_metadata(qtn_proc_t qp) { return qp->metadata; }
size_t _qtn_proc_get_metadata_size(qtn_proc_t qp) { return qp->metadata_size; }
int _qtn_proc_set_metadata(qtn_proc_t qp, const void *d, size_t len) { return _qtn_file_set_metadata(qp, d, len); }
const char *_qtn_proc_get_path_exclusion_pattern(qtn_proc_t qp) { (void)qp; return NULL; }
int _qtn_proc_set_path_exclusion_pattern(qtn_proc_t qp, const char *p) { (void)qp; (void)p; return ENOTSUP; }
const void *_qtn_proc_get_tracking_data(qtn_proc_t qp) { (void)qp; return NULL; }
size_t _qtn_proc_get_tracking_size(qtn_proc_t qp) { (void)qp; return 0; }
int _qtn_proc_set_tracking_data(qtn_proc_t qp, const void *d, size_t len) { (void)qp; (void)d; (void)len; return ENOTSUP; }

/* Tracking data carried across posix_spawn: none. */
int qtn_spawnattrs_get_tracking_data(void *attr, void *data, size_t *len);
int qtn_spawnattrs_set_tracking_data(void *attr, const void *data, size_t len);
int qtn_spawnattrs_get_tracking_data(void *a, void *d, size_t *len) { (void)a; (void)d; if (len) *len = 0; return ENOENT; }
int qtn_spawnattrs_set_tracking_data(void *a, const void *d, size_t len) { (void)a; (void)d; (void)len; return ENOTSUP; }

#pragma mark - Responsibility

/*
 * Which process is "responsible" for another (for TCC prompts and the like) is
 * tracked by the Quarantine kernel extension. These are the same calls Apple's
 * library makes, through the MAC policy syscall, with the same argument blocks
 * (read from macOS 26.4's libquarantine). Kernel blocks hold 64-bit slots.
 */
extern int __sandbox_ms(const char *policy, int call, void *arg);

#define QTN_POLICY "Quarantine"
#define QTN_RESPONSIBILITY_GET 180
#define QTN_RESPONSIBILITY_SET 181
#define QTN_RESPONSIBILITY_GET_AUDIT 182
#define QTN_RESPONSIBILITY_SET_AUDITTOKEN_FOR_SELF 183
#define QTN_RESPONSIBILITY_SET_AUDITTOKEN_FOR_CALLER 184
#define QTN_RESPONSIBILITY_SET_CALLER_FOR_CALLER 185
#define QTN_RESPONSIBILITY_SET_HOSTED_PATH 186
#define QTN_RESPONSIBILITY_SET_HOSTED_TEAM_ID 187

/* audit_token_t fields used: val[5] is the pid, val[7] the pid version. */
#define TOKEN_PID(t) (((const uint32_t *)(t))[5])
#define TOKEN_PIDVERSION(t) (((const uint32_t *)(t))[7])

static int
responsibility_get(pid_t pid, pid_t *rpid, uint64_t *runiqueid, size_t *pathlen, char *path)
{
	uint64_t out_pid = 0, out_uniqueid = 0;
	/* The length slot starts out holding the caller's pointer, as Apple's does. */
	uint64_t len_slot = (uint64_t)(uintptr_t)pathlen;
	uint64_t arg[5] = { (uint64_t)(int64_t)pid, (uint64_t)(uintptr_t)&out_pid,
		(uint64_t)(uintptr_t)&out_uniqueid, pathlen ? (uint64_t)(uintptr_t)&len_slot : 0,
		(uint64_t)(uintptr_t)path };
	int rc = __sandbox_ms(QTN_POLICY, QTN_RESPONSIBILITY_GET, arg);

	if (rc == 0) {
		if (rpid)
			*rpid = (pid_t)out_pid;
		if (runiqueid)
			*runiqueid = out_uniqueid;
		if (pathlen)
			*pathlen = (size_t)len_slot;
	}
	return rc;
}

int
responsibility_get_responsible_for_pid(pid_t pid, pid_t *rpid, uint64_t *runiqueid,
    size_t *pathlen, char *path)
{
	if (pathlen && *pathlen == 0) {
		errno = ERANGE;
		return -1;
	}
	return responsibility_get(pid, rpid, runiqueid, pathlen, path);
}

pid_t
responsibility_get_pid_responsible_for_pid(pid_t pid)
{
	pid_t rpid = 0;

	return responsibility_get(pid, &rpid, NULL, NULL, NULL) == 0 ? rpid : -1;
}

uint64_t
responsibility_get_uniqueid_responsible_for_pid(pid_t pid)
{
	uint64_t uniqueid = 0;

	return responsibility_get(pid, NULL, &uniqueid, NULL, NULL) == 0 ? uniqueid : UINT64_MAX;
}

int
responsibility_get_responsible_audit_token_for_audit_token(const void *token, void *out,
    uint64_t *x, void *y)
{
	uint8_t copy[32];
	uint64_t slot = (uint64_t)(uintptr_t)x;
	/* 0xe0 bytes, as Apple's: the attribution fields stay zero for this query. */
	uint64_t arg[28] = { 0 };
	int rc;

	memcpy(copy, token, sizeof(copy));
	arg[0] = TOKEN_PID(copy);
	arg[1] = TOKEN_PIDVERSION(copy);
	arg[2] = (uint64_t)(uintptr_t)out;
	arg[3] = (uint64_t)(uintptr_t)&slot;
	arg[4] = (uint64_t)(uintptr_t)y;
	rc = __sandbox_ms(QTN_POLICY, QTN_RESPONSIBILITY_GET_AUDIT, arg);
	if (x && rc == 0)
		*x = slot;
	return rc;
}

int
responsibility_init(int value)
{
	int64_t arg[2] = { 0, value };

	return __sandbox_ms(QTN_POLICY, QTN_RESPONSIBILITY_SET, arg);
}

int
responsibility_set_pid_responsible_for_pid(pid_t pid, pid_t rpid)
{
	int64_t arg[2] = { pid, rpid };

	return __sandbox_ms(QTN_POLICY, QTN_RESPONSIBILITY_SET, arg);
}

static int
set_audittoken(const void *token, int call)
{
	uint8_t copy[32];
	uint64_t arg[2];

	memcpy(copy, token, sizeof(copy));
	arg[0] = TOKEN_PID(copy);
	arg[1] = TOKEN_PIDVERSION(copy);
	return __sandbox_ms(QTN_POLICY, call, arg);
}

int
responsibility_set_audittoken_responsible_for_self(const void *token)
{
	return set_audittoken(token, QTN_RESPONSIBILITY_SET_AUDITTOKEN_FOR_SELF);
}

int
responsibility_set_audittoken_responsible_for_caller(const void *token)
{
	return set_audittoken(token, QTN_RESPONSIBILITY_SET_AUDITTOKEN_FOR_CALLER);
}

int
responsibility_set_caller_responsible_for_self(void)
{
	return __sandbox_ms(QTN_POLICY, QTN_RESPONSIBILITY_SET_CALLER_FOR_CALLER, NULL);
}

int
responsibility_set_hosted_path(const char *path)
{
	uint64_t arg[1] = { (uint64_t)(uintptr_t)path };

	return __sandbox_ms(QTN_POLICY, QTN_RESPONSIBILITY_SET_HOSTED_PATH, arg);
}

int
responsibility_set_hosted_team_id(const char *team_id)
{
	uint64_t arg[1] = { (uint64_t)(uintptr_t)team_id };

	return __sandbox_ms(QTN_POLICY, QTN_RESPONSIBILITY_SET_HOSTED_TEAM_ID, arg);
}

/*
 * Spawn attributes: a 24-byte "Quarantine" MAC policy blob, {version 1, size
 * 24, flags} with bit 0 of flags meaning "disclaim responsibility".
 */
int posix_spawnattr_getmacpolicyinfo_np(const posix_spawnattr_t *, const char *, void **, size_t *);
int posix_spawnattr_setmacpolicyinfo_np(posix_spawnattr_t *, const char *, void *, size_t);

struct qtn_spawn_blob {
	uint32_t version, size, flags, reserved;
	uint64_t tracking;
};

static pthread_key_t spawn_blob_key;
static pthread_once_t spawn_blob_once = PTHREAD_ONCE_INIT;

static void
spawn_blob_key_init(void)
{
	pthread_key_create(&spawn_blob_key, free);
}

/* The blob already in attr, or this thread's fresh one. */
static int
spawn_blob(posix_spawnattr_t *attr, struct qtn_spawn_blob **out)
{
	void *data = NULL;
	size_t size = sizeof(struct qtn_spawn_blob);
	int rc;

	pthread_once(&spawn_blob_once, spawn_blob_key_init);
	rc = posix_spawnattr_getmacpolicyinfo_np(attr, QTN_POLICY, &data, &size);
	if (rc == ESRCH) {
		struct qtn_spawn_blob *b = pthread_getspecific(spawn_blob_key);

		if (b == NULL) {
			if ((b = calloc(1, sizeof(*b))) == NULL)
				return ENOMEM;
			pthread_setspecific(spawn_blob_key, b);
		}
		memset(b, 0, sizeof(*b));
		b->version = 1;
		b->size = sizeof(*b);
		*out = b;
		return 0;
	}
	if (rc != 0)
		return rc;
	if (size != sizeof(struct qtn_spawn_blob))
		return EINVAL;
	*out = data;
	return 0;
}

int
responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attr, int disclaim)
{
	struct qtn_spawn_blob *b = NULL;
	int rc = spawn_blob(attr, &b);

	if (rc != 0)
		return rc;
	b->flags = (b->flags & ~1u) | (uint32_t)disclaim;
	return posix_spawnattr_setmacpolicyinfo_np(attr, QTN_POLICY, b, sizeof(*b));
}

int
responsibility_spawnattrs_getdisclaim(const posix_spawnattr_t *attr, char *disclaim)
{
	void *data = NULL;
	size_t size = 0;
	int rc = posix_spawnattr_getmacpolicyinfo_np(attr, QTN_POLICY, &data, &size);

	if (rc != 0)
		return rc;
	if (size != sizeof(struct qtn_spawn_blob))
		return EINVAL;
	if (disclaim)
		*disclaim = ((struct qtn_spawn_blob *)data)->flags & 1;
	return 0;
}

/*
 * Responsibility identities: what responsibility_get_attribution_for_audittoken
 * returns. The accessors read Apple's layout; building one needs the
 * Quarantine kext's attribution reply (call 182 with its full argument block),
 * which Finch doesn't decode yet, so attribution fails with ENOTSUP.
 */
struct responsibility_identity {
	uint64_t reserved[2];
	const char *binary_path;          /* 0x10 */
	const char *hosted_path;          /* 0x18 */
	const char *hosted_team_id;       /* 0x20 */
	const char *signing_id;           /* 0x28 */
	const char *team_id;              /* 0x30 */
	const void *entitlement_data;     /* 0x38 */
	const void *persistent_id;        /* 0x40 */
	uint64_t binary_offset;           /* 0x48 */
	uint64_t entitlement_length;      /* 0x50 */
	uint64_t csflags;                 /* 0x58 */
	uint64_t fileid;                  /* 0x60 */
	uint32_t binary_flags;            /* 0x68 */
	uint32_t reserved2;
	uint32_t fsid;                    /* 0x70 */
	uint32_t platform;                /* 0x74 */
	uint32_t sdk;                     /* 0x78 */
	uint8_t has_fileid;               /* 0x7c */
};

void *
responsibility_get_attribution_for_audittoken(const void *token, int x)
{
	(void)token;
	(void)x;
	errno = ENOTSUP;
	return NULL;
}

const void *
responsibility_identity_get_binary_entitlement_data(const struct responsibility_identity *i,
    uint64_t *length)
{
	if (length)
		*length = i->entitlement_length;
	return i->entitlement_data;
}

bool responsibility_identity_get_binary_is_platform(const struct responsibility_identity *i) { return i->binary_flags & 1; }
uint64_t responsibility_identity_get_binary_offset(const struct responsibility_identity *i) { return i->binary_offset; }
const char *responsibility_identity_get_binary_path(const struct responsibility_identity *i) { return i->binary_path; }
const char *responsibility_identity_get_binary_signing_id(const struct responsibility_identity *i) { return i->signing_id; }
const char *responsibility_identity_get_binary_team_id(const struct responsibility_identity *i) { return i->team_id; }
uint64_t responsibility_identity_get_csflags(const struct responsibility_identity *i) { return i->csflags; }
const char *responsibility_identity_get_hosted_path(const struct responsibility_identity *i) { return i->hosted_path; }
const char *responsibility_identity_get_hosted_team_id(const struct responsibility_identity *i) { return i->hosted_team_id; }
uint32_t responsibility_identity_get_platform(const struct responsibility_identity *i) { return i->platform; }
uint32_t responsibility_identity_get_sdk(const struct responsibility_identity *i) { return i->sdk; }
void responsibility_identity_get_user_uuid(const struct responsibility_identity *i) { (void)i; }

const void *
responsibility_identity_get_persistent_identifier(const struct responsibility_identity *i, int which)
{
	return which ? NULL : i->persistent_id;
}

int openbyid_np(fsid_t *fsid, fsobj_id_t *objid, int flags);

int
responsibility_identity_open_binary_fd(const struct responsibility_identity *i, int flags)
{
	fsid_t fsid = { { (int32_t)i->fsid, 0 } };
	fsobj_id_t objid;

	if (!i->has_fileid) {
		errno = ENOTSUP;
		return -1;
	}
	memcpy(&objid, &i->fileid, sizeof(objid));
	return openbyid_np(&fsid, &objid, flags);
}

void
responsibility_identity_release(struct responsibility_identity *i)
{
	free(i);
}
