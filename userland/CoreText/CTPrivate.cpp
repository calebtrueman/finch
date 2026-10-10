// SPDX-License-Identifier: MIT OR Apache-2.0
//
// CoreText's private functions for system UI fonts and text styles, which SwiftUI calls,
// in Finch's terms over its public API. Text styles have macOS's sizes and weights
// (NSFont's preferred fonts on macOS 26.4); the system UI font is Finch's (Inter).

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdlib.h>
#include <string.h>

#define CT_SPI extern "C" __attribute__((visibility("default")))

namespace {

struct TextStyle {
    const char *name;
    CGFloat size, weight;
};

const TextStyle styles[] = {
    {"UICTFontTextStyleTitle0", 26, 0},          {"UICTFontTextStyleTitle1", 22, 0},
    {"UICTFontTextStyleTitle2", 17, 0},          {"UICTFontTextStyleTitle3", 15, 0},
    {"UICTFontTextStyleHeadline", 13, 0.4},      {"UICTFontTextStyleSubhead", 11, 0},
    {"UICTFontTextStyleBody", 13, 0},            {"UICTFontTextStyleCallout", 12, 0},
    {"UICTFontTextStyleFootnote", 10, 0},        {"UICTFontTextStyleFootnote2", 10, -0.4},
    {"UICTFontTextStyleCaption1", 10, 0},        {"UICTFontTextStyleCaption2", 10, 0},
    {"UICTFontTextStyleCaption3", 10.5, 0.23},   {"UICTFontTextStyleExtraLargeTitle", 36, 0.4},
    {"UICTFontTextStyleExtraLargeTitle2", 28, 0.4},
};

const TextStyle *
style_named(CFStringRef name)
{
    char buf[64];
    if (!name || !CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingASCII))
        return &styles[6];
    for (const TextStyle &s : styles)
        if (!strcmp(s.name, buf))
            return &s;
    return &styles[6];
}

CFDictionaryRef
traits_of(CTFontDescriptorRef d)
{
    CFTypeRef t = d ? CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) : NULL;
    if (t && CFGetTypeID(t) != CFDictionaryGetTypeID()) {
        CFRelease(t);
        return NULL;
    }
    return (CFDictionaryRef)t;
}

CGFloat
number_in(CFDictionaryRef d, CFStringRef key)
{
    CFNumberRef n = d ? (CFNumberRef)CFDictionaryGetValue(d, key) : NULL;
    double v = 0;
    if (n && CFGetTypeID(n) == CFNumberGetTypeID())
        CFNumberGetValue(n, kCFNumberDoubleType, &v);
    return v;
}

/* The system UI font's family, to recognise it. */
bool
is_system_family(CFStringRef family)
{
    if (!family)
        return false;
    CTFontRef ui = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 13, NULL);
    CFStringRef sys = ui ? CTFontCopyFamilyName(ui) : NULL;
    bool same = sys && CFEqual(sys, family);
    if (sys)
        CFRelease(sys);
    if (ui)
        CFRelease(ui);
    return same || CFStringHasPrefix(family, CFSTR("."));
}

/* A system UI font descriptor of a size and weight. */
CTFontDescriptorRef
system_descriptor(CGFloat size, CGFloat weight, CFDictionaryRef extra)
{
    CTFontRef ui = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
    CTFontDescriptorRef base = CTFontCopyFontDescriptor(ui);
    CFRelease(ui);
    CFMutableDictionaryRef attrs = extra ? CFDictionaryCreateMutableCopy(NULL, 0, extra)
                                         : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                     &kCFTypeDictionaryValueCallBacks);
    if (weight != 0) {
        CFNumberRef w = CFNumberCreate(NULL, kCFNumberCGFloatType, &weight);
        const void *k = kCTFontWeightTrait, *v = w;
        CFDictionaryRef traits = CFDictionaryCreate(NULL, &k, &v, 1, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attrs, kCTFontTraitsAttribute, traits);
        CFRelease(traits);
        CFRelease(w);
    }
    CFNumberRef s = CFNumberCreate(NULL, kCFNumberCGFloatType, &size);
    CFDictionarySetValue(attrs, kCTFontSizeAttribute, s);
    CFRelease(s);
    CTFontDescriptorRef d = CTFontDescriptorCreateCopyWithAttributes(base, attrs);
    CFRelease(attrs);
    CFRelease(base);
    return d;
}

} // namespace

CT_SPI CFCharacterSetRef
CTFontCopySystemUIFontExcessiveLineHeightCharacterSet(void)
{
    return CFCharacterSetCreateWithCharactersInString(NULL, CFSTR(""));
}

CT_SPI CFStringRef
CTFontCopyTallestTextStyleLanguageForString(CFStringRef string)
{
    return NULL;
}

CT_SPI CTFontDescriptorRef
CTFontDescriptorCreateForUIType(CTFontUIFontType type, CGFloat size, CFStringRef language)
{
    CTFontRef f = CTFontCreateUIFontForLanguage(type, size, language);
    if (!f)
        f = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, language);
    CTFontDescriptorRef d = CTFontCopyFontDescriptor(f);
    CFRelease(f);
    return d;
}

CT_SPI CTFontDescriptorRef
CTFontDescriptorCreateWithAttributesAndOptions(CFDictionaryRef attributes, uint32_t options)
{
    return CTFontDescriptorCreateWithAttributes(attributes);
}

CT_SPI CGFloat
CTFontDescriptorGetTextStyleSize(CFStringRef textStyle, CFStringRef sizeCategory, int32_t platform, const CGFloat *weight,
                                 const CGFloat *size)
{
    return style_named(textStyle)->size;
}

