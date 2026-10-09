/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSBezierPath: path elements with their line attributes, drawn through
 * CoreGraphics. Element generation matches Apple's (measured on the host):
 *
 * - -closePath appends a close and a move back to the subpath's start; the
 *   rect constructors close without the move; ovals don't close.
 * - Arcs are cubic segments of at most 90 degrees from the start angle,
 *   stepped in radians (so a sweep that doesn't come out even ends in a
 *   degenerate segment, as Apple's does), each with k = 4/3 tan(angle/4).
 * - Ovals are four such segments starting at -45 degrees; rounded rects use
 *   k = 0.55228 and start at the top of the left edge's corner.
 * - Flattening splits each curve into 2^n equal steps of t, the fewest for
 *   which 3/4 of its largest second difference over n^2 is within the class's
 *   default flatness.
 */
#import "AppKitDrawing.h"
#import <CoreText/CoreText.h>
#include <math.h>

typedef struct {
    NSBezierPathElement type;
    NSPoint p[3];
} Element;

static CGFloat default_line_width = 1, default_miter = 10, default_flatness = 0.6;
static NSLineCapStyle default_cap = NSLineCapStyleButt;
static NSLineJoinStyle default_join = NSLineJoinStyleMiter;
static NSWindingRule default_winding = NSWindingRuleNonZero;

static int
npoints(NSBezierPathElement t)
{
    switch (t) {
    case NSBezierPathElementCurveTo: return 3;
    case NSBezierPathElementClosePath: return 1;  /* the subpath's start, as Apple's archives keep it */
    case NSBezierPathElementQuadraticCurveTo: return 2;
    default: return 1;
    }
}

@implementation NSBezierPath {
    Element *_e;
    NSInteger _count, _cap;
    CGFloat _lineWidth, _miterLimit, _flatness;
    NSLineCapStyle _lineCap;
    NSLineJoinStyle _lineJoin;
    NSWindingRule _winding;
    CGFloat *_dash;
    NSInteger _dashCount;
    CGFloat _dashPhase;
    BOOL _cachesBezierPath;
    BOOL _boundsAreControlBounds;  /* made from a CGPath, as Apple reports */
}

+ (NSBezierPath *)bezierPath { return [[[self alloc] init] autorelease]; }

- (instancetype)init
{
    if ((self = [super init])) {
        _lineWidth = default_line_width;
        _miterLimit = default_miter;
        _flatness = default_flatness;
        _lineCap = default_cap;
        _lineJoin = default_join;
        _winding = default_winding;
    }
    return self;
}

- (void)dealloc
{
    free(_e);
    free(_dash);
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSBezierPath *p = [[NSBezierPath allocWithZone:zone] init];
    p->_e = malloc(sizeof(Element) * (size_t)(_count ? _count : 1));
    memcpy(p->_e, _e, sizeof(Element) * (size_t)_count);
    p->_count = p->_cap = _count;
    p->_lineWidth = _lineWidth, p->_miterLimit = _miterLimit, p->_flatness = _flatness;
    p->_lineCap = _lineCap, p->_lineJoin = _lineJoin, p->_winding = _winding;
    [p setLineDash:_dash count:_dashCount phase:_dashPhase];
    p->_boundsAreControlBounds = _boundsAreControlBounds;
    return p;
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSBezierPath class]])
        return NO;
    NSBezierPath *o = other;
    if (o->_count != _count)
        return NO;
    for (NSInteger i = 0; i < _count; i++) {
        if (_e[i].type != o->_e[i].type)
            return NO;
        for (int k = 0; k < npoints(_e[i].type); k++)
            if (!NSEqualPoints(_e[i].p[k], o->_e[i].p[k]))
                return NO;
    }
    return YES;
}

- (NSUInteger)hash { return (NSUInteger)_count; }

/* MARK: Elements */

- (void)_append:(NSBezierPathElement)type p0:(NSPoint)a p1:(NSPoint)b p2:(NSPoint)c
{
    if (_count == _cap) {
        _cap = _cap ? _cap * 2 : 8;
        _e = realloc(_e, sizeof(Element) * (size_t)_cap);
    }
    _e[_count].type = type;
    _e[_count].p[0] = a, _e[_count].p[1] = b, _e[_count].p[2] = c;
    _count++;
    _boundsAreControlBounds = NO;
}

/* The start of the subpath the path ends in. */
- (BOOL)_subpathStart:(NSPoint *)out
{
    for (NSInteger i = _count - 1; i >= 0; i--)
        if (_e[i].type == NSBezierPathElementMoveTo) {
            *out = _e[i].p[0];
            return YES;
        }
    return NO;
}

- (BOOL)_currentPoint:(NSPoint *)out
{
    if (!_count)
        return NO;
    Element *e = &_e[_count - 1];
    switch (e->type) {
    case NSBezierPathElementCurveTo: *out = e->p[2]; break;
    case NSBezierPathElementQuadraticCurveTo: *out = e->p[1]; break;
    default: *out = e->p[0]; break;
    }
    return YES;
}

- (void)moveToPoint:(NSPoint)point
{
    if (_count && _e[_count - 1].type == NSBezierPathElementMoveTo) {
        _e[_count - 1].p[0] = point;
        _boundsAreControlBounds = NO;
        return;
    }
    [self _append:NSBezierPathElementMoveTo p0:point p1:NSZeroPoint p2:NSZeroPoint];
}

- (void)lineToPoint:(NSPoint)point
{
    if (!_count)
        FinchDrawRaise(NSGenericException, @"No current point for line");
    [self _append:NSBezierPathElementLineTo p0:point p1:NSZeroPoint p2:NSZeroPoint];
}

- (void)curveToPoint:(NSPoint)endPoint controlPoint1:(NSPoint)controlPoint1 controlPoint2:(NSPoint)controlPoint2
{
    if (!_count)
        FinchDrawRaise(NSGenericException, @"No current point for curve");
    [self _append:NSBezierPathElementCurveTo p0:controlPoint1 p1:controlPoint2 p2:endPoint];
}

- (void)curveToPoint:(NSPoint)endPoint controlPoint:(NSPoint)controlPoint
{
    if (!_count)
        FinchDrawRaise(NSGenericException, @"No current point for curve");
    [self _append:NSBezierPathElementQuadraticCurveTo p0:controlPoint p1:endPoint p2:NSZeroPoint];
}

