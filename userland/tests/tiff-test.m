/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-tiff-test: TIFF through NSBitmapImageRep, NSImage and ImageIO, one
 * result per line so runs against Apple's frameworks and Finch's can be
 * diffed. It prints the bytes (or, for big files, a checksum) of TIFFs written
 * uncompressed, with LZW and with PackBits, 8- and 16-bit, gray, at another
 * resolution and with several images, then reads each back and prints its
 * properties, its CGImage's layout and its first pixels.
 */
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <zlib.h>

static NSBitmapImageRep *
rep(int w, int h, int spp, BOOL alpha, int bps)
{
    NSBitmapImageRep *r = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:bps
        samplesPerPixel:spp hasAlpha:alpha isPlanar:NO colorSpaceName:spp >= 3 ? NSDeviceRGBColorSpace : NSDeviceWhiteColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    unsigned char *p = r.bitmapData;
    for (long i = 0; i < r.bytesPerRow * h; i++) p[i] = (unsigned char)(i * 37 % 251);
    if (alpha && bps == 8) /* keep it premultiplied: colour no more than alpha */
        for (long i = 0; i < r.bytesPerRow * h; i += spp)
            for (int c = 0; c < spp - 1; c++) if (p[i + c] > p[i + spp - 1]) p[i + c] = p[i + spp - 1];
    return r;
}

static void
show_bytes(const char *label, NSData *d)
{
    printf("%s: %lu bytes", label, (unsigned long)d.length);
    if (d.length <= 400) {
        const uint8_t *b = d.bytes;
        printf(":");
        for (NSUInteger i = 0; i < d.length; i++) printf(" %02x", b[i]);
    } else {
        printf(", crc %08lx", crc32(0, d.bytes, (uInt)d.length));
    }
    printf("\n");
}

static void
show_read(const char *label, NSData *d)
{
    CGImageSourceRef s = CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL);
    if (!s) { printf("%s: no source\n", label); return; }
    size_t n = CGImageSourceGetCount(s);
    printf("%s: type %s, %zu images\n", label, [(__bridge NSString *)CGImageSourceGetType(s) UTF8String], n);
    for (size_t i = 0; i < n; i++) {
        NSDictionary *p = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(s, i, NULL));
        NSMutableArray *keys = [NSMutableArray array];
        for (NSString *k in [[p allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            id v = p[k];
            if ([v isKindOfClass:[NSDictionary class]]) {
                NSMutableArray *sub = [NSMutableArray array];
                for (NSString *sk in [[v allKeys] sortedArrayUsingSelector:@selector(compare:)]) [sub addObject:[NSString stringWithFormat:@"%@=%@", sk, v[sk]]];
                [keys addObject:[NSString stringWithFormat:@"%@{%@}", k, [sub componentsJoinedByString:@","]]];
            } else {
                [keys addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
            }
        }
        printf("  %zu: %s\n", i, [[keys componentsJoinedByString:@" "] UTF8String]);
        CGImageRef im = CGImageSourceCreateImageAtIndex(s, i, NULL);
        if (!im) { printf("  %zu: no image\n", i); continue; }
        CFStringRef space = CGColorSpaceCopyName(CGImageGetColorSpace(im));
        printf("  %zu: %zux%zu bpc %zu bpp %zu bpr %zu info 0x%x %s", i, CGImageGetWidth(im), CGImageGetHeight(im),
            CGImageGetBitsPerComponent(im), CGImageGetBitsPerPixel(im), CGImageGetBytesPerRow(im), CGImageGetBitmapInfo(im),
            space ? [(__bridge NSString *)space UTF8String] : "(no name)");
        if (space) CFRelease(space);
        CFDataRef px = CGDataProviderCopyData(CGImageGetDataProvider(im));
        const uint8_t *b = CFDataGetBytePtr(px);
        for (CFIndex k = 0; k < 16 && k < CFDataGetLength(px); k++) printf(" %02x", b[k]);
        printf(", crc %08lx\n", crc32(0, b, (uInt)CFDataGetLength(px)));
        CFRelease(px);
        CGImageRelease(im);
    }
    CFRelease(s);
}

int
main(void)
{
    @autoreleasepool {
        struct { const char *label; NSData *data; } files[] = {
            {"rgba", [rep(3, 2, 4, YES, 8) TIFFRepresentation]},
            {"rgb", [rep(3, 2, 3, NO, 8) TIFFRepresentation]},
            {"gray", [rep(3, 2, 1, NO, 8) TIFFRepresentation]},
            {"rgba 16-bit", [rep(3, 2, 4, YES, 16) TIFFRepresentation]},
            {"rgba LZW", [rep(3, 2, 4, YES, 8) TIFFRepresentationUsingCompression:NSTIFFCompressionLZW factor:0]},
            {"rgba PackBits", [rep(3, 2, 4, YES, 8) TIFFRepresentationUsingCompression:NSTIFFCompressionPackBits factor:0]},
            {"big", [rep(300, 200, 4, YES, 8) TIFFRepresentation]},
            {"big LZW", [rep(300, 200, 4, YES, 8) TIFFRepresentationUsingCompression:NSTIFFCompressionLZW factor:0]},
            {"big PackBits", [rep(300, 200, 3, NO, 8) TIFFRepresentationUsingCompression:NSTIFFCompressionPackBits factor:0]},
            {NULL, nil},
        };
        NSBitmapImageRep *r = rep(3, 2, 3, NO, 8);
        r.size = NSMakeSize(1.5, 1);
        NSData *dpi = [r TIFFRepresentation];
        NSImage *im = [[NSImage alloc] initWithSize:NSMakeSize(3, 2)];
        [im addRepresentation:rep(6, 4, 4, YES, 8)];
        [im addRepresentation:rep(3, 2, 4, YES, 8)];
        [im addRepresentation:rep(9, 6, 4, YES, 8)];
        NSData *multi = [im TIFFRepresentation];
        NSData *array = [NSBitmapImageRep TIFFRepresentationOfImageRepsInArray:@[rep(3, 2, 4, YES, 8), rep(6, 4, 4, YES, 8)]];
        NSMutableData *dest = [NSMutableData data];
        CGImageDestinationRef d = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)dest, CFSTR("public.tiff"), 1, NULL);
        CGImageDestinationAddImage(d, [rep(3, 2, 4, YES, 8) CGImage],
            (__bridge CFDictionaryRef)@{(id)kCGImagePropertyTIFFDictionary: @{(id)kCGImagePropertyTIFFCompression: @5}});
        CGImageDestinationFinalize(d);
        CFRelease(d);
        for (int i = 0; files[i].label; i++) show_bytes(files[i].label, files[i].data);
        show_bytes("144 dpi", dpi);
        show_bytes("NSImage, three reps", multi);
        show_bytes("array of reps", array);
        show_bytes("image destination, LZW", dest);
        for (int i = 0; files[i].label; i++) show_read(files[i].label, files[i].data);
        show_read("144 dpi", dpi);
        show_read("NSImage, three reps", multi);
        NSBitmapImageRep *back = [NSBitmapImageRep imageRepWithData:files[4].data];
        printf("bitmap from LZW: %ldx%ld spp %ld bps %ld alpha %d\n", (long)back.pixelsWide, (long)back.pixelsHigh,
            (long)back.samplesPerPixel, (long)back.bitsPerSample, back.hasAlpha);
        NSArray *reps = [NSBitmapImageRep imageRepsWithData:multi];
        printf("reps from multi:");
        for (NSImageRep *x in reps) printf(" %ldx%ld", (long)x.pixelsWide, (long)x.pixelsHigh);
        printf("\n");
    }
    return 0;
}
