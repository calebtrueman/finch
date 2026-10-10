/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CALayer: Core Animation's layer tree, its geometry, and its rendering.
 *
 * Geometry is as Core Animation's: a layer's frame is its bounds, placed so
 * the anchor point sits at the position in the superlayer, through the
 * transform (its affine part, for frames and conversions). Rendering is
 * -renderInContext:, through CoreGraphics: background, contents (with its
 * gravity), the layer's own drawing, sublayers by zPosition, border, with
 * corner masking, opacity and shadow. Finch has no render server yet, so
 * animations are kept but not played: model values are what draws.
 */
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/* NSImage, which is AppKit's: asked for through this, without linking AppKit. */
@interface NSObject (FinchContentsImage)
- (CGImageRef)CGImageForProposedRect:(CGRect *)rect context:(id)context hints:(NSDictionary *)hints;
@end

/* Finch has no render server: a framework that shows layers (AppKit) learns of changes that
   need a redraw through this, and finds the view to redisplay. */
__attribute__((visibility("default"))) void (*FinchCALayerDidChange)(CALayer *layer);

static void
changed(CALayer *layer)
{
    if (FinchCALayerDidChange)
        FinchCALayerDidChange(layer);
}

@interface CALayer (FinchPrivate)
- (void)_finchRenderInContext:(CGContextRef)cg;
- (void)_finchDrawContent:(CGContextRef)cg;
@end

@implementation CALayer {
    CGRect _bounds;
    CGPoint _position, _anchorPoint;
    CGFloat _zPosition, _anchorPointZ;
    CATransform3D _transform, _sublayerTransform;
    CALayer *_superlayer;  /* not retained */
    NSMutableArray<CALayer *> *_sublayers;
    CALayer *_mask;
    id _contents;
    CGRect _contentsRect, _contentsCenter;
    CALayerContentsGravity _contentsGravity;
    CALayerContentsFilter _minFilter, _magFilter;
    CGFloat _contentsScale, _rasterizationScale;
    float _opacity, _shadowOpacity;
    CGColorRef _backgroundColor, _borderColor, _shadowColor;
    CGFloat _borderWidth, _cornerRadius, _shadowRadius;
    CGSize _shadowOffset;
    CGPathRef _shadowPath;
    CACornerMask _maskedCorners;
    CAEdgeAntialiasingMask _edgeMask;
    id<CALayerDelegate> _delegate;  /* not retained */
    NSString *_name;
    NSDictionary *_actions, *_style;
    NSMutableDictionary *_values;  /* KVC keys of the app's own */
    NSMutableDictionary<NSString *, CAAnimation *> *_animations;
    NSMutableArray<NSString *> *_animationKeys;
    CAAutoresizingMask _autoresizingMask;
    id<CALayoutManager> _layoutManager;
    NSMutableArray *_constraints;
    struct {
        unsigned hidden : 1;
        unsigned masksToBounds : 1;
        unsigned doubleSided : 1;
        unsigned geometryFlipped : 1;
        unsigned opaque : 1;
        unsigned needsDisplay : 1;
        unsigned needsLayout : 1;
        unsigned needsDisplayOnBoundsChange : 1;
        unsigned drawsAsynchronously : 1;
        unsigned shouldRasterize : 1;
        unsigned allowsEdgeAntialiasing : 1;
        unsigned allowsGroupOpacity : 1;
    } _f;
}

+ (instancetype)layer
{
    return [[[self alloc] init] autorelease];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _anchorPoint = CGPointMake(0.5, 0.5);
        _transform = CATransform3DIdentity;
        _sublayerTransform = CATransform3DIdentity;
        _contentsRect = CGRectMake(0, 0, 1, 1);
        _contentsCenter = CGRectMake(0, 0, 1, 1);
        _contentsGravity = [kCAGravityResize copy];
        _minFilter = [kCAFilterLinear copy];
        _magFilter = [kCAFilterLinear copy];
        _contentsScale = 1;
        _rasterizationScale = 1;
        _opacity = 1;
        _shadowOffset = CGSizeMake(0, -3);
        _shadowRadius = 3;
        _borderColor = CGColorCreateSRGB(0, 0, 0, 1);
        _shadowColor = CGColorCreateSRGB(0, 0, 0, 1);
        _maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        _edgeMask = kCALayerLeftEdge | kCALayerRightEdge | kCALayerBottomEdge | kCALayerTopEdge;
        _f.doubleSided = YES;
        _f.allowsGroupOpacity = YES;
    }
    return self;
}

