/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSPopover: the content view controller's view in a borderless child window
 * of the anchor's window, 13 points of Finch-drawn bubble and pointer around
 * the content on every side, the window's edge touching the positioning rect
 * on the preferred edge (flipped views swap MinY and MaxY), moved to another
 * edge when it would leave the screen. Geometry, delegate and notification
 * order as measured on macOS 26.4. Transient popovers close on clicks outside
 * them, semitransient ones on clicks in the anchor's window, both on Escape.
 */
#import "AppKit_Finch.h"

NSString *const NSPopoverCloseReasonKey = @"NSPopoverCloseReasonKey";
NSPopoverCloseReasonValue const NSPopoverCloseReasonStandard = @"NSPopoverCloseReasonStandard";
NSPopoverCloseReasonValue const NSPopoverCloseReasonDetachToWindow = @"NSPopoverCloseReasonDetachToWindow";
NSNotificationName const NSPopoverWillShowNotification = @"NSPopoverWillShowNotification";
NSNotificationName const NSPopoverDidShowNotification = @"NSPopoverDidShowNotification";
NSNotificationName const NSPopoverWillCloseNotification = @"NSPopoverWillCloseNotification";
NSNotificationName const NSPopoverDidCloseNotification = @"NSPopoverDidCloseNotification";

static NSMutableArray *shown_popovers;
static char controller_popover;

@interface _FinchPopoverWindow : NSPanel
@end
@implementation _FinchPopoverWindow
- (BOOL)canBecomeKeyWindow
{
    return YES;
}
@end

@interface _FinchPopoverFrame : NSView
@property NSRectEdge edge;
@end
@implementation _FinchPopoverFrame
- (void)drawRect:(NSRect)dirty
{
    NSRect b = NSInsetRect([self bounds], 5, 5);
    [[NSColor windowBackgroundColor] setFill];
    NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:b xRadius:7 yRadius:7];
    [body fill];
    [[NSColor separatorColor] setStroke];
    [body stroke];
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    CGFloat x = NSMidX(b), y = NSMidY(b);
    switch (_edge) {
    case NSMinXEdge:
        [arrow moveToPoint:NSMakePoint(NSMaxX(b), y - 6)];
        [arrow lineToPoint:NSMakePoint(NSMaxX(b) + 5, y)];
        [arrow lineToPoint:NSMakePoint(NSMaxX(b), y + 6)];
        break;
    case NSMaxXEdge:
        [arrow moveToPoint:NSMakePoint(NSMinX(b), y - 6)];
        [arrow lineToPoint:NSMakePoint(NSMinX(b) - 5, y)];
        [arrow lineToPoint:NSMakePoint(NSMinX(b), y + 6)];
        break;
    case NSMinYEdge:
        [arrow moveToPoint:NSMakePoint(x - 6, NSMaxY(b))];
        [arrow lineToPoint:NSMakePoint(x, NSMaxY(b) + 5)];
        [arrow lineToPoint:NSMakePoint(x + 6, NSMaxY(b))];
        break;
    default:
        [arrow moveToPoint:NSMakePoint(x - 6, NSMinY(b))];
        [arrow lineToPoint:NSMakePoint(x, NSMinY(b) - 5)];
        [arrow lineToPoint:NSMakePoint(x + 6, NSMinY(b))];
        break;
    }
    [arrow closePath];
    [[NSColor windowBackgroundColor] setFill];
    [arrow fill];
}
@end

@implementation NSPopover {
    __weak id<NSPopoverDelegate> _delegate;
    NSAppearance *_appearance;
    NSViewController *_controller;
    NSView *_anchor;
    _FinchPopoverWindow *_window;
    NSSize _size;
    NSRect _position;
    NSRectEdge _edge;
    NSPopoverBehavior _behavior;
    BOOL _animates, _shown, _fullSize;
}

