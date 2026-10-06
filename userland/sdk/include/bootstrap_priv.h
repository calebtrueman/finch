/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <bootstrap_priv.h>: bootstrap_look_up2() flags. The values are those of the
 * last open-source launchd (launchd-842, liblaunch/bootstrap_priv.h).
 * Finch's bootstrap server has one domain and accepts and ignores them.
 */

#ifndef __BOOTSTRAP_PRIVATE_H__
#define __BOOTSTRAP_PRIVATE_H__

#include <servers/bootstrap.h>
#include <xpc/private.h>

#define BOOTSTRAP_PER_PID_SERVICE   0x1
#define BOOTSTRAP_ALLOW_LOOKUP      0x2
#define BOOTSTRAP_DENY_JOB_CREATION 0x4
#define BOOTSTRAP_PRIVILEGED_SERVER 0x8
#define BOOTSTRAP_FORCE_LOCAL       0x10
#define BOOTSTRAP_SPECIFIC_INSTANCE 0x20
#define BOOTSTRAP_STRICT_CHECKIN    0x40
#define BOOTSTRAP_STRICT_LOOKUP     0x80

#endif
