/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-ct-test: CoreText behaviour, one result per line, so a run against
 * Apple's CoreText (on the host) and one against Finch's can be diffed.
 * Fonts come from files both systems have (Skia's open test fonts), not
 * from the system font set, which differs.
 *
 *   fonts: metrics, names, glyphs, advances, bounds, outlines, traits,
 *   descriptors, tables; lines and runs: shaping (kerning, ligatures),
 *   positions, string indices, typographic bounds, carets and hit testing,
 *   attributes.
 */
#include <CoreText/CoreText.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
str(const char *label, CFStringRef s)
{
    char buf[512] = "NULL";
    if (s)
        CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    printf("%s: %s\n", label, buf);
}

static CGFontRef
cgfont(const char *file)
{
    const char *dirs[] = {getenv("FINCH_TEST_FONTS"), "/usr/local/share/finch/test-fonts",
                          "build/src/skia/resources/fonts", "../../build/src/skia/resources/fonts"};
    for (unsigned i = 0; i < sizeof dirs / sizeof dirs[0]; i++) {
        if (!dirs[i])
            continue;
        char path[1024];
        snprintf(path, sizeof path, "%s/%s", dirs[i], file);
        CGDataProviderRef p = CGDataProviderCreateWithFilename(path);
        if (p) {
            CGFontRef f = CGFontCreateWithDataProvider(p);
            CGDataProviderRelease(p);
            return f;
        }
    }
    fprintf(stderr, "no test font %s\n", file);
    exit(1);
}

static const char *
g(double v)
{
    static char bufs[16][32];
    static int n;
    char *b = bufs[n++ & 15];
    if (fabs(v) < 5e-7)
        v = 0;
    snprintf(b, 32, "%.6g", v);
    return b;
}

static void
rect(const char *label, CGRect r)
{
    printf("%s: {%s, %s, %s, %s}\n", label, g(r.origin.x), g(r.origin.y), g(r.size.width), g(r.size.height));
}

static void
path_summary(void *info, const CGPathElement *e)
{
    int *counts = info;
    counts[e->type]++;
}

static void
fonts(CTFontRef f)
{
    printf("type: %d\n", CFGetTypeID(f) == CTFontGetTypeID());
    printf("size %s upem %u glyphs %ld\n", g(CTFontGetSize(f)), CTFontGetUnitsPerEm(f), (long)CTFontGetGlyphCount(f));
    printf("ascent %s descent %s leading %s cap %s x %s\n", g(CTFontGetAscent(f)), g(CTFontGetDescent(f)),
           g(CTFontGetLeading(f)), g(CTFontGetCapHeight(f)), g(CTFontGetXHeight(f)));
    printf("underline %s %s slant %s\n", g(CTFontGetUnderlinePosition(f)), g(CTFontGetUnderlineThickness(f)),
           g(CTFontGetSlantAngle(f)));
    rect("bounding box", CTFontGetBoundingBox(f));
    CGAffineTransform m = CTFontGetMatrix(f);
    printf("matrix [%s %s %s %s %s %s]\n", g(m.a), g(m.b), g(m.c), g(m.d), g(m.tx), g(m.ty));
    str("postscript", CTFontCopyPostScriptName(f));
    str("family", CTFontCopyFamilyName(f));
    str("full", CTFontCopyFullName(f));
    str("display", CTFontCopyDisplayName(f));
    CFStringRef keys[] = {kCTFontCopyrightNameKey, kCTFontFamilyNameKey, kCTFontSubFamilyNameKey, kCTFontStyleNameKey,
                          kCTFontUniqueNameKey, kCTFontFullNameKey, kCTFontVersionNameKey, kCTFontPostScriptNameKey,
                          kCTFontTrademarkNameKey, kCTFontManufacturerNameKey, kCTFontDesignerNameKey,
                          kCTFontLicenseNameKey, kCTFontLicenseURLNameKey, kCTFontSampleTextNameKey};
    for (unsigned i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        char l[128];
        CFStringGetCString(keys[i], l, sizeof l, kCFStringEncodingUTF8);
        str(l, CTFontCopyName(f, keys[i]));
    }
    printf("symbolic traits 0x%x\n", CTFontGetSymbolicTraits(f));
    CFDictionaryRef traits = CTFontCopyTraits(f);
    CFTypeRef tk[] = {kCTFontSymbolicTrait, kCTFontWeightTrait, kCTFontWidthTrait, kCTFontSlantTrait};
    for (unsigned i = 0; i < 4; i++) {
        CFTypeRef v = traits ? CFDictionaryGetValue(traits, tk[i]) : NULL;
        double d = 0;
        if (v)
            CFNumberGetValue(v, kCFNumberDoubleType, &d);
        char l[64];
        CFStringGetCString(tk[i], l, sizeof l, kCFStringEncodingUTF8);
        printf("trait %s: %s\n", l, v ? g(d) : "none");
    }
    UniChar chars[] = {'H', 'e', 'l', 'o', ' ', 'A', 'V', 'f', 'i', 0x00e9, 0x4e00, '1'};
    CGGlyph glyphs[12];
    printf("all glyphs found: %d\n", CTFontGetGlyphsForCharacters(f, chars, glyphs, 12));
    printf("glyphs:");
    for (int i = 0; i < 12; i++)
        printf(" %d", glyphs[i]);
    printf("\n");
    CGSize adv[12];
    double total = CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, glyphs, adv, 12);
    printf("advances (total %s):", g(total));
    for (int i = 0; i < 12; i++)
        printf(" %s", g(adv[i].width));
    printf("\n");
    CGRect boxes[12];
    CGRect all = CTFontGetBoundingRectsForGlyphs(f, kCTFontOrientationHorizontal, glyphs, boxes, 12);
    rect("glyph bounds union", all);
    for (int i = 0; i < 12; i += 4)
        rect("  glyph bounds", boxes[i]);
    CGPathRef p = CTFontCreatePathForGlyph(f, glyphs[0], NULL);
    int counts[5] = {0};
    CGPathApply(p, counts, path_summary);
    printf("path for H: move %d line %d quad %d curve %d close %d\n", counts[0], counts[1], counts[2], counts[3],
           counts[4]);
    rect("path for H bounds", CGPathGetBoundingBox(p));
    CGPathRelease(p);
    str("name for glyph", CTFontCopyNameForGlyph(f, glyphs[0]));
    CFArrayRef tables = CTFontCopyAvailableTables(f, kCTFontTableOptionNoOptions);
    printf("tables: %ld, has 'kern' %d, has 'GPOS' %d\n", tables ? (long)CFArrayGetCount(tables) : -1L,
           CTFontHasTable(f, 'kern'), CTFontHasTable(f, 'GPOS'));
    CFDataRef head = CTFontCopyTable(f, 'head', kCTFontTableOptionNoOptions);
    printf("head %ld bytes\n", head ? (long)CFDataGetLength(head) : -1L);
    CFStringRef ps = CTFontCopyPostScriptName(f);
    CTFontRef bigger = CTFontCreateCopyWithAttributes(f, 36, NULL, NULL);
    printf("copy size %s ascent %s\n", g(CTFontGetSize(bigger)), g(CTFontGetAscent(bigger)));
    CGAffineTransform skew = CGAffineTransformMake(1, 0, 0.2, 1, 0, 0);
    CTFontRef skewed = CTFontCreateCopyWithAttributes(f, 0, &skew, NULL);
    printf("copy with matrix size %s\n", g(CTFontGetSize(skewed)));
    CGRect sb = CTFontGetBoundingRectsForGlyphs(skewed, kCTFontOrientationHorizontal, glyphs, NULL, 1);
    rect("skewed H bounds", sb);
    CTFontDescriptorRef d = CTFontCopyFontDescriptor(f);
    str("descriptor name", CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute));
    CFNumberRef dsize = CTFontDescriptorCopyAttribute(d, kCTFontSizeAttribute);
    double dsz = -1;
    if (dsize)
        CFNumberGetValue(dsize, kCFNumberDoubleType, &dsz);
    printf("descriptor size %s\n", g(dsz));
    str("descriptor family", CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute));
    CFRelease(ps);
    CGFontRef back = CTFontCopyGraphicsFont(f, NULL);
    printf("graphics font round trip: %d\n", back != NULL);
}

