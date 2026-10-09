/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "AppKit_Finch.h"
#import <objc/message.h>
const CGFloat NSSliderAccessoryWidthDefault = 36;
@implementation NSSliderAccessoryBehavior {
    NSInteger _kind;
    __weak id _target;
    SEL _action;
    void (^_handler)(NSSliderAccessory *);
}
+ (instancetype)_finchBehavior:(NSInteger)kind
{
    NSSliderAccessoryBehavior *b = [[[self alloc] init] autorelease];
    b->_kind = kind;
    return b;
}
+ (NSSliderAccessoryBehavior *)automaticBehavior
{
    static NSSliderAccessoryBehavior *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      b = [[self _finchBehavior:0] retain];
    });
    return b;
}
+ (NSSliderAccessoryBehavior *)valueStepBehavior
{
    static NSSliderAccessoryBehavior *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      b = [[self _finchBehavior:1] retain];
    });
    return b;
}
+ (NSSliderAccessoryBehavior *)valueResetBehavior
{
    static NSSliderAccessoryBehavior *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      b = [[self _finchBehavior:2] retain];
    });
    return b;
}
+ (NSSliderAccessoryBehavior *)behaviorWithTarget:(id)target action:(SEL)action
{
    NSSliderAccessoryBehavior *b = [self _finchBehavior:3];
    b->_target = target;
    b->_action = action;
    return b;
}
+ (NSSliderAccessoryBehavior *)behaviorWithHandler:(void (^)(NSSliderAccessory *))handler
{
    NSSliderAccessoryBehavior *b = [self _finchBehavior:4];
    b->_handler = [handler copy];
    return b;
}
- (void)dealloc
{
    [_handler release];
    [super dealloc];
}
- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _kind = [coder decodeIntegerForKey:@"NSKind"];
        _target = [coder decodeObjectForKey:@"NSTarget"];
        _action = NSSelectorFromString([coder decodeObjectForKey:@"NSAction"]);
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_handler)
        [NSException raise:NSInvalidArgumentException format:@"A slider accessory handler cannot be archived"];
    [coder encodeInteger:_kind forKey:@"NSKind"];
    [coder encodeConditionalObject:_target forKey:@"NSTarget"];
    [coder encodeObject:NSStringFromSelector(_action) forKey:@"NSAction"];
}
- (void)handleAction:(NSSliderAccessory *)sender
{
    if (!sender.enabled)
        return;
    if (_handler)
        _handler(sender);
    else if (_action) {
        if (NSApp)
            [NSApp sendAction:_action to:_target from:sender];
        else if ([_target respondsToSelector:_action])
            ((void (*)(id, SEL, id))objc_msgSend)(_target, _action, sender);
    }
}
@end
@implementation NSSliderAccessory {
    NSImage *_image;
    NSSliderAccessoryBehavior *_behavior;
    BOOL _enabled;
}
- (instancetype)init
{
    if ((self = [super init])) {
        _enabled = YES;
        _behavior = [[NSSliderAccessoryBehavior automaticBehavior] copy];
    }
    return self;
}
+ (NSSliderAccessory *)accessoryWithImage:(NSImage *)image
{
    NSSliderAccessory *a = [[[self alloc] init] autorelease];
    a->_image = [image retain];
    return a;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        _image = [[coder decodeObjectForKey:@"NSImage"] retain];
        NSSliderAccessoryBehavior *b = [coder decodeObjectForKey:@"NSBehavior"];
        if (b)
            self.behavior = b;
        if ([coder containsValueForKey:@"NSEnabled"])
            _enabled = [coder decodeBoolForKey:@"NSEnabled"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_image forKey:@"NSImage"];
    [coder encodeObject:_behavior forKey:@"NSBehavior"];
    [coder encodeBool:_enabled forKey:@"NSEnabled"];
}
- (void)dealloc
{
    [_image release];
    [_behavior release];
    [super dealloc];
}
- (NSSliderAccessoryBehavior *)behavior
{
    return _behavior;
}
- (void)setBehavior:(NSSliderAccessoryBehavior *)behavior
{
    if (_behavior != behavior) {
        [_behavior release];
        _behavior = [behavior copy];
    }
}
- (BOOL)isEnabled
{
    return _enabled;
}
- (void)setEnabled:(BOOL)enabled
{
    _enabled = enabled;
}
- (NSString *)accessibilityRole
{
    return NSAccessibilityButtonRole;
}
- (BOOL)isAccessibilityElement
{
    return YES;
}
- (BOOL)accessibilityPerformPress
{
    if (!_enabled)
        return NO;
    [_behavior handleAction:self];
    return YES;
}
@end
