/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Error singletons and well-known keys. XPC errors are immortal, statically
 * initialised dictionaries of class OS_xpc_error holding a description string.
 */

#include "internal.h"

const char *const _xpc_error_key_description = "XPCErrorDescription";
const char *const _xpc_event_key_name = "XPCEventName";
const char *const _xpc_event_key_stream_name = "XPCEventStreamName";

#define XPC_STATIC_STRING(var, literal) \
	static const struct xpc_string_s var = { \
		XPC_STATIC_HEADER(XPC_TYPE_STRING), \
		.length = sizeof(literal) - 1, \
		.ptr = literal, \
	}

#define XPC_STATIC_ERROR(name, literal) \
	XPC_STATIC_STRING(name##_description, literal); \
	static struct xpc_dict_entry_s name##_entries[1] = { \
		{ .key = (char *)"XPCErrorDescription", \
		  .value = (xpc_object_t)&name##_description }, \
	}; \
	const struct _xpc_dictionary_s name = { \
		XPC_STATIC_HEADER(XPC_TYPE_ERROR), \
		.count = 1, .used = 1, .capacity = 1, \
		.entries = name##_entries, \
	}

/* Descriptions match Apple's libxpc. */
XPC_STATIC_ERROR(_xpc_error_connection_interrupted, "Connection interrupted");
XPC_STATIC_ERROR(_xpc_error_connection_invalid, "Connection invalid");
XPC_STATIC_ERROR(_xpc_error_termination_imminent, "Termination imminent");
XPC_STATIC_ERROR(_xpc_error_peer_code_signing_requirement, "Peer Forbidden");
