/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSEvent: an input event. Events from the window server (FWSEvent) are
 * turned into NSEvents here; apps can also make their own. Which accessors
 * are valid for which event type, and the exception and description an
 * invalid one gives, are as measured on macOS 26.4.
 */
#import "AppKit_Finch.h"

#define MOUSE_TYPES                                                                                             \
    (NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown | NSEventMaskRightMouseUp | \
     NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |                      \
     NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp | NSEventMaskOtherMouseDragged)
#define ENTER_EXIT (NSEventMaskMouseEntered | NSEventMaskMouseExited | NSEventMaskCursorUpdate)
#define KEY_TYPES (NSEventMaskKeyDown | NSEventMaskKeyUp)
#define OTHER_TYPES                                                                                 \
    (NSEventMaskAppKitDefined | NSEventMaskSystemDefined | NSEventMaskApplicationDefined | \
     NSEventMaskPeriodic)

@implementation NSEvent {
    NSEventType _type;
    NSPoint _location;
    NSEventModifierFlags _flags;
    NSTimeInterval _timestamp;
    NSInteger _windowNumber;
    NSWindow *_window;  /* not retained */
    NSInteger _eventNumber, _clickCount, _buttonNumber;
    float _pressure;
    CGFloat _deltaX, _deltaY, _deltaZ;
    BOOL _precise, _inverted;
    NSEventPhase _phase, _momentumPhase;
    NSString *_characters, *_unmodified;
    BOOL _repeat;
    unsigned short _keyCode;
    short _subtype;
    NSInteger _data1, _data2;
    NSInteger _trackingNumber;
    void *_userData;
    NSTrackingArea *_trackingArea;
    NSPoint _screen;  /* from the window server: where on the screen (AppKit's coordinates) */
    BOOL _hasScreen;
}

static NSString *const typeNames[] = {
    [NSEventTypeLeftMouseDown] = @"LMouseDown", [NSEventTypeLeftMouseUp] = @"LMouseUp",
    [NSEventTypeRightMouseDown] = @"RMouseDown", [NSEventTypeRightMouseUp] = @"RMouseUp",
    [NSEventTypeMouseMoved] = @"MouseMoved", [NSEventTypeLeftMouseDragged] = @"LMouseDragged",
    [NSEventTypeRightMouseDragged] = @"RMouseDragged", [NSEventTypeMouseEntered] = @"MouseEntered",
    [NSEventTypeMouseExited] = @"MouseExited", [NSEventTypeKeyDown] = @"KeyDown", [NSEventTypeKeyUp] = @"KeyUp",
    [NSEventTypeFlagsChanged] = @"FlagsChanged", [NSEventTypeAppKitDefined] = @"Kitdefined",
    [NSEventTypeSystemDefined] = @"Sysdefined", [NSEventTypeApplicationDefined] = @"AppDefined",
    [NSEventTypePeriodic] = @"Periodic", [NSEventTypeCursorUpdate] = @"CursorUpdate",
    [NSEventTypeScrollWheel] = @"ScrollWheel", [NSEventTypeTabletPoint] = @"TabletPoint",
    [NSEventTypeTabletProximity] = @"TabletProximity", [NSEventTypeOtherMouseDown] = @"OtherMouseDown",
    [NSEventTypeOtherMouseUp] = @"OtherMouseUp", [NSEventTypeOtherMouseDragged] = @"OtherMouseDragged",
};

static NSString *
format_number(double v)
{
    if (v == floor(v) && fabs(v) < 1e15)
        return [NSString stringWithFormat:@"%.0f", v];
    return [NSString stringWithFormat:@"%g", v];
}

