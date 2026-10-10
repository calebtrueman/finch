/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-text-window-test: a text view in a scroll view on Finch's
 * window server, end to end. Starts a headless server, shows a window
 * holding them, and checks that clicks place the insertion point and
 * select words, that typed keys insert text and arrows move, that the
 * standard editing equivalents (Command-A, -C, -V, -Z) work without a menu,
 * that the scroll wheel scrolls, and that text, the selection and
 * scrolling reach the screen. Finch-only (it drives Finch's server):
 * compare with appkit-text-window-test.expected.
 *
 *   finch-appkit-text-window-test [path to finch-windowserver] [Roboto-Regular.ttf]
 */
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
CGImageRef FWSCopyScreenImage(void);
void FWSSetCursorVisible(bool v);

static void
pump(double seconds)
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    for (;;) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
        if (!e)
            break;
        [NSApp sendEvent:e];
    }
    [NSApp updateWindows];
}

static CFDataRef screen;
static size_t screen_bpr;

static void
snapshot(void)
{
    if (screen)
        CFRelease(screen);
    CGImageRef im = FWSCopyScreenImage();
    screen = CGDataProviderCopyData(CGImageGetDataProvider(im));
    screen_bpr = CGImageGetBytesPerRow(im);
    CGImageRelease(im);
}

static const uint8_t *
pixel(double x, double y)
{
    return CFDataGetBytePtr(screen) + (size_t)(y * 2) * screen_bpr + (size_t)(x * 2) * 4;
}

/* How many pixels in a rect (server points, y down) are dark (text) or the selection's color. */
static void
count(const char *label, double x, double y, double w, double h)
{
    int dark = 0, blue = 0;
    /* the theme's selection color (Fieldwork's green, the classic theme's blue) */
    NSColor *sc = [[NSColor selectedTextBackgroundColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    int sr = (int)([sc redComponent] * 255), sg = (int)([sc greenComponent] * 255), sb = (int)([sc blueComponent] * 255);
    for (double yy = y; yy < y + h; yy += 0.5)
        for (double xx = x; xx < x + w; xx += 0.5) {
            const uint8_t *p = pixel(xx, yy);
            if (p[2] < 128 && p[1] < 128 && p[0] < 128)
                dark++;
            if (abs(p[2] - sr) < 16 && abs(p[1] - sg) < 16 && abs(p[0] - sb) < 16)
                blue++;
        }
    printf("%s: text %s selection %s\n", label, dark > 20 ? "yes" : dark ? "few" : "no", blue > 50 ? "yes" : "no");
}

/* A hash of a region's pixels, to tell whether what is drawn there changed. */
static uint64_t
region_hash(double x, double y, double w, double h)
{
    uint64_t hash = 1469598103934665603ull;
    for (double yy = y; yy < y + h; yy += 0.5)
        for (double xx = x; xx < x + w; xx += 0.5) {
            const uint8_t *p = pixel(xx, yy);
            for (int i = 0; i < 3; i++)
                hash = (hash ^ p[i]) * 1099511628211ull;
        }
    return hash;
}

static void
post(uint32_t type, double x, double y, unichar c, uint32_t code, uint64_t flags)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = x, e.screen_y = y;
    e.modifiers = flags;
    e.key_code = code;
    if (c) {
        e.characters[0] = e.unmodified[0] = c;
        e.length = 1;
    }
    FWSPostEvent(&e);
}

static void
click(double x, double y, int times)
{
    for (int i = 0; i < times; i++) {
        post(FWS_EVENT_LEFT_DOWN, x, y, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, x, y, 0, 0, 0);
    }
}

static void
key(unichar c, uint32_t code, uint64_t flags)
{
    post(FWS_EVENT_KEY_DOWN, 0, 0, c, code, flags);
    post(FWS_EVENT_KEY_UP, 0, 0, c, code, flags);
}

static void
type(const char *s)
{
    for (; *s; s++)
        key((unichar)*s, 0, 0);
}

static void
scroll(double x, double y, double dy)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = FWS_EVENT_SCROLL;
    e.screen_x = x, e.screen_y = y;
    e.delta_y = dy;
    FWSPostEvent(&e);
}

