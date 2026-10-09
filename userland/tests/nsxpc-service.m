/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * org.finch.test.nsxpc: the XPC service finch-nsxpc-test talks to, built as
 * an .xpc bundle inside the client's app (Contents/XPCServices). It serves
 * through +[NSXPCListener serviceListener], as an Xcode XPC service target
 * does. On macOS the host's launchd starts it for the app; on Finch,
 * finch-init starts it on demand (userland/tests/launchd/org.finch.test.nsxpc.plist).
 */
#import <Foundation/Foundation.h>
#include <unistd.h>

#include "nsxpc-test.h"

@interface FinchXPCTestService : NSObject <FinchXPCTestProtocol>
@property (weak) NSXPCConnection *connection;
@property BOOL anonymous;
@end

static NSInteger pings;
static NSMutableArray *anonymousListeners;

@interface FinchXPCAnonymousDelegate : NSObject <NSXPCListenerDelegate>
@end

@implementation FinchXPCTestService

- (void)ping { pings++; }
- (void)countPings:(void (^)(NSInteger))reply { reply(pings); }
- (void)add:(NSInteger)a to:(NSInteger)b reply:(void (^)(NSInteger))reply { reply(a + b); }

- (void)scalarsChar:(char)c uchar:(unsigned char)uc short:(short)s int:(int)i long:(long)l
    ull:(unsigned long long)ull float:(float)f double:(double)d bool:(BOOL)b reply:(void (^)(NSString *))reply
{
    reply([NSString stringWithFormat:@"c=%d uc=%u s=%d i=%d l=%ld ull=%llu f=%g d=%.17g b=%d", c, uc, s, i, l, ull, f, d, b]);
}

- (void)geometryPoint:(NSPoint)p size:(NSSize)s rect:(NSRect)r range:(NSRange)range
    reply:(void (^)(NSRect, NSRange, double))reply
{
    NSRect u = NSUnionRect(NSMakeRect(p.x, p.y, s.width, s.height), r);
    reply(u, NSMakeRange(range.location + 1, range.length * 2), p.x + p.y + s.width + s.height);
}

- (void)uppercase:(NSString *)s reply:(void (^)(NSString *, NSError *))reply
{
    if (s.length == 0) {
        reply(nil, [NSError errorWithDomain:@"org.finch.test" code:7 userInfo:@{NSLocalizedDescriptionKey: @"nothing to uppercase"}]);
        return;
    }
    reply(s.uppercaseString, nil);
}

- (void)echo:(id)plist reply:(void (^)(id))reply { reply(plist); }

- (void)transform:(FinchXPCThing *)thing reply:(void (^)(FinchXPCThing *))reply
{
    FinchXPCThing *t = [FinchXPCThing new];
    t.name = [thing.name stringByAppendingString:@"!"];
    t.count = thing.count * 10;
    t.tags = [thing.tags arrayByAddingObject:NSStringFromClass([thing class])];
    t.frame = NSOffsetRect(thing.frame, 1, 1);
    reply(t);
}

- (void)sortThings:(NSArray *)things reply:(void (^)(NSArray *))reply
{
    reply([things sortedArrayUsingComparator:^NSComparisonResult(FinchXPCThing *a, FinchXPCThing *b) {
        return [a.name compare:b.name];
    }]);
}

- (void)failWithCode:(NSInteger)code reply:(void (^)(NSError *))reply
{
    reply([NSError errorWithDomain:@"org.finch.test" code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"failure %ld", (long)code],
        @"detail": @[@1, @"two"],
    }]);
}

- (void)serverInfo:(void (^)(NSDictionary *))reply
{
    NSXPCConnection *c = [NSXPCConnection currentConnection];
    reply(@{
        @"pid": @(getpid()),
        @"anonymous": @(self.anonymous),
        @"mainThread": @([NSThread isMainThread]),
        @"currentConnection": @(c != nil && c == self.connection),
        @"peerPid": @(c.processIdentifier),
        @"peerUid": @(c.effectiveUserIdentifier),
        @"peerGid": @(c.effectiveGroupIdentifier),
        @"serviceName": c.serviceName ?: @"(null)",
    });
}

- (void)makeAnonymousListener:(void (^)(NSXPCListenerEndpoint *))reply
{
    NSXPCListener *l = [NSXPCListener anonymousListener];
    FinchXPCAnonymousDelegate *d = [FinchXPCAnonymousDelegate new];
    l.delegate = d;
    [anonymousListeners addObject:@[l, d]];   /* the listener's delegate is weak */
    [l resume];
    reply(l.endpoint);
}

- (void)runCallback:(id<FinchXPCCallback>)callback steps:(NSInteger)steps reply:(void (^)(NSInteger))reply
{
    __block NSInteger done = 0;
    __block void (^step)(void);
    void (^ __block __weak weakStep)(void);
    step = ^{
        if (done == steps) {
            reply(done);
            step = nil;
            return;
        }
        [callback progress:(double)(done + 1) / steps message:[NSString stringWithFormat:@"step %ld", (long)done + 1]
            reply:^(BOOL keepGoing) {
                done++;
                if (keepGoing) {
                    weakStep();
                } else {
                    reply(-done);
                    step = nil;
                }
            }];
    };
    weakStep = step;
    step();
}

- (void)delayedReply:(double)seconds reply:(void (^)(NSString *))reply
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            reply([NSString stringWithFormat:@"after %g s", seconds]);
        });
}

- (void)exitNow { exit(0); }

@end

@implementation FinchXPCAnonymousDelegate
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    FinchXPCTestService *s = [FinchXPCTestService new];
    s.connection = connection;
    s.anonymous = YES;
    connection.exportedInterface = FinchXPCTestInterface();
    connection.exportedObject = s;
    [connection resume];
    return YES;
}
@end

@interface FinchXPCServiceDelegate : NSObject <NSXPCListenerDelegate>
@end

@implementation FinchXPCServiceDelegate
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    FinchXPCTestService *s = [FinchXPCTestService new];
    s.connection = connection;
    connection.exportedInterface = FinchXPCTestInterface();
    connection.exportedObject = s;
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(FinchXPCCallback)];
    [connection resume];
    return YES;
}
@end

int
main(void)
{
    anonymousListeners = [NSMutableArray array];
    FinchXPCServiceDelegate *delegate = [FinchXPCServiceDelegate new];
    NSXPCListener *listener = [NSXPCListener serviceListener];
    listener.delegate = delegate;
    [listener resume];   /* never returns */
    return 1;
}
