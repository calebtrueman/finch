/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The receiver is captured here: no host port or logging service is changed. */
#include "../transport.c"
#include <assert.h>
#include <stdio.h>
static const struct trace_hooks *saved_hooks;
static uint8_t metadata[2048], packet[8192];
static size_t packet_size;
static uint64_t packet_id;
static uint32_t packet_flags;
static uint8_t packet_stream;
static unsigned packets, port_calls, registrations, state_calls;
static uint32_t mode;
bool finch_trace_lazy_initialized(void)
{
	return false;
}
uint64_t finch_rt_send(uint8_t s, uint64_t id, uint64_t time, const struct iovec *v, size_t pub,
    size_t priv, uint32_t flags)
{
	(void)s;
	(void)id;
	(void)time;
	(void)v;
	(void)pub;
	(void)priv;
	(void)flags;
	abort();
}
static xpc_object_t large_request;
static unsigned quarantines;
void finch_trace_quarantine(void)
{
	quarantines++;
}
void voucher_activity_initialize_4libtrace(const struct trace_hooks *h)
{
	assert(h->version == 5);
	saved_hooks = h;
}
void *voucher_activity_get_metadata_buffer(size_t *n)
{
	*n = sizeof(metadata);
	return metadata;
}
uint64_t voucher_activity_trace_v_2(uint8_t stream, uint64_t id, uint64_t stamp,
    const struct iovec *v, size_t pub, size_t priv, uint32_t flags)
{
	assert(stamp && priv == 0 && pub <= sizeof(packet));
	packet_stream = stream;
	packet_id = id;
	packet_flags = flags;
	packet_size = pub;
	size_t at = 0;
	while (at < pub) {
		assert(v->iov_len <= pub - at);
		memcpy(packet + at, v->iov_base, v->iov_len);
		at += v->iov_len;
		v++;
	}
	packets++;
	return id;
}
uint32_t os_trace_get_mode(void)
{
	return mode;
}
uint32_t finch_trace_commpage(void)
{
	return 0; /* tracing enabled system-wide */
}
uint32_t finch_trace_mode_peek(void)
{
	return mode;
}
void finch_trace_mode_fork_child(void)
{
}
void finch_trace_stream_fork_child(void)
{
}
void os_trace_set_mode(uint32_t m)
{
	mode = m;
}
kern_return_t bootstrap_look_up2(
    mach_port_t b, const char *s, mach_port_t *p, pid_t pid, uint64_t flags)
{
	(void)b;
	assert(!strcmp(s, "com.apple.logd") && !pid && flags == 8);
	*p = 123;
	return KERN_SUCCESS;
}
kern_return_t mach_port_construct(ipc_space_t task, mach_port_options_ptr_t options,
    mach_port_context_t context, mach_port_name_t *p)
{
	(void)task;
	assert(options->flags == 0x31 && context == 0x71b75ace);
	*p = 123;
	port_calls++;
	return 0;
}
kern_return_t task_set_special_port(task_t task, int which, mach_port_t port)
{
	(void)task;
	assert(which == 10 && port == 123);
	port_calls++;
	return 0;
}
void _dyld_register_func_for_add_image(void (*fn)(const struct mach_header *, intptr_t))
{
	assert(fn);
	registrations++;
}
void _dyld_register_func_for_remove_image(void (*fn)(const struct mach_header *, intptr_t))
{
	assert(fn);
	registrations++;
}
void *xpc_pipe_create(const char *name, uint64_t flags)
{
	assert(!strcmp(name, "com.apple.logd.events") && flags == 6);
	return xpc_dictionary_create(NULL, NULL, 0);
}
int xpc_pipe_simpleroutine(void *pipe, void *request)
{
	(void)pipe;
	if (large_request)
		xpc_release(large_request);
	large_request = xpc_retain(request);
	return 0;
}
int xpc_pipe_routine(void *pipe, xpc_object_t request, xpc_object_t *reply)
{
	*reply = NULL;
	return xpc_pipe_simpleroutine(pipe, request);
}
mach_msg_header_t *dispatch_mach_msg_get_msg(void *m, size_t *n)
{
	*n = ((mach_msg_header_t *)m)->msgh_size;
	return m;
}
void finch_trace_state_request(uint64_t aid, const void *data, uint8_t ttl, const void *image)
{
	const uint32_t *h = data;
	assert(aid == 12345 && h[0] == 1 && h[4] == 3 && h[5] == 1 && ttl == 14 && !image);
	state_calls++;
}
char *finch_log_describe_object(void *p)
{
	(void)p;
	return strdup("object");
}
bool finch_log_object_is_public(void *p)
{
	(void)p;
	return false;
}
extern char __dso_handle;
int main(void)
{
	struct iovec empty = {"", 1};
	assert(!finch_trace_send(0, 4, 1, &empty, 1, 0, 0) && !packets);
	_libtrace_init();
	assert(saved_hooks && port_calls == 2 && registrations == 2);
	saved_hooks->quarantine();
	assert(quarantines == 1);
	saved_hooks->metadata(metadata, sizeof(metadata));
	assert(saved_hooks->logd() == 123);
	struct {
		uint16_t id;
		uint8_t sn, cn;
		char names[10];
	} names = {77, 5, 5, "test\0case"};
	struct finch_log log = {.names = (void *)&names};
	finch_trace_register_log(&log);
	uint16_t end;
	memcpy(&end, metadata + 4, 2);
	assert(!memcmp(metadata + 41 + end - 14, &names, 14));
	finch_trace_register_log(&log);
	uint16_t again;
	memcpy(&again, metadata + 4, 2);
	assert(end == again);
	const char *format = "number %d";
	uint8_t data[8] = {0, 1, 0, 4};
	uint32_t value = 42;
	memcpy(data + 4, &value, 4);
	struct finch_log_pack p = {
	    .image = &__dso_handle, .pc = &__dso_handle + 123, .format = format};
	finch_trace_log_send(&log, 16, &p, data, 8, true);
	assert(packets == 1 && packet_stream == 0 && packet_flags == 1 && packet_size == 14);
	assert(packet_id ==
	    (UINT64_C(4) | (16 << 8) | ((uint64_t)0x202 << 16) |
	        ((uint64_t)(uint32_t)((uintptr_t)format - (uintptr_t)&__dso_handle) << 32)));
	uint32_t pc;
	memcpy(&pc, packet, 4);
	assert(pc == 123 && !memcmp(packet + 4, &names.id, 2) && !memcmp(packet + 6, data, 8));
	finch_trace_useraction(&__dso_handle, format, &__dso_handle + 456);
	assert(packet_size == 4 && packet_stream == 0 && (packet_id & 0xffff) == 0x302);
	memcpy(&pc, packet, 4);
	assert(pc == 456);
	char dynamic_format[32] = "number %d";
	p.format = dynamic_format;
	finch_trace_log_send(&log, 1, &p, data, 8, false);
	assert(packet_stream == 2 && (uint32_t)(packet_id >> 32) == 0x80000000);
	char *text = finch_log_compose_wire("%s", packet + 6, packet_size - 6, NULL, 0);
	assert(!strcmp(text, "number 42"));
	free(text);
	char *large = malloc(5001);
	memset(large, 'x', 5000);
	large[5000] = 0;
	uint8_t pointer_data[12] = {2, 1, 0x22, 8};
	memcpy(pointer_data + 4, &large, 8);
	p.format = "%{public}s";
	finch_trace_log_send(&log, 0, &p, pointer_data, sizeof(pointer_data), false);
	assert(large_request && ((packet_id >> 16) & 0x800) && packet_size == 10);
	assert(xpc_dictionary_get_uint64(large_request, "operation") == 3);
	size_t n = 0;
	const char *public_data = xpc_dictionary_get_data(large_request, "pubdata", &n);
	assert(n == 5001 && !memcmp(public_data, large, n));
	uint32_t mid;
	memcpy(&mid, packet + 6, 4);
	assert(mid == xpc_dictionary_get_uint64(large_request, "message_id"));
	free(large);
	mach_vm_address_t address = 0;
	mach_vm_size_t size = 0;
	assert(!saved_hooks->reconnect(&address, &size) && address && size);
	uint8_t *cursor = (void *)address;
	bool found = false;
	for (size_t off = 0; off + 8 <= size;) {
		uint32_t type, len;
		memcpy(&type, cursor + off, 4);
		memcpy(&len, cursor + off + 4, 4);
		if (!type && !len)
			break;
		assert(len <= size - off - 8);
		if (type == 2 && len == 14 && !memcmp(cursor + off + 8, &names, 14))
			found = true;
		off += 8 + ((len + 7) & ~7u);
	}
	assert(found);
	mach_vm_deallocate(mach_task_self(), address, size);
	struct {
		mach_msg_header_t h;
		NDR_record_t ndr;
		uint64_t aid;
	} request = {.h = {.msgh_size = 40, .msgh_id = 50001}, .aid = 12345};
	saved_hooks->debug(NULL, 2, &request, 0);
	assert(state_calls == 1);
	mode = 0x100;
	unsigned before = packets;
	finch_trace_log_send(&log, 0, &p, data, 8, false);
	assert(packets == before && saved_hooks->logd() == 0);
	xpc_release(large_request);
	puts(
	    "Trace transport: hooks, metadata, wire messages, large messages, reconnect and state requests passed (captured receiver)");
	return 0;
}
