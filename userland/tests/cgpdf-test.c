/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cgpdf-test: CoreGraphics' PDF support, one result per line, for
 * diffing Apple's CoreGraphics against Finch's.
 *
 *  - writing: documents made with CGPDFContext (boxes, information
 *    dictionary, links, outlines, metadata, encryption), read back and
 *    described through the reading API (dates, the producer and the file
 *    identifier are masked: they differ by run and by writer);
 *  - reading: hand-written files (cross-reference tables and streams,
 *    object streams, incremental updates, a broken table, filters, strings,
 *    dates) printed object by object, and their content streams traced
 *    through CGPDFScanner;
 *  - drawing: scenes drawn into a PDF page, read back and drawn with
 *    CGContextDrawPDFPage into a bitmap, compared with the same scene drawn
 *    straight into a bitmap; and hand-written pages compared with the CG
 *    calls they amount to.
 *
 *   finch-cgpdf-test [--no-path]
 *   finch-cgpdf-test --write DIR     write the generated documents to DIR
 *   finch-cgpdf-test --read DIR      describe and draw documents another CoreGraphics wrote
 *   finch-cgpdf-test --write-reference FILE   (on macOS, against Apple's CG) render the reference pages
 */
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#pragma mark - Printing objects

static void
print_cfstring(CFStringRef s)
{
    if (!s) {
        printf("(null)");
        return;
    }
    char buf[4096];
    if (!CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8))
        strcpy(buf, "?");
    printf("\"%s\"", buf);
}

static void
print_bytes(const unsigned char *b, size_t n)
{
    putchar('<');
    for (size_t i = 0; i < n && i < 64; i++)
        printf("%02x", b[i]);
    if (n > 64)
        printf("...(%zu)", n);
    putchar('>');
}

static void print_object(CGPDFObjectRef o, int depth);

