/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSliderCell: a value between a minimum and a maximum, set by dragging a
 * knob along a track (or round a dial, for circular sliders), with optional
 * tick marks the value can be held to. As Apple's (measured by
 * finch-appkit-controls-test): a null-type cell whose value is a double,
 * clamped to the range when it or the range changes; continuous by default
 * (sending on mouse down, drag and up).
 *
 * Nib keys: NSMinValue, NSMaxValue, NSValue, NSAltIncValue,
 * NSNumberOfTickMarks, NSTickMarkPosition, NSAllowsTickMarkValuesOnly,
 * NSVertical, NSSliderType.
 *
 * Drawn in Finch's own flat look: a thin rounded track, the part up to the
 * knob in the accent colour, and a round white knob.
 */
#import "NSControl_Finch.h"

#define SLIDER_ACTION_MASK (NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged)

@implementation NSSliderCell {
    double _value, _min, _max, _altIncrement;
    NSInteger _tickCount;
    NSTickMarkPosition _tickPosition;
    NSSliderType _sliderType;
    NSRect _trackRect;
    struct {
        unsigned ticksOnly : 1;
        unsigned verticalSet : 1;
        unsigned vertical : 1;
        unsigned dragging : 1;
    } _s;
}

+ (BOOL)prefersTrackingUntilMouseUp { return YES; }

- (instancetype)init
{
    return [self initImageCell:nil];
}

- (instancetype)initImageCell:(NSImage *)image
{
    self = [super initImageCell:nil];
    if (self) {
        _max = 1;
        [self sendActionOn:SLIDER_ACTION_MASK];
    }
    return self;
}

- (instancetype)initTextCell:(NSString *)string
{
    return [self initImageCell:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _min = [coder decodeDoubleForKey:@"NSMinValue"];
    _max = [coder containsValueForKey:@"NSMaxValue"] ? [coder decodeDoubleForKey:@"NSMaxValue"] : 1;
    _value = [coder decodeDoubleForKey:@"NSValue"];
    _altIncrement = [coder decodeDoubleForKey:@"NSAltIncValue"];
    _tickCount = [coder decodeIntegerForKey:@"NSNumberOfTickMarks"];
    _tickPosition = (NSTickMarkPosition)[coder decodeIntegerForKey:@"NSTickMarkPosition"];
    _s.ticksOnly = [coder decodeBoolForKey:@"NSAllowsTickMarkValuesOnly"];
    if ([coder containsValueForKey:@"NSVertical"]) {
        _s.verticalSet = YES;
        _s.vertical = [coder decodeBoolForKey:@"NSVertical"];
    }
    _sliderType = (NSSliderType)[coder decodeIntegerForKey:@"NSSliderType"];
    /* the control's NSControlSendActionMask, when there is one, replaces this */
    if ([self _finchActionMask] & NSEventMaskPeriodic)
        [self sendActionOn:SLIDER_ACTION_MASK];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeDouble:_max forKey:@"NSMaxValue"];
    [coder encodeDouble:_min forKey:@"NSMinValue"];
    [coder encodeDouble:_value forKey:@"NSValue"];
    [coder encodeDouble:_altIncrement forKey:@"NSAltIncValue"];
    [coder encodeInteger:_tickCount forKey:@"NSNumberOfTickMarks"];
    [coder encodeInteger:_tickPosition forKey:@"NSTickMarkPosition"];
    [coder encodeBool:_s.ticksOnly forKey:@"NSAllowsTickMarkValuesOnly"];
    [coder encodeBool:[self isVertical] forKey:@"NSVertical"];
    if (_sliderType)
        [coder encodeInteger:_sliderType forKey:@"NSSliderType"];
}

- (BOOL)_finchClickChangesState { return NO; }

#pragma mark Value

