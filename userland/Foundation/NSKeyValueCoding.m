/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Key-value coding (docs/design/FOUNDATION.md), against the SDK's
 * declarations, with Apple's search order:
 *
 *   get   -get<Key>, -<key>, -is<Key>, -_<key>; then, if the class allows
 *         it (+accessInstanceVariablesDirectly), the ivars _<key>, _is<Key>,
 *         <key>, is<Key>; else -valueForUndefinedKey:, which raises
 *         NSUnknownKeyException.
 *   set   -set<Key>:, -_set<Key>:; the same ivars; else
 *         -setValue:forUndefinedKey:. nil for a scalar goes to
 *         -setNilValueForKey:, which raises.
 *
 * Scalars are boxed in NSNumber, structs in NSValue. Arrays and sets map
 * keys over their elements and take the collection operators (@count,
 * @sum, @avg, @max, @min, @unionOfObjects, @distinctUnionOfObjects,
 * @unionOfArrays, @distinctUnionOfArrays, @distinctUnionOfSets);
 * dictionaries read and write their entries. -mutableArrayValueForKey:
 * returns a proxy that mutates through the indexed accessors when the
 * object has them, else by setting the whole array.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <ctype.h>

#include "Foundation_Finch.h"

__attribute__((visibility("hidden"))) void FinchKVOQuietly(id obj, NSString *key, void (^body)(void));   /* NSKeyValueObserving.m */

NSExceptionName const NSUndefinedKeyException = @"NSUnknownKeyException";
NSString *const NSTargetObjectUserInfoKey = @"NSTargetObjectUserInfoKey";
NSString *const NSUnknownUserInfoKey = @"NSUnknownUserInfoKey";
NSString *const NSAverageKeyValueOperator = @"avg";
NSString *const NSCountKeyValueOperator = @"count";
NSString *const NSDistinctUnionOfArraysKeyValueOperator = @"distinctUnionOfArrays";
NSString *const NSDistinctUnionOfObjectsKeyValueOperator = @"distinctUnionOfObjects";
NSString *const NSDistinctUnionOfSetsKeyValueOperator = @"distinctUnionOfSets";
NSString *const NSMaximumKeyValueOperator = @"max";
NSString *const NSMinimumKeyValueOperator = @"min";
NSString *const NSSumKeyValueOperator = @"sum";
NSString *const NSUnionOfArraysKeyValueOperator = @"unionOfArrays";
NSString *const NSUnionOfObjectsKeyValueOperator = @"unionOfObjects";
NSString *const NSUnionOfSetsKeyValueOperator = @"unionOfSets";

/* "name" -> "Name" */
static NSString *
capitalized(NSString *key)
{
    if ([key length] == 0) return key;
    unichar c = [key characterAtIndex:0];
    if (c >= 'a' && c <= 'z') c = (unichar)(c - 'a' + 'A');
    return [[NSString stringWithCharacters:&c length:1] stringByAppendingString:[key substringFromIndex:1]];
}

static SEL
selector(NSString *fmt, NSString *key)
{
    return NSSelectorFromString([NSString stringWithFormat:fmt, key]);
}

/* MARK: - Boxing */

static id
box(const char *type, const void *p)
{
    while (*type && strchr("rnNoORV", *type)) type++;
    switch (*type) {
    case '@': case '#': return *(id const *)p;
    case 'c': return [NSNumber numberWithChar:*(const char *)p];
    case 'C': return [NSNumber numberWithUnsignedChar:*(const unsigned char *)p];
    case 'B': return [NSNumber numberWithBool:*(const _Bool *)p];
    case 's': return [NSNumber numberWithShort:*(const short *)p];
    case 'S': return [NSNumber numberWithUnsignedShort:*(const unsigned short *)p];
    case 'i': return [NSNumber numberWithInt:*(const int *)p];
    case 'I': return [NSNumber numberWithUnsignedInt:*(const unsigned int *)p];
    case 'l': return [NSNumber numberWithLong:*(const long *)p];
    case 'L': return [NSNumber numberWithUnsignedLong:*(const unsigned long *)p];
    case 'q': return [NSNumber numberWithLongLong:*(const long long *)p];
    case 'Q': return [NSNumber numberWithUnsignedLongLong:*(const unsigned long long *)p];
    case 'f': return [NSNumber numberWithFloat:*(const float *)p];
    case 'd': return [NSNumber numberWithDouble:*(const double *)p];
    default: return [NSValue valueWithBytes:p objCType:type];
    }
}

