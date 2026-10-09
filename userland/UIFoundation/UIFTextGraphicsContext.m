/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * How a UI framework hands UIFoundation the context text draws in
 * (NSTextGraphicsContextProvider, as Apple's UIFoundation has it): AppKit's is
 * the standard provider (NSGraphicsContext's current context); a framework
 * such as SwiftUI registers its own provider class, and sets a context for the
 * length of a block. And NSAdaptiveImageGlyph, an inline image glyph's content.
 */
#import "UIFoundationInternal.h"

static Class provider_class;
static Class context_class;
static __thread id current_text_context;

id
UIFCurrentTextGraphicsContext(void)
{
    return current_text_context;
}

__attribute__((visibility("default")))
@interface _NSStandardTextGraphicsContextProvider : NSObject
+ (id)graphicsContextForApplicationFrameworkContext:(id)context;
@end

@implementation _NSStandardTextGraphicsContextProvider
+ (id)graphicsContextForApplicationFrameworkContext:(id)context { return context; }
@end

__attribute__((visibility("default")))
@interface NSTextGraphicsContextProvider : NSObject
@end

@implementation NSTextGraphicsContextProvider

+ (Class)textGraphicsContextProviderClass { return provider_class ?: [_NSStandardTextGraphicsContextProvider class]; }
+ (void)setTextGraphicsContextProviderClass:(Class)cls { provider_class = cls; }
+ (BOOL)textGraphicsContextProviderClassRespondsToColorQuery
{
    return [[self textGraphicsContextProviderClass] respondsToSelector:@selector(colorClassForApplicationFrameworkContext:)];
}
+ (Class)__defaultColorClass { return UIFClass("NSColor"); }
+ (Class)textGraphicsContextClass { return context_class; }
+ (void)setTextGraphicsContextClass:(Class)cls { context_class = cls; }

+ (void)setCurrentTextGraphicsContext:(id)context duringBlock:(void (^)(void))block
{
    id saved = current_text_context;
    current_text_context = context;
    @try {
        block();
    } @finally {
        current_text_context = saved;
    }
}

@end

#pragma mark - NSAdaptiveImageGlyph

@implementation NSAdaptiveImageGlyph {
    NSData *_content;
    NSString *_identifier, *_description;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (UTType *)contentType
{
    Class t = UIFClass("UTType");
    return t ? [t performSelector:@selector(typeWithIdentifier:) withObject:@"public.heic"] : nil;
}

- (instancetype)initWithImageContent:(NSData *)content
{
    if (![content length]) {
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        _content = [content copy];
        _identifier = [[[NSUUID UUID] UUIDString] copy];
        _description = @"";
    }
    return self;
}

- (instancetype)initWithCTAdaptiveImageGlyph:(id)glyph
{
    NSData *d = [glyph respondsToSelector:@selector(imageContent)] ? [glyph performSelector:@selector(imageContent)] : nil;
    return [self initWithImageContent:d ?: [NSData data]];
}

- (void)dealloc
{
    [_content release];
    [_identifier release];
    [_description release];
    [super dealloc];
}

- (NSData *)imageContent { return _content; }
- (NSString *)contentIdentifier { return _identifier; }
- (NSString *)contentDescription { return _description; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (CGImageRef)imageForProposedSize:(CGSize)proposedSize scaleFactor:(CGFloat)scaleFactor
                       imageOffset:(out CGPoint *)outImageOffset imageSize:(out CGSize *)outImageSize
{
    return NULL;
}

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_content forKey:@"NSImageContent"]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithImageContent:[coder decodeObjectOfClass:[NSData class] forKey:@"NSImageContent"]];
}

@end
