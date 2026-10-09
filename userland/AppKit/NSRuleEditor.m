/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A rule editor keeps a tree of rows and lets each delegate supply the
 * choices and values. The same rows build the resulting predicate. */
#import "AppKit_Finch.h"

NSRuleEditorPredicatePartKey const NSRuleEditorPredicateLeftExpression = @"NSRuleEditorPredicateLeftExpression";
NSRuleEditorPredicatePartKey const NSRuleEditorPredicateRightExpression = @"NSRuleEditorPredicateRightExpression";
NSRuleEditorPredicatePartKey const NSRuleEditorPredicateComparisonModifier = @"NSRuleEditorPredicateComparisonModifier";
NSRuleEditorPredicatePartKey const NSRuleEditorPredicateOptions = @"NSRuleEditorPredicateOptions";
NSRuleEditorPredicatePartKey const NSRuleEditorPredicateOperatorType = @"NSRuleEditorPredicateOperatorType";
NSRuleEditorPredicatePartKey const NSRuleEditorPredicateCustomSelector = @"NSRuleEditorPredicateCustomSelector";
NSRuleEditorPredicatePartKey const NSRuleEditorPredicateCompoundType = @"NSRuleEditorPredicateCompoundType";
NSNotificationName const NSRuleEditorRowsDidChangeNotification = @"NSRuleEditorRowsDidChangeNotification";

@interface _FinchRuleRow : NSObject {
  @public
    NSRuleEditorRowType type;
    _FinchRuleRow *parent;
    NSArray *criteria, *values;
}
@end
@implementation _FinchRuleRow
- (void)dealloc
{
    [criteria release];
    [values release];
    [super dealloc];
}
@end
/* Archived rows in IB include these holders. Live controls are rebuilt below. */
@interface _NSRuleEditorViewSliceHolder : NSView
@end
@implementation _NSRuleEditorViewSliceHolder
@end
@interface _NSRuleEditorViewUnboundRowHolder : NSObject <NSCoding>
@end
@implementation _NSRuleEditorViewUnboundRowHolder
- (instancetype)initWithCoder:(NSCoder *)c
{
    return [super init];
}
- (void)encodeWithCoder:(NSCoder *)c
{
}
@end

@implementation NSRuleEditor {
    NSMutableArray *_ruleRows;
    NSMutableIndexSet *_selectedRows;
    NSMutableArray *_rowViews;
    __weak id<NSRuleEditorDelegate> _ruleDelegate;
    NSRuleEditorNestingMode _nesting;
    CGFloat _rowHeight;
    BOOL _editable, _removeAll, _building;
    NSString *_formatFilename, *_rowTypePath, *_subrowsPath, *_criteriaPath, *_valuesPath;
    NSDictionary *_formatDictionary;
    Class _rowClass;
}
- (void)_finchRuleSetup
{
    _ruleRows = [NSMutableArray new];
    _selectedRows = [NSMutableIndexSet new];
    _rowViews = [NSMutableArray new];
    _nesting = NSRuleEditorNestingModeCompound;
    _rowHeight = 32;
    _editable = _removeAll = YES;
    _rowClass = [NSMutableDictionary class];
    _rowTypePath = [@"rowType" copy];
    _subrowsPath = [@"subrows" copy];
    _criteriaPath = [@"criteria" copy];
    _valuesPath = [@"displayValues" copy];
}
- (instancetype)initWithFrame:(NSRect)f
{
    self = [super initWithFrame:f];
    if (self)
        [self _finchRuleSetup];
    return self;
}
- (BOOL)isFlipped
{
    return YES;
}
- (id<NSRuleEditorDelegate>)delegate
{
    return _ruleDelegate;
}
- (void)setDelegate:(id<NSRuleEditorDelegate>)v
{
    _ruleDelegate = v;
    [self reloadCriteria];
}
- (NSRuleEditorNestingMode)nestingMode
{
    return _nesting;
}
- (void)setNestingMode:(NSRuleEditorNestingMode)v
{
    _nesting = v;
    [self _finchRebuildRows];
}
- (CGFloat)rowHeight
{
    return _rowHeight;
}
- (void)setRowHeight:(CGFloat)v
{
    _rowHeight = MAX(1, v);
    [self _finchRebuildRows];
}
- (BOOL)isEditable
{
    return _editable;
}
- (void)setEditable:(BOOL)v
{
    _editable = v;
    [self _finchRebuildRows];
}
- (BOOL)canRemoveAllRows
{
    return _removeAll;
}
- (void)setCanRemoveAllRows:(BOOL)v
{
    _removeAll = v;
    [self _finchRebuildRows];
}
- (NSInteger)numberOfRows
{
    return [_ruleRows count];
}
- (Class)rowClass
{
    return _rowClass;
}
- (void)setRowClass:(Class)v
{
    _rowClass = v;
}
#define RULE_PATH(get, set, slot)                                                                                      \
    -(NSString *)get                                                                                                   \
    {                                                                                                                  \
        return slot;                                                                                                   \
    }                                                                                                                  \
    -(void)set : (NSString *)v                                                                                         \
    {                                                                                                                  \
        if (slot != v) {                                                                                               \
            [slot release];                                                                                            \
            slot = [v copy];                                                                                           \
        }                                                                                                              \
    }
