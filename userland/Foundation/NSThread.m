/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSThread, the NSLock family, and NSObject's -performSelector:... methods
 * (docs/design/FOUNDATION.md), against the SDK's declarations.
 *
 * An NSThread is a pthread. Each thread's NSThread object is found through
 * thread-specific storage (made on first use for threads Foundation didn't
 * start), and remembers its CFRunLoop, where -performSelector:onThread:
 * delivers. Delayed performs are timers on the current run loop, kept in a
 * table per target so they can be cancelled.
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <execinfo.h>
#include <pthread.h>
#include <unistd.h>

#include "Foundation_Finch.h"

extern pthread_t pthread_main_thread_np(void);   /* libpthread; no public declaration */

NSNotificationName const NSWillBecomeMultiThreadedNotification = @"NSWillBecomeMultiThreadedNotification";
NSNotificationName const NSDidBecomeSingleThreadedNotification = @"NSDidBecomeSingleThreadedNotification";
NSNotificationName const NSThreadWillExitNotification = @"NSThreadWillExitNotification";

/* MARK: - NSThread */

@implementation NSThread {
    pthread_t _pthread;
    CFRunLoopRef _runLoop;
    id _target;
    SEL _selector;
    id _argument;
    void (^_block)(void);
    NSString *_name;
    NSMutableDictionary *_dictionary;
    NSUInteger _stackSize;
    NSQualityOfService _qos;
    double _priority;
    BOOL _started, _executing, _finished, _cancelled, _isMain;
}

static pthread_key_t threadKey;
static NSThread *mainThread;
static BOOL multiThreaded;

static void
thread_gone(void *p)
{
    [(id)p release];
}

+ (void)initialize
{
    if (self != [NSThread class]) return;
    pthread_key_create(&threadKey, thread_gone);
    mainThread = [[NSThread alloc] init];
    mainThread->_isMain = YES;
    mainThread->_started = mainThread->_executing = YES;
    mainThread->_pthread = pthread_main_thread_np();
    mainThread->_runLoop = CFRunLoopGetMain();
    mainThread->_name = @"main";
}

+ (NSThread *)currentThread
{
    if (pthread_main_np()) return [self mainThread];
    NSThread *t = pthread_getspecific(threadKey);
    if (!t) {   /* a thread Foundation didn't start */
        t = [[NSThread alloc] init];
        t->_started = t->_executing = YES;
        t->_pthread = pthread_self();
        t->_runLoop = CFRunLoopGetCurrent();
        pthread_setspecific(threadKey, t);
    }
    return t;
}

+ (NSThread *)mainThread { [self class]; return mainThread; }
+ (BOOL)isMainThread { return pthread_main_np() != 0; }
- (BOOL)isMainThread { return _isMain; }
+ (BOOL)isMultiThreaded { return multiThreaded; }

- (instancetype)init
{
    if ((self = [super init])) {
        _priority = 0.5;
        _qos = NSQualityOfServiceDefault;
    }
    return self;
}

- (instancetype)initWithTarget:(id)target selector:(SEL)selector object:(id)argument
{
    if ((self = [self init])) {
        _target = [target retain];
        _selector = selector;
        _argument = [argument retain];
    }
    return self;
}

- (instancetype)initWithBlock:(void (^)(void))block
{
    if ((self = [self init])) _block = [block copy];
    return self;
}

- (void)dealloc
{
    [_target release];
    [_argument release];
    [_block release];
    [_name release];
    [_dictionary release];
    [super dealloc];
}

+ (void)detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)argument
{
    NSThread *t = [[NSThread alloc] initWithTarget:target selector:selector object:argument];
    [t start];
    [t release];
}

+ (void)detachNewThreadWithBlock:(void (^)(void))block
{
    NSThread *t = [[NSThread alloc] initWithBlock:block];
    [t start];
    [t release];
}

static void *
thread_entry(void *p)
{
    NSThread *t = p;   /* retained by -start, released by thread_gone */
    pthread_setspecific(threadKey, t);
    t->_runLoop = CFRunLoopGetCurrent();
    if (t->_name) pthread_setname_np([t->_name UTF8String]);
    @autoreleasepool {
        [t main];
    }
    [NSThread exit];
    return NULL;
}

- (void)start
{
    if (_started)
        FinchRaise(NSInvalidArgumentException, "*** -[NSThread start]: attempt to start the thread again");
    if (_cancelled) {
        _finished = YES;
        return;
    }
    _started = _executing = YES;
    if (!multiThreaded) {
        multiThreaded = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWillBecomeMultiThreadedNotification object:nil];
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (_stackSize) pthread_attr_setstacksize(&attr, _stackSize);
    [self retain];
    if (pthread_create(&_pthread, &attr, thread_entry, self) != 0) {
        _executing = NO;
        [self release];
        FinchRaise(NSInternalInconsistencyException, "*** -[NSThread start]: Thread creation failed");
    }
    pthread_attr_destroy(&attr);
}

