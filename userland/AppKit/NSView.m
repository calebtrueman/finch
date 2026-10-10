/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSView: a rectangle of a window that draws and handles events, in a tree.
 *
 * Geometry is a transform from each view's bounds to its superview's
 * coordinates (frame origin, bounds origin and scale, and a flip when the
 * two disagree on isFlipped); converting to or from the window composes them
 * up to the root. Autoresizing, hit testing and alignment to the backing
 * pixels are as measured on macOS 26.4. Drawing is the window's: it walks the
 * tree, clipping each view to its bounds and the area being redrawn, and
 * calls -drawRect: with an NSGraphicsContext whose CTM is the view's.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"
#import <objc/runtime.h>

NSNotificationName NSViewFrameDidChangeNotification = @"NSViewFrameDidChangeNotification";
NSNotificationName NSViewFocusDidChangeNotification = @"NSViewFocusDidChangeNotification";
NSNotificationName NSViewBoundsDidChangeNotification = @"NSViewBoundsDidChangeNotification";
NSNotificationName NSViewGlobalFrameDidChangeNotification = @"NSViewGlobalFrameDidChangeNotification";
NSNotificationName NSViewDidUpdateTrackingAreasNotification = @"NSViewDidUpdateTrackingAreasNotification";

void FinchViewInstallLayerHook(void);
/* The view a hosted layer belongs to (an associated object on the layer, not retained). */
static char layer_owner_key;

@implementation NSView {
    NSRect _frame, _bounds;
    NSView *_superview;  /* not retained */
    NSMutableArray<NSView *> *_subviews;
    NSWindow *_window;   /* not retained */
    NSAutoresizingMaskOptions _autoresizingMask;
    NSInteger _tag;
    NSRect _dirty;       /* in bounds coordinates; empty when clean */
    CGFloat _frameRotation, _boundsRotation;
    NSString *_toolTip;
    NSView *_nextKeyView, *_previousKeyView;  /* not retained */
    NSMutableArray *_trackingAreas;
    NSString *_identifier;
    NSRect _arExact, _arAligned;  /* the last autoresized frame before and after pixel alignment */
    NSAppearance *_appearance;
    CALayer *_layer;
    id _finchLayout;  /* Auto Layout's state (NSViewLayout.m) */
    struct {
        unsigned hidden : 1;
        unsigned autoresizesSubviews : 1;
        unsigned postsFrame : 1;
        unsigned postsBounds : 1;
        unsigned boundsScaled : 1;
        unsigned wantsLayer : 1;
        unsigned translatesMask : 1;
        unsigned needsLayout : 1;
        unsigned needsUpdateConstraints : 1;
        unsigned drawing : 1;
        unsigned flipped : 1;         /* -setFlipped: (private, as Apple's): what -isFlipped returns */
        unsigned noClipping : 1;      /* clipsToBounds NO */
        unsigned ignoreHitTest : 1;   /* private, as Apple's: hit testing passes through the view itself */
        unsigned alphaSet : 1;
        unsigned layerBacked : 1;     /* the layer was made for the view, or given after it wanted one */
    } _f;
    CGFloat _alpha;
    NSView *_mask;
    NSViewLayerContentsPlacement _layerContentsPlacement;
}

#pragma mark - Creating

- (instancetype)init
{
    return [self initWithFrame:NSZeroRect];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super init];
    if (self) {
        _frame = frame;
        _bounds = NSMakeRect(0, 0, frame.size.width, frame.size.height);
        _tag = -1;
        _f.autoresizesSubviews = YES;
        _f.postsFrame = YES;
        _f.postsBounds = YES;
        _f.translatesMask = YES;
        _f.needsLayout = YES;
        _f.needsUpdateConstraints = YES;
    }
    return self;
}

- (void)dealloc
{
    FinchLayoutViewDealloc(self);
    [_finchLayout release];
    for (NSView *v in _subviews) {
        [v _finchSetSuperview:nil];
        [v setNextResponder:nil];
    }
    [_subviews release];
    [_toolTip release];
    [_trackingAreas release];
    [_identifier release];
    [_appearance release];
    [_mask release];
    [self setLayer:nil];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>", [self class], self];
}

#pragma mark - The tree

- (NSView *)superview { return _superview; }
- (NSWindow *)window { return _window; }
- (NSArray<NSView *> *)subviews { return _subviews ? [[_subviews copy] autorelease] : @[]; }

- (void)_finchSetSuperview:(NSView *)superview
{
    _superview = superview;
}

- (id)_finchLayoutState { return _finchLayout; }
- (void)_finchSetLayoutState:(id)state { [_finchLayout autorelease]; _finchLayout = [state retain]; }

/* Tell a subtree it is moving to another window (or none). */
static void
will_move_to_window(NSView *view, NSWindow *window)
{
    [view viewWillMoveToWindow:window];
    for (NSView *v in view->_subviews)
        will_move_to_window(v, window);
}

static void
did_move_to_window(NSView *view, NSWindow *window)
{
    view->_window = window;
    for (NSView *v in view->_subviews)
        did_move_to_window(v, window);
    [view viewDidMoveToWindow];
}

- (void)_finchSetWindow:(NSWindow *)window
{
    if (_window == window)
        return;
    will_move_to_window(self, window);
    did_move_to_window(self, window);
    if (window)
        [self setNeedsDisplay:YES];
}

- (void)addSubview:(NSView *)view
{
    [self addSubview:view positioned:NSWindowAbove relativeTo:nil];
}

- (void)addSubview:(NSView *)view positioned:(NSWindowOrderingMode)place relativeTo:(NSView *)other
{
    if (!view)
        return;
    [view retain];
    /* As Apple's: the view hears it will move, its old superview lets it go, this one adds it, then it hears it moved. */
    [view viewWillMoveToSuperview:self];
    if (view->_window != _window)
        will_move_to_window(view, _window);
    NSView *old = view->_superview;
    if (old) {
        [old willRemoveSubview:view];
        [old->_subviews removeObjectIdenticalTo:view];
    }
    if (!_subviews)
        _subviews = [[NSMutableArray alloc] init];
    NSUInteger i = other ? [_subviews indexOfObjectIdenticalTo:other] : NSNotFound;
    if (i == NSNotFound)
        i = place == NSWindowBelow ? 0 : [_subviews count];
    else if (place != NSWindowBelow)
        i++;
    [_subviews insertObject:view atIndex:i];
    view->_superview = self;
    /* a view controller goes between its view and the superview, as on macOS */
    NSViewController *vc = FinchViewControllerOf(view);
    if (vc) {
        [vc setNextResponder:self];
        [view setNextResponder:vc];
    } else {
        [view setNextResponder:self];
    }
    [self didAddSubview:view];
    if (view->_window != _window)
        did_move_to_window(view, _window);
    FinchLayoutViewDidMoveToSuperview(view);
    [view viewDidMoveToSuperview];
    [view setNeedsDisplay:YES];
    [view release];
}

- (void)removeFromSuperview
{
    if (_superview)
        [_superview setNeedsDisplayInRect:_frame];
    [self removeFromSuperviewWithoutNeedingDisplay];
}

