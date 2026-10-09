/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cg-test: CoreGraphics behaviour with exact answers, one result per
 * line, so a run against Apple's CoreGraphics (on the host) and one against
 * Finch's can be diffed, as finch-cf-test is.
 *
 *   geometry: rects (null, infinite, negative sizes), dictionary forms;
 *   affine transforms; paths: construction (arcs, ellipses, rounded rects),
 *   bounds, hit testing.
 */
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static const char *
g(CGFloat v)
{
    static char bufs[16][40];
    static int n;
    char *b = bufs[n++ & 15];
    if (v == 0) v = 0;  /* print -0 as 0: rounding differences, not behaviour */
    snprintf(b, 40, "%.17g", v);
    return b;
}

static void
rect(const char *label, CGRect r)
{
    printf("%s: {%s, %s, %s, %s}\n", label, g(r.origin.x), g(r.origin.y), g(r.size.width), g(r.size.height));
}

static void
point(const char *label, CGPoint p)
{
    printf("%s: {%s, %s}\n", label, g(p.x), g(p.y));
}

static void
xform(const char *label, CGAffineTransform t)
{
    printf("%s: [%s %s %s %s %s %s]\n", label, g(t.a), g(t.b), g(t.c), g(t.d), g(t.tx), g(t.ty));
}

/* Rounded to 12 significant digits: trigonometry may differ in the last bits. */
static void
xform12(const char *label, CGAffineTransform t)
{
    CGFloat v[6] = {t.a, t.b, t.c, t.d, t.tx, t.ty};
    printf("%s: [", label);
    for (int i = 0; i < 6; i++) {
        double r = fabs(v[i]) < 1e-12 ? 0 : v[i];
        printf("%s%.12g", i ? " " : "", r);
    }
    printf("]\n");
}

static void
cfdesc(const char *label, CFTypeRef obj)
{
    if (!obj) {
        printf("%s: NULL\n", label);
        return;
    }
    CFStringRef d = CFCopyDescription(obj);
    char buf[2048];
    CFStringGetCString(d, buf, sizeof buf, kCFStringEncodingUTF8);
    for (char *s = buf; *s; s++)
        if (*s == '\n') *s = ' ';
    /* mask addresses */
    char out[2048], *o = out;
    for (char *s = buf; *s && o < out + sizeof out - 12;) {
        if (s[0] == '0' && s[1] == 'x') {
            o += sprintf(o, "0xADDR");
            s += 2;
            while ((*s >= '0' && *s <= '9') || (*s >= 'a' && *s <= 'f')) s++;
        } else {
            *o++ = *s++;
        }
    }
    *o = 0;
    printf("%s: %s\n", label, out);
    CFRelease(d);
}