RULE_PATH(rowTypeKeyPath, setRowTypeKeyPath, _rowTypePath)
RULE_PATH(subrowsKeyPath, setSubrowsKeyPath, _subrowsPath)
RULE_PATH(criteriaKeyPath, setCriteriaKeyPath, _criteriaPath)
RULE_PATH(displayValuesKeyPath, setDisplayValuesKeyPath, _valuesPath)
- (NSString *)formattingStringsFilename
{
    return _formatFilename;
}
- (void)setFormattingStringsFilename:(NSString *)v
{
    [_formatFilename release];
    _formatFilename = [v copy];
    [_formatDictionary release];
    _formatDictionary =
        [[NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:v ofType:@"strings"]] copy];
    [self _finchRebuildRows];
}
- (NSDictionary *)formattingDictionary
{
    return _formatDictionary;
}
- (void)setFormattingDictionary:(NSDictionary *)v
{
    [_formatDictionary release];
    _formatDictionary = [v copy];
    [_formatFilename release];
    _formatFilename = nil;
    [self _finchRebuildRows];
}
- (_FinchRuleRow *)_finchRow:(NSInteger)i
{
    if (i < 0 || i >= (NSInteger)[_ruleRows count])
        [NSException raise:NSRangeException format:@"The rule row index is out of range."];
    return _ruleRows[i];
}
- (NSIndexSet *)subrowIndexesForRow:(NSInteger)i
{
    _FinchRuleRow *p = i == -1 ? nil : [self _finchRow:i];
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    for (NSUInteger j = 0; j < [_ruleRows count]; j++)
        if (((_FinchRuleRow *)_ruleRows[j])->parent == p)
            [out addIndex:j];
    return out;
}
- (NSRuleEditorRowType)rowTypeForRow:(NSInteger)i
{
    return [self _finchRow:i]->type;
}
- (NSInteger)parentRowForRow:(NSInteger)i
{
    _FinchRuleRow *p = [self _finchRow:i]->parent;
    return p ? (NSInteger)[_ruleRows indexOfObjectIdenticalTo:p] : -1;
}
- (NSArray *)criteriaForRow:(NSInteger)i
{
    return [self _finchRow:i]->criteria ?: @[];
}
- (NSArray *)displayValuesForRow:(NSInteger)i
{
    return [self _finchRow:i]->values ?: @[];
}
- (NSInteger)rowForDisplayValue:(id)value
{
    if (!value)
        [NSException raise:NSInvalidArgumentException format:@"A display value is required."];
    for (NSUInteger i = 0; i < [_ruleRows count]; i++) {
        if ([[self displayValuesForRow:i] indexOfObjectIdenticalTo:value] != NSNotFound)
            return i;
        if (![_ruleDelegate respondsToSelector:@selector(ruleEditor:numberOfChildrenForCriterion:withRowType:)])
            continue;
        id parent = nil;
        for (id criterion in [self criteriaForRow:i]) {
            NSInteger count = [_ruleDelegate ruleEditor:self
                           numberOfChildrenForCriterion:parent
                                            withRowType:[self rowTypeForRow:i]];
            for (NSInteger j = 0; j < count; j++) {
                id alternative = [_ruleDelegate ruleEditor:self
                                                     child:j
                                              forCriterion:parent
                                               withRowType:[self rowTypeForRow:i]];
                if ([_ruleDelegate ruleEditor:self displayValueForCriterion:alternative inRow:i] == value)
                    return i;
            }
            parent = criterion;
        }
    }
    return NSNotFound;
}
- (void)_finchRowsChanged
{
    [self _finchRebuildRows];
    [self reloadPredicate];
    NSNotification *n = [NSNotification notificationWithName:NSRuleEditorRowsDidChangeNotification object:self];
    if ([_ruleDelegate respondsToSelector:@selector(ruleEditorRowsDidChange:)])
        [_ruleDelegate ruleEditorRowsDidChange:n];
    [[NSNotificationCenter defaultCenter] postNotification:n];
}
- (void)insertRowAtIndex:(NSInteger)i
                withType:(NSRuleEditorRowType)type
           asSubrowOfRow:(NSInteger)p
                 animate:(BOOL)animate
{
    if (i < 0 || i > (NSInteger)[_ruleRows count] || p >= i || p < -1)
        [NSException raise:NSInvalidArgumentException
                    format:@"A new rule must follow its parent and fit inside the row list."];
    _FinchRuleRow *parent = p < 0 ? nil : [self _finchRow:p];
    if ((parent && parent->type != NSRuleEditorRowTypeCompound) ||
        (_nesting == NSRuleEditorNestingModeSingle && [_ruleRows count]) ||
        ((_nesting == NSRuleEditorNestingModeList || _nesting == NSRuleEditorNestingModeSingle) &&
         (parent || type == NSRuleEditorRowTypeCompound)) ||
        (_nesting == NSRuleEditorNestingModeSimple &&
         ((parent && parent->parent) || (parent && type == NSRuleEditorRowTypeCompound))))
        [NSException raise:NSInvalidArgumentException format:@"This rule editor does not allow that row arrangement."];
    if (i < (NSInteger)[_ruleRows count]) {
        _FinchRuleRow *next = _ruleRows[i];
        if (next->parent && next->parent != parent)
            [NSException raise:NSInvalidArgumentException format:@"The new row would split another parent's children."];
    }
    _FinchRuleRow *r = [[_FinchRuleRow alloc] init];
    r->type = type;
    r->parent = parent;
    [_ruleRows insertObject:r atIndex:i];
    [r release];
    [_selectedRows shiftIndexesStartingAtIndex:i by:1];
    [self setCriteria:@[] andDisplayValues:@[] forRowAtIndex:i];
}
- (void)setCriteria:(NSArray *)criteria andDisplayValues:(NSArray *)values forRowAtIndex:(NSInteger)i
{
    _FinchRuleRow *r = [self _finchRow:i];
    if (!criteria || !values)
        [NSException raise:NSInvalidArgumentException format:@"Criteria and display values must be arrays."];
    NSMutableArray *items = [NSMutableArray arrayWithArray:criteria], *display = [NSMutableArray arrayWithArray:values];
    if ([_ruleDelegate respondsToSelector:@selector(ruleEditor:numberOfChildrenForCriterion:withRowType:)] &&
        [_ruleDelegate respondsToSelector:@selector(ruleEditor:child:forCriterion:withRowType:)]) {
        id last = [items lastObject];
        for (NSUInteger count = 0; count < 256; count++) {
            NSInteger children = [_ruleDelegate ruleEditor:self numberOfChildrenForCriterion:last withRowType:r->type];
            if (children <= 0)
                break;
            id next = [_ruleDelegate ruleEditor:self child:0 forCriterion:last withRowType:r->type];
            if (!next || [items containsObject:next])
                break;
            [items addObject:next];
            last = next;
        }
    }
    while ([display count] > [items count])
        [display removeLastObject];
    for (NSUInteger n = [display count]; n < [items count]; n++) {
        id value = [_ruleDelegate respondsToSelector:@selector(ruleEditor:displayValueForCriterion:inRow:)]
                       ? [_ruleDelegate ruleEditor:self displayValueForCriterion:items[n] inRow:i]
                       : [items[n] description];
        [display addObject:value ?: @""];
    }
    [r->criteria release];
    r->criteria = [items copy];
    [r->values release];
    r->values = [display copy];
    [self _finchRowsChanged];
}
- (void)reloadCriteria
{
    for (NSInteger i = 0; i < (NSInteger)[_ruleRows count]; i++) {
        NSArray *old = [self criteriaForRow:i];
        NSMutableArray *valid = [NSMutableArray array];
        id parent = nil;
        for (id item in old) {
            BOOL found = NO;
            NSInteger n = [_ruleDelegate respondsToSelector:@selector(ruleEditor:
                                                                numberOfChildrenForCriterion:withRowType:)]
                              ? [_ruleDelegate ruleEditor:self
                                    numberOfChildrenForCriterion:parent
                                                     withRowType:[self rowTypeForRow:i]]
                              : 0;
            for (NSInteger j = 0; j < n; j++)
                if ([[_ruleDelegate ruleEditor:self child:j forCriterion:parent
                                   withRowType:[self rowTypeForRow:i]] isEqual:item]) {
                    found = YES;
                    break;
                }
            if (!found)
                break;
            [valid addObject:item];
            parent = item;
        }
        [self setCriteria:valid andDisplayValues:@[] forRowAtIndex:i];
    }
}
- (void)addRow:(id)sender
{
    if (_nesting == NSRuleEditorNestingModeSingle && [_ruleRows count])
        return;
    if (![_ruleRows count] && _nesting == NSRuleEditorNestingModeSimple)
        [self insertRowAtIndex:0 withType:NSRuleEditorRowTypeCompound asSubrowOfRow:-1 animate:NO];
    [self insertRowAtIndex:[_ruleRows count]
                  withType:NSRuleEditorRowTypeSimple
             asSubrowOfRow:_nesting == NSRuleEditorNestingModeSimple ? 0 : -1
                   animate:NO];
}
- (void)removeRowAtIndex:(NSInteger)i
{
    [self _finchRow:i];
    [self removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:i] includeSubrows:YES];
}
- (void)removeRowsAtIndexes:(NSIndexSet *)indexes includeSubrows:(BOOL)include
{
    if ([indexes count] && [indexes lastIndex] >= [_ruleRows count])
        [NSException raise:NSRangeException format:@"The removed rule index is out of range."];
    NSMutableSet *removed = [NSMutableSet set];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      [removed addObject:_ruleRows[i]];
    }];
    if (include)
        for (_FinchRuleRow *r in _ruleRows)
            if (r->parent && [removed containsObject:r->parent])
                [removed addObject:r];
    for (_FinchRuleRow *r in _ruleRows)
        while (r->parent && [removed containsObject:r->parent])
            r->parent = r->parent->parent;
    NSMutableIndexSet *selection = [NSMutableIndexSet indexSet];
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < [_ruleRows count]; i++)
        if (![removed containsObject:_ruleRows[i]]) {
            if ([_selectedRows containsIndex:i])
                [selection addIndex:n];
            n++;
        }
    for (NSInteger i = (NSInteger)[_ruleRows count] - 1; i >= 0; i--)
        if ([removed containsObject:_ruleRows[i]])
            [_ruleRows removeObjectAtIndex:i];
    [_selectedRows release];
    _selectedRows = [selection mutableCopy];
    [self _finchRowsChanged];
}
- (NSIndexSet *)selectedRowIndexes
{
    return [[_selectedRows copy] autorelease];
}
- (void)selectRowIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend
{
    if ([indexes count] && [indexes lastIndex] >= [_ruleRows count])
        [NSException raise:NSRangeException format:@"The selected rule index is out of range."];
    if (!extend)
        [_selectedRows removeAllIndexes];
    [_selectedRows addIndexes:indexes];
    [self setNeedsDisplay:YES];
}
- (NSPredicate *)predicateForRow:(NSInteger)i
{
    _FinchRuleRow *r = [self _finchRow:i];
    NSMutableDictionary *parts = [NSMutableDictionary dictionary];
    if (![_ruleDelegate respondsToSelector:@selector(ruleEditor:predicatePartsForCriterion:withDisplayValue:inRow:)])
        return nil;
    for (NSUInteger n = 0; n < [r->criteria count]; n++) {
        NSDictionary *d = [_ruleDelegate ruleEditor:self
                         predicatePartsForCriterion:r->criteria[n]
                                   withDisplayValue:r->values[n]
                                              inRow:i];
        if (d)
            [parts addEntriesFromDictionary:d];
    }
    if (parts[NSRuleEditorPredicateCompoundType]) {
        NSMutableArray *a = [NSMutableArray array];
        [[self subrowIndexesForRow:i] enumerateIndexesUsingBlock:^(NSUInteger j, BOOL *stop) {
          NSPredicate *p = [self predicateForRow:j];
          if (p)
              [a addObject:p];
        }];
        return [[[NSCompoundPredicate alloc] initWithType:[parts[NSRuleEditorPredicateCompoundType] integerValue]
                                            subpredicates:a] autorelease];
    }
    NSExpression *l = parts[NSRuleEditorPredicateLeftExpression], *right = parts[NSRuleEditorPredicateRightExpression];
    if (!l || !right)
        return nil;
    NSString *selector = parts[NSRuleEditorPredicateCustomSelector];
    if (selector)
        return [NSComparisonPredicate predicateWithLeftExpression:l
                                                  rightExpression:right
                                                   customSelector:NSSelectorFromString(selector)];
    if (!parts[NSRuleEditorPredicateOperatorType])
        return nil;
    return
        [NSComparisonPredicate predicateWithLeftExpression:l
                                           rightExpression:right
                                                  modifier:[parts[NSRuleEditorPredicateComparisonModifier] integerValue]
                                                      type:[parts[NSRuleEditorPredicateOperatorType] integerValue]
                                                   options:[parts[NSRuleEditorPredicateOptions] unsignedIntegerValue]];
}
- (NSPredicate *)predicate
{
    NSMutableArray *a = [NSMutableArray array];
    [[self subrowIndexesForRow:-1] enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      NSPredicate *p = [self predicateForRow:i];
      if (p)
          [a addObject:p];
    }];
    return [a count] == 1 ? a[0] : [a count] ? [NSCompoundPredicate orPredicateWithSubpredicates:a] : nil;
}
- (void)reloadPredicate
{
    [self willChangeValueForKey:@"predicate"];
    [self didChangeValueForKey:@"predicate"];
}
- (void)_finchValueChanged:(id)sender
{
    [self reloadPredicate];
    [self sendAction:[self action] to:[self target]];
}
- (void)_finchRemoveClicked:(id)sender
{
    if (_removeAll || [_ruleRows count] > 1)
        [self removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:[sender tag]] includeSubrows:YES];
    [self sendAction:[self action] to:[self target]];
}
- (void)_finchAddClicked:(id)sender
{
    NSInteger row = [sender tag],
              parent = [self rowTypeForRow:row] == NSRuleEditorRowTypeCompound ? row : [self parentRowForRow:row],
              at = row + 1;
    while (at < (NSInteger)[_ruleRows count] && [self parentRowForRow:at] >= row)
        at++;
    [self insertRowAtIndex:at withType:NSRuleEditorRowTypeSimple asSubrowOfRow:parent animate:NO];
    [self sendAction:[self action] to:[self target]];
}
- (void)_finchChoiceChanged:(NSPopUpButton *)sender
{
    NSArray *ref = objc_getAssociatedObject(sender, @selector(_finchChoiceChanged:));
    NSInteger row = [ref[0] integerValue], column = [ref[1] integerValue];
    NSArray *old = [self criteriaForRow:row];
    NSMutableArray *items = [NSMutableArray arrayWithArray:[old subarrayWithRange:NSMakeRange(0, column)]];
    id choice = [[sender selectedItem] representedObject];
    if (choice)
        [items addObject:choice];
    [self setCriteria:items andDisplayValues:@[] forRowAtIndex:row];
    [self sendAction:[self action] to:[self target]];
}
- (void)_finchRebuildRows
{
    if (_building || !_rowViews)
        return;
    _building = YES;
    for (NSView *v in _rowViews)
        [v removeFromSuperview];
    [_rowViews removeAllObjects];
    NSSize size = [self frame].size;
    size.height = [_ruleRows count] * _rowHeight;
    [self setFrameSize:size];
    for (NSInteger i = 0; i < (NSInteger)[_ruleRows count]; i++) {
        _FinchRuleRow *r = _ruleRows[i];
        NSInteger depth = 0;
        for (_FinchRuleRow *p = r->parent; p; p = p->parent)
            depth++;
        CGFloat x = 8 + depth * 16, y = i * _rowHeight + (_rowHeight - 24) / 2;
        for (NSUInteger n = 0; n < [r->values count]; n++) {
            id value = r->values[n];
            NSView *v = nil;
            if ([value isKindOfClass:[NSView class]])
                v = value;
            else {
                id parent = n ? r->criteria[n - 1] : nil;
                NSInteger count =
                    [_ruleDelegate respondsToSelector:@selector(ruleEditor:numberOfChildrenForCriterion:withRowType:)]
                        ? [_ruleDelegate ruleEditor:self numberOfChildrenForCriterion:parent withRowType:r->type]
                        : 0;
                if (count > 1) {
                    NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 24)
                                                                       pullsDown:NO] autorelease];
                    for (NSInteger j = 0; j < count; j++) {
                        id item = [_ruleDelegate ruleEditor:self child:j forCriterion:parent withRowType:r->type];
                        id display = [item isEqual:r->criteria[n]]
                                         ? value
                                         : [_ruleDelegate ruleEditor:self displayValueForCriterion:item inRow:i];
                        NSString *title =
                            [display isKindOfClass:[NSMenuItem class]] ? [display title] : [display description];
                        [popup addItemWithTitle:title ?: @""];
                        [[popup lastItem] setRepresentedObject:item];
                        if ([item isEqual:r->criteria[n]])
                            [popup selectItemAtIndex:j];
                    }
                    [popup setTarget:self];
                    [popup setAction:@selector(_finchChoiceChanged:)];
                    objc_setAssociatedObject(popup, @selector(_finchChoiceChanged:), @[ @(i), @(n) ],
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    v = popup;
                } else
                    v = [NSTextField
                        labelWithString:[value isKindOfClass:[NSMenuItem class]] ? [value title] : [value description]];
            }
            NSSize s = [v fittingSize];
            if (s.width <= 0)
                s = [v frame].size;
            if ([v isKindOfClass:[NSPopUpButton class]]) {
                NSPopUpButton *popup = (NSPopUpButton *)v;
                for (NSMenuItem *item in [popup itemArray]) {
                    NSSize title = [[item title] sizeWithAttributes:@{NSFontAttributeName : [popup font]}];
                    s.width = MAX(s.width, title.width + 32);
                }
            }
            CGFloat minimum = [v isKindOfClass:[NSTextField class]] && [(NSTextField *)v isEditable] ? 120 : 40;
            s.width = MAX(minimum, MIN(240, s.width));
            s.height = 24;
            [v setFrame:NSMakeRect(x, y, s.width, s.height)];
            x += s.width + 6;
            if ([v isKindOfClass:[NSControl class]]) {
                [(NSControl *)v setEnabled:_editable];
                if (![(NSControl *)v target]) {
                    [(NSControl *)v setTarget:self];
                    [(NSControl *)v setAction:@selector(_finchValueChanged:)];
                }
            }
            [self addSubview:v];
            [_rowViews addObject:v];
        }
        if (_nesting != NSRuleEditorNestingModeSingle)
            for (int add = 0; add < 2; add++) {
                NSButton *b =
                    [NSButton buttonWithTitle:add ? @"+" : @"−"
                                       target:self
                                       action:add ? @selector(_finchAddClicked:) : @selector(_finchRemoveClicked:)];
                [b setTag:i];
                [b setFrame:NSMakeRect(MAX(x, size.width - 60) + add * 28, y, 25, 24)];
                [b setEnabled:_editable && (add || _removeAll || [_ruleRows count] > 1)];
                [self addSubview:b];
                [_rowViews addObject:b];
            }
    }
    [self setNeedsDisplay:YES];
    _building = NO;
}
- (void)drawRect:(NSRect)dirty
{
    for (NSUInteger i = 0; i < [_ruleRows count]; i++) {
        [[_selectedRows containsIndex:i]
                ? [NSColor selectedControlColor]
                : (i % 2 ? [NSColor controlBackgroundColor] : [NSColor windowBackgroundColor]) setFill];
        NSRectFill(NSMakeRect(0, i * _rowHeight, [self bounds].size.width, _rowHeight));
    }
}
- (void)mouseDown:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    NSInteger i = floor(p.y / _rowHeight);
    if (i >= 0 && i < (NSInteger)[_ruleRows count])
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:i]
            byExtendingSelection:([e modifierFlags] & NSEventModifierFlagCommand) != 0];
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [super initWithCoder:c];
    if (self) {
        [self _finchRuleSetup];
        if ([c containsValueForKey:@"NSRuleEditorSliceHeight"])
            _rowHeight = [c decodeDoubleForKey:@"NSRuleEditorSliceHeight"];
        if ([c containsValueForKey:@"NSRuleEditorNestingMode"])
            _nesting = [c decodeIntegerForKey:@"NSRuleEditorNestingMode"];
        if ([c containsValueForKey:@"NSRuleEditorEditable"])
            _editable = [c decodeBoolForKey:@"NSRuleEditorEditable"];
        _removeAll = ![c decodeBoolForKey:@"NSRuleEditorDisallowEmpty"];
        _formatDictionary = [[c decodeObjectForKey:@"NSRuleEditorFormattingDictionary"] copy];
        _ruleDelegate = [c decodeObjectForKey:@"NSRuleEditorDelegate"];
        NSArray *keys = @[
            @"NSRuleEditorRowTypeKeyPath", @"NSRuleEditorSubrowsArrayKeyPath", @"NSRuleEditorItemsKeyPath",
            @"NSRuleEditorValuesKeyPath"
        ];
        SEL setters[] = {@selector(setRowTypeKeyPath:), @selector(setSubrowsKeyPath:), @selector(setCriteriaKeyPath:),
                         @selector(setDisplayValuesKeyPath:)};
        for (int i = 0; i < 4; i++) {
            id v = [c decodeObjectForKey:keys[i]];
            if (v)
                ((void (*)(id, SEL, id))objc_msgSend)(self, setters[i], v);
        }
        for (NSView *v in [[[self subviews] copy] autorelease])
            if ([v isKindOfClass:[_NSRuleEditorViewSliceHolder class]])
                [v removeFromSuperview];
        NSArray *saved = [c decodeObjectForKey:@"FinchRuleRows"];
        for (NSDictionary *d in saved) {
            _FinchRuleRow *r = [[_FinchRuleRow alloc] init];
            r->type = [d[@"type"] integerValue];
            NSInteger parent = [d[@"parent"] integerValue];
            if (parent >= 0 && parent < (NSInteger)[_ruleRows count])
                r->parent = _ruleRows[parent];
            r->criteria = [d[@"criteria"] copy];
            r->values = [d[@"values"] copy];
            [_ruleRows addObject:r];
            [r release];
        }
        if ([saved count])
            [self _finchRebuildRows];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [super encodeWithCoder:c];
    [c encodeDouble:_rowHeight forKey:@"NSRuleEditorSliceHeight"];
    [c encodeInteger:_nesting forKey:@"NSRuleEditorNestingMode"];
    [c encodeBool:_editable forKey:@"NSRuleEditorEditable"];
    [c encodeBool:!_removeAll forKey:@"NSRuleEditorDisallowEmpty"];
    [c encodeObject:_formatDictionary forKey:@"NSRuleEditorFormattingDictionary"];
    [c encodeObject:_rowTypePath forKey:@"NSRuleEditorRowTypeKeyPath"];
    [c encodeObject:_subrowsPath forKey:@"NSRuleEditorSubrowsArrayKeyPath"];
    [c encodeObject:_criteriaPath forKey:@"NSRuleEditorItemsKeyPath"];
    [c encodeObject:_valuesPath forKey:@"NSRuleEditorValuesKeyPath"];
    NSMutableArray *a = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)[_ruleRows count]; i++)
        [a addObject:@{
            @"type" : @([self rowTypeForRow:i]),
            @"parent" : @([self parentRowForRow:i]),
            @"criteria" : [self criteriaForRow:i],
            @"values" : [self displayValuesForRow:i]
        }];
    [c encodeObject:a forKey:@"FinchRuleRows"];
}
- (void)dealloc
{
    [_ruleRows release];
    [_selectedRows release];
    [_rowViews release];
    [_formatFilename release];
    [_formatDictionary release];
    [_rowTypePath release];
    [_subrowsPath release];
    [_criteriaPath release];
    [_valuesPath release];
    [super dealloc];
}
@end
