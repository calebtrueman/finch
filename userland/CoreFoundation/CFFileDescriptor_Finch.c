/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CFFileDescriptor: run-loop callbacks for a file descriptor's readability
 * and writability (public API, <CoreFoundation/CFFileDescriptor.h>).
 * swift-corelibs dropped Darwin's implementation and CF-Lite never had one,
 * so this is Finch's, with Apple's documented behavior:
 *
 *   - Callbacks are one-shot: when one fires, that type is disabled until
 *     CFFileDescriptorEnableCallBacks() turns it on again.
 *   - They're delivered by a run-loop source (CFFileDescriptorCreateRunLoopSource)
 *     on the run loops it's added to.
 *   - CFFileDescriptorInvalidate() stops callbacks and, if asked at
 *     creation, closes the descriptor.
 *
 * Readiness is watched with libdispatch read/write sources on a private
 * queue; a ready source is suspended, marks its type pending, and signals the
 * run-loop source and wakes the run loops it's scheduled on. The type takes
 * CF's reserved static type ID (_kCFRuntimeIDCFFileDescriptor, patches/).
 */

#include "CFInternal.h"
#include "CFRuntime_Internal.h"

#include <CoreFoundation/CFRunLoop.h>
#include <dispatch/dispatch.h>
#include <os/lock.h>
#include <stdlib.h>
#include <unistd.h>

/* <CoreFoundation/CFFileDescriptor.h>; swift-corelibs has no copy of it. */
typedef int CFFileDescriptorNativeDescriptor;
typedef struct __CFFileDescriptor *CFFileDescriptorRef;
enum {
    kCFFileDescriptorReadCallBack = 1UL << 0,
    kCFFileDescriptorWriteCallBack = 1UL << 1,
};
typedef void (*CFFileDescriptorCallBack)(CFFileDescriptorRef f, CFOptionFlags callBackTypes, void *info);
typedef struct {
    CFIndex version;
    void *info;
    void *(*retain)(void *info);
    void (*release)(void *info);
    CFStringRef (*copyDescription)(void *info);
} CFFileDescriptorContext;

struct __CFFileDescriptor {
    CFRuntimeBase base;
    int fd;
    Boolean closeOnInvalidate;
    Boolean valid;
    CFFileDescriptorCallBack callout;
    CFFileDescriptorContext context;
    os_unfair_lock lock;
    CFOptionFlags enabled;           /* armed callback types */
    CFOptionFlags pending;           /* fired, not yet delivered */
    dispatch_queue_t queue;
    dispatch_source_t sources[2];    /* read, write */
    Boolean resumed[2];
    CFRunLoopSourceRef runLoopSource;
    CFMutableArrayRef runLoops;      /* where runLoopSource is scheduled */
};

static void __CFFileDescriptorFinalize(CFTypeRef cf);
static CFStringRef __CFFileDescriptorCopyDescription(CFTypeRef cf);

CF_PRIVATE const CFRuntimeClass __CFFileDescriptorClass = {
    .version = 0,
    .className = "CFFileDescriptor",
    .finalize = __CFFileDescriptorFinalize,
    .copyDebugDesc = __CFFileDescriptorCopyDescription,
};

CF_EXPORT CFTypeID CFFileDescriptorGetTypeID(void);
CF_EXPORT CFFileDescriptorRef CFFileDescriptorCreate(CFAllocatorRef allocator, CFFileDescriptorNativeDescriptor fd,
    Boolean closeOnInvalidate, CFFileDescriptorCallBack callout, const CFFileDescriptorContext *context);
CF_EXPORT CFFileDescriptorNativeDescriptor CFFileDescriptorGetNativeDescriptor(CFFileDescriptorRef f);
CF_EXPORT void CFFileDescriptorGetContext(CFFileDescriptorRef f, CFFileDescriptorContext *context);
CF_EXPORT void CFFileDescriptorEnableCallBacks(CFFileDescriptorRef f, CFOptionFlags callBackTypes);
CF_EXPORT void CFFileDescriptorDisableCallBacks(CFFileDescriptorRef f, CFOptionFlags callBackTypes);
CF_EXPORT void CFFileDescriptorInvalidate(CFFileDescriptorRef f);
CF_EXPORT Boolean CFFileDescriptorIsValid(CFFileDescriptorRef f);
CF_EXPORT CFRunLoopSourceRef CFFileDescriptorCreateRunLoopSource(CFAllocatorRef allocator, CFFileDescriptorRef f,
    CFIndex order);

CFTypeID CFFileDescriptorGetTypeID(void) {
    return _kCFRuntimeIDCFFileDescriptor;
}

static CFOptionFlags kind_flag(int kind) {
    return kind == 0 ? kCFFileDescriptorReadCallBack : kCFFileDescriptorWriteCallBack;
}

