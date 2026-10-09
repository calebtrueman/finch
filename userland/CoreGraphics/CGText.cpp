/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Drawing glyphs: outlines from the font (unhinted, as Apple's are) placed
 * by the text matrix and painted as a path, so every text drawing mode,
 * clip, pattern and shadow works as it does for paths. Colour glyphs
 * (emoji) are drawn by Skia from the font's colour tables, for CoreText.
 */
#include "CGContextInternal.h"
#include "CGFontInternal.h"
#include "CGSkia.h"
#include "CGPDFInternal.h"
#include "include/core/SkFont.h"
#include "include/core/SkColorFilter.h"
#include "include/core/SkPaint.h"
#include <pthread.h>
#include <math.h>
#include <ft2build.h>
#include FT_FREETYPE_H

/* The glyphs' outlines, placed at `positions` in text space, as a path in user space. */
static CGMutablePathRef
glyph_path(CGContextRef c, const CGGlyph *glyphs, const CGPoint *positions, size_t count)
{
    CGGState &g = CGContextState(c);
    CGMutablePathRef out = CGPathCreateMutable();
    sk_sp<SkTypeface> tf = g.font ? CGFontGetTypeface(g.font) : nullptr;
    if (!tf || g.font_size == 0)
        return out;
    /* outlines at 1 unit = 1 em, scaled by the font size through the transform */
    const float em = 64;
    SkFont font(tf, em);
    font.setHinting(SkFontHinting::kNone);
    font.setLinearMetrics(true);
    font.setSubpixel(true);
    bool color = FT_HAS_COLOR((FT_Face)g.font->face);
    for (size_t i = 0; i < count; i++) {
        std::optional<SkPath> outline = font.getPath(glyphs[i]);
        CGPathRef p;
        CGFloat sx, sy;
        if (outline && !outline->isEmpty()) {
            p = CGPathFromSkPath(*outline);
            sx = g.font_size / em, sy = -sx;  /* Skia's glyph space is y down, in em units */
        } else if (color && (p = CGFontCopyGlyphOutline(g.font, glyphs[i]))) {
            sx = sy = g.font_size / CGFontGetUnitsPerEm(g.font);  /* font units, y up */
        } else {
            continue;
        }
        /* glyph space -> text space -> user space */
        CGAffineTransform t = CGAffineTransformMake(sx, 0, 0, sy, positions[i].x, positions[i].y);
        t = CGAffineTransformConcat(t, c->text_matrix);
        t.tx = c->text_matrix.a * positions[i].x + c->text_matrix.c * positions[i].y + c->text_matrix.tx;
        t.ty = c->text_matrix.b * positions[i].x + c->text_matrix.d * positions[i].y + c->text_matrix.ty;
        CGPathAddPath(out, &t, p);
        CFRelease(p);
    }
    return out;
}

/*
 * Font smoothing: Apple's CG darkens the glyphs it fills unless smoothing
 * is off. Raising coverage to the power 0.72 matches it closely (measured
 * against Apple's at 8 to 72 points).
 */
static const double smoothing_gamma = 0.72;

static bool
clips(CGTextDrawingMode mode)
{
    return mode == kCGTextFillClip || mode == kCGTextStrokeClip || mode == kCGTextFillStrokeClip || mode == kCGTextClip;
}

/* Paint glyph outlines in the text drawing mode; `clip_path` (all the glyphs shown) for the clipping modes. */
static void
paint_outlines(CGContextRef c, CGPathRef path, CGPathRef clip_path)
{
    CGTextDrawingMode mode = CGContextState(c).text_mode;
    bool layer = false;
    if ((mode == kCGTextFill || mode == kCGTextFillClip) && c->canvas && c->type != CG_CONTEXT_PDF &&
        CGContextState(c).smooth_fonts &&
        CGContextState(c).allows_smoothing && !CGPathIsEmpty(path)) {
        static uint8_t table[256];
        static pthread_once_t once = PTHREAD_ONCE_INIT;
        pthread_once(&once, [] {
            for (int i = 0; i < 256; i++)
                table[i] = (uint8_t)lround(255 * pow(i / 255.0, smoothing_gamma));
        });
        SkPaint lp;
        lp.setColorFilter(SkColorFilters::TableARGB(table, nullptr, nullptr, nullptr));
        /* the layer covers the glyphs only, unless a shadow falls outside them (a page-sized one per string is slow) */
        CGRect box = CGRectApplyAffineTransform(CGPathGetBoundingBox(path), CGContextUserToDevice(c));
        SkRect bounds = SkRect::MakeXYWH((float)box.origin.x, (float)box.origin.y, (float)box.size.width,
                                         (float)box.size.height).makeOutset(2, 2);
        c->canvas->save();
        c->canvas->resetMatrix();
        bool shadow = CGContextState(c).shadow_color && CGColorGetAlpha(CGContextState(c).shadow_color) > 0;
        c->canvas->saveLayer(CGRectIsNull(box) || shadow ? nullptr : &bounds, &lp);
        layer = true;
    }
    switch (mode) {
    case kCGTextFill:
    case kCGTextFillClip: CGContextDrawUserPath(c, path, kCGPathFill); break;
    case kCGTextStroke:
    case kCGTextStrokeClip: CGContextDrawUserPath(c, path, kCGPathStroke); break;
    case kCGTextFillStroke:
    case kCGTextFillStrokeClip: CGContextDrawUserPath(c, path, kCGPathFillStroke); break;
    case kCGTextInvisible:
    case kCGTextClip: break;
    }
    if (layer) {
        c->canvas->restore();
        c->canvas->restore();
    }
    /* after the smoothing layer, which would take the clip with it */
    if (clips(mode))
        CGContextClipToUserPath(c, clip_path, false);
}

static bool
any_color(CGFontRef font, const CGGlyph *glyphs, size_t count)
{
    for (size_t i = 0; font && i < count; i++)
        if (CGFontGlyphIsColor(font, glyphs[i]))
            return true;
    return false;
}

/*
 * Draw glyphs. Glyphs with colour forms (emoji) are drawn in colour only
 * when `color` is set, as CoreText does (Finch's CoreText calls
 * CGContextFinchShowGlyphsWithColor), and then their outlines are only
 * clipped to. Apple's CGContextShowGlyphs* draws every glyph as its
 * outline, so emoji in bitmap fonts draw nothing there and COLR glyphs
 * draw their base glyph in the fill colour; Finch's do the same.
 */
static void
show(CGContextRef c, const CGGlyph *glyphs, const CGPoint *positions, size_t count, bool color)
{
    if (!c || !glyphs || !positions || !count)
        return;
    CGGState &g = CGContextState(c);
    /* split off the colour glyphs: CoreText draws them whatever the text mode, but not with a clear fill */
    std::vector<CGGlyph> ink_glyphs;
    std::vector<CGPoint> ink_positions;
    std::vector<SkGlyphID> color_glyphs;
    std::vector<SkPoint> color_positions;
    if (color && g.font && g.font_size != 0) {
        for (size_t i = 0; i < count; i++) {
            if (!CGFontGlyphIsColor(g.font, glyphs[i])) {
                ink_glyphs.push_back(glyphs[i]);
                ink_positions.push_back(positions[i]);
            } else {
                /* Skia's glyph space is y down */
                color_glyphs.push_back(glyphs[i]);
                color_positions.push_back(SkPoint::Make((float)positions[i].x, (float)-positions[i].y));
            }
        }
    }
    bool split = color && ink_glyphs.size() != count;
    if (!color_glyphs.empty() && !(g.fill && CGColorGetAlpha(g.fill) == 0)) {
        sk_sp<SkTypeface> tf = CGFontGetTypeface(g.font);
        CGAffineTransform flip = CGAffineTransformMake(1, 0, 0, -1, 0, 0);
        CGAffineTransform m = CGAffineTransformConcat(CGAffineTransformConcat(flip, c->text_matrix), CGContextUserToDevice(c));
        if (tf && m.a * m.d - m.b * m.c != 0) {
            SkFont font(tf, (float)g.font_size);
            font.setHinting(SkFontHinting::kNone);
            font.setLinearMetrics(true);
            font.setSubpixel(true);
            font.setEdging(SkFont::Edging::kAntiAlias);
            CGContextDrawColorGlyphs(c, font, color_glyphs.data(), color_positions.data(), color_glyphs.size(),
                                     CGSkMatrix(m));
        }
    }
    if (split && ink_glyphs.empty() && !clips(g.text_mode))
        return;
    const CGGlyph *ig = split ? ink_glyphs.data() : glyphs;
    const CGPoint *ip = split ? ink_positions.data() : positions;
    size_t in = split ? ink_glyphs.size() : count;
    if (c->type == CG_CONTEXT_PDF && in && !(!color && any_color(g.font, ig, in)) && CGPDFContextShowGlyphs(c, ig, ip, in))
        return;  /* PDF text (Skia's PDF text would draw colour glyphs in colour) */
    CGMutablePathRef path = glyph_path(c, ig, ip, in);
    CGMutablePathRef all = split && clips(g.text_mode) ? glyph_path(c, glyphs, positions, count) : NULL;
    paint_outlines(c, path, all ? all : path);
    if (all)
        CFRelease(all);
    CFRelease(path);
}

/*
 * Finch's own (not Apple's API), for CoreText: CGContextShowGlyphsAtPositions,
 * with glyphs that have colour forms drawn in colour, ignoring the fill
 * colour, as Apple's CoreText draws emoji.
 */
extern "C" void CGContextFinchShowGlyphsWithColor(CGContextRef c, const CGGlyph *glyphs, const CGPoint *positions,
                                                  size_t count);

void
CGContextFinchShowGlyphsWithColor(CGContextRef c, const CGGlyph *glyphs, const CGPoint *positions, size_t count)
{
    show(c, glyphs, positions, count, true);
}

void
CGContextShowGlyphsAtPositions(CGContextRef c, const CGGlyph *glyphs, const CGPoint *positions, size_t count)
{
    show(c, glyphs, positions, count, false);
}

/* Glyphs from the text position, each advanced by its width plus the character spacing; the position moves on. */
static void
show_advancing(CGContextRef c, const CGGlyph *glyphs, const CGSize *advances, size_t count)
{
    if (!c || !glyphs || !count)
        return;
    CGGState &g = CGContextState(c);
    std::vector<CGPoint> pos(count);
    std::vector<int> units(count);
    if (!advances && g.font)
        CGFontGetGlyphAdvances(g.font, glyphs, count, units.data());
    /* positions are relative to the text position, in text space */
    CGPoint start = CGPointMake(c->text_matrix.tx, c->text_matrix.ty);
    CGAffineTransform saved = c->text_matrix;
    CGFloat x = 0, y = 0;
    int upem = g.font ? CGFontGetUnitsPerEm(g.font) : 1000;
    for (size_t i = 0; i < count; i++) {
        pos[i] = CGPointMake(x, y);
        if (advances) {
            x += advances[i].width, y += advances[i].height;
        } else {
            x += units[i] * g.font_size / upem + g.char_spacing;
        }
    }
    show(c, glyphs, pos.data(), count, false);
    c->text_matrix = saved;
    CGPoint end = CGPointApplyAffineTransform(CGPointMake(x, y), CGAffineTransformMake(saved.a, saved.b, saved.c, saved.d, 0, 0));
    c->text_matrix.tx = start.x + end.x;
    c->text_matrix.ty = start.y + end.y;
}

void CGContextShowGlyphs(CGContextRef c, const CGGlyph *g, size_t count) { show_advancing(c, g, NULL, count); }

void
CGContextShowGlyphsAtPoint(CGContextRef c, CGFloat x, CGFloat y, const CGGlyph *g, size_t count)
{
    CGContextSetTextPosition(c, x, y);
    show_advancing(c, g, NULL, count);
}

void
CGContextShowGlyphsWithAdvances(CGContextRef c, const CGGlyph *g, const CGSize *advances, size_t count)
{
    show_advancing(c, g, advances, count);
}

/* The deprecated MacRoman text calls: the font chosen by name, characters through its cmap. */
void
CGContextSelectFont(CGContextRef c, const char *name, CGFloat size, CGTextEncoding encoding)
{
    if (!c || !name)
        return;
    CFStringRef n = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    CGFontRef f = CGFontCreateWithFontName(n);
    CFRelease(n);
    if (f) {
        CGContextSetFont(c, f);
        CFRelease(f);
    }
    CGContextSetFontSize(c, size);
}

void
CGContextShowText(CGContextRef c, const char *string, size_t length)
{
    if (!c || !string || !CGContextState(c).font)
        return;
    FT_Face face = (FT_Face)CGContextState(c).font->face;
    CFStringRef s = CFStringCreateWithBytes(NULL, (const UInt8 *)string, (CFIndex)length, kCFStringEncodingMacRoman, false);
    std::vector<CGGlyph> glyphs;
    for (CFIndex i = 0; s && i < CFStringGetLength(s); i++)
        glyphs.push_back((CGGlyph)FT_Get_Char_Index(face, CFStringGetCharacterAtIndex(s, i)));
    if (s)
        CFRelease(s);
    show_advancing(c, glyphs.data(), NULL, glyphs.size());
}

void
CGContextShowTextAtPoint(CGContextRef c, CGFloat x, CGFloat y, const char *string, size_t length)
{
    CGContextSetTextPosition(c, x, y);
    CGContextShowText(c, string, length);
}
