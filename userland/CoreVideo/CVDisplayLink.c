/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CVDisplayLink: calls its output callback or handler once per display refresh, from a
 * thread of its own, with the time now and the time the next frame shows. Finch's
 * window server doesn't report vertical blanks yet, so the link runs from a timer at the
 * display's refresh rate (60 Hz when the display reports none).
 *
 * Also the host clock functions (CVHostTime.h), which are Mach absolute time.
 */
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>

/* CoreFoundation's runtime (swift-corelibs' CFRuntime.h): a CF type of our own. */
typedef struct {
    uintptr_t isa;
    _Atomic(uint64_t) info;
} CFRuntimeBase;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} CFRuntimeClass;

extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes, unsigned char *category);

struct __CVDisplayLink {
    CFRuntimeBase base;
    os_unfair_lock lock;
    CGDirectDisplayID display;
    CVDisplayLinkOutputCallback callback;
    void *userInfo;
    CVDisplayLinkOutputHandler handler;
    dispatch_queue_t queue;
    dispatch_source_t timer;
    bool running, paused;
    double period; /* seconds */
    int64_t frame;
};

static const int32_t kTimeScale = 1000000000; /* nanoseconds */

static void
display_link_finalize(CFTypeRef cf)
{
    CVDisplayLinkRef link = (CVDisplayLinkRef)cf;
    if (link->timer) {
        dispatch_source_cancel(link->timer);
        dispatch_release(link->timer);
    }
    if (link->queue)
        dispatch_release(link->queue);
    if (link->handler)
        _Block_release(link->handler);
}

static CFStringRef
display_link_description(CFTypeRef cf)
{
    CVDisplayLinkRef link = (CVDisplayLinkRef)cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CVDisplayLink %p [display %u, %s]>"), cf, link->display,
                                    link->running ? "running" : "stopped");
}

static CFTypeID display_link_type;

static const CFRuntimeClass display_link_class = {
    .version = 0,
    .className = "CVDisplayLink",
    .finalize = display_link_finalize,
    .copyDebugDesc = display_link_description,
};

CFTypeID
CVDisplayLinkGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      display_link_type = _CFRuntimeRegisterClass(&display_link_class);
    });
    return display_link_type;
}

#pragma mark - Host time

static mach_timebase_info_data_t
timebase(void)
{
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      mach_timebase_info(&tb);
    });
    return tb;
}

uint64_t
CVGetCurrentHostTime(void)
{
    return mach_absolute_time();
}

double
CVGetHostClockFrequency(void)
{
    mach_timebase_info_data_t tb = timebase();
    return 1e9 * tb.denom / tb.numer;
}

uint32_t
CVGetHostClockMinimumTimeDelta(void)
{
    return 1;
}

#pragma mark - Creating

static double
refresh_period(CGDirectDisplayID display)
{
    double rate = 0;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (mode) {
        rate = CGDisplayModeGetRefreshRate(mode);
        CGDisplayModeRelease(mode);
    }
    return 1.0 / (rate > 1 ? rate : 60);
}

CVReturn
CVDisplayLinkCreateWithCGDisplay(CGDirectDisplayID display, CVDisplayLinkRef *linkOut)
{
    if (!linkOut)
        return kCVReturnInvalidArgument;
    CVDisplayLinkRef link = (CVDisplayLinkRef)_CFRuntimeCreateInstance(
        NULL, CVDisplayLinkGetTypeID(), sizeof(struct __CVDisplayLink) - sizeof(CFRuntimeBase), NULL);
    if (!link)
        return kCVReturnAllocationFailed;
    link->lock = OS_UNFAIR_LOCK_INIT;
    link->display = display;
    link->period = refresh_period(display);
    link->queue = dispatch_queue_create_with_target("com.apple.CoreVideo.CVDisplayLink", DISPATCH_QUEUE_SERIAL,
                                                    dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    *linkOut = link;
    return kCVReturnSuccess;
}

CVReturn
CVDisplayLinkCreateWithCGDisplays(CGDirectDisplayID *displays, CFIndex count, CVDisplayLinkRef *linkOut)
{
    if (!displays || count < 1)
        return kCVReturnInvalidArgument;
    return CVDisplayLinkCreateWithCGDisplay(displays[0], linkOut);
}

CVReturn
CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *linkOut)
{
    return CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), linkOut);
}

