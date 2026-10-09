// SPDX-License-Identifier: MIT OR Apache-2.0
// What the XPC overlay calls in libxpc but the SDK's XPC clang module hides
// from Swift: the session, listener, peer-requirement and rich-error
// functions (Swift sees them through the overlay instead), and the private
// entry points Apple's overlay uses. Each is declared here under a
// _finch_ name bound to libxpc's symbol (asm label), with libxpc's
// signatures and reference conventions; libxpc is Finch's (userland/libxpc).
#pragma once
#include <xpc/xpc.h>
#include <bsm/audit.h>

#define FINCH_XPC(sym) __asm("_" #sym)
typedef xpc_object_t _Nullable XPC_GIVES_REFERENCE * _Nullable finch_xpc_error_out_t;

// session.h
char * _Nullable _finch_xpc_session_copy_description(xpc_object_t _Nonnull session)
    FINCH_XPC(xpc_session_copy_description);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_session_create_xpc_service(
    const char * _Nonnull name, dispatch_queue_t _Nullable target_queue, uint64_t flags,
    finch_xpc_error_out_t error_out) FINCH_XPC(xpc_session_create_xpc_service);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_session_create_mach_service(
    const char * _Nonnull mach_service, dispatch_queue_t _Nullable target_queue, uint64_t flags,
    finch_xpc_error_out_t error_out) FINCH_XPC(xpc_session_create_mach_service);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_session_create_xpc_endpoint(
    xpc_object_t _Nonnull endpoint, dispatch_queue_t _Nullable target_queue, uint64_t flags,
    finch_xpc_error_out_t error_out) FINCH_XPC(xpc_session_create_xpc_endpoint);
void _finch_xpc_session_set_incoming_message_handler(xpc_object_t _Nonnull session,
    void (^ _Nonnull handler)(xpc_object_t _Nonnull message))
    FINCH_XPC(xpc_session_set_incoming_message_handler);
void _finch_xpc_session_set_cancel_handler(xpc_object_t _Nonnull session,
    void (^ _Nonnull handler)(xpc_object_t _Nonnull error))
    FINCH_XPC(xpc_session_set_cancel_handler);
void _finch_xpc_session_set_target_queue(xpc_object_t _Nonnull session,
    dispatch_queue_t _Nullable target_queue) FINCH_XPC(xpc_session_set_target_queue);
bool _finch_xpc_session_activate(xpc_object_t _Nonnull session, finch_xpc_error_out_t error_out)
    FINCH_XPC(xpc_session_activate);
void _finch_xpc_session_cancel(xpc_object_t _Nonnull session) FINCH_XPC(xpc_session_cancel);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_session_send_message(
    xpc_object_t _Nonnull session, xpc_object_t _Nonnull message)
    FINCH_XPC(xpc_session_send_message);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_session_send_message_with_reply_sync(
    xpc_object_t _Nonnull session, xpc_object_t _Nonnull message, finch_xpc_error_out_t error_out)
    FINCH_XPC(xpc_session_send_message_with_reply_sync);
void _finch_xpc_session_send_message_with_reply_async(xpc_object_t _Nonnull session,
    xpc_object_t _Nonnull message,
    void (^ _Nonnull reply_handler)(xpc_object_t _Nullable reply, xpc_object_t _Nullable error))
    FINCH_XPC(xpc_session_send_message_with_reply_async);
void _finch_xpc_session_set_peer_requirement(xpc_object_t _Nonnull session,
    xpc_object_t _Nonnull requirement) FINCH_XPC(xpc_session_set_peer_requirement);
void _finch_xpc_session_set_target_user_session_uid(xpc_object_t _Nonnull session, uid_t uid)
    FINCH_XPC(xpc_session_set_target_user_session_uid);

// listener.h
char * _Nullable _finch_xpc_listener_copy_description(xpc_listener_t _Nonnull listener)
    FINCH_XPC(xpc_listener_copy_description);
XPC_RETURNS_RETAINED xpc_listener_t _Nullable _finch_xpc_listener_create(
    const char * _Nonnull service, dispatch_queue_t _Nullable target_queue, uint64_t flags,
    void (^ _Nonnull incoming_session_handler)(xpc_object_t _Nonnull peer),
    finch_xpc_error_out_t error_out) FINCH_XPC(xpc_listener_create);
