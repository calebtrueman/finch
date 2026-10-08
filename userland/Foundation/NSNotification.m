/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSNotification and NSNotificationCenter (docs/design/FOUNDATION.md),
 * against the SDK's declarations. Notifications are NSConcreteNotification
 * (Apple's class name). The center keeps its observers in posting order;
 * selector observers are held weakly, so an observer that goes away stops
 * receiving (as on macOS since 10.11, which needs no -removeObserver:).
 * Posting matches under the lock, then delivers outside it, so observers
 * may post or remove observers themselves.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

extern id objc_loadWeakRetained(id *location);
extern id objc_initWeak(id *location, id value);
extern void objc_destroyWeak(id *location);

@interface NSConcreteNotification : NSNotification {
    NSString *_name;
    id _object;
    NSDictionary *_userInfo;
}
@end

@implementation NSNotification

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSNotification class]) return [NSConcreteNotification allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (instancetype)notificationWithName:(NSNotificationName)aName object:(id)anObject
{
    return [self notificationWithName:aName object:anObject userInfo:nil];
}

+ (instancetype)notificationWithName:(NSNotificationName)aName object:(id)anObject userInfo:(NSDictionary *)aUserInfo
{
    return [[[self alloc] initWithName:aName object:anObject userInfo:aUserInfo] autorelease];
}

- (instancetype)initWithName:(NSNotificationName)name object:(id)object userInfo:(NSDictionary *)userInfo
{
    return [super init];
}

- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)coder { }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (NSNotificationName)name { FinchAbstract(self, _cmd); }
- (id)object { FinchAbstract(self, _cmd); }
- (NSDictionary *)userInfo { FinchAbstract(self, _cmd); }

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ %p {name = %@%@%@}", NSStringFromClass([self class]), self, [self name],
        [self object] ? [NSString stringWithFormat:@"; object = %@", [self object]] : @"",
        [self userInfo] ? [NSString stringWithFormat:@"; userInfo = %@", [self userInfo]] : @""];
}

@end

@implementation NSConcreteNotification

- (instancetype)initWithName:(NSNotificationName)name object:(id)object userInfo:(NSDictionary *)userInfo
{
    if ((self = [super initWithName:name object:object userInfo:userInfo])) {
        _name = [name copy];
        _object = [object retain];
        _userInfo = [userInfo copy];
    }
    return self;
}

- (void)dealloc
{
    [_name release];
    [_object release];
    [_userInfo release];
    [super dealloc];
}

- (NSNotificationName)name { return _name; }
- (id)object { return _object; }
- (NSDictionary *)userInfo { return _userInfo; }

@end

/* MARK: - The center */

/* One registration: a weakly held observer and selector, or a block (and
 * queue). The entry itself is what -addObserverForName:... returns. */
@interface __NSObserver : NSObject {
@public
    id _observer;               /* weak */
    BOOL _usesObserver;
    SEL _selector;
    NSString *_name;
    id _object;                 /* compared by identity, never messaged */
    void (^_block)(NSNotification *);
    NSOperationQueue *_queue;
}
@end

@implementation __NSObserver
- (void)dealloc
{
    if (_usesObserver) objc_destroyWeak(&_observer);
    [_name release];
    [_block release];
    [_queue release];
    [super dealloc];
}
@end

@implementation NSNotificationCenter {
    NSMutableArray *_observers;
    NSRecursiveLock *_lock;
}

+ (NSNotificationCenter *)defaultCenter
{
    static NSNotificationCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [[NSNotificationCenter alloc] init]; });
    return center;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _observers = [[NSMutableArray alloc] init];
        _lock = [[NSRecursiveLock alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_observers release];
    [_lock release];
    [super dealloc];
}

- (void)addObserver:(id)observer selector:(SEL)aSelector name:(NSNotificationName)aName object:(id)anObject
{
    if (!observer) return;
    __NSObserver *o = [[__NSObserver alloc] init];
    o->_usesObserver = YES;
    objc_initWeak(&o->_observer, observer);
    o->_selector = aSelector;
    o->_name = [aName copy];
    o->_object = anObject;
    [_lock lock];
    [_observers addObject:o];
    [_lock unlock];
    [o release];
}

- (id<NSObject>)addObserverForName:(NSNotificationName)name object:(id)obj queue:(NSOperationQueue *)queue
                        usingBlock:(void (^)(NSNotification *notification))block
{
    __NSObserver *o = [[[__NSObserver alloc] init] autorelease];
    o->_name = [name copy];
    o->_object = obj;
    o->_block = [block copy];
    o->_queue = [queue retain];
    [_lock lock];
    [_observers addObject:o];
    [_lock unlock];
    return o;
}

- (void)removeObserver:(id)observer name:(NSNotificationName)aName object:(id)anObject
{
    if (!observer) return;
    [_lock lock];
    for (NSInteger i = (NSInteger)[_observers count] - 1; i >= 0; i--) {
        __NSObserver *o = [_observers objectAtIndex:(NSUInteger)i];
        id who = o->_usesObserver ? objc_loadWeakRetained(&o->_observer) : nil;
        BOOL match = (o == observer || who == observer || (o->_usesObserver && !who)) &&
            (!aName || [aName isEqualToString:o->_name]) && (!anObject || anObject == o->_object);
        [who release];
        if (match) [_observers removeObjectAtIndex:(NSUInteger)i];
    }
    [_lock unlock];
}

- (void)removeObserver:(id)observer { [self removeObserver:observer name:nil object:nil]; }

- (void)postNotification:(NSNotification *)notification
{
    if (!notification)
        FinchRaise(NSInvalidArgumentException, "*** -[NSNotificationCenter postNotification:]: notification is nil");
    NSString *name = [notification name];
    id object = [notification object];
    NSMutableArray *targets = [NSMutableArray array];
    [_lock lock];
    for (__NSObserver *o in _observers)
        if ((!o->_name || [o->_name isEqualToString:name]) && (!o->_object || o->_object == object)) [targets addObject:o];
    [_lock unlock];
    for (__NSObserver *o in targets) {
        if (o->_usesObserver) {
            id who = objc_loadWeakRetained(&o->_observer);
            if (who) ((void (*)(id, SEL, id))objc_msgSend)(who, o->_selector, notification);
            [who release];
        } else if (o->_queue && o->_queue != [NSOperationQueue currentQueue]) {
            void (^b)(NSNotification *) = o->_block;
            NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{ b(notification); }];
            [o->_queue addOperations:@[ op ] waitUntilFinished:YES];
        } else {
            o->_block(notification);
        }
    }
}

- (void)postNotificationName:(NSNotificationName)aName object:(id)anObject
{
    [self postNotification:[NSNotification notificationWithName:aName object:anObject userInfo:nil]];
}

- (void)postNotificationName:(NSNotificationName)aName object:(id)anObject userInfo:(NSDictionary *)aUserInfo
{
    [self postNotification:[NSNotification notificationWithName:aName object:anObject userInfo:aUserInfo]];
}

@end
