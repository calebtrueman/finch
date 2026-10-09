/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSGradient: colour stops in a colour space (extended sRGB unless given),
 * drawn as a CGGradient. As Apple's, stops are sorted by location, keep the
 * colours they were given, and interpolate premultiplied.
 */
#import "AppKitDrawing.h"
#include <math.h>

@implementation NSGradient {
    NSColorSpace *_space;
    NSInteger _n;
    NSColor **_colors;     /* as given */
    CGFloat *_locations;
    CGFloat *_comps;       /* converted to _space, with alpha: (ncomp + 1) per stop */
    CGGradientRef _cg;
}

- (instancetype)initWithColors:(NSArray<NSColor *> *)colorArray atLocations:(const CGFloat *)locations colorSpace:(NSColorSpace *)colorSpace
{
    return [self _initWithColors:colorArray locations:locations space:colorSpace];
}

- (instancetype)_initWithColors:(NSArray<NSColor *> *)colorArray locations:(const CGFloat *)locations space:(NSColorSpace *)colorSpace
{
    if (!(self = [super init]))
        return nil;
    NSInteger n = (NSInteger)colorArray.count;
    if (n < 1) {
        [self release];
        return nil;
    }
    _space = [(colorSpace ?: [NSColorSpace extendedSRGBColorSpace]) retain];
    BOOL single = n == 1;
    _n = single ? 2 : n;
    _colors = calloc((size_t)_n, sizeof(NSColor *));
    _locations = calloc((size_t)_n, sizeof(CGFloat));
    NSInteger *order = malloc(sizeof(NSInteger) * (size_t)_n);
    for (NSInteger i = 0; i < _n; i++) {
        order[i] = single ? 0 : i;
        _locations[i] = single ? (CGFloat)i : locations ? locations[i] : (n > 1 ? (CGFloat)i / (n - 1) : 0);
    }
    /* stable sort by location */
    for (NSInteger i = 1; i < _n; i++)
        for (NSInteger j = i; j > 0 && _locations[j - 1] > _locations[j]; j--) {
            CGFloat t = _locations[j];
            _locations[j] = _locations[j - 1], _locations[j - 1] = t;
            NSInteger o = order[j];
            order[j] = order[j - 1], order[j - 1] = o;
        }
    NSInteger nc = _space.numberOfColorComponents + 1;
    _comps = calloc((size_t)(_n * nc), sizeof(CGFloat));
    for (NSInteger i = 0; i < _n; i++) {
        NSColor *c = colorArray[(NSUInteger)order[i]];
        _colors[i] = [c retain];
        NSColor *conv = [c colorUsingColorSpace:_space];
        if (conv && conv.numberOfComponents == nc)
            [conv getComponents:_comps + i * nc];
        else
            _comps[i * nc + nc - 1] = 1;
    }
    free(order);
    return self;
}

- (instancetype)initWithColors:(NSArray<NSColor *> *)colorArray
{
    return [self _initWithColors:colorArray locations:NULL space:nil];
}

- (instancetype)initWithStartingColor:(NSColor *)startingColor endingColor:(NSColor *)endingColor
{
    if (!startingColor || !endingColor) {
        [self release];
        return nil;
    }
    return [self initWithColors:@[ startingColor, endingColor ]];
}

