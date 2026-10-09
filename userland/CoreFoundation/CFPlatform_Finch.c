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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
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

/* CFLogTest(toConsole, format, ...): Apple's CoreFoundation exports it for
 * apps' automated tests to log through (TextEdit links it). Apple's writes
 * to a log under the user's Library unless asked for the console; Finch's
 * appends to ~/Library/Logs/CFLogTest.log, or writes to stderr. */
CF_EXPORT void CFLogTest(Boolean toConsole, CFStringRef format, ...);
void CFLogTest(Boolean toConsole, CFStringRef format, ...) {
    if (!format) return;
    va_list ap;
    va_start(ap, format);
    CFStringRef s = CFStringCreateWithFormatAndArguments(kCFAllocatorDefault, NULL, format, ap);
    va_end(ap);
    if (!s) return;
    char buf[4096];
    if (CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8)) {
        FILE *f = NULL;
        if (!toConsole) {
            const char *home = getenv("HOME");
            char path[1024];
            if (home && snprintf(path, sizeof path, "%s/Library/Logs/CFLogTest.log", home) < (int)sizeof path)
                f = fopen(path, "a");
        }
        fprintf(f ? f : stderr, "%s\n", buf);
        if (f) fclose(f);
    }
    CFRelease(s);
}

/* CF's private "Mac zone" debugging switch (SwiftUI asks): never on in Finch. */
CF_EXPORT Boolean _CFMZEnabled(void) { return false; }
