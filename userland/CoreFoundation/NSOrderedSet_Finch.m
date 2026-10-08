/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSOrderedSet and NSMutableOrderedSet (docs/design/FOUNDATION.md), against
 * the SDK's <Foundation/NSOrderedSet.h>. They live in CoreFoundation, as
 * Apple's do: binaries that link CoreFoundation bind them there.
 *
 * The abstract classes build on the primitives (-count, -objectAtIndex:,
 * -indexOfObject:; insert, remove, replace). __NSOrderedSetI and
 * __NSOrderedSetM, Apple's names, keep a CFArray for order and a CFSet for
 * membership. Archives use Apple's keys (NS.object.0, NS.object.1, ...).
 */
#include "CFObjCClasses_Finch.h"

typedef CFComparisonResult NSComparisonResult;
typedef NSComparisonResult (^NSComparator)(id, id);
typedef NSUInteger NSSortOptions, NSBinarySearchingOptions;
enum {
    NSSortConcurrent = 1UL << 0,
    NSSortStable = 1UL << 4,
    NSBinarySearchingFirstEqual = 1UL << 8,
    NSBinarySearchingLastEqual = 1UL << 9,
    NSBinarySearchingInsertionIndex = 1UL << 10,
};

/* What this file sends to Foundation's objects (index sets, coders, sort
 * descriptors) and CF's arrays. */
@interface NSObject (FinchOrderedSetMessages)
- (void)enumerateIndexesUsingBlock:(void (^)(NSUInteger idx, BOOL *stop))block;
- (void)enumerateIndexesWithOptions:(NSEnumerationOptions)opts usingBlock:(void (^)(NSUInteger idx, BOOL *stop))block;
+ (id)indexSetWithIndexesInRange:(NSRange)range;
+ (id)indexSet;
- (void)addIndex:(NSUInteger)value;
- (id)valueForKey:(id)key;
- (void)setValue:(id)value forKey:(id)key;
- (id)sortedArrayUsingDescriptors:(id)descriptors;
- (void)encodeObject:(id)object forKey:(id)key;
- (BOOL)containsValueForKey:(id)key;
- (id)decodeObjectForKey:(id)key;
- (BOOL)isEqual:(id)object;
- (id)descriptionWithLocale:(id)locale indent:(NSUInteger)level;
- (id)objectEnumerator;
- (id)reverseObjectEnumerator;
@end

@interface NSOrderedSet : NSObject <NSCopying, NSMutableCopying, NSFastEnumeration>
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)idx;
- (NSUInteger)indexOfObject:(id)object;
- (instancetype)initWithObjects:(const id *)objects count:(NSUInteger)cnt;
- (instancetype)initWithArray:(NSArray *)array;
- (NSArray *)array;
@end

@interface NSMutableOrderedSet : NSOrderedSet
- (void)insertObject:(id)object atIndex:(NSUInteger)idx;
- (void)removeObjectAtIndex:(NSUInteger)idx;
- (void)replaceObjectAtIndex:(NSUInteger)idx withObject:(id)object;
- (void)addObject:(id)object;
- (void)removeObject:(id)object;
- (void)removeObjectsAtIndexes:(id)indexes;
- (void)insertObjects:(NSArray *)objects atIndexes:(id)indexes;
@end

@interface __NSOrderedSetI : NSOrderedSet {
@public
    CFMutableArrayRef _array;
    CFMutableSetRef _set;
}
@end

@interface __NSOrderedSetM : NSMutableOrderedSet {
@public
    CFMutableArrayRef _array;
    CFMutableSetRef _set;
}
@end

static void __attribute__((noreturn))
abstract(id self, SEL _cmd)
{
    char kind = object_isClass(self) ? '+' : '-';
    __CFFinchRaise(NSInvalidArgumentException, "*** %c[%s %s]: method only defined for abstract class.  Define %c[%s %s]!",
        kind, object_getClassName(self), sel_getName(_cmd), kind, object_getClassName(self), sel_getName(_cmd));
}

static void
check_index(id self, SEL _cmd, NSUInteger idx, NSUInteger count)
{
    if (idx >= count)
        __CFFinchRaise(NSRangeException, "*** -[%s %s]: index %lu beyond bounds [0 .. %ld]", object_getClassName(self), sel_getName(_cmd),
            (unsigned long)idx, (long)count - 1);
}

