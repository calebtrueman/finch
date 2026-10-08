/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSCache (docs/design/FOUNDATION.md), against the SDK's <Foundation/NSCache.h>.
 * It lives in CoreFoundation, as Apple's does. Entries are evicted least
 * recently used first when the count or cost limit is passed, and objects
 * whose discardable content is gone are dropped on access; the delegate
 * hears of each removal.
 */
#include "CFObjCClasses_Finch.h"

@protocol NSCacheDelegate <NSObject>
@optional
- (void)cache:(id)cache willEvictObject:(id)obj;
@end
@protocol NSDiscardableContent
- (BOOL)beginContentAccess;
- (void)endContentAccess;
- (void)discardContentIfPossible;
- (BOOL)isContentDiscarded;
@end

@interface NSCache : NSObject
@end
#include <pthread.h>


@interface _NSCacheEntry : NSObject {
@public
    id object;
    NSUInteger cost;
    unsigned long long used;
}
@end
@implementation _NSCacheEntry
- (void)dealloc { [object release]; [super dealloc]; }
@end

@implementation NSCache {
    id _name;
    id<NSCacheDelegate> _delegate;
    CFMutableDictionaryRef _entries;   /* key (retained, -isEqual:) -> _NSCacheEntry */
    NSUInteger _totalCost, _totalCostLimit, _countLimit;
    unsigned long long _clock;
    BOOL _evicts;
    pthread_mutex_t _mutex;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _entries = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        _evicts = YES;
        pthread_mutex_init(&_mutex, NULL);
    }
    return self;
}

- (void)dealloc
{
    CFRelease(_entries);
    [_name release];
    pthread_mutex_destroy(&_mutex);
    [super dealloc];
}

- (id)name { return _name ? _name : (id)CFSTR(""); }
- (void)setName:(id)name { [_name release]; _name = [name copy]; }
- (id<NSCacheDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSCacheDelegate>)delegate { _delegate = delegate; }
- (NSUInteger)totalCostLimit { return _totalCostLimit; }
- (void)setTotalCostLimit:(NSUInteger)limit { _totalCostLimit = limit; [self evict]; }
- (NSUInteger)countLimit { return _countLimit; }
- (void)setCountLimit:(NSUInteger)limit { _countLimit = limit; [self evict]; }
- (BOOL)evictsObjectsWithDiscardedContent { return _evicts; }
- (void)setEvictsObjectsWithDiscardedContent:(BOOL)flag { _evicts = flag; }

/* Remove an entry, telling the delegate first. Called with the lock held;
 * the delegate is told without it. */
- (void)removeKey:(id)key entry:(_NSCacheEntry *)e evicting:(BOOL)evicting
{
    [[e retain] autorelease];
    _totalCost -= MIN(_totalCost, e->cost);
    CFDictionaryRemoveValue(_entries, key);
    if (_delegate && [_delegate respondsToSelector:@selector(cache:willEvictObject:)]) {
        pthread_mutex_unlock(&_mutex);
        [_delegate cache:self willEvictObject:e->object];
        pthread_mutex_lock(&_mutex);
    }
}

/* Least recently used first, until within the limits. */
- (void)evict
{
    pthread_mutex_lock(&_mutex);
    while ((_countLimit && (NSUInteger)CFDictionaryGetCount(_entries) > _countLimit) || (_totalCostLimit && _totalCost > _totalCostLimit)) {
        CFIndex n = CFDictionaryGetCount(_entries);
        if (!n) break;
        const void **keys = malloc((size_t)n * sizeof(void *)), **vals = malloc((size_t)n * sizeof(void *));
        CFDictionaryGetKeysAndValues(_entries, keys, vals);
        CFIndex oldest = 0;
        for (CFIndex i = 1; i < n; i++)
            if (((_NSCacheEntry *)vals[i])->used < ((_NSCacheEntry *)vals[oldest])->used) oldest = i;
        id key = [[(id)keys[oldest] retain] autorelease];
        _NSCacheEntry *e = (id)vals[oldest];
        free(keys);
        free(vals);
        [self removeKey:key entry:e evicting:YES];
    }
    pthread_mutex_unlock(&_mutex);
}

- (id)objectForKey:(id)key
{
    if (!key) return nil;
    pthread_mutex_lock(&_mutex);
    _NSCacheEntry *e = (id)CFDictionaryGetValue(_entries, key);
    id o = nil;
    if (e) {
        if (_evicts && [e->object conformsToProtocol:@protocol(NSDiscardableContent)] && [e->object isContentDiscarded]) {
            [self removeKey:key entry:e evicting:YES];
        } else {
            e->used = ++_clock;
            o = [[e->object retain] autorelease];
        }
    }
    pthread_mutex_unlock(&_mutex);
    return o;
}

- (void)setObject:(id)obj forKey:(id)key { [self setObject:obj forKey:key cost:0]; }

- (void)setObject:(id)obj forKey:(id)key cost:(NSUInteger)g
{
    if (!key) return;
    if (!obj) { [self removeObjectForKey:key]; return; }
    _NSCacheEntry *e = [[[_NSCacheEntry alloc] init] autorelease];
    e->object = [obj retain];
    e->cost = g;
    pthread_mutex_lock(&_mutex);
    e->used = ++_clock;
    _NSCacheEntry *old = (id)CFDictionaryGetValue(_entries, key);
    if (old) _totalCost -= MIN(_totalCost, old->cost);
    CFDictionarySetValue(_entries, key, e);
    _totalCost += g;
    pthread_mutex_unlock(&_mutex);
    [self evict];
}

- (void)removeObjectForKey:(id)key
{
    if (!key) return;
    pthread_mutex_lock(&_mutex);
    _NSCacheEntry *e = (id)CFDictionaryGetValue(_entries, key);
    if (e) [self removeKey:key entry:e evicting:NO];
    pthread_mutex_unlock(&_mutex);
}

- (void)removeAllObjects
{
    pthread_mutex_lock(&_mutex);
    CFIndex n = CFDictionaryGetCount(_entries);
    const void **keys = malloc(((size_t)n + 1) * sizeof(void *)), **vals = malloc(((size_t)n + 1) * sizeof(void *));
    CFDictionaryGetKeysAndValues(_entries, keys, vals);
    CFArrayRef k = CFArrayCreate(NULL, keys, n, &kCFTypeArrayCallBacks), v = CFArrayCreate(NULL, vals, n, &kCFTypeArrayCallBacks);
    free(keys);
    free(vals);
    for (CFIndex i = 0; i < n; i++) [self removeKey:(id)CFArrayGetValueAtIndex(k, i) entry:(id)CFArrayGetValueAtIndex(v, i) evicting:NO];
    CFRelease(k);
    CFRelease(v);
    pthread_mutex_unlock(&_mutex);
}

@end
