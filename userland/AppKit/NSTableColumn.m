/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTableColumn and NSTableHeaderCell.
 *
 * A column has an identifier, a width held between its minimum and maximum,
 * a resizing mask, a header cell showing its title and a data cell that
 * cell-based tables draw its rows with. As measured on macOS 26.4: columns
 * start 100 wide, at least 10, at most FLT_MAX, resizable both ways, with a
 * text header cell titled "Field" (natural alignment, truncating its tail)
 * and an editable, selectable text data cell; setting the width clamps it to
 * the minimum and maximum (a minimum above the width raises it, a maximum
 * below lowers it), and a table posts NSTableViewColumnDidResizeNotification
 * with the old width when one of its columns changes width.
 *
 * Bindings: "value" (a cell-based column's values, "arrangedObjects.key" of
 * an array controller; the table then binds its content, selection indexes
 * and sort descriptors to the same controller, and the column takes a sort
 * descriptor prototype for the key), and the column's width, minWidth,
 * maxWidth, headerTitle, editable and hidden through key-value coding.
 *
 * Nib keys: NSIdentifier, NSWidth, NSMinWidth, NSMaxWidth, NSHeaderCell,
 * NSDataCell, NSResizingMask, NSIsResizeable, NSIsEditable, NSHidden,
 * NSTableView, NSHeaderToolTip, NSSortDescriptorPrototype.
 */
#import "NSTableView_Finch.h"
#import "NSKeyValueBinding_Finch.h"

@implementation NSTableColumn {
    NSUserInterfaceItemIdentifier _identifier;
    NSTableView *_tableView; /* not retained */
    CGFloat _width, _minWidth, _maxWidth;
    NSTableColumnResizingOptions _resizingMask;
    NSCell *_headerCell, *_dataCell;
    NSString *_headerToolTip;
    NSSortDescriptor *_sortPrototype;
    BOOL _editable, _hidden;
}

static void
column_init(NSTableColumn *self)
{
    self->_width = 100;
    self->_minWidth = 10;
    self->_maxWidth = FLT_MAX;
    self->_resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    self->_editable = YES;
}

static NSCell *
default_header_cell(void)
{
    NSTableHeaderCell *h = [[NSTableHeaderCell alloc] initTextCell:@"Field"];
    [h setAlignment:NSTextAlignmentNatural];
    [h setLineBreakMode:NSLineBreakByTruncatingTail];
    return h;
}

static NSCell *
default_data_cell(void)
{
    NSTextFieldCell *c = [[NSTextFieldCell alloc] initTextCell:@"Field"];
    [c setEditable:YES];
    [c setLineBreakMode:NSLineBreakByTruncatingTail];
    [c setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
    return c;
}

- (instancetype)initWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    self = [super init];
    if (!self)
        return nil;
    column_init(self);
    _identifier = [identifier copy];
    _headerCell = default_header_cell();
    _dataCell = default_data_cell();
    return self;
}

- (instancetype)init
{
    return [self initWithIdentifier:@""];
}

- (void)dealloc
{
    [_identifier release];
    [_headerCell release];
    [_dataCell release];
    [_headerToolTip release];
    [_sortPrototype release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> identifier: %@ width: %g", [self class], self, _identifier, _width];
}

#pragma mark Properties

- (NSUserInterfaceItemIdentifier)identifier { return _identifier; }

- (void)setIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    [_identifier autorelease];
    _identifier = [identifier copy];
}

- (NSTableView *)tableView { return _tableView; }
- (void)setTableView:(NSTableView *)tableView { _tableView = tableView; }
- (void)_finchSetTableView:(NSTableView *)table { _tableView = table; }

- (CGFloat)width { return _width; }

static CGFloat
clamp_width(NSTableColumn *self, CGFloat w)
{
    if (w > self->_maxWidth)
        w = self->_maxWidth;
    if (w < self->_minWidth)
        w = self->_minWidth;
    return w;
}

- (void)_finchSetWidthQuietly:(CGFloat)width
{
    [self willChangeValueForKey:@"width"];
    _width = clamp_width(self, width);
    [self didChangeValueForKey:@"width"];
}

- (void)setWidth:(CGFloat)width
{
    CGFloat w = clamp_width(self, width);
    if (w == _width)
        return;
    CGFloat old = _width;
    [self _finchSetWidthQuietly:w];
    [_tableView _finchColumnChanged:self oldWidth:old];
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    return [key isEqualToString:@"width"] ? NO : [super automaticallyNotifiesObserversForKey:key];
}

