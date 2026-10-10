/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AppKit's private methods that SwiftUI calls, with Apple's behaviour as Finch can give it:
 *   - geometry-in-window observers: a block called when a view's frame, or an ancestor's,
 *     changes (the returned token unregisters when it is released);
 *   - measuring (-measureMin:max:ideal:), the computed safe area, the layer syncing calls
 *     (Finch renders layers with the view tree, so there is nothing to sync), the next
 *     responder for an event;
 *   - accessibility overrides, kept on the object;
 *   - tinted appearances, progress indicator fonts, image accessibility descriptions;
 *   - gesture recognizer state queries, and whether to load a main nib or storyboard.
 */
#import "NSView_Finch.h"
#import <objc/runtime.h>

#pragma mark - Geometry in window

@interface _FinchGeometryObserver : NSObject {
  @public
    __unsafe_unretained NSView *_view;
    void (^_block)(NSView *);
}
@end

static NSHashTable *geometry_observers;

@implementation _FinchGeometryObserver
- (void)dealloc
{
    [geometry_observers removeObject:self];
    [_block release];
    [super dealloc];
}
@end

void
FinchViewGeometryInWindowDidChange(NSView *view)
{
    if (![geometry_observers count])
        return;
    for (_FinchGeometryObserver *o in [geometry_observers allObjects])
        if (o->_view && [o->_view isDescendantOf:view])
            o->_block(o->_view);
}

@implementation NSView (FinchPrivateSPI)

- (id)_observerForChangesInGeometryInWindow:(void (^)(NSView *))block
{
    if (!geometry_observers)
        geometry_observers = [[NSHashTable weakObjectsHashTable] retain];
    _FinchGeometryObserver *o = [[[_FinchGeometryObserver alloc] init] autorelease];
    o->_view = self;
    o->_block = [block copy];
    [geometry_observers addObject:o];
    return o;
}

- (void)_updateLayerGeometryFromView {}
- (void)_updateLayerShadowFromView {}
- (void)_updateLayerShadowColorFromView {}

- (NSEdgeInsets)computedSafeAreaInsets { return [self safeAreaInsets]; }

- (NSResponder *)_nextResponderForEvent:(NSEvent *)event { return [self nextResponder]; }

/*
 * As Apple's: per axis, a view with an intrinsic length is held at least at it when its
 * compression resistance outranks the stretching priority, and at most when its hugging
 * does; its ideal is that length. A view without one measures by its constraints' fitting
 * size, and stretches without limit.
 */
- (void)measureMin:(CGSize *)min max:(CGSize *)max ideal:(CGSize *)ideal stretchingPriority:(float)priority
{
    NSSize intrinsic = [self intrinsicContentSize];
    NSSize fit = [self fittingSize];
    CGFloat lo[2], hi[2], id[2];
    for (int axis = 0; axis < 2; axis++) {
        CGFloat v = axis ? intrinsic.height : intrinsic.width;
        NSLayoutConstraintOrientation o = axis ? NSLayoutConstraintOrientationVertical : NSLayoutConstraintOrientationHorizontal;
        if (v == NSViewNoIntrinsicMetric) {
            CGFloat f = axis ? fit.height : fit.width;
            lo[axis] = f;
            id[axis] = f;
            hi[axis] = CGFLOAT_MAX;
        } else {
            v = MAX(v, 0);
            id[axis] = v;
            lo[axis] = [self contentCompressionResistancePriorityForOrientation:o] > priority ? v : 0;
            hi[axis] = [self contentHuggingPriorityForOrientation:o] > priority ? v : CGFLOAT_MAX;
        }
    }
    if (min)
        *min = CGSizeMake(lo[0], lo[1]);
    if (max)
        *max = CGSizeMake(hi[0], hi[1]);
    if (ideal)
        *ideal = CGSizeMake(id[0], id[1]);
}

- (void)measureMin:(CGSize *)min max:(CGSize *)max ideal:(CGSize *)ideal
{
    [self measureMin:min max:max ideal:ideal stretchingPriority:NSLayoutPriorityDefaultLow];
}

