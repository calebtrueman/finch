/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Foundation's geometry (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSGeometry.h>: the rect, point and size functions, their
 * string forms ("{{1, 2}, {3, 4}}", with %g as Apple's), and NSValue's
 * geometry boxes.
 */
#import <Foundation/Foundation.h>
#include <math.h>

#include "Foundation_Finch.h"

const NSPoint NSZeroPoint = { 0, 0 };
const NSSize NSZeroSize = { 0, 0 };
const NSRect NSZeroRect = { { 0, 0 }, { 0, 0 } };
const NSEdgeInsets NSEdgeInsetsZero = { 0, 0, 0, 0 };

BOOL NSEqualPoints(NSPoint a, NSPoint b) { return a.x == b.x && a.y == b.y; }
BOOL NSEqualSizes(NSSize a, NSSize b) { return a.width == b.width && a.height == b.height; }
BOOL NSEqualRects(NSRect a, NSRect b) { return NSEqualPoints(a.origin, b.origin) && NSEqualSizes(a.size, b.size); }
BOOL NSIsEmptyRect(NSRect r) { return !(r.size.width > 0 && r.size.height > 0); }
BOOL NSEdgeInsetsEqual(NSEdgeInsets a, NSEdgeInsets b)
{
    return a.top == b.top && a.left == b.left && a.bottom == b.bottom && a.right == b.right;
}

NSRect
NSInsetRect(NSRect r, CGFloat dx, CGFloat dy)
{
    return NSMakeRect(r.origin.x + dx, r.origin.y + dy, r.size.width - 2 * dx, r.size.height - 2 * dy);
}

NSRect
NSIntegralRect(NSRect r)
{
    if (NSIsEmptyRect(r)) return NSZeroRect;
    CGFloat x0 = floor(r.origin.x), y0 = floor(r.origin.y);
    CGFloat x1 = ceil(NSMaxX(r)), y1 = ceil(NSMaxY(r));
    return NSMakeRect(x0, y0, x1 - x0, y1 - y0);
}

NSRect
NSIntegralRectWithOptions(NSRect r, NSAlignmentOptions opts)
{
    return NSIntegralRect(r);
}

NSRect
NSUnionRect(NSRect a, NSRect b)
{
    if (NSIsEmptyRect(a)) return NSIsEmptyRect(b) ? NSZeroRect : b;
    if (NSIsEmptyRect(b)) return a;
    CGFloat x0 = MIN(NSMinX(a), NSMinX(b)), y0 = MIN(NSMinY(a), NSMinY(b));
    CGFloat x1 = MAX(NSMaxX(a), NSMaxX(b)), y1 = MAX(NSMaxY(a), NSMaxY(b));
    return NSMakeRect(x0, y0, x1 - x0, y1 - y0);
}

NSRect
NSIntersectionRect(NSRect a, NSRect b)
{
    CGFloat x0 = MAX(NSMinX(a), NSMinX(b)), y0 = MAX(NSMinY(a), NSMinY(b));
    CGFloat x1 = MIN(NSMaxX(a), NSMaxX(b)), y1 = MIN(NSMaxY(a), NSMaxY(b));
    if (x1 <= x0 || y1 <= y0) return NSZeroRect;
    return NSMakeRect(x0, y0, x1 - x0, y1 - y0);
}

NSRect NSOffsetRect(NSRect r, CGFloat dx, CGFloat dy) { return NSMakeRect(r.origin.x + dx, r.origin.y + dy, r.size.width, r.size.height); }

void
NSDivideRect(NSRect r, NSRect *slice, NSRect *rem, CGFloat amount, NSRectEdge edge)
{
    NSRect s = r, m = r;
    switch (edge) {
    case NSMinXEdge: amount = MIN(amount, r.size.width); s.size.width = amount; m.origin.x += amount; m.size.width -= amount; break;
    case NSMaxXEdge: amount = MIN(amount, r.size.width); s.origin.x = NSMaxX(r) - amount; s.size.width = amount; m.size.width -= amount; break;
    case NSMinYEdge: amount = MIN(amount, r.size.height); s.size.height = amount; m.origin.y += amount; m.size.height -= amount; break;
    case NSMaxYEdge: amount = MIN(amount, r.size.height); s.origin.y = NSMaxY(r) - amount; s.size.height = amount; m.size.height -= amount; break;
    }
    if (slice) *slice = s;
    if (rem) *rem = m;
}

BOOL NSPointInRect(NSPoint p, NSRect r) { return p.x >= NSMinX(r) && p.x < NSMaxX(r) && p.y >= NSMinY(r) && p.y < NSMaxY(r); }
BOOL
NSMouseInRect(NSPoint p, NSRect r, BOOL flipped)
{
    if (flipped) return p.x >= NSMinX(r) && p.x < NSMaxX(r) && p.y >= NSMinY(r) && p.y < NSMaxY(r);
    return p.x >= NSMinX(r) && p.x < NSMaxX(r) && p.y > NSMinY(r) && p.y <= NSMaxY(r);
}
BOOL NSContainsRect(NSRect a, NSRect b)
{
    return !NSIsEmptyRect(b) && NSMinX(a) <= NSMinX(b) && NSMinY(a) <= NSMinY(b) && NSMaxX(a) >= NSMaxX(b) && NSMaxY(a) >= NSMaxY(b);
}
BOOL NSIntersectsRect(NSRect a, NSRect b) { return !NSIsEmptyRect(NSIntersectionRect(a, b)); }

NSString *NSStringFromPoint(NSPoint p) { return [NSString stringWithFormat:@"{%g, %g}", p.x, p.y]; }
NSString *NSStringFromSize(NSSize s) { return [NSString stringWithFormat:@"{%g, %g}", s.width, s.height]; }
NSString *
NSStringFromRect(NSRect r)
{
    return [NSString stringWithFormat:@"{%@, %@}", NSStringFromPoint(r.origin), NSStringFromSize(r.size)];
}

/* The numbers in a string, in order, as Apple's parsing reads them. */
static NSUInteger
numbers(NSString *s, double *out, NSUInteger max)
{
    const char *p = [s UTF8String];
    NSUInteger n = 0;
    while (p && *p && n < max) {
        if (strchr("0123456789-+.", *p)) {
            char *end;
            double v = strtod(p, &end);
            if (end != p) { out[n++] = v; p = end; continue; }
        }
        p++;
    }
    return n;
}

NSPoint NSPointFromString(NSString *s) { double v[2] = { 0, 0 }; numbers(s, v, 2); return NSMakePoint(v[0], v[1]); }
NSSize NSSizeFromString(NSString *s) { double v[2] = { 0, 0 }; numbers(s, v, 2); return NSMakeSize(v[0], v[1]); }
NSRect NSRectFromString(NSString *s) { double v[4] = { 0, 0, 0, 0 }; numbers(s, v, 4); return NSMakeRect(v[0], v[1], v[2], v[3]); }

@implementation NSValue (NSValueGeometryExtensions)
+ (NSValue *)valueWithPoint:(NSPoint)p { return [self valueWithBytes:&p objCType:@encode(NSPoint)]; }
+ (NSValue *)valueWithSize:(NSSize)s { return [self valueWithBytes:&s objCType:@encode(NSSize)]; }
+ (NSValue *)valueWithRect:(NSRect)r { return [self valueWithBytes:&r objCType:@encode(NSRect)]; }
+ (NSValue *)valueWithEdgeInsets:(NSEdgeInsets)e { return [self valueWithBytes:&e objCType:@encode(NSEdgeInsets)]; }
- (NSPoint)pointValue { NSPoint p = NSZeroPoint; [self getValue:&p size:sizeof(p)]; return p; }
- (NSSize)sizeValue { NSSize s = NSZeroSize; [self getValue:&s size:sizeof(s)]; return s; }
- (NSRect)rectValue { NSRect r = NSZeroRect; [self getValue:&r size:sizeof(r)]; return r; }
- (NSEdgeInsets)edgeInsetsValue { NSEdgeInsets e = NSEdgeInsetsZero; [self getValue:&e size:sizeof(e)]; return e; }
@end
