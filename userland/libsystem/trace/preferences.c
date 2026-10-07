/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "preferences.h"
#include <dispatch/dispatch.h>
#include <notify.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
extern void *_os_trace_read_file_at(int, const char *, size_t, size_t *);
extern xpc_object_t xpc_create_from_plist(const void *, size_t);
extern xpc_object_t xpc_bundle_create_main(void);
extern xpc_object_t xpc_bundle_get_info_dictionary(xpc_object_t);
extern void *voucher_activity_get_logging_preferences(size_t *);
extern uint64_t voucher_get_activity_id(void *, uint64_t *);
extern uint32_t os_trace_get_mode(void);
extern uint64_t os_simple_hash(const void *, size_t);
extern bool os_variant_check(const char *, const char *);
extern bool os_variant_is_recovery(const char *);
extern bool os_variant_has_internal_diagnostics(const char *);
static uint32_t diagnostic_flags(void)
{
	return *(const volatile uint32_t *)(uintptr_t)UINT64_C(0xfffffc104);
}
static _Atomic uint32_t preference_version;
static dispatch_once_t watcher_once, bundle_once;
static xpc_object_t bundle_preferences;
static void watcher_init(void *unused)
{
	(void)unused;
	int token;
	dispatch_queue_t q =
	    dispatch_queue_create("finch.trace.preferences", DISPATCH_QUEUE_SERIAL);
	notify_register_dispatch(
	    "com.apple.system.logging.prefschanged", &token, q, ^(int changed) {
	      (void)changed;
	      atomic_fetch_add_explicit(&preference_version, 1, memory_order_relaxed);
	    });
	dispatch_release(q);
}
uint32_t finch_trace_preferences_version(void)
{
	dispatch_once_f(&watcher_once, NULL, watcher_init);
	return atomic_load_explicit(&preference_version, memory_order_relaxed);
}
API uint32_t _os_trace_prefs_latest_version_4tests(void)
{
	return finch_trace_preferences_version();
}
API bool _os_trace_mode_match_4tests(uint32_t mask)
{
	(void)finch_trace_preferences_version();
	if ((os_trace_get_mode() | diagnostic_flags()) & mask)
		return true;
	return (mask & 255) && ((voucher_get_activity_id((void *)(intptr_t)-3, NULL) >> 56) & mask);
}
API bool _os_trace_is_development_build(void)
{
	uint32_t f = diagnostic_flags();
	return !(f & UINT32_C(0x80000000)) && (f & UINT32_C(0x10000000));
}
API uint32_t _os_trace_commpage_compute(
    uint32_t current, int recovery, int logging, int internal, int full)
{
	uint32_t base = current & UINT32_C(0x88000000);
	if (recovery) {
		uint32_t extra = base | UINT32_C(0x60000000);
		if (!(full & 1))
			return ((int32_t)current >= 0 && (internal & 1))
			    ? base | UINT32_C(0x71000000)
			    : extra;
		base = extra;
	}
	uint32_t result = current | base | ((uint32_t)logging ^ 1);
	result = internal ? result | UINT32_C(0x11000001) : result & ~UINT32_C(0x11000000);
	return current & UINT32_C(0x80000000) ? base | 1 : result;
}
API bool _os_trace_atm_diagnostic_config(uint32_t *out)
{
	char bootargs[1024];
	size_t size = sizeof(bootargs);
	if (sysctlbyname("kern.bootargs", bootargs, &size, NULL, 0))
		return false;
	bootargs[sizeof(bootargs) - 1] = 0;
	char *p = strcasestr(bootargs, "atm_diagnostic_config=");
	if (!p)
		return false;
	char *end;
	unsigned long value = strtoul(p + 22, &end, 16);
	if (*end && !isspace((unsigned char)*end))
		return false;
	*out = value;
	return true;
}
API kern_return_t _os_trace_set_diagnostic_flags(uint32_t flags)
{
	mach_port_t host = mach_host_self();
	kern_return_t result = host_set_atm_diagnostic_flag(host, flags);
	mach_port_deallocate(mach_task_self(), host);
	return result;
}
API void _os_trace_update_with_datavolume_4launchd(void)
{
	const char *domain = "com.apple.libtrace";
	bool full = os_variant_check(domain, "HasFullLogging");
	uint32_t current = diagnostic_flags();
	bool recovery = os_variant_is_recovery(domain),
	     internal = os_variant_has_internal_diagnostics(domain);
	uint32_t flags = _os_trace_commpage_compute(current, recovery, 0, internal, full);
	if (flags != current)
		_os_trace_set_diagnostic_flags(flags);
}
API xpc_object_t _os_trace_read_plist_at(int dir, const char *path)
{
	size_t n = 0;
	void *bytes = _os_trace_read_file_at(dir, path, 65536, &n);
	if (!bytes)
		return NULL;
	xpc_object_t object = xpc_create_from_plist(bytes, n);
	free(bytes);
	if (object && xpc_get_type(object) != XPC_TYPE_DICTIONARY) {
		xpc_release(object);
		object = NULL;
	}
	return object;
}
static xpc_object_t dict(xpc_object_t object, const char *key)
{
	return object ? xpc_dictionary_get_dictionary(object, key) : NULL;
}
static xpc_object_t value(
    xpc_object_t base, xpc_object_t category, const char *key, xpc_type_t type)
{
	xpc_object_t p = category ? xpc_dictionary_get_value(category, key) : NULL;
	if (p && xpc_get_type(p) == type)
		return p;
	p = base ? xpc_dictionary_get_value(base, key) : NULL;
	return p && xpc_get_type(p) == type ? p : NULL;
}
static unsigned option(xpc_object_t d, const char *key)
{
	const char *s = d ? xpc_dictionary_get_string(d, key) : NULL;
	if (!s)
		return 0;
	if (!strcasecmp(s, "default"))
		return 1;
	if (!strcasecmp(s, "info"))
		return 2;
	if (!strcasecmp(s, "debug"))
		return 3;
	if (!strcasecmp(s, "off") || !strcasecmp(s, "none"))
		return 4;
	return 0;
}
static unsigned selected_option(xpc_object_t base, xpc_object_t category, const char *key)
{
	unsigned n = option(category, key);
	return n ? n : option(base, key);
}
static unsigned privacy(xpc_object_t p)
{
	const char *s = p ? xpc_string_get_string_ptr(p) : NULL;
	if (!s)
		return 0;
	if (!strcasecmp(s, "public"))
		return 1;
	if (!strcasecmp(s, "private"))
		return 2;
	if (!strcasecmp(s, "sensitive"))
		return 3;
	return 0;
}
API void _os_log_preferences_compute(
    xpc_object_t prefs, const char *name, struct finch_log_preferences *out)
{
	xpc_object_t base = dict(prefs, "DEFAULT-OPTIONS"),
	             category = name ? dict(prefs, name) : NULL, base_level = dict(base, "Level"),
	             level = dict(category, "Level"), base_ttl = dict(base, "TTL"),
	             ttl = dict(category, "TTL");
	out->reserved = 0;
	const char *keys[] = {"Default", "Info", "Debug"};
	uint8_t *times = &out->ttl_default;
	for (unsigned i = 0; i < 3; i++) {
		xpc_object_t p = value(base_ttl, ttl, keys[i], XPC_TYPE_INT64);
		times[i] = p ? xpc_int64_get_value(p) : 0;
	}
	uint32_t bits = selected_option(base_level, level, "Enable") |
	    (selected_option(base_level, level, "Persist") << 3) |
	    (selected_option(base, category, "Install-Log-Persist-Level") << 6);
	const char *boolkeys[] = {"Symptoms", "Enable-Oversize-Messages",
	    "Supports-Signpost-Introspection", "Signpost-Persisted",
	    "Enable-Fault-Crashlog-Excerpts"};
	const unsigned masks[] = {0x200, 0x400, 0x20000, 0x80000, 0x2000000};
	for (unsigned i = 0; i < 5; i++) {
		xpc_object_t p = value(base, category, boolkeys[i], XPC_TYPE_BOOL);
		if (p && xpc_bool_get_value(p))
			bits |= masks[i];
	}
	bits |= privacy(value(base, category, "Default-Privacy-Setting", XPC_TYPE_STRING)) << 11;
	unsigned private_level =
	    privacy(value(base, category, "Privacy-Enable-Level", XPC_TYPE_STRING));
	if (!private_level) {
		xpc_object_t p = value(base, category, "Enable-Private-Data", XPC_TYPE_BOOL);
		if (p && xpc_bool_get_value(p))
			private_level = 2;
	}
	bits |= private_level << 13;
	xpc_object_t p = value(base, category, "Signpost-Scope", XPC_TYPE_STRING);
	const char *s = p ? xpc_string_get_string_ptr(p) : NULL;
	bits |= s && !strcasecmp(s, "thread") ? 0x8000
	    : s && !strcasecmp(s, "system")   ? 0x18000
	                                      : 0x10000;
	p = value(base, category, "Signpost-Enabled", XPC_TYPE_BOOL);
	if (p ? xpc_bool_get_value(p)
	      : !name || (strcmp(name, "DynamicTracing") && strcmp(name, "DynamicStackTracing")))
		bits |= 0x40000;
	p = value(base, category, "Signpost-Backtraces-Enabled", XPC_TYPE_BOOL);
	unsigned backtraces =
	    p ? (xpc_bool_get_value(p) ? 1 : 2) : (name && !strcmp(name, "DynamicStackTracing"));
	bits |= backtraces << 20;
	p = value(base, category, "Signpost-Allow-Streaming", XPC_TYPE_BOOL);
	if (!p || xpc_bool_get_value(p))
		bits |= 0x400000;
	p = value(base, category, "Enable-Fault-Crashlogs", XPC_TYPE_STRING);
	s = p ? xpc_string_get_string_ptr(p) : NULL;
	if (s && !strcasecmp(s, "once"))
		bits |= 0x800000;
	else if (s && !strcasecmp(s, "always"))
		bits |= 0x1000000;
	out->options = bits;
}
static void overrides(xpc_object_t target, xpc_object_t source)
{
	if (target == source)
		__builtin_trap();
	if (!source || xpc_get_type(target) != XPC_TYPE_DICTIONARY ||
	    xpc_get_type(source) != XPC_TYPE_DICTIONARY)
		return;
	xpc_dictionary_apply(source, ^bool(const char *key, xpc_object_t incoming) {
	  xpc_object_t old = xpc_dictionary_get_value(target, key);
	  if (old && xpc_get_type(old) == XPC_TYPE_DICTIONARY) {
		  overrides(old, incoming);
		  return true;
	  }
	  if (old && xpc_get_type(incoming) == XPC_TYPE_STRING &&
	      !strcasecmp(xpc_string_get_string_ptr(incoming), "inherit"))
		  return true;
	  xpc_dictionary_set_value(target, key, incoming);
	  return true;
	});
}
static void merge_category(xpc_object_t target, xpc_object_t source, const char *category)
{
	xpc_object_t incoming = dict(source, category);
	if (!incoming)
		return;
	xpc_object_t old = dict(target, category);
	if (old)
		overrides(old, incoming);
	else
		xpc_dictionary_set_value(target, category, incoming);
}
API void _os_log_preferences_merge(xpc_object_t target, xpc_object_t source, const char *category)
{
	if (!source)
		return;
	if (category) {
		merge_category(target, source, "DEFAULT-OPTIONS");
		merge_category(target, source, category);
	} else
		xpc_dictionary_apply(source, ^bool(const char *key, xpc_object_t unused) {
		  (void)unused;
		  merge_category(target, source, key);
		  return true;
		});
}
static const char *const roots[] = {"/System/Library/Preferences/Logging",
    "/System/Cryptexes/App/System/Library/Preferences/Logging",
    "/System/Cryptexes/OS/System/Library/Preferences/Logging",
    "/AppleInternal/Library/Preferences/Logging", "/Library/Preferences/Logging"};
