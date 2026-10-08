/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSJSONSerialization (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSJSONSerialization.h>.
 *
 * Reading works on UTF-8 (UTF-16 and UTF-32 input is detected as RFC 4627
 * says and converted first) and behaves as Apple's: integers become long
 * long or unsigned long long numbers, or NSDecimalNumbers past that;
 * fractions become doubles, or NSDecimalNumbers past 17 significant
 * digits; duplicate keys keep the first value; a trailing comma is
 * accepted; errors are NSCocoaErrorDomain 3840 with Apple's messages and
 * "around line L, column C" (column counted from zero). JSON5 adds
 * comments, unquoted and single-quoted keys, single-quoted strings, hex
 * integers, Infinity and NaN, and leading or trailing decimal points.
 *
 * Writing is Apple's format: "/" escaped unless asked not to, doubles to
 * 17 significant digits, pretty printing with two-space indents and
 * " : ", empty containers as "[\n\n]", and sorted keys in Finder's order
 * (numeric, case-insensitive).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <math.h>

#include "Foundation_Finch.h"

#define MAX_DEPTH 513

/* MARK: - Reading */

typedef struct {
    const unsigned char *p;
    NSUInteger len, i;
    NSJSONReadingOptions opts;
    BOOL json5;
    int depth;
    NSString *error;
    NSUInteger errorAt;
} Reader;

static id read_value(Reader *r);

static void
fail(Reader *r, NSUInteger at, NSString *message)
{
    if (r->error) return;
    r->error = message;
    r->errorAt = at;
}

static BOOL
at_end(Reader *r)
{
    return r->i >= r->len;
}

/* Whitespace, and in JSON5 comments. NO on an unterminated comment. */
static BOOL
skip_space(Reader *r)
{
    while (r->i < r->len) {
        unsigned char c = r->p[r->i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { r->i++; continue; }
        if (r->json5 && c == '/' && r->i + 1 < r->len) {
            if (r->p[r->i + 1] == '/') {
                while (r->i < r->len && r->p[r->i] != '\n') r->i++;
                continue;
            }
            if (r->p[r->i + 1] == '*') {
                NSUInteger j = r->i + 2;
                while (j + 1 < r->len && !(r->p[j] == '*' && r->p[j + 1] == '/')) j++;
                if (j + 1 >= r->len) { fail(r, r->len, @"Unterminated block comment"); return NO; }
                r->i = j + 2;
                continue;
            }
        }
        break;
    }
    return YES;
}

static int
hexval(unsigned char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static BOOL
read_hex4(Reader *r, NSUInteger at, unsigned *out)
{
    unsigned v = 0;
    for (int k = 0; k < 4; k++) {
        if (at + k >= r->len) { fail(r, r->len, @"Unexpected end of file"); return NO; }
        int h = hexval(r->p[at + k]);
        if (h < 0) { fail(r, at + k, @"Invalid hex digit in unicode escape sequence"); return NO; }
        v = v * 16 + (unsigned)h;
    }
    *out = v;
    return YES;
}

static void
append_utf8(NSMutableData *d, unsigned cp)
{
    unsigned char b[4];
    int n;
    if (cp < 0x80) { b[0] = (unsigned char)cp; n = 1; }
    else if (cp < 0x800) { b[0] = (unsigned char)(0xC0 | (cp >> 6)); b[1] = (unsigned char)(0x80 | (cp & 0x3F)); n = 2; }
    else if (cp < 0x10000) {
        b[0] = (unsigned char)(0xE0 | (cp >> 12)); b[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (unsigned char)(0x80 | (cp & 0x3F)); n = 3;
    } else {
        b[0] = (unsigned char)(0xF0 | (cp >> 18)); b[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F)); b[3] = (unsigned char)(0x80 | (cp & 0x3F)); n = 4;
    }
    [d appendBytes:b length:(NSUInteger)n];
}

static NSString *
read_string(Reader *r)
{
    NSUInteger start = r->i;
    unsigned char quote = r->p[r->i++];
    NSMutableData *buf = [NSMutableData data];
    for (;;) {
        if (at_end(r)) { fail(r, start, @"Unterminated string"); return nil; }
        unsigned char c = r->p[r->i];
        if (c == quote) { r->i++; break; }
        if (c < 0x20) { fail(r, r->i, @"Unescaped control character"); return nil; }
        if (c != '\\') {
            NSUInteger run = r->i;
            while (r->i < r->len && r->p[r->i] != quote && r->p[r->i] != '\\' && r->p[r->i] >= 0x20) r->i++;
            [buf appendBytes:r->p + run length:r->i - run];
            continue;
        }
        NSUInteger esc = r->i;
        if (r->i + 1 >= r->len) { fail(r, start, @"Unterminated string"); return nil; }
        unsigned char e = r->p[r->i + 1];
        r->i += 2;
        switch (e) {
        case '"': case '\\': case '/': [buf appendBytes:&e length:1]; break;
        case 'b': append_utf8(buf, '\b'); break;
        case 'f': append_utf8(buf, '\f'); break;
        case 'n': append_utf8(buf, '\n'); break;
        case 'r': append_utf8(buf, '\r'); break;
        case 't': append_utf8(buf, '\t'); break;
        case 'u': {
            unsigned cp;
            if (!read_hex4(r, r->i, &cp)) return nil;
            r->i += 4;
            if (cp >= 0xD800 && cp < 0xDC00) {
                unsigned lo;
                if (r->i + 1 < r->len && r->p[r->i] == '\\' && r->p[r->i + 1] == 'u' && read_hex4(r, r->i + 2, &lo) && lo >= 0xDC00 && lo < 0xE000) {
                    r->i += 6;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                } else {
                    r->error = nil;
                    fail(r, esc, @"Unexpected end of file during string parse (expected low-surrogate code point but did not find one).");
                    return nil;
                }
            } else if (cp >= 0xDC00 && cp < 0xE000) {
                fail(r, esc, @"Unable to convert hex escape sequence (no high character) to UTF8-encoded character.");
                return nil;
            }
            append_utf8(buf, cp);
            break;
        }
        default:
            if (r->json5) {
                if (e == 'x') {
                    int h1 = r->i < r->len ? hexval(r->p[r->i]) : -1, h2 = r->i + 1 < r->len ? hexval(r->p[r->i + 1]) : -1;
                    if (h1 < 0 || h2 < 0) { fail(r, esc, @"Invalid escape sequence"); return nil; }
                    append_utf8(buf, (unsigned)(h1 * 16 + h2));
                    r->i += 2;
                } else if (e == 'v') append_utf8(buf, '\v');
                else if (e == '0') append_utf8(buf, 0);
                else [buf appendBytes:&e length:1];
                break;
            }
            fail(r, esc, @"Invalid escape sequence");
            return nil;
        }
    }
    NSString *s = [[[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] autorelease];
    if (!s) fail(r, start, @"Unable to convert data to string");
    return s;
}

static BOOL
is_ident(unsigned char c, BOOL first)
{
    return c == '_' || c == '$' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80 || (!first && c >= '0' && c <= '9');
}

static id
read_number(Reader *r)
{
    NSUInteger start = r->i;
    BOOL neg = NO;
    if (r->p[r->i] == '-' || (r->json5 && r->p[r->i] == '+')) { neg = r->p[r->i] == '-'; r->i++; }
    if (r->json5) {
        const char *words[] = { "Infinity", "NaN" };
        for (int w = 0; w < 2; w++) {
            size_t n = strlen(words[w]);
            if (r->i + n <= r->len && !memcmp(r->p + r->i, words[w], n)) {
                r->i += n;
                double v = w == 0 ? INFINITY : NAN;
                return [NSNumber numberWithDouble:neg ? -v : v];
            }
        }
        if (r->i + 1 < r->len && r->p[r->i] == '0' && (r->p[r->i + 1] == 'x' || r->p[r->i + 1] == 'X')) {
            r->i += 2;
            unsigned long long v = 0;
            NSUInteger digits = r->i;
            while (r->i < r->len && hexval(r->p[r->i]) >= 0) v = v * 16 + (unsigned)hexval(r->p[r->i++]);
            if (r->i == digits) { fail(r, r->i, @"Invalid value"); return nil; }
            return [NSNumber numberWithLongLong:neg ? -(long long)v : (long long)v];
        }
    }
    NSUInteger intStart = r->i;
    while (r->i < r->len && r->p[r->i] >= '0' && r->p[r->i] <= '9') r->i++;
    NSUInteger intDigits = r->i - intStart;
    if (!intDigits && !(r->json5 && r->i < r->len && r->p[r->i] == '.')) {
        if (r->p[start] == '-' || r->p[start] == '+') fail(r, r->i, @"Number with minus sign but no digits");
        else fail(r, start, @"Invalid value");
        return nil;
    }
    if (intDigits > 1 && r->p[intStart] == '0') { fail(r, intStart + 1, @"Number with leading zero"); return nil; }
    BOOL integral = YES;
    if (r->i < r->len && r->p[r->i] == '.') {
        r->i++;
        NSUInteger f = r->i;
        while (r->i < r->len && r->p[r->i] >= '0' && r->p[r->i] <= '9') r->i++;
        if (r->i == f && !r->json5) { fail(r, r->i, @"Number with decimal point but no additional digits"); return nil; }
        if (r->i > f) integral = NO;
    }
    if (r->i < r->len && (r->p[r->i] == 'e' || r->p[r->i] == 'E')) {
        r->i++;
        if (r->i < r->len && (r->p[r->i] == '-' || r->p[r->i] == '+')) r->i++;
        NSUInteger e = r->i;
        while (r->i < r->len && r->p[r->i] >= '0' && r->p[r->i] <= '9') r->i++;
        if (r->i == e) { fail(r, r->i, @"Number with 'e' but no additional digits"); return nil; }
        integral = NO;
    }
    char *text = strndup((const char *)r->p + start, r->i - start);
    char *t = text;
    if (*t == '+') t++;
    id result;
    if (integral) {
        /* Drop a JSON5 trailing point: "5." is the integer 5. */
        char *dot = strchr(t, '.');
        if (dot) *dot = 0;
        errno = 0;
        long long ll = strtoll(t, NULL, 10);
        if (errno != ERANGE) {
            result = [NSNumber numberWithLongLong:ll];
        } else {
            errno = 0;
            unsigned long long ull = neg ? 0 : strtoull(t, NULL, 10);
            if (!neg && errno != ERANGE) result = [NSNumber numberWithUnsignedLongLong:ull];
            else result = [NSDecimalNumber decimalNumberWithString:[NSString stringWithUTF8String:t]];
        }
    } else {
        int significant = 0;
        BOOL leading = YES;
        for (char *c = t; *c && *c != 'e' && *c != 'E'; c++) {
            if (*c < '0' || *c > '9') continue;
            if (leading && *c == '0') continue;
            leading = NO;
            significant++;
        }
        if (significant > 17) {
            result = [NSDecimalNumber decimalNumberWithString:[NSString stringWithUTF8String:t]];
        } else {
            double d = strtod(t, NULL);
            if (isinf(d) || isnan(d)) { free(text); fail(r, start, @"Number wound up as NaN"); return nil; }
            result = [NSNumber numberWithDouble:d];
        }
    }
    free(text);
    return result;
}

static BOOL
literal(Reader *r, const char *word)
{
    size_t n = strlen(word);
    if (r->i + n <= r->len && !memcmp(r->p + r->i, word, n)) {
        r->i += n;
        return YES;
    }
    fail(r, r->i, [NSString stringWithFormat:@"Something looked like a '%s' but wasn't", word]);
    return NO;
}

static id
read_array(Reader *r)
{
    if (++r->depth > MAX_DEPTH) { fail(r, r->i, @"Too many nested arrays or dictionaries"); return nil; }
    r->i++;
    NSMutableArray *a = [NSMutableArray array];
    if (!skip_space(r)) return nil;
    if (!at_end(r) && r->p[r->i] == ']') { r->i++; r->depth--; return a; }
    for (;;) {
        id v = read_value(r);
        if (!v) return nil;
        [a addObject:v];
        if (!skip_space(r)) return nil;
        if (at_end(r)) { fail(r, r->i, @"Unexpected end of file"); return nil; }
        unsigned char c = r->p[r->i];
        if (c == ']') { r->i++; break; }
        if (c != ',') { fail(r, r->i, @"Badly formed array"); return nil; }
        r->i++;
        if (!skip_space(r)) return nil;
        if (!at_end(r) && r->p[r->i] == ']') { r->i++; break; }
    }
    r->depth--;
    return a;
}

static NSString *
read_key(Reader *r)
{
    if (at_end(r)) { fail(r, r->i, @"Unexpected end of file"); return nil; }
    unsigned char c = r->p[r->i];
    if (c == '"' || (r->json5 && c == '\'')) return read_string(r);
    if (r->json5 && is_ident(c, YES)) {
        NSUInteger start = r->i;
        while (r->i < r->len && is_ident(r->p[r->i], NO)) r->i++;
        return [[[NSString alloc] initWithBytes:r->p + start length:r->i - start encoding:NSUTF8StringEncoding] autorelease];
    }
    fail(r, r->i, @"No string key for value in object");
    return nil;
}

/* An object's members up to `close` (0: the end of the text). */
static id
read_members(Reader *r, unsigned char close)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!skip_space(r)) return nil;
    if (close ? (!at_end(r) && r->p[r->i] == close) : at_end(r)) { if (close) r->i++; return d; }
    for (;;) {
        NSString *key = read_key(r);
        if (!key) return nil;
        if (!skip_space(r)) return nil;
        if (at_end(r)) { fail(r, r->i, @"Unexpected end of file"); return nil; }
        if (r->p[r->i] != ':') { fail(r, r->i, @"No value for key in object"); return nil; }
        r->i++;
        id v = read_value(r);
        if (!v) return nil;
        if (![d objectForKey:key]) [d setObject:v forKey:key];
        if (!skip_space(r)) return nil;
        if (at_end(r)) {
            if (!close) break;
            fail(r, r->i, @"Unexpected end of file");
            return nil;
        }
        unsigned char c = r->p[r->i];
        if (close && c == close) { r->i++; break; }
        if (c != ',') { fail(r, r->i, @"Badly formed object"); return nil; }
        r->i++;
        if (!skip_space(r)) return nil;
        if (close ? (!at_end(r) && r->p[r->i] == close) : at_end(r)) { if (close) r->i++; break; }
    }
    return d;
}

static id
read_object(Reader *r)
{
    if (++r->depth > MAX_DEPTH) { fail(r, r->i, @"Too many nested arrays or dictionaries"); return nil; }
    r->i++;
    id d = read_members(r, '}');
    r->depth--;
    return d;
}

static id
read_value(Reader *r)
{
    if (!skip_space(r)) return nil;
    if (at_end(r)) { fail(r, r->i, @"Unexpected end of file"); return nil; }
    unsigned char c = r->p[r->i];
    switch (c) {
    case '[': return read_array(r);
    case '{': return read_object(r);
    case '"': return read_string(r);
    case 't': return literal(r, "true") ? (id)kCFBooleanTrue : nil;
    case 'f': return literal(r, "false") ? (id)kCFBooleanFalse : nil;
    case 'n': return literal(r, "null") ? [NSNull null] : nil;
    case '-': return read_number(r);
    default:
        if (c >= '0' && c <= '9') return read_number(r);
        if (r->json5 && (c == '\'')) return read_string(r);
        if (r->json5 && (c == '+' || c == '.' || c == 'I' || c == 'N')) return read_number(r);
        fail(r, r->i, @"Invalid value");
        return nil;
    }
}

/* Mutable containers on request; immutable copies otherwise. */
static id
finish_containers(id o, BOOL mutable)
{
    if ([o isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[o count]];
        for (id v in o) [a addObject:finish_containers(v, mutable)];
        return mutable ? a : [[a copy] autorelease];
    }
    if ([o isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:[o count]];
        for (id k in o) [d setObject:finish_containers([o objectForKey:k], mutable) forKey:k];
        return mutable ? d : [[d copy] autorelease];
    }
    return o;
}

/* The text as UTF-8, by its BOM or its pattern of zero bytes. */
static NSData *
utf8_data(NSData *data)
{
    const unsigned char *b = [data bytes];
    NSUInteger n = [data length];
    NSStringEncoding enc = 0;
    NSUInteger skip = 0;
    if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) return [data subdataWithRange:NSMakeRange(3, n - 3)];
    if (n >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0xFE && b[3] == 0xFF) { enc = NSUTF32BigEndianStringEncoding; skip = 4; }
    else if (n >= 4 && b[0] == 0xFF && b[1] == 0xFE && b[2] == 0 && b[3] == 0) { enc = NSUTF32LittleEndianStringEncoding; skip = 4; }
    else if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF) { enc = NSUTF16BigEndianStringEncoding; skip = 2; }
    else if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE) { enc = NSUTF16LittleEndianStringEncoding; skip = 2; }
    else if (n >= 4 && !b[0] && !b[1] && !b[2]) enc = NSUTF32BigEndianStringEncoding;
    else if (n >= 4 && b[0] && !b[1] && !b[2] && !b[3]) enc = NSUTF32LittleEndianStringEncoding;
    else if (n >= 2 && !b[0] && b[1]) enc = NSUTF16BigEndianStringEncoding;
    else if (n >= 2 && b[0] && !b[1]) enc = NSUTF16LittleEndianStringEncoding;
    if (!enc) return data;
    NSString *s = [[[NSString alloc] initWithBytes:b + skip length:n - skip encoding:enc] autorelease];
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

