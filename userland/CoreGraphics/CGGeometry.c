/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGGeometry and CGAffineTransform: points, sizes, rects and affine
 * transforms, with Apple's handling of null, infinite and negative-sized
 * rects (checked by finch-cg-test against Apple's CoreGraphics).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGGeometry.h>
#include <CoreGraphics/CGAffineTransform.h>
#include <math.h>
#include <float.h>

/* The header inlines these; Apple's framework exports them too. */
#undef CGAffineTransformMake
#undef CGPointApplyAffineTransform
#undef CGSizeApplyAffineTransform
#undef CGPointEqualToPoint
#undef CGSizeEqualToSize

const CGPoint CGPointZero = {0, 0};
const CGSize CGSizeZero = {0, 0};
const CGRect CGRectZero = {{0, 0}, {0, 0}};
const CGRect CGRectNull = {{INFINITY, INFINITY}, {0, 0}};
const CGRect CGRectInfinite = {{-DBL_MAX / 2, -DBL_MAX / 2}, {DBL_MAX, DBL_MAX}};
const CGAffineTransform CGAffineTransformIdentity = {1, 0, 0, 1, 0, 0};

#pragma mark - Rects

bool
CGRectIsNull(CGRect r)
{
    return r.origin.x == INFINITY || r.origin.y == INFINITY;
}

bool
CGRectIsInfinite(CGRect r)
{
    return r.origin.x == CGRectInfinite.origin.x && r.origin.y == CGRectInfinite.origin.y &&
           r.size.width == CGRectInfinite.size.width && r.size.height == CGRectInfinite.size.height;
}

bool
CGRectIsEmpty(CGRect r)
{
    return CGRectIsNull(r) || r.size.width == 0 || r.size.height == 0;
}

CGRect
CGRectStandardize(CGRect r)
{
    if (CGRectIsNull(r))
        return CGRectNull;
    if (CGRectIsInfinite(r))
        return r;
    if (r.size.width < 0) {
        r.origin.x += r.size.width;
        r.size.width = -r.size.width;
    }
    if (r.size.height < 0) {
        r.origin.y += r.size.height;
        r.size.height = -r.size.height;
    }
    return r;
}

CGFloat CGRectGetMinX(CGRect r) { return r.size.width < 0 ? r.origin.x + r.size.width : r.origin.x; }
CGFloat CGRectGetMaxX(CGRect r) { return r.size.width < 0 ? r.origin.x : r.origin.x + r.size.width; }
CGFloat CGRectGetMidX(CGRect r) { return CGRectGetMinX(r) + fabs(r.size.width) / 2; }
CGFloat CGRectGetMinY(CGRect r) { return r.size.height < 0 ? r.origin.y + r.size.height : r.origin.y; }
CGFloat CGRectGetMaxY(CGRect r) { return r.size.height < 0 ? r.origin.y : r.origin.y + r.size.height; }
CGFloat CGRectGetMidY(CGRect r) { return CGRectGetMinY(r) + fabs(r.size.height) / 2; }
CGFloat CGRectGetWidth(CGRect r) { return fabs(r.size.width); }
CGFloat CGRectGetHeight(CGRect r) { return fabs(r.size.height); }

bool
CGPointEqualToPoint(CGPoint a, CGPoint b)
{
    return a.x == b.x && a.y == b.y;
}

bool
CGSizeEqualToSize(CGSize a, CGSize b)
{
    return a.width == b.width && a.height == b.height;
}

bool
CGRectEqualToRect(CGRect a, CGRect b)
{
    bool an = CGRectIsNull(a), bn = CGRectIsNull(b);
    if (an || bn)
        return an && bn;
    a = CGRectStandardize(a);
    b = CGRectStandardize(b);
    return CGPointEqualToPoint(a.origin, b.origin) && CGSizeEqualToSize(a.size, b.size);
}

CGRect
CGRectInset(CGRect r, CGFloat dx, CGFloat dy)
{
    if (CGRectIsNull(r) || CGRectIsInfinite(r))
        return r;
    r = CGRectStandardize(r);
    r.origin.x += dx;
    r.origin.y += dy;
    r.size.width -= 2 * dx;
    r.size.height -= 2 * dy;
    if (r.size.width < 0 || r.size.height < 0)
        return CGRectNull;
    return r;
}

CGRect
CGRectIntegral(CGRect r)
{
    if (CGRectIsNull(r) || CGRectIsInfinite(r))
        return r;
    r = CGRectStandardize(r);
    CGFloat x0 = floor(r.origin.x), y0 = floor(r.origin.y);
    CGFloat x1 = ceil(r.origin.x + r.size.width), y1 = ceil(r.origin.y + r.size.height);
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

CGRect
CGRectOffset(CGRect r, CGFloat dx, CGFloat dy)
{
    if (CGRectIsNull(r) || CGRectIsInfinite(r))
        return r;
    r = CGRectStandardize(r);
    r.origin.x += dx;
    r.origin.y += dy;
    return r;
}

CGRect
CGRectUnion(CGRect a, CGRect b)
{
    if (CGRectIsNull(a))
        return b;
    if (CGRectIsNull(b))
        return a;
    if (CGRectIsInfinite(a) || CGRectIsInfinite(b))
        return CGRectInfinite;
    a = CGRectStandardize(a);
    b = CGRectStandardize(b);
    CGFloat x0 = fmin(a.origin.x, b.origin.x), y0 = fmin(a.origin.y, b.origin.y);
    CGFloat x1 = fmax(a.origin.x + a.size.width, b.origin.x + b.size.width);
    CGFloat y1 = fmax(a.origin.y + a.size.height, b.origin.y + b.size.height);
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

CGRect
CGRectIntersection(CGRect a, CGRect b)
{
    if (CGRectIsNull(a) || CGRectIsNull(b))
        return CGRectNull;
    if (CGRectIsInfinite(a))
        return CGRectStandardize(b);
    if (CGRectIsInfinite(b))
        return CGRectStandardize(a);
    a = CGRectStandardize(a);
    b = CGRectStandardize(b);
    CGFloat x0 = fmax(a.origin.x, b.origin.x), y0 = fmax(a.origin.y, b.origin.y);
    CGFloat x1 = fmin(a.origin.x + a.size.width, b.origin.x + b.size.width);
    CGFloat y1 = fmin(a.origin.y + a.size.height, b.origin.y + b.size.height);
    if (x1 < x0 || y1 < y0)
        return CGRectNull;
    return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

/*
 * Each side is the half-open span [min, max), or the single point min when
 * its length is zero; rects intersect when their spans share a point on
 * both axes. So rects that only touch don't intersect, but an empty rect
 * inside another does.
 */
static bool
spans_meet(CGFloat amin, CGFloat alen, CGFloat bmin, CGFloat blen)
{
    CGFloat lo = fmax(amin, bmin);
    if (alen > 0 ? lo >= amin + alen : lo > amin)
        return false;
    return blen > 0 ? lo < bmin + blen : lo <= bmin;
}

bool
CGRectIntersectsRect(CGRect a, CGRect b)
{
    if (CGRectIsNull(a) || CGRectIsNull(b))
        return false;
    if (CGRectIsInfinite(a) || CGRectIsInfinite(b))
        return true;
    a = CGRectStandardize(a);
    b = CGRectStandardize(b);
    return spans_meet(a.origin.x, a.size.width, b.origin.x, b.size.width) &&
           spans_meet(a.origin.y, a.size.height, b.origin.y, b.size.height);
}

bool
CGRectContainsRect(CGRect a, CGRect b)
{
    return CGRectEqualToRect(CGRectUnion(a, b), a);
}

bool
CGRectContainsPoint(CGRect r, CGPoint p)
{
    if (CGRectIsNull(r))
        return false;
    if (CGRectIsInfinite(r))
        return true;
    r = CGRectStandardize(r);
    return p.x >= r.origin.x && p.x < r.origin.x + r.size.width &&
           p.y >= r.origin.y && p.y < r.origin.y + r.size.height;
}

void
CGRectDivide(CGRect r, CGRect *slice, CGRect *remainder, CGFloat amount, CGRectEdge edge)
{
    CGRect s, rem;
    r = CGRectStandardize(r);
    if (CGRectIsNull(r)) {
        s = rem = CGRectNull;
    } else {
        if (amount < 0)
            amount = 0;
        s = rem = r;
        bool horizontal = edge == CGRectMinXEdge || edge == CGRectMaxXEdge;
        CGFloat extent = horizontal ? r.size.width : r.size.height;
        if (amount > extent)
            amount = extent;
        switch (edge) {
        case CGRectMinXEdge:
            s.size.width = amount;
            rem.origin.x += amount;
            rem.size.width -= amount;
            break;
        case CGRectMaxXEdge:
            s.origin.x += r.size.width - amount;
            s.size.width = amount;
            rem.size.width -= amount;
            break;
        case CGRectMinYEdge:
            s.size.height = amount;
            rem.origin.y += amount;
            rem.size.height -= amount;
            break;
        case CGRectMaxYEdge:
            s.origin.y += r.size.height - amount;
            s.size.height = amount;
            rem.size.height -= amount;
            break;
        }
    }
    if (slice)
        *slice = s;
    if (remainder)
        *remainder = rem;
}

#pragma mark - Dictionary representations

static CFNumberRef
number(CGFloat v)
{
    return CFNumberCreate(NULL, kCFNumberCGFloatType, &v);
}

static CFDictionaryRef
make_dict(int n, CFStringRef *keys, CGFloat *values)
{
    CFNumberRef nums[4];
    for (int i = 0; i < n; i++)
        nums[i] = number(values[i]);
    CFDictionaryRef d = CFDictionaryCreate(NULL, (const void **)keys, (const void **)nums, n,
                                           &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (int i = 0; i < n; i++)
        CFRelease(nums[i]);
    return d;
}

static bool
get_values(CFDictionaryRef d, int n, CFStringRef *keys, CGFloat *values)
{
    if (!d)
        return false;
    for (int i = 0; i < n; i++) {
        CFTypeRef v = CFDictionaryGetValue(d, keys[i]);
        if (!v || CFGetTypeID(v) != CFNumberGetTypeID() ||
            !CFNumberGetValue((CFNumberRef)v, kCFNumberCGFloatType, &values[i]))
            return false;
    }
    return true;
}

static CFStringRef point_keys[2], size_keys[2], rect_keys[4];

__attribute__((constructor)) static void
init_keys(void)
{
    point_keys[0] = rect_keys[0] = CFSTR("X");
    point_keys[1] = rect_keys[1] = CFSTR("Y");
    size_keys[0] = rect_keys[2] = CFSTR("Width");
    size_keys[1] = rect_keys[3] = CFSTR("Height");
}

CFDictionaryRef
CGPointCreateDictionaryRepresentation(CGPoint p)
{
    CGFloat v[2] = {p.x, p.y};
    return make_dict(2, point_keys, v);
}

CFDictionaryRef
CGSizeCreateDictionaryRepresentation(CGSize s)
{
    CGFloat v[2] = {s.width, s.height};
    return make_dict(2, size_keys, v);
}

CFDictionaryRef
CGRectCreateDictionaryRepresentation(CGRect r)
{
    CGFloat v[4] = {r.origin.x, r.origin.y, r.size.width, r.size.height};
    return make_dict(4, rect_keys, v);
}

bool
CGPointMakeWithDictionaryRepresentation(CFDictionaryRef d, CGPoint *p)
{
    CGFloat v[2];
    if (!get_values(d, 2, point_keys, v))
        return false;
    if (p)
        *p = CGPointMake(v[0], v[1]);
    return true;
}

bool
CGSizeMakeWithDictionaryRepresentation(CFDictionaryRef d, CGSize *s)
{
    CGFloat v[2];
    if (!get_values(d, 2, size_keys, v))
        return false;
    if (s)
        *s = CGSizeMake(v[0], v[1]);
    return true;
}

bool
CGRectMakeWithDictionaryRepresentation(CFDictionaryRef d, CGRect *r)
{
    CGFloat v[4];
    if (!get_values(d, 4, rect_keys, v))
        return false;
    if (r)
        *r = CGRectMake(v[0], v[1], v[2], v[3]);
    return true;
}

#pragma mark - Affine transforms

CGAffineTransform
CGAffineTransformMake(CGFloat a, CGFloat b, CGFloat c, CGFloat d, CGFloat tx, CGFloat ty)
{
    return (CGAffineTransform){a, b, c, d, tx, ty};
}

CGAffineTransform
CGAffineTransformMakeTranslation(CGFloat tx, CGFloat ty)
{
    return (CGAffineTransform){1, 0, 0, 1, tx, ty};
}

CGAffineTransform
CGAffineTransformMakeScale(CGFloat sx, CGFloat sy)
{
    return (CGAffineTransform){sx, 0, 0, sy, 0, 0};
}

CGAffineTransform
CGAffineTransformMakeRotation(CGFloat angle)
{
    CGFloat s = sin(angle), c = cos(angle);
    return (CGAffineTransform){c, s, -s, c, 0, 0};
}

bool
CGAffineTransformIsIdentity(CGAffineTransform t)
{
    return t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1 && t.tx == 0 && t.ty == 0;
}

/* t1 then t2 */
CGAffineTransform
CGAffineTransformConcat(CGAffineTransform t1, CGAffineTransform t2)
{
    return (CGAffineTransform){
        t1.a * t2.a + t1.b * t2.c,
        t1.a * t2.b + t1.b * t2.d,
        t1.c * t2.a + t1.d * t2.c,
        t1.c * t2.b + t1.d * t2.d,
        t1.tx * t2.a + t1.ty * t2.c + t2.tx,
        t1.tx * t2.b + t1.ty * t2.d + t2.ty,
    };
}

CGAffineTransform
CGAffineTransformTranslate(CGAffineTransform t, CGFloat tx, CGFloat ty)
{
    return CGAffineTransformConcat(CGAffineTransformMakeTranslation(tx, ty), t);
}

CGAffineTransform
CGAffineTransformScale(CGAffineTransform t, CGFloat sx, CGFloat sy)
{
    return CGAffineTransformConcat(CGAffineTransformMakeScale(sx, sy), t);
}

CGAffineTransform
CGAffineTransformRotate(CGAffineTransform t, CGFloat angle)
{
    return CGAffineTransformConcat(CGAffineTransformMakeRotation(angle), t);
}

CGAffineTransform
CGAffineTransformInvert(CGAffineTransform t)
{
    CGFloat det = t.a * t.d - t.b * t.c;
    if (det == 0)
        return t;
    CGFloat a = t.d / det, b = -t.b / det, c = -t.c / det, d = t.a / det;
    return (CGAffineTransform){a, b, c, d, -(t.tx * a + t.ty * c), -(t.tx * b + t.ty * d)};
}

bool
CGAffineTransformEqualToTransform(CGAffineTransform t1, CGAffineTransform t2)
{
    return t1.a == t2.a && t1.b == t2.b && t1.c == t2.c && t1.d == t2.d && t1.tx == t2.tx && t1.ty == t2.ty;
}

CGPoint
CGPointApplyAffineTransform(CGPoint p, CGAffineTransform t)
{
    return CGPointMake(t.a * p.x + t.c * p.y + t.tx, t.b * p.x + t.d * p.y + t.ty);
}

CGSize
CGSizeApplyAffineTransform(CGSize s, CGAffineTransform t)
{
    return CGSizeMake(t.a * s.width + t.c * s.height, t.b * s.width + t.d * s.height);
}

CGRect
CGRectApplyAffineTransform(CGRect r, CGAffineTransform t)
{
    if (CGRectIsNull(r) || CGRectIsInfinite(r))
        return r;
    r = CGRectStandardize(r);
    CGFloat x0 = r.origin.x, y0 = r.origin.y, x1 = x0 + r.size.width, y1 = y0 + r.size.height;
    CGPoint p[4] = {
        CGPointApplyAffineTransform(CGPointMake(x0, y0), t),
        CGPointApplyAffineTransform(CGPointMake(x1, y0), t),
        CGPointApplyAffineTransform(CGPointMake(x0, y1), t),
        CGPointApplyAffineTransform(CGPointMake(x1, y1), t),
    };
    CGFloat minx = p[0].x, maxx = p[0].x, miny = p[0].y, maxy = p[0].y;
    for (int i = 1; i < 4; i++) {
        minx = fmin(minx, p[i].x);
        maxx = fmax(maxx, p[i].x);
        miny = fmin(miny, p[i].y);
        maxy = fmax(maxy, p[i].y);
    }
    return CGRectMake(minx, miny, maxx - minx, maxy - miny);
}

/*
 * t = scale · shear · rotation, then the translation: the first row gives
 * the x scale (signed like the determinant) and the rotation; the second
 * row, rotated back, gives the y scale and the shear.
 */
CGAffineTransformComponents
CGAffineTransformDecompose(CGAffineTransform t)
{
    CGFloat det = t.a * t.d - t.b * t.c;
    CGFloat sx = sqrt(t.a * t.a + t.b * t.b);
    if (det < 0)
        sx = -sx;
    CGFloat rotation = atan2(t.b / sx, t.a / sx);
    CGFloat cs = cos(rotation), sn = sin(rotation);
    CGFloat c = t.c * cs + t.d * sn, sy = t.d * cs - t.c * sn;
    CGAffineTransformComponents out;
    out.scale = CGSizeMake(sx, sy);
    out.horizontalShear = c / sy;
    out.rotation = rotation;
    out.translation = (CGVector){t.tx, t.ty};
    return out;
}

CGAffineTransform
CGAffineTransformMakeWithComponents(CGAffineTransformComponents k)
{
    CGFloat sx = k.scale.width, sy = k.scale.height;
    CGAffineTransform t = {sx, 0, sy * k.horizontalShear, sy, 0, 0};
    t = CGAffineTransformConcat(t, CGAffineTransformMakeRotation(k.rotation));
    t.tx = k.translation.dx;
    t.ty = k.translation.dy;
    return t;
}
