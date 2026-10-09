/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-controls-window-test: controls on Finch's window server, end
 * to end. Starts a headless server, shows a window of controls, clicks and
 * types at them through the server, and checks that actions fire, states
 * change, the default button answers Return, a text field edits through
 * the field editor (when the window has one), and that the controls draw
 * (sampling the composited screen). Finch-only: compare with
 * appkit-controls-window-test.expected.
 *
 *   finch-appkit-controls-window-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
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

static void
flush_log(NSString *label)
{
    printf("%s: %s\n", label.UTF8String, [log_ componentsJoinedByString:@"; "].UTF8String);
    [log_ removeAllObjects];
}

@interface Target : NSObject <NSTextFieldDelegate>
@end

@implementation Target
- (void)log:(SEL)sel sender:(id)sender
{
    NSString *v = [sender isKindOfClass:[NSButton class]] ? [NSString stringWithFormat:@"state %ld", (long)[sender state]]
                                                          : [NSString stringWithFormat:@"'%@'", [sender stringValue]];
    [log_ addObject:[NSString stringWithFormat:@"%s %@ %@", sel_getName(sel),
                                               [sender respondsToSelector:@selector(title)] ? [sender title] : [sender className],
                                               v]];
}
- (void)push:(id)sender { [self log:_cmd sender:sender]; }
- (void)check:(id)sender { [self log:_cmd sender:sender]; }
- (void)radio:(id)sender { [self log:_cmd sender:sender]; }
- (void)field:(id)sender { [self log:_cmd sender:sender]; }
- (void)slide:(id)sender
{
    [log_ addObject:[NSString stringWithFormat:@"slide %.0f", [sender doubleValue]]];
}
- (void)segment:(id)sender
{
    [log_ addObject:[NSString stringWithFormat:@"segment %ld", (long)[sender selectedSegment]]];
}
- (void)controlTextDidBeginEditing:(NSNotification *)n
{
    [log_ addObject:@"didBeginEditing"];
}
- (void)controlTextDidChange:(NSNotification *)n
{
    [log_ addObject:[NSString stringWithFormat:@"didChange '%@'", [[n.userInfo[@"NSFieldEditor"] string] copy]]];
}
- (void)controlTextDidEndEditing:(NSNotification *)n
{
    [log_ addObject:[NSString stringWithFormat:@"didEndEditing '%@'", [n.object stringValue]]];
}
@end

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

/* The window's content origin is at (100, 100) on an 800 by 600 screen: content (x, y) is (100 + x, 500 - y). */
static const uint8_t *
pixel(double x, double y)
{
    double sx = 100 + x, sy = 500 - y;
    return CFDataGetBytePtr(screen) + (size_t)(sy * 2) * screen_bpr + (size_t)(sx * 2) * 4;
}

/* Classify a pixel: accent (blue), light, dark, or other, so the expected output doesn't pin exact colours. */
static const char *
kind(const uint8_t *p)
{
    int r = p[2], g = p[1], b = p[0];
    if (b > 180 && r < 120 && g > 60 && g < 170)
        return "accent";
    if (r > 225 && g > 225 && b > 225)
        return "light";
    if (r < 90 && g < 90 && b < 90)
        return "dark";
    return "other";
}

/* FINCH_CWT_PNG=path writes the screen as a PNG, to look at. */
static void
save_png(void)
{
    const char *path = getenv("FINCH_CWT_PNG");
    if (!path)
        return;
    CGImageRef im = FWSCopyScreenImage();
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (d) {
        CGImageDestinationAddImage(d, im, NULL);
        CGImageDestinationFinalize(d);
        CFRelease(d);
    }
    CFRelease(url);
    CGImageRelease(im);
}

static void
sample(const char *label, double x, double y)
{
    printf("%s: %s\n", label, kind(pixel(x, y)));
}

/* Any dark (text) pixel in a content rect. */
static void
has_ink(const char *label, NSRect r)
{
    int n = 0;
    for (double y = r.origin.y; y < NSMaxY(r); y += 0.5)
        for (double x = r.origin.x; x < NSMaxX(r); x += 0.5) {
            const uint8_t *p = pixel(x, y);
            if (p[0] < 110 && p[1] < 110 && p[2] < 110)
                n++;
        }
    printf("%s: %s\n", label, n > 4 ? "ink" : "blank");
}

static void
post(uint32_t type, double x, double y, unichar c, uint32_t code, uint64_t flags)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = 100 + x, e.screen_y = 500 - y;
    e.modifiers = flags;
    e.key_code = code;
    if (c) {
        e.characters[0] = e.unmodified[0] = c;
        e.length = 1;
    }
    FWSPostEvent(&e);
}

static void
click(double x, double y)
{
    post(FWS_EVENT_LEFT_DOWN, x, y, 0, 0, 0);
    post(FWS_EVENT_LEFT_UP, x, y, 0, 0, 0);
    pump(0.3);
}

