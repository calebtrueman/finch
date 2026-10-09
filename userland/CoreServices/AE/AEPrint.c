/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * AEPrintDescToHandle: descriptors as text, in the AEGizmos-style notation
 * macOS prints (NSAppleEventDescriptor's description is built on it):
 * numbers bare, "TEXT" in quotes, 'utf8'"..." and 'utxt'("..."), type
 * codes in single quotes, lists [ a, b ], records { 'key':value }, Apple
 * events 'clas'\'id  '{ params, &'attr':value } (the attributes every
 * event has are left out), anything else 'type'($HEX$).
 */
#include "AE_Finch.h"

struct buf {
    char *p;
    size_t n, cap;
};

static void
put(struct buf *b, const char *s, size_t n)
{
    if (b->n + n + 1 > b->cap) {
        b->cap = (b->n + n + 1) * 2;
        b->p = realloc(b->p, b->cap);
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}

static void
puts_(struct buf *b, const char *s)
{
    put(b, s, strlen(s));
}

/* 'abcd': stops at a NUL, without the closing quote, as Apple's does. */
static void
put_code(struct buf *b, OSType t)
{
    char s[6] = {'\''};
    int n = 1;
    for (int i = 3; i >= 0; i--) {
        char c = (char)(t >> (i * 8));
        if (!c) {
            put(b, s, n);
            return;
        }
        s[n++] = c;
    }
    s[n++] = '\'';
    put(b, s, n);
}

static void
put_quoted(struct buf *b, const char *s, size_t n)
{
    put(b, "\"", 1);
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '"')
            put(b, "\\", 1);
        put(b, &s[i], 1);
    }
    put(b, "\"", 1);
}

static void print_desc(struct buf *b, const AEDesc *d);

static void
print_items(struct buf *b, const struct ae_items *items, bool keys, const struct ae_items *attrs)
{
    static const AEKeyword hidden[] = {keyEventClassAttr, keyEventIDAttr, keyAddressAttr, keyReturnIDAttr,
                                       keyTransactionIDAttr, keyEventSourceAttr, keyInteractLevelAttr,
                                       keyTimeoutAttr, keyOriginalAddressAttr, keyOptionalKeywordAttr,
                                       'repq'};
    bool first = true;
    puts_(b, " ");
    for (long i = 0; i < items->count; i++) {
        puts_(b, first ? "" : ", ");
        first = false;
        if (keys) {
            put_code(b, items->v[i].key);
            puts_(b, ":");
        }
        print_desc(b, &items->v[i].desc);
    }
    for (long i = 0; attrs && i < attrs->count; i++) {
        bool skip = false;
        for (size_t j = 0; j < sizeof hidden / sizeof *hidden; j++)
            if (attrs->v[i].key == hidden[j])
                skip = true;
        if (skip)
            continue;
        puts_(b, first ? "&" : ", &");
        first = false;
        put_code(b, attrs->v[i].key);
        puts_(b, ":");
        print_desc(b, &attrs->v[i].desc);
    }
    puts_(b, " ");
}

