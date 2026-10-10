/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-kvc-test: key-value coding, key-value observing, NSIndexSet,
 * NSValue and the geometry functions, one result per line so runs against
 * Apple's Foundation and Finch's can be diffed. Addresses are masked;
 * private class names (Apple's array classes, NSDecimalNumber's for @sum)
 * are not printed.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static const char *
masked(NSString *s)
{
    if (!s) return "(null)";
    NSMutableString *m = [s mutableCopy];
    for (NSRange r = [m rangeOfString:@"0x"]; r.location != NSNotFound; r = [m rangeOfString:@"0x" options:0 range:NSMakeRange(r.location + 3, m.length - r.location - 3)]) {
        NSUInteger end = r.location + 2;
        while (end < m.length && isxdigit([m characterAtIndex:end])) end++;
        [m replaceCharactersInRange:NSMakeRange(r.location, end - r.location) withString:@"0xA"];
    }
    return m.UTF8String;
}

static const char *
oneline(id o)
{
    return masked([[o description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
}

/* MARK: - KVC */

@interface Person : NSObject {
    NSString *_name;
    int age;
    BOOL _isHappy;
    NSRange r;
}
@property double height;
@end
@implementation Person
- (NSString *)getTitle { return @"Dr"; }
@end

@interface Closed : NSObject
@end
@implementation Closed
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
@end

static void
kvc(void)
{
    Person *p = [Person new];
    [p setValue:@"Ann" forKey:@"name"];
    [p setValue:@41 forKey:@"age"];
    [p setValue:@YES forKey:@"happy"];
    [p setValue:@1.75 forKey:@"height"];
    [p setValue:[NSValue valueWithRange:NSMakeRange(2, 3)] forKey:@"r"];
    printf("values: %s %s %s %s %s %s\n", oneline([p valueForKey:@"name"]), oneline([p valueForKey:@"age"]),
        oneline([p valueForKey:@"happy"]), oneline([p valueForKey:@"height"]), oneline([p valueForKey:@"title"]),
        oneline([p valueForKey:@"r"]));
    printf("boxed: %s %s\n", object_getClassName([p valueForKey:@"age"]), [[p valueForKey:@"r"] objCType]);
    @try { [p valueForKey:@"nope"]; } @catch (NSException *e) { printf("%s | %s\n", e.name.UTF8String, masked(e.reason)); }
    @try { [p setValue:@1 forKey:@"nope"]; } @catch (NSException *e) { printf("%s | %s\n", e.name.UTF8String, masked(e.reason)); }
    @try { [p setValue:nil forKey:@"age"]; } @catch (NSException *e) { printf("%s | %s\n", e.name.UTF8String, masked(e.reason)); }
    @try { [[Closed new] valueForKey:@"x"]; } @catch (NSException *e) { printf("%s | %s\n", e.name.UTF8String, masked(e.reason)); }

    NSArray *people = @[p, p];
    printf("array: %s\n", [[people valueForKey:@"name"] componentsJoinedByString:@","].UTF8String);
    NSArray *nums = @[@{@"v": @3}, @{@"v": @1}, @{@"v": @5}, @{@"v": @1}];
    printf("ops: %s %s %s %s %s %s\n", oneline([nums valueForKeyPath:@"@count"]), oneline([nums valueForKeyPath:@"@sum.v"]),
        oneline([nums valueForKeyPath:@"@avg.v"]), oneline([nums valueForKeyPath:@"@max.v"]), oneline([nums valueForKeyPath:@"@min.v"]),
        [[[nums valueForKeyPath:@"@distinctUnionOfObjects.v"] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
    printf("union: %s\n", [[nums valueForKeyPath:@"@unionOfObjects.v"] componentsJoinedByString:@","].UTF8String);

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setValue:@"x" forKey:@"k"];
    [d setValue:@{@"in": @"deep"} forKey:@"o"];
    printf("dict: %s %s %s\n", [[d valueForKey:@"k"] UTF8String], [[d valueForKeyPath:@"o.in"] UTF8String], oneline([d valueForKey:@"@count"]));
    [d setValue:nil forKey:@"k"];
    printf("removed: %lu\n", (unsigned long)d.count);
    printf("dictionaryWithValues: %s\n", oneline([p dictionaryWithValuesForKeys:@[@"name", @"age"]]));
    [p setValuesForKeysWithDictionary:@{@"name": @"Bo", @"age": @7}];
    printf("setValues: %s %d\n", [[p valueForKey:@"name"] UTF8String], [[p valueForKey:@"age"] intValue]);
}

/* MARK: - KVO */

@interface Model : NSObject
@property (copy) NSString *name;
@property int count;
@property NSRange r;
@property (strong) Model *child;
@property (readonly) NSString *greeting;
@property (strong) NSMutableArray *items;
@end
@implementation Model
+ (NSSet *)keyPathsForValuesAffectingGreeting { return [NSSet setWithObject:@"name"]; }
- (NSString *)greeting { return [@"hi " stringByAppendingString:self.name ?: @""]; }
@end

@interface Observer : NSObject
@end
@implementation Observer
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [c.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, [c[k] isKindOfClass:[NSIndexSet class]] ? @"<indexes>" : c[k]]];
    printf("observe %s ctx %ld: %s\n", kp.UTF8String, (long)ctx, [parts componentsJoinedByString:@" "].UTF8String);
}
@end

static void
kvo(void)
{
    Model *m = [Model new];
    Observer *o = [Observer new];
    m.name = @"a";
    printf("class before: %s\n", object_getClassName(m));
    [m addObserver:o forKeyPath:@"name" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:(void *)1];
    printf("class after: %s, -class %s\n", object_getClassName(m), class_getName([m class]));
    m.name = @"b";
    [m setValue:@"c" forKey:@"name"];
    [m addObserver:o forKeyPath:@"count" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionPrior context:(void *)2];
    m.count = 5;
    [m addObserver:o forKeyPath:@"r" options:NSKeyValueObservingOptionNew context:(void *)3];
    m.r = NSMakeRange(1, 2);
    [m addObserver:o forKeyPath:@"greeting" options:NSKeyValueObservingOptionNew context:(void *)4];
    m.name = @"d";
    Model *kid = [Model new];
    kid.name = @"k1";
    m.child = kid;
    [m addObserver:o forKeyPath:@"child.name" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:(void *)5];
    kid.name = @"k2";
    Model *kid2 = [Model new];
    kid2.name = @"k3";
    m.child = kid2;
    kid.name = @"ignored";
    m.items = [NSMutableArray array];
    [m addObserver:o forKeyPath:@"items" options:NSKeyValueObservingOptionNew context:(void *)6];
    [[m mutableArrayValueForKey:@"items"] addObject:@"x"];
    printf("items: %s\n", [m.items componentsJoinedByString:@","].UTF8String);
    [m willChangeValueForKey:@"name"];
    [m didChangeValueForKey:@"name"];
    [m removeObserver:o forKeyPath:@"name"];
    m.name = @"e";
    @try { [m removeObserver:o forKeyPath:@"name"]; } @catch (NSException *e) { printf("%s | %s\n", e.name.UTF8String, masked(e.reason)); }
    @try { [@[m] addObserver:o forKeyPath:@"x" options:0 context:NULL]; } @catch (NSException *e) {
        printf("%s | %s\n", e.name.UTF8String, [e.reason substringFromIndex:[e.reason rangeOfString:@">"].location].UTF8String);
    }
    for (NSString *k in @[@"count", @"r", @"greeting", @"child.name", @"items"]) [m removeObserver:o forKeyPath:k];
    printf("class after removing all: %s\n", object_getClassName(m));
}

/* MARK: - NSIndexSet */

static void
indexes(void)
{
    NSMutableIndexSet *s = [NSMutableIndexSet indexSet];
    [s addIndex:3];
    [s addIndexesInRange:NSMakeRange(5, 4)];
    [s addIndex:4];
    [s addIndex:20];
    printf("indexes: %s count %lu first %lu last %lu\n", oneline(s), (unsigned long)s.count, (unsigned long)s.firstIndex, (unsigned long)s.lastIndex);
    printf("contains: %d %d %d range %d\n", [s containsIndex:6], [s containsIndex:10], [s containsIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(3, 3)]],
        [s intersectsIndexesInRange:NSMakeRange(10, 5)]);
    printf("neighbours: %lu %lu %lu %lu\n", (unsigned long)[s indexGreaterThanIndex:8], (unsigned long)[s indexLessThanIndex:3],
        (unsigned long)[s indexGreaterThanOrEqualToIndex:9], (unsigned long)[s indexLessThanOrEqualToIndex:19]);
    [s removeIndexesInRange:NSMakeRange(5, 2)];
    [s shiftIndexesStartingAtIndex:10 by:-5];
    NSMutableArray *seen = [NSMutableArray array];
    [s enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { [seen addObject:@(i)]; }];
    printf("after edits: %s\n", [seen componentsJoinedByString:@","].UTF8String);
    [seen removeAllObjects];
    [s enumerateRangesUsingBlock:^(NSRange r, BOOL *stop) { [seen addObject:NSStringFromRange(r)]; }];
    printf("ranges: %s\n", [seen componentsJoinedByString:@" "].UTF8String);
    NSUInteger buf[8];
    NSRange within = NSMakeRange(0, 100);
    NSUInteger n = [s getIndexes:buf maxCount:2 inIndexRange:&within];
    printf("getIndexes: %lu -> %lu %lu, rest %s\n", (unsigned long)n, (unsigned long)buf[0], (unsigned long)buf[1], NSStringFromRange(within).UTF8String);
    printf("in range: %lu, passing: %lu\n", (unsigned long)[s countOfIndexesInRange:NSMakeRange(4, 4)],
        (unsigned long)[s indexPassingTest:^BOOL(NSUInteger i, BOOL *stop) { return i > 7; }]);
    printf("equal: %d copy %d empty %s\n", [s isEqualToIndexSet:[s copy]], [[s copy] isEqual:s], oneline([NSIndexSet indexSet]));
    NSArray *letters = @[@"a", @"b", @"c", @"d", @"e", @"f", @"g", @"h", @"i"];
    printf("objectsAtIndexes: %s\n", [[letters objectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 3)]] componentsJoinedByString:@""].UTF8String);
    printf("indexesOfObjectsPassingTest: %s\n", oneline([letters indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger i, BOOL *stop) { return i % 3 == 0; }]));
    NSMutableArray *ma = [letters mutableCopy];
    [ma removeObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 6)]];
    [ma insertObjects:@[@"X", @"Y"] atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]];
    printf("mutable array: %s\n", [ma componentsJoinedByString:@""].UTF8String);
}

