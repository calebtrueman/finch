/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-runtime-test: Foundation's threads, locks, notifications, run loops,
 * timers, performs, operation queues and process info, one result per line
 * so runs against Apple's Foundation and Finch's can be diffed. Everything
 * printed is ordered by joins and waits, never by timing.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <string.h>

@interface Counter : NSObject
@property NSInteger hits;
@property (copy) NSString *last;
- (void)note:(NSNotification *)n;
- (void)bump:(id)arg;
@end

@implementation Counter
- (void)note:(NSNotification *)n { self.hits++; self.last = n.name; }
- (void)bump:(id)arg { self.hits++; self.last = [arg description]; }
@end

static void
step(NSString *what)
{
    printf("%s\n", what.UTF8String);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2 || strcmp(argv[1], "--no-path")) {
            Dl_info info;
            printf("Foundation: %s\n", dladdr((__bridge void *)[NSThread class], &info) ? info.dli_fname : "?");
        }

        /* Threads */
        printf("main is main: %d %d\n", [NSThread isMainThread], [[NSThread currentThread] isMainThread]);
        printf("mainThread is current: %d\n", [NSThread mainThread] == [NSThread currentThread]);
        __block BOOL inThreadMain = YES, sawDictionary = NO;
        __block NSString *threadName = nil;
        NSCondition *done = [[NSCondition alloc] init];
        __block BOOL finished = NO;
        NSThread *t = [[NSThread alloc] initWithBlock:^{
            inThreadMain = [NSThread isMainThread];
            threadName = [NSThread currentThread].name;
            [NSThread currentThread].threadDictionary[@"k"] = @"v";
            sawDictionary = [[NSThread currentThread].threadDictionary[@"k"] isEqual:@"v"];
            [done lock];
            finished = YES;
            [done signal];
            [done unlock];
        }];
        t.name = @"worker";
        printf("before start: executing %d finished %d\n", t.executing, t.finished);
        [t start];
        [done lock];
        while (!finished) [done wait];
        [done unlock];
        while (!t.finished) [NSThread sleepForTimeInterval:0.01];
        printf("thread ran off main: %d, name %s, dictionary %d, finished %d\n", !inThreadMain, threadName.UTF8String, sawDictionary, t.finished);
        printf("multithreaded: %d\n", [NSThread isMultiThreaded]);
        @try { [t start]; printf("restart: no exception\n"); }
        @catch (NSException *e) { printf("restart: %s\n", e.name.UTF8String); }

        /* Locks */
        NSLock *lock = [[NSLock alloc] init];
        lock.name = @"the lock";
        [lock lock];
        printf("tryLock while held: %d\n", [lock tryLock]);
        [lock unlock];
        printf("tryLock free: %d\n", [lock tryLock]);
        [lock unlock];
        printf("lock name: %s\n", lock.name.UTF8String);
        NSRecursiveLock *rl = [[NSRecursiveLock alloc] init];
        [rl lock];
        printf("recursive tryLock: %d\n", [rl tryLock]);
        [rl unlock];
        [rl unlock];
        NSConditionLock *cl = [[NSConditionLock alloc] initWithCondition:0];
        dispatch_group_t g = dispatch_group_create();
        dispatch_group_async(g, dispatch_get_global_queue(0, 0), ^{
            [cl lockWhenCondition:1];
            [cl unlockWithCondition:2];
        });
        [cl lock];
        [cl unlockWithCondition:1];
        [cl lockWhenCondition:2];
        printf("condition lock handed over: %ld\n", (long)cl.condition);
        [cl unlock];
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
        printf("timed-out condition wait: %d\n", [cl lockWhenCondition:9 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]]);

        /* Notifications */
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        Counter *c = [[Counter alloc] init];
        [nc addObserver:c selector:@selector(note:) name:@"FinchPing" object:nil];
        [nc postNotificationName:@"FinchPing" object:nil];
        [nc postNotificationName:@"FinchOther" object:nil];
        printf("selector observer: %ld %s\n", (long)c.hits, c.last.UTF8String);
        NSObject *sender = [[NSObject alloc] init];
        __block NSInteger blockHits = 0;
        __block id seenObject = nil;
        __block NSString *seenInfo = nil;
        id token = [nc addObserverForName:@"FinchBlock" object:sender queue:nil usingBlock:^(NSNotification *n) {
            blockHits++;
            seenObject = n.object;
            seenInfo = n.userInfo[@"why"];
        }];
        [nc postNotificationName:@"FinchBlock" object:sender userInfo:@{ @"why": @"because" }];
        [nc postNotificationName:@"FinchBlock" object:[[NSObject alloc] init]];
        printf("block observer: %ld same object %d info %s\n", (long)blockHits, seenObject == sender, seenInfo.UTF8String);
        [nc removeObserver:token];
        [nc postNotificationName:@"FinchBlock" object:sender];
        printf("after removeObserver: %ld\n", (long)blockHits);
        __block NSInteger queued = 0;
        NSOperationQueue *q = [[NSOperationQueue alloc] init];
        id token2 = [nc addObserverForName:@"FinchQueued" object:nil queue:q usingBlock:^(NSNotification *n) {
            queued += [NSOperationQueue currentQueue] == q;
        }];
        [nc postNotificationName:@"FinchQueued" object:nil];
        printf("queued observer ran on its queue before post returned: %ld\n", (long)queued);
        [nc removeObserver:token2];
        @autoreleasepool {
            Counter *gone = [[Counter alloc] init];
            [nc addObserver:gone selector:@selector(note:) name:@"FinchGone" object:nil];
            gone = nil;
        }
        [nc postNotificationName:@"FinchGone" object:nil];
        printf("deallocated observer skipped: ok\n");
        NSNotification *n = [NSNotification notificationWithName:@"N" object:@"obj" userInfo:@{ @"a": @1 }];
        printf("notification: %s %s %d\n", n.name.UTF8String, [n.object UTF8String], [n.userInfo[@"a"] intValue]);
        [nc removeObserver:c];
        [nc postNotificationName:@"FinchPing" object:nil];
        printf("removed selector observer: %ld\n", (long)c.hits);

        /* Run loop, timers, delayed performs */
        NSRunLoop *loop = [NSRunLoop currentRunLoop];
        printf("run loop wraps CFRunLoop: %d\n", loop.getCFRunLoop == CFRunLoopGetCurrent());
        printf("same object: %d\n", loop == [NSRunLoop currentRunLoop] && [NSRunLoop mainRunLoop] == loop);
        __block NSInteger fired = 0;
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *tm) {
            if (++fired == 3) [tm invalidate];
        }];
        printf("timer is CFRunLoopTimer: %d valid %d interval %.2f\n", CFGetTypeID((__bridge CFTypeRef)timer) == CFRunLoopTimerGetTypeID(), timer.valid, timer.timeInterval);
        while (fired < 3) [loop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        printf("repeating timer fired %ld, valid %d\n", (long)fired, timer.valid);
        Counter *target = [[Counter alloc] init];
        NSTimer *targetTimer = [NSTimer timerWithTimeInterval:0.01 target:target selector:@selector(bump:) userInfo:@"info" repeats:NO];
        printf("userInfo: %s\n", [targetTimer.userInfo UTF8String]);
        [loop addTimer:targetTimer forMode:NSDefaultRunLoopMode];
        [loop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        printf("target timer: hits %ld, valid %d\n", (long)target.hits, targetTimer.valid);
        [target performSelector:@selector(bump:) withObject:@"delayed" afterDelay:0.01];
        [target performSelector:@selector(bump:) withObject:@"cancelled" afterDelay:0.02];
        [NSObject cancelPreviousPerformRequestsWithTarget:target selector:@selector(bump:) object:@"cancelled"];
        [loop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        printf("delayed perform: hits %ld last %s\n", (long)target.hits, target.last.UTF8String);
        NSTimer *manual = [NSTimer timerWithTimeInterval:100 target:target selector:@selector(bump:) userInfo:nil repeats:NO];
        [manual fire];
        printf("fire: hits %ld valid %d\n", (long)target.hits, manual.valid);

        /* Performing on other threads */
        __block NSThread *worker = nil;
        NSCondition *ready = [[NSCondition alloc] init];
        NSThread *runner = [[NSThread alloc] initWithBlock:^{
            NSRunLoop *wl = [NSRunLoop currentRunLoop];
            [wl addTimer:[NSTimer timerWithTimeInterval:1000 repeats:YES block:^(NSTimer *x) { }] forMode:NSDefaultRunLoopMode];
            [ready lock];
            worker = [NSThread currentThread];
            [ready signal];
            [ready unlock];
            while (![NSThread currentThread].cancelled) [wl runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }];
        [runner start];
        [ready lock];
        while (!worker) [ready wait];
        [ready unlock];
        Counter *remote = [[Counter alloc] init];
        [remote performSelector:@selector(bump:) onThread:worker withObject:@"on worker" waitUntilDone:YES];
        printf("performSelector:onThread: waited: hits %ld last %s\n", (long)remote.hits, remote.last.UTF8String);
        __block BOOL wasMain = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            [remote performSelectorOnMainThread:@selector(bump:) withObject:@"on main" waitUntilDone:NO];
            wasMain = NO;
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        while (remote.hits < 2) [loop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        printf("performSelectorOnMainThread: hits %ld last %s\n", (long)remote.hits, remote.last.UTF8String);
        [runner cancel];

        /* Operation queues */
        NSOperationQueue *oq = [[NSOperationQueue alloc] init];
        NSMutableArray *order = [NSMutableArray array];
        NSLock *orderLock = [[NSLock alloc] init];
        NSBlockOperation *a = [NSBlockOperation blockOperationWithBlock:^{ [orderLock lock]; [order addObject:@"a"]; [orderLock unlock]; }];
        NSBlockOperation *b = [NSBlockOperation blockOperationWithBlock:^{ [orderLock lock]; [order addObject:@"b"]; [orderLock unlock]; }];
        NSBlockOperation *cOp = [NSBlockOperation blockOperationWithBlock:^{ [orderLock lock]; [order addObject:@"c"]; [orderLock unlock]; }];
        [cOp addDependency:b];
        [b addDependency:a];
        __block BOOL completed = NO;
        cOp.completionBlock = ^{ completed = YES; };
        [oq addOperations:@[ cOp, b, a ] waitUntilFinished:YES];
        while (!completed) [NSThread sleepForTimeInterval:0.01];
        printf("dependencies: %s, finished %d %d %d, completion %d\n", [[order componentsJoinedByString:@""] UTF8String], a.finished, b.finished, cOp.finished, completed);
        NSOperationQueue *serial = [[NSOperationQueue alloc] init];
        serial.maxConcurrentOperationCount = 1;
        NSMutableString *seq = [NSMutableString string];
        for (int i = 0; i < 8; i++) [serial addOperationWithBlock:^{ [seq appendFormat:@"%d", i]; }];
        [serial waitUntilAllOperationsAreFinished];
        printf("serial queue order: %s\n", seq.UTF8String);
        NSBlockOperation *cancelled = [NSBlockOperation blockOperationWithBlock:^{ printf("should not run\n"); }];
        [cancelled cancel];
        [oq addOperation:cancelled];
        [cancelled waitUntilFinished];
        printf("cancelled op: finished %d cancelled %d\n", cancelled.finished, cancelled.cancelled);
        __block BOOL onMainQueue = NO;
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{ onMainQueue = [NSThread isMainThread] && [NSOperationQueue currentQueue] == [NSOperationQueue mainQueue]; }];
        while (!onMainQueue) [loop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        printf("main queue: ran on main %d\n", onMainQueue);
        NSInvocationOperation *io = [[NSInvocationOperation alloc] initWithTarget:@"abc" selector:@selector(uppercaseString) object:nil];
        [io start];
        printf("invocation operation result: %s\n", [io.result UTF8String]);

        /* Process info */
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        printf("arguments: %lu last %s\n", (unsigned long)pi.arguments.count, [pi.arguments.lastObject UTF8String]);
        printf("processName: %s\n", pi.processName.UTF8String);
        printf("pid matches: %d\n", pi.processIdentifier == getpid());
        printf("environment has PATH: %d\n", pi.environment[@"PATH"] != nil);
        printf("at least macOS 26: %d, not 99: %d\n", [pi isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){ 26, 0, 0 }],
            ![pi isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){ 99, 0, 0 }]);
        printf("version string starts with Version: %d\n", [pi.operatingSystemVersionString hasPrefix:@"Version 26."]);
        printf("processors: %d memory: %d uptime: %d\n", pi.processorCount > 0 && pi.activeProcessorCount <= pi.processorCount,
            pi.physicalMemory > (1ULL << 30), pi.systemUptime > 0);
        NSString *u1 = pi.globallyUniqueString, *u2 = pi.globallyUniqueString;
        printf("unique strings differ: %d length ok %d\n", ![u1 isEqualToString:u2], u1.length > 36);
        printf("thermal state: %ld\n", (long)pi.thermalState);
        id activity = [pi beginActivityWithOptions:NSActivityUserInitiated reason:@"test"];
        [pi endActivity:activity];
        printf("activity: ok\n");
        step(@"done");
    }
    return 0;
}
