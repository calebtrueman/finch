/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGPDFContext: a CGContext whose pages are canvases from Skia's PDF backend
 * (SkPDF), so every drawing call works on it as on a bitmap context. User
 * space is the page's default user space (y up); the base transform flips
 * it onto Skia's page canvas (y down), which SkPDF flips back when it
 * writes the content stream.
 *
 * Skia writes the drawing; a final pass reads its file back with Finch's
 * PDF parser and writes the document out again with what Quartz's API adds
 * on top: page boxes (Skia only writes a media box at the origin), links
 * and destinations, the information dictionary, outlines, metadata, output
 * intents, and encryption (the standard security handler, revision 4,
 * AES-128, as Apple's writes it).
 */
#include "CGContextInternal.h"
#include "CGFontInternal.h"
#include "CGPDFInternal.h"
#include "include/core/SkData.h"
#include "include/core/SkDocument.h"
#include "include/core/SkFont.h"
#include "include/core/SkStream.h"
#include "include/docs/SkPDFDocument.h"
#include "include/docs/SkPDFJpegHelpers.h"
#include <CommonCrypto/CommonRandom.h>
#include <math.h>
#include <string.h>
#include <time.h>
#include <map>

CG_PRIVATE struct CGContext *CGContextCreateBase(int type, size_t width, size_t height);
CG_PRIVATE SkColor4f CGContextColor(CGContextRef c, CGColorRef color);

extern "C" {
const CFStringRef kCGPDFContextMediaBox = CFSTR("MediaBox");
const CFStringRef kCGPDFContextCropBox = CFSTR("CropBox");
const CFStringRef kCGPDFContextBleedBox = CFSTR("BleedBox");
const CFStringRef kCGPDFContextTrimBox = CFSTR("TrimBox");
const CFStringRef kCGPDFContextArtBox = CFSTR("ArtBox");
const CFStringRef kCGPDFContextTitle = CFSTR("kCGPDFContextTitle");
const CFStringRef kCGPDFContextAuthor = CFSTR("kCGPDFContextAuthor");
const CFStringRef kCGPDFContextSubject = CFSTR("kCGPDFContextSubject");
const CFStringRef kCGPDFContextKeywords = CFSTR("kCGPDFContextKeywords");
const CFStringRef kCGPDFContextCreator = CFSTR("kCGPDFContextCreator");
const CFStringRef kCGPDFContextOwnerPassword = CFSTR("kCGPDFContextOwnerPassword");
const CFStringRef kCGPDFContextUserPassword = CFSTR("kCGPDFContextUserPassword");
const CFStringRef kCGPDFContextEncryptionKeyLength = CFSTR("kCGPDFContextEncryptionKeyLength");
const CFStringRef kCGPDFContextAllowsPrinting = CFSTR("kCGPDFContextAllowsPrinting");
const CFStringRef kCGPDFContextAllowsCopying = CFSTR("kCGPDFContextAllowsCopying");
const CFStringRef kCGPDFContextOutputIntent = CFSTR("kCGPDFContextOutputIntent");
const CFStringRef kCGPDFXOutputIntentSubtype = CFSTR("S");
const CFStringRef kCGPDFXOutputConditionIdentifier = CFSTR("OutputConditionIdentifier");
const CFStringRef kCGPDFXOutputCondition = CFSTR("OutputCondition");
const CFStringRef kCGPDFXRegistryName = CFSTR("RegistryName");
const CFStringRef kCGPDFXInfo = CFSTR("Info");
const CFStringRef kCGPDFXDestinationOutputProfile = CFSTR("DestOutputProfile");
const CFStringRef kCGPDFContextOutputIntents = CFSTR("kCGPDFContextOutputIntents");
const CFStringRef kCGPDFContextAccessPermissions = CFSTR("kCGPDFContextAccessPermissions");
const CFStringRef kCGPDFContextCreateLinearizedPDF = CFSTR("CGPDFContextCreateLinearizedPDF");
const CFStringRef kCGPDFContextCreatePDFA = CFSTR("CGPDFContextCreatePDFA");
const CFStringRef kCGPDFTagPropertyActualText = CFSTR("CGPDFTagPropertyActualText");
const CFStringRef kCGPDFTagPropertyAlternativeText = CFSTR("CGPDFTagPropertyAlternativeText");
const CFStringRef kCGPDFTagPropertyTitleText = CFSTR("CGPDFTagPropertyTitleText");
const CFStringRef kCGPDFTagPropertyLanguageText = CFSTR("CGPDFTagPropertyLanguageText");
}

namespace {
struct Annot {
    CGRect rect;          /* default user space */
    CFURLRef url;         /* or */
    CFStringRef dest;
};

struct Page {
    CGRect boxes[5];      /* media, crop, bleed, trim, art; CGRectNull where not given */
    std::vector<Annot> annots;
};

struct Writer {
    CGDataConsumerRef consumer;
    SkDynamicMemoryWStream *stream;
    sk_sp<SkDocument> doc;
    CFDictionaryRef aux;
    CGRect media;
    CGRect boxes[5];      /* the document's defaults */
    std::vector<Page> pages;
    std::map<std::string, std::pair<size_t, CGPoint>> dests;  /* name -> page index, point */
    bool in_page, closed;
    CFDataRef metadata;
    CFDictionaryRef outline;
    int tag_depth;
};
}  // namespace

static Writer *
writer(CGContextRef c)
{
    return c && c->type == CG_CONTEXT_PDF ? (Writer *)c->pdf : NULL;
}

static bool
rect_value(CFTypeRef v, CGRect &r)
{
    if (!v || CFGetTypeID(v) != CFDataGetTypeID() || CFDataGetLength((CFDataRef)v) != sizeof(CGRect))
        return false;
    memcpy(&r, CFDataGetBytePtr((CFDataRef)v), sizeof r);
    r = CGRectStandardize(r);
    return true;
}

static const CFStringRef *
box_keys(void)
{
    static const CFStringRef keys[5] = {kCGPDFContextMediaBox, kCGPDFContextCropBox, kCGPDFContextBleedBox,
                                        kCGPDFContextTrimBox, kCGPDFContextArtBox};
    return keys;
}

CGContextRef
CGPDFContextCreate(CGDataConsumerRef consumer, const CGRect *mediaBox, CFDictionaryRef aux)
{
    if (!consumer)
        return NULL;
    CGRect media = CGRectMake(0, 0, 612, 792), r;
    if (mediaBox && !CGRectIsEmpty(*mediaBox) && !CGRectIsInfinite(*mediaBox))
        media = CGRectStandardize(*mediaBox);
    else if (aux && rect_value(CFDictionaryGetValue(aux, kCGPDFContextMediaBox), r) && !CGRectIsEmpty(r))
        media = r;
    Writer *w = new Writer();
    w->consumer = CGDataConsumerRetain(consumer);
    w->aux = aux ? CFDictionaryCreateCopy(NULL, aux) : NULL;
    w->media = media;
    /* boxes other than the media box are per page (Apple's ignores them in the auxiliary info) */
    for (int i = 0; i < 5; i++)
        w->boxes[i] = CGRectNull;
    w->stream = new SkDynamicMemoryWStream();
    SkPDF::Metadata meta = SkPDF::JPEG::MetadataWithCallbacks();
    CFBooleanRef pdfa = aux ? (CFBooleanRef)CFDictionaryGetValue(aux, kCGPDFContextCreatePDFA) : NULL;
    meta.fPDFA = pdfa && CFGetTypeID(pdfa) == CFBooleanGetTypeID() && CFBooleanGetValue(pdfa);
    w->doc = SkPDF::MakeDocument(w->stream, meta);
    if (!w->doc) {
        delete w->stream;
        CGDataConsumerRelease(w->consumer);
        if (w->aux)
            CFRelease(w->aux);
        delete w;
        return NULL;
    }
    struct CGContext *c = CGContextCreateBase(CG_CONTEXT_PDF, (size_t)ceil(media.size.width),
                                              (size_t)ceil(media.size.height));
    c->pdf = w;
    c->draw_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    c->skspace = new sk_sp<SkColorSpace>(SkColorSpace::MakeSRGB());
    c->base_ctm = CGAffineTransformMake(1, 0, 0, -1, -media.origin.x, media.size.height + media.origin.y);
    CGContextState(c).clip = media;
    return c;
}

CGContextRef
CGPDFContextCreateWithURL(CFURLRef url, const CGRect *mediaBox, CFDictionaryRef aux)
{
    CGDataConsumerRef consumer = url ? CGDataConsumerCreateWithURL(url) : NULL;
    if (!consumer)
        return NULL;
    CGContextRef c = CGPDFContextCreate(consumer, mediaBox, aux);
    CGDataConsumerRelease(consumer);
    return c;
}

/* Each page starts with the default graphics state. */
static void
reset_state(CGContextRef c)
{
    struct CGContext *fresh = CGContextCreateBase(CG_CONTEXT_LAYER, c->width, c->height);
    std::swap(c->stack, fresh->stack);
    std::swap(c->path, fresh->path);
    c->text_matrix = CGAffineTransformIdentity;
    CFRelease(fresh);
}

void
CGPDFContextBeginPage(CGContextRef c, CFDictionaryRef info)
{
    Writer *w = writer(c);
    if (!w || w->closed)
        return;
    if (w->in_page)
        return;  /* a page is open: Apple's ignores this */
    Page page;
    for (int i = 0; i < 5; i++)
        page.boxes[i] = i ? w->boxes[i] : w->media;
    CGRect r;
    for (int i = 0; info && i < 5; i++)
        if (rect_value(CFDictionaryGetValue(info, box_keys()[i]), r) && (i || !CGRectIsEmpty(r)))
            page.boxes[i] = r;
    CGRect media = page.boxes[0];
    w->pages.push_back(page);
    c->canvas = w->doc->beginPage((float)media.size.width, (float)media.size.height);
    w->in_page = true;
    c->width = (size_t)ceil(media.size.width);
    c->height = (size_t)ceil(media.size.height);
    reset_state(c);
    c->base_ctm = CGAffineTransformMake(1, 0, 0, -1, -media.origin.x, media.size.height + media.origin.y);
    CGContextState(c).clip = media;
}

void
CGPDFContextEndPage(CGContextRef c)
{
    Writer *w = writer(c);
    if (!w || !w->in_page)
        return;
    w->doc->endPage();
    c->canvas = NULL;
    w->in_page = false;
}

void
CGContextBeginPage(CGContextRef c, const CGRect *mediaBox)
{
    if (!writer(c))
        return;
    CFDictionaryRef info = NULL;
    if (mediaBox) {
        CFDataRef r = CFDataCreate(NULL, (const UInt8 *)mediaBox, sizeof *mediaBox);
        const void *k = kCGPDFContextMediaBox, *v = r;
        info = CFDictionaryCreate(NULL, &k, &v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(r);
    }
    CGPDFContextBeginPage(c, info);
    if (info)
        CFRelease(info);
}

void
CGContextEndPage(CGContextRef c)
{
    CGPDFContextEndPage(c);
}

/* Link rectangles and destination points are in the page's default space: the CTM doesn't apply, as with Apple's. */
static CGRect
default_space_rect(CGContextRef c, CGRect r)
{
    return CGRectStandardize(r);
}

void
CGPDFContextSetURLForRect(CGContextRef c, CFURLRef url, CGRect rect)
{
    Writer *w = writer(c);
    if (!w || !w->in_page || !url)
        return;
    w->pages.back().annots.push_back(Annot{default_space_rect(c, rect), (CFURLRef)CFRetain(url), NULL});
}

void
CGPDFContextSetDestinationForRect(CGContextRef c, CFStringRef name, CGRect rect)
{
    Writer *w = writer(c);
    if (!w || !w->in_page || !name)
        return;
    w->pages.back().annots.push_back(Annot{default_space_rect(c, rect), NULL, (CFStringRef)CFRetain(name)});
}

static std::string
utf8(CFStringRef s)
{
    if (!s)
        return "";
    CFIndex n = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    std::string out((size_t)n, '\0');
    if (!CFStringGetCString(s, out.data(), n, kCFStringEncodingUTF8))
        return "";
    out.resize(strlen(out.c_str()));
    return out;
}

void
CGPDFContextAddDestinationAtPoint(CGContextRef c, CFStringRef name, CGPoint point)
{
    Writer *w = writer(c);
    if (!w || !w->in_page || !name)
        return;
    w->dests[utf8(name)] = {w->pages.size() - 1, point};
}

void
CGPDFContextAddDocumentMetadata(CGContextRef c, CFDataRef metadata)
{
    Writer *w = writer(c);
    if (!w)
        return;
    if (w->metadata)
        CFRelease(w->metadata);
    w->metadata = metadata ? (CFDataRef)CFRetain(metadata) : NULL;
}

void
CGPDFContextSetOutline(CGContextRef c, CFDictionaryRef outline)
{
    Writer *w = writer(c);
    if (!w)
        return;
    if (w->outline)
        CFRelease(w->outline);
    w->outline = outline ? (CFDictionaryRef)CFRetain(outline) : NULL;
}

/* Tagged PDF and structure trees aren't written yet: Skia takes its structure tree before drawing starts. */
void CGPDFContextBeginTag(CGContextRef c, CGPDFTagType type, CFDictionaryRef properties) { if (writer(c)) writer(c)->tag_depth++; }
void CGPDFContextEndTag(CGContextRef c) { if (writer(c) && writer(c)->tag_depth) writer(c)->tag_depth--; }
void CGPDFContextSetParentTree(CGContextRef c, CGPDFDictionaryRef tree) {}
void CGPDFContextSetIDTree(CGContextRef c, CGPDFDictionaryRef tree) {}
void CGPDFContextSetPageTagStructureTree(CGContextRef c, CFDictionaryRef tree) {}

const char *
CGPDFTagTypeGetName(CGPDFTagType type)
{
    static const struct {
        int type;
        const char *name;
    } names[] = {
        {100, "/Document"}, {101, "/Part"}, {102, "/Art"}, {103, "/Sect"}, {104, "/Div"}, {105, "/BlockQuote"},
        {106, "/Caption"}, {107, "/TOC"}, {108, "/TOCI"}, {109, "/Index"}, {110, "/NonStruct"}, {111, "/Private"},
        {200, "/P"}, {201, "/H"}, {202, "/H1"}, {203, "/H2"}, {204, "/H3"}, {205, "/H4"}, {206, "/H5"},
        {207, "/H6"}, {300, "/L"}, {301, "/LI"}, {302, "/Lbl"}, {303, "/LBody"}, {400, "/Table"}, {401, "/TR"},
        {402, "/TH"}, {403, "/TD"}, {404, "/THead"}, {405, "/TBody"}, {406, "/TFoot"}, {500, "/Span"},
        {501, "/Quote"}, {502, "/Note"}, {503, "/Reference"}, {504, "/BibEntry"}, {505, "/Code"}, {506, "/Link"},
        {507, "/Annot"}, {600, "/Ruby"}, {601, "/RB"}, {602, "/RT"}, {603, "/RP"}, {604, "/Warichu"},
        {605, "/WT"}, {606, "/WP"}, {700, "/Figure"}, {701, "/Formula"}, {702, "/Form"}, {800, "/OBJR"},
    };
    for (auto &n : names)
        if (n.type == (int)type)
            return n.name;
    return NULL;
}

#pragma mark - Text

/*
 * Glyphs filled in a plain colour become PDF text in an embedded subset of
 * the font (SkPDF subsets it with HarfBuzz), so the text can be selected
 * and searched. Other cases (strokes, clips, patterns, shadows, blend
 * modes) are drawn as outlines by CGText.cpp.
 */
bool
CGPDFContextShowGlyphs(CGContextRef c, const CGGlyph *glyphs, const CGPoint *positions, size_t count)
{
    if (!writer(c) || !c->canvas)
        return false;
    CGGState &g = CGContextState(c);
    if (g.text_mode != kCGTextFill || !g.font || g.font_size == 0 || CGColorGetPattern(g.fill) ||
        g.blend != kCGBlendModeNormal || (g.shadow_color && CGColorGetAlpha(g.shadow_color) > 0))
        return false;
    sk_sp<SkTypeface> tf = CGFontGetTypeface(g.font);
    if (!tf)
        return false;
    SkFont font(tf, (float)g.font_size);
    font.setHinting(SkFontHinting::kNone);
    font.setLinearMetrics(true);
    font.setSubpixel(true);
    SkPaint paint;
    SkColor4f col = CGContextColor(c, g.fill);
    col.fA *= (float)g.alpha;
    paint.setColor(col, c->skspace ? c->skspace->get() : nullptr);
    paint.setAntiAlias(true);
    /* Skia's glyph space is y down: flip it into text space, then text space to the device */
    CGAffineTransform flip = CGAffineTransformMake(1, 0, 0, -1, 0, 0);
    CGAffineTransform m = CGAffineTransformConcat(CGAffineTransformConcat(flip, c->text_matrix), CGContextUserToDevice(c));
    if (m.a * m.d - m.b * m.c == 0)
        return true;
    std::vector<SkGlyphID> ids(glyphs, glyphs + count);
    std::vector<SkPoint> pts(count);
    for (size_t i = 0; i < count; i++)
        pts[i] = SkPoint::Make((float)positions[i].x, (float)-positions[i].y);
    c->canvas->save();
    c->canvas->setMatrix(CGSkMatrix(m));
    c->canvas->drawGlyphs(SkSpan(ids), SkSpan(pts), SkPoint::Make(0, 0), font, paint);
    c->canvas->restore();
    return true;
}

#pragma mark - The final pass

namespace {
/* Writes objects as PDF syntax, encrypting strings and streams when asked. */
struct Out {
    std::string s;
    bool encrypt = false;
    std::vector<uint8_t> key;   /* the file key */
    uint32_t num = 0;           /* the object being written */

    void raw(const char *t) { s += t; }
    void raw(const std::string &t) { s += t; }

    void number(double v)
    {
        if (v == floor(v) && fabs(v) < 1e15) {
            char b[32];
            snprintf(b, sizeof b, "%lld", (long long)v);
            s += b;
            return;
        }
        char b[64];
        snprintf(b, sizeof b, "%.6f", v);
        char *e = b + strlen(b) - 1;
        while (*e == '0')
            *e-- = 0;
        if (*e == '.')
            *e = 0;
        s += strcmp(b, "-0") ? b : "0";
    }

    void name(const char *n)
    {
        s += '/';
        for (const unsigned char *p = (const unsigned char *)n; *p; p++) {
            if (*p < '!' || *p > '~' || *p == '#' || CGPDFIsDelimiter(*p)) {
                char b[4];
                snprintf(b, sizeof b, "#%02X", *p);
                s += b;
            } else {
                s += (char)*p;
            }
        }
    }

    std::vector<uint8_t> crypt(const uint8_t *b, size_t n)
    {
        std::vector<uint8_t> k, out;
        CGPDFCryptObjectKey(key, num, 0, true, k);
        uint8_t iv[16];
        CCRandomGenerateBytes(iv, sizeof iv);
        CGPDFAES(true, k.data(), k.size(), iv, b, n, out, true);
        out.insert(out.begin(), iv, iv + 16);
        return out;
    }

    void string(const uint8_t *b, size_t n)
    {
        std::vector<uint8_t> enc;
        if (encrypt && num) {
            enc = crypt(b, n);
            b = enc.data(), n = enc.size();
        }
        bool printable = true;
        for (size_t i = 0; i < n && printable; i++)
            printable = b[i] >= 32 && b[i] < 127;
        if (!printable) {
            s += '<';
            static const char hex[] = "0123456789abcdef";
            for (size_t i = 0; i < n; i++)
                s += hex[b[i] >> 4], s += hex[b[i] & 15];
            s += '>';
            return;
        }
        s += '(';
        for (size_t i = 0; i < n; i++) {
            if (b[i] == '(' || b[i] == ')' || b[i] == '\\')
                s += '\\';
            s += (char)b[i];
        }
        s += ')';
    }

    void object(const CGPDFObject &o)
    {
        switch (o.type) {
        case kCGPDFObjectTypeNull: s += "null"; break;
        case kCGPDFObjectTypeBoolean: s += o.b ? "true" : "false"; break;
        case kCGPDFObjectTypeInteger: number((double)o.i); break;
        case kCGPDFObjectTypeReal: number(o.r); break;
        case kCGPDFObjectTypeName: name(o.name); break;
        case kCGPDFObjectTypeString: string(o.string->bytes, o.string->length); break;
        case kCGPDFObjectTypeRef: {
            char b[48];
            snprintf(b, sizeof b, "%u %u R", o.ref.num, o.ref.gen);
            s += b;
            break;
        }
        case kCGPDFObjectTypeArray:
            s += '[';
            for (size_t i = 0; i < o.array->items.size(); i++) {
                if (i)
                    s += ' ';
                object(o.array->items[i]);
            }
            s += ']';
            break;
        case kCGPDFObjectTypeDictionary: dict(o.dict, -1); break;
        case kCGPDFObjectTypeStream: {
            std::vector<uint8_t> enc;
            const uint8_t *b = o.stream->raw;
            size_t n = o.stream->length;
            if (encrypt && num) {
                enc = crypt(b, n);
                b = enc.data(), n = enc.size();
            }
            dict(o.stream->dict, (long)n);
            s += "\nstream\n";
            s.append((const char *)b, n);
            s += "\nendstream";
            break;
        }
        }
    }

    /* `length` >= 0 replaces the Length entry (a stream's). */
    void dict(CGPDFDictionaryRef d, long length)
    {
        s += "<<";
        for (auto &e : d->entries) {
            if (length >= 0 && !strcmp(e.first, "Length"))
                continue;
            s += ' ';
            name(e.first);
            s += ' ';
            object(e.second);
        }
        if (length >= 0) {
            s += " /Length ";
            number((double)length);
        }
        s += " >>";
    }
};

/* Building objects in the parsed document's arena. */
struct Build {
    CGPDFDocData *d;
    uint32_t next;
    std::vector<std::pair<uint32_t, CGPDFObject>> added;

    CGPDFObject integer(long v) { CGPDFObject o; o.type = kCGPDFObjectTypeInteger; o.i = v; return o; }
    CGPDFObject real(double v) { CGPDFObject o; o.type = kCGPDFObjectTypeReal; o.r = v; return o; }
    CGPDFObject null() { return CGPDFNullObject; }
    CGPDFObject boolean(bool v) { CGPDFObject o; o.type = kCGPDFObjectTypeBoolean; o.b = v; return o; }

    CGPDFObject name(const char *n)
    {
        CGPDFObject o;
        o.type = kCGPDFObjectTypeName;
        o.name = d->arena.name(n, strlen(n));
        return o;
    }

    CGPDFObject string(const void *b, size_t n)
    {
        CGPDFObject o;
        o.type = kCGPDFObjectTypeString;
        o.string = d->arena.string(b, n);
        return o;
    }

    /* A text string: ASCII as is, anything else as UTF-16BE with a byte order mark. */
    CGPDFObject text(CFStringRef s)
    {
        CFIndex n = CFStringGetLength(s);
        std::vector<UniChar> u((size_t)n);
        CFStringGetCharacters(s, CFRangeMake(0, n), u.data());
        bool ascii = true;
        for (UniChar ch : u)
            ascii &= ch < 128;
        std::string b;
        if (ascii) {
            for (UniChar ch : u)
                b += (char)ch;
        } else {
            b = "\xfe\xff";
            for (UniChar ch : u)
                b += (char)(ch >> 8), b += (char)ch;
        }
        return string(b.data(), b.size());
    }

    CGPDFObject array()
    {
        CGPDFObject o;
        o.type = kCGPDFObjectTypeArray;
        o.array = d->arena.array(d);
        return o;
    }

    CGPDFObject dict()
    {
        CGPDFObject o;
        o.type = kCGPDFObjectTypeDictionary;
        o.dict = d->arena.dict(d);
        return o;
    }

    CGPDFObject rect(CGRect r)
    {
        CGPDFObject a = array();
        a.array->items = {real(CGRectGetMinX(r)), real(CGRectGetMinY(r)), real(CGRectGetMaxX(r)), real(CGRectGetMaxY(r))};
        return a;
    }

    CGPDFObject ref(uint32_t num)
    {
        CGPDFObject o;
        o.type = kCGPDFObjectTypeRef;
        o.ref.num = num, o.ref.gen = 0;
        return o;
    }

    /* A new indirect object; returns a reference to it. */
    CGPDFObject add(const CGPDFObject &o)
    {
        uint32_t n = next++;
        added.emplace_back(n, o);
        return ref(n);
    }

    CGPDFObject stream(CGPDFObject dict, const void *bytes, size_t n)
    {
        CGPDFStream *s = d->arena.stream(d);
        s->dict = dict.dict;
        uint8_t *copy = (uint8_t *)d->arena.alloc(n);
        memcpy(copy, bytes, n);
        s->raw = copy;
        s->length = n;
        CGPDFObject o;
        o.type = kCGPDFObjectTypeStream;
        o.stream = s;
        return o;
    }
};
}  // namespace

static std::string
date_string(void)
{
    time_t now = time(NULL);
    struct tm t;
    gmtime_r(&now, &t);
    char b[40];
    snprintf(b, sizeof b, "D:%04d%02d%02d%02d%02d%02dZ00'00'", t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour,
             t.tm_min, t.tm_sec);
    return b;
}

static CFStringRef
aux_string(Writer *w, CFStringRef key)
{
    CFTypeRef v = w->aux ? CFDictionaryGetValue(w->aux, key) : NULL;
    return v && CFGetTypeID(v) == CFStringGetTypeID() ? (CFStringRef)v : NULL;
}

static bool
aux_bool(Writer *w, CFStringRef key, bool fallback)
{
    CFTypeRef v = w->aux ? CFDictionaryGetValue(w->aux, key) : NULL;
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID())
        return CFBooleanGetValue((CFBooleanRef)v);
    return fallback;
}

/* Password bytes: PDFDocEncoding for revision 4, which is Latin-1 for the characters it can hold. */
static std::string
password_bytes(CFStringRef s)
{
    std::string out;
    if (!s)
        return out;
    for (CFIndex i = 0; i < CFStringGetLength(s) && out.size() < 32; i++) {
        UniChar ch = CFStringGetCharacterAtIndex(s, i);
        out += (char)(ch < 256 ? ch : '?');
    }
    return out;
}

static CGPDFObject
outline_level(Build &b, CFArrayRef items, CGPDFObject parent, const std::vector<CGPDFObject> &page_refs, long &count)
{
    CFIndex n = items ? CFArrayGetCount(items) : 0;
    std::vector<CGPDFObject> refs, dicts;
    for (CFIndex i = 0; i < n; i++) {
        dicts.push_back(b.dict());
        refs.push_back(b.add(dicts.back()));
    }
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(items, i);
        CGPDFDictionary *d = dicts[(size_t)i].dict;
        if (CFGetTypeID(item) != CFDictionaryGetTypeID())
            continue;
        CFStringRef title = (CFStringRef)CFDictionaryGetValue(item, kCGPDFOutlineTitle);
        d->set("Title", title && CFGetTypeID(title) == CFStringGetTypeID() ? b.text(title) : b.string("", 0));
        d->set("Parent", parent);
        if (i > 0)
            d->set("Prev", refs[(size_t)i - 1]);
        if (i + 1 < n)
            d->set("Next", refs[(size_t)i + 1]);
        CFTypeRef dest = CFDictionaryGetValue(item, kCGPDFOutlineDestination);
        if (dest && CFGetTypeID(dest) == CFNumberGetTypeID()) {
            long page = 0;
            CFNumberGetValue((CFNumberRef)dest, kCFNumberLongType, &page);
            if (page >= 1 && (size_t)page <= page_refs.size()) {
                CGPDFObject a = b.array();
                CGRect r;
                CFTypeRef rv = CFDictionaryGetValue(item, kCGPDFOutlineDestinationRect);
                if (rv && CFGetTypeID(rv) == CFDictionaryGetTypeID() &&
                    CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)rv, &r)) {
                    r = CGRectStandardize(r);
                    a.array->items = {page_refs[(size_t)page - 1], b.name("FitR"), b.real(CGRectGetMinX(r)),
                                      b.real(CGRectGetMinY(r)), b.real(CGRectGetMaxX(r)), b.real(CGRectGetMaxY(r))};
                } else {
                    a.array->items = {page_refs[(size_t)page - 1], b.name("XYZ"), b.null(), b.null(), b.null()};
                }
                d->set("Dest", a);
            }
        } else if (dest && CFGetTypeID(dest) == CFURLGetTypeID()) {
            CGPDFObject action = b.dict();
            action.dict->set("S", b.name("URI"));
            std::string u = utf8(CFURLGetString((CFURLRef)dest));
            action.dict->set("URI", b.string(u.data(), u.size()));
            d->set("A", action);
        }
        CFArrayRef kids = (CFArrayRef)CFDictionaryGetValue(item, kCGPDFOutlineChildren);
        if (kids && CFGetTypeID(kids) == CFArrayGetTypeID() && CFArrayGetCount(kids)) {
            long sub = 0;
            CGPDFObject first = outline_level(b, kids, refs[(size_t)i], page_refs, sub);
            d->set("First", first);
            d->set("Last", b.ref(first.ref.num + (uint32_t)CFArrayGetCount(kids) - 1));
            d->set("Count", b.integer(sub));
            count += sub;
        }
        count++;
    }
    return n ? refs[0] : b.null();
}

