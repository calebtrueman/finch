/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSOutlineView: a table of a tree's visible items, a row per item, the
 * outline column indented by level with a disclosure triangle for items
 * that expand.
 *
 * The rows are the root's children and, under each expanded item, its
 * children; the data source's children are asked for when an item is
 * expanded (or reloaded) and kept until it is reloaded. As measured on
 * macOS 26.4 (appkit-tables-test.m):
 *   - Indentation is 13 per level; the outline column is the first column
 *     unless one is set, and it grows (and shrinks) by a level's indentation
 *     as the deepest visible level changes (autoresizesOutlineColumn).
 *   - In the outline column the disclosure triangle is 13 wide, 2 in from
 *     the column (and indented with the cell, indentationMarkerFollowsCell),
 *     and the cell starts after it, indented by its level, ending where the
 *     column's cell ends.
 *   - Expanding asks -outlineView:shouldExpandItem:, then posts the will and
 *     did notifications, then expands children (with expandChildren:, or the
 *     children that were expanded when the item was last collapsed);
 *     collapsing asks, posts the will notification, collapses expanded
 *     children (remembering them unless collapseChildren:), then posts the
 *     did notification. Expanding nil expands the root's expandable items;
 *     collapsing nil collapses them all, last first.
 *   - Selected items keep their selection as rows come and go; selected
 *     items that are hidden by a collapse are deselected, with a
 *     notification.
 *
 * Nib keys: NSOutlineViewIndentationPerLevelKey,
 * NSOutlineViewAutoresizesOutlineColumnKey, NSOutineViewStronglyReferencesItems,
 * NSOutlineViewOutlineTableColumnKey.
 */
#import "NSTableView_Finch.h"
#import "NSKeyValueBinding_Finch.h"

NSNotificationName NSOutlineViewSelectionDidChangeNotification = @"NSOutlineViewSelectionDidChangeNotification";
NSNotificationName NSOutlineViewColumnDidMoveNotification = @"NSOutlineViewColumnDidMoveNotification";
NSNotificationName NSOutlineViewColumnDidResizeNotification = @"NSOutlineViewColumnDidResizeNotification";
NSNotificationName NSOutlineViewSelectionIsChangingNotification = @"NSOutlineViewSelectionIsChangingNotification";
NSNotificationName NSOutlineViewItemWillExpandNotification = @"NSOutlineViewItemWillExpandNotification";
NSNotificationName NSOutlineViewItemDidExpandNotification = @"NSOutlineViewItemDidExpandNotification";
NSNotificationName NSOutlineViewItemWillCollapseNotification = @"NSOutlineViewItemWillCollapseNotification";
NSNotificationName NSOutlineViewItemDidCollapseNotification = @"NSOutlineViewItemDidCollapseNotification";
NSUserInterfaceItemIdentifier const NSOutlineViewDisclosureButtonKey = @"NSOutlineViewDisclosureButtonKey";
NSUserInterfaceItemIdentifier const NSOutlineViewShowHideButtonKey = @"NSOutlineViewShowHideButtonKey";

static const CGFloat disclosure_width = 13;

@interface NSTableView (FinchOutlineAccess)
- (void)_finchSetSelectedRows:(NSIndexSet *)rows anchor:(NSInteger)anchor notify:(BOOL)notify;
- (void)_finchRecount;
- (void)_finchInvalidateRowGeometry;
- (void)_finchRemoveAllRowViews;
- (void)_finchQuietlySelect:(NSIndexSet *)rows anchor:(NSInteger)anchor;
- (BOOL)_finchProvidesObjectValues;
- (BOOL)_finchEmphasized;
- (id)_finchObjectValueForColumn:(NSTableColumn *)column row:(NSInteger)row;
- (void)_finchSetObjectValue:(id)value forColumn:(NSTableColumn *)column row:(NSInteger)row;
- (NSView *)_finchDelegateViewForColumn:(NSTableColumn *)column row:(NSInteger)row;
- (void)_finchLayoutRowViews;
- (BOOL)_finchIsViewBased;
- (NSArray *)_finchDelegateNotifications;
- (NSInteger)_finchUpdateDepth;
@end

