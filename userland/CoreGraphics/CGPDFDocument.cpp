/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGPDFDocument and CGPDFPage: reading a PDF file's structure (ISO 32000-1
 * section 7.5): the header, cross-reference tables and streams (with
 * incremental updates and hybrid files), object streams, and a rebuilt
 * table when the file's is broken; the page tree with inherited
 * attributes, page boxes and rotation, the drawing transform, the outline,
 * and the standard security handler's passwords and permissions.
 */
#include "CGPDFInternal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unordered_set>

#pragma mark - Shared data

void
CGPDFDocData::release()
{
    if (--refs == 0) {
        if (data)
            CFRelease(data);
        delete this;
    }
}

/* "num gen obj" at `off`; the lexer is left after it. */
static bool
object_header(CGPDFLexer &lx, uint32_t &num, uint32_t &gen)
{
    CGPDFArena scratch;
    CGPDFParser ps(lx, scratch, NULL);
    ps.content = true;
    CGPDFObject a, b;
    if (!ps.parse(a) || a.type != kCGPDFObjectTypeInteger || !ps.parse(b) || b.type != kCGPDFObjectTypeInteger)
        return false;
    CGPDFObject k;
    if (ps.parse(k) || ps.keyword != "obj")
        return false;
    num = (uint32_t)a.i, gen = (uint32_t)b.i;
    return true;
}

static bool
parse_at(CGPDFDocData *d, size_t off, uint32_t num, uint32_t gen, CGPDFObject &out)
{
    if (off >= d->length)
        return false;
    CGPDFLexer lx(d->bytes, d->length);
    lx.p = d->bytes + off;
    uint32_t n, g;
    if (!object_header(lx, n, g) || n != num)
        return false;
    CGPDFParser ps(lx, d->arena, d);
    ps.num = num, ps.gen = g;
    if (!ps.parse(out)) {
        /* "obj endobj": a null object */
        out = CGPDFNullObject;
    }
    return true;
}

static bool
parse_in_object_stream(CGPDFDocData *d, uint32_t stm, uint32_t index, uint32_t num, CGPDFObject &out)
{
    auto it = d->objstm_data.find(stm);
    if (it == d->objstm_data.end()) {
        CGPDFObject *so = d->resolve_ref(stm, 0);
        if (!so || so->type != kCGPDFObjectTypeStream)
            return false;
        CFDataRef data = CGPDFStreamDecode(so->stream, NULL, false);
        if (!data)
            return false;
        it = d->objstm_data.emplace(stm, std::vector<uint8_t>(CFDataGetBytePtr(data),
                                                              CFDataGetBytePtr(data) + CFDataGetLength(data))).first;
        CFRelease(data);
    }
    CGPDFObject *so = d->cache[stm];
    CGPDFInteger n = 0, first = 0;
    CGPDFDictionaryGetInteger(so->stream->dict, "N", &n);
    CGPDFDictionaryGetInteger(so->stream->dict, "First", &first);
    const std::vector<uint8_t> &bytes = it->second;
    CGPDFLexer lx(bytes.data(), bytes.size());
    CGPDFArena scratch;
    CGPDFParser hp(lx, scratch, NULL);
    hp.content = true;
    long found = -1;
    for (CGPDFInteger i = 0; i < n; i++) {
        CGPDFObject a, b;
        if (!hp.parse(a) || !hp.parse(b) || a.type != kCGPDFObjectTypeInteger || b.type != kCGPDFObjectTypeInteger)
            break;
        if ((uint32_t)a.i == num && (found < 0 || (uint32_t)i == index))
            found = (long)b.i;
    }
    if (found < 0 || first + found >= (long)bytes.size())
        return false;
    /* objects in object streams aren't encrypted on their own */
    CGPDFLexer olx(bytes.data(), bytes.size());
    olx.p = bytes.data() + first + found;
    CGPDFParser ps(olx, d->arena, d);
    if (!ps.parse(out))
        out = CGPDFNullObject;
    return true;
}

CGPDFObject *
CGPDFDocData::resolve_ref(uint32_t num, uint32_t gen)
{
    std::lock_guard<std::recursive_mutex> guard(lock);
    auto it = cache.find(num);
    if (it != cache.end())
        return it->second;
    if (resolving[num])
        return NULL;
    resolving[num] = true;
    CGPDFObject o;
    bool ok = false;
    if (num < xref.size()) {
        const CGPDFXref &x = xref[num];
        if (x.kind == 1)
            ok = parse_at(this, (size_t)x.offset, num, x.gen, o);
        else if (x.kind == 2)
            ok = parse_in_object_stream(this, (uint32_t)x.offset, x.index, num, o);
    }
    if (!ok && !reconstructed) {
        reconstruct();
        if (num < xref.size() && xref[num].kind == 1)
            ok = parse_at(this, (size_t)xref[num].offset, num, xref[num].gen, o);
    }
    resolving[num] = false;
    if (!ok)
        return NULL;
    CGPDFObject *p = arena.object(o);
    cache[num] = p;
    return p;
}

#pragma mark - Cross-reference

