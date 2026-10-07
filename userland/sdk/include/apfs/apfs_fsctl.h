/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <apfs/apfs_fsctl.h>: the APFS fsctl requests Apple's open-source code uses,
 * where their values are known. APFS is closed; these were read from macOS
 * 26.4's libremovefile, which calls fsctl(path, APFSIOC_MARK_PURGEABLE,
 * &flags, 0) with flags = APFS_CLEAR_PURGEABLE before deleting a file.
 */

#ifndef _FINCH_APFS_FSCTL_H_
#define _FINCH_APFS_FSCTL_H_

#include <stdint.h>
#include <sys/ioccom.h>

#define APFSIOC_MARK_PURGEABLE  _IOWR('J', 68, uint64_t)   /* 0xc0084a44 */
#define APFS_CLEAR_PURGEABLE    0ULL

#endif
