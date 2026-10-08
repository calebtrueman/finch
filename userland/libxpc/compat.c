/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * The rest of the libxpc surface that loads in every Finch process. On macOS
 * 26, libobjc links libswiftCore, which links Foundation and CoreFoundation,
 * so every process loads those frameworks, and every libxpc symbol they (and
 * Security, Network, libswiftXPC, ...) import must resolve. See
 * docs/design/XPC.md.
 *
 * Real implementations: sessions and listeners (wrappers over connections),
 * rich errors, transactions, shared memory, pointers, send-once rights,
 * entitlement-based peer requirements, version checks, reply helpers.
 * Deliberate "not available on Finch yet" answers are marked FINCH-NOT-YET:
 * background activities, event streams, launchd job/domain routines, and
 * code-signing-identity requirements (which fail closed).
 */

#include <Block.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <mach/mach_vm.h>
#include <objc/runtime.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include "internal.h"

/* Types implemented here; classes and _xpc_type_* aliases live in object.m. */
#define XPC_LOCAL_TYPE(name) extern const struct _xpc_type_s _xpc_type_##name
XPC_LOCAL_TYPE(activity);
XPC_LOCAL_TYPE(pointer);
XPC_LOCAL_TYPE(rich_error);
XPC_LOCAL_TYPE(shmem);
XPC_LOCAL_TYPE(mach_send_once);
XPC_LOCAL_TYPE(session);
XPC_LOCAL_TYPE(listener);
XPC_LOCAL_TYPE(peer_requirement);
XPC_LOCAL_TYPE(transaction);

#pragma mark - Rich errors

struct finch_rich_error_s {
	XPC_OBJECT_HEADER;
	char *description;
	bool can_retry;
};

static xpc_rich_error_t
_xpc_rich_error_create(const char *description, bool can_retry)
{
	struct finch_rich_error_s *e = _xpc_object_alloc(&_xpc_type_rich_error, sizeof(*e));
	e->description = strdup(description);
	e->can_retry = can_retry;
	return (xpc_rich_error_t)e;
}

static void
_set_error(xpc_rich_error_t *out, const char *description, bool can_retry)
{
	if (out) {
		*out = _xpc_rich_error_create(description, can_retry);
	}
}

XPC_INTERNAL void
_xpc_compat_dispose(xpc_object_t obj)
{
	xpc_type_t t = xpc_get_type(obj);

	if (t == (xpc_type_t)&_xpc_type_rich_error) {
		free(((struct finch_rich_error_s *)obj)->description);
	}
}

bool
xpc_rich_error_can_retry(xpc_rich_error_t error)
{
	return ((struct finch_rich_error_s *)error)->can_retry;
}

char *
xpc_rich_error_copy_description(xpc_rich_error_t error)
{
	return strdup(((struct finch_rich_error_s *)error)->description);
}

#pragma mark - Sessions (over connections)

struct finch_session_s {
	XPC_OBJECT_HEADER;
	xpc_connection_t conn;
	xpc_session_incoming_message_handler_t message_handler;
	xpc_session_cancel_handler_t cancel_handler;
	bool activated;
};

static xpc_session_t
_xpc_session_wrap(xpc_connection_t conn, bool activate)
{
	struct finch_session_s *s = _xpc_object_alloc(&_xpc_type_session, sizeof(*s));

	s->conn = conn;
	s->message_handler = NULL;
	s->cancel_handler = NULL;
	s->activated = false;
	xpc_retain((xpc_object_t)s);   /* held by the connection's handler until invalid */
	xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
		if (xpc_get_type(event) == XPC_TYPE_DICTIONARY) {
			if (s->message_handler) {
				s->message_handler(event);
			}
		} else if (event == XPC_ERROR_CONNECTION_INVALID) {
			if (s->cancel_handler) {
				xpc_rich_error_t e = _xpc_rich_error_create("Session invalidated", false);
				s->cancel_handler(e);
				xpc_release((xpc_object_t)e);
			}
			xpc_release((xpc_object_t)s);
		}
	});
	if (activate) {
		s->activated = true;
		xpc_connection_resume(conn);
	}
	return (xpc_session_t)s;
}

static bool
_session_create_inactive(xpc_session_create_flags_t flags)
{
	return (flags & XPC_SESSION_CREATE_INACTIVE) != 0;
}

xpc_session_t
xpc_session_create_mach_service(const char *mach_service, dispatch_queue_t target_queue,
    xpc_session_create_flags_t flags, xpc_rich_error_t *error_out)
{
	xpc_connection_t c = xpc_connection_create_mach_service(mach_service, target_queue, 0);

	if (c == NULL) {
		_set_error(error_out, "Unable to create session", false);
		return NULL;
	}
	return _xpc_session_wrap(c, !_session_create_inactive(flags));
}

xpc_session_t
xpc_session_create_xpc_service(const char *name, dispatch_queue_t target_queue,
    xpc_session_create_flags_t flags, xpc_rich_error_t *error_out)
{
	/* App-bundled XPC services resolve through the bootstrap namespace too. */
	return xpc_session_create_mach_service(name, target_queue, flags, error_out);
}

xpc_session_t xpc_session_create_xpc_endpoint(xpc_endpoint_t endpoint, dispatch_queue_t target_queue,
    xpc_session_create_flags_t flags, xpc_rich_error_t *error_out);

xpc_session_t
xpc_session_create_xpc_endpoint(xpc_endpoint_t endpoint, dispatch_queue_t target_queue,
    xpc_session_create_flags_t flags, xpc_rich_error_t *error_out)
{
	xpc_connection_t c = xpc_connection_create_from_endpoint(endpoint);

	if (c == NULL) {
		_set_error(error_out, "Invalid endpoint", false);
		return NULL;
	}
	if (target_queue) {
		xpc_connection_set_target_queue(c, target_queue);
	}
	return _xpc_session_wrap(c, !_session_create_inactive(flags));
}

