/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-panels-window-test: alerts, open and save panels and
 * NSWorkspace's launching on Finch's window server, end to end. Starts a
 * headless server and, while each alert or panel runs modally, clicks and
 * types at it through the server (timers fire in the modal run loop): an
 * alert answered by a click, by Return, by Escape and by Command-D; an alert
 * as a sheet over a window (placed under the title bar, the window blocked);
 * presentError: with and without recovery; an open panel browsing a
 * temporary tree (what's listed and enabled, double clicks into folders,
 * Command-Up, choosing a file; choosing a folder; cancelling); a save panel
 * typing a name (the extension added), replacing a file after asking, and
 * cancelling. Samples the screen where the panels draw. Then launches a test
 * app bundle (a shell script) with NSWorkspace and checks its arguments,
 * environment and the launch and termination notifications. Finch-only:
 * compare with appkit-panels-window-test.expected.
 *
 *   finch-appkit-panels-window-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
CGImageRef FWSCopyScreenImage(void);
void FWSSetCursorVisible(bool v);

static const double kScreenHeight = 600;

#pragma mark - Events and pixels

static void
post_at(uint32_t type, NSPoint p, unichar c, uint32_t code, uint64_t flags)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = p.x, e.screen_y = kScreenHeight - p.y;
    e.modifiers = flags;
    e.key_code = code;
    if (c) {
        e.characters[0] = e.unmodified[0] = c;
        e.length = 1;
    }
    FWSPostEvent(&e);
}

static void
click_screen(NSPoint p)
{
    post_at(FWS_EVENT_LEFT_DOWN, p, 0, 0, 0);
    post_at(FWS_EVENT_LEFT_UP, p, 0, 0, 0);
}

static void
key(unichar c, uint32_t code, uint64_t flags)
{
    post_at(FWS_EVENT_KEY_DOWN, NSZeroPoint, c, code, flags);
    post_at(FWS_EVENT_KEY_UP, NSZeroPoint, c, code, flags);
}

static void
type_text(NSString *s)
{
    for (NSUInteger i = 0; i < s.length; i++)
        key([s characterAtIndex:i], 0, 0);
}