/* A copy of another layer's model values: what -presentationLayer and -initWithLayer: start from. */
- (instancetype)initWithLayer:(id)other
{
    self = [self init];
    if (self && [other isKindOfClass:[CALayer class]]) {
        CALayer *o = other;
        _bounds = o->_bounds;
        _position = o->_position;
        _anchorPoint = o->_anchorPoint;
        _zPosition = o->_zPosition;
        _transform = o->_transform;
        _sublayerTransform = o->_sublayerTransform;
        _opacity = o->_opacity;
        _f = o->_f;
        [self setContents:o->_contents];
        [self setBackgroundColor:o->_backgroundColor];
        _cornerRadius = o->_cornerRadius;
        _borderWidth = o->_borderWidth;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self init];
    if (self) {
        if ([coder containsValueForKey:@"bounds"])
            _bounds = NSRectToCGRect([coder decodeRectForKey:@"bounds"]);
        if ([coder containsValueForKey:@"position"])
            _position = NSPointToCGPoint([coder decodePointForKey:@"position"]);
        _name = [[coder decodeObjectForKey:@"name"] copy];
        for (CALayer *s in [coder decodeObjectForKey:@"sublayers"])
            [self addSublayer:s];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeRect:NSRectFromCGRect(_bounds) forKey:@"bounds"];
    [coder encodePoint:NSPointFromCGPoint(_position) forKey:@"position"];
    if (_name)
        [coder encodeObject:_name forKey:@"name"];
    if ([_sublayers count])
        [coder encodeObject:_sublayers forKey:@"sublayers"];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (void)dealloc
{
    for (CALayer *s in _sublayers)
        s->_superlayer = nil;
    [_sublayers release];
    [_mask release];
    [_contents release];
    [_contentsGravity release];
    [_minFilter release];
    [_magFilter release];
    CGColorRelease(_backgroundColor);
    CGColorRelease(_borderColor);
    CGColorRelease(_shadowColor);
    CGPathRelease(_shadowPath);
    [_name release];
    [_actions release];
    [_style release];
    [_values release];
    [_animations release];
    [_animationKeys release];
    [_constraints release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@:%p; position = CGPoint (%g %g); bounds = CGRect (%g %g; %g %g)>",
                                      [self class], self, _position.x, _position.y, _bounds.origin.x,
                                      _bounds.origin.y, _bounds.size.width, _bounds.size.height];
}

#pragma mark Defaults and KVC

+ (id)defaultValueForKey:(NSString *)key
{
    static NSDictionary *d;
    if (!d)
        d = [@{
            @"opacity" : @1.0f, @"anchorPoint" : [NSValue valueWithPoint:NSMakePoint(0.5, 0.5)],
            @"contentsScale" : @1.0, @"shadowRadius" : @3.0,
            @"shadowOffset" : [NSValue valueWithSize:NSMakeSize(0, -3)], @"doubleSided" : @YES,
            @"contentsGravity" : kCAGravityResize,
        } retain];
    return d[key];
}

+ (BOOL)needsDisplayForKey:(NSString *)key { return NO; }
- (BOOL)shouldArchiveValueForKey:(NSString *)key { return YES; }

/* As Core Animation's: any key may be set and read back. */
- (void)setValue:(id)value forUndefinedKey:(NSString *)key
{
    if (!_values)
        _values = [[NSMutableDictionary alloc] init];
    if (value)
        _values[key] = value;
    else
        [_values removeObjectForKey:key];
}

- (id)valueForUndefinedKey:(NSString *)key
{
    id v = _values[key];
    return v ?: [[self class] defaultValueForKey:key];
}

#pragma mark Geometry

- (CGRect)bounds { return _bounds; }

- (void)setBounds:(CGRect)bounds
{
    BOOL resized = !CGSizeEqualToSize(bounds.size, _bounds.size);
    CGSize old = _bounds.size;
    _bounds = bounds;
    if (resized) {
        if (_f.needsDisplayOnBoundsChange)
            [self setNeedsDisplay];
        [self setNeedsLayout];
        for (CALayer *s in [[_sublayers copy] autorelease])
            [s resizeWithOldSuperlayerSize:old];
    }
}

- (CGPoint)position { return _position; }
- (void)setPosition:(CGPoint)p { _position = p; changed(self); }
- (CGPoint)anchorPoint { return _anchorPoint; }
- (void)setAnchorPoint:(CGPoint)p { _anchorPoint = p; }
- (CGFloat)zPosition { return _zPosition; }
- (void)setZPosition:(CGFloat)z { _zPosition = z; }
- (CGFloat)anchorPointZ { return _anchorPointZ; }
- (void)setAnchorPointZ:(CGFloat)z { _anchorPointZ = z; }
- (CATransform3D)transform { return _transform; }
- (void)setTransform:(CATransform3D)t { _transform = t; changed(self); }
- (CATransform3D)sublayerTransform { return _sublayerTransform; }
- (void)setSublayerTransform:(CATransform3D)t { _sublayerTransform = t; }
- (CGAffineTransform)affineTransform { return CATransform3DGetAffineTransform(_transform); }
- (void)setAffineTransform:(CGAffineTransform)m { _transform = CATransform3DMakeAffineTransform(m); changed(self); }

/* From this layer's coordinates to its superlayer's (the affine part of the transform). */
static CGAffineTransform
to_super(CALayer *l)
{
    CGFloat ax = l->_bounds.size.width * l->_anchorPoint.x, ay = l->_bounds.size.height * l->_anchorPoint.y;
    CGAffineTransform t = CGAffineTransformMakeTranslation(-l->_bounds.origin.x - ax, -l->_bounds.origin.y - ay);
    t = CGAffineTransformConcat(t, CATransform3DGetAffineTransform(l->_transform));
    t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(l->_position.x, l->_position.y));
    if (l->_superlayer && !CATransform3DIsIdentity(l->_superlayer->_sublayerTransform)) {
        CALayer *s = l->_superlayer;
        CGFloat sx = s->_bounds.origin.x + s->_bounds.size.width * s->_anchorPoint.x;
        CGFloat sy = s->_bounds.origin.y + s->_bounds.size.height * s->_anchorPoint.y;
        CGAffineTransform st = CGAffineTransformMakeTranslation(-sx, -sy);
        st = CGAffineTransformConcat(st, CATransform3DGetAffineTransform(s->_sublayerTransform));
        st = CGAffineTransformConcat(st, CGAffineTransformMakeTranslation(sx, sy));
        t = CGAffineTransformConcat(t, st);
    }
    return t;
}

