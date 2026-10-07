/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_PREFERENCES_H
#define FINCH_TRACE_PREFERENCES_H
#include "internal.h"
#include <xpc/xpc.h>
struct finch_log_preferences {
	uint8_t reserved, ttl_default, ttl_info, ttl_debug;
	uint32_t options;
};
xpc_object_t _os_trace_read_plist_at(int, const char *);
void _os_log_preferences_compute(xpc_object_t, const char *, struct finch_log_preferences *);
void _os_log_preferences_merge(xpc_object_t, xpc_object_t, const char *);
xpc_object_t _os_log_preferences_load(const char *, const char *);
xpc_object_t _os_log_preferences_load_sysprefs(const char *, const char *, bool);
void *_os_log_preferences_copy_cache(size_t *);
uint32_t finch_trace_preferences_version(void);
const unsigned char *finch_trace_preferences_find_record(const void *, size_t, const char *);
bool finch_trace_preferences_cached(
    const void *, size_t, const char *, const char *, struct finch_log_preferences *);
void finch_trace_preferences_refresh(struct finch_log *);
#endif
