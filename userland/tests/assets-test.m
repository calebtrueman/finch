/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-assets-test: compiled asset catalogs. Runs as the executable of
 * AssetsTest.app, whose Resources hold Assets.car (actool's output for
 * assets-test.xcassets), the same catalog compiled for macOS 10.9 and 10.11
 * (uncompressed, RLE, zip and LZFSE bitmaps rather than deepmap2), a nib
 * using a named colour and image, and Extra.bundle with the catalog again.
 *
 * Prints, through CoreUI (CUICatalog and the named lookups, as apps that call
 * it directly see them): names, appearances, every image rendition (scale,
 * size, template mode, pixel format and a digest of the pixels), colours for
 * each appearance and gamut, data, lookup fallbacks, the PDF vector; through
 * AppKit: colorNamed: (dynamic catalog colours resolved per appearance,
 * archived, from a nib), imageNamed:/imageForResource: (sizes, reps, template,
 * the pixels drawn at 1x and 2x in light and dark) and NSDataAsset.
 *
 * Run it against Apple's frameworks and Finch's (DYLD_FRAMEWORK_PATH with
 * Frameworks and PrivateFrameworks, FINCH_FONT_DIRS) and diff all but the
 * first line, which says where CoreUI came from. The host's display may be
 * Display P3 and Finch's is sRGB, so the gamut-dependent colour only says
 * which of its renditions it resolved to.
 */
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/* CoreUI's API, as declared by Apple's private framework (the subset used here). */
@interface CUICatalog : NSObject
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error;
- (NSArray *)allImageNames;
- (NSArray *)appearanceNames;
- (NSArray *)imagesWithName:(NSString *)name;
- (BOOL)containsLookupForName:(NSString *)name;
- (BOOL)imageExistsWithName:(NSString *)name;
- (id)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale;
- (id)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut layoutDirection:(NSInteger)dir
     appearanceName:(NSString *)appearance;
- (id)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut deviceIdiom:(NSInteger)idiom appearanceName:(NSString *)appearance;
- (id)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut;
- (id)dataWithName:(NSString *)name;
- (id)namedVectorImageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut
               layoutDirection:(NSInteger)dir appearanceName:(NSString *)appearance;
- (CGPDFDocumentRef)pdfDocumentWithName:(NSString *)name;
@end

@interface CUINamedLookup : NSObject
@property (readonly) NSString *name;
@property (readonly) NSString *renditionName;
@property (readonly) NSString *appearance;
@property (readonly) CGFloat scale;
@property (readonly) NSInteger idiom;
@property (readonly) NSInteger displayGamut;
@end

@interface CUINamedImage : CUINamedLookup
@property (readonly) CGImageRef image;
@property (readonly) CGSize size;
@property (readonly) BOOL isTemplate;
@property (readonly) NSInteger templateRenderingMode;
@property (readonly) BOOL isVectorBased;
@property (readonly) NSInteger imageType;
@property (readonly) double opacity;
@property (readonly) int exifOrientation;
@end

@interface CUINamedColor : CUINamedLookup
@property (readonly) CGColorRef cgColor;
@property (readonly) NSString *systemColorName;
@end

@interface CUINamedData : CUINamedLookup
@property (readonly) NSData *data;
@property (readonly) NSString *utiType;
@end

@interface CUINamedVectorImage : CUINamedLookup
@property (readonly) CGPDFDocumentRef pdfDocument;
- (CGImageRef)rasterizeImageUsingScaleFactor:(CGFloat)scale forTargetSize:(CGSize)size;
@end

static void out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
out(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", [s UTF8String]);
}

static NSString *
digest(const void *bytes, size_t len)
{
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)len, md);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x", md[0], md[1], md[2], md[3], md[4], md[5]];
}

static NSString *
space_name(CGColorSpaceRef cs)
{
    NSString *n = cs ? CFBridgingRelease(CGColorSpaceCopyName(cs)) : nil;
    return n ?: @"(unnamed)";
}