static CFAttributedStringRef
attributed(const char *text, CTFontRef font, CFDictionaryRef extra)
{
    CFStringRef s = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    CFMutableDictionaryRef attrs = extra ? CFDictionaryCreateMutableCopy(NULL, 0, extra)
                                         : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                     &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCTFontAttributeName, font);
    CFAttributedStringRef a = CFAttributedStringCreate(NULL, s, attrs);
    CFRelease(s);
    CFRelease(attrs);
    return a;
}

static void
line_info(const char *label, CTLineRef line)
{
    CGFloat ascent, descent, leading;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CFRange r = CTLineGetStringRange(line);
    printf("%s: width %s ascent %s descent %s leading %s glyphs %ld range %ld+%ld trailing ws %s\n", label, g(width),
           g(ascent), g(descent), g(leading), (long)CTLineGetGlyphCount(line), (long)r.location, (long)r.length,
           g(CTLineGetTrailingWhitespaceWidth(line)));
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex i = 0; i < CFArrayGetCount(runs); i++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, i);
        CFIndex n = CTRunGetGlyphCount(run);
        CFRange rr = CTRunGetStringRange(run);
        double rw = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), NULL, NULL, NULL);
        printf("  run %ld: %ld glyphs range %ld+%ld status 0x%x width %s\n", (long)i, (long)n, (long)rr.location,
               (long)rr.length, CTRunGetStatus(run), g(rw));
        CGGlyph gl[64];
        CGPoint pos[64];
        CGSize adv[64];
        CFIndex idx[64];
        if (n > 64)
            n = 64;
        CTRunGetGlyphs(run, CFRangeMake(0, n), gl);
        CTRunGetPositions(run, CFRangeMake(0, n), pos);
        CTRunGetAdvances(run, CFRangeMake(0, n), adv);
        CTRunGetStringIndices(run, CFRangeMake(0, n), idx);
        printf("   ");
        for (CFIndex k = 0; k < n; k++)
            printf(" %d@%s,%s+%s[%ld]", gl[k], g(pos[k].x), g(pos[k].y), g(adv[k].width), (long)idx[k]);
        printf("\n");
        CGAffineTransform tm = CTRunGetTextMatrix(run);
        if (!CGAffineTransformIsIdentity(tm))
            printf("   text matrix [%s %s %s %s %s %s]\n", g(tm.a), g(tm.b), g(tm.c), g(tm.d), g(tm.tx), g(tm.ty));
    }
    printf("  offsets:");
    for (CFIndex i = 0; i <= r.length; i++) {
        CGFloat secondary;
        printf(" %s", g(CTLineGetOffsetForStringIndex(line, r.location + i, &secondary)));
    }
    printf("\n  index for x:");
    for (int x = -5; x <= (int)width + 10; x += 7)
        printf(" %ld", (long)CTLineGetStringIndexForPosition(line, CGPointMake(x, 0)));
    printf("\n  pen offset for flush 0.5 in 200: %s\n", g(CTLineGetPenOffsetForFlush(line, 0.5, 200)));
}

