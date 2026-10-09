/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A switch keeps its value without a cell. Mouse and keyboard clicks share one action path. */
#import "NSControl_Finch.h"
#import "NSKeyValueBinding_Finch.h"

@implementation NSSwitch {
    NSControlStateValue _state;
    BOOL _hasValue, _pressed;
    NSControlSize _size;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _state = [coder containsValueForKey:@"NSState"] ? [coder decodeIntegerForKey:@"NSState"] : [[coder decodeObjectForKey:@"NSControlContents"] integerValue];
        _hasValue = [coder containsValueForKey:@"NSState"] || [coder containsValueForKey:@"NSControlContents"];
        _size = [coder decodeIntegerForKey:@"NSControlSize"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_hasValue) [coder encodeInteger:_state forKey:@"NSState"];
    [coder encodeInteger:_size forKey:@"NSControlSize"];
}
- (NSControlStateValue)state { return _state; }
- (void)setState:(NSControlStateValue)value { _state = value; _hasValue = YES; [self setNeedsDisplay:YES]; }
- (id)objectValue { return _hasValue ? @(_state) : nil; }
- (void)setObjectValue:(id)value { NSInteger n = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; [self setState:n == -1 ? -1 : n != 0]; }
- (NSString *)stringValue { return _hasValue ? [@(_state) stringValue] : @""; }
- (void)setStringValue:(NSString *)s { [self setObjectValue:s]; }
- (NSInteger)integerValue { return _state; }
- (void)setIntegerValue:(NSInteger)n { [self setObjectValue:@(n)]; }
- (int)intValue { return (int)_state; }
- (void)setIntValue:(int)n { [self setObjectValue:@(n)]; }
- (double)doubleValue { return _state; }
- (void)setDoubleValue:(double)n { [self setObjectValue:@(n)]; }
- (float)floatValue { return _state; }
- (void)setFloatValue:(float)n { [self setObjectValue:@(n)]; }
- (NSControlSize)controlSize { return _size; }
- (void)setControlSize:(NSControlSize)s { _size = s; [self setNeedsDisplay:YES]; }
- (NSSize)intrinsicContentSize { return NSMakeSize(54, 24); }
- (BOOL)acceptsFirstResponder { return [self isEnabled] && ![self refusesFirstResponder]; }
- (BOOL)isFlipped { return YES; }
- (void)performClick:(id)sender
{
    [self setState:_state ? NSControlStateValueOff : NSControlStateValueOn];
    [self sendAction:[self action] to:[self target]];
}
- (void)mouseDown:(NSEvent *)event
{
    if (![self isEnabled]) return;
    [[self window] makeFirstResponder:self];
    _pressed = YES; [self setNeedsDisplay:YES];
    BOOL inside = YES;
    for (;;) {
        NSEvent *next = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
        if (!next) break;
        inside = NSMouseInRect([self convertPoint:[next locationInWindow] fromView:nil], [self bounds], YES);
        _pressed = inside; [self setNeedsDisplay:YES];
        if ([next type] == NSEventTypeLeftMouseUp) break;
    }
    _pressed = NO; [self setNeedsDisplay:YES];
    if (inside) [self performClick:self];
}
- (void)keyDown:(NSEvent *)event
{
    if (![self isEnabled]) return;
    NSString *s = [event charactersIgnoringModifiers];
    if ([s isEqual:@" "] || [s isEqual:@"\r"]) [self performClick:self];
    else [super keyDown:event];
}
- (void)drawRect:(NSRect)dirty
{
    NSRect bounds = [self bounds];
    CGFloat width = MIN(38, bounds.size.width), height = MIN(22, bounds.size.height);
    NSRect track = NSMakeRect(NSMidX(bounds) - width / 2, NSMidY(bounds) - height / 2, width, height);
    NSColor *fill = _state ? FinchAccentColor() : [NSColor colorWithWhite:_pressed ? 0.57 : 0.68 alpha:1];
    FinchDrawBezel(track, height / 2, FinchDisabled(fill, [self isEnabled]), nil);
    CGFloat diameter = height - 4;
    NSRect knob = NSMakeRect(_state ? NSMaxX(track) - diameter - 2 : track.origin.x + 2, track.origin.y + 2, diameter, diameter);
    [[NSColor whiteColor] setFill]; [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilitySubrole { return NSAccessibilitySwitchSubrole; }
- (id)accessibilityValue { return @(_state); }
- (void)setAccessibilityValue:(id)value { [self setObjectValue:value]; [self sendAction:[self action] to:[self target]]; }
- (BOOL)accessibilityPerformPress { if (![self isEnabled]) return NO; [self performClick:self]; return YES; }
- (void)_finchWillSendAction { FinchBindingPush(self, NSValueBinding, @(_state)); }
@end
