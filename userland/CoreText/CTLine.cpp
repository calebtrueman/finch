/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CTLine and CTRun: an attributed string shaped into runs of positioned
 * glyphs. The string is split by attributes and by bidi level (ICU), runs
 * whose font lacks glyphs fall back to other fonts, and each run is shaped
 * by HarfBuzz with the features its attributes ask for (ligatures, kerning;
 * kCTKernAttributeName adds tracking after every glyph). Runs are laid out
 * in visual order. Caret offsets put a boundary halfway into the adjustment
 * (kerning and tracking) after the previous glyph, and split a ligature's
 * advance evenly among its characters, as Apple's do.
 */
#include "CTLineInternal.h"
#include "CTParagraphInternal.h"
#include <hb.h>
#include <unicode/ubidi.h>
#include <math.h>
#include <algorithm>

#pragma mark - CTRun

static void
run_finalize(CFTypeRef cf)
{
    struct __CTRun *r = (struct __CTRun *)cf;
    if (r->attributes)
        CFRelease(r->attributes);
    if (r->font)
        CFRelease(r->font);
    delete r->glyphs;
    delete r->positions;
    delete r->advances;
    delete r->indices;
}

static CFStringRef
run_desc(CFTypeRef cf)
{
    CTRunRef r = (CTRunRef)cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CTRun: %p>{string range = (%ld, %ld), glyph count = %ld}"), r,
                                    (long)r->range.location, (long)r->range.length, (long)r->glyphs->size());
}

static const CTRuntimeClass run_class = {
    0, "CTRun", NULL, NULL, run_finalize, NULL, NULL, NULL, run_desc, NULL, NULL, 0,
};
static CFTypeID run_type;

CFTypeID
CTRunGetTypeID(void)
{
    return CTTypeRegister(&run_class, &run_type);
}

static struct __CTRun *
run_new(void)
{
    struct __CTRun *r = (struct __CTRun *)CTTypeCreateInstance(CTRunGetTypeID(), sizeof(struct __CTRun));
    r->glyphs = new std::vector<CGGlyph>();
    r->positions = new std::vector<CGPoint>();
    r->advances = new std::vector<CGSize>();
    r->indices = new std::vector<CFIndex>();
    r->text_matrix = CGAffineTransformIdentity;
    return r;
}

CFIndex CTRunGetGlyphCount(CTRunRef r) { return r ? (CFIndex)r->glyphs->size() : 0; }
CFDictionaryRef CTRunGetAttributes(CTRunRef r) { return r ? r->attributes : NULL; }
CTRunStatus CTRunGetStatus(CTRunRef r) { return r ? r->status : 0; }
CFRange CTRunGetStringRange(CTRunRef r) { return r ? r->range : CFRangeMake(0, 0); }
CGAffineTransform CTRunGetTextMatrix(CTRunRef r) { return r ? r->text_matrix : CGAffineTransformIdentity; }
const CGGlyph *CTRunGetGlyphsPtr(CTRunRef r) { return r && !r->glyphs->empty() ? r->glyphs->data() : NULL; }
const CGPoint *CTRunGetPositionsPtr(CTRunRef r) { return r && !r->positions->empty() ? r->positions->data() : NULL; }
const CGSize *CTRunGetAdvancesPtr(CTRunRef r) { return r && !r->advances->empty() ? r->advances->data() : NULL; }
const CFIndex *CTRunGetStringIndicesPtr(CTRunRef r) { return r && !r->indices->empty() ? r->indices->data() : NULL; }

/* A range of a run's glyphs: length 0 means to the end. */
static CFRange
glyph_range(CTRunRef r, CFRange range)
{
    CFIndex n = (CFIndex)r->glyphs->size();
    if (range.length == 0)
        range.length = n - range.location;
    if (range.location < 0 || range.location + range.length > n)
        return CFRangeMake(0, 0);
    return range;
}

template <typename T>
static void
copy_out(CTRunRef r, const std::vector<T> &v, CFRange range, T *out)
{
    range = glyph_range(r, range);
    if (out)
        std::copy(v.begin() + range.location, v.begin() + range.location + range.length, out);
}

void CTRunGetGlyphs(CTRunRef r, CFRange range, CGGlyph *out) { if (r) copy_out(r, *r->glyphs, range, out); }
void CTRunGetPositions(CTRunRef r, CFRange range, CGPoint *out) { if (r) copy_out(r, *r->positions, range, out); }
void CTRunGetAdvances(CTRunRef r, CFRange range, CGSize *out) { if (r) copy_out(r, *r->advances, range, out); }
void CTRunGetStringIndices(CTRunRef r, CFRange range, CFIndex *out) { if (r) copy_out(r, *r->indices, range, out); }

void
CTRunGetBaseAdvancesAndOrigins(CTRunRef r, CFRange range, CGSize *advances, CGPoint *origins)
{
    if (!r)
        return;
    range = glyph_range(r, range);
    for (CFIndex i = 0; i < range.length; i++) {
        CFIndex k = range.location + i;
        if (advances)
            advances[i] = (*r->advances)[(size_t)k];
        if (origins)
            origins[i] = CGPointMake(0, (*r->positions)[(size_t)k].y);
    }
}