/* MARK: - NSValue and geometry */

static void
geometry(void)
{
    NSValue *v[] = {
        [NSValue valueWithRange:NSMakeRange(2, 3)], [NSValue valueWithPoint:NSMakePoint(1.5, 2)],
        [NSValue valueWithSize:NSMakeSize(3, 4.25)], [NSValue valueWithRect:NSMakeRect(1, 2, 3, 4)],
        [NSValue valueWithEdgeInsets:NSEdgeInsetsMake(1, 2, 3, 4)], [NSValue valueWithPointer:(void *)0x1234],
    };
    for (int i = 0; i < 6; i++) printf("value: %s | %s\n", v[i].objCType, v[i].description.UTF8String);
    int x = 5;
    printf("value: %s\n", [NSValue valueWithBytes:&x objCType:@encode(int)].description.UTF8String);
    printf("unboxed: %s %s\n", NSStringFromRect(v[3].rectValue).UTF8String, NSStringFromPoint(v[1].pointValue).UTF8String);
    NSRect a = NSMakeRect(0, 0, 10, 10), b = NSMakeRect(5, 5, 10, 10);
    printf("strings: %s %s %s\n", NSStringFromPoint(NSMakePoint(1, 2.5)).UTF8String, NSStringFromRect(a).UTF8String, NSStringFromSize(NSMakeSize(0.5, 1)).UTF8String);
    printf("union %s intersection %s inset %s offset %s\n", NSStringFromRect(NSUnionRect(a, b)).UTF8String,
        NSStringFromRect(NSIntersectionRect(a, b)).UTF8String, NSStringFromRect(NSInsetRect(a, 2, 3)).UTF8String,
        NSStringFromRect(NSOffsetRect(a, -1, 1)).UTF8String);
    printf("integral %s empty %d %d\n", NSStringFromRect(NSIntegralRect(NSMakeRect(0.5, 0.25, 2.1, 2))).UTF8String, NSIsEmptyRect(NSZeroRect), NSIsEmptyRect(a));
    printf("contains %d %d point %d %d intersects %d\n", NSContainsRect(a, NSMakeRect(1, 1, 2, 2)), NSContainsRect(a, b),
        NSPointInRect(NSMakePoint(10, 5), a), NSPointInRect(NSMakePoint(0, 0), a), NSIntersectsRect(a, b));
    NSRect slice, rem;
    NSDivideRect(a, &slice, &rem, 3, NSMaxYEdge);
    printf("divide %s %s\n", NSStringFromRect(slice).UTF8String, NSStringFromRect(rem).UTF8String);
    printf("parse %s %s %s\n", NSStringFromRect(NSRectFromString(@"{{1, 2}, {3.5, -4}}")).UTF8String,
        NSStringFromPoint(NSPointFromString(@"{7,8}")).UTF8String, NSStringFromSize(NSSizeFromString(@"{9}")).UTF8String);
}

/* A key path ending in a key the object only notifies about (no accessor): observing
   without old values reads nothing, so nothing raises */
static void
notified_only(void)
{
    Model *m = [Model new];
    m.child = [Model new];
    Observer *o = [Observer new];
    [m addObserver:o forKeyPath:@"child.thumbnail" options:NSKeyValueObservingOptionPrior context:(void *)7];
    @try {
        [m.child willChangeValueForKey:@"thumbnail"];
        [m.child didChangeValueForKey:@"thumbnail"];
        printf("notified-only key: no exception\n");
    } @catch (NSException *e) {
        printf("notified-only key: %s\n", e.name.UTF8String);
    }
    [m removeObserver:o forKeyPath:@"child.thumbnail" context:(void *)7];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        kvc();
        kvo();
        indexes();
        geometry();
        notified_only();
    }
    return 0;
}
