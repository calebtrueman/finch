/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSIndexSet and NSMutableIndexSet (docs/design/FOUNDATION.md), against the
 * SDK's declarations: a sorted array of disjoint, non-adjacent ranges. Also
 * the NSArray methods that take index sets.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"

@implementation NSIndexSet {
@protected
    NSRange *_ranges;
    NSUInteger _count, _capacity;
}

+ (instancetype)indexSet { return [[[self alloc] init] autorelease]; }
+ (instancetype)indexSetWithIndex:(NSUInteger)value { return [[[self alloc] initWithIndex:value] autorelease]; }
+ (instancetype)indexSetWithIndexesInRange:(NSRange)range { return [[[self alloc] initWithIndexesInRange:range] autorelease]; }

- (instancetype)initWithIndex:(NSUInteger)value { return [self initWithIndexesInRange:NSMakeRange(value, 1)]; }

- (instancetype)initWithIndexesInRange:(NSRange)range
{
    if ((self = [super init]) && range.length) {
        _capacity = 1;
        _ranges = malloc(sizeof(NSRange));
        _ranges[0] = range;
        _count = 1;
    }
    return self;
}

- (instancetype)initWithIndexSet:(NSIndexSet *)other
{
    if ((self = [super init]) && other->_count) {
        _capacity = other->_count;
        _ranges = malloc(_capacity * sizeof(NSRange));
        memcpy(_ranges, other->_ranges, _capacity * sizeof(NSRange));
        _count = other->_count;
    }
    return self;
}

- (void)dealloc { free(_ranges); [super dealloc]; }

- (id)copyWithZone:(NSZone *)zone { return [[NSIndexSet alloc] initWithIndexSet:self]; }
- (id)mutableCopyWithZone:(NSZone *)zone { return [[NSMutableIndexSet alloc] initWithIndexSet:self]; }
- (instancetype)initWithCoder:(NSCoder *)c { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)c { }
+ (BOOL)supportsSecureCoding { return YES; }

- (NSUInteger)count
{
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < _count; i++) n += _ranges[i].length;
    return n;
}

- (NSUInteger)firstIndex { return _count ? _ranges[0].location : NSNotFound; }
- (NSUInteger)lastIndex { return _count ? NSMaxRange(_ranges[_count - 1]) - 1 : NSNotFound; }

/* The index of the range containing or following `value`. */
static NSUInteger
range_at_or_after(NSIndexSet *s, NSUInteger value)
{
    NSUInteger lo = 0, hi = s->_count;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (NSMaxRange(s->_ranges[mid]) <= value) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

- (NSUInteger)indexGreaterThanOrEqualToIndex:(NSUInteger)value
{
    NSUInteger r = range_at_or_after(self, value);
    if (r == _count) return NSNotFound;
    return value >= _ranges[r].location ? value : _ranges[r].location;
}
- (NSUInteger)indexGreaterThanIndex:(NSUInteger)value { return value == NSNotFound - 1 ? NSNotFound : [self indexGreaterThanOrEqualToIndex:value + 1]; }
- (NSUInteger)indexLessThanOrEqualToIndex:(NSUInteger)value
{
    for (NSUInteger i = _count; i-- > 0;) {
        if (_ranges[i].location <= value) return MIN(value, NSMaxRange(_ranges[i]) - 1);
    }
    return NSNotFound;
}
- (NSUInteger)indexLessThanIndex:(NSUInteger)value { return value == 0 ? NSNotFound : [self indexLessThanOrEqualToIndex:value - 1]; }

- (BOOL)containsIndex:(NSUInteger)value
{
    NSUInteger r = range_at_or_after(self, value);
    return r < _count && NSLocationInRange(value, _ranges[r]);
}

- (BOOL)containsIndexesInRange:(NSRange)range
{
    if (range.length == 0) return NO;
    NSUInteger r = range_at_or_after(self, range.location);
    return r < _count && _ranges[r].location <= range.location && NSMaxRange(_ranges[r]) >= NSMaxRange(range);
}

- (BOOL)containsIndexes:(NSIndexSet *)other
{
    for (NSUInteger i = 0; i < other->_count; i++)
        if (![self containsIndexesInRange:other->_ranges[i]]) return NO;
    return YES;
}

- (BOOL)intersectsIndexesInRange:(NSRange)range
{
    for (NSUInteger i = 0; i < _count; i++)
        if (NSIntersectionRange(_ranges[i], range).length) return YES;
    return NO;
}

- (NSUInteger)countOfIndexesInRange:(NSRange)range
{
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < _count; i++) n += NSIntersectionRange(_ranges[i], range).length;
    return n;
}

- (NSUInteger)getIndexes:(NSUInteger *)buffer maxCount:(NSUInteger)max inIndexRange:(NSRangePointer)range
{
    NSRange limit = range ? *range : NSMakeRange(0, NSNotFound);
    NSUInteger n = 0, last = limit.location;
    for (NSUInteger i = 0; i < _count && n < max; i++) {
        NSRange r = NSIntersectionRange(_ranges[i], limit);
        for (NSUInteger v = r.location; v < NSMaxRange(r) && n < max; v++) {
            buffer[n++] = v;
            last = v + 1;
        }
    }
    if (range) {
        NSUInteger end = NSMaxRange(limit);
        *range = n ? NSMakeRange(last, end - last) : NSMakeRange(end, 0);
    }
    return n;
}

