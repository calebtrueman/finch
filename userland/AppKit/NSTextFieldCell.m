/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextFieldCell: a text cell with text and background colours, a bezel
 * (square or rounded), a placeholder, and the field editor set up for it.
 * Nib keys: NSTextColor, NSBackgroundColor, NSDrawsBackground,
 * NSPlaceholderString, NSTextBezelStyle, NSAllowedInputLocales.
 */
#import "NSControl_Finch.h"

@implementation NSTextFieldCell {
    NSColor *_textColor, *_backgroundColor;
    id _placeholder; /* NSString or NSAttributedString */
    NSArray *_inputLocales;
    NSTextFieldBezelStyle _bezelStyle;
    struct {
        unsigned drawsBackground : 1;
        unsigned markedTextNotifications : 1;
    } _t;
}

- (instancetype)init
{
    return [self initTextCell:@"Field"];
}

- (instancetype)initTextCell:(NSString *)string
{
    self = [super initTextCell:string];
    if (!self)
        return nil;
    _textColor = [[NSColor controlTextColor] retain];
    _backgroundColor = [[NSColor textBackgroundColor] retain];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _textColor = [[coder decodeObjectForKey:@"NSTextColor"] retain] ?: [[NSColor controlTextColor] retain];
    _backgroundColor = [[coder decodeObjectForKey:@"NSBackgroundColor"] retain] ?: [[NSColor textBackgroundColor] retain];
    _t.drawsBackground = [coder decodeBoolForKey:@"NSDrawsBackground"];
    id p = [coder decodeObjectForKey:@"NSPlaceholderString"];
    if ([p isKindOfClass:[NSString class]] || [p isKindOfClass:[NSAttributedString class]])
        _placeholder = [p copy];
    _bezelStyle = (NSTextFieldBezelStyle)[coder decodeIntegerForKey:@"NSTextBezelStyle"];
    _inputLocales = [[coder decodeObjectForKey:@"NSAllowedInputLocales"] copy];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_textColor)
        [coder encodeObject:_textColor forKey:@"NSTextColor"];
    if (_backgroundColor)
        [coder encodeObject:_backgroundColor forKey:@"NSBackgroundColor"];
    if (_t.drawsBackground)
        [coder encodeBool:YES forKey:@"NSDrawsBackground"];
    if (_placeholder)
        [coder encodeObject:_placeholder forKey:@"NSPlaceholderString"];
    if (_bezelStyle)
        [coder encodeInteger:_bezelStyle forKey:@"NSTextBezelStyle"];
    if (_inputLocales)
        [coder encodeObject:_inputLocales forKey:@"NSAllowedInputLocales"];
}

