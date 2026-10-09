/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The PDF object model shared by the reader (CGPDFDocument, CGPDFScanner,
 * CGContextDrawPDFPage) and the writer's final pass (CGPDFContext): objects,
 * the lexer and parser (ISO 32000-1 section 7), stream filters and the
 * standard security handler.
 *
 * Objects live in an arena owned by a document's shared data (or by a
 * scanner, for operands parsed from content). References are kept as
 * references and resolved through the document when they're read, as
 * Apple's accessors resolve them.
 */
#ifndef CG_PDF_INTERNAL_H
#define CG_PDF_INTERNAL_H

#include "CGInternal.h"
#include <atomic>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

struct CGPDFDocData;

/* Objects' types: Apple's, plus a reference not yet resolved. */
enum { kCGPDFObjectTypeRef = 100 };

struct CGPDFObject {
    int type;
    union {
        CGPDFBoolean b;
        CGPDFInteger i;
        CGPDFReal r;
        const char *name;
        struct CGPDFString *string;
        struct CGPDFArray *array;
        struct CGPDFDictionary *dict;
        struct CGPDFStream *stream;
        struct {
            uint32_t num;
            uint32_t gen;
        } ref;
    };
};

struct CGPDFString {
    size_t length;
    unsigned char *bytes;
};

struct CGPDFArray {
    CGPDFDocData *doc;
    std::vector<CGPDFObject> items;
};

struct CGPDFDictionary {
    CGPDFDocData *doc;
    std::vector<std::pair<const char *, CGPDFObject>> entries;
    const CGPDFObject *find(const char *key) const;
    void set(const char *key, const CGPDFObject &o);
    void remove(const char *key);
};

struct CGPDFStream {
    CGPDFDocData *doc;
    CGPDFDictionary *dict;
    const uint8_t *raw;   /* encoded bytes, as in the file */
    size_t length;
    uint32_t num, gen;    /* the object it came from, for decryption (0: none) */
};

/* Owns parsed objects. */
struct CGPDFArena {
    std::vector<CGPDFArray *> arrays;
    std::vector<CGPDFDictionary *> dicts;
    std::vector<CGPDFStream *> streams;
    std::vector<CGPDFString *> strings;
    std::vector<void *> blocks;
    std::vector<CGPDFObject *> objects;
    std::unordered_map<std::string, const char *> names;
    ~CGPDFArena();
    CGPDFArray *array(CGPDFDocData *doc);
    CGPDFDictionary *dict(CGPDFDocData *doc);
    CGPDFStream *stream(CGPDFDocData *doc);
    CGPDFString *string(const void *bytes, size_t len);
    CGPDFObject *object(const CGPDFObject &o);
    const char *name(const char *s, size_t len);
    void *alloc(size_t n);
};

/* The standard security handler's state. */
struct CGPDFCrypt {
    bool encrypted = false, unlocked = false, owner = false;
    int V = 0, R = 0, length = 40;
    int stm = 0, str = 0;            /* methods: 0 none, 1 RC4, 2 AESV2, 3 AESV3 */
    bool encrypt_metadata = true;
    uint32_t P = 0xffffffff;
    std::string O, U, OE, UE, id0;
    std::vector<uint8_t> key;
    uint32_t encrypt_num = 0;        /* the encryption dictionary's own object: not encrypted */
};

struct CGPDFXref {
    uint8_t kind;      /* 0 free, 1 at offset, 2 in an object stream */
    uint32_t gen;
    uint64_t offset;   /* or the object stream's number */
    uint32_t index;    /* within the object stream */
};

/* A document's parsed state, shared by the document and its pages. */
struct CGPDFDocData {
    std::atomic<int> refs{1};
    CFDataRef data = NULL;
    const uint8_t *bytes = NULL;
    size_t length = 0;
    CGPDFArena arena;
    std::vector<CGPDFXref> xref;
    std::unordered_map<uint32_t, CGPDFObject *> cache;
    std::unordered_map<uint32_t, std::vector<uint8_t>> objstm_data;
    std::unordered_map<uint32_t, bool> resolving;
    bool reconstructed = false;
    std::recursive_mutex lock;
    CGPDFDictionary *trailer = NULL;
    CGPDFCrypt crypt;
    int major = 1, minor = 0;
    void *document = NULL;           /* the CGPDFDocument, cleared when it goes */
    std::vector<CGPDFDictionary *> pages;
    bool pages_loaded = false;

    void retain() { refs++; }
    void release();
    /* Rebuild the cross-reference table by scanning the file for objects. */
    void reconstruct();
    /* The object `num`, parsed on first use (NULL if missing or locked). */
    CGPDFObject *resolve_ref(uint32_t num, uint32_t gen);
    /* `o`, or what it refers to. */
    const CGPDFObject *resolve(const CGPDFObject *o);
};

/* A null object, for missing values. */
CG_PRIVATE extern const CGPDFObject CGPDFNullObject;

#pragma mark - Parsing

struct CGPDFLexer {
    const uint8_t *start, *p, *end;
    CGPDFLexer(const uint8_t *b, size_t n) : start(b), p(b), end(b + n) {}
    void skip_space();
    bool at_end() { skip_space(); return p >= end; }
};

