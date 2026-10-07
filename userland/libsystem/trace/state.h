/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_STATE_H
#define FINCH_TRACE_STATE_H
#include <stdint.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
struct finch_state_hints {
	uint32_t version, reserved;
	uint64_t data;
	uint32_t type, flags;
};
struct finch_state_data {
	uint32_t type, size;
	char title[64], object_type[64], object_name[64];
	unsigned char data[];
};
typedef struct finch_state_data * (^finch_state_handler)(const struct finch_state_hints *);
uint64_t os_state_add_handler(dispatch_queue_t, finch_state_handler);
void os_state_remove_handler(uint64_t);
void _os_state_request_for_pidlist(const int *, unsigned);
void finch_trace_state_request(uint64_t, const void *, uint8_t, const void *);
void finch_trace_state_send(xpc_object_t);
#endif
