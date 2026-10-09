/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSLevelIndicatorCell: a level shown as a continuous or segmented bar, a
 * relevancy bar or a star rating, coloured by warning and critical
 * thresholds. As Apple's (measured by finch-appkit-controls-test): a
 * null-type cell whose value is a double, not clamped; 0 to 5 by default
 * (0 to 100 for the continuous and relevancy styles); it takes the focus
 * only when editable.
 *
 * Nib keys: NSValue, NSMinValue, NSMaxValue, NSWarningValue,
 * NSCriticalValue, NSIndicatorStyle (and the tick mark keys, when present).
 *
 * Drawn in Finch's own flat look; the rating style draws Finch's own star
 * shapes.
 */
#import "NSControl_Finch.h"

@implementation NSLevelIndicatorCell {
    double _value, _min, _max, _warning, _critical;
    NSLevelIndicatorStyle _style;
    NSTickMarkPosition _tickPosition;
    NSInteger _ticks, _majorTicks;
}

- (instancetype)init
{
    return [self initWithLevelIndicatorStyle:NSLevelIndicatorStyleDiscreteCapacity];
}

- (instancetype)initTextCell:(NSString *)string
{
    return [self initWithLevelIndicatorStyle:NSLevelIndicatorStyleDiscreteCapacity];
}

- (instancetype)initImageCell:(NSImage *)image
{
    return [self initWithLevelIndicatorStyle:NSLevelIndicatorStyleDiscreteCapacity];
}