/* Store `value` as `type` at p; NO if it can't be (nil for a scalar). */
static BOOL
unbox(id value, const char *type, void *p)
{
    while (*type && strchr("rnNoORV", *type)) type++;
    if (*type == '@' || *type == '#') {
        *(id *)p = value;
        return YES;
    }
    if (!value) return NO;
    switch (*type) {
    case 'c': *(char *)p = [value charValue]; break;
    case 'C': *(unsigned char *)p = [value unsignedCharValue]; break;
    case 'B': *(_Bool *)p = [value boolValue]; break;
    case 's': *(short *)p = [value shortValue]; break;
    case 'S': *(unsigned short *)p = [value unsignedShortValue]; break;
    case 'i': *(int *)p = [value intValue]; break;
    case 'I': *(unsigned int *)p = [value unsignedIntValue]; break;
    case 'l': *(long *)p = [value longValue]; break;
    case 'L': *(unsigned long *)p = [value unsignedLongValue]; break;
    case 'q': *(long long *)p = [value longLongValue]; break;
    case 'Q': *(unsigned long long *)p = [value unsignedLongLongValue]; break;
    case 'f': *(float *)p = [value floatValue]; break;
    case 'd': *(double *)p = [value doubleValue]; break;
    default: {
        NSUInteger size;
        NSGetSizeAndAlignment(type, &size, NULL);
        [(NSValue *)value getValue:p size:size];
        break;
    }
    }
    return YES;
}

/* MARK: - Accessors */

static id
call_getter(id obj, SEL sel)
{
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    char ret[128];
    method_getReturnType(m, ret, sizeof(ret));
    const char *t = ret;
    while (*t && strchr("rnNoORV", *t)) t++;
    if (*t == '@' || *t == '#') return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    if (*t == 'v') return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[obj methodSignatureForSelector:sel]];
    [inv setSelector:sel];
    [inv invokeWithTarget:obj];
    NSUInteger size;
    NSGetSizeAndAlignment(t, &size, NULL);
    void *buf = calloc(1, size + 16);
    [inv getReturnValue:buf];
    id v = box(t, buf);
    free(buf);
    return v;
}

static BOOL
call_setter(id obj, SEL sel, id value, NSString *key)
{
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    char arg[128];
    method_getArgumentType(m, 2, arg, sizeof(arg));
    const char *t = arg;
    while (*t && strchr("rnNoORV", *t)) t++;
    if (*t == '@' || *t == '#') {
        ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, value);
        return YES;
    }
    if (!value) {
        [obj setNilValueForKey:key];
        return YES;
    }
    NSUInteger size;
    NSGetSizeAndAlignment(t, &size, NULL);
    void *buf = calloc(1, size + 16);
    unbox(value, t, buf);
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[obj methodSignatureForSelector:sel]];
    [inv setSelector:sel];
    [inv setArgument:buf atIndex:2];
    [inv invokeWithTarget:obj];
    free(buf);
    return YES;
}

static Ivar
find_ivar(Class cls, NSString *key)
{
    NSString *cap = capitalized(key);
    NSString *names[] = { [@"_" stringByAppendingString:key], [@"_is" stringByAppendingString:cap], key, [@"is" stringByAppendingString:cap] };
    for (int i = 0; i < 4; i++) {
        Ivar iv = class_getInstanceVariable(cls, [names[i] UTF8String]);
        if (iv) return iv;
    }
    return NULL;
}

/* The getter's selector, or NULL. */
static SEL
getter_for(Class cls, NSString *key)
{
    NSString *cap = capitalized(key);
    SEL sels[] = { selector(@"get%@", cap), NSSelectorFromString(key), selector(@"is%@", cap), selector(@"_%@", key) };
    for (int i = 0; i < 4; i++)
        if (class_respondsToSelector(cls, sels[i])) return sels[i];
    return NULL;
}

/* MARK: - Array proxy */

@interface __NSKeyValueMutableArrayProxy : NSMutableArray {
@public
    id _object;
    NSString *_key;
}
@end

@implementation __NSKeyValueMutableArrayProxy

- (void)dealloc { [_object release]; [_key release]; [super dealloc]; }

- (NSArray *)_finchArray
{
    id v = [_object valueForKey:_key];
    return v ? v : @[];
}

- (NSUInteger)count { return [[self _finchArray] count]; }
- (id)objectAtIndex:(NSUInteger)i { return [[self _finchArray] objectAtIndex:i]; }

/* Without indexed accessors: change a copy and set it, telling observers
 * it was a collection change (the setter's own notification is quieted). */
