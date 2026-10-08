/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <vproc_priv.h>: the liblaunch private calls Apple's open-source commands
 * use. A user has one domain on Finch (docs/design/SERVICES.md), standing in
 * for every launchd session type, so switching sessions or detaching from
 * the console's has nothing to do and succeeds.
 */

#ifndef __VPROC_PRIVATE_H__
#define __VPROC_PRIVATE_H__

#include <stdint.h>
#include <sys/types.h>
#include <sys/cdefs.h>
#include <vproc.h>

__BEGIN_DECLS

typedef uint64_t vproc_flags_t;

/* launchd session types (LimitLoadToSessionType). */
#define VPROCMGR_SESSION_LOGINWINDOW "LoginWindow"
#define VPROCMGR_SESSION_BACKGROUND  "Background"
#define VPROCMGR_SESSION_AQUA        "Aqua"
#define VPROCMGR_SESSION_STANDARDIO  "StandardIO"
#define VPROCMGR_SESSION_SYSTEM      "System"

/* Keys for vproc_swap_integer(); values from launchd-842's vproc_priv.h. */
typedef enum {
	VPROC_GSK_ZERO,
	VPROC_GSK_LAST_EXIT_STATUS,
	VPROC_GSK_GLOBAL_ON_DEMAND,
	VPROC_GSK_MGR_UID,
	VPROC_GSK_MGR_PID,
	VPROC_GSK_IS_MANAGED,
} vproc_gsk_t;

/* Reads (outval) and/or sets (inval) a launchd value. Finch's libxpc reads
 * VPROC_GSK_MGR_UID and VPROC_GSK_MGR_PID; other keys report an error. */
vproc_err_t vproc_swap_integer(vproc_t vp, vproc_gsk_t key, int64_t *inval, int64_t *outval);

/* Returns NULL on success (as every vproc call does). */
vproc_err_t _vprocmgr_detach_from_console(vproc_flags_t flags);
vproc_err_t _vprocmgr_switch_to_session(const char *target_session, vproc_flags_t flags);
/* Root: make the caller's bootstrap port `target_user`'s domain. */
vproc_err_t _vprocmgr_move_subset_to_user(uid_t target_user, const char *session_type, uint64_t flags);
vproc_err_t _vproc_post_fork_ping(void);

__END_DECLS

#endif
