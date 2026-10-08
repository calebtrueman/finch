/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Finch's log store: the records finch-logd appends and log(1) reads. One
 * file of records, rotated to <file>.0 when it passes LOGSTORE_MAX bytes.
 * A record is this header, then the process name, subsystem, category and
 * message, each NUL-terminated (lengths exclude the NUL), padded to 8 bytes.
 */
#ifndef FINCH_LOGSTORE_H
#define FINCH_LOGSTORE_H

#include <stdint.h>

#define LOGSTORE_DIR   "/var/db/diagnostics/finch"
#define LOGSTORE_PATH  LOGSTORE_DIR "/os_log.records"
#define LOGSTORE_MAX   (16u << 20)

struct logstore_record {
	uint32_t size;              /* whole record, header included; a multiple of 8 */
	uint8_t  type;              /* os_log_type_t */
	uint8_t  reserved[3];
	uint64_t time_ns;           /* wall clock, nanoseconds since the epoch */
	uint64_t thread;
	int32_t  pid;
	uint16_t process_len, subsystem_len, category_len;
	uint32_t message_len;
	char     strings[];
};

#endif