bool
xpc_session_activate(xpc_session_t session, xpc_rich_error_t *error_out)
{
	struct finch_session_s *s = (struct finch_session_s *)session;

	(void)error_out;
	if (!s->activated) {
		s->activated = true;
		xpc_connection_resume(s->conn);
	}
	return true;
}

void
xpc_session_set_incoming_message_handler(xpc_session_t session, xpc_session_incoming_message_handler_t handler)
{
	struct finch_session_s *s = (struct finch_session_s *)session;
	s->message_handler = Block_copy(handler);
}

void
xpc_session_set_cancel_handler(xpc_session_t session, xpc_session_cancel_handler_t cancel_handler)
{
	struct finch_session_s *s = (struct finch_session_s *)session;
	s->cancel_handler = Block_copy(cancel_handler);
}

void
xpc_session_set_target_queue(xpc_session_t session, dispatch_queue_t target_queue)
{
	xpc_connection_set_target_queue(((struct finch_session_s *)session)->conn, target_queue);
}

xpc_rich_error_t
xpc_session_send_message(xpc_session_t session, xpc_object_t message)
{
	xpc_connection_send_message(((struct finch_session_s *)session)->conn, message);
	return NULL;
}

xpc_object_t
xpc_session_send_message_with_reply_sync(xpc_session_t session, xpc_object_t message,
    xpc_rich_error_t *error_out)
{
	xpc_object_t r = xpc_connection_send_message_with_reply_sync(
	    ((struct finch_session_s *)session)->conn, message);

	if (xpc_get_type(r) == XPC_TYPE_ERROR) {
		_set_error(error_out, xpc_dictionary_get_string(r, XPC_ERROR_KEY_DESCRIPTION) ?: "error",
		    r == XPC_ERROR_CONNECTION_INTERRUPTED);
		xpc_release(r);
		return NULL;
	}
	return r;
}

void
xpc_session_send_message_with_reply_async(xpc_session_t session, xpc_object_t message,
    xpc_session_reply_handler_t reply_handler)
{
	xpc_session_reply_handler_t h = Block_copy(reply_handler);

	xpc_connection_send_message_with_reply(((struct finch_session_s *)session)->conn, message,
	    NULL, ^(xpc_object_t r) {
		if (xpc_get_type(r) == XPC_TYPE_ERROR) {
			xpc_rich_error_t e = _xpc_rich_error_create(
			    xpc_dictionary_get_string(r, XPC_ERROR_KEY_DESCRIPTION) ?: "error",
			    r == XPC_ERROR_CONNECTION_INTERRUPTED);
			h(NULL, e);
			xpc_release((xpc_object_t)e);
		} else {
			h(r, NULL);
		}
		Block_release(h);
	});
}

void
xpc_session_cancel(xpc_session_t session)
{
	xpc_connection_cancel(((struct finch_session_s *)session)->conn);
}

char *
xpc_session_copy_description(xpc_session_t session)
{
	char *d = NULL;
	asprintf(&d, "<xpc_session: %p>", (void *)session);
	return d;
}

/* FINCH-NOT-YET: per-user sessions; requirements are checked by listeners. */
void xpc_session_set_target_user_session_uid(xpc_session_t session, uid_t uid);
void xpc_session_set_target_user_session_uid(xpc_session_t session, uid_t uid) { (void)session; (void)uid; }

void
xpc_session_set_peer_requirement(xpc_session_t session, xpc_peer_requirement_t requirement)
{
	(void)session; (void)requirement;
}

/* Swift overlay SPI. */
xpc_session_t _xpc_session_create_from_connection_4SWIFT(xpc_connection_t connection);
xpc_connection_t _xpc_session_extract_connection_4SWIFT(xpc_session_t session);
void _xpc_session_get_peer_audit_token_4SWIFT(xpc_session_t session, audit_token_t *token);

xpc_session_t
_xpc_session_create_from_connection_4SWIFT(xpc_connection_t connection)
{
	return _xpc_session_wrap((xpc_connection_t)xpc_retain((xpc_object_t)connection), false);
}

xpc_connection_t
_xpc_session_extract_connection_4SWIFT(xpc_session_t session)
{
	return ((struct finch_session_s *)session)->conn;
}

void
_xpc_session_get_peer_audit_token_4SWIFT(xpc_session_t session, audit_token_t *token)
{
	xpc_connection_get_audit_token(((struct finch_session_s *)session)->conn, token);
}

#pragma mark - Listeners

struct finch_listener_s {
	XPC_OBJECT_HEADER;
	xpc_connection_t conn;
	xpc_listener_incoming_session_handler_t handler;
	xpc_peer_requirement_t requirement;
	bool activated;
};

static xpc_listener_t
_xpc_listener_wrap(xpc_connection_t conn, xpc_listener_create_flags_t flags,
    xpc_listener_incoming_session_handler_t handler)
{
	struct finch_listener_s *l = _xpc_object_alloc(&_xpc_type_listener, sizeof(*l));

	l->conn = conn;
	l->handler = handler ? Block_copy(handler) : NULL;
	l->requirement = NULL;
	l->activated = false;
	xpc_connection_set_event_handler(conn, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != XPC_TYPE_CONNECTION || l->handler == NULL) {
			return;
		}
		xpc_session_t s = _xpc_session_wrap((xpc_connection_t)xpc_retain(peer), false);
		l->handler(s);
		xpc_session_activate(s, NULL);
		xpc_release((xpc_object_t)s);
	});
	if (!(flags & XPC_LISTENER_CREATE_INACTIVE)) {
		l->activated = true;
		xpc_connection_resume(conn);
	}
	return (xpc_listener_t)l;
}

