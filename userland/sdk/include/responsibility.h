/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <responsibility.h>: process responsibility SPI, exported by libquarantine
 * (Apple doesn't publish the header). Signatures are those of macOS 26.4's
 * libquarantine, as implemented in userland/libsystem/quarantine.
 */

#ifndef _RESPONSIBILITY_H_
#define _RESPONSIBILITY_H_

#include <spawn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/cdefs.h>
#include <sys/types.h>

__BEGIN_DECLS

typedef struct responsibility_identity *responsibility_identity_t;

/*
 * The process responsible for pid: its pid, unique id and executable path
 * (any may be NULL). On entry *pathlen is the size of path; 0 is ERANGE.
 * Returns 0 or an errno value.
 */
int responsibility_get_responsible_for_pid(pid_t pid, pid_t *rpid, uint64_t *runiqueid,
    size_t *pathlen, char *path);
pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);			/* -1 on error */
uint64_t responsibility_get_uniqueid_responsible_for_pid(pid_t pid);		/* UINT64_MAX on error */
int responsibility_get_responsible_audit_token_for_audit_token(const void *token, void *out,
    uint64_t *x, void *y);

int responsibility_init(int value);
int responsibility_set_pid_responsible_for_pid(pid_t pid, pid_t rpid);
int responsibility_set_audittoken_responsible_for_self(const void *token);
int responsibility_set_audittoken_responsible_for_caller(const void *token);
int responsibility_set_caller_responsible_for_self(void);
int responsibility_set_hosted_path(const char *path);
int responsibility_set_hosted_team_id(const char *team_id);

int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attr, int disclaim);
int responsibility_spawnattrs_getdisclaim(const posix_spawnattr_t *attr, char *disclaim);

responsibility_identity_t responsibility_get_attribution_for_audittoken(const void *token, int x);
const void *responsibility_identity_get_binary_entitlement_data(responsibility_identity_t i,
    uint64_t *length);
bool responsibility_identity_get_binary_is_platform(responsibility_identity_t i);
uint64_t responsibility_identity_get_binary_offset(responsibility_identity_t i);
const char *responsibility_identity_get_binary_path(responsibility_identity_t i);
const char *responsibility_identity_get_binary_signing_id(responsibility_identity_t i);
const char *responsibility_identity_get_binary_team_id(responsibility_identity_t i);
uint64_t responsibility_identity_get_csflags(responsibility_identity_t i);
const char *responsibility_identity_get_hosted_path(responsibility_identity_t i);
const char *responsibility_identity_get_hosted_team_id(responsibility_identity_t i);
uint32_t responsibility_identity_get_platform(responsibility_identity_t i);
uint32_t responsibility_identity_get_sdk(responsibility_identity_t i);
const void *responsibility_identity_get_persistent_identifier(responsibility_identity_t i, int which);
int responsibility_identity_open_binary_fd(responsibility_identity_t i, int flags);
void responsibility_identity_release(responsibility_identity_t i);

__END_DECLS

#endif /* !_RESPONSIBILITY_H_ */
