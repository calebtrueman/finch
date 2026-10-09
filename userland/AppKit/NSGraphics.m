/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The NSGraphics.h functions: rect filling, framing and clipping in the
 * current context (filled with NSCompositingOperationCopy, as Apple's), tiled
 * rects and the classic bezels, window depths, and NSBeep.
 */
#import "AppKitDrawing.h"

NSDeviceDescriptionKey NSDeviceResolution = @"NSDeviceResolution";
NSDeviceDescriptionKey NSDeviceColorSpaceName = @"NSDeviceColorSpaceName";
NSDeviceDescriptionKey NSDeviceBitsPerSample = @"NSDeviceBitsPerSample";
NSDeviceDescriptionKey NSDeviceIsScreen = @"NSDeviceIsScreen";
NSDeviceDescriptionKey NSDeviceIsPrinter = @"NSDeviceIsPrinter";
NSDeviceDescriptionKey NSDeviceSize = @"NSDeviceSize";

/* MARK: Filling and framing */

static void
fill_rects(const NSRect *rects, NSInteger count, NSCompositingOperation op)
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || count <= 0)
        return;
    CGContextSaveGState(c);
    int cgop = FinchCompositeOperation(op);
    if (cgop >= 0)
        CGContextSetCompositeOperation(c, cgop);
    for (NSInteger i = 0; i < count; i++)
        CGContextFillRect(c, NSRectToCGRect(rects[i]));
    CGContextRestoreGState(c);
}

void NSRectFill(NSRect rect) { fill_rects(&rect, 1, NSCompositingOperationCopy); }
void NSRectFillList(const NSRect *rects, NSInteger count) { fill_rects(rects, count, NSCompositingOperationCopy); }
void NSRectFillUsingOperation(NSRect rect, NSCompositingOperation op) { fill_rects(&rect, 1, op); }
void NSRectFillListUsingOperation(const NSRect *rects, NSInteger count, NSCompositingOperation op) { fill_rects(rects, count, op); }

void
NSRectFillListWithColorsUsingOperation(const NSRect *rects, NSColor *const *colors, NSInteger num, NSCompositingOperation op)
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c)
        return;
    CGContextSaveGState(c);
    for (NSInteger i = 0; i < num; i++) {
        [colors[i] setFill];
        fill_rects(&rects[i], 1, op);
    }
    CGContextRestoreGState(c);
}

void
NSRectFillListWithColors(const NSRect *rects, NSColor *const *colors, NSInteger num)
{
    NSRectFillListWithColorsUsingOperation(rects, colors, num, NSCompositingOperationCopy);
}

void
NSRectFillListWithGrays(const NSRect *rects, const CGFloat *grays, NSInteger num)
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c)
        return;
    CGContextSaveGState(c);
    for (NSInteger i = 0; i < num; i++) {
        [[NSColor colorWithDeviceWhite:grays[i] alpha:1] setFill];
        fill_rects(&rects[i], 1, NSCompositingOperationCopy);
    }
    CGContextRestoreGState(c);
}

void
NSFrameRectWithWidthUsingOperation(NSRect rect, CGFloat frameWidth, NSCompositingOperation op)
{
    if (NSIsEmptyRect(rect))
        return;
    CGFloat w = fmin(frameWidth, fmin(rect.size.width, rect.size.height) / 2);
    NSRect sides[4] = {
        NSMakeRect(NSMinX(rect), NSMinY(rect), rect.size.width, w),
        NSMakeRect(NSMinX(rect), NSMaxY(rect) - w, rect.size.width, w),
        NSMakeRect(NSMinX(rect), NSMinY(rect) + w, w, rect.size.height - 2 * w),
        NSMakeRect(NSMaxX(rect) - w, NSMinY(rect) + w, w, rect.size.height - 2 * w),
    };
    fill_rects(sides, 4, op);
}

void NSFrameRectWithWidth(NSRect rect, CGFloat frameWidth) { NSFrameRectWithWidthUsingOperation(rect, frameWidth, NSCompositingOperationCopy); }
void NSFrameRect(NSRect rect) { NSFrameRectWithWidth(rect, 1); }

