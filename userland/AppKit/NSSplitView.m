/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSplitView, NSSplitViewItem and NSSplitViewController. Subviews share
 * the split view's length along its axis, separated by dividers: thick
 * (9 points) by default, thin (1) or pane splitters (10). Adjusting shares
 * the space out in proportion to the subviews' sizes, to the half point,
 * with the last subview taking what is left, as Apple's does. Dividers are
 * dragged with the mouse; the delegate constrains them as on macOS.
 */
#import "NSView_Finch.h"

NSNotificationName NSSplitViewWillResizeSubviewsNotification = @"NSSplitViewWillResizeSubviewsNotification";
NSNotificationName NSSplitViewDidResizeSubviewsNotification = @"NSSplitViewDidResizeSubviewsNotification";
const CGFloat NSSplitViewControllerAutomaticDimension = -1;
const CGFloat NSSplitViewItemUnspecifiedDimension = -1;

@implementation NSSplitView {
    BOOL _vertical, _arrangesAll;
    NSSplitViewDividerStyle _style;
    NSString *_autosaveName;
    id<NSSplitViewDelegate> _delegate;  /* not retained */
    NSMutableArray<NSView *> *_arranged;
    NSMutableDictionary<NSNumber *, NSNumber *> *_holding;
    NSInteger _dragging;  /* the divider being dragged, or -1 */
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _style = NSSplitViewDividerStyleThick;
        _arrangesAll = YES;
        _arranged = [[NSMutableArray alloc] init];
        _holding = [[NSMutableDictionary alloc] init];
        _dragging = -1;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        _vertical = [coder decodeBoolForKey:@"NSIsVertical"];
        _style = [coder containsValueForKey:@"NSDividerStyle"] ? [coder decodeIntegerForKey:@"NSDividerStyle"]
                                                                : NSSplitViewDividerStyleThick;
        _autosaveName = [[coder decodeObjectForKey:@"NSAutosaveName"] copy];
        _arrangesAll = YES;
        _arranged = [[NSMutableArray alloc] initWithArray:[self subviews]];
        _holding = [[NSMutableDictionary alloc] init];
        _dragging = -1;
    }
    return self;
}

