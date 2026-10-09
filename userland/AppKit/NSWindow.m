/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSWindow: a window-server window (docs/design/WINDOWSERVER.md) holding a
 * tree of views. The root of the tree is the frame view (NSThemeFrame, as
 * on macOS), which draws the background and, for titled windows, Finch's
 * title bar; the content view is its subview.
 *
 * Frames are in AppKit's screen coordinates (origin at the main screen's
 * bottom left, y up); the window server's are y down from the top, so they
 * are converted at the edge. Drawing goes into the window's shared buffer
 * through a CG bitmap context whose user space is the window's base
 * coordinates; the area drawn is flushed to the server.
 */
#import "NSView_Finch.h"

NSNotificationName NSWindowDidBecomeKeyNotification = @"NSWindowDidBecomeKeyNotification";
NSNotificationName NSWindowDidBecomeMainNotification = @"NSWindowDidBecomeMainNotification";
NSNotificationName NSWindowDidChangeScreenNotification = @"NSWindowDidChangeScreenNotification";
NSNotificationName NSWindowDidDeminiaturizeNotification = @"NSWindowDidDeminiaturizeNotification";
NSNotificationName NSWindowDidExposeNotification = @"NSWindowDidExposeNotification";
NSNotificationName NSWindowDidMiniaturizeNotification = @"NSWindowDidMiniaturizeNotification";
NSNotificationName NSWindowDidMoveNotification = @"NSWindowDidMoveNotification";
NSNotificationName NSWindowDidResignKeyNotification = @"NSWindowDidResignKeyNotification";
NSNotificationName NSWindowDidResignMainNotification = @"NSWindowDidResignMainNotification";
NSNotificationName NSWindowDidResizeNotification = @"NSWindowDidResizeNotification";
NSNotificationName NSWindowDidUpdateNotification = @"NSWindowDidUpdateNotification";
NSNotificationName NSWindowWillCloseNotification = @"NSWindowWillCloseNotification";
NSNotificationName NSWindowWillMiniaturizeNotification = @"NSWindowWillMiniaturizeNotification";
NSNotificationName NSWindowWillMoveNotification = @"NSWindowWillMoveNotification";
NSNotificationName NSWindowWillBeginSheetNotification = @"NSWindowWillBeginSheetNotification";
NSNotificationName NSWindowDidEndSheetNotification = @"NSWindowDidEndSheetNotification";
NSNotificationName const NSWindowDidChangeBackingPropertiesNotification = @"NSWindowDidChangeBackingPropertiesNotification";
NSNotificationName NSWindowDidChangeScreenProfileNotification = @"NSWindowDidChangeScreenProfileNotification";
NSNotificationName const NSWindowWillStartLiveResizeNotification = @"NSWindowWillStartLiveResizeNotification";
NSNotificationName const NSWindowDidEndLiveResizeNotification = @"NSWindowDidEndLiveResizeNotification";
NSNotificationName const NSWindowWillEnterFullScreenNotification = @"NSWindowWillEnterFullScreenNotification";
NSNotificationName const NSWindowDidEnterFullScreenNotification = @"NSWindowDidEnterFullScreenNotification";
NSNotificationName const NSWindowWillExitFullScreenNotification = @"NSWindowWillExitFullScreenNotification";
NSNotificationName const NSWindowDidExitFullScreenNotification = @"NSWindowDidExitFullScreenNotification";
NSNotificationName const NSWindowDidChangeOcclusionStateNotification = @"NSWindowDidChangeOcclusionStateNotification";
NSString *const NSBackingPropertyOldScaleFactorKey = @"NSBackingPropertyOldScaleFactorKey";
NSString *const NSBackingPropertyOldColorSpaceKey = @"NSBackingPropertyOldColorSpaceKey";

/* Finch's title bar: 32 points, as macOS 26's; 24 for utility windows. */
static CGFloat
titlebar_height(NSWindowStyleMask style)
{
    if (!(style & NSWindowStyleMaskTitled) || (style & NSWindowStyleMaskFullSizeContentView))
        return 0;
    return (style & NSWindowStyleMaskUtilityWindow) ? 24 : 32;
}

static CFMutableArrayRef all_windows;  /* not retaining; in creation order */

#pragma mark - The frame view

@interface NSThemeFrame : NSView
@end

enum { BUTTON_CLOSE, BUTTON_MINIATURIZE, BUTTON_ZOOM };

@implementation NSThemeFrame {
    int _pressed;  /* the title-bar button held, or -1 */
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    _pressed = -1;
    return self;
}

- (BOOL)isOpaque
{
    return [[self window] isOpaque];
}

static NSRect
button_rect(int which, NSRect bounds, CGFloat titlebar)
{
    CGFloat d = 12, gap = 8, left = 12;
    return NSMakeRect(left + which * (d + gap), NSMaxY(bounds) - titlebar / 2 - d / 2, d, d);
}

static void
fill_circle(CGContextRef cg, NSRect r, CGFloat red, CGFloat green, CGFloat blue, CGFloat dark)
{
    CGContextSetRGBFillColor(cg, red * dark, green * dark, blue * dark, 1);
    CGContextFillEllipseInRect(cg, NSRectToCGRect(r));
    CGContextSetRGBStrokeColor(cg, 0, 0, 0, 0.12);
    CGContextSetLineWidth(cg, 0.5);
    CGContextStrokeEllipseInRect(cg, NSRectToCGRect(NSInsetRect(r, 0.25, 0.25)));
}

- (void)drawRect:(NSRect)dirty
{
    NSWindow *w = [self window];
    CGContextRef cg = [[NSGraphicsContext currentContext] CGContext];
    if (!cg)
        return;
    NSRect b = [self bounds];
    CGColorRef bg = [[w backgroundColor] CGColor];
    if (bg)
        CGContextSetFillColorWithColor(cg, bg);
    else
        CGContextSetRGBFillColor(cg, 0.925, 0.925, 0.925, 1);
    CGContextFillRect(cg, NSRectToCGRect(dirty));
    CGFloat t = titlebar_height([w styleMask]);
    if (t == 0)
        return;
    /* the title bar: a band a little lighter than the background, and a hairline under it */
    NSRect bar = NSMakeRect(0, NSMaxY(b) - t, b.size.width, t);
    BOOL key = [w isKeyWindow];
    CGContextSetRGBFillColor(cg, key ? 0.965 : 0.945, key ? 0.965 : 0.945, key ? 0.965 : 0.945, 1);
    CGContextFillRect(cg, NSRectToCGRect(bar));
    CGContextSetRGBFillColor(cg, 0, 0, 0, 0.1);
    CGContextFillRect(cg, CGRectMake(0, NSMinY(bar), b.size.width, 0.5));
    NSWindowStyleMask style = [w styleMask];
    BOOL enabled[3] = {(style & NSWindowStyleMaskClosable) != 0, (style & NSWindowStyleMaskMiniaturizable) != 0,
                       (style & NSWindowStyleMaskResizable) != 0};
    static const CGFloat colours[3][3] = {{0.93, 0.33, 0.30}, {0.96, 0.73, 0.22}, {0.30, 0.76, 0.33}};
    for (int i = 0; i < 3; i++) {
        NSRect r = button_rect(i, b, t);
        if (enabled[i] && key)
            fill_circle(cg, r, colours[i][0], colours[i][1], colours[i][2], _pressed == i ? 0.8 : 1);
        else
            fill_circle(cg, r, 0.82, 0.82, 0.82, 1);
    }
    NSString *title = [w title];
    if ([title length]) {
        id font = [(id)FINCH_CLASS(NSFont) respondsToSelector:@selector(titleBarFontOfSize:)]
                      ? [(id)FINCH_CLASS(NSFont) titleBarFontOfSize:0]
                      : nil;
        CGColorRef ink = CGColorCreateSRGB(0, 0, 0, key ? 0.85 : 0.45);
        id color = [(id)FINCH_CLASS(NSColor) respondsToSelector:@selector(colorWithCGColor:)]
                       ? [(id)FINCH_CLASS(NSColor) colorWithCGColor:ink]
                       : nil;
        CGColorRelease(ink);
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        if (font)
            attrs[@"NSFont"] = font;
        if (color)
            attrs[@"NSColor"] = color;
        if ([title respondsToSelector:@selector(sizeWithAttributes:)]) {
            NSSize size = [title sizeWithAttributes:attrs];
            CGFloat left = NSMaxX(button_rect(2, b, t)) + 12;
            CGFloat x = MAX(left, floor((b.size.width - size.width) / 2));
            [title drawAtPoint:NSMakePoint(x, NSMinY(bar) + floor((t - size.height) / 2)) withAttributes:attrs];
        }
    }
}

