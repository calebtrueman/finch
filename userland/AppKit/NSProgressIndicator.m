/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSProgressIndicator: a bar (determinate or not) or a spinner. A plain
 * flipped NSView, as Apple's; the defaults (indeterminate, bezeled, 0 to
 * 100, shown when stopped) and sizes to fit are Apple's, measured by
 * finch-appkit-controls-test. The value is clamped when set, not when the
 * range changes.
 *
 * Nib keys: NSpiFlags (0x1 bezeled, 0x2 indeterminate, 0x300 control size,
 * 0x1000 spinning, 0x2000 hidden when stopped), NSMinValue, NSMaxValue,
 * NSProgressIndicatorDoubleValue.
 *
 * Drawn in Finch's own flat look: a rounded track filled with the accent
 * colour, an indeterminate bar as a band at a fixed place, the spinner as
 * spokes fading round the circle. Animation advances the band and spokes
 * on a timer while the indicator is in a window.
 */
#import "NSControl_Finch.h"

enum {
    PI_BEZELED = 0x1,
    PI_INDETERMINATE = 0x2,
    PI_SIZE_SHIFT = 8,
    PI_SPINNING = 0x1000,
    PI_HIDDEN_WHEN_STOPPED = 0x2000,
};

@implementation NSProgressIndicator {
    double _value, _min, _max;
    NSProgressIndicatorStyle _style;
    NSControlSize _controlSize;
    NSControlTint _tint;
    NSProgress *_observed;
    NSTimer *_timer;
    NSTimeInterval _animationDelay;
    unsigned _phase;
    struct {
        unsigned indeterminate : 1;
        unsigned bezeled : 1;
        unsigned displayedWhenStopped : 1;
        unsigned threaded : 1;
        unsigned animating : 1;
    } _p;
}