double
CTRunGetTypographicBounds(CTRunRef r, CFRange range, CGFloat *ascent, CGFloat *descent, CGFloat *leading)
{
    if (!r)
        return 0;
    range = glyph_range(r, range);
    if (ascent)
        *ascent = CTFontGetAscent(r->font);
    if (descent)
        *descent = CTFontGetDescent(r->font);
    if (leading)
        *leading = CTFontGetLeading(r->font);
    double w = 0;
    for (CFIndex i = 0; i < range.length; i++)
        w += (*r->advances)[(size_t)(range.location + i)].width;
    return w;
}

CGRect
CTRunGetImageBounds(CTRunRef r, CGContextRef context, CFRange range)
{
    if (!r)
        return CGRectNull;
    range = glyph_range(r, range);
    std::vector<CGRect> boxes((size_t)range.length);
    CTFontGetBoundingRectsForGlyphs(r->font, kCTFontOrientationHorizontal, r->glyphs->data() + range.location,
                                    boxes.data(), range.length);
    CGPoint text = context ? CGContextGetTextPosition(context) : CGPointZero;
    CGRect all = CGRectNull;
    for (CFIndex i = 0; i < range.length; i++) {
        if (CGRectIsEmpty(boxes[(size_t)i]))
            continue;
        CGPoint p = (*r->positions)[(size_t)(range.location + i)];
        all = CGRectUnion(all, CGRectOffset(boxes[(size_t)i], p.x + text.x, p.y + text.y));
    }
    return all;
}

/* Draw a run: glyphs in its font and foreground colour, then underline and strikethrough. */
static void
draw_run(CTRunRef r, CGContextRef c, CFRange range, CGPoint origin)
{
    range = glyph_range(r, range);
    if (!range.length)
        return;
    CGContextSaveGState(c);
    CFTypeRef fromContext = CFDictionaryGetValue(r->attributes, kCTForegroundColorFromContextAttributeName);
    bool use_context = fromContext && CFGetTypeID(fromContext) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)fromContext);
    CGColorRef color = (CGColorRef)CFDictionaryGetValue(r->attributes, kCTForegroundColorAttributeName);
    if (!use_context) {
        if (color && CFGetTypeID(color) == CGColorGetTypeID()) {
            CGContextSetFillColorWithColor(c, color);
        } else {
            CGContextSetGrayFillColor(c, 0, 1);
        }
    }
    CGColorRef stroke = (CGColorRef)CFDictionaryGetValue(r->attributes, kCTStrokeColorAttributeName);
    CFNumberRef stroke_width = (CFNumberRef)CFDictionaryGetValue(r->attributes, kCTStrokeWidthAttributeName);
    double sw = 0;
    if (stroke_width)
        CFNumberGetValue(stroke_width, kCFNumberDoubleType, &sw);
    if (sw != 0) {
        /* percent of the font size: positive strokes only, negative fills and strokes */
        CGContextSetLineWidth(c, fabs(sw) * CTFontGetSize(r->font) / 100);
        if (stroke && CFGetTypeID(stroke) == CGColorGetTypeID())
            CGContextSetStrokeColorWithColor(c, stroke);
        else if (color)
            CGContextSetStrokeColorWithColor(c, color);
        CGContextSetTextDrawingMode(c, sw > 0 ? kCGTextStroke : kCGTextFillStroke);
    }
    std::vector<CGPoint> pos((size_t)range.length);
    for (CFIndex i = 0; i < range.length; i++) {
        CGPoint p = (*r->positions)[(size_t)(range.location + i)];
        pos[(size_t)i] = CGPointMake(p.x + origin.x, p.y + origin.y);
    }
    CGAffineTransform saved = CGContextGetTextMatrix(c);
    CGContextSetFont(c, r->font->cg);
    CGContextSetFontSize(c, CTFontGetSize(r->font));
    CGAffineTransform tm = CGAffineTransformConcat(r->font->matrix, saved);
    tm.tx = saved.tx, tm.ty = saved.ty;
    CGContextSetTextMatrix(c, tm);
    CGContextFinchShowGlyphsWithColor(c, r->glyphs->data() + range.location, pos.data(), (size_t)range.length);
    CGContextSetTextMatrix(c, saved);
    /* underline and strikethrough */
    CFNumberRef ul = (CFNumberRef)CFDictionaryGetValue(r->attributes, kCTUnderlineStyleAttributeName);
    int32_t style = 0;
    if (ul)
        CFNumberGetValue(ul, kCFNumberSInt32Type, &style);
    if (style & 0xff) {
        double x0 = pos[0].x, x1 = pos.back().x + (*r->advances)[(size_t)(range.location + range.length - 1)].width;
        double t = CTFontGetUnderlineThickness(r->font) * ((style & 0xff) == kCTUnderlineStyleThick ? 2 : 1);
        double y = origin.y + CTFontGetUnderlinePosition(r->font);
        CGColorRef uc = (CGColorRef)CFDictionaryGetValue(r->attributes, kCTUnderlineColorAttributeName);
        if (uc)
            CGContextSetFillColorWithColor(c, uc);
        CGPoint tp = CGContextGetTextPosition(c);
        int lines = (style & 0xff) == kCTUnderlineStyleDouble ? 2 : 1;
        for (int k = 0; k < lines; k++)
            CGContextFillRect(c, CGRectMake(tp.x + x0, tp.y + y - t / 2 - k * 2 * t, x1 - x0, t));
    }
    CGContextRestoreGState(c);
}

