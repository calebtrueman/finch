/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Cocoa scripting's object model: class and command descriptions, script commands
 * (the standard ones and apps' subclasses), object specifiers and their evaluation
 * over key-value coding, and the scripting key-value coding methods on NSObject.
 *
 * Specifiers evaluate as Apple's do: a property specifier is the container's value for
 * its key; index, name, unique-ID, middle, random, range and relative specifiers pick
 * from the container's to-many value for theirs. Commands carry their receivers and
 * arguments and run performDefaultImplementation (or the receivers' handler selector).
 * Reading scripting definitions (sdef files) into the suite registry, and receiving
 * Apple events from other processes, come with Finch's Apple event server
 * (docs/design/CORESERVICES.md); until then the registry starts empty.
 */
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdlib.h>

#pragma mark - NSClassDescription

NSNotificationName const NSClassDescriptionNeededForClassNotification = @"NSClassDescriptionNeededForClass";

@implementation NSClassDescription

static NSMutableDictionary *registered_descriptions;

+ (void)registerClassDescription:(NSClassDescription *)description forClass:(Class)aClass
{
    @synchronized(self) {
        if (!registered_descriptions)
            registered_descriptions = [[NSMutableDictionary alloc] init];
        if (description && aClass)
            [registered_descriptions setObject:description forKey:NSStringFromClass(aClass)];
    }
}

+ (void)invalidateClassDescriptionCache
{
    @synchronized(self) {
        [registered_descriptions removeAllObjects];
    }
}

+ (NSClassDescription *)classDescriptionForClass:(Class)aClass
{
    if (!aClass)
        return nil;
    NSClassDescription *d;
    @synchronized(self) {
        d = [[[registered_descriptions objectForKey:NSStringFromClass(aClass)] retain] autorelease];
    }
    if (!d) {
        [[NSNotificationCenter defaultCenter] postNotificationName:NSClassDescriptionNeededForClassNotification
                                                            object:aClass];
        @synchronized(self) {
            d = [[[registered_descriptions objectForKey:NSStringFromClass(aClass)] retain] autorelease];
        }
    }
    return d;
}

- (NSArray<NSString *> *)attributeKeys { return @[]; }
- (NSArray<NSString *> *)toOneRelationshipKeys { return @[]; }
- (NSArray<NSString *> *)toManyRelationshipKeys { return @[]; }
- (NSString *)inverseForRelationshipKey:(NSString *)relationshipKey { return nil; }

@end

@implementation NSObject (NSClassDescriptionPrimitives)

- (NSClassDescription *)classDescription { return [NSClassDescription classDescriptionForClass:[self class]]; }
- (NSArray<NSString *> *)attributeKeys { return [[self classDescription] attributeKeys] ?: @[]; }
- (NSArray<NSString *> *)toOneRelationshipKeys { return [[self classDescription] toOneRelationshipKeys] ?: @[]; }
- (NSArray<NSString *> *)toManyRelationshipKeys { return [[self classDescription] toManyRelationshipKeys] ?: @[]; }
- (NSString *)inverseForRelationshipKey:(NSString *)relationshipKey
{
    return [[self classDescription] inverseForRelationshipKey:relationshipKey];
}

@end

#pragma mark - NSScriptClassDescription

static FourCharCode
code_from(id value)
{
    if ([value isKindOfClass:[NSNumber class]])
        return (FourCharCode)[value unsignedIntValue];
    if (![value isKindOfClass:[NSString class]])
        return 0;
    const char *s = [value UTF8String];
    FourCharCode c = 0;
    for (int i = 0; i < 4; i++)
        c = c << 8 | (uint8_t)(s && strlen(s) > (size_t)i ? s[i] : ' ');
    return c;
}

/* Apple's ivars: _objcClassName is the scripting class name, _moreVars the
   declaration dictionary, _superclassNameOrDescription the superclass's description. */
#define _className _objcClassName
#define _definition ((NSDictionary *)_moreVars)
#define _superDescription ((NSScriptClassDescription *)_superclassNameOrDescription)

@implementation NSScriptClassDescription

+ (NSScriptClassDescription *)classDescriptionForClass:(Class)aClass
{
    for (Class c = aClass; c; c = class_getSuperclass(c)) {
        NSClassDescription *d = [NSClassDescription classDescriptionForClass:c];
        if ([d isKindOfClass:[NSScriptClassDescription class]])
            return (NSScriptClassDescription *)d;
    }
    return nil;
}

- (instancetype)initWithSuiteName:(NSString *)suiteName className:(NSString *)className dictionary:(NSDictionary *)classDeclaration
{
    if ((self = [super init])) {
        _suiteName = [suiteName copy];
        _className = [className copy];
        _moreVars = [classDeclaration copy] ?: [[NSDictionary alloc] init];
        _appleEventCode = code_from([classDeclaration objectForKey:@"AppleEventCode"]);
    }
    return self;
}

- (void)dealloc
{
    [_suiteName release];
    [_className release];
    [_moreVars release];
    [_superclassNameOrDescription release];
    [super dealloc];
}

- (NSString *)suiteName { return _suiteName; }
- (NSString *)className { return _className; }

- (NSString *)implementationClassName
{
    return [_definition objectForKey:@"CocoaClassName"] ?: [_definition objectForKey:@"Class"] ?: _className;
}

- (NSScriptClassDescription *)superclassDescription
{
    if (!_superDescription) {
        Class c = NSClassFromString([self implementationClassName]);
        if (c && class_getSuperclass(c))
            _superclassNameOrDescription = [[NSScriptClassDescription classDescriptionForClass:class_getSuperclass(c)] retain];
    }
    return _superDescription;
}

- (FourCharCode)appleEventCode { return _appleEventCode; }

- (BOOL)matchesAppleEventCode:(FourCharCode)appleEventCode
{
    for (NSScriptClassDescription *d = self; d; d = [d superclassDescription])
        if ([d appleEventCode] == appleEventCode)
            return YES;
    return NO;
}

- (NSDictionary *)_commands { return [_definition objectForKey:@"SupportedCommands"]; }

- (BOOL)supportsCommand:(NSScriptCommandDescription *)commandDescription
{
    return [self selectorForCommand:commandDescription] != NULL ||
           [[self _commands] objectForKey:[commandDescription commandName]] != nil ||
           [[self superclassDescription] supportsCommand:commandDescription];
}

- (SEL)selectorForCommand:(NSScriptCommandDescription *)commandDescription
{
    NSString *name = [commandDescription commandName];
    NSString *key = [NSString stringWithFormat:@"%@.%@", [commandDescription suiteName], name];
    id sel = [[self _commands] objectForKey:key] ?: [[self _commands] objectForKey:name];
    if ([sel isKindOfClass:[NSString class]] && [sel length])
        return NSSelectorFromString(sel);
    return [[self superclassDescription] selectorForCommand:commandDescription];
}

- (NSDictionary *)_keyDefinition:(NSString *)key
{
    for (NSString *kind in @[@"Attributes", @"ToOneRelationships", @"ToManyRelationships"]) {
        NSDictionary *d = [[_definition objectForKey:kind] objectForKey:key];
        if (d)
            return d;
    }
    return [[self superclassDescription] _keyDefinition:key];
}

- (NSString *)_kindOfKey:(NSString *)key
{
    for (NSString *kind in @[@"Attributes", @"ToOneRelationships", @"ToManyRelationships"])
        if ([[_definition objectForKey:kind] objectForKey:key])
            return kind;
    return [[self superclassDescription] _kindOfKey:key];
}

- (NSString *)typeForKey:(NSString *)key { return [[self _keyDefinition:key] objectForKey:@"Type"]; }

- (NSScriptClassDescription *)classDescriptionForKey:(NSString *)key
{
    NSString *type = [self typeForKey:key];
    Class c = type ? NSClassFromString(type) : Nil;
    return c ? [NSScriptClassDescription classDescriptionForClass:c] : nil;
}

- (FourCharCode)appleEventCodeForKey:(NSString *)key
{
    return code_from([[self _keyDefinition:key] objectForKey:@"AppleEventCode"]);
}

- (NSString *)keyWithAppleEventCode:(FourCharCode)appleEventCode
{
    for (NSString *kind in @[@"Attributes", @"ToOneRelationships", @"ToManyRelationships"]) {
        NSDictionary *keys = [_definition objectForKey:kind];
        for (NSString *key in keys)
            if (code_from([[keys objectForKey:key] objectForKey:@"AppleEventCode"]) == appleEventCode)
                return key;
    }
    return [[self superclassDescription] keyWithAppleEventCode:appleEventCode];
}

- (NSString *)defaultSubcontainerAttributeKey
{
    return [_definition objectForKey:@"DefaultSubcontainerAttribute"] ?: [[self superclassDescription] defaultSubcontainerAttributeKey];
}

- (BOOL)isLocationRequiredToCreateForKey:(NSString *)toManyRelationshipKey
{
    id v = [[self _keyDefinition:toManyRelationshipKey] objectForKey:@"LocationRequiredToCreate"];
    return v ? [v boolValue] : YES;
}

- (BOOL)hasPropertyForKey:(NSString *)key
{
    NSString *kind = [self _kindOfKey:key];
    return [kind isEqualToString:@"Attributes"] || [kind isEqualToString:@"ToOneRelationships"];
}

- (BOOL)hasOrderedToManyRelationshipForKey:(NSString *)key
{
    return [[self _kindOfKey:key] isEqualToString:@"ToManyRelationships"];
}

- (BOOL)hasReadablePropertyForKey:(NSString *)key
{
    NSString *access = [[self _keyDefinition:key] objectForKey:@"Access"];
    return [self _kindOfKey:key] && (!access || [access rangeOfString:@"r"].location != NSNotFound);
}

- (BOOL)hasWritablePropertyForKey:(NSString *)key
{
    NSString *access = [[self _keyDefinition:key] objectForKey:@"Access"];
    if ([[self _keyDefinition:key] objectForKey:@"ReadOnly"])
        return ![[[self _keyDefinition:key] objectForKey:@"ReadOnly"] boolValue];
    return [self _kindOfKey:key] && (!access || [access rangeOfString:@"w"].location != NSNotFound);
}

- (BOOL)isReadOnlyKey:(NSString *)key { return ![self hasWritablePropertyForKey:key]; }

- (NSArray<NSString *> *)attributeKeys { return [[_definition objectForKey:@"Attributes"] allKeys] ?: @[]; }
- (NSArray<NSString *> *)toOneRelationshipKeys { return [[_definition objectForKey:@"ToOneRelationships"] allKeys] ?: @[]; }
- (NSArray<NSString *> *)toManyRelationshipKeys { return [[_definition objectForKey:@"ToManyRelationships"] allKeys] ?: @[]; }

@end

#undef _className
#undef _definition
#undef _superDescription

@implementation NSObject (NSScriptClassDescription)

- (FourCharCode)classCode { return [[NSScriptClassDescription classDescriptionForClass:[self class]] appleEventCode]; }

- (NSString *)className
{
    return [[NSScriptClassDescription classDescriptionForClass:[self class]] className] ?: NSStringFromClass([self class]);
}

@end

#pragma mark - NSScriptCommandDescription

/* Apple's ivars: _plistCommandName is the command's name, _moreVars its declaration. */
#define _commandName _plistCommandName
#define _definition ((NSDictionary *)_moreVars)

@implementation NSScriptCommandDescription

- (instancetype)init
{
    [self release];
    return nil;
}

- (instancetype)initWithCoder:(NSCoder *)inCoder
{
    [self release];
    return nil;
}

- (instancetype)initWithSuiteName:(NSString *)suiteName commandName:(NSString *)commandName dictionary:(NSDictionary *)commandDeclaration
{
    if ((self = [super init])) {
        _suiteName = [suiteName copy];
        _commandName = [commandName copy];
        _moreVars = [commandDeclaration copy] ?: [[NSDictionary alloc] init];
        _classAppleEventCode = code_from([commandDeclaration objectForKey:@"AppleEventClassCode"]);
        _idAppleEventCode = code_from([commandDeclaration objectForKey:@"AppleEventCode"]);
    }
    return self;
}

- (void)dealloc
{
    [_suiteName release];
    [_commandName release];
    [_moreVars release];
    [super dealloc];
}

- (void)encodeWithCoder:(NSCoder *)coder {}

- (NSString *)suiteName { return _suiteName; }
- (NSString *)commandName { return _commandName; }
- (FourCharCode)appleEventClassCode { return _classAppleEventCode; }
- (FourCharCode)appleEventCode { return _idAppleEventCode; }
- (NSString *)commandClassName { return [_definition objectForKey:@"CommandClass"] ?: @"NSScriptCommand"; }
- (NSString *)returnType { return [_definition objectForKey:@"Type"]; }
- (FourCharCode)appleEventCodeForReturnType { return code_from([_definition objectForKey:@"ResultAppleEventCode"]); }
- (NSDictionary *)_arguments { return [_definition objectForKey:@"Arguments"]; }
- (NSArray<NSString *> *)argumentNames { return [[self _arguments] allKeys] ?: @[]; }
- (NSString *)typeForArgumentWithName:(NSString *)argumentName { return [[[self _arguments] objectForKey:argumentName] objectForKey:@"Type"]; }

- (FourCharCode)appleEventCodeForArgumentWithName:(NSString *)argumentName
{
    return code_from([[[self _arguments] objectForKey:argumentName] objectForKey:@"AppleEventCode"]);
}

- (BOOL)isOptionalArgumentWithName:(NSString *)argumentName
{
    return [[[[self _arguments] objectForKey:argumentName] objectForKey:@"Optional"] boolValue];
}

- (NSScriptCommand *)createCommandInstanceWithZone:(NSZone *)zone
{
    Class c = NSClassFromString([self commandClassName]) ?: [NSScriptCommand class];
    return [[c allocWithZone:zone] initWithCommandDescription:self];
}

- (NSScriptCommand *)createCommandInstance { return [self createCommandInstanceWithZone:NULL]; }

@end

#undef _commandName
#undef _definition

#pragma mark - NSScriptCommand

static NSScriptCommand *current_command;

/* Apple's ivars; _moreVars holds the error details (a mutable dictionary). */
#define _description _commandDescription
#define _errors ((NSMutableDictionary *)_moreVars)

@implementation NSScriptCommand

+ (NSScriptCommand *)currentCommand { return current_command; }

- (instancetype)initWithCommandDescription:(NSScriptCommandDescription *)commandDef
{
    if ((self = [super init])) {
        _description = [commandDef retain];
        _arguments = [[NSDictionary alloc] init];
        _moreVars = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)inCoder
{
    return [self initWithCommandDescription:(NSScriptCommandDescription *_Nonnull)[inCoder decodeObjectForKey:@"NSCommandDescription"]];
}
- (void)encodeWithCoder:(NSCoder *)coder {}

- (void)dealloc
{
    [_description release];
    [_directParameter release];
    [_receiversSpecifier release];
    [_evaluatedReceivers release];
    [_arguments release];
    [_evaluatedArguments release];
    [_moreVars release];
    [super dealloc];
}

- (NSScriptCommandDescription *)commandDescription { return _description; }

- (id)directParameter { return _directParameter; }
- (void)setDirectParameter:(id)directParameter
{
    [_directParameter autorelease];
    _directParameter = [directParameter retain];
}

- (NSScriptObjectSpecifier *)receiversSpecifier { return _receiversSpecifier; }
- (void)setReceiversSpecifier:(NSScriptObjectSpecifier *)receiversRef
{
    [_receiversSpecifier autorelease];
    _receiversSpecifier = [receiversRef retain];
}

- (id)evaluatedReceivers
{
    if (_receiversSpecifier)
        return [_receiversSpecifier objectsByEvaluatingSpecifier];
    return nil;
}

- (NSDictionary<NSString *, id> *)arguments { return [[_arguments copy] autorelease]; }
- (void)setArguments:(NSDictionary<NSString *, id> *)args
{
    [_arguments autorelease];
    _arguments = [args copy] ?: [[NSDictionary alloc] init];
}

static id
evaluate(id value)
{
    if ([value isKindOfClass:[NSScriptObjectSpecifier class]])
        return [value objectsByEvaluatingSpecifier];
    return value;
}

- (NSDictionary<NSString *, id> *)evaluatedArguments
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in _arguments) {
        id v = evaluate([_arguments objectForKey:k]);
        if (!v)
            return nil;
        [d setObject:v forKey:k];
    }
    return d;
}

- (BOOL)isWellFormed
{
    for (NSString *name in [_description argumentNames])
        if (![_description isOptionalArgumentWithName:name] && ![_arguments objectForKey:name])
            return NO;
    return YES;
}

- (id)performDefaultImplementation { return nil; }

- (id)executeCommand
{
    NSScriptCommand *saved = current_command;
    current_command = self;
    id result = nil;
    id receivers = [self evaluatedReceivers];
    NSScriptClassDescription *cd = nil;
    id one = [receivers isKindOfClass:[NSArray class]] ? [receivers firstObject] : receivers;
    if (one)
        cd = [NSScriptClassDescription classDescriptionForClass:[one class]];
    SEL sel = cd ? [cd selectorForCommand:_description] : NULL;
    if (sel && [one respondsToSelector:sel]) {
        if ([receivers isKindOfClass:[NSArray class]]) {
            NSMutableArray *results = [NSMutableArray array];
            for (id r in receivers) {
                id v = ((id(*)(id, SEL, id))objc_msgSend)(r, sel, self);
                if (v)
                    [results addObject:v];
            }
            result = results;
        } else {
            result = ((id(*)(id, SEL, id))objc_msgSend)(one, sel, self);
        }
    } else {
        result = [self performDefaultImplementation];
    }
    current_command = saved;
    return result;
}

static void
set_error(NSScriptCommand *c, NSMutableDictionary *errors, NSString *key, id value)
{
    if (value)
        [errors setObject:value forKey:key];
    else
        [errors removeObjectForKey:key];
}

- (NSInteger)scriptErrorNumber { return [[_errors objectForKey:@"number"] integerValue]; }
- (void)setScriptErrorNumber:(NSInteger)errorNumber { set_error(self, _errors, @"number", @(errorNumber)); }
- (NSAppleEventDescriptor *)scriptErrorOffendingObjectDescriptor { return [_errors objectForKey:@"object"]; }
- (void)setScriptErrorOffendingObjectDescriptor:(NSAppleEventDescriptor *)d { set_error(self, _errors, @"object", d); }
- (NSAppleEventDescriptor *)scriptErrorExpectedTypeDescriptor { return [_errors objectForKey:@"type"]; }
- (void)setScriptErrorExpectedTypeDescriptor:(NSAppleEventDescriptor *)d { set_error(self, _errors, @"type", d); }
- (NSString *)scriptErrorString { return [_errors objectForKey:@"string"]; }
- (void)setScriptErrorString:(NSString *)errorString { set_error(self, _errors, @"string", [[errorString copy] autorelease]); }

- (NSAppleEventDescriptor *)appleEvent { return [_errors objectForKey:@"event"]; }
- (void)suspendExecution {}
- (void)resumeExecutionWithResult:(id)result {}

@end

#undef _description
#undef _errors

/* The standard suite's commands. */

@implementation NSCloseCommand
- (NSSaveOptions)saveOptions
{
    id v = [[self evaluatedArguments] objectForKey:@"SaveOptions"];
    FourCharCode c = [v isKindOfClass:[NSNumber class]] ? [v unsignedIntValue] : 0;
    return c == 'yes ' ? NSSaveOptionsYes : c == 'no  ' ? NSSaveOptionsNo : NSSaveOptionsAsk;
}
@end

@implementation NSCountCommand
- (id)performDefaultImplementation
{
    id r = [self evaluatedReceivers];
    return @([r isKindOfClass:[NSArray class]] ? [r count] : r ? 1 : 0);
}
@end

@implementation NSCreateCommand
- (NSScriptClassDescription *)createClassDescription
{
    id c = [[self arguments] objectForKey:@"ObjectClass"];
    Class cls = [c isKindOfClass:[NSString class]] ? NSClassFromString(c) : Nil;
    return cls ? [NSScriptClassDescription classDescriptionForClass:cls] : nil;
}
- (NSDictionary<NSString *, id> *)resolvedKeyDictionary { return [[self evaluatedArguments] objectForKey:@"KeyDictionary"] ?: @{}; }
@end

@implementation NSDeleteCommand
- (void)dealloc
{
    [_keySpecifier release];
    [super dealloc];
}
- (void)setReceiversSpecifier:(NSScriptObjectSpecifier *)receiversRef
{
    [super setReceiversSpecifier:[receiversRef containerSpecifier] ?: receiversRef];
    [_keySpecifier autorelease];
    _keySpecifier = [receiversRef retain];
}
- (NSScriptObjectSpecifier *)keySpecifier { return _keySpecifier; }
@end

@implementation NSExistsCommand
- (id)performDefaultImplementation
{
    id r = [self evaluatedReceivers];
    return @(r != nil && (![r isKindOfClass:[NSArray class]] || [r count] > 0));
}
@end

@implementation NSGetCommand
- (id)performDefaultImplementation { return [self evaluatedReceivers]; }
@end

@implementation NSMoveCommand
- (void)dealloc
{
    [_keySpecifier release];
    [super dealloc];
}
- (void)setReceiversSpecifier:(NSScriptObjectSpecifier *)receiversRef
{
    [super setReceiversSpecifier:[receiversRef containerSpecifier] ?: receiversRef];
    [_keySpecifier autorelease];
    _keySpecifier = [receiversRef retain];
}
- (NSScriptObjectSpecifier *)keySpecifier { return _keySpecifier; }
@end

@implementation NSCloneCommand
- (void)dealloc
{
    [_keySpecifier release];
    [super dealloc];
}
- (void)setReceiversSpecifier:(NSScriptObjectSpecifier *)receiversRef
{
    [super setReceiversSpecifier:[receiversRef containerSpecifier] ?: receiversRef];
    [_keySpecifier autorelease];
    _keySpecifier = [receiversRef retain];
}
- (NSScriptObjectSpecifier *)keySpecifier { return _keySpecifier; }
@end

@implementation NSQuitCommand
- (NSSaveOptions)saveOptions
{
    id v = [[self evaluatedArguments] objectForKey:@"SaveOptions"];
    FourCharCode c = [v isKindOfClass:[NSNumber class]] ? [v unsignedIntValue] : 0;
    return c == 'yes ' ? NSSaveOptionsYes : c == 'no  ' ? NSSaveOptionsNo : NSSaveOptionsAsk;
}
@end

@implementation NSSetCommand
- (void)dealloc
{
    [_keySpecifier release];
    [super dealloc];
}
- (void)setReceiversSpecifier:(NSScriptObjectSpecifier *)receiversRef
{
    [super setReceiversSpecifier:[receiversRef containerSpecifier] ?: receiversRef];
    [_keySpecifier autorelease];
    _keySpecifier = [receiversRef retain];
}
- (NSScriptObjectSpecifier *)keySpecifier { return _keySpecifier; }
- (id)performDefaultImplementation
{
    id value = [[self evaluatedArguments] objectForKey:@"Value"];
    id receivers = [self evaluatedReceivers];
    NSString *key = [_keySpecifier key];
    if (!key)
        return nil;
    for (id r in [receivers isKindOfClass:[NSArray class]] ? receivers : (receivers ? @[receivers] : @[]))
        [r setValue:[r coerceValue:value forKey:key] forKey:key];
    return nil;
}
@end

#pragma mark - Object specifiers

/* Apple's ivars; the child specifier isn't retained (it retains its container). */
#define _containerDescription _containerClassDescription
#define _testedObject _containerIsObjectBeingTested
#define _rangeContainer _containerIsRangeContainerObject

@implementation NSScriptObjectSpecifier

+ (NSScriptObjectSpecifier *)objectSpecifierWithDescriptor:(NSAppleEventDescriptor *)descriptor
{
    return nil; /* from Apple events: with Finch's Apple event server */
}

- (instancetype)init
{
    [self release];
    return nil;
}

- (instancetype)initWithContainerSpecifier:(NSScriptObjectSpecifier *)container key:(NSString *)property
{
    return [self initWithContainerClassDescription:[container keyClassDescription] containerSpecifier:container key:property];
}

- (instancetype)initWithContainerClassDescription:(NSScriptClassDescription *)classDesc
                               containerSpecifier:(NSScriptObjectSpecifier *)container
                                              key:(NSString *)property
{
    if ((self = [super init])) {
        _containerDescription = [classDesc retain];
        _container = [container retain];
        [_container setChildSpecifier:self];
        _key = [property copy];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)inCoder
{
    return [self initWithContainerClassDescription:(NSScriptClassDescription *_Nonnull)[inCoder decodeObjectForKey:@"NSContainerClassDescription"]
                                containerSpecifier:[inCoder decodeObjectForKey:@"NSContainer"]
                                               key:[inCoder decodeObjectForKey:@"NSKey"]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_container forKey:@"NSContainer"];
    [coder encodeObject:_key forKey:@"NSKey"];
}

- (void)dealloc
{
    [_containerDescription release];
    [_container release];
    [_key release];
    [_descriptor release];
    [super dealloc];
}

- (NSScriptObjectSpecifier *)childSpecifier { return _child; }
- (void)setChildSpecifier:(NSScriptObjectSpecifier *)child { _child = child; }

- (NSScriptObjectSpecifier *)containerSpecifier { return _container; }
- (void)setContainerSpecifier:(NSScriptObjectSpecifier *)subRef
{
    [_container autorelease];
    _container = [subRef retain];
    [_container setChildSpecifier:self];
}

- (BOOL)containerIsObjectBeingTested { return _testedObject; }
- (void)setContainerIsObjectBeingTested:(BOOL)flag { _testedObject = flag; }
- (BOOL)containerIsRangeContainerObject { return _rangeContainer; }
- (void)setContainerIsRangeContainerObject:(BOOL)flag { _rangeContainer = flag; }

- (NSString *)key { return _key; }
- (void)setKey:(NSString *)key
{
    [_key autorelease];
    _key = [key copy];
}

- (NSScriptClassDescription *)containerClassDescription { return _containerDescription; }
- (void)setContainerClassDescription:(NSScriptClassDescription *)classDesc
{
    [_containerDescription autorelease];
    _containerDescription = [classDesc retain];
}

- (NSScriptClassDescription *)keyClassDescription { return [_containerDescription classDescriptionForKey:_key]; }

- (NSInteger)evaluationErrorNumber { return _error; }
- (void)setEvaluationErrorNumber:(NSInteger)error { _error = error; }

- (NSScriptObjectSpecifier *)evaluationErrorSpecifier { return _error ? self : [_container evaluationErrorSpecifier]; }

- (NSAppleEventDescriptor *)descriptor { return _descriptor; }

/* The specified objects in one container: nil, one object, or an array. */
- (id)_objectsInContainer:(id)container
{
    NSInteger count = 0;
    NSInteger *indices = [self indicesOfObjectsByEvaluatingWithContainer:container count:&count];
    if (count < 0)
        return [container valueForKey:_key];
    if (!indices && _error == 0)
        _error = NSNoSpecifierError;
    if (!indices)
        return nil;
    NSArray *all = [container valueForKey:_key];
    if (![all isKindOfClass:[NSArray class]])
        return nil;
    if (count == 1)
        return indices[0] >= 0 && indices[0] < (NSInteger)[all count] ? [all objectAtIndex:(NSUInteger)indices[0]] : nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < count; i++)
        if (indices[i] >= 0 && indices[i] < (NSInteger)[all count])
            [out addObject:[all objectAtIndex:(NSUInteger)indices[i]]];
    return out;
}

- (NSInteger *)indicesOfObjectsByEvaluatingWithContainer:(id)container count:(NSInteger *)count
{
    if (count)
        *count = -1; /* the whole value */
    return NULL;
}

- (id)objectsByEvaluatingWithContainers:(id)containers
{
    if (!_containerDescription) { /* as Apple's: keys are known by the container's description */
        _error = NSUnknownKeySpecifierError;
        return nil;
    }
    if ([containers isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id c in containers) {
            id v = [self _objectsInContainer:c];
            if ([v isKindOfClass:[NSArray class]])
                [out addObjectsFromArray:v];
            else if (v)
                [out addObject:v];
        }
        return out;
    }
    id v = [self _objectsInContainer:containers];
    if (!v)
        _error = NSNoSpecifierError;
    return v;
}

- (id)objectsByEvaluatingSpecifier
{
    id containers;
    if (_container)
        containers = [_container objectsByEvaluatingSpecifier];
    else
        containers = [NSClassFromString(@"NSApplication") respondsToSelector:@selector(sharedApplication)]
                         ? ((id(*)(id, SEL))objc_msgSend)(NSClassFromString(@"NSApplication"), @selector(sharedApplication))
                         : nil;
    if (!containers) {
        _error = NSContainerSpecifierError;
        return nil;
    }
    return [self objectsByEvaluatingWithContainers:containers];
}

@end

#undef _containerDescription
#undef _testedObject
#undef _rangeContainer

@implementation NSPropertySpecifier
@end

static NSInteger *
one_index(NSInteger i, NSInteger *count)
{
    NSMutableData *d = [NSMutableData dataWithLength:sizeof(NSInteger)];
    *(NSInteger *)[d mutableBytes] = i;
    *count = 1;
    return (NSInteger *)[d mutableBytes];
}

static NSArray *
to_many(id container, NSString *key)
{
    id v = [container valueForKey:key];
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}

@implementation NSIndexSpecifier

- (instancetype)initWithContainerClassDescription:(NSScriptClassDescription *)classDesc
                               containerSpecifier:(NSScriptObjectSpecifier *)container
                                              key:(NSString *)property
                                            index:(NSInteger)index
{
    if ((self = [super initWithContainerClassDescription:classDesc containerSpecifier:container key:property]))
        _index = index;
    return self;
}

- (NSInteger)index { return _index; }
- (void)setIndex:(NSInteger)index { _index = index; }

- (NSInteger *)indicesOfObjectsByEvaluatingWithContainer:(id)container count:(NSInteger *)count
{
    NSArray *all = to_many(container, [self key]);
    NSInteger n = (NSInteger)[all count], i = _index < 0 ? n + _index : _index;
    if (!all || i < 0 || i >= n) {
        *count = 0;
        [self setEvaluationErrorNumber:NSInvalidIndexSpecifierError];
        return NULL;
    }
    return one_index(i, count);
}

@end

@implementation NSMiddleSpecifier
- (NSInteger *)indicesOfObjectsByEvaluatingWithContainer:(id)container count:(NSInteger *)count
{
    NSArray *all = to_many(container, [self key]);
    if (![all count]) {
        *count = 0;
        return NULL;
    }
    return one_index((NSInteger)([all count] - 1) / 2, count);
}
@end

@implementation NSRandomSpecifier
- (NSInteger *)indicesOfObjectsByEvaluatingWithContainer:(id)container count:(NSInteger *)count
{
    NSArray *all = to_many(container, [self key]);
    if (![all count]) {
        *count = 0;
        return NULL;
    }
    return one_index((NSInteger)arc4random_uniform((uint32_t)[all count]), count);
}
@end

@implementation NSNameSpecifier

- (instancetype)initWithContainerClassDescription:(NSScriptClassDescription *)classDesc
                               containerSpecifier:(NSScriptObjectSpecifier *)container
                                              key:(NSString *)property
                                             name:(NSString *)name
{
    if ((self = [super initWithContainerClassDescription:classDesc containerSpecifier:container key:property]))
        _name = [name copy];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)inCoder
{
    if ((self = [super initWithCoder:inCoder]))
        _name = [[inCoder decodeObjectForKey:@"NSName"] copy];
    return self;
}

- (void)dealloc
{
    [_name release];
    [super dealloc];
}

- (NSString *)name { return _name; }
- (void)setName:(NSString *)name
{
    [_name autorelease];
    _name = [name copy];
}

- (NSInteger *)indicesOfObjectsByEvaluatingWithContainer:(id)container count:(NSInteger *)count
{
    NSArray *all = to_many(container, [self key]);
    for (NSUInteger i = 0; i < [all count]; i++) {
        id o = [all objectAtIndex:i];
        if ([o respondsToSelector:@selector(name)] && [[o valueForKey:@"name"] isEqual:_name])
            return one_index((NSInteger)i, count);
    }
    *count = 0;
    [self setEvaluationErrorNumber:NSNoSpecifierError];
    return NULL;
}

@end

@implementation NSUniqueIDSpecifier

- (instancetype)initWithContainerClassDescription:(NSScriptClassDescription *)classDesc
                               containerSpecifier:(NSScriptObjectSpecifier *)container
                                              key:(NSString *)property
                                         uniqueID:(id)uniqueID
{
    if ((self = [super initWithContainerClassDescription:classDesc containerSpecifier:container key:property]))
        _uniqueID = [uniqueID copy];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)inCoder
{
    if ((self = [super initWithCoder:inCoder]))
        _uniqueID = [[inCoder decodeObjectForKey:@"NSUniqueID"] copy];
    return self;
}

- (void)dealloc
{
    [_uniqueID release];
    [super dealloc];
}

- (id)uniqueID { return _uniqueID; }
- (void)setUniqueID:(id)uniqueID
{
    [_uniqueID autorelease];
    _uniqueID = [uniqueID copy];
}

- (NSInteger *)indicesOfObjectsByEvaluatingWithContainer:(id)container count:(NSInteger *)count
{
    NSArray *all = to_many(container, [self key]);
    for (NSUInteger i = 0; i < [all count]; i++) {
        id o = [all objectAtIndex:i];
        if ([o respondsToSelector:@selector(uniqueID)] && [[o valueForKey:@"uniqueID"] isEqual:_uniqueID])
            return one_index((NSInteger)i, count);
    }
    *count = 0;
    [self setEvaluationErrorNumber:NSNoSpecifierError];
    return NULL;
}

@end

#define _start _startSpec
#define _end _endSpec

@implementation NSRangeSpecifier

- (instancetype)initWithContainerClassDescription:(NSScriptClassDescription *)classDesc
                               containerSpecifier:(NSScriptObjectSpecifier *)container
                                              key:(NSString *)property
                                   startSpecifier:(NSScriptObjectSpecifier *)startSpec
                                     endSpecifier:(NSScriptObjectSpecifier *)endSpec
{
    if ((self = [super initWithContainerClassDescription:classDesc containerSpecifier:container key:property])) {
        _start = [startSpec retain];
        _end = [endSpec retain];
    }
    return self;
}

- (void)dealloc
{
    [_start release];
    [_end release];
    [super dealloc];
}

- (NSScriptObjectSpecifier *)startSpecifier { return _start; }
- (void)setStartSpecifier:(NSScriptObjectSpecifier *)startSpec
{
    [_start autorelease];
    _start = [startSpec retain];
}
- (NSScriptObjectSpecifier *)endSpecifier { return _end; }
- (void)setEndSpecifier:(NSScriptObjectSpecifier *)endSpec
{
    [_end autorelease];
    _end = [endSpec retain];
}

- (NSInteger *)indicesOfObjectsByEvaluatingWithContainer:(id)container count:(NSInteger *)count
{
    NSArray *all = to_many(container, [self key]);
    NSInteger a = 0, b = (NSInteger)[all count] - 1, n = 0;
    NSInteger *ia = _start ? [_start indicesOfObjectsByEvaluatingWithContainer:container count:&n] : NULL;
    if (ia && n == 1)
        a = ia[0];
    NSInteger *ib = _end ? [_end indicesOfObjectsByEvaluatingWithContainer:container count:&n] : NULL;
    if (ib && n == 1)
        b = ib[0];
    if (a > b) {
        NSInteger t = a;
        a = b, b = t;
    }
    if (b < a || a < 0) {
        *count = 0;
        return NULL;
    }
    NSMutableData *d = [NSMutableData dataWithLength:sizeof(NSInteger) * (NSUInteger)(b - a + 1)];
    NSInteger *out = (NSInteger *)[d mutableBytes];
    for (NSInteger i = a; i <= b; i++)
        out[i - a] = i;
    *count = b - a + 1;
    return out;
}

@end

#undef _start
#undef _end
#define _position _relativePosition
#define _base _baseSpecifier

@implementation NSRelativeSpecifier

- (instancetype)initWithContainerClassDescription:(NSScriptClassDescription *)classDesc
                               containerSpecifier:(NSScriptObjectSpecifier *)container
                                              key:(NSString *)property
                                 relativePosition:(NSRelativePosition)relPos
                                    baseSpecifier:(NSScriptObjectSpecifier *)baseSpecifier
{
    if ((self = [super initWithContainerClassDescription:classDesc containerSpecifier:container key:property])) {
        _position = relPos;
        _base = [baseSpecifier retain];
    }
    return self;
}

- (void)dealloc
{
    [_base release];
    [super dealloc];
}

- (NSRelativePosition)relativePosition { return _position; }
- (void)setRelativePosition:(NSRelativePosition)relPos { _position = relPos; }
- (NSScriptObjectSpecifier *)baseSpecifier { return _base; }
- (void)setBaseSpecifier:(NSScriptObjectSpecifier *)baseSpecifier
{
    [_base autorelease];
    _base = [baseSpecifier retain];
}

- (NSInteger *)indicesOfObjectsByEvaluatingWithContainer:(id)container count:(NSInteger *)count
{
    NSArray *all = to_many(container, [self key]);
    NSInteger n = 0, *base = [_base indicesOfObjectsByEvaluatingWithContainer:container count:&n];
    if (!base || n != 1) {
        *count = 0;
        return NULL;
    }
    NSInteger i = base[0] + (_position == NSRelativeAfter ? 1 : -1);
    if (i < 0 || i >= (NSInteger)[all count]) {
        *count = 0;
        return NULL;
    }
    return one_index(i, count);
}

@end

#undef _position
#undef _base

#pragma mark - Scripting key-value coding

@implementation NSObject (NSScriptKeyValueCoding)

- (id)valueAtIndex:(NSUInteger)index inPropertyWithKey:(NSString *)key
{
    NSArray *all = to_many(self, key);
    return index < [all count] ? [all objectAtIndex:index] : nil;
}

- (id)valueWithName:(NSString *)name inPropertyWithKey:(NSString *)key
{
    for (id o in to_many(self, key))
        if ([o respondsToSelector:@selector(name)] && [[o valueForKey:@"name"] isEqual:name])
            return o;
    return nil;
}

- (id)valueWithUniqueID:(id)uniqueID inPropertyWithKey:(NSString *)key
{
    for (id o in to_many(self, key))
        if ([o respondsToSelector:@selector(uniqueID)] && [[o valueForKey:@"uniqueID"] isEqual:uniqueID])
            return o;
    return nil;
}

- (void)insertValue:(id)value atIndex:(NSUInteger)index inPropertyWithKey:(NSString *)key
{
    [[self mutableArrayValueForKey:key] insertObject:value atIndex:index];
}

- (void)removeValueAtIndex:(NSUInteger)index fromPropertyWithKey:(NSString *)key
{
    [[self mutableArrayValueForKey:key] removeObjectAtIndex:index];
}

- (void)replaceValueAtIndex:(NSUInteger)index inPropertyWithKey:(NSString *)key withValue:(id)value
{
    [[self mutableArrayValueForKey:key] replaceObjectAtIndex:index withObject:value];
}

- (void)insertValue:(id)value inPropertyWithKey:(NSString *)key
{
    [[self mutableArrayValueForKey:key] addObject:value];
}

- (id)coerceValue:(id)value forKey:(NSString *)key { return value; }

@end

@implementation NSObject (NSScriptObjectSpecifiers)

- (NSScriptObjectSpecifier *)objectSpecifier { return nil; }

- (NSArray<NSNumber *> *)indicesOfObjectsByEvaluatingObjectSpecifier:(NSScriptObjectSpecifier *)specifier
{
    return nil; /* nil: let the specifier evaluate itself */
}

@end

#pragma mark - The suite registry

/* Apple's ivars: classes by name, commands by "suite.command", and suite names. */
#define _classes _cachedClassDescriptionsByAppleEventCode
#define _commands _cachedCommandDescriptionsByAppleEventCodes
#define _suites _suiteDescriptions

@implementation NSScriptSuiteRegistry

static NSScriptSuiteRegistry *shared_registry;

+ (NSScriptSuiteRegistry *)sharedScriptSuiteRegistry
{
    @synchronized(self) {
        if (!shared_registry)
            shared_registry = [[NSScriptSuiteRegistry alloc] init];
    }
    return shared_registry;
}

+ (void)setSharedScriptSuiteRegistry:(NSScriptSuiteRegistry *)registry
{
    @synchronized(self) {
        [shared_registry autorelease];
        shared_registry = [registry retain];
    }
}

- (instancetype)init
{
    if ((self = [super init])) {
        _classes = [[NSMutableDictionary alloc] init];
        _commands = [[NSMutableDictionary alloc] init];
        _suites = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_classes release];
    [_commands release];
    [_suites release];
    [super dealloc];
}

- (void)loadSuitesFromBundle:(NSBundle *)bundle {}

- (void)loadSuiteWithDictionary:(NSDictionary *)suiteDeclaration fromBundle:(NSBundle *)bundle
{
    NSString *suite = [suiteDeclaration objectForKey:@"Name"];
    if (!suite)
        return;
    [_suites addObject:suite];
    NSDictionary *classes = [suiteDeclaration objectForKey:@"Classes"];
    for (NSString *name in classes)
        [self registerClassDescription:[[[NSScriptClassDescription alloc] initWithSuiteName:suite className:name
                                                                                  dictionary:[classes objectForKey:name]] autorelease]];
    NSDictionary *commands = [suiteDeclaration objectForKey:@"Commands"];
    for (NSString *name in commands)
        [self registerCommandDescription:[[[NSScriptCommandDescription alloc] initWithSuiteName:suite commandName:name
                                                                                       dictionary:[commands objectForKey:name]] autorelease]];
}

- (void)registerClassDescription:(NSScriptClassDescription *)classDescription
{
    if (![classDescription className])
        return;
    [_classes setObject:classDescription forKey:[classDescription className]];
    Class c = NSClassFromString([classDescription implementationClassName]);
    if (c)
        [NSClassDescription registerClassDescription:classDescription forClass:c];
}

- (void)registerCommandDescription:(NSScriptCommandDescription *)commandDescription
{
    NSString *key = [NSString stringWithFormat:@"%@.%@", [commandDescription suiteName], [commandDescription commandName]];
    [_commands setObject:commandDescription forKey:key];
}

- (NSArray<NSString *> *)suiteNames { return [[_suites copy] autorelease]; }

- (NSDictionary<NSString *, NSScriptClassDescription *> *)classDescriptionsInSuite:(NSString *)suiteName
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in _classes)
        if ([[[_classes objectForKey:k] suiteName] isEqualToString:suiteName])
            [d setObject:[_classes objectForKey:k] forKey:k];
    return d;
}

