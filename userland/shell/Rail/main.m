/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Rail: Fieldwork's strip down the left edge of the screen, in place of a
 * Dock (docs/design/FIELDWORK.md). From the top: the Finch mark (branding/), the pinned
 * apps, the other running apps, and the workbench switcher at the bottom. It is
 * part of the desktop's frame, so it never floats or magnifies: a running app
 * has a slim accent mark beside its icon, segmented by its windows. Clicking an
 * icon opens or brings forward its app. Pinned apps are the Pinned default (app
 * paths) of org.finch.Rail, or those of a starting set that are installed.
 */
#import <Cocoa/Cocoa.h>

enum { kWidth = 48, kMark = 44, kSlot = 44, kIcon = 32, kBench = 30 };

@interface RailItem : NSObject
@property (copy) NSString *path;
@property (copy) NSString *name;
@property (retain) NSImage *icon;
@property (retain) NSRunningApplication *app;
@property NSUInteger windows;
@property BOOL pinned;
@end

@implementation RailItem
@end

@interface RailView : NSView
@property (retain) NSArray<RailItem *> *items;
@property NSInteger bench;
@end

@implementation RailView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

/* The Finch mark (branding/BRAND.md): the symbol as the brand generates it, Paper on Ink in Night. */
static void
draw_finch(NSRect box)
{
    BOOL night = [[NSAppearance currentDrawingAppearance].name rangeOfString:@"Dark"].location != NSNotFound;
    NSImage *mark = [[NSBundle mainBundle] imageForResource:night ? @"symbol-dark" : @"symbol"];
    NSRect r = NSMakeRect(floor(NSMidX(box) - 14), floor(NSMidY(box) - 14), 28, 28);
    [mark drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

- (NSRect)rectOfItem:(NSUInteger)i
{
    return NSMakeRect(0, kMark + 6 + i * kSlot + (i >= [self firstUnpinned] ? 9 : 0), kWidth, kSlot);
}

- (NSUInteger)firstUnpinned
{
    NSUInteger n = 0;
    for (RailItem *it in _items)
        if (it.pinned)
            n++;
    return n;
}

- (NSRect)rectOfBench:(NSInteger)i
{
    NSRect b = [self bounds];
    return NSMakeRect(0, NSMaxY(b) - 10 - (3 - i) * kBench, kWidth, kBench);
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(b);
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(NSMaxX(b) - 1, 0, 1, NSHeight(b)));
    draw_finch(NSMakeRect(0, 0, kWidth, kMark));
    NSRectFill(NSMakeRect(10, kMark, kWidth - 20, 1));
    NSUInteger firstUnpinned = [self firstUnpinned];
    for (NSUInteger i = 0; i < _items.count; i++) {
        RailItem *it = _items[i];
        NSRect r = [self rectOfItem:i];
        if (i == firstUnpinned && i > 0) {
            [[NSColor separatorColor] setFill];
            NSRectFill(NSMakeRect(14, NSMinY(r) - 5, kWidth - 28, 1));
        }
        NSRect icon = NSMakeRect(floor(NSMidX(r) - kIcon / 2.0), floor(NSMidY(r) - kIcon / 2.0), kIcon, kIcon);
        [it.icon drawInRect:icon fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                   fraction:it.app || it.pinned ? 1 : 0.6 respectFlipped:YES hints:nil];
        if (it.app) {
            /* the running mark: one segment per window, up to three */
            NSUInteger n = MAX(1, MIN(it.windows, 3));
            CGFloat total = 18, gap = 2, seg = (total - gap * (n - 1)) / n;
            [(it.app.active ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor]) setFill];
            for (NSUInteger s = 0; s < n; s++)
                NSRectFill(NSMakeRect(2, NSMidY(r) - total / 2 + s * (seg + gap), 2, seg));
        }
    }
    /* the workbenches */
    NSDictionary *a = @{
        NSFontAttributeName : [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : [NSColor secondaryLabelColor],
    };
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(10, NSMinY([self rectOfBench:0]) - 6, kWidth - 20, 1));
    for (NSInteger i = 0; i < 3; i++) {
        NSRect r = [self rectOfBench:i];
        NSString *label = [NSString stringWithFormat:@"%02ld", (long)i + 1];
        NSMutableDictionary *attrs = [a mutableCopy];
        if (i == _bench)
            attrs[NSForegroundColorAttributeName] = [NSColor labelColor];
        NSSize s = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(floor(NSMidX(r) - s.width / 2), floor(NSMidY(r) - s.height / 2)) withAttributes:attrs];
        if (i == _bench) {
            [[NSColor controlAccentColor] setFill];
            NSRectFill(NSMakeRect(floor(NSMidX(r) - s.width / 2), floor(NSMidY(r) + s.height / 2) + 1, ceil(s.width), 2));
        }
    }
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    for (NSUInteger i = 0; i < _items.count; i++) {
        if (!NSPointInRect(p, [self rectOfItem:i]))
            continue;
        RailItem *it = _items[i];
        if (it.app)
            [it.app activateWithOptions:NSApplicationActivateAllWindows];
        else
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:it.path]
                                                  configuration:[NSWorkspaceOpenConfiguration configuration]
                                              completionHandler:nil];
        return;
    }
    for (NSInteger i = 0; i < 3; i++)
        if (NSPointInRect(p, [self rectOfBench:i])) {
            _bench = i;
            [[NSUserDefaults standardUserDefaults] setInteger:i forKey:@"Workbench"];
            [self setNeedsDisplay:YES];
        }
}

