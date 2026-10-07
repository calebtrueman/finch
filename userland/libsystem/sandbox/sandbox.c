/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_sandbox: the userspace side of the Sandbox MAC policy. Every
 * question and every grant goes to the kernel policy through
 * __sandbox_ms("Sandbox", call, request); this library only builds the
 * requests and reads back the answers, so the kernel stays the one place
 * that decides. Call numbers, request layouts, flag encodings, constants and
 * error behavior are those of macOS 26.4's library (Sandbox-2680.100.174),
 * read from its entry points; tests/sb-compare.c checks the observable
 * behavior against it.
 *
 * File trust and protected directories live in rootless.c. Unused manifest
 * and GPU helpers fail with ENOTSUP in unsupported.c.
 */

#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "internal.h"

/* ---- data ---- */

EXPORT const uint32_t SANDBOX_CHECK_NO_REPORT = 0x40000000;
EXPORT const uint32_t SANDBOX_CHECK_CANONICAL = 0x20000000;
EXPORT const uint32_t SANDBOX_CHECK_NOFOLLOW = 0x10000000;
EXPORT const uint32_t SANDBOX_CHECK_ALLOW_APPROVAL = 0x08000000;
EXPORT const uint32_t SANDBOX_CHECK_POSIX_READABLE = 0x04000000;
EXPORT const uint32_t SANDBOX_CHECK_POSIX_WRITEABLE = 0x02000000;
EXPORT const uint32_t SANDBOX_CHECK_NO_APPROVAL = 0;

EXPORT const uint32_t SANDBOX_EXTENSION_DEFAULT = 0;
EXPORT const uint32_t SANDBOX_EXTENSION_CANONICAL = 0x2;
EXPORT const uint32_t SANDBOX_EXTENSION_NOFOLLOW_ANY = 0x2;
EXPORT const uint32_t SANDBOX_EXTENSION_PREFIXMATCH = 0x4;
EXPORT const uint32_t SANDBOX_EXTENSION_NO_REPORT = 0x10;
EXPORT const uint32_t SANDBOX_EXTENSION_NOFOLLOW = 0x20;
EXPORT const uint32_t SANDBOX_EXTENSION_NO_STORAGE_CLASS = 0x40;
EXPORT const uint32_t SANDBOX_EXTENSION_USER_INTENT = 0x4000;
EXPORT const uint32_t SANDBOX_EXTENSION_MACL_LEARNING = 0x8000;

EXPORT const uint32_t SANDBOX_PROFILE_TYPE_PLATFORM = 1;
EXPORT const uint32_t SANDBOX_PROFILE_TYPE_BASTION = 2;
EXPORT const uint32_t SANDBOX_PROFILE_TYPE_PROCESS = 3;
EXPORT const uint32_t SANDBOX_PROFILE_TYPE_AUTOBOX = 4;
EXPORT const uint32_t SANDBOX_PROFILE_TYPE_GLOBAL_OVERRIDE = 5;

EXPORT const uint64_t SANDBOX_STORAGE_CLASS_GROUP_ANY = 0;
EXPORT const uint64_t SANDBOX_STORAGE_CLASS_PROPERTY_READ_RESTRICTED = 0x1;
EXPORT const uint64_t SANDBOX_STORAGE_CLASS_PROPERTY_WRITE_RESTRICTED = 0x2;
EXPORT const uint64_t SANDBOX_STORAGE_CLASS_PROPERTY_REPLACEMENT_RESTRICTED = 0x4;
EXPORT const uint64_t SANDBOX_STORAGE_CLASS_PROPERTY_ACCEPTS_USER_APPROVAL = 0x8000000000000000ull;

EXPORT const char *const APP_SANDBOX_READ = "com.apple.app-sandbox.read";
EXPORT const char *const APP_SANDBOX_READ_WRITE = "com.apple.app-sandbox.read-write";
EXPORT const char *const APP_SANDBOX_MACH = "com.apple.app-sandbox.mach";
EXPORT const char *const APP_SANDBOX_IOKIT_CLIENT = "com.apple.app-sandbox.iokit-client";
EXPORT const char *const IOS_SANDBOX_CONTAINER = "com.apple.sandbox.container";
EXPORT const char *const IOS_SANDBOX_APPLICATION_GROUP = "com.apple.sandbox.application-group";

/* Named built-in profiles for sandbox_init(..., SANDBOX_NAMED, ...). */
EXPORT const char kSBXProfileNoInternet[] = "no-internet";
EXPORT const char kSBXProfileNoNetwork[] = "no-network";
EXPORT const char kSBXProfileNoWrite[] = "no-write";
EXPORT const char kSBXProfileNoWriteExceptTemporary[] = "no-write-except-temporary";
EXPORT const char kSBXProfilePureComputation[] = "pure-computation";

/* Team and signing-identifier wildcards for the exception registrations:
 * "any signing identifier" is NULL; "platform" is a unique address. */
EXPORT const void *const kSandboxAppBundleAnySigningId = NULL;
EXPORT const void *const kSandboxAppContainerAnySigningId = NULL;
EXPORT const void *const kSandboxAppBundlePlatformTeamId = &kSandboxAppBundlePlatformTeamId;
EXPORT const void *const kSandboxAppContainerPlatformTeamId = &kSandboxAppContainerPlatformTeamId;

/* ---- helpers ---- */

/* Warnings go to the system log and to stderr, as Apple's do. */
void sandbox_warn(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	_SIMPLE_STRING s = _simple_salloc();
	_simple_vsprintf(s, fmt, ap);
	va_end(ap);
	_simple_asl_log(ASL_LEVEL_CRIT, "com.apple.libsystem.sandbox", _simple_string(s));
	_simple_dprintf(STDERR_FILENO, "%s\n", _simple_string(s));
	_simple_sfree(s);
}

/* "iokit-open" was renamed; old callers get the new name and a warning. */
static const char *operation_fixup(const char *op)
{
	if (op && !strcmp(op, "iokit-open")) {
		sandbox_warn("sandbox operation \"%s\" is obsolete; replace with \"%s\"", op, "iokit-open-user-client");
		return "iokit-open-user-client";
	}
	return op;
}

/* ---- checks ---- */

/*
 * The check request (call 2). Callers fill in who and what; check_common
 * adds the filter and the flags from the filter type's high bits, and the
 * kernel stores the verdict (nonzero: denied) through the result pointer.
 */
