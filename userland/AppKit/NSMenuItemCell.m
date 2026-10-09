/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSMenuItemCell: a button cell that draws one menu item, and the superclass
 * of NSPopUpButtonCell. Finch's menus draw their rows themselves
 * (FinchMenuWindow.m); this cell measures and draws an item the same way,
 * in Finch's look, for apps that use it directly.
 */
#import "NSMenu_Finch.h"
#import "NSControl_Finch.h"

#define STATE_WIDTH 22
#define RIGHT_PAD 14
#define KEY_GAP 24

@implementation NSMenuItemCell {
    NSMenuItem *_menuItem;
    NSInteger _tag;
    struct {
        unsigned needsSizing : 1;
        unsigned needsDisplay : 1;
    } _mi;
    CGFloat _stateWidth, _imageWidth, _titleWidth, _keyWidth;
}

- (instancetype)init
{
    return [self initTextCell:@"MenuItem"];
}

- (instancetype)initTextCell:(NSString *)string
{
    self = [super initTextCell:string];
    if (self) {
        _mi.needsSizing = YES;
        [self setBordered:NO];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        id item = [coder decodeObjectForKey:@"NSMenuItem"];
        if ([item isKindOfClass:[NSMenuItem class]])
            _menuItem = [item retain];
        _mi.needsSizing = YES;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_menuItem)
        [coder encodeObject:_menuItem forKey:@"NSMenuItem"];
    [coder encodeBool:YES forKey:@"NSMenuItemRespectAlignment"];
}

- (void)dealloc
{
    [_menuItem release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSMenuItemCell *c = [super copyWithZone:zone];
    c->_menuItem = [_menuItem retain];
    c->_tag = _tag;
    c->_mi = _mi;
    return c;
}

- (NSMenuItem *)menuItem { return _menuItem; }

- (void)setMenuItem:(NSMenuItem *)item
{
    if (item == _menuItem)
        return;
    [_menuItem release];
    _menuItem = [item retain];
    _mi.needsSizing = YES;
}

- (NSInteger)tag { return _tag; }
- (void)setTag:(NSInteger)tag { _tag = tag; }
- (BOOL)needsSizing { return _mi.needsSizing; }
- (void)setNeedsSizing:(BOOL)flag { _mi.needsSizing = flag; }
- (BOOL)needsDisplay { return _mi.needsDisplay; }

- (void)setNeedsDisplay:(BOOL)flag
{
    _mi.needsDisplay = flag;
    if (flag)
        [[self controlView] setNeedsDisplay:YES];
}

- (NSDictionary *)_finchItemAttributes
{
    NSFont *font = [self font] ?: [NSFont menuFontOfSize:0];
    return @{NSFontAttributeName : font};
}

- (void)calcSize
{
    NSMenuItem *i = _menuItem;
    NSDictionary *a = [self _finchItemAttributes];
    _stateWidth = [[i menu] showsStateColumn] || ![i menu] ? STATE_WIDTH : 0;
    _imageWidth = [i image] ? MIN([[i image] size].width, 16) + 6 : 0;
    _titleWidth = i ? ceil([[i title] sizeWithAttributes:a].width) : 0;
    NSString *key = i ? FinchMenuKeyEquivalentString(i) : @"";
    _keyWidth = [key length] ? ceil([key sizeWithAttributes:a].width) : 0;
    _mi.needsSizing = NO;
}

static void
sized(NSMenuItemCell *self)
{
    if (self->_mi.needsSizing)
        [self calcSize];
}

- (CGFloat)stateImageWidth { sized(self); return _stateWidth; }
- (CGFloat)imageWidth { sized(self); return _imageWidth; }
- (CGFloat)titleWidth { sized(self); return _titleWidth; }
- (CGFloat)keyEquivalentWidth { sized(self); return _keyWidth; }

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    sized(self);
    if ([_menuItem isSeparatorItem])
        return NSMakeSize(_stateWidth + RIGHT_PAD, 11);
    return NSMakeSize(_stateWidth + _imageWidth + _titleWidth + (_keyWidth ? KEY_GAP + _keyWidth : 0) + RIGHT_PAD, 22);
}

- (NSRect)stateImageRectForBounds:(NSRect)frame
{
    sized(self);
    return NSMakeRect(NSMinX(frame), NSMinY(frame), _stateWidth, frame.size.height);
}

