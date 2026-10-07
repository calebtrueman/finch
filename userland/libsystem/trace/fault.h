/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_FAULT_H
#define FINCH_TRACE_FAULT_H
#include "internal.h"
#include <xpc/xpc.h>
struct finch_trace_fault_scope {
	void *previous;
	bool active;
};
/* Begin after log filtering; first means the error/fault counter was zero. */
struct finch_trace_fault_scope finch_trace_fault_begin(struct finch_log *, uint8_t,
    const struct finch_log_pack *, const uint8_t *, size_t, bool unreliable, bool first,
    uint8_t ttl);
void finch_trace_fault_end(struct finch_trace_fault_scope *);
struct finch_trace_callback_info {
	uint32_t version, reserved;
	struct finch_log *log;
	const char *subsystem, *category, *format, *message;
	const void *pc;
	uint8_t type;
	uint8_t padding[7];
};
typedef void (*finch_trace_message_callback)(const struct finch_trace_callback_info *);
/* Call after the saved voucher is restored. The fault callback precedes test. */
void finch_trace_fault_callbacks(struct finch_log *, uint8_t, const struct finch_log_pack *,
    const uint8_t *, size_t, finch_trace_message_callback fault, finch_trace_message_callback test);
void finch_trace_quarantine(void);
bool finch_trace_is_quarantined(void);
void finch_trace_quarantine_packet(xpc_object_t, uint32_t state_hint_type);
/* Pure policy helper also used by tests; mode 0 default, 2 always, 3 off. */
bool finch_trace_fault_report_enabled(
    uint32_t options, unsigned mode, bool development, bool first);
#endif
