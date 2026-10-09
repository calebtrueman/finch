/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-draw-test: AppKit's drawing classes (NSGraphicsContext,
 * NSColor, NSColorSpace, NSBezierPath, NSGradient, NSImage and its reps, the
 * NSGraphics.h functions). Prints their state deterministically, for diffing
 * runs against Apple's AppKit and Finch's, then draws scenes into bitmaps and
 * compares them with reference renders made by Apple's AppKit
 * (appkit-draw-reference.bin, written on macOS with --write), with
 * cg-draw-test's tolerances.
 *
 *   finch-appkit-draw-test [reference]
 *   finch-appkit-draw-test --write reference     (on macOS, against Apple's AppKit)
 *
 * The first line is the image NSColor came from; strip it before diffing.
 */
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <math.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <zlib.h>

/* A number rounded to 4 places, without "-0". */
static const char *
F(double v)
{
    static char bufs[16][32];
    static int n;
    char *b = bufs[n++ % 16];
    double r = round(v * 10000) / 10000;
    if (r == 0)
        r = 0;
    snprintf(b, 32, "%.4f", r);
    return b;
}

/* Descriptions without addresses. */
static NSString *
noaddr(NSString *s)
{
    return [s stringByReplacingOccurrencesOfString:@"0x[0-9a-f]+" withString:@"0x?" options:NSRegularExpressionSearch
                                             range:NSMakeRange(0, s.length)];
}

static const char *
S(id o)
{
    return o ? noaddr([o description]).UTF8String : "(nil)";
}

static void
header(const char *s)
{
    printf("== %s\n", s);
}

/* What raising does: "ok" or the exception's name and reason. */
#define TRY(label, ...)                                                                \
    do {                                                                                \
        @try {                                                                          \
            __VA_ARGS__;                                                                \
        } @catch (NSException * e) {                                                   \
            printf("%s: raised %s: %s\n", label, e.name.UTF8String, noaddr(e.reason).UTF8String); \
        }                                                                               \
    } while (0)

/* MARK: - Constants */

static void
constants(void)
{
    header("constants");
    NSString *names[] = {
        NSCalibratedWhiteColorSpace, NSCalibratedBlackColorSpace, NSCalibratedRGBColorSpace, NSDeviceWhiteColorSpace,
        NSDeviceBlackColorSpace, NSDeviceRGBColorSpace, NSDeviceCMYKColorSpace, NSNamedColorSpace, NSPatternColorSpace,
        NSCustomColorSpace, NSDeviceResolution, NSDeviceColorSpaceName, NSDeviceBitsPerSample, NSDeviceIsScreen,
        NSDeviceIsPrinter, NSDeviceSize, NSGraphicsContextDestinationAttributeName,
        NSGraphicsContextRepresentationFormatAttributeName, NSGraphicsContextPSFormat, NSGraphicsContextPDFFormat,
        NSImageHintCTM, NSImageHintInterpolation, NSImageHintUserInterfaceLayoutDirection, NSImageCompressionMethod,
        NSImageCompressionFactor, NSImageDitherTransparency, NSImageRGBColorTable, NSImageInterlaced,
        NSImageColorSyncProfileData, NSImageFrameCount, NSImageCurrentFrame, NSImageCurrentFrameDuration, NSImageLoopCount,
        NSImageGamma, NSImageProgressive, NSImageEXIFData, NSImageIPTCData, NSImageFallbackBackgroundColor,
        NSImageRepRegistryDidChangeNotification, NSSystemColorsDidChangeNotification, NSImageNameCaution,
        NSImageNameAddTemplate, NSImageNameTouchBarPlayTemplate, NSImageNameStatusAvailable, NSImageNameFolder,
        NSImageNameUserGuest, NSImageNameMenuOnStateTemplate, NSImageNameApplicationIcon,
    };
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++)
        printf("%s\n", names[i].UTF8String);
    printf("grays %g %g %g %g\n", NSWhite, NSLightGray, NSDarkGray, NSBlack);
}

/* MARK: - NSGraphicsContext */

static CGContextRef
rgba_context(size_t w, size_t h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    return c;
}

static void
graphics_context(void)
{
    header("NSGraphicsContext");
    printf("current at start %s\n", [NSGraphicsContext currentContext] ? "set" : "nil");
    CGContextRef c = rgba_context(10, 10);
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithCGContext:c flipped:YES];
    printf("kind %d attrs %s flipped %d screen %d cg %d port %d\n", [g isKindOfClass:[NSGraphicsContext class]], S(g.attributes),
           g.flipped, g.drawingToScreen, g.CGContext == c, g.graphicsPort == c);
    printf("interp %ld aa %d op %ld phase %s\n", (long)g.imageInterpolation, g.shouldAntialias, (long)g.compositingOperation,
           NSStringFromPoint(g.patternPhase).UTF8String);
    [NSGraphicsContext setCurrentContext:g];
    printf("current set %d toScreen %d\n", [NSGraphicsContext currentContext] == g, [NSGraphicsContext currentContextDrawingToScreen]);
    [NSGraphicsContext saveGraphicsState];
    printf("after save same %d\n", [NSGraphicsContext currentContext] == g);
    [NSGraphicsContext setCurrentContext:nil];
    printf("set nil %d\n", [NSGraphicsContext currentContext] == nil);
    [NSGraphicsContext restoreGraphicsState];
    printf("after restore same %d\n", [NSGraphicsContext currentContext] == g);
    g.compositingOperation = NSCompositingOperationCopy;
    g.shouldAntialias = NO;
    g.imageInterpolation = NSImageInterpolationHigh;
    printf("set: interp %ld cg %d aa %d op %ld\n", (long)g.imageInterpolation, (int)CGContextGetInterpolationQuality(c),
           g.shouldAntialias, (long)g.compositingOperation);
    [g saveGraphicsState];
    g.compositingOperation = NSCompositingOperationXOR;
    g.shouldAntialias = YES;
    g.imageInterpolation = NSImageInterpolationNone;
    printf("changed: op %ld aa %d interp %ld\n", (long)g.compositingOperation, g.shouldAntialias, (long)g.imageInterpolation);
    [g restoreGraphicsState];
    printf("restored: op %ld aa %d interp %ld\n", (long)g.compositingOperation, g.shouldAntialias, (long)g.imageInterpolation);
    CGContextSaveGState(c);
    g.compositingOperation = NSCompositingOperationDestinationOver;
    CGContextRestoreGState(c);
    printf("CG restore: op %ld\n", (long)g.compositingOperation);
    printf("ops:");
    for (long op = 0; op <= 29; op++) {
        @try {
            g.compositingOperation = (NSCompositingOperation)op;
            printf(" %ld->%ld", op, (long)g.compositingOperation);
        } @catch (NSException *e) {
            printf(" %ld:[%s %s]", op, e.name.UTF8String, e.reason.UTF8String);
        }
    }
    printf("\n");
    g.colorRenderingIntent = NSColorRenderingIntentPerceptual;
    printf("intent %ld\n", (long)g.colorRenderingIntent);
    g.patternPhase = NSMakePoint(3, 4);
    printf("phase %s\n", NSStringFromPoint(g.patternPhase).UTF8String);
    [g flushGraphics];

    NSBitmapImageRep *r = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:5 pixelsHigh:4 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    NSGraphicsContext *b = [NSGraphicsContext graphicsContextWithBitmapImageRep:r];
    CGContextRef bc = b.CGContext;
    CGAffineTransform t = CGContextGetCTM(bc);
    printf("bitmap: attrs %s flipped %d screen %d %zux%zu bpr %zu sameData %d info %x ctm %g %g %g %g %g %g\n", S(b.attributes),
           b.flipped, b.drawingToScreen, CGBitmapContextGetWidth(bc), CGBitmapContextGetHeight(bc), CGBitmapContextGetBytesPerRow(bc),
           CGBitmapContextGetData(bc) == r.bitmapData, CGBitmapContextGetBitmapInfo(bc), t.a, t.b, t.c, t.d, t.tx, t.ty);
    printf("bitmap: interp %ld aa %d op %ld\n", (long)b.imageInterpolation, b.shouldAntialias, (long)b.compositingOperation);
    NSGraphicsContext *a = [NSGraphicsContext graphicsContextWithAttributes:@{NSGraphicsContextDestinationAttributeName: r}];
    printf("from attributes %d flipped %d\n", a != nil, a.flipped);
    __block int other = -1;
    NSThread *th = [[[NSThread alloc] initWithBlock:^{ other = [NSGraphicsContext currentContext] != nil; }] autorelease];
    [th start];
    while (other < 0)
        usleep(1000);
    printf("other thread has a context %d\n", other);
    [NSGraphicsContext setCurrentContext:nil];
    CGContextRelease(c);
}

/* MARK: - NSColorSpace */

static void
archive_keys(id o, NSString *prefix)
{
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:o requiringSecureCoding:NO error:nil];
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil];
    NSArray *objs = plist[@"$objects"];
    NSDictionary *root = objs[1];
    printf("%s keys:", prefix.UTF8String);
    for (NSString *k in [[root allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([k isEqualToString:@"$class"])
            continue;
        id v = root[k];
        if ([v isKindOfClass:[NSNumber class]])
            printf(" %s=%s", k.UTF8String, [[v description] UTF8String]);
        else
            printf(" %s", k.UTF8String);
    }
    printf("\n");
}

static NSArray *
named_spaces(void)
{
    return @[
        NSColorSpace.genericRGBColorSpace, NSColorSpace.genericGrayColorSpace, NSColorSpace.genericCMYKColorSpace,
        NSColorSpace.deviceRGBColorSpace, NSColorSpace.deviceGrayColorSpace, NSColorSpace.deviceCMYKColorSpace,
        NSColorSpace.sRGBColorSpace, NSColorSpace.genericGamma22GrayColorSpace, NSColorSpace.extendedSRGBColorSpace,
        NSColorSpace.extendedGenericGamma22GrayColorSpace, NSColorSpace.displayP3ColorSpace, NSColorSpace.adobeRGB1998ColorSpace
    ];
}

static void
color_spaces(void)
{
    header("NSColorSpace");
    for (NSColorSpace *s in named_spaces()) {
        CFStringRef cgname = CGColorSpaceGetName(s.CGColorSpace);
        printf("%s: name [%s] model %ld n %ld cg %s cgmodel %d icc %d\n", S(s), s.localizedName.UTF8String, (long)s.colorSpaceModel,
               (long)s.numberOfColorComponents, cgname ? [(NSString *)cgname UTF8String] : "-",
               (int)CGColorSpaceGetModel(s.CGColorSpace), s.ICCProfileData.length > 0);
        archive_keys(s, @"  archive");
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:s requiringSecureCoding:YES error:nil];
        NSColorSpace *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColorSpace class] fromData:d error:nil];
        printf("  unarchived same %d equal %d\n", back == s, [back isEqual:s]);
        NSColorSpace *fromCG = [[[NSColorSpace alloc] initWithCGColorSpace:s.CGColorSpace] autorelease];
        printf("  from CG same %d\n", fromCG == s);
    }
    CFStringRef others[] = {kCGColorSpaceLinearSRGB, kCGColorSpaceDCIP3, kCGColorSpaceITUR_709, kCGColorSpaceGenericRGBLinear,
                            kCGColorSpaceLinearGray};
    for (unsigned i = 0; i < sizeof others / sizeof others[0]; i++) {
        CGColorSpaceRef cg = CGColorSpaceCreateWithName(others[i]);
        NSColorSpace *s = [[[NSColorSpace alloc] initWithCGColorSpace:cg] autorelease];
        printf("%s: %s model %ld n %ld\n", [(NSString *)others[i] UTF8String], S(s), (long)s.colorSpaceModel,
               (long)s.numberOfColorComponents);
        archive_keys(s, @"  archive");
        CGColorSpaceRelease(cg);
    }
    printf("p3 from its ICC equal %d\n",
           [[[[NSColorSpace alloc] initWithICCProfileData:NSColorSpace.displayP3ColorSpace.ICCProfileData] autorelease]
               isEqual:NSColorSpace.displayP3ColorSpace]);
    printf("srgb equal/hash %d %d, srgb vs device %d\n", [NSColorSpace.sRGBColorSpace isEqual:NSColorSpace.sRGBColorSpace],
           NSColorSpace.sRGBColorSpace.hash == NSColorSpace.sRGBColorSpace.hash,
           [NSColorSpace.sRGBColorSpace isEqual:NSColorSpace.deviceRGBColorSpace]);
    printf("models: unknown %ld gray %ld rgb %ld cmyk %ld lab %ld deviceN %ld indexed %ld pattern %ld\n",
           (long)NSColorSpaceModelUnknown, (long)NSColorSpaceModelGray, (long)NSColorSpaceModelRGB, (long)NSColorSpaceModelCMYK,
           (long)NSColorSpaceModelLAB, (long)NSColorSpaceModelDeviceN, (long)NSColorSpaceModelIndexed,
           (long)NSColorSpaceModelPatterned);
}

