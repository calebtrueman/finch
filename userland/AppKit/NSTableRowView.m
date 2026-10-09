/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTableRowView and NSTableCellView: the views of a view-based table.
 *
 * A row view holds a row's cell views (one per column, or one across a
 * group row) and draws the row's background, its selection and its
 * separator. As measured on macOS 26.4: a row view starts unselected, not
 * emphasized, with the regular highlight style and no background colour;
 * its interior background style is emphasized only while it is selected and
 * emphasized (the table emphasizes rows while it is the key window's first
 * responder). A cell view is not flipped, holds an object value (which its
 * subviews bind to, "objectValue.name") and outlets to a text field and an
 * image view, and passes its background style on to their cells.
 */
#import "NSTableView_Finch.h"

@implementation NSTableRowView {
    NSTableView *_tableView; /* not retained */
    NSInteger _row;
    NSArray *_cellViews;
    NSColor *_backgroundColor;
    NSTableViewSelectionHighlightStyle _highlightStyle;
    NSTableViewDraggingDestinationFeedbackStyle _dragStyle;
    CGFloat _dropIndentation;
    struct {
        unsigned selected : 1;
        unsigned emphasized : 1;
        unsigned group : 1;
        unsigned floating : 1;
        unsigned target : 1;
        unsigned nextSelected : 1;
        unsigned previousSelected : 1;
    } _r;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        _row = -1;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder]))
        _row = -1;
    return self;
}

- (void)dealloc
{
    [_cellViews release];
    [_backgroundColor release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }

- (void)_finchSetTableView:(NSTableView *)table row:(NSInteger)row
{
    _tableView = table;
    _row = row;
}

- (NSInteger)_finchRow { return _row; }
- (void)_finchSetRow:(NSInteger)row { _row = row; }
- (NSArray *)_finchCellViews { return _cellViews ?: @[]; }

- (void)_finchSetCellViews:(NSArray *)views
{
    [_cellViews autorelease];
    _cellViews = [views copy];
}

- (NSInteger)numberOfColumns { return (NSInteger)[_cellViews count]; }

- (id)viewAtColumn:(NSInteger)column
{
    if (column < 0 || column >= (NSInteger)[_cellViews count])
        return nil;
    id v = [_cellViews objectAtIndex:column];
    return v == [NSNull null] ? nil : v;
}

static void
update_interiors(NSTableRowView *self)
{
    NSBackgroundStyle s = [self interiorBackgroundStyle];
    for (id v in self->_cellViews)
        if (v != [NSNull null] && [v respondsToSelector:@selector(setBackgroundStyle:)])
            [v setBackgroundStyle:s];
    [self setNeedsDisplay:YES];
}

- (BOOL)isSelected { return _r.selected; }

- (void)setSelected:(BOOL)flag
{
    if (_r.selected == (unsigned)flag)
        return;
    _r.selected = flag;
    update_interiors(self);
}

- (BOOL)isEmphasized { return _r.emphasized; }

- (void)setEmphasized:(BOOL)flag
{
    if (_r.emphasized == (unsigned)flag)
        return;
    _r.emphasized = flag;
    update_interiors(self);
}

- (BOOL)isGroupRowStyle { return _r.group; }
- (void)setGroupRowStyle:(BOOL)flag { _r.group = flag; [self setNeedsDisplay:YES]; }
- (BOOL)isFloating { return _r.floating; }
- (void)setFloating:(BOOL)flag { _r.floating = flag; }
- (BOOL)isTargetForDropOperation { return _r.target; }
- (void)setTargetForDropOperation:(BOOL)flag { _r.target = flag; [self setNeedsDisplay:YES]; }
- (BOOL)isNextRowSelected { return _r.nextSelected; }
- (void)setNextRowSelected:(BOOL)flag { _r.nextSelected = flag; [self setNeedsDisplay:YES]; }
- (BOOL)isPreviousRowSelected { return _r.previousSelected; }
- (void)setPreviousRowSelected:(BOOL)flag { _r.previousSelected = flag; [self setNeedsDisplay:YES]; }
- (NSTableViewSelectionHighlightStyle)selectionHighlightStyle { return _highlightStyle; }

- (void)setSelectionHighlightStyle:(NSTableViewSelectionHighlightStyle)style
{
    _highlightStyle = style;
    update_interiors(self);
}

- (NSTableViewDraggingDestinationFeedbackStyle)draggingDestinationFeedbackStyle { return _dragStyle; }
- (void)setDraggingDestinationFeedbackStyle:(NSTableViewDraggingDestinationFeedbackStyle)s { _dragStyle = s; }
- (CGFloat)indentationForDropOperation { return _dropIndentation; }
- (void)setIndentationForDropOperation:(CGFloat)v { _dropIndentation = v; }
- (NSColor *)backgroundColor { return _backgroundColor; }

- (void)setBackgroundColor:(NSColor *)color
{
    [_backgroundColor autorelease];
    _backgroundColor = [color retain];
    [self setNeedsDisplay:YES];
}

- (NSBackgroundStyle)interiorBackgroundStyle
{
    if (_r.selected && _r.emphasized && _highlightStyle != NSTableViewSelectionHighlightStyleNone)
        return NSBackgroundStyleEmphasized;
    return NSBackgroundStyleNormal;
}

#pragma mark Drawing

- (void)drawBackgroundInRect:(NSRect)dirty
{
    if (_backgroundColor) {
        [_backgroundColor setFill];
        NSRectFill(dirty);
    }
    if (_r.group && _tableView && [_tableView effectiveStyle] == NSTableViewStylePlain) {
        [[NSColor colorWithWhite:0.95 alpha:1] setFill];
        NSRectFill(dirty);
    }
}

- (void)drawSelectionInRect:(NSRect)dirty
{
    if (_highlightStyle == NSTableViewSelectionHighlightStyleNone)
        return;
    NSRect b = [self bounds];
    NSTableViewStyle style = _tableView ? [_tableView effectiveStyle] : NSTableViewStyleFullWidth;
    [FinchTableSelectionColor(_r.emphasized) setFill];
    if (style == NSTableViewStyleInset || style == NSTableViewStyleSourceList) {
        NSRect r = NSInsetRect(b, 10, 0);
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5] fill];
        if (_r.previousSelected)
            NSRectFill(NSMakeRect(NSMinX(r), NSMinY(r), NSWidth(r), NSHeight(r) / 2));
        if (_r.nextSelected)
            NSRectFill(NSMakeRect(NSMinX(r), NSMidY(r), NSWidth(r), NSHeight(r) / 2));
    } else {
        NSRectFill(b);
    }
}