static NSArray *
objects_of(NSOrderedSet *self)
{
    NSUInteger n = [self count];
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, (CFIndex)n, &kCFTypeArrayCallBacks);
    for (NSUInteger i = 0; i < n; i++) CFArrayAppendValue(a, [self objectAtIndex:i]);
    return [(id)a autorelease];
}

static CFComparisonResult
block_compare(const void *a, const void *b, void *context)
{
    return ((NSComparator)context)((id)a, (id)b);
}

/* MARK: - NSOrderedSet */

@implementation NSOrderedSet

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSOrderedSet class]) return [__NSOrderedSetI allocWithZone:zone];
    if (self == [NSMutableOrderedSet class]) return [__NSOrderedSetM allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (NSUInteger)count { abstract(self, _cmd); }
- (id)objectAtIndex:(NSUInteger)idx { abstract(self, _cmd); }
- (NSUInteger)indexOfObject:(id)object
{
    NSUInteger n = [self count];
    for (NSUInteger i = 0; i < n; i++) if ([[self objectAtIndex:i] isEqual:object]) return i;
    return (NSUInteger)NSNotFound;
}

- (instancetype)init { return [self initWithObjects:NULL count:0]; }
- (instancetype)initWithObjects:(const id *)objects count:(NSUInteger)cnt { return [super init]; }
- (instancetype)initWithObject:(id)object { return [self initWithObjects:&object count:1]; }

- (instancetype)initWithObjects:(id)firstObj, ...
{
    id r;
    COLLECT_VARARGS(firstObj, objects, count, r = [self initWithObjects:objects count:count]);
    return r;
}

- (instancetype)initWithArray:(NSArray *)array range:(NSRange)range copyItems:(BOOL)flag
{
    NSUInteger n = range.length;
    id *objs = malloc((n + 1) * sizeof(id));
    [array getObjects:objs range:range];
    if (flag) for (NSUInteger i = 0; i < n; i++) objs[i] = [[objs[i] copy] autorelease];
    id r = [self initWithObjects:objs count:n];
    free(objs);
    return r;
}

- (instancetype)initWithArray:(NSArray *)array { return [self initWithArray:array range:NSMakeRange(0, [array count]) copyItems:NO]; }
- (instancetype)initWithArray:(NSArray *)array copyItems:(BOOL)flag { return [self initWithArray:array range:NSMakeRange(0, [array count]) copyItems:flag]; }
- (instancetype)initWithOrderedSet:(NSOrderedSet *)set { return [self initWithArray:[set array]]; }
- (instancetype)initWithOrderedSet:(NSOrderedSet *)set copyItems:(BOOL)flag { return [self initWithArray:[set array] copyItems:flag]; }
- (instancetype)initWithOrderedSet:(NSOrderedSet *)set range:(NSRange)range copyItems:(BOOL)flag
{
    return [self initWithArray:[set array] range:range copyItems:flag];
}

static NSArray *
set_objects(NSSet *set)
{
    CFIndex n = CFSetGetCount((CFSetRef)set);
    const void **v = malloc(((size_t)n + 1) * sizeof(void *));
    CFSetGetValues((CFSetRef)set, v);
    CFArrayRef a = CFArrayCreate(NULL, v, n, &kCFTypeArrayCallBacks);
    free(v);
    return [(id)a autorelease];
}

- (instancetype)initWithSet:(NSSet *)set { return [self initWithArray:set_objects(set)]; }
- (instancetype)initWithSet:(NSSet *)set copyItems:(BOOL)flag { return [self initWithArray:set_objects(set) copyItems:flag]; }

+ (instancetype)orderedSet { return [[[self alloc] init] autorelease]; }
+ (instancetype)orderedSetWithObject:(id)object { return [[[self alloc] initWithObject:object] autorelease]; }
+ (instancetype)orderedSetWithObjects:(const id *)objects count:(NSUInteger)cnt { return [[[self alloc] initWithObjects:objects count:cnt] autorelease]; }
+ (instancetype)orderedSetWithObjects:(id)firstObj, ...
{
    id r;
    COLLECT_VARARGS(firstObj, objects, count, r = [[[self alloc] initWithObjects:objects count:count] autorelease]);
    return r;
}
+ (instancetype)orderedSetWithOrderedSet:(NSOrderedSet *)set { return [[[self alloc] initWithOrderedSet:set] autorelease]; }
+ (instancetype)orderedSetWithOrderedSet:(NSOrderedSet *)set range:(NSRange)range copyItems:(BOOL)flag
{
    return [[[self alloc] initWithOrderedSet:set range:range copyItems:flag] autorelease];
}
+ (instancetype)orderedSetWithArray:(NSArray *)array { return [[[self alloc] initWithArray:array] autorelease]; }
+ (instancetype)orderedSetWithArray:(NSArray *)array range:(NSRange)range copyItems:(BOOL)flag
{
    return [[[self alloc] initWithArray:array range:range copyItems:flag] autorelease];
}
+ (instancetype)orderedSetWithSet:(NSSet *)set { return [[[self alloc] initWithSet:set] autorelease]; }
+ (instancetype)orderedSetWithSet:(NSSet *)set copyItems:(BOOL)flag { return [[[self alloc] initWithSet:set copyItems:flag] autorelease]; }

- (void)getObjects:(id __unsafe_unretained *)objects range:(NSRange)range
{
    for (NSUInteger i = 0; i < range.length; i++) objects[i] = [self objectAtIndex:range.location + i];
}

- (NSArray *)objectsAtIndexes:(id)indexes
{
    NSMutableArray *a = [[[NSMutableArray alloc] init] autorelease];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) { [a addObject:[self objectAtIndex:idx]]; }];
    return a;
}

