/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGPath: paths keep the elements they were built from, as Apple's do, so
 * CGPathApply returns what was added (rects as move + 3 lines + close,
 * arcs as Bézier quarters plus a remainder). Arcs are built on a unit
 * circle and mapped through translate · scale · rotate (· the caller's
 * transform), with exact quarter turns inside an arc, which is how Apple's
 * points come out (checked by finch-cg-test).
 */
#include "CGPathInternal.h"
#include <math.h>
#include <new>

static const CGFloat kappa = 0.5522847498;  /* Apple's quarter-circle constant */

#pragma mark - CF type

static void
path_finalize(CFTypeRef cf)
{
    CGPath *p = (CGPath *)cf;
    delete p->elems;
}

static Boolean
path_equal(CFTypeRef a, CFTypeRef b)
{
    return CGPathEqualToPath((CGPathRef)a, (CGPathRef)b);
}

static CFHashCode
path_hash(CFTypeRef cf)
{
    return ((CGPath *)cf)->elems->size();
}

static CFStringRef
path_desc(CFTypeRef cf)
{
    return CGTypeCopyDescriptionPrefix(cf, "CGPath");
}

static const CGRuntimeClass path_class = {
    0, "CGPath", NULL, NULL, path_finalize, path_equal, path_hash, NULL, path_desc, NULL, NULL, 0,
};
static CFTypeID path_type;

CFTypeID
CGPathGetTypeID(void)
{
    return CGTypeRegister(&path_class, &path_type);
}

static CGPath *
path_new(bool is_mutable)
{
    CGPath *p = (CGPath *)CGTypeCreateInstance(CGPathGetTypeID(), sizeof(CGPath));
    p->elems = new std::vector<CGPathElem>();
    p->is_mutable = is_mutable;
    return p;
}

CGMutablePathRef
CGPathCreateMutable(void)
{
    return (CGMutablePathRef)path_new(true);
}

CGPathRef
CGPathRetain(CGPathRef path)
{
    return path ? (CGPathRef)CFRetain(path) : NULL;
}

void
CGPathRelease(CGPathRef path)
{
    if (path)
        CFRelease(path);
}

#pragma mark - Building

static inline CGPoint
apply(const CGAffineTransform *m, CGFloat x, CGFloat y)
{
    if (!m)
        return CGPointMake(x, y);
    return CGPointMake(m->a * x + m->c * y + m->tx, m->b * x + m->d * y + m->ty);
}

static void
push(CGPath *p, CGPathElementType type, int n, const CGPoint *pts)
{
    CGPathElem e;
    e.type = type;
    for (int i = 0; i < 3; i++)
        e.p[i] = i < n ? pts[i] : CGPointZero;
    p->elems->push_back(e);
    switch (type) {
    case kCGPathElementMoveToPoint:
        p->start = p->current = pts[0];
        p->has_current = true;
        break;
    case kCGPathElementCloseSubpath:
        p->current = p->start;
        break;
    default:
        p->current = pts[n - 1];
        break;
    }
}

void
CGPathMoveToPoint(CGMutablePathRef path, const CGAffineTransform *m, CGFloat x, CGFloat y)
{
    if (!path)
        return;
    CGPoint pt = apply(m, x, y);
    push(path, kCGPathElementMoveToPoint, 1, &pt);
}

void
CGPathAddLineToPoint(CGMutablePathRef path, const CGAffineTransform *m, CGFloat x, CGFloat y)
{
    if (!path || !path->has_current)
        return;
    CGPoint pt = apply(m, x, y);
    push(path, kCGPathElementAddLineToPoint, 1, &pt);
}

void
CGPathAddQuadCurveToPoint(CGMutablePathRef path, const CGAffineTransform *m, CGFloat cpx, CGFloat cpy,
                          CGFloat x, CGFloat y)
{
    if (!path || !path->has_current)
        return;
    CGPoint pts[2] = {apply(m, cpx, cpy), apply(m, x, y)};
    push(path, kCGPathElementAddQuadCurveToPoint, 2, pts);
}

