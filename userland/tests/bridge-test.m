/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-bridge-test: toll-free bridging in both directions, against
 * CoreFoundation alone (the classes it hosts: NSArray, NSMutableArray,
 * NSException, NSEnumerator). Prints one result per line, so runs against
 * Apple's CoreFoundation and Finch's can be diffed (as finch-cf-test is).
 * Class names of concrete objects differ between the two (__NSArrayI vs
 * __NSCFArray) and aren't printed.
 *
 *   - CF functions on an Objective-C subclass of NSArray (ObjC dispatch)
 *   - NSArray messages on CFArrays, and the NSArray class cluster
 *   - exceptions CF-hosted classes raise
 *
 * Built without ARC; links only CoreFoundation (which re-exports libobjc).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef struct _NSRange { NSUInteger location, length; } NSRange;
typedef struct { unsigned long state; id *itemsPtr; unsigned long *mutationsPtr; unsigned long extra[5]; } NSFastEnumerationState;

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);

@interface NSObject (Bridge)
- (NSUInteger)hash;
@end

@interface NSArray : NSObject
+ (instancetype)array;
+ (instancetype)arrayWithObjects:(const id *)objects count:(NSUInteger)count;
+ (instancetype)arrayWithObjects:(id)first, ...;
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)idx;
- (id)firstObject;
- (id)lastObject;
- (NSUInteger)indexOfObject:(id)object;
- (BOOL)containsObject:(id)object;
- (BOOL)isEqualToArray:(NSArray *)other;
- (NSArray *)arrayByAddingObject:(id)object;
- (NSArray *)subarrayWithRange:(NSRange)range;
- (id)objectEnumerator;
- (id)reverseObjectEnumerator;
- (void)enumerateObjectsUsingBlock:(void (^)(id obj, NSUInteger idx, BOOL *stop))block;
- (void)getObjects:(id *)objects range:(NSRange)range;
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id *)buffer count:(NSUInteger)len;
@end
@interface NSMutableArray : NSArray
+ (instancetype)arrayWithCapacity:(NSUInteger)n;
- (void)addObject:(id)object;
- (void)insertObject:(id)object atIndex:(NSUInteger)idx;
- (void)removeObjectAtIndex:(NSUInteger)idx;
- (void)replaceObjectAtIndex:(NSUInteger)idx withObject:(id)object;
- (void)exchangeObjectAtIndex:(NSUInteger)a withObjectAtIndex:(NSUInteger)b;
- (void)removeAllObjects;
- (void)removeObject:(id)object;
- (void)addObjectsFromArray:(NSArray *)array;
@end
@interface NSEnumerator : NSObject
- (id)nextObject;
- (NSArray *)allObjects;
@end
@interface NSException : NSObject
+ (instancetype)exceptionWithName:(id)name reason:(id)reason userInfo:(id)info;
- (id)name;
- (id)reason;
- (void)raise;
@end
extern id NSRangeException, NSInvalidArgumentException, NSInternalInconsistencyException;

/* An NSArray subclass that CF has never seen: three fixed strings. */
@interface Trio : NSArray
@end
@implementation Trio
- (NSUInteger)count { return 3; }
- (id)objectAtIndex:(NSUInteger)i
{
    static CFStringRef s[3];
    s[0] = CFSTR("one"); s[1] = CFSTR("two"); s[2] = CFSTR("three");
    return (id)s[i];
}
@end

static int failures;
static void check(const char *what, int ok) { printf("%s: %s\n", what, ok ? "ok" : "FAIL"); failures += !ok; }

static void
show(const char *what, CFTypeRef cf)
{
    char buf[512] = "(null)";
    if (cf) {
        CFStringRef d = CFGetTypeID(cf) == CFStringGetTypeID() ? CFRetain(cf) : CFCopyDescription(cf);
        CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8);
        CFRelease(d);
    }
    printf("%s: %s\n", what, buf);
}