void
NSEraseRect(NSRect rect)
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c)
        return;
    CGContextSaveGState(c);
    CGContextSetGrayFillColor(c, 1, 1);
    CGContextSetCompositeOperation(c, 1);
    CGContextFillRect(c, NSRectToCGRect(rect));
    CGContextRestoreGState(c);
}

void
NSRectClip(NSRect rect)
{
    CGContextRef c = FinchCurrentCGContext();
    if (c)
        CGContextClipToRect(c, NSRectToCGRect(rect));
}

void
NSRectClipList(const NSRect *rects, NSInteger count)
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || count <= 0)
        return;
    CGRect *r = malloc(sizeof(CGRect) * (size_t)count);
    for (NSInteger i = 0; i < count; i++)
        r[i] = NSRectToCGRect(rects[i]);
    CGContextClipToRects(c, r, (size_t)count);
    free(r);
}

void
NSDottedFrameRect(NSRect rect)
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c)
        return;
    CGContextSaveGState(c);
    CGFloat dash[2] = {1, 1};
    CGContextSetLineDash(c, 0, dash, 2);
    CGContextSetLineWidth(c, 1);
    CGContextStrokeRect(c, CGRectInset(NSRectToCGRect(rect), 0.5, 0.5));
    CGContextRestoreGState(c);
}

void
NSDrawWindowBackground(NSRect rect)
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c)
        return;
    CGContextSaveGState(c);
    [[NSColor windowBackgroundColor] setFill];
    fill_rects(&rect, 1, NSCompositingOperationCopy);
    CGContextRestoreGState(c);
}

void NSHighlightRect(NSRect rect) { NSRectFillUsingOperation(rect, NSCompositingOperationXOR); }
void NSSetFocusRingStyle(NSFocusRingPlacement placement) {}
void NSBeep(void) {}
void NSDisableScreenUpdates(void) {}
void NSEnableScreenUpdates(void) {}
void NSCopyBits(NSInteger srcGState, NSRect srcRect, NSPoint destPoint) {}

void
NSShowAnimationEffect(NSAnimationEffect animationEffect, NSPoint centerLocation, NSSize size, id animationDelegate,
                      SEL didEndSelector, void *contextInfo)
{
    if (animationDelegate && didEndSelector)
        ((void (*)(id, SEL, void *))objc_msgSend)(animationDelegate, didEndSelector, contextInfo);
}

/* The colour of the current bitmap context's pixel under a point (deprecated, but apps still read pixels this way). */
NSColor *
NSReadPixel(NSPoint passedPoint)
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || !CGBitmapContextGetData(c) || CGBitmapContextGetBitsPerComponent(c) != 8 || CGBitmapContextGetBitsPerPixel(c) != 32)
        return nil;
    CGPoint d = CGContextConvertPointToDeviceSpace(c, NSPointToCGPoint(passedPoint));
    long x = (long)floor(d.x), y = (long)CGBitmapContextGetHeight(c) - 1 - (long)floor(d.y);
    if (x < 0 || y < 0 || x >= (long)CGBitmapContextGetWidth(c) || y >= (long)CGBitmapContextGetHeight(c))
        return nil;
    const unsigned char *p = (const unsigned char *)CGBitmapContextGetData(c) + y * CGBitmapContextGetBytesPerRow(c) + 4 * x;
    CGBitmapInfo bi = CGBitmapContextGetBitmapInfo(c);
    CGImageAlphaInfo ai = (CGImageAlphaInfo)(bi & kCGBitmapAlphaInfoMask);
    BOOL little = (bi & kCGBitmapByteOrderMask) == kCGBitmapByteOrder32Little;
    unsigned char px[4];
    for (int k = 0; k < 4; k++)
        px[k] = little ? p[3 - k] : p[k];
    BOOL first = ai == kCGImageAlphaPremultipliedFirst || ai == kCGImageAlphaFirst || ai == kCGImageAlphaNoneSkipFirst;
    unsigned char r = px[first ? 1 : 0], g = px[first ? 2 : 1], b = px[first ? 3 : 2], a = px[first ? 0 : 3];
    if (ai == kCGImageAlphaNoneSkipFirst || ai == kCGImageAlphaNoneSkipLast || ai == kCGImageAlphaNone)
        a = 255;
    double fa = a / 255.0;
    BOOL premul = ai == kCGImageAlphaPremultipliedFirst || ai == kCGImageAlphaPremultipliedLast;
    double k = premul && a ? 255.0 / a : 1;
    return [NSColor colorWithDeviceRed:r * k / 255 green:g * k / 255 blue:b * k / 255 alpha:fa];
}

