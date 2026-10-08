/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSArray and NSMutableArray, which Apple's CoreFoundation hosts
 * (docs/design/FOUNDATION.md), with their concrete class __NSCFArray: the
 * class of every CFArray, so an array made either way is both.
 *
 *   NSArray          abstract: -count and -objectAtIndex: are primitive,
 *                    everything else is built on them (for subclasses)
 *   NSMutableArray   abstract: adds the mutating primitives
 *   __NSPlaceholderArray   what +alloc returns; -init... makes a CFArray
 *   __NSCFArray      CFArray as an NSMutableArray (mutating an immutable one
 *                    raises, as Apple's does)
 *
 * Foundation adds its categories (sorting, KVC, property lists, description).
 */
#include "CFObjCClasses_Finch.h"
#include "CFArray.h"

/* CFArray's own (CFArray.c): whether it was made mutable. */
CF_PRIVATE Boolean _CFArrayIsMutable(CFArrayRef array);

@interface NSArray () <NSCopying, NSMutableCopying, NSFastEnumeration>
+ (instancetype)array;
+ (instancetype)arrayWithObject:(id)object;
+ (instancetype)arrayWithObjects:(const id *)objects count:(NSUInteger)count;
+ (instancetype)arrayWithObjects:(id)first, ...;
+ (instancetype)arrayWithArray:(NSArray *)array;
- (instancetype)init;
- (instancetype)initWithObjects:(const id *)objects count:(NSUInteger)count;
- (instancetype)initWithObjects:(id)first, ...;
- (instancetype)initWithArray:(NSArray *)array;
- (instancetype)initWithArray:(NSArray *)array copyItems:(BOOL)copy;
- (id)objectAtIndexedSubscript:(NSUInteger)idx;
- (id)firstObject;
- (id)lastObject;
- (BOOL)containsObject:(id)object;
- (NSUInteger)indexOfObject:(id)object;
- (NSUInteger)indexOfObjectIdenticalTo:(id)object;
- (BOOL)isEqualToArray:(NSArray *)other;
- (NSArray *)arrayByAddingObject:(id)object;
- (NSArray *)arrayByAddingObjectsFromArray:(NSArray *)other;
- (NSArray *)subarrayWithRange:(NSRange)range;
- (id)objectEnumerator;
- (id)reverseObjectEnumerator;
- (void)makeObjectsPerformSelector:(SEL)sel;
- (void)makeObjectsPerformSelector:(SEL)sel withObject:(id)arg;
- (void)enumerateObjectsUsingBlock:(void (^)(id obj, NSUInteger idx, BOOL *stop))block;
- (void)enumerateObjectsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (^)(id obj, NSUInteger idx, BOOL *stop))block;
- (NSUInteger)indexOfObjectPassingTest:(BOOL (^)(id obj, NSUInteger idx, BOOL *stop))predicate;
@end

@interface NSMutableArray ()
+ (instancetype)arrayWithCapacity:(NSUInteger)capacity;
- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (void)removeLastObject;
- (void)replaceObjectAtIndex:(NSUInteger)idx withObject:(id)object;
- (void)setObject:(id)object atIndexedSubscript:(NSUInteger)idx;
- (void)addObjectsFromArray:(NSArray *)array;
- (void)removeObject:(id)object;
- (void)removeObjectIdenticalTo:(id)object;
- (void)removeObjectsInRange:(NSRange)range;
- (void)setArray:(NSArray *)array;
@end

@interface __NSPlaceholderArray : NSMutableArray
@end
@interface __NSCFArray : NSMutableArray
@end
@interface NSEnumerator : NSObject <NSFastEnumeration>
- (id)nextObject;
- (NSArray *)allObjects;
@end
@interface __NSFastEnumerationEnumerator : NSEnumerator
- (instancetype)_initWithCollection:(id)collection reverse:(BOOL)reverse;
@end

static __NSPlaceholderArray *immutablePlaceholder, *mutablePlaceholder;