- (NSString *)description
{
    NSString *name = (NSUInteger)_type < sizeof typeNames / sizeof *typeNames && typeNames[_type]
                         ? typeNames[_type]
                         : [NSString stringWithFormat:@"%lu", (unsigned long)_type];
    NSMutableString *s = [NSMutableString
        stringWithFormat:@"NSEvent: type=%@ loc=(%@,%@) time=%.1f flags=%@ win=%p winNum=%ld ctxt=0x0", name,
                         format_number(_location.x), format_number(_location.y), _timestamp,
                         _flags ? [NSString stringWithFormat:@"0x%lx", (unsigned long)_flags] : @"0", _window,
                         (long)_windowNumber];
    NSEventMask m = NSEventMaskFromType(_type);
    if (m & MOUSE_TYPES) {
        [s appendFormat:@" evNum=%ld click=%ld buttonNumber=%ld pressure=%g", (long)_eventNumber, (long)_clickCount,
                        (long)_buttonNumber, _pressure];
        if (m & (NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |
                 NSEventMaskOtherMouseDragged))
            [s appendFormat:@" deltaX=%f deltaY=%f", _deltaX, _deltaY];
        [s appendFormat:@" deviceID:0x0 subtype=%d", _subtype];
    } else if (m & NSEventMaskFlagsChanged)
        [s appendFormat:@" keyCode=%u", _keyCode];
    else if (m & KEY_TYPES)
        [s appendFormat:@" chars=\"%@\" unmodchars=\"%@\" repeat=%d keyCode=%u", _characters ?: @"", _unmodified ?: @"",
                        _repeat, _keyCode];
    else if (m & OTHER_TYPES)
        [s appendFormat:@" subtype=%d data1=%ld data2=%ld", _subtype, (long)_data1, (long)_data2];
    else if (m & ENTER_EXIT)
        [s appendFormat:@" evNum=%ld trackNum=%lx userData=%p", (long)_eventNumber, (long)_trackingNumber, _userData];
    else if (_type == NSEventTypeScrollWheel)
        [s appendFormat:@" deltaX=%g deltaY=%g count:0 phase=%@ momentumPhase=%@", _deltaX, _deltaY,
                        _phase ? [NSString stringWithFormat:@"%lu", (unsigned long)_phase] : @"None",
                        _momentumPhase ? [NSString stringWithFormat:@"%lu", (unsigned long)_momentumPhase] : @"None"];
    return s;
}

static void
check(NSEvent *e, NSEventMask allowed)
{
    if (!(NSEventMaskFromType(e->_type) & allowed))
        [NSException raise:NSInternalInconsistencyException format:@"Invalid message sent to event \"%@\"", e];
}

+ (NSEvent *)mouseEventWithType:(NSEventType)type location:(NSPoint)location modifierFlags:(NSEventModifierFlags)flags
                      timestamp:(NSTimeInterval)time windowNumber:(NSInteger)wNum
                        context:(NSGraphicsContext *)unusedPassNil eventNumber:(NSInteger)eNum
                     clickCount:(NSInteger)cNum pressure:(float)pressure
{
    if (!(NSEventMaskFromType(type) & MOUSE_TYPES))
        [NSException raise:NSInternalInconsistencyException
                    format:@"Invalid parameter not satisfying: _NSEventMask64FromType(type) & (MouseMask|NSEventMaskMouseMoved)"];
    NSEvent *e = [[[self alloc] init] autorelease];
    e->_type = type;
    e->_location = location;
    e->_flags = flags;
    e->_timestamp = time;
    e->_windowNumber = wNum;
    e->_window = FinchWindowForNumber(wNum);
    e->_eventNumber = eNum;
    e->_clickCount = cNum;
    e->_pressure = pressure;
    return e;
}

+ (NSEvent *)keyEventWithType:(NSEventType)type location:(NSPoint)location modifierFlags:(NSEventModifierFlags)flags
                    timestamp:(NSTimeInterval)time windowNumber:(NSInteger)wNum
                      context:(NSGraphicsContext *)unusedPassNil characters:(NSString *)keys
  charactersIgnoringModifiers:(NSString *)ukeys isARepeat:(BOOL)flag keyCode:(unsigned short)code
{
    if (!(NSEventMaskFromType(type) & (KEY_TYPES | NSEventMaskFlagsChanged)))
        [NSException raise:NSInternalInconsistencyException
                    format:@"Invalid parameter not satisfying: _NSEventMask64FromType(type) & KeyMask"];
    NSEvent *e = [[[self alloc] init] autorelease];
    e->_type = type;
    e->_location = location;
    e->_flags = flags;
    e->_timestamp = time;
    e->_windowNumber = wNum;
    e->_window = FinchWindowForNumber(wNum);
    e->_characters = [keys copy];
    e->_unmodified = [ukeys copy];
    e->_repeat = flag;
    e->_keyCode = code;
    return e;
}

+ (NSEvent *)enterExitEventWithType:(NSEventType)type location:(NSPoint)location
                      modifierFlags:(NSEventModifierFlags)flags timestamp:(NSTimeInterval)time
                       windowNumber:(NSInteger)wNum context:(NSGraphicsContext *)unusedPassNil
                        eventNumber:(NSInteger)eNum trackingNumber:(NSInteger)tNum userData:(void *)data
{
    if (!(NSEventMaskFromType(type) & ENTER_EXIT))
        [NSException raise:NSInternalInconsistencyException
                    format:@"Invalid parameter not satisfying: _NSEventMask64FromType(type) & EnterExitMask"];
    NSEvent *e = [[[self alloc] init] autorelease];
    e->_type = type;
    e->_location = location;
    e->_flags = flags;
    e->_timestamp = time;
    e->_windowNumber = wNum;
    e->_window = FinchWindowForNumber(wNum);
    e->_eventNumber = eNum;
    e->_trackingNumber = tNum;
    e->_userData = data;
    return e;
}

