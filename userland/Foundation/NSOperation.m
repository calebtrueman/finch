/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSOperation, NSBlockOperation, NSInvocationOperation and NSOperationQueue
 * (docs/design/FOUNDATION.md), against the SDK's declarations, on
 * libdispatch. A queue runs each operation once its dependencies have
 * finished, on a dispatch queue, at most maxConcurrentOperationCount at a
 * time (1: in order). +mainQueue runs on the main dispatch queue.
 *
 * Not yet: asynchronous ("concurrent") operations that report finishing
 * through KVO of isFinished, which waits for Finch's KVO; such an operation
 * is treated as finished when -start returns.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dispatch/dispatch.h>
#include <pthread.h>

#include "Foundation_Finch.h"

/* MARK: - NSOperation */

@implementation NSOperation {
@package
    NSMutableArray *_dependencies;
    NSMutableArray *_waiters;           /* operations that depend on this one */
    void (^_completion)(void);
    NSString *_name;
    NSOperationQueuePriority _priority;
    NSQualityOfService _qos;
    dispatch_group_t _done;
    pthread_mutex_t _lock;
    __weak NSOperationQueue *_queue;
    BOOL _executing, _finished, _cancelled, _enqueued;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _dependencies = [[NSMutableArray alloc] init];
        _waiters = [[NSMutableArray alloc] init];
        _done = dispatch_group_create();
        dispatch_group_enter(_done);
        pthread_mutex_init(&_lock, NULL);
        _qos = NSQualityOfServiceDefault;
    }
    return self;
}

- (void)dealloc
{
    [_dependencies release];
    [_waiters release];
    [_completion release];
    [_name release];
    if (!_finished) dispatch_group_leave(_done);
    dispatch_release(_done);
    pthread_mutex_destroy(&_lock);
    [super dealloc];
}

- (void)main { }

- (BOOL)isReady
{
    pthread_mutex_lock(&_lock);
    BOOL ready = YES;
    for (NSOperation *d in _dependencies) ready = ready && [d isFinished];
    pthread_mutex_unlock(&_lock);
    return ready;
}

- (BOOL)isExecuting { return _executing; }
- (BOOL)isFinished { return _finished; }
- (BOOL)isCancelled { return _cancelled; }
- (BOOL)isConcurrent { return [self isAsynchronous]; }
- (BOOL)isAsynchronous { return NO; }
- (void)cancel { _cancelled = YES; }

/* Mark finished: run the completion block, wake waiters, let dependents go. */
- (void)_finchFinish
{
    pthread_mutex_lock(&_lock);
    if (_finished) { pthread_mutex_unlock(&_lock); return; }
    _executing = NO;
    _finished = YES;
    NSArray *waiters = [[_waiters copy] autorelease];
    [_waiters removeAllObjects];
    void (^completion)(void) = [_completion retain];
    pthread_mutex_unlock(&_lock);
    if (completion) {
        completion();
        [completion release];
    }
    dispatch_group_leave(_done);
    for (NSOperation *w in waiters) [w _finchDependencyFinished];
}

- (void)_finchDependencyFinished
{
    NSOperationQueue *q = _queue;
    if (q && [self isReady]) [q _finchSchedule:self];
}

- (void)start
{
    if (_finished || _executing) return;
    if (!_cancelled) {
        _executing = YES;
        @autoreleasepool { [self main]; }
    }
    [self _finchFinish];
}

- (void)addDependency:(NSOperation *)op
{
    if (!op || op == self) return;
    pthread_mutex_lock(&_lock);
    [_dependencies addObject:op];
    pthread_mutex_unlock(&_lock);
    pthread_mutex_lock(&op->_lock);
    if (!op->_finished) [op->_waiters addObject:self];
    pthread_mutex_unlock(&op->_lock);
}

- (void)removeDependency:(NSOperation *)op
{
    pthread_mutex_lock(&_lock);
    [_dependencies removeObjectIdenticalTo:op];
    pthread_mutex_unlock(&_lock);
    [self _finchDependencyFinished];
}

- (NSArray<NSOperation *> *)dependencies
{
    pthread_mutex_lock(&_lock);
    NSArray *a = [[_dependencies copy] autorelease];
    pthread_mutex_unlock(&_lock);
    return a;
}

- (void (^)(void))completionBlock { return _completion; }
- (void)setCompletionBlock:(void (^)(void))block
{
    void (^old)(void) = _completion;
    _completion = [block copy];
    [old release];
}

- (void)waitUntilFinished { dispatch_group_wait(_done, DISPATCH_TIME_FOREVER); }

