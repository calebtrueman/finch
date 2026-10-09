/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSCollectionView and NSCollectionViewItem.
 *
 * The modern collection view asks its data source for sections and items,
 * a layout (NSCollectionViewLayout.m) for where they go, and shows an item
 * (a view controller made from a registered class or nib) for each element
 * in the visible rect, its origin rounded to the backing pixels. The older
 * one shows an array (content) with copies of a prototype item in a grid of
 * the prototype's size (at least minItemSize, at most maxItemSize), as many
 * columns as fit or maxNumberOfColumns.
 *
 * As measured on macOS 26.4: the view is flipped and not selectable to
 * begin with, one section without a data source; in a scroll view it is as
 * wide as the clip view and at least as tall, growing with the layout's
 * content; programmatic selection ignores selectable and
 * allowsMultipleSelection and tells the delegate nothing, -selectAll: and
 * -deselectAll: tell it; reloading clears the selection; an older
 * collection view's selectionIndexPaths stays empty (its selection is
 * selectionIndexes).
 *
 * Nib keys: NSCollectionViewCore (_NSCollectionViewCore: UICollectionLayout,
 * UIAllowsMultipleSelection), NSSelectable, NSAllowsMultipleSelection,
 * NSBackgroundColors, NSMinGridSize, NSMaxGridSize, NSMaxNumberOfGridRows,
 * NSMaxNumberOfGridColumns.
 */
#import "NSTableView_Finch.h"


@interface NSCollectionViewLayout (FinchCollection)
- (void)_finchSetCollectionView:(NSCollectionView *)cv;
- (void)_finchEnsurePrepared;
@end

@interface NSCollectionViewItem (FinchCollection)
- (void)_finchSetCollectionView:(NSCollectionView *)cv;
@end

#pragma mark - Index paths

@implementation NSIndexPath (NSCollectionViewAdditions)

+ (NSIndexPath *)indexPathForItem:(NSInteger)item inSection:(NSInteger)section
{
    NSUInteger idx[2] = {(NSUInteger)section, (NSUInteger)item};
    return [self indexPathWithIndexes:idx length:2];
}

- (NSInteger)item { return (NSInteger)[self indexAtPosition:1]; }
- (NSInteger)section { return (NSInteger)[self indexAtPosition:0]; }

@end

@implementation NSSet (NSCollectionViewAdditions)

+ (instancetype)setWithCollectionViewIndexPath:(NSIndexPath *)indexPath
{
    return [self setWithObject:indexPath];
}

+ (instancetype)setWithCollectionViewIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
{
    return [self setWithArray:indexPaths];
}

- (void)enumerateIndexPathsWithOptions:(NSEnumerationOptions)opts
                            usingBlock:(void (NS_NOESCAPE ^)(NSIndexPath *, BOOL *))block
{
    NSArray *sorted = [[self allObjects] sortedArrayUsingSelector:@selector(compare:)];
    [sorted enumerateObjectsWithOptions:opts usingBlock:^(id p, NSUInteger i, BOOL *stop) {
        block(p, stop);
    }];
}

@end

#pragma mark - The nib's core

/* What a nib keeps a collection view's layout and selection mode in. */
@interface _NSCollectionViewCore : NSObject <NSCoding> {
@public
    NSCollectionViewLayout *_layout;
    BOOL _multiple;
}
@end

@implementation _NSCollectionViewCore
- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    _layout = [[coder decodeObjectForKey:@"UICollectionLayout"] retain];
    _multiple = [coder decodeBoolForKey:@"UIAllowsMultipleSelection"];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_layout)
        [coder encodeObject:_layout forKey:@"UICollectionLayout"];
    [coder encodeBool:_multiple forKey:@"UIAllowsMultipleSelection"];
}
- (void)dealloc
{
    [_layout release];
    [super dealloc];
}
@end

#pragma mark - NSCollectionView

@implementation NSCollectionView {
    NSCollectionViewLayout *_layout;
    id _dataSource, _delegate, _prefetch; /* not retained */
    NSArray *_content;
    NSCollectionViewItem *_prototype;
    NSMutableSet *_selection;
    NSMutableIndexSet *_legacySelection;
    NSArray *_backgroundColors;
    NSView *_backgroundView;
    NSUInteger _maxRows, _maxColumns;
    NSSize _minItemSize, _maxItemSize;
    NSMutableDictionary *_itemClasses, *_itemNibs, *_suppClasses, *_suppNibs;
    NSMutableDictionary *_items;     /* NSIndexPath -> NSCollectionViewItem */
    NSMutableDictionary *_supplementary; /* "kind/section" -> view */
    NSMutableDictionary *_reuse;     /* identifier -> NSMutableArray */
    NSMutableArray *_counts;         /* items per section, while counted */
    NSMutableArray *_legacyItems;    /* items for the content, in order */
    NSView *_observedClip;
    BOOL _selectable, _multiple, _empty, _laying, _firstResponderOK, _backgroundScrolls;
}

