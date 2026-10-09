/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The collection view's layouts: NSCollectionViewLayout and its
 * attributes, NSCollectionViewFlowLayout and NSCollectionViewGridLayout.
 *
 * A layout works out every element's attributes when prepared (after it is
 * invalidated, as the collection view lays out) and answers from them. As
 * measured on macOS 26.4 (appkit-tables-test.m):
 *   - Flow (vertical): sections follow each other down, each under its
 *     header, inside its insets. Items of one size go in a grid: as many as
 *     fit across with at least the interitem spacing, spread to the edges
 *     with the same spacing on every line (the last too), lines the line
 *     spacing apart. Items of different sizes fill lines one after another;
 *     each line but the last is spread to the edges, the last keeps the
 *     interitem spacing; items are centred in their line's height.
 *     Horizontal flow is the same turned on its side (a uniform grid fills
 *     columns down, columns the line spacing apart; items of different sizes
 *     are spaced the other way round, as Apple's are). The attributes keep
 *     their exact positions; the collection view rounds items' frames to
 *     the backing pixels.
 *   - Grid: as many columns as fit at the minimum item width (at most
 *     maximumNumberOfColumns), items stretched to fill the width up to the
 *     maximum size, and stretched down to fill the visible height when the
 *     rows fit; with maximumNumberOfRows, a fixed number of rows that
 *     scrolls sideways, columns the line spacing apart.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"

NSCollectionViewSupplementaryElementKind const NSCollectionElementKindSectionHeader = @"UICollectionElementKindSectionHeader";
NSCollectionViewSupplementaryElementKind const NSCollectionElementKindSectionFooter = @"UICollectionElementKindSectionFooter";
NSCollectionViewSupplementaryElementKind const NSCollectionElementKindInterItemGapIndicator =
    @"UICollectionElementKindInterItemGapIndicator";

@interface NSCollectionView (FinchLayout)
- (NSSize)_finchLayoutSize;
@end

#pragma mark - Attributes

@implementation NSCollectionViewLayoutAttributes {
    NSRect _frame;
    CGFloat _alpha;
    NSInteger _zIndex;
    BOOL _hidden;
    NSIndexPath *_indexPath;
    NSCollectionElementCategory _category;
    NSString *_kind;
}

- (instancetype)init
{
    if ((self = [super init]))
        _alpha = 1;
    return self;
}

- (void)dealloc
{
    [_indexPath release];
    [_kind release];
    [super dealloc];
}

+ (instancetype)layoutAttributesForItemWithIndexPath:(NSIndexPath *)indexPath
{
    NSCollectionViewLayoutAttributes *a = [[[self alloc] init] autorelease];
    a->_indexPath = [indexPath copy];
    a->_category = NSCollectionElementCategoryItem;
    return a;
}

+ (instancetype)layoutAttributesForInterItemGapBeforeIndexPath:(NSIndexPath *)indexPath
{
    NSCollectionViewLayoutAttributes *a = [[[self alloc] init] autorelease];
    a->_indexPath = [indexPath copy];
    a->_category = NSCollectionElementCategoryInterItemGap;
    a->_kind = [NSCollectionElementKindInterItemGapIndicator copy];
    return a;
}

+ (instancetype)layoutAttributesForSupplementaryViewOfKind:(NSString *)kind withIndexPath:(NSIndexPath *)indexPath
{
    NSCollectionViewLayoutAttributes *a = [[[self alloc] init] autorelease];
    a->_indexPath = [indexPath copy];
    a->_category = NSCollectionElementCategorySupplementaryView;
    a->_kind = [kind copy];
    return a;
}

+ (instancetype)layoutAttributesForDecorationViewOfKind:(NSString *)kind withIndexPath:(NSIndexPath *)indexPath
{
    NSCollectionViewLayoutAttributes *a = [[[self alloc] init] autorelease];
    a->_indexPath = [indexPath copy];
    a->_category = NSCollectionElementCategoryDecorationView;
    a->_kind = [kind copy];
    return a;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSCollectionViewLayoutAttributes *a = [[[self class] allocWithZone:zone] init];
    a->_frame = _frame;
    a->_alpha = _alpha;
    a->_zIndex = _zIndex;
    a->_hidden = _hidden;
    a->_indexPath = [_indexPath copy];
    a->_category = _category;
    a->_kind = [_kind copy];
    return a;
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSCollectionViewLayoutAttributes class]])
        return NO;
    NSCollectionViewLayoutAttributes *o = other;
    return NSEqualRects(_frame, o->_frame) && _alpha == o->_alpha && _zIndex == o->_zIndex && _hidden == o->_hidden &&
           _category == o->_category && (_indexPath == o->_indexPath || [_indexPath isEqual:o->_indexPath]) &&
           (_kind == o->_kind || [_kind isEqual:o->_kind]);
}

