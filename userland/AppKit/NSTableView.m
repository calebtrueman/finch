/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTableView: rows of a data source (or of a content binding) in columns,
 * drawn by the columns' cells (cell-based) or by views the delegate makes
 * (view-based), with a header, selection, sorting and editing.
 *
 * Geometry, as measured on macOS 26.4 (appkit-tables-test.m):
 *   - A row is rowHeight plus the intercell height tall (a delegate's
 *     -tableView:heightOfRow: replaces rowHeight; group rows without one are
 *     28 tall, 19 in source lists, 25 in plain tables); a cell sits in it
 *     floor(spacing/2) down, rowHeight tall.
 *   - A column is its width plus padding: half the intercell width on each
 *     side (floor before, ceil after), except that the outer edges of
 *     full-width, inset and source-list tables get 6.
 *   - Inset and source-list tables (the automatic style resolves to inset)
 *     are inset 10 at each side; inset tables have 5 above the rows and 10
 *     below, source lists 10 below.
 *   - The frame fits the columns and rows; in a clip view it is at least as
 *     big as the clip view less its content insets (the header's height).
 *   - When the clip view changes width, the columns are resized by the
 *     autoresizing style if they filled the table, or if they no longer
 *     fit: uniformly, sequentially from the last, from the first, the last
 *     only or the first only, each held to its minimum and maximum.
 *     -sizeToFit fits them uniformly, -sizeLastColumnToFit with the last.
 * Selection, as measured: programmatic selection ignores the delegate and
 * allowsMultipleSelection (a set reaching past the last row is ignored),
 * -selectAll: and -deselectAll: ask -selectionShouldChangeInTableView:,
 * -deselectAll: does nothing without allowsEmptySelection; the selected
 * row is the last one selected; selecting rows clears the selected
 * columns and the reverse; inserting rows moves the selection without a
 * notification, removing selected rows deselects them with one; cell-based
 * tables insert, remove and move rows only between -beginUpdates and
 * -endUpdates.
 * View-based tables make row views and cell views for the rows in the
 * visible rect (every row outside a window) as they are laid out or asked
 * for, asking the delegate for the row view, then each column's view, then
 * the data source for its object value; views leaving the visible rect go
 * to a reuse queue that -makeViewWithIdentifier:owner: takes from before
 * registered nibs (and the views a nib archived as prototypes).
 */
#import "NSTableView_Finch.h"
#import "NSKeyValueBinding_Finch.h"

NSNotificationName NSTableViewSelectionDidChangeNotification = @"NSTableViewSelectionDidChangeNotification";
NSNotificationName NSTableViewColumnDidMoveNotification = @"NSTableViewColumnDidMoveNotification";
NSNotificationName NSTableViewColumnDidResizeNotification = @"NSTableViewColumnDidResizeNotification";
NSNotificationName NSTableViewSelectionIsChangingNotification = @"NSTableViewSelectionIsChangingNotification";
NSUserInterfaceItemIdentifier const NSTableViewRowViewKey = @"NSTableViewRowViewKey";

@interface NSTableColumn (FinchTableBindings)
- (id)_finchBoundValueAtRow:(NSInteger)row object:(id)object;
- (void)_finchPushBoundValue:(id)value atRow:(NSInteger)row;
- (BOOL)_finchHasValueBinding;
@end

@interface _NSCornerView : NSView
@end

typedef struct {
    CGFloat x, w, lead;
} ColumnBox;

@implementation NSTableView {
    NSMutableArray<NSTableColumn *> *_columns;
    NSTableHeaderView *_headerView;
    NSView *_cornerView;
    id _dataSource, _delegate; /* not retained */
    CGFloat _rowHeight;
    NSSize _spacing;
    NSColor *_backgroundColor, *_gridColor;
    NSTableViewGridLineStyle _gridMask;
    NSTableViewStyle _style;
    NSTableViewRowSizeStyle _rowSizeStyle;
    NSTableViewSelectionHighlightStyle _highlightStyle;
    NSTableViewColumnAutoresizingStyle _autoresizing;
    NSTableViewDraggingDestinationFeedbackStyle _dragStyle;
    NSInteger _rows; /* -1 until counted */
    CGFloat *_rowY;  /* the rows' tops and the bottom, while valid (rows of different heights) */
    NSInteger _rowYCount;
    BOOL _rowsUniform; /* all rows rowHeight tall: tops by arithmetic */
    CGFloat _rowTop, _rowPitch;
    CGFloat _tiledWidth; /* the width the table last tiled to */
    NSMutableIndexSet *_selRows, *_selCols;
    NSInteger _lastRow, _lastCol;
    NSArray *_sortDescriptors;
    NSMapTable *_indicators; /* column -> image */
    NSTableColumn *_highlighted;
    SEL _doubleAction;
    NSInteger _clickedRow, _clickedColumn, _editedRow, _editedColumn, _focusedColumn;
    NSString *_autosaveName;
    NSMutableDictionary *_rowViews; /* NSNumber row -> NSTableRowView */
    NSMutableDictionary *_nibs;     /* identifier -> NSNib */
    NSMutableDictionary *_reuse;    /* identifier -> NSMutableArray of views */
    NSText *_fieldEditor;
    NSCell *_editingCell;
    NSInteger _updates;
    NSView *_observedClip;
    NSArray *_draggingSourceMasks;
    struct {
        unsigned emptySelection : 1;
        unsigned multipleSelection : 1;
        unsigned columnSelection : 1;
        unsigned reordering : 1;
        unsigned resizing : 1;
        unsigned typeSelect : 1;
        unsigned floatsGroupRows : 1;
        unsigned autosaveColumns : 1;
        unsigned alternating : 1;
        unsigned autoRowHeights : 1;
        unsigned verticalMotion : 1;
        unsigned staticContents : 1;
        unsigned tiling : 1;
        unsigned realizing : 1;
        unsigned pushingSelection : 1;
        unsigned pushingSort : 1;
        unsigned decoded : 1;
    } _tv;
}

static void table_init(NSTableView *self);

+ (Class)cellClass { return Nil; }

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    table_init(self);
    _headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 0, 28)];
    [_headerView setTableView:self];
    _cornerView = [[_NSCornerView alloc] initWithFrame:NSMakeRect(0, 0, 17, 28)];
    return self;
}

static void
table_init(NSTableView *self)
{
    self->_columns = [[NSMutableArray alloc] init];
    self->_rowHeight = 24;
    self->_spacing = NSMakeSize(17, 0);
    self->_autoresizing = NSTableViewLastColumnOnlyAutoresizingStyle;
    self->_rows = -1;
    self->_selRows = [[NSMutableIndexSet alloc] init];
    self->_selCols = [[NSMutableIndexSet alloc] init];
    self->_lastRow = self->_lastCol = -1;
    self->_sortDescriptors = [@[] retain];
    self->_indicators = [[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory |
                                                            NSPointerFunctionsOpaquePersonality
                                               valueOptions:NSPointerFunctionsStrongMemory] retain];
    self->_clickedRow = self->_clickedColumn = self->_editedRow = self->_editedColumn = self->_focusedColumn = -1;
    self->_rowViews = [[NSMutableDictionary alloc] init];
    self->_nibs = [[NSMutableDictionary alloc] init];
    self->_reuse = [[NSMutableDictionary alloc] init];
    self->_tv.emptySelection = YES;
    self->_tv.reordering = YES;
    self->_tv.resizing = YES;
    self->_tv.typeSelect = YES;
    self->_tv.floatsGroupRows = YES;
    self->_tv.verticalMotion = YES;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_delegate)
        [[NSNotificationCenter defaultCenter] removeObserver:_delegate name:nil object:self];
    for (NSTableColumn *c in _columns)
        if ([c tableView] == self)
            [c _finchSetTableView:nil];
    if ([_headerView tableView] == self)
        [_headerView setTableView:nil];
    [_columns release];
    [_headerView release];
    [_cornerView release];
    [_backgroundColor release];
    [_gridColor release];
    free(_rowY);
    [_selRows release];
    [_selCols release];
    [_sortDescriptors release];
    [_indicators release];
    [_autosaveName release];
    [_rowViews release];
    [_nibs release];
    [_reuse release];
    [_editingCell release];
    [_draggingSourceMasks release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)needsPanelToBecomeKey { return YES; }

#pragma mark - Data source and delegate

- (id<NSTableViewDataSource>)dataSource { return _dataSource; }

- (void)setDataSource:(id<NSTableViewDataSource>)dataSource
{
    _dataSource = dataSource;
    [self reloadData];
}

- (id<NSTableViewDelegate>)delegate { return _delegate; }

/* The delegate hears the table's notifications through the methods it implements. */
- (NSArray *)_finchDelegateNotifications
{
    return @[
        @[ NSTableViewSelectionDidChangeNotification, @"tableViewSelectionDidChange:" ],
        @[ NSTableViewSelectionIsChangingNotification, @"tableViewSelectionIsChanging:" ],
        @[ NSTableViewColumnDidMoveNotification, @"tableViewColumnDidMove:" ],
        @[ NSTableViewColumnDidResizeNotification, @"tableViewColumnDidResize:" ],
    ];
}

- (void)setDelegate:(id<NSTableViewDelegate>)delegate
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_delegate)
        for (NSArray *n in [self _finchDelegateNotifications])
            [nc removeObserver:_delegate name:n[0] object:self];
    _delegate = delegate;
    for (NSArray *n in [self _finchDelegateNotifications]) {
        SEL sel = NSSelectorFromString(n[1]);
        if ([delegate respondsToSelector:sel])
            [nc addObserver:delegate selector:sel name:n[0] object:self];
    }
    [self _finchInvalidateRowGeometry];
    [self tile];
}

#pragma mark - The hooks NSOutlineView changes

- (NSInteger)_finchCountRows
{
    _FinchBinding *b = FinchBindingFor(self, NSContentBinding);
    if (b) {
        id content = [b rawValue];
        return [content respondsToSelector:@selector(count)] ? (NSInteger)[content count] : 0;
    }
    if ([_dataSource respondsToSelector:@selector(numberOfRowsInTableView:)])
        return [_dataSource numberOfRowsInTableView:self];
    return 0;
}

- (id)_finchContentObjectAtRow:(NSInteger)row
{
    _FinchBinding *b = FinchBindingFor(self, NSContentBinding);
    if (!b)
        return nil;
    id content = [b rawValue];
    if (![content respondsToSelector:@selector(objectAtIndex:)] || row < 0 || (NSUInteger)row >= [content count])
        return nil;
    return [content objectAtIndex:row];
}

- (id)_finchObjectValueForColumn:(NSTableColumn *)column row:(NSInteger)row
{
    if ([column _finchHasValueBinding])
        return [column _finchBoundValueAtRow:row object:[self _finchContentObjectAtRow:row]];
    if ([_dataSource respondsToSelector:@selector(tableView:objectValueForTableColumn:row:)])
        return [_dataSource tableView:self objectValueForTableColumn:column row:row];
    /* a view-based table's cell views show the row's object */
    return [self _finchIsViewBased] ? [self _finchContentObjectAtRow:row] : nil;
}

- (BOOL)_finchProvidesObjectValues
{
    return [_dataSource respondsToSelector:@selector(tableView:objectValueForTableColumn:row:)] ||
           FinchBindingFor(self, NSContentBinding) != nil;
}

- (void)_finchSetObjectValue:(id)value forColumn:(NSTableColumn *)column row:(NSInteger)row
{
    if ([column _finchHasValueBinding])
        [column _finchPushBoundValue:value atRow:row];
    else if ([_dataSource respondsToSelector:@selector(tableView:setObjectValue:forTableColumn:row:)])
        [_dataSource tableView:self setObjectValue:value forTableColumn:column row:row];
}

- (BOOL)_finchIsGroupRow:(NSInteger)row
{
    return [_delegate respondsToSelector:@selector(tableView:isGroupRow:)] && [_delegate tableView:self isGroupRow:row];
}

- (BOOL)_finchDelegateHasRowHeights
{
    return [_delegate respondsToSelector:@selector(tableView:heightOfRow:)];
}

- (CGFloat)_finchDelegateHeightOfRow:(NSInteger)row
{
    return [_delegate tableView:self heightOfRow:row];
}

- (BOOL)_finchDelegateMakesViews
{
    return [_delegate respondsToSelector:@selector(tableView:viewForTableColumn:row:)];
}

- (NSView *)_finchDelegateViewForColumn:(NSTableColumn *)column row:(NSInteger)row
{
    if ([self _finchDelegateMakesViews])
        return [_delegate tableView:self viewForTableColumn:column row:row];
    /* bindings without the delegate method: the column's prototype */
    return column ? [self makeViewWithIdentifier:[column identifier] owner:_delegate] : nil;
}

- (NSTableRowView *)_finchDelegateRowViewForRow:(NSInteger)row
{
    if ([_delegate respondsToSelector:@selector(tableView:rowViewForRow:)])
        return [_delegate tableView:self rowViewForRow:row];
    return nil;
}

- (void)_finchDidAddRowView:(NSTableRowView *)rowView row:(NSInteger)row
{
    if ([_delegate respondsToSelector:@selector(tableView:didAddRowView:forRow:)])
        [_delegate tableView:self didAddRowView:rowView forRow:row];
}

- (void)_finchDidRemoveRowView:(NSTableRowView *)rowView row:(NSInteger)row
{
    if ([_delegate respondsToSelector:@selector(tableView:didRemoveRowView:forRow:)])
        [_delegate tableView:self didRemoveRowView:rowView forRow:row];
}