- (CGRect)frame
{
    return CGRectApplyAffineTransform(_bounds, to_super(self));
}

- (void)setFrame:(CGRect)frame
{
    CGAffineTransform t = CATransform3DGetAffineTransform(_transform);
    CGSize size = frame.size;
    if (!CGAffineTransformIsIdentity(t)) {
        CGAffineTransform inv = CGAffineTransformInvert(t);
        size = CGRectApplyAffineTransform(CGRectMake(0, 0, size.width, size.height), inv).size;
    }
    [self setBounds:CGRectMake(_bounds.origin.x, _bounds.origin.y, size.width, size.height)];
    _position = CGPointMake(frame.origin.x + frame.size.width * _anchorPoint.x,
                            frame.origin.y + frame.size.height * _anchorPoint.y);
}

/*
 * From this layer's coordinates to the space the root layer sits in (the
 * root's own position and transform included, as Core Animation's: a nil
 * layer in the conversions means that space).
 */
static CGAffineTransform
to_root(CALayer *l)
{
    CGAffineTransform t = CGAffineTransformIdentity;
    for (CALayer *x = l; x; x = x->_superlayer)
        t = CGAffineTransformConcat(t, to_super(x));
    return t;
}

static CGAffineTransform
between(CALayer *from, CALayer *to)
{
    CGAffineTransform t = from ? to_root(from) : CGAffineTransformIdentity;
    if (to)
        t = CGAffineTransformConcat(t, CGAffineTransformInvert(to_root(to)));
    return t;
}

- (CGPoint)convertPoint:(CGPoint)p fromLayer:(CALayer *)l { return CGPointApplyAffineTransform(p, between(l, self)); }
- (CGPoint)convertPoint:(CGPoint)p toLayer:(CALayer *)l { return CGPointApplyAffineTransform(p, between(self, l)); }
- (CGRect)convertRect:(CGRect)r fromLayer:(CALayer *)l { return CGRectApplyAffineTransform(r, between(l, self)); }
- (CGRect)convertRect:(CGRect)r toLayer:(CALayer *)l { return CGRectApplyAffineTransform(r, between(self, l)); }
- (CFTimeInterval)convertTime:(CFTimeInterval)t fromLayer:(CALayer *)l { return t; }
- (CFTimeInterval)convertTime:(CFTimeInterval)t toLayer:(CALayer *)l { return t; }

- (BOOL)containsPoint:(CGPoint)p
{
    return CGRectContainsPoint(_bounds, p);
}

/* p is in the superlayer's coordinates, as Core Animation's. */
- (CALayer *)hitTest:(CGPoint)p
{
    if (_f.hidden)
        return nil;
    CGPoint local = CGPointApplyAffineTransform(p, CGAffineTransformInvert(to_super(self)));
    if (_f.masksToBounds && ![self containsPoint:local])
        return nil;
    for (CALayer *s in [_sublayers reverseObjectEnumerator]) {
        CALayer *hit = [s hitTest:local];
        if (hit)
            return hit;
    }
    return [self containsPoint:local] ? self : nil;
}

