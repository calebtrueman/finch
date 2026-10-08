/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSRunLoop and NSTimer, which Apple's CoreFoundation hosts
 * (docs/design/FOUNDATION.md), with __NSCFTimer, the class of every
 * CFRunLoopTimer. An NSRunLoop wraps its thread's CFRunLoop (one object per
 * run loop, kept in thread-specific storage, the main thread's for good).
 * Timers are CFRunLoopTimers whose context holds the target and selector (or
 * the block) and the user info, retained until the timer goes away, as
 * NSTimer retains its target until invalidated.
 */
#include "CFObjCClasses_Finch.h"
#include <dispatch/dispatch.h>
#include <pthread.h>

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);

typedef double NSTimeInterval;

NSString *const NSDefaultRunLoopMode = (NSString *)CFSTR("kCFRunLoopDefaultMode");
NSString *const NSRunLoopCommonModes = (NSString *)CFSTR("kCFRunLoopCommonModes");

@interface NSDate (FinchRunLoop)
+ (id)distantFuture;
+ (id)dateWithTimeIntervalSinceReferenceDate:(NSTimeInterval)ti;
- (NSTimeInterval)timeIntervalSinceReferenceDate;
@end

/* MARK: - NSTimer */

typedef struct {
    int refs;
    id target;
    SEL selector;
    id userInfo;
    void (^block)(id timer);
} TimerInfo;

static const void *
info_retain(const void *p)
{
    __atomic_fetch_add(&((TimerInfo *)p)->refs, 1, __ATOMIC_RELAXED);
    return p;
}

static void
info_release(const void *p)
{
    TimerInfo *i = (TimerInfo *)p;
    if (__atomic_sub_fetch(&i->refs, 1, __ATOMIC_ACQ_REL) == 0) {
        [i->target release];
        [i->userInfo release];
        [i->block release];
        free(i);
    }
}

static void
timer_fired(CFRunLoopTimerRef timer, void *p)
{
    TimerInfo *i = p;
    void *pool = objc_autoreleasePoolPush();
    if (i->block) i->block((id)timer);
    else ((void (*)(id, SEL, id))objc_msgSend)(i->target, i->selector, (id)timer);
    objc_autoreleasePoolPop(pool);
}

static CFRunLoopTimerRef
make_timer(CFAbsoluteTime fire, NSTimeInterval interval, BOOL repeats, id target, SEL sel, id userInfo, void (^block)(id))
{
    TimerInfo *i = calloc(1, sizeof(*i));
    i->target = [target retain];
    i->selector = sel;
    i->userInfo = [userInfo retain];
    i->block = [block copy];
    CFRunLoopTimerContext ctx = { 0, i, info_retain, info_release, NULL };
    if (interval <= 0) interval = 0.0001;   /* as Apple's: a repeating timer needs a positive interval */
    /* refs starts at 0: the timer's retain of its context is the first. */
    return CFRunLoopTimerCreate(NULL, fire, repeats ? interval : 0, 0, 0, timer_fired, &ctx);
}

@interface __NSCFTimer : NSTimer
@end
@interface __NSPlaceholderTimer : NSTimer
@end

static __NSPlaceholderTimer *timerPlaceholder;

@implementation NSTimer

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSTimer class] || self == [__NSCFTimer class]) return (id)timerPlaceholder;
    return [super allocWithZone:zone];
}

+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)ti target:(id)target selector:(SEL)sel userInfo:(id)userInfo repeats:(BOOL)repeats
{
    return [(id)make_timer(CFAbsoluteTimeGetCurrent() + ti, ti, repeats, target, sel, userInfo, nil) autorelease];
}

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti target:(id)target selector:(SEL)sel userInfo:(id)userInfo repeats:(BOOL)repeats
{
    NSTimer *t = [self timerWithTimeInterval:ti target:target selector:sel userInfo:userInfo repeats:repeats];
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), (CFRunLoopTimerRef)t, kCFRunLoopDefaultMode);
    return t;
}

