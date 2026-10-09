/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Rows and columns share layout guides. Cells add ordinary constraints, so
 * intrinsic sizes, custom constraints and surrounding layouts work together. */
#import "AppKit_Finch.h"
#include <float.h>

const CGFloat NSGridViewSizeForContent = FLT_MIN;
@interface NSGridRow () {
  @public
    NSGridView *_grid;
    NSMutableArray *_cells;
    NSGridCellPlacement _yp;
    NSGridRowAlignment _alignment;
    CGFloat _height, _top, _bottom;
    BOOL _hidden;
}
@end
@interface NSGridColumn () {
  @public
    NSGridView *_grid;
    NSGridCellPlacement _xp;
    CGFloat _width, _leading, _trailing;
    BOOL _hidden;
}
@end
@interface NSGridCell () {
  @public
    NSGridRow *_row;
    NSGridColumn *_column;
    NSGridCell *_head;
    NSView *_content;
    NSGridCellPlacement _xp, _yp;
    NSGridRowAlignment _alignment;
    NSArray *_custom;
}
@end
static void grid_changed(NSGridView *g)
{
    [g setNeedsUpdateConstraints:YES];
    [g invalidateIntrinsicContentSize];
}
#define GRID_PROP(type, get, set, slot, grid)                                                                          \
    -(type)get                                                                                                         \
    {                                                                                                                  \
        return slot;                                                                                                   \
    }                                                                                                                  \
    -(void)set : (type)v                                                                                               \
    {                                                                                                                  \
        slot = v;                                                                                                      \
        grid_changed(grid);                                                                                            \
    }

@implementation NSGridCell
+ (NSView *)emptyContentView
{
    static NSView *v;
    if (!v)
        v = [[NSView alloc] initWithFrame:NSZeroRect];
    return v;
}
- (NSGridRow *)row
{
    return _row;
}
- (NSGridColumn *)column
{
    return _column;
}
- (NSView *)contentView
{
    return _content;
}
- (void)setContentView:(NSView *)v
{
    if (v == [NSGridCell emptyContentView])
        v = nil;
    if (_content == v)
        return;
    [_content removeFromSuperview];
    [_content release];
    _content = [v retain];
    if (v) {
        [v setTranslatesAutoresizingMaskIntoConstraints:NO];
        [_row->_grid addSubview:v];
    }
    grid_changed(_row ? _row->_grid : nil);
}
GRID_PROP(NSGridCellPlacement, xPlacement, setXPlacement, _xp, _row ? _row->_grid : nil)
GRID_PROP(NSGridCellPlacement, yPlacement, setYPlacement, _yp, _row ? _row->_grid : nil)
GRID_PROP(NSGridRowAlignment, rowAlignment, setRowAlignment, _alignment, _row ? _row->_grid : nil)
- (NSArray *)customPlacementConstraints
{
    return _custom ?: @[];
}
- (void)setCustomPlacementConstraints:(NSArray *)v
{
    [NSLayoutConstraint deactivateConstraints:_custom];
    [_custom release];
    _custom = [v copy];
    grid_changed(_row ? _row->_grid : nil);
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [super init];
    if (self) {
        _row = [c decodeObjectForKey:@"NSGrid_owningRow"];
        _column = [c decodeObjectForKey:@"NSGrid_owningColumn"];
        _head = [c decodeObjectForKey:@"NSGrid_mergeHead"];
        _content = [[c decodeObjectForKey:@"NSGrid_content"] retain];
        _xp = [c decodeIntegerForKey:@"NSGrid_xPlacement"];
        _yp = [c decodeIntegerForKey:@"NSGrid_yPlacement"];
        _alignment = [c decodeIntegerForKey:@"NSGrid_alignment"];
        _custom = [[c decodeObjectForKey:@"NSGrid_customPlacementConstraints"] copy];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeConditionalObject:_row forKey:@"NSGrid_owningRow"];
    [c encodeConditionalObject:_column forKey:@"NSGrid_owningColumn"];
    [c encodeConditionalObject:_head forKey:@"NSGrid_mergeHead"];
    [c encodeObject:_content forKey:@"NSGrid_content"];
    [c encodeInteger:_xp forKey:@"NSGrid_xPlacement"];
    [c encodeInteger:_yp forKey:@"NSGrid_yPlacement"];
    [c encodeInteger:_alignment forKey:@"NSGrid_alignment"];
    [c encodeObject:_custom forKey:@"NSGrid_customPlacementConstraints"];
}
- (void)dealloc
{
    [_content release];
    [_custom release];
    [super dealloc];
}
@end