- (instancetype)initWithColorsAndLocations:(NSColor *)firstColor, ...
{
    NSMutableArray *colors = [NSMutableArray array];
    NSMutableData *locs = [NSMutableData data];
    va_list ap;
    va_start(ap, firstColor);
    for (NSColor *c = firstColor; c; c = va_arg(ap, NSColor *)) {
        CGFloat l = va_arg(ap, double);
        [colors addObject:c];
        [locs appendBytes:&l length:sizeof l];
    }
    va_end(ap);
    return [self _initWithColors:colors locations:locs.bytes space:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSArray *colors = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSColor class], nil] forKey:@"NSColors"];
    NSArray *locs = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSNumber class], nil] forKey:@"NSLocations"];
    NSColorSpace *space = [coder decodeObjectOfClass:[NSColorSpace class] forKey:@"NSColorSpace"];
    CGFloat *l = NULL;
    if (locs.count == colors.count && locs.count) {
        l = malloc(sizeof(CGFloat) * locs.count);
        for (NSUInteger i = 0; i < locs.count; i++)
            l[i] = [locs[i] doubleValue];
    }
    self = [self _initWithColors:colors locations:l space:space];
    free(l);
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSMutableArray *colors = [NSMutableArray array], *locs = [NSMutableArray array];
    for (NSInteger i = 0; i < _n; i++) {
        [colors addObject:_colors[i]];
        [locs addObject:@(_locations[i])];
    }
    [coder encodeObject:colors forKey:@"NSColors"];
    [coder encodeObject:locs forKey:@"NSLocations"];
    [coder encodeObject:_space forKey:@"NSColorSpace"];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (void)dealloc
{
    for (NSInteger i = 0; i < _n; i++)
        [_colors[i] release];
    free(_colors);
    free(_locations);
    free(_comps);
    [_space release];
    CGGradientRelease(_cg);
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (NSString *)description { return [NSString stringWithFormat:@"<NSGradient: %p>", self]; }

/* MARK: Stops */

- (NSColorSpace *)colorSpace { return _space; }
- (NSInteger)numberOfColorStops { return _n; }

- (void)getColor:(NSColor **)color location:(CGFloat *)location atIndex:(NSInteger)index
{
    if (index < 0 || index >= _n)
        return;  /* Apple's doesn't raise */
    if (color)
        *color = _colors[index];
    if (location)
        *location = _locations[index];
}

- (NSColor *)interpolatedColorAtLocation:(CGFloat)location
{
    NSInteger nc = _space.numberOfColorComponents + 1, a = nc - 1;
    CGFloat out[6];
    NSInteger i = 0;
    if (location <= _locations[0] || _n == 1) {
        memcpy(out, _comps, sizeof(CGFloat) * (size_t)nc);
    } else if (location >= _locations[_n - 1]) {
        memcpy(out, _comps + (_n - 1) * nc, sizeof(CGFloat) * (size_t)nc);
    } else {
        while (i + 1 < _n && _locations[i + 1] < location)
            i++;
        CGFloat span = _locations[i + 1] - _locations[i];
        CGFloat t = span > 0 ? (location - _locations[i]) / span : 0;
        const CGFloat *p = _comps + i * nc, *q = _comps + (i + 1) * nc;
        out[a] = p[a] * (1 - t) + q[a] * t;
        for (NSInteger k = 0; k < a; k++) {
            CGFloat v = p[k] * p[a] * (1 - t) + q[k] * q[a] * t;
            out[k] = out[a] > 0 ? v / out[a] : 0;
        }
    }
    return FinchGradientColor(_space, out, nc);
}

/* MARK: Drawing */

- (CGGradientRef)_cgGradient
{
    if (!_cg && _space.CGColorSpace)
        _cg = CGGradientCreateWithColorComponents(_space.CGColorSpace, _comps, _locations, (size_t)_n);
    return _cg;
}

- (void)drawFromPoint:(NSPoint)startingPoint toPoint:(NSPoint)endingPoint options:(NSGradientDrawingOptions)options
{
    CGContextRef c = FinchCurrentCGContext();
    CGGradientRef g = [self _cgGradient];
    if (c && g)
        CGContextDrawLinearGradient(c, g, NSPointToCGPoint(startingPoint), NSPointToCGPoint(endingPoint),
                                    (CGGradientDrawingOptions)options);
}

- (void)drawFromCenter:(NSPoint)startCenter radius:(CGFloat)startRadius toCenter:(NSPoint)endCenter radius:(CGFloat)endRadius
               options:(NSGradientDrawingOptions)options
{
    CGContextRef c = FinchCurrentCGContext();
    CGGradientRef g = [self _cgGradient];
    if (c && g)
        CGContextDrawRadialGradient(c, g, NSPointToCGPoint(startCenter), startRadius, NSPointToCGPoint(endCenter), endRadius,
                                    (CGGradientDrawingOptions)options);
}

/* The line through rect's centre at angle, long enough that its ends touch the corners. */
static void
angle_points(NSRect rect, CGFloat angle, NSPoint *start, NSPoint *end)
{
    double r = angle * M_PI / 180, dx = cos(r), dy = sin(r);
    double half = (fabs(rect.size.width * dx) + fabs(rect.size.height * dy)) / 2;
    NSPoint mid = NSMakePoint(NSMidX(rect), NSMidY(rect));
    *start = NSMakePoint(mid.x - dx * half, mid.y - dy * half);
    *end = NSMakePoint(mid.x + dx * half, mid.y + dy * half);
}

- (void)drawInRect:(NSRect)rect angle:(CGFloat)angle
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || NSIsEmptyRect(rect))
        return;
    NSPoint s, e;
    angle_points(rect, angle, &s, &e);
    CGContextSaveGState(c);
    CGContextClipToRect(c, NSRectToCGRect(rect));
    [self drawFromPoint:s toPoint:e options:NSGradientDrawsBeforeStartingLocation | NSGradientDrawsAfterEndingLocation];
    CGContextRestoreGState(c);
}

- (void)drawInBezierPath:(NSBezierPath *)path angle:(CGFloat)angle
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || path.isEmpty)
        return;
    NSPoint s, e;
    angle_points(path.bounds, angle, &s, &e);
    CGContextSaveGState(c);
    [path addClip];
    [self drawFromPoint:s toPoint:e options:NSGradientDrawsBeforeStartingLocation | NSGradientDrawsAfterEndingLocation];
    CGContextRestoreGState(c);
}

/* Radial in a rect: the centre at relativeCenterPosition (-1..1 across the rect), out to its farthest corner. */
static void
radial_in(NSGradient *g, NSRect rect, NSPoint rel)
{
    NSPoint center = NSMakePoint(NSMidX(rect) + rel.x * rect.size.width / 2, NSMidY(rect) + rel.y * rect.size.height / 2);
    CGFloat dx = fmax(fabs(center.x - NSMinX(rect)), fabs(NSMaxX(rect) - center.x));
    CGFloat dy = fmax(fabs(center.y - NSMinY(rect)), fabs(NSMaxY(rect) - center.y));
    [g drawFromCenter:center radius:0 toCenter:center radius:hypot(dx, dy)
              options:NSGradientDrawsBeforeStartingLocation | NSGradientDrawsAfterEndingLocation];
}

- (void)drawInRect:(NSRect)rect relativeCenterPosition:(NSPoint)relativeCenterPosition
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || NSIsEmptyRect(rect))
        return;
    CGContextSaveGState(c);
    CGContextClipToRect(c, NSRectToCGRect(rect));
    radial_in(self, rect, relativeCenterPosition);
    CGContextRestoreGState(c);
}

- (void)drawInBezierPath:(NSBezierPath *)path relativeCenterPosition:(NSPoint)relativeCenterPosition
{
    CGContextRef c = FinchCurrentCGContext();
    if (!c || path.isEmpty)
        return;
    CGContextSaveGState(c);
    [path addClip];
    radial_in(self, path.bounds, relativeCenterPosition);
    CGContextRestoreGState(c);
}

@end
