/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSScroller: a scroll bar, in Finch's own look: a flat, rounded,
 * translucent knob over the content (overlay style), no arrows. Its value
 * runs from 0 (top or left) to 1, its knob proportion is the visible part
 * of the document. Dragging the knob, or clicking the track to jump there,
 * sends the action (to the scroll view, which scrolls).
 *
 * The value, proportion, enabled state, target and action are kept here
 * rather than in a cell, so the scroller works whatever NSControl does.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"

/* NSControl is another file's; until it lands, a bare one keeps the build linking. */
#if !__has_include("NSControl.m")
@implementation NSControl
@end
#endif

NSNotificationName const NSPreferredScrollerStyleDidChangeNotification = @"NSPreferredScrollerStyleDidChangeNotification";

static const CGFloat kWidth = 15, kInset = 3, kMinKnob = 18;

@implementation NSScroller {
    double _value;
    CGFloat _proportion;
    id _target;  /* not retained */
    SEL _action;
    NSScrollerPart _hitPart;
    NSControlSize _controlSize;
    NSScrollerKnobStyle _knobStyle;
    NSScrollerStyle _style;
    CGFloat _grab;  /* where in the knob the drag started */
    BOOL _enabled, _horizontal, _tracking;
}

+ (BOOL)isCompatibleWithOverlayScrollers { return self == [NSScroller class]; }
+ (NSScrollerStyle)preferredScrollerStyle { return NSScrollerStyleOverlay; }

+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)controlSize scrollerStyle:(NSScrollerStyle)scrollerStyle
{
    if (controlSize == NSControlSizeSmall || controlSize == NSControlSizeMini)
        return 11;
    return kWidth;
}

+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)controlSize
{
    return [self scrollerWidthForControlSize:controlSize scrollerStyle:NSScrollerStyleLegacy];
}

+ (CGFloat)scrollerWidth { return [self scrollerWidthForControlSize:NSControlSizeRegular]; }

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _horizontal = frame.size.width > frame.size.height;
        _style = [NSScroller preferredScrollerStyle];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (double)doubleValue { return _value; }
- (void)setDoubleValue:(double)value
{
    _value = MAX(0, MIN(1, value));
    [self setNeedsDisplay:YES];
}
- (float)floatValue { return (float)_value; }
- (void)setFloatValue:(float)value { [self setDoubleValue:value]; }
- (CGFloat)knobProportion { return _proportion; }
- (void)setKnobProportion:(CGFloat)proportion
{
    _proportion = MAX(0, MIN(1, proportion));
    [self setNeedsDisplay:YES];
}
- (void)setFloatValue:(float)value knobProportion:(CGFloat)proportion
{
    [self setKnobProportion:proportion];
    [self setDoubleValue:value];
}
- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)flag
{
    _enabled = flag;
    [self setNeedsDisplay:YES];
}
- (id)target { return _target; }
- (void)setTarget:(id)target { _target = target; }
- (SEL)action { return _action; }
- (void)setAction:(SEL)action { _action = action; }
- (NSScrollerPart)hitPart { return _hitPart; }
- (NSControlSize)controlSize { return _controlSize; }
- (void)setControlSize:(NSControlSize)size { _controlSize = size; }
- (NSScrollerKnobStyle)knobStyle { return _knobStyle; }
- (void)setKnobStyle:(NSScrollerKnobStyle)style
{
    _knobStyle = style;
    [self setNeedsDisplay:YES];
}
- (NSScrollerStyle)scrollerStyle { return _style; }
- (void)setScrollerStyle:(NSScrollerStyle)style { _style = style; }
- (NSScrollArrowPosition)arrowsPosition { return NSScrollerArrowsNone; }
- (void)setArrowsPosition:(NSScrollArrowPosition)where {}
- (NSControlTint)controlTint { return NSDefaultControlTint; }
- (void)setControlTint:(NSControlTint)tint {}
- (void)checkSpaceForParts {}