@implementation NSOutlineView {
    NSTableColumn *_outlineColumn; /* not retained (one of the columns) */
    CGFloat _indentation;
    NSMapTable *_children;    /* item (NSNull for the root) -> NSArray of children */
    NSHashTable *_expanded;   /* expanded items */
    NSHashTable *_remembered; /* expanded children of collapsed items, to expand again */
    NSMutableArray *_items;   /* the visible items, a row each */
    NSMutableArray *_parents; /* each row's parent (NSNull at the root) */
    NSMutableData *_levels;   /* each row's level (NSInteger) */
    NSInteger _maxLevel;
    BOOL _autoresizesOutline, _followsCell, _strongRefs, _built, _autosaveExpanded;
}

static void
outline_init(NSOutlineView *self)
{
    self->_indentation = 13;
    self->_followsCell = YES;
    self->_autoresizesOutline = YES;
    self->_strongRefs = YES;
    NSPointerFunctionsOptions identity = NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality;
    self->_children = [[NSMapTable alloc] initWithKeyOptions:identity valueOptions:NSPointerFunctionsStrongMemory
                                                    capacity:0];
    self->_expanded = [[NSHashTable alloc] initWithOptions:identity capacity:0];
    self->_remembered = [[NSHashTable alloc] initWithOptions:identity capacity:0];
    self->_items = [[NSMutableArray alloc] init];
    self->_parents = [[NSMutableArray alloc] init];
    self->_levels = [[NSMutableData alloc] init];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        outline_init(self);
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    outline_init(self);
    if ([coder containsValueForKey:@"NSOutlineViewIndentationPerLevelKey"])
        _indentation = [coder decodeDoubleForKey:@"NSOutlineViewIndentationPerLevelKey"];
    if ([coder containsValueForKey:@"NSOutlineViewAutoresizesOutlineColumnKey"])
        _autoresizesOutline = [coder decodeBoolForKey:@"NSOutlineViewAutoresizesOutlineColumnKey"];
    if ([coder containsValueForKey:@"NSOutineViewStronglyReferencesItems"])
        _strongRefs = [coder decodeBoolForKey:@"NSOutineViewStronglyReferencesItems"];
    _outlineColumn = [coder decodeObjectForKey:@"NSOutlineViewOutlineTableColumnKey"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeDouble:_indentation forKey:@"NSOutlineViewIndentationPerLevelKey"];
    [coder encodeBool:_autoresizesOutline forKey:@"NSOutlineViewAutoresizesOutlineColumnKey"];
    [coder encodeBool:_strongRefs forKey:@"NSOutineViewStronglyReferencesItems"];
    if (_outlineColumn)
        [coder encodeConditionalObject:_outlineColumn forKey:@"NSOutlineViewOutlineTableColumnKey"];
}

- (void)dealloc
{
    [_children release];
    [_expanded release];
    [_remembered release];
    [_items release];
    [_parents release];
    [_levels release];
    [super dealloc];
}

#pragma mark - Properties

- (id<NSOutlineViewDataSource>)dataSource { return (id)[super dataSource]; }
- (void)setDataSource:(id<NSOutlineViewDataSource>)ds { _built = NO; [super setDataSource:(id)ds]; }
- (id<NSOutlineViewDelegate>)delegate { return (id)[super delegate]; }
- (void)setDelegate:(id<NSOutlineViewDelegate>)d { [super setDelegate:(id)d]; }

- (NSTableColumn *)outlineTableColumn
{
    if (_outlineColumn && [[self tableColumns] indexOfObjectIdenticalTo:_outlineColumn] != NSNotFound)
        return _outlineColumn;
    return [[self tableColumns] firstObject];
}

- (void)setOutlineTableColumn:(NSTableColumn *)column
{
    _outlineColumn = column;
    [self setNeedsDisplay:YES];
    [self _finchLayoutRowViews];
}

- (CGFloat)indentationPerLevel { return _indentation; }

- (void)setIndentationPerLevel:(CGFloat)indentation
{
    _indentation = indentation;
    [self setNeedsDisplay:YES];
    [self _finchLayoutRowViews];
}