static int
cmp_keys(const void *a, const void *b)
{
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

typedef struct {
    const char *keys[256];
    CGPDFObjectRef values[256];
    int n;
} Entries;

static void
collect(const char *key, CGPDFObjectRef value, void *info)
{
    Entries *e = info;
    if (e->n < 256) {
        e->keys[e->n] = key;
        e->values[e->n++] = value;
    }
}

static void
print_dict(CGPDFDictionaryRef d, int depth)
{
    Entries e = {{0}, {0}, 0};
    CGPDFDictionaryApplyFunction(d, collect, &e);
    const char *sorted[256];
    memcpy(sorted, e.keys, sizeof(char *) * (size_t)e.n);
    qsort(sorted, (size_t)e.n, sizeof(char *), cmp_keys);
    printf("<<");
    for (int i = 0; i < e.n; i++) {
        CGPDFObjectRef v;
        CGPDFDictionaryGetObject(d, sorted[i], &v);
        printf(" /%s ", sorted[i]);
        /* parents point back up the tree */
        if (!strcmp(sorted[i], "Parent") || !strcmp(sorted[i], "P") || !strcmp(sorted[i], "Prev"))
            printf("<%s>", CGPDFObjectGetType(v) == kCGPDFObjectTypeDictionary ? "dict" : "?");
        else
            print_object(v, depth + 1);
    }
    printf(" >> (%zu)", CGPDFDictionaryGetCount(d));
}

static void
print_object(CGPDFObjectRef o, int depth)
{
    if (depth > 12) {
        printf("...");
        return;
    }
    switch (CGPDFObjectGetType(o)) {
    case kCGPDFObjectTypeNull: printf("null"); break;
    case kCGPDFObjectTypeBoolean: {
        CGPDFBoolean b;
        CGPDFObjectGetValue(o, kCGPDFObjectTypeBoolean, &b);
        printf(b ? "true" : "false");
        break;
    }
    case kCGPDFObjectTypeInteger: {
        CGPDFInteger i;
        CGPDFObjectGetValue(o, kCGPDFObjectTypeInteger, &i);
        printf("%ld", i);
        break;
    }
    case kCGPDFObjectTypeReal: {
        CGPDFReal r;
        CGPDFObjectGetValue(o, kCGPDFObjectTypeReal, &r);
        printf("%.4f", r);
        break;
    }
    case kCGPDFObjectTypeName: {
        const char *n;
        CGPDFObjectGetValue(o, kCGPDFObjectTypeName, &n);
        printf("/%s", n);
        break;
    }
    case kCGPDFObjectTypeString: {
        CGPDFStringRef s;
        CGPDFObjectGetValue(o, kCGPDFObjectTypeString, &s);
        print_bytes(CGPDFStringGetBytePtr(s), CGPDFStringGetLength(s));
        break;
    }
    case kCGPDFObjectTypeArray: {
        CGPDFArrayRef a;
        CGPDFObjectGetValue(o, kCGPDFObjectTypeArray, &a);
        printf("[");
        for (size_t i = 0; i < CGPDFArrayGetCount(a); i++) {
            CGPDFObjectRef v;
            printf(" ");
            if (CGPDFArrayGetObject(a, i, &v))
                print_object(v, depth + 1);
            else
                printf("<missing>");
        }
        printf(" ]");
        break;
    }
    case kCGPDFObjectTypeDictionary: {
        CGPDFDictionaryRef d;
        CGPDFObjectGetValue(o, kCGPDFObjectTypeDictionary, &d);
        print_dict(d, depth);
        break;
    }
    case kCGPDFObjectTypeStream: {
        CGPDFStreamRef s;
        CGPDFObjectGetValue(o, kCGPDFObjectTypeStream, &s);
        printf("stream ");
        print_dict(CGPDFStreamGetDictionary(s), depth);
        CGPDFDataFormat f = 99;
        CFDataRef data = CGPDFStreamCopyData(s, &f);
        printf(" format %d data ", (int)f);
        if (data) {
            print_bytes(CFDataGetBytePtr(data), (size_t)CFDataGetLength(data));
            CFRelease(data);
        } else {
            printf("NULL");
        }
        break;
    }
    default: printf("<type %d>", (int)CGPDFObjectGetType(o)); break;
    }
}

static void
print_rect(const char *label, CGRect r)
{
    if (CGRectIsNull(r))
        printf("%s null", label);
    else
        printf("%s %.2f %.2f %.2f %.2f", label, r.origin.x, r.origin.y, r.size.width, r.size.height);
}

static void
print_transform(const char *label, CGAffineTransform t)
{
    printf("%s [%.4f %.4f %.4f %.4f %.4f %.4f]\n", label, t.a + 0.0, t.b + 0.0, t.c + 0.0, t.d + 0.0, t.tx + 0.0,
           t.ty + 0.0);
}

#pragma mark - Describing a document through the API

static CGPDFDocumentRef
document_from_data(CFDataRef data)
{
    CGDataProviderRef p = CGDataProviderCreateWithCFData(data);
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithProvider(p);
    CGDataProviderRelease(p);
    return doc;
}

/* Strings read while a document was locked are ciphertext (with a random IV): only their length is compared. */
static int strings_encrypted;

static void
print_info_string(CGPDFDictionaryRef info, const char *key, const char *name)
{
    CGPDFStringRef s;
    printf("%s info %s: ", name, key);
    if (!info || !CGPDFDictionaryGetString(info, key, &s)) {
        printf("absent\n");
        return;
    }
    if (strings_encrypted) {
        printf("%zu encrypted bytes\n", CGPDFStringGetLength(s));
        return;
    }
    CFStringRef t = CGPDFStringCopyTextString(s);
    print_cfstring(t);
    if (t)
        CFRelease(t);
    printf("\n");
}

static void
print_info(CGPDFDocumentRef doc, const char *name)
{
    CGPDFDictionaryRef info = CGPDFDocumentGetInfo(doc);
    printf("%s info: %s\n", name, info ? "present" : "absent");
    if (!info)
        return;
    Entries e = {{0}, {0}, 0};
    CGPDFDictionaryApplyFunction(info, collect, &e);
    qsort(e.keys, (size_t)e.n, sizeof(char *), cmp_keys);
    printf("%s info keys:", name);
    for (int i = 0; i < e.n; i++)
        printf(" %s", e.keys[i]);
    printf("\n");
    const char *keys[] = {"Title", "Author", "Subject", "Keywords", "Creator"};
    for (int i = 0; i < 5; i++)
        print_info_string(info, keys[i], name);
    CGPDFArrayRef kw;
    if (CGPDFDictionaryGetArray(info, "AAPL:Keywords", &kw)) {
        printf("%s info keyword array:", name);
        for (size_t i = 0; i < CGPDFArrayGetCount(kw); i++) {
            CGPDFStringRef s;
            if (CGPDFArrayGetString(kw, i, &s)) {
                CFStringRef t = CGPDFStringCopyTextString(s);
                printf(" ");
                print_cfstring(t);
                CFRelease(t);
            }
        }
        printf("\n");
    }
    /* dates differ by run: only that they parse */
    const char *dates[] = {"CreationDate", "ModDate"};
    for (int i = 0; i < 2; i++) {
        CGPDFStringRef s;
        CFDateRef d = CGPDFDictionaryGetString(info, dates[i], &s) ? CGPDFStringCopyDate(s) : NULL;
        printf("%s info %s: %s\n", name, dates[i], d ? "a date" : "none");
        if (d)
            CFRelease(d);
    }
}

static void
print_outline_level(CFArrayRef items, int depth, const char *name)
{
    for (CFIndex i = 0; items && i < CFArrayGetCount(items); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(items, i);
        printf("%s outline %*s", name, depth * 2, "");
        print_cfstring(CFDictionaryGetValue(item, kCGPDFOutlineTitle));
        CFTypeRef dest = CFDictionaryGetValue(item, kCGPDFOutlineDestination);
        if (dest && CFGetTypeID(dest) == CFNumberGetTypeID()) {
            long n;
            CFNumberGetValue(dest, kCFNumberLongType, &n);
            printf(" -> page %ld", n);
        } else if (dest && CFGetTypeID(dest) == CFURLGetTypeID()) {
            printf(" -> ");
            print_cfstring(CFURLGetString(dest));
        }
        CFTypeRef r = CFDictionaryGetValue(item, kCGPDFOutlineDestinationRect);
        CGRect rect;
        if (r && CGRectMakeWithDictionaryRepresentation(r, &rect))
            print_rect(" rect", rect);
        printf("\n");
        print_outline_level(CFDictionaryGetValue(item, kCGPDFOutlineChildren), depth + 1, name);
    }
}

/* Links: their rectangles and where they go. */
static void
print_annots(CGPDFDocumentRef doc, CGPDFPageRef page, const char *name)
{
    CGPDFArrayRef annots;
    if (!CGPDFDictionaryGetArray(CGPDFPageGetDictionary(page), "Annots", &annots))
        return;
    for (size_t i = 0; i < CGPDFArrayGetCount(annots); i++) {
        CGPDFDictionaryRef a;
        if (!CGPDFArrayGetDictionary(annots, i, &a))
            continue;
        const char *sub = "?";
        CGPDFDictionaryGetName(a, "Subtype", &sub);
        printf("%s page %zu annot %s", name, CGPDFPageGetPageNumber(page), sub);
        CGPDFArrayRef r;
        if (CGPDFDictionaryGetArray(a, "Rect", &r)) {
            printf(" rect");
            for (size_t k = 0; k < CGPDFArrayGetCount(r); k++) {
                CGPDFReal v;
                CGPDFArrayGetNumber(r, k, &v);
                printf(" %.2f", v);
            }
        }
        CGPDFDictionaryRef act;
        CGPDFStringRef uri;
        if (CGPDFDictionaryGetDictionary(a, "A", &act) && CGPDFDictionaryGetString(act, "URI", &uri)) {
            printf(" uri ");
            print_bytes(CGPDFStringGetBytePtr(uri), CGPDFStringGetLength(uri));
        }
        CGPDFArrayRef dest;
        if (CGPDFDictionaryGetArray(a, "Dest", &dest)) {
            CGPDFDictionaryRef target;
            size_t n = 0;
            if (CGPDFArrayGetDictionary(dest, 0, &target))
                for (size_t p = 1; p <= CGPDFDocumentGetNumberOfPages(doc); p++)
                    if (CGPDFPageGetDictionary(CGPDFDocumentGetPage(doc, p)) == target)
                        n = p;
            const char *kind = "?";
            CGPDFArrayGetName(dest, 1, &kind);
            printf(" dest page %zu /%s", n, kind);
            for (size_t k = 2; k < CGPDFArrayGetCount(dest); k++) {
                CGPDFReal v;
                if (CGPDFArrayGetNumber(dest, k, &v))
                    printf(" %.2f", v);
                else
                    printf(" null");
            }
        }
        printf("\n");
    }
}

static const char *box_names[] = {"media", "crop", "bleed", "trim", "art"};

static void
describe(CGPDFDocumentRef doc, const char *name)
{
    if (!doc) {
        printf("%s: no document\n", name);
        return;
    }
    int major = -1, minor = -1;
    CGPDFDocumentGetVersion(doc, &major, &minor);
    printf("%s version %d.%d encrypted %d unlocked %d printing %d copying %d permissions 0x%x\n", name, major, minor,
           CGPDFDocumentIsEncrypted(doc), CGPDFDocumentIsUnlocked(doc), CGPDFDocumentAllowsPrinting(doc),
           CGPDFDocumentAllowsCopying(doc), (unsigned)CGPDFDocumentGetAccessPermissions(doc));
    size_t pages = CGPDFDocumentGetNumberOfPages(doc);
    printf("%s pages %zu\n", name, pages);
    CGPDFArrayRef id = CGPDFDocumentGetID(doc);
    printf("%s ID:", name);
    for (size_t i = 0; id && i < CGPDFArrayGetCount(id); i++) {
        CGPDFStringRef s;
        printf(" %zu bytes", CGPDFArrayGetString(id, i, &s) ? CGPDFStringGetLength(s) : 0);
    }
    printf("\n");
    CGPDFDictionaryRef cat = CGPDFDocumentGetCatalog(doc);
    printf("%s catalog: %s", name, cat ? "present" : "absent");
    const char *ckeys[] = {"Type", "Pages", "Outlines", "Metadata", "OutputIntents"};
    for (int i = 0; cat && i < 5; i++) {
        CGPDFObjectRef o;
        if (CGPDFDictionaryGetObject(cat, ckeys[i], &o))
            printf(" %s", ckeys[i]);
    }
    printf("\n");
    CGPDFStreamRef md;
    if (cat && CGPDFDictionaryGetStream(cat, "Metadata", &md)) {
        CFDataRef data = CGPDFStreamCopyData(md, NULL);
        printf("%s metadata %ld bytes: %.*s\n", name, data ? (long)CFDataGetLength(data) : -1L,
               data ? (int)CFDataGetLength(data) : 0, data ? (const char *)CFDataGetBytePtr(data) : "");
        if (data)
            CFRelease(data);
    }
    CGPDFArrayRef intents;
    if (cat && CGPDFDictionaryGetArray(cat, "OutputIntents", &intents))
        for (size_t i = 0; i < CGPDFArrayGetCount(intents); i++) {
            CGPDFDictionaryRef oi;
            if (!CGPDFArrayGetDictionary(intents, i, &oi))
                continue;
            const char *s = "?";
            CGPDFDictionaryGetName(oi, "S", &s);
            printf("%s output intent /%s", name, s);
            const char *keys[] = {"OutputConditionIdentifier", "OutputCondition", "RegistryName", "Info"};
            for (int k = 0; k < 4; k++) {
                CGPDFStringRef str;
                if (CGPDFDictionaryGetString(oi, keys[k], &str)) {
                    CFStringRef t = CGPDFStringCopyTextString(str);
                    printf(" %s=", keys[k]);
                    print_cfstring(t);
                    CFRelease(t);
                }
            }
            CGPDFStreamRef prof;
            CGPDFInteger n = 0;
            if (CGPDFDictionaryGetStream(oi, "DestOutputProfile", &prof))
                CGPDFDictionaryGetInteger(CGPDFStreamGetDictionary(prof), "N", &n);
            printf(" profile N=%ld\n", n);
        }
    print_info(doc, name);
    CFDictionaryRef outline = CGPDFDocumentGetOutline(doc);
    printf("%s outline: %s\n", name, outline ? "present" : "absent");
    if (outline)
        print_outline_level(CFDictionaryGetValue(outline, kCGPDFOutlineChildren), 0, name);
    for (size_t p = 1; p <= pages; p++) {
        CGPDFPageRef page = CGPDFDocumentGetPage(doc, p);
        printf("%s page %zu: number %zu rotation %d", name, p, CGPDFPageGetPageNumber(page),
               CGPDFPageGetRotationAngle(page));
        for (int b = 0; b < 5; b++)
            print_rect(box_names[b], CGPDFPageGetBoxRect(page, (CGPDFBox)b)), printf(b < 4 ? ", " : "\n");
        print_annots(doc, page, name);
    }
}

#pragma mark - Writing

static CFDataRef
rect_data(CGRect r)
{
    return CFDataCreate(NULL, (const UInt8 *)&r, sizeof r);
}

static CFMutableDictionaryRef
mdict(void)
{
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

typedef CFDataRef (*Writer)(void);

/* A plain document: one letter-sized page. */
static CFDataRef
w_plain(void)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CGDataConsumerRef cons = CGDataConsumerCreateWithCFData(d);
    CGContextRef c = CGPDFContextCreate(cons, NULL, NULL);
    CGContextBeginPage(c, NULL);
    CGContextSetRGBFillColor(c, 1, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(72, 72, 144, 144));
    CGContextEndPage(c);
    CGContextRelease(c);  /* closes the document */
    CGDataConsumerRelease(cons);
    return d;
}

/* Information, boxes per page, links and destinations. */
static CFDataRef
w_info_boxes(void)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CGDataConsumerRef cons = CGDataConsumerCreateWithCFData(d);
    CFMutableDictionaryRef aux = mdict();
    CFDictionarySetValue(aux, kCGPDFContextTitle, CFSTR("Tést title"));
    CFDictionarySetValue(aux, kCGPDFContextAuthor, CFSTR("An Author"));
    CFDictionarySetValue(aux, kCGPDFContextCreator, CFSTR("finch-cgpdf-test"));
    CFDictionarySetValue(aux, kCGPDFContextSubject, CFSTR("Subject (with parens) \\ and backslash"));
    const void *kw[2] = {CFSTR("alpha"), CFSTR("beta gamma")};
    CFArrayRef kwa = CFArrayCreate(NULL, kw, 2, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(aux, kCGPDFContextKeywords, kwa);
    CFRelease(kwa);
    CFDataRef art = rect_data(CGRectMake(30, 40, 100, 50));
    CFDictionarySetValue(aux, kCGPDFContextArtBox, art);
    CFRelease(art);
    CGRect media = CGRectMake(10, 20, 300, 200);
    CGContextRef c = CGPDFContextCreate(cons, &media, aux);
    CFRelease(aux);
    print_transform("info-boxes ctm before page", CGContextGetCTM(c));
    CGPDFContextBeginPage(c, NULL);
    print_transform("info-boxes ctm", CGContextGetCTM(c));
    print_transform("info-boxes user to device", CGContextGetUserSpaceToDeviceSpaceTransform(c));
    print_rect("info-boxes clip", CGContextGetClipBoundingBox(c)), printf("\n");
    CGContextSetRGBFillColor(c, 0, 0, 1, 1);
    CGContextFillRect(c, CGRectMake(20, 30, 50, 40));
    CFURLRef url = CFURLCreateWithString(NULL, CFSTR("https://example.com/a?b=c"), NULL);
    CGContextTranslateCTM(c, 5, 5);
    CGPDFContextSetURLForRect(c, url, CGRectMake(20, 30, 50, 40));
    CFRelease(url);
    CGPDFContextAddDestinationAtPoint(c, CFSTR("start"), CGPointMake(50, 60));
    CGPDFContextEndPage(c);
    CFMutableDictionaryRef page = mdict();
    CFDataRef r1 = rect_data(CGRectMake(0, 0, 100, 150)), r2 = rect_data(CGRectMake(5, 5, 80, 120)),
              r3 = rect_data(CGRectMake(6, 6, 70, 110)), r4 = rect_data(CGRectMake(-10, -10, 400, 400));
    CFDictionarySetValue(page, kCGPDFContextMediaBox, r1);
    CFDictionarySetValue(page, kCGPDFContextCropBox, r2);
    CFDictionarySetValue(page, kCGPDFContextTrimBox, r3);
    CFDictionarySetValue(page, kCGPDFContextBleedBox, r4);
    CFRelease(r1), CFRelease(r2), CFRelease(r3), CFRelease(r4);
    CGPDFContextBeginPage(c, page);
    CFRelease(page);
    print_transform("info-boxes ctm page 2", CGContextGetCTM(c));
    print_rect("info-boxes clip page 2", CGContextGetClipBoundingBox(c)), printf("\n");
    CGPDFContextSetDestinationForRect(c, CFSTR("start"), CGRectMake(1, 2, 3, 4));
    CGPDFContextSetDestinationForRect(c, CFSTR("nowhere"), CGRectMake(1, 2, 3, 4));
    CGContextSetGrayFillColor(c, 0.5, 1);
    CGContextFillEllipseInRect(c, CGRectMake(10, 10, 60, 60));
    CGPDFContextEndPage(c);
    CGRect small = CGRectMake(0, 0, 200, 100);
    CGContextBeginPage(c, &small);
    CGContextEndPage(c);
    CGPDFContextClose(c);
    CGContextRelease(c);
    CGDataConsumerRelease(cons);
    return d;
}

static CFDataRef
w_outline(void)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CGDataConsumerRef cons = CGDataConsumerCreateWithCFData(d);
    CGContextRef c = CGPDFContextCreate(cons, NULL, NULL);
    for (int i = 0; i < 3; i++) {
        CGPDFContextBeginPage(c, NULL);
        CGPDFContextEndPage(c);
    }
    CFMutableDictionaryRef root = mdict(), a = mdict(), b = mdict(), a1 = mdict(), a2 = mdict();
    int one = 1, two = 2, three = 3;
    CFNumberRef n1 = CFNumberCreate(NULL, kCFNumberIntType, &one), n2 = CFNumberCreate(NULL, kCFNumberIntType, &two),
                n3 = CFNumberCreate(NULL, kCFNumberIntType, &three);
    CFDictionarySetValue(a, kCGPDFOutlineTitle, CFSTR("Chapter A"));
    CFDictionarySetValue(a, kCGPDFOutlineDestination, n1);
    CFDictionarySetValue(a1, kCGPDFOutlineTitle, CFSTR("Section é"));
    CFDictionarySetValue(a1, kCGPDFOutlineDestination, n2);
    CFDictionaryRef r = CGRectCreateDictionaryRepresentation(CGRectMake(10, 20, 30, 40));
    CFDictionarySetValue(a1, kCGPDFOutlineDestinationRect, r);
    CFRelease(r);
    CFDictionarySetValue(a2, kCGPDFOutlineTitle, CFSTR("Section 2"));
    CFDictionarySetValue(a2, kCGPDFOutlineDestination, n3);
    const void *akids[2] = {a1, a2};
    CFArrayRef ak = CFArrayCreate(NULL, akids, 2, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(a, kCGPDFOutlineChildren, ak);
    CFDictionarySetValue(b, kCGPDFOutlineTitle, CFSTR("Link"));
    CFURLRef url = CFURLCreateWithString(NULL, CFSTR("https://finch.example/"), NULL);
    CFDictionarySetValue(b, kCGPDFOutlineDestination, url);
    const void *kids[2] = {a, b};
    CFArrayRef ka = CFArrayCreate(NULL, kids, 2, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(root, kCGPDFOutlineChildren, ka);
    CGPDFContextSetOutline(c, root);
    const char *xmp = "<?xpacket begin=''?><x:xmpmeta xmlns:x='adobe:ns:meta/'/><?xpacket end='w'?>";
    CFDataRef meta = CFDataCreate(NULL, (const UInt8 *)xmp, (CFIndex)strlen(xmp));
    CGPDFContextAddDocumentMetadata(c, meta);
    CFRelease(meta);
    CGPDFContextClose(c);
    CGContextRelease(c);
    CGDataConsumerRelease(cons);
    CFRelease(ka), CFRelease(ak), CFRelease(url), CFRelease(n1), CFRelease(n2), CFRelease(n3);
    CFRelease(root), CFRelease(a), CFRelease(b), CFRelease(a1), CFRelease(a2);
    return d;
}

static CFDataRef
encrypted(CFStringRef owner, CFStringRef user, int printing, int copying, int perms)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CGDataConsumerRef cons = CGDataConsumerCreateWithCFData(d);
    CFMutableDictionaryRef aux = mdict();
    CFDictionarySetValue(aux, kCGPDFContextTitle, CFSTR("Secret"));
    if (owner)
        CFDictionarySetValue(aux, kCGPDFContextOwnerPassword, owner);
    if (user)
        CFDictionarySetValue(aux, kCGPDFContextUserPassword, user);
    if (printing >= 0)
        CFDictionarySetValue(aux, kCGPDFContextAllowsPrinting, printing ? kCFBooleanTrue : kCFBooleanFalse);
    if (copying >= 0)
        CFDictionarySetValue(aux, kCGPDFContextAllowsCopying, copying ? kCFBooleanTrue : kCFBooleanFalse);
    if (perms >= 0) {
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &perms);
        CFDictionarySetValue(aux, kCGPDFContextAccessPermissions, n);
        CFRelease(n);
    }
    CGContextRef c = CGPDFContextCreate(cons, NULL, aux);
    CFRelease(aux);
    CGPDFContextBeginPage(c, NULL);
    CGContextSetRGBFillColor(c, 0, 0.5, 0, 1);
    CGContextFillRect(c, CGRectMake(10, 10, 100, 100));
    CGPDFContextEndPage(c);
    CGPDFContextClose(c);
    CGContextRelease(c);
    CGDataConsumerRelease(cons);
    return d;
}