static void
collection_init(NSCollectionView *self)
{
    self->_selection = [[NSMutableSet alloc] init];
    self->_legacySelection = [[NSMutableIndexSet alloc] init];
    self->_empty = YES;
    self->_items = [[NSMutableDictionary alloc] init];
    self->_supplementary = [[NSMutableDictionary alloc] init];
    self->_reuse = [[NSMutableDictionary alloc] init];
    self->_itemClasses = [[NSMutableDictionary alloc] init];
    self->_itemNibs = [[NSMutableDictionary alloc] init];
    self->_suppClasses = [[NSMutableDictionary alloc] init];
    self->_suppNibs = [[NSMutableDictionary alloc] init];
    self->_legacyItems = [[NSMutableArray alloc] init];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        collection_init(self);
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    collection_init(self);
    _NSCollectionViewCore *core = [coder decodeObjectForKey:@"NSCollectionViewCore"];
    if ([core isKindOfClass:[_NSCollectionViewCore class]]) {
        if (core->_layout)
            [self setCollectionViewLayout:core->_layout];
        _multiple = core->_multiple;
    }
    _selectable = [coder decodeBoolForKey:@"NSSelectable"];
    if ([coder containsValueForKey:@"NSAllowsMultipleSelection"])
        _multiple = [coder decodeBoolForKey:@"NSAllowsMultipleSelection"];
    _backgroundColors = [[coder decodeObjectForKey:@"NSBackgroundColors"] copy];
    id v = [coder decodeObjectForKey:@"NSMinGridSize"];
    if ([v isKindOfClass:[NSString class]])
        _minItemSize = NSSizeFromString(v);
    v = [coder decodeObjectForKey:@"NSMaxGridSize"];
    if ([v isKindOfClass:[NSString class]])
        _maxItemSize = NSSizeFromString(v);
    _maxRows = [coder decodeIntegerForKey:@"NSMaxNumberOfGridRows"];
    _maxColumns = [coder decodeIntegerForKey:@"NSMaxNumberOfGridColumns"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeBool:_selectable forKey:@"NSSelectable"];
    [coder encodeBool:_multiple forKey:@"NSAllowsMultipleSelection"];
    if (_backgroundColors)
        [coder encodeObject:_backgroundColors forKey:@"NSBackgroundColors"];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_layout _finchSetCollectionView:nil];
    [_layout release];
    [_content release];
    [_prototype release];
    [_selection release];
    [_legacySelection release];
    [_backgroundColors release];
    [_backgroundView release];
    [_itemClasses release];
    [_itemNibs release];
    [_suppClasses release];
    [_suppNibs release];
    for (NSCollectionViewItem *it in [_items allValues])
        [it _finchSetCollectionView:nil];
    [_items release];
    [_supplementary release];
    [_reuse release];
    [_counts release];
    [_legacyItems release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return _selectable; }

/* Outside a window, what the clip view shows (as Apple's). */
- (NSRect)visibleRect
{
    return FinchClippedVisibleRect(self);
}

#pragma mark Properties

- (id<NSCollectionViewDataSource>)dataSource { return _dataSource; }

- (void)setDataSource:(id<NSCollectionViewDataSource>)dataSource
{
    _dataSource = dataSource;
    [self reloadData];
}

- (id<NSCollectionViewDelegate>)delegate { return _delegate; }

- (void)setDelegate:(id<NSCollectionViewDelegate>)delegate
{
    _delegate = delegate;
    [_layout invalidateLayout];
}

- (id<NSCollectionViewPrefetching>)prefetchDataSource { return _prefetch; }
- (void)setPrefetchDataSource:(id<NSCollectionViewPrefetching>)p { _prefetch = p; }
- (NSCollectionViewLayout *)collectionViewLayout { return _layout; }

- (void)setCollectionViewLayout:(NSCollectionViewLayout *)layout
{
    if (layout == _layout)
        return;
    [_layout _finchSetCollectionView:nil];
    [_layout autorelease];
    _layout = [layout retain];
    [_layout _finchSetCollectionView:self];
    [self _finchRemoveAllItems];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (BOOL)isSelectable { return _selectable; }
- (void)setSelectable:(BOOL)flag { _selectable = flag; }
- (BOOL)allowsMultipleSelection { return _multiple; }
- (void)setAllowsMultipleSelection:(BOOL)flag { _multiple = flag; }
- (BOOL)allowsEmptySelection { return _empty; }
- (void)setAllowsEmptySelection:(BOOL)flag { _empty = flag; }
- (NSArray<NSColor *> *)backgroundColors { return _backgroundColors ?: @[ [NSColor controlBackgroundColor] ]; }

- (void)setBackgroundColors:(NSArray<NSColor *> *)colors
{
    [_backgroundColors autorelease];
    _backgroundColors = [colors copy];
    [self setNeedsDisplay:YES];
}

- (NSView *)backgroundView { return _backgroundView; }

- (void)setBackgroundView:(NSView *)view
{
    [_backgroundView autorelease];
    _backgroundView = [view retain];
}

- (BOOL)backgroundViewScrollsWithContent { return _backgroundScrolls; }
- (void)setBackgroundViewScrollsWithContent:(BOOL)flag { _backgroundScrolls = flag; }
- (NSUInteger)maxNumberOfRows { return _maxRows; }
- (void)setMaxNumberOfRows:(NSUInteger)n { _maxRows = n; [self _finchLegacyChanged]; }
- (NSUInteger)maxNumberOfColumns { return _maxColumns; }
- (void)setMaxNumberOfColumns:(NSUInteger)n { _maxColumns = n; [self _finchLegacyChanged]; }
- (NSSize)minItemSize { return _minItemSize; }
- (void)setMinItemSize:(NSSize)s { _minItemSize = s; [self _finchLegacyChanged]; }
- (NSSize)maxItemSize { return _maxItemSize; }
- (void)setMaxItemSize:(NSSize)s { _maxItemSize = s; [self _finchLegacyChanged]; }
- (BOOL)isFirstResponder { return [[self window] firstResponder] == self; }

- (void)drawRect:(NSRect)dirty
{
    NSArray *colors = [self backgroundColors];
    if ([colors count]) {
        [[colors objectAtIndex:0] setFill];
        NSRectFill(dirty);
    }
}

#pragma mark Counts

- (BOOL)_finchLegacy { return !_layout && !_dataSource; }

- (void)_finchCount
{
    if (_counts)
        return;
    _counts = [[NSMutableArray alloc] init];
    if ([self _finchLegacy]) {
        [_counts addObject:@([_content count])];
        return;
    }
    NSInteger sections = [_dataSource respondsToSelector:@selector(numberOfSectionsInCollectionView:)]
                             ? [_dataSource numberOfSectionsInCollectionView:self]
                             : 1;
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger n = [_dataSource respondsToSelector:@selector(collectionView:numberOfItemsInSection:)]
                          ? [_dataSource collectionView:self numberOfItemsInSection:s]
                          : 0;
        [_counts addObject:@(n)];
    }
}

