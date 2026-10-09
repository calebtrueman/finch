/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What CoreAutoLayout and AppKit share about layout items. CoreAutoLayout
 * knows constraints, anchors and the solver; the items they relate (views
 * and layout guides) are AppKit's, and answer these messages, sent by name
 * so CoreAutoLayout doesn't link AppKit (as Apple's: its items speak the
 * private NSLayoutItem protocol).
 */
#ifndef FINCH_LAYOUT_ITEM_H
#define FINCH_LAYOUT_ITEM_H

#import <Foundation/Foundation.h>
#import <AppKit/NSLayoutConstraint.h>
#import <AppKit/NSLayoutAnchor.h>

#define FINCH_LAYOUT_EXPORT __attribute__((visibility("default")))

/* Private attributes Apple's autoresizing-mask constraints use. */
enum {
    FinchLayoutAttributeMinX = 32,
    FinchLayoutAttributeMinY = 33,
    FinchLayoutAttributeMaxXMargin = 36,  /* the superview's side of H:[view]-(c)-| */
    FinchLayoutAttributeMaxYMargin = 37,  /* ... and of V:|-(c)-[view] */
};

/* What a constant stands for, for descriptions: VFL's standard space, or an anchor's system spacing. */
typedef NS_ENUM(NSInteger, FinchLayoutSymbolicConstant) {
    FinchLayoutConstantPlain = 0,
    FinchLayoutConstantStandardSpace,   /* NSSpace(20) */
    FinchLayoutConstantAnchorSpace,     /* NSLayoutAnchorConstraintSpace(8) */
};

/* The standard spaces: between siblings, and to the superview's edge. */
#define FINCH_LAYOUT_SIBLING_SPACE 8.0
#define FINCH_LAYOUT_SUPERVIEW_SPACE 20.0

@protocol FinchLayoutItem <NSObject>
@optional
/* the view this item is laid out in: a view's superview, a guide's owning view */
- (id)_finchLayoutSuperitem;
/* the view constraints on this item alone are installed on: a view, a guide's owning view */
- (id)_finchLayoutContainer;
/* the item's (cached) anchor for an attribute */
- (NSLayoutAnchor *)_finchAnchorForAttribute:(NSLayoutAttribute)attribute;
/* on a container (a view): a constraint installed on it changed its constant or priority */
- (void)_finchLayoutConstraintDidChange:(NSLayoutConstraint *)constraint;
@end

@interface NSLayoutConstraint (FinchLayout)
+ (instancetype)_finchConstraintWithItem:(id)first attribute:(NSLayoutAttribute)a1 relatedBy:(NSLayoutRelation)r
                                  toItem:(id)second attribute:(NSLayoutAttribute)a2 multiplier:(CGFloat)m
                                constant:(CGFloat)c;
- (id)_finchContainer;  /* the view it's installed on (not retained); nil when inactive */
- (void)_finchSetContainer:(id)view;
- (void *)_finchEngineData;
- (void)_finchSetEngineData:(void *)data;
- (FinchLayoutSymbolicConstant)_finchSymbolicConstant;
- (void)_finchSetSymbolicConstant:(FinchLayoutSymbolicConstant)kind;
- (NSString *)_finchSymbolicName;  /* from a nib: "NSSpace" */
/* An anchor constraint's first or second item may be an expression (an anchor offset). */
- (NSLayoutAnchor *)_finchFirstAnchorRaw;
- (NSLayoutAnchor *)_finchSecondAnchorRaw;
@end

/* Autoresizing-mask constraints: the axis flags they print, and what they say. */
typedef NS_ENUM(NSInteger, FinchAutoresizingKind) {
    FinchAutoresizingMinX = 1,     /* view.minX == c */
    FinchAutoresizingWidth,        /* view.width == c */
    FinchAutoresizingMaxXMargin,   /* superview.width - view.maxX == c */
    FinchAutoresizingPropMinX,     /* view.minX == m * superview.width + c */
    FinchAutoresizingPropWidth,    /* view.width == m * superview.width + c */
    FinchAutoresizingMinY,
    FinchAutoresizingHeight,
    FinchAutoresizingMaxYMargin,
    FinchAutoresizingPropMinY,
    FinchAutoresizingPropHeight,
};

@interface NSAutoresizingMaskLayoutConstraint : NSLayoutConstraint
+ (instancetype)_finchConstraintForView:(id)view superview:(id)superview kind:(FinchAutoresizingKind)kind
                             multiplier:(CGFloat)m constant:(CGFloat)c mask:(NSUInteger)mask;
- (FinchAutoresizingKind)_finchKind;
- (NSUInteger)_finchMask;
@end

@interface NSContentSizeLayoutConstraint : NSLayoutConstraint
+ (instancetype)_finchConstraintForView:(id)view orientation:(NSLayoutConstraintOrientation)o constant:(CGFloat)c
                                    hug:(NSLayoutPriority)hug compressionResistance:(NSLayoutPriority)cr;
- (NSLayoutPriority)huggingPriority;
- (NSLayoutPriority)compressionResistancePriority;
- (void)_finchSetHuggingPriority:(NSLayoutPriority)hug compressionResistance:(NSLayoutPriority)cr;
@end

@interface NSLayoutAnchor (FinchLayout)
+ (instancetype)_finchAnchorWithItem:(id)item attribute:(NSLayoutAttribute)attribute;  /* the item's own, if it caches them */
+ (instancetype)_finchNewAnchorWithItem:(id)item attribute:(NSLayoutAttribute)attribute;
- (NSLayoutAttribute)_finchAttribute;
/* An offset between two anchors (anchorWithOffsetToAnchor:): its anchors, else nil. */
- (NSLayoutAnchor *)_finchFromAnchor;
- (NSLayoutAnchor *)_finchToAnchor;
@end

/* The constraint's items, flattening anchor offsets. */
@interface NSLayoutConstraint (FinchLayoutItems)
- (NSArray *)_finchItems;
@end

/* An anchor's "item.attribute" text. */
FINCH_LAYOUT_EXPORT NSString *FinchAnchorText(NSLayoutAnchor *anchor);

/* An item's name in descriptions: its identifier, else "Class:0x...". */
FINCH_LAYOUT_EXPORT NSString *FinchLayoutItemName(id item);

#endif
