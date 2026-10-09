/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Core Animation classes beyond QuartzCore's headers that SwiftUI's renderer uses,
 * with Finch's behaviour:
 *   - CAFilter: a named filter type and its inputs, set and read by key. Layers keep
 *     filters as given; Finch's layer drawing doesn't apply them yet.
 *   - CABackdropLayer: a layer with its backdrop settings (drawn as an ordinary layer).
 *   - CAPresentationModifier and its group: values for a key path, applied on flush.
 *   - CATransactionCompletionItem: a token that holds a transaction's completion open.
 *   - CADisplayLink (public API since macOS 14): calls its target once per display
 *     refresh, from a run-loop timer at the display's rate.
 *   - CALayerGetSuperlayer.
 */
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

#define CA_EXPORT __attribute__((visibility("default")))

CA_EXPORT CALayer *
CALayerGetSuperlayer(CALayer *layer)
{
    return layer.superlayer;
}

#pragma mark - CAFilter

__attribute__((visibility("default")))
@interface CAFilter : NSObject <NSCopying, NSSecureCoding>
@property (copy) NSString *name;
@property (readonly) NSString *type;
@property (getter=isEnabled) BOOL enabled;
@property BOOL cachesInputImage;
+ (NSArray<NSString *> *)filterTypes;
+ (instancetype)filterWithName:(NSString *)name;
+ (instancetype)filterWithType:(NSString *)type;
- (instancetype)initWithName:(NSString *)name;
- (instancetype)initWithType:(NSString *)type;
- (void)setDefaults;
@end

@implementation CAFilter {
    NSString *_type;
    NSMutableDictionary *_inputs;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSArray<NSString *> *)filterTypes
{
    return @[ @"multiplyColor", @"colorAdd", @"colorSubtract", @"colorMonochrome", @"colorMatrix", @"colorHueRotate",
              @"colorSaturate", @"colorBrightness", @"colorContrast", @"colorInvert", @"gaussianBlur", @"variableBlur",
              @"luminanceToAlpha", @"alphaThreshold", @"averageColor", @"lanczosResize", @"curves" ];
}

+ (instancetype)filterWithName:(NSString *)name { return [[[self alloc] initWithName:name] autorelease]; }
+ (instancetype)filterWithType:(NSString *)type { return [[[self alloc] initWithType:type] autorelease]; }

- (instancetype)initWithType:(NSString *)type
{
    if ((self = [super init])) {
        _type = [type copy];
        _name = [type copy];
        _enabled = YES;
        _inputs = [NSMutableDictionary new];
    }
    return self;
}

- (instancetype)initWithName:(NSString *)name { return [self initWithType:name]; }
- (instancetype)init { return [self initWithType:@""]; }

- (void)dealloc
{
    [_type release];
    [_name release];
    [_inputs release];
    [super dealloc];
}

- (NSString *)type { return _type; }
- (void)setDefaults { [_inputs removeAllObjects]; }

- (id)valueForUndefinedKey:(NSString *)key { return _inputs[key]; }
- (void)setValue:(id)value forUndefinedKey:(NSString *)key
{
    if (value)
        _inputs[key] = value;
    else
        [_inputs removeObjectForKey:key];
}

- (id)copyWithZone:(NSZone *)zone
{
    CAFilter *f = [[CAFilter allocWithZone:zone] initWithType:_type];
    f.name = _name;
    f.enabled = _enabled;
    f.cachesInputImage = _cachesInputImage;
    [f->_inputs setDictionary:_inputs];
    return f;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_type forKey:@"type"];
    [coder encodeObject:_name forKey:@"name"];
    [coder encodeBool:_enabled forKey:@"enabled"];
    [coder encodeObject:_inputs forKey:@"inputs"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self initWithType:[coder decodeObjectOfClass:[NSString class] forKey:@"type"] ?: @""])) {
        self.name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"];
        _enabled = [coder decodeBoolForKey:@"enabled"];
        NSDictionary *d = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSDictionary class], [NSString class],
                                                                          [NSNumber class], [NSValue class], [NSArray class],
                                                                          nil]
                                                forKey:@"inputs"];
        if (d)
            [_inputs setDictionary:d];
    }
    return self;
}

- (NSString *)description { return [NSString stringWithFormat:@"<CAFilter %p '%@' type %@>", self, _name, _type]; }

@end

#pragma mark - CABackdropLayer

__attribute__((visibility("default")))
@interface CABackdropLayer : CALayer
@property (nonatomic) CGFloat scale;
@property (nonatomic) BOOL allowsInPlaceFiltering;
@property (nonatomic, copy) NSString *groupName;
@property (nonatomic) BOOL enabled;
@end

@implementation CABackdropLayer

- (instancetype)init
{
    if ((self = [super init])) {
        _scale = 1;
        _enabled = YES;
    }
    return self;
}

- (void)dealloc
{
    [_groupName release];
    [super dealloc];
}

@end

#pragma mark - CAPresentationModifier

@class CAPresentationModifier;

__attribute__((visibility("default")))
@interface CAPresentationModifierGroup : NSObject
@property (nonatomic) BOOL updatesAsynchronously;
@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly) NSUInteger capacity;
+ (instancetype)groupWithCapacity:(NSUInteger)capacity;
- (void)flush;
- (void)flushWithTargetTime:(double)targetTime;
- (void)flushLocally;
- (void)flushLocallyWithTargetTime:(double)targetTime;
- (void)flushWithTransaction;
- (void)flushWithTransactionAndTargetTime:(double)targetTime;
@end