- (NSInteger)numberOfSections
{
    [self _finchCount];
    return (NSInteger)[_counts count];
}

- (NSInteger)numberOfItemsInSection:(NSInteger)section
{
    [self _finchCount];
    if (section < 0 || section >= (NSInteger)[_counts count])
        return 0;
    return [[_counts objectAtIndex:section] integerValue];
}

/* The size the layout lays out in: the view's, or the clip view's when inside one. */
- (NSSize)_finchLayoutSize
{
    NSClipView *clip = (NSClipView *)[self superview];
    if ([clip isKindOfClass:[NSClipView class]])
        return [clip bounds].size;
    return [self bounds].size;
}

#pragma mark Registering and making items

- (void)registerClass:(Class)itemClass forItemWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    if (itemClass)
        [_itemClasses setObject:itemClass forKey:identifier];
    else
        [_itemClasses removeObjectForKey:identifier];
    [_itemNibs removeObjectForKey:identifier];
}

- (void)registerNib:(NSNib *)nib forItemWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    if (nib)
        [_itemNibs setObject:nib forKey:identifier];
    else
        [_itemNibs removeObjectForKey:identifier];
    [_itemClasses removeObjectForKey:identifier];
}

static NSString *
supp_key(NSString *kind, NSString *identifier)
{
    return [NSString stringWithFormat:@"%@\n%@", kind, identifier];
}

- (void)registerClass:(Class)viewClass forSupplementaryViewOfKind:(NSCollectionViewSupplementaryElementKind)kind
       withIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    if (viewClass)
        [_suppClasses setObject:viewClass forKey:supp_key(kind, identifier)];
    else
        [_suppClasses removeObjectForKey:supp_key(kind, identifier)];
}

- (void)registerNib:(NSNib *)nib forSupplementaryViewOfKind:(NSCollectionViewSupplementaryElementKind)kind
     withIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    if (nib)
        [_suppNibs setObject:nib forKey:supp_key(kind, identifier)];
    else
        [_suppNibs removeObjectForKey:supp_key(kind, identifier)];
}

- (NSCollectionViewItem *)makeItemWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
                                     forIndexPath:(NSIndexPath *)indexPath
{
    NSMutableArray *q = [_reuse objectForKey:identifier];
    if ([q count]) {
        NSCollectionViewItem *it = [[[q lastObject] retain] autorelease];
        [q removeLastObject];
        [it prepareForReuse];
        return it;
    }
    Class c = [_itemClasses objectForKey:identifier];
    NSCollectionViewItem *it = nil;
    if (c) {
        it = [[[c alloc] initWithNibName:nil bundle:nil] autorelease];
    } else {
        NSNib *nib = [_itemNibs objectForKey:identifier];
        NSArray *top = nil;
        if (nib && [nib instantiateWithOwner:nil topLevelObjects:&top])
            for (id o in top)
                if ([o isKindOfClass:[NSCollectionViewItem class]]) {
                    it = o;
                    break;
                }
    }
    if (!it)
        [NSException raise:NSInternalInconsistencyException
                    format:@"-[NSCollectionView makeItemWithIdentifier:forIndexPath:] no class or nib registered for "
                           @"identifier %@",
                           identifier];
    [it setIdentifier:identifier];
    [it view];
    return it;
}