static void
lines(CTFontRef f)
{
    const char *texts[] = {"Hello, World", "AVATAR Tea", "office affine", "a b  c  ", "", "x"};
    for (unsigned i = 0; i < sizeof texts / sizeof texts[0]; i++) {
        CFAttributedStringRef a = attributed(texts[i], f, NULL);
        CTLineRef line = CTLineCreateWithAttributedString(a);
        char l[64];
        snprintf(l, sizeof l, "line \"%s\"", texts[i]);
        line_info(l, line);
        CFRelease(line);
        CFRelease(a);
    }
    /* attributes: kerning, ligatures off, two fonts, a colour */
    double kern = 2.5;
    CFNumberRef kn = CFNumberCreate(NULL, kCFNumberDoubleType, &kern);
    int zero = 0;
    CFNumberRef z = CFNumberCreate(NULL, kCFNumberIntType, &zero);
    const void *k1[] = {kCTKernAttributeName}, *v1[] = {kn};
    CFDictionaryRef kd = CFDictionaryCreate(NULL, k1, v1, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef a = attributed("Tracking", f, kd);
    CTLineRef line = CTLineCreateWithAttributedString(a);
    line_info("line with kern", line);
    const void *k2[] = {kCTLigatureAttributeName}, *v2[] = {z};
    CFDictionaryRef ld = CFDictionaryCreate(NULL, k2, v2, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    a = attributed("office affine", f, ld);
    line = CTLineCreateWithAttributedString(a);
    line_info("line without ligatures", line);
    CTFontRef big = CTFontCreateCopyWithAttributes(f, 30, NULL, NULL);
    CFMutableAttributedStringRef mixed = CFAttributedStringCreateMutableCopy(NULL, 0, attributed("small BIG small", f, NULL));
    CFAttributedStringSetAttribute(mixed, CFRangeMake(6, 3), kCTFontAttributeName, big);
    CGColorRef red = CGColorCreateSRGB(1, 0, 0, 1);
    CFAttributedStringSetAttribute(mixed, CFRangeMake(0, 2), kCTForegroundColorAttributeName, red);
    line = CTLineCreateWithAttributedString(mixed);
    line_info("line with two fonts and a colour", line);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex i = 0; i < CFArrayGetCount(runs); i++) {
        CFDictionaryRef attrs = CTRunGetAttributes(CFArrayGetValueAtIndex(runs, i));
        printf("  run %ld attributes: %ld, colour %d\n", (long)i, (long)CFDictionaryGetCount(attrs),
               CFDictionaryContainsKey(attrs, kCTForegroundColorAttributeName));
    }
    CTLineRef trunc = CTLineCreateTruncatedLine(line, 80, kCTLineTruncationEnd, NULL);
    if (trunc)
        line_info("truncated line", trunc);
    /* (justified lines aren't compared yet: Apple's spreads the space by rules not yet worked out) */
}

static CTParagraphStyleRef
para(CTTextAlignment align, CGFloat spacing, CGFloat indent, CGFloat head, CGFloat tail, CTLineBreakMode mode)
{
    CTParagraphStyleSetting settings[] = {
        {kCTParagraphStyleSpecifierAlignment, sizeof align, &align},
        {kCTParagraphStyleSpecifierLineSpacingAdjustment, sizeof spacing, &spacing},
        {kCTParagraphStyleSpecifierFirstLineHeadIndent, sizeof indent, &indent},
        {kCTParagraphStyleSpecifierHeadIndent, sizeof head, &head},
        {kCTParagraphStyleSpecifierTailIndent, sizeof tail, &tail},
        {kCTParagraphStyleSpecifierLineBreakMode, sizeof mode, &mode},
    };
    return CTParagraphStyleCreate(settings, 6);
}

static void
frame_info(const char *label, CFAttributedStringRef a, CGRect box)
{
    CTFramesetterRef fs = CTFramesetterCreateWithAttributedString(a);
    CGPathRef path = CGPathCreateWithRect(box, NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, NULL);
    CFRange vis = CTFrameGetVisibleStringRange(frame), all = CTFrameGetStringRange(frame);
    CFArrayRef lines = CTFrameGetLines(frame);
    CFIndex n = CFArrayGetCount(lines);
    printf("%s: %ld lines, range %ld+%ld visible %ld+%ld\n", label, (long)n, (long)all.location, (long)all.length,
           (long)vis.location, (long)vis.length);
    CGPoint origins[64];
    CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), origins);
    for (CFIndex i = 0; i < n && i < 64; i++) {
        CTLineRef line = CFArrayGetValueAtIndex(lines, i);
        CFRange r = CTLineGetStringRange(line);
        CGFloat asc, desc, lead;
        double w = CTLineGetTypographicBounds(line, &asc, &desc, &lead);
        printf("  line %ld: range %ld+%ld origin %s,%s width %s trailing %s\n", (long)i, (long)r.location,
               (long)r.length, g(origins[i].x), g(origins[i].y), g(w), g(CTLineGetTrailingWhitespaceWidth(line)));
    }
    CFRange fit;
    CGSize sz = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRangeMake(0, 0), NULL, CGSizeMake(box.size.width, CGFLOAT_MAX), &fit);
    printf("  suggested %s x %s fits %ld+%ld\n", g(sz.width), g(sz.height), (long)fit.location, (long)fit.length);
    CTTypesetterRef ts = CTFramesetterGetTypesetter(fs);
    printf("  breaks at 60:");
    for (CFIndex start = 0; start < CFAttributedStringGetLength(a);) {
        CFIndex len = CTTypesetterSuggestLineBreak(ts, start, 60);
        printf(" %ld", (long)len);
        if (len <= 0)
            break;
        start += len;
    }
    printf("\n  cluster breaks at 25:");
    for (CFIndex start = 0; start < CFAttributedStringGetLength(a) && start < 40;) {
        CFIndex len = CTTypesetterSuggestClusterBreak(ts, start, 25);
        printf(" %ld", (long)len);
        if (len <= 0)
            break;
        start += len;
    }
    printf("\n");
    CFRelease(frame), CFRelease(path), CFRelease(fs);
}

