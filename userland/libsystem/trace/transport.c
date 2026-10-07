/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* libdispatch owns the shared firehose pages and Mach delivery. These hooks
 * supply process, image and log-name records in the format logd consumes. */
#include "fault.h"
#include "transport.h"
#include "blob.h"
#include "mode.h"
#include "diagnostic_stream.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <servers/bootstrap.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <xpc/xpc.h>
#include <errno.h>
#include <mach/ndr.h>
extern kern_return_t bootstrap_look_up2(mach_port_t, const char *, mach_port_t *, pid_t, uint64_t);
struct trace_unique_process {
	uint8_t uuid[16];
	uint64_t uniqueid, parentid;
	int32_t version, parentversion;
	uint64_t reserved[2];
};
struct trace_hooks {
	long version;
	mach_port_t (*logd)(void);
	void (*debug)(void *, long, void *, int);
	kern_return_t (*reconnect)(mach_vm_address_t *, mach_vm_size_t *);
	void (*metadata)(void *, size_t);
	void (*quarantine)(void);
};
extern void voucher_activity_initialize_4libtrace(const struct trace_hooks *);
extern void *voucher_activity_get_metadata_buffer(size_t *);
extern uint64_t voucher_activity_trace_v_2(
    uint8_t, uint64_t, uint64_t, const struct iovec *, size_t, size_t, uint32_t);
extern void *_dyld_get_shared_cache_range(size_t *);
extern bool _dyld_get_shared_cache_uuid(uint8_t *);
extern uint32_t os_trace_get_mode(void);
extern void os_trace_set_mode(uint32_t);
static _Atomic bool ready;
static uint8_t client_type;
extern uint64_t finch_rt_send(
    uint8_t, uint64_t, uint64_t, const struct iovec *, size_t, size_t, uint32_t);
