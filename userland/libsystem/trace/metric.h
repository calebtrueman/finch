/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_METRIC_H
#define FINCH_TRACE_METRIC_H
#include "internal.h"
struct metric_object {
	const void *__ptrauth_objc_isa_pointer isa;
	int32_t refs, xrefs;
};
struct metric_label {
	struct metric_object object;
	void *data;
	size_t size;
	void *strings;
	size_t strings_size;
};
struct metric_dimensions {
	struct metric_object object;
	uint8_t capacity, count, reserved[6];
	struct metric_label **labels;
};
struct metric_group {
	struct metric_object object;
	struct finch_log *log;
	struct metric_dimensions *dimensions;
};
struct metric {
	struct metric_object object;
	struct metric_group *group;
	struct metric_label *label;
	struct metric_dimensions *dimensions;
	uint8_t kind, type, stats, unit, scale, bins, reserved[2];
	uint32_t width;
	uint8_t option, padding[3];
	uint64_t data[];
};
struct metric_label_part {
	uint64_t type;
	const char *value;
};
void *finch_metric_allocate(unsigned, size_t);
void finch_trace_metric_send(
    struct finch_log *, uint8_t, const void *, const void *, uint64_t, const void *, size_t);
#endif
