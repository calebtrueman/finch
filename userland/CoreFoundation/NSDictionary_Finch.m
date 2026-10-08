/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSDictionary and NSMutableDictionary, which Apple's CoreFoundation hosts
 * (docs/design/FOUNDATION.md), with __NSCFDictionary, the class of every
 * CFDictionary. As in NSArray_Finch.m: the abstract classes build on their
 * primitives (-count, -objectForKey:, -keyEnumerator; -setObject:forKey:,
 * -removeObjectForKey:), +alloc returns __NSPlaceholderDictionary, and what
 * it makes is a CFDictionary. Keys are copied, as NSDictionary promises.
 *
 * The double-underscore methods are the ones CF sends to dictionaries it
 * didn't make (CFDictionaryGetValueIfPresent and friends).
 */
#include "CFObjCClasses_Finch.h"
#include "CFBasicHash.h"

@interface NSEnumerator : NSObject
- (id)nextObject;
@end
@interface __NSFastEnumerationEnumerator : NSEnumerator
- (instancetype)_initWithCollection:(id)collection reverse:(BOOL)reverse;
@end
@interface NSArray (FinchDictionary)
+ (instancetype)arrayWithObjects:(const id *)objects count:(NSUInteger)count;
+ (instancetype)array;
@end

@interface NSDictionary () <NSCopying, NSMutableCopying, NSFastEnumeration>
+ (instancetype)dictionary;
+ (instancetype)dictionaryWithObject:(id)object forKey:(id)key;
+ (instancetype)dictionaryWithObjects:(const id *)objects forKeys:(const id *)keys count:(NSUInteger)count;
+ (instancetype)dictionaryWithObjectsAndKeys:(id)first, ...;
+ (instancetype)dictionaryWithDictionary:(NSDictionary *)dict;
+ (instancetype)dictionaryWithObjects:(NSArray *)objects forKeys:(NSArray *)keys;
- (instancetype)init;
- (instancetype)initWithObjects:(const id *)objects forKeys:(const id *)keys count:(NSUInteger)count;
- (instancetype)initWithObjectsAndKeys:(id)first, ...;
- (instancetype)initWithDictionary:(NSDictionary *)dict;
- (instancetype)initWithDictionary:(NSDictionary *)dict copyItems:(BOOL)copy;
- (instancetype)initWithObjects:(NSArray *)objects forKeys:(NSArray *)keys;
- (id)keyEnumerator;
- (id)objectEnumerator;
- (id)objectForKeyedSubscript:(id)key;
- (NSArray *)allKeys;
- (NSArray *)allValues;
- (NSArray *)allKeysForObject:(id)object;
- (BOOL)isEqualToDictionary:(NSDictionary *)other;
- (void)getObjects:(id *)objects andKeys:(id *)keys count:(NSUInteger)count;
- (void)enumerateKeysAndObjectsUsingBlock:(void (^)(id key, id obj, BOOL *stop))block;
- (void)enumerateKeysAndObjectsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (^)(id key, id obj, BOOL *stop))block;
@end

@interface NSMutableDictionary ()
+ (instancetype)dictionaryWithCapacity:(NSUInteger)capacity;
- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (void)setObject:(id)object forKey:(id)key;
- (void)setObject:(id)object forKeyedSubscript:(id)key;
- (void)addEntriesFromDictionary:(NSDictionary *)dict;
- (void)removeObjectsForKeys:(NSArray *)keys;
- (void)setDictionary:(NSDictionary *)dict;
@end

@interface __NSPlaceholderDictionary : NSMutableDictionary
@end
@interface __NSCFDictionary : NSMutableDictionary
@end

static __NSPlaceholderDictionary *immutablePlaceholder, *mutablePlaceholder;

CF_PRIVATE Class
__CFFinchInitializeDictionaryClasses(void)
{
    immutablePlaceholder = class_createInstance([__NSPlaceholderDictionary class], 0);
    mutablePlaceholder = class_createInstance([__NSPlaceholderDictionary class], 0);
    return [__NSCFDictionary class];
}

static id
copy_key(id key)
{
    return [key copyWithZone:NULL];
}

/* MARK: - NSDictionary */

