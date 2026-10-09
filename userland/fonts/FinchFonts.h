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

    /* Menlo, Monaco, SF Mono: DejaVu Sans Mono (Menlo is derived from it) */
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
    {"SF Mono", "DejaVuSansMono"},
    {"SFMono-Light", "DejaVuSansMono"},
    {"SFMono-Regular", "DejaVuSansMono"},
    {"SFMono-Medium", "DejaVuSansMono"},
    {"SFMono-Semibold", "DejaVuSansMono-Bold"},
    {"SFMono-Bold", "DejaVuSansMono-Bold"},
    {"SFMono-Heavy", "DejaVuSansMono-Bold"},
    {"SFMono-RegularItalic", "DejaVuSansMono-Oblique"},
    {"SFMono-BoldItalic", "DejaVuSansMono-BoldOblique"},
    {".AppleSystemUIFontMonospaced", "DejaVuSansMono"},
    {".SFNSMono-Regular", "DejaVuSansMono"},

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

#endif