- (void)main
{
    if (_block) _block();
    else if (_target) ((void (*)(id, SEL, id))objc_msgSend)(_target, _selector, _argument);
}

+ (void)exit
{
    NSThread *t = [NSThread currentThread];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSThreadWillExitNotification object:t];
    t->_executing = NO;
    t->_finished = YES;
    if (t->_isMain) exit(0);
    pthread_exit(NULL);
}

+ (void)sleepUntilDate:(NSDate *)date { [self sleepForTimeInterval:[date timeIntervalSinceNow]]; }

+ (void)sleepForTimeInterval:(NSTimeInterval)ti
{
    if (ti <= 0) return;
    struct timespec ts = { (time_t)ti, (long)((ti - (time_t)ti) * 1e9) };
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR)
        ;
}

- (BOOL)isExecuting { return _executing; }
- (BOOL)isFinished { return _finished; }
- (BOOL)isCancelled { return _cancelled; }
- (void)cancel { _cancelled = YES; }

- (NSString *)name { return _name; }
- (void)setName:(NSString *)newName
{
    NSString *old = _name;
    _name = [newName copy];
    [old release];
    if (pthread_equal(_pthread, pthread_self())) pthread_setname_np(_name ? [_name UTF8String] : "");
}

- (NSMutableDictionary *)threadDictionary
{
    if (!_dictionary) _dictionary = [[NSMutableDictionary alloc] init];
    return _dictionary;
}

- (NSUInteger)stackSize { return _stackSize ? _stackSize : 512 * 1024; }
- (void)setStackSize:(NSUInteger)s { _stackSize = s; }
- (NSQualityOfService)qualityOfService { return _qos; }
- (void)setQualityOfService:(NSQualityOfService)q { _qos = q; }
- (double)threadPriority { return _priority; }
- (void)setThreadPriority:(double)p { _priority = p; }
+ (double)threadPriority { return [[self currentThread] threadPriority]; }
+ (BOOL)setThreadPriority:(double)p { [[self currentThread] setThreadPriority:p]; return YES; }

+ (NSArray<NSNumber *> *)callStackReturnAddresses
{
    void *frames[128];
    int n = backtrace(frames, 128);
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 1; i < n; i++) [a addObject:[NSNumber numberWithUnsignedLongLong:(unsigned long long)(uintptr_t)frames[i]]];
    return a;
}

+ (NSArray<NSString *> *)callStackSymbols
{
    void *frames[128];
    int n = backtrace(frames, 128);
    char **syms = backtrace_symbols(frames, n);
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 1; i < n && syms; i++) [a addObject:[NSString stringWithUTF8String:syms[i]]];
    free(syms);
    return a;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s: %p>{number = %llu, name = %@}", object_getClassName(self), self,
        (unsigned long long)(_isMain ? 1 : (uintptr_t)_pthread % 100000), _name ? _name : @"(null)"];
}

/* The run loop -performSelector:onThread: delivers to (nil until the thread runs). */
- (CFRunLoopRef)_finchRunLoop { return _runLoop; }

@end

/* MARK: - Locks */

#define LOCK_NAME \
    - (NSString *)name { return _name; } \
    - (void)setName:(NSString *)n { NSString *o = _name; _name = [n copy]; [o release]; }

static struct timespec
deadline(NSDate *limit)
{
    NSTimeInterval t = [limit timeIntervalSince1970];
    if (t > 1e11) t = 1e11;
    struct timespec ts = { (time_t)t, (long)((t - (time_t)t) * 1e9) };
    return ts;
}

@implementation NSLock {
    pthread_mutex_t _m;
    NSString *_name;
}
LOCK_NAME
- (instancetype)init { if ((self = [super init])) pthread_mutex_init(&_m, NULL); return self; }
- (void)dealloc { pthread_mutex_destroy(&_m); [_name release]; [super dealloc]; }
- (void)lock { pthread_mutex_lock(&_m); }
- (void)unlock { pthread_mutex_unlock(&_m); }
- (BOOL)tryLock { return pthread_mutex_trylock(&_m) == 0; }
- (BOOL)lockBeforeDate:(NSDate *)limit
{
    while (pthread_mutex_trylock(&_m) != 0) {
        if ([limit timeIntervalSinceNow] <= 0) return NO;
        usleep(1000);
    }
    return YES;
}
@end

