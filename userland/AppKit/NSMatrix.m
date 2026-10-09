/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A matrix owns a row-by-row array of cells and a separate selection. */
#import "NSControl_Finch.h"
#import "NSKeyValueBinding_Finch.h"

@interface NSControl (FinchMatrixEditing)
- (void)textDidEndEditing:(NSNotification *)note;
@end

@implementation NSMatrix {
    NSMutableArray *_cells;
    NSMutableIndexSet *_selection;
    NSInteger _rows, _columns, _selected, _anchor;
    NSSize _cellSize, _spacing;
    NSMatrixMode _mode;
    Class _factory;
    NSCell *_prototype, *_keyCell;
    NSColor *_background, *_cellBackground;
    NSMapTable *_toolTips;
    id _delegate, _matrixTarget;
    SEL _matrixAction, _doubleAction;
    NSEventModifierFlags _mouseFlags;
    BOOL _allowsEmpty, _autosizes, _drawsBackground, _drawsCellBackground, _byRect, _autoscroll, _tabTraverses, _autorecalculates;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    return [self initWithFrame:frame mode:NSRadioModeMatrix cellClass:[NSActionCell class] numberOfRows:0 numberOfColumns:0];
}
- (instancetype)initWithFrame:(NSRect)frame mode:(NSMatrixMode)mode cellClass:(Class)factory numberOfRows:(NSInteger)rows numberOfColumns:(NSInteger)columns
{
    if (!(self = [super initWithFrame:frame])) return nil;
    _cells = [NSMutableArray new]; _selection = [NSMutableIndexSet new]; _selected = -1; _anchor = -1;
    _factory = factory ?: [NSActionCell class]; _mode = mode; _byRect = YES; _tabTraverses = mode != NSRadioModeMatrix;
    _cellSize = NSMakeSize(100, 15); _spacing = NSMakeSize(1, 1);
    _background = [[NSColor controlColor] retain]; _cellBackground = [[NSColor controlColor] retain];
    _toolTips = [[NSMapTable strongToStrongObjectsMapTable] retain];
    [self renewRows:rows columns:columns]; return self;
}
- (instancetype)initWithFrame:(NSRect)frame mode:(NSMatrixMode)mode prototype:(NSCell *)prototype numberOfRows:(NSInteger)rows numberOfColumns:(NSInteger)columns
{
    if (!(self = [self initWithFrame:frame mode:mode cellClass:[prototype class] numberOfRows:0 numberOfColumns:0])) return nil;
    [self setPrototype:prototype]; [self renewRows:rows columns:columns]; return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder])) return nil;
    _cells = [[coder decodeObjectForKey:@"NSCells"] mutableCopy] ?: [NSMutableArray new];
    _selection = [NSMutableIndexSet new]; _rows = [coder decodeIntegerForKey:@"NSNumRows"]; _columns = [coder decodeIntegerForKey:@"NSNumCols"];
    _factory = NSClassFromString([coder decodeObjectForKey:@"NSCellClass"]) ?: [NSActionCell class];
    _prototype = [[coder decodeObjectForKey:@"NSProtoCell"] copy];
    _cellSize = [coder containsValueForKey:@"NSCellSize"] ? [coder decodeSizeForKey:@"NSCellSize"] : NSMakeSize(100, 15);
    _spacing = [coder containsValueForKey:@"NSIntercellSpacing"] ? [coder decodeSizeForKey:@"NSIntercellSpacing"] : NSMakeSize(1, 1);
    uint32_t flags = (uint32_t)[coder decodeIntForKey:@"NSMatrixFlags"];
    _mode = (flags & 0x40000000) ? NSRadioModeMatrix : (flags & 0x80000000) ? NSHighlightModeMatrix : (flags & 0x20000000) ? NSListModeMatrix : NSTrackModeMatrix;
    _allowsEmpty = (flags & 0x10000000) != 0; _autoscroll = (flags & 0x08000000) != 0;
    _byRect = (flags & 0x04000000) != 0; _drawsCellBackground = (flags & 0x02000000) != 0;
    _drawsBackground = (flags & 0x01000000) != 0; _autosizes = (flags & 0x00800000) != 0;
    _tabTraverses = (flags & 0x00100000) ? (flags & 0x00200000) != 0 : _mode != NSRadioModeMatrix;
    _autorecalculates = [coder decodeBoolForKey:@"NSAutorecalculatesCellSize"];
    _background = [[coder decodeObjectForKey:@"NSBackgroundColor"] copy] ?: [[NSColor controlColor] retain];
    _cellBackground = [[coder decodeObjectForKey:@"NSCellBackgroundColor"] copy] ?: [[NSColor controlColor] retain];
    _delegate = [coder decodeObjectForKey:@"NSDelegate"]; _toolTips = [[NSMapTable strongToStrongObjectsMapTable] retain];
    NSInteger row = [coder containsValueForKey:@"NSSelectedRow"] ? [coder decodeIntegerForKey:@"NSSelectedRow"] : -1;
    NSInteger column = [coder containsValueForKey:@"NSSelectedCol"] ? [coder decodeIntegerForKey:@"NSSelectedCol"] : -1;
    _selected = row >= 0 && row < _rows && column >= 0 && column < _columns ? row * _columns + column : -1;
    for (NSUInteger i = 0; i < [_cells count]; i++) {
        NSCell *cell = [_cells objectAtIndex:i]; [cell setControlView:self];
        if (_mode == NSRadioModeMatrix && [cell state] != NSControlStateValueOff && _selected < 0) _selected = i;
    }
    if (_selected >= 0) [_selection addIndex:_selected]; _anchor = _selected;
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder]; [coder encodeObject:_cells forKey:@"NSCells"];
    [coder encodeInteger:_rows forKey:@"NSNumRows"]; [coder encodeInteger:_columns forKey:@"NSNumCols"];
    [coder encodeObject:NSStringFromClass(_factory) forKey:@"NSCellClass"]; [coder encodeObject:_prototype forKey:@"NSProtoCell"];
    [coder encodeSize:_cellSize forKey:@"NSCellSize"]; [coder encodeSize:_spacing forKey:@"NSIntercellSpacing"];
    uint32_t flags = _mode == NSRadioModeMatrix ? 0x40000000 : _mode == NSHighlightModeMatrix ? 0x80000000 : _mode == NSListModeMatrix ? 0x20000000 : 0;
    flags |= (_allowsEmpty ? 0x10000000 : 0) | (_autoscroll ? 0x08000000 : 0) | (_byRect ? 0x04000000 : 0) |
             (_drawsCellBackground ? 0x02000000 : 0) | (_drawsBackground ? 0x01000000 : 0) | (_autosizes ? 0x00800000 : 0) |
             0x00100000 | (_tabTraverses ? 0x00200000 : 0);
    [coder encodeInt:(int32_t)flags forKey:@"NSMatrixFlags"];
    [coder encodeBool:_autorecalculates forKey:@"NSAutorecalculatesCellSize"];
    [coder encodeInteger:[self selectedRow] forKey:@"NSSelectedRow"]; [coder encodeInteger:[self selectedColumn] forKey:@"NSSelectedCol"];
    [coder encodeObject:_background forKey:@"NSBackgroundColor"]; [coder encodeObject:_cellBackground forKey:@"NSCellBackgroundColor"];
    [coder encodeConditionalObject:_delegate forKey:@"NSDelegate"];
}
- (void)dealloc
{
    for (NSCell *cell in _cells) if ([cell controlView] == self) [cell setControlView:nil];
    [_cells release]; [_selection release]; [_prototype release]; [_keyCell release];
    [_background release]; [_cellBackground release]; [_toolTips release]; [super dealloc];
}
- (Class)cellClass { return _factory; }
- (void)setCellClass:(Class)c { _factory = c ?: [NSActionCell class]; }
- (NSCell *)prototype { return _prototype; }
- (void)setPrototype:(NSCell *)cell { NSCell *copy = [cell copy]; [_prototype release]; _prototype = copy; }
- (NSMatrixMode)mode { return _mode; }
- (void)setMode:(NSMatrixMode)mode { _mode = mode; _tabTraverses = mode != NSRadioModeMatrix; [self setNeedsDisplay:YES]; }
- (BOOL)allowsEmptySelection { return _allowsEmpty; }
- (void)setAllowsEmptySelection:(BOOL)b { _allowsEmpty = b; }
- (BOOL)autosizesCells { return _autosizes; }
- (void)setAutosizesCells:(BOOL)b { _autosizes = b; }
- (BOOL)autorecalculatesCellSize { return _autorecalculates; }
- (void)setAutorecalculatesCellSize:(BOOL)b { _autorecalculates = b; [self invalidateIntrinsicContentSize]; }
- (BOOL)isSelectionByRect { return _byRect; }
- (void)setSelectionByRect:(BOOL)b { _byRect = b; }
- (BOOL)drawsBackground { return _drawsBackground; }
- (void)setDrawsBackground:(BOOL)b { _drawsBackground = b; [self setNeedsDisplay:YES]; }
- (BOOL)drawsCellBackground { return _drawsCellBackground; }
- (void)setDrawsCellBackground:(BOOL)b { _drawsCellBackground = b; [self setNeedsDisplay:YES]; }
- (BOOL)isAutoscroll { return _autoscroll; }
- (void)setAutoscroll:(BOOL)b { _autoscroll = b; }
- (BOOL)tabKeyTraversesCells { return _tabTraverses; }
- (void)setTabKeyTraversesCells:(BOOL)b { _tabTraverses = b; }
- (NSColor *)backgroundColor { return _background; }
- (void)setBackgroundColor:(NSColor *)c { NSColor *copy = [c copy]; [_background release]; _background = copy; [self setNeedsDisplay:YES]; }
- (NSColor *)cellBackgroundColor { return _cellBackground; }
- (void)setCellBackgroundColor:(NSColor *)c { NSColor *copy = [c copy]; [_cellBackground release]; _cellBackground = copy; [self setNeedsDisplay:YES]; }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (id)target { return _matrixTarget; }
- (void)setTarget:(id)t { _matrixTarget = t; }
- (SEL)action { return _matrixAction; }
- (void)setAction:(SEL)a { _matrixAction = a; }
- (SEL)doubleAction { return _doubleAction; }
- (void)setDoubleAction:(SEL)a { _doubleAction = a; }
- (NSInteger)mouseDownFlags { return _mouseFlags; }
- (NSInteger)numberOfRows { return _rows; }
- (NSInteger)numberOfColumns { return _columns; }
- (void)getNumberOfRows:(NSInteger *)rows columns:(NSInteger *)columns { if (rows) *rows = _rows; if (columns) *columns = _columns; }
- (NSArray *)cells { return [[_cells copy] autorelease]; }
- (NSInteger)selectedRow { return _selected < 0 || !_columns ? -1 : _selected / _columns; }
- (NSInteger)selectedColumn { return _selected < 0 || !_columns ? -1 : _selected % _columns; }
- (NSCell *)selectedCell { return _selected >= 0 && _selected < [_cells count] ? [_cells objectAtIndex:_selected] : nil; }
- (NSArray *)selectedCells { return [_cells objectsAtIndexes:_selection]; }
- (NSCell *)keyCell { return _keyCell; }
- (void)setKeyCell:(NSCell *)cell { [cell retain]; [_keyCell release]; _keyCell = cell; [self setNeedsDisplay:YES]; }
- (NSSize)intercellSpacing { return _spacing; }
- (void)setIntercellSpacing:(NSSize)s { _spacing = s; [self invalidateIntrinsicContentSize]; [self setNeedsDisplay:YES]; }
- (NSSize)cellSize
{
    if (_autorecalculates) for (NSCell *cell in _cells) {
        NSSize s = [cell cellSize]; _cellSize.width = MAX(_cellSize.width, s.width); _cellSize.height = MAX(_cellSize.height, s.height);
    }
    return _cellSize;
}
- (void)setCellSize:(NSSize)s { _cellSize = s; [self invalidateIntrinsicContentSize]; [self setNeedsDisplay:YES]; }
- (NSCell *)cellAtRow:(NSInteger)row column:(NSInteger)column
{
    return row < 0 || column < 0 || row >= _rows || column >= _columns ? nil : [_cells objectAtIndex:row * _columns + column];
}
- (NSRect)cellFrameAtRow:(NSInteger)row column:(NSInteger)column
{
    NSSize size = [self cellSize]; return NSMakeRect(column * (size.width + _spacing.width), row * (size.height + _spacing.height), size.width, size.height);
}
- (BOOL)getRow:(NSInteger *)row column:(NSInteger *)column ofCell:(NSCell *)cell
{
    NSUInteger i = [_cells indexOfObjectIdenticalTo:cell]; if (i == NSNotFound || !_columns) return NO;
    if (row) *row = i / _columns; if (column) *column = i % _columns; return YES;
}
- (BOOL)getRow:(NSInteger *)row column:(NSInteger *)column forPoint:(NSPoint)p
{
    NSSize size = [self cellSize]; CGFloat w = size.width + _spacing.width, h = size.height + _spacing.height;
    if (p.x < 0 || p.y < 0 || w <= 0 || h <= 0) return NO;
    NSInteger r = floor(p.y / h), c = floor(p.x / w);
    if (r >= _rows || c >= _columns || !NSPointInRect(p, [self cellFrameAtRow:r column:c])) return NO;
    if (row) *row = r; if (column) *column = c; return YES;
}
- (NSCell *)_finchNewCell
{
    NSCell *cell = _prototype ? [_prototype copy] : [[_factory alloc] init];
    [cell setControlView:self]; return [cell autorelease];
}
- (NSCell *)makeCellAtRow:(NSInteger)row column:(NSInteger)column
{
    if (![self cellAtRow:row column:column]) return nil;
    NSCell *cell = [self _finchNewCell]; [self putCell:cell atRow:row column:column]; return cell;
}
- (void)putCell:(NSCell *)cell atRow:(NSInteger)row column:(NSInteger)column
{
    if (row < 0 || column < 0 || row >= _rows || column >= _columns || !cell)
        [NSException raise:NSInvalidArgumentException format:@"No matrix cell at row %ld column %ld", (long)row, (long)column];
    NSCell *old = [self cellAtRow:row column:column]; if ([old controlView] == self) [old setControlView:nil];
    [_cells replaceObjectAtIndex:row * _columns + column withObject:cell]; [cell setControlView:self]; [self setNeedsDisplay:YES];
}
- (void)renewRows:(NSInteger)rows columns:(NSInteger)columns
{
    if (rows < 0 || columns < 0) [NSException raise:NSInvalidArgumentException format:@"Matrix dimensions must be nonnegative"];
    NSCell *selected = [[self selectedCell] retain]; NSMutableArray *newCells = [NSMutableArray arrayWithCapacity:rows * columns];
    for (NSInteger r = 0; r < rows; r++) for (NSInteger c = 0; c < columns; c++)
        [newCells addObject:[self cellAtRow:r column:c] ?: [self _finchNewCell]];
    for (NSCell *cell in _cells) if (![newCells containsObject:cell] && [cell controlView] == self) [cell setControlView:nil];
    [_cells setArray:newCells]; _rows = rows; _columns = columns; [_selection removeAllIndexes];
    NSUInteger index = selected ? [_cells indexOfObjectIdenticalTo:selected] : NSNotFound; [selected release];
    _selected = index == NSNotFound ? -1 : (NSInteger)index;
    if (_selected < 0 && _mode == NSRadioModeMatrix && !_allowsEmpty && [_cells count]) _selected = 0;
    if (_selected >= 0) { [_selection addIndex:_selected]; [[self selectedCell] setState:NSControlStateValueOn]; }
    _anchor = _selected; [self invalidateIntrinsicContentSize]; [self setNeedsDisplay:YES];
}
- (void)insertRow:(NSInteger)row { [self insertRow:row withCells:nil]; }
- (void)addRow { [self insertRow:_rows withCells:nil]; }
- (void)addRowWithCells:(NSArray *)cells { [self insertRow:_rows withCells:cells]; }
- (void)insertRow:(NSInteger)row withCells:(NSArray *)cells
{
    if (row < 0 || row > _rows) [NSException raise:NSRangeException format:@"Matrix row is out of range"];
    if (!_columns) _columns = MAX(1, (NSInteger)[cells count]);
    if (cells && [cells count] != _columns) [NSException raise:NSInvalidArgumentException format:@"A matrix row needs %ld cells", (long)_columns];
    NSCell *selected = [[self selectedCell] retain];
    for (NSInteger c = 0; c < _columns; c++) {
        NSCell *cell = cells ? [cells objectAtIndex:c] : [self _finchNewCell]; [cell setControlView:self];
        [_cells insertObject:cell atIndex:row * _columns + c];
    }
    _rows++; [self _finchRestoreSelection:selected]; [selected release];
}
- (void)insertColumn:(NSInteger)column { [self insertColumn:column withCells:nil]; }
- (void)addColumn { [self insertColumn:_columns withCells:nil]; }
- (void)addColumnWithCells:(NSArray *)cells { [self insertColumn:_columns withCells:cells]; }
- (void)insertColumn:(NSInteger)column withCells:(NSArray *)cells
{
    if (column < 0 || column > _columns) [NSException raise:NSRangeException format:@"Matrix column is out of range"];
    if (!_rows) _rows = MAX(1, (NSInteger)[cells count]);
    if (cells && [cells count] != _rows) [NSException raise:NSInvalidArgumentException format:@"A matrix column needs %ld cells", (long)_rows];
    NSCell *selected = [[self selectedCell] retain];
    for (NSInteger r = _rows - 1; r >= 0; r--) {
        NSCell *cell = cells ? [cells objectAtIndex:r] : [self _finchNewCell]; [cell setControlView:self];
        [_cells insertObject:cell atIndex:r * _columns + column];
    }
    _columns++; [self _finchRestoreSelection:selected]; [selected release];
}
- (void)removeRow:(NSInteger)row
{
    if (row < 0 || row >= _rows) [NSException raise:NSRangeException format:@"Matrix row is out of range"];
    NSCell *selected = [[self selectedCell] retain];
    for (NSInteger c = 0; c < _columns; c++) [[self cellAtRow:row column:c] setControlView:nil];
    [_cells removeObjectsInRange:NSMakeRange(row * _columns, _columns)]; _rows--;
    [self _finchRestoreSelection:selected]; [selected release];
}
- (void)removeColumn:(NSInteger)column
{
    if (column < 0 || column >= _columns) [NSException raise:NSRangeException format:@"Matrix column is out of range"];
    NSCell *selected = [[self selectedCell] retain];
    for (NSInteger r = _rows - 1; r >= 0; r--) { [[self cellAtRow:r column:column] setControlView:nil]; [_cells removeObjectAtIndex:r * _columns + column]; }
    _columns--; [self _finchRestoreSelection:selected]; [selected release];
}
- (void)_finchRestoreSelection:(NSCell *)selected
{
    NSUInteger i = selected ? [_cells indexOfObjectIdenticalTo:selected] : NSNotFound;
    _selected = i == NSNotFound ? -1 : (NSInteger)i;
    if (_selected < 0 && _mode == NSRadioModeMatrix && !_allowsEmpty && [_cells count]) _selected = 0;
    [_selection removeAllIndexes]; if (_selected >= 0) { [_selection addIndex:_selected]; [[self selectedCell] setState:NSControlStateValueOn]; }
    [self invalidateIntrinsicContentSize]; [self setNeedsDisplay:YES];
}
- (NSCell *)cellWithTag:(NSInteger)tag { for (NSCell *cell in _cells) if ([cell tag] == tag) return cell; return nil; }
- (void)_finchClearSelection
{
    for (NSUInteger i = [_selection firstIndex]; i != NSNotFound; i = [_selection indexGreaterThanIndex:i]) {
        NSCell *cell = [_cells objectAtIndex:i]; [cell setState:NSControlStateValueOff]; [cell setHighlighted:NO];
    }
    [_selection removeAllIndexes]; _selected = -1;
}
- (void)selectCellAtRow:(NSInteger)row column:(NSInteger)column
{
    NSCell *cell = [self cellAtRow:row column:column]; if (!cell) return;
    if (_mode == NSRadioModeMatrix || _mode == NSListModeMatrix) [self _finchClearSelection]; else [_selection removeAllIndexes];
    _selected = row * _columns + column; _anchor = _selected; [_selection addIndex:_selected]; [cell setState:NSControlStateValueOn];
    [self setKeyCell:cell]; [self setNeedsDisplay:YES];
}
- (BOOL)selectCellWithTag:(NSInteger)tag
{
    NSCell *cell = [self cellWithTag:tag]; NSInteger row, column;
    if (![self getRow:&row column:&column ofCell:cell]) return NO; [self selectCellAtRow:row column:column]; return YES;
}
- (void)deselectSelectedCell
{
    if (_mode == NSRadioModeMatrix && !_allowsEmpty) return;
    if (_selected >= 0) { [[self selectedCell] setState:0]; [[self selectedCell] setHighlighted:NO]; [_selection removeIndex:_selected]; }
    _selected = [_selection count] ? [_selection firstIndex] : -1; [self setNeedsDisplay:YES];
}
- (void)deselectAllCells
{
    if (_mode == NSRadioModeMatrix && !_allowsEmpty) return;
    for (NSCell *cell in _cells) { [cell setState:NSControlStateValueOff]; [cell setHighlighted:NO]; }
    [self _finchClearSelection]; [self setNeedsDisplay:YES];
}
- (void)selectAll:(id)sender
{
    if (_mode != NSListModeMatrix) return;
    [_selection addIndexesInRange:NSMakeRange(0, [_cells count])];
    for (NSCell *cell in _cells) [cell setState:NSControlStateValueOn];
    _selected = [_cells count] ? (NSInteger)[_cells count] - 1 : -1; [self setNeedsDisplay:YES];
}
- (void)setSelectionFrom:(NSInteger)start to:(NSInteger)end anchor:(NSInteger)anchor highlight:(BOOL)highlight
{
    if (![_cells count]) return;
    start = MAX(0, MIN(start, (NSInteger)[_cells count] - 1)); end = MAX(0, MIN(end, (NSInteger)[_cells count] - 1));
    NSInteger low = MIN(start, end), high = MAX(start, end);
    for (NSInteger i = low; i <= high; i++) {
        if (_byRect && _columns && (i % _columns < MIN(start % _columns, end % _columns) || i % _columns > MAX(start % _columns, end % _columns))) continue;
        NSCell *cell = [_cells objectAtIndex:i]; [cell setState:highlight ? NSControlStateValueOn : NSControlStateValueOff]; [cell setHighlighted:highlight];
        if (highlight) [_selection addIndex:i]; else [_selection removeIndex:i];
    }
    _anchor = anchor; _selected = highlight ? end : ([_selection count] ? [_selection firstIndex] : -1); [self setNeedsDisplay:YES];
}
- (void)setState:(NSInteger)value atRow:(NSInteger)row column:(NSInteger)column
{
    NSCell *cell = [self cellAtRow:row column:column];
    if (value && _mode == NSRadioModeMatrix) [self selectCellAtRow:row column:column];
    [cell setState:value]; [self setNeedsDisplay:YES];
}
- (void)sortUsingSelector:(SEL)selector
{
    NSCell *selected = [[self selectedCell] retain]; [_cells sortUsingSelector:selector]; [self _finchRestoreSelection:selected]; [selected release];
}
- (void)sortUsingFunction:(NSInteger (NS_NOESCAPE *)(id, id, void *))compare context:(void *)context
{
    NSCell *selected = [[self selectedCell] retain]; [_cells sortUsingFunction:compare context:context]; [self _finchRestoreSelection:selected]; [selected release];
}
- (BOOL)isFlipped { return YES; }
- (NSSize)intrinsicContentSize
{
    NSSize size = [self cellSize]; return NSMakeSize(_columns ? _columns * size.width + (_columns - 1) * _spacing.width : 0,
                                                    _rows ? _rows * size.height + (_rows - 1) * _spacing.height : 0);
}
- (void)sizeToCells { [self setFrameSize:[self intrinsicContentSize]]; }
- (void)setValidateSize:(BOOL)b { if (b) [self invalidateIntrinsicContentSize]; }
- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    if (_autosizes) {
        if (_columns) _cellSize.width = MAX(0, (size.width - (_columns - 1) * _spacing.width) / _columns);
        if (_rows) _cellSize.height = MAX(0, (size.height - (_rows - 1) * _spacing.height) / _rows);
    }
}
- (void)setScrollable:(BOOL)b { [_prototype setScrollable:b]; for (NSCell *cell in _cells) [cell setScrollable:b]; }
- (void)setFont:(NSFont *)font { [super setFont:font]; [_prototype setFont:font]; for (NSCell *cell in _cells) [cell setFont:font]; [self setNeedsDisplay:YES]; }
- (void)setEnabled:(BOOL)b { [super setEnabled:b]; for (NSCell *cell in _cells) [cell setEnabled:b]; }
- (void)drawRect:(NSRect)dirty
{
    if (_drawsBackground) { [_background setFill]; NSRectFill(dirty); }
    for (NSInteger row = 0; row < _rows; row++) for (NSInteger column = 0; column < _columns; column++) {
        NSRect rect = [self cellFrameAtRow:row column:column]; if (!NSIntersectsRect(rect, dirty)) continue;
        if (_drawsCellBackground) { [_cellBackground setFill]; NSRectFill(rect); }
        [[self cellAtRow:row column:column] drawWithFrame:rect inView:self];
    }
}
- (void)drawCellAtRow:(NSInteger)row column:(NSInteger)column { [self setNeedsDisplayInRect:[self cellFrameAtRow:row column:column]]; }
- (void)highlightCell:(BOOL)b atRow:(NSInteger)row column:(NSInteger)column { [[self cellAtRow:row column:column] setHighlighted:b]; [self drawCellAtRow:row column:column]; }
- (void)scrollCellToVisibleAtRow:(NSInteger)row column:(NSInteger)column { [self scrollRectToVisible:[self cellFrameAtRow:row column:column]]; }
- (BOOL)sendAction
{
    NSCell *cell = [self selectedCell]; SEL action = [cell action] ?: _matrixAction; id target = [cell action] ? [cell target] : _matrixTarget;
    return [super sendAction:action to:target];
}
- (void)sendDoubleAction { if (_doubleAction) [super sendAction:_doubleAction to:_matrixTarget]; else [self sendAction]; }
- (void)sendAction:(SEL)selector to:(id)object forAllCells:(BOOL)all
{
    for (NSCell *cell in all ? _cells : [self selectedCells]) [NSApp sendAction:selector to:object from:cell];
}
- (void)performClick:(id)sender { if ([self isEnabled] && [[self selectedCell] isEnabled]) [self sendAction]; }
- (BOOL)acceptsFirstResponder { return [self isEnabled] && [_cells count] > 0; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseDown:(NSEvent *)event
{
    if (![self isEnabled]) return;
    NSInteger row, column; _mouseFlags = [event modifierFlags];
    if (![self getRow:&row column:&column forPoint:[self convertPoint:[event locationInWindow] fromView:nil]]) return;
    NSCell *cell = [self cellAtRow:row column:column]; if (![cell isEnabled]) return;
    [[self window] makeFirstResponder:self];
    NSInteger index = row * _columns + column;
    if (_mode == NSListModeMatrix && (_mouseFlags & NSEventModifierFlagShift) && _anchor >= 0)
        [self setSelectionFrom:_anchor to:index anchor:_anchor highlight:YES];
    else if (_mode == NSListModeMatrix && (_mouseFlags & NSEventModifierFlagCommand)) {
        BOOL selected = [_selection containsIndex:index];
        if (selected) [_selection removeIndex:index]; else [_selection addIndex:index];
        [cell setState:!selected]; _selected = [_selection containsIndex:index] ? index : ([_selection count] ? [_selection firstIndex] : -1);
    } else [self selectCellAtRow:row column:column];
    if ([cell isEditable] && [cell type] == NSTextCellType) { [self selectTextAtRow:row column:column]; return; }
    [cell setHighlighted:YES]; [[self window] displayIfNeeded]; BOOL inside = YES;
    for (;;) {
        NSEvent *next = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged]; if (!next) break;
        NSInteger r, c;
        inside = [self getRow:&r column:&c forPoint:[self convertPoint:[next locationInWindow] fromView:nil]];
        if (inside && _mode == NSListModeMatrix && (_mouseFlags & NSEventModifierFlagShift)) [self setSelectionFrom:_anchor to:r * _columns + c anchor:_anchor highlight:YES];
        inside = inside && r == row && c == column; [cell setHighlighted:inside];
        if ([next type] == NSEventTypeLeftMouseUp) break;
    }
    [cell setHighlighted:NO]; [self setNeedsDisplay:YES];
    if (inside) { if ([event clickCount] > 1) [self sendDoubleAction]; else [self sendAction]; }
}
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    NSString *key = [event charactersIgnoringModifiers];
    for (NSCell *cell in _cells) if ([cell isEnabled] && [[cell keyEquivalent] length] && [[cell keyEquivalent] isEqual:key]) {
        NSInteger row, column; [self getRow:&row column:&column ofCell:cell]; [self selectCellAtRow:row column:column]; [self sendAction]; return YES;
    }
    return NO;
}
- (void)keyDown:(NSEvent *)event
{
    NSString *s = [event charactersIgnoringModifiers]; if (![s length]) return; unichar key = [s characterAtIndex:0];
    NSInteger row = MAX(0, [self selectedRow]), column = MAX(0, [self selectedColumn]);
    if (key == NSUpArrowFunctionKey) row--; else if (key == NSDownArrowFunctionKey) row++;
    else if (key == NSLeftArrowFunctionKey) column--; else if (key == NSRightArrowFunctionKey) column++;
    else if (key == ' ' || key == '\r') { [self performClick:self]; return; }
    else { [super keyDown:event]; return; }
    if (row >= 0 && row < _rows && column >= 0 && column < _columns && [[self cellAtRow:row column:column] isEnabled]) {
        [self selectCellAtRow:row column:column]; [self scrollCellToVisibleAtRow:row column:column]; [self sendAction];
    }
}
- (NSCell *)selectTextAtRow:(NSInteger)row column:(NSInteger)column
{
    NSCell *cell = [self cellAtRow:row column:column]; if (!cell || ![cell isSelectable]) return nil;
    [self selectCellAtRow:row column:column]; [self abortEditing]; [super setCell:cell];
    NSText *editor = [[self window] fieldEditor:YES forObject:self];
    [self selectWithFrame:[self cellFrameAtRow:row column:column] editor:editor delegate:self start:0 length:[[cell stringValue] length]];
    return cell;
}
- (void)selectText:(id)sender
{
    if ([self selectedCell]) [self selectTextAtRow:[self selectedRow] column:[self selectedColumn]];
    else for (NSInteger i = 0; i < [_cells count]; i++) if ([[_cells objectAtIndex:i] isSelectable]) { [self selectTextAtRow:i / _columns column:i % _columns]; break; }
}
- (void)textDidEndEditing:(NSNotification *)note
{
    NSInteger movement = [[[note userInfo] objectForKey:@"NSTextMovement"] integerValue], index = _selected;
    BOOL traverse = _tabTraverses && (movement == NSTextMovementTab || movement == NSTextMovementBacktab);
    if (traverse) {
        NSMutableDictionary *info = [[[note userInfo] mutableCopy] autorelease]; info[@"NSTextMovement"] = @(NSTextMovementOther);
        [super textDidEndEditing:[NSNotification notificationWithName:[note name] object:[note object] userInfo:info]];
        NSInteger next = index + (movement == NSTextMovementTab ? 1 : -1);
        while (next >= 0 && next < [_cells count]) {
            NSCell *cell = [_cells objectAtIndex:next];
            if ([cell isEnabled] && [cell isSelectable]) { [self selectTextAtRow:next / _columns column:next % _columns]; return; }
            next += movement == NSTextMovementTab ? 1 : -1;
        }
        if (movement == NSTextMovementTab) [[self window] selectKeyViewFollowingView:self]; else [[self window] selectKeyViewPrecedingView:self];
    } else [super textDidEndEditing:note];
}
- (id)objectValue { [self validateEditing]; return [[self selectedCell] objectValue]; }
- (void)setObjectValue:(id)o { [self abortEditing]; [[self selectedCell] setObjectValue:o]; }
- (NSString *)stringValue { [self validateEditing]; return [[self selectedCell] stringValue] ?: @""; }
- (void)setStringValue:(NSString *)s { [self abortEditing]; [[self selectedCell] setStringValue:s]; }
- (NSInteger)integerValue { return [[self selectedCell] integerValue]; }
- (void)setIntegerValue:(NSInteger)n { [[self selectedCell] setIntegerValue:n]; }
- (double)doubleValue { return [[self selectedCell] doubleValue]; }
- (void)setDoubleValue:(double)n { [[self selectedCell] setDoubleValue:n]; }
- (void)setToolTip:(NSString *)tip forCell:(NSCell *)cell { if (tip) [_toolTips setObject:tip forKey:cell]; else [_toolTips removeObjectForKey:cell]; }
- (NSString *)toolTipForCell:(NSCell *)cell { return [_toolTips objectForKey:cell]; }
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data { return [self toolTipForCell:(id)data]; }
- (void)resetCursorRects
{
    [self removeAllToolTips];
    for (NSCell *cell in _cells) if ([self toolTipForCell:cell]) {
        NSInteger row, column; [self getRow:&row column:&column ofCell:cell];
        [self addToolTipRect:[self cellFrameAtRow:row column:column] owner:self userData:cell];
    }
}
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item { return [self isEnabled]; }
+ (NSArray *)_finchBuiltinBindings { return [[super _finchBuiltinBindings] arrayByAddingObjectsFromArray:@[NSSelectedIndexBinding, NSSelectedTagBinding, NSSelectedObjectBinding]]; }
- (void)_finchBindingChanged:(_FinchBinding *)b
{
    if ([b->_name isEqual:NSSelectedTagBinding]) [self selectCellWithTag:[[b rawValue] integerValue]];
    else if ([b->_name isEqual:NSSelectedIndexBinding] && _columns) { NSInteger i = [[b rawValue] integerValue]; [self selectCellAtRow:i / _columns column:i % _columns]; }
    else [super _finchBindingChanged:b];
}
- (void)_finchWillSendAction
{
    [super _finchWillSendAction]; FinchBindingPush(self, NSSelectedIndexBinding, @(_selected));
    FinchBindingPush(self, NSSelectedTagBinding, @([[self selectedCell] tag])); FinchBindingPush(self, NSSelectedObjectBinding, [[self selectedCell] representedObject]);
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityListRole; }
- (NSString *)accessibilitySubrole { return nil; }
- (NSArray *)accessibilityChildren { return [self cells]; }
@end
