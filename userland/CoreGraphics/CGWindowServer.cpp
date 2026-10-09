/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The window server's client side (docs/design/WINDOWSERVER.md): Finch's
 * own FWS* functions, which Finch's AppKit uses for windows and events, and
 * CoreGraphics' public display and window-list API built on them.
 */
#include "CGInternal.h"
#include "../WindowServer/FinchWSProtocol.h"
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <deque>
#include <map>
#include <vector>

#define FWS_EXPORT extern "C" __attribute__((visibility("default")))

namespace {
struct Mapping {
    void *ptr;
    size_t length;
    uint32_t pw, ph, bpr;
};
}  // namespace

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int ws_fd = -1;
static uint32_t serial = 1;
static FWSDisplayInfo display;
static std::deque<FWSEvent> *pending;
static std::map<uint32_t, Mapping> *buffers;
static std::vector<uint8_t> *inbox;
static void (*event_callback)(const FWSEvent *, void *);
static void *event_info;
static bool active;

#pragma mark - Transport

static bool
write_all(const void *buf, size_t len)
{
    const char *p = (const char *)buf;
    while (len) {
        ssize_t n = write(ws_fd, p, len);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        p += n, len -= (size_t)n;
    }
    return true;
}

static uint32_t
send_request(uint32_t type, uint32_t window, const void *body, size_t size, bool want_reply)
{
    uint32_t s = want_reply ? serial++ : 0;
    FWSHeader h = {type, (uint32_t)size, s, window};
    std::vector<uint8_t> buf(sizeof h + size);
    memcpy(buf.data(), &h, sizeof h);
    if (size)
        memcpy(buf.data() + sizeof h, body, size);
    write_all(buf.data(), buf.size());
    return s;
}

/* Read more bytes (and any passed fd) into the inbox. */
static bool
receive(int *passed_fd)
{
    uint8_t buf[65536];
    struct msghdr msg = {};
    struct iovec iov = {buf, sizeof buf};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    char control[CMSG_SPACE(sizeof(int))];
    msg.msg_control = control;
    msg.msg_controllen = sizeof control;
    ssize_t n;
    do
        n = recvmsg(ws_fd, &msg, 0);
    while (n < 0 && errno == EINTR);
    if (n <= 0)
        return false;
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm))
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS && passed_fd)
            memcpy(passed_fd, CMSG_DATA(cm), sizeof(int));
    inbox->insert(inbox->end(), buf, buf + n);
    return true;
}

static void
note_event(const FWSHeader &h, const uint8_t *body)
{
    if (h.type == FWS_EVENT && h.size >= sizeof(FWSEvent)) {
        FWSEvent e;
        memcpy(&e, body, sizeof e);
        pending->push_back(e);
    } else if (h.type == FWS_ACTIVATED && h.size >= sizeof(FWSActivated)) {
        active = ((const FWSActivated *)body)->active != 0;
    } else if (h.type == FWS_DISPLAY_CHANGED && h.size >= sizeof(FWSDisplayInfo)) {
        memcpy(&display, body, sizeof display);
    }
}

/* Take complete messages off the inbox: events are queued; the reply with `want` is returned. */
static bool
drain(uint32_t want, std::vector<uint8_t> *reply)
{
    size_t off = 0;
    bool got = false;
    while (inbox->size() - off >= sizeof(FWSHeader)) {
        FWSHeader h;
        memcpy(&h, inbox->data() + off, sizeof h);
        if (inbox->size() - off < sizeof h + h.size)
            break;
        const uint8_t *body = inbox->data() + off + sizeof h;
        if (h.type == FWS_REPLY && want && h.serial == want && !got) {
            reply->assign(body, body + h.size);
            got = true;
        } else {
            note_event(h, body);
        }
        off += sizeof h + h.size;
    }
    inbox->erase(inbox->begin(), inbox->begin() + (long)off);
    return got;
}

static bool
wait_reply(uint32_t s, std::vector<uint8_t> *reply, int *fd)
{
    if (fd)
        *fd = -1;
    for (;;) {
        if (drain(s, reply))
            return true;
        if (!receive(fd))
            return false;
    }
}

