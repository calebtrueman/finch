/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSStackView: views in a row or a column, laid out by constraints the
 * stack makes and installs on itself, as Apple's does (the recipe,
 * identifiers and priorities measured on macOS 26.4):
 *
 * - across: each view aligned at priority 260 ('NSStackView.Align'), kept
 *   inside the stack (required 'Edge.Top'/'Edge.Bottom', >= 0) and hugged
 *   by it at the stack's hugging priority ('Edge.Min.*', the insets);
 * - along, by distribution: the gravity areas pack each gravity's views
 *   from its edge (the first at 750, spacing at 749.99, 749.98, ..., at
 *   least the spacing between, the center gravity centred at 260); fill
 *   distributions chain the views edge to edge (required), the equal ones
 *   tying sizes, proportions, gaps or centres to a shared dimension
 *   ('NSStackView.Distribution.Ideal') at 260.
 *
 * Hidden views drop out when detachesHiddenViews is set. The constraints
 * are remade in -updateConstraints whenever the views or settings change.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"

@interface _FinchStackIdealGuide : NSLayoutGuide
@end

@implementation _FinchStackIdealGuide
@end

/* What nibs hold for each gravity. */
@interface NSStackViewContainer : NSView
@end

@implementation NSStackViewContainer {
  @public
    NSArray *_views;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self)
        _views = [[coder decodeObjectForKey:@"NSStackViewContainerNonDroppedViews"] copy];
    return self;
}

- (void)dealloc
{
    [_views release];
    [super dealloc];
}

@end


@implementation NSStackView {
    NSMutableArray<NSView *> *_arranged;
    NSMapTable<NSView *, NSNumber *> *_gravity;
    NSMapTable<NSView *, NSNumber *> *_customSpacing;
    NSMapTable<NSView *, NSNumber *> *_visibility;
    NSMutableArray<NSLayoutConstraint *> *_made;
    NSUserInterfaceLayoutOrientation _orientation;
    NSLayoutAttribute _alignment;
    NSStackViewDistribution _distribution;
    CGFloat _spacing;
    NSEdgeInsets _edgeInsets;
    NSLayoutPriority _hugging[2], _clipping[2];
    BOOL _detaches;
    id<NSStackViewDelegate> _delegate;  /* not retained */
    _FinchStackIdealGuide *_ideal;
    NSArray *_builtFor;  /* the visible views the constraints were made for */
}

+ (BOOL)requiresConstraintBasedLayout { return YES; }

static void
setup(NSStackView *self)
{
    self->_arranged = [[NSMutableArray alloc] init];
    self->_gravity = [[NSMapTable strongToStrongObjectsMapTable] retain];
    self->_customSpacing = [[NSMapTable strongToStrongObjectsMapTable] retain];
    self->_visibility = [[NSMapTable strongToStrongObjectsMapTable] retain];
    self->_made = [[NSMutableArray alloc] init];
    self->_orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self->_alignment = NSLayoutAttributeCenterY;
    self->_distribution = NSStackViewDistributionGravityAreas;
    self->_spacing = 8;
    self->_hugging[0] = self->_hugging[1] = 249.99998474121094f;  /* just under the views' own hugging, as Apple's */
    self->_clipping[0] = self->_clipping[1] = NSLayoutPriorityRequired;
    self->_detaches = YES;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
        setup(self);
    return self;
}

+ (instancetype)stackViewWithViews:(NSArray<NSView *> *)views
{
    NSStackView *s = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [s setTranslatesAutoresizingMaskIntoConstraints:NO];
    for (NSView *v in views)
        [s addArrangedSubview:v];
    return s;
}

- (void)dealloc
{
    [_arranged release];
    [_gravity release];
    [_customSpacing release];
    [_visibility release];
    [_made release];
    [_ideal release];
    [_builtFor release];
    [super dealloc];
}

- (BOOL)isFlipped { return NO; }

static void
changed(NSStackView *self)
{
    [self setNeedsUpdateConstraints:YES];
    [self invalidateIntrinsicContentSize];
}

#pragma mark - Properties