@implementation NSRecursiveLock {
    pthread_mutex_t _m;
    NSString *_name;
}
LOCK_NAME
- (instancetype)init
{
    if ((self = [super init])) {
        pthread_mutexattr_t a;
        pthread_mutexattr_init(&a);
        pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_m, &a);
        pthread_mutexattr_destroy(&a);
    }
    return self;
}
- (void)dealloc { pthread_mutex_destroy(&_m); [_name release]; [super dealloc]; }
- (void)lock { pthread_mutex_lock(&_m); }
- (void)unlock { pthread_mutex_unlock(&_m); }
- (BOOL)tryLock { return pthread_mutex_trylock(&_m) == 0; }
- (BOOL)lockBeforeDate:(NSDate *)limit
{
    while (pthread_mutex_trylock(&_m) != 0) {
        if ([limit timeIntervalSinceNow] <= 0) return NO;
        usleep(1000);
    }
    return YES;
}
@end

@implementation NSCondition {
    pthread_mutex_t _m;
    pthread_cond_t _c;
    NSString *_name;
}
LOCK_NAME
- (instancetype)init
{
    if ((self = [super init])) {
        pthread_mutex_init(&_m, NULL);
        pthread_cond_init(&_c, NULL);
    }
    return self;
}
- (void)dealloc { pthread_cond_destroy(&_c); pthread_mutex_destroy(&_m); [_name release]; [super dealloc]; }
- (void)lock { pthread_mutex_lock(&_m); }
- (void)unlock { pthread_mutex_unlock(&_m); }
- (void)wait { pthread_cond_wait(&_c, &_m); }
- (BOOL)waitUntilDate:(NSDate *)limit
{
    struct timespec ts = deadline(limit);
    return pthread_cond_timedwait(&_c, &_m, &ts) == 0;
}
- (void)signal { pthread_cond_signal(&_c); }
- (void)broadcast { pthread_cond_broadcast(&_c); }
@end

@implementation NSConditionLock {
    NSCondition *_cond;
    NSInteger _condition;
    pthread_t _owner;
    NSString *_name;
}
LOCK_NAME
- (instancetype)init { return [self initWithCondition:0]; }
- (instancetype)initWithCondition:(NSInteger)condition
{
    if ((self = [super init])) {
        _cond = [[NSCondition alloc] init];
        _condition = condition;
    }
    return self;
}
- (void)dealloc { [_cond release]; [_name release]; [super dealloc]; }
- (NSInteger)condition { return _condition; }
- (void)lock { [self lockBeforeDate:[NSDate distantFuture]]; }
- (BOOL)tryLock { return [self lockBeforeDate:[NSDate distantPast]]; }
- (BOOL)lockBeforeDate:(NSDate *)limit
{
    [_cond lock];
    while (_owner) {
        if (![_cond waitUntilDate:limit]) { [_cond unlock]; return NO; }
    }
    _owner = pthread_self();
    [_cond unlock];
    return YES;
}
- (void)lockWhenCondition:(NSInteger)c { [self lockWhenCondition:c beforeDate:[NSDate distantFuture]]; }
- (BOOL)tryLockWhenCondition:(NSInteger)c { return [self lockWhenCondition:c beforeDate:[NSDate distantPast]]; }
- (BOOL)lockWhenCondition:(NSInteger)c beforeDate:(NSDate *)limit
{
    [_cond lock];
    while (_owner || _condition != c) {
        if (![_cond waitUntilDate:limit]) { [_cond unlock]; return NO; }
    }
    _owner = pthread_self();
    [_cond unlock];
    return YES;
}
- (void)unlock { [self unlockWithCondition:_condition]; }
- (void)unlockWithCondition:(NSInteger)c
{
    [_cond lock];
    _owner = NULL;
    _condition = c;
    [_cond broadcast];
    [_cond unlock];
}
@end

/* MARK: - Performing selectors */

@interface NSThread (FinchRunLoop)
- (CFRunLoopRef)_finchRunLoop;
@end

/* Delayed performs, per target, so they can be cancelled: target -> array of
 * timers. The timers' blocks hold the target and argument. */
static NSMutableDictionary *delayed;
static NSLock *delayedLock;

@interface __NSDelayedPerform : NSObject {
@public
    id target;
    SEL selector;
    id argument;
}
@end
@implementation __NSDelayedPerform
- (void)dealloc { [target release]; [argument release]; [super dealloc]; }
@end

static NSValue *
key_for(id target)
{
    return [NSValue valueWithPointer:target];
}

@implementation NSObject (NSDelayedPerforming)