static CFDataRef w_encrypted_user(void) { return encrypted(CFSTR("owner"), CFSTR("user"), -1, -1, -1); }
static CFDataRef w_encrypted_empty(void) { return encrypted(CFSTR("owner"), NULL, 0, 1, -1); }
static CFDataRef w_encrypted_perms(void) { return encrypted(CFSTR("owner"), CFSTR(""), -1, -1, kCGPDFAllowsHighQualityPrinting | kCGPDFAllowsCommenting); }
static CFDataRef w_encrypted_nocopy(void) { return encrypted(CFSTR("owner"), CFSTR(""), 1, 0, -1); }

static CFDataRef
w_output_intent(void)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CGDataConsumerRef cons = CGDataConsumerCreateWithCFData(d);
    CFMutableDictionaryRef aux = mdict(), oi = mdict();
    CFDictionarySetValue(oi, kCGPDFXOutputIntentSubtype, CFSTR("GTS_PDFX"));
    CFDictionarySetValue(oi, kCGPDFXOutputConditionIdentifier, CFSTR("CGATS TR 001"));
    CFDictionarySetValue(oi, kCGPDFXOutputCondition, CFSTR("SWOP"));
    CFDictionarySetValue(oi, kCGPDFXRegistryName, CFSTR("http://www.color.org"));
    CFDictionarySetValue(oi, kCGPDFXInfo, CFSTR("Some info"));
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFDictionarySetValue(oi, kCGPDFXDestinationOutputProfile, srgb);
    CGColorSpaceRelease(srgb);
    CFDictionarySetValue(aux, kCGPDFContextOutputIntent, oi);
    CFRelease(oi);
    CGContextRef c = CGPDFContextCreate(cons, NULL, aux);
    CFRelease(aux);
    CGPDFContextBeginPage(c, NULL);
    CGPDFContextEndPage(c);
    CGPDFContextClose(c);
    CGContextRelease(c);
    CGDataConsumerRelease(cons);
    return d;
}

/* No page begun: the document still has one. Drawing between pages is dropped. */
static CFDataRef
w_no_pages(void)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CGDataConsumerRef cons = CGDataConsumerCreateWithCFData(d);
    CGContextRef c = CGPDFContextCreate(cons, NULL, NULL);
    CGContextSetRGBFillColor(c, 1, 0, 0, 1);
    CGPDFContextClose(c);
    CGContextFillRect(c, CGRectMake(0, 0, 10, 10));  /* after closing: ignored */
    CGPDFContextClose(c);
    CGContextRelease(c);
    CGDataConsumerRelease(cons);
    return d;
}

static CFDataRef
w_between_pages(void)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CGDataConsumerRef cons = CGDataConsumerCreateWithCFData(d);
    CGContextRef c = CGPDFContextCreate(cons, NULL, NULL);
    CGPDFContextBeginPage(c, NULL);
    CGPDFContextEndPage(c);
    CGContextFillRect(c, CGRectMake(0, 0, 10, 10));
    CGPDFContextBeginPage(c, NULL);
    CGPDFContextEndPage(c);
    CGPDFContextClose(c);
    CGContextRelease(c);
    CGDataConsumerRelease(cons);
    return d;
}

static const struct {
    const char *name;
    Writer fn;
    const char *password;
} written[] = {
    {"no-pages", w_no_pages, NULL},
    {"between-pages", w_between_pages, NULL},
    {"plain", w_plain, NULL},
    {"info-boxes", w_info_boxes, NULL},
    {"outline", w_outline, NULL},
    {"encrypted-user", w_encrypted_user, "user"},
    {"encrypted-empty", w_encrypted_empty, "owner"},
    {"encrypted-perms", w_encrypted_perms, "owner"},
    {"encrypted-nocopy", w_encrypted_nocopy, "wrong"},
    {"output-intent", w_output_intent, NULL},
};
#define NWRITTEN (sizeof written / sizeof written[0])

static void
describe_written(const char *name, CFDataRef data, const char *password)
{
    CGPDFDocumentRef doc = document_from_data(data);
    strings_encrypted = doc && !CGPDFDocumentIsUnlocked(doc);
    describe(doc, name);
    if (doc && password) {
        bool ok = CGPDFDocumentUnlockWithPassword(doc, password);
        printf("%s unlock with \"%s\": %d\n", name, password, ok);
        if (CGPDFDocumentIsUnlocked(doc)) {
            char again[64];
            snprintf(again, sizeof again, "%s (unlocked)", name);
            describe(doc, again);
        }
    }
    strings_encrypted = 0;
    CGPDFDocumentRelease(doc);
}

#pragma mark - Hand-written files

/* A file from object bodies ("<< ... >>"), numbered from 1, with a cross-reference table. */
static CFDataRef
build_pdf(const char *version, const char *const *objects, int count, const char *trailer_extra)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    char head[64];
    snprintf(head, sizeof head, "%%PDF-%s\n%%\xe2\xe3\xcf\xd3\n", version);
    CFDataAppendBytes(d, (const UInt8 *)head, (CFIndex)strlen(head));
    long offsets[64];
    for (int i = 0; i < count; i++) {
        offsets[i] = CFDataGetLength(d);
        char h[32];
        snprintf(h, sizeof h, "%d 0 obj\n", i + 1);
        CFDataAppendBytes(d, (const UInt8 *)h, (CFIndex)strlen(h));
        CFDataAppendBytes(d, (const UInt8 *)objects[i], (CFIndex)strlen(objects[i]));
        CFDataAppendBytes(d, (const UInt8 *)"\nendobj\n", 8);
    }
    long xref = CFDataGetLength(d);
    char line[256];
    snprintf(line, sizeof line, "xref\n0 %d\n0000000000 65535 f \n", count + 1);
    CFDataAppendBytes(d, (const UInt8 *)line, (CFIndex)strlen(line));
    for (int i = 0; i < count; i++) {
        snprintf(line, sizeof line, "%010ld 00000 n \n", offsets[i]);
        CFDataAppendBytes(d, (const UInt8 *)line, (CFIndex)strlen(line));
    }
    snprintf(line, sizeof line, "trailer\n<< /Size %d /Root 1 0 R %s >>\nstartxref\n%ld\n%%%%EOF\n", count + 1,
             trailer_extra ? trailer_extra : "", xref);
    CFDataAppendBytes(d, (const UInt8 *)line, (CFIndex)strlen(line));
    return d;
}

static CFDataRef
flate_stream(const char *dict_extra, const unsigned char *data, size_t n)
{
    uLongf zlen = compressBound(n);
    unsigned char *z = malloc(zlen);
    compress2(z, &zlen, data, n, 9);
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    char h[256];
    snprintf(h, sizeof h, "<< /Length %lu /Filter /FlateDecode %s >>\nstream\n", (unsigned long)zlen, dict_extra);
    CFDataAppendBytes(d, (const UInt8 *)h, (CFIndex)strlen(h));
    CFDataAppendBytes(d, z, (CFIndex)zlen);
    CFDataAppendBytes(d, (const UInt8 *)"\nendstream", 10);
    CFDataAppendBytes(d, (const UInt8 *)"", 1);
    free(z);
    return d;
}

static const char *content1 =
    "q 1 0 0 1 10 20 cm 0.5 g 0 0 m 10 0 l 10 10 15 15 20 10 c h f Q\n"
    "/F1 12 Tf BT 72 700 Td (Hello \\(world\\)) Tj [(A) -120 (B) 50.5 <0041>] TJ T* 3 Tr ET\n"
    "/GS1 gs [1 2] 0.5 d /CS0 cs 0.1 0.2 0.3 sc /P1 scn 1 0 0 RG 0 0 1 rg 0.2 0.3 0.4 0.5 k\n"
    "/MC0 << /MCID 3 /Alt (x) >> BDC /Span BMC EMC EMC % a comment\n"
    "true false null /Name#20Esc 1.5e3 -.5 +7 unknownop BX newop 1 2 EX\n"
    "BI /W 2 /H 2 /BPC 8 /CS /G /F /AHx ID 00ff\nff00> EI Q\n"
    "/Im1 Do 0 0 100 100 re W n 1 w 2 J 1 j 4 M 50 i /Perceptual ri\n";

static CFDataRef
r_classic(void)
{
    static char page_content[2048];
    snprintf(page_content, sizeof page_content, "<< /Length %zu >>\nstream\n%s\nendstream", strlen(content1),
             content1);
    const char *objs[] = {
        "<< /Type /Catalog /Pages 2 0 R /PageMode /UseOutlines /Names << /Dests 9 0 R >> /Outlines 10 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 3 /MediaBox [0 0 612 792] /Rotate 90 /Resources << /Font << /F1 7 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /CropBox [10 10 600 780] /ArtBox [700 700 800 800] /Rotate -90 >>",
        page_content,
        "(a string with \\n escapes \\101\\102 and \\\nline continuation)",
        "<< /Type /Pages /Parent 2 0 R /Kids [8 0 R 11 0 R] /Count 2 /MediaBox [100 200 -100 -200] >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /Type /Page /Parent 6 0 R /Contents [4 0 R 4 0 R] /UserUnit 2 /Rotate 450 /TrimBox [0 0 50 50] >>",
        "<< /Names [(dest1) [3 0 R /XYZ 10 20 0] (dest2) [8 0 R /Fit]] >>",
        "<< /Type /Outlines /First 12 0 R /Last 13 0 R /Count 2 >>",
        "<< /Type /Page /Parent 6 0 R /MediaBox [0 0 0 0] /Contents 99 0 R >>",
        "<< /Title (One) /Parent 10 0 R /Next 13 0 R /Dest (dest2) >>",
        "<< /Title <feff00540077006f> /Parent 10 0 R /Prev 12 0 R /A << /S /GoTo /D [3 0 R /FitH 5] >> >>",
        "<< /Title (Info Title) /Author <feff004100fc0074> /Subject (PDFDoc \\200\\226\\240 \\030) /CreationDate (D:20240102030405+05'30') "
        "/ModDate (D:1999) /Keywords (k) /Custom /Name /Num 3.25 /Arr [1 (s) /n] /Bad (D:20241301) /Utc (D:20240102030405Z) "
        "/Neg (D:20240102030405-08'00') /Local (D:20240102030405) >>",
        "<< /S /Indirect /Len 15 0 R >>",
        "42",
    };
    return build_pdf("1.5", objs, 16, "/Info 14 0 R /ID [<00112233445566778899aabbccddeeff> (second)]");
}