- (void)_closeWithMove:(BOOL)move
{
    NSPoint start = NSZeroPoint;
    BOOL has = [self _subpathStart:&start];
    if (_count && _e[_count - 1].type == NSBezierPathElementClosePath)
        has = NO;
    [self _append:NSBezierPathElementClosePath p0:start p1:NSZeroPoint p2:NSZeroPoint];
    if (move && has)
        [self _append:NSBezierPathElementMoveTo p0:start p1:NSZeroPoint p2:NSZeroPoint];
}

- (void)closePath { [self _closeWithMove:YES]; }

- (void)relativeMoveToPoint:(NSPoint)point
{
    NSPoint c;
    if (![self _currentPoint:&c])
        FinchDrawRaise(NSGenericException, @"No current point for line");
    [self moveToPoint:NSMakePoint(c.x + point.x, c.y + point.y)];
}

- (void)relativeLineToPoint:(NSPoint)point
{
    NSPoint c;
    if (![self _currentPoint:&c])
        FinchDrawRaise(NSGenericException, @"No current point for line");
    [self lineToPoint:NSMakePoint(c.x + point.x, c.y + point.y)];
}

- (void)relativeCurveToPoint:(NSPoint)endPoint controlPoint1:(NSPoint)controlPoint1 controlPoint2:(NSPoint)controlPoint2
{
    NSPoint c;
    if (![self _currentPoint:&c])
        FinchDrawRaise(NSGenericException, @"No current point for curve");
    [self curveToPoint:NSMakePoint(c.x + endPoint.x, c.y + endPoint.y)
         controlPoint1:NSMakePoint(c.x + controlPoint1.x, c.y + controlPoint1.y)
         controlPoint2:NSMakePoint(c.x + controlPoint2.x, c.y + controlPoint2.y)];
}

- (void)relativeCurveToPoint:(NSPoint)endPoint controlPoint:(NSPoint)controlPoint
{
    NSPoint c;
    if (![self _currentPoint:&c])
        FinchDrawRaise(NSGenericException, @"No current point for curve");
    [self curveToPoint:NSMakePoint(c.x + endPoint.x, c.y + endPoint.y)
          controlPoint:NSMakePoint(c.x + controlPoint.x, c.y + controlPoint.y)];
}

- (void)removeAllPoints
{
    _count = 0;
    _boundsAreControlBounds = NO;
}

- (NSInteger)elementCount { return _count; }

- (NSBezierPathElement)elementAtIndex:(NSInteger)index associatedPoints:(NSPointArray)points
{
    if (index < 0 || index >= _count)
        FinchDrawRaise(NSRangeException, @"elementAtIndex:associatedPoints:: index (%ld) beyond bounds (%ld)", (long)index,
                       (long)_count);
    if (points)
        for (int k = 0; k < npoints(_e[index].type); k++)
            points[k] = _e[index].p[k];
    return _e[index].type;
}

- (NSBezierPathElement)elementAtIndex:(NSInteger)index
{
    return [self elementAtIndex:index associatedPoints:NULL];
}

- (void)setAssociatedPoints:(NSPointArray)points atIndex:(NSInteger)index
{
    if (index < 0 || index >= _count)
        FinchDrawRaise(NSRangeException, @"setAssociatedPoints:atIndex:: index (%ld) beyond bounds (%ld)", (long)index, (long)_count);
    if (_e[index].type == NSBezierPathElementClosePath)
        return;
    for (int k = 0; k < npoints(_e[index].type); k++)
        _e[index].p[k] = points[k];
    _boundsAreControlBounds = NO;
}

- (BOOL)isEmpty { return _count == 0; }

- (NSPoint)currentPoint
{
    NSPoint c;
    if (![self _currentPoint:&c])
        FinchDrawRaise(NSGenericException, @"No current point for line");
    return c;
}

/* MARK: Shapes */

+ (NSBezierPath *)bezierPathWithRect:(NSRect)rect
{
    NSBezierPath *p = [self bezierPath];
    [p appendBezierPathWithRect:rect];
    return p;
}

+ (NSBezierPath *)bezierPathWithOvalInRect:(NSRect)rect
{
    NSBezierPath *p = [self bezierPath];
    [p appendBezierPathWithOvalInRect:rect];
    return p;
}

+ (NSBezierPath *)bezierPathWithRoundedRect:(NSRect)rect xRadius:(CGFloat)xRadius yRadius:(CGFloat)yRadius
{
    NSBezierPath *p = [self bezierPath];
    [p appendBezierPathWithRoundedRect:rect xRadius:xRadius yRadius:yRadius];
    return p;
}

- (void)appendBezierPathWithRect:(NSRect)rect
{
    [self moveToPoint:rect.origin];
    [self lineToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
    [self lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect))];
    [self lineToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect))];
    [self _closeWithMove:NO];
}

/* One cubic for the arc from a to b (radians) of an ellipse with radii rx, ry. */
- (void)_arcSegmentCenter:(NSPoint)c rx:(CGFloat)rx ry:(CGFloat)ry from:(double)a to:(double)b
{
    double k = 4.0 / 3.0 * tan((b - a) / 4);
    double ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b);
    [self curveToPoint:NSMakePoint(c.x + rx * cb, c.y + ry * sb)
         controlPoint1:NSMakePoint(c.x + rx * (ca - k * sa), c.y + ry * (sa + k * ca))
         controlPoint2:NSMakePoint(c.x + rx * (cb + k * sb), c.y + ry * (sb - k * cb))];
}

- (void)appendBezierPathWithOvalInRect:(NSRect)rect
{
    NSPoint c = NSMakePoint(NSMidX(rect), NSMidY(rect));
    CGFloat rx = rect.size.width / 2, ry = rect.size.height / 2;
    double a = -M_PI / 4;
    [self moveToPoint:NSMakePoint(c.x + rx * cos(a), c.y + ry * sin(a))];
    for (int i = 0; i < 4; i++, a += M_PI / 2)
        [self _arcSegmentCenter:c rx:rx ry:ry from:a to:a + M_PI / 2];
}