void
CTRunDraw(CTRunRef r, CGContextRef c, CFRange range)
{
    if (r && c)
        draw_run(r, c, range, CGPointZero);
}

#pragma mark - CTLine

static void
line_finalize(CFTypeRef cf)
{
    struct __CTLine *l = (struct __CTLine *)cf;
    if (l->runs)
        CFRelease(l->runs);
    if (l->string)
        CFRelease(l->string);
    delete l->carets;
}

static CFStringRef
line_desc(CFTypeRef cf)
{
    CTLineRef l = (CTLineRef)cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CTLine: %p>{run count = %ld, string range = (%ld, %ld), width = %g, A/D/L = %g/%g/%g, glyph count = %ld}"),
                                    l, (long)CFArrayGetCount(l->runs), (long)l->range.location, (long)l->range.length,
                                    l->width, l->ascent, l->descent, l->leading, (long)l->glyph_count);
}

static const CTRuntimeClass line_class = {
    0, "CTLine", NULL, NULL, line_finalize, NULL, NULL, NULL, line_desc, NULL, NULL, 0,
};
static CFTypeID line_type;

CFTypeID
CTLineGetTypeID(void)
{
    return CTTypeRegister(&line_class, &line_type);
}

/* The default font: Apple's is Helvetica 12. */
CTFontRef
CTDefaultFont(void)
{
    static CTFontRef font;
    if (!font)
        font = CTFontCreateWithName(CFSTR("Helvetica"), 12, NULL);
    return font;
}

static CTFontRef
attribute_font(CFDictionaryRef attrs)
{
    CFTypeRef f = attrs ? CFDictionaryGetValue(attrs, kCTFontAttributeName) : NULL;
    if (f && CFGetTypeID(f) == CTFontGetTypeID())
        return (CTFontRef)f;
    return CTDefaultFont();
}

static double
number_attribute(CFDictionaryRef attrs, CFStringRef key, double fallback, bool *present = NULL)
{
    CFTypeRef v = attrs ? CFDictionaryGetValue(attrs, key) : NULL;
    if (present)
        *present = v && CFGetTypeID(v) == CFNumberGetTypeID();
    double d = fallback;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d);
    return d;
}

namespace {
struct Piece {
    CFRange range;
    CFDictionaryRef attributes;  /* not retained */
    CTFontRef font;              /* retained */
    UBiDiLevel level;
};
}  // namespace

/* Split [range] of the string by attributes, bidi level and font coverage, in logical order. */
static std::vector<Piece>
itemize(CFAttributedStringRef string, CFRange range, const UniChar *chars, const std::vector<UBiDiLevel> &levels)
{
    std::vector<Piece> out;
    CFIndex i = range.location, end = range.location + range.length;
    CFStringRef s = CFAttributedStringGetString(string);
    while (i < end) {
        CFRange eff;
        CFDictionaryRef attrs = CFAttributedStringGetAttributes(string, i, &eff);
        CFIndex stop = std::min(end, eff.location + eff.length);
        CTFontRef font = attribute_font(attrs);
        CFIndex j = i;
        while (j < stop) {
            UBiDiLevel lv = levels[(size_t)(j - range.location)];
            CFIndex k = j;
            while (k < stop && levels[(size_t)(k - range.location)] == lv)
                k++;
            /* fall back, character by character, where the font has no glyph */
            CFIndex a = j;
            while (a < k) {
                CFIndex len = CFStringIsSurrogateHighCharacter(chars[a - range.location]) && a + 1 < k ? 2 : 1;
                UniChar c = chars[a - range.location];
                UniChar next = a + len < k ? chars[a + len - range.location] : 0;
                uint32_t cp = len == 2 ? CFStringGetLongCharacterForSurrogatePair(c, chars[a + 1 - range.location]) : c;
                /* variation selectors, zero-width joiners, skin tones and tags stay with the character before */
                bool joins = (cp >= 0xFE00 && cp <= 0xFE0F) || cp == 0x200D || (cp >= 0x1F3FB && cp <= 0x1F3FF) ||
                             (cp >= 0xE0020 && cp <= 0xE007F);
                if (joins && !out.empty() && out.back().attributes == attrs && out.back().level == lv &&
                    out.back().range.location + out.back().range.length == a) {
                    out.back().range.length += len;
                    a += len;
                    continue;
                }
                CTFontRef use = font;
                CGGlyph g[2];
                /* where the font has no glyph, or the text asks for emoji presentation (U+FE0F) */
                if (font && (next == 0xFE0F || !CTFontGetGlyphsForCharacters(font, chars + (a - range.location), g, len)) &&
                    !CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetWhitespaceAndNewline), c))
                    use = CTFontCreateForString(font, s, CFRangeMake(a, len));
                else if (font)
                    CFRetain(use);
                if (!out.empty() && out.back().attributes == attrs && out.back().level == lv && use &&
                    out.back().font && CFEqual(out.back().font, use) &&
                    out.back().range.location + out.back().range.length == a) {
                    out.back().range.length += len;
                    if (use)
                        CFRelease(use);
                } else {
                    out.push_back({CFRangeMake(a, len), attrs, use, lv});
                }
                a += len;
            }
            j = k;
        }
        i = stop;
    }
    return out;
}