CVReturn
CVDisplayLinkCreateWithOpenGLDisplayMask(CGOpenGLDisplayMask mask, CVDisplayLinkRef *linkOut)
{
    return CVDisplayLinkCreateWithActiveCGDisplays(linkOut);
}

CVDisplayLinkRef
CVDisplayLinkRetain(CVDisplayLinkRef link)
{
    if (link)
        CFRetain(link);
    return link;
}

void
CVDisplayLinkRelease(CVDisplayLinkRef link)
{
    if (link)
        CFRelease(link);
}

#pragma mark - Displays

CVReturn
CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef link, CGDirectDisplayID display)
{
    if (!link)
        return kCVReturnInvalidArgument;
    os_unfair_lock_lock(&link->lock);
    link->display = display;
    link->period = refresh_period(display);
    os_unfair_lock_unlock(&link->lock);
    return kCVReturnSuccess;
}

CVReturn
CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(CVDisplayLinkRef link, CGLContextObj context, CGLPixelFormatObj format)
{
    return link ? kCVReturnSuccess : kCVReturnInvalidArgument;
}

CGDirectDisplayID
CVDisplayLinkGetCurrentCGDisplay(CVDisplayLinkRef link)
{
    return link ? link->display : 0;
}

#pragma mark - Callbacks

CVReturn
CVDisplayLinkSetOutputCallback(CVDisplayLinkRef link, CVDisplayLinkOutputCallback callback, void *userInfo)
{
    if (!link)
        return kCVReturnInvalidArgument;
    os_unfair_lock_lock(&link->lock);
    link->callback = callback;
    link->userInfo = userInfo;
    os_unfair_lock_unlock(&link->lock);
    return kCVReturnSuccess;
}

CVReturn
CVDisplayLinkSetOutputHandler(CVDisplayLinkRef link, CVDisplayLinkOutputHandler handler)
{
    if (!link)
        return kCVReturnInvalidArgument;
    CVDisplayLinkOutputHandler copy = handler ? _Block_copy(handler) : NULL;
    os_unfair_lock_lock(&link->lock);
    CVDisplayLinkOutputHandler old = link->handler;
    link->handler = copy;
    os_unfair_lock_unlock(&link->lock);
    if (old)
        _Block_release(old);
    return kCVReturnSuccess;
}

static void
fill_time(CVTimeStamp *t, uint64_t host, int64_t frame, double period)
{
    memset(t, 0, sizeof *t);
    t->version = 0;
    t->videoTimeScale = kTimeScale;
    t->videoRefreshPeriod = (int64_t)(period * kTimeScale);
    t->videoTime = frame * t->videoRefreshPeriod;
    t->hostTime = host;
    t->rateScalar = 1.0;
    t->flags = kCVTimeStampVideoTimeValid | kCVTimeStampHostTimeValid | kCVTimeStampRateScalarValid |
               kCVTimeStampVideoRefreshPeriodValid;
}

static void
tick(CVDisplayLinkRef link)
{
    os_unfair_lock_lock(&link->lock);
    if (!link->running || link->paused) {
        os_unfair_lock_unlock(&link->lock);
        return;
    }
    CVDisplayLinkOutputCallback callback = link->callback;
    void *info = link->userInfo;
    CVDisplayLinkOutputHandler handler = link->handler ? _Block_copy(link->handler) : NULL;
    double period = link->period;
    int64_t frame = link->frame++;
    os_unfair_lock_unlock(&link->lock);

    mach_timebase_info_data_t tb = timebase();
    uint64_t now = mach_absolute_time();
    uint64_t ahead = (uint64_t)(period * 1e9 * tb.denom / tb.numer);
    CVTimeStamp inNow, inOutput;
    fill_time(&inNow, now, frame, period);
    fill_time(&inOutput, now + ahead, frame + 1, period);
    CVOptionFlags flagsOut = 0;
    if (handler) {
        handler(link, &inNow, &inOutput, 0, &flagsOut);
        _Block_release(handler);
    } else if (callback) {
        callback(link, &inNow, &inOutput, 0, &flagsOut, info);
    }
}