- (void)appendBezierPathWithRoundedRect:(NSRect)rect xRadius:(CGFloat)xRadius yRadius:(CGFloat)yRadius
{
    rect = NSRectFromCGRect(CGRectStandardize(NSRectToCGRect(rect)));
    CGFloat rx = fmin(xRadius, rect.size.width / 2), ry = fmin(yRadius, rect.size.height / 2);
    if (rx <= 0 || ry <= 0) {
        [self appendBezierPathWithRect:rect];
        [self moveToPoint:rect.origin];
        return;
    }
    const CGFloat k = 0.55228, kx = rx * k, ky = ry * k;
    CGFloat x0 = NSMinX(rect), x1 = NSMaxX(rect), y0 = NSMinY(rect), y1 = NSMaxY(rect);
    [self moveToPoint:NSMakePoint(x0 + rx, y1)];
    [self curveToPoint:NSMakePoint(x0, y1 - ry) controlPoint1:NSMakePoint(x0 + rx - kx, y1) controlPoint2:NSMakePoint(x0, y1 - ry + ky)];
    [self lineToPoint:NSMakePoint(x0, y0 + ry)];
    [self curveToPoint:NSMakePoint(x0 + rx, y0) controlPoint1:NSMakePoint(x0, y0 + ry - ky) controlPoint2:NSMakePoint(x0 + rx - kx, y0)];
    [self lineToPoint:NSMakePoint(x1 - rx, y0)];
    [self curveToPoint:NSMakePoint(x1, y0 + ry) controlPoint1:NSMakePoint(x1 - rx + kx, y0) controlPoint2:NSMakePoint(x1, y0 + ry - ky)];
    [self lineToPoint:NSMakePoint(x1, y1 - ry)];
    [self curveToPoint:NSMakePoint(x1 - rx, y1) controlPoint1:NSMakePoint(x1, y1 - ry + ky) controlPoint2:NSMakePoint(x1 - rx + kx, y1)];
    [self closePath];
}

- (void)appendBezierPathWithArcWithCenter:(NSPoint)center radius:(CGFloat)radius startAngle:(CGFloat)startAngle
                                 endAngle:(CGFloat)endAngle clockwise:(BOOL)clockwise
{
    if (clockwise)
        while (endAngle > startAngle)
            endAngle -= 360;
    else
        while (endAngle < startAngle)
            endAngle += 360;
    double s = startAngle * M_PI / 180, e = endAngle * M_PI / 180;
    NSPoint start = NSMakePoint(center.x + radius * cos(s), center.y + radius * sin(s));
    if (_count)
        [self lineToPoint:start];
    else
        [self moveToPoint:start];
    double a = s;
    if (!clockwise)
        while (a < e) {
            double b = fmin(a + M_PI / 2, e);
            [self _arcSegmentCenter:center rx:radius ry:radius from:a to:b];
            a = b;
        }
    else
        while (a > e) {
            double b = fmax(a - M_PI / 2, e);
            [self _arcSegmentCenter:center rx:radius ry:radius from:a to:b];
            a = b;
        }
}

- (void)appendBezierPathWithArcWithCenter:(NSPoint)center radius:(CGFloat)radius startAngle:(CGFloat)startAngle endAngle:(CGFloat)endAngle
{
    [self appendBezierPathWithArcWithCenter:center radius:radius startAngle:startAngle endAngle:endAngle clockwise:NO];
}

/* The arc tangent to the lines from the current point to point1 and from point1 to point2 (CGPathAddArcToPoint's). */
- (void)appendBezierPathWithArcFromPoint:(NSPoint)point1 toPoint:(NSPoint)point2 radius:(CGFloat)radius
{
    NSPoint p0;
    if (![self _currentPoint:&p0])
        FinchDrawRaise(NSGenericException, @"No current point for line");
    double ax = p0.x - point1.x, ay = p0.y - point1.y, bx = point2.x - point1.x, by = point2.y - point1.y;
    double la = hypot(ax, ay), lb = hypot(bx, by);
    double cross = ax * by - ay * bx;
    if (la == 0 || lb == 0 || radius <= 0 || fabs(cross) < 1e-12 * la * lb) {
        [self lineToPoint:point1];
        return;
    }
    ax /= la, ay /= la, bx /= lb, by /= lb;
    double cosang = ax * bx + ay * by, ang = acos(fmax(-1, fmin(1, cosang)));
    double d = radius / tan(ang / 2);
    NSPoint t1 = NSMakePoint(point1.x + ax * d, point1.y + ay * d);
    double bisx = ax + bx, bisy = ay + by, bl = hypot(bisx, bisy);
    double h = radius / sin(ang / 2);
    NSPoint c = NSMakePoint(point1.x + bisx / bl * h, point1.y + bisy / bl * h);
    /* the arc from t1 to t2 around c, in segments of at most 90 degrees (no degenerate remainder) */
    double a = atan2(t1.y - c.y, t1.x - c.x), sweep = M_PI - ang;
    if (cross > 0)
        sweep = -sweep;
    [self lineToPoint:t1];
    int n = (int)ceil(fabs(sweep) / (M_PI / 2) - 1e-9);
    double step = n ? sweep / n : 0;
    for (int i = 0; i < n; i++, a += step)
        [self _arcSegmentCenter:c rx:radius ry:radius from:a to:a + step];
}

- (void)appendBezierPath:(NSBezierPath *)path
{
    for (NSInteger i = 0; i < path->_count; i++) {
        Element *e = &path->_e[i];
        [self _append:e->type p0:e->p[0] p1:e->p[1] p2:e->p[2]];
    }
}

- (void)appendBezierPathWithPoints:(NSPointArray)points count:(NSInteger)count
{
    for (NSInteger i = 0; i < count; i++) {
        if (i == 0 && !_count)
            [self moveToPoint:points[i]];
        else
            [self lineToPoint:points[i]];
    }
}

static CTFontRef
ct_font(NSFont *font)
{
    if (!font)
        return NULL;
    if (CFGetTypeID((CFTypeRef)font) == CTFontGetTypeID())
        return (CTFontRef)CFRetain((CFTypeRef)font);
    return CTFontCreateWithName((CFStringRef)[font fontName], [font pointSize], NULL);
}