/* A cross-reference stream and an object stream (neither filtered), plus a Flate stream with a PNG predictor. */
static CFDataRef
r_xref_stream(void)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    const char *head = "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n";
    CFDataAppendBytes(d, (const UInt8 *)head, (CFIndex)strlen(head));
    long off[8];
    /* 1: the object stream holding 2 (pages) and 3 (page) */
    const char *objs = "2 0 3 70 ";
    const char *o2 = "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 100] >>";
    const char *o3 = "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>";
    char body[512];
    int first = (int)strlen(objs);
    snprintf(body, sizeof body, "%s%-70s%s", objs, o2, o3);
    char obj[1024];
    off[1] = CFDataGetLength(d);
    snprintf(obj, sizeof obj, "1 0 obj\n<< /Type /ObjStm /N 2 /First %d /Length %zu >>\nstream\n%s\nendstream\nendobj\n",
             first, strlen(body), body);
    CFDataAppendBytes(d, (const UInt8 *)obj, (CFIndex)strlen(obj));
    /* 4: content, Flate with the PNG Up predictor over rows of 4 bytes */
    const unsigned char rows[] = {2, 'q', ' ', '1', ' ', 2, 0, 0, 0, 0, 0, 'g', ' ', 'Q', '\n'};
    unsigned char raw[15];
    memcpy(raw, rows, 15);
    /* row 2 is "q 1 " + delta: the predictor adds the row above */
    const char *want = "0 g Q\n";
    (void)want;
    off[4] = CFDataGetLength(d);
    CFDataAppendBytes(d, (const UInt8 *)"4 0 obj\n", 8);
    CFDataRef fs = flate_stream("/DecodeParms << /Predictor 12 /Columns 4 >>", raw, sizeof raw);
    CFDataAppendBytes(d, CFDataGetBytePtr(fs), CFDataGetLength(fs) - 1);
    CFRelease(fs);
    CFDataAppendBytes(d, (const UInt8 *)"\nendobj\n", 8);
    /* 5: the catalog, 6: info */
    off[5] = CFDataGetLength(d);
    const char *o5 = "5 0 obj\n<< /Type /Catalog /Pages 2 0 R /Version /1.8 >>\nendobj\n";
    CFDataAppendBytes(d, (const UInt8 *)o5, (CFIndex)strlen(o5));
    off[6] = CFDataGetLength(d);
    const char *o6 = "6 0 obj\n<< /Producer (xref stream test) >>\nendobj\n";
    CFDataAppendBytes(d, (const UInt8 *)o6, (CFIndex)strlen(o6));
    /* 7: the cross-reference stream, W [1 2 1] */
    off[7] = CFDataGetLength(d);
    unsigned char x[8 * 4];
    int types[8] = {0, 1, 2, 2, 1, 1, 1, 1};
    for (int i = 0; i < 8; i++) {
        long f2 = types[i] == 2 ? 1 : types[i] == 1 ? off[i] : 0;
        int f3 = types[i] == 2 ? (i == 2 ? 0 : 1) : 0;
        if (i == 0)
            f3 = 255;
        x[4 * i] = (unsigned char)types[i];
        x[4 * i + 1] = (unsigned char)(f2 >> 8);
        x[4 * i + 2] = (unsigned char)f2;
        x[4 * i + 3] = (unsigned char)f3;
    }
    snprintf(obj, sizeof obj,
             "7 0 obj\n<< /Type /XRef /Size 8 /W [1 2 1] /Root 5 0 R /Info 6 0 R /Length %d >>\nstream\n",
             (int)sizeof x);
    CFDataAppendBytes(d, (const UInt8 *)obj, (CFIndex)strlen(obj));
    CFDataAppendBytes(d, x, sizeof x);
    snprintf(obj, sizeof obj, "\nendstream\nendobj\nstartxref\n%ld\n%%%%EOF\n", off[7]);
    CFDataAppendBytes(d, (const UInt8 *)obj, (CFIndex)strlen(obj));
    return d;
}

/* An incremental update that replaces the info dictionary and adds a page. */
static CFDataRef
r_incremental(void)
{
    const char *objs[] = {
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] >>",
        "<< /Title (old) >>",
    };
    CFDataRef base = build_pdf("1.4", objs, 4, "/Info 4 0 R");
    CFMutableDataRef d = CFDataCreateMutableCopy(NULL, 0, base);
    const char *b = (const char *)CFDataGetBytePtr(base);
    long prev = 0;
    const char *sx = strstr(b, "startxref\n");
    prev = strtol(sx + 10, NULL, 10);
    long o2 = CFDataGetLength(d);
    const char *n2 = "2 0 obj\n<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>\nendobj\n";
    CFDataAppendBytes(d, (const UInt8 *)n2, (CFIndex)strlen(n2));
    long o4 = CFDataGetLength(d);
    const char *n4 = "4 0 obj\n<< /Title (new) /Author (updated) >>\nendobj\n";
    CFDataAppendBytes(d, (const UInt8 *)n4, (CFIndex)strlen(n4));
    long o5 = CFDataGetLength(d);
    const char *n5 = "5 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Rotate 180 >>\nendobj\n";
    CFDataAppendBytes(d, (const UInt8 *)n5, (CFIndex)strlen(n5));
    long xref = CFDataGetLength(d);
    char t[512];
    snprintf(t, sizeof t,
             "xref\n0 1\n0000000000 65535 f \n2 1\n%010ld 00000 n \n4 2\n%010ld 00000 n \n%010ld 00000 n \n"
             "trailer\n<< /Size 6 /Root 1 0 R /Info 4 0 R /Prev %ld >>\nstartxref\n%ld\n%%%%EOF\n",
             o2, o4, o5, prev, xref);
    CFDataAppendBytes(d, (const UInt8 *)t, (CFIndex)strlen(t));
    CFRelease(base);
    return d;
}

/* A file whose cross-reference offsets are all wrong, and with junk before the header. */
static CFDataRef
r_broken(void)
{
    const char *objs[] = {
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 123 456] /Contents 4 0 R >>",
        "<< /Length 999 >>\nstream\n0 0 1 rg 0 0 10 10 re f\nendstream",
    };
    CFDataRef good = build_pdf("1.2", objs, 4, NULL);
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CFDataAppendBytes(d, (const UInt8 *)"junk\r\n", 6);
    CFDataAppendBytes(d, CFDataGetBytePtr(good), CFDataGetLength(good));
    CFRelease(good);
    return d;
}

/* Streams through each filter. */
static CFDataRef
r_filters(void)
{
    static char lzw_obj[256], hex_obj[256], a85_obj[256], rl_obj[256];
    /* LZW of "-----A---B" (the specification's example) */
    snprintf(lzw_obj, sizeof lzw_obj, "<< /Length 9 /Filter /LZWDecode >>\nstream\n%s\nendstream",
             "\x80\x0B\x60\x50\x22\x0C\x0C\x85\x01");
    snprintf(hex_obj, sizeof hex_obj, "<< /Length 13 /Filter /ASCIIHexDecode >>\nstream\n48 65 6C6c6F7>\nendstream");
    snprintf(a85_obj, sizeof a85_obj, "<< /Length 18 /Filter /ASCII85Decode >>\nstream\n87cURD]i,\"Ebo80~>\nendstream");
    snprintf(rl_obj, sizeof rl_obj, "<< /Length 7 /Filter /RunLengthDecode >>\nstream\n\x02xyz\xfd!\x80\nendstream");
    const char *objs[] = {
        "<< /Type /Catalog /Pages 2 0 R /S [3 0 R 4 0 R 5 0 R 6 0 R 7 0 R 8 0 R] >>",
        "<< /Type /Pages /Kids [9 0 R] /Count 1 >>",
        lzw_obj,
        hex_obj,
        a85_obj,
        rl_obj,
        "<< /Length 4 /Filter [/ASCIIHexDecode /DCTDecode] >>\nstream\nFFD8\nendstream",
        "<< /Length 3 /Filter /JBIG2Decode >>\nstream\nabc\nendstream",
        "<< /Type /Page /Parent 2 0 R >>",
    };
    return build_pdf("1.4", objs, 9, NULL);
}

static void
dump_document(const char *name, CFDataRef data)
{
    if (getenv("CGPDF_SAVE")) {
        char path[1024];
        snprintf(path, sizeof path, "%s/%s.pdf", getenv("CGPDF_SAVE"), name);
        FILE *f = fopen(path, "wb");
        if (f) {
            fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), f);
            fclose(f);
        }
    }
    CGPDFDocumentRef doc = document_from_data(data);
    if (!doc) {
        printf("%s: no document\n", name);
        return;
    }
    describe(doc, name);
    CGPDFDictionaryRef cat = CGPDFDocumentGetCatalog(doc);
    if (cat) {
        printf("%s catalog ", name);
        print_dict(cat, 0);
        printf("\n");
    }
    CGPDFDictionaryRef info = CGPDFDocumentGetInfo(doc);
    if (info) {
        printf("%s info ", name);
        print_dict(info, 0);
        printf("\n");
        const char *dates[] = {"CreationDate", "ModDate", "Bad", "Utc", "Neg", "Local", "Title"};
        for (int i = 0; i < 7; i++) {
            CGPDFStringRef s;
            if (!CGPDFDictionaryGetString(info, dates[i], &s))
                continue;
            CFDateRef date = CGPDFStringCopyDate(s);
            printf("%s date %s: ", name, dates[i]);
            if (date) {
                printf("%.0f\n", CFDateGetAbsoluteTime(date));
                CFRelease(date);
            } else {
                printf("none\n");
            }
        }
        const char *texts[] = {"Title", "Author", "Subject"};
        for (int i = 0; i < 3; i++)
            print_info_string(info, texts[i], name);
        /* accessors on wrong types and missing keys */
        CGPDFInteger iv = -1;
        CGPDFReal rv = -1;
        const char *nv = NULL;
        printf("%s accessors: num-as-int %d num-as-real %d (%.2f) name %d (%s) missing %d bool-on-string %d\n", name,
               CGPDFDictionaryGetInteger(info, "Num", &iv), CGPDFDictionaryGetNumber(info, "Num", &rv), rv,
               CGPDFDictionaryGetName(info, "Custom", &nv), nv ? nv : "", CGPDFDictionaryGetObject(info, "Nope", NULL),
               CGPDFDictionaryGetBoolean(info, "Title", NULL));
        CGPDFArrayRef arr;
        if (CGPDFDictionaryGetArray(info, "Arr", &arr)) {
            CGPDFInteger a0 = 0;
            CGPDFReal a0r = 0;
            printf("%s array accessors: int %d real %d (%.1f) string-as-name %d out-of-range %d null %d\n", name,
                   CGPDFArrayGetInteger(arr, 0, &a0), CGPDFArrayGetNumber(arr, 0, &a0r), a0r,
                   CGPDFArrayGetName(arr, 1, NULL), CGPDFArrayGetObject(arr, 9, NULL), CGPDFArrayGetNull(arr, 0));
        }
    }
    printf("%s object type of NULL: %d, value of NULL: %d\n", name, (int)CGPDFObjectGetType(NULL),
           CGPDFObjectGetValue(NULL, kCGPDFObjectTypeInteger, NULL));
    for (size_t p = 1; p <= CGPDFDocumentGetNumberOfPages(doc); p++) {
        CGPDFPageRef page = CGPDFDocumentGetPage(doc, p);
        printf("%s page %zu dict ", name, p);
        print_dict(CGPDFPageGetDictionary(page), 0);
        printf("\n");
        printf("%s page %zu document matches %d\n", name, p, CGPDFPageGetDocument(page) == doc);
    }
    printf("%s page 0: %s, page past end: %s\n", name, CGPDFDocumentGetPage(doc, 0) ? "page" : "NULL",
           CGPDFDocumentGetPage(doc, CGPDFDocumentGetNumberOfPages(doc) + 1) ? "page" : "NULL");
    CGPDFDocumentRelease(doc);
}

#pragma mark - Scanner traces

static CGPDFScannerRef current;

static void
pop_all(CGPDFScannerRef s)
{
    CGPDFObjectRef stack[64];
    int n = 0;
    while (n < 64 && CGPDFScannerPopObject(s, &stack[n]))
        n++;
    for (int i = n - 1; i >= 0; i--) {
        printf(" ");
        print_object(stack[i], 1);
    }
}

#define OPS(X)                                                                                                      \
    X(b, "b") X(B, "B") X(bstar, "b*") X(Bstar, "B*") X(BDC, "BDC") X(BI, "BI") X(BMC, "BMC") X(BT, "BT")           \
    X(BX, "BX") X(c, "c") X(cm, "cm") X(CS, "CS") X(cs, "cs") X(d, "d") X(d0, "d0") X(d1, "d1") X(Do, "Do")         \
    X(DP, "DP") X(EI, "EI") X(EMC, "EMC") X(ET, "ET") X(EX, "EX") X(f, "f") X(F, "F") X(fstar, "f*") X(G, "G")      \
    X(g, "g") X(gs, "gs") X(h, "h") X(i, "i") X(ID, "ID") X(j, "j") X(J, "J") X(K, "K") X(k, "k") X(l, "l")         \
    X(m, "m") X(M, "M") X(MP, "MP") X(n, "n") X(q, "q") X(Q, "Q") X(re, "re") X(RG, "RG") X(rg, "rg") X(ri, "ri")   \
    X(s, "s") X(S, "S") X(SC, "SC") X(sc, "sc") X(SCN, "SCN") X(scn, "scn") X(sh, "sh") X(Tstar, "T*")             \
    X(Tc, "Tc") X(Td, "Td") X(TD, "TD") X(Tf, "Tf") X(Tj, "Tj") X(TJ, "TJ") X(TL, "TL") X(Tm, "Tm") X(Tr, "Tr")      \
    X(Ts, "Ts") X(Tw, "Tw") X(Tz, "Tz") X(v, "v") X(w, "w") X(W, "W") X(Wstar, "W*") X(y, "y") X(quote, "'")       \
    X(dquote, "\"") X(unknownop, "unknownop") X(newop, "newop")