- (BOOL)indentationMarkerFollowsCell { return _followsCell; }
- (void)setIndentationMarkerFollowsCell:(BOOL)flag { _followsCell = flag; [self setNeedsDisplay:YES]; }
- (BOOL)autoresizesOutlineColumn { return _autoresizesOutline; }
- (void)setAutoresizesOutlineColumn:(BOOL)flag { _autoresizesOutline = flag; }
- (BOOL)autosaveExpandedItems { return _autosaveExpanded; }
- (void)setAutosaveExpandedItems:(BOOL)flag { _autosaveExpanded = flag; }
- (BOOL)stronglyReferencesItems { return _strongRefs; }
- (void)setStronglyReferencesItems:(BOOL)flag { _strongRefs = flag; }
- (NSTableViewStyle)style { return [super style]; }

#pragma mark - The table's hooks

- (NSArray *)_finchDelegateNotifications
{
    return @[
        @[ NSOutlineViewSelectionDidChangeNotification, @"outlineViewSelectionDidChange:" ],
        @[ NSOutlineViewSelectionIsChangingNotification, @"outlineViewSelectionIsChanging:" ],
        @[ NSOutlineViewColumnDidMoveNotification, @"outlineViewColumnDidMove:" ],
        @[ NSOutlineViewColumnDidResizeNotification, @"outlineViewColumnDidResize:" ],
        @[ NSOutlineViewItemWillExpandNotification, @"outlineViewItemWillExpand:" ],
        @[ NSOutlineViewItemDidExpandNotification, @"outlineViewItemDidExpand:" ],
        @[ NSOutlineViewItemWillCollapseNotification, @"outlineViewItemWillCollapse:" ],
        @[ NSOutlineViewItemDidCollapseNotification, @"outlineViewItemDidCollapse:" ],
    ];
}

- (NSString *)_finchSelectionDidChangeName { return NSOutlineViewSelectionDidChangeNotification; }
- (NSString *)_finchSelectionIsChangingName { return NSOutlineViewSelectionIsChangingNotification; }
- (NSString *)_finchColumnDidMoveName { return NSOutlineViewColumnDidMoveNotification; }
- (NSString *)_finchColumnDidResizeName { return NSOutlineViewColumnDidResizeNotification; }

static id
key_for(id item)
{
    return item ?: [NSNull null];
}

static id
item_of(id key)
{
    return key == [NSNull null] ? nil : key;
}

/* The children of an item, from the cache or the data source. */
- (NSArray *)_finchChildrenOf:(id)item
{
    NSArray *c = [_children objectForKey:key_for(item)];
    if (c)
        return c;
    id ds = [self dataSource];
    NSMutableArray *a = [NSMutableArray array];
    NSInteger n = [ds respondsToSelector:@selector(outlineView:numberOfChildrenOfItem:)]
                      ? [ds outlineView:self numberOfChildrenOfItem:item]
                      : 0;
    for (NSInteger i = 0; i < n; i++) {
        id child = [ds outlineView:self child:i ofItem:item];
        [a addObject:child ?: [NSNull null]];
    }
    [_children setObject:a forKey:key_for(item)];
    return a;
}

static void
add_rows(NSOutlineView *self, id parent, NSInteger level)
{
    for (id child in [self _finchChildrenOf:parent]) {
        [self->_items addObject:child];
        [self->_parents addObject:key_for(parent)];
        [self->_levels appendBytes:&level length:sizeof level];
        if ([self->_expanded containsObject:child])
            add_rows(self, child, level + 1);
    }
}

/* Rebuild the rows from the expanded items. */
- (void)_finchBuildRows
{
    [_items removeAllObjects];
    [_parents removeAllObjects];
    [_levels setLength:0];
    _built = YES;
    if (![self dataSource])
        return;
    add_rows(self, nil, 0);
}

- (NSInteger)_finchCountRows
{
    if (!_built)
        [self _finchBuildRows];
    return (NSInteger)[_items count];
}

static NSInteger
row_level(NSOutlineView *self, NSInteger row)
{
    if (row < 0 || (NSUInteger)row >= [self->_items count])
        return -1;
    return ((const NSInteger *)[self->_levels bytes])[row];
}