- (NSView *)makeSupplementaryViewOfKind:(NSCollectionViewSupplementaryElementKind)kind
                         withIdentifier:(NSUserInterfaceItemIdentifier)identifier
                           forIndexPath:(NSIndexPath *)indexPath
{
    NSString *key = supp_key(kind, identifier);
    NSMutableArray *q = [_reuse objectForKey:key];
    if ([q count]) {
        NSView *v = [[[q lastObject] retain] autorelease];
        [q removeLastObject];
        return v;
    }
    Class c = [_suppClasses objectForKey:key];
    NSView *v = nil;
    if (c) {
        v = [[[c alloc] initWithFrame:NSZeroRect] autorelease];
    } else {
        NSNib *nib = [_suppNibs objectForKey:key];
        NSArray *top = nil;
        if (nib && [nib instantiateWithOwner:nil topLevelObjects:&top])
            for (id o in top)
                if ([o isKindOfClass:[NSView class]]) {
                    v = o;
                    break;
                }
    }
    [v setIdentifier:identifier];
    return v;
}

#pragma mark Items

- (NSCollectionViewItem *)_finchNewItemAt:(NSIndexPath *)p
{
    if ([self _finchLegacy]) {
        NSCollectionViewItem *it = [self newItemForRepresentedObject:[_content objectAtIndex:[p item]]];
        return [it autorelease];
    }
    if ([_dataSource respondsToSelector:@selector(collectionView:itemForRepresentedObjectAtIndexPath:)])
        return [_dataSource collectionView:self itemForRepresentedObjectAtIndexPath:p];
    return nil;
}

- (NSCollectionViewItem *)newItemForRepresentedObject:(id)object
{
    NSCollectionViewItem *proto = _prototype;
    NSCollectionViewItem *it =
        [[[proto class] ?: [NSCollectionViewItem class] alloc] initWithNibName:[proto nibName] bundle:[proto nibBundle]];
    [it setRepresentedObject:object];
    NSView *v = [it view];
    if (proto && [proto isViewLoaded])
        [v setFrameSize:[[proto view] frame].size];
    return it;
}

- (void)_finchRemoveItem:(NSIndexPath *)p enqueue:(BOOL)enqueue
{
    NSCollectionViewItem *it = [[[_items objectForKey:p] retain] autorelease];
    if (!it)
        return;
    [_items removeObjectForKey:p];
    [[it view] removeFromSuperview];
    if ([_delegate respondsToSelector:@selector(collectionView:didEndDisplayingItem:forRepresentedObjectAtIndexPath:)])
        [_delegate collectionView:self didEndDisplayingItem:it forRepresentedObjectAtIndexPath:p];
    if (enqueue && [it identifier]) {
        NSMutableArray *q = [_reuse objectForKey:[it identifier]];
        if (!q) {
            q = [NSMutableArray array];
            [_reuse setObject:q forKey:[it identifier]];
        }
        [q addObject:it];
    }
}

- (void)_finchRemoveAllItems
{
    for (NSIndexPath *p in [_items allKeys])
        [self _finchRemoveItem:p enqueue:NO];
    for (NSView *v in [_supplementary allValues])
        [v removeFromSuperview];
    [_supplementary removeAllObjects];
    for (NSCollectionViewItem *it in _legacyItems)
        [[it view] removeFromSuperview];
    [_legacyItems removeAllObjects];
}

static NSRect
pixel_rect(NSCollectionView *self, NSRect r)
{
    CGFloat s = MAX(1, [[self window] backingScaleFactor]);
    r.origin.x = round(r.origin.x * s) / s;
    r.origin.y = round(r.origin.y * s) / s;
    return r;
}

/* Lay out: the layout's content sizes the view; items for the visible elements. */
- (void)_finchLayOutItems
{
    if (_laying)
        return;
    _laying = YES;
    if ([self _finchLegacy]) {
        [self _finchLayOutLegacy];
        _laying = NO;
        return;
    }
    [_layout _finchEnsurePrepared];
    NSClipView *clip = (NSClipView *)[self superview];
    if (_layout && [clip isKindOfClass:[NSClipView class]]) {
        NSSize content = [_layout collectionViewContentSize];
        NSSize c = [clip bounds].size;
        NSSize size = NSMakeSize(MAX(content.width, c.width), MAX(content.height, c.height));
        if (!NSEqualSizes(size, [self frame].size))
            [super setFrameSize:size];
    }
    NSRect vis = NSIntersectionRect([self visibleRect], [self bounds]);
    NSArray *attrs = [_layout layoutAttributesForElementsInRect:vis] ?: @[];
    NSMutableSet *want = [NSMutableSet set];
    for (NSCollectionViewLayoutAttributes *a in attrs)
        if ([a representedElementCategory] == NSCollectionElementCategoryItem)
            [want addObject:[a indexPath]];
    for (NSIndexPath *p in [_items allKeys])
        if (![want containsObject:p])
            [self _finchRemoveItem:p enqueue:YES];
    for (NSCollectionViewLayoutAttributes *a in attrs) {
        NSIndexPath *p = [a indexPath];
        if ([a representedElementCategory] == NSCollectionElementCategoryItem) {
            NSCollectionViewItem *it = [_items objectForKey:p];
            if (!it) {
                it = [self _finchNewItemAt:p];
                if (!it)
                    continue;
                [_items setObject:it forKey:p];
                [it _finchSetCollectionView:self];
                [it setSelected:[_selection containsObject:p]];
                if ([_delegate respondsToSelector:@selector(collectionView:willDisplayItem:forRepresentedObjectAtIndexPath:)])
                    [_delegate collectionView:self willDisplayItem:it forRepresentedObjectAtIndexPath:p];
            }
            NSView *v = [it view];
            [v setFrame:pixel_rect(self, [a frame])];
            [v setHidden:[a isHidden]];
            if ([v superview] != self)
                [self addSubview:v];
        } else if ([a representedElementCategory] == NSCollectionElementCategorySupplementaryView) {
            NSString *key = [NSString stringWithFormat:@"%@/%ld", [a representedElementKind], (long)[p section]];
            NSView *v = [_supplementary objectForKey:key];
            if (!v && [_dataSource respondsToSelector:@selector(collectionView:viewForSupplementaryElementOfKind:atIndexPath:)]) {
                v = [_dataSource collectionView:self viewForSupplementaryElementOfKind:[a representedElementKind]
                                    atIndexPath:p];
                if (v)
                    [_supplementary setObject:v forKey:key];
            }
            [v setFrame:pixel_rect(self, [a frame])];
            if (v && [v superview] != self)
                [self addSubview:v];
        }
    }
    _laying = NO;
}

