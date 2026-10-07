/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Local trace buffer helpers. The host keeps these helpers private. */
#include "blob.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
uint32_t os_trace_blob_available(const struct finch_trace_blob *b)
{
	return b->capacity - b->length - (b->binary ^ 1);
}
uint32_t os_trace_blob_grow(struct finch_trace_blob *b, size_t extra)
{
	uint32_t used = b->length + (b->binary ^ 1), cap = b->maximum;
	if (extra <= UINT32_MAX - used && b->capacity <= UINT32_MAX / 2) {
		uint32_t need = used + extra, doubled = b->capacity * 2;
		cap = need > doubled ? need : doubled;
		if (cap > b->maximum)
			cap = b->maximum;
	}
	if (cap > b->capacity) {
		void *p = (b->flags & 1) ? realloc(b->data, cap) : malloc(cap);
		if (!p)
			return os_trace_blob_available(b);
		if (!(b->flags & 1)) {
			if (used)
				memcpy(p, b->data, used);
			b->flags |= 1;
		}
		b->data = p;
		b->capacity = cap;
	}
	return cap - used;
}
size_t os_trace_blob_add_slow(struct finch_trace_blob *b, const void *data, size_t size)
{
	if (b->flags & 2)
		return 0;
	uint32_t available = os_trace_blob_available(b);
	if (size > available && b->capacity < b->maximum)
		available = os_trace_blob_grow(b, size);
	if (size > available) {
		b->flags |= 2;
		size = available;
	}
	if (size)
		memcpy((char *)b->data + b->length, data, size);
	b->length += size;
	if (!b->binary)
		((char *)b->data)[b->length] = 0;
	return size;
}
void finch_trace_blob_append(void *blob, const void *data, size_t size)
{
	os_trace_blob_add_slow(blob, data, size);
}
size_t os_trace_blob_vaddf(struct finch_trace_blob *b, const char *format, int error, va_list args)
{
	if (b->binary == 1)
		__builtin_trap();
	if (b->flags & 2)
		return 0;
	uint32_t available = os_trace_blob_available(b);
	va_list copy;
	va_copy(copy, args);
	errno = error;
	int result = vsnprintf((char *)b->data + b->length, b->capacity - b->length, format, copy);
	va_end(copy);
	if (result < 0) {
		((char *)b->data)[b->length] = 0;
		return 0;
	}
	size_t count = result;
	if (count > available && b->capacity < b->maximum) {
		available = os_trace_blob_grow(b, count);
		va_copy(copy, args);
		errno = error;
		vsnprintf((char *)b->data + b->length, (size_t)available + 1, format, copy);
		va_end(copy);
	}
	if (count > available) {
		count = available;
		b->flags |= 2;
	}
	b->length += count;
	return count;
}
size_t os_trace_blob_addf(struct finch_trace_blob *b, const char *format, ...)
{
	va_list args;
	va_start(args, format);
	size_t n = os_trace_blob_vaddf(b, format, 0, args);
	va_end(args);
	return n;
}
void *os_trace_blob_detach(struct finch_trace_blob *b, size_t *size)
{
	void *p = b->data;
	uint16_t flags = b->flags;
	b->data = (void *)(uintptr_t)0xebadf000;
	b->flags = 0;
	if (size)
		*size = b->length;
	if (flags & 1)
		return p;
	size_t count = b->length + (b->binary ^ 1);
	void *out = malloc(count ? count : 1);
	if (out && count)
		memcpy(out, p, count);
	return out;
}
