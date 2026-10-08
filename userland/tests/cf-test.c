/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cf-test: CoreFoundation behaviour, printed one result per line so a
 * run against Apple's CoreFoundation (on the host) and a run against Finch's
 * (in the VM) can be compared line for line. Nothing printed depends on
 * addresses, the clock or the machine. The first line names the
 * CoreFoundation that's loaded; `finch-cf-test --no-path` leaves it out, for
 * diffing.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <xpc/xpc.h>

/* <CoreFoundation/CFXPCBridge.h> (private) */
xpc_object_t _CFXPCCreateXPCObjectFromCFObject(CFTypeRef);
CFTypeRef _CFXPCCreateCFObjectFromXPCObject(xpc_object_t);
xpc_object_t _CFXPCCreateXPCMessageWithCFObject(CFTypeRef);
CFTypeRef _CFXPCCreateCFObjectFromXPCMessage(xpc_object_t);
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int failures;

static void
put(const char *label, CFStringRef s)
{
	char buf[1024] = "(null)";
	if (s) CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
	printf("%s: %s\n", label, buf);
}

static void
check(const char *label, bool ok)
{
	printf("%s: %s\n", label, ok ? "ok" : "FAILED");
	failures += !ok;
}

static void
hex(const char *label, CFDataRef d)
{
	printf("%s: %ld bytes ", label, d ? CFDataGetLength(d) : -1L);
	unsigned h = 2166136261u;   /* FNV-1a of the bytes */
	for (CFIndex i = 0; d && i < CFDataGetLength(d); i++) h = (h ^ CFDataGetBytePtr(d)[i]) * 16777619u;
	printf("fnv %08x\n", h);
}

static void
strings(void)
{
	CFMutableStringRef m = CFStringCreateMutable(NULL, 0);
	CFStringAppend(m, CFSTR("Hello, "));
	CFStringAppendFormat(m, NULL, CFSTR("%@ %d %.3f %s"), CFSTR("wörld"), 42, 3.14159, "c-string");
	put("format", m);
	CFStringUppercase(m, NULL);
	put("uppercase", m);
	printf("length: %ld\n", CFStringGetLength(m));
	CFRange r = CFStringFind(m, CFSTR("WÖRLD"), 0);
	printf("find: %ld %ld\n", r.location, r.length);
	printf("compare ci: %ld\n", (long)CFStringCompare(CFSTR("Straße"), CFSTR("STRASSE"), kCFCompareCaseInsensitive));
	printf("compare numeric: %ld\n", (long)CFStringCompare(CFSTR("file10"), CFSTR("file9"), kCFCompareNumerically));
	CFArrayRef parts = CFStringCreateArrayBySeparatingStrings(NULL, CFSTR("a,b,,c"), CFSTR(","));
	printf("split: %ld\n", CFArrayGetCount(parts));
	put("join", CFStringCreateByCombiningStrings(NULL, parts, CFSTR("|")));
	CFMutableStringRef t = CFStringCreateMutableCopy(NULL, 0, CFSTR("Ærøskøbing café"));
	CFStringTransform(t, NULL, kCFStringTransformToLatin, false);
	CFStringTransform(t, NULL, kCFStringTransformStripCombiningMarks, false);
	put("transform", t);
	CFMutableStringRef n = CFStringCreateMutableCopy(NULL, 0, CFSTR("é"));
	CFStringNormalize(n, kCFStringNormalizationFormC);
	printf("normalize C: %ld\n", CFStringGetLength(n));
	put("int value", CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), CFStringGetIntValue(CFSTR("  -123abc"))));
	CFDataRef utf16 = CFStringCreateExternalRepresentation(NULL, CFSTR("hi☃"), kCFStringEncodingUTF16BE, 0);
	hex("utf16be", utf16);
	put("from macroman", CFStringCreateWithCString(NULL, "caf\x8e", kCFStringEncodingMacRoman));
}

static CFComparisonResult
compare_strings(const void *a, const void *b, void *context)
{
	(void)context;
	return CFStringCompare(a, b, 0);
}

