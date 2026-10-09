/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Column browser: item delegates use Finch row views; old delegates receive
 * an NSMatrix. Both paths share branch loading, paths and selection. */
#import "NSControl_Finch.h"
#include <math.h>
#import <objc/message.h>
NSNotificationName NSBrowserColumnConfigurationDidChangeNotification =
    @"NSBrowserColumnConfigurationDidChangeNotification";
@class FinchBrowserColumn;
@interface NSBrowser (FinchBrowser)
- (void)_finchUserSelect:(NSIndexSet *)indexes column:(NSInteger)column doubleClick:(BOOL)doubleClick;
- (CGFloat)_finchHeightOfRow:(NSInteger)row column:(NSInteger)column;
- (void)_finchKey:(NSEvent *)event column:(NSInteger)column;
@end
@interface FinchBrowserRows : NSView {
  @public
    NSBrowser *browser;         /* owned by the parent view */
    FinchBrowserColumn *column; /* owned by the browser */
}
@end
@interface FinchBrowserColumn : NSObject {
  @public
    NSMutableArray *items, *cells;
    NSMutableIndexSet *selection;
    NSString *title;
    id parent;
    NSScrollView *scroll;
    NSView *rows;
    NSMatrix *matrix;
    CGFloat width;
    NSInteger index;
}
@end
@implementation FinchBrowserColumn
- (instancetype)init
{
    if ((self = [super init])) {
        items = [[NSMutableArray alloc] init];
        cells = [[NSMutableArray alloc] init];
        selection = [[NSMutableIndexSet alloc] init];
    }
    return self;
}
- (void)dealloc
{
    [scroll removeFromSuperview];
    [items release];
    [cells release];
    [selection release];
    [title release];
    [parent release];
    [scroll release];
    [rows release];
    [super dealloc];
}
@end
@implementation FinchBrowserRows
- (BOOL)isFlipped
{
    return YES;
}
- (BOOL)acceptsFirstResponder
{
    return YES;
}
- (void)drawRect:(NSRect)dirty
{
    [[NSColor textBackgroundColor] setFill];
    NSRectFill(dirty);
    CGFloat y = 0;
    for (NSUInteger row = 0; row < column->cells.count; row++) {
        CGFloat height = [browser _finchHeightOfRow:row column:column->index];
        NSRect frame = NSMakeRect(0, y, self.bounds.size.width, height);
        if (NSIntersectsRect(frame, dirty)) {
            NSBrowserCell *cell = [browser loadedCellAtRow:row column:column->index];
            cell.state = [column->selection containsIndex:row] ? NSControlStateValueOn : NSControlStateValueOff;
            [cell drawWithFrame:frame inView:self];
        }
        y += height;
    }
}
- (void)mouseDown:(NSEvent *)event
{
    [self.window makeFirstResponder:self];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat y = 0;
    NSInteger hit = -1;
    for (NSUInteger row = 0; row < column->cells.count; row++) {
        CGFloat height = [browser _finchHeightOfRow:row column:column->index];
        if (point.y >= y && point.y < y + height) {
            hit = row;
            break;
        }
        y += height;
    }
    if (hit < 0) {
        if (browser.allowsEmptySelection)
            [browser _finchUserSelect:[NSIndexSet indexSet] column:column->index doubleClick:NO];
        return;
    }
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSetWithIndex:hit];
    if (browser.allowsMultipleSelection && (event.modifierFlags & NSEventModifierFlagCommand)) {
        indexes = [[column->selection mutableCopy] autorelease];
        if ([indexes containsIndex:hit])
            [indexes removeIndex:hit];
        else
            [indexes addIndex:hit];
    } else if (browser.allowsMultipleSelection && (event.modifierFlags & NSEventModifierFlagShift) &&
               column->selection.count) {
        NSUInteger anchor = column->selection.firstIndex;
        indexes = [NSMutableIndexSet
            indexSetWithIndexesInRange:NSMakeRange(MIN(anchor, hit), MAX(anchor, hit) - MIN(anchor, hit) + 1)];
    }
    [browser _finchUserSelect:indexes column:column->index doubleClick:event.clickCount > 1];
}
- (void)keyDown:(NSEvent *)event
{
    [browser _finchKey:event column:column->index];
}
@end