- (int)_buttonAt:(NSPoint)p
{
    NSWindow *w = [self window];
    CGFloat t = titlebar_height([w styleMask]);
    if (t == 0)
        return -1;
    for (int i = 0; i < 3; i++)
        if (NSPointInRect(p, NSInsetRect(button_rect(i, [self bounds], t), -2, -2)))
            return i;
    return -1;
}

- (BOOL)_inTitlebar:(NSPoint)p
{
    CGFloat t = titlebar_height([[self window] styleMask]);
    return t > 0 && p.y >= NSMaxY([self bounds]) - t;
}

/* Title-bar buttons, and moving the window by its title bar or background. */
- (void)mouseDown:(NSEvent *)event
{
    NSWindow *w = [self window];
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    int button = [self _buttonAt:p];
    if (button >= 0) {
        _pressed = button;
        [self setNeedsDisplay:YES];
        [w displayIfNeeded];
        NSEvent *e;
        BOOL inside = YES;
        while ((e = [w nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged])) {
            inside = [self _buttonAt:[self convertPoint:[e locationInWindow] fromView:nil]] == button;
            if ([e type] == NSEventTypeLeftMouseUp)
                break;
        }
        _pressed = -1;
        [self setNeedsDisplay:YES];
        if (inside) {
            if (button == BUTTON_CLOSE)
                [w performClose:self];
            else if (button == BUTTON_MINIATURIZE)
                [w performMiniaturize:self];
            else
                [w performZoom:self];
        }
        return;
    }
    if ([self _inTitlebar:p] || [w isMovableByWindowBackground])
        [w performWindowDragWithEvent:event];
}

@end

#pragma mark - NSWindow

@implementation NSWindow {
    NSRect _frame;
    NSWindowStyleMask _style;
    NSBackingStoreType _backing;
    NSThemeFrame *_frameView;
    NSView *_contentView;  /* retained by the frame view */
    NSString *_title, *_representedFilename;
    NSURL *_representedURL;
    id<NSWindowDelegate> _delegate;  /* not retained */
    NSWindowController *_windowController;  /* not retained */
    uint32_t _server;  /* the window-server window, or 0 before it's made */
    CGContextRef _context;
    NSWindowLevel _level;
    NSResponder *_firstResponder;  /* not retained */
    NSView *_initialFirstResponder;  /* not retained */
    NSView *_mouseDownView;  /* where a mouse-down went: drags and the up follow it */
    NSColor *_backgroundColor;
    CGFloat _alpha;
    NSSize _minSize, _maxSize, _contentMinSize, _contentMaxSize, _resizeIncrements, _aspectRatio;
    NSRect _dirty;  /* window coordinates */
    NSWindowCollectionBehavior _collectionBehavior;
    NSInteger _number;
    NSWindowTabbingMode _tabbingMode;
    NSAppearance *_appearance;
    NSWindowSharingType _sharingType;
    NSPoint _cascadePoint;
    NSString *_frameAutosaveName;
    NSView *_lastMouseView;  /* for entered and exited */
    NSWindow *_parent;
    NSMutableArray *_children;
    NSToolbar *_toolbar;
    struct {
        unsigned visible : 1;
        unsigned key : 1;
        unsigned main : 1;
        unsigned released : 1;
        unsigned opaque : 1;
        unsigned shadow : 1;
        unsigned mouseMoved : 1;
        unsigned autodisplay : 1;
        unsigned oneShot : 1;
        unsigned excluded : 1;
        unsigned hidesOnDeactivate : 1;
        unsigned movable : 1;
        unsigned movableByBackground : 1;
        unsigned documentEdited : 1;
        unsigned ignoresMouse : 1;
        unsigned miniaturized : 1;
        unsigned displaying : 1;
        unsigned flushDisabled : 1;
        unsigned closing : 1;
        unsigned preventsApplicationTermination : 1;
        unsigned titleHidden : 1;
        unsigned titlebarTransparent : 1;
        unsigned restorable : 1;
        unsigned canHide : 1;
    } _w;
}


+ (NSRect)frameRectForContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style
{
    rect.size.height += titlebar_height(style);
    return rect;
}

+ (NSRect)contentRectForFrameRect:(NSRect)rect styleMask:(NSWindowStyleMask)style
{
    rect.size.height -= titlebar_height(style);
    return rect;
}

+ (CGFloat)minFrameWidthWithTitle:(NSString *)title styleMask:(NSWindowStyleMask)style
{
    return (style & NSWindowStyleMaskTitled) ? 76 : 0;
}

+ (NSWindowDepth)defaultDepthLimit
{
    return NSWindowDepthTwentyfourBitRGB;
}

- (NSRect)frameRectForContentRect:(NSRect)rect
{
    return [[self class] frameRectForContentRect:rect styleMask:_style];
}

- (NSRect)contentRectForFrameRect:(NSRect)rect
{
    return [[self class] contentRectForFrameRect:rect styleMask:_style];
}

- (instancetype)init
{
    return [self initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered
                               defer:YES];
}

- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing defer:(BOOL)flag
{
    self = [super init];
    if (!self)
        return nil;
    _style = style;
    _backing = backing;
    _frame = [[self class] frameRectForContentRect:contentRect styleMask:style];
    _title = @"";
    _alpha = 1;
    _level = NSNormalWindowLevel;
    _minSize = NSMakeSize(0, titlebar_height(style));
    _maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    _contentMaxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    _resizeIncrements = NSMakeSize(1, 1);
    _number = -1;
    _w.released = YES;
    _w.opaque = YES;
    _w.shadow = YES;
    _w.autodisplay = YES;
    _w.movable = YES;
    _w.restorable = YES;
    _w.canHide = YES;
    _firstResponder = self;
    _frameView = [[NSThemeFrame alloc]
        initWithFrame:NSMakeRect(0, 0, _frame.size.width, _frame.size.height)];
    [_frameView setAutoresizesSubviews:YES];
    [_frameView _finchSetWindow:self];
    NSView *content = [[NSView alloc] initWithFrame:[self _contentFrameInFrameView]];
    [self setContentView:content];
    [content release];
    if (!all_windows)
        all_windows = CFArrayCreateMutable(NULL, 0, NULL);
    CFArrayAppendValue(all_windows, self);
    if (!flag)
        [self _finchServerWindow];
    return self;
}

- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing defer:(BOOL)flag screen:(NSScreen *)screen
{
    return [self initWithContentRect:contentRect styleMask:style backing:backing defer:flag];
}

+ (instancetype)windowWithContentViewController:(NSViewController *)controller
{
    NSView *view = [controller view];
    NSWindow *w = [[self alloc] initWithContentRect:[view frame]
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered defer:YES];
    [w setContentViewController:controller];
    [w setReleasedWhenClosed:NO];
    return [w autorelease];
}

