/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-ctfonts-test: the fonts Finch ships and Apple's names for them
 * (userland/fonts). For each Apple font name, the font CoreText and
 * CoreGraphics resolve it to and its metrics; the UI fonts; the default font;
 * bold and italic faces; the fallback fonts chosen for Latin, Greek,
 * Cyrillic, CJK, Arabic, Hebrew, symbols and emoji; and emoji drawn in
 * colour.
 *
 * Finch-only: Apple's output names Apple's own fonts, so the output is
 * compared with userland/tests/ctfonts-expected.txt instead of with a host
 * run. On the host, against build/root:
 *
 *   DYLD_FRAMEWORK_PATH=build/root/System/Library/Frameworks \
 *   FINCH_FONT_DIRS=build/root/System/Library/Fonts \
 *       build/userland/finch-ctfonts-test | diff userland/tests/ctfonts-expected.txt -
 *
 * In the VM: finch-ctfonts-test | diff /usr/local/share/finch/ctfonts-expected.txt -
 */
#include <CoreText/CoreText.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

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

static const char *
cstr(CFStringRef s, char *buf, size_t len)
{
    snprintf(buf, len, "NULL");
    if (s) {
        CFStringGetCString(s, buf, (CFIndex)len, kCFStringEncodingUTF8);
        CFRelease(s);
    }
    return buf;
}

static CFStringRef
cf(const char *s)
{
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static double
weight(CTFontRef f)
{
    double w = 0;
    CFDictionaryRef t = CTFontCopyTraits(f);
    CFNumberRef n = t ? CFDictionaryGetValue(t, kCTFontWeightTrait) : NULL;
    if (n)
        CFNumberGetValue(n, kCFNumberDoubleType, &w);
    if (t)
        CFRelease(t);
    return w;
}

static double
line_width(CTFontRef f, const char *text)
{
    CFStringRef s = cf(text);
    CFStringRef k = kCTFontAttributeName;
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)&k, (const void **)&f, 1,
                                               &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, s, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line), CFRelease(as), CFRelease(attrs), CFRelease(s);
    return w;
}

static void
describe(const char *label, CTFontRef f)
{
    char ps[256], fam[256];
    if (!f) {
        printf("%s: NULL\n", label);
        return;
    }
    printf("%s: %s (%s) size %s weight %s traits 0x%x\n", label, cstr(CTFontCopyPostScriptName(f), ps, sizeof ps),
           cstr(CTFontCopyFamilyName(f), fam, sizeof fam), g(CTFontGetSize(f)), g(weight(f)),
           CTFontGetSymbolicTraits(f));
}

static void
names(void)
{
    static const char *list[] = {
        "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique", "helvetica",
        "Helvetica Neue", "HelveticaNeue", "HelveticaNeue-Bold", "HelveticaNeue-Italic", "Arial", "ArialMT",
        "Arial-BoldMT", "Arial-ItalicMT", "Arial-BoldItalicMT", "Arial Bold",
        "Times", "Times-Roman", "Times-Bold", "Times New Roman", "TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT",
        "Courier", "Courier-Bold", "Courier New", "CourierNewPSMT", "CourierNewPS-BoldMT",
        "Menlo", "Menlo-Regular", "Menlo-Bold", "Menlo-Italic", "Monaco", "SF Mono", "SFMono-Regular", "SFMono-Bold",
        "SFMono-RegularItalic", "SFMono-BoldItalic", ".AppleSystemUIFontMonospaced",
        ".AppleSystemUIFont", ".AppleSystemUIFontBold", ".SFNS-Regular", ".SFNS-Semibold", ".SFNS-Bold", "System Font",
        "SF Pro", "SFProText-Regular", "SFProText-Medium", "SFProDisplay-Bold", "LucidaGrande", "Lucida Grande",
        ".SFNS-Ultralight", ".SFNS-Thin", ".SFNS-Heavy", ".SFNS-Black", ".AppleSystemUIFontItalic",
        "SF Pro Rounded", "SFProRounded-Regular", "SFProRounded-Medium", "SFProRounded-Semibold", "SFProRounded-Bold",
        "Charter", "Charter-Roman", "Charter-Bold", "Charter-Italic", "Charter-BoldItalic",
        "Palatino", "Palatino-Roman", "Palatino-Bold", "Palatino-Italic", "Palatino-BoldItalic",
        "LucidaGrande-Bold", "Apple Color Emoji", "AppleColorEmoji", "Apple Symbols",
        "PingFang SC", "PingFangSC-Regular", "PingFangSC-Semibold", "PingFangTC-Regular", "Hiragino Sans",
        "HiraginoSans-W3", "HiraginoSans-W6", "HiraKakuProN-W3", "Apple SD Gothic Neo",
        "Geeza Pro", "GeezaPro-Bold", "Arial Hebrew",
        /* Finch's own names, and one that is nothing (Helvetica, as on macOS) */
        "Inter", "Inter-Medium", "Liberation Sans", "Noto Sans", "NoSuchFont",
    };
    printf("# Apple names: CoreText font, then metrics at 12 points, then CGFontCreateWithFontName\n");
    for (unsigned i = 0; i < sizeof list / sizeof list[0]; i++) {
        CFStringRef n = cf(list[i]);
        CTFontRef f = CTFontCreateWithName(n, 12, NULL);
        describe(list[i], f);
        if (f) {
            printf("  upem %u ascent %s descent %s leading %s cap %s x %s width %s\n", CTFontGetUnitsPerEm(f),
                   g(CTFontGetAscent(f)), g(CTFontGetDescent(f)), g(CTFontGetLeading(f)), g(CTFontGetCapHeight(f)),
                   g(CTFontGetXHeight(f)), g(line_width(f, "Hamburgefonstiv 0123")));
            CFRelease(f);
        }
        char ps[256];
        CGFontRef cg = CGFontCreateWithFontName(n);
        printf("  CGFont: %s\n", cg ? cstr(CGFontCopyPostScriptName(cg), ps, sizeof ps) : "NULL");
        if (cg)
            CGFontRelease(cg);
        CFRelease(n);
    }
}