/* From __CFFinchInitializeObjC (CFObjC.m): CFArray's class, and the placeholders. */
CF_PRIVATE Class
__CFFinchInitializeArrayClasses(void)
{
    immutablePlaceholder = class_createInstance([__NSPlaceholderArray class], 0);
    mutablePlaceholder = class_createInstance([__NSPlaceholderArray class], 0);
    return [__NSCFArray class];
}

static void
check_index(id self, SEL _cmd, NSUInteger idx, NSUInteger count)
{
    if (idx >= count) {
        if (count == 0)
            __CFFinchRaise(NSRangeException, "*** " FINCH_METHOD_FMT ": index %lu beyond bounds for empty array",
                FINCH_METHOD_ARGS, (unsigned long)idx);
        __CFFinchRaise(NSRangeException, "*** " FINCH_METHOD_FMT ": index %lu beyond bounds [0 .. %lu]",
            FINCH_METHOD_ARGS, (unsigned long)idx, (unsigned long)count - 1);
    }
}

static void
check_object(id self, SEL _cmd, id object)
{
    if (!object)
        __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": object cannot be nil", FINCH_METHOD_ARGS);
}

/* MARK: - NSArray */

@implementation NSArray

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSArray class]) return (id)immutablePlaceholder;
    if (self == [NSMutableArray class]) return (id)mutablePlaceholder;
    return [super allocWithZone:zone];
}

+ (instancetype)array { return [[[self alloc] init] autorelease]; }
+ (instancetype)arrayWithObject:(id)object { return [[[self alloc] initWithObjects:&object count:1] autorelease]; }
+ (instancetype)arrayWithObjects:(const id *)objects count:(NSUInteger)count
{
    return [[[self alloc] initWithObjects:objects count:count] autorelease];
}
+ (instancetype)arrayWithArray:(NSArray *)array { return [[[self alloc] initWithArray:array] autorelease]; }


+ (instancetype)arrayWithObjects:(id)first, ...
{
    id result;
    COLLECT_VARARGS(first, objects, count, result = [self arrayWithObjects:objects count:count]);
    return result;
}

- (instancetype)initWithObjects:(id)first, ...
{
    id result;
    COLLECT_VARARGS(first, objects, count, result = [self initWithObjects:objects count:count]);
    return result;
}

- (instancetype)init { return [super init]; }

/* For subclasses: the abstract class stores nothing. */
- (instancetype)initWithObjects:(const id *)objects count:(NSUInteger)count { return [self init]; }

- (instancetype)initWithArray:(NSArray *)array { return [self initWithArray:array copyItems:NO]; }

- (instancetype)initWithArray:(NSArray *)array copyItems:(BOOL)copy
{
    NSUInteger n = [array count];
    id stackbuf[16], *objects = n <= 16 ? stackbuf : malloc(n * sizeof(id));
    [array getObjects:objects range:NSMakeRange(0, n)];
    if (copy)
        for (NSUInteger i = 0; i < n; i++) objects[i] = [objects[i] copyWithZone:NULL];
    id result = [self initWithObjects:objects count:n];
    if (copy)
        for (NSUInteger i = 0; i < n; i++) [objects[i] release];
    if (objects != stackbuf) free(objects);
    return result;
}

- (NSUInteger)count
{
    __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s count]!",
        FINCH_METHOD_ARGS, object_getClassName(self));
}

- (id)objectAtIndex:(NSUInteger)idx
{
    __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s objectAtIndex:]!",
        FINCH_METHOD_ARGS, object_getClassName(self));
}

- (id)objectAtIndexedSubscript:(NSUInteger)idx { return [self objectAtIndex:idx]; }
- (id)firstObject { return [self count] ? [self objectAtIndex:0] : nil; }
- (id)lastObject { NSUInteger n = [self count]; return n ? [self objectAtIndex:n - 1] : nil; }