static NSError *
json_error(NSString *message, Reader *r)
{
    NSUInteger line = 1, lineStart = 0;
    for (NSUInteger k = 0; k < r->errorAt && k < r->len; k++)
        if (r->p[k] == '\n') { line++; lineStart = k + 1; }
    NSString *desc = [NSString stringWithFormat:@"%@ around line %lu, column %lu.", message, (unsigned long)line,
        (unsigned long)(r->errorAt - lineStart)];
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError
        userInfo:@{ NSDebugDescriptionErrorKey: desc, @"NSJSONSerializationErrorIndex": @(r->errorAt) }];
}

/* MARK: - Writing */

typedef struct {
    NSMutableData *out;
    NSJSONWritingOptions opts;
    int depth;
} Writer;

static void
put(Writer *w, const char *s)
{
    [w->out appendBytes:s length:strlen(s)];
}

static void
indent(Writer *w)
{
    for (int k = 0; k < w->depth; k++) put(w, "  ");
}

static void
write_string(Writer *w, NSString *s)
{
    put(w, "\"");
    const unsigned char *u = (const unsigned char *)[s UTF8String];
    NSUInteger run = 0, k = 0;
    for (; u[k]; k++) {
        unsigned char c = u[k];
        const char *esc = NULL;
        char hex[8];
        switch (c) {
        case '"': esc = "\\\""; break;
        case '\\': esc = "\\\\"; break;
        case '/': if (!(w->opts & NSJSONWritingWithoutEscapingSlashes)) esc = "\\/"; break;
        case '\b': esc = "\\b"; break;
        case '\f': esc = "\\f"; break;
        case '\n': esc = "\\n"; break;
        case '\r': esc = "\\r"; break;
        case '\t': esc = "\\t"; break;
        default:
            if (c < 0x20) { snprintf(hex, sizeof(hex), "\\u%04x", c); esc = hex; }
        }
        if (!esc) continue;
        [w->out appendBytes:u + run length:k - run];
        put(w, esc);
        run = k + 1;
    }
    [w->out appendBytes:u + run length:k - run];
    put(w, "\"");
}

