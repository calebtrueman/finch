/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_RING_H
#define FINCH_TRACE_RING_H
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
struct rt_ring {
	uint32_t count, reserved;
	size_t segment_size;
	_Atomic uint32_t *next;
	_Atomic uint32_t *parts;
	unsigned char *data;
};
struct rt_piece {
	void *data;
	size_t size;
};
struct rt_write_parts {
	struct rt_piece first, second;
};
typedef void (*rt_write_fn)(const struct rt_write_parts *, void *);
typedef void (*rt_read_fn)(uint32_t, const void *, size_t, void *);
typedef int (*rt_iterate_fn)(void *, void *);
typedef void (*rt_dropped_fn)(void *, void *, uint32_t);
struct rt_resource {
	uint32_t type, reserved;
	size_t offset, size;
};
struct rt_buffer {
	char marker[32];
	uint16_t marker_length;
	unsigned char reserved[6];
	uint64_t version;
	size_t size, used, count;
	struct rt_resource resources[15];
};
int RTLogRingBufferInit(struct rt_ring *, void *, void *, void *, uint32_t, size_t);
int RTLogRingBufferCreateManaged(struct rt_ring *, void *, uint32_t, size_t);
int RTLogRingBufferJoinManaged(struct rt_ring *, const void *, void *);
size_t RTLogRingBufferDataSize(size_t, size_t);
int RTLogRingBufferWriteWithCallback(struct rt_ring *, rt_write_fn, size_t, void *);
int RTLogRingBufferWriteBuffer(struct rt_ring *, const void *, size_t);
int RTLogRingBufferWriteMessage(struct rt_ring *, const struct rt_piece *, size_t);
int RTLogRingBufferReadAt(struct rt_ring *, rt_read_fn, void *, uint32_t *, uint32_t *);
int RTLogRingBufferIterateFrom(
    struct rt_ring *, uint32_t *, void *, void *, size_t, rt_dropped_fn, rt_iterate_fn);
int RTLogRingBufferIterate(struct rt_ring *, void *, void *, size_t, rt_iterate_fn);
int RTLogRingBufferIsDataAvailable(const struct rt_ring *, uint32_t);
uint32_t RTLogRingBufferGetSegmentCount(const struct rt_ring *);
size_t RTLogRingBufferGetSegmentSize(const struct rt_ring *);
void RTLogBufferInitialize(void *, size_t);
int RTLogBufferCheckStatus(const void *);
void *RTLogBufferGetHeader(void *);
void *RTLogBufferGetResource(void *, uint32_t);
size_t RTLogBufferGetResourceSize(const void *, uint32_t);
void *RTLogBufferAllocateResource(void *, uint32_t, size_t);
void *RTLogBufferAddResource(void *, uint32_t, const void *, size_t);
size_t RTLogBufferRequiredStorageSize(const size_t *, size_t);
void RTLogBufferIterate(void *, void (*)(const struct rt_resource *, void *), void *);
unsigned RTLogConnectMemoryConfigFromString(const char *);
#endif