- (void)_finchWillDisplayCell:(NSCell *)cell column:(NSTableColumn *)column row:(NSInteger)row
{
    if ([_delegate respondsToSelector:@selector(tableView:willDisplayCell:forTableColumn:row:)])
        [_delegate tableView:self willDisplayCell:cell forTableColumn:column row:row];
}

- (BOOL)_finchShouldSelectRow:(NSInteger)row
{
    if ([_delegate respondsToSelector:@selector(tableView:shouldSelectRow:)])
        return [_delegate tableView:self shouldSelectRow:row];
    return YES;
}

- (NSIndexSet *)_finchProposedSelection:(NSIndexSet *)proposed
{
    if ([_delegate respondsToSelector:@selector(tableView:selectionIndexesForProposedSelection:)])
        return [_delegate tableView:self selectionIndexesForProposedSelection:proposed];
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    [proposed enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if ([_selRows containsIndex:i] || [self _finchShouldSelectRow:i])
            [out addIndex:i];
    }];
    return out;
}

- (BOOL)_finchSelectionShouldChange
{
    if ([_delegate respondsToSelector:@selector(selectionShouldChangeInTableView:)])
        return [_delegate selectionShouldChangeInTableView:self];
    return YES;
}

- (BOOL)_finchShouldEditColumn:(NSTableColumn *)column row:(NSInteger)row
{
    if ([_delegate respondsToSelector:@selector(tableView:shouldEditTableColumn:row:)])
        return [_delegate tableView:self shouldEditTableColumn:column row:row];
    return YES;
}

- (NSString *)_finchSelectionDidChangeName { return NSTableViewSelectionDidChangeNotification; }
- (NSString *)_finchSelectionIsChangingName { return NSTableViewSelectionIsChangingNotification; }
- (NSString *)_finchColumnDidMoveName { return NSTableViewColumnDidMoveNotification; }
- (NSString *)_finchColumnDidResizeName { return NSTableViewColumnDidResizeNotification; }

- (void)_finchSortDescriptorsChanged:(NSArray *)old
{
    if ([_dataSource respondsToSelector:@selector(tableView:sortDescriptorsDidChange:)])
        [_dataSource tableView:self sortDescriptorsDidChange:old];
}

- (void)_finchDidClickColumn:(NSTableColumn *)column
{
    if ([_delegate respondsToSelector:@selector(tableView:didClickTableColumn:)])
        [_delegate tableView:self didClickTableColumn:column];
}

#pragma mark - Columns

- (NSArray<NSTableColumn *> *)tableColumns { return [[_columns copy] autorelease]; }
- (NSInteger)numberOfColumns { return (NSInteger)[_columns count]; }

- (void)addTableColumn:(NSTableColumn *)column
{
    if (!column)
        return;
    [_columns addObject:column];
    [column _finchSetTableView:self];
    _FinchBinding *b = FinchBindingFor(column, NSValueBinding);
    if (b)
        [column _finchBindingChanged:b];
    [self _finchColumnsChanged];
}

- (void)removeTableColumn:(NSTableColumn *)column
{
    NSUInteger i = [_columns indexOfObjectIdenticalTo:column];
    if (i == NSNotFound)
        return;
    [[column retain] autorelease];
    if (_highlighted == column)
        _highlighted = nil;
    [_indicators removeObjectForKey:column];
    [_columns removeObjectAtIndex:i];
    [column _finchSetTableView:nil];
    /* the selected columns after it move down */
    NSMutableIndexSet *cols = [NSMutableIndexSet indexSet];
    [_selCols enumerateIndexesUsingBlock:^(NSUInteger c, BOOL *stop) {
        if (c < i)
            [cols addIndex:c];
        else if (c > i)
            [cols addIndex:c - 1];
    }];
    [_selCols removeAllIndexes];
    [_selCols addIndexes:cols];
    [self _finchColumnsChanged];
}

- (void)moveColumn:(NSInteger)from toColumn:(NSInteger)to
{
    NSInteger n = (NSInteger)[_columns count];
    if (from < 0 || from >= n || to < 0 || to >= n)
        [NSException raise:NSInternalInconsistencyException format:@"Invalid column index"];
    if (from == to)
        return;
    NSTableColumn *c = [[_columns objectAtIndex:from] retain];
    [_columns removeObjectAtIndex:from];
    [_columns insertObject:c atIndex:to];
    [c release];
    BOOL fromSel = [_selCols containsIndex:from];
    NSMutableIndexSet *cols = [NSMutableIndexSet indexSet];
    [_selCols enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if ((NSInteger)i == from)
            return;
        NSInteger j = i;
        if (from < to && j > from && j <= to)
            j--;
        else if (from > to && j >= to && j < from)
            j++;
        [cols addIndex:j];
    }];
    if (fromSel)
        [cols addIndex:to];
    [_selCols removeAllIndexes];
    [_selCols addIndexes:cols];
    /* view-based rows move their views with the column */
    for (NSTableRowView *rv in [_rowViews allValues]) {
        NSMutableArray *views = [[[rv _finchCellViews] mutableCopy] autorelease];
        if ((NSInteger)[views count] == n) {
            id v = [[views objectAtIndex:from] retain];
            [views removeObjectAtIndex:from];
            [views insertObject:v atIndex:to];
            [v release];
            [rv _finchSetCellViews:views];
        }
    }
    [self _finchColumnsChanged];
    [[NSNotificationCenter defaultCenter] postNotificationName:[self _finchColumnDidMoveName] object:self
                                                      userInfo:@{@"NSOldColumn" : @(from), @"NSNewColumn" : @(to)}];
}

- (NSInteger)columnWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    NSUInteger i = 0;
    for (NSTableColumn *c in _columns) {
        if ([[c identifier] isEqual:identifier])
            return (NSInteger)i;
        i++;
    }
    return -1;
}

- (NSTableColumn *)tableColumnWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    NSInteger i = [self columnWithIdentifier:identifier];
    return i < 0 ? nil : [_columns objectAtIndex:i];
}

- (void)_finchColumnsChanged
{
    [self tile];
    [_headerView setNeedsDisplay:YES];
    [self setNeedsLayout:YES];
    [self _finchLayoutRowViews];
}

- (void)_finchColumnChanged:(NSTableColumn *)column oldWidth:(CGFloat)oldWidth
{
    [self _finchColumnsChanged];
    [[NSNotificationCenter defaultCenter] postNotificationName:[self _finchColumnDidResizeName] object:self
                                                      userInfo:@{@"NSTableColumn" : column, @"NSOldWidth" : @(oldWidth)}];
}

/* Hiding or showing a column keeps the table's width: the others take up the difference. */
- (void)_finchColumnVisibilityChanged:(NSTableColumn *)column
{
    CGFloat width = NSWidth([self frame]);
    [self _finchAutoresizeColumnsBy:width - [self _finchColumnsWidth] style:_autoresizing notify:YES];
    [self _finchColumnsChanged];
}

#pragma mark - Style and metrics

- (NSTableViewStyle)style { return _style; }

- (void)setStyle:(NSTableViewStyle)style
{
    _style = style;
    [self _finchInvalidateRowGeometry];
    [self tile];
}

- (NSTableViewStyle)effectiveStyle { return [self _finchStyle]; }

- (NSTableViewStyle)_finchStyle
{
    if (_style != NSTableViewStyleAutomatic)
        return _style;
    return _highlightStyle == NSTableViewSelectionHighlightStyleSourceList ? NSTableViewStyleSourceList
                                                                            : NSTableViewStyleInset;
}

static CGFloat
side_inset(NSTableView *self)
{
    NSTableViewStyle s = [self _finchStyle];
    return s == NSTableViewStyleInset || s == NSTableViewStyleSourceList ? 10 : 0;
}

/* The visible columns' boxes: x and width of each column's rect, and the padding before its cell. */
static NSInteger
column_boxes(NSTableView *self, ColumnBox *out, NSInteger max)
{
    NSInteger n = (NSInteger)[self->_columns count], first = -1, last = -1;
    for (NSInteger i = 0; i < n; i++)
        if (![[self->_columns objectAtIndex:i] isHidden]) {
            if (first < 0)
                first = i;
            last = i;
        }
    CGFloat s = self->_spacing.width, before = floor(s / 2), after = s - floor(s / 2);
    BOOL padded = [self _finchStyle] != NSTableViewStylePlain;
    CGFloat x = side_inset(self);
    for (NSInteger i = 0; i < n && i < max; i++) {
        NSTableColumn *c = [self->_columns objectAtIndex:i];
        if ([c isHidden]) {
            out[i] = (ColumnBox){0, 0, 0};
            continue;
        }
        CGFloat lead = padded && i == first ? 6 : before, trail = padded && i == last ? 6 : after;
        CGFloat w = lead + [c width] + trail;
        out[i] = (ColumnBox){x, w, lead};
        x += w;
    }
    return n;
}

- (CGFloat)_finchColumnsWidth
{
    NSInteger n = (NSInteger)[_columns count];
    ColumnBox *b = calloc(n + 1, sizeof(ColumnBox));
    column_boxes(self, b, n);
    CGFloat w = 0;
    for (NSInteger i = 0; i < n; i++)
        w = MAX(w, b[i].x + b[i].w);
    free(b);
    return MAX(w, side_inset(self)) + side_inset(self);
}

- (NSRect)rectOfColumn:(NSInteger)column
{
    NSInteger n = (NSInteger)[_columns count];
    if (column < 0 || column >= n)
        return NSZeroRect;
    ColumnBox *b = calloc(n, sizeof(ColumnBox));
    column_boxes(self, b, n);
    ColumnBox c = b[column];
    free(b);
    if (c.w == 0)
        return NSZeroRect;
    return NSMakeRect(c.x, 0, c.w, NSHeight([self bounds]));
}

static CGFloat
top_inset(NSTableView *self)
{
    if ([self _finchStyle] != NSTableViewStyleInset)
        return 0;
    /* a group row at the top gets more room */
    if (self->_rows > 0 && ![self _finchDelegateHasRowHeights] && [self _finchIsGroupRow:0])
        return 10;
    return 5;
}

static CGFloat
bottom_inset(NSTableView *self)
{
    NSTableViewStyle s = [self _finchStyle];
    return s == NSTableViewStyleInset || s == NSTableViewStyleSourceList ? 10 : 0;
}

static CGFloat
group_row_height(NSTableView *self)
{
    switch ([self _finchStyle]) {
    case NSTableViewStyleSourceList:
        return 19;
    case NSTableViewStylePlain:
        return 25;
    default:
        return 28;
    }
}

- (void)_finchInvalidateRowGeometry
{
    free(_rowY);
    _rowY = NULL;
    _rowYCount = 0;
    _rowsUniform = NO;
}

static void
compute_rows(NSTableView *self)
{
    NSInteger n = [self numberOfRows];
    if (self->_rowYCount == n + 1)
        return;
    free(self->_rowY);
    self->_rowY = NULL;
    self->_rowYCount = n + 1;
    BOOL heights = [self _finchDelegateHasRowHeights];
    BOOL groups = [self->_delegate respondsToSelector:@selector(tableView:isGroupRow:)] ||
                  [self respondsToSelector:@selector(_finchHasGroupItems)];
    CGFloat y = top_inset(self);
    self->_rowTop = y;
    self->_rowPitch = self->_rowHeight + self->_spacing.height;
    self->_rowsUniform = !heights && !groups;
    if (self->_rowsUniform)
        return;
    self->_rowY = malloc((n + 1) * sizeof(CGFloat));
    for (NSInteger r = 0; r < n; r++) {
        self->_rowY[r] = y;
        CGFloat h = self->_rowHeight;
        if (heights)
            h = [self _finchDelegateHeightOfRow:r];
        else if (groups && [self _finchIsGroupRow:r])
            h = group_row_height(self) - self->_spacing.height;
        y += h + self->_spacing.height;
    }
    self->_rowY[n] = y;
}

/* The top of a row (or, for the row count, the bottom of the last). */
static inline CGFloat
row_top(NSTableView *self, NSInteger r)
{
    return self->_rowsUniform ? self->_rowTop + r * self->_rowPitch : self->_rowY[r];
}

- (CGFloat)_finchRowsHeight
{
    compute_rows(self);
    return row_top(self, _rowYCount - 1) + bottom_inset(self);
}

- (NSRect)rectOfRow:(NSInteger)row
{
    if (row < 0 || row >= [self numberOfRows])
        return NSZeroRect;
    compute_rows(self);
    CGFloat top = row_top(self, row);
    return NSMakeRect(0, top, NSWidth([self bounds]), row_top(self, row + 1) - top);
}

- (NSRange)rowsInRect:(NSRect)rect
{
    NSInteger n = [self numberOfRows];
    if (n == 0 || NSIsEmptyRect(rect))
        return NSMakeRange(0, 0);
    compute_rows(self);
    /* the first row ending below the rect's top, the last starting above its bottom */
    NSInteger lo = 0, hi = n;
    while (lo < hi) {
        NSInteger mid = (lo + hi) / 2;
        if (row_top(self, mid + 1) <= NSMinY(rect))
            lo = mid + 1;
        else
            hi = mid;
    }
    NSInteger first = lo;
    lo = first, hi = n;
    while (lo < hi) {
        NSInteger mid = (lo + hi) / 2;
        if (row_top(self, mid) < NSMaxY(rect))
            lo = mid + 1;
        else
            hi = mid;
    }
    NSInteger end = lo;
    if (first >= n || end <= first)
        return NSMakeRange(0, 0);
    return NSMakeRange(first, end - first);
}

