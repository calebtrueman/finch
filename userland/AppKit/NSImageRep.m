/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSImageRep, the registry of image rep classes, and NSCustomImageRep (an
 * image drawn by a block or a delegate).
 *
 * Reps draw through FinchDrawCGImage(): an image's portion mapped onto a
 * destination rectangle, with a compositing operation, an alpha and,
 * optionally, the flip of a flipped context undone.
 */
#import "AppKitDrawing.h"

NSNotificationName NSImageRepRegistryDidChangeNotification = @"NSImageRepRegistryDidChangeNotification";

static NSMutableArray *registered;

static void
ensure_registry(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registered = [[NSMutableArray alloc] initWithObjects:[NSBitmapImageRep class], nil]; });
}

/* The context's CTM flipped within dst (for respectFlipped: in a flipped context). */
static void
flip_within(CGContextRef c, NSRect dst)
{
    CGContextTranslateCTM(c, 0, NSMinY(dst) + NSMaxY(dst));
    CGContextScaleCTM(c, 1, -1);
}

/* Map src (in a rep of the given size) onto dst, and set up the operation and alpha. */
static BOOL
begin_draw(CGContextRef c, NSRect dst, NSRect src, NSSize repSize, NSCompositingOperation op, CGFloat fraction,
           BOOL flip, NSDictionary *hints, CGRect *imageRect)
{
    if (NSIsEmptyRect(dst) || src.size.width <= 0 || src.size.height <= 0)
        return NO;
    CGContextSaveGState(c);
    int cgop = FinchCompositeOperation(op);
    if (cgop >= 0)
        CGContextSetCompositeOperation(c, cgop);
    CGContextSetAlpha(c, fraction < 0 ? 0 : fraction > 1 ? 1 : fraction);
    NSNumber *interp = hints[NSImageHintInterpolation];
    if (interp)
        CGContextSetInterpolationQuality(c, (CGInterpolationQuality)interp.integerValue);
    if (flip)
        flip_within(c, dst);
    CGContextClipToRect(c, NSRectToCGRect(dst));
    CGFloat sx = dst.size.width / src.size.width, sy = dst.size.height / src.size.height;
    *imageRect = CGRectMake(dst.origin.x - src.origin.x * sx, dst.origin.y - src.origin.y * sy, repSize.width * sx,
                            repSize.height * sy);
    return YES;
}

FINCH_HIDDEN BOOL
FinchDrawCGImage(CGImageRef image, NSSize repSize, NSRect dst, NSRect src, NSCompositingOperation op, CGFloat fraction,
                 BOOL respectFlipped, NSDictionary *hints)
{
    NSGraphicsContext *g = [NSGraphicsContext currentContext];
    CGContextRef c = [g CGContext];
    if (!c || !image)
        return NO;
    if (NSIsEmptyRect(src))
        src = NSMakeRect(0, 0, repSize.width, repSize.height);
    CGRect r;
    if (!begin_draw(c, dst, src, repSize, op, fraction, respectFlipped && [g isFlipped], hints, &r))
        return NO;
    CGContextDrawImage(c, r, image);
    CGContextRestoreGState(c);
    return YES;
}