@end

#pragma mark - Accessibility overrides

static char override_values_key, override_handlers_key;

@implementation NSObject (FinchAccessibilityOverrides)

- (BOOL)_accessibilitySetOverrideValue:(id)value forAttribute:(NSAccessibilityAttributeName)attribute
{
    NSMutableDictionary *d = objc_getAssociatedObject(self, &override_values_key);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &override_values_key, d, OBJC_ASSOCIATION_RETAIN);
    }
    if (value)
        d[attribute] = value;
    else
        [d removeObjectForKey:attribute];
    return YES;
}

- (BOOL)_accessibilitySetOverrideHandler:(id (^)(void))handler forAttribute:(NSAccessibilityAttributeName)attribute
{
    NSMutableDictionary *d = objc_getAssociatedObject(self, &override_handlers_key);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &override_handlers_key, d, OBJC_ASSOCIATION_RETAIN);
    }
    if (handler)
        d[attribute] = [[handler copy] autorelease];
    else
        [d removeObjectForKey:attribute];
    return YES;
}

@end

#pragma mark - Small properties

@implementation NSApplication (FinchPrivateSPI)
- (BOOL)_shouldLoadMainNibNamed:(NSString *)name { return YES; }
- (BOOL)_shouldLoadMainStoryboardNamed:(NSString *)name { return YES; }
@end

/* Finch's appearances take the accent from the theme; a tint is kept for the caller only. */
@implementation NSAppearance (FinchPrivateSPI)
- (NSAppearance *)appearanceByApplyingTintColor:(NSColor *)tintColor { return self; }
@end

static char progress_font_key, image_description_key;

@implementation NSProgressIndicator (FinchPrivateSPI)
- (NSFont *)font { return objc_getAssociatedObject(self, &progress_font_key); }
- (void)setFont:(NSFont *)font { objc_setAssociatedObject(self, &progress_font_key, font, OBJC_ASSOCIATION_RETAIN); }
@end

@implementation NSImage (FinchPrivateSPI)
- (NSString *)_defaultAccessibilityDescription { return objc_getAssociatedObject(self, &image_description_key); }
- (void)_setDefaultAccessibilityDescription:(NSString *)s
{
    objc_setAssociatedObject(self, &image_description_key, s, OBJC_ASSOCIATION_COPY);
}
@end

@implementation NSWorkspace (FinchPrivateSPI)
- (BOOL)isAccessibilityFullKeyboardAccessEnabled { return NO; }
@end

@implementation NSGestureRecognizer (FinchPrivateSPI)
- (void)_updateForActiveEvents {}
- (BOOL)_hasUnmetFailureRequirements { return NO; }
@end

#pragma mark - Constraint-based layout hosting

/* Whether a view hosts its own layout engine (private; Finch's engine is per root). */
static char hosts_engine_key;

@implementation NSView (FinchLayoutEngineHosting)
- (void)_setHostsLayoutEngine:(BOOL)flag
{
    objc_setAssociatedObject(self, &hosts_engine_key, flag ? @YES : nil, OBJC_ASSOCIATION_RETAIN);
}
- (BOOL)_hostsLayoutEngine { return objc_getAssociatedObject(self, &hosts_engine_key) != nil; }
@end

typedef struct {
    CGFloat firstTextBaseline;
    CGFloat lastTextBaseline;
} FinchBaselineOffset;

/*
 * A view that holds one hosted view pinned to its edges and measures it through Auto
 * Layout: SwiftUI hosts AppKit views (NSViewRepresentable) in one.
 */
__attribute__((visibility("default")))
@interface _NSConstraintBasedLayoutHostingView : NSView {
    BOOL _hasAddedConstraints;
}
@property (retain, nullable) NSView *hostedView;
- (instancetype)initWithHostedView:(NSView *)view;
@end

@implementation _NSConstraintBasedLayoutHostingView {
    NSView *_hosted;
    NSArray *_pins;
}

+ (BOOL)requiresConstraintBasedLayout { return YES; }

