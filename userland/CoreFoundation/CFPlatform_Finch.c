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

/*
 * App Nap (private SPI Apple's CoreFoundation exports): a process tells the
 * system it's holding a power assertion, so it isn't throttled while idle
 * (IOKit's power management calls this). Finch doesn't nap processes, so
 * there's nothing to tell; the call is accepted and ignored.
 */
typedef CF_OPTIONS(uint64_t, __CFRunLoopOptions) {
    __CFRunLoopOptionsTakeAssertion = 1 << 0,
    __CFRunLoopOptionsDropAssertion = 1 << 1,
};
CF_EXPORT void __CFRunLoopSetOptionsReason(__CFRunLoopOptions options, CFStringRef reason);
void __CFRunLoopSetOptionsReason(__CFRunLoopOptions options, CFStringRef reason) {
    (void)options;
    (void)reason;
}

/* Apple's CoreFoundation exports these; the run loop pushes a pool around
 * each callout with them. */
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);
CF_EXPORT uintptr_t _CFAutoreleasePoolPush(void) { return (uintptr_t)objc_autoreleasePoolPush(); }
CF_EXPORT void _CFAutoreleasePoolPop(uintptr_t pool) { objc_autoreleasePoolPop((void *)pool); }