@implementation NSImageRep {
    NSSize _size;
    BOOL _hasAlpha, _opaque;
    NSColorSpaceName _colorSpaceName;
    NSInteger _bitsPerSample, _pixelsWide, _pixelsHigh;
    NSImageLayoutDirection _layoutDirection;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _colorSpaceName = [NSCalibratedRGBColorSpace copy];
        _layoutDirection = NSImageLayoutDirectionUnspecified;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        if ([coder allowsKeyedCoding])
            _size = [coder decodeSizeForKey:@"NSSize"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if ([coder allowsKeyedCoding])
        [coder encodeSize:_size forKey:@"NSSize"];
}

- (void)dealloc
{
    [_colorSpaceName release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSImageRep *r = NSCopyObject(self, 0, zone);
    r->_colorSpaceName = [_colorSpaceName copy];
    return r;
}

- (NSSize)size { return _size; }
- (void)setSize:(NSSize)size { _size = size; }
- (BOOL)hasAlpha { return _hasAlpha; }
- (void)setAlpha:(BOOL)alpha { _hasAlpha = alpha; }
- (BOOL)isOpaque { return _opaque; }
- (void)setOpaque:(BOOL)opaque { _opaque = opaque; }
- (NSColorSpaceName)colorSpaceName { return _colorSpaceName; }

- (void)setColorSpaceName:(NSColorSpaceName)name
{
    name = [name copy];
    [_colorSpaceName release];
    _colorSpaceName = name;
}

- (NSInteger)bitsPerSample { return _bitsPerSample; }
- (void)setBitsPerSample:(NSInteger)bps { _bitsPerSample = bps; }
- (NSInteger)pixelsWide { return _pixelsWide; }
- (void)setPixelsWide:(NSInteger)w { _pixelsWide = w; }
- (NSInteger)pixelsHigh { return _pixelsHigh; }
- (void)setPixelsHigh:(NSInteger)h { _pixelsHigh = h; }
- (NSImageLayoutDirection)layoutDirection { return _layoutDirection; }
- (void)setLayoutDirection:(NSImageLayoutDirection)d { _layoutDirection = d; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ %p Size={%g, %g} ColorSpace=%@ BPS=%ld Pixels=%ldx%ld Alpha=%@", [self class], self,
                                      _size.width, _size.height, _colorSpaceName, (long)_bitsPerSample, (long)_pixelsWide,
                                      (long)_pixelsHigh, _hasAlpha ? @"YES" : @"NO"];
}

/* MARK: Drawing */

- (BOOL)draw { return NO; }

- (BOOL)drawAtPoint:(NSPoint)point
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || (_size.width <= 0 && _size.height <= 0))
        return NO;
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, point.x, point.y);
    BOOL ok = [self draw];
    CGContextRestoreGState(c);
    return ok;
}

- (BOOL)drawInRect:(NSRect)rect
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || _size.width <= 0 || _size.height <= 0)
        return NO;
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, rect.origin.x, rect.origin.y);
    CGContextScaleCTM(c, rect.size.width / _size.width, rect.size.height / _size.height);
    BOOL ok = [self draw];
    CGContextRestoreGState(c);
    return ok;
}

- (BOOL)drawInRect:(NSRect)dstSpacePortionRect fromRect:(NSRect)srcSpacePortionRect operation:(NSCompositingOperation)op
          fraction:(CGFloat)requestedAlpha respectFlipped:(BOOL)respectContextIsFlipped hints:(NSDictionary *)hints
{
    NSGraphicsContext *g = [NSGraphicsContext currentContext];
    CGContextRef c = [g CGContext];
    if (!c || _size.width <= 0 || _size.height <= 0)
        return NO;
    NSRect src = NSIsEmptyRect(srcSpacePortionRect) ? NSMakeRect(0, 0, _size.width, _size.height) : srcSpacePortionRect;
    CGRect r;
    if (!begin_draw(c, dstSpacePortionRect, src, _size, op, requestedAlpha, respectContextIsFlipped && [g isFlipped], hints, &r))
        return NO;
    /* draw the whole rep into r through -drawInRect:, in a transparency layer so the alpha and operation apply once */
    CGContextBeginTransparencyLayer(c, NULL);
    CGContextSetAlpha(c, 1);
    BOOL ok = [self drawInRect:NSRectFromCGRect(r)];
    CGContextEndTransparencyLayer(c);
    CGContextRestoreGState(c);
    return ok;
}

