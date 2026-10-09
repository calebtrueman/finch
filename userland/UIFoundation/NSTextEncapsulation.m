/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextEncapsulation: a frame drawn around a run of text (a rounded rectangle,
 * rectangle or capsule, outlined or filled), as the NSTextEncapsulation
 * attribute's value, and the attribute names SwiftUI's text uses. The values
 * are kept; Finch's text drawing doesn't draw the frame yet.
 */
#import "UIFoundationInternal.h"

__attribute__((visibility("default"))) NSString *const NSTextEncapsulationAttributeName = @"NSTextEncapsulation";
__attribute__((visibility("default"))) NSString *const NSLanguageIdentifierAttributeName = @"NSLanguage";

__attribute__((visibility("default")))
@interface NSTextEncapsulation : NSObject <NSCopying, NSSecureCoding>
@property (nonatomic) NSUInteger scale;
@property (nonatomic) NSUInteger shape;
@property (nonatomic) NSUInteger style;
@property (nonatomic) NSUInteger platterSize;
@property (nonatomic) CGFloat lineWeight;
@property (nonatomic, strong) NSObject *color;
@property (nonatomic) CGFloat minimumWidth;
@end

@implementation NSTextEncapsulation

+ (BOOL)supportsSecureCoding { return YES; }

- (void)dealloc
{
    [_color release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSTextEncapsulation *c = [[NSTextEncapsulation allocWithZone:zone] init];
    c.scale = _scale;
    c.shape = _shape;
    c.style = _style;
    c.platterSize = _platterSize;
    c.lineWeight = _lineWeight;
    c.color = _color;
    c.minimumWidth = _minimumWidth;
    return c;
}

- (BOOL)isEqual:(id)o
{
    if (![o isKindOfClass:[NSTextEncapsulation class]])
        return NO;
    NSTextEncapsulation *e = o;
    return e.scale == _scale && e.shape == _shape && e.style == _style && e.platterSize == _platterSize &&
           e.lineWeight == _lineWeight && e.minimumWidth == _minimumWidth && (e.color == _color || [e.color isEqual:_color]);
}

- (NSUInteger)hash { return _scale ^ _shape << 2 ^ _style << 4 ^ _platterSize << 6; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:(NSInteger)_scale forKey:@"NSScale"];
    [coder encodeInteger:(NSInteger)_shape forKey:@"NSShape"];
    [coder encodeInteger:(NSInteger)_style forKey:@"NSStyle"];
    [coder encodeInteger:(NSInteger)_platterSize forKey:@"NSPlatterSize"];
    [coder encodeDouble:_lineWeight forKey:@"NSLineWeight"];
    [coder encodeDouble:_minimumWidth forKey:@"NSMinimumWidth"];
    if (_color)
        [coder encodeObject:_color forKey:@"NSColor"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _scale = (NSUInteger)[coder decodeIntegerForKey:@"NSScale"];
        _shape = (NSUInteger)[coder decodeIntegerForKey:@"NSShape"];
        _style = (NSUInteger)[coder decodeIntegerForKey:@"NSStyle"];
        _platterSize = (NSUInteger)[coder decodeIntegerForKey:@"NSPlatterSize"];
        _lineWeight = [coder decodeDoubleForKey:@"NSLineWeight"];
        _minimumWidth = [coder decodeDoubleForKey:@"NSMinimumWidth"];
        _color = [[coder decodeObjectOfClass:[NSObject class] forKey:@"NSColor"] retain];
    }
    return self;
}

- (void)setPlatformColor:(NSObject *)color { self.color = color; }

@end