static void
geometry(void)
{
    rect("zero", CGRectZero);
    rect("null", CGRectNull);
    rect("infinite", CGRectInfinite);
    point("pointzero", CGPointZero);
    printf("sizezero: %s %s\n", g(CGSizeZero.width), g(CGSizeZero.height));

    CGRect rs[] = {
        CGRectMake(1, 2, 3, 4), CGRectMake(10, 20, -5, -8), CGRectMake(0, 0, 0, 5),
        CGRectNull, CGRectInfinite, CGRectMake(1.5, 2.25, 3.75, 0.5),
        CGRectMake(-1, -1, 0, 0), CGRectMake(INFINITY, 3, 4, 5),
    };
    int n = sizeof rs / sizeof rs[0];
    for (int i = 0; i < n; i++) {
        CGRect r = rs[i];
        char l[64];
        printf("r%d minmax: %s %s %s %s %s %s w=%s h=%s\n", i,
               g(CGRectGetMinX(r)), g(CGRectGetMidX(r)), g(CGRectGetMaxX(r)),
               g(CGRectGetMinY(r)), g(CGRectGetMidY(r)), g(CGRectGetMaxY(r)),
               g(CGRectGetWidth(r)), g(CGRectGetHeight(r)));
        printf("r%d empty=%d null=%d infinite=%d\n", i, CGRectIsEmpty(r), CGRectIsNull(r), CGRectIsInfinite(r));
        snprintf(l, sizeof l, "r%d standardize", i); rect(l, CGRectStandardize(r));
        snprintf(l, sizeof l, "r%d inset 1 0.5", i); rect(l, CGRectInset(r, 1, 0.5));
        snprintf(l, sizeof l, "r%d inset -2 -2", i); rect(l, CGRectInset(r, -2, -2));
        snprintf(l, sizeof l, "r%d inset 5 5", i); rect(l, CGRectInset(r, 5, 5));
        snprintf(l, sizeof l, "r%d integral", i); rect(l, CGRectIntegral(r));
        snprintf(l, sizeof l, "r%d offset", i); rect(l, CGRectOffset(r, 2, -3));
        for (int j = 0; j < n; j++) {
            snprintf(l, sizeof l, "r%d union r%d", i, j); rect(l, CGRectUnion(r, rs[j]));
            snprintf(l, sizeof l, "r%d intersection r%d", i, j); rect(l, CGRectIntersection(r, rs[j]));
            printf("r%d r%d intersects=%d contains=%d equal=%d\n", i, j,
                   CGRectIntersectsRect(r, rs[j]), CGRectContainsRect(r, rs[j]), CGRectEqualToRect(r, rs[j]));
        }
        CGPoint ps[] = {{1, 2}, {4, 6}, {3.999, 5.999}, {5, -1}, {0, 0}, {7, 15}};
        printf("r%d contains points:", i);
        for (unsigned k = 0; k < sizeof ps / sizeof ps[0]; k++)
            printf(" %d", CGRectContainsPoint(r, ps[k]));
        printf("\n");
        for (int e = 0; e < 4; e++) {
            CGRect s, rem;
            CGRectDivide(r, &s, &rem, 1.5, (CGRectEdge)e);
            snprintf(l, sizeof l, "r%d divide %d slice", i, e); rect(l, s);
            snprintf(l, sizeof l, "r%d divide %d remainder", i, e); rect(l, rem);
            CGRectDivide(r, &s, &rem, 100, (CGRectEdge)e);
            snprintf(l, sizeof l, "r%d divide-big %d slice", i, e); rect(l, s);
            snprintf(l, sizeof l, "r%d divide-big %d remainder", i, e); rect(l, rem);
            CGRectDivide(r, &s, &rem, -1, (CGRectEdge)e);
            snprintf(l, sizeof l, "r%d divide-neg %d slice", i, e); rect(l, s);
            snprintf(l, sizeof l, "r%d divide-neg %d remainder", i, e); rect(l, rem);
        }
    }
    /* touching edges */
    CGRect a = CGRectMake(0, 0, 10, 10), b = CGRectMake(10, 0, 5, 5), c = CGRectMake(10, 10, 5, 5);
    rect("touch side", CGRectIntersection(a, b));
    printf("touch side intersects=%d\n", CGRectIntersectsRect(a, b));
    rect("touch corner", CGRectIntersection(a, c));
    printf("touch corner intersects=%d\n", CGRectIntersectsRect(a, c));
    printf("equal points: %d %d\n", CGPointEqualToPoint(CGPointMake(1, 2), CGPointMake(1, 2)),
           CGPointEqualToPoint(CGPointMake(1, 2), CGPointMake(1, 3)));
    printf("equal sizes: %d %d\n", CGSizeEqualToSize(CGSizeMake(1, 2), CGSizeMake(1, 2)),
           CGSizeEqualToSize(CGSizeMake(1, 2), CGSizeMake(-1, 2)));
    printf("equal rects neg: %d\n", CGRectEqualToRect(CGRectMake(0, 0, 10, 10), CGRectMake(10, 10, -10, -10)));
    printf("equal nulls: %d\n", CGRectEqualToRect(CGRectNull, CGRectMake(INFINITY, INFINITY, 5, 5)));

    /* dictionary representations */
    CFDictionaryRef d = CGRectCreateDictionaryRepresentation(CGRectMake(1, 2.5, -3, 4));
    cfdesc("rect dict", d);
    CGRect back;
    printf("rect from dict: %d", CGRectMakeWithDictionaryRepresentation(d, &back));
    rect("", back);
    CFRelease(d);
    d = CGPointCreateDictionaryRepresentation(CGPointMake(7, 8));
    cfdesc("point dict", d);
    CGPoint pt;
    printf("point from dict: %d", CGPointMakeWithDictionaryRepresentation(d, &pt));
    point("", pt);
    CFRelease(d);
    d = CGSizeCreateDictionaryRepresentation(CGSizeMake(9, 10));
    cfdesc("size dict", d);
    CGSize sz;
    printf("size from dict: %d %s %s\n", CGSizeMakeWithDictionaryRepresentation(d, &sz), g(sz.width), g(sz.height));
    printf("rect from size dict: %d\n", CGRectMakeWithDictionaryRepresentation(d, &back));
    CFRelease(d);
    /* integers as values */
    int iv = 3;
    CFNumberRef three = CFNumberCreate(NULL, kCFNumberIntType, &iv);
    const void *keys[] = {CFSTR("X"), CFSTR("Y")}, *vals[] = {three, three};
    d = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    printf("point from int dict: %d", CGPointMakeWithDictionaryRepresentation(d, &pt));
    point("", pt);
    CFRelease(d);
    CFRelease(three);
    printf("point from NULL dict: %d\n", CGPointMakeWithDictionaryRepresentation(NULL, &pt));
}