static void
set_entry(CGPDFDocData *d, uint32_t num, const CGPDFXref &x, bool override)
{
    if (num > 10000000)
        return;
    if (num >= d->xref.size())
        d->xref.resize(num + 1, CGPDFXref{0, 0, 0, 0});
    /* newer sections are read first: they win */
    if (override || (d->xref[num].kind == 0 && d->xref[num].offset == 0))
        d->xref[num] = x;
}

static void
merge_trailer(CGPDFDocData *d, CGPDFDictionary *t)
{
    if (!d->trailer) {
        d->trailer = t;
        return;
    }
    for (auto &e : t->entries)
        if (!d->trailer->find(e.first))
            d->trailer->set(e.first, e.second);
}

static bool read_xref(CGPDFDocData *d, size_t off, int depth);

static bool
read_xref_stream(CGPDFDocData *d, size_t off, int depth)
{
    CGPDFLexer lx(d->bytes, d->length);
    lx.p = d->bytes + off;
    uint32_t num, gen;
    if (!object_header(lx, num, gen))
        return false;
    CGPDFParser ps(lx, d->arena, d);
    CGPDFObject o;
    if (!ps.parse(o) || o.type != kCGPDFObjectTypeStream)
        return false;
    CGPDFDictionary *dict = o.stream->dict;
    CGPDFArrayRef w;
    if (!CGPDFDictionaryGetArray(dict, "W", &w) || CGPDFArrayGetCount(w) < 3)
        return false;
    CGPDFInteger ws[3];
    for (int k = 0; k < 3; k++)
        if (!CGPDFArrayGetInteger(w, (size_t)k, &ws[k]) || ws[k] < 0 || ws[k] > 8)
            return false;
    CGPDFInteger size = 0;
    CGPDFDictionaryGetInteger(dict, "Size", &size);
    std::vector<std::pair<CGPDFInteger, CGPDFInteger>> ranges;
    CGPDFArrayRef index;
    if (CGPDFDictionaryGetArray(dict, "Index", &index)) {
        for (size_t i = 0; i + 1 < CGPDFArrayGetCount(index); i += 2) {
            CGPDFInteger a = 0, b = 0;
            CGPDFArrayGetInteger(index, i, &a);
            CGPDFArrayGetInteger(index, i + 1, &b);
            ranges.emplace_back(a, b);
        }
    } else {
        ranges.emplace_back(0, size);
    }
    o.stream->num = 0;  /* cross-reference streams aren't encrypted */
    CFDataRef data = CGPDFStreamDecode(o.stream, NULL, false);
    if (!data)
        return false;
    const uint8_t *p = CFDataGetBytePtr(data), *e = p + CFDataGetLength(data);
    size_t rec = (size_t)(ws[0] + ws[1] + ws[2]);
    auto field = [&](const uint8_t *q, CGPDFInteger n) {
        uint64_t v = 0;
        for (CGPDFInteger k = 0; k < n; k++)
            v = v << 8 | q[k];
        return v;
    };
    for (auto &r : ranges)
        for (CGPDFInteger i = 0; i < r.second && p + rec <= e; i++, p += rec) {
            uint64_t type = ws[0] ? field(p, ws[0]) : 1;
            uint64_t f2 = field(p + ws[0], ws[1]), f3 = field(p + ws[0] + ws[1], ws[2]);
            CGPDFXref x = {0, 0, 0, 0};
            if (type == 1)
                x = {1, (uint32_t)f3, f2, 0};
            else if (type == 2)
                x = {2, 0, f2, (uint32_t)f3};
            else
                x = {0, 0, 1, 0};  /* free: marks the number as seen */
            set_entry(d, (uint32_t)(r.first + i), x, false);
        }
    CFRelease(data);
    merge_trailer(d, dict);
    CGPDFInteger prev;
    if (CGPDFDictionaryGetInteger(dict, "Prev", &prev) && prev >= 0 && depth < 64 && (size_t)prev != off)
        read_xref(d, (size_t)prev, depth + 1);
    return true;
}

