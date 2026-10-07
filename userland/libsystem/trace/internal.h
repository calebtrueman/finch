/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_INTERNAL_H
#define FINCH_TRACE_INTERNAL_H
#include <ptrauth.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <time.h>
#include "format.h"
#define API __attribute__((visibility("default")))
struct finch_log_names {uint16_t id;uint8_t subsystem_size,category_size;char names[];};
struct finch_log {const void *__ptrauth_objc_isa_pointer isa;int32_t refs,xrefs;struct finch_log*next;struct finch_log_names*names;uint64_t reserved[2];uint32_t generation,unused;uint64_t options;};
struct finch_log_pack {uint64_t continuous;struct timespec wall;const void*image;const void*pc;const char*format;uint64_t reserved[2];uint16_t error,data_size;uint8_t data[];};
struct finch_log_message {
 uint64_t identifier,timestamp,thread;const void*image_uuid;const char*image_path;
 uint64_t seconds,microseconds;int32_t timezone,daylight;uint64_t image_offset,reserved;
 uint32_t flags,padding;const char*format;const uint8_t*data;size_t data_size;
 const uint8_t*private_data;size_t private_size;const char*subsystem,*category;uint64_t extra[5];
};
extern struct finch_log _os_log_default,_os_log_disabled;
void finch_log_send(struct finch_log*,uint8_t,const struct finch_log_pack*,const uint8_t*,size_t,bool);
#endif