- (NSDictionary<NSString *, NSScriptCommandDescription *> *)commandDescriptionsInSuite:(NSString *)suiteName
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in _commands) {
        NSScriptCommandDescription *c = [_commands objectForKey:k];
        if ([[c suiteName] isEqualToString:suiteName])
            [d setObject:c forKey:[c commandName]];
    }
    return d;
}

- (NSScriptClassDescription *)classDescriptionWithAppleEventCode:(FourCharCode)appleEventCode
{
    for (NSString *k in _classes)
        if ([[_classes objectForKey:k] appleEventCode] == appleEventCode)
            return [_classes objectForKey:k];
    return nil;
}

- (NSScriptCommandDescription *)commandDescriptionWithAppleEventClass:(FourCharCode)appleEventClassCode
                                                    andAppleEventCode:(FourCharCode)appleEventIDCode
{
    for (NSString *k in _commands) {
        NSScriptCommandDescription *c = [_commands objectForKey:k];
        if ([c appleEventClassCode] == appleEventClassCode && [c appleEventCode] == appleEventIDCode)
            return c;
    }
    return nil;
}

- (NSString *)suiteForAppleEventCode:(FourCharCode)appleEventCode { return nil; }
- (FourCharCode)appleEventCodeForSuite:(NSString *)suiteName { return 0; }
- (NSBundle *)bundleForSuite:(NSString *)suiteName { return nil; }
- (NSData *)aeteResource:(NSString *)languageName { return nil; }

@end

#undef _classes
#undef _commands
#undef _suites