/* A CGImage's format and its pixels' digest, row by row without padding. */
static NSString *
image_desc(CGImageRef im)
{
    if (!im)
        return @"no image";
    CFDataRef d = CGDataProviderCopyData(CGImageGetDataProvider(im));
    size_t w = CGImageGetWidth(im), h = CGImageGetHeight(im), bpr = CGImageGetBytesPerRow(im), bpp = CGImageGetBitsPerPixel(im);
    NSMutableData *rows = [NSMutableData data];
    for (size_t y = 0; d && y < h; y++)
        [rows appendBytes:CFDataGetBytePtr(d) + y * bpr length:w * bpp / 8];
    if (d)
        CFRelease(d);
    return [NSString stringWithFormat:@"%zux%zu bpc %zu bpp %zu info 0x%x %@ pixels %@", w, h, CGImageGetBitsPerComponent(im), bpp,
                                      CGImageGetBitmapInfo(im), space_name(CGImageGetColorSpace(im)), digest(rows.bytes, rows.length)];
}

static NSString *
cgcolor_desc(CGColorRef c)
{
    if (!c)
        return @"nil";
    NSMutableString *s = [NSMutableString stringWithString:space_name(CGColorGetColorSpace(c))];
    for (size_t i = 0; i < CGColorGetNumberOfComponents(c); i++)
        [s appendFormat:@" %.9g", CGColorGetComponents(c)[i]];
    return s;
}

/* MARK: - CoreUI */

static NSArray *appearances;