struct check_request {
	uint64_t *result;          /* 0x00 */
	int64_t pid;               /* 0x08 */
	const char *operation;     /* 0x10 */
	uint64_t filter_kind;      /* 0x18 */
	uint64_t filter_arg;       /* 0x20 */
	uint64_t flags;            /* 0x28 */
	uint64_t target;           /* 0x30: pid version or unique id */
	uint64_t reserved[13];     /* 0x38 */
};
_Static_assert(sizeof(struct check_request) == 0xa0, "check request");

#define CHECK_FLAG_NO_REPORT       0x01
#define CHECK_FLAG_CANONICAL       0x02
#define CHECK_FLAG_NOFOLLOW        0x08
#define CHECK_FLAG_ALLOW_APPROVAL  0x10
#define CHECK_FLAG_POSIX_READABLE  0x20
#define CHECK_FLAG_POSIX_WRITEABLE 0x40
#define CHECK_BY_AUDIT_TOKEN       0x40000000
#define CHECK_BY_UNIQUE_ID         0x80000000u
#define CHECK_BY_REFERENCE         0xc0000000u

/* The kernel's filter kind for each public filter type, and how many
 * arguments the type takes. */
static int check_common(struct check_request *req, uint32_t type, va_list ap)
{
	uint64_t result = 0;
	struct { uint64_t a; uint64_t b; } pair = { 0, 0 };
	struct { uint64_t a; uint32_t b; } pair2 = { 0, 0 };

	req->result = &result;
	if (type & 0x40000000) req->flags |= CHECK_FLAG_NO_REPORT;
	if (type & 0x20000000) req->flags |= CHECK_FLAG_CANONICAL;
	if (type & 0x10000000) req->flags |= CHECK_FLAG_NOFOLLOW;
	if (type & 0x08000000) req->flags |= CHECK_FLAG_ALLOW_APPROVAL;
	if (type & 0x04000000) req->flags |= CHECK_FLAG_POSIX_READABLE;
	if (type & 0x02000000) req->flags |= CHECK_FLAG_POSIX_WRITEABLE;

	uint32_t filter = type & 0x81ffffffu;
	switch (filter) {
	case 0:   /* none */
		req->filter_kind = 0;
		req->filter_arg = 0;
		break;
	case 1: case 2: case 3: case 4: case 5: case 6: case 7: case 8:
	case 12: case 13: case 15: case 17: case 19: {
		/* One pointer-sized argument (a path, a name, ...). */
		static const uint8_t kind[20] = {
			[1] = 1, [2] = 6, [3] = 7, [4] = 25, [5] = 27, [6] = 28, [7] = 33, [8] = 34,
			[12] = 50, [13] = 19, [15] = 45, [17] = 5, [19] = 69,
		};
		req->filter_kind = kind[filter];
		req->filter_arg = (uint64_t)va_arg(ap, void *);
		break;
	}
	case 10: case 14: case 16: case 18: {
		/* One int argument. */
		static const uint8_t kind[20] = { [10] = 240, [14] = 65, [16] = 75, [18] = 52 };
		req->filter_kind = kind[filter];
		req->filter_arg = (uint32_t)va_arg(ap, int);
		break;
	}
	case 9:   /* two arguments, passed by address */
		pair.a = (uint64_t)va_arg(ap, void *);
		pair.b = (uint64_t)(int64_t)va_arg(ap, int);
		req->filter_kind = 35;
		req->filter_arg = (uint64_t)&pair;
		break;
	case 11: {   /* pointers to a 32-bit and a 64-bit value */
		const uint32_t *p32 = va_arg(ap, const uint32_t *);
		const uint64_t *p64 = va_arg(ap, const uint64_t *);
		pair2.b = *p32;
		pair2.a = *p64;
		req->filter_kind = 241;
		req->filter_arg = (uint64_t)&pair2;
		break;
	}
	default:
		errno = EINVAL;
		return -1;
	}
	if (__sandbox_ms("Sandbox", 2, req) != 0)
		return -1;
	return result != 0;
}

EXPORT int sandbox_check(pid_t pid, const char *operation, uint32_t type, ...)
{
	struct check_request req = { .pid = pid, .operation = operation_fixup(operation) };
	va_list ap;
	va_start(ap, type);
	int r = check_common(&req, type, ap);
	va_end(ap);
	return r;
}

EXPORT int sandbox_check_by_audit_token(const audit_token_t *token, const char *operation, uint32_t type, ...)
{
	struct check_request req = {
		.pid = token->val[5], .operation = operation_fixup(operation),
		.flags = CHECK_BY_AUDIT_TOKEN, .target = token->val[7],
	};
	va_list ap;
	va_start(ap, type);
	int r = check_common(&req, type, ap);
	va_end(ap);
	return r;
}

EXPORT int sandbox_check_by_uniqueid(pid_t pid, uint64_t unique_id, const char *operation, uint32_t type, ...)
{
	struct check_request req = {
		.pid = pid, .operation = operation_fixup(operation),
		.flags = CHECK_BY_UNIQUE_ID, .target = unique_id,
	};
	va_list ap;
	va_start(ap, type);
	int r = check_common(&req, type, ap);
	va_end(ap);
	return r;
}

EXPORT int sandbox_check_by_reference(uint64_t reference, const char *operation, uint32_t type, ...)
{
	struct check_request req = {
		.operation = operation_fixup(operation), .flags = CHECK_BY_REFERENCE, .target = reference,
	};
	va_list ap;
	va_start(ap, type);
	int r = check_common(&req, type, ap);
	va_end(ap);
	return r;
}

/* Same as sandbox_check, also reporting who the access is attributed to. */
EXPORT int sandbox_check_with_attribution(pid_t pid, uint64_t attribution, uint64_t context,
    uint32_t *attributed, const char *operation, uint32_t type, ...)
{
	uint64_t ctx = context, out = 0;
	struct check_request req = {
		.pid = pid, .operation = operation_fixup(operation), .flags = 0x100,
	};
	req.reserved[10] = attribution;           /* 0x88 */
	req.reserved[11] = (uint64_t)&ctx;        /* 0x90 */
	req.reserved[12] = (uint64_t)&out;        /* 0x98 */
	va_list ap;
	va_start(ap, type);
	int r = check_common(&req, type, ap);
	va_end(ap);
	if (attributed)
		*attributed = (uint32_t)out;
	return r;
}

