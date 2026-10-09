/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-coreservices-test: CoreServices.framework and what Foundation builds
 * on it. Apple event descriptors, lists, records, coercions and in-process
 * dispatch (AE); NSAppleEventDescriptor and NSAppleEventManager
 * (Foundation); the UTType C API and LaunchServices against a test app
 * bundle this program makes; FSRefs, handles, the Resource Manager and
 * Gestalt (CarbonCore); MDItem (Metadata); FSEvents. Prints everything; the
 * first line names the image AECreateDesc came from. Run it against Apple's
 * frameworks and Finch's (DYLD_FRAMEWORK_PATH) and diff all but that line.
 *
 *   finch-coreservices-test [scratch directory]
 * Use the same scratch directory under the build folder for host comparisons.
 * macOS excludes applications in /tmp when choosing registered handlers.
 * The VM default is /tmp/finch-coreservices-test.
 * Add --private-launch after the scratch directory to exercise the private
 * workspace launcher. macOS declines this case for the fixture; Finch can
 * launch it directly, so that optional line is excluded from strict parity.
 */
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSString *scratch;
static BOOL testPrivateLaunch;
static NSString *testBundleID, *testType, *testExtension, *testMIME, *testScheme, *testAppName;

/* Keep the fixture separate from older runs registered with the host's
 * LaunchServices database. Only its scratch-path suffix varies. */
static NSString *
fixtureText(NSString *text)
{
    if (!text || !testBundleID)
        return text;
    NSArray *values = @[testBundleID, testType, testExtension, testMIME, testScheme, testAppName];
    NSArray *labels = @[@"org.finch.test.coreservices", @"org.finch.test.document", @"fnchtst",
                        @"application/x-finch-test", @"finchcstest", @"FinchCSTest.app"];
    for (NSUInteger i = 0; i < values.count; i++)
        text = [text stringByReplacingOccurrencesOfString:values[i] withString:labels[i]];
    return [text stringByReplacingOccurrencesOfString:[testAppName stringByDeletingPathExtension]
                                           withString:@"FinchCSTest"];
}

static const char *
ostype(OSType t)
{
    static char buf[8][16];
    static int n;
    char *b = buf[n++ & 7];
    unsigned char c[4] = {(unsigned char)(t >> 24), (unsigned char)(t >> 16), (unsigned char)(t >> 8), (unsigned char)t};
    int printable = 1;
    for (int i = 0; i < 4; i++)
        if (c[i] < 0x20 || c[i] > 0x7e)
            printable = 0;
    if (printable)
        snprintf(b, 16, "'%c%c%c%c'", c[0], c[1], c[2], c[3]);
    else
        snprintf(b, 16, "0x%08x", (unsigned)t);
    return b;
}

static NSString *
hex(const void *p, size_t n)
{
    NSMutableString *s = [NSMutableString string];
    const unsigned char *b = p;
    for (size_t i = 0; i < n && i < 40; i++)
        [s appendFormat:@"%02x", b[i]];
    if (n > 40)
        [s appendString:@"..."];
    return s;
}

/* A descriptor: type, size and data bytes (for lists and records, their items). */
static NSString *
desc_str(const AEDesc *d)
{
    if (d->descriptorType == typeAEList || d->descriptorType == typeAERecord || d->descriptorType == typeAppleEvent ||
        AECheckIsRecord(d)) {
        long n = -1;
        OSErr e = AECountItems(d, &n);
        NSMutableString *s = [NSMutableString stringWithFormat:@"%s[%ld%s]{", ostype(d->descriptorType), n,
                                                               e ? [NSString stringWithFormat:@" err %d", e].UTF8String : ""];
        for (long i = 1; i <= n; i++) {
            AEKeyword k = 0;
            AEDesc item = {typeNull, NULL};
            e = AEGetNthDesc(d, i, typeWildCard, &k, &item);
            if (e)
                [s appendFormat:@"%s#%ld err %d", i > 1 ? ", " : "", i, e];
            else {
                NSString *key = @(ostype(k));
                [s appendFormat:@"%s%@:%@", i > 1 ? ", " : "", key, desc_str(&item)];
            }
            AEDisposeDesc(&item);
        }
        [s appendString:@"}"];
        return s;
    }
    Size n = AEGetDescDataSize(d);
    void *buf = malloc(n + 1);
    OSErr e = AEGetDescData(d, buf, n);
    NSString *r = [NSString stringWithFormat:@"%s(%ld%s%@%s)", ostype(d->descriptorType), (long)n, n ? " " : "",
                                             hex(buf, n), e ? [NSString stringWithFormat:@" err %d", e].UTF8String : ""];
    free(buf);
    return r;
}

static void
print_desc(const char *label, const AEDesc *d)
{
    printf("%s: %s null-handle %d\n", label, desc_str(d).UTF8String, d->dataHandle == NULL);
}

static NSString *
printed(const AEDesc *d)
{
    Handle h = NULL;
    OSStatus e = AEPrintDescToHandle(d, &h);
    if (e)
        return [NSString stringWithFormat:@"err %d", (int)e];
    NSString *s = [NSString stringWithUTF8String:*h];
    DisposeHandle(h);
    return s;
}

#pragma mark - AE: descriptors

static void
ae_descriptors(void)
{
    printf("== AE descriptors\n");
    AEDesc d;
    AEInitializeDesc(&d);
    print_desc("initialized", &d);
    printf("dispose null %d\n", AEDisposeDesc(&d));
    SInt32 v = 42;
    printf("create long %d\n", AECreateDesc(typeSInt32, &v, sizeof v, &d));
    print_desc("long", &d);
    printf("size %ld\n", (long)AEGetDescDataSize(&d));
    SInt16 small = 0;
    printf("get short buffer %d %d\n", AEGetDescData(&d, &small, sizeof small), small);
    SInt64 big = -1;
    printf("get big buffer %d %lld\n", AEGetDescData(&d, &big, sizeof big), big);
    AEDesc dup;
    printf("duplicate %d\n", AEDuplicateDesc(&d, &dup));
    print_desc("dup", &dup);
    printf("same storage %d\n", dup.dataHandle == d.dataHandle);
    SInt32 w = 7;
    printf("replace %d\n", AEReplaceDescData(typeSInt16, &w, 2, &dup));
    print_desc("replaced", &dup);
    print_desc("original", &d);
    AEDisposeDesc(&dup);
    printf("disposed type %s null %d\n", ostype(dup.descriptorType), dup.dataHandle == NULL);
    AEDisposeDesc(&d);
    printf("create null %d\n", AECreateDesc(typeNull, NULL, 0, &d));
    print_desc("null", &d);
    AEDisposeDesc(&d);
    printf("create empty text %d\n", AECreateDesc(typeUTF8Text, "", 0, &d));
    print_desc("empty", &d);
    AEDisposeDesc(&d);
    printf("create true %d\n", AECreateDesc(typeTrue, NULL, 0, &d));
    print_desc("true", &d);
    AEDisposeDesc(&d);
    printf("create utf8 %d\n", AECreateDesc(typeUTF8Text, "h\xc3\xa9llo", 6, &d));
    print_desc("utf8", &d);
    printf("printed %s\n", printed(&d).UTF8String);
    AEDisposeDesc(&d);
    char range[4] = {0};
    AECreateDesc(typeUTF8Text, "abcdefgh", 8, &d);
    printf("range %d %.4s\n", AEGetDescDataRange(&d, range, 2, 4), range);
    printf("range past %d\n", AEGetDescDataRange(&d, range, 6, 4));
    AEDisposeDesc(&d);
    printf("list as desc %d\n", AECreateDesc(typeAEList, NULL, 0, &d));
    print_desc("list desc", &d);
    AEDisposeDesc(&d);
}

#pragma mark - AE: lists and records

static void
ae_lists(void)
{
    printf("== AE lists\n");
    AEDescList l;
    printf("create list %d\n", AECreateList(NULL, 0, false, &l));
    print_desc("empty list", &l);
    SInt32 a = 1, b = 2, c = 3;
    printf("put 0 %d\n", AEPutPtr(&l, 0, typeSInt32, &a, 4));
    printf("put 1 %d\n", AEPutPtr(&l, 1, typeSInt32, &b, 4));
    printf("put 2 %d\n", AEPutPtr(&l, 2, typeSInt32, &c, 4));
    printf("put 3 %d\n", AEPutPtr(&l, 3, typeUTF8Text, "x", 1));
    print_desc("list", &l);
    long n = 0;
    AECountItems(&l, &n);
    printf("count %ld\n", n);
    AEKeyword k;
    DescType t;
    Size sz;
    SInt32 out = 0;
    printf("nth ptr 2 %d", AEGetNthPtr(&l, 2, typeSInt32, &k, &t, &out, 4, &sz));
    printf(" key %s type %s size %ld val %d\n", ostype(k), ostype(t), (long)sz, out);
    double dv = 0;
    printf("nth ptr 3 as double %d", AEGetNthPtr(&l, 1, typeIEEE64BitFloatingPoint, &k, &t, &dv, 8, &sz));
    printf(" type %s size %ld val %g\n", ostype(t), (long)sz, dv);
    printf("nth ptr 9 %d\n", AEGetNthPtr(&l, 9, typeSInt32, &k, &t, &out, 4, &sz));
    printf("nth ptr 0 %d\n", AEGetNthPtr(&l, 0, typeSInt32, &k, &t, &out, 4, &sz));
    printf("nth ptr 3 as long %d\n", AEGetNthPtr(&l, 3, typeSInt32, &k, &t, &out, 4, &sz));
    printf("size of 3 %d", AESizeOfNthItem(&l, 3, &t, &sz));
    printf(" type %s size %ld\n", ostype(t), (long)sz);
    printf("delete 1 %d\n", AEDeleteItem(&l, 1));
    printf("delete 9 %d\n", AEDeleteItem(&l, 9));
    print_desc("after delete", &l);
    printf("put key into list %d\n", AEPutKeyPtr(&l, 'abcd', typeSInt32, &a, 4));
    printf("is record %d\n", AECheckIsRecord(&l));
    AEDescList nested;
    AECreateList(NULL, 0, false, &nested);
    AEPutDesc(&nested, 0, &l);
    AEPutPtr(&nested, 0, typeSInt32, &a, 4);
    print_desc("nested", &nested);
    printf("printed %s\n", printed(&nested).UTF8String);
    AEDisposeDesc(&nested);
    AEDisposeDesc(&l);

    AERecord r;
    printf("create record %d\n", AECreateList(NULL, 0, true, &r));
    print_desc("empty record", &r);
    printf("put key %d\n", AEPutKeyPtr(&r, 'abcd', typeSInt32, &a, 4));
    printf("put key %d\n", AEPutKeyPtr(&r, 'efgh', typeUTF8Text, "hi", 2));
    printf("replace key %d\n", AEPutKeyPtr(&r, 'abcd', typeSInt32, &b, 4));
    printf("put index %d\n", AEPutPtr(&r, 0, typeSInt32, &c, 4));
    print_desc("record", &r);
    printf("is record %d\n", AECheckIsRecord(&r));
    printf("get key %d", AEGetKeyPtr(&r, 'abcd', typeWildCard, &t, &out, 4, &sz));
    printf(" type %s val %d\n", ostype(t), out);
    char txt[8] = {0};
    printf("get key as text %d", AEGetKeyPtr(&r, 'abcd', typeUTF8Text, &t, txt, 7, &sz));
    printf(" type %s size %ld %s\n", ostype(t), (long)sz, txt);
    printf("get missing %d\n", AEGetKeyPtr(&r, 'zzzz', typeWildCard, &t, &out, 4, &sz));
    AEDesc kd;
    printf("get key desc %d", AEGetKeyDesc(&r, 'efgh', typeWildCard, &kd));
    print_desc("", &kd);
    AEDisposeDesc(&kd);
    printf("size of key %d", AESizeOfKeyDesc(&r, 'efgh', &t, &sz));
    printf(" type %s size %ld\n", ostype(t), (long)sz);
    printf("has key %d %d\n", AECheckIsRecord(&r), (int)AEGetKeyDesc(&r, 'efgh', typeSInt32, &kd));
    printf("delete key %d\n", AEDeleteKeyDesc(&r, 'abcd'));
    printf("delete missing %d\n", AEDeleteKeyDesc(&r, 'abcd'));
    print_desc("after delete", &r);
    printf("printed %s\n", printed(&r).UTF8String);
    AEDesc coerced;
    printf("record to list %d\n", AECoerceDesc(&r, typeAEList, &coerced));
    AEDisposeDesc(&coerced);
    printf("record to custom %d", AECoerceDesc(&r, 'cust', &coerced));
    print_desc("", &coerced);
    printf("custom is record %d\n", AECheckIsRecord(&coerced));
    printf("printed %s\n", printed(&coerced).UTF8String);
    AEDisposeDesc(&coerced);
    AEDisposeDesc(&r);

    AEDesc numbers;
    SInt32 arr[3] = {10, 20, 30};
    AECreateList(NULL, 0, false, &numbers);
    printf("put array %d\n", AEPutArray(&numbers, kAEDataArray, (const AEArrayData *)arr, typeSInt32, 4, 3));
    print_desc("array", &numbers);
    AEDisposeDesc(&numbers);
}

#pragma mark - AE: coercions

