/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSBitmapImageRep: pixels in memory (meshed or planar, 1 to 32 bits per
 * sample) or decoded from a CGImage (initWithCGImage:, or ImageIO for
 * initWithData:). A rep made from a CGImage keeps it until its pixels are
 * asked for.
 *
 * Measured on Apple's: rows of an allocated buffer are padded to 32 bytes;
 * byte-order flags are dropped for allocated buffers; 16- and 32-bit samples
 * are in host order unless a big-endian flag says otherwise; colours are
 * written truncated, premultiplied where the format is.
 */
#import "AppKitDrawing.h"
#import <ImageIO/ImageIO.h>
#include <math.h>

NSBitmapImageRepPropertyKey NSImageCompressionMethod = @"NSImageCompressionMethod";
NSBitmapImageRepPropertyKey NSImageCompressionFactor = @"NSImageCompressionFactor";
NSBitmapImageRepPropertyKey NSImageDitherTransparency = @"NSImageDitherTransparency";
NSBitmapImageRepPropertyKey NSImageRGBColorTable = @"NSImageRGBColorTable";
NSBitmapImageRepPropertyKey NSImageInterlaced = @"NSImageInterlaced";
NSBitmapImageRepPropertyKey NSImageColorSyncProfileData = @"NSImageColorSyncProfileData";
NSBitmapImageRepPropertyKey NSImageFrameCount = @"NSImageFrameCount";
NSBitmapImageRepPropertyKey NSImageCurrentFrame = @"NSImageCurrentFrame";
NSBitmapImageRepPropertyKey NSImageCurrentFrameDuration = @"NSImageCurrentFrameDuration";
NSBitmapImageRepPropertyKey NSImageLoopCount = @"NSImageLoopCount";
NSBitmapImageRepPropertyKey NSImageGamma = @"NSImageGamma";
NSBitmapImageRepPropertyKey NSImageProgressive = @"NSImageProgressive";
NSBitmapImageRepPropertyKey NSImageEXIFData = @"NSImageEXIFData";
NSBitmapImageRepPropertyKey NSImageIPTCData = @"NSImageIPTCData";
NSBitmapImageRepPropertyKey NSImageFallbackBackgroundColor = @"NSImageFallbackBackgroundColor";

static NSInteger
components_for_name(NSString *name)
{
    if ([name isEqualToString:NSDeviceRGBColorSpace] || [name isEqualToString:NSCalibratedRGBColorSpace])
        return 3;
    if ([name isEqualToString:NSDeviceWhiteColorSpace] || [name isEqualToString:NSCalibratedWhiteColorSpace] ||
        [name isEqualToString:NSDeviceBlackColorSpace] || [name isEqualToString:NSCalibratedBlackColorSpace])
        return 1;
    if ([name isEqualToString:NSDeviceCMYKColorSpace])
        return 4;
    return 0;
}

static NSColorSpace *
space_for_name(NSString *name)
{
    if ([name isEqualToString:NSDeviceRGBColorSpace])
        return [NSColorSpace deviceRGBColorSpace];
    if ([name isEqualToString:NSCalibratedRGBColorSpace])
        return [NSColorSpace genericRGBColorSpace];
    if ([name isEqualToString:NSDeviceWhiteColorSpace] || [name isEqualToString:NSDeviceBlackColorSpace])
        return [NSColorSpace deviceGrayColorSpace];
    if ([name isEqualToString:NSCalibratedWhiteColorSpace] || [name isEqualToString:NSCalibratedBlackColorSpace])
        return [NSColorSpace genericGrayColorSpace];
    if ([name isEqualToString:NSDeviceCMYKColorSpace])
        return [NSColorSpace deviceCMYKColorSpace];
    return nil;
}

static NSString *
name_for_space(NSColorSpace *space)
{
    BOOL device = [space isEqual:[NSColorSpace deviceRGBColorSpace]] || [space isEqual:[NSColorSpace deviceGrayColorSpace]];
    switch (space.colorSpaceModel) {
    case NSColorSpaceModelRGB: return device ? NSDeviceRGBColorSpace : NSCalibratedRGBColorSpace;
    case NSColorSpaceModelGray: return device ? NSDeviceWhiteColorSpace : NSCalibratedWhiteColorSpace;
    case NSColorSpaceModelCMYK: return NSDeviceCMYKColorSpace;
    default: return NSCustomColorSpace;
    }
}

static NSString *
uti_for_type(NSBitmapImageFileType t)
{
    switch (t) {
    case NSBitmapImageFileTypeTIFF: return @"public.tiff";
    case NSBitmapImageFileTypeBMP: return @"com.microsoft.bmp";
    case NSBitmapImageFileTypeGIF: return @"com.compuserve.gif";
    case NSBitmapImageFileTypeJPEG: return @"public.jpeg";
    case NSBitmapImageFileTypePNG: return @"public.png";
    case NSBitmapImageFileTypeJPEG2000: return @"public.jpeg-2000";
    }
    return nil;
}

@implementation NSBitmapImageRep {
    unsigned char *_planes[5];
    NSMutableData *_owned;
    BOOL _planar;
    NSInteger _spp, _bpp, _bpr;
    NSBitmapFormat _format;
    NSColorSpace *_space;
    CGImageRef _image;    /* the source image (pixels not yet loaded) or a cached rendering of the pixels */
    BOOL _loaded;         /* _planes hold the pixels */
    BOOL _drawnInto;      /* a graphics context draws into the pixels: don't cache images of them */
    NSMutableDictionary *_properties;
    NSTIFFCompression _compression;
    float _factor;
    CGImageSourceRef _incremental;
    NSMutableData *_incrementalData;
}

/* MARK: Creating */

- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height
                           bitsPerSample:(NSInteger)bps samplesPerPixel:(NSInteger)spp hasAlpha:(BOOL)alpha isPlanar:(BOOL)isPlanar
                          colorSpaceName:(NSColorSpaceName)colorSpaceName bytesPerRow:(NSInteger)rBytes bitsPerPixel:(NSInteger)pBits
{
    return [self initWithBitmapDataPlanes:planes pixelsWide:width pixelsHigh:height bitsPerSample:bps samplesPerPixel:spp
                                 hasAlpha:alpha isPlanar:isPlanar colorSpaceName:colorSpaceName bitmapFormat:0
                              bytesPerRow:rBytes bitsPerPixel:pBits];
}

- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height
                           bitsPerSample:(NSInteger)bps samplesPerPixel:(NSInteger)spp hasAlpha:(BOOL)alpha isPlanar:(BOOL)isPlanar
                          colorSpaceName:(NSColorSpaceName)colorSpaceName bitmapFormat:(NSBitmapFormat)bitmapFormat
                             bytesPerRow:(NSInteger)rBytes bitsPerPixel:(NSInteger)pBits
{
    if (!(self = [super init]))
        return nil;
    NSInteger ncomp = components_for_name(colorSpaceName);
    if (!ncomp) {
        NSLog(@"Bad colorspace name %@", colorSpaceName);
        [self release];
        return nil;
    }
    BOOL bpsOK = bps == 1 || bps == 2 || bps == 4 || bps == 8 || bps == 16 || bps == 32;
    if ((bitmapFormat & NSBitmapFormatFloatingPointSamples) && bps != 16 && bps != 32)
        bpsOK = NO;
    NSInteger minBpp = isPlanar ? bps : bps * spp;
    if (width < 1 || height < 1 || !bpsOK || spp != ncomp + (alpha ? 1 : 0) || (pBits && pBits < minBpp)) {
        NSLog(@"Inconsistent set of values to create NSBitmapImageRep");
        [self release];
        return nil;
    }
    NSInteger bpp = pBits ? pBits : minBpp;
    NSInteger rowBytes = (width * bpp + 7) / 8;
    if (rBytes && rBytes < rowBytes) {
        NSLog(@"Inconsistent set of values to create NSBitmapImageRep");
        [self release];
        return nil;
    }
    BOOL allocate = !planes || !planes[0];
    _bpr = rBytes ? rBytes : allocate ? (rowBytes + 31) / 32 * 32 : rowBytes;
    _bpp = bpp;
    _spp = spp;
    _planar = isPlanar;
    _format = allocate ? (bitmapFormat & 7) : bitmapFormat;
    NSInteger nplanes = isPlanar ? spp : 1;
    if (allocate) {
        _owned = [[NSMutableData alloc] initWithLength:(NSUInteger)(_bpr * height * nplanes)];
        for (NSInteger i = 0; i < nplanes; i++)
            _planes[i] = (unsigned char *)_owned.mutableBytes + i * _bpr * height;
    } else {
        for (NSInteger i = 0; i < nplanes; i++)
            _planes[i] = planes[i];
    }
    _loaded = YES;
    [self setPixelsWide:width];
    [self setPixelsHigh:height];
    [self setSize:NSMakeSize(width, height)];
    [self setBitsPerSample:bps];
    [self setAlpha:alpha];
    [self setOpaque:YES];
    [self setColorSpaceName:colorSpaceName];
    _space = [space_for_name(colorSpaceName) retain];
    return self;
}

- (void)_adoptCGImage:(CGImageRef)image
{
    _image = CGImageRetain(image);
    _loaded = NO;
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    CGColorSpaceRef cs = CGImageGetColorSpace(image);
    _space = cs ? [[NSColorSpace alloc] initWithCGColorSpace:cs] : [[NSColorSpace deviceGrayColorSpace] retain];
    CGImageAlphaInfo ai = CGImageGetAlphaInfo(image);
    BOOL hasAlpha = ai != kCGImageAlphaNone && ai != kCGImageAlphaNoneSkipFirst && ai != kCGImageAlphaNoneSkipLast;
    NSInteger ncomp = cs ? (NSInteger)CGColorSpaceGetNumberOfComponents(cs) : 0;
    _spp = ncomp + (hasAlpha ? 1 : 0);
    _bpp = (NSInteger)CGImageGetBitsPerPixel(image);
    _bpr = (NSInteger)CGImageGetBytesPerRow(image);
    size_t bpc = CGImageGetBitsPerComponent(image);
    CGBitmapInfo bi = CGImageGetBitmapInfo(image);
    NSBitmapFormat f = 0;
    if (ai == kCGImageAlphaFirst || ai == kCGImageAlphaPremultipliedFirst || ai == kCGImageAlphaNoneSkipFirst)
        f |= NSBitmapFormatAlphaFirst;
    if (ai == kCGImageAlphaFirst || ai == kCGImageAlphaLast)
        f |= NSBitmapFormatAlphaNonpremultiplied;
    if (bi & kCGBitmapFloatComponents)
        f |= NSBitmapFormatFloatingPointSamples;
    CGBitmapInfo order = bi & kCGBitmapByteOrderMask;
    if (bpc == 8 && order == kCGBitmapByteOrder32Little)
        f |= NSBitmapFormatThirtyTwoBitLittleEndian;
    if (bpc == 16 && order != kCGBitmapByteOrder16Little)
        f |= NSBitmapFormatSixteenBitBigEndian;
    if (bpc == 32 && order != kCGBitmapByteOrder32Little)
        f |= NSBitmapFormatThirtyTwoBitBigEndian;
    _format = f;
    [self setPixelsWide:(NSInteger)w];
    [self setPixelsHigh:(NSInteger)h];
    [self setSize:NSMakeSize(w, h)];
    [self setBitsPerSample:(NSInteger)bpc];
    [self setAlpha:hasAlpha];
    [self setOpaque:!hasAlpha];
    [self setColorSpaceName:name_for_space(_space)];
}