@implementation NSBrowser {
    NSMutableArray *_columns;
    NSBrowserCell *_prototype;
    NSScroller *_columnScroller;
    __weak id<NSBrowserDelegate> _delegate;
    Class _matrixClass;
    SEL _doubleAction;
    NSString *_separator, *_autosave;
    id _root;
    CGFloat _minWidth, _defaultWidth, _rowHeight;
    NSInteger _maximumVisible, _firstVisible;
    NSBrowserColumnResizingType _resizing;
    BOOL _loaded, _itemBased, _reuse, _horizontal, _autohide, _separates, _titled, _multiple, _branches, _empty,
        _previousTitle, _arrowAction, _allResize, _typeSelect;
}
+ (Class)cellClass
{
    return [NSBrowserCell class];
}
- (void)_finchDefaults
{
    _columns = [[NSMutableArray alloc] init];
    _prototype = [[NSBrowserCell alloc] initTextCell:@""];
    _separator = [@"/" copy];
    _minWidth = 100;
    _defaultWidth = -1;
    _rowHeight = 24;
    _resizing = NSBrowserAutoColumnResizing;
    _separates = YES;
    _titled = YES;
    _empty = YES;
    _previousTitle = YES;
    _typeSelect = YES;
    _matrixClass = objc_getClass("NSMatrix");
    _columnScroller = [[NSScroller alloc] initWithFrame:NSMakeRect(0, 0, 100, 16)];
    _columnScroller.target = self;
    _columnScroller.action = @selector(scrollViaScroller:);
    _columnScroller.hidden = YES;
    [self addSubview:_columnScroller];
}
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        [self _finchDefaults];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        [self _finchDefaults];
        NSBrowserCell *prototype = [coder decodeObjectForKey:@"NSCellPrototype"];
        if (prototype)
            self.cellPrototype = prototype;
        NSString *separator = [coder decodeObjectForKey:@"NSPathSeparator"];
        if (separator)
            self.pathSeparator = separator;
        if ([coder containsValueForKey:@"NSMinColumnWidth"])
            _minWidth = [coder decodeDoubleForKey:@"NSMinColumnWidth"];
        if ([coder containsValueForKey:@"NSMaxNumberOfVisibleColumns"])
            _maximumVisible = [coder decodeIntegerForKey:@"NSMaxNumberOfVisibleColumns"];
        if ([coder containsValueForKey:@"NSColumnResizingType"])
            _resizing = [coder decodeIntegerForKey:@"NSColumnResizingType"];
        if ([coder containsValueForKey:@"NSPreferedColumnWidth"])
            _defaultWidth = [coder decodeDoubleForKey:@"NSPreferedColumnWidth"];
        if ([coder containsValueForKey:@"NSBrowserRowHeight"])
            _rowHeight = [coder decodeDoubleForKey:@"NSBrowserRowHeight"];
        if ([coder containsValueForKey:@"NSBrFlags"]) {
            uint32_t flags = [coder decodeInt32ForKey:@"NSBrFlags"];
            _multiple = !!(flags & 0x80000000);
            _branches = !!(flags & 0x40000000);
            _reuse = !!(flags & 0x20000000);
            _titled = !!(flags & 0x10000000);
            _previousTitle = !!(flags & 0x08000000);
            _horizontal = !!(flags & 0x10000);
            _empty = !(flags & 0x20000);
            _arrowAction = !!(flags & 0x40000);
        }
        id delegate = [coder decodeObjectForKey:@"NSDelegate"];
        if (delegate)
            self.delegate = delegate;
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_prototype forKey:@"NSCellPrototype"];
    [coder encodeObject:_separator forKey:@"NSPathSeparator"];
    [coder encodeDouble:_minWidth forKey:@"NSMinColumnWidth"];
    [coder encodeInteger:_maximumVisible forKey:@"NSMaxNumberOfVisibleColumns"];
    [coder encodeInteger:_resizing forKey:@"NSColumnResizingType"];
    [coder encodeDouble:_defaultWidth forKey:@"NSPreferedColumnWidth"];
    [coder encodeDouble:_rowHeight forKey:@"NSBrowserRowHeight"];
    uint32_t flags = (_multiple ? 0x80000000 : 0) | (_branches ? 0x40000000 : 0) | (_reuse ? 0x20000000 : 0) |
                     (_titled ? 0x10000000 : 0) | (_previousTitle ? 0x08000000 : 0) | (_horizontal ? 0x10000 : 0) |
                     (!_empty ? 0x20000 : 0) | (_arrowAction ? 0x40000 : 0) | 0x4000;
    [coder encodeInt32:flags forKey:@"NSBrFlags"];
    [coder encodeConditionalObject:_delegate forKey:@"NSDelegate"];
}
- (void)dealloc
{
    [_columns release];
    [_columnScroller release];
    [_prototype release];
    [_separator release];
    [_autosave release];
    [_root release];
    [super dealloc];
}
- (BOOL)acceptsFirstResponder
{
    return YES;
}
- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self tile];
}
- (id<NSBrowserDelegate>)delegate
{
    return _delegate;
}
- (void)setDelegate:(id<NSBrowserDelegate>)delegate
{
    _delegate = delegate;
    _itemBased = [delegate respondsToSelector:@selector(browser:numberOfChildrenOfItem:)] &&
                 [delegate respondsToSelector:@selector(browser:child:ofItem:)];
    if (_loaded)
        [self loadColumnZero];
}
- (id)cellPrototype
{
    return _prototype;
}
- (void)setCellPrototype:(id)cell
{
    if (_prototype != cell) {
        [_prototype release];
        _prototype = [cell retain] ?: [[NSBrowserCell alloc] initTextCell:@""];
    }
}
- (void)setCellClass:(Class)cls
{
    self.cellPrototype = [[[cls alloc] initTextCell:@""] autorelease];
}
- (Class)matrixClass
{
    return _matrixClass;
}
- (void)setMatrixClass:(Class)cls
{
    _matrixClass = cls;
}
- (SEL)doubleAction
{
    return _doubleAction;
}
- (void)setDoubleAction:(SEL)action
{
    _doubleAction = action;
}
- (BOOL)isLoaded
{
    return _loaded;
}
#define FLAG(getter, setter, member)                                                                                   \
    -(BOOL)getter { return member; }                                                                                   \
    -(void)setter : (BOOL)value                                                                                        \
    {                                                                                                                  \
        member = value;                                                                                                \
        [self tile];                                                                                                   \
    }
