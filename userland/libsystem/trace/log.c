/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "fault.h"
#include "internal.h"
#include "transport.h"
#include "preferences.h"
#include "mode.h"
#include "diagnostic_stream.h"
#include <Block.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
extern const char log_class[] __asm__("_OBJC_CLASS_$_OS_os_log");
extern struct finch_log *finch_log_allocate(void);
API struct finch_log _os_log_default = {
    .isa = log_class, .refs = INT32_MAX, .xrefs = INT32_MAX, .options = UINT64_C(0x45000000000000)};
API struct finch_log _os_log_disabled = {.isa = log_class, .refs = INT32_MAX, .xrefs = INT32_MAX};
static pthread_mutex_t logs_lock = PTHREAD_MUTEX_INITIALIZER;
static struct finch_log *logs;
static uint16_t next_log_id = 1;
API struct finch_log _os_log_debug = {
    .isa = log_class, .refs = INT32_MAX, .xrefs = INT32_MAX, .options = 2};
API struct finch_log _os_log_error = {
    .isa = log_class, .refs = INT32_MAX, .xrefs = INT32_MAX, .options = 16};
API struct finch_log _os_log_fault = {
    .isa = log_class, .refs = INT32_MAX, .xrefs = INT32_MAX, .options = 17};
typedef void (^log_hook)(uint8_t, const struct finch_log_message *);
static log_hook hook;
static pthread_mutex_t hook_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t hook_level = 0;
static uint64_t hook_params;
static _Thread_local bool inside_hook, unreliable;
static void *test_callback, *fault_callback, *nscf_formatter;
static unsigned rank(uint8_t t)
{
	switch (t) {
	case 2:
		return 0;
	case 1:
		return 1;
	case 0:
		return 2;
	case 16:
		return 3;
	case 17:
		return 4;
	default:
		return 2;
	}
}
API int os_log_compare_enablement(uint8_t a, uint8_t b)
{
	return (int)rank(a) - (int)rank(b);
}
API struct finch_log *os_log_create(const char *subsystem, const char *category)
{
	if (os_trace_get_mode() & 0x100)
		return &_os_log_disabled;
	if (!subsystem || !category)
		return &_os_log_disabled;
	uint8_t sn = (uint8_t)(strlen(subsystem) + 1), cn = (uint8_t)(strlen(category) + 1);
	size_t size = sizeof(struct finch_log_names) + sn + cn;
	struct finch_log_names *n = calloc(1, size);
	if (!n)
		return &_os_log_disabled;
	n->subsystem_size = sn;
	n->category_size = cn;
	if (sn)
		strlcpy(n->names, subsystem, sn);
	if (cn)
		strlcpy(n->names + sn, category, cn);
	pthread_mutex_lock(&logs_lock);
	for (struct finch_log *l = logs; l; l = l->next)
		if (l->names->subsystem_size == sn && l->names->category_size == cn &&
		    !memcmp(l->names->names, n->names, (size_t)sn + cn)) {
			pthread_mutex_unlock(&logs_lock);
			free(n);
			return l;
		}
	struct finch_log *l = finch_log_allocate();
	if (!l) {
		pthread_mutex_unlock(&logs_lock);
		free(n);
		return &_os_log_disabled;
	}
	l->refs = l->xrefs = INT32_MAX;
	n->id = next_log_id++;
	l->names = n;
	l->options = UINT64_C(0x0445000000000000);
	l->next = logs;
	logs = l;
	pthread_mutex_unlock(&logs_lock);
	finch_trace_preferences_refresh(l);
	return l;
}
API struct finch_log *_os_log_create(const void *image, const char *s, const char *c)
{
	(void)image;
	return os_log_create(s, c);
}
API void _os_log_release(struct finch_log *l)
{
	(void)l;
}
API bool os_log_type_enabled(struct finch_log *l, uint8_t type)
{
	uint32_t mode = os_trace_get_mode();
	if (!l || l == &_os_log_disabled || (mode & 0x100))
		return false;
	pthread_mutex_lock(&hook_lock);
	bool have_hook = hook != NULL, wanted = have_hook && rank(type) >= rank(hook_level);
	pthread_mutex_unlock(&hook_lock);
	if ((mode & 0x400) && !have_hook)
		return false;
	if (wanted)
		return true;
	if (finch_trace_stream_enabled(4, type, l))
		return true;
	if (l->names &&
	    __atomic_load_n(&l->generation, __ATOMIC_ACQUIRE) != finch_trace_preferences_version())
		finch_trace_preferences_refresh(l);
	unsigned level = (unsigned)(__atomic_load_n(&l->options, __ATOMIC_ACQUIRE) >> 32) & 7;
	if (level == 4)
		return false;
	if (!level)
		level = finch_trace_process_levels() & 3;
	if (!level)
		level = 2;
	if (type == 2)
		return level == 3 || (mode & 2);
	if (type == 1)
		return level >= 2 || (mode & 3);
	return true;
}
API bool os_log_is_enabled(struct finch_log *l)
{
	return os_log_type_enabled(l, 0);
}
API bool os_log_is_debug_enabled(struct finch_log *l)
{
	return os_log_type_enabled(l, 2);
}
API void os_log_set_enabled(struct finch_log *l, bool enabled)
{
	(void)l;
	(void)enabled;
}
API uint8_t os_log_get_type(const void *m)
{
	return ((const uint8_t *)m)[1];
}
API unsigned os_trace_get_type(const void *m)
{
	switch (os_log_get_type(m)) {
	case 0:
		return 1;
	case 1:
		return 4;
	case 2:
		return 2;
	case 16:
		return 0x41;
	case 17:
		return 0xc1;
	default:
		return 0;
	}
}
API const char *os_log_type_get_name(unsigned t)
{
	switch (t) {
	case 0:
		return "Default";
	case 1:
		return "Info";
	case 2:
		return "Debug";
	case 16:
		return "Error";
	case 17:
		return "Fault";
	default:
		abort();
	}
}
API uint32_t os_log_errors_count(struct finch_log *l)
{
	return __atomic_load_n((uint32_t *)((char *)l + 40), __ATOMIC_RELAXED);
}
API uint32_t os_log_faults_count(struct finch_log *l)
{
	return __atomic_load_n((uint32_t *)((char *)l + 44), __ATOMIC_RELAXED);
}
API log_hook os_log_set_hook_with_params(uint8_t level, uint64_t params, log_hook block)
{
	if (!block)
		abort();
	log_hook copied = Block_copy(block);
	pthread_mutex_lock(&hook_lock);
	log_hook old = hook;
	if (!old || rank(level) < rank(hook_level))
		hook_level = level;
	hook_params |= params;
	hook = copied;
	pthread_mutex_unlock(&hook_lock);
	return old;
}
API log_hook os_log_set_hook(uint8_t level, log_hook block)
{
	return os_log_set_hook_with_params(level, 0, block);
}
API void *os_log_set_test_callback(void *p)
{
	return __atomic_exchange_n(&test_callback, p, __ATOMIC_SEQ_CST);
}
API void *os_log_set_fault_callback(void *p)
{
	return p ? __atomic_exchange_n(&fault_callback, p, __ATOMIC_SEQ_CST)
	         : __atomic_load_n(&fault_callback, __ATOMIC_SEQ_CST);
}
API void *_os_log_get_nscf_formatter(void)
{
	return __atomic_load_n(&nscf_formatter, __ATOMIC_SEQ_CST);
}
API void _os_log_set_nscf_formatter(void *p)
{
	__atomic_store_n(&nscf_formatter, p, __ATOMIC_SEQ_CST);
}
API void os_set_logging_unreliable_for_current_thread(bool value)
{
	unreliable = value;
}
API char *os_log_copy_message_string(const struct finch_log_message *m)
{
	return finch_log_compose_wire(
	    m->format, m->data, m->data_size, m->private_data, m->private_size);
}
API char *os_log_copy_decorated_message(uint8_t type, const struct finch_log_message *m)
{
	char *message = os_log_copy_message_string(m);
	if (!message)
		return NULL;
	struct tm tm;
	time_t secs = (time_t)m->seconds;
	char stamp[80], zone[16];
	localtime_r(&secs, &tm);
	strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm);
	strftime(zone, sizeof(zone), "%z", &tm);
	char *out = NULL;
	const char *s = m->subsystem, *c = m->category;
	asprintf(&out, "%s.%06llu%s %s %s[%d:%llx]%s%s%s%s%s %s\n", stamp,
	    (unsigned long long)m->microseconds, zone, os_log_type_get_name(type), getprogname(),
	    getpid(), (unsigned long long)m->thread, s ? "[" : "", s ? s : "", s ? ":" : "",
	    s && c ? c : "", s ? "]" : "", message);
	free(message);
	return out;
}
/* Bytes 1-3 of the options word are the Default, Info and Debug TTLs from the
 * log's preferences; errors and faults use the Default TTL. */