#define CALLBACK(id, name)                                                                                          \
    static void op_##id(CGPDFScannerRef s, void *info)                                                             \
    {                                                                                                               \
        printf("%s op %s:", (const char *)info, name);                                                             \
        pop_all(s);                                                                                                 \
        printf("\n");                                                                                               \
    }
OPS(CALLBACK)

/* "Do" also looks its operand up in the resources; "q" stops the scan after the third. */
static int q_count;

static void
op_Do_lookup(CGPDFScannerRef s, void *info)
{
    const char *name = NULL;
    CGPDFScannerPopName(s, &name);
    CGPDFObjectRef o = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(s), "XObject", name ? name : "");
    printf("%s op Do: /%s resource %s\n", (const char *)info, name ? name : "?",
           o ? (CGPDFObjectGetType(o) == kCGPDFObjectTypeStream ? "stream" : "other") : "missing");
}

static void
op_q_stop(CGPDFScannerRef s, void *info)
{
    printf("%s op q\n", (const char *)info);
    if (++q_count == 1)
        CGPDFScannerStop(s);
}

/* The typed pops: what each says about the operands of "Tf" and "TJ". */
static void
op_Tf_typed(CGPDFScannerRef s, void *info)
{
    CGPDFInteger i = 0;
    CGPDFReal r = 0;
    const char *n = NULL;
    bool a = CGPDFScannerPopInteger(s, &i);
    bool b2 = CGPDFScannerPopNumber(s, &r);
    bool c = CGPDFScannerPopName(s, &n);
    bool d = CGPDFScannerPopName(s, &n);
    printf("%s op Tf typed: int %d (%ld) number %d (%.1f) name %d (%s) empty %d\n", (const char *)info, a, i, b2, r, c,
           n ? n : "", d);
}

static void
trace(const char *name, CGPDFContentStreamRef cs, int variant)
{
    CGPDFOperatorTableRef t = CGPDFOperatorTableCreate();
#define REGISTER(id, opname) CGPDFOperatorTableSetCallback(t, opname, op_##id);
    OPS(REGISTER)
    if (variant == 1) {
        CGPDFOperatorTableSetCallback(t, "Do", op_Do_lookup);
        CGPDFOperatorTableSetCallback(t, "q", op_q_stop);
        CGPDFOperatorTableSetCallback(t, "Tf", op_Tf_typed);
    }
    q_count = 0;
    CGPDFScannerRef s = CGPDFScannerCreate(cs, t, (void *)name);
    current = s;
    bool ok = CGPDFScannerScan(s);
    printf("%s scan returned %d\n", name, ok);
    CGPDFScannerRelease(s);
    CGPDFOperatorTableRelease(t);
}

static void
traces(CFDataRef data, const char *name)
{
    CGPDFDocumentRef doc = document_from_data(data);
    if (!doc)
        return;
    for (size_t p = 1; p <= CGPDFDocumentGetNumberOfPages(doc); p++) {
        CGPDFPageRef page = CGPDFDocumentGetPage(doc, p);
        CGPDFContentStreamRef cs = CGPDFContentStreamCreateWithPage(page);
        CFArrayRef streams = CGPDFContentStreamGetStreams(cs);
        char label[128];
        snprintf(label, sizeof label, "%s page %zu", name, p);
        printf("%s streams %ld\n", label, streams ? (long)CFArrayGetCount(streams) : -1L);
        CGPDFObjectRef font = CGPDFContentStreamGetResource(cs, "Font", "F1");
        printf("%s resource F1: %s\n", label, font ? "found" : "missing");
        trace(label, cs, 0);
        if (p == 1) {
            snprintf(label, sizeof label, "%s page %zu (stop)", name, p);
            trace(label, cs, 1);
            /* a form-like stream with its own resources and the page as parent */
            CGPDFStreamRef first = streams && CFArrayGetCount(streams) ? (CGPDFStreamRef)CFArrayGetValueAtIndex(streams, 0) : NULL;
            if (first) {
                CGPDFContentStreamRef child = CGPDFContentStreamCreateWithStream(first, CGPDFPageGetDictionary(page), cs);
                printf("%s child resource F1: %s\n", label,
                       CGPDFContentStreamGetResource(child, "Font", "F1") ? "found" : "missing");
                CGPDFContentStreamRelease(child);
            }
        }
        CGPDFContentStreamRelease(cs);
    }
    CGPDFDocumentRelease(doc);
}

#pragma mark - Drawing transforms

static void
drawing_transforms(void)
{
    const char *objs[] = {
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /CropBox [10 10 190 90] >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [50 60 650 860] /Rotate 90 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Rotate 270 /CropBox [-20 -20 50 200] >>",
    };
    CFDataRef data = build_pdf("1.4", objs, 5, NULL);
    CGPDFDocumentRef doc = document_from_data(data);
    CFRelease(data);
    CGRect rects[] = {CGRectMake(0, 0, 400, 400), CGRectMake(10, 20, 100, 300), CGRectMake(0, 0, 50, 50),
                      CGRectMake(-5, 5, 1000, 100)};
    int rotations[] = {0, 90, -90, 180, 45, 360};
    for (size_t p = 1; p <= 3; p++) {
        CGPDFPageRef page = CGPDFDocumentGetPage(doc, p);
        for (int r = 0; r < 4; r++)
            for (int rot = 0; rot < 6; rot++)
                for (int keep = 0; keep < 2; keep++)
                    for (int box = 0; box < 2; box++) {
                        char label[128];
                        snprintf(label, sizeof label, "transform page %zu rect %d rotate %d keep %d box %d", p, r,
                                 rotations[rot], keep, box);
                        print_transform(label, CGPDFPageGetDrawingTransform(page, (CGPDFBox)box, rects[r],
                                                                            rotations[rot], keep));
                    }
    }
    printf("transform NULL page: ");
    print_transform("", CGPDFPageGetDrawingTransform(NULL, kCGPDFMediaBox, rects[0], 0, true));
    print_rect("box of NULL page", CGPDFPageGetBoxRect(NULL, kCGPDFMediaBox)), printf("\n");
    print_rect("box 7", CGPDFPageGetBoxRect(CGPDFDocumentGetPage(doc, 1), (CGPDFBox)7)), printf("\n");
    CGPDFDocumentRelease(doc);
}

#pragma mark - Rendering

#define SIZE 64

static CGContextRef
bitmap(void)
{
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, SIZE, SIZE, 8, 0, rgb, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(rgb);
    return c;
}

static unsigned char *
pixels_of(CGContextRef c)
{
    unsigned char *out = malloc(SIZE * SIZE * 4);
    const unsigned char *d = CGBitmapContextGetData(c);
    size_t bpr = CGBitmapContextGetBytesPerRow(c);
    for (int y = 0; y < SIZE; y++)
        memcpy(out + y * SIZE * 4, d + (size_t)y * bpr, SIZE * 4);
    return out;
}

static int render_failures;

static int
compare(const char *name, const unsigned char *ref, const unsigned char *got, double edge_limit)
{
    int interior_max = 0, edges = 0, bad = 0;
    double edge_sum = 0;
    for (int y = 0; y < SIZE; y++)
        for (int x = 0; x < SIZE; x++) {
            const unsigned char *r = ref + 4 * (y * SIZE + x), *g = got + 4 * (y * SIZE + x);
            int flat = 1;
            for (int dy = -1; dy <= 1 && flat; dy++)
                for (int dx = -1; dx <= 1 && flat; dx++) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= SIZE || ny >= SIZE)
                        continue;
                    flat = !memcmp(r, ref + 4 * (ny * SIZE + nx), 4);
                }
            int diff = 0;
            for (int k = 0; k < 4; k++)
                diff = abs(r[k] - g[k]) > diff ? abs(r[k] - g[k]) : diff;
            if (flat) {
                interior_max = diff > interior_max ? diff : interior_max;
            } else {
                edges++;
                edge_sum += diff;
                bad += diff > 96;
            }
        }
    if (getenv("CGPDF_DUMP") && strstr(name, getenv("CGPDF_DUMP")))
        for (int y = 0; y < SIZE; y++) {
            for (int x = 0; x < SIZE; x++)
                putchar(" .:-=+*#%@"[ref[4 * (y * SIZE + x) + 3] * 9 / 255]);
            printf("   ");
            for (int x = 0; x < SIZE; x++)
                putchar(" .:-=+*#%@"[got[4 * (y * SIZE + x) + 3] * 9 / 255]);
            printf("\n");
        }
    if (getenv("CGPDF_RAW") && getenv("CGPDF_DUMP") && strstr(name, getenv("CGPDF_DUMP"))) {
        char path[1024];
        snprintf(path, sizeof path, "%s/ref.rgba", getenv("CGPDF_RAW"));
        FILE *f = fopen(path, "wb");
        if (f)
            fwrite(ref, 1, SIZE * SIZE * 4, f), fclose(f);
        snprintf(path, sizeof path, "%s/got.rgba", getenv("CGPDF_RAW"));
        f = fopen(path, "wb");
        if (f)
            fwrite(got, 1, SIZE * SIZE * 4, f), fclose(f);
    }
    double edge_mean = edges ? edge_sum / edges : 0;
    int ok = interior_max <= 3 && edge_mean <= edge_limit && bad <= edges / 25 + 2;
    if (ok)
        printf("%s: ok\n", name);
    else
        printf("%s: DIFFERS (flat max %d, edge mean %.1f, edge outliers %d of %d)\n", name, interior_max, edge_mean, bad,
               edges);
    render_failures += !ok;
    return ok;
}

static CGFontRef
test_font(void)
{
    static CGFontRef font;
    if (font)
        return font;
    const char *dirs[] = {getenv("FINCH_TEST_FONTS"), "/usr/local/share/finch/test-fonts",
                          "build/src/skia/resources/fonts", "../../build/src/skia/resources/fonts"};
    for (unsigned i = 0; i < sizeof dirs / sizeof dirs[0] && !font; i++) {
        if (!dirs[i])
            continue;
        char path[1024];
        snprintf(path, sizeof path, "%s/Roboto-Regular.ttf", dirs[i]);
        CGDataProviderRef p = CGDataProviderCreateWithFilename(path);
        if (p) {
            font = CGFontCreateWithDataProvider(p);
            CGDataProviderRelease(p);
        }
    }
    return font;
}

static CGImageRef
checkerboard(size_t n, int cells)
{
    unsigned char *px = malloc(n * n * 4);
    for (size_t y = 0; y < n; y++)
        for (size_t x = 0; x < n; x++) {
            int on = (int)((x * (size_t)cells / n) + (y * (size_t)cells / n)) % 2;
            unsigned char *p = px + 4 * (y * n + x);
            p[0] = on ? 220 : 20, p[1] = on ? 40 : 160, p[2] = (unsigned char)(x * 255 / (n - 1)), p[3] = 255;
        }
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, px, (CFIndex)(n * n * 4), kCFAllocatorMalloc);
    CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGImageRef im = CGImageCreate(n, n, 8, 32, n * 4, rgb, kCGImageAlphaNoneSkipLast, prov, NULL, false,
                                  kCGRenderingIntentDefault);
    CGColorSpaceRelease(rgb);
    CGDataProviderRelease(prov);
    return im;
}

static void
s_rects(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 1, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(8, 8, 32, 16));
    CGContextSetGrayFillColor(c, 0.5, 1);
    CGContextFillRect(c, CGRectMake(40, 40, 20, 20));
    CGContextSetRGBStrokeColor(c, 0, 0, 1, 1);
    CGContextSetLineWidth(c, 3);
    CGContextStrokeRect(c, CGRectMake(6, 34, 26, 24));
}

static void
s_paths(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 0.1, 0.6, 0.2, 1);
    CGContextAddEllipseInRect(c, CGRectMake(4, 4, 56, 56));
    CGContextAddEllipseInRect(c, CGRectMake(18, 18, 28, 28));
    CGContextEOFillPath(c);
    CGFloat dash[] = {6, 3};
    CGContextSetLineDash(c, 0, dash, 2);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetRGBStrokeColor(c, 0.6, 0, 0.6, 1);
    CGContextSetLineWidth(c, 2.5);
    CGContextMoveToPoint(c, 6, 58);
    CGContextAddCurveToPoint(c, 20, 20, 44, 60, 58, 6);
    CGContextStrokePath(c);
}