/* MARK: - NSColor */

static void
color_detail(const char *label, NSColor *c)
{
    printf("%s: [%s] type %ld csname %s alpha %s\n", label, S(c), (long)c.type, c.colorSpaceName.UTF8String, F(c.alphaComponent));
    TRY("  colorSpace", printf("  colorSpace %s n %ld\n", S(c.colorSpace), (long)c.numberOfComponents));
    TRY("  rgb", printf("  rgb %s %s %s\n", F(c.redComponent), F(c.greenComponent), F(c.blueComponent)));
    TRY("  hsb", printf("  hsb %s %s %s\n", F(c.hueComponent), F(c.saturationComponent), F(c.brightnessComponent)));
    TRY("  white", printf("  white %s\n", F(c.whiteComponent)));
    TRY("  cmyk", printf("  cmyk %s %s %s %s\n", F(c.cyanComponent), F(c.magentaComponent), F(c.yellowComponent), F(c.blackComponent)));
    TRY("  catalog", printf("  catalog %s %s\n", c.catalogNameComponent.UTF8String, c.colorNameComponent.UTF8String));
    TRY("  getRed", {
        CGFloat r, g, b, a;
        [c getRed:&r green:&g blue:&b alpha:&a];
        printf("  getRed %s %s %s %s\n", F(r), F(g), F(b), F(a));
    });
    TRY("  getWhite", {
        CGFloat w, a;
        [c getWhite:&w alpha:&a];
        printf("  getWhite %s %s\n", F(w), F(a));
    });
    CGColorRef cg = c.CGColor;
    if (cg) {
        CFStringRef n = CGColorSpaceGetName(CGColorGetColorSpace(cg));
        printf("  CGColor %s:", n ? [(NSString *)n UTF8String] : "-");
        for (size_t i = 0; i < CGColorGetNumberOfComponents(cg); i++)
            printf(" %s", F(CGColorGetComponents(cg)[i]));
        printf("\n");
    } else {
        printf("  CGColor NULL\n");
    }
}

static void
print_components(const char *label, NSColor *c)
{
    if (!c) {
        printf("%s: nil\n", label);
        return;
    }
    printf("%s: %s %s", label, c.colorSpaceName.UTF8String, c.type == NSColorTypeComponentBased ? S(c.colorSpace) : "-");
    if (c.type == NSColorTypeComponentBased) {
        CGFloat comps[8];
        [c getComponents:comps];
        for (NSInteger i = 0; i < c.numberOfComponents; i++)
            printf(" %s", F(comps[i]));
    }
    printf("\n");
}

static NSString *const system_names[] = {
    @"labelColor", @"secondaryLabelColor", @"tertiaryLabelColor", @"quaternaryLabelColor", @"linkColor",
    @"placeholderTextColor", @"windowFrameTextColor", @"selectedMenuItemTextColor", @"alternateSelectedControlTextColor",
    @"headerTextColor", @"separatorColor", @"gridColor", @"windowBackgroundColor", @"underPageBackgroundColor",
    @"controlBackgroundColor", @"selectedContentBackgroundColor", @"unemphasizedSelectedContentBackgroundColor",
    @"findHighlightColor", @"textColor", @"textBackgroundColor", @"selectedTextColor", @"selectedTextBackgroundColor",
    @"unemphasizedSelectedTextBackgroundColor", @"unemphasizedSelectedTextColor", @"controlColor", @"controlTextColor",
    @"selectedControlColor", @"selectedControlTextColor", @"disabledControlTextColor", @"keyboardFocusIndicatorColor",
    @"systemRedColor", @"systemGreenColor", @"systemBlueColor", @"systemOrangeColor", @"systemYellowColor",
    @"systemBrownColor", @"systemPinkColor", @"systemPurpleColor", @"systemGrayColor", @"systemTealColor",
    @"systemIndigoColor", @"systemMintColor", @"systemCyanColor", @"systemFillColor", @"secondarySystemFillColor",
    @"tertiarySystemFillColor", @"quaternarySystemFillColor", @"controlAccentColor", @"highlightColor", @"shadowColor",
    @"controlHighlightColor", @"controlLightHighlightColor", @"controlShadowColor", @"controlDarkShadowColor",
    @"scrollBarColor", @"knobColor", @"selectedKnobColor", @"windowFrameColor", @"selectedMenuItemColor", @"headerColor",
    @"secondarySelectedControlColor", @"alternateSelectedControlColor",
};

static void
archived_color(const char *label, NSColor *c)
{
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:c requiringSecureCoding:YES error:nil];
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil];
    NSDictionary *root = plist[@"$objects"][1];
    printf("%s archive:", label);
    for (NSString *k in [[root allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([k isEqualToString:@"$class"])
            continue;
        id v = root[k];
        if ([v isKindOfClass:[NSNumber class]])
            printf(" %s=%s", k.UTF8String, [[v description] UTF8String]);
        else if ([v isKindOfClass:[NSData class]]) {
            /* the exact strings, except the legacy fallbacks converted by ColorSync */
            NSString *s = [[[NSString alloc] initWithData:v encoding:NSASCIIStringEncoding] autorelease];
            BOOL converted = root[@"NSCustomColorSpace"] && ([k isEqualToString:@"NSRGB"] || [k isEqualToString:@"NSWhite"]);
            if (converted) {
                printf(" %s=(", k.UTF8String);
                for (NSString *n in [[s stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]] componentsSeparatedByString:@" "])
                    printf(" %s", F(n.doubleValue));
                printf(" )");
            } else
                printf(" %s=\"%s\"%lu", k.UTF8String, [s stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]].UTF8String,
                       (unsigned long)[v length]);
        } else
            printf(" %s", k.UTF8String);
    }
    NSColor *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:d error:nil];
    printf(" -> equal %d\n", [back isEqual:c]);
    print_components("  unarchived", back.type == NSColorTypeCatalog ? [back colorUsingType:NSColorTypeComponentBased] : back);
}

