/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSLayoutConstraint: firstItem.firstAttribute {==, <=, >=}
 * multiplier * secondItem.secondAttribute + constant, at a priority.
 *
 * As on macOS, constraints live in CoreAutoLayout (Foundation re-exports
 * them) and know nothing of views: activating one installs it on the
 * nearest common ancestor of its items by sending -addConstraint: to that
 * view, found through the items' superitems (FinchLayoutItem.h). AppKit
 * keeps the installed constraints and feeds them to the solver.
 *
 * Descriptions are Apple's, as measured on macOS 26.4: spacing between
 * edges prints as visual format ("H:[a]-(8)-[b]"), items with an identifier
 * print by it and are listed under "names", others print as
 * "Class:0x...". Validation messages are Apple's.
 */
#import "FinchLayoutItem.h"
#import <objc/runtime.h>

@interface NSLayoutConstraint () {
  @public
    __weak id _firstItem;
    __weak id _secondItem;
    NSLayoutAttribute _firstAttribute, _secondAttribute;
    NSLayoutRelation _relation;
    CGFloat _multiplier, _constant;
    NSLayoutPriority _priority;
    NSString *_identifier;
    BOOL _shouldBeArchived;
    BOOL _constantResolved;
    FinchLayoutSymbolicConstant _symbolic;
    NSString *_symbolicName;
    NSLayoutAnchor *_firstAnchorRaw, *_secondAnchorRaw;  /* anchor constraints: as made (they may be offsets) */
    id _container;  /* not retained: the view holds the constraint */
    void *_engineData;
}
@end

NSString *
FinchLayoutItemName(id item)
{
    if (!item)
        return @"(null)";
    NSString *ident = [item respondsToSelector:@selector(identifier)] ? [item identifier] : nil;
    if ([ident length])
        return ident;
    return [NSString stringWithFormat:@"%@:%p", NSStringFromClass([item class]), item];
}

static BOOL
item_named(id item)
{
    return item && [item respondsToSelector:@selector(identifier)] && [[item identifier] length];
}

static NSString *
attribute_name(NSLayoutAttribute a)
{
    switch ((NSInteger)a) {
    case NSLayoutAttributeLeft: return @"left";
    case NSLayoutAttributeRight: return @"right";
    case NSLayoutAttributeTop: return @"top";
    case NSLayoutAttributeBottom: return @"bottom";
    case NSLayoutAttributeLeading: return @"leading";
    case NSLayoutAttributeTrailing: return @"trailing";
    case NSLayoutAttributeWidth: return @"width";
    case NSLayoutAttributeHeight: return @"height";
    case NSLayoutAttributeCenterX: return @"centerX";
    case NSLayoutAttributeCenterY: return @"centerY";
    case NSLayoutAttributeLastBaseline: return @"lastBaseline";
    case NSLayoutAttributeFirstBaseline: return @"firstBaseline";
    case FinchLayoutAttributeMinX: return @"minX";
    case FinchLayoutAttributeMinY: return @"minY";
    case NSLayoutAttributeNotAnAttribute: return @"notAnAttribute";
    default: return [NSString stringWithFormat:@"%ld", (long)a];
    }
}

static NSString *
relation_string(NSLayoutRelation r)
{
    return r == NSLayoutRelationLessThanOrEqual ? @"<=" : r == NSLayoutRelationGreaterThanOrEqual ? @">=" : @"==";
}

static NSString *
num(CGFloat v)
{
    return [NSString stringWithFormat:@"%g", (double)v];
}

/* Axes: 0 horizontal position, 1 vertical position, 2 width, 3 height. */
static int
attribute_axis(NSLayoutAttribute a)
{
    switch ((NSInteger)a) {
    case NSLayoutAttributeLeft:
    case NSLayoutAttributeRight:
    case NSLayoutAttributeLeading:
    case NSLayoutAttributeTrailing:
    case NSLayoutAttributeCenterX:
    case FinchLayoutAttributeMinX:
        return 0;
    case NSLayoutAttributeTop:
    case NSLayoutAttributeBottom:
    case NSLayoutAttributeCenterY:
    case NSLayoutAttributeLastBaseline:
    case NSLayoutAttributeFirstBaseline:
    case FinchLayoutAttributeMinY:
        return 1;
    case NSLayoutAttributeWidth: return 2;
    case NSLayoutAttributeHeight: return 3;
    default: return -1;
    }
}

