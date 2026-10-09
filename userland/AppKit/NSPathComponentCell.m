/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSPathControl_Finch.h"

@implementation NSPathComponentCell {
    NSURL *_URL;
    NSImage *_pathImage;
}
- (instancetype)initTextCell:(NSString *)s
{
    if ((self = [super initTextCell:s])) { [self setLineBreakMode:NSLineBreakByClipping]; [self setAlignment:NSTextAlignmentNatural]; }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _URL = [[coder decodeObjectForKey:@"NSURL"] copy]; _pathImage = [[coder decodeObjectForKey:@"NSImage"] retain];
        if (!_pathImage && [_URL isFileURL]) _pathImage = [[[NSWorkspace sharedWorkspace] iconForFile:[_URL path]] retain];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder { [super encodeWithCoder:coder]; [coder encodeObject:_URL forKey:@"NSURL"]; [coder encodeObject:_pathImage forKey:@"NSImage"]; }
- (void)dealloc { [_URL release]; [_pathImage release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone { NSPathComponentCell *c = [super copyWithZone:zone]; [c->_URL retain]; [c->_pathImage retain]; return c; }
- (NSURL *)URL { return _URL; }
- (void)setURL:(NSURL *)URL { NSURL *copy = [URL copy]; [_URL release]; _URL = copy; [self _finchChanged]; }
- (NSImage *)image { return _pathImage; }
- (void)setImage:(NSImage *)image { [image retain]; [_pathImage release]; _pathImage = image; [self _finchChanged]; }
- (NSSize)cellSizeForBounds:(NSRect)r
{
    NSSize size = [[self attributedStringValue] size];
    return NSMakeSize(ceil(size.width) + (_pathImage ? 24 : 8), [self controlSize] == NSControlSizeMini ? 15 : 19);
}
- (void)drawWithFrame:(NSRect)r inView:(NSView *)view
{
    if (NSIsEmptyRect(r)) return;
    [NSGraphicsContext saveGraphicsState]; NSRectClip(r);
    if ([self isHighlighted]) FinchDrawBezel(r, 3, [FinchAccentColor() colorWithAlphaComponent:0.18], nil);
    NSRect text = NSInsetRect(r, 4, 0);
    if (_pathImage) {
        NSRect icon = NSMakeRect(text.origin.x, NSMidY(r) - 8, 16, 16);
        FinchDrawImageInRect(_pathImage, icon, NSImageScaleProportionallyDown, NSImageAlignCenter, [view isFlipped], [self isEnabled] ? 1 : 0.45);
        text.origin.x += 20; text.size.width = MAX(0, text.size.width - 20);
    }
    FinchDrawCellText([self attributedStringValue], text, [view isFlipped]);
    [NSGraphicsContext restoreGraphicsState];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilitySubrole { return nil; }
@end