static void
test_coreui_catalog(NSString *title, CUICatalog *cat)
{
    out(@"%@: %@", title, cat ? @"opened" : @"nil");
    if (!cat)
        return;
    NSArray *names = [[cat allImageNames] sortedArrayUsingSelector:@selector(compare:)];
    out(@"  names: %@", [names componentsJoinedByString:@", "]);
    out(@"  appearances: %@", [[[cat appearanceNames] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]);
    for (NSString *n in names) {
        NSArray *imgs = [cat imagesWithName:n];
        for (id l in imgs) {
            if (![l isKindOfClass:NSClassFromString(@"CUINamedImage")]) {
                out(@"  %@: %s", n, class_getName([l class]));
                continue;
            }
            CUINamedImage *i = l;
            out(@"  %@: %s %@ @%gx %gx%g mode %ld template %d vector %d type %ld opacity %g exif %d: %@", n, class_getName([i class]),
                i.appearance, i.scale, i.size.width, i.size.height, (long)i.templateRenderingMode, i.isTemplate, i.isVectorBased,
                (long)i.imageType, i.opacity, i.exifOrientation, image_desc(i.image));
        }
        for (NSString *a in appearances)
            for (NSInteger g = 0; g < 2; g++) {
                CUINamedColor *c = [cat colorWithName:n displayGamut:g deviceIdiom:0 appearanceName:a];
                if (c)
                    out(@"  %@ colour %@ gamut %ld: %@%@%@", n, a, (long)g, cgcolor_desc(c.cgColor),
                        c.systemColorName ? @" system " : @"", c.systemColorName ?: @"");
            }
        CUINamedData *d = [cat dataWithName:n];
        if (d)
            out(@"  %@ data: %@ %lu bytes %@", n, d.utiType, (unsigned long)d.data.length, digest(d.data.bytes, d.data.length));
    }
    /* lookups: scales past what's there, appearances the catalog lacks or doesn't list */
    for (NSString *n in @[ @"Dot", @"Glyph", @"Gradient", @"Shape", @"Notes", @"Missing" ])
        for (NSString *a in @[ @"", @"NSAppearanceNameAqua", @"NSAppearanceNameDarkAqua", @"Bogus" ])
            for (NSNumber *s in @[ @1, @2, @3 ]) {
                CUINamedImage *i = [cat imageWithName:n scaleFactor:s.doubleValue displayGamut:0 layoutDirection:0
                                       appearanceName:a.length ? a : nil];
                out(@"  lookup %@ %@ @%@: %@", n, a.length ? a : @"(none)", s,
                    i ? [NSString stringWithFormat:@"%@ @%gx %@", i.appearance, i.scale, image_desc(i.image)] : @"nil");
            }
    for (NSString *n in @[ @"AccentRed", @"Vivid", @"Ink", @"Tint" ])
        for (NSString *a in @[ @"", @"NSAppearanceNameAqua", @"NSAppearanceNameVibrantDark", @"NSAppearanceNameAccessibilitySystem", @"Bogus" ]) {
            CUINamedColor *c = [cat colorWithName:n displayGamut:0 deviceIdiom:0 appearanceName:a.length ? a : nil];
            out(@"  colour lookup %@ %@: %@", n, a.length ? a : @"(none)", c ? cgcolor_desc(c.cgColor) : @"nil");
        }
    out(@"  contains Dot %d Missing %d; image exists Dot %d Notes %d", [cat containsLookupForName:@"Dot"],
        [cat containsLookupForName:@"Missing"], [cat imageExistsWithName:@"Dot"], [cat imageExistsWithName:@"Notes"]);
    CUINamedVectorImage *v = [cat namedVectorImageWithName:@"Shape" scaleFactor:1 displayGamut:0 layoutDirection:0 appearanceName:nil];
    CGPDFDocumentRef doc = v.pdfDocument;
    CGPDFPageRef page = doc ? CGPDFDocumentGetPage(doc, 1) : NULL;
    CGRect box = page ? CGPDFPageGetBoxRect(page, kCGPDFMediaBox) : CGRectZero;
    out(@"  vector Shape: %s pages %zu box %@", v ? class_getName([v class]) : "nil", doc ? CGPDFDocumentGetNumberOfPages(doc) : 0,
        NSStringFromRect(NSRectFromCGRect(box)));
    out(@"  pdfDocumentWithName Shape: %s, Dot: %s", [cat pdfDocumentWithName:@"Shape"] ? "yes" : "no",
        [cat pdfDocumentWithName:@"Dot"] ? "yes" : "no");
}

/* MARK: - AppKit */

/* Pixels of a drawing: an image drawn at its size into a scale x context in an appearance. */
static NSString *
drawn(NSImage *image, CGFloat scale, NSAppearanceName appearance)
{
    NSSize s = image.size;
    size_t w = (size_t)ceil(s.width * scale), h = (size_t)ceil(s.height * scale);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 4 * w, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextScaleCTM(c, scale, scale);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:c flipped:NO]];
    [[NSAppearance appearanceNamed:appearance] performAsCurrentDrawingAppearance:^{
        [image drawInRect:NSMakeRect(0, 0, s.width, s.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                 fraction:1];
    }];
    [NSGraphicsContext restoreGraphicsState];
    const uint8_t *p = CGBitmapContextGetData(c);
    NSMutableString *r = [NSMutableString stringWithFormat:@"%@", digest(p, 4 * w * h)];
    /* the corners and the middle */
    size_t pts[5][2] = {{0, 0}, {w - 1, 0}, {0, h - 1}, {w - 1, h - 1}, {w / 2, h / 2}};
    for (int i = 0; i < 5; i++) {
        const uint8_t *q = p + 4 * (pts[i][1] * w + pts[i][0]);
        [r appendFormat:@" %02x%02x%02x%02x", q[0], q[1], q[2], q[3]];
    }
    CGContextRelease(c);
    return r;
}

