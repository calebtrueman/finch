/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-collections-test: NSAttributedString, NSRegularExpression,
 * NSOrderedSet, NSCountedSet, NSHashTable, NSMapTable, NSPointerArray,
 * NSCache and Cocoa error descriptions, one result per line so runs
 * against Apple's Foundation and Finch's can be diffed. Private class names
 * and hash-table bucket numbers are not printed.
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

static void
attributed(void)
{
    NSMutableAttributedString *m = [[NSMutableAttributedString alloc] initWithString:@"hello world" attributes:@{@"k": @1}];
    [m addAttribute:@"b" value:@"x" range:NSMakeRange(2, 3)];
    printf("attributed: %s\n", oneline(m));
    printf("empty: [%s] plain: %s\n", oneline([[NSAttributedString alloc] initWithString:@""]), oneline([[NSAttributedString alloc] initWithString:@"plain"]));
    NSRange r;
    NSDictionary *a = [m attributesAtIndex:3 effectiveRange:&r];
    printf("at 3: %s %s\n", oneline(a), NSStringFromRange(r).UTF8String);
    [m attributesAtIndex:0 longestEffectiveRange:&r inRange:NSMakeRange(0, m.length)];
    printf("longest at 0: %s\n", NSStringFromRange(r).UTF8String);
    id k = [m attribute:@"k" atIndex:8 longestEffectiveRange:&r inRange:NSMakeRange(0, m.length)];
    printf("k at 8: %s %s\n", oneline(k), NSStringFromRange(r).UTF8String);
    printf("substring: %s\n", oneline([m attributedSubstringFromRange:NSMakeRange(1, 5)]));
    [m replaceCharactersInRange:NSMakeRange(0, 5) withString:@"HI"];
    [m removeAttribute:@"k" range:NSMakeRange(0, 2)];
    [m appendAttributedString:[[NSAttributedString alloc] initWithString:@"!" attributes:@{@"z": @YES}]];
    [m.mutableString appendString:@"?"];
    printf("edited: %s length %lu\n", oneline(m), (unsigned long)m.length);
    NSMutableArray *runs = [NSMutableArray array];
    [m enumerateAttributesInRange:NSMakeRange(0, m.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
        [runs addObject:[NSString stringWithFormat:@"%@:%lu", NSStringFromRange(range), (unsigned long)attrs.count]];
    }];
    printf("runs: %s\n", [runs componentsJoinedByString:@" "].UTF8String);
    [runs removeAllObjects];
    [m enumerateAttribute:@"z" inRange:NSMakeRange(0, m.length) options:NSAttributedStringEnumerationReverse usingBlock:^(id value, NSRange range, BOOL *stop) {
        [runs addObject:[NSString stringWithFormat:@"%@=%@", NSStringFromRange(range), value ? value : @"-"]];
    }];
    printf("z runs: %s\n", [runs componentsJoinedByString:@" "].UTF8String);
    NSAttributedString *c = [m copy];
    printf("equal: %d %d bridged %d\n", [c isEqual:m], [c isEqualToAttributedString:[[NSAttributedString alloc] initWithString:m.string]],
        CFGetTypeID((__bridge CFTypeRef)m) == CFAttributedStringGetTypeID());
    CFMutableAttributedStringRef cf = CFAttributedStringCreateMutable(NULL, 0);
    CFAttributedStringReplaceString(cf, CFRangeMake(0, 0), CFSTR("cf"));
    CFAttributedStringSetAttribute(cf, CFRangeMake(0, 1), CFSTR("q"), kCFBooleanTrue);
    printf("from CF: %s\n", oneline((__bridge NSAttributedString *)cf));
    CFRelease(cf);
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:m requiringSecureCoding:NO error:NULL];
    NSAttributedString *back = [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:d error:NULL];
    printf("archived: equal %d class %s\n", [back isEqual:m], class_getName([back classForCoder]));
    @try { [m addAttribute:@"x" value:@1 range:NSMakeRange(20, 2)]; } @catch (NSException *e) { printf("out of range: %s\n", e.name.UTF8String); }
}

