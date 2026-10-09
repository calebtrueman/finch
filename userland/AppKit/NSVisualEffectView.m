/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Material state and a solid fallback until Finch can blur window contents. */
#import "AppKit_Finch.h"
@implementation NSVisualEffectView {
    NSVisualEffectMaterial _material;
    NSVisualEffectBlendingMode _blend;
    NSVisualEffectState _state;
    NSImage *_mask;
    BOOL _emphasized;
}
- (void)dealloc
{
    [_mask release];
    [super dealloc];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _material = [coder decodeIntegerForKey:@"NSMaterial"];
        _blend = [coder decodeIntegerForKey:@"NSBlendingMode"];
        _state = [coder decodeIntegerForKey:@"NSState"];
        _mask = [[coder decodeObjectForKey:@"NSMaskImage"] retain];
        _emphasized = [coder decodeBoolForKey:@"NSEmphasized"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeInteger:_material forKey:@"NSMaterial"];
    [coder encodeInteger:_blend forKey:@"NSBlendingMode"];
    [coder encodeInteger:_state forKey:@"NSState"];
    [coder encodeObject:_mask forKey:@"NSMaskImage"];
    [coder encodeBool:_emphasized forKey:@"NSEmphasized"];
}
- (NSVisualEffectMaterial)material
{
    return _material;
}
- (void)setMaterial:(NSVisualEffectMaterial)v
{
    _material = v;
    [self setNeedsDisplay:YES];
}
- (NSVisualEffectBlendingMode)blendingMode
{
    return _blend;
}
- (void)setBlendingMode:(NSVisualEffectBlendingMode)v
{
    _blend = v;
    [self setNeedsDisplay:YES];
}
- (NSVisualEffectState)state
{
    return _state;
}
- (void)setState:(NSVisualEffectState)v
{
    _state = v;
    [self setNeedsDisplay:YES];
}
- (NSImage *)maskImage
{
    return _mask;
}
- (void)setMaskImage:(NSImage *)v
{
    if (v != _mask) {
        [_mask release];
        _mask = [v retain];
        [self setNeedsDisplay:YES];
    }
}
- (BOOL)isEmphasized
{
    return _emphasized;
}
- (void)setEmphasized:(BOOL)v
{
    _emphasized = v;
    [self setNeedsDisplay:YES];
}
- (BOOL)allowsVibrancy
{
    return NO;
}
- (BOOL)isOpaque
{
    return NO;
}
- (NSBackgroundStyle)interiorBackgroundStyle
{
    return NSBackgroundStyleNormal;
}
- (void)drawRect:(NSRect)dirty
{
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirty);
}
@end