@implementation CAPresentationModifierGroup {
    NSUInteger _capacity;
    NSHashTable *_modifiers;
}

+ (instancetype)groupWithCapacity:(NSUInteger)capacity
{
    CAPresentationModifierGroup *g = [[[self alloc] init] autorelease];
    g->_capacity = capacity;
    return g;
}

- (instancetype)init
{
    if ((self = [super init]))
        _modifiers = [[NSHashTable weakObjectsHashTable] retain];
    return self;
}

- (void)dealloc
{
    [_modifiers release];
    [super dealloc];
}

- (NSUInteger)capacity { return _capacity; }
- (NSUInteger)count { return [_modifiers count]; }
- (void)_finchAdd:(CAPresentationModifier *)m { [_modifiers addObject:m]; }
- (void)flush {}
- (void)flushWithTargetTime:(double)t {}
- (void)flushLocally {}
- (void)flushLocallyWithTargetTime:(double)t {}
- (void)flushWithTransaction {}
- (void)flushWithTransactionAndTargetTime:(double)t {}

@end

__attribute__((visibility("default")))
@interface CAPresentationModifier : NSObject
@property (nonatomic, copy, readonly) NSString *keyPath;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL additive;
@property (nonatomic, readonly) CAPresentationModifierGroup *group;
@property (nonatomic, strong) id value;
@end

@implementation CAPresentationModifier

- (instancetype)initWithKeyPath:(NSString *)keyPath initialValue:(id)value initialVelocity:(id)velocity additive:(BOOL)additive
   preferredFrameRateRangeMaximum:(NSInteger)maximum group:(CAPresentationModifierGroup *)group
{
    if ((self = [super init])) {
        _keyPath = [keyPath copy];
        _value = [value retain];
        _additive = additive;
        _enabled = YES;
        _group = [group retain];
        [group _finchAdd:self];
    }
    return self;
}

- (instancetype)initWithKeyPath:(NSString *)keyPath initialValue:(id)value additive:(BOOL)additive group:(CAPresentationModifierGroup *)group
{
    return [self initWithKeyPath:keyPath initialValue:value initialVelocity:nil additive:additive preferredFrameRateRangeMaximum:0 group:group];
}

- (instancetype)initWithKeyPath:(NSString *)keyPath initialValue:(id)value additive:(BOOL)additive
{
    return [self initWithKeyPath:keyPath initialValue:value additive:additive group:nil];
}

- (void)dealloc
{
    [_keyPath release];
    [_value release];
    [_group release];
    [super dealloc];
}

- (void)setValue:(id)value velocity:(id)velocity { self.value = value; }

@end

#pragma mark - CATransactionCompletionItem

__attribute__((visibility("default")))
@interface CATransactionCompletionItem : NSObject
+ (instancetype)completionItem;
- (void)invalidate;
@end

@implementation CATransactionCompletionItem
+ (instancetype)completionItem { return [[[self alloc] init] autorelease]; }
- (void)invalidate {}
@end

#pragma mark - CADisplayLink

@implementation CADisplayLink {
    id _target; /* retained, as Apple's */
    SEL _selector;
    NSTimer *_timer;
    CFTimeInterval _timestamp, _duration;
    BOOL _paused;
    CAFrameRateRange _range;
}

+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector
{
    CADisplayLink *l = [[[self alloc] init] autorelease];
    l->_target = [target retain];
    l->_selector = selector;
    l->_duration = 1.0 / 60;
    return l;
}

+ (CADisplayLink *)displayLinkWithDisplay:(id)display target:(id)target selector:(SEL)selector
{
    return [self displayLinkWithTarget:target selector:selector];
}

- (void)dealloc
{
    [_timer invalidate];
    [_timer release];
    [_target release];
    [super dealloc];
}

- (void)_finchTick:(NSTimer *)t
{
    if (_paused)
        return;
    _timestamp = CACurrentMediaTime();
    ((void (*)(id, SEL, CADisplayLink *))(void *)objc_msgSend)(_target, _selector, self);
}

- (void)addToRunLoop:(NSRunLoop *)runloop forMode:(NSRunLoopMode)mode
{
    if (!_timer) {
        _timer = [[NSTimer timerWithTimeInterval:_duration target:self selector:@selector(_finchTick:) userInfo:nil repeats:YES] retain];
    }
    [runloop addTimer:_timer forMode:mode];
}

- (void)removeFromRunLoop:(NSRunLoop *)runloop forMode:(NSRunLoopMode)mode
{
    [_timer invalidate];
    [_timer release];
    _timer = nil;
}

- (void)invalidate
{
    [_timer invalidate];
    [_timer release];
    _timer = nil;
    [_target release];
    _target = nil;
}

- (CFTimeInterval)timestamp { return _timestamp; }
- (CFTimeInterval)targetTimestamp { return _timestamp + _duration; }
- (CFTimeInterval)duration { return _duration; }
- (BOOL)isPaused { return _paused; }
- (void)setPaused:(BOOL)paused { _paused = paused; }
- (CAFrameRateRange)preferredFrameRateRange { return _range; }
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range { _range = range; }
- (id)display { return nil; }
- (void)setHighFrameRateReasons:(const uint32_t *)reasons count:(NSInteger)count {}

@end