static void
transforms(void)
{
    xform("identity", CGAffineTransformIdentity);
    xform("make", CGAffineTransformMake(1, 2, 3, 4, 5, 6));
    xform("translation", CGAffineTransformMakeTranslation(3, -4));
    xform("scale", CGAffineTransformMakeScale(2, 0.5));
    double angles[] = {0, M_PI / 6, M_PI / 4, M_PI / 2, M_PI, 3 * M_PI / 2, 2 * M_PI, -M_PI / 3, 1};
    for (unsigned i = 0; i < sizeof angles / sizeof angles[0]; i++) {
        char l[40];
        snprintf(l, sizeof l, "rotation %u", i);
        xform12(l, CGAffineTransformMakeRotation(angles[i]));
        snprintf(l, sizeof l, "rotate %u", i);
        xform12(l, CGAffineTransformRotate(CGAffineTransformMake(1, 2, 3, 4, 5, 6), angles[i]));
    }
    xform("rotation pi/2 exact", CGAffineTransformMakeRotation(M_PI / 2));
    xform("rotation pi exact", CGAffineTransformMakeRotation(M_PI));
    CGAffineTransform m = CGAffineTransformMake(1, 2, 3, 4, 5, 6);
    printf("is identity: %d %d\n", CGAffineTransformIsIdentity(CGAffineTransformIdentity), CGAffineTransformIsIdentity(m));
    xform("translate", CGAffineTransformTranslate(m, 10, 20));
    xform("scale m", CGAffineTransformScale(m, 2, 3));
    xform("invert", CGAffineTransformInvert(m));
    xform("invert singular", CGAffineTransformInvert(CGAffineTransformMake(1, 2, 2, 4, 5, 6)));
    xform("invert scale", CGAffineTransformInvert(CGAffineTransformMakeScale(4, 0.25)));
    xform("concat", CGAffineTransformConcat(m, CGAffineTransformMake(7, 8, 9, 10, 11, 12)));
    printf("equal: %d %d\n", CGAffineTransformEqualToTransform(m, m),
           CGAffineTransformEqualToTransform(m, CGAffineTransformIdentity));
    point("apply point", CGPointApplyAffineTransform(CGPointMake(1, 1), m));
    CGSize s = CGSizeApplyAffineTransform(CGSizeMake(2, 3), m);
    printf("apply size: %s %s\n", g(s.width), g(s.height));
    rect("apply rect", CGRectApplyAffineTransform(CGRectMake(1, 2, 3, 4), m));
    rect("apply rect neg", CGRectApplyAffineTransform(CGRectMake(1, 2, -3, -4), CGAffineTransformMakeScale(-1, 1)));
    rect("apply null rect", CGRectApplyAffineTransform(CGRectNull, m));
    rect("apply infinite rect", CGRectApplyAffineTransform(CGRectInfinite, m));
    rect("apply rect rotation", CGRectApplyAffineTransform(CGRectMake(0, 0, 10, 20), CGAffineTransformMakeRotation(M_PI / 4)));

    CGAffineTransform ts[] = {
        CGAffineTransformIdentity, m, CGAffineTransformMakeRotation(M_PI / 6),
        CGAffineTransformMakeScale(-2, 3), CGAffineTransformMake(2, 0, 1, 3, 4, 5),
        CGAffineTransformMake(0, 1, -1, 0, 0, 0), CGAffineTransformMake(1, 2, 2, 4, 0, 0),
        CGAffineTransformMake(-1, 0, 0, -1, 7, 8),
    };
    for (unsigned i = 0; i < sizeof ts / sizeof ts[0]; i++) {
        CGAffineTransformComponents c = CGAffineTransformDecompose(ts[i]);
        printf("decompose %u: scale %.12g %.12g shear %.12g rotation %.12g translation %.12g %.12g\n", i,
               c.scale.width, c.scale.height, fabs(c.horizontalShear) < 1e-12 ? 0 : c.horizontalShear,
               fabs(c.rotation) < 1e-12 ? 0 : c.rotation, c.translation.dx, c.translation.dy);
        char l[40];
        snprintf(l, sizeof l, "recompose %u", i);
        xform12(l, CGAffineTransformMakeWithComponents(c));
    }
}


static void
dump_element(void *info, const CGPathElement *e)
{
    static const char *names[] = {"move", "line", "quad", "curve", "close"};
    static const int npoints[] = {1, 1, 2, 3, 0};
    printf(" %s", names[e->type]);
    for (int i = 0; i < npoints[e->type]; i++)
        printf(" %.10g,%.10g", fabs(e->points[i].x) < 1e-10 ? 0 : e->points[i].x,
               fabs(e->points[i].y) < 1e-10 ? 0 : e->points[i].y);
    (*(int *)info)++;
}

/* Below 1e-10 is rounding noise from trigonometry, not behaviour. */
static CGRect
denoise(CGRect r)
{
    CGFloat *v = &r.origin.x;
    for (int i = 0; i < 4; i++)
        if (fabs(v[i]) < 1e-10)
            v[i] = 0;
    return r;
}

