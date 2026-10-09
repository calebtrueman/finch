/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Animation: NSAnimationContext, the animator proxies of views, windows and
 * constraints (NSAnimatablePropertyContainer), and NSAnimation and
 * NSViewAnimation.
 *
 * Finch has no compositor animation yet, so an animator sets its target's
 * values at once: what Apple's shows at the end of the animation, which is
 * also what its getters answer meanwhile. Grouping, durations and
 * completion handlers behave as Apple's (completions run on the main queue
 * once the group closes). NSAnimation runs on a timer, or in a loop when
 * blocking, with Apple's curves, progress marks and delegate calls.
 */
#import "NSView_Finch.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark NSAnimationContext

@implementation NSAnimationContext {
    NSTimeInterval _duration;
    CAMediaTimingFunction *_timing;
    void (^_completion)(void);
    BOOL _implicit;
}

static NSString *const kStack = @"FinchAnimationContextStack";

static NSMutableArray<NSAnimationContext *> *
stack(void)
{
    NSMutableDictionary *td = [[NSThread currentThread] threadDictionary];
    NSMutableArray *s = td[kStack];
    if (!s) {
        s = [NSMutableArray array];
        NSAnimationContext *base = [[NSAnimationContext alloc] init];
        [s addObject:base];
        [base release];
        td[kStack] = s;
    }
    return s;
}

- (instancetype)init
{
    self = [super init];
    if (self)
        _duration = 0.25;
    return self;
}

- (void)dealloc
{
    [_timing release];
    [_completion release];
    [super dealloc];
}

/* Outside any group, the thread's base context (the same object each time, as Apple's). */
+ (NSAnimationContext *)currentContext { return [stack() firstObject]; }

+ (void)beginGrouping
{
    NSAnimationContext *outer = [self currentContext];
    NSAnimationContext *c = [[NSAnimationContext alloc] init];
    c->_duration = outer->_duration;
    c->_timing = [outer->_timing retain];
    c->_implicit = outer->_implicit;
    c->_completion = [outer->_completion copy];
    [outer setCompletionHandler:nil];
    [stack() addObject:c];
    [c release];
}

+ (void)endGrouping
{
    NSMutableArray *s = stack();
    if ([s count] < 2)
        return;
    NSAnimationContext *saved = [[[s lastObject] retain] autorelease];
    NSAnimationContext *current = [self currentContext];
    if (current->_completion)
        dispatch_async(dispatch_get_main_queue(), current->_completion);
    [current setDuration:saved->_duration];
    [current setTimingFunction:saved->_timing];
    [current setAllowsImplicitAnimation:saved->_implicit];
    [current setCompletionHandler:saved->_completion];
    [s removeLastObject];
}

+ (void)runAnimationGroup:(void (NS_NOESCAPE ^)(NSAnimationContext *))changes completionHandler:(void (^)(void))completionHandler
{
    [self beginGrouping];
    NSAnimationContext *c = [self currentContext];
    if (completionHandler)
        [c setCompletionHandler:completionHandler];
    @try {
        if (changes)
            changes(c);
    } @finally {
        [self endGrouping];
    }
}

+ (void)runAnimationGroup:(void (NS_NOESCAPE ^)(NSAnimationContext *))changes
{
    [self runAnimationGroup:changes completionHandler:nil];
}

- (NSTimeInterval)duration { return _duration; }
- (void)setDuration:(NSTimeInterval)d { _duration = d; }
- (CAMediaTimingFunction *)timingFunction { return _timing; }
- (void)setTimingFunction:(CAMediaTimingFunction *)f { [_timing autorelease]; _timing = [f retain]; }
- (void (^)(void))completionHandler { return _completion; }
- (void)setCompletionHandler:(void (^)(void))h { [_completion autorelease]; _completion = [h copy]; }
- (BOOL)allowsImplicitAnimation { return _implicit; }
- (void)setAllowsImplicitAnimation:(BOOL)f { _implicit = f; }

@end

#pragma mark The animator proxy

/*
 * Forwards everything to its target; it answers -class and kind-of as the
 * target does (Apple's is a proxy of a class named after the target's).
 */
@interface FinchAnimator : NSProxy {
@public
    __weak id _target;  /* The target keeps its animator. */
}
@end

@implementation FinchAnimator

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [_target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)inv { [inv invokeWithTarget:_target]; }
- (id)forwardingTargetForSelector:(SEL)sel { return _target; }
- (BOOL)respondsToSelector:(SEL)sel { return [_target respondsToSelector:sel]; }
- (BOOL)isKindOfClass:(Class)c { return [_target isKindOfClass:c]; }
- (BOOL)isMemberOfClass:(Class)c { return [_target isMemberOfClass:c]; }
- (BOOL)conformsToProtocol:(Protocol *)p { return [_target conformsToProtocol:p]; }
- (Class)class { return [_target class]; }
- (NSString *)description { return [_target description]; }
- (id)animator { return self; }