static void
colors(void)
{
    header("NSColor");
    NSImage *patternImage = [[[NSImage alloc] initWithSize:NSMakeSize(2, 2)] autorelease];
    struct {
        const char *label;
        NSColor *color;
    } cases[] = {
        {"sRGB", [NSColor colorWithSRGBRed:1 green:0.5 blue:0.25 alpha:0.75]},
        {"sRGB 255ths", [NSColor colorWithSRGBRed:0.2 green:0.4 blue:0.6 alpha:1]},
        {"device RGB", [NSColor colorWithDeviceRed:1 green:0.5 blue:0.25 alpha:1]},
        {"device RGB clamped", [NSColor colorWithDeviceRed:1.5 green:-1 blue:0.5 alpha:2]},
        {"device RGB 255ths", [NSColor colorWithDeviceRed:1 green:0 blue:0 alpha:1]},
        {"calibrated RGB", [NSColor colorWithCalibratedRed:1 green:0.5 blue:0.25 alpha:1]},
        {"generic RGB", [NSColor colorWithRed:0.123456 green:0.5 blue:0.25 alpha:1]},
        {"sRGB extended values", [NSColor colorWithSRGBRed:1.5 green:-1 blue:0.5 alpha:2]},
        {"P3", [NSColor colorWithDisplayP3Red:1 green:0.5 blue:0.25 alpha:1]},
        {"P3 255ths", [NSColor colorWithDisplayP3Red:1 green:0 blue:0 alpha:1]},
        {"gamma 2.2 white", [NSColor colorWithGenericGamma22White:0.5 alpha:1]},
        {"white", [NSColor colorWithWhite:0.123456 alpha:1]},
        {"white extended", [NSColor colorWithWhite:1.5 alpha:2]},
        {"device white", [NSColor colorWithDeviceWhite:0.2 alpha:0.6]},
        {"device white odd", [NSColor colorWithDeviceWhite:0.123456 alpha:1]},
        {"calibrated white", [NSColor colorWithCalibratedWhite:0.4 alpha:1]},
        {"HSB", [NSColor colorWithHue:0.5 saturation:0.5 brightness:0.5 alpha:1]},
        {"HSB out of range", [NSColor colorWithHue:1.5 saturation:2 brightness:0.5 alpha:1]},
        {"device HSB", [NSColor colorWithDeviceHue:1 saturation:1 brightness:1 alpha:1]},
        {"calibrated HSB", [NSColor colorWithCalibratedHue:0.25 saturation:0.5 brightness:0.8 alpha:1]},
        {"P3 HSB", [NSColor colorWithColorSpace:NSColorSpace.displayP3ColorSpace hue:0.5 saturation:0.5 brightness:0.5 alpha:1]},
        {"CMYK", [NSColor colorWithDeviceCyan:0.1 magenta:0.2 yellow:0.3 black:0.4 alpha:1]},
        {"CGColor generic", [NSColor colorWithCGColor:CGColorCreateGenericRGB(0.1, 0.2, 0.3, 1)]},
        {"CGColor gray", [NSColor colorWithCGColor:CGColorCreateGenericGray(0.1, 1)]},
        {"space components", [NSColor colorWithColorSpace:NSColorSpace.genericRGBColorSpace components:(CGFloat[]){0.1, 0.2, 0.3, 0.4} count:4]},
        {"space generic CMYK", [NSColor colorWithColorSpace:NSColorSpace.genericCMYKColorSpace components:(CGFloat[]){0.1, 0.2, 0.3, 0.4, 1} count:5]},
        {"space device gray", [NSColor colorWithColorSpace:NSColorSpace.deviceGrayColorSpace components:(CGFloat[]){0.5, 1} count:2]},
        {"black", NSColor.blackColor}, {"darkGray", NSColor.darkGrayColor}, {"lightGray", NSColor.lightGrayColor},
        {"white std", NSColor.whiteColor}, {"gray", NSColor.grayColor}, {"red", NSColor.redColor}, {"green", NSColor.greenColor},
        {"blue", NSColor.blueColor}, {"cyan", NSColor.cyanColor}, {"yellow", NSColor.yellowColor}, {"magenta", NSColor.magentaColor},
        {"orange", NSColor.orangeColor}, {"purple", NSColor.purpleColor}, {"brown", NSColor.brownColor}, {"clear", NSColor.clearColor},
        {"label", NSColor.labelColor}, {"catalog controlColor", [NSColor colorWithCatalogName:@"System" colorName:@"controlColor"]},
        {"pattern", [NSColor colorWithPatternImage:patternImage]},
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        if ([cases[i].color type] == NSColorTypePattern) {
            NSColor *c = cases[i].color;
            printf("%s: type %ld csname %s image same %d\n", cases[i].label, (long)c.type, c.colorSpaceName.UTF8String,
                   c.patternImage == patternImage);
            TRY("  colorSpace", printf("  colorSpace %s\n", S(c.colorSpace)));
            continue;
        }
        color_detail(cases[i].label, cases[i].color);
    }
    printf("missing catalog %s, other catalog %s, named %s\n", S([NSColor colorWithCatalogName:@"System" colorName:@"nonexistent"]),
           S([NSColor colorWithCatalogName:@"Crayons" colorName:@"Banana"]), S([NSColor colorNamed:@"nope"]));
    printf("catalog localized %s %s\n", NSColor.labelColor.localizedCatalogNameComponent.UTF8String,
           NSColor.labelColor.localizedColorNameComponent.UTF8String);
    TRY("hsb in gray space", [NSColor colorWithColorSpace:NSColorSpace.genericGrayColorSpace hue:0.5 saturation:0.5 brightness:0.5 alpha:1]);
    TRY("label numberOfComponents", (void)NSColor.labelColor.numberOfComponents);
    TRY("srgb patternImage", (void)[NSColor.redColor patternImage]);

    header("HSB");
    for (int k = 0; k <= 12; k++)
        print_components("hue", [NSColor colorWithHue:k / 12.0 saturation:0.8 brightness:0.9 alpha:1]);
    CGFloat h, s, b, a;
    [[NSColor colorWithSRGBRed:0.9 green:0.2 blue:0.5 alpha:1] getHue:&h saturation:&s brightness:&b alpha:&a];
    printf("getHue %s %s %s %s\n", F(h), F(s), F(b), F(a));
    [[NSColor colorWithSRGBRed:0.3 green:0.3 blue:0.3 alpha:1] getHue:&h saturation:&s brightness:&b alpha:&a];
    printf("gray getHue %s %s %s\n", F(h), F(s), F(b));

    header("system colours (sRGB, light)");
    /* (by name: Finch's AppKit may not have NSAppearance yet; its system colours are the light appearance's) */
    Class appearance = NSClassFromString(@"NSAppearance");
    void (^light)(void (^)(void)) = ^(void (^block)(void)) {
        id aqua = [appearance appearanceNamed:@"NSAppearanceNameAqua"];
        if ([aqua respondsToSelector:@selector(performAsCurrentDrawingAppearance:)])
            [aqua performAsCurrentDrawingAppearance:block];
        else
            block();
    };
    light(^{
        for (unsigned i = 0; i < sizeof system_names / sizeof system_names[0]; i++) {
            NSColor *c = [NSColor performSelector:NSSelectorFromString(system_names[i])];
            printf("%s [%s] ", system_names[i].UTF8String, S(c));
            print_components("", [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace]);
        }
    });
    printf("alternating %s\n", [[NSColor.alternatingContentBackgroundColors valueForKey:@"description"] componentsJoinedByString:@", "].UTF8String);
    printf("control alternating %s\n",
           [[NSColor.controlAlternatingRowBackgroundColors valueForKey:@"description"] componentsJoinedByString:@", "].UTF8String);

    header("conversions");
    NSArray *from = @[
        [NSColor colorWithWhite:0.2 alpha:1], [NSColor colorWithWhite:0.5 alpha:1], [NSColor colorWithCalibratedWhite:0.8 alpha:1],
        [NSColor colorWithDeviceWhite:0.5 alpha:1], [NSColor colorWithSRGBRed:0.2 green:0.1 blue:0.9 alpha:1],
        [NSColor colorWithSRGBRed:0.5 green:0.5 blue:0.5 alpha:0.5], [NSColor colorWithDeviceRed:0.8 green:0.1 blue:0.9 alpha:1],
        [NSColor colorWithCalibratedRed:0.5 green:0.1 blue:0.9 alpha:1], [NSColor colorWithDisplayP3Red:0.5 green:0.1 blue:0.9 alpha:1],
        NSColor.labelColor, NSColor.systemBlueColor
    ];
    NSArray *to = @[
        NSColorSpace.sRGBColorSpace, NSColorSpace.genericGamma22GrayColorSpace, NSColorSpace.genericGrayColorSpace,
        NSColorSpace.genericRGBColorSpace, NSColorSpace.deviceRGBColorSpace, NSColorSpace.displayP3ColorSpace
    ];
    for (NSColor *c in from) {
        printf("%s\n", S(c));
        for (NSColorSpace *s in to)
            print_components("  ->", [c colorUsingColorSpace:s]);
        for (NSString *n in @[ NSDeviceRGBColorSpace, NSCalibratedRGBColorSpace, NSDeviceWhiteColorSpace, NSCalibratedWhiteColorSpace,
                               NSNamedColorSpace, NSPatternColorSpace ])
            print_components("  name->", [c colorUsingColorSpaceName:n]);
        printf("  same space returns self %d\n", c.type == NSColorTypeComponentBased && [c colorUsingColorSpace:c.colorSpace] == c);
        print_components("  usingType component", [c colorUsingType:NSColorTypeComponentBased]);
        printf("  usingType catalog %s pattern %s\n", S([c colorUsingType:NSColorTypeCatalog]), S([c colorUsingType:NSColorTypePattern]));
    }
    printf("pattern to sRGB %s\n", S([[NSColor colorWithPatternImage:patternImage] colorUsingColorSpace:NSColorSpace.sRGBColorSpace]));
    print_components("sRGB description of converted gray", [[NSColor colorWithWhite:0.5 alpha:1] colorUsingColorSpace:NSColorSpace.sRGBColorSpace]);
    printf("  [%s]\n", S([[NSColor colorWithWhite:0.5 alpha:1] colorUsingColorSpace:NSColorSpace.sRGBColorSpace]));

    header("derived colours");
    NSColor *sa = [NSColor colorWithSRGBRed:0.2 green:0.4 blue:0.6 alpha:0.5], *db = [NSColor colorWithDeviceRed:1 green:0.5 blue:0 alpha:1];
    NSColor *gw = [NSColor colorWithWhite:0.3 alpha:1], *ck = [NSColor colorWithDeviceCyan:0.1 magenta:0.2 yellow:0.3 black:0.4 alpha:1];
    /* (no CMYK: Apple converts it with its Generic CMYK profile, which Finch doesn't have) */
    NSArray *derived = @[ sa, db, gw, [NSColor colorWithCalibratedWhite:0.3 alpha:1], [NSColor colorWithDeviceWhite:0.3 alpha:0.5],
                          [NSColor colorWithCalibratedRed:0.2 green:0.4 blue:0.6 alpha:1], NSColor.labelColor,
                          [NSColor colorWithSRGBRed:0.8 green:0.4 blue:0.2 alpha:1] ];
    for (NSColor *c in derived) {
        printf("%s\n", S(c));
        printf("  alpha 0.3: %s\n", S([c colorWithAlphaComponent:0.3]));
        print_components("  blend .5 sRGB", [c blendedColorWithFraction:0.5 ofColor:sa]);
        print_components("  blend .25 gray", [c blendedColorWithFraction:0.25 ofColor:gw]);
        print_components("  blend 0 device", [c blendedColorWithFraction:0 ofColor:db]);
        print_components("  blend 1 device", [c blendedColorWithFraction:1 ofColor:db]);
        print_components("  highlight .3", [c highlightWithLevel:0.3]);
        print_components("  shadow .3", [c shadowWithLevel:0.3]);
        printf("  copy same %d\n", [[c copy] autorelease] == c);
    }
    printf("equal: tagged/space %d device/sRGB %d same values %d hash %d white/device white %d label/catalog %d\n",
           [NSColor.redColor isEqual:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1]],
           [[NSColor colorWithDeviceRed:1 green:0 blue:0 alpha:1] isEqual:NSColor.redColor],
           [sa isEqual:[NSColor colorWithSRGBRed:0.2 green:0.4 blue:0.6 alpha:0.5]],
           sa.hash == [NSColor colorWithSRGBRed:0.2 green:0.4 blue:0.6 alpha:0.5].hash,
           [[NSColor colorWithWhite:0.5 alpha:1] isEqual:[NSColor colorWithDeviceWhite:0.5 alpha:1]],
           [NSColor.labelColor isEqual:[NSColor colorWithCatalogName:@"System" colorName:@"labelColor"]]);
    CGFloat comps[6] = {-1, -1, -1, -1, -1, -1};
    [ck getComponents:comps];
    printf("getComponents cmyk %s %s %s %s %s n %ld\n", F(comps[0]), F(comps[1]), F(comps[2]), F(comps[3]), F(comps[4]),
           (long)ck.numberOfComponents);
    printf("ignoresAlpha %d currentControlTint %ld\n", NSColor.ignoresAlpha, (long)NSColor.currentControlTint);

    header("NSColor archives");
    archived_color("sRGB", [NSColor colorWithSRGBRed:1 green:0.5 blue:0.25 alpha:0.75]);
    archived_color("255ths", [NSColor colorWithSRGBRed:0.8 green:0.4 blue:0.2 alpha:1]);
    archived_color("device", [NSColor colorWithDeviceRed:1 green:0.5 blue:0.25 alpha:1]);
    archived_color("device alpha", [NSColor colorWithDeviceRed:1 green:0.5 blue:0.25 alpha:0.5]);
    archived_color("calibrated", [NSColor colorWithCalibratedRed:1 green:0.5 blue:0.25 alpha:1]);
    archived_color("P3", [NSColor colorWithDisplayP3Red:1 green:0.5 blue:0.25 alpha:1]);
    archived_color("white", [NSColor colorWithWhite:0.5 alpha:1]);
    archived_color("device white", [NSColor colorWithDeviceWhite:0.5 alpha:0.5]);
    archived_color("calibrated white", [NSColor colorWithCalibratedWhite:0.5 alpha:1]);
    archived_color("cmyk", [NSColor colorWithDeviceCyan:0.1 magenta:0.2 yellow:0.3 black:0.4 alpha:1]);
    archived_color("generic from CG", [NSColor colorWithCGColor:CGColorCreateGenericRGB(0.1, 0.2, 0.3, 1)]);
    archived_color("adobe", [NSColor colorWithColorSpace:NSColorSpace.adobeRGB1998ColorSpace components:(CGFloat[]){0.1, 0.2, 0.3, 1} count:4]);
    archived_color("thirds", [NSColor colorWithSRGBRed:1.0 / 3 green:0.1 blue:0.123456789 alpha:1]);
    archived_color("label", NSColor.labelColor);
    printf("secure coding %d %d %d %d\n", NSColor.supportsSecureCoding, NSColorSpace.supportsSecureCoding,
           NSBezierPath.supportsSecureCoding, NSGradient.supportsSecureCoding);
}

/* MARK: - NSBezierPath */

static void
path_elements(const char *label, NSBezierPath *p)
{
    printf("%s: n=%ld", label, (long)p.elementCount);
    for (NSInteger i = 0; i < p.elementCount; i++) {
        NSPoint pt[3];
        NSBezierPathElement e = [p elementAtIndex:i associatedPoints:pt];
        int k = e == NSBezierPathElementCurveTo ? 3 : e == NSBezierPathElementClosePath ? 0 : e == NSBezierPathElementQuadraticCurveTo ? 2 : 1;
        printf(" %c", "MLCZQ"[e]);
        for (int j = 0; j < k; j++)
            printf(" %s,%s", F(pt[j].x), F(pt[j].y));
    }
    printf("\n");
    if (!p.isEmpty) {
        NSRect b = p.bounds, cb = p.controlPointBounds;
        NSPoint c = p.currentPoint;
        printf("  bounds %s %s %s %s cp %s %s %s %s current %s,%s\n", F(b.origin.x), F(b.origin.y), F(b.size.width), F(b.size.height),
               F(cb.origin.x), F(cb.origin.y), F(cb.size.width), F(cb.size.height), F(c.x), F(c.y));
    }
}

static NSBezierPath *
mixed_path(void)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0, 0)];
    [p lineToPoint:NSMakePoint(10, 0)];
    [p curveToPoint:NSMakePoint(20, 10) controlPoint1:NSMakePoint(15, 0) controlPoint2:NSMakePoint(20, 5)];
    [p closePath];
    [p lineToPoint:NSMakePoint(5, 5)];
    return p;
}