- (void)layout
{
    [super layout];
    [self _finchLayOutItems];
}

- (void)viewWillDraw
{
    [self _finchLayOutItems];
    [super viewWillDraw];
}

- (void)setFrameSize:(NSSize)size
{
    NSSize old = [self frame].size;
    [super setFrameSize:size];
    if (!_laying && !NSEqualSizes(old, size)) {
        if ([_layout shouldInvalidateLayoutForBoundsChange:[self bounds]])
            [_layout invalidateLayout];
        [self setNeedsLayout:YES];
    }
}

- (void)viewWillMoveToSuperview:(NSView *)newSuperview
{
    if (_observedClip) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_observedClip];
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
        [nc addObserver:self selector:@selector(_finchClipFrameChanged:) name:NSViewFrameDidChangeNotification object:s];
        [nc addObserver:self selector:@selector(_finchClipBoundsChanged:) name:NSViewBoundsDidChangeNotification object:s];
        [self _finchClipFrameChanged:nil];
    }
}

- (void)_finchClipFrameChanged:(NSNotification *)note
{
    NSSize c = [_observedClip bounds].size;
    NSSize f = [self frame].size;
    if (f.width != c.width || f.height < c.height) {
        _laying = YES;
        [super setFrameSize:NSMakeSize(c.width, MAX(f.height, c.height))];
        _laying = NO;
    }
    [_layout invalidateLayout];
    [self setNeedsLayout:YES];
}

- (void)_finchClipBoundsChanged:(NSNotification *)note
{
    [self setNeedsLayout:YES];
}

- (NSArray<NSCollectionViewItem *> *)visibleItems
{
    if ([self _finchLegacy])
        return [[_legacyItems copy] autorelease];
    NSArray *keys = [[_items allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *out = [NSMutableArray array];
    for (NSIndexPath *p in keys)
        [out addObject:[_items objectForKey:p]];
    return out;
}

- (NSSet<NSIndexPath *> *)indexPathsForVisibleItems { return [NSSet setWithArray:[_items allKeys]]; }

- (NSCollectionViewItem *)itemAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self _finchLegacy])
        return [self itemAtIndex:[indexPath item]];
    return [_items objectForKey:indexPath];
}

- (NSIndexPath *)indexPathForItem:(NSCollectionViewItem *)item
{
    if ([self _finchLegacy]) {
        NSUInteger i = [_legacyItems indexOfObjectIdenticalTo:item];
        return i == NSNotFound ? nil : [NSIndexPath indexPathForItem:i inSection:0];
    }
    for (NSIndexPath *p in _items)
        if ([_items objectForKey:p] == item)
            return p;
    return nil;
}

- (NSIndexPath *)indexPathForItemAtPoint:(NSPoint)point
{
    if ([self _finchLegacy]) {
        for (NSUInteger i = 0; i < [_content count]; i++)
            if (NSPointInRect(point, [self frameForItemAtIndex:i]))
                return [NSIndexPath indexPathForItem:i inSection:0];
        return nil;
    }
    for (NSCollectionViewLayoutAttributes *a in [_layout layoutAttributesForElementsInRect:NSMakeRect(point.x, point.y, 1, 1)])
        if ([a representedElementCategory] == NSCollectionElementCategoryItem && NSPointInRect(point, [a frame]))
            return [a indexPath];
    return nil;
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return [_layout layoutAttributesForItemAtIndexPath:indexPath];
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForSupplementaryElementOfKind:(NSString *)kind
                                                                        atIndexPath:(NSIndexPath *)indexPath
{
    return [_layout layoutAttributesForSupplementaryViewOfKind:kind atIndexPath:indexPath];
}

- (NSRect)frameForItemAtIndex:(NSUInteger)index
{
    if ([self _finchLegacy])
        return [self frameForItemAtIndex:index withNumberOfItems:[_content count]];
    return [[self layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]] frame];
}

- (NSView *)supplementaryViewForElementKind:(NSCollectionViewSupplementaryElementKind)kind
                                atIndexPath:(NSIndexPath *)indexPath
{
    return [_supplementary objectForKey:[NSString stringWithFormat:@"%@/%ld", kind, (long)[indexPath section]]];
}