- (instancetype)initWithLevelIndicatorStyle:(NSLevelIndicatorStyle)style
{
    self = [super initImageCell:nil];
    if (self) {
        _style = style;
        _max = (style == NSLevelIndicatorStyleContinuousCapacity || style == NSLevelIndicatorStyleRelevancy) ? 100 : 5;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _style = (NSLevelIndicatorStyle)[coder decodeIntegerForKey:@"NSIndicatorStyle"];
    _value = [coder decodeDoubleForKey:@"NSValue"];
    _min = [coder decodeDoubleForKey:@"NSMinValue"];
    _max = [coder containsValueForKey:@"NSMaxValue"] ? [coder decodeDoubleForKey:@"NSMaxValue"] : 5;
    _warning = [coder decodeDoubleForKey:@"NSWarningValue"];
    _critical = [coder decodeDoubleForKey:@"NSCriticalValue"];
    _ticks = [coder decodeIntegerForKey:@"NSNumberOfTickMarks"];
    _majorTicks = [coder decodeIntegerForKey:@"NSNumberOfMajorTickMarks"];
    _tickPosition = (NSTickMarkPosition)[coder decodeIntegerForKey:@"NSTickMarkPosition"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeDouble:_value forKey:@"NSValue"];
    if (_min)
        [coder encodeDouble:_min forKey:@"NSMinValue"];
    [coder encodeDouble:_max forKey:@"NSMaxValue"];
    if (_warning)
        [coder encodeDouble:_warning forKey:@"NSWarningValue"];
    if (_critical)
        [coder encodeDouble:_critical forKey:@"NSCriticalValue"];
    [coder encodeInteger:_style forKey:@"NSIndicatorStyle"];
    if (_ticks)
        [coder encodeInteger:_ticks forKey:@"NSNumberOfTickMarks"];
    if (_majorTicks)
        [coder encodeInteger:_majorTicks forKey:@"NSNumberOfMajorTickMarks"];
    if (_tickPosition)
        [coder encodeInteger:_tickPosition forKey:@"NSTickMarkPosition"];
}

- (BOOL)_finchClickChangesState { return NO; }
- (BOOL)acceptsFirstResponder { return [self isEditable] && [self isEnabled] && ![self refusesFirstResponder]; }

#pragma mark Value

- (void)_finchStore:(double)v
{
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
- (NSLevelIndicatorStyle)levelIndicatorStyle { return _style; }

- (void)setLevelIndicatorStyle:(NSLevelIndicatorStyle)style
{
    _style = style;
    [self _finchChanged];
}

- (double)minValue { return _min; }
- (void)setMinValue:(double)v { _min = v; [self _finchChanged]; }
- (double)maxValue { return _max; }
- (void)setMaxValue:(double)v { _max = v; [self _finchChanged]; }
- (double)warningValue { return _warning; }
- (void)setWarningValue:(double)v { _warning = v; [self _finchChanged]; }
- (double)criticalValue { return _critical; }
- (void)setCriticalValue:(double)v { _critical = v; [self _finchChanged]; }
- (NSTickMarkPosition)tickMarkPosition { return _tickPosition; }
- (void)setTickMarkPosition:(NSTickMarkPosition)p { _tickPosition = p; [self _finchChanged]; }
- (NSInteger)numberOfTickMarks { return _ticks; }
- (void)setNumberOfTickMarks:(NSInteger)n { _ticks = MAX(n, 0); [self _finchChanged]; }
- (NSInteger)numberOfMajorTickMarks { return _majorTicks; }
- (void)setNumberOfMajorTickMarks:(NSInteger)n { _majorTicks = MAX(n, 0); [self _finchChanged]; }

- (double)tickMarkValueAtIndex:(NSInteger)index
{
    if (index < 0 || index >= _ticks)
        [NSException raise:NSRangeException format:@"tick mark index %ld out of range (%ld tick marks)", (long)index,
                                                    (long)_ticks];
    return _ticks == 1 ? (_min + _max) / 2 : _min + (_max - _min) * index / (double)(_ticks - 1);
}

- (NSRect)_finchFrame
{
    NSView *v = [self controlView];
    return v ? [v bounds] : NSZeroRect;
}

- (NSRect)rectOfTickMarkAtIndex:(NSInteger)index
{
    double v = [self tickMarkValueAtIndex:index];
    NSRect f = [self _finchFrame];
    double frac = _max > _min ? (v - _min) / (_max - _min) : 0;
    BOOL major = _majorTicks > 1 && _ticks > 1 && index % MAX(1, (_ticks - 1) / (_majorTicks - 1)) == 0;
    CGFloat h = major ? 5 : 3;
    BOOL flipped = [[self controlView] isFlipped];
    BOOL above = _tickPosition == NSTickMarkPositionAbove;
    CGFloat y = (above != flipped) ? NSMaxY(f) - h : f.origin.y;
    return NSMakeRect(round(f.origin.x + 1 + frac * (f.size.width - 2)) - 0.5, y, 1, h);
}

#pragma mark Geometry and drawing

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    if (_style == NSLevelIndicatorStyleRating)
        return NSMakeSize(MAX(0, _max) * 12, 12);
    return NSMakeSize(40000, 16 + (_ticks > 0 ? 6 : 0));
}

/* The bar, leaving room for tick marks. */
- (NSRect)_finchBar:(NSRect)frame flipped:(BOOL)flipped
{
    CGFloat h = MIN(frame.size.height, _style == NSLevelIndicatorStyleRelevancy ? 12 : 14);
    NSRect r = NSMakeRect(frame.origin.x, floor(NSMidY(frame) - h / 2), frame.size.width, h);
    if (_ticks > 0) {
        BOOL above = _tickPosition == NSTickMarkPositionAbove;
        if (above != flipped)
            r.origin.y = frame.origin.y;
        else
            r.origin.y = NSMaxY(frame) - h;
        r.size.height = MIN(h, frame.size.height - 6);
    }
    return r;
}

- (NSColor *)_finchColorFor:(double)level
{
    NSView *v = [self controlView];
    NSColor *normal = nil, *warning = nil, *critical = nil;
    if ([v isKindOfClass:[NSLevelIndicator class]]) {
        normal = [(NSLevelIndicator *)v fillColor];
        warning = [(NSLevelIndicator *)v warningFillColor];
        critical = [(NSLevelIndicator *)v criticalFillColor];
    }
    normal = normal ?: [NSColor systemGreenColor];
    warning = warning ?: [NSColor systemYellowColor];
    critical = critical ?: [NSColor systemRedColor];
    BOOL hasCritical = _critical != 0 && _critical != _min, hasWarning = _warning != 0 && _warning != _min;
    if (_critical >= _warning) {
        if (hasCritical && level >= _critical)
            return critical;
        if (hasWarning && level >= _warning)
            return warning;
    } else {
        if (hasCritical && level <= _critical)
            return critical;
        if (hasWarning && level <= _warning)
            return warning;
    }
    return normal;
}

static NSBezierPath *
star(NSRect r)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    NSPoint c = NSMakePoint(NSMidX(r), NSMidY(r));
    CGFloat outer = MIN(r.size.width, r.size.height) / 2, inner = outer * 0.45;
    BOOL flipped = [[NSGraphicsContext currentContext] isFlipped];
    for (int i = 0; i < 10; i++) {
        double a = M_PI * i / 5;
        CGFloat rad = i % 2 ? inner : outer;
        NSPoint q = NSMakePoint(c.x + sin(a) * rad, flipped ? c.y - cos(a) * rad : c.y + cos(a) * rad);
        if (i == 0)
            [p moveToPoint:q];
        else
            [p lineToPoint:q];
    }
    [p closePath];
    return p;
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    BOOL flipped = [view isFlipped], enabled = [self isEnabled];
    double range = _max - _min, level = MAX(_min, MIN(_max, _value));
    double f = range > 0 ? (level - _min) / range : 0;
    NSColor *track = FinchDisabled([NSColor colorWithSRGBRed:0.86 green:0.87 blue:0.89 alpha:1], enabled);
    if (_style == NSLevelIndicatorStyleRating) {
        NSInteger n = (NSInteger)ceil(_max);
        for (NSInteger i = 0; i < n; i++) {
            NSRect s = NSMakeRect(frame.origin.x + i * 12, NSMidY(frame) - 6, 12, 12);
            if (i < (NSInteger)floor(_value + 0.5)) {
                [FinchDisabled([NSColor systemOrangeColor], enabled) setFill];
                [star(NSInsetRect(s, 0.5, 0.5)) fill];
            } else {
                [track setFill];
                [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(s) - 1.5, NSMidY(s) - 1.5, 3, 3)] fill];
            }
        }
        return;
    }
    NSRect bar = [self _finchBar:frame flipped:flipped];
    if (_style == NSLevelIndicatorStyleRelevancy) {
        FinchDrawBezel(bar, 2, track, nil);
        NSRect fill = bar;
        fill.size.width = round(bar.size.width * f);
        if (fill.size.width > 0)
            FinchDrawBezel(fill, 2, FinchDisabled([NSColor secondaryLabelColor], enabled), nil);
    } else if (_style == NSLevelIndicatorStyleDiscreteCapacity && range > 0) {
        NSInteger n = (NSInteger)ceil(range);
        CGFloat gap = 2, w = (bar.size.width - gap * (n - 1)) / n;
        NSColor *color = FinchDisabled([self _finchColorFor:level], enabled);
        for (NSInteger i = 0; i < n; i++) {
            NSRect seg = NSMakeRect(round(bar.origin.x + i * (w + gap)), bar.origin.y, floor(w), bar.size.height);
            FinchDrawBezel(seg, 2, i < (NSInteger)floor(level - _min + 0.5) ? color : track, nil);
        }
    } else {
        FinchDrawBezel(bar, 3, track, nil);
        NSRect fill = bar;
        fill.size.width = round(bar.size.width * f);
        if (fill.size.width > 0)
            FinchDrawBezel(fill, 3, FinchDisabled([self _finchColorFor:level], enabled), nil);
    }
    if (_ticks > 0) {
        [FinchDisabled(FinchControlStroke(), enabled) setFill];
        for (NSInteger i = 0; i < _ticks; i++)
            NSRectFill([self rectOfTickMarkAtIndex:i]);
    }
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view
{
    [self drawWithFrame:frame inView:view];
}