typedef struct {
    NSBezierPath *path;
    CGAffineTransform t;
} GlyphInfo;

static void
glyph_element(void *info, const CGPathElement *e)
{
    GlyphInfo *g = info;
    NSPoint p[3];
    for (int i = 0; i < 3 && e->type != kCGPathElementCloseSubpath; i++)
        if ((e->type == kCGPathElementAddCurveToPoint) || i < (e->type == kCGPathElementAddQuadCurveToPoint ? 2 : 1))
            p[i] = NSPointFromCGPoint(CGPointApplyAffineTransform(e->points[i], g->t));
    switch (e->type) {
    case kCGPathElementMoveToPoint: [g->path moveToPoint:p[0]]; break;
    case kCGPathElementAddLineToPoint: [g->path lineToPoint:p[0]]; break;
    case kCGPathElementAddQuadCurveToPoint: [g->path curveToPoint:p[1] controlPoint:p[0]]; break;
    case kCGPathElementAddCurveToPoint: [g->path curveToPoint:p[2] controlPoint1:p[0] controlPoint2:p[1]]; break;
    case kCGPathElementCloseSubpath: [g->path closePath]; break;
    }
}

- (void)appendBezierPathWithCGGlyphs:(const CGGlyph *)glyphs count:(NSInteger)count inFont:(NSFont *)font
{
    CTFontRef f = ct_font(font);
    if (!f)
        return;
    NSPoint origin = NSZeroPoint;
    [self _currentPoint:&origin];
    for (NSInteger i = 0; i < count; i++) {
        CGPathRef gp = CTFontCreatePathForGlyph(f, glyphs[i], NULL);
        GlyphInfo info = {self, CGAffineTransformMakeTranslation(origin.x, origin.y)};
        if (gp) {
            CGPathApply(gp, &info, glyph_element);
            CGPathRelease(gp);
        }
        CGSize adv;
        CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, &glyphs[i], &adv, 1);
        origin.x += adv.width;
        origin.y += adv.height;
        [self moveToPoint:origin];
    }
    CFRelease(f);
}

- (void)appendBezierPathWithCGGlyph:(CGGlyph)glyph inFont:(NSFont *)font
{
    [self appendBezierPathWithCGGlyphs:&glyph count:1 inFont:font];
}

- (void)appendBezierPathWithGlyph:(NSGlyph)glyph inFont:(NSFont *)font
{
    CGGlyph g = (CGGlyph)glyph;
    [self appendBezierPathWithCGGlyphs:&g count:1 inFont:font];
}

- (void)appendBezierPathWithGlyphs:(NSGlyph *)glyphs count:(NSInteger)count inFont:(NSFont *)font
{
    CGGlyph *g = malloc(sizeof(CGGlyph) * (size_t)(count ? count : 1));
    for (NSInteger i = 0; i < count; i++)
        g[i] = (CGGlyph)glyphs[i];
    [self appendBezierPathWithCGGlyphs:g count:count inFont:font];
    free(g);
}

- (void)appendBezierPathWithPackedGlyphs:(const char *)packedGlyphs
{
}

/* MARK: Derived paths */

static NSPoint
cubic_at(NSPoint p0, NSPoint p1, NSPoint p2, NSPoint p3, double t)
{
    double u = 1 - t, a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
    return NSMakePoint(a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y);
}

static int
flatten_steps(NSPoint p0, NSPoint p1, NSPoint p2, NSPoint p3, CGFloat flatness)
{
    double d1 = hypot(p0.x - 2 * p1.x + p2.x, p0.y - 2 * p1.y + p2.y);
    double d2 = hypot(p1.x - 2 * p2.x + p3.x, p1.y - 2 * p2.y + p3.y);
    double d = 0.75 * fmax(d1, d2);
    if (flatness <= 0)
        flatness = 0.01;
    int n = 1;
    while (d > flatness * n * n && n < 65536)
        n *= 2;
    return n;
}

static void
quad_to_cubic(NSPoint p0, NSPoint q, NSPoint p3, NSPoint *c1, NSPoint *c2)
{
    *c1 = NSMakePoint(p0.x + 2.0 / 3 * (q.x - p0.x), p0.y + 2.0 / 3 * (q.y - p0.y));
    *c2 = NSMakePoint(p3.x + 2.0 / 3 * (q.x - p3.x), p3.y + 2.0 / 3 * (q.y - p3.y));
}

- (NSBezierPath *)_flattenedWithFlatness:(CGFloat)flatness
{
    NSBezierPath *f = [[self copy] autorelease];
    f->_count = 0;
    NSPoint cur = NSZeroPoint;
    for (NSInteger i = 0; i < _count; i++) {
        Element *e = &_e[i];
        NSPoint c1, c2, end;
        switch (e->type) {
        case NSBezierPathElementMoveTo:
        case NSBezierPathElementLineTo:
        case NSBezierPathElementClosePath:
            [f _append:e->type p0:e->p[0] p1:NSZeroPoint p2:NSZeroPoint];
            cur = e->p[0];
            continue;
        case NSBezierPathElementQuadraticCurveTo:
            quad_to_cubic(cur, e->p[0], e->p[1], &c1, &c2);
            end = e->p[1];
            break;
        default:
            c1 = e->p[0], c2 = e->p[1], end = e->p[2];
            break;
        }
        int n = flatten_steps(cur, c1, c2, end, flatness);
        for (int k = 1; k <= n; k++)
            [f _append:NSBezierPathElementLineTo p0:k == n ? end : cubic_at(cur, c1, c2, end, (double)k / n) p1:NSZeroPoint
                    p2:NSZeroPoint];
        cur = end;
    }
    return f;
}

- (NSBezierPath *)bezierPathByFlatteningPath
{
    return [self _flattenedWithFlatness:default_flatness];
}