/* Wake every run loop the source is scheduled on (caller holds the lock). */
static void signal_locked(CFFileDescriptorRef f) {
    if (!f->runLoopSource) return;
    CFRunLoopSourceSignal(f->runLoopSource);
    for (CFIndex i = 0; i < CFArrayGetCount(f->runLoops); i++) {
        CFRunLoopWakeUp((CFRunLoopRef)CFArrayGetValueAtIndex(f->runLoops, i));
    }
}

/* A dispatch source saw the descriptor ready: one-shot, so disarm it. */
static void ready(CFFileDescriptorRef f, int kind) {
    os_unfair_lock_lock(&f->lock);
    if (f->valid && f->resumed[kind]) {
        dispatch_suspend(f->sources[kind]);
        f->resumed[kind] = false;
        f->enabled &= ~kind_flag(kind);
        f->pending |= kind_flag(kind);
        signal_locked(f);
    }
    os_unfair_lock_unlock(&f->lock);
}

/* --- run-loop source callbacks (version 0) --- */

static void rls_schedule(void *info, CFRunLoopRef rl, CFStringRef mode) {
    CFFileDescriptorRef f = info;
    (void)mode;
    os_unfair_lock_lock(&f->lock);
    CFArrayAppendValue(f->runLoops, rl);
    if (f->pending) signal_locked(f);   /* fired before it was scheduled */
    os_unfair_lock_unlock(&f->lock);
}

static void rls_cancel(void *info, CFRunLoopRef rl, CFStringRef mode) {
    CFFileDescriptorRef f = info;
    (void)mode;
    os_unfair_lock_lock(&f->lock);
    CFIndex i = CFArrayGetFirstIndexOfValue(f->runLoops, CFRangeMake(0, CFArrayGetCount(f->runLoops)), rl);
    if (i != kCFNotFound) CFArrayRemoveValueAtIndex(f->runLoops, i);
    os_unfair_lock_unlock(&f->lock);
}

static void rls_perform(void *info) {
    CFFileDescriptorRef f = info;
    os_unfair_lock_lock(&f->lock);
    CFOptionFlags fired = f->pending;
    f->pending = 0;
    Boolean valid = f->valid;
    CFFileDescriptorCallBack callout = f->callout;
    void *context = f->context.info;
    os_unfair_lock_unlock(&f->lock);
    if (valid && fired && callout) {
        CFRetain(f);
        callout(f, fired, context);
        CFRelease(f);
    }
}

/* --- API --- */

CFFileDescriptorRef CFFileDescriptorCreate(CFAllocatorRef allocator, CFFileDescriptorNativeDescriptor fd,
    Boolean closeOnInvalidate, CFFileDescriptorCallBack callout, const CFFileDescriptorContext *context) {
    if (fd < 0) return NULL;
    CFIndex extra = sizeof(struct __CFFileDescriptor) - sizeof(CFRuntimeBase);
    CFFileDescriptorRef f = (CFFileDescriptorRef)_CFRuntimeCreateInstance(allocator, _kCFRuntimeIDCFFileDescriptor,
        extra, NULL);
    if (!f) return NULL;
    f->fd = fd;
    f->closeOnInvalidate = closeOnInvalidate;
    f->valid = true;
    f->callout = callout;
    f->lock = OS_UNFAIR_LOCK_INIT;
    if (context) {
        f->context = *context;
        if (context->retain && context->info) f->context.info = context->retain(context->info);
    }
    f->runLoops = CFArrayCreateMutable(kCFAllocatorSystemDefault, 0, NULL);   /* not retained, as in CF */
    f->queue = dispatch_queue_create("com.apple.CFFileDescriptor", DISPATCH_QUEUE_SERIAL);
    for (int kind = 0; kind < 2; kind++) {
        f->sources[kind] = dispatch_source_create(kind == 0 ? DISPATCH_SOURCE_TYPE_READ : DISPATCH_SOURCE_TYPE_WRITE,
            (uintptr_t)fd, 0, f->queue);
        dispatch_source_set_event_handler(f->sources[kind], ^{ ready(f, kind); });
    }
    return f;
}

CFFileDescriptorNativeDescriptor CFFileDescriptorGetNativeDescriptor(CFFileDescriptorRef f) {
    return f->fd;
}

void CFFileDescriptorGetContext(CFFileDescriptorRef f, CFFileDescriptorContext *context) {
    if (!context) return;
    CFAssert1(context->version == 0, __kCFLogAssertion, "%s(): context version not initialized to 0", __PRETTY_FUNCTION__);
    *context = f->context;
}

void CFFileDescriptorEnableCallBacks(CFFileDescriptorRef f, CFOptionFlags callBackTypes) {
    os_unfair_lock_lock(&f->lock);
    if (f->valid) {
        for (int kind = 0; kind < 2; kind++) {
            if ((callBackTypes & kind_flag(kind)) && !f->resumed[kind]) {
                f->enabled |= kind_flag(kind);
                f->resumed[kind] = true;
                dispatch_resume(f->sources[kind]);
            }
        }
    }
    os_unfair_lock_unlock(&f->lock);
}