- (NSArray<NSView *> *)visibleSupplementaryViewsOfKind:(NSCollectionViewSupplementaryElementKind)kind
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in _supplementary)
        if ([k hasPrefix:[kind stringByAppendingString:@"/"]])
            [out addObject:[_supplementary objectForKey:k]];
    return out;
}

- (NSSet<NSIndexPath *> *)indexPathsForVisibleSupplementaryElementsOfKind:(NSCollectionViewSupplementaryElementKind)kind
{
    NSMutableSet *out = [NSMutableSet set];
    for (NSString *k in _supplementary)
        if ([k hasPrefix:[kind stringByAppendingString:@"/"]])
            [out addObject:[NSIndexPath indexPathForItem:0 inSection:[[k lastPathComponent] integerValue]]];
    return out;
}

#pragma mark Reloading and changing

- (void)reloadData
{
    [_counts release];
    _counts = nil;
    [self _finchRemoveAllItems];
    [_selection removeAllObjects];
    [_layout invalidateLayout];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)_finchUpdated
{
    [_counts release];
    _counts = nil;
    [self _finchRemoveAllItems];
    [_layout invalidateLayout];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

/* Index paths in a section shift as items come and go. */
- (void)_finchShiftSelection:(NSSet *)paths by:(NSInteger)delta
{
    NSMutableSet *out = [NSMutableSet set];
    for (NSIndexPath *s in _selection) {
        NSInteger item = [s item], section = [s section];
        BOOL gone = NO;
        NSInteger shift = 0;
        for (NSIndexPath *p in paths) {
            if ([p section] != section)
                continue;
            if (delta < 0 && [p item] == item)
                gone = YES;
            else if ([p item] < item || (delta > 0 && [p item] == item))
                shift += delta;
        }
        if (!gone)
            [out addObject:[NSIndexPath indexPathForItem:item + shift inSection:section]];
    }
    [_selection setSet:out];
}

- (void)insertItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths
{
    [self _finchShiftSelection:indexPaths by:1];
    [self _finchUpdated];
}

- (void)deleteItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths
{
    [self _finchShiftSelection:indexPaths by:-1];
    [self _finchUpdated];
}

- (void)reloadItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths { [self _finchUpdated]; }
- (void)moveItemAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to { [self _finchUpdated]; }
- (void)insertSections:(NSIndexSet *)sections { [self _finchUpdated]; }
- (void)deleteSections:(NSIndexSet *)sections { [self _finchUpdated]; }
- (void)reloadSections:(NSIndexSet *)sections { [self _finchUpdated]; }
- (void)moveSection:(NSInteger)section toSection:(NSInteger)newSection { [self _finchUpdated]; }

- (void)performBatchUpdates:(void(NS_NOESCAPE ^)(void))updates completionHandler:(void (^)(BOOL))completionHandler
{
    if (updates)
        updates();
    [self _finchUpdated];
    if (completionHandler)
        completionHandler(YES);
}

- (void)toggleSectionCollapse:(id)sender {}

- (void)scrollToItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths scrollPosition:(NSCollectionViewScrollPosition)pos
{
    NSRect r = NSZeroRect;
    for (NSIndexPath *p in indexPaths) {
        NSRect f = [[self layoutAttributesForItemAtIndexPath:p] frame];
        r = NSIsEmptyRect(r) ? f : NSUnionRect(r, f);
    }
    if (!NSIsEmptyRect(r))
        [self scrollRectToVisible:r];
}

#pragma mark Selection

static void
show_selection(NSCollectionView *self)
{
    for (NSIndexPath *p in self->_items)
        [[self->_items objectForKey:p] setSelected:[self->_selection containsObject:p]];
}

- (NSSet<NSIndexPath *> *)selectionIndexPaths { return [[_selection copy] autorelease]; }

- (void)setSelectionIndexPaths:(NSSet<NSIndexPath *> *)paths
{
    [self willChangeValueForKey:@"selectionIndexPaths"];
    [_selection setSet:paths ?: [NSSet set]];
    show_selection(self);
    [self didChangeValueForKey:@"selectionIndexPaths"];
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    if ([key isEqualToString:@"selectionIndexPaths"] || [key isEqualToString:@"selectionIndexes"])
        return NO;
    return [super automaticallyNotifiesObserversForKey:key];
}

- (NSIndexSet *)selectionIndexes
{
    if ([self _finchLegacy])
        return [[_legacySelection copy] autorelease];
    NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
    for (NSIndexPath *p in _selection)
        if ([p section] == 0)
            [s addIndex:[p item]];
    return s;
}

- (void)setSelectionIndexes:(NSIndexSet *)indexes
{
    [self willChangeValueForKey:@"selectionIndexes"];
    if ([self _finchLegacy]) {
        [_legacySelection removeAllIndexes];
        [_legacySelection addIndexes:indexes];
        for (NSUInteger i = 0; i < [_legacyItems count]; i++)
            [[_legacyItems objectAtIndex:i] setSelected:[_legacySelection containsIndex:i]];
    } else {
        NSMutableSet *s = [NSMutableSet set];
        [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
            [s addObject:[NSIndexPath indexPathForItem:i inSection:0]];
        }];
        [_selection setSet:s];
        show_selection(self);
    }
    [self didChangeValueForKey:@"selectionIndexes"];
}