static void
bezier_paths(void)
{
    header("NSBezierPath");
    path_elements("rect", [NSBezierPath bezierPathWithRect:NSMakeRect(1, 2, 10, 20)]);
    path_elements("oval", [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1, 2, 30, 40)]);
    path_elements("rounded", [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 2, 30, 40) xRadius:4 yRadius:6]);
    path_elements("rounded big radii", [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, 40, 20) xRadius:30 yRadius:30]);
    path_elements("rounded zero radius", [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, 40, 20) xRadius:0 yRadius:5]);
    double arcs[][3] = {{0, 90, 0}, {0, 90, 1}, {30, 300, 0}, {-45, 405, 0}, {10, 10, 0}, {0, 720, 0}, {180, 0, 0}, {0, 360, 1},
                        {0, -90, 0}, {300, 30, 1}, {0, 100, 0}, {350, 10, 0}, {10, 350, 1}, {0, 1000, 0}, {123.4, 321, 0}, {720, 0, 1}};
    for (unsigned i = 0; i < sizeof arcs / sizeof arcs[0]; i++) {
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p appendBezierPathWithArcWithCenter:NSMakePoint(3, 4) radius:7 startAngle:arcs[i][0] endAngle:arcs[i][1] clockwise:arcs[i][2] != 0];
        char label[64];
        snprintf(label, sizeof label, "arc %g %g %s", arcs[i][0], arcs[i][1], arcs[i][2] != 0 ? "cw" : "ccw");
        path_elements(label, p);
    }
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0, 0)];
    [p appendBezierPathWithArcWithCenter:NSMakePoint(10, 10) radius:5 startAngle:180 endAngle:0];
    path_elements("arc after move", p);
    p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0, 0)];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(10, 0) toPoint:NSMakePoint(10, 10) radius:3];
    path_elements("arc from point", p);
    p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0, 0)];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(10, 0) toPoint:NSMakePoint(20, 0) radius:3];
    path_elements("arc from point, colinear", p);
    p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(20, 20)];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(0, 20) toPoint:NSMakePoint(0, 0) radius:5];
    path_elements("arc from point, turning left", p);

    NSBezierPath *m = mixed_path();
    path_elements("mixed", m);
    path_elements("reversed", [m bezierPathByReversingPath]);
    path_elements("reversed rect", [[NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 4, 3)] bezierPathByReversingPath]);
    path_elements("reversed oval", [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 4, 4)] bezierPathByReversingPath]);
    path_elements("flattened", [m bezierPathByFlatteningPath]);
    double curves[][8] = {{0, 0, 0, 100, 100, 100, 100, 0}, {0, 0, 10, 40, 30, -40, 40, 0}, {0, 0, 1, 1, 2, 1, 3, 0},
                          {0, 0, 50, 0, 50, 0, 50, 50}, {0, 0, 100, 0, 0, 100, 100, 100}};
    double flats[] = {0.1, 0.6, 2, 20};
    for (unsigned f = 0; f < 4; f++) {
        [NSBezierPath setDefaultFlatness:flats[f]];
        printf("flatness %g:", flats[f]);
        for (unsigned i = 0; i < 5; i++) {
            NSBezierPath *c = [NSBezierPath bezierPath];
            [c moveToPoint:NSMakePoint(curves[i][0], curves[i][1])];
            [c curveToPoint:NSMakePoint(curves[i][6], curves[i][7]) controlPoint1:NSMakePoint(curves[i][2], curves[i][3])
                controlPoint2:NSMakePoint(curves[i][4], curves[i][5])];
            printf(" %ld", (long)[c bezierPathByFlatteningPath].elementCount - 1);
        }
        printf("\n");
    }
    [NSBezierPath setDefaultFlatness:0.6];
    NSBezierPath *c = [NSBezierPath bezierPath];
    [c moveToPoint:NSMakePoint(0, 0)];
    [c curveToPoint:NSMakePoint(40, 0) controlPoint1:NSMakePoint(10, 40) controlPoint2:NSMakePoint(30, -40)];
    path_elements("flattened S", [c bezierPathByFlatteningPath]);

    p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(1, 1)];
    [p relativeLineToPoint:NSMakePoint(5, 0)];
    [p relativeCurveToPoint:NSMakePoint(5, 5) controlPoint1:NSMakePoint(1, 0) controlPoint2:NSMakePoint(5, 1)];
    [p relativeMoveToPoint:NSMakePoint(2, 2)];
    path_elements("relative", p);
    p = [NSBezierPath bezierPath];
    [p appendBezierPathWithRect:NSMakeRect(0, 0, 1, 1)];
    [p appendBezierPathWithOvalInRect:NSMakeRect(5, 5, 2, 2)];
    NSPoint pts[3] = {{0, 0}, {3, 4}, {5, 0}};
    [p appendBezierPathWithPoints:pts count:3];
    path_elements("appended", p);
    NSBezierPath *q = [NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 2, 2)];
    [q appendBezierPath:m];
    path_elements("append path", q);
    p = [NSBezierPath bezierPath];
    [p appendBezierPathWithPoints:pts count:3];
    path_elements("points into empty", p);
    p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0, 0)];
    [p lineToPoint:NSMakePoint(10, 0)];
    [p moveToPoint:NSMakePoint(5, 5)];
    [p moveToPoint:NSMakePoint(6, 6)];
    path_elements("double move", p);
    p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0, 0)];
    [p lineToPoint:NSMakePoint(10, 0)];
    [p closePath];
    [p closePath];
    path_elements("double close", p);
    p = [NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 4, 4)];
    [p lineToPoint:NSMakePoint(9, 9)];
    path_elements("line after rect", p);
    p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(0, 0)];
    [p curveToPoint:NSMakePoint(10, 0) controlPoint1:NSMakePoint(0, 10) controlPoint2:NSMakePoint(10, 10)];
    path_elements("curve bounds", p);

    printf("defaults: lw %g flat %g cap %ld join %ld miter %g wind %ld\n", NSBezierPath.defaultLineWidth, NSBezierPath.defaultFlatness,
           (long)NSBezierPath.defaultLineCapStyle, (long)NSBezierPath.defaultLineJoinStyle, NSBezierPath.defaultMiterLimit,
           (long)NSBezierPath.defaultWindingRule);
    p = [NSBezierPath bezierPath];
    NSBezierPath.defaultLineWidth = 3;
    printf("instance keeps its width %g, new %g\n", p.lineWidth, [NSBezierPath bezierPath].lineWidth);
    NSBezierPath.defaultLineWidth = 1;
    NSInteger count;
    CGFloat dash[4], phase;
    [p getLineDash:NULL count:&count phase:&phase];
    printf("dash count %ld\n", (long)count);
    [p setLineDash:(CGFloat[]){4, 2, 1} count:3 phase:1.5];
    [p getLineDash:dash count:&count phase:&phase];
    printf("dash %ld %g %g %g phase %g\n", (long)count, dash[0], dash[1], dash[2], phase);

    NSBezierPath *two = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 20, 20)];
    [two appendBezierPathWithOvalInRect:NSMakeRect(5, 5, 10, 10)];
    NSPoint tests[] = {{10, 10}, {2, 10}, {0, 0}, {20, 10}, {10, 20}, {10, 0}, {7, 10}, {19.9, 10}, {-1, 10}, {3, 3}};
    for (unsigned i = 0; i < sizeof tests / sizeof tests[0]; i++) {
        two.windingRule = NSWindingRuleNonZero;
        BOOL nz = [two containsPoint:tests[i]];
        two.windingRule = NSWindingRuleEvenOdd;
        printf("contains %g,%g nonzero %d evenodd %d\n", tests[i].x, tests[i].y, nz, [two containsPoint:tests[i]]);
    }
    NSBezierPath *r = [NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 10, 10)];
    printf("rect edges %d %d %d %d outside %d\n", [r containsPoint:NSMakePoint(0, 0)], [r containsPoint:NSMakePoint(10, 10)],
           [r containsPoint:NSMakePoint(10, 5)], [r containsPoint:NSMakePoint(5, 0)], [r containsPoint:NSMakePoint(10.01, 5)]);
    NSBezierPath *open = [NSBezierPath bezierPath];
    [open moveToPoint:NSMakePoint(0, 0)];
    [open lineToPoint:NSMakePoint(10, 0)];
    [open lineToPoint:NSMakePoint(10, 10)];
    printf("open path contains %d %d\n", [open containsPoint:NSMakePoint(8, 2)], [open containsPoint:NSMakePoint(2, 8)]);

    NSAffineTransform *t = [NSAffineTransform transform];
    [t rotateByDegrees:90];
    [t scaleBy:2];
    NSBezierPath *tr = [NSBezierPath bezierPathWithRect:NSMakeRect(1, 1, 2, 3)];
    [tr transformUsingAffineTransform:t];
    path_elements("transformed", tr);
    path_elements("transformBezierPath", [t transformBezierPath:[NSBezierPath bezierPathWithRect:NSMakeRect(1, 1, 2, 3)]]);
    p = [NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 4, 4)];
    NSPoint np[1] = {{9, 9}};
    [p setAssociatedPoints:np atIndex:2];
    path_elements("set points", p);
    [p removeAllPoints];
    printf("removed n=%ld empty %d\n", (long)p.elementCount, p.isEmpty);
    TRY("bounds of empty", (void)p.bounds);
    TRY("lineTo on empty", [p lineToPoint:NSMakePoint(1, 1)]);
    TRY("curveTo on empty", [p curveToPoint:NSMakePoint(1, 1) controlPoint1:NSZeroPoint controlPoint2:NSZeroPoint]);
    TRY("relativeMove on empty", [p relativeMoveToPoint:NSMakePoint(1, 1)]);
    TRY("currentPoint of empty", (void)p.currentPoint);
    [p closePath];
    printf("close on empty n=%ld\n", (long)p.elementCount);
    TRY("element out of range", (void)[[NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 1, 1)] elementAtIndex:10]);
    NSBezierPath *cp = [[m copy] autorelease];
    printf("copy equal %d, fresh equal %d, after change %d\n", [cp isEqual:m], [mixed_path() isEqual:m],
           ([cp lineToPoint:NSMakePoint(1, 1)], [cp isEqual:m]));
    NSString *desc = [NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, 1, 2)].description;
    NSRange nl = [desc rangeOfString:@"\n"];
    printf("description:%s", [desc substringFromIndex:nl.location].UTF8String);
    NSBezierPath *fromCG = [NSBezierPath bezierPathWithCGPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 10, 10)].CGPath];
    path_elements("from CGPath", fromCG);
    CGRect bb = CGPathGetBoundingBox([NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 10, 10)].CGPath);
    printf("CGPath box %s %s %s %s\n", F(bb.origin.x), F(bb.origin.y), F(bb.size.width), F(bb.size.height));

    header("NSBezierPath archives");
    for (int v = 0; v < 2; v++) {
        NSBezierPath *a = mixed_path();
        if (v) {
            a.lineWidth = 2.5, a.lineCapStyle = NSLineCapStyleRound, a.lineJoinStyle = NSLineJoinStyleBevel, a.miterLimit = 4;
            a.flatness = 0.3, a.windingRule = NSWindingRuleEvenOdd;
            [a setLineDash:(CGFloat[]){3, 1} count:2 phase:0.5];
        }
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:a requiringSecureCoding:YES error:nil];
        NSDictionary *root = [NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil][@"$objects"][1];
        for (NSString *k in [[root allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            if ([k isEqualToString:@"$class"])
                continue;
            id val = root[k];
            if ([val isKindOfClass:[NSData class]]) {
                printf("  %s =", k.UTF8String);
                const unsigned char *bytes = [val bytes];
                for (NSUInteger i = 0; i < [val length]; i++)
                    printf("%s%02x", i % 9 ? "" : " ", bytes[i]);
                printf("\n");
            } else
                printf("  %s = %s\n", k.UTF8String, S(val));
        }
        NSBezierPath *b = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSBezierPath class] fromData:d error:nil];
        printf("  unarchived: n=%ld lw %g cap %ld join %ld miter %g flat %g wind %ld\n", (long)b.elementCount, b.lineWidth,
               (long)b.lineCapStyle, (long)b.lineJoinStyle, b.miterLimit, b.flatness, (long)b.windingRule);
        path_elements("  elements", b);
    }
}

/* MARK: - NSGradient */

static void
gradient_detail(const char *label, NSGradient *g)
{
    if (!g) {
        printf("%s: nil\n", label);
        return;
    }
    printf("%s: stops %ld space %s\n", label, (long)g.numberOfColorStops, S(g.colorSpace));
    for (NSInteger i = 0; i < g.numberOfColorStops; i++) {
        NSColor *c;
        CGFloat loc;
        [g getColor:&c location:&loc atIndex:i];
        printf("  stop %g %s\n", loc, S(c));
    }
    for (double t = -0.25; t <= 1.25; t += 0.25) {
        char label[32];
        snprintf(label, sizeof label, "  at %g", t);
        print_components(label, [g interpolatedColorAtLocation:t]);
    }
}

