/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * FSEvents (FSEvents.h): event streams over kqueue. Finch has no fseventsd
 * yet, so a started stream watches each path's directory with a vnode
 * dispatch source and reports a change to the directory itself
 * (kFSEventStreamEventFlagNone, as a coalesced macOS event does, asking
 * the client to rescan it); history before the stream started
 * (sinceWhen) isn't kept. Event IDs count up from FSEventsGetCurrentEventId,
 * which starts at the time of the first call in the process.
 */
#include "../CarbonCore/CarbonCore_Finch.h"
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

struct __FSEventStream {
    _Atomic int refcount;
    FSEventStreamCallback callback;
    FSEventStreamContext context;
    CFArrayRef paths;
    CFArrayRef exclusions;
    FSEventStreamEventId since, latest;
    CFTimeInterval latency;
    FSEventStreamCreateFlags flags;
    dev_t device;
    CFRunLoopRef runloop;
    CFStringRef mode;
    dispatch_queue_t queue;
    dispatch_source_t *sources;
    long nsources;
    bool started, invalid;
};

static _Atomic FSEventStreamEventId current_id;

FSEventStreamEventId
FSEventsGetCurrentEventId(void)
{
    FSEventStreamEventId zero = 0;
    atomic_compare_exchange_strong(&current_id, &zero, (FSEventStreamEventId)time(NULL) << 8);
    return atomic_load(&current_id);
}

static FSEventStreamRef
create(CFAllocatorRef allocator, FSEventStreamCallback callback, FSEventStreamContext *context,
       CFArrayRef pathsToWatch, FSEventStreamEventId sinceWhen, CFTimeInterval latency, FSEventStreamCreateFlags flags,
       dev_t device)
{
    if (!callback || !pathsToWatch || CFArrayGetCount(pathsToWatch) == 0)
        return NULL;
    FSEventStreamRef s = calloc(1, sizeof *s);
    s->refcount = 1;
    s->callback = callback;
    if (context) {
        s->context = *context;
        if (context->retain && context->info)
            s->context.info = (void *)context->retain(context->info);
    }
    s->paths = CFArrayCreateCopy(allocator, pathsToWatch);
    s->since = sinceWhen;
    s->latest = sinceWhen == kFSEventStreamEventIdSinceNow ? FSEventsGetCurrentEventId() : sinceWhen;
    s->latency = latency;
    s->flags = flags;
    s->device = device;
    return s;
}

FSEventStreamRef
FSEventStreamCreate(CFAllocatorRef allocator, FSEventStreamCallback callback, FSEventStreamContext *context,
                    CFArrayRef pathsToWatch, FSEventStreamEventId sinceWhen, CFTimeInterval latency,
                    FSEventStreamCreateFlags flags)
{
    return create(allocator, callback, context, pathsToWatch, sinceWhen, latency, flags, 0);
}

FSEventStreamRef
FSEventStreamCreateRelativeToDevice(CFAllocatorRef allocator, FSEventStreamCallback callback,
                                    FSEventStreamContext *context, dev_t deviceToWatch, CFArrayRef pathsToWatchRelativeToDevice,
                                    FSEventStreamEventId sinceWhen, CFTimeInterval latency, FSEventStreamCreateFlags flags)
{
    return create(allocator, callback, context, pathsToWatchRelativeToDevice, sinceWhen, latency, flags, deviceToWatch);
}

void
FSEventStreamRetain(FSEventStreamRef s)
{
    if (s)
        atomic_fetch_add(&s->refcount, 1);
}

static void
stop_sources(FSEventStreamRef s)
{
    for (long i = 0; i < s->nsources; i++) {
        dispatch_source_cancel(s->sources[i]);
        dispatch_release(s->sources[i]);
    }
    free(s->sources);
    s->sources = NULL;
    s->nsources = 0;
}

void
FSEventStreamRelease(FSEventStreamRef s)
{
    if (!s || atomic_fetch_sub(&s->refcount, 1) != 1)
        return;
    stop_sources(s);
    if (s->context.release && s->context.info)
        s->context.release(s->context.info);
    if (s->paths)
        CFRelease(s->paths);
    if (s->exclusions)
        CFRelease(s->exclusions);
    if (s->mode)
        CFRelease(s->mode);
    if (s->runloop)
        CFRelease(s->runloop);
    if (s->queue)
        dispatch_release(s->queue);
    free(s);
}

void
FSEventStreamScheduleWithRunLoop(FSEventStreamRef s, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    if (!s || !runLoop)
        return;
    s->runloop = (CFRunLoopRef)CFRetain(runLoop);
    s->mode = CFStringCreateCopy(NULL, runLoopMode);
}

void
FSEventStreamUnscheduleFromRunLoop(FSEventStreamRef s, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
    if (!s || s->runloop != runLoop)
        return;
    CFRelease(s->runloop);
    s->runloop = NULL;
}

void
FSEventStreamSetDispatchQueue(FSEventStreamRef s, dispatch_queue_t q)
{
    if (!s)
        return;
    if (q)
        dispatch_retain(q);
    if (s->queue)
        dispatch_release(s->queue);
    s->queue = q;
}