static void
show_image(NSString *title, NSImage *i)
{
    if (!i) {
        out(@"%@: nil", title);
        return;
    }
    NSMutableSet *px = [NSMutableSet set];  /* the bitmaps (Apple's also has a PDF rep for a vector; Finch has none yet) */
    NSInteger widest = 0;
    for (NSImageRep *r in i.representations)
        if (r.pixelsWide > 0) {
            [px addObject:[NSString stringWithFormat:@"%ldx%ld", (long)r.pixelsWide, (long)r.pixelsHigh]];
            widest = MAX(widest, r.pixelsWide);
        }
    NSArray *sizes = [[px allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a compare:b options:NSNumericSearch];
    }];
    out(@"%@: size %@ template %d name %@ reps %@", title, NSStringFromSize(i.size), i.isTemplate, i.name,
        [sizes componentsJoinedByString:@" "]);
    /* at the scales it has bitmaps for (scaling them up is CoreGraphics' business, not the catalog's) */
    for (NSAppearanceName a in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ])
        for (NSNumber *s in @[ @1, @2 ])
            if (s.doubleValue * i.size.width <= widest)
                out(@"  drawn @%@x %@: %@", s, a, drawn(i, s.doubleValue, a));
}

static void
show_color(NSString *title, NSColor *c)
{
    if (!c) {
        out(@"%@: nil", title);
        return;
    }
    out(@"%@: %s %@", title, class_getName([c class]), c);
    out(@"  type %ld space %@ catalog %@ name %@", (long)c.type, c.colorSpaceName, c.catalogNameComponent, c.colorNameComponent);
    for (NSAppearanceName a in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua, NSAppearanceNameVibrantLight,
                                  NSAppearanceNameVibrantDark, NSAppearanceNameAccessibilityHighContrastDarkAqua ])
        [[NSAppearance appearanceNamed:a] performAsCurrentDrawingAppearance:^{
            NSColor *r = [c colorUsingType:NSColorTypeComponentBased];
            out(@"  %@: %@ | %@ | alpha %g", a, r, cgcolor_desc(c.CGColor), c.alphaComponent);
        }];
}