static void
pi_defaults(NSProgressIndicator *self)
{
    self->_max = 100;
    self->_p.indeterminate = YES;
    self->_p.bezeled = YES;
    self->_p.displayedWhenStopped = YES;
    self->_p.threaded = YES;
    self->_animationDelay = 5.0 / 60.0;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
        pi_defaults(self);
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    pi_defaults(self);
    unsigned f = (unsigned)[coder decodeIntForKey:@"NSpiFlags"];
    if ([coder containsValueForKey:@"NSpiFlags"]) {
        _p.bezeled = (f & PI_BEZELED) != 0;
        _p.indeterminate = (f & PI_INDETERMINATE) != 0;
        _p.displayedWhenStopped = !(f & PI_HIDDEN_WHEN_STOPPED);
        _style = (f & PI_SPINNING) ? NSProgressIndicatorStyleSpinning : NSProgressIndicatorStyleBar;
        _controlSize = (f >> PI_SIZE_SHIFT) & 3;
    }
    _min = [coder decodeDoubleForKey:@"NSMinValue"];
    if ([coder containsValueForKey:@"NSMaxValue"])
        _max = [coder decodeDoubleForKey:@"NSMaxValue"];
    _value = [coder decodeDoubleForKey:@"NSProgressIndicatorDoubleValue"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    unsigned f = 0x4 | (_p.bezeled ? PI_BEZELED : 0) | (_p.indeterminate ? PI_INDETERMINATE : 0) |
                 ((unsigned)(_controlSize & 3) << PI_SIZE_SHIFT) |
                 (_style == NSProgressIndicatorStyleSpinning ? PI_SPINNING : 0) |
                 (_p.displayedWhenStopped ? 0 : PI_HIDDEN_WHEN_STOPPED);
    [coder encodeInt:(int)f forKey:@"NSpiFlags"];
    if (_min)
        [coder encodeDouble:_min forKey:@"NSMinValue"];
    [coder encodeDouble:_max forKey:@"NSMaxValue"];
    if (_value)
        [coder encodeDouble:_value forKey:@"NSProgressIndicatorDoubleValue"];
}

- (void)dealloc
{
    [_timer invalidate];
    [_timer release];
    [_observed release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }

#pragma mark State

- (BOOL)isIndeterminate { return _p.indeterminate; }

- (void)setIndeterminate:(BOOL)flag
{
    _p.indeterminate = flag;
    [self setNeedsDisplay:YES];
}

- (BOOL)isBezeled { return _p.bezeled; }

- (void)setBezeled:(BOOL)flag
{
    _p.bezeled = flag;
    [self setNeedsDisplay:YES];
}

- (NSControlTint)controlTint { return _tint; }
- (void)setControlTint:(NSControlTint)tint { _tint = tint; }
- (NSControlSize)controlSize { return _controlSize; }

- (void)setControlSize:(NSControlSize)size
{
    _controlSize = size;
    [self setNeedsDisplay:YES];
}

- (double)doubleValue { return _value; }

- (void)setDoubleValue:(double)v
{
    v = MAX(_min, MIN(_max, v));
    if (v == _value)
        return;
    _value = v;
    if (!_p.indeterminate)
        [self setNeedsDisplay:YES];
}

- (void)incrementBy:(double)delta { [self setDoubleValue:_value + delta]; }
- (double)minValue { return _min; }

- (void)setMinValue:(double)v
{
    _min = v;
    [self setNeedsDisplay:YES];
}

- (double)maxValue { return _max; }

- (void)setMaxValue:(double)v
{
    _max = v;
    [self setNeedsDisplay:YES];
}

- (NSProgress *)observedProgress { return _observed; }

- (void)setObservedProgress:(NSProgress *)progress
{
    [progress retain];
    [_observed release];
    _observed = progress;
    [self setNeedsDisplay:YES];
}

- (BOOL)usesThreadedAnimation { return _p.threaded; }
- (void)setUsesThreadedAnimation:(BOOL)flag { _p.threaded = flag; }
- (NSProgressIndicatorStyle)style { return _style; }

- (void)setStyle:(NSProgressIndicatorStyle)style
{
    _style = style;
    [self setNeedsDisplay:YES];
}

- (BOOL)isDisplayedWhenStopped { return _p.displayedWhenStopped; }

- (void)setDisplayedWhenStopped:(BOOL)flag
{
    _p.displayedWhenStopped = flag;
    [self setNeedsDisplay:YES];
}

- (NSTimeInterval)animationDelay { return _animationDelay; }
- (void)setAnimationDelay:(NSTimeInterval)delay { _animationDelay = delay; }

#pragma mark Animation

- (void)_finchTick:(NSTimer *)timer
{
    _phase++;
    [self setNeedsDisplay:YES];
}

- (void)_finchStopTimer
{
    [_timer invalidate];
    [_timer release];
    _timer = nil;
}

- (void)_finchStartTimerIfShown
{
    if (!_p.animating || _timer || ![self window])
        return;
    if (_style != NSProgressIndicatorStyleSpinning && !_p.indeterminate)
        return;
    _timer = [[NSTimer timerWithTimeInterval:1.0 / 12 target:self selector:@selector(_finchTick:) userInfo:nil
                                     repeats:YES] retain];
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)startAnimation:(id)sender
{
    if (_p.animating)
        return;
    _p.animating = YES;
    [self _finchStartTimerIfShown];
    [self setNeedsDisplay:YES];
}

- (void)stopAnimation:(id)sender
{
    if (!_p.animating)
        return;
    _p.animating = NO;
    [self _finchStopTimer];
    [self setNeedsDisplay:YES];
}

- (void)animate:(id)sender
{
    _phase++;
    [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window])
        [self _finchStartTimerIfShown];
    else
        [self _finchStopTimer];
}

#pragma mark Size

- (CGFloat)_finchSpinnerSize
{
    switch (_controlSize) {
    case NSControlSizeSmall: return 16;
    case NSControlSizeMini: return 10;
    default: return 32;
    }
}

- (CGFloat)_finchBarHeight
{
    switch (_controlSize) {
    case NSControlSizeSmall: return 12;
    case NSControlSizeMini: return 10;
    default: return 20;
    }
}

- (NSSize)intrinsicContentSize
{
    if (_style == NSProgressIndicatorStyleSpinning) {
        CGFloat s = [self _finchSpinnerSize];
        return NSMakeSize(s, s);
    }
    return NSMakeSize(NSViewNoIntrinsicMetric, [self _finchBarHeight]);
}

- (void)sizeToFit
{
    NSSize s = [self intrinsicContentSize];
    if (s.width == NSViewNoIntrinsicMetric)
        s.width = [self frame].size.width;
    [self setFrameSize:s];
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirty
{
    if (!_p.animating && !_p.displayedWhenStopped &&
        (_style == NSProgressIndicatorStyleSpinning || _p.indeterminate))
        return;
    NSRect b = [self bounds];
    if (_style == NSProgressIndicatorStyleSpinning) {
        [self _finchDrawSpinner:b];
        return;
    }
    CGFloat h = _controlSize == NSControlSizeRegular || _controlSize == NSControlSizeLarge ? 6 : 4;
    h = MIN(h, b.size.height);
    NSRect track = NSMakeRect(b.origin.x, floor(NSMidY(b) - h / 2), b.size.width, h);
    FinchDrawBezel(track, h / 2, [NSColor colorWithSRGBRed:0.86 green:0.87 blue:0.89 alpha:1], nil);
    NSRect fill = track;
    if (_p.indeterminate) {
        /* a band a third of the track, moved along by the animation */
        CGFloat w = track.size.width / 3, span = track.size.width - w;
        CGFloat t = span > 0 ? fmod(_phase * 6.0, 2 * span) : 0;
        if (t > span)
            t = 2 * span - t;
        fill.origin.x += t;
        fill.size.width = w;
    } else {
        double f = _max > _min ? (MAX(_min, MIN(_max, _value)) - _min) / (_max - _min) : 0;
        if (_observed)
            f = MAX(0, MIN(1, [_observed fractionCompleted]));
        fill.size.width = round(track.size.width * f);
    }
    if (fill.size.width > 0)
        FinchDrawBezel(fill, h / 2, FinchAccentColor(), nil);
}

- (void)_finchDrawSpinner:(NSRect)b
{
    CGFloat d = MIN(b.size.width, b.size.height);
    NSPoint c = NSMakePoint(NSMidX(b), NSMidY(b));
    int spokes = 8;
    CGFloat outer = d / 2 - 1, inner = outer * 0.5, width = MAX(1.5, d / 12);
    for (int i = 0; i < spokes; i++) {
        double a = 2 * M_PI * i / spokes;
        int age = (int)((i - (int)(_phase % spokes) + spokes) % spokes);
        CGFloat alpha = _p.animating ? 0.25 + 0.75 * (spokes - 1 - age) / (spokes - 1) : 0.25 + 0.6 * i / (spokes - 1);
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(c.x + sin(a) * inner, c.y - cos(a) * inner)];
        [p lineToPoint:NSMakePoint(c.x + sin(a) * outer, c.y - cos(a) * outer)];
        [p setLineWidth:width];
        [p setLineCapStyle:NSLineCapStyleRound];
        [[NSColor colorWithSRGBRed:0.35 green:0.36 blue:0.4 alpha:alpha] setStroke];
        [p stroke];
    }
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement { return YES; }
- (id)accessibilityValue { return @(_value); }

@end
