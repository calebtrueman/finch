/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The layer kinds: shape, gradient, text, replicator, scroll, tiled,
 * transform and emitter layers, the emitter cell, and the constraint layout
 * manager. Defaults are Core Animation's. The shape, gradient and text
 * layers draw (through CoreGraphics and CoreText) in CALayer's render pass;
 * the replicator draws its copies; the emitter keeps its cells but emits
 * nothing, as there's no animation clock yet.
 */
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>

@interface CALayer (FinchPrivate)
- (void)_finchRenderInContext:(CGContextRef)cg;
- (void)_finchDrawContent:(CGContextRef)cg;
@end

static CGColorRef
srgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    return CGColorCreateSRGB(r, g, b, a);
}

static void
set_color(CGColorRef *slot, CGColorRef c)
{
    CGColorRetain(c);
    CGColorRelease(*slot);
    *slot = c;
}

#define COPY_PROP(type, get, set, ivar)                 \
    -(type)get { return ivar; }                         \
    -(void)set:(type)v { [ivar autorelease]; ivar = [v copy]; }
#define SCALAR_PROP(type, get, set, ivar) \
    -(type)get { return ivar; }           \
    -(void)set:(type)v { ivar = v; }
#define COLOR_PROP(get, set, ivar)        \
    -(CGColorRef)get { return ivar; }     \
    -(void)set:(CGColorRef)c { set_color(&ivar, c); }

#pragma mark CAShapeLayer

@implementation CAShapeLayer {
    CGPathRef _path;
    CGColorRef _fillColor, _strokeColor;
    CAShapeLayerFillRule _fillRule;
    CAShapeLayerLineCap _lineCap;
    CAShapeLayerLineJoin _lineJoin;
    CGFloat _lineWidth, _miterLimit, _strokeStart, _strokeEnd, _lineDashPhase;
    NSArray<NSNumber *> *_lineDashPattern;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _fillColor = srgb(0, 0, 0, 1);
        _fillRule = [kCAFillRuleNonZero copy];
        _lineCap = [kCALineCapButt copy];
        _lineJoin = [kCALineJoinMiter copy];
        _lineWidth = 1;
        _miterLimit = 10;
        _strokeEnd = 1;
    }
    return self;
}

- (void)dealloc
{
    CGPathRelease(_path);
    CGColorRelease(_fillColor);
    CGColorRelease(_strokeColor);
    [_fillRule release];
    [_lineCap release];
    [_lineJoin release];
    [_lineDashPattern release];
    [super dealloc];
}

- (CGPathRef)path { return _path; }
- (void)setPath:(CGPathRef)p
{
    CGPathRef copy = p ? CGPathCreateCopy(p) : NULL;
    CGPathRelease(_path);
    _path = copy;
}
COLOR_PROP(fillColor, setFillColor, _fillColor)
COLOR_PROP(strokeColor, setStrokeColor, _strokeColor)
COPY_PROP(CAShapeLayerFillRule, fillRule, setFillRule, _fillRule)
COPY_PROP(CAShapeLayerLineCap, lineCap, setLineCap, _lineCap)
COPY_PROP(CAShapeLayerLineJoin, lineJoin, setLineJoin, _lineJoin)
COPY_PROP(NSArray *, lineDashPattern, setLineDashPattern, _lineDashPattern)
SCALAR_PROP(CGFloat, lineWidth, setLineWidth, _lineWidth)
SCALAR_PROP(CGFloat, miterLimit, setMiterLimit, _miterLimit)
SCALAR_PROP(CGFloat, strokeStart, setStrokeStart, _strokeStart)
SCALAR_PROP(CGFloat, strokeEnd, setStrokeEnd, _strokeEnd)
SCALAR_PROP(CGFloat, lineDashPhase, setLineDashPhase, _lineDashPhase)