static void
s_transform_clip(CGContextRef c)
{
    CGContextTranslateCTM(c, 32, 32);
    CGContextRotateCTM(c, 0.4);
    CGContextScaleCTM(c, 1.2, 0.8);
    CGContextClipToRect(c, CGRectMake(-20, -20, 40, 40));
    CGContextSetRGBFillColor(c, 0.9, 0.5, 0.1, 1);
    CGContextFillEllipseInRect(c, CGRectMake(-30, -30, 50, 50));
}

static void
s_alpha(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 1, 1, 0, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 40, 40));
    CGContextSetRGBFillColor(c, 0, 0, 1, 0.5);
    CGContextFillRect(c, CGRectMake(20, 20, 40, 40));
    CGContextSetAlpha(c, 0.5);
    CGContextSetRGBFillColor(c, 1, 0, 0, 1);
    CGContextFillEllipseInRect(c, CGRectMake(5, 30, 25, 25));
}

static void
s_layer(CGContextRef c)
{
    /* (colours inside a group come back shifted in Apple's own PDFs: grays here) */
    CGContextBeginTransparencyLayer(c, NULL);
    CGContextSetGrayFillColor(c, 0, 1);
    CGContextFillRect(c, CGRectMake(8, 8, 32, 32));
    CGContextSetGrayFillColor(c, 0.5, 1);
    CGContextFillRect(c, CGRectMake(24, 24, 32, 32));
    CGContextEndTransparencyLayer(c);
}

static void
s_image(CGContextRef c)
{
    CGImageRef im = checkerboard(16, 4);
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(8, 8, 48, 48), im);
    CGImageRelease(im);
}

static CGGradientRef
rainbow(void)
{
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = {1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1};
    CGFloat locs[] = {0, 0.4, 1};
    CGGradientRef g = CGGradientCreateWithColorComponents(rgb, comps, locs, 3);
    CGColorSpaceRelease(rgb);
    return g;
}

static void
s_gradients(CGContextRef c)
{
    CGGradientRef g = rainbow();
    CGContextSaveGState(c);
    CGContextClipToRect(c, CGRectMake(0, 0, 64, 30));
    CGContextDrawLinearGradient(c, g, CGPointMake(8, 0), CGPointMake(56, 0), 0);
    CGContextRestoreGState(c);
    CGContextClipToRect(c, CGRectMake(0, 34, 64, 30));
    CGContextDrawRadialGradient(c, g, CGPointMake(32, 48), 2, CGPointMake(32, 48), 20,
                                kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
}

static void
cell(void *info, CGContextRef c)
{
    CGContextSetRGBFillColor(c, 0.2, 0.2, 0.8, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 8, 8));
    CGContextSetRGBFillColor(c, 1, 0.8, 0, 1);
    CGContextFillEllipseInRect(c, CGRectMake(8, 8, 8, 8));
}

static void
s_pattern(CGContextRef c)
{
    CGPatternCallbacks cb = {0, cell, NULL};
    CGPatternRef p = CGPatternCreate(NULL, CGRectMake(0, 0, 16, 16), CGAffineTransformIdentity, 16, 16,
                                     kCGPatternTilingConstantSpacing, true, &cb);
    CGColorSpaceRef ps = CGColorSpaceCreatePattern(NULL);
    CGContextSetFillColorSpace(c, ps);
    CGFloat alpha = 1;
    CGContextSetFillPattern(c, p, &alpha);
    CGContextFillRect(c, CGRectMake(0, 0, 64, 64));
    CGColorSpaceRelease(ps);
    CGPatternRelease(p);
}

static const CGGlyph word[] = {44, 73, 70, 76, 80, 3, 59, 82};

static void
s_text(CGContextRef c)
{
    CGContextSetFont(c, test_font());
    CGContextSetFontSize(c, 18);
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextShowGlyphsAtPoint(c, 3, 24, word, 5);
    CGContextSetTextMatrix(c, CGAffineTransformMake(1, 0.2, -0.1, 1.1, 0, 0));
    CGContextSetRGBFillColor(c, 0.7, 0, 0, 1);
    CGContextShowGlyphsAtPoint(c, 4, 44, word + 3, 4);
}

static void
s_text_stroke(CGContextRef c)
{
    CGContextSetFont(c, test_font());
    CGContextSetFontSize(c, 28);
    CGContextSetTextDrawingMode(c, kCGTextStroke);
    CGContextSetRGBStrokeColor(c, 0, 0.3, 0.8, 1);
    CGContextShowGlyphsAtPoint(c, 2, 20, word, 3);
}

static void
s_cmyk_lab(CGContextRef c)
{
    CGFloat lab_range[] = {-128, 127, -128, 127};
    CGFloat white[] = {0.9642, 1, 0.8249};
    CGColorSpaceRef lab = CGColorSpaceCreateLab(white, NULL, lab_range);
    CGFloat comps[] = {60, 40, 20, 1};
    CGColorRef col = CGColorCreate(lab, comps);
    CGContextSetFillColorWithColor(c, col);
    CGContextFillRect(c, CGRectMake(0, 0, 32, 64));
    CGColorRelease(col);
    CGColorSpaceRelease(lab);
    CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGFloat pc[] = {0.2, 0.7, 0.4, 1};
    col = CGColorCreate(p3, pc);
    CGContextSetFillColorWithColor(c, col);
    CGContextFillRect(c, CGRectMake(32, 0, 32, 64));
    CGColorRelease(col);
    CGColorSpaceRelease(p3);
}

typedef void (*Scene)(CGContextRef);

static void
s_rects_offset(CGContextRef c)
{
    CGContextTranslateCTM(c, 100, -50);
    s_rects(c);
}

static const struct {
    const char *name;
    Scene fn;
    double edge;
} scenes[] = {
    {"rects", s_rects, 16},
    {"paths", s_paths, 16},
    {"transform and clip", s_transform_clip, 16},
    {"alpha", s_alpha, 16},
    {"transparency layer", s_layer, 16},
    {"image", s_image, 26},  /* the default smoothing filters differ */
    {"gradients", s_gradients, 16},
    {"pattern", s_pattern, 20},
    {"text", s_text, 24},
    {"text stroke", s_text_stroke, 24},
    {"lab and p3", s_cmyk_lab, 16},
};
#define NSCENES (sizeof scenes / sizeof scenes[0])

static CFDataRef
scene_pdf(Scene fn, CGRect media)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CGDataConsumerRef cons = CGDataConsumerCreateWithCFData(d);
    CGContextRef c = CGPDFContextCreate(cons, &media, NULL);
    CGPDFContextBeginPage(c, NULL);
    fn(c);
    CGPDFContextEndPage(c);
    CGPDFContextClose(c);
    CGContextRelease(c);
    CGDataConsumerRelease(cons);
    return d;
}

static unsigned char *
render_page(CFDataRef pdf, size_t number)
{
    CGPDFDocumentRef doc = document_from_data(pdf);
    CGContextRef bm = bitmap();
    CGPDFPageRef page = doc ? CGPDFDocumentGetPage(doc, number) : NULL;
    if (page) {
        CGRect media = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
        CGContextTranslateCTM(bm, -media.origin.x, -media.origin.y);
        CGContextDrawPDFPage(bm, page);
    }
    unsigned char *px = pixels_of(bm);
    CGContextRelease(bm);
    CGPDFDocumentRelease(doc);
    return px;
}

static unsigned char *
render_direct(Scene fn)
{
    CGContextRef bm = bitmap();
    fn(bm);
    unsigned char *px = pixels_of(bm);
    CGContextRelease(bm);
    return px;
}

static void
round_trips(const char *read_dir)
{
    for (size_t i = 0; i < NSCENES; i++) {
        CFDataRef pdf = NULL;
        char name[160];
        if (read_dir) {
            char path[1024];
            snprintf(path, sizeof path, "%s/scene-%zu.pdf", read_dir, i);
            CGDataProviderRef p = CGDataProviderCreateWithFilename(path);
            pdf = p ? CGDataProviderCopyData(p) : NULL;
            CGDataProviderRelease(p);
            snprintf(name, sizeof name, "read scene %s", scenes[i].name);
        } else {
            pdf = scene_pdf(scenes[i].fn, CGRectMake(0, 0, SIZE, SIZE));
            snprintf(name, sizeof name, "round trip %s", scenes[i].name);
        }
        if (!pdf) {
            printf("%s: no file\n", name);
            continue;
        }
        unsigned char *ref = render_direct(scenes[i].fn), *got = render_page(pdf, 1);
        compare(name, ref, got, scenes[i].edge);
        free(ref), free(got);
        CFRelease(pdf);
    }
    /* a media box away from the origin: user space is PDF space, not the box's */
    if (!read_dir) {
        CFDataRef pdf = scene_pdf(s_rects_offset, CGRectMake(100, -50, SIZE, SIZE));
        unsigned char *ref = render_direct(s_rects), *got = render_page(pdf, 1);
        compare("round trip offset media box", ref, got, 16);
        free(ref), free(got);
        CFRelease(pdf);
    }
}

/* Hand-written page content against the CG calls it amounts to. */
static void
h_shapes(CGContextRef c)
{
    CGContextSetRGBFillColor(c, 1, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(4, 4, 20, 30));
    CGContextSetGrayFillColor(c, 0.25, 1);
    CGContextMoveToPoint(c, 30, 4);
    CGContextAddLineToPoint(c, 60, 4);
    CGContextAddCurveToPoint(c, 60, 30, 45, 40, 30, 30);
    CGContextClosePath(c);
    CGContextFillPath(c);
    CGContextSetRGBStrokeColor(c, 0, 0, 1, 1);
    CGContextSetLineWidth(c, 4);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextMoveToPoint(c, 6, 60);
    CGContextAddLineToPoint(c, 30, 40);
    CGContextAddLineToPoint(c, 58, 60);
    CGContextStrokePath(c);
}

static void
h_clip_cm(CGContextRef c)
{
    CGContextSaveGState(c);
    CGContextConcatCTM(c, CGAffineTransformMake(0.8, 0.2, -0.2, 0.8, 20, 6));
    CGContextAddEllipseInRect(c, CGRectMake(0, 0, 40, 40));
    CGContextClip(c);
    CGContextSetCMYKFillColor(c, 0, 0, 0, 1, 1);
    CGContextFillRect(c, CGRectMake(0, 0, 64, 64));
    CGContextRestoreGState(c);
    CGContextSetRGBFillColor(c, 0, 0.5, 0, 0.5);
    CGContextFillRect(c, CGRectMake(0, 48, 64, 16));
}

static void
h_image(CGContextRef c)
{
    CGImageRef im = checkerboard(4, 2);
    CGContextDrawImage(c, CGRectMake(8, 8, 48, 48), im);
    CGImageRelease(im);
}

static void
ramp(void *info, const CGFloat *in, CGFloat *out)
{
    out[0] = in[0], out[1] = 0.2, out[2] = 1 - in[0];
}

static void
h_shading(CGContextRef c)
{
    CGFunctionCallbacks cb = {0, ramp, NULL};
    CGFloat domain[] = {0, 1}, range[] = {0, 1, 0, 1, 0, 1};
    CGFunctionRef f = CGFunctionCreate(NULL, 1, domain, 3, range, &cb);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGShadingRef sh = CGShadingCreateAxial(rgb, CGPointMake(8, 0), CGPointMake(56, 0), f, true, true);
    CGContextDrawShading(c, sh);
    CGShadingRelease(sh);
    CGColorSpaceRelease(rgb);
    CGFunctionRelease(f);
}

static void
h_text(CGContextRef c)
{
    CGContextSelectFont(c, "Helvetica", 20, kCGEncodingMacRoman);
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextShowTextAtPoint(c, 4, 24, "Hi!", 3);
}

static const struct {
    const char *name;
    const char *content;
    const char *resources;
    Scene fn;
    double edge;
} handwritten[] = {
    {"shapes", "1 0 0 rg 4 4 20 30 re f 0.25 g 30 4 m 60 4 l 60 30 45 40 30 30 c h f 0 0 1 RG 4 w 1 j 6 60 m 30 40 l 58 60 l S",
     "", h_shapes, 16},
    {"clip and cm",
     "q 0.8 0.2 -0.2 0.8 20 6 cm 0 20 m 0 31.0457 8.9543 40 20 40 c 31.0457 40 40 31.0457 40 20 c 40 8.9543 31.0457 0 20 0 c "
     "8.9543 0 0 8.9543 0 20 c h W n 0 0 0 1 k 0 0 64 64 re f Q /GS0 gs 0 0.5 0 rg 0 48 64 16 re f",
     "/ExtGState << /GS0 << /ca 0.5 >> >>", h_clip_cm, 16},
    {"inline image", NULL, "", h_image, 16},
    {"axial shading", "/Sh0 sh", "/Shading << /Sh0 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [8 0 56 0] "
     "/Function << /FunctionType 2 /Domain [0 1] /C0 [0 0.2 1] /C1 [1 0.2 0] /N 1 >> /Extend [true true] >> >>",
     h_shading, 16},
    {"standard font text", "BT /F1 20 Tf 4 24 Td (Hi!) Tj ET",
     "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /MacRomanEncoding >> >>", h_text, 30},
};
#define NHAND (sizeof handwritten / sizeof handwritten[0])