static bool
read_xref(CGPDFDocData *d, size_t off, int depth)
{
    if (off >= d->length)
        return false;
    CGPDFLexer lx(d->bytes, d->length);
    lx.p = d->bytes + off;
    lx.skip_space();
    if ((size_t)(lx.end - lx.p) < 4 || memcmp(lx.p, "xref", 4))
        return read_xref_stream(d, (size_t)(lx.p - d->bytes), depth);
    lx.p += 4;
    CGPDFArena scratch;
    CGPDFParser ps(lx, scratch, NULL);
    ps.content = true;
    for (;;) {
        CGPDFObject a, b;
        const uint8_t *save = lx.p;
        if (!ps.parse(a)) {
            lx.p = save;
            break;
        }
        if (!ps.parse(b) || a.type != kCGPDFObjectTypeInteger || b.type != kCGPDFObjectTypeInteger)
            return false;
        for (CGPDFInteger i = 0; i < b.i; i++) {
            CGPDFObject o, g;
            if (!ps.parse(o) || !ps.parse(g))
                return false;
            CGPDFObject k;
            ps.parse(k);
            bool used = ps.keyword == "n";
            CGPDFXref x = used ? CGPDFXref{1, (uint32_t)g.i, (uint64_t)o.i, 0} : CGPDFXref{0, 0, 1, 0};
            /* a common error: the first section numbered from 1 with a free object 0 */
            CGPDFInteger num = a.i + i;
            if (a.i == 1 && i == 0 && !used && o.i == 0)
                num = 0, a.i = 0;
            if (used && x.offset == 0)
                continue;
            set_entry(d, (uint32_t)num, x, false);
        }
    }
    lx.skip_space();
    if ((size_t)(lx.end - lx.p) < 7 || memcmp(lx.p, "trailer", 7))
        return false;
    lx.p += 7;
    CGPDFParser tp(lx, d->arena, d);
    CGPDFObject t;
    if (!tp.parse(t) || t.type != kCGPDFObjectTypeDictionary)
        return false;
    merge_trailer(d, t.dict);
    CGPDFInteger stm, prev;
    if (CGPDFDictionaryGetInteger(t.dict, "XRefStm", &stm) && stm > 0)
        read_xref_stream(d, (size_t)stm, depth + 1);
    if (CGPDFDictionaryGetInteger(t.dict, "Prev", &prev) && prev >= 0 && depth < 64 && (size_t)prev != off)
        read_xref(d, (size_t)prev, depth + 1);
    return true;
}

void
CGPDFDocData::reconstruct()
{
    reconstructed = true;
    CGPDFDictionary *old_trailer = trailer;
    /* every "num gen obj" in the file; later ones win */
    for (const uint8_t *p = bytes, *e = bytes + length; p + 3 < e;) {
        const uint8_t *q = (const uint8_t *)memmem(p, (size_t)(e - p), "obj", 3);
        if (!q)
            break;
        p = q + 3;
        if (q + 3 < e && !CGPDFIsSpace(q[3]) && !CGPDFIsDelimiter(q[3]))
            continue;
        /* back over "gen" and "num" */
        const uint8_t *s = q;
        int fields = 0;
        while (s > bytes && fields < 2) {
            while (s > bytes && CGPDFIsSpace(s[-1]))
                s--;
            const uint8_t *digits_end = s;
            while (s > bytes && s[-1] >= '0' && s[-1] <= '9')
                s--;
            if (s == digits_end)
                break;
            fields++;
        }
        if (fields != 2 || (s > bytes && !CGPDFIsSpace(s[-1]) && !CGPDFIsDelimiter(s[-1])))
            continue;
        CGPDFLexer lx(bytes, length);
        lx.p = s;
        uint32_t num, gen;
        if (object_header(lx, num, gen))
            set_entry(this, num, CGPDFXref{1, gen, (uint64_t)(s - bytes), 0}, true);
    }
    /* trailers, and cross-reference streams standing in for them */
    for (const uint8_t *p = bytes, *e = bytes + length; p < e;) {
        const uint8_t *q = (const uint8_t *)memmem(p, (size_t)(e - p), "trailer", 7);
        if (!q)
            break;
        CGPDFLexer lx(bytes, length);
        lx.p = q + 7;
        CGPDFParser ps(lx, arena, this);
        CGPDFObject t;
        if (ps.parse(t) && t.type == kCGPDFObjectTypeDictionary && t.dict->find("Root")) {
            if (!trailer || trailer == old_trailer)
                trailer = t.dict;
            else
                for (auto &en : t.dict->entries)
                    trailer->set(en.first, en.second);
        }
        p = q + 7;
    }
    if (!trailer || !trailer->find("Root")) {
        /* the catalog, found by type */
        for (uint32_t n = 0; n < xref.size(); n++) {
            if (xref[n].kind != 1)
                continue;
            CGPDFObject o;
            if (!parse_at(this, (size_t)xref[n].offset, n, xref[n].gen, o))
                continue;
            const char *type = NULL;
            CGPDFDictionaryRef dict = o.type == kCGPDFObjectTypeDictionary ? o.dict
                                      : o.type == kCGPDFObjectTypeStream ? o.stream->dict : NULL;
            if (dict && CGPDFDictionaryGetName(dict, "Type", &type) && !strcmp(type, "XRef") && dict->find("Root")) {
                if (!trailer)
                    trailer = arena.dict(this);
                for (auto &en : dict->entries)
                    if (!trailer->find(en.first) && strcmp(en.first, "Length") && strcmp(en.first, "Filter"))
                        trailer->set(en.first, en.second);
            }
            if (dict && type && !strcmp(type, "Catalog") && (!trailer || !trailer->find("Root"))) {
                if (!trailer)
                    trailer = arena.dict(this);
                CGPDFObject ref;
                ref.type = kCGPDFObjectTypeRef;
                ref.ref.num = n, ref.ref.gen = xref[n].gen;
                trailer->set("Root", ref);
            }
        }
    }
}

