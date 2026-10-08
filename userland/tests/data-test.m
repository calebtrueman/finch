/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-data-test: NSDecimalNumber and the NSDecimal functions, NSScanner,
 * NSJSONSerialization, NSUUID and NSSortDescriptor, one result per line so
 * runs against Apple's Foundation and Finch's can be diffed. Addresses are
 * masked; private class names are not printed.
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

/* MARK: - NSDecimalNumber */

static void
decimals(void)
{
    NSLocale *us = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    NSDecimalNumber *a = [NSDecimalNumber decimalNumberWithString:@"12.345"];
    NSDecimalNumber *b = [NSDecimalNumber decimalNumberWithString:@"-0.5"];
    NSDecimalNumber *c = [NSDecimalNumber decimalNumberWithMantissa:314159 exponent:-5 isNegative:NO];
    printf("parse: %s %s %s %s\n", oneline(a), oneline(b), oneline(c), oneline([NSDecimalNumber decimalNumberWithString:@"1,5" locale:[NSLocale localeWithLocaleIdentifier:@"de_DE"]]));
    printf("arith: %s %s %s %s\n", oneline([a decimalNumberByAdding:b]), oneline([a decimalNumberBySubtracting:b]),
        oneline([a decimalNumberByMultiplyingBy:b]), oneline([a decimalNumberByDividingBy:b]));
    printf("divide: %s %s\n", oneline([[NSDecimalNumber one] decimalNumberByDividingBy:[NSDecimalNumber decimalNumberWithString:@"3"]]),
        oneline([[NSDecimalNumber decimalNumberWithString:@"2"] decimalNumberByDividingBy:[NSDecimalNumber decimalNumberWithString:@"3"]]));
    printf("power: %s %s pow10 %s\n", oneline([[NSDecimalNumber decimalNumberWithString:@"1.1"] decimalNumberByRaisingToPower:10]),
        oneline([[NSDecimalNumber decimalNumberWithString:@"2"] decimalNumberByRaisingToPower:100]), oneline([a decimalNumberByMultiplyingByPowerOf10:3]));
    printf("constants: %s %s %s %s nan %d\n", oneline([NSDecimalNumber zero]), oneline([NSDecimalNumber one]),
        oneline([NSDecimalNumber maximumDecimalNumber]), oneline([NSDecimalNumber minimumDecimalNumber]), [[NSDecimalNumber notANumber] isEqual:[NSDecimalNumber notANumber]]);
    printf("nan: %s %s\n", oneline([NSDecimalNumber notANumber]), oneline([NSDecimalNumber decimalNumberWithString:@"abc"]));
    printf("values: %g %d %lld %s %s\n", a.doubleValue, a.intValue, [[NSDecimalNumber decimalNumberWithString:@"-99.9"] longLongValue], a.objCType,
        [a descriptionWithLocale:[NSLocale localeWithLocaleIdentifier:@"fr_FR"]].UTF8String);
    printf("compare: %ld %ld %ld equal %d %d\n", (long)[a compare:b], (long)[b compare:a], (long)[a compare:@12.345], [a isEqual:[NSDecimalNumber decimalNumberWithString:@"12.3450"]], [a isEqualToNumber:@12.345]);
    NSDecimalNumberHandler *h = [NSDecimalNumberHandler decimalNumberHandlerWithRoundingMode:NSRoundBankers scale:2 raiseOnExactness:NO raiseOnOverflow:NO raiseOnUnderflow:NO raiseOnDivideByZero:NO];
    printf("rounded: %s %s %s\n", oneline([a decimalNumberByRoundingAccordingToBehavior:h]), oneline([[NSDecimalNumber decimalNumberWithString:@"2.345"] decimalNumberByRoundingAccordingToBehavior:h]),
        oneline([[NSDecimalNumber one] decimalNumberByDividingBy:[NSDecimalNumber zero] withBehavior:h]));
    @try { [[NSDecimalNumber one] decimalNumberByDividingBy:[NSDecimalNumber zero]]; } @catch (NSException *e) { printf("%s | %s\n", e.name.UTF8String, e.reason.UTF8String); }
    @try { [[NSDecimalNumber maximumDecimalNumber] decimalNumberByAdding:[NSDecimalNumber maximumDecimalNumber]]; } @catch (NSException *e) { printf("%s | %s\n", e.name.UTF8String, e.reason.UTF8String); }
    printf("from number: %s %s %s\n", oneline([NSDecimalNumber decimalNumberWithDecimal:[@0.1 decimalValue]]), oneline([NSDecimalNumber decimalNumberWithDecimal:[@(1LL << 62) decimalValue]]),
        oneline([NSDecimalNumber decimalNumberWithDecimal:[@(-7) decimalValue]]));

    NSDecimal x, y, r;
    NSScanner *sc = [NSScanner scannerWithString:@"1234.5678 0.0001"];
    [sc scanDecimal:&x];
    [sc scanDecimal:&y];
    NSDecimalAdd(&r, &x, &y, NSRoundPlain);
    printf("functions: add %s", NSDecimalString(&r, us).UTF8String);
    NSDecimalMultiply(&r, &x, &y, NSRoundPlain);
    printf(" mul %s", NSDecimalString(&r, nil).UTF8String);
    NSDecimal rounded;
    NSDecimalRound(&rounded, &x, 1, NSRoundUp);
    printf(" round-up %s", NSDecimalString(&rounded, nil).UTF8String);
    NSDecimalRound(&rounded, &x, -2, NSRoundDown);
    printf(" round-down %s", NSDecimalString(&rounded, nil).UTF8String);
    NSDecimalRound(&rounded, &x, 2, NSRoundPlain);
    printf(" plain %s compare %ld\n", NSDecimalString(&rounded, nil).UTF8String, (long)NSDecimalCompare(&x, &y));
    printf("hash equal: %d\n", [[NSDecimalNumber decimalNumberWithString:@"1.50"] hash] == [[NSDecimalNumber decimalNumberWithString:@"1.5"] hash]);
}