- (id)_finchObjectValueForColumn:(NSTableColumn *)column row:(NSInteger)row
{
    id ds = [self dataSource];
    if ([ds respondsToSelector:@selector(outlineView:objectValueForTableColumn:byItem:)])
        return [ds outlineView:self objectValueForTableColumn:column byItem:[self itemAtRow:row]];
    return [super _finchObjectValueForColumn:column row:row];
}

- (BOOL)_finchProvidesObjectValues
{
    return [[self dataSource] respondsToSelector:@selector(outlineView:objectValueForTableColumn:byItem:)] ||
           [super _finchProvidesObjectValues];
}

- (void)_finchSetObjectValue:(id)value forColumn:(NSTableColumn *)column row:(NSInteger)row
{
    id ds = [self dataSource];
    if ([ds respondsToSelector:@selector(outlineView:setObjectValue:forTableColumn:byItem:)])
        [ds outlineView:self setObjectValue:value forTableColumn:column byItem:[self itemAtRow:row]];
    else
        [super _finchSetObjectValue:value forColumn:column row:row];
}

- (BOOL)_finchIsGroupRow:(NSInteger)row
{
    id d = [self delegate];
    return [d respondsToSelector:@selector(outlineView:isGroupItem:)] && [d outlineView:self isGroupItem:[self itemAtRow:row]];
}

- (BOOL)_finchHasGroupItems
{
    return [[self delegate] respondsToSelector:@selector(outlineView:isGroupItem:)];
}

- (BOOL)_finchDelegateHasRowHeights
{
    return [[self delegate] respondsToSelector:@selector(outlineView:heightOfRowByItem:)];
}

- (CGFloat)_finchDelegateHeightOfRow:(NSInteger)row
{
    return [[self delegate] outlineView:self heightOfRowByItem:[self itemAtRow:row]];
}

- (BOOL)_finchDelegateMakesViews
{
    return [[self delegate] respondsToSelector:@selector(outlineView:viewForTableColumn:item:)];
}

- (NSView *)_finchDelegateViewForColumn:(NSTableColumn *)column row:(NSInteger)row
{
    if ([self _finchDelegateMakesViews])
        return [[self delegate] outlineView:self viewForTableColumn:column item:[self itemAtRow:row]];
    return [super _finchDelegateViewForColumn:column row:row];
}

- (NSTableRowView *)_finchDelegateRowViewForRow:(NSInteger)row
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:rowViewForItem:)])
        return [d outlineView:self rowViewForItem:[self itemAtRow:row]];
    return nil;
}

- (void)_finchDidAddRowView:(NSTableRowView *)rowView row:(NSInteger)row
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:didAddRowView:forRow:)])
        [d outlineView:self didAddRowView:rowView forRow:row];
}

- (void)_finchDidRemoveRowView:(NSTableRowView *)rowView row:(NSInteger)row
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:didRemoveRowView:forRow:)])
        [d outlineView:self didRemoveRowView:rowView forRow:row];
}

- (void)_finchWillDisplayCell:(NSCell *)cell column:(NSTableColumn *)column row:(NSInteger)row
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:willDisplayCell:forTableColumn:item:)])
        [d outlineView:self willDisplayCell:cell forTableColumn:column item:[self itemAtRow:row]];
}

- (BOOL)_finchShouldSelectRow:(NSInteger)row
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:shouldSelectItem:)])
        return [d outlineView:self shouldSelectItem:[self itemAtRow:row]];
    return YES;
}

- (NSIndexSet *)_finchProposedSelection:(NSIndexSet *)proposed
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:selectionIndexesForProposedSelection:)])
        return [d outlineView:self selectionIndexesForProposedSelection:proposed];
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    [proposed enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        if ([self isRowSelected:i] || [self _finchShouldSelectRow:i])
            [out addIndex:i];
    }];
    return out;
}

- (BOOL)_finchSelectionShouldChange
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(selectionShouldChangeInOutlineView:)])
        return [d selectionShouldChangeInOutlineView:self];
    return YES;
}