- (NSOperationQueuePriority)queuePriority { return _priority; }
- (void)setQueuePriority:(NSOperationQueuePriority)p { _priority = p; }
- (NSQualityOfService)qualityOfService { return _qos; }
- (void)setQualityOfService:(NSQualityOfService)q { _qos = q; }
- (double)threadPriority { return 0.5; }
- (void)setThreadPriority:(double)p { }
- (NSString *)name { return _name; }
- (void)setName:(NSString *)newName { NSString *o = _name; _name = [newName copy]; [o release]; }

@end

/* MARK: - NSBlockOperation, NSInvocationOperation */

@implementation NSBlockOperation {
    NSMutableArray *_blocks;
}

+ (instancetype)blockOperationWithBlock:(void (^)(void))block
{
    NSBlockOperation *op = [[[self alloc] init] autorelease];
    [op addExecutionBlock:block];
    return op;
}

- (instancetype)init
{
    if ((self = [super init])) _blocks = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc { [_blocks release]; [super dealloc]; }

- (void)addExecutionBlock:(void (^)(void))block
{
    if ([self isExecuting] || [self isFinished])
        FinchRaise(NSInvalidArgumentException, "*** -[NSBlockOperation addExecutionBlock:]: blocks cannot be added after the operation has started executing or finished");
    void (^copy)(void) = [block copy];
    [_blocks addObject:copy];
    [copy release];
}

- (NSArray<void (^)(void)> *)executionBlocks { return [[_blocks copy] autorelease]; }

- (void)main
{
    for (void (^b)(void) in [[_blocks copy] autorelease]) b();
}

@end

@implementation NSInvocationOperation {
    NSInvocation *_invocation;
    id _result;
}

- (instancetype)initWithTarget:(id)target selector:(SEL)sel object:(id)arg
{
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) { [self release]; return nil; }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target];
    [inv setSelector:sel];
    if ([sig numberOfArguments] > 2) [inv setArgument:&arg atIndex:2];
    return [self initWithInvocation:inv];
}

- (instancetype)initWithInvocation:(NSInvocation *)inv
{
    if ((self = [super init])) {
        _invocation = [inv retain];
        [_invocation retainArguments];
    }
    return self;
}

- (void)dealloc { [_invocation release]; [_result release]; [super dealloc]; }
- (NSInvocation *)invocation { return _invocation; }
- (void)main
{
    [_invocation invoke];
    if ([[_invocation methodSignature] methodReturnType][0] == '@') {
        id r = nil;
        [_invocation getReturnValue:&r];
        _result = [r retain];
    }
}
- (id)result { return _result; }

@end

/* MARK: - NSOperationQueue */

static pthread_key_t currentQueueKey;

@implementation NSOperationQueue {
    NSMutableArray *_operations;        /* added and not yet finished, in order */
    NSMutableArray *_pending;           /* ready, waiting for a slot */
    dispatch_queue_t _dq;
    pthread_mutex_t _lock;
    NSInteger _maxConcurrent, _running;
    NSString *_name;
    NSQualityOfService _qos;
    BOOL _suspended, _isMain;
}

+ (void)initialize
{
    if (self == [NSOperationQueue class]) pthread_key_create(&currentQueueKey, NULL);
}

+ (NSOperationQueue *)mainQueue
{
    static NSOperationQueue *main;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        main = [[NSOperationQueue alloc] init];
        main->_isMain = YES;
        main->_maxConcurrent = 1;
        dispatch_release(main->_dq);
        main->_dq = dispatch_get_main_queue();
        dispatch_retain(main->_dq);
        main->_name = @"NSOperationQueue Main Queue";
    });
    return main;
}

+ (NSOperationQueue *)currentQueue
{
    NSOperationQueue *q = pthread_getspecific(currentQueueKey);
    if (!q && pthread_main_np()) q = [self mainQueue];
    return q;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _operations = [[NSMutableArray alloc] init];
        _pending = [[NSMutableArray alloc] init];
        _dq = dispatch_queue_create("NSOperationQueue", DISPATCH_QUEUE_CONCURRENT);
        pthread_mutex_init(&_lock, NULL);
        _maxConcurrent = NSOperationQueueDefaultMaxConcurrentOperationCount;
        _qos = NSQualityOfServiceDefault;
    }
    return self;
}

- (void)dealloc
{
    [_operations release];
    [_pending release];
    dispatch_release(_dq);
    pthread_mutex_destroy(&_lock);
    [_name release];
    [super dealloc];
}