static inline bool CGPDFIsSpace(int c) { return c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32; }
static inline bool CGPDFIsDelimiter(int c)
{
    return c == '(' || c == ')' || c == '<' || c == '>' || c == '[' || c == ']' || c == '{' || c == '}' || c == '/' ||
           c == '%';
}

/*
 * Parse one object at the lexer. Keywords that aren't objects (operators in
 * content, "endobj", "R" handled here) come back as `keyword` with type 0.
 * `num`/`gen` name the indirect object being parsed, for decrypting its strings.
 */
struct CGPDFParser {
    CGPDFLexer &lx;
    CGPDFArena &arena;
    CGPDFDocData *doc;
    uint32_t num = 0, gen = 0;
    bool content = false;            /* content stream: no references */
    std::string keyword;
    int depth = 0;
    CGPDFParser(CGPDFLexer &l, CGPDFArena &a, CGPDFDocData *d) : lx(l), arena(a), doc(d) {}
    bool parse(CGPDFObject &out);
};

/* Decode a stream's data. `format` gets JPEG/JPEG 2000 when the last filter is left undecoded. */
CG_PRIVATE CFDataRef CGPDFStreamDecode(CGPDFStreamRef s, CGPDFDataFormat *format, bool stop_at_images);
/* Apply one named filter to `in`. False if the filter isn't supported. */
CG_PRIVATE bool CGPDFApplyFilter(const char *name, CGPDFDictionaryRef params, std::vector<uint8_t> &data);

#pragma mark - Encryption (CGPDFCrypt.cpp)

CG_PRIVATE bool CGPDFCryptSetup(CGPDFDocData *d, CGPDFDictionaryRef encrypt);
CG_PRIVATE bool CGPDFCryptUnlock(CGPDFDocData *d, const char *password);
/* Decrypt in place the bytes of an object's string or stream. */
CG_PRIVATE void CGPDFCryptDecrypt(CGPDFDocData *d, uint32_t num, uint32_t gen, bool stream, std::vector<uint8_t> &data);
CG_PRIVATE void CGPDFMD5(const void *data, size_t n, uint8_t out[16]);
CG_PRIVATE void CGPDFRC4(const uint8_t *key, size_t keylen, uint8_t *data, size_t n);
CG_PRIVATE bool CGPDFAES(bool encrypt, const uint8_t *key, size_t keylen, const uint8_t iv[16], const uint8_t *in,
                         size_t n, std::vector<uint8_t> &out, bool padding);
/* For writing: the O and U entries and the file key for revision 4 (AES-128), passwords as given. */
CG_PRIVATE void CGPDFCryptMakeR4(const std::string &owner, const std::string &user, uint32_t P,
                                 const std::string &id0, std::string &O, std::string &U, std::vector<uint8_t> &key);
CG_PRIVATE void CGPDFCryptObjectKey(const std::vector<uint8_t> &key, uint32_t num, uint32_t gen, bool aes,
                                    std::vector<uint8_t> &out);

#pragma mark - Documents (CGPDFDocument.cpp)

CG_PRIVATE CGPDFDocData *CGPDFDocDataCreate(CFDataRef data);
CG_PRIVATE CGPDFDocumentRef CGPDFDocumentCreateWithDocData(CGPDFDocData *d);
CG_PRIVATE CGPDFDocData *CGPDFDocumentGetDocData(CGPDFDocumentRef doc);
CG_PRIVATE CGPDFDictionaryRef CGPDFPageGetResources(CGPDFPageRef page);
CG_PRIVATE CGPDFDocData *CGPDFPageGetDocData(CGPDFPageRef page);
/* Text string bytes (PDFDocEncoding or UTF-16) to a CFString. */
CG_PRIVATE CFStringRef CGPDFCopyTextString(const uint8_t *bytes, size_t len);

#pragma mark - Content (CGPDFScanner.cpp)

/* One operation of a content stream. */
struct CGPDFOperation {
    const char *op;
    std::vector<CGPDFObject> operands;
};

/* Reads operations from content bytes; inline images become a "BI" operation whose operand is a stream. */
struct CGPDFContentReader {
    CGPDFLexer lx;
    CGPDFArena &arena;
    CGPDFDocData *doc;
    CGPDFContentReader(const uint8_t *b, size_t n, CGPDFArena &a, CGPDFDocData *d) : lx(b, n), arena(a), doc(d) {}
    /* False at the end. */
    bool next(CGPDFOperation &op);
};

/* Is `op` one of the operators PDF defines (other than BI/ID, BX/EX)? */
CG_PRIVATE bool CGPDFIsOperator(const char *op);
CG_PRIVATE CGPDFDictionaryRef CGPDFContentStreamGetResources(CGPDFContentStreamRef cs);
CG_PRIVATE CGPDFDocData *CGPDFContentStreamGetDocData(CGPDFContentStreamRef cs);

#pragma mark - Writing (CGPDFContext.cpp)

CG_PRIVATE void CGPDFContextFinalize(CGContextRef c);
/* Draw glyphs as PDF text. False when the state needs the path fallback. */
CG_PRIVATE bool CGPDFContextShowGlyphs(CGContextRef c, const CGGlyph *glyphs, const CGPoint *positions, size_t count);

#endif