CGPDFDocData *
CGPDFDocDataCreate(CFDataRef data)
{
    const uint8_t *b = CFDataGetBytePtr(data);
    size_t n = (size_t)CFDataGetLength(data);
    /* the header may follow some junk */
    const uint8_t *h = n ? (const uint8_t *)memmem(b, std::min<size_t>(n, 1024), "%PDF-", 5) : NULL;
    if (!h)
        return NULL;
    CGPDFDocData *d = new CGPDFDocData();
    d->data = (CFDataRef)CFRetain(data);
    d->bytes = b;
    d->length = n;
    if (h + 8 <= b + n && h[5] >= '0' && h[5] <= '9' && h[6] == '.') {
        d->major = h[5] - '0';
        d->minor = 0;
        for (const uint8_t *q = h + 7; q < b + n && *q >= '0' && *q <= '9'; q++)
            d->minor = d->minor * 10 + (*q - '0');
    }
    /* startxref, near the end */
    size_t tail = std::min<size_t>(n, 2048);
    const uint8_t *sx = NULL;
    for (const uint8_t *q = b + n - tail; q + 9 <= b + n; q++)
        if (!memcmp(q, "startxref", 9))
            sx = q;
    bool ok = false;
    if (sx) {
        CGPDFLexer lx(b, n);
        lx.p = sx + 9;
        CGPDFArena scratch;
        CGPDFParser ps(lx, scratch, NULL);
        ps.content = true;
        CGPDFObject off;
        if (ps.parse(off) && off.type == kCGPDFObjectTypeInteger && off.i >= 0)
            ok = read_xref(d, (size_t)off.i, 0);
    }
    CGPDFDictionaryRef root = NULL;
    if (!ok || !d->trailer || !CGPDFDictionaryGetDictionary(d->trailer, "Root", &root)) {
        if (!d->reconstructed)
            d->reconstruct();
    }
    if (!d->trailer) {
        d->release();
        return NULL;
    }
    /* encryption: try the empty user password */
    const CGPDFObject *enc = d->trailer->find("Encrypt");
    if (enc) {
        if (enc->type == kCGPDFObjectTypeRef)
            d->crypt.encrypt_num = enc->ref.num;
        CGPDFDictionaryRef ed = NULL;
        CGPDFDictionaryGetDictionary(d->trailer, "Encrypt", &ed);
        if (ed && CGPDFCryptSetup(d, ed))
            CGPDFCryptUnlock(d, "");
        else
            d->crypt.encrypted = true;  /* a handler we don't know: stays locked */
    }
    if (d->crypt.unlocked || !d->crypt.encrypted) {
        if (!CGPDFDictionaryGetDictionary(d->trailer, "Root", &root)) {
            if (!d->reconstructed) {
                d->reconstruct();
                CGPDFDictionaryGetDictionary(d->trailer, "Root", &root);
            }
            if (!root) {
                d->release();
                return NULL;
            }
        }
    }
    return d;
}

#pragma mark - Pages

static void
collect_pages(CGPDFDocData *d, CGPDFDictionaryRef node, std::unordered_set<CGPDFDictionaryRef> &seen, int depth)
{
    if (!node || depth > 64 || !seen.insert(node).second)
        return;
    CGPDFArrayRef kids;
    const char *type = NULL;
    CGPDFDictionaryGetName(node, "Type", &type);
    if (CGPDFDictionaryGetArray(node, "Kids", &kids) && !(type && !strcmp(type, "Page"))) {
        for (size_t i = 0; i < CGPDFArrayGetCount(kids); i++) {
            CGPDFDictionaryRef kid;
            if (CGPDFArrayGetDictionary(kids, i, &kid))
                collect_pages(d, kid, seen, depth + 1);
        }
        return;
    }
    if (type && !strcmp(type, "Pages"))
        return;
    d->pages.push_back((CGPDFDictionary *)node);
}

static void
load_pages(CGPDFDocData *d)
{
    std::lock_guard<std::recursive_mutex> guard(d->lock);
    if (d->pages_loaded)
        return;
    d->pages_loaded = true;
    CGPDFDictionaryRef root, pages;
    if (!d->trailer || !CGPDFDictionaryGetDictionary(d->trailer, "Root", &root) ||
        !CGPDFDictionaryGetDictionary(root, "Pages", &pages))
        return;
    std::unordered_set<CGPDFDictionaryRef> seen;
    collect_pages(d, pages, seen, 0);
}

/* An attribute of a page, or of the nearest page-tree node that has it. */
static const CGPDFObject *
inherited(CGPDFDictionaryRef page, const char *key)
{
    CGPDFDictionaryRef node = page;
    for (int i = 0; node && i < 64; i++) {
        CGPDFObjectRef o;
        if (CGPDFDictionaryGetObject(node, key, &o))
            return o;
        CGPDFDictionaryRef parent = NULL;
        if (!CGPDFDictionaryGetDictionary(node, "Parent", &parent) || parent == node)
            break;
        node = parent;
    }
    return NULL;
}

struct CGPDFPage {
    CGRuntimeBase base;
    CGPDFDocData *d;
    CGPDFDictionary *dict;
    size_t number;
};

struct CGPDFDocument {
    CGRuntimeBase base;
    CGPDFDocData *d;
    std::vector<CGPDFPage *> *pages;
    CFDictionaryRef outline;
};

