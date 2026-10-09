/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Layout anchors: an item's attribute, as an object that makes constraints
 * with others of its kind (x-axis with x-axis, y-axis with y-axis,
 * dimensions with dimensions and constants). An offset between two anchors
 * of an axis (-anchorWithOffsetToAnchor:) is itself a dimension
 * (_NSDistanceLayoutDimension, as Apple's), which constraints can relate.
 * Descriptions are Apple's.
 */
#import "FinchLayoutItem.h"
#import <objc/runtime.h>

@interface NSLayoutConstraint (FinchAnchors)
+ (NSLayoutConstraint *)_finchConstraintWithAnchor:(NSLayoutAnchor *)a relation:(NSLayoutRelation)r
                                            anchor:(NSLayoutAnchor *)b multiplier:(CGFloat)m constant:(CGFloat)c;
@end

@interface _NSDistanceLayoutDimension : NSLayoutDimension
@end

static NSString *
attr_name(NSLayoutAttribute a)
{
    static NSString *const names[] = {@"notAnAttribute", @"left", @"right", @"top", @"bottom", @"leading", @"trailing",
                                      @"width", @"height", @"centerX", @"centerY", @"lastBaseline", @"firstBaseline"};
    return a >= 0 && a <= NSLayoutAttributeFirstBaseline ? names[a] : @"";
}

@implementation NSLayoutAnchor {
  @public
    __weak id _item;
    NSLayoutAttribute _attribute;
    NSLayoutAnchor *_from, *_to;
}

+ (instancetype)_finchAnchorWithItem:(id)item attribute:(NSLayoutAttribute)attribute
{
    if (item && [item respondsToSelector:@selector(_finchAnchorForAttribute:)]) {
        NSLayoutAnchor *a = [item _finchAnchorForAttribute:attribute];
        if (a)
            return a;
    }
    return [self _finchNewAnchorWithItem:item attribute:attribute];
}

+ (instancetype)_finchNewAnchorWithItem:(id)item attribute:(NSLayoutAttribute)attribute
{
    Class c;
    switch (attribute) {
    case NSLayoutAttributeWidth:
    case NSLayoutAttributeHeight:
        c = [NSLayoutDimension class];
        break;
    case NSLayoutAttributeTop:
    case NSLayoutAttributeBottom:
    case NSLayoutAttributeCenterY:
    case NSLayoutAttributeFirstBaseline:
    case NSLayoutAttributeLastBaseline:
        c = [NSLayoutYAxisAnchor class];
        break;
    default:
        c = [NSLayoutXAxisAnchor class];
        break;
    }
    NSLayoutAnchor *a = [[[c alloc] init] autorelease];
    a->_item = item;
    a->_attribute = attribute;
    return a;
}

- (void)dealloc
{
    [_from release];
    [_to release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (id)item { return _item; }
- (NSLayoutAttribute)_finchAttribute { return _attribute; }
- (NSLayoutAnchor *)_finchFromAnchor { return _from; }
- (NSLayoutAnchor *)_finchToAnchor { return _to; }
- (NSString *)name { return _from ? @"" : attr_name(_attribute); }

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSLayoutAnchor class]] || _from)
        return NO;
    NSLayoutAnchor *o = other;
    id a = _item, b = o->_item;
    return !o->_from && a == b && _attribute == o->_attribute;
}

- (NSUInteger)hash
{
    id item = _item;
    return (NSUInteger)item ^ (NSUInteger)_attribute;
}

NSString *
FinchAnchorText(NSLayoutAnchor *anchor)
{
    if (anchor->_from)
        return [NSString stringWithFormat:@"(%@ - %@)", FinchAnchorText(anchor->_to), FinchAnchorText(anchor->_from)];
    return [NSString stringWithFormat:@"%@.%@", FinchLayoutItemName(anchor->_item), attr_name(anchor->_attribute)];
}

