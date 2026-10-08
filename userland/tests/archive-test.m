/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-archive-test: NSKeyedArchiver and NSKeyedUnarchiver, one result per
 * line so runs against Apple's Foundation and Finch's can be diffed. It
 * prints the structure of archives (object numbering, classes, keys),
 * round-trips Foundation's classes, decodes an archive made by Apple's
 * Foundation on macOS 26 (embedded below), and checks secure coding.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/* NSKeyedArchiver output from macOS 26 for the objects in apple_root(). */
static const char apple_archive[] =
    "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEI"
    "CVRyb290gAGvEDwLDCkqKywtMTg5PUFISUpNUVJVWVxiZmdqa3N0dXh9foCDiouRlJmcoaWmqba8wMPNztHV2dzl5uzt8PFVJG51"
    "bGzSDQ4PKFpOUy5vYmplY3RzViRjbGFzc68QGBAREhMUFRYXGBkaGxwdHh8gISIjJCUmJ4ACgAOABIAFgAaACIAJgAuAD4ASgBSA"
    "GYAdgB+AIYAlgCiAK4AtgC+AMoA0gDWAOoA7U3N0chAqI0AMAAAAAAAACdIOLi8wWU5TLnN0cmluZ4AHU211dNIyMzQ1WiRjbGFz"
    "c25hbWVYJGNsYXNzZXNfEA9OU011dGFibGVTdHJpbmejNDY3WE5TU3RyaW5nWE5TT2JqZWN0QmFi0joOOzxXTlMuZGF0YUJjZIAK"
    "0jIzPj9dTlNNdXRhYmxlRGF0YaM+QDdWTlNEYXRh00INDkNFR1dOUy5rZXlzoUSADKFGgA2ADlFrUXbSMjNLTFxOU0RpY3Rpb25h"
    "cnmiSzfSDQ5OUKFPgBCAEVFz0jIzU1RVTlNTZXSiUzfSVg5XWFdOUy50aW1lI0CPQAAAAAAAgBPSMjNaW1ZOU0RhdGWiWjfTXQ5e"
    "X2BhV05TLmJhc2VbTlMucmVsYXRpdmWAFYAXgBjTXQ5eY2BlgACAF4AWXxAPaHR0cDovL3gub3JnL2Ev0jIzaGlVTlNVUkyiaDdT"
    "Yi9j1Gxtbg5vcHFyXxASTlMucmFuZ2V2YWwubGVuZ3RoXxAUTlMucmFuZ2V2YWwubG9jYXRpb25aTlMuc3BlY2lhbIAagBsQBIAc"
    "EAIQAdIyM3Z3V05TVmFsdWWidjfTeQ5uenJ8Wk5TLnJlY3R2YWyAHoAcEANfEBB7ezEsIDJ9LCB7MywgNH190Q5/gCDSMjOBglZO"
    "U051bGyigTfUhIWGDnyHiIlWTlNDb2RlWk5TVXNlckluZm9YTlNEb21haW6AI4AigCRRRNNCDQ6MjkehRIAMoUaADYAO0jIzkpNX"
    "TlNFcnJvcqKSN9OVDpZzl5hcTlNSYW5nZUNvdW50W05TUmFuZ2VEYXRhgCeAJtI6Dpo8RQEDrAIBgArSMjOdnl8QEU5TTXV0YWJs"
    "ZUluZGV4U2V0o5+gN18QEU5TTXV0YWJsZUluZGV4U2V0Wk5TSW5kZXhTZXTSDqKjpF1OUy5pZGVudGlmaWVygCqAKVVmcl9DQdIy"
    "M6eoWE5TTG9jYWxloqc31w6qq6ytrq+wsSyztLQsW05TLm1hbnRpc3NhW05TLm5lZ2F0aXZlW05TLmV4cG9uZW50Xk5TLm1hbnRp"
    "c3NhLmJvWU5TLmxlbmd0aFpOUy5jb21wYWN0gCxPEBB9AAAAAAAAAAAAAAAAAAAACRP//////////xABCdIyM7e4XxAaTlNEZWNp"
    "bWFsTnVtYmVyUGxhY2Vob2xkZXKlubq7djdfEBpOU0RlY2ltYWxOdW1iZXJQbGFjZWhvbGRlcl8QD05TRGVjaW1hbE51bWJlclhO"
    "U051bWJlctK9Dr6/XE5TLnV1aWRieXRlc08QEOYh4fjDbElak/wMJHo+bl+ALtIyM8HCVk5TVVVJRKLBN9XEDsXGx8jJyspEWk5T"
    "U2VsZWN0b3JfEBJOU1JldmVyc2VOdWxsT3JkZXJbTlNBc2NlbmRpbmdVTlNLZXmAMIAxCAiADFhjb21wYXJlOtIyM8/QXxAQTlNT"
    "b3J0RGVzY3JpcHRvcqLPN9LSDtPUWE5TU3RyaW5nU3h5eoAz0jIz1tdeTlNDaGFyYWN0ZXJTZXSi2DdeTlNDaGFyYWN0ZXJTZXTS"
    "2g5x1FtOU0J1aWx0aW5JRIAz1Q7d3t/g4bTi42NRblRuZXh0VG5hbWVUYmFja4A5gDeANoAAUWHVDt3e3+Dh6GPqJoA5EAKAAIA4"
    "gDVRYtIyM+7vVE5vZGWi7jcU/////////////////////9IyM/LzV05TQXJyYXmi8jcACAARABoAJAApADIANwBJAEwAUQBTAJIA"
    "mACdAKgArwDKAMwAzgDQANIA1ADWANgA2gDcAN4A4ADiAOQA5gDoAOoA7ADuAPAA8gD0APYA+AD6APwBAAECAQsBDAERARsBHQEh"
    "ASYBMQE6AUwBUAFZAWIBZQFqAXIBdQF3AXwBigGOAZUBnAGkAaYBqAGqAawBrgGwAbIBtwHEAccBzAHOAdAB0gHUAdkB3wHiAecB"
    "7wH4AfoB/wIGAgkCEAIYAiQCJgIoAioCMQIzAjUCNwJJAk4CVAJXAlsCZAJ5ApACmwKdAp8CoQKjAqUCpwKsArQCtwK+AskCywLN"
    "As8C4gLlAucC7ALzAvYC/wMGAxEDGgMcAx4DIAMiAykDKwMtAy8DMQMzAzgDQANDA0oDVwNjA2UDZwNsA3IDdAN5A40DkQOlA7AD"
    "tQPDA8UDxwPNA9ID2wPeA+0D+QQFBBEEIAQqBDUENwRKBEsEVARWBFcEXAR5BH8EnASuBLcEvATJBNwE3gTjBOoE7QT4BQMFGAUk"
    "BSoFLAUuBS8FMAUyBTsFQAVTBVYFWwVkBWgFagVvBX4FgQWQBZUFoQWjBa4FsAW1BboFvwXBBcMFxQXHBckF1AXWBdgF2gXcBd4F"
    "4AXlBeoF7QX+BgMGCwAAAAAAAAIBAAAAAAAAAPQAAAAAAAAAAAAAAAAAAAYO";