+ (NSEvent *)otherEventWithType:(NSEventType)type location:(NSPoint)location modifierFlags:(NSEventModifierFlags)flags
                      timestamp:(NSTimeInterval)time windowNumber:(NSInteger)wNum
                        context:(NSGraphicsContext *)unusedPassNil subtype:(short)subtype data1:(NSInteger)d1
                          data2:(NSInteger)d2
{
    if (!(NSEventMaskFromType(type) & OTHER_TYPES))
        [NSException raise:NSInternalInconsistencyException
                    format:@"Invalid parameter not satisfying: _NSEventMask64FromType(type) & OtherMask"];
    NSEvent *e = [[[self alloc] init] autorelease];
    e->_type = type;
    e->_location = location;
    e->_flags = flags;
    e->_timestamp = time;
    e->_windowNumber = wNum;
    e->_window = FinchWindowForNumber(wNum);
    e->_subtype = subtype;
    e->_data1 = d1;
    e->_data2 = d2;
    return e;
}

+ (NSEvent *)eventWithCGEvent:(CGEventRef)cgEvent
{
    return nil;
}

+ (NSEvent *)eventWithEventRef:(const void *)eventRef
{
    return nil;
}

- (void)dealloc
{
    [_characters release];
    [_unmodified release];
    [_trackingArea release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSEvent *e = NSCopyObject(self, 0, zone);
    [e->_characters retain];
    [e->_unmodified retain];
    [e->_trackingArea retain];
    return e;
}

- (NSEventType)type { return _type; }
- (NSEventModifierFlags)modifierFlags { return _flags; }
- (NSTimeInterval)timestamp { return _timestamp; }
- (NSWindow *)window { return _window; }
- (NSInteger)windowNumber { return _windowNumber; }
- (NSGraphicsContext *)context { return nil; }
- (NSPoint)locationInWindow { return _location; }
- (CGFloat)deltaX { return _deltaX; }
- (CGFloat)deltaY { return _deltaY; }
- (CGFloat)deltaZ { return _deltaZ; }
- (NSInteger)buttonNumber { return _buttonNumber; }
- (NSEventPhase)momentumPhase { return _momentumPhase; }
- (CGEventRef)CGEvent { return NULL; }
- (const void *)eventRef { return NULL; }
- (NSUInteger)deviceID { return 0; }
- (NSEventMask)associatedEventsMask { return 0; }
- (BOOL)isSwipeTrackingFromScrollEventsEnabled { return NO; }

- (NSEventSubtype)subtype
{
    check(self, MOUSE_TYPES | OTHER_TYPES | NSEventMaskScrollWheel | NSEventMaskTabletPoint |
                    NSEventMaskTabletProximity);
    return _subtype;
}

- (NSInteger)data1
{
    check(self, OTHER_TYPES);
    return _data1;
}

- (NSInteger)data2
{
    check(self, OTHER_TYPES);
    return _data2;
}

- (NSString *)characters
{
    check(self, KEY_TYPES);
    return _characters;
}

- (NSString *)charactersIgnoringModifiers
{
    check(self, KEY_TYPES);
    return _unmodified;
}

- (NSString *)charactersByApplyingModifiers:(NSEventModifierFlags)modifiers
{
    check(self, KEY_TYPES);
    NSString *s = _unmodified;
    if (modifiers & NSEventModifierFlagShift)
        return [s uppercaseString];
    return s;
}

- (BOOL)isARepeat
{
    check(self, KEY_TYPES);
    return _repeat;
}

- (unsigned short)keyCode
{
    check(self, KEY_TYPES | NSEventMaskFlagsChanged);
    return _keyCode;
}

- (NSInteger)clickCount
{
    check(self, MOUSE_TYPES);
    return _clickCount;
}

- (float)pressure
{
    check(self, MOUSE_TYPES | NSEventMaskTabletPoint | NSEventMaskPressure);
    return _pressure;
}

- (NSInteger)eventNumber
{
    check(self, MOUSE_TYPES | ENTER_EXIT);
    return _eventNumber;
}

- (NSInteger)trackingNumber
{
    check(self, ENTER_EXIT);
    return _trackingNumber;
}

- (void *)userData
{
    check(self, ENTER_EXIT);
    return _userData;
}

- (NSTrackingArea *)trackingArea
{
    check(self, ENTER_EXIT);
    return _trackingArea;
}

- (CGFloat)scrollingDeltaX
{
    check(self, NSEventMaskScrollWheel);
    return _deltaX;
}

- (CGFloat)scrollingDeltaY
{
    check(self, NSEventMaskScrollWheel);
    return _deltaY;
}

- (BOOL)hasPreciseScrollingDeltas
{
    check(self, ~(NSEventMask)(ENTER_EXIT | KEY_TYPES | NSEventMaskFlagsChanged));
    return _precise;
}

- (NSEventPhase)phase
{
    check(self, NSEventMaskScrollWheel | NSEventMaskMagnify | NSEventMaskRotate | NSEventMaskSwipe |
                    NSEventMaskSmartMagnify | NSEventMaskGesture);
    return _phase;
}

- (BOOL)isDirectionInvertedFromDevice
{
    check(self, NSEventMaskScrollWheel);
    return _inverted;
}

- (NSInteger)absoluteX { check(self, MOUSE_TYPES | NSEventMaskTabletPoint); return 0; }
- (NSInteger)absoluteY { check(self, MOUSE_TYPES | NSEventMaskTabletPoint); return 0; }
- (NSInteger)absoluteZ { check(self, MOUSE_TYPES | NSEventMaskTabletPoint); return 0; }
- (NSEventButtonMask)buttonMask { check(self, MOUSE_TYPES | NSEventMaskTabletPoint); return 0; }
- (NSPoint)tilt { check(self, MOUSE_TYPES | NSEventMaskTabletPoint); return NSZeroPoint; }
- (float)tangentialPressure { check(self, MOUSE_TYPES | NSEventMaskTabletPoint); return 0; }
- (float)rotation { check(self, MOUSE_TYPES | NSEventMaskTabletPoint | NSEventMaskRotate); return 0; }
- (id)vendorDefined { check(self, MOUSE_TYPES | NSEventMaskTabletPoint); return nil; }
- (CGFloat)magnification { check(self, NSEventMaskMagnify); return 0; }
- (NSInteger)stage { check(self, NSEventMaskPressure); return 0; }
- (CGFloat)stageTransition { check(self, NSEventMaskPressure); return 0; }

#pragma mark - State outside events

static NSEventModifierFlags current_flags;
static NSPoint current_mouse;  /* screen coordinates, AppKit's: y up from the main screen's bottom */
static NSUInteger current_buttons;

void
FinchEventNoteModifiers(NSEventModifierFlags flags, NSPoint mouse, NSUInteger buttons)
{
    current_flags = flags;
    current_mouse = mouse;
    current_buttons = buttons;
}

+ (NSPoint)mouseLocation { return current_mouse; }
+ (NSEventModifierFlags)modifierFlags { return current_flags; }
+ (NSUInteger)pressedMouseButtons { return current_buttons; }
+ (NSTimeInterval)doubleClickInterval { return 0.5; }
+ (NSTimeInterval)keyRepeatDelay { return 0.5; }
+ (NSTimeInterval)keyRepeatInterval { return 1.0 / 12; }
+ (BOOL)isMouseCoalescingEnabled { return YES; }
+ (void)setMouseCoalescingEnabled:(BOOL)flag {}
+ (BOOL)isSwipeTrackingFromScrollEventsEnabled { return NO; }

#pragma mark - Monitors and periodic events

static NSMutableArray *local_monitors;

+ (id)addLocalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(NSEvent *(^)(NSEvent *))block
{
    if (!local_monitors)
        local_monitors = [[NSMutableArray alloc] init];
    NSArray *monitor = @[ @(mask), [[block copy] autorelease] ];
    [local_monitors addObject:monitor];
    return monitor;
}

+ (id)addGlobalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(void (^)(NSEvent *))block
{
    /* Events for other apps aren't delivered to this one on Finch (yet). */
    return @[ @(mask), [[block copy] autorelease] ];
}

+ (void)removeMonitor:(id)eventMonitor
{
    [local_monitors removeObjectIdenticalTo:eventMonitor];
}

/* Local monitors see an event before it is dispatched, and may change or swallow it. */
FINCH_PRIVATE NSEvent *
FinchEventApplyLocalMonitors(NSEvent *event)
{
    for (NSArray *monitor in [[local_monitors copy] autorelease]) {
        if (!event)
            break;
        if ([monitor[0] unsignedLongLongValue] & NSEventMaskFromType([event type])) {
            NSEvent *(^handler)(NSEvent *) = monitor[1];
            event = handler(event);
        }
    }
    return event;
}

static NSTimer *periodic;

+ (void)startPeriodicEventsAfterDelay:(NSTimeInterval)delay withPeriod:(NSTimeInterval)period
{
    if (periodic)
        [NSException raise:NSInternalInconsistencyException format:@"Periodic events are already being generated"];
    periodic = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:delay] interval:period
                                          target:self selector:@selector(_finchPeriodic:) userInfo:nil
                                         repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:periodic forMode:NSDefaultRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:periodic forMode:NSEventTrackingRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:periodic forMode:NSModalPanelRunLoopMode];
}

