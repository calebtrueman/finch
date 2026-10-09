/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Accessibility objects beyond views and cells:
 *   - NSAccessibilityElement: an element for a part of a view's drawing. Any
 *     NSAccessibility protocol property can be set on it; what isn't set reads as
 *     nothing, as Apple's.
 *   - NSAccessibilityCustomAction, NSAccessibilityCustomRotor and its search
 *     parameters and results.
 *   - NSHapticFeedbackManager: Finch has no haptic hardware yet, so its performer
 *     does nothing.
 *   - The private entry points SwiftUI uses to read an element's attributes and
 *     perform its actions by their old attribute and action names, and
 *     NSAccessibilityRemoteUIElement's check for remote UI apps.
 *   - The user accent colour functions: Finch Macs have no hardware colour.
 */
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define AK_EXPORT __attribute__((visibility("default")))

AK_EXPORT NSAccessibilityAttributeName const NSAccessibilityIsAccessibilityElementAttribute = @"AXIsElement";
AK_EXPORT NSAccessibilityAttributeName const NSAccessibilityAttributedUserInputLabelsAttribute = @"AXAttributedUserInputLabels";

#pragma mark - NSAccessibilityElement

/*
 * The NSAccessibility protocol has some 200 properties. An element answers each
 * one from a dictionary: the first time a protocol getter or setter is called,
 * it is added to the class, typed from the protocol's own method description.
 */
@interface NSAccessibilityElement ()
- (NSMutableDictionary *)_finchValues;
@end

static NSString *
property_key(SEL sel, BOOL *isSetter)
{
    NSString *name = NSStringFromSelector(sel);
    *isSetter = [name hasPrefix:@"setAccessibility"] && [name hasSuffix:@":"];
    if (*isSetter) {
        name = [name substringWithRange:NSMakeRange(3, [name length] - 4)];
        return [[[name substringToIndex:1] lowercaseString] stringByAppendingString:[name substringFromIndex:1]];
    }
    if ([name hasPrefix:@"isAccessibility"])
        return [@"a" stringByAppendingString:[name substringFromIndex:3]];
    return name;
}

static const char *
protocol_types(SEL sel)
{
    Protocol *p = @protocol(NSAccessibility);
    struct objc_method_description d = protocol_getMethodDescription(p, sel, NO, YES);
    if (!d.name)
        d = protocol_getMethodDescription(p, sel, YES, YES);
    return d.types;
}

@implementation NSAccessibilityElement {
    NSMutableDictionary *_values;
    NSMutableArray *_children;
    NSRect _frameInParent;
}