- (void)_finchDrawContent:(CGContextRef)cg
{
    if (!_path)
        return;
    CGContextSaveGState(cg);
    if (_fillColor) {
        CGContextAddPath(cg, _path);
        CGContextSetFillColorWithColor(cg, _fillColor);
        if ([_fillRule isEqualToString:kCAFillRuleEvenOdd])
            CGContextEOFillPath(cg);
        else
            CGContextFillPath(cg);
    }
    if (_strokeColor && _lineWidth > 0 && _strokeEnd > _strokeStart) {
        CGContextAddPath(cg, _path);
        CGContextSetStrokeColorWithColor(cg, _strokeColor);
        CGContextSetLineWidth(cg, _lineWidth);
        CGContextSetMiterLimit(cg, _miterLimit);
        CGContextSetLineCap(cg, [_lineCap isEqualToString:kCALineCapRound]    ? kCGLineCapRound
                                : [_lineCap isEqualToString:kCALineCapSquare] ? kCGLineCapSquare
                                                                              : kCGLineCapButt);
        CGContextSetLineJoin(cg, [_lineJoin isEqualToString:kCALineJoinRound]    ? kCGLineJoinRound
                                 : [_lineJoin isEqualToString:kCALineJoinBevel] ? kCGLineJoinBevel
                                                                                : kCGLineJoinMiter);
        NSUInteger n = [_lineDashPattern count];
        if (n) {
            CGFloat dashes[n];
            for (NSUInteger i = 0; i < n; i++)
                dashes[i] = [_lineDashPattern[i] doubleValue];
            CGContextSetLineDash(cg, _lineDashPhase, dashes, n);
        }
        CGContextStrokePath(cg);
    }
    CGContextRestoreGState(cg);
}

@end

#pragma mark CAGradientLayer

@implementation CAGradientLayer {
    NSArray *_colors;
    NSArray<NSNumber *> *_locations;
    CGPoint _startPoint, _endPoint;
    CAGradientLayerType _type;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _startPoint = CGPointMake(0.5, 0);
        _endPoint = CGPointMake(0.5, 1);
        _type = [kCAGradientLayerAxial copy];
    }
    return self;
}

- (void)dealloc
{
    [_colors release];
    [_locations release];
    [_type release];
    [super dealloc];
}

COPY_PROP(NSArray *, colors, setColors, _colors)
COPY_PROP(NSArray *, locations, setLocations, _locations)
COPY_PROP(CAGradientLayerType, type, setType, _type)
SCALAR_PROP(CGPoint, startPoint, setStartPoint, _startPoint)
SCALAR_PROP(CGPoint, endPoint, setEndPoint, _endPoint)

/* Points are in the unit square of the bounds, y running with the layer's. */
- (void)_finchDrawContent:(CGContextRef)cg
{
    NSUInteger n = [_colors count];
    if (!n)
        return;
    CGFloat locs[n];
    BOOL have = [_locations count] == n;
    for (NSUInteger i = 0; i < n; i++)
        locs[i] = have ? [_locations[i] doubleValue] : (n > 1 ? (CGFloat)i / (n - 1) : 0);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef g = CGGradientCreateWithColors(cs, (CFArrayRef)_colors, locs);
    CGColorSpaceRelease(cs);
    if (!g)
        return;
    CGRect b = [self bounds];
    CGPoint s = CGPointMake(CGRectGetMinX(b) + _startPoint.x * b.size.width, CGRectGetMinY(b) + _startPoint.y * b.size.height);
    CGPoint e = CGPointMake(CGRectGetMinX(b) + _endPoint.x * b.size.width, CGRectGetMinY(b) + _endPoint.y * b.size.height);
    CGContextSaveGState(cg);
    CGContextClipToRect(cg, b);
    if ([_type isEqualToString:kCAGradientLayerRadial]) {
        /* the end point gives the radii, as Core Animation's: an ellipse */
        CGFloat rx = fabs(e.x - s.x), ry = fabs(e.y - s.y);
        CGFloat r = MAX(rx, ry);
        if (r > 0) {
            CGContextTranslateCTM(cg, s.x, s.y);
            CGContextScaleCTM(cg, rx > 0 ? rx / r : 1, ry > 0 ? ry / r : 1);
            CGContextDrawRadialGradient(cg, g, CGPointZero, 0, CGPointZero, r, kCGGradientDrawsAfterEndLocation);
        }
    } else if ([_type isEqualToString:kCAGradientLayerConic]) {
        CGContextDrawConicGradient(cg, g, s, atan2(e.y - s.y, e.x - s.x));
    } else {
        CGContextDrawLinearGradient(cg, g, s, e, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    }
    CGContextRestoreGState(cg);
    CGGradientRelease(g);
}

@end

#pragma mark CATextLayer

@implementation CATextLayer {
    id _string;
    CFTypeRef _font;
    CGFloat _fontSize;
    CGColorRef _foregroundColor;
    CATextLayerAlignmentMode _alignmentMode;
    CATextLayerTruncationMode _truncationMode;
    BOOL _wrapped, _allowsFontSubpixelQuantization;
}

+ (BOOL)needsDisplayForKey:(NSString *)key
{
    static NSSet *keys;
    if (!keys)
        keys = [[NSSet alloc] initWithObjects:@"string", @"font", @"fontSize", @"foregroundColor", @"wrapped",
                                              @"alignmentMode", @"truncationMode", nil];
    return [keys containsObject:key] || [super needsDisplayForKey:key];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _font = CTFontCreateWithName(CFSTR("Helvetica"), 36, NULL);
        _fontSize = 36;
        _foregroundColor = srgb(1, 1, 1, 1);
        _alignmentMode = [kCAAlignmentNatural copy];
        _truncationMode = [kCATruncationNone copy];
    }
    return self;
}