- (BOOL)_finchShouldEditColumn:(NSTableColumn *)column row:(NSInteger)row
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:shouldEditTableColumn:item:)])
        return [d outlineView:self shouldEditTableColumn:column item:[self itemAtRow:row]];
    return YES;
}

- (void)_finchSortDescriptorsChanged:(NSArray *)old
{
    id ds = [self dataSource];
    if ([ds respondsToSelector:@selector(outlineView:sortDescriptorsDidChange:)])
        [ds outlineView:self sortDescriptorsDidChange:old];
}

- (void)_finchDidClickColumn:(NSTableColumn *)column
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:didClickTableColumn:)])
        [d outlineView:self didClickTableColumn:column];
}

#pragma mark - Items and rows

- (id)itemAtRow:(NSInteger)row
{
    if (!_built)
        [self _finchBuildRows];
    if (row < 0 || (NSUInteger)row >= [_items count])
        return nil;
    return item_of([_items objectAtIndex:row]);
}

- (NSInteger)rowForItem:(id)item
{
    if (!_built)
        [self _finchBuildRows];
    if (!item)
        return -1;
    NSUInteger i = [_items indexOfObjectIdenticalTo:item];
    return i == NSNotFound ? -1 : (NSInteger)i;
}

- (NSInteger)levelForRow:(NSInteger)row
{
    if (!_built)
        [self _finchBuildRows];
    return row_level(self, row);
}

- (NSInteger)levelForItem:(id)item
{
    return [self levelForRow:[self rowForItem:item]];
}

- (id)parentForItem:(id)item
{
    NSInteger r = [self rowForItem:item];
    if (r < 0)
        return nil;
    return item_of([_parents objectAtIndex:r]);
}

- (NSInteger)childIndexForItem:(id)item
{
    NSInteger r = [self rowForItem:item];
    if (r < 0)
        return -1;
    NSArray *siblings = [_children objectForKey:[_parents objectAtIndex:r]];
    NSUInteger i = [siblings indexOfObjectIdenticalTo:item];
    return i == NSNotFound ? -1 : (NSInteger)i;
}

- (NSInteger)numberOfChildrenOfItem:(id)item
{
    return (NSInteger)[[self _finchChildrenOf:item] count];
}

- (id)child:(NSInteger)index ofItem:(id)item
{
    NSArray *c = [self _finchChildrenOf:item];
    if (index < 0 || (NSUInteger)index >= [c count])
        return nil;
    return item_of([c objectAtIndex:index]);
}

- (BOOL)isExpandable:(id)item
{
    if (!item)
        return YES;
    id ds = [self dataSource];
    return [ds respondsToSelector:@selector(outlineView:isItemExpandable:)] && [ds outlineView:self isItemExpandable:item];
}

- (BOOL)isItemExpanded:(id)item
{
    if (!item)
        return YES;
    return [_expanded containsObject:item];
}

#pragma mark - Expanding and collapsing

- (void)_finchPost:(NSString *)name item:(id)item
{
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:self
                                                      userInfo:@{@"NSObject" : item ?: [NSNull null]}];
}

/* Rows changed shape: rebuild, keep the selected items selected, notify if some went away. */
- (void)_finchRowsReshaped:(void (^)(void))change
{
    NSIndexSet *sel = [self selectedRowIndexes];
    NSMutableArray *selItems = [NSMutableArray array];
    [sel enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
        if (r < [_items count])
            [selItems addObject:[_items objectAtIndex:r]];
    }];
    id anchorItem = [self selectedRow] >= 0 ? [self itemAtRow:[self selectedRow]] : nil;
    change();
    [self _finchBuildRows];
    [self _finchRecountKeepingSelection];
    NSMutableIndexSet *now = [NSMutableIndexSet indexSet];
    for (id it in selItems) {
        NSUInteger r = [_items indexOfObjectIdenticalTo:it];
        if (r != NSNotFound)
            [now addIndex:r];
    }
    NSInteger anchor = anchorItem ? [self rowForItem:anchorItem] : -1;
    [self _finchQuietlySelect:now anchor:anchor];
    if ([now count] != [selItems count])
        [[NSNotificationCenter defaultCenter] postNotificationName:[self _finchSelectionDidChangeName] object:self];
}