#pragma mark Editing by clicking

- (double)_finchValueAt:(NSPoint)p frame:(NSRect)frame
{
    if (_style == NSLevelIndicatorStyleRating)
        return MAX(_min, MIN(_max, ceil((p.x - frame.origin.x) / 12)));
    double f = frame.size.width > 0 ? (p.x - frame.origin.x) / frame.size.width : 0;
    f = MAX(0, MIN(1, f));
    double v = _min + f * (_max - _min);
    return _style == NSLevelIndicatorStyleDiscreteCapacity ? ceil(v - 1e-9) : v;
}

- (BOOL)trackMouse:(NSEvent *)event inRect:(NSRect)frame ofView:(NSView *)view untilMouseUp:(BOOL)untilUp
{
    if (![self isEditable] || ![self isEnabled])
        return NO;
    NSWindow *w = [view window];
    NSPoint p = [view convertPoint:[event locationInWindow] fromView:nil];
    [self setDoubleValue:[self _finchValueAt:p frame:frame]];
    [view setNeedsDisplay:YES];
    while ([event type] != NSEventTypeLeftMouseUp) {
        NSEvent *e = [w nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        if (!e)
            break;
        event = e;
        p = [view convertPoint:[e locationInWindow] fromView:nil];
        [self setDoubleValue:[self _finchValueAt:p frame:frame]];
        [view setNeedsDisplay:YES];
        if ([self isContinuous])
            [self _finchSendAction];
    }
    [self _finchSendAction];
    return YES;
}

@end