xpc_listener_t
xpc_listener_create(const char *service, dispatch_queue_t target_queue,
    xpc_listener_create_flags_t flags, xpc_listener_incoming_session_handler_t incoming_session_handler,
    xpc_rich_error_t *error_out)
{
	xpc_connection_t c = xpc_connection_create_mach_service(service, target_queue,
	    XPC_CONNECTION_MACH_SERVICE_LISTENER);

	if (c == NULL) {
		_set_error(error_out, "Unable to check in with the bootstrap server", false);
		return NULL;
	}
	return _xpc_listener_wrap(c, flags, incoming_session_handler);
}

xpc_listener_t xpc_listener_create_anonymous(dispatch_queue_t target_queue,
    xpc_listener_create_flags_t flags, xpc_listener_incoming_session_handler_t handler,
    xpc_rich_error_t *error_out);

xpc_listener_t
xpc_listener_create_anonymous(dispatch_queue_t target_queue, xpc_listener_create_flags_t flags,
    xpc_listener_incoming_session_handler_t handler, xpc_rich_error_t *error_out)
{
	xpc_connection_t c = xpc_connection_create(NULL, target_queue);

	if (c == NULL) {
		_set_error(error_out, "Unable to create listener", false);
		return NULL;
	}
	return _xpc_listener_wrap(c, flags, handler);
}

void xpc_listener_set_incoming_session_handler(xpc_listener_t listener,
    xpc_listener_incoming_session_handler_t handler);

void
xpc_listener_set_incoming_session_handler(xpc_listener_t listener, xpc_listener_incoming_session_handler_t handler)
{
	((struct finch_listener_s *)listener)->handler = Block_copy(handler);
}

bool
xpc_listener_activate(xpc_listener_t listener, xpc_rich_error_t *error_out)
{
	struct finch_listener_s *l = (struct finch_listener_s *)listener;

	(void)error_out;
	if (!l->activated) {
		l->activated = true;
		xpc_connection_resume(l->conn);
	}
	return true;
}

void
xpc_listener_cancel(xpc_listener_t listener)
{
	xpc_connection_cancel(((struct finch_listener_s *)listener)->conn);
}

xpc_endpoint_t xpc_listener_create_endpoint(xpc_listener_t listener);

xpc_endpoint_t
xpc_listener_create_endpoint(xpc_listener_t listener)
{
	return xpc_endpoint_create(((struct finch_listener_s *)listener)->conn);
}

void
xpc_listener_reject_peer(xpc_session_t peer, const char *reason)
{
	(void)reason;
	xpc_session_cancel(peer);
}

void
xpc_listener_set_peer_requirement(xpc_listener_t listener, xpc_peer_requirement_t requirement)
{
	((struct finch_listener_s *)listener)->requirement = requirement;
}

char *
xpc_listener_copy_description(xpc_listener_t listener)
{
	char *d = NULL;
	asprintf(&d, "<xpc_listener: %p>", (void *)listener);
	return d;
}

#pragma mark - Peer requirements

enum finch_req_kind { REQ_ENTITLEMENT_EXISTS, REQ_ENTITLEMENT_MATCHES, REQ_UNSUPPORTED };

struct finch_peer_requirement_s {
	XPC_OBJECT_HEADER;
	enum finch_req_kind kind;
	char *entitlement;
	xpc_object_t value;
};

static xpc_peer_requirement_t
_req(enum finch_req_kind kind, const char *ent, xpc_object_t value)
{
	struct finch_peer_requirement_s *r = _xpc_object_alloc(&_xpc_type_peer_requirement, sizeof(*r));
	r->kind = kind;
	r->entitlement = ent ? strdup(ent) : NULL;
	r->value = value ? xpc_retain(value) : NULL;
	return (xpc_peer_requirement_t)r;
}

xpc_peer_requirement_t
xpc_peer_requirement_create_entitlement_exists(const char *entitlement, xpc_rich_error_t *error_out)
{
	(void)error_out;
	return _req(REQ_ENTITLEMENT_EXISTS, entitlement, NULL);
}

xpc_peer_requirement_t
xpc_peer_requirement_create_entitlement_matches_value(const char *entitlement, xpc_object_t value,
    xpc_rich_error_t *error_out)
{
	(void)error_out;
	return _req(REQ_ENTITLEMENT_MATCHES, entitlement, value);
}

/* FINCH-NOT-YET: code-signing identities. These requirements never match (fail closed). */
xpc_peer_requirement_t
xpc_peer_requirement_create_team_identity(const char *signing_identifier, xpc_rich_error_t *error_out)
{
	(void)signing_identifier; (void)error_out;
	return _req(REQ_UNSUPPORTED, NULL, NULL);
}

xpc_peer_requirement_t
xpc_peer_requirement_create_platform_identity(const char *signing_identifier, xpc_rich_error_t *error_out)
{
	(void)signing_identifier; (void)error_out;
	return _req(REQ_UNSUPPORTED, NULL, NULL);
}

xpc_peer_requirement_t
xpc_peer_requirement_create_lwcr(xpc_object_t lwcr, xpc_rich_error_t *error_out)
{
	(void)lwcr; (void)error_out;
	return _req(REQ_UNSUPPORTED, NULL, NULL);
}

xpc_object_t xpc_copy_entitlement_for_token(const char *key, audit_token_t *token);
void xpc_dictionary_get_audit_token(xpc_object_t xdict, audit_token_t *token);

static bool
_req_match_token(xpc_peer_requirement_t requirement, audit_token_t *token)
{
	struct finch_peer_requirement_s *r = (struct finch_peer_requirement_s *)requirement;
	xpc_object_t v;
	bool ok;

	if (r->kind == REQ_UNSUPPORTED) {
		return false;
	}
	v = xpc_copy_entitlement_for_token(r->entitlement, token);
	ok = v != NULL && (r->kind == REQ_ENTITLEMENT_EXISTS || xpc_equal(v, r->value));
	if (v) xpc_release(v);
	return ok;
}