- (NSIndexSet *)columnIndexesInRect:(NSRect)rect
{
    NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
    for (NSInteger i = 0; i < (NSInteger)[_columns count]; i++) {
        NSRect r = [self rectOfColumn:i];
        r.size.height = MAX(r.size.height, 1);
        r.origin.y = NSMinY(rect);
        if (NSWidth(r) > 0 && NSMaxX(r) > NSMinX(rect) && NSMinX(r) < NSMaxX(rect))
            [s addIndex:i];
    }
    return s;
}

- (NSRange)columnsInRect:(NSRect)rect
{
    NSIndexSet *s = [self columnIndexesInRect:rect];
    if (![s count])
        return NSMakeRange(0, 0);
    return NSMakeRange([s firstIndex], [s lastIndex] - [s firstIndex] + 1);
}

- (NSInteger)rowAtPoint:(NSPoint)point
{
    NSInteger n = [self numberOfRows];
    if (n == 0)
        return -1;
    compute_rows(self);
    if (point.y < row_top(self, 0) || point.y >= row_top(self, n))
        return -1;
    NSInteger lo = 0, hi = n - 1;
    while (lo < hi) {
        NSInteger mid = (lo + hi + 1) / 2;
        if (row_top(self, mid) <= point.y)
            lo = mid;
        else
            hi = mid - 1;
    }
    return lo;
}

- (NSInteger)columnAtPoint:(NSPoint)point
{
    for (NSInteger i = 0; i < (NSInteger)[_columns count]; i++) {
        NSRect r = [self rectOfColumn:i];
        if (NSWidth(r) > 0 && point.x >= NSMinX(r) && point.x < NSMaxX(r))
            return i;
    }
    return -1;
}

- (NSRect)_finchPlainFrameOfCellAtColumn:(NSInteger)column row:(NSInteger)row
{
    NSInteger n = (NSInteger)[_columns count];
    if (column < 0 || column >= n || row < 0 || row >= [self numberOfRows])
        return NSZeroRect;
    ColumnBox *b = calloc(n, sizeof(ColumnBox));
    column_boxes(self, b, n);
    ColumnBox c = b[column];
    free(b);
    if (c.w == 0)
        return NSZeroRect;
    NSRect r = [self rectOfRow:row];
    CGFloat sh = _spacing.height;
    return NSMakeRect(c.x + c.lead, NSMinY(r) + floor(sh / 2), [[_columns objectAtIndex:column] width],
                      MAX(0, NSHeight(r) - sh));
}

- (NSRect)frameOfCellAtColumn:(NSInteger)column row:(NSInteger)row
{
    return [self _finchPlainFrameOfCellAtColumn:column row:row];
}

#pragma mark - Rows

- (NSInteger)numberOfRows
{
    if (_rows < 0)
        _rows = MAX(0, [self _finchCountRows]);
    return _rows;
}

- (CGFloat)rowHeight { return _rowHeight; }

- (void)setRowHeight:(CGFloat)rowHeight
{
    if (rowHeight <= 0) return;
    CGFloat scale = MAX(1, [[self window] backingScaleFactor]);
    _rowHeight = round(rowHeight * scale) / scale;
    [self _finchInvalidateRowGeometry];
    [self tile];
    [self _finchLayoutRowViews];
}

- (NSSize)intercellSpacing { return _spacing; }

- (void)setIntercellSpacing:(NSSize)spacing
{
    _spacing = spacing;
    [self _finchInvalidateRowGeometry];
    [self tile];
    [self _finchLayoutRowViews];
}

- (NSTableViewRowSizeStyle)rowSizeStyle { return _rowSizeStyle; }
- (void)setRowSizeStyle:(NSTableViewRowSizeStyle)style { _rowSizeStyle = style; }

- (NSTableViewRowSizeStyle)effectiveRowSizeStyle
{
    return _rowSizeStyle == NSTableViewRowSizeStyleDefault ? NSTableViewRowSizeStyleMedium : _rowSizeStyle;
}

- (BOOL)usesAutomaticRowHeights { return _tv.autoRowHeights; }
- (void)setUsesAutomaticRowHeights:(BOOL)flag { _tv.autoRowHeights = flag; }

- (void)noteHeightOfRowsWithIndexesChanged:(NSIndexSet *)indexSet
{
    [self _finchInvalidateRowGeometry];
    [self tile];
    [self _finchLayoutRowViews];
}

/* The rows changed under the table: count them again, keep the selection within them. */
- (void)_finchRecount
{
    _rows = -1;
    [self _finchInvalidateRowGeometry];
    NSInteger n = [self numberOfRows];
    if ([_selRows count] && (NSInteger)[_selRows lastIndex] >= n) {
        NSMutableIndexSet *s = [[_selRows mutableCopy] autorelease];
        [s removeIndexesInRange:NSMakeRange(n, NSUIntegerMax - n)];
        [self _finchSetSelectedRows:s anchor:_lastRow < n ? _lastRow : -1 notify:YES];
    }
}

- (void)noteNumberOfRowsChanged
{
    [self _finchRecount];
    [self tile];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)reloadData
{
    [self abortEditing];
    /* as Apple's, a view-based table forgets its selection */
    if ([self _finchDelegateMakesViews] && !FinchBindingFor(self, NSSelectionIndexesBinding) &&
        ([_selRows count] || [_selCols count])) {
        [_selCols removeAllIndexes];
        [self _finchSetSelectedRows:[NSIndexSet indexSet] anchor:-1 notify:YES];
    }
    [self _finchRemoveAllRowViews];
    [self _finchRecount];
    [self tile];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)_finchRowsChanged
{
    [self reloadData];
}

- (void)reloadDataForRowIndexes:(NSIndexSet *)rows columnIndexes:(NSIndexSet *)columns
{
    if (![_rowViews count]) {
        [self setNeedsDisplay:YES];
        return;
    }
    [rows enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
        NSTableRowView *rv = [_rowViews objectForKey:@(r)];
        if (!rv)
            return;
        [columns enumerateIndexesUsingBlock:^(NSUInteger c, BOOL *stop2) {
            [self _finchReloadViewInRowView:rv column:c row:r];
        }];
    }];
}

- (void)beginUpdates { _updates++; }
- (NSInteger)_finchUpdateDepth { return _updates; }

- (void)endUpdates
{
    if (_updates > 0)
        _updates--;
    if (_updates == 0) {
        [self tile];
        [self setNeedsDisplay:YES];
    }
}

- (BOOL)_finchIsViewBased
{
    return [self _finchDelegateMakesViews] || [_nibs count] > 0 || [_rowViews count] > 0;
}

static void
check_updates(NSTableView *self)
{
    if (self->_updates == 0 && ![self _finchIsViewBased])
        [NSException raise:NSInternalInconsistencyException
                    format:@"NSTableView Error: Insert/remove/move only works within a -beginUpdates/-endUpdates "
                           @"block or a View Based TableView."];
}

/* Shift an index set for inserted rows (each index in `inserted` is where a row lands). */
static NSIndexSet *
shift_for_insert(NSIndexSet *set, NSIndexSet *inserted)
{
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    [set enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        NSUInteger j = i;
        NSUInteger k = [inserted firstIndex];
        while (k != NSNotFound && k <= j) {
            j++;
            k = [inserted indexGreaterThanIndex:k];
        }
        [out addIndex:j];
    }];
    return out;
}

static NSInteger
shift_index_for_insert(NSInteger i, NSIndexSet *inserted)
{
    if (i < 0)
        return i;
    NSIndexSet *s = shift_for_insert([NSIndexSet indexSetWithIndex:i], inserted);
    return (NSInteger)[s firstIndex];
}

static NSIndexSet *
shift_for_remove(NSIndexSet *set, NSIndexSet *removed)
{
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    [set enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if ([removed containsIndex:i])
            return;
        NSUInteger below = [removed countOfIndexesInRange:NSMakeRange(0, i)];
        [out addIndex:i - below];
    }];
    return out;
}

- (void)insertRowsAtIndexes:(NSIndexSet *)indexes withAnimation:(NSTableViewAnimationOptions)options
{
    check_updates(self);
    if (![indexes count])
        return;
    NSInteger n = [self numberOfRows];
    _rows = n + (NSInteger)[indexes count];
    [self _finchInvalidateRowGeometry];
    NSIndexSet *sel = shift_for_insert(_selRows, indexes);
    [_selRows removeAllIndexes];
    [_selRows addIndexes:sel];
    _lastRow = shift_index_for_insert(_lastRow, indexes);
    /* row views move down; the new rows get views if their neighbours have them */
    if ([_rowViews count]) {
        NSMutableDictionary *moved = [NSMutableDictionary dictionary];
        for (NSNumber *k in [_rowViews allKeys]) {
            NSInteger r = shift_index_for_insert([k integerValue], indexes);
            NSTableRowView *rv = [_rowViews objectForKey:k];
            [rv _finchSetRow:r];
            [moved setObject:rv forKey:@(r)];
        }
        [_rowViews setDictionary:moved];
        [self tile];
        [self _finchLayoutRowViews];
        [indexes enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
            if ([self _finchRowIsVisible:r])
                [self _finchMakeRowView:r];
        }];
    } else {
        [self tile];
    }
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)removeRowsAtIndexes:(NSIndexSet *)indexes withAnimation:(NSTableViewAnimationOptions)options
{
    check_updates(self);
    if (![indexes count])
        return;
    NSInteger n = [self numberOfRows];
    NSUInteger gone = [indexes countOfIndexesInRange:NSMakeRange(0, n)];
    _rows = n - (NSInteger)gone;
    [self _finchInvalidateRowGeometry];
    if ([_rowViews count]) {
        NSMutableDictionary *kept = [NSMutableDictionary dictionary];
        for (NSNumber *k in [[_rowViews allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSInteger r = [k integerValue];
            NSTableRowView *rv = [_rowViews objectForKey:k];
            if ([indexes containsIndex:r]) {
                [[rv retain] autorelease];
                [rv removeFromSuperview];
                [rv _finchSetRow:-1];
                [self _finchDidRemoveRowView:rv row:-1];
                continue;
            }
            NSInteger nr = r - (NSInteger)[indexes countOfIndexesInRange:NSMakeRange(0, r)];
            [rv _finchSetRow:nr];
            [kept setObject:rv forKey:@(nr)];
        }
        [_rowViews setDictionary:kept];
    }
    BOOL lostSelected = [_selRows intersectsIndexesInRange:NSMakeRange(0, NSUIntegerMax)] &&
                        [[_selRows indexesPassingTest:^BOOL(NSUInteger i, BOOL *stop) {
                            return [indexes containsIndex:i];
                        }] count] > 0;
    NSIndexSet *sel = shift_for_remove(_selRows, indexes);
    NSInteger anchor = _lastRow;
    if (anchor >= 0) {
        if ([indexes containsIndex:anchor])
            anchor = -1;
        else
            anchor -= (NSInteger)[indexes countOfIndexesInRange:NSMakeRange(0, anchor)];
    }
    [self tile];
    [self _finchLayoutRowViews];
    if (lostSelected)
        [self _finchSetSelectedRows:sel anchor:anchor notify:YES];
    else {
        [_selRows removeAllIndexes];
        [_selRows addIndexes:sel];
        _lastRow = anchor;
    }
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)moveRowAtIndex:(NSInteger)oldIndex toIndex:(NSInteger)newIndex
{
    check_updates(self);
    NSInteger n = [self numberOfRows];
    if (oldIndex < 0 || oldIndex >= n || newIndex < 0 || newIndex >= n || oldIndex == newIndex)
        return;
    NSInteger (^map)(NSInteger) = ^NSInteger(NSInteger i) {
        if (i == oldIndex)
            return newIndex;
        if (oldIndex < newIndex && i > oldIndex && i <= newIndex)
            return i - 1;
        if (oldIndex > newIndex && i >= newIndex && i < oldIndex)
            return i + 1;
        return i;
    };
    NSMutableIndexSet *sel = [NSMutableIndexSet indexSet];
    [_selRows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        [sel addIndex:map(i)];
    }];
    [_selRows removeAllIndexes];
    [_selRows addIndexes:sel];
    if (_lastRow >= 0)
        _lastRow = map(_lastRow);
    if ([_rowViews count]) {
        NSMutableDictionary *moved = [NSMutableDictionary dictionary];
        for (NSNumber *k in [_rowViews allKeys]) {
            NSInteger r = map([k integerValue]);
            NSTableRowView *rv = [_rowViews objectForKey:k];
            [rv _finchSetRow:r];
            [moved setObject:rv forKey:@(r)];
        }
        [_rowViews setDictionary:moved];
    }
    [self _finchInvalidateRowGeometry];
    [self _finchLayoutRowViews];
    [self setNeedsDisplay:YES];
}

- (void)hideRowsAtIndexes:(NSIndexSet *)indexes withAnimation:(NSTableViewAnimationOptions)options {}
- (void)unhideRowsAtIndexes:(NSIndexSet *)indexes withAnimation:(NSTableViewAnimationOptions)options {}
- (NSIndexSet *)hiddenRowIndexes { return [NSIndexSet indexSet]; }

#pragma mark - Layout of the table itself

- (void)tile
{
    if (_tv.tiling)
        return;
    _tv.tiling = YES;
    NSSize size = NSMakeSize([self _finchColumnsWidth], [self _finchRowsHeight]);
    NSClipView *clip = (NSClipView *)[self superview];
    if ([clip isKindOfClass:[NSClipView class]]) {
        NSRect b = [clip bounds];
        NSEdgeInsets in = [clip contentInsets];
        size.width = MAX(size.width, NSWidth(b) - in.left - in.right);
        size.height = MAX(size.height, NSHeight(b) - in.top - in.bottom);
    }
    if (!NSEqualSizes(size, [self frame].size)) {
        [super setFrameSize:size];
        [self _finchInvalidateRowGeometry];
    }
    _tiledWidth = size.width;
    NSRect h = [_headerView frame];
    if (_headerView && NSWidth(h) != size.width)
        [_headerView setFrameSize:NSMakeSize(size.width, NSHeight(h) > 0 ? NSHeight(h) : 28)];
    _tv.tiling = NO;
    [self _finchLayoutRowViews];
    [self setNeedsDisplay:YES];
    [_headerView setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    if (!_tv.tiling) {
        [self _finchInvalidateRowGeometry];
        [_headerView setFrameSize:NSMakeSize(size.width, NSHeight([_headerView frame]))];
        [self _finchLayoutRowViews];
        [self setNeedsLayout:YES];
    }
}

- (void)viewWillMoveToSuperview:(NSView *)newSuperview
{
    if (_observedClip) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc removeObserver:self name:NSViewFrameDidChangeNotification object:_observedClip];
        [nc removeObserver:self name:NSViewBoundsDidChangeNotification object:_observedClip];
        _observedClip = nil;
    }
    [super viewWillMoveToSuperview:newSuperview];
}