static pthread_mutex_t metadata_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t *process_metadata;
static uintptr_t cache_base;
static size_t cache_size;
struct registered_log {
	struct registered_log *next;
	struct finch_log *log;
};
static struct registered_log *registered_logs;
static bool in_cache(const void *p)
{
	return (uintptr_t)p >= cache_base && (uintptr_t)p - cache_base < cache_size;
}
uint64_t finch_trace_send(uint8_t stream, uint64_t id, uint64_t stamp, const struct iovec *iov,
    size_t public_size, size_t private_size, uint32_t flags)
{
	if (!atomic_load_explicit(&ready, memory_order_acquire) || (os_trace_get_mode() & 0x100))
		return 0;
	if (client_type == 2)
		return finch_rt_send(stream, id, stamp, iov, public_size, private_size, flags);
	return voucher_activity_trace_v_2(stream, id, stamp, iov, public_size, private_size, flags);
}
mach_port_t finch_trace_logd_port(void)
{
	mach_port_t port = MACH_PORT_NULL;
	/* Like Apple's: no logd lookup while tracing is disabled for the process or,
	 * through the commpage, system-wide. With logging off there is no logd to
	 * ask, and in PID 1 (the bootstrap server) a lookup can wait on itself. */
	if ((finch_trace_mode_peek() | finch_trace_commpage()) & 0x100)
		return port;
	return bootstrap_look_up2(bootstrap_port, "com.apple.logd", &port, 0, 8) == KERN_SUCCESS
	    ? port
	    : MACH_PORT_NULL;
}
static bool image_record(const struct mach_header *header, uint8_t record[32])
{
	if (!header || header->magic != MH_MAGIC_64)
		return false;
	const struct mach_header_64 *h = (const void *)header;
	const uint8_t *p = (const void *)(h + 1), *end = p + h->sizeofcmds;
	bool found = false;
	uint64_t size = 0;
	memset(record, 0, 32);
	memcpy(record + 16, &header, 8);
	for (uint32_t i = 0; i < h->ncmds && p + sizeof(struct load_command) <= end; i++) {
		const struct load_command *c = (const void *)p;
		if (c->cmdsize < sizeof(*c) || c->cmdsize > (size_t)(end - p))
			break;
		if (c->cmd == LC_UUID && c->cmdsize >= sizeof(struct uuid_command)) {
			memcpy(record, ((const struct uuid_command *)c)->uuid, 16);
			found = true;
		}
		if (c->cmd == LC_SEGMENT_64 && c->cmdsize >= sizeof(struct segment_command_64)) {
			const struct segment_command_64 *s = (const void *)c;
			if (!strcmp(s->segname, "__TEXT"))
				size = s->vmsize;
		}
		p += c->cmdsize;
	}
	memcpy(record + 24, &size, 8);
	return found;
}
static void image_event(const struct mach_header *header, bool load)
{
	if (in_cache(header) || !atomic_load(&ready))
		return;
	uint8_t record[32];
	if (!image_record(header, record))
		return;
	Dl_info info = {0};
	if (!dladdr(header, &info) || !info.dli_fname)
		return;
	struct iovec iov[] = {{record, 32}, {(void *)info.dli_fname, strlen(info.dli_fname) + 1}};
	finch_trace_send(3, UINT64_C(0x105) | ((uint64_t)(load ? 1 : 2) << 32),
	    mach_continuous_time(), iov, 32 + iov[1].iov_len, 0, 0);
}
static void image_added(const struct mach_header *h, intptr_t slide)
{
	(void)slide;
	image_event(h, true);
}
static void image_removed(const struct mach_header *h, intptr_t slide)
{
	(void)slide;
	image_event(h, false);
}
void finch_trace_metadata_init(void *memory, size_t size)
{
	if (size != 2048)
		abort();
	memset(memory, 0, size);
	uint8_t *p = memory;
	struct trace_unique_process info = {0};
	if (proc_pidinfo(getpid(), 17, 0, &info, sizeof(info)) == sizeof(info))
		memcpy(p + 8, info.uuid, 16);
	_dyld_get_shared_cache_uuid(p + 24);
	const char *path = _dyld_get_image_name(0);
	if (!path)
		path = getprogname();
	strlcpy((char *)p + 41, path ? path : "", 1024);
	uint16_t length = (uint16_t)((strlen((char *)p + 41) & ~1u) + 2);
	memcpy(p + 2, &length, 2);
	memcpy(p + 4, &length, 2);
	const char *limit = getenv("OSLogRateLimit");
	if (limit) {
		char *end;
		long n = strtol(limit, &end, 10);
		if (end != limit && !*end && n >= INT16_MIN && n <= INT16_MAX) {
			int16_t v = n;
			memcpy(p + 6, &v, 2);
			p[40] = 1;
		}
	}
	process_metadata = p;
}
void finch_trace_register_log(struct finch_log *l)
{
	if (!l || !l->names || !atomic_load(&ready))
		return;
	size_t size = 0;
	uint8_t *metadata;
	if (client_type == 2) {
		metadata = process_metadata;
		size = metadata ? 2048 : 0;
	} else
		metadata = voucher_activity_get_metadata_buffer(&size);
	bool stored = false;
	pthread_mutex_lock(&metadata_lock);
	for (struct registered_log *r = registered_logs; r; r = r->next)
		if (r->log == l) {
			pthread_mutex_unlock(&metadata_lock);
			return;
		}
	struct registered_log *r = calloc(1, sizeof(*r));
	if (!r) {
		pthread_mutex_unlock(&metadata_lock);
		return;
	}
	r->log = l;
	r->next = registered_logs;
	registered_logs = r;
	size_t n = 4 + l->names->subsystem_size + l->names->category_size;
	if (metadata && size >= 41) {
		uint16_t used;
		memcpy(&used, metadata + 4, 2);
		size_t next = used + n + (n & 1);
		if (next < size - 41 && next <= UINT16_MAX) {
			memcpy(metadata + 41 + used, l->names, n);
			uint16_t v = next;
			memcpy(metadata + 4, &v, 2);
			stored = true;
		}
	}
	pthread_mutex_unlock(&metadata_lock);
	if (!stored) {
		struct iovec iov = {l->names, n};
		finch_trace_send(3, UINT64_C(0x205) | ((uint64_t)l->names->id << 32),
		    mach_continuous_time(), &iov, n, 0, 0);
	}
}
static void reconnect_add(
    struct finch_trace_blob *b, uint32_t type, const void *record, size_t length, const char *path)
{
	uint32_t n = (uint32_t)(length + (path ? strlen(path) + 1 : 0)), head[2] = {type, n};
	uint64_t zero = 0;
	finch_trace_blob_append(b, head, 8);
	finch_trace_blob_append(b, record, length);
	if (path)
		finch_trace_blob_append(b, path, strlen(path) + 1);
	if (n & 7)
		finch_trace_blob_append(b, &zero, 8 - (n & 7));
}
static kern_return_t reconnect_info(mach_vm_address_t *address, mach_vm_size_t *size)
{
	*address = 0;
	*size = 0;
	struct finch_trace_blob b = {.maximum = 1048576, .binary = 1};
	uint32_t count = _dyld_image_count();
	for (uint32_t i = 0; i < count; i++) {
		const struct mach_header *h = _dyld_get_image_header(i);
		if (!h || h->filetype == MH_EXECUTE || in_cache(h))
			continue;
		uint8_t record[32];
		const char *path = _dyld_get_image_name(i);
		if (path && image_record(h, record))
			reconnect_add(&b, 3, record, 32, path);
	}
	pthread_mutex_lock(&metadata_lock);
	for (struct registered_log *r = registered_logs; r; r = r->next) {
		struct finch_log_names *n = r->log->names;
		reconnect_add(&b, 2, n, 4 + n->subsystem_size + n->category_size, NULL);
	}
	pthread_mutex_unlock(&metadata_lock);
	if (!b.length) {
		if (b.flags & 1)
			free(b.data);
		return KERN_SUCCESS;
	}
	*size = (b.length + vm_page_mask) & ~(mach_vm_size_t)vm_page_mask;
	kern_return_t result =
	    mach_vm_allocate(mach_task_self(), address, *size, VM_FLAGS_ANYWHERE);
	if (result == KERN_SUCCESS)
		memcpy((void *)*address, b.data, b.length);
	if (b.flags & 1)
		free(b.data);
	return result;
}
extern mach_msg_header_t *dispatch_mach_msg_get_msg(void *, size_t *);
extern void finch_trace_state_request(uint64_t, const void *, uint8_t, const void *)
    __attribute__((weak_import));
