/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The combo box keeps the typed value separate from its selected list item. */
#import "NSControl_Finch.h"

@interface NSComboBox (FinchComboBox)
- (void)_finchComboSelectionChanged;
@end

/* Nibs store list measurements on a private table object. */
@interface NSComboTableView : NSView
@property CGFloat rowHeight;
@property NSSize intercellSpacing;
@end
@implementation NSComboTableView
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _rowHeight = [coder decodeDoubleForKey:@"NSRowHeight"];
        _intercellSpacing = NSMakeSize([coder decodeDoubleForKey:@"NSIntercellSpacingWidth"], [coder decodeDoubleForKey:@"NSIntercellSpacingHeight"]);
    }
    return self;
}
@end

@implementation NSComboBoxCell {
    NSMutableArray *_items;
    id _dataSource;
    NSInteger _selected, _visible, _dataCount, _topItem;
    NSSize _spacing;
    CGFloat _itemHeight;
    BOOL _scroller, _buttonBordered, _usesData, _completes;
}
- (instancetype)initTextCell:(NSString *)s
{
    if (!(self = [super initTextCell:s])) return nil;
    _items = [NSMutableArray new]; _selected = -1; _visible = 5;
    _spacing = NSMakeSize(17, 0); _itemHeight = 18; _scroller = YES; _buttonBordered = YES;
    [self setEditable:YES]; [self setSelectable:YES]; [self setBezeled:YES];
    [self setDrawsBackground:YES]; [self setScrollable:YES]; [self setLineBreakMode:NSLineBreakByClipping];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder])) return nil;
    _items = [[coder decodeObjectForKey:@"NSPopUpListData"] mutableCopy] ?: [NSMutableArray new];
    _selected = [coder containsValueForKey:@"NSComboSelectedIndex"] ? [coder decodeIntegerForKey:@"NSComboSelectedIndex"] : -1;
    _visible = [coder containsValueForKey:@"NSVisibleItemCount"] ? [coder decodeIntegerForKey:@"NSVisibleItemCount"] : 5;
    _scroller = ![coder containsValueForKey:@"NSHasVerticalScroller"] || [coder decodeBoolForKey:@"NSHasVerticalScroller"];
    _buttonBordered = ![coder containsValueForKey:@"NSButtonBordered"] || [coder decodeBoolForKey:@"NSButtonBordered"];
    _completes = [coder decodeBoolForKey:@"NSCompletes"];
    _usesData = [coder decodeBoolForKey:@"NSUsesDataSource"];
    _dataSource = [coder decodeObjectForKey:@"NSDataSource"];
    id table = [coder decodeObjectForKey:@"NSTableView"];
    _itemHeight = [coder containsValueForKey:@"NSComboItemHeight"] ? [coder decodeDoubleForKey:@"NSComboItemHeight"] :
        [table respondsToSelector:@selector(rowHeight)] ? [table rowHeight] : 18;
    _spacing = [table respondsToSelector:@selector(intercellSpacing)] ? [table intercellSpacing] : NSMakeSize(17, 0);
    if ([coder containsValueForKey:@"NSComboSpacing"]) _spacing = NSSizeFromString([coder decodeObjectForKey:@"NSComboSpacing"]);
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_items forKey:@"NSPopUpListData"];
    [coder encodeInteger:_selected forKey:@"NSComboSelectedIndex"];
    [coder encodeInteger:_visible forKey:@"NSVisibleItemCount"];
    [coder encodeBool:_scroller forKey:@"NSHasVerticalScroller"];
    [coder encodeBool:_buttonBordered forKey:@"NSButtonBordered"];
    [coder encodeBool:_completes forKey:@"NSCompletes"];
    [coder encodeBool:_usesData forKey:@"NSUsesDataSource"];
    [coder encodeConditionalObject:_dataSource forKey:@"NSDataSource"];
    [coder encodeDouble:_itemHeight forKey:@"NSComboItemHeight"];
    [coder encodeObject:NSStringFromSize(_spacing) forKey:@"NSComboSpacing"];
}
- (void)dealloc { [_items release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone
{
    NSComboBoxCell *c = [super copyWithZone:zone]; c->_items = [_items mutableCopy]; return c;
}
- (BOOL)hasVerticalScroller { return _scroller; }
- (void)setHasVerticalScroller:(BOOL)b { _scroller = b; }
- (NSSize)intercellSpacing { return _spacing; }
- (void)setIntercellSpacing:(NSSize)s { _spacing = s; }
- (CGFloat)itemHeight { return _itemHeight; }
- (void)setItemHeight:(CGFloat)h { _itemHeight = h; }
- (NSInteger)numberOfVisibleItems { return _visible; }
- (void)setNumberOfVisibleItems:(NSInteger)n { _visible = n; }
- (BOOL)isButtonBordered { return _buttonBordered; }
- (void)setButtonBordered:(BOOL)b { _buttonBordered = b; [self _finchChanged]; }
- (BOOL)usesDataSource { return _usesData; }
- (void)setUsesDataSource:(BOOL)b { _usesData = b; [self reloadData]; }
- (id)dataSource { return _dataSource; }
- (void)setDataSource:(id)d { _dataSource = d; [self reloadData]; [self noteNumberOfItemsChanged]; }
- (BOOL)completes { return _completes; }
- (void)setCompletes:(BOOL)b { _completes = b; }
- (NSInteger)numberOfItems { return _usesData ? _dataCount : (NSInteger)[_items count]; }
- (NSInteger)indexOfSelectedItem { return _selected; }
- (NSArray *)objectValues { return [[_items copy] autorelease]; }
- (id)itemObjectValueAtIndex:(NSInteger)i { return [_items objectAtIndex:i]; }
- (id)objectValueOfSelectedItem { return _selected < 0 ? nil : [_items objectAtIndex:_selected]; }
- (NSInteger)indexOfItemWithObjectValue:(id)o { return [_items indexOfObject:o]; }
- (void)reloadData
{
    if (!_usesData) return;
    NSView *view = [self controlView];
    if ([view isKindOfClass:[NSComboBox class]] && [_dataSource respondsToSelector:@selector(numberOfItemsInComboBox:)])
        _dataCount = [_dataSource numberOfItemsInComboBox:(NSComboBox *)view];
    else if ([_dataSource respondsToSelector:@selector(numberOfItemsInComboBoxCell:)])
        _dataCount = [_dataSource numberOfItemsInComboBoxCell:self];
    else _dataCount = 0;
    _dataCount = MAX(0, _dataCount);
    if (_selected >= _dataCount) _selected = -1;
    [self _finchChanged];
}
- (void)noteNumberOfItemsChanged { [self reloadData]; }
- (id)_finchListValueAtIndex:(NSInteger)i
{
    if (!_usesData) return [_items objectAtIndex:i];
    NSView *view = [self controlView];
    if ([view isKindOfClass:[NSComboBox class]] && [_dataSource respondsToSelector:@selector(comboBox:objectValueForItemAtIndex:)])
        return [_dataSource comboBox:(NSComboBox *)view objectValueForItemAtIndex:i];
    if ([_dataSource respondsToSelector:@selector(comboBoxCell:objectValueForItemAtIndex:)])
        return [_dataSource comboBoxCell:self objectValueForItemAtIndex:i];
    return nil;
}
- (void)_finchSelectionChanged
{
    id view = [self controlView];
    if ([view respondsToSelector:@selector(_finchComboSelectionChanged)]) [view _finchComboSelectionChanged];
    [self _finchChanged];
}
- (void)selectItemAtIndex:(NSInteger)i
{
    if (i < 0) return;
    if (i >= [self numberOfItems]) [NSException raise:NSRangeException format:@"Combo box item %ld is out of range", (long)i];
    if (i == _selected) return;
    _selected = i; [self setObjectValue:[self _finchListValueAtIndex:i]]; [self _finchSelectionChanged];
}
- (void)deselectItemAtIndex:(NSInteger)i
{
    if (i != _selected || i < 0) return;
    _selected = -1; [self setStringValue:@""]; [self _finchSelectionChanged];
}
- (void)selectItemWithObjectValue:(id)o
{
    NSInteger i = [_items indexOfObject:o]; if (i != NSNotFound) [self selectItemAtIndex:i];
}
- (void)addItemWithObjectValue:(id)o { if (!_usesData) { [_items addObject:o]; [self _finchChanged]; } }
- (void)addItemsWithObjectValues:(NSArray *)a { if (!_usesData) { [_items addObjectsFromArray:a]; [self _finchChanged]; } }
- (void)insertItemWithObjectValue:(id)o atIndex:(NSInteger)i
{
    if (_usesData) return;
    [_items insertObject:o atIndex:i]; if (_selected >= i) _selected++; [self _finchChanged];
}
- (void)removeItemAtIndex:(NSInteger)i
{
    if (_usesData) return;
    [_items removeObjectAtIndex:i];
    if (_selected == i) _selected = -1; else if (_selected > i) _selected--;
    [self _finchChanged];
}
- (void)removeItemWithObjectValue:(id)o
{
    if (_usesData) return;
    NSInteger i = [_items indexOfObject:o]; if (i != NSNotFound) [self removeItemAtIndex:i];
}
- (void)removeAllItems { if (!_usesData) { [_items removeAllObjects]; _selected = -1; [self _finchChanged]; } }
- (void)scrollItemAtIndexToTop:(NSInteger)i { if (i >= 0 && i < [self numberOfItems]) _topItem = i; }
- (void)scrollItemAtIndexToVisible:(NSInteger)i
{
    if (i < 0 || i >= [self numberOfItems]) return;
    if (i < _topItem) _topItem = i; else if (i >= _topItem + _visible) _topItem = MAX(0, i - _visible + 1);
}
- (NSString *)completedString:(NSString *)s
{
    if (_usesData) {
        NSView *view = [self controlView];
        if ([view isKindOfClass:[NSComboBox class]] && [_dataSource respondsToSelector:@selector(comboBox:completedString:)])
            return [_dataSource comboBox:(NSComboBox *)view completedString:s];
        if ([_dataSource respondsToSelector:@selector(comboBoxCell:completedString:)]) return [_dataSource comboBoxCell:self completedString:s];
    }
    if (![s length]) return nil;
    for (id item in _items) {
        NSString *value = [item isKindOfClass:[NSString class]] ? item : [item description];
        if ([value hasPrefix:s]) return value;
    }
    return nil;
}
- (NSRect)drawingRectForBounds:(NSRect)r
{
    CGFloat h = [self controlSize] == NSControlSizeMini ? 12 : [self controlSize] == NSControlSizeLarge ? 20 : 16;
    return NSMakeRect(r.origin.x, r.origin.y + floor((r.size.height - h) / 2), r.size.width, h);
}
- (NSRect)titleRectForBounds:(NSRect)r
{
    NSRect rect = [self drawingRectForBounds:r]; rect.origin.x += 4; rect.size.width = MAX(0, rect.size.width - 38); return rect;
}
- (NSSize)cellSizeForBounds:(NSRect)r
{
    NSSize s = [super cellSizeForBounds:r]; s.width += 30;
    s.height = [self controlSize] == NSControlSizeLarge ? 28 : [self controlSize] == NSControlSizeSmall ? 20 : [self controlSize] == NSControlSizeMini ? 16 : 24;
    return s;
}
- (void)drawWithFrame:(NSRect)r inView:(NSView *)view
{
    [super drawWithFrame:r inView:view];
    NSRect button = NSMakeRect(NSMaxX(r) - 24, r.origin.y, 24, r.size.height);
    if (_buttonBordered) FinchDrawBezel(button, 3, FinchControlFill(NO), FinchControlStroke());
    [FinchDisabled([NSColor labelColor], [self isEnabled]) setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath]; [p setLineWidth:1.4];
    CGFloat y = NSMidY(button);
    [p moveToPoint:NSMakePoint(NSMidX(button) - 4, y - 2)];
    [p lineToPoint:NSMakePoint(NSMidX(button), y + 2)];
    [p lineToPoint:NSMakePoint(NSMidX(button) + 4, y - 2)]; [p stroke];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityComboBoxRole; }
- (NSString *)accessibilitySubrole { return nil; }
- (id)accessibilityValue { return [self stringValue]; }
@end
