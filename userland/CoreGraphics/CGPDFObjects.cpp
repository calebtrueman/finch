/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * PDF objects (ISO 32000-1 section 7.3): the arena that owns them, the
 * lexer and parser, the public accessors for objects, arrays, dictionaries,
 * strings and streams, text strings and dates, and the stream filters
 * (section 7.4) other than the image codecs.
 */
#include "CGPDFInternal.h"
#include <algorithm>
#include <ctype.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

const CGPDFObject CGPDFNullObject = {kCGPDFObjectTypeNull, {}};

#pragma mark - Arena

CGPDFArena::~CGPDFArena()
{
    for (auto *a : arrays)
        delete a;
    for (auto *d : dicts)
        delete d;
    for (auto *s : streams)
        delete s;
    for (auto *s : strings)
        delete s;
    for (auto *o : objects)
        delete o;
    for (void *b : blocks)
        free(b);
}

CGPDFArray *
CGPDFArena::array(CGPDFDocData *doc)
{
    auto *a = new CGPDFArray{doc, {}};
    arrays.push_back(a);
    return a;
}

CGPDFDictionary *
CGPDFArena::dict(CGPDFDocData *doc)
{
    auto *d = new CGPDFDictionary{doc, {}};
    dicts.push_back(d);
    return d;
}

CGPDFStream *
CGPDFArena::stream(CGPDFDocData *doc)
{
    auto *s = new CGPDFStream{doc, NULL, NULL, 0, 0, 0};
    streams.push_back(s);
    return s;
}

void *
CGPDFArena::alloc(size_t n)
{
    void *b = malloc(n ? n : 1);
    blocks.push_back(b);
    return b;
}

CGPDFString *
CGPDFArena::string(const void *bytes, size_t len)
{
    auto *s = new CGPDFString{len, (unsigned char *)alloc(len + 1)};
    if (len)
        memcpy(s->bytes, bytes, len);
    s->bytes[len] = 0;
    strings.push_back(s);
    return s;
}

CGPDFObject *
CGPDFArena::object(const CGPDFObject &o)
{
    auto *p = new CGPDFObject(o);
    objects.push_back(p);
    return p;
}

const char *
CGPDFArena::name(const char *s, size_t len)
{
    std::string key(s, len);
    auto it = names.find(key);
    if (it != names.end())
        return it->second;
    char *copy = (char *)alloc(len + 1);
    memcpy(copy, s, len);
    copy[len] = 0;
    names.emplace(key, copy);
    return copy;
}

const CGPDFObject *
CGPDFDictionary::find(const char *key) const
{
    for (auto &e : entries)
        if (!strcmp(e.first, key))
            return &e.second;
    return NULL;
}

void
CGPDFDictionary::set(const char *key, const CGPDFObject &o)
{
    for (auto &e : entries)
        if (!strcmp(e.first, key)) {
            e.second = o;
            return;
        }
    entries.emplace_back(key, o);
}

void
CGPDFDictionary::remove(const char *key)
{
    for (size_t i = 0; i < entries.size(); i++)
        if (!strcmp(entries[i].first, key)) {
            entries.erase(entries.begin() + (long)i);
            return;
        }
}

#pragma mark - Lexer and parser

void
CGPDFLexer::skip_space()
{
    while (p < end) {
        if (CGPDFIsSpace(*p)) {
            p++;
        } else if (*p == '%') {
            while (p < end && *p != '\n' && *p != '\r')
                p++;
        } else {
            break;
        }
    }
}