/* Shape one piece into a run (glyphs in visual order within the run). */
static struct __CTRun *
shape(const Piece &p, CFIndex base, const UniChar *chars, CFIndex nchars)
{
    struct __CTRun *run = run_new();
    run->range = p.range;
    CTFontRef font = p.font;
    run->font = font ? (CTFontRef)CFRetain(font) : NULL;
    /* the run's attributes, with the font actually used */
    CFMutableDictionaryRef attrs = p.attributes ? CFDictionaryCreateMutableCopy(NULL, 0, p.attributes)
                                                : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                            &kCFTypeDictionaryValueCallBacks);
    if (font)
        CFDictionarySetValue(attrs, kCTFontAttributeName, font);
    run->attributes = attrs;
    if (!font)
        return run;
    bool rtl = p.level & 1;
    if (rtl)
        run->status |= kCTRunStatusRightToLeft;
    if (!CGAffineTransformIsIdentity(font->matrix)) {
        run->status |= kCTRunStatusHasNonIdentityMatrix;
        run->text_matrix = font->matrix;
    }
    hb_buffer_t *buf = hb_buffer_create();
    hb_buffer_add_utf16(buf, (const uint16_t *)chars, (int)nchars, (unsigned)(p.range.location - base),
                        (int)p.range.length);
    hb_buffer_set_direction(buf, rtl ? HB_DIRECTION_RTL : HB_DIRECTION_LTR);
    hb_buffer_guess_segment_properties(buf);
    std::vector<hb_feature_t> features;
    bool lig_set;
    double lig = number_attribute(p.attributes, kCTLigatureAttributeName, 1, &lig_set);
    if (lig_set && lig == 0) {
        for (const char *tag : {"liga", "clig", "dlig", "hlig", "rlig"}) {
            hb_feature_t f = {hb_tag_from_string(tag, 4), 0, HB_FEATURE_GLOBAL_START, HB_FEATURE_GLOBAL_END};
            if (strcmp(tag, "rlig"))
                features.push_back(f);
        }
    } else if (lig_set && lig >= 2) {
        features.push_back({hb_tag_from_string("dlig", 4), 1, HB_FEATURE_GLOBAL_START, HB_FEATURE_GLOBAL_END});
    }
    bool kern_set;
    double tracking = number_attribute(p.attributes, kCTKernAttributeName, 0, &kern_set);
    if (kern_set && tracking == 0)
        features.push_back({hb_tag_from_string("kern", 4), 0, HB_FEATURE_GLOBAL_START, HB_FEATURE_GLOBAL_END});
    double tracking_attr = number_attribute(p.attributes, kCTTrackingAttributeName, 0);
    hb_buffer_set_flags(buf, (hb_buffer_flags_t)(HB_BUFFER_FLAG_REMOVE_DEFAULT_IGNORABLES));
    hb_shape((hb_font_t *)font->hb, buf, features.data(), (unsigned)features.size());
    unsigned n;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buf, &n);
    hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buf, &n);
    double s = font->size / font->upem;
    double x = 0;
    CGGlyph space = 0;
    UniChar sp = ' ';
    CTFontGetGlyphsForCharacters(font, &sp, &space, 1);
    for (unsigned i = 0; i < n; i++) {
        UniChar ch = chars[info[i].cluster];
        double adv = pos[i].x_advance * s + tracking + tracking_attr;
        CGGlyph glyph = (CGGlyph)info[i].codepoint;
        /* as Apple's: line ends take no space (the space glyph unless the font maps them),
           tabs are spaces advanced to the next stop later, other controls show nothing */
        if (ch == '\n' || ch == 0x2028 || ch == 0x2029 || ch == 0x85 || ch == '\v' || ch == '\f' || ch == '\r') {
            if (!glyph)
                glyph = space;
            adv = 0;
        } else if (ch == '\t') {
            glyph = space;
        } else if (ch < 0x20 || (ch >= 0x7f && ch < 0xa0)) {
            continue;
        }
        run->glyphs->push_back(glyph);
        run->positions->push_back(CGPointMake(x + pos[i].x_offset * s, pos[i].y_offset * s));
        run->advances->push_back(CGSizeMake(adv, 0));
        run->indices->push_back((CFIndex)info[i].cluster + base);
        x += adv;
    }
    hb_buffer_destroy(buf);
    run->width = x;
    run->tracking = tracking + tracking_attr;
    return run;
}