- (void)dealloc
{
    [_string release];
    if (_font)
        CFRelease(_font);
    CGColorRelease(_foregroundColor);
    [_alignmentMode release];
    [_truncationMode release];
    [super dealloc];
}

COPY_PROP(id, string, setString, _string)
SCALAR_PROP(CGFloat, fontSize, setFontSize, _fontSize)
COLOR_PROP(foregroundColor, setForegroundColor, _foregroundColor)
COPY_PROP(CATextLayerAlignmentMode, alignmentMode, setAlignmentMode, _alignmentMode)
COPY_PROP(CATextLayerTruncationMode, truncationMode, setTruncationMode, _truncationMode)
SCALAR_PROP(BOOL, isWrapped, setWrapped, _wrapped)
SCALAR_PROP(BOOL, allowsFontSubpixelQuantization, setAllowsFontSubpixelQuantization, _allowsFontSubpixelQuantization)

- (CFTypeRef)font { return _font; }
- (void)setFont:(CFTypeRef)f
{
    if (f)
        CFRetain(f);
    if (_font)
        CFRelease(_font);
    _font = f;
}

/* The font as a CTFont of the layer's size: the font property may be a CTFont, a CGFont, an NSFont or a name. */
- (CTFontRef)_ctFont
{
    CFTypeRef f = _font;
    if (!f)
        return CTFontCreateWithName(CFSTR("Helvetica"), _fontSize, NULL);
    CFTypeID type = CFGetTypeID(f);
    if (type == CTFontGetTypeID())
        return CTFontCreateCopyWithAttributes((CTFontRef)f, _fontSize, NULL, NULL);
    if (type == CGFontGetTypeID())
        return CTFontCreateWithGraphicsFont((CGFontRef)f, _fontSize, NULL, NULL);
    if (type == CFStringGetTypeID())
        return CTFontCreateWithName((CFStringRef)f, _fontSize, NULL);
    return CTFontCreateWithName(CFSTR("Helvetica"), _fontSize, NULL);
}

- (NSAttributedString *)_attributedString
{
    if ([_string isKindOfClass:[NSAttributedString class]])
        return _string;
    if (![_string isKindOfClass:[NSString class]])
        return nil;
    CTFontRef font = [self _ctFont];
    CTTextAlignment align = [_alignmentMode isEqualToString:kCAAlignmentCenter]      ? kCTTextAlignmentCenter
                            : [_alignmentMode isEqualToString:kCAAlignmentRight]     ? kCTTextAlignmentRight
                            : [_alignmentMode isEqualToString:kCAAlignmentJustified] ? kCTTextAlignmentJustified
                            : [_alignmentMode isEqualToString:kCAAlignmentLeft]      ? kCTTextAlignmentLeft
                                                                                     : kCTTextAlignmentNatural;
    CTParagraphStyleSetting setting = {kCTParagraphStyleSpecifierAlignment, sizeof align, &align};
    CTParagraphStyleRef para = CTParagraphStyleCreate(&setting, 1);
    NSDictionary *attrs = @{
        (id)kCTFontAttributeName : (id)font,
        (id)kCTForegroundColorAttributeName : (id)_foregroundColor,
        (id)kCTParagraphStyleAttributeName : (id)para,
    };
    NSAttributedString *s = [[[NSAttributedString alloc] initWithString:_string attributes:attrs] autorelease];
    CFRelease(font);
    CFRelease(para);
    return s;
}

