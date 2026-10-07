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
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
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

#pragma mark - Responsibility (kernel policy: every process is responsible for itself)

int responsibility_init(void);
pid_t responsibility_get_responsible_for_pid(pid_t pid);
pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);
uint64_t responsibility_get_uniqueid_responsible_for_pid(pid_t pid);
int responsibility_get_responsible_audit_token_for_audit_token(const void *token, void *out);
int responsibility_spawnattrs_setdisclaim(void *attr, int disclaim);
int responsibility_spawnattrs_getdisclaim(void *attr, int *disclaim);

int responsibility_init(void) { return 0; }
pid_t responsibility_get_responsible_for_pid(pid_t pid) { return pid; }
pid_t responsibility_get_pid_responsible_for_pid(pid_t pid) { return pid; }
uint64_t responsibility_get_uniqueid_responsible_for_pid(pid_t pid) { (void)pid; return 0; }

/* audit_token_t is 32 bytes. */
int
responsibility_get_responsible_audit_token_for_audit_token(const void *token, void *out)
{
	memcpy(out, token, 32);
	return 0;
}

int responsibility_spawnattrs_setdisclaim(void *a, int d) { (void)a; (void)d; return 0; }
int responsibility_spawnattrs_getdisclaim(void *a, int *d) { (void)a; if (d) *d = 0; return 0; }

/* The rest of the responsibility SPI: not available (0 / NULL / ENOTSUP). */
#define NOT_AVAILABLE(name) long name(void); long name(void) { return 0; }
NOT_AVAILABLE(responsibility_get_attribution_for_audittoken)
NOT_AVAILABLE(responsibility_identity_get_binary_entitlement_data)
NOT_AVAILABLE(responsibility_identity_get_binary_is_platform)
NOT_AVAILABLE(responsibility_identity_get_binary_offset)
NOT_AVAILABLE(responsibility_identity_get_binary_path)
NOT_AVAILABLE(responsibility_identity_get_binary_signing_id)
NOT_AVAILABLE(responsibility_identity_get_binary_team_id)
NOT_AVAILABLE(responsibility_identity_get_csflags)
NOT_AVAILABLE(responsibility_identity_get_hosted_path)
NOT_AVAILABLE(responsibility_identity_get_hosted_team_id)
NOT_AVAILABLE(responsibility_identity_get_persistent_identifier)
NOT_AVAILABLE(responsibility_identity_get_platform)
NOT_AVAILABLE(responsibility_identity_get_sdk)
NOT_AVAILABLE(responsibility_identity_get_user_uuid)
NOT_AVAILABLE(responsibility_identity_release)
NOT_AVAILABLE(responsibility_set_hosted_path)
NOT_AVAILABLE(responsibility_set_hosted_team_id)

int responsibility_identity_open_binary_fd(void);
int responsibility_set_audittoken_responsible_for_caller(void);
int responsibility_set_audittoken_responsible_for_self(void);
int responsibility_set_caller_responsible_for_self(void);
int responsibility_set_pid_responsible_for_pid(void);
int responsibility_identity_open_binary_fd(void) { errno = ENOTSUP; return -1; }
int responsibility_set_audittoken_responsible_for_caller(void) { return ENOTSUP; }
int responsibility_set_audittoken_responsible_for_self(void) { return ENOTSUP; }
int responsibility_set_caller_responsible_for_self(void) { return ENOTSUP; }
int responsibility_set_pid_responsible_for_pid(void) { return ENOTSUP; }