- (instancetype)init
{
    self = [super init];
    if (self)
        _animates = YES;
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [super initWithCoder:c];
    if (self) {
        _animates = [c containsValueForKey:@"NSAnimates"] ? [c decodeBoolForKey:@"NSAnimates"] : YES;
        _behavior = [c decodeIntegerForKey:@"NSBehavior"];
        _size = NSMakeSize([c decodeDoubleForKey:@"NSContentWidth"], [c decodeDoubleForKey:@"NSContentHeight"]);
        _fullSize = [c decodeBoolForKey:@"NSHasFullSizeContent"];
        [self setContentViewController:[c decodeObjectForKey:@"NSContentViewController"]];
        _appearance = [[c decodeObjectForKey:@"NSAppearance"] retain];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [super encodeWithCoder:c];
    [c encodeBool:_animates forKey:@"NSAnimates"];
    [c encodeInteger:_behavior forKey:@"NSBehavior"];
    [c encodeDouble:_size.width forKey:@"NSContentWidth"];
    [c encodeDouble:_size.height forKey:@"NSContentHeight"];
    [c encodeBool:_fullSize forKey:@"NSHasFullSizeContent"];
    [c encodeObject:_controller forKey:@"NSContentViewController"];
    [c encodeObject:_appearance forKey:@"NSAppearance"];
}
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (objc_getAssociatedObject(_controller, &controller_popover) == self)
        objc_setAssociatedObject(_controller, &controller_popover, nil, OBJC_ASSOCIATION_ASSIGN);
    [_appearance release];
    [_controller release];
    [_anchor release];
    [_window release];
    [super dealloc];
}
- (id<NSPopoverDelegate>)delegate
{
    return _delegate;
}
- (void)setDelegate:(id<NSPopoverDelegate>)v
{
    _delegate = v;
}
- (NSAppearance *)appearance
{
    return _appearance;
}
- (void)setAppearance:(NSAppearance *)a
{
    if (a != _appearance) {
        [_appearance release];
        _appearance = [a retain];
        [_window setAppearance:a];
    }
}
- (NSAppearance *)effectiveAppearance
{
    return _appearance ?: [_anchor effectiveAppearance] ?: [NSAppearance appearanceNamed:NSAppearanceNameVibrantLight];
}
- (BOOL)animates
{
    return _animates;
}
- (void)setAnimates:(BOOL)v
{
    _animates = v;
}
- (NSPopoverBehavior)behavior
{
    return _behavior;
}
- (void)setBehavior:(NSPopoverBehavior)v
{
    _behavior = v;
}
- (BOOL)hasFullSizeContent
{
    return _fullSize;
}
- (void)setHasFullSizeContent:(BOOL)v
{
    _fullSize = v;
}
- (BOOL)isShown
{
    return _shown;
}
- (BOOL)isDetached
{
    return NO;
}
- (NSViewController *)contentViewController
{
    return _controller;
}
- (void)setContentViewController:(NSViewController *)v
{
    if (v == _controller)
        return;
    if (_shown)
        [self close];
    if (_controller)
        objc_setAssociatedObject(_controller, &controller_popover, nil, OBJC_ASSOCIATION_ASSIGN);
    [_controller release];
    _controller = [v retain];
    if (v)
        objc_setAssociatedObject(v, &controller_popover, self, OBJC_ASSOCIATION_ASSIGN);
}
- (NSSize)contentSize
{
    return _size;
}
- (void)setContentSize:(NSSize)v
{
    _size = NSMakeSize(MAX(0, v.width), MAX(0, v.height));
    if (_shown)
        [self _finchPosition];
}
- (NSRect)positioningRect
{
    return _position;
}
- (void)setPositioningRect:(NSRect)v
{
    _position = v;
    if (_shown)
        [self _finchPosition];
}