/* A rendering of the rep at the proposed size in pixels (the context's scale), as Apple's base class does. */
- (CGImageRef)CGImageForProposedRect:(NSRect *)proposedDestRect context:(NSGraphicsContext *)context hints:(NSDictionary *)hints
{
    NSRect r = proposedDestRect ? *proposedDestRect : NSMakeRect(0, 0, _size.width, _size.height);
    CGFloat scale = 1;
    if (context.CGContext) {
        CGAffineTransform t = CGContextGetUserSpaceToDeviceSpaceTransform(context.CGContext);
        scale = fmax(1, sqrt(fabs(t.a * t.d - t.b * t.c)));
    }
    size_t w = (size_t)ceil(r.size.width * scale), h = (size_t)ceil(r.size.height * scale);
    if (!w || !h)
        return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bc = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!bc)
        return NULL;
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithCGContext:bc flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:g];
    CGContextScaleCTM(bc, scale, scale);
    [self drawInRect:NSMakeRect(0, 0, r.size.width, r.size.height)];
    [NSGraphicsContext restoreGraphicsState];
    CGImageRef im = CGBitmapContextCreateImage(bc);
    CGContextRelease(bc);
    return (CGImageRef)[(id)im autorelease];
}

/* MARK: Registry */

+ (void)registerImageRepClass:(Class)imageRepClass
{
    ensure_registry();
    @synchronized(registered) {
        if (![registered containsObject:imageRepClass])
            [registered addObject:imageRepClass];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:NSImageRepRegistryDidChangeNotification object:imageRepClass];
}

+ (void)unregisterImageRepClass:(Class)imageRepClass
{
    ensure_registry();
    @synchronized(registered) {
        [registered removeObject:imageRepClass];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:NSImageRepRegistryDidChangeNotification object:imageRepClass];
}

+ (NSArray<Class> *)registeredImageRepClasses
{
    ensure_registry();
    @synchronized(registered) {
        return [[registered copy] autorelease];
    }
}

+ (Class)imageRepClassForType:(NSString *)type
{
    for (Class c in [self registeredImageRepClasses])
        if ([[c imageUnfilteredTypes] containsObject:type])
            return c;
    return Nil;
}

+ (Class)imageRepClassForFileType:(NSString *)type
{
    for (Class c in [self registeredImageRepClasses])
        if ([[c imageUnfilteredFileTypes] containsObject:type])
            return c;
    return Nil;
}

+ (Class)imageRepClassForPasteboardType:(NSPasteboardType)type { return [self imageRepClassForType:type]; }

+ (Class)imageRepClassForData:(NSData *)data
{
    for (Class c in [self registeredImageRepClasses])
        if ([c canInitWithData:data])
            return c;
    return Nil;
}

+ (BOOL)canInitWithData:(NSData *)data { return NO; }
+ (NSArray<NSString *> *)imageUnfilteredTypes { return @[]; }
+ (NSArray<NSString *> *)imageUnfilteredFileTypes { return @[]; }
+ (NSArray<NSPasteboardType> *)imageUnfilteredPasteboardTypes { return [self imageUnfilteredTypes]; }

+ (NSArray<NSString *> *)imageTypes
{
    if (self != [NSImageRep class])
        return [self imageUnfilteredTypes];
    NSMutableArray *all = [NSMutableArray array];
    for (Class c in [self registeredImageRepClasses])
        for (NSString *t in [c imageUnfilteredTypes])
            if (![all containsObject:t])
                [all addObject:t];
    return all;
}

+ (NSArray<NSString *> *)imageFileTypes
{
    if (self != [NSImageRep class])
        return [self imageUnfilteredFileTypes];
    NSMutableArray *all = [NSMutableArray array];
    for (Class c in [self registeredImageRepClasses])
        for (NSString *t in [c imageUnfilteredFileTypes])
            if (![all containsObject:t])
                [all addObject:t];
    return all;
}