static void
collections(void)
{
	const void *keys[] = { CFSTR("b"), CFSTR("a"), CFSTR("c") };
	int v[] = { 2, 1, 3 };
	const void *vals[3];
	for (int i = 0; i < 3; i++) vals[i] = CFNumberCreate(NULL, kCFNumberIntType, &v[i]);
	CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, 3, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	int out = 0;
	CFNumberGetValue(CFDictionaryGetValue(d, CFSTR("c")), kCFNumberIntType, &out);
	printf("dict: %ld %d\n", CFDictionaryGetCount(d), out);
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (int i = 0; i < 3; i++) CFArrayAppendValue(a, keys[i]);
	CFArraySortValues(a, CFRangeMake(0, 3), compare_strings, NULL);
	put("sorted", CFStringCreateByCombiningStrings(NULL, a, CFSTR("")));
	CFSetRef s = CFSetCreate(NULL, keys, 3, &kCFTypeSetCallBacks);
	check("set member", CFSetContainsValue(s, CFSTR("a")) && !CFSetContainsValue(s, CFSTR("z")));
	CFBagRef bag = CFBagCreate(NULL, (const void *[]){ CFSTR("x"), CFSTR("x"), CFSTR("y") }, 3, &kCFTypeBagCallBacks);
	printf("bag count x: %ld\n", CFBagGetCountOfValue(bag, CFSTR("x")));
	check("equal dicts", CFEqual(d, CFDictionaryCreateCopy(NULL, d)));
	printf("hash stable: %d\n", CFHash(CFSTR("finch")) == CFHash(CFStringCreateCopy(NULL, CFSTR("finch"))));
}

static void
numbers_and_data(void)
{
	double pi = 3.25;
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &pi);
	int64_t big = 1LL << 40;
	CFNumberRef b = CFNumberCreate(NULL, kCFNumberSInt64Type, &big);
	printf("number compare: %ld\n", (long)CFNumberCompare(n, b, NULL));
	printf("is float: %d %d\n", CFNumberIsFloatType(n), CFNumberIsFloatType(b));
	check("bool", CFBooleanGetValue(kCFBooleanTrue) && CFGetTypeID(kCFBooleanFalse) == CFBooleanGetTypeID());
	CFMutableDataRef md = CFDataCreateMutable(NULL, 0);
	CFDataAppendBytes(md, (const UInt8 *)"finch", 5);
	CFDataReplaceBytes(md, CFRangeMake(1, 3), (const UInt8 *)"XYZW", 4);
	printf("data: %.*s\n", (int)CFDataGetLength(md), CFDataGetBytePtr(md));
	CFUUIDRef u = CFUUIDCreateFromString(NULL, CFSTR("68753a44-4d6f-1226-9c60-0050e4c00067"));
	put("uuid", CFUUIDCreateString(NULL, u));
}