/* Caret offset of every string index in the line (logical), from the runs' glyphs. */
static void
compute_carets(struct __CTLine *l, const UniChar *chars)
{
    CFIndex n = l->range.length;
    l->carets = new std::vector<CGFloat>((size_t)n + 1, 0);
    std::vector<bool> set((size_t)n + 1, false);
    for (CFIndex ri = 0; ri < CFArrayGetCount(l->runs); ri++) {
        CTRunRef r = (CTRunRef)CFArrayGetValueAtIndex(l->runs, ri);
        size_t g = r->glyphs->size();
        std::vector<int> nominal(g);
        CGFontGetGlyphAdvances(r->font->cg, r->glyphs->data(), g, nominal.data());
        double s = r->font->size / r->font->upem;
        for (size_t k = 0; k < g; k++) {
            CFIndex start = (*r->indices)[k] - l->range.location;
            /* the characters this glyph covers: up to the next cluster */
            CFIndex next = r->range.location + r->range.length - l->range.location;
            for (size_t m = 0; m < g; m++) {
                CFIndex idx = (*r->indices)[m] - l->range.location;
                if (idx > start && idx < next)
                    next = idx;
            }
            double x = (*r->positions)[k].x;
            double adv = (*r->advances)[k].width;
            double adjust_prev = 0;
            if (k > 0)
                adjust_prev = (*r->advances)[k - 1].width - nominal[k - 1] * s;
            else if (ri > 0) {
                CTRunRef pr = (CTRunRef)CFArrayGetValueAtIndex(l->runs, ri - 1);
                adjust_prev = pr->tracking;
            }
            double count = (double)(next - start);
            double base_adv = adv - (adv - nominal[k] * s);  /* the glyph's own advance, for splitting ligatures */
            for (CFIndex c = start; c < next && c < n; c++) {
                double off = c == start ? x - adjust_prev / 2 : x + base_adv * (double)(c - start) / count;
                if (!set[(size_t)c]) {
                    (*l->carets)[(size_t)c] = off;
                    set[(size_t)c] = true;
                }
            }
        }
    }
    /* the end of the line, less the last glyph's trailing adjustment */
    double end = l->width;
    if (CFArrayGetCount(l->runs)) {
        CTRunRef last = (CTRunRef)CFArrayGetValueAtIndex(l->runs, CFArrayGetCount(l->runs) - 1);
        end -= last->tracking;
    }
    (*l->carets)[(size_t)n] = end;
    if (n == 0)
        (*l->carets)[0] = 0;
    (void)chars;
}