static BOOL
is_directional(NSLayoutAttribute a)
{
    return a == NSLayoutAttributeLeading || a == NSLayoutAttributeTrailing;
}

static BOOL
is_absolute_x(NSLayoutAttribute a)
{
    return a == NSLayoutAttributeLeft || a == NSLayoutAttributeRight;
}

static id
item_superitem(id item)
{
    return [item respondsToSelector:@selector(_finchLayoutSuperitem)] ? [item _finchLayoutSuperitem] : nil;
}

static id
item_container(id item)
{
    if ([item isKindOfClass:[NSLayoutAnchor class]])
        return nil;
    return [item respondsToSelector:@selector(_finchLayoutContainer)] ? [item _finchLayoutContainer] : item;
}

@implementation NSLayoutConstraint

static void
validate(id first, NSLayoutAttribute a1, NSLayoutRelation r, id second, NSLayoutAttribute a2, CGFloat m, CGFloat c)
{
    NSString *who = first ? [first description] : @"(null)";
    if (!first)
        [NSException raise:NSInvalidArgumentException
                    format:@"NSLayoutConstraint for %@: Constraint must contain a first layout item", who];
    int x1 = attribute_axis(a1), x2 = second ? attribute_axis(a2) : -2;
    if (x1 < 0 || (second && x2 < 0))
        [NSException raise:NSInvalidArgumentException format:@"NSLayoutConstraint for %@: Unknown layout attribute", who];
    if (x1 <= 1 && (!second || m == 0))
        [NSException raise:NSInvalidArgumentException
                    format:@"NSLayoutConstraint for %@: A multiplier of 0 or a nil second item together with a location "
                           @"for the first attribute creates an illegal constraint of a location equal to a constant. "
                           @"Location attributes must be specified in pairs.",
                           who];
    if (second) {
        BOOL ok = (x1 <= 1) == (x2 <= 1);  /* positions with positions (either axis), sizes with sizes */
        if (!ok)
            [NSException raise:NSInvalidArgumentException
                        format:@"NSLayoutConstraint for %@: Invalid pairing of layout attributes.", who];
        if ((is_directional(a1) && is_absolute_x(a2)) || (is_absolute_x(a1) && is_directional(a2)))
            [NSException raise:NSInvalidArgumentException
                        format:@"NSLayoutConstraint for %@: A constraint cannot be made between a leading/trailing "
                               @"attribute and a right/left attribute. Use leading/trailing for both or neither.",
                               who];
    }
}

+ (instancetype)_finchConstraintWithItem:(id)first attribute:(NSLayoutAttribute)a1 relatedBy:(NSLayoutRelation)r
                                  toItem:(id)second attribute:(NSLayoutAttribute)a2 multiplier:(CGFloat)m
                                constant:(CGFloat)c
{
    NSLayoutConstraint *k = [[[self alloc] init] autorelease];
    k->_firstItem = first;
    k->_secondItem = second;
    k->_firstAttribute = a1;
    k->_secondAttribute = second ? a2 : NSLayoutAttributeNotAnAttribute;
    k->_relation = r;
    k->_multiplier = m;
    k->_constant = c;
    k->_constantResolved = YES;
    return k;
}

+ (instancetype)constraintWithItem:(id)view1 attribute:(NSLayoutAttribute)attr1 relatedBy:(NSLayoutRelation)relation
                            toItem:(id)view2 attribute:(NSLayoutAttribute)attr2 multiplier:(CGFloat)multiplier
                          constant:(CGFloat)c
{
    if (!view2)
        attr2 = NSLayoutAttributeNotAnAttribute;
    validate(view1, attr1, relation, view2, attr2, multiplier, c);
    NSLayoutConstraint *k = [self _finchConstraintWithItem:view1 attribute:attr1 relatedBy:relation toItem:view2
                                                 attribute:attr2 multiplier:multiplier constant:c];
    if (!isfinite(c))
        [NSException raise:NSInternalInconsistencyException
                    format:@"NSLayoutConstraint constant is not finite!  That's illegal.  constant:%g firstAnchor:%@ "
                           @"secondAnchor:%@",
                           c, [k firstAnchor], [k secondAnchor]];
    return k;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _priority = NSLayoutPriorityRequired;
        _multiplier = 1;
        _constantResolved = YES;
    }
    return self;
}