- (NSUInteger)hash
{
    return [_indexPath hash] ^ (NSUInteger)_category;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> indexPath: %@ frame: %@", [self class], self, _indexPath,
                                      NSStringFromRect(_frame)];
}

- (NSRect)frame { return _frame; }
- (void)setFrame:(NSRect)frame { _frame = frame; }
- (NSSize)size { return _frame.size; }
- (void)setSize:(NSSize)size { _frame.size = size; }
- (CGFloat)alpha { return _alpha; }
- (void)setAlpha:(CGFloat)alpha { _alpha = alpha; }
- (NSInteger)zIndex { return _zIndex; }
- (void)setZIndex:(NSInteger)z { _zIndex = z; }
- (BOOL)isHidden { return _hidden; }
- (void)setHidden:(BOOL)hidden { _hidden = hidden; }
- (NSIndexPath *)indexPath { return _indexPath; }

- (void)setIndexPath:(NSIndexPath *)indexPath
{
    [_indexPath autorelease];
    _indexPath = [indexPath copy];
}

- (NSCollectionElementCategory)representedElementCategory { return _category; }
- (NSString *)representedElementKind { return _kind; }

@end

#pragma mark - Invalidation contexts

@implementation NSCollectionViewLayoutInvalidationContext {
    BOOL _dataSourceCounts, _everything;
    NSPoint _offset;
    NSSize _size;
}
- (BOOL)invalidateEverything { return YES; }
- (BOOL)invalidateDataSourceCounts { return YES; }
- (void)invalidateItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths {}
- (void)invalidateSupplementaryElementsOfKind:(NSString *)kind atIndexPaths:(NSSet<NSIndexPath *> *)paths {}
- (void)invalidateDecorationElementsOfKind:(NSString *)kind atIndexPaths:(NSSet<NSIndexPath *> *)paths {}
- (NSSet<NSIndexPath *> *)invalidatedItemIndexPaths { return nil; }
- (NSDictionary *)invalidatedSupplementaryIndexPaths { return nil; }
- (NSDictionary *)invalidatedDecorationIndexPaths { return nil; }
- (NSPoint)contentOffsetAdjustment { return _offset; }
- (void)setContentOffsetAdjustment:(NSPoint)p { _offset = p; }
- (NSSize)contentSizeAdjustment { return _size; }
- (void)setContentSizeAdjustment:(NSSize)s { _size = s; }
@end

@implementation NSCollectionViewFlowLayoutInvalidationContext {
    BOOL _delegateMetrics, _attributes;
}
- (BOOL)invalidateFlowLayoutDelegateMetrics { return _delegateMetrics; }
- (void)setInvalidateFlowLayoutDelegateMetrics:(BOOL)f { _delegateMetrics = f; }
- (BOOL)invalidateFlowLayoutAttributes { return _attributes; }
- (void)setInvalidateFlowLayoutAttributes:(BOOL)f { _attributes = f; }
@end

#pragma mark - NSCollectionViewLayout

@implementation NSCollectionViewLayout {
    NSCollectionView *_collectionView; /* not retained */
    NSMutableDictionary *_decorationClasses;
@protected
    BOOL _prepared;
}

+ (Class)layoutAttributesClass { return [NSCollectionViewLayoutAttributes class]; }
+ (Class)invalidationContextClass { return [NSCollectionViewLayoutInvalidationContext class]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self init];
}

