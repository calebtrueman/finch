/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Bridges from CG's types to Skia's: colour spaces, matrices, paths. */
#include "CGSkia.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPathIter.h"
#include <math.h>

sk_sp<SkColorSpace>
CGSkColorSpace(CGColorSpaceRef cs)
{
    if (!cs)
        return SkColorSpace::MakeSRGB();
    CGColorSpaceRef resolved = CGColorSpaceResolveDevice(cs);
    sk_sp<SkColorSpace> out;
    if (resolved->kind == CG_SPACE_MATRIX) {
        const CGTransferFn &t = resolved->trc[0];
        skcms_TransferFunction tf;
        if (t.kind == CG_TF_PQ)
            tf = SkNamedTransferFn::kPQ;
        else if (t.kind == CG_TF_HLG)
            tf = SkNamedTransferFn::kHLG;
        else
            tf = {(float)t.g, (float)t.a, (float)t.b, (float)t.c, (float)t.d, (float)t.e, (float)t.f};
        skcms_Matrix3x3 m;
        if (resolved->model == kCGColorSpaceModelRGB) {
            for (int r = 0; r < 3; r++)
                for (int c = 0; c < 3; c++)
                    m.vals[r][c] = (float)resolved->toXYZ[3 * r + c];
        } else {
            m = SkNamedGamut::kSRGB;  /* gray: neutral pixels stay neutral */
        }
        out = SkColorSpace::MakeRGB(tf, m);
    }
    CFRelease(resolved);
    return out ? out : SkColorSpace::MakeSRGB();
}

SkMatrix
CGSkMatrix(const CGAffineTransform &t)
{
    return SkMatrix::MakeAll((float)t.a, (float)t.c, (float)t.tx, (float)t.b, (float)t.d, (float)t.ty, 0, 0, 1);
}

CGAffineTransform
CGFromSkMatrix(const SkMatrix &m)
{
    return CGAffineTransformMake(m.getScaleX(), m.getSkewY(), m.getSkewX(), m.getScaleY(), m.getTranslateX(),
                                 m.getTranslateY());
}

SkPath
CGSkPath(CGPathRef path, const CGAffineTransform *t, bool evenOdd)
{
    SkPathBuilder b(evenOdd ? SkPathFillType::kEvenOdd : SkPathFillType::kWinding);
    if (!path)
        return b.detach();
    auto pt = [&](CGPoint p) {
        if (t)
            p = CGPointApplyAffineTransform(p, *t);
        return SkPoint::Make((float)p.x, (float)p.y);
    };
    for (auto &e : *path->elems) {
        switch (e.type) {
        case kCGPathElementMoveToPoint: b.moveTo(pt(e.p[0])); break;
        case kCGPathElementAddLineToPoint: b.lineTo(pt(e.p[0])); break;
        case kCGPathElementAddQuadCurveToPoint: b.quadTo(pt(e.p[0]), pt(e.p[1])); break;
        case kCGPathElementAddCurveToPoint: b.cubicTo(pt(e.p[0]), pt(e.p[1]), pt(e.p[2])); break;
        case kCGPathElementCloseSubpath: b.close(); break;
        }
    }
    return b.detach();
}

CGMutablePathRef
CGPathFromSkPath(const SkPath &path)
{
    CGMutablePathRef out = CGPathCreateMutable();
    SkPathIter it = path.iter();
    while (auto rec = it.next()) {
        const SkPoint *p = rec->fPoints.data();
        switch (rec->fVerb) {
        case SkPathVerb::kMove: CGPathMoveToPoint(out, NULL, p[0].fX, p[0].fY); break;
        case SkPathVerb::kLine: CGPathAddLineToPoint(out, NULL, p[1].fX, p[1].fY); break;
        case SkPathVerb::kQuad: CGPathAddQuadCurveToPoint(out, NULL, p[1].fX, p[1].fY, p[2].fX, p[2].fY); break;
        case SkPathVerb::kConic: {
            SkPoint quads[1 + 2 * 8];
            int n = SkPath::ConvertConicToQuads(p[0], p[1], p[2], rec->conicWeight(), quads, 3);
            for (int i = 0; i < n; i++)
                CGPathAddQuadCurveToPoint(out, NULL, quads[1 + 2 * i].fX, quads[1 + 2 * i].fY, quads[2 + 2 * i].fX,
                                          quads[2 + 2 * i].fY);
            break;
        }
        case SkPathVerb::kCubic:
            CGPathAddCurveToPoint(out, NULL, p[1].fX, p[1].fY, p[2].fX, p[2].fY, p[3].fX, p[3].fY);
            break;
        case SkPathVerb::kClose: CGPathCloseSubpath(out); break;
        }
    }
    return out;
}

#pragma mark - Stroked and dashed copies of paths

#include "include/core/SkPaint.h"
#include "include/core/SkPathEffect.h"
#include "include/core/SkPathUtils.h"
#include "include/core/SkStrokeRec.h"
#include "include/effects/SkDashPathEffect.h"
#include <vector>

/* The outline of a path stroked with these settings, as Skia's stroker draws it. */
extern "C" CGPathRef
CGPathCreateCopyByStrokingPath(CGPathRef path, const CGAffineTransform *transform, CGFloat lineWidth, CGLineCap cap,
                               CGLineJoin join, CGFloat miterLimit)
{
    if (!path)
        return NULL;
    SkPaint p;
    p.setStyle(SkPaint::kStroke_Style);
    p.setStrokeWidth((float)lineWidth);
    p.setStrokeCap(cap == kCGLineCapRound ? SkPaint::kRound_Cap : cap == kCGLineCapSquare ? SkPaint::kSquare_Cap : SkPaint::kButt_Cap);
    p.setStrokeJoin(join == kCGLineJoinRound ? SkPaint::kRound_Join : join == kCGLineJoinBevel ? SkPaint::kBevel_Join : SkPaint::kMiter_Join);
    p.setStrokeMiter((float)miterLimit);
    SkPath outline = skpathutils::FillPathWithPaint(CGSkPath(path, transform, false), p);
    return CGPathFromSkPath(outline);
}

/* The path cut into dashes (lengths alternate on and off, starting `phase` in). */
extern "C" CGPathRef
CGPathCreateCopyByDashingPath(CGPathRef path, const CGAffineTransform *transform, CGFloat phase, const CGFloat *lengths,
                              size_t count)
{
    if (!path)
        return NULL;
    SkPath src = CGSkPath(path, transform, false);
    if (!lengths || count == 0)
        return CGPathFromSkPath(src);
    std::vector<float> intervals;
    for (size_t i = 0; i < count; i++)
        intervals.push_back((float)lengths[i]);
    if (intervals.size() % 2)   /* an odd count repeats, as CG's does */
        intervals.insert(intervals.end(), intervals.begin(), intervals.end());
    sk_sp<SkPathEffect> dash = SkDashPathEffect::Make(intervals, (float)phase);
    SkPaint p;
    p.setStyle(SkPaint::kStroke_Style);
    p.setPathEffect(dash);
    SkPath out = skpathutils::FillPathWithPaint(src, p);
    /* FillPathWithPaint strokes; only the dash is wanted: apply the effect alone */
    SkPathBuilder b;
    SkStrokeRec rec(SkStrokeRec::kHairline_InitStyle);
    if (dash && dash->filterPath(&b, src, &rec))
        out = b.detach();
    return CGPathFromSkPath(out);
}