static int
hexval(int c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/* A literal string's bytes, after the opening parenthesis. */
static void
literal_string(CGPDFLexer &lx, std::vector<uint8_t> &out)
{
    int nest = 1;
    while (lx.p < lx.end) {
        uint8_t c = *lx.p++;
        if (c == '(') {
            nest++;
        } else if (c == ')') {
            if (--nest == 0)
                return;
        } else if (c == '\r') {
            /* an end of line in a string is a line feed */
            if (lx.p < lx.end && *lx.p == '\n')
                lx.p++;
            c = '\n';
        } else if (c == '\\' && lx.p < lx.end) {
            c = *lx.p++;
            switch (c) {
            case 'n': c = '\n'; break;
            case 'r': c = '\r'; break;
            case 't': c = '\t'; break;
            case 'b': c = '\b'; break;
            case 'f': c = '\f'; break;
            case '\r':
                if (lx.p < lx.end && *lx.p == '\n')
                    lx.p++;
                continue;
            case '\n': continue;
            default:
                if (c >= '0' && c <= '7') {
                    int v = c - '0';
                    for (int k = 0; k < 2 && lx.p < lx.end && *lx.p >= '0' && *lx.p <= '7'; k++)
                        v = v * 8 + (*lx.p++ - '0');
                    c = (uint8_t)v;
                }
                break;
            }
        }
        out.push_back(c);
    }
}

static void
hex_string(CGPDFLexer &lx, std::vector<uint8_t> &out)
{
    int hi = -1;
    while (lx.p < lx.end) {
        uint8_t c = *lx.p++;
        if (c == '>')
            break;
        int v = hexval(c);
        if (v < 0)
            continue;
        if (hi < 0) {
            hi = v;
        } else {
            out.push_back((uint8_t)(hi << 4 | v));
            hi = -1;
        }
    }
    if (hi >= 0)
        out.push_back((uint8_t)(hi << 4));
}

/* A token that is a number: integer, or real (with a point). */
static bool
number(CGPDFLexer &lx, CGPDFObject &out, bool strict)
{
    const uint8_t *p = lx.p;
    bool neg = false, real = false, digits = false;
    while (p < lx.end && (*p == '+' || *p == '-')) {
        neg ^= *p == '-';
        p++;
    }
    double v = 0, scale = 0;
    long long iv = 0;
    bool overflow = false;
    for (; p < lx.end; p++) {
        if (*p >= '0' && *p <= '9') {
            digits = true;
            if (real) {
                scale /= 10;
                v += (*p - '0') * scale;
            } else {
                v = v * 10 + (*p - '0');
                if (iv > (LLONG_MAX - 9) / 10)
                    overflow = true;
                else
                    iv = iv * 10 + (*p - '0');
            }
        } else if (*p == '.' && !real) {
            real = true;
            scale = 1;
        } else {
            break;
        }
    }
    if (!digits && !real)
        return false;
    /* characters glued to a number ("1.5e3") make it no number in content, and are dropped elsewhere */
    if (strict && p < lx.end && !CGPDFIsSpace(*p) && !CGPDFIsDelimiter(*p))
        return false;
    lx.p = p;
    while (lx.p < lx.end && !CGPDFIsSpace(*lx.p) && !CGPDFIsDelimiter(*lx.p))
        lx.p++;
    if (real || overflow || iv > LONG_MAX) {
        out.type = kCGPDFObjectTypeReal;
        out.r = neg ? -v : v;
    } else {
        out.type = kCGPDFObjectTypeInteger;
        out.i = neg ? -(CGPDFInteger)iv : (CGPDFInteger)iv;
    }
    return true;
}

/* An unsigned integer token at the lexer, without consuming it unless it is one. */
static bool
peek_uint(CGPDFLexer &lx, uint32_t &v)
{
    lx.skip_space();
    const uint8_t *p = lx.p;
    if (p >= lx.end || *p < '0' || *p > '9')
        return false;
    uint64_t n = 0;
    while (p < lx.end && *p >= '0' && *p <= '9')
        n = n * 10 + (uint64_t)(*p++ - '0');
    if (p < lx.end && !CGPDFIsSpace(*p) && !CGPDFIsDelimiter(*p))
        return false;
    if (n > 0xffffffffu)
        return false;
    v = (uint32_t)n;
    lx.p = p;
    return true;
}

static void
stream_data(CGPDFParser &ps, CGPDFDictionary *dict, CGPDFObject &out)
{
    CGPDFLexer &lx = ps.lx;
    /* "stream" is followed by CRLF or LF (a lone CR is tolerated) */
    if (lx.p < lx.end && *lx.p == '\r')
        lx.p++;
    if (lx.p < lx.end && *lx.p == '\n')
        lx.p++;
    const uint8_t *data = lx.p;
    size_t avail = (size_t)(lx.end - data);
    long long len = -1;
    const CGPDFObject *lo = dict->find("Length");
    if (lo && ps.doc)
        lo = ps.doc->resolve(lo);
    if (lo && lo->type == kCGPDFObjectTypeInteger)
        len = lo->i;
    else if (lo && lo->type == kCGPDFObjectTypeReal)
        len = (long long)lo->r;
    auto ends_at = [&](size_t n) {
        const uint8_t *q = data + n, *e = lx.end;
        while (q < e && CGPDFIsSpace(*q))
            q++;
        return e - q >= 9 && !memcmp(q, "endstream", 9);
    };
    size_t n;
    if (len >= 0 && (size_t)len <= avail && ends_at((size_t)len)) {
        n = (size_t)len;
    } else {
        /* a wrong or missing length: up to "endstream", less the end of line before it */
        const uint8_t *q = (const uint8_t *)memmem(data, avail, "endstream", 9);
        n = q ? (size_t)(q - data) : avail;
        if (len >= 0 && (size_t)len < n && !q)
            n = (size_t)len;
    }
    lx.p = data + n;
    lx.skip_space();
    if (lx.end - lx.p >= 9 && !memcmp(lx.p, "endstream", 9))
        lx.p += 9;
    CGPDFStream *s = ps.arena.stream(ps.doc);
    s->dict = dict;
    s->raw = data;
    s->length = n;
    s->num = ps.num, s->gen = ps.gen;
    out.type = kCGPDFObjectTypeStream;
    out.stream = s;
}

bool
CGPDFParser::parse(CGPDFObject &out)
{
    keyword.clear();
    lx.skip_space();
    if (lx.p >= lx.end)
        return false;
    out = CGPDFObject{};
    uint8_t c = *lx.p;
    if (depth > 200)
        return false;
    if (c == '/') {
        lx.p++;
        std::string n;
        while (lx.p < lx.end && !CGPDFIsSpace(*lx.p) && !CGPDFIsDelimiter(*lx.p)) {
            if (*lx.p == '#' && lx.end - lx.p >= 3 && hexval(lx.p[1]) >= 0 && hexval(lx.p[2]) >= 0) {
                n.push_back((char)(hexval(lx.p[1]) << 4 | hexval(lx.p[2])));
                lx.p += 3;
            } else {
                n.push_back((char)*lx.p++);
            }
        }
        out.type = kCGPDFObjectTypeName;
        out.name = arena.name(n.data(), n.size());
        return true;
    }
    if (c == '(' || (c == '<' && (lx.p + 1 >= lx.end || lx.p[1] != '<'))) {
        lx.p++;
        std::vector<uint8_t> bytes;
        if (c == '(')
            literal_string(lx, bytes);
        else
            hex_string(lx, bytes);
        if (doc && num && doc->crypt.encrypted && num != doc->crypt.encrypt_num)
            CGPDFCryptDecrypt(doc, num, gen, false, bytes);
        out.type = kCGPDFObjectTypeString;
        out.string = arena.string(bytes.data(), bytes.size());
        return true;
    }
    if (c == '[') {
        lx.p++;
        CGPDFArray *a = arena.array(doc);
        depth++;
        for (;;) {
            lx.skip_space();
            if (lx.p >= lx.end)
                break;
            if (*lx.p == ']') {
                lx.p++;
                break;
            }
            CGPDFObject item;
            const uint8_t *before = lx.p;
            if (!parse(item)) {
                if (lx.p == before)
                    lx.p++;
                if (!keyword.empty() && !content)
                    break;  /* "endobj" and the like end a broken array */
                continue;
            }
            a->items.push_back(item);
        }
        depth--;
        keyword.clear();
        out.type = kCGPDFObjectTypeArray;
        out.array = a;
        return true;
    }
    if (c == '<') {
        lx.p += 2;
        CGPDFDictionary *d = arena.dict(doc);
        depth++;
        for (;;) {
            lx.skip_space();
            if (lx.p >= lx.end)
                break;
            if (*lx.p == '>') {
                lx.p += lx.p + 1 < lx.end && lx.p[1] == '>' ? 2 : 1;
                break;
            }
            CGPDFObject key;
            const uint8_t *before = lx.p;
            if (!parse(key)) {
                if (lx.p == before)
                    lx.p++;
                if (!keyword.empty() && !content)
                    break;
                continue;
            }
            if (key.type != kCGPDFObjectTypeName)
                continue;
            CGPDFObject value;
            lx.skip_space();
            if (lx.p < lx.end && *lx.p == '>')
                break;
            if (!parse(value)) {
                if (!keyword.empty() && !content)
                    break;
                continue;
            }
            /* a null value is the same as no entry */
            if (value.type != kCGPDFObjectTypeNull)
                d->set(key.name, value);
        }
        depth--;
        keyword.clear();
        /* a stream? */
        const uint8_t *save = lx.p;
        lx.skip_space();
        if (!content && lx.end - lx.p >= 6 && !memcmp(lx.p, "stream", 6) &&
            (lx.p + 6 == lx.end || !isalpha(lx.p[6]))) {
            lx.p += 6;
            stream_data(*this, d, out);
            return true;
        }
        lx.p = save;
        out.type = kCGPDFObjectTypeDictionary;
        out.dict = d;
        return true;
    }
    if ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.') {
        if (!number(lx, out, content)) {
            if (content)
                goto keyword;
            lx.p++;
            return false;
        }
        if (!content && out.type == kCGPDFObjectTypeInteger && out.i >= 0) {
            /* "num gen R"? */
            const uint8_t *save = lx.p;
            uint32_t g;
            if (peek_uint(lx, g)) {
                lx.skip_space();
                if (lx.p < lx.end && *lx.p == 'R' && (lx.p + 1 == lx.end || CGPDFIsSpace(lx.p[1]) ||
                                                      CGPDFIsDelimiter(lx.p[1]))) {
                    lx.p++;
                    uint32_t n = (uint32_t)out.i;
                    out.type = kCGPDFObjectTypeRef;
                    out.ref.num = n;
                    out.ref.gen = g;
                    return true;
                }
            }
            lx.p = save;
        }
        return true;
    }
    if (c == ')' || c == '>' || c == ']' || c == '}' || c == '{') {
        lx.p++;
        keyword.assign(1, (char)c);
        return false;
    }
keyword:
    /* a keyword */
    const uint8_t *s = lx.p;
    while (lx.p < lx.end && !CGPDFIsSpace(*lx.p) && !CGPDFIsDelimiter(*lx.p))
        lx.p++;
    keyword.assign((const char *)s, (size_t)(lx.p - s));
    if (keyword == "true" || keyword == "false") {
        out.type = kCGPDFObjectTypeBoolean;
        out.b = keyword == "true";
        keyword.clear();
        return true;
    }
    if (keyword == "null") {
        out.type = kCGPDFObjectTypeNull;
        keyword.clear();
        return true;
    }
    return false;
}