@implementation NSDictionary

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSDictionary class]) return (id)immutablePlaceholder;
    if (self == [NSMutableDictionary class]) return (id)mutablePlaceholder;
    return [super allocWithZone:zone];
}

+ (instancetype)dictionary { return [[[self alloc] init] autorelease]; }
+ (instancetype)dictionaryWithObject:(id)object forKey:(id)key
{
    return [[[self alloc] initWithObjects:&object forKeys:&key count:1] autorelease];
}
+ (instancetype)dictionaryWithObjects:(const id *)objects forKeys:(const id *)keys count:(NSUInteger)count
{
    return [[[self alloc] initWithObjects:objects forKeys:keys count:count] autorelease];
}
+ (instancetype)dictionaryWithDictionary:(NSDictionary *)dict { return [[[self alloc] initWithDictionary:dict] autorelease]; }
+ (instancetype)dictionaryWithObjects:(NSArray *)objects forKeys:(NSArray *)keys
{
    return [[[self alloc] initWithObjects:objects forKeys:keys] autorelease];
}

/* Arguments alternate object, key, ... (nil-terminated). */
+ (instancetype)dictionaryWithObjectsAndKeys:(id)first, ...
{
    id result;
    COLLECT_VARARGS(first, args, n, {
        NSUInteger pairs = n / 2;
        id *objects = malloc((pairs + 1) * sizeof(id)), *keys = malloc((pairs + 1) * sizeof(id));
        for (NSUInteger i = 0; i < pairs; i++) { objects[i] = args[2 * i]; keys[i] = args[2 * i + 1]; }
        result = [self dictionaryWithObjects:objects forKeys:keys count:pairs];
        free(objects); free(keys);
    });
    return result;
}

- (instancetype)initWithObjectsAndKeys:(id)first, ...
{
    id result;
    COLLECT_VARARGS(first, args, n, {
        NSUInteger pairs = n / 2;
        id *objects = malloc((pairs + 1) * sizeof(id)), *keys = malloc((pairs + 1) * sizeof(id));
        for (NSUInteger i = 0; i < pairs; i++) { objects[i] = args[2 * i]; keys[i] = args[2 * i + 1]; }
        result = [self initWithObjects:objects forKeys:keys count:pairs];
        free(objects); free(keys);
    });
    return result;
}

- (instancetype)init { return [super init]; }
- (instancetype)initWithObjects:(const id *)objects forKeys:(const id *)keys count:(NSUInteger)count { return [self init]; }

- (instancetype)initWithDictionary:(NSDictionary *)dict { return [self initWithDictionary:dict copyItems:NO]; }

- (instancetype)initWithDictionary:(NSDictionary *)dict copyItems:(BOOL)copy
{
    NSUInteger n = [dict count];
    id *objects = malloc((n + 1) * sizeof(id)), *keys = malloc((n + 1) * sizeof(id));
    [dict getObjects:objects andKeys:keys count:n];
    if (copy)
        for (NSUInteger i = 0; i < n; i++) objects[i] = [objects[i] copyWithZone:NULL];
    id result = [self initWithObjects:objects forKeys:keys count:n];
    if (copy)
        for (NSUInteger i = 0; i < n; i++) [objects[i] release];
    free(objects);
    free(keys);
    return result;
}

- (instancetype)initWithObjects:(NSArray *)objects forKeys:(NSArray *)keys
{
    NSUInteger n = [objects count];
    if ([keys count] != n)
        __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": count of objects (%lu) differs from count of keys (%lu)",
            FINCH_METHOD_ARGS, (unsigned long)n, (unsigned long)[keys count]);
    id *o = malloc((n + 1) * sizeof(id)), *k = malloc((n + 1) * sizeof(id));
    [objects getObjects:o range:NSMakeRange(0, n)];
    [keys getObjects:k range:NSMakeRange(0, n)];
    id result = [self initWithObjects:o forKeys:k count:n];
    free(o);
    free(k);
    return result;
}

#define ABSTRACT(sig, name) \
    sig { __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s " name "]!", \
        FINCH_METHOD_ARGS, object_getClassName(self)); }
