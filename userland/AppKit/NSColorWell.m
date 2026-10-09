/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSColorWell: a control (without a cell, as Apple's) showing a colour;
 * its value is the colour. Clicking activates it and, when Finch has a
 * colour panel, shows the panel; without one it only toggles active.
 * Drawn in Finch's own look: a rounded frame around a swatch.
 */
#import "NSControl_Finch.h"

@implementation NSColorWell {
    NSColor *_color;
    NSImage *_image;
    id _pulldownTarget; /* weak */
    SEL _pulldownAction;
    NSColorWellStyle _style;
    CGFloat _maximumLinearExposure;
    struct {
        unsigned bordered : 1;
        unsigned active : 1;
        unsigned continuous : 1;
        unsigned supportsAlpha : 1;
    } _cw;
}

static NSMutableArray *active_wells; /* not retained */

+ (instancetype)colorWellWithStyle:(NSColorWellStyle)style
{
    NSColorWell *w = [[[self alloc] initWithFrame:NSMakeRect(0, 0, 44, 24)] autorelease];
    [w setColorWellStyle:style];
    return w;
}

static void
well_defaults(NSColorWell *self)
{
    self->_color = [[NSColor whiteColor] retain];
    self->_cw.bordered = YES;
    self->_cw.continuous = YES;
    self->_cw.supportsAlpha = YES;
    self->_maximumLinearExposure = 1;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
        well_defaults(self);
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    well_defaults(self);
    NSColor *c = [coder decodeObjectForKey:@"NSColor"];
    if ([c isKindOfClass:[NSColor class]]) {
        [_color release];
        _color = [c retain];
    }
    _cw.bordered = [coder decodeBoolForKey:@"NSIsBordered"];
    [self setEnabled:[coder decodeBoolForKey:@"NSEnabled"]];
    if ([coder containsValueForKey:@"NSColorWellStyle"])
        _style = (NSColorWellStyle)[coder decodeIntegerForKey:@"NSColorWellStyle"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_color forKey:@"NSColor"];
    [coder encodeBool:_cw.bordered forKey:@"NSIsBordered"];
}

- (void)dealloc
{
    [active_wells removeObjectIdenticalTo:self];
    [_color release];
    [_image release];
    [super dealloc];
}

- (NSColor *)color { return _color; }

- (void)setColor:(NSColor *)color
{
    if (!color || color == _color)
        return;
    [_color release];
    _color = [color copy];
    [self setNeedsDisplay:YES];
}

- (void)takeColorFrom:(id)sender
{
    if ([sender respondsToSelector:@selector(color)])
        [self setColor:[sender color]];
}

- (id)objectValue { return _color; }

- (void)setObjectValue:(id)value
{
    if ([value isKindOfClass:[NSColor class]])
        [self setColor:value];
}

- (NSString *)stringValue { return @""; }
- (void)setStringValue:(NSString *)string {}
- (BOOL)isContinuous { return _cw.continuous; }
- (void)setContinuous:(BOOL)flag { _cw.continuous = flag; }
- (BOOL)isBordered { return _cw.bordered; }

- (void)setBordered:(BOOL)flag
{
    _cw.bordered = flag;
    [self setNeedsDisplay:YES];
}

- (NSColorWellStyle)colorWellStyle { return _style; }
- (void)setColorWellStyle:(NSColorWellStyle)style { _style = style; [self setNeedsDisplay:YES]; }
- (NSImage *)image { return _image; }

- (void)setImage:(NSImage *)image
{
    [_image release];
    _image = [image retain];
}

- (id)pulldownTarget { return _pulldownTarget; }
- (void)setPulldownTarget:(id)t { _pulldownTarget = t; }
- (SEL)pulldownAction { return _pulldownAction; }
- (void)setPulldownAction:(SEL)a { _pulldownAction = a; }
- (BOOL)supportsAlpha { return _cw.supportsAlpha; }
- (void)setSupportsAlpha:(BOOL)f { _cw.supportsAlpha = f; }
- (CGFloat)maximumLinearExposure { return _maximumLinearExposure; }
- (void)setMaximumLinearExposure:(CGFloat)v { _maximumLinearExposure = v; }
- (NSSize)intrinsicContentSize { return NSMakeSize(48, 24); }
- (void)sizeToFit { [self setFrameSize:[self intrinsicContentSize]]; }

#pragma mark Activation

- (BOOL)isActive { return _cw.active; }

- (void)activate:(BOOL)exclusive
{
    if (exclusive) {
        for (NSColorWell *w in [[active_wells copy] autorelease])
            if (w != self)
                [w deactivate];
    }
    if (_cw.active)
        return;
    _cw.active = YES;
    if (!active_wells)
        active_wells = (NSMutableArray *)CFBridgingRelease(CFArrayCreateMutable(NULL, 0, NULL));
    if (active_wells)
        [active_wells retain];
    [active_wells addObject:self];
    Class panelClass = FINCH_CLASS(NSColorPanel);
    if (panelClass && [panelClass respondsToSelector:@selector(sharedColorPanel)]) {
        id panel = [panelClass sharedColorPanel];
        if ([panel respondsToSelector:@selector(setColor:)])
            [panel setColor:_color];
        if ([panel respondsToSelector:@selector(orderFront:)])
            [panel orderFront:self];
    }
    [self setNeedsDisplay:YES];
}

- (void)deactivate
{
    if (!_cw.active)
        return;
    _cw.active = NO;
    [active_wells removeObjectIdenticalTo:self];
    [self setNeedsDisplay:YES];
}

/* The colour panel's colour changed. */
- (void)changeColor:(id)sender
{
    if (!_cw.active)
        return;
    [self takeColorFrom:sender];
    [self sendAction:[self action] to:[self target]];
}

- (void)mouseDown:(NSEvent *)event
{
    if (![self isEnabled])
        return;
    NSEvent *e;
    while ((e = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged]))
        if ([e type] == NSEventTypeLeftMouseUp)
            break;
    NSPoint p = [self convertPoint:[e ?: event locationInWindow] fromView:nil];
    if (!NSMouseInRect(p, [self bounds], [self isFlipped]))
        return;
    if (_cw.active)
        [self deactivate];
    else
        [self activate:YES];
}