#pragma mark - Objects

const CGPDFObject *
CGPDFDocData::resolve(const CGPDFObject *o)
{
    for (int hops = 0; o && o->type == kCGPDFObjectTypeRef && hops < 32; hops++) {
        CGPDFObject *r = resolve_ref(o->ref.num, o->ref.gen);
        o = r ? r : &CGPDFNullObject;
    }
    return o;
}

static const CGPDFObject *
resolved(CGPDFDocData *doc, const CGPDFObject *o)
{
    if (o && o->type == kCGPDFObjectTypeRef)
        return doc ? doc->resolve(o) : &CGPDFNullObject;
    return o;
}

CGPDFObjectType
CGPDFObjectGetType(CGPDFObjectRef o)
{
    return o ? (CGPDFObjectType)o->type : kCGPDFObjectTypeNull;
}

static bool
get_value(const CGPDFObject *o, CGPDFObjectType type, void *value)
{
    if (!o)
        return false;
    if (o->type != type) {
        if (o->type == kCGPDFObjectTypeInteger && type == kCGPDFObjectTypeReal) {
            if (value)
                *(CGPDFReal *)value = (CGPDFReal)o->i;
            return true;
        }
        return false;
    }
    if (!value)
        return true;
    switch (type) {
    case kCGPDFObjectTypeNull: break;
    case kCGPDFObjectTypeBoolean: *(CGPDFBoolean *)value = o->b; break;
    case kCGPDFObjectTypeInteger: *(CGPDFInteger *)value = o->i; break;
    case kCGPDFObjectTypeReal: *(CGPDFReal *)value = o->r; break;
    case kCGPDFObjectTypeName: *(const char **)value = o->name; break;
    case kCGPDFObjectTypeString: *(CGPDFStringRef *)value = o->string; break;
    case kCGPDFObjectTypeArray: *(CGPDFArrayRef *)value = o->array; break;
    case kCGPDFObjectTypeDictionary: *(CGPDFDictionaryRef *)value = o->dict; break;
    case kCGPDFObjectTypeStream: *(CGPDFStreamRef *)value = o->stream; break;
    }
    return true;
}