- (void)viewDidMoveToSuperview
{
    [super viewDidMoveToSuperview];
    NSView *s = [self superview];
    if ([s isKindOfClass:[NSClipView class]]) {
        _observedClip = s;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [s setPostsFrameChangedNotifications:YES];
        [s setPostsBoundsChangedNotifications:YES];
        [nc addObserver:self selector:@selector(_finchClipFrameChanged:) name:NSViewFrameDidChangeNotification object:s];
        [nc addObserver:self selector:@selector(_finchClipBoundsChanged:) name:NSViewBoundsDidChangeNotification object:s];
    }
    [self tile];
}

- (void)_finchClipFrameChanged:(NSNotification *)note
{
    NSClipView *clip = (NSClipView *)_observedClip;
    NSEdgeInsets in = [clip contentInsets];
    CGFloat target = NSWidth([clip bounds]) - in.left - in.right;
    /* the width it had (an autoresizing mask may already have changed the frame) */
    CGFloat columns = [self _finchColumnsWidth], old = _tiledWidth > 0 ? _tiledWidth : NSWidth([self frame]);
    if (target != old && (columns > target || fabs(columns - old) < 0.5))
        [self _finchAutoresizeColumnsBy:target - columns style:_autoresizing notify:YES];
    [self tile];
    [self setNeedsLayout:YES];
}

- (void)_finchClipBoundsChanged:(NSNotification *)note
{
    [self setNeedsLayout:YES];
}

#pragma mark - Column sizing

/* Spread delta over the resizable columns as `style` says, each held to its limits. */
- (void)_finchAutoresizeColumnsBy:(CGFloat)delta style:(NSTableViewColumnAutoresizingStyle)style notify:(BOOL)notify
{
    if (delta == 0 || style == NSTableViewNoColumnAutoresizing)
        return;
    NSMutableArray *cols = [NSMutableArray array];
    for (NSTableColumn *c in _columns)
        if (![c isHidden] && ([c resizingMask] & NSTableColumnAutoresizingMask))
            [cols addObject:c];
    if (![cols count])
        return;
    NSUInteger n = [cols count];
    CGFloat *old = malloc(n * sizeof(CGFloat)), *w = malloc(n * sizeof(CGFloat));
    for (NSUInteger i = 0; i < n; i++)
        old[i] = w[i] = [[cols objectAtIndex:i] width];
    CGFloat left = delta;
    if (style == NSTableViewUniformColumnAutoresizingStyle) {
        BOOL *fixed = calloc(n, sizeof(BOOL));
        for (int pass = 0; pass < 64 && fabs(left) > 1e-9; pass++) {
            NSUInteger open = 0;
            for (NSUInteger i = 0; i < n; i++)
                if (!fixed[i])
                    open++;
            if (!open)
                break;
            CGFloat share = left / open;
            BOOL clamped = NO;
            for (NSUInteger i = 0; i < n; i++) {
                if (fixed[i])
                    continue;
                NSTableColumn *c = [cols objectAtIndex:i];
                CGFloat want = w[i] + share;
                if (want < [c minWidth] || want > [c maxWidth]) {
                    CGFloat got = MAX([c minWidth], MIN([c maxWidth], want));
                    left -= got - w[i];
                    w[i] = got;
                    fixed[i] = YES;
                    clamped = YES;
                }
            }
            if (clamped)
                continue;
            for (NSUInteger i = 0; i < n; i++)
                if (!fixed[i])
                    w[i] += share;
            left = 0;
        }
        free(fixed);
    } else {
        NSInteger start, end, step;
        switch (style) {
        case NSTableViewSequentialColumnAutoresizingStyle:
            start = n - 1, end = -1, step = -1;
            break;
        case NSTableViewReverseSequentialColumnAutoresizingStyle:
            start = 0, end = n, step = 1;
            break;
        case NSTableViewLastColumnOnlyAutoresizingStyle:
            start = n - 1, end = n - 2, step = -1;
            break;
        case NSTableViewFirstColumnOnlyAutoresizingStyle:
        default:
            start = 0, end = 1, step = 1;
            break;
        }
        for (NSInteger i = start; i != end && fabs(left) > 1e-9; i += step) {
            NSTableColumn *c = [cols objectAtIndex:i];
            CGFloat got = MAX([c minWidth], MIN([c maxWidth], w[i] + left));
            left -= got - w[i];
            w[i] = got;
        }
    }
    for (NSUInteger i = 0; i < n; i++)
        [[cols objectAtIndex:i] _finchSetWidthQuietly:w[i]];
    if (notify)
        for (NSUInteger i = 0; i < n; i++)
            if (w[i] != old[i])
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:[self _finchColumnDidResizeName] object:self
                                userInfo:@{@"NSTableColumn" : [cols objectAtIndex:i], @"NSOldWidth" : @(old[i])}];
    free(old);
    free(w);
}

- (CGFloat)_finchFitWidth
{
    NSClipView *clip = (NSClipView *)[self superview];
    if ([clip isKindOfClass:[NSClipView class]])
        return NSWidth([clip bounds]) - [clip contentInsets].left - [clip contentInsets].right;
    return NSWidth([self frame]);
}

- (void)sizeToFit
{
    CGFloat target = [self _finchFitWidth];
    [self _finchAutoresizeColumnsBy:target - [self _finchColumnsWidth] style:NSTableViewUniformColumnAutoresizingStyle
                             notify:YES];
    [self _finchColumnsChanged];
}

- (void)sizeLastColumnToFit
{
    CGFloat target = [self _finchFitWidth];
    [self _finchAutoresizeColumnsBy:target - [self _finchColumnsWidth] style:NSTableViewLastColumnOnlyAutoresizingStyle
                             notify:YES];
    [self _finchColumnsChanged];
}

- (NSTableViewColumnAutoresizingStyle)columnAutoresizingStyle { return _autoresizing; }
- (void)setColumnAutoresizingStyle:(NSTableViewColumnAutoresizingStyle)style { _autoresizing = style; }
- (BOOL)autoresizesAllColumnsToFit { return _autoresizing == NSTableViewUniformColumnAutoresizingStyle; }

- (void)setAutoresizesAllColumnsToFit:(BOOL)flag
{
    _autoresizing = flag ? NSTableViewUniformColumnAutoresizingStyle : NSTableViewLastColumnOnlyAutoresizingStyle;
}

- (void)_finchResizeColumn:(NSInteger)column toWidth:(CGFloat)width
{
    if (column < 0 || column >= (NSInteger)[_columns count])
        return;
    NSTableColumn *c = [_columns objectAtIndex:column];
    if (!([c resizingMask] & NSTableColumnUserResizingMask) || !_tv.resizing)
        return;
    if ([_delegate respondsToSelector:@selector(tableView:sizeToFitWidthOfColumn:)] && width < 0)
        width = [_delegate tableView:self sizeToFitWidthOfColumn:column];
    [c setWidth:width];
}

#pragma mark - Header and corner

- (NSTableHeaderView *)headerView { return _headerView; }

- (void)setHeaderView:(NSTableHeaderView *)headerView
{
    if (headerView == _headerView)
        return;
    if ([_headerView tableView] == self)
        [_headerView setTableView:nil];
    [_headerView removeFromSuperview];
    [_headerView autorelease];
    _headerView = [headerView retain];
    [_headerView setTableView:self];
    NSScrollView *sv = [self enclosingScrollView];
    [sv tile];
    [self tile];
}

- (NSView *)cornerView
{
    /* overlay scrollers leave no corner */
    NSScrollView *sv = [self enclosingScrollView];
    if (sv && [sv scrollerStyle] == NSScrollerStyleOverlay)
        return nil;
    return _cornerView;
}

- (void)setCornerView:(NSView *)cornerView
{
    [_cornerView autorelease];
    _cornerView = [cornerView retain];
}

#pragma mark - Appearance

- (NSColor *)backgroundColor { return _backgroundColor ?: [NSColor controlBackgroundColor]; }

- (void)setBackgroundColor:(NSColor *)color
{
    [_backgroundColor autorelease];
    _backgroundColor = [color retain];
    [self setNeedsDisplay:YES];
}

- (NSColor *)gridColor { return _gridColor ?: [NSColor separatorColor]; }

- (void)setGridColor:(NSColor *)color
{
    [_gridColor autorelease];
    _gridColor = [color retain];
    [self setNeedsDisplay:YES];
}

- (NSTableViewGridLineStyle)gridStyleMask { return _gridMask; }

- (void)setGridStyleMask:(NSTableViewGridLineStyle)mask
{
    _gridMask = mask;
    [self setNeedsDisplay:YES];
}

- (BOOL)usesAlternatingRowBackgroundColors { return _tv.alternating; }

- (void)setUsesAlternatingRowBackgroundColors:(BOOL)flag
{
    _tv.alternating = flag;
    [self setNeedsDisplay:YES];
}

- (NSTableViewSelectionHighlightStyle)selectionHighlightStyle { return _highlightStyle; }

- (void)setSelectionHighlightStyle:(NSTableViewSelectionHighlightStyle)style
{
    _highlightStyle = style;
    for (NSTableRowView *rv in [_rowViews allValues])
        [rv setSelectionHighlightStyle:style];
    [self setNeedsDisplay:YES];
}

- (NSTableViewDraggingDestinationFeedbackStyle)draggingDestinationFeedbackStyle { return _dragStyle; }
- (void)setDraggingDestinationFeedbackStyle:(NSTableViewDraggingDestinationFeedbackStyle)style { _dragStyle = style; }
- (BOOL)allowsColumnReordering { return _tv.reordering; }
- (void)setAllowsColumnReordering:(BOOL)flag { _tv.reordering = flag; }
- (BOOL)allowsColumnResizing { return _tv.resizing; }
- (void)setAllowsColumnResizing:(BOOL)flag { _tv.resizing = flag; }
- (BOOL)allowsTypeSelect { return _tv.typeSelect; }
- (void)setAllowsTypeSelect:(BOOL)flag { _tv.typeSelect = flag; }
- (BOOL)floatsGroupRows { return _tv.floatsGroupRows; }
- (void)setFloatsGroupRows:(BOOL)flag { _tv.floatsGroupRows = flag; }
- (BOOL)autosaveTableColumns { return _tv.autosaveColumns; }
- (void)setAutosaveTableColumns:(BOOL)flag { _tv.autosaveColumns = flag; }
- (NSTableViewAutosaveName)autosaveName { return _autosaveName; }

- (void)setAutosaveName:(NSTableViewAutosaveName)name
{
    [_autosaveName autorelease];
    _autosaveName = [name copy];
}

- (BOOL)verticalMotionCanBeginDrag { return _tv.verticalMotion; }
- (void)setVerticalMotionCanBeginDrag:(BOOL)flag { _tv.verticalMotion = flag; }
- (BOOL)usesStaticContents { return _tv.staticContents; }
- (void)setUsesStaticContents:(BOOL)flag { _tv.staticContents = flag; }
- (NSUserInterfaceLayoutDirection)userInterfaceLayoutDirection { return NSUserInterfaceLayoutDirectionLeftToRight; }
- (SEL)doubleAction { return _doubleAction; }
- (void)setDoubleAction:(SEL)action { _doubleAction = action; }
- (NSInteger)clickedRow { return _clickedRow; }
- (NSInteger)clickedColumn { return _clickedColumn; }
- (NSInteger)editedRow { return _editedRow; }
- (NSInteger)editedColumn { return _editedColumn; }
- (NSInteger)focusedColumn { return _focusedColumn; }
- (void)setFocusedColumn:(NSInteger)column { _focusedColumn = column; }
- (BOOL)shouldFocusCell:(NSCell *)cell atColumn:(NSInteger)column row:(NSInteger)row { return [cell isEditable]; }
- (void)setDraggingSourceOperationMask:(NSDragOperation)mask forLocal:(BOOL)isLocal {}
- (void)setDropRow:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {}
- (BOOL)canDragRowsWithIndexes:(NSIndexSet *)rows atPoint:(NSPoint)point { return YES; }

