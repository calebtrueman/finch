/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <ne_session.h>: libsystem_networkextension's session interface (VPN and
 * other network-extension sessions), as configd uses it. Apple doesn't
 * publish this header.
 *
 * Status values were read from macOS 26.4's SystemConfiguration
 * (SCNetworkConnectionGetStatusFromNEStatus maps status - 1 through a
 * five-entry table to kSCNetworkConnection{Disconnected, Connecting,
 * Connected, Connecting, Disconnecting}). The session-type, info-type and
 * event values are added once they are verified the same way.
 */

#ifndef _FINCH_NE_SESSION_H_
#define _FINCH_NE_SESSION_H_

#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/cdefs.h>
#include <uuid/uuid.h>
#include <xpc/xpc.h>

__BEGIN_DECLS

typedef enum {
	NESessionStatusInvalid       = 0,
	NESessionStatusDisconnected  = 1,
	NESessionStatusConnecting    = 2,
	NESessionStatusConnected     = 3,
	NESessionStatusReasserting   = 4,
	NESessionStatusDisconnecting = 5,
} ne_session_status_t;

typedef struct ne_session_s *ne_session_t;
typedef int ne_session_type_t;
typedef int ne_session_info_type_t;
typedef int ne_session_event_t;

typedef void (^ne_session_status_handler_t)(ne_session_status_t status);
typedef void (^ne_session_info_handler_t)(xpc_object_t info);
typedef void (^ne_session_event_handler_t)(ne_session_event_t event, void *event_data);

ne_session_t ne_session_create(uuid_t configuration_id, ne_session_type_t type);
void ne_session_retain(ne_session_t session);
void ne_session_release(ne_session_t session);
void ne_session_cancel(ne_session_t session);
void ne_session_set_event_handler(ne_session_t session, dispatch_queue_t queue, ne_session_event_handler_t handler);
void ne_session_get_status(ne_session_t session, dispatch_queue_t queue, ne_session_status_handler_t handler);
void ne_session_get_info(ne_session_t session, ne_session_info_type_t type, dispatch_queue_t queue, ne_session_info_handler_t handler);
void ne_session_start_with_options(ne_session_t session, xpc_object_t options);
void ne_session_stop(ne_session_t session);
void ne_session_send_barrier(ne_session_t session);
bool ne_session_use_as_system_vpn(void);
bool ne_session_always_on_vpn_configs_present(void);

__END_DECLS

#endif
