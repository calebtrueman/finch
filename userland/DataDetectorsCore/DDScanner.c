/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * DataDetectorsCore (private): a scanner that finds links, email addresses, phone
 * numbers and IP addresses in text, as results with a type, a range and the matched
 * string, typed as Apple's are (HttpURL, WebURL, FileURL, GenericURL, Email,
 * PhoneNumber, IPAddress). Where a URL ends follows Apple's scanner: trailing . , ! ?
 * : and unbalanced closing brackets are left out, quotes and angle brackets end it.
 * Dates and street addresses (Apple's DateTime and FullAddress) aren't found yet.
 * Signatures are Apple's, read from its binary and Terminal's calls.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* CoreFoundation's runtime (swift-corelibs' CFRuntime.h): CF types of our own. */
typedef struct {
    uintptr_t isa;
    _Atomic(uint64_t) info;
} CFRuntimeBase;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} CFRuntimeClass;

extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes,
                                          unsigned char *category);

typedef struct __DDScanner *DDScannerRef;
typedef struct __DDResult *DDResultRef;

struct __DDScanner {
    CFRuntimeBase base;
    int type;
    long options;
    CFMutableArrayRef results;
};

struct __DDResult {
    CFRuntimeBase base;
    CFStringRef type;
    CFStringRef matched;
    CFRange range;
};

/* Apple's result's range sits at 0x20, which callers reaching in rely on. */
_Static_assert(__builtin_offsetof(struct __DDResult, range) == 0x20, "DDResult range offset");

DDScannerRef DDScannerCreate(int type, long options, CFErrorRef *error);
DDScannerRef DDScannerCreateWithTypeAndLocale(int type, CFLocaleRef locale, CFErrorRef *error);
void DDScannerSetOptions(DDScannerRef scanner, long options);
Boolean DDScannerScanStringWithRange(DDScannerRef scanner, CFStringRef string, CFRange range);
CFArrayRef DDScannerCopyResultsWithOptions(DDScannerRef scanner, long options);
CFTypeID DDScannerGetTypeID(void);
CFTypeID DDResultGetTypeID(void);
CFRange DDResultGetRange(DDResultRef result);
CFStringRef DDResultGetType(DDResultRef result);
CFStringRef DDResultGetMatchedString(DDResultRef result);

static CFTypeID scanner_type, result_type;

static void
scanner_finalize(CFTypeRef cf)
{
    CFRelease(((struct __DDScanner *)cf)->results);
}

static void
result_finalize(CFTypeRef cf)
{
    struct __DDResult *r = (struct __DDResult *)cf;
    CFRelease(r->type);
    CFRelease(r->matched);
}

static CFStringRef
result_description(CFTypeRef cf)
{
    const struct __DDResult *r = cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<DDResult %p [%ld,%ld] %@: %@>"), cf, (long)r->range.location,
                                    (long)r->range.length, r->type, r->matched);
}

static const CFRuntimeClass scanner_class = {0, "DDScanner", NULL, NULL, scanner_finalize, NULL, NULL, NULL, NULL,
                                             NULL, NULL, 0};
static const CFRuntimeClass result_class = {0, "DDResult", NULL, NULL, result_finalize, NULL, NULL, NULL,
                                            result_description, NULL, NULL, 0};

CFTypeID
DDScannerGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ scanner_type = _CFRuntimeRegisterClass(&scanner_class); });
    return scanner_type;
}

CFTypeID
DDResultGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ result_type = _CFRuntimeRegisterClass(&result_class); });
    return result_type;
}

DDScannerRef
DDScannerCreateWithTypeAndLocale(int type, CFLocaleRef locale, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    struct __DDScanner *s = (struct __DDScanner *)_CFRuntimeCreateInstance(
        NULL, DDScannerGetTypeID(), sizeof(struct __DDScanner) - sizeof(CFRuntimeBase), NULL);
    s->type = type;
    s->results = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    return s;
}

DDScannerRef
DDScannerCreate(int type, long options, CFErrorRef *error)
{
    DDScannerRef s = DDScannerCreateWithTypeAndLocale(type, NULL, error);
    if (s)
        DDScannerSetOptions(s, options);
    return s;
}

void
DDScannerSetOptions(DDScannerRef scanner, long options)
{
    if (scanner)
        scanner->options = options;
}

CFRange
DDResultGetRange(DDResultRef result)
{
    return result->range;
}

CFStringRef
DDResultGetType(DDResultRef result)
{
    return result->type;
}

CFStringRef
DDResultGetMatchedString(DDResultRef result)
{
    return result->matched;
}

/* --- scanning --- */