- (NSImage *)indicatorImageInTableColumn:(NSTableColumn *)column { return [_indicators objectForKey:column]; }

- (void)setIndicatorImage:(NSImage *)image inTableColumn:(NSTableColumn *)column
{
    if (!column)
        return;
    if (image)
        [_indicators setObject:image forKey:column];
    else
        [_indicators removeObjectForKey:column];
    [_headerView setNeedsDisplay:YES];
}

- (NSTableColumn *)highlightedTableColumn { return _highlighted; }

- (void)setHighlightedTableColumn:(NSTableColumn *)column
{
    _highlighted = column;
    [_headerView setNeedsDisplay:YES];
    [self setNeedsDisplay:YES];
}

#pragma mark - Sorting

- (NSArray<NSSortDescriptor *> *)sortDescriptors { return [[_sortDescriptors retain] autorelease]; }

- (void)setSortDescriptors:(NSArray<NSSortDescriptor *> *)descriptors
{
    if (!descriptors)
        descriptors = @[];
    if ([descriptors isEqualToArray:_sortDescriptors])
        return;
    NSArray *old = [_sortDescriptors autorelease];
    _sortDescriptors = [descriptors copy];
    [_headerView setNeedsDisplay:YES];
    _FinchBinding *b = FinchBindingFor(self, NSSortDescriptorsBinding);
    if (b && !_tv.pushingSort) {
        _tv.pushingSort = YES;
        [b push:_sortDescriptors];
        _tv.pushingSort = NO;
    }
    [self _finchSortDescriptorsChanged:old];
}

/* A click on a column's header: sort by it (or reverse its sort), as Apple's does with the column's prototype. */
- (void)_finchHeaderClickedColumn:(NSInteger)column event:(NSEvent *)event
{
    if (column < 0 || column >= (NSInteger)[_columns count])
        return;
    NSTableColumn *c = [_columns objectAtIndex:column];
    if (_tv.columnSelection && ![c sortDescriptorPrototype]) {
        BOOL extend = ([event modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagShift)) != 0;
        [self selectColumnIndexes:[NSIndexSet indexSetWithIndex:column] byExtendingSelection:extend];
    }
    NSSortDescriptor *proto = [c sortDescriptorPrototype];
    if (proto) {
        NSMutableArray *sorts = [[_sortDescriptors mutableCopy] autorelease];
        NSSortDescriptor *first = [sorts firstObject];
        NSSortDescriptor *next = proto;
        if (first && [[first key] isEqualToString:[proto key]])
            next = [first reversedSortDescriptor];
        NSIndexSet *dup = [sorts indexesOfObjectsPassingTest:^BOOL(NSSortDescriptor *d, NSUInteger i, BOOL *stop) {
            return [[d key] isEqualToString:[proto key]];
        }];
        [sorts removeObjectsAtIndexes:dup];
        [sorts insertObject:next atIndex:0];
        [self setSortDescriptors:sorts];
    }
    [self _finchDidClickColumn:c];
}

#pragma mark - Selection

- (BOOL)allowsEmptySelection { return _tv.emptySelection; }
- (void)setAllowsEmptySelection:(BOOL)flag { _tv.emptySelection = flag; }
- (BOOL)allowsMultipleSelection { return _tv.multipleSelection; }
- (void)setAllowsMultipleSelection:(BOOL)flag { _tv.multipleSelection = flag; }
- (BOOL)allowsColumnSelection { return _tv.columnSelection; }
- (void)setAllowsColumnSelection:(BOOL)flag { _tv.columnSelection = flag; }

- (NSIndexSet *)selectedRowIndexes { return [[_selRows copy] autorelease]; }
- (NSIndexSet *)selectedColumnIndexes { return [[_selCols copy] autorelease]; }
- (NSInteger)numberOfSelectedRows { return (NSInteger)[_selRows count]; }
- (NSInteger)numberOfSelectedColumns { return (NSInteger)[_selCols count]; }
- (BOOL)isRowSelected:(NSInteger)row { return row >= 0 && [_selRows containsIndex:row]; }
- (BOOL)isColumnSelected:(NSInteger)column { return column >= 0 && [_selCols containsIndex:column]; }

- (NSInteger)selectedRow
{
    if (![_selRows count])
        return -1;
    if (_lastRow >= 0 && [_selRows containsIndex:_lastRow])
        return _lastRow;
    return (NSInteger)[_selRows firstIndex];
}

- (NSInteger)selectedColumn
{
    if (![_selCols count])
        return -1;
    if (_lastCol >= 0 && [_selCols containsIndex:_lastCol])
        return _lastCol;
    return (NSInteger)[_selCols lastIndex];
}

- (void)_finchPostSelectionChange
{
    [[NSNotificationCenter defaultCenter] postNotificationName:[self _finchSelectionDidChangeName] object:self];
}

/* Show the selection: row views' states, the selection's drawing. */
- (void)_finchSelectionShown
{
    for (NSNumber *k in _rowViews) {
        NSTableRowView *rv = [_rowViews objectForKey:k];
        NSInteger r = [k integerValue];
        [rv setSelected:[_selRows containsIndex:r]];
        [rv setPreviousRowSelected:r > 0 && [_selRows containsIndex:r - 1]];
        [rv setNextRowSelected:[_selRows containsIndex:r + 1]];
    }
    [self setNeedsDisplay:YES];
}

- (void)_finchSetSelectedRows:(NSIndexSet *)rows anchor:(NSInteger)anchor notify:(BOOL)notify
{
    BOOL colsChanged = [_selCols count] > 0;
    if ([rows isEqualToIndexSet:_selRows] && !colsChanged) {
        if (anchor >= 0 || ![rows count])
            _lastRow = anchor;
        return;
    }
    [_selCols removeAllIndexes];
    _lastCol = -1;
    [_selRows removeAllIndexes];
    [_selRows addIndexes:rows];
    _lastRow = anchor;
    [self _finchSelectionShown];
    _FinchBinding *b = FinchBindingFor(self, NSSelectionIndexesBinding);
    if (b && !_tv.pushingSelection) {
        _tv.pushingSelection = YES;
        [b push:[[_selRows copy] autorelease]];
        _tv.pushingSelection = NO;
    }
    if (notify)
        [self _finchPostSelectionChange];
}

/* Set the selection without telling anyone (the outline view keeps its items selected as rows move). */
- (void)_finchQuietlySelect:(NSIndexSet *)rows anchor:(NSInteger)anchor
{
    [_selRows removeAllIndexes];
    [_selRows addIndexes:rows];
    _lastRow = anchor;
    [self _finchSelectionShown];
}

- (void)selectRowIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend
{
    if (!indexes)
        indexes = [NSIndexSet indexSet];
    if ([indexes count] && (NSInteger)[indexes lastIndex] >= [self numberOfRows])
        return;
    NSMutableIndexSet *s = extend ? [[_selRows mutableCopy] autorelease] : [NSMutableIndexSet indexSet];
    [s addIndexes:indexes];
    NSInteger anchor = [indexes count] ? (NSInteger)[indexes lastIndex] : (extend ? _lastRow : -1);
    [self _finchSetSelectedRows:s anchor:anchor notify:YES];
}

- (void)selectRow:(NSInteger)row byExtendingSelection:(BOOL)extend
{
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:extend];
}

- (void)deselectRow:(NSInteger)row
{
    if (![_selRows containsIndex:row])
        return;
    if (!_tv.emptySelection && [_selRows count] == 1)
        return;
    NSMutableIndexSet *s = [[_selRows mutableCopy] autorelease];
    [s removeIndex:row];
    NSInteger anchor = _lastRow == row ? ([s count] ? (NSInteger)[s lastIndex] : -1) : _lastRow;
    [self _finchSetSelectedRows:s anchor:anchor notify:YES];
}

- (void)selectColumnIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend
{
    if (!_tv.columnSelection)
        return;
    NSMutableIndexSet *s = extend ? [[_selCols mutableCopy] autorelease] : [NSMutableIndexSet indexSet];
    [s addIndexes:indexes];
    if ([s isEqualToIndexSet:_selCols] && ![_selRows count])
        return;
    [_selRows removeAllIndexes];
    _lastRow = -1;
    [_selCols removeAllIndexes];
    [_selCols addIndexes:s];
    _lastCol = [indexes count] ? (NSInteger)[indexes lastIndex] : _lastCol;
    [self _finchSelectionShown];
    [_headerView setNeedsDisplay:YES];
    [self _finchPostSelectionChange];
}

- (void)selectColumn:(NSInteger)column byExtendingSelection:(BOOL)extend
{
    [self selectColumnIndexes:[NSIndexSet indexSetWithIndex:column] byExtendingSelection:extend];
}

- (void)deselectColumn:(NSInteger)column
{
    if (![_selCols containsIndex:column])
        return;
    [_selCols removeIndex:column];
    if (_lastCol == column)
        _lastCol = -1;
    [self _finchSelectionShown];
    [_headerView setNeedsDisplay:YES];
    [self _finchPostSelectionChange];
}

- (void)selectAll:(id)sender
{
    if (!_tv.multipleSelection && !_tv.columnSelection)
        return;
    if (![self _finchSelectionShouldChange])
        return;
    NSInteger n = [self numberOfRows];
    NSIndexSet *all = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, n)];
    all = [self _finchProposedSelection:all];
    [self _finchSetSelectedRows:all anchor:[all count] ? (NSInteger)[all lastIndex] : -1 notify:YES];
}

- (void)deselectAll:(id)sender
{
    if (!_tv.emptySelection)
        return;
    if (![self _finchSelectionShouldChange])
        return;
    if (![_selRows count] && ![_selCols count])
        return;
    [_selCols removeAllIndexes];
    [self _finchSetSelectedRows:[NSIndexSet indexSet] anchor:-1 notify:YES];
}

#pragma mark - Cells

- (NSCell *)preparedCellAtColumn:(NSInteger)column row:(NSInteger)row
{
    NSTableColumn *c = [_columns objectAtIndex:column];
    NSCell *cell = [c dataCellForRow:row];
    if ([_delegate respondsToSelector:@selector(tableView:dataCellForTableColumn:row:)]) {
        NSCell *d = [_delegate tableView:self dataCellForTableColumn:c row:row];
        if (d)
            cell = d;
    }
    [cell setObjectValue:[self _finchObjectValueForColumn:c row:row]];
    [cell setHighlighted:[_selRows containsIndex:row] || [_selCols containsIndex:column]];
    [cell setBackgroundStyle:[cell isHighlighted] && [self _finchEmphasized] ? NSBackgroundStyleEmphasized
                                                                              : NSBackgroundStyleNormal];
    [self _finchWillDisplayCell:cell column:c row:row];
    return cell;
}

#pragma mark - View-based tables

- (NSDictionary<NSUserInterfaceItemIdentifier, NSNib *> *)registeredNibsByIdentifier
{
    return [[_nibs copy] autorelease];
}

- (void)registerNib:(NSNib *)nib forIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    if (!identifier)
        return;
    if (nib)
        [_nibs setObject:nib forKey:identifier];
    else
        [_nibs removeObjectForKey:identifier];
}

- (__kindof NSView *)makeViewWithIdentifier:(NSUserInterfaceItemIdentifier)identifier owner:(id)owner
{
    if (!identifier)
        return nil;
    NSMutableArray *queue = [_reuse objectForKey:identifier];
    if ([queue count]) {
        NSView *v = [[[queue lastObject] retain] autorelease];
        [queue removeLastObject];
        return v;
    }
    NSNib *nib = [_nibs objectForKey:identifier];
    if (!nib)
        return nil;
    NSArray *top = nil;
    if (![nib instantiateWithOwner:owner topLevelObjects:&top])
        return nil;
    for (id o in top)
        if ([o isKindOfClass:[NSView class]]) {
            if (![o identifier])
                [o setIdentifier:identifier];
            return o;
        }
    return nil;
}

- (void)_finchEnqueueView:(NSView *)view
{
    NSString *ident = [view identifier];
    if (!ident)
        return;
    NSMutableArray *q = [_reuse objectForKey:ident];
    if (!q) {
        q = [NSMutableArray array];
        [_reuse setObject:q forKey:ident];
    }
    [q addObject:view];
}

- (NSRect)_finchVisibleRows
{
    return [self visibleRect];
}

- (BOOL)_finchRowIsVisible:(NSInteger)row
{
    NSRange r = [self rowsInRect:NSIntersectionRect([self visibleRect], [self bounds])];
    return NSLocationInRange(row, r);
}

- (NSTableRowView *)_finchRowViewIfAny:(NSInteger)row { return [_rowViews objectForKey:@(row)]; }

/* The cell view's frame in its row view. */
- (NSRect)_finchCellViewFrame:(NSInteger)column row:(NSInteger)row group:(BOOL)group
{
    NSRect rr = [self rectOfRow:row];
    if (group) {
        NSTableViewStyle s = [self _finchStyle];
        CGFloat pad = s == NSTableViewStylePlain ? floor(_spacing.width / 2) : 6;
        CGFloat x = side_inset(self) + pad;
        return NSMakeRect(x, 0, MAX(0, NSWidth(rr) - 2 * x), NSHeight(rr));
    }
    NSRect f = [self frameOfCellAtColumn:column row:row];
    return NSMakeRect(NSMinX(f), 0, NSWidth(f), NSHeight(rr));
}