- (void)encodeWithCoder:(NSCoder *)coder {}

- (void)dealloc
{
    [_decorationClasses release];
    [super dealloc];
}

- (NSCollectionView *)collectionView { return _collectionView; }
- (void)_finchSetCollectionView:(NSCollectionView *)cv { _collectionView = cv; _prepared = NO; }

- (void)invalidateLayout
{
    _prepared = NO;
    [_collectionView setNeedsLayout:YES];
}

- (void)invalidateLayoutWithContext:(NSCollectionViewLayoutInvalidationContext *)context
{
    [self invalidateLayout];
}

- (void)_finchEnsurePrepared
{
    if (_prepared)
        return;
    _prepared = YES;
    [self prepareLayout];
}

- (void)prepareLayout {}
- (NSArray<NSCollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(NSRect)rect { return @[]; }
- (NSCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath { return nil; }

- (NSCollectionViewLayoutAttributes *)layoutAttributesForSupplementaryViewOfKind:(NSString *)kind
                                                                     atIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForDecorationViewOfKind:(NSString *)kind
                                                                  atIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForDropTargetAtPoint:(NSPoint)point { return nil; }
- (NSCollectionViewLayoutAttributes *)layoutAttributesForInterItemGapBeforeIndexPath:(NSIndexPath *)p { return nil; }
- (BOOL)shouldInvalidateLayoutForBoundsChange:(NSRect)newBounds { return NO; }

- (NSCollectionViewLayoutInvalidationContext *)invalidationContextForBoundsChange:(NSRect)newBounds
{
    return [[[[[self class] invalidationContextClass] alloc] init] autorelease];
}

- (NSPoint)targetContentOffsetForProposedContentOffset:(NSPoint)p withScrollingVelocity:(NSPoint)v { return p; }
- (NSPoint)targetContentOffsetForProposedContentOffset:(NSPoint)p { return p; }
- (NSSize)collectionViewContentSize { return NSZeroSize; }
- (void)prepareForCollectionViewUpdates:(NSArray *)updateItems {}
- (void)finalizeCollectionViewUpdates {}
- (void)prepareForAnimatedBoundsChange:(NSRect)oldBounds {}
- (void)finalizeAnimatedBoundsChange {}
- (void)prepareForTransitionToLayout:(NSCollectionViewLayout *)newLayout {}
- (void)prepareForTransitionFromLayout:(NSCollectionViewLayout *)oldLayout {}
- (void)finalizeLayoutTransition {}

- (void)registerClass:(Class)viewClass forDecorationViewOfKind:(NSString *)kind
{
    if (!_decorationClasses)
        _decorationClasses = [[NSMutableDictionary alloc] init];
    if (viewClass)
        [_decorationClasses setObject:viewClass forKey:kind];
    else
        [_decorationClasses removeObjectForKey:kind];
}

- (void)registerNib:(NSNib *)nib forDecorationViewOfKind:(NSString *)kind {}

@end

#pragma mark - Shared by the two layouts

/* What a prepared layout holds: every item's and supplementary view's attributes, and the content size. */
@interface _FinchLayoutStore : NSObject {
@public
    NSMutableDictionary *_items;  /* NSIndexPath -> attributes */
    NSMutableDictionary *_headers, *_footers;
    NSMutableArray *_all;
    NSSize _content;
}
@end

@implementation _FinchLayoutStore
- (instancetype)init
{
    self = [super init];
    _items = [[NSMutableDictionary alloc] init];
    _headers = [[NSMutableDictionary alloc] init];
    _footers = [[NSMutableDictionary alloc] init];
    _all = [[NSMutableArray alloc] init];
    return self;
}
- (void)dealloc
{
    [_items release];
    [_headers release];
    [_footers release];
    [_all release];
    [super dealloc];
}
- (void)addItem:(NSIndexPath *)p frame:(NSRect)f
{
    NSCollectionViewLayoutAttributes *a = [NSCollectionViewLayoutAttributes layoutAttributesForItemWithIndexPath:p];
    [a setFrame:f];
    [_items setObject:a forKey:p];
    [_all addObject:a];
}
- (void)addSupplementary:(NSString *)kind section:(NSInteger)s frame:(NSRect)f
{
    NSIndexPath *p = [NSIndexPath indexPathForItem:0 inSection:s];
    NSCollectionViewLayoutAttributes *a = [NSCollectionViewLayoutAttributes layoutAttributesForSupplementaryViewOfKind:kind
                                                                                                        withIndexPath:p];
    [a setFrame:f];
    [a setZIndex:1];
    [([kind isEqualToString:NSCollectionElementKindSectionHeader] ? _headers : _footers) setObject:a forKey:p];
    if (f.size.width > 0 && f.size.height > 0)
        [_all addObject:a];
}
- (NSArray *)inRect:(NSRect)r
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSCollectionViewLayoutAttributes *a in _all)
        if (NSIntersectsRect([a frame], r))
            [out addObject:[[a copy] autorelease]];
    return out;
}
@end