void CFFileDescriptorDisableCallBacks(CFFileDescriptorRef f, CFOptionFlags callBackTypes) {
    os_unfair_lock_lock(&f->lock);
    for (int kind = 0; kind < 2; kind++) {
        if ((callBackTypes & kind_flag(kind)) && f->resumed[kind]) {
            dispatch_suspend(f->sources[kind]);
            f->resumed[kind] = false;
        }
        if (callBackTypes & kind_flag(kind)) f->enabled &= ~kind_flag(kind);
    }
    os_unfair_lock_unlock(&f->lock);
}

/* Stop callbacks, close the descriptor if asked, drop the context. Doesn't
 * retain `f`, so finalize can use it too. */
static void invalidate(CFFileDescriptorRef f) {
    CFRunLoopSourceRef source = NULL;
    void *info = NULL;
    void (*release)(void *) = NULL;

    os_unfair_lock_lock(&f->lock);
    if (!f->valid) {
        os_unfair_lock_unlock(&f->lock);
        return;
    }
    f->valid = false;
    f->enabled = f->pending = 0;
    /* The descriptor closes once both watchers have stopped using it. The
     * count lives outside `f`, which may be gone by then. */
    _Atomic int *left = malloc(sizeof(*left));
    atomic_store(left, 2);
    int fd = f->fd;
    Boolean closeIt = f->closeOnInvalidate;
    for (int kind = 0; kind < 2; kind++) {
        dispatch_source_set_cancel_handler(f->sources[kind], ^{
            if (atomic_fetch_sub(left, 1) == 1) {
                if (closeIt) close(fd);
                free(left);
            }
        });
        dispatch_source_cancel(f->sources[kind]);
        if (!f->resumed[kind]) {       /* a suspended source never runs its cancel handler */
            f->resumed[kind] = true;
            dispatch_resume(f->sources[kind]);
        }
    }
    source = f->runLoopSource;
    f->runLoopSource = NULL;
    info = f->context.info;
    release = f->context.release;
    f->context.info = NULL;
    os_unfair_lock_unlock(&f->lock);

    if (source) {
        CFRunLoopSourceInvalidate(source);
        CFRelease(source);
    }
    if (release && info) release(info);
}

void CFFileDescriptorInvalidate(CFFileDescriptorRef f) {
    CFRetain(f);
    invalidate(f);
    CFRelease(f);
}

Boolean CFFileDescriptorIsValid(CFFileDescriptorRef f) {
    os_unfair_lock_lock(&f->lock);
    Boolean valid = f->valid;
    os_unfair_lock_unlock(&f->lock);
    return valid;
}

CFRunLoopSourceRef CFFileDescriptorCreateRunLoopSource(CFAllocatorRef allocator, CFFileDescriptorRef f, CFIndex order) {
    CFRunLoopSourceRef result = NULL;
    os_unfair_lock_lock(&f->lock);
    if (f->valid) {
        if (!f->runLoopSource) {
            CFRunLoopSourceContext ctx = {
                .version = 0,
                .info = f,
                .schedule = rls_schedule,
                .cancel = rls_cancel,
                .perform = rls_perform,
            };
            f->runLoopSource = CFRunLoopSourceCreate(allocator, order, &ctx);
        }
        result = f->runLoopSource ? (CFRunLoopSourceRef)CFRetain(f->runLoopSource) : NULL;
    }
    os_unfair_lock_unlock(&f->lock);
    return result;
}

static void __CFFileDescriptorFinalize(CFTypeRef cf) {
    CFFileDescriptorRef f = (CFFileDescriptorRef)cf;
    invalidate(f);
    /* Readiness handlers run on f->queue and use `f`; with the sources
     * cancelled no more are queued, so this waits out any still running. */
    dispatch_sync(f->queue, ^{});
    for (int kind = 0; kind < 2; kind++) {
        if (f->sources[kind]) dispatch_release(f->sources[kind]);
    }
    if (f->queue) dispatch_release(f->queue);
    if (f->runLoops) CFRelease(f->runLoops);
}

static CFStringRef __CFFileDescriptorCopyDescription(CFTypeRef cf) {
    CFFileDescriptorRef f = (CFFileDescriptorRef)cf;
    return CFStringCreateWithFormat(kCFAllocatorSystemDefault, NULL,
        CFSTR("<CFFileDescriptor %p [%p]>{valid = %s, fd = %d, callbacks enabled = %lu}"), cf,
        CFGetAllocator(cf), f->valid ? "Yes" : "No", f->fd, (unsigned long)f->enabled);
}