static bool
connect_locked(void)
{
    if (ws_fd >= 0)
        return true;
    if (!pending) {
        pending = new std::deque<FWSEvent>();
        buffers = new std::map<uint32_t, Mapping>();
        inbox = new std::vector<uint8_t>();
    }
    const char *path = getenv(FWS_SOCKET_ENV) ? getenv(FWS_SOCKET_ENV) : FWS_SOCKET_DEFAULT;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {};
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", path);
    if (fd < 0 || strlen(path) >= sizeof addr.sun_path || connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        if (fd >= 0)
            close(fd);
        return false;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    ws_fd = fd;
    FWSHello hello = {FWS_PROTOCOL_VERSION, getpid(), {0}};
    const char *name = getprogname();
    snprintf(hello.name, sizeof hello.name, "%s", name ? name : "");
    std::vector<uint8_t> reply;
    uint32_t s = send_request(FWS_HELLO, 0, &hello, sizeof hello, true);
    if (!wait_reply(s, &reply, NULL) || reply.size() < sizeof display) {
        close(ws_fd);
        ws_fd = -1;
        return false;
    }
    memcpy(&display, reply.data(), sizeof display);
    return true;
}

#pragma mark - Finch's client API

FWS_EXPORT bool
FWSConnect(void)
{
    pthread_mutex_lock(&lock);
    bool ok = connect_locked();
    pthread_mutex_unlock(&lock);
    return ok;
}

FWS_EXPORT int
FWSConnectionFileDescriptor(void)
{
    return FWSConnect() ? ws_fd : -1;
}

FWS_EXPORT bool
FWSGetDisplayInfo(FWSDisplayInfo *out)
{
    if (!FWSConnect())
        return false;
    *out = display;
    return true;
}

static void
map_buffer(const FWSBuffer &b, int fd)
{
    auto it = buffers->find(b.window);
    if (it != buffers->end()) {
        munmap(it->second.ptr, it->second.length);
        buffers->erase(it);
    }
    if (fd < 0)
        return;
    void *p = mmap(NULL, (size_t)b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p != MAP_FAILED)
        (*buffers)[b.window] = {p, (size_t)b.length, b.pixel_width, b.pixel_height, b.bytes_per_row};
}

FWS_EXPORT uint32_t
FWSCreateWindow(FWSRect frame, int32_t level, uint32_t flags)
{
    pthread_mutex_lock(&lock);
    uint32_t id = 0;
    if (connect_locked()) {
        FWSWindowSpec spec = {frame, level, flags};
        std::vector<uint8_t> reply;
        int fd;
        uint32_t s = send_request(FWS_CREATE_WINDOW, 0, &spec, sizeof spec, true);
        if (wait_reply(s, &reply, &fd) && reply.size() >= sizeof(FWSBuffer)) {
            FWSBuffer b;
            memcpy(&b, reply.data(), sizeof b);
            id = b.window;
            if (id)
                map_buffer(b, fd);
            else if (fd >= 0)
                close(fd);
        }
    }
    pthread_mutex_unlock(&lock);
    return id;
}

/* The window's buffer: BGRA premultiplied, little-endian 32-bit ((uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little). */
FWS_EXPORT void *
FWSWindowBuffer(uint32_t window, uint32_t *pixel_width, uint32_t *pixel_height, uint32_t *bytes_per_row)
{
    pthread_mutex_lock(&lock);
    void *p = NULL;
    if (buffers) {
        auto it = buffers->find(window);
        if (it != buffers->end()) {
            p = it->second.ptr;
            if (pixel_width)
                *pixel_width = it->second.pw;
            if (pixel_height)
                *pixel_height = it->second.ph;
            if (bytes_per_row)
                *bytes_per_row = it->second.bpr;
        }
    }
    pthread_mutex_unlock(&lock);
    return p;
}

/* A bitmap context over the window's buffer, in points with the origin at the bottom left. */
FWS_EXPORT CGContextRef
FWSCreateWindowContext(uint32_t window)
{
    uint32_t pw, ph, bpr;
    void *p = FWSWindowBuffer(window, &pw, &ph, &bpr);
    if (!p)
        return NULL;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(p, pw, ph, 8, bpr, srgb,
                                           (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(srgb);
    if (c)
        CGContextScaleCTM(c, display.scale, display.scale);
    return c;
}

FWS_EXPORT void
FWSSetWindowFrame(uint32_t window, FWSRect frame)
{
    pthread_mutex_lock(&lock);
    if (connect_locked()) {
        FWSWindowSpec spec = {frame, 0, 0};
        std::vector<uint8_t> reply;
        int fd;
        uint32_t s = send_request(FWS_SET_FRAME, window, &spec, sizeof spec, true);
        if (wait_reply(s, &reply, &fd) && reply.size() >= sizeof(FWSBuffer)) {
            FWSBuffer b;
            memcpy(&b, reply.data(), sizeof b);
            if (fd >= 0)
                map_buffer(b, fd);
        }
    }
    pthread_mutex_unlock(&lock);
}

static void
simple(uint32_t type, uint32_t window, const void *body, size_t size)
{
    pthread_mutex_lock(&lock);
    if (connect_locked())
        send_request(type, window, body, size, false);
    pthread_mutex_unlock(&lock);
}

FWS_EXPORT void FWSDestroyWindow(uint32_t w)
{
    simple(FWS_DESTROY_WINDOW, w, NULL, 0);
    pthread_mutex_lock(&lock);
    if (buffers) {
        auto it = buffers->find(w);
        if (it != buffers->end()) {
            munmap(it->second.ptr, it->second.length);
            buffers->erase(it);
        }
    }
    pthread_mutex_unlock(&lock);
}

FWS_EXPORT void FWSOrderWindow(uint32_t w, int32_t mode, uint32_t relative) { FWSOrder o = {mode, relative}; simple(FWS_ORDER, w, &o, sizeof o); }
FWS_EXPORT void FWSSetWindowLevel(uint32_t w, int32_t level) { FWSInt v = {level}; simple(FWS_SET_LEVEL, w, &v, sizeof v); }
FWS_EXPORT void FWSSetWindowAlpha(uint32_t w, double alpha) { FWSDouble v = {alpha}; simple(FWS_SET_ALPHA, w, &v, sizeof v); }
FWS_EXPORT void FWSSetWindowFlags(uint32_t w, uint32_t flags) { FWSInt v = {(int32_t)flags}; simple(FWS_SET_FLAGS, w, &v, sizeof v); }
FWS_EXPORT void FWSSetWindowTitle(uint32_t w, const char *t) { simple(FWS_SET_TITLE, w, t, t ? strlen(t) : 0); }
FWS_EXPORT void FWSFlushWindow(uint32_t w, FWSRect r) { FWSFlush f = {r}; simple(FWS_FLUSH, w, &f, sizeof f); }
FWS_EXPORT void FWSMakeKeyWindow(uint32_t w) { simple(FWS_MAKE_KEY, w, NULL, 0); }
FWS_EXPORT void FWSWarpCursor(double x, double y) { FWSPoint p = {x, y}; simple(FWS_WARP_CURSOR, 0, &p, sizeof p); }
FWS_EXPORT void FWSSetCursorVisible(bool v) { FWSInt i = {v}; simple(FWS_SET_CURSOR_VISIBLE, 0, &i, sizeof i); }
FWS_EXPORT void FWSPostEvent(const FWSEvent *e) { simple(FWS_POST_EVENT, 0, e, sizeof *e); }
FWS_EXPORT bool FWSIsActive(void) { return active; }

FWS_EXPORT void
FWSSetCursorShape(int32_t shape)
{
    FWSCursor c = {shape, 0, 0, 0, 0};
    simple(FWS_SET_CURSOR, 0, &c, sizeof c);
}

/* The window list, front to back; free() the result. */
FWS_EXPORT FWSWindowInfo *
FWSCopyWindowList(uint32_t *count)
{
    *count = 0;
    pthread_mutex_lock(&lock);
    FWSWindowInfo *out = NULL;
    if (connect_locked()) {
        std::vector<uint8_t> reply;
        uint32_t s = send_request(FWS_WINDOW_LIST, 0, NULL, 0, true);
        if (wait_reply(s, &reply, NULL) && reply.size() >= 4) {
            uint32_t n;
            memcpy(&n, reply.data(), 4);
            if (reply.size() >= 4 + (size_t)n * sizeof(FWSWindowInfo)) {
                out = (FWSWindowInfo *)malloc(n * sizeof(FWSWindowInfo) + 1);
                memcpy(out, reply.data() + 4, n * sizeof(FWSWindowInfo));
                *count = n;
            }
        }
    }
    pthread_mutex_unlock(&lock);
    return out;
}

/* The composited screen (tests): an image of the display, in pixels. */
FWS_EXPORT CGImageRef
FWSCopyScreenImage(void)
{
    pthread_mutex_lock(&lock);
    CGImageRef im = NULL;
    if (connect_locked()) {
        std::vector<uint8_t> reply;
        int fd;
        uint32_t s = send_request(FWS_SNAPSHOT, 0, NULL, 0, true);
        if (wait_reply(s, &reply, &fd) && reply.size() >= sizeof(FWSBuffer) && fd >= 0) {
            FWSBuffer b;
            memcpy(&b, reply.data(), sizeof b);
            void *p = mmap(NULL, (size_t)b.length, PROT_READ, MAP_SHARED, fd, 0);
            close(fd);
            if (p != MAP_FAILED) {
                CFDataRef data = CFDataCreate(NULL, (const UInt8 *)p, (CFIndex)b.length);
                munmap(p, (size_t)b.length);
                CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
                CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                im = CGImageCreate(b.pixel_width, b.pixel_height, 8, 32, b.bytes_per_row, srgb,
                                   (uint32_t)kCGImageAlphaPremultipliedFirst | (uint32_t)kCGBitmapByteOrder32Little, prov, NULL, false,
                                   kCGRenderingIntentDefault);
                CFRelease(srgb), CFRelease(prov), CFRelease(data);
            }
        }
    }
    pthread_mutex_unlock(&lock);
    return im;
}

/* The next event received, without waiting (false if none). */
FWS_EXPORT bool
FWSNextEvent(FWSEvent *out, bool wait)
{
    pthread_mutex_lock(&lock);
    bool got = false;
    if (connect_locked()) {
        for (;;) {
            drain(0, NULL);
            if (!pending->empty()) {
                *out = pending->front();
                pending->pop_front();
                got = true;
                break;
            }
            if (!wait)
                break;
            if (!receive(NULL))
                break;
        }
    }
    pthread_mutex_unlock(&lock);
    return got;
}

/* Deliver events on the main run loop as they arrive. */
static void
readable(CFFileDescriptorRef fdref, CFOptionFlags flags, void *info)
{
    pthread_mutex_lock(&lock);
    if (ws_fd >= 0 && receive(NULL))
        drain(0, NULL);
    pthread_mutex_unlock(&lock);
    FWSEvent e;
    while (FWSNextEvent(&e, false))
        if (event_callback)
            event_callback(&e, event_info);
    CFFileDescriptorEnableCallBacks(fdref, kCFFileDescriptorReadCallBack);
}

FWS_EXPORT bool
FWSSetEventHandler(void (*callback)(const FWSEvent *, void *), void *info)
{
    if (!FWSConnect())
        return false;
    event_callback = callback;
    event_info = info;
    static CFFileDescriptorRef source;
    if (!source) {
        source = CFFileDescriptorCreate(NULL, ws_fd, false, readable, NULL);
        CFRunLoopSourceRef rls = CFFileDescriptorCreateRunLoopSource(NULL, source, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, kCFRunLoopCommonModes);
        CFRelease(rls);
        CFFileDescriptorEnableCallBacks(source, kCFFileDescriptorReadCallBack);
    }
    return true;
}

#pragma mark - CoreGraphics' display API

CGDirectDisplayID
CGMainDisplayID(void)
{
    FWSDisplayInfo d;
    return FWSGetDisplayInfo(&d) ? d.display : 1;
}

CGError
CGGetActiveDisplayList(uint32_t max, CGDirectDisplayID *displays, uint32_t *count)
{
    FWSDisplayInfo d;
    bool ok = FWSGetDisplayInfo(&d);
    if (count)
        *count = ok ? 1 : 0;
    if (ok && displays && max >= 1)
        displays[0] = d.display;
    return kCGErrorSuccess;
}

CGError
CGGetOnlineDisplayList(uint32_t max, CGDirectDisplayID *displays, uint32_t *count)
{
    return CGGetActiveDisplayList(max, displays, count);
}

CGError
CGGetDisplaysWithPoint(CGPoint point, uint32_t max, CGDirectDisplayID *displays, uint32_t *count)
{
    FWSDisplayInfo d;
    bool in = FWSGetDisplayInfo(&d) && point.x >= 0 && point.y >= 0 && point.x < d.width && point.y < d.height;
    if (count)
        *count = in ? 1 : 0;
    if (in && displays && max)
        displays[0] = d.display;
    return kCGErrorSuccess;
}

CGError
CGGetDisplaysWithRect(CGRect rect, uint32_t max, CGDirectDisplayID *displays, uint32_t *count)
{
    FWSDisplayInfo d;
    bool in = FWSGetDisplayInfo(&d) && CGRectIntersectsRect(rect, CGRectMake(0, 0, d.width, d.height));
    if (count)
        *count = in ? 1 : 0;
    if (in && displays && max)
        displays[0] = d.display;
    return kCGErrorSuccess;
}

CGRect
CGDisplayBounds(CGDirectDisplayID display)
{
    FWSDisplayInfo d;
    if (!FWSGetDisplayInfo(&d) || display != d.display)
        return CGRectZero;
    return CGRectMake(0, 0, d.width, d.height);
}

size_t
CGDisplayPixelsWide(CGDirectDisplayID display)
{
    return (size_t)CGDisplayBounds(display).size.width;
}

size_t
CGDisplayPixelsHigh(CGDirectDisplayID display)
{
    return (size_t)CGDisplayBounds(display).size.height;
}

boolean_t CGDisplayIsMain(CGDirectDisplayID display) { return display == CGMainDisplayID(); }
boolean_t CGDisplayIsActive(CGDirectDisplayID display) { return display == CGMainDisplayID(); }
boolean_t CGDisplayIsOnline(CGDirectDisplayID display) { return display == CGMainDisplayID(); }
boolean_t CGDisplayIsBuiltin(CGDirectDisplayID display) { return display == CGMainDisplayID(); }
uint32_t CGDisplayUnitNumber(CGDirectDisplayID display) { return 0; }
uint32_t CGDisplayVendorNumber(CGDirectDisplayID display) { return 0; }
uint32_t CGDisplayModelNumber(CGDirectDisplayID display) { return 0; }
uint32_t CGDisplaySerialNumber(CGDirectDisplayID display) { return 0; }
double CGDisplayRotation(CGDirectDisplayID display) { return 0; }

CGSize
CGDisplayScreenSize(CGDirectDisplayID display)
{
    /* millimetres, at about 110 points per inch */
    CGRect b = CGDisplayBounds(display);
    return CGSizeMake(b.size.width / 110 * 25.4, b.size.height / 110 * 25.4);
}

CGError
CGDisplayMoveCursorToPoint(CGDirectDisplayID display, CGPoint point)
{
    FWSWarpCursor(point.x, point.y);
    return kCGErrorSuccess;
}

CGError
CGWarpMouseCursorPosition(CGPoint point)
{
    FWSWarpCursor(point.x, point.y);
    return kCGErrorSuccess;
}

CGError CGDisplayHideCursor(CGDirectDisplayID display) { FWSSetCursorVisible(false); return kCGErrorSuccess; }
CGError CGDisplayShowCursor(CGDirectDisplayID display) { FWSSetCursorVisible(true); return kCGErrorSuccess; }
CGError CGAssociateMouseAndMouseCursorPosition(boolean_t connected) { return kCGErrorSuccess; }

#pragma mark - The window list

static CFNumberRef
num(int64_t v)
{
    return CFNumberCreate(NULL, kCFNumberSInt64Type, &v);
}

static void
put(CFMutableDictionaryRef d, CFStringRef k, CFTypeRef v)
{
    if (v) {
        CFDictionarySetValue(d, k, v);
        CFRelease(v);
    }
}

CFArrayRef
CGWindowListCopyWindowInfo(CGWindowListOption option, CGWindowID relativeToWindow)
{
    uint32_t n;
    FWSWindowInfo *list = FWSCopyWindowList(&n);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    bool after = false, seen_relative = false;
    for (uint32_t i = 0; i < n; i++) {
        FWSWindowInfo &w = list[i];
        if ((option & kCGWindowListOptionOnScreenOnly) && !w.on_screen)
            continue;
        if (option & kCGWindowListOptionIncludingWindow) {
            if (w.window != relativeToWindow)
                continue;
        }
        if (option & (kCGWindowListOptionOnScreenAboveWindow | kCGWindowListOptionOnScreenBelowWindow)) {
            if (w.window == relativeToWindow) {
                seen_relative = true;
                after = true;
                continue;
            }
            if ((option & kCGWindowListOptionOnScreenAboveWindow) && seen_relative)
                continue;
            if ((option & kCGWindowListOptionOnScreenBelowWindow) && !after)
                continue;
        }
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
        put(d, kCGWindowNumber, num(w.window));
        put(d, kCGWindowLayer, num(w.level));
        put(d, kCGWindowOwnerPID, num(w.pid));
        put(d, kCGWindowSharingState, num(kCGWindowSharingReadOnly));
        put(d, kCGWindowStoreType, num(kCGBackingStoreBuffered));
        put(d, kCGWindowMemoryUsage, num((int64_t)(w.frame.width * w.frame.height * 4)));
        CFNumberRef alpha = CFNumberCreate(NULL, kCFNumberDoubleType, &w.alpha);
        put(d, kCGWindowAlpha, alpha);
        put(d, kCGWindowBounds,
            CGRectCreateDictionaryRepresentation(CGRectMake(w.frame.x, w.frame.y, w.frame.width, w.frame.height)));
        put(d, kCGWindowOwnerName, CFStringCreateWithCString(NULL, w.owner, kCFStringEncodingUTF8));
        if (w.title[0])
            put(d, kCGWindowName, CFStringCreateWithCString(NULL, w.title, kCFStringEncodingUTF8));
        if (w.on_screen)
            CFDictionarySetValue(d, kCGWindowIsOnscreen, kCFBooleanTrue);
        CFArrayAppendValue(out, d);
        CFRelease(d);
    }
    free(list);
    return out;
}

CFArrayRef
CGWindowListCreate(CGWindowListOption option, CGWindowID relativeToWindow)
{
    CFArrayRef info = CGWindowListCopyWindowInfo(option, relativeToWindow);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, NULL);
    for (CFIndex i = 0; i < CFArrayGetCount(info); i++) {
        CFNumberRef n = (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)CFArrayGetValueAtIndex(info, i), kCGWindowNumber);
        int64_t v;
        CFNumberGetValue(n, kCFNumberSInt64Type, &v);
        CFArrayAppendValue(out, (const void *)(uintptr_t)v);
    }
    CFRelease(info);
    return out;
}

CFArrayRef
CGWindowListCreateDescriptionFromArray(CFArrayRef windowArray)
{
    CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; windowArray && i < CFArrayGetCount(windowArray); i++) {
        uintptr_t want = (uintptr_t)CFArrayGetValueAtIndex(windowArray, i);
        for (CFIndex k = 0; k < CFArrayGetCount(all); k++) {
            CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(all, k);
            int64_t v;
            CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(d, kCGWindowNumber), kCFNumberSInt64Type, &v);
            if ((uintptr_t)v == want)
                CFArrayAppendValue(out, d);
        }
    }
    CFRelease(all);
    return out;
}

#define KEY(n) const CFStringRef n = CFSTR(#n);
extern "C" {
KEY(kCGWindowNumber)
KEY(kCGWindowStoreType)
KEY(kCGWindowLayer)
KEY(kCGWindowBounds)
KEY(kCGWindowSharingState)
KEY(kCGWindowAlpha)
KEY(kCGWindowOwnerPID)
KEY(kCGWindowMemoryUsage)
KEY(kCGWindowWorkspace)
KEY(kCGWindowOwnerName)
KEY(kCGWindowName)
KEY(kCGWindowIsOnscreen)
KEY(kCGWindowBackingLocationVideoMemory)
}