- (void)dealloc
{
    [_identifier release];
    [_symbolicName release];
    [_firstAnchorRaw release];
    [_secondAnchorRaw release];
    [super dealloc];
}

- (id)firstItem { return _firstItem; }
- (id)secondItem { return _secondItem; }
- (NSLayoutAttribute)firstAttribute { return _firstAttribute; }
- (NSLayoutAttribute)secondAttribute { return _secondAttribute; }
- (NSLayoutRelation)relation { return _relation; }
- (CGFloat)multiplier { return _multiplier; }
- (BOOL)shouldBeArchived { return _shouldBeArchived; }
- (void)setShouldBeArchived:(BOOL)flag { _shouldBeArchived = flag; }
- (NSString *)identifier { return _identifier; }
- (void)setIdentifier:(NSString *)identifier { [_identifier autorelease]; _identifier = [identifier copy]; }
- (NSLayoutPriority)priority { return _priority; }
- (id)_finchContainer { return _container; }
- (void)_finchSetContainer:(id)view { _container = view; }
- (void *)_finchEngineData { return _engineData; }
- (void)_finchSetEngineData:(void *)data { _engineData = data; }
- (FinchLayoutSymbolicConstant)_finchSymbolicConstant { return _symbolic; }
- (void)_finchSetSymbolicConstant:(FinchLayoutSymbolicConstant)kind { _symbolic = kind; }
- (NSString *)_finchSymbolicName { return _symbolicName; }
- (NSLayoutAnchor *)_finchFirstAnchorRaw { return _firstAnchorRaw; }
- (NSLayoutAnchor *)_finchSecondAnchorRaw { return _secondAnchorRaw; }

/* A nib's symbolic NSSpace: the standard space, to the superview's edge or between siblings. */
- (CGFloat)constant
{
    if (!_constantResolved) {
        id first = _firstItem, second = _secondItem;
        BOOL toSuper = second && (item_superitem(first) == second || item_superitem(second) == first);
        _constant = toSuper ? FINCH_LAYOUT_SUPERVIEW_SPACE : FINCH_LAYOUT_SIBLING_SPACE;
        _constantResolved = YES;
    }
    return _constant;
}

- (void)setConstant:(CGFloat)constant
{
    if (!isfinite(constant))
        [NSException raise:NSInternalInconsistencyException
                    format:@"NSLayoutConstraint constant is not finite!  That's illegal.  constant:%g firstAnchor:%@ "
                           @"secondAnchor:%@",
                           constant, [self firstAnchor], [self secondAnchor]];
    _constantResolved = YES;
    if (_constant == constant)
        return;
    _constant = constant;
    _symbolic = FinchLayoutConstantPlain;
    if ([_container respondsToSelector:@selector(_finchLayoutConstraintDidChange:)])
        [_container _finchLayoutConstraintDidChange:self];
}

- (void)setPriority:(NSLayoutPriority)priority
{
    if (!(priority > 0 && priority <= NSLayoutPriorityRequired))
        [NSException raise:NSInternalInconsistencyException
                    format:@"It's illegal to set priority:%g.  Priorities must be greater than 0 and less or equal to "
                           @"NSLayoutPriorityRequired, which is %f.",
                           priority, (double)NSLayoutPriorityRequired];
    if (_priority == priority)
        return;
    _priority = priority;
    if ([_container respondsToSelector:@selector(_finchLayoutConstraintDidChange:)])
        [_container _finchLayoutConstraintDidChange:self];
}

- (NSLayoutAnchor *)firstAnchor
{
    if (_firstAnchorRaw)
        return _firstAnchorRaw;
    return [NSLayoutAnchor _finchAnchorWithItem:_firstItem attribute:_firstAttribute];
}

