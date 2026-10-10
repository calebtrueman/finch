/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Window tabs (NSWindowTabGroup, NSWindowTab and NSWindow's tabbing calls). A window is in
 * a group of its own until another is added to it as a tab. The windows of a group share
 * one frame and only the selected one is on screen, as on macOS; Finch draws no tab bar
 * yet, so tabs are switched with the Window menu's commands (Show Next Tab, ...) or by
 * the app. Closing a tab selects the one beside it.
 */
#import "AppKit_Finch.h"

@interface NSWindowTabGroup ()
- (instancetype)_finchInitWithIdentifier:(NSWindowTabbingIdentifier)identifier;
@end

@implementation NSWindowTab {
    __weak NSWindow *_window;
    NSString *_title, *_toolTip;
    NSAttributedString *_attributedTitle;
    NSView *_accessoryView;
}

- (instancetype)_finchInitWithWindow:(NSWindow *)window
{
    if ((self = [super init]))
        _window = window;
    return self;
}

- (void)dealloc
{
    [_title release];
    [_toolTip release];
    [_attributedTitle release];
    [_accessoryView release];
    [super dealloc];
}

- (NSString *)title { return _title ?: [_window title] ?: @""; }
- (void)setTitle:(NSString *)title
{
    [_title autorelease];
    _title = [title copy];
}
- (NSAttributedString *)attributedTitle { return _attributedTitle; }
- (void)setAttributedTitle:(NSAttributedString *)title
{
    [_attributedTitle autorelease];
    _attributedTitle = [title copy];
}
- (NSString *)toolTip { return _toolTip ?: [self title]; }
- (void)setToolTip:(NSString *)tip
{
    [_toolTip autorelease];
    _toolTip = [tip copy];
}
- (NSWindow *)window { return _window; }
- (NSImage *)image { return nil; } /* tabs show no icon on Finch yet (private) */
- (void)setImage:(NSImage *)image {}
- (NSView *)accessoryView { return _accessoryView; }
- (void)setAccessoryView:(NSView *)view
{
    [_accessoryView autorelease];
    _accessoryView = [view retain];
}

@end

static char group_key, tab_key, identifier_key;

@implementation NSWindowTabGroup {
    NSString *_identifier;
    NSMutableArray<NSWindow *> *_windows; /* not retained: windows own their groups */
    __weak NSWindow *_selected;
    BOOL _overviewVisible;
}

- (instancetype)_finchInitWithIdentifier:(NSWindowTabbingIdentifier)identifier
{
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _windows = (NSMutableArray *)CFArrayCreateMutable(NULL, 0, NULL);
    }
    return self;
}

- (void)dealloc
{
    [_identifier release];
    [_windows release];
    [super dealloc];
}

- (NSWindowTabbingIdentifier)identifier { return _identifier; }
- (NSArray<NSWindow *> *)windows { return [[_windows copy] autorelease]; }
- (BOOL)isOverviewVisible { return _overviewVisible; }
- (void)setOverviewVisible:(BOOL)visible { _overviewVisible = visible; }
- (BOOL)isTabBarVisible { return [_windows count] > 1; }
- (NSWindow *)selectedWindow { return _selected; }

/* Shows the selected window where the group is, and takes the others off screen. */
- (void)setSelectedWindow:(NSWindow *)window
{
    if (!window || ![_windows containsObject:window])
        return;
    NSWindow *previous = _selected;
    _selected = window;
    if (previous && previous != window && [previous isVisible]) {
        [window setFrame:[previous frame] display:NO];
        [window orderWindow:NSWindowAbove relativeTo:[previous windowNumber]];
        [previous orderOut:nil];
        if ([previous isKeyWindow])
            [window makeKeyWindow];
    }
}

