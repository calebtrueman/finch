/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * What finch-nsxpc-test (nsxpc-test.m) and its XPC service
 * (nsxpc-service.m, org.finch.test.nsxpc.xpc) share: the protocols the
 * service exports and the client calls back, and a custom secure-coded class.
 */
#import <Foundation/Foundation.h>

#define FINCH_NSXPC_SERVICE @"org.finch.test.nsxpc"

/* A custom NSSecureCoding class, compiled into both processes. */
@interface FinchXPCThing : NSObject <NSSecureCoding>
@property (copy) NSString *name;
@property NSInteger count;
@property (copy) NSArray<NSString *> *tags;
@property NSRect frame;
@end

@implementation FinchXPCThing
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_name forKey:@"name"];
    [coder encodeInteger:_count forKey:@"count"];
    [coder encodeObject:_tags forKey:@"tags"];
    [coder encodeRect:_frame forKey:@"frame"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _name = [[coder decodeObjectOfClass:[NSString class] forKey:@"name"] copy];
        _count = [coder decodeIntegerForKey:@"count"];
        _tags = [[coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSString class], nil] forKey:@"tags"] copy];
        _frame = [coder decodeRectForKey:@"frame"];
    }
    return self;
}
- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ name=%@ count=%ld tags=%@ frame=%@>", [self class], _name, (long)_count,
        [_tags componentsJoinedByString:@","], NSStringFromRect(_frame)];
}
@end

/* The client's object the service calls back through a proxy argument. */
@protocol FinchXPCCallback
- (void)progress:(double)fraction message:(NSString *)message reply:(void (^)(BOOL keepGoing))reply;
@end

@protocol FinchXPCTestProtocol
- (void)ping;
- (void)countPings:(void (^)(NSInteger count))reply;
- (void)add:(NSInteger)a to:(NSInteger)b reply:(void (^)(NSInteger sum))reply;
- (void)scalarsChar:(char)c uchar:(unsigned char)uc short:(short)s int:(int)i long:(long)l
    ull:(unsigned long long)ull float:(float)f double:(double)d bool:(BOOL)b reply:(void (^)(NSString *description))reply;
- (void)geometryPoint:(NSPoint)p size:(NSSize)s rect:(NSRect)r range:(NSRange)range
    reply:(void (^)(NSRect rect, NSRange range, double sum))reply;
- (void)uppercase:(NSString *)s reply:(void (^)(NSString *upper, NSError *error))reply;
- (void)echo:(id)plist reply:(void (^)(id same))reply;
- (void)transform:(FinchXPCThing *)thing reply:(void (^)(FinchXPCThing *result))reply;
- (void)sortThings:(NSArray *)things reply:(void (^)(NSArray *sorted))reply;
- (void)failWithCode:(NSInteger)code reply:(void (^)(NSError *error))reply;
- (void)serverInfo:(void (^)(NSDictionary *info))reply;
- (void)makeAnonymousListener:(void (^)(NSXPCListenerEndpoint *endpoint))reply;
- (void)runCallback:(id<FinchXPCCallback>)callback steps:(NSInteger)steps reply:(void (^)(NSInteger completed))reply;
- (void)delayedReply:(double)seconds reply:(void (^)(NSString *answer))reply;
- (void)exitNow;
@end

/* The interfaces, built the same way on both sides. */
static inline NSXPCInterface *
FinchXPCTestInterface(void)
{
    NSXPCInterface *i = [NSXPCInterface interfaceWithProtocol:@protocol(FinchXPCTestProtocol)];
    NSSet *things = [NSSet setWithObjects:[NSArray class], [FinchXPCThing class], nil];
    [i setClasses:things forSelector:@selector(sortThings:reply:) argumentIndex:0 ofReply:NO];
    [i setClasses:things forSelector:@selector(sortThings:reply:) argumentIndex:0 ofReply:YES];
    [i setInterface:[NSXPCInterface interfaceWithProtocol:@protocol(FinchXPCCallback)]
        forSelector:@selector(runCallback:steps:reply:) argumentIndex:0 ofReply:NO];
    return i;
}