- (NSLayoutAnchor *)secondAnchor
{
    if (_secondAnchorRaw)
        return _secondAnchorRaw;
    if (!_secondItem)
        return nil;
    return [NSLayoutAnchor _finchAnchorWithItem:_secondItem attribute:_secondAttribute];
}

/* Anchor constraints keep their anchors, which may be offsets between anchors rather than an item's. */
+ (NSLayoutConstraint *)_finchConstraintWithAnchor:(NSLayoutAnchor *)a relation:(NSLayoutRelation)r
                                            anchor:(NSLayoutAnchor *)b multiplier:(CGFloat)m constant:(CGFloat)c
{
    NSLayoutConstraint *k = [self _finchConstraintWithItem:[a item] attribute:[a _finchAttribute] relatedBy:r
                                                    toItem:[b item] attribute:[b _finchAttribute] multiplier:m
                                                  constant:c];
    if ([a _finchFromAnchor]) {
        k->_firstAnchorRaw = [a retain];
        k->_firstAttribute = NSLayoutAttributeNotAnAttribute;
    }
    if ([b _finchFromAnchor]) {
        k->_secondAnchorRaw = [b retain];
        k->_secondAttribute = NSLayoutAttributeNotAnAttribute;
    }
    if (!isfinite(c))
        [NSException raise:NSInternalInconsistencyException
                    format:@"NSLayoutConstraint constant is not finite!  That's illegal.  constant:%g firstAnchor:%@ "
                           @"secondAnchor:%@",
                           c, a, b];
    return k;
}

#pragma mark - Activation

/* The items a constraint relates, as views or guides (an offset contributes both its anchors' items). */
static void
collect_items(NSLayoutAnchor *anchor, id item, NSMutableArray *out)
{
    if ([anchor _finchFromAnchor]) {
        collect_items([anchor _finchFromAnchor], [[anchor _finchFromAnchor] item], out);
        collect_items([anchor _finchToAnchor], [[anchor _finchToAnchor] item], out);
    } else if (item) {
        [out addObject:item];
    }
}

- (NSArray *)_finchItems
{
    NSMutableArray *items = [NSMutableArray array];
    collect_items(_firstAnchorRaw, _firstItem, items);
    collect_items(_secondAnchorRaw, _secondItem, items);
    return items;
}

static BOOL
is_ancestor(id ancestor, id view)
{
    for (id v = view; v; v = item_superitem(v))
        if (v == ancestor)
            return YES;
    return NO;
}

/* The nearest view that is an ancestor of (or is) every item's container. */
- (id)_finchCommonAncestor
{
    id common = nil;
    BOOL first = YES;
    for (id item in [self _finchItems]) {
        id c = item_container(item);
        if (first) {
            common = c;
            first = NO;
            continue;
        }
        while (common && !is_ancestor(common, c))
            common = item_superitem(common);
        if (!common)
            return nil;
    }
    return common;
}

- (BOOL)isActive { return _container != nil; }

- (void)setActive:(BOOL)active
{
    if (active) {
        id view = [self _finchCommonAncestor];
        if (!view)
            [NSException raise:NSGenericException
                        format:@"Unable to activate constraint with anchors %@ and %@ because they have no common "
                               @"ancestor.  Does the constraint or its anchors reference items in different view "
                               @"hierarchies?  That's illegal.",
                               [self firstAnchor], [self secondAnchor]];
        if (_container == view)
            return;
        [view addConstraint:self];
    } else if (_container) {
        [_container removeConstraint:self];
    }
}

+ (void)activateConstraints:(NSArray<NSLayoutConstraint *> *)constraints
{
    for (NSLayoutConstraint *c in constraints)
        [c setActive:YES];
}

+ (void)deactivateConstraints:(NSArray<NSLayoutConstraint *> *)constraints
{
    for (NSLayoutConstraint *c in constraints)
        [c setActive:NO];
}

#pragma mark - Descriptions