- (CGSize)preferredFrameSize
{
    if ([_layoutManager respondsToSelector:@selector(preferredSizeOfLayer:)])
        return [_layoutManager preferredSizeOfLayer:self];
    return [self frame].size;
}

- (CAAutoresizingMask)autoresizingMask { return _autoresizingMask; }
- (void)setAutoresizingMask:(CAAutoresizingMask)m { _autoresizingMask = m; }

- (void)resizeSublayersWithOldSize:(CGSize)size
{
    for (CALayer *s in [[_sublayers copy] autorelease])
        [s resizeWithOldSuperlayerSize:size];
}

- (void)resizeWithOldSuperlayerSize:(CGSize)old
{
    CAAutoresizingMask m = _autoresizingMask;
    if (!m || !_superlayer)
        return;
    CGSize now = _superlayer->_bounds.size;
    CGRect f = [self frame];
    CGFloat dw = now.width - old.width, dh = now.height - old.height;
    int nx = !!(m & kCALayerMinXMargin) + !!(m & kCALayerWidthSizable) + !!(m & kCALayerMaxXMargin);
    int ny = !!(m & kCALayerMinYMargin) + !!(m & kCALayerHeightSizable) + !!(m & kCALayerMaxYMargin);
    if (nx) {
        if (m & kCALayerMinXMargin)
            f.origin.x += dw / nx;
        if (m & kCALayerWidthSizable)
            f.size.width += dw / nx;
    }
    if (ny) {
        if (m & kCALayerMinYMargin)
            f.origin.y += dh / ny;
        if (m & kCALayerHeightSizable)
            f.size.height += dh / ny;
    }
    [self setFrame:f];
}

#pragma mark The tree

- (CALayer *)superlayer { return _superlayer; }
- (NSArray<CALayer *> *)sublayers { return _sublayers ? [[_sublayers copy] autorelease] : nil; }

- (void)setSublayers:(NSArray<CALayer *> *)sublayers
{
    for (CALayer *s in [self sublayers])
        [s removeFromSuperlayer];
    for (CALayer *s in sublayers)
        [self addSublayer:s];
}

- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned)index
{
    if (!layer)
        return;
    [layer retain];
    [layer removeFromSuperlayer];
    if (!_sublayers)
        _sublayers = [[NSMutableArray alloc] init];
    [_sublayers insertObject:layer atIndex:MIN(index, (unsigned)[_sublayers count])];
    layer->_superlayer = self;
    [layer release];
    [self setNeedsLayout];
}

- (void)addSublayer:(CALayer *)layer
{
    [self insertSublayer:layer atIndex:(unsigned)[_sublayers count]];
}

- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling
{
    NSUInteger i = sibling ? [_sublayers indexOfObjectIdenticalTo:sibling] : NSNotFound;
    [self insertSublayer:layer atIndex:i == NSNotFound ? 0 : (unsigned)i];
}

- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling
{
    NSUInteger i = sibling ? [_sublayers indexOfObjectIdenticalTo:sibling] : NSNotFound;
    [self insertSublayer:layer atIndex:i == NSNotFound ? (unsigned)[_sublayers count] : (unsigned)i + 1];
}

- (void)replaceSublayer:(CALayer *)old with:(CALayer *)new
{
    NSUInteger i = [_sublayers indexOfObjectIdenticalTo:old];
    if (i == NSNotFound)
        return;
    [[old retain] autorelease];
    [old removeFromSuperlayer];
    [self insertSublayer:new atIndex:(unsigned)i];
}

- (void)removeFromSuperlayer
{
    CALayer *s = _superlayer;
    if (!s)
        return;
    changed(s);
    _superlayer = nil;
    [s->_sublayers removeObjectIdenticalTo:self];
    [s setNeedsLayout];
}

- (CALayer *)mask { return _mask; }
- (void)setMask:(CALayer *)m { [_mask autorelease]; _mask = [m retain]; }

- (CALayer *)presentationLayer { return nil; }
- (CALayer *)modelLayer { return self; }

#pragma mark Layout

- (id<CALayoutManager>)layoutManager { return _layoutManager; }
- (void)setLayoutManager:(id<CALayoutManager>)m { _layoutManager = m; }
- (BOOL)needsLayout { return _f.needsLayout; }
- (void)setNeedsLayout { _f.needsLayout = YES; changed(self); }