- (BOOL)isEqualToIndexSet:(NSIndexSet *)other
{
    if (other == self) return YES;
    if (!other || other->_count != _count) return NO;
    return memcmp(_ranges, other->_ranges, _count * sizeof(NSRange)) == 0;
}

- (BOOL)isEqual:(id)o { return o == self || ([o isKindOfClass:[NSIndexSet class]] && [self isEqualToIndexSet:o]); }
- (NSUInteger)hash { return [self count]; }

- (void)enumerateIndexesWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))block
{
    BOOL stop = NO;
    if (opts & NSEnumerationReverse) {
        for (NSUInteger i = _count; i-- > 0 && !stop;)
            for (NSUInteger v = NSMaxRange(_ranges[i]); v-- > _ranges[i].location && !stop;) block(v, &stop);
    } else {
        for (NSUInteger i = 0; i < _count && !stop; i++)
            for (NSUInteger v = _ranges[i].location; v < NSMaxRange(_ranges[i]) && !stop; v++) block(v, &stop);
    }
}
- (void)enumerateIndexesUsingBlock:(void (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))block { [self enumerateIndexesWithOptions:0 usingBlock:block]; }
- (void)enumerateIndexesInRange:(NSRange)range options:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))block
{
    [self enumerateIndexesWithOptions:opts usingBlock:^(NSUInteger idx, BOOL *stop) {
        if (NSLocationInRange(idx, range)) block(idx, stop);
    }];
}

- (void)enumerateRangesWithOptions:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSRange range, BOOL *stop))block
{
    BOOL stop = NO;
    if (opts & NSEnumerationReverse) {
        for (NSUInteger i = _count; i-- > 0 && !stop;) block(_ranges[i], &stop);
    } else {
        for (NSUInteger i = 0; i < _count && !stop; i++) block(_ranges[i], &stop);
    }
}
- (void)enumerateRangesUsingBlock:(void (NS_NOESCAPE ^)(NSRange range, BOOL *stop))block { [self enumerateRangesWithOptions:0 usingBlock:block]; }
- (void)enumerateRangesInRange:(NSRange)range options:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(NSRange range, BOOL *stop))block
{
    [self enumerateRangesWithOptions:opts usingBlock:^(NSRange r, BOOL *stop) {
        NSRange i = NSIntersectionRange(r, range);
        if (i.length) block(i, stop);
    }];
}

- (NSUInteger)indexPassingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate
{
    __block NSUInteger found = NSNotFound;
    [self enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (predicate(idx, stop)) { found = idx; *stop = YES; }
    }];
    return found;
}

- (NSIndexSet *)indexesPassingTest:(BOOL (NS_NOESCAPE ^)(NSUInteger idx, BOOL *stop))predicate
{
    NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
    [self enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (predicate(idx, stop)) [s addIndex:idx];
    }];
    return [[s copy] autorelease];
}

/* Apple's: "<NSIndexSet: 0x...>[number of indexes: 3 (in 2 ranges), indexes: (1-2 5)]"
 * ("ranges" even for one), or "<NSIndexSet: 0x...>(no indexes)". */
- (NSString *)description
{
    if (!_count) return [NSString stringWithFormat:@"<%s: %p>(no indexes)", object_getClassName(self), self];
    NSMutableString *s = [NSMutableString stringWithFormat:@"<%s: %p>[number of indexes: %lu (in %lu ranges), indexes: (",
        object_getClassName(self), self, (unsigned long)[self count], (unsigned long)_count];
    for (NSUInteger i = 0; i < _count; i++) {
        if (i) [s appendString:@" "];
        if (_ranges[i].length == 1) [s appendFormat:@"%lu", (unsigned long)_ranges[i].location];
        else [s appendFormat:@"%lu-%lu", (unsigned long)_ranges[i].location, (unsigned long)(NSMaxRange(_ranges[i]) - 1)];
    }
    [s appendString:@")]"];
    return s;
}

@end

@implementation NSMutableIndexSet

- (void)_finchReserve:(NSUInteger)n
{
    if (n <= _capacity) return;
    _capacity = MAX(n, _capacity * 2);
    _ranges = realloc(_ranges, _capacity * sizeof(NSRange));
}

- (void)addIndexesInRange:(NSRange)range
{
    if (range.length == 0) return;
    NSUInteger start = range.location, end = NSMaxRange(range);
    /* Ranges that touch or overlap [start, end) merge into one. */
    NSUInteger first = 0;
    while (first < _count && NSMaxRange(_ranges[first]) < start) first++;
    NSUInteger last = first;
    while (last < _count && _ranges[last].location <= end) {
        start = MIN(start, _ranges[last].location);
        end = MAX(end, NSMaxRange(_ranges[last]));
        last++;
    }
    NSUInteger removed = last - first;
    if (removed == 0) {
        [self _finchReserve:_count + 1];
        memmove(_ranges + first + 1, _ranges + first, (_count - first) * sizeof(NSRange));
        _count++;
    } else if (removed > 1) {
        memmove(_ranges + first + 1, _ranges + last, (_count - last) * sizeof(NSRange));
        _count -= removed - 1;
    }
    _ranges[first] = NSMakeRange(start, end - start);
}

