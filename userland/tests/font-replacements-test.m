/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch-only checks for the fonts used in place of Apple's. Run in the VM,
 * or on the host with DYLD_FRAMEWORK_PATH pointing at Finch's frameworks
 * (including PrivateFrameworks) and FINCH_FONT_DIRS at Finch's font folder.
 *
 * Check the public font APIs, real glyphs and outlines, weight selection,
 * rounded system descriptors, and the real styles used when a replacement
 * lacks italic or bold. This test does not need a window server.
 */
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include <math.h>
#include <stdio.h>

static unsigned checks, failures;

static void
check(BOOL ok, NSString *what)
{
    checks++;
    if (!ok) {
        failures++;
        printf("FAIL %s\n", what.UTF8String);
    }
}

static NSString *
font_name(CTFontRef font)
{
    return font ? CFBridgingRelease(CTFontCopyPostScriptName(font)) : nil;
}

static void
check_name(CTFontRef font, NSString *expected, NSString *label)
{
    NSString *actual = font_name(font);
    check([actual isEqualToString:expected],
          [NSString stringWithFormat:@"%@: expected %@, got %@", label, expected, actual]);
}

/* Check actual font data as well as the name. Missing or broken font files
 * must fail even if a name still appears in the font list. */
static void
check_glyphs(CTFontRef font, NSString *label)
{
    UniChar letters[] = {'A', 'g', '0'};
    CGGlyph glyphs[3] = {0};
    BOOL mapped = font && CTFontGetGlyphsForCharacters(font, letters, glyphs, 3);
    check(mapped && glyphs[0] && glyphs[1] && glyphs[2],
          [label stringByAppendingString:@": basic letters have glyphs"]);
    if (!mapped)
        return;
    CGPathRef path = CTFontCreatePathForGlyph(font, glyphs[0], NULL);
    check(path && !CGPathIsEmpty(path), [label stringByAppendingString:@": A has an outline"]);
    if (path)
        CGPathRelease(path);
    CGSize advances[3] = {{0}};
    double width = CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, glyphs, advances, 3);
    check(width > 0 && advances[0].width > 0 && advances[1].width > 0 && advances[2].width > 0,
          [label stringByAppendingString:@": letters have usable widths"]);
}

static void
check_named_font(NSString *requested, NSString *expected)
{
    CTFontRef ct = CTFontCreateWithName((__bridge CFStringRef)requested, 17, NULL);
    CGFontRef cg = CGFontCreateWithFontName((__bridge CFStringRef)requested);
    NSFont *ns = [NSFont fontWithName:requested size:17];
    check_name(ct, expected, [requested stringByAppendingString:@" through CoreText"]);
    NSString *cgName = cg ? CFBridgingRelease(CGFontCopyPostScriptName(cg)) : nil;
    check([cgName isEqualToString:expected],
          [NSString stringWithFormat:@"%@ through CoreGraphics: expected %@, got %@", requested, expected, cgName]);
    check([ns.fontName isEqualToString:expected],
          [NSString stringWithFormat:@"%@ through NSFont: expected %@, got %@", requested, expected, ns.fontName]);
    check(ct && ns && fabs(CTFontGetSize(ct) - 17) < 1e-6 && fabs(ns.pointSize - 17) < 1e-6,
          [requested stringByAppendingString:@": point size stays 17"]);
    check_glyphs(ct, requested);

    /* Both text paths must use the same installed face and widths. */
    if (ct && cg) {
        CFDataRef ctHead = CTFontCopyTable(ct, kCTFontTableHead, kCTFontTableOptionNoOptions);
        CFDataRef cgHead = CGFontCopyTableForTag(cg, kCTFontTableHead);
        check(ctHead && cgHead && CFDataGetLength(ctHead) > 0 && CFEqual(ctHead, cgHead),
              [requested stringByAppendingString:@": CoreText and CoreGraphics load the same font data"]);
        UniChar letter = 'A';
        CGGlyph glyph = 0;
        int cgAdvance = 0;
        CGSize ctAdvance = CGSizeZero;
        BOOL mapped = CTFontGetGlyphsForCharacters(ct, &letter, &glyph, 1);
        BOOL advanced = CGFontGetGlyphAdvances(cg, &glyph, 1, &cgAdvance);
        CTFontGetAdvancesForGlyphs(ct, kCTFontOrientationHorizontal, &glyph, &ctAdvance, 1);
        unsigned em = (unsigned)CGFontGetUnitsPerEm(cg);
        check(mapped && advanced && em > 0 && fabs(ctAdvance.width - (double)cgAdvance * 17 / em) < 1e-6,
              [requested stringByAppendingString:@": CoreText and CoreGraphics agree on glyph width"]);
        if (ctHead)
            CFRelease(ctHead);
        if (cgHead)
            CFRelease(cgHead);
    }
    if (ct)
        CFRelease(ct);
    if (cg)
        CGFontRelease(cg);
}

