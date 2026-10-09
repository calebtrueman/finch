/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-ws-test: the window server and its client library in CoreGraphics
 * (docs/design/WINDOWSERVER.md). Starts a headless server on a private
 * socket, makes windows, draws into them, and checks the composited screen,
 * the window list, stacking, input routing and resizing. Finch-only (Apple
 * has no such API): its output is compared with ws-test.expected.
 *
 *   finch-ws-test [path to finch-windowserver]
 */
#include <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;

/* Finch CoreGraphics' client API */
bool FWSConnect(void);
bool FWSGetDisplayInfo(FWSDisplayInfo *out);
uint32_t FWSCreateWindow(FWSRect frame, int32_t level, uint32_t flags);
CGContextRef FWSCreateWindowContext(uint32_t window);
void FWSSetWindowFrame(uint32_t window, FWSRect frame);
void FWSDestroyWindow(uint32_t w);
void FWSOrderWindow(uint32_t w, int32_t mode, uint32_t relative);
void FWSSetWindowTitle(uint32_t w, const char *t);
void FWSFlushWindow(uint32_t w, FWSRect r);
void FWSMakeKeyWindow(uint32_t w);
void FWSSetCursorVisible(bool v);
void FWSPostEvent(const FWSEvent *e);
bool FWSNextEvent(FWSEvent *out, bool wait);
CGImageRef FWSCopyScreenImage(void);
void *FWSWindowBuffer(uint32_t window, uint32_t *pw, uint32_t *ph, uint32_t *bpr);

static CGImageRef screen;
static const uint8_t *pixels;
static size_t bpr;

static void
snapshot(void)
{
    if (screen)
        CGImageRelease(screen);
    screen = FWSCopyScreenImage();
    CFDataRef d = CGDataProviderCopyData(CGImageGetDataProvider(screen));
    pixels = CFDataGetBytePtr(d);  /* kept for the test's life */
    bpr = CGImageGetBytesPerRow(screen);
}

/* The screen at a point (in points), as R G B A. */
static void
sample(const char *label, double x, double y)
{
    size_t px = (size_t)(x * 2), py = (size_t)(y * 2);
    const uint8_t *p = pixels + py * bpr + px * 4;
    printf("%s (%g,%g): %d %d %d %d\n", label, x, y, p[2], p[1], p[0], p[3]);
}

static void
fill(uint32_t w, double r, double g, double b, double a)
{
    CGContextRef c = FWSCreateWindowContext(w);
    CGContextClearRect(c, CGRectMake(0, 0, 10000, 10000));
    CGContextSetRGBFillColor(c, r, g, b, a);
    CGContextFillRect(c, CGRectMake(0, 0, 10000, 10000));
    CGContextRelease(c);
    FWSFlushWindow(w, (FWSRect){0, 0, 0, 0});
}

static void
event(uint32_t type, double x, double y, uint32_t key)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = x, e.screen_y = y;
    e.key_code = key;
    FWSPostEvent(&e);
}

static void
expect_event(const char *label)
{
    FWSEvent e;
    if (FWSNextEvent(&e, true))
        printf("%s: type %u window %u at %g,%g clicks %u key %u\n", label, e.type, e.window, e.x, e.y, e.click_count,
               e.key_code);
    else
        printf("%s: none\n", label);
}

static void
list(const char *label)
{
    CFArrayRef a = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    printf("%s:", label);
    for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(a, i);
        int64_t n;
        CFNumberGetValue(CFDictionaryGetValue(d, kCGWindowNumber), kCFNumberSInt64Type, &n);
        CGRect r;
        CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(d, kCGWindowBounds), &r);
        char title[64] = "";
        CFStringRef t = CFDictionaryGetValue(d, kCGWindowName);
        if (t)
            CFStringGetCString(t, title, sizeof title, kCFStringEncodingUTF8);
        printf(" [%lld \"%s\" %g,%g %gx%g%s]", n, title, r.origin.x, r.origin.y, r.size.width, r.size.height,
               CFDictionaryContainsKey(d, kCGWindowIsOnscreen) ? " on" : "");
    }
    printf("\n");
    CFRelease(a);
}