typedef struct {
    const UniChar *s;
    CFIndex n;          /* the scanned range's end */
    CFIndex base;       /* where the buffer starts in the string */
    CFStringRef string;
    CFMutableArrayRef out;
    bool *taken;        /* characters already in a result */
} scan_t;

static bool
is_alpha(UniChar c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static bool
is_digit(UniChar c)
{
    return c >= '0' && c <= '9';
}

static bool
is_alnum(UniChar c)
{
    return is_alpha(c) || is_digit(c);
}

static bool
is_space(UniChar c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0xA0 || c == 0x2028 || c == 0x2029 || c == 0x3000;
}

static void
add(scan_t *sc, CFIndex start, CFIndex end, CFStringRef type)
{
    struct __DDResult *r = (struct __DDResult *)_CFRuntimeCreateInstance(
        NULL, DDResultGetTypeID(), sizeof(struct __DDResult) - sizeof(CFRuntimeBase), NULL);
    r->type = CFRetain(type);
    r->range = CFRangeMake(sc->base + start, end - start);
    r->matched = CFStringCreateWithSubstring(NULL, sc->string, r->range);
    CFArrayAppendValue(sc->out, r);
    CFRelease(r);
    for (CFIndex i = start; i < end; i++)
        sc->taken[i] = true;
}

static bool
free_span(const scan_t *sc, CFIndex start, CFIndex end)
{
    for (CFIndex i = start; i < end; i++)
        if (sc->taken[i])
            return false;
    return true;
}

/* A URL's characters run to whitespace, a quote or an angle bracket; then trailing
   punctuation and unbalanced closing brackets come off. */
static CFIndex
url_end(const scan_t *sc, CFIndex i)
{
    CFIndex end = i;
    while (end < sc->n && !is_space(sc->s[end]) && sc->s[end] != '"' && sc->s[end] != '<' && sc->s[end] != '>' &&
           sc->s[end] != 0x201C && sc->s[end] != 0x201D)
        end++;
    for (;;) {
        if (end <= i)
            return end;
        UniChar c = sc->s[end - 1];
        if (c == '.' || c == ',' || c == '!' || c == '?' || c == ':') {
            end--;
            continue;
        }
        if (c == ')' || c == ']' || c == '}') {
            UniChar open = c == ')' ? '(' : c == ']' ? '[' : '{';
            int depth = 0;
            for (CFIndex k = i; k < end; k++)
                depth += sc->s[k] == open ? 1 : sc->s[k] == c ? -1 : 0;
            if (depth < 0) {
                end--;
                continue;
            }
        }
        return end;
    }
}

static bool
prefix_ci(const UniChar *s, CFIndex n, const char *p)
{
    CFIndex k = (CFIndex)strlen(p);
    if (n < k)
        return false;
    for (CFIndex i = 0; i < k; i++) {
        UniChar c = s[i];
        if (c >= 'A' && c <= 'Z')
            c += 32;
        if (c != (UniChar)p[i])
            return false;
    }
    return true;
}

/* scheme://..., and the schemes written without slashes */
static void
scan_schemes(scan_t *sc)
{
    static const char *bare[] = {"mailto:", "tel:", "sms:", "facetime:", "facetime-audio:", "maps:", "news:"};
    for (CFIndex i = 0; i < sc->n; i++) {
        if (!is_alpha(sc->s[i]) || (i > 0 && (is_alnum(sc->s[i - 1]) || sc->s[i - 1] == '+' || sc->s[i - 1] == '.' ||
                                              sc->s[i - 1] == '-')))
            continue;
        CFIndex j = i;
        while (j < sc->n && (is_alnum(sc->s[j]) || sc->s[j] == '+' || sc->s[j] == '.' || sc->s[j] == '-'))
            j++;
        if (j >= sc->n || sc->s[j] != ':')
            continue;
        bool slashes = j + 2 < sc->n && sc->s[j + 1] == '/' && sc->s[j + 2] == '/';
        bool known = false;
        for (size_t k = 0; k < sizeof bare / sizeof *bare && !slashes; k++)
            known = known || (j + 1 - i == (CFIndex)strlen(bare[k]) && prefix_ci(sc->s + i, sc->n - i, bare[k]));
        if (!slashes && !known)
            continue;
        CFIndex body = slashes ? j + 3 : j + 1, end = url_end(sc, body);
        if (end <= body)
            continue;
        CFStringRef type = CFSTR("GenericURL");
        if (prefix_ci(sc->s + i, j - i + 1, "http:") || prefix_ci(sc->s + i, j - i + 1, "https:"))
            type = CFSTR("HttpURL");
        else if (prefix_ci(sc->s + i, j - i + 1, "file:"))
            type = CFSTR("FileURL");
        add(sc, i, end, type);
        i = end;
    }
}

/* Top-level domains a bare host name may end in: the generic ones and the country
   codes, less those that are also common file extensions (.md, .py, .sh, ...). */
static const char *const kTLDs[] = {
    "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "name", "pro", "aero", "coop", "museum", "mobi",
    "asia", "tel", "travel", "jobs", "app", "dev", "io", "ai", "co", "me", "tv", "us", "uk", "ca", "de", "fr", "jp",
    "au", "cn", "ru", "br", "it", "nl", "es", "se", "no", "fi", "dk", "ch", "at", "be", "cz", "in", "kr", "nz", "ie",
    "za", "mx", "ar", "cl", "eu", "gr", "hu", "pt", "ro", "sk", "tr", "tw", "hk", "sg", "il", "is", "lu", "ua", "vn",
    "id", "my", "ph", "th", "xyz", "online", "site", "shop", "store", "tech", "blog", "cloud", "page", "news",
    "live", "art", "design", "club", "fm", "gg", "ly", "to", "cc", "ws", "la",
};

static bool
known_tld(const UniChar *s, CFIndex n)
{
    for (size_t k = 0; k < sizeof kTLDs / sizeof *kTLDs; k++)
        if ((CFIndex)strlen(kTLDs[k]) == n && prefix_ci(s, n, kTLDs[k]))
            return true;
    return false;
}

/* host.tld at i: labels of letters, digits and hyphens, at least two, the last a
   known TLD. Returns the host's end, or -1. */
static CFIndex
host_end(const scan_t *sc, CFIndex i)
{
    CFIndex j = i, labels = 0, last = i;
    for (;;) {
        CFIndex start = j;
        while (j < sc->n && (is_alnum(sc->s[j]) || sc->s[j] == '-' || sc->s[j] > 0x7F) && !is_space(sc->s[j]))
            j++;
        if (j == start)
            break;
        labels++;
        last = start;
        if (j + 1 < sc->n && sc->s[j] == '.' && (is_alnum(sc->s[j + 1]) || sc->s[j + 1] > 0x7F))
            j++;
        else
            break;
    }
    if (labels < 2 || !known_tld(sc->s + last, j - last))
        return -1;
    return j;
}

static void
scan_emails(scan_t *sc)
{
    for (CFIndex at = 1; at < sc->n; at++) {
        if (sc->s[at] != '@' || sc->taken[at])
            continue;
        CFIndex start = at;
        while (start > 0 && (is_alnum(sc->s[start - 1]) || strchr("._%+-", (char)sc->s[start - 1])) && sc->s[start - 1] < 0x80)
            start--;
        while (start < at && sc->s[start] == '.')
            start++;
        if (start == at || (start > 0 && sc->s[start - 1] == ':')) /* user:password@host isn't an address */
            continue;
        CFIndex end = host_end(sc, at + 1);
        if (end < 0 || (end < sc->n && (sc->s[end] == ':' || sc->s[end] == '/' || sc->s[end] == '@')))
            continue;
        if (free_span(sc, start, end))
            add(sc, start, end, CFSTR("Email"));
    }
}

static void
scan_hosts(scan_t *sc)
{
    for (CFIndex i = 0; i < sc->n; i++) {
        if (sc->taken[i] || !is_alnum(sc->s[i]) ||
            (i > 0 && (is_alnum(sc->s[i - 1]) || sc->s[i - 1] == '.' || sc->s[i - 1] == '-' || sc->s[i - 1] == '/')))
            continue;
        CFIndex h = host_end(sc, i);
        /* a colon after a host starts a port, or it isn't a link (git@host:path) */
        if (h < 0 || (h + 1 < sc->n && sc->s[h] == ':' && !is_digit(sc->s[h + 1])))
            continue;
        CFIndex end = (h < sc->n && (sc->s[h] == '/' || sc->s[h] == ':' || sc->s[h] == '?' || sc->s[h] == '#'))
                          ? url_end(sc, h)
                          : h;
        if (end < h)
            end = h;
        if (free_span(sc, i, end))
            add(sc, i, end, CFSTR("WebURL"));
        i = end;
    }
}

static void
scan_ip_addresses(scan_t *sc)
{
    for (CFIndex i = 0; i < sc->n; i++) {
        if (sc->taken[i] || !is_digit(sc->s[i]) || (i > 0 && (is_alnum(sc->s[i - 1]) || sc->s[i - 1] == '.')))
            continue;
        CFIndex j = i;
        int parts = 0;
        bool ok = true;
        while (parts < 4) {
            int value = 0, digits = 0;
            while (j < sc->n && is_digit(sc->s[j]) && digits < 4)
                value = value * 10 + (sc->s[j++] - '0'), digits++;
            if (digits == 0 || digits > 3 || value > 255) {
                ok = false;
                break;
            }
            parts++;
            if (parts < 4) {
                if (j + 1 < sc->n && sc->s[j] == '.' && is_digit(sc->s[j + 1]))
                    j++;
                else {
                    ok = false;
                    break;
                }
            }
        }
        if (ok && (j >= sc->n || (!is_alnum(sc->s[j]) && !(sc->s[j] == '.' && j + 1 < sc->n && is_digit(sc->s[j + 1])))))
            add(sc, i, j, CFSTR("IPAddress"));
        else
            while (i + 1 < sc->n && (is_digit(sc->s[i + 1]) || sc->s[i + 1] == '.'))
                i++;
    }
}

/* Phone numbers: an optional + and country code, then groups of digits split by
   spaces, hyphens, dots or an area code's parentheses; 7 to 15 digits, at least two
   groups, and not shaped like a date (dddd-dd-dd). */
static void
scan_phones(scan_t *sc)
{
    for (CFIndex i = 0; i < sc->n; i++) {
        UniChar c = sc->s[i];
        if (sc->taken[i] || !(is_digit(c) || c == '+' || c == '(') ||
            (i > 0 && (is_alnum(sc->s[i - 1]) || sc->s[i - 1] == '.' || sc->s[i - 1] == '-' || sc->s[i - 1] == '+')))
            continue;
        CFIndex j = i;
        bool plus = c == '+';
        if (plus)
            j++;
        int digits = 0, groups = 0, sizes[16] = {0};
        CFIndex end = j;
        while (j < sc->n && groups < 16) {
            bool paren = sc->s[j] == '(';
            if (paren)
                j++;
            CFIndex g = j;
            while (j < sc->n && is_digit(sc->s[j]))
                j++;
            if (j == g)
                break;
            if (paren) {
                if (j >= sc->n || sc->s[j] != ')')
                    break;
                j++;
            }
            sizes[groups++] = (int)(j - g - (paren ? 1 : 0));
            digits += (int)(j - g - (paren ? 1 : 0));
            end = j;
            if (j < sc->n && (sc->s[j] == ' ' || sc->s[j] == '-' || sc->s[j] == '.') && j + 1 < sc->n &&
                (is_digit(sc->s[j + 1]) || sc->s[j + 1] == '('))
                j++;
            else if (!(j < sc->n && sc->s[j] == '('))
                break;
        }
        bool date = groups == 3 && sizes[0] == 4 && sizes[1] <= 2 && sizes[2] <= 2;
        bool shaped = groups >= 2 || (plus && groups >= 1);
        bool boundary = end >= sc->n || !(is_alnum(sc->s[end]) || (sc->s[end] == '.' && end + 1 < sc->n && is_digit(sc->s[end + 1])));
        if (digits >= 7 && digits <= 15 && shaped && !date && boundary && sizes[groups - 1] >= 4 && free_span(sc, i, end)) {
            add(sc, i, end, CFSTR("PhoneNumber"));
            i = end;
        } else {
            while (i + 1 < sc->n && (is_digit(sc->s[i + 1]) || strchr(" -.()+", (char)sc->s[i + 1])) && sc->s[i + 1] < 0x80 &&
                   !is_space(sc->s[i + 1]))
                i++;
        }
    }
}

static CFComparisonResult
by_location(const void *a, const void *b, void *context)
{
    CFIndex x = ((const struct __DDResult *)a)->range.location, y = ((const struct __DDResult *)b)->range.location;
    return x < y ? kCFCompareLessThan : x > y ? kCFCompareGreaterThan : kCFCompareEqualTo;
}

Boolean
DDScannerScanStringWithRange(DDScannerRef scanner, CFStringRef string, CFRange range)
{
    if (!scanner || !string)
        return false;
    CFArrayRemoveAllValues(scanner->results);
    CFIndex len = CFStringGetLength(string);
    if (range.location < 0 || range.length < 0 || range.location + range.length > len)
        return false;
    UniChar *buf = malloc(sizeof(UniChar) * (size_t)(range.length + 1));
    CFStringGetCharacters(string, range, buf);
    scan_t sc = {buf, range.length, range.location, string, scanner->results, calloc((size_t)range.length + 1, 1)};
    scan_schemes(&sc);
    scan_emails(&sc);
    scan_ip_addresses(&sc);
    scan_hosts(&sc);
    scan_phones(&sc);
    CFArraySortValues(scanner->results, CFRangeMake(0, CFArrayGetCount(scanner->results)), by_location, NULL);
    free(sc.taken);
    free(buf);
    return true;
}

CFArrayRef
DDScannerCopyResultsWithOptions(DDScannerRef scanner, long options)
{
    if (!scanner)
        return NULL;
    return CFArrayCreateCopy(NULL, scanner->results);
}
