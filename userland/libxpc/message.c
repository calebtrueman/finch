/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Mach transport for XPC messages: a header, optional port descriptors (fds,
 * rights, endpoints), and the CPX@ payload. See docs/design/XPC-protocol.md.
 */

#include <stdlib.h>
#include <string.h>

#include "internal.h"

/* Release the rights an outgoing message created and would have moved
 * (fileports). Copied rights still belong to their objects. */
static void
_xpc_ports_release_moved(struct xpc_ports *ports)
{
	for (size_t i = 0; i < ports->count; i++) {
		if (ports->desc[i].disposition == MACH_MSG_TYPE_MOVE_SEND) {
			mach_port_deallocate(mach_task_self(), ports->desc[i].name);
		} else if (ports->desc[i].disposition == MACH_MSG_TYPE_MOVE_RECEIVE) {
			mach_port_mod_refs(mach_task_self(), ports->desc[i].name, MACH_PORT_RIGHT_RECEIVE, -1);
		}
	}
}

kern_return_t
_xpc_message_send(mach_port_t dest, mach_msg_type_name_t dest_disp, xpc_object_t dict,
    uint32_t msgid, mach_port_t reply, mach_msg_type_name_t reply_disp,
    mach_msg_option_t options, mach_msg_timeout_t timeout)
{
	struct xpc_ports ports = { NULL, 0, 0, 0 };
	size_t payload_len = 0, size;
	void *payload = _xpc_serialize_message(dict, &payload_len, &ports);
	mach_msg_header_t *h;
	uint8_t *p;
	kern_return_t kr;

	if (payload == NULL) {
		_xpc_ports_release_moved(&ports);
		free(ports.desc);
		return KERN_INVALID_ARGUMENT;
	}
	size = sizeof(*h) + payload_len;
	if (ports.count > 0) {
		size += sizeof(mach_msg_body_t) + ports.count * sizeof(mach_msg_port_descriptor_t);
	}
	h = calloc(1, size);
	if (h == NULL) {
		abort();
	}
	h->msgh_bits = MACH_MSGH_BITS(dest_disp, MACH_PORT_VALID(reply) ? reply_disp : 0);
	h->msgh_size = (mach_msg_size_t)size;
	h->msgh_remote_port = dest;
	h->msgh_local_port = MACH_PORT_VALID(reply) ? reply : MACH_PORT_NULL;
	h->msgh_id = (mach_msg_id_t)msgid;
	p = (uint8_t *)(h + 1);
	if (ports.count > 0) {
		h->msgh_bits |= MACH_MSGH_BITS_COMPLEX;
		((mach_msg_body_t *)p)->msgh_descriptor_count = (mach_msg_size_t)ports.count;
		p += sizeof(mach_msg_body_t);
		memcpy(p, ports.desc, ports.count * sizeof(mach_msg_port_descriptor_t));
		p += ports.count * sizeof(mach_msg_port_descriptor_t);
	}
	memcpy(p, payload, payload_len);
	free(payload);

	kr = mach_msg(h, MACH_SEND_MSG | options, h->msgh_size, 0, MACH_PORT_NULL,
	    timeout, MACH_PORT_NULL);
	if (kr != MACH_MSG_SUCCESS && kr != MACH_SEND_INVALID_DEST) {
		/* The kernel didn't take the message: we still own moved rights. */
		_xpc_ports_release_moved(&ports);
	}
	free(ports.desc);
	free(h);
	return kr;
}

kern_return_t
_xpc_message_receive(mach_port_t port, mach_msg_option_t options, mach_msg_timeout_t timeout,
    mach_msg_header_t **out)
{
	mach_msg_size_t size = 4096;
	mach_msg_option_t opts = MACH_RCV_MSG | MACH_RCV_LARGE | options |
	    MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
	    MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
	kern_return_t kr;

	for (;;) {
		mach_msg_header_t *h = malloc(size + MAX_TRAILER_SIZE);
		if (h == NULL) {
			abort();
		}
		kr = mach_msg(h, opts, 0, size + MAX_TRAILER_SIZE, port, timeout, MACH_PORT_NULL);
		if (kr == MACH_RCV_TOO_LARGE) {
			size = h->msgh_size + MAX_TRAILER_SIZE;   /* message is still queued */
			free(h);
			continue;
		}
		if (kr != MACH_MSG_SUCCESS) {
			free(h);
			return kr;
		}
		*out = h;
		return kr;
	}
}

/*
 * Decode a received XPC message. Consumes the message's port descriptors (the
 * ones the payload doesn't use are released). Leaves the reply right in
 * msg->msgh_remote_port for the caller. Returns NULL for malformed messages.
 */
xpc_object_t
_xpc_message_decode(mach_msg_header_t *msg)
{
	struct xpc_ports ports = { NULL, 0, 0, 0 };
	const uint8_t *p = (const uint8_t *)(msg + 1), *end = (const uint8_t *)msg + msg->msgh_size;
	xpc_object_t dict = NULL;

	if (msg->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
		const mach_msg_body_t *body = (const mach_msg_body_t *)p;
		const mach_msg_port_descriptor_t *d;
		mach_msg_size_t n;

		if (p + sizeof(*body) > end) {
			goto out;
		}
		n = body->msgh_descriptor_count;
		d = (const mach_msg_port_descriptor_t *)(body + 1);
		if (n > 1024 || (const uint8_t *)(d + n) > end) {
			goto out;
		}
		ports.desc = calloc(n ? n : 1, sizeof(*ports.desc));
		for (mach_msg_size_t i = 0; i < n; i++) {
			if (d[i].type != MACH_MSG_PORT_DESCRIPTOR) {
				/* XPC only sends port descriptors; anything else is malformed.
				 * mach_msg_destroy() below releases everything. */
				free(ports.desc);
				mach_msg_destroy(msg);
				return NULL;
			}
			ports.desc[ports.count++] = d[i];
		}
		p = (const uint8_t *)(d + n);
	}
	dict = _xpc_deserialize_message(p, (size_t)(end - p), &ports);
out:
	_xpc_ports_free(&ports);   /* rights the payload didn't claim */
	return dict;
}