static void
page_finalize(CFTypeRef cf)
{
    struct CGPDFPage *p = (struct CGPDFPage *)cf;
    if (p->d)
        p->d->release();
}

static CFStringRef
page_desc(CFTypeRef cf)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CGPDFPage %p>"), cf);
}

static const CGRuntimeClass page_class = {
    0, "CGPDFPage", NULL, NULL, page_finalize, NULL, NULL, NULL, page_desc, NULL, NULL, 0,
};
static CFTypeID page_type;

CFTypeID
CGPDFPageGetTypeID(void)
{
    return CGTypeRegister(&page_class, &page_type);
}

static void
document_finalize(CFTypeRef cf)
{
    struct CGPDFDocument *doc = (struct CGPDFDocument *)cf;
    if (doc->pages) {
        for (auto *p : *doc->pages)
            if (p)
                CFRelease(p);
        delete doc->pages;
    }
    if (doc->outline)
        CFRelease(doc->outline);
    if (doc->d) {
        {
            std::lock_guard<std::recursive_mutex> guard(doc->d->lock);
            doc->d->document = NULL;
        }
        doc->d->release();
    }
}

static CFStringRef
document_desc(CFTypeRef cf)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CGPDFDocument %p>"), cf);
}

static const CGRuntimeClass document_class = {
    0, "CGPDFDocument", NULL, NULL, document_finalize, NULL, NULL, NULL, document_desc, NULL, NULL, 0,
};
static CFTypeID document_type;

CFTypeID
CGPDFDocumentGetTypeID(void)
{
    return CGTypeRegister(&document_class, &document_type);
}

CGPDFDocumentRef
CGPDFDocumentCreateWithDocData(CGPDFDocData *d)
{
    struct CGPDFDocument *doc =
        (struct CGPDFDocument *)CGTypeCreateInstance(CGPDFDocumentGetTypeID(), sizeof(struct CGPDFDocument));
    doc->d = d;
    d->document = doc;
    doc->pages = new std::vector<CGPDFPage *>();
    return doc;
}

CGPDFDocData *
CGPDFDocumentGetDocData(CGPDFDocumentRef doc)
{
    return doc ? doc->d : NULL;
}

CGPDFDocumentRef
CGPDFDocumentCreateWithProvider(CGDataProviderRef provider)
{
    CFDataRef data = provider ? CGDataProviderCopyData(provider) : NULL;
    if (!data)
        return NULL;
    CGPDFDocData *d = CGPDFDocDataCreate(data);
    CFRelease(data);
    return d ? CGPDFDocumentCreateWithDocData(d) : NULL;
}

CGPDFDocumentRef
CGPDFDocumentCreateWithURL(CFURLRef url)
{
    CGDataProviderRef p = url ? CGDataProviderCreateWithURL(url) : NULL;
    if (!p)
        return NULL;
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithProvider(p);
    CGDataProviderRelease(p);
    return doc;
}

CGPDFDocumentRef CGPDFDocumentRetain(CGPDFDocumentRef d) { return d ? (CGPDFDocumentRef)CFRetain(d) : NULL; }
void CGPDFDocumentRelease(CGPDFDocumentRef d) { if (d) CFRelease(d); }

/* The header's version, or the catalog's when that is later (an update can raise it). */
void
CGPDFDocumentGetVersion(CGPDFDocumentRef doc, int *major, int *minor)
{
    int ma = doc ? doc->d->major : 0, mi = doc ? doc->d->minor : 0;
    CGPDFDictionaryRef cat = CGPDFDocumentGetCatalog(doc);
    const char *v = NULL;
    if (cat && CGPDFDictionaryGetName(cat, "Version", &v) && v[0] >= '0' && v[0] <= '9' && v[1] == '.') {
        int cma = v[0] - '0', cmi = atoi(v + 2);
        if (cma > ma || (cma == ma && cmi > mi))
            ma = cma, mi = cmi;
    }
    if (major)
        *major = ma;
    if (minor)
        *minor = mi;
}

bool CGPDFDocumentIsEncrypted(CGPDFDocumentRef doc) { return doc && doc->d->crypt.encrypted; }
bool CGPDFDocumentIsUnlocked(CGPDFDocumentRef doc) { return doc && (!doc->d->crypt.encrypted || doc->d->crypt.unlocked); }

bool
CGPDFDocumentUnlockWithPassword(CGPDFDocumentRef doc, const char *password)
{
    if (!doc)
        return false;
    CGPDFDocData *d = doc->d;
    std::lock_guard<std::recursive_mutex> guard(d->lock);
    if (!d->crypt.encrypted)
        return true;  /* nothing to unlock */
    if (d->crypt.R < 2)
        return false;
    CGPDFCrypt saved = d->crypt;
    if (!CGPDFCryptUnlock(d, password ? password : "")) {
        /* a wrong password leaves the document locked, even one the empty password had opened */
        d->crypt = saved;
        d->crypt.unlocked = false;
        return false;
    }
    /* objects already read while locked keep their encrypted strings, as Apple's do */
    return true;
}