/* va_list plumbing for checks whose filter argument this library supplies. */
static int check_with_args(struct check_request *req, uint32_t type, ...)
{
	va_list ap;
	va_start(ap, type);
	int r = check_common(req, type, ap);
	va_end(ap);
	return r;
}

/* May the process with token `sender` send signal `signal` to `target`? */
EXPORT int sandbox_check_process_signal_target(const audit_token_t *sender, int signal,
    const audit_token_t *target, uint32_t flags)
{
	struct check_request req = {
		.pid = sender->val[5], .operation = "signal", .flags = 0x41000000, .target = sender->val[7],
	};
	req.reserved[7] = target->val[5];   /* 0x70 */
	req.reserved[8] = target->val[7];   /* 0x78 */
	return check_with_args(&req, (flags & 0x81ffffffu) | 18, signal);
}

EXPORT int sandbox_check_self_signal_target(int signal, const audit_token_t *target, uint32_t flags)
{
	struct check_request req = { .pid = getpid(), .operation = "signal", .flags = 0x1000000 };
	req.reserved[7] = target->val[5];
	req.reserved[8] = target->val[7];
	return check_with_args(&req, (flags & 0x81ffffffu) | 18, signal);
}

/* Many checks in one call (21). Flags other than NO_REPORT and
 * ALLOW_APPROVAL are refused; the result is 0 or -1, or the error number for
 * refused flags, as Apple's. */
EXPORT int sandbox_check_bulk(const audit_token_t *token, const char *operation, uint32_t type,
    uint32_t count, void *items, void *results)
{
	if (type & 0x81ffffffu)
		return EINVAL;
	if (type & 0x30000000)
		return ENOTSUP;
	struct {
		uint64_t pid, pidversion;
		const char *operation;
		uint64_t flags;
		uint64_t count;
		void *items, *results;
	} req = {
		.pid = (uint32_t)token->val[5], .pidversion = (uint32_t)token->val[7],
		.operation = operation_fixup(operation), .count = count, .items = items, .results = results,
	};
	if (type & 0x48000000)
		req.flags = (type & 0x08000000) ? 0x10 + ((type >> 30) != 0) : 1;
	return __sandbox_ms("Sandbox", 21, &req) != 0 ? -1 : 0;
}

/*
 * Network operations ("network-*") against an address. `addr` is a
 * sockaddr: only AF_INET (2) and AF_INET6 (30) are supported.
 */
struct sandbox_checkattr { uint32_t magic; uint32_t flags; uint8_t reserved[56]; };

EXPORT int sandbox_check_network(const audit_token_t *token, const struct sandbox_checkattr *attr,
    const char *operation, int socket_type, const struct sockaddr *addr)
{
	if (!operation || !addr) {
		errno = EINVAL;
		return -1;
	}
	uint8_t family = ((const uint8_t *)addr)[1];
	if (family != 2 && family != 30) {
		errno = ENOTSUP;
		return -1;
	}
	if (strncmp(operation, "network-", 8)) {
		errno = EINVAL;
		return -1;
	}
	uint64_t result = 0;
	struct { int64_t socket_type; const void *addr; uint64_t len; } net = {
		socket_type, addr, ((const uint8_t *)addr)[0],
	};
	struct check_request req = {
		.result = &result, .pid = (uint32_t)token->val[5], .operation = operation,
		.filter_kind = 242, .filter_arg = (uint64_t)&net, .flags = CHECK_BY_AUDIT_TOKEN,
		.target = (uint32_t)token->val[7],
	};
	if (attr)
		req.flags = attr->flags | CHECK_BY_AUDIT_TOKEN;
	int r = __sandbox_ms("Sandbox", 2, &req);
	return r == -1 ? -1 : result != 0;
}

EXPORT struct sandbox_checkattr *sandbox_checkattr_alloc(void)
{
	struct sandbox_checkattr *a = calloc(1, sizeof(*a));
	if (!a)
		sandbox_warn("%s: failed to allocate", "sandbox_checkattr_alloc");
	return a;
}

EXPORT void sandbox_checkattr_disable_reporting(struct sandbox_checkattr *a)
{
	a->flags |= 1;
}

EXPORT void sandbox_checkattr_free(struct sandbox_checkattr **a)
{
	if (!a)
		return;
	free(*a);
	*a = NULL;
}

/* Would Finder automation on `path` be allowed (call 83)? Returns 1 when
 * allowed, 0 otherwise. No flags are defined. */
EXPORT int sandbox_check_finder_automation_for_path(const audit_token_t *token, const char *path, uint32_t flags)
{
	if (flags) {
		sandbox_warn("%s: unsupported flags: %u", "sandbox_check_finder_automation_for_path", flags);
		abort();
	}
	uint64_t denied = 0;
	struct { uint64_t *result; uint64_t zero; uint64_t pid, pidversion; const char *path; } req = {
		&denied, 0, (uint32_t)token->val[5], (uint32_t)token->val[7], path,
	};
	if (__sandbox_ms("Sandbox", 83, &req) < 0) {
		sandbox_warn("%s: failed for %s: %s (%d)", "sandbox_check_finder_automation_for_path", path,
		    strerror(errno), errno);
		return 0;
	}
	return denied == 0;
}

/* ---- message filters (call 52 checks, 53 releases, 61 retains) ---- */

static int message_filter_check(const audit_token_t *token, uint64_t filter, uint64_t kind,
    uint32_t flags, uint64_t value, const char *string, const char *fn)
{
	uint64_t denied = 0;
	struct {
		uint64_t *result; uint64_t filter; uint64_t pid, pidversion;
		uint64_t kind; const char *string; uint64_t value; uint64_t no_report;
	} req = { &denied, filter, (uint32_t)token->val[5], (uint32_t)token->val[7], kind, string, value, 0 };
	if (flags & 0x40000000) {
		req.no_report = 1;
		flags &= ~0x40000000u;
	}
	if (flags) {
		sandbox_warn("unsupported flags passed to %s: 0x%0x", fn, flags);
		errno = ENOTSUP;
		return -1;
	}
	if (__sandbox_ms("Sandbox", 52, &req) != 0)
		return -1;
	return denied != 0;
}