- (void)removeFromSuperviewWithoutNeedingDisplay
{
    NSView *superview = _superview;
    if (!superview)
        return;
    if ([_window firstResponder] == self || ([[_window firstResponder] isKindOfClass:[NSView class]] &&
                                             [(NSView *)[_window firstResponder] isDescendantOf:self]))
        [_window _finchResetFirstResponder];
    [self retain];
    FinchLayoutViewWillLeaveSuperview(self, superview);
    [self viewWillMoveToSuperview:nil];
    if (_window)
        will_move_to_window(self, nil);
    [superview willRemoveSubview:self];
    [superview->_subviews removeObjectIdenticalTo:self];
    _superview = nil;
    [self setNextResponder:nil];
    if (_window)
        did_move_to_window(self, nil);
    [self viewDidMoveToSuperview];
    [self autorelease];
}

- (void)replaceSubview:(NSView *)oldView with:(NSView *)newView
{
    if ([_subviews indexOfObjectIdenticalTo:oldView] == NSNotFound)
        return;
    [[oldView retain] autorelease];
    [self addSubview:newView positioned:NSWindowAbove relativeTo:oldView];
    [oldView removeFromSuperview];
}

- (void)setSubviews:(NSArray<NSView *> *)subviews
{
    for (NSView *v in [self subviews])
        if ([subviews indexOfObjectIdenticalTo:v] == NSNotFound)
            [v removeFromSuperview];
    /* Views already here keep their place in the new order without hearing about it; new ones are added. */
    NSMutableArray *kept = [NSMutableArray array];
    for (NSView *v in subviews)
        if (v->_superview == self)
            [kept addObject:v];
    [_subviews setArray:kept];
    for (NSUInteger i = 0; i < [subviews count]; i++) {
        NSView *v = subviews[i];
        if (v->_superview != self)
            [self addSubview:v positioned:NSWindowAbove relativeTo:i ? subviews[i - 1] : nil];
    }
}

- (void)sortSubviewsUsingFunction:(NSComparisonResult (*NS_NOESCAPE)(__kindof NSView *, __kindof NSView *, void *))compare
                          context:(void *)context
{
    [_subviews sortUsingComparator:^NSComparisonResult(id a, id b) {
        return compare(a, b, context);
    }];
    [self setNeedsDisplay:YES];
}

- (BOOL)isDescendantOf:(NSView *)view
{
    for (NSView *v = self; v; v = v->_superview)
        if (v == view)
            return YES;
    return NO;
}

- (NSView *)ancestorSharedWithView:(NSView *)view
{
    for (NSView *v = self; v; v = v->_superview)
        if ([view isDescendantOf:v])
            return v;
    return nil;
}

- (NSView *)opaqueAncestor
{
    for (NSView *v = self; v; v = v->_superview)
        if ([v isOpaque])
            return v;
    return nil;
}

- (__kindof NSView *)viewWithTag:(NSInteger)tag
{
    if ([self tag] == tag)
        return self;
    for (NSView *v in _subviews) {
        NSView *found = [v viewWithTag:tag];
        if (found)
            return found;
    }
    return nil;
}

- (NSScrollView *)enclosingScrollView
{
    Class scroll = NSClassFromString(@"NSScrollView");
    for (NSView *v = _superview; v; v = v->_superview)
        if (scroll && [v isKindOfClass:scroll])
            return (NSScrollView *)v;
    return nil;
}

- (void)viewWillMoveToSuperview:(NSView *)newSuperview {}
- (void)viewDidMoveToSuperview {}
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {}
- (void)viewDidMoveToWindow {}
- (void)didAddSubview:(NSView *)subview {}
- (void)willRemoveSubview:(NSView *)subview {}
- (void)viewDidChangeBackingProperties {}
- (void)viewDidChangeEffectiveAppearance {}
- (void)viewWillStartLiveResize {}
- (void)viewDidEndLiveResize {}
- (BOOL)inLiveResize { return NO; }
- (BOOL)preservesContentDuringLiveResize { return NO; }

#pragma mark - Properties

- (NSInteger)tag { return _tag; }
- (void)setTag:(NSInteger)tag { _tag = tag; }
- (BOOL)isFlipped { return _f.flipped; }
- (void)setFlipped:(BOOL)flag { _f.flipped = flag; }
- (BOOL)ignoreHitTest { return _f.ignoreHitTest; }
- (void)setIgnoreHitTest:(BOOL)flag { _f.ignoreHitTest = flag; }
/* A mask view: what's drawn under its transparent parts isn't shown (draw_view). */
- (NSView *)maskView { return _mask; }
- (void)setMaskView:(NSView *)v
{
    [_mask autorelease];
    _mask = [v retain];
}
- (NSView *)mask { return _mask; }
- (void)setMask:(NSView *)v { [self setMaskView:v]; }
- (NSViewLayerContentsPlacement)layerContentsPlacement { return _layerContentsPlacement; }
- (void)setLayerContentsPlacement:(NSViewLayerContentsPlacement)p { _layerContentsPlacement = p; }
- (BOOL)isOpaque { return NO; }
- (BOOL)isHidden { return _f.hidden; }
- (NSAutoresizingMaskOptions)autoresizingMask { return _autoresizingMask; }
- (void)setAutoresizingMask:(NSAutoresizingMaskOptions)mask { _autoresizingMask = mask; }
- (BOOL)autoresizesSubviews { return _f.autoresizesSubviews; }
- (void)setAutoresizesSubviews:(BOOL)flag { _f.autoresizesSubviews = flag; }
- (BOOL)postsFrameChangedNotifications { return _f.postsFrame; }
- (void)setPostsFrameChangedNotifications:(BOOL)flag { _f.postsFrame = flag; }
- (BOOL)postsBoundsChangedNotifications { return _f.postsBounds; }
- (void)setPostsBoundsChangedNotifications:(BOOL)flag { _f.postsBounds = flag; }
- (NSString *)toolTip { return _toolTip; }
- (void)setToolTip:(NSString *)toolTip { [_toolTip autorelease]; _toolTip = [toolTip copy]; }
- (NSUserInterfaceItemIdentifier)identifier { return _identifier; }
- (void)setIdentifier:(NSUserInterfaceItemIdentifier)identifier { [_identifier autorelease]; _identifier = [identifier copy]; }
/*
 * Layers. A view that wants a layer gets a backing layer (-makeBackingLayer) whose delegate
 * it is; a view given a layer hosts that one. Finch has no render server: when the view
 * tree draws, a view's layer is rendered (its contents, own drawing and sublayers) in the
 * view's bounds after the view draws itself and before its subviews, and layer changes
 * mark the view that shows them for display (FinchCALayerDidChange).
 */