ABSTRACT(- (NSUInteger)count, "count")
ABSTRACT(- (id)objectForKey:(id)key, "objectForKey:")
ABSTRACT(- (id)keyEnumerator, "keyEnumerator")
#undef ABSTRACT

- (id)objectForKeyedSubscript:(id)key { return [self objectForKey:key]; }

- (void)getObjects:(id *)objects andKeys:(id *)keys count:(NSUInteger)count
{
    NSUInteger i = 0;
    for (id k in self) {
        if (i == count) break;
        if (keys) keys[i] = k;
        if (objects) objects[i] = [self objectForKey:k];
        i++;
    }
}

- (void)getObjects:(id *)objects andKeys:(id *)keys { [self getObjects:objects andKeys:keys count:[self count]]; }

- (NSArray *)allKeys
{
    NSUInteger n = [self count];
    id *keys = malloc((n + 1) * sizeof(id));
    [self getObjects:NULL andKeys:keys count:n];
    NSArray *result = [NSArray arrayWithObjects:keys count:n];
    free(keys);
    return result;
}

- (NSArray *)allValues
{
    NSUInteger n = [self count];
    id *objects = malloc((n + 1) * sizeof(id));
    [self getObjects:objects andKeys:NULL count:n];
    NSArray *result = [NSArray arrayWithObjects:objects count:n];
    free(objects);
    return result;
}

- (NSArray *)allKeysForObject:(id)object
{
    NSMutableArray *result = [NSMutableArray array];
    for (id k in self) {
        id v = [self objectForKey:k];
        if (v == object || [v isEqual:object]) [result addObject:k];
    }
    return result;
}

- (id)objectEnumerator
{
    return [[[__NSFastEnumerationEnumerator alloc] _initWithCollection:[self allValues] reverse:NO] autorelease];
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    /* Keys, from -keyEnumerator: the enumerator rides in extra[0]. */
    static unsigned long never_mutated;
    if (state->state == 0) {
        state->state = 1;
        state->extra[0] = (unsigned long)[self keyEnumerator];
        state->mutationsPtr = &never_mutated;
    }
    NSEnumerator *e = (NSEnumerator *)state->extra[0];
    NSUInteger n = 0;
    for (id k; n < len && (k = [e nextObject]);) buffer[n++] = k;
    state->itemsPtr = buffer;
    return n;
}

- (BOOL)isEqualToDictionary:(NSDictionary *)other
{
    if (other == self) return YES;
    if ([other count] != [self count]) return NO;
    for (id k in self) {
        id a = [self objectForKey:k], b = [other objectForKey:k];
        if (!b || (a != b && ![a isEqual:b])) return NO;
    }
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    return other && [other isKindOfClass:[NSDictionary class]] && [self isEqualToDictionary:other];
}

- (NSUInteger)hash { return [self count]; }

- (id)copyWithZone:(struct _NSZone *)zone { return [[NSDictionary alloc] initWithDictionary:self]; }
- (id)mutableCopyWithZone:(struct _NSZone *)zone { return [[NSMutableDictionary alloc] initWithDictionary:self]; }

- (void)enumerateKeysAndObjectsUsingBlock:(void (^)(id, id, BOOL *))block
{
    [self enumerateKeysAndObjectsWithOptions:0 usingBlock:block];
}

- (void)enumerateKeysAndObjectsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (^)(id, id, BOOL *))block
{
    BOOL stop = NO;
    for (id k in [self allKeys]) {
        block(k, [self objectForKey:k], &stop);
        if (stop) break;
    }
}

/* What CF sends (CFDictionary.c) to dictionaries it didn't make. */
- (BOOL)__getValue:(id *)value forKey:(id)key
{
    id v = [self objectForKey:key];
    if (v && value) *value = v;
    return v != nil;
}
- (NSUInteger)countForKey:(id)key { return [self objectForKey:key] ? 1 : 0; }
- (BOOL)containsKey:(id)key { return [self objectForKey:key] != nil; }
- (NSUInteger)countForObject:(id)object
{
    NSUInteger n = 0;
    for (id k in self) {
        id v = [self objectForKey:k];
        n += v == object || [v isEqual:object];
    }
    return n;
}
- (BOOL)containsObject:(id)object { return [self countForObject:object] != 0; }

