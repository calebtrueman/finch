/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGFont: a font file's glyphs and metrics, in font units. Metrics come from
 * the font's tables (head, hhea, OS/2, post, name, hmtx, fvar), glyph
 * bounds and variations from FreeType, and drawing goes through a Skia
 * typeface made from the same data (CGContextShowGlyphs*, CGFontInternal.h).
 */
#include "CGFontInternal.h"
#include "include/core/SkData.h"
#include "include/core/SkFontArguments.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkStream.h"
#include "include/ports/SkFontMgr_empty.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include FT_MULTIPLE_MASTERS_H
#include FT_TRUETYPE_TABLES_H
#include FT_COLOR_H
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

extern "C" {
const CFStringRef kCGFontVariationAxisName = CFSTR("kCGFontVariationAxisName");
const CFStringRef kCGFontVariationAxisMinValue = CFSTR("kCGFontVariationAxisMinValue");
const CFStringRef kCGFontVariationAxisMaxValue = CFSTR("kCGFontVariationAxisMaxValue");
const CFStringRef kCGFontVariationAxisDefaultValue = CFSTR("kCGFontVariationAxisDefaultValue");
}

static pthread_mutex_t ft_lock = PTHREAD_MUTEX_INITIALIZER;
static FT_Library ft_library;

#pragma mark - Table access