+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)ti repeats:(BOOL)repeats block:(void (^)(NSTimer *))block
{
    return [(id)make_timer(CFAbsoluteTimeGetCurrent() + ti, ti, repeats, nil, NULL, nil, (void (^)(id))block) autorelease];
}

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti repeats:(BOOL)repeats block:(void (^)(NSTimer *))block
{
    NSTimer *t = [self timerWithTimeInterval:ti repeats:repeats block:block];
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), (CFRunLoopTimerRef)t, kCFRunLoopDefaultMode);
    return t;
}

/* An invocation: invoked with the timer, not given it. */
+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)ti invocation:(id)invocation repeats:(BOOL)repeats
{
    [invocation retain];
    return [self timerWithTimeInterval:ti repeats:repeats block:^(NSTimer *t) {
        ((void (*)(id, SEL))objc_msgSend)(invocation, sel_registerName("invoke"));
        if (![t isValid] || !repeats) [invocation release];
    }];
}

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti invocation:(id)invocation repeats:(BOOL)repeats
{
    NSTimer *t = [self timerWithTimeInterval:ti invocation:invocation repeats:repeats];
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), (CFRunLoopTimerRef)t, kCFRunLoopDefaultMode);
    return t;
}

- (CFTypeID)_cfTypeID { return CFRunLoopTimerGetTypeID(); }

@end

@implementation __NSPlaceholderTimer

FINCH_IMMORTAL_MEMORY

- (instancetype)initWithFireDate:(id)date interval:(NSTimeInterval)ti target:(id)target selector:(SEL)sel userInfo:(id)ui repeats:(BOOL)rep
{
    return (id)make_timer([date timeIntervalSinceReferenceDate], ti, rep, target, sel, ui, nil);
}

- (instancetype)initWithFireDate:(id)date interval:(NSTimeInterval)ti repeats:(BOOL)rep block:(void (^)(NSTimer *))block
{
    return (id)make_timer([date timeIntervalSinceReferenceDate], ti, rep, nil, NULL, nil, (void (^)(id))block);
}

@end

@implementation __NSCFTimer

FINCH_CF_OBJECT_MEMORY

static TimerInfo *
info_of(id self)
{
    CFRunLoopTimerContext ctx = { 0 };
    CFRunLoopTimerGetContext((CFRunLoopTimerRef)self, &ctx);
    return ctx.retain == info_retain ? ctx.info : NULL;   /* NULL: made by CF, not by NSTimer */
}

- (void)fire
{
    if (!CFRunLoopTimerIsValid((CFRunLoopTimerRef)self)) return;
    TimerInfo *i = info_of(self);
    if (i) {
        info_retain(i);
        timer_fired((CFRunLoopTimerRef)self, i);
        info_release(i);
    }
    if (CFRunLoopTimerGetInterval((CFRunLoopTimerRef)self) <= 0) CFRunLoopTimerInvalidate((CFRunLoopTimerRef)self);
}

- (id)fireDate
{
    return [NSDate dateWithTimeIntervalSinceReferenceDate:CFRunLoopTimerGetNextFireDate((CFRunLoopTimerRef)self)];
}
- (void)setFireDate:(id)date
{
    CFRunLoopTimerSetNextFireDate((CFRunLoopTimerRef)self, [date timeIntervalSinceReferenceDate]);
}
- (CFAbsoluteTime)_cffireTime { return CFRunLoopTimerGetNextFireDate((CFRunLoopTimerRef)self); }
- (NSTimeInterval)timeInterval { return CFRunLoopTimerGetInterval((CFRunLoopTimerRef)self); }
- (NSTimeInterval)tolerance { return CFRunLoopTimerGetTolerance((CFRunLoopTimerRef)self); }
- (void)setTolerance:(NSTimeInterval)t { CFRunLoopTimerSetTolerance((CFRunLoopTimerRef)self, t); }
- (void)invalidate { CFRunLoopTimerInvalidate((CFRunLoopTimerRef)self); }
- (BOOL)isValid { return CFRunLoopTimerIsValid((CFRunLoopTimerRef)self); }
- (id)userInfo { TimerInfo *i = info_of(self); return i ? i->userInfo : nil; }