- (void)_finchStore:(double)v
{
    v = MAX(_min, MIN(_max, v));
    if (_s.ticksOnly && _tickCount > 0)
        v = [self closestTickMarkValueToValue:v];
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
- (NSString *)title { return @""; }
- (void)setTitle:(NSString *)title {}
- (NSImage *)image { return nil; }
- (void)setImage:(NSImage *)image {}
- (id)titleCell { return nil; }
- (void)setTitleCell:(NSCell *)cell {}
- (NSColor *)titleColor { return nil; }
- (void)setTitleColor:(NSColor *)color {}
- (NSFont *)titleFont { return nil; }
- (void)setTitleFont:(NSFont *)font {}

- (double)minValue { return _min; }

- (void)setMinValue:(double)v
{
    _min = v;
    _value = MAX(_min, MIN(_max, _value));
    [self _finchChanged];
}

- (double)maxValue { return _max; }

- (void)setMaxValue:(double)v
{
    _max = v;
    _value = MAX(_min, MIN(_max, _value));
    [self _finchChanged];
}

- (double)altIncrementValue { return _altIncrement; }
- (void)setAltIncrementValue:(double)v { _altIncrement = v; }
- (NSSliderType)sliderType { return _sliderType; }

- (void)setSliderType:(NSSliderType)type
{
    _sliderType = type;
    [self _finchChanged];
}

- (BOOL)isVertical
{
    if (_s.verticalSet)
        return _s.vertical;
    NSView *v = [self controlView];
    if (!v)
        return NO;
    NSSize s = [v frame].size;
    return s.height > s.width;
}

- (void)setVertical:(BOOL)flag
{
    _s.verticalSet = YES;
    _s.vertical = flag;
    [self _finchChanged];
}

/* A slider is continuous when it sends on drags (and down), as Apple's masks show. */
- (BOOL)isContinuous
{
    return ([self _finchActionMask] & (NSEventMaskLeftMouseDragged | NSEventMaskPeriodic)) != 0;
}

- (void)setContinuous:(BOOL)flag
{
    [self sendActionOn:flag ? SLIDER_ACTION_MASK : NSEventMaskLeftMouseUp];
}

- (CGFloat)knobThickness { return 20; }
- (void)setKnobThickness:(CGFloat)t {}

#pragma mark Tick marks

- (NSInteger)numberOfTickMarks { return _tickCount; }

- (void)setNumberOfTickMarks:(NSInteger)n
{
    _tickCount = MAX(n, 0);
    if (_s.ticksOnly)
        [self _finchStore:_value];
    [self _finchChanged];
}

- (NSTickMarkPosition)tickMarkPosition { return _tickPosition; }

- (void)setTickMarkPosition:(NSTickMarkPosition)p
{
    _tickPosition = p;
    [self _finchChanged];
}

- (BOOL)allowsTickMarkValuesOnly { return _s.ticksOnly; }

- (void)setAllowsTickMarkValuesOnly:(BOOL)flag
{
    _s.ticksOnly = flag;
    if (flag && _tickCount > 0) {
        double v = [self closestTickMarkValueToValue:_value];
        if (v != _value) {
            _value = v;
            [self _finchChanged];
        }
    }
}

- (double)tickMarkValueAtIndex:(NSInteger)index
{
    if (index < 0 || index >= _tickCount)
        [NSException raise:NSRangeException format:@"tick mark index %ld out of range (%ld tick marks)", (long)index,
                                                    (long)_tickCount];
    if (_tickCount == 1)
        return (_min + _max) / 2;
    return _min + (_max - _min) * index / (double)(_tickCount - 1);
}

- (double)closestTickMarkValueToValue:(double)value
{
    if (_tickCount <= 0)
        return value;
    if (_tickCount == 1)
        return (_min + _max) / 2;
    double step = (_max - _min) / (double)(_tickCount - 1);
    if (step == 0)
        return _min;
    double i = round((value - _min) / step);
    i = MAX(0, MIN(_tickCount - 1, i));
    return _min + step * i;
}

#pragma mark Geometry

- (NSRect)_finchFrame
{
    if (!NSIsEmptyRect(_trackRect))
        return _trackRect;
    NSView *v = [self controlView];
    return v ? [v bounds] : NSZeroRect;
}

- (NSRect)trackRect { return [self _finchFrame]; }

/* The line the knob's centre moves along, inset by half the knob. */
- (NSRect)_finchTrackIn:(NSRect)frame
{
    CGFloat k = [self knobThickness] / 2;
    if ([self isVertical])
        return NSMakeRect(NSMidX(frame), frame.origin.y + k, 0, MAX(0, frame.size.height - 2 * k));
    return NSMakeRect(frame.origin.x + k, NSMidY(frame), MAX(0, frame.size.width - 2 * k), 0);
}

- (double)_finchFraction
{
    return _max > _min ? (MAX(_min, MIN(_max, _value)) - _min) / (_max - _min) : 0;
}

- (NSPoint)_finchKnobCentreIn:(NSRect)frame flipped:(BOOL)flipped
{
    NSRect t = [self _finchTrackIn:frame];
    double f = [self _finchFraction];
    if ([self isVertical]) {
        /* the maximum is at the top */
        CGFloat y = flipped ? NSMaxY(t) - f * t.size.height : t.origin.y + f * t.size.height;
        return NSMakePoint(t.origin.x, y);
    }
    return NSMakePoint(t.origin.x + f * t.size.width, t.origin.y);
}

- (CGFloat)_finchKnobDiameter
{
    switch ([self controlSize]) {
    case NSControlSizeSmall: return 12;
    case NSControlSizeMini: return 10;
    default: return 16;
    }
}

- (NSRect)knobRectFlipped:(BOOL)flipped
{
    NSRect frame = [self _finchFrame];
    if (_sliderType == NSSliderTypeCircular) {
        NSRect dial = [self _finchDialIn:frame];
        CGFloat r = dial.size.width / 2 - 5, a = [self _finchFraction] * 2 * M_PI;
        CGFloat dx = sin(a) * r, dy = cos(a) * r;
        NSPoint c = NSMakePoint(NSMidX(dial) + dx, flipped ? NSMidY(dial) - dy : NSMidY(dial) + dy);
        return NSMakeRect(c.x - 3, c.y - 3, 6, 6);
    }
    CGFloat d = [self _finchKnobDiameter];
    NSPoint c = [self _finchKnobCentreIn:frame flipped:flipped];
    return NSMakeRect(round(c.x - d / 2), round(c.y - d / 2), d, d);
}

- (NSRect)barRectFlipped:(BOOL)flipped
{
    NSRect frame = [self _finchFrame];
    NSRect t = [self _finchTrackIn:frame];
    CGFloat th = 4;
    if ([self isVertical])
        return NSMakeRect(round(t.origin.x - th / 2), t.origin.y - th / 2, th, t.size.height + th);
    return NSMakeRect(t.origin.x - th / 2, round(t.origin.y - th / 2), t.size.width + th, th);
}

- (NSRect)_finchDialIn:(NSRect)frame
{
    CGFloat d = MIN(frame.size.width, frame.size.height) - 2;
    return NSMakeRect(floor(NSMidX(frame) - d / 2), floor(NSMidY(frame) - d / 2), d, d);
}

- (NSRect)rectOfTickMarkAtIndex:(NSInteger)index
{
    double v = [self tickMarkValueAtIndex:index];
    NSRect frame = [self _finchFrame];
    NSRect t = [self _finchTrackIn:frame];
    double f = _max > _min ? (v - _min) / (_max - _min) : 0;
    BOOL flipped = [[self controlView] isFlipped];
    if ([self isVertical]) {
        CGFloat y = flipped ? NSMaxY(t) - f * t.size.height : t.origin.y + f * t.size.height;
        CGFloat x = _tickPosition == NSTickMarkPositionLeading ? t.origin.x - 10 : t.origin.x + 6;
        return NSMakeRect(x, round(y) - 0.5, 4, 1);
    }
    BOOL above = _tickPosition == NSTickMarkPositionAbove;
    CGFloat y = (above != flipped) ? t.origin.y + 6 : t.origin.y - 10;
    return NSMakeRect(round(t.origin.x + f * t.size.width) - 0.5, y, 1, 4);
}

- (NSInteger)indexOfTickMarkAtPoint:(NSPoint)point
{
    for (NSInteger i = 0; i < _tickCount; i++)
        if (NSPointInRect(point, NSInsetRect([self rectOfTickMarkAtIndex:i], -3, -3)))
            return i;
    return NSNotFound;
}

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    CGFloat h = [self controlSize] == NSControlSizeSmall ? 12 : [self controlSize] == NSControlSizeMini ? 10 : 16;
    if (_tickCount > 0)
        h += 8;
    if (_sliderType == NSSliderTypeCircular) {
        CGFloat d = [self controlSize] == NSControlSizeRegular ? 24 : 18;
        return NSMakeSize(d, d);
    }
    if ([self isVertical])
        return NSMakeSize(h, 40000);
    return NSMakeSize(40000, h);
}

