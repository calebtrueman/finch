/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Core Animation's animation objects, timing functions and transactions.
 *
 * The objects keep what the app gives them and answer as Core Animation's
 * do (defaults, copying, the spring's settling time, the timing curves).
 * Nothing plays them yet: CALayer ends each one as it's added.
 */
#import <QuartzCore/QuartzCore.h>
#include <math.h>

#pragma mark CAMediaTimingFunction

@implementation CAMediaTimingFunction {
    float _c[4];  /* the two inner control points; the outer ones are (0,0) and (1,1) */
}

+ (instancetype)functionWithName:(CAMediaTimingFunctionName)name
{
    static const struct {
        NSString *const *name;
        float c[4];
    } table[] = {
        {&kCAMediaTimingFunctionLinear, {0, 0, 1, 1}},
        {&kCAMediaTimingFunctionEaseIn, {0.42f, 0, 1, 1}},
        {&kCAMediaTimingFunctionEaseOut, {0, 0, 0.58f, 1}},
        {&kCAMediaTimingFunctionEaseInEaseOut, {0.42f, 0, 0.58f, 1}},
        {&kCAMediaTimingFunctionDefault, {0.25f, 0.1f, 0.25f, 1}},
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
        if ([name isEqualToString:*table[i].name]) {
            const float *c = table[i].c;
            return [self functionWithControlPoints:c[0]:c[1]:c[2]:c[3]];
        }
    return nil;
}

+ (instancetype)functionWithControlPoints:(float)c1x :(float)c1y :(float)c2x :(float)c2y
{
    return [[[self alloc] initWithControlPoints:c1x:c1y:c2x:c2y] autorelease];
}

- (instancetype)initWithControlPoints:(float)c1x :(float)c1y :(float)c2x :(float)c2y
{
    self = [super init];
    if (self) {
        _c[0] = c1x, _c[1] = c1y, _c[2] = c2x, _c[3] = c2y;
    }
    return self;
}

- (void)getControlPointAtIndex:(size_t)idx values:(float[2])ptr
{
    switch (idx) {
    case 0: ptr[0] = 0, ptr[1] = 0; break;
    case 1: ptr[0] = _c[0], ptr[1] = _c[1]; break;
    case 2: ptr[0] = _c[2], ptr[1] = _c[3]; break;
    default: ptr[0] = 1, ptr[1] = 1; break;
    }
}

static double
bezier(double a, double b, double t)
{
    return 3 * a * t * (1 - t) * (1 - t) + 3 * b * t * t * (1 - t) + t * t * t;
}

/* The curve's y at x (Newton's method, then bisection if it stalls). */
- (float)_solveForInput:(float)x
{
    if (x <= 0 || x >= 1)
        return x <= 0 ? 0 : 1;
    double t = x;
    for (int i = 0; i < 8; i++) {
        double e = bezier(_c[0], _c[2], t) - x;
        double d = 3 * _c[0] * (1 - t) * (1 - t) + 6 * (_c[2] - _c[0]) * t * (1 - t) + 3 * (1 - _c[2]) * t * t;
        if (fabs(e) < 1e-7)
            return (float)bezier(_c[1], _c[3], t);
        if (fabs(d) < 1e-6)
            break;
        t -= e / d;
    }
    double lo = 0, hi = 1;
    t = x;
    for (int i = 0; i < 40; i++) {
        double v = bezier(_c[0], _c[2], t);
        if (v < x)
            lo = t;
        else
            hi = t;
        t = (lo + hi) / 2;
    }
    return (float)bezier(_c[1], _c[3], t);
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self initWithControlPoints:[coder decodeFloatForKey:@"c1x"]:[coder decodeFloatForKey:@"c1y"]
                                      :[coder decodeFloatForKey:@"c2x"]:[coder decodeFloatForKey:@"c2y"]];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeFloat:_c[0] forKey:@"c1x"];
    [coder encodeFloat:_c[1] forKey:@"c1y"];
    [coder encodeFloat:_c[2] forKey:@"c2x"];
    [coder encodeFloat:_c[3] forKey:@"c2y"];
}
+ (BOOL)supportsSecureCoding { return YES; }

- (BOOL)isEqual:(id)o
{
    if (![o isKindOfClass:[CAMediaTimingFunction class]])
        return NO;
    CAMediaTimingFunction *f = o;
    return !memcmp(_c, f->_c, sizeof _c);
}