bool
xpc_peer_requirement_match_received_message(xpc_peer_requirement_t peer_requirement, xpc_object_t message,
    xpc_rich_error_t *error_out)
{
	audit_token_t token;
	bool ok;

	xpc_dictionary_get_audit_token(message, &token);
	ok = _req_match_token(peer_requirement, &token);
	if (!ok) {
		_set_error(error_out, "Peer requirement not satisfied", false);
	}
	return ok;
}

bool _xpc_peer_requirement_match_token(xpc_peer_requirement_t requirement, audit_token_t *token);

bool
_xpc_peer_requirement_match_token(xpc_peer_requirement_t requirement, audit_token_t *token)
{
	return _req_match_token(requirement, token);
}

#pragma mark - Activities (FINCH-NOT-YET: no background-task scheduler)

const char *const XPC_ACTIVITY_INTERVAL = "Interval";
const char *const XPC_ACTIVITY_REPEATING = "Repeating";
const char *const XPC_ACTIVITY_DELAY = "Delay";
const char *const XPC_ACTIVITY_GRACE_PERIOD = "GracePeriod";
const char *const XPC_ACTIVITY_PRIORITY = "Priority";
const char *const XPC_ACTIVITY_PRIORITY_MAINTENANCE = "Maintenance";
const char *const XPC_ACTIVITY_PRIORITY_UTILITY = "Utility";
const char *const XPC_ACTIVITY_APP_REFRESH = "AppRefresh";
const int64_t XPC_ACTIVITY_INTERVAL_7_DAYS = 604800;
const char *const XPC_COALITION_INFO_KEY_NAME = "name";
const char *const XPC_COALITION_INFO_KEY_BUNDLE_IDENTIFIER = "bundle_identifier";

static const struct xpc_string_s _xpc_activity_check_in_string = {
	XPC_STATIC_HEADER(XPC_TYPE_STRING), .length = 10, .ptr = "<CHECK-IN>",
};
const xpc_object_t XPC_ACTIVITY_CHECK_IN = (xpc_object_t)&_xpc_activity_check_in_string;

/* Registration succeeds, but nothing schedules activities yet: handlers never run. */
void
xpc_activity_register(const char *identifier, xpc_object_t criteria, xpc_activity_handler_t handler)
{
	(void)identifier; (void)criteria; (void)handler;
}

void
xpc_activity_unregister(const char *identifier)
{
	(void)identifier;
}

xpc_object_t
xpc_activity_copy_criteria(xpc_activity_t activity)
{
	(void)activity;
	return NULL;
}

void
xpc_activity_set_criteria(xpc_activity_t activity, xpc_object_t criteria)
{
	(void)activity; (void)criteria;
}

xpc_activity_state_t
xpc_activity_get_state(xpc_activity_t activity)
{
	(void)activity;
	return XPC_ACTIVITY_STATE_DONE;
}

bool
xpc_activity_set_state(xpc_activity_t activity, xpc_activity_state_t state)
{
	(void)activity; (void)state;
	return false;
}

bool
xpc_activity_should_defer(xpc_activity_t activity)
{
	(void)activity;
	return false;
}

#pragma mark - Event streams (FINCH-NOT-YET: launchd event publishers)

void
xpc_set_event_stream_handler(const char *stream, dispatch_queue_t targetq, xpc_handler_t handler)
{
	(void)stream; (void)targetq; (void)handler;
}

void xpc_set_event(const char *stream, const char *name, xpc_object_t descriptor);
void xpc_set_event(const char *stream, const char *name, xpc_object_t descriptor)
{
	(void)stream; (void)name; (void)descriptor;
}

void xpc_track_activity(void);
void xpc_track_activity(void) {}

#pragma mark - Transactions

/* An os_transaction is an os_object; Finch processes aren't idle-exited yet. */
struct finch_transaction_s {
	XPC_OBJECT_HEADER;
	char *name;
};

typedef struct finch_transaction_s *os_transaction_t;
os_transaction_t os_transaction_create(const char *description);
char *os_transaction_copy_description(os_transaction_t transaction);

os_transaction_t
os_transaction_create(const char *description)
{
	struct finch_transaction_s *t = _xpc_object_alloc(&_xpc_type_transaction, sizeof(*t));
	t->name = description ? strdup(description) : NULL;
	return t;
}

char *
os_transaction_copy_description(os_transaction_t transaction)
{
	return strdup(transaction->name ? transaction->name : "");
}

void
xpc_transaction_begin(void)
{
}

void
xpc_transaction_end(void)
{
}

void xpc_transaction_exit_clean(void);
void xpc_transactions_enable(void);
void xpc_transaction_exit_clean(void) {}
void xpc_transactions_enable(void) {}

typedef void *vproc_t;
typedef void *vproc_transaction_t;
vproc_transaction_t vproc_transaction_begin(vproc_t vp);
void vproc_transaction_end(vproc_t vp, vproc_transaction_t vpt);
void _vproc_transaction_try_exit(int status);
void *vproc_swap_string(vproc_t vp, int key, const char *inval, char **outval);

vproc_transaction_t
vproc_transaction_begin(vproc_t vp)
{
	(void)vp;
	return (vproc_transaction_t)vproc_transaction_begin;   /* non-NULL token */
}

void
vproc_transaction_end(vproc_t vp, vproc_transaction_t vpt)
{
	(void)vp; (void)vpt;
}

void
_vproc_transaction_try_exit(int status)
{
	(void)status;
}

void *
vproc_swap_string(vproc_t vp, int key, const char *inval, char **outval)
{
	(void)vp; (void)key; (void)inval;
	if (outval) *outval = NULL;
	return (void *)vproc_swap_string;   /* non-NULL = error */
}

#pragma mark - Shared memory, pointers, send-once rights

struct finch_shmem_s {
	XPC_OBJECT_HEADER;
	mach_port_t entry;          /* named memory entry (send right) */
	size_t length;
};