static NSPoint
center_of(NSView *v)
{
    NSRect r = [v convertRect:v.bounds toView:nil];
    r = [v.window convertRectToScreen:r];
    return NSMakePoint(NSMidX(r), NSMidY(r));
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
pixel(NSPoint p)
{
    double sy = kScreenHeight - p.y;
    return CFDataGetBytePtr(screen) + (size_t)(sy * 2) * screen_bpr + (size_t)(p.x * 2) * 4;
}

static const char *
kind(const uint8_t *p)
{
    int r = p[2], g = p[1], b = p[0];
    /* the theme's accent (Fieldwork's green; Apple's blue in the classic theme) */
    static int accent[3] = {-1};
    if (accent[0] < 0) {
        NSColor *c = [[NSColor controlAccentColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        accent[0] = (int)([c redComponent] * 255), accent[1] = (int)([c greenComponent] * 255);
        accent[2] = (int)([c blueComponent] * 255);
    }
    if (abs(r - accent[0]) < 40 && abs(g - accent[1]) < 40 && abs(b - accent[2]) < 40)
        return "accent";
    /* a blue accent (the classic theme's) is drawn in Aqua's shades of blue */
    if (b > 180 && r < 120 && g > 60 && g < 170)
        return accent[2] > accent[0] + 60 ? "accent" : "blue";
    if (r > 225 && g > 225 && b > 225)
        return "light";
    if (r < 90 && g < 90 && b < 90)
        return "dark";
    if (r > 200 && g > 150 && b < 80)
        return "yellow";
    return "other";
}

static void
sample(const char *label, NSPoint p)
{
    printf("%s: %s\n", label, kind(pixel(p)));
}

static void
has_ink(const char *label, NSView *v)
{
    NSRect r = [v.window convertRectToScreen:[v convertRect:v.bounds toView:nil]];
    int n = 0;
    for (double y = r.origin.y; y < NSMaxY(r); y += 0.5)
        for (double x = r.origin.x; x < NSMaxX(r); x += 0.5) {
            const uint8_t *p = pixel(NSMakePoint(x, y));
            if (p[0] < 110 && p[1] < 110 && p[2] < 110)
                n++;
        }
    printf("%s: %s\n", label, n > 4 ? "ink" : "blank");
}

/* FINCH_PWT_PNG=prefix writes each snapshot as prefixN.png, to look at. */
static void
save_png(void)
{
    static int n;
    const char *prefix = getenv("FINCH_PWT_PNG");
    if (!prefix)
        return;
    char path[1024];
    snprintf(path, sizeof path, "%s%d.png", prefix, n++);
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
look(void)
{
    snapshot();
    save_png();
}

/* Steps run from timers, which fire in the modal panel run loop mode too. */
static void
after(double seconds, void (^block)(void))
{
    NSTimer *t = [NSTimer timerWithTimeInterval:seconds repeats:NO block:^(NSTimer *timer) {
        block();
    }];
    [[NSRunLoop currentRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

/* Run blocks a second apart once the modal panel about to run is up and key (a slow machine takes a while). */
static void
steps(NSArray *blocks)
{
    NSArray *copy = [blocks copy];
    __block int polls = 0;
    NSTimer *t = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        NSWindow *m = NSApp.modalWindow;
        if (!(m.isVisible && m.isKeyWindow) && ++polls < 300)
            return;
        [timer invalidate];
        double at = 0.5;
        for (void (^b)(void) in copy) {
            after(at, b);
            at += 1.0;
        }
    }];
    [[NSRunLoop currentRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

static void pump(double seconds);

/* Pump events until a condition holds, for at most 20 seconds. */
static void
pump_until(BOOL (^done)(void))
{
    for (int i = 0; i < 200 && !done(); i++)
        pump(0.1);
    pump(0.2);
}

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
}

static NSButton *
find_button(NSView *v, NSString *title)
{
    if ([v isKindOfClass:[NSButton class]] && [[(NSButton *)v title] isEqualToString:title] && !v.isHidden)
        return (NSButton *)v;
    for (NSView *s in v.subviews) {
        NSButton *b = find_button(s, title);
        if (b)
            return b;
    }
    return nil;
}

static void
click_button(NSWindow *w, NSString *title)
{
    NSButton *b = find_button(w.contentView, title);
    if (!b) {
        printf("no button '%s'\n", title.UTF8String);
        return;
    }
    click_screen(center_of(b));
}

#pragma mark - Alerts

@interface Recoverer : NSObject
@end
@implementation Recoverer
- (BOOL)attemptRecoveryFromError:(NSError *)error optionIndex:(NSUInteger)index
{
    printf("recovery attempted with option %lu\n", (unsigned long)index);
    return index == 0;
}
@end

@interface Parent : NSObject
@property int clicks;
@end
@implementation Parent
- (void)press:(id)sender
{
    self.clicks++;
}
@end

static NSAlert *
three_button_alert(void)
{
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Do you want to save the changes made to the document “Untitled”?";
    a.informativeText = @"Your changes will be lost if you don’t save them.";
    [a addButtonWithTitle:@"Save"];
    [a addButtonWithTitle:@"Cancel"];
    [a addButtonWithTitle:@"Don't Save"];
    return a;
}

static void
alerts(void)
{
    /* a click on the second button */
    NSAlert *a = three_button_alert();
    steps(@[
        ^{
            look();
            NSWindow *w = a.window;
            printf("alert visible %d key %d modal %d level %ld\n", w.isVisible, w.isKeyWindow, NSApp.modalWindow == w,
                   (long)w.level);
            NSButton *save = a.buttons[0], *cancel = a.buttons[1], *dont = a.buttons[2];
            printf("buttons right to left %d, along the bottom %d\n",
                   NSMinX(save.frame) > NSMinX(cancel.frame) && NSMinX(cancel.frame) > NSMinX(dont.frame),
                   NSMinY(save.frame) < 30);
            sample("default button", center_of(save));
            sample("other button", NSMakePoint(NSMinX([w convertRectToScreen:[cancel convertRect:cancel.bounds toView:nil]]) + 6,
                                               center_of(cancel).y));
            has_ink("cancel title", cancel);
            NSRect wf = w.frame;
            sample("icon", NSMakePoint(wf.origin.x + 20 + 32, NSMaxY([w contentRectForFrameRect:wf]) - 20 - 32));
            sample("panel background", NSMakePoint(NSMaxX(wf) - 10, NSMidY(wf)));
            click_screen(center_of(cancel));
        },
    ]);
    NSModalResponse r = [a runModal];
    printf("click Cancel: %ld, alert visible after %d\n", (long)r, a.window.isVisible);

    a = three_button_alert();
    steps(@[ ^{
        key('\r', 36, 0);
    } ]);
    printf("Return: %ld\n", (long)[a runModal]);
    a = three_button_alert();
    steps(@[ ^{
        key(0x1b, 53, 0);
    } ]);
    printf("Escape: %ld\n", (long)[a runModal]);
    a = three_button_alert();
    steps(@[ ^{
        key('d', 2, kCGEventFlagMaskCommand);
    } ]);
    printf("Command-D: %ld\n", (long)[a runModal]);

    /* a plain alert: its implicit OK */
    a = [[NSAlert alloc] init];
    a.messageText = @"Done.";
    a.showsSuppressionButton = YES;
    steps(@[
        ^{
            look();
            has_ink("message", [a.window.contentView.subviews filteredArrayUsingPredicate:
                                                             [NSPredicate predicateWithBlock:^BOOL(id v, NSDictionary *b) {
                                                                 return [v isKindOfClass:[NSTextField class]] &&
                                                                        [[v stringValue] isEqual:@"Done."];
                                                             }]].firstObject);
            click_screen(center_of(a.suppressionButton));
        },
        ^{
            click_button(a.window, @"OK");
        },
    ]);
    printf("implicit OK: %ld, suppression %ld\n", (long)[a runModal], (long)a.suppressionButton.state);

    /* a critical alert's icon is the caution sign */
    a = [[NSAlert alloc] init];
    a.alertStyle = NSAlertStyleCritical;
    a.messageText = @"Careful";
    steps(@[ ^{
        look();
        NSRect wf = a.window.frame;
        sample("critical icon", NSMakePoint(wf.origin.x + 20 + 32, NSMaxY([a.window contentRectForFrameRect:wf]) - 20 - 40));
        key('\r', 36, 0);
    } ]);
    printf("critical: %ld\n", (long)[a runModal]);
}

static void
sheets(NSWindow *parent, Parent *target, NSButton *parentButton)
{
    NSAlert *a = three_button_alert();
    __block NSModalResponse got = 0;
    __block BOOL ended = NO;
    [a beginSheetModalForWindow:parent
              completionHandler:^(NSModalResponse r) {
                  got = r;
                  ended = YES;
              }];
    pump_until(^BOOL {
        return a.window.isVisible && a.window.isKeyWindow;
    });
    NSWindow *s = a.window;
    NSRect pf = parent.frame, sf = s.frame, pc = [parent contentRectForFrameRect:pf];
    printf("sheet: attached %d parent %d visible %d key %d centred %d under the title bar %d\n", parent.attachedSheet == s,
           s.sheetParent == parent, s.isVisible, s.isKeyWindow, fabs(NSMidX(sf) - NSMidX(pf)) <= 1,
           fabs(NSMaxY(sf) - NSMaxY(pc)) <= 1);
    look();
    sample("sheet default button", center_of(a.buttons[0]));
    /* the parent doesn't take clicks while the sheet is up */
    NSPoint pb = center_of(parentButton);
    if (!NSPointInRect(pb, sf)) {
        click_screen(pb);
        pump(1.0);
    }
    printf("parent button clicks while sheet up %d, sheet still key %d\n", target.clicks, s.isKeyWindow);
    click_screen(center_of(a.buttons[2]));
    pump_until(^BOOL {
        return ended && parent.isKeyWindow;
    });
    printf("sheet ended %d with %ld, attached after %d, visible %d, parent key %d\n", ended, (long)got,
           parent.attachedSheet != nil, s.isVisible, parent.isKeyWindow);
    click_screen(pb);
    pump_until(^BOOL {
        return target.clicks > 0;
    });
    printf("parent button clicks after %d\n", target.clicks);
}

static void
errors(void)
{
    NSError *plain = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
    steps(@[ ^{
        key('\r', 36, 0);
    } ]);
    printf("presentError: %d\n", [NSApp presentError:plain]);
    NSError *recoverable = [NSError errorWithDomain:@"Test" code:1 userInfo:@{
        NSLocalizedDescriptionKey : @"Couldn't do it.",
        NSLocalizedRecoveryOptionsErrorKey : @[ @"Try Again", @"Cancel" ],
        NSRecoveryAttempterErrorKey : [Recoverer new]
    }];
    steps(@[ ^{
        key('\r', 36, 0);
    } ]);
    printf("presentError with recovery: %d\n", [NSApp presentError:recoverable]);
}

#pragma mark - Panels

static NSString *root;

static void
make_tree(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"finch-pwt-%d", getpid()]];
    root = [root stringByResolvingSymlinksInPath];
    [fm removeItemAtPath:root error:nil];
    for (NSString *d in @[ @"Alpha", @"Beta", @"Gamma.app/Contents" ])
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:d] withIntermediateDirectories:YES
                       attributes:nil error:nil];
    for (NSString *f in @[ @"notes.txt", @".hidden", @"photo.png", @"Beta/doc1.txt", @"Beta/image.png" ])
        [@"x" writeToFile:[root stringByAppendingPathComponent:f] atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static NSString *
rel(NSURL *u)
{
    NSString *p = [u.path stringByResolvingSymlinksInPath];
    if ([p hasPrefix:root])
        return [@"<root>" stringByAppendingString:[p substringFromIndex:root.length]];
    return p ?: @"(nil)";
}

/* The panel's list, read from Finch's own ivars (FinchFileList in NSSavePanel.m). */
static id
ivar(id o, const char *name)
{
    Ivar v = class_getInstanceVariable(object_getClass(o), name);
    return v ? object_getIvar(o, v) : nil;
}

static BOOL
ivar_bool(id o, const char *name)
{
    Ivar v = class_getInstanceVariable(object_getClass(o), name);
    return v ? *(BOOL *)((uint8_t *)(__bridge void *)o + ivar_getOffset(v)) : NO;
}

static NSView *
list_of(NSSavePanel *p)
{
    return ivar(p, "_list");
}

static void
print_list(const char *label, NSSavePanel *p)
{
    NSMutableArray *a = [NSMutableArray array];
    for (id e in ivar(list_of(p), "_entries"))
        [a addObject:[NSString stringWithFormat:@"%@%@%@", ivar(e, "name"), ivar_bool(e, "directory") ? @"/" : @"",
                                                ivar_bool(e, "enabled") ? @"" : @" (off)"]];
    printf("%s: %s\n", label, [a componentsJoinedByString:@", "].UTF8String);
}

static NSPoint
row_point(NSSavePanel *p, NSUInteger row)
{
    NSView *list = list_of(p);
    NSPoint q = [list convertPoint:NSMakePoint(60, row * 22 + 11) toView:nil];
    return [p convertPointToScreen:q];
}

@interface PanelDelegate : NSObject <NSOpenSavePanelDelegate>
@property (strong) NSMutableArray<NSString *> *log;
@property BOOL refuse;
@end

@implementation PanelDelegate
- (void)panel:(id)sender didChangeToDirectoryURL:(NSURL *)url
{
    [self.log addObject:[NSString stringWithFormat:@"didChangeTo %@", rel(url)]];
}
- (BOOL)panel:(id)sender shouldEnableURL:(NSURL *)url
{
    return ![url.lastPathComponent isEqual:@"Gamma.app"];
}
- (BOOL)panel:(id)sender validateURL:(NSURL *)url error:(NSError **)outError
{
    [self.log addObject:[NSString stringWithFormat:@"validate %@", rel(url)]];
    return YES;
}
- (void)panelSelectionDidChange:(id)sender
{
    [self.log addObject:@"selectionDidChange"];
}
@end

static void
flush_log(const char *label, PanelDelegate *d)
{
    printf("%s: %s\n", label, [d.log componentsJoinedByString:@"; "].UTF8String);
    [d.log removeAllObjects];
}

static void
open_panels(void)
{
    PanelDelegate *d = [PanelDelegate new];
    d.log = [NSMutableArray array];
    NSOpenPanel *o = [NSOpenPanel openPanel];
    o.directoryURL = [NSURL fileURLWithPath:root isDirectory:YES];
    o.allowedContentTypes = @[ UTTypePlainText ];
    o.delegate = d;
    o.message = @"Choose a text file";
    steps(@[
        ^{
            look();
            printf("open panel visible %d key %d title '%s'\n", o.isVisible, o.isKeyWindow, o.title.UTF8String);
            print_list("root", o);
            NSButton *ob = find_button(o.contentView, @"Open");
            sample("open button (disabled, nothing selected)",
                   NSMakePoint(NSMinX([o convertRectToScreen:[ob convertRect:ob.bounds toView:nil]]) + 6, center_of(ob).y));
            sample("folder icon", NSMakePoint(row_point(o, 0).x - 60 + 16, row_point(o, 0).y));
            /* a disabled file can't be selected */
            click_screen(row_point(o, 4));
        },
        ^{
            printf("selected after clicking photo.png %lu\n", (unsigned long)[ivar(list_of(o), "_selection") count]);
            /* double click Beta */
            click_screen(row_point(o, 1));
            click_screen(row_point(o, 1));
        },
        ^{
            print_list("Beta", o);
            /* Command-Up, then back into Beta with the keyboard */
            key(NSUpArrowFunctionKey, 126, kCGEventFlagMaskCommand);
        },
        ^{
            print_list("after Command-Up", o);
            key(NSDownArrowFunctionKey, 125, 0);
            key(NSDownArrowFunctionKey, 125, 0);
            key(NSDownArrowFunctionKey, 125, kCGEventFlagMaskCommand);
        },
        ^{
            print_list("after Command-Down", o);
            click_screen(row_point(o, 0));
        },
        ^{
            look();
            sample("selected row", row_point(o, 0));
            NSButton *ob = find_button(o.contentView, @"Open");
            sample("open button (enabled)", NSMakePoint(NSMinX([o convertRectToScreen:[ob convertRect:ob.bounds toView:nil]]) + 6,
                                                        center_of(ob).y));
            click_button(o, @"Open");
        },
    ]);
    NSModalResponse r = [o runModal];
    flush_log("open panel delegate", d);
    printf("open: %ld URLs %s visible after %d\n", (long)r,
           [[o.URLs valueForKey:@"lastPathComponent"] componentsJoinedByString:@","].UTF8String, o.isVisible);
    printf("open URL %s\n", rel(o.URL).UTF8String);

    /* choosing folders, several at once */
    NSOpenPanel *f = [NSOpenPanel openPanel];
    f.directoryURL = [NSURL fileURLWithPath:root isDirectory:YES];
    f.canChooseFiles = NO;
    f.canChooseDirectories = YES;
    f.allowsMultipleSelection = YES;
    f.showsHiddenFiles = YES;
    steps(@[
        ^{
            print_list("folders", f);
            click_screen(row_point(f, 1));
        },
        ^{
            NSPoint p = row_point(f, 2);
            post_at(FWS_EVENT_LEFT_DOWN, p, 0, 0, kCGEventFlagMaskCommand);
            post_at(FWS_EVENT_LEFT_UP, p, 0, 0, kCGEventFlagMaskCommand);
        },
        ^{
            key('\r', 36, 0);
        },
    ]);
    r = [f runModal];
    printf("folders: %ld URLs %s\n", (long)r, [[f.URLs valueForKey:@"lastPathComponent"] componentsJoinedByString:@","].UTF8String);

    NSOpenPanel *c = [NSOpenPanel openPanel];
    c.directoryURL = [NSURL fileURLWithPath:root isDirectory:YES];
    steps(@[ ^{
        key(0x1b, 53, 0);
    } ]);
    r = [c runModal];
    printf("cancelled open: %ld URLs %lu\n", (long)r, (unsigned long)c.URLs.count);
}

static void
save_panels(void)
{
    PanelDelegate *d = [PanelDelegate new];
    d.log = [NSMutableArray array];
    NSSavePanel *s = [NSSavePanel savePanel];
    s.directoryURL = [NSURL fileURLWithPath:root isDirectory:YES];
    s.allowedContentTypes = @[ UTTypePlainText ];
    s.delegate = d;
    steps(@[
        ^{
            look();
            NSTextField *field = ivar(s, "_nameField");
            printf("save panel visible %d first responder is the name field's editor %d, selected %s\n", s.isVisible,
                   field.currentEditor && s.firstResponder == (NSResponder *)field.currentEditor,
                   NSStringFromRange(field.currentEditor.selectedRange).UTF8String);
            print_list("save list", s);
            sample("save button", center_of(find_button(s.contentView, @"Save")));
            has_ink("name field", field);
            type_text(@"Report");
        },
        ^{
            /* a slow machine is still typing */
        },
        ^{
            printf("typed '%s'\n", s.nameFieldStringValue.UTF8String);
            key('\r', 36, 0);
        },
    ]);
    NSModalResponse r = [s runModal];
    flush_log("save delegate", d);
    printf("save: %ld URL %s name %s\n", (long)r, rel(s.URL).UTF8String, s.nameFieldStringValue.UTF8String);

    /* an existing name: asked, replaced */
    NSSavePanel *t = [NSSavePanel savePanel];
    t.directoryURL = [NSURL fileURLWithPath:root isDirectory:YES];
    t.allowedContentTypes = @[ UTTypePlainText ];
    t.nameFieldStringValue = @"notes";
    steps(@[
        ^{
            key('\r', 36, 0);
        },
        ^{
            NSWindow *w = NSApp.modalWindow;
            printf("asked to replace %d\n", w != t && w.isVisible);
            look();
            click_button(w, @"Replace");
        },
    ]);
    r = [t runModal];
    printf("replace: %ld URL %s\n", (long)r, rel(t.URL).UTF8String);

    /* a click on a file takes its name; Escape cancels */
    NSSavePanel *u = [NSSavePanel savePanel];
    u.directoryURL = [NSURL fileURLWithPath:root isDirectory:YES];
    steps(@[
        ^{
            print_list("all files", u);
            click_screen(row_point(u, 4));
        },
        ^{
            printf("name after click %s\n", u.nameFieldStringValue.UTF8String);
            key(0x1b, 53, 0);
        },
    ]);
    r = [u runModal];
    printf("cancelled save: %ld\n", (long)r);

    /* hidden extension */
    NSSavePanel *h = [NSSavePanel savePanel];
    h.directoryURL = [NSURL fileURLWithPath:root isDirectory:YES];
    h.allowedContentTypes = @[ UTTypePlainText ];
    h.canSelectHiddenExtension = YES;
    h.extensionHidden = YES;
    h.nameFieldStringValue = @"Summary.txt";
    steps(@[
        ^{
            NSTextField *field = ivar(h, "_nameField");
            printf("field shows '%s', name '%s'\n", field.stringValue.UTF8String, h.nameFieldStringValue.UTF8String);
            key('\r', 36, 0);
        },
    ]);
    r = [h runModal];
    printf("hidden extension: %ld URL %s\n", (long)r, rel(h.URL).UTF8String);

    /* as a sheet */
    NSWindow *parent = NSApp.mainWindow;
    NSSavePanel *sh = [NSSavePanel savePanel];
    sh.directoryURL = [NSURL fileURLWithPath:root isDirectory:YES];
    __block NSModalResponse got = 0;
    [sh beginSheetModalForWindow:parent completionHandler:^(NSModalResponse code) {
        got = code;
    }];
    pump_until(^BOOL {
        return sh.isVisible && sh.isKeyWindow;
    });
    printf("save sheet attached %d\n", parent.attachedSheet == sh);
    key(0x1b, 53, 0);
    pump_until(^BOOL {
        return got != 0;
    });
    printf("save sheet ended %ld attached %d\n", (long)got, parent.attachedSheet != nil);
}

#pragma mark - Launching

static void
launching(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *app = [root stringByAppendingPathComponent:@"Launch.app"];
    [fm createDirectoryAtPath:[app stringByAppendingPathComponent:@"Contents/MacOS"] withIntermediateDirectories:YES
                   attributes:nil error:nil];
    [@{
        @"CFBundleIdentifier" : @"org.finch.test.launch",
        @"CFBundleExecutable" : @"launch",
        @"CFBundleName" : @"Launch"
    } writeToFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:NO];
    NSString *outFile = [root stringByAppendingPathComponent:@"launched.txt"];
    NSString *script = [NSString stringWithFormat:@"#!/bin/sh\necho \"$FINCH_PWT_VALUE $*\" > '%@.tmp'\nmv '%@.tmp' '%@'\nsleep 3\n",
                                                  outFile, outFile, outFile];
    NSString *exe = [app stringByAppendingPathComponent:@"Contents/MacOS/launch"];
    [script writeToFile:exe atomically:NO encoding:NSUTF8StringEncoding error:nil];
    chmod(exe.fileSystemRepresentation, 0755);

    NSWorkspace *w = [NSWorkspace sharedWorkspace];
    NSMutableArray *notes = [NSMutableArray array];
    id o1 = [w.notificationCenter addObserverForName:NSWorkspaceDidLaunchApplicationNotification object:nil queue:nil
                                          usingBlock:^(NSNotification *n) {
                                              [notes addObject:[NSString stringWithFormat:@"launched %@",
                                                                                          [n.userInfo[NSWorkspaceApplicationKey] bundleIdentifier]]];
                                          }];
    id o2 = [w.notificationCenter addObserverForName:NSWorkspaceDidTerminateApplicationNotification object:nil queue:nil
                                          usingBlock:^(NSNotification *n) {
                                              [notes addObject:[NSString stringWithFormat:@"terminated %@",
                                                                                          [n.userInfo[NSWorkspaceApplicationKey] localizedName]]];
                                          }];
    NSWorkspaceOpenConfiguration *c = [NSWorkspaceOpenConfiguration configuration];
    c.arguments = @[ @"-flag" ];
    c.environment = @{@"FINCH_PWT_VALUE" : @"hello"};
    __block NSRunningApplication *launched = nil;
    __block NSError *error = nil;
    __block BOOL done = NO;
    [w openURLs:@[ [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"notes.txt"]] ]
        withApplicationAtURL:[NSURL fileURLWithPath:app]
               configuration:c
           completionHandler:^(NSRunningApplication *a, NSError *e) {
               launched = a;
               error = e;
               done = YES;
           }];
    for (int i = 0; i < 400 && !done; i++)
        pump(0.05);
    printf("launched %d error %s: %s %s pid %d bundle %s\n", launched != nil, error.description.UTF8String,
           launched.bundleIdentifier.UTF8String, launched.localizedName.UTF8String, launched.processIdentifier > 0,
           rel(launched.bundleURL).UTF8String);
    for (int i = 0; i < 400 && ![fm fileExistsAtPath:outFile]; i++)
        pump(0.05);
    NSString *text = [NSString stringWithContentsOfFile:outFile encoding:NSUTF8StringEncoding error:nil];
    text = [text stringByReplacingOccurrencesOfString:root withString:@"<root>"];
    printf("it ran with: %s", text.UTF8String ?: "(nothing)\n");
    printf("running applications has it %d\n",
           [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"org.finch.test.launch"] count] == 1);
    for (int i = 0; i < 400 && !launched.isTerminated; i++)
        pump(0.05);
    pump(0.3);
    printf("terminated %d; notifications: %s\n", launched.isTerminated, [notes componentsJoinedByString:@", "].UTF8String);
    [w.notificationCenter removeObserver:o1];
    [w.notificationCenter removeObserver:o2];
    NSString *odd = [root stringByAppendingPathComponent:@"data.finch-nothing-opens-this"];
    [@"x" writeToFile:odd atomically:NO encoding:NSUTF8StringEncoding error:nil];
    printf("openURL with no app for it %d\n", [w openURL:[NSURL fileURLWithPath:odd]]);
    printf("app URL for the test bundle id (not in an app folder) %s\n",
           [w URLForApplicationWithBundleIdentifier:@"org.finch.test.launch"].path.UTF8String ?: "(none)");
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-apwt.%d", getpid());
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
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        make_tree();

        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 80, 560, 420)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered defer:YES];
        w.releasedWhenClosed = NO;
        w.title = @"Document";
        Parent *target = [Parent new];
        NSButton *pb = [NSButton buttonWithTitle:@"Parent" target:target action:@selector(press:)];
        pb.frame = NSMakeRect(20, 20, 90, 24);
        [w.contentView addSubview:pb];
        [w makeKeyAndOrderFront:nil];
        pump(0.3);

        alerts();
        sheets(w, target, pb);
        errors();
        open_panels();
        save_panels();
        launching();

        [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        unlink(sock);
    }
    return 0;
}