static void
regexes(void)
{
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\\w+)@(\\w+)" options:0 error:&err];
    NSString *s = @"mail bob@host and amy@site now";
    NSTextCheckingResult *r = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    printf("regex: %s\n", oneline(re));
    printf("first: %s %lu ranges %s %s type %llu\n", oneline(r), (unsigned long)r.numberOfRanges, NSStringFromRange([r rangeAtIndex:1]).UTF8String,
        NSStringFromRange([r rangeAtIndex:2]).UTF8String, (unsigned long long)r.resultType);
    printf("count: %lu groups %lu\n", (unsigned long)[re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)], (unsigned long)re.numberOfCaptureGroups);
    printf("replaced: %s\n", [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"<$2:$1\\$>"].UTF8String);
    NSMutableArray *found = [NSMutableArray array];
    for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) [found addObject:[s substringWithRange:m.range]];
    printf("matches: %s\n", [found componentsJoinedByString:@","].UTF8String);
    NSRegularExpression *named = [NSRegularExpression regularExpressionWithPattern:@"(?<year>\\d{4})-(?<month>\\d\\d)" options:0 error:NULL];
    NSTextCheckingResult *n = [named firstMatchInString:@"on 2026-10 ok" options:0 range:NSMakeRange(0, 13)];
    printf("named: %s %s\n", NSStringFromRange([n rangeWithName:@"year"]).UTF8String, NSStringFromRange([n rangeWithName:@"month"]).UTF8String);
    NSRegularExpression *ci = [NSRegularExpression regularExpressionWithPattern:@"^hello$" options:NSRegularExpressionCaseInsensitive | NSRegularExpressionAnchorsMatchLines error:NULL];
    printf("options: %lu %lu\n", (unsigned long)[ci numberOfMatchesInString:@"HELLO\nhello\nhi" options:0 range:NSMakeRange(0, 14)], (unsigned long)ci.options);
    printf("escaped: %s %s\n", [NSRegularExpression escapedPatternForString:@"a.b*c"].UTF8String, [NSRegularExpression escapedTemplateForString:@"$1\\"].UTF8String);
    [NSRegularExpression regularExpressionWithPattern:@"(" options:0 error:&err];
    printf("error: %s\n", oneline(err));
    printf("string search: %s %s\n", NSStringFromRange([s rangeOfString:@"a\\w+@" options:NSRegularExpressionSearch]).UTF8String,
        [s stringByReplacingOccurrencesOfString:@"[aeiou]" withString:@"_" options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)].UTF8String);
    NSTextCheckingResult *shifted = [r resultByAdjustingRangesWithOffset:10];
    printf("shifted: %s\n", NSStringFromRange(shifted.range).UTF8String);
    NSDataDetector *dd = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
    NSString *links = @"see https://example.org/path, or write to me@example.com.";
    NSMutableArray *urls = [NSMutableArray array];
    for (NSTextCheckingResult *m in [dd matchesInString:links options:0 range:NSMakeRange(0, links.length)])
        [urls addObject:[NSString stringWithFormat:@"%@ %@", NSStringFromRange(m.range), m.URL.absoluteString]];
    printf("links: %s\n", [urls componentsJoinedByString:@" | "].UTF8String);
}