- (void)dealloc
{
    [_autosaveName release];
    [_arranged release];
    [_holding release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isVertical { return _vertical; }
- (void)setVertical:(BOOL)flag { _vertical = flag; [self setNeedsDisplay:YES]; }
- (NSSplitViewDividerStyle)dividerStyle { return _style; }
- (void)setDividerStyle:(NSSplitViewDividerStyle)style { _style = style; [self setNeedsDisplay:YES]; }
- (NSSplitViewAutosaveName)autosaveName { return _autosaveName; }
- (void)setAutosaveName:(NSSplitViewAutosaveName)name { [_autosaveName autorelease]; _autosaveName = [name copy]; }
- (id<NSSplitViewDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSSplitViewDelegate>)delegate { _delegate = delegate; }
- (BOOL)arrangesAllSubviews { return _arrangesAll; }
- (void)setArrangesAllSubviews:(BOOL)flag { _arrangesAll = flag; }
- (NSArray<NSView *> *)arrangedSubviews { return _arrangesAll ? [self subviews] : [[_arranged copy] autorelease]; }

- (CGFloat)dividerThickness
{
    switch (_style) {
    case NSSplitViewDividerStyleThin: return 1;
    case NSSplitViewDividerStylePaneSplitter: return 10;
    default: return 9;
    }
}

- (NSColor *)dividerColor
{
    return [NSColor separatorColor];
}

- (void)addArrangedSubview:(NSView *)view
{
    [self insertArrangedSubview:view atIndex:(NSInteger)[_arranged count]];
}

- (void)insertArrangedSubview:(NSView *)view atIndex:(NSInteger)index
{
    if ([view superview] != self)
        [self addSubview:view];
    [_arranged removeObjectIdenticalTo:view];
    [_arranged insertObject:view atIndex:(NSUInteger)MIN(index, (NSInteger)[_arranged count])];
}

- (void)removeArrangedSubview:(NSView *)view
{
    [_arranged removeObjectIdenticalTo:view];
}

- (void)didAddSubview:(NSView *)subview
{
    [super didAddSubview:subview];
    if (_arrangesAll && [_arranged indexOfObjectIdenticalTo:subview] == NSNotFound)
        [_arranged addObject:subview];
}

- (void)willRemoveSubview:(NSView *)subview
{
    [_arranged removeObjectIdenticalTo:subview];
    [super willRemoveSubview:subview];
}

static CGFloat length_of(NSSplitView *s, NSRect r) { return s->_vertical ? r.size.width : r.size.height; }
static CGFloat start_of(NSSplitView *s, NSRect r) { return s->_vertical ? NSMinX(r) : NSMinY(r); }

static NSRect
along(NSSplitView *s, CGFloat start, CGFloat length)
{
    NSRect b = [s bounds];
    return s->_vertical ? NSMakeRect(start, NSMinY(b), length, b.size.height)
                        : NSMakeRect(NSMinX(b), start, b.size.width, length);
}

static CGFloat
half(CGFloat v)
{
    return floor(v * 2 + 0.5) / 2;
}

/* Share the length out in proportion to the subviews' current sizes, to the half point. */
- (void)adjustSubviews
{
    NSArray<NSView *> *views = [self arrangedSubviews];
    NSUInteger n = [views count];
    if (!n)
        return;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewWillResizeSubviewsNotification object:self];
    CGFloat available = length_of(self, [self bounds]) - [self dividerThickness] * (n - 1);
    CGFloat total = 0;
    for (NSView *v in views)
        total += [self isSubviewCollapsed:v] ? 0 : length_of(self, [v frame]);
    CGFloat pos = start_of(self, [self bounds]);
    for (NSUInteger i = 0; i < n; i++) {
        NSView *v = views[i];
        CGFloat len;
        if (i == n - 1)
            len = MAX(0, start_of(self, [self bounds]) + length_of(self, [self bounds]) - pos);
        else if (total > 0)
            len = MAX(0, half(length_of(self, [v frame]) * available / total));
        else
            len = half(available / n);
        [v setFrame:along(self, pos, len)];
        pos += len + [self dividerThickness];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewDidResizeSubviewsNotification object:self];
    [self setNeedsDisplay:YES];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    if ([(id)_delegate respondsToSelector:@selector(splitView:resizeSubviewsWithOldSize:)])
        [_delegate splitView:self resizeSubviewsWithOldSize:oldSize];
    else
        [self adjustSubviews];
}

- (BOOL)isSubviewCollapsed:(NSView *)subview
{
    return [subview isHidden];
}

- (CGFloat)minPossiblePositionOfDividerAtIndex:(NSInteger)i
{
    NSArray *views = [self arrangedSubviews];
    if (i < 0 || (NSUInteger)i >= [views count])
        return 0;
    return start_of(self, [views[(NSUInteger)i] frame]) - (i > 0 ? 0 : 0);
}

- (CGFloat)maxPossiblePositionOfDividerAtIndex:(NSInteger)i
{
    NSArray *views = [self arrangedSubviews];
    if (i < 0 || (NSUInteger)i + 1 >= [views count])
        return 0;
    NSView *next = views[(NSUInteger)i + 1];
    return start_of(self, [next frame]) + length_of(self, [next frame]) - [self dividerThickness];
}

/* Move a divider: the views on either side give and take, within their neighbours. */
- (void)setPosition:(CGFloat)position ofDividerAtIndex:(NSInteger)i
{
    NSArray *views = [self arrangedSubviews];
    if (i < 0 || (NSUInteger)i + 1 >= [views count])
        return;
    CGFloat lo = [self minPossiblePositionOfDividerAtIndex:i], hi = [self maxPossiblePositionOfDividerAtIndex:i];
    if ([(id)_delegate respondsToSelector:@selector(splitView:constrainSplitPosition:ofSubviewAt:)])
        position = [_delegate splitView:self constrainSplitPosition:position ofSubviewAt:i];
    if ([(id)_delegate respondsToSelector:@selector(splitView:constrainMinCoordinate:ofSubviewAt:)])
        lo = MAX(lo, [_delegate splitView:self constrainMinCoordinate:lo ofSubviewAt:i]);
    if ([(id)_delegate respondsToSelector:@selector(splitView:constrainMaxCoordinate:ofSubviewAt:)])
        hi = MIN(hi, [_delegate splitView:self constrainMaxCoordinate:hi ofSubviewAt:i]);
    position = MAX(lo, MIN(hi, position));
    NSView *a = views[(NSUInteger)i], *b = views[(NSUInteger)i + 1];
    CGFloat aStart = start_of(self, [a frame]);
    CGFloat bEnd = start_of(self, [b frame]) + length_of(self, [b frame]);
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewWillResizeSubviewsNotification object:self];
    [a setFrame:along(self, aStart, position - aStart)];
    CGFloat bStart = position + [self dividerThickness];
    [b setFrame:along(self, bStart, MAX(0, bEnd - bStart))];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewDidResizeSubviewsNotification object:self];
    [self setNeedsDisplay:YES];
}