- (void)getObjects:(id *)objects range:(NSRange)range
{
    NSUInteger n = [self count];
    if (range.location > n || range.length > n - range.location)
        __CFFinchRaise(NSRangeException, "*** " FINCH_METHOD_FMT ": range {%lu, %lu} extends beyond bounds [0 .. %lu]",
            FINCH_METHOD_ARGS, (unsigned long)range.location, (unsigned long)range.length, (unsigned long)(n ? n - 1 : 0));
    for (NSUInteger i = 0; i < range.length; i++) objects[i] = [self objectAtIndex:range.location + i];
}

- (NSUInteger)indexOfObject:(id)object
{
    NSUInteger n = [self count];
    for (NSUInteger i = 0; i < n; i++) {
        id o = [self objectAtIndex:i];
        if (o == object || [o isEqual:object]) return i;
    }
    return NSNotFound;
}

- (NSUInteger)indexOfObjectIdenticalTo:(id)object
{
    NSUInteger n = [self count];
    for (NSUInteger i = 0; i < n; i++)
        if ([self objectAtIndex:i] == object) return i;
    return NSNotFound;
}

- (BOOL)containsObject:(id)object { return [self indexOfObject:object] != NSNotFound; }

- (BOOL)isEqualToArray:(NSArray *)other
{
    if (other == self) return YES;
    NSUInteger n = [self count];
    if ([other count] != n) return NO;
    for (NSUInteger i = 0; i < n; i++) {
        id a = [self objectAtIndex:i], b = [other objectAtIndex:i];
        if (a != b && ![a isEqual:b]) return NO;
    }
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    return other && [other isKindOfClass:[NSArray class]] && [self isEqualToArray:other];
}

- (NSUInteger)hash { return [self count]; }

- (id)copyWithZone:(struct _NSZone *)zone { return [[NSArray alloc] initWithArray:self]; }
- (id)mutableCopyWithZone:(struct _NSZone *)zone { return [[NSMutableArray alloc] initWithArray:self]; }

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    static unsigned long never_mutated;
    NSUInteger n = [self count], i = state->state;
    if (i >= n) return 0;
    if (len > n - i) len = n - i;
    [self getObjects:buffer range:NSMakeRange(i, len)];
    state->state = i + len;
    state->itemsPtr = buffer;
    state->mutationsPtr = &never_mutated;
    return len;
}

- (id)objectEnumerator
{
    return [[[__NSFastEnumerationEnumerator alloc] _initWithCollection:self reverse:NO] autorelease];
}

- (id)reverseObjectEnumerator
{
    return [[[__NSFastEnumerationEnumerator alloc] _initWithCollection:self reverse:YES] autorelease];
}

- (NSArray *)arrayByAddingObject:(id)object
{
    check_object(self, _cmd, object);
    NSUInteger n = [self count];
    id *objects = malloc((n + 1) * sizeof(id));
    [self getObjects:objects range:NSMakeRange(0, n)];
    objects[n] = object;
    NSArray *result = [NSArray arrayWithObjects:objects count:n + 1];
    free(objects);
    return result;
}

- (NSArray *)arrayByAddingObjectsFromArray:(NSArray *)other
{
    NSMutableArray *m = [[NSMutableArray alloc] initWithArray:self];
    [m addObjectsFromArray:other];
    NSArray *result = [NSArray arrayWithArray:m];
    [m release];
    return result;
}

- (NSArray *)subarrayWithRange:(NSRange)range
{
    id stackbuf[16], *objects = range.length <= 16 ? stackbuf : malloc(range.length * sizeof(id));
    [self getObjects:objects range:range];
    NSArray *result = [NSArray arrayWithObjects:objects count:range.length];
    if (objects != stackbuf) free(objects);
    return result;
}

- (void)makeObjectsPerformSelector:(SEL)sel
{
    NSUInteger n = [self count];
    for (NSUInteger i = 0; i < n; i++) ((void (*)(id, SEL))objc_msgSend)([self objectAtIndex:i], sel);
}