static void
named_fonts(void)
{
    const struct {
        NSString *request, *expected;
    } cases[] = {
        {@"SF Pro", @"Inter-Regular"},
        {@"SF Pro Rounded", @"OpenRunde-Regular"},
        {@"SF Mono", @"FragmentMono-Regular"},
        {@"SFMono-RegularItalic", @"FragmentMono-Italic"},
        {@"Charter", @"XCharter-Roman"},
        {@"Charter-Bold", @"XCharter-Bold"},
        {@"Charter-Italic", @"XCharter-Italic"},
        {@"Charter-BoldItalic", @"XCharter-BoldItalic"},
        {@"Palatino", @"TeXGyrePagella-Regular"},
        {@"Palatino-Bold", @"TeXGyrePagella-Bold"},
        {@"Palatino-Italic", @"TeXGyrePagella-Italic"},
        {@"Palatino-BoldItalic", @"TeXGyrePagella-BoldItalic"},
        /* These families keep their previous fonts. */
        {@"Helvetica", @"LiberationSans"},
        {@"Helvetica-Bold", @"LiberationSans-Bold"},
        {@"Helvetica-Oblique", @"LiberationSans-Italic"},
        {@"Helvetica-BoldOblique", @"LiberationSans-BoldItalic"},
        {@"Arial", @"LiberationSans"},
        {@"Times", @"LiberationSerif"},
        {@"Courier", @"LiberationMono"},
        {@"Menlo", @"DejaVuSansMono"},
        {@"Inter-Regular", @"Inter-Regular"},
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++)
        check_named_font(cases[i].request, cases[i].expected);
}

static void
system_fonts(void)
{
    const struct {
        NSFontWeight weight;
        NSString *expected;
    } weights[] = {
        {NSFontWeightUltraLight, @"Inter-ExtraLight"},
        {NSFontWeightThin, @"Inter-Thin"},
        {NSFontWeightLight, @"Inter-Light"},
        {NSFontWeightRegular, @"Inter-Regular"},
        {NSFontWeightMedium, @"Inter-Medium"},
        {NSFontWeightSemibold, @"Inter-SemiBold"},
        {NSFontWeightBold, @"Inter-Bold"},
        {NSFontWeightHeavy, @"Inter-ExtraBold"},
        {NSFontWeightBlack, @"Inter-Black"},
    };
    for (unsigned i = 0; i < sizeof weights / sizeof weights[0]; i++) {
        NSFont *font = [NSFont systemFontOfSize:17 weight:weights[i].weight];
        check_name((__bridge CTFontRef)font, weights[i].expected, @"weighted system font");
        check_glyphs((__bridge CTFontRef)font, weights[i].expected);
        check(fabs(font.pointSize - 17) < 1e-6, @"weighted system font keeps its requested size");
    }
    CTFontRef system = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 17, NULL);
    CTFontRef emphasized = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 17, NULL);
    check_name(system, @"Inter-Regular", @"CoreText system font");
    check_name(emphasized, @"Inter-Bold", @"CoreText emphasized system font");
    if (system)
        CFRelease(system);
    if (emphasized)
        CFRelease(emphasized);

    const struct {
        NSFontWeight weight;
        NSString *expected;
    } rounded[] = {
        {NSFontWeightRegular, @"OpenRunde-Regular"},
        {NSFontWeightMedium, @"OpenRunde-Medium"},
        {NSFontWeightSemibold, @"OpenRunde-Semibold"},
        {NSFontWeightBold, @"OpenRunde-Bold"},
    };
    for (unsigned i = 0; i < sizeof rounded / sizeof rounded[0]; i++) {
        NSFont *base = [NSFont systemFontOfSize:17 weight:rounded[i].weight];
        NSFontDescriptor *descriptor = [base.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
        check(descriptor != nil, @"system font offers a rounded descriptor");
        NSFont *font = [NSFont fontWithDescriptor:descriptor size:17];
        check_name((__bridge CTFontRef)font, rounded[i].expected, @"rounded system descriptor");
        check_glyphs((__bridge CTFontRef)font, rounded[i].expected);
    }
    NSFont *mono = [NSFont monospacedSystemFontOfSize:17 weight:NSFontWeightRegular];
    NSFont *monoBold = [NSFont monospacedSystemFontOfSize:17 weight:NSFontWeightBold];
    check_name((__bridge CTFontRef)mono, @"FragmentMono-Regular", @"monospaced system font");
    check_name((__bridge CTFontRef)monoBold, @"DejaVuSansMono-Bold", @"bold monospaced system font");
    check(mono.isFixedPitch && monoBold.isFixedPitch, @"both monospaced system styles stay fixed width");
}