- (NSUsableScrollerParts)usableParts
{
    if (!_enabled || _proportion <= 0 || _proportion >= 1)
        return NSNoScrollerParts;
    return NSAllScrollerParts;
}

/* The track the knob runs in, and the knob. */
static NSRect
track_rect(NSScroller *self)
{
    return NSInsetRect([self bounds], 2, 2);
}

static CGFloat
knob_length(NSScroller *self, NSRect track)
{
    CGFloat len = self->_horizontal ? NSWidth(track) : NSHeight(track);
    return MIN(len, MAX(kMinKnob, len * self->_proportion));
}

- (NSRect)rectForPart:(NSScrollerPart)part
{
    NSRect track = track_rect(self);
    switch (part) {
    case NSScrollerKnobSlot:
        return track;
    case NSScrollerKnob: {
        if ([self usableParts] == NSNoScrollerParts)
            return NSZeroRect;
        CGFloat k = knob_length(self, track);
        if (_horizontal)
            return NSMakeRect(NSMinX(track) + (NSWidth(track) - k) * _value, NSMinY(track), k, NSHeight(track));
        return NSMakeRect(NSMinX(track), NSMinY(track) + (NSHeight(track) - k) * _value, NSWidth(track), k);
    }
    case NSScrollerDecrementPage: {
        NSRect knob = [self rectForPart:NSScrollerKnob];
        if (_horizontal)
            return NSMakeRect(NSMinX(track), NSMinY(track), NSMinX(knob) - NSMinX(track), NSHeight(track));
        return NSMakeRect(NSMinX(track), NSMinY(track), NSWidth(track), NSMinY(knob) - NSMinY(track));
    }
    case NSScrollerIncrementPage: {
        NSRect knob = [self rectForPart:NSScrollerKnob];
        if (_horizontal)
            return NSMakeRect(NSMaxX(knob), NSMinY(track), NSMaxX(track) - NSMaxX(knob), NSHeight(track));
        return NSMakeRect(NSMinX(track), NSMaxY(knob), NSWidth(track), NSMaxY(track) - NSMaxY(knob));
    }
    default:
        return NSZeroRect;
    }
}

- (NSScrollerPart)testPart:(NSPoint)point
{
    NSPoint p = [self convertPoint:point fromView:nil];
    if (!NSPointInRect(p, [self bounds]) || [self usableParts] == NSNoScrollerParts)
        return NSScrollerNoPart;
    if (NSPointInRect(p, [self rectForPart:NSScrollerKnob]))
        return NSScrollerKnob;
    if (NSPointInRect(p, [self rectForPart:NSScrollerDecrementPage]))
        return NSScrollerDecrementPage;
    if (NSPointInRect(p, [self rectForPart:NSScrollerIncrementPage]))
        return NSScrollerIncrementPage;
    return NSScrollerKnobSlot;
}

#pragma mark - Drawing

- (void)drawKnobSlotInRect:(NSRect)slotRect highlight:(BOOL)flag
{
    if (!_tracking)
        return;
    [[NSColor colorWithWhite:0.5 alpha:0.12] setFill];
    CGFloat r = (_horizontal ? NSHeight(slotRect) : NSWidth(slotRect)) / 2;
    [[NSBezierPath bezierPathWithRoundedRect:slotRect xRadius:r yRadius:r] fill];
}

- (void)drawKnob
{
    NSRect knob = [self rectForPart:NSScrollerKnob];
    if (NSIsEmptyRect(knob))
        return;
    /* thin when idle, full width while dragged */
    CGFloat shrink = _tracking ? 0 : kInset - 2;
    knob = _horizontal ? NSInsetRect(knob, 0, shrink) : NSInsetRect(knob, shrink, 0);
    NSColor *c = _knobStyle == NSScrollerKnobStyleLight ? [NSColor colorWithWhite:1 alpha:0.6]
                                                        : [NSColor colorWithWhite:0 alpha:_tracking ? 0.55 : 0.4];
    [c setFill];
    CGFloat r = (_horizontal ? NSHeight(knob) : NSWidth(knob)) / 2;
    [[NSBezierPath bezierPathWithRoundedRect:knob xRadius:r yRadius:r] fill];
}