- (void)dealloc
{
    CFIndex i = CFArrayGetFirstIndexOfValue(all_windows, CFRangeMake(0, CFArrayGetCount(all_windows)), self);
    if (i != kCFNotFound)
        CFArrayRemoveValueAtIndex(all_windows, i);
    [self _finchDestroyServerWindow];
    [_frameView _finchSetWindow:nil];
    [_frameView release];
    [_title release];
    [_representedFilename release];
    [_representedURL release];
    [_backgroundColor release];
    [_appearance release];
    [_frameAutosaveName release];
    [_children release];
    [_toolbar release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>", [self class], self];
}

/* All windows, front to back as far as Finch knows (creation order otherwise). */
FINCH_PRIVATE NSArray *
FinchAllWindows(void)
{
    return all_windows ? [NSArray arrayWithArray:(NSArray *)all_windows] : @[];
}

NSWindow *
FinchWindowForNumber(NSInteger number)
{
    if (number <= 0)
        return nil;
    for (NSWindow *w in (NSArray *)all_windows)
        if (w->_number == number)
            return w;
    return nil;
}

#pragma mark - The window server

static FWSRect
server_rect(NSRect frame)
{
    NSRect screen = [[NSScreen mainScreen] frame];
    return (FWSRect){frame.origin.x, NSMaxY(screen) - NSMaxY(frame), frame.size.width, frame.size.height};
}

static uint32_t
server_flags(NSWindow *w)
{
    return (w->_w.opaque && w->_alpha >= 1 ? FWS_WINDOW_OPAQUE : 0) | (w->_w.shadow ? FWS_WINDOW_SHADOW : 0) |
           (w->_w.ignoresMouse ? FWS_WINDOW_IGNORES_MOUSE : 0) | FWS_WINDOW_SHARED;
}

- (uint32_t)_finchServerWindow
{
    if (_server)
        return _server;
    if (!FWSConnect())
        return 0;
    _server = FWSCreateWindow(server_rect(_frame), (int32_t)_level, server_flags(self));
    if (!_server)
        return 0;
    _number = _server;
    FWSSetWindowTitle(_server, [_title UTF8String]);
    if (_alpha < 1)
        FWSSetWindowAlpha(_server, _alpha);
    [self _finchMakeContext];
    _dirty = NSMakeRect(0, 0, _frame.size.width, _frame.size.height);
    return _server;
}

- (void)_finchMakeContext
{
    if (_context)
        CGContextRelease(_context);
    _context = _server ? FWSCreateWindowContext(_server) : NULL;
}

- (void)_finchDestroyServerWindow
{
    if (_context)
        CGContextRelease(_context);
    _context = NULL;
    if (_server)
        FWSDestroyWindow(_server);
    _server = 0;
}

- (CGContextRef)_finchCGContext
{
    [self _finchServerWindow];
    return _context;
}

- (void)_finchFlushDrawing
{
    if (_server && !_w.flushDisabled)
        FWSFlushWindow(_server, (FWSRect){0, 0, 0, 0});
}

- (void)_finchInvalidateRect:(NSRect)rect
{
    rect = NSIntersectionRect(rect, NSMakeRect(0, 0, _frame.size.width, _frame.size.height));
    if (NSIsEmptyRect(rect))
        return;
    _dirty = NSIsEmptyRect(_dirty) ? rect : NSUnionRect(_dirty, rect);
    FinchApplicationNeedsDisplay();
}

#pragma mark - Drawing

- (BOOL)viewsNeedDisplay { return !NSIsEmptyRect(_dirty); }
- (void)setViewsNeedDisplay:(BOOL)flag
{
    if (flag)
        [self _finchInvalidateRect:NSMakeRect(0, 0, _frame.size.width, _frame.size.height)];
    else
        _dirty = NSZeroRect;
}
- (BOOL)isAutodisplay { return _w.autodisplay; }
- (void)setAutodisplay:(BOOL)flag { _w.autodisplay = flag; }
- (BOOL)isFlushWindowDisabled { return _w.flushDisabled; }
- (void)disableFlushWindow { _w.flushDisabled = YES; }
- (void)enableFlushWindow { _w.flushDisabled = NO; }
- (void)flushWindow { [self _finchFlushDrawing]; }
- (void)flushWindowIfNeeded { [self _finchFlushDrawing]; }
- (BOOL)canStoreColor { return YES; }
- (void)useOptimizedDrawing:(BOOL)flag {}
- (void)disableScreenUpdatesUntilFlush {}
- (NSGraphicsContext *)graphicsContext
{
    CGContextRef cg = [self _finchCGContext];
    return cg ? [NSGraphicsContext graphicsContextWithCGContext:cg flipped:NO] : nil;
}

- (void)display
{
    [self setViewsNeedDisplay:YES];
    [self displayIfNeeded];
}

- (void)displayIfNeeded
{
    if (NSIsEmptyRect(_dirty) || !_w.visible || _w.displaying)
        return;
    CGContextRef cg = [self _finchCGContext];
    if (!cg)
        return;
    _w.displaying = YES;
    [_frameView layoutSubtreeIfNeeded];
    NSRect dirty = NSIntegralRect(_dirty);
    _dirty = NSZeroRect;
    CGContextSaveGState(cg);
    CGContextClipToRect(cg, NSRectToCGRect(dirty));
    CGContextClearRect(cg, NSRectToCGRect(dirty));
    @try {
        FinchViewDrawTree(_frameView, cg, dirty, NO);
    } @finally {
        CGContextRestoreGState(cg);
        _w.displaying = NO;
    }
    CGContextFlush(cg);
    if (!_w.flushDisabled)
        FWSFlushWindow(_server, (FWSRect){dirty.origin.x, _frame.size.height - NSMaxY(dirty), dirty.size.width,
                                          dirty.size.height});
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidUpdateNotification object:self];
}

- (void)update
{
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidUpdateNotification object:self];
}

- (NSBackingStoreType)backingType { return _backing; }
- (void)setBackingType:(NSBackingStoreType)type { _backing = type; }

- (CGFloat)backingScaleFactor
{
    NSScreen *s = [self screen];
    return s ? [s backingScaleFactor] : FinchDefaultBackingScale();
}

- (NSRect)convertRectToBacking:(NSRect)r
{
    CGFloat s = [self backingScaleFactor];
    return NSMakeRect(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s);
}

- (NSRect)convertRectFromBacking:(NSRect)r
{
    CGFloat s = [self backingScaleFactor];
    return NSMakeRect(r.origin.x / s, r.origin.y / s, r.size.width / s, r.size.height / s);
}

- (NSPoint)convertPointToBacking:(NSPoint)p { CGFloat s = [self backingScaleFactor]; return NSMakePoint(p.x * s, p.y * s); }
- (NSPoint)convertPointFromBacking:(NSPoint)p { CGFloat s = [self backingScaleFactor]; return NSMakePoint(p.x / s, p.y / s); }
- (NSRect)backingAlignedRect:(NSRect)rect options:(NSAlignmentOptions)options
{
    return [self convertRectFromBacking:NSIntegralRectWithOptions([self convertRectToBacking:rect], options)];
}

- (NSRect)convertRectToScreen:(NSRect)r
{
    return NSOffsetRect(r, _frame.origin.x, _frame.origin.y);
}

- (NSRect)convertRectFromScreen:(NSRect)r
{
    return NSOffsetRect(r, -_frame.origin.x, -_frame.origin.y);
}

- (NSPoint)convertPointToScreen:(NSPoint)p
{
    return NSMakePoint(p.x + _frame.origin.x, p.y + _frame.origin.y);
}