- (void)_finchGiveObjectValue:(NSView *)view column:(NSTableColumn *)column row:(NSInteger)row
{
    if (!view || ![view respondsToSelector:@selector(setObjectValue:)])
        return;
    if ([self _finchProvidesObjectValues])
        [(id)view setObjectValue:[self _finchObjectValueForColumn:column row:row]];
}

- (NSTableRowView *)_finchMakeRowView:(NSInteger)row
{
    NSTableRowView *rv = [_rowViews objectForKey:@(row)];
    if (rv)
        return rv;
    rv = [self _finchDelegateRowViewForRow:row];
    if (!rv)
        rv = [[[NSTableRowView alloc] initWithFrame:NSZeroRect] autorelease];
    BOOL group = [self _finchIsGroupRow:row];
    [rv setFrame:[self rectOfRow:row]];
    [rv _finchSetTableView:self row:row];
    [rv setGroupRowStyle:group];
    [rv setSelectionHighlightStyle:_highlightStyle];
    [rv setSelected:[_selRows containsIndex:row]];
    [rv setEmphasized:[self _finchEmphasized]];
    NSMutableArray *views = [NSMutableArray array];
    if (group) {
        NSView *v = [self _finchDelegateViewForColumn:nil row:row];
        [self _finchGiveObjectValue:v column:nil row:row];
        if (v)
            [views addObject:v];
    } else {
        for (NSUInteger c = 0; c < [_columns count]; c++) {
            NSTableColumn *col = [_columns objectAtIndex:c];
            NSView *v = [col isHidden] ? nil : [self _finchDelegateViewForColumn:col row:row];
            [self _finchGiveObjectValue:v column:col row:row];
            [views addObject:v ?: (id)[NSNull null]];
        }
    }
    [rv _finchSetCellViews:views];
    [self _finchPlaceCellViewsOf:rv row:row];
    [_rowViews setObject:rv forKey:@(row)];
    [self addSubview:rv];
    [self _finchDidAddRowView:rv row:row];
    return rv;
}

- (void)_finchPlaceCellViewsOf:(NSTableRowView *)rv row:(NSInteger)row
{
    NSArray *views = [rv _finchCellViews];
    BOOL group = [rv isGroupRowStyle] && [views count] == 1 && [_columns count] != 1 ? YES : [rv isGroupRowStyle];
    for (NSUInteger c = 0; c < [views count]; c++) {
        NSView *v = [views objectAtIndex:c];
        if ((id)v == [NSNull null])
            continue;
        [v setFrame:[self _finchCellViewFrame:c row:row group:group]];
        if ([v superview] != rv)
            [rv addSubview:v];
        if ([v respondsToSelector:@selector(setBackgroundStyle:)])
            [(id)v setBackgroundStyle:[rv interiorBackgroundStyle]];
    }
}

- (void)_finchReloadViewInRowView:(NSTableRowView *)rv column:(NSUInteger)c row:(NSInteger)row
{
    NSMutableArray *views = [[[rv _finchCellViews] mutableCopy] autorelease];
    if (c >= [views count] || c >= [_columns count])
        return;
    NSView *old = [views objectAtIndex:c];
    if ((id)old != [NSNull null])
        [self _finchEnqueueView:old];
    NSTableColumn *col = [_columns objectAtIndex:c];
    NSView *v = [self _finchDelegateViewForColumn:col row:row];
    [self _finchGiveObjectValue:v column:col row:row];
    NSMutableArray *q = [_reuse objectForKey:[old identifier]];
    if ((id)old != [NSNull null] && [q indexOfObjectIdenticalTo:old] != NSNotFound)
        [q removeObjectIdenticalTo:old];
    if (v != old && (id)old != [NSNull null])
        [old removeFromSuperview];
    [views replaceObjectAtIndex:c withObject:v ?: (id)[NSNull null]];
    [rv _finchSetCellViews:views];
    [self _finchPlaceCellViewsOf:rv row:row];
}

- (void)_finchRemoveRowView:(NSInteger)row enqueue:(BOOL)enqueue
{
    NSTableRowView *rv = [[[_rowViews objectForKey:@(row)] retain] autorelease];
    if (!rv)
        return;
    [_rowViews removeObjectForKey:@(row)];
    if (enqueue)
        for (NSView *v in [rv _finchCellViews])
            if ((id)v != [NSNull null]) {
                [v removeFromSuperview];
                [self _finchEnqueueView:v];
            }
    [rv removeFromSuperview];
    [self _finchDidRemoveRowView:rv row:row];
}