- (id)firstObject { return [self count] ? [self objectAtIndex:0] : nil; }
- (id)lastObject { return [self count] ? [self objectAtIndex:[self count] - 1] : nil; }
- (id)objectAtIndexedSubscript:(NSUInteger)idx { return [self objectAtIndex:idx]; }
- (BOOL)containsObject:(id)object { return [self indexOfObject:object] != (NSUInteger)NSNotFound; }
- (NSArray *)array { return objects_of(self); }

- (NSSet *)set
{
    NSArray *a = [self array];
    CFIndex n = CFArrayGetCount((CFArrayRef)a);
    const void **v = malloc(((size_t)n + 1) * sizeof(void *));
    CFArrayGetValues((CFArrayRef)a, CFRangeMake(0, n), v);
    CFSetRef s = CFSetCreate(NULL, v, n, &kCFTypeSetCallBacks);
    free(v);
    return [(id)s autorelease];
}

- (NSOrderedSet *)reversedOrderedSet
{
    NSUInteger n = [self count];
    id *objs = malloc((n + 1) * sizeof(id));
    for (NSUInteger i = 0; i < n; i++) objs[i] = [self objectAtIndex:n - 1 - i];
    id r = [NSOrderedSet orderedSetWithObjects:objs count:n];
    free(objs);
    return r;
}

- (BOOL)isEqualToOrderedSet:(NSOrderedSet *)other
{
    if (other == self) return YES;
    if ([other count] != [self count]) return NO;
    for (NSUInteger i = 0; i < [self count]; i++) if (![[self objectAtIndex:i] isEqual:[other objectAtIndex:i]]) return NO;
    return YES;
}

- (BOOL)isEqual:(id)object
{
    return object == self || ([object isKindOfClass:[NSOrderedSet class]] && [self isEqualToOrderedSet:object]);
}

- (NSUInteger)hash { return [self count]; }

- (BOOL)intersectsOrderedSet:(NSOrderedSet *)other
{
    for (NSUInteger i = 0; i < [other count]; i++) if ([self containsObject:[other objectAtIndex:i]]) return YES;
    return NO;
}
- (BOOL)intersectsSet:(NSSet *)set
{
    for (id o in set_objects(set)) if ([self containsObject:o]) return YES;
    return NO;
}
- (BOOL)isSubsetOfOrderedSet:(NSOrderedSet *)other
{
    for (NSUInteger i = 0; i < [self count]; i++) if (![other containsObject:[self objectAtIndex:i]]) return NO;
    return YES;
}
- (BOOL)isSubsetOfSet:(NSSet *)set
{
    for (NSUInteger i = 0; i < [self count]; i++) if (![set containsObject:[self objectAtIndex:i]]) return NO;
    return YES;
}