CTLineRef
CTLineCreateWithAttributedSubstring(CFAttributedStringRef string, CFRange range)
{
    struct __CTLine *l = (struct __CTLine *)CTTypeCreateInstance(CTLineGetTypeID(), sizeof(struct __CTLine));
    l->string = (CFAttributedStringRef)CFRetain(string);
    l->range = range;
    CFMutableArrayRef runs = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    l->runs = runs;
    CFStringRef s = CFAttributedStringGetString(string);
    std::vector<UniChar> chars((size_t)range.length + 1);
    CFStringGetCharacters(s, range, chars.data());
    /* bidi levels */
    std::vector<UBiDiLevel> levels((size_t)range.length, 0);
    UErrorCode err = U_ZERO_ERROR;
    UBiDi *bidi = ubidi_openSized((int32_t)range.length, 0, &err);
    bool has_rtl = false;
    for (CFIndex i = 0; i < range.length && !has_rtl; i++) {
        UCharDirection d = u_charDirection(chars[(size_t)i]);
        has_rtl = d == U_RIGHT_TO_LEFT || d == U_RIGHT_TO_LEFT_ARABIC || d == U_RIGHT_TO_LEFT_EMBEDDING ||
                  d == U_RIGHT_TO_LEFT_OVERRIDE || d == U_RIGHT_TO_LEFT_ISOLATE;
    }
    if (has_rtl && U_SUCCESS(err)) {
        ubidi_setPara(bidi, (const UChar *)chars.data(), (int32_t)range.length, UBIDI_DEFAULT_LTR, NULL, &err);
        if (U_SUCCESS(err))
            for (CFIndex i = 0; i < range.length; i++)
                levels[(size_t)i] = ubidi_getLevelAt(bidi, (int32_t)i);
    }
    if (bidi)
        ubidi_close(bidi);
    std::vector<Piece> pieces = itemize(string, range, chars.data(), levels);
    /* visual order of pieces: reverse runs of odd level (simple reordering by levels) */
    std::vector<size_t> order(pieces.size());
    for (size_t i = 0; i < order.size(); i++)
        order[i] = i;
    if (has_rtl) {
        std::vector<UBiDiLevel> plevels;
        for (auto &p : pieces)
            plevels.push_back(p.level);
        std::vector<int32_t> visual(pieces.size());
        ubidi_reorderVisual(plevels.data(), (int32_t)plevels.size(), visual.data());
        for (size_t i = 0; i < order.size(); i++)
            order[i] = (size_t)visual[i];
    }
    double x = 0;
    CGFloat ascent = 0, descent = 0, leading = 0;
    for (size_t oi : order) {
        struct __CTRun *run = shape(pieces[oi], range.location, chars.data(), range.length);
        for (auto &p : *run->positions)
            p.x += x;
        x += run->width;
        if (run->font) {
            ascent = std::max(ascent, CTFontGetAscent(run->font));
            descent = std::max(descent, CTFontGetDescent(run->font));
            leading = std::max(leading, CTFontGetLeading(run->font));
        }
        l->glyph_count += (CFIndex)run->glyphs->size();
        CFArrayAppendValue(runs, run);
        CFRelease(run);
    }
    for (auto &p : pieces)
        if (p.font)
            CFRelease(p.font);
    /* tabs advance to the paragraph style's next tab stop */
    CFDictionaryRef first = range.length ? CFAttributedStringGetAttributes(string, range.location, NULL) : NULL;
    CTParagraphStyleRef style = first ? (CTParagraphStyleRef)CFDictionaryGetValue(first, kCTParagraphStyleAttributeName) : NULL;
    double shift = 0;
    for (CFIndex ri = 0; ri < CFArrayGetCount(runs); ri++) {
        struct __CTRun *r = (struct __CTRun *)CFArrayGetValueAtIndex(runs, ri);
        for (size_t k = 0; k < r->glyphs->size(); k++) {
            (*r->positions)[k].x += shift;
            if (chars[(size_t)((*r->indices)[k] - range.location)] != '\t')
                continue;
            double pen = (*r->positions)[k].x, stop = -1;
            CFArrayRef tabs = style ? style->tabs : NULL;
            static CFArrayRef defaults;
            if (!tabs) {
                if (!defaults) {
                    CTParagraphStyleRef d = CTParagraphStyleCreate(NULL, 0);
                    defaults = (CFArrayRef)CFRetain(d->tabs);
                    CFRelease(d);
                }
                tabs = defaults;
            }
            for (CFIndex t = 0; t < CFArrayGetCount(tabs) && stop < 0; t++) {
                double loc = CTTextTabGetLocation((CTTextTabRef)CFArrayGetValueAtIndex(tabs, t));
                if (loc > pen + 0.001)
                    stop = loc;
            }
            double interval = style ? style->values.tab_interval : 0;
            if (stop < 0 && interval > 0)
                stop = (floor(pen / interval) + 1) * interval;
            double adv = stop >= 0 ? stop - pen : (*r->advances)[k].width;
            shift += adv - (*r->advances)[k].width;
            (*r->advances)[k].width = adv;
        }
        r->width = 0;
        for (auto &a : *r->advances)
            r->width += a.width;
    }
    x += shift;
    l->width = x;
    l->ascent = ascent, l->descent = descent, l->leading = leading;
    /* trailing whitespace */
    CFCharacterSetRef ws = CFCharacterSetGetPredefined(kCFCharacterSetWhitespaceAndNewline);
    CFIndex t = range.length;
    while (t > 0 && CFCharacterSetIsCharacterMember(ws, chars[(size_t)t - 1]))
        t--;
    double trailing = 0;
    for (CFIndex ri = 0; ri < CFArrayGetCount(runs); ri++) {
        CTRunRef r = (CTRunRef)CFArrayGetValueAtIndex(runs, ri);
        for (size_t k = 0; k < r->glyphs->size(); k++)
            if ((*r->indices)[k] - range.location >= t)
                trailing += (*r->advances)[k].width;
    }
    l->trailing_whitespace = trailing;
    compute_carets(l, chars.data());
    return l;
}

/*
 * A line cut from a line shaped over more text, as Apple's typesetter makes
 * lines: glyphs keep the advances (and kerning) they had in context.
 * Left-to-right lines only; the caller reshapes when the text has bidi.
 */
