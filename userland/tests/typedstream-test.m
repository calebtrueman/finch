/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-typedstream-test: NSArchiver and NSUnarchiver (NeXT's typedstream), one
 * result per line so runs against Apple's Foundation and Finch's can be
 * diffed. It prints the bytes each kind of value and class archives to,
 * round-trips them, and decodes an archive made by Apple's NSArchiver on
 * macOS 26 (embedded below).
 */
#import <Foundation/Foundation.h>

/* NSArchiver output from macOS 26 for the array in mk_root() of the test's history. */
static const char apple_archive[] =
    "040b73747265616d747970656481e803840140848484074e534172726179008484084e534f626a65637400858401690d"
    "92848484084e53537472696e67019484012b037374728692848484084e534e756d626572008484074e5356616c756500"
    "9484012a8495952a869284989a848401649b83000000000000f83f8692848484064e53446174610094950284045b3263"
    "5d010286928484840c4e5344696374696f6e6172790094950192849697016b86928496970176868692848484054e5353"
    "6574009484014901928496970173868692848484064e534461746500949b81e8038692848484054e5355524c00948401"
    "63019284a9a3009284969709687474703a2f2f782f868692849697016286869284999a84840d7b5f4e5352616e67653d"
    "51517da4030486928484840f4e534d757461626c65537472696e67019697036d75748692848484194e534d757461626c"
    "6541747472696275746564537472696e67008484124e5341747472696275746564537472696e6700949284b097036162"
    "63868402694901019284a0950086a802019284a0950192849697014b869284969701568686a801018692959284989a84"
    "840171a9870000000000ffffff8686";

static NSData *
from_hex(const char *hex)
{
    NSMutableData *d = [NSMutableData data];
    for (const char *p = hex; p[0] && p[1]; p += 2) {
        unsigned v;
        sscanf(p, "%2x", &v);
        uint8_t b = (uint8_t)v;
        [d appendBytes:&b length:1];
    }
    return d;
}

/* The bytes after the 16-byte header. */
static void
dump(const char *label, NSData *d)
{
    printf("%s:", label);
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 16; i < d.length; i++) printf(" %02x", b[i]);
    printf("\n");
}