- (NSString *)description
{
    id item = _item;
    if (_from) {
        id a = _to->_item, b = _from->_item;
        return [NSString stringWithFormat:@"<%@:%p `%@` (names: %@:%p, %@:%p)>", NSStringFromClass([self class]), self,
                                          FinchAnchorText(self), FinchAnchorText(_to), a, FinchAnchorText(_from), b];
    }
    BOOL named = item && [item respondsToSelector:@selector(identifier)] && [[item identifier] length];
    if (named)
        return [NSString stringWithFormat:@"<%@:%p \"%@\" (names: %@:%p)>", NSStringFromClass([self class]), self,
                                          FinchAnchorText(self), FinchLayoutItemName(item), item];
    return [NSString stringWithFormat:@"<%@:%p \"%@\">", NSStringFromClass([self class]), self, FinchAnchorText(self)];
}

- (BOOL)hasAmbiguousLayout
{
    id item = _item;
    return [item respondsToSelector:@selector(hasAmbiguousLayout)] ? [item hasAmbiguousLayout] : NO;
}

- (NSArray<NSLayoutConstraint *> *)constraintsAffectingLayout
{
    id item = _item;
    NSLayoutConstraintOrientation o = [self isKindOfClass:[NSLayoutYAxisAnchor class]] || _attribute == NSLayoutAttributeHeight
                                          ? NSLayoutConstraintOrientationVertical
                                          : NSLayoutConstraintOrientationHorizontal;
    if ([item respondsToSelector:@selector(constraintsAffectingLayoutForOrientation:)])
        return [item constraintsAffectingLayoutForOrientation:o];
    return @[];
}

- (NSLayoutConstraint *)_finch:(NSLayoutRelation)r anchor:(NSLayoutAnchor *)a m:(CGFloat)m c:(CGFloat)c
{
    return [NSLayoutConstraint _finchConstraintWithAnchor:self relation:r anchor:a multiplier:m constant:c];
}

- (NSLayoutConstraint *)constraintEqualToAnchor:(NSLayoutAnchor *)anchor { return [self _finch:0 anchor:anchor m:1 c:0]; }
- (NSLayoutConstraint *)constraintGreaterThanOrEqualToAnchor:(NSLayoutAnchor *)anchor { return [self _finch:1 anchor:anchor m:1 c:0]; }
- (NSLayoutConstraint *)constraintLessThanOrEqualToAnchor:(NSLayoutAnchor *)anchor { return [self _finch:-1 anchor:anchor m:1 c:0]; }
- (NSLayoutConstraint *)constraintEqualToAnchor:(NSLayoutAnchor *)anchor constant:(CGFloat)c { return [self _finch:0 anchor:anchor m:1 c:c]; }
- (NSLayoutConstraint *)constraintGreaterThanOrEqualToAnchor:(NSLayoutAnchor *)anchor constant:(CGFloat)c { return [self _finch:1 anchor:anchor m:1 c:c]; }
- (NSLayoutConstraint *)constraintLessThanOrEqualToAnchor:(NSLayoutAnchor *)anchor constant:(CGFloat)c { return [self _finch:-1 anchor:anchor m:1 c:c]; }

- (NSLayoutDimension *)_finchOffsetTo:(NSLayoutAnchor *)other
{
    _NSDistanceLayoutDimension *d = [[[_NSDistanceLayoutDimension alloc] init] autorelease];
    ((NSLayoutAnchor *)d)->_from = [self retain];
    ((NSLayoutAnchor *)d)->_to = [other retain];
    ((NSLayoutAnchor *)d)->_attribute = NSLayoutAttributeNotAnAttribute;
    return d;
}

/* self == anchor + multiplier * the system's spacing */
- (NSLayoutConstraint *)_finchSpacing:(NSLayoutRelation)r after:(NSLayoutAnchor *)anchor multiplier:(CGFloat)m
{
    NSLayoutConstraint *k = [self _finch:r anchor:anchor m:1 c:FINCH_LAYOUT_SIBLING_SPACE * m];
    [k _finchSetSymbolicConstant:FinchLayoutConstantAnchorSpace];
    return k;
}

@end

@implementation NSLayoutXAxisAnchor