- (NSPoint)convertPointFromScreen:(NSPoint)p
{
    return NSMakePoint(p.x - _frame.origin.x, p.y - _frame.origin.y);
}

- (NSPoint)convertBaseToScreen:(NSPoint)p { return [self convertPointToScreen:p]; }
- (NSPoint)convertScreenToBase:(NSPoint)p { return [self convertPointFromScreen:p]; }

- (NSPoint)mouseLocationOutsideOfEventStream
{
    return [self convertPointFromScreen:[NSEvent mouseLocation]];
}

#pragma mark - Views

- (NSRect)_contentFrameInFrameView
{
    NSRect r = NSMakeRect(0, 0, _frame.size.width, _frame.size.height);
    r.size.height -= titlebar_height(_style);
    return r;
}

- (__kindof NSView *)contentView { return _contentView; }

- (void)setContentView:(NSView *)view
{
    if (view == _contentView)
        return;
    NSView *old = _contentView;
    if (old) {
        [[old retain] autorelease];
        [old removeFromSuperview];
    }
    _contentView = view;
    if (view) {
        [view setFrame:[self _contentFrameInFrameView]];
        [_frameView addSubview:view];
        [view setNextResponder:self];
        if (_firstResponder == old && old)
            _firstResponder = self;
    }
    [_frameView setNeedsDisplay:YES];
}

- (NSViewController *)contentViewController
{
    return objc_getAssociatedObject(self, @selector(contentViewController));
}

- (void)setContentViewController:(NSViewController *)controller
{
    objc_setAssociatedObject(self, @selector(contentViewController), controller, OBJC_ASSOCIATION_RETAIN);
    NSView *v = [controller view];
    if (v) {
        NSRect frame = [v frame];
        [self setContentSize:frame.size];
        [self setContentView:v];
    }
    NSString *title = [controller title];
    if (title)
        [self setTitle:title];
}

- (NSRect)contentLayoutRect
{
    return [self _contentFrameInFrameView];
}

- (NSLayoutGuide *)contentLayoutGuide { return nil; }

- (NSView *)_finchFrameView { return _frameView; }

- (NSResponder *)firstResponder { return _firstResponder; }
- (NSView *)initialFirstResponder { return _initialFirstResponder; }
- (void)setInitialFirstResponder:(NSView *)view { _initialFirstResponder = view; }

/*
 * As Apple's: the old first responder must agree to resign; the new one is
 * asked only to become (not whether it accepts). If it refuses, or isn't in
 * this window, the window itself becomes first responder.
 */
- (BOOL)makeFirstResponder:(NSResponder *)responder
{
    if (responder == _firstResponder)
        return YES;
    NSResponder *old = _firstResponder;
    if (old && old != self && ![old resignFirstResponder])
        return NO;
    _firstResponder = self;
    if (!responder || responder == self)
        return YES;
    if ([responder isKindOfClass:[NSView class]] && [(NSView *)responder window] != self)
        return YES;
    if (![responder becomeFirstResponder])
        return NO;
    _firstResponder = responder;
    return YES;
}

- (void)_finchResetFirstResponder
{
    _firstResponder = self;
}

- (void)selectNextKeyView:(id)sender
{
    NSView *start = [_firstResponder isKindOfClass:[NSView class]] ? (NSView *)_firstResponder : _initialFirstResponder;
    NSView *next = start ? [start nextValidKeyView] : nil;
    if (!next && [_initialFirstResponder canBecomeKeyView])
        next = _initialFirstResponder;
    if (next)
        [self makeFirstResponder:next];
}

- (void)selectPreviousKeyView:(id)sender
{
    NSView *start = [_firstResponder isKindOfClass:[NSView class]] ? (NSView *)_firstResponder : _initialFirstResponder;
    NSView *prev = start ? [start previousValidKeyView] : nil;
    if (prev)
        [self makeFirstResponder:prev];
}

- (void)selectKeyViewFollowingView:(NSView *)view
{
    NSView *next = [view nextValidKeyView];
    if (next)
        [self makeFirstResponder:next];
}

- (void)selectKeyViewPrecedingView:(NSView *)view
{
    NSView *prev = [view previousValidKeyView];
    if (prev)
        [self makeFirstResponder:prev];
}

- (NSSelectionDirection)keyViewSelectionDirection { return NSDirectSelection; }
- (BOOL)autorecalculatesKeyViewLoop { return NO; }
- (void)setAutorecalculatesKeyViewLoop:(BOOL)flag {}
- (void)recalculateKeyViewLoop {}

#pragma mark - Properties

- (NSString *)title { return _title; }

- (void)setTitle:(NSString *)title
{
    if (!title)
        title = @"";
    [_title autorelease];
    _title = [title copy];
    if (_server)
        FWSSetWindowTitle(_server, [_title UTF8String]);
    if (titlebar_height(_style))
        [_frameView setNeedsDisplayInRect:NSMakeRect(0, _frame.size.height - titlebar_height(_style),
                                                     _frame.size.width, titlebar_height(_style))];
}

- (NSString *)subtitle { return @""; }
- (void)setSubtitle:(NSString *)subtitle {}
- (NSString *)representedFilename { return _representedFilename ?: @""; }
- (void)setRepresentedFilename:(NSString *)name { [_representedFilename autorelease]; _representedFilename = [name copy]; }
- (NSURL *)representedURL { return _representedURL; }
- (void)setRepresentedURL:(NSURL *)url { [_representedURL autorelease]; _representedURL = [url copy]; }
- (void)setTitleWithRepresentedFilename:(NSString *)filename
{
    [self setRepresentedFilename:filename];
    [self setTitle:[filename lastPathComponent]];
}
- (NSWindowTitleVisibility)titleVisibility { return _w.titleHidden ? NSWindowTitleHidden : NSWindowTitleVisible; }
- (void)setTitleVisibility:(NSWindowTitleVisibility)v { _w.titleHidden = v == NSWindowTitleHidden; }
- (BOOL)titlebarAppearsTransparent { return _w.titlebarTransparent; }
- (void)setTitlebarAppearsTransparent:(BOOL)flag { _w.titlebarTransparent = flag; }
- (NSWindowStyleMask)styleMask { return _style; }

- (void)setStyleMask:(NSWindowStyleMask)style
{
    NSRect content = [self contentRectForFrameRect:_frame];
    _style = style;
    _frame = [self frameRectForContentRect:content];
    [self setFrame:_frame display:YES];
    [_contentView setFrame:[self _contentFrameInFrameView]];
}

- (id<NSWindowDelegate>)delegate { return _delegate; }

- (void)setDelegate:(id<NSWindowDelegate>)delegate
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_delegate)
        [nc removeObserver:_delegate name:nil object:self];
    _delegate = delegate;
    if (!delegate)
        return;
    static const struct {
        const char *selector;
        NSNotificationName const *name;
    } hooks[] = {
        {"windowDidBecomeKey:", &NSWindowDidBecomeKeyNotification},
        {"windowDidBecomeMain:", &NSWindowDidBecomeMainNotification},
        {"windowDidResignKey:", &NSWindowDidResignKeyNotification},
        {"windowDidResignMain:", &NSWindowDidResignMainNotification},
        {"windowDidMove:", &NSWindowDidMoveNotification},
        {"windowWillMove:", &NSWindowWillMoveNotification},
        {"windowDidResize:", &NSWindowDidResizeNotification},
        {"windowWillClose:", &NSWindowWillCloseNotification},
        {"windowDidUpdate:", &NSWindowDidUpdateNotification},
        {"windowDidExpose:", &NSWindowDidExposeNotification},
        {"windowDidMiniaturize:", &NSWindowDidMiniaturizeNotification},
        {"windowDidDeminiaturize:", &NSWindowDidDeminiaturizeNotification},
        {"windowWillMiniaturize:", &NSWindowWillMiniaturizeNotification},
        {"windowDidChangeScreen:", &NSWindowDidChangeScreenNotification},
        {"windowDidChangeBackingProperties:", &NSWindowDidChangeBackingPropertiesNotification},
        {"windowWillStartLiveResize:", &NSWindowWillStartLiveResizeNotification},
        {"windowDidEndLiveResize:", &NSWindowDidEndLiveResizeNotification},
        {"windowDidChangeOcclusionState:", &NSWindowDidChangeOcclusionStateNotification},
    };
    for (size_t i = 0; i < sizeof hooks / sizeof *hooks; i++) {
        SEL sel = sel_registerName(hooks[i].selector);
        if (*hooks[i].name && [(id)delegate respondsToSelector:sel])
            [nc addObserver:delegate selector:sel name:*hooks[i].name object:self];
    }
}