static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static int16_t sbe16(const uint8_t *p) { return (int16_t)be16(p); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

/* A table's bytes within the font data (face 0 of a collection), or NULL. */
static const uint8_t *
find_table(CGFontRef f, uint32_t tag, size_t *len)
{
    const uint8_t *d = f->bytes;
    size_t n = f->length;
    size_t base = 0;
    if (n >= 12 && be32(d) == 'ttcf')
        base = be32(d + 12);
    if (base + 12 > n)
        return NULL;
    uint16_t count = be16(d + base + 4);
    for (uint16_t i = 0; i < count; i++) {
        const uint8_t *rec = d + base + 12 + 16 * i;
        if (rec + 16 > d + n)
            return NULL;
        if (be32(rec) == tag) {
            uint32_t off = be32(rec + 8), length = be32(rec + 12);
            if ((size_t)off + length > n)
                return NULL;
            if (len)
                *len = length;
            return d + off;
        }
    }
    return NULL;
}

/* A string from the name table (Windows Unicode preferred, then Mac Roman). */
static CFStringRef
name_string(CGFontRef f, uint16_t id)
{
    size_t len;
    const uint8_t *t = find_table(f, 'name', &len);
    if (!t || len < 6)
        return NULL;
    uint16_t count = be16(t + 2), storage = be16(t + 4);
    CFStringRef mac = NULL;
    for (uint16_t i = 0; i < count && 6 + 12 * (size_t)(i + 1) <= len; i++) {
        const uint8_t *r = t + 6 + 12 * i;
        uint16_t platform = be16(r), encoding = be16(r + 2), name = be16(r + 6), length = be16(r + 8), offset = be16(r + 10);
        if (name != id || (size_t)storage + offset + length > len)
            continue;
        const uint8_t *s = t + storage + offset;
        if (platform == 3 || platform == 0) {
            if (mac)
                CFRelease(mac);
            return CFStringCreateWithBytes(NULL, s, length, kCFStringEncodingUTF16BE, false);
        }
        if (platform == 1 && encoding == 0 && !mac)
            mac = CFStringCreateWithBytes(NULL, s, length, kCFStringEncodingMacRoman, false);
    }
    return mac;
}

#pragma mark - CF type

static void
font_finalize(CFTypeRef cf)
{
    struct CGFont *f = (struct CGFont *)cf;
    if (f->face) {
        pthread_mutex_lock(&ft_lock);
        FT_Done_Face((FT_Face)f->face);
        pthread_mutex_unlock(&ft_lock);
    }
    if (f->typeface)
        ((SkTypeface *)f->typeface)->unref();
    if (f->data)
        CFRelease(f->data);
    if (f->variations)
        CFRelease(f->variations);
    delete f->coords;
    delete f->color;
}

static CFStringRef
font_desc(CFTypeRef cf)
{
    CGFontRef f = (CGFontRef)cf;
    CFStringRef ps = CGFontCopyPostScriptName(f);
    CFStringRef d = CFStringCreateWithFormat(NULL, NULL, CFSTR("<CGFont (%p): %@>"), f, ps ? ps : CFSTR(""));
    if (ps)
        CFRelease(ps);
    return d;
}

static const CGRuntimeClass font_class = {
    0, "CGFont", NULL, NULL, font_finalize, NULL, NULL, NULL, font_desc, NULL, NULL, 0,
};
static CFTypeID font_type;

CFTypeID
CGFontGetTypeID(void)
{
    return CGTypeRegister(&font_class, &font_type);
}

/* FreeType leaves units_per_EM 0 for a font with only bitmaps (CBDT, sbix); its head table still has it. */
static int
units_per_em(FT_Face face)
{
    if (face->units_per_EM)
        return face->units_per_EM;
    TT_Header *head = (TT_Header *)FT_Get_Sfnt_Table(face, FT_SFNT_HEAD);
    return head && head->Units_Per_EM ? head->Units_Per_EM : 1000;
}

static struct CGFont *
font_from_data(CFDataRef data, const std::vector<double> *coords)
{
    pthread_mutex_lock(&ft_lock);
    if (!ft_library && FT_Init_FreeType(&ft_library)) {
        pthread_mutex_unlock(&ft_lock);
        return NULL;
    }
    FT_Face face;
    FT_Error err = FT_New_Memory_Face(ft_library, CFDataGetBytePtr(data), CFDataGetLength(data), 0, &face);
    pthread_mutex_unlock(&ft_lock);
    if (err)
        return NULL;
    struct CGFont *f = (struct CGFont *)CGTypeCreateInstance(CGFontGetTypeID(), sizeof(struct CGFont));
    f->data = (CFDataRef)CFRetain(data);
    f->bytes = CFDataGetBytePtr(data);
    f->length = (size_t)CFDataGetLength(data);
    f->face = face;
    f->units_per_em = units_per_em(face);
    f->glyph_count = (size_t)face->num_glyphs;
    f->coords = coords ? new std::vector<double>(*coords) : NULL;
    if (coords && FT_HAS_MULTIPLE_MASTERS(face)) {
        std::vector<FT_Fixed> fixed;
        for (double v : *coords)
            fixed.push_back((FT_Fixed)lround(v * 65536));
        FT_Set_Var_Design_Coordinates(face, (FT_UInt)fixed.size(), fixed.data());
    }
    return f;
}

CGFontRef
CGFontCreateWithDataProvider(CGDataProviderRef provider)
{
    CFDataRef data = provider ? CGDataProviderCopyData(provider) : NULL;
    if (!data)
        return NULL;
    struct CGFont *f = font_from_data(data, NULL);
    CFRelease(data);
    return f;
}

CGFontRef
CGFontCreateWithFontName(CFStringRef name)
{
    CFDataRef data = name ? CGFontRegistryCopyDataForName(name) : NULL;
    if (!data)
        return NULL;
    struct CGFont *f = font_from_data(data, NULL);
    CFRelease(data);
    return f;
}

CGFontRef
CGFontCreateWithPlatformFont(void *ref)
{
    return NULL;
}

/*
 * Finch's own (not Apple's API): the font's file data and variation
 * coordinates, for CoreText, which shapes with the same bytes.
 */
extern "C" CFDataRef CGFontFinchCopyData(CGFontRef f, CFIndex *axisCount, double *coords, CFIndex maxCoords);

CFDataRef
CGFontFinchCopyData(CGFontRef f, CFIndex *axisCount, double *coords, CFIndex maxCoords)
{
    if (!f)
        return NULL;
    CFIndex n = f->coords ? (CFIndex)f->coords->size() : 0;
    if (axisCount)
        *axisCount = n;
    for (CFIndex i = 0; coords && i < n && i < maxCoords; i++)
        coords[i] = (*f->coords)[i];
    return (CFDataRef)CFRetain(f->data);
}

CGFontRef CGFontRetain(CGFontRef f) { return f ? (CGFontRef)CFRetain(f) : NULL; }
void CGFontRelease(CGFontRef f) { if (f) CFRelease(f); }

#pragma mark - Metrics

size_t CGFontGetNumberOfGlyphs(CGFontRef f) { return f ? f->glyph_count : 0; }
int CGFontGetUnitsPerEm(CGFontRef f) { return f ? f->units_per_em : 0; }
CFStringRef CGFontCopyPostScriptName(CGFontRef f) { return f ? name_string(f, 6) : NULL; }
CFStringRef CGFontCopyFullName(CGFontRef f) { return f ? name_string(f, 4) : NULL; }

int
CGFontGetAscent(CGFontRef f)
{
    size_t len;
    const uint8_t *t = f ? find_table(f, 'hhea', &len) : NULL;
    return t && len >= 10 ? sbe16(t + 4) : 0;
}

int
CGFontGetDescent(CGFontRef f)
{
    size_t len;
    const uint8_t *t = f ? find_table(f, 'hhea', &len) : NULL;
    return t && len >= 10 ? sbe16(t + 6) : 0;
}

int
CGFontGetLeading(CGFontRef f)
{
    size_t len;
    const uint8_t *t = f ? find_table(f, 'hhea', &len) : NULL;
    return t && len >= 10 ? sbe16(t + 8) : 0;
}

/* OS/2 version 2 and later carry the cap and x heights; otherwise measure H and x. */
static int
glyph_height(CGFontRef f, FT_ULong ch)
{
    FT_Face face = (FT_Face)f->face;
    pthread_mutex_lock(&ft_lock);
    FT_UInt g = FT_Get_Char_Index(face, ch);
    int h = 0;
    if (g && !FT_Load_Glyph(face, g, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING)) {
        FT_BBox box;
        FT_Outline_Get_CBox(&face->glyph->outline, &box);
        h = (int)box.yMax;
    }
    pthread_mutex_unlock(&ft_lock);
    return h;
}

int
CGFontGetCapHeight(CGFontRef f)
{
    size_t len;
    const uint8_t *t = f ? find_table(f, 'OS/2', &len) : NULL;
    if (t && len >= 90 && be16(t) >= 2)
        return sbe16(t + 88);
    return f ? glyph_height(f, 'H') : 0;
}

int
CGFontGetXHeight(CGFontRef f)
{
    size_t len;
    const uint8_t *t = f ? find_table(f, 'OS/2', &len) : NULL;
    if (t && len >= 88 && be16(t) >= 2)
        return sbe16(t + 86);
    return f ? glyph_height(f, 'x') : 0;
}

CGRect
CGFontGetFontBBox(CGFontRef f)
{
    size_t len;
    const uint8_t *t = f ? find_table(f, 'head', &len) : NULL;
    if (!t || len < 44)
        return CGRectZero;
    int x0 = sbe16(t + 36), y0 = sbe16(t + 38), x1 = sbe16(t + 40), y1 = sbe16(t + 42);
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

CGFloat
CGFontGetItalicAngle(CGFontRef f)
{
    size_t len;
    const uint8_t *t = f ? find_table(f, 'post', &len) : NULL;
    return t && len >= 8 ? (int32_t)be32(t + 4) / 65536.0 : 0;
}

CGFloat
CGFontGetStemV(CGFontRef f)
{
    return 0;  /* TrueType fonts have none; CFF's StdVW is not read yet */
}

bool
CGFontGetGlyphAdvances(CGFontRef f, const CGGlyph *glyphs, size_t count, int *advances)
{
    if (!f || !glyphs || !advances)
        return false;
    size_t hlen, mlen;
    const uint8_t *hhea = find_table(f, 'hhea', &hlen), *hmtx = find_table(f, 'hmtx', &mlen);
    uint16_t nmetrics = hhea && hlen >= 36 ? be16(hhea + 34) : 0;
    for (size_t i = 0; i < count; i++) {
        CGGlyph g = glyphs[i];
        int adv = 0;
        if (g < f->glyph_count && nmetrics && hmtx) {
            size_t k = g < nmetrics ? g : nmetrics - 1;
            if (4 * k + 2 <= mlen)
                adv = be16(hmtx + 4 * k);
        }
        advances[i] = adv;
    }
    return true;
}

/*
 * A bitmap-only font's glyph: load it from the largest strike (with the
 * lock held). The strike is the face's only size state; everything else
 * loads unscaled.
 */
static bool
load_bitmap(CGFontRef f, CGGlyph glyph, FT_Int32 flags)
{
    FT_Face face = (FT_Face)f->face;
    if (!FT_HAS_FIXED_SIZES(face))
        return false;
    int best = 0;
    for (int i = 1; i < face->num_fixed_sizes; i++)
        if (face->available_sizes[i].y_ppem > face->available_sizes[best].y_ppem)
            best = i;
    if (!face->size || face->size->metrics.y_ppem != (face->available_sizes[best].y_ppem + 32) >> 6)
        FT_Select_Size(face, best);
    return !FT_Load_Glyph(face, glyph, flags) && face->glyph->format == FT_GLYPH_FORMAT_BITMAP;
}

/* Its bounds: the bitmap's extent at the strike, in font units. */
static void
bitmap_bbox(CGFontRef f, CGGlyph glyph, CGRect *box)
{
    FT_Face face = (FT_Face)f->face;
    if (!load_bitmap(f, glyph, FT_LOAD_COLOR | FT_LOAD_BITMAP_METRICS_ONLY) || !face->size->metrics.y_ppem)
        return;
    double s = (double)f->units_per_em / face->size->metrics.y_ppem;
    FT_GlyphSlot slot = face->glyph;
    *box = CGRectMake(slot->bitmap_left * s, (slot->bitmap_top - (int)slot->bitmap.rows) * s,
                      slot->bitmap.width * s, slot->bitmap.rows * s);
}

/*
 * Whether a glyph has a colour form: layers in COLR (version 0), or a
 * colour bitmap (CBDT, sbix). Checked once per glyph and cached. COLR
 * version 1 paint graphs aren't counted: Apple's CoreText draws those
 * glyphs as their outlines (measured on macOS 26), and so does Finch's.
 */
bool
CGFontGlyphIsColor(CGFontRef f, CGGlyph glyph)
{
    if (!f || glyph >= f->glyph_count || !FT_HAS_COLOR((FT_Face)f->face))
        return false;
    FT_Face face = (FT_Face)f->face;
    pthread_mutex_lock(&ft_lock);
    std::vector<uint8_t> *&known = ((struct CGFont *)f)->color;
    if (!known)
        known = new std::vector<uint8_t>(f->glyph_count, 0);
    uint8_t &k = (*known)[glyph];
    if (!k) {
        FT_UInt layer, color;
        FT_LayerIterator it = {};
        bool yes = FT_Get_Color_Glyph_Layer(face, glyph, &layer, &color, &it) ||
                   (load_bitmap(f, glyph, FT_LOAD_COLOR | FT_LOAD_BITMAP_METRICS_ONLY) &&
                    face->glyph->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA);
        k = yes ? 2 : 1;
    }
    bool yes = k == 2;
    pthread_mutex_unlock(&ft_lock);
    return yes;
}

/*
 * A glyph's outline from FreeType, in font units (y up), or NULL. Skia
 * gives no outline for a glyph it draws in colour (COLR), but CG fills
 * those with their base glyph's outline.
 */
CGPathRef
CGFontCopyGlyphOutline(CGFontRef f, CGGlyph glyph)
{
    if (!f || glyph >= f->glyph_count)
        return NULL;
    FT_Face face = (FT_Face)f->face;
    pthread_mutex_lock(&ft_lock);
    if (FT_Load_Glyph(face, glyph, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING) ||
        face->glyph->format != FT_GLYPH_FORMAT_OUTLINE || face->glyph->outline.n_points == 0) {
        pthread_mutex_unlock(&ft_lock);
        return NULL;
    }
    CGMutablePathRef path = CGPathCreateMutable();
    FT_Outline_Funcs funcs = {
        [](const FT_Vector *to, void *u) -> int {
            CGMutablePathRef p = (CGMutablePathRef)u;
            if (!CGPathIsEmpty(p))
                CGPathCloseSubpath(p);
            CGPathMoveToPoint(p, NULL, to->x, to->y);
            return 0;
        },
        [](const FT_Vector *to, void *u) -> int {
            CGPathAddLineToPoint((CGMutablePathRef)u, NULL, to->x, to->y);
            return 0;
        },
        [](const FT_Vector *c, const FT_Vector *to, void *u) -> int {
            CGPathAddQuadCurveToPoint((CGMutablePathRef)u, NULL, c->x, c->y, to->x, to->y);
            return 0;
        },
        [](const FT_Vector *c1, const FT_Vector *c2, const FT_Vector *to, void *u) -> int {
            CGPathAddCurveToPoint((CGMutablePathRef)u, NULL, c1->x, c1->y, c2->x, c2->y, to->x, to->y);
            return 0;
        },
        0, 0,
    };
    FT_Outline_Decompose(&face->glyph->outline, &funcs, path);
    if (!CGPathIsEmpty(path))
        CGPathCloseSubpath(path);
    pthread_mutex_unlock(&ft_lock);
    return path;
}

bool
CGFontGetGlyphBBoxes(CGFontRef f, const CGGlyph *glyphs, size_t count, CGRect *bboxes)
{
    if (!f || !glyphs || !bboxes)
        return false;
    FT_Face face = (FT_Face)f->face;
    pthread_mutex_lock(&ft_lock);
    for (size_t i = 0; i < count; i++) {
        bboxes[i] = CGRectZero;
        if (glyphs[i] >= f->glyph_count)
            continue;
        if (!FT_IS_SCALABLE(face)) {
            bitmap_bbox(f, glyphs[i], &bboxes[i]);
            continue;
        }
        if (FT_Load_Glyph(face, glyphs[i], FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING))
            continue;
        if (face->glyph->format != FT_GLYPH_FORMAT_OUTLINE || face->glyph->outline.n_points == 0)
            continue;
        FT_BBox box;
        FT_Outline_Get_CBox(&face->glyph->outline, &box);
        bboxes[i] = CGRectMake(box.xMin, box.yMin, box.xMax - box.xMin, box.yMax - box.yMin);
    }
    pthread_mutex_unlock(&ft_lock);
    return true;
}

#pragma mark - Glyph names

/* The 258 standard Macintosh glyph names (TrueType 'post' table). */
static const char *const mac_names[258] = {
    ".notdef", ".null", "nonmarkingreturn", "space", "exclam", "quotedbl", "numbersign", "dollar", "percent",
    "ampersand", "quotesingle", "parenleft", "parenright", "asterisk", "plus", "comma", "hyphen", "period", "slash",
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "colon", "semicolon", "less",
    "equal", "greater", "question", "at", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "bracketleft", "backslash", "bracketright",
    "asciicircum", "underscore", "grave", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "braceleft", "bar", "braceright", "asciitilde",
    "Adieresis", "Aring", "Ccedilla", "Eacute", "Ntilde", "Odieresis", "Udieresis", "aacute", "agrave",
    "acircumflex", "adieresis", "atilde", "aring", "ccedilla", "eacute", "egrave", "ecircumflex", "edieresis",
    "iacute", "igrave", "icircumflex", "idieresis", "ntilde", "oacute", "ograve", "ocircumflex", "odieresis",
    "otilde", "uacute", "ugrave", "ucircumflex", "udieresis", "dagger", "degree", "cent", "sterling", "section",
    "bullet", "paragraph", "germandbls", "registered", "copyright", "trademark", "acute", "dieresis", "notequal",
    "AE", "Oslash", "infinity", "plusminus", "lessequal", "greaterequal", "yen", "mu", "partialdiff", "summation",
    "product", "pi", "integral", "ordfeminine", "ordmasculine", "Omega", "ae", "oslash", "questiondown",
    "exclamdown", "logicalnot", "radical", "florin", "approxequal", "Delta", "guillemotleft", "guillemotright",
    "ellipsis", "nonbreakingspace", "Agrave", "Atilde", "Otilde", "OE", "oe", "endash", "emdash", "quotedblleft",
    "quotedblright", "quoteleft", "quoteright", "divide", "lozenge", "ydieresis", "Ydieresis", "fraction",
    "currency", "guilsinglleft", "guilsinglright", "fi", "fl", "daggerdbl", "periodcentered", "quotesinglbase",
    "quotedblbase", "perthousand", "Acircumflex", "Ecircumflex", "Aacute", "Edieresis", "Egrave", "Iacute",
    "Icircumflex", "Idieresis", "Igrave", "Oacute", "Ocircumflex", "apple", "Ograve", "Uacute", "Ucircumflex",
    "Ugrave", "dotlessi", "circumflex", "tilde", "macron", "breve", "dotaccent", "ring", "cedilla", "hungarumlaut",
    "ogonek", "caron", "Lslash", "lslash", "Scaron", "scaron", "Zcaron", "zcaron", "brokenbar", "Eth", "eth",
    "Yacute", "yacute", "Thorn", "thorn", "minus", "multiply", "onesuperior", "twosuperior", "threesuperior",
    "onehalf", "onequarter", "threequarters", "franc", "Gbreve", "gbreve", "Idotaccent", "Scedilla", "scedilla",
    "Cacute", "cacute", "Ccaron", "ccaron", "dcroat",
};

/* The glyph's name from 'post' (formats 1 and 2), or "" when the font has none. */
static std::string
post_name(CGFontRef f, CGGlyph g)
{
    size_t len;
    const uint8_t *t = find_table(f, 'post', &len);
    if (!t || len < 32)
        return "";
    uint32_t format = be32(t);
    if (format == 0x00010000)
        return g < 258 ? mac_names[g] : "";
    if (format != 0x00020000 || len < 34)
        return "";
    uint16_t n = be16(t + 32);
    if (g >= n || 34 + 2 * (size_t)n > len)
        return "";
    uint16_t idx = be16(t + 34 + 2 * g);
    if (idx < 258)
        return mac_names[idx];
    /* Pascal strings after the index array */
    const uint8_t *p = t + 34 + 2 * n, *end = t + len;
    for (uint16_t k = 258; p < end; k++) {
        uint8_t l = *p;
        if (k == idx)
            return p + 1 + l <= end ? std::string((const char *)p + 1, l) : "";
        p += 1 + l;
    }
    return "";
}

CFStringRef
CGFontCopyGlyphNameForGlyph(CGFontRef f, CGGlyph g)
{
    if (!f || g >= f->glyph_count)
        return NULL;
    std::string name = post_name(f, g);
    if (name.empty())
        name = g == 0 ? ".notdef" : "gid" + std::to_string(g);
    return CFStringCreateWithCString(NULL, name.c_str(), kCFStringEncodingUTF8);
}

CGGlyph
CGFontGetGlyphWithGlyphName(CGFontRef f, CFStringRef name)
{
    if (!f || !name)
        return 0;
    char buf[256];
    if (!CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8))
        return 0;
    for (size_t g = 0; g < f->glyph_count; g++)
        if (post_name(f, (CGGlyph)g) == buf)
            return (CGGlyph)g;
    return 0;
}

#pragma mark - Tables

CFArrayRef
CGFontCopyTableTags(CGFontRef f)
{
    if (!f)
        return NULL;
    const uint8_t *d = f->bytes;
    size_t base = f->length >= 16 && be32(d) == 'ttcf' ? be32(d + 12) : 0;
    if (base + 12 > f->length)
        return NULL;
    uint16_t count = be16(d + base + 4);
    CFMutableArrayRef tags = CFArrayCreateMutable(NULL, count, NULL);
    for (uint16_t i = 0; i < count && base + 12 + 16 * (size_t)(i + 1) <= f->length; i++)
        CFArrayAppendValue(tags, (const void *)(uintptr_t)be32(d + base + 12 + 16 * i));
    return tags;
}

CFDataRef
CGFontCopyTableForTag(CGFontRef f, uint32_t tag)
{
    size_t len;
    const uint8_t *t = f ? find_table(f, tag, &len) : NULL;
    return t ? CFDataCreate(NULL, t, (CFIndex)len) : NULL;
}

bool
CGFontCanCreatePostScriptSubset(CGFontRef f, CGFontPostScriptFormat format)
{
    return f && (format == kCGFontPostScriptFormatType1 || format == kCGFontPostScriptFormatType42);
}

CFDataRef
CGFontCreatePostScriptSubset(CGFontRef f, CFStringRef subsetName, CGFontPostScriptFormat format, const CGGlyph *glyphs,
                             size_t count, const CGGlyph encoding[256])
{
    return NULL;  /* PostScript output is not supported */
}

CFDataRef
CGFontCreatePostScriptEncoding(CGFontRef f, const CGGlyph encoding[256])
{
    return NULL;
}

#pragma mark - Variations

namespace {
struct Axis {
    uint32_t tag;
    double min, def, max;
    uint16_t name_id;
};
}  // namespace

static std::vector<Axis>
axes(CGFontRef f)
{
    std::vector<Axis> out;
    size_t len;
    const uint8_t *t = find_table(f, 'fvar', &len);
    if (!t || len < 16)
        return out;
    uint16_t offset = be16(t + 4), count = be16(t + 8), size = be16(t + 10);
    for (uint16_t i = 0; i < count && (size_t)offset + (size_t)size * (i + 1) <= len; i++) {
        const uint8_t *a = t + offset + size * i;
        out.push_back({be32(a), (int32_t)be32(a + 4) / 65536.0, (int32_t)be32(a + 8) / 65536.0,
                       (int32_t)be32(a + 12) / 65536.0, be16(a + 18)});
    }
    return out;
}

static CFStringRef
axis_name(CGFontRef f, const Axis &a)
{
    CFStringRef n = name_string(f, a.name_id);
    if (n)
        return n;
    char tag[5] = {(char)(a.tag >> 24), (char)(a.tag >> 16), (char)(a.tag >> 8), (char)a.tag, 0};
    return CFStringCreateWithCString(NULL, tag, kCFStringEncodingASCII);
}

static CFNumberRef
number(double v)
{
    return CFNumberCreate(NULL, kCFNumberDoubleType, &v);
}

CFArrayRef
CGFontCopyVariationAxes(CGFontRef f)
{
    if (!f)
        return NULL;
    std::vector<Axis> list = axes(f);
    if (list.empty())
        return NULL;
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, (CFIndex)list.size(), &kCFTypeArrayCallBacks);
    for (const Axis &a : list) {
        CFStringRef name = axis_name(f, a);
        CFNumberRef mn = number(a.min), mx = number(a.max), df = number(a.def);
        const void *keys[] = {kCGFontVariationAxisName, kCGFontVariationAxisMinValue, kCGFontVariationAxisMaxValue,
                              kCGFontVariationAxisDefaultValue};
        const void *vals[] = {name, mn, mx, df};
        CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, 4, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(out, d);
        CFRelease(d), CFRelease(name), CFRelease(mn), CFRelease(mx), CFRelease(df);
    }
    return out;
}