static void
plists(void)
{
	int one = 1;
	CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(d, CFSTR("Label"), CFSTR("org.finch.test"));
	CFDictionarySetValue(d, CFSTR("Count"), CFNumberCreate(NULL, kCFNumberIntType, &one));
	CFDictionarySetValue(d, CFSTR("Enabled"), kCFBooleanTrue);
	CFDictionarySetValue(d, CFSTR("When"), CFDateCreate(NULL, 700000000.0));
	CFDictionarySetValue(d, CFSTR("Blob"), CFDataCreate(NULL, (const UInt8 *)"\0\1\2", 3));
	CFDictionarySetValue(d, CFSTR("List"), CFArrayCreate(NULL, (const void *[]){ CFSTR("x"), CFSTR("ÿ") }, 2,
	    &kCFTypeArrayCallBacks));
	CFDataRef xml = CFPropertyListCreateData(NULL, d, kCFPropertyListXMLFormat_v1_0, 0, NULL);
	hex("xml plist", xml);
	CFDataRef bin = CFPropertyListCreateData(NULL, d, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
	hex("binary plist", bin);
	CFPropertyListFormat fmt;
	CFPropertyListRef back = CFPropertyListCreateWithData(NULL, bin, 0, &fmt, NULL);
	check("binary round trip", back && CFEqual(back, d) && fmt == kCFPropertyListBinaryFormat_v1_0);
	back = CFPropertyListCreateWithData(NULL, xml, 0, &fmt, NULL);
	check("xml round trip", back && CFEqual(back, d) && fmt == kCFPropertyListXMLFormat_v1_0);
	CFDataRef old = CFDataCreate(NULL, (const UInt8 *)"{ a = (1, \"two\"); b = <0102>; }", 31);
	back = CFPropertyListCreateWithData(NULL, old, 0, &fmt, NULL);
	check("openstep plist", back && fmt == kCFPropertyListOpenStepFormat && CFDictionaryGetCount(back) == 2);

	/* CF <-> XPC (CFXPCBridge), as IOKit's power management uses it. */
	xpc_object_t x = _CFXPCCreateXPCObjectFromCFObject(d);
	printf("xpc type dictionary: %d, count %zu\n", xpc_get_type(x) == XPC_TYPE_DICTIONARY, xpc_dictionary_get_count(x));
	CFTypeRef roundtrip = _CFXPCCreateCFObjectFromXPCObject(x);
	check("xpc round trip", roundtrip && CFEqual(roundtrip, d));
	xpc_object_t msg = _CFXPCCreateXPCMessageWithCFObject(CFSTR("payload"));
	CFTypeRef fromMsg = _CFXPCCreateCFObjectFromXPCMessage(msg);
	check("xpc message round trip", fromMsg && CFEqual(fromMsg, CFSTR("payload")));
	printf("xpc message keys: %zu\n", xpc_dictionary_get_count(msg));
}

static void
time_and_locale(void)
{
	CFTimeZoneRef gmt = CFTimeZoneCreateWithTimeIntervalFromGMT(NULL, 0);
	CFLocaleRef posix = CFLocaleCreate(NULL, CFSTR("en_US_POSIX"));
	CFDateFormatterRef f = CFDateFormatterCreate(NULL, posix, kCFDateFormatterNoStyle, kCFDateFormatterNoStyle);
	CFDateFormatterSetFormat(f, CFSTR("yyyy-MM-dd'T'HH:mm:ss EEEE"));
	CFDateFormatterSetProperty(f, kCFDateFormatterTimeZone, gmt);
	put("date", CFDateFormatterCreateStringWithAbsoluteTime(NULL, f, 700000000.0));
	CFAbsoluteTime parsed = 0;
	check("date parse", CFDateFormatterGetAbsoluteTimeFromString(f, CFSTR("2023-03-08T20:26:40 Wednesday"), NULL,
	    &parsed) && parsed == 700000000.0);
	CFLocaleRef de = CFLocaleCreate(NULL, CFSTR("de_DE"));
	CFNumberFormatterRef nf = CFNumberFormatterCreate(NULL, de, kCFNumberFormatterDecimalStyle);
	double x = 1234567.891;
	put("number de", CFNumberFormatterCreateStringWithValue(NULL, nf, kCFNumberDoubleType, &x));
	put("locale display", CFLocaleCopyDisplayNameForPropertyValue(posix, kCFLocaleIdentifier, CFSTR("fr_CA")));
	put("canonical", CFLocaleCreateCanonicalLocaleIdentifierFromString(NULL, CFSTR("EN-us")));
	CFGregorianDate g = CFAbsoluteTimeGetGregorianDate(700000000.0, gmt);
	printf("gregorian: %d-%d-%d %d:%d\n", (int)g.year, g.month, g.day, g.hour, g.minute);
	CFCalendarRef cal = CFCalendarCreateWithIdentifier(NULL, kCFGregorianCalendar);
	CFCalendarSetTimeZone(cal, gmt);
	int y = 0, mo = 0, dd = 0;
	CFCalendarDecomposeAbsoluteTime(cal, 700000000.0, "yMd", &y, &mo, &dd);
	printf("calendar: %d %d %d\n", y, mo, dd);
	check("charset", CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetDecimalDigit), 0x0663)
	    && !CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetLetter), '1'));
}

static void
urls(void)
{
	CFURLRef u = CFURLCreateWithString(NULL, CFSTR("https://user@example.com:8443/a/b/../c.txt?q=1#frag"), NULL);
	put("host", CFURLCopyHostName(u));
	printf("port: %d\n", CFURLGetPortNumber(u));
	put("path", CFURLCopyPath(u));
	put("ext", CFURLCopyPathExtension(u));
	put("absolute", CFURLGetString(CFURLCopyAbsoluteURL(u)));
	CFURLRef f = CFURLCreateWithFileSystemPath(NULL, CFSTR("/usr/share/../lib"), kCFURLPOSIXPathStyle, true);
	put("file url", CFURLGetString(f));
	put("escaped", CFURLCreateStringByAddingPercentEscapes(NULL, CFSTR("a b&c/é"), NULL, CFSTR("&"),
	    kCFStringEncodingUTF8));
}

static void
timer_fired(CFRunLoopTimerRef t, void *info)
{
	(void)t;
	(*(int *)info)++;
	CFRunLoopStop(CFRunLoopGetCurrent());
}

static void
mach_callback(CFMachPortRef port, void *msg, CFIndex size, void *info)
{
	(void)port; (void)size;
	*(int *)info = ((mach_msg_header_t *)msg)->msgh_id;
	CFRunLoopStop(CFRunLoopGetCurrent());
}

static void
fd_callback(CFFileDescriptorRef f, CFOptionFlags types, void *info)
{
	char c;
	read(CFFileDescriptorGetNativeDescriptor(f), &c, 1);
	((int *)info)[0]++;
	((int *)info)[1] = (int)types;
	((int *)info)[2] = c;
	CFRunLoopStop(CFRunLoopGetCurrent());
}