/* Finder's order, which Apple's sorted keys use. */
static NSInteger
key_order(id a, id b, void *ctx)
{
    return [a compare:b options:NSCaseInsensitiveSearch | NSNumericSearch | NSWidthInsensitiveSearch | NSForcedOrderingSearch
        range:NSMakeRange(0, [a length]) locale:[NSLocale systemLocale]];
}

static void
write_value(Writer *w, id o)
{
    BOOL pretty = (w->opts & NSJSONWritingPrettyPrinted) != 0;
    if ([o isKindOfClass:[NSString class]]) {
        write_string(w, o);
    } else if ([o isKindOfClass:[NSNull class]]) {
        put(w, "null");
    } else if ([o isKindOfClass:[NSNumber class]]) {
        if (o == (id)kCFBooleanTrue || o == (id)kCFBooleanFalse) { put(w, o == (id)kCFBooleanTrue ? "true" : "false"); return; }
        if ([o isKindOfClass:[NSDecimalNumber class]]) {
            NSDecimal d = [o decimalValue];
            if (NSDecimalIsNotANumber(&d)) FinchRaise(NSInvalidArgumentException, "NaN number in JSON write");
            put(w, [[o description] UTF8String]);
            return;
        }
        const char *t = [o objCType];
        char buf[64];
        if (*t == 'f' || *t == 'd') {
            double d = [o doubleValue];
            if (isnan(d)) FinchRaise(NSInvalidArgumentException, "Invalid number value (NaN) in JSON write");
            if (isinf(d)) FinchRaise(NSInvalidArgumentException, "Invalid number value (infinite) in JSON write");
            snprintf(buf, sizeof(buf), "%.17g", d);
        } else if (*t == 'Q') {
            snprintf(buf, sizeof(buf), "%llu", [o unsignedLongLongValue]);
        } else {
            snprintf(buf, sizeof(buf), "%lld", [o longLongValue]);
        }
        put(w, buf);
    } else if ([o isKindOfClass:[NSArray class]]) {
        put(w, "[");
        w->depth++;
        BOOL first = YES;
        for (id v in o) {
            if (!first) put(w, ",");
            first = NO;
            if (pretty) { put(w, "\n"); indent(w); }
            write_value(w, v);
        }
        w->depth--;
        if (pretty) { put(w, first ? "\n\n" : "\n"); indent(w); }
        put(w, "]");
    } else if ([o isKindOfClass:[NSDictionary class]]) {
        for (id k in o)
            if (![k isKindOfClass:[NSString class]]) FinchRaise(NSInvalidArgumentException, "Invalid (non-string) key in JSON dictionary");
        NSArray *keys = [o allKeys];
        if (w->opts & NSJSONWritingSortedKeys) keys = [keys sortedArrayUsingFunction:key_order context:NULL];
        put(w, "{");
        w->depth++;
        BOOL first = YES;
        for (NSString *k in keys) {
            if (!first) put(w, ",");
            first = NO;
            if (pretty) { put(w, "\n"); indent(w); }
            write_string(w, k);
            put(w, pretty ? " : " : ":");
            write_value(w, [o objectForKey:k]);
        }
        w->depth--;
        if (pretty) { put(w, first ? "\n\n" : "\n"); indent(w); }
        put(w, "}");
    } else {
        FinchRaise(NSInvalidArgumentException, "Invalid type in JSON write (%s)", object_getClassName(o));
    }
}