static void
handwritten_pages(void)
{
    for (size_t i = 0; i < NHAND; i++) {
        static char content[4096], page[512], body[2048];
        const char *text = handwritten[i].content;
        if (!text) {
            /* checkerboard(4, 2) as an inline image */
            char *p = body + sprintf(body, "q 48 0 0 48 8 8 cm BI /W 4 /H 4 /BPC 8 /CS /RGB /F /AHx ID ");
            for (int y = 0; y < 4; y++)
                for (int x = 0; x < 4; x++) {
                    int on = (x * 2 / 4 + y * 2 / 4) % 2;
                    p += sprintf(p, "%02x%02x%02x ", on ? 220 : 20, on ? 40 : 160, x * 255 / 3);
                }
            strcpy(p, "> EI Q");
            text = body;
        }
        snprintf(content, sizeof content, "<< /Length %zu >>\nstream\n%s\nendstream", strlen(text), text);
        snprintf(page, sizeof page, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] /Contents 4 0 R /Resources << %s >> >>",
                 handwritten[i].resources);
        const char *objs[] = {"<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", page,
                              content};
        CFDataRef pdf = build_pdf("1.4", objs, 4, NULL);
        unsigned char *ref = render_direct(handwritten[i].fn), *got = render_page(pdf, 1);
        char name[128];
        snprintf(name, sizeof name, "hand-written %s", handwritten[i].name);
        compare(name, ref, got, handwritten[i].edge);
        free(ref), free(got);
        CFRelease(pdf);
    }
}

#pragma mark - Pages against Apple's renders

/*
 * Hand-written pages for the interpreter's features, drawn with
 * CGContextDrawPDFPage and compared with renders by Apple's CoreGraphics
 * (cgpdf-reference.bin, written on macOS with --write-reference).
 */
typedef struct {
    CFMutableDataRef d;
    long off[64];
    int n;
} Builder;

static void
b_begin(Builder *b)
{
    b->d = CFDataCreateMutable(NULL, 0);
    b->n = 0;
    const char *head = "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n";
    CFDataAppendBytes(b->d, (const UInt8 *)head, (CFIndex)strlen(head));
}

static void
b_append(Builder *b, const void *bytes, size_t n)
{
    CFDataAppendBytes(b->d, bytes, (CFIndex)n);
}

/* The next object, from text. Returns its number. */
static int
b_obj(Builder *b, const char *text)
{
    int num = ++b->n;
    b->off[num] = CFDataGetLength(b->d);
    char h[32];
    snprintf(h, sizeof h, "%d 0 obj\n", num);
    b_append(b, h, strlen(h));
    b_append(b, text, strlen(text));
    b_append(b, "\nendobj\n", 8);
    return num;
}

static int
b_stream(Builder *b, const char *dict, const void *bytes, size_t n)
{
    int num = ++b->n;
    b->off[num] = CFDataGetLength(b->d);
    char h[1024];
    snprintf(h, sizeof h, "%d 0 obj\n<< %s /Length %zu >>\nstream\n", num, dict, n);
    b_append(b, h, strlen(h));
    b_append(b, bytes, n);
    b_append(b, "\nendstream\nendobj\n", 18);
    return num;
}