static uint8_t message_ttl(struct finch_log *l, uint8_t type)
{
	uint64_t o = __atomic_load_n(&l->options, __ATOMIC_ACQUIRE);
	unsigned shift = type == 1 ? 16 : type == 2 ? 24 : 8;
	return (uint8_t)(o >> shift);
}
void finch_log_send(struct finch_log *l, uint8_t type, const struct finch_log_pack *p,
    const uint8_t *data, size_t size, bool force)
{
	if (!l)
		l = &_os_log_default;
	if (!force && !os_log_type_enabled(l, type))
		return;
	int err = errno;
	uint32_t before = 1;
	if (type == 16)
		before = __atomic_fetch_add((uint32_t *)((char *)l + 40), 1, __ATOMIC_RELAXED);
	if (type == 17)
		before = __atomic_fetch_add((uint32_t *)((char *)l + 44), 1, __ATOMIC_RELAXED);
	/* Faults (and messages flagged 0x80) collect state dumps under their own activity. */
	struct finch_trace_fault_scope scope = finch_trace_fault_begin(
	    l, type, p, data, size, unreliable, before == 0, message_ttl(l, type));
	pthread_mutex_lock(&hook_lock);
	log_hook callback =
	    hook && !inside_hook && rank(type) >= rank(hook_level) ? Block_copy(hook) : NULL;
	pthread_mutex_unlock(&hook_lock);
	if (callback) {
		struct finch_log_wire wire = {0};
		if (!finch_log_flatten(data, size, p ? p->error : err, &wire)) {
			struct timespec now;
			clock_gettime(CLOCK_REALTIME, &now);
			struct finch_log_message m = {
			    .identifier = 4 | ((uint64_t)type << 8) | UINT64_C(0x20000),
			    .timestamp = mach_continuous_time(),
			    .seconds = (uint64_t)now.tv_sec,
			    .microseconds = (uint64_t)now.tv_nsec / 1000,
			    .format = p ? p->format : "",
			    .data = wire.public_data,
			    .data_size = wire.public_size};
			pthread_threadid_np(NULL, &m.thread);
			if (l->names) {
				m.subsystem = l->names->names;
				m.category = l->names->names + l->names->subsystem_size;
			}
			inside_hook = true;
			callback(type, &m);
			inside_hook = false;
			free(wire.public_data);
		}
		Block_release(callback);
	}
	finch_trace_log_send(l, type, p, data, size, unreliable);
	const char *dt = getenv("OS_ACTIVITY_DT_MODE");
	if (dt && *dt && strcmp(dt, "0")) {
		char *s =
		    finch_log_compose(p ? p->format : "", data, size, p ? p->error : err, NULL, 0);
		if (s) {
			dprintf(STDERR_FILENO, "%s\n", s);
			free(s);
		}
	}
	finch_trace_fault_end(&scope);
	/* After the caller's voucher is back: the fault callback, then the test callback. */
	finch_trace_fault_callbacks(l, type, p, data, size,
	    (finch_trace_message_callback)__atomic_load_n(&fault_callback, __ATOMIC_SEQ_CST),
	    (finch_trace_message_callback)__atomic_load_n(&test_callback, __ATOMIC_SEQ_CST));
	errno = err;
}
API char *_os_log_send_and_compose_impl(uint32_t flags, const char **fmt, char *buffer,
    size_t capacity, void *image, struct finch_log *l, uint8_t type, const char *format,
    uint8_t *data, uint32_t size)
{
	int err = errno;
	if (fmt)
		*fmt = format;
	struct finch_log_pack p = {.image = image,
	    .pc = __builtin_return_address(0),
	    .format = format,
	    .error = (uint16_t)err};
	if (flags & 1)
		finch_log_send(l, type, &p, data, size, false);
	char *out = flags & 2 ? finch_log_compose(format, data, size, err, buffer, capacity) : NULL;
	errno = err;
	return out;
}
API void _os_log_impl(void *image, struct finch_log *l, uint8_t type, const char *format,
    uint8_t *data, uint32_t size)
{
	_os_log_send_and_compose_impl(1, NULL, NULL, 0, image, l, type, format, data, size);
}
#define IMPL(name)                                                                                 \
	API void name(                                                                             \
	    void *i, struct finch_log *l, uint8_t t, const char *f, uint8_t *d, uint32_t n)        \
	{                                                                                          \
		_os_log_impl(i, l, t, f, d, n);                                                    \
	}