- (id)objectEnumerator { return [[self array] objectEnumerator]; }
- (id)reverseObjectEnumerator { return [[self array] reverseObjectEnumerator]; }

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    NSUInteger n = [self count];
    if (state->state == 0) state->mutationsPtr = &state->extra[0];
    NSUInteger i = state->state, k = 0;
    for (; i < n && k < len; i++, k++) buffer[k] = [self objectAtIndex:i];
    state->state = i;
    state->itemsPtr = buffer;
    return k;
}

- (void)enumerateObjectsAtIndexes:(id)s options:(NSEnumerationOptions)opts usingBlock:(void (^)(id, NSUInteger, BOOL *))block
{
    __block BOOL stop = NO;
    [s enumerateIndexesWithOptions:opts & NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stopIndexes) {
        block([self objectAtIndex:idx], idx, &stop);
        if (stop) *stopIndexes = YES;
    }];
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

- (void)enumerateObjectsUsingBlock:(void (^)(id, NSUInteger, BOOL *))block { [self enumerateObjectsWithOptions:0 usingBlock:block]; }

- (NSUInteger)indexOfObjectWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (^)(id, NSUInteger, BOOL *))predicate
{
    __block NSUInteger found = (NSUInteger)NSNotFound;
    [self enumerateObjectsWithOptions:opts usingBlock:^(id o, NSUInteger i, BOOL *stop) {
        if (predicate(o, i, stop)) { found = i; *stop = YES; }
    }];
    return found;
}

- (NSUInteger)indexOfObjectPassingTest:(BOOL (^)(id, NSUInteger, BOOL *))predicate { return [self indexOfObjectWithOptions:0 passingTest:predicate]; }

- (NSUInteger)indexOfObjectAtIndexes:(id)s options:(NSEnumerationOptions)opts passingTest:(BOOL (^)(id, NSUInteger, BOOL *))predicate
{
    __block NSUInteger found = (NSUInteger)NSNotFound;
    [self enumerateObjectsAtIndexes:s options:opts usingBlock:^(id o, NSUInteger i, BOOL *stop) {
        if (predicate(o, i, stop)) { found = i; *stop = YES; }
    }];
    return found;
}

- (id)indexesOfObjectsWithOptions:(NSEnumerationOptions)opts passingTest:(BOOL (^)(id, NSUInteger, BOOL *))predicate
{
    id set = [objc_getClass("NSMutableIndexSet") indexSet];
    [self enumerateObjectsWithOptions:opts usingBlock:^(id o, NSUInteger i, BOOL *stop) { if (predicate(o, i, stop)) [set addIndex:i]; }];
    return set;
}

- (id)indexesOfObjectsPassingTest:(BOOL (^)(id, NSUInteger, BOOL *))predicate { return [self indexesOfObjectsWithOptions:0 passingTest:predicate]; }

- (id)indexesOfObjectsAtIndexes:(id)s options:(NSEnumerationOptions)opts passingTest:(BOOL (^)(id, NSUInteger, BOOL *))predicate
{
    id set = [objc_getClass("NSMutableIndexSet") indexSet];
    [self enumerateObjectsAtIndexes:s options:opts usingBlock:^(id o, NSUInteger i, BOOL *stop) { if (predicate(o, i, stop)) [set addIndex:i]; }];
    return set;
}

- (NSUInteger)indexOfObject:(id)obj inSortedRange:(NSRange)r options:(NSBinarySearchingOptions)opts usingComparator:(NSComparator)cmp
{
    BOOL first = (opts & NSBinarySearchingFirstEqual) != 0, last = (opts & NSBinarySearchingLastEqual) != 0;
    BOOL insert = (opts & NSBinarySearchingInsertionIndex) != 0;
    NSUInteger lo = r.location, hi = r.location + r.length, found = (NSUInteger)NSNotFound;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        CFComparisonResult c = cmp([self objectAtIndex:mid], obj);
        if (c == kCFCompareEqualTo) {
            found = mid;
            if (first || (insert && !last)) hi = mid;
            else if (last) lo = mid + 1;
            else break;
        } else if (c == kCFCompareLessThan) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (insert) return found != (NSUInteger)NSNotFound && !last && !first ? found : (last && found != (NSUInteger)NSNotFound ? found + 1 : lo);
    return found;
}