static void
dump_path(const char *label, CGPathRef path)
{
    if (!path) {
        printf("%s: NULL\n", label);
        return;
    }
    int n = 0;
    printf("%s:", label);
    CGPathApply(path, &n, dump_element);
    printf(" (%d)\n", n);
    CGRect r;
    printf("%s empty=%d", label, CGPathIsEmpty(path));
    printf(" isrect=%d", CGPathIsRect(path, &r));
    if (CGPathIsRect(path, &r))
        printf(" {%.10g %.10g %.10g %.10g}", r.origin.x, r.origin.y, r.size.width, r.size.height);
    CGPoint cp = CGPathGetCurrentPoint(path);
    printf(" current=%.10g,%.10g", fabs(cp.x) < 1e-10 ? 0 : cp.x, fabs(cp.y) < 1e-10 ? 0 : cp.y);
    r = denoise(CGPathGetBoundingBox(path));
    printf(" box={%.10g %.10g %.10g %.10g}", r.origin.x, r.origin.y, r.size.width, r.size.height);
    r = denoise(CGPathGetPathBoundingBox(path));
    printf(" pathbox={%.10g %.10g %.10g %.10g}\n", r.origin.x, r.origin.y, r.size.width, r.size.height);
}

static void
paths(void)
{
    CGMutablePathRef p = CGPathCreateMutable();
    dump_path("empty", p);
    CGPathMoveToPoint(p, NULL, 1, 2);
    dump_path("move", p);
    CGPathAddLineToPoint(p, NULL, 10, 2);
    CGPathAddQuadCurveToPoint(p, NULL, 15, 5, 10, 10);
    CGPathAddCurveToPoint(p, NULL, 8, 12, 4, 12, 1, 10);
    CGPathCloseSubpath(p);
    dump_path("mixed", p);
    CGPathAddLineToPoint(p, NULL, 20, 20);
    dump_path("line after close", p);
    CGAffineTransform t = CGAffineTransformMake(2, 0, 0, 3, 5, 7);
    CGPathMoveToPoint(p, &t, 1, 1);
    CGPathAddLineToPoint(p, &t, 2, 2);
    dump_path("transformed", p);
    CGPathRelease(p);

    p = CGPathCreateMutable();
    CGPathAddLineToPoint(p, NULL, 3, 4);
    dump_path("line without move", p);
    CGPathRelease(p);

    dump_path("rect", CGPathCreateWithRect(CGRectMake(1, 2, 3, 4), NULL));
    dump_path("rect neg", CGPathCreateWithRect(CGRectMake(10, 20, -3, -4), NULL));
    dump_path("rect transformed", CGPathCreateWithRect(CGRectMake(1, 2, 3, 4), &t));
    dump_path("ellipse", CGPathCreateWithEllipseInRect(CGRectMake(0, 0, 20, 10), NULL));
    dump_path("circle", CGPathCreateWithEllipseInRect(CGRectMake(-5, -5, 10, 10), NULL));
    dump_path("rounded", CGPathCreateWithRoundedRect(CGRectMake(0, 0, 40, 20), 5, 3, NULL));
    dump_path("rounded 0", CGPathCreateWithRoundedRect(CGRectMake(0, 0, 40, 20), 0, 0, NULL));

    p = CGPathCreateMutable();
    CGPathAddArc(p, NULL, 50, 50, 10, 0, M_PI / 2, false);
    dump_path("arc ccw quarter", p);
    CGPathRelease(p);
    p = CGPathCreateMutable();
    CGPathAddArc(p, NULL, 50, 50, 10, 0, M_PI / 2, true);
    dump_path("arc cw 3/4", p);
    CGPathRelease(p);
    p = CGPathCreateMutable();
    CGPathAddArc(p, NULL, 0, 0, 10, 0.3, 2.5, false);
    dump_path("arc odd", p);
    CGPathRelease(p);
    p = CGPathCreateMutable();
    CGPathAddArc(p, NULL, 0, 0, 10, 0, 2 * M_PI, false);
    dump_path("arc full", p);
    CGPathRelease(p);
    p = CGPathCreateMutable();
    CGPathAddArc(p, NULL, 0, 0, 10, 0, 7, false);
    dump_path("arc over full", p);
    CGPathRelease(p);
    p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, 0, 0);
    CGPathAddArc(p, NULL, 20, 0, 5, M_PI, 0, true);
    dump_path("arc after move", p);
    CGPathRelease(p);
    p = CGPathCreateMutable();
    CGPathAddArc(p, NULL, 0, 0, 10, 1, 1, false);
    dump_path("arc zero sweep", p);
    CGPathRelease(p);
    p = CGPathCreateMutable();
    CGPathAddRelativeArc(p, NULL, 0, 0, 10, 0.5, -2);
    dump_path("relative arc", p);
    CGPathRelease(p);
    p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, 0, 0);
    CGPathAddArcToPoint(p, NULL, 10, 0, 10, 10, 3);
    CGPathAddArcToPoint(p, NULL, 10, 20, 0, 20, 100);
    CGPathAddArcToPoint(p, NULL, 0, 20, 0, 30, 2);
    dump_path("arc to point", p);
    CGPathRelease(p);
    p = CGPathCreateMutable();
    CGPathAddRect(p, NULL, CGRectMake(0, 0, 5, 5));
    CGRect rs[] = {CGRectMake(10, 10, 1, 1), CGRectMake(20, 20, 2, 2)};
    CGPathAddRects(p, NULL, rs, 2);
    CGPoint pts[] = {{0, 0}, {1, 5}, {2, 0}};
    CGPathAddLines(p, NULL, pts, 3);
    CGPathAddEllipseInRect(p, NULL, CGRectMake(0, 0, 4, 4));
    CGPathAddRoundedRect(p, NULL, CGRectMake(0, 0, 10, 10), 2, 2);
    dump_path("adds", p);
    CGMutablePathRef q = CGPathCreateMutable();
    CGPathMoveToPoint(q, NULL, 100, 100);
    CGPathAddPath(q, &t, p);
    dump_path("add path", q);
    printf("equal: %d %d\n", CGPathEqualToPath(p, p), CGPathEqualToPath(p, q));
    CGPathRef copy = CGPathCreateCopy(p);
    printf("copy equal: %d\n", CGPathEqualToPath(p, copy));
    dump_path("copy by transforming", CGPathCreateCopyByTransformingPath(p, &t));
    CGPathRelease(q);

    CGPathRef circle = CGPathCreateWithEllipseInRect(CGRectMake(0, 0, 10, 10), NULL);
    CGPoint probes[] = {{5, 5}, {0, 0}, {0.5, 5}, {10, 5}, {9.99, 5}, {5, 10}, {5, 0}, {1.5, 1.5}};
    printf("circle contains:");
    for (unsigned i = 0; i < sizeof probes / sizeof probes[0]; i++)
        printf(" %d", CGPathContainsPoint(circle, NULL, probes[i], false));
    printf("\n");
    CGMutablePathRef ring = CGPathCreateMutable();
    CGPathAddEllipseInRect(ring, NULL, CGRectMake(0, 0, 20, 20));
    CGPathAddEllipseInRect(ring, NULL, CGRectMake(5, 5, 10, 10));
    printf("ring contains winding/evenodd: %d %d %d %d\n",
           CGPathContainsPoint(ring, NULL, CGPointMake(10, 10), false),
           CGPathContainsPoint(ring, NULL, CGPointMake(10, 10), true),
           CGPathContainsPoint(ring, NULL, CGPointMake(2, 10), false),
           CGPathContainsPoint(ring, NULL, CGPointMake(2, 10), true));
    CGMutablePathRef open = CGPathCreateMutable();
    CGPathMoveToPoint(open, NULL, 0, 0);
    CGPathAddLineToPoint(open, NULL, 10, 0);
    CGPathAddLineToPoint(open, NULL, 10, 10);
    printf("open contains: %d %d\n", CGPathContainsPoint(open, NULL, CGPointMake(8, 2), false),
           CGPathContainsPoint(open, NULL, CGPointMake(2, 8), false));
    {
        /* (printed directly: Apple's short strings are tagged pointers, which describe as their contents) */
        CFStringRef name = CFCopyTypeIDDescription(CFGetTypeID(circle));
        char buf[64];
        CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        printf("path type: %s\n", buf);
        CFRelease(name);
    }
    printf("path type id same: %d\n", CFGetTypeID(circle) == CGPathGetTypeID());
    CGPathRelease(circle);
    CGPathRelease(ring);
    CGPathRelease(open);
    CGPathRelease(p);
    CGPathRelease(copy);
}

