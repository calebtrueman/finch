/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "internal.h"
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
extern void *os_retain(void *);
extern void os_release(void *);
extern void *voucher_copy(void);
extern void *voucher_adopt(void *);
extern uint64_t voucher_get_activity_id(void *, uint64_t *);
extern void *voucher_activity_create_with_data_2(
    uint64_t *, void *, unsigned, const void *, size_t, uint32_t);
extern uint64_t voucher_activity_id_allocate(unsigned);
extern uint32_t os_trace_get_mode(void);
extern uint8_t *_os_log_pack_fill(struct finch_log_pack *, size_t, int, void *, const char *);
struct activity_marker {
	void *isa;
	int32_t refs, xrefs;
};
API struct activity_marker _os_activity_none = {NULL, INT32_MAX, INT32_MAX};
API struct activity_marker _os_activity_current = {NULL, INT32_MAX, INT32_MAX};
struct scope {
	uint64_t identifier;
	void *previous;
};
static void *actual(void *a)
{
	return a == &_os_activity_none ? NULL : a == &_os_activity_current ? (void *)-3 : a;
}
API uint64_t os_activity_get_identifier(void *a, uint64_t *parent)
{
	uint64_t id = voucher_get_activity_id(actual(a), parent);
	if (parent)
		*parent &= UINT64_C(0xffffffffffffff);
	return id & UINT64_C(0xffffffffffffff);
}
API void *_os_activity_create(void *image, const char *description, void *parent, unsigned flags)
{
	void *base = actual(parent);
	if (flags & 1)
		base = NULL;
	if (flags & 2) {
		if (flags & 1 || base != (void *)-3)
			abort();
		if (voucher_get_activity_id(base, NULL))
			return voucher_copy();
	}
	uint32_t location = (uint32_t)((uintptr_t)__builtin_return_address(0) - (uintptr_t)image);
	uint64_t trace = UINT64_C(0x20102) |
	    ((uint64_t)(uint32_t)((uintptr_t)description - (uintptr_t)image) << 32);
	uint32_t mode = os_trace_get_mode();
	return voucher_activity_create_with_data_2(
	    &trace, base, mode & 0x10000 ? mode & 255 : 0, &location, sizeof(location), 0);
}
API void os_activity_scope_enter(void *a, struct scope *s)
{
	if (a == &_os_activity_current)
		abort();
	void *v = actual(a);
	if (v)
		os_retain(v);
	s->identifier = voucher_get_activity_id(v, NULL);
	s->previous = voucher_adopt(v);
}
API void os_activity_scope_leave(struct scope *s)
{
	void *v = voucher_adopt(s->previous);
	if (v)
		os_release(v);
	memset(s, 0, sizeof(*s));
}
API void os_activity_apply_f(void *a, void *context, void (*work)(void *))
{
	struct scope s;
	os_activity_scope_enter(a, &s);
	work(context);
	os_activity_scope_leave(&s);
}
API void os_activity_apply(void *a, void (^work)(void))
{
	struct scope s;
	os_activity_scope_enter(a, &s);
	work();
	os_activity_scope_leave(&s);
}
API void _os_activity_initiate_f(
    void *image, const char *description, unsigned flags, void *context, void (*work)(void *))
{
	void *a = _os_activity_create(image, description, &_os_activity_current, flags);
	void *old = voucher_adopt(a);
	work(context);
	void *v = voucher_adopt(old);
	if (v)
		os_release(v);
}
API void _os_activity_initiate(
    void *image, const char *description, unsigned flags, void (^work)(void))
{
	void *a = _os_activity_create(image, description, &_os_activity_current, flags);
	void *old = voucher_adopt(a);
	work();
	void *v = voucher_adopt(old);
	if (v)
		os_release(v);
}
API unsigned os_activity_get_active(uint64_t *out, unsigned *count)
{
	if (!*count)
		return 0;
	uint64_t parent = 0, id = voucher_get_activity_id((void *)-3, &parent);
	out[0] = id;
	if (*count >= 2)
		out[1] = parent;
	unsigned n = (id != 0) + (*count >= 2 && parent != 0);
	*count = n;
	return n;
}
/* These retired APIs also return no results on the host. */
API uint64_t _os_activity_start(void)
{
	return 0;
}
API void os_activity_end(uint64_t id)
{
	(void)id;
}
API int os_activity_diagnostic_for_pid(int pid)
{
	(void)pid;
	return 0;
}
API void os_activity_iterate_processes(void *context)
{
	(void)context;
}
API void os_activity_iterate_activities(void *context)
{
	(void)context;
}
API void os_activity_iterate_breadcrumbs(void *context)
{
	(void)context;
}
API void os_activity_iterate_messages(void *context)
{
	(void)context;
}
API void *os_activity_for_task_thread(void *task, void *thread)
{
	(void)task;
	(void)thread;
	return NULL;
}
API void *os_activity_for_thread(void *thread)
{
	(void)thread;
	return NULL;
}
API void *os_activity_messages_for_thread(void *thread)
{
	(void)thread;
	return NULL;
}