- (CFTypeID)_cfTypeID { return CFDictionaryGetTypeID(); }
- (BOOL)isNSDictionary__ { return YES; }

@end

/* MARK: - NSMutableDictionary */

@implementation NSMutableDictionary

+ (instancetype)dictionaryWithCapacity:(NSUInteger)capacity { return [[[self alloc] initWithCapacity:capacity] autorelease]; }
- (instancetype)initWithCapacity:(NSUInteger)capacity { return [self init]; }

#define ABSTRACT(sig, name) \
    sig { __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s " name "]!", \
        FINCH_METHOD_ARGS, object_getClassName(self)); }
ABSTRACT(- (void)setObject:(id)object forKey:(id)key, "setObject:forKey:")
ABSTRACT(- (void)removeObjectForKey:(id)key, "removeObjectForKey:")
#undef ABSTRACT

- (void)setObject:(id)object forKeyedSubscript:(id)key
{
    if (object) [self setObject:object forKey:key];
    else [self removeObjectForKey:key];
}

- (void)addEntriesFromDictionary:(NSDictionary *)dict
{
    for (id k in dict) [self setObject:[dict objectForKey:k] forKey:k];
}

- (void)removeAllObjects
{
    for (id k in [self allKeys]) [self removeObjectForKey:k];
}

- (void)removeObjectsForKeys:(NSArray *)keys
{
    for (id k in keys) [self removeObjectForKey:k];
}

- (void)setDictionary:(NSDictionary *)dict
{
    if (dict == self) return;
    [dict retain];
    [self removeAllObjects];
    [self addEntriesFromDictionary:dict];
    [dict release];
}

- (id)copyWithZone:(struct _NSZone *)zone { return [[NSDictionary alloc] initWithDictionary:self]; }

/* What CF sends to mutable dictionaries it didn't make. */
- (void)__addObject:(id)object forKey:(id)key { if (![self objectForKey:key]) [self setObject:object forKey:key]; }
- (void)__setObject:(id)object forKey:(id)key { [self setObject:object forKey:key]; }
- (void)replaceObject:(id)object forKey:(id)key { if ([self objectForKey:key]) [self setObject:object forKey:key]; }

@end

/* MARK: - __NSPlaceholderDictionary */

@implementation __NSPlaceholderDictionary

FINCH_IMMORTAL_MEMORY