static CFDataRef
b_finish(Builder *b)
{
    long xref = CFDataGetLength(b->d);
    char line[128];
    snprintf(line, sizeof line, "xref\n0 %d\n0000000000 65535 f \n", b->n + 1);
    b_append(b, line, strlen(line));
    for (int i = 1; i <= b->n; i++) {
        snprintf(line, sizeof line, "%010ld 00000 n \n", b->off[i]);
        b_append(b, line, strlen(line));
    }
    snprintf(line, sizeof line, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%ld\n%%%%EOF\n", b->n + 1, xref);
    b_append(b, line, strlen(line));
    return b->d;
}

static CFDataRef
font_bytes(void)
{
    static CFDataRef data;
    if (data)
        return data;
    const char *dirs[] = {getenv("FINCH_TEST_FONTS"), "/usr/local/share/finch/test-fonts",
                          "build/src/skia/resources/fonts", "../../build/src/skia/resources/fonts"};
    for (unsigned i = 0; i < sizeof dirs / sizeof dirs[0] && !data; i++) {
        if (!dirs[i])
            continue;
        char path[1024];
        snprintf(path, sizeof path, "%s/Roboto-Regular.ttf", dirs[i]);
        CGDataProviderRef p = CGDataProviderCreateWithFilename(path);
        if (p) {
            data = CGDataProviderCopyData(p);
            CGDataProviderRelease(p);
        }
    }
    return data;
}

/*
 * A one-page document: objects 1-4 are the catalog, the page tree, the
 * page (64 x 64) and its content; `extra` adds objects from 5 on, and
 * `resources` refers to them.
 */
typedef void (*Extra)(Builder *b);

static CFDataRef
ref_page(const char *content, const char *resources, Extra extra)
{
    Builder b;
    b_begin(&b);
    b_obj(&b, "<< /Type /Catalog /Pages 2 0 R >>");
    b_obj(&b, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    char page[2048];
    snprintf(page, sizeof page, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] /Contents 4 0 R /Resources << %s >> >>",
             resources);
    b_obj(&b, page);
    b_stream(&b, "", content, strlen(content));
    if (extra)
        extra(&b);
    return b_finish(&b);
}

static void
x_tiling(Builder *b)
{
    const char *cell = "0.9 0.2 0.1 rg 0 0 6 6 re f 0.1 0.3 0.9 rg 6 6 6 6 re f";
    b_stream(b, "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 12 12] /XStep 12 /YStep 12 /Resources << >> "
                "/Matrix [1 0 0 1 2 3]", cell, strlen(cell));
    const char *stencil = "0 0 m 8 0 l 4 8 l h f";
    b_stream(b, "/PatternType 1 /PaintType 2 /TilingType 1 /BBox [0 0 8 8] /XStep 10 /YStep 10 /Resources << >>",
             stencil, strlen(stencil));
}

static void
x_shading_pattern(Builder *b)
{
    b_obj(b, "<< /PatternType 2 /Matrix [1 0 0 1 32 32] /Shading << /ShadingType 3 /ColorSpace /DeviceRGB "
             "/Coords [0 0 2 0 0 30] /Extend [true true] /Function << /FunctionType 3 /Domain [0 1] /Bounds [0.5] "
             "/Encode [0 1 0 1] /Functions [<< /FunctionType 2 /Domain [0 1] /C0 [1 1 0] /C1 [1 0 0] /N 1 >> "
             "<< /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 2 >>] >> >> >>");
}

static void
x_sampled(Builder *b)
{
    /* a sampled function: 4 RGB samples, 8 bits each */
    unsigned char samples[] = {255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0};
    b_stream(b, "/FunctionType 0 /Domain [0 1] /Range [0 1 0 1 0 1] /Size [4] /BitsPerSample 8", samples, sizeof samples);
    const char *ps = "{ dup 0.5 gt { pop 1 0.5 } { 2 mul 0 } ifelse 0.25 }";
    b_stream(b, "/FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1]", ps, strlen(ps));
}

static void
x_function_shading(Builder *b)
{
    const char *ps = "{ 2 copy mul 3 1 roll exch pop 0.5 }";
    b_stream(b, "/FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1]", ps, strlen(ps));
}

static void
x_gouraud(Builder *b)
{
    /* free-form triangles: flag, x, y (16 bits), r g b (8 bits) */
    unsigned char t[] = {0, 0x00, 0x00, 0x00, 0x00, 255, 0, 0, 0, 0xff, 0xff, 0x00, 0x00, 0, 255, 0,
                         0, 0x80, 0x00, 0xff, 0xff, 0, 0, 255, 1, 0x00, 0x00, 0xff, 0xff, 255, 255, 0};
    b_stream(b, "/ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 16 /BitsPerComponent 8 /BitsPerFlag 8 "
                "/Decode [0 64 0 64 0 1 0 1 0 1]", t, sizeof t);
}

static void
x_coons(Builder *b)
{
    /* one Coons patch: 12 points (8-bit coordinates) and 4 colours */
    unsigned char t[] = {0, 4, 4, 20, 0, 44, 8, 60, 4, 64, 24, 56, 44, 60, 60, 44, 64, 24, 56, 4, 60, 8, 44, 0, 20,
                         255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0};
    b_stream(b, "/ShadingType 6 /ColorSpace /DeviceRGB /BitsPerCoordinate 8 /BitsPerComponent 8 /BitsPerFlag 8 "
                "/Decode [0 255 0 255 0 1 0 1 0 1]", t, sizeof t);
}

static void
x_images(Builder *b)
{
    /* 5: indexed, 2 bits; 6: RGB with 7: a soft mask; 8: a stencil */
    unsigned char idx[] = {0x1b, 0xe4, 0x6c, 0x93};
    b_stream(b, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /BitsPerComponent 2 "
                "/ColorSpace [/Indexed /DeviceRGB 3 <ff0000 00ff00 0000ff ffff00>]", idx, sizeof idx);
    unsigned char rgb[16 * 3];
    for (int i = 0; i < 16; i++)
        rgb[3 * i] = (unsigned char)(i * 16), rgb[3 * i + 1] = 80, rgb[3 * i + 2] = (unsigned char)(255 - i * 16);
    b_stream(b, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /BitsPerComponent 8 /ColorSpace /DeviceRGB "
                "/SMask 7 0 R", rgb, sizeof rgb);
    unsigned char alpha[16];
    for (int i = 0; i < 16; i++)
        alpha[i] = (unsigned char)((i % 4) * 85);
    b_stream(b, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /BitsPerComponent 8 /ColorSpace /DeviceGray", alpha,
             sizeof alpha);
    unsigned char stencil[] = {0x3c, 0x66, 0xc3, 0x81, 0x81, 0xc3, 0x66, 0x3c};
    b_stream(b, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ImageMask true /Decode [1 0]", stencil,
             sizeof stencil);
}

static void
x_forms(Builder *b)
{
    const char *form = "1 0 0 rg 0 0 20 20 re f 0 0 1 rg 10 10 20 20 re f";
    b_stream(b, "/Type /XObject /Subtype /Form /BBox [0 0 25 25] /Matrix [1.2 0.3 -0.3 1.2 8 4] "
                "/Group << /S /Transparency >>", form, strlen(form));
    b_obj(b, "<< /ca 0.5 /BM /Multiply >>");
}

static void
x_soft_mask(Builder *b)
{
    const char *g = "/Sh0 sh";
    b_stream(b, "/Type /XObject /Subtype /Form /BBox [0 0 64 64] /Group << /S /Transparency /CS /DeviceGray >> "
                "/Resources << /Shading << /Sh0 << /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 64 0] "
                "/Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> >> >> >>",
             g, strlen(g));
    b_obj(b, "<< /SMask << /S /Luminosity /G 5 0 R >> >>");
}

static void
x_type0(Builder *b)
{
    CFDataRef f = font_bytes();
    if (!f)
        return;
    char dict[128];
    snprintf(dict, sizeof dict, "/Length1 %ld", (long)CFDataGetLength(f));
    b_stream(b, dict, CFDataGetBytePtr(f), (size_t)CFDataGetLength(f));
    b_obj(b, "<< /Type /FontDescriptor /FontName /Roboto /Flags 32 /FontBBox [-737 -271 1148 1056] /ItalicAngle 0 "
             "/Ascent 928 /Descent -244 /CapHeight 711 /StemV 80 /FontFile2 5 0 R >>");
    b_obj(b, "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Roboto /CIDSystemInfo << /Registry (Adobe) "
             "/Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R /DW 600 /CIDToGIDMap /Identity >>");
    b_obj(b, "<< /Type /Font /Subtype /Type0 /BaseFont /Roboto /Encoding /Identity-H /DescendantFonts [7 0 R] >>");
    /* 9: the same file as a simple TrueType font */
    b_obj(b, "<< /Type /Font /Subtype /TrueType /BaseFont /Roboto /FirstChar 32 /LastChar 126 /Encoding /WinAnsiEncoding "
             "/FontDescriptor 6 0 R >>");
}

static void
x_type3(Builder *b)
{
    const char *square = "500 0 0 0 400 400 d1 0 0 400 400 re f";
    const char *tri = "600 0 d0 0.2 0.6 0.2 rg 0 0 m 500 0 l 250 450 l f";
    b_stream(b, "", square, strlen(square));
    b_stream(b, "", tri, strlen(tri));
    b_obj(b, "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 600 600] /FontMatrix [0.001 0 0 0.001 0 0] "
             "/CharProcs << /sq 5 0 R /tri 6 0 R >> /Encoding << /Type /Encoding /Differences [65 /sq /tri] >> "
             "/FirstChar 65 /LastChar 66 /Widths [500 600] /Resources << >> >>");
}

static const struct {
    const char *name;
    const char *content;
    const char *resources;
    Extra extra;
} ref_pages[] = {
    {"separation and devicen",
     "/S1 cs 0.7 sc 0 0 32 64 re f /S2 cs 0.2 0.9 sc 32 0 32 32 re f /S3 cs 1 sc 32 32 32 32 re f",
     "/ColorSpace << /S1 [/Separation /Spot /DeviceRGB << /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0 0.4 0.8] /N 1 >>] "
     "/S2 [/DeviceN [/A /B] /DeviceRGB << /FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1] /Length 22 >>] "
     "/S3 [/Separation /None /DeviceGray << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>] >>",
     NULL},
    /* (no Lab: Apple's converts Lab differently from its own CGColorSpace's colorimetry, which Finch follows) */
    {"calrgb and indexed fills",
     "/C cs 0.2 0.7 0.3 sc 32 0 32 32 re f /I cs 2 sc 0 32 64 32 re f",
     "/ColorSpace << "
     "/C [/CalRGB << /WhitePoint [0.9505 1 1.089] /Gamma [2.2 2.2 2.2] /Matrix [0.4124 0.2126 0.0193 0.3576 0.7152 0.1192 0.1805 0.0722 0.9505] >>] "
     "/I [/Indexed /DeviceRGB 2 <102030 c0a080 3060c0>] >>",
     NULL},
    {"tiling patterns", "/Pattern cs /P0 scn 0 0 64 32 re f /PS cs 0.8 0.1 0.6 /P1 scn 4 36 56 24 re f",
     "/Pattern << /P0 5 0 R /P1 6 0 R >> /ColorSpace << /PS [/Pattern /DeviceRGB] >>", x_tiling},
    {"shading pattern and stitching", "/Pattern cs /P0 scn 2 2 60 60 re f", "/Pattern << /P0 5 0 R >>", x_shading_pattern},
    {"sampled and calculator functions",
     "q 0 0 64 32 re W n /Sh0 sh Q q 0 32 64 32 re W n /Sh1 sh Q",
     "/Shading << /Sh0 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [4 0 60 0] /Function 5 0 R >> "
     "/Sh1 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [4 0 60 0] /Function 6 0 R /Extend [true true] >> >>",
     x_sampled},
    {"function-based shading", "q 64 0 0 64 0 0 cm /Sh0 sh Q",
     "/Shading << /Sh0 << /ShadingType 1 /ColorSpace /DeviceRGB /Domain [0 1 0 1] /Function 5 0 R >> >>",
     x_function_shading},
    {"gouraud triangles", "/Sh0 sh", "/Shading << /Sh0 5 0 R >>", x_gouraud},
    {"coons patch", "/Sh0 sh", "/Shading << /Sh0 5 0 R >>", x_coons},
    {"images", "q 30 0 0 30 2 32 cm /I0 Do Q q 30 0 0 30 32 32 cm /I1 Do Q 0.8 0.2 0.2 rg q 30 0 0 30 2 2 cm /I3 Do Q",
     "/XObject << /I0 5 0 R /I1 6 0 R /I3 8 0 R >>", x_images},
    {"form, group, alpha and blend", "0.9 0.9 0.2 rg 0 0 64 64 re f /G0 gs /F0 Do",
     "/XObject << /F0 5 0 R >> /ExtGState << /G0 6 0 R >>", x_forms},
    {"luminosity soft mask", "/G0 gs 0.1 0.2 0.8 rg 0 0 64 64 re f", "/ExtGState << /G0 6 0 R >>", x_soft_mask},
    {"type 0 font", "BT /F0 18 Tf 2 36 Td <002c00490046> Tj 0 -24 Td 2 Tc 120 Tz <004c0050> Tj ET",
     "/Font << /F0 8 0 R >>", x_type0},
    {"truetype font", "BT /F1 16 Tf 2 40 Td (Finch) Tj 0 -20 Td 1 Tr 0.5 w 0 0 1 RG [(Pd) -300 (f)] TJ ET",
     "/Font << /F1 9 0 R >>", x_type0},
    {"type 3 font", "0.8 0 0 rg BT /T3 40 Tf 2 12 Td (ABA) Tj ET", "/Font << /T3 7 0 R >>", x_type3},
    {"text clip", "BT /F1 40 Tf 7 Tr 2 12 Td (Fi) Tj ET 0 0.5 0 rg 0 0 64 64 re f", "/Font << /F1 9 0 R >>", x_type0},
    {"lines, caps and dashes",
     "4 w 1 J 0 0 1 RG 8 8 m 56 8 l S 2 J [6 4] 0 d 1 0 0 RG 8 20 m 56 20 l S [] 0 d 0 J 2 j 6 w 0 0.6 0 RG "
     "8 30 m 32 56 l 56 30 l S 0.5 g 1 w 10 40 10 10 re B",
     "", NULL},
};
#define NREF (sizeof ref_pages / sizeof ref_pages[0])

/* The DeviceN tint transform's PostScript (its stream is filled in at build time). */
static CFDataRef
build_ref_page(size_t i)
{
    if (i == 0) {
        /* the DeviceN space needs a calculator stream: build that page by hand */
        Builder b;
        b_begin(&b);
        b_obj(&b, "<< /Type /Catalog /Pages 2 0 R >>");
        b_obj(&b, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
        b_obj(&b, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] /Contents 4 0 R /Resources << /ColorSpace << "
                  "/S1 [/Separation /Spot /DeviceRGB << /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0 0.4 0.8] /N 1 >>] "
                  "/S2 [/DeviceN [/A /B] /DeviceRGB 5 0 R] "
                  "/S3 [/Separation /None /DeviceGray << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>] >> >> >>");
        b_stream(&b, "", ref_pages[0].content, strlen(ref_pages[0].content));
        const char *ps = "{ 2 copy mul }";
        b_stream(&b, "/FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1]", ps, strlen(ps));
        return b_finish(&b);
    }
    return ref_page(ref_pages[i].content, ref_pages[i].resources, ref_pages[i].extra);
}

static unsigned char *
render_ref(size_t i)
{
    CFDataRef pdf = build_ref_page(i);
    unsigned char *px = render_page(pdf, 1);
    CFRelease(pdf);
    return px;
}

static int
reference_pages(const char *write_path)
{
    size_t one = SIZE * SIZE * 4, total = one * NREF;
    if (write_path) {
        Dl_info info;
        const char *cg = dladdr((void *)CGContextDrawPDFPage, &info) ? info.dli_fname : "?";
        if (strncmp(cg, "/System/", 8)) {
            fprintf(stderr, "references come from Apple's CoreGraphics (this is %s)\n", cg);
            return 1;
        }
        unsigned char *all = malloc(total);
        for (size_t i = 0; i < NREF; i++) {
            unsigned char *px = render_ref(i);
            memcpy(all + i * one, px, one);
            free(px);
        }
        uLongf zlen = compressBound(total);
        unsigned char *z = malloc(zlen);
        compress2(z, &zlen, all, total, 9);
        FILE *f = fopen(write_path, "wb");
        if (!f)
            return 1;
        fwrite(z, 1, zlen, f);
        fclose(f);
        printf("wrote %zu reference pages\n", NREF);
        return 0;
    }
    const char *paths[] = {getenv("CGPDF_REFERENCE"), "/usr/local/share/finch/cgpdf-reference.bin",
                           "userland/tests/cgpdf-reference.bin", "cgpdf-reference.bin"};
    FILE *f = NULL;
    for (unsigned i = 0; i < sizeof paths / sizeof paths[0] && !f; i++)
        if (paths[i])
            f = fopen(paths[i], "rb");
    if (!f) {
        printf("reference pages: no reference file\n");
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long zlen = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *z = malloc((size_t)zlen), *all = malloc(total);
    fread(z, 1, (size_t)zlen, f);
    fclose(f);
    uLongf len = total;
    if (uncompress(all, &len, z, (uLong)zlen) != Z_OK || len != total) {
        printf("reference pages: the reference doesn't match these pages (regenerate it with --write-reference)\n");
        return 1;
    }
    int failures = 0;
    for (size_t i = 0; i < NREF; i++) {
        unsigned char *px = render_ref(i);
        char name[128];
        snprintf(name, sizeof name, "page %s", ref_pages[i].name);
        double edge = strstr(name, "font") || strstr(name, "text") ? 24 : 16;
        failures += !compare(name, all + i * one, px, edge);
        free(px);
    }
    free(z), free(all);
    return failures;
}

#pragma mark - Main

static void
write_file(const char *dir, const char *name, CFDataRef data)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/%s.pdf", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror(path);
        exit(1);
    }
    fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), f);
    fclose(f);
}

static CFDataRef
read_file(const char *dir, const char *name)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/%s.pdf", dir, name);
    CGDataProviderRef p = CGDataProviderCreateWithFilename(path);
    CFDataRef d = p ? CGDataProviderCopyData(p) : NULL;
    CGDataProviderRelease(p);
    return d;
}

int
main(int argc, char **argv)
{
    int no_path = 0;
    const char *write_dir = NULL, *read_dir = NULL, *write_ref = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--no-path"))
            no_path = 1;
        else if (!strcmp(argv[i], "--write") && i + 1 < argc)
            write_dir = argv[++i];
        else if (!strcmp(argv[i], "--read") && i + 1 < argc)
            read_dir = argv[++i];
        else if (!strcmp(argv[i], "--write-reference") && i + 1 < argc)
            write_ref = argv[++i];
    }
    Dl_info info;
    if (!no_path)
        printf("CoreGraphics: %s\n", dladdr((void *)CGPDFContextCreate, &info) ? info.dli_fname : "?");
    if (write_ref)
        return reference_pages(write_ref);
    if (write_dir) {
        for (size_t i = 0; i < NWRITTEN; i++) {
            CFDataRef d = written[i].fn();
            write_file(write_dir, written[i].name, d);
            CFRelease(d);
        }
        for (size_t i = 0; i < NSCENES; i++) {
            CFDataRef d = scene_pdf(scenes[i].fn, CGRectMake(0, 0, SIZE, SIZE));
            char name[32];
            snprintf(name, sizeof name, "scene-%zu", i);
            write_file(write_dir, name, d);
            CFRelease(d);
        }
        printf("wrote %zu documents\n", NWRITTEN + NSCENES);
        return 0;
    }
    if (read_dir) {
        for (size_t i = 0; i < NWRITTEN; i++) {
            CFDataRef d = read_file(read_dir, written[i].name);
            if (!d) {
                printf("%s: no file\n", written[i].name);
                continue;
            }
            describe_written(written[i].name, d, written[i].password);
            CFRelease(d);
        }
        round_trips(read_dir);
        return render_failures ? 1 : 0;
    }
    for (size_t i = 0; i < NWRITTEN; i++) {
        CFDataRef d = written[i].fn();
        describe_written(written[i].name, d, written[i].password);
        CFRelease(d);
    }
    CFDataRef r;
    r = r_classic(), dump_document("classic", r), traces(r, "classic"), CFRelease(r);
    r = r_xref_stream(), dump_document("xref-stream", r), traces(r, "xref-stream"), CFRelease(r);
    r = r_incremental(), dump_document("incremental", r), CFRelease(r);
    r = r_broken(), dump_document("broken", r), traces(r, "broken"), CFRelease(r);
    r = r_filters(), dump_document("filters", r), CFRelease(r);
    CFDataRef junk = CFDataCreate(NULL, (const UInt8 *)"not a pdf", 9);
    printf("not a pdf: %s\n", document_from_data(junk) ? "document" : "NULL");
    CFRelease(junk);
    drawing_transforms();
    round_trips(NULL);
    handwritten_pages();
    reference_pages(NULL);
    return render_failures ? 1 : 0;
}