- (BOOL)wantsLayer { return _f.wantsLayer; }
- (void)setWantsLayer:(BOOL)flag
{
    _f.wantsLayer = flag;
    if (flag && !_layer) {
        CALayer *layer = [self makeBackingLayer];
        [layer setDelegate:(id)self];
        [self setLayer:layer];
    }
    _f.layerBacked = flag && _layer;
    [self setNeedsDisplay:YES];
}
- (CALayer *)layer { return _layer; }
- (void)setLayer:(CALayer *)layer
{
    if (layer == _layer)
        return;
    FinchViewInstallLayerHook();
    if ([_layer delegate] == (id)self)
        [_layer setDelegate:nil];
    if (_layer && objc_getAssociatedObject(_layer, &layer_owner_key) == self)
        objc_setAssociatedObject(_layer, &layer_owner_key, nil, OBJC_ASSOCIATION_ASSIGN);
    [_layer release];
    _layer = [layer retain];
    /* a layer given to a view that already wants one backs it (it redraws with the view);
       given to one that doesn't, the view hosts it */
    _f.layerBacked = layer && _f.wantsLayer;
    if (layer) {
        _f.wantsLayer = YES;
        objc_setAssociatedObject(layer, &layer_owner_key, self, OBJC_ASSOCIATION_ASSIGN);
    }
    [self setNeedsDisplay:YES];
}
- (BOOL)wantsUpdateLayer { return NO; }
- (CALayer *)makeBackingLayer { return [FINCH_CLASS(CALayer) layer]; }
- (NSViewLayerContentsRedrawPolicy)layerContentsRedrawPolicy { return NSViewLayerContentsRedrawDuringViewResize; }
- (void)setLayerContentsRedrawPolicy:(NSViewLayerContentsRedrawPolicy)policy {}
- (BOOL)canDrawConcurrently { return NO; }
- (void)setCanDrawConcurrently:(BOOL)flag {}
- (BOOL)canDrawSubviewsIntoLayer { return NO; }
- (void)setCanDrawSubviewsIntoLayer:(BOOL)flag {}
- (CGFloat)alphaValue { return _f.alphaSet ? _alpha : 1; }
- (void)setAlphaValue:(CGFloat)alpha
{
    _alpha = alpha;
    _f.alphaSet = YES;
    [self setNeedsDisplay:YES];
}
- (NSUserInterfaceLayoutDirection)userInterfaceLayoutDirection { return NSUserInterfaceLayoutDirectionLeftToRight; }
- (void)setUserInterfaceLayoutDirection:(NSUserInterfaceLayoutDirection)direction {}
/* Auto Layout is NSViewLayout.m's; the flags live here. */
- (BOOL)translatesAutoresizingMaskIntoConstraints { return _f.translatesMask; }
- (void)setTranslatesAutoresizingMaskIntoConstraints:(BOOL)flag
{
    if (_f.translatesMask == (unsigned)flag)
        return;
    _f.translatesMask = flag;
    FinchLayoutViewFrameDidChange(self);
}
- (BOOL)needsLayout { return _f.needsLayout; }
/* a view needing layout gets an update pass, as one needing display does */
- (void)setNeedsLayout:(BOOL)flag
{
    _f.needsLayout = flag;
    if (flag && _window)
        FinchApplicationNeedsDisplay();
}
- (BOOL)needsUpdateConstraints { return _f.needsUpdateConstraints; }
- (void)setNeedsUpdateConstraints:(BOOL)flag { _f.needsUpdateConstraints = flag; }
- (NSAppearance *)appearance { return _appearance; }
- (void)setAppearance:(NSAppearance *)appearance { [_appearance autorelease]; _appearance = [appearance retain]; }
- (NSAppearance *)effectiveAppearance
{
    for (NSView *v = self; v; v = v->_superview)
        if (v->_appearance)
            return v->_appearance;
    if (_window)
        return [_window effectiveAppearance];
    return [NSApp effectiveAppearance];
}

- (void)setHidden:(BOOL)hidden
{
    if (_f.hidden == (unsigned)hidden)
        return;
    _f.hidden = hidden;
    FinchLayoutViewFrameDidChange(self);  /* stack views drop hidden views */
    if (hidden) {
        NSResponder *first = [_window firstResponder];
        if ([first isKindOfClass:[NSView class]] && [(NSView *)first isDescendantOf:self])
            [_window makeFirstResponder:nil];
        [self viewDidHide];
    } else {
        [self viewDidUnhide];
    }
    if (_superview)
        [_superview setNeedsDisplayInRect:_frame];
}

- (BOOL)isHiddenOrHasHiddenAncestor
{
    for (NSView *v = self; v; v = v->_superview)
        if (v->_f.hidden)
            return YES;
    return NO;
}

- (void)viewDidHide {}
- (void)viewDidUnhide {}

#pragma mark - Frame and bounds

- (NSRect)frame { return _frame; }
- (NSRect)bounds { return _bounds; }
- (CGFloat)frameRotation { return _frameRotation; }
- (void)setFrameRotation:(CGFloat)angle { _frameRotation = angle; }
- (CGFloat)frameCenterRotation { return _frameRotation; }
- (void)setFrameCenterRotation:(CGFloat)angle { _frameRotation = angle; }
- (CGFloat)boundsRotation { return _boundsRotation; }
- (void)setBoundsRotation:(CGFloat)angle { _boundsRotation = angle; }
- (void)rotateByAngle:(CGFloat)angle { _boundsRotation += angle; }

- (void)setFrame:(NSRect)frame
{
    if (NSEqualRects(frame, _frame))
        return;
    BOOL posts = _f.postsFrame;
    _f.postsFrame = NO;
    [self setFrameOrigin:frame.origin];
    [self setFrameSize:frame.size];
    _f.postsFrame = posts;
    if (posts)
        [[NSNotificationCenter defaultCenter] postNotificationName:NSViewFrameDidChangeNotification object:self];
}

- (void)setFrameOrigin:(NSPoint)origin
{
    if (NSEqualPoints(origin, _frame.origin))
        return;
    if (_superview)
        [_superview setNeedsDisplayInRect:_frame];
    _frame.origin = origin;
    if (_superview)
        [_superview setNeedsDisplayInRect:_frame];
    FinchLayoutViewFrameDidChange(self);
    FinchViewGeometryInWindowDidChange(self);
    if (_f.postsFrame)
        [[NSNotificationCenter defaultCenter] postNotificationName:NSViewFrameDidChangeNotification object:self];
}

- (void)setFrameSize:(NSSize)size
{
    if (NSEqualSizes(size, _frame.size))
        return;
    NSSize old = _frame.size;
    if (_superview)
        [_superview setNeedsDisplayInRect:_frame];
    if (_f.boundsScaled && old.width != 0 && old.height != 0) {
        _bounds.size.width = size.width * (_bounds.size.width / old.width);
        _bounds.size.height = size.height * (_bounds.size.height / old.height);
    } else {
        _bounds.size = size;
    }
    _frame.size = size;
    if (_f.autoresizesSubviews)
        [self resizeSubviewsWithOldSize:old];
    FinchLayoutViewFrameDidChange(self);
    FinchViewGeometryInWindowDidChange(self);
    [self setNeedsDisplay:YES];
    if (_f.postsFrame)
        [[NSNotificationCenter defaultCenter] postNotificationName:NSViewFrameDidChangeNotification object:self];
}