CTLineRef
CTLineCreateSlice(CTLineRef whole, CFRange range)
{
    struct __CTLine *l = (struct __CTLine *)CTTypeCreateInstance(CTLineGetTypeID(), sizeof(struct __CTLine));
    l->string = (CFAttributedStringRef)CFRetain(whole->string);
    l->range = range;
    CFMutableArrayRef runs = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    l->runs = runs;
    double start_x = -1, x = 0;
    CGFloat ascent = 0, descent = 0, leading = 0;
    for (CFIndex ri = 0; ri < CFArrayGetCount(whole->runs); ri++) {
        CTRunRef r = (CTRunRef)CFArrayGetValueAtIndex(whole->runs, ri);
        if (r->range.location >= range.location + range.length || r->range.location + r->range.length <= range.location)
            continue;
        struct __CTRun *n = run_new();
        n->attributes = (CFDictionaryRef)CFRetain(r->attributes);
        n->font = (CTFontRef)CFRetain(r->font);
        n->status = r->status;
        n->text_matrix = r->text_matrix;
        n->tracking = r->tracking;
        CFIndex lo = std::max(range.location, r->range.location);
        CFIndex hi = std::min(range.location + range.length, r->range.location + r->range.length);
        n->range = CFRangeMake(lo, hi - lo);
        for (size_t k = 0; k < r->glyphs->size(); k++) {
            CFIndex idx = (*r->indices)[k];
            if (idx < range.location || idx >= range.location + range.length)
                continue;
            if (start_x < 0)
                start_x = (*r->positions)[k].x;
            n->glyphs->push_back((*r->glyphs)[k]);
            CGPoint p = (*r->positions)[k];
            n->positions->push_back(CGPointMake(p.x - start_x, p.y));
            n->advances->push_back((*r->advances)[k]);
            n->indices->push_back(idx);
            n->width += (*r->advances)[k].width;
        }
        x += n->width;
        ascent = std::max(ascent, CTFontGetAscent(n->font));
        descent = std::max(descent, CTFontGetDescent(n->font));
        leading = std::max(leading, CTFontGetLeading(n->font));
        l->glyph_count += (CFIndex)n->glyphs->size();
        CFArrayAppendValue(runs, n);
        CFRelease(n);
    }
    l->width = x;
    l->ascent = ascent, l->descent = descent, l->leading = leading;
    std::vector<UniChar> chars((size_t)range.length + 1);
    CFStringGetCharacters(CFAttributedStringGetString(l->string), range, chars.data());
    CFCharacterSetRef ws = CFCharacterSetGetPredefined(kCFCharacterSetWhitespaceAndNewline);
    CFIndex t = range.length;
    while (t > 0 && CFCharacterSetIsCharacterMember(ws, chars[(size_t)t - 1]))
        t--;
    double trailing = 0;
    for (CFIndex ri = 0; ri < CFArrayGetCount(runs); ri++) {
        CTRunRef r = (CTRunRef)CFArrayGetValueAtIndex(runs, ri);
        for (size_t k = 0; k < r->glyphs->size(); k++)
            if ((*r->indices)[k] - range.location >= t)
                trailing += (*r->advances)[k].width;
    }
    l->trailing_whitespace = trailing;
    compute_carets(l, chars.data());
    return l;
}

bool
CTLineHasRightToLeft(CTLineRef l)
{
    for (CFIndex ri = 0; ri < CFArrayGetCount(l->runs); ri++)
        if (((CTRunRef)CFArrayGetValueAtIndex(l->runs, ri))->status & kCTRunStatusRightToLeft)
            return true;
    return false;
}

CTLineRef
CTLineCreateWithAttributedString(CFAttributedStringRef string)
{
    if (!string)
        return NULL;
    return CTLineCreateWithAttributedSubstring(string, CFRangeMake(0, CFAttributedStringGetLength(string)));
}

CFIndex CTLineGetGlyphCount(CTLineRef l) { return l ? l->glyph_count : 0; }
CFArrayRef CTLineGetGlyphRuns(CTLineRef l) { return l ? l->runs : NULL; }
CFRange CTLineGetStringRange(CTLineRef l) { return l ? l->range : CFRangeMake(0, 0); }
double CTLineGetTrailingWhitespaceWidth(CTLineRef l) { return l ? l->trailing_whitespace : 0; }

double
CTLineGetTypographicBounds(CTLineRef l, CGFloat *ascent, CGFloat *descent, CGFloat *leading)
{
    if (!l)
        return 0;
    if (ascent)
        *ascent = l->ascent;
    if (descent)
        *descent = l->descent;
    if (leading)
        *leading = l->leading;
    return l->width;
}

CGRect
CTLineGetBoundsWithOptions(CTLineRef l, CTLineBoundsOptions options)
{
    if (!l)
        return CGRectZero;
    double w = l->width;
    if (options & kCTLineBoundsExcludeTypographicShifts)
        (void)0;
    if (options & kCTLineBoundsUseGlyphPathBounds)
        return CTLineGetImageBounds(l, NULL);
    if (options & kCTLineBoundsUseHangingPunctuation)
        (void)0;
    if (!(options & kCTLineBoundsExcludeTypographicLeading))
        return CGRectMake(0, -l->descent - l->leading, w, l->ascent + l->descent + l->leading);
    return CGRectMake(0, -l->descent, w, l->ascent + l->descent);
}

CGRect
CTLineGetImageBounds(CTLineRef l, CGContextRef context)
{
    if (!l)
        return CGRectNull;
    CGRect all = CGRectNull;
    for (CFIndex i = 0; i < CFArrayGetCount(l->runs); i++)
        all = CGRectUnion(all, CTRunGetImageBounds((CTRunRef)CFArrayGetValueAtIndex(l->runs, i), context, CFRangeMake(0, 0)));
    return all;
}

double
CTLineGetPenOffsetForFlush(CTLineRef l, CGFloat flushFactor, double flushWidth)
{
    if (!l)
        return 0;
    double used = l->width - l->trailing_whitespace;
    double off = (flushWidth - used) * fmin(1, fmax(0, flushFactor));
    return off > 0 ? off : 0;
}

CGFloat
CTLineGetOffsetForStringIndex(CTLineRef l, CFIndex index, CGFloat *secondary)
{
    if (!l)
        return 0;
    CFIndex i = index - l->range.location;
    if (i < 0)
        i = 0;
    if (i > l->range.length)
        i = l->range.length;
    CGFloat off = (*l->carets)[(size_t)i];
    if (secondary)
        *secondary = off;
    return off;
}