CGPDFAccessPermissions
CGPDFDocumentGetAccessPermissions(CGPDFDocumentRef doc)
{
    if (!doc)
        return 0;
    const CGPDFCrypt &c = doc->d->crypt;
    if (!c.encrypted || c.owner)
        return 0xff;
    if (!c.unlocked)
        return 0;
    /* the P bits (table 22) as Apple's reader groups them */
    uint32_t P = c.P, out = 0;
    if (P & 4)
        out |= kCGPDFAllowsLowQualityPrinting | kCGPDFAllowsHighQualityPrinting;
    if (P & (8 | 256 | 1024))
        out |= kCGPDFAllowsDocumentChanges;
    if (P & (8 | 1024))
        out |= kCGPDFAllowsDocumentAssembly;
    if (P & 16)
        out |= kCGPDFAllowsContentCopying;
    if (P & (16 | 512))
        out |= kCGPDFAllowsContentAccessibility;
    if (P & 32)
        out |= kCGPDFAllowsCommenting;
    if (P & 256)
        out |= kCGPDFAllowsFormFieldEntry;
    return out;
}

bool
CGPDFDocumentAllowsPrinting(CGPDFDocumentRef doc)
{
    return doc && (CGPDFDocumentGetAccessPermissions(doc) & kCGPDFAllowsLowQualityPrinting);
}

bool
CGPDFDocumentAllowsCopying(CGPDFDocumentRef doc)
{
    return doc && (CGPDFDocumentGetAccessPermissions(doc) & kCGPDFAllowsContentCopying);
}

size_t
CGPDFDocumentGetNumberOfPages(CGPDFDocumentRef doc)
{
    if (!doc)
        return 0;
    load_pages(doc->d);
    return doc->d->pages.size();
}

CGPDFPageRef
CGPDFDocumentGetPage(CGPDFDocumentRef doc, size_t number)
{
    if (!doc || number == 0)
        return NULL;
    CGPDFDocData *d = doc->d;
    load_pages(d);
    std::lock_guard<std::recursive_mutex> guard(d->lock);
    if (number > d->pages.size())
        return NULL;
    if (doc->pages->size() < d->pages.size())
        doc->pages->resize(d->pages.size(), NULL);
    CGPDFPage *&slot = (*doc->pages)[number - 1];
    if (!slot) {
        slot = (CGPDFPage *)CGTypeCreateInstance(CGPDFPageGetTypeID(), sizeof(CGPDFPage));
        slot->d = d;
        d->retain();
        slot->dict = d->pages[number - 1];
        slot->number = number;
    }
    return slot;
}

CGPDFDictionaryRef
CGPDFDocumentGetCatalog(CGPDFDocumentRef doc)
{
    CGPDFDictionaryRef root = NULL;
    if (doc && doc->d->trailer)
        CGPDFDictionaryGetDictionary(doc->d->trailer, "Root", &root);
    return root;
}

CGPDFDictionaryRef
CGPDFDocumentGetInfo(CGPDFDocumentRef doc)
{
    CGPDFDictionaryRef info = NULL;
    if (doc && doc->d->trailer)
        CGPDFDictionaryGetDictionary(doc->d->trailer, "Info", &info);
    return info;
}

CGPDFArrayRef
CGPDFDocumentGetID(CGPDFDocumentRef doc)
{
    CGPDFArrayRef id = NULL;
    if (doc && doc->d->trailer)
        CGPDFDictionaryGetArray(doc->d->trailer, "ID", &id);
    return id;
}

#pragma mark - Page attributes

CGPDFDocumentRef
CGPDFPageGetDocument(CGPDFPageRef page)
{
    return page ? (CGPDFDocumentRef)page->d->document : NULL;
}

/* A locked document's pages are there, but without numbers or boxes. */
static bool
locked(CGPDFPageRef page)
{
    return page->d->crypt.encrypted && !page->d->crypt.unlocked;
}

size_t CGPDFPageGetPageNumber(CGPDFPageRef page) { return page && !locked(page) ? page->number : 0; }
CGPDFDictionaryRef CGPDFPageGetDictionary(CGPDFPageRef page) { return page ? page->dict : NULL; }
CGPDFDocData *CGPDFPageGetDocData(CGPDFPageRef page) { return page ? page->d : NULL; }

CGPDFPageRef CGPDFPageRetain(CGPDFPageRef p) { return p ? (CGPDFPageRef)CFRetain(p) : NULL; }
void CGPDFPageRelease(CGPDFPageRef p) { if (p) CFRelease(p); }

CGPDFDictionaryRef
CGPDFPageGetResources(CGPDFPageRef page)
{
    const CGPDFObject *o = page ? inherited(page->dict, "Resources") : NULL;
    return o && o->type == kCGPDFObjectTypeDictionary ? o->dict : NULL;
}