static void
gradients(void)
{
    header("NSGradient");
    gradient_detail("two", [[[NSGradient alloc] initWithStartingColor:NSColor.redColor endingColor:NSColor.blueColor] autorelease]);
    gradient_detail("three", [[[NSGradient alloc] initWithColors:@[ NSColor.redColor, NSColor.greenColor,
                                                                    [NSColor colorWithWhite:0.5 alpha:0.5] ]] autorelease]);
    gradient_detail("with locations", [[[NSGradient alloc] initWithColorsAndLocations:NSColor.redColor, 0.2, NSColor.blueColor, 0.9, nil] autorelease]);
    CGFloat locs[] = {0.5, 0.1, 0.8};
    gradient_detail("unsorted, generic RGB", [[[NSGradient alloc] initWithColors:@[ [NSColor colorWithSRGBRed:0.8 green:0.2 blue:0.2 alpha:1],
                                                                                    [NSColor colorWithSRGBRed:0.2 green:0.8 blue:0.2 alpha:1],
                                                                                    [NSColor colorWithSRGBRed:0.2 green:0.2 blue:0.8 alpha:1] ]
                                                                     atLocations:locs colorSpace:NSColorSpace.genericRGBColorSpace] autorelease]);
    gradient_detail("one colour", [[[NSGradient alloc] initWithColors:@[ NSColor.redColor ]] autorelease]);
    gradient_detail("device", [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithDeviceRed:1 green:0 blue:0 alpha:1]
                                                             endingColor:[NSColor colorWithDeviceWhite:1 alpha:1]] autorelease]);
    gradient_detail("catalog", [[[NSGradient alloc] initWithStartingColor:NSColor.labelColor endingColor:NSColor.systemRedColor] autorelease]);
    gradient_detail("gray space", [[[NSGradient alloc] initWithColors:@[ NSColor.blackColor, NSColor.whiteColor ] atLocations:(CGFloat[]){0, 1}
                                                           colorSpace:NSColorSpace.genericGamma22GrayColorSpace] autorelease]);
    TRY("stop out of range", [[[[NSGradient alloc] initWithColors:@[ NSColor.redColor, NSColor.blueColor ]] autorelease] getColor:NULL location:NULL atIndex:5]);
}

/* MARK: - Image reps */

static void
rep_detail(NSBitmapImageRep *r)
{
    if (!r) {
        printf("  nil\n");
        return;
    }
    printf("  %ldx%ld size %s bps %ld spp %ld bpp %ld bpr %ld planar %d planes %ld alpha %d opaque %d format %lu cs %s [%s] data %d\n",
           (long)r.pixelsWide, (long)r.pixelsHigh, NSStringFromSize(r.size).UTF8String, (long)r.bitsPerSample, (long)r.samplesPerPixel,
           (long)r.bitsPerPixel, (long)r.bytesPerRow, r.planar, (long)r.numberOfPlanes, r.hasAlpha, r.opaque,
           (unsigned long)r.bitmapFormat, r.colorSpaceName.UTF8String, S(r.colorSpace), r.bitmapData != NULL);
    CGImageRef im = r.CGImage;
    if (im)
        printf("  CGImage %zux%zu bpc %zu bpp %zu bpr %zu info %x\n", CGImageGetWidth(im), CGImageGetHeight(im),
               CGImageGetBitsPerComponent(im), CGImageGetBitsPerPixel(im), CGImageGetBytesPerRow(im), CGImageGetBitmapInfo(im));
    else
        printf("  CGImage nil\n");
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithBitmapImageRep:r];
    if (g)
        printf("  context bpr %zu info %x\n", CGBitmapContextGetBytesPerRow(g.CGContext), CGBitmapContextGetBitmapInfo(g.CGContext));
    else
        printf("  no context\n");
}

static void
image_reps(void)
{
    header("NSBitmapImageRep formats");
    struct {
        int bps, spp, alpha, planar;
        NSString *cs;
        NSBitmapFormat fmt;
        int bpr, bpp;
    } cases[] = {
        {8, 4, 1, 0, NSDeviceRGBColorSpace, 0, 0, 0}, {8, 4, 1, 0, NSCalibratedRGBColorSpace, 0, 0, 0},
        {8, 3, 0, 0, NSDeviceRGBColorSpace, 0, 0, 0}, {8, 3, 0, 0, NSDeviceRGBColorSpace, 0, 0, 32},
        {8, 1, 0, 0, NSDeviceWhiteColorSpace, 0, 0, 0}, {8, 2, 1, 0, NSCalibratedWhiteColorSpace, 0, 0, 0},
        {16, 4, 1, 0, NSDeviceRGBColorSpace, 0, 0, 0}, {32, 4, 1, 0, NSDeviceRGBColorSpace, NSBitmapFormatFloatingPointSamples, 0, 0},
        {8, 4, 1, 0, NSDeviceRGBColorSpace, NSBitmapFormatAlphaFirst, 0, 0},
        {8, 4, 1, 0, NSDeviceRGBColorSpace, NSBitmapFormatAlphaNonpremultiplied, 0, 0}, {8, 4, 1, 1, NSDeviceRGBColorSpace, 0, 0, 0},
        {8, 4, 0, 0, NSDeviceCMYKColorSpace, 0, 0, 0}, {8, 5, 1, 0, NSDeviceCMYKColorSpace, 0, 0, 0},
        {1, 1, 0, 0, NSDeviceWhiteColorSpace, 0, 0, 0}, {4, 1, 0, 0, NSCalibratedWhiteColorSpace, 0, 0, 0},
        {8, 4, 1, 0, NSDeviceRGBColorSpace, 0, 100, 0}, {8, 4, 1, 0, NSDeviceRGBColorSpace, NSBitmapFormatThirtyTwoBitLittleEndian, 0, 0},
        {16, 4, 1, 0, NSDeviceRGBColorSpace, NSBitmapFormatSixteenBitLittleEndian, 0, 0}, {8, 4, 0, 0, NSDeviceRGBColorSpace, 0, 0, 0},
        {8, 2, 0, 0, NSDeviceRGBColorSpace, 0, 0, 0}, {8, 1, 1, 0, NSDeviceWhiteColorSpace, 0, 0, 0},
        {8, 4, 1, 0, NSPatternColorSpace, 0, 0, 0}, {5, 3, 0, 0, NSDeviceRGBColorSpace, 0, 0, 0},
        {12, 3, 0, 0, NSDeviceRGBColorSpace, 0, 0, 0},
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        printf("case %u: bps %d spp %d alpha %d planar %d %s format %lu bpr %d bpp %d\n", i, cases[i].bps, cases[i].spp, cases[i].alpha,
               cases[i].planar, cases[i].cs.UTF8String, (unsigned long)cases[i].fmt, cases[i].bpr, cases[i].bpp);
        NSBitmapImageRep *r = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:5 pixelsHigh:3
            bitsPerSample:cases[i].bps samplesPerPixel:cases[i].spp hasAlpha:cases[i].alpha isPlanar:cases[i].planar
            colorSpaceName:cases[i].cs bitmapFormat:cases[i].fmt bytesPerRow:cases[i].bpr bitsPerPixel:cases[i].bpp] autorelease];
        rep_detail(r);
    }

    header("NSBitmapImageRep pixels");
    NSBitmapImageRep *r = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:3 pixelsHigh:2 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    unsigned char *d = r.bitmapData;
    printf("initial %d %d %d %d\n", d[0], d[1], d[2], d[3]);
    [r setColor:[NSColor colorWithDeviceRed:1 green:0.5 blue:0.25 alpha:0.5] atX:1 y:0];
    printf("setColor %d %d %d %d\n", d[4], d[5], d[6], d[7]);
    print_components("colorAt", [r colorAtX:1 y:0]);
    NSUInteger px[5];
    [r getPixel:px atX:1 y:0];
    printf("getPixel %lu %lu %lu %lu\n", px[0], px[1], px[2], px[3]);
    NSUInteger sp[4] = {10, 20, 30, 40};
    [r setPixel:sp atX:2 y:1];
    [r getPixel:px atX:2 y:1];
    printf("setPixel %lu %lu %lu %lu\n", px[0], px[1], px[2], px[3]);
    print_components("colorAt set pixel", [r colorAtX:2 y:1]);
    printf("colorAt outside %s\n", S([r colorAtX:5 y:5]));
    NSBitmapImageRep *g = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8
        samplesPerPixel:1 hasAlpha:NO isPlanar:NO colorSpaceName:NSCalibratedWhiteColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    [g setColor:[NSColor colorWithCalibratedWhite:0.5 alpha:1] atX:0 y:0];
    printf("gray setColor %d\n", g.bitmapData[0]);
    print_components("gray colorAt", [g colorAtX:0 y:0]);
    NSBitmapImageRep *s16 = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:16
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    [s16 setColor:[NSColor colorWithDeviceRed:0.2 green:0.4 blue:0.6 alpha:1] atX:1 y:1];
    [s16 getPixel:px atX:1 y:1];
    printf("16-bit getPixel %lu %lu %lu %lu\n", px[0], px[1], px[2], px[3]);
    print_components("16-bit colorAt", [s16 colorAtX:1 y:1]);
    NSBitmapImageRep *one = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:10 pixelsHigh:1 bitsPerSample:1
        samplesPerPixel:1 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceWhiteColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    NSUInteger on = 1;
    [one setPixel:&on atX:3 y:0];
    [one setPixel:&on atX:9 y:0];
    printf("1-bit bytes %02x %02x\n", one.bitmapData[0], one.bitmapData[1]);
    print_components("1-bit colorAt", [one colorAtX:3 y:0]);
    NSBitmapImageRep *planar = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8
        samplesPerPixel:3 hasAlpha:NO isPlanar:YES colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    [planar setColor:[NSColor colorWithDeviceRed:1 green:0.5 blue:0 alpha:1] atX:1 y:0];
    unsigned char *planes[5];
    [planar getBitmapDataPlanes:planes];
    printf("planar planes %d %d %d (plane 4 %s)\n", planes[0][1], planes[1][1], planes[2][1], planes[3] ? "set" : "NULL");
    print_components("planar colorAt", [planar colorAtX:1 y:0]);

    header("NSBitmapImageRep from CGImage and data");
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    unsigned char buf[16] = {255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 10, 20, 30, 255};
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, buf, 16, NULL);
    CGImageRef im = CGImageCreate(2, 2, 8, 32, 8, rgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast, prov, NULL, false, kCGRenderingIntentDefault);
    NSBitmapImageRep *c2 = [[[NSBitmapImageRep alloc] initWithCGImage:im] autorelease];
    printf("from CGImage same image %d\n", c2.CGImage == im);
    rep_detail(c2);
    print_components("colorAt 1,0", [c2 colorAtX:1 y:0]);
    print_components("colorAt 1,1", [c2 colorAtX:1 y:1]);
    unsigned char *cd = c2.bitmapData;
    printf("data %d %d %d %d\n", cd[4], cd[5], cd[6], cd[7]);
    NSData *png = [c2 representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    printf("png %d\n", png.length > 0);
    NSBitmapImageRep *back = [NSBitmapImageRep imageRepWithData:png];
    printf("from png %ldx%ld size %s alpha %d\n", (long)back.pixelsWide, (long)back.pixelsHigh, NSStringFromSize(back.size).UTF8String, back.hasAlpha);
    for (int y = 0; y < 2; y++)
        for (int x = 0; x < 2; x++)
            print_components("  png colorAt", [back colorAtX:x y:y]);
    NSData *jpg = [c2 representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor: @0.9}];
    printf("jpeg %d\n", jpg.length > 0);
    NSBitmapImageRep *jback = [NSBitmapImageRep imageRepWithData:jpg];
    printf("from jpeg %ldx%ld\n", (long)jback.pixelsWide, (long)jback.pixelsHigh);
    printf("png and jpeg readable %d %d\n", [NSBitmapImageRep.imageTypes containsObject:@"public.png"],
           [NSBitmapImageRep.imageTypes containsObject:@"public.jpeg"]);
    printf("canInit png %d junk %d, junk rep %s\n", [NSBitmapImageRep canInitWithData:png],
           [NSBitmapImageRep canInitWithData:[NSData dataWithBytes:"junk" length:4]],
           S([[[NSBitmapImageRep alloc] initWithData:[NSData dataWithBytes:"junk" length:4]] autorelease]));
    printf("rep class for png %s\n", class_getName([NSImageRep imageRepClassForData:png]));
    NSBitmapImageRep *sized = [[back copy] autorelease];
    sized.size = NSMakeSize(10, 10);
    printf("copy+setSize %s pixels %ld, original %s\n", NSStringFromSize(sized.size).UTF8String, (long)sized.pixelsWide,
           NSStringFromSize(back.size).UTF8String);
    NSBitmapImageRep *retag = [c2 bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    printf("retagged %s %s\n", S(retag.colorSpace), retag.colorSpaceName.UTF8String);
    printf("retag to gray %s\n", S([c2 bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.genericGrayColorSpace]));
    NSBitmapImageRep *conv = [c2 bitmapImageRepByConvertingToColorSpace:NSColorSpace.genericRGBColorSpace
                                                         renderingIntent:NSColorRenderingIntentDefault];
    printf("converted to generic RGB: %s spp %ld\n", S(conv.colorSpace), (long)conv.samplesPerPixel);
    print_components("  converted colorAt 0,0", [conv colorAtX:0 y:0]);
    CGImageRelease(im);
    CGDataProviderRelease(prov);
    CGColorSpaceRelease(rgb);
    printf("registered has bitmap %d\n", [NSImageRep.registeredImageRepClasses containsObject:[NSBitmapImageRep class]]);
}