#pragma mark Drawing

- (void)drawWellInside:(NSRect)rect
{
    NSColor *c = _color ?: [NSColor whiteColor];
    if ([c alphaComponent] < 1) {
        /* a checkerboard under translucent colours */
        [[NSColor whiteColor] setFill];
        NSRectFill(rect);
        [[NSColor colorWithWhite:0.8 alpha:1] setFill];
        for (CGFloat y = NSMinY(rect); y < NSMaxY(rect); y += 4)
            for (CGFloat x = NSMinX(rect) + ((int)((y - NSMinY(rect)) / 4) % 2) * 4; x < NSMaxX(rect); x += 8)
                NSRectFill(NSIntersectionRect(rect, NSMakeRect(x, y, 4, 4)));
    }
    [c setFill];
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    BOOL enabled = [self isEnabled];
    if (_cw.bordered) {
        NSColor *fill = _cw.active ? [FinchAccentColor() colorWithAlphaComponent:0.25] : FinchControlFill(NO);
        FinchDrawBezel(NSInsetRect(b, 1, 1), 5, FinchDisabled(fill, enabled), FinchDisabled(FinchControlStroke(), enabled));
        NSRect inner = NSInsetRect(b, 5, 5);
        NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:inner xRadius:2 yRadius:2];
        [NSGraphicsContext saveGraphicsState];
        [clip addClip];
        [self drawWellInside:inner];
        [NSGraphicsContext restoreGraphicsState];
        [FinchDisabled([NSColor colorWithWhite:0 alpha:0.2], enabled) setStroke];
        [clip setLineWidth:1];
        [clip stroke];
    } else {
        [self drawWellInside:b];
    }
}

@end