- (void)_finchPost:(NSString *)name selector:(SEL)selector closing:(BOOL)closing
{
    NSDictionary *info =
        closing ? @{NSPopoverCloseReasonKey : NSPopoverCloseReasonStandard, @"NSPopoverCloseReasonUserInfoKey" : @0}
                : nil;
    NSNotification *n = [NSNotification notificationWithName:name object:self userInfo:info];
    if ([_delegate respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(_delegate, selector, n);
    [[NSNotificationCenter defaultCenter] postNotification:n];
}
static NSRect popover_frame(NSRect anchor, NSSize size, NSRectEdge edge)
{
    NSRect r = NSMakeRect(NSMidX(anchor) - size.width / 2, NSMidY(anchor) - size.height / 2, size.width, size.height);
    if (edge == NSMinXEdge)
        r.origin.x = NSMinX(anchor) - size.width;
    else if (edge == NSMaxXEdge)
        r.origin.x = NSMaxX(anchor);
    else if (edge == NSMinYEdge)
        r.origin.y = NSMinY(anchor) - size.height;
    else
        r.origin.y = NSMaxY(anchor);
    return r;
}
- (void)_finchPosition
{
    NSRect anchor = [[_anchor window] convertRectToScreen:[_anchor convertRect:_position toView:nil]];
    NSSize outer = NSMakeSize(_size.width + 26, _size.height + 26);
    NSRectEdge edge = _edge;
    if ([_anchor isFlipped] && (edge == NSMinYEdge || edge == NSMaxYEdge))
        edge = edge == NSMinYEdge ? NSMaxYEdge : NSMinYEdge;
    NSRect frame = popover_frame(anchor, outer, edge), screen = [[[_anchor window] screen] visibleFrame];
    if (!NSIsEmptyRect(screen) && !NSContainsRect(screen, frame)) {
        NSRectEdge candidates[] = {(NSRectEdge)(edge ^ 2), NSMinXEdge, NSMaxXEdge, NSMinYEdge, NSMaxYEdge};
        for (unsigned i = 0; i < 5; i++) {
            NSRect r = popover_frame(anchor, outer, candidates[i]);
            if (NSContainsRect(screen, r)) {
                frame = r;
                edge = candidates[i];
                break;
            }
        }
        frame.origin.x = MAX(NSMinX(screen), MIN(frame.origin.x, NSMaxX(screen) - frame.size.width));
        frame.origin.y = MAX(NSMinY(screen), MIN(frame.origin.y, NSMaxY(screen) - frame.size.height));
    }
    [_window setFrame:frame display:NO];
    _FinchPopoverFrame *wrapper = (id)[_window contentView];
    [wrapper setEdge:edge];
    [[_controller view] setFrame:NSMakeRect(13, 13, _size.width, _size.height)];
    [wrapper setNeedsDisplay:YES];
}
- (void)_finchParentGone:(NSNotification *)n
{
    [self close];
}
- (void)_finchParentMoved:(NSNotification *)n
{
    if (_shown)
        [self _finchPosition];
}

static void install_popover_monitor(void)
{
    if (shown_popovers)
        return;
    shown_popovers = [[NSMutableArray alloc] init];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                                                  NSEventMaskOtherMouseDown | NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *e) {
                                            for (NSPopover *p in [[shown_popovers copy] autorelease]) {
                                                if (p->_behavior == NSPopoverBehaviorApplicationDefined)
                                                    continue;
                                                if ([e type] == NSEventTypeKeyDown) {
                                                    if ([e keyCode] == 53 ||
                                                        [[e charactersIgnoringModifiers] isEqualToString:@"\033"]) {
                                                        [p performClose:nil];
                                                        return nil;
                                                    }
                                                } else {
                                                    NSWindow *w = [e window];
                                                    BOOL inside = NO;
                                                    for (NSWindow *q = w; q; q = [q parentWindow])
                                                        if (q == p->_window)
                                                            inside = YES;
                                                    /* transient: any click outside; semitransient: clicks in
                                                       the anchor's window only (NSPopover.h) */
                                                    if (!inside && (p->_behavior == NSPopoverBehaviorTransient ||
                                                                    w == [p->_anchor window]))
                                                        [p performClose:nil];
                                                }
                                            }
                                            return e;
                                          }];
}
- (void)showRelativeToRect:(NSRect)r ofView:(NSView *)v preferredEdge:(NSRectEdge)edge
{
    if (!v || ![v window])
        [NSException raise:NSInvalidArgumentException format:@"A popover needs an anchor view in a window."];
    if (_behavior == NSPopoverBehaviorSemitransient && [[v window] parentWindow])
        [NSException raise:NSInvalidArgumentException
                    format:@"A semitransient popover cannot attach to a child window."];
    NSView *content = [_controller view];
    if (!content)
        [NSException raise:NSInternalInconsistencyException
                    format:@"A popover needs a content view controller and view."];
    if (![[v window] isVisible] || [v isHiddenOrHasHiddenAncestor])
        return;
    BOOL already = _shown;
    NSWindow *oldParent = [_anchor window];
    if (v != _anchor) {
        [_anchor release];
        _anchor = [v retain];
    }
    _position = NSIsEmptyRect(r) ? [v bounds] : r;
    _edge = edge;
    if (!already) {
        /* as Apple's: the controller's preferred size, when it has one, wins at each showing */
        NSSize preferred = [_controller preferredContentSize];
        if (preferred.width > 0 && preferred.height > 0)
            _size = preferred;
        if (_size.width == 0)
            _size.width = [content frame].size.width;
        if (_size.height == 0)
            _size.height = [content frame].size.height;
        [self _finchPost:NSPopoverWillShowNotification selector:@selector(popoverWillShow:) closing:NO];
        if (!_window) {
            _window = [[_FinchPopoverWindow alloc] initWithContentRect:NSZeroRect
                                                             styleMask:NSWindowStyleMaskBorderless
                                                               backing:NSBackingStoreBuffered
                                                                 defer:YES];
            [_window setReleasedWhenClosed:NO];
            [_window setOpaque:NO];
            [_window setBackgroundColor:[NSColor clearColor]];
            [_window setHasShadow:YES];
            [_window setLevel:NSNormalWindowLevel];
            [_window setContentView:[[[_FinchPopoverFrame alloc] initWithFrame:NSZeroRect] autorelease]];
        }
        [_window setAppearance:[self effectiveAppearance]];
        [_controller viewWillAppear];
        [[_window contentView] addSubview:content];
        [_controller setNextResponder:self];
        [content setNextResponder:_controller];
        install_popover_monitor();
        [shown_popovers addObject:self];
        _shown = YES;
    }
    if (oldParent != [v window])
        [oldParent removeChildWindow:_window];
    [self _finchPosition];
    if ([_window parentWindow] != [v window])
        [[v window] addChildWindow:_window ordered:NSWindowAbove];
    [_window orderFront:nil];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self];
    [nc addObserver:self selector:@selector(_finchParentGone:) name:NSWindowWillCloseNotification object:[v window]];
    [nc addObserver:self selector:@selector(_finchParentMoved:) name:NSWindowDidMoveNotification object:[v window]];
    [nc addObserver:self selector:@selector(_finchParentMoved:) name:NSWindowDidResizeNotification object:[v window]];
    if (!already) {
        [_controller viewDidAppear];
        [self _finchPost:NSPopoverDidShowNotification selector:@selector(popoverDidShow:) closing:NO];
    }
}
- (void)showRelativeToToolbarItem:(NSToolbarItem *)item
{
    NSView *v = [item view];
    if (v)
        [self showRelativeToRect:[v bounds] ofView:v preferredEdge:NSMinYEdge];
}
- (void)performClose:(id)sender
{
    if (![_delegate respondsToSelector:@selector(popoverShouldClose:)] || [_delegate popoverShouldClose:self])
        [self close];
}
- (void)close
{
    if (!_shown)
        return;
    [[self retain] autorelease];
    [self _finchPost:NSPopoverWillCloseNotification selector:@selector(popoverWillClose:) closing:YES];
    [_controller viewWillDisappear];
    [[_window parentWindow] removeChildWindow:_window];
    [_window orderOut:nil];
    [[_controller view] removeFromSuperview];
    _shown = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_controller viewDidDisappear];
    [self _finchPost:NSPopoverDidCloseNotification selector:@selector(popoverDidClose:) closing:YES];
    [shown_popovers removeObjectIdenticalTo:self];
}
@end

FINCH_PRIVATE BOOL FinchDismissPopoverController(NSViewController *controller)
{
    NSPopover *p = objc_getAssociatedObject(controller, &controller_popover);
    if (!p || ![p isShown])
        return NO;
    [p close];
    return YES;
}