- (CGFloat)minWidth { return _minWidth; }

- (void)setMinWidth:(CGFloat)minWidth
{
    _minWidth = minWidth;
    if (_width < minWidth)
        [self setWidth:minWidth];
}

- (CGFloat)maxWidth { return _maxWidth; }

- (void)setMaxWidth:(CGFloat)maxWidth
{
    _maxWidth = maxWidth;
    if (_width > maxWidth)
        [self setWidth:maxWidth];
}

- (NSTableColumnResizingOptions)resizingMask { return _resizingMask; }
- (void)setResizingMask:(NSTableColumnResizingOptions)mask { _resizingMask = mask; }
- (BOOL)isResizable { return _resizingMask != 0; }

- (void)setResizable:(BOOL)flag
{
    _resizingMask = flag ? NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask : NSTableColumnNoResizing;
}

- (BOOL)isEditable { return _editable; }
- (void)setEditable:(BOOL)flag { _editable = flag; }
- (BOOL)isHidden { return _hidden; }

- (void)setHidden:(BOOL)hidden
{
    if (_hidden == hidden)
        return;
    _hidden = hidden;
    [_tableView _finchColumnVisibilityChanged:self];
}

- (NSString *)title { return [_headerCell stringValue]; }

- (void)setTitle:(NSString *)title
{
    [_headerCell setStringValue:title ?: @""];
    [[_tableView headerView] setNeedsDisplay:YES];
}

- (id)headerCell { return _headerCell; }

- (void)setHeaderCell:(NSCell *)cell
{
    if (!cell)
        [NSException raise:NSInvalidArgumentException format:@"-[NSTableColumn setHeaderCell:] nil cell"];
    [_headerCell autorelease];
    _headerCell = [cell retain];
    [[_tableView headerView] setNeedsDisplay:YES];
}

- (id)dataCell { return _dataCell; }

- (void)setDataCell:(NSCell *)cell
{
    if (!cell)
        [NSException raise:NSInvalidArgumentException format:@"-[NSTableColumn setDataCell:] nil cell"];
    [_dataCell autorelease];
    _dataCell = [cell retain];
    [_tableView setNeedsDisplay:YES];
}

- (id)dataCellForRow:(NSInteger)row { return _dataCell; }

- (NSString *)headerToolTip { return _headerToolTip; }

- (void)setHeaderToolTip:(NSString *)tip
{
    [_headerToolTip autorelease];
    _headerToolTip = [tip copy];
}

- (NSSortDescriptor *)sortDescriptorPrototype { return _sortPrototype; }

- (void)setSortDescriptorPrototype:(NSSortDescriptor *)prototype
{
    [_sortPrototype autorelease];
    _sortPrototype = [prototype copy];
}

/* Fit the width to the header's title. */
- (void)sizeToFit
{
    NSSize s = [_headerCell cellSize];
    CGFloat w = ceil(s.width);
    if (w < _minWidth)
        _minWidth = w;
    [self setWidth:w];
}

#pragma mark Archiving

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (!self)
        return nil;
    column_init(self);
    _identifier = [[coder decodeObjectForKey:@"NSIdentifier"] copy];
    if ([coder containsValueForKey:@"NSWidth"])
        _width = [coder decodeDoubleForKey:@"NSWidth"];
    if ([coder containsValueForKey:@"NSMinWidth"])
        _minWidth = [coder decodeDoubleForKey:@"NSMinWidth"];
    if ([coder containsValueForKey:@"NSMaxWidth"])
        _maxWidth = [coder decodeDoubleForKey:@"NSMaxWidth"];
    _headerCell = [[coder decodeObjectForKey:@"NSHeaderCell"] retain] ?: default_header_cell();
    _dataCell = [[coder decodeObjectForKey:@"NSDataCell"] retain] ?: default_data_cell();
    if ([coder containsValueForKey:@"NSResizingMask"])
        _resizingMask = [coder decodeIntegerForKey:@"NSResizingMask"];
    else if ([coder containsValueForKey:@"NSIsResizeable"])
        [self setResizable:[coder decodeBoolForKey:@"NSIsResizeable"]];
    _editable = [coder decodeBoolForKey:@"NSIsEditable"];
    _hidden = [coder decodeBoolForKey:@"NSHidden"];
    _tableView = [coder decodeObjectForKey:@"NSTableView"];
    _headerToolTip = [[coder decodeObjectForKey:@"NSHeaderToolTip"] copy];
    _sortPrototype = [[coder decodeObjectForKey:@"NSSortDescriptorPrototype"] copy];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_identifier)
        [coder encodeObject:_identifier forKey:@"NSIdentifier"];
    [coder encodeDouble:_width forKey:@"NSWidth"];
    [coder encodeDouble:_minWidth forKey:@"NSMinWidth"];
    [coder encodeDouble:_maxWidth forKey:@"NSMaxWidth"];
    [coder encodeObject:_headerCell forKey:@"NSHeaderCell"];
    [coder encodeObject:_dataCell forKey:@"NSDataCell"];
    [coder encodeInteger:_resizingMask forKey:@"NSResizingMask"];
    [coder encodeBool:_resizingMask != 0 forKey:@"NSIsResizeable"];
    if (_editable)
        [coder encodeBool:YES forKey:@"NSIsEditable"];
    if (_hidden)
        [coder encodeBool:YES forKey:@"NSHidden"];
    if (_tableView)
        [coder encodeConditionalObject:_tableView forKey:@"NSTableView"];
    if (_headerToolTip)
        [coder encodeObject:_headerToolTip forKey:@"NSHeaderToolTip"];
    if (_sortPrototype)
        [coder encodeObject:_sortPrototype forKey:@"NSSortDescriptorPrototype"];
}