- (NSString *)_finchConstantText
{
    CGFloat c = [self constant];
    NSString *v;
    if (_symbolic == FinchLayoutConstantStandardSpace)
        v = [NSString stringWithFormat:@"NSSpace(%@)", num(c)];
    else if (_symbolic == FinchLayoutConstantAnchorSpace)
        v = [NSString stringWithFormat:@"NSLayoutAnchorConstraintSpace(%@)", num(c)];
    else
        v = num(c);
    NSString *rel = _relation == NSLayoutRelationEqual ? @"" : relation_string(_relation);
    NSString *prio = _priority < NSLayoutPriorityRequired ? [NSString stringWithFormat:@"@%@", num(_priority)] : @"";
    return [NSString stringWithFormat:@"(%@%@%@)", rel, v, prio];
}

static NSLayoutAttribute
leading_edge_for(NSLayoutAttribute a)
{
    switch ((NSInteger)a) {
    case NSLayoutAttributeLeading: return NSLayoutAttributeTrailing;
    case NSLayoutAttributeLeft: return NSLayoutAttributeRight;
    case NSLayoutAttributeTop: return NSLayoutAttributeBottom;
    default: return NSLayoutAttributeNotAnAttribute;
    }
}

static NSString *
axis_prefix(NSLayoutAttribute a)
{
    return a == NSLayoutAttributeTop || a == NSLayoutAttributeBottom ? @"V:" : @"H:";
}

static NSString *
ltr_suffix(NSLayoutAttribute a)
{
    return is_absolute_x(a) ? @"(LTR)" : @"";
}

/* The spacing forms: the body, and whether '|' (the superview) appears; nil if the constraint isn't one. */
- (NSString *)_finchSpacingBody:(id *)bar
{
    id first = _firstItem, second = _secondItem;
    if (_firstAnchorRaw || _secondAnchorRaw || !first || !second || _multiplier != 1)
        return nil;
    NSLayoutAttribute a1 = _firstAttribute, a2 = _secondAttribute;
    NSString *k = [self _finchConstantText];
    /* |-(c)-[first] */
    if (a1 == a2 && leading_edge_for(a1) && item_superitem(first) == second) {
        *bar = second;
        return [NSString stringWithFormat:@"%@|-%@-[%@]%@", axis_prefix(a1), k, FinchLayoutItemName(first),
                                          ltr_suffix(a1)];
    }
    /* [second]-(c)-| */
    if (a1 == a2 && (a1 == NSLayoutAttributeTrailing || a1 == NSLayoutAttributeRight || a1 == NSLayoutAttributeBottom) &&
        item_superitem(second) == first) {
        *bar = first;
        return [NSString stringWithFormat:@"%@[%@]-%@-|%@", axis_prefix(a1), FinchLayoutItemName(second), k,
                                          ltr_suffix(a1)];
    }
    /* [second]-(c)-[first] */
    if (leading_edge_for(a1) && a2 == leading_edge_for(a1))
        return [NSString stringWithFormat:@"%@[%@]-%@-[%@]%@", axis_prefix(a1), FinchLayoutItemName(second), k,
                                          FinchLayoutItemName(first), ltr_suffix(a1)];
    return nil;
}

NSString *FinchAnchorText(NSLayoutAnchor *anchor);

static NSString *
anchor_term(NSLayoutAnchor *raw, id item, NSLayoutAttribute attr)
{
    if (raw)
        return [NSString stringWithFormat:@"(%@ - %@)", FinchAnchorText([raw _finchToAnchor]),
                                          FinchAnchorText([raw _finchFromAnchor])];
    return [NSString stringWithFormat:@"%@.%@", FinchLayoutItemName(item), attribute_name(attr)];
}

- (NSString *)_finchGeneralBody
{
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@ %@ ", anchor_term(_firstAnchorRaw, _firstItem, _firstAttribute), relation_string(_relation)];
    BOOL term = NO;
    if ((_secondItem || _secondAnchorRaw) && _multiplier != 0) {
        if (_multiplier == -1)
            [s appendString:@"-"];
        else if (_multiplier != 1)
            [s appendFormat:@"%@*", num(_multiplier)];
        [s appendString:anchor_term(_secondAnchorRaw, _secondItem, _secondAttribute)];
        term = YES;
    }
    CGFloat c = [self constant];
    if (!term)
        [s appendString:c < 0 ? [NSString stringWithFormat:@"- %@", num(-c)] : num(c)];
    else if (c > 0)
        [s appendFormat:@" + %@", num(c)];
    else if (c < 0)
        [s appendFormat:@" - %@", num(-c)];
    return s;
}