EXPORT int sandbox_check_message_filter_integer(const audit_token_t *token, uint64_t filter, uint64_t kind,
    uint32_t flags, int64_t value)
{
	if (!filter)
		return 0;
	return message_filter_check(token, filter, kind, flags, (uint32_t)value, NULL,
	    "sandbox_check_message_filter_integer");
}

EXPORT int sandbox_check_message_filter_string(const audit_token_t *token, uint64_t filter, uint64_t kind,
    uint32_t flags, const char *string)
{
	if (!string) {
		errno = EINVAL;
		return -1;
	}
	if (!filter)
		return 0;
	return message_filter_check(token, filter, kind, flags, 0, string, "sandbox_check_message_filter_string");
}

EXPORT uint64_t sandbox_message_filter_retain(uint64_t filter)
{
	if (filter && __sandbox_ms("Sandbox", 61, &filter) != 0) {
		/* Apple's library treats a failed retain as fatal. */
		sandbox_warn("%s failed on message filter #%llu: %d (%s)", "sandbox_message_filter_retain",
		    filter, errno, strerror(errno));
		abort();
	}
	return filter;
}

EXPORT void sandbox_message_filter_release(uint64_t filter)
{
	if (!filter)
		return;
	if (__sandbox_ms("Sandbox", 53, &filter) != 0) {
		int e = errno;
		sandbox_warn("%s failed on message filter #%llu: %d (%s)", "sandbox_message_filter_release",
		    filter, e, strerror(e));
	}
}

/*
 * The message filter a check would apply, as a buffer the kernel fills
 * (grown and retried on ERANGE, three tries). Returns the buffer and its
 * size, or { NULL, 0 } with errno set.
 */
struct sandbox_buffer { void *data; uint64_t size; };

EXPORT struct sandbox_buffer sandbox_message_filter_query(pid_t pid, const char *operation, uint32_t type, ...)
{
	struct check_request req = { .pid = pid, .operation = operation_fixup(operation), .flags = 0x4000000 };
	uint64_t size = 1024;
	void *buf = malloc(size);
	int err;
	for (int tries = 3; buf; ) {
		req.reserved[4] = (uint64_t)buf;     /* 0x58 */
		req.reserved[5] = (uint64_t)&size;   /* 0x60 */
		va_list ap;
		va_start(ap, type);
		int r = check_common(&req, type, ap);
		va_end(ap);
		if (r == 0)
			return (struct sandbox_buffer){ buf, size };
		if (r >= 1) {
			errno = EPERM;
			break;
		}
		if (errno != ERANGE)
			break;
		buf = reallocf(buf, size);
		if (!buf || --tries == 0)
			break;
	}
	err = errno;
	free(buf);
	errno = err;
	return (struct sandbox_buffer){ NULL, 0 };
}

/* Is access to `path` approved by the user (TCC-style approval policy)? Also
 * returns the policy's name unless it is a telemetry-only policy. */
EXPORT int sandbox_query_approval_policy_for_path(const char *operation, const char *path, char **policy)
{
	char name[0x80] = { 0 };
	uint64_t name_size = sizeof(name), denied = 0;
	struct check_request req = {
		.result = &denied, .pid = getpid(), .operation = operation_fixup(operation),
		.filter_kind = 1, .filter_arg = (uint64_t)path, .flags = 0x10000001,
	};
	req.reserved[1] = (uint64_t)name;          /* 0x40 */
	req.reserved[2] = (uint64_t)&name_size;    /* 0x48 */
	if (__sandbox_ms("Sandbox", 2, &req) != 0)
		return -1;
	if (policy)
		*policy = (name_size && !strstr(name, "-telemetry-")) ? strdup(name) : NULL;
	return denied != 0;
}

EXPORT int sandbox_query_user_intent_for_process_with_audit_token(const audit_token_t *token,
    const char *operation, uint32_t type, const char *path, bool *intent)
{
	uint64_t result = 0, has_intent = 0;
	struct check_request req = {
		.result = &result, .pid = (uint32_t)token->val[5], .operation = operation_fixup(operation),
		.filter_kind = 1, .filter_arg = (uint64_t)path, .flags = 0x48000000,
		.target = (uint32_t)token->val[7],
	};
	req.reserved[3] = (uint64_t)&has_intent;   /* 0x50 */
	if (type & 0x78000000)
		req.flags = (0x48000000 + ((type & 0x40000000) != 0)) | ((type >> 28) & 2) |
		    ((type >> 25) & 8) | ((type >> 23) & 0x10);
	if (type & 0x81fffffeu) {
		errno = EINVAL;
		return -1;
	}
	if (__sandbox_ms("Sandbox", 2, &req) != 0)
		return -1;
	if (intent)
		*intent = has_intent != 0;
	return result != 0;
}

/* ---- extensions ---- */

#define EXTENSION_MAX 0x3ff0
#define EXT_FILE    0
#define EXT_MACH    1
#define EXT_IOKIT   2
#define EXT_GENERIC 3
#define EXT_TO_PID      0x10000
#define EXT_TO_TOKEN    0x30000

/* Issue an extension token (call 5): a string the kernel signs, which the
 * receiving process consumes to gain the access. */
static char *extension_issue(const char *class, uint32_t type, const char *data, uint32_t flags,
    pid_t pid, uint32_t pidversion)
{
	char *token = malloc(EXTENSION_MAX);
	if (!token)
		return NULL;
	if (flags & 1) {
		strlcpy(token, "invalid", EXTENSION_MAX);
		return token;
	}
	struct {
		const char *class; uint64_t type; const char *data; uint64_t flags;
		char *token; int64_t pid; uint64_t pidversion;
	} req = { class, type, data, flags, token, pid, pidversion };
	if (__sandbox_ms("Sandbox", 5, &req) != 0) {
		int e = errno;
		free(token);
		errno = e;
		return NULL;
	}
	return token;
}

#define LOCAL(f) ((f) & ~EXT_TO_TOKEN)

EXPORT char *sandbox_extension_issue_file(const char *class, const char *path, uint32_t flags)
{
	return extension_issue(class, EXT_FILE, path, LOCAL(flags), 0, 0);
}

EXPORT char *sandbox_extension_issue_file_to_process(const char *class, const char *path, uint32_t flags,
    audit_token_t token)
{
	return extension_issue(class, EXT_FILE, path, flags | EXT_TO_TOKEN, token.val[5], token.val[7]);
}

