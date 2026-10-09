/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-nsxpc-test: NSXPCConnection, NSXPCListener and NSXPCInterface,
 * against the XPC service org.finch.test.nsxpc (nsxpc-service.m), which
 * lives in this program's app bundle (FinchXPCTest.app/Contents/XPCServices).
 * Scalars, structs, strings, property lists, custom secure-coded classes,
 * reply blocks, errors, proxies passed as arguments, endpoints of anonymous
 * listeners, synchronous proxies, ordering and queues, interruption (the
 * service is killed) and invalidation.
 *
 * Run it from the app bundle. On macOS the host's launchd starts the bundled
 * service; on Finch, finch-init starts it on demand. The output is the same
 * on both (pids are written as <pid>/<self>); exits 0 on success.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>

#include "nsxpc-test.h"

static int failures;
static pid_t servicePid;

static void
check(BOOL ok, NSString *what)
{
    printf("%s: %s\n", what.UTF8String, ok ? "ok" : "FAILED");
    failures += !ok;
}

/* Pids vary from run to run. */
static NSString *
scrub(id object)
{
    NSString *s = object ? [object description] : @"(nil)";
    s = [s stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"pid %d", getpid()] withString:@"pid <self>"];
    if (servicePid > 0)
        s = [s stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"pid %d", servicePid] withString:@"pid <pid>"];
    NSRegularExpression *pointer = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-f]+" options:0 error:NULL];
    return [pointer stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"0x…"];
}

static void
print_error(NSString *label, NSError *e)
{
    printf("%s: %s %ld %s\n", label.UTF8String, e.domain.UTF8String, (long)e.code, scrub(e.userInfo).UTF8String);
}

static BOOL
wait_for(dispatch_semaphore_t s)
{
    return dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0;
}

static NSString *
queue_label(void)
{
    return [NSString stringWithUTF8String:dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)];
}

static NSString *
class_names(NSSet *classes)
{
    NSMutableArray *names = [NSMutableArray array];
    for (Class c in classes) [names addObject:NSStringFromClass(c)];
    [names sortUsingSelector:@selector(compare:)];
    return [names componentsJoinedByString:@","];
}

#pragma mark - The interface

@protocol FinchXPCBadProtocol
- (NSInteger)returnsSomething;
- (void)twoBlocks:(void (^)(void))a and:(void (^)(void))b;
- (void)takesThing:(FinchXPCThing *)thing array:(NSArray *)array string:(NSString *)s number:(NSNumber *)n
    anything:(id)anything count:(NSInteger)count reply:(void (^)(NSDictionary *d, NSString *s))reply;
@end

static void
test_interface(void)
{
    printf("-- NSXPCInterface\n");
    NSXPCInterface *i = [NSXPCInterface interfaceWithProtocol:@protocol(FinchXPCBadProtocol)];
    printf("protocol: %s\n", protocol_getName(i.protocol));
    SEL sel = @selector(takesThing:array:string:number:anything:count:reply:);
    for (NSUInteger a = 0; a <= 6; a++)
        printf("argument %lu: {%s}\n", (unsigned long)a, class_names([i classesForSelector:sel argumentIndex:a ofReply:NO]).UTF8String);
    for (NSUInteger a = 0; a <= 1; a++)
        printf("reply argument %lu: {%s}\n", (unsigned long)a, class_names([i classesForSelector:sel argumentIndex:a ofReply:YES]).UTF8String);
    @try {
        [i classesForSelector:sel argumentIndex:2 ofReply:YES];
        printf("out of range: no exception\n");
    } @catch (NSException *e) {
        printf("out of range: %s: %s\n", e.name.UTF8String, e.reason.UTF8String);
    }
    @try {
        [i setClasses:[NSSet set] forSelector:@selector(description) argumentIndex:0 ofReply:NO];
        printf("not in protocol: no exception\n");
    } @catch (NSException *e) {
        printf("not in protocol: %s: %s\n", e.name.UTF8String, e.reason.UTF8String);
    }
    [i setClasses:[NSSet setWithObjects:[NSString class], [NSURL class], nil] forSelector:sel argumentIndex:4 ofReply:NO];
    printf("after setClasses: {%s}\n", class_names([i classesForSelector:sel argumentIndex:4 ofReply:NO]).UTF8String);
    printf("interface for argument 0: %s\n", [i interfaceForSelector:sel argumentIndex:0 ofReply:NO] ? "set" : "nil");
    NSXPCInterface *cb = [NSXPCInterface interfaceWithProtocol:@protocol(FinchXPCCallback)];
    [i setInterface:cb forSelector:sel argumentIndex:4 ofReply:NO];
    printf("interface for argument 4: %s\n", [i interfaceForSelector:sel argumentIndex:4 ofReply:NO] == cb ? "the one set" : "WRONG");
    printf("XPC type for argument 4: %s\n", [i XPCTypeForSelector:sel argumentIndex:4 ofReply:NO] ? "set" : "nil");
    [i setXPCType:XPC_TYPE_DICTIONARY forSelector:sel argumentIndex:4 ofReply:NO];
    printf("XPC type after set: %s\n", [i XPCTypeForSelector:sel argumentIndex:4 ofReply:NO] == XPC_TYPE_DICTIONARY ? "dictionary" : "WRONG");
}

