/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "internal.h"
#include "mode.h"
#include "preferences.h"
#include "diagnostic_stream.h"
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/sysctl.h>
#include <unistd.h>
extern xpc_object_t xpc_bundle_create_main(void);
extern xpc_object_t xpc_bundle_get_info_dictionary(xpc_object_t);
extern uint64_t voucher_get_activity_id(void *, uint64_t *);
static _Atomic uint32_t trace_mode;
static _Atomic bool started;
static dispatch_once_t mode_once;
static _Thread_local bool inside_mode;
static pthread_mutex_t refresh_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t process_generation = UINT32_MAX;
static char *bundle_id;
static _Atomic uint8_t process_levels;
static _Atomic uint64_t stream_bits = UINT64_C(0xb00070000);

static uint32_t commpage(void)
{
	return *(const volatile uint32_t *)(uintptr_t)UINT64_C(0xfffffc104);
}
uint32_t finch_trace_mode_peek(void)
{
	return atomic_load_explicit(&trace_mode, memory_order_relaxed);
}
bool finch_trace_lazy_initialized(void)
{
	return atomic_load_explicit(&started, memory_order_relaxed);
}
API bool _os_trace_lazy_init_completed_4libxpc(void)
{
	return finch_trace_lazy_initialized();
}
API bool _os_trace_lazy_init_completed_4swift(void)
{
	return finch_trace_lazy_initialized();
}
API void os_trace_set_mode(uint32_t mode)
{
	if (!((finch_trace_mode_peek() | commpage()) & 0x100))
		atomic_store_explicit(&trace_mode, mode & 0xffffff, memory_order_relaxed);
}
static void mode_init(void *unused)
{
	(void)unused;
	atomic_store(&started, true);
	uint32_t mode = finch_trace_mode_peek();
	if ((mode | commpage()) & 0x100)
		return;
	const char *activity = getenv("OS_ACTIVITY_MODE"), *stream = getenv("OS_ACTIVITY_STREAM");
	if (stream && !strcasecmp(stream, "live"))
		mode |= 8;
	if (getenv("OS_ACTIVITY_PROPAGATE_MODE"))
		mode |= 0x10000;
	if (activity) {
		if (!strcasecmp(activity, "info"))
			mode |= 1;
		else if (!strcasecmp(activity, "debug"))
			mode |= 3;
		else if (!strcasecmp(activity, "off"))
			mode |= 0x400;
		else if (!strcasecmp(activity, "disable"))
			mode |= 0x100;
		else if (!strcasecmp(activity, "stream")) {
			mode |= 11;
			if (isatty(2))
				fputs(
				    "use OS_ACTIVITY_STREAM for configuring streaming.\n", stderr);
		}
	}
	int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
	struct kinfo_proc process = {0};
	size_t size = sizeof(process);
	if (!activity && !sysctl(mib, 4, &process, &size, NULL, 0) &&
	    (process.kp_proc.p_flag & P_TRACED))
		mode |= 3;
	atomic_store(&trace_mode, mode);
	xpc_object_t bundle = xpc_bundle_create_main();
	if (bundle) {
		xpc_object_t info = xpc_bundle_get_info_dictionary(bundle);
		const char *identifier =
		    info ? xpc_dictionary_get_string(info, "CFBundleIdentifier") : NULL;
		if (identifier)
			bundle_id = strdup(identifier);
		xpc_release(bundle);
	}
}
static unsigned level(xpc_object_t root, const char *key)
{
	xpc_object_t d = root ? xpc_dictionary_get_dictionary(root, "Level") : NULL;
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
static void refresh_process(uint32_t generation)
{
	if ((finch_trace_mode_peek() | commpage()) & 0x100)
		return;
	pthread_mutex_lock(&refresh_lock);
	if (process_generation == generation) {
		pthread_mutex_unlock(&refresh_lock);
		return;
	}
	xpc_object_t filter = _os_trace_read_plist_at(
	    AT_FDCWD, "/Library/Preferences/Logging/com.apple.diagnosticd.filter.plist");
	uint64_t bits = UINT64_C(0xb00070000);
	if (filter) {
		const char *path = _dyld_get_image_name(0);
		if (!path)
			path = getprogname();
		const char *slash = path ? strrchr(path, '/') : NULL;
		struct finch_trace_filter_subject subject = {.path = path,
		    .process = slash ? slash + 1 : path,
		    .pid = getpid(),
		    .uid = geteuid()};
		uint64_t matches[2] = {0};
		bool match = finch_trace_filter_matches(filter, &subject, matches);
		bits =
		    (match ? matches[0] : 0) | (uint64_t)xpc_dictionary_get_int64(filter, "global");
		xpc_release(filter);
	}
	atomic_store(&stream_bits, bits);
	if (bundle_id) {
		char path[1024];
		snprintf(path, sizeof(path),
		    "/System/Library/Preferences/Logging/Processes/%s.plist", bundle_id);
		xpc_object_t system = _os_trace_read_plist_at(AT_FDCWD, path);
		snprintf(path, sizeof(path), "/Library/Preferences/Logging/Processes/%s.plist",
		    bundle_id);
		xpc_object_t local = _os_trace_read_plist_at(AT_FDCWD, path);
		unsigned enable = level(local, "Enable"), persist = level(local, "Persist");
		if (!enable)
			enable = level(system, "Enable");
		if (!persist)
			persist = level(system, "Persist");
		atomic_store(&process_levels, (enable & 3) | (persist << 2));
		if (system)
			xpc_release(system);
		if (local)
			xpc_release(local);
	}
	process_generation = generation;
	pthread_mutex_unlock(&refresh_lock);
}
API uint32_t os_trace_get_mode(void)
{
	if (inside_mode)
		return finch_trace_mode_peek();
	int saved = errno;
	inside_mode = true;
	dispatch_once_f(&mode_once, NULL, mode_init);
	if (!((finch_trace_mode_peek() | commpage()) & 0x100))
		refresh_process(finch_trace_preferences_version());
	inside_mode = false;
	errno = saved;
	return finch_trace_mode_peek();
}
uint8_t finch_trace_process_levels(void)
{
	(void)os_trace_get_mode();
	return atomic_load(&process_levels);
}
static bool enabled(unsigned mask, unsigned stream_mask)
{
	uint32_t mode = os_trace_get_mode() | commpage();
	uint64_t activity = 0;
	if (mode & mask)
		return true;
	activity = voucher_get_activity_id((void *)(intptr_t)-3, NULL) >> 56;
	if (activity & mask)
		return true;
	if ((mode | activity) & 8) {
		uint64_t bits = atomic_load(&stream_bits);
		return (bits & 0x20000) && ((bits >> 32) & stream_mask);
	}
	return false;
}
API bool os_trace_debug_enabled(void)
{
	return enabled(2, 2);
}
API bool os_trace_info_enabled(void)
{
	return enabled(3, 1);
}
void finch_trace_mode_fork_child(void)
{
	mode_once = 0;
	atomic_store(&trace_mode, 0);
	atomic_store(&started, false);
	atomic_store(&stream_bits, 0);
	atomic_store(&process_levels, 0);
	process_generation = UINT32_MAX;
	bundle_id = NULL;
	inside_mode = false;
	refresh_lock = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
}