CFIndex
CTLineGetStringIndexForPosition(CTLineRef l, CGPoint position)
{
    if (!l || l->range.length == 0)
        return kCFNotFound;
    const std::vector<CGFloat> &c = *l->carets;
    CFIndex best = 0;
    double dist = INFINITY;
    if (position.x >= c.back())
        return l->range.location + l->range.length;
    for (size_t i = 0; i < c.size(); i++) {
        if (i > 0 && i < c.size() - 1 && c[i] == 0 && c[i - 1] > 0)
            continue;  /* characters truncated away */
        double d = fabs(position.x - c[i]);
        if (d < dist)
            dist = d, best = (CFIndex)i;
    }
    return l->range.location + best;
}

void
CTLineEnumerateCaretOffsets(CTLineRef l, void (^block)(double offset, CFIndex charIndex, bool leadingEdge, bool *stop))
{
    if (!l || !block)
        return;
    bool stop = false;
    for (CFIndex i = 0; i < l->range.length && !stop; i++) {
        block((*l->carets)[(size_t)i], l->range.location + i, true, &stop);
        if (!stop)
            block((*l->carets)[(size_t)i + 1], l->range.location + i, false, &stop);
    }
}

void
CTLineDraw(CTLineRef l, CGContextRef c)
{
    if (!l || !c)
        return;
    for (CFIndex i = 0; i < CFArrayGetCount(l->runs); i++)
        CTRunDraw((CTRunRef)CFArrayGetValueAtIndex(l->runs, i), c, CFRangeMake(0, 0));
}

#pragma mark - Truncation and justification

CTLineRef
CTLineCreateTruncatedLine(CTLineRef l, double width, CTLineTruncationType type, CTLineRef token)
{
    if (!l)
        return NULL;
    if (l->width <= width)
        return (CTLineRef)CFRetain(l);
    /* keep characters from the start (end truncation) while they fit with the token */
    double tw = token ? token->width : 0;
    CFIndex keep = 0;
    for (CFIndex i = 0; i <= l->range.length; i++)
        if ((*l->carets)[(size_t)i] + tw <= width)
            keep = i;
    /* (start and middle truncation are done as end truncation for now) */
    CFMutableAttributedStringRef s = CFAttributedStringCreateMutableCopy(NULL, 0, l->string);
    CFAttributedStringRef sub = CFAttributedStringCreateWithSubstring(NULL, s, CFRangeMake(l->range.location, keep));
    CFMutableAttributedStringRef out = CFAttributedStringCreateMutableCopy(NULL, 0, sub);
    if (token)
        CFAttributedStringReplaceAttributedString(out, CFRangeMake(keep, 0), token->string);
    struct __CTLine *t = (struct __CTLine *)CTLineCreateWithAttributedString(out);
    CFRelease(out), CFRelease(sub), CFRelease(s);
    /* as Apple's: the line still covers the whole string range; the last run takes the dropped characters */
    CFIndex old_len = t->range.length;
    t->range = l->range;
    CFIndex runs = CFArrayGetCount(t->runs);
    if (runs) {
        struct __CTRun *last = (struct __CTRun *)CFArrayGetValueAtIndex(t->runs, runs - 1);
        last->range.length = l->range.location + l->range.length - last->range.location;
    }
    double end = (*t->carets)[(size_t)old_len];
    t->carets->resize((size_t)l->range.length + 1, 0);
    for (CFIndex i = old_len; i < l->range.length; i++)
        (*t->carets)[(size_t)i] = 0;
    (*t->carets)[(size_t)l->range.length] = end;
    return t;
}

CTLineRef
CTLineCreateJustifiedLine(CTLineRef l, CGFloat factor, double width)
{
    if (!l)
        return NULL;
    struct __CTLine *j = (struct __CTLine *)CTLineCreateWithAttributedSubstring(l->string, l->range);
    double used = j->width - j->trailing_whitespace;
    double extra = (width - used) * fmin(1, fmax(0, factor));
    if (extra <= 0 || j->glyph_count < 2)
        return j;
    /* spread the space over the gaps between glyphs, evenly */
    CFIndex gaps = j->glyph_count - 1, k = 0;
    double add = extra / gaps, shift = 0;
    for (CFIndex ri = 0; ri < CFArrayGetCount(j->runs); ri++) {
        struct __CTRun *r = (struct __CTRun *)CFArrayGetValueAtIndex(j->runs, ri);
        double run_shift_start = shift;
        (void)run_shift_start;
        for (size_t g = 0; g < r->glyphs->size(); g++, k++) {
            (*r->positions)[g].x += shift;
            if (k < gaps) {
                (*r->advances)[g].width += add;
                shift += add;
            }
        }
        r->width = 0;
        for (auto &a : *r->advances)
            r->width += a.width;
    }
    j->width = width;
    delete j->carets;
    std::vector<UniChar> chars((size_t)j->range.length + 1);
    CFStringGetCharacters(CFAttributedStringGetString(j->string), j->range, chars.data());
    compute_carets(j, chars.data());
    return j;
}