static NSString *
V(NSString *s)
{
    return [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
}

@interface Watcher : NSObject <NSTextViewDelegate>
@property NSMutableArray<NSString *> *log;
@end

@implementation Watcher
- (void)textDidBeginEditing:(NSNotification *)n
{
    [self.log addObject:@"didBegin"];
}
- (void)textDidEndEditing:(NSNotification *)n
{
    [self.log addObject:@"didEnd"];
}
@end

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = "/usr/libexec/finch-windowserver", *font = NULL;
        for (int i = 1; i < argc; i++) {
            if (strstr(argv[i], ".ttf"))
                font = argv[i];
            else
                server = argv[i];
        }
        const char *fonts[] = {font, "/usr/local/share/finch/test-fonts/Roboto-Regular.ttf",
                               "build/src/skia/resources/fonts/Roboto-Regular.ttf"};
        for (size_t i = 0; i < 3; i++)
            if (fonts[i] && !access(fonts[i], R_OK)) {
                CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(fonts[i])],
                                                 kCTFontManagerScopeProcess, NULL);
                break;
            }
        NSFont *roboto = [NSFont fontWithName:@"Roboto-Regular" size:14];
        if (!roboto) {
            printf("no Roboto\n");
            return 1;
        }
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-atwt.%d", getpid());
        setenv(FWS_SOCKET_ENV, sock, 1);
        pid_t pid;
        char *args[] = {(char *)server, "--headless", "--size", "800x600", "--scale", "2", NULL};
        if (posix_spawn(&pid, server, NULL, NULL, args, environ)) {
            printf("can't start %s\n", server);
            return 1;
        }
        for (int i = 0; i < 100 && !FWSConnect(); i++)
            usleep(20000);
        FWSSetCursorVisible(false);

        [NSApplication sharedApplication];
        [NSApp finishLaunching];
        /* content 300x200 at (100,100): in the server's coordinates, x 100-400, y 300-500 */
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 300, 200)
                                                  styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered
                                                      defer:YES];
        w.releasedWhenClosed = NO;
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
        sv.hasVerticalScroller = YES;
        NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
        tv.font = roboto;
        tv.richText = NO;
        tv.allowsUndo = YES;
        tv.minSize = NSMakeSize(0, 200);
        tv.maxSize = NSMakeSize(1e7, 1e7);
        tv.autoresizingMask = NSViewWidthSizable;
        Watcher *watcher = [Watcher new];
        watcher.log = [NSMutableArray array];
        tv.delegate = watcher;
        sv.documentView = tv;
        w.contentView = sv;
        [w makeKeyAndOrderFront:nil];
        pump(0.3);
        printf("first responder is the text view %d\n", w.firstResponder == tv);

        /* click in the text view, type, move */
        click(200, 320, 1);
        pump(0.2);
        printf("after click: first responder is the text view %d, selection %s\n", w.firstResponder == tv,
               NSStringFromRange(tv.selectedRange).UTF8String);
        type("Hello world");
        pump(0.3);
        printf("typed '%s' selection %s\n", tv.string.UTF8String, NSStringFromRange(tv.selectedRange).UTF8String);
        key(NSLeftArrowFunctionKey, 123, kCGEventFlagMaskSecondaryFn);
        key(NSLeftArrowFunctionKey, 123, kCGEventFlagMaskSecondaryFn);
        key(NSLeftArrowFunctionKey, 123, kCGEventFlagMaskSecondaryFn);
        type("X");
        pump(0.3);
        printf("left 3, typed: '%s' selection %s\n", tv.string.UTF8String, NSStringFromRange(tv.selectedRange).UTF8String);
        key(NSLeftArrowFunctionKey, 123, kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskAlternate);
        pump(0.2);
        printf("option-left: selection %s\n", NSStringFromRange(tv.selectedRange).UTF8String);
        key(NSRightArrowFunctionKey, 124, kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskShift);
        key(NSRightArrowFunctionKey, 124, kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskShift);
        pump(0.2);
        printf("shift-right twice: selection %s\n", NSStringFromRange(tv.selectedRange).UTF8String);
        key(0x7f, 51, 0);
        pump(0.2);
        printf("delete: '%s' selection %s\n", tv.string.UTF8String, NSStringFromRange(tv.selectedRange).UTF8String);
        key('\r', 36, 0);
        type("next");
        pump(0.3);
        printf("return, typed: '%s'\n", V(tv.string).UTF8String);
        key(NSUpArrowFunctionKey, 126, kCGEventFlagMaskSecondaryFn);
        pump(0.2);
        printf("up: selection %s\n", NSStringFromRange(tv.selectedRange).UTF8String);

        /* clicks: at the start of the first line, a double click on a word */
        click(106, 310, 1);
        pump(0.3);
        printf("click at the start: selection %s\n", NSStringFromRange(tv.selectedRange).UTF8String);
        post(FWS_EVENT_LEFT_DOWN, 112, 310, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, 112, 310, 0, 0, 0);
        post(FWS_EVENT_LEFT_DOWN, 112, 310, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, 112, 310, 0, 0, 0);
        pump(0.3);
        printf("double click: selection %s '%s'\n", NSStringFromRange(tv.selectedRange).UTF8String,
               [tv.string substringWithRange:tv.selectedRange].UTF8String);
        /* a drag selects */
        post(FWS_EVENT_LEFT_DOWN, 106, 310, 0, 0, 0);
        post(FWS_EVENT_LEFT_DRAGGED, 150, 310, 0, 0, 0);
        post(FWS_EVENT_LEFT_DRAGGED, 400 - 20, 310, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, 400 - 20, 310, 0, 0, 0);
        pump(0.3);
        printf("drag: selection %s\n", NSStringFromRange(tv.selectedRange).UTF8String);

        /* the editing equivalents, without a menu */
        key('c', 8, kCGEventFlagMaskCommand);
        click(400 - 20, 330, 1);
        pump(0.2);
        key(NSDownArrowFunctionKey, 125, kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskCommand);
        key('v', 9, kCGEventFlagMaskCommand);
        pump(0.3);
        printf("copy, paste at the end: '%s'\n", V(tv.string).UTF8String);
        key('z', 6, kCGEventFlagMaskCommand);
        pump(0.3);
        printf("undo: '%s'\n", V(tv.string).UTF8String);
        key('a', 0, kCGEventFlagMaskCommand);
        pump(0.3);
        printf("select all: selection %s\n", NSStringFromRange(tv.selectedRange).UTF8String);
        printf("delegate: %s\n", [watcher.log componentsJoinedByString:@", "].UTF8String);

        /* what reaches the screen: text on the first line, the selection behind it */
        snapshot();
        count("first line, all selected", 100, 300, 120, 16);
        count("below the text", 100, 400, 280, 60);
        key(NSRightArrowFunctionKey, 124, kCGEventFlagMaskSecondaryFn);
        pump(0.3);
        snapshot();
        count("first line, no selection", 100, 300, 120, 16);

        /* scrolling: forty lines, then the wheel */
        NSMutableString *many = [NSMutableString string];
        for (int i = 1; i <= 40; i++)
            [many appendFormat:@"%sline %d", i > 1 ? "\n" : "", i];
        tv.string = many;
        [tv scrollRangeToVisible:NSMakeRange(0, 0)];
        pump(0.3);
        printf("text view frame %s visible %s\n", NSStringFromRect(tv.frame).UTF8String,
               NSStringFromRect(sv.documentVisibleRect).UTF8String);
        printf("scroller enabled %d proportion %.3f value %.3f\n", sv.verticalScroller.enabled,
               sv.verticalScroller.knobProportion, sv.verticalScroller.doubleValue);
        snapshot();
        count("top before scrolling", 100, 300, 120, 16);
        uint64_t before = region_hash(100, 300, 280, 200);
        const uint8_t *knob = pixel(392, 310);
        printf("scroller knob drawn %d\n", knob[0] < 200);
        if (getenv("FINCH_TEXT_TEST_DUMP")) {
            /* a look at the screen, for people */
            CGImageRef im = FWSCopyScreenImage();
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:im];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:@(getenv("FINCH_TEXT_TEST_DUMP")) atomically:YES];
            CGImageRelease(im);
        }
        scroll(200, 400, -100);
        pump(0.3);
        printf("scrolled: visible %s\n", NSStringFromRect(sv.documentVisibleRect).UTF8String);
        snapshot();
        count("top after scrolling", 100, 300, 120, 16);
        printf("what is drawn changed %d\n", region_hash(100, 300, 280, 200) != before);
        knob = pixel(392, 310);
        printf("knob moved off the top %d\n", knob[0] > 200);
        scroll(200, 400, -10000);
        pump(0.3);
        printf("scrolled to the end: visible %s value %.3f\n", NSStringFromRect(sv.documentVisibleRect).UTF8String,
               sv.verticalScroller.doubleValue);
        scroll(200, 400, 30);
        pump(0.3);
        printf("back 30: visible %s\n", NSStringFromRect(sv.documentVisibleRect).UTF8String);
        /* typing at the start scrolls back to it */
        click(150, 310, 1);
        pump(0.2);
        [tv setSelectedRange:NSMakeRange(0, 0)];
        type("A");
        pump(0.3);
        printf("typed at the start: visible %s text starts '%s'\n", NSStringFromRect(sv.documentVisibleRect).UTF8String,
               [tv.string substringToIndex:7].UTF8String);

        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        unlink(sock);
    }
    return 0;
}