- (NSRect)imageRectForBounds:(NSRect)frame
{
    sized(self);
    return NSMakeRect(NSMinX(frame) + _stateWidth, NSMinY(frame), _imageWidth, frame.size.height);
}

- (NSRect)titleRectForBounds:(NSRect)frame
{
    sized(self);
    CGFloat x = NSMinX(frame) + _stateWidth + _imageWidth + [_menuItem indentationLevel] * 10;
    return NSMakeRect(x, NSMinY(frame), MAX(0, NSMaxX(frame) - x - RIGHT_PAD - (_keyWidth ? KEY_GAP + _keyWidth : 0)),
                      frame.size.height);
}

- (NSRect)keyEquivalentRectForBounds:(NSRect)frame
{
    sized(self);
    return NSMakeRect(NSMaxX(frame) - RIGHT_PAD - _keyWidth, NSMinY(frame), _keyWidth, frame.size.height);
}

- (NSColor *)_finchItemColor
{
    BOOL enabled = [_menuItem isEnabled];
    if ([self isHighlighted] && enabled)
        return [NSColor whiteColor];
    return enabled ? FinchControlTextColor()
                   : [NSColor colorWithSRGBRed:0.62 green:0.62 blue:0.62 alpha:1];
}

- (void)drawSeparatorItemWithFrame:(NSRect)frame inView:(NSView *)view
{
    [[NSColor colorWithSRGBRed:0.84 green:0.84 blue:0.84 alpha:1] setFill];
    NSRectFill(NSMakeRect(NSMinX(frame) + 10, floor(NSMidY(frame)), frame.size.width - 20, 1));
}

- (void)drawBorderAndBackgroundWithFrame:(NSRect)frame inView:(NSView *)view
{
    if ([self isHighlighted] && [_menuItem isEnabled]) {
        [FinchAccentColor() setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame, 5, 0) xRadius:4 yRadius:4] fill];
    }
}

- (void)drawStateImageWithFrame:(NSRect)frame inView:(NSView *)view
{
    NSControlStateValue s = [_menuItem state];
    NSImage *mark = s == NSControlStateValueOn ? [_menuItem onStateImage]
                    : s == NSControlStateValueMixed ? [_menuItem mixedStateImage]
                                                    : [_menuItem offStateImage];
    if (mark)
        FinchDrawImageInRect(mark, [self stateImageRectForBounds:frame], NSImageScaleProportionallyDown,
                             NSImageAlignCenter, [view isFlipped], 1);
}

- (void)drawImageWithFrame:(NSRect)frame inView:(NSView *)view
{
    if ([_menuItem image])
        FinchDrawImageInRect([_menuItem image], [self imageRectForBounds:frame], NSImageScaleProportionallyDown,
                             NSImageAlignCenter, [view isFlipped], [_menuItem isEnabled] ? 1 : 0.5);
}

- (void)drawTitleWithFrame:(NSRect)frame inView:(NSView *)view
{
    NSMutableDictionary *a = [[[self _finchItemAttributes] mutableCopy] autorelease];
    a[NSForegroundColorAttributeName] = [self _finchItemColor];
    NSAttributedString *t = [[[NSAttributedString alloc] initWithString:[_menuItem title] ?: @"" attributes:a]
        autorelease];
    FinchDrawCellText(t, [self titleRectForBounds:frame], [view isFlipped]);
}

- (void)drawKeyEquivalentWithFrame:(NSRect)frame inView:(NSView *)view
{
    NSString *key = _menuItem ? FinchMenuKeyEquivalentString(_menuItem) : @"";
    if (![key length])
        return;
    NSMutableDictionary *a = [[[self _finchItemAttributes] mutableCopy] autorelease];
    a[NSForegroundColorAttributeName] = [self _finchItemColor];
    NSAttributedString *t = [[[NSAttributedString alloc] initWithString:key attributes:a] autorelease];
    FinchDrawCellText(t, [self keyEquivalentRectForBounds:frame], [view isFlipped]);
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    if ([_menuItem isSeparatorItem]) {
        [self drawSeparatorItemWithFrame:frame inView:view];
        return;
    }
    [self drawBorderAndBackgroundWithFrame:frame inView:view];
    [self drawInteriorWithFrame:frame inView:view];
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view
{
    [self drawStateImageWithFrame:frame inView:view];
    [self drawImageWithFrame:frame inView:view];
    [self drawTitleWithFrame:frame inView:view];
    [self drawKeyEquivalentWithFrame:frame inView:view];
}

@end
