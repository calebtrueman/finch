/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <xpc/private.h>: the libxpc private interfaces that Apple's open-source
 * libSystem components (Libinfo, libdarwin, ...) compile against. Apple's
 * header isn't published. These declarations match Finch's libxpc
 * (userland/libxpc), which exports the same symbols with the same ABI as
 * Apple's.
 */

#ifndef __XPC_PRIVATE_H__
#define __XPC_PRIVATE_H__

#include <bsm/audit.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <xpc/xpc.h>

__BEGIN_DECLS

/* Pipes: synchronous request/response over a Mach port. */
typedef struct xpc_pipe_s *xpc_pipe_t;

/* Pipe creation flags. Finch's libxpc accepts and ignores them (it has one
 * bootstrap domain and no QoS propagation yet); values are Finch's own. */
#define XPC_PIPE_PRIVILEGED     0x1
#define XPC_PIPE_PROPAGATE_QOS  0x2

xpc_pipe_t xpc_pipe_create(const char *name, uint64_t flags);
xpc_pipe_t xpc_pipe_create_from_port(mach_port_t port, uint64_t flags);
xpc_pipe_t xpc_pipe_create_with_user_session_uid(const char *name, uid_t uid, uint64_t flags);
void xpc_pipe_invalidate(xpc_pipe_t pipe);
int xpc_pipe_simpleroutine(xpc_pipe_t pipe, xpc_object_t message);
int xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply);
int xpc_pipe_routine_with_flags(xpc_pipe_t pipe, xpc_object_t message, xpc_object_t *reply,
    uint64_t flags);
int xpc_pipe_receive(mach_port_t port, xpc_object_t *message);
int xpc_pipe_routine_reply(xpc_object_t reply);

/* Environment variable naming a sandboxed app's container (dirhelper uses it
 * as the per-user directory suffix). */
#define XPC_ENV_SANDBOX_CONTAINER_ID "APP_SANDBOX_CONTAINER_ID"

/* Is this process under App Sandbox? (Finch: never, yet.) */
bool _xpc_runtime_is_app_sandboxed(void);

/* Multi-user sessions (Finch has a single session: never enabled). */
bool xpc_user_sessions_enabled(void);
uid_t xpc_user_sessions_get_foreground_uid(int *error);
uid_t xpc_user_sessions_get_session_uid(void);

/* Objects. */
xpc_object_t xpc_create_from_plist(const void *data, size_t length);
xpc_object_t xpc_create_from_serialization(const void *data, size_t length);
void xpc_dictionary_get_audit_token(xpc_object_t xdict, audit_token_t *token);
xpc_object_t xpc_mach_send_create(mach_port_t port);
mach_port_t xpc_mach_send_copy_right(xpc_object_t xsend);
xpc_object_t xpc_mach_recv_create(mach_port_t port);
mach_port_t xpc_mach_recv_extract_right(xpc_object_t xrecv);
const char *xpc_strerror(int error);

/* Event publishers (launchd event streams). */
typedef struct finch_event_publisher_s *xpc_event_publisher_t;
typedef char event_name_t[128];

typedef enum {
	XPC_EVENT_PUBLISHER_ACTION_ADD = 0,
	XPC_EVENT_PUBLISHER_ACTION_REMOVE = 1,
	XPC_EVENT_PUBLISHER_ACTION_INITIAL_BARRIER = 2,
} xpc_event_publisher_action_t;

typedef void (^xpc_event_publisher_handler_t)(xpc_event_publisher_action_t action, uint64_t token,
    xpc_object_t descriptor);
typedef void (^xpc_event_publisher_error_handler_t)(int error);

xpc_event_publisher_t xpc_event_publisher_create(const char *stream, dispatch_queue_t queue);
void xpc_event_publisher_set_handler(xpc_event_publisher_t pub, xpc_event_publisher_handler_t handler);
void xpc_event_publisher_set_error_handler(xpc_event_publisher_t pub,
    xpc_event_publisher_error_handler_t handler);
void xpc_event_publisher_set_throttling(xpc_event_publisher_t pub, uint64_t max_inflight);
void xpc_event_publisher_activate(xpc_event_publisher_t pub);
int xpc_event_publisher_fire(xpc_event_publisher_t pub, uint64_t token, xpc_object_t details);
int xpc_event_publisher_fire_noboost(xpc_event_publisher_t pub, uint64_t token, xpc_object_t details);
au_asid_t xpc_event_publisher_get_subscriber_asid(xpc_event_publisher_t pub, uint64_t token);
bool xpc_get_service_identifier_for_token(uint64_t token, event_name_t name);

/* Entitlements. */
xpc_object_t xpc_copy_entitlement_for_self(const char *key);
xpc_object_t xpc_copy_entitlement_for_token(const char *key, audit_token_t *token);
xpc_object_t xpc_copy_entitlements_for_self(void);

/* Bootstrap. */
kern_return_t bootstrap_look_up2(mach_port_t bp, const name_t service_name, mach_port_t *sp,
    pid_t target_pid, uint64_t flags);
kern_return_t bootstrap_look_up3(mach_port_t bp, const name_t service_name, mach_port_t *sp,
    pid_t target_pid, const uuid_t instance, uint64_t flags);

__END_DECLS

#endif /* __XPC_PRIVATE_H__ */