- (void)setBounds:(NSRect)bounds
{
    [self setBoundsOrigin:bounds.origin];
    [self setBoundsSize:bounds.size];
}

- (void)setBoundsOrigin:(NSPoint)origin
{
    if (NSEqualPoints(origin, _bounds.origin))
        return;
    _bounds.origin = origin;
    [self setNeedsDisplay:YES];
    if (_f.postsBounds)
        [[NSNotificationCenter defaultCenter] postNotificationName:NSViewBoundsDidChangeNotification object:self];
}

- (void)setBoundsSize:(NSSize)size
{
    if (NSEqualSizes(size, _bounds.size))
        return;
    _bounds.size = size;
    _f.boundsScaled = !NSEqualSizes(size, _frame.size);
    [self setNeedsDisplay:YES];
    if (_f.postsBounds)
        [[NSNotificationCenter defaultCenter] postNotificationName:NSViewBoundsDidChangeNotification object:self];
}

- (void)translateOriginToPoint:(NSPoint)point
{
    [self setBoundsOrigin:NSMakePoint(_bounds.origin.x - point.x, _bounds.origin.y - point.y)];
}

- (void)scaleUnitSquareToSize:(NSSize)size
{
    if (size.width == 0 || size.height == 0)
        return;
    [self setBoundsSize:NSMakeSize(_bounds.size.width / size.width, _bounds.size.height / size.height)];
}

#pragma mark - Autoresizing

/* The backing scale views align to: the window's, else the main screen's. */
CGFloat
FinchViewBackingScale(NSView *view)
{
    NSWindow *w = view ? view->_window : nil;
    if (w)
        return [w backingScaleFactor];
    return FinchDefaultBackingScale();
}

/*
 * One axis: the flexible parts (margin before, size, margin after) share the
 * change. One flexible part takes it all (a size stops at zero); several
 * share it in proportion to their sizes, each stopping at zero.
 */
static void
resize_axis(CGFloat *origin, CGFloat *length, CGFloat oldSuper, CGFloat newSuper, BOOL flexMin, BOOL flexSize,
            BOOL flexMax)
{
    CGFloat delta = newSuper - oldSuper;
    int count = flexMin + flexSize + flexMax;
    if (count == 0 || delta == 0)
        return;
    CGFloat before = *origin, size = *length, after = oldSuper - (*origin + *length);
    if (count == 1) {
        if (flexMin)
            *origin += delta;
        else if (flexSize)
            *length = MAX(0, size + delta);
        return;
    }
    CGFloat total = (flexMin ? before : 0) + (flexSize ? size : 0) + (flexMax ? after : 0);
    CGFloat dMin, dSize;
    if (total == 0) {
        dMin = flexMin ? delta / count : 0;
        dSize = flexSize ? delta / count : 0;
    } else {
        dMin = flexMin ? delta * before / total : 0;
        dSize = flexSize ? delta * size / total : 0;
    }
    CGFloat newOrigin = before + dMin, newSize = size + dSize;
    if (flexMin && newOrigin < 0)
        newOrigin = 0;
    if (newSize < 0)
        newSize = 0;
    *origin = newOrigin;
    *length = newSize;
}

/* Both edges down to the backing pixel grid. */
static void
floor_to_pixels(CGFloat *origin, CGFloat *length, CGFloat scale)
{
    CGFloat lo = floor(*origin * scale + 1e-9) / scale;
    CGFloat hi = floor((*origin + *length) * scale + 1e-9) / scale;
    *origin = lo;
    *length = MAX(0, hi - lo);
}

- (void)resizeWithOldSuperviewSize:(NSSize)oldSize
{
    NSAutoresizingMaskOptions m = _autoresizingMask;
    if (!m || !_superview)
        return;
    NSSize newSize = _superview->_bounds.size;
    newSize.width = MAX(0, newSize.width);
    newSize.height = MAX(0, newSize.height);
    oldSize.width = MAX(0, oldSize.width);
    oldSize.height = MAX(0, oldSize.height);
    /* Apple's keeps the unaligned result, and starts from it while the frame is still the aligned one. */
    NSRect r = NSEqualRects(_frame, _arAligned) && !NSIsEmptyRect(_arAligned) ? _arExact : _frame;
    BOOL changedX = (m & (NSViewMinXMargin | NSViewWidthSizable | NSViewMaxXMargin)) && newSize.width != oldSize.width;
    BOOL changedY = (m & (NSViewMinYMargin | NSViewHeightSizable | NSViewMaxYMargin)) && newSize.height != oldSize.height;
    if (!changedX && !changedY)
        return;
    CGFloat scale = FinchViewBackingScale(self);
    if (changedX)
        resize_axis(&r.origin.x, &r.size.width, oldSize.width, newSize.width, (m & NSViewMinXMargin) != 0,
                    (m & NSViewWidthSizable) != 0, (m & NSViewMaxXMargin) != 0);
    if (changedY)
        resize_axis(&r.origin.y, &r.size.height, oldSize.height, newSize.height, (m & NSViewMinYMargin) != 0,
                    (m & NSViewHeightSizable) != 0, (m & NSViewMaxYMargin) != 0);
    NSRect aligned = r;
    if (changedX)
        floor_to_pixels(&aligned.origin.x, &aligned.size.width, scale);
    if (changedY)
        floor_to_pixels(&aligned.origin.y, &aligned.size.height, scale);
    [self setFrame:aligned];
    _arExact = r;
    _arAligned = _frame;
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    for (NSView *v in [[_subviews copy] autorelease])
        [v resizeWithOldSuperviewSize:oldSize];
}

#pragma mark - Coordinates

/* From this view's bounds to its superview's coordinates (or the window's, at the root). */
static CGAffineTransform
to_superview(NSView *v)
{
    CGFloat sx = v->_bounds.size.width != 0 ? v->_frame.size.width / v->_bounds.size.width : 1;
    CGFloat sy = v->_bounds.size.height != 0 ? v->_frame.size.height / v->_bounds.size.height : 1;
    BOOL superFlipped = v->_superview ? [v->_superview isFlipped] : NO;
    if ([v isFlipped] == superFlipped)
        return CGAffineTransformMake(sx, 0, 0, sy, v->_frame.origin.x - v->_bounds.origin.x * sx,
                                     v->_frame.origin.y - v->_bounds.origin.y * sy);
    return CGAffineTransformMake(sx, 0, 0, -sy, v->_frame.origin.x - v->_bounds.origin.x * sx,
                                 v->_frame.origin.y + v->_frame.size.height + v->_bounds.origin.y * sy);
}

/* From this view's bounds to window coordinates (the root's superview space). */
CGAffineTransform
FinchViewToBase(NSView *view)
{
    CGAffineTransform t = CGAffineTransformIdentity;
    for (NSView *v = view; v; v = v->_superview)
        t = CGAffineTransformConcat(t, to_superview(v));
    return t;
}

static CGAffineTransform
between(NSView *from, NSView *to)
{
    CGAffineTransform t = from ? FinchViewToBase(from) : CGAffineTransformIdentity;
    if (to)
        t = CGAffineTransformConcat(t, CGAffineTransformInvert(FinchViewToBase(to)));
    return t;
}

- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view
{
    return NSPointFromCGPoint(CGPointApplyAffineTransform(NSPointToCGPoint(point), between(view, self)));
}

- (NSPoint)convertPoint:(NSPoint)point toView:(NSView *)view
{
    return NSPointFromCGPoint(CGPointApplyAffineTransform(NSPointToCGPoint(point), between(self, view)));
}

static NSSize
convert_size(NSSize size, CGAffineTransform t)
{
    CGSize s = CGSizeApplyAffineTransform(NSSizeToCGSize(size), t);
    return NSMakeSize(fabs(s.width), fabs(s.height));
}

- (NSSize)convertSize:(NSSize)size fromView:(NSView *)view
{
    return convert_size(size, between(view, self));
}

- (NSSize)convertSize:(NSSize)size toView:(NSView *)view
{
    return convert_size(size, between(self, view));
}

- (NSRect)convertRect:(NSRect)rect fromView:(NSView *)view
{
    return NSRectFromCGRect(CGRectApplyAffineTransform(NSRectToCGRect(rect), between(view, self)));
}

- (NSRect)convertRect:(NSRect)rect toView:(NSView *)view
{
    return NSRectFromCGRect(CGRectApplyAffineTransform(NSRectToCGRect(rect), between(self, view)));
}

/* Backing coordinates: window coordinates times the backing scale. */
- (NSPoint)convertPointToBacking:(NSPoint)p
{
    CGFloat s = FinchViewBackingScale(self);
    p = _window ? [self convertPoint:p toView:nil] : p;
    return NSMakePoint(p.x * s, p.y * s);
}

- (NSPoint)convertPointFromBacking:(NSPoint)p
{
    CGFloat s = FinchViewBackingScale(self);
    p = NSMakePoint(p.x / s, p.y / s);
    return _window ? [self convertPoint:p fromView:nil] : p;
}

- (NSSize)convertSizeToBacking:(NSSize)size
{
    CGFloat s = FinchViewBackingScale(self);
    size = _window ? [self convertSize:size toView:nil] : size;
    return NSMakeSize(size.width * s, size.height * s);
}

- (NSSize)convertSizeFromBacking:(NSSize)size
{
    CGFloat s = FinchViewBackingScale(self);
    size = NSMakeSize(size.width / s, size.height / s);
    return _window ? [self convertSize:size fromView:nil] : size;
}

- (NSRect)convertRectToBacking:(NSRect)r
{
    CGFloat s = FinchViewBackingScale(self);
    r = _window ? [self convertRect:r toView:nil] : r;
    return NSMakeRect(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s);
}

- (NSRect)convertRectFromBacking:(NSRect)r
{
    CGFloat s = FinchViewBackingScale(self);
    r = NSMakeRect(r.origin.x / s, r.origin.y / s, r.size.width / s, r.size.height / s);
    return _window ? [self convertRect:r fromView:nil] : r;
}

- (NSPoint)convertPointToLayer:(NSPoint)p { return p; }
- (NSPoint)convertPointFromLayer:(NSPoint)p { return p; }
- (NSSize)convertSizeToLayer:(NSSize)s { return s; }
- (NSSize)convertSizeFromLayer:(NSSize)s { return s; }
- (NSRect)convertRectToLayer:(NSRect)r { return r; }
- (NSRect)convertRectFromLayer:(NSRect)r { return r; }
- (NSPoint)convertPointToBase:(NSPoint)p { return [self convertPointToBacking:p]; }
- (NSPoint)convertPointFromBase:(NSPoint)p { return [self convertPointFromBacking:p]; }
- (NSSize)convertSizeToBase:(NSSize)s { return [self convertSizeToBacking:s]; }
- (NSSize)convertSizeFromBase:(NSSize)s { return [self convertSizeFromBacking:s]; }
- (NSRect)convertRectToBase:(NSRect)r { return [self convertRectToBacking:r]; }
- (NSRect)convertRectFromBase:(NSRect)r { return [self convertRectFromBacking:r]; }

- (NSRect)backingAlignedRect:(NSRect)rect options:(NSAlignmentOptions)options
{
    NSRect r = [self convertRectToBacking:rect];
    r = NSIntegralRectWithOptions(r, options);
    return [self convertRectFromBacking:r];
}

/* The origin and the size each to the nearest backing pixel. */
- (NSRect)centerScanRect:(NSRect)rect
{
    NSRect r = [self convertRectToBacking:rect];
    r.origin.x = round(r.origin.x);
    r.origin.y = round(r.origin.y);
    r.size.width = round(r.size.width);
    r.size.height = round(r.size.height);
    return [self convertRectFromBacking:r];
}

- (NSRect)visibleRect
{
    if (!_window)
        return NSMakeRect(-DBL_MAX / 2, -DBL_MAX / 2, DBL_MAX, DBL_MAX);
    NSRect r = _bounds;
    for (NSView *v = self; v->_superview; v = v->_superview) {
        NSRect inSuper = [v convertRect:r toView:v->_superview];
        inSuper = NSIntersectionRect(inSuper, v->_superview->_bounds);
        r = [v convertRect:inSuper fromView:v->_superview];
        if (NSIsEmptyRect(r))
            return NSZeroRect;
    }
    return NSIntersectionRect(r, _bounds);
}

#pragma mark - Hit testing

- (NSView *)hitTest:(NSPoint)point
{
    if (_f.hidden)
        return nil;
    BOOL superFlipped = _superview ? [_superview isFlipped] : NO;
    if (!NSMouseInRect(point, _frame, superFlipped))
        return nil;
    NSPoint local = _superview ? [self convertPoint:point fromView:_superview]
                               : NSPointFromCGPoint(CGPointApplyAffineTransform(
                                     NSPointToCGPoint(point), CGAffineTransformInvert(to_superview(self))));
    for (NSView *v in [_subviews reverseObjectEnumerator]) {
        NSView *hit = [v hitTest:local];
        if (hit)
            return hit;
    }
    return _f.ignoreHitTest ? nil : self;
}

- (BOOL)mouse:(NSPoint)point inRect:(NSRect)rect
{
    return NSMouseInRect(point, rect, [self isFlipped]);
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return NO; }
- (BOOL)shouldDelayWindowOrderingForEvent:(NSEvent *)event { return NO; }
- (BOOL)needsPanelToBecomeKey { return NO; }
- (BOOL)mouseDownCanMoveWindow { return [self isOpaque] ? NO : YES; }
- (BOOL)acceptsTouchEvents { return NO; }
- (void)setAcceptsTouchEvents:(BOOL)flag {}
- (BOOL)wantsRestingTouches { return NO; }
- (void)setWantsRestingTouches:(BOOL)flag {}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    for (NSView *v in [[_subviews copy] autorelease])
        if (![v isHidden] && [v performKeyEquivalent:event])
            return YES;
    return NO;
}