- (void)dealloc
{
    [_textColor release];
    [_backgroundColor release];
    [_placeholder release];
    [_inputLocales release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSTextFieldCell *c = [super copyWithZone:zone];
    [c->_textColor retain];
    [c->_backgroundColor retain];
    [c->_placeholder retain];
    [c->_inputLocales retain];
    return c;
}

#pragma mark Properties

- (NSColor *)textColor { return _textColor; }

- (void)setTextColor:(NSColor *)color
{
    [_textColor release];
    _textColor = [color copy];
    [self _finchChanged];
}

- (NSColor *)backgroundColor { return _backgroundColor; }

- (void)setBackgroundColor:(NSColor *)color
{
    [_backgroundColor release];
    _backgroundColor = [color copy];
    [self _finchChanged];
}

/* As Apple's: a rounded bezel draws its own background. */
- (BOOL)drawsBackground
{
    return _t.drawsBackground && !([self isBezeled] && _bezelStyle == NSTextFieldRoundedBezel);
}

- (void)setDrawsBackground:(BOOL)flag
{
    _t.drawsBackground = flag;
    [self _finchChanged];
}

- (NSTextFieldBezelStyle)bezelStyle { return _bezelStyle; }

- (void)setBezelStyle:(NSTextFieldBezelStyle)style
{
    _bezelStyle = style;
    [self _finchChanged];
}

- (NSString *)placeholderString
{
    return [_placeholder isKindOfClass:[NSString class]] ? _placeholder : nil;
}

- (void)setPlaceholderString:(NSString *)s
{
    [_placeholder release];
    _placeholder = [s copy];
    [self _finchChanged];
}

- (NSAttributedString *)placeholderAttributedString
{
    return [_placeholder isKindOfClass:[NSAttributedString class]] ? _placeholder : nil;
}

- (void)setPlaceholderAttributedString:(NSAttributedString *)s
{
    [_placeholder release];
    _placeholder = [s copy];
    [self _finchChanged];
}

- (NSArray<NSString *> *)allowedInputSourceLocales { return _inputLocales; }

- (void)setAllowedInputSourceLocales:(NSArray<NSString *> *)locales
{
    [_inputLocales release];
    _inputLocales = [locales copy];
}

- (void)setWantsNotificationForMarkedText:(BOOL)flag { _t.markedTextNotifications = flag; }
- (BOOL)wantsNotificationForMarkedText { return _t.markedTextNotifications; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return [self isEnabled] && [self isEditable] && ![self refusesFirstResponder]; }

- (NSDictionary *)_finchTextAttributes
{
    NSMutableDictionary *a = [[[super _finchTextAttributes] mutableCopy] autorelease];
    NSColor *c = _textColor ?: [NSColor controlTextColor];
    a[NSForegroundColorAttributeName] = [self isEnabled] ? c : [NSColor disabledControlTextColor];
    return a;
}

- (NSText *)setUpFieldEditorAttributes:(NSText *)text
{
    [super setUpFieldEditorAttributes:text];
    [text setTextColor:_textColor ?: [NSColor controlTextColor]];
    return text;
}

#pragma mark Geometry and drawing

- (CGFloat)_finchFrameInset
{
    return [self isBezeled] ? 4 : [self isBordered] ? 3 : 0;
}

- (NSRect)drawingRectForBounds:(NSRect)rect
{
    CGFloat i = [self _finchFrameInset];
    CGFloat h = [self _finchBezelHeightInset];
    return NSInsetRect(rect, i + h, i > 0 ? MIN(i, 2) : 0);
}

/* A rounded bezel keeps its text clear of the ends. */
- (CGFloat)_finchBezelHeightInset
{
    return [self isBezeled] && _bezelStyle == NSTextFieldRoundedBezel ? 4 : 0;
}

- (NSRect)titleRectForBounds:(NSRect)rect
{
    return [self drawingRectForBounds:rect];
}

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    CGFloat i = 2 * [self _finchFrameInset];
    CGFloat width = [self wraps] && rect.size.width > 0 && rect.size.width < 1e6 ? rect.size.width - 4 - i : 0;
    NSAttributedString *s = [self attributedStringValue];
    NSSize ts = FinchCellTextSize(s, width);
    if (![s length] && [_placeholder length] && [self isEditable])
        ts.width = FinchCellTextSize([self _finchPlaceholder], 0).width;
    return NSMakeSize(ts.width + 4 + i + 2 * [self _finchBezelHeightInset], ts.height + i);
}

- (NSAttributedString *)_finchPlaceholder
{
    if ([_placeholder isKindOfClass:[NSAttributedString class]])
        return _placeholder;
    NSMutableDictionary *a = [[[self _finchTextAttributes] mutableCopy] autorelease];
    a[NSForegroundColorAttributeName] = [NSColor placeholderTextColor];
    return [[[NSAttributedString alloc] initWithString:_placeholder ?: @"" attributes:a] autorelease];
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    if ([self _finchIsEditing])
        return;
    NSAttributedString *s = [self attributedStringValue];
    if (![s length] && [_placeholder length])
        s = [self _finchPlaceholder];
    FinchDrawCellText(s, NSInsetRect([self titleRectForBounds:frame], 2, 0), [controlView isFlipped]);
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    BOOL enabled = [self isEnabled];
    NSColor *bg = _backgroundColor ?: [NSColor textBackgroundColor];
    if ([self isBezeled]) {
        BOOL rounded = _bezelStyle == NSTextFieldRoundedBezel;
        NSColor *fill = rounded || _t.drawsBackground ? bg : nil;
        FinchDrawBezel(frame, rounded ? frame.size.height / 2 : 3, fill, FinchDisabled(FinchControlStroke(), enabled));
    } else if ([self isBordered]) {
        if (_t.drawsBackground) {
            [bg setFill];
            NSRectFill(frame);
        }
        FinchDrawBezel(frame, 0, nil, FinchDisabled([NSColor colorWithWhite:0.45 alpha:1], enabled));
    } else if (_t.drawsBackground) {
        [bg setFill];
        NSRectFill(frame);
    }
    [self drawInteriorWithFrame:frame inView:controlView];
    if ([self _finchIsEditing] && [self focusRingType] != NSFocusRingTypeNone && ([self isBezeled] || [self isBordered])) {
        CGFloat r = [self isBezeled] && _bezelStyle == NSTextFieldRoundedBezel ? frame.size.height / 2 : 3;
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame, 1, 1) xRadius:r yRadius:r];
        [p setLineWidth:2];
        [[FinchAccentColor() colorWithAlphaComponent:0.7] setStroke];
        [p stroke];
    }
}

@end