/* Start what we can: called with the lock not held. */
- (void)_finchDrain
{
    for (;;) {
        pthread_mutex_lock(&_lock);
        NSInteger limit = _maxConcurrent == NSOperationQueueDefaultMaxConcurrentOperationCount ? 64 : _maxConcurrent;
        if (_suspended || [_pending count] == 0 || _running >= limit) {
            pthread_mutex_unlock(&_lock);
            return;
        }
        NSOperation *op = [[[_pending objectAtIndex:0] retain] autorelease];
        [_pending removeObjectAtIndex:0];
        _running++;
        pthread_mutex_unlock(&_lock);
        [op retain];
        dispatch_async(_dq, ^{
            void *previous = pthread_getspecific(currentQueueKey);
            pthread_setspecific(currentQueueKey, self);
            [op start];
            if (![op isFinished]) [op _finchFinish];   /* asynchronous operations: see above */
            pthread_setspecific(currentQueueKey, previous);
            pthread_mutex_lock(&self->_lock);
            [self->_operations removeObjectIdenticalTo:op];
            self->_running--;
            pthread_mutex_unlock(&self->_lock);
            [op release];
            [self _finchDrain];
        });
    }
}

- (void)_finchSchedule:(NSOperation *)op
{
    pthread_mutex_lock(&_lock);
    if (![_pending containsObject:op] && [_operations containsObject:op] && ![op isExecuting] && ![op isFinished])
        [_pending addObject:op];
    pthread_mutex_unlock(&_lock);
    [self _finchDrain];
}

- (void)addOperation:(NSOperation *)op
{
    if (op->_enqueued)
        FinchRaise(NSInvalidArgumentException, "*** -[NSOperationQueue addOperation:]: operation is already enqueued on a queue");
    if ([op isFinished] || [op isExecuting])
        FinchRaise(NSInvalidArgumentException, "*** -[NSOperationQueue addOperation:]: operation is finished and cannot be enqueued");
    op->_enqueued = YES;
    op->_queue = self;
    pthread_mutex_lock(&_lock);
    [_operations addObject:op];
    pthread_mutex_unlock(&_lock);
    if ([op isReady]) [self _finchSchedule:op];
}

- (void)addOperations:(NSArray<NSOperation *> *)ops waitUntilFinished:(BOOL)wait
{
    for (NSOperation *op in ops) [self addOperation:op];
    if (wait)
        for (NSOperation *op in ops) [op waitUntilFinished];
}

- (void)addOperationWithBlock:(void (^)(void))block
{
    [self addOperation:[NSBlockOperation blockOperationWithBlock:block]];
}

- (void)addBarrierBlock:(void (^)(void))barrier
{
    NSBlockOperation *b = [NSBlockOperation blockOperationWithBlock:barrier];
    for (NSOperation *op in [self operations]) [b addDependency:op];
    [self addOperation:b];
}

- (NSArray<__kindof NSOperation *> *)operations
{
    pthread_mutex_lock(&_lock);
    NSArray *a = [[_operations copy] autorelease];
    pthread_mutex_unlock(&_lock);
    return a;
}

- (NSUInteger)operationCount { return [[self operations] count]; }
- (void)cancelAllOperations { for (NSOperation *op in [self operations]) [op cancel]; }
- (void)waitUntilAllOperationsAreFinished { for (NSOperation *op in [self operations]) [op waitUntilFinished]; }

- (NSInteger)maxConcurrentOperationCount { return _maxConcurrent; }
- (void)setMaxConcurrentOperationCount:(NSInteger)n
{
    pthread_mutex_lock(&_lock);
    _maxConcurrent = n;
    pthread_mutex_unlock(&_lock);
    [self _finchDrain];
}

- (BOOL)isSuspended { return _suspended; }
- (void)setSuspended:(BOOL)s
{
    pthread_mutex_lock(&_lock);
    _suspended = s;
    pthread_mutex_unlock(&_lock);
    if (!s) [self _finchDrain];
}

- (NSString *)name { return _name; }
- (void)setName:(NSString *)newName { NSString *o = _name; _name = [newName copy]; [o release]; }
- (NSQualityOfService)qualityOfService { return _qos; }
- (void)setQualityOfService:(NSQualityOfService)q { _qos = q; }
- (dispatch_queue_t)underlyingQueue { return _dq; }
- (void)setUnderlyingQueue:(dispatch_queue_t)q
{
    if (!q) return;
    dispatch_retain(q);
    dispatch_release(_dq);
    _dq = q;
}

@end
