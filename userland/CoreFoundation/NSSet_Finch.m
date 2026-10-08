/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSSet and NSMutableSet, which Apple's CoreFoundation hosts
 * (docs/design/FOUNDATION.md), with __NSCFSet, the class of every CFSet.
 * The pattern of NSArray_Finch.m: primitives (-count, -member:,
 * -objectEnumerator; -addObject:, -removeObject:), a placeholder from
 * +alloc, and CFSets as the concrete objects.
 */
#include "CFObjCClasses_Finch.h"
#include "CFBasicHash.h"

@interface NSEnumerator : NSObject
- (id)nextObject;
@end
@interface __NSFastEnumerationEnumerator : NSEnumerator
- (instancetype)_initWithCollection:(id)collection reverse:(BOOL)reverse;
@end
@interface NSArray (FinchSet)
+ (instancetype)arrayWithObjects:(const id *)objects count:(NSUInteger)count;
@end

@interface NSSet () <NSCopying, NSMutableCopying, NSFastEnumeration>
+ (instancetype)set;
+ (instancetype)setWithObject:(id)object;
+ (instancetype)setWithObjects:(const id *)objects count:(NSUInteger)count;
+ (instancetype)setWithObjects:(id)first, ...;
+ (instancetype)setWithArray:(NSArray *)array;
+ (instancetype)setWithSet:(NSSet *)set;
- (instancetype)init;
- (instancetype)initWithObjects:(const id *)objects count:(NSUInteger)count;
- (instancetype)initWithObjects:(id)first, ...;
- (instancetype)initWithArray:(NSArray *)array;
- (instancetype)initWithSet:(NSSet *)set;
- (instancetype)initWithSet:(NSSet *)set copyItems:(BOOL)copy;
- (id)objectEnumerator;
- (NSArray *)allObjects;
- (id)anyObject;
- (BOOL)isEqualToSet:(NSSet *)other;
- (BOOL)isSubsetOfSet:(NSSet *)other;
- (BOOL)intersectsSet:(NSSet *)other;
- (NSSet *)setByAddingObject:(id)object;
- (NSSet *)setByAddingObjectsFromSet:(NSSet *)other;
- (NSSet *)setByAddingObjectsFromArray:(NSArray *)other;
- (void)makeObjectsPerformSelector:(SEL)sel;
- (void)enumerateObjectsUsingBlock:(void (^)(id obj, BOOL *stop))block;
@end

@interface NSMutableSet ()
+ (instancetype)setWithCapacity:(NSUInteger)capacity;
- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (void)addObjectsFromArray:(NSArray *)array;
- (void)unionSet:(NSSet *)other;
- (void)minusSet:(NSSet *)other;
- (void)intersectSet:(NSSet *)other;
- (void)setSet:(NSSet *)other;
@end

@interface __NSPlaceholderSet : NSMutableSet
@end
@interface __NSCFSet : NSMutableSet
@end

static __NSPlaceholderSet *immutablePlaceholder, *mutablePlaceholder;

CF_PRIVATE Class
__CFFinchInitializeSetClasses(void)
{
    immutablePlaceholder = class_createInstance([__NSPlaceholderSet class], 0);
    mutablePlaceholder = class_createInstance([__NSPlaceholderSet class], 0);
    return [__NSCFSet class];
}

/* MARK: - NSSet */

@implementation NSSet

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSSet class]) return (id)immutablePlaceholder;
    if (self == [NSMutableSet class]) return (id)mutablePlaceholder;
    return [super allocWithZone:zone];
}

+ (instancetype)set { return [[[self alloc] init] autorelease]; }
+ (instancetype)setWithObject:(id)object { return [[[self alloc] initWithObjects:&object count:1] autorelease]; }
+ (instancetype)setWithObjects:(const id *)objects count:(NSUInteger)count
{
    return [[[self alloc] initWithObjects:objects count:count] autorelease];
}
+ (instancetype)setWithArray:(NSArray *)array { return [[[self alloc] initWithArray:array] autorelease]; }
+ (instancetype)setWithSet:(NSSet *)set { return [[[self alloc] initWithSet:set] autorelease]; }

+ (instancetype)setWithObjects:(id)first, ...
{
    id result;
    COLLECT_VARARGS(first, objects, count, result = [self setWithObjects:objects count:count]);
    return result;
}

- (instancetype)initWithObjects:(id)first, ...
{
    id result;
    COLLECT_VARARGS(first, objects, count, result = [self initWithObjects:objects count:count]);
    return result;
}

- (instancetype)init { return [super init]; }
- (instancetype)initWithObjects:(const id *)objects count:(NSUInteger)count { return [self init]; }

- (instancetype)initWithArray:(NSArray *)array
{
    NSUInteger n = [array count];
    id *objects = malloc((n + 1) * sizeof(id));
    [array getObjects:objects range:NSMakeRange(0, n)];
    id result = [self initWithObjects:objects count:n];
    free(objects);
    return result;
}

- (instancetype)initWithSet:(NSSet *)set { return [self initWithSet:set copyItems:NO]; }

