/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-window-test: AppKit on Finch's window server, end to end.
 * Starts a headless server, shows a window with views, and checks what
 * reaches the screen, that clicks and keys go to the right views, that the
 * title bar drags the window, and that the close button closes it.
 * Finch-only (it drives Finch's server): compare with
 * appkit-window-test.expected.
 *
 *   finch-appkit-window-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
CGImageRef FWSCopyScreenImage(void);
void FWSSetCursorVisible(bool v);

static NSMutableArray<NSString *> *log_;

@interface Fill : NSView
@property (strong) NSColor *color;
@property BOOL takesFocus;
@end

@implementation Fill
- (void)drawRect:(NSRect)dirty
{
    [self.color setFill];
    NSRectFill(dirty);
}
- (BOOL)acceptsFirstResponder
{
    return self.takesFocus;
}
- (void)mouseDown:(NSEvent *)e
{
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    [log_ addObject:[NSString stringWithFormat:@"%@ mouseDown window %@ local %@ clicks %ld", self.identifier,
                                               NSStringFromPoint(e.locationInWindow), NSStringFromPoint(p),
                                               (long)e.clickCount]];
}
- (void)mouseUp:(NSEvent *)e
{
    [log_ addObject:[NSString stringWithFormat:@"%@ mouseUp", self.identifier]];
}
- (void)keyDown:(NSEvent *)e
{
    NSMutableString *chars = [NSMutableString string];
    for (NSUInteger i = 0; i < e.characters.length; i++)
        [chars appendFormat:@"%s%04x", i ? " " : "", [e.characters characterAtIndex:i]];
    [log_ addObject:[NSString stringWithFormat:@"%@ keyDown %@ code %u", self.identifier, chars, e.keyCode]];
    [self interpretKeyEvents:@[ e ]];
}
- (void)insertText:(id)s
{
    [log_ addObject:[NSString stringWithFormat:@"%@ insertText '%@'", self.identifier, s]];
}
- (void)doCommandBySelector:(SEL)sel
{
    [log_ addObject:[NSString stringWithFormat:@"%@ command %@", self.identifier, NSStringFromSelector(sel)]];
}
@end

@interface Delegate : NSObject <NSWindowDelegate, NSApplicationDelegate>
@end
@implementation Delegate
- (void)windowWillClose:(NSNotification *)n
{
    [log_ addObject:@"delegate windowWillClose"];
}
- (void)windowDidMove:(NSNotification *)n
{
    /* a drag moves the window once per drag event that gets through, which depends on timing */
    if (![log_.lastObject isEqualToString:@"delegate windowDidMove"])
        [log_ addObject:@"delegate windowDidMove"];
}
- (void)windowDidBecomeKey:(NSNotification *)n
{
    [log_ addObject:@"delegate windowDidBecomeKey"];
}
- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    [log_ addObject:@"delegate applicationDidFinishLaunching"];
}
@end

static void
flush_log(NSString *label)
{
    printf("%s: %s\n", label.UTF8String, [log_ componentsJoinedByString:@"; "].UTF8String);
    [log_ removeAllObjects];
}

/* Run the app's event loop for a while. */
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