xpc_object_t
xpc_shmem_create(void *region, size_t length)
{
	memory_object_size_t size = length;
	mach_port_t entry = MACH_PORT_NULL;
	struct finch_shmem_s *s;

	if (mach_make_memory_entry_64(mach_task_self(), &size, (memory_object_offset_t)(uintptr_t)region,
	        VM_PROT_READ | VM_PROT_WRITE, &entry, MACH_PORT_NULL) != KERN_SUCCESS) {
		return NULL;
	}
	s = _xpc_object_alloc(&_xpc_type_shmem, sizeof(*s));
	s->entry = entry;
	s->length = length;
	return s;
}

size_t
xpc_shmem_map(xpc_object_t xshmem, void **region)
{
	struct finch_shmem_s *s = xshmem;
	mach_vm_address_t addr = 0;

	if (mach_vm_map(mach_task_self(), &addr, s->length, 0, VM_FLAGS_ANYWHERE, s->entry, 0, FALSE,
	        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE) != KERN_SUCCESS) {
		*region = NULL;
		return 0;
	}
	*region = (void *)(uintptr_t)addr;
	return s->length;
}

struct finch_pointer_s {
	XPC_OBJECT_HEADER;
	void *value;
};

xpc_object_t xpc_pointer_create(void *value);
void *xpc_pointer_get_value(xpc_object_t xptr);

xpc_object_t
xpc_pointer_create(void *value)
{
	struct finch_pointer_s *p = _xpc_object_alloc(&_xpc_type_pointer, sizeof(*p));
	p->value = value;
	return p;
}

void *
xpc_pointer_get_value(xpc_object_t xptr)
{
	return xpc_get_type(xptr) == (xpc_type_t)&_xpc_type_pointer ? ((struct finch_pointer_s *)xptr)->value : NULL;
}

void xpc_dictionary_set_pointer(xpc_object_t xdict, const char *key, void *value);
void *xpc_dictionary_get_pointer(xpc_object_t xdict, const char *key);
void xpc_array_set_pointer(xpc_object_t xarray, size_t index, void *value);
void *xpc_array_get_pointer(xpc_object_t xarray, size_t index);

void
xpc_dictionary_set_pointer(xpc_object_t xdict, const char *key, void *value)
{
	xpc_object_t p = xpc_pointer_create(value);
	xpc_dictionary_set_value(xdict, key, p);
	xpc_release(p);
}

void *
xpc_dictionary_get_pointer(xpc_object_t xdict, const char *key)
{
	xpc_object_t v = xpc_dictionary_get_value(xdict, key);
	return v ? xpc_pointer_get_value(v) : NULL;
}

void
xpc_array_set_pointer(xpc_object_t xarray, size_t index, void *value)
{
	xpc_object_t p = xpc_pointer_create(value);
	xpc_array_set_value(xarray, index, p);
	xpc_release(p);
}

void *
xpc_array_get_pointer(xpc_object_t xarray, size_t index)
{
	xpc_object_t v = xpc_array_get_value(xarray, index);
	return v ? xpc_pointer_get_value(v) : NULL;
}

struct finch_send_once_s {
	XPC_OBJECT_HEADER;
	mach_port_t port;
};

xpc_object_t xpc_mach_send_create(mach_port_t port);
xpc_object_t xpc_mach_send_once_create(mach_port_t port);
mach_port_t xpc_mach_send_once_extract_right(xpc_object_t xso);
xpc_object_t xpc_mach_send_create_with_disposition(mach_port_t port, mach_msg_type_name_t disposition);

/* Takes ownership of a send-once right. */
xpc_object_t
xpc_mach_send_once_create(mach_port_t port)
{
	struct finch_send_once_s *o = _xpc_object_alloc(&_xpc_type_mach_send_once, sizeof(*o));
	o->port = port;
	return o;
}

mach_port_t
xpc_mach_send_once_extract_right(xpc_object_t xso)
{
	struct finch_send_once_s *o = xso;
	mach_port_t p = o->port;
	o->port = MACH_PORT_NULL;
	return p;
}

xpc_object_t
xpc_mach_send_create_with_disposition(mach_port_t port, mach_msg_type_name_t disposition)
{
	switch (disposition) {
	case MACH_MSG_TYPE_MOVE_SEND:
		return _xpc_mach_send_adopt(port);   /* consumes the caller's right */
	case MACH_MSG_TYPE_MAKE_SEND:
		if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
			return NULL;
		}
		return _xpc_mach_send_adopt(port);
	default:
		return xpc_mach_send_create(port);   /* COPY_SEND */
	}
}

#pragma mark - Connection extras

char *xpc_connection_copy_bundle_id(xpc_connection_t connection);
void xpc_connection_kill(xpc_connection_t connection, int signal);
void xpc_connection_send_notification(xpc_connection_t connection, xpc_object_t message);
void xpc_connection_set_bootstrap(xpc_connection_t connection, xpc_object_t bootstrap);
void xpc_connection_set_instance(xpc_connection_t connection, uuid_t instance);
void xpc_connection_set_legacy(xpc_connection_t connection);
void xpc_connection_set_privileged(xpc_connection_t connection);

char *
xpc_connection_copy_bundle_id(xpc_connection_t connection)
{
	(void)connection;
	return NULL;
}

void
xpc_connection_kill(xpc_connection_t connection, int sig)
{
	pid_t pid = xpc_connection_get_pid(connection);
	if (pid > 0) {
		kill(pid, sig);
	}
}

void
xpc_connection_send_notification(xpc_connection_t connection, xpc_object_t message)
{
	xpc_connection_send_message(connection, message);
}

/* Launchd-domain and instance routing: Finch has a single bootstrap domain. */
void xpc_connection_set_bootstrap(xpc_connection_t c, xpc_object_t b) { (void)c; (void)b; }
void xpc_connection_set_instance(xpc_connection_t c, uuid_t i) { (void)c; (void)i; }
void xpc_connection_set_legacy(xpc_connection_t c) { (void)c; }
void xpc_connection_set_privileged(xpc_connection_t c) { (void)c; }

