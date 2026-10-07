/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <vproc_priv.h>: the liblaunch private calls Apple's open-source commands
 * use. Finch has a single launchd-style session, so detaching from the
 * console's session has nothing to do and succeeds.
 */

#ifndef __VPROC_PRIVATE_H__
#define __VPROC_PRIVATE_H__

#include <stdint.h>
#include <sys/cdefs.h>
#include <vproc.h>

__BEGIN_DECLS

typedef uint64_t vproc_flags_t;

/* Keys for vproc_swap_integer(); values from launchd-842's vproc_priv.h. */
typedef enum {
	VPROC_GSK_ZERO,
	VPROC_GSK_LAST_EXIT_STATUS,
	VPROC_GSK_GLOBAL_ON_DEMAND,
	VPROC_GSK_MGR_UID,
	VPROC_GSK_MGR_PID,
	VPROC_GSK_IS_MANAGED,
} vproc_gsk_t;

/* Reads (outval) and/or sets (inval) a launchd value. Finch's libxpc
 * implements it; it reports an error for every key. */
vproc_err_t vproc_swap_integer(vproc_t vp, vproc_gsk_t key, int64_t *inval, int64_t *outval);

/* Returns NULL on success (as every vproc call does). */
vproc_err_t _vprocmgr_detach_from_console(vproc_flags_t flags);

__END_DECLS

#endif