- (NSUserInterfaceLayoutOrientation)orientation { return _orientation; }
- (void)setOrientation:(NSUserInterfaceLayoutOrientation)o
{
    if (o == _orientation)
        return;
    /* the default alignment follows: centred across */
    if (o == NSUserInterfaceLayoutOrientationVertical && _alignment == NSLayoutAttributeCenterY)
        _alignment = NSLayoutAttributeCenterX;
    else if (o == NSUserInterfaceLayoutOrientationHorizontal && _alignment == NSLayoutAttributeCenterX)
        _alignment = NSLayoutAttributeCenterY;
    _orientation = o;
    changed(self);
}
- (NSLayoutAttribute)alignment { return _alignment; }
- (void)setAlignment:(NSLayoutAttribute)a { _alignment = a; changed(self); }
- (NSStackViewDistribution)distribution { return _distribution; }
- (void)setDistribution:(NSStackViewDistribution)d { _distribution = d; changed(self); }
- (CGFloat)spacing { return _spacing; }
- (void)setSpacing:(CGFloat)s { _spacing = s; changed(self); }
- (NSEdgeInsets)edgeInsets { return _edgeInsets; }
- (void)setEdgeInsets:(NSEdgeInsets)e { _edgeInsets = e; changed(self); }
- (BOOL)detachesHiddenViews { return _detaches; }
- (void)setDetachesHiddenViews:(BOOL)d { _detaches = d; changed(self); }
- (id<NSStackViewDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSStackViewDelegate>)d { _delegate = d; }
- (BOOL)hasEqualSpacing { return _distribution == NSStackViewDistributionEqualSpacing; }
- (void)setHasEqualSpacing:(BOOL)e { [self setDistribution:e ? NSStackViewDistributionEqualSpacing : NSStackViewDistributionGravityAreas]; }

- (NSLayoutPriority)huggingPriorityForOrientation:(NSLayoutConstraintOrientation)o { return _hugging[o ? 1 : 0]; }
- (void)setHuggingPriority:(NSLayoutPriority)p forOrientation:(NSLayoutConstraintOrientation)o { _hugging[o ? 1 : 0] = p; changed(self); }
- (NSLayoutPriority)clippingResistancePriorityForOrientation:(NSLayoutConstraintOrientation)o { return _clipping[o ? 1 : 0]; }
- (void)setClippingResistancePriority:(NSLayoutPriority)p forOrientation:(NSLayoutConstraintOrientation)o { _clipping[o ? 1 : 0] = p; changed(self); }

- (void)setCustomSpacing:(CGFloat)spacing afterView:(NSView *)view
{
    if (spacing == NSStackViewSpacingUseDefault)
        [_customSpacing removeObjectForKey:view];
    else
        [_customSpacing setObject:@(spacing) forKey:view];
    changed(self);
}

- (CGFloat)customSpacingAfterView:(NSView *)view
{
    NSNumber *n = [_customSpacing objectForKey:view];
    return n ? [n doubleValue] : NSStackViewSpacingUseDefault;
}

- (void)setVisibilityPriority:(NSStackViewVisibilityPriority)p forView:(NSView *)view
{
    [_visibility setObject:@(p) forKey:view];
    changed(self);
}

- (NSStackViewVisibilityPriority)visibilityPriorityForView:(NSView *)view
{
    NSNumber *n = [_visibility objectForKey:view];
    return n ? [n floatValue] : NSStackViewVisibilityPriorityMustHold;
}

#pragma mark - Views

static NSStackViewGravity
gravity_of(NSStackView *self, NSView *v)
{
    NSNumber *n = [self->_gravity objectForKey:v];
    return n ? (NSStackViewGravity)[n integerValue] : NSStackViewGravityLeading;
}

/* The arranged views, by gravity. */
- (NSArray<NSView *> *)views
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSStackViewGravity g = NSStackViewGravityLeading; g <= NSStackViewGravityTrailing; g++)
        for (NSView *v in _arranged)
            if (gravity_of(self, v) == g)
                [a addObject:v];
    return a;
}

- (NSArray<NSView *> *)arrangedSubviews { return [self views]; }

- (NSArray<NSView *> *)viewsInGravity:(NSStackViewGravity)gravity
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSView *v in _arranged)
        if (gravity_of(self, v) == gravity)
            [a addObject:v];
    return a;
}