#pragma mark Drawing

- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped
{
    NSRect bar = [self barRectFlipped:flipped];
    BOOL enabled = [self isEnabled];
    FinchDrawBezel(bar, 2, FinchDisabled([NSColor colorWithSRGBRed:0.82 green:0.83 blue:0.85 alpha:1], enabled), nil);
    NSPoint c = [self _finchKnobCentreIn:[self _finchFrame] flipped:flipped];
    NSRect fill = bar;
    if ([self isVertical]) {
        if (flipped) {
            fill.size.height = NSMaxY(bar) - c.y;
            fill.origin.y = c.y;
        } else
            fill.size.height = c.y - bar.origin.y;
    } else {
        fill.size.width = c.x - bar.origin.x;
    }
    NSColor *accent = nil;
    if ([[self controlView] respondsToSelector:@selector(trackFillColor)])
        accent = [(NSSlider *)[self controlView] trackFillColor];
    if (fill.size.width > 0 && fill.size.height > 0)
        FinchDrawBezel(fill, 2, FinchDisabled(accent ?: FinchAccentColor(), enabled), nil);
}

- (void)drawKnob:(NSRect)knob
{
    BOOL enabled = [self isEnabled];
    if (_sliderType == NSSliderTypeCircular) {
        [FinchDisabled(FinchAccentColor(), enabled) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
        return;
    }
    NSColor *fill = [self isHighlighted] ? FinchControlFill(YES) : [NSColor whiteColor];
    NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(knob, 0.5, 0.5)];
    [FinchDisabled(fill, enabled) setFill];
    [p fill];
    [FinchDisabled(FinchControlStroke(), enabled) setStroke];
    [p setLineWidth:1];
    [p stroke];
}