CVReturn
CVDisplayLinkStart(CVDisplayLinkRef link)
{
    if (!link)
        return kCVReturnInvalidArgument;
    os_unfair_lock_lock(&link->lock);
    if (link->running) {
        os_unfair_lock_unlock(&link->lock);
        return kCVReturnSuccess;
    }
    link->running = true;
    if (!link->timer) {
        link->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, link->queue);
        dispatch_source_set_event_handler(link->timer, ^{
          tick(link);
        });
        uint64_t ns = (uint64_t)(link->period * 1e9);
        dispatch_source_set_timer(link->timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns), ns, ns / 20);
        dispatch_resume(link->timer);
    }
    os_unfair_lock_unlock(&link->lock);
    return kCVReturnSuccess;
}

CVReturn
CVDisplayLinkStop(CVDisplayLinkRef link)
{
    if (!link)
        return kCVReturnInvalidArgument;
    os_unfair_lock_lock(&link->lock);
    dispatch_source_t timer = link->timer;
    link->timer = NULL;
    link->running = false;
    os_unfair_lock_unlock(&link->lock);
    if (timer) {
        dispatch_source_cancel(timer);
        dispatch_release(timer);
    }
    return kCVReturnSuccess;
}

/* Private: pause a running link without stopping its thread. */
void
CVDisplayLinkSetPaused(CVDisplayLinkRef link, bool paused)
{
    if (!link)
        return;
    os_unfair_lock_lock(&link->lock);
    link->paused = paused;
    os_unfair_lock_unlock(&link->lock);
}

Boolean
CVDisplayLinkIsRunning(CVDisplayLinkRef link)
{
    return link && link->running;
}

#pragma mark - Times

CVTime
CVDisplayLinkGetNominalOutputVideoRefreshPeriod(CVDisplayLinkRef link)
{
    if (!link)
        return kCVZeroTime;
    return (CVTime){.timeValue = (int64_t)(link->period * kTimeScale), .timeScale = kTimeScale, .flags = 0};
}

CVTime
CVDisplayLinkGetOutputVideoLatency(CVDisplayLinkRef link)
{
    return (CVTime){.timeValue = 0, .timeScale = kTimeScale, .flags = 0};
}

double
CVDisplayLinkGetActualOutputVideoRefreshPeriod(CVDisplayLinkRef link)
{
    return link ? link->period : 0;
}

CVReturn
CVDisplayLinkGetCurrentTime(CVDisplayLinkRef link, CVTimeStamp *outTime)
{
    if (!link || !outTime)
        return kCVReturnInvalidArgument;
    if (!link->running)
        return kCVReturnDisplayLinkNotRunning;
    os_unfair_lock_lock(&link->lock);
    int64_t frame = link->frame;
    double period = link->period;
    os_unfair_lock_unlock(&link->lock);
    fill_time(outTime, mach_absolute_time(), frame, period);
    return kCVReturnSuccess;
}

/* Converts between host and video times, the fields asked for in outTime->flags. */
CVReturn
CVDisplayLinkTranslateTime(CVDisplayLinkRef link, const CVTimeStamp *inTime, CVTimeStamp *outTime)
{
    if (!link || !inTime || !outTime)
        return kCVReturnInvalidArgument;
    mach_timebase_info_data_t tb = timebase();
    double hostPerVideo = (double)tb.denom / tb.numer; /* host ticks per nanosecond */
    uint64_t want = outTime->flags;
    CVTimeStamp t = *inTime;
    if (!(t.flags & kCVTimeStampHostTimeValid) && (t.flags & kCVTimeStampVideoTimeValid))
        t.hostTime = (uint64_t)(t.videoTime * hostPerVideo * kTimeScale / (t.videoTimeScale ? t.videoTimeScale : kTimeScale));
    if (!(t.flags & kCVTimeStampVideoTimeValid) && (t.flags & kCVTimeStampHostTimeValid)) {
        t.videoTimeScale = kTimeScale;
        t.videoTime = (int64_t)(t.hostTime / hostPerVideo);
    }
    t.videoRefreshPeriod = (int64_t)(link->period * kTimeScale);
    t.flags |= kCVTimeStampHostTimeValid | kCVTimeStampVideoTimeValid | kCVTimeStampVideoRefreshPeriodValid;
    t.flags &= want ? want | kCVTimeStampHostTimeValid | kCVTimeStampVideoTimeValid : ~0ull;
    *outTime = t;
    return kCVReturnSuccess;
}

const CVTime kCVZeroTime = {0, 1, 0};
const CVTime kCVIndefiniteTime = {0, 1, kCVTimeIsIndefinite};
