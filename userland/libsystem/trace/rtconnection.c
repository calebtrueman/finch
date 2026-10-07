/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "transport.h"
#include "ring.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <xpc/xpc.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
extern void xpc_dictionary_set_mach_send(xpc_object_t, const char *, mach_port_t);
extern void __xpc_connection_set_logging(xpc_connection_t, bool);
extern void finch_trace_metadata_init(void *, size_t);
extern mach_port_t finch_trace_logd_port(void);
static pthread_mutex_t connection_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned connection_state;
static bool connected_once;
static uint8_t memory_config;
static xpc_connection_t connection;
static mach_port_t memory_port;
static void *shared_memory;
static size_t shared_size;
static struct rt_ring bins[6];
static uint8_t *process_resource;
API unsigned RTBinIndexForType(int type)
{
	switch (type) {
	case 0:
		return 3;
	case 1:
		return 2;
	case 2:
		return 1;
	case 16:
	case 17:
		return 4;
	default:
		abort();
	}
}
API void RTLogDisconnect(void)
{
	pthread_mutex_lock(&connection_lock);
	if (atomic_load(&connection_state)) {
		if (connection) {
			xpc_connection_cancel(connection);
			xpc_release(connection);
			connection = NULL;
		}
		atomic_store(&connection_state, 0);
	}
	pthread_mutex_unlock(&connection_lock);
}
API int RTLogConnectRingBuffer(const uint8_t *config)
{
	assert(config);
	static const uint32_t default_counts[6] = {64, 256, 256, 2048, 256, 1024};
	static const size_t segment_sizes[6] = {256, 64, 64, 64, 64, 64};
	unsigned scale = memory_config == 2 ? 1 : memory_config == 3 ? 2 : 0;
	uint32_t counts[6];
	size_t resources[9];
	for (unsigned i = 0; i < 6; i++) {
		counts[i] = default_counts[i] << (i ? scale : 0);
		resources[i] = RTLogRingBufferDataSize(counts[i], segment_sizes[i]);
	}
	resources[6] = 96;
	resources[7] = 80;
	resources[8] = 2048;
	size_t requested = RTLogBufferRequiredStorageSize(resources, 9);
	mach_vm_address_t address = 0;
	kern_return_t result = mach_vm_allocate(
	    mach_task_self(), &address, requested, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
	assert(result == KERN_SUCCESS);
	memory_object_size_t memory_size = requested;
	mach_port_t port = MACH_PORT_NULL;
	result = mach_make_memory_entry_64(mach_task_self(), &memory_size, address,
	    VM_PROT_READ | VM_PROT_WRITE, &port, MACH_PORT_NULL);
	assert(result == KERN_SUCCESS);
	shared_memory = (void *)address;
	shared_size = memory_size;
	memory_port = port;
	RTLogBufferInitialize(shared_memory, shared_size);
	for (unsigned i = 0; i < 6; i++) {
		void *storage = RTLogBufferAllocateResource(shared_memory, i + 2, resources[i]);
		assert(storage);
		assert(
		    !RTLogRingBufferCreateManaged(bins + i, storage, counts[i], segment_sizes[i]));
		void *description = RTLogBufferAllocateResource(shared_memory, i + 8, 16);
		assert(description);
		memcpy(description, bins + i, 16);
	}
	void *metadata = RTLogBufferAllocateResource(shared_memory, 14, 2048);
	assert(metadata);
	finch_trace_metadata_init(metadata, 2048);
	struct {
		char name[64];
		uint32_t pid, uid, flags, random;
	} process = {0};
	strlcpy(process.name, getprogname(), sizeof(process.name));
	process.pid = getpid();
	process.uid = geteuid();
	process.random = (uint32_t)rand();
	process_resource = RTLogBufferAddResource(shared_memory, 1, &process, sizeof(process));
	assert(process_resource);
	atomic_store(&connection_state, 1);
	connection = xpc_connection_create_mach_service("com.apple.logd.realtime", NULL, 0);
	assert(connection);
	__xpc_connection_set_logging(connection, false);
	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
	  if (xpc_get_type(event) != XPC_TYPE_ERROR)
		  atomic_store(&connection_state, 2);
	});
	xpc_connection_activate(connection);
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
	xpc_dictionary_set_uint64(message, "rt_message_type", 0);
	xpc_dictionary_set_uint64(message, "rt_shmem_size", shared_size);
	xpc_dictionary_set_mach_send(message, "rt_shmem_descriptor", memory_port);
	xpc_connection_send_message(connection, message);
	xpc_release(message);
	(void)finch_trace_logd_port();
	return 0;
}
API int RTLogConnect(void)
{
	if (atomic_load(&connection_state))
		return 1;
	pthread_mutex_lock(&connection_lock);
	int result = 1;
	if (!connected_once) {
		memory_config =
		    (uint8_t)RTLogConnectMemoryConfigFromString(getenv("OSLogRTBufferConfig"));
		RTLogConnectRingBuffer(&memory_config);
		connected_once = true;
		result = 0;
	}
	pthread_mutex_unlock(&connection_lock);
	return result;
}
struct rt_record_copy {
	uint8_t *bytes;
	size_t size;
	uint64_t identifier;
};
static void copy_record(const struct rt_write_parts *parts, void *context)
{
	struct rt_record_copy *r = context;
	assert(parts->first.size >= 40);
	size_t n = parts->first.size < r->size ? parts->first.size : r->size;
	memcpy(parts->first.data, r->bytes, n);
	if (n < r->size)
		memcpy(parts->second.data, r->bytes + n, r->size - n);
	__atomic_store_n(
	    (uint64_t *)((uint8_t *)parts->first.data + 16), r->identifier, __ATOMIC_RELEASE);
}
uint64_t finch_rt_send(uint8_t stream, uint64_t identifier, uint64_t stamp, const struct iovec *iov,
    size_t public_size, size_t private_size, uint32_t flags)
{
	RTLogConnect();
	uint16_t trace_flags = (uint16_t)(identifier >> 16);
	uint64_t creator = (trace_flags & 0x10) ? (uint64_t)getpid() : 0;
	if (!creator)
		trace_flags &= ~0x10;
	size_t pub = public_size + (creator ? 8 : 0) + (private_size ? 4 : 0);
	if (private_size)
		trace_flags |= 0x100;
	size_t private_offset = 40 + ((pub + 7) & ~(size_t)7),
	       total = (private_offset + private_size + 7) & ~(size_t)7;
	if (total >= 4081)
		abort();
	uint8_t data[4080] = {0};
	uint16_t total16 = total, private16 = private_offset;
	memcpy(data, &total16, 2);
	memcpy(data + 2, &private16, 2);
	data[4] = 1;
	data[6] = stream;
	data[7] = (uint8_t)((((0x13u >> stream) & 1) | ((process_resource[72] & 2)) |
	                        ((flags & 1) ? 0 : 4))
	              << 1) &
	    6;
	uint64_t base = stamp >= UINT64_C(0x1000000000) ? stamp - UINT64_C(0x1000000000) : 0;
	memcpy(data + 8, &base, 8);
	uint64_t thread;
	pthread_threadid_np(NULL, &thread);
	memcpy(data + 24, &thread, 8);
	uint64_t time_length = (stamp - base) | ((uint64_t)pub << 48);
	memcpy(data + 32, &time_length, 8);
	size_t offset = 40;
	if (creator) {
		memcpy(data + offset, &creator, 8);
		offset += 8;
	}
	if (private_size) {
		uint32_t range =
		    (uint16_t)private_offset | ((uint32_t)(uint16_t)private_size << 16);
		memcpy(data + offset, &range, 4);
		offset += 4;
	}
	size_t left = public_size;
	while (left) {
		assert(iov->iov_len <= left);
		memcpy(data + offset, iov->iov_base, iov->iov_len);
		offset += iov->iov_len;
		left -= iov->iov_len;
		iov++;
	}
	offset = private_offset;
	left = private_size;
	while (left) {
		assert(iov->iov_len <= left);
		memcpy(data + offset, iov->iov_base, iov->iov_len);
		offset += iov->iov_len;
		left -= iov->iov_len;
		iov++;
	}
	identifier = (identifier & ~UINT64_C(0xffff0000)) | ((uint64_t)trace_flags << 16);
	struct rt_record_copy copy = {data, total, identifier};
	unsigned bin = stream == 3    ? 0
	    : (identifier & 255) == 6 ? 5
	                              : RTBinIndexForType((identifier >> 8) & 255);
	assert(!RTLogRingBufferWriteWithCallback(bins + bin, copy_record, total, &copy));
	return identifier;
}