static void
deliver(FSEventStreamRef s, const char *path)
{
    FSEventStreamEventId id = atomic_fetch_add(&current_id, 1) + 1;
    s->latest = id;
    FSEventStreamEventFlags flags = kFSEventStreamEventFlagNone;
    if (s->flags & kFSEventStreamCreateFlagUseCFTypes) {
        CFStringRef p = CFStringCreateWithFileSystemRepresentation(NULL, path);
        CFArrayRef paths = CFArrayCreate(NULL, (const void **)&p, 1, &kCFTypeArrayCallBacks);
        s->callback(s, s->context.info, 1, (void *)paths, &flags, &id);
        CFRelease(paths);
        CFRelease(p);
    } else {
        const char *paths[1] = {path};
        s->callback(s, s->context.info, 1, paths, &flags, &id);
    }
}

Boolean
FSEventStreamStart(FSEventStreamRef s)
{
    if (!s || s->started || s->invalid || (!s->runloop && !s->queue))
        return false;
    FSEventsGetCurrentEventId();
    CFIndex n = CFArrayGetCount(s->paths);
    s->sources = calloc(n, sizeof *s->sources);
    for (CFIndex i = 0; i < n; i++) {
        char path[PATH_MAX];
        if (!CFStringGetFileSystemRepresentation(CFArrayGetValueAtIndex(s->paths, i), path, sizeof path))
            continue;
        int fd = open(path, O_EVTONLY);
        if (fd < 0)
            continue;
        char real[PATH_MAX];
        if (!realpath(path, real))
            strlcpy(real, path, sizeof real);
        size_t len = strlen(real);
        if (len && real[len - 1] != '/')
            strlcat(real, "/", sizeof real);
        char *reported = strdup(real);
        dispatch_queue_t q = s->queue ? s->queue : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
                                                       DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME |
                                                           DISPATCH_VNODE_ATTRIB | DISPATCH_VNODE_EXTEND,
                                                       q);
        FSEventStreamRetain(s);
        dispatch_source_set_event_handler(src, ^{
            if (!s->started)
                return;
            if (s->queue) {
                deliver(s, reported);
            } else if (s->runloop) {
                CFRunLoopPerformBlock(s->runloop, s->mode ? s->mode : kCFRunLoopDefaultMode, ^{
                    if (s->started)
                        deliver(s, reported);
                });
                CFRunLoopWakeUp(s->runloop);
            }
        });
        dispatch_source_set_cancel_handler(src, ^{
            close(fd);
            free(reported);
            FSEventStreamRelease(s);
        });
        dispatch_resume(src);
        s->sources[s->nsources++] = src;
    }
    s->started = true;
    return true;
}

void
FSEventStreamStop(FSEventStreamRef s)
{
    if (!s)
        return;
    s->started = false;
    stop_sources(s);
}

void
FSEventStreamInvalidate(FSEventStreamRef s)
{
    if (!s)
        return;
    FSEventStreamStop(s);
    s->invalid = true;
    if (s->runloop) {
        CFRelease(s->runloop);
        s->runloop = NULL;
    }
    if (s->queue) {
        dispatch_release(s->queue);
        s->queue = NULL;
    }
}

FSEventStreamEventId FSEventStreamGetLatestEventId(ConstFSEventStreamRef s) { return s ? s->latest : 0; }
dev_t FSEventStreamGetDeviceBeingWatched(ConstFSEventStreamRef s) { return s ? s->device : 0; }
CF_RETURNS_RETAINED CFArrayRef FSEventStreamCopyPathsBeingWatched(ConstFSEventStreamRef s)
{
    return s ? CFArrayCreateCopy(NULL, s->paths) : NULL;
}

FSEventStreamEventId
FSEventStreamFlushAsync(FSEventStreamRef s)
{
    return s ? s->latest : 0;
}

void FSEventStreamFlushSync(FSEventStreamRef s) {}

Boolean
FSEventStreamSetExclusionPaths(FSEventStreamRef s, CFArrayRef pathsToExclude)
{
    if (!s || !pathsToExclude || CFArrayGetCount(pathsToExclude) > 8)
        return false;
    if (s->exclusions)
        CFRelease(s->exclusions);
    s->exclusions = CFArrayCreateCopy(NULL, pathsToExclude);
    return true;
}

CF_RETURNS_RETAINED CFStringRef
FSEventStreamCopyDescription(ConstFSEventStreamRef s)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("FSEventStreamRef@%p:{ paths = %@, latency = %f, flags = 0x%08x }"),
                                    s, s ? s->paths : NULL, s ? s->latency : 0.0, s ? (unsigned)s->flags : 0u);
}

void
FSEventStreamShow(ConstFSEventStreamRef s)
{
    CFStringRef d = FSEventStreamCopyDescription(s);
    CFShow(d);
    CFRelease(d);
}

FSEventStreamEventId
FSEventsGetLastEventIdForDeviceBeforeTime(dev_t dev, CFAbsoluteTime time)
{
    return 0;
}

CF_RETURNS_RETAINED CFUUIDRef
FSEventsCopyUUIDForDevice(dev_t dev)
{
    return NULL;
}

Boolean
FSEventsPurgeEventsForDeviceUpToEventId(dev_t dev, FSEventStreamEventId eventId)
{
    return false;
}