- (void)drawKnob
{
    [self drawKnob:[self knobRectFlipped:[[self controlView] isFlipped]]];
}

- (void)drawTickMarks
{
    if (_tickCount <= 0 || _sliderType == NSSliderTypeCircular)
        return;
    [FinchDisabled(FinchControlStroke(), [self isEnabled]) setFill];
    for (NSInteger i = 0; i < _tickCount; i++)
        NSRectFill([self rectOfTickMarkAtIndex:i]);
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    _trackRect = frame;
    BOOL flipped = [view isFlipped];
    if (_sliderType == NSSliderTypeCircular) {
        NSRect dial = [self _finchDialIn:frame];
        FinchDrawBezel(dial, dial.size.width / 2, FinchDisabled([NSColor whiteColor], [self isEnabled]),
                       FinchDisabled(FinchControlStroke(), [self isEnabled]));
        [self drawKnob:[self knobRectFlipped:flipped]];
        return;
    }
    [self drawTickMarks];
    [self drawBarInside:frame flipped:flipped];
    [self drawKnob:[self knobRectFlipped:flipped]];
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view
{
    [self drawWithFrame:frame inView:view];
}

#pragma mark Tracking

- (double)_finchValueAtPoint:(NSPoint)p frame:(NSRect)frame flipped:(BOOL)flipped
{
    double f;
    if (_sliderType == NSSliderTypeCircular) {
        NSRect dial = [self _finchDialIn:frame];
        CGFloat dx = p.x - NSMidX(dial), dy = flipped ? NSMidY(dial) - p.y : p.y - NSMidY(dial);
        double a = atan2(dx, dy);
        if (a < 0)
            a += 2 * M_PI;
        f = a / (2 * M_PI);
    } else {
        NSRect t = [self _finchTrackIn:frame];
        if ([self isVertical])
            f = t.size.height > 0 ? (flipped ? NSMaxY(t) - p.y : p.y - t.origin.y) / t.size.height : 0;
        else
            f = t.size.width > 0 ? (p.x - t.origin.x) / t.size.width : 0;
        f = MAX(0, MIN(1, f));
    }
    return _min + f * (_max - _min);
}

- (BOOL)startTrackingAt:(NSPoint)p inView:(NSView *)view { return YES; }
- (BOOL)continueTracking:(NSPoint)last at:(NSPoint)p inView:(NSView *)view { return YES; }

- (BOOL)trackMouse:(NSEvent *)event inRect:(NSRect)frame ofView:(NSView *)view untilMouseUp:(BOOL)untilUp
{
    if (![self isEnabled])
        return NO;
    _trackRect = frame;
    NSWindow *w = [view window];
    BOOL flipped = [view isFlipped];
    NSEventMask mask = [self _finchActionMask];
    NSPoint p = [view convertPoint:[event locationInWindow] fromView:nil];
    /* grabbing the knob keeps the offset; elsewhere the knob jumps to the mouse */
    NSRect knob = [self knobRectFlipped:flipped];
    NSPoint centre = NSMakePoint(NSMidX(knob), NSMidY(knob));
    NSSize offset = NSZeroSize;
    if (_sliderType == NSSliderTypeLinear && NSPointInRect(p, NSInsetRect(knob, -2, -2)))
        offset = NSMakeSize(p.x - centre.x, p.y - centre.y);
    [self startTrackingAt:p inView:view];
    double before = _value;
    [self _finchStore:[self _finchValueAtPoint:NSMakePoint(p.x - offset.width, p.y - offset.height) frame:frame
                                       flipped:flipped]];
    [view setNeedsDisplay:YES];
    if (mask & NSEventMaskLeftMouseDown)
        [self _finchSendAction];
    NSPoint last = p;
    if ([event type] != NSEventTypeLeftMouseUp) {
        for (;;) {
            NSEvent *e = [w nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
            if (!e)
                break;
            p = [view convertPoint:[e locationInWindow] fromView:nil];
            double old = _value;
            [self _finchStore:[self _finchValueAtPoint:NSMakePoint(p.x - offset.width, p.y - offset.height)
                                                 frame:frame flipped:flipped]];
            if (_value != old) {
                [view setNeedsDisplay:YES];
                [w displayIfNeeded];
            }
            if ([e type] == NSEventTypeLeftMouseUp)
                break;
            [self continueTracking:last at:p inView:view];
            if ((mask & NSEventMaskLeftMouseDragged) && _value != old)
                [self _finchSendAction];
            last = p;
        }
    }
    [self stopTracking:last at:p inView:view mouseIsUp:YES];
    if ((mask & NSEventMaskLeftMouseUp) || _value != before)
        [self _finchSendAction];
    return YES;
}

@end