EXPORT char *sandbox_extension_issue_file_to_process_by_pid(const char *class, const char *path,
    uint32_t flags, pid_t pid)
{
	return extension_issue(class, EXT_FILE, path, LOCAL(flags) | EXT_TO_PID, pid, 0);
}

EXPORT char *sandbox_extension_issue_file_to_self(const char *class, const char *path, uint32_t flags)
{
	return extension_issue(class, EXT_FILE, path, LOCAL(flags) | EXT_TO_PID, getpid(), 0);
}

EXPORT char *sandbox_extension_issue_mach(const char *class, const char *name, uint32_t flags)
{
	return extension_issue(class, EXT_MACH, name, LOCAL(flags), 0, 0);
}

EXPORT char *sandbox_extension_issue_mach_to_process(const char *class, const char *name, uint32_t flags,
    audit_token_t token)
{
	return extension_issue(class, EXT_MACH, name, flags | EXT_TO_TOKEN, token.val[5], token.val[7]);
}

EXPORT char *sandbox_extension_issue_mach_to_process_by_pid(const char *class, const char *name,
    uint32_t flags, pid_t pid)
{
	return extension_issue(class, EXT_MACH, name, LOCAL(flags) | EXT_TO_PID, pid, 0);
}

EXPORT char *sandbox_extension_issue_iokit_registry_entry_class(const char *class, const char *entry_class,
    uint32_t flags)
{
	return extension_issue(class, EXT_IOKIT, entry_class, LOCAL(flags), 0, 0);
}

EXPORT char *sandbox_extension_issue_iokit_registry_entry_class_to_process(const char *class,
    const char *entry_class, uint32_t flags, audit_token_t token)
{
	return extension_issue(class, EXT_IOKIT, entry_class, flags | EXT_TO_TOKEN, token.val[5], token.val[7]);
}

EXPORT char *sandbox_extension_issue_iokit_registry_entry_class_to_process_by_pid(const char *class,
    const char *entry_class, uint32_t flags, pid_t pid)
{
	return extension_issue(class, EXT_IOKIT, entry_class, LOCAL(flags) | EXT_TO_PID, pid, 0);
}

EXPORT char *sandbox_extension_issue_generic(const char *class, uint32_t flags)
{
	return extension_issue(class, EXT_GENERIC, NULL, LOCAL(flags), 0, 0);
}

EXPORT char *sandbox_extension_issue_generic_to_process(const char *class, uint32_t flags, audit_token_t token)
{
	return extension_issue(class, EXT_GENERIC, NULL, flags | EXT_TO_TOKEN, token.val[5], token.val[7]);
}

EXPORT char *sandbox_extension_issue_generic_to_process_by_pid(const char *class, uint32_t flags, pid_t pid)
{
	return extension_issue(class, EXT_GENERIC, NULL, LOCAL(flags) | EXT_TO_PID, pid, 0);
}

/* Consume an extension token (call 6). Returns a handle for releasing it,
 * 0 for the "invalid" placeholder token, or -1. */
EXPORT int64_t sandbox_extension_consume(const char *token)
{
	if (!strcmp(token, "invalid"))
		return 0;
	int64_t handle = 0;
	struct { const char *token; uint64_t size; int64_t *handle; } req = { token, strlen(token) + 1, &handle };
	return __sandbox_ms("Sandbox", 6, &req) == 0 ? handle : -1;
}

/* Older names. */
EXPORT int sandbox_consume_extension(const char *path, const char *token)
{
	(void)path;
	return sandbox_extension_consume(token) == -1 ? -1 : 0;
}

EXPORT int sandbox_consume_fs_extension(const char *token, char **path)
{
	int64_t h = sandbox_extension_consume(token);
	if (path && h != -1)
		*path = NULL;
	return h == -1 ? -1 : 0;
}

EXPORT int sandbox_consume_mach_extension(const char *token, char **name)
{
	int64_t h = sandbox_extension_consume(token);
	if (name && h != -1)
		*name = NULL;
	return h == -1 ? -1 : 0;
}

EXPORT int sandbox_issue_fs_extension(const char *path, uint64_t flags, char **token)
{
	*token = sandbox_extension_issue_file((flags & 8) ? APP_SANDBOX_READ_WRITE : APP_SANDBOX_READ, path, 0);
	return *token ? 0 : -1;
}

EXPORT int sandbox_issue_mach_extension(const char *name, char **token)
{
	*token = sandbox_extension_issue_mach(APP_SANDBOX_MACH, name, 0);
	return *token ? 0 : -1;
}

/* Release (call 7) by handle, by path, or by token. */
EXPORT int sandbox_extension_release(int64_t handle)
{
	struct { int64_t handle; const char *token; const char *path; } req = { handle, NULL, NULL };
	return __sandbox_ms("Sandbox", 7, &req);
}

EXPORT int sandbox_release_fs_extension(const char *token)
{
	struct { int64_t handle; const char *token; const char *path; } req = { 0, token, NULL };
	return __sandbox_ms("Sandbox", 7, &req);
}

EXPORT int sandbox_extension_release_file(const char *path)
{
	struct { int64_t handle; const char *token; const char *path; } req = { 0, NULL, path };
	return __sandbox_ms("Sandbox", 7, &req);
}

EXPORT int sandbox_extension_release_and_detect_last_reference(int64_t handle, bool *last)
{
	struct { int64_t handle; uint64_t zero1, zero2; bool *last; } req = { handle, 0, 0, last };
	return __sandbox_ms("Sandbox", 80, &req);
}

EXPORT int sandbox_extension_update_file(const char *path, uint32_t flags)
{
	struct { const char *path; uint64_t flags; } req = { path, flags };
	return __sandbox_ms("Sandbox", 8, &req);
}

EXPORT int sandbox_extension_update_file_by_fileid(const char *token, uint64_t fileid, uint32_t flags)
{
	struct { const char *token; uint64_t fileid; uint64_t flags; } req = { token, fileid, flags };
	return __sandbox_ms("Sandbox", 79, &req);
}

/* Extensions are reaped by the kernel; nothing to do here. */
EXPORT void sandbox_extension_reap(void) {}

/* ---- containers ---- */

EXPORT int sandbox_container_path_for_pid(pid_t pid, char *buf, size_t size)
{
	struct { int64_t pid; uint64_t pidversion; char *buf; uint64_t size; uint64_t by_token; } req = {
		pid ? pid : getpid(), 0, buf, size, 0,
	};
	return __sandbox_ms("Sandbox", 4, &req);
}