static void
system_descriptors(void)
{
    NSFontDescriptor *system = [NSFont systemFontOfSize:17].fontDescriptor;
    NSFontDescriptor *rounded = [system fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    NSFontDescriptor *bold = [rounded fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitBold];
    NSFont *boldFont = [NSFont fontWithDescriptor:bold size:17];
    check_name((__bridge CTFontRef)boldFont, @"OpenRunde-Bold", @"rounded descriptor adds bold");
    NSFontDescriptor *plain = [bold fontDescriptorWithSymbolicTraits:0];
    NSFont *plainFont = [NSFont fontWithDescriptor:plain size:17];
    check_name((__bridge CTFontRef)plainFont, @"OpenRunde-Regular", @"rounded descriptor removes bold");

    NSFont *resized = [boldFont fontWithSize:23];
    check_name((__bridge CTFontRef)resized, @"OpenRunde-Bold", @"resizing keeps the rounded bold face");
    check(fabs(resized.pointSize - 23) < 1e-6, @"resizing a rounded font applies the new size");
    NSFontDescriptor *back = [resized.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignDefault];
    NSFont *defaultFont = [NSFont fontWithDescriptor:back size:0];
    check_name((__bridge CTFontRef)defaultFont, @"Inter-Bold", @"resized rounded font can return to the default design");
    check(fabs(defaultFont.pointSize - 23) < 1e-6, @"changing the design preserves the resized point size");

    NSFontDescriptor *italic = [system fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitItalic];
    NSFont *italicFont = [NSFont fontWithDescriptor:italic size:17];
    check_name((__bridge CTFontRef)italicFont, @"Inter-Italic", @"system descriptor requests a real italic face");
    NSFontDescriptor *systemBold = [NSFont boldSystemFontOfSize:17].fontDescriptor;
    NSFontDescriptor *boldItalic = [systemBold fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitBold | NSFontDescriptorTraitItalic];
    NSFont *boldItalicFont = [NSFont fontWithDescriptor:boldItalic size:17];
    check_name((__bridge CTFontRef)boldItalicFont, @"Inter-BoldItalic", @"system descriptor requests a real bold italic face");
    check([rounded fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitItalic] == nil,
          @"rounded italic is unavailable instead of silently returning an upright face");
}

static void
font_manager_styles(void)
{
    NSFontManager *manager = [NSFontManager sharedFontManager];
    NSFont *italic = [manager convertFont:[NSFont systemFontOfSize:17] toHaveTrait:NSItalicFontMask];
    check_name((__bridge CTFontRef)italic, @"Inter-Italic", @"NSFontManager adds system italic");
    check(([manager traitsOfFont:italic] & NSItalicFontMask) != 0,
          @"NSFontManager system italic has the italic style");
    NSFont *mono = [NSFont monospacedSystemFontOfSize:17 weight:NSFontWeightRegular];
    NSFont *bold = [manager convertFont:mono toHaveTrait:NSBoldFontMask];
    check_name((__bridge CTFontRef)bold, @"DejaVuSansMono-Bold", @"NSFontManager adds monospaced bold");
    check(bold.isFixedPitch && ([manager traitsOfFont:bold] & NSBoldFontMask) != 0,
          @"NSFontManager monospaced bold keeps fixed widths and bold style");
}

static void
trait_conversion(NSString *base, CTFontSymbolicTraits traits, NSString *expected)
{
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)base, 17, NULL);
    CTFontRef changed = font ? CTFontCreateCopyWithSymbolicTraits(font, 0, NULL, traits, traits) : NULL;
    NSString *label = [NSString stringWithFormat:@"%@ adding traits 0x%x", base, traits];
    check_name(changed, expected, label);
    check(changed && (CTFontGetSymbolicTraits(changed) & traits) == traits,
          [label stringByAppendingString:@": the requested style is present"]);
    check(changed && fabs(CTFontGetSize(changed) - 17) < 1e-6,
          [label stringByAppendingString:@": size is preserved"]);
    check_glyphs(changed, label);
    if (changed)
        CFRelease(changed);
    if (font)
        CFRelease(font);
}

int
main(void)
{
    @autoreleasepool {
        named_fonts();
        system_fonts();
        system_descriptors();
        font_manager_styles();
        trait_conversion(@"Inter-Regular", kCTFontTraitItalic, @"Inter-Italic");
        trait_conversion(@"Inter-Bold", kCTFontTraitItalic, @"Inter-BoldItalic");
        trait_conversion(@"FragmentMono-Regular", kCTFontTraitBold, @"DejaVuSansMono-Bold");
        trait_conversion(@"FragmentMono-Italic", kCTFontTraitBold, @"DejaVuSansMono-BoldOblique");
        trait_conversion(@"Charter", kCTFontTraitBold | kCTFontTraitItalic, @"XCharter-BoldItalic");
        trait_conversion(@"Palatino", kCTFontTraitBold | kCTFontTraitItalic, @"TeXGyrePagella-BoldItalic");
        printf("font replacements: %u checks, %u failures\n", checks, failures);
    }
    return failures ? 1 : 0;
}