static NSSize
view_size(NSCollectionView *cv)
{
    return cv ? [cv _finchLayoutSize] : NSZeroSize;
}

#pragma mark - NSCollectionViewFlowLayout

@implementation NSCollectionViewFlowLayout {
    CGFloat _lineSpacing, _interitemSpacing;
    NSSize _itemSize, _estimatedItemSize, _headerSize, _footerSize;
    NSEdgeInsets _sectionInset;
    NSCollectionViewScrollDirection _direction;
    BOOL _pinHeaders, _pinFooters;
    NSMutableIndexSet *_collapsed;
    _FinchLayoutStore *_store;
}

static void
flow_init(NSCollectionViewFlowLayout *self)
{
    self->_lineSpacing = 10;
    self->_interitemSpacing = 10;
    self->_itemSize = NSMakeSize(50, 50);
    self->_collapsed = [[NSMutableIndexSet alloc] init];
}

- (instancetype)init
{
    if ((self = [super init]))
        flow_init(self);
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    flow_init(self);
    if ([coder containsValueForKey:@"NSLineSpacing"])
        _lineSpacing = [coder decodeDoubleForKey:@"NSLineSpacing"];
    if ([coder containsValueForKey:@"NSInteritemSpacing"])
        _interitemSpacing = [coder decodeDoubleForKey:@"NSInteritemSpacing"];
    NSValue *v;
    if ((v = [coder decodeObjectForKey:@"NSItemSize"]))
        _itemSize = [v sizeValue];
    if ((v = [coder decodeObjectForKey:@"NSEstimatedItemSize"]))
        _estimatedItemSize = [v sizeValue];
    if ((v = [coder decodeObjectForKey:@"NSHeaderReferenceSize"]))
        _headerSize = [v sizeValue];
    if ((v = [coder decodeObjectForKey:@"NSFooterReferenceSize"]))
        _footerSize = [v sizeValue];
    if ((v = [coder decodeObjectForKey:@"NSSectionInset"]))
        _sectionInset = [v edgeInsetsValue];
    _direction = [coder decodeIntegerForKey:@"NSScrollDirection"];
    _pinHeaders = [coder decodeBoolForKey:@"NSSectionHeadersPinToVisibleBounds"];
    _pinFooters = [coder decodeBoolForKey:@"NSSectionFootersPinToVisibleBounds"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_lineSpacing forKey:@"NSLineSpacing"];
    [coder encodeDouble:_interitemSpacing forKey:@"NSInteritemSpacing"];
    [coder encodeObject:[NSValue valueWithSize:_itemSize] forKey:@"NSItemSize"];
    [coder encodeObject:[NSValue valueWithEdgeInsets:_sectionInset] forKey:@"NSSectionInset"];
    if (_direction)
        [coder encodeInteger:_direction forKey:@"NSScrollDirection"];
}

- (void)dealloc
{
    [_collapsed release];
    [_store release];
    [super dealloc];
}

+ (Class)invalidationContextClass { return [NSCollectionViewFlowLayoutInvalidationContext class]; }