+ (BOOL)resolveInstanceMethod:(SEL)sel
{
    const char *types = protocol_types(sel);
    if (!types)
        return [super resolveInstanceMethod:sel];
    BOOL setter;
    NSString *key = property_key(sel, &setter);
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:types];
    const char *t = setter ? [sig getArgumentTypeAtIndex:2] : [sig methodReturnType];
    if (setter && [sig numberOfArguments] != 3)
        return NO;
    if (!setter && [sig numberOfArguments] != 2)
        return NO;
    id block = nil;
    switch (t[0]) {
    case '@':
        block = setter ? (id) ^ (NSAccessibilityElement * self, id v) {
            if (v)
                [self _finchValues][key] = v;
            else
                [[self _finchValues] removeObjectForKey:key];
        } : (id) ^ id(NSAccessibilityElement * self) { return [self _finchValues][key]; };
        break;
    case 'B':
    case 'c':
        block = setter ? (id) ^ (NSAccessibilityElement * self, BOOL v) { [self _finchValues][key] = @(v); }
                       : (id) ^ BOOL(NSAccessibilityElement * self) { return [[self _finchValues][key] boolValue]; };
        break;
    case 'q':
    case 'Q':
    case 'i':
    case 'I':
        block = setter ? (id) ^ (NSAccessibilityElement * self, NSInteger v) { [self _finchValues][key] = @(v); }
                       : (id) ^ NSInteger(NSAccessibilityElement * self) { return [[self _finchValues][key] integerValue]; };
        break;
    case 'd':
        block = setter ? (id) ^ (NSAccessibilityElement * self, double v) { [self _finchValues][key] = @(v); }
                       : (id) ^ double(NSAccessibilityElement * self) { return [[self _finchValues][key] doubleValue]; };
        break;
    case 'f':
        block = setter ? (id) ^ (NSAccessibilityElement * self, float v) { [self _finchValues][key] = @(v); }
                       : (id) ^ float(NSAccessibilityElement * self) { return [[self _finchValues][key] floatValue]; };
        break;
    case '{':
        if (!strncmp(t, "{CGRect=", 8))
            block = setter ? (id) ^ (NSAccessibilityElement * self, NSRect v) { [self _finchValues][key] = [NSValue valueWithRect:v]; }
                           : (id) ^ NSRect(NSAccessibilityElement * self) { return [[self _finchValues][key] rectValue]; };
        else if (!strncmp(t, "{CGPoint=", 9))
            block = setter ? (id) ^ (NSAccessibilityElement * self, NSPoint v) { [self _finchValues][key] = [NSValue valueWithPoint:v]; }
                           : (id) ^ NSPoint(NSAccessibilityElement * self) { return [[self _finchValues][key] pointValue]; };
        else if (!strncmp(t, "{CGSize=", 8))
            block = setter ? (id) ^ (NSAccessibilityElement * self, NSSize v) { [self _finchValues][key] = [NSValue valueWithSize:v]; }
                           : (id) ^ NSSize(NSAccessibilityElement * self) { return [[self _finchValues][key] sizeValue]; };
        else if (!strncmp(t, "{_NSRange=", 10))
            block = setter ? (id) ^ (NSAccessibilityElement * self, NSRange v) { [self _finchValues][key] = [NSValue valueWithRange:v]; }
                           : (id) ^ NSRange(NSAccessibilityElement * self) {
                                 NSValue *v = [self _finchValues][key];
                                 return v ? [v rangeValue] : NSMakeRange(NSNotFound, 0);
                             };
        break;
    }
    if (!block)
        return [super resolveInstanceMethod:sel];
    class_addMethod(self, sel, imp_implementationWithBlock(block), types);
    return YES;
}

+ (id)accessibilityElementWithRole:(NSAccessibilityRole)role frame:(NSRect)frame label:(NSString *)label parent:(id)parent
{
    NSAccessibilityElement *e = [[[self alloc] init] autorelease];
    [e setAccessibilityRole:role];
    [e setAccessibilityFrame:frame];
    [e setAccessibilityLabel:label];
    [e setAccessibilityParent:parent];
    return e;
}

- (void)dealloc
{
    [_values release];
    [_children release];
    [super dealloc];
}

- (NSMutableDictionary *)_finchValues
{
    if (!_values)
        _values = [NSMutableDictionary new];
    return _values;
}

- (void)accessibilityAddChildElement:(NSAccessibilityElement *)childElement
{
    if (!_children)
        _children = [NSMutableArray new];
    [_children addObject:childElement];
    [childElement setAccessibilityParent:self];
}

- (NSArray *)accessibilityChildren { return _values[@"accessibilityChildren"] ?: (_children.count ? [[_children copy] autorelease] : nil); }

- (NSRect)accessibilityFrameInParentSpace { return _frameInParent; }

/* A frame in the parent's space becomes a screen frame through the parent view. */
- (void)setAccessibilityFrameInParentSpace:(NSRect)frame
{
    _frameInParent = frame;
    id parent = [self accessibilityParent];
    if ([parent isKindOfClass:[NSView class]])
        [self setAccessibilityFrame:NSAccessibilityFrameInView(parent, frame)];
    else if ([parent isKindOfClass:[NSAccessibilityElement class]]) {
        NSRect p = [parent accessibilityFrame];
        [self setAccessibilityFrame:NSOffsetRect(frame, p.origin.x, p.origin.y)];
    } else
        [self setAccessibilityFrame:frame];
}