- (NSLayoutDimension *)anchorWithOffsetToAnchor:(NSLayoutXAxisAnchor *)otherAnchor { return [self _finchOffsetTo:otherAnchor]; }
- (NSLayoutConstraint *)constraintEqualToSystemSpacingAfterAnchor:(NSLayoutXAxisAnchor *)anchor multiplier:(CGFloat)m
{
    return [self _finchSpacing:0 after:anchor multiplier:m];
}
- (NSLayoutConstraint *)constraintGreaterThanOrEqualToSystemSpacingAfterAnchor:(NSLayoutXAxisAnchor *)anchor multiplier:(CGFloat)m
{
    return [self _finchSpacing:1 after:anchor multiplier:m];
}
- (NSLayoutConstraint *)constraintLessThanOrEqualToSystemSpacingAfterAnchor:(NSLayoutXAxisAnchor *)anchor multiplier:(CGFloat)m
{
    return [self _finchSpacing:-1 after:anchor multiplier:m];
}

@end

@implementation NSLayoutYAxisAnchor

- (NSLayoutDimension *)anchorWithOffsetToAnchor:(NSLayoutYAxisAnchor *)otherAnchor { return [self _finchOffsetTo:otherAnchor]; }
- (NSLayoutConstraint *)constraintEqualToSystemSpacingBelowAnchor:(NSLayoutYAxisAnchor *)anchor multiplier:(CGFloat)m
{
    return [self _finchSpacing:0 after:anchor multiplier:m];
}
- (NSLayoutConstraint *)constraintGreaterThanOrEqualToSystemSpacingBelowAnchor:(NSLayoutYAxisAnchor *)anchor multiplier:(CGFloat)m
{
    return [self _finchSpacing:1 after:anchor multiplier:m];
}
- (NSLayoutConstraint *)constraintLessThanOrEqualToSystemSpacingBelowAnchor:(NSLayoutYAxisAnchor *)anchor multiplier:(CGFloat)m
{
    return [self _finchSpacing:-1 after:anchor multiplier:m];
}

@end

@implementation NSLayoutDimension

- (NSLayoutConstraint *)constraintEqualToConstant:(CGFloat)c { return [self _finch:0 anchor:nil m:1 c:c]; }
- (NSLayoutConstraint *)constraintGreaterThanOrEqualToConstant:(CGFloat)c { return [self _finch:1 anchor:nil m:1 c:c]; }
- (NSLayoutConstraint *)constraintLessThanOrEqualToConstant:(CGFloat)c { return [self _finch:-1 anchor:nil m:1 c:c]; }
- (NSLayoutConstraint *)constraintEqualToAnchor:(NSLayoutDimension *)anchor multiplier:(CGFloat)m { return [self _finch:0 anchor:anchor m:m c:0]; }
- (NSLayoutConstraint *)constraintGreaterThanOrEqualToAnchor:(NSLayoutDimension *)anchor multiplier:(CGFloat)m { return [self _finch:1 anchor:anchor m:m c:0]; }
- (NSLayoutConstraint *)constraintLessThanOrEqualToAnchor:(NSLayoutDimension *)anchor multiplier:(CGFloat)m { return [self _finch:-1 anchor:anchor m:m c:0]; }
- (NSLayoutConstraint *)constraintEqualToAnchor:(NSLayoutDimension *)anchor multiplier:(CGFloat)m constant:(CGFloat)c { return [self _finch:0 anchor:anchor m:m c:c]; }
- (NSLayoutConstraint *)constraintGreaterThanOrEqualToAnchor:(NSLayoutDimension *)anchor multiplier:(CGFloat)m constant:(CGFloat)c { return [self _finch:1 anchor:anchor m:m c:c]; }
- (NSLayoutConstraint *)constraintLessThanOrEqualToAnchor:(NSLayoutDimension *)anchor multiplier:(CGFloat)m constant:(CGFloat)c { return [self _finch:-1 anchor:anchor m:m c:c]; }

@end

@implementation _NSDistanceLayoutDimension
@end