bool
CGPDFObjectGetValue(CGPDFObjectRef o, CGPDFObjectType type, void *value)
{
    return get_value(o, type, value);
}

#pragma mark - Arrays

size_t
CGPDFArrayGetCount(CGPDFArrayRef a)
{
    return a ? a->items.size() : 0;
}

static const CGPDFObject *
array_item(CGPDFArrayRef a, size_t i)
{
    if (!a || i >= a->items.size())
        return NULL;
    return resolved(a->doc, &a->items[i]);
}

bool
CGPDFArrayGetObject(CGPDFArrayRef a, size_t i, CGPDFObjectRef *value)
{
    const CGPDFObject *o = array_item(a, i);
    if (!o)
        return false;
    if (value)
        *value = (CGPDFObjectRef)o;
    return true;
}

bool CGPDFArrayGetNull(CGPDFArrayRef a, size_t i) { return get_value(array_item(a, i), kCGPDFObjectTypeNull, NULL); }
bool CGPDFArrayGetBoolean(CGPDFArrayRef a, size_t i, CGPDFBoolean *v) { return get_value(array_item(a, i), kCGPDFObjectTypeBoolean, v); }
bool CGPDFArrayGetInteger(CGPDFArrayRef a, size_t i, CGPDFInteger *v) { return get_value(array_item(a, i), kCGPDFObjectTypeInteger, v); }
bool CGPDFArrayGetNumber(CGPDFArrayRef a, size_t i, CGPDFReal *v) { return get_value(array_item(a, i), kCGPDFObjectTypeReal, v); }
bool CGPDFArrayGetName(CGPDFArrayRef a, size_t i, const char **v) { return get_value(array_item(a, i), kCGPDFObjectTypeName, v); }
bool CGPDFArrayGetString(CGPDFArrayRef a, size_t i, CGPDFStringRef *v) { return get_value(array_item(a, i), kCGPDFObjectTypeString, v); }
bool CGPDFArrayGetArray(CGPDFArrayRef a, size_t i, CGPDFArrayRef *v) { return get_value(array_item(a, i), kCGPDFObjectTypeArray, v); }
bool CGPDFArrayGetDictionary(CGPDFArrayRef a, size_t i, CGPDFDictionaryRef *v) { return get_value(array_item(a, i), kCGPDFObjectTypeDictionary, v); }
bool CGPDFArrayGetStream(CGPDFArrayRef a, size_t i, CGPDFStreamRef *v) { return get_value(array_item(a, i), kCGPDFObjectTypeStream, v); }

void
CGPDFArrayApplyBlock(CGPDFArrayRef a, CF_NOESCAPE CGPDFArrayApplierBlock block, void *info)
{
    if (!a || !block)
        return;
    for (size_t i = 0; i < a->items.size(); i++)
        if (!block(i, (CGPDFObjectRef)resolved(a->doc, &a->items[i]), info))
            return;
}

#pragma mark - Dictionaries