@interface Node : NSObject <NSSecureCoding>
@property (copy) NSString *name;
@property (strong) Node *next;
@property (weak) Node *back;
@property int n;
@end
@implementation Node
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)c
{
    [c encodeObject:self.name forKey:@"name"];
    [c encodeObject:self.next forKey:@"next"];
    [c encodeConditionalObject:self.back forKey:@"back"];
    [c encodeInt:self.n forKey:@"n"];
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    if ((self = [super init])) {
        _name = [c decodeObjectOfClass:[NSString class] forKey:@"name"];
        _next = [c decodeObjectOfClass:[Node class] forKey:@"next"];
        _back = [c decodeObjectOfClass:[Node class] forKey:@"back"];
        _n = [c decodeIntForKey:@"n"];
    }
    return self;
}
@end

/* Every primitive, the unkeyed API, and a conditional object. */
@interface Everything : NSObject <NSCoding>
@property (strong) id other;
@end
@implementation Everything
- (void)encodeWithCoder:(NSCoder *)c
{
    const char *str = "cstr";
    SEL sel = @selector(foo:);
    int arr[3] = { 7, 8, 9 };
    short sh = -3;
    unsigned long long q = 1ULL << 63;
    [c encodeValueOfObjCType:@encode(char *) at:&str];
    [c encodeValueOfObjCType:@encode(SEL) at:&sel];
    [c encodeArrayOfObjCType:@encode(int) count:3 at:arr];
    [c encodeValueOfObjCType:"s" at:&sh];
    [c encodeValueOfObjCType:"Q" at:&q];
    [c encodeBytes:"xy" length:2];
    [c encodeObject:@"o"];
    [c encodeConditionalObject:self.other forKey:@"cond"];
    [c encodeSize:NSMakeSize(3, 4) forKey:@"sz"];
    [c encodeInt:-1 forKey:@"neg"];
    [c encodeInteger:5 forKey:@"nsint"];
    [c encodeFloat:0.1f forKey:@"flt"];
    [c encodeBool:YES forKey:@"bool"];
    [c encodeInt64:1LL << 40 forKey:@"big"];
    [c encodeBytes:(const uint8_t *)"abc" length:3 forKey:@"bytes"];
    [c encodeDouble:2.5 forKey:@"dbl"];
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    if ((self = [super init])) {
        char *str = NULL;
        SEL sel = NULL;
        int arr[3] = { 0 };
        short sh = 0;
        unsigned long long q = 0;
        [c decodeValueOfObjCType:@encode(char *) at:&str size:sizeof(str)];
        [c decodeValueOfObjCType:@encode(SEL) at:&sel size:sizeof(sel)];
        [c decodeArrayOfObjCType:@encode(int) count:3 at:arr];
        [c decodeValueOfObjCType:"s" at:&sh size:sizeof(sh)];
        [c decodeValueOfObjCType:"Q" at:&q size:sizeof(q)];
        NSUInteger n = 0;
        void *bytes = [c decodeBytesWithReturnedLength:&n];
        id o = [c decodeObject];
        NSUInteger bn = 0;
        const uint8_t *kb = [c decodeBytesForKey:@"bytes" returnedLength:&bn];
        printf("decoded: %s %s %d,%d,%d %d %llu %.*s %s cond=%s sz=%s neg=%d nsint=%ld flt=%g bool=%d big=%lld bytes=%.*s dbl=%g missing=%d has=%d,%d\n",
            str, sel_getName(sel), arr[0], arr[1], arr[2], sh, q, (int)n, (char *)bytes, [[o description] UTF8String],
            [[c decodeObjectForKey:@"cond"] class] ? "set" : "nil", NSStringFromSize([c decodeSizeForKey:@"sz"]).UTF8String,
            [c decodeIntForKey:@"neg"], (long)[c decodeIntegerForKey:@"nsint"], [c decodeFloatForKey:@"flt"], [c decodeBoolForKey:@"bool"],
            [c decodeInt64ForKey:@"big"], (int)bn, kb, [c decodeDoubleForKey:@"dbl"], [c decodeIntForKey:@"missing"],
            [c containsValueForKey:@"dbl"], [c containsValueForKey:@"missing"]);
    }
    return self;
}
@end