static void
ae_coercions(void)
{
    printf("== AE coercions\n");
    struct src {
        const char *name;
        DescType type;
        const void *data;
        Size size;
    };
    SInt16 s7 = 7;
    SInt32 l42 = 42, lneg = -5, l100k = 100000, l1 = 1, l0 = 0;
    SInt64 c40 = 1LL << 40;
    UInt32 m4g = 4000000000u;
    double d35 = 3.5, d2 = 2.0, d1e20 = 1e20, dneg = -2.75;
    float f125 = 1.25f;
    Boolean bt = 1, bf = 0;
    OSType tabcd = 'abcd', eyes = 'yes ', ttrue = 'true';
    UniChar u42[2] = {'4', '2'};
    UniChar uhi[3] = {'h', 0xe9, 'y'};
    struct src srcs[] = {
        {"shor 7", typeSInt16, &s7, 2},
        {"long 42", typeSInt32, &l42, 4},
        {"long -5", typeSInt32, &lneg, 4},
        {"long 100000", typeSInt32, &l100k, 4},
        {"long 1", typeSInt32, &l1, 4},
        {"long 0", typeSInt32, &l0, 4},
        {"comp 2^40", typeSInt64, &c40, 8},
        {"magn 4e9", typeUInt32, &m4g, 4},
        {"doub 3.5", typeIEEE64BitFloatingPoint, &d35, 8},
        {"doub 2", typeIEEE64BitFloatingPoint, &d2, 8},
        {"doub -2.75", typeIEEE64BitFloatingPoint, &dneg, 8},
        {"doub 1e20", typeIEEE64BitFloatingPoint, &d1e20, 8},
        {"sing 1.25", typeIEEE32BitFloatingPoint, &f125, 4},
        {"bool 1", typeBoolean, &bt, 1},
        {"bool 0", typeBoolean, &bf, 1},
        {"true", typeTrue, NULL, 0},
        {"fals", typeFalse, NULL, 0},
        {"TEXT 123", typeChar, "123", 3},
        {"TEXT -8", typeChar, "-8", 2},
        {"TEXT 1.5", typeChar, "1.5", 3},
        {"TEXT hello", typeChar, "hello", 5},
        {"TEXT true", typeChar, "true", 4},
        {"TEXT abcd", typeChar, "abcd", 4},
        {"utxt 42", typeUnicodeText, u42, 4},
        {"utxt hey", typeUnicodeText, uhi, 6},
        {"utf8 77", typeUTF8Text, "77", 2},
        {"utf8 caf\xc3\xa9", typeUTF8Text, "caf\xc3\xa9", 5},
        {"type abcd", typeType, &tabcd, 4},
        {"type true", typeType, &ttrue, 4},
        {"enum yes", typeEnumerated, &eyes, 4},
        {"null", typeNull, NULL, 0},
        {"furl", typeFileURL, "file:///tmp/a%20b", 17},
        {"custom", 'cust', "xy", 2},
    };
    DescType targets[] = {typeSInt16,    typeSInt32,    typeSInt64,  typeUInt32,     typeIEEE64BitFloatingPoint,
                          typeIEEE32BitFloatingPoint,   typeBoolean, typeChar,       typeUnicodeText,
                          typeUTF8Text,  typeType,      typeEnumerated, typeAEList,  typeAERecord,
                          typeFileURL,   typeWildCard,  typeNull,    typeTrue,       'cust'};
    for (size_t i = 0; i < sizeof srcs / sizeof *srcs; i++) {
        for (size_t j = 0; j < sizeof targets / sizeof *targets; j++) {
            AEDesc r = {typeNull, NULL};
            OSErr e = AECoercePtr(srcs[i].type, srcs[i].data, srcs[i].size, targets[j], &r);
            if (e)
                printf("%s -> %s: err %d\n", srcs[i].name, ostype(targets[j]), e);
            else
                printf("%s -> %s: %s\n", srcs[i].name, ostype(targets[j]), desc_str(&r).UTF8String);
            AEDisposeDesc(&r);
        }
    }
    /* lists of one item coerce to the item's type, and items to lists */
    AEDescList one, two;
    AECreateList(NULL, 0, false, &one);
    AEPutPtr(&one, 0, typeSInt32, &l42, 4);
    AECreateList(NULL, 0, false, &two);
    AEPutPtr(&two, 0, typeSInt32, &l42, 4);
    AEPutPtr(&two, 0, typeUTF8Text, "x", 1);
    DescType lt[] = {typeSInt32, typeUTF8Text, typeAEList, typeAERecord, typeWildCard};
    for (size_t j = 0; j < sizeof lt / sizeof *lt; j++) {
        AEDesc r = {typeNull, NULL};
        OSErr e = AECoerceDesc(&one, lt[j], &r);
        printf("list1 -> %s: %s\n", ostype(lt[j]), e ? [NSString stringWithFormat:@"err %d", e].UTF8String : desc_str(&r).UTF8String);
        AEDisposeDesc(&r);
        e = AECoerceDesc(&two, lt[j], &r);
        printf("list2 -> %s: %s\n", ostype(lt[j]), e ? [NSString stringWithFormat:@"err %d", e].UTF8String : desc_str(&r).UTF8String);
        AEDisposeDesc(&r);
    }
    AEDisposeDesc(&one);
    AEDisposeDesc(&two);
}

#pragma mark - AE: Apple events and handlers

static int handler_calls;

static OSErr
echo_handler(const AppleEvent *event, AppleEvent *reply, SRefCon refcon)
{
    handler_calls++;
    AEDesc direct;
    OSErr e = AEGetParamDesc(event, keyDirectObject, typeWildCard, &direct);
    printf("  handler refcon %ld direct %s reply type %s\n", (long)refcon,
           e ? [NSString stringWithFormat:@"err %d", e].UTF8String : desc_str(&direct).UTF8String,
           ostype(reply->descriptorType));
    if (!e && reply->descriptorType != typeNull)
        AEPutParamDesc(reply, keyDirectObject, &direct);
    AEDisposeDesc(&direct);
    return (intptr_t)refcon == 99 ? -1728 : noErr;
}

static OSErr
coerce_handler(const AEDesc *from, DescType to, SRefCon refcon, AEDesc *result)
{
    printf("  coercion %s -> %s refcon %ld\n", ostype(from->descriptorType), ostype(to), (long)refcon);
    return AECreateDesc(to, "zz", 2, result);
}

static void
attr(const AppleEvent *ae, AEKeyword key, DescType want)
{
    DescType t = 0;
    Size sz = 0;
    char buf[64] = {0};
    OSErr e = AEGetAttributePtr(ae, key, want, &t, buf, sizeof buf, &sz);
    if (e)
        printf("attr %s as %s: err %d\n", ostype(key), ostype(want), e);
    else
        printf("attr %s as %s: %s size %ld %s\n", ostype(key), ostype(want), ostype(t), (long)sz,
               (key == keyReturnIDAttr || key == keyTransactionIDAttr) ? "" : hex(buf, MIN(sz, (Size)sizeof buf)).UTF8String);
}

static void
ae_events(void)
{
    printf("== AE events\n");
    ProcessSerialNumber self = {0, 2 /* kCurrentProcess (ApplicationServices) */};
    AEAddressDesc target;
    printf("target %d\n", AECreateDesc(typeProcessSerialNumber, &self, sizeof self, &target));
    AppleEvent ae;
    printf("create %d\n", AECreateAppleEvent('fnch', 'test', &target, kAutoGenerateReturnID, kAnyTransactionID, &ae));
    printf("type %s is record %d\n", ostype(ae.descriptorType), AECheckIsRecord(&ae));
    long n = -1;
    printf("count %d %ld\n", AECountItems(&ae, &n), n);
    attr(&ae, keyEventClassAttr, typeWildCard);
    attr(&ae, keyEventIDAttr, typeType);
    attr(&ae, keyEventClassAttr, typeUTF8Text);
    attr(&ae, keyAddressAttr, typeWildCard);
    attr(&ae, keyTransactionIDAttr, typeWildCard);
    attr(&ae, keyEventSourceAttr, typeWildCard);
    attr(&ae, keyInteractLevelAttr, typeWildCard);
    attr(&ae, keyTimeoutAttr, typeWildCard);
    attr(&ae, keyMissedKeywordAttr, typeWildCard);
    attr(&ae, 'zzzz', typeWildCard);
    SInt32 rid = 0;
    DescType t;
    Size sz;
    AEGetAttributePtr(&ae, keyReturnIDAttr, typeSInt32, &t, &rid, 4, &sz);
    printf("return id type %s nonzero %d\n", ostype(t), rid != 0);
    SInt32 v = 5;
    printf("put param %d\n", AEPutParamPtr(&ae, keyDirectObject, typeSInt32, &v, 4));
    printf("put param %d\n", AEPutParamPtr(&ae, 'parm', typeUTF8Text, "text", 4));
    printf("count %d %ld\n", AECountItems(&ae, &n), n);
    AEDesc p;
    printf("get param %d", AEGetParamDesc(&ae, keyDirectObject, typeWildCard, &p));
    print_desc("", &p);
    AEDisposeDesc(&p);
    printf("get param as text %d", AEGetParamDesc(&ae, keyDirectObject, typeUTF8Text, &p));
    print_desc("", &p);
    AEDisposeDesc(&p);
    printf("get missing %d\n", AEGetParamDesc(&ae, 'nope', typeWildCard, &p));
    printf("size of param %d", AESizeOfParam(&ae, 'parm', &t, &sz));
    printf(" type %s size %ld\n", ostype(t), (long)sz);
    char buf[16] = {0};
    printf("get param ptr %d", AEGetParamPtr(&ae, 'parm', typeChar, &t, buf, sizeof buf - 1, &sz));
    printf(" type %s size %ld %s\n", ostype(t), (long)sz, buf);
    AEKeyword k;
    printf("nth %d", AEGetNthDesc(&ae, 2, typeWildCard, &k, &p));
    printf(" key %s", ostype(k));
    print_desc("", &p);
    AEDisposeDesc(&p);
    printf("put attr %d\n", AEPutAttributePtr(&ae, 'xatr', typeSInt32, &v, 4));
    attr(&ae, 'xatr', typeWildCard);
    printf("put attr class %d\n", AEPutAttributePtr(&ae, keyEventClassAttr, typeType, "abcd", 4));
    attr(&ae, keyEventClassAttr, typeWildCard);
    OSType fnch = 'fnch';
    AEPutAttributePtr(&ae, keyEventClassAttr, typeType, &fnch, 4);
    printf("size of attr %d", AESizeOfAttribute(&ae, keyAddressAttr, &t, &sz));
    printf(" type %s size %ld\n", ostype(t), (long)sz);
    printf("delete param %d\n", AEDeleteParam(&ae, 'parm'));
    printf("delete missing %d\n", AEDeleteParam(&ae, 'parm'));
    printf("count %d %ld\n", AECountItems(&ae, &n), n);
    AEDesc as_record;
    printf("event to record %d", AECoerceDesc(&ae, typeAERecord, &as_record));
    print_desc("", &as_record);
    AEDisposeDesc(&as_record);

    /* handlers */
    AEEventHandlerUPP h = NewAEEventHandlerUPP(echo_handler);
    AEEventHandlerUPP got = NULL;
    SRefCon rc = 0;
    printf("get handler before %d\n", AEGetEventHandler('fnch', 'test', &got, &rc, false));
    printf("install %d\n", AEInstallEventHandler('fnch', 'test', h, (SRefCon)7, false));
    printf("get handler %d same %d refcon %ld\n", AEGetEventHandler('fnch', 'test', &got, &rc, false), got == h, (long)rc);
    printf("get wildcard-class %d\n", AEGetEventHandler('fnch', 'othr', &got, &rc, false));
    printf("install wildcard %d\n", AEInstallEventHandler('fnch', typeWildCard, h, (SRefCon)8, false));
    printf("get via wildcard %d refcon %ld\n", AEGetEventHandler('fnch', 'othr', &got, &rc, false), (long)rc);

    AppleEvent reply;
    AEInitializeDesc(&reply);
    handler_calls = 0;
    OSStatus e = AESendMessage(&ae, &reply, kAEWaitReply, kAEDefaultTimeout);
    printf("send self %d calls %d\n", (int)e, handler_calls);
    printf("reply type %s record %d\n", ostype(reply.descriptorType), AECheckIsRecord(&reply));
    if (reply.descriptorType != typeNull) {
        printf("reply count %d %ld\n", AECountItems(&reply, &n), n);
        printf("reply direct %d", AEGetParamDesc(&reply, keyDirectObject, typeWildCard, &p));
        print_desc("", &p);
        AEDisposeDesc(&p);
        attr(&reply, keyEventClassAttr, typeWildCard);
        attr(&reply, keyEventIDAttr, typeWildCard);
        SInt32 rrid = 0;
        AEGetAttributePtr(&reply, keyReturnIDAttr, typeSInt32, &t, &rrid, 4, &sz);
        printf("reply return id matches %d\n", rrid == rid);
    }
    AEDisposeDesc(&reply);

    AppleEvent other;
    AECreateAppleEvent('fnch', 'othr', &target, kAutoGenerateReturnID, kAnyTransactionID, &other);
    AEPutParamPtr(&other, keyDirectObject, typeUTF8Text, "o", 1);
    e = AESendMessage(&other, &reply, kAEWaitReply, kAEDefaultTimeout);
    printf("send wildcard-handled %d calls %d\n", (int)e, handler_calls);
    AEDisposeDesc(&reply);
    e = AESendMessage(&other, &reply, kAENoReply, kAEDefaultTimeout);
    printf("send no reply %d calls %d reply %s\n", (int)e, handler_calls, ostype(reply.descriptorType));
    AEDisposeDesc(&reply);
    AEDisposeDesc(&other);

    AEInstallEventHandler('fnch', 'fail', h, (SRefCon)99, false);
    AECreateAppleEvent('fnch', 'fail', &target, kAutoGenerateReturnID, kAnyTransactionID, &other);
    e = AESendMessage(&other, &reply, kAEWaitReply, kAEDefaultTimeout);
    printf("send failing %d calls %d\n", (int)e, handler_calls);
    SInt32 errn = 0;
    OSErr ge = AEGetParamPtr(&reply, keyErrorNumber, typeSInt32, &t, &errn, 4, &sz);
    printf("reply errn %d %d\n", ge, errn);
    AEDisposeDesc(&reply);
    AEDisposeDesc(&other);

    printf("remove %d\n", AERemoveEventHandler('fnch', 'test', h, false));
    printf("remove again %d\n", AERemoveEventHandler('fnch', 'test', h, false));
    printf("remove wildcard %d\n", AERemoveEventHandler('fnch', typeWildCard, h, false));
    AERemoveEventHandler('fnch', 'fail', h, false);
    e = AESendMessage(&ae, &reply, kAEWaitReply, kAEDefaultTimeout);
    printf("send unhandled %d\n", (int)e);
    if (reply.descriptorType != typeNull) {
        errn = 0;
        ge = AEGetParamPtr(&reply, keyErrorNumber, typeSInt32, &t, &errn, 4, &sz);
        printf("unhandled reply errn %d %d\n", ge, errn);
    }
    AEDisposeDesc(&reply);

    /* no such process */
    pid_t nobody = 99999;
    AEAddressDesc gone;
    AECreateDesc(typeKernelProcessID, &nobody, sizeof nobody, &gone);
    AppleEvent toGone;
    AECreateAppleEvent('fnch', 'test', &gone, kAutoGenerateReturnID, kAnyTransactionID, &toGone);
    e = AESendMessage(&toGone, &reply, kAEWaitReply, 60);
    printf("send to missing pid %d\n", (int)e);
    AEDisposeDesc(&reply);
    AEDisposeDesc(&toGone);
    AEDisposeDesc(&gone);
    AECreateDesc(typeApplicationBundleID, "org.finch.no-such-app", 21, &gone);
    AECreateAppleEvent('fnch', 'test', &gone, kAutoGenerateReturnID, kAnyTransactionID, &toGone);
    e = AESendMessage(&toGone, &reply, kAEWaitReply, 60);
    printf("send to missing bundle %d\n", (int)e);
    AEDisposeDesc(&reply);
    AEDisposeDesc(&toGone);
    AEDisposeDesc(&gone);

    /* coercion handlers */
    AECoerceDescUPP ch = NewAECoerceDescUPP(coerce_handler);
    printf("install coercion %d\n", AEInstallCoercionHandler('fnc1', 'fnc2', (AECoercionHandlerUPP)ch, (SRefCon)3, true, false));
    AEDesc src, dst;
    AECreateDesc('fnc1', "a", 1, &src);
    printf("coerce custom %d", AECoerceDesc(&src, 'fnc2', &dst));
    print_desc("", &dst);
    AEDisposeDesc(&dst);
    printf("remove coercion %d\n", AERemoveCoercionHandler('fnc1', 'fnc2', (AECoercionHandlerUPP)ch, false));
    printf("coerce custom after %d\n", AECoerceDesc(&src, 'fnc2', &dst));
    AEDisposeDesc(&src);

    /* special handlers and manager info */
    printf("special get %d\n", AEGetSpecialHandler(keyPreDispatch, &got, false));
    printf("special install %d\n", AEInstallSpecialHandler(keyPreDispatch, h, false));
    printf("special get %d same %d\n", AEGetSpecialHandler(keyPreDispatch, &got, false), got == h);
    printf("special remove %d\n", AERemoveSpecialHandler(keyPreDispatch, h, false));
    printf("special get %d\n", AEGetSpecialHandler(keyPreDispatch, &got, false));
    long info = -1;
    printf("manager info %d %ld\n", AEManagerInfo(keyAEVersion, &info), info > 0 ? 1L : info);
    printf("printed event %s\n", printed(&ae).UTF8String);
    AEDisposeDesc(&ae);
    AEDisposeDesc(&target);
}