/* Read Skia's file back and write the document as Quartz's API describes it. */
static CFDataRef
finish(Writer *w, CFDataRef skia)
{
    CGPDFDocData *d = CGPDFDocDataCreate(skia);
    if (!d)
        return (CFDataRef)CFRetain(skia);
    CGPDFDictionaryRef root = NULL;
    CGPDFDictionaryGetDictionary(d->trailer, "Root", &root);
    const CGPDFObject *root_ref = d->trailer->find("Root"), *info_ref = d->trailer->find("Info");
    std::vector<CGPDFDictionary *> pages;
    {
        CGPDFDocumentRef doc = CGPDFDocumentCreateWithDocData(d);
        d->retain();
        size_t n = CGPDFDocumentGetNumberOfPages(doc);
        pages = d->pages;
        (void)n;
        CFRelease(doc);
    }
    /* every object Skia wrote, parsed */
    uint32_t max = (uint32_t)d->xref.size();
    std::vector<CGPDFObject *> objects(max, NULL);
    std::map<CGPDFDictionary *, uint32_t> numbers;
    for (uint32_t n = 1; n < max; n++) {
        if (d->xref[n].kind != 1)
            continue;
        if (info_ref && info_ref->type == kCGPDFObjectTypeRef && info_ref->ref.num == n)
            continue;  /* replaced below */
        objects[n] = d->resolve_ref(n, 0);
        if (objects[n] && objects[n]->type == kCGPDFObjectTypeDictionary)
            numbers[objects[n]->dict] = n;
    }
    Build b{d, max, {}};
    std::vector<CGPDFObject> page_refs;
    for (auto *p : pages)
        page_refs.push_back(b.ref(numbers[p]));

    /* pages: boxes, a translation when the media box isn't at the origin, links */
    static const char *box_names[5] = {"MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox"};
    for (size_t i = 0; i < pages.size() && i < w->pages.size(); i++) {
        CGPDFDictionary *p = pages[i];
        const Page &pg = w->pages[i];
        for (int k = 0; k < 5; k++)
            if (!CGRectIsNull(pg.boxes[k]))
                p->set(box_names[k], b.rect(pg.boxes[k]));
        CGRect media = pg.boxes[0];
        if (media.origin.x != 0 || media.origin.y != 0) {
            Out o;
            o.raw("1 0 0 1 ");
            o.number(media.origin.x);
            o.raw(" ");
            o.number(media.origin.y);
            o.raw(" cm\n");
            CGPDFObject prefix = b.add(b.stream(b.dict(), o.s.data(), o.s.size()));
            CGPDFObject contents = b.array();
            contents.array->items.push_back(prefix);
            if (const CGPDFObject *old = p->find("Contents")) {
                if (old->type == kCGPDFObjectTypeArray)
                    for (auto &item : old->array->items)
                        contents.array->items.push_back(item);
                else
                    contents.array->items.push_back(*old);
            }
            p->set("Contents", contents);
        }
        CGPDFObject annots = b.array();
        for (const Annot &a : pg.annots) {
            CGPDFObject link = b.dict();
            link.dict->set("Type", b.name("Annot"));
            link.dict->set("Subtype", b.name("Link"));
            link.dict->set("Rect", b.rect(a.rect));
            CGPDFObject border = b.array();
            border.array->items = {b.integer(0), b.integer(0), b.integer(0)};
            link.dict->set("Border", border);
            if (a.url) {
                CGPDFObject action = b.dict();
                action.dict->set("Type", b.name("Action"));
                action.dict->set("S", b.name("URI"));
                std::string u = utf8(CFURLGetString(a.url));
                action.dict->set("URI", b.string(u.data(), u.size()));
                link.dict->set("A", action);
            } else {
                /* a name never given a destination still makes a link, going nowhere */
                auto it = w->dests.find(utf8(a.dest));
                if (it != w->dests.end() && it->second.first < page_refs.size()) {
                    CGPDFObject dest = b.array();
                    dest.array->items = {page_refs[it->second.first], b.name("XYZ"), b.real(it->second.second.x),
                                         b.real(it->second.second.y), b.integer(0)};
                    link.dict->set("Dest", dest);
                }
            }
            annots.array->items.push_back(b.add(link));
        }
        if (!annots.array->items.empty())
            p->set("Annots", annots);
    }

    /* the catalog */
    if (root) {
        CGPDFDictionary *cat = (CGPDFDictionary *)root;
        if (w->metadata) {
            CGPDFObject md = b.dict();
            md.dict->set("Type", b.name("Metadata"));
            md.dict->set("Subtype", b.name("XML"));
            cat->set("Metadata", b.add(b.stream(md, CFDataGetBytePtr(w->metadata), (size_t)CFDataGetLength(w->metadata))));
        }
        CFArrayRef kids = w->outline ? (CFArrayRef)CFDictionaryGetValue(w->outline, kCGPDFOutlineChildren) : NULL;
        if (kids && CFGetTypeID(kids) == CFArrayGetTypeID() && CFArrayGetCount(kids)) {
            CGPDFObject outlines = b.dict();
            CGPDFObject oref = b.add(outlines);
            long count = 0;
            CGPDFObject first = outline_level(b, kids, oref, page_refs, count);
            outlines.dict->set("Type", b.name("Outlines"));
            outlines.dict->set("First", first);
            outlines.dict->set("Last", b.ref(first.ref.num + (uint32_t)CFArrayGetCount(kids) - 1));
            outlines.dict->set("Count", b.integer(count));
            cat->set("Outlines", oref);
        }
        /* output intents */
        std::vector<CFDictionaryRef> intents;
        CFTypeRef one = w->aux ? CFDictionaryGetValue(w->aux, kCGPDFContextOutputIntent) : NULL;
        CFTypeRef many = w->aux ? CFDictionaryGetValue(w->aux, kCGPDFContextOutputIntents) : NULL;
        if (many && CFGetTypeID(many) == CFArrayGetTypeID()) {
            for (CFIndex i = 0; i < CFArrayGetCount((CFArrayRef)many); i++) {
                CFTypeRef v = CFArrayGetValueAtIndex((CFArrayRef)many, i);
                if (CFGetTypeID(v) == CFDictionaryGetTypeID())
                    intents.push_back((CFDictionaryRef)v);
            }
        } else if (one && CFGetTypeID(one) == CFDictionaryGetTypeID()) {
            intents.push_back((CFDictionaryRef)one);
        }
        if (!intents.empty()) {
            CGPDFObject arr = b.array();
            for (CFDictionaryRef src : intents) {
                CGPDFObject oi = b.dict();
                oi.dict->set("Type", b.name("OutputIntent"));
                const CFStringRef keys[] = {kCGPDFXOutputIntentSubtype, kCGPDFXOutputConditionIdentifier,
                                            kCGPDFXOutputCondition, kCGPDFXRegistryName, kCGPDFXInfo};
                for (CFStringRef k : keys) {
                    CFTypeRef v = CFDictionaryGetValue(src, k);
                    if (!v || CFGetTypeID(v) != CFStringGetTypeID())
                        continue;
                    std::string key = utf8(k);
                    if (k == kCGPDFXOutputIntentSubtype)
                        oi.dict->set("S", b.name(utf8((CFStringRef)v).c_str()));
                    else
                        oi.dict->set(d->arena.name(key.data(), key.size()), b.text((CFStringRef)v));
                }
                CFTypeRef prof = CFDictionaryGetValue(src, kCGPDFXDestinationOutputProfile);
                if (prof && CFGetTypeID(prof) == CGColorSpaceGetTypeID()) {
                    CFDataRef icc = CGColorSpaceCopyICCData((CGColorSpaceRef)prof);
                    if (icc) {
                        CGPDFObject sd = b.dict();
                        sd.dict->set("N", b.integer((long)CGColorSpaceGetNumberOfComponents((CGColorSpaceRef)prof)));
                        oi.dict->set("DestOutputProfile",
                                     b.add(b.stream(sd, CFDataGetBytePtr(icc), (size_t)CFDataGetLength(icc))));
                        CFRelease(icc);
                    }
                }
                arr.array->items.push_back(oi);
            }
            cat->set("OutputIntents", arr);
        }
    }

    /* the information dictionary */
    CGPDFObject info = b.dict();
    static const struct {
        const CFStringRef *key;
        const char *name;
    } strings[] = {{&kCGPDFContextTitle, "Title"}, {&kCGPDFContextAuthor, "Author"},
                   {&kCGPDFContextSubject, "Subject"}, {&kCGPDFContextCreator, "Creator"}};
    for (auto &e : strings)
        if (CFStringRef s = aux_string(w, *e.key))
            info.dict->set(e.name, b.text(s));
    CFTypeRef kw = w->aux ? CFDictionaryGetValue(w->aux, kCGPDFContextKeywords) : NULL;
    if (kw && CFGetTypeID(kw) == CFStringGetTypeID()) {
        info.dict->set("Keywords", b.text((CFStringRef)kw));
    } else if (kw && CFGetTypeID(kw) == CFArrayGetTypeID()) {
        /* an array: joined with commas, and kept as an array too, as Apple's writes it */
        CFStringRef joined = CFStringCreateByCombiningStrings(NULL, (CFArrayRef)kw, CFSTR(", "));
        info.dict->set("Keywords", b.text(joined));
        CFRelease(joined);
        CGPDFObject arr = b.array();
        for (CFIndex i = 0; i < CFArrayGetCount((CFArrayRef)kw); i++) {
            CFTypeRef v = CFArrayGetValueAtIndex((CFArrayRef)kw, i);
            if (CFGetTypeID(v) == CFStringGetTypeID())
                arr.array->items.push_back(b.text((CFStringRef)v));
        }
        info.dict->set("AAPL:Keywords", arr);
    }
    std::string date = date_string();
    info.dict->set("Producer", b.string("Finch Quartz PDFContext", 23));
    info.dict->set("CreationDate", b.string(date.data(), date.size()));
    info.dict->set("ModDate", b.string(date.data(), date.size()));
    CGPDFObject info_obj = b.add(info);

    /* the file identifier */
    uint8_t id[16];
    {
        std::string seed((const char *)CFDataGetBytePtr(skia), (size_t)CFDataGetLength(skia));
        seed += date;
        uint8_t r[16];
        CCRandomGenerateBytes(r, sizeof r);
        seed.append((const char *)r, sizeof r);
        CGPDFMD5(seed.data(), seed.size(), id);
    }

    /* encryption */
    Out out;
    CGPDFObject encrypt_ref = b.null();
    CFStringRef owner = aux_string(w, kCGPDFContextOwnerPassword), user = aux_string(w, kCGPDFContextUserPassword);
    if (owner) {
        uint32_t P = 0xFFFFFFFC;
        CFTypeRef perms = w->aux ? CFDictionaryGetValue(w->aux, kCGPDFContextAccessPermissions) : NULL;
        if (perms && CFGetTypeID(perms) == CFNumberGetTypeID()) {
            uint32_t a = 0;
            CFNumberGetValue((CFNumberRef)perms, kCFNumberSInt32Type, &a);
            /* the superset model: high-quality printing implies low, and so on */
            if (a & kCGPDFAllowsHighQualityPrinting)
                a |= kCGPDFAllowsLowQualityPrinting;
            if (a & kCGPDFAllowsDocumentChanges)
                a |= kCGPDFAllowsCommenting | kCGPDFAllowsFormFieldEntry;
            if (a & kCGPDFAllowsContentCopying)
                a |= kCGPDFAllowsContentAccessibility;
            if (a & kCGPDFAllowsCommenting)
                a |= kCGPDFAllowsFormFieldEntry;
            P = 0xFFFFF0C0;
            if (a & kCGPDFAllowsLowQualityPrinting)
                P |= 4;
            if (a & kCGPDFAllowsHighQualityPrinting)
                P |= 2048;
            if (a & kCGPDFAllowsDocumentChanges)
                P |= 8;
            if (a & kCGPDFAllowsDocumentAssembly)
                P |= 1024;
            if (a & kCGPDFAllowsContentCopying)
                P |= 16;
            if (a & kCGPDFAllowsContentAccessibility)
                P |= 512;
            if (a & kCGPDFAllowsCommenting)
                P |= 32;
            if (a & kCGPDFAllowsFormFieldEntry)
                P |= 256;
        }
        if (!aux_bool(w, kCGPDFContextAllowsPrinting, true))
            P &= ~(uint32_t)(4 | 2048);
        if (!aux_bool(w, kCGPDFContextAllowsCopying, true))
            P &= ~(uint32_t)(16 | 512);
        std::string O, U;
        std::vector<uint8_t> key;
        CGPDFCryptMakeR4(password_bytes(owner), password_bytes(user), P, std::string((const char *)id, 16), O, U, key);
        CGPDFObject enc = b.dict();
        enc.dict->set("Filter", b.name("Standard"));
        enc.dict->set("V", b.integer(4));
        enc.dict->set("R", b.integer(4));
        enc.dict->set("Length", b.integer(128));
        CGPDFObject std_cf = b.dict(), cf = b.dict();
        std_cf.dict->set("AuthEvent", b.name("DocOpen"));
        std_cf.dict->set("CFM", b.name("AESV2"));
        std_cf.dict->set("Length", b.integer(16));
        cf.dict->set("StdCF", std_cf);
        enc.dict->set("CF", cf);
        enc.dict->set("StmF", b.name("StdCF"));
        enc.dict->set("StrF", b.name("StdCF"));
        enc.dict->set("EncryptMetadata", b.boolean(true));
        enc.dict->set("O", b.string(O.data(), O.size()));
        enc.dict->set("U", b.string(U.data(), U.size()));
        enc.dict->set("P", b.integer((long)(int32_t)P));
        encrypt_ref = b.add(enc);
        out.encrypt = true;
        out.key = key;
    }

    /* write it out */
    out.raw(owner ? "%PDF-1.6\n%\xe2\xe3\xcf\xd3\n" : "%PDF-1.3\n%\xe2\xe3\xcf\xd3\n");
    std::vector<size_t> offsets(b.next, 0);
    auto emit = [&](uint32_t n, const CGPDFObject &o) {
        offsets[n] = out.s.size();
        char head[32];
        snprintf(head, sizeof head, "%u 0 obj\n", n);
        out.raw(head);
        out.num = encrypt_ref.type == kCGPDFObjectTypeRef && n == encrypt_ref.ref.num ? 0 : n;
        out.object(o);
        out.raw("\nendobj\n");
    };
    for (uint32_t n = 1; n < max; n++)
        if (objects[n])
            emit(n, *objects[n]);
    for (auto &a : b.added)
        emit(a.first, a.second);
    size_t xref = out.s.size();
    char line[64];
    snprintf(line, sizeof line, "xref\n0 %u\n0000000000 65535 f \n", b.next);
    out.raw(line);
    for (uint32_t n = 1; n < b.next; n++) {
        if (offsets[n])
            snprintf(line, sizeof line, "%010zu 00000 n \n", offsets[n]);
        else
            snprintf(line, sizeof line, "0000000000 65535 f \n");
        out.raw(line);
    }
    out.num = 0;
    out.raw("trailer\n<< /Size ");
    out.number(b.next);
    out.raw(" /Root ");
    out.object(*root_ref);
    out.raw(" /Info ");
    out.object(info_obj);
    if (encrypt_ref.type == kCGPDFObjectTypeRef) {
        out.raw(" /Encrypt ");
        out.object(encrypt_ref);
    }
    out.raw(" /ID [ ");
    bool enc = out.encrypt;
    out.encrypt = false;
    out.string(id, 16);
    out.raw(" ");
    out.string(id, 16);
    out.encrypt = enc;
    snprintf(line, sizeof line, " ] >>\nstartxref\n%zu\n%%%%EOF\n", xref);
    out.raw(line);
    d->release();
    return CFDataCreate(NULL, (const UInt8 *)out.s.data(), (CFIndex)out.s.size());
}