CFDictionaryRef
CGFontCopyVariations(CGFontRef f)
{
    if (!f)
        return NULL;
    std::vector<Axis> list = axes(f);
    if (list.empty())
        return NULL;
    CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                           &kCFTypeDictionaryValueCallBacks);
    for (size_t i = 0; i < list.size(); i++) {
        CFStringRef name = axis_name(f, list[i]);
        CFNumberRef v = number(f->coords && i < f->coords->size() ? (*f->coords)[i] : list[i].def);
        CFDictionarySetValue(out, name, v);
        CFRelease(name), CFRelease(v);
    }
    return out;
}

CGFontRef
CGFontCreateCopyWithVariations(CGFontRef f, CFDictionaryRef variations)
{
    if (!f)
        return NULL;
    std::vector<Axis> list = axes(f);
    if (list.empty() || !variations)
        return CGFontRetain(f);
    std::vector<double> coords;
    for (size_t i = 0; i < list.size(); i++) {
        double v = f->coords && i < f->coords->size() ? (*f->coords)[i] : list[i].def;
        CFStringRef name = axis_name(f, list[i]);
        CFTypeRef given = CFDictionaryGetValue(variations, name);
        CFRelease(name);
        if (!given) {
            /* also accept the axis tag as a number */
            CFNumberRef tag = CFNumberCreate(NULL, kCFNumberSInt32Type, &list[i].tag);
            given = CFDictionaryGetValue(variations, tag);
            CFRelease(tag);
        }
        if (given && CFGetTypeID(given) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)given, kCFNumberDoubleType, &v);
        coords.push_back(fmin(list[i].max, fmax(list[i].min, v)));
    }
    return font_from_data(f->data, &coords);
}