- (NSString *)accessibilityRoleDescription
{
    return _values[@"accessibilityRoleDescription"] ?: NSAccessibilityRoleDescription([self accessibilityRole], [self accessibilitySubrole]);
}

- (BOOL)isAccessibilityElement
{
    NSNumber *n = _values[@"accessibilityElement"];
    return n ? [n boolValue] : YES;
}
- (void)setAccessibilityElement:(BOOL)flag { [self _finchValues][@"accessibilityElement"] = @(flag); }

- (id)accessibilityHitTest:(NSPoint)point
{
    for (id child in [[self accessibilityChildren] reverseObjectEnumerator])
        if ([child respondsToSelector:@selector(accessibilityFrame)] && NSPointInRect(point, [child accessibilityFrame]))
            return [child respondsToSelector:@selector(accessibilityHitTest:)] ? [child accessibilityHitTest:point] : child;
    return self;
}

- (id)accessibilityFocusedUIElement { return self; }

@end

#pragma mark - Custom actions and rotors

@implementation NSAccessibilityCustomAction {
    id<NSObject> _target; /* weak */
}

- (instancetype)initWithName:(NSString *)name handler:(BOOL (^)(void))handler
{
    if ((self = [super init])) {
        _name = [name copy];
        _handler = [handler copy];
    }
    return self;
}

- (instancetype)initWithName:(NSString *)name target:(id<NSObject>)target selector:(SEL)selector
{
    if ((self = [super init])) {
        _name = [name copy];
        _target = target;
        _selector = selector;
    }
    return self;
}

- (void)dealloc
{
    [_name release];
    [_handler release];
    [super dealloc];
}

- (id<NSObject>)target { return _target; }
- (void)setTarget:(id<NSObject>)target { _target = target; }

- (BOOL)_finchPerform
{
    if (_handler)
        return _handler();
    if (_target && _selector && [_target respondsToSelector:_selector])
        return ((BOOL(*)(id, SEL, id))objc_msgSend)(_target, _selector, self);
    return NO;
}

@end

@implementation NSAccessibilityCustomRotor {
    id _searchDelegate, _loadDelegate; /* weak */
}

- (instancetype)initWithLabel:(NSString *)label itemSearchDelegate:(id<NSAccessibilityCustomRotorItemSearchDelegate>)delegate
{
    if ((self = [super init])) {
        _type = NSAccessibilityCustomRotorTypeCustom;
        _label = [label copy];
        _searchDelegate = delegate;
    }
    return self;
}

- (instancetype)initWithRotorType:(NSAccessibilityCustomRotorType)type itemSearchDelegate:(id<NSAccessibilityCustomRotorItemSearchDelegate>)delegate
{
    if ((self = [super init])) {
        _type = type;
        _label = @"";
        _searchDelegate = delegate;
    }
    return self;
}

- (void)dealloc
{
    [_label release];
    [super dealloc];
}

- (id<NSAccessibilityCustomRotorItemSearchDelegate>)itemSearchDelegate { return _searchDelegate; }
- (void)setItemSearchDelegate:(id<NSAccessibilityCustomRotorItemSearchDelegate>)d { _searchDelegate = d; }
- (id<NSAccessibilityElementLoading>)itemLoadingDelegate { return _loadDelegate; }
- (void)setItemLoadingDelegate:(id<NSAccessibilityElementLoading>)d { _loadDelegate = d; }

@end

@implementation NSAccessibilityCustomRotorSearchParameters

- (instancetype)init
{
    if ((self = [super init]))
        _filterString = @"";
    return self;
}

- (void)dealloc
{
    [_currentItem release];
    [_filterString release];
    [super dealloc];
}

@end

@implementation NSAccessibilityCustomRotorItemResult {
    id _target; /* weak */
    id _token;
}