- (NSArray *)sortedArrayWithOptions:(NSSortOptions)opts usingComparator:(NSComparator)cmptr
{
    CFMutableArrayRef a = CFArrayCreateMutableCopy(NULL, 0, (CFArrayRef)[self array]);
    CFArraySortValues(a, CFRangeMake(0, CFArrayGetCount(a)), block_compare, cmptr);
    return [(id)a autorelease];
}

- (NSArray *)sortedArrayUsingComparator:(NSComparator)cmptr { return [self sortedArrayWithOptions:0 usingComparator:cmptr]; }
- (NSArray *)sortedArrayUsingDescriptors:(id)sortDescriptors { return [[self array] sortedArrayUsingDescriptors:sortDescriptors]; }

/* Apple's: the array's form inside "{( ... )}". */
- (id)descriptionWithLocale:(id)locale indent:(NSUInteger)level
{
    id a = [[self array] descriptionWithLocale:locale indent:level];
    return [(id)CFStringCreateWithFormat(NULL, NULL, CFSTR("{%@}"), a) autorelease];
}
- (id)descriptionWithLocale:(id)locale { return [self descriptionWithLocale:locale indent:0]; }
- (id)description { return [self descriptionWithLocale:nil indent:0]; }

- (id)copyWithZone:(struct _NSZone *)zone { return [[NSOrderedSet allocWithZone:zone] initWithOrderedSet:self]; }
- (id)mutableCopyWithZone:(struct _NSZone *)zone { return [[NSMutableOrderedSet allocWithZone:zone] initWithOrderedSet:self]; }

- (Class)classForCoder { return [NSOrderedSet class]; }

static id
object_key(NSUInteger i)
{
    return [(id)CFStringCreateWithFormat(NULL, NULL, CFSTR("NS.object.%lu"), (unsigned long)i) autorelease];
}

- (void)encodeWithCoder:(id)coder
{
    for (NSUInteger i = 0; i < [self count]; i++) [coder encodeObject:[self objectAtIndex:i] forKey:object_key(i)];
}

- (instancetype)initWithCoder:(id)coder
{
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (NSUInteger i = 0;; i++) {
        id k = object_key(i);
        if (![coder containsValueForKey:k]) break;
        id o = [coder decodeObjectForKey:k];
        if (!o) { CFRelease(a); [self release]; return nil; }
        CFArrayAppendValue(a, o);
    }
    id r = [self initWithArray:(NSArray *)a];
    CFRelease(a);
    return r;
}

- (id)valueForKey:(id)key
{
    NSMutableOrderedSet *r = [NSMutableOrderedSet orderedSet];
    for (NSUInteger i = 0; i < [self count]; i++) {
        id v = [[self objectAtIndex:i] valueForKey:key];
        if (v) [r addObject:v];
    }
    return r;
}

- (void)setValue:(id)value forKey:(id)key
{
    for (NSUInteger i = 0; i < [self count]; i++) [[self objectAtIndex:i] setValue:value forKey:key];
}

@end

/* MARK: - NSMutableOrderedSet */

@implementation NSMutableOrderedSet

- (instancetype)initWithCapacity:(NSUInteger)numItems { return [self init]; }
+ (instancetype)orderedSetWithCapacity:(NSUInteger)numItems { return [[[self alloc] initWithCapacity:numItems] autorelease]; }

- (void)insertObject:(id)object atIndex:(NSUInteger)idx { abstract(self, _cmd); }
- (void)removeObjectAtIndex:(NSUInteger)idx { abstract(self, _cmd); }
- (void)replaceObjectAtIndex:(NSUInteger)idx withObject:(id)object { abstract(self, _cmd); }

- (Class)classForCoder { return [NSMutableOrderedSet class]; }

- (void)addObject:(id)object { [self insertObject:object atIndex:[self count]]; }
- (void)addObjects:(const id *)objects count:(NSUInteger)count { for (NSUInteger i = 0; i < count; i++) [self addObject:objects[i]]; }
- (void)addObjectsFromArray:(NSArray *)array { for (id o in array) [self addObject:o]; }