static void
key(unichar c, uint32_t code)
{
    post(FWS_EVENT_KEY_DOWN, 0, 0, c, code, 0);
    post(FWS_EVENT_KEY_UP, 0, 0, c, code, 0);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-acwt.%d", getpid());
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
        [NSApp finishLaunching];

        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 400, 300)
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:YES];
        w.releasedWhenClosed = NO;
        w.title = @"Controls";
        Target *t = [Target new];
        NSView *content = w.contentView;

        NSButton *ok = [NSButton buttonWithTitle:@"OK" target:t action:@selector(push:)];
        ok.frame = NSMakeRect(290, 15, 90, 32);
        ok.keyEquivalent = @"\r";
        [content addSubview:ok];
        NSButton *other = [NSButton buttonWithTitle:@"Other" target:t action:@selector(push:)];
        other.frame = NSMakeRect(190, 15, 90, 32);
        [content addSubview:other];
        NSButton *check = [NSButton checkboxWithTitle:@"Check" target:t action:@selector(check:)];
        check.frame = NSMakeRect(20, 260, 120, 18);
        [content addSubview:check];
        NSButton *ra = [NSButton radioButtonWithTitle:@"Radio A" target:t action:@selector(radio:)];
        ra.frame = NSMakeRect(20, 235, 120, 18);
        ra.state = NSControlStateValueOn;
        [content addSubview:ra];
        NSButton *rb = [NSButton radioButtonWithTitle:@"Radio B" target:t action:@selector(radio:)];
        rb.frame = NSMakeRect(20, 212, 120, 18);
        [content addSubview:rb];
        NSTextField *label = [NSTextField labelWithString:@"Name"];
        label.frame = NSMakeRect(20, 170, 60, 17);
        [content addSubview:label];
        NSTextField *field = [NSTextField textFieldWithString:@"Hello"];
        field.frame = NSMakeRect(90, 168, 200, 22);
        field.target = t;
        field.action = @selector(field:);
        field.delegate = t;
        [content addSubview:field];
        NSSlider *slider = [NSSlider sliderWithValue:0 minValue:0 maxValue:100 target:t action:@selector(slide:)];
        slider.frame = NSMakeRect(20, 120, 200, 24);
        [content addSubview:slider];
        NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithLabels:@[ @"One", @"Two", @"Three" ]
                                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                          target:t action:@selector(segment:)];
        seg.frame = NSMakeRect(20, 75, 210, 24);
        [seg setWidth:68 forSegment:0];
        [seg setWidth:68 forSegment:1];
        [seg setWidth:68 forSegment:2];
        seg.selectedSegment = 0;
        [content addSubview:seg];
        NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(250, 120, 130, 20)];
        bar.indeterminate = NO;
        bar.doubleValue = 75;
        [content addSubview:bar];

        [w makeKeyAndOrderFront:nil];
        pump(0.3);
        printf("default button is OK %d, first responder %s\n", w.defaultButtonCell == ok.cell,
               w.firstResponder == w ? "window" : w.firstResponder.className.UTF8String);
        BOOL editor = [w respondsToSelector:@selector(fieldEditor:forObject:)] &&
                      [w fieldEditor:YES forObject:field] != nil;

        snapshot();
        save_png();
        sample("default button", 335, 31);
        sample("other button", 235 - 30, 31);
        has_ink("other button title", NSMakeRect(205, 24, 60, 14));
        sample("checkbox off", 27, 269);
        sample("radio A on", 22, 244);
        sample("radio B off", 22, 221);
        has_ink("label", NSMakeRect(20, 170, 40, 17));
        sample("text field background", 270, 179);
        has_ink("text field text", NSMakeRect(94, 170, 40, 18));
        sample("segment one (selected)", 26, 80);
        sample("segment two", 94, 80);
        sample("progress filled", 260, 130);
        sample("progress empty", 375, 130);

        /* buttons */
        click(60, 269);
        printf("check state %ld\n", (long)check.state);
        click(60, 221);
        printf("radios %ld %ld\n", (long)ra.state, (long)rb.state);
        click(235, 31);
        flush_log(@"clicks");
        /* a press dragged off the button and released outside doesn't fire */
        post(FWS_EVENT_LEFT_DOWN, 235, 31, 0, 0, 0);
        post(FWS_EVENT_LEFT_DRAGGED, 235, 90, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, 235, 90, 0, 0, 0);
        pump(0.3);
        flush_log(@"press and drag off");
        snapshot();
        sample("checkbox on", 27, 269);
        sample("radio A off", 22, 244);
        sample("radio B on", 22, 221);

        /* Return goes to the default button */
        key('\r', 36);
        pump(0.3);
        flush_log(@"return");

        /* the slider follows the mouse; the segmented control selects */
        post(FWS_EVENT_LEFT_DOWN, 120, 132, 0, 0, 0);
        post(FWS_EVENT_LEFT_DRAGGED, 170, 132, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, 170, 132, 0, 0, 0);
        pump(0.3);
        printf("slider %s\n", slider.doubleValue > 60 && slider.doubleValue < 90 ? "moved to about 75" : "elsewhere");
        [log_ removeAllObjects];
        click(190, 87);
        printf("segment %ld\n", (long)seg.selectedSegment);
        flush_log(@"segment");
        snapshot();
        sample("segment three (selected)", 162, 80);
        sample("segment one", 26, 80);

        /* the text field edits through the field editor */
        printf("field editor %s\n", editor ? "yes" : "no");
        if (editor) {
            click(150, 179);
            printf("editing %d first responder is the editor %d\n", field.currentEditor != nil,
                   field.currentEditor && w.firstResponder == (NSResponder *)field.currentEditor);
            [field.currentEditor selectAll:nil];
            key('h', 4);
            key('i', 34);
            pump(0.3);
            printf("field value while editing '%s'\n", field.stringValue.UTF8String);
            key('\r', 36);
            pump(0.3);
            flush_log(@"typed and return");
            printf("field '%s'\n", field.stringValue.UTF8String);
            key('\t', 48);
            pump(0.3);
            flush_log(@"tab");
            printf("editing after tab %d\n", field.currentEditor != nil);
        }

        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        unlink(sock);
    }
    return 0;
}
