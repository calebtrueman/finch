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

/* As Apple's: the smallest size the view's constraints allow, unbounded above, and that as ideal. */
- (void)measureMin:(CGSize *)min max:(CGSize *)max ideal:(CGSize *)ideal stretchingPriority:(float)priority
{
    NSSize fit = [self fittingSize];
    if (min)
        *min = NSSizeToCGSize(fit);
    if (max)
        *max = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);
    if (ideal)
        *ideal = NSSizeToCGSize(fit);
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
