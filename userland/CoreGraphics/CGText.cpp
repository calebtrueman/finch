/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Drawing glyphs: outlines from the font (unhinted, as Apple's are) placed
 * by the text matrix and painted as a path, so every text drawing mode,
 * clip, pattern and shadow works as it does for paths.
 */
#include "CGContextInternal.h"
#include "CGFontInternal.h"
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
    for (size_t i = 0; i < count; i++) {
        std::optional<SkPath> outline = font.getPath(glyphs[i]);
        if (!outline || outline->isEmpty())
            continue;
        CGMutablePathRef p = CGPathFromSkPath(*outline);
        /* glyph space (y down, em units) -> text space -> user space */
        CGFloat s = g.font_size / em;
        CGAffineTransform t = CGAffineTransformMake(s, 0, 0, -s, positions[i].x, positions[i].y);
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

static void
show(CGContextRef c, const CGGlyph *glyphs, const CGPoint *positions, size_t count)
{
    if (!c || !glyphs || !positions || !count)
        return;
    CGMutablePathRef path = glyph_path(c, glyphs, positions, count);
    CGTextDrawingMode mode = CGContextState(c).text_mode;
    bool layer = false;
    if ((mode == kCGTextFill || mode == kCGTextFillClip) && c->canvas && CGContextState(c).smooth_fonts &&
        CGContextState(c).allows_smoothing) {
        static uint8_t table[256];
        static pthread_once_t once = PTHREAD_ONCE_INIT;
        pthread_once(&once, [] {
            for (int i = 0; i < 256; i++)
                table[i] = (uint8_t)lround(255 * pow(i / 255.0, smoothing_gamma));
        });
        SkPaint lp;
        lp.setColorFilter(SkColorFilters::TableARGB(table, nullptr, nullptr, nullptr));
        c->canvas->save();
        c->canvas->resetMatrix();
        c->canvas->saveLayer(nullptr, &lp);
        layer = true;
    }
    switch (CGContextState(c).text_mode) {
    case kCGTextFill: CGContextDrawUserPath(c, path, kCGPathFill); break;
    case kCGTextStroke: CGContextDrawUserPath(c, path, kCGPathStroke); break;
    case kCGTextFillStroke: CGContextDrawUserPath(c, path, kCGPathFillStroke); break;
    case kCGTextInvisible: break;
    case kCGTextFillClip:
        CGContextDrawUserPath(c, path, kCGPathFill);
        CGContextClipToUserPath(c, path, false);
        break;
    case kCGTextStrokeClip:
        CGContextDrawUserPath(c, path, kCGPathStroke);
        CGContextClipToUserPath(c, path, false);
        break;
    case kCGTextFillStrokeClip:
        CGContextDrawUserPath(c, path, kCGPathFillStroke);
        CGContextClipToUserPath(c, path, false);
        break;
    case kCGTextClip: CGContextClipToUserPath(c, path, false); break;
    }
    if (layer) {
        c->canvas->restore();
        c->canvas->restore();
    }
    CFRelease(path);
}

void
CGContextShowGlyphsAtPositions(CGContextRef c, const CGGlyph *glyphs, const CGPoint *positions, size_t count)
{
    show(c, glyphs, positions, count);
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
    show(c, glyphs, pos.data(), count);
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
