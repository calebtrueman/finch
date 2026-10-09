/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSClipView: the scroll view's content view. It holds the document view
 * as its only subview and shows part of it: scrolling is moving its bounds
 * origin. As Apple's, -scrollToPoint: moves there as asked, while
 * -setBoundsOrigin: goes through -constrainBoundsRect:, which keeps the
 * bounds over the document (and its content insets); the clip view is
 * flipped when its document view is, and follows the document's frame
 * changes. Copying on scroll is a redraw here.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"

@implementation NSClipView {
    NSView *_documentView;  /* a subview, retained through the subview list */
    NSColor *_backgroundColor;
    NSEdgeInsets _insets;
    BOOL _drawsBackground, _copiesOnScroll, _adjustsInsets;
}

static void
clip_init(NSClipView *self)
{
    self->_drawsBackground = YES;
    self->_copiesOnScroll = YES;
    self->_adjustsInsets = YES;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        clip_init(self);
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_backgroundColor release];
    [super dealloc];
}

- (BOOL)isFlipped { return _documentView ? [_documentView isFlipped] : NO; }
- (BOOL)isOpaque { return _drawsBackground && _backgroundColor && [_backgroundColor alphaComponent] >= 1; }

- (NSColor *)backgroundColor
{
    return _backgroundColor ?: [NSColor controlBackgroundColor];
}

- (void)setBackgroundColor:(NSColor *)color
{
    [_backgroundColor autorelease];
    _backgroundColor = [color retain];
    [self setNeedsDisplay:YES];
}

- (BOOL)drawsBackground { return _drawsBackground; }
- (void)setDrawsBackground:(BOOL)flag
{
    _drawsBackground = flag;
    [self setNeedsDisplay:YES];
}
- (BOOL)copiesOnScroll { return _copiesOnScroll; }
- (void)setCopiesOnScroll:(BOOL)flag { _copiesOnScroll = flag; }
- (NSEdgeInsets)contentInsets { return _insets; }
/* A text view fills what the clip view shows (NSTextView.m). */
static void
fit_document(NSClipView *self)
{
    NSView *doc = [self documentView];
    if ([doc respondsToSelector:@selector(_finchFitClipView)])
        [(id)doc _finchFitClipView];
}

- (void)setContentInsets:(NSEdgeInsets)insets
{
    _insets = insets;
    fit_document(self);
    [super setBoundsOrigin:[self constrainBoundsRect:[self bounds]].origin];
}
- (BOOL)automaticallyAdjustsContentInsets { return _adjustsInsets; }
- (void)setAutomaticallyAdjustsContentInsets:(BOOL)flag { _adjustsInsets = flag; }
- (NSCursor *)documentCursor { return nil; }
- (void)setDocumentCursor:(NSCursor *)cursor {}

- (void)drawRect:(NSRect)rect
{
    if (!_drawsBackground)
        return;
    [[self backgroundColor] setFill];
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
}

#pragma mark - The document view

- (__kindof NSView *)documentView { return _documentView; }

static void
reflect(NSClipView *self)
{
    NSView *sv = [self superview];
    if ([sv isKindOfClass:[NSScrollView class]])
        [(NSScrollView *)sv reflectScrolledClipView:self];
}

- (void)setDocumentView:(NSView *)view
{
    if (view == _documentView)
        return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_documentView) {
        [nc removeObserver:self name:NSViewFrameDidChangeNotification object:_documentView];
        [nc removeObserver:self name:NSViewBoundsDidChangeNotification object:_documentView];
        NSView *old = _documentView;
        _documentView = nil;
        [old removeFromSuperview];
    }
    _documentView = view;
    if (view) {
        [self addSubview:view];
        [view setPostsFrameChangedNotifications:YES];
        [nc addObserver:self selector:@selector(viewFrameChanged:) name:NSViewFrameDidChangeNotification object:view];
        [nc addObserver:self selector:@selector(viewBoundsChanged:) name:NSViewBoundsDidChangeNotification object:view];
        /* Show the document from its origin: its frame's origin is the start, flipped or not. */
        NSPoint o = [view frame].origin;
        [super setBoundsOrigin:[self constrainBoundsRect:NSMakeRect(o.x - _insets.left,
                                                                    o.y - ([self isFlipped] ? _insets.top : _insets.bottom),
                                                                    NSWidth([self bounds]), NSHeight([self bounds]))]
                                   .origin];
    }
    [self setNeedsDisplay:YES];
    reflect(self);
}

- (void)willRemoveSubview:(NSView *)subview
{
    if (subview == _documentView) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc removeObserver:self name:NSViewFrameDidChangeNotification object:_documentView];
        [nc removeObserver:self name:NSViewBoundsDidChangeNotification object:_documentView];
        _documentView = nil;
    }
    [super willRemoveSubview:subview];
}