/* A rectangle entry, normalized; false if missing or malformed. */
static bool
box_entry(CGPDFDictionaryRef page, const char *key, CGRect &r)
{
    const CGPDFObject *o = inherited(page, key);
    if (!o || o->type != kCGPDFObjectTypeArray || CGPDFArrayGetCount(o->array) != 4)
        return false;
    CGPDFReal v[4];
    for (size_t i = 0; i < 4; i++)
        if (!CGPDFArrayGetNumber(o->array, i, &v[i]))
            return false;
    r = CGRectStandardize(CGRectMake(v[0], v[1], v[2] - v[0], v[3] - v[1]));
    return true;
}

CGRect
CGPDFPageGetBoxRect(CGPDFPageRef page, CGPDFBox box)
{
    if (!page || box < kCGPDFMediaBox || box > kCGPDFArtBox || locked(page))
        return CGRectNull;
    CGRect media;
    if (!box_entry(page->dict, "MediaBox", media))
        media = CGRectMake(0, 0, 612, 792);
    if (box == kCGPDFMediaBox)
        return media;
    CGRect crop = media, r;
    if (box_entry(page->dict, "CropBox", r)) {
        r = CGRectIntersection(r, media);
        if (!CGRectIsNull(r))
            crop = r;
    }
    if (box == kCGPDFCropBox)
        return crop;
    /* the others default to the crop box, and aren't clipped to it */
    static const char *keys[] = {NULL, NULL, "BleedBox", "TrimBox", "ArtBox"};
    if (box_entry(page->dict, keys[box], r))
        return r;
    return crop;
}

int
CGPDFPageGetRotationAngle(CGPDFPageRef page)
{
    if (!page)
        return 0;
    const CGPDFObject *o = inherited(page->dict, "Rotate");
    CGPDFInteger r = 0;
    if (o && o->type == kCGPDFObjectTypeInteger)
        r = o->i;
    else if (o && o->type == kCGPDFObjectTypeReal)
        r = (CGPDFInteger)o->r;
    return (int)r;  /* as written: Apple's doesn't normalize it */
}

/*
 * The box, rotated by the page's rotation plus `rotate` (clockwise, in 90
 * degree steps), scaled down to fit `rect` if it's bigger (never up), and
 * centred in it.
 */
CGAffineTransform
CGPDFPageGetDrawingTransform(CGPDFPageRef page, CGPDFBox box, CGRect rect, int rotate, bool preserveAspectRatio)
{
    if (!page)
        return CGAffineTransformIdentity;
    CGRect b = CGPDFPageGetBoxRect(page, box);
    /* a total that isn't a multiple of 90 degrees counts as none */
    int angle = (CGPDFPageGetRotationAngle(page) + rotate) % 360;
    if (angle < 0)
        angle += 360;
    if (angle % 90)
        angle = 0;
    rect = CGRectStandardize(rect);
    bool quarter = angle == 90 || angle == 270;
    CGFloat bw = quarter ? b.size.height : b.size.width, bh = quarter ? b.size.width : b.size.height;
    CGFloat sx = 1, sy = 1;
    if (bw > 0 && bh > 0) {
        sx = rect.size.width / bw, sy = rect.size.height / bh;
        if (preserveAspectRatio)
            sx = sy = fmin(sx, sy);
        sx = fmin(sx, 1), sy = fmin(sy, 1);
    }
    /* exact quarter turns, clockwise on the page */
    static const int cs[4][2] = {{1, 0}, {0, -1}, {-1, 0}, {0, 1}};
    CGFloat cosv = cs[angle / 90][0], sinv = cs[angle / 90][1];
    CGFloat ex = quarter ? sy : sx, ey = quarter ? sx : sy;
    CGAffineTransform t = CGAffineTransformMake(cosv * ex, sinv * ex, -sinv * ey, cosv * ey, 0, 0);
    CGFloat mx = CGRectGetMidX(b), my = CGRectGetMidY(b);
    t.tx = CGRectGetMidX(rect) - (t.a * mx + t.c * my);
    t.ty = CGRectGetMidY(rect) - (t.b * mx + t.d * my);
    t.a += 0.0, t.b += 0.0, t.c += 0.0, t.d += 0.0;
    return t;
}

#pragma mark - Deprecated page accessors on the document

static CGRect
doc_box(CGPDFDocumentRef doc, int page, CGPDFBox box)
{
    CGPDFPageRef p = page > 0 ? CGPDFDocumentGetPage(doc, (size_t)page) : NULL;
    return p ? CGPDFPageGetBoxRect(p, box) : CGRectNull;
}

CGRect CGPDFDocumentGetMediaBox(CGPDFDocumentRef d, int page) { return doc_box(d, page, kCGPDFMediaBox); }
CGRect CGPDFDocumentGetCropBox(CGPDFDocumentRef d, int page) { return doc_box(d, page, kCGPDFCropBox); }
CGRect CGPDFDocumentGetBleedBox(CGPDFDocumentRef d, int page) { return doc_box(d, page, kCGPDFBleedBox); }
CGRect CGPDFDocumentGetTrimBox(CGPDFDocumentRef d, int page) { return doc_box(d, page, kCGPDFTrimBox); }
CGRect CGPDFDocumentGetArtBox(CGPDFDocumentRef d, int page) { return doc_box(d, page, kCGPDFArtBox); }

