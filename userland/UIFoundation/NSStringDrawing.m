/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * String drawing and measuring (NSStringDrawing.h): NSString and
 * NSAttributedString, laid out as Apple's text system lays out a string in
 * a text container, and drawn with CoreText into the current
 * NSGraphicsContext's CGContext.
 *
 * The layout itself is UIFTextLayout.m's.
 */
#import "UIFTextLayout.h"

UIF_HIDDEN void UIFStringDrawingContextSetResult(NSStringDrawingContext *c, CGFloat scale, CGRect bounds);

#pragma mark - The API

static NSAttributedString *
attributed(NSString *s, NSDictionary *attrs)
{
    return [[[NSAttributedString alloc] initWithString:s ? s : @"" attributes:attrs] autorelease];
}

static NSDictionary *
typing_attributes(NSAttributedString *s)
{
    return s.length ? [s attributesAtIndex:s.length - 1 effectiveRange:NULL] : @{};
}

static CGRect
bounding_rect(NSAttributedString *s, NSDictionary *typing, CGSize size, NSStringDrawingOptions options,
              NSStringDrawingContext *context)
{
    UIFLayoutParams p = {size.width, size.height, options, 0, NO, NO, 0, NO};
    UIFLayout L = UIFLayoutString(s, typing, p);
    CGRect r = UIFLayoutUsedRect(&L, p);
    UIFLayoutFree(&L);
    UIFStringDrawingContextSetResult(context, 1, r);
    return r;
}

static void
draw_in_rect(NSAttributedString *s, NSDictionary *typing, CGRect rect, NSStringDrawingOptions options,
             NSStringDrawingContext *context, BOOL clip)
{
    BOOL flipped = UIFCurrentContextIsFlipped();
    BOOL multi = (options & NSStringDrawingUsesLineFragmentOrigin) != 0;
    UIFLayoutParams p = {multi ? rect.size.width : 0, multi ? rect.size.height : 0, options, 0, NO, NO, 0, NO};
    UIFLayout L = UIFLayoutString(s, typing, p);
    CGRect used = UIFLayoutUsedRect(&L, p);
    if (multi) {
        CGFloat top = flipped ? CGRectGetMinY(rect) : CGRectGetMaxY(rect);
        CGContextRef cg = clip ? UIFCurrentCGContext() : NULL;
        if (cg) {
            CGContextSaveGState(cg);
            CGContextClipToRect(cg, rect);
        }
        UIFLayoutDraw(&L, rect.origin.x, top, flipped);
        if (cg)
            CGContextRestoreGState(cg);
    } else if (L.count) {
        /* The rectangle's origin is the first line's baseline. */
        UIFLine *ln = &L.lines[0];
        CGFloat top = flipped ? rect.origin.y - ln->baseline : rect.origin.y + ln->baseline;
        UIFLayoutDraw(&L, rect.origin.x - ln->x, top, flipped);
    }
    UIFLayoutFree(&L);
    UIFStringDrawingContextSetResult(context, 1, used);
}

static void
draw_at_point(NSAttributedString *s, NSDictionary *typing, CGPoint point)
{
    BOOL flipped = UIFCurrentContextIsFlipped();
    UIFLayoutParams p = {0, 0, NSStringDrawingUsesLineFragmentOrigin, 0, NO, NO, 0, NO};
    UIFLayout L = UIFLayoutString(s, typing, p);
    /* The point is the top-left of the text in a flipped context, its bottom-left otherwise. */
    CGFloat top = flipped ? point.y : point.y + L.height;
    UIFLayoutDraw(&L, point.x, top, flipped);
    UIFLayoutFree(&L);
}

@implementation NSString (NSStringDrawing)

- (CGSize)sizeWithAttributes:(NSDictionary *)attrs
{
    return [self boundingRectWithSize:CGSizeZero options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs context:nil]
        .size;
}

- (void)drawAtPoint:(CGPoint)point withAttributes:(NSDictionary *)attrs
{
    draw_at_point(attributed(self, attrs), attrs ? attrs : @{}, point);
}

- (void)drawInRect:(CGRect)rect withAttributes:(NSDictionary *)attrs
{
    draw_in_rect(attributed(self, attrs), attrs ? attrs : @{}, rect, NSStringDrawingUsesLineFragmentOrigin, nil, YES);
}

- (void)drawWithRect:(CGRect)rect
             options:(NSStringDrawingOptions)options
          attributes:(NSDictionary *)attributes
             context:(NSStringDrawingContext *)context
{
    draw_in_rect(attributed(self, attributes), attributes ? attributes : @{}, rect, options, context, NO);
}

- (CGRect)boundingRectWithSize:(CGSize)size
                       options:(NSStringDrawingOptions)options
                    attributes:(NSDictionary *)attributes
                       context:(NSStringDrawingContext *)context
{
    return bounding_rect(attributed(self, attributes), attributes ? attributes : @{}, size, options, context);
}

- (void)drawWithRect:(NSRect)rect options:(NSStringDrawingOptions)options attributes:(NSDictionary *)attributes
{
    [self drawWithRect:rect options:options attributes:attributes context:nil];
}

- (NSRect)boundingRectWithSize:(NSSize)size options:(NSStringDrawingOptions)options attributes:(NSDictionary *)attributes
{
    return [self boundingRectWithSize:size options:options attributes:attributes context:nil];
}

@end

@implementation NSAttributedString (NSStringDrawing)

- (CGSize)size
{
    return [self boundingRectWithSize:CGSizeZero options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
}

- (void)drawAtPoint:(CGPoint)point
{
    draw_at_point(self, typing_attributes(self), point);
}

- (void)drawInRect:(CGRect)rect
{
    draw_in_rect(self, typing_attributes(self), rect, NSStringDrawingUsesLineFragmentOrigin, nil, YES);
}

- (void)drawWithRect:(CGRect)rect options:(NSStringDrawingOptions)options context:(NSStringDrawingContext *)context
{
    draw_in_rect(self, typing_attributes(self), rect, options, context, NO);
}

- (CGRect)boundingRectWithSize:(CGSize)size options:(NSStringDrawingOptions)options context:(NSStringDrawingContext *)context
{
    return bounding_rect(self, typing_attributes(self), size, options, context);
}

- (void)drawWithRect:(NSRect)rect options:(NSStringDrawingOptions)options
{
    [self drawWithRect:rect options:options context:nil];
}

- (NSRect)boundingRectWithSize:(NSSize)size options:(NSStringDrawingOptions)options
{
    return [self boundingRectWithSize:size options:options context:nil];
}

@end

/* Apple's private string-drawing class settings that apps still call. */
@implementation NSString (FinchDrawingSettings)
+ (CGFloat)defaultLineHeightForFont:(NSFont *)font
{
    NSLayoutManager *lm = [[[NSLayoutManager alloc] init] autorelease];
    return [lm defaultLineHeightForFont:font];
}
+ (BOOL)usesScreenFonts { return NO; }
+ (void)setUsesScreenFonts:(BOOL)f {}
+ (float)hyphenationFactor { return 0; }
+ (void)setDefaultAttachmentScaling:(NSUInteger)s {}
@end