- (void)selectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths scrollPosition:(NSCollectionViewScrollPosition)pos
{
    [self willChangeValueForKey:@"selectionIndexPaths"];
    [_selection unionSet:paths];
    show_selection(self);
    [self didChangeValueForKey:@"selectionIndexPaths"];
    if (pos != NSCollectionViewScrollPositionNone)
        [self scrollToItemsAtIndexPaths:paths scrollPosition:pos];
}

- (void)deselectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths
{
    [self willChangeValueForKey:@"selectionIndexPaths"];
    [_selection minusSet:paths];
    show_selection(self);
    [self didChangeValueForKey:@"selectionIndexPaths"];
}

- (NSSet *)_finchAllPaths
{
    NSMutableSet *all = [NSMutableSet set];
    for (NSInteger s = 0; s < [self numberOfSections]; s++)
        for (NSInteger i = 0; i < [self numberOfItemsInSection:s]; i++)
            [all addObject:[NSIndexPath indexPathForItem:i inSection:s]];
    return all;
}

- (void)selectAll:(id)sender
{
    if (!_selectable || !_multiple)
        return;
    NSMutableSet *add = [[[self _finchAllPaths] mutableCopy] autorelease];
    [add minusSet:_selection];
    if ([_delegate respondsToSelector:@selector(collectionView:shouldSelectItemsAtIndexPaths:)])
        add = [[[_delegate collectionView:self shouldSelectItemsAtIndexPaths:add] mutableCopy] autorelease];
    if (![add count])
        return;
    [self selectItemsAtIndexPaths:add scrollPosition:NSCollectionViewScrollPositionNone];
    if ([_delegate respondsToSelector:@selector(collectionView:didSelectItemsAtIndexPaths:)])
        [_delegate collectionView:self didSelectItemsAtIndexPaths:add];
}

- (void)deselectAll:(id)sender
{
    if (!_selectable || ![_selection count])
        return;
    NSSet *gone = [[_selection copy] autorelease];
    if ([_delegate respondsToSelector:@selector(collectionView:shouldDeselectItemsAtIndexPaths:)])
        gone = [_delegate collectionView:self shouldDeselectItemsAtIndexPaths:gone];
    if (![gone count])
        return;
    [self deselectItemsAtIndexPaths:gone];
    if ([_delegate respondsToSelector:@selector(collectionView:didDeselectItemsAtIndexPaths:)])
        [_delegate collectionView:self didDeselectItemsAtIndexPaths:gone];
}

- (void)mouseDown:(NSEvent *)event
{
    if (!_selectable)
        return;
    NSWindow *w = [self window];
    if ([w firstResponder] != self)
        [w makeFirstResponder:self];
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSIndexPath *hit = [self indexPathForItemAtPoint:p];
    if ([self _finchLegacy]) {
        NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
        if (hit) {
            if (_multiple && ([event modifierFlags] & NSEventModifierFlagCommand)) {
                [s addIndexes:_legacySelection];
                if ([s containsIndex:[hit item]])
                    [s removeIndex:[hit item]];
                else
                    [s addIndex:[hit item]];
            } else {
                [s addIndex:[hit item]];
            }
        } else if (!_empty) {
            [s addIndexes:_legacySelection];
        }
        [self setSelectionIndexes:s];
        return;
    }
    BOOL toggle = _multiple && ([event modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagShift));
    NSMutableSet *gone = [NSMutableSet set], *add = [NSMutableSet set];
    if (!toggle) {
        [gone unionSet:_selection];
        if (hit)
            [gone removeObject:hit];
        if (!hit && !_empty)
            [gone removeAllObjects];
    }
    if (hit) {
        if (toggle && [_selection containsObject:hit])
            [gone addObject:hit];
        else if (![_selection containsObject:hit])
            [add addObject:hit];
    }
    if ([gone count] && [_delegate respondsToSelector:@selector(collectionView:shouldDeselectItemsAtIndexPaths:)])
        gone = [[[_delegate collectionView:self shouldDeselectItemsAtIndexPaths:gone] mutableCopy] autorelease];
    if ([add count] && [_delegate respondsToSelector:@selector(collectionView:shouldSelectItemsAtIndexPaths:)])
        add = [[[_delegate collectionView:self shouldSelectItemsAtIndexPaths:add] mutableCopy] autorelease];
    if ([gone count]) {
        [self deselectItemsAtIndexPaths:gone];
        if ([_delegate respondsToSelector:@selector(collectionView:didDeselectItemsAtIndexPaths:)])
            [_delegate collectionView:self didDeselectItemsAtIndexPaths:gone];
    }
    if ([add count]) {
        [self selectItemsAtIndexPaths:add scrollPosition:NSCollectionViewScrollPositionNone];
        if ([_delegate respondsToSelector:@selector(collectionView:didSelectItemsAtIndexPaths:)])
            [_delegate collectionView:self didSelectItemsAtIndexPaths:add];
    }
}

#pragma mark The older collection view

- (NSArray *)content { return _content ?: @[]; }

- (void)setContent:(NSArray *)content
{
    [_content autorelease];
    _content = [content copy];
    [_counts release];
    _counts = nil;
    [self _finchRemoveAllItems];
    [self _finchLegacyChanged];
}

- (NSCollectionViewItem *)itemPrototype { return _prototype; }