- (void)makeObjectsPerformSelector:(SEL)sel withObject:(id)arg
{
    NSUInteger n = [self count];
    for (NSUInteger i = 0; i < n; i++) ((void (*)(id, SEL, id))objc_msgSend)([self objectAtIndex:i], sel, arg);
}

- (void)enumerateObjectsUsingBlock:(void (^)(id, NSUInteger, BOOL *))block
{
    [self enumerateObjectsWithOptions:0 usingBlock:block];
}

- (void)enumerateObjectsWithOptions:(NSEnumerationOptions)opts usingBlock:(void (^)(id, NSUInteger, BOOL *))block
{
    NSUInteger n = [self count];
    BOOL stop = NO;
    for (NSUInteger k = 0; k < n && !stop; k++) {
        NSUInteger i = (opts & NSEnumerationReverse) ? n - 1 - k : k;
        block([self objectAtIndex:i], i, &stop);
    }
}

- (NSUInteger)indexOfObjectPassingTest:(BOOL (^)(id, NSUInteger, BOOL *))predicate
{
    NSUInteger n = [self count];
    BOOL stop = NO;
    for (NSUInteger i = 0; i < n && !stop; i++)
        if (predicate([self objectAtIndex:i], i, &stop)) return i;
    return NSNotFound;
}

- (CFTypeID)_cfTypeID { return CFArrayGetTypeID(); }
- (BOOL)isNSArray__ { return YES; }

@end

/* MARK: - NSMutableArray */

@implementation NSMutableArray

+ (instancetype)arrayWithCapacity:(NSUInteger)capacity { return [[[self alloc] initWithCapacity:capacity] autorelease]; }
- (instancetype)initWithCapacity:(NSUInteger)capacity { return [self init]; }

#define ABSTRACT(sig) \
    sig { __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s %s]!", \
        FINCH_METHOD_ARGS, object_getClassName(self), sel_getName(_cmd)); }
ABSTRACT(- (void)insertObject:(id)object atIndex:(NSUInteger)idx)
ABSTRACT(- (void)removeObjectAtIndex:(NSUInteger)idx)
ABSTRACT(- (void)replaceObjectAtIndex:(NSUInteger)idx withObject:(id)object)
#undef ABSTRACT

- (void)addObject:(id)object { [self insertObject:object atIndex:[self count]]; }
- (void)removeLastObject { NSUInteger n = [self count]; if (n) [self removeObjectAtIndex:n - 1]; }

- (void)setObject:(id)object atIndex:(NSUInteger)idx
{
    if (idx == [self count]) [self addObject:object];
    else [self replaceObjectAtIndex:idx withObject:object];
}

- (void)setObject:(id)object atIndexedSubscript:(NSUInteger)idx { [self setObject:object atIndex:idx]; }

- (void)exchangeObjectAtIndex:(NSUInteger)i withObjectAtIndex:(NSUInteger)j
{
    id a = [[self objectAtIndex:i] retain], b = [self objectAtIndex:j];
    [self replaceObjectAtIndex:i withObject:b];
    [self replaceObjectAtIndex:j withObject:a];
    [a release];
}

- (void)removeAllObjects { while ([self count]) [self removeObjectAtIndex:[self count] - 1]; }

- (void)addObjectsFromArray:(NSArray *)array
{
    for (id o in array) [self addObject:o];
}

- (void)removeObject:(id)object
{
    for (NSUInteger i = [self count]; i-- > 0;) {
        id o = [self objectAtIndex:i];
        if (o == object || [o isEqual:object]) [self removeObjectAtIndex:i];
    }
}

- (void)removeObjectIdenticalTo:(id)object
{
    for (NSUInteger i = [self count]; i-- > 0;)
        if ([self objectAtIndex:i] == object) [self removeObjectAtIndex:i];
}

- (void)removeObjectsInRange:(NSRange)range
{
    for (NSUInteger i = range.length; i-- > 0;) [self removeObjectAtIndex:range.location + i];
}