+ (NSArray<NSPasteboardType> *)imagePasteboardTypes { return [self imageTypes]; }
+ (BOOL)canInitWithPasteboard:(NSPasteboard *)pasteboard { return NO; }
+ (NSArray<NSImageRep *> *)imageRepsWithPasteboard:(NSPasteboard *)pasteboard { return nil; }
+ (NSImageRep *)imageRepWithPasteboard:(NSPasteboard *)pasteboard { return nil; }

+ (NSArray<NSImageRep *> *)imageRepsWithData:(NSData *)data
{
    Class c = [self imageRepClassForData:data];
    return c && c != [NSImageRep class] ? [c imageRepsWithData:data] : nil;
}

+ (NSArray<NSImageRep *> *)imageRepsWithContentsOfFile:(NSString *)filename
{
    NSData *d = [NSData dataWithContentsOfFile:filename];
    if (!d)
        return nil;
    Class c = self == [NSImageRep class] ? [self imageRepClassForData:d] : self;
    return c ? [c imageRepsWithData:d] : nil;
}

+ (NSImageRep *)imageRepWithContentsOfFile:(NSString *)filename
{
    return [[self imageRepsWithContentsOfFile:filename] firstObject];
}

+ (NSArray<NSImageRep *> *)imageRepsWithContentsOfURL:(NSURL *)url
{
    NSData *d = [NSData dataWithContentsOfURL:url];
    if (!d)
        return nil;
    Class c = self == [NSImageRep class] ? [self imageRepClassForData:d] : self;
    return c ? [c imageRepsWithData:d] : nil;
}

+ (NSImageRep *)imageRepWithContentsOfURL:(NSURL *)url
{
    return [[self imageRepsWithContentsOfURL:url] firstObject];
}

@end

/* MARK: - NSCustomImageRep */

@implementation NSCustomImageRep {
    BOOL (^_handler)(NSRect);
    BOOL _handlerFlipped;
    SEL _selector;
    id _delegate;
}

- (instancetype)initWithSize:(NSSize)size flipped:(BOOL)flipped drawingHandler:(BOOL (^)(NSRect dstRect))drawingHandler
{
    if ((self = [super init])) {
        [self setSize:size];
        _handler = [drawingHandler copy];
        _handlerFlipped = flipped;
    }
    return self;
}

- (instancetype)initWithDrawSelector:(SEL)selector delegate:(id)delegate
{
    if ((self = [super init])) {
        _selector = selector;
        _delegate = delegate;
    }
    return self;
}

- (void)dealloc
{
    [_handler release];
    [super dealloc];
}

- (BOOL (^)(NSRect))drawingHandler { return _handler; }
- (SEL)drawSelector { return _selector; }
- (id)delegate { return _delegate; }

- (NSString *)description
{
    NSSize s = [self size];
    return [NSString stringWithFormat:@"NSCustomImageRep %p Size={%g, %g} ColorSpace=Generic RGB colorspace BPS=0 Pixels=0x0 Alpha=NO", self,
                                      s.width, s.height];
}

/* The handler draws its rect (0, 0, size) in a context flipped as it asked. */
- (BOOL)draw
{
    NSGraphicsContext *g = [NSGraphicsContext currentContext];
    CGContextRef c = [g CGContext];
    if (!c)
        return NO;
    NSSize s = [self size];
    if (_handler) {
        NSGraphicsContext *hg = [NSGraphicsContext graphicsContextWithCGContext:c flipped:_handlerFlipped];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:hg];
        if (_handlerFlipped) {
            CGContextTranslateCTM(c, 0, s.height);
            CGContextScaleCTM(c, 1, -1);
        }
        BOOL ok = _handler(NSMakeRect(0, 0, s.width, s.height));
        [NSGraphicsContext restoreGraphicsState];
        return ok;
    }
    if (_delegate && _selector) {
        CGContextSaveGState(c);
        ((void (*)(id, SEL, id))objc_msgSend)(_delegate, _selector, self);
        CGContextRestoreGState(c);
        return YES;
    }
    return NO;
}

@end