#define FLOW_PROPERTY(type, getter, setter, ivar)                                                                      \
    -(type)getter { return ivar; }                                                                                     \
    -(void)setter(type)v                                                                                               \
    {                                                                                                                  \
        ivar = v;                                                                                                      \
        [self invalidateLayout];                                                                                       \
    }

FLOW_PROPERTY(CGFloat, minimumLineSpacing, setMinimumLineSpacing:, _lineSpacing)
FLOW_PROPERTY(CGFloat, minimumInteritemSpacing, setMinimumInteritemSpacing:, _interitemSpacing)
FLOW_PROPERTY(NSSize, itemSize, setItemSize:, _itemSize)
FLOW_PROPERTY(NSSize, estimatedItemSize, setEstimatedItemSize:, _estimatedItemSize)
FLOW_PROPERTY(NSSize, headerReferenceSize, setHeaderReferenceSize:, _headerSize)
FLOW_PROPERTY(NSSize, footerReferenceSize, setFooterReferenceSize:, _footerSize)
FLOW_PROPERTY(NSEdgeInsets, sectionInset, setSectionInset:, _sectionInset)
FLOW_PROPERTY(NSCollectionViewScrollDirection, scrollDirection, setScrollDirection:, _direction)
FLOW_PROPERTY(BOOL, sectionHeadersPinToVisibleBounds, setSectionHeadersPinToVisibleBounds:, _pinHeaders)
FLOW_PROPERTY(BOOL, sectionFootersPinToVisibleBounds, setSectionFootersPinToVisibleBounds:, _pinFooters)

- (BOOL)sectionAtIndexIsCollapsed:(NSUInteger)section { return [_collapsed containsIndex:section]; }

- (void)collapseSectionAtIndex:(NSUInteger)section
{
    [_collapsed addIndex:section];
    [self invalidateLayout];
}

- (void)expandSectionAtIndex:(NSUInteger)section
{
    [_collapsed removeIndex:section];
    [self invalidateLayout];
}

/* A header or footer across the section (empty when its reference size is). */
static NSRect
supplementary_frame(BOOL vertical, CGFloat pos, CGFloat extent, NSSize ref)
{
    if (vertical)
        return ref.height > 0 ? NSMakeRect(0, pos, extent, ref.height) : NSMakeRect(0, pos, 0, 0);
    return ref.width > 0 ? NSMakeRect(pos, 0, ref.width, extent) : NSMakeRect(pos, 0, 0, 0);
}

/* One line (or column) of items: their sizes, laid along the line's direction. */
static void
place_line(_FinchLayoutStore *store, NSInteger section, NSArray *line, NSSize *sizes, NSInteger first, CGFloat start,
           CGFloat lineStart, CGFloat across, CGFloat gap, BOOL vertical)
{
    CGFloat pos = start;
    for (NSUInteger k = 0; k < [line count]; k++) {
        NSInteger i = first + k;
        NSSize s = sizes[i];
        CGFloat along = vertical ? s.width : s.height, other = vertical ? s.height : s.width;
        CGFloat off = (across - other) / 2;
        NSRect f = vertical ? NSMakeRect(pos, lineStart + off, s.width, s.height)
                            : NSMakeRect(lineStart + off, pos, s.width, s.height);
        [store addItem:[NSIndexPath indexPathForItem:i inSection:section] frame:f];
        pos += along + gap;
    }
}