CT_SPI CTFontDescriptorRef
CTFontDescriptorCreateWithTextStyleAndAttributes(CFStringRef textStyle, CFStringRef sizeCategory, CFDictionaryRef attributes)
{
    const TextStyle *s = style_named(textStyle);
    return system_descriptor(s->size, s->weight, attributes);
}

CT_SPI CTFontSymbolicTraits
CTFontDescriptorGetSymbolicTraits(CTFontDescriptorRef descriptor)
{
    CFDictionaryRef t = traits_of(descriptor);
    CTFontSymbolicTraits v = (CTFontSymbolicTraits)number_in(t, kCTFontSymbolicTrait);
    if (t)
        CFRelease(t);
    return v;
}

CT_SPI CGFloat
CTFontDescriptorGetWeight(CTFontDescriptorRef descriptor)
{
    CFDictionaryRef t = traits_of(descriptor);
    CGFloat v = number_in(t, kCTFontWeightTrait);
    if (t)
        CFRelease(t);
    return v;
}

CT_SPI bool
CTFontDescriptorIsSystemUIFont(CTFontDescriptorRef descriptor)
{
    CFStringRef family = descriptor ? (CFStringRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) : NULL;
    bool is = is_system_family(family);
    if (family)
        CFRelease(family);
    return is;
}

/* Bold for accessibility: the weight two steps heavier (regular to semibold, semibold to heavy...). */
CT_SPI CGFloat
CTFontGetAccessibilityBoldWeightOfWeight(CGFloat weight)
{
    static const CGFloat steps[] = {-0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62};
    const size_t n = sizeof steps / sizeof steps[0];
    size_t i = 0;
    while (i + 1 < n && steps[i] < weight - 0.01)
        i++;
    return steps[i + 2 < n ? i + 2 : n - 1];
}

CT_SPI bool
CTFontGetClippingMetrics(CTFontRef font, CGFloat *ascent, CGFloat *descent)
{
    if (ascent)
        *ascent = CTFontGetAscent(font);
    if (descent)
        *descent = CTFontGetDescent(font);
    return true;
}

CT_SPI bool
CTFontGetLanguageAwareOutsets(CTFontRef font, CGFloat *left, CGFloat *top, CGFloat *right, CGFloat *bottom)
{
    if (left)
        *left = 0;
    if (top)
        *top = 0;
    if (right)
        *right = 0;
    if (bottom)
        *bottom = 0;
    return false;
}

CT_SPI CGFloat
CTFontGetWeight(CTFontRef font)
{
    CFDictionaryRef t = CTFontCopyTraits(font);
    CGFloat v = number_in(t, kCTFontWeightTrait);
    if (t)
        CFRelease(t);
    return v;
}

CT_SPI bool
CTFontIsSystemUIFont(CTFontRef font)
{
    CFStringRef family = CTFontCopyFamilyName(font);
    bool is = is_system_family(family);
    if (family)
        CFRelease(family);
    return is;
}

/* CTCompositionLanguage: none (0) unless the language is Chinese or Japanese. */
CT_SPI uint8_t
CTParagraphStyleGetCompositionLanguageForLanguage(CFStringRef language)
{
    if (!language)
        return 0;
    if (CFStringHasPrefix(language, CFSTR("ja")))
        return 3;
    if (CFStringHasPrefix(language, CFSTR("zh-Hant")) || CFStringHasPrefix(language, CFSTR("zh-TW")))
        return 2;
    if (CFStringHasPrefix(language, CFSTR("zh")))
        return 1;
    return 0;
}

// Whether text in a font should be antialiased whatever the context says. On macOS
// only Menlo, Lucida Grande and STHeiti answer yes (a property of those fonts, not of
// their tables); Finch's stand-in for Menlo answers as Menlo does.
CT_SPI bool
CTFontShouldAntiAlias(CTFontRef font)
{
    if (!font)
        return true;
    CFStringRef ps = CTFontCopyPostScriptName(font);
    char name[128] = "";
    if (ps) {
        CFStringGetCString(ps, name, sizeof name, kCFStringEncodingUTF8);
        CFRelease(ps);
    }
    static const char *const always[] = {"Menlo", "LucidaGrande", "STHeiti", "DejaVuSansMono"};
    for (const char *prefix : always)
        if (!strncmp(name, prefix, strlen(prefix)))
            return true;
    return false;
}

// Draws glyphs from the context's text position, each advance (in text space) placing
// the next, as CGContextShowGlyphsWithAdvances does; the text position ends after the
// last glyph. The text matrix carries the text position, so positions start at zero.
CT_SPI void
CTFontDrawGlyphsWithAdvances(CTFontRef font, const CGGlyph glyphs[], const CGSize advances[], size_t count,
                             CGContextRef context)
{
    if (!font || !glyphs || !advances || !count || !context)
        return;
    CGPoint *positions = (CGPoint *)malloc(sizeof(CGPoint) * count);
    CGPoint p = CGPointZero;
    for (size_t i = 0; i < count; i++) {
        positions[i] = p;
        p.x += advances[i].width;
        p.y += advances[i].height;
    }
    CGAffineTransform tm = CGContextGetTextMatrix(context);
    CTFontDrawGlyphs(font, glyphs, positions, count, context);
    CGPoint end = CGPointApplyAffineTransform(p, tm);
    CGContextSetTextPosition(context, end.x, end.y);
    free(positions);
}