static void
cfstr(const char *label, CFStringRef str)
{
    char buf[256] = "NULL";
    if (str)
        CFStringGetCString(str, buf, sizeof buf, kCFStringEncodingUTF8);
    printf("%s: %s\n", label, buf);
}

static void
space_info(const char *label, CGColorSpaceRef cs)
{
    if (!cs) {
        printf("%s: NULL\n", label);
        return;
    }
    CFStringRef name = CGColorSpaceCopyName(cs);
    char nbuf[128] = "NULL";
    if (name)
        CFStringGetCString(name, nbuf, sizeof nbuf, kCFStringEncodingUTF8);
    CFDataRef icc = CGColorSpaceCopyICCData(cs);
    printf("%s: name=%s getname=%d model=%d n=%zu wide=%d hdr=%d pq=%d hlg=%d extended=%d output=%d icc=%d base=%d table=%zu\n",
           label, nbuf, CGColorSpaceGetName(cs) != NULL, CGColorSpaceGetModel(cs),
           CGColorSpaceGetNumberOfComponents(cs), CGColorSpaceIsWideGamutRGB(cs), CGColorSpaceIsHDR(cs),
           CGColorSpaceIsPQBased(cs), CGColorSpaceIsHLGBased(cs), CGColorSpaceUsesExtendedRange(cs),
           CGColorSpaceSupportsOutput(cs), icc != NULL, CGColorSpaceGetBaseColorSpace(cs) != NULL,
           CGColorSpaceGetColorTableCount(cs));
    if (name)
        CFRelease(name);
    if (icc)
        CFRelease(icc);
}