/* MARK: - NSScanner */

static void
scanner(void)
{
    NSScanner *s = [NSScanner scannerWithString:@"  42 -17 3.5e2 0x1F ff name=value; end"];
    int i;
    NSInteger n;
    double d;
    unsigned hex, hex2;
    NSString *word, *rest;
    BOOL ok1 = [s scanInt:&i], ok2 = [s scanInteger:&n], ok3 = [s scanDouble:&d], ok4 = [s scanHexInt:&hex], ok5 = [s scanHexInt:&hex2];
    printf("numbers: %d %d %d %d %d -> %d %ld %g %u %u at %lu\n", ok1, ok2, ok3, ok4, ok5, i, (long)n, d, hex, hex2, (unsigned long)s.scanLocation);
    BOOL ok6 = [s scanUpToString:@"=" intoString:&word];
    BOOL ok7 = [s scanString:@"=" intoString:NULL];
    BOOL ok8 = [s scanCharactersFromSet:[NSCharacterSet letterCharacterSet] intoString:&rest];
    printf("strings: %d %d %d -> %s %s at %lu end %d\n", ok6, ok7, ok8, word.UTF8String, rest.UTF8String, (unsigned long)s.scanLocation, s.isAtEnd);
    BOOL ok9 = [s scanInt:&i];
    [s scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&word];
    printf("after: %d %s end %d\n", ok9, word.UTF8String, s.isAtEnd);
    [s scanUpToString:@"x" intoString:&word];
    printf("rest: %s end %d\n", word.UTF8String, s.isAtEnd);

    NSScanner *t = [NSScanner scannerWithString:@"ABC abc 99999999999 -0x10 1e400 .5"];
    t.caseSensitive = NO;
    BOOL c1 = [t scanString:@"abc" intoString:&word];
    printf("case-insensitive: %d %s", c1, word.UTF8String);
    t.caseSensitive = YES;
    printf(" sensitive %d", [t scanString:@"ABC" intoString:NULL]);
    [t scanString:@"abc" intoString:NULL];
    long long ll;
    BOOL c2 = [t scanInt:&i];
    printf(" overflow %d %d", c2, i);
    unsigned long long uhex;
    [t setScanLocation:8];
    [t scanLongLong:&ll];
    printf(" ll %lld", ll);
    BOOL c3 = [t scanHexLongLong:&uhex];
    printf(" neg-hex %d", c3);
    t.scanLocation = 24;
    BOOL c4 = [t scanDouble:&d];
    printf(" big %d %g", c4, d);
    BOOL c5 = [t scanDouble:&d];
    printf(" dot %d %g\n", c5, d);
    NSScanner *u = [NSScanner scannerWithString:@"a,b,,c"];
    u.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@","];
    NSMutableArray *parts = [NSMutableArray array];
    while (!u.isAtEnd && [u scanUpToString:@"," intoString:&word]) [parts addObject:word];
    printf("skip: %s\n", [parts componentsJoinedByString:@"|"].UTF8String);
    NSScanner *fr = [NSScanner localizedScannerWithString:@"3,25"];
    float f;
    printf("localized: %d %g\n", [fr scanFloat:&f], f);
    printf("description: %s\n", oneline([NSScanner scannerWithString:@"x"]) ? "ok" : "nil");
    NSScanner *hd = [NSScanner scannerWithString:@"0x1.8p1 10"];
    printf("hex double: %d %g\n", [hd scanHexDouble:&d], d);
}