- (void)layoutSublayers
{
    if ([_layoutManager respondsToSelector:@selector(layoutSublayersOfLayer:)])
        [_layoutManager layoutSublayersOfLayer:self];
    if ([(id)_delegate respondsToSelector:@selector(layoutSublayersOfLayer:)])
        [_delegate layoutSublayersOfLayer:self];
}

- (void)layoutIfNeeded
{
    if (_f.needsLayout) {
        _f.needsLayout = NO;
        [self layoutSublayers];
    }
    for (CALayer *s in [[_sublayers copy] autorelease])
        [s layoutIfNeeded];
}

#pragma mark Properties

#define FLAG(get, set, field)                 \
    -(BOOL)get { return _f.field; }          \
    -(void)set:(BOOL)v { _f.field = v; changed(self); }

FLAG(isHidden, setHidden, hidden)
FLAG(masksToBounds, setMasksToBounds, masksToBounds)
FLAG(isDoubleSided, setDoubleSided, doubleSided)
FLAG(isGeometryFlipped, setGeometryFlipped, geometryFlipped)
FLAG(isOpaque, setOpaque, opaque)
FLAG(needsDisplayOnBoundsChange, setNeedsDisplayOnBoundsChange, needsDisplayOnBoundsChange)
FLAG(drawsAsynchronously, setDrawsAsynchronously, drawsAsynchronously)
FLAG(shouldRasterize, setShouldRasterize, shouldRasterize)
FLAG(allowsEdgeAntialiasing, setAllowsEdgeAntialiasing, allowsEdgeAntialiasing)
FLAG(allowsGroupOpacity, setAllowsGroupOpacity, allowsGroupOpacity)
#undef FLAG

- (BOOL)contentsAreFlipped
{
    BOOL flipped = NO;
    for (CALayer *l = self; l; l = l->_superlayer)
        if (l->_f.geometryFlipped)
            flipped = !flipped;
    return flipped;
}

- (float)opacity { return _opacity; }
- (void)setOpacity:(float)o { _opacity = o; changed(self); }
- (id)contents { return _contents; }
- (void)setContents:(id)c { [c retain]; [_contents release]; _contents = c; changed(self); }
- (CGRect)contentsRect { return _contentsRect; }
- (void)setContentsRect:(CGRect)r { _contentsRect = r; }
- (CGRect)contentsCenter { return _contentsCenter; }
- (void)setContentsCenter:(CGRect)r { _contentsCenter = r; }
- (CALayerContentsGravity)contentsGravity { return _contentsGravity; }
- (void)setContentsGravity:(CALayerContentsGravity)g { [_contentsGravity autorelease]; _contentsGravity = [g copy]; }
- (CALayerContentsFilter)minificationFilter { return _minFilter; }
- (void)setMinificationFilter:(CALayerContentsFilter)f { [_minFilter autorelease]; _minFilter = [f copy]; }
- (CALayerContentsFilter)magnificationFilter { return _magFilter; }
- (void)setMagnificationFilter:(CALayerContentsFilter)f { [_magFilter autorelease]; _magFilter = [f copy]; }
- (float)minificationFilterBias { return 0; }
- (void)setMinificationFilterBias:(float)b {}
- (CGFloat)contentsScale { return _contentsScale; }
- (void)setContentsScale:(CGFloat)s { _contentsScale = s; }
- (CGFloat)rasterizationScale { return _rasterizationScale; }
- (void)setRasterizationScale:(CGFloat)s { _rasterizationScale = s; }
- (CALayerContentsFormat)contentsFormat { return kCAContentsFormatRGBA8Uint; }
- (void)setContentsFormat:(CALayerContentsFormat)f {}

static void
set_color(CGColorRef *slot, CGColorRef c)
{
    CGColorRetain(c);
    CGColorRelease(*slot);
    *slot = c;
}

