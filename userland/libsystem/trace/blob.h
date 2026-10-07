/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_BLOB_H
#define FINCH_TRACE_BLOB_H
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
struct finch_trace_blob {
	void *data;
	uint32_t length, capacity, maximum;
	uint16_t flags;
	uint8_t binary, reserved;
};
uint32_t os_trace_blob_available(const struct finch_trace_blob *);
uint32_t os_trace_blob_grow(struct finch_trace_blob *, size_t);
size_t os_trace_blob_add_slow(struct finch_trace_blob *, const void *, size_t);
size_t os_trace_blob_addf(struct finch_trace_blob *, const char *, ...);
size_t os_trace_blob_vaddf(struct finch_trace_blob *, const char *, int, va_list);
void *os_trace_blob_detach(struct finch_trace_blob *, size_t *);
void finch_trace_blob_append(void *, const void *, size_t);
#endif