- (BOOL)performMnemonic:(NSString *)string
{
    for (NSView *v in [[_subviews copy] autorelease])
        if ([v performMnemonic:string])
            return YES;
    return NO;
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    return [self menu] ?: [[self class] defaultMenu];
}

+ (NSMenu *)defaultMenu
{
    return nil;
}

- (void)willOpenMenu:(NSMenu *)menu withEvent:(NSEvent *)event {}
- (void)didCloseMenu:(NSMenu *)menu withEvent:(NSEvent *)event {}

- (void)rightMouseDown:(NSEvent *)event
{
    NSMenu *menu = [self menuForEvent:event];
    if (menu)
        [(id)FINCH_CLASS(NSMenu) popUpContextMenu:menu withEvent:event forView:self];
    else
        [super rightMouseDown:event];
}

#pragma mark - The key view loop

- (NSView *)nextKeyView { return _nextKeyView; }
- (NSView *)previousKeyView { return _previousKeyView; }

- (void)setNextKeyView:(NSView *)next
{
    _nextKeyView = next;
    if (next)
        next->_previousKeyView = self;
}

- (BOOL)canBecomeKeyView
{
    return [self acceptsFirstResponder] && ![self isHiddenOrHasHiddenAncestor];
}

- (NSView *)nextValidKeyView
{
    for (NSView *v = _nextKeyView; v && v != self; v = v->_nextKeyView)
        if ([v canBecomeKeyView])
            return v;
    return nil;
}

- (NSView *)previousValidKeyView
{
    for (NSView *v = _previousKeyView; v && v != self; v = v->_previousKeyView)
        if ([v canBecomeKeyView])
            return v;
    return nil;
}

#pragma mark - Drawing

- (BOOL)needsDisplay { return !NSIsEmptyRect(_dirty); }

- (void)setNeedsDisplay:(BOOL)flag
{
    /* a layer-backed view's layer redraws with it (once: the layer's change comes back here) */
    if (flag && _layer && _f.layerBacked && ![_layer needsDisplay])
        [_layer setNeedsDisplay];
    if (flag)
        [self setNeedsDisplayInRect:_bounds];
    else
        _dirty = NSZeroRect;
}

- (void)setNeedsDisplayInRect:(NSRect)rect
{
    rect = NSIntersectionRect(rect, _bounds);
    if (NSIsEmptyRect(rect) || !_window)
        return;
    _dirty = NSIsEmptyRect(_dirty) ? rect : NSUnionRect(_dirty, rect);
    if (_window && !_f.hidden)
        [_window _finchInvalidateRect:[self convertRect:rect toView:nil]];
}

- (void)drawRect:(NSRect)dirtyRect {}

- (BOOL)needsToDrawRect:(NSRect)rect
{
    NSRect drawing = [NSGraphicsContext currentContext] ? FinchViewRectBeingDrawn(self) : _bounds;
    return NSIntersectsRect(rect, drawing);
}

- (void)getRectsBeingDrawn:(const NSRect **)rects count:(NSInteger *)count
{
    static NSRect one;
    one = FinchViewRectBeingDrawn(self);
    if (rects)
        *rects = &one;
    if (count)
        *count = 1;
}

- (void)getRectsExposedDuringLiveResize:(NSRect[4])exposedRects count:(NSInteger *)count
{
    exposedRects[0] = _bounds;
    *count = 1;
}

- (BOOL)wantsDefaultClipping { return YES; }
- (BOOL)clipsToBounds { return !_f.noClipping; }
- (void)setClipsToBounds:(BOOL)flag
{
    _f.noClipping = !flag;
    [self setNeedsDisplay:YES];
}

- (void)display { [self displayRect:_bounds]; }
- (void)displayIfNeeded
{
    if (_window)
        [_window displayIfNeeded];
}
- (void)displayIfNeededIgnoringOpacity { [self displayIfNeeded]; }
- (void)displayRect:(NSRect)rect
{
    if (_window) {
        [self setNeedsDisplayInRect:rect];
        [_window displayIfNeeded];
    }
}
- (void)displayIfNeededInRect:(NSRect)rect { [self displayIfNeeded]; }
- (void)displayRectIgnoringOpacity:(NSRect)rect { [self displayRect:rect]; }
- (void)displayIfNeededInRectIgnoringOpacity:(NSRect)rect { [self displayIfNeeded]; }

- (void)displayRectIgnoringOpacity:(NSRect)rect inContext:(NSGraphicsContext *)context
{
    FinchViewDrawTree(self, [context CGContext], rect, NO);
}

- (void)viewWillDraw
{
}

- (void)lockFocus
{
    [self lockFocusIfCanDraw];
}

- (BOOL)lockFocusIfCanDraw
{
    CGContextRef cg = [_window _finchCGContext];
    if (!cg)
        return NO;
    [NSGraphicsContext saveGraphicsState];
    CGContextSaveGState(cg);
    CGContextConcatCTM(cg, FinchViewToBase(self));
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:cg flipped:[self isFlipped]]];
    return YES;
}

- (void)unlockFocus
{
    CGContextRef cg = [[NSGraphicsContext currentContext] CGContext];
    if (cg)
        CGContextRestoreGState(cg);
    [NSGraphicsContext restoreGraphicsState];
    [_window _finchFlushDrawing];
}

+ (NSView *)focusView
{
    return nil;
}

- (BOOL)canDraw
{
    return _window != nil && ![self isHiddenOrHasHiddenAncestor];
}