- (void)drawSeparatorInRect:(NSRect)dirty
{
    NSTableViewGridLineStyle g = [_tableView gridStyleMask];
    if (!(g & (NSTableViewSolidHorizontalGridLineMask | NSTableViewDashedHorizontalGridLineMask)))
        return;
    NSRect b = [self bounds];
    CGFloat px = 1 / MAX(1, FinchViewBackingScale(self));
    [[_tableView gridColor] setFill];
    NSRectFill(NSMakeRect(NSMinX(b), NSMaxY(b) - px, NSWidth(b), px));
}

- (void)drawDraggingDestinationFeedbackInRect:(NSRect)dirty
{
    [[FinchAccentColor() colorWithAlphaComponent:0.25] setFill];
    NSRectFill([self bounds]);
}

- (void)drawRect:(NSRect)dirty
{
    [self drawBackgroundInRect:dirty];
    if (_r.selected)
        [self drawSelectionInRect:dirty];
    if (_r.target)
        [self drawDraggingDestinationFeedbackInRect:dirty];
    [self drawSeparatorInRect:dirty];
}

@end

#pragma mark - NSTableCellView

@implementation NSTableCellView {
    id _objectValue;
    NSTextField *_textField; /* not retained (a subview) */
    NSImageView *_imageView; /* not retained (a subview) */
    NSBackgroundStyle _backgroundStyle;
    NSTableViewRowSizeStyle _rowSizeStyle;
}

- (void)dealloc
{
    [_objectValue release];
    [super dealloc];
}

- (id)objectValue { return _objectValue; }

- (void)setObjectValue:(id)value
{
    if (value == _objectValue)
        return;
    [_objectValue autorelease];
    _objectValue = [value retain];
}

- (NSTextField *)textField { return _textField; }
- (void)setTextField:(NSTextField *)field { _textField = field; }
- (NSImageView *)imageView { return _imageView; }
- (void)setImageView:(NSImageView *)view { _imageView = view; }
- (NSBackgroundStyle)backgroundStyle { return _backgroundStyle; }

- (void)setBackgroundStyle:(NSBackgroundStyle)style
{
    _backgroundStyle = style;
    for (NSView *v in [self subviews])
        if ([v isKindOfClass:[NSControl class]] && [[(NSControl *)v cell] respondsToSelector:@selector(setBackgroundStyle:)]) {
            [[(NSControl *)v cell] setBackgroundStyle:style];
            [v setNeedsDisplay:YES];
        }
}

- (NSTableViewRowSizeStyle)rowSizeStyle { return _rowSizeStyle; }
- (void)setRowSizeStyle:(NSTableViewRowSizeStyle)style { _rowSizeStyle = style; }

- (NSArray<NSDraggingImageComponent *> *)draggingImageComponents { return @[]; }

@end
