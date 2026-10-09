/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Gesture recognizers: NSGestureRecognizer and the click, pan, press,
 * magnification and rotation recognizers, with views' -gestureRecognizers.
 *
 * The window shows a mouse event to the recognizers of the view it hits and
 * of that view's ancestors before the view gets it (NSWindow.m calls
 * FinchGestureRecognizersHandleEvent); a recognizer that recognizes sends
 * its action to its target. The state machine is Apple's: possible, then
 * began/changed/ended for continuous gestures, recognized for discrete
 * ones, or failed; back to possible after the gesture.
 */
#import "NSView_Finch.h"
#import <objc/message.h>
#import <objc/runtime.h>

@implementation NSGestureRecognizer {
@protected
    id _target;  /* weak */
    SEL _action;
    NSGestureRecognizerState _state;
    id<NSGestureRecognizerDelegate> _delegate;  /* weak */
    NSView *_view;                              /* not retained: the view keeps its recognizers */
    NSString *_name;
    NSPressureConfiguration *_pressure;
    NSEventModifierFlags _modifiers;
    NSPoint _location;  /* in the window */
    NSTouchTypeMask _touchTypes;
    struct {
        unsigned disabled : 1;
        unsigned primary : 1, secondary : 1, other : 1, key : 1, magnification : 1, rotation : 1;
    } _f;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action
{
    self = [super init];
    if (self) {
        _target = target;
        _action = action;
        _touchTypes = NSTouchTypeMaskDirect;
    }
    return self;
}

- (instancetype)init { return [self initWithTarget:nil action:NULL]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self initWithTarget:[coder decodeObjectForKey:@"NSGestureRecognizer.target"]
                         action:NSSelectorFromString([coder decodeObjectForKey:@"NSGestureRecognizer.action"])];
    if (self) {
        _delegate = [coder decodeObjectForKey:@"NSGestureRecognizer.delegate"];
        if ([coder containsValueForKey:@"NSGestureRecognizer.enabled"])
            _f.disabled = ![coder decodeBoolForKey:@"NSGestureRecognizer.enabled"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {}

- (void)dealloc
{
    [_name release];
    [_pressure release];
    [super dealloc];
}

- (id)target { return _target; }
- (void)setTarget:(id)t { _target = t; }
- (SEL)action { return _action; }
- (void)setAction:(SEL)a { _action = a; }
- (NSGestureRecognizerState)state { return _state; }
- (id<NSGestureRecognizerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSGestureRecognizerDelegate>)d { _delegate = d; }
- (BOOL)isEnabled { return !_f.disabled; }
- (void)setEnabled:(BOOL)f
{
    _f.disabled = !f;
    if (!f && _state != NSGestureRecognizerStatePossible)
        [self _finchFinish];
}
- (NSView *)view { return _view; }
- (void)_finchSetView:(NSView *)v { _view = v; }
- (NSPressureConfiguration *)pressureConfiguration { return _pressure; }
- (void)setPressureConfiguration:(NSPressureConfiguration *)p { [_pressure autorelease]; _pressure = [p retain]; }
- (NSString *)name { return _name; }
- (void)setName:(NSString *)n { [_name autorelease]; _name = [n copy]; }
- (NSEventModifierFlags)modifierFlags { return _modifiers; }
- (NSTouchTypeMask)allowedTouchTypes { return _touchTypes; }
- (void)setAllowedTouchTypes:(NSTouchTypeMask)m { _touchTypes = m; }

#define DELAYS_EVENTS(get, set, bit) \
    -(BOOL)get { return _f.bit; } \
    -(void)set:(BOOL)v { _f.bit = v; }
DELAYS_EVENTS(delaysPrimaryMouseButtonEvents, setDelaysPrimaryMouseButtonEvents, primary)
DELAYS_EVENTS(delaysSecondaryMouseButtonEvents, setDelaysSecondaryMouseButtonEvents, secondary)
DELAYS_EVENTS(delaysOtherMouseButtonEvents, setDelaysOtherMouseButtonEvents, other)
DELAYS_EVENTS(delaysKeyEvents, setDelaysKeyEvents, key)
DELAYS_EVENTS(delaysMagnificationEvents, setDelaysMagnificationEvents, magnification)
DELAYS_EVENTS(delaysRotationEvents, setDelaysRotationEvents, rotation)
#undef DELAYS_EVENTS

- (NSPoint)locationInView:(NSView *)view
{
    return view ? [view convertPoint:_location fromView:nil] : _location;
}

/* Subclasses set the state; the action goes out on began, changed, ended and recognized. */
- (void)setState:(NSGestureRecognizerState)state
{
    if (state == NSGestureRecognizerStateBegan && [(id)_delegate respondsToSelector:@selector(gestureRecognizerShouldBegin:)] &&
        ![_delegate gestureRecognizerShouldBegin:self])
        state = NSGestureRecognizerStateFailed;
    _state = state;
    if (state == NSGestureRecognizerStateBegan || state == NSGestureRecognizerStateChanged ||
        state == NSGestureRecognizerStateEnded) {
        /* straight to the target when there is one; the responder chain otherwise */
        if (_action && _target && [_target respondsToSelector:_action])
            ((void (*)(id, SEL, id))objc_msgSend)(_target, _action, self);
        else if (_action)
            [NSApp sendAction:_action to:_target from:self];
    }
    if (state == NSGestureRecognizerStateEnded || state == NSGestureRecognizerStateCancelled ||
        state == NSGestureRecognizerStateFailed)
        [self performSelector:@selector(_finchFinish) withObject:nil afterDelay:0];
}

- (void)_finchFinish
{
    [self reset];
    _state = NSGestureRecognizerStatePossible;
}

- (void)reset {}
- (BOOL)canPreventGestureRecognizer:(NSGestureRecognizer *)other { return YES; }
- (BOOL)canBePreventedByGestureRecognizer:(NSGestureRecognizer *)other { return YES; }
- (BOOL)shouldRequireFailureOfGestureRecognizer:(NSGestureRecognizer *)other { return NO; }
- (BOOL)shouldBeRequiredToFailByGestureRecognizer:(NSGestureRecognizer *)other { return NO; }

- (void)mouseDown:(NSEvent *)event {}
- (void)rightMouseDown:(NSEvent *)event {}
- (void)otherMouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {}
- (void)rightMouseUp:(NSEvent *)event {}
- (void)otherMouseUp:(NSEvent *)event {}
- (void)mouseDragged:(NSEvent *)event {}
- (void)rightMouseDragged:(NSEvent *)event {}
- (void)otherMouseDragged:(NSEvent *)event {}
- (void)mouseCancelled:(NSEvent *)event {}
- (void)keyDown:(NSEvent *)event {}
- (void)keyUp:(NSEvent *)event {}
- (void)flagsChanged:(NSEvent *)event {}
- (void)tabletPoint:(NSEvent *)event {}
- (void)magnifyWithEvent:(NSEvent *)event {}
- (void)rotateWithEvent:(NSEvent *)event {}
- (void)pressureChangeWithEvent:(NSEvent *)event {}
- (void)touchesBeganWithEvent:(NSEvent *)event {}
- (void)touchesMovedWithEvent:(NSEvent *)event {}
- (void)touchesEndedWithEvent:(NSEvent *)event {}
- (void)touchesCancelledWithEvent:(NSEvent *)event {}

/* Sees an event first (NSWindow.m); answers whether the view should not get it. */
- (BOOL)_finchHandleEvent:(NSEvent *)event
{
    if (_f.disabled)
        return NO;
    if ([(id)_delegate respondsToSelector:@selector(gestureRecognizer:shouldAttemptToRecognizeWithEvent:)] &&
        ![_delegate gestureRecognizer:self shouldAttemptToRecognizeWithEvent:event])
        return NO;
    _location = [event locationInWindow];
    _modifiers = [event modifierFlags];
    switch ([event type]) {
    case NSEventTypeLeftMouseDown: [self mouseDown:event]; return _f.primary;
    case NSEventTypeLeftMouseUp: [self mouseUp:event]; return _f.primary;
    case NSEventTypeLeftMouseDragged: [self mouseDragged:event]; return _f.primary;
    case NSEventTypeRightMouseDown: [self rightMouseDown:event]; return _f.secondary;
    case NSEventTypeRightMouseUp: [self rightMouseUp:event]; return _f.secondary;
    case NSEventTypeRightMouseDragged: [self rightMouseDragged:event]; return _f.secondary;
    case NSEventTypeOtherMouseDown: [self otherMouseDown:event]; return _f.other;
    case NSEventTypeOtherMouseUp: [self otherMouseUp:event]; return _f.other;
    case NSEventTypeOtherMouseDragged: [self otherMouseDragged:event]; return _f.other;
    case NSEventTypeKeyDown: [self keyDown:event]; return _f.key;
    case NSEventTypeKeyUp: [self keyUp:event]; return _f.key;
    case NSEventTypeFlagsChanged: [self flagsChanged:event]; return NO;
    case NSEventTypeMagnify: [self magnifyWithEvent:event]; return _f.magnification;
    case NSEventTypeRotate: [self rotateWithEvent:event]; return _f.rotation;
    default: return NO;
    }
}

@end

/* The button numbers a buttonMask names: bit 0 the left button, bit 1 the right, and so on. */
static BOOL
button_in_mask(NSEvent *event, NSUInteger mask)
{
    return (mask & (1u << [event buttonNumber])) != 0;
}

#pragma mark Click

@implementation NSClickGestureRecognizer {
    NSUInteger _buttonMask;
    NSInteger _clicks, _touches, _count;
    NSPoint _down;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action
{
    self = [super initWithTarget:target action:action];
    if (self) {
        _buttonMask = 1;
        _clicks = 1;
        _touches = 1;
        [self setDelaysPrimaryMouseButtonEvents:YES];
    }
    return self;
}

- (NSUInteger)buttonMask { return _buttonMask; }
- (void)setButtonMask:(NSUInteger)m { _buttonMask = m; }
- (NSInteger)numberOfClicksRequired { return _clicks; }
- (void)setNumberOfClicksRequired:(NSInteger)n { _clicks = n; }
- (NSInteger)numberOfTouchesRequired { return _touches; }
- (void)setNumberOfTouchesRequired:(NSInteger)n { _touches = n; }

- (void)_down:(NSEvent *)e
{
    if (!button_in_mask(e, _buttonMask))
        return;
    _down = [e locationInWindow];
    _count = [e clickCount];
}

/* Recognized on the up of the click that makes the count, if it stayed near where it went down. */
- (void)_up:(NSEvent *)e
{
    if (!button_in_mask(e, _buttonMask) || [self state] != NSGestureRecognizerStatePossible)
        return;
    NSPoint p = [e locationInWindow];
    if (fabs(p.x - _down.x) > 4 || fabs(p.y - _down.y) > 4)
        [self setState:NSGestureRecognizerStateFailed];
    else if (_count >= _clicks)
        [self setState:NSGestureRecognizerStateEnded];
}

- (void)mouseDown:(NSEvent *)e { [self _down:e]; }
- (void)rightMouseDown:(NSEvent *)e { [self _down:e]; }
- (void)otherMouseDown:(NSEvent *)e { [self _down:e]; }
- (void)mouseUp:(NSEvent *)e { [self _up:e]; }
- (void)rightMouseUp:(NSEvent *)e { [self _up:e]; }
- (void)otherMouseUp:(NSEvent *)e { [self _up:e]; }

@end

#pragma mark Pan

@implementation NSPanGestureRecognizer {
    NSUInteger _buttonMask;
    NSInteger _touches;
    NSPoint _start, _last, _velocity, _offset;
    NSTimeInterval _lastTime;
    BOOL _down;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action
{
    self = [super initWithTarget:target action:action];
    if (self) {
        _buttonMask = 1;
        _touches = 1;
    }
    return self;
}

- (NSUInteger)buttonMask { return _buttonMask; }
- (void)setButtonMask:(NSUInteger)m { _buttonMask = m; }
- (NSInteger)numberOfTouchesRequired { return _touches; }
- (void)setNumberOfTouchesRequired:(NSInteger)n { _touches = n; }

- (NSPoint)translationInView:(NSView *)view
{
    NSPoint a = [self locationInView:view], b = view ? [view convertPoint:_start fromView:nil] : _start;
    return NSMakePoint(a.x - b.x + _offset.x, a.y - b.y + _offset.y);
}

- (void)setTranslation:(NSPoint)t inView:(NSView *)view
{
    NSPoint a = [self locationInView:view], b = view ? [view convertPoint:_start fromView:nil] : _start;
    _offset = NSMakePoint(t.x - (a.x - b.x), t.y - (a.y - b.y));
}

- (NSPoint)velocityInView:(NSView *)view { return _velocity; }

- (void)reset
{
    _down = NO;
    _offset = NSZeroPoint;
    _velocity = NSZeroPoint;
}

- (void)_down:(NSEvent *)e
{
    if (!button_in_mask(e, _buttonMask))
        return;
    _down = YES;
    _start = _last = [e locationInWindow];
    _lastTime = [e timestamp];
}

/* Begins once the pointer has moved, then changes with each drag. */
- (void)_dragged:(NSEvent *)e
{
    if (!_down)
        return;
    NSPoint p = [e locationInWindow];
    NSTimeInterval dt = [e timestamp] - _lastTime;
    if (dt > 0)
        _velocity = NSMakePoint((p.x - _last.x) / dt, (p.y - _last.y) / dt);
    _last = p;
    _lastTime = [e timestamp];
    [self setState:[self state] == NSGestureRecognizerStatePossible ? NSGestureRecognizerStateBegan
                                                                     : NSGestureRecognizerStateChanged];
}

- (void)_up:(NSEvent *)e
{
    if (!_down)
        return;
    _down = NO;
    NSGestureRecognizerState s = [self state];
    if (s == NSGestureRecognizerStateBegan || s == NSGestureRecognizerStateChanged)
        [self setState:NSGestureRecognizerStateEnded];
    else
        [self setState:NSGestureRecognizerStateFailed];
}

- (void)mouseDown:(NSEvent *)e { [self _down:e]; }
- (void)rightMouseDown:(NSEvent *)e { [self _down:e]; }
- (void)otherMouseDown:(NSEvent *)e { [self _down:e]; }
- (void)mouseDragged:(NSEvent *)e { [self _dragged:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self _dragged:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self _dragged:e]; }
- (void)mouseUp:(NSEvent *)e { [self _up:e]; }
- (void)rightMouseUp:(NSEvent *)e { [self _up:e]; }
- (void)otherMouseUp:(NSEvent *)e { [self _up:e]; }

@end

#pragma mark Press

@implementation NSPressGestureRecognizer {
    NSUInteger _buttonMask;
    NSInteger _touches;
    NSTimeInterval _duration;
    CGFloat _movement;
    NSPoint _down;
    BOOL _pressing;
}

/* As Apple's: half a second, 5 points (the double-click time and distance). */
- (instancetype)initWithTarget:(id)target action:(SEL)action
{
    self = [super initWithTarget:target action:action];
    if (self) {
        _buttonMask = 1;
        _touches = 1;
        _duration = 0.5;
        _movement = 5;
    }
    return self;
}

- (NSUInteger)buttonMask { return _buttonMask; }
- (void)setButtonMask:(NSUInteger)m { _buttonMask = m; }
- (NSInteger)numberOfTouchesRequired { return _touches; }
- (void)setNumberOfTouchesRequired:(NSInteger)n { _touches = n; }
- (NSTimeInterval)minimumPressDuration { return _duration; }
- (void)setMinimumPressDuration:(NSTimeInterval)d { _duration = d; }
- (CGFloat)allowableMovement { return _movement; }
- (void)setAllowableMovement:(CGFloat)m { _movement = m; }

- (void)reset
{
    _pressing = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_held) object:nil];
}

- (void)_held
{
    if (_pressing && [self state] == NSGestureRecognizerStatePossible)
        [self setState:NSGestureRecognizerStateBegan];
}

- (void)_down:(NSEvent *)e
{
    if (!button_in_mask(e, _buttonMask))
        return;
    _pressing = YES;
    _down = [e locationInWindow];
    [self performSelector:@selector(_held) withObject:nil afterDelay:_duration
                  inModes:@[ NSDefaultRunLoopMode, NSEventTrackingRunLoopMode ]];
}

- (void)_dragged:(NSEvent *)e
{
    if (!_pressing)
        return;
    NSPoint p = [e locationInWindow];
    BOOL far = hypot(p.x - _down.x, p.y - _down.y) > _movement;
    if ([self state] == NSGestureRecognizerStatePossible) {
        if (far) {
            _pressing = NO;
            [self setState:NSGestureRecognizerStateFailed];
        }
    } else {
        [self setState:NSGestureRecognizerStateChanged];
    }
}

- (void)_up:(NSEvent *)e
{
    if (!_pressing)
        return;
    _pressing = NO;
    NSGestureRecognizerState s = [self state];
    [self setState:s == NSGestureRecognizerStatePossible ? NSGestureRecognizerStateFailed : NSGestureRecognizerStateEnded];
}

- (void)mouseDown:(NSEvent *)e { [self _down:e]; }
- (void)rightMouseDown:(NSEvent *)e { [self _down:e]; }
- (void)otherMouseDown:(NSEvent *)e { [self _down:e]; }
- (void)mouseDragged:(NSEvent *)e { [self _dragged:e]; }
- (void)rightMouseDragged:(NSEvent *)e { [self _dragged:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self _dragged:e]; }
- (void)mouseUp:(NSEvent *)e { [self _up:e]; }
- (void)rightMouseUp:(NSEvent *)e { [self _up:e]; }
- (void)otherMouseUp:(NSEvent *)e { [self _up:e]; }

@end

#pragma mark Magnification and rotation (trackpad gestures)

@implementation NSMagnificationGestureRecognizer {
    CGFloat _magnification;
}

- (CGFloat)magnification { return _magnification; }
- (void)setMagnification:(CGFloat)m { _magnification = m; }
- (void)reset { _magnification = 0; }

- (void)magnifyWithEvent:(NSEvent *)e
{
    _magnification += [e magnification];
    NSEventPhase phase = [e phase];
    if (phase == NSEventPhaseEnded || phase == NSEventPhaseCancelled)
        [self setState:NSGestureRecognizerStateEnded];
    else
        [self setState:[self state] == NSGestureRecognizerStatePossible ? NSGestureRecognizerStateBegan
                                                                         : NSGestureRecognizerStateChanged];
}

@end

@implementation NSRotationGestureRecognizer {
    CGFloat _rotation;  /* radians */
}

- (CGFloat)rotation { return _rotation; }
- (void)setRotation:(CGFloat)r { _rotation = r; }
- (CGFloat)rotationInDegrees { return _rotation * 180 / M_PI; }
- (void)setRotationInDegrees:(CGFloat)d { _rotation = d * M_PI / 180; }
- (void)reset { _rotation = 0; }

/* The event's rotation is in degrees, counterclockwise. */
- (void)rotateWithEvent:(NSEvent *)e
{
    _rotation += [e rotation] * M_PI / 180;
    NSEventPhase phase = [e phase];
    if (phase == NSEventPhaseEnded || phase == NSEventPhaseCancelled)
        [self setState:NSGestureRecognizerStateEnded];
    else
        [self setState:[self state] == NSGestureRecognizerStatePossible ? NSGestureRecognizerStateBegan
                                                                         : NSGestureRecognizerStateChanged];
}

@end

#pragma mark Views

@implementation NSView (NSGestureRecognizer)

static const void *kRecognizers = &kRecognizers;

- (NSArray<NSGestureRecognizer *> *)gestureRecognizers
{
    return [[objc_getAssociatedObject(self, kRecognizers) copy] autorelease] ?: @[];
}

- (void)setGestureRecognizers:(NSArray<NSGestureRecognizer *> *)recognizers
{
    for (NSGestureRecognizer *g in [self gestureRecognizers])
        [self removeGestureRecognizer:g];
    for (NSGestureRecognizer *g in recognizers)
        [self addGestureRecognizer:g];
}

- (void)addGestureRecognizer:(NSGestureRecognizer *)g
{
    if (!g)
        return;
    [[g view] removeGestureRecognizer:g];
    NSMutableArray *a = objc_getAssociatedObject(self, kRecognizers);
    if (!a) {
        a = [NSMutableArray array];
        objc_setAssociatedObject(self, kRecognizers, a, OBJC_ASSOCIATION_RETAIN);
    }
    [a addObject:g];
    [g _finchSetView:self];
}

- (void)removeGestureRecognizer:(NSGestureRecognizer *)g
{
    NSMutableArray *a = objc_getAssociatedObject(self, kRecognizers);
    if (![a containsObject:g])
        return;
    [g _finchSetView:nil];
    [a removeObjectIdenticalTo:g];
}

@end

/*
 * The recognizers of the hit view and its ancestors see the event first
 * (NSWindow.m). Answers YES when one of them that recognizes, or is still
 * deciding and delays such events, keeps it from the view.
 */
BOOL
FinchGestureRecognizersHandleEvent(NSView *hit, NSEvent *event)
{
    BOOL withhold = NO;
    for (NSView *v = hit; v; v = [v superview]) {
        NSArray *rs = objc_getAssociatedObject(v, kRecognizers);
        for (NSGestureRecognizer *g in [[rs copy] autorelease])
            if ([g _finchHandleEvent:event])
                withhold = YES;
    }
    return withhold;
}

/* NSWindow.m's hook: the recognizers of the view and its ancestors see the event before the view does. */
@implementation NSView (FinchGestureDelivery)
- (void)_finchDeliverGestureEvent:(NSEvent *)event selector:(SEL)selector
{
    FinchGestureRecognizersHandleEvent(self, event);
}
@end