- (NSBezierPath *)bezierPathByReversingPath
{
    NSBezierPath *r = [[self copy] autorelease];
    r->_count = 0;
    NSInteger i = 0;
    NSPoint start = NSZeroPoint;
    while (i < _count) {
        /* one subpath: an optional move, segments, and maybe a close */
        if (_e[i].type == NSBezierPathElementMoveTo)
            start = _e[i++].p[0];
        NSInteger first = i, end = i;
        while (end < _count && _e[end].type != NSBezierPathElementMoveTo && _e[end].type != NSBezierPathElementClosePath)
            end++;
        BOOL closed = end < _count && _e[end].type == NSBezierPathElementClosePath;
        NSInteger nseg = end - first;
        NSPoint *ends = malloc(sizeof(NSPoint) * (size_t)(nseg + 1));
        ends[0] = start;
        for (NSInteger k = 1; k <= nseg; k++) {
            Element *e = &_e[first + k - 1];
            ends[k] = e->type == NSBezierPathElementCurveTo ? e->p[2] : e->type == NSBezierPathElementQuadraticCurveTo ? e->p[1] : e->p[0];
        }
        if (closed) {
            [r moveToPoint:start];
            if (nseg > 0 && !NSEqualPoints(ends[nseg], start))
                [r lineToPoint:ends[nseg]];
        } else {
            [r moveToPoint:ends[nseg]];
        }
        for (NSInteger k = nseg; k >= 1; k--) {
            Element *e = &_e[first + k - 1];
            if (closed && k == 1 && e->type == NSBezierPathElementLineTo)
                break;  /* the first line becomes the closing one */
            switch (e->type) {
            case NSBezierPathElementCurveTo: [r curveToPoint:ends[k - 1] controlPoint1:e->p[1] controlPoint2:e->p[0]]; break;
            case NSBezierPathElementQuadraticCurveTo: [r curveToPoint:ends[k - 1] controlPoint:e->p[0]]; break;
            default: [r lineToPoint:ends[k - 1]]; break;
            }
        }
        if (closed)
            [r closePath];
        free(ends);
        i = closed ? end + 1 : end;
        if (closed && i < _count && _e[i].type != NSBezierPathElementMoveTo)
            continue;  /* segments after a close start again from the subpath's start */
    }
    return r;
}

- (void)transformUsingAffineTransform:(NSAffineTransform *)transform
{
    NSAffineTransformStruct t = [transform transformStruct];
    for (NSInteger i = 0; i < _count; i++)
        for (int k = 0; k < npoints(_e[i].type); k++) {
            NSPoint p = _e[i].p[k];
            _e[i].p[k] = NSMakePoint(t.m11 * p.x + t.m21 * p.y + t.tX, t.m12 * p.x + t.m22 * p.y + t.tY);
        }
    _boundsAreControlBounds = NO;
}

/* MARK: Bounds and hit testing */

- (NSRect)controlPointBounds
{
    if (!_count)
        FinchDrawRaise(NSGenericException, @"No current point for control point bounds");
    CGFloat x0 = INFINITY, y0 = INFINITY, x1 = -INFINITY, y1 = -INFINITY;
    for (NSInteger i = 0; i < _count; i++) {
        if (_e[i].type == NSBezierPathElementClosePath)
            continue;
        for (int k = 0; k < npoints(_e[i].type); k++) {
            NSPoint p = _e[i].p[k];
            x0 = fmin(x0, p.x), y0 = fmin(y0, p.y), x1 = fmax(x1, p.x), y1 = fmax(y1, p.y);
        }
    }
    if (x0 > x1)
        return NSZeroRect;
    return NSMakeRect(x0, y0, x1 - x0, y1 - y0);
}

/* Extremes of one coordinate of a cubic, at the roots of its derivative. */
static void
cubic_extent(double p0, double p1, double p2, double p3, double *lo, double *hi)
{
    *lo = fmin(*lo, fmin(p0, p3)), *hi = fmax(*hi, fmax(p0, p3));
    double a = -p0 + 3 * p1 - 3 * p2 + p3, b = 2 * (p0 - 2 * p1 + p2), c = p1 - p0;
    double roots[2];
    int n = 0;
    if (fabs(a) < 1e-12) {
        if (fabs(b) > 1e-12)
            roots[n++] = -c / b;
    } else {
        double disc = b * b - 4 * a * c;
        if (disc >= 0) {
            double s = sqrt(disc);
            roots[n++] = (-b + s) / (2 * a);
            roots[n++] = (-b - s) / (2 * a);
        }
    }
    for (int i = 0; i < n; i++) {
        double t = roots[i];
        if (t <= 0 || t >= 1)
            continue;
        double u = 1 - t, v = u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3;
        *lo = fmin(*lo, v), *hi = fmax(*hi, v);
    }
}

- (NSRect)bounds
{
    if (!_count)
        FinchDrawRaise(NSGenericException, @"No current point for control point bounds");
    if (_boundsAreControlBounds)
        return [self controlPointBounds];
    double x0 = INFINITY, y0 = INFINITY, x1 = -INFINITY, y1 = -INFINITY;
    NSPoint cur = NSZeroPoint;
    for (NSInteger i = 0; i < _count; i++) {
        Element *e = &_e[i];
        NSPoint c1, c2;
        switch (e->type) {
        case NSBezierPathElementClosePath:
            cur = e->p[0];
            continue;
        case NSBezierPathElementMoveTo:
            cur = e->p[0];
            x0 = fmin(x0, cur.x), y0 = fmin(y0, cur.y), x1 = fmax(x1, cur.x), y1 = fmax(y1, cur.y);
            continue;
        case NSBezierPathElementLineTo:
            cur = e->p[0];
            x0 = fmin(x0, cur.x), y0 = fmin(y0, cur.y), x1 = fmax(x1, cur.x), y1 = fmax(y1, cur.y);
            continue;
        case NSBezierPathElementQuadraticCurveTo:
            quad_to_cubic(cur, e->p[0], e->p[1], &c1, &c2);
            cubic_extent(cur.x, c1.x, c2.x, e->p[1].x, &x0, &x1);
            cubic_extent(cur.y, c1.y, c2.y, e->p[1].y, &y0, &y1);
            cur = e->p[1];
            continue;
        default:
            cubic_extent(cur.x, e->p[0].x, e->p[1].x, e->p[2].x, &x0, &x1);
            cubic_extent(cur.y, e->p[0].y, e->p[1].y, e->p[2].y, &y0, &y1);
            cur = e->p[2];
            continue;
        }
    }
    if (x0 > x1)
        return [self controlPointBounds];
    return NSMakeRect(x0, y0, x1 - x0, y1 - y0);
}