static void
ui_fonts(void)
{
    printf("# UI fonts (size 0: each one's own size)\n");
    for (int t = (int)kCTFontUIFontUser; t <= (int)kCTFontUIFontControlContent; t++) {
        char label[32];
        snprintf(label, sizeof label, "ui %d", t);
        CTFontRef f = CTFontCreateUIFontForLanguage((CTFontUIFontType)t, 0, NULL);
        describe(label, f);
        if (f)
            CFRelease(f);
    }
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 20, NULL);
    describe("system at 20", f);
    CFRelease(f);
}

static void
defaults_and_traits(void)
{
    printf("# the default font (a line with no font attribute)\n");
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, CFSTR("default"), NULL);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, 0);
    describe("default", CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName));
    CFRelease(line), CFRelease(as);

    printf("# bold and italic copies\n");
    const char *bases[] = {"Helvetica", "Times", "Courier", "Menlo", ".AppleSystemUIFont", "SF Mono",
                           "SF Pro Rounded", "Charter", "Palatino", "Noto Sans"};
    for (unsigned i = 0; i < sizeof bases / sizeof bases[0]; i++) {
        CFStringRef n = cf(bases[i]);
        CTFontRef f = CTFontCreateWithName(n, 12, NULL);
        CTFontSymbolicTraits want[] = {kCTFontTraitBold, kCTFontTraitItalic, kCTFontTraitBold | kCTFontTraitItalic};
        for (unsigned k = 0; k < 3; k++) {
            char label[128];
            snprintf(label, sizeof label, "%s +0x%x", bases[i], want[k]);
            CTFontRef c = CTFontCreateCopyWithSymbolicTraits(f, 0, NULL, want[k], want[k]);
            describe(label, c);
            if (c)
                CFRelease(c);
        }
        CFRelease(f), CFRelease(n);
    }
}