/* Text from the top of the bounds, as Core Animation's: one line unless wrapped. */
- (void)_finchDrawContent:(CGContextRef)cg
{
    NSAttributedString *s = [self _attributedString];
    if (![s length])
        return;
    CGRect b = [self bounds];
    CGContextSaveGState(cg);
    CGContextClipToRect(cg, b);
    BOOL flipped = [self contentsAreFlipped];
    if (flipped) {
        CGContextTranslateCTM(cg, 0, CGRectGetMinY(b) + CGRectGetMaxY(b));
        CGContextScaleCTM(cg, 1, -1);
    }
    CGContextSetTextMatrix(cg, CGAffineTransformIdentity);
    if (_wrapped) {
        CTFramesetterRef fs = CTFramesetterCreateWithAttributedString((CFAttributedStringRef)s);
        CGPathRef path = CGPathCreateWithRect(b, NULL);
        CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, NULL);
        CTFrameDraw(frame, cg);
        CFRelease(frame);
        CGPathRelease(path);
        CFRelease(fs);
    } else {
        CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)s);
        CGFloat ascent = 0, descent = 0, leading = 0;
        double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        if (width > b.size.width && ![_truncationMode isEqualToString:kCATruncationNone]) {
            CTLineTruncationType type = [_truncationMode isEqualToString:kCATruncationStart]    ? kCTLineTruncationStart
                                        : [_truncationMode isEqualToString:kCATruncationMiddle] ? kCTLineTruncationMiddle
                                                                                                : kCTLineTruncationEnd;
            NSAttributedString *dots = [[[NSAttributedString alloc]
                initWithString:@"…"
                     attributes:[s attributesAtIndex:0 effectiveRange:NULL]] autorelease];
            CTLineRef token = CTLineCreateWithAttributedString((CFAttributedStringRef)dots);
            CTLineRef t = CTLineCreateTruncatedLine(line, b.size.width, type, token);
            CFRelease(token);
            if (t) {
                CFRelease(line);
                line = t;
                width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
            }
        }
        CGFloat x = CGRectGetMinX(b);
        if ([_alignmentMode isEqualToString:kCAAlignmentCenter])
            x += (b.size.width - width) / 2;
        else if ([_alignmentMode isEqualToString:kCAAlignmentRight])
            x += b.size.width - width;
        CGContextSetTextPosition(cg, x, CGRectGetMaxY(b) - ascent);
        CTLineDraw(line, cg);
        CFRelease(line);
    }
    CGContextRestoreGState(cg);
}

@end

#pragma mark CAReplicatorLayer

@implementation CAReplicatorLayer {
    NSInteger _instanceCount;
    CFTimeInterval _instanceDelay;
    CATransform3D _instanceTransform;
    CGColorRef _instanceColor;
    float _dr, _dg, _db, _da;
    BOOL _preservesDepth;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _instanceCount = 1;
        _instanceTransform = CATransform3DIdentity;
        _instanceColor = srgb(1, 1, 1, 1);
    }
    return self;
}

- (void)dealloc
{
    CGColorRelease(_instanceColor);
    [super dealloc];
}

SCALAR_PROP(NSInteger, instanceCount, setInstanceCount, _instanceCount)
SCALAR_PROP(CFTimeInterval, instanceDelay, setInstanceDelay, _instanceDelay)
SCALAR_PROP(CATransform3D, instanceTransform, setInstanceTransform, _instanceTransform)
SCALAR_PROP(BOOL, preservesDepth, setPreservesDepth, _preservesDepth)
COLOR_PROP(instanceColor, setInstanceColor, _instanceColor)
SCALAR_PROP(float, instanceRedOffset, setInstanceRedOffset, _dr)
SCALAR_PROP(float, instanceGreenOffset, setInstanceGreenOffset, _dg)
SCALAR_PROP(float, instanceBlueOffset, setInstanceBlueOffset, _db)
SCALAR_PROP(float, instanceAlphaOffset, setInstanceAlphaOffset, _da)

