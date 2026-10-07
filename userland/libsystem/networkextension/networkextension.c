/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_networkextension: the client side of Network Extension (VPN,
 * content filter, DNS proxy and relay sessions, per-app VPN, NECP policy
 * helpers). On macOS the work is done by Apple's closed nesessionmanager and
 * nehelper daemons. Finch has neither yet (FINCH-NOT-YET), and no network
 * extension configurations, so this library answers as macOS does for a
 * configuration that doesn't exist: sessions are disconnected, carry no
 * info, never start, and are canceled when asked; no configuration of any
 * kind is present; nothing is blocked. Names, constants, the configuration
 * generation counter and the functions macOS itself implements as constants
 * match Apple's library (tests/ne-compare.c checks them against it).
 *
 * The exports nothing in the system calls are in stubs.c.
 */

#include <Block.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <uuid/uuid.h>
#include <xpc/xpc.h>

#define EXPORT __attribute__((visibility("default")))

/* ---- data ---- */

EXPORT const uint64_t NE_TRACKER_MAX_BACKTRACE_SIZE = 128;
EXPORT const uint64_t NE_TRACKER_MAX_PROCNAME_SIZE = 256;
EXPORT const uuid_t ne_privacy_proxy_netagent_id = {
	0x39, 0x07, 0x9e, 0x9b, 0x4b, 0x0a, 0x42, 0x6c, 0xa9, 0xef, 0xac, 0x19, 0x0b, 0x88, 0x2a, 0x80,
};
EXPORT const uuid_t ne_privacy_dns_netagent_id = {
	0x35, 0x3a, 0x4f, 0x9c, 0xce, 0xf5, 0x4c, 0xee, 0x93, 0xad, 0x46, 0x97, 0xbb, 0x03, 0x18, 0xd7,
};
EXPORT bool g_ne_uuid_cache_hit;
EXPORT bool g_ne_read_uuid_cache;

/* ---- names ---- */

EXPORT const char *ne_session_status_to_string(int status)
{
	static const char *const names[] = {
		"invalid", "disconnected", "connecting", "connected", "reasserting", "disconnecting",
	};
	return (unsigned)status < 6 ? names[status] : "invalid";
}

EXPORT const char *ne_session_type_to_string(int type)
{
	static const char *const names[] = {
		"<unknown>", "vpn", "appvpn", "aovpn", "contentfilter", "pathcontroller", "dnsproxy",
		"dnssettings", "apppush", "relay", "urlfilter", "hotspot-evaluation",
		"hotspot-authentication",
	};
	return (unsigned)type < 13 ? names[type] : "<unknown>";
}

EXPORT const char *ne_session_info_type_to_string(int type)
{
	static const char *const names[] = {
		"unknown", "statistics", "extended status", "configuration", "flow divert token",
		"app push send info",
	};
	return (unsigned)type < 6 ? names[type] : "unknown";
}

EXPORT const char *ne_session_stop_reason_to_string(int reason)
{
	static const char *const names[] = {
		"None",
		"Stop command received",
		"Device slept too long",
		"Plugin initiated",
		"No network available",
		"Network changed, tunnel no longer viable",
		"Plugin was disabled",
		"Plugin failed",
		"Authentication was canceled",
		"Device went to sleep",
		"Bad configuration",
		"Authentication took too long",
		"Tunnel did not come up in time",
		"Tunnel did not re-assert in time",
		"Tunnel must be started from the app",
		"Configuration does not have a server address",
		"Server address is invalid",
		"Failed to resolve the server address",
		"Negotiation with the server failed",
		"Tunnel was idle for too long",
		"Server is not responding",
		"Tunnel was terminated by the server",
		"Server is down or unreachable",
		"Authentication failed",
		"Client certificate is missing",
		"Client certificate is invalid",
		"Client certificate is not yet valid",
		"Client certificate has expired",
		"Server certificate is invalid",
		"Server certification is not yet valid",
		"Server certificate has expired",
		"Configuration was disabled",
		"Configuration was removed",
		"Configuration was superceded by another configuration",
		"User logged out",
		"Console user changed",
		"Tunnel is being re-started with different credentials",
		"Configuration has changed",
		"None",
		"On Demand Disconnect rule matched",
		"App Update",
		"Network preparation took to long",
	};
	return (unsigned)reason < sizeof(names) / sizeof(names[0]) ? names[reason] : "None";
}

/* ---- sessions ---- */