#pragma mark Bindings

+ (NSArray *)_finchBuiltinBindings
{
    return @[
        @"displayPatternValue1", NSEditableBinding, NSEnabledBinding, NSFontBinding, NSFontBoldBinding,
        NSFontFamilyNameBinding, NSFontItalicBinding, NSFontNameBinding, NSFontSizeBinding, NSHeaderTitleBinding,
        NSMaxWidthBinding, NSMinWidthBinding, NSTextColorBinding, NSValueBinding, NSWidthBinding
    ];
}

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqualToString:NSValueBinding] || [binding isEqualToString:NSHeaderTitleBinding] ||
           [binding isEqualToString:NSEnabledBinding] || [binding isEqualToString:NSFontBinding] ||
           [binding isEqualToString:NSTextColorBinding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSValueBinding] || [binding isEqualToString:NSHeaderTitleBinding])
        return [NSString class];
    if ([binding isEqualToString:NSWidthBinding] || [binding isEqualToString:NSMinWidthBinding] ||
        [binding isEqualToString:NSMaxWidthBinding] || [binding isEqualToString:NSEditableBinding] ||
        [binding isEqualToString:NSEnabledBinding])
        return [NSNumber class];
    if ([binding isEqualToString:NSFontBinding])
        return [NSFont class];
    if ([binding isEqualToString:NSTextColorBinding])
        return [NSColor class];
    return [super _finchValueClassForBinding:binding];
}

/* "arrangedObjects.name": the content's key path and the key in each object. */
static void
split_value_path(NSString *keyPath, NSString **content, NSString **key)
{
    NSRange dot = [keyPath rangeOfString:@"."];
    if (dot.location == NSNotFound) {
        *content = keyPath;
        *key = nil;
        return;
    }
    *content = [keyPath substringToIndex:dot.location];
    *key = [keyPath substringFromIndex:NSMaxRange(dot)];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    NSString *name = b->_name;
    if ([name isEqualToString:NSValueBinding]) {
        NSString *content, *key;
        split_value_path(b->_keyPath, &content, &key);
        if (!_sortPrototype && key)
            _sortPrototype = [[NSSortDescriptor alloc] initWithKey:key ascending:YES selector:@selector(compare:)];
        NSTableView *t = _tableView;
        if (t && !FinchBindingFor(t, NSContentBinding)) {
            [t bind:NSContentBinding toObject:b->_observed withKeyPath:content options:nil];
            if ([b->_observed isKindOfClass:[NSArrayController class]]) {
                if (!FinchBindingFor(t, NSSelectionIndexesBinding))
                    [t bind:NSSelectionIndexesBinding toObject:b->_observed withKeyPath:@"selectionIndexes" options:nil];
                if (!FinchBindingFor(t, NSSortDescriptorsBinding))
                    [t bind:NSSortDescriptorsBinding toObject:b->_observed withKeyPath:@"sortDescriptors" options:nil];
            }
        }
        [t _finchRowsChanged];
        return;
    }
    if ([name isEqualToString:NSHeaderTitleBinding]) {
        id v = [b displayValueWithKind:NULL];
        [self setTitle:[v isKindOfClass:[NSString class]] ? v : [v description]];
        return;
    }
    if ([name isEqualToString:NSEnabledBinding] || [name isEqualToString:NSFontBinding] ||
        [name isEqualToString:NSTextColorBinding]) {
        [_tableView setNeedsDisplay:YES];
        return;
    }
    [super _finchBindingChanged:b];
}