#pragma mark - The service

@interface FinchXPCClientCallback : NSObject <FinchXPCCallback>
@property (strong) NSMutableArray *log;
@property NSInteger stopAt;
@end

@implementation FinchXPCClientCallback
- (void)progress:(double)fraction message:(NSString *)message reply:(void (^)(BOOL))reply
{
    @synchronized (self) {
        [self.log addObject:[NSString stringWithFormat:@"%.2f %@ main=%d current=%d", fraction, message,
            [NSThread isMainThread], [NSXPCConnection currentConnection] != nil]];
    }
    reply((NSInteger)self.log.count != self.stopAt);
}
@end

static NSXPCConnection *
service_connection(void)
{
    NSXPCConnection *c = [[NSXPCConnection alloc] initWithServiceName:FINCH_NSXPC_SERVICE];
    c.remoteObjectInterface = FinchXPCTestInterface();
    c.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(FinchXPCCallback)];
    return c;
}

static void
test_messages(NSXPCConnection *c)
{
    __block NSError *lastError = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    id<FinchXPCTestProtocol> p = [c remoteObjectProxyWithErrorHandler:^(NSError *e) {
        lastError = e;
        print_error(@"unexpected error", e);
        dispatch_semaphore_signal(s);
    }];

    printf("-- messages\n");
    __block NSDictionary *info = nil;
    [p serverInfo:^(NSDictionary *d) { info = d; dispatch_semaphore_signal(s); }];
    check(wait_for(s) && info != nil, @"serverInfo replied");
    servicePid = [info[@"pid"] intValue];
    check(servicePid > 0 && servicePid != getpid(), @"service runs in its own process");
    check([info[@"peerPid"] intValue] == getpid() && [info[@"peerUid"] intValue] == (int)geteuid() &&
        [info[@"peerGid"] intValue] == (int)getegid(), @"service sees our pid, euid and egid");
    check([info[@"currentConnection"] boolValue], @"+currentConnection in the exported object is its connection");
    check(![info[@"mainThread"] boolValue], @"exported methods run off the main thread");
    printf("service sees serviceName %s\n", [info[@"serviceName"] UTF8String]);
    check(c.processIdentifier == servicePid, @"processIdentifier is the service's pid");
    check(c.effectiveUserIdentifier == geteuid(), @"effectiveUserIdentifier");
    printf("connection: %s\n", scrub(c).UTF8String);

    __block NSInteger sum = 0;
    __block BOOL onMain = YES;
    __block NSString *label = nil;
    __block NSXPCConnection *current = nil;
    [p add:40 to:2 reply:^(NSInteger r) {
        sum = r;
        onMain = [NSThread isMainThread];
        label = queue_label();
        current = [NSXPCConnection currentConnection];
        dispatch_semaphore_signal(s);
    }];
    wait_for(s);
    check(sum == 42, @"add: 40 + 2 = 42");
    check(!onMain, @"reply blocks run off the main thread");
    printf("reply queue: %s\n", label.UTF8String);
    check(current == c, @"+currentConnection in a reply block is the connection");

    __block NSString *str = nil;
    [p scalarsChar:65 uchar:250 short:30000 int:-2000000000 long:-9000000000000000000L ull:18000000000000000000ULL
        float:1.5f double:3.141592653589793 bool:YES reply:^(NSString *d) { str = d; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("scalars: %s\n", str.UTF8String);

    __block NSRect rect;
    __block NSRange range;
    __block double total = 0;
    [p geometryPoint:NSMakePoint(1, 2) size:NSMakeSize(3, 4) rect:NSMakeRect(10, 10, 5, 5) range:NSMakeRange(7, 8)
        reply:^(NSRect r, NSRange rg, double t) { rect = r; range = rg; total = t; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("structs: %s %s %g\n", NSStringFromRect(rect).UTF8String, NSStringFromRange(range).UTF8String, total);

    __block NSError *err = nil;
    [p uppercase:@"finch ✓" reply:^(NSString *u, NSError *e) { str = u; err = e; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("uppercase: %s error=%s\n", str.UTF8String, err ? "yes" : "nil");
    [p uppercase:@"" reply:^(NSString *u, NSError *e) { str = u; err = e; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("uppercase of nothing: %s\n", str ? str.UTF8String : "nil");
    print_error(@"  its error", err);
    [p uppercase:nil reply:^(NSString *u, NSError *e) { str = u; err = e; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("uppercase of nil: %s error code %ld\n", str ? str.UTF8String : "nil", (long)err.code);

    NSDictionary *plist = @{
        @"string": @"héllo",
        @"int": @-42,
        @"big": @18000000000000000000ULL,
        @"double": @2.5,
        @"bool": @YES,
        @"data": [@"bytes" dataUsingEncoding:NSUTF8StringEncoding],
        @"date": [NSDate dateWithTimeIntervalSince1970:1000000000.25],
        @"null": [NSNull null],
        @"array": @[@1, @"two", @[@3]],
        @"set": [NSSet setWithObjects:@"a", @"b", nil],
        @"ordered": [NSOrderedSet orderedSetWithObjects:@"z", @"y", nil],
        @42: @"number key",
    };
    __block id echoed = nil;
    [p echo:plist reply:^(id same) { echoed = same; dispatch_semaphore_signal(s); }];
    wait_for(s);
    check([echoed isEqual:plist], @"echo: a property list comes back equal");
    for (NSString *k in @[@"string", @"int", @"big", @"double", @"bool", @"date", @"array", @"set", @"ordered"])
        printf("  %s: %s (%s)\n", k.UTF8String, [[echoed[k] description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String,
            [echoed[k] isKindOfClass:[NSString class]] ? "string" : [echoed[k] isKindOfClass:[NSNumber class]] ?
            [NSString stringWithFormat:@"number %s", [echoed[k] objCType]].UTF8String : "object");
    printf("  bool is the boolean singleton: %s\n", echoed[@"bool"] == (id)kCFBooleanTrue ? "yes" : "no");
    printf("  date: %.2f\n", [echoed[@"date"] timeIntervalSince1970]);
    [p echo:nil reply:^(id same) { echoed = same; dispatch_semaphore_signal(s); }];
    wait_for(s);
    check(echoed == nil, @"echo: nil comes back nil");
    NSMutableArray *mutable = [NSMutableArray arrayWithObject:@"m"];
    [p echo:mutable reply:^(id same) { echoed = same; dispatch_semaphore_signal(s); }];
    wait_for(s);
    check([echoed isEqual:mutable], @"echo: a mutable array comes back equal");

    FinchXPCThing *thing = [FinchXPCThing new];
    thing.name = @"finch";
    thing.count = 4;
    thing.tags = @[@"bird"];
    thing.frame = NSMakeRect(1, 2, 3, 4);
    __block FinchXPCThing *result = nil;
    [p transform:thing reply:^(FinchXPCThing *t) { result = t; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("custom class: %s\n", result.description.UTF8String);

    NSMutableArray *things = [NSMutableArray array];
    for (NSString *name in @[@"c", @"a", @"b"]) {
        FinchXPCThing *t = [FinchXPCThing new];
        t.name = name;
        [things addObject:t];
    }
    __block NSArray *sorted = nil;
    [p sortThings:things reply:^(NSArray *a) { sorted = a; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("array of custom objects (setClasses): %s\n", [[sorted valueForKey:@"name"] componentsJoinedByString:@","].UTF8String);

    [p failWithCode:99 reply:^(NSError *e) { err = e; dispatch_semaphore_signal(s); }];
    wait_for(s);
    print_error(@"error argument", err);
    printf("  localizedDescription: %s\n", err.localizedDescription.UTF8String);

    printf("-- ordering\n");
    for (int i = 0; i < 200; i++) [p ping];
    __block NSInteger count = 0;
    [p countPings:^(NSInteger n) { count = n; dispatch_semaphore_signal(s); }];
    wait_for(s);
    check(count == 200, @"200 one-way messages arrive before the next request");
    NSMutableArray *order = [NSMutableArray array];
    __block atomic_int inside = 0;
    __block BOOL overlapped = NO, sameQueue = YES;
    dispatch_semaphore_t all = dispatch_semaphore_create(0);
    for (NSInteger i = 0; i < 50; i++) {
        [p add:i to:0 reply:^(NSInteger r) {
            if (atomic_fetch_add(&inside, 1) != 0) overlapped = YES;
            usleep(200);
            [order addObject:@(r)];
            if (![queue_label() isEqualToString:label]) sameQueue = NO;
            atomic_fetch_sub(&inside, 1);
            if (order.count == 50) dispatch_semaphore_signal(all);
        }];
    }
    wait_for(all);
    BOOL inOrder = order.count == 50;
    for (NSInteger i = 0; inOrder && i < 50; i++) inOrder = [order[i] integerValue] == i;
    check(inOrder, @"50 replies arrive in the order sent");
    check(!overlapped && sameQueue, @"replies run one at a time on the connection's queue");

    printf("-- synchronous proxy\n");
    id<FinchXPCTestProtocol> sync = [c synchronousRemoteObjectProxyWithErrorHandler:^(NSError *e) { print_error(@"unexpected error", e); }];
    sum = 0;
    __block BOOL syncOnMain = NO;
    [sync add:20 to:22 reply:^(NSInteger r) { sum = r; syncOnMain = [NSThread isMainThread]; }];
    check(sum == 42, @"the reply has run when the call returns");
    check(syncOnMain, @"on the calling thread");

    printf("-- proxies as arguments\n");
    FinchXPCClientCallback *callback = [FinchXPCClientCallback new];
    callback.log = [NSMutableArray array];
    __block NSInteger completed = 0;
    [p runCallback:callback steps:3 reply:^(NSInteger n) { completed = n; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("callback: completed %ld; %s\n", (long)completed, [callback.log componentsJoinedByString:@"; "].UTF8String);
    callback.log = [NSMutableArray array];
    callback.stopAt = 2;
    [p runCallback:callback steps:5 reply:^(NSInteger n) { completed = n; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("callback stopped: completed %ld; %s\n", (long)completed, [callback.log componentsJoinedByString:@"; "].UTF8String);

    printf("-- a reply sent later from another queue\n");
    [p delayedReply:0.2 reply:^(NSString *a) { str = a; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("delayed reply: %s\n", str.UTF8String);

    printf("-- an anonymous listener's endpoint, passed back\n");
    __block NSXPCListenerEndpoint *endpoint = nil;
    [p makeAnonymousListener:^(NSXPCListenerEndpoint *e) { endpoint = e; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("endpoint: %s\n", NSStringFromClass([endpoint class]).UTF8String);
    NSXPCConnection *ec = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
    ec.remoteObjectInterface = FinchXPCTestInterface();
    printf("endpoint connection: %s, serviceName %s\n", scrub(ec).UTF8String, ec.serviceName ? ec.serviceName.UTF8String : "nil");
    [ec resume];
    info = nil;
    [[ec remoteObjectProxyWithErrorHandler:^(NSError *e) { print_error(@"unexpected error", e); dispatch_semaphore_signal(s); }]
        serverInfo:^(NSDictionary *d) { info = d; dispatch_semaphore_signal(s); }];
    wait_for(s);
    check([info[@"anonymous"] boolValue] && [info[@"pid"] intValue] == servicePid && [info[@"currentConnection"] boolValue],
        @"the endpoint reaches the service's anonymous listener");
    printf("endpoint connection after a message: %s\n", scrub(ec).UTF8String);
    [ec invalidate];
    (void)lastError;
}

/* The receiver rejects an argument whose class the interface doesn't allow. */
static void
test_secure_coding(NSXPCConnection *c, int *interruptions)
{
    printf("-- secure coding\n");
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    __block NSError *err = nil;
    __block BOOL replied = NO;
    int before = *interruptions;
    FinchXPCThing *thing = [FinchXPCThing new];
    [[c remoteObjectProxyWithErrorHandler:^(NSError *e) { err = e; dispatch_semaphore_signal(s); }]
        echo:thing reply:^(id same) { replied = YES; dispatch_semaphore_signal(s); }];
    wait_for(s);
    printf("a class the interface doesn't allow: replied=%d error=%ld\n", replied, (long)err.code);
    usleep(300000);
    printf("  interruption handler: %s\n", *interruptions > before ? "called" : "not called");
}

static void
test_interruption(NSXPCConnection *c, int *interruptions)
{
    printf("-- interruption (the service is killed)\n");
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    __block NSError *err = nil;
    __block BOOL replied = NO;
    int before = *interruptions;
    id<FinchXPCTestProtocol> p = [c remoteObjectProxyWithErrorHandler:^(NSError *e) { err = e; dispatch_semaphore_signal(s); }];
    __block NSDictionary *info = nil;
    [p serverInfo:^(NSDictionary *d) { info = d; dispatch_semaphore_signal(s); }];
    wait_for(s);
    servicePid = [info[@"pid"] intValue];
    [p delayedReply:10 reply:^(NSString *a) { replied = YES; dispatch_semaphore_signal(s); }];
    usleep(200000);
    kill(servicePid, SIGKILL);
    check(wait_for(s) && !replied, @"a pending reply fails");
    printf("  its error: %s %ld\n", err.domain.UTF8String, (long)err.code);   /* Apple names the pid or not, by timing */
    usleep(300000);
    check(*interruptions == before + 1, @"the interruption handler runs once");
    pid_t old = servicePid;
    info = nil;
    [p serverInfo:^(NSDictionary *d) { info = d; dispatch_semaphore_signal(s); }];
    wait_for(s);
    servicePid = [info[@"pid"] intValue];
    check(info != nil && servicePid > 0 && servicePid != old, @"the next message relaunches the service");

    printf("-- the service exits by itself\n");
    before = *interruptions;
    old = servicePid;
    [p exitNow];
    usleep(500000);
    check(*interruptions == before + 1, @"the interruption handler runs");
    info = nil;
    [p serverInfo:^(NSDictionary *d) { info = d; dispatch_semaphore_signal(s); }];
    wait_for(s);
    servicePid = [info[@"pid"] intValue];
    check(info != nil && servicePid != old, @"and the service comes back");
}

static void
test_invalidation(NSXPCConnection *c, int *invalidations, int *interruptions)
{
    printf("-- invalidation\n");
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    __block NSError *err = nil;
    __block int errors = 0;
    __block BOOL replied = NO;
    int interruptionsBefore = *interruptions;
    id<FinchXPCTestProtocol> p = [c remoteObjectProxyWithErrorHandler:^(NSError *e) {
        err = e;
        errors++;
        dispatch_semaphore_signal(s);
    }];
    [p delayedReply:2 reply:^(NSString *a) { replied = YES; dispatch_semaphore_signal(s); }];
    usleep(200000);
    [c invalidate];
    check(wait_for(s) && !replied, @"a pending reply fails");
    print_error(@"  its error", err);
    usleep(200000);
    check(*invalidations == 1, @"the invalidation handler runs once");
    check(*interruptions == interruptionsBefore, @"the interruption handler doesn't run");
    check(c.interruptionHandler == nil && c.invalidationHandler == nil, @"both handlers are released");
    err = nil;
    [p add:1 to:1 reply:^(NSInteger r) { replied = YES; dispatch_semaphore_signal(s); }];
    check(wait_for(s) && !replied, @"a message after invalidation fails");
    print_error(@"  its error", err);
    errors = 0;
    [p ping];
    [(id<FinchXPCTestProtocol>)c.remoteObjectProxy add:1 to:1 reply:^(NSInteger r) { replied = YES; }];
    usleep(300000);
    printf("one-way and handler-less messages after invalidation: %d error(s), replied=%d\n", errors, replied);
    [c invalidate];
    usleep(100000);
    check(*invalidations == 1, @"invalidating again does nothing");
}

static void
test_missing_service(void)
{
    printf("-- a service that doesn't exist\n");
    NSXPCConnection *c = [[NSXPCConnection alloc] initWithServiceName:@"org.finch.test.nonexistent"];
    printf("connection: %s, serviceName %s\n", scrub(c).UTF8String, c.serviceName.UTF8String);
    c.remoteObjectInterface = FinchXPCTestInterface();
    dispatch_semaphore_t s = dispatch_semaphore_create(0), inv = dispatch_semaphore_create(0);
    c.invalidationHandler = ^{ dispatch_semaphore_signal(inv); };
    [c resume];
    __block NSError *err = nil;
    [[c remoteObjectProxyWithErrorHandler:^(NSError *e) { err = e; dispatch_semaphore_signal(s); }] ping];
    [[c remoteObjectProxyWithErrorHandler:^(NSError *e) { err = e; dispatch_semaphore_signal(s); }] add:1 to:2 reply:^(NSInteger r) { }];
    wait_for(s);
    print_error(@"error", err);
    check(wait_for(inv), @"the invalidation handler runs");

    NSXPCConnection *m = [[NSXPCConnection alloc] initWithMachServiceName:@"org.finch.test.nonexistent.mach" options:NSXPCConnectionPrivileged];
    printf("mach connection: %s, serviceName %s\n", scrub(m).UTF8String, m.serviceName.UTF8String);
    m.remoteObjectInterface = FinchXPCTestInterface();
    [m resume];
    __block BOOL called = NO;
    [[m synchronousRemoteObjectProxyWithErrorHandler:^(NSError *e) { err = e; called = YES; }] add:1 to:2 reply:^(NSInteger r) { }];
    printf("synchronous proxy: error handler ran before the call returned: %s\n", called ? "yes" : "no");
    print_error(@"error", err);
    [m invalidate];
}

#pragma mark - In-process

static NSXPCInterface *
local_interface(void)
{
    NSXPCInterface *i = [NSXPCInterface interfaceWithProtocol:@protocol(FinchXPCBadProtocol)];
    [i setClasses:[NSSet setWithObject:[NSURL class]] forSelector:@selector(takesThing:array:string:number:anything:count:reply:) argumentIndex:4 ofReply:NO];
    return i;
}

static NSString *acceptedLine;

@interface FinchXPCLocal : NSObject <FinchXPCBadProtocol, NSXPCListenerDelegate>
@end

@implementation FinchXPCLocal
- (NSInteger)returnsSomething { return 1; }
- (void)twoBlocks:(void (^)(void))a and:(void (^)(void))b { }
- (void)takesThing:(FinchXPCThing *)thing array:(NSArray *)array string:(NSString *)s number:(NSNumber *)n
    anything:(id)anything count:(NSInteger)count reply:(void (^)(NSDictionary *, NSString *))reply
{
    reply(@{@"thing": thing.name ?: @"nil", @"array": array, @"number": n, @"anything": [anything description] ?: @"nil", @"count": @(count)}, s);
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    acceptedLine = [NSString stringWithFormat:@"delegate: main=%d; new connection: %@", [NSThread isMainThread], scrub(connection)];
    connection.exportedInterface = local_interface();
    connection.exportedObject = self;
    [connection resume];
    return YES;
}
@end

@interface FinchXPCRefuser : NSObject <NSXPCListenerDelegate>
@end

@implementation FinchXPCRefuser
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection { return NO; }
@end

static void
test_in_process(void)
{
    printf("-- an anonymous listener in this process\n");
    FinchXPCLocal *local = [FinchXPCLocal new];
    NSXPCListener *l = [NSXPCListener anonymousListener];
    l.delegate = local;
    [l resume];
    printf("listener: %s\n", scrub(l).UTF8String);
    NSXPCConnection *c = [[NSXPCConnection alloc] initWithListenerEndpoint:l.endpoint];
    c.remoteObjectInterface = local_interface();
    [c resume];
    id<FinchXPCBadProtocol> p = [c remoteObjectProxy];
    printf("proxy class: %s\n", object_getClassName(p));
    @try {
        NSInteger r = [p returnsSomething];
        printf("non-void return: %ld\n", (long)r);
    } @catch (NSException *e) {
        printf("non-void return: %s: %s\n", e.name.UTF8String, e.reason.UTF8String);
    }
    @try {
        [p twoBlocks:^{ } and:^{ }];
        printf("two blocks: no exception\n");
    } @catch (NSException *e) {
        printf("two blocks: %s: %s\n", e.name.UTF8String, e.reason.UTF8String);
    }
    @try {
        [(id)p performSelector:@selector(notInTheProtocol)];
        printf("not in the protocol: no exception\n");
    } @catch (NSException *e) {
        printf("not in the protocol: %s: %s\n", e.name.UTF8String, scrub(e.reason).UTF8String);
    }
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    __block NSDictionary *d = nil;
    __block NSString *str = nil;
    FinchXPCThing *t = [FinchXPCThing new];
    t.name = @"local";
    [p takesThing:t array:@[@1] string:@"s" number:@3 anything:[NSURL URLWithString:@"https://finch.example/a?b"] count:-7
        reply:^(NSDictionary *dd, NSString *ss) { d = dd; str = ss; dispatch_semaphore_signal(s); }];
    check(wait_for(s), @"in-process round trip");
    printf("%s\n", acceptedLine.UTF8String);
    printf("in-process: %s %s\n", [scrub(d) stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String, str.UTF8String);
    printf("connection: %s\n", scrub(c).UTF8String);
    [c invalidate];
    [l invalidate];

    printf("-- a listener that refuses\n");
    FinchXPCRefuser *refuser = [FinchXPCRefuser new];
    NSXPCListener *r = [NSXPCListener anonymousListener];
    r.delegate = refuser;
    [r resume];
    NSXPCConnection *rc = [[NSXPCConnection alloc] initWithListenerEndpoint:r.endpoint];
    rc.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(FinchXPCBadProtocol)];
    dispatch_semaphore_t inv = dispatch_semaphore_create(0);
    rc.invalidationHandler = ^{ dispatch_semaphore_signal(inv); };
    [rc resume];
    __block NSError *err = nil;
    [[rc remoteObjectProxyWithErrorHandler:^(NSError *e) { err = e; dispatch_semaphore_signal(s); }]
        takesThing:nil array:nil string:nil number:nil anything:nil count:0 reply:^(NSDictionary *dd, NSString *ss) { }];
    wait_for(s);
    print_error(@"refused", err);
    printf("the refused connection's invalidation handler: %s\n", dispatch_semaphore_wait(inv, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0 ? "called" : "not called");
    [r invalidate];
}

int
main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        test_interface();
        test_in_process();

        static int interruptions, invalidations;
        NSXPCConnection *c = service_connection();
        printf("-- connection to %s\n", FINCH_NSXPC_SERVICE.UTF8String);
        printf("connection: %s, serviceName %s\n", scrub(c).UTF8String, c.serviceName.UTF8String);
        c.interruptionHandler = ^{ interruptions++; };
        c.invalidationHandler = ^{ invalidations++; };
        [c resume];
        test_messages(c);
        test_secure_coding(c, &interruptions);
        test_interruption(c, &interruptions);
        test_invalidation(c, &invalidations, &interruptions);
        test_missing_service();
    }
    printf("%s\n", failures ? "FAILED" : "PASSED: NSXPCConnection");
    return failures != 0;
}