char *
xpc_connection_copy_invalidation_reason(xpc_connection_t connection)
{
	(void)connection;
	return NULL;
}

/* FINCH-NOT-YET: code-signing requirements can't be evaluated; refuse rather
 * than pretend to enforce. */
int
xpc_connection_set_peer_code_signing_requirement(xpc_connection_t connection, const char *requirement)
{
	(void)connection; (void)requirement;
	return ENOTSUP;
}

void
xpc_dictionary_set_connection(xpc_object_t xdict, const char *key, xpc_connection_t connection)
{
	xpc_dictionary_set_value(xdict, key, (xpc_object_t)connection);
}

void
xpc_array_set_connection(xpc_object_t xarray, size_t index, xpc_connection_t connection)
{
	xpc_array_set_value(xarray, index, (xpc_object_t)connection);
}

#pragma mark - Replies

static void
_xpc_send_reply(xpc_object_t reply)
{
	struct _xpc_dictionary_s *d = reply;
	mach_port_t rp = d->reply_port;

	if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY || !MACH_PORT_VALID(rp)) {
		return;
	}
	d->reply_port = MACH_PORT_NULL;
	if (_xpc_message_send(rp, MACH_MSG_TYPE_MOVE_SEND_ONCE, reply, XPC_MSGID_REPLY,
	        MACH_PORT_NULL, 0, 0, MACH_MSG_TIMEOUT_NONE) != MACH_MSG_SUCCESS) {
		mach_port_deallocate(mach_task_self(), rp);
	}
}

void xpc_dictionary_send_reply(xpc_object_t reply);
void xpc_dictionary_send_reply_4SWIFT(xpc_object_t reply);
void xpc_dictionary_handoff_reply(xpc_object_t reply, dispatch_queue_t queue, dispatch_block_t block);

void xpc_dictionary_send_reply(xpc_object_t reply) { _xpc_send_reply(reply); }
void xpc_dictionary_send_reply_4SWIFT(xpc_object_t reply) { _xpc_send_reply(reply); }

/* Run `block` on `queue`, then send the reply. */
void
xpc_dictionary_handoff_reply(xpc_object_t reply, dispatch_queue_t queue, dispatch_block_t block)
{
	dispatch_block_t b = Block_copy(block);
	xpc_retain(reply);
	dispatch_async(queue, ^{
		b();
		Block_release(b);
		_xpc_send_reply(reply);
		xpc_release(reply);
	});
}

#pragma mark - Descriptions and strings

char *xpc_copy_short_description(xpc_object_t object);
char *xpc_dictionary_copy_basic_description(xpc_object_t object);
char *xpc_inspect_copy_description(xpc_object_t object);
const char *xpc_strerror(int error);
xpc_object_t xpc_string_create_no_copy(const char *string);
xpc_object_t xpc_create_with_format(const char *format, ...);

char *xpc_copy_short_description(xpc_object_t o) { return xpc_copy_description(o); }
char *xpc_dictionary_copy_basic_description(xpc_object_t o) { return xpc_copy_description(o); }
char *xpc_inspect_copy_description(xpc_object_t o) { return xpc_copy_description(o); }
const char *xpc_strerror(int error) { return strerror(error); }

/* Finch strings own their bytes; "no copy" still copies (always safe). */
xpc_object_t xpc_string_create_no_copy(const char *string) { return xpc_string_create(string); }

/* FINCH-NOT-YET: the format language of xpc_create_with_format. */
xpc_object_t
xpc_create_with_format(const char *format, ...)
{
	(void)format;
	return NULL;
}

#pragma mark - Identity, bootstrap and launchd SPI

xpc_object_t xpc_copy_bootstrap(void);
char *xpc_copy_code_signing_identity_for_token(audit_token_t *token);
xpc_object_t xpc_copy_entitlements_data_for_token(audit_token_t *token);
xpc_object_t _xpc_runtime_get_entitlements_data(void);
Class xpc_get_class4NSXPC(xpc_type_t type);
void xpc_add_bundle(const char *path, unsigned int flags);
void xpc_handle_service(void *handler);

xpc_object_t xpc_copy_bootstrap(void) { return NULL; }
char *xpc_copy_code_signing_identity_for_token(audit_token_t *token) { (void)token; return NULL; }
xpc_object_t xpc_copy_entitlements_data_for_token(audit_token_t *token) { (void)token; return NULL; }
xpc_object_t _xpc_runtime_get_entitlements_data(void) { return NULL; }
void xpc_add_bundle(const char *path, unsigned int flags) { (void)path; (void)flags; }
void xpc_handle_service(void *handler) { (void)handler; }

/* NSXPC asks libxpc for the class of an XPC type; types are classes. */
Class
xpc_get_class4NSXPC(xpc_type_t type)
{
	return (Class)type;
}

/* xpc_main: become the XPC service named by the environment, serve forever. */
void
xpc_main(xpc_connection_handler_t handler)
{
	const char *name = getenv("XPC_SERVICE_NAME");
	xpc_connection_t l = name ? xpc_connection_create_mach_service(name, NULL,
	    XPC_CONNECTION_MACH_SERVICE_LISTENER) : NULL;

	if (l == NULL) {
		fprintf(stderr, "xpc_main: no service to check in (XPC_SERVICE_NAME unset or unknown)\n");
		exit(EXIT_FAILURE);
	}
	xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) {
			handler((xpc_connection_t)peer);
		}
	});
	xpc_connection_resume(l);
	dispatch_main();
}

kern_return_t bootstrap_look_up3(mach_port_t bp, const name_t name, mach_port_t *sp, pid_t pid,
    const uuid_t instance, uint64_t flags);
kern_return_t bootstrap_register2(mach_port_t bp, const name_t name, mach_port_t sp, uint64_t flags);

kern_return_t
bootstrap_look_up3(mach_port_t bp, const name_t name, mach_port_t *sp, pid_t pid,
    const uuid_t instance, uint64_t flags)
{
	(void)pid; (void)instance; (void)flags;
	return bootstrap_look_up(bp, name, sp);
}