- (NSWindowController *)windowController { return _windowController; }
- (void)setWindowController:(NSWindowController *)controller
{
    _windowController = controller;
    [self setNextResponder:controller];
}

- (NSInteger)windowNumber { return _number; }
- (NSWindowLevel)level { return _level; }

- (void)setLevel:(NSWindowLevel)level
{
    _level = level;
    if (_server)
        FWSSetWindowLevel(_server, (int32_t)level);
}

- (CGFloat)alphaValue { return _alpha; }

- (void)setAlphaValue:(CGFloat)alpha
{
    _alpha = alpha;
    if (_server) {
        FWSSetWindowAlpha(_server, alpha);
        FWSSetWindowFlags(_server, server_flags(self));
    }
}

- (BOOL)isOpaque { return _w.opaque; }
- (void)setOpaque:(BOOL)flag
{
    _w.opaque = flag;
    if (_server)
        FWSSetWindowFlags(_server, server_flags(self));
}
- (BOOL)hasShadow { return _w.shadow; }
- (void)setHasShadow:(BOOL)flag
{
    _w.shadow = flag;
    if (_server)
        FWSSetWindowFlags(_server, server_flags(self));
}
- (void)invalidateShadow {}
- (BOOL)ignoresMouseEvents { return _w.ignoresMouse; }
- (void)setIgnoresMouseEvents:(BOOL)flag
{
    _w.ignoresMouse = flag;
    if (_server)
        FWSSetWindowFlags(_server, server_flags(self));
}

- (NSColor *)backgroundColor
{
    if (_backgroundColor)
        return _backgroundColor;
    id cls = FINCH_CLASS(NSColor);
    return [cls respondsToSelector:@selector(windowBackgroundColor)] ? [cls windowBackgroundColor] : nil;
}

- (void)setBackgroundColor:(NSColor *)color
{
    [_backgroundColor autorelease];
    _backgroundColor = [color retain];
    [_frameView setNeedsDisplay:YES];
}

- (BOOL)isReleasedWhenClosed { return _w.released; }
- (void)setReleasedWhenClosed:(BOOL)flag { _w.released = flag; }
- (BOOL)acceptsMouseMovedEvents { return _w.mouseMoved; }
- (void)setAcceptsMouseMovedEvents:(BOOL)flag { _w.mouseMoved = flag; }
- (BOOL)isOneShot { return _w.oneShot; }
- (void)setOneShot:(BOOL)flag { _w.oneShot = flag; }
- (BOOL)isExcludedFromWindowsMenu { return _w.excluded; }
- (void)setExcludedFromWindowsMenu:(BOOL)flag { _w.excluded = flag; }
- (BOOL)hidesOnDeactivate { return _w.hidesOnDeactivate; }
- (void)setHidesOnDeactivate:(BOOL)flag { _w.hidesOnDeactivate = flag; }
- (BOOL)canHide { return _w.canHide; }
- (void)setCanHide:(BOOL)flag { _w.canHide = flag; }
- (BOOL)isMovable { return _w.movable; }
- (void)setMovable:(BOOL)flag { _w.movable = flag; }
- (BOOL)isMovableByWindowBackground { return _w.movableByBackground; }
- (void)setMovableByWindowBackground:(BOOL)flag { _w.movableByBackground = flag; }
- (BOOL)isDocumentEdited { return _w.documentEdited; }
- (void)setDocumentEdited:(BOOL)flag { _w.documentEdited = flag; }
- (BOOL)isRestorable { return _w.restorable; }
- (void)setRestorable:(BOOL)flag { _w.restorable = flag; }
- (BOOL)worksWhenModal { return NO; }
- (BOOL)isFloatingPanel { return NO; }
- (BOOL)isModalPanel { return NO; }
- (BOOL)isSheet { return NO; }
- (BOOL)isMiniaturizable { return (_style & NSWindowStyleMaskMiniaturizable) != 0; }
- (BOOL)isResizable { return (_style & NSWindowStyleMaskResizable) != 0; }
- (BOOL)isZoomable { return (_style & NSWindowStyleMaskResizable) != 0; }
- (BOOL)isMiniaturized { return _w.miniaturized; }
- (BOOL)isZoomed { return NO; }
- (BOOL)showsResizeIndicator { return NO; }
- (void)setShowsResizeIndicator:(BOOL)flag {}
- (BOOL)showsToolbarButton { return NO; }
- (void)setShowsToolbarButton:(BOOL)flag {}
- (NSWindowCollectionBehavior)collectionBehavior { return _collectionBehavior; }
- (void)setCollectionBehavior:(NSWindowCollectionBehavior)b { _collectionBehavior = b; }
- (NSWindowAnimationBehavior)animationBehavior { return NSWindowAnimationBehaviorDefault; }
- (void)setAnimationBehavior:(NSWindowAnimationBehavior)b {}
- (NSWindowTabbingMode)tabbingMode { return _tabbingMode; }
- (void)setTabbingMode:(NSWindowTabbingMode)mode { _tabbingMode = mode; }
+ (BOOL)allowsAutomaticWindowTabbing { return NO; }
+ (void)setAllowsAutomaticWindowTabbing:(BOOL)flag {}
+ (NSWindowUserTabbingPreference)userTabbingPreference { return NSWindowUserTabbingPreferenceManual; }
- (NSWindowTabbingIdentifier)tabbingIdentifier { return [self className]; }
- (void)setTabbingIdentifier:(NSWindowTabbingIdentifier)identifier {}
- (NSArray<NSWindow *> *)tabbedWindows { return nil; }
- (NSWindowSharingType)sharingType { return _sharingType; }
- (void)setSharingType:(NSWindowSharingType)type { _sharingType = type; }
- (NSWindowOcclusionState)occlusionState { return _w.visible ? NSWindowOcclusionStateVisible : 0; }
- (NSAppearance *)appearance { return _appearance; }
- (void)setAppearance:(NSAppearance *)appearance { [_appearance autorelease]; _appearance = [appearance retain]; }
- (NSAppearance *)effectiveAppearance { return _appearance ?: [NSApp effectiveAppearance]; }
- (NSToolbar *)toolbar { return _toolbar; }
- (void)setToolbar:(NSToolbar *)toolbar { [_toolbar autorelease]; _toolbar = [toolbar retain]; }
- (NSWindowToolbarStyle)toolbarStyle { return NSWindowToolbarStyleAutomatic; }
- (void)setToolbarStyle:(NSWindowToolbarStyle)style {}
- (NSTitlebarSeparatorStyle)titlebarSeparatorStyle { return NSTitlebarSeparatorStyleAutomatic; }
- (void)setTitlebarSeparatorStyle:(NSTitlebarSeparatorStyle)style {}
- (void)addTitlebarAccessoryViewController:(NSTitlebarAccessoryViewController *)c {}
- (NSButton *)standardWindowButton:(NSWindowButton)b { return nil; }
+ (NSButton *)standardWindowButton:(NSWindowButton)b forStyleMask:(NSWindowStyleMask)styleMask { return nil; }
- (NSWindow *)parentWindow { return _parent; }
- (void)setParentWindow:(NSWindow *)parent { _parent = parent; }
- (NSArray<NSWindow *> *)childWindows { return _children ? [[_children copy] autorelease] : nil; }