void
CGPathAddCurveToPoint(CGMutablePathRef path, const CGAffineTransform *m, CGFloat cp1x, CGFloat cp1y,
                      CGFloat cp2x, CGFloat cp2y, CGFloat x, CGFloat y)
{
    if (!path || !path->has_current)
        return;
    CGPoint pts[3] = {apply(m, cp1x, cp1y), apply(m, cp2x, cp2y), apply(m, x, y)};
    push(path, kCGPathElementAddCurveToPoint, 3, pts);
}

void
CGPathCloseSubpath(CGMutablePathRef path)
{
    if (!path || !path->has_current)
        return;
    push(path, kCGPathElementCloseSubpath, 0, NULL);
}

void
CGPathAddRect(CGMutablePathRef path, const CGAffineTransform *m, CGRect rect)
{
    if (!path)
        return;
    CGRect r = CGRectStandardize(rect);
    CGFloat x0 = r.origin.x, y0 = r.origin.y, x1 = x0 + r.size.width, y1 = y0 + r.size.height;
    CGPathMoveToPoint(path, m, x0, y0);
    CGPathAddLineToPoint(path, m, x1, y0);
    CGPathAddLineToPoint(path, m, x1, y1);
    CGPathAddLineToPoint(path, m, x0, y1);
    CGPathCloseSubpath(path);
}

void
CGPathAddRects(CGMutablePathRef path, const CGAffineTransform *m, const CGRect *rects, size_t count)
{
    for (size_t i = 0; rects && i < count; i++)
        CGPathAddRect(path, m, rects[i]);
}

void
CGPathAddLines(CGMutablePathRef path, const CGAffineTransform *m, const CGPoint *points, size_t count)
{
    if (!path || !points || !count)
        return;
    CGPathMoveToPoint(path, m, points[0].x, points[0].y);
    for (size_t i = 1; i < count; i++)
        CGPathAddLineToPoint(path, m, points[i].x, points[i].y);
}

/* Rotate a unit-frame point by n exact quarter turns. */
static inline CGPoint
quarter_turn(CGPoint p, int n)
{
    switch (((n % 4) + 4) % 4) {
    case 1: return CGPointMake(-p.y, p.x);
    case 2: return CGPointMake(-p.x, -p.y);
    case 3: return CGPointMake(p.y, -p.x);
    default: return p;
    }
}

static void
curve_unit(CGPath *p, const CGAffineTransform *t, CGPoint c1, CGPoint c2, CGPoint end, int turns)
{
    c1 = quarter_turn(c1, turns);
    c2 = quarter_turn(c2, turns);
    end = quarter_turn(end, turns);
    CGPoint pts[3] = {apply(t, c1.x, c1.y), apply(t, c2.x, c2.y), apply(t, end.x, end.y)};
    push(p, kCGPathElementAddCurveToPoint, 3, pts);
}

/*
 * The unit-circle arc from angle 0 through `delta`, mapped by `t`: a move
 * (or a line, when the path has a current point and `move` is false) to its
 * start, then Bézier quarters and the remainder.
 */
static void
add_unit_arc(CGPath *p, const CGAffineTransform *t, CGFloat delta, bool move)
{
    CGPoint start = apply(t, 1, 0);
    push(p, move || !p->has_current ? kCGPathElementMoveToPoint : kCGPathElementAddLineToPoint, 1, &start);
    if (delta == 0)
        return;
    int sign = delta < 0 ? -1 : 1;
    CGFloat rest = fabs(delta);
    int turns = 0;
    while (rest >= M_PI_2) {
        curve_unit(p, t, CGPointMake(1, sign * kappa), CGPointMake(kappa, sign * 1.0), CGPointMake(0, sign * 1.0),
                   turns);
        rest -= M_PI_2;
        turns += sign;
    }
    if (rest > 0) {
        CGFloat phi = sign * rest;
        CGFloat k = 4.0 / 3.0 * tan(phi / 4);
        CGFloat c = cos(phi), s = sin(phi);
        curve_unit(p, t, CGPointMake(1, k), CGPointMake(c + k * s, s - k * c), CGPointMake(c, s), turns);
    }
}

static CGAffineTransform
arc_transform(const CGAffineTransform *m, CGFloat x, CGFloat y, CGFloat rx, CGFloat ry, CGFloat angle)
{
    CGAffineTransform t = CGAffineTransformMakeTranslation(x, y);
    t = CGAffineTransformScale(t, rx, ry);
    if (angle != 0)
        t = CGAffineTransformRotate(t, angle);
    if (m)
        t = CGAffineTransformConcat(t, *m);
    return t;
}