- (instancetype)initWithSet:(NSSet *)set copyItems:(BOOL)copy
{
    NSUInteger n = [set count], i = 0;
    id *objects = malloc((n + 1) * sizeof(id));
    for (id o in set) {
        if (i == n) break;
        objects[i++] = copy ? [o copyWithZone:NULL] : o;
    }
    id result = [self initWithObjects:objects count:i];
    if (copy)
        for (NSUInteger j = 0; j < i; j++) [objects[j] release];
    free(objects);
    return result;
}

#define ABSTRACT(sig, name) \
    sig { __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s " name "]!", \
        FINCH_METHOD_ARGS, object_getClassName(self)); }
ABSTRACT(- (NSUInteger)count, "count")
ABSTRACT(- (id)member:(id)object, "member:")
ABSTRACT(- (id)objectEnumerator, "objectEnumerator")
#undef ABSTRACT

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    static unsigned long never_mutated;
    if (state->state == 0) {
        state->state = 1;
        state->extra[0] = (unsigned long)[self objectEnumerator];
        state->mutationsPtr = &never_mutated;
    }
    NSEnumerator *e = (NSEnumerator *)state->extra[0];
    NSUInteger n = 0;
    for (id o; n < len && (o = [e nextObject]);) buffer[n++] = o;
    state->itemsPtr = buffer;
    return n;
}

- (void)getObjects:(id *)objects
{
    NSUInteger i = 0;
    for (id o in self) objects[i++] = o;
}

- (NSArray *)allObjects
{
    NSUInteger n = [self count];
    id *objects = malloc((n + 1) * sizeof(id));
    [self getObjects:objects];
    NSArray *result = [NSArray arrayWithObjects:objects count:n];
    free(objects);
    return result;
}

- (id)anyObject
{
    for (id o in self) return o;
    return nil;
}

- (BOOL)containsObject:(id)object { return object && [self member:object] != nil; }

- (BOOL)isSubsetOfSet:(NSSet *)other
{
    for (id o in self)
        if (![other member:o]) return NO;
    return YES;
}

- (BOOL)intersectsSet:(NSSet *)other
{
    for (id o in self)
        if ([other member:o]) return YES;
    return NO;
}

- (BOOL)isEqualToSet:(NSSet *)other
{
    return other == self || ([other count] == [self count] && [self isSubsetOfSet:other]);
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    return other && [other isKindOfClass:[NSSet class]] && [self isEqualToSet:other];
}

- (NSUInteger)hash { return [self count]; }

- (id)copyWithZone:(struct _NSZone *)zone { return [[NSSet alloc] initWithSet:self]; }
- (id)mutableCopyWithZone:(struct _NSZone *)zone { return [[NSMutableSet alloc] initWithSet:self]; }

- (NSSet *)setByAddingObject:(id)object
{
    NSMutableSet *m = [[NSMutableSet alloc] initWithSet:self];
    [m addObject:object];
    NSSet *result = [NSSet setWithSet:m];
    [m release];
    return result;
}

- (NSSet *)setByAddingObjectsFromSet:(NSSet *)other
{
    NSMutableSet *m = [[NSMutableSet alloc] initWithSet:self];
    [m unionSet:other];
    NSSet *result = [NSSet setWithSet:m];
    [m release];
    return result;
}

- (NSSet *)setByAddingObjectsFromArray:(NSArray *)other
{
    NSMutableSet *m = [[NSMutableSet alloc] initWithSet:self];
    [m addObjectsFromArray:other];
    NSSet *result = [NSSet setWithSet:m];
    [m release];
    return result;
}

- (void)makeObjectsPerformSelector:(SEL)sel
{
    for (id o in [self allObjects]) ((void (*)(id, SEL))objc_msgSend)(o, sel);
}

- (void)enumerateObjectsUsingBlock:(void (^)(id, BOOL *))block
{
    BOOL stop = NO;
    for (id o in [self allObjects]) {
        block(o, &stop);
        if (stop) break;
    }
}

/* What CF sends (CFSet.c) to sets it didn't make. */
- (BOOL)__getValue:(id *)value forObj:(id)object
{
    id v = [self member:object];
    if (v && value) *value = v;
    return v != nil;
}
- (NSUInteger)countForObject:(id)object { return [self member:object] ? 1 : 0; }

- (CFTypeID)_cfTypeID { return CFSetGetTypeID(); }
- (BOOL)isNSSet__ { return YES; }

@end

/* MARK: - NSMutableSet */

@implementation NSMutableSet

+ (instancetype)setWithCapacity:(NSUInteger)capacity { return [[[self alloc] initWithCapacity:capacity] autorelease]; }
- (instancetype)initWithCapacity:(NSUInteger)capacity { return [self init]; }

#define ABSTRACT(sig, name) \
    sig { __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s " name "]!", \
        FINCH_METHOD_ARGS, object_getClassName(self)); }
ABSTRACT(- (void)addObject:(id)object, "addObject:")
ABSTRACT(- (void)removeObject:(id)object, "removeObject:")
#undef ABSTRACT