- (void)replaceObjectsInRange:(NSRange)range withObjects:(const id *)objects count:(NSUInteger)count
{
    [self removeObjectsInRange:range];
    for (NSUInteger i = 0; i < count; i++) [self insertObject:objects[i] atIndex:range.location + i];
}

- (void)setArray:(NSArray *)array
{
    if (array == self) return;
    [array retain];
    [self removeAllObjects];
    [self addObjectsFromArray:array];
    [array release];
}

- (id)copyWithZone:(struct _NSZone *)zone { return [[NSArray alloc] initWithArray:self]; }

@end

/* MARK: - __NSPlaceholderArray */

@implementation __NSPlaceholderArray

FINCH_IMMORTAL_MEMORY

- (BOOL)_isMutable { return self == mutablePlaceholder; }

- (instancetype)init { return [self initWithObjects:NULL count:0]; }
- (instancetype)initWithCapacity:(NSUInteger)capacity
{
    return (id)CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
}

- (instancetype)initWithObjects:(const id *)objects count:(NSUInteger)count
{
    for (NSUInteger i = 0; i < count; i++)
        if (!objects[i])
            __CFFinchRaise(NSInvalidArgumentException,
                "*** " FINCH_METHOD_FMT ": attempt to insert nil object from objects[%lu]", FINCH_METHOD_ARGS, (unsigned long)i);
    if (![self _isMutable])
        return (id)CFArrayCreate(NULL, (const void **)objects, (CFIndex)count, &kCFTypeArrayCallBacks);
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFArrayReplaceValues(a, CFRangeMake(0, 0), (const void **)objects, (CFIndex)count);
    return (id)a;
}

- (NSUInteger)count { return 0; }

@end

/* MARK: - __NSCFArray */

@implementation __NSCFArray

FINCH_CF_OBJECT_MEMORY

/* Instances are CF objects: [[obj class] alloc] goes through the placeholder. */
+ (instancetype)allocWithZone:(struct _NSZone *)zone { return (id)mutablePlaceholder; }

- (NSUInteger)count { return (NSUInteger)CFArrayGetCount((CFArrayRef)self); }

- (id)objectAtIndex:(NSUInteger)idx
{
    check_index(self, _cmd, idx, (NSUInteger)CFArrayGetCount((CFArrayRef)self));
    return (id)CFArrayGetValueAtIndex((CFArrayRef)self, (CFIndex)idx);
}

- (id)objectAtIndexedSubscript:(NSUInteger)idx
{
    check_index(self, _cmd, idx, (NSUInteger)CFArrayGetCount((CFArrayRef)self));
    return (id)CFArrayGetValueAtIndex((CFArrayRef)self, (CFIndex)idx);
}

- (void)getObjects:(id *)objects range:(NSRange)range
{
    NSUInteger n = (NSUInteger)CFArrayGetCount((CFArrayRef)self);
    if (range.location > n || range.length > n - range.location)
        __CFFinchRaise(NSRangeException, "*** " FINCH_METHOD_FMT ": range {%lu, %lu} extends beyond bounds [0 .. %lu]",
            FINCH_METHOD_ARGS, (unsigned long)range.location, (unsigned long)range.length, (unsigned long)(n ? n - 1 : 0));
    CFArrayGetValues((CFArrayRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length), (const void **)objects);
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    NSUInteger n = (NSUInteger)CFArrayGetCount((CFArrayRef)self), i = state->state;
    if (i == 0) state->extra[0] = n;   /* what mutationsPtr watches: the count */
    if (i >= n) return 0;
    if (len > n - i) len = n - i;
    CFArrayGetValues((CFArrayRef)self, CFRangeMake((CFIndex)i, (CFIndex)len), (const void **)buffer);
    state->state = i + len;
    state->itemsPtr = buffer;
    state->mutationsPtr = &state->extra[0];
    return len;
}

- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }

- (id)copyWithZone:(struct _NSZone *)zone
{
    if (!_CFArrayIsMutable((CFArrayRef)self)) return [self retain];
    return (id)CFArrayCreateCopy(NULL, (CFArrayRef)self);
}

- (id)mutableCopyWithZone:(struct _NSZone *)zone
{
    return (id)CFArrayCreateMutableCopy(NULL, 0, (CFArrayRef)self);
}

static void
check_mutable(id self, SEL _cmd)
{
    if (!_CFArrayIsMutable((CFArrayRef)self))
        __CFFinchRaise(NSInternalInconsistencyException, FINCH_METHOD_FMT ": mutating method sent to immutable object",
            FINCH_METHOD_ARGS);
}

- (void)addObject:(id)object
{
    check_mutable(self, _cmd);
    check_object(self, _cmd, object);
    CFArrayAppendValue((CFMutableArrayRef)self, object);
}

- (void)insertObject:(id)object atIndex:(NSUInteger)idx
{
    check_mutable(self, _cmd);
    check_object(self, _cmd, object);
    NSUInteger n = (NSUInteger)CFArrayGetCount((CFArrayRef)self);
    if (idx > n)
        __CFFinchRaise(NSRangeException, "*** " FINCH_METHOD_FMT ": index %lu beyond bounds [0 .. %lu]",
            FINCH_METHOD_ARGS, (unsigned long)idx, (unsigned long)n);
    CFArrayInsertValueAtIndex((CFMutableArrayRef)self, (CFIndex)idx, object);
}

- (void)removeObjectAtIndex:(NSUInteger)idx
{
    check_mutable(self, _cmd);
    check_index(self, _cmd, idx, (NSUInteger)CFArrayGetCount((CFArrayRef)self));
    CFArrayRemoveValueAtIndex((CFMutableArrayRef)self, (CFIndex)idx);
}

- (void)removeLastObject
{
    check_mutable(self, _cmd);
    CFIndex n = CFArrayGetCount((CFArrayRef)self);
    if (n) CFArrayRemoveValueAtIndex((CFMutableArrayRef)self, n - 1);
}

- (void)replaceObjectAtIndex:(NSUInteger)idx withObject:(id)object
{
    check_mutable(self, _cmd);
    check_object(self, _cmd, object);
    check_index(self, _cmd, idx, (NSUInteger)CFArrayGetCount((CFArrayRef)self));
    CFArraySetValueAtIndex((CFMutableArrayRef)self, (CFIndex)idx, object);
}

- (void)removeAllObjects
{
    check_mutable(self, _cmd);
    CFArrayRemoveAllValues((CFMutableArrayRef)self);
}

- (void)exchangeObjectAtIndex:(NSUInteger)i withObjectAtIndex:(NSUInteger)j
{
    check_mutable(self, _cmd);
    NSUInteger n = (NSUInteger)CFArrayGetCount((CFArrayRef)self);
    check_index(self, _cmd, i, n);
    check_index(self, _cmd, j, n);
    CFArrayExchangeValuesAtIndices((CFMutableArrayRef)self, (CFIndex)i, (CFIndex)j);
}

- (void)replaceObjectsInRange:(NSRange)range withObjects:(const id *)objects count:(NSUInteger)count
{
    check_mutable(self, _cmd);
    CFArrayReplaceValues((CFMutableArrayRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length),
        (const void **)objects, (CFIndex)count);
}

@end

/* MARK: - Enumerators */

@implementation NSEnumerator

- (id)nextObject
{
    __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": method only defined for abstract class.  Define -[%s nextObject]!",
        FINCH_METHOD_ARGS, object_getClassName(self));
}

- (NSArray *)allObjects
{
    NSMutableArray *all = [NSMutableArray array];
    for (id o; (o = [self nextObject]);) [all addObject:o];
    return all;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    static unsigned long never_mutated;
    NSUInteger n = 0;
    for (id o; n < len && (o = [self nextObject]);) buffer[n++] = o;
    state->state = 1;
    state->itemsPtr = buffer;
    state->mutationsPtr = &never_mutated;
    return n;
}

