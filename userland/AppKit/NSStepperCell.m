/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSStepperCell: up and down arrows that step a value between a minimum and
 * a maximum, wrapping round if asked. As Apple's (measured by
 * finch-appkit-controls-test): a null-type cell whose value is a double,
 * clamped when set; by default 0 to 59 in steps of 1, wrapping, repeating
 * while held, and continuous (it acts on mouse down, then periodically).
 *
 * Nib keys: NSValue, NSMinValue, NSMaxValue, NSIncrement, NSValueWraps,
 * NSAutorepeat.
 *
 * Drawn in Finch's own flat look: a rounded body split in two, a chevron
 * in each half.
 */
#import "NSControl_Finch.h"

@implementation NSStepperCell {
    double _value, _min, _max, _increment;
    int _pressed; /* 0 none, 1 up, -1 down */
    struct {
        unsigned wraps : 1;
        unsigned autorepeat : 1;
    } _st;
}

- (instancetype)init
{
    return [self initImageCell:nil];
}

- (instancetype)initTextCell:(NSString *)string
{
    return [self initImageCell:nil];
}

- (instancetype)initImageCell:(NSImage *)image
{
    self = [super initImageCell:nil];
    if (self) {
        _max = 59;
        _increment = 1;
        _st.wraps = YES;
        _st.autorepeat = YES;
        [self sendActionOn:NSEventMaskLeftMouseDown];
        [self setContinuous:YES];
        [self setBaseWritingDirection:NSWritingDirectionLeftToRight]; /* as Apple's, made in code */
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _value = [coder decodeDoubleForKey:@"NSValue"];
    _min = [coder decodeDoubleForKey:@"NSMinValue"];
    _max = [coder containsValueForKey:@"NSMaxValue"] ? [coder decodeDoubleForKey:@"NSMaxValue"] : 59;
    _increment = [coder containsValueForKey:@"NSIncrement"] ? [coder decodeDoubleForKey:@"NSIncrement"] : 1;
    _st.wraps = [coder decodeBoolForKey:@"NSValueWraps"];
    _st.autorepeat = [coder decodeBoolForKey:@"NSAutorepeat"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeDouble:_value forKey:@"NSValue"];
    if (_min)
        [coder encodeDouble:_min forKey:@"NSMinValue"];
    [coder encodeDouble:_max forKey:@"NSMaxValue"];
    [coder encodeDouble:_increment forKey:@"NSIncrement"];
    if (_st.wraps)
        [coder encodeBool:YES forKey:@"NSValueWraps"];
    if (_st.autorepeat)
        [coder encodeBool:YES forKey:@"NSAutorepeat"];
}

- (BOOL)_finchClickChangesState { return NO; }

#pragma mark Value

- (void)_finchStore:(double)v
{
    v = MAX(_min, MIN(_max, v));
    if (v == _value)
        return;
    _value = v;
    [self _finchChanged];
}

- (double)doubleValue { return _value; }
- (void)setDoubleValue:(double)v { [self _finchStore:v]; }
- (float)floatValue { return (float)_value; }
- (void)setFloatValue:(float)v { [self _finchStore:v]; }
- (int)intValue { return (int)_value; }
- (void)setIntValue:(int)v { [self _finchStore:v]; }
- (NSInteger)integerValue { return (NSInteger)_value; }
- (void)setIntegerValue:(NSInteger)v { [self _finchStore:(double)v]; }
- (id)objectValue { return @(_value); }

- (void)setObjectValue:(id)value
{
    [self _finchStore:[value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0];
}

- (NSString *)stringValue { return [NSString stringWithFormat:@"%.16g", _value]; }

- (void)setStringValue:(NSString *)string
{
    if (!string)
        [NSException raise:NSInternalInconsistencyException format:@"Attempt to set a cell's string value to nil"];
    [self _finchStore:[string doubleValue]];
}

- (NSAttributedString *)attributedStringValue
{
    return [[[NSAttributedString alloc] initWithString:[self stringValue]] autorelease];
}

- (void)setAttributedStringValue:(NSAttributedString *)value { [self setStringValue:[value string] ?: @""]; }
- (double)minValue { return _min; }
- (void)setMinValue:(double)v { _min = v; }
- (double)maxValue { return _max; }
- (void)setMaxValue:(double)v { _max = v; }
- (double)increment { return _increment; }
- (void)setIncrement:(double)v { _increment = v; }
- (BOOL)valueWraps { return _st.wraps; }
- (void)setValueWraps:(BOOL)flag { _st.wraps = flag; }
- (BOOL)autorepeat { return _st.autorepeat; }
- (void)setAutorepeat:(BOOL)flag { _st.autorepeat = flag; }

/* One step up (direction 1) or down (-1), wrapping or stopping at the ends. */
- (void)_finchStep:(int)direction
{
    double v = _value + direction * _increment;
    if (v > _max)
        v = _st.wraps ? _min : _max;
    else if (v < _min)
        v = _st.wraps ? _max : _min;
    [self _finchStore:v];
}

#pragma mark Geometry and drawing

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    switch ([self controlSize]) {
    case NSControlSizeSmall: return NSMakeSize(15, 22);
    case NSControlSizeMini: return NSMakeSize(11, 15);
    default: return NSMakeSize(20, 26);
    }
}

- (NSRect)_finchBody:(NSRect)frame
{
    NSSize s = [self cellSizeForBounds:frame];
    CGFloat w = MIN(frame.size.width, s.width - 4), h = MIN(frame.size.height, s.height - 4);
    return NSMakeRect(floor(NSMidX(frame) - w / 2), floor(NSMidY(frame) - h / 2), w, h);
}

/* Which half a point is in: 1 for the upper, -1 for the lower. */
- (int)_finchHalfAt:(NSPoint)p frame:(NSRect)frame flipped:(BOOL)flipped
{
    BOOL upperHalf = flipped ? p.y < NSMidY(frame) : p.y >= NSMidY(frame);
    return upperHalf ? 1 : -1;
}

static void
chevron(NSRect half, BOOL up, BOOL flipped, NSColor *color)
{
    CGFloat w = MIN(half.size.width * 0.5, 7), h = w * 0.55;
    CGFloat cx = NSMidX(half), cy = NSMidY(half);
    BOOL pointsUpInDevice = up;
    CGFloat tip = (pointsUpInDevice != flipped) ? cy + h / 2 : cy - h / 2;
    CGFloat base = (pointsUpInDevice != flipped) ? cy - h / 2 : cy + h / 2;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(cx - w / 2, base)];
    [p lineToPoint:NSMakePoint(cx, tip)];
    [p lineToPoint:NSMakePoint(cx + w / 2, base)];
    [p setLineWidth:1.5];
    [p setLineCapStyle:NSLineCapStyleRound];
    [p setLineJoinStyle:NSLineJoinStyleRound];
    [color setStroke];
    [p stroke];
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    BOOL flipped = [view isFlipped], enabled = [self isEnabled];
    NSRect body = [self _finchBody:frame];
    FinchDrawBezel(body, 5, FinchDisabled(FinchControlFill(NO), enabled), FinchDisabled(FinchControlStroke(), enabled));
    NSRect upper = body, lower = body;
    upper.size.height = lower.size.height = body.size.height / 2;
    if (flipped)
        lower.origin.y += body.size.height / 2;
    else
        upper.origin.y += body.size.height / 2;
    if (_pressed) {
        NSRect r = NSInsetRect(_pressed > 0 ? upper : lower, 1, 1);
        FinchDrawBezel(r, 4, FinchControlFill(YES), nil);
    }
    [FinchDisabled(FinchControlStroke(), enabled) setFill];
    NSRectFill(NSMakeRect(body.origin.x + 3, round(NSMidY(body)) - 0.5, body.size.width - 6, 1));
    NSColor *ink = FinchDisabled([NSColor controlTextColor], enabled);
    chevron(upper, YES, flipped, ink);
    chevron(lower, NO, flipped, ink);
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view
{
    [self drawWithFrame:frame inView:view];
}

#pragma mark Tracking

/*
 * A press steps at once (and sends, the stepper acting on mouse down); held
 * in the same half with autorepeat, it steps again after a delay and then
 * at intervals, as Apple's.
 */
- (BOOL)trackMouse:(NSEvent *)event inRect:(NSRect)frame ofView:(NSView *)view untilMouseUp:(BOOL)untilUp
{
    if (![self isEnabled])
        return NO;
    NSWindow *w = [view window];
    BOOL flipped = [view isFlipped];
    NSPoint p = [view convertPoint:[event locationInWindow] fromView:nil];
    int half = [self _finchHalfAt:p frame:frame flipped:flipped];
    NSEventMask mask = [self _finchActionMask];
    _pressed = half;
    [self _finchStep:half];
    [view setNeedsDisplay:YES];
    [w displayIfNeeded];
    if (mask & (NSEventMaskLeftMouseDown | NSEventMaskPeriodic))
        [self _finchSendAction];
    BOOL inside = YES;
    NSTimeInterval wait = 0.4;
    while ([event type] != NSEventTypeLeftMouseUp) {
        NSEvent *e = [w nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged
                                    untilDate:[NSDate dateWithTimeIntervalSinceNow:_st.autorepeat ? wait : 1e6]
                                       inMode:NSEventTrackingRunLoopMode
                                      dequeue:YES];
        if (!e) {
            /* held: repeat */
            if (inside && _st.autorepeat) {
                [self _finchStep:half];
                [view setNeedsDisplay:YES];
                [w displayIfNeeded];
                if (mask & NSEventMaskPeriodic)
                    [self _finchSendAction];
            }
            wait = 0.075;
            continue;
        }
        event = e;
        p = [view convertPoint:[e locationInWindow] fromView:nil];
        inside = NSMouseInRect(p, frame, flipped) && [self _finchHalfAt:p frame:frame flipped:flipped] == half;
        int shown = inside ? half : 0;
        if (shown != _pressed) {
            _pressed = shown;
            [view setNeedsDisplay:YES];
        }
    }
    _pressed = 0;
    [view setNeedsDisplay:YES];
    if ((mask & NSEventMaskLeftMouseUp) && !(mask & NSEventMaskLeftMouseDown))
        [self _finchSendAction];
    return YES;
}

@end
