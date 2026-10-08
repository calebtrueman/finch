/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSSortDescriptor (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSSortDescriptor.h>, and the collection methods that sort
 * with descriptors. Keys are key paths (KVC); a nil key compares the
 * objects themselves; a nil selector is -compare:. Sorting is stable, as
 * Apple's is.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>

#include "Foundation_Finch.h"

enum {
    ASCENDING = 1,
};

@implementation NSSortDescriptor

+ (instancetype)sortDescriptorWithKey:(NSString *)key ascending:(BOOL)ascending
{
    return [[[self alloc] initWithKey:key ascending:ascending] autorelease];
}

+ (instancetype)sortDescriptorWithKey:(NSString *)key ascending:(BOOL)ascending selector:(SEL)selector
{
    return [[[self alloc] initWithKey:key ascending:ascending selector:selector] autorelease];
}

+ (instancetype)sortDescriptorWithKey:(NSString *)key ascending:(BOOL)ascending comparator:(NSComparator)cmptr
{
    return [[[self alloc] initWithKey:key ascending:ascending comparator:cmptr] autorelease];
}

- (instancetype)initWithKey:(NSString *)key ascending:(BOOL)ascending
{
    return [self initWithKey:key ascending:ascending selector:@selector(compare:)];
}

- (instancetype)initWithKey:(NSString *)key ascending:(BOOL)ascending selector:(SEL)selector
{
    if ((self = [super init])) {
        _key = [key copy];
        _sortDescriptorFlags = ascending ? ASCENDING : 0;
        _selector = selector ? selector : @selector(compare:);
    }
    return self;
}

- (instancetype)initWithKey:(NSString *)key ascending:(BOOL)ascending comparator:(NSComparator)cmptr
{
    if ((self = [super init])) {
        _key = [key copy];
        _sortDescriptorFlags = ascending ? ASCENDING : 0;
        _selectorOrBlock = [cmptr copy];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *sel = [coder decodeObjectOfClass:[NSString class] forKey:@"Selector"];
    return [self initWithKey:[coder decodeObjectOfClass:[NSString class] forKey:@"Key"] ascending:[coder decodeBoolForKey:@"Ascending"]
        selector:sel ? NSSelectorFromString(sel) : NULL];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_key) [coder encodeObject:_key forKey:@"Key"];
    [coder encodeBool:[self ascending] forKey:@"Ascending"];
    if (_selector) [coder encodeObject:NSStringFromSelector(_selector) forKey:@"Selector"];
}

+ (BOOL)supportsSecureCoding { return YES; }
- (void)allowEvaluation { }

- (NSString *)key { return _key; }
- (BOOL)ascending { return (_sortDescriptorFlags & ASCENDING) != 0; }
- (SEL)selector { return _selectorOrBlock ? NULL : _selector; }
- (NSComparator)comparator
{
    if (_selectorOrBlock) return _selectorOrBlock;
    SEL sel = _selector;
    return [[^NSComparisonResult(id a, id b) { return ((NSComparisonResult (*)(id, SEL, id))objc_msgSend)(a, sel, b); } copy] autorelease];
}

- (NSComparisonResult)compareObject:(id)object1 toObject:(id)object2
{
    id a = _key ? [object1 valueForKeyPath:_key] : object1;
    id b = _key ? [object2 valueForKeyPath:_key] : object2;
    NSComparisonResult r;
    if (_selectorOrBlock) r = ((NSComparator)_selectorOrBlock)(a, b);
    else if (!a) r = b ? NSOrderedAscending : NSOrderedSame;
    else r = ((NSComparisonResult (*)(id, SEL, id))objc_msgSend)(a, _selector, b);
    return [self ascending] ? r : (NSComparisonResult)-r;
}

- (id)reversedSortDescriptor
{
    if (_selectorOrBlock) return [[[NSSortDescriptor alloc] initWithKey:_key ascending:![self ascending] comparator:_selectorOrBlock] autorelease];
    return [[[NSSortDescriptor alloc] initWithKey:_key ascending:![self ascending] selector:_selector] autorelease];
}

/* Apple's: "(name, ascending, NO, compare:)", or BLOCK(0x...) for a comparator. */
- (NSString *)description
{
    NSString *how = _selectorOrBlock ? [NSString stringWithFormat:@"BLOCK(%p)", _selectorOrBlock] : NSStringFromSelector(_selector);
    return [NSString stringWithFormat:@"(%@, %s, NO, %@)", _key ? _key : @"", [self ascending] ? "ascending" : "descending", how];
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSSortDescriptor class]]) return NO;
    NSSortDescriptor *o = other;
    return [self ascending] == [o ascending] && (_key == o->_key || [_key isEqual:o->_key]) && _selector == o->_selector &&
        _selectorOrBlock == o->_selectorOrBlock;
}

- (NSUInteger)hash { return [_key hash] ^ (_selector ? (NSUInteger)(uintptr_t)sel_getName(_selector) : 0) ^ [self ascending]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (void)dealloc
{
    [_key release];
    [_selectorOrBlock release];
    [super dealloc];
}

@end

static NSComparisonResult
compare_descriptors(NSArray *descriptors, id a, id b)
{
    for (NSSortDescriptor *d in descriptors) {
        NSComparisonResult r = [d compareObject:a toObject:b];
        if (r != NSOrderedSame) return r;
    }
    return NSOrderedSame;
}

@implementation NSArray (NSSortDescriptorSorting)

- (NSArray *)sortedArrayUsingDescriptors:(NSArray<NSSortDescriptor *> *)sortDescriptors
{
    return [self sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(id a, id b) {
        return compare_descriptors(sortDescriptors, a, b);
    }];
}

@end

@implementation NSMutableArray (NSSortDescriptorSorting)

- (void)sortUsingDescriptors:(NSArray<NSSortDescriptor *> *)sortDescriptors
{
    [self sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(id a, id b) {
        return compare_descriptors(sortDescriptors, a, b);
    }];
}

@end

@implementation NSSet (NSSortDescriptorSorting)

- (NSArray *)sortedArrayUsingDescriptors:(NSArray<NSSortDescriptor *> *)sortDescriptors
{
    return [[self allObjects] sortedArrayUsingDescriptors:sortDescriptors];
}

@end