static void debug_channel(void *context, long reason, void *message, int error)
{
	(void)context;
	(void)error;
	if (reason != 2)
		return;
	size_t size = 0;
	mach_msg_header_t *m = dispatch_mach_msg_get_msg(message, &size);
	if (!m)
		return;
	if (m->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
		mach_msg_destroy(m);
		return;
	}
	if (m->msgh_id == 50001 && m->msgh_size == 40) {
		uint64_t aid;
		memcpy(&aid, (char *)m + 32, 8);
		uint32_t hints[6] = {1, 0, 0, 0, 3, 1};
		if (finch_trace_state_request)
			finch_trace_state_request(aid, hints, 14, NULL);
		return;
	}
	if (m->msgh_id == 50000 && m->msgh_size == 44) {
		uint32_t mode;
		memcpy(&mode, (char *)m + 32, 4);
		os_trace_set_mode(mode);
		return;
	}
	if (m->msgh_id == 50002 && m->msgh_size == 24 && MACH_PORT_VALID(m->msgh_remote_port)) {
		struct {
			mach_msg_header_t header;
			NDR_record_t ndr;
			int32_t result;
			uint32_t mode;
			uint64_t reserved;
		} reply = {0};
		reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
		reply.header.msgh_size = sizeof(reply);
		reply.header.msgh_remote_port = m->msgh_remote_port;
		reply.header.msgh_id = 50102;
		reply.ndr = NDR_record;
		reply.mode = os_trace_get_mode();
		mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply), 0, MACH_PORT_NULL, 0,
		    MACH_PORT_NULL);
		m->msgh_remote_port = MACH_PORT_NULL;
		return;
	}
	mach_msg_destroy(m);
}
extern void *xpc_pipe_create(const char *, uint64_t);
extern int xpc_pipe_simpleroutine(void *, void *);
extern int xpc_pipe_routine(void *, xpc_object_t, xpc_object_t *);
void finch_trace_state_send(void *dictionary)
{
	for (unsigned retry = 0; retry < 2; retry++) {
		void *pipe = xpc_pipe_create("com.apple.logd.events", 6);
		if (!pipe)
			return;
		int result = xpc_pipe_simpleroutine(pipe, dictionary);
		xpc_release(pipe);
		if (result != EPIPE)
			return;
	}
}
static const struct trace_hooks hooks = {5, finch_trace_logd_port, debug_channel, reconnect_info,
    finch_trace_metadata_init, finch_trace_quarantine};
