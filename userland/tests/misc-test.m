/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-misc-test: NSProxy, NSAssertionHandler, NSIndexPath, NSDateInterval,
 * NSAffineTransform, NSValueTransformer, NSUndoManager, NSNotificationQueue,
 * zones and pages, HFS type codes and the uncaught-exception handler, one
 * result per line so runs against Apple's Foundation and Finch's can be
 * diffed.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static const char *
oneline(id o)
{
    if (!o) return "(null)";
    NSMutableString *m = [[[[o description] componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "] mutableCopy];
    for (NSRange r = [m rangeOfString:@"0x"]; r.location != NSNotFound; r = [m rangeOfString:@"0x" options:0 range:NSMakeRange(r.location + 3, m.length - r.location - 3)]) {
        NSUInteger end = r.location + 2;
        while (end < m.length && isxdigit([m characterAtIndex:end])) end++;
        [m replaceCharactersInRange:NSMakeRange(r.location, end - r.location) withString:@"0xA"];
    }
    return m.UTF8String;
}

@interface Forwarder : NSProxy
@property (strong) id target;
@property int forwarded;
@end
@implementation Forwarder
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [self.target methodSignatureForSelector:s]; }
- (void)forwardInvocation:(NSInvocation *)i
{
    self.forwarded++;
    [i invokeWithTarget:self.target];
}
@end

@interface Asserter : NSObject
@end
@implementation Asserter
- (void)check:(int)x { NSAssert(x > 0, @"x must be positive, got %d", x); }
- (void)param:(id)p { NSParameterAssert(p != nil); }
+ (void)classCheck { NSAssert(NO, @"class side"); }
@end

@interface Counter : NSObject
@property NSInteger value;
@end
@implementation Counter
- (void)add:(NSNumber *)n
{
    self.value += n.integerValue;
    [[NSUndoManager valueForKey:@"self"] class];
}
@end

static void
proxies(void)
{
    Forwarder *p = [Forwarder alloc];
    p.target = @"hello";
    NSString *s = (NSString *)p;
    printf("proxy: %lu %s class %s kind %d responds %d isProxy %d proxyClass %s\n", (unsigned long)s.length, [s uppercaseString].UTF8String,
        class_getName([p class]), [p isKindOfClass:[NSString class]], [p respondsToSelector:@selector(length)], [p isProxy],
        [NSStringFromClass([NSProxy class]) UTF8String]);
    printf("forwarded: %d equal %d\n", p.forwarded, [s isEqualToString:@"hello"]);
    @try { [[NSProxy alloc] class]; printf("bare proxy class ok\n"); } @catch (NSException *e) { printf("%s\n", e.reason.UTF8String); }
}

static void
assertions(void)
{
    @try { [[Asserter new] check:-1]; } @catch (NSException *e) { printf("assert: %s | %s\n", e.name.UTF8String, e.reason.UTF8String); }
    @try { [[Asserter new] param:nil]; } @catch (NSException *e) { printf("param: %s\n", e.reason.UTF8String); }
    @try { [Asserter classCheck]; } @catch (NSException *e) { printf("class: %s\n", e.reason.UTF8String); }
    @try { NSCAssert(0, @"c assert %d", 7); } @catch (NSException *e) { printf("c: %s\n", e.reason.UTF8String); }
    @try { NSCParameterAssert(1 == 2); } @catch (NSException *e) { printf("c param: %s\n", e.reason.UTF8String); }
    printf("handler per thread: %d\n", [NSAssertionHandler currentHandler] == [NSAssertionHandler currentHandler]);
}

static void
values(void)
{
    NSUInteger idx[] = { 1, 4, 2 };
    NSIndexPath *ip = [NSIndexPath indexPathWithIndexes:idx length:3];
    NSUInteger got[3];
    [ip getIndexes:got range:NSMakeRange(1, 2)];
    printf("indexpath: %s %lu at1 %lu add %s remove %s got %lu,%lu\n", oneline(ip), (unsigned long)ip.length, (unsigned long)[ip indexAtPosition:1],
        oneline([ip indexPathByAddingIndex:9]), oneline([ip indexPathByRemovingLastIndex]), (unsigned long)got[0], (unsigned long)got[1]);
    printf("compare: %ld %ld %ld equal %d\n", (long)[ip compare:[NSIndexPath indexPathWithIndex:1]], (long)[ip compare:[NSIndexPath indexPathWithIndex:2]],
        (long)[ip compare:[ip copy]], [ip isEqual:[NSIndexPath indexPathWithIndexes:idx length:3]]);
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:@[ip, [NSIndexPath indexPathWithIndex:7]] requiringSecureCoding:NO error:NULL];
    printf("archived: %d\n", [[NSKeyedUnarchiver unarchiveTopLevelObjectWithData:d error:NULL] isEqual:@[ip, [NSIndexPath indexPathWithIndex:7]]]);

    NSDate *t0 = [NSDate dateWithTimeIntervalSinceReferenceDate:0];
    NSDateInterval *a = [[NSDateInterval alloc] initWithStartDate:t0 duration:3600];
    NSDateInterval *b = [[NSDateInterval alloc] initWithStartDate:[t0 dateByAddingTimeInterval:1800] endDate:[t0 dateByAddingTimeInterval:7200]];
    printf("interval: %s\n", oneline(a));
    printf("ops: contains %d %d intersects %d intersection %s compare %ld\n", [a containsDate:[t0 dateByAddingTimeInterval:3600]],
        [a containsDate:[t0 dateByAddingTimeInterval:3601]], [a intersectsDateInterval:b], oneline([a intersectionWithDateInterval:b]), (long)[a compare:b]);

    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:10 yBy:20];
    [t rotateByDegrees:90];
    [t scaleBy:2];
    NSPoint q = [t transformPoint:NSMakePoint(1, 0)];
    NSSize sz = [t transformSize:NSMakeSize(1, 1)];
    NSAffineTransformStruct m = t.transformStruct;
    printf("transform: %g %g size %g %g struct %g %g %g %g %g %g\n", q.x, q.y, sz.width, sz.height, m.m11, m.m12, m.m21, m.m22, m.tX, m.tY);
    NSAffineTransform *inv = [t copy];
    [inv invert];
    NSPoint back = [inv transformPoint:q];
    NSAffineTransform *u = [NSAffineTransform transform];
    [u scaleXBy:3 yBy:1];
    [u appendTransform:t];
    NSPoint w = [u transformPoint:NSMakePoint(1, 1)];
    printf("inverse: %g %g append %g %g\n", round(back.x * 1e9) / 1e9, round(back.y * 1e9) / 1e9, w.x, w.y);

    NSValueTransformer *neg = [NSValueTransformer valueTransformerForName:NSNegateBooleanTransformerName];
    printf("transformers: %s %s %s %s reverse %d %d\n", oneline([neg transformedValue:@YES]), oneline([neg reverseTransformedValue:@NO]),
        oneline([[NSValueTransformer valueTransformerForName:NSIsNilTransformerName] transformedValue:nil]),
        oneline([[NSValueTransformer valueTransformerForName:NSIsNotNilTransformerName] transformedValue:@1]),
        [[neg class] allowsReverseTransformation], [[[NSValueTransformer valueTransformerForName:NSIsNilTransformerName] class] allowsReverseTransformation]);
    NSValueTransformer *secure = [NSValueTransformer valueTransformerForName:NSSecureUnarchiveFromDataTransformerName];
    NSData *archived = [secure reverseTransformedValue:@[@"x", @2]];
    printf("secure: %s names %d\n", oneline([secure transformedValue:archived]), [[NSValueTransformer valueTransformerNames] containsObject:NSKeyedUnarchiveFromDataTransformerName]);
}