- (void)drawRect:(NSRect)dirtyRect
{
    if ([self usableParts] == NSNoScrollerParts)
        return;
    [self drawKnobSlotInRect:[self rectForPart:NSScrollerKnobSlot] highlight:NO];
    [self drawKnob];
}

- (void)drawParts {}
- (void)highlight:(BOOL)flag {}
- (void)drawArrow:(NSScrollerArrow)whichArrow highlight:(BOOL)flag {}

#pragma mark - Events

/* Clicks on a scroller with nothing to scroll go to what is under it. */
- (NSView *)hitTest:(NSPoint)point
{
    if ([self usableParts] == NSNoScrollerParts)
        return nil;
    return [super hitTest:point];
}

static void
send_action(NSScroller *self)
{
    if (self->_action)
        [NSApp sendAction:self->_action to:self->_target from:self];
}

static CGFloat
along(NSScroller *self, NSPoint p)
{
    return self->_horizontal ? p.x : p.y;
}

- (void)mouseDown:(NSEvent *)event
{
    if ([self usableParts] == NSNoScrollerParts)
        return;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSRect knob = [self rectForPart:NSScrollerKnob];
    NSRect track = track_rect(self);
    CGFloat k = knob_length(self, track);
    _tracking = YES;
    if (NSPointInRect(p, knob)) {
        _grab = along(self, p) - (_horizontal ? NSMinX(knob) : NSMinY(knob));
    } else {
        /* jump there, then drag from the knob's middle */
        _grab = k / 2;
        [self mouseDragged:event];
    }
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event
{
    if (!_tracking)
        return;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSRect track = track_rect(self);
    CGFloat k = knob_length(self, track);
    CGFloat room = (_horizontal ? NSWidth(track) : NSHeight(track)) - k;
    CGFloat start = _horizontal ? NSMinX(track) : NSMinY(track);
    double v = room > 0 ? (along(self, p) - _grab - start) / room : 0;
    [self setDoubleValue:v];
    _hitPart = NSScrollerKnob;
    send_action(self);
}

- (void)mouseUp:(NSEvent *)event
{
    _tracking = NO;
    _hitPart = NSScrollerNoPart;
    [self setNeedsDisplay:YES];
}

- (void)trackKnob:(NSEvent *)event { [self mouseDown:event]; }
- (void)trackScrollButtons:(NSEvent *)event {}

#pragma mark - Archiving

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    NSRect f = [self frame];
    _horizontal = ([coder decodeIntForKey:@"NSsFlags"] & 1) || f.size.width > f.size.height;
    _style = [NSScroller preferredScrollerStyle];
    _target = [coder decodeObjectForKey:@"NSTarget"] ?: [coder decodeObjectForKey:@"NSControlTarget"];
    NSString *action = [coder decodeObjectForKey:@"NSAction"] ?: [coder decodeObjectForKey:@"NSControlAction"];
    if ([action isKindOfClass:[NSString class]])
        _action = NSSelectorFromString(action);
    if ([coder containsValueForKey:@"NSCurValue"])
        _value = [coder decodeDoubleForKey:@"NSCurValue"];
    if ([coder containsValueForKey:@"NSPercent"])
        _proportion = [coder decodeDoubleForKey:@"NSPercent"];
    if ([coder containsValueForKey:@"NSControlSize"])
        _controlSize = [coder decodeIntegerForKey:@"NSControlSize"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_horizontal)
        [coder encodeInt:1 forKey:@"NSsFlags"];
    if (_target)
        [coder encodeConditionalObject:_target forKey:@"NSTarget"];
    if (_action)
        [coder encodeObject:NSStringFromSelector(_action) forKey:@"NSAction"];
    [coder encodeDouble:_value forKey:@"NSCurValue"];
    [coder encodeDouble:_proportion forKey:@"NSPercent"];
}

@end
