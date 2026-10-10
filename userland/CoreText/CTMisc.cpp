/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CTGlyphInfo, CTRunDelegate, CTRubyAnnotation, and the version. */
#include "CTInternal.h"
#include <string.h>

uint32_t
CTGetCoreTextVersion(void)
{
    return 0x000D0000;  /* as macOS 26.4's */
}

#pragma mark - CTGlyphInfo

struct __CTGlyphInfo {
    CTRuntimeBase base;
    CGGlyph glyph;
    CGFontIndex cid;
    CTCharacterCollection collection;
    CFStringRef name, base_string;
};

static void
glyphinfo_finalize(CFTypeRef cf)
{
    struct __CTGlyphInfo *g = (struct __CTGlyphInfo *)cf;
    if (g->name)
        CFRelease(g->name);
    if (g->base_string)
        CFRelease(g->base_string);
}

static const CTRuntimeClass glyphinfo_class = {
    0, "CTGlyphInfo", NULL, NULL, glyphinfo_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID glyphinfo_type;

CFTypeID
CTGlyphInfoGetTypeID(void)
{
    return CTTypeRegister(&glyphinfo_class, &glyphinfo_type);
}

static struct __CTGlyphInfo *
glyphinfo_new(CFStringRef base)
{
    struct __CTGlyphInfo *g = (struct __CTGlyphInfo *)CTTypeCreateInstance(CTGlyphInfoGetTypeID(), sizeof(struct __CTGlyphInfo));
    g->base_string = base ? CFStringCreateCopy(NULL, base) : NULL;
    return g;
}

CTGlyphInfoRef
CTGlyphInfoCreateWithGlyphName(CFStringRef glyphName, CTFontRef font, CFStringRef baseString)
{
    if (!glyphName || !font || !baseString)
        return NULL;
    struct __CTGlyphInfo *g = glyphinfo_new(baseString);
    g->name = CFStringCreateCopy(NULL, glyphName);
    g->glyph = CTFontGetGlyphWithName(font, glyphName);
    return g;
}

CTGlyphInfoRef
CTGlyphInfoCreateWithGlyph(CGGlyph glyph, CTFontRef font, CFStringRef baseString)
{
    if (!font || !baseString)
        return NULL;
    struct __CTGlyphInfo *g = glyphinfo_new(baseString);
    g->glyph = glyph;
    return g;
}

CTGlyphInfoRef
CTGlyphInfoCreateWithCharacterIdentifier(CGFontIndex cid, CTCharacterCollection collection, CFStringRef baseString)
{
    if (!baseString)
        return NULL;
    struct __CTGlyphInfo *g = glyphinfo_new(baseString);
    g->cid = cid;
    g->collection = collection;
    return g;
}

CFStringRef CTGlyphInfoGetGlyphName(CTGlyphInfoRef g) { return g ? g->name : NULL; }
CGGlyph CTGlyphInfoGetGlyph(CTGlyphInfoRef g) { return g ? g->glyph : 0; }
CGFontIndex CTGlyphInfoGetCharacterIdentifier(CTGlyphInfoRef g) { return g ? g->cid : 0; }
CTCharacterCollection CTGlyphInfoGetCharacterCollection(CTGlyphInfoRef g) { return g ? g->collection : kCTCharacterCollectionIdentityMapping; }

#pragma mark - CTRunDelegate

struct __CTRunDelegate {
    CTRuntimeBase base;
    CTRunDelegateCallbacks callbacks;
    void *refcon;
};

static void
delegate_finalize(CFTypeRef cf)
{
    struct __CTRunDelegate *d = (struct __CTRunDelegate *)cf;
    if (d->callbacks.dealloc)
        d->callbacks.dealloc(d->refcon);
}

static const CTRuntimeClass delegate_class = {
    0, "CTRunDelegate", NULL, NULL, delegate_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID delegate_type;

CFTypeID
CTRunDelegateGetTypeID(void)
{
    return CTTypeRegister(&delegate_class, &delegate_type);
}

CTRunDelegateRef
CTRunDelegateCreate(const CTRunDelegateCallbacks *callbacks, void *refCon)
{
    if (!callbacks)
        return NULL;
    struct __CTRunDelegate *d = (struct __CTRunDelegate *)CTTypeCreateInstance(CTRunDelegateGetTypeID(), sizeof(struct __CTRunDelegate));
    d->callbacks = *callbacks;
    d->refcon = refCon;
    return d;
}

void *
CTRunDelegateGetRefCon(CTRunDelegateRef d)
{
    return d ? d->refcon : NULL;
}

bool
CTRunDelegateGetMetrics(CFTypeRef cf, CGFloat *ascent, CGFloat *descent, CGFloat *width)
{
    if (!cf || CFGetTypeID(cf) != CTRunDelegateGetTypeID())
        return false;
    struct __CTRunDelegate *d = (struct __CTRunDelegate *)cf;
    *ascent = d->callbacks.getAscent ? d->callbacks.getAscent(d->refcon) : 0;
    *descent = d->callbacks.getDescent ? d->callbacks.getDescent(d->refcon) : 0;
    *width = d->callbacks.getWidth ? d->callbacks.getWidth(d->refcon) : 0;
    return true;
}

#pragma mark - CTRubyAnnotation

struct __CTRubyAnnotation {
    CTRuntimeBase base;
    CTRubyAlignment alignment;
    CTRubyOverhang overhang;
    CGFloat size_factor;
    CFStringRef text[kCTRubyPositionCount];
    CFDictionaryRef attributes;
};

static void
ruby_finalize(CFTypeRef cf)
{
    struct __CTRubyAnnotation *r = (struct __CTRubyAnnotation *)cf;
    for (int i = 0; i < kCTRubyPositionCount; i++)
        if (r->text[i])
            CFRelease(r->text[i]);
    if (r->attributes)
        CFRelease(r->attributes);
}

static const CTRuntimeClass ruby_class = {
    0, "CTRubyAnnotation", NULL, NULL, ruby_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID ruby_type;

CFTypeID
CTRubyAnnotationGetTypeID(void)
{
    return CTTypeRegister(&ruby_class, &ruby_type);
}

CTRubyAnnotationRef
CTRubyAnnotationCreate(CTRubyAlignment alignment, CTRubyOverhang overhang, CGFloat sizeFactor,
                       CFStringRef text[kCTRubyPositionCount])
{
    struct __CTRubyAnnotation *r = (struct __CTRubyAnnotation *)CTTypeCreateInstance(CTRubyAnnotationGetTypeID(), sizeof(struct __CTRubyAnnotation));
    r->alignment = alignment;
    r->overhang = overhang;
    r->size_factor = sizeFactor;
    for (int i = 0; text && i < kCTRubyPositionCount; i++)
        r->text[i] = text[i] ? CFStringCreateCopy(NULL, text[i]) : NULL;
    return r;
}

CTRubyAnnotationRef
CTRubyAnnotationCreateWithAttributes(CTRubyAlignment alignment, CTRubyOverhang overhang, CTRubyPosition position,
                                     CFStringRef string, CFDictionaryRef attributes)
{
    CFStringRef text[kCTRubyPositionCount] = {NULL};
    if (position >= 0 && position < kCTRubyPositionCount)
        text[position] = string;
    struct __CTRubyAnnotation *r = (struct __CTRubyAnnotation *)CTRubyAnnotationCreate(alignment, overhang, 0.5, text);
    r->attributes = attributes ? CFDictionaryCreateCopy(NULL, attributes) : NULL;
    return r;
}

CTRubyAnnotationRef
CTRubyAnnotationCreateCopy(CTRubyAnnotationRef r)
{
    if (!r)
        return NULL;
    struct __CTRubyAnnotation *c = (struct __CTRubyAnnotation *)CTRubyAnnotationCreate(
        r->alignment, r->overhang, r->size_factor, (CFStringRef *)r->text);
    c->attributes = r->attributes ? (CFDictionaryRef)CFRetain(r->attributes) : NULL;
    return c;
}

CTRubyAlignment CTRubyAnnotationGetAlignment(CTRubyAnnotationRef r) { return r ? r->alignment : kCTRubyAlignmentInvalid; }
CTRubyOverhang CTRubyAnnotationGetOverhang(CTRubyAnnotationRef r) { return r ? r->overhang : kCTRubyOverhangInvalid; }
CGFloat CTRubyAnnotationGetSizeFactor(CTRubyAnnotationRef r) { return r ? r->size_factor : 0; }

CFStringRef
CTRubyAnnotationGetTextForPosition(CTRubyAnnotationRef r, CTRubyPosition position)
{
    return r && position >= 0 && position < kCTRubyPositionCount ? r->text[position] : NULL;
}

#pragma mark - Adaptive image glyphs (no image providers on Finch yet)

CGRect
CTFontGetTypographicBoundsForAdaptiveImageProvider(CTFontRef font, CFTypeRef provider)
{
    return CGRectZero;
}

void
CTFontDrawImageFromAdaptiveImageProviderAtPoint(CTFontRef font, CFTypeRef provider, CGPoint point, CGContextRef context)
{
}