- (void)viewFrameChanged:(NSNotification *)note
{
    [super setBoundsOrigin:[self constrainBoundsRect:[self bounds]].origin];
    [self setNeedsDisplay:YES];
    reflect(self);
}

- (void)viewBoundsChanged:(NSNotification *)note
{
    reflect(self);
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    fit_document(self);
    if (_documentView)
        [super setBoundsOrigin:[self constrainBoundsRect:[self bounds]].origin];
    reflect(self);
}

- (NSRect)documentRect
{
    if (!_documentView)
        return NSZeroRect;
    NSRect r = [_documentView frame];
    NSSize b = [self bounds].size;
    r.size.width = MAX(r.size.width, b.width);
    r.size.height = MAX(r.size.height, b.height);
    return r;
}

- (NSRect)documentVisibleRect
{
    if (!_documentView)
        return NSZeroRect;
    return [_documentView convertRect:[self bounds] fromView:self];
}

#pragma mark - Scrolling

static CGFloat
clamp_axis(CGFloat v, CGFloat lo, CGFloat hi)
{
    if (hi < lo)
        return lo;
    return MAX(lo, MIN(v, hi));
}

- (NSRect)constrainBoundsRect:(NSRect)r
{
    if (!_documentView)
        return r;
    NSRect d = [_documentView frame];
    BOOL flipped = [self isFlipped];
    CGFloat before = flipped ? _insets.top : _insets.bottom, after = flipped ? _insets.bottom : _insets.top;
    r.origin.x = clamp_axis(r.origin.x, NSMinX(d) - _insets.left, NSMaxX(d) + _insets.right - r.size.width);
    r.origin.y = clamp_axis(r.origin.y, NSMinY(d) - before, NSMaxY(d) + after - r.size.height);
    return r;
}

- (NSPoint)constrainScrollPoint:(NSPoint)point
{
    NSRect b = [self bounds];
    b.origin = point;
    return [self constrainBoundsRect:b].origin;
}

- (void)setBoundsOrigin:(NSPoint)origin
{
    NSRect b = [self bounds];
    b.origin = origin;
    [super setBoundsOrigin:[self constrainBoundsRect:b].origin];
    reflect(self);
}

- (void)scrollToPoint:(NSPoint)point
{
    [super setBoundsOrigin:point];
    reflect(self);
}

- (BOOL)autoscroll:(NSEvent *)event
{
    if (!event || !_documentView)
        return NO;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSRect b = [self bounds];
    if (NSPointInRect(p, b))
        return NO;
    NSPoint o = b.origin;
    if (p.x < NSMinX(b))
        o.x -= NSMinX(b) - p.x;
    else if (p.x > NSMaxX(b))
        o.x += p.x - NSMaxX(b);
    if (p.y < NSMinY(b))
        o.y -= NSMinY(b) - p.y;
    else if (p.y > NSMaxY(b))
        o.y += p.y - NSMaxY(b);
    NSPoint c = [self constrainScrollPoint:o];
    if (NSEqualPoints(c, b.origin))
        return NO;
    [self scrollToPoint:c];
    return YES;
}

- (void)scrollWheel:(NSEvent *)event
{
    [[self superview] scrollWheel:event];
}

- (BOOL)acceptsFirstResponder { return NO; }

#pragma mark - Archiving

enum { CV_NO_COPY_ON_SCROLL = 1 << 1, CV_DRAWS_BACKGROUND = 1 << 2 };

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    clip_init(self);
    int flags = [coder decodeIntForKey:@"NScvFlags"];
    _drawsBackground = (flags & CV_DRAWS_BACKGROUND) != 0;
    _copiesOnScroll = !(flags & CV_NO_COPY_ON_SCROLL);
    _backgroundColor = [[coder decodeObjectForKey:@"NSBGColor"] retain];
    if ([coder containsValueForKey:@"NSAutomaticallyAdjustsContentInsets"])
        _adjustsInsets = [coder decodeBoolForKey:@"NSAutomaticallyAdjustsContentInsets"];
    NSView *doc = [coder decodeObjectForKey:@"NSDocView"];
    if (doc) {
        _documentView = doc;
        [doc setPostsFrameChangedNotifications:YES];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(viewFrameChanged:) name:NSViewFrameDidChangeNotification object:doc];
        [nc addObserver:self selector:@selector(viewBoundsChanged:) name:NSViewBoundsDidChangeNotification object:doc];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    int flags = (_drawsBackground ? CV_DRAWS_BACKGROUND : 0) | (_copiesOnScroll ? 0 : CV_NO_COPY_ON_SCROLL);
    if (flags)
        [coder encodeInt:flags forKey:@"NScvFlags"];
    if (_documentView)
        [coder encodeObject:_documentView forKey:@"NSDocView"];
    if (_backgroundColor)
        [coder encodeObject:_backgroundColor forKey:@"NSBGColor"];
    [coder encodeBool:_adjustsInsets forKey:@"NSAutomaticallyAdjustsContentInsets"];
}

@end