- (NSLayoutPriority)holdingPriorityForSubviewAtIndex:(NSInteger)i
{
    NSNumber *p = _holding[@(i)];
    return p ? [p floatValue] : NSLayoutPriorityDefaultLow;
}

- (void)setHoldingPriority:(NSLayoutPriority)priority forSubviewAtIndex:(NSInteger)i
{
    _holding[@(i)] = @(priority);
}

- (NSRect)_finchDividerRect:(NSUInteger)i
{
    NSView *v = [self arrangedSubviews][i];
    CGFloat end = start_of(self, [v frame]) + length_of(self, [v frame]);
    return along(self, end, [self dividerThickness]);
}

- (void)drawDividerInRect:(NSRect)rect
{
    [[self dividerColor] setFill];
    if (_style == NSSplitViewDividerStyleThin) {
        NSRectFill(rect);
        return;
    }
    /* Finch's divider: a hairline centred in the gap */
    NSRect line = _vertical ? NSMakeRect(NSMidX(rect) - 0.5, NSMinY(rect), 1, rect.size.height)
                            : NSMakeRect(NSMinX(rect), NSMidY(rect) - 0.5, rect.size.width, 1);
    NSRectFill(line);
}

- (void)drawRect:(NSRect)dirty
{
    NSArray *views = [self arrangedSubviews];
    for (NSUInteger i = 0; i + 1 < [views count]; i++) {
        NSRect r = [self _finchDividerRect:i];
        if (NSIntersectsRect(r, dirty))
            [self drawDividerInRect:r];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSArray *views = [self arrangedSubviews];
    _dragging = -1;
    for (NSUInteger i = 0; i + 1 < [views count]; i++)
        if (NSMouseInRect(p, NSInsetRect([self _finchDividerRect:i], _vertical ? -2 : 0, _vertical ? 0 : -2), YES))
            _dragging = (NSInteger)i;
    if (_dragging < 0) {
        [super mouseDown:event];
        return;
    }
    CGFloat offset = (_vertical ? p.x : p.y) - start_of(self, [self _finchDividerRect:(NSUInteger)_dragging]);
    NSEvent *e;
    while ((e = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp])) {
        NSPoint q = [self convertPoint:[e locationInWindow] fromView:nil];
        [self setPosition:(_vertical ? q.x : q.y) - offset ofDividerAtIndex:_dragging];
        if ([e type] == NSEventTypeLeftMouseUp)
            break;
    }
    _dragging = -1;
}

@end

#pragma mark - NSSplitViewItem and NSSplitViewController

@implementation NSSplitViewItem {
    NSViewController *_viewController;
    BOOL _collapsed, _canCollapse;
    NSSplitViewItemBehavior _behavior;
    NSLayoutPriority _holding;
    CGFloat _minimumThickness, _maximumThickness, _preferredFraction;
}

+ (instancetype)splitViewItemWithViewController:(NSViewController *)viewController
{
    NSSplitViewItem *item = [[[self alloc] init] autorelease];
    item->_viewController = [viewController retain];
    item->_holding = NSLayoutPriorityDefaultLow;
    item->_minimumThickness = NSSplitViewItemUnspecifiedDimension;
    item->_maximumThickness = NSSplitViewItemUnspecifiedDimension;
    item->_preferredFraction = NSSplitViewItemUnspecifiedDimension;
    return item;
}