- (void)_finchRecountKeepingSelection
{
    [self _finchRemoveAllRowViews];
    [self _finchInvalidateRowGeometry];
    [self _finchQuietlySelect:[NSIndexSet indexSet] anchor:-1];
    [self _finchRecount];
    [self tile];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (NSInteger)_finchMaxVisibleLevel
{
    NSInteger m = 0, n = (NSInteger)[_items count];
    const NSInteger *lv = [_levels bytes];
    for (NSInteger i = 0; i < n; i++)
        m = MAX(m, lv[i]);
    return m;
}

- (void)_finchAdjustOutlineColumn:(NSInteger)oldMax
{
    if (!_autoresizesOutline)
        return;
    NSInteger m = [self _finchMaxVisibleLevel];
    if (m == oldMax)
        return;
    NSTableColumn *c = [self outlineTableColumn];
    [c setWidth:[c width] + (m - oldMax) * _indentation];
}

- (void)_finchExpand:(id)item children:(BOOL)children
{
    if (![self isExpandable:item])
        return;
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:shouldExpandItem:)] && ![d outlineView:self shouldExpandItem:item])
        return;
    if (![_expanded containsObject:item]) {
        [self _finchPost:NSOutlineViewItemWillExpandNotification item:item];
        [_expanded addObject:item];
        [self _finchPost:NSOutlineViewItemDidExpandNotification item:item];
    }
    for (id child in [self _finchChildrenOf:item]) {
        if (children || [_remembered containsObject:child]) {
            [_remembered removeObject:child];
            [self _finchExpand:child children:children];
        }
    }
}

- (void)_finchCollapse:(id)item children:(BOOL)children
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(outlineView:shouldCollapseItem:)] && ![d outlineView:self shouldCollapseItem:item])
        return;
    if (![_expanded containsObject:item])
        return;
    [self _finchPost:NSOutlineViewItemWillCollapseNotification item:item];
    for (id child in [_children objectForKey:item]) {
        if ([_expanded containsObject:child]) {
            [self _finchCollapse:child children:children];
            if (!children)
                [_remembered addObject:child];
        }
        if (children)
            [_remembered removeObject:child];
    }
    [_expanded removeObject:item];
    [self _finchPost:NSOutlineViewItemDidCollapseNotification item:item];
}

- (void)expandItem:(id)item expandChildren:(BOOL)children
{
    if (!_built)
        [self _finchBuildRows];
    NSInteger oldMax = [self _finchMaxVisibleLevel];
    [self _finchRowsReshaped:^{
        if (item) {
            [self _finchExpand:item children:children];
        } else {
            for (id child in [self _finchChildrenOf:nil])
                [self _finchExpand:child children:children];
        }
    }];
    [self _finchAdjustOutlineColumn:oldMax];
}

- (void)expandItem:(id)item
{
    [self expandItem:item expandChildren:NO];
}

- (void)collapseItem:(id)item collapseChildren:(BOOL)children
{
    if (!_built)
        [self _finchBuildRows];
    NSInteger oldMax = [self _finchMaxVisibleLevel];
    [self _finchRowsReshaped:^{
        if (item) {
            [self _finchCollapse:item children:children];
        } else {
            for (id child in [[self _finchChildrenOf:nil] reverseObjectEnumerator])
                [self _finchCollapse:child children:children];
        }
    }];
    [self _finchAdjustOutlineColumn:oldMax];
}

- (void)collapseItem:(id)item
{
    [self collapseItem:item collapseChildren:NO];
}

#pragma mark - Reloading and changing the tree

- (void)reloadData
{
    /* keep what's expanded; ask for children again */
    [_children removeAllObjects];
    if (!_built || [self dataSource]) {
        NSIndexSet *sel = [self selectedRowIndexes];
        NSMutableArray *selItems = [NSMutableArray array];
        [sel enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
            if (r < [_items count])
                [selItems addObject:[_items objectAtIndex:r]];
        }];
        [self _finchBuildRows];
        [super reloadData];
        NSMutableIndexSet *now = [NSMutableIndexSet indexSet];
        for (id it in selItems) {
            NSUInteger r = [_items indexOfObjectIdenticalTo:it];
            if (r != NSNotFound)
                [now addIndex:r];
        }
        if (![now isEqualToIndexSet:[self selectedRowIndexes]])
            [self _finchSetSelectedRows:now anchor:[now count] ? (NSInteger)[now lastIndex] : -1 notify:YES];
    } else {
        [super reloadData];
    }
}

