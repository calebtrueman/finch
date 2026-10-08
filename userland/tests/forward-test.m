/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-forward-test: Objective-C message forwarding and NSInvocation, which
 * CoreFoundation provides. One result per line, so runs against Apple's
 * CoreFoundation and Finch's can be diffed (addresses are masked).
 *
 *   - unrecognized selectors raise NSInvalidArgumentException
 *   - -forwardingTargetForSelector: and -forwardInvocation: (a proxy)
 *   - NSInvocation built by hand: arguments and results of every kind the
 *     arm64 ABI treats differently (sub-word integers, floats, homogeneous
 *     float aggregates, 16-byte and larger structs, stack arguments)
 *   - NSMethodSignature and NSObject's -description
 *
 * Built without ARC; links only CoreFoundation.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <string.h>

typedef struct { double x, y, w, h; } FRect;            /* an HFA of four doubles */
typedef struct { float a, b; } Pairf;                   /* an HFA of two floats */
typedef struct { unsigned long loc, len; } Range;       /* 16 bytes: x0, x1 */
typedef struct { long a, b, c, d, e; } Big;             /* 40 bytes: by reference, x8 */
typedef struct { char c; short s; } Small;              /* 4 bytes in one x register */

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *);

@interface NSMethodSignature : NSObject
+ (instancetype)signatureWithObjCTypes:(const char *)types;
- (NSUInteger)numberOfArguments;
- (const char *)getArgumentTypeAtIndex:(NSUInteger)idx;
- (NSUInteger)frameLength;
- (const char *)methodReturnType;
- (NSUInteger)methodReturnLength;
- (BOOL)isOneway;
@end
@interface NSInvocation : NSObject
+ (NSInvocation *)invocationWithMethodSignature:(NSMethodSignature *)sig;
- (void)setTarget:(id)t;
- (id)target;
- (void)setSelector:(SEL)s;
- (SEL)selector;
- (void)setArgument:(void *)v atIndex:(NSInteger)i;
- (void)getArgument:(void *)v atIndex:(NSInteger)i;
- (void)getReturnValue:(void *)v;
- (void)setReturnValue:(void *)v;
- (void)invoke;
- (void)invokeWithTarget:(id)t;
- (void)retainArguments;
- (BOOL)argumentsRetained;
- (NSMethodSignature *)methodSignature;
@end
@interface NSException : NSObject
- (id)name;
- (id)reason;
@end
@interface NSObject (Forwarding)
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel;
+ (NSMethodSignature *)instanceMethodSignatureForSelector:(SEL)sel;
- (id)description;
+ (id)description;
@end

@interface Calc : NSObject
- (int)add:(int)a to:(int)b;
- (int)widen:(char)c short:(short)s uchar:(unsigned char)u;
- (double)mix:(double)a f:(float)b i:(int)c;
- (long)many:(long)a :(long)b :(long)c :(long)d :(long)e :(long)f :(long)g :(long)h :(long)i :(char)j :(long)k;
- (double)manyd:(double)a :(double)b :(double)c :(double)d :(double)e :(double)f :(double)g :(double)h :(float)i :(double)j;
- (FRect)rectFrom:(double)x :(double)y;
- (double)area:(FRect)r;
- (Range)rangeFrom:(Range)r shift:(long)n;
- (Big)big:(Big)b times:(long)n;
- (Pairf)swap:(Pairf)p;
- (long)small:(Small)s;
- (id)echo:(id)o;
- (void)nothing;
@end

@implementation Calc
- (int)add:(int)a to:(int)b { return a + b; }
- (int)widen:(char)c short:(short)s uchar:(unsigned char)u { return c * 1000000 + s * 1000 + u; }
- (double)mix:(double)a f:(float)b i:(int)c { return a * b + c; }
- (long)many:(long)a :(long)b :(long)c :(long)d :(long)e :(long)f :(long)g :(long)h :(long)i :(char)j :(long)k
{
    return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + 9 * i + 10 * j + 11 * k;
}
- (double)manyd:(double)a :(double)b :(double)c :(double)d :(double)e :(double)f :(double)g :(double)h :(float)i :(double)j
{
    return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10;
}
- (FRect)rectFrom:(double)x :(double)y { return (FRect){ x, y, x * 2, y * 2 }; }
- (double)area:(FRect)r { return r.w * r.h + r.x - r.y; }
- (Range)rangeFrom:(Range)r shift:(long)n { return (Range){ r.loc + (unsigned long)n, r.len * 2 }; }
- (Big)big:(Big)b times:(long)n { return (Big){ b.a * n, b.b * n, b.c * n, b.d * n, b.e * n }; }
- (Pairf)swap:(Pairf)p { return (Pairf){ p.b, p.a }; }
- (long)small:(Small)s { return s.c * 100000L + s.s; }
- (id)echo:(id)o { return o; }
- (void)nothing { }
@end