size_t
CGPDFDictionaryGetCount(CGPDFDictionaryRef d)
{
    return d ? d->entries.size() : 0;
}

static const CGPDFObject *
dict_item(CGPDFDictionaryRef d, const char *key)
{
    if (!d || !key)
        return NULL;
    /* an entry referring to a missing object is there, as null */
    return resolved(d->doc, d->find(key));
}

bool
CGPDFDictionaryGetObject(CGPDFDictionaryRef d, const char *key, CGPDFObjectRef *value)
{
    const CGPDFObject *o = dict_item(d, key);
    if (!o)
        return false;
    if (value)
        *value = (CGPDFObjectRef)o;
    return true;
}

bool CGPDFDictionaryGetBoolean(CGPDFDictionaryRef d, const char *k, CGPDFBoolean *v) { return get_value(dict_item(d, k), kCGPDFObjectTypeBoolean, v); }
bool CGPDFDictionaryGetInteger(CGPDFDictionaryRef d, const char *k, CGPDFInteger *v) { return get_value(dict_item(d, k), kCGPDFObjectTypeInteger, v); }
bool CGPDFDictionaryGetNumber(CGPDFDictionaryRef d, const char *k, CGPDFReal *v) { return get_value(dict_item(d, k), kCGPDFObjectTypeReal, v); }
bool CGPDFDictionaryGetName(CGPDFDictionaryRef d, const char *k, const char **v) { return get_value(dict_item(d, k), kCGPDFObjectTypeName, v); }
bool CGPDFDictionaryGetString(CGPDFDictionaryRef d, const char *k, CGPDFStringRef *v) { return get_value(dict_item(d, k), kCGPDFObjectTypeString, v); }
bool CGPDFDictionaryGetArray(CGPDFDictionaryRef d, const char *k, CGPDFArrayRef *v) { return get_value(dict_item(d, k), kCGPDFObjectTypeArray, v); }
bool CGPDFDictionaryGetDictionary(CGPDFDictionaryRef d, const char *k, CGPDFDictionaryRef *v) { return get_value(dict_item(d, k), kCGPDFObjectTypeDictionary, v); }
bool CGPDFDictionaryGetStream(CGPDFDictionaryRef d, const char *k, CGPDFStreamRef *v) { return get_value(dict_item(d, k), kCGPDFObjectTypeStream, v); }

void
CGPDFDictionaryApplyFunction(CGPDFDictionaryRef d, CGPDFDictionaryApplierFunction fn, void *info)
{
    if (!d || !fn)
        return;
    for (auto &e : d->entries)
        fn(e.first, (CGPDFObjectRef)resolved(d->doc, &e.second), info);
}

void
CGPDFDictionaryApplyBlock(CGPDFDictionaryRef d, CF_NOESCAPE CGPDFDictionaryApplierBlock block, void *info)
{
    if (!d || !block)
        return;
    for (auto &e : d->entries)
        if (!block(e.first, (CGPDFObjectRef)resolved(d->doc, &e.second), info))
            return;
}

#pragma mark - Strings

size_t CGPDFStringGetLength(CGPDFStringRef s) { return s ? s->length : 0; }
const unsigned char *CGPDFStringGetBytePtr(CGPDFStringRef s) { return s ? s->bytes : NULL; }

/* PDFDocEncoding's bytes that differ from Latin-1 (ISO 32000-1, Annex D). */
static const uint16_t pdfdoc_18[8] = {0x02D8, 0x02C7, 0x02C6, 0x02D9, 0x02DD, 0x02DB, 0x02DA, 0x02DC};
static const uint16_t pdfdoc_80[33] = {
    0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044, 0x2039, 0x203A, 0x2212,
    0x2030, 0x201E, 0x201C, 0x201D, 0x2018, 0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x0141,
    0x0152, 0x0160, 0x0178, 0x017D, 0x0131, 0x0142, 0x0153, 0x0161, 0x017E, 0xFFFD, 0x20AC,
};

CFStringRef
CGPDFCopyTextString(const uint8_t *b, size_t n)
{
    if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF)
        return CFStringCreateWithBytes(NULL, b + 2, (CFIndex)(n - 2) & ~1, kCFStringEncodingUTF16BE, false);
    if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE)
        return CFStringCreateWithBytes(NULL, b + 2, (CFIndex)(n - 2) & ~1, kCFStringEncodingUTF16LE, false);
    if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
        CFStringRef s = CFStringCreateWithBytes(NULL, b + 3, (CFIndex)(n - 3), kCFStringEncodingUTF8, false);
        if (s)
            return s;
    }
    std::vector<UniChar> u(n);
    for (size_t i = 0; i < n; i++) {
        uint8_t c = b[i];
        if (c >= 0x18 && c <= 0x1F)
            u[i] = pdfdoc_18[c - 0x18];
        else if (c >= 0x80 && c <= 0xA0)
            u[i] = pdfdoc_80[c - 0x80];
        else
            u[i] = c;
    }
    return CFStringCreateWithCharacters(NULL, u.data(), (CFIndex)n);
}

CFStringRef
CGPDFStringCopyTextString(CGPDFStringRef s)
{
    return s ? CGPDFCopyTextString(s->bytes, s->length) : NULL;
}