- (void)addChildWindow:(NSWindow *)child ordered:(NSWindowOrderingMode)place
{
    if (!_children)
        _children = [[NSMutableArray alloc] init];
    [_children addObject:child];
    child->_parent = self;
    if (_w.visible)
        [child orderWindow:place relativeTo:_number];
}

- (void)removeChildWindow:(NSWindow *)child
{
    child->_parent = nil;
    [_children removeObjectIdenticalTo:child];
}

- (NSSize)minSize { return _minSize; }
- (void)setMinSize:(NSSize)size { _minSize = size; }
- (NSSize)maxSize { return _maxSize; }
- (void)setMaxSize:(NSSize)size { _maxSize = size; }
- (NSSize)contentMinSize { return _contentMinSize; }
- (void)setContentMinSize:(NSSize)size
{
    _contentMinSize = size;
    _minSize = [self frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)].size;
}
- (NSSize)contentMaxSize { return _contentMaxSize; }
- (void)setContentMaxSize:(NSSize)size
{
    _contentMaxSize = size;
    _maxSize = [self frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)].size;
}
- (NSSize)resizeIncrements { return _resizeIncrements; }
- (void)setResizeIncrements:(NSSize)size { _resizeIncrements = size; }
- (NSSize)contentResizeIncrements { return _resizeIncrements; }
- (void)setContentResizeIncrements:(NSSize)size { _resizeIncrements = size; }
- (NSSize)aspectRatio { return _aspectRatio; }
- (void)setAspectRatio:(NSSize)ratio { _aspectRatio = ratio; }
- (NSSize)contentAspectRatio { return _aspectRatio; }
- (void)setContentAspectRatio:(NSSize)ratio { _aspectRatio = ratio; }

#pragma mark - Frame

- (NSRect)frame { return _frame; }

- (NSScreen *)screen
{
    return [NSScreen mainScreen];
}

- (NSScreen *)deepestScreen
{
    return [NSScreen mainScreen];
}

- (void)setFrame:(NSRect)frame display:(BOOL)flag
{
    frame.size.width = MAX(frame.size.width, 0);
    frame.size.height = MAX(frame.size.height, 0);
    if (NSEqualRects(frame, _frame))
        return;
    BOOL moved = !NSEqualPoints(frame.origin, _frame.origin);
    BOOL resized = !NSEqualSizes(frame.size, _frame.size);
    _frame = frame;
    if (_server) {
        FWSSetWindowFrame(_server, server_rect(frame));
        if (resized)
            [self _finchMakeContext];
    }
    if (resized) {
        /* the frame view sizes the content view itself; its autoresizing mask is the app's */
        [_frameView setFrameSize:frame.size];
        [_contentView setFrame:[self _contentFrameInFrameView]];
        [self _finchInvalidateRect:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    }
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (moved)
        [nc postNotificationName:NSWindowDidMoveNotification object:self];
    if (resized)
        [nc postNotificationName:NSWindowDidResizeNotification object:self];
    if (flag && resized)
        [self displayIfNeeded];
}

- (void)setFrame:(NSRect)frame display:(BOOL)flag animate:(BOOL)animate
{
    [self setFrame:frame display:flag];
}

- (NSTimeInterval)animationResizeTime:(NSRect)frame { return 0.2; }

- (void)setFrameOrigin:(NSPoint)origin
{
    [self setFrame:NSMakeRect(origin.x, origin.y, _frame.size.width, _frame.size.height) display:YES];
}

- (void)setFrameTopLeftPoint:(NSPoint)point
{
    [self setFrameOrigin:NSMakePoint(point.x, point.y - _frame.size.height)];
}

- (NSPoint)cascadeTopLeftFromPoint:(NSPoint)point
{
    NSRect visible = [[self screen] visibleFrame];
    if (NSEqualPoints(point, NSZeroPoint))
        point = NSMakePoint(NSMinX(_frame), NSMaxY(_frame));
    else
        point = NSMakePoint(point.x + 20, point.y - 20);
    if (point.y - _frame.size.height < NSMinY(visible) || point.x + _frame.size.width > NSMaxX(visible))
        point = NSMakePoint(NSMinX(visible) + 20, NSMaxY(visible) - 20);
    [self setFrameTopLeftPoint:point];
    return point;
}

- (void)setContentSize:(NSSize)size
{
    NSRect frame = [self frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
    /* the top edge stays */
    frame.origin = NSMakePoint(_frame.origin.x, NSMaxY(_frame) - frame.size.height);
    [self setFrame:frame display:YES];
}

- (void)center
{
    NSRect visible = [[self screen] visibleFrame];
    if (NSIsEmptyRect(visible))
        return;
    NSPoint origin = NSMakePoint(floor(NSMidX(visible) - _frame.size.width / 2),
                                 floor(NSMinY(visible) + (visible.size.height - _frame.size.height) * 2 / 3));
    [self setFrameOrigin:origin];
}

- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen
{
    if (!screen)
        return frame;
    NSRect visible = [screen visibleFrame];
    if (NSMaxY(frame) > NSMaxY(visible))
        frame.origin.y = NSMaxY(visible) - frame.size.height;
    return frame;
}

- (BOOL)setFrameUsingName:(NSWindowFrameAutosaveName)name { return [self setFrameUsingName:name force:NO]; }

- (BOOL)setFrameUsingName:(NSWindowFrameAutosaveName)name force:(BOOL)force
{
    NSString *saved = [[NSUserDefaults standardUserDefaults]
        stringForKey:[@"NSWindow Frame " stringByAppendingString:name]];
    if (!saved)
        return NO;
    [self setFrameFromString:saved];
    return YES;
}

- (BOOL)setFrameAutosaveName:(NSWindowFrameAutosaveName)name
{
    [_frameAutosaveName autorelease];
    _frameAutosaveName = [name copy];
    return YES;
}

- (NSWindowFrameAutosaveName)frameAutosaveName { return _frameAutosaveName ?: @""; }

- (void)saveFrameUsingName:(NSWindowFrameAutosaveName)name
{
    [[NSUserDefaults standardUserDefaults] setObject:[self stringWithSavedFrame]
                                              forKey:[@"NSWindow Frame " stringByAppendingString:name]];
}

- (NSWindowPersistableFrameDescriptor)stringWithSavedFrame
{
    NSRect s = [[self screen] frame];
    return [NSString stringWithFormat:@"%g %g %g %g %g %g %g %g ", _frame.origin.x, _frame.origin.y,
                                      _frame.size.width, _frame.size.height, s.origin.x, s.origin.y, s.size.width,
                                      s.size.height];
}

- (void)setFrameFromString:(NSWindowPersistableFrameDescriptor)string
{
    NSArray *parts = [string componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([parts count] < 4)
        return;
    [self setFrame:NSMakeRect([parts[0] doubleValue], [parts[1] doubleValue], [parts[2] doubleValue],
                              [parts[3] doubleValue])
           display:YES];
}

#pragma mark - Ordering

- (BOOL)isVisible { return _w.visible; }
- (BOOL)isOnActiveSpace { return YES; }

- (void)orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)other
{
    if (place == NSWindowOut) {
        if (!_w.visible)
            return;
        _w.visible = NO;
        if (_server)
            FWSOrderWindow(_server, FWS_ORDER_OUT, 0);
        if (_w.key)
            [self resignKeyWindow];
        if (_w.main)
            [self resignMainWindow];
        FinchApplicationWindowOrderedOut(self);
        return;
    }
    if (![self _finchServerWindow]) {
        _w.visible = YES;  /* no window server: keep the state, for tests */
        return;
    }
    BOOL appearing = !_w.visible;
    _w.visible = YES;
    if (appearing)
        [self _finchInvalidateRect:NSMakeRect(0, 0, _frame.size.width, _frame.size.height)];
    [self displayIfNeeded];
    FWSOrderWindow(_server, place == NSWindowBelow ? FWS_ORDER_BELOW : FWS_ORDER_ABOVE, (uint32_t)MAX(other, 0));
    for (NSWindow *child in _children)
        [child orderWindow:NSWindowAbove relativeTo:_number];
}

- (void)orderFront:(id)sender { [self orderWindow:NSWindowAbove relativeTo:0]; }
- (void)orderBack:(id)sender { [self orderWindow:NSWindowBelow relativeTo:0]; }
- (void)orderOut:(id)sender { [self orderWindow:NSWindowOut relativeTo:0]; }
- (void)orderFrontRegardless { [self orderFront:nil]; }

- (void)makeKeyAndOrderFront:(id)sender
{
    [self orderFront:sender];
    [self makeKeyWindow];
    if ([self canBecomeMainWindow])
        [self makeMainWindow];
}

- (BOOL)canBecomeKeyWindow
{
    return (_style & NSWindowStyleMaskTitled) != 0;
}

- (BOOL)canBecomeMainWindow
{
    return _w.visible && (_style & NSWindowStyleMaskTitled) && ![self isKindOfClass:[NSPanel class]];
}

- (BOOL)isKeyWindow { return _w.key; }
- (BOOL)isMainWindow { return _w.main; }

- (void)makeKeyWindow
{
    if (_w.key || ![self canBecomeKeyWindow])
        return;
    NSWindow *old = [NSApp keyWindow];
    if (old && old != self)
        [old resignKeyWindow];
    _w.key = YES;
    FinchApplicationSetKeyWindow(self);
    if (_server)
        FWSMakeKeyWindow(_server);
    [self becomeKeyWindow];
}

- (void)becomeKeyWindow
{
    if (_firstResponder == self && _initialFirstResponder)
        [self makeFirstResponder:_initialFirstResponder];
    [_frameView setNeedsDisplay:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidBecomeKeyNotification object:self];
}

- (void)resignKeyWindow
{
    if (!_w.key)
        return;
    _w.key = NO;
    FinchApplicationSetKeyWindow(nil);
    [_frameView setNeedsDisplay:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResignKeyNotification object:self];
}

- (void)makeMainWindow
{
    if (_w.main || ![self canBecomeMainWindow])
        return;
    NSWindow *old = [NSApp mainWindow];
    if (old && old != self)
        [old resignMainWindow];
    _w.main = YES;
    FinchApplicationSetMainWindow(self);
    [self becomeMainWindow];
}

- (void)becomeMainWindow
{
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidBecomeMainNotification object:self];
}

- (void)resignMainWindow
{
    if (!_w.main)
        return;
    _w.main = NO;
    FinchApplicationSetMainWindow(nil);
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResignMainNotification object:self];
}