IMPL(_os_log_debug_impl)
IMPL(_os_log_error_impl)
IMPL(_os_log_fault_impl) IMPL(_os_log_unreliable_impl) API size_t _os_log_pack_size(size_t n)
{
	return n + 72;
}
API uint8_t *_os_log_pack_fill(
    struct finch_log_pack *p, size_t size, int error, void *image, const char *format)
{
	if (size >= 65536 || size < 72)
		abort();
	memset(p, 0, 68);
	p->image = image;
	p->pc = __builtin_return_address(0);
	p->format = format;
	p->error = (uint16_t)error;
	p->data_size = (uint16_t)(size - 72);
	return p->data;
}
API char *os_log_pack_compose(
    struct finch_log_pack *p, struct finch_log *l, uint8_t t, char *b, size_t n)
{
	(void)l;
	(void)t;
	return finch_log_compose(p->format, p->data, p->data_size, p->error, b, n);
}
API void os_log_pack_send(struct finch_log_pack *p, struct finch_log *l, uint8_t t)
{
	finch_log_send(l, t, p, p->data, p->data_size, false);
}
API char *os_log_pack_send_and_compose(
    struct finch_log_pack *p, struct finch_log *l, uint8_t t, char *b, size_t n)
{
	os_log_pack_send(p, l, t);
	return os_log_pack_compose(p, l, t, b, n);
}
API void os_log_with_args(
    struct finch_log *l, uint8_t type, const char *format, va_list args, void *address)
{
	if (!format || !os_log_type_enabled(l, type))
		return;
	int err = errno;
	size_t n = 0;
	uint8_t *data = finch_log_pack_arguments(format, args, &n);
	if (!data)
		return;
	Dl_info caller = {0}, literal = {0};
	bool stable = address &&
	    dladdr(ptrauth_strip(address, ptrauth_key_return_address), &caller) &&
	    dladdr(format, &literal) && caller.dli_fbase == literal.dli_fbase;
	struct finch_log_pack p = {
	    .image = caller.dli_fbase, .pc = address, .format = format, .error = (uint16_t)err};
	if (stable)
		finch_log_send(l, type, &p, data, n, false);
	else {
		char *text = finch_log_compose(format, data, n, err, NULL, 0);
		if (text) {
			uint8_t buffer[12] = {3, 1, 0x21, 8};
			memcpy(buffer + 4, &text, 8);
			p.format = "%s";
			finch_log_send(l, type, &p, buffer, sizeof(buffer), false);
			free(text);
		}
	}
	free(data);
	errno = err;
}
API void os_log_with_args_4syslog(
    struct finch_log *l, uint8_t type, const char *format, va_list args, void *address)
{
	os_log_with_args(l, type, format, args, address);
}
API void _os_log_internal(void *image, struct finch_log *l, uint8_t type, const char *format, ...)
{
	(void)image;
	va_list args;
	va_start(args, format);
	os_log_with_args(l, type, format, args, __builtin_return_address(0));
	va_end(args);
}
API bool os_log_shim_enabled(void *address)
{
	(void)address;
	return !(os_trace_get_mode() & 0x100);
}
API bool os_log_shim_legacy_logging_enabled(void)
{
	return (os_trace_get_mode() & UINT32_C(0x20000000)) != 0;
}
API void os_log_shim_to_stdout(struct finch_log *l)
{
	if (l == &_os_log_default || l == &_os_log_disabled)
		abort();
	l->options |= UINT64_C(1) << 63;
}
/* The system's default fault callback deliberately has no work to do. */
API void os_log_fault_default_callback(void)
{
}