- (NSArray<NSView *> *)detachedViews
{
    NSMutableArray *a = [NSMutableArray array];
    if (_detaches)
        for (NSView *v in [self views])
            if ([v isHidden])
                [a addObject:v];
    return a;
}

- (void)insertView:(NSView *)view atIndex:(NSUInteger)index inGravity:(NSStackViewGravity)gravity
{
    if (!view)
        return;
    [view retain];
    [_arranged removeObjectIdenticalTo:view];
    /* the index counts within the gravity */
    NSArray *in = [self viewsInGravity:gravity];
    NSUInteger at = [_arranged count];
    if (index < [in count])
        at = [_arranged indexOfObjectIdenticalTo:in[index]];
    else if ([in count])
        at = [_arranged indexOfObjectIdenticalTo:[in lastObject]] + 1;
    [_arranged insertObject:view atIndex:at];
    [_gravity setObject:@(gravity) forKey:view];
    [view setTranslatesAutoresizingMaskIntoConstraints:NO];
    if ([view superview] != self)
        [self addSubview:view];
    [view release];
    changed(self);
}

- (void)addView:(NSView *)view inGravity:(NSStackViewGravity)gravity
{
    [self insertView:view atIndex:[[self viewsInGravity:gravity] count] inGravity:gravity];
}

- (void)setViews:(NSArray<NSView *> *)views inGravity:(NSStackViewGravity)gravity
{
    for (NSView *v in [self viewsInGravity:gravity])
        if ([views indexOfObjectIdenticalTo:v] == NSNotFound)
            [self removeView:v];
    for (NSView *v in views)
        [self addView:v inGravity:gravity];
}

- (void)setViews:(NSArray<NSView *> *)views
{
    for (NSView *v in [self views])
        [self removeView:v];
    for (NSView *v in views)
        [self addView:v inGravity:NSStackViewGravityLeading];
}

- (void)removeView:(NSView *)view
{
    [self removeArrangedSubview:view];
    [view removeFromSuperview];
}

- (void)addArrangedSubview:(NSView *)view
{
    [self insertArrangedSubview:view atIndex:(NSInteger)[_arranged count]];
}

- (void)insertArrangedSubview:(NSView *)view atIndex:(NSInteger)index
{
    if (!view)
        return;
    [view retain];
    [_arranged removeObjectIdenticalTo:view];
    [_arranged insertObject:view atIndex:MIN((NSUInteger)index, [_arranged count])];
    if (![_gravity objectForKey:view])
        [_gravity setObject:@(NSStackViewGravityLeading) forKey:view];
    [view setTranslatesAutoresizingMaskIntoConstraints:NO];
    if ([view superview] != self)
        [self addSubview:view];
    [view release];
    changed(self);
}

- (void)removeArrangedSubview:(NSView *)view
{
    if ([_arranged indexOfObjectIdenticalTo:view] == NSNotFound)
        return;
    [_arranged removeObjectIdenticalTo:view];
    [_gravity removeObjectForKey:view];
    [_customSpacing removeObjectForKey:view];
    changed(self);
}

- (void)willRemoveSubview:(NSView *)subview
{
    [self removeArrangedSubview:subview];
    [super willRemoveSubview:subview];
}

#pragma mark - Constraints

- (NSArray *)_finchVisibleViews
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSView *v in [self views])
        if (!(_detaches && [v isHidden]))
            [a addObject:v];
    return a;
}

/* Called by the layout pass: hidden views coming and going change the constraints. */
- (void)_finchLayoutRefresh
{
    if (![[self _finchVisibleViews] isEqualToArray:_builtFor ?: @[]])
        [self setNeedsUpdateConstraints:YES];
}

static NSLayoutConstraint *
made(NSStackView *self, NSLayoutConstraint *c, NSString *ident, NSLayoutPriority p)
{
    [c setIdentifier:ident];
    if (p < NSLayoutPriorityRequired)
        [c setPriority:p];
    [self->_made addObject:c];
    return c;
}