- (NSString *)_finchBody:(id *)bar
{
    NSString *spacing = [self _finchSpacingBody:bar];
    return spacing ?: [self _finchGeneralBody];
}

- (NSString *)_finchPriorityText
{
    return _priority < NSLayoutPriorityRequired ? [NSString stringWithFormat:@" priority:%@", num(_priority)] : @"";
}

- (NSString *)_finchPrefix
{
    return @"";
}

static void
add_anchor_names(NSLayoutAnchor *raw, NSMutableArray *names)
{
    for (NSLayoutAnchor *a in @[ [raw _finchToAnchor] ?: (id)[NSNull null], [raw _finchFromAnchor] ?: (id)[NSNull null] ])
        if ([a isKindOfClass:[NSLayoutAnchor class]] && [a item])
            [names addObject:[NSString stringWithFormat:@"%@:%p", FinchAnchorText(a), [a item]]];
}

- (NSString *)description
{
    id bar = nil;
    NSString *body = [self _finchBody:&bar];
    NSMutableArray *names = [NSMutableArray array];
    id first = _firstItem, second = _secondItem;
    if ([self respondsToSelector:@selector(_finchNamedItems)]) {
        for (id item in [(id)self _finchNamedItems])
            if (item_named(item))
                [names addObject:[NSString stringWithFormat:@"%@:%p", FinchLayoutItemName(item), item]];
        first = second = nil;
    }
    if (_firstAnchorRaw)
        add_anchor_names(_firstAnchorRaw, names);
    else if (item_named(first))
        [names addObject:[NSString stringWithFormat:@"%@:%p", FinchLayoutItemName(first), first]];
    if (_multiplier == 0 && !bar)
        second = nil;  /* not in the formula */
    if (_secondAnchorRaw)
        add_anchor_names(_secondAnchorRaw, names);
    else if (item_named(second) && second != first)
        [names addObject:[NSString stringWithFormat:@"%@:%p", FinchLayoutItemName(second), second]];
    if (bar) {
        NSString *n = FinchLayoutItemName(bar);
        [names addObject:item_named(bar) ? [NSString stringWithFormat:@"'|':%@:%p", n, bar]
                                         : [NSString stringWithFormat:@"'|':%@", n]];
    }
    NSString *ident = _identifier ? [NSString stringWithFormat:@"'%@' ", _identifier] : @"";
    NSString *state = [self isActive] ? @"active" : @"inactive";
    NSString *tail = [names count] ? [NSString stringWithFormat:@"%@, names: %@ ", state, [names componentsJoinedByString:@", "]]
                                   : state;
    return [NSString stringWithFormat:@"<%@:%p %@%@%@%@   (%@)>", NSStringFromClass([self class]), self,
                                      [self _finchPrefix], ident, body, [self _finchPriorityText], tail];
}

