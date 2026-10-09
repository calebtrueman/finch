/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-menu-window-test: Finch's menus on its window server, end to
 * end. Starts a headless server, sets a main menu and checks that the menu
 * bar draws, that clicking a title opens its menu, that clicking, dragging
 * through and the keyboard choose items (and not disabled ones), that
 * submenus open, that Command-key equivalents fire, that a right click pops
 * up a view's context menu, and -popUpMenuPositioningItem:atLocation:inView:.
 * Finch-only (it drives Finch's server and draws in Finch's look): compare
 * with appkit-menu-window-test.expected.
 *
 * While a menu is open the app is inside the menu's tracking loop, so the
 * test's later steps run from a timer in the common run-loop modes.
 *
 *   finch-appkit-menu-window-test [path to finch-windowserver]
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
note(NSString *s)
{
    [log_ addObject:s];
}

static void
flush_log(NSString *label)
{
    printf("%s: %s\n", label.UTF8String, log_.count ? [log_ componentsJoinedByString:@"; "].UTF8String : "-");
    [log_ removeAllObjects];
}

#pragma mark - Screen and input

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
/* For a look at the screen: FINCH_MENU_TEST_PNG=path. */
static void
save_png(void)
{
    const char *path = getenv("FINCH_MENU_TEST_PNG");
    if (!path)
        return;
    CGImageRef im = FWSCopyScreenImage();
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, im, NULL);
    CGImageDestinationFinalize(d);
    CFRelease(d);
    CFRelease(url);
    CGImageRelease(im);
}

static void
sample(const char *label, double x, double y)
{
    const uint8_t *p = CFDataGetBytePtr(screen) + (size_t)(y * 2) * screen_bpr + (size_t)(x * 2) * 4;
    printf("  %s (%g,%g): %d %d %d\n", label, x, y, p[2], p[1], p[0]);
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
click(double x, double y)
{
    post(FWS_EVENT_MOUSE_MOVED, x, y, 0, 0, 0);
    post(FWS_EVENT_LEFT_DOWN, x, y, 0, 0, 0);
    post(FWS_EVENT_LEFT_UP, x, y, 0, 0, 0);
}

static void
key(unichar c, uint32_t code, uint64_t flags)
{
    post(FWS_EVENT_KEY_DOWN, 0, 0, c, code, flags);
    post(FWS_EVENT_KEY_UP, 0, 0, c, code, flags);
}

#pragma mark - Steps, run from a timer while menus track

static NSMutableArray *steps;  /* blocks, one per tick */

@interface Ticker : NSObject
@end
@implementation Ticker
- (void)tick:(NSTimer *)t
{
    if (!steps.count)
        return;
    void (^step)(void) = steps[0];
    [steps removeObjectAtIndex:0];
    step();
}
@end

/* Run the app until the steps are done (and a little more). */
static void
run(NSArray *blocks)
{
    [steps addObjectsFromArray:blocks];
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:30];
    while ((steps.count || [until timeIntervalSinceNow] > 29.6) && [until timeIntervalSinceNow] > 0) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                           inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e)
            [NSApp sendEvent:e];
    }
    NSDate *settle = [NSDate dateWithTimeIntervalSinceNow:0.3];
    while ([settle timeIntervalSinceNow] > 0) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:settle inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
        if (e)
            [NSApp sendEvent:e];
    }
    [NSApp updateWindows];
}

/* A step that does nothing, to let the app catch up. */
static void (^wait_)(void) = ^{
};

#pragma mark - Targets

@interface Handler : NSObject <NSMenuDelegate>
@end
@implementation Handler
- (void)newDoc:(NSMenuItem *)sender
{
    note([NSString stringWithFormat:@"newDoc: from %@", sender.title]);
}
- (void)save:(NSMenuItem *)sender
{
    note([NSString stringWithFormat:@"save: from %@", sender.title]);
}
- (void)docA:(NSMenuItem *)sender
{
    note([NSString stringWithFormat:@"docA: from %@ in %@", sender.title, sender.menu.title]);
}
- (void)copyIt:(NSMenuItem *)sender
{
    note([NSString stringWithFormat:@"copyIt: from %@", sender.title]);
}
- (void)pasteIt:(NSMenuItem *)sender
{
    note([NSString stringWithFormat:@"pasteIt: from %@", sender.title]);
}
- (void)popChanged:(NSPopUpButton *)sender
{
    note([NSString stringWithFormat:@"popChanged: selected %ld '%@'", (long)sender.indexOfSelectedItem, sender.titleOfSelectedItem]);
}
- (void)quitIt:(NSMenuItem *)sender
{
    note([NSString stringWithFormat:@"quitIt: from %@", sender.title]);
}
- (void)menuWillOpen:(NSMenu *)menu
{
    note([NSString stringWithFormat:@"willOpen %@", menu.title]);
}
- (void)menuDidClose:(NSMenu *)menu
{
    note([NSString stringWithFormat:@"didClose %@", menu.title]);
}
@end