XPC_RETURNS_RETAINED xpc_listener_t _Nullable _finch_xpc_listener_create_anonymous(
    dispatch_queue_t _Nullable target_queue, uint64_t flags,
    void (^ _Nonnull incoming_session_handler)(xpc_object_t _Nonnull peer),
    finch_xpc_error_out_t error_out) FINCH_XPC(xpc_listener_create_anonymous);
XPC_RETURNS_RETAINED xpc_object_t _Nonnull _finch_xpc_listener_create_endpoint(
    xpc_listener_t _Nonnull listener) FINCH_XPC(xpc_listener_create_endpoint);
bool _finch_xpc_listener_activate(xpc_listener_t _Nonnull listener, finch_xpc_error_out_t error_out)
    FINCH_XPC(xpc_listener_activate);
void _finch_xpc_listener_cancel(xpc_listener_t _Nonnull listener) FINCH_XPC(xpc_listener_cancel);
void _finch_xpc_listener_reject_peer(xpc_object_t _Nonnull peer, const char * _Nonnull reason)
    FINCH_XPC(xpc_listener_reject_peer);
void _finch_xpc_listener_set_incoming_session_handler(xpc_listener_t _Nonnull listener,
    void (^ _Nonnull incoming_session_handler)(xpc_object_t _Nonnull peer))
    FINCH_XPC(xpc_listener_set_incoming_session_handler);
void _finch_xpc_listener_set_peer_requirement(xpc_listener_t _Nonnull listener,
    xpc_object_t _Nonnull requirement) FINCH_XPC(xpc_listener_set_peer_requirement);

// peer_requirement.h
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_peer_requirement_create_entitlement_exists(
    const char * _Nonnull entitlement, finch_xpc_error_out_t error_out)
    FINCH_XPC(xpc_peer_requirement_create_entitlement_exists);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_peer_requirement_create_entitlement_matches_value(
    const char * _Nonnull entitlement, xpc_object_t _Nonnull value, finch_xpc_error_out_t error_out)
    FINCH_XPC(xpc_peer_requirement_create_entitlement_matches_value);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_peer_requirement_create_team_identity(
    const char * _Nullable signing_identifier, finch_xpc_error_out_t error_out)
    FINCH_XPC(xpc_peer_requirement_create_team_identity);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_peer_requirement_create_platform_identity(
    const char * _Nullable signing_identifier, finch_xpc_error_out_t error_out)
    FINCH_XPC(xpc_peer_requirement_create_platform_identity);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_peer_requirement_create_lwcr(
    xpc_object_t _Nonnull lwcr, finch_xpc_error_out_t error_out)
    FINCH_XPC(xpc_peer_requirement_create_lwcr);
bool _finch_xpc_peer_requirement_match_received_message(xpc_object_t _Nonnull requirement,
    xpc_object_t _Nonnull message, finch_xpc_error_out_t error_out)
    FINCH_XPC(xpc_peer_requirement_match_received_message);

// rich_error.h
char * _Nullable _finch_xpc_rich_error_copy_description(xpc_object_t _Nonnull error)
    FINCH_XPC(xpc_rich_error_copy_description);
bool _finch_xpc_rich_error_can_retry(xpc_object_t _Nonnull error) FINCH_XPC(xpc_rich_error_can_retry);

// libxpc's private entry points (dictionary replies, Swift session glue)
bool _finch_xpc_dictionary_expects_reply(xpc_object_t _Nonnull message)
    FINCH_XPC(xpc_dictionary_expects_reply);
void _finch_xpc_dictionary_send_reply(xpc_object_t _Nonnull reply) FINCH_XPC(xpc_dictionary_send_reply);
void _finch_xpc_dictionary_handoff_reply(xpc_object_t _Nonnull message, dispatch_queue_t _Nonnull queue,
    dispatch_block_t _Nonnull block) FINCH_XPC(xpc_dictionary_handoff_reply);
void _finch_xpc_dictionary_get_audit_token(xpc_object_t _Nonnull message, audit_token_t * _Nonnull token)
    FINCH_XPC(xpc_dictionary_get_audit_token);