static void
fallback(void)
{
    static const char *samples[][2] = {
        {"latin", "Hello, world"},
        {"latin extended", "\xC5\x81\xC3\xB3" "d\xC5\xBA \xC8\x98" "tefan \xE1\xBA\xA0"},
        {"greek", "\xCE\x91\xCE\xB8\xCE\xAE\xCE\xBD\xCE\xB1"},
        {"cyrillic", "\xD0\x9C\xD0\xBE\xD1\x81\xD0\xBA\xD0\xB2\xD0\xB0"},
        {"chinese", "\xE4\xB8\xAD\xE6\x96\x87"},
        {"japanese", "\xE3\x81\xB2\xE3\x82\x89\xE3\x81\x8C\xE3\x81\xAA\xE3\x82\xAB\xE3\x82\xBF\xE3\x82\xAB\xE3\x83\x8A"},
        {"korean", "\xED\x95\x9C\xEA\xB5\xAD\xEC\x96\xB4"},
        {"arabic", "\xD9\x85\xD8\xB1\xD8\xAD\xD8\xA8\xD8\xA7"},
        {"hebrew", "\xD7\xA9\xD7\x9C\xD7\x95\xD7\x9D"},
        {"symbols", "\xE2\x99\x9E \xE2\x8C\x98 \xE2\x86\x92"},
        {"emoji", "\xF0\x9F\x98\x80\xF0\x9F\x91\x8D"},
        {"heart and vs16", "\xE2\x9D\xA4\xEF\xB8\x8F"},
        {"zwj family", "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7"},
        {"skin tone", "\xF0\x9F\x91\x8B\xF0\x9F\x8F\xBD"},
        {"mixed", "Hi \xE4\xB8\xAD \xD9\x85\xD8\xB1 \xF0\x9F\x98\x80!"},
    };
    const char *bases[] = {"Helvetica", "Helvetica-Bold", "Menlo"};
    printf("# fallback: CTFontCreateForString for the first character, then the runs of a line\n");
    for (unsigned b = 0; b < sizeof bases / sizeof bases[0]; b++) {
        CFStringRef bn = cf(bases[b]);
        CTFontRef base = CTFontCreateWithName(bn, 12, NULL);
        CFRelease(bn);
        for (unsigned i = 0; i < sizeof samples / sizeof samples[0]; i++) {
            CFStringRef s = cf(samples[i][1]);
            char label[128], ps[256];
            snprintf(label, sizeof label, "%s %s", bases[b], samples[i][0]);
            CTFontRef f = CTFontCreateForString(base, s, CFRangeMake(0, CFStringGetLength(s)));
            printf("%s: %s", label, cstr(CTFontCopyPostScriptName(f), ps, sizeof ps));
            CFRelease(f);
            CFStringRef k = kCTFontAttributeName;
            CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)&k, (const void **)&base, 1,
                                                       &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFAttributedStringRef as = CFAttributedStringCreate(NULL, s, attrs);
            CTLineRef line = CTLineCreateWithAttributedString(as);
            CFArrayRef runs = CTLineGetGlyphRuns(line);
            printf(" | runs");
            for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
                CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
                CFRange range = CTRunGetStringRange(run);
                CTFontRef rf = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
                printf(" [%ld+%ld %s%s]", (long)range.location, (long)range.length,
                       cstr(CTFontCopyPostScriptName(rf), ps, sizeof ps),
                       CTRunGetStatus(run) & kCTRunStatusRightToLeft ? " rtl" : "");
            }
            printf(" width %s\n", g(CTLineGetTypographicBounds(line, NULL, NULL, NULL)));
            CFRelease(line), CFRelease(as), CFRelease(attrs), CFRelease(s);
        }
        CFRelease(base);
    }

    printf("# the default cascade list\n");
    CTFontRef h = CTFontCreateWithName(CFSTR("Helvetica"), 12, NULL);
    CFArrayRef list = CTFontCopyDefaultCascadeListForLanguages(h, NULL);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        char ps[256];
        CTFontDescriptorRef d = CFArrayGetValueAtIndex(list, i);
        printf("cascade %ld: %s\n", (long)i,
               cstr(CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute), ps, sizeof ps));
    }
    if (list)
        CFRelease(list);
    CFRelease(h);
}

/* What a bitmap holds: the inked box (rows from the top), pixel counts, mean colour, and how much is the fill colour (red). */
#define CW 200
#define CH 120
static void
ink(const char *label, const unsigned char *px)
{
    int x0 = CW, y0 = CH, x1 = -1, y1 = -1, inked = 0, opaque = 0, red = 0, maxa = 0;
    double r = 0, gr = 0, b = 0;
    for (int y = 0; y < CH; y++)
        for (int x = 0; x < CW; x++) {
            const unsigned char *p = px + 4 * (y * CW + x);
            if (p[3] > maxa)
                maxa = p[3];
            if (p[3] <= 8)
                continue;
            inked++;
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
            if (p[3] < 128)
                continue;
            /* unpremultiplied */
            double pr = p[0] * 255.0 / p[3], pg = p[1] * 255.0 / p[3], pb = p[2] * 255.0 / p[3];
            opaque++;
            r += pr, gr += pg, b += pb;
            red += pr > 200 && pg < 60 && pb < 60;
        }
    if (!inked) {
        printf("%s: nothing\n", label);
        return;
    }
    printf("%s: ink x %d..%d y %d..%d, %d px inked, max alpha %d, %d px opaque: mean colour %.0f %.0f %.0f, %d px fill red\n",
           label, x0, x1, y0, y1, inked, maxa, opaque, opaque ? r / opaque : 0, opaque ? gr / opaque : 0,
           opaque ? b / opaque : 0, red);
}