@interface ContextView : NSView
@end
@implementation ContextView
- (void)drawRect:(NSRect)r
{
    [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1] setFill];
    NSRectFill(r);
}
- (void)willOpenMenu:(NSMenu *)menu withEvent:(NSEvent *)event
{
    note([NSString stringWithFormat:@"view willOpenMenu %@", menu.title]);
}
- (void)didCloseMenu:(NSMenu *)menu withEvent:(NSEvent *)event
{
    note([NSString stringWithFormat:@"view didCloseMenu %@", menu.title]);
}
@end

static CGFloat
text_width(NSString *s, NSFont *f)
{
    return ceil([s sizeWithAttributes:@{NSFontAttributeName : f}].width);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-amt.%d", getpid());
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
        steps = [NSMutableArray array];
        Ticker *ticker = [Ticker new];
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.15 target:ticker selector:@selector(tick:) userInfo:nil
                                                repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        [[NSProcessInfo processInfo] setProcessName:@"Menus"];

        [NSApplication sharedApplication];
        Handler *h = [Handler new];

        /* the main menu */
        NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Menus"];
        [appMenu addItemWithTitle:@"Quit Menus" action:@selector(quitIt:) keyEquivalent:@"q"].target = h;
        [main setSubmenu:appMenu forItem:[main addItemWithTitle:@"Menus" action:NULL keyEquivalent:@""]];
        NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
        file.delegate = h;
        [file addItemWithTitle:@"New" action:@selector(newDoc:) keyEquivalent:@"n"].target = h;
        [file addItemWithTitle:@"Open…" action:@selector(nobody:) keyEquivalent:@"o"];
        [file addItem:[NSMenuItem separatorItem]];
        NSMenuItem *saveItem = [file addItemWithTitle:@"Save" action:@selector(save:) keyEquivalent:@"s"];
        saveItem.target = h;
        saveItem.state = NSControlStateValueOn;
        NSMenu *recent = [[NSMenu alloc] initWithTitle:@"Recent"];
        [recent addItemWithTitle:@"Doc A" action:@selector(docA:) keyEquivalent:@""].target = h;
        [file setSubmenu:recent forItem:[file addItemWithTitle:@"Recent" action:NULL keyEquivalent:@""]];
        [main setSubmenu:file forItem:[main addItemWithTitle:@"File" action:NULL keyEquivalent:@""]];
        NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
        [edit addItemWithTitle:@"Copy" action:@selector(copyIt:) keyEquivalent:@"c"].target = h;
        [edit addItemWithTitle:@"Paste" action:@selector(pasteIt:) keyEquivalent:@"v"].target = h;
        [main setSubmenu:edit forItem:[main addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""]];
        NSMenu *windows = [[NSMenu alloc] initWithTitle:@"Window"];
        [windows addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
        [main setSubmenu:windows forItem:[main addItemWithTitle:@"Window" action:NULL keyEquivalent:@""]];
        NSApp.mainMenu = main;
        NSApp.windowsMenu = windows;
        [NSApp finishLaunching];

        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 300, 200)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered defer:YES];
        w.releasedWhenClosed = NO;
        w.title = @"Main";
        ContextView *cv = [[ContextView alloc] initWithFrame:NSZeroRect];
        w.contentView = cv;
        NSMenu *ctx = [[NSMenu alloc] initWithTitle:@"Context"];
        ctx.delegate = h;
        [ctx addItemWithTitle:@"Copy" action:@selector(copyIt:) keyEquivalent:@""].target = h;
        [ctx addItemWithTitle:@"Paste" action:@selector(pasteIt:) keyEquivalent:@""].target = h;
        cv.menu = ctx;
        NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(150, 150, 120, 24) pullsDown:NO];
        [pop addItemsWithTitles:@[ @"One", @"Two", @"Three" ]];
        [pop selectItemAtIndex:1];
        pop.target = h;
        pop.action = @selector(popChanged:);
        [cv addSubview:pop];
        [w makeKeyAndOrderFront:nil];
        run(@[ wait_ ]);
        printf("active %d key %d visible frame %s\n", NSApp.isActive, w.isKeyWindow,
               NSStringFromRect(NSScreen.mainScreen.visibleFrame).UTF8String);

        /* The bar's layout, as Finch draws it: titles from x 10, 9 points of padding each side, the app's name bold. */
        CGFloat appW = text_width(@"Menus", [NSFont boldSystemFontOfSize:13]) + 18;
        CGFloat fileX = 10 + appW, fileW = text_width(@"File", [NSFont menuBarFontOfSize:0]) + 18;
        CGFloat editX = fileX + fileW, editW = text_width(@"Edit", [NSFont menuBarFontOfSize:0]) + 18;
        CGFloat windowX = editX + editW;
        /* A menu's rows: 5 points of padding, items 22 points, separators 11. Under the bar: y 24 down. */
        CGFloat row0 = 24 + 5 + 11, row1 = row0 + 22, row3 = row1 + 22 + 11 / 2.0 + 11 / 2.0, row4 = row3 + 22;

        snapshot();
        printf("menu bar:\n");
        sample("bar background", 780, 12);
        sample("bar bottom line", 780, 23.5);
        sample("under the bar", 780, 40);

        /* click a title: its menu opens and stays open; the pointer highlights; a click chooses */
        click(fileX + fileW / 2, 12);
        run(@[
            wait_, wait_,
            ^{
                snapshot();
                printf("File open:\n");
                save_png();
                sample("File title highlighted", fileX + 5, 12);
                sample("menu background", fileX + 30, row0 + 9);
                sample("check mark (Save, on)", fileX + 12, row3 + 3.5);
                post(FWS_EVENT_MOUSE_MOVED, fileX + 40, row0, 0, 0, 0);
            },
            wait_,
            ^{
                snapshot();
                sample("New highlighted", fileX + 8, row0);
                sample("Open (disabled) not highlighted", fileX + 8, row1);
                click(fileX + 40, row1);  /* disabled: nothing */
            },
            wait_,
            ^{
                snapshot();
                sample("still open after clicking a disabled item", fileX + 30, row0 + 9);
                click(fileX + 40, row0);
            },
            wait_
        ]);
        flush_log(@"click New");
        snapshot();
        sample("closed", fileX + 30, row0 + 9);
        sample("title no longer highlighted", fileX + 5, 12);

        /* the keyboard: down skips the disabled item and the separator; Return chooses */
        click(fileX + fileW / 2, 12);
        run(@[
            wait_, wait_, ^{ key(NSDownArrowFunctionKey, 125, kCGEventFlagMaskSecondaryFn); },
            ^{ key(NSDownArrowFunctionKey, 125, kCGEventFlagMaskSecondaryFn); }, wait_,
            ^{
                snapshot();
                sample("Save highlighted by the keyboard", fileX + 19, row3 - 8);
                key('\r', 36, 0);
            },
            wait_
        ]);
        flush_log(@"keys down down return");

        /* Escape closes */
        click(fileX + fileW / 2, 12);
        run(@[ wait_, wait_, ^{ key(0x1b, 53, 0); }, wait_ ]);
        flush_log(@"escape");
        snapshot();
        sample("closed by escape", fileX + 30, row0 + 9);

        /* a submenu opens beside its item; choose in it */
        __block CGFloat subX = 0;
        click(fileX + fileW / 2, 12);
        run(@[
            wait_, wait_, ^{ post(FWS_EVENT_MOUSE_MOVED, fileX + 40, row4, 0, 0, 0); }, wait_,
            ^{
                /* the submenu's left edge: where the menu background starts right of the File menu */
                snapshot();
                for (CGFloat x = fileX + 60; x < 700; x += 1) {
                    const uint8_t *p = CFDataGetBytePtr(screen) + (size_t)((row4 + 4) * 2) * screen_bpr +
                                       (size_t)(x * 2) * 4;
                    if (p[2] == 247 && x > fileX + 100) {
                        const uint8_t *q = p - 3 * 4 * 2;
                        if (q[2] != 247) {
                            subX = x;
                            break;
                        }
                    }
                }
                printf("submenu opened right of the menu %d\n", subX > fileX + 100);
                post(FWS_EVENT_MOUSE_MOVED, subX + 20, row4, 0, 0, 0);
            },
            wait_,
            ^{
                snapshot();
                sample("Doc A highlighted", subX + 8, row4);
                sample("Recent still highlighted", fileX + 8, row4);
                click(subX + 20, row4);
            },
            wait_
        ]);
        flush_log(@"submenu");

        /* press on a title, drag to an item, release */
        run(@[
            ^{
                post(FWS_EVENT_MOUSE_MOVED, editX + editW / 2, 12, 0, 0, 0);
                post(FWS_EVENT_LEFT_DOWN, editX + editW / 2, 12, 0, 0, 0);
            },
            wait_, ^{ post(FWS_EVENT_LEFT_DRAGGED, editX + 30, 30, 0, 0, 0); },
            ^{ post(FWS_EVENT_LEFT_DRAGGED, editX + 30, row1, 0, 0, 0); }, wait_,
            ^{ post(FWS_EVENT_LEFT_UP, editX + 30, row1, 0, 0, 0); }, wait_
        ]);
        flush_log(@"drag to Paste");

        /* moving across the bar switches menus */
        click(fileX + fileW / 2, 12);
        run(@[
            wait_, wait_, ^{ post(FWS_EVENT_MOUSE_MOVED, windowX + 20, 12, 0, 0, 0); }, wait_,
            ^{
                NSMutableArray *titles = [NSMutableArray array];
                for (NSMenuItem *i in windows.itemArray)
                    [titles addObject:i.isSeparatorItem ? @"---" : [NSString stringWithFormat:@"%@%@", i.title,
                                                                                i.state ? @" (on)" : @""]];
                printf("Window menu: %s\n", [titles componentsJoinedByString:@", "].UTF8String);
                key(0x1b, 53, 0);
            },
            wait_
        ]);
        flush_log(@"switch to Window");

        /* Command-key equivalents, through NSApp's sendEvent: */
        run(@[
            ^{
                key('n', 45, kCGEventFlagMaskCommand);
                key('q', 12, kCGEventFlagMaskCommand);
                key('x', 7, kCGEventFlagMaskCommand);
            },
            wait_
        ]);
        flush_log(@"cmd-n cmd-q cmd-x");

        /* a right click pops up the view's menu at the pointer; it stays open; a click chooses */
        NSRect content = [w convertRectToScreen:cv.frame];
        double cx = NSMinX(content) + 50, cy = 600 - NSMaxY(content) + 40;
        run(@[
            ^{
                post(FWS_EVENT_MOUSE_MOVED, cx, cy, 0, 0, 0);
                post(FWS_EVENT_RIGHT_DOWN, cx, cy, 0, 0, 0);
                post(FWS_EVENT_RIGHT_UP, cx, cy, 0, 0, 0);
            },
            wait_, wait_,
            ^{
                snapshot();
                printf("context menu:\n");
                sample("menu at the pointer", cx + 30, cy + 5 + 11 + 9);
                sample("view beside it", cx - 30, cy + 20);
                click(cx + 40, cy + 5 + 22 + 11);
            },
            wait_
        ]);
        flush_log(@"context menu");

        /* -popUpMenuPositioningItem:atLocation:inView: puts the item at the location */
        __block BOOL chosen = NO;
        [steps addObjectsFromArray:@[
            wait_, wait_,
            ^{
                snapshot();
                /* Paste's top left at (60, 40) in the (unflipped) view: Copy is the row above */
                double px = NSMinX(content) + 60, py = 600 - (NSMinY(content) + 40);
                sample("Paste row (at the location)", px + 30, py + 11);
                sample("Copy row above it", px + 30, py - 11);
                click(px + 40, py - 11);
            },
            wait_
        ]];
        chosen = [ctx popUpMenuPositioningItem:[ctx itemAtIndex:1] atLocation:NSMakePoint(60, 40) inView:cv];
        run(@[ wait_ ]);
        printf("popUpMenuPositioningItem returned %d\n", chosen);
        flush_log(@"positioned menu");

        /* a pop-up button: its menu opens with the selected item over the button; choosing selects */
        double popX = NSMinX(content) + 150, popTop = 600 - (NSMinY(content) + 174);
        run(@[
            ^{ click(popX + 60, popTop + 12); },
            wait_, wait_,
            ^{
                snapshot();
                printf("pop-up menu:\n");
                sample("Two highlighted over the button", popX + 19, popTop + 5);
                sample("Three below it", popX + 100, popTop + 34);
                click(popX + 40, popTop + 34);
            },
            wait_
        ]);
        flush_log(@"pop-up");
        printf("pop-up selected %ld title '%s' states %ld%ld%ld\n", (long)pop.indexOfSelectedItem, pop.title.UTF8String,
               (long)[pop itemAtIndex:0].state, (long)[pop itemAtIndex:1].state, (long)[pop itemAtIndex:2].state);

        /* the bar follows the main menu */
        [main removeItemAtIndex:3];
        run(@[ wait_ ]);
        snapshot();
        sample("Window title gone", windowX + 12, 12);
        NSApp.mainMenu = nil;
        run(@[ wait_ ]);
        snapshot();
        sample("no main menu: no bar", 780, 12);

        [timer invalidate];
        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        unlink(sock);
    }
    return 0;
}
