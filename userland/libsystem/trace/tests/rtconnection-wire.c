/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#define mach_vm_allocate mock_allocate
#define mach_make_memory_entry_64 mock_memory_entry
#define xpc_connection_create_mach_service mock_connection_create
#define __xpc_connection_set_logging mock_connection_logging
#define xpc_connection_set_event_handler mock_connection_handler
#define xpc_connection_activate mock_connection_activate
#define xpc_connection_send_message mock_connection_send
#define xpc_dictionary_set_mach_send mock_set_mach_send
#define xpc_connection_cancel mock_connection_cancel
#include "../rtconnection.c"
#include <Block.h>
#include <stdio.h>
static unsigned creates, activates, cancels, requests, metadata_calls;
static xpc_handler_t event_handler;
static xpc_object_t request;
kern_return_t mock_allocate(vm_map_t task, mach_vm_address_t *address, mach_vm_size_t n, int flags)
{
	assert(task == mach_task_self() && (flags & VM_FLAGS_ANYWHERE));
	*address = (uintptr_t)calloc(1, n);
	return *address ? 0 : KERN_RESOURCE_SHORTAGE;
}
kern_return_t mock_memory_entry(vm_map_t task, memory_object_size_t *n,
    memory_object_offset_t address, vm_prot_t permissions, mach_port_t *out, mach_port_t parent)
{
	assert(task == mach_task_self() && *n && address && permissions == 3 && !parent);
	*out = 123;
	return 0;
}
xpc_connection_t mock_connection_create(const char *name, dispatch_queue_t queue, uint64_t flags)
{
	assert(!strcmp(name, "com.apple.logd.realtime") && !queue && !flags);
	creates++;
	return (void *)xpc_dictionary_create(NULL, NULL, 0);
}
void mock_connection_logging(xpc_connection_t c, bool enabled)
{
	assert(c && !enabled);
}
void mock_connection_handler(xpc_connection_t c, xpc_handler_t handler)
{
	assert(c);
	event_handler = Block_copy(handler);
}
void mock_connection_activate(xpc_connection_t c)
{
	assert(c);
	activates++;
}
void mock_connection_cancel(xpc_connection_t c)
{
	assert(c);
	cancels++;
}
void mock_set_mach_send(xpc_object_t dictionary, const char *key, mach_port_t port)
{
	assert(!strcmp(key, "rt_shmem_descriptor") && port == 123);
	xpc_dictionary_set_uint64(dictionary, key, port);
}
void mock_connection_send(xpc_connection_t c, xpc_object_t r)
{
	assert(c);
	request = xpc_retain(r);
	requests++;
}
void finch_trace_metadata_init(void *p, size_t n)
{
	assert(n == 2048);
	memset(p, 0, n);
	metadata_calls++;
}
mach_port_t finch_trace_logd_port(void)
{
	return 123;
}
static unsigned read_count;
static uint64_t expected_id;
static void read_record(uint32_t index, const void *data, size_t size, void *context)
{
	(void)index;
	(void)context;
	const uint8_t *p = data;
	assert(size >= 48);
	uint16_t total, offset;
	memcpy(&total, p, 2);
	memcpy(&offset, p + 2, 2);
	assert(total == 48 && offset == 48 && p[4] == 1 && p[6] == 0);
	uint64_t identifier;
	memcpy(&identifier, p + 16, 8);
	assert(identifier == expected_id);
	assert(!memcmp(p + 40, "hello", 6));
	read_count++;
}
int main(void)
{
	unsetenv("OSLogRTBufferConfig");
	assert(RTLogConnect() == 0 && RTLogConnect() == 1);
	assert(creates == 1 && activates == 1 && requests == 1 && metadata_calls == 1 &&
	    connection_state == 1);
	assert(xpc_dictionary_get_uint64(request, "rt_message_type") == 0 &&
	    xpc_dictionary_get_uint64(request, "rt_shmem_size") == shared_size &&
	    xpc_dictionary_get_uint64(request, "rt_shmem_descriptor") == 123);
	assert(RTLogBufferCheckStatus(shared_memory) == 0);
	struct rt_buffer *b = shared_memory;
	assert(b->count == 14);
	for (unsigned i = 0; i < 6; i++) {
		assert(RTLogBufferGetResource(shared_memory, 2 + i));
		assert(RTLogBufferGetResourceSize(shared_memory, 8 + i) == 16);
	}
	assert(RTLogBufferGetResourceSize(shared_memory, 14) == 2048 &&
	    RTLogBufferGetResourceSize(shared_memory, 1) == 80);
	event_handler((void *)XPC_ERROR_CONNECTION_INTERRUPTED);
	assert(connection_state == 1);
	event_handler(request);
	assert(connection_state == 2);
	struct iovec payload = {"hello", 6};
	expected_id = 4;
	assert(finch_rt_send(0, 4, 123456, &payload, 6, 0, 0) == 4);
	uint32_t cursor = bins[3].count + 1, lost = 0;
	RTLogRingBufferReadAt(bins + 3, read_record, NULL, &cursor, &lost);
	assert(read_count == 1 && !lost);
	RTLogDisconnect();
	RTLogDisconnect();
	assert(cancels == 1 && connection_state == 0 && RTLogConnect() == 1);
	xpc_release(request);
	Block_release(event_handler);
	free(shared_memory);
	puts(
	    "RT connection: shared resources, service message, event states, ring packet and disconnect passed (mock service)");
}