- (instancetype)initWithCGImage:(CGImageRef)cgImage
{
    if (!cgImage) {
        [self release];
        return nil;
    }
    if ((self = [super init]))
        [self _adoptCGImage:cgImage];
    return self;
}

- (instancetype)initWithCIImage:(CIImage *)ciImage
{
    [self release];
    return nil;
}

- (instancetype)initWithFocusedViewRect:(NSRect)rect
{
    [self release];
    return nil;
}

static NSSize
dpi_size(CFDictionaryRef props, size_t w, size_t h)
{
    NSDictionary *p = (NSDictionary *)props;
    double dx = [p[(id)kCGImagePropertyDPIWidth] doubleValue], dy = [p[(id)kCGImagePropertyDPIHeight] doubleValue];
    return NSMakeSize(dx > 0 ? w * 72.0 / dx : w, dy > 0 ? h * 72.0 / dy : h);
}

- (instancetype)_initWithSource:(CGImageSourceRef)src index:(size_t)i
{
    CGImageRef im = CGImageSourceCreateImageAtIndex(src, i, NULL);
    if (!im) {
        [self release];
        return nil;
    }
    self = [self initWithCGImage:im];
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, i, NULL);
    if (props) {
        [self setSize:dpi_size(props, CGImageGetWidth(im), CGImageGetHeight(im))];
        CFRelease(props);
    }
    size_t count = CGImageSourceGetCount(src);
    if (count > 1) {
        _properties = [[NSMutableDictionary alloc] init];
        _properties[NSImageFrameCount] = @(count);
        _properties[NSImageCurrentFrame] = @(i);
    }
    CGImageRelease(im);
    return self;
}

- (instancetype)initWithData:(NSData *)data
{
    CGImageSourceRef src = data ? CGImageSourceCreateWithData((CFDataRef)data, NULL) : NULL;
    if (!src || !CGImageSourceGetCount(src)) {
        if (src)
            CFRelease(src);
        [self release];
        return nil;
    }
    self = [self _initWithSource:src index:0];
    CFRelease(src);
    return self;
}

+ (instancetype)imageRepWithData:(NSData *)data
{
    return [[[self alloc] initWithData:data] autorelease];
}

+ (NSArray<NSImageRep *> *)imageRepsWithData:(NSData *)data
{
    CGImageSourceRef src = data ? CGImageSourceCreateWithData((CFDataRef)data, NULL) : NULL;
    if (!src)
        return nil;
    NSMutableArray *a = [NSMutableArray array];
    for (size_t i = 0; i < CGImageSourceGetCount(src); i++) {
        NSBitmapImageRep *r = [[self alloc] _initWithSource:src index:i];
        if (r)
            [a addObject:r];
        [r release];
    }
    CFRelease(src);
    return a.count ? a : nil;
}

+ (BOOL)canInitWithData:(NSData *)data
{
    CGImageSourceRef src = data ? CGImageSourceCreateWithData((CFDataRef)data, NULL) : NULL;
    if (!src)
        return NO;
    BOOL ok = CGImageSourceGetType(src) != NULL;
    CFRelease(src);
    return ok;
}

+ (NSArray<NSString *> *)imageUnfilteredTypes
{
    CFArrayRef a = CGImageSourceCopyTypeIdentifiers();
    return [(NSArray *)a autorelease] ?: @[];
}

+ (NSArray<NSString *> *)imageUnfilteredFileTypes
{
    NSMutableArray *exts = [NSMutableArray array];
    NSDictionary *map = @{
        @"public.png": @[ @"png", @"PNG" ],
        @"public.jpeg": @[ @"jpg", @"jpeg", @"jpe", @"JPG", @"JPEG" ],
        @"com.compuserve.gif": @[ @"gif", @"GIF" ],
        @"com.microsoft.bmp": @[ @"bmp", @"BMP" ],
        @"public.tiff": @[ @"tiff", @"tif", @"TIFF", @"TIF" ],
        @"org.webmproject.webp": @[ @"webp" ],
        @"com.microsoft.ico": @[ @"ico" ],
        @"public.heic": @[ @"heic" ],
    };
    for (NSString *t in [self imageUnfilteredTypes])
        [exts addObjectsFromArray:map[t] ?: @[]];
    return exts;
}

- (instancetype)initForIncrementalLoad
{
    if ((self = [super init])) {
        _incremental = CGImageSourceCreateIncremental(NULL);
        _incrementalData = [[NSMutableData alloc] init];
    }
    return self;
}

- (NSInteger)incrementalLoadFromData:(NSData *)data complete:(BOOL)complete
{
    if (!_incremental)
        return NSImageRepLoadStatusInvalidData;
    [_incrementalData setData:data];
    CGImageSourceUpdateData(_incremental, (CFDataRef)_incrementalData, complete);
    if (!complete)
        return CGImageSourceGetType(_incremental) ? NSImageRepLoadStatusWillNeedAllData : NSImageRepLoadStatusUnknownType;
    CGImageRef im = CGImageSourceCreateImageAtIndex(_incremental, 0, NULL);
    if (!im)
        return NSImageRepLoadStatusInvalidData;
    [self _adoptCGImage:im];
    CGImageRelease(im);
    return NSImageRepLoadStatusCompleted;
}