#pragma mark - Skia

sk_sp<SkTypeface>
CGFontGetTypeface(CGFontRef f)
{
    pthread_mutex_lock(&ft_lock);
    SkTypeface *tf = (SkTypeface *)f->typeface;
    if (tf) {
        tf->ref();
        pthread_mutex_unlock(&ft_lock);
        return sk_sp<SkTypeface>(tf);
    }
    pthread_mutex_unlock(&ft_lock);
    static sk_sp<SkFontMgr> mgr = SkFontMgr_New_Custom_Empty();
    CFRetain(f->data);
    sk_sp<SkData> data = SkData::MakeWithProc(f->bytes, f->length,
                                              [](const void *, void *ctx) { CFRelease((CFDataRef)ctx); },
                                              (void *)f->data);
    SkFontArguments args;
    std::vector<SkFontArguments::VariationPosition::Coordinate> coords;
    if (f->coords) {
        std::vector<Axis> list = axes(f);
        for (size_t i = 0; i < list.size() && i < f->coords->size(); i++)
            coords.push_back({list[i].tag, (float)(*f->coords)[i]});
        args.setVariationDesignPosition({coords.data(), (int)coords.size()});
    }
    sk_sp<SkTypeface> made = mgr->makeFromStream(SkMemoryStream::Make(data), args);
    if (!made)
        return nullptr;
    pthread_mutex_lock(&ft_lock);
    if (!f->typeface) {
        made->ref();
        ((struct CGFont *)f)->typeface = made.get();
    }
    pthread_mutex_unlock(&ft_lock);
    return made;
}