- (CGColorRef)backgroundColor { return _backgroundColor; }
- (void)setBackgroundColor:(CGColorRef)c { set_color(&_backgroundColor, c); changed(self); }
- (CGColorRef)borderColor { return _borderColor; }
- (void)setBorderColor:(CGColorRef)c { set_color(&_borderColor, c); }
- (CGColorRef)shadowColor { return _shadowColor; }
- (void)setShadowColor:(CGColorRef)c { set_color(&_shadowColor, c); }
- (CGFloat)borderWidth { return _borderWidth; }
- (void)setBorderWidth:(CGFloat)w { _borderWidth = w; }
- (CGFloat)cornerRadius { return _cornerRadius; }
- (void)setCornerRadius:(CGFloat)r { _cornerRadius = r; }
- (CACornerMask)maskedCorners { return _maskedCorners; }
- (void)setMaskedCorners:(CACornerMask)m { _maskedCorners = m; }
- (CALayerCornerCurve)cornerCurve { return kCACornerCurveCircular; }
- (void)setCornerCurve:(CALayerCornerCurve)c {}
- (float)shadowOpacity { return _shadowOpacity; }
- (void)setShadowOpacity:(float)o { _shadowOpacity = o; }
- (CGSize)shadowOffset { return _shadowOffset; }
- (void)setShadowOffset:(CGSize)o { _shadowOffset = o; }
- (CGFloat)shadowRadius { return _shadowRadius; }
- (void)setShadowRadius:(CGFloat)r { _shadowRadius = r; }
- (CGPathRef)shadowPath { return _shadowPath; }
- (void)setShadowPath:(CGPathRef)p { CGPathRetain(p); CGPathRelease(_shadowPath); _shadowPath = p; }
- (CAEdgeAntialiasingMask)edgeAntialiasingMask { return _edgeMask; }
- (void)setEdgeAntialiasingMask:(CAEdgeAntialiasingMask)m { _edgeMask = m; }
- (id<CALayerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<CALayerDelegate>)d { _delegate = d; }
- (NSString *)name { return _name; }
- (void)setName:(NSString *)n { [_name autorelease]; _name = [n copy]; }
- (NSDictionary *)actions { return _actions; }
- (void)setActions:(NSDictionary *)a { [_actions autorelease]; _actions = [a copy]; }
- (NSDictionary *)style { return _style; }
- (void)setStyle:(NSDictionary *)s { [_style autorelease]; _style = [s copy]; }
- (NSArray *)filters { return nil; }
- (void)setFilters:(NSArray *)f {}
- (NSArray *)backgroundFilters { return nil; }
- (void)setBackgroundFilters:(NSArray *)f {}
- (id)compositingFilter { return nil; }
- (void)setCompositingFilter:(id)f {}
- (NSArray *)constraints { return [_constraints count] ? [[_constraints copy] autorelease] : nil; }
- (void)setConstraints:(NSArray *)c { [_constraints release]; _constraints = [c mutableCopy]; }
- (void)addConstraint:(id)c
{
    if (!_constraints)
        _constraints = [[NSMutableArray alloc] init];
    [_constraints addObject:c];
}
- (BOOL)wantsExtendedDynamicRangeContent { return NO; }
- (void)setWantsExtendedDynamicRangeContent:(BOOL)f {}

#pragma mark Drawing

- (BOOL)needsDisplay { return _f.needsDisplay; }
- (void)setNeedsDisplay { _f.needsDisplay = YES; changed(self); }
- (void)setNeedsDisplayInRect:(CGRect)r { _f.needsDisplay = YES; changed(self); }

- (void)displayIfNeeded
{
    if (_f.needsDisplay)
        [self display];
}

/* As Core Animation's: the delegate's -displayLayer:, else draw into a fresh bitmap that becomes the contents. */
- (void)display
{
    _f.needsDisplay = NO;
    if ([(id)_delegate respondsToSelector:@selector(displayLayer:)]) {
        [_delegate displayLayer:self];
        return;
    }
    if ([(id)_delegate respondsToSelector:@selector(layerWillDraw:)])
        [_delegate layerWillDraw:self];
    size_t w = (size_t)ceil(_bounds.size.width * _contentsScale), h = (size_t)ceil(_bounds.size.height * _contentsScale);
    if (!w || !h)
        return;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!cg)
        return;
    CGContextScaleCTM(cg, _contentsScale, _contentsScale);
    /* as Core Animation's: flipped contents are drawn with y down */
    if ([self contentsAreFlipped]) {
        CGContextTranslateCTM(cg, 0, _bounds.size.height);
        CGContextScaleCTM(cg, 1, -1);
    }
    CGContextTranslateCTM(cg, -_bounds.origin.x, -_bounds.origin.y);
    [self drawInContext:cg];
    CGImageRef image = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);
    [self setContents:(id)image];
    CGImageRelease(image);
}

- (void)drawInContext:(CGContextRef)ctx
{
    if ([(id)_delegate respondsToSelector:@selector(drawLayer:inContext:)])
        [_delegate drawLayer:self inContext:ctx];
}