/* Days from 1970-01-01 to January 1 of `y` (proleptic Gregorian). */
static long
days_to_year(long y)
{
    y -= 1;
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;
    return era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 - 719162;
}

/*
 * "D:YYYYMMDDHHmmSSOHH'mm'" (section 7.9.4); every part after the year is
 * optional, and a missing offset means UTC. Fields aren't range-checked:
 * a 13th month runs on past December, as Apple's does.
 */
CFDateRef
CGPDFStringCopyDate(CGPDFStringRef s)
{
    if (!s)
        return NULL;
    const char *p = (const char *)s->bytes, *e = p + s->length;
    while (p < e && *p == ' ')
        p++;
    if (e - p >= 2 && p[0] == 'D' && p[1] == ':')
        p += 2;
    auto digits = [&](int n, int &out) {
        int v = 0;
        for (int k = 0; k < n; k++) {
            if (p + k >= e || p[k] < '0' || p[k] > '9')
                return false;
            v = v * 10 + (p[k] - '0');
        }
        out = v;
        p += n;
        return true;
    };
    int year, month = 1, day = 1, hour = 0, minute = 0, second = 0;
    if (!digits(4, year))
        return NULL;
    if (digits(2, month) && digits(2, day) && digits(2, hour) && digits(2, minute))
        digits(2, second);
    if (month < 1 || month > 13 || day < 1)
        return NULL;
    int offset = 0;
    if (p < e && (*p == '+' || *p == '-')) {
        int sign = *p == '-' ? -1 : 1, oh = 0, om = 0;
        p++;
        if (digits(2, oh)) {
            if (p < e && *p == '\'')
                p++;
            digits(2, om);
        }
        offset = sign * (oh * 3600 + om * 60);
    }
    static const int before[14] = {0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365};
    bool leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    long days = days_to_year(year) + before[month] + (leap && month > 2) + day - 1;
    double t = (double)days * 86400 + hour * 3600 + minute * 60 + second - offset;
    return CFDateCreate(NULL, t - kCFAbsoluteTimeIntervalSince1970);
}

#pragma mark - Filters

static void
predict(CGPDFDictionaryRef params, std::vector<uint8_t> &data)
{
    CGPDFInteger predictor = 1, colors = 1, bpc = 8, columns = 1;
    if (!params || !CGPDFDictionaryGetInteger(params, "Predictor", &predictor) || predictor < 2)
        return;
    CGPDFDictionaryGetInteger(params, "Colors", &colors);
    CGPDFDictionaryGetInteger(params, "BitsPerComponent", &bpc);
    CGPDFDictionaryGetInteger(params, "Columns", &columns);
    if (colors < 1 || colors > 32 || bpc < 1 || bpc > 16 || columns < 1 || columns > (1 << 24))
        return;
    size_t bpp = (size_t)((colors * bpc + 7) / 8), row = (size_t)((colors * bpc * columns + 7) / 8);
    std::vector<uint8_t> out;
    if (predictor == 2) {
        /* TIFF: each sample less the one to its left (8-bit samples handled byte-wise) */
        out = data;
        if (bpc == 8)
            for (size_t y = 0; y + row <= out.size(); y += row)
                for (size_t x = bpp; x < row; x++)
                    out[y + x] = (uint8_t)(out[y + x] + out[y + x - bpp]);
        else if (bpc == 16)
            for (size_t y = 0; y + row <= out.size(); y += row)
                for (size_t x = 2 * (size_t)colors; x + 1 < row; x += 2) {
                    unsigned v = (unsigned)(out[y + x] << 8 | out[y + x + 1]) +
                                 (unsigned)(out[y + x - 2 * colors] << 8 | out[y + x + 1 - 2 * colors]);
                    out[y + x] = (uint8_t)(v >> 8), out[y + x + 1] = (uint8_t)v;
                }
        data.swap(out);
        return;
    }
    /* PNG: a filter type byte before each row */
    std::vector<uint8_t> prev(row, 0), cur(row);
    for (size_t pos = 0; pos < data.size(); pos += row + 1) {
        int type = data[pos];
        size_t n = std::min(row, data.size() - pos - 1);
        if (pos + 1 > data.size())
            break;
        for (size_t x = 0; x < row; x++) {
            uint8_t raw = x < n ? data[pos + 1 + x] : 0;
            uint8_t a = x >= bpp ? cur[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0;
            switch (type) {
            case 1: cur[x] = (uint8_t)(raw + a); break;
            case 2: cur[x] = (uint8_t)(raw + b); break;
            case 3: cur[x] = (uint8_t)(raw + ((a + b) >> 1)); break;
            case 4: {
                int pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c);
                cur[x] = (uint8_t)(raw + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c));
                break;
            }
            default: cur[x] = raw; break;
            }
        }
        out.insert(out.end(), cur.begin(), cur.begin() + (long)n);
        prev.swap(cur);
    }
    data.swap(out);
}