- (void)addObjectsFromArray:(NSArray *)array { for (id o in array) [self addObject:o]; }
- (void)unionSet:(NSSet *)other { for (id o in other) [self addObject:o]; }
- (void)minusSet:(NSSet *)other { for (id o in other) [self removeObject:o]; }

- (void)intersectSet:(NSSet *)other
{
    for (id o in [self allObjects])
        if (![other member:o]) [self removeObject:o];
}

- (void)removeAllObjects { for (id o in [self allObjects]) [self removeObject:o]; }

- (void)setSet:(NSSet *)other
{
    if (other == self) return;
    [other retain];
    [self removeAllObjects];
    [self unionSet:other];
    [other release];
}

- (id)copyWithZone:(struct _NSZone *)zone { return [[NSSet alloc] initWithSet:self]; }

/* What CF sends to mutable sets it didn't make. */
- (void)replaceObject:(id)object { if ([self member:object]) { [self removeObject:object]; [self addObject:object]; } }
- (void)setObject:(id)object { [self removeObject:object]; [self addObject:object]; }

@end

/* MARK: - __NSPlaceholderSet */

@implementation __NSPlaceholderSet

FINCH_IMMORTAL_MEMORY

- (instancetype)init { return [self initWithObjects:NULL count:0]; }
- (instancetype)initWithCapacity:(NSUInteger)capacity
{
    return (id)CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
}

- (instancetype)initWithObjects:(const id *)objects count:(NSUInteger)count
{
    for (NSUInteger i = 0; i < count; i++)
        if (!objects[i])
            __CFFinchRaise(NSInvalidArgumentException,
                "*** " FINCH_METHOD_FMT ": attempt to insert nil object from objects[%lu]", FINCH_METHOD_ARGS, (unsigned long)i);
    if (self != mutablePlaceholder)
        return (id)CFSetCreate(NULL, (const void **)objects, (CFIndex)count, &kCFTypeSetCallBacks);
    CFMutableSetRef m = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    for (NSUInteger i = 0; i < count; i++) CFSetAddValue(m, objects[i]);
    return (id)m;
}

- (NSUInteger)count { return 0; }

@end

/* MARK: - __NSCFSet */

@implementation __NSCFSet

FINCH_CF_OBJECT_MEMORY

/* Instances are CF objects: [[obj class] alloc] goes through the placeholder. */
+ (instancetype)allocWithZone:(struct _NSZone *)zone { return (id)mutablePlaceholder; }

- (NSUInteger)count { return (NSUInteger)CFSetGetCount((CFSetRef)self); }
- (id)member:(id)object { return object ? (id)CFSetGetValue((CFSetRef)self, object) : nil; }
- (BOOL)containsObject:(id)object { return object && CFSetContainsValue((CFSetRef)self, object); }
- (void)getObjects:(id *)objects { CFSetGetValues((CFSetRef)self, (const void **)objects); }

- (id)objectEnumerator
{
    return [[[__NSFastEnumerationEnumerator alloc] _initWithCollection:self reverse:NO] autorelease];
}

/* A snapshot of the values, as __NSCFDictionary's keys. */
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    if (state->state == 0) {
        CFIndex n = CFSetGetCount((CFSetRef)self);
        CFMutableDataRef values = CFDataCreateMutable(NULL, 0);
        CFDataSetLength(values, n * (CFIndex)sizeof(id));
        CFSetGetValues((CFSetRef)self, (const void **)CFDataGetMutableBytePtr(values));
        [(id)values autorelease];
        state->extra[0] = (unsigned long)n;
        state->extra[1] = (unsigned long)CFDataGetBytePtr(values);
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

static BOOL is_mutable(id self) { return CFBasicHashIsMutable((CFBasicHashRef)self); }

- (id)copyWithZone:(struct _NSZone *)zone
{
    if (!is_mutable(self)) return [self retain];
    return (id)CFSetCreateCopy(NULL, (CFSetRef)self);
}

- (id)mutableCopyWithZone:(struct _NSZone *)zone { return (id)CFSetCreateMutableCopy(NULL, 0, (CFSetRef)self); }

static void
check(id self, SEL _cmd, id object)
{
    if (!is_mutable(self))
        __CFFinchRaise(NSInternalInconsistencyException, FINCH_METHOD_FMT ": mutating method sent to immutable object",
            FINCH_METHOD_ARGS);
    if (!object && (sel_isEqual(_cmd, @selector(addObject:)) || sel_isEqual(_cmd, @selector(removeObject:))))
        __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": object cannot be nil", FINCH_METHOD_ARGS);
}

- (void)addObject:(id)object { check(self, _cmd, object); CFSetAddValue((CFMutableSetRef)self, object); }
- (void)removeObject:(id)object { check(self, _cmd, object); CFSetRemoveValue((CFMutableSetRef)self, object); }
- (void)removeAllObjects { check(self, _cmd, self); CFSetRemoveAllValues((CFMutableSetRef)self); }

@end
