/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Platform helpers CoreFoundation calls on Darwin. swift-corelibs defines
 * them only in its Swift build (CFPlatform.c's DEPLOYMENT_RUNTIME_SWIFT
 * block); Apple's CF keeps them internal, so they're CF_PRIVATE here too.
 */

#include "CFInternal.h"

#include <pthread.h>
#include <string.h>
#include <unistd.h>

/* The current directory into `path` (at most `maxlen` bytes, NUL included). */
CF_PRIVATE Boolean _CFGetCurrentDirectory(char *path, int maxlen) {
    return maxlen > 0 && getcwd(path, (size_t)maxlen) != NULL;
}

/* Darwin names only the calling thread. Returns 0, or an errno value. */
CF_PRIVATE int _CFThreadSetName(_CFThreadRef thread, const char *_Nonnull name) {
    if (!pthread_equal(thread, pthread_self())) return EINVAL;
    return pthread_setname_np(name);
}