@end

/* MARK: - NSRunLoop */

@interface NSRunLoop : NSObject {
@public
    CFRunLoopRef _rl;
    void *_reserved[5];
}
@end

static pthread_key_t runLoopKey;
static NSRunLoop *mainRunLoop;

static void
release_run_loop(void *p)
{
    [(id)p release];
}

static NSRunLoop *
wrap(CFRunLoopRef rl)
{
    NSRunLoop *r = class_createInstance([NSRunLoop class], 0);
    r->_rl = (CFRunLoopRef)CFRetain(rl);
    return r;
}

CF_PRIVATE void
__CFFinchInitializeRunLoopClasses(void)
{
    timerPlaceholder = class_createInstance([__NSPlaceholderTimer class], 0);
    pthread_key_create(&runLoopKey, release_run_loop);
}

CF_PRIVATE Class
__CFFinchTimerClass(void)
{
    return [__NSCFTimer class];
}

@implementation NSRunLoop

+ (NSRunLoop *)currentRunLoop
{
    if (pthread_main_np()) return [self mainRunLoop];
    NSRunLoop *r = pthread_getspecific(runLoopKey);
    if (!r) {
        r = wrap(CFRunLoopGetCurrent());
        pthread_setspecific(runLoopKey, r);
    }
    return r;
}

+ (NSRunLoop *)mainRunLoop
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mainRunLoop = wrap(CFRunLoopGetMain()); });
    return mainRunLoop;
}

- (void)dealloc
{
    if (_rl) CFRelease(_rl);
    [super dealloc];
}

- (CFRunLoopRef)getCFRunLoop { return _rl; }

- (NSString *)currentMode
{
    return [(id)CFRunLoopCopyCurrentMode(_rl) autorelease];
}

- (void)addTimer:(NSTimer *)timer forMode:(NSString *)mode
{
    CFRunLoopAddTimer(_rl, (CFRunLoopTimerRef)timer, (CFStringRef)mode);
}

- (id)limitDateForMode:(NSString *)mode
{
    CFAbsoluteTime next = CFRunLoopGetNextTimerFireDate(_rl, (CFStringRef)mode);
    return next ? [NSDate dateWithTimeIntervalSinceReferenceDate:next] : nil;
}

- (BOOL)runMode:(NSString *)mode beforeDate:(id)limitDate
{
    NSTimeInterval wait = [limitDate timeIntervalSinceReferenceDate] - CFAbsoluteTimeGetCurrent();
    if (wait < 0) wait = 0;
    CFRunLoopRunResult r = CFRunLoopRunInMode((CFStringRef)mode, wait, true);
    return r != kCFRunLoopRunFinished;
}

- (void)acceptInputForMode:(NSString *)mode beforeDate:(id)limitDate
{
    [self runMode:mode beforeDate:limitDate];
}

- (void)runUntilDate:(id)limitDate
{
    while ([limitDate timeIntervalSinceReferenceDate] > CFAbsoluteTimeGetCurrent() &&
           [self runMode:NSDefaultRunLoopMode beforeDate:limitDate])
        ;
}

- (void)run
{
    while ([self runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]])
        ;
}

- (void)performBlock:(void (^)(void))block
{
    CFRunLoopPerformBlock(_rl, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(_rl);
}

- (void)performInModes:(id)modes block:(void (^)(void))block
{
    CFRunLoopPerformBlock(_rl, (CFTypeRef)modes, block);
    CFRunLoopWakeUp(_rl);
}

@end
