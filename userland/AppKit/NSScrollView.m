/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSScrollView: a clip view showing part of a document view, with
 * scrollers. Geometry is as Apple's with overlay scrollers (the default
 * here): the clip view fills the scroll view inside its border, and the
 * scrollers float over its trailing and bottom edges; legacy-style
 * scrollers take their width from the clip view instead. Scrolling by the
 * wheel or trackpad moves the clip view by the event's deltas (points when
 * precise, lines otherwise), held to the document; magnification scales
 * the clip view's bounds. Rulers are recorded but not drawn: Finch has no
 * NSRulerView yet.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"
#import "NSTableView_Finch.h"

NSNotificationName const NSScrollViewWillStartLiveMagnifyNotification = @"NSScrollViewWillStartLiveMagnifyNotification";
NSNotificationName const NSScrollViewDidEndLiveMagnifyNotification = @"NSScrollViewDidEndLiveMagnifyNotification";
NSNotificationName const NSScrollViewWillStartLiveScrollNotification = @"NSScrollViewWillStartLiveScrollNotification";
NSNotificationName const NSScrollViewDidLiveScrollNotification = @"NSScrollViewDidLiveScrollNotification";
NSNotificationName const NSScrollViewDidEndLiveScrollNotification = @"NSScrollViewDidEndLiveScrollNotification";

/* NSsFlags, as ibtool writes them. */
enum {
    SF_BORDER_MASK = 0x3,
    SF_HAS_VERTICAL = 1 << 4,
    SF_HAS_HORIZONTAL = 1 << 5,
    SF_AUTOHIDES = 1 << 9,
    SF_VERTICAL_ELASTICITY_SHIFT = 12,
    SF_HORIZONTAL_ELASTICITY_SHIFT = 14,
    SF_PREDOMINANT_AXIS = 1 << 16,
    SF_FIND_BAR_SHIFT = 17,
    SF_ALLOWS_MAGNIFICATION = 1 << 19,
};

static Class ruler_class;

@implementation NSScrollView {
    NSClipView *_contentView;
    NSScroller *_vScroller, *_hScroller;
    NSRulerView *_hRuler, *_vRuler;
    NSView *_findBarView;
    NSBorderType _borderType;
    CGFloat _hLine, _vLine, _hPage, _vPage;
    CGFloat _magnification, _minMagnification, _maxMagnification;
    NSEdgeInsets _contentInsets, _scrollerInsets;
    NSScrollerStyle _scrollerStyle;
    NSScrollerKnobStyle _knobStyle;
    NSScrollElasticity _hElasticity, _vElasticity;
    NSScrollViewFindBarPosition _findBarPosition;
    BOOL _hasV, _hasH, _autohides, _predominantAxis, _allowsMagnification, _hasHRuler, _hasVRuler, _rulersVisible;
    BOOL _adjustsInsets, _findBarVisible, _tiling;
    BOOL _insetsStale; /* the automatic insets need working out in the next layout pass */
}

