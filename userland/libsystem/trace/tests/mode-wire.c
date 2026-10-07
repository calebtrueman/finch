/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../mode.h"
#include "../diagnostic_stream.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern bool os_trace_debug_enabled(void), os_trace_info_enabled(void);
static uint32_t generation;
static unsigned reads, bundles;
static const char *system_enable = "debug", *system_persist = "info", *local_enable, *local_persist;
static uint64_t filter_bits = UINT64_C(0xb00070000), activity;
static bool have_bundle = true;
uint32_t finch_trace_preferences_version(void)
{
	assert(os_trace_get_mode() == finch_trace_mode_peek());
	errno = 17;
	return generation;
}
xpc_object_t test_mode_bundle(void)
{
	bundles++;
	assert(finch_trace_lazy_initialized());
	assert(os_trace_get_mode() == finch_trace_mode_peek());
	xpc_object_t p = xpc_dictionary_create(NULL, NULL, 0);
	if (have_bundle)
		xpc_dictionary_set_string(p, "CFBundleIdentifier", "mode.test");
	return p;
}
xpc_object_t test_mode_bundle_info(xpc_object_t p)
{
	return p;
}
uint64_t test_mode_activity(void *current, uint64_t *parent)
{
	assert(current == (void *)(intptr_t)-3 && !parent);
	return activity;
}
bool finch_trace_filter_matches(
    xpc_object_t p, const struct finch_trace_filter_subject *s, uint64_t bits[2])
{
	(void)p;
	assert(s->path && s->process && !s->subsystem && !s->category);
	bits[0] = filter_bits;
	return true;
}
xpc_object_t _os_trace_read_plist_at(int dir, const char *path)
{
	(void)dir;
	reads++;
	errno = 29;
	xpc_object_t p = xpc_dictionary_create(NULL, NULL, 0);
	if (strstr(path, "diagnosticd"))
		return p;
	assert(strstr(path, "/Processes/mode.test.plist"));
	bool system = !strncmp(path, "/System/", 8);
	const char *enable = system ? system_enable : local_enable,
	           *persist = system ? system_persist : local_persist;
	xpc_object_t level = xpc_dictionary_create(NULL, NULL, 0);
	if (enable)
		xpc_dictionary_set_string(level, "Enable", enable);
	if (persist)
		xpc_dictionary_set_string(level, "Persist", persist);
	xpc_dictionary_set_value(p, "Level", level);
	xpc_release(level);
	return p;
}
static void *thread(void *unused)
{
	(void)unused;
	for (unsigned i = 0; i < 1000; i++) {
		errno = 93;
		assert(os_trace_get_mode() == 8 && errno == 93);
	}
	return NULL;
}
int main(void)
{
	unsetenv("OS_ACTIVITY_MODE");
	unsetenv("OS_ACTIVITY_STREAM");
	unsetenv("OS_ACTIVITY_PROPAGATE_MODE");
	assert(!finch_trace_lazy_initialized());
	os_trace_set_mode(8);
	assert(!finch_trace_lazy_initialized() && finch_trace_mode_peek() == 8);
	errno = 91;
	assert(os_trace_get_mode() == 8 && errno == 91);
	assert(bundles == 1 && reads == 3 && finch_trace_process_levels() == 11);
	assert(os_trace_debug_enabled() && os_trace_info_enabled());
	const char *choices[] = {NULL, "bad", "default", "info", "debug", "off", "none"};
	for (unsigned i = 0; i < 7; i++)
		for (unsigned j = 0; j < 7; j++) {
			local_enable = choices[i];
			local_persist = choices[j];
			generation++;
			unsigned before = reads;
			unsigned enable = i < 2 ? 3
			    : i == 2            ? 1
			    : i == 3            ? 2
			    : i == 4            ? 3
			                        : 4,
			         persist = j < 2 ? 2
			    : j == 2             ? 1
			    : j == 3             ? 2
			    : j == 4             ? 3
			                         : 4;
			assert(finch_trace_process_levels() == ((enable & 3) | (persist << 2)) &&
			    reads == before + 3);
			assert(finch_trace_process_levels() == ((enable & 3) | (persist << 2)) &&
			    reads == before + 3);
		}
	filter_bits = UINT64_C(0x100020000);
	generation++;
	assert(!os_trace_debug_enabled() && os_trace_info_enabled());
	filter_bits = UINT64_C(0x200020000);
	generation++;
	assert(os_trace_debug_enabled() &&
	    (!os_trace_info_enabled() ||
	        (*(const volatile uint32_t *)(uintptr_t)UINT64_C(0xfffffc104) & 3)));
	activity = UINT64_C(2) << 56;
	os_trace_set_mode(0);
	assert(os_trace_debug_enabled() && os_trace_info_enabled());
	activity = 0;
	os_trace_set_mode(8);
	pthread_t threads[8];
	unsigned before = reads;
	for (unsigned i = 0; i < 8; i++)
		assert(!pthread_create(threads + i, NULL, thread, NULL));
	for (unsigned i = 0; i < 8; i++)
		assert(!pthread_join(threads[i], NULL));
	assert(reads == before);
	finch_trace_mode_fork_child();
	assert(!finch_trace_lazy_initialized() && !finch_trace_mode_peek());
	setenv("OS_ACTIVITY_MODE", "debug", 1);
	assert(os_trace_get_mode() == 3 && bundles == 2);
	finch_trace_mode_fork_child();
	have_bundle = false;
	setenv("OS_ACTIVITY_MODE", "off", 1);
	before = reads;
	assert(os_trace_get_mode() == 0x400 && reads == before + 1 &&
	    finch_trace_process_levels() == 0);
	os_trace_set_mode(0x100);
	generation++;
	before = reads;
	assert(os_trace_get_mode() == 0x100 && reads == before);
	os_trace_set_mode(0);
	assert(os_trace_get_mode() == 0x100);
	puts(
	    "mode wire: process levels, filter refresh, nested calls, threads, fork reset, and disable checks passed");
	return 0;
}