- (void)_finchChange:(NSKeyValueChange)kind at:(NSUInteger)index with:(void (^)(NSMutableArray *))edit
{
    NSIndexSet *idx = [NSIndexSet indexSetWithIndex:index];
    NSMutableArray *m = [[[self _finchArray] mutableCopy] autorelease];
    [_object willChange:kind valuesAtIndexes:idx forKey:_key];
    edit(m);
    FinchKVOQuietly(_object, _key, ^{ [_object setValue:m forKey:_key]; });
    [_object didChange:kind valuesAtIndexes:idx forKey:_key];
}

- (void)insertObject:(id)o atIndex:(NSUInteger)i
{
    SEL s = selector(@"insertObject:in%@AtIndex:", capitalized(_key));
    if ([_object respondsToSelector:s]) ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(_object, s, o, i);
    else [self _finchChange:NSKeyValueChangeInsertion at:i with:^(NSMutableArray *m) { [m insertObject:o atIndex:i]; }];
}

- (void)removeObjectAtIndex:(NSUInteger)i
{
    SEL s = selector(@"removeObjectFrom%@AtIndex:", capitalized(_key));
    if ([_object respondsToSelector:s]) ((void (*)(id, SEL, NSUInteger))objc_msgSend)(_object, s, i);
    else [self _finchChange:NSKeyValueChangeRemoval at:i with:^(NSMutableArray *m) { [m removeObjectAtIndex:i]; }];
}

- (void)replaceObjectAtIndex:(NSUInteger)i withObject:(id)o
{
    SEL s = selector(@"replaceObjectIn%@AtIndex:withObject:", capitalized(_key));
    if ([_object respondsToSelector:s]) ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(_object, s, i, o);
    else [self _finchChange:NSKeyValueChangeReplacement at:i with:^(NSMutableArray *m) { [m replaceObjectAtIndex:i withObject:o]; }];
}

- (void)addObject:(id)o { [self insertObject:o atIndex:[self count]]; }
- (void)removeLastObject { NSUInteger n = [self count]; if (n) [self removeObjectAtIndex:n - 1]; }

@end

/* MARK: - NSObject */

@implementation NSObject (NSKeyValueCoding)

+ (BOOL)accessInstanceVariablesDirectly { return YES; }

- (id)valueForKey:(NSString *)key
{
    if (!key)
        FinchRaise(NSInvalidArgumentException, "*** -valueForKey: key cannot be nil");
    Class cls = object_getClass(self);
    SEL g = getter_for(cls, key);
    if (g) return call_getter(self, g);
    NSString *cap = capitalized(key);
    if (class_respondsToSelector(cls, selector(@"countOf%@", cap)) &&
        class_respondsToSelector(cls, selector(@"objectIn%@AtIndex:", cap))) {
        NSUInteger n = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, selector(@"countOf%@", cap));
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
        SEL at = selector(@"objectIn%@AtIndex:", cap);
        for (NSUInteger i = 0; i < n; i++) [a addObject:((id (*)(id, SEL, NSUInteger))objc_msgSend)(self, at, i)];
        return a;
    }
    if ([[self class] accessInstanceVariablesDirectly]) {
        Ivar iv = find_ivar(cls, key);
        if (iv) {
            const char *t = ivar_getTypeEncoding(iv);
            if (t[0] == '@') return object_getIvar(self, iv);
            return box(t, (char *)self + ivar_getOffset(iv));
        }
    }
    return [self valueForUndefinedKey:key];
}

- (void)setValue:(id)value forKey:(NSString *)key
{
    if (!key)
        FinchRaise(NSInvalidArgumentException, "*** -setValue:forKey: key cannot be nil");
    Class cls = object_getClass(self);
    NSString *cap = capitalized(key);
    SEL setters[] = { selector(@"set%@:", cap), selector(@"_set%@:", cap) };
    for (int i = 0; i < 2; i++)
        if (class_respondsToSelector(cls, setters[i])) {
            call_setter(self, setters[i], value, key);
            return;
        }
    if ([[self class] accessInstanceVariablesDirectly]) {
        Ivar iv = find_ivar(cls, key);
        if (iv) {
            const char *t = ivar_getTypeEncoding(iv);
            [self willChangeValueForKey:key];
            if (t[0] == '@') {
                object_setIvarWithStrongDefault(self, iv, value);
            } else if (!unbox(value, t, (char *)self + ivar_getOffset(iv))) {
                [self didChangeValueForKey:key];
                [self setNilValueForKey:key];
                return;
            }
            [self didChangeValueForKey:key];
            return;
        }
    }
    [self setValue:value forUndefinedKey:key];
}

