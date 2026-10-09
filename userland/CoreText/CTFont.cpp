/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CTFont: a CGFont at a size and matrix. Metrics come from the font's tables
 * as Apple's do (hhea, or OS/2 typographic metrics when the font asks for
 * them; post for underlines and slant), glyph outlines and boxes from
 * FreeType, and shaping (CTLine) from HarfBuzz over the same bytes.
 */
#include "CTInternal.h"
#include "CTRegistry.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include FT_MULTIPLE_MASTERS_H
#include FT_TRUETYPE_TABLES_H
#include <hb.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <map>
#include <string>

static pthread_mutex_t ft_lock = PTHREAD_MUTEX_INITIALIZER;
static FT_Library ft_library;

void CTFontLockFace(CTFontRef) { pthread_mutex_lock(&ft_lock); }
void CTFontUnlockFace(CTFontRef) { pthread_mutex_unlock(&ft_lock); }

#pragma mark - CF type

static void
font_finalize(CFTypeRef cf)
{
    struct __CTFont *f = (struct __CTFont *)cf;
    if (f->hb)
        hb_font_destroy((hb_font_t *)f->hb);
    if (f->face) {
        pthread_mutex_lock(&ft_lock);
        FT_Done_Face((FT_Face)f->face);
        pthread_mutex_unlock(&ft_lock);
    }
    if (f->data)
        CFRelease(f->data);
    if (f->cg)
        CFRelease(f->cg);
    if (f->descriptor)
        CFRelease(f->descriptor);
    delete f->coords;
}

static CFStringRef
font_desc(CFTypeRef cf)
{
    CTFontRef f = (CTFontRef)cf;
    CFStringRef ps = CTFontCopyPostScriptName(f), fam = CTFontCopyFamilyName(f);
    CFStringRef d = CFStringCreateWithFormat(NULL, NULL, CFSTR("<CTFont: %p>{name = %@, size = %f, matrix = [%.1f %.1f %.1f %.1f %.1f %.1f], descriptor = <CTFontDescriptor: %p>}"),
                                             f, ps ? ps : CFSTR(""), f->size, f->matrix.a, f->matrix.b, f->matrix.c,
                                             f->matrix.d, f->matrix.tx, f->matrix.ty, f->descriptor);
    if (ps)
        CFRelease(ps);
    if (fam)
        CFRelease(fam);
    return d;
}

static Boolean
font_equal(CFTypeRef a, CFTypeRef b)
{
    CTFontRef x = (CTFontRef)a, y = (CTFontRef)b;
    return x->size == y->size && CGAffineTransformEqualToTransform(x->matrix, y->matrix) &&
           (x->data == y->data || CFEqual(x->data, y->data)) &&
           (x->coords == y->coords || (x->coords && y->coords && *x->coords == *y->coords));
}

static CFHashCode
font_hash(CFTypeRef cf)
{
    CTFontRef f = (CTFontRef)cf;
    return (CFHashCode)(f->length * 31 + (size_t)(f->size * 64));
}

static const CTRuntimeClass font_class = {
    0, "CTFont", NULL, NULL, font_finalize, font_equal, font_hash, NULL, font_desc, NULL, NULL, 0,
};
static CFTypeID font_type;

CFTypeID
CTFontGetTypeID(void)
{
    return CTTypeRegister(&font_class, &font_type);
}

#pragma mark - Tables and names

const uint8_t *
CTFontTable(CTFontRef f, uint32_t tag, size_t *length)
{
    const uint8_t *d = f->bytes;
    size_t n = f->length, base = 0;
    if (n >= 16 && ct_be32(d) == 'ttcf')
        base = ct_be32(d + 12);
    if (base + 12 > n)
        return NULL;
    uint16_t count = ct_be16(d + base + 4);
    for (uint16_t i = 0; i < count && base + 12 + 16 * (size_t)(i + 1) <= n; i++) {
        const uint8_t *rec = d + base + 12 + 16 * i;
        if (ct_be32(rec) == tag) {
            size_t off = ct_be32(rec + 8), len = ct_be32(rec + 12);
            if (off + len > n)
                return NULL;
            if (length)
                *length = len;
            return d + off;
        }
    }
    return NULL;
}