/* Where the contents go in the bounds, by the gravity. */
static CGRect
contents_rect(CALayer *l, CGSize image)
{
    CGRect b = l->_bounds;
    NSString *g = l->_contentsGravity;
    CGSize s = CGSizeMake(image.width / l->_contentsScale, image.height / l->_contentsScale);
    if ([g isEqualToString:kCAGravityResize] || !s.width || !s.height)
        return b;
    if ([g isEqualToString:kCAGravityResizeAspect] || [g isEqualToString:kCAGravityResizeAspectFill]) {
        CGFloat k = [g isEqualToString:kCAGravityResizeAspect] ? MIN(b.size.width / s.width, b.size.height / s.height)
                                                               : MAX(b.size.width / s.width, b.size.height / s.height);
        s = CGSizeMake(s.width * k, s.height * k);
        return CGRectMake(CGRectGetMidX(b) - s.width / 2, CGRectGetMidY(b) - s.height / 2, s.width, s.height);
    }
    CGFloat x = CGRectGetMidX(b) - s.width / 2, y = CGRectGetMidY(b) - s.height / 2;
    if ([g hasSuffix:@"eft"])  /* left, topLeft, bottomLeft */
        x = CGRectGetMinX(b);
    if ([g hasSuffix:@"ight"])
        x = CGRectGetMaxX(b) - s.width;
    if ([g hasPrefix:@"top"])
        y = CGRectGetMaxY(b) - s.height;
    if ([g hasPrefix:@"bottom"])
        y = CGRectGetMinY(b);
    return CGRectMake(x, y, s.width, s.height);
}

static CGPathRef
rounded(CGRect r, CGFloat radius)
{
    radius = MIN(radius, MIN(r.size.width, r.size.height) / 2);
    return CGPathCreateWithRoundedRect(r, radius, radius, NULL);
}

/* The layer in its own coordinates; the caller has placed them. */
- (void)_finchRenderInContext:(CGContextRef)cg
{
    if (_f.hidden || _opacity <= 0)
        return;
    CGContextSaveGState(cg);
    if (_shadowOpacity > 0 && _shadowColor) {
        CGColorRef sc = CGColorCreateCopyWithAlpha(_shadowColor, CGColorGetAlpha(_shadowColor) * _shadowOpacity);
        CGContextSetShadowWithColor(cg, _shadowOffset, _shadowRadius, sc);
        CGColorRelease(sc);
    }
    if (_opacity < 1)
        CGContextSetAlpha(cg, _opacity);
    CGContextBeginTransparencyLayer(cg, NULL);
    CGContextSetShadowWithColor(cg, CGSizeZero, 0, NULL);
    CGPathRef shape = _cornerRadius > 0 ? rounded(_bounds, _cornerRadius) : CGPathCreateWithRect(_bounds, NULL);
    if (_backgroundColor) {
        CGContextAddPath(cg, shape);
        CGContextSetFillColorWithColor(cg, _backgroundColor);
        CGContextFillPath(cg);
    }
    CGContextSaveGState(cg);
    if (_f.masksToBounds) {
        CGContextAddPath(cg, shape);
        CGContextClip(cg);
    }
    if (_f.needsDisplay)
        [self display];
    if (_contents && CFGetTypeID((CFTypeRef)_contents) == CGImageGetTypeID()) {
        CGImageRef image = (CGImageRef)_contents;
        CGRect r = contents_rect(self, CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image)));
        CGContextSaveGState(cg);
        if ([self contentsAreFlipped]) {
            CGContextTranslateCTM(cg, 0, CGRectGetMinY(r) + CGRectGetMaxY(r));
            CGContextScaleCTM(cg, 1, -1);
        }
        CGContextDrawImage(cg, r, image);
        CGContextRestoreGState(cg);
    } else if (_contents && [_contents respondsToSelector:@selector(CGImageForProposedRect:context:hints:)]) {
        CGRect r = _bounds;
        CGImageRef image = [_contents CGImageForProposedRect:&r context:nil hints:nil];
        if (image)
            CGContextDrawImage(cg, contents_rect(self, CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image))), image);
    }
    [self _finchDrawContent:cg];
    NSArray *ordered = [_sublayers sortedArrayWithOptions:NSSortStable
                                          usingComparator:^NSComparisonResult(CALayer *a, CALayer *b) {
                                              return a->_zPosition < b->_zPosition ? NSOrderedAscending
                                                     : a->_zPosition > b->_zPosition ? NSOrderedDescending
                                                                                     : NSOrderedSame;
                                          }];
    for (CALayer *s in ordered) {
        CGContextSaveGState(cg);
        CGContextConcatCTM(cg, to_super(s));
        [s _finchRenderInContext:cg];
        CGContextRestoreGState(cg);
    }
    CGContextRestoreGState(cg);
    if (_borderWidth > 0 && _borderColor) {
        CGPathRef inner = _cornerRadius > 0
                              ? rounded(CGRectInset(_bounds, _borderWidth / 2, _borderWidth / 2), _cornerRadius - _borderWidth / 2)
                              : CGPathCreateWithRect(CGRectInset(_bounds, _borderWidth / 2, _borderWidth / 2), NULL);
        CGContextAddPath(cg, inner);
        CGContextSetStrokeColorWithColor(cg, _borderColor);
        CGContextSetLineWidth(cg, _borderWidth);
        CGContextStrokePath(cg);
        CGPathRelease(inner);
    }
    CGPathRelease(shape);
    if (_mask) {
        /* the mask, in this layer's space, keeps what's under its opaque parts */
        CGContextSaveGState(cg);
        CGContextSetBlendMode(cg, kCGBlendModeDestinationIn);
        CGContextBeginTransparencyLayer(cg, NULL);
        CGContextConcatCTM(cg, to_super(_mask));
        [_mask _finchRenderInContext:cg];
        CGContextEndTransparencyLayer(cg);
        CGContextRestoreGState(cg);
    }
    CGContextEndTransparencyLayer(cg);
    CGContextRestoreGState(cg);
}