- (void)setItemPrototype:(NSCollectionViewItem *)prototype
{
    [_prototype autorelease];
    _prototype = [prototype retain];
    [self _finchRemoveAllItems];
    [self _finchLegacyChanged];
}

- (void)_finchLegacyChanged
{
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (NSSize)_finchLegacyItemSize
{
    NSSize s = _prototype && [_prototype isViewLoaded] ? [[_prototype view] frame].size : NSZeroSize;
    if (_prototype && ![_prototype isViewLoaded])
        s = [[_prototype view] frame].size;
    s.width = MAX(s.width, _minItemSize.width);
    s.height = MAX(s.height, _minItemSize.height);
    if (_maxItemSize.width > 0)
        s.width = MIN(s.width, _maxItemSize.width);
    if (_maxItemSize.height > 0)
        s.height = MIN(s.height, _maxItemSize.height);
    return s;
}

- (NSRect)frameForItemAtIndex:(NSUInteger)index withNumberOfItems:(NSUInteger)count
{
    NSSize s = [self _finchLegacyItemSize];
    NSSize view = [self _finchLayoutSize];
    NSUInteger cols = s.width > 0 ? (NSUInteger)floor(view.width / s.width) : 1;
    if (_maxColumns > 0 && cols > _maxColumns)
        cols = _maxColumns;
    if (cols < 1)
        cols = 1;
    if (_maxRows > 0 && cols * _maxRows < count)
        cols = (count + _maxRows - 1) / _maxRows;
    return NSMakeRect((index % cols) * s.width, (index / cols) * s.height, s.width, s.height);
}

- (void)_finchLayOutLegacy
{
    NSUInteger n = [_content count];
    while ([_legacyItems count] > n) {
        [[[_legacyItems lastObject] view] removeFromSuperview];
        [_legacyItems removeLastObject];
    }
    for (NSUInteger i = 0; i < n; i++) {
        NSCollectionViewItem *it = i < [_legacyItems count] ? [_legacyItems objectAtIndex:i] : nil;
        if (!it) {
            it = [self newItemForRepresentedObject:[_content objectAtIndex:i]];
            [it _finchSetCollectionView:self];
            [_legacyItems addObject:it];
            [it release];
        } else if ([it representedObject] != [_content objectAtIndex:i]) {
            [it setRepresentedObject:[_content objectAtIndex:i]];
        }
        [it setSelected:[_legacySelection containsIndex:i]];
        NSView *v = [it view];
        [v setFrame:[self frameForItemAtIndex:i withNumberOfItems:n]];
        if ([v superview] != self)
            [self addSubview:v];
    }
}

- (NSCollectionViewItem *)itemAtIndex:(NSUInteger)index
{
    if ([self _finchLegacy]) {
        if (index >= [_content count])
            return nil;
        if (index >= [_legacyItems count])
            [self _finchLayOutLegacy];
        return index < [_legacyItems count] ? [_legacyItems objectAtIndex:index] : nil;
    }
    return [self itemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
}

#pragma mark Dragging (not yet)

- (void)setDraggingSourceOperationMask:(NSDragOperation)mask forLocal:(BOOL)isLocal {}
- (NSImage *)draggingImageForItemsAtIndexPaths:(NSSet *)paths withEvent:(NSEvent *)event offset:(NSPointPointer)offset
{
    return nil;
}

@end

#pragma mark - NSCollectionViewItem

@implementation NSCollectionViewItem {
    NSCollectionView *_collectionView; /* not retained */
    NSTextField *_textField;           /* not retained */
    NSImageView *_imageView;           /* not retained */
    NSUserInterfaceItemIdentifier _identifier;
    NSCollectionViewItemHighlightState _highlightState;
    BOOL _selected;
}

- (void)dealloc
{
    [_identifier release];
    [super dealloc];
}

- (NSCollectionView *)collectionView { return _collectionView; }
- (void)_finchSetCollectionView:(NSCollectionView *)cv { _collectionView = cv; }
- (BOOL)isSelected { return _selected; }
- (void)setSelected:(BOOL)selected { _selected = selected; }
- (NSCollectionViewItemHighlightState)highlightState { return _highlightState; }
- (void)setHighlightState:(NSCollectionViewItemHighlightState)state { _highlightState = state; }
- (NSImageView *)imageView { return _imageView; }
- (void)setImageView:(NSImageView *)view { _imageView = view; }
- (NSTextField *)textField { return _textField; }
- (void)setTextField:(NSTextField *)field { _textField = field; }
- (NSUserInterfaceItemIdentifier)identifier { return _identifier; }

- (void)setIdentifier:(NSUserInterfaceItemIdentifier)identifier
{
    [_identifier autorelease];
    _identifier = [identifier copy];
}

- (NSArray<NSDraggingImageComponent *> *)draggingImageComponents { return @[]; }
- (void)prepareForReuse {}
- (void)applyLayoutAttributes:(NSCollectionViewLayoutAttributes *)attributes {}
- (NSCollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:
    (NSCollectionViewLayoutAttributes *)attributes
{
    return attributes;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSCollectionViewItem *it = [[[self class] allocWithZone:zone] initWithNibName:[self nibName] bundle:[self nibBundle]];
    [it setRepresentedObject:[self representedObject]];
    return it;
}

@end