/* The sublayers again for each further instance, each through one more instance transform. */
- (void)_finchDrawContent:(CGContextRef)cg
{
    CGAffineTransform step = CATransform3DGetAffineTransform(_instanceTransform);
    CGAffineTransform t = CGAffineTransformIdentity;
    for (NSInteger i = 1; i < _instanceCount; i++) {
        t = CGAffineTransformConcat(step, t);
        float alpha = (float)CGColorGetAlpha(_instanceColor) + _da * (float)i;
        if (alpha <= 0)
            break;
        CGContextSaveGState(cg);
        CGContextConcatCTM(cg, t);
        CGContextSetAlpha(cg, MIN(alpha, 1));
        for (CALayer *s in [self sublayers]) {
            CGContextSaveGState(cg);
            CGRect f = [s frame];
            CGRect b = [s bounds];
            CGContextTranslateCTM(cg, f.origin.x - b.origin.x, f.origin.y - b.origin.y);
            [s _finchRenderInContext:cg];
            CGContextRestoreGState(cg);
        }
        CGContextRestoreGState(cg);
    }
}

@end

#pragma mark CAScrollLayer, CATiledLayer, CATransformLayer

@implementation CAScrollLayer {
    CAScrollLayerScrollMode _scrollMode;
}

- (instancetype)init
{
    self = [super init];
    if (self)
        _scrollMode = [kCAScrollBoth copy];
    return self;
}

- (void)dealloc
{
    [_scrollMode release];
    [super dealloc];
}

COPY_PROP(CAScrollLayerScrollMode, scrollMode, setScrollMode, _scrollMode)

- (void)scrollToPoint:(CGPoint)p
{
    CGRect b = [self bounds];
    if ([_scrollMode isEqualToString:kCAScrollNone])
        return;
    if (![_scrollMode isEqualToString:kCAScrollVertically])
        b.origin.x = p.x;
    if (![_scrollMode isEqualToString:kCAScrollHorizontally])
        b.origin.y = p.y;
    [self setBounds:b];
}

- (void)scrollToRect:(CGRect)r
{
    CGRect b = [self bounds];
    CGPoint p = b.origin;
    if (CGRectGetMaxX(r) > CGRectGetMaxX(b))
        p.x = CGRectGetMaxX(r) - b.size.width;
    if (r.origin.x < p.x)
        p.x = r.origin.x;
    if (CGRectGetMaxY(r) > CGRectGetMaxY(b))
        p.y = CGRectGetMaxY(r) - b.size.height;
    if (r.origin.y < p.y)
        p.y = r.origin.y;
    [self scrollToPoint:p];
}

@end

/* Scrolling of any layer: asks the nearest scroll layer above it. */
@implementation CALayer (CALayerScrolling)

- (CAScrollLayer *)_finchScrollLayer
{
    for (CALayer *l = [self superlayer]; l; l = [l superlayer])
        if ([l isKindOfClass:[CAScrollLayer class]])
            return (CAScrollLayer *)l;
    return nil;
}

- (void)scrollPoint:(CGPoint)p
{
    CAScrollLayer *s = [self _finchScrollLayer];
    [s scrollToPoint:[self convertPoint:p toLayer:s]];
}

- (void)scrollRectToVisible:(CGRect)r
{
    CAScrollLayer *s = [self _finchScrollLayer];
    [s scrollToRect:[self convertRect:r toLayer:s]];
}

- (CGRect)visibleRect
{
    CAScrollLayer *s = [self _finchScrollLayer];
    if (!s)
        return [self bounds];
    return CGRectIntersection([self bounds], [self convertRect:[s bounds] fromLayer:s]);
}

@end

@implementation CATiledLayer {
    size_t _levels, _bias;
    CGSize _tileSize;
}

+ (CFTimeInterval)fadeDuration { return 0.25; }

- (instancetype)init
{
    self = [super init];
    if (self) {
        _levels = 1;
        _tileSize = CGSizeMake(256, 256);
    }
    return self;
}

SCALAR_PROP(size_t, levelsOfDetail, setLevelsOfDetail, _levels)
SCALAR_PROP(size_t, levelsOfDetailBias, setLevelsOfDetailBias, _bias)
SCALAR_PROP(CGSize, tileSize, setTileSize, _tileSize)

@end

@implementation CATransformLayer
@end

#pragma mark Emitters

@implementation CAEmitterCell {
    NSMutableDictionary *_v;
}