@end

/* The animator of an object, kept with it (the same proxy each time, as Apple's). */
static id
animator_of(id target)
{
    static const void *key = &key;
    FinchAnimator *a = objc_getAssociatedObject(target, key);
    if (!a) {
        a = [FinchAnimator alloc];
        a->_target = target;
        objc_setAssociatedObject(target, key, a, OBJC_ASSOCIATION_RETAIN);
        [a release];
    }
    return a;
}

static const void *kAnimations = &kAnimations;

static id
default_animation(NSString *key)
{
    static NSSet *keys;
    if (!keys)
        keys = [[NSSet alloc] initWithObjects:@"frame", @"frameOrigin", @"frameSize", @"bounds", @"boundsOrigin",
                                              @"boundsSize", @"alphaValue", @"frameRotation", @"frameCenterRotation",
                                              @"boundsRotation", @"backgroundFilters", @"contentFilters",
                                              @"compositingFilter", @"shadow", @"constant", nil];
    if (![keys containsObject:key])
        return nil;
    static CABasicAnimation *basic;
    if (!basic)
        basic = [[CABasicAnimation animation] retain];
    return basic;
}

#define ANIMATABLE_CONTAINER                                                                                 \
    -(instancetype)animator { return animator_of(self); }                                                   \
    -(NSDictionary<NSAnimatablePropertyKey, id> *)animations                                                \
    {                                                                                                        \
        return objc_getAssociatedObject(self, kAnimations) ?: @{};                                           \
    }                                                                                                        \
    -(void)setAnimations:(NSDictionary<NSAnimatablePropertyKey, id> *)a                                     \
    {                                                                                                        \
        objc_setAssociatedObject(self, kAnimations, [[a copy] autorelease], OBJC_ASSOCIATION_RETAIN);        \
    }                                                                                                        \
    -(id)animationForKey:(NSAnimatablePropertyKey)key                                                       \
    {                                                                                                        \
        id a = [objc_getAssociatedObject(self, kAnimations) objectForKey:key];                              \
        return a ?: [[self class] defaultAnimationForKey:key];                                               \
    }                                                                                                        \
    +(id)defaultAnimationForKey:(NSAnimatablePropertyKey)key { return default_animation(key); }

@implementation NSView (NSAnimatablePropertyContainer)
ANIMATABLE_CONTAINER
@end

@implementation NSWindow (NSAnimatablePropertyContainer)
ANIMATABLE_CONTAINER
@end

@implementation NSLayoutConstraint (NSAnimatablePropertyContainer)
ANIMATABLE_CONTAINER
@end

@implementation NSWindow (FinchAnimationResize)
/* As Apple's: the default resize time, 0.2 s per 150 points the frame's corner moves. */
- (NSTimeInterval)animationResizeTime:(NSRect)newFrame
{
    NSRect f = [self frame];
    CGFloat dx = fabs(NSWidth(newFrame) - NSWidth(f)), dy = fabs(NSHeight(newFrame) - NSHeight(f));
    return sqrt(dx * dx + dy * dy) / 150 * 0.2;
}
@end

#pragma mark NSAnimation

NSAnimationProgress
FinchAnimationCurveValue(NSAnimationCurve curve, NSAnimationProgress t)
{
    switch (curve) {
    case NSAnimationEaseInOut: return (float)((1 - cos(t * M_PI)) / 2);
    case NSAnimationEaseIn: return (float)(1 - cos(t * M_PI_2));
    case NSAnimationEaseOut: return (float)sin(t * M_PI_2);
    default: return t;
    }
}

NSNotificationName NSAnimationProgressMarkNotification = @"NSAnimationProgressMarkNotification";
NSString *NSAnimationProgressMark = @"NSAnimationProgressMark";
NSAnimatablePropertyKey NSAnimationTriggerOrderIn = @"NSAnimationTriggerOrderIn";
NSAnimatablePropertyKey NSAnimationTriggerOrderOut = @"NSAnimationTriggerOrderOut";

@implementation NSAnimation {
    NSTimeInterval _duration;
    NSAnimationCurve _curve;
    NSAnimationBlockingMode _blocking;
    float _frameRate;
    NSAnimationProgress _progress;
    NSArray<NSNumber *> *_marks;
    NSUInteger _nextMark;
    id<NSAnimationDelegate> _delegate;
    NSTimer *_timer;
    NSDate *_start;
    NSArray *_modes;
    BOOL _animating;
}