#pragma mark - Closing, miniaturizing, zooming

- (void)performClose:(id)sender
{
    if (!(_style & NSWindowStyleMaskClosable)) {
        NSBeep();
        return;
    }
    BOOL should = YES;
    if ([(id)_delegate respondsToSelector:@selector(windowShouldClose:)])
        should = [_delegate windowShouldClose:self];
    else if ([self respondsToSelector:@selector(windowShouldClose:)])
        should = [(id<NSWindowDelegate>)self windowShouldClose:self];
    if (should)
        [self close];
}

- (void)close
{
    if (_w.closing)
        return;
    _w.closing = YES;
    [self retain];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowWillCloseNotification object:self];
    [self orderOut:nil];
    [self _finchDestroyServerWindow];
    _w.closing = NO;
    if (_w.released)
        [self autorelease];  /* balances the reference the creator gave away */
    [self autorelease];
}

- (void)performMiniaturize:(id)sender
{
    [self miniaturize:sender];
}

- (void)miniaturize:(id)sender
{
    if (_w.miniaturized)
        return;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowWillMiniaturizeNotification object:self];
    _w.miniaturized = YES;
    if (_server)
        FWSOrderWindow(_server, FWS_ORDER_OUT, 0);
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidMiniaturizeNotification object:self];
}

- (void)deminiaturize:(id)sender
{
    if (!_w.miniaturized)
        return;
    _w.miniaturized = NO;
    [self makeKeyAndOrderFront:sender];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidDeminiaturizeNotification object:self];
}

- (void)performZoom:(id)sender
{
    [self zoom:sender];
}

- (void)zoom:(id)sender
{
    NSRect visible = [[self screen] visibleFrame];
    if (NSIsEmptyRect(visible))
        return;
    [self setFrame:visible display:YES];
}

- (void)toggleFullScreen:(id)sender
{
    [self zoom:sender];
}

- (void)performWindowDragWithEvent:(NSEvent *)event
{
    if (!_w.movable)
        return;
    /* on the screen: window coordinates shift under the pointer as the window moves */
    NSPoint start = FinchEventScreenLocation(event);
    NSPoint origin = _frame.origin;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowWillMoveNotification object:self];
    NSEvent *e;
    while ((e = [self nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged])) {
        NSPoint p = FinchEventScreenLocation(e);
        [self setFrameOrigin:NSMakePoint(origin.x + p.x - start.x, origin.y + p.y - start.y)];
        if ([e type] == NSEventTypeLeftMouseUp)
            break;
    }
}

#pragma mark - Events

- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask
{
    return [self nextEventMatchingMask:mask untilDate:[NSDate distantFuture] inMode:NSEventTrackingRunLoopMode
                               dequeue:YES];
}

- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask untilDate:(NSDate *)expiration inMode:(NSRunLoopMode)mode
                           dequeue:(BOOL)deqFlag
{
    return [NSApp nextEventMatchingMask:mask untilDate:expiration inMode:mode dequeue:deqFlag];
}

- (void)discardEventsMatchingMask:(NSEventMask)mask beforeEvent:(NSEvent *)lastEvent
{
    [NSApp discardEventsMatchingMask:mask beforeEvent:lastEvent];
}

- (void)postEvent:(NSEvent *)event atStart:(BOOL)flag
{
    [NSApp postEvent:event atStart:flag];
}

- (NSEvent *)currentEvent
{
    return [NSApp currentEvent];
}

- (void)trackEventsMatchingMask:(NSEventMask)mask timeout:(NSTimeInterval)timeout mode:(NSRunLoopMode)mode
                        handler:(void (NS_NOESCAPE ^)(NSEvent *, BOOL *))handler
{
    BOOL stop = NO;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!stop) {
        NSEvent *e = [self nextEventMatchingMask:mask untilDate:until inMode:mode dequeue:YES];
        handler(e, &stop);
        if (!e)
            break;
    }
}

/* The view a mouse event at a point in window coordinates goes to. */
- (NSView *)_finchViewAt:(NSPoint)p
{
    return [_frameView hitTest:p];
}