- (instancetype)initWithTargetElement:(id<NSAccessibilityElement>)targetElement
{
    if ((self = [super init])) {
        _target = targetElement;
        _targetRange = NSMakeRange(NSNotFound, 0);
    }
    return self;
}

- (instancetype)initWithItemLoadingToken:(NSAccessibilityLoadingToken)token customLabel:(NSString *)customLabel
{
    if ((self = [super init])) {
        _token = [token retain];
        _customLabel = [customLabel copy];
        _targetRange = NSMakeRange(NSNotFound, 0);
    }
    return self;
}

- (void)dealloc
{
    [_token release];
    [_customLabel release];
    [super dealloc];
}

- (id<NSAccessibilityElement>)targetElement { return _target; }
- (NSAccessibilityLoadingToken)itemLoadingToken { return _token; }

@end

#pragma mark - Haptic feedback

@interface _FinchHapticFeedbackPerformer : NSObject <NSHapticFeedbackPerformer>
@end

@implementation _FinchHapticFeedbackPerformer
- (void)performFeedbackPattern:(NSHapticFeedbackPattern)pattern performanceTime:(NSHapticFeedbackPerformanceTime)time {}
@end

@implementation NSHapticFeedbackManager

+ (id<NSHapticFeedbackPerformer>)defaultPerformer
{
    static _FinchHapticFeedbackPerformer *performer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      performer = [_FinchHapticFeedbackPerformer new];
    });
    return performer;
}

@end

#pragma mark - Entry points

AK_EXPORT void
NSAccessibilityBeginInternalAccessors(void)
{
}

AK_EXPORT void
NSAccessibilityEndInternalAccessors(void)
{
}

/* "AXRoleDescription" -> accessibilityRoleDescription; "AXEnabled" -> isAccessibilityEnabled. */
static SEL
getter_for_attribute(id element, NSString *attribute)
{
    if (![attribute hasPrefix:@"AX"])
        return NULL;
    NSString *base = [attribute substringFromIndex:2];
    if ([attribute isEqualToString:NSAccessibilityIsAccessibilityElementAttribute])
        base = @"Element";
    SEL sel = NSSelectorFromString([@"accessibility" stringByAppendingString:base]);
    if ([element respondsToSelector:sel])
        return sel;
    sel = NSSelectorFromString([@"isAccessibility" stringByAppendingString:base]);
    if ([element respondsToSelector:sel])
        return sel;
    return NULL;
}

AK_EXPORT BOOL
NSAccessibilityEntryPointIsAttributeSupported(id element, NSAccessibilityAttributeName attribute)
{
    if (getter_for_attribute(element, attribute))
        return YES;
    if ([element respondsToSelector:@selector(accessibilityAttributeNames)])
        return [[element accessibilityAttributeNames] containsObject:attribute];
    return NO;
}

AK_EXPORT id
NSAccessibilityEntryPointValueForAttribute(id element, NSAccessibilityAttributeName attribute)
{
    if ([attribute isEqualToString:NSAccessibilityPositionAttribute] && [element respondsToSelector:@selector(accessibilityFrame)])
        return [NSValue valueWithPoint:[element accessibilityFrame].origin];
    if ([attribute isEqualToString:NSAccessibilitySizeAttribute] && [element respondsToSelector:@selector(accessibilityFrame)])
        return [NSValue valueWithSize:[element accessibilityFrame].size];
    if ([attribute isEqualToString:NSAccessibilityDescriptionAttribute] && [element respondsToSelector:@selector(accessibilityLabel)])
        return [element accessibilityLabel];
    SEL getter = getter_for_attribute(element, attribute);
    if (getter) {
        NSMethodSignature *sig = [element methodSignatureForSelector:getter];
        if ([sig numberOfArguments] != 2)
            return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:getter];
        [inv invokeWithTarget:element];
        const char *t = [sig methodReturnType];
        if (t[0] == '@') {
            __unsafe_unretained id v;
            [inv getReturnValue:&v];
            return v;
        }
        NSUInteger size = [sig methodReturnLength];
        char buf[size];
        [inv getReturnValue:buf];
        switch (t[0]) {
        case 'B': case 'c': return @(*(BOOL *)buf);
        case 'q': return @(*(long long *)buf);
        case 'Q': return @(*(unsigned long long *)buf);
        case 'd': return @(*(double *)buf);
        case 'f': return @(*(float *)buf);
        }
        return [NSValue valueWithBytes:buf objCType:t];
    }
    if ([element respondsToSelector:@selector(accessibilityAttributeValue:)])
        return [element accessibilityAttributeValue:attribute];
    return nil;
}