static void
undo(void)
{
    NSUndoManager *u = [NSUndoManager new];
    __block int notes = 0;
    id obs = [[NSNotificationCenter defaultCenter] addObserverForName:nil object:u queue:nil usingBlock:^(NSNotification *n) { notes++; }];
    u.groupsByEvent = NO;
    NSMutableArray *a = [NSMutableArray array];
    [u beginUndoGrouping];
    [a addObject:@1];
    [[u prepareWithInvocationTarget:a] removeLastObject];
    [u setActionName:@"Add"];
    [u endUndoGrouping];
    printf("undo: can %d name %s title %s [%s] level %ld\n", u.canUndo, u.undoActionName.UTF8String, u.undoMenuItemTitle.UTF8String,
        [a componentsJoinedByString:@","].UTF8String, (long)u.groupingLevel);
    [u undo];
    printf("after undo: [%s] canUndo %d canRedo %d %s\n", [a componentsJoinedByString:@","].UTF8String, u.canUndo, u.canRedo, u.redoMenuItemTitle.UTF8String);

    Counter *c = [Counter new];
    __block __weak void (^set)(NSInteger);
    void (^setter)(NSInteger) = ^(NSInteger v) {
        NSInteger old = c.value;
        c.value = v;
        [u registerUndoWithTarget:c handler:^(id target) { set(old); }];
    };
    set = setter;
    [u beginUndoGrouping];
    setter(5);
    [u setActionName:@"Set"];
    [u beginUndoGrouping];
    setter(8);
    [u endUndoGrouping];
    [u endUndoGrouping];
    printf("nested: %ld\n", (long)c.value);
    [u undo];
    printf("undone: %ld redo %d %s\n", (long)c.value, u.canRedo, u.redoActionName.UTF8String);
    [u redo];
    printf("redone: %ld undo %s\n", (long)c.value, u.undoActionName.UTF8String);
    [u undo];
    [u beginUndoGrouping];
    [u registerUndoWithTarget:c selector:@selector(setValue:) object:nil];
    [u endUndoGrouping];
    printf("new action clears redo: %d\n", u.canRedo);
    [u removeAllActionsWithTarget:c];
    printf("removed: undo %d redo %d\n", u.canUndo, u.canRedo);
    [u disableUndoRegistration];
    [u beginUndoGrouping];
    [[u prepareWithInvocationTarget:a] addObject:@9];
    [u endUndoGrouping];
    printf("disabled: %d enabled %d\n", u.canUndo, u.isUndoRegistrationEnabled);
    [u enableUndoRegistration];
    @try { [u endUndoGrouping]; } @catch (NSException *e) { printf("unbalanced: %s\n", e.name.UTF8String); }
    u.levelsOfUndo = 2;
    for (int i = 0; i < 4; i++) {
        [u beginUndoGrouping];
        [[u prepareWithInvocationTarget:a] addObject:@(i)];
        [u endUndoGrouping];
    }
    int n = 0;
    while (u.canUndo) { [u undo]; n++; }
    printf("levels: %d [%s]\n", n, [a componentsJoinedByString:@","].UTF8String);
    [[NSNotificationCenter defaultCenter] removeObserver:obs];
    printf("notifications: %d\n", notes > 10);

    NSUndoManager *ev = [NSUndoManager new];
    [[ev prepareWithInvocationTarget:a] removeAllObjects];
    printf("event group: level %ld can %d\n", (long)ev.groupingLevel, ev.canUndo);
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    printf("after run loop: level %ld can %d\n", (long)ev.groupingLevel, ev.canUndo);
}