int
CGPDFDocumentGetRotationAngle(CGPDFDocumentRef doc, int page)
{
    CGPDFPageRef p = page > 0 ? CGPDFDocumentGetPage(doc, (size_t)page) : NULL;
    return p ? CGPDFPageGetRotationAngle(p) : 0;
}

#pragma mark - Outline

extern "C" {
const CFStringRef kCGPDFOutlineTitle = CFSTR("Title");
const CFStringRef kCGPDFOutlineChildren = CFSTR("Children");
const CFStringRef kCGPDFOutlineDestination = CFSTR("Destination");
const CFStringRef kCGPDFOutlineDestinationRect = CFSTR("DestinationRect");
}

static size_t
page_number_of(CGPDFDocumentRef doc, CGPDFArrayRef dest)
{
    CGPDFDictionaryRef page;
    CGPDFInteger index;
    if (CGPDFArrayGetDictionary(dest, 0, &page)) {
        load_pages(doc->d);
        for (size_t i = 0; i < doc->d->pages.size(); i++)
            if (doc->d->pages[i] == page)
                return i + 1;
    } else if (CGPDFArrayGetInteger(dest, 0, &index) && index >= 0) {
        return (size_t)index + 1;
    }
    return 0;
}

static CFMutableDictionaryRef
mutable_dict(void)
{
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static void
outline_items(CGPDFDocumentRef doc, CGPDFDictionaryRef first, CFMutableArrayRef out, int depth)
{
    std::unordered_set<CGPDFDictionaryRef> seen;
    for (CGPDFDictionaryRef item = first; item && depth < 32 && seen.insert(item).second;) {
        CFMutableDictionaryRef entry = mutable_dict();
        CGPDFStringRef title;
        CFStringRef t = CGPDFDictionaryGetString(item, "Title", &title) ? CGPDFStringCopyTextString(title) : NULL;
        CFDictionarySetValue(entry, kCGPDFOutlineTitle, t ? t : CFSTR(""));
        if (t)
            CFRelease(t);
        CGPDFObjectRef dest = NULL;
        CGPDFDictionaryRef action;
        if (!CGPDFDictionaryGetObject(item, "Dest", &dest) && CGPDFDictionaryGetDictionary(item, "A", &action)) {
            const char *s = NULL;
            CGPDFDictionaryGetName(action, "S", &s);
            CGPDFStringRef uri;
            if (s && !strcmp(s, "URI") && CGPDFDictionaryGetString(action, "URI", &uri)) {
                CFURLRef url = CFURLCreateWithBytes(NULL, uri->bytes, (CFIndex)uri->length, kCFStringEncodingUTF8, NULL);
                if (url) {
                    CFDictionarySetValue(entry, kCGPDFOutlineDestination, url);
                    CFRelease(url);
                }
            } else if (s && !strcmp(s, "GoTo")) {
                CGPDFDictionaryGetObject(action, "D", &dest);
            }
        }
        /* explicit destinations only: Apple's leaves out items that go to a named one */
        CGPDFArrayRef da = dest && dest->type == kCGPDFObjectTypeArray ? dest->array : NULL;
        size_t page = da ? page_number_of(doc, da) : 0;
        if (page) {
            long n = (long)page;
            CFNumberRef num = CFNumberCreate(NULL, kCFNumberLongType, &n);
            CFDictionarySetValue(entry, kCGPDFOutlineDestination, num);
            CFRelease(num);
        }
        CGPDFDictionaryRef child;
        if (CGPDFDictionaryGetDictionary(item, "First", &child)) {
            CFMutableArrayRef kids = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
            outline_items(doc, child, kids, depth + 1);
            if (CFArrayGetCount(kids))
                CFDictionarySetValue(entry, kCGPDFOutlineChildren, kids);
            CFRelease(kids);
        }
        if (CFDictionaryContainsKey(entry, kCGPDFOutlineDestination) || CFDictionaryContainsKey(entry, kCGPDFOutlineChildren))
            CFArrayAppendValue(out, entry);
        CFRelease(entry);
        CGPDFDictionaryRef next = NULL;
        CGPDFDictionaryGetDictionary(item, "Next", &next);
        item = next;
    }
}

CFDictionaryRef
CGPDFDocumentGetOutline(CGPDFDocumentRef doc)
{
    if (!doc)
        return NULL;
    std::lock_guard<std::recursive_mutex> guard(doc->d->lock);
    if (doc->outline)
        return doc->outline;
    /* an outline whose items all go to named destinations is there, empty */
    CGPDFDictionaryRef catalog = CGPDFDocumentGetCatalog(doc), outlines, first;
    if (!catalog || !CGPDFDictionaryGetDictionary(catalog, "Outlines", &outlines))
        return NULL;
    CFMutableArrayRef kids = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (CGPDFDictionaryGetDictionary(outlines, "First", &first))
        outline_items(doc, first, kids, 0);
    CFMutableDictionaryRef root = mutable_dict();
    CFDictionarySetValue(root, kCGPDFOutlineChildren, kids);
    CFRelease(kids);
    doc->outline = root;
    return root;
}
