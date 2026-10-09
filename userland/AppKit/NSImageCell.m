/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSImageCell: shows an image, scaled and aligned, in an optional frame.
 * As Apple's, its type stays NSNullCellType and its value is the image.
 * Nib keys: NSContents (the image), NSAlign, NSScale, NSStyle, NSAnimates.
 * Frames are drawn in Finch's own flat look.
 */
#import "NSControl_Finch.h"

@implementation NSImageCell {
    NSImage *_image;
    NSImageAlignment _alignment;
    NSImageScaling _scaling;
    NSImageFrameStyle _frameStyle;
    BOOL _animates;
}

- (instancetype)init
{
    return [self initImageCell:nil];
}

- (instancetype)initImageCell:(NSImage *)image
{
    self = [super initImageCell:nil];
    if (!self)
        return nil;
    _image = [image retain];
    [self setRefusesFirstResponder:YES];
    return self;
}

- (instancetype)initTextCell:(NSString *)string
{
    return [self initImageCell:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    id image = [coder decodeObjectForKey:@"NSContents"];
    _image = [image isKindOfClass:[NSImage class]] ? [image retain] : nil;
    _alignment = (NSImageAlignment)[coder decodeIntegerForKey:@"NSAlign"];
    _scaling = (NSImageScaling)[coder decodeIntegerForKey:@"NSScale"];
    _frameStyle = (NSImageFrameStyle)[coder decodeIntegerForKey:@"NSStyle"];
    _animates = [coder decodeBoolForKey:@"NSAnimates"];
    [super setType:NSNullCellType];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_image)
        [coder encodeObject:_image forKey:@"NSContents"];
    [coder encodeInteger:_alignment forKey:@"NSAlign"];
    [coder encodeInteger:_scaling forKey:@"NSScale"];
    [coder encodeInteger:_frameStyle forKey:@"NSStyle"];
    [coder encodeBool:_animates forKey:@"NSAnimates"];
}

- (void)dealloc
{
    [_image release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSImageCell *c = [super copyWithZone:zone];
    [c->_image retain];
    return c;
}

- (BOOL)_finchAnimates { return _animates; }
- (void)_finchSetAnimates:(BOOL)flag { _animates = flag; }
- (NSCellType)type { return NSNullCellType; }
- (void)setType:(NSCellType)type {}
- (NSImage *)image { return _image; }

- (void)setImage:(NSImage *)image
{
    if (image == _image)
        return;
    [_image release];
    _image = [image retain];
    [self _finchChanged];
}

- (id)objectValue { return _image; }

- (void)setObjectValue:(id)value
{
    [self setImage:[value isKindOfClass:[NSImage class]] ? value : nil];
}

- (NSString *)stringValue { return _image ? [_image description] : @""; }
- (void)setStringValue:(NSString *)string {}
- (NSImageAlignment)imageAlignment { return _alignment; }
- (void)setImageAlignment:(NSImageAlignment)a { _alignment = a; [self _finchChanged]; }
- (NSImageScaling)imageScaling { return _scaling; }
- (void)setImageScaling:(NSImageScaling)s { _scaling = s; [self _finchChanged]; }
- (NSImageFrameStyle)imageFrameStyle { return _frameStyle; }
- (void)setImageFrameStyle:(NSImageFrameStyle)s { _frameStyle = s; [self _finchChanged]; }

- (CGFloat)_finchFrameInset
{
    switch (_frameStyle) {
    case NSImageFramePhoto: return 4;
    case NSImageFrameGrayBezel: return 3;
    case NSImageFrameGroove: return 3;
    default: return 0;
    }
}

- (NSRect)drawingRectForBounds:(NSRect)rect
{
    CGFloat i = [self _finchFrameInset];
    return NSInsetRect(rect, i, i);
}

- (NSRect)imageRectForBounds:(NSRect)rect { return [self drawingRectForBounds:rect]; }

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    if (!_image)
        return NSZeroSize;
    CGFloat i = 2 * [self _finchFrameInset];
    NSSize s = [_image size];
    return NSMakeSize(s.width + i, s.height + i);
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    switch (_frameStyle) {
    case NSImageFramePhoto:
        FinchDrawBezel(NSInsetRect(frame, 1, 1), 1, [NSColor whiteColor], FinchControlStroke());
        [[NSColor colorWithWhite:0 alpha:0.15] setFill];
        NSRectFill(NSMakeRect(NSMinX(frame) + 2, [controlView isFlipped] ? NSMaxY(frame) - 1 : NSMinY(frame),
                              frame.size.width - 2, 1));
        break;
    case NSImageFrameGrayBezel:
        FinchDrawBezel(frame, 4, [NSColor colorWithSRGBRed:0.95 green:0.95 blue:0.96 alpha:1], FinchControlStroke());
        break;
    case NSImageFrameGroove:
        FinchDrawBezel(frame, 3, nil, FinchControlStroke());
        FinchDrawBezel(NSInsetRect(frame, 1, 1), 2, nil, [NSColor colorWithWhite:1 alpha:0.8]);
        break;
    default:
        break;
    }
    [self drawInteriorWithFrame:frame inView:controlView];
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    FinchDrawImageInRect(_image, [self drawingRectForBounds:frame], _scaling, _alignment, [controlView isFlipped],
                         [self isEnabled] ? 1 : 0.5);
}

@end