+ (instancetype)sidebarWithViewController:(NSViewController *)viewController
{
    NSSplitViewItem *item = [self splitViewItemWithViewController:viewController];
    item->_behavior = NSSplitViewItemBehaviorSidebar;
    item->_canCollapse = YES;
    item->_holding = 260;
    return item;
}

+ (instancetype)contentListWithViewController:(NSViewController *)viewController
{
    NSSplitViewItem *item = [self splitViewItemWithViewController:viewController];
    item->_behavior = NSSplitViewItemBehaviorContentList;
    return item;
}

+ (instancetype)inspectorWithViewController:(NSViewController *)viewController
{
    NSSplitViewItem *item = [self splitViewItemWithViewController:viewController];
    item->_behavior = NSSplitViewItemBehaviorInspector;
    item->_canCollapse = YES;
    return item;
}

- (void)dealloc
{
    [_viewController release];
    [super dealloc];
}

- (NSViewController *)viewController { return _viewController; }
- (void)setViewController:(NSViewController *)c { [_viewController autorelease]; _viewController = [c retain]; }
- (NSSplitViewItemBehavior)behavior { return _behavior; }
- (BOOL)isCollapsed { return _collapsed; }
- (void)setCollapsed:(BOOL)flag
{
    _collapsed = flag;
    [[_viewController view] setHidden:flag];
}
- (BOOL)canCollapse { return _canCollapse; }
- (void)setCanCollapse:(BOOL)flag { _canCollapse = flag; }
- (NSLayoutPriority)holdingPriority { return _holding; }
- (void)setHoldingPriority:(NSLayoutPriority)p { _holding = p; }
- (CGFloat)minimumThickness { return _minimumThickness; }
- (void)setMinimumThickness:(CGFloat)v { _minimumThickness = v; }
- (CGFloat)maximumThickness { return _maximumThickness; }
- (void)setMaximumThickness:(CGFloat)v { _maximumThickness = v; }
- (CGFloat)preferredThicknessFraction { return _preferredFraction; }
- (void)setPreferredThicknessFraction:(CGFloat)v { _preferredFraction = v; }

/* From a nib or storyboard: Apple's keys, each present only when not the behavior's default. */
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSplitViewItemBehavior behavior = [coder decodeIntegerForKey:@"NSSplitViewItemBehavior"];
    NSViewController *vc = [coder decodeObjectForKey:@"NSSplitViewItemViewController"];
    NSSplitViewItem *made = behavior == NSSplitViewItemBehaviorSidebar ? [NSSplitViewItem sidebarWithViewController:vc]
                            : behavior == NSSplitViewItemBehaviorContentList
                                ? [NSSplitViewItem contentListWithViewController:vc]
                            : behavior == NSSplitViewItemBehaviorInspector ? [NSSplitViewItem inspectorWithViewController:vc]
                                                                           : [NSSplitViewItem splitViewItemWithViewController:vc];
    [self release];
    self = [made retain];
#define DECODE(key, ivar, how) \
    if ([coder containsValueForKey:@"NSSplitViewItem" key]) \
        ivar = [coder how:@"NSSplitViewItem" key];
    DECODE("HoldingCollapsed", _collapsed, decodeBoolForKey)
    DECODE("CanCollapseFromDrag", _canCollapse, decodeBoolForKey)
    DECODE("HoldingPriority", _holding, decodeFloatForKey)
    DECODE("MinimumThickness", _minimumThickness, decodeDoubleForKey)
    DECODE("MaximumThickness", _maximumThickness, decodeDoubleForKey)
    DECODE("PreferredThicknessFraction", _preferredFraction, decodeDoubleForKey)
#undef DECODE
    return self;
}

@end

@implementation NSSplitViewController {
    NSSplitView *_splitView;
    NSMutableArray<NSSplitViewItem *> *_items;
    CGFloat _minimumThicknessForInlineSidebars;
}

- (instancetype)initWithNibName:(NSNibName)name bundle:(NSBundle *)bundle
{
    self = [super initWithNibName:name bundle:bundle];
    if (self)
        _items = [[NSMutableArray alloc] init];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        _items = [[NSMutableArray alloc] initWithArray:[coder decodeObjectForKey:@"NSSplitViewItems"] ?: @[]];
        NSSplitView *sv = [coder decodeObjectForKey:@"NSSplitView"];
        if (sv)
            [self setSplitView:sv];
    }
    return self;
}