@end

@interface RailController : NSObject
@property (retain) NSPanel *panel;
@property (retain) RailView *view;
@end

@implementation RailController

static NSArray<NSString *> *
pinned_paths(void)
{
    NSArray *pins = [[NSUserDefaults standardUserDefaults] arrayForKey:@"Pinned"];
    if (pins.count)
        return pins;
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *name in @[ @"Finder", @"TextEdit", @"Terminal", @"Calculator", @"Image Capture", @"Stickies" ])
        for (NSString *dir in @[ @"/Applications", @"/System/Applications", @"/System/Applications/Utilities",
                                 @"/System/Library/CoreServices" ]) {
            NSString *p = [[dir stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"app"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                [found addObject:p];
                break;
            }
        }
    return found;
}

/* Windows on screen per process, from the window server's list. */
static NSDictionary<NSNumber *, NSNumber *> *
window_counts(void)
{
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    for (NSDictionary *w in (__bridge NSArray *)list) {
        if ([w[(id)kCGWindowLayer] integerValue] != 0)
            continue;
        NSNumber *pid = w[(id)kCGWindowOwnerPID];
        if (pid)
            counts[pid] = @([counts[pid] unsignedIntegerValue] + 1);
    }
    if (list)
        CFRelease(list);
    return counts;
}

- (void)refresh
{
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    NSDictionary *counts = window_counts();
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *running = [ws runningApplications];
    for (NSString *path in pinned_paths()) {
        RailItem *it = [RailItem new];
        it.path = path;
        it.pinned = YES;
        for (NSRunningApplication *a in running)
            if ([a.bundleURL.path isEqualToString:path])
                it.app = a;
        [seen addObject:path];
        [items addObject:it];
    }
    for (NSRunningApplication *a in running) {
        NSString *path = a.bundleURL.path;
        if (!path || [seen containsObject:path] || a.activationPolicy != NSApplicationActivationPolicyRegular ||
            a.processIdentifier == getpid())
            continue;
        RailItem *it = [RailItem new];
        it.path = path;
        it.app = a;
        [seen addObject:path];
        [items addObject:it];
    }
    BOOL changed = items.count != _view.items.count;
    for (NSUInteger i = 0; !changed && i < items.count; i++) {
        RailItem *x = items[i], *y = _view.items[i];
        NSUInteger wx = x.app ? [counts[@(x.app.processIdentifier)] unsignedIntegerValue] : 0;
        changed = ![x.path isEqualToString:y.path] || (x.app != nil) != (y.app != nil) || wx != y.windows ||
                  x.app.active != y.app.active;
    }
    for (RailItem *it in items) {
        it.windows = it.app ? [counts[@(it.app.processIdentifier)] unsignedIntegerValue] : 0;
        it.icon = [ws iconForFile:it.path];
        it.name = [[NSFileManager defaultManager] displayNameAtPath:it.path];
    }
    if (changed || !_view.items) {
        _view.items = items;
        [_view setNeedsDisplay:YES];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    NSRect screen = [[NSScreen mainScreen] frame];
    CGFloat bar = NSMaxY(screen) - NSMaxY([[NSScreen mainScreen] visibleFrame]);
    NSRect frame = NSMakeRect(NSMinX(screen), NSMinY(screen), kWidth, NSHeight(screen) - bar);
    _panel = [[NSPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                          backing:NSBackingStoreBuffered defer:NO];
    [_panel setLevel:kCGDockWindowLevel];
    [_panel setHasShadow:NO];
    [_panel setHidesOnDeactivate:NO];
    [_panel setCollectionBehavior:NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces];
    _view = [[RailView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, NSHeight(frame))];
    _view.bench = [[NSUserDefaults standardUserDefaults] integerForKey:@"Workbench"];
    [_panel setContentView:_view];
    [self refresh];
    [_panel orderFrontRegardless];
    NSTimer *t = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

- (void)tick:(NSTimer *)t { [self refresh]; }

@end

int
main(int argc, const char **argv)
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        RailController *c = [RailController new];
        [app setDelegate:(id)c];
        [app run];
    }
    return 0;
}