#pragma mark - AE: object specifiers

static int accessor_calls;

static OSErr
accessor(DescType desiredClass, const AEDesc *container, DescType containerClass, DescType form, const AEDesc *selectionData,
         AEDesc *value, SRefCon refcon)
{
    accessor_calls++;
    printf("  accessor want %s container %s class %s form %s data %s refcon %ld\n", ostype(desiredClass),
           desc_str(container).UTF8String, ostype(containerClass), ostype(form), desc_str(selectionData).UTF8String,
           (long)refcon);
    if (desiredClass == 'fail')
        return errAENoSuchObject;
    SInt32 token = accessor_calls * 10;
    return AECreateDesc(desiredClass == 'docu' ? 'dtok' : 'wtok', &token, 4, value);
}

static int disposed_tokens;

static OSErr
dispose_token(AEDesc *token)
{
    disposed_tokens++;
    printf("  dispose token %s\n", desc_str(token).UTF8String);
    return AEDisposeDesc(token);
}

static void
ae_objects(void)
{
    printf("== AE objects\n");
    printf("init %d\n", AEObjectInit());
    AEDesc null = {typeNull, NULL}, offset, docSpec, wordSpec, name, cmp, logic, range, a, b;
    printf("offset %d", CreateOffsetDescriptor(2, &offset));
    print_desc("", &offset);
    printf("doc spec %d", CreateObjSpecifier('docu', &null, formAbsolutePosition, &offset, false, &docSpec));
    print_desc("", &docSpec);
    printf("printed %s\n", printed(&docSpec).UTF8String);
    AECreateDesc(typeUTF8Text, "hello", 5, &name);
    printf("word spec %d", CreateObjSpecifier('cwor', &docSpec, formName, &name, false, &wordSpec));
    print_desc("", &wordSpec);
    printf("printed %s\n", printed(&wordSpec).UTF8String);
    SInt32 one = 1, two = 2;
    AECreateDesc(typeSInt32, &one, 4, &a);
    AECreateDesc(typeSInt32, &two, 4, &b);
    printf("comp %d", CreateCompDescriptor(kAEEquals, &a, &b, false, &cmp));
    print_desc("", &cmp);
    AEDescList terms;
    AECreateList(NULL, 0, false, &terms);
    AEPutDesc(&terms, 0, &cmp);
    printf("logical %d", CreateLogicalDescriptor(&terms, kAEAND, false, &logic));
    print_desc("", &logic);
    printf("range %d", CreateRangeDescriptor(&a, &b, false, &range));
    print_desc("", &range);

    AEDesc token;
    printf("resolve without accessor %d\n", AEResolve(&docSpec, kAEIDoMinimum, &token));
    OSLAccessorUPP acc = NewOSLAccessorUPP(accessor);
    printf("install %d\n", AEInstallObjectAccessor('docu', typeNull, acc, (SRefCon)5, false));
    printf("install %d\n", AEInstallObjectAccessor(typeWildCard, 'dtok', acc, (SRefCon)6, false));
    OSLAccessorUPP got;
    SRefCon rc;
    printf("get %d same %d refcon %ld\n", AEGetObjectAccessor('docu', typeNull, &got, &rc, false), got == acc, (long)rc);
    printf("get wildcard %d\n", AEGetObjectAccessor('cwor', 'dtok', &got, &rc, false));
    accessor_calls = 0;
    printf("resolve doc %d", AEResolve(&docSpec, kAEIDoMinimum, &token));
    print_desc("", &token);
    AEDisposeToken(&token);
    printf("resolve word %d", AEResolve(&wordSpec, kAEIDoMinimum, &token));
    print_desc("", &token);
    printf("dispose token %d\n", AEDisposeToken(&token));
    printf("callbacks %d\n", AESetObjectCallbacks(NULL, NULL, NewOSLDisposeTokenUPP(dispose_token), NULL, NULL, NULL, NULL));
    disposed_tokens = 0;
    printf("resolve word %d", AEResolve(&wordSpec, kAEIDoMinimum, &token));
    print_desc("", &token);
    printf("disposed %d\n", disposed_tokens);
    printf("dispose token %d disposed %d\n", AEDisposeToken(&token), disposed_tokens);
    AEDesc failSpec;
    CreateObjSpecifier('fail', &docSpec, formName, &name, false, &failSpec);
    printf("resolve failing %d", AEResolve(&failSpec, kAEIDoMinimum, &token));
    print_desc("", &token);
    printf("resolve text %d\n", AEResolve(&name, kAEIDoMinimum, &token));
    printf("resolve null %d", AEResolve(&null, kAEIDoMinimum, &token));
    print_desc("", &token);
    AESetObjectCallbacks(NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    printf("remove %d\n", AERemoveObjectAccessor('docu', typeNull, acc, false));
    printf("remove again %d\n", AERemoveObjectAccessor('docu', typeNull, acc, false));
    AERemoveObjectAccessor(typeWildCard, 'dtok', acc, false);
    AEDisposeDesc(&failSpec);
    AEDisposeDesc(&offset);
    AEDisposeDesc(&docSpec);
    AEDisposeDesc(&wordSpec);
    AEDisposeDesc(&name);
    AEDisposeDesc(&cmp);
    AEDisposeDesc(&terms);
    AEDisposeDesc(&logic);
    AEDisposeDesc(&range);
    AEDisposeDesc(&a);
    AEDisposeDesc(&b);
}

#pragma mark - CarbonCore

static NSString *
uni(const HFSUniStr255 *u)
{
    return [NSString stringWithCharacters:u->unicode length:u->length];
}

static NSString *
ref_path(const FSRef *ref)
{
    UInt8 buf[PATH_MAX];
    OSStatus e = FSRefMakePath(ref, buf, sizeof buf);
    return e ? [NSString stringWithFormat:@"err %d", (int)e] : @((const char *)buf);
}

/* A path with the scratch directory (as resolved) shown as $S. */
static NSString *
rel(NSString *p)
{
    char buf[PATH_MAX];
    NSString *real = realpath(scratch.fileSystemRepresentation, buf) ? @(buf) : scratch;
    if ([p hasPrefix:real])
        return fixtureText([@"$S" stringByAppendingString:[p substringFromIndex:real.length]]);
    if ([p hasPrefix:scratch])
        return fixtureText([@"$S" stringByAppendingString:[p substringFromIndex:scratch.length]]);
    return p;
}

static void
put_be32(NSMutableData *d, uint32_t v)
{
    uint32_t b = CFSwapInt32HostToBig(v);
    [d appendBytes:&b length:4];
}

static void
put_be16(NSMutableData *d, uint16_t v)
{
    uint16_t b = CFSwapInt16HostToBig(v);
    [d appendBytes:&b length:2];
}

/* A resource file: TEXT 128 "Greeting" = hello, TEXT 129 = world, STR  200 = \pFinch. */
static NSData *
resource_file(void)
{
    NSMutableData *data = [NSMutableData data];
    put_be32(data, 5); [data appendBytes:"hello" length:5];
    put_be32(data, 5); [data appendBytes:"world" length:5];
    put_be32(data, 6); [data appendBytes:"\005Finch" length:6];
    NSMutableData *map = [NSMutableData dataWithLength:16 + 4 + 2 + 2];
    put_be16(map, 28);            /* type list offset */
    NSUInteger nameListOffsetAt = map.length;
    put_be16(map, 0);             /* name list offset, patched */
    put_be16(map, 1);             /* 2 types - 1 */
    [map appendBytes:"TEXT" length:4]; put_be16(map, 1); put_be16(map, 2 + 2 * 8);
    [map appendBytes:"STR " length:4]; put_be16(map, 0); put_be16(map, 2 + 2 * 8 + 2 * 12);
    uint32_t offs[3] = {0, 9, 18};
    int16_t ids[3] = {128, 129, 200};
    int16_t names[3] = {0, -1, -1};
    for (int i = 0; i < 3; i++) {
        put_be16(map, ids[i]);
        put_be16(map, names[i]);
        uint32_t attrOff = (i == 1 ? (uint32_t)resPurgeable << 24 : 0) | offs[i];
        put_be32(map, attrOff);
        put_be32(map, 0);
    }
    uint16_t nameList = CFSwapInt16HostToBig((uint16_t)map.length);
    [map replaceBytesInRange:NSMakeRange(nameListOffsetAt, 2) withBytes:&nameList];
    [map appendBytes:"\010Greeting" length:9];
    NSMutableData *file = [NSMutableData data];
    put_be32(file, 256);
    put_be32(file, 256 + (uint32_t)data.length);
    put_be32(file, (uint32_t)data.length);
    put_be32(file, (uint32_t)map.length);
    [file increaseLengthBy:256 - 16];
    [file appendData:data];
    [file appendData:map];
    return file;
}

static void
show_res(const char *label, Handle h)
{
    if (!h) {
        printf("%s: NULL ResError %d\n", label, ResError());
        return;
    }
    ResID rid = 0;
    ResType type = 0;
    Str255 name = {0};
    GetResInfo(h, &rid, &type, name);
    printf("%s: %s %d '%.*s' size %ld data %s attrs 0x%x ResError %d\n", label, ostype(type), rid, name[0], name + 1,
           (long)GetHandleSize(h), hex(*h, GetHandleSize(h)).UTF8String, GetResAttrs(h), ResError());
}

static void
carboncore(void)
{
    printf("== CarbonCore handles\n");
    Handle h = NewHandle(10);
    printf("new %d size %ld err %d\n", h != NULL, (long)GetHandleSize(h), MemError());
    SetHandleSize(h, 3);
    memcpy(*h, "abc", 3);
    printf("resized %ld err %d\n", (long)GetHandleSize(h), MemError());
    printf("ptr and hand %d\n", PtrAndHand("def", h, 3));
    printf("contents %.*s\n", (int)GetHandleSize(h), *h);
    Handle copy = h;
    printf("hand to hand %d same %d size %ld\n", HandToHand(&copy), copy == h, (long)GetHandleSize(copy));
    printf("hand and hand %d size %ld\n", HandAndHand(h, copy), (long)GetHandleSize(copy));
    Handle p2h = NULL;
    printf("ptr to hand %d size %ld\n", PtrToHand("xyz", &p2h, 3), (long)GetHandleSize(p2h));
    printf("state %d", HGetState(h));
    HLock(h);
    printf(" locked %d", HGetState(h) & 0x80 ? 1 : 0);
    HUnlock(h);
    printf(" unlocked %d\n", HGetState(h) & 0x80 ? 1 : 0);
    Handle clear = NewHandleClear(4);
    printf("clear %s\n", hex(*clear, 4).UTF8String);
    EmptyHandle(clear);
    printf("emptied master %d size %ld\n", *clear == NULL, (long)GetHandleSize(clear));
    ReallocateHandle(clear, 2);
    printf("reallocated %ld err %d\n", (long)GetHandleSize(clear), MemError());
    DisposeHandle(clear);
    DisposeHandle(h);
    DisposeHandle(copy);
    DisposeHandle(p2h);
    printf("dispose err %d\n", MemError());
    Ptr p = NewPtr(12);
    printf("ptr size %ld\n", (long)GetPtrSize(p));
    DisposePtr(p);
    p = NewPtrClear(3);
    printf("clear ptr %s\n", hex(p, 3).UTF8String);
    DisposePtr(p);
    Handle empty = NewEmptyHandle();
    printf("empty handle master %d size %ld\n", *empty == NULL, (long)GetHandleSize(empty));
    DisposeHandle(empty);

    printf("== CarbonCore files\n");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [scratch stringByAppendingPathComponent:@"files"];
    [fm removeItemAtPath:dir error:nil];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *file = [dir stringByAppendingPathComponent:@"test.txt"];
    [@"hello world" writeToFile:file atomically:NO encoding:NSUTF8StringEncoding error:nil];
    chmod(file.fileSystemRepresentation, 0640);
    FSRef ref, dref, parent;
    Boolean isDir = 9;
    printf("make ref %d dir %d\n", (int)FSPathMakeRef((const UInt8 *)file.fileSystemRepresentation, &ref, &isDir), isDir);
    printf("make dir ref %d", (int)FSPathMakeRef((const UInt8 *)dir.fileSystemRepresentation, &dref, &isDir));
    printf(" dir %d\n", isDir);
    printf("missing %d\n", (int)FSPathMakeRef((const UInt8 *)"/nonexistent/finch", &parent, NULL));
    printf("path %s\n", rel(ref_path(&ref)).UTF8String);
    printf("compare self %d other %d\n", FSCompareFSRefs(&ref, &ref), FSCompareFSRefs(&ref, &dref));
    FSRef again;
    FSPathMakeRef((const UInt8 *)file.fileSystemRepresentation, &again, NULL);
    printf("compare again %d\n", FSCompareFSRefs(&ref, &again));
    FSCatalogInfo info;
    HFSUniStr255 name;
    memset(&info, 0xee, sizeof info);
    OSErr e = FSGetCatalogInfo(&ref, kFSCatInfoGettableInfo, &info, &name, NULL, &parent);
    struct stat st;
    stat(file.fileSystemRepresentation, &st);
    printf("catalog %d name %s parent %s\n", e, uni(&name).UTF8String, rel(ref_path(&parent)).UTF8String);
    printf("node flags 0x%x sizes %llu %d rsrc %llu %llu valence %u\n", info.nodeFlags & ~(kFSNodeDataOpenMask | kFSNodeResOpenMask | kFSNodeForkOpenMask),
           info.dataLogicalSize, info.dataPhysicalSize >= info.dataLogicalSize, info.rsrcLogicalSize,
           info.rsrcPhysicalSize, info.valence);
    FSPermissionInfo *perm = (FSPermissionInfo *)&info.permissions;
    printf("perm owner %d group %d mode 0%o access 0x%x\n", perm->userID == getuid(), perm->groupID == st.st_gid,
           perm->mode, perm->userAccess);
    UInt64 mod = ((UInt64)info.contentModDate.highSeconds << 32) | info.contentModDate.lowSeconds;
    UInt64 cre = ((UInt64)info.createDate.highSeconds << 32) | info.createDate.lowSeconds;
    printf("dates content %d create %d backup %u/%u\n", mod == (UInt64)st.st_mtimespec.tv_sec + 2082844800ULL,
           cre == (UInt64)st.st_birthtimespec.tv_sec + 2082844800ULL, info.backupDate.highSeconds, info.backupDate.lowSeconds);
    printf("finder info %s ext %s\n", hex(info.finderInfo, 16).UTF8String, hex(info.extFinderInfo, 16).UTF8String);
    printf("sharing %d privileges 0x%x encoding %u\n", info.sharingFlags, info.userPrivileges, (unsigned)info.textEncodingHint);
    FileInfo *fi = (FileInfo *)info.finderInfo;
    fi->fileType = 'TEXT';
    fi->fileCreator = 'FnCh';
    fi->finderFlags = kHasBeenInited;
    printf("set finder info %d\n", FSSetCatalogInfo(&ref, kFSCatInfoFinderInfo, &info));
    memset(&info, 0, sizeof info);
    FSGetCatalogInfo(&ref, kFSCatInfoFinderInfo | kFSCatInfoNodeFlags, &info, NULL, NULL, NULL);
    printf("finder info %s\n", hex(info.finderInfo, 16).UTF8String);
    perm = (FSPermissionInfo *)&info.permissions;
    FSGetCatalogInfo(&ref, kFSCatInfoPermissions, &info, NULL, NULL, NULL);
    perm->mode = (perm->mode & ~0777) | 0600;
    printf("set perm %d", FSSetCatalogInfo(&ref, kFSCatInfoPermissions, &info));
    stat(file.fileSystemRepresentation, &st);
    printf(" mode 0%o\n", st.st_mode & 0777);
    memset(&info, 0, sizeof info);
    e = FSGetCatalogInfo(&dref, kFSCatInfoNodeFlags | kFSCatInfoValence | kFSCatInfoDataSizes, &info, &name, NULL, NULL);
    printf("dir catalog %d name %s flags 0x%x valence %u size %llu\n", e, uni(&name).UTF8String, info.nodeFlags,
           info.valence, info.dataLogicalSize);

    HFSUniStr255 fork;
    FSGetDataForkName(&fork);
    printf("data fork '%s'", uni(&fork).UTF8String);
    FSGetResourceForkName(&fork);
    printf(" resource fork '%s'\n", uni(&fork).UTF8String);
    FSIORefNum fref = 0;
    HFSUniStr255 dataFork;
    FSGetDataForkName(&dataFork);
    printf("open fork %d", FSOpenFork(&ref, dataFork.length, dataFork.unicode, fsRdWrPerm, &fref));
    SInt64 fsize = -1;
    printf(" size %d %lld", FSGetForkSize(fref, &fsize), fsize);
    char rbuf[32] = {0};
    ByteCount got = 0;
    printf(" read %d", FSReadFork(fref, fsFromStart, 6, 5, rbuf, &got));
    printf(" %lu '%s'", (unsigned long)got, rbuf);
    printf(" read past %d", FSReadFork(fref, fsFromStart, 8, 10, rbuf, &got));
    printf(" %lu", (unsigned long)got);
    SInt64 pos = 0;
    printf(" pos %d %lld", FSGetForkPosition(fref, &pos), pos);
    printf(" write %d", FSWriteFork(fref, fsFromStart, 0, 5, "HELLO", &got));
    printf(" set size %d", FSSetForkSize(fref, fsFromStart, 8));
    printf(" close %d\n", FSCloseFork(fref));
    printf("contents %s\n", [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil].UTF8String);
    printf("open rsrc fork %d\n", FSOpenFork(&ref, fork.length, fork.unicode, fsRdPerm, &fref));
    printf("close bad %d\n", FSCloseFork(30000));

    UniChar uname[] = {'n', 'e', 'w', '.', 't', 'x', 't'};
    FSRef created, made;
    printf("create %d", FSCreateFileUnicode(&dref, 7, uname, kFSCatInfoNone, NULL, &created, NULL));
    printf(" %s\n", rel(ref_path(&created)).UTF8String);
    printf("create again %d\n", FSCreateFileUnicode(&dref, 7, uname, kFSCatInfoNone, NULL, NULL, NULL));
    printf("make ref unicode %d", FSMakeFSRefUnicode(&dref, 7, uname, kTextEncodingUnknown, &made));
    printf(" same %d\n", FSCompareFSRefs(&made, &created));
    UniChar sub[] = {'s', 'u', 'b'};
    FSRef subdir;
    UInt32 newDirID = 0;
    printf("create dir %d", FSCreateDirectoryUnicode(&dref, 3, sub, kFSCatInfoNone, NULL, &subdir, NULL, &newDirID));
    printf(" %s id %d\n", rel(ref_path(&subdir)).UTF8String, newDirID != 0);
    FSRef moved;
    printf("move %d", FSMoveObject(&created, &subdir, &moved));
    printf(" %s\n", rel(ref_path(&moved)).UTF8String);
    UniChar rn[] = {'r', 'e', 'n', 'a', 'm', 'e', 'd'};
    FSRef renamed;
    printf("rename %d", FSRenameUnicode(&moved, 7, rn, kTextEncodingUnknown, &renamed));
    printf(" %s\n", rel(ref_path(&renamed)).UTF8String);
    printf("stale ref path %s\n", rel(ref_path(&moved)).UTF8String);
    FSIterator it;
    printf("iterator %d", FSOpenIterator(&dref, kFSIterateFlat, &it));
    ItemCount n = 0;
    FSCatalogInfo infos[10];
    FSRef refs[10];
    HFSUniStr255 names[10];
    e = FSGetCatalogInfoBulk(it, 10, &n, NULL, kFSCatInfoNodeFlags, infos, refs, NULL, names);
    NSMutableArray *found = [NSMutableArray array];
    for (ItemCount i = 0; i < n; i++)
        [found addObject:[NSString stringWithFormat:@"%@%s", uni(&names[i]), infos[i].nodeFlags & kFSNodeIsDirectoryMask ? "/" : ""]];
    [found sortUsingSelector:@selector(compare:)];
    printf(" bulk %d count %lu %s", e, (unsigned long)n, [found componentsJoinedByString:@","].UTF8String);
    e = FSGetCatalogInfoBulk(it, 10, &n, NULL, kFSCatInfoNone, NULL, NULL, NULL, NULL);
    printf(" again %d %lu close %d\n", e, (unsigned long)n, FSCloseIterator(it));
    printf("delete nonempty %d\n", FSDeleteObject(&subdir));
    printf("delete %d", FSDeleteObject(&renamed));
    printf(" %d\n", FSDeleteObject(&subdir));
    printf("delete again %d\n", FSDeleteObject(&renamed));

    FSRef folder;
    struct { short domain; OSType type; } folders[] = {
        {kUserDomain, kPreferencesFolderType}, {kUserDomain, kApplicationSupportFolderType},
        {kUserDomain, kDomainLibraryFolderType}, {kLocalDomain, kDomainLibraryFolderType},
        {kSystemDomain, kDomainLibraryFolderType}, {kUserDomain, kDesktopFolderType},
        {kUserDomain, kCurrentUserFolderType}, {kLocalDomain, kApplicationsFolderType},
        {kSystemDomain, kFontsFolderType}, {kUserDomain, 'zzzz'},
    };
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    for (size_t i = 0; i < sizeof folders / sizeof *folders; i++) {
        e = FSFindFolder(folders[i].domain, folders[i].type, kDontCreateFolder, &folder);
        NSString *path = e ? @"" : ref_path(&folder);
        if ([path hasPrefix:home])
            path = [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
        printf("folder %d %s: %d %s\n", folders[i].domain, ostype(folders[i].type), e, path.UTF8String);
    }

    AliasHandle alias = NULL;
    printf("alias %d", FSNewAlias(NULL, &ref, &alias));
    HFSUniStr255 target;
    CFStringRef apath = NULL;
    FSAliasInfoBitmap which = 0;
    FSAliasInfo ainfo;
    printf(" info %d", FSCopyAliasInfo(alias, &target, NULL, &apath, &which, &ainfo));
    printf(" target %s path %s\n", uni(&target).UTF8String, rel((__bridge NSString *)apath).UTF8String);
    if (apath)
        CFRelease(apath);
    FSRef resolved;
    Boolean changed = 9;
    printf("resolve %d changed %d", FSResolveAlias(NULL, alias, &resolved, &changed), changed);
    printf(" same %d\n", FSCompareFSRefs(&resolved, &ref));
    short count = 1;
    Boolean needsUpdate = 9;
    printf("match bulk %d count %d", FSMatchAliasBulk(NULL, kARMNoUI, alias, &count, &resolved, &needsUpdate, NULL, NULL), count);
    printf(" same %d\n", FSCompareFSRefs(&resolved, &ref));
    DisposeHandle((Handle)alias);
    Boolean isFolder = 9, aliased = 9;
    FSRef plain = ref;
    printf("resolve file %d folder %d aliased %d", FSResolveAliasFile(&plain, true, &isFolder, &aliased), isFolder, aliased);
    printf(" same %d\n", FSCompareFSRefs(&plain, &ref));
    printf("resolve file flags %d\n", FSResolveAliasFileWithMountFlags(&plain, true, &isFolder, &aliased, kResolveAliasFileNoUI));

    CFURLRef url = CFURLCreateFromFSRef(NULL, &ref);
    printf("url from ref %s\n", rel([(__bridge NSURL *)url path]).UTF8String);
    FSRef fromURL;
    printf("ref from url %d", CFURLGetFSRef(url, &fromURL));
    printf(" same %d\n", FSCompareFSRefs(&fromURL, &ref));
    CFRelease(url);
    url = CFURLCreateFromFSRef(NULL, &dref);
    printf("dir url %s directory %d\n", rel([(__bridge NSURL *)url path]).UTF8String, CFURLHasDirectoryPath(url));
    CFRelease(url);
    NSURL *nowhere = [NSURL fileURLWithPath:@"/nonexistent/finch"];
    printf("ref from missing url %d\n", CFURLGetFSRef((__bridge CFURLRef)nowhere, &fromURL));
    printf("ref from http url %d\n", CFURLGetFSRef((__bridge CFURLRef)[NSURL URLWithString:@"http://example.com/"], &fromURL));

    printf("== CarbonCore resources\n");
    NSString *rfile = [dir stringByAppendingPathComponent:@"test.rsrc"];
    [resource_file() writeToFile:rfile atomically:NO];
    FSRef rref;
    FSPathMakeRef((const UInt8 *)rfile.fileSystemRepresentation, &rref, NULL);
    printf("res load %d\n", LMGetResLoad());
    ResFileRefNum before = CurResFile();
    ResFileRefNum rf = -1;
    e = FSOpenResourceFile(&rref, dataFork.length, dataFork.unicode, fsRdPerm, &rf);
    printf("open %d valid %d current %d ResError %d\n", e, rf > 0, CurResFile() == rf, ResError());
    printf("count TEXT %d STR %d none %d types %d\n", Count1Resources('TEXT'), Count1Resources('STR '),
           Count1Resources('none'), Count1Types());
    ResType rt = 0;
    Get1IndType(&rt, 1);
    printf("type 1 %s", ostype(rt));
    Get1IndType(&rt, 2);
    printf(" type 2 %s\n", ostype(rt));
    Handle r1 = Get1Resource('TEXT', 128);
    show_res("TEXT 128", r1);
    printf("same handle again %d\n", Get1Resource('TEXT', 128) == r1);
    show_res("TEXT 129", Get1Resource('TEXT', 129));
    show_res("ind 2", Get1IndResource('TEXT', 2));
    show_res("ind 3", Get1IndResource('TEXT', 3));
    show_res("STR 200", GetResource('STR ', 200));
    Str255 nm = "\010Greeting";
    show_res("named", Get1NamedResource('TEXT', nm));
    show_res("missing", Get1Resource('TEXT', 999));
    printf("size on disk %ld max %ld\n", (long)GetResourceSizeOnDisk(r1), (long)GetMaxResourceSize(r1));
    printf("home %d\n", HomeResFile(r1) == rf);
    LMSetResLoad(false);
    Handle unloaded = Get1Resource('TEXT', 129);
    printf("unloaded master %d\n", unloaded && *unloaded == NULL);
    LMSetResLoad(true);
    if (unloaded) {
        LoadResource(unloaded);
        printf("loaded %d %.*s\n", ResError(), (int)GetHandleSize(unloaded), *unloaded);
    }
    DetachResource(r1);
    printf("detached %d still %.*s home %d\n", ResError(), (int)GetHandleSize(r1), *r1, HomeResFile(r1));
    DisposeHandle(r1);
    UseResFile(12345);
    printf("use bad %d current ok %d\n", ResError(), CurResFile() == rf);
    UseResFile(rf);
    Handle added = NULL;
    PtrToHand("added!", &added, 6);
    AddResource(added, 'NEW ', 300, (ConstStr255Param)"\003new");
    printf("add to read-only %d\n", ResError());
    CloseResFile(rf);
    printf("close %d current restored %d\n", ResError(), CurResFile() == before);
    show_res("after close", Get1Resource('TEXT', 128));

    rf = -1;
    e = FSOpenResourceFile(&rref, dataFork.length, dataFork.unicode, fsRdWrPerm, &rf);
    printf("open rw %d\n", e);
    AddResource(added, 'NEW ', 300, (ConstStr255Param)"\003new");
    printf("add %d count %d\n", ResError(), Count1Resources('NEW '));
    Handle w = Get1Resource('TEXT', 129);
    SetHandleSize(w, 3);
    memcpy(*w, "WOR", 3);
    ChangedResource(w);
    printf("changed %d\n", ResError());
    Handle gone = Get1Resource('STR ', 200);
    RemoveResource(gone);
    printf("remove %d count %d\n", ResError(), Count1Resources('STR '));
    DisposeHandle(gone);
    UpdateResFile(rf);
    printf("update %d\n", ResError());
    CloseResFile(rf);
    e = FSOpenResourceFile(&rref, dataFork.length, dataFork.unicode, fsRdPerm, &rf);
    printf("reopen %d types %d\n", e, Count1Types());
    show_res("NEW 300", Get1Resource('NEW ', 300));
    show_res("TEXT 129", Get1Resource('TEXT', 129));
    show_res("TEXT 128", Get1Resource('TEXT', 128));
    show_res("STR 200", Get1Resource('STR ', 200));
    CloseResFile(rf);
    printf("open text as resources %d\n", FSOpenResourceFile(&ref, dataFork.length, dataFork.unicode, fsRdPerm, &rf));
    printf("open missing rsrc fork %d\n", FSOpenResourceFile(&ref, fork.length, fork.unicode, fsRdPerm, &rf));
    printf("FSOpenResFile %d ResError %d\n", FSOpenResFile(&ref, fsRdPerm), ResError());
    NSString *newRes = [dir stringByAppendingPathComponent:@"new.rsrc"];
    UniChar nr[] = {'n', 'e', 'w', '.', 'r', 's', 'r', 'c'};
    FSRef newRef;
    e = FSCreateResourceFile(&dref, 8, nr, kFSCatInfoNone, NULL, dataFork.length, dataFork.unicode, &newRef, NULL);
    printf("create resource file %d size %lld\n", e,
           [[fm attributesOfItemAtPath:newRes error:nil] fileSize]);
    e = FSOpenResourceFile(&newRef, dataFork.length, dataFork.unicode, fsRdWrPerm, &rf);
    printf("open new %d types %d\n", e, Count1Types());
    CloseResFile(rf);

    printf("== CarbonCore misc\n");
    SInt32 v1 = 0, v2 = 0, v3 = 0, sv = 0, r = 0;
    Gestalt(gestaltSystemVersionMajor, &v1);
    Gestalt(gestaltSystemVersionMinor, &v2);
    Gestalt(gestaltSystemVersionBugFix, &v3);
    Gestalt(gestaltSystemVersion, &sv);
    printf("gestalt version consistent %d major>=26 %d\n", sv == ((v1 / 10) << 12 | (v1 % 10) << 8 | MIN(v2, 9) << 4 | MIN(v3, 9)), v1 >= 26);
    OSType sels[] = {'cpuf', 'sysa', 'vm  ', 'pgsz', 'os  ', 'alis', 'fs  ', 'thds', 'cfrg', 'rsrc', 'proc', 'zzzz'};
    for (size_t i = 0; i < sizeof sels / sizeof *sels; i++) {
        r = 0;
        e = Gestalt(sels[i], &r);
        printf("gestalt %s %d 0x%x\n", ostype(sels[i]), e, (unsigned)r);
    }
    printf("gestalt ram %d\n", Gestalt('ram ', &r) == 0 && r > 0);
    printf("fixmul %d fixratio %d\n", (int)FixMul(0x18000, 0x20000), (int)FixRatio(1, 4));
    extended80 x80;
    dtox80(&(double){3.25}, &x80);
    printf("x80 %s back %g\n", hex(&x80, 10).UTF8String, x80tod(&x80));
    CFStringRef user = CSCopyUserName(true), full = CSCopyUserName(false);
    printf("user name matches %d full %d\n", [(__bridge NSString *)user isEqual:NSUserName()],
           [(__bridge NSString *)full isEqual:NSFullUserName()]);
    CFRelease(user);
    CFRelease(full);
    printf("backup exclude %d\n", (int)CSBackupSetItemExcluded((__bridge CFURLRef)[NSURL fileURLWithPath:file], true, false));
    Boolean byPath = 9;
    printf("is excluded %d by path %d\n", CSBackupIsItemExcluded((__bridge CFURLRef)[NSURL fileURLWithPath:file], &byPath), byPath);
    UniChar a1[] = {'a', 'b', 'c'}, a2[] = {'A', 'B', 'D'};
    Boolean eq = 9;
    SInt32 order = 9;
    printf("compare %d", (int)UCCompareTextDefault(kUCCollateCaseInsensitiveMask, a1, 3, a2, 3, &eq, &order));
    printf(" eq %d order %d\n", eq, order < 0 ? -1 : order > 0);
    printf("compare equal %d", (int)UCCompareTextDefault(kUCCollateCaseInsensitiveMask, a1, 2, a2, 2, &eq, &order));
    printf(" eq %d order %d\n", eq, order < 0 ? -1 : order > 0);
    TextEncoding te = CreateTextEncoding(kTextEncodingMacRoman, kTextEncodingDefaultVariant, kTextEncodingDefaultFormat);
    TextEncoding te2 = 0;
    printf("text encoding 0x%x\n", (unsigned)te);
    GetTextEncodingFromScriptInfo(smJapanese, kTextLanguageDontCare, kTextRegionDontCare, &te2);
    printf("japanese 0x%x\n", (unsigned)te2);
    TextToUnicodeInfo tui;
    printf("ttu create %d", (int)CreateTextToUnicodeInfoByEncoding(te, &tui));
    UniChar ubuf[16];
    ByteCount read = 0, len = 0;
    e = ConvertFromTextToUnicode(tui, 4, "caf\x8e", 0, 0, NULL, NULL, NULL, sizeof ubuf, &read, &len, ubuf);
    printf(" convert %d read %lu len %lu %s", e, (unsigned long)read, (unsigned long)len,
           [NSString stringWithCharacters:ubuf length:len / 2].UTF8String);
    printf(" dispose %d\n", (int)DisposeTextToUnicodeInfo(&tui));
    ComponentInstance ci = OpenDefaultComponent('zzzz', 'zzzz');
    printf("component %d\n", ci != NULL);
    printf("pi %.6f\n", pi);
}

#pragma mark - UTType C API

static NSString *
cfs(CFTypeRef v)
{
    if (!v)
        return @"(null)";
    NSString *d = [(__bridge id)v isKindOfClass:[NSArray class]]
                      ? [NSString stringWithFormat:@"[%@]", [(__bridge NSArray *)v componentsJoinedByString:@","]]
                      : [(__bridge id)v description];
    CFRelease(v);
    return fixtureText(d);
}

static void
uttypes(void)
{
    printf("== UTType constants\n");
#define X(name) printf("%s %s\n", #name, [(__bridge NSString *)name UTF8String]);
#include "coreservices-uttypes.inc"
#undef X
    printf("== UTType functions\n");
    struct { CFStringRef tag, cls, conforming; } tags[] = {
        {CFSTR("txt"), kUTTagClassFilenameExtension, NULL}, {CFSTR("TXT"), kUTTagClassFilenameExtension, NULL},
        {CFSTR("jpg"), kUTTagClassFilenameExtension, NULL}, {CFSTR("html"), kUTTagClassFilenameExtension, kUTTypeText},
        {CFSTR("app"), kUTTagClassFilenameExtension, NULL}, {CFSTR("app"), kUTTagClassFilenameExtension, kUTTypeBundle},
        {CFSTR("zzqq"), kUTTagClassFilenameExtension, NULL}, {CFSTR("zzqq"), kUTTagClassFilenameExtension, kUTTypeText},
        {CFSTR("image/png"), kUTTagClassMIMEType, NULL}, {CFSTR("text/plain"), kUTTagClassMIMEType, NULL},
        {CFSTR("x-zz/qq"), kUTTagClassMIMEType, NULL}, {CFSTR("TEXT"), kUTTagClassOSType, NULL},
        {CFSTR("PDF "), kUTTagClassOSType, NULL}, {CFSTR("JPEG"), kUTTagClassOSType, NULL},
        {CFSTR("PNGf"), kUTTagClassOSType, NULL}, {CFSTR("APPL"), kUTTagClassOSType, NULL},
        {CFSTR("ZzQq"), kUTTagClassOSType, NULL}, {CFSTR("NSStringPboardType"), kUTTagClassNSPboardType, NULL},
        {CFSTR("NeXT TIFF v4.0 pasteboard type"), kUTTagClassNSPboardType, NULL},
        {CFSTR("x"), CFSTR("org.finch.tagclass"), NULL},
    };
    for (size_t i = 0; i < sizeof tags / sizeof *tags; i++) {
        printf("tag %s %s %s -> %s all %s\n", [(__bridge NSString *)tags[i].tag UTF8String],
               [(__bridge NSString *)tags[i].cls UTF8String], tags[i].conforming ? [(__bridge NSString *)tags[i].conforming UTF8String] : "-",
               cfs(UTTypeCreatePreferredIdentifierForTag(tags[i].cls, tags[i].tag, tags[i].conforming)).UTF8String,
               cfs(UTTypeCreateAllIdentifiersForTag(tags[i].cls, tags[i].tag, tags[i].conforming)).UTF8String);
    }
    CFStringRef types[] = {kUTTypePlainText, kUTTypeJPEG, kUTTypePNG, kUTTypeTIFF, kUTTypePDF, kUTTypeHTML,
                           kUTTypeApplicationBundle, kUTTypeFolder, kUTTypeData, kUTTypeUTF8PlainText,
                           kUTTypeQuickTimeMovie, kUTTypeMP3, CFSTR("public.zzqq"), CFSTR("dyn.ah62d4rv4ge81y8xvse")};
    CFStringRef classes[] = {kUTTagClassFilenameExtension, kUTTagClassMIMEType, kUTTagClassOSType, kUTTagClassNSPboardType};
    for (size_t i = 0; i < sizeof types / sizeof *types; i++) {
        printf("type %s desc '%s' declared %d dynamic %d\n", [(__bridge NSString *)types[i] UTF8String],
               cfs(UTTypeCopyDescription(types[i])).UTF8String, UTTypeIsDeclared(types[i]), UTTypeIsDynamic(types[i]));
        for (size_t j = 0; j < sizeof classes / sizeof *classes; j++)
            printf("  %s preferred %s all %s\n", [(__bridge NSString *)classes[j] UTF8String],
                   cfs(UTTypeCopyPreferredTagWithClass(types[i], classes[j])).UTF8String,
                   cfs(UTTypeCopyAllTagsWithClass(types[i], classes[j])).UTF8String);
        NSDictionary *decl = CFBridgingRelease(UTTypeCopyDeclaration(types[i]));
        id conforms = decl[(__bridge NSString *)kUTTypeConformsToKey];
        if ([conforms isKindOfClass:[NSString class]])
            conforms = @[ conforms ];
        printf("  declaration id %s conforms %s\n", [decl[(__bridge NSString *)kUTTypeIdentifierKey] UTF8String],
               [[conforms ?: @[] componentsJoinedByString:@","] UTF8String]);
    }
    struct { CFStringRef a, b; } pairs[] = {
        {kUTTypePlainText, kUTTypeText}, {kUTTypeText, kUTTypePlainText}, {kUTTypeJPEG, kUTTypeImage},
        {kUTTypeJPEG, kUTTypeData}, {kUTTypeJPEG, kUTTypeItem}, {kUTTypeApplicationBundle, kUTTypePackage},
        {kUTTypeApplicationBundle, kUTTypeApplication}, {kUTTypeFolder, kUTTypeDirectory}, {kUTTypeHTML, kUTTypeText},
        {CFSTR("PUBLIC.PLAIN-TEXT"), kUTTypeText}, {CFSTR("public.zzqq"), kUTTypeData},
        {CFSTR("dyn.ah62d4rv4ge81y8xvse"), kUTTypeData}, {kUTTypePlainText, kUTTypePlainText},
    };
    for (size_t i = 0; i < sizeof pairs / sizeof *pairs; i++)
        printf("conforms %s %s %d equal %d\n", [(__bridge NSString *)pairs[i].a UTF8String],
               [(__bridge NSString *)pairs[i].b UTF8String], UTTypeConformsTo(pairs[i].a, pairs[i].b),
               UTTypeEqual(pairs[i].a, pairs[i].b));
    printf("equal case %d\n", UTTypeEqual(CFSTR("Public.Plain-Text"), kUTTypePlainText));
    OSType codes[] = {'TEXT', 'APPL', 'ab c', 0, 0x01020304, '\'abc'};
    for (size_t i = 0; i < sizeof codes / sizeof *codes; i++) {
        CFStringRef str = UTCreateStringForOSType(codes[i]);
        printf("ostype %s -> '%s' -> %s\n", ostype(codes[i]), [(__bridge NSString *)str UTF8String],
               ostype(UTGetOSTypeFromString(str)));
        CFRelease(str);
    }
    NSString *bad[] = {@"", @"abc", @"abcde", @"ébcd", @"abé"};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++)
        printf("from string '%s' -> %s\n", bad[i].UTF8String, ostype(UTGetOSTypeFromString((__bridge CFStringRef)bad[i])));
    printf("declaring bundle of plain text %s\n", UTTypeCopyDeclaringBundleURL(kUTTypePlainText) ? "set" : "nil");
}

#pragma mark - LaunchServices


/* LaunchServices' private classes, as apps call them. */
@interface NSObject (FinchLaunchServicesSPI)
+ (id)defaultWorkspace;
- (BOOL)applicationIsInstalled:(NSString *)bundleID;
- (NSArray *)applicationsAvailableForOpeningURL:(NSURL *)url;
- (NSURL *)URLOverrideForURL:(NSURL *)url;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleID allowPlaceholder:(BOOL)allow error:(NSError **)error;
- (instancetype)initWithURL:(NSURL *)url allowPlaceholder:(BOOL)allow error:(NSError **)error;
+ (id)bundleRecordWithBundleIdentifier:(NSString *)bundleID allowPlaceholder:(BOOL)allow error:(NSError **)error;
+ (id)applicationProxyForIdentifier:(NSString *)bundleID;
- (id)objectForKey:(NSString *)key ofClass:(Class)cls;
- (NSString *)bundleIdentifier;
- (NSString *)localizedName;
- (NSURL *)URL;
- (NSURL *)bundleURL;
- (NSString *)shortVersionString;
- (NSString *)bundleVersion;
- (BOOL)isPlaceholder;
- (BOOL)isInstalled;
- (BOOL)isValid;
- (BOOL)isDeletable;
- (id)applicationState;
- (id)appState;
- (id)infoDictionary;
- (BOOL)isSensitive;
- (void)setSensitive:(BOOL)sensitive;
@end

static NSString *appPath, *docPath;

static NSString *
urls(CFArrayRef a)
{
    if (!a)
        return @"(null)";
    NSMutableArray *m = [NSMutableArray array];
    for (NSURL *u in (__bridge NSArray *)a)
        [m addObject:rel(u.path)];
    CFRelease(a);
    return [m componentsJoinedByString:@","];
}

static NSString *
url_str(CFURLRef u)
{
    if (!u)
        return @"(null)";
    NSString *s = rel([(__bridge NSURL *)u path]);
    CFRelease(u);
    return s;
}

static void
make_app(void)
{
    uint64_t hash = UINT64_C(14695981039346656037);
    const unsigned char *path = (const unsigned char *)scratch.fileSystemRepresentation;
    for (; *path; path++)
        hash = (hash ^ *path) * UINT64_C(1099511628211);
    NSString *suffix = [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
    testBundleID = [@"org.finch.test.coreservices." stringByAppendingString:suffix];
    testType = [@"org.finch.test.document." stringByAppendingString:suffix];
    testExtension = [@"fnchtst" stringByAppendingString:suffix];
    testMIME = [@"application/x-finch-test-" stringByAppendingString:suffix];
    testScheme = [@"finchcstest" stringByAppendingString:suffix];
    testAppName = [NSString stringWithFormat:@"FinchCSTest-%@.app", suffix];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *apps = [scratch stringByAppendingPathComponent:@"apps"];
    appPath = [apps stringByAppendingPathComponent:testAppName];
    [fm removeItemAtPath:apps error:nil];
    [fm createDirectoryAtPath:[appPath stringByAppendingPathComponent:@"Contents/MacOS"] withIntermediateDirectories:YES
                   attributes:nil error:nil];
    NSDictionary *info = @{
        @"CFBundleIdentifier" : testBundleID,
        @"CFBundleName" : @"FinchCSTest",
        @"CFBundleDisplayName" : @"Finch CS Test",
        @"CFBundleExecutable" : @"FinchCSTest",
        @"CFBundlePackageType" : @"APPL",
        @"CFBundleSignature" : @"FnCt",
        @"CFBundleShortVersionString" : @"1.2",
        @"CFBundleVersion" : @"34",
        @"CFBundleInfoDictionaryVersion" : @"6.0",
        @"LSMinimumSystemVersion" : @"11.0",
        @"LSUIElement" : @YES,
        @"CFBundleDocumentTypes" : @[ @{
            @"CFBundleTypeName" : @"Finch Test Document",
            @"CFBundleTypeRole" : @"Editor",
            @"LSHandlerRank" : @"Owner",
            @"LSItemContentTypes" : @[ testType ],
        } ],
        @"UTExportedTypeDeclarations" : @[ @{
            @"UTTypeIdentifier" : testType,
            @"UTTypeDescription" : @"Finch Test Document",
            @"UTTypeConformsTo" : @[ @"public.data", @"public.content" ],
            @"UTTypeTagSpecification" : @{
                @"public.filename-extension" : @[ testExtension ],
                @"public.mime-type" : testMIME,
            },
        } ],
        @"CFBundleURLTypes" : @[ @{@"CFBundleURLName" : @"Finch Test URL", @"CFBundleURLSchemes" : @[ testScheme ]} ],
    };
    [info writeToFile:[appPath stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:NO];
    [@"APPLFnCt" writeToFile:[appPath stringByAppendingPathComponent:@"Contents/PkgInfo"] atomically:NO
                    encoding:NSASCIIStringEncoding error:nil];
    char self_path[PATH_MAX];
    uint32_t n = sizeof self_path;
    _NSGetExecutablePath(self_path, &n);
    [fm copyItemAtPath:@(self_path) toPath:[appPath stringByAppendingPathComponent:@"Contents/MacOS/FinchCSTest"] error:nil];
    docPath = [scratch stringByAppendingPathComponent:[@"doc." stringByAppendingString:testExtension]];
    [@"finch" writeToFile:docPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

/* Waits (up to 10 s) for the test app to have been launched `count` times. */
static int
launches(int count)
{
    NSString *marker = [scratch stringByAppendingPathComponent:@"launched"];
    int n = 0;
    for (int i = 0; i < 200; i++) {
        n = (int)[[[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil]
            componentsSeparatedByString:@"\n"] count] - 1;
        if (n >= count)
            break;
        usleep(50000);
    }
    usleep(300000);  /* let it exit */
    return MAX(n, 0);
}

static void
launchservices(void)
{
    printf("== LaunchServices\n");
    make_app();
    NSURL *app = [NSURL fileURLWithPath:appPath], *doc = [NSURL fileURLWithPath:docPath];
    printf("register %d\n", (int)LSRegisterURL((__bridge CFURLRef)app, true));
    CFErrorRef err = NULL;
    printf("apps for id %s\n", urls(LSCopyApplicationURLsForBundleIdentifier((__bridge CFStringRef)testBundleID, &err)).UTF8String);
    CFArrayRef none = LSCopyApplicationURLsForBundleIdentifier(CFSTR("org.finch.no-such-app"), &err);
    printf("apps for missing %s err %ld %s\n", urls(none).UTF8String, err ? (long)CFErrorGetCode(err) : 0L,
           err ? [(__bridge NSString *)CFErrorGetDomain(err) UTF8String] : "");
    if (err)
        CFRelease(err);
    printf("type for ext %s\n", cfs(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)testExtension, NULL)).UTF8String);
    printf("type for mime %s\n", cfs(UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)testMIME, NULL)).UTF8String);
    printf("type desc %s conforms content %d\n", cfs(UTTypeCopyDescription((__bridge CFStringRef)testType)).UTF8String,
           UTTypeConformsTo((__bridge CFStringRef)testType, kUTTypeContent));
    printf("type ext %s declared %d\n", cfs(UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)testType, kUTTagClassFilenameExtension)).UTF8String,
           UTTypeIsDeclared((__bridge CFStringRef)testType));
    printf("default for type %s\n", url_str(LSCopyDefaultApplicationURLForContentType((__bridge CFStringRef)testType, kLSRolesAll, NULL)).UTF8String);
    printf("default for doc %s\n", url_str(LSCopyDefaultApplicationURLForURL((__bridge CFURLRef)doc, kLSRolesAll, NULL)).UTF8String);
    printf("default for scheme url %s\n", url_str(LSCopyDefaultApplicationURLForURL((__bridge CFURLRef)[NSURL URLWithString:[testScheme stringByAppendingString:@"://x"]], kLSRolesAll, NULL)).UTF8String);
    CFErrorRef derr = NULL;
    CFURLRef nobody = LSCopyDefaultApplicationURLForContentType(CFSTR("org.finch.no-such-type"), kLSRolesAll, &derr);
    printf("default for unknown %s err %ld\n", url_str(nobody).UTF8String, derr ? (long)CFErrorGetCode(derr) : 0L);
    if (derr)
        CFRelease(derr);
    printf("apps for doc %s\n", urls(LSCopyApplicationURLsForURL((__bridge CFURLRef)doc, kLSRolesAll)).UTF8String);
    printf("handlers for type %s\n", cfs(LSCopyAllRoleHandlersForContentType((__bridge CFStringRef)testType, kLSRolesAll)).UTF8String);
    printf("default handler for type %s\n", cfs(LSCopyDefaultRoleHandlerForContentType((__bridge CFStringRef)testType, kLSRolesAll)).UTF8String);
    printf("handler for scheme %s\n", cfs(LSCopyDefaultHandlerForURLScheme((__bridge CFStringRef)testScheme)).UTF8String);
    printf("handlers for scheme %s\n", cfs(LSCopyAllHandlersForURLScheme((__bridge CFStringRef)testScheme)).UTF8String);
    printf("handler for unknown scheme %s\n", cfs(LSCopyDefaultHandlerForURLScheme(CFSTR("finchnoscheme"))).UTF8String);
    Boolean accepts = 9;
    printf("can accept %d", (int)LSCanURLAcceptURL((__bridge CFURLRef)doc, (__bridge CFURLRef)app, kLSRolesAll, kLSAcceptDefault, &accepts));
    printf(" %d\n", accepts);
    NSURL *text = [NSURL fileURLWithPath:[scratch stringByAppendingPathComponent:@"files/test.txt"]];
    printf("can accept text %d", (int)LSCanURLAcceptURL((__bridge CFURLRef)text, (__bridge CFURLRef)app, kLSRolesAll, kLSAcceptDefault, &accepts));
    printf(" %d\n", accepts);
    LSItemInfoRecord info;
    memset(&info, 0, sizeof info);
    printf("item info app %d", (int)LSCopyItemInfoForURL((__bridge CFURLRef)app, kLSRequestAllInfo, &info));
    printf(" flags 0x%x type %s creator %s ext %s\n", (unsigned)info.flags, ostype(info.filetype), ostype(info.creator),
           cfs(info.extension).UTF8String);
    memset(&info, 0, sizeof info);
    printf("item info doc %d", (int)LSCopyItemInfoForURL((__bridge CFURLRef)doc, kLSRequestAllInfo, &info));
    printf(" flags 0x%x ext %s\n", (unsigned)info.flags, cfs(info.extension).UTF8String);
    memset(&info, 0, sizeof info);
    printf("item info dir %d", (int)LSCopyItemInfoForURL((__bridge CFURLRef)[NSURL fileURLWithPath:scratch], kLSRequestBasicFlagsOnly, &info));
    printf(" flags 0x%x\n", (unsigned)info.flags);
    CFURLRef found = NULL;
    printf("find by id %d", (int)LSFindApplicationForInfo(kLSUnknownCreator, (__bridge CFStringRef)testBundleID, NULL, NULL, &found));
    printf(" %s\n", url_str(found).UTF8String);
    found = NULL;
    printf("find by name %d", (int)LSFindApplicationForInfo(kLSUnknownCreator, NULL, (__bridge CFStringRef)testAppName, NULL, &found));
    printf(" %s\n", url_str(found).UTF8String);
    found = NULL;
    printf("find missing %d\n", (int)LSFindApplicationForInfo(kLSUnknownCreator, CFSTR("org.finch.no-such-app"), NULL, NULL, &found));
    found = NULL;
    printf("get for url %d", (int)LSGetApplicationForURL((__bridge CFURLRef)doc, kLSRolesAll, NULL, &found));
    printf(" %s\n", url_str(found).UTF8String);
    found = NULL;
    printf("get for info %d", (int)LSGetApplicationForInfo(kLSUnknownType, kLSUnknownCreator, (__bridge CFStringRef)testExtension, kLSRolesAll, NULL, &found));
    printf(" %s\n", url_str(found).UTF8String);
    FSRef docRef, appRef;
    FSPathMakeRef((const UInt8 *)docPath.fileSystemRepresentation, &docRef, NULL);
    printf("get for ref %d", (int)LSGetApplicationForItem(&docRef, kLSRolesAll, &appRef, NULL));
    printf(" %s\n", rel(ref_path(&appRef)).UTF8String);
    CFStringRef kind = NULL;
    printf("kind %d", (int)LSCopyKindStringForURL((__bridge CFURLRef)doc, &kind));
    printf(" %s\n", cfs(kind).UTF8String);

    printf("== LaunchServices opening\n");
    NSString *marker = [scratch stringByAppendingPathComponent:@"launched"];
    [[NSFileManager defaultManager] removeItemAtPath:marker error:nil];
    CFURLRef launched = NULL;
    printf("open app %d", (int)LSOpenCFURLRef((__bridge CFURLRef)app, &launched));
    printf(" launched %s count %d\n", url_str(launched).UTF8String, launches(1));
    launched = NULL;
    printf("open doc %d", (int)LSOpenCFURLRef((__bridge CFURLRef)doc, &launched));
    printf(" launched %s count %d\n", url_str(launched).UTF8String, launches(2));
    LSLaunchURLSpec spec = {0};
    spec.appURL = (__bridge CFURLRef)app;
    spec.itemURLs = (__bridge CFArrayRef) @[ doc ];
    spec.launchFlags = kLSLaunchDefaults | kLSLaunchDontSwitch;
    launched = NULL;
    printf("open spec %d", (int)LSOpenFromURLSpec(&spec, &launched));
    printf(" launched %s count %d\n", url_str(launched).UTF8String, launches(3));
    launched = NULL;
    printf("open scheme %d", (int)LSOpenCFURLRef((__bridge CFURLRef)[NSURL URLWithString:[testScheme stringByAppendingString:@"://hello"]], &launched));
    printf(" launched %s count %d\n", url_str(launched).UTF8String, launches(4));
    launched = NULL;
    printf("open unknown scheme %d\n", (int)LSOpenCFURLRef((__bridge CFURLRef)[NSURL URLWithString:@"finchnoscheme://x"], &launched));
    printf("open missing file %d\n", (int)LSOpenCFURLRef((__bridge CFURLRef)[NSURL fileURLWithPath:@"/nonexistent/finch.fnchtst"], NULL));
    NSString *unknown = [scratch stringByAppendingPathComponent:@"thing.zzqqx"];
    [@"?" writeToFile:unknown atomically:NO encoding:NSUTF8StringEncoding error:nil];
    printf("open unclaimed %d\n", (int)LSOpenCFURLRef((__bridge CFURLRef)[NSURL fileURLWithPath:unknown], NULL));

    printf("== LaunchServices classes\n");
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    id w = [ws defaultWorkspace];
    printf("workspace %d same %d\n", w != nil, w == [ws defaultWorkspace]);
    printf("installed %d missing %d\n", [w applicationIsInstalled:testBundleID],
           [w applicationIsInstalled:@"org.finch.no-such-app"]);
    NSMutableArray *ids = [NSMutableArray array];
    for (id proxy in [w applicationsAvailableForOpeningURL:doc])
        [ids addObject:[proxy bundleIdentifier] ?: @"?"];
    printf("available for doc %s\n", fixtureText([ids componentsJoinedByString:@","]).UTF8String);
    printf("override %s\n", [w URLOverrideForURL:[NSURL URLWithString:@"http://example.com/"]].absoluteString.UTF8String);
    Class recCls = NSClassFromString(@"LSApplicationRecord");
    NSError *rerr = nil;
    id rec = [[recCls alloc] initWithBundleIdentifier:testBundleID allowPlaceholder:NO error:&rerr];
    printf("record %d bundle %s name %s url %s\n", rec != nil, fixtureText([rec bundleIdentifier]).UTF8String, fixtureText([rec localizedName]).UTF8String,
           rel([rec URL].path).UTF8String);
    printf("record version %s build %s placeholder %d\n", [rec shortVersionString].UTF8String, [rec bundleVersion].UTF8String,
           [rec isPlaceholder]);
    id state = [rec applicationState];
    printf("state installed %d valid %d placeholder %d\n", [state isInstalled], [state isValid], [state isPlaceholder]);
    id infoDict = [rec infoDictionary];
    printf("info signature %s wrong class %s\n", [[infoDict objectForKey:@"CFBundleSignature" ofClass:[NSString class]] UTF8String],
           [[[infoDict objectForKey:@"CFBundleSignature" ofClass:[NSNumber class]] description] UTF8String]);
    printf("deletable %d\n", [rec isDeletable]);
    rerr = nil;
    id missing = [[recCls alloc] initWithBundleIdentifier:@"org.finch.no-such-app" allowPlaceholder:NO error:&rerr];
    printf("missing record %d error %s %ld\n", missing != nil, rerr.domain.UTF8String ?: "", (long)rerr.code);
    id byURL = [[recCls alloc] initWithURL:app allowPlaceholder:NO error:&rerr];
    printf("record by url %s\n", fixtureText([byURL bundleIdentifier]).UTF8String);
    Class bundleCls = NSClassFromString(@"LSBundleRecord");
    id brec = [bundleCls bundleRecordWithBundleIdentifier:testBundleID allowPlaceholder:NO error:&rerr];
    printf("bundle record %s kind %d\n", fixtureText([brec bundleIdentifier]).UTF8String, [brec isKindOfClass:recCls]);
    printf("record subclass of bundle record %d\n", [recCls isSubclassOfClass:bundleCls]);
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    id proxy = [proxyCls applicationProxyForIdentifier:testBundleID];
    printf("proxy %s url %s name %s version %s\n", fixtureText([proxy bundleIdentifier]).UTF8String, rel([proxy bundleURL].path).UTF8String,
           fixtureText([proxy localizedName]).UTF8String, [proxy shortVersionString].UTF8String);
    printf("proxy state installed %d\n", [[proxy appState] isInstalled]);
    id ghost = [proxyCls applicationProxyForIdentifier:@"org.finch.no-such-app"];
    printf("missing proxy %d installed %d\n", ghost != nil, [[ghost appState] isInstalled]);
    id cfg = [[NSClassFromString(@"_LSOpenConfiguration") alloc] init];
    printf("open configuration %d sensitive %d\n", cfg != nil, [cfg isSensitive]);
    [cfg setSensitive:YES];
    printf("set sensitive %d\n", [cfg isSensitive]);
    if (testPrivateLaunch) {
        printf("open with bundle id %d", [w openApplicationWithBundleID:testBundleID]);
        printf(" count %d\n", launches(5));
    }
    printf("open missing bundle id %d\n", [w openApplicationWithBundleID:@"org.finch.no-such-app"]);
}