void
CGPDFContextClose(CGContextRef c)
{
    Writer *w = writer(c);
    if (!w || w->closed)
        return;
    if (w->in_page)
        CGPDFContextEndPage(c);
    if (w->pages.empty()) {
        /* a document always has a page: drawing outside pages is dropped, as Apple's does */
        CGPDFContextBeginPage(c, NULL);
        CGPDFContextEndPage(c);
    }
    w->closed = true;
    w->doc->close();
    sk_sp<SkData> data = w->stream->detachAsData();
    CFDataRef skia = CFDataCreate(NULL, (const UInt8 *)data->data(), (CFIndex)data->size());
    CFDataRef final = finish(w, skia);
    CFRelease(skia);
    CGDataConsumerPutBytesInternal(w->consumer, CFDataGetBytePtr(final), (size_t)CFDataGetLength(final));
    CFRelease(final);
}

void
CGPDFContextFinalize(CGContextRef c)
{
    Writer *w = writer(c);
    if (!w)
        return;
    CGPDFContextClose(c);
    c->canvas = NULL;
    w->doc.reset();
    delete w->stream;
    CGDataConsumerRelease(w->consumer);
    if (w->aux)
        CFRelease(w->aux);
    if (w->metadata)
        CFRelease(w->metadata);
    if (w->outline)
        CFRelease(w->outline);
    for (auto &p : w->pages)
        for (auto &a : p.annots) {
            if (a.url)
                CFRelease(a.url);
            if (a.dest)
                CFRelease(a.dest);
        }
    delete w;
    ((struct CGContext *)c)->pdf = NULL;
}