/* Forwards every message to a Calc, through -forwardingTargetForSelector:. */
@interface Redirect : NSObject
@end
@implementation Redirect
- (id)forwardingTargetForSelector:(SEL)sel { static Calc *c; if (!c) c = [[Calc alloc] init]; return c; }
@end

/* A proxy that sees every message as an NSInvocation, records it, passes it
 * on, and doubles int results. */
@interface Proxy : NSObject {
@public
    Calc *target;
    int seen;
    char last[64];
}
@end
@implementation Proxy
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)inv
{
    seen++;
    snprintf(last, sizeof(last), "%s", sel_getName([inv selector]));
    [inv invokeWithTarget:target];
    if (!strcmp([[inv methodSignature] methodReturnType], "i")) {
        int r;
        [inv getReturnValue:&r];
        r *= 2;
        [inv setReturnValue:&r];
    }
}
@end

static void
cstr(const char *what, CFTypeRef s)
{
    char buf[256] = "(null)";
    if (s) CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
    for (char *p = strstr(buf, "0x"); p; p = strstr(p, "0x")) {        /* mask addresses */
        char *e = p + 2;
        while ((*e >= '0' && *e <= '9') || (*e >= 'a' && *e <= 'f')) e++;
        memmove(p + 6, e, strlen(e) + 1);
        memcpy(p, "0xADDR", 6);
        p += 6;
    }
    printf("%s: %s\n", what, buf);
}

static void
raises(const char *what, void (^b)(void))
{
    @try { b(); printf("%s: no exception\n", what); }
    @catch (NSException *e) {
        char n[64];
        CFStringGetCString((CFStringRef)[e name], n, sizeof(n), kCFStringEncodingUTF8);
        printf("%s: %s, ", what, n);
        cstr("reason", (CFTypeRef)[e reason]);
    }
}