#pragma mark - Coding (nibs)

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self init];
    if (!self)
        return nil;
    _firstItem = [coder decodeObjectForKey:@"NSFirstItem"];
    _secondItem = [coder decodeObjectForKey:@"NSSecondItem"];
    _firstAttribute = [coder containsValueForKey:@"NSFirstAttributeV2"] ? [coder decodeIntegerForKey:@"NSFirstAttributeV2"]
                                                                         : [coder decodeIntegerForKey:@"NSFirstAttribute"];
    _secondAttribute = [coder containsValueForKey:@"NSSecondAttributeV2"]
                           ? [coder decodeIntegerForKey:@"NSSecondAttributeV2"]
                           : [coder decodeIntegerForKey:@"NSSecondAttribute"];
    _relation = [coder decodeIntegerForKey:@"NSRelation"];
    _multiplier = [coder containsValueForKey:@"NSMultiplier"] ? [coder decodeDoubleForKey:@"NSMultiplier"] : 1;
    _constant = [coder containsValueForKey:@"NSConstantV2"] ? [coder decodeDoubleForKey:@"NSConstantV2"]
                                                            : [coder decodeDoubleForKey:@"NSConstant"];
    if ([coder containsValueForKey:@"NSPriority"])
        _priority = (NSLayoutPriority)[coder decodeDoubleForKey:@"NSPriority"];
    _shouldBeArchived = [coder decodeBoolForKey:@"NSShouldBeArchived"];
    _identifier = [[coder decodeObjectForKey:@"NSLayoutIdentifier"] copy];
    NSString *symbolic = [coder decodeObjectForKey:@"NSSymbolicConstant"];
    if (symbolic) {
        _symbolicName = [symbolic copy];
        if ([symbolic isEqualToString:@"NSSpace"]) {
            _symbolic = FinchLayoutConstantStandardSpace;
            _constantResolved = NO;
        }
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    id first = _firstItem, second = _secondItem;
    [coder encodeConditionalObject:first forKey:@"NSFirstItem"];
    [coder encodeInteger:_firstAttribute forKey:@"NSFirstAttribute"];
    [coder encodeInteger:_firstAttribute forKey:@"NSFirstAttributeV2"];
    if (_relation)
        [coder encodeInteger:_relation forKey:@"NSRelation"];
    if (second) {
        [coder encodeConditionalObject:second forKey:@"NSSecondItem"];
        [coder encodeInteger:_secondAttribute forKey:@"NSSecondAttribute"];
        [coder encodeInteger:_secondAttribute forKey:@"NSSecondAttributeV2"];
    }
    if (_multiplier != 1)
        [coder encodeDouble:_multiplier forKey:@"NSMultiplier"];
    if (_symbolicName) {
        [coder encodeObject:_symbolicName forKey:@"NSSymbolicConstant"];
    } else if (_constant != 0) {
        [coder encodeDouble:_constant forKey:@"NSConstant"];
        [coder encodeDouble:_constant forKey:@"NSConstantV2"];
    }
    if (_priority != NSLayoutPriorityRequired)
        [coder encodeDouble:_priority forKey:@"NSPriority"];
    if (_shouldBeArchived)
        [coder encodeBool:YES forKey:@"NSShouldBeArchived"];
    if (_identifier)
        [coder encodeObject:_identifier forKey:@"NSLayoutIdentifier"];
}

@end

#pragma mark - Identifier category (declared separately in the SDK)

#pragma mark - Autoresizing-mask constraints

@implementation NSAutoresizingMaskLayoutConstraint {
    FinchAutoresizingKind _kind;
    NSUInteger _mask;
}

+ (instancetype)_finchConstraintForView:(id)view superview:(id)superview kind:(FinchAutoresizingKind)kind
                             multiplier:(CGFloat)m constant:(CGFloat)c mask:(NSUInteger)mask
{
    NSLayoutAttribute a1 = 0, a2 = 0;
    id second = nil;
    switch (kind) {
    case FinchAutoresizingMinX: a1 = FinchLayoutAttributeMinX; break;
    case FinchAutoresizingMinY: a1 = FinchLayoutAttributeMinY; break;
    case FinchAutoresizingWidth: a1 = NSLayoutAttributeWidth; break;
    case FinchAutoresizingHeight: a1 = NSLayoutAttributeHeight; break;
    case FinchAutoresizingMaxXMargin: a1 = NSLayoutAttributeWidth; a2 = FinchLayoutAttributeMaxXMargin; second = superview; break;
    case FinchAutoresizingMaxYMargin: a1 = NSLayoutAttributeHeight; a2 = FinchLayoutAttributeMaxYMargin; second = superview; break;
    case FinchAutoresizingPropMinX: a1 = FinchLayoutAttributeMinX; a2 = NSLayoutAttributeWidth; second = superview; break;
    case FinchAutoresizingPropWidth: a1 = NSLayoutAttributeWidth; a2 = NSLayoutAttributeWidth; second = superview; break;
    case FinchAutoresizingPropMinY: a1 = FinchLayoutAttributeMinY; a2 = NSLayoutAttributeHeight; second = superview; break;
    case FinchAutoresizingPropHeight: a1 = NSLayoutAttributeHeight; a2 = NSLayoutAttributeHeight; second = superview; break;
    }
    NSAutoresizingMaskLayoutConstraint *k = [self _finchConstraintWithItem:view attribute:a1 relatedBy:0 toItem:second
                                                                 attribute:a2 multiplier:m constant:c];
    k->_kind = kind;
    k->_mask = mask;
    return k;
}