- (void)exchangeObjectAtIndex:(NSUInteger)idx1 withObjectAtIndex:(NSUInteger)idx2
{
    if (idx1 == idx2) return;
    NSUInteger lo = idx1 < idx2 ? idx1 : idx2, hi = idx1 < idx2 ? idx2 : idx1;
    id a = [[[self objectAtIndex:lo] retain] autorelease], b = [[[self objectAtIndex:hi] retain] autorelease];
    [self removeObjectAtIndex:hi];
    [self removeObjectAtIndex:lo];
    [self insertObject:b atIndex:lo];
    [self insertObject:a atIndex:hi];
}

- (void)moveObjectsAtIndexes:(id)indexes toIndex:(NSUInteger)idx
{
    NSArray *moving = [self objectsAtIndexes:indexes];
    [self removeObjectsAtIndexes:indexes];
    [self insertObjects:moving atIndexes:[objc_getClass("NSIndexSet") indexSetWithIndexesInRange:NSMakeRange(idx, [moving count])]];
}

- (void)insertObjects:(NSArray *)objects atIndexes:(id)indexes
{
    __block NSUInteger i = 0;
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) { [self insertObject:[objects objectAtIndex:i++] atIndex:idx]; }];
}

- (void)setObject:(id)obj atIndex:(NSUInteger)idx
{
    if (idx == [self count]) [self insertObject:obj atIndex:idx];
    else [self replaceObjectAtIndex:idx withObject:obj];
}
- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)idx { [self setObject:obj atIndex:idx]; }

- (void)removeObjectsInRange:(NSRange)range
{
    for (NSUInteger i = range.length; i > 0; i--) [self removeObjectAtIndex:range.location + i - 1];
}

- (void)replaceObjectsInRange:(NSRange)range withObjects:(const id *)objects count:(NSUInteger)count
{
    [self removeObjectsInRange:range];
    for (NSUInteger i = 0; i < count; i++) [self insertObject:objects[i] atIndex:range.location + i];
}

- (void)replaceObjectsAtIndexes:(id)indexes withObjects:(NSArray *)objects
{
    __block NSUInteger i = 0;
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) { [self replaceObjectAtIndex:idx withObject:[objects objectAtIndex:i++]]; }];
}

- (void)removeObjectsAtIndexes:(id)indexes
{
    [indexes enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) { [self removeObjectAtIndex:idx]; }];
}

- (void)removeAllObjects { [self removeObjectsInRange:NSMakeRange(0, [self count])]; }

- (void)removeObject:(id)object
{
    NSUInteger i = [self indexOfObject:object];
    if (i != (NSUInteger)NSNotFound) [self removeObjectAtIndex:i];
}

- (void)removeObjectsInArray:(NSArray *)array { for (id o in array) [self removeObject:o]; }
- (void)intersectOrderedSet:(NSOrderedSet *)other { for (id o in [self array]) if (![other containsObject:o]) [self removeObject:o]; }
- (void)minusOrderedSet:(NSOrderedSet *)other { for (id o in [other array]) [self removeObject:o]; }
- (void)unionOrderedSet:(NSOrderedSet *)other { for (id o in [other array]) [self addObject:o]; }
- (void)intersectSet:(NSSet *)other { for (id o in [self array]) if (![other containsObject:o]) [self removeObject:o]; }
- (void)minusSet:(NSSet *)other { for (id o in set_objects(other)) [self removeObject:o]; }
- (void)unionSet:(NSSet *)other { for (id o in set_objects(other)) [self addObject:o]; }

- (void)sortRange:(NSRange)range options:(NSSortOptions)opts usingComparator:(NSComparator)cmptr
{
    CFMutableArrayRef a = CFArrayCreateMutableCopy(NULL, 0, (CFArrayRef)[self array]);
    CFArraySortValues(a, CFRangeMake((CFIndex)range.location, (CFIndex)range.length), block_compare, cmptr);
    [self removeAllObjects];
    for (CFIndex i = 0; i < CFArrayGetCount(a); i++) [self addObject:(id)CFArrayGetValueAtIndex(a, i)];
    CFRelease(a);
}

- (void)sortWithOptions:(NSSortOptions)opts usingComparator:(NSComparator)cmptr { [self sortRange:NSMakeRange(0, [self count]) options:opts usingComparator:cmptr]; }
- (void)sortUsingComparator:(NSComparator)cmptr { [self sortRange:NSMakeRange(0, [self count]) options:0 usingComparator:cmptr]; }

