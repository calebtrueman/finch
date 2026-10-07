/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Event publishers: the libxpc side of launchd event streams (LaunchEvents).
 * A daemon such as notifyd publishes a stream; launchd tells it which
 * subscriptions exist (ADD/REMOVE, then INITIAL_BARRIER once the initial set
 * has been delivered) and relays fired events to the subscribers.
 *
 * FINCH-NOT-YET: finch-init doesn't support LaunchEvents, so a publisher never
 * has subscribers. It still behaves like one whose initial set is empty:
 * after activation the handler receives INITIAL_BARRIER (notifyd only finishes
 * starting up when it does), and firing at an unknown token fails.
 */

#include <Block.h>
#include <bsm/audit.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

extern const struct _xpc_type_s _xpc_type_event_publisher;

typedef enum {
	XPC_EVENT_PUBLISHER_ACTION_ADD = 0,
	XPC_EVENT_PUBLISHER_ACTION_REMOVE = 1,
	XPC_EVENT_PUBLISHER_ACTION_INITIAL_BARRIER = 2,
} xpc_event_publisher_action_t;

typedef void (^xpc_event_publisher_handler_t)(xpc_event_publisher_action_t action, uint64_t token,
    xpc_object_t descriptor);
typedef void (^xpc_event_publisher_error_handler_t)(int error);

struct finch_event_publisher_s {
	XPC_OBJECT_HEADER;
	char *stream;
	dispatch_queue_t queue;
	xpc_event_publisher_handler_t handler;
	xpc_event_publisher_error_handler_t error_handler;
	uint64_t throttle;
	bool activated;
};

typedef struct finch_event_publisher_s *xpc_event_publisher_t;
typedef char event_name_t[128];

xpc_event_publisher_t xpc_event_publisher_create(const char *stream, dispatch_queue_t queue);
void xpc_event_publisher_set_handler(xpc_event_publisher_t pub, xpc_event_publisher_handler_t handler);
void xpc_event_publisher_set_error_handler(xpc_event_publisher_t pub, xpc_event_publisher_error_handler_t handler);
void xpc_event_publisher_set_throttling(xpc_event_publisher_t pub, uint64_t max_inflight);
void xpc_event_publisher_activate(xpc_event_publisher_t pub);
int xpc_event_publisher_fire(xpc_event_publisher_t pub, uint64_t token, xpc_object_t details);
int xpc_event_publisher_fire_noboost(xpc_event_publisher_t pub, uint64_t token, xpc_object_t details);
au_asid_t xpc_event_publisher_get_subscriber_asid(xpc_event_publisher_t pub, uint64_t token);
bool xpc_get_service_identifier_for_token(uint64_t token, event_name_t name);

XPC_INTERNAL void
_xpc_event_publisher_dispose(xpc_object_t obj)
{
	struct finch_event_publisher_s *p = obj;

	free(p->stream);
	if (p->queue) dispatch_release(p->queue);
	if (p->handler) Block_release(p->handler);
	if (p->error_handler) Block_release(p->error_handler);
}

xpc_event_publisher_t
xpc_event_publisher_create(const char *stream, dispatch_queue_t queue)
{
	struct finch_event_publisher_s *p = _xpc_object_alloc(&_xpc_type_event_publisher, sizeof(*p));

	p->stream = strdup(stream ? stream : "");
	p->queue = queue ? queue : dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
	dispatch_retain(p->queue);
	p->handler = NULL;
	p->error_handler = NULL;
	p->throttle = 0;
	p->activated = false;
	return p;
}

void
xpc_event_publisher_set_handler(xpc_event_publisher_t p, xpc_event_publisher_handler_t handler)
{
	if (p->handler) Block_release(p->handler);
	p->handler = handler ? Block_copy(handler) : NULL;
}

void
xpc_event_publisher_set_error_handler(xpc_event_publisher_t p, xpc_event_publisher_error_handler_t handler)
{
	if (p->error_handler) Block_release(p->error_handler);
	p->error_handler = handler ? Block_copy(handler) : NULL;
}

void
xpc_event_publisher_set_throttling(xpc_event_publisher_t p, uint64_t max_inflight)
{
	p->throttle = max_inflight;
}

/* No subscriptions exist: the initial set is complete as soon as we start. */
void
xpc_event_publisher_activate(xpc_event_publisher_t p)
{
	if (p->activated) {
		return;
	}
	p->activated = true;
	xpc_retain((xpc_object_t)p);
	dispatch_async(p->queue, ^{
		if (p->handler) {
			p->handler(XPC_EVENT_PUBLISHER_ACTION_INITIAL_BARRIER, 0, NULL);
		}
		xpc_release((xpc_object_t)p);
	});
}

/* There are no subscriber tokens, so every token is unknown. */
int
xpc_event_publisher_fire(xpc_event_publisher_t p, uint64_t token, xpc_object_t details)
{
	(void)p; (void)token; (void)details;
	return ESRCH;
}

int
xpc_event_publisher_fire_noboost(xpc_event_publisher_t p, uint64_t token, xpc_object_t details)
{
	return xpc_event_publisher_fire(p, token, details);
}

au_asid_t
xpc_event_publisher_get_subscriber_asid(xpc_event_publisher_t p, uint64_t token)
{
	(void)p; (void)token;
	return AU_DEFAUDITSID;
}

bool
xpc_get_service_identifier_for_token(uint64_t token, event_name_t name)
{
	(void)token;
	name[0] = '\0';
	return false;
}