/* Winding number of the path, flattened finely, around p, as CGPathContainsPoint answers: a point on a
 * straight edge is inside, but the flattened curves lie inside their curves, so a point on a curve isn't. */
- (BOOL)containsPoint:(NSPoint)point
{
    if (!_count)
        return NO;
    int winding = 0;
    NSPoint start = NSZeroPoint, cur = NSZeroPoint;
    BOOL have = NO;
    __block BOOL onEdge = NO;
    void (^edge)(NSPoint, NSPoint, BOOL) = ^(NSPoint a, NSPoint b, BOOL straight) {
        double ex = b.x - a.x, ey = b.y - a.y, px = point.x - a.x, py = point.y - a.y;
        double cross = ex * py - ey * px, len2 = ex * ex + ey * ey;
        if (straight && fabs(cross) <= 1e-9 * fmax(1, sqrt(len2))) {
            double t = len2 > 0 ? (px * ex + py * ey) / len2 : 0;
            if (t >= -1e-12 && t <= 1 + 1e-12 && (len2 > 0 || (px == 0 && py == 0)))
                onEdge = YES;
        }
    };
    int *w = &winding;
    void (^cross)(NSPoint, NSPoint, BOOL) = ^(NSPoint a, NSPoint b, BOOL straight) {
        edge(a, b, straight);
        double c = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
        if (a.y <= point.y) {
            if (b.y > point.y && c > 0)
                (*w)++;
        } else if (b.y <= point.y && c < 0)
            (*w)--;
    };
    for (NSInteger i = 0; i < _count; i++) {
        Element *e = &_e[i];
        switch (e->type) {
        case NSBezierPathElementMoveTo:
            if (have)
                cross(cur, start, YES);
            start = cur = e->p[0], have = YES;
            break;
        case NSBezierPathElementClosePath:
            if (have)
                cross(cur, start, YES);
            cur = start;
            break;
        case NSBezierPathElementLineTo:
            cross(cur, e->p[0], YES);
            cur = e->p[0];
            break;
        default: {
            NSPoint c1, c2, end;
            if (e->type == NSBezierPathElementQuadraticCurveTo)
                quad_to_cubic(cur, e->p[0], e->p[1], &c1, &c2), end = e->p[1];
            else
                c1 = e->p[0], c2 = e->p[1], end = e->p[2];
            int n = flatten_steps(cur, c1, c2, end, 0.01);
            NSPoint prev = cur;
            for (int k = 1; k <= n; k++) {
                NSPoint q = k == n ? end : cubic_at(cur, c1, c2, end, (double)k / n);
                cross(prev, q, NO);
                prev = q;
            }
            cur = end;
            break;
        }
        }
    }
    if (have)
        cross(cur, start, YES);
    if (onEdge)
        return YES;
    return _winding == NSWindingRuleEvenOdd ? (winding & 1) != 0 : winding != 0;
}

/* MARK: Attributes */

+ (void)setDefaultMiterLimit:(CGFloat)limit { default_miter = limit; }
+ (CGFloat)defaultMiterLimit { return default_miter; }
+ (void)setDefaultFlatness:(CGFloat)flatness { default_flatness = flatness; }
+ (CGFloat)defaultFlatness { return default_flatness; }
+ (void)setDefaultWindingRule:(NSWindingRule)windingRule { default_winding = windingRule; }
+ (NSWindingRule)defaultWindingRule { return default_winding; }
+ (void)setDefaultLineCapStyle:(NSLineCapStyle)lineCapStyle { default_cap = lineCapStyle; }
+ (NSLineCapStyle)defaultLineCapStyle { return default_cap; }
+ (void)setDefaultLineJoinStyle:(NSLineJoinStyle)lineJoinStyle { default_join = lineJoinStyle; }
+ (NSLineJoinStyle)defaultLineJoinStyle { return default_join; }
+ (void)setDefaultLineWidth:(CGFloat)lineWidth { default_line_width = lineWidth; }
+ (CGFloat)defaultLineWidth { return default_line_width; }

- (CGFloat)lineWidth { return _lineWidth; }
- (void)setLineWidth:(CGFloat)w { _lineWidth = w; }
- (NSLineCapStyle)lineCapStyle { return _lineCap; }
- (void)setLineCapStyle:(NSLineCapStyle)s { _lineCap = s; }
- (NSLineJoinStyle)lineJoinStyle { return _lineJoin; }
- (void)setLineJoinStyle:(NSLineJoinStyle)s { _lineJoin = s; }
- (NSWindingRule)windingRule { return _winding; }
- (void)setWindingRule:(NSWindingRule)r { _winding = r; }
- (CGFloat)miterLimit { return _miterLimit; }
- (void)setMiterLimit:(CGFloat)m { _miterLimit = m; }
- (CGFloat)flatness { return _flatness; }
- (void)setFlatness:(CGFloat)f { _flatness = f; }
- (BOOL)cachesBezierPath { return _cachesBezierPath; }
- (void)setCachesBezierPath:(BOOL)flag { _cachesBezierPath = flag; }

- (void)setLineDash:(const CGFloat *)pattern count:(NSInteger)count phase:(CGFloat)phase
{
    free(_dash);
    _dash = NULL;
    _dashCount = pattern && count > 0 ? count : 0;
    if (_dashCount) {
        _dash = malloc(sizeof(CGFloat) * (size_t)count);
        memcpy(_dash, pattern, sizeof(CGFloat) * (size_t)count);
    }
    _dashPhase = phase;
}

- (void)getLineDash:(CGFloat *)pattern count:(NSInteger *)count phase:(CGFloat *)phase
{
    if (pattern && _dashCount)
        memcpy(pattern, _dash, sizeof(CGFloat) * (size_t)_dashCount);
    if (count)
        *count = _dashCount;
    if (phase)
        *phase = _dashPhase;
}

/* MARK: CoreGraphics */