- (NSUInteger)hash { return (NSUInteger)(_c[0] * 1000 + _c[1] * 100 + _c[2] * 10 + _c[3]); }

@end

#pragma mark CAValueFunction

@implementation CAValueFunction {
    NSString *_name;
}

+ (instancetype)functionWithName:(CAValueFunctionName)name
{
    CAValueFunction *f = [[[self alloc] init] autorelease];
    f->_name = [name copy];
    return f;
}

- (CAValueFunctionName)name { return _name; }
- (void)dealloc { [_name release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self)
        _name = [[coder decodeObjectOfClass:[NSString class] forKey:@"name"] copy];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_name forKey:@"name"]; }
+ (BOOL)supportsSecureCoding { return YES; }

@end

#pragma mark CAAnimation

/*
 * Each animation keeps its values in a dictionary, as Core Animation's
 * archive does: properties read through it with their defaults, which keeps
 * copying and coding the same for every subclass.
 */
@implementation CAAnimation {
@protected
    NSMutableDictionary *_v;
    id _delegate;
}

+ (instancetype)animation
{
    return [[[self alloc] init] autorelease];
}

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
    [_delegate release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    CAAnimation *c = [[[self class] allocWithZone:zone] init];
    [c->_v setDictionary:_v];
    c->_delegate = [_delegate retain];
    return c;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self init];
    if (self) {
        NSDictionary *d = [coder decodeObjectForKey:@"values"];
        if ([d isKindOfClass:[NSDictionary class]])
            [_v setDictionary:d];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_v forKey:@"values"]; }
+ (BOOL)supportsSecureCoding { return YES; }

+ (id)defaultValueForKey:(NSString *)key { return nil; }
- (BOOL)shouldArchiveValueForKey:(NSString *)key { return NO; }

- (id)_get:(NSString *)key
{
    id v = _v[key];
    return v ?: [[self class] defaultValueForKey:key];
}

- (void)_set:(id)v key:(NSString *)key
{
    if (v)
        _v[key] = v;
    else
        [_v removeObjectForKey:key];
}

- (void)setValue:(id)value forUndefinedKey:(NSString *)key { [self _set:value key:key]; }
- (id)valueForUndefinedKey:(NSString *)key { return [self _get:key]; }

#define DOUBLE(get, set, K, def)                                    \
    -(double)get { id v = [self _get:K]; return v ? [v doubleValue] : def; } \
    -(void)set:(double)x { [self _set:@(x) key:K]; }
#define FLOAT(get, set, K, def)                                     \
    -(float)get { id v = [self _get:K]; return v ? [v floatValue] : def; } \
    -(void)set:(float)x { [self _set:@(x) key:K]; }
#define BOOLV(get, set, K, def)                                     \
    -(BOOL)get { id v = [self _get:K]; return v ? [v boolValue] : def; } \
    -(void)set:(BOOL)x { [self _set:@(x) key:K]; }
#define OBJECT(type, get, set, K)                                   \
    -(type)get { return [self _get:K]; }                            \
    -(void)set:(type)x { [self _set:x key:K]; }

DOUBLE(beginTime, setBeginTime, @"beginTime", 0)
DOUBLE(duration, setDuration, @"duration", 0)
DOUBLE(timeOffset, setTimeOffset, @"timeOffset", 0)
DOUBLE(repeatDuration, setRepeatDuration, @"repeatDuration", 0)
FLOAT(speed, setSpeed, @"speed", 1)
FLOAT(repeatCount, setRepeatCount, @"repeatCount", 0)
BOOLV(autoreverses, setAutoreverses, @"autoreverses", NO)
BOOLV(isRemovedOnCompletion, setRemovedOnCompletion, @"removedOnCompletion", YES)
OBJECT(CAMediaTimingFunction *, timingFunction, setTimingFunction, @"timingFunction")

- (CAMediaTimingFillMode)fillMode { return [self _get:@"fillMode"] ?: kCAFillModeRemoved; }
- (void)setFillMode:(CAMediaTimingFillMode)m { [self _set:m key:@"fillMode"]; }

- (id<CAAnimationDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<CAAnimationDelegate>)d
{
    /* retained, as Core Animation's is */
    [d retain];
    [_delegate release];
    _delegate = d;
}