- (void)_finchMouseEntered:(NSView *)view event:(NSEvent *)event
{
    /* Tracking areas: entered and exited for the views the pointer crosses into or out of. */
    NSView *old = _lastMouseView;
    if (old == view)
        return;
    _lastMouseView = view;
    NSPoint p = [event locationInWindow];
    for (NSView *v = old; v; v = [v superview]) {
        if (view && [view isDescendantOf:v])
            break;
        for (NSTrackingArea *a in [v trackingAreas]) {
            if (([a options] & NSTrackingMouseEnteredAndExited) && [[a owner] respondsToSelector:@selector(mouseExited:)]) {
                NSEvent *e = [NSEvent enterExitEventWithType:NSEventTypeMouseExited location:p modifierFlags:[event modifierFlags]
                                                   timestamp:[event timestamp] windowNumber:_number context:nil
                                                 eventNumber:0 trackingNumber:(NSInteger)a userData:[a userInfo] ? (void *)[a userInfo] : NULL];
                [[a owner] mouseExited:e];
            }
        }
    }
    for (NSView *v = view; v; v = [v superview]) {
        if (old && [old isDescendantOf:v])
            break;
        for (NSTrackingArea *a in [v trackingAreas]) {
            if (([a options] & NSTrackingMouseEnteredAndExited) && [[a owner] respondsToSelector:@selector(mouseEntered:)]) {
                NSEvent *e = [NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:p modifierFlags:[event modifierFlags]
                                                   timestamp:[event timestamp] windowNumber:_number context:nil
                                                 eventNumber:0 trackingNumber:(NSInteger)a userData:[a userInfo] ? (void *)[a userInfo] : NULL];
                [[a owner] mouseEntered:e];
            }
        }
    }
}

- (void)sendEvent:(NSEvent *)event
{
    NSEventType type = [event type];
    switch (type) {
    case NSEventTypeLeftMouseDown:
    case NSEventTypeRightMouseDown:
    case NSEventTypeOtherMouseDown: {
        NSView *view = [self _finchViewAt:[event locationInWindow]];
        BOOL wasKey = _w.key;
        if (!wasKey && type == NSEventTypeLeftMouseDown) {
            [NSApp activateIgnoringOtherApps:YES];
            [self makeKeyAndOrderFront:self];
        }
        if (!view)
            break;
        if (!wasKey && view != _frameView && ![view acceptsFirstMouse:event]) {
            _mouseDownView = nil;
            break;
        }
        if (type == NSEventTypeLeftMouseDown && view != _firstResponder && [view acceptsFirstResponder])
            [self makeFirstResponder:view];
        _mouseDownView = view;
        if (type == NSEventTypeLeftMouseDown)
            [view mouseDown:event];
        else if (type == NSEventTypeRightMouseDown)
            [view rightMouseDown:event];
        else
            [view otherMouseDown:event];
        break;
    }
    case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseUp: {
        NSView *view = _mouseDownView ?: [self _finchViewAt:[event locationInWindow]];
        _mouseDownView = nil;
        if (type == NSEventTypeLeftMouseUp)
            [view mouseUp:event];
        else if (type == NSEventTypeRightMouseUp)
            [view rightMouseUp:event];
        else
            [view otherMouseUp:event];
        break;
    }
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged: {
        NSView *view = _mouseDownView;
        if (type == NSEventTypeLeftMouseDragged)
            [view mouseDragged:event];
        else if (type == NSEventTypeRightMouseDragged)
            [view rightMouseDragged:event];
        else
            [view otherMouseDragged:event];
        break;
    }
    case NSEventTypeMouseMoved: {
        NSView *view = [self _finchViewAt:[event locationInWindow]];
        [self _finchMouseEntered:view event:event];
        if (_w.mouseMoved)
            [_firstResponder mouseMoved:event];
        break;
    }
    case NSEventTypeScrollWheel:
        [[self _finchViewAt:[event locationInWindow]] scrollWheel:event];
        break;
    case NSEventTypeKeyDown:
        if ([event modifierFlags] & NSEventModifierFlagCommand) {
            if ([self performKeyEquivalent:event])
                break;
        }
        if ([self _finchKeyViewNavigation:event])
            break;
        [_firstResponder keyDown:event];
        break;
    case NSEventTypeKeyUp:
        [_firstResponder keyUp:event];
        break;
    case NSEventTypeFlagsChanged:
        [_firstResponder flagsChanged:event];
        break;
    case NSEventTypeMouseEntered:
    case NSEventTypeMouseExited:
        break;
    default:
        break;
    }
}

/* Tab and Shift-Tab move through the key view loop when the first responder doesn't take them. */
- (BOOL)_finchKeyViewNavigation:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] != 1)
        return NO;
    unichar c = [chars characterAtIndex:0];
    if (c != '\t' && c != 0x19)
        return NO;
    if ([_firstResponder isKindOfClass:[NSView class]] && [_firstResponder respondsToSelector:@selector(insertText:)] &&
        ![_firstResponder isKindOfClass:FINCH_CLASS(NSControl)])
        return NO;  /* a text view takes its tabs */
    if (c == 0x19 || ([event modifierFlags] & NSEventModifierFlagShift))
        [self selectPreviousKeyView:self];
    else
        [self selectNextKeyView:self];
    return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    return [_frameView performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event
{
    if ([self _finchKeyViewNavigation:event])
        return;
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] == 1 && [chars characterAtIndex:0] == 0x1b) {
        [self tryToPerform:@selector(cancelOperation:) with:self];
        return;
    }
    [super keyDown:event];
}

- (BOOL)tryToPerform:(SEL)action with:(id)object
{
    if ([super tryToPerform:action with:object])
        return YES;
    if (_delegate && [(id)_delegate respondsToSelector:action]) {
        ((void (*)(id, SEL, id))objc_msgSend)(_delegate, action, object);
        return YES;
    }
    return NO;
}

- (BOOL)acceptsFirstResponder { return YES; }

- (NSUndoManager *)undoManager
{
    if ([(id)_delegate respondsToSelector:@selector(windowWillReturnUndoManager:)])
        return [_delegate windowWillReturnUndoManager:self];
    NSUndoManager *u = objc_getAssociatedObject(self, @selector(undoManager));
    if (!u) {
        u = [[[NSUndoManager alloc] init] autorelease];
        objc_setAssociatedObject(self, @selector(undoManager), u, OBJC_ASSOCIATION_RETAIN);
    }
    return u;
}

- (id)validRequestorForSendType:(NSPasteboardType)sendType returnType:(NSPasteboardType)returnType
{
    return nil;
}

- (NSRect)_finchDirtyRect { return _dirty; }

/* Window-server events for this window. */
void
FinchWindowServerEvent(const FWSEvent *e)
{
    NSWindow *w = FinchWindowForNumber(e->window);
    if (e->type == FWS_EVENT_WINDOW_MOVED && w) {
        NSRect screen = [[NSScreen mainScreen] frame];
        NSRect f = NSMakeRect(e->x, NSMaxY(screen) - e->y - e->delta_y, e->delta_x, e->delta_y);
        w->_frame = f;
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidMoveNotification object:w];
    }
}

@end

@implementation NSPanel

- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing defer:(BOOL)flag
{
    self = [super initWithContentRect:contentRect styleMask:style backing:backing defer:flag];
    if (self) {
        [self setReleasedWhenClosed:NO];
        [self setHidesOnDeactivate:YES];
    }
    return self;
}

- (BOOL)isFloatingPanel { return [self level] == NSFloatingWindowLevel; }
- (void)setFloatingPanel:(BOOL)flag { [self setLevel:flag ? NSFloatingWindowLevel : NSNormalWindowLevel]; }
- (BOOL)becomesKeyOnlyIfNeeded { return NO; }
- (void)setBecomesKeyOnlyIfNeeded:(BOOL)flag {}
- (BOOL)worksWhenModal { return NO; }
- (void)setWorksWhenModal:(BOOL)flag {}
- (BOOL)canBecomeMainWindow { return NO; }

@end