/* MARK: - NSJSONSerialization */

static const char *
json(id o, NSJSONWritingOptions opts)
{
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:opts error:&e];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String : oneline(e);
}

static const char *
parse(NSString *s, NSJSONReadingOptions opts)
{
    NSError *e = nil;
    id o = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:opts error:&e];
    if (!o) return [NSString stringWithFormat:@"error %ld %@", (long)e.code, e.userInfo[NSDebugDescriptionErrorKey]].UTF8String;
    return oneline(o);
}

static void
jsons(void)
{
    NSDictionary *obj = @{@"name": @"Finch", @"n": @3, @"pi": @3.25, @"yes": @YES, @"none": [NSNull null],
                          @"list": @[@1, @"two", @[], @{}], @"esc": @"a/\"b\"\\\n\t\u00e9\U0001F426\x01"};
    printf("write: %s\n", json(obj, NSJSONWritingSortedKeys));
    printf("slashes: %s\n", json(@[@"a/b"], NSJSONWritingWithoutEscapingSlashes));
    printf("pretty: %s\n", masked([[NSString stringWithUTF8String:json(@{@"b": @[@1, @2], @"a": @{@"x": @{}}, @"c": @[]}, NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]));
    printf("doubles: %s\n", json(@[@0.1, @1e20, @1e21, @-0.0, @1.5e-7, @123456789.125, @(1.0 / 3), @100.0, @3.0f], 0));
    printf("integers: %s\n", json(@[@(LLONG_MAX), @(ULLONG_MAX), @(-1), @((char)'a'), [NSDecimalNumber decimalNumberWithString:@"1.10"]], 0));
    printf("fragment: %s | %s\n", json(@"x", NSJSONWritingFragmentsAllowed), json(@5, NSJSONWritingFragmentsAllowed));
    printf("valid: %d %d %d %d %d\n", [NSJSONSerialization isValidJSONObject:obj], [NSJSONSerialization isValidJSONObject:@"x"],
        [NSJSONSerialization isValidJSONObject:@[@(NAN)]], [NSJSONSerialization isValidJSONObject:@{@1: @2}], [NSJSONSerialization isValidJSONObject:@[[NSDate date]]]);
    @try { printf("invalid: %s\n", json(@[[NSObject new]], 0)); } @catch (NSException *e) { printf("%s | %s\n", e.name.UTF8String, masked(e.reason)); }
    @try { printf("nan: %s\n", json(@[@(INFINITY)], 0)); } @catch (NSException *e) { printf("%s | %s\n", e.name.UTF8String, masked(e.reason)); }

    printf("read: %s\n", parse(@"{\"a\": [1, 2.5, -3e2, true, false, null, \"x\\u00e9\\ud83d\\udc26\\n\"], \"b\": {}}", 0));
    printf("numbers: %s\n", parse(@"[0, -0, 1.0, 12345678901234567890, 1e400, 0.1, 9007199254740993, -9223372036854775808]", 0));
    id m = [NSJSONSerialization JSONObjectWithData:[@"{\"a\":[\"s\"]}" dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:NULL];
    id im = [NSJSONSerialization JSONObjectWithData:[@"{\"a\":[\"s\"]}" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    printf("mutable: %d %d | %d %d\n", [m isKindOfClass:[NSMutableDictionary class]] && [m respondsToSelector:@selector(setObject:forKey:)],
        [m[@"a"] isKindOfClass:[NSMutableArray class]], [m isEqual:im], [[im allKeys] count] == 1);
    @try { [im setObject:@1 forKey:@"b"]; printf("immutable set: ok\n"); } @catch (NSException *e) { printf("immutable set: raised\n"); }
    printf("fragments: %s %s\n", parse(@"\"str\"", NSJSONReadingFragmentsAllowed), parse(@" 42 ", NSJSONReadingFragmentsAllowed));
    printf("errors: %s\n", parse(@"\"str\"", 0));
    printf("errors: %s\n", parse(@"[1, 2", 0));
    printf("errors: %s\n", parse(@"{\"a\" 1}", 0));
    printf("errors: %s\n", parse(@"[1,]", 0));
    printf("errors: %s\n", parse(@"", 0));
    printf("errors: %s\n", parse(@"[tru]", 0));
    printf("errors: %s\n", parse(@"[1] x", 0));
    printf("errors: %s\n", parse(@"{1: 2}", 0));
    printf("errors: %s\n", parse(@"[\"\\x\"]", 0));
    printf("errors: %s\n", parse(@"\n\n  [01]", 0));
    printf("duplicate: %s\n", parse(@"{\"a\":1,\"a\":2}", 0));
    printf("bom/utf16: %s %s\n", oneline([NSJSONSerialization JSONObjectWithData:[@"[\"\u00e9\"]" dataUsingEncoding:NSUTF16StringEncoding] options:0 error:NULL]),
        oneline([NSJSONSerialization JSONObjectWithData:[@"[1]" dataUsingEncoding:NSUTF16LittleEndianStringEncoding] options:0 error:NULL]));
    printf("json5: %s\n", parse(@"{a: 1, 'b': [0x10, .5, +1,], // c\n Infinity: NaN}", NSJSONReadingJSON5Allowed));
    printf("top-level dict: %s\n", parse(@"\"a\": 1, \"b\": 2", NSJSONReadingJSON5Allowed | NSJSONReadingTopLevelDictionaryAssumed));
}

/* MARK: - NSUUID and NSSortDescriptor */

static void
uuids(void)
{
    NSUUID *u = [[NSUUID alloc] initWithUUIDString:@"e621e1f8-c36c-495a-93fc-0c247a3e6e5f"];
    uuid_t bytes;
    [u getUUIDBytes:bytes];
    printf("uuid: %s %02x%02x %s\n", u.UUIDString.UTF8String, bytes[0], bytes[15], oneline(u));
    printf("invalid: %s %s\n", oneline([[NSUUID alloc] initWithUUIDString:@"nope"]), oneline([[NSUUID alloc] initWithUUIDString:@"E621E1F8C36C495A93FC0C247A3E6E5F"]));
    NSUUID *v = [[NSUUID alloc] initWithUUIDBytes:bytes];
    printf("equal: %d hash %d copy %d compare %ld\n", [u isEqual:v], u.hash == v.hash, [[u copy] isEqual:u], (long)[u compare:[[NSUUID alloc] initWithUUIDString:@"00000000-0000-0000-0000-000000000001"]]);
    NSUUID *r = [NSUUID UUID];
    printf("random: %lu version %c variant %d unique %d\n", (unsigned long)r.UUIDString.length, [r.UUIDString characterAtIndex:14], ([r.UUIDString characterAtIndex:19] & 0xff) >= '8', ![r isEqual:[NSUUID UUID]]);
}

static void
sorting(void)
{
    NSArray *people = @[@{@"name": @"bo", @"age": @30}, @{@"name": @"Al", @"age": @25}, @{@"name": @"cy", @"age": @30}, @{@"name": @"al", @"age": @40}];
    NSSortDescriptor *byAge = [NSSortDescriptor sortDescriptorWithKey:@"age" ascending:NO];
    NSSortDescriptor *byName = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(caseInsensitiveCompare:)];
    NSArray *sorted = [people sortedArrayUsingDescriptors:@[byAge, byName]];
    printf("sorted: %s\n", [[sorted valueForKey:@"name"] componentsJoinedByString:@","].UTF8String);
    printf("descriptors: %s | %s | %s\n", oneline(byAge), oneline(byName), oneline(byName.reversedSortDescriptor));
    printf("compare: %ld %ld key %s asc %d sel %s\n", (long)[byAge compareObject:people[0] toObject:people[1]], (long)[byName compareObject:people[1] toObject:people[3]],
        byName.key.UTF8String, byName.ascending, sel_getName(byName.selector));
    NSSortDescriptor *len = [NSSortDescriptor sortDescriptorWithKey:@"self" ascending:YES comparator:^NSComparisonResult(NSString *a, NSString *b) {
        return a.length < b.length ? NSOrderedAscending : a.length > b.length ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray *words = [@[@"ccc", @"a", @"bb", @"dddd", @"e"] mutableCopy];
    [words sortUsingDescriptors:@[len]];
    printf("comparator: %s\n", [words componentsJoinedByString:@","].UTF8String);
    printf("path: %s\n", [[[@[@{@"o": @{@"v": @2}}, @{@"o": @{@"v": @1}}] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"o.v" ascending:YES]]] valueForKeyPath:@"o.v"] componentsJoinedByString:@","].UTF8String);
    printf("set: %s\n", [[[NSSet setWithArray:@[@3, @1, @2]] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:nil ascending:YES]]] componentsJoinedByString:@","].UTF8String);
    printf("equal: %d %d\n", [byAge isEqual:[NSSortDescriptor sortDescriptorWithKey:@"age" ascending:NO]], [byAge isEqual:byName]);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        decimals();
        scanner();
        jsons();
        uuids();
        sorting();
    }
    return 0;
}
