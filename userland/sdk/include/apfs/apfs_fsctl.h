/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <apfs/apfs_fsctl.h>: the APFS fsctl requests Apple's open-source code uses,
 * where their values are known. APFS is closed; these were read from macOS
 * 26.4's libremovefile, which calls fsctl(path, APFSIOC_MARK_PURGEABLE,
 * &flags, 0) with flags = APFS_CLEAR_PURGEABLE before deleting a file. The
 * xdstream and purgeable-flags requests are from macOS 26.4's mtree.
 */

#ifndef _FINCH_APFS_FSCTL_H_
#define _FINCH_APFS_FSCTL_H_

#include <stdint.h>
#include <sys/ioccom.h>

#define APFSIOC_MARK_PURGEABLE  _IOWR('J', 68, uint64_t)   /* 0xc0084a44 */
#define APFS_CLEAR_PURGEABLE    0ULL

/* The object id of a file's extended-attribute data stream (named by xdi_name). */
struct xdstream_obj_id {
	char     *xdi_name;
	uint64_t  xdi_xdtream_obj_id;
};
#define APFSIOC_XDSTREAM_OBJ_ID           _IOWR('J', 53, struct xdstream_obj_id) /* 0xc0104a35 */

/* A file's purgeable flags (the low 16 bits are meaningful). */
#define APFSIOC_GET_PURGEABLE_FILE_FLAGS  _IOR('J', 71, uint64_t)               /* 0x40084a47 */
#define APFS_PURGEABLE_FLAGS_MASK         0xffffULL

#endif
