/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSResponder: the responder chain. An event method a responder doesn't
 * implement passes the event to its next responder; at the end of the chain
 * a key down beeps (-noResponderFor:) and everything else is dropped.
 */
#import <AppKit/AppKit.h>
#import "AppKit_Finch.h"

@implementation NSResponder {
    NSResponder *_nextResponder;  /* not retained, as Apple's */
    NSMenu *_menu;
}

- (instancetype)init
{
    return [super init];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self && [coder allowsKeyedCoding]) {
        _nextResponder = [coder decodeObjectForKey:@"NSNextResponder"];
        _menu = [[coder decodeObjectForKey:@"NSMenu"] retain];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_nextResponder)
        [coder encodeConditionalObject:_nextResponder forKey:@"NSNextResponder"];
    if (_menu)
        [coder encodeObject:_menu forKey:@"NSMenu"];
}

- (void)dealloc
{
    [_menu release];
    [super dealloc];
}

- (NSResponder *)nextResponder
{
    return _nextResponder;
}

- (void)setNextResponder:(NSResponder *)next
{
    _nextResponder = next;
}

- (BOOL)acceptsFirstResponder
{
    return NO;
}

- (BOOL)becomeFirstResponder
{
    return YES;
}

- (BOOL)resignFirstResponder
{
    return YES;
}

- (BOOL)validateProposedFirstResponder:(NSResponder *)responder forEvent:(NSEvent *)event
{
    return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    return NO;
}

- (BOOL)tryToPerform:(SEL)action with:(id)object
{
    if ([self respondsToSelector:action]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, action, object);
        return YES;
    }
    return [_nextResponder tryToPerform:action with:object];
}

- (void)noResponderFor:(SEL)eventSelector
{
    if (eventSelector == @selector(keyDown:))
        NSBeep();
}

- (id)supplementalTargetForAction:(SEL)action sender:(id)sender
{
    return nil;
}

- (id)validRequestorForSendType:(NSPasteboardType)sendType returnType:(NSPasteboardType)returnType
{
    return [_nextResponder validRequestorForSendType:sendType returnType:returnType];
}

- (NSMenu *)menu
{
    if (object_getClass(self) == [NSResponder class])
        [NSException raise:NSGenericException
                    format:@"Abstract method -[NSResponder menu:] called from class NSResponder.  Subclasses must override."];
    return _menu;
}

- (void)setMenu:(NSMenu *)menu
{
    [menu retain];
    [_menu release];
    _menu = menu;
}

- (NSUndoManager *)undoManager
{
    return [_nextResponder undoManager];
}

- (BOOL)shouldBeTreatedAsInkEvent:(NSEvent *)event
{
    return NO;
}

- (BOOL)wantsScrollEventsForSwipeTrackingOnAxis:(NSEventGestureAxis)axis
{
    return NO;
}

- (BOOL)wantsForwardedScrollEventsForAxis:(NSEventGestureAxis)axis
{
    return NO;
}

- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events
{
    for (NSEvent *event in events)
        FinchInterpretKeyEvent(self, event);
}

- (void)flushBufferedKeyEvents
{
}

- (BOOL)presentError:(NSError *)error
{
    NSResponder *next = _nextResponder;
    if (next)
        return [next presentError:[self willPresentError:error]];
    return [NSApp presentError:[self willPresentError:error]];
}

- (void)presentError:(NSError *)error modalForWindow:(NSWindow *)window delegate:(id)delegate
    didPresentSelector:(SEL)didPresentSelector contextInfo:(void *)contextInfo
{
    error = [self willPresentError:error];
    if (_nextResponder)
        [_nextResponder presentError:error modalForWindow:window delegate:delegate
                  didPresentSelector:didPresentSelector contextInfo:contextInfo];
    else
        [NSApp presentError:error modalForWindow:window delegate:delegate didPresentSelector:didPresentSelector
                contextInfo:contextInfo];
}

- (NSError *)willPresentError:(NSError *)error
{
    return error;
}

- (BOOL)performMnemonic:(NSString *)string
{
    return NO;
}

- (void)showContextHelp:(id)sender
{
}

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder
{
}

- (void)restoreStateWithCoder:(NSCoder *)coder
{
}

/* Window restoration isn't kept between launches yet: there's nothing to mark stale. */
- (void)invalidateRestorableState {}
+ (NSArray<NSString *> *)restorableStateKeyPaths { return @[]; }

/* Events go up the chain; at its end, -noResponderFor:. */
#define FORWARD(sel)                                \
    -(void)sel:(NSEvent *)event                     \
    {                                               \
        if (_nextResponder)                         \
            [_nextResponder sel:event];             \
        else                                        \
            [self noResponderFor:@selector(sel:)];  \
    }

FORWARD(mouseDown)
FORWARD(rightMouseDown)
FORWARD(otherMouseDown)
FORWARD(mouseUp)
FORWARD(rightMouseUp)
FORWARD(otherMouseUp)
FORWARD(mouseMoved)
FORWARD(mouseDragged)
FORWARD(mouseCancelled)
FORWARD(scrollWheel)
FORWARD(rightMouseDragged)
FORWARD(otherMouseDragged)
FORWARD(mouseEntered)
FORWARD(mouseExited)
FORWARD(keyDown)
FORWARD(keyUp)
FORWARD(flagsChanged)
FORWARD(tabletPoint)
FORWARD(tabletProximity)
FORWARD(cursorUpdate)
FORWARD(magnifyWithEvent)
FORWARD(rotateWithEvent)
FORWARD(swipeWithEvent)
FORWARD(beginGestureWithEvent)
FORWARD(endGestureWithEvent)
FORWARD(smartMagnifyWithEvent)
FORWARD(changeModeWithEvent)
FORWARD(touchesBeganWithEvent)
FORWARD(touchesMovedWithEvent)
FORWARD(touchesEndedWithEvent)
FORWARD(touchesCancelledWithEvent)
FORWARD(quickLookWithEvent)
FORWARD(pressureChangeWithEvent)
FORWARD(contextMenuKeyDown)
#undef FORWARD

- (void)helpRequested:(NSEvent *)event
{
    [_nextResponder helpRequested:event];
}

/* NSStandardKeyBindingResponding: text-editing actions go up the chain. */
- (void)doCommandBySelector:(SEL)selector
{
    if (![self tryToPerform:selector with:nil])
        NSBeep();
}

- (void)insertText:(id)insertString
{
    if (_nextResponder)
        [_nextResponder insertText:insertString];
    else
        NSBeep();
}

@end