- (void)removeIndexesInRange:(NSRange)range
{
    if (range.length == 0) return;
    NSUInteger start = range.location, end = NSMaxRange(range);
    for (NSUInteger i = 0; i < _count;) {
        NSRange r = _ranges[i];
        NSUInteger rs = r.location, re = NSMaxRange(r);
        if (re <= start || rs >= end) { i++; continue; }
        if (rs < start && re > end) {           /* split in two */
            [self _finchReserve:_count + 1];
            memmove(_ranges + i + 1, _ranges + i, (_count - i) * sizeof(NSRange));
            _count++;
            _ranges[i] = NSMakeRange(rs, start - rs);
            _ranges[i + 1] = NSMakeRange(end, re - end);
            return;
        }
        if (rs < start) { _ranges[i].length = start - rs; i++; continue; }
        if (re > end) { _ranges[i] = NSMakeRange(end, re - end); i++; continue; }
        memmove(_ranges + i, _ranges + i + 1, (_count - i - 1) * sizeof(NSRange));
        _count--;
    }
}

- (void)addIndex:(NSUInteger)value { [self addIndexesInRange:NSMakeRange(value, 1)]; }
- (void)removeIndex:(NSUInteger)value { [self removeIndexesInRange:NSMakeRange(value, 1)]; }
- (void)addIndexes:(NSIndexSet *)other
{
    for (NSUInteger i = 0; i < other->_count; i++) [self addIndexesInRange:other->_ranges[i]];
}
- (void)removeIndexes:(NSIndexSet *)other
{
    for (NSUInteger i = 0; i < other->_count; i++) [self removeIndexesInRange:other->_ranges[i]];
}
- (void)removeAllIndexes { _count = 0; }

- (void)shiftIndexesStartingAtIndex:(NSUInteger)index by:(NSInteger)delta
{
    if (delta < 0) [self removeIndexesInRange:NSMakeRange(index + (NSUInteger)delta, (NSUInteger)-delta)];
    NSMutableIndexSet *shifted = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < _count; i++) {
        NSRange r = _ranges[i];
        if (NSMaxRange(r) <= index) { [shifted addIndexesInRange:r]; continue; }
        if (r.location < index) {
            [shifted addIndexesInRange:NSMakeRange(r.location, index - r.location)];
            r = NSMakeRange(index, NSMaxRange(r) - index);
        }
        [shifted addIndexesInRange:NSMakeRange((NSUInteger)((NSInteger)r.location + delta), r.length)];
    }
    free(_ranges);
    _ranges = shifted->_ranges;
    _count = shifted->_count;
    _capacity = shifted->_capacity;
    shifted->_ranges = NULL;
    shifted->_count = shifted->_capacity = 0;
}

- (id)copyWithZone:(NSZone *)zone { return [[NSIndexSet alloc] initWithIndexSet:self]; }

@end

/* MARK: - NSArray with index sets */

@implementation NSArray (FinchIndexSets)

- (NSArray *)objectsAtIndexes:(NSIndexSet *)indexes
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:[indexes count]];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) { [a addObject:[self objectAtIndex:idx]]; }];
    return a;
}

- (NSIndexSet *)indexesOfObjectsPassingTest:(BOOL (NS_NOESCAPE ^)(id obj, NSUInteger idx, BOOL *stop))predicate
{
    NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
    NSUInteger i = 0;
    BOOL stop = NO;
    for (id o in self) {
        if (predicate(o, i, &stop)) [s addIndex:i];
        if (stop) break;
        i++;
    }
    return [[s copy] autorelease];
}

- (void)enumerateObjectsAtIndexes:(NSIndexSet *)s options:(NSEnumerationOptions)opts usingBlock:(void (NS_NOESCAPE ^)(id obj, NSUInteger idx, BOOL *stop))block
{
    [s enumerateIndexesWithOptions:opts usingBlock:^(NSUInteger idx, BOOL *stop) { block([self objectAtIndex:idx], idx, stop); }];
}

@end

@implementation NSMutableArray (FinchIndexSets)

- (void)insertObjects:(NSArray *)objects atIndexes:(NSIndexSet *)indexes
{
    __block NSUInteger i = 0;
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) { [self insertObject:[objects objectAtIndex:i++] atIndex:idx]; }];
}

- (void)removeObjectsAtIndexes:(NSIndexSet *)indexes
{
    [indexes enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) { [self removeObjectAtIndex:idx]; }];
}

- (void)replaceObjectsAtIndexes:(NSIndexSet *)indexes withObjects:(NSArray *)objects
{
    __block NSUInteger i = 0;
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) { [self replaceObjectAtIndex:idx withObject:[objects objectAtIndex:i++]]; }];
}

@end