static void
flate(std::vector<uint8_t> &data)
{
    std::vector<uint8_t> out;
    z_stream z = {};
    if (inflateInit(&z) != Z_OK)
        return;
    z.next_in = data.data();
    z.avail_in = (uInt)data.size();
    uint8_t buf[65536];
    int r;
    do {
        z.next_out = buf;
        z.avail_out = sizeof buf;
        r = inflate(&z, Z_NO_FLUSH);
        out.insert(out.end(), buf, buf + (sizeof buf - z.avail_out));
    } while (r == Z_OK && (z.avail_in > 0 || z.avail_out == 0));
    if (r == Z_DATA_ERROR && out.empty()) {
        /* raw deflate without the zlib header */
        inflateEnd(&z);
        z = {};
        if (inflateInit2(&z, -15) != Z_OK)
            return;
        z.next_in = data.data();
        z.avail_in = (uInt)data.size();
        do {
            z.next_out = buf;
            z.avail_out = sizeof buf;
            r = inflate(&z, Z_NO_FLUSH);
            out.insert(out.end(), buf, buf + (sizeof buf - z.avail_out));
        } while (r == Z_OK && (z.avail_in > 0 || z.avail_out == 0));
    }
    inflateEnd(&z);
    data.swap(out);
}

static void
lzw(std::vector<uint8_t> &data, int early)
{
    std::vector<uint8_t> out;
    std::vector<std::vector<uint8_t>> table;
    auto reset = [&] {
        table.assign(258, {});
        for (int i = 0; i < 256; i++)
            table[i] = {(uint8_t)i};
    };
    reset();
    int bits = 9;
    uint32_t acc = 0;
    int nacc = 0;
    int prev = -1;
    for (size_t i = 0; i < data.size();) {
        while (nacc < bits && i < data.size()) {
            acc = acc << 8 | data[i++];
            nacc += 8;
        }
        if (nacc < bits)
            break;
        int code = (int)((acc >> (nacc - bits)) & ((1u << bits) - 1));
        nacc -= bits;
        if (code == 256) {
            reset();
            bits = 9;
            prev = -1;
            continue;
        }
        if (code == 257)
            break;
        std::vector<uint8_t> entry;
        if (code < (int)table.size())
            entry = table[(size_t)code];
        else if (prev >= 0 && code == (int)table.size()) {
            entry = table[(size_t)prev];
            entry.push_back(entry[0]);
        } else {
            break;
        }
        out.insert(out.end(), entry.begin(), entry.end());
        if (prev >= 0 && table.size() < 4096) {
            std::vector<uint8_t> n = table[(size_t)prev];
            n.push_back(entry[0]);
            table.push_back(n);
        }
        prev = code;
        size_t next = table.size() + (size_t)early;
        bits = next >= 2048 ? 12 : next >= 1024 ? 11 : next >= 512 ? 10 : 9;
    }
    data.swap(out);
}

static void
ascii_hex(std::vector<uint8_t> &data)
{
    std::vector<uint8_t> out;
    int hi = -1;
    for (uint8_t c : data) {
        if (c == '>')
            break;
        int v = hexval(c);
        if (v < 0)
            continue;
        if (hi < 0)
            hi = v;
        else
            out.push_back((uint8_t)(hi << 4 | v)), hi = -1;
    }
    if (hi >= 0)
        out.push_back((uint8_t)(hi << 4));
    data.swap(out);
}

static void
ascii85(std::vector<uint8_t> &data)
{
    std::vector<uint8_t> out;
    uint32_t tuple = 0;
    int n = 0;
    size_t i = 0;
    if (data.size() >= 2 && data[0] == '<' && data[1] == '~')
        i = 2;
    for (; i < data.size(); i++) {
        uint8_t c = data[i];
        if (c == '~')
            break;
        if (CGPDFIsSpace(c))
            continue;
        if (c == 'z' && n == 0) {
            out.insert(out.end(), 4, 0);
            continue;
        }
        if (c < '!' || c > 'u')
            continue;
        tuple = tuple * 85 + (uint32_t)(c - '!');
        if (++n == 5) {
            for (int k = 3; k >= 0; k--)
                out.push_back((uint8_t)(tuple >> (8 * k)));
            tuple = 0, n = 0;
        }
    }
    if (n > 1) {
        for (int k = n; k < 5; k++)
            tuple = tuple * 85 + 84;
        for (int k = 3; k >= 5 - n; k--)
            out.push_back((uint8_t)(tuple >> (8 * k)));
    }
    data.swap(out);
}

static void
run_length(std::vector<uint8_t> &data)
{
    std::vector<uint8_t> out;
    for (size_t i = 0; i < data.size();) {
        int len = data[i++];
        if (len == 128)
            break;
        if (len < 128) {
            size_t n = std::min((size_t)len + 1, data.size() - i);
            out.insert(out.end(), data.begin() + (long)i, data.begin() + (long)(i + n));
            i += n;
        } else if (i < data.size()) {
            out.insert(out.end(), (size_t)(257 - len), data[i++]);
        }
    }
    data.swap(out);
}