- (NSBitmapImageRep *)bitmapImageRepForCachingDisplayInRect:(NSRect)rect
{
    CGFloat scale = FinchViewBackingScale(self);
    NSInteger w = (NSInteger)ceil(rect.size.width * scale), h = (NSInteger)ceil(rect.size.height * scale);
    NSBitmapImageRep *rep = [(NSBitmapImageRep *)[FINCH_CLASS(NSBitmapImageRep) alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                        isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [rep setSize:rect.size];
    return [rep autorelease];
}

- (void)cacheDisplayInRect:(NSRect)rect toBitmapImageRep:(NSBitmapImageRep *)rep
{
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGContextRef cg = [gc CGContext];
    if (!cg)
        return;
    CGContextSaveGState(cg);
    NSSize size = [rep size];
    CGFloat sx = size.width ? [rep pixelsWide] / size.width : 1, sy = size.height ? [rep pixelsHigh] / size.height : 1;
    /* The rep's own CTM is in pixels; draw in points, with rect's origin at the rep's. */
    CGContextScaleCTM(cg, sx / (CGContextGetCTM(cg).a ?: 1), sy / (CGContextGetCTM(cg).d ?: 1));
    CGContextClearRect(cg, CGRectMake(0, 0, rect.size.width, rect.size.height));
    NSRect inRoot = rect;
    if ([self isFlipped])
        CGContextConcatCTM(cg, CGAffineTransformMake(1, 0, 0, -1, -inRoot.origin.x, inRoot.origin.y + inRoot.size.height));
    else
        CGContextTranslateCTM(cg, -inRoot.origin.x, -inRoot.origin.y);
    FinchViewDrawTree(self, cg, rect, YES);
    CGContextRestoreGState(cg);
    CGContextFlush(cg);
}

#pragma mark - Tracking areas and cursor rects

- (NSArray<NSTrackingArea *> *)trackingAreas
{
    return _trackingAreas ? [[_trackingAreas copy] autorelease] : @[];
}

- (void)addTrackingArea:(NSTrackingArea *)area
{
    if (!_trackingAreas)
        _trackingAreas = [[NSMutableArray alloc] init];
    [_trackingAreas addObject:area];
    [area _finchSetView:self];
}

- (void)removeTrackingArea:(NSTrackingArea *)area
{
    [area _finchSetView:nil];
    [_trackingAreas removeObjectIdenticalTo:area];
}

- (void)updateTrackingAreas
{
}

- (NSTrackingRectTag)addTrackingRect:(NSRect)rect owner:(id)owner userData:(void *)data assumeInside:(BOOL)flag
{
    NSTrackingArea *area = [(NSTrackingArea *)[FINCH_CLASS(NSTrackingArea) alloc]
        initWithRect:rect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | (flag ? NSTrackingAssumeInside : 0)
               owner:owner userInfo:nil];
    [self addTrackingArea:area];
    [area release];
    return (NSTrackingRectTag)area;
}

- (void)removeTrackingRect:(NSTrackingRectTag)tag
{
    for (NSTrackingArea *a in [[_trackingAreas copy] autorelease])
        if ((NSTrackingRectTag)a == tag)
            [self removeTrackingArea:a];
}

- (void)addCursorRect:(NSRect)rect cursor:(NSCursor *)cursor {}
- (void)removeCursorRect:(NSRect)rect cursor:(NSCursor *)cursor {}
- (void)discardCursorRects {}
- (void)resetCursorRects {}

- (NSToolTipTag)addToolTipRect:(NSRect)rect owner:(id)owner userData:(void *)data { return 0; }
- (void)removeToolTip:(NSToolTipTag)tag {}
- (void)removeAllToolTips {}

#pragma mark - Scrolling

- (BOOL)autoscroll:(NSEvent *)event
{
    return [_superview autoscroll:event];
}

- (NSRect)adjustScroll:(NSRect)newVisible
{
    return newVisible;
}

- (void)scrollPoint:(NSPoint)point
{
    Class clip = NSClassFromString(@"NSClipView");
    NSView *s = _superview;
    if (clip && [s isKindOfClass:clip]) {
        NSPoint p = [self convertPoint:point toView:s];
        [(NSClipView *)s scrollToPoint:[s convertPoint:p fromView:s]];
    }
}

- (BOOL)scrollRectToVisible:(NSRect)rect
{
    Class clip = NSClassFromString(@"NSClipView");
    NSView *s = _superview;
    if (!clip || ![s isKindOfClass:clip])
        return [s scrollRectToVisible:[self convertRect:rect toView:s]];
    NSRect visible = [s bounds];
    NSRect r = [self convertRect:rect toView:s];
    NSPoint origin = visible.origin;
    if (NSMinX(r) < NSMinX(visible))
        origin.x = NSMinX(r);
    else if (NSMaxX(r) > NSMaxX(visible))
        origin.x = MIN(NSMinX(r), NSMaxX(r) - visible.size.width);
    if (NSMinY(r) < NSMinY(visible))
        origin.y = NSMinY(r);
    else if (NSMaxY(r) > NSMaxY(visible))
        origin.y = MIN(NSMinY(r), NSMaxY(r) - visible.size.height);
    if (NSEqualPoints(origin, visible.origin))
        return NO;
    [(NSClipView *)s scrollToPoint:origin];
    return YES;
}

- (void)scrollRect:(NSRect)rect by:(NSSize)delta
{
    [self setNeedsDisplay:YES];
}

- (void)reflectScrolledClipView:(NSClipView *)clipView
{
}

#pragma mark - Archiving (nibs)

enum {
    VFLAGS_AUTORESIZE_MASK = 0x3f,
    VFLAGS_AUTORESIZES_SUBVIEWS = 1 << 8,
    VFLAGS_HIDDEN = 1u << 31,
};

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _tag = -1;
    _f.postsFrame = YES;
    _f.postsBounds = YES;
    _f.translatesMask = YES;
    _f.needsLayout = YES;
    _f.needsUpdateConstraints = YES;
    if ([coder containsValueForKey:@"NSFrame"])
        _frame = [coder decodeRectForKey:@"NSFrame"];
    else if ([coder containsValueForKey:@"NSFrameSize"])
        _frame.size = [coder decodeSizeForKey:@"NSFrameSize"];
    _bounds = NSMakeRect(0, 0, _frame.size.width, _frame.size.height);
    if ([coder containsValueForKey:@"NSBounds"])
        [self setBounds:[coder decodeRectForKey:@"NSBounds"]];
    unsigned flags = [coder containsValueForKey:@"NSvFlags"] ? (unsigned)[coder decodeIntForKey:@"NSvFlags"]
                                                              : VFLAGS_AUTORESIZES_SUBVIEWS;
    _autoresizingMask = flags & VFLAGS_AUTORESIZE_MASK;
    _f.autoresizesSubviews = (flags & VFLAGS_AUTORESIZES_SUBVIEWS) != 0;
    _f.hidden = (flags & VFLAGS_HIDDEN) != 0;
    if ([coder containsValueForKey:@"NSTag"])
        _tag = [coder decodeIntegerForKey:@"NSTag"];
    if ([coder containsValueForKey:@"NSDoNotTranslateAutoresizingMask"])
        _f.translatesMask = ![coder decodeBoolForKey:@"NSDoNotTranslateAutoresizingMask"];
    _identifier = [[coder decodeObjectForKey:@"NSReuseIdentifierKey"] copy];
    _toolTip = [[coder decodeObjectForKey:@"NSToolTip"] copy];
    _appearance = [[coder decodeObjectForKey:@"NSAppearance"] retain];
    _superview = [coder decodeObjectForKey:@"NSSuperview"];
    for (NSView *v in [coder decodeObjectForKey:@"NSSubviews"]) {
        if (!_subviews)
            _subviews = [[NSMutableArray alloc] init];
        if ([_subviews indexOfObjectIdenticalTo:v] == NSNotFound)
            [_subviews addObject:v];
        v->_superview = self;
        [v setNextResponder:self];
    }
    NSView *next = [coder decodeObjectForKey:@"NSNextKeyView"];
    if (next)
        [self setNextKeyView:next];
    if ([coder containsValueForKey:@"NSViewWantsLayer"])
        _f.wantsLayer = [coder decodeBoolForKey:@"NSViewWantsLayer"];
    FinchLayoutDecodeView(self, coder);
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeRect:_frame forKey:@"NSFrame"];
    if (!NSEqualRects(_bounds, NSMakeRect(0, 0, _frame.size.width, _frame.size.height)))
        [coder encodeRect:_bounds forKey:@"NSBounds"];
    unsigned flags = (unsigned)_autoresizingMask | (_f.autoresizesSubviews ? VFLAGS_AUTORESIZES_SUBVIEWS : 0) |
                     (_f.hidden ? VFLAGS_HIDDEN : 0);
    [coder encodeInt:(int)flags forKey:@"NSvFlags"];
    if (_tag != -1)
        [coder encodeInteger:_tag forKey:@"NSTag"];
    if (_superview)
        [coder encodeConditionalObject:_superview forKey:@"NSSuperview"];
    if ([_subviews count])
        [coder encodeObject:_subviews forKey:@"NSSubviews"];
    if (_nextKeyView)
        [coder encodeConditionalObject:_nextKeyView forKey:@"NSNextKeyView"];
    if (_toolTip)
        [coder encodeObject:_toolTip forKey:@"NSToolTip"];
}