static NSString *
fmt(id o)
{
    NSString *d = [o description];
    if ([d hasPrefix:@"<CFKeyedArchiverUID"]) {
        NSRange r = [d rangeOfString:@"value = "];
        return [@"@" stringByAppendingString:[d substringWithRange:NSMakeRange(NSMaxRange(r), [d length] - NSMaxRange(r) - 1)]];
    }
    if ([o isKindOfClass:[NSDictionary class]]) {
        NSMutableArray *p = [NSMutableArray array];
        for (id k in [[o allKeys] sortedArrayUsingSelector:@selector(compare:)]) [p addObject:[NSString stringWithFormat:@"%@=%@", k, fmt(o[k])]];
        return [NSString stringWithFormat:@"{%@}", [p componentsJoinedByString:@" "]];
    }
    if ([o isKindOfClass:[NSArray class]]) {
        NSMutableArray *p = [NSMutableArray array];
        for (id x in o) [p addObject:fmt(x)];
        return [NSString stringWithFormat:@"[%@]", [p componentsJoinedByString:@","]];
    }
    if ([o isKindOfClass:[NSData class]]) return [NSString stringWithFormat:@"<%@>", [o base64EncodedStringWithOptions:0]];
    if ([o isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"'%@'", o];
    if (CFGetTypeID((__bridge CFTypeRef)o) == CFBooleanGetTypeID()) return [o boolValue] ? @"true" : @"false";
    if ([o isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"%@%s", o, strchr("fd", *[o objCType]) ? "r" : ""];
    return [o description];
}

/* An archive's structure: ,  and each object by number. */
static void
dump(const char *label, id root)
{
    NSError *err = nil;
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:root requiringSecureCoding:NO error:&err];
    if (!d) {
        printf("%s: error %ld %s\n", label, (long)err.code, [[err.userInfo[NSDebugDescriptionErrorKey] componentsSeparatedByString:@"\n"][0] UTF8String]);
        return;
    }
    NSDictionary *pl = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
    NSArray *objs = pl[@"$objects"];
    NSMutableArray *p = [NSMutableArray array];
    for (NSUInteger i = 1; i < objs.count; i++) {
        id o = objs[i];
        if ([o isKindOfClass:[NSDictionary class]] && o[@"$classname"])
            [p addObject:[NSString stringWithFormat:@"%lu:C(%@)", (unsigned long)i, [o[@"$classes"] componentsJoinedByString:@">"]]];
        else
            [p addObject:[NSString stringWithFormat:@"%lu:%@", (unsigned long)i, fmt(o)]];
    }
    printf("%s: %s %s %s | %s\n", label, [pl[@"$archiver"] UTF8String], fmt(pl[@"$top"]).UTF8String, [pl[@"$version"] description].UTF8String,
        [p componentsJoinedByString:@" "].UTF8String);
}

/* The description on one line, addresses masked. */
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

/* Locales, calendars and character sets describe themselves by private
 * class names; print what identifies them instead. */
static const char *
shown(id o)
{
    if ([o isKindOfClass:[NSLocale class]]) return [o localeIdentifier].UTF8String;
    if ([o isKindOfClass:[NSCalendar class]]) return [NSString stringWithFormat:@"%@ %@", [o calendarIdentifier], [[o timeZone] name]].UTF8String;
    if ([o isKindOfClass:[NSTimeZone class]]) return [NSString stringWithFormat:@"%@ %ld", [o name], (long)[o secondsFromGMT]].UTF8String;
    if ([o isKindOfClass:[NSCharacterSet class]]) return [NSString stringWithFormat:@"x=%d 5=%d", [o characterIsMember:'x'], [o characterIsMember:'5']].UTF8String;
    if ([o isKindOfClass:[NSSet class]]) return [[[o allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String;
    if ([o isKindOfClass:[NSIndexSet class]]) {
        NSMutableArray *r = [NSMutableArray array];
        [o enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) { [r addObject:NSStringFromRange(range)]; }];
        return [r componentsJoinedByString:@" "].UTF8String;
    }
    return oneline(o);
}

static void
roundtrip(const char *label, id o)
{
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:o requiringSecureCoding:NO error:NULL];
    id back = [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:d error:NULL];
    printf("roundtrip %s: equal %d class %s | %s\n", label, [back isEqual:o], class_getName([back classForCoder]), shown(back));
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        /* Structure */
        dump("string", @"s");
        dump("number", @1);
        dump("unsigned", @(18446744073709551615ULL));
        dump("double", @1.5);
        dump("bool", @NO);
        dump("data", [NSData dataWithBytes:"ab" length:2]);
        dump("array", @[@"a", @"a", @[], @YES, @NO, @YES]);
        dump("mutable", @[[@"m" mutableCopy], [NSMutableData dataWithBytes:"x" length:1], [@[@1] mutableCopy], [@{@"a": @1} mutableCopy], [NSMutableSet setWithObject:@2]]);
        dump("values", @[[NSValue valueWithRange:NSMakeRange(1, 2)], [NSValue valueWithPoint:NSMakePoint(1, 2)], [NSValue valueWithSize:NSMakeSize(1, 2)],
                         [NSValue valueWithRect:NSMakeRect(1, 2, 3, 4)], [NSValue valueWithEdgeInsets:NSEdgeInsetsMake(1, 2, 3, 4)]]);
        int five = 5;
        dump("intvalue", [NSValue valueWithBytes:&five objCType:@encode(int)]);
        dump("date-url-null", @[[NSDate dateWithTimeIntervalSinceReferenceDate:1000], [NSURL URLWithString:@"b/c" relativeToURL:[NSURL URLWithString:@"http://x.org/a/"]],
                                [NSURL fileURLWithPath:@"/tmp/x"], [NSNull null]]);
        dump("error", [NSError errorWithDomain:@"D" code:3 userInfo:@{@"k": @"v"}]);
        dump("exception", [NSException exceptionWithName:@"N" reason:@"R" userInfo:nil]);
        NSMutableIndexSet *ix = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 3)];
        [ix addIndex:10];
        [ix addIndexesInRange:NSMakeRange(300, 1000)];
        dump("indexsets", @[[NSIndexSet indexSet], [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 3)], ix]);
        dump("charsets", @[[NSCharacterSet characterSetWithCharactersInString:@"ab"], [NSCharacterSet letterCharacterSet],
                           [NSCharacterSet characterSetWithRange:NSMakeRange(65, 3)], [NSMutableCharacterSet characterSetWithCharactersInString:@"q"]]);
        dump("locale", [NSLocale localeWithLocaleIdentifier:@"fr_CA"]);
        dump("decimal", [NSDecimalNumber decimalNumberWithString:@"-12.5"]);
        dump("sortdescriptor", [NSSortDescriptor sortDescriptorWithKey:@"k" ascending:NO selector:@selector(caseInsensitiveCompare:)]);
        dump("uuid", [[NSUUID alloc] initWithUUIDString:@"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"]);
        NSDateComponents *dc = [NSDateComponents new];
        dc.year = 2020;
        dc.month = 3;
        dump("datecomponents", dc);
        Everything *e1 = [Everything new], *e2 = [Everything new];
        e1.other = e2;
        e2.other = e1;
        dump("everything", [Everything new]);
        dump("conditional", @[e1, e2]);
        dump("struct", [NSValue valueWithBytes:&(struct { int a; double b; }){ 1, 2 } objCType:"{?=id}"]);
        dump("nil", nil);

        /* Round trips */
        roundtrip("string", @"héllo");
        roundtrip("mutablestring", [@"m" mutableCopy]);
        roundtrip("collections", @[@{@"k": @[@1, @2.5, @YES]}, [NSNull null]]);
        roundtrip("set", [NSSet setWithObjects:@"a", @"b", nil]);
        roundtrip("values", @[[NSValue valueWithRange:NSMakeRange(1, 2)], [NSValue valueWithRect:NSMakeRect(1, 2, 3, 4)], [NSValue valueWithEdgeInsets:NSEdgeInsetsMake(1, 2, 3, 4)],
                              [NSValue valueWithBytes:&five objCType:@encode(int)]]);
        roundtrip("date", [NSDate dateWithTimeIntervalSinceReferenceDate:12345.5]);
        roundtrip("url", [NSURL URLWithString:@"b/c?q=1" relativeToURL:[NSURL URLWithString:@"http://x.org/a/"]]);
        roundtrip("error", [NSError errorWithDomain:NSPOSIXErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: @"gone"}]);
        roundtrip("indexset", ix);
        roundtrip("charset", [NSCharacterSet characterSetWithCharactersInString:@"xyz"]);
        roundtrip("locale", [NSLocale localeWithLocaleIdentifier:@"de_CH"]);
        roundtrip("timezone", [NSTimeZone timeZoneWithName:@"Asia/Tokyo"]);
        NSCalendar *hebrew = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierHebrew];
        hebrew.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Jerusalem"];
        roundtrip("calendar", hebrew);
        roundtrip("decimal", [NSDecimalNumber decimalNumberWithString:@"123456789012345678901234567890.5"]);
        roundtrip("uuid", [[NSUUID alloc] initWithUUIDString:@"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"]);
        roundtrip("sortdescriptor", [NSSortDescriptor sortDescriptorWithKey:@"k" ascending:NO selector:@selector(localizedCompare:)]);
        roundtrip("datecomponents", dc);
        roundtrip("unsigned", @(18446744073709551615ULL));
        id ev = [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:@[e1, e2] requiringSecureCoding:NO error:NULL] error:NULL];
        printf("cycle: %d %d\n", [ev[0] other] == ev[1], [ev[1] other] == ev[0]);

        /* Apple's archive */
        NSData *apple = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:apple_archive] options:0];
        NSError *err = nil;
        NSArray *a = [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:apple error:&err];
        printf("apple archive: %lu objects, error %ld\n", (unsigned long)a.count, (long)err.code);
        for (id o in a) {
            if ([o isKindOfClass:[Node class]]) {
                Node *n = o;
                printf("  Node %s n=%d next %s back-is-self %d\n", n.name.UTF8String, n.n, n.next.name.UTF8String, n.next.back == n);
            } else {
                printf("  %s: %s\n", class_getName([o classForCoder]), shown(o));
            }
        }

        /* Secure coding */
        NSData *strings = [NSKeyedArchiver archivedDataWithRootObject:@[@"a"] requiringSecureCoding:YES error:NULL];
        id ok = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSString class], nil] fromData:strings error:&err];
        printf("secure ok: %s error %ld\n", oneline(ok), (long)err.code);
        id bad = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSArray class] fromData:strings error:&err];
        printf("secure missing class: %s error %ld\n", oneline(bad), (long)err.code);
        bad = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSDictionary class] fromData:strings error:&err];
        printf("secure wrong class: %s error %ld\n", oneline(bad), (long)err.code);
        printf("array of strings: %s\n", oneline([NSKeyedUnarchiver unarchivedArrayOfObjectsOfClass:[NSString class] fromData:strings error:&err]));
        NSData *insecure = [NSKeyedArchiver archivedDataWithRootObject:[Everything new] requiringSecureCoding:YES error:&err];
        printf("secure archive of NSCoding-only: %s error %ld\n", insecure ? "data" : "nil", (long)err.code);
        bad = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSArray class] fromData:[@"junk" dataUsingEncoding:NSUTF8StringEncoding] error:&err];
        printf("junk: %s error %ld\n", oneline(bad), (long)err.code);
        @try {
            printf("junk (legacy): %s\n", oneline([NSKeyedUnarchiver unarchiveObjectWithData:[@"junk" dataUsingEncoding:NSUTF8StringEncoding]]));
        } @catch (NSException *x) {
            printf("junk (legacy): %s\n", x.name.UTF8String);
        }

        /* Archiver API */
        NSKeyedArchiver *ar = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
        [ar setClassName:@"Renamed" forClass:[Node class]];
        Node *solo = [Node new];
        solo.name = @"solo";
        [ar encodeObject:solo forKey:@"thing"];
        [ar encodeInt:7 forKey:@"top-int"];
        [ar finishEncoding];
        NSDictionary *pl = [NSPropertyListSerialization propertyListWithData:ar.encodedData options:0 format:NULL error:NULL];
        printf("renamed: %s top %s\n", [pl[@"$objects"][3][@"$classname"] UTF8String], fmt(pl[@"$top"]).UTF8String);
        NSKeyedUnarchiver *un = [[NSKeyedUnarchiver alloc] initForReadingFromData:ar.encodedData error:&err];
        un.requiresSecureCoding = NO;
        [un setClass:[Node class] forClassName:@"Renamed"];
        printf("unrenamed: %s top-int %d\n", [[[un decodeObjectForKey:@"thing"] name] UTF8String], [un decodeIntForKey:@"top-int"]);
        ar = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
        ar.outputFormat = NSPropertyListXMLFormat_v1_0;
        [ar encodeObject:@"x" forKey:@"root"];
        printf("xml: %d\n", [[[NSString alloc] initWithData:ar.encodedData encoding:NSUTF8StringEncoding] hasPrefix:@"<?xml"]);
    }
    return 0;
}
