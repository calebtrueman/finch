/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ring.h"
#include <assert.h>
#include <errno.h>
#include <string.h>
#include <strings.h>
#define API __attribute__((visibility("default")))
static size_t aligned(size_t n)
{
	return (n + 7) & ~(size_t)7;
}
API int RTLogRingBufferInit(struct rt_ring *r, void *size_buffer, void *parts, void *data,
    uint32_t count, size_t segment_size)
{
	assert(r && size_buffer && parts && data);
	if (!count || !segment_size) {
		errno = EINVAL;
		return -1;
	}
	r->count = count;
	r->segment_size = segment_size;
	r->next = (void *)((char *)size_buffer + 16);
	r->parts = parts;
	r->data = data;
	memcpy(size_buffer, r, 16);
	atomic_store_explicit(r->next, count + 1, memory_order_release);
	memset(parts, 0, count * 4);
	return 0;
}
API int RTLogRingBufferCreateManaged(
    struct rt_ring *r, void *data, uint32_t count, size_t segment_size)
{
	assert(r && data);
	if (!count || !segment_size || (count & (count - 1))) {
		errno = EINVAL;
		return -1;
	}
	r->count = count;
	r->segment_size = segment_size;
	r->next = data;
	r->parts = (void *)((char *)data + 4);
	r->data = (void *)aligned((uintptr_t)data + 4 + count * 4);
	atomic_store_explicit(r->next, count + 1, memory_order_release);
	return 0;
}
API int RTLogRingBufferJoinManaged(struct rt_ring *r, const void *size, void *data)
{
	assert(r && size && data);
	const struct rt_ring *s = size;
	if (!s->count || !s->segment_size || (s->count & (s->count - 1)))
		return 0;
	memcpy(r, size, 16);
	r->next = data;
	r->parts = (void *)((char *)data + 4);
	r->data = (void *)aligned((uintptr_t)data + 4 + r->count * 4);
	return 1;
}
API size_t RTLogRingBufferDataSize(size_t count, size_t segment_size)
{
	return 8 + count * (segment_size + 4);
}
API uint32_t RTLogRingBufferGetSegmentCount(const struct rt_ring *r)
{
	assert(r);
	return r->count;
}
API size_t RTLogRingBufferGetSegmentSize(const struct rt_ring *r)
{
	assert(r);
	return r->segment_size;
}
API int RTLogRingBufferIsDataAvailable(const struct rt_ring *r, uint32_t cursor)
{
	return (int32_t)(cursor - atomic_load_explicit(r->next, memory_order_relaxed)) < 0;
}
API int RTLogRingBufferWriteWithCallback(struct rt_ring *r, rt_write_fn fn, size_t n, void *context)
{
	assert(r && fn);
	if (n > r->segment_size * r->count) {
		errno = ENOSPC;
		return -1;
	}
	uint32_t segments = (uint32_t)((n + r->segment_size - 1) / r->segment_size),
	         start = atomic_fetch_add_explicit(r->next, segments, memory_order_relaxed),
	         slot = start & (r->count - 1);
	struct rt_write_parts pieces = {{r->data + slot * r->segment_size, n}, {NULL, 0}};
	if (slot + segments > r->count) {
		pieces.first.size = (r->count - slot) * r->segment_size;
		pieces.second.data = r->data;
		pieces.second.size = n - pieces.first.size;
	}
	for (uint32_t i = 1; i < segments; i++)
		atomic_store_explicit(
		    &r->parts[(start + i) & (r->count - 1)], start, memory_order_relaxed);
	fn(&pieces, context);
	atomic_store_explicit(&r->parts[slot], start, memory_order_release);
	return 0;
}
static void flat_write(const struct rt_write_parts *p, void *context)
{
	const struct rt_piece *in = context;
	memcpy(p->first.data, in->data, p->first.size);
	if (p->second.size)
		memcpy(p->second.data, (const char *)in->data + p->first.size, p->second.size);
}
API int RTLogRingBufferWriteBuffer(struct rt_ring *r, const void *in, size_t n)
{
	assert(r && in);
	struct rt_piece p = {(void *)in, n};
	return RTLogRingBufferWriteWithCallback(r, flat_write, n, &p);
}
struct message {
	const struct rt_piece *pieces;
	size_t count;
};
static void message_write(const struct rt_write_parts *p, void *context)
{
	const struct message *m = context;
	unsigned char *out = p->first.data;
	size_t available = p->first.size;
	for (size_t i = 0; i < m->count; i++) {
		const unsigned char *src = m->pieces[i].data;
		size_t n = m->pieces[i].size;
		if (!p->second.size || n < available) {
			memcpy(out, src, n);
			out += n;
			available -= n;
		} else {
			memcpy(out, src, available);
			out = p->second.data;
			memcpy(out, src + available, n - available);
			available = p->second.size;
		}
	}
}
API int RTLogRingBufferWriteMessage(struct rt_ring *r, const struct rt_piece *pieces, size_t count)
{
	size_t n = 0;
	for (size_t i = 0; i < count; i++)
		n += pieces[i].size;
	struct message m = {pieces, count};
	return RTLogRingBufferWriteWithCallback(r, message_write, n, &m);
}
API int RTLogRingBufferReadAt(
    struct rt_ring *r, rt_read_fn fn, void *context, uint32_t *cursor, uint32_t *dropped)
{
	assert(r->count > 0);
	uint32_t count = r->count, end = atomic_load_explicit(r->next, memory_order_relaxed),
	         current = *cursor, msg, next;
	if (end - current > count) {
		*dropped = end - current - count;
		current = end - count;
		*cursor = current;
		for (;;) {
			msg = atomic_load_explicit(
			    &r->parts[current & (count - 1)], memory_order_acquire);
			if (msg == current)
				break;
			current++;
			*cursor = current;
			if ((int32_t)(current - end) >= 0)
				break;
		}
	} else {
		msg = atomic_load_explicit(&r->parts[current & (count - 1)], memory_order_acquire);
		*dropped = 0;
		if ((int32_t)(msg - current) < 0)
			return 0;
	}
	if (current == end)
		return 0;
	const unsigned char *data = r->data + (current & (count - 1)) * r->segment_size;
	size_t bytes = r->segment_size;
	uint32_t callback_start = current;
	*cursor = ++current;
	for (;;) {
		next = atomic_load_explicit(&r->parts[current & (count - 1)], memory_order_acquire);
		if (next != msg)
			break;
		if ((int32_t)(current - end) >= 0) {
			next = msg;
			break;
		}
		if (!(current & (count - 1))) {
			fn(callback_start, data, (uint32_t)bytes, context);
			bytes = 0;
			data = r->data;
			callback_start = current;
		}
		bytes += r->segment_size;
		*cursor = ++current;
	}
	fn(callback_start, data, (uint32_t)bytes, context);
	return (int32_t)(next - (msg + count)) < 0;
}
struct read_buffer {
	void *buffer;
	uint32_t used, reserved;
	size_t capacity;
};
static void copy_read(uint32_t start, const void *data, size_t n, void *p)
{
	(void)start;
	struct read_buffer *b = p;
	size_t room = b->capacity - b->used;
	if (n > room)
		n = room;
	memcpy((char *)b->buffer + b->used, data, n);
	b->used += (uint32_t)n;
}
API int RTLogRingBufferIterateFrom(struct rt_ring *r, uint32_t *cursor, void *context, void *buffer,
    size_t capacity, rt_dropped_fn loss, rt_iterate_fn fn)
{
	assert(r && cursor && buffer && fn);
	uint32_t start = *cursor, end = atomic_load_explicit(r->next, memory_order_relaxed),
	         dropped = 0;
	for (;;) {
		struct read_buffer b = {buffer, 0, 0, capacity};
		if (!RTLogRingBufferReadAt(r, copy_read, &b, cursor, &dropped))
			return 0;
		if (loss && dropped)
			loss(buffer, context, dropped);
		if (!fn(buffer, context))
			return 1;
		if ((int32_t)(*cursor - end) >= 0)
			return *cursor != start;
	}
}
API int RTLogRingBufferIterate(
    struct rt_ring *r, void *context, void *buffer, size_t capacity, rt_iterate_fn fn)
{
	assert(r && buffer && fn);
	uint32_t cursor = atomic_load_explicit(r->next, memory_order_acquire) - r->count,
	         end = atomic_load_explicit(r->next, memory_order_relaxed);
	int ret;
	for (;;) {
		ret = RTLogRingBufferIterateFrom(r, &cursor, context, buffer, capacity, NULL, fn);
		if (ret || (int32_t)(cursor - end) >= 0)
			return ret;
		cursor++;
	}
}
static const char marker[32] = "[==========LOGBUFFER==========]";
API void RTLogBufferInitialize(void *p, size_t n)
{
	assert(p && n >= sizeof(struct rt_buffer));
	struct rt_buffer *b = p;
	memcpy(b->marker, marker, 32);
	b->marker_length = 32;
	b->version = 5;
	b->size = n;
}
API int RTLogBufferCheckStatus(const void *p)
{
	assert(p);
	const struct rt_buffer *b = p;
	if (b->marker_length != 32 || strncmp(b->marker, marker, 31))
		return 2;
	if (b->version != 5)
		return 1;
	return b->count > 15 ? 3 : 0;
}
API void *RTLogBufferGetHeader(void *p)
{
	assert(p);
	return RTLogBufferCheckStatus(p) ? NULL : p;
}
API void *RTLogBufferGetResource(void *p, uint32_t type)
{
	assert(p);
	struct rt_buffer *b = p;
	if (RTLogBufferCheckStatus(p))
		return NULL;
	for (size_t i = 0; i < b->count; i++)
		if (b->resources[i].type == type)
			return b->resources[i].offset > b->size
			    ? NULL
			    : (char *)p + b->resources[i].offset;
	return NULL;
}
API size_t RTLogBufferGetResourceSize(const void *p, uint32_t type)
{
	assert(p);
	const struct rt_buffer *b = p;
	if (RTLogBufferCheckStatus(p))
		return 0;
	for (size_t i = 0; i < b->count; i++)
		if (b->resources[i].type == type)
			return b->resources[i].size;
	return 0;
}
API void *RTLogBufferAllocateResource(void *p, uint32_t type, size_t n)
{
	assert(p);
	struct rt_buffer *b = p;
	size_t bytes = aligned(n),
	       offset = b->count
	    ? aligned(b->resources[b->count - 1].offset + b->resources[b->count - 1].size)
	    : sizeof(*b);
	assert(offset + bytes <= b->size);
	assert(b->count < 15);
	struct rt_resource *r = &b->resources[b->count];
	r->type = type;
	r->offset = offset;
	r->size = bytes;
	b->count++;
	b->used += bytes;
	void *out = (char *)p + offset;
	assert(!((uintptr_t)out & 7));
	return out;
}
API void *RTLogBufferAddResource(void *p, uint32_t type, const void *data, size_t n)
{
	assert(p && data);
	void *out = RTLogBufferAllocateResource(p, type, n);
	assert(out);
	return memcpy(out, data, n);
}
API size_t RTLogBufferRequiredStorageSize(const size_t *sizes, size_t count)
{
	if (!count || count > 14)
		return 0;
	size_t n = sizeof(struct rt_buffer);
	for (size_t i = 0; i < count; i++)
		n += aligned(sizes[i]);
	return n;
}
API void RTLogBufferIterate(void *p, void (*fn)(const struct rt_resource *, void *), void *context)
{
	assert(p && fn);
	struct rt_buffer *b = p;
	if (RTLogBufferCheckStatus(p))
		return;
	for (size_t i = 0; i < b->count; i++)
		fn(&b->resources[i], context);
}
API unsigned RTLogConnectMemoryConfigFromString(const char *s)
{
	if (!s || !strcasecmp(s, "default"))
		return 0;
	if (!strcasecmp(s, "small"))
		return 1;
	if (!strcasecmp(s, "medium"))
		return 2;
	if (!strcasecmp(s, "large"))
		return 3;
	return 0;
}