static xpc_object_t read_subsystem(unsigned root, const char *name)
{
	char path[1024];
	snprintf(path, sizeof(path), "%s/Subsystems/%s.plist", roots[root], name);
	return _os_trace_read_plist_at(AT_FDCWD, path);
}
static xpc_object_t base_prefs(const char *name, bool cryptex)
{
	xpc_object_t p = NULL;
	if (cryptex) {
		p = read_subsystem(1, name);
		if (!p)
			p = read_subsystem(2, name);
	}
	return p ? p : read_subsystem(0, name);
}
static void add_prefs(xpc_object_t *target, xpc_object_t source, const char *category)
{
	if (!source)
		return;
	if (*target) {
		_os_log_preferences_merge(*target, source, category);
		xpc_release(source);
	} else
		*target = source;
}
API xpc_object_t _os_log_preferences_load_sysprefs(
    const char *name, const char *category, bool cryptex)
{
	xpc_object_t p = base_prefs(name, cryptex);
	if (_os_trace_is_development_build())
		add_prefs(&p, read_subsystem(3, name), category);
	return p;
}
static void bundle_init(void *unused)
{
	(void)unused;
	xpc_object_t bundle = xpc_bundle_create_main();
	if (!bundle)
		return;
	xpc_object_t info = xpc_bundle_get_info_dictionary(bundle);
	xpc_object_t prefs = dict(info, "OSLogPreferences");
	if (prefs)
		bundle_preferences = xpc_retain(prefs);
	xpc_release(bundle);
}
API xpc_object_t _os_log_preferences_load(const char *name, const char *category)
{
	xpc_object_t p = _os_log_preferences_load_sysprefs(name, category, true);
	dispatch_once_f(&bundle_once, NULL, bundle_init);
	xpc_object_t bundled = dict(bundle_preferences, name);
	if (bundled)
		add_prefs(&p, xpc_copy(bundled), category);
	add_prefs(&p, read_subsystem(4, name), category);
	return p;
}
API void *_os_log_preferences_copy_cache(size_t *length)
{
	*length = 0;
	if ((os_trace_get_mode() | diagnostic_flags()) & 0x100)
		return NULL;
	size_t n = 0;
	void *buffer = voucher_activity_get_logging_preferences(&n);
	if (!buffer)
		return NULL;
	uint32_t version = 0;
	if (n >= 4)
		memcpy(&version, buffer, 4);
	void *out = NULL;
	if (version == 6) {
		out = malloc(n);
		if (out) {
			memcpy(out, buffer, n);
			*length = n;
		}
	}
	mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)buffer, n);
	return out;
}
/* All record fields may be unaligned. A bad record ends its sibling list. */
const unsigned char *finch_trace_preferences_find_record(
    const void *data, size_t size, const char *name)
{
	const unsigned char *p = data;
	size_t length = strlen(name);
	uint32_t hash = (uint32_t)os_simple_hash(name, length);
	while (size >= 20) {
		uint32_t total, n, h;
		memcpy(&total, p, 4);
		memcpy(&n, p + 4, 4);
		memcpy(&h, p + 8, 4);
		if (total > size || total < 21 || (uint64_t)n + 21 > total || p[20 + (size_t)n])
			return NULL;
		if (h == hash && n == length && !memcmp(p + 20, name, length))
			return p;
		p += total;
		size -= total;
	}
	return NULL;
}
static void default_signpost(const char *category, struct finch_log_preferences *out)
{
	if (!strcmp(category, "DynamicTracing"))
		out->options &= ~UINT32_C(0x40000);
	else if (!strcmp(category, "DynamicStackTracing"))
		out->options = (out->options & ~UINT32_C(0x340000)) | UINT32_C(0x100000);
}
bool finch_trace_preferences_cached(const void *data, size_t size, const char *subsystem,
    const char *category, struct finch_log_preferences *out)
{
	uint32_t version = 0;
	if (size >= 4)
		memcpy(&version, data, 4);
	if (version != 6)
		return false;
	*out = (struct finch_log_preferences){.options = 0x450000};
	const unsigned char *sub = finch_trace_preferences_find_record(
	    (const unsigned char *)data + 4, size - 4, subsystem);
	if (sub) {
		uint32_t total, n;
		memcpy(&total, sub, 4);
		memcpy(&n, sub + 4, 4);
		memcpy(out, sub + 12, 8);
		size_t start = 20 + (((size_t)n + 4) & ~(size_t)3);
		const unsigned char *cat = start <= total
		    ? finch_trace_preferences_find_record(sub + start, total - start, category)
		    : NULL;
		if (cat) {
			memcpy(out, cat + 12, 8);
			return true;
		}
	}
	default_signpost(category, out);
	return true;
}
void finch_trace_preferences_refresh(struct finch_log *log)
{
	if (!log || !log->names)
		return;
	int saved = errno;
	const char *subsystem = log->names->names,
	           *category = subsystem + log->names->subsystem_size;
	uint32_t generation = finch_trace_preferences_version();
	dispatch_once_f(&bundle_once, NULL, bundle_init);
	struct finch_log_preferences values;
	bool found = false;
	if (!dict(bundle_preferences, subsystem)) {
		size_t size = 0;
		void *cache = _os_log_preferences_copy_cache(&size);
		if (cache) {
			found = finch_trace_preferences_cached(
			    cache, size, subsystem, category, &values);
			free(cache);
		}
	}
	if (!found) {
		xpc_object_t prefs = _os_log_preferences_load(subsystem, category);
		_os_log_preferences_compute(prefs, category, &values);
		if (prefs)
			xpc_release(prefs);
	}
	values.options = (values.options & ~UINT32_C(0x7c000000)) |
	    ((uint32_t)(__atomic_load_n(&log->options, __ATOMIC_RELAXED) >> 32) &
	        UINT32_C(0x7c000000));
	uint64_t updated;
	memcpy(&updated, &values, 8);
	__atomic_store_n(&log->options, updated, __ATOMIC_RELEASE);
	__atomic_store_n(&log->generation, generation, __ATOMIC_RELEASE);
	errno = saved;
}
