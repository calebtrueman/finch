/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <reboot2.h>: ask the service manager to reboot or halt. On Finch,
 * reboot3() asks finch-init to stop every job and process, sync, and call
 * reboot(2) with `howto` (RB_* from <sys/reboot.h>). Root only. Returns 0
 * once finch-init has accepted, or an errno value.
 */

#ifndef _REBOOT2_H_
#define _REBOOT2_H_

#include <stdint.h>
#include <sys/cdefs.h>
#include <sys/reboot.h>

__BEGIN_DECLS

int reboot3(uint64_t howto, ...);

__END_DECLS

#endif