- (CAFrameRateRange)preferredFrameRateRange { return CAFrameRateRangeDefault; }
- (void)setPreferredFrameRateRange:(CAFrameRateRange)r {}

- (void)runActionForKey:(NSString *)event object:(id)anObject arguments:(NSDictionary *)dict
{
    if ([anObject isKindOfClass:[CALayer class]])
        [(CALayer *)anObject addAnimation:self forKey:event];
}

@end

@implementation CAPropertyAnimation

+ (instancetype)animationWithKeyPath:(NSString *)path
{
    CAPropertyAnimation *a = [self animation];
    [a setKeyPath:path];
    return a;
}

- (NSString *)keyPath { return [self _get:@"keyPath"]; }
- (void)setKeyPath:(NSString *)p { [self _set:[[p copy] autorelease] key:@"keyPath"]; }
BOOLV(isAdditive, setAdditive, @"additive", NO)
BOOLV(isCumulative, setCumulative, @"cumulative", NO)
OBJECT(CAValueFunction *, valueFunction, setValueFunction, @"valueFunction")

@end

@implementation CABasicAnimation
OBJECT(id, fromValue, setFromValue, @"fromValue")
OBJECT(id, toValue, setToValue, @"toValue")
OBJECT(id, byValue, setByValue, @"byValue")
@end

@implementation CAKeyframeAnimation
OBJECT(NSArray *, values, setValues, @"values")
OBJECT(NSArray<NSNumber *> *, keyTimes, setKeyTimes, @"keyTimes")
OBJECT(NSArray<CAMediaTimingFunction *> *, timingFunctions, setTimingFunctions, @"timingFunctions")
OBJECT(NSArray<NSNumber *> *, tensionValues, setTensionValues, @"tensionValues")
OBJECT(NSArray<NSNumber *> *, continuityValues, setContinuityValues, @"continuityValues")
OBJECT(NSArray<NSNumber *> *, biasValues, setBiasValues, @"biasValues")
OBJECT(CAAnimationRotationMode, rotationMode, setRotationMode, @"rotationMode")

- (CAAnimationCalculationMode)calculationMode { return [self _get:@"calculationMode"] ?: kCAAnimationLinear; }
- (void)setCalculationMode:(CAAnimationCalculationMode)m { [self _set:m key:@"calculationMode"]; }

- (CGPathRef)path { return (CGPathRef)[self _get:@"path"]; }
- (void)setPath:(CGPathRef)p
{
    CGPathRef copy = p ? CGPathCreateCopy(p) : NULL;
    [self _set:(id)copy key:@"path"];
    CGPathRelease(copy);
}
@end

@implementation CASpringAnimation

- (instancetype)initWithPerceptualDuration:(CFTimeInterval)duration bounce:(CGFloat)bounce
{
    self = [self init];
    if (self) {
        [self setMass:1];
        [self setStiffness:pow(2 * M_PI / duration, 2)];
        [self setDamping:bounce >= 0 ? 4 * M_PI * (1 - bounce) / duration : 4 * M_PI / (duration * (1 + bounce))];
        [self setDuration:[self settlingDuration]];
    }
    return self;
}

DOUBLE(mass, setMass, @"mass", 1)
DOUBLE(stiffness, setStiffness, @"stiffness", 100)
DOUBLE(damping, setDamping, @"damping", 10)
DOUBLE(initialVelocity, setInitialVelocity, @"initialVelocity", 0)
BOOLV(allowsOverdamping, setAllowsOverdamping, @"allowsOverdamping", NO)

- (CGFloat)perceptualDuration { return 2 * M_PI / sqrt([self stiffness] / [self mass]); }
- (CGFloat)bounce
{
    double d = [self perceptualDuration], damping = [self damping];
    double b = 1 - damping * d / (4 * M_PI);
    return b >= 0 ? b : 4 * M_PI / (damping * d) - 1;
}

/*
 * As Core Animation's: an underdamped spring settles when the bound on its
 * swing, (|A| + |B|) e^(-ζω t), falls to a thousandth of the distance; a
 * critically or overdamped one is taken as critical, sampled every tenth
 * of a second until it stays within that thousandth.
 */