- (void)reloadItem:(id)item reloadChildren:(BOOL)reloadChildren
{
    if (!item) {
        [self reloadData];
        return;
    }
    [self _finchRowsReshaped:^{
        if (reloadChildren) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:item];
            while ([stack count]) {
                id it = [stack lastObject];
                [stack removeLastObject];
                NSArray *c = [_children objectForKey:it];
                if (c)
                    [stack addObjectsFromArray:c];
                [_children removeObjectForKey:it];
            }
        }
    }];
}

- (void)reloadItem:(id)item
{
    [self reloadItem:item reloadChildren:NO];
}

- (void)insertItemsAtIndexes:(NSIndexSet *)indexes inParent:(id)parent withAnimation:(NSTableViewAnimationOptions)options
{
    if (!_built)
        [self _finchBuildRows];
    if (![self _finchIsViewBased] && ![self _finchInUpdates])
        [NSException raise:NSInternalInconsistencyException
                    format:@"NSTableView Error: Insert/remove/move only works within a -beginUpdates/-endUpdates "
                           @"block or a View Based TableView."];
    NSMutableArray *c = [[[_children objectForKey:key_for(parent)] mutableCopy] autorelease];
    if (!c)
        return;
    id ds = [self dataSource];
    [self _finchRowsReshaped:^{
        [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
            id child = [ds outlineView:self child:i ofItem:parent];
            [c insertObject:child ?: [NSNull null] atIndex:MIN(i, [c count])];
        }];
        [_children setObject:c forKey:key_for(parent)];
    }];
}

- (void)removeItemsAtIndexes:(NSIndexSet *)indexes inParent:(id)parent withAnimation:(NSTableViewAnimationOptions)options
{
    if (!_built)
        [self _finchBuildRows];
    if (![self _finchIsViewBased] && ![self _finchInUpdates])
        [NSException raise:NSInternalInconsistencyException
                    format:@"NSTableView Error: Insert/remove/move only works within a -beginUpdates/-endUpdates "
                           @"block or a View Based TableView."];
    NSMutableArray *c = [[[_children objectForKey:key_for(parent)] mutableCopy] autorelease];
    if (!c)
        return;
    [self _finchRowsReshaped:^{
        NSIndexSet *valid = [indexes indexesPassingTest:^BOOL(NSUInteger i, BOOL *stop) {
            return i < [c count];
        }];
        [c removeObjectsAtIndexes:valid];
        [_children setObject:c forKey:key_for(parent)];
    }];
}

- (void)moveItemAtIndex:(NSInteger)from inParent:(id)oldParent toIndex:(NSInteger)to inParent:(id)newParent
{
    if (!_built)
        [self _finchBuildRows];
    NSMutableArray *a = [[[_children objectForKey:key_for(oldParent)] mutableCopy] autorelease];
    NSMutableArray *b = oldParent == newParent ? a : [[[_children objectForKey:key_for(newParent)] mutableCopy] autorelease];
    if (!a || !b || from < 0 || (NSUInteger)from >= [a count])
        return;
    [self _finchRowsReshaped:^{
        id it = [[a objectAtIndex:from] retain];
        [a removeObjectAtIndex:from];
        [b insertObject:it atIndex:MIN((NSUInteger)MAX(to, 0), [b count])];
        [it release];
        [_children setObject:a forKey:key_for(oldParent)];
        [_children setObject:b forKey:key_for(newParent)];
    }];
}

- (BOOL)_finchInUpdates
{
    return [(id)self _finchUpdateDepth] > 0;
}

#pragma mark - Geometry