static void
orderedsets(void)
{
    NSOrderedSet *o = [NSOrderedSet orderedSetWithObjects:@3, @1, @2, @1, nil];
    printf("ordered: %s count %lu index %lu contains %d first %s last %s\n", oneline(o), (unsigned long)o.count, (unsigned long)[o indexOfObject:@2],
        [o containsObject:@9], oneline(o.firstObject), oneline(o.lastObject));
    printf("nested: %s\n", oneline(@[o, [NSSet setWithObject:@4], @[@5]]));
    NSMutableOrderedSet *m = [o mutableCopy];
    [m addObject:@4];
    [m addObject:@3];
    [m insertObject:@0 atIndex:0];
    [m removeObject:@1];
    [m exchangeObjectAtIndex:0 withObjectAtIndex:3];
    printf("mutable: %s\n", [m.array componentsJoinedByString:@","].UTF8String);
    [m sortUsingComparator:^NSComparisonResult(id a, id b) { return [a compare:b]; }];
    [m replaceObjectAtIndex:0 withObject:@7];
    [m unionOrderedSet:[NSOrderedSet orderedSetWithObjects:@8, @2, nil]];
    [m minusSet:[NSSet setWithObject:@3]];
    printf("sorted: %s reversed %s\n", [m.array componentsJoinedByString:@","].UTF8String, [m.reversedOrderedSet.array componentsJoinedByString:@","].UTF8String);
    printf("equal: %d %d subset %d intersects %d\n", [o isEqual:[NSOrderedSet orderedSetWithArray:@[@3, @1, @2]]], [o isEqual:[NSOrderedSet orderedSetWithArray:@[@1, @2, @3]]],
        [o isSubsetOfSet:[NSSet setWithArray:@[@1, @2, @3, @4]]], [o intersectsOrderedSet:m]);
    NSMutableArray *seen = [NSMutableArray array];
    for (id x in o) [seen addObject:x];
    printf("enumerated: %s kvc %s\n", [seen componentsJoinedByString:@","].UTF8String, oneline([[NSOrderedSet orderedSetWithObjects:@"a", @"bb", nil] valueForKey:@"length"]));
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:o requiringSecureCoding:NO error:NULL];
    printf("archived: %d\n", [[NSKeyedUnarchiver unarchiveTopLevelObjectWithData:d error:NULL] isEqual:o]);
    @try { [o objectAtIndex:9]; } @catch (NSException *e) { printf("bounds: %s\n", e.name.UTF8String); }

    NSCountedSet *cs = [NSCountedSet setWithArray:@[@"a", @"b", @"a", @"c", @"a"]];
    [cs removeObject:@"c"];
    printf("counted: count %lu a=%lu b=%lu c=%lu member %s\n", (unsigned long)cs.count, (unsigned long)[cs countForObject:@"a"],
        (unsigned long)[cs countForObject:@"b"], (unsigned long)[cs countForObject:@"c"], oneline([cs member:@"a"]));
}

@interface Token : NSObject
@property int n;
@end
@implementation Token
- (NSString *)description { return [NSString stringWithFormat:@"T%d", self.n]; }
@end

static void
pointers(void)
{
    NSHashTable *weak = [NSHashTable weakObjectsHashTable];
    NSMapTable *wk = [NSMapTable weakToStrongObjectsMapTable];
    NSMapTable *wv = [NSMapTable strongToWeakObjectsMapTable];
    NSPointerArray *pa = [NSPointerArray weakObjectsPointerArray];
    Token *keep = [Token new];
    keep.n = 1;
    @autoreleasepool {
        Token *gone = [Token new];
        gone.n = 2;
        [weak addObject:keep];
        [weak addObject:gone];
        [wk setObject:@"kept" forKey:keep];
        [wk setObject:@"lost" forKey:gone];
        [wv setObject:keep forKey:@"a"];
        [wv setObject:gone forKey:@"b"];
        [pa addPointer:(__bridge void *)keep];
        [pa addPointer:(__bridge void *)gone];
        [pa addPointer:NULL];
        printf("before: %lu %lu %lu %lu\n", (unsigned long)weak.count, (unsigned long)wk.count, (unsigned long)wv.count, (unsigned long)pa.count);
        gone = nil;
    }
    printf("after: hash %s map %s / %s / %s array %s %lu\n", oneline(weak.allObjects), oneline([wk objectForKey:keep]), oneline([wv objectForKey:@"a"]),
        oneline([wv objectForKey:@"b"]), oneline(pa.allObjects), (unsigned long)pa.count);
    [pa compact];
    printf("compacted: %lu\n", (unsigned long)pa.count);

    NSMapTable *strong = [NSMapTable strongToStrongObjectsMapTable];
    for (int i = 0; i < 50; i++) [strong setObject:@(i * i) forKey:@(i)];
    [strong removeObjectForKey:@7];
    printf("strong map: %lu %s %s dict %lu\n", (unsigned long)strong.count, oneline([strong objectForKey:@9]), oneline([strong objectForKey:@7]),
        (unsigned long)strong.dictionaryRepresentation.count);
    NSMapTable *opaque = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                               valueOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsIntegerPersonality];
    NSString *k1 = [NSMutableString stringWithString:@"key"], *k2 = [NSMutableString stringWithString:@"key"];
    NSMapInsert(opaque, (__bridge void *)k1, (void *)5);
    printf("identity: %d %d\n", NSMapGet(opaque, (__bridge void *)k1) == (void *)5, NSMapGet(opaque, (__bridge void *)k2) == NULL);
    NSHashTable *copyIn = [NSHashTable hashTableWithOptions:NSPointerFunctionsCopyIn];
    NSMutableString *ms = [@"abc" mutableCopy];
    [copyIn addObject:ms];
    [ms appendString:@"d"];
    printf("copy-in: %s\n", oneline(copyIn.anyObject));

    NSMapTable *c = NSCreateMapTable(NSObjectMapKeyCallBacks, NSIntegerMapValueCallBacks, 0);
    NSMapInsert(c, @"one", (void *)1);
    NSMapInsert(c, @"two", (void *)2);
    void *v = NULL;
    printf("C map: %lu %ld member %d\n", (unsigned long)NSCountMapTable(c), (long)NSMapGet(c, @"two"), NSMapMember(c, @"one", NULL, &v) && v == (void *)1);
    NSMapRemove(c, @"one");
    NSMapEnumerator e = NSEnumerateMapTable(c);
    void *ek, *ev;
    while (NSNextMapEnumeratorPair(&e, &ek, &ev)) printf("C pair: %s %ld\n", oneline((__bridge id)ek), (long)ev);
    NSEndMapTableEnumeration(&e);
    NSFreeMapTable(c);
    NSHashTable *h = NSCreateHashTable(NSIntegerHashCallBacks, 0);
    NSHashInsert(h, (void *)42);
    NSHashInsert(h, (void *)42);
    printf("C hash: %lu %ld\n", (unsigned long)NSCountHashTable(h), (long)NSHashGet(h, (void *)42));
    NSFreeHashTable(h);
}