CFStringRef
CTFontNameString(CTFontRef f, uint16_t id)
{
    size_t len;
    const uint8_t *t = CTFontTable(f, 'name', &len);
    if (!t || len < 6)
        return NULL;
    uint16_t count = ct_be16(t + 2), storage = ct_be16(t + 4);
    CFStringRef mac = NULL;
    for (uint16_t i = 0; i < count && 6 + 12 * (size_t)(i + 1) <= len; i++) {
        const uint8_t *r = t + 6 + 12 * i;
        uint16_t platform = ct_be16(r), encoding = ct_be16(r + 2), name = ct_be16(r + 6), length = ct_be16(r + 8),
                 offset = ct_be16(r + 10);
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

static int16_t s16(const uint8_t *p) { return (int16_t)ct_be16(p); }

#pragma mark - Creating

static struct __CTFont *
font_from_graphics(CGFontRef cg, CGFloat size, const CGAffineTransform *matrix)
{
    CFIndex naxes = 0;
    double coords[64];
    CFDataRef data = CGFontFinchCopyData(cg, &naxes, coords, 64);
    if (!data)
        return NULL;
    pthread_mutex_lock(&ft_lock);
    if (!ft_library && FT_Init_FreeType(&ft_library)) {
        pthread_mutex_unlock(&ft_lock);
        CFRelease(data);
        return NULL;
    }
    FT_Face face;
    FT_Error err = FT_New_Memory_Face(ft_library, CFDataGetBytePtr(data), CFDataGetLength(data), 0, &face);
    if (!err && naxes && FT_HAS_MULTIPLE_MASTERS(face)) {
        FT_Fixed fixed[64];
        for (CFIndex i = 0; i < naxes && i < 64; i++)
            fixed[i] = (FT_Fixed)lround(coords[i] * 65536);
        FT_Set_Var_Design_Coordinates(face, (FT_UInt)naxes, fixed);
    }
    pthread_mutex_unlock(&ft_lock);
    if (err) {
        CFRelease(data);
        return NULL;
    }
    struct __CTFont *f = (struct __CTFont *)CTTypeCreateInstance(CTFontGetTypeID(), sizeof(struct __CTFont));
    f->cg = (CGFontRef)CFRetain(cg);
    f->data = data;
    f->bytes = CFDataGetBytePtr(data);
    f->length = (size_t)CFDataGetLength(data);
    f->face = face;
    /* a font with only bitmaps (CBDT, sbix) has units per em in its head table, though FreeType reports 0 */
    TT_Header *head = (TT_Header *)FT_Get_Sfnt_Table(face, FT_SFNT_HEAD);
    f->upem = face->units_per_EM ? face->units_per_EM : head && head->Units_Per_EM ? head->Units_Per_EM : 1000;
    f->size = size > 0 ? size : 12;
    f->matrix = matrix ? *matrix : CGAffineTransformIdentity;
    CFRetain(data);
    hb_blob_t *blob = hb_blob_create((const char *)f->bytes, (unsigned)f->length, HB_MEMORY_MODE_READONLY, (void *)data,
                                     [](void *d) { CFRelease((CFDataRef)d); });
    hb_face_t *hface = hb_face_create(blob, 0);
    hb_font_t *hb = hb_font_create(hface);
    hb_font_set_scale(hb, f->upem, f->upem);
    if (naxes) {
        float design[64];
        for (CFIndex i = 0; i < naxes && i < 64; i++)
            design[i] = (float)coords[i];
        hb_font_set_var_coords_design(hb, design, (unsigned)naxes);
        f->coords = new std::vector<double>(coords, coords + naxes);
    }
    hb_face_destroy(hface);
    hb_blob_destroy(blob);
    f->hb = hb;
    return f;
}

CTFontRef
CTFontCreateWithGraphicsFont(CGFontRef graphicsFont, CGFloat size, const CGAffineTransform *matrix,
                             CTFontDescriptorRef attributes)
{
    if (!graphicsFont)
        return NULL;
    CTFontRegistryAddGraphicsFont(graphicsFont);
    return font_from_graphics(graphicsFont, size, matrix);
}

/* The font used when a name finds nothing: Helvetica, as Apple's (Liberation Sans on Finch). */
static CGFontRef
default_graphics_font(void)
{
    static const char *names[] = {"Helvetica", "LiberationSans", "Inter-Regular", ".AppleSystemUIFont", "Roboto-Regular"};
    for (const char *n : names) {
        CFStringRef s = CFStringCreateWithCString(NULL, n, kCFStringEncodingUTF8);
        CGFontRef f = CTFontRegistryCopyGraphicsFont(s);
        CFRelease(s);
        if (f)
            return f;
    }
    return NULL;
}

CTFontRef
CTFontCreateWithName(CFStringRef name, CGFloat size, const CGAffineTransform *matrix)
{
    CGFontRef cg = name ? CTFontRegistryCopyGraphicsFont(name) : NULL;
    if (!cg)
        cg = default_graphics_font();
    if (!cg)
        return NULL;
    CTFontRef f = font_from_graphics(cg, size, matrix);
    CFRelease(cg);
    return f;
}

CTFontRef
CTFontCreateWithNameAndOptions(CFStringRef name, CGFloat size, const CGAffineTransform *matrix, CTFontOptions options)
{
    return CTFontCreateWithName(name, size, matrix);
}

CTFontRef
CTFontCreateWithFontDescriptor(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix)
{
    if (!descriptor)
        return NULL;
    CFStringRef name = (CFStringRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
    if (!name)
        name = (CFStringRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute);
    if (size == 0) {
        CFNumberRef s = (CFNumberRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontSizeAttribute);
        if (s) {
            CFNumberGetValue(s, kCFNumberCGFloatType, &size);
            CFRelease(s);
        }
    }
    CGAffineTransform m = matrix ? *matrix : CGAffineTransformIdentity;
    if (!matrix) {
        CFDataRef md = (CFDataRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontMatrixAttribute);
        if (md && (size_t)CFDataGetLength(md) == sizeof(CGAffineTransform))
            memcpy(&m, CFDataGetBytePtr(md), sizeof m);
        if (md)
            CFRelease(md);
    }
    CTFontRef f = CTFontCreateWithName(name, size, &m);
    if (name)
        CFRelease(name);
    if (f) {
        ((struct __CTFont *)f)->descriptor = (CTFontDescriptorRef)CFRetain(descriptor);
    }
    return f;
}

CTFontRef
CTFontCreateWithFontDescriptorAndOptions(CTFontDescriptorRef d, CGFloat size, const CGAffineTransform *m, CTFontOptions o)
{
    return CTFontCreateWithFontDescriptor(d, size, m);
}

CTFontRef
CTFontCreateCopyWithAttributes(CTFontRef font, CGFloat size, const CGAffineTransform *matrix, CTFontDescriptorRef attributes)
{
    if (!font)
        return NULL;
    return font_from_graphics(font->cg, size > 0 ? size : font->size, matrix ? matrix : &font->matrix);
}

CTFontRef
CTFontCreateCopyWithFamily(CTFontRef font, CGFloat size, const CGAffineTransform *matrix, CFStringRef family)
{
    CTFontRef f = family ? CTFontCreateWithName(family, size > 0 ? size : font->size, matrix ? matrix : &font->matrix) : NULL;
    return f ? f : NULL;
}

CTFontRef
CTFontCreateWithPlatformFont(ATSFontRef platformFont, CGFloat size, const CGAffineTransform *matrix,
                             CTFontDescriptorRef attributes)
{
    return NULL;
}

CTFontRef
CTFontCreateWithQuickdrawInstance(ConstStr255Param name, int16_t identifier, uint8_t style, CGFloat size)
{
    return NULL;
}

ATSFontRef
CTFontGetPlatformFont(CTFontRef font, CTFontDescriptorRef *attributes)
{
    return 0;
}

CGFontRef
CTFontCopyGraphicsFont(CTFontRef font, CTFontDescriptorRef *attributes)
{
    if (attributes)
        *attributes = NULL;
    return font ? (CGFontRef)CFRetain(font->cg) : NULL;
}

#pragma mark - Metrics

CGFloat CTFontGetSize(CTFontRef f) { return f ? f->size : 0; }
CGAffineTransform CTFontGetMatrix(CTFontRef f) { return f ? f->matrix : CGAffineTransformIdentity; }
unsigned CTFontGetUnitsPerEm(CTFontRef f) { return f ? (unsigned)f->upem : 0; }
CFIndex CTFontGetGlyphCount(CTFontRef f) { return f ? (CFIndex)((FT_Face)f->face)->num_glyphs : 0; }
CFStringEncoding CTFontGetStringEncoding(CTFontRef f) { return kCFStringEncodingUnicode; }

static double
scale(CTFontRef f)
{
    return f->size / f->upem;
}

/* OS/2 fsSelection bit 7: use the typographic metrics. */
static bool
use_typo(CTFontRef f, const uint8_t **os2)
{
    size_t len;
    const uint8_t *t = CTFontTable(f, 'OS/2', &len);
    *os2 = t && len >= 78 ? t : NULL;
    return *os2 && (ct_be16(t + 62) & 0x80);
}

CGFloat
CTFontGetAscent(CTFontRef f)
{
    if (!f)
        return 0;
    const uint8_t *os2;
    if (use_typo(f, &os2))
        return s16(os2 + 68) * scale(f);
    size_t len;
    const uint8_t *h = CTFontTable(f, 'hhea', &len);
    return h && len >= 10 ? s16(h + 4) * scale(f) : 0;
}

CGFloat
CTFontGetDescent(CTFontRef f)
{
    if (!f)
        return 0;
    const uint8_t *os2;
    if (use_typo(f, &os2))
        return -s16(os2 + 70) * scale(f);
    size_t len;
    const uint8_t *h = CTFontTable(f, 'hhea', &len);
    return h && len >= 10 ? -s16(h + 6) * scale(f) : 0;
}

CGFloat
CTFontGetLeading(CTFontRef f)
{
    if (!f)
        return 0;
    const uint8_t *os2;
    if (use_typo(f, &os2))
        return s16(os2 + 72) * scale(f);
    size_t len;
    const uint8_t *h = CTFontTable(f, 'hhea', &len);
    return h && len >= 10 ? s16(h + 8) * scale(f) : 0;
}

CGFloat
CTFontGetCapHeight(CTFontRef f)
{
    return f ? CGFontGetCapHeight(f->cg) * scale(f) : 0;
}

CGFloat
CTFontGetXHeight(CTFontRef f)
{
    return f ? CGFontGetXHeight(f->cg) * scale(f) : 0;
}

CGFloat
CTFontGetUnderlinePosition(CTFontRef f)
{
    size_t len;
    const uint8_t *t = f ? CTFontTable(f, 'post', &len) : NULL;
    return t && len >= 12 ? s16(t + 8) * scale(f) : 0;
}

CGFloat
CTFontGetUnderlineThickness(CTFontRef f)
{
    size_t len;
    const uint8_t *t = f ? CTFontTable(f, 'post', &len) : NULL;
    return t && len >= 12 ? s16(t + 10) * scale(f) : 0;
}

CGFloat
CTFontGetSlantAngle(CTFontRef f)
{
    return f ? CGFontGetItalicAngle(f->cg) : 0;
}

CGRect
CTFontGetBoundingBox(CTFontRef f)
{
    if (!f)
        return CGRectZero;
    CGRect b = CGFontGetFontBBox(f->cg);
    double s = scale(f);
    CGRect r = CGRectMake(b.origin.x * s, b.origin.y * s, b.size.width * s, b.size.height * s);
    return CGAffineTransformIsIdentity(f->matrix) ? r : CGRectApplyAffineTransform(r, f->matrix);
}

#pragma mark - Names

static int
name_id(CFStringRef key)
{
    struct {
        CFStringRef const *key;
        int id;
    } map[] = {
        {&kCTFontCopyrightNameKey, 0}, {&kCTFontFamilyNameKey, 1}, {&kCTFontSubFamilyNameKey, 2},
        {&kCTFontStyleNameKey, 2}, {&kCTFontUniqueNameKey, 3}, {&kCTFontFullNameKey, 4},
        {&kCTFontVersionNameKey, 5}, {&kCTFontPostScriptNameKey, 6}, {&kCTFontTrademarkNameKey, 7},
        {&kCTFontManufacturerNameKey, 8}, {&kCTFontDesignerNameKey, 9}, {&kCTFontDescriptionNameKey, 10},
        {&kCTFontVendorURLNameKey, 11}, {&kCTFontDesignerURLNameKey, 12}, {&kCTFontLicenseNameKey, 13},
        {&kCTFontLicenseURLNameKey, 14}, {&kCTFontSampleTextNameKey, 19}, {&kCTFontPostScriptCIDNameKey, 20},
    };
    for (auto &m : map)
        if (CFEqual(key, *m.key))
            return m.id;
    return -1;
}

CFStringRef
CTFontCopyName(CTFontRef f, CFStringRef key)
{
    if (!f || !key)
        return NULL;
    int id = name_id(key);
    return id < 0 ? NULL : CTFontNameString(f, (uint16_t)id);
}

CFStringRef
CTFontCopyLocalizedName(CTFontRef f, CFStringRef key, CFStringRef *language)
{
    if (language)
        *language = NULL;
    return CTFontCopyName(f, key);
}

CFStringRef CTFontCopyPostScriptName(CTFontRef f) { return f ? CTFontNameString(f, 6) : NULL; }

CFStringRef
CTFontCopyFamilyName(CTFontRef f)
{
    if (!f)
        return NULL;
    CFStringRef typographic = CTFontNameString(f, 16);
    return typographic ? typographic : CTFontNameString(f, 1);
}

CFStringRef CTFontCopyFullName(CTFontRef f) { return f ? CTFontNameString(f, 4) : NULL; }
CFStringRef CTFontCopyDisplayName(CTFontRef f) { return CTFontCopyFullName(f); }

#pragma mark - Traits

CTFontSymbolicTraits
CTFontGetSymbolicTraits(CTFontRef f)
{
    if (!f)
        return 0;
    uint32_t t = 0;
    size_t len;
    const uint8_t *head = CTFontTable(f, 'head', &len);
    uint16_t mac_style = head && len >= 46 ? ct_be16(head + 44) : 0;
    const uint8_t *os2 = CTFontTable(f, 'OS/2', &len);
    uint16_t sel = os2 && len >= 64 ? ct_be16(os2 + 62) : 0;
    if ((mac_style & 2) || (sel & 1))
        t |= kCTFontTraitItalic;
    if ((mac_style & 1) || (sel & 0x20))
        t |= kCTFontTraitBold;
    const uint8_t *post = CTFontTable(f, 'post', &len);
    if (post && len >= 16 && ct_be32(post + 12))
        t |= kCTFontTraitMonoSpace;
    if (os2 && len >= 8) {
        uint16_t width = ct_be16(os2 + 6);
        if (width && width < 5)
            t |= kCTFontTraitCondensed;
        if (width > 5)
            t |= kCTFontTraitExpanded;
    }
    return t;
}

/* Apple's normalised weights for the OS/2 weight classes, interpolated. */
static double
normalised_weight(int w)
{
    static const double classes[] = {100, 200, 300, 400, 500, 600, 700, 800, 900};
    static const double weights[] = {-0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62};
    if (w <= 100)
        return -0.8;
    if (w >= 900)
        return 0.62;
    for (int i = 0; i < 8; i++)
        if (w <= classes[i + 1])
            return weights[i] + (weights[i + 1] - weights[i]) * (w - classes[i]) / 100;
    return 0;
}

CFDictionaryRef
CTFontCopyTraits(CTFontRef f)
{
    if (!f)
        return NULL;
    size_t len;
    const uint8_t *os2 = CTFontTable(f, 'OS/2', &len);
    int weight_class = os2 && len >= 6 ? ct_be16(os2 + 4) : 400;
    int width_class = os2 && len >= 8 ? ct_be16(os2 + 6) : 5;
    uint32_t sym = CTFontGetSymbolicTraits(f);
    double weight = normalised_weight(weight_class);
    double width = (width_class - 5) * 0.1;
    double slant = -CTFontGetSlantAngle(f) / 180.0;
    CFNumberRef vs = CFNumberCreate(NULL, kCFNumberSInt32Type, &sym), vw = CFNumberCreate(NULL, kCFNumberDoubleType, &weight);
    CFNumberRef vd = CFNumberCreate(NULL, kCFNumberDoubleType, &width), vl = CFNumberCreate(NULL, kCFNumberDoubleType, &slant);
    const void *keys[] = {kCTFontSymbolicTrait, kCTFontWeightTrait, kCTFontWidthTrait, kCTFontSlantTrait};
    const void *vals[] = {vs, vw, vd, vl};
    CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, 4, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    CFRelease(vs), CFRelease(vw), CFRelease(vd), CFRelease(vl);
    return d;
}

CTFontRef
CTFontCreateCopyWithSymbolicTraits(CTFontRef font, CGFloat size, const CGAffineTransform *matrix,
                                   CTFontSymbolicTraits value, CTFontSymbolicTraits mask)
{
    if (!font)
        return NULL;
    CTFontSymbolicTraits have = CTFontGetSymbolicTraits(font);
    CTFontSymbolicTraits want = (have & ~mask) | (value & mask);
    if (want == have)
        return CTFontCreateCopyWithAttributes(font, size, matrix, NULL);
    /* the family's other faces: bold and italic among the installed fonts */
    const CTFontSymbolicTraits styles = kCTFontTraitBold | kCTFontTraitItalic;
    if ((want ^ have) & ~styles)
        return NULL;
    CFStringRef family = CTFontCopyFamilyName(font);
    CGFontRef cg = family ? CTFontRegistryCopyFamilyFace(family, want & kCTFontTraitBold, want & kCTFontTraitItalic)
                          : NULL;
    if (family)
        CFRelease(family);
    if (!cg)
        return NULL;
    CTFontRef f = font_from_graphics(cg, size > 0 ? size : font->size, matrix ? matrix : &font->matrix);
    CFRelease(cg);
    return f;
}

#pragma mark - Glyphs

bool
CTFontGetGlyphsForCharacters(CTFontRef f, const UniChar characters[], CGGlyph glyphs[], CFIndex count)
{
    if (!f || !characters || !glyphs)
        return false;
    bool all = true;
    FT_Face face = (FT_Face)f->face;
    pthread_mutex_lock(&ft_lock);
    for (CFIndex i = 0; i < count; i++) {
        UniChar c = characters[i];
        uint32_t cp = c;
        if (CFStringIsSurrogateHighCharacter(c) && i + 1 < count && CFStringIsSurrogateLowCharacter(characters[i + 1])) {
            cp = CFStringGetLongCharacterForSurrogatePair(c, characters[i + 1]);
            glyphs[i] = (CGGlyph)FT_Get_Char_Index(face, cp);
            glyphs[i + 1] = 0;
            all &= glyphs[i] != 0;
            i++;
            continue;
        }
        glyphs[i] = (CGGlyph)FT_Get_Char_Index(face, cp);
        all &= glyphs[i] != 0;
    }
    pthread_mutex_unlock(&ft_lock);
    return all;
}

double
CTFontGetAdvancesForGlyphs(CTFontRef f, CTFontOrientation orientation, const CGGlyph glyphs[], CGSize advances[],
                           CFIndex count)
{
    if (!f || !glyphs)
        return 0;
    std::vector<int> units((size_t)count);
    CGFontGetGlyphAdvances(f->cg, glyphs, (size_t)count, units.data());
    double total = 0, s = scale(f);
    for (CFIndex i = 0; i < count; i++) {
        double a = units[(size_t)i] * s;
        total += a;
        if (advances)
            advances[i] = orientation == kCTFontOrientationVertical ? CGSizeMake(0, f->size) : CGSizeMake(a, 0);
    }
    return orientation == kCTFontOrientationVertical ? count * f->size : total;
}

CGRect
CTFontGetBoundingRectsForGlyphs(CTFontRef f, CTFontOrientation orientation, const CGGlyph glyphs[], CGRect rects[],
                                CFIndex count)
{
    if (!f || !glyphs)
        return CGRectZero;
    std::vector<CGRect> boxes((size_t)count);
    CGFontGetGlyphBBoxes(f->cg, glyphs, (size_t)count, boxes.data());
    double s = scale(f);
    CGRect all = CGRectNull;
    for (CFIndex i = 0; i < count; i++) {
        CGRect b = boxes[(size_t)i];
        CGRect r = CGRectMake(b.origin.x * s, b.origin.y * s, b.size.width * s, b.size.height * s);
        if (!CGAffineTransformIsIdentity(f->matrix) && !CGRectIsEmpty(r))
            r = CGRectApplyAffineTransform(r, f->matrix);
        if (rects)
            rects[i] = r;
        if (!CGRectIsEmpty(r))
            all = CGRectUnion(all, r);
    }
    return CGRectIsNull(all) ? CGRectZero : all;
}

CGRect
CTFontGetOpticalBoundsForGlyphs(CTFontRef f, const CGGlyph glyphs[], CGRect rects[], CFIndex count, CFOptionFlags options)
{
    return CTFontGetBoundingRectsForGlyphs(f, kCTFontOrientationHorizontal, glyphs, rects, count);
}

void
CTFontGetVerticalTranslationsForGlyphs(CTFontRef f, const CGGlyph glyphs[], CGSize translations[], CFIndex count)
{
    std::vector<CGSize> adv((size_t)count);
    CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, glyphs, adv.data(), count);
    for (CFIndex i = 0; i < count; i++)
        translations[i] = CGSizeMake(-adv[(size_t)i].width / 2, -CTFontGetAscent(f));
}

namespace {
/* FreeType ends each contour with a line back to its start; Apple's paths let the close do that. */
struct Decompose {
    CGMutablePathRef path;
    CGAffineTransform t;
    bool open, pending;
    FT_Vector start, line;

    void flush(bool closing)
    {
        if (pending && !(closing && line.x == start.x && line.y == start.y))
            CGPathAddLineToPoint(path, &t, line.x, line.y);
        pending = false;
    }
    void close()
    {
        flush(true);
        if (open)
            CGPathCloseSubpath(path);
        open = false;
    }
};
}  // namespace

CGPathRef
CTFontCreatePathForGlyph(CTFontRef f, CGGlyph glyph, const CGAffineTransform *matrix)
{
    if (!f)
        return NULL;
    FT_Face face = (FT_Face)f->face;
    pthread_mutex_lock(&ft_lock);
    if (FT_Load_Glyph(face, glyph, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING) ||
        face->glyph->format != FT_GLYPH_FORMAT_OUTLINE) {
        pthread_mutex_unlock(&ft_lock);
        return NULL;
    }
    double s = scale(f);
    Decompose d = {};
    d.path = CGPathCreateMutable();
    d.t = CGAffineTransformConcat(CGAffineTransformMakeScale(s, s), f->matrix);
    if (matrix)
        d.t = CGAffineTransformConcat(d.t, *matrix);
    FT_Outline_Funcs funcs = {
        [](const FT_Vector *to, void *u) -> int {
            Decompose *d = (Decompose *)u;
            d->close();
            CGPathMoveToPoint(d->path, &d->t, to->x, to->y);
            d->open = true;
            d->start = *to;
            return 0;
        },
        [](const FT_Vector *to, void *u) -> int {
            Decompose *d = (Decompose *)u;
            d->flush(false);
            d->line = *to;
            d->pending = true;
            return 0;
        },
        [](const FT_Vector *c, const FT_Vector *to, void *u) -> int {
            Decompose *d = (Decompose *)u;
            d->flush(false);
            CGPathAddQuadCurveToPoint(d->path, &d->t, c->x, c->y, to->x, to->y);
            return 0;
        },
        [](const FT_Vector *c1, const FT_Vector *c2, const FT_Vector *to, void *u) -> int {
            Decompose *d = (Decompose *)u;
            d->flush(false);
            CGPathAddCurveToPoint(d->path, &d->t, c1->x, c1->y, c2->x, c2->y, to->x, to->y);
            return 0;
        },
        0, 0,
    };
    FT_Outline_Decompose(&face->glyph->outline, &funcs, &d);
    d.close();
    pthread_mutex_unlock(&ft_lock);
    return d.path;
}

CFStringRef
CTFontCopyNameForGlyph(CTFontRef f, CGGlyph glyph)
{
    return f ? CGFontCopyGlyphNameForGlyph(f->cg, glyph) : NULL;
}

CGGlyph
CTFontGetGlyphWithName(CTFontRef f, CFStringRef name)
{
    return f ? CGFontGetGlyphWithGlyphName(f->cg, name) : 0;
}

CFIndex
CTFontGetLigatureCaretPositions(CTFontRef f, CGGlyph glyph, CGFloat positions[], CFIndex maxPositions)
{
    return 0;
}

void
CTFontDrawGlyphs(CTFontRef f, const CGGlyph glyphs[], const CGPoint positions[], size_t count, CGContextRef context)
{
    if (!f || !context)
        return;
    /*
     * As Apple's: the font is left set in the context (so is a text clip),
     * the glyphs are placed through the context's text matrix, and colour
     * glyphs are drawn in colour.
     */
    CGAffineTransform saved = CGContextGetTextMatrix(context);
    CGContextSetFont(context, f->cg);
    CGContextSetFontSize(context, f->size);
    CGAffineTransform tm = CGAffineTransformConcat(f->matrix, saved);
    tm.tx = saved.tx, tm.ty = saved.ty;
    CGContextSetTextMatrix(context, tm);
    CGContextFinchShowGlyphsWithColor(context, glyphs, positions, count);
    CGContextSetTextMatrix(context, saved);
}

#pragma mark - Tables, characters, variations, features

CFArrayRef
CTFontCopyAvailableTables(CTFontRef f, CTFontTableOptions options)
{
    return f ? CGFontCopyTableTags(f->cg) : NULL;
}

bool
CTFontHasTable(CTFontRef f, CTFontTableTag tag)
{
    return f && CTFontTable(f, tag, NULL) != NULL;
}

CFDataRef
CTFontCopyTable(CTFontRef f, CTFontTableTag tag, CTFontTableOptions options)
{
    return f ? CGFontCopyTableForTag(f->cg, tag) : NULL;
}

CFCharacterSetRef
CTFontCopyCharacterSet(CTFontRef f)
{
    if (!f)
        return NULL;
    CFMutableCharacterSetRef set = CFCharacterSetCreateMutable(NULL);
    FT_Face face = (FT_Face)f->face;
    pthread_mutex_lock(&ft_lock);
    FT_UInt gi;
    FT_ULong c = FT_Get_First_Char(face, &gi);
    while (gi) {
        CFCharacterSetAddCharactersInRange(set, CFRangeMake((CFIndex)c, 1));
        c = FT_Get_Next_Char(face, c, &gi);
    }
    pthread_mutex_unlock(&ft_lock);
    CFCharacterSetRef out = CFCharacterSetCreateCopy(NULL, set);
    CFRelease(set);
    return out;
}

CFArrayRef
CTFontCopySupportedLanguages(CTFontRef f)
{
    return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

CFArrayRef
CTFontCopyVariationAxes(CTFontRef f)
{
    if (!f)
        return NULL;
    CFArrayRef cgaxes = CGFontCopyVariationAxes(f->cg);
    if (!cgaxes)
        return NULL;
    size_t len;
    const uint8_t *fvar = CTFontTable(f, 'fvar', &len);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(cgaxes); i++) {
        CFDictionaryRef a = (CFDictionaryRef)CFArrayGetValueAtIndex(cgaxes, i);
        uint32_t tag = 0;
        uint16_t flags = 0;
        if (fvar && len >= 16) {
            const uint8_t *rec = fvar + ct_be16(fvar + 4) + ct_be16(fvar + 10) * i;
            if (rec + 20 <= fvar + len)
                tag = ct_be32(rec), flags = ct_be16(rec + 16);
        }
        int hidden = flags & 1;
        CFNumberRef id = CFNumberCreate(NULL, kCFNumberSInt32Type, &tag), h = CFNumberCreate(NULL, kCFNumberIntType, &hidden);
        const void *keys[] = {kCTFontVariationAxisIdentifierKey, kCTFontVariationAxisMinimumValueKey,
                              kCTFontVariationAxisMaximumValueKey, kCTFontVariationAxisDefaultValueKey,
                              kCTFontVariationAxisNameKey, kCTFontVariationAxisHiddenKey};
        const void *vals[] = {id, CFDictionaryGetValue(a, kCGFontVariationAxisMinValue),
                              CFDictionaryGetValue(a, kCGFontVariationAxisMaxValue),
                              CFDictionaryGetValue(a, kCGFontVariationAxisDefaultValue),
                              CFDictionaryGetValue(a, kCGFontVariationAxisName), h};
        CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, hidden ? 6 : 5, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(out, d);
        CFRelease(d), CFRelease(id), CFRelease(h);
    }
    CFRelease(cgaxes);
    return out;
}

CFDictionaryRef
CTFontCopyVariation(CTFontRef f)
{
    if (!f || !f->coords)
        return NULL;
    CFArrayRef axes = CTFontCopyVariationAxes(f);
    if (!axes)
        return NULL;
    CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                           &kCFTypeDictionaryValueCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(axes) && (size_t)i < f->coords->size(); i++) {
        CFDictionaryRef a = (CFDictionaryRef)CFArrayGetValueAtIndex(axes, i);
        CFNumberRef v = CFNumberCreate(NULL, kCFNumberDoubleType, &(*f->coords)[(size_t)i]);
        CFDictionarySetValue(out, CFDictionaryGetValue(a, kCTFontVariationAxisIdentifierKey), v);
        CFRelease(v);
    }
    CFRelease(axes);
    return out;
}

CFArrayRef
CTFontCopyFeatures(CTFontRef f)
{
    return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

CFArrayRef
CTFontCopyFeatureSettings(CTFontRef f)
{
    return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

#pragma mark - Descriptors, fallback, UI fonts

CTFontDescriptorRef
CTFontCopyFontDescriptor(CTFontRef f)
{
    if (!f)
        return NULL;
    if (f->descriptor)
        return (CTFontDescriptorRef)CFRetain(f->descriptor);
    CFStringRef ps = CTFontCopyPostScriptName(f);
    CTFontDescriptorRef d = CTFontDescriptorCreateWithNameAndSize(ps ? ps : CFSTR(""), f->size);
    if (ps)
        CFRelease(ps);
    if (!CGAffineTransformIsIdentity(f->matrix)) {
        CFDataRef m = CFDataCreate(NULL, (const UInt8 *)&f->matrix, sizeof f->matrix);
        CTFontDescriptorRef with = CTFontDescriptorCreateCopyWithAttributes(
            d, (CFDictionaryRef)CFAutorelease(CFDictionaryCreate(NULL, (const void **)&kCTFontMatrixAttribute,
                                                                 (const void **)&m, 1, &kCFTypeDictionaryKeyCallBacks,
                                                                 &kCFTypeDictionaryValueCallBacks)));
        CFRelease(m);
        CFRelease(d);
        d = with;
    }
    return d;
}

CFTypeRef
CTFontCopyAttribute(CTFontRef f, CFStringRef attribute)
{
    if (!f || !attribute)
        return NULL;
    if (CFEqual(attribute, kCTFontNameAttribute))
        return CTFontCopyPostScriptName(f);
    if (CFEqual(attribute, kCTFontFamilyNameAttribute))
        return CTFontCopyFamilyName(f);
    if (CFEqual(attribute, kCTFontDisplayNameAttribute))
        return CTFontCopyDisplayName(f);
    if (CFEqual(attribute, kCTFontStyleNameAttribute))
        return CTFontNameString(f, 2);
    if (CFEqual(attribute, kCTFontTraitsAttribute))
        return CTFontCopyTraits(f);
    if (CFEqual(attribute, kCTFontSizeAttribute))
        return CFNumberCreate(NULL, kCFNumberCGFloatType, &f->size);
    if (CFEqual(attribute, kCTFontCharacterSetAttribute))
        return CTFontCopyCharacterSet(f);
    if (CFEqual(attribute, kCTFontVariationAttribute))
        return CTFontCopyVariation(f);
    return NULL;
}

/* Does the font have glyphs for every character in the range? */
static bool
covers(CTFontRef f, CFStringRef s, CFRange r)
{
    std::vector<UniChar> chars((size_t)r.length);
    std::vector<CGGlyph> glyphs((size_t)r.length);
    CFStringGetCharacters(s, r, chars.data());
    return CTFontGetGlyphsForCharacters(f, chars.data(), glyphs.data(), r.length);
}

/*
 * Finch's fallback cascade, in order, as regular and bold faces: the system
 * font, then Noto for wider Latin, Greek and Cyrillic and for other scripts,
 * symbols and emoji. Each font is loaded once, at 12 points, to test
 * coverage; the font returned is made at the asked size.
 */
static const char *const cascade_names[][2] = {
    {"Inter-Regular", "Inter-Bold"},
    {"NotoSans-Regular", "NotoSans-Bold"},
    {"NotoSansArabic-Regular", "NotoSansArabic-Bold"},
    {"NotoSansHebrew-Regular", "NotoSansHebrew-Bold"},
    {"NotoSansCJKsc-Regular", "NotoSansCJKsc-Bold"},
    {"NotoSansSymbols-Regular", NULL},
    {"NotoSansSymbols2-Regular", NULL},
    {"DejaVuSansMono", "DejaVuSansMono-Bold"},
    {"NotoColorEmoji", NULL},
    {"LiberationSans", "LiberationSans-Bold"},
};
enum { cascade_count = sizeof cascade_names / sizeof cascade_names[0], cascade_emoji = 8 };

static CTFontRef
cascade_font(size_t i, bool bold)
{
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static CTFontRef fonts[cascade_count][2];
    static bool tried[cascade_count][2];
    if (bold && !cascade_names[i][1])
        bold = false;
    pthread_mutex_lock(&lock);
    if (!tried[i][bold]) {
        tried[i][bold] = true;
        CFStringRef name = CFStringCreateWithCString(NULL, cascade_names[i][bold], kCFStringEncodingUTF8);
        CGFontRef cg = CTFontRegistryCopyGraphicsFont(name);
        CFRelease(name);
        if (cg) {
            fonts[i][bold] = font_from_graphics(cg, 12, NULL);
            CFRelease(cg);
        }
    }
    CTFontRef f = fonts[i][bold];
    pthread_mutex_unlock(&lock);
    return f;
}

/* Text emoji-like enough to look for in the emoji font first: the emoji planes, or a variation selector 16. */
static bool
wants_emoji(CFStringRef s, CFRange r)
{
    UniChar c[3] = {0, 0, 0};
    CFIndex n = std::min<CFIndex>(3, CFStringGetLength(s) - r.location);
    CFStringGetCharacters(s, CFRangeMake(r.location, n), c);
    uint32_t cp = c[0];
    CFIndex next = 1;
    if (n > 1 && CFStringIsSurrogateHighCharacter(c[0]) && CFStringIsSurrogateLowCharacter(c[1])) {
        cp = CFStringGetLongCharacterForSurrogatePair(c[0], c[1]);
        next = 2;
    }
    return (cp >= 0x1F000 && cp <= 0x1FAFF) || (next < n && c[next] == 0xFE0F);
}

CTFontRef
CTFontCreateForString(CTFontRef current, CFStringRef string, CFRange range)
{
    if (!current)
        return NULL;
    if (!string || !range.length)
        return (CTFontRef)CFRetain(current);
    /* the first character (a surrogate pair is one) */
    UniChar first[2];
    CFIndex len = range.length > 1 ? 2 : 1;
    CFStringGetCharacters(string, CFRangeMake(range.location, len), first);
    if (len == 2 && !(CFStringIsSurrogateHighCharacter(first[0]) && CFStringIsSurrogateLowCharacter(first[1])))
        len = 1;
    CFRange one = CFRangeMake(range.location, len);
    bool emoji = wants_emoji(string, one);
    /* the font covers how the string starts: it is the font for that much */
    if (!emoji && covers(current, string, one))
        return (CTFontRef)CFRetain(current);
    bool bold = CTFontGetSymbolicTraits(current) & kCTFontTraitBold;
    /* the emoji font first when the text asks for it */
    size_t order[cascade_count], n = 0;
    if (emoji)
        order[n++] = cascade_emoji;
    for (size_t i = 0; i < cascade_count; i++)
        if (!emoji || i != cascade_emoji)
            order[n++] = i;
    for (size_t i : order) {
        CTFontRef probe = cascade_font(i, bold);
        if (probe && covers(probe, string, one))
            return font_from_graphics(probe->cg, current->size, &current->matrix);
    }
    return (CTFontRef)CFRetain(current);
}

CTFontRef
CTFontCreateForStringWithLanguage(CTFontRef current, CFStringRef string, CFRange range, CFStringRef language)
{
    return CTFontCreateForString(current, string, range);
}

CFArrayRef
CTFontCopyDefaultCascadeListForLanguages(CTFontRef font, CFArrayRef languagePrefList)
{
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    bool bold = font && (CTFontGetSymbolicTraits(font) & kCTFontTraitBold);
    for (size_t i = 0; i < cascade_count; i++) {
        CTFontRef f = cascade_font(i, bold);
        if (!f)
            continue;
        CFStringRef ps = CTFontCopyPostScriptName(f);
        if (font) {
            CFStringRef mine = CTFontCopyPostScriptName(font);
            bool same = mine && CFEqual(mine, ps);
            if (mine)
                CFRelease(mine);
            if (same) {
                CFRelease(ps);
                continue;
            }
        }
        CTFontDescriptorRef d = CTFontDescriptorCreateWithNameAndSize(ps, 0);
        CFArrayAppendValue(out, d);
        CFRelease(d);
        CFRelease(ps);
    }
    return out;
}

/* Apple's UI fonts: the system font (Inter on Finch) at each use's size, emphasized ones bold. */
CTFontRef
CTFontCreateUIFontForLanguage(CTFontUIFontType uiType, CGFloat size, CFStringRef language)
{
    static const struct {
        CTFontUIFontType type;
        CGFloat size;
        const char *name;
    } fonts[] = {
        {kCTFontUIFontUser, 12, "Helvetica"},
        {kCTFontUIFontUserFixedPitch, 10, "Menlo-Regular"},
        {kCTFontUIFontSystem, 13, ".AppleSystemUIFont"},
        {kCTFontUIFontEmphasizedSystem, 13, ".AppleSystemUIFontBold"},
        {kCTFontUIFontSmallSystem, 11, ".AppleSystemUIFont"},
        {kCTFontUIFontSmallEmphasizedSystem, 11, ".AppleSystemUIFontBold"},
        {kCTFontUIFontMiniSystem, 9, ".AppleSystemUIFont"},
        {kCTFontUIFontMiniEmphasizedSystem, 9, ".AppleSystemUIFontBold"},
        {kCTFontUIFontViews, 12, ".AppleSystemUIFont"},
        {kCTFontUIFontApplication, 13, ".AppleSystemUIFont"},
        {kCTFontUIFontLabel, 10, ".AppleSystemUIFont"},
        {kCTFontUIFontMenuTitle, 13, ".AppleSystemUIFont"},
        {kCTFontUIFontMenuItem, 13, ".AppleSystemUIFont"},
        {kCTFontUIFontMenuItemMark, 13, ".AppleSystemUIFont"},
        {kCTFontUIFontMenuItemCmdKey, 13, ".Keyboard"},
        {kCTFontUIFontWindowTitle, 13, ".AppleSystemUIFontBold"},
        {kCTFontUIFontPushButton, 13, ".AppleSystemUIFont"},
        {kCTFontUIFontUtilityWindowTitle, 11, ".AppleSystemUIFont"},
        {kCTFontUIFontAlertHeader, 13, ".AppleSystemUIFontBold"},
        {kCTFontUIFontSystemDetail, 9, ".AppleSystemUIFont"},
        {kCTFontUIFontEmphasizedSystemDetail, 9, ".AppleSystemUIFontBold"},
        {kCTFontUIFontToolbar, 11, ".AppleSystemUIFont"},
        {kCTFontUIFontSmallToolbar, 10, ".AppleSystemUIFont"},
        {kCTFontUIFontMessage, 13, ".AppleSystemUIFont"},
        {kCTFontUIFontPalette, 11, ".AppleSystemUIFont"},
        {kCTFontUIFontToolTip, 11, ".AppleSystemUIFont"},
        {kCTFontUIFontControlContent, 12, ".AppleSystemUIFont"},
    };
    for (auto &u : fonts) {
        if (u.type != uiType)
            continue;
        CFStringRef name = CFStringCreateWithCString(NULL, u.name, kCFStringEncodingUTF8);
        CTFontRef f = CTFontCreateWithName(name, size > 0 ? size : u.size, NULL);
        CFRelease(name);
        return f;
    }
    return NULL;
}

CTFontUIFontType
CTFontGetUIFontType(CTFontRef font)
{
    return kCTFontUIFontNone;
}
