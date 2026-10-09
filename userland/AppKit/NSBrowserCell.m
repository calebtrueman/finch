/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSControl_Finch.h"
@implementation NSBrowserCell {
    BOOL _leaf, _loaded;
    NSImage *_alternateImage;
}
- (instancetype)init
{
    return [self initTextCell:@""];
}
- (instancetype)initTextCell:(NSString *)text
{
    if ((self = [super initTextCell:text])) {
        _loaded = YES;
        self.font = [NSFont systemFontOfSize:13];
    }
    return self;
}
- (instancetype)initImageCell:(NSImage *)image
{
    if ((self = [super initImageCell:image])) {
        _loaded = YES;
        self.font = [NSFont systemFontOfSize:13];
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _loaded = YES;
        _leaf = [coder decodeBoolForKey:@"NSIsLeaf"];
        _alternateImage = [[coder decodeObjectForKey:@"NSAlternateImage"] retain];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeBool:_leaf forKey:@"NSIsLeaf"];
    [coder encodeObject:_alternateImage forKey:@"NSAlternateImage"];
}
- (void)dealloc
{
    [_alternateImage release];
    [super dealloc];
}
- (id)copyWithZone:(NSZone *)zone
{
    NSBrowserCell *cell = [super copyWithZone:zone];
    [cell->_alternateImage retain];
    return cell;
}
+ (NSImage *)branchImage
{
    static NSImage *image;
    if (!image)
        image = [[NSImage imageWithSize:NSMakeSize(9, 11)
                                flipped:NO
                         drawingHandler:^BOOL(NSRect rect) {
                           NSBezierPath *arrow = [NSBezierPath bezierPath];
                           [arrow moveToPoint:NSMakePoint(2, 2)];
                           [arrow lineToPoint:NSMakePoint(6, 5.5)];
                           [arrow lineToPoint:NSMakePoint(2, 9)];
                           [[NSColor secondaryLabelColor] setStroke];
                           arrow.lineWidth = 1.5;
                           [arrow stroke];
                           return YES;
                         }] retain];
    return image;
}
+ (NSImage *)highlightedBranchImage
{
    return self.branchImage;
}
- (BOOL)isLeaf
{
    return _leaf;
}
- (void)setLeaf:(BOOL)leaf
{
    _leaf = leaf;
    [self _finchChanged];
}
- (BOOL)isLoaded
{
    return _loaded;
}
- (void)setLoaded:(BOOL)loaded
{
    _loaded = loaded;
}
- (void)reset
{
    self.state = NSControlStateValueOff;
    self.highlighted = NO;
}
- (void)set
{
    self.state = NSControlStateValueOn;
}
- (NSImage *)alternateImage
{
    return _alternateImage;
}
- (void)setAlternateImage:(NSImage *)image
{
    if (_alternateImage != image) {
        [_alternateImage release];
        _alternateImage = [image retain];
        [self _finchChanged];
    }
}
- (NSSize)cellSizeForBounds:(NSRect)bounds
{
    NSSize size = [super cellSizeForBounds:bounds];
    size.height = MAX(size.height, ceil((self.font ?: [NSFont systemFontOfSize:13]).pointSize * 1.2));
    return size;
}
- (NSColor *)highlightColorInView:(NSView *)view
{
    return [NSColor selectedControlColor];
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    BOOL selected = self.state != NSControlStateValueOff || self.highlighted;
    if (selected) {
        [[self highlightColorInView:view] setFill];
        NSRectFill(frame);
    }
    [self drawInteriorWithFrame:frame inView:view];
}
- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view
{
    BOOL selected = self.state != NSControlStateValueOff || self.highlighted;
    NSRect text = NSInsetRect(frame, 4, 0);
    if (!_leaf)
        text.size.width = MAX(0, text.size.width - 12);
    NSImage *image = selected && _alternateImage ? _alternateImage : self.image;
    if (image) {
        CGFloat side = MIN(16, MAX(0, frame.size.height - 2));
        [image drawInRect:NSMakeRect(text.origin.x, NSMidY(frame) - side / 2, side, side)
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:self.enabled ? 1 : 0.4
            respectFlipped:view.isFlipped
                     hints:nil];
        text.origin.x += side + 4;
        text.size.width = MAX(0, text.size.width - side - 4);
    }
    NSColor *color = selected ? [NSColor selectedControlTextColor] : [NSColor controlTextColor];
    NSAttributedString *string =
        [[[NSAttributedString alloc] initWithString:self.stringValue ?: @""
                                         attributes:@{
                                             NSFontAttributeName : self.font ?: [NSFont systemFontOfSize:13],
                                             NSForegroundColorAttributeName : FinchDisabled(color, self.enabled)
                                         }] autorelease];
    FinchDrawCellText(string, text, view.isFlipped);
    if (!_leaf) {
        NSBezierPath *arrow = [NSBezierPath bezierPath];
        CGFloat x = NSMaxX(frame) - 8, y = NSMidY(frame);
        [arrow moveToPoint:NSMakePoint(x - 2, y - 3)];
        [arrow lineToPoint:NSMakePoint(x + 1, y)];
        [arrow lineToPoint:NSMakePoint(x - 2, y + 3)];
        [color setStroke];
        arrow.lineWidth = 1.2;
        [arrow stroke];
    }
}
@end