/* CFFileDescriptor: one-shot read callback delivered by the run loop. */
static void
file_descriptor(void)
{
	int p[2], got[3] = { 0, 0, 0 };
	pipe(p);
	CFFileDescriptorContext ctx = { 0, got, NULL, NULL, NULL };
	CFFileDescriptorRef f = CFFileDescriptorCreate(NULL, p[0], true, fd_callback, &ctx);
	printf("fd type matches: %d\n", CFGetTypeID(f) == CFFileDescriptorGetTypeID());
	CFRunLoopSourceRef src = CFFileDescriptorCreateRunLoopSource(NULL, f, 0);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
	CFFileDescriptorEnableCallBacks(f, kCFFileDescriptorReadCallBack);
	write(p[1], "ab", 2);
	SInt32 r = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5, false);
	printf("fd callback: count %d types %d byte %c result %d\n", got[0], got[1], got[2], (int)r);
	/* One-shot: data is still waiting, but no callback until re-enabled. */
	r = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
	printf("fd one-shot: count %d result %d\n", got[0], (int)r);
	CFFileDescriptorEnableCallBacks(f, kCFFileDescriptorReadCallBack);
	r = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5, false);
	printf("fd re-enabled: count %d byte %c result %d\n", got[0], got[2], (int)r);
	CFFileDescriptorInvalidate(f);
	check("fd invalidated", !CFFileDescriptorIsValid(f));
	CFRelease(src);
	CFRelease(f);
	close(p[1]);
}

static void
runloop(void)
{
	int fired = 0;
	CFRunLoopTimerContext tc = { 0, &fired, NULL, NULL, NULL };
	CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.05, 0, 0, 0, timer_fired, &tc);
	CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
	SInt32 r = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5, false);
	printf("timer: fired %d, result %d\n", fired, (int)r);

	int got = 0;
	CFMachPortContext mc = { 0, &got, NULL, NULL, NULL };
	CFMachPortRef mp = CFMachPortCreate(NULL, mach_callback, &mc, NULL);
	CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, mp, 0);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
	mach_msg_header_t h = { .msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0), .msgh_size = sizeof(h),
	    .msgh_remote_port = CFMachPortGetPort(mp), .msgh_id = 4242 };
	mach_msg(&h, MACH_SEND_MSG, sizeof(h), 0, 0, 0, 0);
	r = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5, false);
	printf("mach port: id %d, result %d\n", got, (int)r);
	CFMachPortInvalidate(mp);
	check("invalidated", !CFMachPortIsValid(mp));

	__block int blocks = 0;
	CFRunLoopPerformBlock(CFRunLoopGetCurrent(), kCFRunLoopDefaultMode, ^{ blocks++; });
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
	printf("perform block: %d\n", blocks);
}

/* CF objects are Objective-C objects: their classes, and ObjC memory
 * management and equality on them. */
static void
objc_bridge(void)
{
	CFMutableStringRef m = CFStringCreateMutableCopy(NULL, 0, CFSTR("ab"));
	int one = 1;
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &one);
	printf("class constant string: %s\n", object_getClassName((id)CFSTR("x")));
	printf("class string: %s\n", object_getClassName((id)m));
	printf("class number: %s\n", object_getClassName((id)n));
	printf("class boolean: %s\n", object_getClassName((id)kCFBooleanTrue));
	printf("class null: %s\n", object_getClassName((id)kCFNull));
	((id (*)(id, SEL))objc_msgSend)((id)m, sel_registerName("retain"));
	printf("objc retain: %ld\n", CFGetRetainCount(m));
	((void (*)(id, SEL))objc_msgSend)((id)m, sel_registerName("release"));
	printf("objc release: %ld\n", CFGetRetainCount(m));
	bool eq = ((bool (*)(id, SEL, id))objc_msgSend)((id)m, sel_registerName("isEqual:"), (id)CFSTR("ab"));
	printf("objc isEqual: %d\n", eq);
	unsigned long h = ((unsigned long (*)(id, SEL))objc_msgSend)((id)m, sel_registerName("hash"));
	printf("objc hash matches CFHash: %d\n", h == CFHash(m));
}

int
main(int argc, char **argv)
{
	Dl_info info;
	setvbuf(stdout, NULL, _IONBF, 0);
	if (!(argc > 1 && strcmp(argv[1], "--no-path") == 0) && dladdr((void *)CFStringCreateMutable, &info))
		printf("CoreFoundation: %s\n", info.dli_fname);
	strings();
	collections();
	numbers_and_data();
	plists();
	time_and_locale();
	urls();
	runloop();
	file_descriptor();
	objc_bridge();
	printf("%s (%d failed checks)\n", failures ? "FAILED" : "done", failures);
	return failures != 0;
}