@end

#pragma mark - Drawing a tree

/* The rect being drawn in each view while the tree draws, in its bounds. */
static NSMapTable *being_drawn;

NSRect
FinchViewRectBeingDrawn(NSView *view)
{
    NSValue *v = being_drawn ? [being_drawn objectForKey:view] : nil;
    return v ? [v rectValue] : [view bounds];
}

/* A view's layer, in the view's bounds. */
static void
render_layer(NSView *view, CGContextRef cg, NSRect r, CGAffineTransform base)
{
    CALayer *layer = [view layer];
    if (!layer)
        return;
    NSRect bounds = [view bounds];
    if (!CGRectEqualToRect([layer bounds], NSRectToCGRect(bounds)))
        [layer setBounds:NSRectToCGRect(bounds)];
    CGFloat scale = [[view window] backingScaleFactor];
    if (scale > 0 && [layer contentsScale] != scale)
        [layer setContentsScale:scale];
    CGContextSaveGState(cg);
    CGContextConcatCTM(cg, base);
    CGContextClipToRect(cg, NSRectToCGRect(r));
    /* in the view's own space, as a window shows it: in a flipped view, the layer's drawing
       origin is the view's top left, as on macOS */
    [layer layoutIfNeeded];
    [layer renderInContext:cg];
    CGContextRestoreGState(cg);
}

/* A layer changed: the view whose layer it is (or is under) is redisplayed. */
static void
layer_changed(CALayer *layer)
{
    /* the view that shows it is recorded on the root of its tree; the view is redrawn, and its
       layer, which changed itself, isn't told again */
    CALayer *root = layer;
    while ([root superlayer])
        root = [root superlayer];
    NSView *owner = objc_getAssociatedObject(root, &layer_owner_key);
    if (owner && [owner layer] == root)
        [owner setNeedsDisplayInRect:[owner bounds]];
}

void
FinchViewInstallLayerHook(void)
{
    extern void (*FinchCALayerDidChange)(CALayer *) __attribute__((weak_import));
    if (&FinchCALayerDidChange && !FinchCALayerDidChange)
        FinchCALayerDidChange = layer_changed;
}

static void
draw_view(NSView *view, CGContextRef cg, NSRect rect, CGAffineTransform base)
{
    if ([view isHidden])
        return;
    CGFloat alpha = [view alphaValue];
    if (alpha <= 0)
        return;
    NSRect bounds = [view bounds];
    /* a view that doesn't clip to its bounds draws its subviews (and itself) beyond them */
    BOOL clips = [view clipsToBounds];
    NSRect r = clips ? NSIntersectionRect(rect, bounds) : rect;
    if (NSIsEmptyRect(r) && clips)
        return;
    /* a view with a mask (its maskView) is drawn apart, then the mask's alpha is applied */
    NSView *mask = [view maskView];
    BOOL layered = alpha < 1 || mask;
    if (layered) {
        CGContextSaveGState(cg);
        CGContextSetAlpha(cg, alpha);
        CGContextBeginTransparencyLayer(cg, NULL);
    }
    [view viewWillDraw];
    CGContextSaveGState(cg);
    CGContextConcatCTM(cg, base);
    if (clips)
        CGContextClipToRect(cg, NSRectToCGRect(bounds));
    CGContextClipToRect(cg, NSRectToCGRect(r));
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:[view isFlipped]];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:gc];
    if (!being_drawn)
        being_drawn = [[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory |
                                                          NSPointerFunctionsOpaquePersonality
                                             valueOptions:NSPointerFunctionsStrongMemory] retain];
    [being_drawn setObject:[NSValue valueWithRect:r] forKey:view];
    /* as Apple's, a view draws in its effective appearance (system colours resolve in it) */
    Class appearanceClass = FINCH_CLASS(NSAppearance);
    NSAppearance *savedAppearance = [[appearanceClass currentDrawingAppearance] retain];
    [appearanceClass setCurrentAppearance:[view effectiveAppearance]];
    @try {
        [view drawRect:r];
    } @finally {
        [appearanceClass setCurrentAppearance:savedAppearance];
        [savedAppearance release];
        [being_drawn removeObjectForKey:view];
        [NSGraphicsContext restoreGraphicsState];
        CGContextRestoreGState(cg);
    }
    [view setNeedsDisplay:NO];
    render_layer(view, cg, r, base);
    for (NSView *sub in [view subviews]) {
        NSRect inSub = [sub convertRect:r fromView:view];
        CGAffineTransform t = CGAffineTransformConcat(
            CGAffineTransformConcat(FinchViewToBase(sub), CGAffineTransformInvert(FinchViewToBase(view))), base);
        draw_view(sub, cg, inSub, t);
    }
    if (mask) {
        /* the mask in the view's space (its frame in the view's bounds), kept where it's opaque */
        NSRect frame = [mask frame], mb = [mask bounds];
        CGAffineTransform local = CGAffineTransformMakeTranslation(frame.origin.x - bounds.origin.x,
                                                                   frame.origin.y - bounds.origin.y);
        if ([mask isFlipped] != [view isFlipped])
            local = CGAffineTransformConcat(CGAffineTransformConcat(CGAffineTransformMakeScale(1, -1),
                                                                    CGAffineTransformMakeTranslation(0, frame.size.height)),
                                            local);
        local = CGAffineTransformConcat(CGAffineTransformMakeTranslation(-mb.origin.x, -mb.origin.y), local);
        CGContextSaveGState(cg);
        CGContextSetBlendMode(cg, kCGBlendModeDestinationIn);
        CGContextBeginTransparencyLayer(cg, NULL);
        draw_view(mask, cg, mb, CGAffineTransformConcat(local, base));
        CGContextEndTransparencyLayer(cg);
        CGContextRestoreGState(cg);
    }
    if (layered) {
        CGContextEndTransparencyLayer(cg);
        CGContextRestoreGState(cg);
    }
}

/*
 * Draw a view and its subviews into cg, whose CTM maps the view's
 * coordinates (or, with inViewSpace NO, the window's) to the device.
 */
void
FinchViewDrawTree(NSView *view, CGContextRef cg, NSRect rect, BOOL inViewSpace)
{
    if (!cg)
        return;
    CGAffineTransform base = inViewSpace ? CGAffineTransformIdentity : FinchViewToBase(view);
    draw_view(view, cg, rect, base);
}

const CGFloat NSViewNoIntrinsicMetric = -1;
