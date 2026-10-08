/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-foundation-test: Foundation behaviour, one result per line, so a run
 * against Apple's Foundation (on the host) and one against Finch's can be
 * diffed, as finch-cf-test is. Built with ARC and literals, as apps are.
 *
 *   strings: creation, formats, comparison, search, case, splitting,
 *   replacement, paths, numeric values, encodings; mutable strings;
 *   numbers and literals; values; errors; autorelease pools; sorting;
 *   runtime names; what gcore's GCoreFramework uses.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <string.h>

static void
p(NSString *label, id value)
{
    printf("%s: %s\n", label.UTF8String, [[value description] UTF8String]);
}

static void
raises(NSString *label, void (^block)(void))
{
    @try {
        block();
        printf("%s: no exception\n", label.UTF8String);
    } @catch (NSException *e) {
        printf("%s: %s\n", label.UTF8String, e.name.UTF8String);
    }
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2 || strcmp(argv[1], "--no-path")) {
            Dl_info info;
            printf("Foundation: %s\n", dladdr((__bridge void *)[NSString class], &info) ? info.dli_fname : "?");
        }

        /* Strings */
        NSString *s = [NSString stringWithFormat:@"%@ has %d items, %.2f each, %s", @"cart", 3, 1.5, "c-string"];
        p(@"format", s);
        printf("length: %lu\n", (unsigned long)s.length);
        p(@"utf8 round trip", [NSString stringWithUTF8String:"h\xc3\xa9llo w\xc3\xb6rld"]);
        printf("utf8 bytes: %lu\n", (unsigned long)[@"héllo" lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        p(@"characters", [NSString stringWithCharacters:(unichar[]){ 'a', 0x263A, 'b' } length:3]);
        printf("compare: %ld %ld %ld\n", (long)[@"apple" compare:@"banana"], (long)[@"b" compare:@"a"], (long)[@"x" compare:@"x"]);
        printf("caseInsensitiveCompare: %ld\n", (long)[@"HELLO" caseInsensitiveCompare:@"hello"]);
        printf("numeric compare: %ld\n", (long)[@"file10" compare:@"file9" options:NSNumericSearch]);
        printf("isEqualToString: %d %d\n", [@"abc" isEqualToString:[NSString stringWithFormat:@"a%@", @"bc"]], [@"abc" isEqualToString:@"abd"]);
        printf("hash equal for equal strings: %d\n", [@"same" hash] == [[NSMutableString stringWithString:@"same"] hash]);
        printf("prefix/suffix: %d %d %d\n", [@"Finch OS" hasPrefix:@"Finch"], [@"Finch OS" hasSuffix:@"OS"], [@"Finch" hasPrefix:@"OS"]);
        NSRange r = [@"the quick brown fox" rangeOfString:@"brown"];
        printf("rangeOfString: %lu %lu\n", (unsigned long)r.location, (unsigned long)r.length);
        r = [@"the quick brown fox" rangeOfString:@"QUICK" options:NSCaseInsensitiveSearch];
        printf("case-insensitive range: %lu %lu\n", (unsigned long)r.location, (unsigned long)r.length);
        printf("not found: %d\n", [@"abc" rangeOfString:@"z"].location == NSNotFound);
        printf("containsString: %d\n", [@"swallow" containsString:@"all"]);
        p(@"substring", [@"0123456789" substringWithRange:NSMakeRange(2, 5)]);
        p(@"substringFromIndex", [@"0123456789" substringFromIndex:7]);
        p(@"substringToIndex", [@"0123456789" substringToIndex:3]);
        p(@"appending", [@"foo" stringByAppendingString:@"bar"]);
        p(@"appendingFormat", [@"n=" stringByAppendingFormat:@"%ld", 42L]);
        p(@"upper", [@"MiXeD cAsE straße" uppercaseString]);
        p(@"lower", [@"MiXeD cAsE" lowercaseString]);
        p(@"capitalized", [@"hello wide world" capitalizedString]);
        NSArray *parts = [@"a,b,,c" componentsSeparatedByString:@","];
        printf("components: %lu [%s]\n", (unsigned long)parts.count, [[parts componentsJoinedByString:@"|"] UTF8String]);
        p(@"split by set", [[@"one two\tthree" componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] componentsJoinedByString:@"+"]);
        p(@"trimmed", [@"  \t padded \n" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        p(@"replace", [@"a-b-c" stringByReplacingOccurrencesOfString:@"-" withString:@"::"]);
        p(@"replace range", [@"Hello World" stringByReplacingCharactersInRange:NSMakeRange(6, 5) withString:@"Finch"]);
        p(@"padding", [@"ab" stringByPaddingToLength:6 withString:@"xy" startingAtIndex:0]);
        printf("intValue: %d %d %d\n", [@"  42abc" intValue], [@"-17" intValue], [@"x" intValue]);
        printf("integerValue: %ld\n", (long)[@"9876543210" integerValue]);
        printf("longLongValue saturates: %lld\n", [@"99999999999999999999" longLongValue]);
        printf("doubleValue: %.3f %.3f\n", [@"3.25" doubleValue], [@"1e3" doubleValue]);
        printf("floatValue: %.2f\n", [@" -2.5" floatValue]);
        printf("boolValue: %d %d %d %d\n", [@"YES" boolValue], [@"true" boolValue], [@"0" boolValue], [@"no" boolValue]);
        NSData *utf16 = [@"hi" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
        printf("utf16le data: %lu bytes\n", (unsigned long)utf16.length);
        p(@"from data", [[NSString alloc] initWithData:[@"data!" dataUsingEncoding:NSUTF8StringEncoding] encoding:NSUTF8StringEncoding]);
        printf("cString latin1: %s\n", [@"plain" cStringUsingEncoding:NSISOLatin1StringEncoding]);

        /* Paths */
        p(@"lastPathComponent", [@"/usr/local/bin/finch" lastPathComponent]);
        p(@"deletingLastPathComponent", [@"/usr/local/bin/" stringByDeletingLastPathComponent]);
        p(@"appendingPathComponent", [@"/usr/local" stringByAppendingPathComponent:@"lib"]);
        p(@"appendingPathComponent to /", [@"/" stringByAppendingPathComponent:@"etc"]);
        p(@"pathExtension", [@"archive.tar.gz" pathExtension]);
        p(@"deletingPathExtension", [@"/tmp/notes.txt" stringByDeletingPathExtension]);
        p(@"appendingPathExtension", [@"photo" stringByAppendingPathExtension:@"png"]);
        p(@"pathComponents", [[@"/a/b/c" pathComponents] componentsJoinedByString:@" "]);
        p(@"pathWithComponents", [NSString pathWithComponents:@[ @"/", @"usr", @"bin" ]]);
        p(@"standardized", [@"/usr/./lib/../bin" stringByStandardizingPath]);
        printf("isAbsolutePath: %d %d\n", [@"/x" isAbsolutePath], [@"x/y" isAbsolutePath]);

        /* Mutable strings */
        NSMutableString *m = [NSMutableString stringWithCapacity:8];
        [m appendString:@"world"];
        [m insertString:@"hello " atIndex:0];
        [m appendFormat:@"%c", '!'];
        [m replaceCharactersInRange:NSMakeRange(0, 1) withString:@"H"];
        [m deleteCharactersInRange:NSMakeRange(5, 1)];
        p(@"mutable", m);
        NSUInteger n = [m replaceOccurrencesOfString:@"o" withString:@"0" options:0 range:NSMakeRange(0, m.length)];
        printf("replaceOccurrences: %lu %s\n", (unsigned long)n, m.UTF8String);
        [m setString:@"reset"];
        p(@"setString", m);
        NSString *frozen = [m copy];
        [m appendString:@"!"];
        printf("copy is independent: %s %s\n", frozen.UTF8String, m.UTF8String);
        raises(@"mutating immutable", ^{ [(NSMutableString *)[NSString stringWithFormat:@"%d", 1] appendString:@"x"]; });
        raises(@"substring out of range", ^{ [@"abc" substringFromIndex:9]; });

        /* Numbers */
        NSNumber *i = @42, *d = @2.5, *f = @1.25f, *b = @YES, *c = @'A', *big = @(ULLONG_MAX);
        printf("literals: %d %.2f %.2f %d %d\n", i.intValue, d.doubleValue, f.floatValue, b.boolValue, c.charValue);
        p(@"stringValue int", i.stringValue);
        p(@"stringValue double", d.stringValue);
        p(@"stringValue float", f.stringValue);
        p(@"stringValue bool", b.stringValue);
        p(@"description ullong max", big);
        printf("objCType: %s %s %s\n", i.objCType, d.objCType, b.objCType);
        printf("compare: %ld %ld %ld\n", (long)[@1 compare:@2], (long)[@2.0 compare:@2], (long)[@3 compare:@-1]);
        printf("isEqualToNumber int/double: %d\n", [@2 isEqualToNumber:@2.0]);
        printf("equal hash: %d\n", [@7 hash] == [[NSNumber numberWithLongLong:7] hash]);
        NSNumber *made = [NSNumber numberWithInt:-12];
        printf("numberWithInt: %d %u %ld %.1f\n", made.intValue, made.unsignedIntValue, (long)made.integerValue, made.doubleValue);
        printf("bool numbers are kCFBoolean: %d\n", (__bridge CFBooleanRef)[NSNumber numberWithBool:YES] == kCFBooleanTrue);
        printf("number bridges: %d\n", CFGetTypeID((__bridge CFTypeRef)made) == CFNumberGetTypeID());
        printf("truncating double: %d %d\n", @(3.99).intValue, @(-3.99).intValue);
        printf("unsigned from negative: %u\n", [NSNumber numberWithInt:-1].unsignedIntValue);

        /* Values */
        NSValue *rv = [NSValue valueWithRange:NSMakeRange(3, 4)];
        printf("range value: %lu %lu %s\n", (unsigned long)rv.rangeValue.location, (unsigned long)rv.rangeValue.length, rv.objCType);
        int stuff = 0x01020304;
        NSValue *bytes = [NSValue valueWithBytes:&stuff objCType:@encode(int)];
        int back = 0;
        [bytes getValue:&back];
        printf("bytes value: %x %d\n", back, [bytes isEqualToValue:[NSValue value:&stuff withObjCType:@encode(int)]]);
        printf("pointer value: %d\n", [NSValue valueWithPointer:&stuff].pointerValue == &stuff);

        /* Errors */
        NSError *e = [NSError errorWithDomain:NSPOSIXErrorDomain code:2 userInfo:nil];
        p(@"posix error", e);
        p(@"posix error localized", e.localizedDescription);
        e = [NSError errorWithDomain:@"FinchDomain" code:7 userInfo:@{ NSLocalizedDescriptionKey: @"custom" }];
        p(@"custom error", e);
        p(@"plain error localized", [NSError errorWithDomain:@"FinchDomain" code:3 userInfo:nil].localizedDescription);

        /* Collections from Foundation's side */
        NSArray *words = @[ @"pear", @"apple", @"fig" ];
        p(@"sorted", [[words sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]);
        p(@"sorted by block", [[words sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *z) {
            return [@(a.length) compare:@(z.length)];
        }] componentsJoinedByString:@","]);
        NSDictionary *dict = @{ @"one": @1, @"two": @2 };
        printf("literal dictionary: %lu %d\n", (unsigned long)dict.count, [dict[@"two"] intValue]);
        printf("empty literals: %lu %lu\n", (unsigned long)@[].count, (unsigned long)@{}.count);
        NSMutableArray *ma = [NSMutableArray arrayWithArray:words];
        [ma addObject:@"kiwi"];
        [ma sortUsingSelector:@selector(caseInsensitiveCompare:)];
        p(@"mutable sorted", [ma componentsJoinedByString:@" "]);

        /* Descriptions (old-style property-list text) */
        for (NSString *q in @[ @"plain", @"", @"two words", @"a_b", @"q\"t", @"tab\t", @"n\nl", @"ünï", @"123", @"\U0001F600" ])
            printf("quoted: %s\n", [[@[ q ] description] stringByReplacingOccurrencesOfString:@"\n" withString:@"|"].UTF8String);
        printf("%s\n", [@[ @1, @2.5, @YES, [NSNull null], @[ @"in", @[] ], @{}, [NSData dataWithBytes:"ab" length:2] ] description].UTF8String);
        printf("%s\n", [@{ @"b": @1, @"a": @{ @"z": @[ @1, @2 ], @"y": @"v w" }, @"c d": @[] } description].UTF8String);
        printf("%s\n", [[NSSet setWithObject:@"x"] description].UTF8String);
        printf("%s\n", [NSString stringWithFormat:@"%@ / %@ / %@", @[ @1 ], @{ @"k": @"v" }, [NSMutableArray arrayWithObject:@"m"]].UTF8String);
        printf("%s\n", [@[ @"a" ] descriptionWithLocale:nil indent:1].UTF8String);

        /* Runtime names */
        p(@"NSStringFromClass", NSStringFromClass([NSMutableString class]));
        printf("NSClassFromString: %d\n", NSClassFromString(@"NSNumber") == [NSNumber class]);
        p(@"NSStringFromSelector", NSStringFromSelector(@selector(addObject:)));
        printf("NSSelectorFromString: %d\n", NSSelectorFromString(@"count") == @selector(count));
        p(@"NSStringFromRange", NSStringFromRange(NSMakeRange(1, 2)));
        printf("string class is NSString: %d %d\n", [@"x" isKindOfClass:[NSString class]], [[NSMutableString string] isKindOfClass:[NSMutableString class]]);
        printf("number class is NSNumber: %d %d\n", [@1 isKindOfClass:[NSNumber class]], [[NSNumber numberWithDouble:1] isKindOfClass:[NSValue class]]);

        /* What GCoreFramework does */
        NSMutableArray *list = [NSMutableArray array];
        [list addObject:[NSString stringWithUTF8String:"core.123"]];
        NSString *pid = [[list[0] componentsSeparatedByString:@"."] lastObject];
        NSNumber *pn = @(pid.intValue);
        printf("gcore-like: %s %d %ld\n", pn.stringValue.UTF8String, pn.intValue, (long)[pn compare:@100]);

        /* Pools */
        __weak id weak = nil;
        @autoreleasepool {
            NSString *t = [NSString stringWithFormat:@"temporary %d", 1];
            weak = t;
            printf("in pool: %d\n", weak != nil);
        }
    }
    printf("done\n");
    return 0;
}
