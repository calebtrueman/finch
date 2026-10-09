/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CoreText's adaptive image glyph class (CTAdaptiveImageGlyph.m), for the Swift overlay. */
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

@interface CTAdaptiveImageGlyph : NSObject <CTAdaptiveImageProviding>
@property (readonly, copy) NSData *imageContent;
@property (readonly, copy) NSString *contentIdentifier;
@property (readonly, copy) NSString *contentDescription;
- (instancetype)initWithImageContent:(NSData *)content;
@end