static void
print_desc(struct buf *b, const AEDesc *d)
{
    struct ae_store *s = ae_store(d);
    char tmp[64];
    if (!s) {
        puts_(b, "null()");
        return;
    }
    if (s->kind == AE_LIST) {
        puts_(b, "[");
        print_items(b, &s->items, false, NULL);
        puts_(b, "]");
        return;
    }
    if (s->kind == AE_RECORD) {
        if (d->descriptorType != typeAERecord)
            put_code(b, d->descriptorType);
        puts_(b, "{");
        print_items(b, &s->items, true, NULL);
        puts_(b, "}");
        return;
    }
    if (s->kind == AE_EVENT) {
        OSType cls = 0, eid = 0;
        struct ae_item *c = ae_find(&s->attrs, keyEventClassAttr), *e = ae_find(&s->attrs, keyEventIDAttr);
        if (c)
            AEGetDescData(&c->desc, &cls, 4);
        if (e)
            AEGetDescData(&e->desc, &eid, 4);
        put_code(b, cls);
        puts_(b, "\\");
        put_code(b, eid);
        puts_(b, "{");
        print_items(b, &s->items, true, &s->attrs);
        puts_(b, "}");
        return;
    }
    Size n;
    const unsigned char *p = ae_bytes(d, &n);
    switch (d->descriptorType) {
    case typeSInt16:
        if (n >= 2) { snprintf(tmp, sizeof tmp, "%d", *(const SInt16 *)p); puts_(b, tmp); return; }
        break;
    case typeSInt32:
        if (n >= 4) { snprintf(tmp, sizeof tmp, "%d", *(const SInt32 *)p); puts_(b, tmp); return; }
        break;
    case typeSInt64:
        if (n >= 8) { snprintf(tmp, sizeof tmp, "%lld", *(const SInt64 *)p); puts_(b, tmp); return; }
        break;
    case typeUInt32:
        if (n >= 4) { snprintf(tmp, sizeof tmp, "%u", *(const UInt32 *)p); puts_(b, tmp); return; }
        break;
    case typeUInt64:
        if (n >= 8) { snprintf(tmp, sizeof tmp, "%llu", *(const UInt64 *)p); puts_(b, tmp); return; }
        break;
    case typeIEEE64BitFloatingPoint:
        if (n >= 8) { snprintf(tmp, sizeof tmp, "%g", *(const double *)p); puts_(b, tmp); return; }
        break;
    case typeIEEE32BitFloatingPoint:
        if (n >= 4) { snprintf(tmp, sizeof tmp, "%g", *(const float *)p); puts_(b, tmp); return; }
        break;
    case typeBoolean:
        if (n >= 1) { snprintf(tmp, sizeof tmp, "%d", p[0]); puts_(b, tmp); return; }
        break;
    case typeTrue: puts_(b, "'true'(\"true\")"); return;
    case typeFalse: puts_(b, "'fals'(\"false\")"); return;
    case typeType:
    case typeEnumerated:
        if (n >= 4) { put_code(b, *(const OSType *)p); return; }
        break;
    case typeKeyword:
    case typeProperty:
        if (n >= 4) {
            put_code(b, d->descriptorType);
            puts_(b, "(\"");
            OSType t = *(const OSType *)p;
            char c[4] = {(char)(t >> 24), (char)(t >> 16), (char)(t >> 8), (char)t};
            put(b, c, 4);
            puts_(b, "\")");
            return;
        }
        break;
    case typeChar:
    case typeFileURL: put_quoted(b, (const char *)p, n); return;
    case typeApplicationURL:
        puts_(b, "'aprl'(");
        put_quoted(b, (const char *)p, n);
        puts_(b, ")");
        return;
    case typeUTF8Text:
        puts_(b, "'utf8'");
        put_quoted(b, (const char *)p, n);
        return;
    case typeUnicodeText:
    case typeUTF16ExternalRepresentation: {
        CFStringRef str = d->descriptorType == typeUnicodeText
                              ? CFStringCreateWithBytes(NULL, p, n & ~1, kCFStringEncodingUTF16LE, false)
                              : CFStringCreateWithBytes(NULL, p, n & ~1, kCFStringEncodingUTF16, true);
        if (!str)
            break;
        CFIndex len = CFStringGetLength(str), used = 0;
        CFIndex max = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8);
        char *u = malloc(max + 1);
        CFStringGetBytes(str, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false, (UInt8 *)u, max, &used);
        CFRelease(str);
        if (d->descriptorType == typeUnicodeText) {
            puts_(b, "'utxt'(");
            put_quoted(b, u, used);
            puts_(b, ")");
        } else {
            puts_(b, "'ut16'");
            put_quoted(b, u, used);
        }
        free(u);
        return;
    }
    case typeProcessSerialNumber:
        if (n >= 8) {
            const ProcessSerialNumber *psn = (const ProcessSerialNumber *)p;
            if (psn->highLongOfPSN == 0) {
                snprintf(tmp, sizeof tmp, "[0x0,%x]", (unsigned)psn->lowLongOfPSN);
                puts_(b, tmp);
            }
            return;
        }
        break;
    case typeKernelProcessID:
        if (n >= 4) {
            snprintf(tmp, sizeof tmp, "'kpid'[pid=%d]", *(const pid_t *)p);
            puts_(b, tmp);
            return;
        }
        break;
    case typeNull: puts_(b, "null()"); return;
    }
    put_code(b, d->descriptorType);
    puts_(b, "($");
    for (Size i = 0; i < n; i++) {
        snprintf(tmp, sizeof tmp, "%02X", p[i]);
        puts_(b, tmp);
    }
    puts_(b, "$)");
}

OSStatus
AEPrintDescToHandle(const AEDesc *desc, Handle *result)
{
    if (!desc || !result)
        return paramErr;
    struct buf b = {0};
    puts_(&b, "");
    print_desc(&b, desc);
    OSErr e = PtrToHand(b.p, result, b.n + 1);
    free(b.p);
    return e;
}