void
CGPathAddRelativeArc(CGMutablePathRef path, const CGAffineTransform *m, CGFloat x, CGFloat y, CGFloat radius,
                     CGFloat startAngle, CGFloat delta)
{
    if (!path)
        return;
    CGAffineTransform t = arc_transform(m, x, y, radius, radius, startAngle);
    add_unit_arc(path, &t, delta, false);
}

void
CGPathAddArc(CGMutablePathRef path, const CGAffineTransform *m, CGFloat x, CGFloat y, CGFloat radius,
             CGFloat startAngle, CGFloat endAngle, bool clockwise)
{
    if (!path)
        return;
    if (clockwise) {
        while (startAngle < endAngle)
            startAngle += 2 * M_PI;
    } else {
        while (endAngle < startAngle)
            endAngle += 2 * M_PI;
    }
    CGPathAddRelativeArc(path, m, x, y, radius, startAngle, endAngle - startAngle);
}

void
CGPathAddEllipseInRect(CGMutablePathRef path, const CGAffineTransform *m, CGRect rect)
{
    if (!path)
        return;
    CGRect r = CGRectStandardize(rect);
    CGAffineTransform t = arc_transform(m, CGRectGetMidX(r), CGRectGetMidY(r), r.size.width / 2,
                                        r.size.height / 2, 0);
    add_unit_arc(path, &t, 2 * M_PI, true);
    CGPathCloseSubpath(path);
}

void
CGPathAddRoundedRect(CGMutablePathRef path, const CGAffineTransform *m, CGRect rect, CGFloat cw, CGFloat ch)
{
    if (!path)
        return;
    CGRect r = CGRectStandardize(rect);
    if (cw <= 0 || ch <= 0) {
        CGPathAddRect(path, m, r);
        return;
    }
    CGFloat x0 = r.origin.x, y0 = r.origin.y, x1 = x0 + r.size.width, y1 = y0 + r.size.height;
    if (cw > r.size.width / 2)
        cw = r.size.width / 2;
    if (ch > r.size.height / 2)
        ch = r.size.height / 2;
    struct {
        CGFloat lx, ly, cx, cy, angle;
    } corners[4] = {
        {x1, y1 - ch, x1 - cw, y1 - ch, 0},
        {x0 + cw, y1, x0 + cw, y1 - ch, M_PI_2},
        {x0, y0 + ch, x0 + cw, y0 + ch, M_PI},
        {x1 - cw, y0, x1 - cw, y0 + ch, 3 * M_PI_2},
    };
    CGPathMoveToPoint(path, m, x1, CGRectGetMidY(r));
    for (auto &c : corners) {
        CGPathAddLineToPoint(path, m, c.lx, c.ly);
        CGAffineTransform t = arc_transform(m, c.cx, c.cy, cw, ch, c.angle);
        curve_unit(path, &t, CGPointMake(1, kappa), CGPointMake(kappa, 1), CGPointMake(0, 1), 0);
    }
    CGPathCloseSubpath(path);
}

void
CGPathAddArcToPoint(CGMutablePathRef path, const CGAffineTransform *m, CGFloat x1, CGFloat y1, CGFloat x2,
                    CGFloat y2, CGFloat radius)
{
    if (!path || !path->has_current)
        return;
    /* The current point is in path space; the rest is in user space. */
    CGPoint p0 = path->current;
    if (m)
        p0 = CGPointApplyAffineTransform(p0, CGAffineTransformInvert(*m));
    CGFloat ux = p0.x - x1, uy = p0.y - y1, vx = x2 - x1, vy = y2 - y1;
    CGFloat ul = hypot(ux, uy), vl = hypot(vx, vy);
    if (ul == 0 || vl == 0) {
        CGPathAddLineToPoint(path, m, x1, y1);
        return;
    }
    ux /= ul, uy /= ul, vx /= vl, vy /= vl;
    CGFloat cross = ux * vy - uy * vx;
    if (cross == 0) {
        CGPathAddLineToPoint(path, m, x1, y1);
        return;
    }
    CGFloat theta = acos(fmax(-1.0, fmin(1.0, ux * vx + uy * vy)));
    CGFloat d = radius / tan(theta / 2);
    CGFloat tx = x1 + ux * d, ty = y1 + uy * d;
    CGFloat a1, a2, cx, cy;
    bool clockwise;
    if (cross < 0) {
        cx = tx + uy * radius, cy = ty - ux * radius;
        a1 = atan2(ux, -uy);
        a2 = atan2(-vx, vy);
        clockwise = false;
    } else {
        cx = tx - uy * radius, cy = ty + ux * radius;
        a1 = atan2(-ux, uy);
        a2 = atan2(vx, -vy);
        clockwise = true;
    }
    CGPathAddArc(path, m, cx, cy, radius, a1, a2, clockwise);
}