- (void)updateConstraints
{
    if ([_made count]) {
        [self removeConstraints:_made];
        [_made removeAllObjects];
    }
    NSArray *views = [self _finchVisibleViews];
    [_builtFor release];
    _builtFor = [views copy];
    BOOL vertical = _orientation == NSUserInterfaceLayoutOrientationVertical;
    NSEdgeInsets in = _edgeInsets;
    CGFloat leadInset = vertical ? in.top : in.left, trailInset = vertical ? in.bottom : in.right;
    CGFloat crossMinInset = vertical ? in.left : in.top, crossMaxInset = vertical ? in.right : in.bottom;
    NSLayoutPriority hugAlong = _hugging[vertical ? 1 : 0], hugAcross = _hugging[vertical ? 0 : 1];

    /* anchors along and across the stack */
    id (^lead)(id) = ^id(id v) { return vertical ? (id)[v topAnchor] : (id)[v leadingAnchor]; };
    id (^trail)(id) = ^id(id v) { return vertical ? (id)[v bottomAnchor] : (id)[v trailingAnchor]; };
    id (^cmin)(id) = ^id(id v) { return vertical ? (id)[v leadingAnchor] : (id)[v topAnchor]; };
    id (^cmax)(id) = ^id(id v) { return vertical ? (id)[v trailingAnchor] : (id)[v bottomAnchor]; };
    NSLayoutDimension * (^size)(id) = ^NSLayoutDimension *(id v) { return vertical ? [v heightAnchor] : [v widthAnchor]; };
    NSString *Lead = vertical ? @"Top" : @"Leading", *Trail = vertical ? @"Bottom" : @"Trailing";
    NSString *CMin = vertical ? @"Leading" : @"Top", *CMax = vertical ? @"Trailing" : @"Bottom";

    /* across */
    for (NSView *v in views) {
        NSLayoutConstraint *align = nil;
        switch ((NSInteger)_alignment) {
        case NSLayoutAttributeCenterX:
        case NSLayoutAttributeCenterY:
            align = vertical ? [[v centerXAnchor] constraintEqualToAnchor:[self centerXAnchor]]
                             : [[v centerYAnchor] constraintEqualToAnchor:[self centerYAnchor]];
            break;
        case NSLayoutAttributeTop:
        case NSLayoutAttributeLeading:
        case NSLayoutAttributeLeft:
            align = [(id)cmin(v) constraintEqualToAnchor:cmin(self) constant:crossMinInset];
            break;
        case NSLayoutAttributeBottom:
        case NSLayoutAttributeTrailing:
        case NSLayoutAttributeRight:
            /* as Apple's: the inset added, not taken away */
            align = [(id)cmax(v) constraintEqualToAnchor:cmax(self) constant:crossMaxInset];
            break;
        case NSLayoutAttributeFirstBaseline:
        case NSLayoutAttributeLastBaseline:
            if (!vertical)
                align = [(id)[v performSelector:_alignment == NSLayoutAttributeFirstBaseline ? @selector(firstBaselineAnchor)
                                                                                                : @selector(lastBaselineAnchor)]
                    constraintEqualToAnchor:[self performSelector:_alignment == NSLayoutAttributeFirstBaseline
                                                                      ? @selector(firstBaselineAnchor)
                                                                      : @selector(lastBaselineAnchor)]];
            break;
        default:
            break;
        }
        if (align)
            made(self, align, @"NSStackView.Align", 260);
        made(self, [(id)cmin(v) constraintGreaterThanOrEqualToAnchor:cmin(self)], [@"NSStackView.Edge." stringByAppendingString:CMin], NSLayoutPriorityRequired);
        made(self, [(id)cmax(self) constraintGreaterThanOrEqualToAnchor:cmax(v)], [@"NSStackView.Edge." stringByAppendingString:CMax], NSLayoutPriorityRequired);
        made(self, [(id)cmin(v) constraintEqualToAnchor:cmin(self) constant:crossMinInset], [@"NSStackView.Edge.Min." stringByAppendingString:CMin], hugAcross);
        made(self, [(id)cmax(self) constraintEqualToAnchor:cmax(v) constant:crossMaxInset], [@"NSStackView.Edge.Min." stringByAppendingString:CMax], hugAcross);
    }

    /* along */
    NSUInteger n = [views count];
    if (n) {
        NSView *first = views[0], *last = [views lastObject];
        BOOL fill = _distribution == NSStackViewDistributionFill || _distribution == NSStackViewDistributionFillEqually ||
                    _distribution == NSStackViewDistributionFillProportionally;
        BOOL gravity = _distribution == NSStackViewDistributionGravityAreas;
        BOOL hasTrailingGravity = gravity && [[self viewsInGravity:NSStackViewGravityTrailing] count];
        NSString *minLead = [@"NSStackView.Edge.Min." stringByAppendingString:Lead];
        NSString *minTrail = [@"NSStackView.Edge.Min." stringByAppendingString:Trail];
        if (fill) {
            made(self, [(id)lead(first) constraintEqualToAnchor:lead(self) constant:leadInset], minLead, NSLayoutPriorityRequired);
            made(self, [(id)trail(self) constraintEqualToAnchor:trail(last) constant:trailInset], minTrail, NSLayoutPriorityRequired);
        } else {
            NSLayoutPriority leadP = 750, trailP = gravity && !hasTrailingGravity ? hugAlong : 750;
            if (gravity && ![[self viewsInGravity:NSStackViewGravityLeading] count])
                leadP = hugAlong;
            made(self, [(id)lead(first) constraintEqualToAnchor:lead(self) constant:leadInset], minLead, leadP);
            made(self, [(id)trail(self) constraintEqualToAnchor:trail(last) constant:trailInset], minTrail, trailP);
            made(self, [(id)lead(first) constraintGreaterThanOrEqualToAnchor:lead(self)], [@"NSStackView.Edge." stringByAppendingString:Lead], NSLayoutPriorityRequired);
            made(self, [(id)trail(self) constraintGreaterThanOrEqualToAnchor:trail(last) constant:trailInset], [@"NSStackView.Edge." stringByAppendingString:Trail], NSLayoutPriorityRequired);
        }
        NSLayoutPriority chainP = 749.99f;
        for (NSUInteger i = 0; i + 1 < n; i++) {
            NSView *a = views[i], *b = views[i + 1];
            CGFloat sp = [self customSpacingAfterView:a];
            if (sp == NSStackViewSpacingUseDefault)
                sp = _spacing;
            if (fill) {
                made(self, [(id)lead(b) constraintEqualToAnchor:trail(a) constant:sp], @"NSStackView.Stack", NSLayoutPriorityRequired);
                continue;
            }
            made(self, [(id)lead(b) constraintGreaterThanOrEqualToAnchor:trail(a) constant:sp], @"NSStackView.Stack.Min", NSLayoutPriorityRequired);
            BOOL sameGravity = gravity && gravity_of(self, a) == gravity_of(self, b);
            NSLayoutPriority p = sameGravity ? chainP : hugAlong;
            made(self, [(id)lead(b) constraintEqualToAnchor:trail(a) constant:sp], @"NSStackView.Stack", p);
            if (sameGravity)
                chainP -= 0.01f;
        }
        /* the centre gravity, centred */
        NSArray *center = gravity ? [self viewsInGravity:NSStackViewGravityCenter] : @[];
        NSMutableArray *visibleCenter = [NSMutableArray array];
        for (NSView *v in center)
            if ([views indexOfObjectIdenticalTo:v] != NSNotFound)
                [visibleCenter addObject:v];
        if ([visibleCenter count]) {
            NSLayoutDimension *before = [(id)lead(self) anchorWithOffsetToAnchor:lead(visibleCenter[0])];
            NSLayoutDimension *after = [(id)trail([visibleCenter lastObject]) anchorWithOffsetToAnchor:trail(self)];
            made(self, [before constraintEqualToAnchor:after], @"NSStackView.CenterGroup.Center", 260);
        }
        /* the equal distributions, through a shared dimension */
        if (_distribution != NSStackViewDistributionGravityAreas && _distribution != NSStackViewDistributionFill) {
            if (!_ideal) {
                _ideal = [[_FinchStackIdealGuide alloc] init];
                [_ideal setIdentifier:@"NSStackView.Distribution.Ideal"];
                [self addLayoutGuide:_ideal];
            }
            NSLayoutDimension *ideal = size(_ideal);
            for (NSUInteger i = 0; i < n; i++) {
                NSView *v = views[i];
                switch (_distribution) {
                case NSStackViewDistributionFillEqually:
                    made(self, [size(v) constraintEqualToAnchor:ideal], @"NSStackView.Distribution.EqualSizing", 260);
                    break;
                case NSStackViewDistributionFillProportionally: {
                    NSSize s = [v intrinsicContentSize];
                    CGFloat m = vertical ? s.height : s.width;
                    if (m > 0)
                        made(self, [size(v) constraintEqualToAnchor:ideal multiplier:m], @"NSStackView.Distribution.ProportionalSizing", 260);
                    break;
                }
                case NSStackViewDistributionEqualSpacing:
                    if (i + 1 < n)
                        made(self, [[(id)trail(v) anchorWithOffsetToAnchor:lead(views[i + 1])] constraintEqualToAnchor:ideal],
                             @"NSStackView.Distribution.EqualSpacing", 260);
                    break;
                case NSStackViewDistributionEqualCentering: {
                    if (i + 1 < n) {
                        id c1 = vertical ? (id)[v centerYAnchor] : (id)[v centerXAnchor];
                        id c2 = vertical ? (id)[views[i + 1] centerYAnchor] : (id)[views[i + 1] centerXAnchor];
                        made(self, [[(id)c1 anchorWithOffsetToAnchor:c2] constraintEqualToAnchor:ideal],
                             @"NSStackView.Distribution.EqualCentering", 260);
                    }
                    break;
                }
                default:
                    break;
                }
            }
        }
    }
    [self addConstraints:_made];
    [super updateConstraints];
}