int
main(int argc, char **argv)
{
    if (argc < 2 || strcmp(argv[1], "--no-path")) {
        Dl_info info;
        printf("CoreFoundation: %s\n", dladdr((void *)CFArrayGetCount, &info) ? info.dli_fname : "?");
    }
    void *pool = objc_autoreleasePoolPush();
    Calc *calc = [[Calc alloc] init];

    /* Unrecognized selectors. */
    raises("instance", ^{ ((void (*)(id, SEL))objc_msgSend)(calc, sel_registerName("frobnicate:")); });
    raises("class", ^{ ((void (*)(id, SEL))objc_msgSend)([Calc class], sel_registerName("frobnicate")); });
    raises("root NSObject", ^{ ((void (*)(id, SEL))objc_msgSend)([[NSObject alloc] init], sel_registerName("count")); });

    /* Forwarding target. */
    Redirect *rd = [[Redirect alloc] init];
    printf("redirect add: %d\n", [(Calc *)rd add:40 to:2]);
    printf("redirect mix: %.3f\n", [(Calc *)rd mix:1.5 f:2.0f i:3]);
    FRect rr = [(Calc *)rd rectFrom:1.5 :2.5];
    printf("redirect rect: %.1f %.1f %.1f %.1f\n", rr.x, rr.y, rr.w, rr.h);
    Big bb = [(Calc *)rd big:(Big){ 1, 2, 3, 4, 5 } times:3];
    printf("redirect big: %ld %ld %ld %ld %ld\n", bb.a, bb.b, bb.c, bb.d, bb.e);
    printf("redirect many: %ld\n", [(Calc *)rd many:1 :2 :3 :4 :5 :6 :7 :8 :9 :-2 :11]);

    /* forwardInvocation: */
    Proxy *px = [[Proxy alloc] init];
    px->target = calc;
    printf("proxy add (doubled): %d\n", [(Calc *)px add:20 to:1]);
    printf("proxy widen (doubled): %d\n", [(Calc *)px widen:-3 short:-7 uchar:250]);
    printf("proxy mix: %.3f\n", [(Calc *)px mix:-2.25 f:4.0f i:10]);
    printf("proxy many: %ld\n", [(Calc *)px many:1 :1 :1 :1 :1 :1 :1 :1 :1 :-1 :1]);
    printf("proxy manyd: %.2f\n", [(Calc *)px manyd:1 :1 :1 :1 :1 :1 :1 :1 :0.5f :2]);
    rr = [(Calc *)px rectFrom:3 :4];
    printf("proxy rect: %.1f %.1f %.1f %.1f\n", rr.x, rr.y, rr.w, rr.h);
    printf("proxy area: %.2f\n", [(Calc *)px area:(FRect){ 1, 2, 3, 4 }]);
    Range rg = [(Calc *)px rangeFrom:(Range){ 10, 5 } shift:7];
    printf("proxy range: %lu %lu\n", rg.loc, rg.len);
    bb = [(Calc *)px big:(Big){ -1, 2, -3, 4, -5 } times:-2];
    printf("proxy big: %ld %ld %ld %ld %ld\n", bb.a, bb.b, bb.c, bb.d, bb.e);
    Pairf pf = [(Calc *)px swap:(Pairf){ 1.25f, -8.5f }];
    printf("proxy swap: %.2f %.2f\n", pf.a, pf.b);
    printf("proxy small: %ld\n", [(Calc *)px small:(Small){ -4, 321 }]);
    printf("proxy echo is same: %d\n", [(Calc *)px echo:(id)calc] == (id)calc);
    [(Calc *)px nothing];
    printf("proxy saw %d messages, last %s\n", px->seen, px->last);
    raises("proxy unknown", ^{ ((void (*)(id, SEL))objc_msgSend)(px, sel_registerName("unknownThing")); });

    /* NSInvocation by hand. */
    NSMethodSignature *sig = [calc methodSignatureForSelector:@selector(many::::::::::::)];
    sig = [calc methodSignatureForSelector:sel_registerName("many:::::::::::")];
    printf("many: args %lu frame %lu ret %s/%lu\n", (unsigned long)[sig numberOfArguments],
        (unsigned long)[sig frameLength], [sig methodReturnType], (unsigned long)[sig methodReturnLength]);
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:calc];
    [inv setSelector:sel_registerName("many:::::::::::")];
    for (long i = 2; i < 13; i++) {
        if (i == 11) { char c = -5; [inv setArgument:&c atIndex:i]; }
        else { long v = i * 10; [inv setArgument:&v atIndex:i]; }
    }
    [inv invoke];
    long lr;
    [inv getReturnValue:&lr];
    printf("invoke many: %ld\n", lr);
    char cg;
    [inv getArgument:&cg atIndex:11];
    printf("argument 11 back: %d\n", cg);

    inv = [NSInvocation invocationWithMethodSignature:[calc methodSignatureForSelector:@selector(big:times:)]];
    [inv setSelector:@selector(big:times:)];
    Big in = { 7, 8, 9, 10, 11 };
    long times = 4;
    [inv setArgument:&in atIndex:2];
    [inv setArgument:&times atIndex:3];
    [inv invokeWithTarget:calc];
    [inv getReturnValue:&bb];
    printf("invoke big: %ld %ld %ld %ld %ld\n", bb.a, bb.b, bb.c, bb.d, bb.e);

    inv = [NSInvocation invocationWithMethodSignature:[calc methodSignatureForSelector:@selector(area:)]];
    [inv setSelector:@selector(area:)];
    FRect ar = { 0.5, 0.25, 6, 7 };
    [inv setArgument:&ar atIndex:2];
    [inv invokeWithTarget:calc];
    double dr;
    [inv getReturnValue:&dr];
    printf("invoke area: %.3f\n", dr);

    inv = [NSInvocation invocationWithMethodSignature:[calc methodSignatureForSelector:@selector(manyd::::::::::)]];
    [inv setSelector:@selector(manyd::::::::::)];
    for (int i = 2; i < 12; i++) {
        if (i == 10) { float f = 1.5f; [inv setArgument:&f atIndex:i]; }
        else { double d = i; [inv setArgument:&d atIndex:i]; }
    }
    [inv invokeWithTarget:calc];
    [inv getReturnValue:&dr];
    printf("invoke manyd: %.2f\n", dr);

    inv = [NSInvocation invocationWithMethodSignature:[calc methodSignatureForSelector:@selector(echo:)]];
    CFStringRef s = CFStringCreateWithCString(NULL, "retained by the invocation", kCFStringEncodingUTF8);  /* too long to be a tagged pointer */
    CFIndex before = CFGetRetainCount(s);
    [inv setArgument:&s atIndex:2];
    [inv retainArguments];
    printf("retainArguments retains: %d (%d)\n", CFGetRetainCount(s) == before + 1, [inv argumentsRetained]);
    CFRelease(s);

    raises("invocation index", ^{ long x = 0; [[NSInvocation invocationWithMethodSignature:[calc methodSignatureForSelector:@selector(nothing)]] setArgument:&x atIndex:5]; });

    /* Signatures. */
    NSMethodSignature *t = [NSMethodSignature signatureWithObjCTypes:"{_R=QQ}40@0:8^v16r*24Vv32"];
    printf("signature: args %lu ret %s/%lu frame %lu\n", (unsigned long)[t numberOfArguments], [t methodReturnType],
        (unsigned long)[t methodReturnLength], (unsigned long)[t frameLength]);
    for (NSUInteger i = 0; i < [t numberOfArguments]; i++) printf("  %lu: %s\n", (unsigned long)i, [t getArgumentTypeAtIndex:i]);
    printf("instanceMethodSignatureForSelector nil for unknown: %d\n", [Calc instanceMethodSignatureForSelector:sel_registerName("nope")] == nil);
    printf("oneway: %d %d\n", [[NSMethodSignature signatureWithObjCTypes:"Vv@:"] isOneway], [t isOneway]);

    /* Descriptions. */
    cstr("instance description", (CFTypeRef)[calc description]);
    cstr("class description", (CFTypeRef)[Calc description]);

    objc_autoreleasePoolPop(pool);
    printf("done\n");
    return 0;
}