static BOOL
valid(id o, int depth)
{
    if ([o isKindOfClass:[NSString class]] || [o isKindOfClass:[NSNull class]]) return YES;
    if ([o isKindOfClass:[NSNumber class]]) {
        if ([o isKindOfClass:[NSDecimalNumber class]]) { NSDecimal d = [o decimalValue]; return !NSDecimalIsNotANumber(&d); }
        double d = [o doubleValue];
        return !isnan(d) && !isinf(d);
    }
    if ([o isKindOfClass:[NSArray class]]) {
        for (id v in o) if (!valid(v, depth + 1)) return NO;
        return YES;
    }
    if ([o isKindOfClass:[NSDictionary class]]) {
        for (id k in o) if (![k isKindOfClass:[NSString class]] || !valid([o objectForKey:k], depth + 1)) return NO;
        return YES;
    }
    return NO;
}

@implementation NSJSONSerialization

+ (BOOL)isValidJSONObject:(id)obj
{
    if (![obj isKindOfClass:[NSArray class]] && ![obj isKindOfClass:[NSDictionary class]]) return NO;
    return valid(obj, 0);
}

+ (NSData *)dataWithJSONObject:(id)obj options:(NSJSONWritingOptions)opt error:(NSError **)error
{
    if (!(opt & NSJSONWritingFragmentsAllowed) && ![obj isKindOfClass:[NSArray class]] && ![obj isKindOfClass:[NSDictionary class]])
        FinchRaise(NSInvalidArgumentException, "*** +[NSJSONSerialization dataWithJSONObject:options:error:]: Invalid top-level type in JSON write");
    Writer w = { [NSMutableData data], opt, 0 };
    write_value(&w, obj);
    if (error) *error = nil;
    return w.out;
}

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error
{
    if (!data) FinchRaise(NSInvalidArgumentException, "data parameter is nil");
    if (error) *error = nil;
    if (![data length]) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError
            userInfo:@{ NSDebugDescriptionErrorKey: @"Unable to parse empty data." }];
        return nil;
    }
    NSData *utf8 = utf8_data(data);
    Reader r = { [utf8 bytes], [utf8 length], 0, opt, (opt & NSJSONReadingJSON5Allowed) != 0, 0, nil, 0 };
    id result = nil;
    if (!skip_space(&r)) goto failed;
    if (r.json5 && (opt & NSJSONReadingTopLevelDictionaryAssumed) && !(!at_end(&r) && r.p[r.i] == '{')) {
        result = read_members(&r, 0);
        if (!result) goto failed;
    } else {
        if (at_end(&r)) { fail(&r, r.i, @"JSON text did not have any content"); goto failed; }
        if (!(opt & NSJSONReadingFragmentsAllowed) && r.p[r.i] != '[' && r.p[r.i] != '{') {
            fail(&r, r.i, @"JSON text did not start with array or object and option to allow fragments not set.");
            goto failed;
        }
        result = read_value(&r);
        if (!result) goto failed;
    }
    if (!skip_space(&r)) goto failed;
    if (!at_end(&r)) { fail(&r, r.i, @"Garbage at end"); goto failed; }
    return finish_containers(result, (opt & NSJSONReadingMutableContainers) != 0);

failed:
    if (error) *error = json_error(r.error ? r.error : @"Invalid value", &r);
    return nil;
}

+ (NSInteger)writeJSONObject:(id)obj toStream:(NSOutputStream *)stream options:(NSJSONWritingOptions)opt error:(NSError **)error
{
    NSData *d = [self dataWithJSONObject:obj options:opt error:error];
    if (!d) return 0;
    const uint8_t *b = [d bytes];
    NSUInteger done = 0, n = [d length];
    while (done < n) {
        NSInteger w = [stream write:b + done maxLength:n - done];
        if (w <= 0) {
            if (error) *error = [stream streamError];
            return 0;
        }
        done += (NSUInteger)w;
    }
    return (NSInteger)n;
}

+ (id)JSONObjectWithStream:(NSInputStream *)stream options:(NSJSONReadingOptions)opt error:(NSError **)error
{
    NSMutableData *d = [NSMutableData data];
    uint8_t buf[4096];
    NSInteger n;
    while ((n = [stream read:buf maxLength:sizeof(buf)]) > 0) [d appendBytes:buf length:(NSUInteger)n];
    if (n < 0) {
        if (error) *error = [stream streamError];
        return nil;
    }
    return [self JSONObjectWithData:d options:opt error:error];
}

@end
