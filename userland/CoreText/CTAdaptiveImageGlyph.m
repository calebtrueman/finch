/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CTAdaptiveImageGlyph: an adaptive image glyph's content (CoreText's class, which
 * NSAdaptiveImageGlyph and AttributedString.AdaptiveImageGlyph carry). Finch keeps the
 * image content data; it provides no image for a size yet.
 */
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

__attribute__((visibility("default")))
@interface CTAdaptiveImageGlyph : NSObject <CTAdaptiveImageProviding, NSSecureCoding>
@property (readonly, copy) NSData *imageContent;
@property (readonly, copy) NSString *contentIdentifier;
@property (readonly, copy) NSString *contentDescription;
- (instancetype)initWithImageContent:(NSData *)content;
@end

@implementation CTAdaptiveImageGlyph

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithImageContent:(NSData *)content
{
    if ((self = [super init])) {
        _imageContent = [content copy];
        _contentIdentifier = [[NSUUID UUID] UUIDString];
        _contentDescription = @"";
    }
    return self;
}

- (CGImageRef)imageForProposedSize:(CGSize)proposedSize scaleFactor:(CGFloat)scaleFactor
                       imageOffset:(out CGPoint *)outImageOffset imageSize:(out CGSize *)outImageSize
{
    return NULL;
}

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_imageContent forKey:@"NSImageContent"]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithImageContent:[coder decodeObjectOfClass:[NSData class] forKey:@"NSImageContent"] ?: [NSData data]];
}

@end