- (void)prepareLayout
{
    [_store release];
    _store = [[_FinchLayoutStore alloc] init];
    NSCollectionView *cv = [self collectionView];
    if (!cv)
        return;
    id d = [cv delegate];
    BOOL vertical = _direction == NSCollectionViewScrollDirectionVertical;
    NSSize view = view_size(cv);
    CGFloat extent = vertical ? view.width : view.height; /* across the scrolling */
    CGFloat pos = 0;                                       /* along the scrolling */
    NSInteger sections = [cv numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        NSEdgeInsets in = [d respondsToSelector:@selector(collectionView:layout:insetForSectionAtIndex:)]
                              ? [d collectionView:cv layout:self insetForSectionAtIndex:s]
                              : _sectionInset;
        CGFloat ls = [d respondsToSelector:@selector(collectionView:layout:minimumLineSpacingForSectionAtIndex:)]
                         ? [d collectionView:cv layout:self minimumLineSpacingForSectionAtIndex:s]
                         : _lineSpacing;
        CGFloat is = [d respondsToSelector:@selector(collectionView:layout:minimumInteritemSpacingForSectionAtIndex:)]
                         ? [d collectionView:cv layout:self minimumInteritemSpacingForSectionAtIndex:s]
                         : _interitemSpacing;
        NSSize hs = [d respondsToSelector:@selector(collectionView:layout:referenceSizeForHeaderInSection:)]
                        ? [d collectionView:cv layout:self referenceSizeForHeaderInSection:s]
                        : _headerSize;
        NSSize fs = [d respondsToSelector:@selector(collectionView:layout:referenceSizeForFooterInSection:)]
                        ? [d collectionView:cv layout:self referenceSizeForFooterInSection:s]
                        : _footerSize;
        CGFloat hAlong = vertical ? hs.height : hs.width;
        [self->_store addSupplementary:NSCollectionElementKindSectionHeader section:s
                                 frame:supplementary_frame(vertical, pos, extent, hs)];
        pos += hAlong;
        CGFloat before = vertical ? in.top : in.left, after = vertical ? in.bottom : in.right;
        CGFloat sideA = vertical ? in.left : in.top, sideB = vertical ? in.right : in.bottom;
        pos += before;
        CGFloat avail = extent - sideA - sideB;
        NSInteger n = [cv numberOfItemsInSection:s];
        NSSize *sizes = malloc(MAX(n, 1) * sizeof(NSSize));
        BOOL uniform = YES;
        for (NSInteger i = 0; i < n; i++) {
            NSIndexPath *p = [NSIndexPath indexPathForItem:i inSection:s];
            sizes[i] = [d respondsToSelector:@selector(collectionView:layout:sizeForItemAtIndexPath:)]
                           ? [d collectionView:cv layout:self sizeForItemAtIndexPath:p]
                           : _itemSize;
            if (i && !NSEqualSizes(sizes[i], sizes[0]))
                uniform = NO;
        }
        if (n == 0) {
            /* nothing */
        } else if (uniform) {
            CGFloat a = vertical ? sizes[0].width : sizes[0].height, b = vertical ? sizes[0].height : sizes[0].width;
            NSInteger per = (NSInteger)floor((avail + is) / (a + is));
            if (per < 1)
                per = 1;
            if (per > n && n > 0 && 0)
                per = n;
            CGFloat gap = per > 1 ? (avail - per * a) / (per - 1) : 0;
            NSInteger lines = (n + per - 1) / per;
            for (NSInteger i = 0; i < n; i++) {
                NSInteger line = i / per, k = i % per;
                CGFloat across = sideA + k * (a + gap), along = pos + line * (b + ls);
                NSRect f = vertical ? NSMakeRect(across, along, sizes[i].width, sizes[i].height)
                                    : NSMakeRect(along, across, sizes[i].width, sizes[i].height);
                [_store addItem:[NSIndexPath indexPathForItem:i inSection:s] frame:f];
            }
            pos += lines * b + (lines - 1) * ls;
        } else {
            /* Apple's spaces items of different sizes the other way round when the flow is horizontal. */
            CGFloat within = vertical ? is : ls, between = vertical ? ls : is;
            NSInteger i = 0;
            BOOL firstLine = YES;
            while (i < n) {
                NSInteger first = i;
                CGFloat used = 0, thick = 0;
                NSMutableArray *line = [NSMutableArray array];
                while (i < n) {
                    CGFloat a = vertical ? sizes[i].width : sizes[i].height;
                    CGFloat need = [line count] ? used + within + a : a;
                    if ([line count] && need > avail + 1e-9)
                        break;
                    used = need;
                    thick = MAX(thick, vertical ? sizes[i].height : sizes[i].width);
                    [line addObject:@(i)];
                    i++;
                }
                if (!firstLine)
                    pos += between;
                firstLine = NO;
                BOOL last = i >= n;
                CGFloat sum = used - within * ([line count] - 1);
                CGFloat gap = !last && [line count] > 1 ? (avail - sum) / ([line count] - 1) : within;
                place_line(_store, s, line, sizes, first, sideA, pos, thick, gap, vertical);
                pos += thick;
            }
        }
        free(sizes);
        pos += after;
        CGFloat fAlong = vertical ? fs.height : fs.width;
        [_store addSupplementary:NSCollectionElementKindSectionFooter section:s
                           frame:supplementary_frame(vertical, pos, extent, fs)];
        pos += fAlong;
    }
    _store->_content = vertical ? NSMakeSize(extent, pos) : NSMakeSize(pos, extent);
}