- (CGPathRef)CGPath
{
    CGMutablePathRef p = CGPathCreateMutable();
    for (NSInteger i = 0; i < _count; i++) {
        Element *e = &_e[i];
        switch (e->type) {
        case NSBezierPathElementMoveTo: CGPathMoveToPoint(p, NULL, e->p[0].x, e->p[0].y); break;
        case NSBezierPathElementLineTo: CGPathAddLineToPoint(p, NULL, e->p[0].x, e->p[0].y); break;
        case NSBezierPathElementCurveTo:
            CGPathAddCurveToPoint(p, NULL, e->p[0].x, e->p[0].y, e->p[1].x, e->p[1].y, e->p[2].x, e->p[2].y);
            break;
        case NSBezierPathElementQuadraticCurveTo:
            CGPathAddQuadCurveToPoint(p, NULL, e->p[0].x, e->p[0].y, e->p[1].x, e->p[1].y);
            break;
        case NSBezierPathElementClosePath: CGPathCloseSubpath(p); break;
        }
    }
    return (CGPathRef)[(id)p autorelease];
}

- (void)setCGPath:(CGPathRef)path
{
    [self removeAllPoints];
    if (path)
        CGPathApplyWithBlock(path, ^(const CGPathElement *e) {
            switch (e->type) {
            case kCGPathElementMoveToPoint: [self moveToPoint:NSPointFromCGPoint(e->points[0])]; break;
            case kCGPathElementAddLineToPoint: [self lineToPoint:NSPointFromCGPoint(e->points[0])]; break;
            case kCGPathElementAddQuadCurveToPoint:
                [self curveToPoint:NSPointFromCGPoint(e->points[1]) controlPoint:NSPointFromCGPoint(e->points[0])];
                break;
            case kCGPathElementAddCurveToPoint:
                [self curveToPoint:NSPointFromCGPoint(e->points[2]) controlPoint1:NSPointFromCGPoint(e->points[0])
                     controlPoint2:NSPointFromCGPoint(e->points[1])];
                break;
            case kCGPathElementCloseSubpath: [self closePath]; break;
            }
        });
    _boundsAreControlBounds = YES;
}

+ (NSBezierPath *)bezierPathWithCGPath:(CGPathRef)cgPath
{
    NSBezierPath *p = [self bezierPath];
    [p setCGPath:cgPath];
    return p;
}

/* MARK: Drawing */

- (void)_addToContext:(CGContextRef)c
{
    CGContextBeginPath(c);
    CGContextAddPath(c, [self CGPath]);
}

- (void)_applyLineAttributes:(CGContextRef)c
{
    CGContextSetLineWidth(c, _lineWidth);
    CGContextSetLineCap(c, (CGLineCap)_lineCap);
    CGContextSetLineJoin(c, (CGLineJoin)_lineJoin);
    CGContextSetMiterLimit(c, _miterLimit);
    CGContextSetFlatness(c, _flatness);
    CGContextSetLineDash(c, _dashPhase, _dash, (size_t)_dashCount);
}

- (void)stroke
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || !_count)
        return;
    CGContextSaveGState(c);
    [self _applyLineAttributes:c];
    [self _addToContext:c];
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
}

- (void)fill
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || !_count)
        return;
    CGContextSaveGState(c);
    CGContextSetFlatness(c, _flatness);
    [self _addToContext:c];
    if (_winding == NSWindingRuleEvenOdd)
        CGContextEOFillPath(c);
    else
        CGContextFillPath(c);
    CGContextRestoreGState(c);
}

- (void)addClip
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c)
        return;
    [self _addToContext:c];
    if (_winding == NSWindingRuleEvenOdd)
        CGContextEOClip(c);
    else
        CGContextClip(c);
}

- (void)setClip
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c)
        return;
    CGContextResetClip(c);
    [self addClip];
}

+ (void)fillRect:(NSRect)rect
{
    CGContextRef c = FinchCurrentCGContext();
    if (c)
        CGContextFillRect(c, NSRectToCGRect(rect));
}

+ (void)strokeRect:(NSRect)rect
{
    NSBezierPath *p = [self bezierPathWithRect:rect];
    [p stroke];
}

+ (void)clipRect:(NSRect)rect
{
    CGContextRef c = FinchCurrentCGContext();
    if (c)
        CGContextClipToRect(c, NSRectToCGRect(rect));
}

+ (void)strokeLineFromPoint:(NSPoint)point1 toPoint:(NSPoint)point2
{
    NSBezierPath *p = [self bezierPath];
    [p moveToPoint:point1];
    [p lineToPoint:point2];
    [p stroke];
}

+ (void)drawPackedGlyphs:(const char *)packedGlyphs atPoint:(NSPoint)point
{
}

/* MARK: Description, NSCoding */

- (NSString *)description
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"Path <%p>", self];
    if (_count) {
        [s appendFormat:@"\n  Bounds: %@", NSStringFromRect([self bounds])];
        [s appendFormat:@"\n  Control point bounds: %@", NSStringFromRect([self controlPointBounds])];
    }
    for (NSInteger i = 0; i < _count; i++) {
        Element *e = &_e[i];
        switch (e->type) {
        case NSBezierPathElementMoveTo: [s appendFormat:@"\n    %f %f moveto", e->p[0].x, e->p[0].y]; break;
        case NSBezierPathElementLineTo: [s appendFormat:@"\n    %f %f lineto", e->p[0].x, e->p[0].y]; break;
        case NSBezierPathElementCurveTo:
            [s appendFormat:@"\n    %f %f %f %f %f %f curveto", e->p[0].x, e->p[0].y, e->p[1].x, e->p[1].y, e->p[2].x, e->p[2].y];
            break;
        case NSBezierPathElementQuadraticCurveTo:
            [s appendFormat:@"\n    %f %f %f %f quadcurveto", e->p[0].x, e->p[0].y, e->p[1].x, e->p[1].y];
            break;
        case NSBezierPathElementClosePath: [s appendString:@"\n    closepath"]; break;
        }
    }
    return s;
}

+ (BOOL)supportsSecureCoding { return YES; }

static void
put_float(NSMutableData *d, CGFloat v)
{
    float f = (float)v;
    uint32_t u;
    memcpy(&u, &f, 4);
    u = CFSwapInt32HostToBig(u);
    [d appendBytes:&u length:4];
}

static CGFloat
get_float(const uint8_t *b)
{
    uint32_t u;
    memcpy(&u, b, 4);
    u = CFSwapInt32BigToHost(u);
    float f;
    memcpy(&f, &u, 4);
    return f;
}

