/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A primary button and a menu can share one body or use two click areas. */
#import "NSControl_Finch.h"

@implementation NSComboButton {
    NSString *_title;
    NSImage *_image;
    NSMenu *_menu;
    NSImageScaling _imageScaling;
    NSComboButtonStyle _style;
    NSControlSize _size;
    BOOL _pressed;
}
- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _title = [@"" copy]; _menu = [[NSMenu alloc] initWithTitle:@""];
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _title = [[coder decodeObjectForKey:@"NSTitle"] copy] ?: [@"" copy];
        _image = [[coder decodeObjectForKey:@"NSImage"] retain];
        _menu = [[coder decodeObjectForKey:@"NSMenu"] retain] ?: [[NSMenu alloc] initWithTitle:@""];
        _style = [coder decodeIntegerForKey:@"NSComboButtonStyle"];
        _imageScaling = [coder decodeIntegerForKey:@"NSImageScaling"];
        _size = [coder decodeIntegerForKey:@"NSControlSize"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_title forKey:@"NSTitle"]; [coder encodeObject:_image forKey:@"NSImage"];
    [coder encodeObject:_menu forKey:@"NSMenu"]; [coder encodeInteger:_style forKey:@"NSComboButtonStyle"];
    [coder encodeInteger:_imageScaling forKey:@"NSImageScaling"]; [coder encodeInteger:_size forKey:@"NSControlSize"];
}
- (void)dealloc { [_title release]; [_image release]; [_menu release]; [super dealloc]; }
+ (instancetype)comboButtonWithTitle:(NSString *)title menu:(NSMenu *)menu target:(id)target action:(SEL)action
{
    NSComboButton *button = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [button setTitle:title]; [button setMenu:menu]; [button setTarget:target]; [button setAction:action];
    [button sizeToFit]; return button;
}
+ (instancetype)comboButtonWithImage:(NSImage *)image menu:(NSMenu *)menu target:(id)target action:(SEL)action
{
    return [self comboButtonWithTitle:@"" image:image menu:menu target:target action:action];
}
+ (instancetype)comboButtonWithTitle:(NSString *)title image:(NSImage *)image menu:(NSMenu *)menu target:(id)target action:(SEL)action
{
    NSComboButton *button = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [button setTitle:title]; [button setImage:image]; [button setMenu:menu];
    [button setTarget:target]; [button setAction:action]; [button sizeToFit]; return button;
}
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)s { NSString *copy = [s copy] ?: [@"" copy]; [_title release]; _title = copy; [self invalidateIntrinsicContentSize]; [self setNeedsDisplay:YES]; }
- (NSImage *)image { return _image; }
- (void)setImage:(NSImage *)image { [image retain]; [_image release]; _image = image; [self invalidateIntrinsicContentSize]; [self setNeedsDisplay:YES]; }
- (NSMenu *)menu { return _menu; }
- (void)setMenu:(NSMenu *)menu { [menu retain]; [_menu release]; _menu = menu; [self setNeedsDisplay:YES]; }
- (NSImageScaling)imageScaling { return _imageScaling; }
- (void)setImageScaling:(NSImageScaling)scaling { _imageScaling = scaling; [self setNeedsDisplay:YES]; }
- (NSComboButtonStyle)style { return _style; }
- (void)setStyle:(NSComboButtonStyle)style { _style = style; [self setNeedsDisplay:YES]; }
- (NSControlSize)controlSize { return _size; }
- (void)setControlSize:(NSControlSize)size { _size = size; [self invalidateIntrinsicContentSize]; [self setNeedsDisplay:YES]; }
- (NSFont *)font { return [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:_size]]; }
- (NSSize)intrinsicContentSize
{
    CGFloat h = _size == NSControlSizeSmall ? 20 : _size == NSControlSizeMini ? 16 : _size == NSControlSizeLarge ? 28 : 24;
    CGFloat content = ceil([_title sizeWithAttributes:@{NSFontAttributeName: [self font]}].width);
    if (_image) content += MIN(h - 4, [_image size].width) + ([_title length] ? 4 : 0);
    return NSMakeSize(MAX(42, content + 38), h);
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return [self isEnabled]; }
- (void)_finchShowMenu
{
    if ([_menu numberOfItems]) [_menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY([self bounds])) inView:self];
}
- (void)performClick:(id)sender
{
    if (![self isEnabled]) return;
    if ([self action]) [self sendAction:[self action] to:[self target]];
    else if (_style == NSComboButtonStyleUnified) [self _finchShowMenu];
}
- (void)mouseDown:(NSEvent *)event
{
    if (![self isEnabled]) return;
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    if ((_style == NSComboButtonStyleSplit && point.x >= NSMaxX([self bounds]) - 20) ||
        (_style == NSComboButtonStyleUnified && ![self action])) { [self _finchShowMenu]; return; }
    if (![self action]) return;
    _pressed = YES; [self setNeedsDisplay:YES]; [[self window] displayIfNeeded];
    BOOL inside = YES, showMenu = NO;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.5];
    for (;;) {
        NSEvent *next = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged
                                          untilDate:_style == NSComboButtonStyleUnified ? until : [NSDate distantFuture]
                                             inMode:NSEventTrackingRunLoopMode dequeue:YES];
        if (!next) { showMenu = inside && _style == NSComboButtonStyleUnified; break; }
        point = [self convertPoint:[next locationInWindow] fromView:nil];
        inside = NSMouseInRect(point, [self bounds], YES); _pressed = inside; [self setNeedsDisplay:YES];
        if ([next type] == NSEventTypeLeftMouseUp) break;
    }
    _pressed = NO; [self setNeedsDisplay:YES];
    if (showMenu) [self _finchShowMenu]; else if (inside) [self performClick:self];
}
- (void)keyDown:(NSEvent *)event
{
    NSString *s = [event charactersIgnoringModifiers];
    if ([s isEqual:@" "] || [s isEqual:@"\r"]) [self performClick:self];
    else if ([s length] && [s characterAtIndex:0] == NSDownArrowFunctionKey) [self _finchShowMenu];
    else [super keyDown:event];
}
- (void)drawRect:(NSRect)dirty
{
    NSRect r = [self bounds];
    FinchDrawBezel(r, 5, FinchControlFill(_pressed), FinchControlStroke());
    CGFloat split = NSMaxX(r) - 20;
    if (_style == NSComboButtonStyleSplit) {
        [FinchControlStroke() setStroke]; NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(split, r.origin.y + 3)]; [line lineToPoint:NSMakePoint(split, NSMaxY(r) - 3)]; [line stroke];
    }
    NSRect content = NSMakeRect(r.origin.x + 6, r.origin.y + 2, MAX(0, split - r.origin.x - 12), MAX(0, r.size.height - 4));
    if (_image) {
        CGFloat width = MIN(content.size.height, [_image size].width);
        FinchDrawImageInRect(_image, NSMakeRect(content.origin.x, content.origin.y, width, content.size.height), _imageScaling, NSImageAlignCenter, YES, [self isEnabled] ? 1 : 0.45);
        content.origin.x += width + 4; content.size.width = MAX(0, content.size.width - width - 4);
    }
    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease]; [ps setAlignment:NSTextAlignmentCenter];
    NSAttributedString *text = [[[NSAttributedString alloc] initWithString:_title attributes:@{NSFontAttributeName:[self font], NSForegroundColorAttributeName:FinchDisabled([NSColor controlTextColor], [self isEnabled] && [self action] != NULL), NSParagraphStyleAttributeName:ps}] autorelease];
    FinchDrawCellText(text, content, YES);
    [FinchDisabled([NSColor controlTextColor], [self isEnabled] && [_menu numberOfItems] > 0) setStroke];
    NSBezierPath *arrow = [NSBezierPath bezierPath]; [arrow setLineWidth:1.3];
    [arrow moveToPoint:NSMakePoint(split + 6, NSMidY(r) - 2)]; [arrow lineToPoint:NSMakePoint(split + 10, NSMidY(r) + 2)];
    [arrow lineToPoint:NSMakePoint(split + 14, NSMidY(r) - 2)]; [arrow stroke];
}
- (BOOL)isAccessibilityElement { return NO; }
- (NSString *)accessibilityRole { return NSAccessibilityUnknownRole; }
- (NSString *)accessibilitySubrole { return nil; }
- (BOOL)accessibilityPerformPress { if (![self isEnabled]) return NO; [self performClick:self]; return YES; }
@end