static void
test_appkit(void)
{
    NSBundle *main = [NSBundle mainBundle];
    NSBundle *extra = [NSBundle bundleWithPath:[main pathForResource:@"Extra" ofType:@"bundle"]];

    out(@"colours");
    for (NSString *n in @[ @"AccentRed", @"Paper", @"Ink", @"Folder/Nested" ])
        show_color(n, [NSColor colorNamed:n]);
    show_color(@"AccentRed in Extra.bundle", [NSColor colorNamed:@"AccentRed" bundle:extra]);
    show_color(@"Missing", [NSColor colorNamed:@"Missing"]);
    show_color(@"Dot (an image)", [NSColor colorNamed:@"Dot"]);
    /* Vivid has sRGB and Display P3 renditions; the display decides */
    NSColor *vivid = [NSColor colorNamed:@"Vivid"];
    CUICatalog *cat = [[NSClassFromString(@"CUICatalog") alloc] initWithName:@"Assets" fromBundle:main error:NULL];
    BOOL either = NO;
    for (NSInteger g = 0; g < 2; g++)
        either |= CGColorEqualToColor(vivid.CGColor, [[cat colorWithName:@"Vivid" displayGamut:g] cgColor]);
    out(@"Vivid: %@, resolves to one of its gamut's renditions: %d", vivid, either);
    /* a system colour reference: the light appearance's (Finch's system colours aren't dynamic yet) */
    [[NSAppearance appearanceNamed:NSAppearanceNameAqua] performAsCurrentDrawingAppearance:^{
        NSColor *t = [NSColor colorNamed:@"Tint"];
        out(@"Tint: %@ resolves like systemOrangeColor: %d", t,
            CGColorEqualToColor(t.CGColor, [NSColor systemOrangeColor].CGColor));
    }];

    NSColor *red = [NSColor colorNamed:@"AccentRed"];
    out(@"equal to another lookup %d, hash equal %d, equal to Paper %d", [red isEqual:[NSColor colorNamed:@"AccentRed"]],
        red.hash == [NSColor colorNamed:@"AccentRed"].hash, [red isEqual:[NSColor colorNamed:@"Paper"]]);
    out(@"in sRGB %@; with alpha %@", [red colorUsingColorSpace:[NSColorSpace sRGBColorSpace]], [red colorWithAlphaComponent:0.5]);
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:red requiringSecureCoding:NO error:NULL];
    NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:archive error:NULL];
    u.requiresSecureCoding = NO;
    NSColor *back = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    out(@"archived and back: %s %@ equal %d", class_getName([back class]), back, [back isEqual:red]);
    NSColor *fallback = [NSColor colorWithCatalogName:@"#$assets-mainBundleID" colorName:@"Paper"];
    out(@"colorWithCatalogName #$assets-mainBundleID Paper: %@", fallback);

    out(@"nib");
    NSNib *nib = [[NSNib alloc] initWithNibNamed:@"AssetsTest" bundle:main];
    NSArray *objs = nil;
    [nib instantiateWithOwner:nil topLevelObjects:&objs];
    objs = [objs sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [NSStringFromClass([a class]) compare:NSStringFromClass([b class])];
    }];
    for (id o in objs) {
        if ([o isKindOfClass:[NSTextField class]]) {
            show_color(@"text field textColor", [o textColor]);
            out(@"  backgroundColor %@", [o backgroundColor]);
        } else if ([o isKindOfClass:[NSImageView class]])
            show_image(@"image view image", [o image]);
    }

    out(@"images");
    for (NSString *n in @[ @"Dot", @"Glyph", @"Gradient", @"Shape", @"Missing", @"AccentRed", @"Notes" ])
        show_image([@"imageNamed " stringByAppendingString:n], [NSImage imageNamed:n]);
    out(@"imageNamed Dot again is the same image: %d", [NSImage imageNamed:@"Dot"] == [NSImage imageNamed:@"Dot"]);
    show_image(@"Extra.bundle imageForResource Glyph", [extra imageForResource:@"Glyph"]);
    show_image(@"main imageForResource Dot", [main imageForResource:@"Dot"]);

    out(@"data");
    for (NSString *n in @[ @"Notes", @"Blob", @"Missing", @"Dot" ]) {
        NSDataAsset *d = [[NSDataAsset alloc] initWithName:n];
        if (!d) {
            out(@"%@: nil", n);
            continue;
        }
        out(@"%@: name %@ type %@ %lu bytes %@", n, d.name, d.typeIdentifier, (unsigned long)d.data.length,
            digest(d.data.bytes, d.data.length));
        if ([d.typeIdentifier isEqualToString:@"public.plain-text"])
            out(@"  \"%@\"", [[[NSString alloc] initWithData:d.data encoding:NSUTF8StringEncoding]
                                 stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]);
    }
    NSDataAsset *ed = [[NSDataAsset alloc] initWithName:@"Blob" bundle:extra];
    out(@"Blob in Extra.bundle: %lu bytes", (unsigned long)ed.data.length);
}

int
main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    @autoreleasepool {
        Dl_info info;
        Class c = NSClassFromString(@"CUICatalog");
        out(@"CoreUI: %s", c && dladdr((__bridge void *)c, &info) ? info.dli_fname : "(not loaded)");
        appearances = @[ @"NSAppearanceNameSystem", @"NSAppearanceNameDarkAqua", @"NSAppearanceNameAccessibilitySystem" ];
        NSBundle *main = [NSBundle mainBundle];
        test_coreui_catalog(@"Assets.car", [[c alloc] initWithName:@"Assets" fromBundle:main error:NULL]);
        for (NSString *legacy in @[ @"Assets-10.9", @"Assets-10.11" ])
            test_coreui_catalog([legacy stringByAppendingString:@".car"],
                                [[c alloc] initWithURL:[main URLForResource:legacy withExtension:@"car"] error:NULL]);
        NSError *e = nil;
        id none = [[c alloc] initWithURL:[NSURL fileURLWithPath:@"/nonexistent/Assets.car"] error:&e];
        out(@"missing catalog: %@, error %d", none, e != nil);
        test_appkit();
    }
    return 0;
}