API void _libtrace_init(void)
{
	const char *client = getenv("OSLogClientType");
	if (client) {
		long n = strtol(client, NULL, 10);
		if (n >= 0 && n <= 2 && errno != ERANGE && !(n == 0 && errno == EINVAL))
			client_type = (uint8_t)n;
	}
	cache_base = (uintptr_t)_dyld_get_shared_cache_range(&cache_size);
	mach_port_options_t options = {.flags = 0x31};
	mach_port_t port = MACH_PORT_NULL;
	if (mach_port_construct(mach_task_self(), &options, 0x71b75ace, &port) == KERN_SUCCESS)
		task_set_special_port(mach_task_self(), 10, port);
	if (client_type != 2)
		voucher_activity_initialize_4libtrace(&hooks);
	atomic_store_explicit(&ready, true, memory_order_release);
	_dyld_register_func_for_add_image(image_added);
	_dyld_register_func_for_remove_image(image_removed);
}
API void _libtrace_fork_child(void)
{
	metadata_lock = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
	registered_logs = NULL;
	process_metadata = NULL;
	finch_trace_mode_fork_child();
	finch_trace_stream_fork_child();
}
/* The record prefix carries a call-site offset, optional image UUID and the
 * subsystem/category ID. The format offset occupies the upper identifier bits. */