/* MARK: Tiled rects and bezels */

NSRect
NSDrawColorTiledRects(NSRect boundsRect, NSRect clipRect, const NSRectEdge *sides, NSColor **colors, NSInteger count)
{
    NSRect remainder = boundsRect, slice;
    CGContextRef c = FinchCurrentCGContext();
    if (c)
        CGContextSaveGState(c);
    for (NSInteger i = 0; i < count; i++) {
        NSDivideRect(remainder, &slice, &remainder, 1, sides[i]);
        NSRect r = NSIntersectionRect(slice, clipRect);
        if (c && !NSIsEmptyRect(r)) {
            [colors[i] setFill];
            fill_rects(&r, 1, NSCompositingOperationCopy);
        }
    }
    if (c)
        CGContextRestoreGState(c);
    return remainder;
}

NSRect
NSDrawTiledRects(NSRect boundsRect, NSRect clipRect, const NSRectEdge *sides, const CGFloat *grays, NSInteger count)
{
    NSColor **colors = malloc(sizeof(NSColor *) * (size_t)(count ? count : 1));
    for (NSInteger i = 0; i < count; i++)
        colors[i] = [NSColor colorWithCalibratedWhite:grays[i] alpha:1];
    NSRect r = NSDrawColorTiledRects(boundsRect, clipRect, sides, colors, count);
    free(colors);
    return r;
}

/* The bezels as Apple has always drawn them: edges of grays, in Finch's own flat look rather than Apple's artwork. */
static NSRect
bezel(NSRect rect, NSRect clip, const NSRectEdge *sides, const CGFloat *grays, NSInteger n, CGFloat fill)
{
    NSRect inner = NSDrawTiledRects(rect, clip, sides, grays, n);
    if (fill >= 0) {
        CGContextRef c = FinchCurrentCGContext();
        if (c) {
            CGContextSaveGState(c);
            [[NSColor colorWithCalibratedWhite:fill alpha:1] setFill];
            NSRect r = NSIntersectionRect(inner, clip);
            fill_rects(&r, 1, NSCompositingOperationCopy);
            CGContextRestoreGState(c);
        }
    }
    return inner;
}

static const NSRectEdge bezel_sides[] = {NSRectEdgeMaxX, NSRectEdgeMinY, NSRectEdgeMinX, NSRectEdgeMaxY,
                                         NSRectEdgeMaxX, NSRectEdgeMinY, NSRectEdgeMinX, NSRectEdgeMaxY};

void
NSDrawGrayBezel(NSRect rect, NSRect clipRect)
{
    const CGFloat grays[] = {NSWhite, NSWhite, NSDarkGray, NSDarkGray, NSLightGray, NSLightGray, NSBlack, NSBlack};
    bezel(rect, clipRect, bezel_sides, grays, 8, NSLightGray);
}

void
NSDrawGroove(NSRect rect, NSRect clipRect)
{
    const CGFloat grays[] = {NSWhite, NSWhite, NSDarkGray, NSDarkGray, NSDarkGray, NSDarkGray, NSWhite, NSWhite};
    bezel(rect, clipRect, bezel_sides, grays, 8, NSLightGray);
}

void
NSDrawWhiteBezel(NSRect rect, NSRect clipRect)
{
    const CGFloat grays[] = {NSWhite, NSWhite, NSDarkGray, NSDarkGray, NSLightGray, NSLightGray, NSDarkGray, NSDarkGray};
    bezel(rect, clipRect, bezel_sides, grays, 8, NSWhite);
}