- (instancetype)initWithDuration:(NSTimeInterval)duration animationCurve:(NSAnimationCurve)curve
{
    self = [super init];
    if (self) {
        _duration = duration;
        _curve = curve;
        _marks = [[NSArray alloc] init];
    }
    return self;
}

- (instancetype)init { return [self initWithDuration:0 animationCurve:NSAnimationEaseInOut]; }

- (instancetype)initWithCoder:(NSCoder *)coder { return [self init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
- (id)copyWithZone:(NSZone *)zone
{
    NSAnimation *a = [[[self class] allocWithZone:zone] initWithDuration:_duration animationCurve:_curve];
    a->_blocking = _blocking;
    a->_frameRate = _frameRate;
    [a setProgressMarks:_marks];
    return a;
}

- (void)dealloc
{
    [_timer invalidate];
    [_marks release];
    [_start release];
    [_modes release];
    [super dealloc];
}

- (NSTimeInterval)duration { return _duration; }
- (void)setDuration:(NSTimeInterval)d
{
    if (d < 0)
        [NSException raise:NSInvalidArgumentException format:@"%@: duration must be 0 or more", self];
    _duration = d;
}
- (NSAnimationCurve)animationCurve { return _curve; }
- (void)setAnimationCurve:(NSAnimationCurve)c { _curve = c; }
- (NSAnimationBlockingMode)animationBlockingMode { return _blocking; }
- (void)setAnimationBlockingMode:(NSAnimationBlockingMode)m { _blocking = m; }
- (float)frameRate { return _frameRate; }
- (void)setFrameRate:(float)r { _frameRate = MAX(r, 0); }
- (id<NSAnimationDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSAnimationDelegate>)d { _delegate = d; }
- (NSArray<NSRunLoopMode> *)runLoopModesForAnimating { return _modes; }
- (BOOL)isAnimating { return _animating; }
- (NSAnimationProgress)currentProgress { return _progress; }

- (float)currentValue
{
    if ([(id)_delegate respondsToSelector:@selector(animation:valueForProgress:)])
        return [_delegate animation:self valueForProgress:_progress];
    return FinchAnimationCurveValue(_curve, _progress);
}

- (NSArray<NSNumber *> *)progressMarks { return _marks; }
- (void)setProgressMarks:(NSArray<NSNumber *> *)marks
{
    [_marks autorelease];
    _marks = [[marks sortedArrayUsingSelector:@selector(compare:)] copy] ?: [[NSArray alloc] init];
}
- (void)addProgressMark:(NSAnimationProgress)p { [self setProgressMarks:[_marks arrayByAddingObject:@(p)]]; }
- (void)removeProgressMark:(NSAnimationProgress)p
{
    NSMutableArray *m = [[_marks mutableCopy] autorelease];
    [m removeObject:@(p)];
    [self setProgressMarks:m];
}

/* Marks passed on the way to p, then p; ends at 1. */
- (void)setCurrentProgress:(NSAnimationProgress)p
{
    p = MIN(MAX(p, 0), 1);
    _progress = p;
    while (_nextMark < [_marks count] && [_marks[_nextMark] floatValue] <= p) {
        float mark = [_marks[_nextMark++] floatValue];
        if ([(id)_delegate respondsToSelector:@selector(animation:didReachProgressMark:)])
            [_delegate animation:self didReachProgressMark:mark];
        [[NSNotificationCenter defaultCenter] postNotificationName:NSAnimationProgressMarkNotification
                                                            object:self
                                                          userInfo:@{NSAnimationProgressMark : @(mark)}];
    }
}

- (void)_finchTick
{
    NSTimeInterval t = -[_start timeIntervalSinceNow];
    [self setCurrentProgress:_duration > 0 ? (float)(t / _duration) : 1];
    if (_progress >= 1)
        [self _finchFinish:YES];
}

- (void)_finchFinish:(BOOL)ended
{
    [_timer invalidate];
    _timer = nil;
    _animating = NO;
    if (ended && [(id)_delegate respondsToSelector:@selector(animationDidEnd:)])
        [_delegate animationDidEnd:self];
    else if (!ended && [(id)_delegate respondsToSelector:@selector(animationDidStop:)])
        [_delegate animationDidStop:self];
}

- (void)startAnimation
{
    if (_animating)
        return;
    if ([(id)_delegate respondsToSelector:@selector(animationShouldStart:)] && ![_delegate animationShouldStart:self])
        return;
    _animating = YES;
    _nextMark = 0;
    while (_nextMark < [_marks count] && [_marks[_nextMark] floatValue] < _progress)
        _nextMark++;
    [_start release];
    _start = [[NSDate dateWithTimeIntervalSinceNow:-_progress * _duration] retain];
    NSTimeInterval interval = _frameRate > 0 ? 1.0 / _frameRate : 1.0 / 60;
    if (_blocking == NSAnimationBlocking) {
        while (_animating) {
            [self _finchTick];
            if (_animating)
                [NSThread sleepForTimeInterval:interval];
        }
        return;
    }
    _timer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(_finchTick) userInfo:nil repeats:YES];
    for (NSRunLoopMode mode in _modes ?: @[ NSDefaultRunLoopMode, NSModalPanelRunLoopMode, NSEventTrackingRunLoopMode ])
        [[NSRunLoop currentRunLoop] addTimer:_timer forMode:mode];
}

- (void)stopAnimation
{
    if (_animating)
        [self _finchFinish:NO];
}

- (void)startWhenAnimation:(NSAnimation *)a reachesProgress:(NSAnimationProgress)p {}
- (void)stopWhenAnimation:(NSAnimation *)a reachesProgress:(NSAnimationProgress)p {}
- (void)clearStartAnimation {}
- (void)clearStopAnimation {}

@end

#pragma mark NSViewAnimation

NSViewAnimationKey NSViewAnimationTargetKey = @"NSViewAnimationTargetKey";
NSViewAnimationKey NSViewAnimationStartFrameKey = @"NSViewAnimationStartFrameKey";
NSViewAnimationKey NSViewAnimationEndFrameKey = @"NSViewAnimationEndFrameKey";
NSViewAnimationKey NSViewAnimationEffectKey = @"NSViewAnimationEffectKey";
NSViewAnimationEffectName NSViewAnimationFadeInEffect = @"NSViewAnimationFadeInEffect";
NSViewAnimationEffectName NSViewAnimationFadeOutEffect = @"NSViewAnimationFadeOutEffect";

@implementation NSViewAnimation {
    NSArray *_animations;
    NSMutableArray *_starts;
}

/* As Apple's: half a second, not blocking, ease in and out. */
- (instancetype)initWithViewAnimations:(NSArray<NSDictionary<NSViewAnimationKey, id> *> *)a
{
    self = [super initWithDuration:0.5 animationCurve:NSAnimationEaseInOut];
    if (self) {
        [self setAnimationBlockingMode:NSAnimationNonblocking];
        _animations = [a copy];
    }
    return self;
}

- (void)dealloc
{
    [_animations release];
    [_starts release];
    [super dealloc];
}

- (NSArray *)viewAnimations { return _animations; }
- (void)setViewAnimations:(NSArray *)a { [_animations autorelease]; _animations = [a copy]; }

static NSRect
frame_of(id target)
{
    return [target isKindOfClass:[NSWindow class]] ? [target frame] : [(NSView *)target frame];
}

- (void)startAnimation
{
    [_starts release];
    _starts = [[NSMutableArray alloc] init];
    for (NSDictionary *d in _animations) {
        id t = d[NSViewAnimationTargetKey];
        NSValue *s = d[NSViewAnimationStartFrameKey];
        [_starts addObject:s ?: [NSValue valueWithRect:frame_of(t)]];
        NSString *effect = d[NSViewAnimationEffectKey];
        if ([effect isEqualToString:NSViewAnimationFadeInEffect]) {
            if ([t isKindOfClass:[NSWindow class]])
                [t orderFront:nil];
            else
                [t setHidden:NO];
        }
    }
    [super startAnimation];
}

- (void)setCurrentProgress:(NSAnimationProgress)p
{
    [super setCurrentProgress:p];
    float v = [self currentValue];
    NSUInteger i = 0;
    for (NSDictionary *d in _animations) {
        id t = d[NSViewAnimationTargetKey];
        NSRect a = i < [_starts count] ? [_starts[i] rectValue] : frame_of(t);
        i++;
        NSValue *e = d[NSViewAnimationEndFrameKey];
        if (e) {
            NSRect b = [e rectValue];
            NSRect r = NSMakeRect(a.origin.x + (b.origin.x - a.origin.x) * v, a.origin.y + (b.origin.y - a.origin.y) * v,
                                  a.size.width + (b.size.width - a.size.width) * v,
                                  a.size.height + (b.size.height - a.size.height) * v);
            if ([t isKindOfClass:[NSWindow class]])
                [t setFrame:r display:YES];
            else
                [(NSView *)t setFrame:r];
        }
        NSString *effect = d[NSViewAnimationEffectKey];
        if ([effect isEqualToString:NSViewAnimationFadeOutEffect] && p >= 1) {
            if ([t isKindOfClass:[NSWindow class]])
                [t orderOut:nil];
            else
                [t setHidden:YES];
        }
    }
}

@end