enum {
	NESessionStatusDisconnected = 1,
	NESessionEventCanceled = 2,
};

typedef void (^ne_session_event_handler_t)(int event, void *event_data);
typedef void (^ne_session_status_handler_t)(int status);
typedef void (^ne_session_info_handler_t)(xpc_object_t info);

typedef struct ne_session_s {
	_Atomic long refcount;
	uuid_t configuration_id;
	int type;
	dispatch_queue_t event_queue;
	ne_session_event_handler_t event_handler;
} *ne_session_t;

static dispatch_queue_t default_queue(void)
{
	return dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
}

EXPORT ne_session_t ne_session_create(const uuid_t configuration_id, int type)
{
	ne_session_t s = calloc(1, sizeof(*s));
	if (!s)
		return NULL;
	s->refcount = 1;
	if (configuration_id)
		uuid_copy(s->configuration_id, configuration_id);
	s->type = type;
	return s;
}

EXPORT void ne_session_retain(ne_session_t s)
{
	atomic_fetch_add(&s->refcount, 1);
}

static void clear_event_handler(ne_session_t s)
{
	if (s->event_handler)
		Block_release(s->event_handler);
	if (s->event_queue)
		dispatch_release(s->event_queue);
	s->event_handler = NULL;
	s->event_queue = NULL;
}

EXPORT void ne_session_release(ne_session_t s)
{
	if (atomic_fetch_sub(&s->refcount, 1) != 1)
		return;
	clear_event_handler(s);
	free(s);
}

EXPORT void ne_session_set_event_handler(ne_session_t s, dispatch_queue_t queue, ne_session_event_handler_t handler)
{
	clear_event_handler(s);
	if (!handler)
		return;
	s->event_handler = Block_copy(handler);
	s->event_queue = queue ? queue : default_queue();
	dispatch_retain(s->event_queue);
}

/* The session is canceled: the event handler hears so once, then is dropped. */
EXPORT void ne_session_cancel(ne_session_t s)
{
	ne_session_event_handler_t handler = s->event_handler;
	dispatch_queue_t queue = s->event_queue;
	s->event_handler = NULL;
	s->event_queue = NULL;
	if (!handler)
		return;
	dispatch_async(queue, ^{
		handler(NESessionEventCanceled, NULL);
		Block_release(handler);
	});
	dispatch_release(queue);
}

/* No configuration exists, so no session ever leaves "disconnected". */
EXPORT void ne_session_get_status(ne_session_t s, dispatch_queue_t queue, ne_session_status_handler_t handler)
{
	(void)s;
	if (!handler)
		return;
	ne_session_status_handler_t h = Block_copy(handler);
	dispatch_async(queue ? queue : default_queue(), ^{
		h(NESessionStatusDisconnected);
		Block_release(h);
	});
}

EXPORT void ne_session_get_info(ne_session_t s, int type, dispatch_queue_t queue, ne_session_info_handler_t handler)
{
	(void)s; (void)type;
	if (!handler)
		return;
	ne_session_info_handler_t h = Block_copy(handler);
	dispatch_async(queue ? queue : default_queue(), ^{
		h(NULL);
		Block_release(h);
	});
}

/* Starting or stopping a session that has no configuration does nothing. */
EXPORT void ne_session_start(ne_session_t s) { (void)s; }
EXPORT void ne_session_start_with_options(ne_session_t s, xpc_object_t options) { (void)s; (void)options; }
EXPORT void ne_session_start_on_behalf_of(ne_session_t s, xpc_object_t options, uint32_t bootstrap_port,
    uint32_t audit_session, uid_t uid, gid_t gid, pid_t pid)
{
	(void)s; (void)options; (void)bootstrap_port; (void)audit_session; (void)uid; (void)gid; (void)pid;
}
EXPORT void ne_session_stop(ne_session_t s) { (void)s; }
EXPORT void ne_session_send_barrier(ne_session_t s) { (void)s; }

/* ---- configurations ---- */