static void
queues(void)
{
    NSNotificationQueue *q = [NSNotificationQueue defaultQueue];
    __block NSMutableArray *got = [NSMutableArray array];
    id obs = [[NSNotificationCenter defaultCenter] addObserverForName:nil object:@"src" queue:nil usingBlock:^(NSNotification *n) { [got addObject:n.name]; }];
    [q enqueueNotification:[NSNotification notificationWithName:@"A" object:@"src"] postingStyle:NSPostASAP];
    [q enqueueNotification:[NSNotification notificationWithName:@"A" object:@"src"] postingStyle:NSPostASAP];
    [q enqueueNotification:[NSNotification notificationWithName:@"I" object:@"src"] postingStyle:NSPostWhenIdle];
    [q enqueueNotification:[NSNotification notificationWithName:@"B" object:@"src"] postingStyle:NSPostASAP coalesceMask:NSNotificationNoCoalescing forModes:nil];
    [q enqueueNotification:[NSNotification notificationWithName:@"D" object:@"src"] postingStyle:NSPostASAP];
    [q dequeueNotificationsMatching:[NSNotification notificationWithName:@"D" object:@"src"] coalesceMask:NSNotificationCoalescingOnName];
    [q enqueueNotification:[NSNotification notificationWithName:@"N" object:@"src"] postingStyle:NSPostNow];
    printf("queue before run: %s\n", [got componentsJoinedByString:@","].UTF8String);
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    printf("queue after run: %s\n", [got componentsJoinedByString:@","].UTF8String);
    [[NSNotificationCenter defaultCenter] removeObserver:obs];
}

static void
uncaught_handler(NSException *e) { }

static void
memory(void)
{
    NSZone *z = NSDefaultMallocZone();
    char *p = NSZoneMalloc(z, 16);
    strcpy(p, "zone");
    p = NSZoneRealloc(z, p, 32);
    printf("zones: %s from %d calloc %d\n", p, NSZoneFromPointer(p) == z, ((char *)NSZoneCalloc(NULL, 4, 4))[15]);
    NSZoneFree(z, p);
    printf("pages: %lu %lu %lu %lu\n", (unsigned long)NSPageSize(), (unsigned long)NSLogPageSize(), (unsigned long)NSRoundUpToMultipleOfPageSize(1),
        (unsigned long)NSRoundDownToMultipleOfPageSize(NSPageSize() + 5));
    void *pages = NSAllocateMemoryPages(100);
    memset(pages, 1, 100);
    NSDeallocateMemoryPages(pages, 100);
    printf("hfs: %s %d\n", NSFileTypeForHFSTypeCode('TEXT').UTF8String, NSHFSTypeCodeFromFileType(@"'APPL'") == 'APPL');
    NSSetUncaughtExceptionHandler(uncaught_handler);
    printf("handler: %d version %.1f\n", NSGetUncaughtExceptionHandler() == uncaught_handler, NSFoundationVersionNumber);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        proxies();
        assertions();
        values();
        undo();
        queues();
        memory();
    }
    return 0;
}