void
NSDrawButton(NSRect rect, NSRect clipRect)
{
    static const NSRectEdge sides[] = {NSRectEdgeMaxX, NSRectEdgeMinY, NSRectEdgeMinX, NSRectEdgeMaxY, NSRectEdgeMaxX, NSRectEdgeMinY};
    const CGFloat grays[] = {NSBlack, NSBlack, NSWhite, NSWhite, NSDarkGray, NSDarkGray};
    bezel(rect, clipRect, sides, grays, 6, NSLightGray);
}

void
NSDrawDarkBezel(NSRect rect, NSRect clipRect)
{
    const CGFloat grays[] = {NSWhite, NSWhite, NSLightGray, NSLightGray, NSLightGray, NSLightGray, NSBlack, NSBlack};
    bezel(rect, clipRect, bezel_sides, grays, 8, NSDarkGray);
}

void
NSDrawLightBezel(NSRect rect, NSRect clipRect)
{
    const CGFloat grays[] = {NSWhite, NSWhite, NSLightGray, NSLightGray, NSLightGray, NSLightGray, NSDarkGray, NSDarkGray};
    bezel(rect, clipRect, bezel_sides, grays, 8, NSWhite);
}

/* MARK: Window depths: (colour space code << 8) | bits per sample */

static const NSWindowDepth depths[] = {0x108, 0x204, 0x208, 0x210, 0x220, 0};

const NSWindowDepth *NSAvailableWindowDepths(void) { return depths; }

NSWindowDepth
NSBestDepth(NSColorSpaceName colorSpace, NSInteger bps, NSInteger bpp, BOOL planar, BOOL *exactMatch)
{
    NSWindowDepth d;
    BOOL exact = YES;
    if ([colorSpace isEqualToString:NSDeviceWhiteColorSpace] || [colorSpace isEqualToString:NSCalibratedWhiteColorSpace] ||
        [colorSpace isEqualToString:NSDeviceBlackColorSpace] || [colorSpace isEqualToString:NSCalibratedBlackColorSpace])
        d = bps <= 2 ? 0x102 : 0x108;
    else if ([colorSpace isEqualToString:NSDeviceRGBColorSpace] || [colorSpace isEqualToString:NSCalibratedRGBColorSpace])
        d = bps <= 4 ? 0x204 : bps <= 12 ? 0x208 : bps <= 16 ? 0x210 : 0x220;
    else
        d = 0x208, exact = NO;
    if (exactMatch)
        *exactMatch = exact;
    return d;
}

BOOL NSPlanarFromDepth(NSWindowDepth depth) { return ((depth >> 8) & 0xf) == 1; }

NSColorSpaceName
NSColorSpaceFromDepth(NSWindowDepth depth)
{
    switch ((depth >> 8) & 0xf) {
    case 0: return NSCalibratedBlackColorSpace;
    case 1: return NSCalibratedWhiteColorSpace;
    case 2: return NSCalibratedRGBColorSpace;
    case 5: return NSDeviceCMYKColorSpace;
    default: NSLog(@"Bad colorspace number %d", (int)((depth >> 8) & 0xf)); return nil;
    }
}

NSInteger NSBitsPerSampleFromDepth(NSWindowDepth depth) { return depth & 0xff; }

NSInteger
NSBitsPerPixelFromDepth(NSWindowDepth depth)
{
    switch (depth) {
    case 0x102: return 2;
    case 0x108: return 8;
    case 0x202: return 8;
    case 0x204: return 12;
    case 0x208: return 24;
    case 0x210: return 64;
    case 0x220: return 128;
    default: return 0;
    }
}

NSInteger
NSNumberOfColorComponents(NSColorSpaceName colorSpaceName)
{
    if ([colorSpaceName isEqualToString:NSDeviceRGBColorSpace] || [colorSpaceName isEqualToString:NSCalibratedRGBColorSpace])
        return 3;
    if ([colorSpaceName isEqualToString:NSDeviceWhiteColorSpace] || [colorSpaceName isEqualToString:NSCalibratedWhiteColorSpace] ||
        [colorSpaceName isEqualToString:NSDeviceBlackColorSpace] || [colorSpaceName isEqualToString:NSCalibratedBlackColorSpace])
        return 1;
    if ([colorSpaceName isEqualToString:NSDeviceCMYKColorSpace])
        return 4;
    NSLog(@"Bad colorspace name %@", colorSpaceName);
    return 0;
}