- (id)valueForUndefinedKey:(NSString *)key
{
    NSException *e = [NSException exceptionWithName:NSUndefinedKeyException
        reason:[NSString stringWithFormat:@"[<%@ %p> valueForUndefinedKey:]: this class is not key value coding-compliant for the key %@.", [self class], self, key]
        userInfo:@{ NSTargetObjectUserInfoKey: self, NSUnknownUserInfoKey: key }];
    [e raise];
    return nil;
}

- (void)setValue:(id)value forUndefinedKey:(NSString *)key
{
    NSException *e = [NSException exceptionWithName:NSUndefinedKeyException
        reason:[NSString stringWithFormat:@"[<%@ %p> setValue:forUndefinedKey:]: this class is not key value coding-compliant for the key %@.", [self class], self, key]
        userInfo:@{ NSTargetObjectUserInfoKey: self, NSUnknownUserInfoKey: key }];
    [e raise];
}

- (void)setNilValueForKey:(NSString *)key
{
    [NSException raise:NSInvalidArgumentException
                format:@"[<%@ %p> setNilValueForKey]: could not set nil as the value for the key %@.", [self class], self, key];
}

- (id)valueForKeyPath:(NSString *)keyPath
{
    NSRange dot = [keyPath rangeOfString:@"."];
    if (dot.location == NSNotFound) return [self valueForKey:keyPath];
    id first = [self valueForKey:[keyPath substringToIndex:dot.location]];
    return [first valueForKeyPath:[keyPath substringFromIndex:dot.location + 1]];
}

- (void)setValue:(id)value forKeyPath:(NSString *)keyPath
{
    NSRange dot = [keyPath rangeOfString:@"."];
    if (dot.location == NSNotFound) {
        [self setValue:value forKey:keyPath];
        return;
    }
    [[self valueForKey:[keyPath substringToIndex:dot.location]] setValue:value forKeyPath:[keyPath substringFromIndex:dot.location + 1]];
}

- (NSDictionary<NSString *, id> *)dictionaryWithValuesForKeys:(NSArray<NSString *> *)keys
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:[keys count]];
    for (NSString *k in keys) {
        id v = [self valueForKey:k];
        [d setObject:v ? v : [NSNull null] forKey:k];
    }
    return d;
}

- (void)setValuesForKeysWithDictionary:(NSDictionary<NSString *, id> *)keyedValues
{
    for (NSString *k in keyedValues) {
        id v = [keyedValues objectForKey:k];
        [self setValue:v == [NSNull null] ? nil : v forKey:k];
    }
}

- (BOOL)validateValue:(inout id *)ioValue forKey:(NSString *)inKey error:(out NSError **)outError
{
    SEL v = selector(@"validate%@:error:", capitalized(inKey));
    if ([self respondsToSelector:v]) return ((BOOL (*)(id, SEL, id *, NSError **))objc_msgSend)(self, v, ioValue, outError);
    return YES;
}

- (BOOL)validateValue:(inout id *)ioValue forKeyPath:(NSString *)inKeyPath error:(out NSError **)outError
{
    NSRange dot = [inKeyPath rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location == NSNotFound) return [self validateValue:ioValue forKey:inKeyPath error:outError];
    return [[self valueForKeyPath:[inKeyPath substringToIndex:dot.location]] validateValue:ioValue
        forKey:[inKeyPath substringFromIndex:dot.location + 1] error:outError];
}

- (NSMutableArray *)mutableArrayValueForKey:(NSString *)key
{
    __NSKeyValueMutableArrayProxy *p = [[[__NSKeyValueMutableArrayProxy alloc] init] autorelease];
    p->_object = [self retain];
    p->_key = [key copy];
    return p;
}

- (NSMutableArray *)mutableArrayValueForKeyPath:(NSString *)keyPath
{
    NSRange dot = [keyPath rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location == NSNotFound) return [self mutableArrayValueForKey:keyPath];
    return [[self valueForKeyPath:[keyPath substringToIndex:dot.location]] mutableArrayValueForKey:[keyPath substringFromIndex:dot.location + 1]];
}

- (NSMutableSet *)mutableSetValueForKey:(NSString *)key
{
    NSMutableSet *s = [NSMutableSet setWithSet:[self valueForKey:key]];
    return s;
}

@end

/* MARK: - Collections */