EXPORT int sandbox_container_path_for_audit_token(const audit_token_t *token, char *buf, size_t size)
{
	struct { int64_t pid; uint64_t pidversion; char *buf; uint64_t size; uint64_t by_token; } req = {
		(uint32_t)token->val[5], (uint32_t)token->val[7], buf, size, 1,
	};
	return __sandbox_ms("Sandbox", 4, &req);
}

EXPORT bool _sandbox_in_a_container(void)
{
	char path[1024] = { 0 };
	return sandbox_container_path_for_pid(getpid(), path, sizeof(path)) == 0;
}

/* Call 13: { identifier, path, is application group, persona }. */
static int set_container_path(const char *identifier, const char *path, uint64_t group, uint32_t persona)
{
	struct { const char *identifier; const char *path; uint64_t group; uint64_t persona; } req = {
		identifier, path, group, persona,
	};
	return __sandbox_ms("Sandbox", 13, &req);
}

EXPORT int sandbox_set_container_path_for_signing_id(const char *id, const char *path)
{
	return set_container_path(id, path, 0, UINT32_MAX);
}

EXPORT int sandbox_set_container_path_for_signing_id_with_persona(const char *id, const char *path, uint32_t persona)
{
	return set_container_path(id, path, 0, persona);
}

EXPORT int sandbox_set_container_path_for_application_group(const char *group, const char *path)
{
	return set_container_path(group, path, 1, UINT32_MAX);
}

EXPORT int sandbox_set_container_path_for_application_group_with_persona(const char *group, const char *path,
    uint32_t persona)
{
	return set_container_path(group, path, 1, persona);
}

EXPORT int sandbox_set_container_path_for_audit_token(const audit_token_t *token, const char *path)
{
	struct { uint64_t pid, pidversion; const char *path; } req = {
		(uint32_t)token->val[5], (uint32_t)token->val[7], path,
	};
	return __sandbox_ms("Sandbox", 66, &req);
}

EXPORT int sandbox_get_container_expected(bool *expected, bool *transitional)
{
	uint64_t a = 0, b = 0;
	struct { uint64_t *a, *b; } req = { &a, &b };
	if (__sandbox_ms("Sandbox", 67, &req) != 0)
		return -1;
	if (expected)
		*expected = a != 0;
	if (transitional)
		*transitional = b != 0;
	return 0;
}

/* Returns 0 or an errno value. */
EXPORT int sandbox_check_protected_app_container(pid_t pid, bool *protected_container, bool *other)
{
	struct { int64_t pid; uint64_t *flags; uint64_t value; } req = { pid, NULL, 0 };
	req.flags = &req.value;
	if (__sandbox_ms("Sandbox", 77, &req) != 0)
		return errno;
	uint8_t f = (uint8_t)req.value;
	*protected_container = f & 1;
	*other = (f >> 1) & 1;
	return 0;
}

/* Call 51: a process's container path or profile name. */
static int proc_get(uint64_t what, const audit_token_t *token, uint64_t arg, uint64_t *out)
{
	uint64_t value = *out;
	struct { uint64_t what, pid, pidversion, arg; uint64_t *out; } req = {
		what, (uint32_t)token->val[5], (uint32_t)token->val[7], arg, &value,
	};
	int r = __sandbox_ms("Sandbox", 51, &req);
	*out = value;
	return r != 0 ? -1 : 0;
}

EXPORT int sandbox_proc_getcontainer(const audit_token_t *token, uint64_t arg, uint64_t *out)
{
	return proc_get(1, token, arg, out);
}

EXPORT int sandbox_proc_getprofilename(const audit_token_t *token, uint64_t arg, uint64_t *out)
{
	return proc_get(0, token, arg, out);
}

/* ---- references, state, notes ---- */

EXPORT int64_t sandbox_reference_retain_by_audit_token(const audit_token_t *token)
{
	int64_t ref = -1;
	struct { uint64_t pid, pidversion; int64_t *ref; } req = {
		(uint32_t)token->val[5], (uint32_t)token->val[7], &ref,
	};
	return __sandbox_ms("Sandbox", 28, &req) == 0 ? ref : -1;
}

EXPORT int sandbox_reference_release(int64_t ref)
{
	return __sandbox_ms("Sandbox", 29, &ref);
}

EXPORT bool sandbox_enable_state_flag(const char *flag, const audit_token_t *token)
{
	struct { uint64_t pid, pidversion; const char *flag; } req = {
		(uint32_t)token->val[5], (uint32_t)token->val[7], flag,
	};
	return __sandbox_ms("Sandbox", 65, &req) == 0;
}

EXPORT bool sandbox_enable_local_state_flag(const char *flag)
{
	(void)flag;
	errno = ENOTSUP;
	return false;
}

EXPORT int sandbox_note(const char *note)
{
	return __sandbox_ms("Sandbox", 3, &note);
}

EXPORT int sandbox_passthrough_access(int fd, const char *path)
{
	struct { int64_t fd; const char *path; } req = { fd, path };
	return __sandbox_ms("Sandbox", 12, &req);
}

EXPORT int sandbox_suspend(pid_t pid)
{
	int64_t p = pid;
	return __sandbox_ms("Sandbox", 10, &p);
}

EXPORT int sandbox_unsuspend(void)
{
	return __sandbox_ms("Sandbox", 11, NULL);
}

EXPORT bool sandbox_builtin_query(const char *name)
{
	return __sandbox_ms("Sandbox", 22, &name) == 0;
}

/* The data volume's paths seen through the system volume (call 82). */
EXPORT int sandbox_enable_root_translation(const char *data_volume)
{
	if (strcmp(data_volume, "/System/Volumes/Data")) {
		sandbox_warn("%s: unsupported data volume path: %s", "sandbox_enable_root_translation", data_volume);
		errno = EINVAL;
		return -1;
	}
	return __sandbox_ms("Sandbox", 82, NULL);
}

/* Preference domains whose files the policy protects from tampering. */
EXPORT bool sandbox_requests_integrity_protection_for_preference_domain(const char *domain)
{
	return !strcasecmp(domain, "com.apple.universalaccess") || !strcasecmp(domain, "com.apple.networkserviceproxy") ||
	    !strcasecmp(domain, "com.apple.inputsources");
}

