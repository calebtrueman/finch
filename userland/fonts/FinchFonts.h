/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Shared by CoreText's and CoreGraphics' font registries: where installed
 * fonts are looked for, and Apple's font names with the fonts Finch ships in
 * their place (userland/fonts/build.sh).
 *
 * Font directories: /System/Library/Fonts, /Library/Fonts and
 * ~/Library/Fonts, as on macOS. FINCH_FONT_DIRS, a colon-separated list,
 * replaces them (for running Finch's frameworks on a macOS host against
 * build/root/System/Library/Fonts instead of Apple's fonts); it is ignored in
 * set-id processes.
 *
 * Aliases: a name resolves to an alias only when no installed or
 * registered font has that name, so apps that bundle the real font, or a
 * host with Apple's fonts installed, get the real one. Keys are PostScript,
 * full and family names, compared ignoring case (as CoreText compares font
 * names); values are PostScript names of fonts Finch ships.
 *
 * Only names. No Apple font data is used or shipped.
 */
#ifndef FINCH_FONTS_H
#define FINCH_FONTS_H

#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <string>
#include <vector>

/* The directories to index for installed fonts, in order. */
static inline std::vector<std::string>
finch_font_dirs(void)
{
    std::vector<std::string> dirs;
    const char *env = issetugid() ? NULL : getenv("FINCH_FONT_DIRS");
    if (env && *env) {
        std::string all(env);
        size_t start = 0;
        while (start <= all.size()) {
            size_t end = all.find(':', start);
            if (end == std::string::npos)
                end = all.size();
            if (end > start)
                dirs.push_back(all.substr(start, end - start));
            start = end + 1;
        }
        return dirs;
    }
    dirs.push_back("/System/Library/Fonts");
    dirs.push_back("/Library/Fonts");
    if (const char *home = getenv("HOME"))
        dirs.push_back(std::string(home) + "/Library/Fonts");
    return dirs;
}

struct FinchFontAlias {
    const char *apple, *finch;
};

static const struct FinchFontAlias finch_font_aliases[] = {
    /* Helvetica, Helvetica Neue, Arial: Liberation Sans (Arial's metrics) */
    {"Helvetica", "LiberationSans"},
    {"Helvetica-Light", "LiberationSans"},
    {"Helvetica-Bold", "LiberationSans-Bold"},
    {"Helvetica-Oblique", "LiberationSans-Italic"},
    {"Helvetica-LightOblique", "LiberationSans-Italic"},
    {"Helvetica-BoldOblique", "LiberationSans-BoldItalic"},
    {"Helvetica Bold", "LiberationSans-Bold"},
    {"Helvetica Oblique", "LiberationSans-Italic"},
    {"Helvetica Bold Oblique", "LiberationSans-BoldItalic"},
    {"Helvetica Neue", "LiberationSans"},
    {"HelveticaNeue", "LiberationSans"},
    {"HelveticaNeue-UltraLight", "LiberationSans"},
    {"HelveticaNeue-Thin", "LiberationSans"},
    {"HelveticaNeue-Light", "LiberationSans"},
    {"HelveticaNeue-Medium", "LiberationSans"},
    {"HelveticaNeue-Bold", "LiberationSans-Bold"},
    {"HelveticaNeue-CondensedBold", "LiberationSans-Bold"},
    {"HelveticaNeue-CondensedBlack", "LiberationSans-Bold"},
    {"HelveticaNeue-Italic", "LiberationSans-Italic"},
    {"HelveticaNeue-UltraLightItalic", "LiberationSans-Italic"},
    {"HelveticaNeue-ThinItalic", "LiberationSans-Italic"},
    {"HelveticaNeue-LightItalic", "LiberationSans-Italic"},
    {"HelveticaNeue-MediumItalic", "LiberationSans-Italic"},
    {"HelveticaNeue-BoldItalic", "LiberationSans-BoldItalic"},
    {"Helvetica Neue Bold", "LiberationSans-Bold"},
    {"Helvetica Neue Italic", "LiberationSans-Italic"},
    {"Helvetica Neue Bold Italic", "LiberationSans-BoldItalic"},
    {"Arial", "LiberationSans"},
    {"ArialMT", "LiberationSans"},
    {"Arial-BoldMT", "LiberationSans-Bold"},
    {"Arial-ItalicMT", "LiberationSans-Italic"},
    {"Arial-BoldItalicMT", "LiberationSans-BoldItalic"},
    {"Arial Bold", "LiberationSans-Bold"},
    {"Arial Italic", "LiberationSans-Italic"},
    {"Arial Bold Italic", "LiberationSans-BoldItalic"},

    /* Times, Times New Roman: Liberation Serif (Times New Roman's metrics) */
    {"Times", "LiberationSerif"},
    {"Times-Roman", "LiberationSerif"},
    {"Times-Bold", "LiberationSerif-Bold"},
    {"Times-Italic", "LiberationSerif-Italic"},
    {"Times-BoldItalic", "LiberationSerif-BoldItalic"},
    {"Times Roman", "LiberationSerif"},
    {"Times Bold", "LiberationSerif-Bold"},
    {"Times Italic", "LiberationSerif-Italic"},
    {"Times Bold Italic", "LiberationSerif-BoldItalic"},
    {"Times New Roman", "LiberationSerif"},
    {"TimesNewRomanPSMT", "LiberationSerif"},
    {"TimesNewRomanPS-BoldMT", "LiberationSerif-Bold"},
    {"TimesNewRomanPS-ItalicMT", "LiberationSerif-Italic"},
    {"TimesNewRomanPS-BoldItalicMT", "LiberationSerif-BoldItalic"},
    {"Times New Roman Bold", "LiberationSerif-Bold"},
    {"Times New Roman Italic", "LiberationSerif-Italic"},
    {"Times New Roman Bold Italic", "LiberationSerif-BoldItalic"},

    /* Courier, Courier New: Liberation Mono (Courier New's metrics) */
    {"Courier", "LiberationMono"},
    {"Courier-Bold", "LiberationMono-Bold"},
    {"Courier-Oblique", "LiberationMono-Italic"},
    {"Courier-BoldOblique", "LiberationMono-BoldItalic"},
    {"Courier Bold", "LiberationMono-Bold"},
    {"Courier Oblique", "LiberationMono-Italic"},
    {"Courier Bold Oblique", "LiberationMono-BoldItalic"},
    {"Courier New", "LiberationMono"},
    {"CourierNewPSMT", "LiberationMono"},
    {"CourierNewPS-BoldMT", "LiberationMono-Bold"},
    {"CourierNewPS-ItalicMT", "LiberationMono-Italic"},
    {"CourierNewPS-BoldItalicMT", "LiberationMono-BoldItalic"},
    {"Courier New Bold", "LiberationMono-Bold"},
    {"Courier New Italic", "LiberationMono-Italic"},
    {"Courier New Bold Italic", "LiberationMono-BoldItalic"},

    /* Menlo and Monaco: DejaVu Sans Mono (Menlo is derived from it) */
    {"Menlo", "DejaVuSansMono"},
    {"Menlo-Regular", "DejaVuSansMono"},
    {"Menlo-Bold", "DejaVuSansMono-Bold"},
    {"Menlo-Italic", "DejaVuSansMono-Oblique"},
    {"Menlo-BoldItalic", "DejaVuSansMono-BoldOblique"},
    {"Menlo Regular", "DejaVuSansMono"},
    {"Menlo Bold", "DejaVuSansMono-Bold"},
    {"Menlo Italic", "DejaVuSansMono-Oblique"},
    {"Menlo Bold Italic", "DejaVuSansMono-BoldOblique"},
    {"Monaco", "DejaVuSansMono"},

    /* SF Mono: Fragment Mono; keep DejaVu for the missing bold faces. */
    {"SF Mono", "FragmentMono-Regular"},
    {"SFMono-Light", "FragmentMono-Regular"},
    {"SFMono-Regular", "FragmentMono-Regular"},
    {"SFMono-Medium", "FragmentMono-Regular"},
    {"SFMono-Semibold", "DejaVuSansMono-Bold"},
    {"SFMono-Bold", "DejaVuSansMono-Bold"},
    {"SFMono-Heavy", "DejaVuSansMono-Bold"},
    {"SFMono-RegularItalic", "FragmentMono-Italic"},
    {"SFMono-BoldItalic", "DejaVuSansMono-BoldOblique"},
    {".AppleSystemUIFontMonospaced", "FragmentMono-Regular"},
    {".SFNSMono-Regular", "FragmentMono-Regular"},
    {"SF Mono Regular", "FragmentMono-Regular"},
    {"SF Mono Italic", "FragmentMono-Italic"},
    {"SF Mono Bold", "DejaVuSansMono-Bold"},
    {"SF Mono Bold Italic", "DejaVuSansMono-BoldOblique"},
    {"SFMono-LightItalic", "FragmentMono-Italic"},
    {"SFMono-MediumItalic", "FragmentMono-Italic"},
    {"SFMono-SemiboldItalic", "DejaVuSansMono-BoldOblique"},
    {"SFMono-HeavyItalic", "DejaVuSansMono-BoldOblique"},
    {".AppleSystemUIFontMonospaced-Regular", "FragmentMono-Regular"},
    {".AppleSystemUIFontMonospaced-Italic", "FragmentMono-Italic"},
    {".AppleSystemUIFontMonospaced-Bold", "DejaVuSansMono-Bold"},
    {".AppleSystemUIFontMonospaced-BoldItalic", "DejaVuSansMono-BoldOblique"},
    {".SFNSMono-RegularItalic", "FragmentMono-Italic"},
    {".SFNSMono-Bold", "DejaVuSansMono-Bold"},
    {".SFNSMono-BoldItalic", "DejaVuSansMono-BoldOblique"},

    /* The system font (SF Pro), Lucida Grande: Inter, weight for weight */
    {".AppleSystemUIFont", "Inter-Regular"},
    {".AppleSystemUIFontBold", "Inter-Bold"},
    {".AppleSystemUIFontEmphasized", "Inter-Bold"},
    {".AppleSystemUIFontItalic", "Inter-Italic"},
    {".AppleSystemUIFontEmphasizedItalic", "Inter-BoldItalic"},
    {".AppleSystemUIFontDemi", "Inter-SemiBold"},
    {".AppleSystemUIFontHeavy", "Inter-ExtraBold"},
    {".AppleSystemUIFontBlack", "Inter-Black"},
    {".AppleSystemUIFontLight", "Inter-Light"},
    {".AppleSystemUIFontThin", "Inter-Thin"},
    {".AppleSystemUIFontUltraLight", "Inter-ExtraLight"},
    {".AppleSystemUIFontMedium", "Inter-Medium"},
    {"System Font", "Inter-Regular"},
    {".SF NS", "Inter-Regular"},
    {".SFNS-Ultralight", "Inter-ExtraLight"},
    {".SFNS-Thin", "Inter-Thin"},
    {".SFNS-Light", "Inter-Light"},
    {".SFNS-Regular", "Inter-Regular"},
    {".SFNS-Medium", "Inter-Medium"},
    {".SFNS-Semibold", "Inter-SemiBold"},
    {".SFNS-Bold", "Inter-Bold"},
    {".SFNS-Heavy", "Inter-ExtraBold"},
    {".SFNS-Black", "Inter-Black"},
    {".SFNS-RegularItalic", "Inter-Italic"},
    {".SFNS-BoldItalic", "Inter-BoldItalic"},
    {"SF Pro", "Inter-Regular"},
    {"SF Pro Text", "Inter-Regular"},
    {"SF Pro Display", "Inter-Regular"},
    {"SFPro-Regular", "Inter-Regular"},
    {"SFPro-Bold", "Inter-Bold"},
    {"SFProText-Ultralight", "Inter-ExtraLight"},
    {"SFProText-Thin", "Inter-Thin"},
    {"SFProText-Light", "Inter-Light"},
    {"SFProText-Regular", "Inter-Regular"},
    {"SFProText-Medium", "Inter-Medium"},
    {"SFProText-Semibold", "Inter-SemiBold"},
    {"SFProText-Bold", "Inter-Bold"},
    {"SFProText-Heavy", "Inter-ExtraBold"},
    {"SFProText-Black", "Inter-Black"},
    {"SFProText-RegularItalic", "Inter-Italic"},
    {"SFProText-BoldItalic", "Inter-BoldItalic"},
    {"SFProDisplay-Ultralight", "Inter-ExtraLight"},
    {"SFProDisplay-Thin", "Inter-Thin"},
    {"SFProDisplay-Light", "Inter-Light"},
    {"SFProDisplay-Regular", "Inter-Regular"},
    {"SFProDisplay-Medium", "Inter-Medium"},
    {"SFProDisplay-Semibold", "Inter-SemiBold"},
    {"SFProDisplay-Bold", "Inter-Bold"},
    {"SFProDisplay-Heavy", "Inter-ExtraBold"},
    {"SFProDisplay-Black", "Inter-Black"},
    {".Keyboard", "Inter-Regular"},
    {"Lucida Grande", "Inter-Regular"},
    {"LucidaGrande", "Inter-Regular"},
    {"LucidaGrande-Bold", "Inter-Bold"},
    {"Lucida Grande Bold", "Inter-Bold"},

    /* SF Pro Rounded: Open Runde's four weights; use the nearest weight. */
    {"SF Pro Rounded", "OpenRunde-Regular"},
    {".AppleSystemUIFontRounded", "OpenRunde-Regular"},
    {".AppleSystemUIFontRoundedBold", "OpenRunde-Bold"},
    {".AppleSystemUIFontRoundedEmphasized", "OpenRunde-Bold"},
    {".AppleSystemUIFontRoundedDemi", "OpenRunde-Semibold"},
    {".AppleSystemUIFontRoundedMedium", "OpenRunde-Medium"},
    {"SFProRounded-Ultralight", "OpenRunde-Regular"},
    {"SFProRounded-Thin", "OpenRunde-Regular"},
    {"SFProRounded-Light", "OpenRunde-Regular"},
    {"SFProRounded-Regular", "OpenRunde-Regular"},
    {"SFProRounded-Medium", "OpenRunde-Medium"},
    {"SFProRounded-Semibold", "OpenRunde-Semibold"},
    {"SFProRounded-Bold", "OpenRunde-Bold"},
    {"SFProRounded-Heavy", "OpenRunde-Bold"},
    {"SFProRounded-Black", "OpenRunde-Bold"},
    {".SFNSRounded-Ultralight", "OpenRunde-Regular"},
    {".SFNSRounded-Thin", "OpenRunde-Regular"},
    {".SFNSRounded-Light", "OpenRunde-Regular"},
    {".SFNSRounded-Regular", "OpenRunde-Regular"},
    {".SFNSRounded-Medium", "OpenRunde-Medium"},
    {".SFNSRounded-Semibold", "OpenRunde-Semibold"},
    {".SFNSRounded-Bold", "OpenRunde-Bold"},
    {".SFNSRounded-Heavy", "OpenRunde-Bold"},
    {".SFNSRounded-Black", "OpenRunde-Bold"},
    {".AppleSystemUIFontRounded-Ultralight", "OpenRunde-Regular"},
    {".AppleSystemUIFontRounded-Thin", "OpenRunde-Regular"},
    {".AppleSystemUIFontRounded-Light", "OpenRunde-Regular"},
    {".AppleSystemUIFontRounded-Regular", "OpenRunde-Regular"},
    {".AppleSystemUIFontRounded-Medium", "OpenRunde-Medium"},
    {".AppleSystemUIFontRounded-Semibold", "OpenRunde-Semibold"},
    {".AppleSystemUIFontRounded-Bold", "OpenRunde-Bold"},
    {".AppleSystemUIFontRounded-Heavy", "OpenRunde-Bold"},
    {".AppleSystemUIFontRounded-Black", "OpenRunde-Bold"},
    {"SF Pro Rounded Regular", "OpenRunde-Regular"},
    {"SF Pro Rounded Medium", "OpenRunde-Medium"},
    {"SF Pro Rounded Semibold", "OpenRunde-Semibold"},
    {"SF Pro Rounded Bold", "OpenRunde-Bold"},

    /* Charter and Palatino: open fonts from the same design families. */
    {"Charter", "XCharter-Roman"},
    {"Charter-Roman", "XCharter-Roman"},
    {"Charter-Bold", "XCharter-Bold"},
    {"Charter-Italic", "XCharter-Italic"},
    {"Charter-BoldItalic", "XCharter-BoldItalic"},
    {"Charter Roman", "XCharter-Roman"},
    {"Charter Bold", "XCharter-Bold"},
    {"Charter Italic", "XCharter-Italic"},
    {"Charter Bold Italic", "XCharter-BoldItalic"},
    {"Palatino", "TeXGyrePagella-Regular"},
    {"Palatino-Roman", "TeXGyrePagella-Regular"},
    {"Palatino-Bold", "TeXGyrePagella-Bold"},
    {"Palatino-Italic", "TeXGyrePagella-Italic"},
    {"Palatino-BoldItalic", "TeXGyrePagella-BoldItalic"},
    {"Palatino Roman", "TeXGyrePagella-Regular"},
    {"Palatino Bold", "TeXGyrePagella-Bold"},
    {"Palatino Italic", "TeXGyrePagella-Italic"},
    {"Palatino Bold Italic", "TeXGyrePagella-BoldItalic"},

    /* Emoji and symbols */
    {"Apple Color Emoji", "NotoColorEmoji"},
    {"AppleColorEmoji", "NotoColorEmoji"},
    {".Apple Color Emoji UI", "NotoColorEmoji"},
    {"Apple Symbols", "NotoSansSymbols-Regular"},
    {"AppleSymbols", "NotoSansSymbols-Regular"},

    /* Chinese, Japanese, Korean: Noto Sans CJK SC (every Noto CJK face covers all three) */
    {"PingFang SC", "NotoSansCJKsc-Regular"},
    {"PingFang TC", "NotoSansCJKsc-Regular"},
    {"PingFang HK", "NotoSansCJKsc-Regular"},
    {"PingFangSC-Ultralight", "NotoSansCJKsc-Regular"},
    {"PingFangSC-Thin", "NotoSansCJKsc-Regular"},
    {"PingFangSC-Light", "NotoSansCJKsc-Regular"},
    {"PingFangSC-Regular", "NotoSansCJKsc-Regular"},
    {"PingFangSC-Medium", "NotoSansCJKsc-Regular"},
    {"PingFangSC-Semibold", "NotoSansCJKsc-Bold"},
    {"PingFangTC-Regular", "NotoSansCJKsc-Regular"},
    {"PingFangTC-Medium", "NotoSansCJKsc-Regular"},
    {"PingFangTC-Semibold", "NotoSansCJKsc-Bold"},
    {"PingFangHK-Regular", "NotoSansCJKsc-Regular"},
    {"PingFangHK-Medium", "NotoSansCJKsc-Regular"},
    {"PingFangHK-Semibold", "NotoSansCJKsc-Bold"},
    {"Hiragino Sans", "NotoSansCJKsc-Regular"},
    {"HiraginoSans-W3", "NotoSansCJKsc-Regular"},
    {"HiraginoSans-W6", "NotoSansCJKsc-Bold"},
    {"Hiragino Kaku Gothic ProN", "NotoSansCJKsc-Regular"},
    {"HiraKakuProN-W3", "NotoSansCJKsc-Regular"},
    {"HiraKakuProN-W6", "NotoSansCJKsc-Bold"},
    {"Hiragino Kaku Gothic Pro", "NotoSansCJKsc-Regular"},
    {"HiraKakuPro-W3", "NotoSansCJKsc-Regular"},
    {"HiraKakuPro-W6", "NotoSansCJKsc-Bold"},
    {"Hiragino Mincho ProN", "NotoSansCJKsc-Regular"},
    {"HiraMinProN-W3", "NotoSansCJKsc-Regular"},
    {"HiraMinProN-W6", "NotoSansCJKsc-Bold"},
    {"Apple SD Gothic Neo", "NotoSansCJKsc-Regular"},
    {"AppleSDGothicNeo-Regular", "NotoSansCJKsc-Regular"},
    {"AppleSDGothicNeo-Bold", "NotoSansCJKsc-Bold"},
    {"Heiti SC", "NotoSansCJKsc-Regular"},
    {"STHeitiSC-Light", "NotoSansCJKsc-Regular"},
    {"STHeitiSC-Medium", "NotoSansCJKsc-Bold"},

    /* Arabic and Hebrew */
    {"Geeza Pro", "NotoSansArabic-Regular"},
    {"GeezaPro", "NotoSansArabic-Regular"},
    {"GeezaPro-Bold", "NotoSansArabic-Bold"},
    {"SF Arabic", "NotoSansArabic-Regular"},
    {".SFArabic-Regular", "NotoSansArabic-Regular"},
    {"Arial Hebrew", "NotoSansHebrew-Regular"},
    {"ArialHebrew", "NotoSansHebrew-Regular"},
    {"ArialHebrew-Bold", "NotoSansHebrew-Bold"},
    {"SF Hebrew", "NotoSansHebrew-Regular"},
    {".SFHebrew-Regular", "NotoSansHebrew-Regular"},
};

/* The PostScript name of the font Finch ships for an Apple font name, or NULL. */
static inline const char *
finch_font_alias(const char *name)
{
    for (size_t i = 0; i < sizeof finch_font_aliases / sizeof finch_font_aliases[0]; i++)
        if (!strcasecmp(finch_font_aliases[i].apple, name))
            return finch_font_aliases[i].finch;
    return 0;
}

/* The other way: the Apple PostScript name a Finch font stands in for, for
 * documents that name fonts (RTF). The first of its names that is a
 * PostScript name (no spaces, not a private ".name"), preferring "X-Regular"
 * or "X-Roman" over "X" when both are listed; 0 if it stands in for none. */
static inline const char *
finch_font_apple_name(const char *finch)
{
    const char *found = 0;
    for (size_t i = 0; i < sizeof finch_font_aliases / sizeof finch_font_aliases[0]; i++) {
        const char *apple = finch_font_aliases[i].apple;
        if (strcmp(finch_font_aliases[i].finch, finch) || apple[0] == '.' || strchr(apple, ' '))
            continue;
        if (!found) {
            found = apple;
        } else {
            size_t n = strlen(found);
            if (!strncmp(apple, found, n) && (!strcmp(apple + n, "-Regular") || !strcmp(apple + n, "-Roman")))
                return apple;
        }
    }
    return found;
}

#endif