/* "@op.rest" applied to a collection's elements. */
static id
collection_operator(id collection, NSString *keyPath)
{
    NSRange dot = [keyPath rangeOfString:@"."];
    NSString *op = [keyPath substringWithRange:NSMakeRange(1, (dot.location == NSNotFound ? [keyPath length] : dot.location) - 1)];
    NSString *rest = dot.location == NSNotFound ? nil : [keyPath substringFromIndex:dot.location + 1];
    if ([op isEqualToString:NSCountKeyValueOperator]) return [NSNumber numberWithUnsignedInteger:[collection count]];
    NSMutableArray *values = [NSMutableArray array];
    for (id o in collection) {
        id v = rest ? [o valueForKeyPath:rest] : o;
        if (v && v != [NSNull null]) [values addObject:v];
    }
    if ([op isEqualToString:NSSumKeyValueOperator] || [op isEqualToString:NSAverageKeyValueOperator]) {
        double sum = 0;
        BOOL integral = YES;
        for (NSNumber *n in values) {
            sum += [n doubleValue];
            integral = integral && (strchr("cCsSiIlLqQB", *[n objCType]) != NULL);
        }
        if ([op isEqualToString:NSAverageKeyValueOperator]) {
            if ([values count] == 0) return nil;
            sum /= (double)[values count];
            integral = NO;
        }
        return integral ? [NSNumber numberWithLongLong:(long long)sum] : [NSNumber numberWithDouble:sum];
    }
    if ([op isEqualToString:NSMaximumKeyValueOperator] || [op isEqualToString:NSMinimumKeyValueOperator]) {
        BOOL max = [op isEqualToString:NSMaximumKeyValueOperator];
        id best = nil;
        for (id v in values)
            if (!best || [v compare:best] == (max ? NSOrderedDescending : NSOrderedAscending)) best = v;
        return best;
    }
    if ([op isEqualToString:NSUnionOfObjectsKeyValueOperator]) return values;
    if ([op isEqualToString:NSDistinctUnionOfObjectsKeyValueOperator]) return [[NSSet setWithArray:values] allObjects];
    if ([op isEqualToString:NSUnionOfArraysKeyValueOperator] || [op isEqualToString:NSDistinctUnionOfArraysKeyValueOperator] ||
        [op isEqualToString:NSDistinctUnionOfSetsKeyValueOperator] || [op isEqualToString:NSUnionOfSetsKeyValueOperator]) {
        NSMutableArray *all = [NSMutableArray array];
        for (id c in values) for (id o in c) [all addObject:o];
        if ([op hasPrefix:@"distinct"]) return [[NSSet setWithArray:all] allObjects];
        return all;
    }
    FinchRaise(NSInvalidArgumentException, "[<%s %p> valueForKeyPath:]: this class does not implement the %@ operation.",
        object_getClassName(collection), collection, op);
}

@implementation NSArray (NSKeyValueCoding)

- (id)valueForKey:(NSString *)key
{
    if ([key hasPrefix:@"@"]) return [super valueForKey:[key substringFromIndex:1]];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[self count]];
    for (id o in self) {
        id v = [o valueForKey:key];
        [out addObject:v ? v : [NSNull null]];
    }
    return out;
}

- (void)setValue:(id)value forKey:(NSString *)key
{
    for (id o in self) [o setValue:value forKey:key];
}

- (id)valueForKeyPath:(NSString *)keyPath
{
    if ([keyPath hasPrefix:@"@"]) return collection_operator(self, keyPath);
    return [super valueForKeyPath:keyPath];
}

@end

@implementation NSSet (NSKeyValueCoding)

- (id)valueForKey:(NSString *)key
{
    if ([key hasPrefix:@"@"]) return [super valueForKey:[key substringFromIndex:1]];
    NSMutableSet *out = [NSMutableSet setWithCapacity:[self count]];
    for (id o in self) {
        id v = [o valueForKey:key];
        if (v) [out addObject:v];
    }
    return out;
}

- (void)setValue:(id)value forKey:(NSString *)key
{
    for (id o in self) [o setValue:value forKey:key];
}

- (id)valueForKeyPath:(NSString *)keyPath
{
    if ([keyPath hasPrefix:@"@"]) return collection_operator(self, keyPath);
    return [super valueForKeyPath:keyPath];
}

@end

@implementation NSDictionary (NSKeyValueCoding)

- (id)valueForKey:(NSString *)key
{
    if ([key hasPrefix:@"@"]) return [super valueForKey:[key substringFromIndex:1]];
    return [self objectForKey:key];
}

@end

@implementation NSMutableDictionary (NSKeyValueCoding)

- (void)setValue:(id)value forKey:(NSString *)key
{
    if (value) [self setObject:value forKey:key];
    else [self removeObjectForKey:key];
}

@end