#pragma mark - Metadata, FSEvents, recent items

static void
metadata(void)
{
    printf("== Metadata\n");
    NSString *file = [scratch stringByAppendingPathComponent:@"files/test.txt"];
    MDItemRef item = MDItemCreateWithURL(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:file]);
    printf("item %d\n", item != NULL);
    struct stat st;
    stat(file.fileSystemRepresentation, &st);
    CFStringRef keys[] = {kMDItemContentType, kMDItemDisplayName, kMDItemFSName, kMDItemKind, kMDItemContentTypeTree,
                          kMDItemFSSize, kMDItemFSIsReadable, kMDItemFSIsWriteable, kMDItemFSOwnerUserID,
                          kMDItemFSInvisible, kMDItemFSNodeCount, kMDItemFSLabel, kMDItemFSIsExtensionHidden};
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        id v = CFBridgingRelease(MDItemCopyAttribute(item, keys[i]));
        NSString *d = [v isKindOfClass:[NSArray class]] ? [v componentsJoinedByString:@","] : [v description];
        if (keys[i] == kMDItemFSOwnerUserID)
            d = [v intValue] == (int)getuid() ? @"me" : d;
        printf("%s: %s\n", [(__bridge NSString *)keys[i] UTF8String], d.UTF8String ?: "(null)");
    }
    NSDate *mod = CFBridgingRelease(MDItemCopyAttribute(item, kMDItemFSContentChangeDate));
    NSDate *cre = CFBridgingRelease(MDItemCopyAttribute(item, kMDItemFSCreationDate));
    printf("dates content %d creation %d\n", (long)mod.timeIntervalSince1970 == st.st_mtimespec.tv_sec,
           (long)cre.timeIntervalSince1970 == st.st_birthtimespec.tv_sec);
    NSString *path = CFBridgingRelease(MDItemCopyAttribute(item, kMDItemPath));
    printf("path %s\n", rel(path).UTF8String);
    NSDictionary *several = CFBridgingRelease(MDItemCopyAttributes(item, (__bridge CFArrayRef) @[ (__bridge id)kMDItemFSName, (__bridge id)kMDItemContentType ]));
    printf("attributes %s %s\n", [several[(__bridge id)kMDItemFSName] UTF8String], [several[(__bridge id)kMDItemContentType] UTF8String]);
    CFRelease(item);
    MDItemRef dir = MDItemCreate(NULL, (__bridge CFStringRef)[scratch stringByAppendingPathComponent:@"files"]);
    printf("dir type %s count %s\n", [CFBridgingRelease(MDItemCopyAttribute(dir, kMDItemContentType)) UTF8String],
           [[CFBridgingRelease(MDItemCopyAttribute(dir, kMDItemFSNodeCount)) description] UTF8String]);
    CFRelease(dir);
    MDItemRef app = MDItemCreate(NULL, (__bridge CFStringRef)appPath);
    printf("app type %s id %s\n", [CFBridgingRelease(MDItemCopyAttribute(app, kMDItemContentType)) UTF8String],
           [fixtureText(CFBridgingRelease(MDItemCopyAttribute(app, kMDItemCFBundleIdentifier))) UTF8String]);
    CFRelease(app);
    printf("missing item %d\n", MDItemCreate(NULL, CFSTR("/nonexistent/finch")) != NULL);
    printf("key strings %s %s\n", [(__bridge NSString *)kMDItemTitle UTF8String], [(__bridge NSString *)kMDItemDateAdded UTF8String]);

    printf("== FSEvents\n");
    FSEventStreamContext ctx = {0};
    FSEventStreamRef stream = FSEventStreamCreate(NULL, (FSEventStreamCallback)(void *)printf, &ctx,
                                                  (__bridge CFArrayRef) @[ scratch ], kFSEventStreamEventIdSinceNow, 1.0,
                                                  kFSEventStreamCreateFlagNone);
    printf("stream %d\n", stream != NULL);
    NSArray *watched = CFBridgingRelease(FSEventStreamCopyPathsBeingWatched(stream));
    printf("watching %s\n", rel(watched.firstObject).UTF8String);
    printf("start unscheduled %d\n", FSEventStreamStart(stream));
    FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    printf("start %d latest>0 %d\n", FSEventStreamStart(stream), FSEventStreamGetLatestEventId(stream) > 0);
    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    printf("current id>0 %d\n", FSEventsGetCurrentEventId() > 0);
    printf("empty paths %d\n", FSEventStreamCreate(NULL, (FSEventStreamCallback)(void *)printf, &ctx,
                                                   (__bridge CFArrayRef) @[], kFSEventStreamEventIdSinceNow, 1.0, 0) != NULL);

    printf("== Shared file lists\n");
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListRecentDocumentItems, NULL);
    printf("recent documents %d\n", list != NULL);
    if (list) {
        CFTypeRef max = LSSharedFileListCopyProperty(list, CFSTR("maxAmount"));
        printf("max amount property %s\n", max ? "set" : "nil");
        if (max)
            CFRelease(max);
        CFRelease(list);
    }
}