static NSString *
show(id o)
{
    if ([o isKindOfClass:[NSAttributedString class]]) {
        NSMutableString *s = [NSMutableString stringWithFormat:@"attributed '%@'", [o string]];
        [o enumerateAttributesInRange:NSMakeRange(0, [o length]) options:0 usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
            [s appendFormat:@" [%lu,%lu %@]", (unsigned long)r.location, (unsigned long)r.length,
                [[a description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
        }];
        return s;
    }
    if ([o isKindOfClass:[NSURL class]]) return [NSString stringWithFormat:@"url %@ base %@", [o relativeString], [[o baseURL] absoluteString]];
    if ([o isKindOfClass:[NSDate class]]) return [NSString stringWithFormat:@"date %g", [o timeIntervalSinceReferenceDate]];
    if ([o isKindOfClass:[NSSet class]]) return [NSString stringWithFormat:@"set %@", [[o allObjects] componentsJoinedByString:@","]];
    if ([o isKindOfClass:[NSDictionary class]] || [o isKindOfClass:[NSArray class]])
        return [[o description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return [NSString stringWithFormat:@"%@", o];
}

int
main(void)
{
    @autoreleasepool {
        NSMutableData *m;
        NSArchiver *a;
#define CASE(label, ...) m = [NSMutableData data]; a = [[NSArchiver alloc] initForWritingWithMutableData:m]; __VA_ARGS__; dump(label, [a archiverData]);
        CASE("header", );
        {
            NSData *h = [[[NSArchiver alloc] initForWritingWithMutableData:[NSMutableData data]] archiverData];
            printf("header bytes: %lu %02x %.11s\n", (unsigned long)h.length, ((const uint8_t *)h.bytes)[0], (const char *)h.bytes + 2);
        }
        int ints[] = { 0, 5, 127, -110, -111, -128, 300, -300, 70000, -70000 };
        for (unsigned i = 0; i < sizeof(ints) / sizeof(ints[0]); i++) {
            char label[32];
            snprintf(label, sizeof(label), "int %d", ints[i]);
            CASE(label, [a encodeValueOfObjCType:"i" at:&ints[i]]);
        }
        long long q = 1LL << 40; CASE("long long 2^40", [a encodeValueOfObjCType:"q" at:&q]);
        unsigned u = 0xffffffff; CASE("unsigned max", [a encodeValueOfObjCType:"I" at:&u]);
        unsigned short us = 65535; CASE("unsigned short max", [a encodeValueOfObjCType:"S" at:&us]);
        unsigned char uc = 200; CASE("unsigned char 200", [a encodeValueOfObjCType:"C" at:&uc]);
        BOOL yes = YES; CASE("BOOL", [a encodeValueOfObjCType:"B" at:&yes]);
        float f = 1.5f; CASE("float 1.5", [a encodeValueOfObjCType:"f" at:&f]);
        float f2 = 2; CASE("float 2", [a encodeValueOfObjCType:"f" at:&f2]);
        double d = 3.25; CASE("double 3.25", [a encodeValueOfObjCType:"d" at:&d]);
        double d2 = -3; CASE("double -3", [a encodeValueOfObjCType:"d" at:&d2]);
        double d3 = 1e20; CASE("double 1e20", [a encodeValueOfObjCType:"d" at:&d3]);
        char *cs = "hi", *cs2 = strdup("hi"), *none = NULL;
        CASE("C strings", [a encodeValueOfObjCType:"*" at:&cs]; [a encodeValueOfObjCType:"*" at:&cs];
             [a encodeValueOfObjCType:"*" at:&cs2]; [a encodeValueOfObjCType:"*" at:&none]);
        SEL sel = @selector(foo:); CASE("selector twice", [a encodeValueOfObjCType:":" at:&sel]; [a encodeValueOfObjCType:":" at:&sel]);
        Class cl = [NSString class]; CASE("class twice", [a encodeValueOfObjCType:"#" at:&cl]; [a encodeValueOfObjCType:"#" at:&cl]);
        int two[2] = {1, 2}; CASE("int array", [a encodeValueOfObjCType:"[2i]" at:two]);
        struct { int x; double y; } st = {3, 4.5}; CASE("struct", [a encodeValueOfObjCType:"{S=id}" at:&st]);
        int k[2] = {7, 8}; CASE("two ints, one group", [a encodeValuesOfObjCTypes:"ii", &k[0], &k[1]]);
        CASE("two ints, two groups", [a encodeValueOfObjCType:"i" at:&k[0]]; [a encodeValueOfObjCType:"i" at:&k[1]]);
        CASE("bytes", [a encodeBytes:"abc" length:3]);
        CASE("char array", [a encodeArrayOfObjCType:"c" count:3 at:"xyz"]);
        CASE("data object", [a encodeDataObject:[NSData dataWithBytes:"ab" length:2]]);
        CASE("point, size, rect", [a encodePoint:NSMakePoint(1, 2)]; [a encodeSize:NSMakeSize(3, 4)];
             [a encodeRect:NSMakeRect(1, 2.5, 3, 4)]);
        CASE("nil object", [a encodeObject:nil]);
        CASE("string twice", [a encodeObject:@"hello"]; [a encodeObject:@"hello"]);
        CASE("unicode string", [a encodeObject:@"é"]);
        CASE("mutable string", [a encodeObject:[NSMutableString stringWithString:@"m"]]);
        CASE("array", [a encodeObject:@[@"a", @"b"]]);
        CASE("mutable array", [a encodeObject:[NSMutableArray arrayWithObject:@"a"]]);
        CASE("dictionary", [a encodeObject:@{@"k": @"v"}]);
        CASE("set", [a encodeObject:[NSSet setWithObject:@"s"]]);
        CASE("data", [a encodeObject:[NSData dataWithBytes:"ab" length:2]]);
        CASE("mutable data", [a encodeObject:[NSMutableData dataWithBytes:"a" length:1]]);
        CASE("date", [a encodeObject:[NSDate dateWithTimeIntervalSinceReferenceDate:0]]);
        CASE("url with base", [a encodeObject:[NSURL URLWithString:@"b" relativeToURL:[NSURL URLWithString:@"http://x/"]]]);
        CASE("range value", [a encodeObject:[NSValue valueWithRange:NSMakeRange(1, 2)]]);
        NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:@"abc"];
        [as addAttribute:@"K" value:@"V" range:NSMakeRange(1, 1)];
        CASE("attributed string, three runs", [a encodeObject:as]);
        NSArray *x = @[@"q"];
        CASE("root object, shared", [a encodeRootObject:@[x, x]]);
        CASE("root object, conditional absent", [a encodeRootObject:@[@"r"]]; );

        /* round trips through this Foundation's archiver and unarchiver */
        NSArray *values = @[@"str", @[@"a", @"b"], @{@"k": @"v"}, [NSSet setWithObject:@"s"], [NSData dataWithBytes:"\x01\x02" length:2],
            [NSDate dateWithTimeIntervalSinceReferenceDate:1000], [NSURL URLWithString:@"b" relativeToURL:[NSURL URLWithString:@"http://x/"]],
            [NSValue valueWithRange:NSMakeRange(3, 4)], as];
        for (id v in values) {
            id back = [NSUnarchiver unarchiveObjectWithData:[NSArchiver archivedDataWithRootObject:v]];
            printf("round trip %s: %s\n", [show(v) UTF8String], [show(back) UTF8String]);
        }
        NSMutableData *pm = [NSMutableData data];
        NSArchiver *pa = [[NSArchiver alloc] initForWritingWithMutableData:pm];
        int iv = -70000; double dv = 2.5; char *sv = "cstr"; SEL selv = @selector(x:y:);
        [pa encodeValueOfObjCType:"i" at:&iv];
        [pa encodeValueOfObjCType:"d" at:&dv];
        [pa encodeValueOfObjCType:"*" at:&sv];
        [pa encodeValueOfObjCType:":" at:&selv];
        [pa encodeRect:NSMakeRect(1, 2, 3, 4)];
        [pa encodeBytes:"xyz" length:3];
        NSUnarchiver *pu = [[NSUnarchiver alloc] initForReadingWithData:[pa archiverData]];
        int iv2; double dv2; char *sv2; SEL selv2; NSUInteger n;
        [pu decodeValueOfObjCType:"i" at:&iv2];
        [pu decodeValueOfObjCType:"d" at:&dv2];
        [pu decodeValueOfObjCType:"*" at:&sv2];
        [pu decodeValueOfObjCType:":" at:&selv2];
        NSRect r = [pu decodeRect];
        char *bytes = [pu decodeBytesWithReturnedLength:&n];
        printf("values back: %d %g %s %s {%g %g %g %g} %.*s at end %d version %u\n", iv2, dv2, sv2, sel_getName(selv2),
            r.origin.x, r.origin.y, r.size.width, r.size.height, (int)n, bytes, [pu isAtEnd], [pu systemVersion]);
        @try {
            [pu decodeValueOfObjCType:"i" at:&iv2];
            printf("past the end: no exception\n");
        } @catch (NSException *e) {
            printf("past the end: %s\n", [[e name] UTF8String]);
        }
        NSUnarchiver *mm = [[NSUnarchiver alloc] initForReadingWithData:[NSArchiver archivedDataWithRootObject:@"s"]];
        @try {
            [mm decodeValueOfObjCType:"i" at:&iv2];
            printf("type mismatch: no exception\n");
        } @catch (NSException *e) {
            printf("type mismatch: %s\n", [[e name] UTF8String]);
        }
        printf("not an archive: %s\n", [NSUnarchiver unarchiveObjectWithData:[NSData dataWithBytes:"junk" length:4]] ? "decoded" : "nil");

        /* Apple's archive */
        NSUnarchiver *ua = [[NSUnarchiver alloc] initForReadingWithData:from_hex(apple_archive)];
        NSArray *apple = [ua decodeObject];
        printf("apple archive: %lu objects, at end %d, NSString version %ld, NSArray version %ld\n", (unsigned long)[apple count],
            [ua isAtEnd], (long)[ua versionForClassName:@"NSString"], (long)[ua versionForClassName:@"NSArray"]);
        for (id o in apple) printf("  %s: %s\n", [NSStringFromClass([o classForCoder]) UTF8String], [show(o) UTF8String]);
        printf("  same string object: %d\n", [apple objectAtIndex:0] == [apple objectAtIndex:11]);
        dump("apple archive re-archived", [NSArchiver archivedDataWithRootObject:apple]);
    }
    return 0;
}