/* No network extension configuration of any kind exists. */
EXPORT bool ne_session_always_on_vpn_configs_present(void) { return false; }
EXPORT bool ne_session_always_on_vpn_configs_present_at_boot(void) { return false; }
EXPORT bool ne_session_app_vpn_configs_present(void) { return false; }
EXPORT bool ne_session_content_filter_configs_present(void) { return false; }
EXPORT bool ne_session_dns_proxy_configs_present(void) { return false; }
EXPORT bool ne_session_dns_settings_configs_present(void) { return false; }
EXPORT bool ne_session_local_communication_configs_present(void) { return false; }
EXPORT bool ne_session_on_demand_configs_present(void) { return false; }
EXPORT bool ne_session_path_controller_configs_present(void) { return false; }
EXPORT bool ne_session_relay_configs_present(void) { return false; }
EXPORT bool ne_session_urlfilter_configs_present(void) { return false; }
EXPORT bool ne_session_vod_evaluate_connection_present(void) { return false; }
EXPORT bool ne_session_vpn_configs_present(void) { return false; }
EXPORT bool ne_session_vpn_include_all_networks_configs_present(void) { return false; }
EXPORT bool ne_session_manager_is_running(void) { return false; }
EXPORT bool ne_session_manager_has_active_sessions(void) { return false; }

/* On macOS, sessions are always the system VPN. */
EXPORT bool ne_session_use_as_system_vpn(void) { return true; }

/*
 * The configuration generation: the state of the
 * "com.apple.neconfigurationchanged" notification, which the configuration
 * owner bumps on every change (0 until it does). Same logic as Apple's,
 * including starting over after a notify failure.
 */
EXPORT uint64_t ne_get_configuration_generation(void)
{
	static int token = -1;
	static uint64_t generation;
	if (token < 0 && notify_register_check("com.apple.neconfigurationchanged", &token) != NOTIFY_STATUS_OK) {
		token = -1;
		return generation;
	}
	int changed = 0;
	if (notify_check(token, &changed) != NOTIFY_STATUS_OK)
		goto fail;
	if (changed) {
		uint64_t state = 0;
		if (notify_get_state(token, &state) != NOTIFY_STATUS_OK)
			goto fail;
		generation = state & 0x7ffffffffffffull;
	}
	return generation;
fail:
	notify_cancel(token);
	token = -1;
	generation = 0;
	return 0;
}

/*
 * Applies the NECP "drop all" level saved in
 * /Library/Preferences/com.apple.networkextension.necp.plist at boot (launchd
 * calls it). Finch writes no NECP preferences yet, so there is nothing to
 * apply (FINCH-NOT-YET).
 */
EXPORT void ne_session_initialize_necp_drop_all(void) {}

/* ---- trackers: macOS's own implementations are these constants ---- */

EXPORT bool ne_tracker_check_is_hostname_blocked(void) { return false; }
EXPORT bool ne_tracker_should_save_stacktrace(void) { return false; }
EXPORT void *ne_tracker_copy_current_stacktrace(void) { return NULL; }
EXPORT void ne_tracker_create_xcode_issue(void) {}
EXPORT int ne_tracker_get_disposition(void) { return 1; }

/* ---- other constants in macOS's library ---- */

EXPORT int ne_session_policy_match_get_service_type(void) { return 0; }
EXPORT int ne_session_policy_match_get_service_action(void) { return 0; }
EXPORT int ne_session_service_get_dns_service_id(void) { return 0; }

/* ---- logging ---- */

EXPORT os_log_t ne_log_obj(void)
{
	static dispatch_once_t once;
	static os_log_t log;
	dispatch_once(&once, ^{ log = os_log_create("com.apple.networkextension", ""); });
	return log;
}

EXPORT os_log_t ne_log_large_obj(void)
{
	static dispatch_once_t once;
	static os_log_t log;
	dispatch_once(&once, ^{ log = os_log_create("com.apple.networkextension", "Large"); });
	return log;
}

EXPORT bool nelog_is_info_logging_enabled(void) { return os_log_type_enabled(ne_log_obj(), OS_LOG_TYPE_INFO); }
EXPORT bool nelog_is_debug_logging_enabled(void) { return os_log_type_enabled(ne_log_obj(), OS_LOG_TYPE_DEBUG); }
/* libsystem_darwin's (<os/variant_private.h>). */
extern bool os_variant_has_internal_diagnostics(const char *subsystem);

EXPORT bool nelog_is_extra_vpn_logging_enabled(void)
{
	return os_variant_has_internal_diagnostics("com.apple.networkextension.extra_vpn_logs");
}

EXPORT bool ne_session_is_safeboot(void)
{
	int safeboot = 0;
	size_t len = sizeof(safeboot);
	return sysctlbyname("kern.safeboot", &safeboot, &len, NULL, 0) == 0 && safeboot != 0;
}