- (void)_finchRemoveAllRowViews
{
    for (NSNumber *k in [[_rowViews allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [self _finchRemoveRowView:[k integerValue] enqueue:NO];
}

/* Row views follow the rows' rects (after a change of geometry). */
- (void)_finchLayoutRowViews
{
    if (![_rowViews count])
        return;
    NSInteger n = [self numberOfRows];
    for (NSNumber *k in [_rowViews allKeys]) {
        NSInteger r = [k integerValue];
        NSTableRowView *rv = [_rowViews objectForKey:k];
        if (r >= n)
            continue;
        [rv setFrame:[self rectOfRow:r]];
        [self _finchPlaceCellViewsOf:rv row:r];
    }
}

/* Make views for the visible rows, let go of the others. */
- (void)_finchRealizeRows
{
    if (_tv.realizing || ![self _finchIsViewBased])
        return;
    _tv.realizing = YES;
    /* row heights (group rows) are worked out again as views are made */
    [self _finchInvalidateRowGeometry];
    [self tile];
    NSInteger n = [self numberOfRows];
    NSRange vis = [self rowsInRect:NSIntersectionRect([self visibleRect], [self bounds])];
    for (NSNumber *k in [[_rowViews allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSInteger r = [k integerValue];
        if (r >= n || !NSLocationInRange(r, vis))
            [self _finchRemoveRowView:r enqueue:YES];
    }
    for (NSUInteger r = vis.location; r < NSMaxRange(vis); r++)
        [self _finchMakeRowView:r];
    _tv.realizing = NO;
}

- (void)layout
{
    [super layout];
    [self _finchRealizeRows];
}

- (void)viewWillDraw
{
    [self _finchRealizeRows];
    [super viewWillDraw];
}

- (NSTableRowView *)rowViewAtRow:(NSInteger)row makeIfNecessary:(BOOL)make
{
    if (row < 0 || row >= [self numberOfRows])
        return nil;
    NSTableRowView *rv = [_rowViews objectForKey:@(row)];
    if (rv || !make)
        return rv;
    [self _finchRealizeRows];
    rv = [_rowViews objectForKey:@(row)];
    return rv ?: [self _finchMakeRowView:row];
}

- (__kindof NSView *)viewAtColumn:(NSInteger)column row:(NSInteger)row makeIfNecessary:(BOOL)make
{
    NSTableRowView *rv = [self rowViewAtRow:row makeIfNecessary:make];
    if (!rv)
        return nil;
    return [rv viewAtColumn:column];
}

- (NSInteger)rowForView:(NSView *)view
{
    for (NSView *v = view; v; v = [v superview]) {
        if ([v isKindOfClass:[NSTableRowView class]] && [v superview] == self)
            return [(NSTableRowView *)v _finchRow];
        if (v == self)
            break;
    }
    return -1;
}

- (NSInteger)columnForView:(NSView *)view
{
    NSView *child = nil;
    for (NSView *v = view; v; child = v, v = [v superview]) {
        if ([v isKindOfClass:[NSTableRowView class]] && [v superview] == self) {
            NSTableRowView *rv = (NSTableRowView *)v;
            if ([rv isGroupRowStyle] && [[rv _finchCellViews] count] == 1 && [_columns count] != 1)
                return -1;
            NSUInteger i = [[rv _finchCellViews] indexOfObjectIdenticalTo:child];
            return i == NSNotFound ? -1 : (NSInteger)i;
        }
        if (v == self)
            break;
    }
    return -1;
}

- (void)enumerateAvailableRowViewsUsingBlock:(void(NS_NOESCAPE ^)(__kindof NSTableRowView *, NSInteger))handler
{
    for (NSNumber *k in [[_rowViews allKeys] sortedArrayUsingSelector:@selector(compare:)])
        handler([_rowViews objectForKey:k], [k integerValue]);
}

- (NSView *)hitTest:(NSPoint)point
{
    return [super hitTest:point];
}

#pragma mark - Scrolling

/* Outside a window, Apple's tables still see what their clip view shows. */
- (NSRect)visibleRect
{
    return FinchClippedVisibleRect(self);
}

- (void)scrollRowToVisible:(NSInteger)row
{
    NSRect r = [self rectOfRow:row];
    if (NSIsEmptyRect(r))
        return;
    NSClipView *clip = (NSClipView *)[self superview];
    if (![clip isKindOfClass:[NSClipView class]])
        return;
    NSRect b = [clip bounds];
    NSEdgeInsets in = [clip contentInsets];
    CGFloat top = NSMinY(b) + in.top, bottom = NSMaxY(b) - in.bottom;
    NSPoint o = b.origin;
    if (NSMinY(r) < top)
        o.y = NSMinY(r) - in.top;
    else if (NSMaxY(r) > bottom)
        o.y = NSMaxY(r) + in.bottom - NSHeight(b);
    else
        return;
    [clip scrollToPoint:[clip constrainScrollPoint:o]];
    [[clip superview] reflectScrolledClipView:clip];
    [self setNeedsLayout:YES];
}

- (void)scrollColumnToVisible:(NSInteger)column
{
    NSRect r = [self rectOfColumn:column];
    if (NSIsEmptyRect(r))
        return;
    NSClipView *clip = (NSClipView *)[self superview];
    if (![clip isKindOfClass:[NSClipView class]])
        return;
    NSRect b = [clip bounds];
    NSPoint o = b.origin;
    if (NSMinX(r) < NSMinX(b))
        o.x = NSMinX(r);
    else if (NSMaxX(r) > NSMaxX(b))
        o.x = NSMaxX(r) - NSWidth(b);
    else
        return;
    [clip scrollToPoint:[clip constrainScrollPoint:o]];
    [[clip superview] reflectScrolledClipView:clip];
}

#pragma mark - Drawing

- (BOOL)_finchEmphasized
{
    NSWindow *w = [self window];
    if (!w || ![w isKeyWindow])
        return NO;
    NSResponder *f = [w firstResponder];
    return f == self || ([f isKindOfClass:[NSView class]] && [(NSView *)f isDescendantOf:self]);
}

- (void)drawRect:(NSRect)dirty
{
    [self drawBackgroundInClipRect:dirty];
    if ([self _finchIsViewBased]) {
        [self drawGridInClipRect:dirty];
        return;
    }
    [self highlightSelectionInClipRect:dirty];
    [self drawGridInClipRect:dirty];
    NSRange rows = [self rowsInRect:dirty];
    for (NSUInteger r = rows.location; r < NSMaxRange(rows); r++)
        [self drawRow:r clipRect:dirty];
}

- (void)drawBackgroundInClipRect:(NSRect)clip
{
    [[self backgroundColor] setFill];
    NSRectFill(clip);
    if (!_tv.alternating)
        return;
    NSArray *colors = [NSColor alternatingContentBackgroundColors];
    NSInteger n = [self numberOfRows];
    CGFloat h = _rowHeight + _spacing.height;
    compute_rows(self);
    /* stripes continue below the last row at the standard height */
    CGFloat y0 = n ? row_top(self, 0) : top_inset(self);
    NSInteger first = MAX(0, (NSInteger)floor((NSMinY(clip) - y0) / MAX(h, 1)));
    NSRange vis = [self rowsInRect:clip];
    for (NSUInteger r = vis.location; r < NSMaxRange(vis); r++) {
        CGFloat top = row_top(self, r), bottom = row_top(self, r + 1);
        [[colors objectAtIndex:r % [colors count]] setFill];
        NSRectFill(NSIntersectionRect(clip, NSMakeRect(NSMinX(clip), top, NSWidth(clip), bottom - top)));
    }
    CGFloat y = n ? row_top(self, n) : y0;
    for (NSInteger r = MAX(n, first); y < NSMaxY(clip) && h > 0; r++) {
        CGFloat top = y0 + (r - n) * h + (n ? row_top(self, n) - y0 : 0);
        y = top + h;
        if (y <= NSMinY(clip))
            continue;
        [[colors objectAtIndex:r % [colors count]] setFill];
        NSRectFill(NSIntersectionRect(clip, NSMakeRect(NSMinX(clip), top, NSWidth(clip), h)));
    }
}

/* The selection's shape: inset tables round it inside their margins. */
- (NSRect)_finchSelectionRectForRow:(NSInteger)row
{
    NSRect r = [self rectOfRow:row];
    CGFloat inset = side_inset(self);
    return NSMakeRect(NSMinX(r) + inset, NSMinY(r), NSWidth(r) - 2 * inset, NSHeight(r));
}

- (void)highlightSelectionInClipRect:(NSRect)clip
{
    if (_highlightStyle == NSTableViewSelectionHighlightStyleNone)
        return;
    NSColor *c = FinchTableSelectionColor([self _finchEmphasized]);
    BOOL rounded = side_inset(self) > 0;
    [_selRows enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
        NSRect sr = [self _finchSelectionRectForRow:r];
        if (!NSIntersectsRect(sr, clip))
            return;
        [c setFill];
        if (rounded) {
            BOOL above = r > 0 && [_selRows containsIndex:r - 1], below = [_selRows containsIndex:r + 1];
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:sr xRadius:5 yRadius:5];
            [p fill];
            if (above)
                NSRectFill(NSMakeRect(NSMinX(sr), NSMinY(sr), NSWidth(sr), NSHeight(sr) / 2));
            if (below)
                NSRectFill(NSMakeRect(NSMinX(sr), NSMidY(sr), NSWidth(sr), NSHeight(sr) / 2));
        } else {
            NSRectFill(sr);
        }
    }];
    [_selCols enumerateIndexesUsingBlock:^(NSUInteger col, BOOL *stop) {
        [c setFill];
        NSRectFill(NSIntersectionRect([self rectOfColumn:col], clip));
    }];
}

- (void)drawGridInClipRect:(NSRect)clip
{
    if (!_gridMask)
        return;
    [[self gridColor] setFill];
    CGFloat px = 1 / MAX(1, FinchViewBackingScale(self));
    if (_gridMask & NSTableViewSolidVerticalGridLineMask) {
        for (NSInteger i = 0; i < (NSInteger)[_columns count]; i++) {
            NSRect r = [self rectOfColumn:i];
            if (NSWidth(r) <= 0)
                continue;
            NSRectFill(NSIntersectionRect(clip, NSMakeRect(NSMaxX(r) - px, NSMinY(clip), px, NSHeight(clip))));
        }
    }
    if (_gridMask & (NSTableViewSolidHorizontalGridLineMask | NSTableViewDashedHorizontalGridLineMask)) {
        NSRange rows = [self rowsInRect:clip];
        for (NSUInteger r = rows.location; r < NSMaxRange(rows); r++) {
            NSRect rr = [self rectOfRow:r];
            NSRectFill(NSIntersectionRect(clip, NSMakeRect(NSMinX(clip), NSMaxY(rr) - px, NSWidth(clip), px)));
        }
    }
}

- (void)_finchDrawRow:(NSInteger)row clipRect:(NSRect)clip
{
    BOOL emphasized = [self _finchEmphasized];
    for (NSInteger c = 0; c < (NSInteger)[_columns count]; c++) {
        NSRect f = [self frameOfCellAtColumn:c row:row];
        if (NSIsEmptyRect(f) || !NSIntersectsRect(f, clip))
            continue;
        if (_editedRow == row && _editedColumn == c && _fieldEditor)
            continue;
        NSCell *cell = [self preparedCellAtColumn:c row:row];
        if ([cell isHighlighted] && emphasized && [cell isKindOfClass:[NSTextFieldCell class]]) {
            NSTextFieldCell *copy = [[cell copy] autorelease];
            [copy setTextColor:[NSColor alternateSelectedControlTextColor]];
            [copy setHighlighted:NO];
            cell = copy;
        }
        BOOL wasHighlighted = [cell isHighlighted];
        [cell setHighlighted:NO];
        [cell drawWithFrame:f inView:self];
        [cell setHighlighted:wasHighlighted];
    }
}

- (void)drawRow:(NSInteger)row clipRect:(NSRect)clip
{
    [self _finchDrawRow:row clipRect:clip];
}

#pragma mark - Events

- (BOOL)becomeFirstResponder
{
    [self setNeedsDisplay:YES];
    /* the window makes the table its first responder once this returns */
    [self performSelector:@selector(_finchEmphasisChanged) withObject:nil afterDelay:0];
    return YES;
}

- (BOOL)resignFirstResponder
{
    [self setNeedsDisplay:YES];
    [self performSelector:@selector(_finchEmphasisChanged) withObject:nil afterDelay:0];
    return YES;
}

- (void)_finchEmphasisChanged
{
    BOOL e = [self _finchEmphasized];
    for (NSTableRowView *rv in [_rowViews allValues]) {
        [rv setEmphasized:e];
        [self _finchPlaceCellViewsOf:rv row:[rv _finchRow]];
    }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

/* A click (and drag) selects as the Finder does: a plain click selects the row, Command toggles, Shift extends. */
- (NSIndexSet *)_finchSelectionForClickAt:(NSInteger)row modifiers:(NSEventModifierFlags)mods anchor:(NSInteger)anchor
                                     base:(NSIndexSet *)base
{
    NSMutableIndexSet *s;
    BOOL multi = _tv.multipleSelection;
    if (row < 0)
        return _tv.emptySelection ? [NSIndexSet indexSet] : base;
    if (multi && (mods & NSEventModifierFlagCommand)) {
        s = [[base mutableCopy] autorelease];
        if ([s containsIndex:row] && (_tv.emptySelection || [s count] > 1))
            [s removeIndex:row];
        else
            [s addIndex:row];
    } else if (multi && (mods & NSEventModifierFlagShift) && anchor >= 0) {
        s = [[base mutableCopy] autorelease];
        [s addIndexesInRange:NSMakeRange(MIN(anchor, row), labs(anchor - row) + 1)];
    } else {
        s = [NSMutableIndexSet indexSetWithIndex:row];
    }
    return s;
}

- (BOOL)_finchMouseDownInOutlineCell:(NSEvent *)event row:(NSInteger)row { return NO; }

- (void)mouseDown:(NSEvent *)event
{
    NSWindow *w = [self window];
    if ([self acceptsFirstResponder] && [w firstResponder] != self && [w makeFirstResponder:self])
        [self _finchEmphasisChanged];
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger row = [self rowAtPoint:p], col = [self columnAtPoint:p];
    _clickedRow = row;
    _clickedColumn = col;
    if (row >= 0 && [self _finchMouseDownInOutlineCell:event row:row])
        return;
    if ([event clickCount] >= 2 && row >= 0 && col >= 0) {
        NSTableColumn *tc = [_columns objectAtIndex:col];
        if (![self _finchIsViewBased] && [tc isEditable] && [[tc dataCell] isEditable] &&
            [self _finchShouldEditColumn:tc row:row] &&
            ([_dataSource respondsToSelector:@selector(tableView:setObjectValue:forTableColumn:row:)] ||
             [tc _finchHasValueBinding])) {
            [self editColumn:col row:row withEvent:event select:YES];
            return;
        }
        if (_doubleAction)
            [self sendAction:_doubleAction to:[self target]];
        return;
    }
    if (![self _finchSelectionShouldChange])
        return;
    NSIndexSet *base = [[_selRows copy] autorelease];
    NSEventModifierFlags mods = [event modifierFlags];
    NSInteger anchor = [self selectedRow];
    NSIndexSet *proposed = [self _finchSelectionForClickAt:row modifiers:mods anchor:anchor base:base];
    proposed = [self _finchProposedSelection:proposed];
    [self _finchSetSelectedRows:proposed anchor:row >= 0 && [proposed containsIndex:row] ? row : [self selectedRow]
                         notify:NO];
    BOOL changed = ![proposed isEqualToIndexSet:base];
    if (changed)
        [[NSNotificationCenter defaultCenter] postNotificationName:[self _finchSelectionIsChangingName] object:self];
    [w displayIfNeeded];
    /* drag to extend */
    for (;;) {
        NSEvent *e = [w nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        if (!e || [e type] == NSEventTypeLeftMouseUp)
            break;
        NSPoint q = [self convertPoint:[e locationInWindow] fromView:nil];
        [self autoscroll:e];
        NSInteger r = [self rowAtPoint:q];
        if (r < 0 || row < 0 || !_tv.multipleSelection)
            continue;
        NSMutableIndexSet *s = [[base mutableCopy] autorelease];
        if (!(mods & (NSEventModifierFlagCommand | NSEventModifierFlagShift)))
            [s removeAllIndexes];
        [s addIndexesInRange:NSMakeRange(MIN(row, r), labs(row - r) + 1)];
        NSIndexSet *ps = [self _finchProposedSelection:s];
        if (![ps isEqualToIndexSet:_selRows]) {
            [self _finchSetSelectedRows:ps anchor:r notify:NO];
            changed = YES;
            [[NSNotificationCenter defaultCenter] postNotificationName:[self _finchSelectionIsChangingName] object:self];
            [w displayIfNeeded];
        }
    }
    if (changed || ![_selRows isEqualToIndexSet:base])
        [self _finchPostSelectionChange];
    [self sendAction:[self action] to:[self target]];
}

- (void)rightMouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    _clickedRow = [self rowAtPoint:p];
    _clickedColumn = [self columnAtPoint:p];
    [super rightMouseDown:event];
}

- (void)keyDown:(NSEvent *)event
{
    [self interpretKeyEvents:@[ event ]];
}

- (void)_finchMoveSelectionBy:(NSInteger)delta extend:(BOOL)extend
{
    NSInteger n = [self numberOfRows];
    if (!n)
        return;
    NSInteger cur = [self selectedRow];
    NSInteger next = cur < 0 ? (delta > 0 ? 0 : n - 1) : cur + delta;
    next = MAX(0, MIN(n - 1, next));
    if (next == cur && !extend)
        return;
    if (![self _finchSelectionShouldChange])
        return;
    NSMutableIndexSet *s = extend && _tv.multipleSelection ? [[_selRows mutableCopy] autorelease]
                                                           : [NSMutableIndexSet indexSet];
    [s addIndex:next];
    NSIndexSet *ps = [self _finchProposedSelection:s];
    if (![ps containsIndex:next])
        return;
    [self _finchSetSelectedRows:ps anchor:next notify:YES];
    [self scrollRowToVisible:next];
}

- (void)moveDown:(id)sender { [self _finchMoveSelectionBy:1 extend:NO]; }
- (void)moveUp:(id)sender { [self _finchMoveSelectionBy:-1 extend:NO]; }
- (void)moveDownAndModifySelection:(id)sender { [self _finchMoveSelectionBy:1 extend:YES]; }
- (void)moveUpAndModifySelection:(id)sender { [self _finchMoveSelectionBy:-1 extend:YES]; }
- (void)moveToBeginningOfDocument:(id)sender { [self _finchMoveSelectionBy:-NSIntegerMax / 2 extend:NO]; }
- (void)moveToEndOfDocument:(id)sender { [self _finchMoveSelectionBy:NSIntegerMax / 2 extend:NO]; }
- (void)scrollToBeginningOfDocument:(id)sender { [self scrollRowToVisible:0]; }
- (void)scrollToEndOfDocument:(id)sender { [self scrollRowToVisible:[self numberOfRows] - 1]; }
- (void)scrollPageUp:(id)sender { [[self enclosingScrollView] scrollPageUp:sender]; }
- (void)scrollPageDown:(id)sender { [[self enclosingScrollView] scrollPageDown:sender]; }
- (void)cancelOperation:(id)sender { [self abortEditing]; }

- (void)insertNewline:(id)sender
{
    NSInteger row = [self selectedRow];
    if (row < 0 || ![_columns count])
        return;
    for (NSInteger c = 0; c < (NSInteger)[_columns count]; c++) {
        NSTableColumn *tc = [_columns objectAtIndex:c];
        if (![tc isHidden] && [tc isEditable] && [self _finchShouldEditColumn:tc row:row] &&
            ![self _finchIsViewBased]) {
            [self editColumn:c row:row withEvent:nil select:YES];
            return;
        }
    }
}

#pragma mark - Editing (cell-based)

- (void)editColumn:(NSInteger)column row:(NSInteger)row withEvent:(NSEvent *)event select:(BOOL)select
{
    NSWindow *w = [self window];
    if (!w || column < 0 || column >= (NSInteger)[_columns count] || row < 0 || row >= [self numberOfRows])
        return;
    [self abortEditing];
    if (![_selRows containsIndex:row])
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [self scrollRowToVisible:row];
    NSCell *cell = [[[self preparedCellAtColumn:column row:row] copy] autorelease];
    [cell setHighlighted:NO];
    [cell setEditable:YES];
    NSText *fe = [w fieldEditor:YES forObject:self];
    if (!fe)
        return;
    _editedRow = row;
    _editedColumn = column;
    [_editingCell release];
    _editingCell = [cell retain];
    _fieldEditor = fe;
    NSRect f = [self frameOfCellAtColumn:column row:row];
    NSString *s = [cell stringValue] ?: @"";
    [cell selectWithFrame:f inView:self editor:fe delegate:self start:0 length:select ? (NSInteger)[s length] : 0];
    [w makeFirstResponder:fe];
    [self setNeedsDisplayInRect:[self rectOfRow:row]];
}

- (NSText *)currentEditor { return _fieldEditor; }

- (void)_finchEndEditing:(BOOL)commit movement:(NSInteger)movement
{
    NSText *fe = _fieldEditor;
    if (!fe)
        return;
    NSInteger row = _editedRow, col = _editedColumn;
    _fieldEditor = nil;
    if (commit && col >= 0 && col < (NSInteger)[_columns count]) {
        NSString *s = [[[fe string] copy] autorelease] ?: @"";
        [_editingCell setStringValue:s];
        [self _finchSetObjectValue:[_editingCell objectValue] forColumn:[_columns objectAtIndex:col] row:row];
    }
    [_editingCell endEditing:fe];
    [_editingCell release];
    _editingCell = nil;
    _editedRow = _editedColumn = -1;
    NSWindow *w = [self window];
    if ([w firstResponder] == (NSResponder *)fe)
        [w makeFirstResponder:self];
    [self setNeedsDisplay:YES];
    if (movement == NSTextMovementTab || movement == NSTextMovementBacktab) {
        NSInteger step = movement == NSTextMovementTab ? 1 : -1;
        for (NSInteger c = col + step; c >= 0 && c < (NSInteger)[_columns count]; c += step) {
            NSTableColumn *tc = [_columns objectAtIndex:c];
            if (![tc isHidden] && [tc isEditable] && [self _finchShouldEditColumn:tc row:row]) {
                [self editColumn:c row:row withEvent:nil select:YES];
                return;
            }
        }
    }
}

- (BOOL)abortEditing
{
    if (!_fieldEditor)
        return NO;
    [self _finchEndEditing:NO movement:0];
    return YES;
}

- (void)validateEditing
{
    if (_fieldEditor && _editingCell)
        [_editingCell setStringValue:[[[_fieldEditor string] copy] autorelease] ?: @""];
}

- (BOOL)textShouldBeginEditing:(NSText *)text { return YES; }
- (BOOL)textShouldEndEditing:(NSText *)text { return YES; }
- (void)textDidBeginEditing:(NSNotification *)note {}
- (void)textDidChange:(NSNotification *)note {}

- (void)textDidEndEditing:(NSNotification *)note
{
    NSInteger movement = [[[note userInfo] objectForKey:@"NSTextMovement"] integerValue];
    [self _finchEndEditing:YES movement:movement];
}

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)sel
{
    if (sel == @selector(cancelOperation:)) {
        [self abortEditing];
        return YES;
    }
    return NO;
}

#pragma mark - Archiving

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    table_init(self);
    _tv.decoded = YES;
    NSArray *cols = [coder decodeObjectForKey:@"NSTableColumns"];
    for (NSTableColumn *c in cols) {
        [_columns addObject:c];
        [c _finchSetTableView:self];
    }
    _headerView = [[coder decodeObjectForKey:@"NSHeaderView"] retain];
    [_headerView setTableView:self];
    _cornerView = [[coder decodeObjectForKey:@"NSCornerView"] retain];
    if ([coder containsValueForKey:@"NSIntercellSpacingWidth"])
        _spacing.width = [coder decodeDoubleForKey:@"NSIntercellSpacingWidth"];
    if ([coder containsValueForKey:@"NSIntercellSpacingHeight"])
        _spacing.height = [coder decodeDoubleForKey:@"NSIntercellSpacingHeight"];
    _backgroundColor = [[coder decodeObjectForKey:@"NSBackgroundColor"] retain];
    _gridColor = [[coder decodeObjectForKey:@"NSGridColor"] retain];
    /* Interface Builder's default grid colour reads back as the current default, as Apple's does */
    if ([_gridColor type] == NSColorTypeCatalog && [[_gridColor colorNameComponent] isEqualToString:@"gridColor"]) {
        [_gridColor release];
        _gridColor = nil;
    }
    if ([coder containsValueForKey:@"NSRowHeight"])
        _rowHeight = [coder decodeDoubleForKey:@"NSRowHeight"];
    if ([coder containsValueForKey:@"NSTvFlags"]) {
        unsigned f = (unsigned)[coder decodeIntForKey:@"NSTvFlags"];
        _tv.resizing = (f & TV_COLUMN_RESIZING) != 0;
        _tv.reordering = (f & TV_COLUMN_REORDERING) != 0;
        _tv.emptySelection = (f & TV_EMPTY_SELECTION) != 0;
        _tv.multipleSelection = (f & TV_MULTIPLE_SELECTION) != 0;
        _tv.columnSelection = (f & TV_COLUMN_SELECTION) != 0;
        _tv.autosaveColumns = (f & TV_AUTOSAVE_COLUMNS) != 0;
        _tv.alternating = (f & TV_ALTERNATING_ROWS) != 0;
    }
    _gridMask = [coder decodeIntegerForKey:@"NSGridStyleMask"];
    if ([coder containsValueForKey:@"NSColumnAutoresizingStyle"])
        _autoresizing = [coder decodeIntegerForKey:@"NSColumnAutoresizingStyle"];
    if ([coder containsValueForKey:@"NSAllowsTypeSelect"])
        _tv.typeSelect = [coder decodeBoolForKey:@"NSAllowsTypeSelect"];
    _style = [coder decodeIntegerForKey:@"NSTableViewStyle"];
    _rowSizeStyle = [coder decodeIntegerForKey:@"NSTableViewRowSizeStyle"];
    _highlightStyle = [coder decodeIntegerForKey:@"NSTableViewSelectionHighlightStyle"];
    _dragStyle = [coder decodeIntegerForKey:@"NSTableViewDraggingDestinationStyle"];
    if ([coder containsValueForKey:@"NSTableViewShouldFloatGroupRows"])
        _tv.floatsGroupRows = [coder decodeBoolForKey:@"NSTableViewShouldFloatGroupRows"];
    _tv.autoRowHeights = [coder decodeBoolForKey:@"NSTableViewUseARH"];
    _autosaveName = [[coder decodeObjectForKey:@"NSAutosaveName"] copy];
    NSDictionary *nibs = [coder decodeObjectForKey:@"NSTableViewArchivedReusableViewsKey"];
    if ([nibs isKindOfClass:[NSDictionary class]])
        [_nibs addEntriesFromDictionary:nibs];
    _delegate = [coder decodeObjectForKey:@"NSDelegate"];
    _dataSource = [coder decodeObjectForKey:@"NSDataSource"];
    if (_delegate)
        [self setDelegate:_delegate];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_columns forKey:@"NSTableColumns"];
    if (_headerView)
        [coder encodeObject:_headerView forKey:@"NSHeaderView"];
    if (_cornerView)
        [coder encodeObject:_cornerView forKey:@"NSCornerView"];
    [coder encodeDouble:_spacing.width forKey:@"NSIntercellSpacingWidth"];
    [coder encodeDouble:_spacing.height forKey:@"NSIntercellSpacingHeight"];
    if (_backgroundColor)
        [coder encodeObject:_backgroundColor forKey:@"NSBackgroundColor"];
    if (_gridColor)
        [coder encodeObject:_gridColor forKey:@"NSGridColor"];
    [coder encodeDouble:_rowHeight forKey:@"NSRowHeight"];
    unsigned f = (_tv.resizing ? TV_COLUMN_RESIZING : 0) | (_tv.reordering ? TV_COLUMN_REORDERING : 0) |
                 (_tv.emptySelection ? TV_EMPTY_SELECTION : 0) | (_tv.multipleSelection ? TV_MULTIPLE_SELECTION : 0) |
                 (_tv.columnSelection ? TV_COLUMN_SELECTION : 0) | (_tv.autosaveColumns ? TV_AUTOSAVE_COLUMNS : 0) |
                 (_tv.alternating ? TV_ALTERNATING_ROWS : 0);
    [coder encodeInt:(int)f forKey:@"NSTvFlags"];
    if (_gridMask)
        [coder encodeInteger:_gridMask forKey:@"NSGridStyleMask"];
    [coder encodeInteger:_autoresizing forKey:@"NSColumnAutoresizingStyle"];
    [coder encodeBool:_tv.typeSelect forKey:@"NSAllowsTypeSelect"];
    if (_style)
        [coder encodeInteger:_style forKey:@"NSTableViewStyle"];
    if (_rowSizeStyle)
        [coder encodeInteger:_rowSizeStyle forKey:@"NSTableViewRowSizeStyle"];
    if (_highlightStyle)
        [coder encodeInteger:_highlightStyle forKey:@"NSTableViewSelectionHighlightStyle"];
    if (_autosaveName)
        [coder encodeObject:_autosaveName forKey:@"NSAutosaveName"];
    if ([_nibs count])
        [coder encodeObject:_nibs forKey:@"NSTableViewArchivedReusableViewsKey"];
}

#pragma mark - Bindings

+ (NSArray *)_finchBuiltinBindings
{
    return @[
        NSContentBinding, NSDoubleClickArgumentBinding, NSDoubleClickTargetBinding, NSEnabledBinding, NSFontBinding,
        NSFontBoldBinding, NSFontFamilyNameBinding, NSFontItalicBinding, NSFontNameBinding, NSFontSizeBinding,
        NSHiddenBinding, NSRowHeightBinding, NSSelectionIndexesBinding, NSSortDescriptorsBinding, NSToolTipBinding
    ];
}

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqualToString:NSContentBinding] || [binding isEqualToString:NSSelectionIndexesBinding] ||
           [binding isEqualToString:NSSortDescriptorsBinding] || [binding isEqualToString:NSRowHeightBinding] ||
           [binding isEqualToString:NSDoubleClickArgumentBinding] || [binding isEqualToString:NSDoubleClickTargetBinding] ||
           [super _finchHandlesBinding:binding];
}