@end

/* An enumerator over any collection, through its fast enumeration (Apple's
 * CoreFoundation exports the class). Reverse enumeration snapshots the
 * collection, which is what -reverseObjectEnumerator promises anyway. */
@implementation __NSFastEnumerationEnumerator {
    id _collection;
    NSArray *_reversed;
    NSFastEnumerationState _state;
    id __unsafe_unretained _buffer[16];
    NSUInteger _count, _index;
}

- (instancetype)_initWithCollection:(id)collection reverse:(BOOL)reverse
{
    if ((self = [super init])) {
        if (reverse) {
            NSArray *all = collection;
            NSUInteger n = [all count];
            id *objects = malloc((n ? n : 1) * sizeof(id));
            [all getObjects:objects range:NSMakeRange(0, n)];
            for (NSUInteger i = 0; i < n / 2; i++) { id t = objects[i]; objects[i] = objects[n - 1 - i]; objects[n - 1 - i] = t; }
            _reversed = [[NSArray alloc] initWithObjects:objects count:n];
            free(objects);
            _collection = [_reversed retain];
        } else {
            _collection = [collection retain];
        }
    }
    return self;
}

- (id)nextObject
{
    if (_index == _count) {
        _count = [_collection countByEnumeratingWithState:&_state objects:_buffer count:16];
        _index = 0;
        if (_count == 0) return nil;
    }
    return _state.itemsPtr[_index++];
}

- (void)dealloc
{
    [_collection release];
    [_reversed release];
    [super dealloc];
}

@end

/* MARK: - Constant literals */

/* clang's constant array literal (@[@"a", @"b"] built for macOS 11+), with
 * the layout the compiler emits: count, then a pointer to the objects. */
@interface NSConstantArray : NSArray {
    NSUInteger _count;
    const id *_objects;
}
@end

@implementation NSConstantArray
FINCH_IMMORTAL_MEMORY
- (NSUInteger)count { return _count; }
- (id)objectAtIndex:(NSUInteger)idx
{
    check_index(self, _cmd, idx, _count);
    return _objects[idx];
}
- (void)getObjects:(id *)objects range:(NSRange)range
{
    if (range.location > _count || range.length > _count - range.location)
        __CFFinchRaise(NSRangeException, "*** " FINCH_METHOD_FMT ": range {%lu, %lu} extends beyond bounds [0 .. %lu]",
            FINCH_METHOD_ARGS, (unsigned long)range.location, (unsigned long)range.length, (unsigned long)(_count ? _count - 1 : 0));
    memcpy(objects, _objects + range.location, range.length * sizeof(id));
}
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    if (state->state) return 0;
    state->state = 1;
    state->itemsPtr = (id *)_objects;
    state->mutationsPtr = &state->extra[0];
    return _count;
}
- (id)copyWithZone:(struct _NSZone *)zone { return self; }
@end

/* The empty array: what clang's @[] refers to (___NSArray0__struct), and
 * Apple's CF exports both it and a pointer to it. */
@interface __NSArray0 : NSArray
@end
@implementation __NSArray0
FINCH_IMMORTAL_MEMORY
- (NSUInteger)count { return 0; }
- (id)objectAtIndex:(NSUInteger)idx { check_index(self, _cmd, idx, 0); return nil; }
- (id)copyWithZone:(struct _NSZone *)zone { return self; }
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    return 0;
}
@end

extern char OBJC_CLASS_$___NSArray0[];
struct __finch_NSArray0_object { __ptrauth_cf_objc_isa_pointer uintptr_t isa; };
CF_EXPORT struct __finch_NSArray0_object __NSArray0__struct;
struct __finch_NSArray0_object __NSArray0__struct = { (uintptr_t)OBJC_CLASS_$___NSArray0 };
CF_EXPORT const id __NSArray0__;   /* as clang declares it */
const id __NSArray0__ = (id)&__NSArray0__struct;