/* FINCH-NOT-YET: dynamic registration (finch-init's bootstrap server, X4). */
kern_return_t
bootstrap_register2(mach_port_t bp, const name_t name, mach_port_t sp, uint64_t flags)
{
	(void)bp; (void)name; (void)sp; (void)flags;
	return 1100 /* BOOTSTRAP_NOT_PRIVILEGED */;
}

/* FINCH-NOT-YET: launchd job/domain/service routines and socket activation. */
int _launch_job_routine(int routine, xpc_object_t msg, xpc_object_t *reply);
int _launch_job_routine_async(int routine, xpc_object_t msg, xpc_object_t *reply);
int _xpc_domain_routine(int routine, xpc_object_t msg, xpc_object_t *reply);
int _xpc_service_routine(int routine, xpc_object_t msg, xpc_object_t *reply);
void *_launch_msg2(void *request, int fd, void *reply_block);
int launch_activate_socket(const char *name, int **fds, size_t *count);
#include <launch.h>

int _launch_job_routine(int r, xpc_object_t m, xpc_object_t *o) { (void)r; (void)m; if (o) *o = NULL; return ENOTSUP; }
int _launch_job_routine_async(int r, xpc_object_t m, xpc_object_t *o) { (void)r; (void)m; if (o) *o = NULL; return ENOTSUP; }
int _xpc_domain_routine(int r, xpc_object_t m, xpc_object_t *o) { (void)r; (void)m; if (o) *o = NULL; return ENOTSUP; }
int _xpc_service_routine(int r, xpc_object_t m, xpc_object_t *o) { (void)r; (void)m; if (o) *o = NULL; return ENOTSUP; }
void *_launch_msg2(void *req, int fd, void *b) { (void)req; (void)fd; (void)b; errno = ENOTSUP; return NULL; }
int launch_activate_socket(const char *n, int **f, size_t *c) { (void)n; *f = NULL; *c = 0; return ENOENT; }

#pragma mark - OS version queries

/* Parse "26.4.1" into a packed 0xMMMMmmpp version (dyld's encoding). */
static uint32_t
_packed_version(const char *sysctl_name)
{
	char buf[64];
	size_t len = sizeof(buf);
	unsigned maj = 0, min = 0, pat = 0;

	if (sysctlbyname(sysctl_name, buf, &len, NULL, 0) != 0) {
		return 0;
	}
	sscanf(buf, "%u.%u.%u", &maj, &min, &pat);
	return maj << 16 | (min & 0xff) << 8 | (pat & 0xff);
}

struct os_system_version_s {
	unsigned int major, minor, patch;
};
int os_system_version_get_current_version(struct os_system_version_s *v);
int os_system_version_get_ios_support_version(struct os_system_version_s *v);

static int
_fill_version(struct os_system_version_s *v, const char *sysctl_name)
{
	uint32_t p = _packed_version(sysctl_name);

	if (p == 0) {
		return EINVAL;
	}
	v->major = p >> 16;
	v->minor = (p >> 8) & 0xff;
	v->patch = p & 0xff;
	return 0;
}

int os_system_version_get_current_version(struct os_system_version_s *v) { return _fill_version(v, "kern.osproductversion"); }
int os_system_version_get_ios_support_version(struct os_system_version_s *v) { return _fill_version(v, "kern.iossupportversion"); }

/* clang's @available / Swift #available: is the running OS at least each version given? */
typedef struct { uint32_t platform; uint32_t version; } finch_build_version_t;
bool _availability_version_check(uint32_t count, finch_build_version_t versions[]);

bool
_availability_version_check(uint32_t count, finch_build_version_t versions[])
{
	uint32_t macos = _packed_version("kern.osproductversion");
	uint32_t ios = _packed_version("kern.iossupportversion");

	for (uint32_t i = 0; i < count; i++) {
		if (versions[i].platform == 1 /* PLATFORM_MACOS */) {
			return macos >= versions[i].version;
		}
		if (versions[i].platform == 6 /* PLATFORM_MACCATALYST */ && ios != 0) {
			return ios >= versions[i].version;
		}
	}
	return true;   /* no constraint for this platform */
}

#pragma mark - User sessions (FINCH-NOT-YET: one session)

bool xpc_user_sessions_enabled(void);
uid_t xpc_user_sessions_get_foreground_uid(int *error);
uid_t xpc_user_sessions_get_session_uid(void);
typedef struct xpc_pipe_s *xpc_pipe_t;
xpc_pipe_t xpc_pipe_create(const char *name, uint64_t flags);
xpc_pipe_t xpc_pipe_create_with_user_session_uid(const char *name, uid_t uid, uint64_t flags);

bool xpc_user_sessions_enabled(void) { return false; }

uid_t
xpc_user_sessions_get_foreground_uid(int *error)
{
	if (error) *error = ENOTSUP;
	return (uid_t)-1;
}

uid_t xpc_user_sessions_get_session_uid(void) { return 0; }

/* One session: the per-user namespace is the global one. */
xpc_pipe_t
xpc_pipe_create_with_user_session_uid(const char *name, uid_t uid, uint64_t flags)
{
	(void)uid;
	return xpc_pipe_create(name, flags);
}

#pragma mark - Pipe interface routines, reply ids, misc SPI

typedef struct xpc_pipe_s *finch_pipe_t;

int _xpc_pipe_interface_routine(finch_pipe_t pipe, uint64_t routine, xpc_object_t message,
    xpc_object_t *reply, uint64_t flags);
int _xpc_pipe_interface_routine_async(finch_pipe_t pipe, uint64_t routine, xpc_object_t message,
    dispatch_queue_t queue, void *handler);
uint64_t _xpc_dictionary_get_reply_msg_id(xpc_object_t xdict);
uint64_t _xpc_dictionary_extract_reply_msg_id(xpc_object_t xdict);

