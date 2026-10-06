/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <opendirectory/odipc.h>: Open Directory's Mach service names, as used by
 * Libinfo's directory-services module and membership APIs. The release names
 * are the services opendirectoryd registers on macOS 26 (launchctl print
 * system); the debug names and the RPC dictionary keys are the strings in
 * macOS 26.4's libsystem_info. On Finch these resolve through finch-init's bootstrap server once a
 * directory service registers them.
 */

#ifndef _OPENDIRECTORY_ODIPC_H_
#define _OPENDIRECTORY_ODIPC_H_

#define kODMachLibinfoPortName          "com.apple.system.opendirectoryd.libinfo"
#define kODMachMembershipPortName       "com.apple.system.opendirectoryd.membership"
#define kODMachLibinfoPortNameDebug     "com.apple.system.opendirectoryd.libinfo_debug"
#define kODMachMembershipPortNameDebug  "com.apple.system.opendirectoryd.membership_debug"

/* Libinfo RPC request/reply keys (xpc_pipe routines to the libinfo service). */
#define OD_RPC_NAME     "rpc_name"
#define OD_RPC_VERSION  "rpc_version"
#define OD_RPC_RESULT   "result"
#define OD_RPC_ERROR    "error"

#endif