/* The value a cell-based column's binding gives a row: the row's object's value for the key. */
- (id)_finchBoundValueAtRow:(NSInteger)row object:(id)object
{
    _FinchBinding *b = FinchBindingFor(self, NSValueBinding);
    if (!b)
        return nil;
    NSString *content, *key;
    split_value_path(b->_keyPath, &content, &key);
    id v = object;
    if (!v) {
        id all = [b->_observed valueForKeyPath:content];
        if (![all respondsToSelector:@selector(objectAtIndex:)] || row < 0 || (NSUInteger)row >= [all count])
            return nil;
        v = [all objectAtIndex:row];
    }
    if (key)
        v = [v valueForKeyPath:key];
    if (b->_transformer)
        v = [b->_transformer transformedValue:v];
    return v;
}

/* The user edited a row: through the binding to the row's object. */
- (void)_finchPushBoundValue:(id)value atRow:(NSInteger)row
{
    _FinchBinding *b = FinchBindingFor(self, NSValueBinding);
    if (!b)
        return;
    NSString *content, *key;
    split_value_path(b->_keyPath, &content, &key);
    id all = [b->_observed valueForKeyPath:content];
    if (!key || row < 0 || (NSUInteger)row >= [all count])
        return;
    if (b->_transformer && [[b->_transformer class] allowsReverseTransformation])
        value = [b->_transformer reverseTransformedValue:value];
    [[all objectAtIndex:row] setValue:value forKeyPath:key];
}

- (BOOL)_finchHasValueBinding { return FinchBindingFor(self, NSValueBinding) != nil; }

@end

#pragma mark - NSTableHeaderCell

/*
 * A header cell: the column's title over Finch's header background, with a
 * separator on its trailing edge, the sort indicator when its column sorts
 * the table, and a darker background while pressed.
 */
@implementation NSTableHeaderCell

- (instancetype)initTextCell:(NSString *)string
{
    self = [super initTextCell:string];
    if (self) {
        [self setTextColor:[NSColor headerTextColor]];
        [self setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    }
    return self;
}

- (NSRect)sortIndicatorRectForBounds:(NSRect)rect
{
    return NSMakeRect(NSMaxX(rect) - 15, NSMidY(rect) - 4, 9, 8);
}

- (void)drawSortIndicatorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView ascending:(BOOL)ascending
                          priority:(NSInteger)priority
{
    if (priority != 0)
        return;
    NSRect r = [self sortIndicatorRectForBounds:cellFrame];
    BOOL flipped = [controlView isFlipped];
    /* a chevron: up for ascending */
    BOOL up = ascending != flipped;
    NSBezierPath *p = [NSBezierPath bezierPath];
    CGFloat yTip = up ? NSMaxY(r) - 1.5 : NSMinY(r) + 1.5, yBase = up ? NSMinY(r) + 2 : NSMaxY(r) - 2;
    [p moveToPoint:NSMakePoint(NSMinX(r) + 1, yBase)];
    [p lineToPoint:NSMakePoint(NSMidX(r), yTip)];
    [p lineToPoint:NSMakePoint(NSMaxX(r) - 1, yBase)];
    [p setLineWidth:1.5];
    [p setLineCapStyle:NSLineCapStyleRound];
    [p setLineJoinStyle:NSLineJoinStyleRound];
    [[NSColor secondaryLabelColor] setStroke];
    [p stroke];
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    [([self isHighlighted] ? [NSColor colorWithWhite:0.88 alpha:1] : [NSColor colorWithWhite:0.97 alpha:1]) setFill];
    NSRectFill(frame);
    [[NSColor colorWithWhite:0.85 alpha:1] setFill];
    NSRectFill(NSMakeRect(NSMaxX(frame) - 1, NSMinY(frame) + 4, 1, MAX(0, NSHeight(frame) - 8)));
    [self drawInteriorWithFrame:frame inView:controlView];
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    NSRect r = NSInsetRect(frame, 4, 0);
    FinchDrawCellText([self attributedStringValue], r, [controlView isFlipped]);
}

@end
