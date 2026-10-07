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

/* Returns NULL on success (as every vproc call does). */
vproc_err_t _vprocmgr_detach_from_console(vproc_flags_t flags);

__END_DECLS

#endif