static _Atomic uint64_t next_signpost = 1;
static uintptr_t pointer_salt;
static pthread_once_t salt_once = PTHREAD_ONCE_INIT;
static void make_salt(void)
{
	arc4random_buf(&pointer_salt, sizeof(pointer_salt));
	pointer_salt &= ~((uintptr_t)getpagesize() - 1);
}
API bool os_signpost_enabled(struct finch_log *l)
{
	return l && l != &_os_log_disabled && !(os_trace_get_mode() & 0x500) &&
	    ((l->options >> 50) & 1);
}
API uint64_t os_signpost_id_generate(struct finch_log *l)
{
	if (!os_signpost_enabled(l))
		return 0;
	if (((l->options >> 32) & 0x18000) == 0x18000)
		return voucher_activity_id_allocate(0);
	return atomic_fetch_add(&next_signpost, 1);
}
API uint64_t os_signpost_id_make_with_pointer(struct finch_log *l, const void *p)
{
	if (!os_signpost_enabled(l))
		return 0;
	if (((l->options >> 32) & 0x18000) == 0x18000)
		return UINT64_MAX;
	pthread_once(&salt_once, make_salt);
	return pointer_salt + (uintptr_t)p;
}
static void *introspection_hook;
API void *os_signpost_set_introspection_hook_4Perf(void *p)
{
	return __atomic_exchange_n(&introspection_hook, p, __ATOMIC_SEQ_CST);
}
API uint8_t *_os_signpost_pack_fill(struct finch_log_pack *p, size_t size, int error, void *image,
    const char *format, const char *name, uint64_t id)
{
	if (!format)
		format = name + strlen(name);
	uint8_t *out = _os_log_pack_fill(p, size, error, image, format);
	p->reserved[0] = (uintptr_t)name;
	p->reserved[1] = id;
	return out;
}
API void _os_signpost_pack_send(struct finch_log_pack *p, struct finch_log *l, uint8_t t)
{
	if (os_signpost_enabled(l))
		finch_log_send(l, t, p, p->data, p->data_size, true);
}
API void _os_signpost_emit_with_name_impl(void *image, struct finch_log *l, uint8_t type,
    uint64_t id, const char *name, const char *format, uint8_t *data, uint32_t size)
{
	struct finch_log_pack p = {.image = image,
	    .pc = __builtin_return_address(0),
	    .format = format ? format : "",
	    .reserved = {(uintptr_t)name, id}};
	if (os_signpost_enabled(l))
		finch_log_send(l, type, &p, data, size, true);
}
API void _os_signpost_emit_unreliably_with_name_impl(void *i, struct finch_log *l, uint8_t t,
    uint64_t id, const char *n, const char *f, uint8_t *d, uint32_t size)
{
	_os_signpost_emit_with_name_impl(i, l, t, id, n, f, d, size);
}
API void _os_signpost_emit_impl(
    void *i, struct finch_log *l, uint8_t t, uint64_t id, const char *f, uint8_t *d, uint32_t n)
{
	_os_signpost_emit_with_name_impl(i, l, t, id, NULL, f, d, n);
}

extern void finch_trace_useraction(const void *, const char *, const void *);
API void _os_activity_label_useraction(void *image, const char *name)
{
	finch_trace_useraction(image, name, __builtin_return_address(0));
}
API void _os_activity_set_breadcrumb(void *image, const char *name)
{
	finch_trace_useraction(image, name, __builtin_return_address(0));
}