- (void)_finchAttach:(NSWindow *)window
{
    NSWindowTabGroup *old = objc_getAssociatedObject(window, &group_key);
    if (old && old != self)
        [old removeWindow:window];
    objc_setAssociatedObject(window, &group_key, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)insertWindow:(NSWindow *)window atIndex:(NSInteger)index
{
    if (!window || [_windows containsObject:window])
        return;
    [self _finchAttach:window];
    [_windows insertObject:window atIndex:(NSUInteger)MAX(0, MIN(index, (NSInteger)[_windows count]))];
    if (!_selected)
        _selected = window;
}

- (void)addWindow:(NSWindow *)window
{
    [self insertWindow:window atIndex:(NSInteger)[_windows count]];
}

/* A window leaves the group (closed, or moved to a window of its own); the tab beside it
   is selected if it was. */
- (void)removeWindow:(NSWindow *)window
{
    NSUInteger i = [_windows indexOfObject:window];
    if (i == NSNotFound)
        return;
    BOOL wasSelected = _selected == window;
    BOOL wasOnScreen = [window isVisible];
    [_windows removeObjectAtIndex:i];
    if (objc_getAssociatedObject(window, &group_key) == self)
        objc_setAssociatedObject(window, &group_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (wasSelected) {
        _selected = nil;
        if ([_windows count]) {
            NSWindow *next = [_windows objectAtIndex:MIN(i, [_windows count] - 1)];
            _selected = next;
            if (wasOnScreen) {
                [next setFrame:[window frame] display:NO];
                [next makeKeyAndOrderFront:nil];
            }
        }
    }
}

@end

@implementation NSWindow (FinchTabbing)

- (NSWindowTabGroup *)tabGroup
{
    NSWindowTabGroup *g = objc_getAssociatedObject(self, &group_key);
    if (!g) {
        g = [[[NSWindowTabGroup alloc] _finchInitWithIdentifier:[self tabbingIdentifier]] autorelease];
        [g addWindow:self];
    }
    return g;
}

- (NSWindowTab *)tab
{
    NSWindowTab *t = objc_getAssociatedObject(self, &tab_key);
    if (!t) {
        t = [[[NSWindowTab alloc] _finchInitWithWindow:self] autorelease];
        objc_setAssociatedObject(self, &tab_key, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return t;
}

/* Unless set, Apple's form: the class, its controller's and delegate's, and "VT". */
- (NSWindowTabbingIdentifier)tabbingIdentifier
{
    NSString *set = objc_getAssociatedObject(self, &identifier_key);
    if (set)
        return set;
    return [NSString stringWithFormat:@"%@-%@-%@-VT-", [self className],
                                      [self windowController] ? NSStringFromClass([[self windowController] class]) : @"(null)",
                                      [self delegate] ? NSStringFromClass([(id)[self delegate] class]) : @"(null)"];
}

- (void)setTabbingIdentifier:(NSWindowTabbingIdentifier)identifier
{
    objc_setAssociatedObject(self, &identifier_key, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (NSArray<NSWindow *> *)tabbedWindows
{
    NSWindowTabGroup *g = objc_getAssociatedObject(self, &group_key);
    return [[g windows] count] > 1 ? [g windows] : nil;
}

/* The new tab goes beside this one (after it for NSWindowAbove) and is selected. */
- (void)addTabbedWindow:(NSWindow *)window ordered:(NSWindowOrderingMode)ordered
{
    if (!window || window == self)
        return;
    NSWindowTabGroup *g = [self tabGroup];
    NSUInteger at = [[g windows] indexOfObject:self];
    [g insertWindow:window atIndex:(NSInteger)(ordered == NSWindowBelow ? at : at + 1)];
    [window setFrame:[self frame] display:NO];
    if ([self isVisible]) {
        [g setSelectedWindow:self];
        [g setSelectedWindow:window];
    }
}

- (void)_finchSelectTabBy:(NSInteger)step
{
    NSArray *ws = [[self tabGroup] windows];
    NSUInteger n = [ws count], i = [ws indexOfObject:[[self tabGroup] selectedWindow] ?: self];
    if (n < 2 || i == NSNotFound)
        return;
    [[self tabGroup] setSelectedWindow:[ws objectAtIndex:(i + n + (NSUInteger)step) % n]];
}

- (IBAction)selectNextTab:(id)sender { [self _finchSelectTabBy:1]; }
- (IBAction)selectPreviousTab:(id)sender { [self _finchSelectTabBy:-1]; }

- (IBAction)moveTabToNewWindow:(id)sender
{
    NSWindowTabGroup *g = objc_getAssociatedObject(self, &group_key);
    if ([[g windows] count] < 2)
        return;
    NSRect frame = [self frame];
    [g removeWindow:self];
    [self setFrame:NSOffsetRect(frame, 24, -24) display:NO];
    [self makeKeyAndOrderFront:nil];
}

- (IBAction)mergeAllWindows:(id)sender
{
    for (NSWindow *w in [NSApp windows])
        if (w != self && [w isVisible] && [[w tabbingIdentifier] isEqualToString:[self tabbingIdentifier]] &&
            [w tabbingMode] != NSWindowTabbingModeDisallowed)
            [self addTabbedWindow:w ordered:NSWindowAbove];
    [[self tabGroup] setSelectedWindow:self];
}

- (IBAction)toggleTabBar:(id)sender {}
- (IBAction)toggleTabOverview:(id)sender
{
    [[self tabGroup] setOverviewVisible:![[self tabGroup] isOverviewVisible]];
}

@end

void
FinchWindowTabWillClose(NSWindow *window)
{
    [(NSWindowTabGroup *)objc_getAssociatedObject(window, &group_key) removeWindow:window];
}
