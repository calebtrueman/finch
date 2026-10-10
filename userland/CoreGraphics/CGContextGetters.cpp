/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGContext's private getters and composite operations, as Apple's
 * CoreGraphics exports them (AppKit's NSGraphicsContext reads its state
 * through them, so it lives in the CG graphics state and is saved and
 * restored with it).
 *
 * Apple's composite operations number Porter-Duff and blend modes together:
 * 0 clear, 1 copy, 2 source over, 3 source in, 4 source out, 5 source atop,
 * 6 destination over, 7 destination in, 8 destination out, 9 destination
 * atop, 10 XOR, 11 plus darker, 12 plus lighter, then 13 to 27 are
 * kCGBlendModeMultiply to kCGBlendModeLuminosity. Each is one CGBlendMode.
 */
#include "CGContextInternal.h"

extern "C" {
CGBlendMode CGContextGetBlendMode(CGContextRef c);
int CGContextGetCompositeOperation(CGContextRef c);
void CGContextSetCompositeOperation(CGContextRef c, int op);
bool CGContextGetShouldAntialias(CGContextRef c);
bool CGContextGetAllowsAntialiasing(CGContextRef c);
CGColorRenderingIntent CGContextGetRenderingIntent(CGContextRef c);
CGSize CGContextGetPatternPhase(CGContextRef c);
CGFloat CGContextGetAlpha(CGContextRef c);
CGFloat CGContextGetLineWidth(CGContextRef c);
CGFloat CGContextGetFlatness(CGContextRef c);
bool CGContextGetShouldSmoothFonts(CGContextRef c);
bool CGContextGetAllowsFontSmoothing(CGContextRef c);
int CGContextGetFontSmoothingStyle(CGContextRef c);
void CGContextSetFontSmoothingStyle(CGContextRef c, int style);
}

static const int porter_duff_blend[13] = {
    kCGBlendModeClear, kCGBlendModeCopy, kCGBlendModeNormal, kCGBlendModeSourceIn, kCGBlendModeSourceOut,
    kCGBlendModeSourceAtop, kCGBlendModeDestinationOver, kCGBlendModeDestinationIn, kCGBlendModeDestinationOut,
    kCGBlendModeDestinationAtop, kCGBlendModeXOR, kCGBlendModePlusDarker, kCGBlendModePlusLighter,
};

CGBlendMode CGContextGetBlendMode(CGContextRef c) { return c ? CGContextState(c).blend : kCGBlendModeNormal; }

int
CGContextGetCompositeOperation(CGContextRef c)
{
    if (!c)
        return 2;
    int b = CGContextState(c).blend;
    for (int op = 0; op < 13; op++)
        if (porter_duff_blend[op] == b)
            return op;
    return b >= kCGBlendModeMultiply && b <= kCGBlendModeLuminosity ? 12 + b : 2;
}

void
CGContextSetCompositeOperation(CGContextRef c, int op)
{
    if (!c)
        return;
    if (op >= 0 && op < 13)
        CGContextSetBlendMode(c, (CGBlendMode)porter_duff_blend[op]);
    else if (op >= 13 && op <= 27)
        CGContextSetBlendMode(c, (CGBlendMode)(op - 12));
}

bool CGContextGetShouldAntialias(CGContextRef c) { return c ? CGContextState(c).antialias : true; }
bool CGContextGetAllowsAntialiasing(CGContextRef c) { return c ? CGContextState(c).allows_antialias : true; }
CGColorRenderingIntent CGContextGetRenderingIntent(CGContextRef c) { return c ? CGContextState(c).intent : kCGRenderingIntentDefault; }
CGSize CGContextGetPatternPhase(CGContextRef c) { return c ? CGContextState(c).pattern_phase : CGSizeZero; }
CGFloat CGContextGetAlpha(CGContextRef c) { return c ? CGContextState(c).alpha : 1; }
CGFloat CGContextGetLineWidth(CGContextRef c) { return c ? CGContextState(c).line_width : 1; }
CGFloat CGContextGetFlatness(CGContextRef c) { return c ? CGContextState(c).flatness : 0.5; }
bool CGContextGetShouldSmoothFonts(CGContextRef c) { return c ? CGContextState(c).smooth_fonts : true; }
bool CGContextGetAllowsFontSmoothing(CGContextRef c) { return c ? CGContextState(c).allows_smoothing : true; }
int CGContextGetFontSmoothingStyle(CGContextRef c) { return c ? CGContextState(c).font_smoothing_style : 48; }
void CGContextSetFontSmoothingStyle(CGContextRef c, int style) { if (c) CGContextState(c).font_smoothing_style = style; }