/* MARK: - NSImage */

static NSBitmapImageRep *
checker_rep(int n, int cells)
{
    NSBitmapImageRep *r = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:n pixelsHigh:n bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    unsigned char *d = r.bitmapData;
    for (int y = 0; y < n; y++)
        for (int x = 0; x < n; x++) {
            int on = ((x * cells / n) + (y * cells / n)) % 2;
            unsigned char *p = d + y * r.bytesPerRow + 4 * x;
            unsigned char a = (x < n / 4 && y < n / 4) ? 0 : 255;  /* a transparent corner */
            p[0] = (unsigned char)((on ? 220 : 20) * a / 255), p[1] = (unsigned char)((on ? 40 : 160) * a / 255);
            p[2] = (unsigned char)((x * 255 / (n - 1)) * a / 255), p[3] = a;
        }
    return r;
}

static void
images(void)
{
    header("NSImage");
    NSImage *i = [[[NSImage alloc] initWithSize:NSMakeSize(4, 3)] autorelease];
    printf("sized: size %s valid %d template %d name %s cacheMode %ld multiple %d colorMatch %d eps %d bestFitting %d\n",
           NSStringFromSize(i.size).UTF8String, i.valid, i.template, S(i.name), (long)i.cacheMode, i.matchesOnMultipleResolution,
           i.prefersColorMatch, i.usesEPSOnResolutionMismatch, i.matchesOnlyOnBestFittingAxis);
    printf("alignmentRect %s resizing %ld background %s\n", NSStringFromRect(i.alignmentRect).UTF8String, (long)i.resizingMode,
           S(i.backgroundColor));
    [i lockFocus];
    printf("lockFocus: context %d flipped %d\n", [NSGraphicsContext currentContext] != nil, [NSGraphicsContext currentContext].flipped);
    [[NSColor redColor] set];
    NSRectFill(NSMakeRect(0, 0, 2, 3));
    [i unlockFocus];
    printf("unlockFocus: context %d reps %lu valid %d size %s\n", [NSGraphicsContext currentContext] != nil,
           (unsigned long)i.representations.count, i.valid, NSStringFromSize(i.size).UTF8String);
    [i lockFocusFlipped:YES];
    printf("lockFocusFlipped: flipped %d\n", [NSGraphicsContext currentContext].flipped);
    [i unlockFocus];
    NSImage *e = [[[NSImage alloc] init] autorelease];
    printf("empty: size %s valid %d reps %lu\n", NSStringFromSize(e.size).UTF8String, e.valid, (unsigned long)e.representations.count);
    TRY("lockFocus on empty", [e lockFocus]);
    printf("imageNamed missing %s\n", S([NSImage imageNamed:@"finch-not-an-image"]));
    printf("setName %d, imageNamed finds it %d, name %s\n", [i setName:@"finch-test-image"],
           [NSImage imageNamed:@"finch-test-image"] == i, i.name.UTF8String);
    NSImage *other = [[[NSImage alloc] initWithSize:NSMakeSize(1, 1)] autorelease];
    printf("name taken %d\n", [other setName:@"finch-test-image"]);
    [i setName:nil];
    printf("unnamed, lookup %s\n", S([NSImage imageNamed:@"finch-test-image"]));

    NSBitmapImageRep *rep = checker_rep(16, 4);
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSImage *fromData = [[[NSImage alloc] initWithData:png] autorelease];
    printf("from data: size %s reps %lu valid %d\n", NSStringFromSize(fromData.size).UTF8String, (unsigned long)fromData.representations.count,
           fromData.valid);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-appkit-draw-test.png"];
    [png writeToFile:path atomically:YES];
    NSImage *fromFile = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
    NSImage *fromURL = [[[NSImage alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]] autorelease];
    printf("from file %s, from URL %s\n", NSStringFromSize(fromFile.size).UTF8String, NSStringFromSize(fromURL.size).UTF8String);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    printf("bad data %s, missing file %s\n", S([[[NSImage alloc] initWithData:[NSData dataWithBytes:"xx" length:2]] autorelease]),
           S([[[NSImage alloc] initWithContentsOfFile:@"/nonexistent/finch.png"] autorelease]));
    CGImageRef cg = rep.CGImage;
    NSImage *fromCG = [[[NSImage alloc] initWithCGImage:cg size:NSMakeSize(32, 32)] autorelease];
    printf("from CGImage: size %s rep size %s\n", NSStringFromSize(fromCG.size).UTF8String,
           NSStringFromSize(fromCG.representations[0].size).UTF8String);
    NSImage *zero = [[[NSImage alloc] initWithCGImage:cg size:NSZeroSize] autorelease];
    printf("from CGImage zero size: %s\n", NSStringFromSize(zero.size).UTF8String);
    NSImage *added = [[[NSImage alloc] init] autorelease];
    [added addRepresentation:rep];
    printf("added rep: size %s\n", NSStringFromSize(added.size).UTF8String);
    added.size = NSMakeSize(8, 8);
    printf("resized: %s rep %s\n", NSStringFromSize(added.size).UTF8String, NSStringFromSize(rep.size).UTF8String);
    [added removeRepresentation:rep];
    printf("removed: reps %lu\n", (unsigned long)added.representations.count);
    NSImage *copy = [[fromCG copy] autorelease];
    printf("copy: size %s reps %lu same rep %d\n", NSStringFromSize(copy.size).UTF8String, (unsigned long)copy.representations.count,
           copy.representations[0] == fromCG.representations[0]);
    __block NSRect handlerRect = NSZeroRect;
    __block int handlerFlipped = -1;
    NSImage *h = [NSImage imageWithSize:NSMakeSize(5, 5) flipped:YES drawingHandler:^BOOL(NSRect dst) {
        handlerRect = dst;
        handlerFlipped = [NSGraphicsContext currentContext].flipped;
        return YES;
    }];
    printf("handler image: size %s reps %lu custom %d\n", NSStringFromSize(h.size).UTF8String, (unsigned long)h.representations.count,
           [h.representations[0] isKindOfClass:[NSCustomImageRep class]]);
    CGContextRef bc = rgba_context(20, 20);
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:bc flipped:NO]];
    [h drawInRect:NSMakeRect(0, 0, 10, 10)];
    printf("handler called with %s flipped %d\n", NSStringFromRect(handlerRect).UTF8String, handlerFlipped);
    NSRect proposed = NSMakeRect(0, 0, 4, 4);
    CGImageRef hcg = [fromCG CGImageForProposedRect:&proposed context:[NSGraphicsContext currentContext] hints:nil];
    printf("CGImageForProposedRect %zux%zu rect %s\n", CGImageGetWidth(hcg), CGImageGetHeight(hcg), NSStringFromRect(proposed).UTF8String);
    [NSGraphicsContext setCurrentContext:nil];
    CGContextRelease(bc);
    printf("template %d -> ", fromCG.template);
    fromCG.template = YES;
    printf("%d\n", fromCG.template);
}

/* MARK: - NSGraphics functions */

static void
graphics_functions(void)
{
    header("NSGraphics");
    NSWindowDepth ds[] = {NSWindowDepthTwentyfourBitRGB, NSWindowDepthSixtyfourBitRGB, NSWindowDepthOnehundredtwentyeightBitRGB, 0x108, 0x204, 0x502};
    for (unsigned i = 0; i < sizeof ds / sizeof ds[0]; i++)
        printf("depth %x: planar %d bps %ld bpp %ld cs %s\n", ds[i], NSPlanarFromDepth(ds[i]), (long)NSBitsPerSampleFromDepth(ds[i]),
               (long)NSBitsPerPixelFromDepth(ds[i]), S(NSColorSpaceFromDepth(ds[i])));
    for (NSString *n in @[ NSCalibratedWhiteColorSpace, NSDeviceRGBColorSpace, NSDeviceCMYKColorSpace ])
        printf("components %s %ld\n", n.UTF8String, (long)NSNumberOfColorComponents(n));
    BOOL exact;
    NSWindowDepth d = NSBestDepth(NSDeviceRGBColorSpace, 8, 24, NO, &exact);
    printf("best rgb 8 %x exact %d\n", d, exact);
    d = NSBestDepth(NSDeviceRGBColorSpace, 16, 64, NO, &exact);
    printf("best rgb 16 %x exact %d\n", d, exact);
    d = NSBestDepth(NSCalibratedWhiteColorSpace, 8, 8, NO, &exact);
    printf("best gray 8 %x exact %d\n", d, exact);
    printf("available:");
    for (const NSWindowDepth *a = NSAvailableWindowDepths(); *a; a++)
        printf(" %x", *a);
    printf("\n");
    NSRect r = NSDrawTiledRects(NSMakeRect(0, 0, 10, 10), NSMakeRect(0, 0, 10, 10), (NSRectEdge[]){NSRectEdgeMinX, NSRectEdgeMaxY},
                                (CGFloat[]){0, 1}, 2);
    printf("tiled remainder (no context) %s\n", NSStringFromRect(r).UTF8String);
    NSBeep();
    printf("beep returned\n");
}

/* MARK: - Scenes */

#define SIZE 64

typedef void (*SceneFn)(void);

static void
fill_white(void)
{
    [[NSColor whiteColor] set];
    NSRectFill(NSMakeRect(0, 0, SIZE, SIZE));
}

static void
s_rect_fill(void)
{
    fill_white();
    [[NSColor redColor] set];
    NSRectFill(NSMakeRect(4, 4, 30, 20));
    [[NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:0.5] set];
    NSRectFill(NSMakeRect(20, 14, 30, 30));
    [[NSColor colorWithSRGBRed:0 green:0.6 blue:0 alpha:0.5] setFill];
    NSRectFillUsingOperation(NSMakeRect(30, 30, 30, 30), NSCompositingOperationSourceOver);
    [[NSColor colorWithDeviceWhite:0.25 alpha:1] set];
    NSRect list[3] = {{{2, 50}, {10, 10}}, {{14, 50}, {10, 10}}, {{2, 30}, {6, 6}}};
    NSRectFillList(list, 3);
}

static void
s_frames(void)
{
    fill_white();
    [[NSColor blackColor] set];
    NSFrameRect(NSMakeRect(4, 4, 56, 56));
    [[NSColor colorWithSRGBRed:0.8 green:0.1 blue:0.1 alpha:1] set];
    NSFrameRectWithWidth(NSMakeRect(10, 10, 44, 30), 3);
    [[NSColor colorWithSRGBRed:0.1 green:0.1 blue:0.8 alpha:0.5] set];
    NSFrameRectWithWidthUsingOperation(NSMakeRect(20, 20, 30, 36), 5, NSCompositingOperationSourceOver);
    NSEraseRect(NSMakeRect(40, 4, 10, 10));
}

static void
s_operations(void)
{
    [[NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1] set];
    NSRectFill(NSMakeRect(8, 8, 48, 48));
    [[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:0.75] set];
    NSRectFillUsingOperation(NSMakeRect(0, 0, 30, 30), NSCompositingOperationSourceAtop);
    NSRectFillUsingOperation(NSMakeRect(34, 0, 30, 30), NSCompositingOperationXOR);
    NSRectFillUsingOperation(NSMakeRect(0, 34, 30, 30), NSCompositingOperationDestinationOver);
    NSRectFillUsingOperation(NSMakeRect(34, 34, 30, 30), NSCompositingOperationClear);
    [[NSColor colorWithSRGBRed:0.5 green:1 blue:0.5 alpha:1] set];
    NSRectFillUsingOperation(NSMakeRect(24, 24, 16, 16), NSCompositingOperationMultiply);
}