- (NSSize)collectionViewContentSize
{
    [self _finchEnsurePrepared];
    return _store ? _store->_content : NSZeroSize;
}

- (NSArray *)layoutAttributesForElementsInRect:(NSRect)rect
{
    [self _finchEnsurePrepared];
    return [_store inRect:rect];
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath
{
    [self _finchEnsurePrepared];
    return [[[_store->_items objectForKey:indexPath] copy] autorelease];
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForSupplementaryViewOfKind:(NSString *)kind
                                                                     atIndexPath:(NSIndexPath *)indexPath
{
    [self _finchEnsurePrepared];
    NSIndexPath *p = [NSIndexPath indexPathForItem:0 inSection:[indexPath section]];
    NSDictionary *d = [kind isEqualToString:NSCollectionElementKindSectionHeader] ? _store->_headers
                      : [kind isEqualToString:NSCollectionElementKindSectionFooter] ? _store->_footers
                                                                                   : nil;
    return [[[d objectForKey:p] copy] autorelease];
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(NSRect)newBounds
{
    NSSize old = _store ? _store->_content : NSZeroSize;
    return _direction == NSCollectionViewScrollDirectionVertical ? newBounds.size.width != old.width
                                                                 : newBounds.size.height != old.height;
}

@end

#pragma mark - NSCollectionViewGridLayout

@implementation NSCollectionViewGridLayout {
    NSEdgeInsets _margins;
    CGFloat _interitemSpacing, _lineSpacing;
    NSUInteger _maxRows, _maxColumns;
    NSSize _minItemSize, _maxItemSize;
    NSArray *_backgroundColors;
    _FinchLayoutStore *_store;
}

- (void)dealloc
{
    [_backgroundColors release];
    [_store release];
    [super dealloc];
}

FLOW_PROPERTY(NSEdgeInsets, margins, setMargins:, _margins)
FLOW_PROPERTY(CGFloat, minimumInteritemSpacing, setMinimumInteritemSpacing:, _interitemSpacing)
FLOW_PROPERTY(CGFloat, minimumLineSpacing, setMinimumLineSpacing:, _lineSpacing)
FLOW_PROPERTY(NSUInteger, maximumNumberOfRows, setMaximumNumberOfRows:, _maxRows)
FLOW_PROPERTY(NSUInteger, maximumNumberOfColumns, setMaximumNumberOfColumns:, _maxColumns)
FLOW_PROPERTY(NSSize, minimumItemSize, setMinimumItemSize:, _minItemSize)
FLOW_PROPERTY(NSSize, maximumItemSize, setMaximumItemSize:, _maxItemSize)

- (NSArray<NSColor *> *)backgroundColors { return _backgroundColors ?: @[]; }

- (void)setBackgroundColors:(NSArray<NSColor *> *)colors
{
    [_backgroundColors autorelease];
    _backgroundColors = [colors copy];
}

static CGFloat
clamp_size(CGFloat v, CGFloat lo, CGFloat hi)
{
    if (hi > 0 && v > hi)
        v = hi;
    if (v < lo)
        v = lo;
    return v;
}

- (void)prepareLayout
{
    [_store release];
    _store = [[_FinchLayoutStore alloc] init];
    NSCollectionView *cv = [self collectionView];
    if (!cv)
        return;
    NSSize view = view_size(cv);
    NSEdgeInsets m = _margins;
    CGFloat ii = _interitemSpacing, ls = _lineSpacing;
    NSInteger count = 0, sections = [cv numberOfSections];
    for (NSInteger s = 0; s < sections; s++)
        count += [cv numberOfItemsInSection:s];
    CGFloat availW = view.width - m.left - m.right, availH = view.height - m.top - m.bottom;
    NSInteger rows, cols;
    CGFloat w, h, gapX, gapY;
    if (_maxRows > 0) {
        rows = (NSInteger)_maxRows;
        cols = MAX(1, (count + rows - 1) / rows);
        gapX = ls;
        gapY = ii;
    } else {
        CGFloat minW = MAX(1, _minItemSize.width);
        cols = (NSInteger)floor((availW + ii) / (minW + ii));
        if (_maxColumns > 0 && cols > (NSInteger)_maxColumns)
            cols = (NSInteger)_maxColumns;
        cols = MAX(1, cols);
        rows = MAX(1, (count + cols - 1) / cols);
        gapX = ii;
        gapY = ls;
    }
    w = clamp_size((availW - (cols - 1) * gapX) / cols, _minItemSize.width, _maxItemSize.width);
    h = clamp_size((availH - (rows - 1) * gapY) / rows, _minItemSize.height, _maxItemSize.height);
    NSInteger i = 0;
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger n = [cv numberOfItemsInSection:s];
        for (NSInteger k = 0; k < n; k++, i++) {
            NSInteger row = i / cols, col = i % cols;
            [_store addItem:[NSIndexPath indexPathForItem:k inSection:s]
                      frame:NSMakeRect(m.left + col * (w + gapX), m.top + row * (h + gapY), w, h)];
        }
    }
    NSInteger usedRows = count ? (count + cols - 1) / cols : 0;
    NSInteger usedCols = MIN(cols, count);
    _store->_content = NSMakeSize(m.left + usedCols * w + MAX(0, usedCols - 1) * gapX + m.right,
                                  m.top + usedRows * h + MAX(0, usedRows - 1) * gapY + m.bottom);
}

- (NSSize)collectionViewContentSize
{
    [self _finchEnsurePrepared];
    return _store ? _store->_content : NSZeroSize;
}

- (NSArray *)layoutAttributesForElementsInRect:(NSRect)rect
{
    [self _finchEnsurePrepared];
    return [_store inRect:rect];
}

- (NSCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath
{
    [self _finchEnsurePrepared];
    return [[[_store->_items objectForKey:indexPath] copy] autorelease];
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(NSRect)newBounds { return YES; }

@end

#pragma mark - Transitions

@implementation NSCollectionViewTransitionLayout {
    NSCollectionViewLayout *_current, *_next;
    CGFloat _progress;
}
- (instancetype)initWithCurrentLayout:(NSCollectionViewLayout *)current nextLayout:(NSCollectionViewLayout *)next
{
    if ((self = [super init])) {
        _current = [current retain];
        _next = [next retain];
    }
    return self;
}
- (void)dealloc
{
    [_current release];
    [_next release];
    [super dealloc];
}
- (NSCollectionViewLayout *)currentLayout { return _current; }
- (NSCollectionViewLayout *)nextLayout { return _next; }
- (CGFloat)transitionProgress { return _progress; }
- (void)setTransitionProgress:(CGFloat)p { _progress = p; }
- (void)updateValue:(CGFloat)value forAnimatedKey:(NSCollectionViewTransitionLayoutAnimatedKey)key {}
- (CGFloat)valueForAnimatedKey:(NSCollectionViewTransitionLayoutAnimatedKey)key { return 0; }
- (NSSize)collectionViewContentSize { return _progress < 0.5 ? [_current collectionViewContentSize] : [_next collectionViewContentSize]; }
- (NSArray *)layoutAttributesForElementsInRect:(NSRect)r
{
    return [(_progress < 0.5 ? _current : _next) layoutAttributesForElementsInRect:r];
}
- (NSCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)p
{
    return [(_progress < 0.5 ? _current : _next) layoutAttributesForItemAtIndexPath:p];
}
@end