static void
scroll_init(NSScrollView *self)
{
    self->_hLine = self->_vLine = 10;
    self->_hPage = self->_vPage = 10;
    self->_magnification = 1;
    self->_minMagnification = 0.25;
    self->_maxMagnification = 4;
    self->_scrollerStyle = [NSScroller preferredScrollerStyle];
    self->_predominantAxis = YES;
    self->_adjustsInsets = YES;
    self->_findBarPosition = NSScrollViewFindBarPositionAboveContent;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        scroll_init(self);
        NSClipView *clip = [[NSClipView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
        [self setContentView:clip];
        [clip release];
    }
    return self;
}

- (void)dealloc
{
    [_contentView release];
    [_vScroller release];
    [_hScroller release];
    [_hRuler release];
    [_vRuler release];
    [_findBarView release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return [_contentView drawsBackground] && _borderType == NSNoBorder; }

#pragma mark - Views

- (NSClipView *)contentView { return _contentView; }

- (void)setContentView:(NSClipView *)view
{
    if (view == _contentView)
        return;
    NSView *doc = [[[_contentView documentView] retain] autorelease];
    if (_contentView) {
        [_contentView removeFromSuperview];
        [_contentView release];
    }
    _contentView = [view retain];
    if (view) {
        [self addSubview:view positioned:NSWindowBelow relativeTo:nil];
        if (doc && ![view documentView])
            [view setDocumentView:doc];
    }
    [self tile];
}

- (__kindof NSView *)documentView { return [_contentView documentView]; }

- (void)setDocumentView:(NSView *)view
{
    [_contentView setDocumentView:view];
    [self tile];
    [self reflectScrolledClipView:_contentView];
}

- (NSRect)documentVisibleRect { return [_contentView documentVisibleRect]; }
- (NSSize)contentSize { return [_contentView frame].size; }

- (NSColor *)backgroundColor { return [_contentView backgroundColor]; }
- (void)setBackgroundColor:(NSColor *)color { [_contentView setBackgroundColor:color]; }
- (BOOL)drawsBackground { return [_contentView drawsBackground]; }
- (void)setDrawsBackground:(BOOL)flag { [_contentView setDrawsBackground:flag]; }
- (NSCursor *)documentCursor { return [_contentView documentCursor]; }
- (void)setDocumentCursor:(NSCursor *)cursor { [_contentView setDocumentCursor:cursor]; }

#pragma mark - Scrollers

static NSScroller *
make_scroller(NSScrollView *self, BOOL horizontal)
{
    NSRect f = horizontal ? NSMakeRect(0, 0, 100, [NSScroller scrollerWidth]) : NSMakeRect(0, 0, [NSScroller scrollerWidth], 100);
    NSScroller *s = [[NSScroller alloc] initWithFrame:f];
    [s setTarget:self];
    [s setAction:@selector(_doScroller:)];
    [s setScrollerStyle:self->_scrollerStyle];
    [s setKnobStyle:self->_knobStyle];
    [self addSubview:s];
    return s;
}

- (NSScroller *)verticalScroller { return _vScroller; }
- (NSScroller *)horizontalScroller { return _hScroller; }

- (void)setVerticalScroller:(NSScroller *)scroller
{
    if (scroller == _vScroller)
        return;
    [_vScroller removeFromSuperview];
    [_vScroller release];
    _vScroller = [scroller retain];
    if (scroller) {
        [scroller setTarget:self];
        [scroller setAction:@selector(_doScroller:)];
        if (_hasV)
            [self addSubview:scroller];
    }
    [self tile];
}

- (void)setHorizontalScroller:(NSScroller *)scroller
{
    if (scroller == _hScroller)
        return;
    [_hScroller removeFromSuperview];
    [_hScroller release];
    _hScroller = [scroller retain];
    if (scroller) {
        [scroller setTarget:self];
        [scroller setAction:@selector(_doScroller:)];
        if (_hasH)
            [self addSubview:scroller];
    }
    [self tile];
}

- (BOOL)hasVerticalScroller { return _hasV; }
- (BOOL)hasHorizontalScroller { return _hasH; }

- (void)setHasVerticalScroller:(BOOL)flag
{
    _hasV = flag;
    if (flag && !_vScroller)
        _vScroller = make_scroller(self, NO);
    else if (flag && [_vScroller superview] != self)
        [self addSubview:_vScroller];
    [self tile];
    [self reflectScrolledClipView:_contentView];
}

- (void)setHasHorizontalScroller:(BOOL)flag
{
    _hasH = flag;
    if (flag && !_hScroller)
        _hScroller = make_scroller(self, YES);
    else if (flag && [_hScroller superview] != self)
        [self addSubview:_hScroller];
    [self tile];
    [self reflectScrolledClipView:_contentView];
}

- (BOOL)autohidesScrollers { return _autohides; }
- (void)setAutohidesScrollers:(BOOL)flag
{
    _autohides = flag;
    [self reflectScrolledClipView:_contentView];
}

- (NSScrollerStyle)scrollerStyle { return _scrollerStyle; }
- (void)setScrollerStyle:(NSScrollerStyle)style
{
    _scrollerStyle = style;
    [_vScroller setScrollerStyle:style];
    [_hScroller setScrollerStyle:style];
    [self tile];
}

- (NSScrollerKnobStyle)scrollerKnobStyle { return _knobStyle; }
- (void)setScrollerKnobStyle:(NSScrollerKnobStyle)style
{
    _knobStyle = style;
    [_vScroller setKnobStyle:style];
    [_hScroller setKnobStyle:style];
}

- (NSBorderType)borderType { return _borderType; }
- (void)setBorderType:(NSBorderType)type
{
    _borderType = type;
    [self tile];
    [self setNeedsDisplay:YES];
}

- (NSScrollElasticity)horizontalScrollElasticity { return _hElasticity; }
- (void)setHorizontalScrollElasticity:(NSScrollElasticity)e { _hElasticity = e; }
- (NSScrollElasticity)verticalScrollElasticity { return _vElasticity; }
- (void)setVerticalScrollElasticity:(NSScrollElasticity)e { _vElasticity = e; }
- (BOOL)usesPredominantAxisScrolling { return _predominantAxis; }
- (void)setUsesPredominantAxisScrolling:(BOOL)flag { _predominantAxis = flag; }
- (BOOL)scrollsDynamically { return YES; }
- (void)setScrollsDynamically:(BOOL)flag {}
- (NSEdgeInsets)scrollerInsets { return _scrollerInsets; }
- (void)setScrollerInsets:(NSEdgeInsets)insets
{
    _scrollerInsets = insets;
    [self tile];
}

#pragma mark - Line and page amounts

- (CGFloat)lineScroll { return _vLine; }
- (void)setLineScroll:(CGFloat)v { _hLine = _vLine = v; }
- (CGFloat)horizontalLineScroll { return _hLine; }
- (void)setHorizontalLineScroll:(CGFloat)v { _hLine = v; }
- (CGFloat)verticalLineScroll { return _vLine; }
- (void)setVerticalLineScroll:(CGFloat)v { _vLine = v; }
- (CGFloat)pageScroll { return _vPage; }
- (void)setPageScroll:(CGFloat)v { _hPage = _vPage = v; }
- (CGFloat)horizontalPageScroll { return _hPage; }
- (void)setHorizontalPageScroll:(CGFloat)v { _hPage = v; }
- (CGFloat)verticalPageScroll { return _vPage; }
- (void)setVerticalPageScroll:(CGFloat)v { _vPage = v; }

#pragma mark - Sizes

static CGFloat
border_width(NSBorderType type)
{
    switch (type) {
    case NSLineBorder:
    case NSBezelBorder:
        return 1;
    case NSGrooveBorder:
        return 2;
    default:
        return 0;
    }
}

+ (NSSize)frameSizeForContentSize:(NSSize)size horizontalScrollerClass:(Class)hClass verticalScrollerClass:(Class)vClass
                       borderType:(NSBorderType)type controlSize:(NSControlSize)controlSize
                    scrollerStyle:(NSScrollerStyle)style
{
    CGFloat b = border_width(type);
    size.width += 2 * b;
    size.height += 2 * b;
    if (style == NSScrollerStyleLegacy) {
        if (vClass)
            size.width += [vClass scrollerWidthForControlSize:controlSize scrollerStyle:style];
        if (hClass)
            size.height += [hClass scrollerWidthForControlSize:controlSize scrollerStyle:style];
    }
    return size;
}

+ (NSSize)contentSizeForFrameSize:(NSSize)size horizontalScrollerClass:(Class)hClass verticalScrollerClass:(Class)vClass
                       borderType:(NSBorderType)type controlSize:(NSControlSize)controlSize
                    scrollerStyle:(NSScrollerStyle)style
{
    CGFloat b = border_width(type);
    size.width = MAX(0, size.width - 2 * b);
    size.height = MAX(0, size.height - 2 * b);
    if (style == NSScrollerStyleLegacy) {
        if (vClass)
            size.width = MAX(0, size.width - [vClass scrollerWidthForControlSize:controlSize scrollerStyle:style]);
        if (hClass)
            size.height = MAX(0, size.height - [hClass scrollerWidthForControlSize:controlSize scrollerStyle:style]);
    }
    return size;
}

+ (NSSize)frameSizeForContentSize:(NSSize)size hasHorizontalScroller:(BOOL)h hasVerticalScroller:(BOOL)v
                       borderType:(NSBorderType)type
{
    return [self frameSizeForContentSize:size horizontalScrollerClass:h ? [NSScroller class] : nil
                   verticalScrollerClass:v ? [NSScroller class] : nil borderType:type
                             controlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleLegacy];
}

+ (NSSize)contentSizeForFrameSize:(NSSize)size hasHorizontalScroller:(BOOL)h hasVerticalScroller:(BOOL)v
                       borderType:(NSBorderType)type
{
    return [self contentSizeForFrameSize:size horizontalScrollerClass:h ? [NSScroller class] : nil
                   verticalScrollerClass:v ? [NSScroller class] : nil borderType:type
                             controlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleLegacy];
}

#pragma mark - Layout

static BOOL
shows(NSScrollView *self, NSScroller *s, BOOL has)
{
    return s && has && ![s isHidden];
}

- (void)tile
{
    if (_tiling)
        return;
    _tiling = YES;
    NSRect inner = NSInsetRect([self bounds], border_width(_borderType), border_width(_borderType));
    /* the find bar takes its height above (or below) the content and the scrollers */
    if (_findBarView) {
        if (_findBarVisible) {
            CGFloat fb = NSHeight([_findBarView frame]);
            NSRect bar = NSMakeRect(NSMinX(inner), NSMinY(inner), NSWidth(inner), fb);
            if (_findBarPosition == NSScrollViewFindBarPositionBelowContent)
                bar.origin.y = NSMaxY(inner) - fb;
            else
                inner.origin.y += fb;
            inner.size.height = MAX(0, inner.size.height - fb);
            if ([_findBarView superview] != self)
                [self addSubview:_findBarView];
            [_findBarView setFrame:bar];
            [_findBarView setHidden:NO];
        } else {
            [_findBarView setHidden:YES];
        }
    }
    BOOL v = shows(self, _vScroller, _hasV), h = shows(self, _hScroller, _hasH);
    CGFloat vw = v ? NSWidth([_vScroller frame]) : 0, hw = h ? NSHeight([_hScroller frame]) : 0;
    if (v && vw <= 0)
        vw = [NSScroller scrollerWidth];
    if (h && hw <= 0)
        hw = [NSScroller scrollerWidth];
    NSRect content = inner;
    if (_scrollerStyle == NSScrollerStyleLegacy) {
        content.size.width = MAX(0, content.size.width - vw);
        content.size.height = MAX(0, content.size.height - hw);
    }
    [_contentView setFrame:content];
    /* The scrollers sit on the trailing and bottom edges (the scroll view is flipped). */
    if (_vScroller) {
        NSRect f = NSMakeRect(NSMaxX(inner) - vw, NSMinY(inner) + _scrollerInsets.top, vw,
                              NSHeight(inner) - (h ? hw : 0) - _scrollerInsets.top - _scrollerInsets.bottom);
        [_vScroller setFrame:f];
        [_vScroller setHidden:!_hasV || [_vScroller isHidden]];
    }
    if (_hScroller) {
        NSRect f = NSMakeRect(NSMinX(inner) + _scrollerInsets.left, NSMaxY(inner) - hw,
                              NSWidth(inner) - (v ? vw : 0) - _scrollerInsets.left - _scrollerInsets.right, hw);
        [_hScroller setFrame:f];
        [_hScroller setHidden:!_hasH || [_hScroller isHidden]];
    }
    FinchScrollViewTileHeader(self, inner); /* a table's header (NSTableHeaderView.m) */
    _tiling = NO;
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    _insetsStale = YES;
    [self setNeedsLayout:YES];
    [self tile];
    [self reflectScrolledClipView:_contentView];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    /* -tile places the clip view and scrollers. */
}

- (void)drawRect:(NSRect)rect
{
    if (_borderType == NSNoBorder)
        return;
    NSRect b = [self bounds];
    NSColor *c = _borderType == NSLineBorder ? [NSColor colorWithWhite:0 alpha:0.5] : [NSColor colorWithWhite:0.6 alpha:1];
    [c setFill];
    CGFloat w = border_width(_borderType);
    NSRectFill(NSMakeRect(NSMinX(b), NSMinY(b), NSWidth(b), w));
    NSRectFill(NSMakeRect(NSMinX(b), NSMaxY(b) - w, NSWidth(b), w));
    NSRectFill(NSMakeRect(NSMinX(b), NSMinY(b), w, NSHeight(b)));
    NSRectFill(NSMakeRect(NSMaxX(b) - w, NSMinY(b), w, NSHeight(b)));
}

#pragma mark - Scrolling

/* The scroller value for one axis: how far through the scrollable range the visible part is. */
static void
axis_state(CGFloat docMin, CGFloat docLen, CGFloat visMin, CGFloat visLen, BOOL invert, double *value,
           CGFloat *proportion)
{
    if (docLen <= 0 || visLen >= docLen) {
        *proportion = docLen > 0 ? 1 : 0;
        *value = 0;
        return;
    }
    *proportion = visLen / docLen;
    double v = (visMin - docMin) / (docLen - visLen);
    v = MAX(0, MIN(1, v));
    *value = invert ? 1 - v : v;
}

- (void)reflectScrolledClipView:(NSClipView *)clip
{
    if (clip != _contentView)
        return;
    FinchScrollViewReflectHeader(self);
    NSView *doc = [clip documentView];
    NSRect d = doc ? [doc frame] : NSZeroRect, b = [clip bounds];
    BOOL changed = NO;
    if (_vScroller) {
        double v;
        CGFloat p;
        axis_state(NSMinY(d), NSHeight(d), NSMinY(b), NSHeight(b), ![clip isFlipped], &v, &p);
        [_vScroller setKnobProportion:p];
        [_vScroller setDoubleValue:v];
        [_vScroller setEnabled:doc && p < 1];
        BOOL hide = !_hasV || (_autohides && !(doc && p < 1));
        if (hide != [_vScroller isHidden]) {
            [_vScroller setHidden:hide];
            changed = YES;
        }
    }
    if (_hScroller) {
        double v;
        CGFloat p;
        axis_state(NSMinX(d), NSWidth(d), NSMinX(b), NSWidth(b), NO, &v, &p);
        [_hScroller setKnobProportion:p];
        [_hScroller setDoubleValue:v];
        [_hScroller setEnabled:doc && p < 1];
        BOOL hide = !_hasH || (_autohides && !(doc && p < 1));
        if (hide != [_hScroller isHidden]) {
            [_hScroller setHidden:hide];
            changed = YES;
        }
    }
    if (changed && _scrollerStyle == NSScrollerStyleLegacy)
        [self tile];
}

- (void)_doScroller:(NSScroller *)scroller
{
    NSView *doc = [self documentView];
    if (!doc)
        return;
    NSRect d = [doc frame], b = [_contentView bounds];
    NSPoint o = b.origin;
    double v = [scroller doubleValue];
    if (scroller == _vScroller) {
        if (![_contentView isFlipped])
            v = 1 - v;
        o.y = NSMinY(d) + v * MAX(0, NSHeight(d) - NSHeight(b));
    } else if (scroller == _hScroller) {
        o.x = NSMinX(d) + v * MAX(0, NSWidth(d) - NSWidth(b));
    }
    [_contentView scrollToPoint:[_contentView constrainScrollPoint:o]];
}

/* Scroll the clip view by (dx, dy) in its bounds, toward the document's top-left when positive in flipped terms. */
static BOOL
scroll_by(NSScrollView *self, CGFloat dx, CGFloat dy)
{
    NSClipView *clip = self->_contentView;
    if (![clip documentView])
        return NO;
    NSPoint o = [clip bounds].origin;
    NSPoint want = NSMakePoint(o.x + dx, [clip isFlipped] ? o.y + dy : o.y - dy);
    NSPoint c = [clip constrainScrollPoint:want];
    if (NSEqualPoints(c, o))
        return NO;
    [clip scrollToPoint:c];
    return YES;
}

- (void)scrollWheel:(NSEvent *)event
{
    CGFloat dx = [event scrollingDeltaX], dy = [event scrollingDeltaY];
    if (![event hasPreciseScrollingDeltas]) {
        dx *= _hLine;
        dy *= _vLine;
    }
    if (_predominantAxis) {
        if (fabs(dx) > fabs(dy))
            dy = 0;
        else
            dx = 0;
    }
    if (!_hasH && !_hasV) {
        /* still scrolls, as Apple's does */
    }
    CGFloat m = _magnification > 0 ? _magnification : 1;
    if (!scroll_by(self, -dx / m, -dy / m))
        [[self nextResponder] scrollWheel:event];
}

static CGFloat
page_amount(NSScrollView *self)
{
    return MAX(NSHeight([self->_contentView bounds]) - self->_vPage, self->_vLine);
}

- (void)scrollLineUp:(id)sender { scroll_by(self, 0, -_vLine); }
- (void)scrollLineDown:(id)sender { scroll_by(self, 0, _vLine); }
- (void)scrollPageUp:(id)sender { scroll_by(self, 0, -page_amount(self)); }
- (void)scrollPageDown:(id)sender { scroll_by(self, 0, page_amount(self)); }
- (void)pageUp:(id)sender { [self scrollPageUp:sender]; }
- (void)pageDown:(id)sender { [self scrollPageDown:sender]; }
- (void)scrollToBeginningOfDocument:(id)sender { scroll_by(self, 0, -CGFLOAT_MAX / 4); }
- (void)scrollToEndOfDocument:(id)sender { scroll_by(self, 0, CGFLOAT_MAX / 4); }

- (void)flashScrollers {}

#pragma mark - Insets

- (NSEdgeInsets)contentInsets { return _contentInsets; }

- (void)setContentInsets:(NSEdgeInsets)insets
{
    NSEdgeInsets old = _contentInsets;
    _contentInsets = insets;
    _insetsStale = NO; /* insets set by hand stand until the frame or window changes */
    NSPoint o = [_contentView bounds].origin;
    o.x -= insets.left - old.left;
    if ([_contentView isFlipped])
        o.y -= insets.top - old.top;
    else
        o.y -= insets.bottom - old.bottom;
    [_contentView setContentInsets:insets];
    [_contentView setBoundsOrigin:o];
    [self tile]; /* a table's header adds to the clip view's inset */
}

/*
 * As Apple's, in the window's layout pass a scroll view that adjusts its insets takes a top inset of how
 * far it runs above the window's contentLayoutRect (under a full-size content window's title bar and
 * toolbar), and no others.
 */
- (void)layout
{
    [super layout];
    NSWindow *w = [self window];
    if (!_adjustsInsets || !w || !_insetsStale)
        return;
    _insetsStale = NO;
    NSRect f = [self convertRect:[self bounds] toView:nil];
    CGFloat top = MAX(0, NSMaxY(f) - NSMaxY([w contentLayoutRect]));
    if (_contentInsets.top != top || _contentInsets.left != 0 || _contentInsets.bottom != 0 || _contentInsets.right != 0)
        [self setContentInsets:NSEdgeInsetsMake(top, 0, 0, 0)];
}

- (void)setFrameOrigin:(NSPoint)origin
{
    [super setFrameOrigin:origin];
    _insetsStale = YES;
    [self setNeedsLayout:YES];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    _insetsStale = YES;
    [self setNeedsLayout:YES];
}

- (BOOL)automaticallyAdjustsContentInsets { return _adjustsInsets; }
- (void)setAutomaticallyAdjustsContentInsets:(BOOL)flag
{
    _adjustsInsets = flag;
    [_contentView setAutomaticallyAdjustsContentInsets:flag];
    if (flag) {
        _insetsStale = YES;
        [self setNeedsLayout:YES];
    }
}

#pragma mark - Magnification

- (BOOL)allowsMagnification { return _allowsMagnification; }
- (void)setAllowsMagnification:(BOOL)flag { _allowsMagnification = flag; }
- (CGFloat)minMagnification { return _minMagnification; }
- (void)setMinMagnification:(CGFloat)v { _minMagnification = v; }
- (CGFloat)maxMagnification { return _maxMagnification; }
- (void)setMaxMagnification:(CGFloat)v { _maxMagnification = v; }
- (CGFloat)magnification { return _magnification; }

static CGFloat
clamp_magnification(NSScrollView *self, CGFloat m)
{
    return MAX(self->_minMagnification, MIN(self->_maxMagnification, m));
}

/* Magnify, putting the bounds origin at `origin` for the new size (then held to the document). */
static void
apply_magnification(NSScrollView *self, CGFloat m, NSPoint (^origin)(NSSize size))
{
    self->_magnification = m;
    NSClipView *clip = self->_contentView;
    NSSize frame = [clip frame].size;
    NSSize size = NSMakeSize(frame.width / m, frame.height / m);
    NSPoint o = origin(size);
    [clip setBoundsSize:size];
    [clip setBoundsOrigin:o];
    [self reflectScrolledClipView:clip];
}

- (void)setMagnification:(CGFloat)magnification
{
    NSRect b = [_contentView bounds];
    NSPoint centre = NSMakePoint(NSMidX(b), NSMidY(b));
    apply_magnification(self, clamp_magnification(self, magnification), ^NSPoint(NSSize s) {
      return NSMakePoint(centre.x - s.width / 2, centre.y - s.height / 2);
    });
}

- (void)setMagnification:(CGFloat)magnification centeredAtPoint:(NSPoint)point
{
    NSRect b = [_contentView bounds];
    apply_magnification(self, clamp_magnification(self, magnification), ^NSPoint(NSSize s) {
      /* the point stays where it is in the clip view */
      CGFloat sx = NSWidth(b) ? s.width / NSWidth(b) : 1, sy = NSHeight(b) ? s.height / NSHeight(b) : 1;
      return NSMakePoint(point.x - (point.x - NSMinX(b)) * sx, point.y - (point.y - NSMinY(b)) * sy);
    });
}

- (void)magnifyToFitRect:(NSRect)rect
{
    if (NSIsEmptyRect(rect))
        return;
    NSSize frame = [_contentView frame].size;
    CGFloat m = MIN(frame.width / rect.size.width, frame.height / rect.size.height);
    apply_magnification(self, clamp_magnification(self, m), ^NSPoint(NSSize s) {
      return NSMakePoint(NSMidX(rect) - s.width / 2, NSMidY(rect) - s.height / 2);
    });
}

- (void)magnifyWithEvent:(NSEvent *)event
{
    if (!_allowsMagnification) {
        [super magnifyWithEvent:event];
        return;
    }
    [self setMagnification:_magnification * (1 + [event magnification])];
}

#pragma mark - Rulers (recorded only)

+ (Class)rulerViewClass { return ruler_class; }
+ (void)setRulerViewClass:(Class)rulerViewClass { ruler_class = rulerViewClass; }
- (BOOL)rulersVisible { return _rulersVisible; }
- (void)setRulersVisible:(BOOL)flag { _rulersVisible = flag; }
- (BOOL)hasHorizontalRuler { return _hasHRuler; }
- (void)setHasHorizontalRuler:(BOOL)flag { _hasHRuler = flag; }
- (BOOL)hasVerticalRuler { return _hasVRuler; }
- (void)setHasVerticalRuler:(BOOL)flag { _hasVRuler = flag; }
- (NSRulerView *)horizontalRulerView { return _hRuler; }
- (void)setHorizontalRulerView:(NSRulerView *)ruler
{
    [_hRuler autorelease];
    _hRuler = [ruler retain];
}
- (NSRulerView *)verticalRulerView { return _vRuler; }
- (void)setVerticalRulerView:(NSRulerView *)ruler
{
    [_vRuler autorelease];
    _vRuler = [ruler retain];
}

#pragma mark - Find bar

- (NSView *)findBarView { return _findBarView; }
- (void)setFindBarView:(NSView *)view
{
    if (_findBarView && _findBarView != view)
        [_findBarView removeFromSuperview];
    [_findBarView autorelease];
    _findBarView = [view retain];
}
- (BOOL)isFindBarVisible { return _findBarVisible; }
- (void)setFindBarVisible:(BOOL)flag
{
    _findBarVisible = flag;
    [self tile];
}
- (NSScrollViewFindBarPosition)findBarPosition { return _findBarPosition; }
- (void)setFindBarPosition:(NSScrollViewFindBarPosition)p { _findBarPosition = p; }
- (void)findBarViewDidChangeHeight { [self tile]; }

- (void)addFloatingSubview:(NSView *)view forAxis:(NSEventGestureAxis)axis { [self addSubview:view]; }

#pragma mark - Archiving

/* NSScrollAmts: four big-endian floats, the horizontal and vertical page amounts, then the line amounts. */
static float
be_float(const uint8_t *p)
{
    uint32_t u = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
    float f;
    memcpy(&f, &u, 4);
    return f;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    scroll_init(self);
    unsigned flags = (unsigned)[coder decodeIntForKey:@"NSsFlags"];
    _borderType = flags & SF_BORDER_MASK;
    _hasV = (flags & SF_HAS_VERTICAL) != 0;
    _hasH = (flags & SF_HAS_HORIZONTAL) != 0;
    _autohides = (flags & SF_AUTOHIDES) != 0;
    _vElasticity = (flags >> SF_VERTICAL_ELASTICITY_SHIFT) & 3;
    _hElasticity = (flags >> SF_HORIZONTAL_ELASTICITY_SHIFT) & 3;
    _predominantAxis = (flags & SF_PREDOMINANT_AXIS) != 0;
    _findBarPosition = (flags >> SF_FIND_BAR_SHIFT) & 3;
    _allowsMagnification = (flags & SF_ALLOWS_MAGNIFICATION) != 0;
    NSData *amounts = [coder decodeObjectForKey:@"NSScrollAmts"];
    if ([amounts isKindOfClass:[NSData class]] && [amounts length] >= 16) {
        const uint8_t *p = [amounts bytes];
        _hPage = be_float(p);
        _vPage = be_float(p + 4);
        _hLine = be_float(p + 8);
        _vLine = be_float(p + 12);
    }
    if ([coder containsValueForKey:@"NSMagnification"])
        _magnification = [coder decodeDoubleForKey:@"NSMagnification"];
    if ([coder containsValueForKey:@"NSMinMagnification"])
        _minMagnification = [coder decodeDoubleForKey:@"NSMinMagnification"];
    if ([coder containsValueForKey:@"NSMaxMagnification"])
        _maxMagnification = [coder decodeDoubleForKey:@"NSMaxMagnification"];
    if ([coder containsValueForKey:@"NSScrollerKnobStyle"])
        _knobStyle = [coder decodeIntegerForKey:@"NSScrollerKnobStyle"];
    _contentView = [[coder decodeObjectForKey:@"NSContentView"] retain];
    _vScroller = [[coder decodeObjectForKey:@"NSVScroller"] retain];
    _hScroller = [[coder decodeObjectForKey:@"NSHScroller"] retain];
    for (NSScroller *s in @[ _vScroller ?: (id)[NSNull null], _hScroller ?: (id)[NSNull null] ]) {
        if (![s isKindOfClass:[NSScroller class]])
            continue;
        [s setTarget:self];
        [s setAction:@selector(_doScroller:)];
        [s setScrollerStyle:_scrollerStyle];
    }
    [_vScroller setHidden:!_hasV];
    [_hScroller setHidden:!_hasH];
    [self tile];
    [self reflectScrolledClipView:_contentView];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    unsigned flags = (unsigned)_borderType | (_hasV ? SF_HAS_VERTICAL : 0) | (_hasH ? SF_HAS_HORIZONTAL : 0) |
                     (_autohides ? SF_AUTOHIDES : 0) | ((unsigned)_vElasticity << SF_VERTICAL_ELASTICITY_SHIFT) |
                     ((unsigned)_hElasticity << SF_HORIZONTAL_ELASTICITY_SHIFT) |
                     (_predominantAxis ? SF_PREDOMINANT_AXIS : 0) | ((unsigned)_findBarPosition << SF_FIND_BAR_SHIFT) |
                     (_allowsMagnification ? SF_ALLOWS_MAGNIFICATION : 0);
    [coder encodeInt:(int)flags forKey:@"NSsFlags"];
    if (_contentView)
        [coder encodeObject:_contentView forKey:@"NSContentView"];
    if (_vScroller)
        [coder encodeObject:_vScroller forKey:@"NSVScroller"];
    if (_hScroller)
        [coder encodeObject:_hScroller forKey:@"NSHScroller"];
    float amounts[4] = {(float)_hPage, (float)_vPage, (float)_hLine, (float)_vLine};
    uint8_t bytes[16];
    for (int i = 0; i < 4; i++) {
        uint32_t u;
        memcpy(&u, &amounts[i], 4);
        bytes[i * 4] = u >> 24, bytes[i * 4 + 1] = u >> 16, bytes[i * 4 + 2] = u >> 8, bytes[i * 4 + 3] = u;
    }
    [coder encodeObject:[NSData dataWithBytes:bytes length:16] forKey:@"NSScrollAmts"];
    [coder encodeDouble:_magnification forKey:@"NSMagnification"];
    [coder encodeDouble:_minMagnification forKey:@"NSMinMagnification"];
    [coder encodeDouble:_maxMagnification forKey:@"NSMaxMagnification"];
}

@end

/* Apple's scroll views answer a delegate (private); apps set one. */
@implementation NSScrollView (FinchDelegate)
static const void *kScrollDelegate = &kScrollDelegate;
- (id)delegate { return objc_getAssociatedObject(self, kScrollDelegate); }
- (void)setDelegate:(id)d { objc_setAssociatedObject(self, kScrollDelegate, d, OBJC_ASSOCIATION_ASSIGN); }
@end
