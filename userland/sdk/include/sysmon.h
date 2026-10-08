/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <sysmon.h>: libsysmon, the process/system statistics client (Apple doesn't
 * publish it). The interface is what macOS 26.4's libsysmon exports; the
 * numbering of the request types and attributes is what Apple's own tools
 * (pgrep/pkill) were compiled with. Finch's libsysmon (userland/libsysmon)
 * answers process requests itself, with no sysmond.
 */

#ifndef _SYSMON_H_
#define _SYSMON_H_

#include <os/object.h>
#include <stdbool.h>
#include <stdint.h>
#include <xpc/xpc.h>

__BEGIN_DECLS

#if OS_OBJECT_USE_OBJC
OS_OBJECT_DECL(sysmon_object);
OS_OBJECT_DECL_SUBCLASS(sysmon_request, sysmon_object);
OS_OBJECT_DECL_SUBCLASS(sysmon_table, sysmon_object);
OS_OBJECT_DECL_SUBCLASS(sysmon_row, sysmon_object);
#else
typedef struct sysmon_object_s *sysmon_object_t;
typedef struct sysmon_request_s *sysmon_request_t;
typedef struct sysmon_table_s *sysmon_table_t;
typedef struct sysmon_row_s *sysmon_row_t;
#endif

typedef uint32_t sysmon_attribute_t;

/* Request types (2 and 3 are system-wide and coalition tables: not provided). */
#define SYSMON_REQUEST_TYPE_PROCESS	1

/* Process attributes: values are uint64 unless noted. */
#define SYSMON_ATTR_PROC_FLAGS		1	/* proc_bsdinfo pbi_flags (PROC_FLAG_*) */
#define SYSMON_ATTR_PROC_PID		4
#define SYSMON_ATTR_PROC_PPID		5
#define SYSMON_ATTR_PROC_UID		6	/* effective */
#define SYSMON_ATTR_PROC_RUID		8
#define SYSMON_ATTR_PROC_RGID		9
#define SYSMON_ATTR_PROC_COMM		12	/* string */
#define SYSMON_ATTR_PROC_PGID		15
#define SYSMON_ATTR_PROC_TDEV		17	/* controlling terminal's dev_t */
#define SYSMON_ATTR_PROC_START		20	/* date */
#define SYSMON_ATTR_PROC_ARGUMENTS	44	/* array of strings */

extern const char *SYSMON_XPC_SERVICE_NAME;
extern const char *SYSMON_XPC_KEY_TYPE;
extern const char *SYSMON_XPC_KEY_FLAGS;
extern const char *SYSMON_XPC_KEY_ATTRIBUTES;
extern const char *SYSMON_XPC_REPLY_KEY_HEADER;
extern const char *SYSMON_XPC_REPLY_KEY_TABLE;
extern const char *SYSMON_XPC_REPLY_KEY_TIMESTAMP;

sysmon_request_t sysmon_request_create(uint64_t type, void (^handler)(sysmon_table_t table));
sysmon_request_t sysmon_request_create_with_error(uint64_t type,
    void (^handler)(sysmon_table_t table, const char *error));
void sysmon_request_add_attribute(sysmon_request_t request, sysmon_attribute_t attribute);
/* Attributes, terminated by 0. */
void sysmon_request_add_attributes(sysmon_request_t request, ...);
void sysmon_request_set_flags(sysmon_request_t request, uint64_t flags);
/* Repeat every interval milliseconds (rounded to a multiple of 500, at least 500). */
void sysmon_request_set_interval(sysmon_request_t request, uint64_t interval_ms);
void sysmon_request_execute(sysmon_request_t request);
void sysmon_request_cancel(sysmon_request_t request);

uint64_t sysmon_table_get_count(sysmon_table_t table);
sysmon_row_t sysmon_table_get_row(sysmon_table_t table, uint64_t index);
sysmon_row_t sysmon_table_copy_row(sysmon_table_t table, uint64_t index);
uint64_t sysmon_table_get_timestamp(sysmon_table_t table);
void sysmon_table_apply(sysmon_table_t table, bool (^applier)(sysmon_row_t row));

xpc_object_t sysmon_row_get_value(sysmon_row_t row, sysmon_attribute_t attribute);
void sysmon_row_apply(sysmon_row_t row, bool (^applier)(sysmon_attribute_t attribute,
    xpc_object_t value));

/* Any sysmon object (void *, so plain C callers keep their own types). */
void *sysmon_retain(void *object);
void sysmon_release(void *object);

sysmon_request_t sysmon_request_alloc(void);
sysmon_table_t sysmon_table_alloc(void);
sysmon_row_t sysmon_row_alloc(void);

__END_DECLS

#endif /* !_SYSMON_H_ */
