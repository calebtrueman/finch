/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSlider: an NSControl over an NSSliderCell. Flipped, continuous, and
 * horizontal or vertical by its shape unless told, as Apple's. The arrow
 * keys move the value by the alternate increment, a tick mark, or a
 * twentieth of the range.
 */
#import "NSControl_Finch.h"

@implementation NSSlider {
    NSColor *_trackFillColor;
    double _neutralValue;
    NSTintProminence _tintProminence;
}

+ (Class)cellClass
{
    return [super cellClass] ?: [NSSliderCell class];
}

+ (instancetype)sliderWithTarget:(id)target action:(SEL)action
{
    NSSlider *s = [[[self alloc] initWithFrame:NSMakeRect(0, 0, 100, 16)] autorelease];
    [s setTarget:target];
    [s setAction:action];
    return s;
}

+ (instancetype)sliderWithValue:(double)value minValue:(double)minValue maxValue:(double)maxValue target:(id)target
                         action:(SEL)action
{
    NSSlider *s = [self sliderWithTarget:target action:action];
    [s setMinValue:minValue];
    [s setMaxValue:maxValue];
    [s setDoubleValue:value];
    return s;
}

- (void)dealloc
{
    [_trackFillColor release];
    [super dealloc];
}

static NSSliderCell *
cell_of(NSSlider *s)
{
    id c = [s cell];
    return [c isKindOfClass:[NSSliderCell class]] ? c : nil;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (NSSliderType)sliderType { return [cell_of(self) sliderType]; }
- (void)setSliderType:(NSSliderType)t { [cell_of(self) setSliderType:t]; }
- (double)minValue { return [cell_of(self) minValue]; }
- (void)setMinValue:(double)v { [cell_of(self) setMinValue:v]; [self setNeedsDisplay:YES]; }
- (double)maxValue { return [cell_of(self) maxValue]; }
- (void)setMaxValue:(double)v { [cell_of(self) setMaxValue:v]; [self setNeedsDisplay:YES]; }
- (double)neutralValue { return _neutralValue; }
- (void)setNeutralValue:(double)v { _neutralValue = v; }
- (double)altIncrementValue { return [cell_of(self) altIncrementValue]; }
- (void)setAltIncrementValue:(double)v { [cell_of(self) setAltIncrementValue:v]; }
- (CGFloat)knobThickness { return [cell_of(self) knobThickness]; }
- (void)setKnobThickness:(CGFloat)t {}
- (BOOL)isVertical { return [cell_of(self) isVertical]; }
- (void)setVertical:(BOOL)flag { [cell_of(self) setVertical:flag]; }
- (NSColor *)trackFillColor { return _trackFillColor; }

- (void)setTrackFillColor:(NSColor *)color
{
    [_trackFillColor release];
    _trackFillColor = [color copy];
    [self setNeedsDisplay:YES];
}

- (NSTintProminence)tintProminence { return _tintProminence; }
- (void)setTintProminence:(NSTintProminence)p { _tintProminence = p; }
- (NSInteger)numberOfTickMarks { return [cell_of(self) numberOfTickMarks]; }
- (void)setNumberOfTickMarks:(NSInteger)n { [cell_of(self) setNumberOfTickMarks:n]; [self setNeedsDisplay:YES]; }
- (NSTickMarkPosition)tickMarkPosition { return [cell_of(self) tickMarkPosition]; }
- (void)setTickMarkPosition:(NSTickMarkPosition)p { [cell_of(self) setTickMarkPosition:p]; }
- (BOOL)allowsTickMarkValuesOnly { return [cell_of(self) allowsTickMarkValuesOnly]; }
- (void)setAllowsTickMarkValuesOnly:(BOOL)flag { [cell_of(self) setAllowsTickMarkValuesOnly:flag]; }
- (double)tickMarkValueAtIndex:(NSInteger)index { return [cell_of(self) tickMarkValueAtIndex:index]; }
- (NSRect)rectOfTickMarkAtIndex:(NSInteger)index { return [cell_of(self) rectOfTickMarkAtIndex:index]; }
- (NSInteger)indexOfTickMarkAtPoint:(NSPoint)p { return [cell_of(self) indexOfTickMarkAtPoint:p]; }
- (double)closestTickMarkValueToValue:(double)v { return [cell_of(self) closestTickMarkValueToValue:v]; }
- (id)titleCell { return nil; }
- (void)setTitleCell:(NSCell *)cell {}
- (NSColor *)titleColor { return nil; }
- (void)setTitleColor:(NSColor *)color {}
- (NSFont *)titleFont { return nil; }
- (void)setTitleFont:(NSFont *)font {}
- (NSString *)title { return nil; }
- (void)setTitle:(NSString *)title {}
- (NSImage *)image { return nil; }
- (void)setImage:(NSImage *)image {}

- (NSSize)intrinsicContentSize
{
    NSSliderCell *c = cell_of(self);
    NSSize s = [c cellSize];
    if ([c sliderType] == NSSliderTypeCircular)
        return s;
    if ([c isVertical])
        return NSMakeSize(s.width, NSViewNoIntrinsicMetric);
    return NSMakeSize(NSViewNoIntrinsicMetric, s.height);
}

- (void)sizeToFit
{
    NSSize s = [self intrinsicContentSize];
    NSSize f = [self frame].size;
    [self setFrameSize:NSMakeSize(s.width == NSViewNoIntrinsicMetric ? f.width : s.width,
                                  s.height == NSViewNoIntrinsicMetric ? f.height : s.height)];
}

#pragma mark Keys

- (void)keyDown:(NSEvent *)event
{
    [self interpretKeyEvents:@[ event ]];
}

- (void)_finchStep:(int)direction
{
    NSSliderCell *c = cell_of(self);
    if (!c || ![self isEnabled])
        return;
    double step = [c altIncrementValue];
    if (step <= 0)
        step = [c numberOfTickMarks] > 1 ? ([c maxValue] - [c minValue]) / ([c numberOfTickMarks] - 1)
                                         : ([c maxValue] - [c minValue]) / 20;
    [c setDoubleValue:[c doubleValue] + direction * step];
    [self setNeedsDisplay:YES];
    [self sendAction:[self action] to:[self target]];
}

- (void)moveUp:(id)sender { [self _finchStep:1]; }
- (void)moveRight:(id)sender { [self _finchStep:1]; }
- (void)moveDown:(id)sender { [self _finchStep:-1]; }
- (void)moveLeft:(id)sender { [self _finchStep:-1]; }
- (void)pageUp:(id)sender { [self _finchStep:5]; }
- (void)pageDown:(id)sender { [self _finchStep:-5]; }

- (BOOL)_finchBecomesFirstResponderOnClick { return NO; }

@end