- (FinchAutoresizingKind)_finchKind { return _kind; }
- (NSUInteger)_finchMask { return _mask; }

static NSString *
axis_flags(BOOL minFlex, BOOL sizeFlex, BOOL maxFlex)
{
    if (!minFlex && !sizeFlex && !maxFlex)
        maxFlex = YES;
    return [NSString stringWithFormat:@"%c%c%c", minFlex ? '&' : '-', sizeFlex ? '&' : '-', maxFlex ? '&' : '-'];
}

- (NSString *)_finchPrefix
{
    NSUInteger m = _mask;
    return [NSString stringWithFormat:@"h=%@ v=%@ ", axis_flags(m & 1, m & 2, m & 4), axis_flags(m & 8, m & 16, m & 32)];
}

- (NSArray *)_finchNamedItems
{
    id view = _firstItem, superview = item_superitem(view);
    if (_kind == FinchAutoresizingMaxXMargin || _kind == FinchAutoresizingMaxYMargin)
        return @[ superview ?: (id)[NSNull null], view ?: (id)[NSNull null] ];
    if (_kind == FinchAutoresizingMinX || _kind == FinchAutoresizingMinY || _kind == FinchAutoresizingWidth ||
        _kind == FinchAutoresizingHeight)
        return @[ view ?: (id)[NSNull null] ];
    return @[ view ?: (id)[NSNull null], superview ?: (id)[NSNull null] ];
}

- (NSString *)_finchBody:(id *)bar
{
    id view = _firstItem, superview = item_superitem(view);
    CGFloat c = [self constant];
    switch (_kind) {
    case FinchAutoresizingMinX:
    case FinchAutoresizingMinY:
        *bar = superview;
        return [NSString stringWithFormat:@"%@.%@ == %@", FinchLayoutItemName(view),
                                          _kind == FinchAutoresizingMinX ? @"minX" : @"minY", num(c)];
    case FinchAutoresizingMaxXMargin:
        *bar = superview;
        return [NSString stringWithFormat:@"H:[%@]-(%@)-|", FinchLayoutItemName(view), num(c)];
    case FinchAutoresizingMaxYMargin:
        *bar = superview;
        return [NSString stringWithFormat:@"V:|-(%@)-[%@]", num(c), FinchLayoutItemName(view)];
    default:
        return [self _finchGeneralBody];
    }
}

@end

#pragma mark - Content size constraints

@implementation NSContentSizeLayoutConstraint {
    NSLayoutPriority _hug, _compression;
}

+ (instancetype)_finchConstraintForView:(id)view orientation:(NSLayoutConstraintOrientation)o constant:(CGFloat)c
                                    hug:(NSLayoutPriority)hug compressionResistance:(NSLayoutPriority)cr
{
    NSContentSizeLayoutConstraint *k =
        [self _finchConstraintWithItem:view
                             attribute:o == NSLayoutConstraintOrientationHorizontal ? NSLayoutAttributeWidth
                                                                                    : NSLayoutAttributeHeight
                             relatedBy:NSLayoutRelationEqual toItem:nil attribute:0 multiplier:1 constant:c];
    k->_hug = hug;
    k->_compression = cr;
    return k;
}

- (NSLayoutPriority)huggingPriority { return _hug; }
- (NSLayoutPriority)compressionResistancePriority { return _compression; }
- (void)_finchSetHuggingPriority:(NSLayoutPriority)hug compressionResistance:(NSLayoutPriority)cr
{
    _hug = hug;
    _compression = cr;
}

- (NSString *)_finchPriorityText
{
    return [NSString stringWithFormat:@" Hug:%@ CompressionResistance:%@", num(_hug), num(_compression)];
}

@end

/* Interface Builder's placeholders for constraints it adds to ambiguous layouts. */
@interface NSIBPrototypingLayoutConstraint : NSLayoutConstraint
@end

@implementation NSIBPrototypingLayoutConstraint
@end