#pragma mark - Foundation's Apple event classes

static void
show_ns(const char *label, NSAppleEventDescriptor *d)
{
    printf("%s: %s type %s items %ld record %d\n", label, d.description.UTF8String, ostype(d.descriptorType),
           (long)d.numberOfItems, d.isRecordDescriptor);
}

@interface Handler : NSObject
@end
@implementation Handler
- (void)handle:(NSAppleEventDescriptor *)event withReply:(NSAppleEventDescriptor *)reply
{
    NSAppleEventManager *m = [NSAppleEventManager sharedAppleEventManager];
    printf("  handler class %s id %s direct %s current %d reply %d\n", ostype(event.eventClass), ostype(event.eventID),
           [event paramDescriptorForKeyword:keyDirectObject].stringValue.UTF8String,
           [m.currentAppleEvent isEqual:event] || m.currentAppleEvent.eventID == event.eventID,
           m.currentReplyAppleEvent != nil);
    [reply setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:@"done"] forKeyword:keyDirectObject];
}
@end

static void
foundation_ae(void)
{
    printf("== NSAppleEventDescriptor\n");
    show_ns("null", [NSAppleEventDescriptor nullDescriptor]);
    show_ns("bool", [NSAppleEventDescriptor descriptorWithBoolean:YES]);
    show_ns("enum", [NSAppleEventDescriptor descriptorWithEnumCode:'yes ']);
    show_ns("int", [NSAppleEventDescriptor descriptorWithInt32:-12]);
    show_ns("double", [NSAppleEventDescriptor descriptorWithDouble:2.5]);
    show_ns("type", [NSAppleEventDescriptor descriptorWithTypeCode:'abcd']);
    show_ns("string", [NSAppleEventDescriptor descriptorWithString:@"héllo"]);
    show_ns("url", [NSAppleEventDescriptor descriptorWithFileURL:[NSURL fileURLWithPath:@"/tmp/a b"]]);
    show_ns("bytes", [NSAppleEventDescriptor descriptorWithDescriptorType:'cust' bytes:"\x01\x02" length:2]);
    show_ns("data", [NSAppleEventDescriptor descriptorWithDescriptorType:typeUTF8Text data:[@"xyz" dataUsingEncoding:NSUTF8StringEncoding]]);
    show_ns("pid", [NSAppleEventDescriptor descriptorWithProcessIdentifier:1]);
    show_ns("bundle", [NSAppleEventDescriptor descriptorWithBundleIdentifier:@"com.example.app"]);
    show_ns("app url", [NSAppleEventDescriptor descriptorWithApplicationURL:[NSURL fileURLWithPath:@"/Applications/X.app"]]);
    show_ns("current", [NSAppleEventDescriptor currentProcessDescriptor]);
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1000000000];
    NSAppleEventDescriptor *dd = [NSAppleEventDescriptor descriptorWithDate:date];
    printf("date type %s back %d\n", ostype(dd.descriptorType), [dd.dateValue isEqual:date]);
    NSAppleEventDescriptor *i = [NSAppleEventDescriptor descriptorWithInt32:42];
    printf("values int %d double %g bool %d string %s enum %s type %s data %s\n", i.int32Value, i.doubleValue, i.booleanValue,
           i.stringValue.UTF8String, ostype(i.enumCodeValue), ostype(i.typeCodeValue), hex(i.data.bytes, i.data.length).UTF8String);
    NSAppleEventDescriptor *str = [NSAppleEventDescriptor descriptorWithString:@"17"];
    printf("string values int %d double %g bool %d url %s\n", str.int32Value, str.doubleValue, str.booleanValue,
           str.fileURLValue.absoluteString.UTF8String);
    NSAppleEventDescriptor *t = [NSAppleEventDescriptor descriptorWithString:@"true"];
    printf("true string bool %d\n", t.booleanValue);
    NSAppleEventDescriptor *u = [NSAppleEventDescriptor descriptorWithFileURL:[NSURL fileURLWithPath:@"/tmp/a b"]];
    printf("url value %s string %s\n", u.fileURLValue.absoluteString.UTF8String, u.stringValue.UTF8String);
    NSAppleEventDescriptor *coerced = [i coerceToDescriptorType:typeUnicodeText];
    show_ns("coerced", coerced);
    show_ns("bad coerce", [[NSAppleEventDescriptor descriptorWithString:@"x"] coerceToDescriptorType:typeSInt32]);
    NSAppleEventDescriptor *copy = [i copy];
    printf("copy equal %d same %d hash %d\n", [copy isEqual:i], copy == i, copy.hash == i.hash);

    NSAppleEventDescriptor *list = [NSAppleEventDescriptor listDescriptor];
    [list insertDescriptor:[NSAppleEventDescriptor descriptorWithInt32:1] atIndex:0];
    [list insertDescriptor:[NSAppleEventDescriptor descriptorWithString:@"two"] atIndex:2];
    [list insertDescriptor:[NSAppleEventDescriptor descriptorWithInt32:0] atIndex:1];
    show_ns("list", list);
    printf("list item 2 %s key %s item 9 %s\n", [list descriptorAtIndex:2].description.UTF8String,
           ostype([list keywordForDescriptorAtIndex:2]), [list descriptorAtIndex:9].description.UTF8String);
    [list removeDescriptorAtIndex:1];
    show_ns("after remove", list);
    NSAppleEventDescriptor *rec = [NSAppleEventDescriptor recordDescriptor];
    [rec setDescriptor:[NSAppleEventDescriptor descriptorWithInt32:5] forKeyword:'abcd'];
    [rec setDescriptor:[NSAppleEventDescriptor descriptorWithString:@"v"] forKeyword:'efgh'];
    [rec setDescriptor:[NSAppleEventDescriptor descriptorWithInt32:6] forKeyword:'abcd'];
    show_ns("record", rec);
    printf("record key 2 %s value %s missing %s\n", ostype([rec keywordForDescriptorAtIndex:2]),
           [rec descriptorForKeyword:'abcd'].description.UTF8String, [rec descriptorForKeyword:'zzzz'].description.UTF8String);
    [rec removeDescriptorWithKeyword:'abcd'];
    show_ns("after remove", rec);

    NSAppleEventDescriptor *target = [NSAppleEventDescriptor currentProcessDescriptor];
    NSAppleEventDescriptor *ev = [NSAppleEventDescriptor appleEventWithEventClass:'fnch' eventID:'nsae' targetDescriptor:target
                                                                         returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    [ev setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:@"payload"] forKeyword:keyDirectObject];
    [ev setAttributeDescriptor:[NSAppleEventDescriptor descriptorWithInt32:3] forKeyword:'xatr'];
    show_ns("event", ev);
    printf("event class %s id %s transaction %d return nonzero %d attr %s target %s\n", ostype(ev.eventClass), ostype(ev.eventID),
           ev.transactionID, ev.returnID != 0, [ev attributeDescriptorForKeyword:'xatr'].description.UTF8String,
           [ev attributeDescriptorForKeyword:keyAddressAttr].description.UTF8String);
    [ev removeParamDescriptorWithKeyword:'nope'];
    printf("param %s\n", [ev paramDescriptorForKeyword:keyDirectObject].stringValue.UTF8String);
    AEDesc ownedCopy;
    AEDuplicateDesc(ev.aeDesc, &ownedCopy);
    NSAppleEventDescriptor *wrapped = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&ownedCopy];
    printf("aeDesc type %s\n", ostype(ev.aeDesc->descriptorType));
    (void)wrapped;

    printf("== NSAppleEventManager\n");
    NSAppleEventManager *m = [NSAppleEventManager sharedAppleEventManager];
    Handler *h = [Handler new];
    [m setEventHandler:h andSelector:@selector(handle:withReply:) forEventClass:'fnch' andEventID:'nsae'];
    AEEventHandlerUPP proc = NULL;
    SRefCon rc = 0;
    printf("installed with AE %d\n", AEGetEventHandler('fnch', 'nsae', &proc, &rc, false));
    NSError *error = nil;
    NSAppleEventDescriptor *reply = [ev sendEventWithOptions:NSAppleEventSendDefaultOptions timeout:10 error:&error];
    printf("send %d reply %s error %ld\n", reply != nil, [reply paramDescriptorForKeyword:keyDirectObject].stringValue.UTF8String,
           (long)error.code);
    AppleEvent raw, rawReply;
    AEDuplicateDesc(ev.aeDesc, &raw);
    AEInitializeDesc(&rawReply);
    AECreateAppleEvent(kCoreEventClass, kAEAnswer, ev.aeDesc, kAutoGenerateReturnID, kAnyTransactionID, &rawReply);
    printf("dispatch raw %d\n", [m dispatchRawAppleEvent:&raw withRawReply:&rawReply handlerRefCon:rc]);
    AEDisposeDesc(&raw);
    AEDisposeDesc(&rawReply);
    printf("current outside %d\n", m.currentAppleEvent != nil);
    [m removeEventHandlerForEventClass:'fnch' andEventID:'nsae'];
    printf("removed from AE %d\n", AEGetEventHandler('fnch', 'nsae', &proc, &rc, false));
    error = nil;
    reply = [ev sendEventWithOptions:NSAppleEventSendDefaultOptions timeout:10 error:&error];
    printf("send unhandled %d error %s %ld\n", reply != nil, error.domain.UTF8String, (long)error.code);
    NSAppleEventDescriptor *far = [NSAppleEventDescriptor appleEventWithEventClass:'fnch' eventID:'nsae'
        targetDescriptor:[NSAppleEventDescriptor descriptorWithBundleIdentifier:@"org.finch.no-such-app"]
        returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    error = nil;
    reply = [far sendEventWithOptions:NSAppleEventSendDefaultOptions timeout:10 error:&error];
    printf("send to missing app %d error %s %ld\n", reply != nil, error.domain.UTF8String, (long)error.code);
}