static void
color_info(const char *label, CGColorRef c)
{
    if (!c) {
        printf("%s: NULL\n", label);
        return;
    }
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *v = CGColorGetComponents(c);
    CFStringRef sname = CGColorSpaceCopyName(CGColorGetColorSpace(c));
    char nbuf[128] = "NULL";
    if (sname)
        CFStringGetCString(sname, nbuf, sizeof nbuf, kCFStringEncodingUTF8);
    printf("%s: space=%s n=%zu alpha=%.4f (", label, nbuf, n, CGColorGetAlpha(c));
    for (size_t i = 0; i < n; i++)
        printf("%s%.4f", i ? " " : "", fabs(v[i]) < 5e-5 ? 0 : v[i]);
    printf(")\n");
    if (sname)
        CFRelease(sname);
}

static void
colors(void)
{
    CFStringRef names[] = {
        kCGColorSpaceGenericGray, kCGColorSpaceGenericRGB, kCGColorSpaceGenericCMYK, kCGColorSpaceDisplayP3,
        kCGColorSpaceGenericRGBLinear, kCGColorSpaceAdobeRGB1998, kCGColorSpaceSRGB, kCGColorSpaceGenericGrayGamma2_2,
        kCGColorSpaceGenericXYZ, kCGColorSpaceGenericLab, kCGColorSpaceACESCGLinear, kCGColorSpaceITUR_709,
        kCGColorSpaceITUR_709_PQ, kCGColorSpaceITUR_709_HLG, kCGColorSpaceITUR_2020, kCGColorSpaceITUR_2020_sRGBGamma,
        kCGColorSpaceROMMRGB, kCGColorSpaceDCIP3, kCGColorSpaceLinearITUR_2020, kCGColorSpaceExtendedITUR_2020,
        kCGColorSpaceExtendedLinearITUR_2020, kCGColorSpaceLinearDisplayP3, kCGColorSpaceExtendedDisplayP3,
        kCGColorSpaceExtendedLinearDisplayP3, kCGColorSpaceITUR_2100_PQ, kCGColorSpaceITUR_2100_HLG,
        kCGColorSpaceDisplayP3_PQ, kCGColorSpaceDisplayP3_HLG, kCGColorSpaceExtendedSRGB, kCGColorSpaceLinearSRGB,
        kCGColorSpaceExtendedLinearSRGB, kCGColorSpaceExtendedGray, kCGColorSpaceLinearGray,
        kCGColorSpaceExtendedLinearGray, kCGColorSpaceCoreMedia709, CFSTR("kCGColorSpaceDeviceRGB"),
        CFSTR("kCGColorSpaceDeviceGray"), CFSTR("kCGColorSpaceDeviceCMYK"), CFSTR("bogus"),
    };
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++) {
        char l[160];
        CFStringGetCString(names[i], l, sizeof l, kCFStringEncodingUTF8);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(names[i]);
        space_info(l, cs);
        if (cs) {
            CGColorSpaceRef lin = CGColorSpaceCreateLinearized(cs), ext = CGColorSpaceCreateExtended(cs);
            CGColorSpaceRef el = CGColorSpaceCreateExtendedLinearized(cs), std = CGColorSpaceCreateCopyWithStandardRange(cs);
            char m[200];
            snprintf(m, sizeof m, "  %s linearized", l), space_info(m, lin);
            snprintf(m, sizeof m, "  %s extended", l), space_info(m, ext);
            snprintf(m, sizeof m, "  %s extended linearized", l), space_info(m, el);
            snprintf(m, sizeof m, "  %s standard range", l), space_info(m, std);
            CGColorSpaceRelease(lin), CGColorSpaceRelease(ext), CGColorSpaceRelease(el), CGColorSpaceRelease(std);
            CGColorSpaceRelease(cs);
        }
    }
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB(), gray = CGColorSpaceCreateDeviceGray();
    CGColorSpaceRef cmyk = CGColorSpaceCreateDeviceCMYK();
    space_info("device rgb", rgb);
    space_info("device gray", gray);
    space_info("device cmyk", cmyk);
    printf("device rgb shared: %d\n", rgb == CGColorSpaceCreateDeviceRGB());
    CGColorSpaceRef srgb1 = CGColorSpaceCreateWithName(kCGColorSpaceSRGB), srgb2 = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    printf("named shared: %d equal: %d\n", srgb1 == srgb2, CFEqual(srgb1, srgb2));
    printf("type ids: %d %d\n", CFGetTypeID(rgb) == CGColorSpaceGetTypeID(), CGColorSpaceGetTypeID() != CGPathGetTypeID());
    printf("rgb == srgb: %d\n", CFEqual(rgb, srgb1));
    CGFloat white[3] = {0.9505, 1.0, 1.089}, black[3] = {0, 0, 0}, gamma[3] = {1.8, 1.8, 1.8};
    CGFloat matrix[9] = {0.4497, 0.2446, 0.0252, 0.3163, 0.6720, 0.1412, 0.1845, 0.0833, 0.9227};
    space_info("calibrated rgb", CGColorSpaceCreateCalibratedRGB(white, black, gamma, matrix));
    space_info("calibrated gray", CGColorSpaceCreateCalibratedGray(white, black, 2.2));
    CGFloat range[4] = {-100, 100, -100, 100};
    space_info("lab", CGColorSpaceCreateLab(white, black, range));
    unsigned char table[6] = {255, 0, 0, 0, 0, 255};
    CGColorSpaceRef indexed = CGColorSpaceCreateIndexed(rgb, 1, table);
    space_info("indexed", indexed);
    unsigned char back[6] = {0};
    CGColorSpaceGetColorTable(indexed, back);
    printf("indexed table: %d %d %d %d %d %d\n", back[0], back[1], back[2], back[3], back[4], back[5]);
    space_info("indexed bad", CGColorSpaceCreateIndexed(rgb, 300, table));
    space_info("pattern", CGColorSpaceCreatePattern(rgb));
    space_info("pattern uncolored", CGColorSpaceCreatePattern(NULL));
    CFDataRef icc = CGColorSpaceCopyICCData(srgb1);
    CGColorSpaceRef fromicc = CGColorSpaceCreateWithICCData(icc);
    space_info("from srgb icc", fromicc);
    CFDataRef garbage = CFDataCreate(NULL, (const UInt8 *)"not an icc profile at all", 25);
    space_info("from garbage icc", CGColorSpaceCreateWithICCData(garbage));
    CFPropertyListRef plist = CGColorSpaceCopyPropertyList(srgb1);
    printf("srgb plist type: %s\n", !plist ? "NULL" : CFGetTypeID(plist) == CFStringGetTypeID() ? "string" :
           CFGetTypeID(plist) == CFDataGetTypeID() ? "data" : CFGetTypeID(plist) == CFDictionaryGetTypeID() ? "dict" : "other");
    if (plist && CFGetTypeID(plist) == CFStringGetTypeID())
        cfstr("srgb plist", plist);
    space_info("from plist", plist ? CGColorSpaceCreateWithPropertyList(plist) : NULL);

    /* colors */
    CGFloat comps[4] = {1, 0.5, 0.25, 0.75};
    color_info("create rgb", CGColorCreate(rgb, comps));
    color_info("create gray", CGColorCreate(gray, comps));
    color_info("create null space", CGColorCreate(NULL, comps));
    color_info("generic rgb", CGColorCreateGenericRGB(0.2, 0.4, 0.6, 0.8));
    color_info("generic gray", CGColorCreateGenericGray(0.3, 1));
    color_info("generic cmyk", CGColorCreateGenericCMYK(0.1, 0.2, 0.3, 0.4, 0.5));
    color_info("gray gamma 2.2", CGColorCreateGenericGrayGamma2_2(0.5, 1));
    color_info("srgb", CGColorCreateSRGB(1, 0, 0, 1));
    color_info("srgb extended", CGColorCreateSRGB(1.5, -0.2, 0, 2));
    color_info("constant white", CGColorGetConstantColor(kCGColorWhite));
    color_info("constant black", CGColorGetConstantColor(kCGColorBlack));
    color_info("constant clear", CGColorGetConstantColor(kCGColorClear));
    color_info("constant bogus", CGColorGetConstantColor(CFSTR("bogus")));
    cfstr("kCGColorWhite", kCGColorWhite);
    cfstr("kCGColorSpaceSRGB", kCGColorSpaceSRGB);
    cfstr("kCGColorSpaceDisplayP3", kCGColorSpaceDisplayP3);
    cfstr("kCGColorSpaceExtendedRange", kCGColorSpaceExtendedRange);
    CGColorRef red = CGColorCreateSRGB(1, 0, 0, 1);
    color_info("copy with alpha", CGColorCreateCopyWithAlpha(red, 0.25));
    color_info("copy with alpha 2", CGColorCreateCopyWithAlpha(red, 2));
    printf("equal: %d %d %d\n", CGColorEqualToColor(red, CGColorCreateSRGB(1, 0, 0, 1)),
           CGColorEqualToColor(red, CGColorCreateSRGB(1, 0, 0, 0.5)),
           CGColorEqualToColor(red, CGColorCreateGenericRGB(1, 0, 0, 1)));
    printf("color type: %d\n", CFGetTypeID(red) == CGColorGetTypeID());
    CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGColorSpaceRef linear = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    CGColorSpaceRef ext = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    CGColorSpaceRef gen = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    CGColorSpaceRef ggray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    CGColorSpaceRef lgray = CGColorSpaceCreateWithName(kCGColorSpaceLinearGray);
    CGColorSpaceRef adobe = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
    CGColorSpaceRef targets[] = {p3, linear, ext, gen, ggray, lgray, adobe, srgb1, rgb, gray};
    const char *tnames[] = {"p3", "linear srgb", "extended srgb", "generic rgb", "gray 2.2", "linear gray",
                            "adobe", "srgb", "device rgb", "device gray"};
    CGColorRef sources[] = {red, CGColorCreateSRGB(0.5, 0.5, 0.5, 1), CGColorCreateSRGB(0.2, 0.7, 0.9, 0.5),
                            CGColorCreateGenericGray(0.5, 1)};
    for (unsigned si = 0; si < 4; si++)
        for (unsigned ti = 0; ti < sizeof targets / sizeof targets[0]; ti++) {
            char l[80];
            if (si == 0 && targets[ti] == gen)
                continue;  /* sRGB red is outside Generic RGB: clipping out-of-gamut colour is the CMM's choice */
            snprintf(l, sizeof l, "match %u to %s", si, tnames[ti]);
            color_info(l, CGColorCreateCopyByMatchingToColorSpace(targets[ti], kCGRenderingIntentDefault, sources[si], NULL));
        }
    CGColorRef p3red = CGColorCreate(p3, (CGFloat[]){1, 0, 0, 1});
    color_info("p3 red to srgb", CGColorCreateCopyByMatchingToColorSpace(srgb1, kCGRenderingIntentDefault, p3red, NULL));
    color_info("p3 red to extended srgb", CGColorCreateCopyByMatchingToColorSpace(ext, kCGRenderingIntentDefault, p3red, NULL));
    /* descriptions and property lists */
    CFStringRef dnames[] = {kCGColorSpaceSRGB, kCGColorSpaceDisplayP3, kCGColorSpaceExtendedSRGB, kCGColorSpaceGenericRGB,
                            kCGColorSpaceGenericGray, kCGColorSpaceGenericGrayGamma2_2, kCGColorSpaceGenericCMYK,
                            kCGColorSpaceGenericLab, kCGColorSpaceGenericXYZ, kCGColorSpaceITUR_2100_PQ,
                            kCGColorSpaceLinearGray, kCGColorSpaceCoreMedia709, CFSTR("kCGColorSpaceDisplayP3_PQ_EOTF")};
    for (unsigned i = 0; i < sizeof dnames / sizeof dnames[0]; i++) {
        char l[160], m[200];
        CFStringGetCString(dnames[i], l, sizeof l, kCFStringEncodingUTF8);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(dnames[i]);
        snprintf(m, sizeof m, "desc %s", l);
        cfdesc(m, cs);
        CFPropertyListRef pl = CGColorSpaceCopyPropertyList(cs);
        snprintf(m, sizeof m, "plist %s", l);
        if (pl && CFGetTypeID(pl) == CFNumberGetTypeID()) {
            int id;
            CFNumberGetValue(pl, kCFNumberIntType, &id);
            printf("%s: number %d\n", m, id);
        } else if (pl && CFGetTypeID(pl) == CFStringGetTypeID()) {
            cfstr(m, pl);
        } else {
            printf("%s: %s\n", m, !pl ? "NULL" : CFGetTypeID(pl) == CFDataGetTypeID() ? "data" : "other");
        }
        CGColorSpaceRef back = pl ? CGColorSpaceCreateWithPropertyList(pl) : NULL;
        printf("%s round trip: %d\n", m, back == cs);
        CFStringRef nm = CGColorSpaceCopyName(cs);
        snprintf(m, sizeof m, "name %s", l);
        cfstr(m, nm);
    }
    cfdesc("desc device rgb", rgb);
    cfdesc("desc device gray", gray);
    cfdesc("desc device cmyk", cmyk);
    cfdesc("desc indexed", indexed);
    cfdesc("desc pattern", CGColorSpaceCreatePattern(NULL));
    cfdesc("desc calibrated gray", CGColorSpaceCreateCalibratedGray(white, black, 2.2));
    for (int k = 0; k < 3; k++) {
        CGColorSpaceRef dev = k == 0 ? rgb : k == 1 ? gray : cmyk;
        CFPropertyListRef pl = CGColorSpaceCopyPropertyList(dev);
        printf("device plist %d: ", k);
        if (pl && CFGetTypeID(pl) == CFStringGetTypeID())
            cfstr("string", pl);
        else
            printf("%s\n", pl ? "other" : "NULL");
    }
    cfdesc("desc color srgb", CGColorCreateSRGB(1, 0.5, 0.25, 1));
    cfdesc("desc color device", CGColorCreate(rgb, comps));
    cfdesc("desc color white", CGColorGetConstantColor(kCGColorWhite));
    cfdesc("desc color generic gray", CGColorCreateGenericGray(0.3, 1));
    cfdesc("desc color cmyk", CGColorCreateGenericCMYK(0.1, 0.2, 0.3, 0.4, 0.5));
    cfdesc("desc color extended", CGColorCreate(ext, (CGFloat[]){0.123456789, 1.5, -0.2, 1}));
    cfdesc("desc color p3", CGColorCreate(p3, (CGFloat[]){0.5, 1, 0.2, 1}));
    color_info("p3 red to srgb perceptual", CGColorCreateCopyByMatchingToColorSpace(srgb1, kCGRenderingIntentPerceptual, p3red, NULL));
}

int
main(int argc, char **argv)
{
    if (argc < 2 || strcmp(argv[1], "--no-path")) {
        Dl_info info;
        printf("CoreGraphics: %s\n", dladdr((void *)CGRectUnion, &info) ? info.dli_fname : "?");
    }
    geometry();
    transforms();
    paths();
    colors();
    return 0;
}
