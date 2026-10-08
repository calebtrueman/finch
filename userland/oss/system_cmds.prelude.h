/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into system_cmds (tools/build-oss.sh).
 *
 * In Apple's internal SDK <sys/proc_info.h> ends by including
 * <sys/proc_info_private.h> (PROC_PIDCOALITIONINFO, PROC_INFO_CALL_*), and
 * the coalition types come with it. gcore relies on that. Finch's SDK has
 * the public header, so the private half is included here (xnu's own copy).
 */
#include <sys/proc_info.h>
#include <sys/proc_info_private.h>
#include <mach/coalition.h>

/*
 * Likewise <sys/resource.h> brings in <sys/resource_private.h> (taskpolicy's
 * IOPOL_TYPE_VFS_* and PRIO_DARWIN_ROLE_*), and <sys/kdebug.h> brings in
 * <sys/kdebug_private.h> (latency's and sc_usage's trace buffer types).
 */
#include <sys/resource.h>
#include <sys/resource_private.h>
#include <sys/kdebug.h>
#include <sys/kdebug_private.h>