- (void)dealloc
{
    [_owned release];
    [_space release];
    CGImageRelease(_image);
    [_properties release];
    if (_incremental)
        CFRelease(_incremental);
    [_incrementalData release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSBitmapImageRep *r = [super copyWithZone:zone];
    [r->_space retain];
    r->_properties = [_properties mutableCopy];
    r->_incremental = NULL;
    r->_incrementalData = nil;
    r->_drawnInto = NO;
    if (_loaded) {
        NSInteger nplanes = _planar ? _spp : 1, h = [self pixelsHigh];
        r->_owned = [[NSMutableData alloc] initWithLength:(NSUInteger)(_bpr * h * nplanes)];
        for (NSInteger i = 0; i < nplanes; i++) {
            r->_planes[i] = (unsigned char *)r->_owned.mutableBytes + i * _bpr * h;
            memcpy(r->_planes[i], _planes[i], (size_t)(_bpr * h));
        }
        r->_image = NULL;
    } else {
        r->_owned = nil;
        CGImageRetain(r->_image);
    }
    return r;
}

/* MARK: Pixels */

/* A CGImage-backed rep's pixels, copied out of the image in its own layout. */
- (void)_load
{
    if (_loaded || !_image)
        return;
    CGDataProviderRef p = CGImageGetDataProvider(_image);
    CFDataRef d = p ? CGDataProviderCopyData(p) : NULL;
    NSInteger h = [self pixelsHigh];
    _owned = [[NSMutableData alloc] initWithLength:(NSUInteger)(_bpr * h)];
    if (d) {
        memcpy(_owned.mutableBytes, CFDataGetBytePtr(d), MIN((size_t)CFDataGetLength(d), _owned.length));
        CFRelease(d);
    }
    _planes[0] = _owned.mutableBytes;
    _planar = NO;
    _loaded = YES;
    [self _finchInvalidateImage];
}

- (void)_finchInvalidateImage
{
    if (_loaded && _image) {
        CGImageRelease(_image);
        _image = NULL;
    }
}

- (unsigned char *)bitmapData
{
    [self _load];
    [self _finchInvalidateImage];
    return _planes[0];
}

- (void)getBitmapDataPlanes:(unsigned char **)data
{
    [self _load];
    [self _finchInvalidateImage];
    for (int i = 0; i < 5; i++)
        data[i] = i < (_planar ? _spp : 1) ? _planes[i] : NULL;
}

- (BOOL)isPlanar { return _planar; }
- (NSInteger)samplesPerPixel { return _spp; }
- (NSInteger)bitsPerPixel { return _bpp; }
- (NSInteger)bytesPerRow { return _bpr; }
- (NSInteger)bytesPerPlane { return _bpr * [self pixelsHigh]; }
- (NSInteger)numberOfPlanes { return _planar ? _spp : 1; }
- (NSBitmapFormat)bitmapFormat { return _format; }
- (NSColorSpace *)colorSpace { return _space; }

static NSUInteger
max_sample(NSInteger bps)
{
    return bps >= 32 ? 0xffffffffu : ((NSUInteger)1 << bps) - 1;
}

/* Sample s (in memory order) of pixel (x, y), raw. */
- (NSUInteger)_sample:(NSInteger)s x:(NSInteger)x y:(NSInteger)y
{
    NSInteger bps = [self bitsPerSample];
    unsigned char *base = _planar ? _planes[s] + y * _bpr : _planes[0] + y * _bpr;
    NSInteger bit = _planar ? x * bps : x * _bpp + s * bps;
    if (bps == 8) {
        NSInteger byte = bit / 8;
        if ((_format & NSBitmapFormatThirtyTwoBitLittleEndian) && _bpp == 32)
            byte = x * 4 + (3 - s);
        return base[byte];
    }
    if (bps == 16) {
        uint16_t v;
        memcpy(&v, base + bit / 8, 2);
        return (_format & NSBitmapFormatSixteenBitBigEndian) ? CFSwapInt16(v) : v;
    }
    if (bps == 32) {
        uint32_t v;
        memcpy(&v, base + bit / 8, 4);
        return (_format & NSBitmapFormatThirtyTwoBitBigEndian) ? CFSwapInt32(v) : v;
    }
    unsigned char b = base[bit / 8];
    return (b >> (8 - bps - bit % 8)) & max_sample(bps);
}

- (void)_setSample:(NSInteger)s x:(NSInteger)x y:(NSInteger)y value:(NSUInteger)v
{
    NSInteger bps = [self bitsPerSample];
    unsigned char *base = _planar ? _planes[s] + y * _bpr : _planes[0] + y * _bpr;
    NSInteger bit = _planar ? x * bps : x * _bpp + s * bps;
    if (bps == 8) {
        NSInteger byte = bit / 8;
        if ((_format & NSBitmapFormatThirtyTwoBitLittleEndian) && _bpp == 32)
            byte = x * 4 + (3 - s);
        base[byte] = (unsigned char)v;
    } else if (bps == 16) {
        uint16_t w = (uint16_t)v;
        if (_format & NSBitmapFormatSixteenBitBigEndian)
            w = CFSwapInt16(w);
        memcpy(base + bit / 8, &w, 2);
    } else if (bps == 32) {
        uint32_t w = (uint32_t)v;
        if (_format & NSBitmapFormatThirtyTwoBitBigEndian)
            w = CFSwapInt32(w);
        memcpy(base + bit / 8, &w, 4);
    } else {
        int shift = (int)(8 - bps - bit % 8);
        unsigned char mask = (unsigned char)(max_sample(bps) << shift);
        base[bit / 8] = (unsigned char)((base[bit / 8] & ~mask) | ((v << shift) & mask));
    }
}

- (BOOL)_inBounds:(NSInteger)x y:(NSInteger)y
{
    return x >= 0 && y >= 0 && x < [self pixelsWide] && y < [self pixelsHigh];
}

- (void)getPixel:(NSUInteger[])p atX:(NSInteger)x y:(NSInteger)y
{
    [self _load];
    if (![self _inBounds:x y:y])
        return;
    for (NSInteger s = 0; s < _spp; s++)
        p[s] = [self _sample:s x:x y:y];
}

- (void)setPixel:(NSUInteger[])p atX:(NSInteger)x y:(NSInteger)y
{
    [self _load];
    if (![self _inBounds:x y:y])
        return;
    for (NSInteger s = 0; s < _spp; s++)
        [self _setSample:s x:x y:y value:p[s]];
    [self _finchInvalidateImage];
}

/* A sample as a value in [0, 1]. */
- (double)_value:(NSUInteger)raw
{
    if (_format & NSBitmapFormatFloatingPointSamples) {
        if ([self bitsPerSample] == 32) {
            uint32_t u = (uint32_t)raw;
            float f;
            memcpy(&f, &u, 4);
            return f;
        }
        uint16_t h = (uint16_t)raw;
        __fp16 f;
        memcpy(&f, &h, 2);
        return f;
    }
    return (double)raw / max_sample([self bitsPerSample]);
}

- (NSUInteger)_raw:(double)v
{
    if (_format & NSBitmapFormatFloatingPointSamples) {
        if ([self bitsPerSample] == 32) {
            float f = (float)v;
            uint32_t u;
            memcpy(&u, &f, 4);
            return u;
        }
        __fp16 f = (__fp16)v;
        uint16_t h;
        memcpy(&h, &f, 2);
        return h;
    }
    v = v < 0 ? 0 : v > 1 ? 1 : v;
    return (NSUInteger)(v * max_sample([self bitsPerSample]));
}

- (NSColor *)colorAtX:(NSInteger)x y:(NSInteger)y
{
    [self _load];
    if (![self _inBounds:x y:y])
        return nil;
    BOOL alphaFirst = (_format & NSBitmapFormatAlphaFirst) != 0, hasAlpha = [self hasAlpha];
    BOOL premul = hasAlpha && !(_format & NSBitmapFormatAlphaNonpremultiplied);
    NSInteger ncomp = _spp - (hasAlpha ? 1 : 0), first = hasAlpha && alphaFirst ? 1 : 0;
    double a = 1;
    if (hasAlpha)
        a = [self _value:[self _sample:alphaFirst ? 0 : ncomp x:x y:y]];
    CGFloat c[6];
    for (NSInteger i = 0; i < ncomp; i++) {
        double v = [self _value:[self _sample:first + i x:x y:y]];
        if (premul)
            v = a > 0 ? v / a : 0;
        c[i] = v;
    }
    c[ncomp] = a;
    NSString *name = [self colorSpaceName];
    if ([name isEqualToString:NSDeviceBlackColorSpace] || [name isEqualToString:NSCalibratedBlackColorSpace])
        c[0] = 1 - c[0];
    if ([name isEqualToString:NSDeviceRGBColorSpace])
        return [NSColor colorWithDeviceRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
    if ([name isEqualToString:NSCalibratedRGBColorSpace])
        return [NSColor colorWithCalibratedRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
    if (([name isEqualToString:NSDeviceWhiteColorSpace] || [name isEqualToString:NSDeviceBlackColorSpace]) && [self bitsPerSample] >= 8)
        return [NSColor colorWithDeviceWhite:c[0] alpha:c[1]];  /* (Apple's reads fewer bits as calibrated) */
    if ([name isEqualToString:NSCalibratedWhiteColorSpace] || [name isEqualToString:NSCalibratedBlackColorSpace] ||
        [name isEqualToString:NSDeviceWhiteColorSpace] || [name isEqualToString:NSDeviceBlackColorSpace])
        return [NSColor colorWithCalibratedWhite:c[0] alpha:c[1]];
    if ([name isEqualToString:NSDeviceCMYKColorSpace])
        return [NSColor colorWithDeviceCyan:c[0] magenta:c[1] yellow:c[2] black:c[3] alpha:c[4]];
    return [NSColor colorWithColorSpace:_space components:c count:ncomp + 1];
}

- (void)setColor:(NSColor *)color atX:(NSInteger)x y:(NSInteger)y
{
    [self _load];
    if (![self _inBounds:x y:y])
        return;
    NSString *name = [self colorSpaceName];
    BOOL black = [name isEqualToString:NSDeviceBlackColorSpace] || [name isEqualToString:NSCalibratedBlackColorSpace];
    NSColor *c = black ? [color colorUsingColorSpaceName:[name isEqualToString:NSDeviceBlackColorSpace] ? NSDeviceWhiteColorSpace
                                                                                                       : NSCalibratedWhiteColorSpace]
                       : [name isEqualToString:NSCustomColorSpace] ? [color colorUsingColorSpace:_space]
                                                                    : [color colorUsingColorSpaceName:name];
    if (!c || c.type != NSColorTypeComponentBased)
        return;
    CGFloat comps[6];
    NSInteger n = c.numberOfComponents;
    [c getComponents:comps];
    if (black)
        comps[0] = 1 - comps[0];
    BOOL alphaFirst = (_format & NSBitmapFormatAlphaFirst) != 0, hasAlpha = [self hasAlpha];
    BOOL premul = hasAlpha && !(_format & NSBitmapFormatAlphaNonpremultiplied);
    NSInteger ncomp = _spp - (hasAlpha ? 1 : 0), first = hasAlpha && alphaFirst ? 1 : 0;
    double a = comps[n - 1];
    for (NSInteger i = 0; i < ncomp && i < n - 1; i++)
        [self _setSample:first + i x:x y:y value:[self _raw:premul ? comps[i] * a : comps[i]]];
    if (hasAlpha)
        [self _setSample:alphaFirst ? 0 : ncomp x:x y:y value:[self _raw:a]];
    [self _finchInvalidateImage];
}

/* MARK: CoreGraphics */

static CGBitmapInfo
bitmap_info(NSBitmapFormat f, NSInteger bps, NSInteger bpp, NSInteger spp, BOOL hasAlpha)
{
    uint32_t bi;
    BOOL first = (f & NSBitmapFormatAlphaFirst) != 0, nonpremul = (f & NSBitmapFormatAlphaNonpremultiplied) != 0;
    if (hasAlpha)
        bi = first ? (nonpremul ? kCGImageAlphaFirst : kCGImageAlphaPremultipliedFirst)
                   : (nonpremul ? kCGImageAlphaLast : kCGImageAlphaPremultipliedLast);
    else if (bpp > bps * spp)
        bi = first ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaNoneSkipLast;
    else
        bi = kCGImageAlphaNone;
    if (f & NSBitmapFormatFloatingPointSamples)
        bi |= kCGBitmapFloatComponents;
    if (bps == 8 && bpp == 32 && (f & NSBitmapFormatThirtyTwoBitLittleEndian))
        bi |= kCGBitmapByteOrder32Little;
    else if (bps == 16)
        bi |= (f & NSBitmapFormatSixteenBitBigEndian) ? kCGBitmapByteOrder16Big : kCGBitmapByteOrder16Little;
    else if (bps == 32)
        bi |= (f & NSBitmapFormatThirtyTwoBitBigEndian) ? kCGBitmapByteOrder32Big : kCGBitmapByteOrder32Little;
    return (CGBitmapInfo)bi;
}

- (CGBitmapInfo)_bitmapInfo
{
    return bitmap_info(_format, [self bitsPerSample], _planar ? [self bitsPerSample] * _spp : _bpp, _spp, [self hasAlpha]);
}

static void
release_data(void *info, const void *data, size_t size)
{
    [(id)info release];
}

/* The pixels as a CGImage (planar reps are meshed first, black spaces inverted). */
- (CGImageRef)_createImage
{
    NSInteger w = [self pixelsWide], h = [self pixelsHigh], bps = [self bitsPerSample];
    NSString *name = [self colorSpaceName];
    BOOL black = [name isEqualToString:NSDeviceBlackColorSpace] || [name isEqualToString:NSCalibratedBlackColorSpace];
    NSMutableData *copy;
    NSInteger bpr = _bpr, bpp = _bpp;
    if (_planar) {
        bpp = bps * _spp;
        bpr = (w * bpp + 7) / 8;
        copy = [[NSMutableData alloc] initWithLength:(NSUInteger)(bpr * h)];
        NSBitmapImageRep *meshed = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
            bitsPerSample:bps samplesPerPixel:_spp hasAlpha:[self hasAlpha] isPlanar:NO colorSpaceName:name
            bitmapFormat:_format bytesPerRow:bpr bitsPerPixel:bpp];
        for (NSInteger y = 0; y < h; y++)
            for (NSInteger x = 0; x < w; x++)
                for (NSInteger s = 0; s < _spp; s++)
                    [meshed _setSample:s x:x y:y value:[self _sample:s x:x y:y]];
        memcpy(copy.mutableBytes, meshed->_planes[0], (size_t)(bpr * h));
        [meshed release];
    } else {
        copy = [[NSMutableData alloc] initWithBytes:_planes[0] length:(NSUInteger)(_bpr * h)];
    }
    if (black && bps == 8) {
        unsigned char *b = copy.mutableBytes;
        for (NSInteger i = 0; i < bpr * h; i++)
            b[i] = 255 - b[i];
    }
    CGDataProviderRef p = CGDataProviderCreateWithData(copy, copy.bytes, copy.length, release_data);
    CGColorSpaceRef cs = _space.CGColorSpace;
    CGImageRef im = CGImageCreate((size_t)w, (size_t)h, (size_t)bps, (size_t)bpp, (size_t)bpr, cs,
                                  bitmap_info(_format, bps, bpp, _spp, [self hasAlpha]), p, NULL, true,
                                  kCGRenderingIntentDefault);
    CGDataProviderRelease(p);
    return im;
}

- (CGImageRef)CGImage
{
    if (!_loaded)
        return _image;
    if (_drawnInto) {
        CGImageRef im = [self _createImage];
        return (CGImageRef)[(id)im autorelease];
    }
    if (!_image)
        _image = [self _createImage];
    return _image;
}

- (CGImageRef)CGImageForProposedRect:(NSRect *)proposedDestRect context:(NSGraphicsContext *)context hints:(NSDictionary *)hints
{
    return [self CGImage];
}

/* What Apple's NSGraphicsContext can draw into: meshed, 8 bits or more, premultiplied, and a format CG has. */
- (CGContextRef)_finchCreateCGContext
{
    NSInteger bps = [self bitsPerSample];
    BOOL hasAlpha = [self hasAlpha];
    NSInteger ncomp = _spp - (hasAlpha ? 1 : 0);
    NSString *name = [self colorSpaceName];
    if (_planar || bps < 8 || (hasAlpha && (_format & NSBitmapFormatAlphaNonpremultiplied)))
        return NULL;
    if ([name isEqualToString:NSDeviceBlackColorSpace] || [name isEqualToString:NSCalibratedBlackColorSpace])
        return NULL;
    if (ncomp == 4 && hasAlpha)
        return NULL;
    if (ncomp == 3 && _bpp != 4 * bps)
        return NULL;
    [self _load];
    CGContextRef c = CGBitmapContextCreate(_planes[0], (size_t)[self pixelsWide], (size_t)[self pixelsHigh], (size_t)bps,
                                           (size_t)_bpr, _space.CGColorSpace, [self _bitmapInfo]);
    if (c) {
        _drawnInto = YES;
        [self _finchInvalidateImage];
        /* the rep's size may differ from its pixels: draw in its points */
        NSSize s = [self size];
        if (s.width > 0 && s.height > 0)
            CGContextScaleCTM(c, [self pixelsWide] / s.width, [self pixelsHigh] / s.height);
    }
    return c;
}

/* MARK: Drawing */

- (BOOL)draw
{
    NSSize s = [self size];
    return [self drawInRect:NSMakeRect(0, 0, s.width, s.height)];
}

- (BOOL)drawInRect:(NSRect)rect
{
    CGContextRef c = FinchCurrentCGContext();
    CGImageRef im = [self CGImage];
    if (!c || !im)
        return NO;
    /* a rep drawn on its own replaces what's under it, as Apple's (NSCompositingOperationCopy) */
    CGContextSaveGState(c);
    CGContextSetCompositeOperation(c, 1);
    CGContextDrawImage(c, NSRectToCGRect(rect), im);
    CGContextRestoreGState(c);
    return YES;
}

- (BOOL)drawInRect:(NSRect)dstSpacePortionRect fromRect:(NSRect)srcSpacePortionRect operation:(NSCompositingOperation)op
          fraction:(CGFloat)requestedAlpha respectFlipped:(BOOL)respectContextIsFlipped hints:(NSDictionary *)hints
{
    return FinchDrawCGImage([self CGImage], [self size], dstSpacePortionRect, srcSpacePortionRect, op, requestedAlpha,
                            respectContextIsFlipped, hints);
}

/* MARK: Converting */

- (NSBitmapImageRep *)bitmapImageRepByConvertingToColorSpace:(NSColorSpace *)targetSpace renderingIntent:(NSColorRenderingIntent)renderingIntent
{
    NSColorSpaceModel m = targetSpace.colorSpaceModel;
    if (!targetSpace.CGColorSpace || (m != NSColorSpaceModelRGB && m != NSColorSpaceModelGray && m != NSColorSpaceModelCMYK))
        return nil;
    if ([targetSpace isEqual:_space])
        return [[self retain] autorelease];
    NSInteger w = [self pixelsWide], h = [self pixelsHigh];
    BOOL cmyk = m == NSColorSpaceModelCMYK, gray = m == NSColorSpaceModelGray;
    /* Apple's drops alpha converting to gray (and CMYK has none) */
    NSInteger spp = cmyk ? 4 : gray ? 1 : 4;
    NSBitmapImageRep *r = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
        samplesPerPixel:spp hasAlpha:!cmyk && !gray isPlanar:NO colorSpaceName:cmyk ? NSDeviceCMYKColorSpace : gray ? NSCalibratedWhiteColorSpace : NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0] autorelease];
    [r->_space release];
    r->_space = [targetSpace retain];
    [r setColorSpaceName:name_for_space(targetSpace)];
    CGContextRef c = [r _finchCreateCGContext];
    if (!c)
        return nil;
    CGContextSetRenderingIntent(c, (CGColorRenderingIntent)renderingIntent);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), [self CGImage]);
    CGContextRelease(c);
    r->_drawnInto = NO;
    [r setSize:[self size]];
    return r;
}