+ (void)_finchPeriodic:(NSTimer *)timer
{
    NSEvent *e = [self otherEventWithType:NSEventTypePeriodic location:NSZeroPoint modifierFlags:current_flags
                                timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:0 context:nil
                                  subtype:0 data1:0 data2:0];
    [NSApp postEvent:e atStart:NO];
}

+ (void)stopPeriodicEvents
{
    [periodic invalidate];
    [periodic release];
    periodic = nil;
}

#pragma mark - From the window server

static NSEventModifierFlags
modifiers_from_cg(uint64_t flags)
{
    /* CGEventFlags and NSEventModifierFlags share their device-independent bits. */
    return (NSEventModifierFlags)flags;
}

NSEvent *
FinchEventFromServer(const FWSEvent *e, NSWindow *window)
{
    NSEventType type = (NSEventType)e->type;
    NSEventModifierFlags flags = modifiers_from_cg(e->modifiers);
    NSInteger number = [window windowNumber];
    /* Window coordinates: points from the frame's bottom left, y up. */
    NSPoint loc = window ? NSMakePoint(e->x, [window frame].size.height - e->y) : NSZeroPoint;
    if (!window) {
        NSRect screen = [[[NSScreen screens] firstObject] frame];
        loc = NSMakePoint(e->screen_x, screen.size.height - e->screen_y);
    }
    NSEvent *ev = nil;
    switch (type) {
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp:
    case NSEventTypeFlagsChanged: {
        NSString *chars = [NSString stringWithCharacters:e->characters length:MIN(e->length, 8)];
        NSUInteger un = 0;
        while (un < 8 && e->unmodified[un])
            un++;
        NSString *unmod = e->length ? [NSString stringWithCharacters:e->unmodified length:MIN(un, e->length)] : @"";
        if (type == NSEventTypeFlagsChanged)
            chars = unmod = @"";
        ev = [NSEvent keyEventWithType:type location:loc modifierFlags:flags timestamp:e->timestamp
                          windowNumber:number context:nil characters:chars charactersIgnoringModifiers:unmod
                             isARepeat:e->is_repeat != 0 keyCode:(unsigned short)e->key_code];
        break;
    }
    case NSEventTypeScrollWheel: {
        ev = [[[NSEvent alloc] init] autorelease];
        ev->_type = type;
        ev->_location = loc;
        ev->_flags = flags;
        ev->_timestamp = e->timestamp;
        ev->_windowNumber = number;
        ev->_window = window;
        ev->_deltaX = e->delta_x;
        ev->_deltaY = e->delta_y;
        ev->_precise = YES;
        break;
    }
    default:
        if (!(NSEventMaskFromType(type) & MOUSE_TYPES))
            return nil;
        ev = [NSEvent mouseEventWithType:type location:loc modifierFlags:flags timestamp:e->timestamp
                            windowNumber:number context:nil eventNumber:0 clickCount:(NSInteger)e->click_count
                                pressure:(type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseDragged) ? 1 : 0];
        ev->_buttonNumber = (NSInteger)e->button;
        ev->_deltaX = e->delta_x;
        ev->_deltaY = e->delta_y;
        break;
    }
    ev->_window = window;
    NSRect screen = [[NSScreen mainScreen] frame];
    ev->_screen = NSMakePoint(e->screen_x, NSMaxY(screen) - e->screen_y);
    ev->_hasScreen = YES;
    return ev;
}

/* Where an event happened on the screen: as the server saw it, else from its window's frame now. */
NSPoint
FinchEventScreenLocation(NSEvent *e)
{
    if (e->_hasScreen)
        return e->_screen;
    return e->_window ? [e->_window convertPointToScreen:e->_location] : e->_location;
}

@end