struct trace_prefix {
	uint8_t bytes[40];
	size_t length;
	uint16_t flags;
	uintptr_t base;
};
static struct trace_prefix prefix_for(struct finch_log *l, const void *image, const void *pc)
{
	struct trace_prefix out = {0};
	Dl_info info = {0};
	uintptr_t address = (uintptr_t)ptrauth_strip(pc, ptrauth_key_return_address);
	if (!image && dladdr((const void *)address, &info))
		image = info.dli_fbase;
	uint8_t record[32];
	uint64_t offset = address;
	if (image && in_cache(image)) {
		out.base = cache_base;
		offset = address - cache_base;
		out.flags = offset >> 32 ? 12 : 4;
		out.length = offset >> 32 ? 6 : 4;
		memcpy(out.bytes, &offset, out.length);
	} else if (image && ((const struct mach_header *)image)->filetype == MH_EXECUTE) {
		out.base = (uintptr_t)image;
		offset = address - out.base;
		out.flags = 2;
		out.length = 4;
		memcpy(out.bytes, &offset, 4);
	} else if (image && image_record(image, record)) {
		out.base = (uintptr_t)image;
		offset = address - out.base;
		out.flags = 10;
		out.length = 20;
		memcpy(out.bytes, &offset, 4);
		memcpy(out.bytes + 4, record, 16);
	} else {
		out.flags = 8;
		out.length = 6;
		memcpy(out.bytes, &offset, 6);
	}
	if (l && l->names) {
		finch_trace_register_log(l);
		out.flags |= 0x200;
		memcpy(out.bytes + out.length, &l->names->id, 2);
		out.length += 2;
	}
	return out;
}
static _Atomic uint32_t next_oversize = 1;
static size_t command_size(const uint8_t *wire, size_t n)
{
	if (n < 2)
		return n;
	size_t offset = 2;
	for (unsigned i = 0; i < wire[1]; i++) {
		if (offset + 2 > n || wire[offset + 1] > n - offset - 2)
			return n;
		offset += 2 + wire[offset + 1];
	}
	return offset;
}
static void oversize_send(struct finch_log *l, uint8_t stream, uint32_t message_id, uint64_t stamp,
    const uint8_t *wire, size_t size)
{
	xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
	if (!request)
		return;
	uint8_t uuid[16] = {0};
	_dyld_get_shared_cache_uuid(uuid);
	xpc_dictionary_set_uint64(request, "operation", 3);
	xpc_dictionary_set_uuid(request, "dsc_uuid", uuid);
	xpc_dictionary_set_uint64(request, "stream_id", stream);
	xpc_dictionary_set_uint64(request, "message_id", message_id);
	xpc_dictionary_set_uint64(request, "ts", stamp);
	size_t commands = command_size(wire, size);
	xpc_dictionary_set_data(request, "commands", wire, commands);
	xpc_dictionary_set_data(request, "pubdata", wire + commands, size - commands);
	xpc_dictionary_set_data(request, "privdata", NULL, 0);
	if (l && l->names)
		xpc_dictionary_set_data(request, "subsystem", l->names,
		    4 + l->names->subsystem_size + l->names->category_size);
	for (unsigned retry = 0; retry < 2; retry++) {
		void *pipe = xpc_pipe_create("com.apple.logd.events", 6);
		if (!pipe)
			break;
		xpc_object_t reply = NULL;
		int result = xpc_pipe_routine(pipe, request, &reply);
		if (reply)
			xpc_release(reply);
		xpc_release(pipe);
		if (result != EPIPE)
			break;
	}
	xpc_release(request);
}
static void send_packet(struct finch_log *l, uint8_t stream, uint64_t identifier,
    struct trace_prefix *prefix, const uint8_t *wire, size_t size, uint32_t flags)
{
	uint64_t stamp = mach_continuous_time();
	struct iovec iov[2] = {{prefix->bytes, prefix->length}, {(void *)wire, size}};
	if (prefix->length + size <= 4000) {
		finch_trace_send(stream, identifier, stamp, iov, prefix->length + size, 0, flags);
		return;
	}
	uint32_t message_id = atomic_fetch_add(&next_oversize, 1);
	memcpy(prefix->bytes + prefix->length, &message_id, 4);
	prefix->length += 4;
	identifier |= UINT64_C(0x800) << 16;
	oversize_send(l, stream, message_id, stamp, wire, size);
	iov[0].iov_len = prefix->length;
	finch_trace_send(stream, identifier, stamp, iov, prefix->length, 0, flags);
}
void finch_trace_log_send(struct finch_log *l, uint8_t type, const struct finch_log_pack *p,
    const uint8_t *data, size_t size, bool unreliable)
{
	if (!atomic_load(&ready) || !p)
		return;
	struct trace_prefix prefix = prefix_for(l, p->image, p->pc);
	struct finch_log_wire wire = {0};
	if (finch_log_flatten(data, size, p->error, &wire))
		return;
	uint64_t format_offset = p->format ? (uintptr_t)p->format - prefix.base : 0;
	uint32_t code = (uint32_t)format_offset;
	char *dynamic = NULL;
	Dl_info format_info = {0};
	bool literal = p->format && prefix.base && dladdr(p->format, &format_info) &&
	    ((uintptr_t)format_info.dli_fbase == prefix.base || in_cache(format_info.dli_fbase));
	if (!literal) {
		dynamic =
		    finch_log_compose(p->format ? p->format : "", data, size, p->error, NULL, 0);
		if (!dynamic) {
			free(wire.public_data);
			return;
		}
		free(wire.public_data);
		size_t n = strlen(dynamic) + 1;
		if (n > 65535)
			n = 65535;
		wire.public_size = n + 8;
		wire.public_data = calloc(1, wire.public_size);
		if (!wire.public_data) {
			free(dynamic);
			return;
		}
		uint8_t header[8] = {2, 1, 0x22, 4, 0, 0, (uint8_t)n, (uint8_t)(n >> 8)};
		memcpy(wire.public_data, header, 8);
		memcpy(wire.public_data + 8, dynamic, n);
		wire.public_data[wire.public_size - 1] = 0;
		code = 0x80000000;
	}
	if (literal && format_offset >> 31) {
		uint16_t high = (uint16_t)(format_offset >>
		    31); /* Large format offsets precede the subsystem ID. */
		size_t at = prefix.length - ((prefix.flags & 0x200) ? 2 : 0);
		memmove(prefix.bytes + at + 2, prefix.bytes + at, prefix.length - at);
		memcpy(prefix.bytes + at, &high, 2);
		prefix.length += 2;
		prefix.flags |= 0x20;
		code &= 0x7fffffff;
	}
	uint8_t stream = type == 1 || type == 2 ? 2 : 0;
	uint8_t name_space = 4;
	if (p->reserved[1]) {
		name_space = 6;
		stream = 2;
		uint64_t id = p->reserved[1];
		memcpy(prefix.bytes + prefix.length, &id, 8);
		prefix.length += 8;
		if (p->reserved[0]) {
			uint32_t name = (uint32_t)(p->reserved[0] - prefix.base);
			memcpy(prefix.bytes + prefix.length, &name, 4);
			prefix.length += 4;
			prefix.flags |= 0x8000;
		}
	}
	uint64_t identifier = name_space | ((uint64_t)type << 8) | ((uint64_t)prefix.flags << 16) |
	    ((uint64_t)code << 32);
	send_packet(
	    l, stream, identifier, &prefix, wire.public_data, wire.public_size, unreliable ? 1 : 0);
	free(dynamic);
	free(wire.public_data);
}
void finch_trace_metric_send(struct finch_log *l, uint8_t type, const void *image, const void *pc,
    uint64_t value, const void *payload, size_t size)
{
	if (!atomic_load(&ready))
		return;
	struct trace_prefix prefix = prefix_for(l, image, pc);
	memcpy(prefix.bytes + prefix.length, &value, 8);
	prefix.length += 8;
	uint64_t id = 8 | ((uint64_t)type << 8) | ((uint64_t)prefix.flags << 16);
	send_packet(l, 7, id, &prefix, payload, size, 0);
}