- (NSRect)_finchOutlineGeometry:(NSInteger)row cell:(NSRect *)cellOut outline:(NSRect *)outlineOut
{
    NSTableColumn *oc = [self outlineTableColumn];
    NSInteger col = oc ? (NSInteger)[[self tableColumns] indexOfObjectIdenticalTo:oc] : -1;
    NSRect plain = [self _finchPlainFrameOfCellAtColumn:col row:row];
    NSRect colRect = [self rectOfColumn:col];
    NSInteger level = MAX(0, [self levelForRow:row]);
    CGFloat markerX = NSMinX(colRect) + MAX(0, NSMinX(plain) - NSMinX(colRect) - 4);
    CGFloat cellX = markerX + disclosure_width + level * _indentation;
    NSRect cell = NSMakeRect(cellX, NSMinY(plain), MAX(0, NSMaxX(plain) - cellX), NSHeight(plain));
    NSRect rowRect = [self rectOfRow:row];
    NSRect outline = NSMakeRect(markerX + (_followsCell ? level * _indentation : 0), NSMinY(rowRect), disclosure_width,
                                NSHeight(rowRect));
    if (cellOut)
        *cellOut = cell;
    if (outlineOut)
        *outlineOut = outline;
    return plain;
}

- (NSRect)frameOfCellAtColumn:(NSInteger)column row:(NSInteger)row
{
    NSRect plain = [super frameOfCellAtColumn:column row:row];
    if (NSIsEmptyRect(plain))
        return plain;
    NSTableColumn *oc = [self outlineTableColumn];
    if (!oc || [[self tableColumns] objectAtIndex:column] != oc || [self _finchIsGroupRow:row])
        return plain;
    NSRect cell;
    [self _finchOutlineGeometry:row cell:&cell outline:NULL];
    return cell;
}

- (NSRect)frameOfOutlineCellAtRow:(NSInteger)row
{
    id item = [self itemAtRow:row];
    if (!item || ![self isExpandable:item] || ![self outlineTableColumn])
        return NSZeroRect;
    NSRect outline;
    [self _finchOutlineGeometry:row cell:NULL outline:&outline];
    return outline;
}

#pragma mark - Drawing and clicks

- (void)drawRow:(NSInteger)row clipRect:(NSRect)clip
{
    [super drawRow:row clipRect:clip];
    NSRect f = [self frameOfOutlineCellAtRow:row];
    if (NSIsEmptyRect(f) || !NSIntersectsRect(f, clip))
        return;
    BOOL selected = [self isRowSelected:row] && [self _finchEmphasized];
    FinchTableDrawDisclosure(f, [self isItemExpanded:[self itemAtRow:row]], YES,
                             selected ? [NSColor alternateSelectedControlTextColor] : [NSColor secondaryLabelColor]);
}

- (BOOL)_finchMouseDownInOutlineCell:(NSEvent *)event row:(NSInteger)row
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSRect f = [self frameOfOutlineCellAtRow:row];
    if (NSIsEmptyRect(f) || !NSPointInRect(p, NSInsetRect(f, -2, 0)))
        return NO;
    id item = [self itemAtRow:row];
    BOOL all = ([event modifierFlags] & NSEventModifierFlagOption) != 0;
    if ([self isItemExpanded:item])
        [self collapseItem:item collapseChildren:all];
    else
        [self expandItem:item expandChildren:all];
    return YES;
}

- (void)moveRight:(id)sender
{
    id item = [self itemAtRow:[self selectedRow]];
    if (item && [self isExpandable:item])
        [self expandItem:item];
}

- (void)moveLeft:(id)sender
{
    NSInteger row = [self selectedRow];
    id item = [self itemAtRow:row];
    if (!item)
        return;
    if ([self isItemExpanded:item]) {
        [self collapseItem:item];
        return;
    }
    id parent = [self parentForItem:item];
    if (parent)
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:[self rowForItem:parent]] byExtendingSelection:NO];
}

- (void)setDropItem:(id)item dropChildIndex:(NSInteger)index {}
- (BOOL)shouldCollapseAutoExpandedItemsForDeposited:(BOOL)deposited { return YES; }
- (NSButton *)_finchDisclosureButton { return nil; }

@end