static const struct {
    NSString *const *action;
    const char *selector;
} actions[] = {
    {&NSAccessibilityPressAction, "accessibilityPerformPress"},
    {&NSAccessibilityIncrementAction, "accessibilityPerformIncrement"},
    {&NSAccessibilityDecrementAction, "accessibilityPerformDecrement"},
    {&NSAccessibilityConfirmAction, "accessibilityPerformConfirm"},
    {&NSAccessibilityCancelAction, "accessibilityPerformCancel"},
    {&NSAccessibilityShowMenuAction, "accessibilityPerformShowMenu"},
    {&NSAccessibilityPickAction, "accessibilityPerformPick"},
    {&NSAccessibilityRaiseAction, "accessibilityPerformRaise"},
    {&NSAccessibilityShowAlternateUIAction, "accessibilityPerformShowAlternateUI"},
    {&NSAccessibilityShowDefaultUIAction, "accessibilityPerformShowDefaultUI"},
    {&NSAccessibilityDeleteAction, "accessibilityPerformDelete"},
};

/* Only the actions an element implements itself, not NSObject's defaults. */
static BOOL
implements(id element, SEL sel)
{
    if (![element respondsToSelector:sel])
        return NO;
    return class_getMethodImplementation([element class], sel) != class_getMethodImplementation([NSObject class], sel);
}

AK_EXPORT NSArray *
NSAccessibilityEntryPointActionNames(id element)
{
    NSMutableArray *names = [NSMutableArray array];
    for (size_t i = 0; i < sizeof actions / sizeof actions[0]; i++)
        if (implements(element, sel_registerName(actions[i].selector)))
            [names addObject:*actions[i].action];
    if (![names count] && [element respondsToSelector:@selector(accessibilityActionNames)])
        return [element accessibilityActionNames];
    return [names count] ? names : nil;
}

AK_EXPORT NSString *
NSAccessibilityEntryPointActionDescription(id element, NSAccessibilityActionName action)
{
    if ([element respondsToSelector:@selector(accessibilityActionDescription:)])
        return [element accessibilityActionDescription:action];
    return NSAccessibilityActionDescription(action);
}

AK_EXPORT BOOL
NSAccessibilityEntryPointPerformAction(id element, NSAccessibilityActionName action)
{
    for (size_t i = 0; i < sizeof actions / sizeof actions[0]; i++) {
        SEL sel = sel_registerName(actions[i].selector);
        if ([action isEqualToString:*actions[i].action] && [element respondsToSelector:sel])
            return ((BOOL(*)(id, SEL))objc_msgSend)(element, sel);
    }
    if ([element respondsToSelector:@selector(accessibilityPerformAction:)]) {
        [element accessibilityPerformAction:action];
        return YES;
    }
    return NO;
}

#pragma mark - Remote UI

__attribute__((visibility("default")))
@interface NSAccessibilityRemoteUIElement : NSObject
+ (BOOL)isRemoteUIApp;
@end

@implementation NSAccessibilityRemoteUIElement
+ (BOOL)isRemoteUIApp { return NO; }
@end

#pragma mark - Accent colour

AK_EXPORT BOOL
NSUserAccentHasHardwareColor(void)
{
    return NO;
}

AK_EXPORT NSString *
NSUserAccentColorGetHardwareAccentColorName(void)
{
    return nil;
}