static CGContextRef
canvas(unsigned char *px)
{
    memset(px, 0, CW * CH * 4);
    CGColorSpaceRef s = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(px, CW, CH, 8, CW * 4, s, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(s);
    CGContextSetRGBFillColor(c, 1, 0, 0, 1);
    return c;
}

static CTLineRef
red_line(const char *text, CTFontRef font)
{
    CGColorSpaceRef s = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[] = {1, 0, 0, 1};
    CGColorRef red = CGColorCreate(s, comps);
    CGColorSpaceRelease(s);
    CFStringRef keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    CFTypeRef values[] = {font, red};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFStringRef str = cf(text);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CFRelease(as), CFRelease(str), CFRelease(attrs), CGColorRelease(red);
    return line;
}

/*
 * Colour glyphs (Noto Color Emoji's CBDT bitmaps): CoreText draws them in
 * their own colours, not the fill colour, through the CTM, text matrix and
 * context alpha; CoreGraphics' glyph calls draw only outlines, so nothing
 * for an emoji, as Apple's do.
 */
static void
color_glyphs(void)
{
    printf("# colour glyphs, drawn at (20, 30) in a %dx%d bitmap with a red fill\n", CW, CH);
    static unsigned char px[CW * CH * 4];
    CTFontRef f = CTFontCreateWithName(CFSTR("Apple Color Emoji"), 40, NULL);
    UniChar u[2] = {0xD83D, 0xDE00};
    CGGlyph gl[2];
    CTFontGetGlyphsForCharacters(f, u, gl, 2);
    CGRect box;
    CGSize adv;
    CTFontGetBoundingRectsForGlyphs(f, kCTFontOrientationHorizontal, gl, &box, 1);
    CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, gl, &adv, 1);
    printf("U+1F600 at 40 pt: advance %s bounds %s %s %s %s\n", g(adv.width), g(box.origin.x), g(box.origin.y),
           g(box.size.width), g(box.size.height));
    CGPoint at = CGPointMake(20, 30);

    struct {
        const char *label;
        int kind;
    } cases[] = {
        {"CTFontDrawGlyphs", 0},
        {"CGContextShowGlyphsAtPositions", 1},
        {"CTFontDrawGlyphs, context alpha 0.5", 2},
        {"CTFontDrawGlyphs, clear fill", 3},
        {"CTFontDrawGlyphs, CTM scaled 2", 4},
        {"CTFontDrawGlyphs, text matrix rotated 30 degrees", 5},
        {"CTFontDrawGlyphs at 12 pt", 6},
        {"CTFontDrawGlyphs, stroke mode", 7},
        {"CTFontDrawGlyphs, clip mode, then a rect filled", 8},
        {"CTLineDraw A, grinning face, B", 9},
        {"CTLineDraw family (ZWJ sequence)", 10},
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        CGContextRef c = canvas(px);
        CTFontRef font = (CTFontRef)CFRetain(f);
        int k = cases[i].kind;
        if (k == 2)
            CGContextSetAlpha(c, 0.5);
        if (k == 3)
            CGContextSetRGBFillColor(c, 1, 0, 0, 0);
        if (k == 4)
            CGContextScaleCTM(c, 2, 2), at = CGPointMake(10, 15);
        if (k == 5)
            CGContextSetTextMatrix(c, CGAffineTransformMakeRotation(M_PI / 6));
        if (k == 6)
            CFRelease(font), font = CTFontCreateWithName(CFSTR("Apple Color Emoji"), 12, NULL);
        if (k == 7)
            CGContextSetTextDrawingMode(c, kCGTextStroke);
        if (k == 8)
            CGContextSetTextDrawingMode(c, kCGTextClip);
        if (k == 1) {
            CGFontRef cg = CTFontCopyGraphicsFont(font, NULL);
            CGContextSetFont(c, cg);
            CGContextSetFontSize(c, 40);
            CGContextShowGlyphsAtPositions(c, gl, &at, 1);
            CGFontRelease(cg);
        } else if (k >= 9) {
            CTFontRef helvetica = CTFontCreateWithName(CFSTR("Helvetica"), 40, NULL);
            CTLineRef line = red_line(k == 9 ? "A\xF0\x9F\x98\x80" "B"
                                             : "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7",
                                      helvetica);
            CGContextSetTextPosition(c, at.x, at.y);
            CTLineDraw(line, c);
            printf("%s: width %s\n", cases[i].label, g(CTLineGetTypographicBounds(line, NULL, NULL, NULL)));
            CFRelease(line), CFRelease(helvetica);
        } else {
            CTFontDrawGlyphs(font, gl, &at, 1, c);
        }
        if (k == 8) {
            CGContextSetRGBFillColor(c, 0, 0, 1, 1);
            CGContextFillRect(c, CGRectMake(0, 0, CW, CH));
        }
        ink(cases[i].label, px);
        at = CGPointMake(20, 30);
        CFRelease(font);
        CGContextRelease(c);
    }
    CFRelease(f);
}

static void
installed(void)
{
    printf("# installed families\n");
    CFArrayRef fams = CTFontManagerCopyAvailableFontFamilyNames();
    for (CFIndex i = 0; i < CFArrayGetCount(fams); i++) {
        char buf[256];
        CFStringRef s = CFArrayGetValueAtIndex(fams, i);
        CFRetain(s);
        printf("family: %s\n", cstr(s, buf, sizeof buf));
    }
    CFRelease(fams);
}

int
main(void)
{
    names();
    ui_fonts();
    defaults_and_traits();
    fallback();
    color_glyphs();
    installed();
    return 0;
}