/* A routine with an explicit number: msgh_id 0x40000000 | routine (as bootstrap uses). */
int
_xpc_pipe_interface_routine(finch_pipe_t pipe, uint64_t routine, xpc_object_t message,
    xpc_object_t *reply, uint64_t flags)
{
	(void)flags;
	return _xpc_pipe_routine_port(pipe->port,
	    XPC_MSGID_PIPE_ROUTINE | (uint32_t)(routine & 0x00ffffff), message, reply, NULL);
}

/* FINCH-NOT-YET: asynchronous interface routines. */
int
_xpc_pipe_interface_routine_async(finch_pipe_t pipe, uint64_t routine, xpc_object_t message,
    dispatch_queue_t queue, void *handler)
{
	(void)pipe; (void)routine; (void)message; (void)queue; (void)handler;
	return ENOTSUP;
}

/* The Mach message id a received request arrived with. */
uint64_t
_xpc_dictionary_get_reply_msg_id(xpc_object_t xdict)
{
	return xpc_get_type(xdict) == XPC_TYPE_DICTIONARY ? ((struct _xpc_dictionary_s *)xdict)->msgid : 0;
}

uint64_t
_xpc_dictionary_extract_reply_msg_id(xpc_object_t xdict)
{
	uint64_t id = _xpc_dictionary_get_reply_msg_id(xdict);
	if (id != 0) {
		((struct _xpc_dictionary_s *)xdict)->msgid = 0;
	}
	return id;
}

xpc_object_t xpc_create_from_plist(const void *data, size_t length);
xpc_object_t xpc_create_from_plist_with_string_cache(const void *data, size_t length, void *cache);
char *xpc_copy_clean_description(xpc_object_t object);
xpc_object_t xpc_copy_event(const char *stream, const char *name);
xpc_object_t xpc_coalition_copy_info(uint64_t coalition_id);
void os_transaction_needs_more_time(os_transaction_t transaction);
void xpc_transaction_try_exit_clean(void);

/* The string cache only deduplicates key strings; the result is the same. */
xpc_object_t
xpc_create_from_plist_with_string_cache(const void *data, size_t length, void *cache)
{
	(void)cache;
	return xpc_create_from_plist(data, length);
}

char *xpc_copy_clean_description(xpc_object_t o) { return xpc_copy_description(o); }

/* Event streams have no registrations on Finch yet (see xpc_set_event). */
xpc_object_t xpc_copy_event(const char *stream, const char *name) { (void)stream; (void)name; return NULL; }

/* FINCH-NOT-YET: coalitions are a kernel feature launchd manages; no info yet. */
xpc_object_t xpc_coalition_copy_info(uint64_t coalition_id) { (void)coalition_id; return NULL; }

/* Finch doesn't idle-exit processes, so there's no deadline to extend or exit to try. */
void os_transaction_needs_more_time(os_transaction_t t) { (void)t; }
void xpc_transaction_try_exit_clean(void) {}

/*
 * reboot3(): the service manager's reboot/halt entry point (reboot(8),
 * shutdown(8)). Asks finch-init, over the bootstrap port, to stop every job
 * and process, sync, and call reboot(2) with `howto` (RB_* flags). Returns 0
 * once finch-init has accepted (it then takes the system down), else an
 * errno value (EPERM unless root).
 */
int reboot3(uint64_t howto, ...);

int
reboot3(uint64_t howto, ...)
{
	xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0), reply = NULL;
	int rc;

	xpc_dictionary_set_string(req, "op", "reboot");
	xpc_dictionary_set_uint64(req, "howto", howto);
	rc = _xpc_pipe_routine_port(bootstrap_port, XPC_MSGID_PIPE_ROUTINE, req, &reply, NULL);
	xpc_release(req);
	if (rc != 0) {
		return rc;
	}
	rc = (int)xpc_dictionary_get_int64(reply, "error");
	xpc_release(reply);
	return rc;
}

/* Finch has one session: there is no per-console launchd to detach from. */
typedef uint64_t vproc_flags_t;
void *_vprocmgr_detach_from_console(vproc_flags_t flags);
void *_vprocmgr_detach_from_console(vproc_flags_t flags) { (void)flags; return NULL; }

#pragma mark - Remote XPC and file transfers (FINCH-NOT-YET)

/*
 * Used by RemoteXPC (talking to other devices) and cryptex tooling. Their
 * prototypes aren't published; these return failure (NULL / an error) and
 * write nothing through any out-parameter, so callers see "not available".
 */
void *xpc_file_transfer_create_with_fd(void);
void *xpc_file_transfer_create_with_path(void);
void *xpc_file_transfer_copy_io(void);
uint64_t xpc_file_transfer_get_transfer_id(void);
int xpc_file_transfer_send_finished(void);
int xpc_file_transfer_set_transport_writing_callbacks(void);
int xpc_file_transfer_write_finished(void);
int xpc_file_transfer_write_to_fd(void);
void xpc_install_remote_hooks(void);
void *xpc_make_serialization_with_ool(void);
void *xpc_receive_remote_msg(void);
void xpc_extension_type_init(void);

void *xpc_file_transfer_create_with_fd(void) { return NULL; }
void *xpc_file_transfer_create_with_path(void) { return NULL; }
void *xpc_file_transfer_copy_io(void) { return NULL; }
uint64_t xpc_file_transfer_get_transfer_id(void) { return 0; }
int xpc_file_transfer_send_finished(void) { return ENOTSUP; }
int xpc_file_transfer_set_transport_writing_callbacks(void) { return ENOTSUP; }
int xpc_file_transfer_write_finished(void) { return ENOTSUP; }
int xpc_file_transfer_write_to_fd(void) { return ENOTSUP; }
void xpc_install_remote_hooks(void) {}
void *xpc_make_serialization_with_ool(void) { return NULL; }
void *xpc_receive_remote_msg(void) { return NULL; }
void xpc_extension_type_init(void) {}
