/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <System/pthread_machdep.h>: the old home of the direct thread-specific-data
 * interface (reserved TSD keys, _pthread_getspecific_direct). It now lives in
 * libpthread's <pthread/tsd_private.h>; objc4 still includes the old name.
 */
#ifndef FINCH_SYSTEM_PTHREAD_MACHDEP_H
#define FINCH_SYSTEM_PTHREAD_MACHDEP_H
#include <pthread/tsd_private.h>
#endif