XPC_RETURNS_RETAINED xpc_object_t _Nullable _finch_xpc_session_create_from_connection(
    xpc_object_t _Nonnull connection) FINCH_XPC(_xpc_session_create_from_connection_4SWIFT);
xpc_object_t _Nonnull _finch_xpc_session_extract_connection(xpc_object_t _Nonnull session)
    FINCH_XPC(_xpc_session_extract_connection_4SWIFT);
void _finch_xpc_session_get_peer_audit_token(xpc_object_t _Nonnull session, audit_token_t * _Nonnull token)
    FINCH_XPC(_xpc_session_get_peer_audit_token_4SWIFT);
bool _finch_xpc_peer_requirement_match_token(xpc_object_t _Nonnull requirement,
    audit_token_t * _Nonnull token) FINCH_XPC(_xpc_peer_requirement_match_token);

// The XPC_TYPE_* and XPC_ERROR_* macros, as functions Swift can call.
#define FINCH_XPC_TYPE(t) static inline xpc_type_t _Nonnull _finch_xpc_type_##t(void) { return XPC_TYPE_##t; }
FINCH_XPC_TYPE(CONNECTION) FINCH_XPC_TYPE(ENDPOINT) FINCH_XPC_TYPE(NULL) FINCH_XPC_TYPE(BOOL)
FINCH_XPC_TYPE(INT64) FINCH_XPC_TYPE(UINT64) FINCH_XPC_TYPE(DOUBLE) FINCH_XPC_TYPE(DATE)
FINCH_XPC_TYPE(DATA) FINCH_XPC_TYPE(STRING) FINCH_XPC_TYPE(UUID) FINCH_XPC_TYPE(FD)
FINCH_XPC_TYPE(SHMEM) FINCH_XPC_TYPE(ARRAY) FINCH_XPC_TYPE(DICTIONARY) FINCH_XPC_TYPE(ERROR)
FINCH_XPC_TYPE(ACTIVITY) FINCH_XPC_TYPE(RICH_ERROR)
#undef FINCH_XPC_TYPE
// libxpc's private types, which Apple's overlay names too.
#define FINCH_XPC_PRIVATE_TYPE(t, sym) extern const struct _xpc_type_s sym; \
    static inline xpc_type_t _Nonnull _finch_xpc_type_##t(void) { return &sym; }
FINCH_XPC_PRIVATE_TYPE(PIPE, _xpc_type_pipe) FINCH_XPC_PRIVATE_TYPE(BUNDLE, _xpc_type_bundle)
FINCH_XPC_PRIVATE_TYPE(POINTER, _xpc_type_pointer) FINCH_XPC_PRIVATE_TYPE(SERVICE, _xpc_type_service)
FINCH_XPC_PRIVATE_TYPE(MACH_RECV, _xpc_type_mach_recv) FINCH_XPC_PRIVATE_TYPE(MACH_SEND, _xpc_type_mach_send)
FINCH_XPC_PRIVATE_TYPE(SERIALIZER, _xpc_type_serializer)
FINCH_XPC_PRIVATE_TYPE(FILE_TRANSFER, _xpc_type_file_transfer)
FINCH_XPC_PRIVATE_TYPE(MACH_SEND_ONCE, _xpc_type_mach_send_once)
FINCH_XPC_PRIVATE_TYPE(SERVICE_INSTANCE, _xpc_type_service_instance)
#undef FINCH_XPC_PRIVATE_TYPE
static inline xpc_object_t _Nonnull _finch_xpc_bool_true(void) { return XPC_BOOL_TRUE; }
static inline xpc_object_t _Nonnull _finch_xpc_bool_false(void) { return XPC_BOOL_FALSE; }
static inline xpc_object_t _Nonnull _finch_xpc_error_connection_interrupted(void) { return XPC_ERROR_CONNECTION_INTERRUPTED; }
static inline xpc_object_t _Nonnull _finch_xpc_error_connection_invalid(void) { return XPC_ERROR_CONNECTION_INVALID; }
static inline xpc_object_t _Nonnull _finch_xpc_error_termination_imminent(void) { return XPC_ERROR_TERMINATION_IMMINENT; }
static inline xpc_object_t _Nonnull _finch_xpc_error_peer_code_signing_requirement(void) { return XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT; }