void
CGPathAddPath(CGMutablePathRef path1, const CGAffineTransform *m, CGPathRef path2)
{
    if (!path1 || !path2)
        return;
    std::vector<CGPathElem> elems = *path2->elems;  /* path2 may be path1 */
    for (auto &e : elems) {
        CGPoint pts[3];
        int n = CGPathElemPointCount(e.type);
        for (int i = 0; i < n; i++)
            pts[i] = apply(m, e.p[i].x, e.p[i].y);
        push(path1, e.type, n, pts);
    }
}

#pragma mark - Copies and constructors

static CGPath *
path_copy(CGPathRef path, const CGAffineTransform *m, bool is_mutable)
{
    if (!path)
        return NULL;
    CGPath *p = path_new(is_mutable);
    CGPathAddPath(p, m, path);
    return p;
}

CGPathRef
CGPathCreateCopy(CGPathRef path)
{
    if (path && !path->is_mutable)
        return CGPathRetain(path);
    return path_copy(path, NULL, false);
}

CGPathRef
CGPathCreateCopyByTransformingPath(CGPathRef path, const CGAffineTransform *m)
{
    return path_copy(path, m, false);
}

CGMutablePathRef
CGPathCreateMutableCopy(CGPathRef path)
{
    return path_copy(path, NULL, true);
}

CGMutablePathRef
CGPathCreateMutableCopyByTransformingPath(CGPathRef path, const CGAffineTransform *m)
{
    return path_copy(path, m, true);
}

CGPathRef
CGPathCreateWithRect(CGRect rect, const CGAffineTransform *m)
{
    CGPath *p = path_new(false);
    CGPathAddRect(p, m, rect);
    return p;
}

CGPathRef
CGPathCreateWithEllipseInRect(CGRect rect, const CGAffineTransform *m)
{
    CGPath *p = path_new(false);
    CGPathAddEllipseInRect(p, m, rect);
    return p;
}

CGPathRef
CGPathCreateWithRoundedRect(CGRect rect, CGFloat cw, CGFloat ch, const CGAffineTransform *m)
{
    CGPath *p = path_new(false);
    CGPathAddRoundedRect(p, m, rect, cw, ch);
    return p;
}

#pragma mark - Queries

bool
CGPathEqualToPath(CGPathRef a, CGPathRef b)
{
    if (a == b)
        return true;
    if (!a || !b || a->elems->size() != b->elems->size())
        return false;
    for (size_t i = 0; i < a->elems->size(); i++) {
        const CGPathElem &x = (*a->elems)[i], &y = (*b->elems)[i];
        if (x.type != y.type)
            return false;
        for (int k = 0; k < CGPathElemPointCount(x.type); k++)
            if (x.p[k].x != y.p[k].x || x.p[k].y != y.p[k].y)
                return false;
    }
    return true;
}

bool
CGPathIsEmpty(CGPathRef path)
{
    return !path || path->elems->empty();
}

bool
CGPathIsRect(CGPathRef path, CGRect *rect)
{
    if (!path)
        return false;
    const std::vector<CGPathElem> &e = *path->elems;
    if (e.size() != 5 || e[0].type != kCGPathElementMoveToPoint || e[1].type != kCGPathElementAddLineToPoint ||
        e[2].type != kCGPathElementAddLineToPoint || e[3].type != kCGPathElementAddLineToPoint ||
        e[4].type != kCGPathElementCloseSubpath)
        return false;
    CGPoint a = e[0].p[0], b = e[1].p[0], c = e[2].p[0], d = e[3].p[0];
    bool horizontal_first = a.y == b.y && b.x == c.x && c.y == d.y && d.x == a.x;
    bool vertical_first = a.x == b.x && b.y == c.y && c.x == d.x && d.y == a.y;
    if (!horizontal_first && !vertical_first)
        return false;
    if (rect)
        *rect = CGRectStandardize(CGRectMake(a.x, a.y, c.x - a.x, c.y - a.y));
    return true;
}