- (NSBitmapImageRep *)bitmapImageRepByRetaggingWithColorSpace:(NSColorSpace *)newSpace
{
    if (newSpace.colorSpaceModel != _space.colorSpaceModel)
        return nil;
    if ([newSpace isEqual:_space])
        return [[self retain] autorelease];
    NSBitmapImageRep *r = [[self copy] autorelease];
    [r->_space release];
    r->_space = [newSpace retain];
    [r setColorSpaceName:name_for_space(newSpace)];
    if (!r->_loaded) {
        CGImageRef im = CGImageCreateCopyWithColorSpace(r->_image, newSpace.CGColorSpace);
        CGImageRelease(r->_image);
        r->_image = im;
    }
    return r;
}

- (void)colorizeByMappingGray:(CGFloat)midPoint toColor:(NSColor *)midPointColor blackMapping:(NSColor *)shadowColor whiteMapping:(NSColor *)lightColor
{
    /* Each pixel's gray level picks a colour between black-mid-white mappings. */
    NSInteger w = [self pixelsWide], h = [self pixelsHigh];
    for (NSInteger y = 0; y < h; y++)
        for (NSInteger x = 0; x < w; x++) {
            NSColor *c = [[self colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedWhiteColorSpace];
            if (!c)
                continue;
            CGFloat g = c.whiteComponent;
            NSColor *out = g < midPoint ? [shadowColor blendedColorWithFraction:midPoint > 0 ? g / midPoint : 1 ofColor:midPointColor]
                                        : [midPointColor blendedColorWithFraction:midPoint < 1 ? (g - midPoint) / (1 - midPoint) : 1
                                                                          ofColor:lightColor];
            if (out)
                [self setColor:[out colorWithAlphaComponent:c.alphaComponent] atX:x y:y];
        }
}

/* MARK: File formats */

- (NSData *)representationUsingType:(NSBitmapImageFileType)storageType properties:(NSDictionary<NSBitmapImageRepPropertyKey, id> *)properties
{
    return [NSBitmapImageRep representationOfImageRepsInArray:@[ self ] usingType:storageType properties:properties];
}

+ (NSData *)representationOfImageRepsInArray:(NSArray<NSImageRep *> *)imageReps usingType:(NSBitmapImageFileType)storageType
                                  properties:(NSDictionary<NSBitmapImageRepPropertyKey, id> *)properties
{
    NSString *uti = uti_for_type(storageType);
    if (!uti || !imageReps.count)
        return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef d = CGImageDestinationCreateWithData((CFMutableDataRef)out, (CFStringRef)uti, imageReps.count, NULL);
    if (!d)
        return nil;
    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    if (properties[NSImageCompressionFactor])
        opts[(id)kCGImageDestinationLossyCompressionQuality] = properties[NSImageCompressionFactor];
    if ([properties[NSImageInterlaced] boolValue])
        opts[(id)kCGImagePropertyPNGDictionary] = @{(id)kCGImagePropertyPNGInterlaceType: @1};
    if ([properties[NSImageProgressive] boolValue])
        opts[(id)kCGImagePropertyJFIFDictionary] = @{(id)kCGImagePropertyJFIFIsProgressive: @YES};
    NSColor *bg = properties[NSImageFallbackBackgroundColor];
    if (bg.CGColor)
        opts[(id)kCGImageDestinationBackgroundColor] = (id)bg.CGColor;
    BOOL added = NO;
    for (NSImageRep *r in imageReps) {
        CGImageRef im = [r CGImageForProposedRect:NULL context:nil hints:nil];
        if (!im)
            continue;
        CGImageDestinationAddImage(d, im, (CFDictionaryRef)opts);
        added = YES;
    }
    BOOL ok = added && CGImageDestinationFinalize(d);
    CFRelease(d);
    return ok && out.length ? out : nil;
}

- (NSData *)TIFFRepresentation
{
    return [self representationUsingType:NSBitmapImageFileTypeTIFF properties:@{}];
}

- (NSData *)TIFFRepresentationUsingCompression:(NSTIFFCompression)comp factor:(float)factor
{
    return [self representationUsingType:NSBitmapImageFileTypeTIFF properties:@{NSImageCompressionFactor: @(factor)}];
}

+ (NSData *)TIFFRepresentationOfImageRepsInArray:(NSArray<NSImageRep *> *)array
{
    return [self representationOfImageRepsInArray:array usingType:NSBitmapImageFileTypeTIFF properties:@{}];
}

+ (NSData *)TIFFRepresentationOfImageRepsInArray:(NSArray<NSImageRep *> *)array usingCompression:(NSTIFFCompression)comp factor:(float)factor
{
    return [self representationOfImageRepsInArray:array usingType:NSBitmapImageFileTypeTIFF properties:@{}];
}

+ (void)getTIFFCompressionTypes:(const NSTIFFCompression **)list count:(NSInteger *)numTypes
{
    static const NSTIFFCompression types[] = {NSTIFFCompressionNone, NSTIFFCompressionLZW, NSTIFFCompressionPackBits};
    *list = types;
    *numTypes = 3;
}

+ (NSString *)localizedNameForTIFFCompressionType:(NSTIFFCompression)compression
{
    switch (compression) {
    case NSTIFFCompressionNone: return @"No Compression";
    case NSTIFFCompressionLZW: return @"LZW Compression";
    case NSTIFFCompressionPackBits: return @"PackBits Compression";
    case NSTIFFCompressionCCITTFAX3: return @"CCITTFAX3 Compression";
    case NSTIFFCompressionCCITTFAX4: return @"CCITTFAX4 Compression";
    case NSTIFFCompressionJPEG: return @"JPEG Compression";
    default: return nil;
    }
}

- (BOOL)canBeCompressedUsing:(NSTIFFCompression)compression
{
    return compression == NSTIFFCompressionNone || compression == NSTIFFCompressionLZW || compression == NSTIFFCompressionPackBits;
}

- (void)getCompression:(NSTIFFCompression *)compression factor:(float *)factor
{
    if (compression)
        *compression = _compression ?: NSTIFFCompressionNone;
    if (factor)
        *factor = _factor;
}

- (void)setCompression:(NSTIFFCompression)compression factor:(float)factor
{
    _compression = compression;
    _factor = factor;
}

- (void)setProperty:(NSBitmapImageRepPropertyKey)property withValue:(id)value
{
    if (!_properties)
        _properties = [[NSMutableDictionary alloc] init];
    if (value)
        _properties[property] = value;
    else
        [_properties removeObjectForKey:property];
}

- (id)valueForProperty:(NSBitmapImageRepPropertyKey)property
{
    if ([property isEqualToString:NSImageColorSyncProfileData] && !_properties[property])
        return [_space ICCProfileData];
    return _properties[property];
}

- (NSString *)description
{
    NSSize s = [self size];
    return [NSString stringWithFormat:@"NSBitmapImageRep %p Size={%g, %g} ColorSpace=%@ BPS=%ld BPP=%ld Pixels=%ldx%ld Alpha=%@ Planar=%@ Format=%lu",
                                      self, s.width, s.height, _space, (long)[self bitsPerSample], (long)_bpp, (long)[self pixelsWide],
                                      (long)[self pixelsHigh], [self hasAlpha] ? @"YES" : @"NO", _planar ? @"YES" : @"NO",
                                      (unsigned long)_format];
}

/* MARK: NSCoding (Apple's key; the data is PNG where Apple's is TIFF, which -initWithData: reads either way) */

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSData *d = [self TIFFRepresentation] ?: [self representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (d)
        [coder encodeObject:d forKey:@"NSTIFFRepresentation"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSData *d = [coder decodeObjectOfClass:[NSData class] forKey:@"NSTIFFRepresentation"];
    return [self initWithData:d];
}

@end