/* Run block; print the name of the exception it raises, if any. */
static void
raises(const char *what, void (^block)(void))
{
    @try {
        block();
        printf("%s: no exception\n", what);
    } @catch (NSException *e) {
        show(what, (CFTypeRef)[e name]);
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

    /* ObjC -> CF: CF functions on an object CF didn't make. */
    Trio *t = [[Trio alloc] init];
    CFArrayRef tcf = (CFArrayRef)t;
    check("CFGetTypeID(subclass) is CFArray", CFGetTypeID(tcf) == CFArrayGetTypeID());
    printf("CFArrayGetCount(subclass): %ld\n", (long)CFArrayGetCount(tcf));
    show("CFArrayGetValueAtIndex(subclass, 1)", CFArrayGetValueAtIndex(tcf, 1));
    const void *vals[3];
    CFArrayGetValues(tcf, CFRangeMake(0, 3), vals);
    show("CFArrayGetValues(subclass)[2]", vals[2]);
    check("CFArrayContainsValue(subclass, two)", CFArrayContainsValue(tcf, CFRangeMake(0, 3), CFSTR("two")));
    printf("CFArrayGetFirstIndexOfValue(subclass, three): %ld\n",
        (long)CFArrayGetFirstIndexOfValue(tcf, CFRangeMake(0, 3), CFSTR("three")));
    CFIndex rc = CFGetRetainCount(tcf);
    CFRetain(tcf);
    check("CFRetain(subclass) counts", CFGetRetainCount(tcf) == rc + 1);
    CFRelease(tcf);
    check("CFRelease(subclass) counts", CFGetRetainCount(tcf) == rc);

    const void *same[3] = { CFSTR("one"), CFSTR("two"), CFSTR("three") };
    CFArrayRef cfa = CFArrayCreate(NULL, same, 3, &kCFTypeArrayCallBacks);
    check("CFEqual(CFArray, subclass)", CFEqual(cfa, tcf));
    check("CFEqual(subclass, CFArray)", CFEqual(tcf, cfa));
    check("CFHash(subclass) == CFHash(CFArray)", CFHash(tcf) == CFHash(cfa));
    CFArrayRef copy = CFArrayCreateCopy(NULL, tcf);
    check("CFArrayCreateCopy(subclass) equal", CFEqual(copy, cfa));
    CFRelease(copy);
    CFMutableArrayRef mcopy = CFArrayCreateMutableCopy(NULL, 0, tcf);
    CFArrayAppendValue(mcopy, CFSTR("four"));
    printf("mutable copy of subclass, appended: %ld\n", (long)CFArrayGetCount(mcopy));
    CFRelease(mcopy);
    CFArrayRef nested = CFArrayCreate(NULL, (const void *[]){ tcf }, 1, &kCFTypeArrayCallBacks);
    check("CFEqual(nested CFArray of subclass, of CFArray)",
        CFEqual(nested, CFArrayCreate(NULL, (const void *[]){ cfa }, 1, &kCFTypeArrayCallBacks)));

    /* CF -> ObjC: NSArray messages on CF arrays. */
    NSArray *a = (NSArray *)cfa;
    check("CFArray isKindOfClass NSArray", [a isKindOfClass:[NSArray class]]);
    printf("[CFArray count]: %lu\n", (unsigned long)[a count]);
    show("[CFArray objectAtIndex:0]", (CFTypeRef)[a objectAtIndex:0]);
    show("[CFArray lastObject]", (CFTypeRef)[a lastObject]);
    printf("[CFArray indexOfObject:two]: %lu\n", (unsigned long)[a indexOfObject:(id)CFSTR("two")]);
    check("[CFArray isEqual:subclass]", [a isEqual:t]);
    check("[subclass isEqualToArray:CFArray]", [t isEqualToArray:a]);
    int n = 0;
    for (id o in a) n += o != nil;
    printf("fast enumeration of CFArray: %d\n", n);
    n = 0;
    for (id o in t) n += o != nil;
    printf("fast enumeration of subclass: %d\n", n);
    show("reverse enumerator first", (CFTypeRef)[[a reverseObjectEnumerator] nextObject]);
    printf("enumerator allObjects: %lu\n", (unsigned long)[[[t objectEnumerator] allObjects] count]);
    __block NSUInteger sum = 0;
    [a enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) { (void)obj; (void)stop; sum += idx; }];
    printf("block enumeration index sum: %lu\n", (unsigned long)sum);
    show("subarray {1, 2} last", (CFTypeRef)[[a subarrayWithRange:(NSRange){ 1, 2 }] lastObject]);
    show("arrayByAddingObject last", (CFTypeRef)[[t arrayByAddingObject:(id)CFSTR("four")] lastObject]);

    /* The class cluster. */
    NSArray *made = [NSArray arrayWithObjects:(id)CFSTR("x"), (id)CFSTR("y"), nil];
    check("+arrayWithObjects: is a CFArray", CFGetTypeID((CFTypeRef)made) == CFArrayGetTypeID());
    printf("+arrayWithObjects: count via CF: %ld\n", (long)CFArrayGetCount((CFArrayRef)made));
    NSMutableArray *m = [NSMutableArray arrayWithCapacity:4];
    [m addObject:(id)CFSTR("b")];
    [m insertObject:(id)CFSTR("a") atIndex:0];
    CFArrayAppendValue((CFMutableArrayRef)m, CFSTR("c"));
    [m exchangeObjectAtIndex:0 withObjectAtIndex:2];
    [m replaceObjectAtIndex:1 withObject:(id)CFSTR("B")];
    [m addObjectsFromArray:t];
    [m removeObject:(id)CFSTR("two")];
    [m removeObjectAtIndex:0];
    printf("mutable array: count %lu\n", (unsigned long)[m count]);
    for (NSUInteger i = 0; i < [m count]; i++) show("  element", (CFTypeRef)[m objectAtIndex:i]);
    check("[NSArray array] is empty", [[NSArray array] count] == 0);
    check("[NSArray alloc] is shared", [NSArray alloc] == [NSArray alloc]);

    /* Exceptions. */
    raises("objectAtIndex: past the end", ^{ [a objectAtIndex:7]; });
    raises("mutable objectAtIndex: past the end", ^{ [m objectAtIndex:9]; });
    raises("insert nil", ^{ [m insertObject:nil atIndex:0]; });
    raises("arrayWithObjects:count: with nil", ^{ id o[2] = { (id)CFSTR("x"), nil }; [NSArray arrayWithObjects:o count:2]; });
    raises("custom exception", ^{
        [[NSException exceptionWithName:(id)CFSTR("FinchTest") reason:(id)CFSTR("because") userInfo:nil] raise];
    });
    @try {
        [[NSException exceptionWithName:(id)CFSTR("FinchTest") reason:(id)CFSTR("because") userInfo:nil] raise];
    } @catch (NSException *e) {
        show("custom exception reason", (CFTypeRef)[e reason]);
    }
    raises("abstract count", ^{ [[[NSArray alloc] init] count]; [(NSArray *)class_createInstance([NSArray class], 0) count]; });

    [t release];
    objc_autoreleasePoolPop(pool);
    printf("done (%d failed checks)\n", failures);
    return failures != 0;
}
