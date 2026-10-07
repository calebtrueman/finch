/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_coreservices entry points that postdate the published sources
 * (_dirhelper.c and NSSystemDirectories.c, from Libc-997.90.3). Argument
 * orders were read from macOS 26.4's library (see docs/design/PHASE1-EXIT.md).
 */

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/types.h>
#include <unistd.h>

#include <mach-o/dyld_priv.h>

#include "NSSystemDirectories.h"
#include "dirhelper_priv.h"

char *_dirhelper(dirhelper_which_t which, char *path, size_t pathlen);
void _dirhelper_fork_child(void);

#pragma mark - sysdir (public, <sysdir.h>): the NSSearchPath enumeration under its new name

unsigned int sysdir_start_search_path_enumeration(unsigned int dir, unsigned int domainMask);
unsigned int sysdir_start_search_path_enumeration_private(unsigned int dir, unsigned int domainMask);
unsigned int sysdir_get_next_search_path_enumeration(unsigned int state, char *path);
NSSearchPathEnumerationState NSStartSearchPathEnumerationPrivate(NSSearchPathDirectory dir,
    NSSearchPathDomainMask domainMask);

unsigned int
sysdir_start_search_path_enumeration(unsigned int dir, unsigned int domainMask)
{
	return NSStartSearchPathEnumeration(dir, domainMask);
}

unsigned int
sysdir_start_search_path_enumeration_private(unsigned int dir, unsigned int domainMask)
{
	return NSStartSearchPathEnumeration(dir, domainMask);
}

unsigned int
sysdir_get_next_search_path_enumeration(unsigned int state, char *path)
{
	return NSGetNextSearchPathEnumeration(state, path);
}

NSSearchPathEnumerationState
NSStartSearchPathEnumerationPrivate(NSSearchPathDirectory dir, NSSearchPathDomainMask domainMask)
{
	return NSStartSearchPathEnumeration(dir, domainMask);
}

#pragma mark - Per-user directories relative to a volume

/* True if `relpath` is on the root volume (or not given). */
static bool
on_root_volume(const char *relpath)
{
	struct statfs sfs;
	if (relpath == NULL || *relpath == '\0') return true;
	if (statfs(relpath, &sfs) != 0) return false;
	return strcmp(sfs.f_mntonname, "/") == 0;
}

/*
 * The per-user directory on the volume containing `relpath`. For the root
 * volume that's the ordinary one. Other volumes' layout isn't documented, so
 * Finch reports ENOTSUP for them (FINCH-NOT-YET).
 */
char *_dirhelper_relative_with_hints(dirhelper_which_t which, const char *relpath, char *path,
    size_t pathlen, uint64_t hints);
char *_dirhelper_relative(dirhelper_which_t which, const char *relpath, char *path, size_t pathlen);
char *__user_relative_dirname_with_hints(uid_t uid, dirhelper_which_t which, const char *relpath,
    char *path, size_t pathlen, uint64_t hints);
char *__user_relative_dirname(uid_t uid, dirhelper_which_t which, const char *relpath, char *path,
    size_t pathlen);

char *
_dirhelper_relative_with_hints(dirhelper_which_t which, const char *relpath, char *path, size_t pathlen,
    uint64_t hints)
{
	(void)hints;
	if ((unsigned)which > DIRHELPER_USER_LOCAL_LAST) {
		errno = EINVAL;
		return NULL;
	}
	if (!on_root_volume(relpath)) {
		errno = ENOTSUP;
		return NULL;
	}
	return _dirhelper(which, path, pathlen);
}

char *
_dirhelper_relative(dirhelper_which_t which, const char *relpath, char *path, size_t pathlen)
{
	return _dirhelper_relative_with_hints(which, relpath, path, pathlen, 0);
}

char *
__user_relative_dirname_with_hints(uid_t uid, dirhelper_which_t which, const char *relpath, char *path,
    size_t pathlen, uint64_t hints)
{
	(void)hints;
	if (uid == 0) uid = getuid();   /* as Apple's: 0 means the caller */
	if ((unsigned)which > DIRHELPER_USER_LOCAL_LAST) {
		errno = EINVAL;
		return NULL;
	}
	if (!on_root_volume(relpath)) {
		errno = ENOTSUP;
		return NULL;
	}
	return __user_local_dirname(uid, which, path, pathlen);
}

char *
__user_relative_dirname(uid_t uid, dirhelper_which_t which, const char *relpath, char *path, size_t pathlen)
{
	return __user_relative_dirname_with_hints(uid, which, relpath, path, pathlen, 0);
}

#pragma mark - User directory suffix

static char *user_dir_suffix;

void _set_user_dir_suffix(const char *suffix);
char *_get_user_dir_suffix(void);
char *_finch_user_dir_suffix(void);

/* Validated as _dirhelper does: no path traversal. */
void
_set_user_dir_suffix(const char *suffix)
{
	free(user_dir_suffix);
	user_dir_suffix = NULL;
	if (suffix != NULL && *suffix != '\0' && strstr(suffix, "..") == NULL) {
		user_dir_suffix = strdup(suffix);
	}
}

/* The suffix in effect (set explicitly, else DIRHELPER_USER_DIR_SUFFIX for
 * unrestricted processes); not owned by the caller. */
char *
_finch_user_dir_suffix(void)
{
	if (user_dir_suffix != NULL) return user_dir_suffix;
	return dyld_process_is_restricted() ? NULL : getenv(DIRHELPER_ENV_USER_DIR_SUFFIX);
}

/* Caller frees. */
char *
_get_user_dir_suffix(void)
{
	char *s = _finch_user_dir_suffix();
	return s ? strdup(s) : NULL;
}

#pragma mark - Process hooks and test entry points

void _libcoreservices_fork_child(void);
int _idle_exit(void);
char *_dirhelper_test(dirhelper_which_t which, char *path, size_t pathlen);
int _dirhelper_remove_test(void);

/* Called by libSystem in a forked child: the per-user directory is recomputed. */
void
_libcoreservices_fork_child(void)
{
	_dirhelper_fork_child();
}

/* dirhelper's daemon idle-exit hook; Finch runs no dirhelper daemon. */
int
_idle_exit(void)
{
	return 0;
}

/* Test hooks of Apple's dirhelper daemon: not supported. */
char *
_dirhelper_test(dirhelper_which_t which, char *path, size_t pathlen)
{
	(void)which; (void)path; (void)pathlen;
	errno = ENOTSUP;
	return NULL;
}

int
_dirhelper_remove_test(void)
{
	return ENOTSUP;
}