@interface Evictions : NSObject <NSCacheDelegate>
@property (strong) NSMutableArray *evicted;
@end
@implementation Evictions
- (void)cache:(NSCache *)cache willEvictObject:(id)obj { [self.evicted addObject:obj]; }
@end

static void
caches(void)
{
    NSCache *c = [NSCache new];
    Evictions *d = [Evictions new];
    d.evicted = [NSMutableArray array];
    c.delegate = d;
    c.countLimit = 2;
    c.name = @"test";
    [c setObject:@"A" forKey:@"a"];
    [c setObject:@"B" forKey:@"b"];
    [c objectForKey:@"a"];
    [c setObject:@"C" forKey:@"c"];
    printf("cache: %s %s %s name %s evicted %s\n", oneline([c objectForKey:@"a"]), oneline([c objectForKey:@"b"]), oneline([c objectForKey:@"c"]),
        c.name.UTF8String, [d.evicted componentsJoinedByString:@","].UTF8String);
    [c removeObjectForKey:@"a"];
    [c removeAllObjects];
    printf("removed: %s evicted %s\n", oneline([c objectForKey:@"c"]), [d.evicted componentsJoinedByString:@","].UTF8String);
}

static void
errors(void)
{
    int codes[] = { 4, 256, 257, 260, 512, 516, 2048, 3072, 3840, 4864, 1, 0 };
    for (int i = 0; codes[i]; i++) {
        NSError *a = [NSError errorWithDomain:NSCocoaErrorDomain code:codes[i] userInfo:nil];
        NSError *b = [NSError errorWithDomain:NSCocoaErrorDomain code:codes[i] userInfo:@{NSFilePathErrorKey: @"/tmp/dir/f.txt", @"NSInvalidValue": @"vv"}];
        printf("cocoa %d: %s | %s\n", codes[i], a.localizedDescription.UTF8String, b.localizedDescription.UTF8String);
    }
    printf("described: %s\n", oneline([NSError errorWithDomain:NSCocoaErrorDomain code:4 userInfo:nil]));
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        attributed();
        regexes();
        orderedsets();
        pointers();
        caches();
        errors();
    }
    /* fast enumeration of pointer collections, in a pool that drains */
    @autoreleasepool {
        NSHashTable *h = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory];
        NSMapTable *m = [NSMapTable strongToStrongObjectsMapTable];
        for (int i = 0; i < 3; i++) {
            [h addObject:@(i)];
            [m setObject:@(i * 10) forKey:@(i)];
        }
        long sum = 0;
        for (NSNumber *n in h)
            sum += n.longValue;
        for (NSNumber *k in m)
            sum += [[m objectForKey:k] longValue];
        printf("enumerated pointer collections: %ld\n", sum);
    }
    printf("pool drained\n");
    return 0;
}