FLAG(reusesColumns, setReusesColumns, _reuse)
FLAG(hasHorizontalScroller, setHasHorizontalScroller, _horizontal)
FLAG(autohidesScroller, setAutohidesScroller, _autohide)
FLAG(separatesColumns, setSeparatesColumns, _separates)
FLAG(isTitled, setTitled, _titled)
FLAG(allowsMultipleSelection, setAllowsMultipleSelection, _multiple)
FLAG(allowsBranchSelection, setAllowsBranchSelection, _branches)
FLAG(allowsEmptySelection, setAllowsEmptySelection, _empty)
FLAG(takesTitleFromPreviousColumn, setTakesTitleFromPreviousColumn, _previousTitle)
FLAG(sendsActionOnArrowKeys, setSendsActionOnArrowKeys, _arrowAction)
FLAG(prefersAllColumnUserResizing, setPrefersAllColumnUserResizing, _allResize)
FLAG(allowsTypeSelect, setAllowsTypeSelect, _typeSelect)
- (CGFloat)minColumnWidth
{
    return _minWidth;
}
- (void)setMinColumnWidth:(CGFloat)value
{
    _minWidth = MAX(1, value);
    [self tile];
}
- (NSInteger)maxVisibleColumns
{
    return _maximumVisible;
}
- (void)setMaxVisibleColumns:(NSInteger)value
{
    _maximumVisible = MAX(0, value);
    [self tile];
}
- (NSBrowserColumnResizingType)columnResizingType
{
    return _resizing;
}
- (void)setColumnResizingType:(NSBrowserColumnResizingType)value
{
    _resizing = value;
    [self tile];
}
- (CGFloat)defaultColumnWidth
{
    return _defaultWidth;
}
- (void)setDefaultColumnWidth:(CGFloat)value
{
    _defaultWidth = value;
    [self tile];
}
- (CGFloat)rowHeight
{
    if (!_itemBased)
        [NSException raise:NSInternalInconsistencyException
                    format:@"rowHeight is not supported for browsers with matrix delegates."];
    return _rowHeight;
}
- (void)setRowHeight:(CGFloat)value
{
    if (value <= 0)
        [NSException raise:NSInvalidArgumentException format:@"rowHeight must be positive"];
    _rowHeight = ceil(value);
    [self tile];
}
- (CGFloat)_finchHeightOfRow:(NSInteger)row column:(NSInteger)index
{
    if (_itemBased && [_delegate respondsToSelector:@selector(browser:heightOfRow:inColumn:)])
        return MAX(1, [_delegate browser:self heightOfRow:row inColumn:index]);
    return _itemBased ? _rowHeight : ceil((_prototype.font ?: [NSFont systemFontOfSize:13]).pointSize * 1.2);
}
- (FinchBrowserColumn *)_finchColumn:(NSInteger)index
{
    return index >= 0 && index < (NSInteger)_columns.count ? _columns[index] : nil;
}
- (NSInteger)lastColumn
{
    return (NSInteger)_columns.count - 1;
}
- (void)setLastColumn:(NSInteger)last
{
    if (last >= self.lastColumn)
        return;
    last = MAX(-1, last);
    NSInteger old = self.lastColumn;
    while (self.lastColumn > last) {
        FinchBrowserColumn *c = _columns.lastObject;
        [c->scroll removeFromSuperview];
        [_columns removeLastObject];
    }
    _firstVisible = MIN(_firstVisible, MAX(0, last));
    if ([_delegate respondsToSelector:@selector(browser:didChangeLastColumn:toColumn:)])
        [_delegate browser:self didChangeLastColumn:old toColumn:last];
    [self tile];
}
- (void)loadColumnZero
{
    [self setLastColumn:-1];
    [_root release];
    _root = nil;
    if (_itemBased && [_delegate respondsToSelector:@selector(rootItemForBrowser:)])
        _root = [[_delegate rootItemForBrowser:self] retain];
    _loaded = YES;
    _firstVisible = 0;
    [self addColumn];
}
- (void)addColumn
{
    NSInteger old = self.lastColumn;
    FinchBrowserColumn *c = [[FinchBrowserColumn alloc] init];
    c->index = old + 1;
    if (c->index == 0)
        c->parent = [_root retain];
    else
        c->parent = [[self itemAtRow:[self selectedRowInColumn:old] inColumn:old] retain];
    c->width = _defaultWidth > 0 ? MAX(_minWidth, _defaultWidth) : _minWidth;
    if (_resizing != NSBrowserAutoColumnResizing &&
        [_delegate respondsToSelector:@selector(browser:shouldSizeColumn:forUserResize:toWidth:)])
        c->width = MAX(_minWidth, [_delegate browser:self shouldSizeColumn:c->index forUserResize:NO toWidth:c->width]);
    c->scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    c->scroll.borderType = NSNoBorder;
    c->scroll.hasVerticalScroller = YES;
    c->scroll.autohidesScrollers = YES;
    if (_itemBased || !_matrixClass) {
        FinchBrowserRows *rows = [[FinchBrowserRows alloc] initWithFrame:NSZeroRect];
        rows->browser = self;
        rows->column = c;
        c->rows = rows;
    } else {
        c->matrix = [[_matrixClass alloc] initWithFrame:NSZeroRect
                                                   mode:_multiple ? NSListModeMatrix : NSRadioModeMatrix
                                              prototype:_prototype
                                           numberOfRows:0
                                        numberOfColumns:1];
        c->rows = c->matrix;
        c->matrix.target = self;
        c->matrix.action = @selector(doClick:);
        c->matrix.doubleAction = @selector(doDoubleClick:);
        c->matrix.allowsEmptySelection = _empty;
        c->matrix.intercellSpacing = NSZeroSize;
    }
    c->scroll.documentView = c->rows;
    [_columns addObject:c];
    [self addSubview:c->scroll];
    [c release];
    [self reloadColumn:old + 1];
    if ([_delegate respondsToSelector:@selector(browser:didChangeLastColumn:toColumn:)])
        [_delegate browser:self didChangeLastColumn:old toColumn:old + 1];
}
- (void)reloadColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c)
        return;
    NSMutableArray *oldSelection = [NSMutableArray array];
    [c->selection enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
      if (row < c->cells.count)
          [oldSelection addObject:_itemBased && row < c->items.count ? c->items[row] : [c->cells[row] stringValue]];
    }];
    [c->items removeAllObjects];
    [c->cells removeAllObjects];
    [c->selection removeAllIndexes];
    if (_itemBased) {
        NSInteger count = MAX(0, [_delegate browser:self numberOfChildrenOfItem:c->parent]);
        for (NSInteger row = 0; row < count; row++) {
            id item = [_delegate browser:self child:row ofItem:c->parent];
            if (!item)
                item = [NSNull null];
            [c->items addObject:item];
            NSBrowserCell *cell = [[_prototype copy] autorelease];
            cell.objectValue = [_delegate respondsToSelector:@selector(browser:objectValueForItem:)]
                                   ? [_delegate browser:self objectValueForItem:item]
                                   : [item description];
            cell.leaf = [self isLeafItem:item];
            cell.loaded = YES;
            [c->cells addObject:cell];
        }
    } else if (c->matrix) {
        if ([_delegate respondsToSelector:@selector(browser:createRowsForColumn:inMatrix:)])
            [_delegate browser:self createRowsForColumn:index inMatrix:c->matrix];
        else {
            NSInteger count = [_delegate respondsToSelector:@selector(browser:numberOfRowsInColumn:)]
                                  ? MAX(0, [_delegate browser:self numberOfRowsInColumn:index])
                                  : 0;
            [c->matrix renewRows:count columns:1];
        }
        for (NSInteger row = 0; row < c->matrix.numberOfRows; row++) {
            NSBrowserCell *cell = [c->matrix cellAtRow:row column:0];
            [c->cells addObject:cell];
        }
    }
    for (NSUInteger row = 0; row < c->cells.count; row++) {
        NSBrowserCell *cell = [self loadedCellAtRow:row column:index];
        id value = _itemBased ? c->items[row] : cell.stringValue;
        if ([oldSelection containsObject:value])
            [c->selection addIndex:row];
        cell.state = [c->selection containsIndex:row] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (c->matrix) {
        [c->matrix deselectAllCells];
        [c->selection enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
          [c->matrix selectCellAtRow:row column:0];
        }];
    }
    BOOL branch = c->selection.count == 1 && ![[self loadedCellAtRow:c->selection.firstIndex column:index] isLeaf];
    FinchBrowserColumn *next = [self _finchColumn:index + 1];
    if (!branch)
        [self setLastColumn:index];
    else if (next) {
        id parent = [self itemAtRow:c->selection.firstIndex inColumn:index];
        [next->parent release];
        next->parent = [parent retain];
        [self reloadColumn:index + 1];
    } else
        [self addColumn];
    [c->title release];
    c->title = nil;
    if ([_delegate respondsToSelector:@selector(browser:titleOfColumn:)])
        c->title = [[_delegate browser:self titleOfColumn:index] copy];
    if (!c->title && _previousTitle && index > 0)
        c->title = [[[self selectedCellInColumn:index - 1] stringValue] copy];
    if (!c->title)
        c->title = [@"" copy];
    [self tile];
}
- (id)loadedCellAtRow:(NSInteger)row column:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c || row < 0 || row >= (NSInteger)c->cells.count)
        return nil;
    NSBrowserCell *cell = c->cells[row];
    if ([_delegate respondsToSelector:@selector(browser:willDisplayCell:atRow:column:)])
        [_delegate browser:self willDisplayCell:cell atRow:row column:index];
    cell.loaded = YES;
    return cell;
}
- (id)itemAtRow:(NSInteger)row inColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    return c && row >= 0 && row < (NSInteger)c->items.count ? c->items[row] : nil;
}
- (id)parentForItemsInColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    return c ? c->parent : nil;
}
- (BOOL)isLeafItem:(id)item
{
    return [_delegate respondsToSelector:@selector(browser:isLeafItem:)] ? [_delegate browser:self isLeafItem:item]
                                                                         : YES;
}
- (NSMatrix *)matrixInColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    return c ? c->matrix : nil;
}
- (NSInteger)columnOfMatrix:(NSMatrix *)matrix
{
    for (FinchBrowserColumn *c in _columns)
        if (c->matrix == matrix && matrix)
            return c->index;
    return -1;
}
- (void)selectRow:(NSInteger)row inColumn:(NSInteger)index
{
    if ([_delegate respondsToSelector:@selector(browser:selectRow:inColumn:)] && ![_delegate browser:self
                                                                                           selectRow:row
                                                                                            inColumn:index])
        return;
    [self selectRowIndexes:row < 0 ? [NSIndexSet indexSet] : [NSIndexSet indexSetWithIndex:row] inColumn:index];
}
- (void)selectRowIndexes:(NSIndexSet *)indexes inColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c)
        return;
    NSMutableIndexSet *selection = [NSMutableIndexSet indexSet];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
      if (row < c->cells.count && [[self loadedCellAtRow:row column:index] isEnabled]) {
          [selection addIndex:row];
          if (!_multiple)
              *stop = YES;
      }
    }];
    if (!selection.count && !_empty && c->selection.count)
        return;
    [c->selection removeAllIndexes];
    [c->selection addIndexes:selection];
    for (NSUInteger row = 0; row < c->cells.count; row++)
        [c->cells[row] setState:[selection containsIndex:row] ? NSControlStateValueOn : NSControlStateValueOff];
    if (c->matrix) {
        [c->matrix deselectAllCells];
        [selection enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
          [c->matrix selectCellAtRow:row column:0];
        }];
    }
    [self setLastColumn:index];
    if (selection.count == 1) {
        NSBrowserCell *cell = [self loadedCellAtRow:selection.firstIndex column:index];
        if (!cell.leaf)
            [self addColumn];
    }
    [c->rows setNeedsDisplay:YES];
    [self scrollColumnToVisible:self.lastColumn];
}
- (NSInteger)selectedRowInColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    return c && c->selection.count ? (NSInteger)c->selection.firstIndex : -1;
}
- (NSIndexSet *)selectedRowIndexesInColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    return c ? [[c->selection copy] autorelease] : nil;
}
- (NSInteger)selectedColumn
{
    for (NSInteger i = self.lastColumn; i >= 0; i--)
        if ([self selectedRowInColumn:i] >= 0)
            return i;
    return -1;
}
- (id)selectedCellInColumn:(NSInteger)index
{
    return [self loadedCellAtRow:[self selectedRowInColumn:index] column:index];
}
- (id)selectedCell
{
    return [self selectedCellInColumn:self.selectedColumn];
}
- (NSArray *)selectedCells
{
    FinchBrowserColumn *c = [self _finchColumn:self.selectedColumn];
    if (!c)
        return nil;
    NSMutableArray *cells = [NSMutableArray array];
    [c->selection enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
      [cells addObject:[self loadedCellAtRow:row column:c->index]];
    }];
    return cells;
}
- (NSInteger)clickedRow
{
    return -1;
}
- (NSInteger)clickedColumn
{
    return -1;
}
- (void)_finchUserSelect:(NSIndexSet *)indexes column:(NSInteger)index doubleClick:(BOOL)doubleClick
{
    if (_itemBased && [_delegate respondsToSelector:@selector(browser:selectionIndexesForProposedSelection:inColumn:)])
        indexes = [_delegate browser:self selectionIndexesForProposedSelection:indexes inColumn:index];
    [self selectRowIndexes:indexes inColumn:index];
    if (doubleClick && _doubleAction)
        [self sendAction:_doubleAction to:self.target];
    else
        [self sendAction];
}
- (NSIndexSet *)_finchMatrixSelection:(NSMatrix *)matrix column:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    NSMutableIndexSet *selection = [NSMutableIndexSet indexSet];
    for (NSCell *cell in matrix.selectedCells) {
        NSUInteger row = [c->cells indexOfObjectIdenticalTo:cell];
        if (row != NSNotFound)
            [selection addIndex:row];
    }
    return selection;
}
- (void)doClick:(NSMatrix *)sender
{
    NSInteger column = [self columnOfMatrix:sender];
    if (column >= 0)
        [self _finchUserSelect:[self _finchMatrixSelection:sender column:column] column:column doubleClick:NO];
}
- (void)doDoubleClick:(NSMatrix *)sender
{
    NSInteger column = [self columnOfMatrix:sender];
    if (column >= 0)
        [self _finchUserSelect:[self _finchMatrixSelection:sender column:column] column:column doubleClick:YES];
}
- (BOOL)sendAction
{
    return [super sendAction:self.action to:self.target];
}
- (void)selectAll:(id)sender
{
    NSInteger index = MAX(0, self.selectedColumn);
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!_multiple || !c)
        return;
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < c->cells.count; i++)
        if (_branches || [[self loadedCellAtRow:i column:index] isLeaf])
            [set addIndex:i];
    [self selectRowIndexes:set inColumn:index];
}
- (NSString *)pathSeparator
{
    return _separator;
}
- (void)setPathSeparator:(NSString *)separator
{
    if (!separator.length)
        [NSException raise:NSInvalidArgumentException format:@"pathSeparator must not be empty"];
    if (_separator != separator) {
        [_separator release];
        _separator = [separator copy];
    }
}
- (NSString *)pathToColumn:(NSInteger)index
{
    if (!_loaded || index <= 0 || self.selectedColumn < 0)
        return @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSInteger i = 0; i < index && i <= self.lastColumn; i++) {
        NSCell *cell = [self selectedCellInColumn:i];
        if (!cell)
            break;
        [parts addObject:cell.stringValue ?: @""];
    }
    return [_separator stringByAppendingString:[parts componentsJoinedByString:_separator]];
}
- (NSString *)path
{
    return [self pathToColumn:self.selectedColumn + 1];
}
- (BOOL)setPath:(NSString *)path
{
    if (!path)
        return NO;
    if (!_loaded)
        [self loadColumnZero];
    NSArray *parts = [path componentsSeparatedByString:_separator];
    NSInteger column = 0;
    [self selectRowIndexes:[NSIndexSet indexSet] inColumn:0];
    for (NSString *part in parts) {
        if (!part.length)
            continue;
        FinchBrowserColumn *c = [self _finchColumn:column];
        if (!c)
            return NO;
        if ([_delegate respondsToSelector:@selector(browser:selectCellWithString:inColumn:)]) {
            if (![_delegate browser:self selectCellWithString:part inColumn:column])
                return NO;
        }
        NSInteger match = -1;
        for (NSUInteger row = 0; row < c->cells.count; row++)
            if ([[[self loadedCellAtRow:row column:column] stringValue] isEqual:part]) {
                match = row;
                break;
            }
        if (match < 0)
            return NO;
        [self selectRow:match inColumn:column++];
    }
    return YES;
}
- (NSIndexPath *)indexPathForColumn:(NSInteger)column
{
    NSIndexPath *path = [NSIndexPath indexPathWithIndexes:NULL length:0];
    for (NSInteger i = 0; i < column; i++) {
        NSInteger row = [self selectedRowInColumn:i];
        if (row < 0)
            break;
        path = [path indexPathByAddingIndex:row];
    }
    return path;
}
- (NSIndexPath *)selectionIndexPath
{
    NSInteger column = self.selectedColumn;
    if (column < 0)
        return nil;
    return [[self indexPathForColumn:column] indexPathByAddingIndex:[self selectedRowInColumn:column]];
}
- (id)itemAtIndexPath:(NSIndexPath *)path
{
    id item = _root;
    if (!_itemBased)
        return nil;
    for (NSUInteger i = 0; i < path.length; i++) {
        NSUInteger row = [path indexAtPosition:i];
        NSInteger count = [_delegate browser:self numberOfChildrenOfItem:item];
        if (row >= (NSUInteger)MAX(0, count))
            return nil;
        item = [_delegate browser:self child:row ofItem:item];
    }
    return item;
}
- (void)setSelectionIndexPath:(NSIndexPath *)path
{
    if (!path) {
        if (_loaded)
            [self selectRowIndexes:[NSIndexSet indexSet] inColumn:0];
        return;
    }
    if (!_itemBased)
        [NSException raise:NSInternalInconsistencyException format:@"Index paths require an item delegate"];
    if (!_loaded)
        [self loadColumnZero];
    for (NSUInteger depth = 0; depth < path.length; depth++) {
        FinchBrowserColumn *c = [self _finchColumn:depth];
        NSUInteger row = [path indexAtPosition:depth];
        if (!c || row >= c->items.count)
            [NSException raise:NSInvalidArgumentException format:@"Invalid browser index path"];
        [self selectRow:row inColumn:depth];
    }
}
- (NSArray *)selectionIndexPaths
{
    NSInteger index = self.selectedColumn;
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c)
        return @[];
    NSMutableArray *paths = [NSMutableArray array];
    NSIndexPath *parent = [self indexPathForColumn:index];
    [c->selection enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
      [paths addObject:[parent indexPathByAddingIndex:row]];
    }];
    return paths;
}
- (void)setSelectionIndexPaths:(NSArray *)paths
{
    if (!paths.count) {
        self.selectionIndexPath = nil;
        return;
    }
    NSIndexPath *first = paths[0];
    self.selectionIndexPath = first;
    if (first.length == 0)
        return;
    NSMutableIndexSet *selection = [NSMutableIndexSet indexSet];
    NSIndexPath *parent = [first indexPathByRemovingLastIndex];
    for (NSIndexPath *path in paths) {
        if (path.length != first.length || ![[path indexPathByRemovingLastIndex] isEqual:parent])
            [NSException raise:NSInvalidArgumentException format:@"Browser selections must share a parent"];
        [selection addIndex:[path indexAtPosition:path.length - 1]];
    }
    [self selectRowIndexes:selection inColumn:first.length - 1];
}
- (void)setTitle:(NSString *)title ofColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c)
        return;
    [c->title release];
    c->title = [title copy];
    [self setNeedsDisplay:YES];
}
- (NSString *)titleOfColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    return c ? c->title : nil;
}
- (CGFloat)titleHeight
{
    return _titled ? 20 : 0;
}
- (NSInteger)numberOfVisibleColumns
{
    NSInteger count = MAX(1, (NSInteger)floor((self.bounds.size.width + 2) / (_minWidth + 2)));
    if (_maximumVisible > 0)
        count = MIN(count, _maximumVisible);
    return count;
}
- (NSInteger)firstVisibleColumn
{
    return _firstVisible;
}
- (NSInteger)lastVisibleColumn
{
    return MIN(self.lastColumn, _firstVisible + self.numberOfVisibleColumns - 1);
}
- (CGFloat)widthOfColumn:(NSInteger)index
{
    if (_resizing == NSBrowserAutoColumnResizing)
        return floor((self.bounds.size.width - (self.numberOfVisibleColumns - 1) * 2) / self.numberOfVisibleColumns);
    FinchBrowserColumn *c = [self _finchColumn:index];
    return c ? c->width : (_defaultWidth > 0 ? MAX(_minWidth, _defaultWidth) : _minWidth);
}
- (void)setWidth:(CGFloat)width ofColumn:(NSInteger)index
{
    if (_resizing == NSBrowserAutoColumnResizing)
        return;
    if (index < 0) {
        self.defaultColumnWidth = width;
        return;
    }
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c)
        return;
    width = MAX(_minWidth, width);
    if ([_delegate respondsToSelector:@selector(browser:shouldSizeColumn:forUserResize:toWidth:)])
        width = MAX(_minWidth, [_delegate browser:self shouldSizeColumn:index forUserResize:YES toWidth:width]);
    if (c->width == width)
        return;
    c->width = width;
    [self tile];
    NSNotification *note = [NSNotification notificationWithName:NSBrowserColumnConfigurationDidChangeNotification
                                                         object:self];
    [[NSNotificationCenter defaultCenter] postNotification:note];
    if ([_delegate respondsToSelector:@selector(browserColumnConfigurationDidChange:)])
        [_delegate browserColumnConfigurationDidChange:note];
    if (_autosave.length) {
        NSMutableArray *widths = [NSMutableArray array];
        for (FinchBrowserColumn *column in _columns)
            [widths addObject:@(column->width)];
        [[NSUserDefaults standardUserDefaults] setObject:widths
                                                  forKey:[@"NSBrowserColumns " stringByAppendingString:_autosave]];
    }
}
- (NSBrowserColumnsAutosaveName)columnsAutosaveName
{
    return _autosave;
}
- (void)setColumnsAutosaveName:(NSBrowserColumnsAutosaveName)name
{
    if ([_autosave isEqual:name])
        return;
    [_autosave release];
    _autosave = [name copy];
    NSArray *widths = name.length ? [[NSUserDefaults standardUserDefaults]
                                        arrayForKey:[@"NSBrowserColumns " stringByAppendingString:name]]
                                  : nil;
    for (NSUInteger i = 0; i < MIN(widths.count, _columns.count); i++)
        ((FinchBrowserColumn *)_columns[i])->width = MAX(_minWidth, [widths[i] doubleValue]);
    [self tile];
}
+ (void)removeSavedColumnsWithAutosaveName:(NSBrowserColumnsAutosaveName)name
{
    if (name.length)
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:[@"NSBrowserColumns " stringByAppendingString:name]];
}
- (CGFloat)columnWidthForColumnContentWidth:(CGFloat)width
{
    return width + 1;
}
- (CGFloat)columnContentWidthForColumnWidth:(CGFloat)width
{
    return MAX(0, width - 1);
}
- (NSRect)frameOfColumn:(NSInteger)index
{
    if (index < _firstVisible || index > _firstVisible + self.numberOfVisibleColumns - 1)
        return NSZeroRect;
    CGFloat x = self.bounds.origin.x;
    for (NSInteger i = _firstVisible; i < index; i++)
        x += [self widthOfColumn:i] + 2;
    CGFloat scroller = _horizontal && (!_autohide || self.lastColumn + 1 > self.numberOfVisibleColumns) ? 16 : 0;
    CGFloat top = _titled ? self.titleHeight + 2 : 0;
    return NSMakeRect(x, self.bounds.origin.y + scroller, [self widthOfColumn:index],
                      MAX(0, self.bounds.size.height - top - scroller));
}
- (NSRect)frameOfInsideOfColumn:(NSInteger)index
{
    return [self frameOfColumn:index];
}
- (NSRect)titleFrameOfColumn:(NSInteger)index
{
    if (!_titled)
        return NSZeroRect;
    NSRect frame = [self frameOfColumn:index];
    return NSMakeRect(frame.origin.x, NSMaxY(self.bounds) - self.titleHeight, frame.size.width, self.titleHeight);
}
- (NSRect)frameOfRow:(NSInteger)row inColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c || row < 0 || row >= (NSInteger)c->cells.count)
        return NSZeroRect;
    CGFloat y = 0;
    for (NSInteger i = 0; i < row; i++)
        y += [self _finchHeightOfRow:i column:index];
    CGFloat height = [self _finchHeightOfRow:row column:index];
    return [self convertRect:NSMakeRect(0, y, c->rows.bounds.size.width, height) fromView:c->rows];
}
- (BOOL)getRow:(NSInteger *)row column:(NSInteger *)index forPoint:(NSPoint)point
{
    if (row)
        *row = -1;
    if (index)
        *index = -1;
    for (FinchBrowserColumn *c in _columns) {
        if (!NSPointInRect(point, [self frameOfColumn:c->index]))
            continue;
        if (index)
            *index = c->index;
        for (NSUInteger i = 0; i < c->cells.count; i++)
            if (NSPointInRect(point, [self frameOfRow:i inColumn:c->index])) {
                if (row)
                    *row = i;
                return YES;
            }
        return NO;
    }
    return NO;
}
- (void)tile
{
    _columnScroller.hidden = !_horizontal || (_autohide && self.lastColumn + 1 <= self.numberOfVisibleColumns);
    _columnScroller.frame = NSMakeRect(self.bounds.origin.x, self.bounds.origin.y, self.bounds.size.width, 16);
    _columnScroller.enabled = self.lastColumn + 1 > self.numberOfVisibleColumns;
    _columnScroller.knobProportion = MIN(1, (CGFloat)self.numberOfVisibleColumns / MAX(1, self.lastColumn + 1));
    _columnScroller.doubleValue = (double)_firstVisible / MAX(1, self.lastColumn + 1 - self.numberOfVisibleColumns);
    for (FinchBrowserColumn *c in _columns) {
        BOOL visible = c->index >= _firstVisible && c->index < _firstVisible + self.numberOfVisibleColumns;
        c->scroll.hidden = !visible;
        if (!visible)
            continue;
        c->scroll.frame = [self frameOfInsideOfColumn:c->index];
        CGFloat height = 0;
        for (NSUInteger row = 0; row < c->cells.count; row++)
            height += [self _finchHeightOfRow:row column:c->index];
        CGFloat width = c->scroll.contentView.bounds.size.width;
        c->rows.frame = NSMakeRect(0, 0, width, MAX(height, c->scroll.contentView.bounds.size.height));
        if (c->matrix) {
            c->matrix.cellSize = NSMakeSize(width, [self _finchHeightOfRow:0 column:c->index]);
            c->matrix.allowsEmptySelection = _empty;
            c->matrix.mode = _multiple ? NSListModeMatrix : NSRadioModeMatrix;
        }
        [c->rows setNeedsDisplay:YES];
    }
    [self setNeedsDisplay:YES];
}
- (void)drawTitleOfColumn:(NSInteger)index inRect:(NSRect)rect
{
    [FinchControlFill(NO) setFill];
    NSRectFill(rect);
    NSString *title = [self titleOfColumn:index] ?: @"";
    NSAttributedString *text =
        [[[NSAttributedString alloc] initWithString:title
                                         attributes:@{
                                             NSFontAttributeName : [NSFont systemFontOfSize:12],
                                             NSForegroundColorAttributeName : [NSColor secondaryLabelColor]
                                         }] autorelease];
    FinchDrawCellText(text, NSInsetRect(rect, 6, 0), self.isFlipped);
}
- (void)drawRect:(NSRect)dirty
{
    [[NSColor textBackgroundColor] setFill];
    NSRectFill(dirty);
    for (NSInteger i = _firstVisible; i < _firstVisible + self.numberOfVisibleColumns; i++) {
        if (_titled)
            [self drawTitleOfColumn:i inRect:[self titleFrameOfColumn:i]];
        NSRect frame = [self frameOfColumn:i];
        [FinchControlStroke() setFill];
        NSRectFill(NSMakeRect(NSMaxX(frame), self.bounds.origin.y, 1, self.bounds.size.height));
    }
}
- (void)scrollColumnToVisible:(NSInteger)index
{
    NSInteger first = _firstVisible;
    if (index < first)
        first = MAX(0, index);
    else if (index >= first + self.numberOfVisibleColumns)
        first = index - self.numberOfVisibleColumns + 1;
    first = MIN(MAX(0, self.lastColumn), first);
    if (first == _firstVisible)
        return;
    if ([_delegate respondsToSelector:@selector(browserWillScroll:)])
        [_delegate browserWillScroll:self];
    _firstVisible = first;
    [self tile];
    if ([_delegate respondsToSelector:@selector(browserDidScroll:)])
        [_delegate browserDidScroll:self];
}
- (void)scrollColumnsRightBy:(NSInteger)amount
{
    [self scrollColumnToVisible:MIN(self.lastColumn, self.lastVisibleColumn + MAX(0, amount))];
}
- (void)scrollColumnsLeftBy:(NSInteger)amount
{
    [self scrollColumnToVisible:MAX(0, self.firstVisibleColumn - MAX(0, amount))];
}
- (void)scrollRowToVisible:(NSInteger)row inColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c)
        return;
    NSRect rect = [c->rows convertRect:[self frameOfRow:row inColumn:index] fromView:self];
    [c->rows scrollRectToVisible:rect];
}
- (void)validateVisibleColumns
{
    for (NSInteger i = self.firstVisibleColumn; i <= self.lastVisibleColumn; i++)
        if ([_delegate respondsToSelector:@selector(browser:isColumnValid:)] && ![_delegate browser:self
                                                                                      isColumnValid:i])
            [self reloadColumn:i];
}
- (void)reloadDataForRowIndexes:(NSIndexSet *)indexes inColumn:(NSInteger)index
{
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c)
        return;
    [indexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
      if (row >= c->items.count)
          return;
      id item = c->items[row];
      NSBrowserCell *cell = c->cells[row];
      cell.objectValue = [_delegate respondsToSelector:@selector(browser:objectValueForItem:)]
                             ? [_delegate browser:self objectValueForItem:item]
                             : [item description];
      cell.leaf = [self isLeafItem:item];
    }];
    [c->rows setNeedsDisplay:YES];
}
- (void)noteHeightOfRowsWithIndexesChanged:(NSIndexSet *)indexes inColumn:(NSInteger)index
{
    [self tile];
}
- (void)_finchKey:(NSEvent *)event column:(NSInteger)index
{
    NSString *text = event.charactersIgnoringModifiers;
    if (!text.length)
        return;
    unichar key = [text characterAtIndex:0];
    FinchBrowserColumn *c = [self _finchColumn:index];
    if (!c)
        return;
    NSInteger row = [self selectedRowInColumn:index];
    BOOL changed = NO;
    if (key == NSUpArrowFunctionKey || key == NSDownArrowFunctionKey) {
        row = key == NSUpArrowFunctionKey ? MAX(0, row - 1) : MIN((NSInteger)c->cells.count - 1, row + 1);
        [self selectRow:row inColumn:index];
        [self scrollRowToVisible:row inColumn:index];
        changed = YES;
    } else if (key == NSLeftArrowFunctionKey && index > 0) {
        [self setLastColumn:index - 1];
        FinchBrowserColumn *previous = [self _finchColumn:index - 1];
        [self.window makeFirstResponder:previous->rows];
        [self scrollColumnToVisible:index - 1];
        changed = YES;
    } else if (key == NSRightArrowFunctionKey) {
        if (row >= 0 && ![[self selectedCellInColumn:index] isLeaf]) {
            if (self.lastColumn == index)
                [self addColumn];
            FinchBrowserColumn *next = [self _finchColumn:index + 1];
            if (next->cells.count)
                [self selectRow:0 inColumn:index + 1];
            [self.window makeFirstResponder:next->rows];
            [self scrollColumnToVisible:index + 1];
            changed = YES;
        }
    } else if (key == '\r' || key == '\n') {
        if (_doubleAction)
            [self sendAction:_doubleAction to:self.target];
        else
            [self sendAction];
        return;
    } else if (_typeSelect && !(event.modifierFlags & NSEventModifierFlagCommand)) {
        for (NSUInteger offset = 1; offset <= c->cells.count; offset++) {
            NSUInteger candidate = (MAX(-1, row) + offset) % c->cells.count;
            NSString *title = [[self loadedCellAtRow:candidate column:index] stringValue];
            if ([title rangeOfString:text options:NSCaseInsensitiveSearch | NSAnchoredSearch].location == 0) {
                [self selectRow:candidate inColumn:index];
                [self scrollRowToVisible:candidate inColumn:index];
                [self sendAction];
                return;
            }
        }
    }
    if (changed && _arrowAction)
        [self sendAction];
}
- (void)keyDown:(NSEvent *)event
{
    [self _finchKey:event column:MAX(0, self.selectedColumn)];
}
- (void)mouseDown:(NSEvent *)event
{
    if (_resizing != NSBrowserUserColumnResizing)
        return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger hit = -1;
    for (NSInteger i = _firstVisible; i <= self.lastVisibleColumn; i++)
        if (fabs(point.x - NSMaxX([self frameOfColumn:i])) <= 3) {
            hit = i;
            break;
        }
    if (hit < 0 || !self.window)
        return;
    CGFloat original = [self widthOfColumn:hit];
    NSEvent *next;
    while ((next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp])) {
        CGFloat x = [self convertPoint:next.locationInWindow fromView:nil].x;
        CGFloat width = original + x - point.x;
        if (_allResize != !!(next.modifierFlags & NSEventModifierFlagOption))
            for (NSInteger i = 0; i <= self.lastColumn; i++)
                [self setWidth:width ofColumn:i];
        else
            [self setWidth:width ofColumn:hit];
        if (next.type == NSEventTypeLeftMouseUp)
            break;
    }
}
- (void)scrollViaScroller:(NSScroller *)sender
{
    NSInteger first = _firstVisible;
    switch (sender.hitPart) {
    case NSScrollerDecrementLine:
        first--;
        break;
    case NSScrollerIncrementLine:
        first++;
        break;
    case NSScrollerDecrementPage:
        first -= self.numberOfVisibleColumns;
        break;
    case NSScrollerIncrementPage:
        first += self.numberOfVisibleColumns;
        break;
    default:
        first = llround(sender.doubleValue * MAX(0, self.lastColumn + 1 - self.numberOfVisibleColumns));
        break;
    }
    first = MIN(MAX(0, self.lastColumn + 1 - self.numberOfVisibleColumns), MAX(0, first));
    if (first == _firstVisible)
        return;
    if ([_delegate respondsToSelector:@selector(browserWillScroll:)])
        [_delegate browserWillScroll:self];
    _firstVisible = first;
    [self tile];
    if ([_delegate respondsToSelector:@selector(browserDidScroll:)])
        [_delegate browserDidScroll:self];
}
- (void)updateScroller
{
    [self tile];
}
- (void)displayColumn:(NSInteger)index
{
    [self setNeedsDisplayInRect:[self frameOfColumn:index]];
}
- (void)displayAllColumns
{
    [self setNeedsDisplay:YES];
}
- (BOOL)acceptsArrowKeys
{
    return YES;
}
- (void)setAcceptsArrowKeys:(BOOL)flag
{
}
@end
