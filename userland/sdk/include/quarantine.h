/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <quarantine.h>: the quarantine API (libquarantine). The library exports
 * these with a leading underscore (_qtn_file_alloc ...); the public names are
 * macros, as in Apple's header. See userland/libsystem/quarantine.
 */

#ifndef _QUARANTINE_H_
#define _QUARANTINE_H_

#include <stddef.h>
#include <stdint.h>
#include <sys/cdefs.h>
#include <sys/types.h>

__BEGIN_DECLS

typedef struct _qtn_file_s *qtn_file_t;
typedef struct _qtn_proc_s *qtn_proc_t;

#define QTN_NOT_QUARANTINED      (-1)
#define QTN_SERIALIZED_DATA_MAX  4096

/* Flags are bits below 0x2000. Only values confirmed from Apple's binaries
 * are defined here (DO_NOT_TRANSLOCATE: macOS 26.4's libcopyfile ORs 0x100). */
#define QTN_FLAG_DO_NOT_TRANSLOCATE  0x0100

extern const char _qtn_xattr_name[];
extern const char _qtn_label_name[];
#define qtn_xattr_name _qtn_xattr_name
#define qtn_label_name _qtn_label_name

const char *_qtn_error(int code);
#define qtn_error _qtn_error

qtn_file_t _qtn_file_alloc(void);
void _qtn_file_free(qtn_file_t qf);
qtn_file_t _qtn_file_clone(qtn_file_t qf);
int _qtn_file_init_with_fd(qtn_file_t qf, int fd);
int _qtn_file_init_with_path(qtn_file_t qf, const char *path);
int _qtn_file_init_with_data(qtn_file_t qf, const void *data, size_t len);
int _qtn_file_to_data(qtn_file_t qf, char *buf, size_t *len);
int _qtn_file_apply_to_fd(qtn_file_t qf, int fd);
int _qtn_file_apply_to_path(qtn_file_t qf, const char *path);
uint32_t _qtn_file_get_flags(qtn_file_t qf);
int _qtn_file_set_flags(qtn_file_t qf, uint32_t flags);
uint64_t _qtn_file_get_timestamp(qtn_file_t qf);
int _qtn_file_set_timestamp(qtn_file_t qf, uint64_t ts);
const char *_qtn_file_get_identifier(qtn_file_t qf);
int _qtn_file_set_identifier(qtn_file_t qf, const char *identifier);
const void *_qtn_file_get_metadata(qtn_file_t qf);
size_t _qtn_file_get_metadata_size(qtn_file_t qf);
int _qtn_file_set_metadata(qtn_file_t qf, const void *data, size_t len);

#define qtn_file_alloc _qtn_file_alloc
#define qtn_file_free _qtn_file_free
#define qtn_file_clone _qtn_file_clone
#define qtn_file_init_with_fd _qtn_file_init_with_fd
#define qtn_file_init_with_path _qtn_file_init_with_path
#define qtn_file_init_with_data _qtn_file_init_with_data
#define qtn_file_to_data _qtn_file_to_data
#define qtn_file_apply_to_fd _qtn_file_apply_to_fd
#define qtn_file_apply_to_path _qtn_file_apply_to_path
#define qtn_file_get_flags _qtn_file_get_flags
#define qtn_file_set_flags _qtn_file_set_flags
#define qtn_file_get_timestamp _qtn_file_get_timestamp
#define qtn_file_set_timestamp _qtn_file_set_timestamp
#define qtn_file_get_identifier _qtn_file_get_identifier
#define qtn_file_set_identifier _qtn_file_set_identifier
#define qtn_file_get_metadata _qtn_file_get_metadata
#define qtn_file_get_metadata_size _qtn_file_get_metadata_size
#define qtn_file_set_metadata _qtn_file_set_metadata

__END_DECLS

#endif