/* ---- registrations: return 0 or an errno value ---- */

static int register_call(int call, int64_t arg)
{
	return __sandbox_ms("Sandbox", call, &arg) == 0 ? 0 : errno;
}

EXPORT int sandbox_register_app_container(int fd) { return register_call(75, fd); }
EXPORT int sandbox_unregister_app_container(int fd) { return register_call(76, fd); }
EXPORT int sandbox_register_disk_image_backing_store(int fd) { return register_call(85, fd); }
EXPORT int sandbox_unregister_disk_image_backing_store(int fd) { return register_call(86, fd); }
EXPORT int sandbox_register_sync_root(int fd) { return register_call(69, fd); }
EXPORT int _sandbox_register_app_bundle_0(int fd) { return register_call(62, fd); }
EXPORT int sandbox_unregister_app_bundle(int fd) { return register_call(63, fd); }

/* Call 71: { fd, team kind (0 team, 1 team package, 2 platform, 3 platform
 * package), bundle (1) or container (2), team id, signing id }. */
static int register_exception(const char *fn, int fd, uint32_t what, uint64_t kind, const char *team,
    const char *signing_id)
{
	struct { int64_t fd; uint64_t kind; uint64_t what; const char *team; const char *signing_id; } req = {
		fd, kind, what, team, signing_id,
	};
	if (__sandbox_ms("Sandbox", 71, &req) == 0)
		return 0;
	int e = errno;
	sandbox_warn("%s failed for team-id=%s, signing-id=%s: #%d (%s)", fn, kind < 2 ? team : "(platform)",
	    signing_id, e, strerror(e));
	return e;
}

static int register_exception_for(const char *fn, int fd, uint32_t what, const void *platform,
    const char *team, const char *signing_id, bool package)
{
	bool is_platform = team == platform;
	uint64_t kind = (is_platform ? 2 : 0) + package;
	return register_exception(fn, fd, what, kind, is_platform ? NULL : team, signing_id);
}

EXPORT int sandbox_register_app_bundle_exception(int fd, const char *team, const char *signing_id)
{
	return register_exception_for("sandbox_register_app_bundle_exception", fd, 1,
	    kSandboxAppBundlePlatformTeamId, team, signing_id, false);
}

EXPORT int sandbox_register_app_bundle_package_exception(int fd, const char *team, const char *signing_id)
{
	return register_exception_for("sandbox_register_app_bundle_package_exception", fd, 1,
	    kSandboxAppBundlePlatformTeamId, team, signing_id, true);
}

EXPORT int sandbox_register_app_container_exception(int fd, const char *team, const char *signing_id)
{
	return register_exception_for("sandbox_register_app_container_exception", fd, 2,
	    kSandboxAppContainerPlatformTeamId, team, signing_id, false);
}

EXPORT int sandbox_register_app_container_package_exception(int fd, const char *team, const char *signing_id)
{
	return register_exception_for("sandbox_register_app_container_package_exception", fd, 2,
	    kSandboxAppContainerPlatformTeamId, team, signing_id, true);
}

/* Register an app bundle and, given a team, its exceptions for any signing
 * identifier. */
EXPORT int _sandbox_register_app_bundle_1(int fd, const char *team)
{
	int r = _sandbox_register_app_bundle_0(fd);
	if (r || !team)
		return r;
	r = sandbox_register_app_bundle_exception(fd, team, NULL);
	if (r)
		return r;
	return sandbox_register_app_bundle_package_exception(fd, team, NULL);
}

EXPORT int sandbox_register_app_bundle(int fd, const char *team)
{
	return _sandbox_register_app_bundle_1(fd, team);
}

EXPORT int sandbox_register_bastion_profile(const void *profile, size_t size)
{
	struct { const void *profile; uint64_t size; uint64_t zero[2]; } req = { profile, size, { 0, 0 } };
	return __sandbox_ms("Sandbox", 68, &req);
}

EXPORT int sandbox_unregister_bastion_profile(void)
{
	struct { const void *profile; uint64_t size; uint64_t zero[2]; } req = { 0 };
	return __sandbox_ms("Sandbox", 68, &req);
}

/* ---- spawn attributes ---- */

struct sandbox_spawnattrs {
	uint32_t version;          /* 0 */
	uint32_t size;             /* 0x450 */
	uint32_t profile_length;
	uint32_t container_length;
	char profile[0x40];
	char container[0x400];
};
_Static_assert(sizeof(struct sandbox_spawnattrs) == 0x450, "spawnattrs");

EXPORT void sandbox_spawnattrs_init(struct sandbox_spawnattrs *a)
{
	a->version = 0;
	a->size = sizeof(*a);
	a->profile_length = 0;
	a->container_length = 0;
	a->profile[0] = 0;
	a->container[0] = 0;
}

EXPORT int sandbox_spawnattrs_setprofilename(struct sandbox_spawnattrs *a, const char *name)
{
	size_t n = strlen(name);
	if (n >= sizeof(a->profile)) {
		errno = EINVAL;
		return -1;
	}
	memcpy(a->profile, name, n + 1);
	a->profile_length = (uint32_t)n;
	return 0;
}

EXPORT int sandbox_spawnattrs_setcontainer(struct sandbox_spawnattrs *a, const char *path)
{
	size_t n = strlen(path);
	if (n >= sizeof(a->container)) {
		errno = EINVAL;
		return -1;
	}
	memcpy(a->container, path, n + 1);
	a->container_length = (uint32_t)n;
	return 0;
}

EXPORT int sandbox_spawnattrs_getprofilename(struct sandbox_spawnattrs *a, const char **name)
{
	*name = a->profile;
	return 0;
}

EXPORT int sandbox_spawnattrs_getcontainer(struct sandbox_spawnattrs *a, const char **path)
{
	*path = a->container;
	return 0;
}

/* ---- storage classes ---- */

EXPORT int sandbox_check_storage_class(int fd, const char *path, uint64_t storage_class)
{
	uint8_t trusted = 0;
	struct { int64_t fd; const char *path; uint64_t storage_class; uint8_t *trusted; } req = {
		fd, path, storage_class, &trusted,
	};
	if (__sandbox_ms("Sandbox", 87, &req) != 0)
		return -1;
	return trusted ^ 1;
}

