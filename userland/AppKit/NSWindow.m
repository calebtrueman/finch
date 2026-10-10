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
#import "FinchTheme.h"
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
/* private, as Apple's: a window coming onscreen and going off */
NSNotificationName NSWindowDidOrderOnScreenNotification = @"_NSWindowDidBecomeVisible";
NSNotificationName NSWindowDidOrderOffScreenNotification = @"NSWindowDidOrderOffScreenNotification";
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
bar_height(NSWindowStyleMask style)
{
    if (!(style & NSWindowStyleMaskTitled))
        return 0;
    return (style & NSWindowStyleMaskUtilityWindow) ? 24 : 32;
}

/* The title bar's share of the frame outside the content: none when the content is full size. */
static CGFloat
titlebar_height(NSWindowStyleMask style)
{
    return (style & NSWindowStyleMaskFullSizeContentView) ? 0 : bar_height(style);
}

/* The title bar and, when shown, the toolbar's row under it (NSToolbar.m). */
extern const CGFloat FinchToolbarHeight;
static CGFloat
chrome_height(NSWindow *w)
{
    CGFloat t = titlebar_height([w styleMask]);
    if (t && [[w toolbar] isVisible])
        t += FinchToolbarHeight;
    return t;
}

/* The title bar and toolbar as drawn: over the content's top when the content is full size. */
static CGFloat
visible_chrome_height(NSWindow *w)
{
    CGFloat t = bar_height([w styleMask]);
    if (t && [[w toolbar] isVisible])
        t += FinchToolbarHeight;
    return t;
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

/* Fieldwork's window controls: one cluster of three segments on the left (docs/design/FIELDWORK.md). */
enum { FW_SEGMENT = 22, FW_CLUSTER_HEIGHT = 18, FW_LEFT = 10 };

static NSRect
button_rect(int which, NSRect bounds, CGFloat titlebar)
{
    if (!FinchThemeIsClassic())
        return NSMakeRect(FW_LEFT + which * FW_SEGMENT, NSMaxY(bounds) - titlebar / 2 - FW_CLUSTER_HEIGHT / 2.0, FW_SEGMENT,
                          FW_CLUSTER_HEIGHT);
    CGFloat d = 12, gap = 8, left = 12;
    return NSMakeRect(left + which * (d + gap), NSMaxY(bounds) - titlebar / 2 - d / 2, d, d);
}

static void
set_fill(CGContextRef cg, NSColor *c)
{
    CGColorRef cc = [c CGColor];
    if (cc)
        CGContextSetFillColorWithColor(cg, cc);
}

static void
set_stroke(CGContextRef cg, NSColor *c)
{
    CGColorRef cc = [c CGColor];
    if (cc)
        CGContextSetStrokeColorWithColor(cg, cc);
}

/* The cluster: a machined strip of three segments, close (x), minimise (-) and zoom (a square), in ink. */
static void
draw_fieldwork_controls(CGContextRef cg, NSRect b, CGFloat t, BOOL key, const BOOL enabled[3], int pressed)
{
    NSRect all = NSUnionRect(button_rect(0, b, t), button_rect(2, b, t));
    CGRect r = NSRectToCGRect(NSInsetRect(all, 0.5, 0.5));
    CGFloat radius = FinchThemeMetric(@"controlCornerRadius", 3);
    CGPathRef path = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
    set_fill(cg, [NSColor controlColor]);
    CGContextAddPath(cg, path);
    CGContextFillPath(cg);
    if (pressed >= 0 && enabled[pressed]) {
        CGContextSaveGState(cg);
        CGContextAddPath(cg, path);
        CGContextClip(cg);
        set_fill(cg, [NSColor selectedTextBackgroundColor]);
        CGContextFillRect(cg, NSRectToCGRect(button_rect(pressed, b, t)));
        CGContextRestoreGState(cg);
    }
    set_stroke(cg, FinchThemePaletteColor(@"outline") ?: [NSColor separatorColor]);
    CGContextSetLineWidth(cg, 1);
    CGContextAddPath(cg, path);
    CGContextStrokePath(cg);
    CGPathRelease(path);
    /* the dividers */
    set_fill(cg, [NSColor separatorColor]);
    for (int i = 1; i < 3; i++) {
        NSRect seg = button_rect(i, b, t);
        CGContextFillRect(cg, CGRectMake(NSMinX(seg), NSMinY(seg) + 4, 1, NSHeight(seg) - 8));
    }
    NSColor *ink = key ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    for (int i = 0; i < 3; i++) {
        NSRect seg = button_rect(i, b, t);
        CGFloat cx = floor(NSMidX(seg)) + 0.5, cy = floor(NSMidY(seg)) + 0.5;
        CGContextSaveGState(cg);
        set_stroke(cg, ink);
        CGContextSetAlpha(cg, enabled[i] ? 1 : 0.3);
        CGContextSetLineWidth(cg, 1.25);
        CGContextSetLineCap(cg, kCGLineCapRound);
        if (i == BUTTON_CLOSE) {
            CGContextMoveToPoint(cg, cx - 3.5, cy - 3.5);
            CGContextAddLineToPoint(cg, cx + 3.5, cy + 3.5);
            CGContextMoveToPoint(cg, cx - 3.5, cy + 3.5);
            CGContextAddLineToPoint(cg, cx + 3.5, cy - 3.5);
        } else if (i == BUTTON_MINIATURIZE) {
            CGContextMoveToPoint(cg, cx - 4, cy);
            CGContextAddLineToPoint(cg, cx + 4, cy);
        } else {
            CGContextAddRect(cg, CGRectMake(cx - 3.5, cy - 3.5, 7, 7));
        }
        CGContextStrokePath(cg);
        CGContextRestoreGState(cg);
    }
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
    CGColorRef bg = [[w backgroundColor] CGColor];
    if (bg)
        CGContextSetFillColorWithColor(cg, bg);
    else
        CGContextSetRGBFillColor(cg, 0.925, 0.925, 0.925, 1);
    CGContextFillRect(cg, NSRectToCGRect(dirty));
    if (titlebar_height([w styleMask]))
        [self _finchDrawTitlebar:cg];
}

/*
 * The title bar (and the toolbar's row): a band a little lighter than the
 * background with a hairline under it, the buttons and the title, in the
 * frame view's coordinates. Full-size content windows draw it from
 * FinchTitlebarView, over the content.
 */
- (void)_finchDrawTitlebar:(CGContextRef)cg
{
    NSWindow *w = [self window];
    NSRect b = [self bounds];
    CGFloat t = bar_height([w styleMask]);
    if (t == 0)
        return;
    CGFloat chrome = visible_chrome_height(w);
    NSRect bar = NSMakeRect(0, NSMaxY(b) - chrome, b.size.width, chrome);
    BOOL key = [w isKeyWindow];
    NSWindowStyleMask style = [w styleMask];
    BOOL enabled[3] = {(style & NSWindowStyleMaskClosable) != 0, (style & NSWindowStyleMaskMiniaturizable) != 0,
                       (style & NSWindowStyleMaskResizable) != 0};
    BOOL fieldwork = !FinchThemeIsClassic();
    /* a transparent title bar with no controls enabled (an alert's) shows none */
    BOOL bare = [w titlebarAppearsTransparent] && !enabled[0] && !enabled[1] && !enabled[2];
    if (fieldwork) {
        /* slate, a hairline under it, a faint highlight along the top edge, and the key window's green mark */
        if (![w titlebarAppearsTransparent]) {
            set_fill(cg, FinchThemePaletteColor(@"slate") ?: [NSColor controlBackgroundColor]);
            CGContextFillRect(cg, NSRectToCGRect(bar));
            set_fill(cg, [NSColor separatorColor]);
            CGContextFillRect(cg, CGRectMake(0, NSMinY(bar), b.size.width, 1));
        }
        set_fill(cg, FinchThemePaletteColor(@"edgeHighlight") ?: [NSColor highlightColor]);
        CGContextFillRect(cg, CGRectMake(0, NSMaxY(b) - 1, b.size.width, 1));
        if (key) {
            set_fill(cg, [NSColor controlAccentColor]);
            CGFloat mark = FinchThemeMetric(@"keyWindowMarkWidth", 2);
            CGContextFillRect(cg, CGRectMake(0, NSMaxY(b) - mark, b.size.width, mark));
        }
        if (!bare)
            draw_fieldwork_controls(cg, b, t, key, enabled, _pressed);
    } else {
        if (![w titlebarAppearsTransparent]) {
            CGContextSetRGBFillColor(cg, key ? 0.965 : 0.945, key ? 0.965 : 0.945, key ? 0.965 : 0.945, 1);
            CGContextFillRect(cg, NSRectToCGRect(bar));
            CGContextSetRGBFillColor(cg, 0, 0, 0, 0.1);
            CGContextFillRect(cg, CGRectMake(0, NSMinY(bar), b.size.width, 0.5));
        }
        static const CGFloat colours[3][3] = {{0.93, 0.33, 0.30}, {0.96, 0.73, 0.22}, {0.30, 0.76, 0.33}};
        for (int i = 0; i < 3 && !bare; i++) {
            NSRect r = button_rect(i, b, t);
            if (enabled[i] && key)
                fill_circle(cg, r, colours[i][0], colours[i][1], colours[i][2], _pressed == i ? 0.8 : 1);
            else
                fill_circle(cg, r, 0.82, 0.82, 0.82, 1);
        }
    }
    NSString *title = [w titleVisibility] == NSWindowTitleHidden ? nil : [w title];
    if ([title length]) {
        id font = [(id)FINCH_CLASS(NSFont) respondsToSelector:@selector(titleBarFontOfSize:)]
                      ? [(id)FINCH_CLASS(NSFont) titleBarFontOfSize:0]
                      : nil;
        CGColorRef ink = CGColorCreateSRGB(0, 0, 0, key ? 0.85 : 0.45);
        id color = [(id)FINCH_CLASS(NSColor) respondsToSelector:@selector(colorWithCGColor:)]
                       ? [(id)FINCH_CLASS(NSColor) colorWithCGColor:ink]
                       : nil;
        CGColorRelease(ink);
        if (fieldwork)
            color = key ? [NSColor labelColor] : [NSColor secondaryLabelColor];
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        if (font)
            attrs[@"NSFont"] = font;
        if (color)
            attrs[@"NSColor"] = color;
        if ([title respondsToSelector:@selector(sizeWithAttributes:)]) {
            NSSize size = [title sizeWithAttributes:attrs];
            CGFloat left = NSMaxX(button_rect(2, b, t)) + 12;
            CGFloat x = MAX(left, floor((b.size.width - size.width) / 2));
            [title drawAtPoint:NSMakePoint(x, NSMaxY(b) - t + floor((t - size.height) / 2)) withAttributes:attrs];
        }
    }
}

- (int)_buttonAt:(NSPoint)p
{
    NSWindow *w = [self window];
    CGFloat t = bar_height([w styleMask]);
    if (t == 0)
        return -1;
    for (int i = 0; i < 3; i++)
        if (NSPointInRect(p, NSInsetRect(button_rect(i, [self bounds], t), -2, -2)))
            return i;
    return -1;
}

- (BOOL)_inTitlebar:(NSPoint)p
{
    CGFloat t = visible_chrome_height([self window]);
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

#pragma mark - The title bar over full-size content

/* Above a full-size content view (and under the toolbar's row): the frame view draws it and takes its clicks. */
@interface FinchTitlebarView : NSView
@end

@implementation FinchTitlebarView

- (void)drawRect:(NSRect)dirty
{
    CGContextRef cg = [[NSGraphicsContext currentContext] CGContext];
    NSThemeFrame *frame = (NSThemeFrame *)[self superview];
    if (!cg || !frame)
        return;
    NSPoint o = [self frame].origin;
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg, -o.x, -o.y);
    [frame _finchDrawTitlebar:cg];
    CGContextRestoreGState(cg);
}

- (void)mouseDown:(NSEvent *)event
{
    [[self superview] mouseDown:event];
}

- (BOOL)mouseDownCanMoveWindow { return YES; }

@end

#pragma mark - NSWindow

@implementation NSWindow {
    NSRect _frame;
    NSWindowStyleMask _style;
    NSBackingStoreType _backing;
    NSThemeFrame *_frameView;
    FinchTitlebarView *_titlebarView;  /* full-size content windows only */
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

/* The instance methods count the toolbar's row, as Apple's do. */
- (NSRect)frameRectForContentRect:(NSRect)rect
{
    rect.size.height += chrome_height(self);
    return rect;
}

- (NSRect)contentRectForFrameRect:(NSRect)rect
{
    rect.size.height -= chrome_height(self);
    return rect;
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
    [self _finchUpdateTitlebarView];
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
    /* The view's size, or else the controller's preferred size, or else what the view's
       content needs (an NSHostingView's, for one, sizes itself only by layout). */
    NSRect rect = [view frame];
    if (NSIsEmptyRect(rect))
        rect.size = [controller preferredContentSize];
    if (rect.size.width <= 0 || rect.size.height <= 0)
        rect.size = [view fittingSize];
    rect.origin = NSZeroPoint;
    NSWindow *w = [[self alloc] initWithContentRect:rect
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
    [_titlebarView release];
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
           (w->_w.ignoresMouse ? FWS_WINDOW_IGNORES_MOUSE : 0) | FWS_WINDOW_SHARED |
           ((w->_style & NSWindowStyleMaskTitled) ? FWS_WINDOW_TITLED : 0);
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
    if (!_w.visible || _w.displaying)
        return;
    /* layout first, even with nothing to draw: it can resize the window (and so dirty it) */
    if (NSIsEmptyRect(_dirty)) {
        _w.displaying = YES;
        [_frameView layoutSubtreeIfNeeded];
        _w.displaying = NO;
        if (NSIsEmptyRect(_dirty))
            return;
    }
    if (![self _finchCGContext])
        return;
    _w.displaying = YES;
    /* layout can resize the window, which replaces its context: take the context after it */
    [_frameView layoutSubtreeIfNeeded];
    CGContextRef cg = [self _finchCGContext];
    if (!cg) {
        _w.displaying = NO;
        return;
    }
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
    if ([_toolbar isVisible])
        [_toolbar validateVisibleItems];
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
    r.size.height -= chrome_height(self);
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
        [_frameView addSubview:view positioned:NSWindowBelow relativeTo:nil];  /* under the title bar and toolbar */
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

/* The part of the frame the title bar and toolbar leave clear, also when the content runs under them. */
- (NSRect)contentLayoutRect
{
    NSRect r = NSMakeRect(0, 0, _frame.size.width, _frame.size.height);
    r.size.height -= visible_chrome_height(self);
    return r;
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
    /* Unless becoming first responder handed it on (a text field to its field editor). */
    if (_firstResponder == self)
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
    if (bar_height(_style))
        [_frameView setNeedsDisplayInRect:NSMakeRect(0, _frame.size.height - bar_height(_style),
                                                     _frame.size.width, bar_height(_style))];
    [_titlebarView setNeedsDisplay:YES];
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
- (void)setTitleVisibility:(NSWindowTitleVisibility)v
{
    _w.titleHidden = v == NSWindowTitleHidden;
    [_frameView setNeedsDisplay:YES];
    [_titlebarView setNeedsDisplay:YES];
}
- (BOOL)titlebarAppearsTransparent { return _w.titlebarTransparent; }
- (void)setTitlebarAppearsTransparent:(BOOL)flag
{
    _w.titlebarTransparent = flag;
    [_frameView setNeedsDisplay:YES];
    [_titlebarView setNeedsDisplay:YES];
}
- (NSWindowStyleMask)styleMask { return _style; }

- (void)setStyleMask:(NSWindowStyleMask)style
{
    NSRect content = [self contentRectForFrameRect:_frame];
    _style = style;
    _frame = [self frameRectForContentRect:content];
    [self setFrame:_frame display:YES];
    [self _finchToolbarChangedFrom:chrome_height(self)];  /* the toolbar's row and the title bar overlay */
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
- (void)setToolbar:(NSToolbar *)toolbar
{
    if (toolbar == _toolbar)
        return;
    [_toolbar _finchSetWindow:nil];
    [[_toolbar _finchView] removeFromSuperview];
    CGFloat before = chrome_height(self);
    [_toolbar autorelease];
    _toolbar = [toolbar retain];
    [toolbar _finchSetWindow:self];
    [self _finchToolbarChangedFrom:before];
}

/* Showing or hiding the toolbar grows or shrinks the frame, keeping the content's size and the top edge. */
- (void)_finchToolbarChanged
{
    [self _finchToolbarChangedFrom:-1];
}

- (void)_finchToolbarChangedFrom:(CGFloat)before
{
    NSView *row = [_toolbar _finchView];
    CGFloat t = bar_height(_style);
    BOOL shown = t && [_toolbar isVisible];
    if (before < 0)
        before = titlebar_height(_style) ? t + (shown ? 0 : FinchToolbarHeight) : 0;
    CGFloat after = chrome_height(self);
    if (after != before) {
        NSRect f = _frame;
        f.size.height += after - before;
        f.origin.y -= after - before;
        [self setFrame:f display:NO];
    }
    if (shown) {
        [row setFrame:NSMakeRect(0, _frame.size.height - t - FinchToolbarHeight, _frame.size.width, FinchToolbarHeight)];
        [row setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
        if ([row superview] != _frameView)
            [_frameView addSubview:row];
    } else {
        [row removeFromSuperview];
    }
    [self _finchUpdateTitlebarView];
    [_contentView setFrame:[self _contentFrameInFrameView]];
    [_frameView setNeedsDisplay:YES];
}

/* The overlay title bar of a full-size content window, sized to the title bar and toolbar, under the toolbar's row. */
- (void)_finchUpdateTitlebarView
{
    BOOL want = (_style & NSWindowStyleMaskFullSizeContentView) && bar_height(_style);
    if (!want) {
        [_titlebarView removeFromSuperview];
        [_titlebarView release];
        _titlebarView = nil;
        return;
    }
    if (!_titlebarView)
        _titlebarView = [[FinchTitlebarView alloc] initWithFrame:NSZeroRect];
    CGFloat h = visible_chrome_height(self);
    [_titlebarView setFrame:NSMakeRect(0, _frame.size.height - h, _frame.size.width, h)];
    [_titlebarView setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    NSView *row = [_toolbar isVisible] ? [_toolbar _finchView] : nil;
    if ([row superview] == _frameView)
        [_frameView addSubview:_titlebarView positioned:NSWindowBelow relativeTo:row];
    else
        [_frameView addSubview:_titlebarView positioned:NSWindowAbove relativeTo:nil];
    [_titlebarView setNeedsDisplay:YES];
}

- (IBAction)toggleToolbarShown:(id)sender
{
    [_toolbar setVisible:![_toolbar isVisible]];
}

- (IBAction)runToolbarCustomizationPalette:(id)sender
{
    [_toolbar runCustomizationPalette:sender];
}
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
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidOrderOffScreenNotification object:self];
        return;
    }
    if (![self _finchServerWindow]) {
        _w.visible = YES;  /* no window server: keep the state, for tests */
        return;
    }
    BOOL appearing = !_w.visible;
    if (appearing && ([self styleMask] & NSWindowStyleMaskTitled)) {
        /* as Apple's: a titled window placed onscreen keeps its title bar below the menu bar */
        NSScreen *screen = [self screen] ? [self screen] : [NSScreen mainScreen];
        NSRect constrained = [self constrainFrameRect:_frame toScreen:screen];
        if (!NSEqualRects(constrained, _frame))
            [self setFrame:constrained display:NO];
    }
    _w.visible = YES;
    /* a window is laid out as it appears, which can resize it to fit its content */
    if (appearing)
        [_frameView layoutSubtreeIfNeeded];
    if (appearing)
        [self _finchInvalidateRect:NSMakeRect(0, 0, _frame.size.width, _frame.size.height)];
    [self displayIfNeeded];
    FWSOrderWindow(_server, place == NSWindowBelow ? FWS_ORDER_BELOW : FWS_ORDER_ABOVE, (uint32_t)MAX(other, 0));
    for (NSWindow *child in _children)
        [child orderWindow:NSWindowAbove relativeTo:_number];
    if (appearing)
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidOrderOnScreenNotification object:self];
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

/* Tracking areas, as AppKit's: by geometry, not by what is hit. On each move, every area in the
 * window whose rect (in its view) the pointer has come into or gone out of tells its owner it
 * entered or exited, and one that asks for moves hears them while the pointer is in it. */
static void
track(NSView *view, NSPoint inWindow, NSEvent *event, NSInteger window, BOOL inWindowAtAll)
{
    if ([view isHidden])
        inWindowAtAll = NO;
    NSArray *areas = [view trackingAreas];
    if ([areas count]) {
        NSPoint p = [view convertPoint:inWindow fromView:nil];
        for (NSTrackingArea *a in areas) {
            NSTrackingAreaOptions o = [a options];
            BOOL inside = inWindowAtAll && NSPointInRect(p, [a rect]);
            id owner = [a owner];
            if (inside != [a _finchInside]) {
                [a _finchSetInside:inside];
                SEL selector = inside ? @selector(mouseEntered:) : @selector(mouseExited:);
                if ((o & NSTrackingMouseEnteredAndExited) && [owner respondsToSelector:selector]) {
                    NSEvent *e = [NSEvent enterExitEventWithType:inside ? NSEventTypeMouseEntered : NSEventTypeMouseExited
                                                        location:inWindow modifierFlags:[event modifierFlags]
                                                       timestamp:[event timestamp] windowNumber:window context:nil
                                                     eventNumber:0 trackingNumber:(NSInteger)a
                                                        userData:[a userInfo] ? (void *)[a userInfo] : NULL];
                    [owner performSelector:selector withObject:e];
                }
            } else if (inside && (o & NSTrackingMouseMoved) && [owner respondsToSelector:@selector(mouseMoved:)]) {
                [owner mouseMoved:event];
            }
        }
    }
    for (NSView *sub in [view subviews])
        track(sub, inWindow, event, window, inWindowAtAll);
}

- (void)_finchMouseEntered:(NSView *)view event:(NSEvent *)event
{
    _lastMouseView = view;
    NSPoint p = [event locationInWindow];
    BOOL inside = NSPointInRect(p, NSMakeRect(0, 0, _frame.size.width, _frame.size.height));
    track(_frameView, p, event, _number, inside);
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
        /* Controls that don't edit text (buttons, sliders) don't take the focus on a click (NSControl.m). */
        if (type == NSEventTypeLeftMouseDown && view != _firstResponder && [view acceptsFirstResponder] &&
            (![view respondsToSelector:@selector(_finchBecomesFirstResponderOnClick)] ||
             ((BOOL (*)(id, SEL))objc_msgSend)(view, @selector(_finchBecomesFirstResponderOnClick))))
            [self makeFirstResponder:view];
        _mouseDownView = view;
        if (type == NSEventTypeLeftMouseDown)
            {
            [view _finchDeliverGestureEvent:event selector:@selector(mouseDown:)];
            [view mouseDown:event];
        }
        else if (type == NSEventTypeRightMouseDown)
            {
            [view _finchDeliverGestureEvent:event selector:@selector(rightMouseDown:)];
            [view rightMouseDown:event];
        }
        else
            {
            [view _finchDeliverGestureEvent:event selector:@selector(otherMouseDown:)];
            [view otherMouseDown:event];
        }
        break;
    }
    case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseUp: {
        NSView *view = _mouseDownView ?: [self _finchViewAt:[event locationInWindow]];
        _mouseDownView = nil;
        if (type == NSEventTypeLeftMouseUp)
            {
            [view _finchDeliverGestureEvent:event selector:@selector(mouseUp:)];
            [view mouseUp:event];
        }
        else if (type == NSEventTypeRightMouseUp)
            {
            [view _finchDeliverGestureEvent:event selector:@selector(rightMouseUp:)];
            [view rightMouseUp:event];
        }
        else
            {
            [view _finchDeliverGestureEvent:event selector:@selector(otherMouseUp:)];
            [view otherMouseUp:event];
        }
        break;
    }
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged: {
        NSView *view = _mouseDownView;
        if (type == NSEventTypeLeftMouseDragged)
            {
            [view _finchDeliverGestureEvent:event selector:@selector(mouseDragged:)];
            [view mouseDragged:event];
        }
        else if (type == NSEventTypeRightMouseDragged)
            {
            [view _finchDeliverGestureEvent:event selector:@selector(rightMouseDragged:)];
            [view rightMouseDragged:event];
        }
        else
            {
            [view _finchDeliverGestureEvent:event selector:@selector(otherMouseDragged:)];
            [view otherMouseDragged:event];
        }
        break;
    }
    case NSEventTypeMagnify:
    case NSEventTypeRotate: {
        NSView *view = [self _finchViewAt:event.locationInWindow];
        SEL selector = type == NSEventTypeMagnify ? @selector(magnifyWithEvent:) : @selector(rotateWithEvent:);
        [view _finchDeliverGestureEvent:event selector:selector];
        if (type == NSEventTypeMagnify) [view magnifyWithEvent:event];
        else [view rotateWithEvent:event];
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
    /* Keys nothing took: key equivalents without Command (Return for the default button, Escape for Cancel). */
    if ([self performKeyEquivalent:event])
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

/* The window's identifier (NSUserInterfaceItemIdentification), document and restoration class. */
@implementation NSWindow (FinchIdentification)
static const void *kIdentifier = &kIdentifier, *kRestoration = &kRestoration;
- (NSUserInterfaceItemIdentifier)identifier { return objc_getAssociatedObject(self, kIdentifier); }
- (void)setIdentifier:(NSUserInterfaceItemIdentifier)i
{
    objc_setAssociatedObject(self, kIdentifier, i, OBJC_ASSOCIATION_COPY);
}
- (Class)restorationClass { return objc_getAssociatedObject(self, kRestoration); }
- (void)setRestorationClass:(Class)c { objc_setAssociatedObject(self, kRestoration, c, OBJC_ASSOCIATION_ASSIGN); }
- (id)document { return [[self windowController] document]; }
- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL a = [item action];
    if (a == @selector(performClose:))
        return [self styleMask] & NSWindowStyleMaskClosable ? YES : [self _finchHasCloseTarget];
    if (a == @selector(performMiniaturize:))
        return ([self styleMask] & NSWindowStyleMaskMiniaturizable) != 0;
    if (a == @selector(performZoom:))
        return ([self styleMask] & NSWindowStyleMaskResizable) != 0;
    return [self respondsToSelector:a];
}
- (BOOL)_finchHasCloseTarget { return NO; }
/* Private, as Apple's: a left mouse-down's drags and up go to this view from now on. A view
 * inside it that took the mouse-down itself (an AppKit control in a SwiftUI view) keeps them,
 * as an inner control wins over its container's gestures; the container's recognizers still
 * see them on their way. */
- (void)_latchView:(NSView *)view forEvent:(NSEvent *)event
{
    if ([event type] != NSEventTypeLeftMouseDown || !_mouseDownView)
        return;
    if (_mouseDownView != view && [_mouseDownView isDescendantOf:view])
        return;
    _mouseDownView = view;
}

@end