- (void)performSelector:(SEL)aSelector withObject:(id)anArgument afterDelay:(NSTimeInterval)delay inModes:(NSArray<NSRunLoopMode> *)modes
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        delayed = [[NSMutableDictionary alloc] init];
        delayedLock = [[NSLock alloc] init];
    });
    __NSDelayedPerform *p = [[[__NSDelayedPerform alloc] init] autorelease];
    p->target = [self retain];
    p->selector = aSelector;
    p->argument = [anArgument retain];
    NSValue *key = key_for(self);
    NSTimer *timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
        [delayedLock lock];
        NSMutableArray *list = [delayed objectForKey:key];
        [[p retain] autorelease];
        [list removeObjectIdenticalTo:t];
        if ([list count] == 0) [delayed removeObjectForKey:key];
        [delayedLock unlock];
        ((void (*)(id, SEL, id))objc_msgSend)(p->target, p->selector, p->argument);
    }];
    objc_setAssociatedObject(timer, (void *)&delayed, p, OBJC_ASSOCIATION_RETAIN);
    [delayedLock lock];
    NSMutableArray *list = [delayed objectForKey:key];
    if (!list) {
        list = [NSMutableArray array];
        [delayed setObject:list forKey:key];
    }
    [list addObject:timer];
    [delayedLock unlock];
    for (NSRunLoopMode mode in modes) [[NSRunLoop currentRunLoop] addTimer:timer forMode:mode];
}

- (void)performSelector:(SEL)aSelector withObject:(id)anArgument afterDelay:(NSTimeInterval)delay
{
    [self performSelector:aSelector withObject:anArgument afterDelay:delay inModes:@[ NSDefaultRunLoopMode ]];
}

static void
cancel(id target, BOOL all, SEL sel, id arg)
{
    if (!delayed) return;
    [delayedLock lock];
    NSValue *key = key_for(target);
    NSMutableArray *list = [delayed objectForKey:key];
    for (NSTimer *t in [[list copy] autorelease]) {
        __NSDelayedPerform *p = objc_getAssociatedObject(t, (void *)&delayed);
        if (all || (p->selector == sel && (p->argument == arg || [p->argument isEqual:arg]))) {
            [t invalidate];
            [list removeObjectIdenticalTo:t];
        }
    }
    if (list && [list count] == 0) [delayed removeObjectForKey:key];
    [delayedLock unlock];
}

+ (void)cancelPreviousPerformRequestsWithTarget:(id)aTarget { cancel(aTarget, YES, NULL, nil); }
+ (void)cancelPreviousPerformRequestsWithTarget:(id)aTarget selector:(SEL)aSelector object:(id)anArgument
{
    cancel(aTarget, NO, aSelector, anArgument);
}

@end

@implementation NSObject (NSThreadPerformAdditions)

- (void)performSelector:(SEL)aSelector onThread:(NSThread *)thr withObject:(id)arg waitUntilDone:(BOOL)wait modes:(NSArray<NSString *> *)array
{
    if (wait && thr == [NSThread currentThread]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, aSelector, arg);
        return;
    }
    CFRunLoopRef rl = [thr _finchRunLoop];
    if (!rl) FinchRaise(NSInternalInconsistencyException, "*** -[NSObject performSelector:onThread:...]: target thread has no run loop");
    dispatch_semaphore_t done = wait ? dispatch_semaphore_create(0) : NULL;
    [self retain];
    [arg retain];
    CFRunLoopPerformBlock(rl, (CFTypeRef)(array ? array : @[ NSDefaultRunLoopMode ]), ^{
        ((void (*)(id, SEL, id))objc_msgSend)(self, aSelector, arg);
        [arg release];
        [self release];
        if (done) dispatch_semaphore_signal(done);
    });
    CFRunLoopWakeUp(rl);
    if (done) {
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        dispatch_release(done);
    }
}

- (void)performSelector:(SEL)aSelector onThread:(NSThread *)thr withObject:(id)arg waitUntilDone:(BOOL)wait
{
    [self performSelector:aSelector onThread:thr withObject:arg waitUntilDone:wait modes:@[ NSDefaultRunLoopMode ]];
}

- (void)performSelectorOnMainThread:(SEL)aSelector withObject:(id)arg waitUntilDone:(BOOL)wait modes:(NSArray<NSString *> *)array
{
    [self performSelector:aSelector onThread:[NSThread mainThread] withObject:arg waitUntilDone:wait modes:array];
}

- (void)performSelectorOnMainThread:(SEL)aSelector withObject:(id)arg waitUntilDone:(BOOL)wait
{
    [self performSelectorOnMainThread:aSelector withObject:arg waitUntilDone:wait modes:@[ NSRunLoopCommonModes ]];
}

- (void)performSelectorInBackground:(SEL)aSelector withObject:(id)arg
{
    [NSThread detachNewThreadSelector:aSelector toTarget:self withObject:arg];
}

@end
