/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Cocoa bindings inside AppKit (NSKeyValueBinding.m, NSController.m): the
 * hooks controls call when the user changes their value, and what the
 * controllers share with the binding machinery.
 */
#ifndef NSKEYVALUEBINDING_FINCH_H
#define NSKEYVALUEBINDING_FINCH_H

#import "AppKit_Finch.h"

/* A control is about to send its action (NSControl's -sendAction:to:, even
 * without an action): its value-like bindings take the control's value. */
FINCH_PRIVATE void FinchBindingsControlWillSendAction(NSControl *control);

/* The field editor began editing a control, changed its text, or ended. */
enum { FinchEditBegan, FinchEditChanged, FinchEditEnded };
FINCH_PRIVATE void FinchBindingsControlEdited(NSControl *control, int phase);

/* The binding object for `binding` on `object`, or nil. */
FINCH_PRIVATE id FinchBindingFor(id object, NSString *binding);
/* Give the bound object a value, as the user would have (reverse-transformed). */
FINCH_PRIVATE void FinchBindingPush(id object, NSString *binding, id value);

/* A binding: the receiver (not retained), the bound object and key path, the options
   (every option the binding understands, NSNull where unset). */
@interface _FinchBinding : NSObject <NSEditor> {
@public
    id _owner; /* not retained */
    NSString *_name;
    id _observed;
    NSString *_keyPath;
    NSString *_observedPath; /* what KVO watches: the key path, or up to a collection in it */
    NSDictionary *_options;
    NSValueTransformer *_transformer;
    BOOL _pushing, _editing, _connected;
}
- (void)_finchConnect;
- (void)_finchDisconnect;
- (id)rawValue;
- (id)valueWithKind:(int *)kind;
- (id)displayValueWithKind:(int *)kind;
- (void)push:(id)value;
- (void)_finchBeginEditing;
- (void)_finchEndEditing;
@end

/* What the classes here (and the controllers, NSController.m) implement for their bindings. */
@interface NSObject (FinchBindings)
+ (NSArray *)_finchBuiltinBindings;
- (BOOL)_finchHandlesBinding:(NSString *)binding;
- (NSDictionary *)_finchDefaultOptionsForBinding:(NSString *)binding;
- (Class)_finchValueClassForBinding:(NSString *)binding;
- (void)_finchBindingChanged:(_FinchBinding *)binding;
- (void)_finchPushBinding:(_FinchBinding *)binding;
- (void)_finchBindingRemoved:(NSString *)binding;
- (void)_finchWillSendAction;
@end

#endif
