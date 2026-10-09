/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTableHeaderView: the column titles above a table, and its place in a
 * scroll view.
 *
 * The header lines its columns' header cells up with the table's columns,
 * draws the sort indicator of the column the table sorts by, sorts (or
 * selects the column) on a click and resizes a column dragged by its
 * trailing edge. As on macOS 26.4, a scroll view puts a table's header in a
 * clip view of its own across the top of the scroll view, over the content
 * clip view (which still fills the scroll view), and adds the header's
 * height to the content clip view's top inset, so the table's top row
 * starts below it; the header's clip view follows the content horizontally.
 *
 * Nib keys: NSTableView. A scroll view archives the header's clip view as
 * one of its subviews (and NSHeaderClipView).
 */
#import "NSTableView_Finch.h"

@implementation NSTableHeaderView {
    NSTableView *_tableView; /* not retained */
    NSInteger _pressed, _resized, _dragged;
    CGFloat _draggedDistance;
}

static void
header_init(NSTableHeaderView *self)
{
    self->_pressed = self->_resized = self->_dragged = -1;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        header_init(self);
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        header_init(self);
        _tableView = [coder decodeObjectForKey:@"NSTableView"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_tableView)
        [coder encodeConditionalObject:_tableView forKey:@"NSTableView"];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (NSTableView *)tableView { return _tableView; }

- (void)setTableView:(NSTableView *)tableView
{
    _tableView = tableView;
    [self setNeedsDisplay:YES];
}

- (NSInteger)draggedColumn { return _dragged; }
- (CGFloat)draggedDistance { return _draggedDistance; }
- (NSInteger)resizedColumn { return _resized; }
- (void)_finchSetPressedColumn:(NSInteger)column
{
    _pressed = column;
    [self setNeedsDisplay:YES];
}

- (NSRect)headerRectOfColumn:(NSInteger)column
{
    NSRect r = [_tableView rectOfColumn:column];
    if (NSIsEmptyRect(r))
        return NSZeroRect;
    return NSMakeRect(NSMinX(r), 0, NSWidth(r), NSHeight([self bounds]));
}

- (NSInteger)columnAtPoint:(NSPoint)point
{
    if (point.y < 0 || point.y >= NSHeight([self bounds]))
        return -1;
    return [_tableView columnAtPoint:NSMakePoint(point.x, 0)];
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    [[NSColor colorWithWhite:0.97 alpha:1] setFill];
    NSRectFill(dirty);
    NSArray *cols = [_tableView tableColumns];
    NSSortDescriptor *sort = [[_tableView sortDescriptors] firstObject];
    NSIndexSet *selected = [_tableView selectedColumnIndexes];
    for (NSInteger i = 0; i < (NSInteger)[cols count]; i++) {
        NSRect r = [self headerRectOfColumn:i];
        if (NSIsEmptyRect(r) || !NSIntersectsRect(r, dirty))
            continue;
        NSTableColumn *c = [cols objectAtIndex:i];
        NSCell *cell = [c headerCell];
        BOOL hl = i == _pressed || [selected containsIndex:i];
        [cell setHighlighted:hl];
        [cell drawWithFrame:r inView:self];
        [cell setHighlighted:NO];
        NSImage *indicator = [_tableView indicatorImageInTableColumn:c];
        if (indicator) {
            NSSize s = [indicator size];
            NSRect ir = NSMakeRect(NSMaxX(r) - s.width - 6, NSMidY(r) - s.height / 2, s.width, s.height);
            [indicator drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
                   respectFlipped:YES hints:nil];
        } else if (sort && [[[c sortDescriptorPrototype] key] isEqualToString:[sort key]] &&
                   [cell respondsToSelector:@selector(drawSortIndicatorWithFrame:inView:ascending:priority:)]) {
            [(NSTableHeaderCell *)cell drawSortIndicatorWithFrame:r inView:self ascending:[sort ascending] priority:0];
        }
    }
    [[NSColor colorWithWhite:0.85 alpha:1] setFill];
    CGFloat px = 1 / MAX(1, FinchViewBackingScale(self));
    NSRectFill(NSIntersectionRect(dirty, NSMakeRect(NSMinX(b), NSMaxY(b) - px, NSWidth(b), px)));
}

/* The column whose trailing edge is under the point (for resizing), or -1. */
- (NSInteger)_finchResizableColumnAt:(NSPoint)p
{
    NSArray *cols = [_tableView tableColumns];
    for (NSInteger i = 0; i < (NSInteger)[cols count]; i++) {
        NSRect r = [self headerRectOfColumn:i];
        if (NSIsEmptyRect(r))
            continue;
        if (fabs(p.x - NSMaxX(r)) <= 3 && ([[cols objectAtIndex:i] resizingMask] & NSTableColumnUserResizingMask) &&
            [_tableView allowsColumnResizing])
            return i;
    }
    return -1;
}

- (void)mouseDown:(NSEvent *)event
{
    NSWindow *w = [self window];
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger edge = [self _finchResizableColumnAt:p];
    if (edge >= 0) {
        NSTableColumn *c = [[_tableView tableColumns] objectAtIndex:edge];
        CGFloat start = p.x, width = [c width];
        _resized = edge;
        for (;;) {
            NSEvent *e = [w nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
            if (!e || [e type] == NSEventTypeLeftMouseUp)
                break;
            NSPoint q = [self convertPoint:[e locationInWindow] fromView:nil];
            [_tableView _finchResizeColumn:edge toWidth:width + q.x - start];
            [w displayIfNeeded];
        }
        _resized = -1;
        return;
    }
    NSInteger col = [self columnAtPoint:p];
    if (col < 0)
        return;
    [self _finchSetPressedColumn:col];
    [w displayIfNeeded];
    BOOL inside = YES;
    for (;;) {
        NSEvent *e = [w nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        if (!e)
            break;
        NSPoint q = [self convertPoint:[e locationInWindow] fromView:nil];
        inside = [self columnAtPoint:q] == col;
        if ([e type] == NSEventTypeLeftMouseUp)
            break;
        [self _finchSetPressedColumn:inside ? col : -1];
        [w displayIfNeeded];
    }
    [self _finchSetPressedColumn:-1];
    if (inside)
        [_tableView _finchHeaderClickedColumn:col event:event];
}

@end

#pragma mark - In a scroll view

static char headerClipKey;

static NSClipView *
header_clip(NSScrollView *sv)
{
    NSClipView *hc = objc_getAssociatedObject(sv, &headerClipKey);
    if (hc && [hc superview] == sv)
        return hc;
    /* one from a nib: a clip view, not the content view, showing a header */
    for (NSView *v in [sv subviews])
        if ([v isKindOfClass:[NSClipView class]] && v != [sv contentView] &&
            [[(NSClipView *)v documentView] isKindOfClass:[NSTableHeaderView class]]) {
            objc_setAssociatedObject(sv, &headerClipKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return (NSClipView *)v;
        }
    return nil;
}

void
FinchScrollViewTileHeader(NSScrollView *sv, NSRect inner, NSEdgeInsets rulers, BOOL setInsets)
{
    NSView *doc = [sv documentView];
    NSTableHeaderView *h = [doc isKindOfClass:[NSTableView class]] ? [(NSTableView *)doc headerView] : nil;
    NSClipView *hc = header_clip(sv);
    NSClipView *content = [sv contentView];
    CGFloat height = 0;
    if (h) {
        if (!hc) {
            hc = [[[NSClipView alloc] initWithFrame:NSZeroRect] autorelease];
            [hc setDrawsBackground:NO];
            [sv addSubview:hc positioned:NSWindowAbove relativeTo:content];
            objc_setAssociatedObject(sv, &headerClipKey, hc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if ([hc documentView] != h)
            [hc setDocumentView:h];
        height = NSHeight([h frame]);
        [hc setFrame:NSMakeRect(NSMinX(inner), NSMinY(inner), NSWidth(inner), height)];
        [hc setHidden:NO];
    } else if (hc) {
        [hc removeFromSuperview];
        objc_setAssociatedObject(sv, &headerClipKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!setInsets) {
        return;
    }
    {
        NSEdgeInsets in = [sv contentInsets];
        in.top += height + rulers.top;
        in.left += rulers.left;
        NSEdgeInsets cur = [content contentInsets];
        if (cur.top != in.top || cur.left != in.left || cur.bottom != in.bottom || cur.right != in.right) {
            /* the content moves with its inset, as Apple's does (then is held to the document) */
            /* content at the top stays at the top as the inset changes, as Apple's does */
            NSPoint o = [content bounds].origin;
            if (o.x == -cur.left)
                o.x = -in.left;
            if (o.y == -cur.top)
                o.y = -in.top;
            [content setContentInsets:in];
            [content setBoundsOrigin:o];
        }
    }
    if ([doc isKindOfClass:[NSTableView class]])
        [(NSTableView *)doc tile];
    FinchScrollViewReflectHeader(sv);
}

void
FinchScrollViewReflectHeader(NSScrollView *sv)
{
    NSClipView *hc = objc_getAssociatedObject(sv, &headerClipKey);
    if (!hc || [hc superview] != sv)
        return;
    NSPoint o = [hc bounds].origin;
    CGFloat x = [[sv contentView] bounds].origin.x;
    if (o.x != x)
        [hc scrollToPoint:NSMakePoint(x, o.y)];
}