static void
user_activity(void)
{
    printf("== NSUserActivity\n");
    Class cls = NSClassFromString(@"NSUserActivity");
    NSUserActivity *a = [[cls alloc] initWithActivityType:@"org.finch.test.activity"];
    a.title = @"Title";
    a.userInfo = @{@"k" : @"v"};
    [a addUserInfoEntriesFromDictionary:@{@"n" : @1}];
    a.requiredUserInfoKeys = [NSSet setWithObject:@"k"];
    a.keywords = [NSSet setWithObjects:@"b", @"a", nil];
    a.eligibleForSearch = YES;
    a.needsSave = YES;
    a.webpageURL = [NSURL URLWithString:@"https://example.com/"];
    printf("type %s title %s info %ld keys %ld keywords %ld search %d handoff %d public %d save %d url %s\n",
           a.activityType.UTF8String, a.title.UTF8String, (long)a.userInfo.count, (long)a.requiredUserInfoKeys.count,
           (long)a.keywords.count, a.eligibleForSearch, a.eligibleForHandoff, a.eligibleForPublicIndexing, a.needsSave,
           a.webpageURL.absoluteString.UTF8String);
    [a becomeCurrent];
    [a resignCurrent];
    [a invalidate];
    printf("invalidated\n");
}

int
main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (strstr(argv[0], "/Contents/MacOS/FinchCSTest")) {
        /* launched as the test app: note it and leave */
        NSString *app = [[[@(argv[0]) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString *marker = [[[app stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"launched"];
        FILE *f = fopen(marker.fileSystemRepresentation, "a");
        if (f) {
            fprintf(f, "launched\n");
            fclose(f);
        }
        return 0;
    }
    @autoreleasepool {
        Dl_info info;
        dladdr((void *)AECreateDesc, &info);
        printf("%s\n", info.dli_fname);
        scratch = argc > 1 ? @(argv[1]) : @"/tmp/finch-coreservices-test";
        testPrivateLaunch = argc > 2 && !strcmp(argv[2], "--private-launch");
        [[NSFileManager defaultManager] createDirectoryAtPath:scratch withIntermediateDirectories:YES attributes:nil error:nil];
        ae_descriptors();
        ae_lists();
        ae_coercions();
        ae_events();
        ae_objects();
        carboncore();
        uttypes();
        launchservices();
        metadata();
        foundation_ae();
        user_activity();
    }
    return 0;
}