- (instancetype)initWithHostedView:(NSView *)view
{
    if ((self = [super initWithFrame:view ? [view frame] : NSZeroRect]))
        [self setHostedView:view];
    return self;
}

- (void)dealloc
{
    [_pins release];
    [_hosted release];
    [super dealloc];
}

- (NSView *)hostedView { return _hosted; }

- (void)setHostedView:(NSView *)view
{
    if (view == _hosted)
        return;
    if (_pins)
        [NSLayoutConstraint deactivateConstraints:_pins];
    [_pins release];
    _pins = nil;
    [_hosted removeFromSuperview];
    [_hosted release];
    _hosted = [view retain];
    _hasAddedConstraints = NO;
    if (view) {
        [view setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self addSubview:view];
        [self setNeedsUpdateConstraints:YES];
    }
    [self invalidateIntrinsicContentSize];
}

- (void)updateConstraints
{
    if (_hosted && !_hasAddedConstraints) {
        _pins = [@[
            [[_hosted leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
            [[_hosted trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
            [[_hosted topAnchor] constraintEqualToAnchor:[self topAnchor]],
            [[_hosted bottomAnchor] constraintEqualToAnchor:[self bottomAnchor]],
        ] retain];
        [NSLayoutConstraint activateConstraints:_pins];
        _hasAddedConstraints = YES;
    }
    [super updateConstraints];
}

- (void)willRemoveSubview:(NSView *)subview
{
    if (subview == _hosted) {
        if (_pins)
            [NSLayoutConstraint deactivateConstraints:_pins];
        [_pins release];
        _pins = nil;
        _hasAddedConstraints = NO;
    }
    [super willRemoveSubview:subview];
}

/* The hosted view's size within `fits`: its fitting size, with the fixed axes (bit 0 the
   width, bit 1 the height) held at the proposal. */
- (CGSize)_layoutSizeThatFits:(CGSize)fits fixedAxes:(unsigned long long)axes
{
    if (!_hosted)
        return CGSizeZero;
    NSSize intrinsic = [_hosted intrinsicContentSize];
    NSSize fit = [_hosted fittingSize];
    CGSize s = CGSizeMake(intrinsic.width != NSViewNoIntrinsicMetric ? intrinsic.width : fit.width,
                          intrinsic.height != NSViewNoIntrinsicMetric ? intrinsic.height : fit.height);
    if (axes & 1)
        s.width = fits.width;
    if (axes & 2)
        s.height = fits.height;
    return s;
}

- (CGSize)sizeThatFits:(CGSize)fits { return [self _layoutSizeThatFits:fits fixedAxes:0]; }
- (void)sizeToFit { [self setFrameSize:NSSizeFromCGSize([self sizeThatFits:CGSizeZero])]; }
- (BOOL)_layoutHeightDependsOnWidth { return NO; }
- (NSSize)intrinsicContentSize { return _hosted ? [_hosted intrinsicContentSize] : [super intrinsicContentSize]; }
- (NSEdgeInsets)alignmentRectInsets { return _hosted ? [_hosted alignmentRectInsets] : [super alignmentRectInsets]; }

- (void)_setFrameWithAlignmentRect:(CGRect)rect
{
    [self setFrame:[self frameForAlignmentRect:NSRectFromCGRect(rect)]];
}

- (FinchBaselineOffset)_baselineOffsetsAtSize:(CGSize)size
{
    FinchBaselineOffset b = {0, 0};
    if (_hosted) {
        b.firstTextBaseline = [_hosted firstBaselineOffsetFromTop];
        b.lastTextBaseline = [_hosted lastBaselineOffsetFromBottom];
    }
    return b;
}

- (void)_intrinsicContentSizeInvalidatedForChildView:(NSView *)view { [self invalidateIntrinsicContentSize]; }
- (void)_layoutMetricsInvalidatedForHostedView { [self invalidateIntrinsicContentSize]; }
- (void)_informContainerThatSubviewsNeedUpdateConstraints { [self setNeedsUpdateConstraints:YES]; }
- (void)constraintsDidChangeInEngine:(id)engine {}

@end