@implementation NSGridRow
- (instancetype)init
{
    self = [super init];
    if (self) {
        _height = NSGridViewSizeForContent;
        _cells = [NSMutableArray new];
    }
    return self;
}
- (NSGridView *)gridView
{
    return _grid;
}
- (NSInteger)numberOfCells
{
    return [_cells count];
}
- (NSGridCell *)cellAtIndex:(NSInteger)i
{
    NSGridCell *c = _cells[i];
    return c->_head ?: c;
}
GRID_PROP(NSGridCellPlacement, yPlacement, setYPlacement, _yp, _grid)
GRID_PROP(NSGridRowAlignment, rowAlignment, setRowAlignment, _alignment, _grid)
GRID_PROP(CGFloat, height, setHeight, _height, _grid)
GRID_PROP(CGFloat, topPadding, setTopPadding, _top, _grid)
GRID_PROP(CGFloat, bottomPadding, setBottomPadding, _bottom, _grid)
GRID_PROP(BOOL, isHidden, setHidden, _hidden, _grid)
- (void)mergeCellsInRange:(NSRange)r
{
    [_grid mergeCellsInHorizontalRange:r verticalRange:NSMakeRange([_grid indexOfRow:self], 1)];
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [self init];
    if (self) {
        _grid = [c decodeObjectForKey:@"NSGrid_owningGrid"];
        [_cells release];
        _cells = [[c decodeObjectForKey:@"NSGrid_cells"] mutableCopy] ?: [NSMutableArray new];
        _yp = [c decodeIntegerForKey:@"NSGrid_yPlacement"];
        _alignment = [c decodeIntegerForKey:@"NSGrid_alignment"];
        if ([c containsValueForKey:@"NSGrid_height"])
            _height = [c decodeDoubleForKey:@"NSGrid_height"];
        _top = [c decodeDoubleForKey:@"NSGrid_topPadding"];
        _bottom = [c decodeDoubleForKey:@"NSGrid_bottomPadding"];
        _hidden = [c decodeBoolForKey:@"NSGrid_hidden"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeConditionalObject:_grid forKey:@"NSGrid_owningGrid"];
    [c encodeObject:_cells forKey:@"NSGrid_cells"];
    [c encodeInteger:_yp forKey:@"NSGrid_yPlacement"];
    [c encodeInteger:_alignment forKey:@"NSGrid_alignment"];
    [c encodeDouble:_height forKey:@"NSGrid_height"];
    [c encodeDouble:_top forKey:@"NSGrid_topPadding"];
    [c encodeDouble:_bottom forKey:@"NSGrid_bottomPadding"];
    [c encodeBool:_hidden forKey:@"NSGrid_hidden"];
}
- (void)dealloc
{
    for (NSGridCell *c in _cells) {
        c->_row = nil;
        c->_head = nil;
    }
    [_cells release];
    [super dealloc];
}
@end
@implementation NSGridColumn
- (instancetype)init
{
    self = [super init];
    if (self)
        _width = NSGridViewSizeForContent;
    return self;
}
- (NSGridView *)gridView
{
    return _grid;
}
- (NSInteger)numberOfCells
{
    return [_grid numberOfRows];
}
- (NSGridCell *)cellAtIndex:(NSInteger)i
{
    return [_grid cellAtColumnIndex:[_grid indexOfColumn:self] rowIndex:i];
}
GRID_PROP(NSGridCellPlacement, xPlacement, setXPlacement, _xp, _grid)
GRID_PROP(CGFloat, width, setWidth, _width, _grid)
GRID_PROP(CGFloat, leadingPadding, setLeadingPadding, _leading, _grid)
GRID_PROP(CGFloat, trailingPadding, setTrailingPadding, _trailing, _grid)
GRID_PROP(BOOL, isHidden, setHidden, _hidden, _grid)
- (void)mergeCellsInRange:(NSRange)r
{
    [_grid mergeCellsInHorizontalRange:NSMakeRange([_grid indexOfColumn:self], 1) verticalRange:r];
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [self init];
    if (self) {
        _grid = [c decodeObjectForKey:@"NSGrid_owningGrid"];
        _xp = [c decodeIntegerForKey:@"NSGrid_xPlacement"];
        if ([c containsValueForKey:@"NSGrid_width"])
            _width = [c decodeDoubleForKey:@"NSGrid_width"];
        _leading = [c decodeDoubleForKey:@"NSGrid_leadingPadding"];
        _trailing = [c decodeDoubleForKey:@"NSGrid_trailingPadding"];
        _hidden = [c decodeBoolForKey:@"NSGrid_hidden"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeConditionalObject:_grid forKey:@"NSGrid_owningGrid"];
    [c encodeInteger:_xp forKey:@"NSGrid_xPlacement"];
    [c encodeDouble:_width forKey:@"NSGrid_width"];
    [c encodeDouble:_leading forKey:@"NSGrid_leadingPadding"];
    [c encodeDouble:_trailing forKey:@"NSGrid_trailingPadding"];
    [c encodeBool:_hidden forKey:@"NSGrid_hidden"];
}
@end

@implementation NSGridView {
    NSMutableArray *_rows, *_columns, *_made, *_guides;
    NSGridCellPlacement _xp, _yp;
    NSGridRowAlignment _alignment;
    CGFloat _rowSpacing, _columnSpacing;
}
+ (BOOL)requiresConstraintBasedLayout
{
    return YES;
}
- (void)_finchSetup
{
    _rows = [NSMutableArray new];
    _columns = [NSMutableArray new];
    _made = [NSMutableArray new];
    _guides = [NSMutableArray new];
    _xp = _yp = NSGridCellPlacementLeading;
    _alignment = NSGridRowAlignmentNone;
    _rowSpacing = _columnSpacing = 6;
    for (int a = 0; a < 2; a++) {
        [self setContentHuggingPriority:249 forOrientation:a];
        [self setContentCompressionResistancePriority:1000 forOrientation:a];
    }
}
- (instancetype)initWithFrame:(NSRect)f
{
    self = [super initWithFrame:f];
    if (self)
        [self _finchSetup];
    return self;
}
+ (instancetype)gridViewWithNumberOfColumns:(NSInteger)c rows:(NSInteger)r
{
    if (c < 0 || r < 0)
        [NSException raise:NSInvalidArgumentException format:@"Grid dimensions cannot be negative."];
    NSGridView *g = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    for (NSInteger i = 0; i < c; i++)
        [g addColumnWithViews:@[]];
    for (NSInteger i = 0; i < r; i++)
        [g addRowWithViews:@[]];
    return g;
}
+ (instancetype)gridViewWithViews:(NSArray *)rows
{
    NSGridView *g = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    for (NSArray *r in rows)
        [g addRowWithViews:r];
    return g;
}
- (NSInteger)numberOfRows
{
    return [_rows count];
}
- (NSInteger)numberOfColumns
{
    return [_columns count];
}
- (NSGridRow *)rowAtIndex:(NSInteger)i
{
    return _rows[i];
}
- (NSGridColumn *)columnAtIndex:(NSInteger)i
{
    return _columns[i];
}
- (NSInteger)indexOfRow:(NSGridRow *)r
{
    return [_rows indexOfObjectIdenticalTo:r];
}
- (NSInteger)indexOfColumn:(NSGridColumn *)c
{
    return [_columns indexOfObjectIdenticalTo:c];
}
- (NSGridCell *)cellAtColumnIndex:(NSInteger)c rowIndex:(NSInteger)r
{
    return [_rows[r] cellAtIndex:c];
}
- (NSGridCell *)cellForView:(NSView *)v
{
    for (NSView *q = v; q && q != self; q = [q superview])
        for (NSGridRow *r in _rows)
            for (NSGridCell *c in r->_cells)
                if (c->_content == q)
                    return c;
    return nil;
}
GRID_PROP(NSGridCellPlacement, xPlacement, setXPlacement, _xp, self)
GRID_PROP(NSGridCellPlacement, yPlacement, setYPlacement, _yp, self)
GRID_PROP(NSGridRowAlignment, rowAlignment, setRowAlignment, _alignment, self)
GRID_PROP(CGFloat, rowSpacing, setRowSpacing, _rowSpacing, self)
GRID_PROP(CGFloat, columnSpacing, setColumnSpacing, _columnSpacing, self)
- (NSGridRow *)addRowWithViews:(NSArray *)v
{
    return [self insertRowAtIndex:[_rows count] withViews:v];
}
- (NSGridRow *)insertRowAtIndex:(NSInteger)i withViews:(NSArray *)v
{
    if (i < 0 || i > (NSInteger)[_rows count])
        [NSException raise:NSRangeException format:@"Grid row index is out of range."];
    while ([_columns count] < [v count])
        [self addColumnWithViews:@[]];
    NSGridRow *r = [[[NSGridRow alloc] init] autorelease];
    r->_grid = self;
    [_rows insertObject:r atIndex:i];
    for (NSUInteger j = 0; j < [_columns count]; j++) {
        NSGridCell *c = [[[NSGridCell alloc] init] autorelease];
        c->_row = r;
        c->_column = _columns[j];
        [r->_cells addObject:c];
        if (j < [v count])
            [c setContentView:v[j]];
    }
    grid_changed(self);
    return r;
}
- (NSGridColumn *)addColumnWithViews:(NSArray *)v
{
    return [self insertColumnAtIndex:[_columns count] withViews:v];
}
- (NSGridColumn *)insertColumnAtIndex:(NSInteger)i withViews:(NSArray *)v
{
    if (i < 0 || i > (NSInteger)[_columns count])
        [NSException raise:NSRangeException format:@"Grid column index is out of range."];
    while ([_rows count] < [v count])
        [self addRowWithViews:@[]];
    NSGridColumn *c = [[[NSGridColumn alloc] init] autorelease];
    c->_grid = self;
    [_columns insertObject:c atIndex:i];
    for (NSUInteger j = 0; j < [_rows count]; j++) {
        NSGridRow *r = _rows[j];
        NSGridCell *cell = [[[NSGridCell alloc] init] autorelease];
        cell->_row = r;
        cell->_column = c;
        [r->_cells insertObject:cell atIndex:i];
        if (j < [v count])
            [cell setContentView:v[j]];
    }
    grid_changed(self);
    return c;
}
- (void)_finchUnmergeRemoved:(NSGridCell *)removed
{
    for (NSGridRow *r in _rows)
        for (NSGridCell *c in r->_cells)
            if (c->_head == removed)
                c->_head = nil;
}
- (void)removeRowAtIndex:(NSInteger)i
{
    NSGridRow *r = _rows[i];
    for (NSGridCell *c in r->_cells) {
        [self _finchUnmergeRemoved:c];
        [c setContentView:nil];
    }
    r->_grid = nil;
    [_rows removeObjectAtIndex:i];
    grid_changed(self);
}
- (void)removeColumnAtIndex:(NSInteger)i
{
    NSGridColumn *c = _columns[i];
    for (NSGridRow *r in _rows) {
        NSGridCell *x = r->_cells[i];
        [self _finchUnmergeRemoved:x];
        [x setContentView:nil];
        x->_column = nil;
        [r->_cells removeObjectAtIndex:i];
    }
    c->_grid = nil;
    [_columns removeObjectAtIndex:i];
    grid_changed(self);
}
- (void)moveRowAtIndex:(NSInteger)a toIndex:(NSInteger)b
{
    id r = [[_rows objectAtIndex:a] retain];
    [_rows objectAtIndex:b];
    [_rows removeObjectAtIndex:a];
    [_rows insertObject:r atIndex:b];
    [r release];
    grid_changed(self);
}
- (void)moveColumnAtIndex:(NSInteger)a toIndex:(NSInteger)b
{
    id c = [[_columns objectAtIndex:a] retain];
    [_columns objectAtIndex:b];
    [_columns removeObjectAtIndex:a];
    [_columns insertObject:c atIndex:b];
    [c release];
    for (NSGridRow *r in _rows) {
        id cell = [r->_cells[a] retain];
        [r->_cells removeObjectAtIndex:a];
        [r->_cells insertObject:cell atIndex:b];
        [cell release];
    }
    grid_changed(self);
}
- (void)mergeCellsInHorizontalRange:(NSRange)h verticalRange:(NSRange)v
{
    if (!h.length || !v.length || h.location > [_columns count] || h.length > [_columns count] - h.location ||
        v.location > [_rows count] || v.length > [_rows count] - v.location)
        [NSException raise:NSRangeException format:@"The merged cells must be inside the grid."];
    NSGridCell *head = [self cellAtColumnIndex:h.location rowIndex:v.location];
    for (NSUInteger y = v.location; y < NSMaxRange(v); y++)
        for (NSUInteger x = h.location; x < NSMaxRange(h); x++) {
            NSGridRow *r = _rows[y];
            NSGridCell *c = r->_cells[x];
            if (c != head) {
                [c setContentView:nil];
                c->_head = head;
            }
        }
    grid_changed(self);
}
static void gc(NSMutableArray *made, id a, NSLayoutAttribute aa, NSLayoutRelation relation, id b, NSLayoutAttribute ba,
               CGFloat constant, float priority, NSString *name)
{
    NSLayoutConstraint *c = [NSLayoutConstraint constraintWithItem:a
                                                         attribute:aa
                                                         relatedBy:relation
                                                            toItem:b
                                                         attribute:ba
                                                        multiplier:1
                                                          constant:constant];
    [c setPriority:priority];
    [c setIdentifier:name];
    [made addObject:c];
}
- (void)updateConstraints
{
    [NSLayoutConstraint deactivateConstraints:_made];
    [_made removeAllObjects];
    for (NSLayoutGuide *g in _guides)
        [self removeLayoutGuide:g];
    [_guides removeAllObjects];
    NSMutableArray *rg = [NSMutableArray array], *cg = [NSMutableArray array];
    for (int axis = 0; axis < 2; axis++) {
        NSArray *items = axis ? _rows : _columns;
        NSMutableArray *guides = axis ? rg : cg;
        NSLayoutAttribute start = axis ? NSLayoutAttributeTop : NSLayoutAttributeLeading,
                          end = axis ? NSLayoutAttributeBottom : NSLayoutAttributeTrailing,
                          dim = axis ? NSLayoutAttributeHeight : NSLayoutAttributeWidth;
        NSLayoutGuide *previous = nil;
        CGFloat previousPadding = 0;
        for (id item in items) {
            BOOL hidden = [item isHidden];
            CGFloat before = axis ? [item topPadding] : [item leadingPadding],
                    after = axis ? [item bottomPadding] : [item trailingPadding],
                    size = axis ? [item height] : [item width];
            NSLayoutGuide *g = [[[NSLayoutGuide alloc] init] autorelease];
            [self addLayoutGuide:g];
            [_guides addObject:g];
            [guides addObject:g];
            gc(_made, g, start, NSLayoutRelationEqual, previous ?: self, previous ? end : start,
               hidden ? 0 : before + (previous ? previousPadding + (axis ? _rowSpacing : _columnSpacing) : 0), 1000,
               @"GridView.boundary");
            gc(_made, g, dim, NSLayoutRelationGreaterThanOrEqual, nil, NSLayoutAttributeNotAnAttribute, 0, 1000,
               @"GridView.nonnegative");
            if (hidden || size != NSGridViewSizeForContent)
                gc(_made, g, dim, NSLayoutRelationEqual, nil, NSLayoutAttributeNotAnAttribute, hidden ? 0 : size, 1000,
                   axis ? @"NSGridRow.explicit_size" : @"NSGridColumn.explicit_size");
            else
                gc(_made, g, dim, NSLayoutRelationEqual, nil, NSLayoutAttributeNotAnAttribute, 0, 1,
                   @"GridView.empty_size");
            if (!hidden) {
                previous = g;
                previousPadding = after;
            }
        }
        if (previous)
            gc(_made, previous, end, NSLayoutRelationEqual, self, end, -previousPadding, 1000,
               @"GridView.last_boundary");
    }
    for (NSUInteger y = 0; y < [_rows count]; y++) {
        NSGridRow *r = _rows[y];
        NSView *baseline = nil;
        NSGridRowAlignment baseAlign = 0;
        for (NSUInteger x = 0; x < [_columns count]; x++) {
            NSGridCell *c = r->_cells[x];
            NSGridColumn *col = _columns[x];
            NSView *v = c->_content;
            if (c->_head || !v)
                continue;
            BOOL hidden = r->_hidden || col->_hidden;
            [v setHidden:hidden];
            if (hidden) {
                [NSLayoutConstraint deactivateConstraints:c->_custom];
                continue;
            }
            [NSLayoutConstraint activateConstraints:c->_custom];
            NSUInteger ex = x, ey = y;
            for (NSUInteger yy = y; yy < [_rows count]; yy++) {
                NSGridRow *rr = _rows[yy];
                for (NSUInteger xx = x; xx < [_columns count]; xx++) {
                    NSGridCell *cc = rr->_cells[xx];
                    if (cc->_head == c) {
                        ex = MAX(ex, xx);
                        ey = MAX(ey, yy);
                    }
                }
            }
            NSGridCellPlacement xp = c->_xp ?: col->_xp ?: _xp, yp = c->_yp ?: r->_yp ?: _yp;
            NSGridRowAlignment align = c->_alignment ?: r->_alignment ?: _alignment;
            for (int axis = 0; axis < 2; axis++) {
                NSGridCellPlacement place = axis ? yp : xp;
                if (place == NSGridCellPlacementNone)
                    continue;
                NSArray *guides = axis ? rg : cg;
                id first = guides[axis ? y : x], last = guides[axis ? ey : ex];
                NSLayoutAttribute start = axis ? NSLayoutAttributeTop : NSLayoutAttributeLeading,
                                  end = axis ? NSLayoutAttributeBottom : NSLayoutAttributeTrailing,
                                  center = axis ? NSLayoutAttributeCenterY : NSLayoutAttributeCenterX;
                if (axis && align >= NSGridRowAlignmentFirstBaseline && baseline) {
                    gc(_made, v,
                       align == NSGridRowAlignmentFirstBaseline ? NSLayoutAttributeFirstBaseline
                                                                : NSLayoutAttributeLastBaseline,
                       NSLayoutRelationEqual, baseline,
                       baseAlign == NSGridRowAlignmentFirstBaseline ? NSLayoutAttributeFirstBaseline
                                                                    : NSLayoutAttributeLastBaseline,
                       0, 1000, @"GridView.baseline");
                } else if (place == NSGridCellPlacementCenter && first == last)
                    gc(_made, v, center, NSLayoutRelationEqual, first, center, 0, 1000,
                       axis ? @"GridView_Y_centering" : @"GridView_X_centering");
                else if (place == NSGridCellPlacementCenter) {
                    NSLayoutGuide *span = [[[NSLayoutGuide alloc] init] autorelease];
                    [self addLayoutGuide:span];
                    [_guides addObject:span];
                    gc(_made, span, start, NSLayoutRelationEqual, first, start, 0, 1000, @"GridView.merged_start");
                    gc(_made, span, end, NSLayoutRelationEqual, last, end, 0, 1000, @"GridView.merged_end");
                    gc(_made, v, center, NSLayoutRelationEqual, span, center, 0, 1000,
                       axis ? @"GridView_Y_centering" : @"GridView_X_centering");
                } else {
                    if (place == NSGridCellPlacementLeading || place == NSGridCellPlacementFill ||
                        place == NSGridCellPlacementCenter)
                        gc(_made, v, start, NSLayoutRelationEqual, first, start, 0, 1000,
                           axis ? @"GridView_top_placement" : @"GridView_leading_placement");
                    if (place == NSGridCellPlacementTrailing || place == NSGridCellPlacementFill)
                        gc(_made, v, end, NSLayoutRelationEqual, last, end, 0, 1000,
                           axis ? @"GridView_bottom_placement" : @"GridView_trailing_placement");
                }
                if (place != NSGridCellPlacementFill) {
                    gc(_made, v, start, NSLayoutRelationGreaterThanOrEqual, first, start, 0, 1000,
                       @"GridView.start_containment");
                    gc(_made, v, end, NSLayoutRelationLessThanOrEqual, last, end, 0, 1000,
                       axis ? @"GridView.bottom_containment" : @"GridView.trailing_containment");
                    gc(_made, v, end, NSLayoutRelationGreaterThanOrEqual, last, end, 0, 249,
                       axis ? @"GridView.row_sizing" : @"GridView.column_sizing");
                }
            }
            if (!baseline && align >= NSGridRowAlignmentFirstBaseline) {
                baseline = v;
                baseAlign = align;
            }
        }
    }
    [NSLayoutConstraint activateConstraints:_made];
    [super updateConstraints];
}
- (void)layout
{
    NSMutableDictionary *hiddenFrames = [NSMutableDictionary dictionary];
    for (NSView *v in [self subviews])
        if ([v isHidden])
            hiddenFrames[[NSValue valueWithNonretainedObject:v]] = [NSValue valueWithRect:[v frame]];
    [super layout];
    /* An unattached grid keeps its own frame but lays out its contents at
     * the size chosen by the constraints. Its top is the fitted top. */
    if (![self superview] && ![self window] && ![self isFlipped]) {
        CGFloat delta = [self fittingSize].height - [self bounds].size.height;
        if (delta)
            for (NSView *v in [self subviews])
                if (![v isHidden]) {
                    NSRect frame = [v frame];
                    frame.origin.y += delta;
                    [v setFrame:frame];
                }
    }
    for (NSValue *key in hiddenFrames) {
        NSView *v = [key nonretainedObjectValue];
        NSRect frame = [v frame];
        frame.origin = [hiddenFrames[key] rectValue].origin;
        [v setFrame:frame];
    }
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [super initWithCoder:c];
    if (self) {
        [self _finchSetup];
        [_rows release];
        [_columns release];
        _rows = [[c decodeObjectForKey:@"NSGrid_rows"] mutableCopy] ?: [NSMutableArray new];
        _columns = [[c decodeObjectForKey:@"NSGrid_columns"] mutableCopy] ?: [NSMutableArray new];
        if ([c containsValueForKey:@"NSGrid_rowSpacing"])
            _rowSpacing = [c decodeDoubleForKey:@"NSGrid_rowSpacing"];
        if ([c containsValueForKey:@"NSGrid_columnSpacing"])
            _columnSpacing = [c decodeDoubleForKey:@"NSGrid_columnSpacing"];
        if ([c containsValueForKey:@"NSGrid_xPlacement"])
            _xp = [c decodeIntegerForKey:@"NSGrid_xPlacement"];
        if ([c containsValueForKey:@"NSGrid_yPlacement"])
            _yp = [c decodeIntegerForKey:@"NSGrid_yPlacement"];
        if ([c containsValueForKey:@"NSGrid_alignment"])
            _alignment = [c decodeIntegerForKey:@"NSGrid_alignment"];
        for (NSGridColumn *col in _columns)
            col->_grid = self;
        for (NSGridRow *r in _rows) {
            r->_grid = self;
            for (NSGridCell *cell in r->_cells) {
                cell->_row = r;
                if (cell->_content) {
                    [cell->_content setTranslatesAutoresizingMaskIntoConstraints:NO];
                    [self addSubview:cell->_content];
                }
            }
        }
        grid_changed(self);
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [super encodeWithCoder:c];
    [c encodeObject:_rows forKey:@"NSGrid_rows"];
    [c encodeObject:_columns forKey:@"NSGrid_columns"];
    [c encodeDouble:_rowSpacing forKey:@"NSGrid_rowSpacing"];
    [c encodeDouble:_columnSpacing forKey:@"NSGrid_columnSpacing"];
    [c encodeInteger:_xp forKey:@"NSGrid_xPlacement"];
    [c encodeInteger:_yp forKey:@"NSGrid_yPlacement"];
    [c encodeInteger:_alignment forKey:@"NSGrid_alignment"];
}
- (void)dealloc
{
    [NSLayoutConstraint deactivateConstraints:_made];
    for (NSGridRow *r in _rows)
        r->_grid = nil;
    for (NSGridColumn *c in _columns)
        c->_grid = nil;
    [_rows release];
    [_columns release];
    [_made release];
    [_guides release];
    [super dealloc];
}
@end