- (void)dealloc
{
    [_splitView release];
    [_items release];
    [super dealloc];
}

- (NSSplitView *)splitView
{
    if (!_splitView) {
        NSSplitView *sv = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        [sv setVertical:YES];
        [sv setDividerStyle:NSSplitViewDividerStyleThin];
        [self setSplitView:sv];
        [sv release];
    }
    return _splitView;
}

- (void)setSplitView:(NSSplitView *)sv
{
    [_splitView autorelease];
    _splitView = [sv retain];
    [sv setDelegate:self];
}

- (void)loadView
{
    NSSplitView *sv = [self splitView];
    for (NSSplitViewItem *item in _items)
        [sv addArrangedSubview:[[item viewController] view]];
    [self setView:sv];
    [sv adjustSubviews];
}

- (void)viewDidLoad {}

- (NSArray<NSSplitViewItem *> *)splitViewItems { return [[_items copy] autorelease]; }

- (void)setSplitViewItems:(NSArray<NSSplitViewItem *> *)items
{
    for (NSSplitViewItem *i in [self splitViewItems])
        [self removeSplitViewItem:i];
    for (NSSplitViewItem *i in items)
        [self addSplitViewItem:i];
}

- (void)addSplitViewItem:(NSSplitViewItem *)item
{
    [self insertSplitViewItem:item atIndex:(NSInteger)[_items count]];
}

- (void)insertSplitViewItem:(NSSplitViewItem *)item atIndex:(NSInteger)index
{
    [_items insertObject:item atIndex:(NSUInteger)index];
    [self addChildViewController:[item viewController]];
    if ([self isViewLoaded]) {
        [_splitView insertArrangedSubview:[[item viewController] view] atIndex:index];
        [_splitView adjustSubviews];
    }
}

- (void)removeSplitViewItem:(NSSplitViewItem *)item
{
    if ([self isViewLoaded])
        [[[item viewController] view] removeFromSuperview];
    [[item viewController] removeFromParentViewController];
    [_items removeObjectIdenticalTo:item];
}

- (NSSplitViewItem *)splitViewItemForViewController:(NSViewController *)viewController
{
    for (NSSplitViewItem *i in _items)
        if ([i viewController] == viewController)
            return i;
    return nil;
}

- (CGFloat)minimumThicknessForInlineSidebars { return _minimumThicknessForInlineSidebars; }
- (void)setMinimumThicknessForInlineSidebars:(CGFloat)v { _minimumThicknessForInlineSidebars = v; }

- (IBAction)toggleSidebar:(id)sender
{
    for (NSSplitViewItem *i in _items)
        if ([i behavior] == NSSplitViewItemBehaviorSidebar) {
            [i setCollapsed:![i isCollapsed]];
            [_splitView adjustSubviews];
            return;
        }
}

- (IBAction)toggleInspector:(id)sender
{
    for (NSSplitViewItem *i in _items)
        if ([i behavior] == NSSplitViewItemBehaviorInspector) {
            [i setCollapsed:![i isCollapsed]];
            [_splitView adjustSubviews];
            return;
        }
}

- (BOOL)splitView:(NSSplitView *)splitView canCollapseSubview:(NSView *)subview
{
    for (NSSplitViewItem *i in _items)
        if ([[i viewController] view] == subview)
            return [i canCollapse];
    return NO;
}

- (BOOL)splitView:(NSSplitView *)splitView shouldHideDividerAtIndex:(NSInteger)dividerIndex
{
    return NO;
}

- (NSRect)splitView:(NSSplitView *)splitView effectiveRect:(NSRect)proposedEffectiveRect
       forDrawnRect:(NSRect)drawnRect ofDividerAtIndex:(NSInteger)dividerIndex
{
    return proposedEffectiveRect;
}

- (NSRect)splitView:(NSSplitView *)splitView additionalEffectiveRectOfDividerAtIndex:(NSInteger)dividerIndex
{
    return NSZeroRect;
}

@end