extern bool finch_trace_lazy_initialized(void);
extern int _dispatch_is_multithreaded(void);
API void os_log_set_client_type(uint8_t type)
{
	if (pthread_is_threaded_np() || _dispatch_is_multithreaded() ||
	    finch_trace_lazy_initialized())
		abort();
	client_type = type;
}

void finch_trace_useraction(const void *image, const char *name, const void *pc)
{
	if (!atomic_load(&ready) || (os_trace_get_mode() & 0x500))
		return;
	struct trace_prefix prefix = prefix_for(NULL, image, pc);
	uint64_t offset = name ? (uintptr_t)name - prefix.base : 0;
	uint32_t code = offset & 0x7fffffff;
	if (offset >> 31) {
		uint16_t high = offset >> 31;
		memcpy(prefix.bytes + prefix.length, &high, 2);
		prefix.length += 2;
		prefix.flags |= 0x20;
	}
	struct iovec iov = {prefix.bytes, prefix.length};
	uint64_t id = 0x302 | ((uint64_t)prefix.flags << 16) | ((uint64_t)code << 32);
	finch_trace_send(0, id, mach_continuous_time(), &iov, prefix.length, 0, 0);
}

/* Older os_trace calls carry raw values followed by one size byte per value
 * and a final value count. Preserve that trailer when a message is shortened. */
API void _os_trace_with_buffer(void *image, const char *format, uint8_t type, const void *buffer,
    size_t size, void (^payload)(xpc_object_t))
{
	(void)payload;
	if (!atomic_load(&ready))
		return;
	uint32_t mode = os_trace_get_mode();
	if (mode & 0x500)
		return;
	extern uint64_t voucher_get_activity_id(void *, uint64_t *);
	uint64_t activity = voucher_get_activity_id((void *)-3, NULL);
	uint8_t log_type = 0;
	if (type == 2) {
		if (!(mode & 2) && !(activity & (UINT64_C(2) << 56)))
			return;
		log_type = 2;
	} else if (type == 4) {
		if (!(mode & 3) && !(activity & (UINT64_C(3) << 56)))
			return;
		log_type = 1;
	} else if (type == 0x41)
		log_type = 16;
	else if (type == 0xc1)
		log_type = 17;
	struct trace_prefix prefix = prefix_for(NULL, image, __builtin_return_address(0));
	uint64_t offset = format ? (uintptr_t)format - prefix.base : 0;
	uint32_t code = offset & 0x7fffffff;
	if (offset >> 31) {
		uint16_t high = offset >> 31;
		memcpy(prefix.bytes + prefix.length, &high, 2);
		prefix.length += 2;
		prefix.flags |= 0x20;
	}
	const uint8_t *data = buffer;
	uint8_t shortened[1024];
	if (size > 1023) {
		size_t count = data[size - 1], values = 0, kept = 0;
		if (count >= size)
			return;
		const uint8_t *lengths = data + size - 1 - count;
		while (kept < count) {
			size_t next = values + (lengths[kept] & 63);
			if (next + kept + 2 > sizeof(shortened))
				break;
			values = next;
			kept++;
		}
		if (values > size - count - 1)
			return;
		memcpy(shortened, data, values);
		memcpy(shortened + values, lengths, kept);
		shortened[values + kept] = (uint8_t)kept;
		data = shortened;
		size = values + kept + 1;
	}
	uint64_t id =
	    3 | ((uint64_t)log_type << 8) | ((uint64_t)prefix.flags << 16) | ((uint64_t)code << 32);
	struct iovec iov[2] = {{prefix.bytes, prefix.length}, {(void *)data, size}};
	finch_trace_send(2, id, mach_continuous_time(), iov, prefix.length + size, 0, 0);
}