+ (instancetype)emitterCell { return [[[self alloc] init] autorelease]; }
+ (id)defaultValueForKey:(NSString *)key
{
    static NSDictionary *d;
    if (!d)
        d = [@{@"scale" : @1.0, @"enabled" : @YES, @"speed" : @1.0f} retain];
    return d[key];
}
- (BOOL)shouldArchiveValueForKey:(NSString *)key { return YES; }

- (instancetype)init
{
    self = [super init];
    if (self)
        _v = [[NSMutableDictionary alloc] init];
    return self;
}

- (void)dealloc
{
    [_v release];
    [super dealloc];
}

- (instancetype)initWithCoder:(NSCoder *)coder { return [self init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
+ (BOOL)supportsSecureCoding { return YES; }

- (id)_get:(NSString *)k { return _v[k] ?: [[self class] defaultValueForKey:k]; }
- (void)_set:(id)x key:(NSString *)k
{
    if (x)
        _v[k] = x;
    else
        [_v removeObjectForKey:k];
}
- (void)setValue:(id)value forUndefinedKey:(NSString *)key { [self _set:value key:key]; }
- (id)valueForUndefinedKey:(NSString *)key { return [self _get:key]; }

#define CELL_NUM(type, get, set, K, conv) \
    -(type)get { return (type)[[self _get:K] conv]; } \
    -(void)set:(type)x { [self _set:@(x) key:K]; }
#define CELL_OBJ(type, get, set, K) \
    -(type)get { return [self _get:K]; } \
    -(void)set:(type)x { [self _set:x key:K]; }

CELL_OBJ(NSString *, name, setName, @"name")
CELL_NUM(BOOL, isEnabled, setEnabled, @"enabled", boolValue)
CELL_NUM(float, birthRate, setBirthRate, @"birthRate", floatValue)
CELL_NUM(float, lifetime, setLifetime, @"lifetime", floatValue)
CELL_NUM(float, lifetimeRange, setLifetimeRange, @"lifetimeRange", floatValue)
CELL_NUM(CGFloat, emissionLatitude, setEmissionLatitude, @"emissionLatitude", doubleValue)
CELL_NUM(CGFloat, emissionLongitude, setEmissionLongitude, @"emissionLongitude", doubleValue)
CELL_NUM(CGFloat, emissionRange, setEmissionRange, @"emissionRange", doubleValue)
CELL_NUM(CGFloat, velocity, setVelocity, @"velocity", doubleValue)
CELL_NUM(CGFloat, velocityRange, setVelocityRange, @"velocityRange", doubleValue)
CELL_NUM(CGFloat, xAcceleration, setXAcceleration, @"xAcceleration", doubleValue)
CELL_NUM(CGFloat, yAcceleration, setYAcceleration, @"yAcceleration", doubleValue)
CELL_NUM(CGFloat, zAcceleration, setZAcceleration, @"zAcceleration", doubleValue)
CELL_NUM(CGFloat, scale, setScale, @"scale", doubleValue)
CELL_NUM(CGFloat, scaleRange, setScaleRange, @"scaleRange", doubleValue)
CELL_NUM(CGFloat, scaleSpeed, setScaleSpeed, @"scaleSpeed", doubleValue)
CELL_NUM(CGFloat, spin, setSpin, @"spin", doubleValue)
CELL_NUM(CGFloat, spinRange, setSpinRange, @"spinRange", doubleValue)
CELL_NUM(float, redRange, setRedRange, @"redRange", floatValue)
CELL_NUM(float, greenRange, setGreenRange, @"greenRange", floatValue)
CELL_NUM(float, blueRange, setBlueRange, @"blueRange", floatValue)
CELL_NUM(float, alphaRange, setAlphaRange, @"alphaRange", floatValue)
CELL_NUM(float, redSpeed, setRedSpeed, @"redSpeed", floatValue)
CELL_NUM(float, greenSpeed, setGreenSpeed, @"greenSpeed", floatValue)
CELL_NUM(float, blueSpeed, setBlueSpeed, @"blueSpeed", floatValue)
CELL_NUM(float, alphaSpeed, setAlphaSpeed, @"alphaSpeed", floatValue)
CELL_NUM(CGFloat, contentsScale, setContentsScale, @"contentsScale", doubleValue)
CELL_NUM(float, minificationFilterBias, setMinificationFilterBias, @"minificationFilterBias", floatValue)
CELL_NUM(double, beginTime, setBeginTime, @"beginTime", doubleValue)
CELL_NUM(double, duration, setDuration, @"duration", doubleValue)
CELL_NUM(float, speed, setSpeed, @"speed", floatValue)
CELL_NUM(double, timeOffset, setTimeOffset, @"timeOffset", doubleValue)
CELL_NUM(float, repeatCount, setRepeatCount, @"repeatCount", floatValue)
CELL_NUM(double, repeatDuration, setRepeatDuration, @"repeatDuration", doubleValue)
CELL_NUM(BOOL, autoreverses, setAutoreverses, @"autoreverses", boolValue)
CELL_OBJ(id, contents, setContents, @"contents")
CELL_OBJ(NSArray *, emitterCells, setEmitterCells, @"emitterCells")
CELL_OBJ(NSDictionary *, style, setStyle, @"style")
CELL_OBJ(NSString *, magnificationFilter, setMagnificationFilter, @"magnificationFilter")
CELL_OBJ(NSString *, minificationFilter, setMinificationFilter, @"minificationFilter")
CELL_OBJ(CAMediaTimingFillMode, fillMode, setFillMode, @"fillMode")

- (CGRect)contentsRect
{
    NSValue *v = [self _get:@"contentsRect"];
    return v ? NSRectToCGRect([v rectValue]) : CGRectMake(0, 0, 1, 1);
}
- (void)setContentsRect:(CGRect)r { [self _set:[NSValue valueWithRect:NSRectFromCGRect(r)] key:@"contentsRect"]; }

- (CGColorRef)color
{
    id c = [self _get:@"color"];
    if (!c) {
        static CGColorRef white;
        if (!white)
            white = srgb(1, 1, 1, 1);
        return white;
    }
    return (CGColorRef)c;
}
- (void)setColor:(CGColorRef)c { [self _set:(id)c key:@"color"]; }

@end

@implementation CAEmitterLayer {
    NSArray<CAEmitterCell *> *_cells;
    CGPoint _emitterPosition;
    CGFloat _emitterZ, _depth;
    CGSize _size;
    CAEmitterLayerEmitterShape _shape;
    CAEmitterLayerEmitterMode _mode;
    CAEmitterLayerRenderMode _renderMode;
    float _birthRate, _lifetime, _velocity, _scale, _spin;
    unsigned int _seed;
    BOOL _preservesDepth;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _shape = [kCAEmitterLayerPoint copy];
        _mode = [kCAEmitterLayerVolume copy];
        _renderMode = [kCAEmitterLayerUnordered copy];
        _birthRate = _lifetime = _velocity = _scale = _spin = 1;
    }
    return self;
}

- (void)dealloc
{
    [_cells release];
    [_shape release];
    [_mode release];
    [_renderMode release];
    [super dealloc];
}

COPY_PROP(NSArray *, emitterCells, setEmitterCells, _cells)
COPY_PROP(CAEmitterLayerEmitterShape, emitterShape, setEmitterShape, _shape)
COPY_PROP(CAEmitterLayerEmitterMode, emitterMode, setEmitterMode, _mode)
COPY_PROP(CAEmitterLayerRenderMode, renderMode, setRenderMode, _renderMode)
SCALAR_PROP(CGPoint, emitterPosition, setEmitterPosition, _emitterPosition)
SCALAR_PROP(CGFloat, emitterZPosition, setEmitterZPosition, _emitterZ)
SCALAR_PROP(CGFloat, emitterDepth, setEmitterDepth, _depth)
SCALAR_PROP(CGSize, emitterSize, setEmitterSize, _size)
SCALAR_PROP(float, birthRate, setBirthRate, _birthRate)
SCALAR_PROP(float, lifetime, setLifetime, _lifetime)
SCALAR_PROP(float, velocity, setVelocity, _velocity)
SCALAR_PROP(float, scale, setScale, _scale)
SCALAR_PROP(float, spin, setSpin, _spin)
SCALAR_PROP(unsigned int, seed, setSeed, _seed)
SCALAR_PROP(BOOL, preservesDepth, setPreservesDepth, _preservesDepth)

@end

#pragma mark Constraints

/* In the header's ivars: _srcId, _srcAttr, _attr, _scale, _offset. */
@implementation CAConstraint

+ (instancetype)constraintWithAttribute:(CAConstraintAttribute)attr relativeTo:(NSString *)src
                              attribute:(CAConstraintAttribute)srcAttr scale:(CGFloat)m offset:(CGFloat)c
{
    return [[[self alloc] initWithAttribute:attr relativeTo:src attribute:srcAttr scale:m offset:c] autorelease];
}

+ (instancetype)constraintWithAttribute:(CAConstraintAttribute)attr relativeTo:(NSString *)src
                              attribute:(CAConstraintAttribute)srcAttr offset:(CGFloat)c
{
    return [self constraintWithAttribute:attr relativeTo:src attribute:srcAttr scale:1 offset:c];
}

+ (instancetype)constraintWithAttribute:(CAConstraintAttribute)attr relativeTo:(NSString *)src
                              attribute:(CAConstraintAttribute)srcAttr
{
    return [self constraintWithAttribute:attr relativeTo:src attribute:srcAttr scale:1 offset:0];
}

- (instancetype)initWithAttribute:(CAConstraintAttribute)attr relativeTo:(NSString *)src
                        attribute:(CAConstraintAttribute)srcAttr scale:(CGFloat)m offset:(CGFloat)c
{
    self = [super init];
    if (self) {
        _attr = attr;
        _srcId = [src copy];
        _srcAttr = srcAttr;
        _scale = m;
        _offset = c;
    }
    return self;
}

- (void)dealloc
{
    [_srcId release];
    [super dealloc];
}

- (instancetype)initWithCoder:(NSCoder *)coder { return [self init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
+ (BOOL)supportsSecureCoding { return YES; }

- (CAConstraintAttribute)attribute { return _attr; }
- (NSString *)sourceName { return _srcId; }
- (CAConstraintAttribute)sourceAttribute { return _srcAttr; }
- (CGFloat)scale { return _scale; }
- (CGFloat)offset { return _offset; }

@end

static CGFloat
attribute_value(CGRect f, CAConstraintAttribute a)
{
    switch (a) {
    case kCAConstraintMinX: return CGRectGetMinX(f);
    case kCAConstraintMidX: return CGRectGetMidX(f);
    case kCAConstraintMaxX: return CGRectGetMaxX(f);
    case kCAConstraintWidth: return f.size.width;
    case kCAConstraintMinY: return CGRectGetMinY(f);
    case kCAConstraintMidY: return CGRectGetMidY(f);
    case kCAConstraintMaxY: return CGRectGetMaxY(f);
    case kCAConstraintHeight: return f.size.height;
    }
    return 0;
}

@implementation CAConstraintLayoutManager

+ (instancetype)layoutManager { return [[[self alloc] init] autorelease]; }

/*
 * Each sublayer's constraints, in order, against the superlayer ("superlayer")
 * or a named sibling: a width or height sets the size, the others place the
 * edge or middle along their axis.
 */
- (void)layoutSublayersOfLayer:(CALayer *)layer
{
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    for (CALayer *s in [layer sublayers])
        if ([s name])
            byName[[s name]] = s;
    CGRect bounds = [layer bounds];
    for (CALayer *s in [layer sublayers]) {
        NSArray *cs = [s constraints];
        if (![cs count])
            continue;
        CGRect f = [s frame];
        for (CAConstraint *c in cs) {
            CGRect src;
            if ([[c sourceName] isEqualToString:@"superlayer"])
                src = bounds;
            else if (byName[[c sourceName]])
                src = [byName[[c sourceName]] frame];
            else
                continue;
            CGFloat v = attribute_value(src, [c sourceAttribute]) * [c scale] + [c offset];
            switch ([c attribute]) {
            case kCAConstraintWidth: f.size.width = v; break;
            case kCAConstraintHeight: f.size.height = v; break;
            case kCAConstraintMinX: f.origin.x = v; break;
            case kCAConstraintMidX: f.origin.x = v - f.size.width / 2; break;
            case kCAConstraintMaxX: f.origin.x = v - f.size.width; break;
            case kCAConstraintMinY: f.origin.y = v; break;
            case kCAConstraintMidY: f.origin.y = v - f.size.height / 2; break;
            case kCAConstraintMaxY: f.origin.y = v - f.size.height; break;
            }
        }
        [s setFrame:f];
    }
}

@end