CGPoint
CGPathGetCurrentPoint(CGPathRef path)
{
    return path && path->has_current ? path->current : CGPointZero;
}

CGRect
CGPathGetBoundingBox(CGPathRef path)
{
    if (!path || path->elems->empty())
        return CGRectNull;
    CGFloat x0 = INFINITY, y0 = INFINITY, x1 = -INFINITY, y1 = -INFINITY;
    for (auto &e : *path->elems)
        for (int i = 0; i < CGPathElemPointCount(e.type); i++) {
            x0 = fmin(x0, e.p[i].x), x1 = fmax(x1, e.p[i].x);
            y0 = fmin(y0, e.p[i].y), y1 = fmax(y1, e.p[i].y);
        }
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

/* Extend [lo, hi] by a quadratic or cubic Bézier's extrema in one axis. */
static void
quad_extrema(CGFloat p0, CGFloat p1, CGFloat p2, CGFloat *lo, CGFloat *hi)
{
    CGFloat den = p0 - 2 * p1 + p2;
    if (den == 0)
        return;
    CGFloat t = (p0 - p1) / den;
    if (t > 0 && t < 1) {
        CGFloat mt = 1 - t, v = mt * mt * p0 + 2 * mt * t * p1 + t * t * p2;
        *lo = fmin(*lo, v), *hi = fmax(*hi, v);
    }
}

static void
cubic_extrema(CGFloat p0, CGFloat p1, CGFloat p2, CGFloat p3, CGFloat *lo, CGFloat *hi)
{
    /* derivative / 3: a t^2 + b t + c */
    CGFloat a = -p0 + 3 * p1 - 3 * p2 + p3, b = 2 * (p0 - 2 * p1 + p2), c = p1 - p0;
    CGFloat ts[2];
    int n = 0;
    if (fabs(a) < 1e-12) {
        if (b != 0)
            ts[n++] = -c / b;
    } else {
        CGFloat disc = b * b - 4 * a * c;
        if (disc >= 0) {
            CGFloat sq = sqrt(disc);
            ts[n++] = (-b + sq) / (2 * a);
            ts[n++] = (-b - sq) / (2 * a);
        }
    }
    for (int i = 0; i < n; i++) {
        CGFloat t = ts[i];
        if (t > 0 && t < 1) {
            CGFloat mt = 1 - t;
            CGFloat v = mt * mt * mt * p0 + 3 * mt * mt * t * p1 + 3 * mt * t * t * p2 + t * t * t * p3;
            *lo = fmin(*lo, v), *hi = fmax(*hi, v);
        }
    }
}

CGRect
CGPathGetPathBoundingBox(CGPathRef path)
{
    if (!path || path->elems->empty())
        return CGRectNull;
    CGFloat x0 = INFINITY, y0 = INFINITY, x1 = -INFINITY, y1 = -INFINITY;
    CGPoint cur = CGPointZero, start = CGPointZero;
    for (auto &e : *path->elems) {
        int n = CGPathElemPointCount(e.type);
        if (n) {
            CGPoint end = e.p[n - 1];
            x0 = fmin(x0, end.x), x1 = fmax(x1, end.x);
            y0 = fmin(y0, end.y), y1 = fmax(y1, end.y);
        }
        switch (e.type) {
        case kCGPathElementMoveToPoint:
            start = e.p[0];
            break;
        case kCGPathElementAddQuadCurveToPoint:
            quad_extrema(cur.x, e.p[0].x, e.p[1].x, &x0, &x1);
            quad_extrema(cur.y, e.p[0].y, e.p[1].y, &y0, &y1);
            break;
        case kCGPathElementAddCurveToPoint:
            cubic_extrema(cur.x, e.p[0].x, e.p[1].x, e.p[2].x, &x0, &x1);
            cubic_extrema(cur.y, e.p[0].y, e.p[1].y, e.p[2].y, &y0, &y1);
            break;
        default:
            break;
        }
        cur = e.type == kCGPathElementCloseSubpath ? start : e.p[n - 1];
    }
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

void
CGPathApply(CGPathRef path, void *info, CGPathApplierFunction function)
{
    if (!path || !function)
        return;
    std::vector<CGPathElem> elems = *path->elems;
    for (auto &e : elems) {
        CGPathElement el = {e.type, e.p};
        function(info, &el);
    }
}

void
CGPathApplyWithBlock(CGPathRef path, CGPathApplyBlock CF_NOESCAPE block)
{
    if (!path || !block)
        return;
    std::vector<CGPathElem> elems = *path->elems;
    for (auto &e : elems) {
        CGPathElement el = {e.type, e.p};
        block(&el);
    }
}

#pragma mark - Hit testing

/* Flatten the path into closed polygons (one per subpath). */
void
CGPathFlatten(CGPathRef path, const CGAffineTransform *m, CGFloat tolerance,
              std::vector<std::vector<CGPoint>> &out)
{
    out.clear();
    CGPoint cur = CGPointZero;
    auto pt = [&](CGPoint p) { return m ? CGPointApplyAffineTransform(p, *m) : p; };
    for (auto &e : *path->elems) {
        switch (e.type) {
        case kCGPathElementMoveToPoint:
            out.emplace_back();
            cur = pt(e.p[0]);
            out.back().push_back(cur);
            break;
        case kCGPathElementAddLineToPoint:
            cur = pt(e.p[0]);
            out.back().push_back(cur);
            break;
        case kCGPathElementAddQuadCurveToPoint:
        case kCGPathElementAddCurveToPoint: {
            bool quad = e.type == kCGPathElementAddQuadCurveToPoint;
            CGPoint p0 = cur, p1 = pt(e.p[0]), p2 = pt(e.p[1]), p3 = quad ? p2 : pt(e.p[2]);
            CGFloat len = hypot(p1.x - p0.x, p1.y - p0.y) + hypot(p2.x - p1.x, p2.y - p1.y) +
                          (quad ? 0 : hypot(p3.x - p2.x, p3.y - p2.y));
            int steps = (int)fmin(1000, fmax(4, ceil(sqrt(len / tolerance))));
            for (int i = 1; i <= steps; i++) {
                CGFloat t = (CGFloat)i / steps, mt = 1 - t;
                CGPoint q;
                if (quad) {
                    q.x = mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x;
                    q.y = mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y;
                } else {
                    q.x = mt * mt * mt * p0.x + 3 * mt * mt * t * p1.x + 3 * mt * t * t * p2.x + t * t * t * p3.x;
                    q.y = mt * mt * mt * p0.y + 3 * mt * mt * t * p1.y + 3 * mt * t * t * p2.y + t * t * t * p3.y;
                }
                out.back().push_back(q);
            }
            cur = quad ? p2 : p3;
            break;
        }
        case kCGPathElementCloseSubpath:
            cur = out.back().front();
            out.emplace_back();
            out.back().push_back(cur);
            break;
        }
    }
}

bool
CGPathContainsPoint(CGPathRef path, const CGAffineTransform *m, CGPoint point, bool eoFill)
{
    if (!path)
        return false;
    std::vector<std::vector<CGPoint>> polys;
    CGPathFlatten(path, m, 0.001, polys);
    int winding = 0;
    for (auto &poly : polys) {
        size_t n = poly.size();
        if (n < 2)
            continue;
        for (size_t i = 0; i < n; i++) {
            CGPoint a = poly[i], b = poly[(i + 1) % n];
            /* on the edge counts as inside */
            CGFloat dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy;
            if (len2 > 0) {
                CGFloat t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / len2;
                if (t >= 0 && t <= 1) {
                    CGFloat ex = a.x + t * dx - point.x, ey = a.y + t * dy - point.y;
                    if (ex * ex + ey * ey < 1e-18)
                        return true;
                }
            } else if (a.x == point.x && a.y == point.y) {
                return true;
            }
            if (a.y <= point.y) {
                if (b.y > point.y && (dx * (point.y - a.y) - (point.x - a.x) * dy) > 0)
                    winding++;
            } else if (b.y <= point.y && (dx * (point.y - a.y) - (point.x - a.x) * dy) < 0) {
                winding--;
            }
        }
    }
    return eoFill ? (winding & 1) : winding != 0;
}
