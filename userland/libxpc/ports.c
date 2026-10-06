/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Port-carrying XPC types: Mach send rights and endpoints (plus fd adoption).
 */

#include <stdlib.h>
#include <unistd.h>

#include "internal.h"

void
_xpc_ports_free(struct xpc_ports *ports)
{
	for (size_t i = 0; i < ports->count; i++) {
		if (ports->desc[i].name != MACH_PORT_NULL) {
			mach_port_deallocate(mach_task_self(), ports->desc[i].name);
		}
	}
	free(ports->desc);
	ports->desc = NULL;
	ports->count = ports->cap = ports->next = 0;
}

xpc_object_t
_xpc_fd_adopt(int fd)
{
	struct xpc_fd_s *o = _xpc_object_alloc(XPC_TYPE_FD, sizeof(*o));
	o->fd = fd;
	return o;
}

xpc_object_t
_xpc_mach_send_adopt(mach_port_t port)
{
	struct xpc_mach_send_s *o = _xpc_object_alloc(XPC_TYPE_MACH_SEND, sizeof(*o));
	o->port = port;
	return o;
}

xpc_object_t
_xpc_endpoint_adopt(mach_port_t port)
{
	struct xpc_endpoint_s *o = _xpc_object_alloc(XPC_TYPE_ENDPOINT, sizeof(*o));
	o->port = port;
	return o;
}

/* Private libxpc API (same names and signatures as Apple's exports). */

xpc_object_t xpc_mach_send_create(mach_port_t port);
mach_port_t xpc_mach_send_copy_right(xpc_object_t xsend);
mach_port_t xpc_mach_send_get_right(xpc_object_t xsend);

/* Takes an additional send right; the caller keeps its own. */
xpc_object_t
xpc_mach_send_create(mach_port_t port)
{
	if (!MACH_PORT_VALID(port) ||
	    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) {
		return NULL;
	}
	return _xpc_mach_send_adopt(port);
}

mach_port_t
xpc_mach_send_get_right(xpc_object_t xsend)
{
	if (xpc_get_type(xsend) != XPC_TYPE_MACH_SEND) {
		return MACH_PORT_NULL;
	}
	return ((struct xpc_mach_send_s *)xsend)->port;
}

mach_port_t
xpc_mach_send_copy_right(xpc_object_t xsend)
{
	mach_port_t port = xpc_mach_send_get_right(xsend);

	if (MACH_PORT_VALID(port)) {
		mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1);
	}
	return port;
}

void
xpc_dictionary_set_mach_send(xpc_object_t xdict, const char *key, mach_port_t port)
{
	xpc_object_t v = xpc_mach_send_create(port);

	if (v != NULL) {
		xpc_dictionary_set_value(xdict, key, v);
		xpc_release(v);
	}
}

mach_port_t
xpc_dictionary_copy_mach_send(xpc_object_t xdict, const char *key)
{
	xpc_object_t v = xpc_dictionary_get_value(xdict, key);
	return v ? xpc_mach_send_copy_right(v) : MACH_PORT_NULL;
}

/* Returns the endpoint's listener port with an extra send right (Apple's _4sim SPI). */
mach_port_t
xpc_endpoint_copy_listener_port_4sim(xpc_object_t endpoint)
{
	mach_port_t port;

	if (xpc_get_type(endpoint) != XPC_TYPE_ENDPOINT) {
		return MACH_PORT_NULL;
	}
	port = ((struct xpc_endpoint_s *)endpoint)->port;
	mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1);
	return port;
}

/* An endpoint for an arbitrary listener port (takes an additional send right). */
xpc_object_t
xpc_endpoint_create_mach_port_4sim(mach_port_t port)
{
	if (!MACH_PORT_VALID(port) ||
	    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) {
		return NULL;
	}
	return _xpc_endpoint_adopt(port);
}