/* The screen at a point in the server's coordinates (points, y down), as R G B. */
static void
sample(const char *label, double x, double y)
{
    const uint8_t *p = CFDataGetBytePtr(screen) + (size_t)(y * 2) * screen_bpr + (size_t)(x * 2) * 4;
    printf("%s (%g,%g): %d %d %d\n", label, x, y, p[2], p[1], p[0]);
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

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-awt.%d", getpid());
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
        log_ = [NSMutableArray array];

        [NSApplication sharedApplication];
        Delegate *d = [Delegate new];
        NSApp.delegate = d;
        [NSApp finishLaunching];
        flush_log(@"launch");
        NSScreen *s = NSScreen.mainScreen;
        printf("screen %s visible %s scale %g\n", NSStringFromRect(s.frame).UTF8String,
               NSStringFromRect(s.visibleFrame).UTF8String, s.backingScaleFactor);

        NSWindow *w = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(100, 100, 300, 200)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered defer:YES];
        w.releasedWhenClosed = NO;
        w.delegate = d;
        w.title = @"Finch";
        Fill *content = [[Fill alloc] initWithFrame:NSZeroRect];
        content.identifier = @"content";
        content.color = [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1];
        w.contentView = content;
        Fill *box = [[Fill alloc] initWithFrame:NSMakeRect(20, 20, 50, 50)];
        box.identifier = @"box";
        box.takesFocus = YES;
        box.color = [NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1];
        [content addSubview:box];
        [w makeKeyAndOrderFront:nil];
        pump(0.3);
        flush_log(@"shown");
        printf("window %s number>0 %d key %d main %d visible %d first responder %s\n",
               NSStringFromRect(w.frame).UTF8String, w.windowNumber > 0, w.isKeyWindow, w.isMainWindow, w.isVisible,
               w.firstResponder == w ? "window" : [w.firstResponder className].UTF8String);
        printf("app key %d main %d active %d windows %lu\n", NSApp.keyWindow == w, NSApp.mainWindow == w,
               NSApp.isActive, (unsigned long)NSApp.windows.count);

        /* The window's top in the server's coordinates: 600 - (100 + 232) = 268; the content's bottom is 500. */
        snapshot();
        sample("content", 250, 400);
        sample("box", 125, 475);
        sample("title bar", 250, 280);
        sample("desktop", 50, 50);

        /* a click in the box, then keys */
        post(FWS_EVENT_LEFT_DOWN, 125, 475, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, 125, 475, 0, 0, 0);
        pump(0.3);
        flush_log(@"click box");
        printf("first responder is box %d\n", w.firstResponder == box);
        post(FWS_EVENT_KEY_DOWN, 0, 0, 'q', 12, 0);
        post(FWS_EVENT_KEY_DOWN, 0, 0, NSLeftArrowFunctionKey, 123, kCGEventFlagMaskSecondaryFn);
        post(FWS_EVENT_KEY_DOWN, 0, 0, '\r', 36, 0);
        pump(0.3);
        flush_log(@"keys");
        post(FWS_EVENT_LEFT_DOWN, 250, 400, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, 250, 400, 0, 0, 0);
        pump(0.3);
        flush_log(@"click content");

        /* redraw after a change */
        content.color = [NSColor colorWithSRGBRed:0 green:1 blue:0 alpha:1];
        content.needsDisplay = YES;
        pump(0.2);
        snapshot();
        sample("content after redraw", 250, 400);
        sample("box after redraw", 125, 475);

        /* drag the title bar 50 right and 20 down */
        post(FWS_EVENT_LEFT_DOWN, 250, 284, 0, 0, 0);
        post(FWS_EVENT_LEFT_DRAGGED, 280, 294, 0, 0, 0);
        post(FWS_EVENT_LEFT_DRAGGED, 300, 304, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, 300, 304, 0, 0, 0);
        pump(0.5);
        printf("after drag: %s\n", NSStringFromRect(w.frame).UTF8String);
        flush_log(@"drag");
        snapshot();
        sample("moved content", 300, 420);
        sample("old place", 120, 300);

        /* resize from the program */
        [w setContentSize:NSMakeSize(200, 100)];
        pump(0.2);
        printf("after resize: %s content %s box %s\n", NSStringFromRect(w.frame).UTF8String,
               NSStringFromRect(content.frame).UTF8String, NSStringFromRect(box.frame).UTF8String);
        snapshot();
        sample("resized content", 300, 380);

        /* the close button: 12 + 6 points from the left, in the middle of the 32-point title bar */
        NSRect f = w.frame;
        double top = 600 - NSMaxY(f);
        post(FWS_EVENT_LEFT_DOWN, NSMinX(f) + 18, top + 16, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, NSMinX(f) + 18, top + 16, 0, 0, 0);
        pump(0.5);
        flush_log(@"close");
        printf("visible %d key window %d\n", w.isVisible, NSApp.keyWindow != nil);
        snapshot();
        sample("closed", 300, 380);

        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        unlink(sock);
    }
    return 0;
}