- (void)sortUsingDescriptors:(id)sortDescriptors
{
    NSArray *sorted = [[self array] sortedArrayUsingDescriptors:sortDescriptors];
    [self removeAllObjects];
    for (id o in sorted) [self addObject:o];
}

@end

/* MARK: - Concrete classes */

#define ORDERED_STORAGE \
    - (void)dealloc { if (_array) CFRelease(_array); if (_set) CFRelease(_set); [super dealloc]; } \
    - (NSUInteger)count { return (NSUInteger)CFArrayGetCount(_array); } \
    - (id)objectAtIndex:(NSUInteger)idx \
    { \
        check_index(self, _cmd, idx, (NSUInteger)CFArrayGetCount(_array)); \
        return (id)CFArrayGetValueAtIndex(_array, (CFIndex)idx); \
    } \
    - (NSUInteger)indexOfObject:(id)object \
    { \
        if (!object || !CFSetContainsValue(_set, object)) return (NSUInteger)NSNotFound; \
        CFIndex i = CFArrayGetFirstIndexOfValue(_array, CFRangeMake(0, CFArrayGetCount(_array)), object); \
        return i < 0 ? (NSUInteger)NSNotFound : (NSUInteger)i; \
    } \
    - (BOOL)containsObject:(id)object { return object && CFSetContainsValue(_set, object); } \
    - (NSArray *)array { return [(id)CFArrayCreateCopy(NULL, _array) autorelease]; } \
    - (instancetype)initWithObjects:(const id *)objects count:(NSUInteger)cnt \
    { \
        if ((self = [super initWithObjects:NULL count:0])) { \
            _array = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks); \
            _set = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks); \
            for (NSUInteger i = 0; i < cnt; i++) { \
                if (!objects[i]) __CFFinchRaise(NSInvalidArgumentException, "*** -[%s initWithObjects:count:]: attempt to insert nil object from objects[%lu]", \
                    object_getClassName(self), (unsigned long)i); \
                if (CFSetContainsValue(_set, objects[i])) continue; \
                CFSetAddValue(_set, objects[i]); \
                CFArrayAppendValue(_array, objects[i]); \
            } \
        } \
        return self; \
    }

@implementation __NSOrderedSetI
ORDERED_STORAGE
- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }
@end

@implementation __NSOrderedSetM
ORDERED_STORAGE

- (instancetype)init { return [self initWithObjects:NULL count:0]; }

- (void)insertObject:(id)object atIndex:(NSUInteger)idx
{
    if (!object) __CFFinchRaise(NSInvalidArgumentException, "*** -[__NSOrderedSetM insertObject:atIndex:]: object cannot be nil");
    if (idx > (NSUInteger)CFArrayGetCount(_array)) check_index(self, _cmd, idx, (NSUInteger)CFArrayGetCount(_array));
    if (CFSetContainsValue(_set, object)) return;
    CFSetAddValue(_set, object);
    CFArrayInsertValueAtIndex(_array, (CFIndex)idx, object);
}

- (void)removeObjectAtIndex:(NSUInteger)idx
{
    check_index(self, _cmd, idx, (NSUInteger)CFArrayGetCount(_array));
    CFSetRemoveValue(_set, CFArrayGetValueAtIndex(_array, (CFIndex)idx));
    CFArrayRemoveValueAtIndex(_array, (CFIndex)idx);
}

- (void)replaceObjectAtIndex:(NSUInteger)idx withObject:(id)object
{
    check_index(self, _cmd, idx, (NSUInteger)CFArrayGetCount(_array));
    if (!object) __CFFinchRaise(NSInvalidArgumentException, "*** -[__NSOrderedSetM replaceObjectAtIndex:withObject:]: object cannot be nil");
    id old = (id)CFArrayGetValueAtIndex(_array, (CFIndex)idx);
    if ([old isEqual:object]) {
        CFArraySetValueAtIndex(_array, (CFIndex)idx, object);
        return;
    }
    if (CFSetContainsValue(_set, object)) return;
    CFSetRemoveValue(_set, old);
    CFSetAddValue(_set, object);
    CFArraySetValueAtIndex(_array, (CFIndex)idx, object);
}

- (void)removeAllObjects
{
    CFArrayRemoveAllValues(_array);
    CFSetRemoveAllValues(_set);
}

@end