/* What a subclass draws itself, without contents (a shape, a gradient), over the contents and under the sublayers. */
- (void)_finchDrawContent:(CGContextRef)cg {}

- (void)renderInContext:(CGContextRef)ctx
{
    [self _finchRenderInContext:ctx];
}

#pragma mark Actions and animations

+ (id<CAAction>)defaultActionForKey:(NSString *)event { return nil; }

/* As Core Animation's: the delegate, the actions dictionary, the style, then the class. */
- (id<CAAction>)actionForKey:(NSString *)event
{
    if ([(id)_delegate respondsToSelector:@selector(actionForLayer:forKey:)]) {
        id a = [_delegate actionForLayer:self forKey:event];
        if (a)
            return a == [NSNull null] ? nil : a;
    }
    id a = _actions[event];
    if (a)
        return a == [NSNull null] ? nil : a;
    a = _style[@"actions"][event];
    if (a)
        return a == [NSNull null] ? nil : a;
    return [[self class] defaultActionForKey:event];
}

- (void)addAnimation:(CAAnimation *)anim forKey:(NSString *)key
{
    if (!anim)
        return;
    if (!_animations) {
        _animations = [[NSMutableDictionary alloc] init];
        _animationKeys = [[NSMutableArray alloc] init];
    }
    if (!key)
        key = [NSString stringWithFormat:@"finch.%p", anim];
    CAAnimation *copy = [[anim copy] autorelease];
    if (!_animations[key])
        [_animationKeys addObject:key];
    _animations[key] = copy;
    /* No render server plays it: it ends unplayed a turn later, after the transaction's completion. */
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            id delegate = [copy delegate];
            if ([delegate respondsToSelector:@selector(animationDidStart:)])
                [delegate animationDidStart:copy];
            if ([copy isRemovedOnCompletion] && _animations[key] == copy) {
                [_animations removeObjectForKey:key];
                [_animationKeys removeObject:key];
            }
            if ([delegate respondsToSelector:@selector(animationDidStop:finished:)])
                [delegate animationDidStop:copy finished:NO];
            [self release];
        });
    });
}

- (CAAnimation *)animationForKey:(NSString *)key { return _animations[key]; }
- (NSArray<NSString *> *)animationKeys { return [_animationKeys count] ? [[_animationKeys copy] autorelease] : nil; }

- (void)removeAnimationForKey:(NSString *)key
{
    [_animations removeObjectForKey:key];
    [_animationKeys removeObject:key];
}

- (void)removeAllAnimations
{
    [_animations removeAllObjects];
    [_animationKeys removeAllObjects];
}

#pragma mark CAMediaTiming (a layer's own timing)

- (CFTimeInterval)beginTime { return 0; }
- (void)setBeginTime:(CFTimeInterval)t {}
- (CFTimeInterval)duration { return 0; }
- (void)setDuration:(CFTimeInterval)d {}
- (float)speed { return 1; }
- (void)setSpeed:(float)s {}
- (CFTimeInterval)timeOffset { return 0; }
- (void)setTimeOffset:(CFTimeInterval)t {}
- (float)repeatCount { return 0; }
- (void)setRepeatCount:(float)c {}
- (CFTimeInterval)repeatDuration { return 0; }
- (void)setRepeatDuration:(CFTimeInterval)d {}
- (BOOL)autoreverses { return NO; }
- (void)setAutoreverses:(BOOL)f {}
- (CAMediaTimingFillMode)fillMode { return kCAFillModeRemoved; }
- (void)setFillMode:(CAMediaTimingFillMode)m {}

@end