int
main(int argc, char **argv)
{
    const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
    char sock[64];
    snprintf(sock, sizeof sock, "/tmp/finch-ws-test.%d", getpid());
    setenv(FWS_SOCKET_ENV, sock, 1);
    pid_t pid;
    char *args[] = {(char *)server, "--headless", "--size", "400x300", "--scale", "2", NULL};
    if (posix_spawn(&pid, server, NULL, NULL, args, environ)) {
        printf("can't start %s\n", server);
        return 1;
    }
    for (int i = 0; i < 100 && !FWSConnect(); i++)
        usleep(20000);
    FWSDisplayInfo d;
    printf("connected: %d\n", FWSGetDisplayInfo(&d));
    FWSSetCursorVisible(false);  /* keep the cursor out of the sampled pixels */
    printf("display: %gx%g scale %g refresh %g\n", d.width, d.height, d.scale, d.refresh);
    printf("main display bounds: %g %g\n", CGDisplayBounds(CGMainDisplayID()).size.width,
           CGDisplayBounds(CGMainDisplayID()).size.height);

    uint32_t a = FWSCreateWindow((FWSRect){50, 40, 200, 150}, 0, FWS_WINDOW_OPAQUE);
    uint32_t b = FWSCreateWindow((FWSRect){150, 120, 200, 120}, 0, 0);
    uint32_t pw, ph, row;
    FWSWindowBuffer(a, &pw, &ph, &row);
    printf("window %u buffer %ux%u, row %u\n", a, pw, ph, row);
    FWSSetWindowTitle(a, "Red");
    FWSSetWindowTitle(b, "Blue");
    fill(a, 1, 0, 0, 1);
    fill(b, 0, 0, 1, 0.5);
    list("before ordering");
    snapshot();
    sample("desktop where a would be", 100, 100);
    FWSOrderWindow(a, FWS_ORDER_ABOVE, 0);
    FWSOrderWindow(b, FWS_ORDER_ABOVE, 0);
    snapshot();
    sample("a only", 60, 50);
    sample("overlap, b above", 200, 150);
    sample("b only", 300, 220);
    sample("desktop", 10, 10);
    list("ordered");
    FWSOrderWindow(a, FWS_ORDER_ABOVE, b);
    snapshot();
    sample("overlap, a above", 200, 150);
    list("a above b");

    /* input */
    event(FWS_EVENT_LEFT_DOWN, 300, 220, 0);
    expect_event("click in b");
    event(FWS_EVENT_LEFT_DRAGGED, 100, 60, 0);
    expect_event("drag captured by b");
    event(FWS_EVENT_LEFT_UP, 100, 60, 0);
    expect_event("release to b");
    event(FWS_EVENT_LEFT_DOWN, 100, 60, 0);
    expect_event("click in a");
    event(FWS_EVENT_LEFT_UP, 100, 60, 0);
    expect_event("release in a");
    event(FWS_EVENT_LEFT_DOWN, 100, 60, 0);
    expect_event("double click in a");
    event(FWS_EVENT_LEFT_UP, 100, 60, 0);
    expect_event("release");
    FWSMakeKeyWindow(b);
    event(FWS_EVENT_KEY_DOWN, 0, 0, 0x00);
    expect_event("key to b");
    event(FWS_EVENT_MOUSE_MOVED, 10, 10, 0);
    event(FWS_EVENT_KEY_UP, 0, 0, 0x00);
    expect_event("key up to b (moving over the desktop sends nothing)");

    /* move and resize */
    FWSSetWindowFrame(a, (FWSRect){0, 0, 100, 80});
    FWSWindowBuffer(a, &pw, &ph, &row);
    printf("resized buffer %ux%u, row %u\n", pw, ph, row);
    fill(a, 0, 1, 0, 1);
    snapshot();
    sample("moved and resized a", 20, 20);
    sample("where a was", 60, 100);
    FWSOrderWindow(b, FWS_ORDER_OUT, 0);
    snapshot();
    sample("b ordered out", 300, 220);
    list("b out");
    FWSDestroyWindow(a);
    list("a destroyed");

    kill(pid, SIGTERM);
    waitpid(pid, NULL, 0);
    unlink(sock);
    return 0;
}
