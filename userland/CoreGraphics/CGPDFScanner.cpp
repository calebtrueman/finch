/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Content streams (ISO 32000-1 section 7.8): CGPDFContentStream (a page's
 * or form's streams and resources), CGPDFOperatorTable and CGPDFScanner,
 * which parses operands onto a stack and calls the table's callback for
 * each operator. The reader behind them (CGPDFContentReader) is shared
 * with CGContextDrawPDFPage.
 */
#include "CGPDFInternal.h"
#include <string.h>

#pragma mark - Reading operations

bool
CGPDFIsOperator(const char *op)
{
    static const char *const ops[] = {
        "b", "B", "b*", "B*", "BDC", "BMC", "BT", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP", "EI",
        "EMC", "ET", "f", "F", "f*", "G", "g", "gs", "h", "i", "j", "J", "K", "k", "l", "m", "M", "MP", "n",
        "q", "Q", "re", "RG", "rg", "ri", "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td", "TD",
        "Tf", "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz", "v", "w", "W", "W*", "y", "'", "\"",
    };
    for (const char *o : ops)
        if (!strcmp(o, op))
            return true;
    return false;
}

/* An inline image's data runs from after "ID" and one white-space byte to "EI" between white space. */
static bool
inline_image(CGPDFContentReader &r, CGPDFDictionary *dict, CGPDFOperation &op)
{
    CGPDFLexer &lx = r.lx;
    if (lx.p < lx.end && CGPDFIsSpace(*lx.p))
        lx.p++;
    const uint8_t *data = lx.p, *q = data;
    const uint8_t *found = NULL;
    while (q + 2 <= lx.end) {
        q = (const uint8_t *)memmem(q, (size_t)(lx.end - q), "EI", 2);
        if (!q)
            break;
        bool before = q == data || CGPDFIsSpace(q[-1]);
        bool after = q + 2 == lx.end || CGPDFIsSpace(q[2]);
        if (before && after) {
            /* what follows should parse as content: skip candidates followed by binary junk */
            bool plausible = true;
            for (const uint8_t *t = q + 2; t < lx.end && t < q + 32; t++)
                if (*t > 126 || (*t < 32 && !CGPDFIsSpace(*t))) {
                    plausible = false;
                    break;
                }
            if (plausible) {
                found = q;
                break;
            }
        }
        q += 2;
    }
    size_t n = found ? (size_t)(found - data) : (size_t)(lx.end - data);
    if (found && n > 0 && CGPDFIsSpace(data[n - 1]))
        n--;
    lx.p = found ? found + 2 : lx.end;
    CGPDFStream *s = r.arena.stream(r.doc);
    s->dict = dict;
    /* the data is copied: content bytes may be temporary */
    uint8_t *copy = (uint8_t *)r.arena.alloc(n);
    memcpy(copy, data, n);
    s->raw = copy;
    s->length = n;
    CGPDFObject o;
    o.type = kCGPDFObjectTypeStream;
    o.stream = s;
    op.op = "BI";
    op.operands.clear();
    op.operands.push_back(o);
    return true;
}

bool
CGPDFContentReader::next(CGPDFOperation &op)
{
    CGPDFParser ps(lx, arena, doc);
    ps.content = true;
    op.operands.clear();
    for (;;) {
        lx.skip_space();
        if (lx.p >= lx.end)
            return false;
        CGPDFObject o;
        const uint8_t *before = lx.p;
        if (ps.parse(o)) {
            op.operands.push_back(o);
            continue;
        }
        if (lx.p == before)
            lx.p++;
        if (ps.keyword.empty())
            continue;
        const std::string &k = ps.keyword;
        if (k.size() == 1 && strchr(")>]}{", k[0]))
            continue;  /* stray delimiters */
        if (k == "BI") {
            /* key/value pairs up to "ID" */
            CGPDFDictionary *dict = arena.dict(doc);
            for (;;) {
                CGPDFObject key, value;
                if (!ps.parse(key)) {
                    if (ps.keyword == "ID" || lx.p >= lx.end)
                        break;
                    continue;
                }
                if (!ps.parse(value)) {
                    if (ps.keyword == "ID")
                        break;
                    continue;
                }
                if (key.type == kCGPDFObjectTypeName)
                    dict->set(key.name, value);
            }
            return inline_image(*this, dict, op);
        }
        op.op = arena.name(k.data(), k.size());
        return true;
    }
}

#pragma mark - Operator tables

struct CGPDFOperatorTable {
    std::atomic<int> refs{1};
    std::unordered_map<std::string, CGPDFOperatorCallback> ops;
};

CGPDFOperatorTableRef
CGPDFOperatorTableCreate(void)
{
    return new CGPDFOperatorTable();
}

CGPDFOperatorTableRef
CGPDFOperatorTableRetain(CGPDFOperatorTableRef t)
{
    if (t)
        t->refs++;
    return t;
}

void
CGPDFOperatorTableRelease(CGPDFOperatorTableRef t)
{
    if (t && --t->refs == 0)
        delete t;
}

void
CGPDFOperatorTableSetCallback(CGPDFOperatorTableRef t, const char *name, CGPDFOperatorCallback callback)
{
    if (!t || !name)
        return;
    if (callback)
        t->ops[name] = callback;
    else
        t->ops.erase(name);
}

#pragma mark - Content streams

struct CGPDFContentStream {
    std::atomic<int> refs{1};
    CGPDFDocData *d;
    CGPDFPageRef page;           /* retained, for a page's content */
    std::vector<CGPDFStreamRef> streams;
    CGPDFDictionaryRef resources;
    CGPDFContentStream *parent;  /* retained */
    CFArrayRef array;
};

CGPDFContentStreamRef
CGPDFContentStreamCreateWithPage(CGPDFPageRef page)
{
    if (!page)
        return NULL;
    auto *cs = new CGPDFContentStream();
    cs->d = CGPDFPageGetDocData(page);
    cs->d->retain();
    cs->page = CGPDFPageRetain(page);
    cs->resources = CGPDFPageGetResources(page);
    cs->parent = NULL;
    cs->array = NULL;
    CGPDFDictionaryRef dict = CGPDFPageGetDictionary(page);
    CGPDFStreamRef s;
    CGPDFArrayRef a;
    if (CGPDFDictionaryGetStream(dict, "Contents", &s)) {
        cs->streams.push_back(s);
    } else if (CGPDFDictionaryGetArray(dict, "Contents", &a)) {
        for (size_t i = 0; i < CGPDFArrayGetCount(a); i++)
            if (CGPDFArrayGetStream(a, i, &s))
                cs->streams.push_back(s);
    }
    return cs;
}

CGPDFContentStreamRef
CGPDFContentStreamCreateWithStream(CGPDFStreamRef stream, CGPDFDictionaryRef resources, CGPDFContentStreamRef parent)
{
    if (!stream)
        return NULL;
    auto *cs = new CGPDFContentStream();
    cs->d = stream->doc ? stream->doc : parent ? parent->d : NULL;
    if (cs->d)
        cs->d->retain();
    cs->page = NULL;
    cs->streams.push_back(stream);
    cs->resources = resources;
    cs->parent = CGPDFContentStreamRetain(parent);
    cs->array = NULL;
    return cs;
}

CGPDFContentStreamRef
CGPDFContentStreamRetain(CGPDFContentStreamRef cs)
{
    if (cs)
        cs->refs++;
    return cs;
}

void
CGPDFContentStreamRelease(CGPDFContentStreamRef cs)
{
    if (!cs || --cs->refs)
        return;
    if (cs->array)
        CFRelease(cs->array);
    CGPDFContentStreamRelease(cs->parent);
    CGPDFPageRelease(cs->page);
    if (cs->d)
        cs->d->release();
    delete cs;
}

CFArrayRef
CGPDFContentStreamGetStreams(CGPDFContentStreamRef cs)
{
    if (!cs)
        return NULL;
    if (!cs->array)
        cs->array = CFArrayCreate(NULL, (const void **)cs->streams.data(), (CFIndex)cs->streams.size(), NULL);
    return cs->array;
}

/* A stream's own resources, or (when it has none) its parent's. */
CGPDFObjectRef
CGPDFContentStreamGetResource(CGPDFContentStreamRef cs, const char *category, const char *name)
{
    while (cs && !cs->resources)
        cs = cs->parent;
    CGPDFDictionaryRef cat;
    CGPDFObjectRef o;
    if (cs && category && name && CGPDFDictionaryGetDictionary(cs->resources, category, &cat) &&
        CGPDFDictionaryGetObject(cat, name, &o))
        return o;
    return NULL;
}

CGPDFDictionaryRef CGPDFContentStreamGetResources(CGPDFContentStreamRef cs) { return cs ? cs->resources : NULL; }
CGPDFDocData *CGPDFContentStreamGetDocData(CGPDFContentStreamRef cs) { return cs ? cs->d : NULL; }

#pragma mark - Scanners

struct CGPDFScanner {
    std::atomic<int> refs{1};
    CGPDFContentStreamRef cs;
    CGPDFOperatorTableRef table;
    void *info;
    std::vector<CGPDFObject> stack;
    CGPDFArena *arena;
    bool stopped;
};

CGPDFScannerRef
CGPDFScannerCreate(CGPDFContentStreamRef cs, CGPDFOperatorTableRef table, void *info)
{
    auto *s = new CGPDFScanner();
    s->cs = CGPDFContentStreamRetain(cs);
    s->table = CGPDFOperatorTableRetain(table);
    s->info = info;
    s->arena = new CGPDFArena();
    s->stopped = false;
    return s;
}

CGPDFScannerRef
CGPDFScannerRetain(CGPDFScannerRef s)
{
    if (s)
        s->refs++;
    return s;
}

void
CGPDFScannerRelease(CGPDFScannerRef s)
{
    if (!s || --s->refs)
        return;
    CGPDFContentStreamRelease(s->cs);
    CGPDFOperatorTableRelease(s->table);
    delete s->arena;
    delete s;
}

bool
CGPDFScannerScan(CGPDFScannerRef s)
{
    if (!s || !s->cs)
        return false;
    s->stopped = false;
    /* the streams are one content stream: tokens may cross from one to the next */
    std::vector<uint8_t> bytes;
    for (CGPDFStreamRef st : s->cs->streams) {
        CFDataRef data = CGPDFStreamDecode(st, NULL, false);
        if (!data)
            continue;
        bytes.insert(bytes.end(), CFDataGetBytePtr(data), CFDataGetBytePtr(data) + CFDataGetLength(data));
        bytes.push_back('\n');
        CFRelease(data);
    }
    CGPDFContentReader reader(bytes.data(), bytes.size(), *s->arena, s->cs->d);
    CGPDFOperation op;
    s->stack.clear();
    while (!s->stopped && reader.next(op)) {
        /*
         * Operands pile up until an operator PDF defines: other keywords
         * (BX/EX compatibility sections, unknown operators, malformed
         * tokens) are skipped and leave the operands where they are. An
         * inline image arrives as "EI" with its stream on top of the stack.
         */
        s->stack.insert(s->stack.end(), op.operands.begin(), op.operands.end());
        const char *name = !strcmp(op.op, "BI") ? "EI" : op.op;
        if (!CGPDFIsOperator(name))
            continue;
        CGPDFOperatorCallback cb = NULL;
        if (s->table) {
            auto it = s->table->ops.find(name);
            if (it != s->table->ops.end())
                cb = it->second;
        }
        if (cb)
            cb(s, s->info);
        s->stack.clear();
    }
    return true;  /* stopping isn't a failure */
}

CGPDFContentStreamRef CGPDFScannerGetContentStream(CGPDFScannerRef s) { return s ? s->cs : NULL; }
void CGPDFScannerStop(CGPDFScannerRef s) { if (s) s->stopped = true; }

static const CGPDFObject *
top(CGPDFScannerRef s)
{
    return s && !s->stack.empty() ? &s->stack.back() : NULL;
}

static bool
pop(CGPDFScannerRef s, CGPDFObjectType type, void *value)
{
    const CGPDFObject *o = top(s);
    if (!o)
        return false;
    CGPDFObject copy = *o;
    s->stack.pop_back();
    if (!CGPDFObjectGetValue(&copy, type, value))
        return false;
    return true;
}

bool
CGPDFScannerPopObject(CGPDFScannerRef s, CGPDFObjectRef *value)
{
    const CGPDFObject *o = top(s);
    if (!o)
        return false;
    CGPDFObject *kept = s->arena->object(*o);
    s->stack.pop_back();
    if (value)
        *value = kept;
    return true;
}

bool CGPDFScannerPopBoolean(CGPDFScannerRef s, CGPDFBoolean *v) { return pop(s, kCGPDFObjectTypeBoolean, v); }
bool CGPDFScannerPopInteger(CGPDFScannerRef s, CGPDFInteger *v) { return pop(s, kCGPDFObjectTypeInteger, v); }
bool CGPDFScannerPopNumber(CGPDFScannerRef s, CGPDFReal *v) { return pop(s, kCGPDFObjectTypeReal, v); }
bool CGPDFScannerPopName(CGPDFScannerRef s, const char **v) { return pop(s, kCGPDFObjectTypeName, v); }
bool CGPDFScannerPopString(CGPDFScannerRef s, CGPDFStringRef *v) { return pop(s, kCGPDFObjectTypeString, v); }
bool CGPDFScannerPopArray(CGPDFScannerRef s, CGPDFArrayRef *v) { return pop(s, kCGPDFObjectTypeArray, v); }
bool CGPDFScannerPopDictionary(CGPDFScannerRef s, CGPDFDictionaryRef *v) { return pop(s, kCGPDFObjectTypeDictionary, v); }
bool CGPDFScannerPopStream(CGPDFScannerRef s, CGPDFStreamRef *v) { return pop(s, kCGPDFObjectTypeStream, v); }