/* Apple's NSSegments: per point, a type byte and two big-endian floats (a curve is three such records). */
- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_count) {
        NSMutableData *d = [NSMutableData data];
        for (NSInteger i = 0; i < _count; i++)
            for (int k = 0; k < npoints(_e[i].type); k++) {
                uint8_t t = (uint8_t)_e[i].type;
                [d appendBytes:&t length:1];
                put_float(d, _e[i].p[k].x);
                put_float(d, _e[i].p[k].y);
            }
        [coder encodeBytes:d.bytes length:d.length forKey:@"NSSegments"];
    }
    if (_lineWidth != 1)
        [coder encodeDouble:_lineWidth forKey:@"NSLineWidth"];
    if (_lineCap)
        [coder encodeInteger:_lineCap forKey:@"NSCapStyle"];
    if (_lineJoin)
        [coder encodeInteger:_lineJoin forKey:@"NSJoinStyle"];
    if (_miterLimit != 10)
        [coder encodeDouble:_miterLimit forKey:@"NSMiterLimit"];
    if (_flatness != 0.6)
        [coder encodeDouble:_flatness forKey:@"NSFlatness"];
    if (_winding)
        [coder encodeInteger:_winding forKey:@"NSWindingRule"];
    if (_dashCount) {
        NSMutableData *d = [NSMutableData data];
        for (NSInteger i = 0; i < _dashCount; i++)
            put_float(d, _dash[i]);
        [coder encodeBytes:d.bytes length:d.length forKey:@"NSDashPatterns"];
        [coder encodeDouble:_dashPhase forKey:@"NSDashPhase"];
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self init]))
        return nil;
    NSUInteger len = 0;
    const uint8_t *b = [coder decodeBytesForKey:@"NSSegments" returnedLength:&len];
    for (NSUInteger off = 0; b && off + 9 <= len;) {
        NSBezierPathElement t = (NSBezierPathElement)b[off];
        int n = npoints(t);
        NSPoint p[3] = {NSZeroPoint, NSZeroPoint, NSZeroPoint};
        for (int k = 0; k < n && off + 9 <= len; k++, off += 9)
            p[k] = NSMakePoint(get_float(b + off + 1), get_float(b + off + 5));
        [self _append:t p0:p[0] p1:p[1] p2:p[2]];
    }
    if ([coder containsValueForKey:@"NSLineWidth"])
        _lineWidth = [coder decodeDoubleForKey:@"NSLineWidth"];
    if ([coder containsValueForKey:@"NSCapStyle"])
        _lineCap = (NSLineCapStyle)[coder decodeIntegerForKey:@"NSCapStyle"];
    if ([coder containsValueForKey:@"NSJoinStyle"])
        _lineJoin = (NSLineJoinStyle)[coder decodeIntegerForKey:@"NSJoinStyle"];
    if ([coder containsValueForKey:@"NSMiterLimit"])
        _miterLimit = [coder decodeDoubleForKey:@"NSMiterLimit"];
    if ([coder containsValueForKey:@"NSFlatness"])
        _flatness = [coder decodeDoubleForKey:@"NSFlatness"];
    if ([coder containsValueForKey:@"NSWindingRule"])
        _winding = (NSWindingRule)[coder decodeIntegerForKey:@"NSWindingRule"];
    const uint8_t *d = [coder decodeBytesForKey:@"NSDashPatterns" returnedLength:&len];
    if (d && len >= 4) {
        NSInteger n = (NSInteger)(len / 4);
        CGFloat *pat = malloc(sizeof(CGFloat) * (size_t)n);
        for (NSInteger i = 0; i < n; i++)
            pat[i] = get_float(d + 4 * i);
        [self setLineDash:pat count:n phase:[coder decodeDoubleForKey:@"NSDashPhase"]];
        free(pat);
    }
    return self;
}

@end

/* MARK: - NSAffineTransform's AppKit additions */

@implementation NSAffineTransform (NSAppKitAdditions)

- (NSBezierPath *)transformBezierPath:(NSBezierPath *)path
{
    /* rebuilt element by element, as Apple's (so a close is followed by its move) */
    NSBezierPath *copy = [NSBezierPath bezierPath];
    NSAffineTransformStruct t = [self transformStruct];
    NSPoint p[3];
#define T(q) NSMakePoint(t.m11 * (q).x + t.m21 * (q).y + t.tX, t.m12 * (q).x + t.m22 * (q).y + t.tY)
    for (NSInteger i = 0; i < path.elementCount; i++) {
        switch ([path elementAtIndex:i associatedPoints:p]) {
        case NSBezierPathElementMoveTo: [copy moveToPoint:T(p[0])]; break;
        case NSBezierPathElementLineTo: [copy lineToPoint:T(p[0])]; break;
        case NSBezierPathElementCurveTo: [copy curveToPoint:T(p[2]) controlPoint1:T(p[0]) controlPoint2:T(p[1])]; break;
        case NSBezierPathElementQuadraticCurveTo: [copy curveToPoint:T(p[1]) controlPoint:T(p[0])]; break;
        case NSBezierPathElementClosePath: [copy closePath]; break;
        }
    }
#undef T
    [copy setLineWidth:path.lineWidth];
    [copy setLineCapStyle:path.lineCapStyle];
    [copy setLineJoinStyle:path.lineJoinStyle];
    [copy setMiterLimit:path.miterLimit];
    [copy setFlatness:path.flatness];
    [copy setWindingRule:path.windingRule];
    return copy;
}

- (void)set
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c)
        return;
    /* replace the CTM: undo the current one, then apply this */
    CGContextConcatCTM(c, CGAffineTransformInvert(CGContextGetCTM(c)));
    NSAffineTransformStruct t = [self transformStruct];
    CGContextConcatCTM(c, CGAffineTransformMake(t.m11, t.m12, t.m21, t.m22, t.tX, t.tY));
}

- (void)concat
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c)
        return;
    NSAffineTransformStruct t = [self transformStruct];
    CGContextConcatCTM(c, CGAffineTransformMake(t.m11, t.m12, t.m21, t.m22, t.tX, t.tY));
}

@end