- (Class)_finchValueClassForBinding:(NSString *)binding
{
    if ([binding isEqualToString:NSContentBinding] || [binding isEqualToString:NSSortDescriptorsBinding])
        return [NSArray class];
    if ([binding isEqualToString:NSSelectionIndexesBinding])
        return [NSIndexSet class];
    if ([binding isEqualToString:NSRowHeightBinding])
        return [NSNumber class];
    return [super _finchValueClassForBinding:binding];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    NSString *name = b->_name;
    if ([name isEqualToString:NSContentBinding]) {
        [self reloadData];
        /* the selection binding may have changed with the content, before it */
        _FinchBinding *sel = FinchBindingFor(self, NSSelectionIndexesBinding);
        if (sel)
            [self _finchBindingChanged:sel];
        return;
    }
    if ([name isEqualToString:NSSelectionIndexesBinding]) {
        if (_tv.pushingSelection)
            return;
        id v = [b rawValue];
        NSIndexSet *s = [v isKindOfClass:[NSIndexSet class]] ? v : [NSIndexSet indexSet];
        if ([s count] && (NSInteger)[s lastIndex] >= [self numberOfRows]) {
            _rows = -1;
            [self _finchInvalidateRowGeometry];
            [self tile];
        }
        _tv.pushingSelection = YES;
        if (![s isEqualToIndexSet:_selRows])
            [self _finchSetSelectedRows:s anchor:[s count] ? (NSInteger)[s lastIndex] : -1 notify:YES];
        _tv.pushingSelection = NO;
        return;
    }
    if ([name isEqualToString:NSSortDescriptorsBinding]) {
        if (_tv.pushingSort)
            return;
        id v = [b rawValue];
        _tv.pushingSort = YES;
        [self setSortDescriptors:[v isKindOfClass:[NSArray class]] ? v : @[]];
        _tv.pushingSort = NO;
        return;
    }
    if ([name isEqualToString:NSRowHeightBinding]) {
        id v = [b displayValueWithKind:NULL];
        if ([v respondsToSelector:@selector(doubleValue)])
            [self setRowHeight:[v doubleValue]];
        return;
    }
    if ([name isEqualToString:NSDoubleClickArgumentBinding] || [name isEqualToString:NSDoubleClickTargetBinding])
        return;
    [super _finchBindingChanged:b];
}

- (void)_finchBindingRemoved:(NSString *)binding
{
    if ([binding isEqualToString:NSContentBinding])
        [self reloadData];
    [super _finchBindingRemoved:binding];
}

@end

#pragma mark - The corner view

@implementation _NSCornerView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)rect
{
    [[NSColor colorWithWhite:0.97 alpha:1] setFill];
    NSRectFill([self bounds]);
    [[NSColor colorWithWhite:0.85 alpha:1] setFill];
    NSRect b = [self bounds];
    NSRectFill(NSMakeRect(NSMinX(b), NSMaxY(b) - 1, NSWidth(b), 1));
}

@end

#pragma mark - The visible rect

/*
 * What the ancestors (clip views, outside a window) leave visible, in the
 * view's coordinates. As Apple's, it is not cut to the view's own bounds
 * (a table under its header sees the header's strip above its top), and
 * outside a window only clip views clip.
 */
NSRect
FinchClippedVisibleRect(NSView *view)
{
    BOOL inWindow = [view window] != nil, clipped = inWindow;
    NSRect r = [view bounds];
    NSView *v = view;
    for (NSView *s = [view superview]; s; v = s, s = [s superview]) {
        r = [v convertRect:r toView:s];
        if (inWindow || [s isKindOfClass:[NSClipView class]]) {
            r = NSIntersectionRect(r, [s bounds]);
            clipped = YES;
        }
    }
    if (!clipped)
        return NSMakeRect(-DBL_MAX / 2, -DBL_MAX / 2, DBL_MAX, DBL_MAX);
    if (NSIsEmptyRect(r))
        return NSZeroRect;
    return [view convertRect:r fromView:v];
}

#pragma mark - The look

NSColor *
FinchTableSelectionColor(BOOL emphasized)
{
    return emphasized ? [NSColor selectedContentBackgroundColor] : [NSColor unemphasizedSelectedContentBackgroundColor];
}

void
FinchTableDrawDisclosure(NSRect frame, BOOL expanded, BOOL flipped, NSColor *color)
{
    CGFloat cx = NSMidX(frame), cy = NSMidY(frame), s = 3.5;
    NSBezierPath *p = [NSBezierPath bezierPath];
    if (expanded) {
        /* a chevron pointing down */
        CGFloat dir = flipped ? 1 : -1;
        [p moveToPoint:NSMakePoint(cx - s, cy - dir * s / 2)];
        [p lineToPoint:NSMakePoint(cx, cy + dir * s / 2)];
        [p lineToPoint:NSMakePoint(cx + s, cy - dir * s / 2)];
    } else {
        [p moveToPoint:NSMakePoint(cx - s / 2, cy - s)];
        [p lineToPoint:NSMakePoint(cx + s / 2, cy)];
        [p lineToPoint:NSMakePoint(cx - s / 2, cy + s)];
    }
    [p setLineWidth:1.5];
    [p setLineCapStyle:NSLineCapStyleRound];
    [p setLineJoinStyle:NSLineJoinStyleRound];
    [color setStroke];
    [p stroke];
}