#pragma mark - Nibs

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    setup(self);
    _orientation = [coder decodeIntegerForKey:@"NSStackViewOrientation"];
    if ([coder containsValueForKey:@"NSStackViewAlignment"])
        _alignment = [coder decodeIntegerForKey:@"NSStackViewAlignment"];
    if ([coder containsValueForKey:@"NSStackViewSpacing"])
        _spacing = [coder decodeDoubleForKey:@"NSStackViewSpacing"];
    if ([coder containsValueForKey:@"NSStackViewdistribution"])
        _distribution = [coder decodeIntegerForKey:@"NSStackViewdistribution"];
    else if ([coder decodeBoolForKey:@"NSStackViewHasEqualSpacing"])
        _distribution = NSStackViewDistributionEqualSpacing;
    _edgeInsets = NSEdgeInsetsMake([coder decodeDoubleForKey:@"NSStackViewEdgeInsets.top"],
                                   [coder decodeDoubleForKey:@"NSStackViewEdgeInsets.left"],
                                   [coder decodeDoubleForKey:@"NSStackViewEdgeInsets.bottom"],
                                   [coder decodeDoubleForKey:@"NSStackViewEdgeInsets.right"]);
    if ([coder containsValueForKey:@"NSStackViewHorizontalHugging"])
        _hugging[0] = [coder decodeDoubleForKey:@"NSStackViewHorizontalHugging"];
    if ([coder containsValueForKey:@"NSStackViewVerticalHugging"])
        _hugging[1] = [coder decodeDoubleForKey:@"NSStackViewVerticalHugging"];
    if ([coder containsValueForKey:@"NSStackViewHorizontalClippingResistance"])
        _clipping[0] = [coder decodeDoubleForKey:@"NSStackViewHorizontalClippingResistance"];
    if ([coder containsValueForKey:@"NSStackViewVerticalClippingResistance"])
        _clipping[1] = [coder decodeDoubleForKey:@"NSStackViewVerticalClippingResistance"];
    if ([coder containsValueForKey:@"NSStackViewDetachesHiddenViews"])
        _detaches = [coder decodeBoolForKey:@"NSStackViewDetachesHiddenViews"];
    NSString *keys[] = {@"NSStackViewBeginningContainer", @"NSStackViewMiddleContainer", @"NSStackViewEndContainer"};
    for (int g = 0; g < 3; g++) {
        NSStackViewContainer *c = [coder decodeObjectForKey:keys[g]];
        if (![c isKindOfClass:[NSStackViewContainer class]])
            continue;
        for (NSView *v in c->_views) {
            [_arranged addObject:v];
            [_gravity setObject:@(g + 1) forKey:v];
        }
    }
    [self setNeedsUpdateConstraints:YES];
    return self;
}

@end