bool
CGPDFApplyFilter(const char *name, CGPDFDictionaryRef params, std::vector<uint8_t> &data)
{
    if (!strcmp(name, "FlateDecode") || !strcmp(name, "Fl")) {
        flate(data);
        predict(params, data);
    } else if (!strcmp(name, "LZWDecode") || !strcmp(name, "LZW")) {
        CGPDFInteger early = 1;
        if (params)
            CGPDFDictionaryGetInteger(params, "EarlyChange", &early);
        lzw(data, early ? 1 : 0);
        predict(params, data);
    } else if (!strcmp(name, "ASCIIHexDecode") || !strcmp(name, "AHx")) {
        ascii_hex(data);
    } else if (!strcmp(name, "ASCII85Decode") || !strcmp(name, "A85")) {
        ascii85(data);
    } else if (!strcmp(name, "RunLengthDecode") || !strcmp(name, "RL")) {
        run_length(data);
    } else if (!strcmp(name, "Crypt")) {
        /* only the Identity crypt filter is named in streams; others come from the document */
    } else {
        return false;
    }
    return true;
}

/* The filters (and their parameters) of a stream's dictionary, in order. */
static void
filters(CGPDFDictionaryRef dict, std::vector<const char *> &names, std::vector<CGPDFDictionaryRef> &params)
{
    CGPDFObjectRef f = NULL, p = NULL;
    if (!CGPDFDictionaryGetObject(dict, "Filter", &f) && !CGPDFDictionaryGetObject(dict, "F", &f))
        return;
    if (!CGPDFDictionaryGetObject(dict, "DecodeParms", &p))
        CGPDFDictionaryGetObject(dict, "DP", &p);
    if (f->type == kCGPDFObjectTypeName) {
        names.push_back(f->name);
        params.push_back(p && p->type == kCGPDFObjectTypeDictionary ? p->dict : NULL);
        if (p && p->type == kCGPDFObjectTypeArray) {
            CGPDFDictionaryRef d = NULL;
            CGPDFArrayGetDictionary(p->array, 0, &d);
            params.back() = d;
        }
    } else if (f->type == kCGPDFObjectTypeArray) {
        for (size_t i = 0; i < f->array->items.size(); i++) {
            const char *n;
            if (!CGPDFArrayGetName(f->array, i, &n))
                continue;
            CGPDFDictionaryRef d = NULL;
            if (p && p->type == kCGPDFObjectTypeArray)
                CGPDFArrayGetDictionary(p->array, i, &d);
            else if (p && p->type == kCGPDFObjectTypeDictionary && i == 0)
                d = p->dict;
            names.push_back(n);
            params.push_back(d);
        }
    }
}

CFDataRef
CGPDFStreamDecode(CGPDFStreamRef s, CGPDFDataFormat *format, bool stop_at_images)
{
    if (format)
        *format = CGPDFDataFormatRaw;
    if (!s)
        return NULL;
    std::vector<uint8_t> data(s->raw, s->raw + s->length);
    CGPDFDocData *doc = s->doc;
    if (doc && s->num && doc->crypt.encrypted) {
        if (!doc->crypt.unlocked)
            return NULL;
        /* the cross-reference stream and (optionally) metadata stay in the clear */
        const char *type = NULL;
        CGPDFDictionaryGetName(s->dict, "Type", &type);
        bool clear = type && (!strcmp(type, "XRef") ||
                              (!strcmp(type, "Metadata") && !doc->crypt.encrypt_metadata));
        std::vector<const char *> names;
        std::vector<CGPDFDictionaryRef> params;
        filters(s->dict, names, params);
        for (size_t i = 0; i < names.size(); i++) {
            const char *cf = NULL;
            if (!strcmp(names[i], "Crypt") && (!params[i] || !CGPDFDictionaryGetName(params[i], "Name", &cf) ||
                                                !strcmp(cf, "Identity")))
                clear = true;
        }
        if (!clear)
            CGPDFCryptDecrypt(doc, s->num, s->gen, true, data);
    }
    std::vector<const char *> names;
    std::vector<CGPDFDictionaryRef> params;
    filters(s->dict, names, params);
    for (size_t i = 0; i < names.size(); i++) {
        const char *n = names[i];
        if (!strcmp(n, "DCTDecode") || !strcmp(n, "DCT")) {
            if (format)
                *format = CGPDFDataFormatJPEGEncoded;
            break;
        }
        if (!strcmp(n, "JPXDecode")) {
            if (format)
                *format = CGPDFDataFormatJPEG2000;
            break;
        }
        if (!CGPDFApplyFilter(n, params[i], data)) {
            if (stop_at_images)
                break;
            data.clear();  /* a filter we can't decode (CCITT, JBIG2): no data, as Apple's gives for bad data */
            break;
        }
    }
    return CFDataCreate(NULL, data.data(), (CFIndex)data.size());
}

#pragma mark - Streams

CGPDFDictionaryRef
CGPDFStreamGetDictionary(CGPDFStreamRef s)
{
    return s ? s->dict : NULL;
}

CFDataRef
CGPDFStreamCopyData(CGPDFStreamRef s, CGPDFDataFormat *format)
{
    return CGPDFStreamDecode(s, format, false);
}