static void
s_paths_fill(void)
{
    fill_white();
    [[NSColor colorWithSRGBRed:0.2 green:0.6 blue:0.3 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4, 30, 40, 28)] fill];
    [[NSColor colorWithSRGBRed:0.8 green:0.3 blue:0.1 alpha:0.8] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(20, 6, 40, 30) xRadius:8 yRadius:5] fill];
    NSBezierPath *two = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2, 2, 24, 24)];
    [two appendBezierPathWithOvalInRect:NSMakeRect(8, 8, 12, 12)];
    two.windingRule = NSWindingRuleEvenOdd;
    [[NSColor blackColor] setFill];
    [two fill];
    [[NSColor colorWithSRGBRed:0.1 green:0.1 blue:0.6 alpha:1] setFill];
    [NSBezierPath fillRect:NSMakeRect(50, 50, 10, 10)];
}

static void
s_paths_stroke(void)
{
    fill_white();
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(8, 8)];
    [p lineToPoint:NSMakePoint(56, 20)];
    [p lineToPoint:NSMakePoint(20, 56)];
    p.lineWidth = 5;
    p.lineCapStyle = NSLineCapStyleRound;
    p.lineJoinStyle = NSLineJoinStyleRound;
    [[NSColor colorWithSRGBRed:0 green:0 blue:0.6 alpha:1] setStroke];
    [p stroke];
    NSBezierPath *d = [NSBezierPath bezierPathWithRect:NSMakeRect(6, 30, 24, 24)];
    [d setLineDash:(CGFloat[]){6, 3} count:2 phase:2];
    d.lineWidth = 2;
    [[NSColor colorWithSRGBRed:0.8 green:0.4 blue:0 alpha:1] setStroke];
    [d stroke];
    NSBezierPath *m = [NSBezierPath bezierPath];
    [m moveToPoint:NSMakePoint(34, 34)];
    [m lineToPoint:NSMakePoint(46, 58)];
    [m lineToPoint:NSMakePoint(58, 34)];
    m.lineWidth = 4;
    m.lineJoinStyle = NSLineJoinStyleMiter;
    [[NSColor colorWithSRGBRed:0.5 green:0 blue:0.5 alpha:1] setStroke];
    [m stroke];
    NSBezierPath.defaultLineWidth = 3;
    [[NSColor colorWithSRGBRed:0.1 green:0.6 blue:0.1 alpha:1] setStroke];
    [NSBezierPath strokeLineFromPoint:NSMakePoint(30, 4) toPoint:NSMakePoint(60, 10)];
    [NSBezierPath strokeRect:NSMakeRect(40, 12, 10, 8)];
    NSBezierPath.defaultLineWidth = 1;
}

static void
s_arcs(void)
{
    fill_white();
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(32, 32)];
    [p appendBezierPathWithArcWithCenter:NSMakePoint(32, 32) radius:26 startAngle:30 endAngle:300];
    [p closePath];
    [[NSColor colorWithSRGBRed:0.9 green:0.7 blue:0.1 alpha:1] setFill];
    [p fill];
    NSBezierPath *q = [NSBezierPath bezierPath];
    [q appendBezierPathWithArcWithCenter:NSMakePoint(32, 32) radius:14 startAngle:200 endAngle:20 clockwise:YES];
    q.lineWidth = 3;
    [[NSColor blackColor] setStroke];
    [q stroke];
    NSBezierPath *r = [NSBezierPath bezierPath];
    [r moveToPoint:NSMakePoint(4, 60)];
    [r appendBezierPathWithArcFromPoint:NSMakePoint(60, 60) toPoint:NSMakePoint(60, 4) radius:12];
    [r lineToPoint:NSMakePoint(60, 4)];
    r.lineWidth = 2;
    [[NSColor colorWithSRGBRed:0.2 green:0.2 blue:0.9 alpha:1] setStroke];
    [r stroke];
}

static void
s_clip(void)
{
    fill_white();
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(6, 6, 52, 40)] addClip];
    [[NSColor colorWithSRGBRed:0.7 green:0.1 blue:0.4 alpha:1] set];
    NSRectFill(NSMakeRect(0, 0, 40, 64));
    NSRectClip(NSMakeRect(30, 0, 34, 64));
    [[NSColor colorWithSRGBRed:0.1 green:0.4 blue:0.7 alpha:1] set];
    NSRectFill(NSMakeRect(0, 20, 64, 10));
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext saveGraphicsState];
    NSRect list[2] = {{{2, 50}, {10, 10}}, {{50, 50}, {10, 10}}};
    NSRectClipList(list, 2);
    [[NSColor blackColor] set];
    NSRectFill(NSMakeRect(0, 48, 64, 16));
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext saveGraphicsState];
    [NSBezierPath clipRect:NSMakeRect(20, 48, 20, 16)];
    [[NSColor colorWithSRGBRed:0 green:0.7 blue:0 alpha:1] set];
    NSRectFill(NSMakeRect(0, 52, 64, 8));
    [NSGraphicsContext restoreGraphicsState];
}

static void
s_transform(void)
{
    fill_white();
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:32 yBy:32];
    [t rotateByDegrees:30];
    [t scaleXBy:1.5 yBy:0.75];
    [t concat];
    [[NSColor colorWithSRGBRed:0.3 green:0.3 blue:0.8 alpha:1] set];
    NSRectFill(NSMakeRect(-12, -12, 24, 24));
    [NSGraphicsContext restoreGraphicsState];
    NSAffineTransform *u = [NSAffineTransform transform];
    [u translateXBy:8 yBy:44];
    [u scaleBy:0.5];
    NSBezierPath *p = [u transformBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 30, 30)]];
    [[NSColor colorWithSRGBRed:0.8 green:0.2 blue:0.2 alpha:1] setFill];
    [p fill];
}

static void
s_gradient_angle(void)
{
    NSGradient *g = [[[NSGradient alloc] initWithColors:@[ NSColor.redColor, [NSColor colorWithSRGBRed:0 green:1 blue:0 alpha:0.6], NSColor.blueColor ]] autorelease];
    [g drawInRect:NSMakeRect(4, 4, 56, 40) angle:30];
    NSGradient *h = [[[NSGradient alloc] initWithStartingColor:NSColor.whiteColor endingColor:NSColor.blackColor] autorelease];
    [h drawInRect:NSMakeRect(4, 48, 56, 12) angle:0];
}

static void
s_gradient_path(void)
{
    fill_white();
    NSGradient *g = [[[NSGradient alloc] initWithColorsAndLocations:NSColor.yellowColor, 0.1, NSColor.purpleColor, 0.9, nil] autorelease];
    [g drawInBezierPath:[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(6, 6, 52, 52) xRadius:10 yRadius:10] angle:-90];
    NSGradient *two = [[[NSGradient alloc] initWithStartingColor:NSColor.redColor endingColor:NSColor.blueColor] autorelease];
    [two drawFromPoint:NSMakePoint(20, 20) toPoint:NSMakePoint(44, 44) options:0];
}

static void
s_gradient_radial(void)
{
    fill_white();
    NSGradient *g = [[[NSGradient alloc] initWithStartingColor:NSColor.whiteColor endingColor:[NSColor colorWithSRGBRed:0 green:0.3 blue:0.7 alpha:1]] autorelease];
    [g drawFromCenter:NSMakePoint(24, 26) radius:2 toCenter:NSMakePoint(32, 32) radius:28
              options:NSGradientDrawsBeforeStartingLocation | NSGradientDrawsAfterEndingLocation];
}

static void
s_gradient_radial_rect(void)
{
    fill_white();
    NSGradient *g = [[[NSGradient alloc] initWithStartingColor:NSColor.yellowColor endingColor:NSColor.redColor] autorelease];
    [g drawInRect:NSMakeRect(4, 4, 56, 36) relativeCenterPosition:NSMakePoint(0, 0)];
    [g drawInRect:NSMakeRect(4, 44, 56, 16) relativeCenterPosition:NSMakePoint(0.5, -0.5)];
}

static void
s_rep_draw(void)
{
    fill_white();
    [NSGraphicsContext currentContext].imageInterpolation = NSImageInterpolationNone;
    NSBitmapImageRep *r = checker_rep(16, 4);
    [r drawInRect:NSMakeRect(4, 4, 32, 32)];
    [r drawAtPoint:NSMakePoint(42, 42)];
    [r drawInRect:NSMakeRect(40, 4, 20, 32) fromRect:NSMakeRect(4, 4, 8, 8) operation:NSCompositingOperationSourceOver fraction:0.6
        respectFlipped:NO hints:nil];
}

static void
s_image_draw(void)
{
    fill_white();
    [NSGraphicsContext currentContext].imageInterpolation = NSImageInterpolationNone;
    NSImage *i = [[[NSImage alloc] init] autorelease];
    [i addRepresentation:checker_rep(16, 4)];
    /* (whole-number scales: CG's nearest-neighbour sampling at other scales is CoreGraphics' business) */
    [i drawInRect:NSMakeRect(0, 0, 32, 32) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [i drawInRect:NSMakeRect(36, 0, 16, 32) fromRect:NSMakeRect(0, 0, 8, 16) operation:NSCompositingOperationCopy fraction:0.5];
    [i drawAtPoint:NSMakePoint(4, 40) fromRect:NSMakeRect(4, 4, 12, 12) operation:NSCompositingOperationSourceOver fraction:1];
    i.size = NSMakeSize(8, 8);
    [i drawAtPoint:NSMakePoint(40, 44) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [i drawInRect:NSMakeRect(52, 40, 8, 16)];
}

static void
s_image_flipped(void)
{
    fill_white();
    NSGraphicsContext *g = [NSGraphicsContext currentContext];
    CGContextRef c = g.CGContext;
    NSGraphicsContext *flipped = [NSGraphicsContext graphicsContextWithCGContext:c flipped:YES];
    [NSGraphicsContext setCurrentContext:flipped];
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, SIZE);
    CGContextScaleCTM(c, 1, -1);
    flipped.imageInterpolation = NSImageInterpolationNone;
    NSImage *i = [[[NSImage alloc] init] autorelease];
    [i addRepresentation:checker_rep(16, 4)];
    [i drawInRect:NSMakeRect(2, 2, 28, 28) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [i drawInRect:NSMakeRect(34, 2, 28, 28) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:nil];
    [i drawInRect:NSMakeRect(2, 34, 28, 28)];
    [[NSColor colorWithSRGBRed:0.9 green:0.1 blue:0.1 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRect:NSMakeRect(36, 36, 20, 8)] fill];
    CGContextRestoreGState(c);
    [NSGraphicsContext setCurrentContext:g];
}

static void
s_template(void)
{
    fill_white();
    NSImage *i = [[[NSImage alloc] init] autorelease];
    [i addRepresentation:checker_rep(16, 2)];
    i.template = YES;
    [i drawInRect:NSMakeRect(8, 8, 48, 48) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.8];
}

static void
s_pattern_color(void)
{
    NSImage *i = [[[NSImage alloc] init] autorelease];
    [i addRepresentation:checker_rep(8, 2)];
    [[NSColor colorWithPatternImage:i] set];
    NSRectFill(NSMakeRect(0, 0, SIZE, SIZE));
}

static void
s_bitmap_context(void)
{
    NSBitmapImageRep *r = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:32 pixelsHigh:32 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:r]];
    [[NSColor colorWithDeviceRed:0.9 green:0.9 blue:0.2 alpha:1] set];
    NSRectFill(NSMakeRect(0, 0, 32, 32));
    [[NSColor colorWithDeviceRed:0.1 green:0.3 blue:0.8 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4, 4, 24, 16)] fill];
    [NSGraphicsContext restoreGraphicsState];
    fill_white();
    [NSGraphicsContext currentContext].imageInterpolation = NSImageInterpolationNone;
    [r drawInRect:NSMakeRect(0, 0, 64, 64)];
    NSBitmapImageRep *g = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:16 pixelsHigh:16 bitsPerSample:8
        samplesPerPixel:1 hasAlpha:NO isPlanar:NO colorSpaceName:NSCalibratedWhiteColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:g]];
    [[NSColor colorWithCalibratedWhite:0.8 alpha:1] set];
    NSRectFill(NSMakeRect(0, 0, 16, 16));
    [[NSColor colorWithCalibratedWhite:0.1 alpha:1] set];
    NSRectFill(NSMakeRect(2, 2, 6, 10));
    [NSGraphicsContext restoreGraphicsState];
    [g drawInRect:NSMakeRect(44, 44, 16, 16)];
}