static void
frames(CTFontRef f)
{
    const char *text = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.\n"
                       "Second paragraph with a line separator, and a verylongwordthatcannotfitonaline here.";
    frame_info("plain", attributed(text, f, NULL), CGRectMake(0, 0, 160, 400));
    frame_info("short box", attributed(text, f, NULL), CGRectMake(10, 20, 160, 60));
    CTTextAlignment aligns[] = {kCTTextAlignmentRight, kCTTextAlignmentCenter, kCTTextAlignmentJustified,
                                kCTTextAlignmentNatural};
    const char *names[] = {"right", "center", "justified", "natural"};
    for (int i = 0; i < 4; i++) {
        CTParagraphStyleRef ps = para(aligns[i], 3, 12, 4, -8, kCTLineBreakByWordWrapping);
        const void *k[] = {kCTParagraphStyleAttributeName}, *v[] = {ps};
        CFDictionaryRef d = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        char l[64];
        snprintf(l, sizeof l, "aligned %s", names[i]);
        frame_info(l, attributed(text, f, d), CGRectMake(0, 0, 180, 400));
        CFRelease(d);
        CFRelease(ps);
    }
    CTParagraphStyleRef ps = para(kCTTextAlignmentLeft, 0, 0, 0, 0, kCTLineBreakByCharWrapping);
    const void *k[] = {kCTParagraphStyleAttributeName}, *v[] = {ps};
    CFDictionaryRef d = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    frame_info("char wrapping", attributed(text, f, d), CGRectMake(0, 0, 120, 400));
    /* paragraph style getters */
    CTParagraphStyleRef p2 = para(kCTTextAlignmentCenter, 2.5, 10, 5, -5, kCTLineBreakByTruncatingTail);
    CTTextAlignment al;
    CGFloat sp, fi, tl;
    CTLineBreakMode lb;
    CTParagraphStyleGetValueForSpecifier(p2, kCTParagraphStyleSpecifierAlignment, sizeof al, &al);
    CTParagraphStyleGetValueForSpecifier(p2, kCTParagraphStyleSpecifierLineSpacingAdjustment, sizeof sp, &sp);
    CTParagraphStyleGetValueForSpecifier(p2, kCTParagraphStyleSpecifierFirstLineHeadIndent, sizeof fi, &fi);
    CTParagraphStyleGetValueForSpecifier(p2, kCTParagraphStyleSpecifierTailIndent, sizeof tl, &tl);
    CTParagraphStyleGetValueForSpecifier(p2, kCTParagraphStyleSpecifierLineBreakMode, sizeof lb, &lb);
    printf("paragraph style: align %d spacing %s first indent %s tail %s break %d\n", al, g(sp), g(fi), g(tl), lb);
    CFArrayRef tabs = NULL;
    CTParagraphStyleGetValueForSpecifier(p2, kCTParagraphStyleSpecifierTabStops, sizeof tabs, &tabs);
    printf("default tab stops: %ld", tabs ? (long)CFArrayGetCount(tabs) : -1L);
    for (CFIndex i = 0; tabs && i < CFArrayGetCount(tabs) && i < 4; i++)
        printf(" %s", g(CTTextTabGetLocation(CFArrayGetValueAtIndex(tabs, i))));
    CGFloat tabint = -1;
    CTParagraphStyleGetValueForSpecifier(p2, kCTParagraphStyleSpecifierDefaultTabInterval, sizeof tabint, &tabint);
    printf(" interval %s\n", g(tabint));
}

int
main(int argc, char **argv)
{
    if (argc < 2 || strcmp(argv[1], "--no-path")) {
        Dl_info info;
        printf("CoreText: %s\n", dladdr((void *)CTLineCreateWithAttributedString, &info) ? info.dli_fname : "?");
    }
    CGFontRef cg = cgfont("Roboto-Regular.ttf");
    CTFontRef f = CTFontCreateWithGraphicsFont(cg, 18, NULL, NULL);
    fonts(f);
    lines(f);
    frames(f);
    return 0;
}
