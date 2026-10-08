/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <rootless.h>: System Integrity Protection helpers in libsystem_sandbox
 * (Apple doesn't publish this header). Prototypes are those of Finch's
 * implementation (userland/libsystem/sandbox/rootless.c), which follows
 * macOS 26.4's library.
 */
#ifndef _ROOTLESS_H_
#define _ROOTLESS_H_

#include <stdbool.h>
#include <stdint.h>
#include <sys/cdefs.h>
#include <sys/types.h>

__BEGIN_DECLS

int rootless_apply_internal(const void *manifest, const char *base, const char *path, unsigned flags);
int rootless_apply(const void *manifest, const char *path);
int rootless_apply_relative(const void *manifest, const char *base, const char *path);
void *rootless_manifest_parse(const char *path);
void rootless_manifest_free(void *manifest);
bool rootless_preflight(const char *path, const void *manifest);
int rootless_convert_to_datavault(const char *path, const char *name);
int rootless_check_trusted(const char *path) { return trusted(path, -1, NULL); }
int rootless_check_trusted_fd(int fd) { return trusted(NULL, fd, NULL); }
int rootless_check_trusted_class(const char *path, const char *name);
int rootless_check_datavault_flag(const char *path, const char *name);
int rootless_check_restricted_flag(const char *path, const char *name);
int rootless_restricted_environment(void);
int rootless_protected_volume(const char *path);
int rootless_protected_volume_fd(int fd);
int rootless_mkdir_restricted(const char *path, mode_t mode, const char *name);
int rootless_mkdir_datavault(const char *path, mode_t mode, const char *name);
int rootless_mkdir_nounlink(const char *path, mode_t mode, const char *name);
int rootless_remove_datavault_in_favor_of_static_storage_class(const char *path);
int rootless_remove_restricted_in_favor_of_static_storage_class(const char *path);
int rootless_allows_task_for_pid(void) { return 1; }
int rootless_suspend(void) { return 0; }
void rootless_register_trusted_storage_class(const char *name, unsigned index);
uint32_t rootless_trusted_by_self_token(int fd, unsigned index);
bool rootless_verify_trusted_by_self_token(uint32_t token, unsigned index);

__END_DECLS

#endif /* !_ROOTLESS_H_ */