static void
s_tiled(void)
{
    fill_white();
    NSRectEdge sides[] = {NSRectEdgeMaxX, NSRectEdgeMinY, NSRectEdgeMinX, NSRectEdgeMaxY, NSRectEdgeMaxX, NSRectEdgeMinY};
    CGFloat grays[] = {0, 0, 1, 1, 0.33, 0.33};
    NSRect rem = NSDrawTiledRects(NSMakeRect(8, 8, 48, 48), NSMakeRect(0, 0, 40, 64), sides, grays, 6);
    [[NSColor colorWithSRGBRed:0.4 green:0.6 blue:0.8 alpha:1] set];
    NSRectFill(rem);
    NSColor *cols[] = {NSColor.redColor, NSColor.greenColor, NSColor.blueColor, NSColor.yellowColor};
    NSDrawColorTiledRects(NSMakeRect(44, 2, 18, 18), NSMakeRect(0, 0, 64, 64), sides, cols, 4);
}

static void
s_custom_rep(void)
{
    fill_white();
    NSImage *i = [NSImage imageWithSize:NSMakeSize(20, 20) flipped:NO drawingHandler:^BOOL(NSRect dst) {
        [[NSColor colorWithSRGBRed:0.9 green:0.2 blue:0.2 alpha:1] set];
        NSRectFill(NSMakeRect(0, 0, 10, 20));
        [[NSColor colorWithSRGBRed:0.2 green:0.2 blue:0.9 alpha:1] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(8, 2, 10, 10)] fill];
        return YES;
    }];
    [i drawInRect:NSMakeRect(4, 4, 40, 40)];
    NSImage *f = [NSImage imageWithSize:NSMakeSize(20, 20) flipped:YES drawingHandler:^BOOL(NSRect dst) {
        [[NSColor colorWithSRGBRed:0.1 green:0.6 blue:0.1 alpha:1] set];
        NSRectFill(NSMakeRect(0, 0, 20, 6));
        return YES;
    }];
    [f drawInRect:NSMakeRect(44, 4, 16, 56)];
}

static void
s_flipped_paths(void)
{
    fill_white();
    NSGraphicsContext *g = [NSGraphicsContext currentContext];
    CGContextRef c = g.CGContext;
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:c flipped:YES]];
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, SIZE);
    CGContextScaleCTM(c, 1, -1);
    [[NSColor colorWithSRGBRed:0.2 green:0.5 blue:0.8 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(4, 4, 40, 20) xRadius:6 yRadius:6] fill];
    [[NSColor colorWithSRGBRed:0.8 green:0.2 blue:0.2 alpha:1] set];
    NSRectFill(NSMakeRect(40, 30, 20, 30));
    NSGradient *gr = [[[NSGradient alloc] initWithStartingColor:NSColor.blackColor endingColor:NSColor.whiteColor] autorelease];
    [gr drawInRect:NSMakeRect(4, 30, 30, 30) angle:90];
    CGContextRestoreGState(c);
    [NSGraphicsContext setCurrentContext:g];
}

static void
s_colors(void)
{
    fill_white();
    NSColor *cs[] = {
        [NSColor colorWithCalibratedRed:0.8 green:0.3 blue:0.1 alpha:1], [NSColor colorWithDeviceRed:0.8 green:0.3 blue:0.1 alpha:1],
        [NSColor colorWithDisplayP3Red:0.8 green:0.3 blue:0.1 alpha:1], [NSColor colorWithCalibratedWhite:0.4 alpha:1],
        [NSColor colorWithDeviceWhite:0.4 alpha:1], [NSColor colorWithWhite:0.4 alpha:1], NSColor.systemBlueColor, NSColor.labelColor,
        NSColor.controlAccentColor, [NSColor.systemGreenColor colorWithAlphaComponent:0.5], NSColor.selectedTextBackgroundColor,
        [NSColor colorWithHue:0.7 saturation:0.6 brightness:0.8 alpha:1], NSColor.orangeColor, NSColor.brownColor,
        [NSColor.redColor blendedColorWithFraction:0.5 ofColor:NSColor.blueColor], [NSColor.blueColor highlightWithLevel:0.4],
    };
    for (int i = 0; i < 16; i++) {
        [cs[i] set];
        NSRectFill(NSMakeRect((i % 4) * 16, (i / 4) * 16, 16, 16));
    }
}

static void
s_transform_set(void)
{
    fill_white();
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:10 yBy:40];
    [t rotateByDegrees:-20];
    [t set];
    [[NSColor colorWithSRGBRed:0.9 green:0.5 blue:0.1 alpha:1] set];
    NSRectFill(NSMakeRect(0, 0, 30, 12));
    [NSGraphicsContext restoreGraphicsState];
    NSRect rects[3] = {{{2, 2}, {12, 12}}, {{18, 2}, {12, 12}}, {{34, 2}, {12, 12}}};
    NSColor *colors[3] = {NSColor.redColor, [NSColor colorWithSRGBRed:0 green:0.5 blue:0 alpha:0.5], NSColor.blueColor};
    NSRectFillListWithColors(rects, colors, 3);
    NSRect more[2] = {{{50, 2}, {12, 12}}, {{50, 18}, {12, 12}}};
    CGFloat grays[2] = {0.2, 0.7};
    NSRectFillListWithGrays(more, grays, 2);
    [[NSColor colorWithSRGBRed:0.2 green:0.2 blue:0.8 alpha:0.5] set];
    NSRectFillListUsingOperation(rects, 2, NSCompositingOperationSourceOver);
}

typedef struct {
    const char *name;
    SceneFn fn;
} Scene;

static const Scene scenes[] = {
    {"rect fills", s_rect_fill},
    {"frames and erase", s_frames},
    {"compositing operations", s_operations},
    {"path fills", s_paths_fill},
    {"path strokes", s_paths_stroke},
    {"arcs", s_arcs},
    {"clipping", s_clip},
    {"transforms", s_transform},
    {"gradient at an angle", s_gradient_angle},
    {"gradient in a path", s_gradient_path},
    {"radial gradient", s_gradient_radial},
    {"radial gradient in rects", s_gradient_radial_rect},
    {"bitmap rep drawing", s_rep_draw},
    {"image drawing", s_image_draw},
    {"image in a flipped context", s_image_flipped},
    {"template image", s_template},
    {"pattern colour", s_pattern_color},
    {"drawing into bitmap reps", s_bitmap_context},
    {"tiled rects", s_tiled},
    {"drawing handler images", s_custom_rep},
    {"paths in a flipped context", s_flipped_paths},
    {"colour spaces", s_colors},
    {"transform -set and fill lists", s_transform_set},
};
#define NSCENES (sizeof scenes / sizeof scenes[0])

static unsigned char *
render(const Scene *s)
{
    CGContextRef c = rgba_context(SIZE, SIZE);
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithCGContext:c flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:g];
    @autoreleasepool {
        s->fn();
    }
    [NSGraphicsContext restoreGraphicsState];
    unsigned char *out = malloc(SIZE * SIZE * 4);
    const unsigned char *d = CGBitmapContextGetData(c);
    for (int y = 0; y < SIZE; y++)
        memcpy(out + y * SIZE * 4, d + y * CGBitmapContextGetBytesPerRow(c), SIZE * 4);
    CGContextRelease(c);
    return out;
}

static int
compare(const char *name, const unsigned char *ref, const unsigned char *got)
{
    int interior_max = 0, edges = 0, bad = 0;
    double edge_sum = 0;
    for (int y = 0; y < SIZE; y++)
        for (int x = 0; x < SIZE; x++) {
            const unsigned char *r = ref + 4 * (y * SIZE + x), *g = got + 4 * (y * SIZE + x);
            int flat = 1;
            for (int dy = -1; dy <= 1 && flat; dy++)
                for (int dx = -1; dx <= 1 && flat; dx++) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= SIZE || ny >= SIZE)
                        continue;
                    flat = !memcmp(r, ref + 4 * (ny * SIZE + nx), 4);
                }
            int diff = 0;
            for (int k = 0; k < 4; k++)
                diff = abs(r[k] - g[k]) > diff ? abs(r[k] - g[k]) : diff;
            if (flat) {
                interior_max = diff > interior_max ? diff : interior_max;
            } else {
                edges++;
                edge_sum += diff;
                bad += diff > 96;
            }
        }
    if (getenv("APPKIT_DRAW_DUMP") && strstr(name, getenv("APPKIT_DRAW_DUMP")))
        for (int y = 0; y < SIZE; y++) {
            for (int x = 0; x < SIZE; x++) {
                const unsigned char *p = ref + 4 * (y * SIZE + x);
                putchar(" .:-=+*#%@"[(p[0] + p[1] + p[2]) * 9 / 765]);
            }
            printf("   ");
            for (int x = 0; x < SIZE; x++) {
                const unsigned char *p = got + 4 * (y * SIZE + x);
                putchar(" .:-=+*#%@"[(p[0] + p[1] + p[2]) * 9 / 765]);
            }
            printf("\n");
        }
    double edge_mean = edges ? edge_sum / edges : 0;
    int ok = interior_max <= 2 && edge_mean <= 16 && bad <= edges / 50 + 1;
    if (ok)
        printf("%s: ok\n", name);
    else
        printf("%s: DIFFERS (flat max %d, edge mean %.1f, edge outliers %d of %d)\n", name, interior_max, edge_mean, bad, edges);
    return ok;
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        const char *write = NULL, *ref_path = NULL;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--write") && i + 1 < argc)
                write = argv[++i];
            else
                ref_path = argv[i];
        }
        const char *image = class_getImageName([NSColor class]);
        printf("AppKit: %s\n", image ? image : "?");
        size_t one = SIZE * SIZE * 4, total = one * NSCENES;
        if (write) {
            if (strncmp(image, "/System/", 8)) {
                fprintf(stderr, "references come from Apple's AppKit (this is %s)\n", image);
                return 1;
            }
            unsigned char *all = malloc(total);
            for (size_t i = 0; i < NSCENES; i++) {
                unsigned char *px = render(&scenes[i]);
                memcpy(all + i * one, px, one);
                free(px);
            }
            uLongf zlen = compressBound(total);
            unsigned char *z = malloc(zlen);
            compress2(z, &zlen, all, total, 9);
            FILE *f = fopen(write, "wb");
            fwrite(z, 1, zlen, f);
            fclose(f);
            printf("wrote %zu scenes (%lu bytes)\n", NSCENES, (unsigned long)zlen);
            return 0;
        }
        constants();
        graphics_context();
        color_spaces();
        colors();
        bezier_paths();
        gradients();
        image_reps();
        images();
        graphics_functions();

        header("scenes");
        if (!ref_path)
            ref_path = "/usr/local/share/finch/appkit-draw-reference.bin";
        FILE *f = fopen(ref_path, "rb");
        if (!f) {
            printf("no reference at %s\n", ref_path);
            return 1;
        }
        fseek(f, 0, SEEK_END);
        long zlen = ftell(f);
        fseek(f, 0, SEEK_SET);
        unsigned char *z = malloc((size_t)zlen), *all = malloc(total);
        fread(z, 1, (size_t)zlen, f);
        fclose(f);
        uLongf len = total;
        if (uncompress(all, &len, z, (uLong)zlen) != Z_OK || len != total) {
            printf("reference doesn't match these scenes: regenerate it with --write\n");
            return 1;
        }
        int failures = 0;
        for (size_t i = 0; i < NSCENES; i++) {
            unsigned char *px = render(&scenes[i]);
            failures += !compare(scenes[i].name, all + i * one, px);
            free(px);
        }
        return failures ? 1 : 0;
    }
}
