/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <os/transaction_private.h>: os_transaction, the object a process holds
 * while it has outstanding work, so the service manager won't idle-exit it.
 * Implemented in libxpc (Finch: userland/libxpc/compat.c).
 */

#ifndef __OS_TRANSACTION_PRIVATE_H__
#define __OS_TRANSACTION_PRIVATE_H__

#include <os/object.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

OS_OBJECT_DECL_CLASS(os_transaction);

OS_OBJECT_RETURNS_RETAINED OS_WARN_RESULT
os_transaction_t os_transaction_create(const char *description);

char *os_transaction_copy_description(os_transaction_t transaction);

__END_DECLS

#endif