- (instancetype)init { return [self initWithObjects:NULL forKeys:NULL count:0]; }
- (instancetype)initWithCapacity:(NSUInteger)capacity
{
    return (id)CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

- (instancetype)initWithObjects:(const id *)objects forKeys:(const id *)keys count:(NSUInteger)count
{
    for (NSUInteger i = 0; i < count; i++) {
        if (!objects[i])
            __CFFinchRaise(NSInvalidArgumentException,
                "*** " FINCH_METHOD_FMT ": attempt to insert nil object from objects[%lu]", FINCH_METHOD_ARGS, (unsigned long)i);
        if (!keys[i])
            __CFFinchRaise(NSInvalidArgumentException,
                "*** " FINCH_METHOD_FMT ": attempt to insert nil key from keys[%lu]", FINCH_METHOD_ARGS, (unsigned long)i);
    }
    id stackbuf[16], *copies = count <= 16 ? stackbuf : malloc(count * sizeof(id));
    for (NSUInteger i = 0; i < count; i++) copies[i] = copy_key(keys[i]);
    CFTypeRef d;
    if (self == mutablePlaceholder) {
        CFMutableDictionaryRef m = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        for (NSUInteger i = 0; i < count; i++) CFDictionarySetValue(m, copies[i], objects[i]);
        d = m;
    } else {
        d = CFDictionaryCreate(NULL, (const void **)copies, (const void **)objects, (CFIndex)count,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    for (NSUInteger i = 0; i < count; i++) [copies[i] release];
    if (copies != stackbuf) free(copies);
    return (id)d;
}

- (NSUInteger)count { return 0; }

@end

/* MARK: - __NSCFDictionary */

@implementation __NSCFDictionary

FINCH_CF_OBJECT_MEMORY

/* Instances are CF objects: [[obj class] alloc] goes through the placeholder. */
+ (instancetype)allocWithZone:(struct _NSZone *)zone { return (id)mutablePlaceholder; }

- (NSUInteger)count { return (NSUInteger)CFDictionaryGetCount((CFDictionaryRef)self); }

- (id)objectForKey:(id)key
{
    return key ? (id)CFDictionaryGetValue((CFDictionaryRef)self, key) : nil;
}

- (id)objectForKeyedSubscript:(id)key
{
    return key ? (id)CFDictionaryGetValue((CFDictionaryRef)self, key) : nil;
}

- (void)getObjects:(id *)objects andKeys:(id *)keys count:(NSUInteger)count
{
    NSUInteger n = (NSUInteger)CFDictionaryGetCount((CFDictionaryRef)self);
    if (count >= n) {
        CFDictionaryGetKeysAndValues((CFDictionaryRef)self, (const void **)keys, (const void **)objects);
        return;
    }
    id *k = malloc(n * sizeof(id)), *v = malloc(n * sizeof(id));
    CFDictionaryGetKeysAndValues((CFDictionaryRef)self, (const void **)k, (const void **)v);
    if (keys) memcpy(keys, k, count * sizeof(id));
    if (objects) memcpy(objects, v, count * sizeof(id));
    free(k);
    free(v);
}

- (id)keyEnumerator
{
    return [[[__NSFastEnumerationEnumerator alloc] _initWithCollection:self reverse:NO] autorelease];
}

/* Keys, from a snapshot taken on the first call: a CFData of key pointers
 * kept alive by the autorelease pool, which outlives the loop. */
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    if (state->state == 0) {
        CFIndex n = CFDictionaryGetCount((CFDictionaryRef)self);
        CFMutableDataRef keys = CFDataCreateMutable(NULL, 0);
        CFDataSetLength(keys, n * (CFIndex)sizeof(id));
        CFDictionaryGetKeysAndValues((CFDictionaryRef)self, (const void **)CFDataGetMutableBytePtr(keys), NULL);
        [(id)keys autorelease];
        state->extra[0] = (unsigned long)n;
        state->extra[1] = (unsigned long)CFDataGetBytePtr(keys);
        state->extra[2] = 0;
        state->mutationsPtr = &state->extra[0];
        state->state = 1;
    }
    NSUInteger n = state->extra[0], i = state->extra[2];
    if (i >= n) return 0;
    if (len > n - i) len = n - i;
    state->itemsPtr = (id *)state->extra[1] + i;
    state->extra[2] = i + len;
    return len;
}

- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }

static BOOL
is_mutable(id self)
{
    return CFBasicHashIsMutable((CFBasicHashRef)self);
}

- (id)copyWithZone:(struct _NSZone *)zone
{
    if (!is_mutable(self)) return [self retain];
    return (id)CFDictionaryCreateCopy(NULL, (CFDictionaryRef)self);
}

- (id)mutableCopyWithZone:(struct _NSZone *)zone
{
    return (id)CFDictionaryCreateMutableCopy(NULL, 0, (CFDictionaryRef)self);
}

static void
check_mutable(id self, SEL _cmd)
{
    if (!is_mutable(self))
        __CFFinchRaise(NSInternalInconsistencyException, FINCH_METHOD_FMT ": mutating method sent to immutable object",
            FINCH_METHOD_ARGS);
}

- (void)setObject:(id)object forKey:(id)key
{
    check_mutable(self, _cmd);
    if (!key)
        __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": key cannot be nil", FINCH_METHOD_ARGS);
    if (!object)
        __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": object cannot be nil (key: %@)", FINCH_METHOD_ARGS, key);
    id k = copy_key(key);
    CFDictionarySetValue((CFMutableDictionaryRef)self, k, object);
    [k release];
}

- (void)removeObjectForKey:(id)key
{
    check_mutable(self, _cmd);
    if (!key)
        __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": key cannot be nil", FINCH_METHOD_ARGS);
    CFDictionaryRemoveValue((CFMutableDictionaryRef)self, key);
}

- (void)removeAllObjects
{
    check_mutable(self, _cmd);
    CFDictionaryRemoveAllValues((CFMutableDictionaryRef)self);
}

@end
