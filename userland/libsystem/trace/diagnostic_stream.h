/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_DIAGNOSTIC_STREAM_H
#define FINCH_DIAGNOSTIC_STREAM_H
#include "internal.h"
#include <xpc/xpc.h>
/* kind: 1 activity, 2 legacy trace, 4 log/metric, 8 signpost. */
bool finch_trace_stream_enabled(unsigned kind, uint8_t level, struct finch_log *log);
struct finch_trace_stream_event {
	uint64_t identifier, timestamp;
	const void *image, *pc;
	const char *name;
	uint64_t format_offset;
	const void *buffer;
	size_t buffer_size;
	const void *private_data;
	size_t private_size;
	struct finch_log *log;
	uint64_t signpost_id;
	const char *signpost_name;
	uint8_t ttl;
	bool persisted;
	void *activity;
	const struct timespec *wall;
};
void finch_trace_stream_send(
    const struct finch_trace_stream_event *, void (^payload)(xpc_object_t));
void finch_trace_stream_fork_child(void);
/* Kept separate so tests can exercise the saved filter without host changes. */
struct finch_trace_filter_subject {
	const char *subsystem, *category, *path, *process;
	int32_t pid;
	uint32_t uid;
};
bool finch_trace_filter_matches(
    xpc_object_t, const struct finch_trace_filter_subject *, uint64_t[2]);
#endif