- (CFTimeInterval)settlingDuration
{
    double m = [self mass], k = [self stiffness], c = [self damping], v0 = [self initialVelocity];
    if (m <= 0 || k <= 0)
        return 0;
    double w0 = sqrt(k / m), zw = c / (2 * m);
    if (zw < w0) {
        double wd = sqrt(w0 * w0 - zw * zw);
        double amp = 1 + fabs((zw - v0) / wd);
        return log(1000 * amp) / zw;
    }
    double last = 0;
    for (int i = 1; i <= 10000; i++) {
        double t = i * 0.1;
        if (fabs((1 + (w0 - v0) * t) * exp(-w0 * t)) >= 0.001)
            last = t;
        else if (t - last > 20 / w0)
            break;
    }
    return round((last + 0.1) * 10) / 10;
}

@end

@implementation CATransition
OBJECT(CATransitionSubtype, subtype, setSubtype, @"subtype")
FLOAT(startProgress, setStartProgress, @"startProgress", 0)
FLOAT(endProgress, setEndProgress, @"endProgress", 1)
OBJECT(id, filter, setFilter, @"filter")
- (CATransitionType)type { return [self _get:@"type"] ?: kCATransitionFade; }
- (void)setType:(CATransitionType)t { [self _set:t key:@"type"]; }
@end

@implementation CAAnimationGroup
OBJECT(NSArray<CAAnimation *> *, animations, setAnimations, @"animations")
@end

#pragma mark CATransaction

/*
 * A stack of open transactions per thread. The values of the innermost are
 * what the class answers; outside any, the defaults. A completion block runs
 * on the main queue once the transaction it belongs to is committed, as
 * Core Animation's runs when that transaction's animations are done.
 */
@interface FinchTransaction : NSObject {
@public
    NSMutableDictionary *values;
}
@end
@implementation FinchTransaction
- (instancetype)init
{
    self = [super init];
    if (self)
        values = [[NSMutableDictionary alloc] init];
    return self;
}
- (void)dealloc
{
    [values release];
    [super dealloc];
}
@end

static NSString *const kStack = @"FinchCATransactionStack";

static NSMutableArray<FinchTransaction *> *
stack(void)
{
    NSMutableDictionary *td = [[NSThread currentThread] threadDictionary];
    NSMutableArray *s = td[kStack];
    if (!s) {
        s = [NSMutableArray array];
        td[kStack] = s;
    }
    return s;
}

@implementation CATransaction

+ (void)begin
{
    FinchTransaction *t = [[FinchTransaction alloc] init];
    [stack() addObject:t];
    [t release];
}

+ (void)commit
{
    NSMutableArray *s = stack();
    FinchTransaction *t = [[[s lastObject] retain] autorelease];
    if (!t)
        return;
    [s removeLastObject];
    void (^block)(void) = t->values[kCATransactionCompletionBlock];
    if (block)
        dispatch_async(dispatch_get_main_queue(), block);
}

+ (void)flush {}
+ (void)lock {}
+ (void)unlock {}

+ (id)valueForKey:(NSString *)key
{
    for (FinchTransaction *t in [stack() reverseObjectEnumerator]) {
        id v = t->values[key];
        if (v)
            return v;
    }
    return nil;
}

+ (void)setValue:(id)value forKey:(NSString *)key
{
    FinchTransaction *t = [stack() lastObject];
    if (!t)
        return;
    if (value)
        t->values[key] = value;
    else
        [t->values removeObjectForKey:key];
}

+ (CFTimeInterval)animationDuration
{
    id v = [self valueForKey:kCATransactionAnimationDuration];
    return v ? [v doubleValue] : 0.25;
}
+ (void)setAnimationDuration:(CFTimeInterval)d { [self setValue:@(d) forKey:kCATransactionAnimationDuration]; }
+ (CAMediaTimingFunction *)animationTimingFunction { return [self valueForKey:kCATransactionAnimationTimingFunction]; }
+ (void)setAnimationTimingFunction:(CAMediaTimingFunction *)f
{
    [self setValue:f forKey:kCATransactionAnimationTimingFunction];
}
+ (BOOL)disableActions { return [[self valueForKey:kCATransactionDisableActions] boolValue]; }
+ (void)setDisableActions:(BOOL)flag { [self setValue:@(flag) forKey:kCATransactionDisableActions]; }
+ (void (^)(void))completionBlock { return [self valueForKey:kCATransactionCompletionBlock]; }

+ (void)setCompletionBlock:(void (^)(void))block
{
    [self setValue:[[block copy] autorelease] forKey:kCATransactionCompletionBlock];
}

@end