/*
 * Issue a file extension for `path` to the process with `token`, provided
 * the process may perform `operation` on `related_path` (a document's
 * related file, such as its sidecar). Call 2 asks the kernel; a related
 * item it already knows about gets the extension directly, otherwise the
 * process must pass an ordinary check first.
 */
EXPORT char *sandbox_extension_issue_related_file_to_process(const char *class, const char *related_path,
    const char *path, const char *operation, uint32_t type, audit_token_t token)
{
	uint64_t denied = 0, related = 0;
	struct check_request req = {
		.result = &denied, .pid = (uint32_t)token.val[5], .operation = operation_fixup(operation),
		.filter_kind = 1, .filter_arg = (uint64_t)related_path,
		.flags = (0x42000002 + ((type & 0x40000000) != 0)) | ((type >> 25) & 8) | ((type >> 23) & 0x10),
		.target = (uint32_t)token.val[7],
	};
	req.reserved[6] = (uint64_t)&related;   /* 0x68 */
	if (type & 0x81fffffeu) {
		errno = EINVAL;
		return NULL;
	}
	if (__sandbox_ms("Sandbox", 2, &req) != 0)
		return NULL;
	if (denied) {
		errno = EPERM;
		return NULL;
	}
	uint32_t flags = EXT_TO_TOKEN | 2;
	if (!related) {
		int r = sandbox_check_by_audit_token(&token, operation, type | 0x20000001, path);
		if (r < 0)
			return NULL;
		if (r > 0) {
			errno = EPERM;
			return NULL;
		}
		flags += 0x2000;
	}
	return extension_issue(class, EXT_FILE, path, flags, token.val[5], token.val[7]);
}

/* ---- entering a sandbox ---- */

/* Tell libxpc the process is now sandboxed (Apple's library aborts if
 * libxpc can't be told). */
EXPORT void _sandbox_enter_notify_libxpc(void)
{
	void (*f)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "_xpc_runtime_process_has_entered_sandbox");
	if (!f)
		abort();
	f();
}

/* The error string sandbox_init returns when the compiler gave none; never
 * freed (sandbox_free_error knows it). */
static char internal_error[19];

EXPORT void sandbox_free_error(char *error)
{
	if (error != internal_error)
		free(error);
}

/*
 * sandbox_init: compile a profile with libsandbox (an SBPL string, a named
 * profile or a file, with parameters) and apply it; or (flags 2 and 4) ask
 * the kernel to apply a built-in profile by name (call 1).
 */
EXPORT int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char *const parameters[],
    char **errorbuf)
{
	char *local_error = NULL;
	char **err = errorbuf ? errorbuf : &local_error;
	int r = -1;
	void *params = NULL, (*free_params)(void *) = NULL;
	*err = NULL;

	void *lib = dlopen("/usr/lib/libsandbox.1.dylib", RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
	if (!lib) {
		asprintf(err, "%s", dlerror());
		goto done;
	}
	if (parameters) {
		void *(*create_params)(void) = (void *(*)(void))dlsym(lib, "sandbox_create_params");
		int (*set_param)(void *, const char *, const char *) =
		    (int (*)(void *, const char *, const char *))dlsym(lib, "sandbox_set_param");
		free_params = (void (*)(void *))dlsym(lib, "sandbox_free_params");
		if (!create_params || !set_param || !free_params) {
			asprintf(err, "%s", dlerror());
			free_params = NULL;
			goto close;
		}
		if (!(params = create_params())) {
			asprintf(err, "%s", strerror(errno));
			goto close;
		}
		for (const char *const *p = parameters; p[0]; p += 2)
			if (set_param(params, p[0], p[1]) != 0) {
				asprintf(err, "%s", strerror(errno));
				goto free_params;
			}
	}

	const char *compiler;
	switch (flags) {
	case 0: compiler = "sandbox_compile_string"; break;
	case 1: compiler = "sandbox_compile_named"; break;
	case 3: compiler = "sandbox_compile_file"; break;
	case 2: case 4: {
		struct { const char *name; uint64_t zero[2]; } req = { profile, { 0, 0 } };
		r = __sandbox_ms("Sandbox", 1, &req);
		if (r != 0)
			asprintf(err, "%s", strerror(errno));
		else
			_sandbox_enter_notify_libxpc();
		goto free_params;
	}
	default:
		asprintf(err, "bad flags");
		goto free_params;
	}
	void *(*compile)(const char *, void *, char **) = (void *(*)(const char *, void *, char **))dlsym(lib, compiler);
	if (!compile) {
		asprintf(err, "%s", dlerror());
		goto free_params;
	}
	void *compiled = compile(profile, params, err);
	if (!compiled)
		goto free_params;
	int (*apply)(void *) = (int (*)(void *))dlsym(lib, "sandbox_apply");
	if (!apply)
		asprintf(err, "%s", dlerror());
	else if (apply(compiled) != 0)
		asprintf(err, "%s", strerror(errno));
	else
		r = 0;
	void (*free_profile)(void *) = (void (*)(void *))dlsym(lib, "sandbox_free_profile");
	if (free_profile)
		free_profile(compiled);
free_params:
	if (params)
		free_params(params);
close:
	dlclose(lib);
done:
	if (*err)
		sandbox_warn("sandbox initialization failed: %s", *err);
	if (err == &local_error) {
		if (local_error != internal_error)
			free(local_error);
	} else if (r != 0 && !*err) {
		strlcpy(internal_error, "compilation failed", sizeof(internal_error));
		*err = internal_error;
	}
	return r;
}

EXPORT int sandbox_init(const char *profile, uint64_t flags, char **errorbuf)
{
	return sandbox_init_with_parameters(profile, flags, NULL, errorbuf);
}

/* Take on another process's sandbox (call 30). */
EXPORT int sandbox_init_from_pid(pid_t pid)
{
	int64_t p = pid;
	int r = __sandbox_ms("Sandbox", 30, &p);
	if (r == 0)
		_sandbox_enter_notify_libxpc();
	return r;
}

/* Apply a compiled profile (call 0). */
EXPORT int sandbox_apply_bytecode(const void *bytecode, size_t size, const char *container)
{
	if (!bytecode) {
		errno = EINVAL;
		return -1;
	}
	struct { const void *bytecode; uint64_t size; const char *container; uint64_t container_size; } req = {
		bytecode, size, container, container ? strlen(container) + 1 : 0,
	};
	return __sandbox_ms("Sandbox", 0, &req);
}
