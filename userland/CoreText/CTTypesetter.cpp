/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CTTypesetter, CTFramesetter and CTFrame: breaking an attributed string
 * into lines (at ICU line-break opportunities, or between clusters when a
 * word doesn't fit; line ends always end a line) and stacking them in a
 * frame, with Apple's rounding: each line takes its rounded ascent, descent
 * and leading; origins are relative to the frame's box; a line shows only
 * when its descent stays inside the box.
 */
#include "CTLineInternal.h"
#include "CTParagraphInternal.h"
#include <unicode/ubrk.h>
#include <math.h>
#include <algorithm>

#pragma mark - CTTypesetter

struct __CTTypesetter {
    CTRuntimeBase base;
    CFAttributedStringRef string;
    std::vector<UniChar> *chars;
    UBreakIterator *lines;
    UBreakIterator *clusters;
    CTLineRef whole;   /* the text shaped once; lines are cut from it */
    bool reshape;      /* bidi text: lines are shaped on their own */
};

static void
ts_finalize(CFTypeRef cf)
{
    struct __CTTypesetter *t = (struct __CTTypesetter *)cf;
    if (t->lines)
        ubrk_close(t->lines);
    if (t->clusters)
        ubrk_close(t->clusters);
    if (t->string)
        CFRelease(t->string);
    if (t->whole)
        CFRelease(t->whole);
    delete t->chars;
}

static const CTRuntimeClass ts_class = {
    0, "CTTypesetter", NULL, NULL, ts_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID ts_type;

CFTypeID
CTTypesetterGetTypeID(void)
{
    return CTTypeRegister(&ts_class, &ts_type);
}

CTTypesetterRef
CTTypesetterCreateWithAttributedStringAndOptions(CFAttributedStringRef string, CFDictionaryRef options)
{
    if (!string)
        return NULL;
    struct __CTTypesetter *t = (struct __CTTypesetter *)CTTypeCreateInstance(CTTypesetterGetTypeID(), sizeof(struct __CTTypesetter));
    t->string = CFAttributedStringCreateCopy(NULL, string);
    CFIndex n = CFAttributedStringGetLength(string);
    t->chars = new std::vector<UniChar>((size_t)n + 1, 0);
    CFStringGetCharacters(CFAttributedStringGetString(string), CFRangeMake(0, n), t->chars->data());
    UErrorCode err = U_ZERO_ERROR;
    t->lines = ubrk_open(UBRK_LINE, "en", (const UChar *)t->chars->data(), (int32_t)n, &err);
    err = U_ZERO_ERROR;
    t->clusters = ubrk_open(UBRK_CHARACTER, "en", (const UChar *)t->chars->data(), (int32_t)n, &err);
    t->whole = CTLineCreateWithAttributedSubstring(t->string, CFRangeMake(0, n));
    t->reshape = CTLineHasRightToLeft(t->whole);
    return t;
}

CTTypesetterRef
CTTypesetterCreateWithAttributedString(CFAttributedStringRef string)
{
    return CTTypesetterCreateWithAttributedStringAndOptions(string, NULL);
}

static bool
is_line_end(UniChar c)
{
    return c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029 || c == 0x85 || c == '\v' || c == '\f';
}

/* Where the line starting at `start` must end at the latest (after a line end character). */
static CFIndex
hard_end(CTTypesetterRef t, CFIndex start)
{
    CFIndex n = (CFIndex)t->chars->size() - 1;
    for (CFIndex i = start; i < n; i++) {
        UniChar c = (*t->chars)[(size_t)i];
        if (is_line_end(c)) {
            if (c == '\r' && i + 1 < n && (*t->chars)[(size_t)i + 1] == '\n')
                return i + 2;
            return i + 1;
        }
    }
    return n;
}

static CTLineRef
make_line(CTTypesetterRef t, CFRange range)
{
    return t->reshape ? CTLineCreateWithAttributedSubstring(t->string, range) : CTLineCreateSlice(t->whole, range);
}

/* The width of [start, end): less trailing whitespace for line breaks, all of it for cluster breaks. */
static double
used_width(CTTypesetterRef t, CFIndex start, CFIndex end, bool with_trailing = false)
{
    CTLineRef l = make_line(t, CFRangeMake(start, end - start));
    double w = with_trailing ? l->width : l->width - l->trailing_whitespace;
    CFRelease(l);
    return w;
}

CFIndex
CTTypesetterSuggestClusterBreakWithOffset(CTTypesetterRef t, CFIndex start, double width, double offset)
{
    if (!t)
        return 0;
    CFIndex limit = hard_end(t, start), best = 0;
    for (int32_t b = ubrk_following(t->clusters, (int32_t)start); b != UBRK_DONE && b <= limit;
         b = ubrk_next(t->clusters)) {
        if (best && used_width(t, start, b, true) > width)
            break;
        best = b - start;
        if (b == limit)
            break;
    }
    return best ? best : (limit > start ? 1 : 0);
}

CFIndex
CTTypesetterSuggestClusterBreak(CTTypesetterRef t, CFIndex start, double width)
{
    return CTTypesetterSuggestClusterBreakWithOffset(t, start, width, 0);
}

CFIndex
CTTypesetterSuggestLineBreakWithOffset(CTTypesetterRef t, CFIndex start, double width, double offset)
{
    if (!t)
        return 0;
    CFIndex limit = hard_end(t, start), best = 0;
    if (used_width(t, start, limit) <= width)
        return limit - start;
    for (int32_t b = ubrk_following(t->lines, (int32_t)start); b != UBRK_DONE && b <= limit; b = ubrk_next(t->lines)) {
        if (used_width(t, start, b) > width)
            break;
        best = b - start;
    }
    return best ? best : CTTypesetterSuggestClusterBreakWithOffset(t, start, width, offset);
}

CFIndex
CTTypesetterSuggestLineBreak(CTTypesetterRef t, CFIndex start, double width)
{
    return CTTypesetterSuggestLineBreakWithOffset(t, start, width, 0);
}

CTLineRef
CTTypesetterCreateLineWithOffset(CTTypesetterRef t, CFRange range, double offset)
{
    if (!t)
        return NULL;
    if (range.length == 0)
        range.length = (CFIndex)t->chars->size() - 1 - range.location;
    return make_line(t, range);
}

CTLineRef
CTTypesetterCreateLine(CTTypesetterRef t, CFRange range)
{
    return CTTypesetterCreateLineWithOffset(t, range, 0);
}

#pragma mark - CTFrame

struct __CTFrame {
    CTRuntimeBase base;
    CGPathRef path;
    CFRange range, visible;
    CFArrayRef lines;
    std::vector<CGPoint> *origins;
    CFDictionaryRef attributes;
    CGRect box;
};

static void
frame_finalize(CFTypeRef cf)
{
    struct __CTFrame *f = (struct __CTFrame *)cf;
    if (f->path)
        CFRelease(f->path);
    if (f->lines)
        CFRelease(f->lines);
    if (f->attributes)
        CFRelease(f->attributes);
    delete f->origins;
}

static const CTRuntimeClass frame_class = {
    0, "CTFrame", NULL, NULL, frame_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID frame_type;

CFTypeID
CTFrameGetTypeID(void)
{
    return CTTypeRegister(&frame_class, &frame_type);
}

CFRange CTFrameGetStringRange(CTFrameRef f) { return f ? f->range : CFRangeMake(0, 0); }
CFRange CTFrameGetVisibleStringRange(CTFrameRef f) { return f ? f->visible : CFRangeMake(0, 0); }
CGPathRef CTFrameGetPath(CTFrameRef f) { return f ? f->path : NULL; }
CFDictionaryRef CTFrameGetFrameAttributes(CTFrameRef f) { return f ? f->attributes : NULL; }
CFArrayRef CTFrameGetLines(CTFrameRef f) { return f ? f->lines : NULL; }

void
CTFrameGetLineOrigins(CTFrameRef f, CFRange range, CGPoint origins[])
{
    if (!f || !origins)
        return;
    if (range.length == 0)
        range.length = (CFIndex)f->origins->size() - range.location;
    for (CFIndex i = 0; i < range.length && (size_t)(range.location + i) < f->origins->size(); i++)
        origins[i] = (*f->origins)[(size_t)(range.location + i)];
}

void
CTFrameDraw(CTFrameRef f, CGContextRef c)
{
    if (!f || !c)
        return;
    for (CFIndex i = 0; i < CFArrayGetCount(f->lines); i++) {
        CGPoint o = (*f->origins)[(size_t)i];
        CGContextSetTextPosition(c, f->box.origin.x + o.x, f->box.origin.y + o.y);
        CTLineDraw((CTLineRef)CFArrayGetValueAtIndex(f->lines, i), c);
    }
}

#pragma mark - Layout

namespace {
struct Layout {
    std::vector<CTLineRef> lines;  /* retained */
    std::vector<CGPoint> origins;  /* relative to the box */
    CFIndex end;                   /* string index after the last line that fits */
    double width_needed, height_needed;
};
}  // namespace

static CTParagraphStyleRef
style_at(CFAttributedStringRef s, CFIndex i)
{
    CFDictionaryRef a = CFAttributedStringGetAttributes(s, i, NULL);
    CFTypeRef p = a ? CFDictionaryGetValue(a, kCTParagraphStyleAttributeName) : NULL;
    return p && CFGetTypeID(p) == CTParagraphStyleGetTypeID() ? (CTParagraphStyleRef)p : NULL;
}

/*
 * Lay out [range] in a box of `width` x `height` (height may be unbounded).
 * Lines past the bottom are not kept when `clip`.
 */
static Layout
layout(CTTypesetterRef ts, CFRange range, double width, double height, bool clip)
{
    Layout out = {};
    CFAttributedStringRef s = ts->string;
    CFIndex i = range.location, end = range.location + range.length;
    double y = height;  /* the top of the next line */
    bool para_start = true;
    out.end = i;
    while (i < end) {
        CTParagraphStyleRef ps = style_at(s, i);
        CTParagraphValues v = {};
        v.alignment = kCTTextAlignmentNatural;
        if (ps)
            v = ps->values;
        double head = para_start ? v.first_indent : v.head_indent;
        double right = v.tail_indent > 0 ? v.tail_indent : width + v.tail_indent;
        double avail = right - head;
        CFIndex len;
        if (v.line_break == kCTLineBreakByCharWrapping)
            len = CTTypesetterSuggestClusterBreak(ts, i, avail);
        else
            len = CTTypesetterSuggestLineBreak(ts, i, avail);
        if (len <= 0)
            break;
        if (i + len > end)
            len = end - i;
        UniChar last = (*ts->chars)[(size_t)(i + len - 1)];
        bool para_end = is_line_end(last) && last != 0x2028 && last != '\v';
        bool text_end = i + len >= end;
        CTLineRef line = make_line(ts, CFRangeMake(i, len));
        if (v.alignment == kCTTextAlignmentJustified && !para_end && !text_end) {
            CTLineRef j = CTLineCreateJustifiedLine(line, 1.0, avail);
            CFRelease(line);
            line = j;
            ((struct __CTLine *)line)->trailing_whitespace = 0;
        }
        double used = line->width - line->trailing_whitespace;
        double x = head;
        if (v.alignment == kCTTextAlignmentRight)
            x = right - used;
        else if (v.alignment == kCTTextAlignmentCenter)
            x = head + (avail - used) / 2;
        double ascent = round(line->ascent), descent = round(line->descent), leading = round(line->leading);
        if (out.lines.empty() && v.paragraph_spacing_before > 0)
            y -= v.paragraph_spacing_before;
        double origin = y - ascent;
        if (clip && origin - descent < -0.001) {
            CFRelease(line);
            break;
        }
        out.lines.push_back(line);
        out.origins.push_back(CGPointMake(x, origin));
        out.width_needed = std::max(out.width_needed, head + used + (v.tail_indent <= 0 ? -v.tail_indent : 0));
        out.height_needed = height - (origin - line->descent);
        y = origin - descent - leading - v.line_spacing_adjustment;
        if (para_end)
            y -= v.paragraph_spacing;
        out.end = i + len;
        i += len;
        para_start = para_end;
    }
    return out;
}

#pragma mark - CTFramesetter

struct __CTFramesetter {
    CTRuntimeBase base;
    CTTypesetterRef typesetter;
};

static void
fs_finalize(CFTypeRef cf)
{
    struct __CTFramesetter *f = (struct __CTFramesetter *)cf;
    if (f->typesetter)
        CFRelease(f->typesetter);
}

static const CTRuntimeClass fs_class = {
    0, "CTFramesetter", NULL, NULL, fs_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID fs_type;

CFTypeID
CTFramesetterGetTypeID(void)
{
    return CTTypeRegister(&fs_class, &fs_type);
}

CTFramesetterRef
CTFramesetterCreateWithTypesetter(CTTypesetterRef typesetter)
{
    if (!typesetter)
        return NULL;
    struct __CTFramesetter *f = (struct __CTFramesetter *)CTTypeCreateInstance(CTFramesetterGetTypeID(), sizeof(struct __CTFramesetter));
    f->typesetter = (CTTypesetterRef)CFRetain(typesetter);
    return f;
}

CTFramesetterRef
CTFramesetterCreateWithAttributedString(CFAttributedStringRef string)
{
    CTTypesetterRef t = CTTypesetterCreateWithAttributedString(string);
    if (!t)
        return NULL;
    CTFramesetterRef f = CTFramesetterCreateWithTypesetter(t);
    CFRelease(t);
    return f;
}

CTTypesetterRef
CTFramesetterGetTypesetter(CTFramesetterRef f)
{
    return f ? f->typesetter : NULL;
}

static CFRange
full(CTFramesetterRef f, CFRange range)
{
    CFIndex n = (CFIndex)f->typesetter->chars->size() - 1;
    if (range.length == 0)
        range.length = n - range.location;
    return range;
}

CTFrameRef
CTFramesetterCreateFrame(CTFramesetterRef fs, CFRange range, CGPathRef path, CFDictionaryRef attributes)
{
    if (!fs || !path)
        return NULL;
    range = full(fs, range);
    CGRect box = CGPathGetBoundingBox(path);
    Layout l = layout(fs->typesetter, range, box.size.width, box.size.height, true);
    struct __CTFrame *f = (struct __CTFrame *)CTTypeCreateInstance(CTFrameGetTypeID(), sizeof(struct __CTFrame));
    f->path = CGPathCreateCopy(path);
    f->box = box;
    f->range = range;
    f->visible = CFRangeMake(range.location, l.end - range.location);
    CFMutableArrayRef lines = CFArrayCreateMutable(NULL, (CFIndex)l.lines.size(), &kCFTypeArrayCallBacks);
    for (CTLineRef line : l.lines) {
        CFArrayAppendValue(lines, line);
        CFRelease(line);
    }
    f->lines = lines;
    f->origins = new std::vector<CGPoint>(l.origins);
    f->attributes = attributes ? CFDictionaryCreateCopy(NULL, attributes) : NULL;
    return f;
}

CGSize
CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterRef fs, CFRange range, CFDictionaryRef attributes,
                                             CGSize constraints, CFRange *fitRange)
{
    if (!fs)
        return CGSizeZero;
    range = full(fs, range);
    double height = constraints.height >= CGFLOAT_MAX / 2 ? 1e7 : constraints.height;
    double width = constraints.width >= CGFLOAT_MAX / 2 ? 1e7 : constraints.width;
    Layout l = layout(fs->typesetter, range, width, height, true);
    for (CTLineRef line : l.lines)
        CFRelease(line);
    if (fitRange)
        *fitRange = CFRangeMake(range.location, l.end - range.location);
    return CGSizeMake(l.width_needed, ceil(l.height_needed));
}
