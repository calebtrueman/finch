/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Code requirements: Apple's requirement language, compiled to and from the
 * binary form (magic 0xfade0c00) Apple's code signatures carry, and evaluated
 * against signed code. The language and the binary layout follow Apple's
 * published grammar (Security's requirements.grammar) and requirement.h; the
 * parser, printer and evaluator are Finch's.
 */
#include "SecInternal.h"
#include "SecCodeInternal.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
	opFalse, opTrue, opIdent, opAppleAnchor, opAnchorHash, opInfoKeyValue, opAnd, opOr, opCDHash,
	opNot, opInfoKeyField, opCertField, opTrustedCert, opTrustedCerts, opCertGeneric,
	opAppleGenericAnchor, opEntitlementField, opCertPolicy, opNamedAnchor, opNamedCode, opPlatform,
	opNotarized, opCertFieldDate, opLegacyDevID,
};
enum { opFlagMask = 0xFF000000, opGenericFalse = 0x80000000, opGenericSkip = 0x40000000 };
enum {
	matchExists, matchEqual, matchContains, matchBeginsWith, matchEndsWith, matchLessThan,
	matchGreaterThan, matchLessEqual, matchGreaterEqual, matchOn, matchBefore, matchAfter,
	matchOnOrBefore, matchOnOrAfter, matchAbsent,
};
enum { kLeafCert = 0, kAnchorCert = -1 };
#define kRequirementMagic 0xfade0c00u
#define kRequirementsMagic 0xfade0c01u

/* ---- The object ---- */

typedef struct {
	CFRuntimeBase base;
	CFDataRef blob;
} Requirement;

static void reqFree(CFTypeRef o)
{
	CFRelease(((Requirement *)o)->blob);
}
static Boolean reqEqual(CFTypeRef a, CFTypeRef b)
{
	return CFEqual(((Requirement *)a)->blob, ((Requirement *)b)->blob);
}
static CFHashCode reqHash(CFTypeRef a)
{
	return CFHash(((Requirement *)a)->blob);
}
SEC_DEFINE_TYPE(SecRequirementGetTypeID, "SecRequirement", reqFree, reqEqual, reqHash)

static uint32_t be32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static bool validBlob(CFDataRef d)
{
	if (!d || CFGetTypeID(d) != CFDataGetTypeID() || CFDataGetLength(d) < 12)
		return false;
	const uint8_t *p = CFDataGetBytePtr(d);
	return be32(p) == kRequirementMagic && be32(p + 4) == (uint32_t)CFDataGetLength(d) && be32(p + 8) == 1;
}

SecRequirementRef _SecRequirementCreate(CFDataRef blob)
{
	Requirement *r = (Requirement *)_SecCreateInstance(SecRequirementGetTypeID(), sizeof(*r));
	r->blob = CFDataCreateCopy(NULL, blob);
	return (SecRequirementRef)r;
}

CFDataRef _SecRequirementGetData(SecRequirementRef r)
{
	return ((Requirement *)r)->blob;
}

/* ---- Compiling ---- */

typedef struct {
	CFMutableDataRef out;
	const char *p;
	const char *error;
} Parser;

static void put32(Parser *ps, uint32_t v)
{
	uint8_t b[4] = {v >> 24, v >> 16, v >> 8, v};
	CFDataAppendBytes(ps->out, b, 4);
}
static void putData(Parser *ps, const void *data, size_t n)
{
	static const uint8_t zero[4];
	put32(ps, (uint32_t)n);
	CFDataAppendBytes(ps->out, data, n);
	if (n % 4)
		CFDataAppendBytes(ps->out, zero, 4 - n % 4);
}
/* Inserts an op before the expression that starts at offset `at`. */
static void insert32(Parser *ps, CFIndex at, uint32_t v)
{
	uint8_t b[4] = {v >> 24, v >> 16, v >> 8, v};
	CFDataReplaceBytes(ps->out, CFRangeMake(at, 0), b, 4);
}

/* Tokens */
enum { tEnd, tWord, tString, tHash, tHex, tInt, tPath, tPunct, tError };
typedef struct {
	int type;
	char text[1024];
	size_t len;
} Token;

static void skipSpace(Parser *ps)
{
	for (;;) {
		while (*ps->p == ' ' || *ps->p == '\t' || *ps->p == '\n' || *ps->p == '\r')
			ps->p++;
		if (*ps->p == '#' || (ps->p[0] == '/' && ps->p[1] == '/')) {
			while (*ps->p && *ps->p != '\n')
				ps->p++;
		} else if (ps->p[0] == '/' && ps->p[1] == '*') {
			const char *e = strstr(ps->p + 2, "*/");
			ps->p = e ? e + 2 : ps->p + strlen(ps->p);
		} else
			return;
	}
}

static bool isIdentStart(char c)
{
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

/* Reads a token without consuming it. */
static const char *lex(Parser *ps, Token *t)
{
	skipSpace(ps);
	const char *s = ps->p;
	t->len = 0;
	t->text[0] = 0;
	if (!*s) {
		t->type = tEnd;
		return s;
	}
	if (s[0] == 'H' && s[1] == '"') {
		const char *e = s + 2;
		while (isxdigit((unsigned char)*e))
			e++;
		if (*e != '"' || e == s + 2) {
			t->type = tError;
			return s;
		}
		t->type = tHash;
		t->len = e - (s + 2);
		memcpy(t->text, s + 2, t->len < sizeof(t->text) - 1 ? t->len : sizeof(t->text) - 1);
		t->text[t->len] = 0;
		return e + 1;
	}
	if (s[0] == '0' && s[1] == 'x') {
		const char *e = s + 2;
		while (isxdigit((unsigned char)*e))
			e++;
		t->type = tHex;
		t->len = e - (s + 2);
		memcpy(t->text, s + 2, t->len);
		t->text[t->len] = 0;
		return e;
	}
	if (isIdentStart(*s)) {
		/* DOTKEY: IDENT ( "." ( IDENT | INTEGER ) )* */
		const char *e = s;
		for (;;) {
			while (isalnum((unsigned char)*e))
				e++;
			if (e[0] == '.' && (isalnum((unsigned char)e[1])))
				e++;
			else
				break;
		}
		t->type = tWord;
		t->len = e - s;
		if (t->len >= sizeof(t->text))
			t->len = sizeof(t->text) - 1;
		memcpy(t->text, s, t->len);
		t->text[t->len] = 0;
		return e;
	}
	if (isdigit((unsigned char)*s)) {
		const char *e = s;
		while (isdigit((unsigned char)*e))
			e++;
		t->type = tInt;
		t->len = e - s;
		memcpy(t->text, s, t->len);
		t->text[t->len] = 0;
		return e;
	}
	if (*s == '"') {
		const char *e = s + 1;
		while (*e && *e != '"') {
			if (*e == '\\' && e[1] == '"')
				e++;
			if (t->len < sizeof(t->text) - 1)
				t->text[t->len++] = *e;
			e++;
		}
		if (*e != '"') {
			t->type = tError;
			return s;
		}
		t->text[t->len] = 0;
		t->type = tString;
		return e + 1;
	}
	if (*s == '/' && isIdentStart(s[1])) {
		const char *e = s;
		int parts = 0;
		while (*e == '/' && isIdentStart(e[1])) {
			e++;
			while (isalnum((unsigned char)*e))
				e++;
			parts++;
		}
		if (parts >= 2) {
			t->type = tPath;
			t->len = e - s;
			memcpy(t->text, s, t->len);
			t->text[t->len] = 0;
			return e;
		}
	}
	static const char *two[] = {"=>", "<=", ">=", "==", NULL};
	for (int i = 0; two[i]; i++)
		if (s[0] == two[i][0] && s[1] == two[i][1]) {
			t->type = tPunct;
			memcpy(t->text, s, 2);
			t->text[2] = 0;
			t->len = 2;
			return s + 2;
		}
	if (strchr(";()[]<>,=~-!*", *s)) {
		t->type = tPunct;
		t->text[0] = *s;
		t->text[1] = 0;
		t->len = 1;
		return s + 1;
	}
	t->type = tError;
	return s;
}

static bool peek(Parser *ps, Token *t)
{
	lex(ps, t);
	return t->type != tError;
}
static void next(Parser *ps, Token *t)
{
	ps->p = lex(ps, t);
}
static bool acceptWord(Parser *ps, const char *w)
{
	Token t;
	const char *after = lex(ps, &t);
	if (t.type == tWord && strcmp(t.text, w) == 0) {
		ps->p = after;
		return true;
	}
	return false;
}
static bool acceptPunct(Parser *ps, const char *w)
{
	Token t;
	const char *after = lex(ps, &t);
	if (t.type == tPunct && strcmp(t.text, w) == 0) {
		ps->p = after;
		return true;
	}
	return false;
}
static void fail(Parser *ps, const char *msg)
{
	if (!ps->error)
		ps->error = msg;
}

static const char *const keywords[] = {"guest", "host", "designated", "library", "plugin", "or", "and",
    "always", "true", "never", "false", "identifier", "cdhash", "platform", "notarized", "legacy", "anchor",
    "apple", "generic", "certificate", "cert", "trusted", "info", "entitlement", "exists", "absent", "leaf",
    "root", "timestamp", NULL};

static bool isKeyword(const char *s)
{
	for (int i = 0; keywords[i]; i++)
		if (strcmp(s, keywords[i]) == 0)
			return true;
	return false;
}

/* identifierString / stringvalue: a DOTKEY (not a keyword) or a quoted string. */
static bool stringValue(Parser *ps, Token *t, bool allowPath)
{
	next(ps, t);
	if (t->type == tString || (t->type == tWord && !isKeyword(t->text)) || (allowPath && t->type == tPath))
		return true;
	fail(ps, "expected a string");
	return false;
}

static void eql(Parser *ps)
{
	if (!acceptPunct(ps, "=="))
		acceptPunct(ps, "=");
}

static int hexValue(char c)
{
	return isdigit((unsigned char)c) ? c - '0' : (tolower((unsigned char)c) - 'a' + 10);
}
static size_t hexDecode(const char *s, size_t n, uint8_t *out)
{
	for (size_t i = 0; i + 1 < n + 1 && i < n; i += 2)
		out[i / 2] = (uint8_t)(hexValue(s[i]) << 4 | hexValue(s[i + 1]));
	return n / 2;
}

static bool hashValue(Parser *ps, uint8_t digest[20])
{
	Token t;
	next(ps, &t);
	if (t.type != tHash || t.len != 40) {
		fail(ps, "invalid hash");
		return false;
	}
	hexDecode(t.text, 40, digest);
	return true;
}

/* An OID in dotted form, encoded as DER content bytes. */
static bool encodeOID(const char *s, uint8_t *out, size_t *len)
{
	unsigned long arcs[64];
	int n = 0;
	const char *p = s;
	while (*p && n < 64) {
		if (!isdigit((unsigned char)*p))
			return false;
		arcs[n++] = strtoul(p, (char **)&p, 10);
		if (*p == '.')
			p++;
		else if (*p)
			return false;
	}
	if (n < 2)
		return false;
	size_t o = 0;
	unsigned long first = arcs[0] * 40 + arcs[1];
	for (int i = 1; i < n; i++) {
		unsigned long v = i == 1 ? first : arcs[i];
		uint8_t tmp[10];
		int k = 0;
		do {
			tmp[k++] = v & 0x7f;
			v >>= 7;
		} while (v);
		while (k > 0) {
			k--;
			out[o++] = tmp[k] | (k ? 0x80 : 0);
		}
	}
	*len = o;
	return true;
}

static void matchSuffix(Parser *ps)
{
	Token t;
	peek(ps, &t);
	if (t.type == tPunct && (!strcmp(t.text, "=") || !strcmp(t.text, "=="))) {
		next(ps, &t);
		uint32_t op = matchEqual;
		if (acceptPunct(ps, "*"))
			op = matchEndsWith;
		Token v;
		next(ps, &v);
		uint8_t buf[512];
		const void *data = v.text;
		size_t n = v.len;
		if (v.type == tHex) {
			if (v.len % 2) {
				fail(ps, "odd number of digits");
				return;
			}
			n = hexDecode(v.text, v.len, buf);
			data = buf;
		} else if (v.type == tWord && !strcmp(v.text, "timestamp")) {
			fail(ps, "timestamps aren't supported");
			return;
		} else if (!(v.type == tString || (v.type == tWord && !isKeyword(v.text)))) {
			fail(ps, "expected a value");
			return;
		}
		if (acceptPunct(ps, "*"))
			op = op == matchEndsWith ? matchContains : matchBeginsWith;
		put32(ps, op);
		putData(ps, data, n);
		return;
	}
	struct {
		const char *punct;
		uint32_t op;
	} ops[] = {{"~", matchContains}, {"<=", matchLessEqual}, {">=", matchGreaterEqual},
	    {"<", matchLessThan}, {">", matchGreaterThan}};
	for (size_t i = 0; i < sizeof(ops) / sizeof(*ops); i++)
		if (acceptPunct(ps, ops[i].punct)) {
			Token v;
			if (!stringValue(ps, &v, false))
				return;
			put32(ps, ops[i].op);
			putData(ps, v.text, v.len);
			return;
		}
	if (acceptWord(ps, "absent")) {
		put32(ps, matchAbsent);
		return;
	}
	acceptWord(ps, "exists");
	put32(ps, matchExists);
}

static bool bracketKey(Parser *ps, Token *key)
{
	if (!acceptPunct(ps, "[")) {
		fail(ps, "expected [");
		return false;
	}
	if (!stringValue(ps, key, false))
		return false;
	if (!acceptPunct(ps, "]")) {
		fail(ps, "expected ]");
		return false;
	}
	return true;
}

static void certMatch(Parser *ps, int32_t slot, const char *key)
{
	const char *prefixes[] = {"timestamp.", "subject.", "field.", "extension.", "policy."};
	uint32_t ops[] = {opCertFieldDate, opCertField, opCertGeneric, opCertGeneric, opCertPolicy};
	for (int i = 0; i < 5; i++) {
		size_t n = strlen(prefixes[i]);
		if (strncmp(key, prefixes[i], n))
			continue;
		put32(ps, ops[i]);
		put32(ps, (uint32_t)slot);
		if (ops[i] == opCertField)
			putData(ps, key, strlen(key));
		else {
			uint8_t oid[256];
			size_t len = 0;
			if (!encodeOID(key + n, oid, &len)) {
				fail(ps, "invalid OID");
				return;
			}
			putData(ps, oid, len);
		}
		matchSuffix(ps);
		return;
	}
	fail(ps, "unrecognized certificate field");
}

static bool certSlot(Parser *ps, int32_t *slot)
{
	Token t;
	if (acceptPunct(ps, "-")) {
		next(ps, &t);
		if (t.type != tInt)
			return false;
		*slot = -atoi(t.text);
		return true;
	}
	if (acceptWord(ps, "leaf")) {
		*slot = kLeafCert;
		return true;
	}
	if (acceptWord(ps, "root")) {
		*slot = kAnchorCert;
		return true;
	}
	peek(ps, &t);
	if (t.type == tInt) {
		next(ps, &t);
		*slot = atoi(t.text);
		return true;
	}
	return false;
}

/* certslotspec: "= hash" or "[key] match" */
static void certSlotSpec(Parser *ps, int32_t slot)
{
	Token t;
	peek(ps, &t);
	if (t.type == tPunct && !strcmp(t.text, "[")) {
		Token key;
		if (bracketKey(ps, &key))
			certMatch(ps, slot, key.text);
		return;
	}
	eql(ps);
	uint8_t digest[20];
	if (!hashValue(ps, digest))
		return;
	put32(ps, opAnchorHash);
	put32(ps, (uint32_t)slot);
	putData(ps, digest, 20);
}

static void expr(Parser *ps);

static void primary(Parser *ps)
{
	Token t;
	if (ps->error)
		return;
	peek(ps, &t);
	if (t.type == tPunct && !strcmp(t.text, "(")) {
		next(ps, &t);
		/* ( identifierString ) is a named code requirement */
		const char *save = ps->p;
		Token name;
		next(ps, &name);
		if ((name.type == tString || (name.type == tWord && !isKeyword(name.text))) && acceptPunct(ps, ")")) {
			put32(ps, opNamedCode);
			putData(ps, name.text, name.len);
			return;
		}
		ps->p = save;
		expr(ps);
		if (!acceptPunct(ps, ")"))
			fail(ps, "expected )");
		return;
	}
	if (t.type == tPunct && !strcmp(t.text, "!")) {
		next(ps, &t);
		put32(ps, opNot);
		primary(ps);
		return;
	}
	if (t.type != tWord) {
		fail(ps, "unexpected token");
		return;
	}
	next(ps, &t);
	const char *w = t.text;
	if (!strcmp(w, "always") || !strcmp(w, "true"))
		put32(ps, opTrue);
	else if (!strcmp(w, "never") || !strcmp(w, "false"))
		put32(ps, opFalse);
	else if (!strcmp(w, "identifier")) {
		eql(ps);
		Token v;
		if (stringValue(ps, &v, false)) {
			put32(ps, opIdent);
			putData(ps, v.text, v.len);
		}
	} else if (!strcmp(w, "cdhash")) {
		eql(ps);
		uint8_t digest[20];
		if (hashValue(ps, digest)) {
			put32(ps, opCDHash);
			putData(ps, digest, 20);
		}
	} else if (!strcmp(w, "platform")) {
		eql(ps);
		Token v;
		next(ps, &v);
		if (v.type != tInt)
			fail(ps, "expected a number");
		else {
			put32(ps, opPlatform);
			put32(ps, (uint32_t)atoi(v.text));
		}
	} else if (!strcmp(w, "notarized"))
		put32(ps, opNotarized);
	else if (!strcmp(w, "legacy"))
		put32(ps, opLegacyDevID);
	else if (!strcmp(w, "info") || !strcmp(w, "entitlement")) {
		Token key;
		if (bracketKey(ps, &key)) {
			put32(ps, w[0] == 'i' ? opInfoKeyField : opEntitlementField);
			putData(ps, key.text, key.len);
			matchSuffix(ps);
		}
	} else if (!strcmp(w, "anchor")) {
		if (acceptWord(ps, "apple")) {
			if (acceptWord(ps, "generic"))
				put32(ps, opAppleGenericAnchor);
			else {
				Token n;
				peek(ps, &n);
				if (n.type == tString || (n.type == tWord && !isKeyword(n.text))) {
					next(ps, &n);
					put32(ps, opNamedAnchor);
					putData(ps, n.text, n.len);
				} else
					put32(ps, opAppleAnchor);
			}
		} else if (acceptWord(ps, "generic")) {
			if (acceptWord(ps, "apple"))
				put32(ps, opAppleGenericAnchor);
			else
				fail(ps, "expected apple");
		} else if (acceptWord(ps, "trusted"))
			put32(ps, opTrustedCerts);
		else
			certSlotSpec(ps, kAnchorCert);
	} else if (!strcmp(w, "certificate") || !strcmp(w, "cert")) {
		if (acceptWord(ps, "trusted")) {
			put32(ps, opTrustedCerts);
			return;
		}
		int32_t slot;
		if (!certSlot(ps, &slot)) {
			fail(ps, "expected a certificate slot");
			return;
		}
		if (acceptWord(ps, "trusted")) {
			put32(ps, opTrustedCert);
			put32(ps, (uint32_t)slot);
		} else
			certSlotSpec(ps, slot);
	} else
		fail(ps, "unexpected word");
}

static void term(Parser *ps)
{
	CFIndex label = CFDataGetLength(ps->out);
	primary(ps);
	while (!ps->error && acceptWord(ps, "and")) {
		insert32(ps, label, opAnd);
		primary(ps);
	}
}

static void expr(Parser *ps)
{
	CFIndex label = CFDataGetLength(ps->out);
	term(ps);
	while (!ps->error && acceptWord(ps, "or")) {
		insert32(ps, label, opOr);
		term(ps);
	}
}

static CFDataRef compile(const char *text)
{
	Parser ps = {CFDataCreateMutable(NULL, 0), text, NULL};
	put32(&ps, kRequirementMagic);
	put32(&ps, 0);
	put32(&ps, 1);   /* expression form */
	expr(&ps);
	while (!ps.error && acceptPunct(&ps, ";"))
		;
	Token t;
	if (!ps.error && (lex(&ps, &t), t.type != tEnd))
		fail(&ps, "unexpected trailing text");
	if (ps.error) {
		CFRelease(ps.out);
		return NULL;
	}
	uint32_t n = (uint32_t)CFDataGetLength(ps.out);
	uint8_t b[4] = {n >> 24, n >> 16, n >> 8, n};
	CFDataReplaceBytes(ps.out, CFRangeMake(4, 4), b, 4);
	return ps.out;
}

/* ---- Printing ---- */

typedef struct {
	const uint8_t *p, *end;
	CFMutableStringRef s;
	bool bad;
} Reader;

static uint32_t get32(Reader *r)
{
	if (r->p + 4 > r->end) {
		r->bad = true;
		return 0;
	}
	uint32_t v = be32(r->p);
	r->p += 4;
	return v;
}
static bool getData(Reader *r, const uint8_t **data, size_t *n)
{
	uint32_t len = get32(r);
	size_t padded = (len + 3) & ~3u;
	if (r->bad || r->p + padded > r->end || padded < len) {
		r->bad = true;
		return false;
	}
	*data = r->p;
	*n = len;
	r->p += padded;
	return true;
}
static void emit(Reader *r, const char *fmt, ...)
{
	char buf[2048];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	CFStringAppendCString(r->s, buf, kCFStringEncodingUTF8);
}
static void emitBytes(Reader *r, const uint8_t *p, size_t n)
{
	for (size_t i = 0; i < n; i++)
		emit(r, "%02x", p[i]);
}

enum { isSimple, isPrintable, isBinary };
static void dumpData(Reader *r, int mode, bool dotOkay)
{
	const uint8_t *d;
	size_t n;
	if (!getData(r, &d, &n))
		return;
	for (size_t i = 0; i < n; i++) {
		if (isalnum(d[i]) || (d[i] == '.' && dotOkay)) {
			if (i == 0 && isdigit(d[i]))
				mode = isPrintable;
		} else if (isgraph(d[i]) || isspace(d[i])) {
			if (mode == isSimple)
				mode = isPrintable;
		} else {
			mode = isBinary;
			break;
		}
	}
	if (mode == isSimple) {
		char tmp[1024];
		size_t m = n < sizeof(tmp) - 1 ? n : sizeof(tmp) - 1;
		memcpy(tmp, d, m);
		tmp[m] = 0;
		if (isKeyword(tmp) || n == 0)
			mode = isPrintable;
	}
	if (mode == isSimple)
		emit(r, "%.*s", (int)n, d);
	else if (mode == isPrintable) {
		emit(r, "\"");
		for (size_t i = 0; i < n; i++)
			emit(r, d[i] == '\\' || d[i] == '"' ? "\\%c" : "%c", d[i]);
		emit(r, "\"");
	} else {
		emit(r, "0x");
		emitBytes(r, d, n);
	}
}
static void hashData(Reader *r)
{
	const uint8_t *d;
	size_t n;
	if (!getData(r, &d, &n))
		return;
	emit(r, "H\"");
	emitBytes(r, d, n);
	emit(r, "\"");
}
static void certSlotText(Reader *r)
{
	int32_t slot = (int32_t)get32(r);
	if (slot == kAnchorCert)
		emit(r, " root");
	else if (slot == kLeafCert)
		emit(r, " leaf");
	else
		emit(r, " %d", slot);
}
static void oidText(Reader *r, const char *prefix)
{
	const uint8_t *d;
	size_t n;
	if (!getData(r, &d, &n))
		return;
	emit(r, "%s", prefix);
	unsigned long v = 0;
	bool first = true;
	for (size_t i = 0; i < n; i++) {
		v = (v << 7) | (d[i] & 0x7f);
		if (d[i] & 0x80)
			continue;
		if (first) {
			unsigned long a = v < 80 ? v / 40 : 2;
			emit(r, "%lu.%lu", a, v - a * 40);
			first = false;
		} else
			emit(r, ".%lu", v);
		v = 0;
	}
}
static void matchText(Reader *r)
{
	uint32_t op = get32(r);
	switch (op) {
	case matchExists: emit(r, " /* exists */"); break;
	case matchAbsent: emit(r, " absent "); break;
	case matchEqual: emit(r, " = "); dumpData(r, isSimple, false); break;
	case matchContains: emit(r, " ~ "); dumpData(r, isSimple, false); break;
	case matchBeginsWith: emit(r, " = "); dumpData(r, isSimple, false); emit(r, "*"); break;
	case matchEndsWith: emit(r, " = *"); dumpData(r, isSimple, false); break;
	case matchLessThan: emit(r, " < "); dumpData(r, isSimple, false); break;
	case matchGreaterEqual: emit(r, " >= "); dumpData(r, isSimple, false); break;
	case matchLessEqual: emit(r, " <= "); dumpData(r, isSimple, false); break;
	case matchGreaterThan: emit(r, " > "); dumpData(r, isSimple, false); break;
	case matchOn: case matchBefore: case matchAfter: case matchOnOrBefore: case matchOnOrAfter: {
		static const char *ops[] = {" = ", " < ", " > ", " <= ", " >= "};
		uint32_t hi = get32(r), lo = get32(r);
		int64_t t = (int64_t)(((uint64_t)hi << 32) | lo);
		emit(r, "%s<%lld>", ops[op - matchOn], (long long)t);
		break;
	}
	default: emit(r, "MATCH OPCODE %u NOT UNDERSTOOD", op); break;
	}
}

enum { slPrimary, slAnd, slOr };
static void exprText(Reader *r, int level)
{
	if (r->bad)
		return;
	uint32_t op = get32(r);
	switch (op & ~opFlagMask) {
	case opFalse: emit(r, "never"); break;
	case opTrue: emit(r, "always"); break;
	case opIdent: emit(r, "identifier "); dumpData(r, isSimple, false); break;
	case opAppleAnchor: emit(r, "anchor apple"); break;
	case opAppleGenericAnchor: emit(r, "anchor apple generic"); break;
	case opAnchorHash: emit(r, "certificate"); certSlotText(r); emit(r, " = "); hashData(r); break;
	case opInfoKeyValue: emit(r, "info["); dumpData(r, isSimple, true); emit(r, "] = "); dumpData(r, isSimple, false); break;
	case opAnd:
	case opOr: {
		int l = (op & ~opFlagMask) == opAnd ? slAnd : slOr;
		if (level < l)
			emit(r, "(");
		exprText(r, l);
		emit(r, l == slAnd ? " and " : " or ");
		exprText(r, l);
		if (level < l)
			emit(r, ")");
		break;
	}
	case opNot: emit(r, "! "); exprText(r, slPrimary); break;
	case opCDHash: emit(r, "cdhash "); hashData(r); break;
	case opInfoKeyField: emit(r, "info["); dumpData(r, isSimple, true); emit(r, "]"); matchText(r); break;
	case opEntitlementField: emit(r, "entitlement["); dumpData(r, isSimple, true); emit(r, "]"); matchText(r); break;
	case opCertField: emit(r, "certificate"); certSlotText(r); emit(r, "["); dumpData(r, isSimple, true); emit(r, "]"); matchText(r); break;
	case opCertFieldDate: emit(r, "certificate"); certSlotText(r); emit(r, "["); oidText(r, "timestamp."); emit(r, "]"); matchText(r); break;
	case opCertGeneric: emit(r, "certificate"); certSlotText(r); emit(r, "["); oidText(r, "field."); emit(r, "]"); matchText(r); break;
	case opCertPolicy: emit(r, "certificate"); certSlotText(r); emit(r, "["); oidText(r, "policy."); emit(r, "]"); matchText(r); break;
	case opTrustedCert: emit(r, "certificate"); certSlotText(r); emit(r, "trusted"); break;
	case opTrustedCerts: emit(r, "anchor trusted"); break;
	case opNamedAnchor: emit(r, "anchor apple "); dumpData(r, isSimple, false); break;
	case opNamedCode: emit(r, "("); dumpData(r, isSimple, false); emit(r, ")"); break;
	case opPlatform: emit(r, "platform = %d", (int32_t)get32(r)); break;
	case opNotarized: emit(r, "notarized"); break;
	case opLegacyDevID: emit(r, "legacy"); break;
	default:
		if (op & (opGenericFalse | opGenericSkip)) {
			const uint8_t *d;
			size_t n;
			getData(r, &d, &n);
			emit(r, (op & opGenericFalse) ? " false /* opcode %u */" : " /* opcode %u */", op & ~opFlagMask);
		} else {
			emit(r, "OPCODE %u NOT UNDERSTOOD (ending print)", op);
			r->bad = true;
		}
	}
}

static CFStringRef copyText(CFDataRef blob)
{
	Reader r = {CFDataGetBytePtr(blob) + 12, CFDataGetBytePtr(blob) + CFDataGetLength(blob), CFStringCreateMutable(NULL, 0), false};
	exprText(&r, slOr);
	return r.s;
}

/* A requirement set (the signature's requirements blob), as text. */
CFStringRef _SecRequirementsCopyText(const uint8_t *p, size_t n)
{
	CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
	if (n < 12 || be32(p) != kRequirementsMagic)
		return s;
	uint32_t count = be32(p + 8);
	static const char *names[] = {NULL, "host", "guest", "designated", "library", "plugin"};
	for (uint32_t i = 0; i < count && 12 + 8 * (i + 1) <= n; i++) {
		uint32_t type = be32(p + 12 + 8 * i), off = be32(p + 16 + 8 * i);
		if (off + 8 > n || be32(p + off) != kRequirementMagic || off + be32(p + off + 4) > n)
			continue;
		CFDataRef blob = CFDataCreate(NULL, p + off, be32(p + off + 4));
		CFStringRef text = copyText(blob);
		if (type < 6 && names[type])
			CFStringAppendFormat(s, NULL, CFSTR("%s => %@\n"), names[type], text);
		else
			CFStringAppendFormat(s, NULL, CFSTR("%u => %@\n"), type, text);
		CFRelease(text);
		CFRelease(blob);
	}
	return s;
}

/* The requirement of one type from a requirement set, or NULL. */
SecRequirementRef _SecRequirementsCopyType(const uint8_t *p, size_t n, uint32_t wanted)
{
	if (n < 12 || be32(p) != kRequirementsMagic)
		return NULL;
	uint32_t count = be32(p + 8);
	for (uint32_t i = 0; i < count && 12 + 8 * (i + 1) <= n; i++) {
		uint32_t type = be32(p + 12 + 8 * i), off = be32(p + 16 + 8 * i);
		if (type != wanted || off + 8 > n || off + be32(p + off + 4) > n)
			continue;
		CFDataRef blob = CFDataCreate(NULL, p + off, be32(p + off + 4));
		SecRequirementRef r = validBlob(blob) ? _SecRequirementCreate(blob) : NULL;
		CFRelease(blob);
		return r;
	}
	return NULL;
}

/* ---- Evaluation ---- */

typedef struct {
	const SecCodeContext *ctx;
	const uint8_t *p, *end;
	bool bad;
} Eval;

static uint32_t evGet32(Eval *e)
{
	if (e->p + 4 > e->end) {
		e->bad = true;
		return 0;
	}
	uint32_t v = be32(e->p);
	e->p += 4;
	return v;
}
static bool evData(Eval *e, const uint8_t **d, size_t *n)
{
	uint32_t len = evGet32(e);
	size_t padded = (len + 3) & ~3u;
	if (e->bad || e->p + padded > e->end) {
		e->bad = true;
		return false;
	}
	*d = e->p;
	*n = len;
	e->p += padded;
	return true;
}

static bool matchValue(Eval *e, CFTypeRef value)
{
	uint32_t op = evGet32(e);
	if (op == matchExists)
		return value != NULL;
	if (op == matchAbsent)
		return value == NULL;
	if (op >= matchOn && op <= matchOnOrAfter) {
		evGet32(e);
		evGet32(e);
		return false;
	}
	const uint8_t *d;
	size_t n;
	if (!evData(e, &d, &n) || !value)
		return false;
	CFStringRef want = CFStringCreateWithBytes(NULL, d, n, kCFStringEncodingUTF8, false);
	CFStringRef have = NULL;
	if (CFGetTypeID(value) == CFStringGetTypeID())
		have = CFRetain(value);
	else if (CFGetTypeID(value) == CFBooleanGetTypeID())
		have = CFRetain(CFBooleanGetValue(value) ? CFSTR("true") : CFSTR("false"));
	else if (CFGetTypeID(value) == CFNumberGetTypeID())
		have = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@"), value);
	else if (CFGetTypeID(value) == CFArrayGetTypeID()) {
		/* An array matches if any element does (entitlement arrays). */
		bool any = false;
		for (CFIndex i = 0; !any && i < CFArrayGetCount(value); i++) {
			CFTypeRef v = CFArrayGetValueAtIndex(value, i);
			any = CFGetTypeID(v) == CFStringGetTypeID() && want && CFEqual(v, want);
		}
		if (want)
			CFRelease(want);
		return any;
	}
	bool ok = false;
	if (have && want) {
		CFRange all = CFRangeMake(0, CFStringGetLength(have));
		switch (op) {
		case matchEqual: ok = CFEqual(have, want); break;
		case matchContains: ok = CFStringFind(have, want, 0).location != kCFNotFound; break;
		case matchBeginsWith: ok = CFStringHasPrefix(have, want); break;
		case matchEndsWith: ok = CFStringHasSuffix(have, want); break;
		case matchLessThan: ok = CFStringCompareWithOptions(have, want, all, kCFCompareNumerically) < 0; break;
		case matchGreaterThan: ok = CFStringCompareWithOptions(have, want, all, kCFCompareNumerically) > 0; break;
		case matchLessEqual: ok = CFStringCompareWithOptions(have, want, all, kCFCompareNumerically) <= 0; break;
		case matchGreaterEqual: ok = CFStringCompareWithOptions(have, want, all, kCFCompareNumerically) >= 0; break;
		}
	}
	if (have)
		CFRelease(have);
	if (want)
		CFRelease(want);
	return ok;
}

static bool evalExpr(Eval *e);

/* Skips one expression without evaluating it (for short-circuiting). */
static void skipExpr(Eval *e)
{
	bool saved = e->bad;
	const SecCodeContext *ctx = e->ctx;
	SecCodeContext none = {0};
	e->ctx = &none;
	evalExpr(e);
	e->ctx = ctx;
	e->bad = e->bad || saved;
}

static SecCertificateRef certAt(const SecCodeContext *ctx, int32_t slot)
{
	if (!ctx->certificates)
		return NULL;
	CFIndex n = CFArrayGetCount(ctx->certificates);
	CFIndex i = slot == kAnchorCert ? n - 1 : slot >= 0 ? slot : n + slot;
	return i >= 0 && i < n ? (SecCertificateRef)CFArrayGetValueAtIndex(ctx->certificates, i) : NULL;
}

static bool evalExpr(Eval *e)
{
	if (e->bad)
		return false;
	const SecCodeContext *c = e->ctx;
	uint32_t op = evGet32(e);
	const uint8_t *d;
	size_t n;
	switch (op & ~opFlagMask) {
	case opFalse:
		return false;
	case opTrue:
		return true;
	case opIdent:
		if (!evData(e, &d, &n))
			return false;
		return c->identifier && CFStringGetLength(c->identifier) == (CFIndex)n &&
		    ({
			    char buf[1024];
			    CFStringGetCString(c->identifier, buf, sizeof(buf), kCFStringEncodingUTF8) && memcmp(buf, d, n) == 0;
		    });
	case opAppleAnchor:
	case opAppleGenericAnchor:
	case opTrustedCerts:
	case opNotarized:
	case opLegacyDevID:
		/* No Apple roots, no trust settings, no notarization tickets on Finch. */
		return false;
	case opAnchorHash: {
		int32_t slot = (int32_t)evGet32(e);
		if (!evData(e, &d, &n))
			return false;
		SecCertificateRef cert = certAt(c, slot);
		if (!cert)
			return false;
		CFDataRef der = SecCertificateCopyData(cert);
		CFDataRef h = _SecCodeCopySHA1(der);
		bool ok = h && CFDataGetLength(h) == (CFIndex)n && memcmp(CFDataGetBytePtr(h), d, n) == 0;
		if (h)
			CFRelease(h);
		CFRelease(der);
		return ok;
	}
	case opInfoKeyValue: {
		const uint8_t *k, *v;
		size_t kn, vn;
		if (!evData(e, &k, &kn) || !evData(e, &v, &vn))
			return false;
		CFStringRef key = CFStringCreateWithBytes(NULL, k, kn, kCFStringEncodingUTF8, false);
		CFTypeRef have = c->infoPlist && key ? CFDictionaryGetValue(c->infoPlist, key) : NULL;
		CFStringRef want = CFStringCreateWithBytes(NULL, v, vn, kCFStringEncodingUTF8, false);
		bool ok = have && want && CFEqual(have, want);
		if (key)
			CFRelease(key);
		if (want)
			CFRelease(want);
		return ok;
	}
	case opAnd: {
		bool a = evalExpr(e);
		if (!a) {
			skipExpr(e);
			return false;
		}
		return evalExpr(e);
	}
	case opOr: {
		bool a = evalExpr(e);
		if (a) {
			skipExpr(e);
			return true;
		}
		return evalExpr(e);
	}
	case opNot:
		return !evalExpr(e);
	case opCDHash: {
		if (!evData(e, &d, &n))
			return false;
		for (CFIndex i = 0; c->cdhashes && i < CFArrayGetCount(c->cdhashes); i++) {
			CFDataRef h = CFArrayGetValueAtIndex(c->cdhashes, i);
			if (CFDataGetLength(h) >= (CFIndex)n && memcmp(CFDataGetBytePtr(h), d, n) == 0)
				return true;
		}
		return false;
	}
	case opInfoKeyField:
	case opEntitlementField: {
		if (!evData(e, &d, &n))
			return false;
		CFDictionaryRef dict = (op & ~opFlagMask) == opInfoKeyField ? c->infoPlist : c->entitlements;
		CFStringRef key = CFStringCreateWithBytes(NULL, d, n, kCFStringEncodingUTF8, false);
		CFTypeRef v = dict && key ? CFDictionaryGetValue(dict, key) : NULL;
		if (key)
			CFRelease(key);
		return matchValue(e, v);
	}
	case opCertField:
	case opCertGeneric:
	case opCertPolicy:
	case opCertFieldDate: {
		int32_t slot = (int32_t)evGet32(e);
		if (!evData(e, &d, &n))
			return false;
		SecCertificateRef cert = certAt(c, slot);
		CFTypeRef v = cert ? _SecCodeCopyCertificateField(cert, op & ~opFlagMask, d, n) : NULL;
		bool ok = matchValue(e, v);
		if (v)
			CFRelease(v);
		return ok && cert;
	}
	case opTrustedCert:
		evGet32(e);
		return false;
	case opNamedAnchor:
	case opNamedCode:
		evData(e, &d, &n);
		return false;
	case opPlatform:
		return (int32_t)evGet32(e) == (int32_t)c->platform && c->platform != 0;
	default:
		if (op & (opGenericFalse | opGenericSkip)) {
			evData(e, &d, &n);
			return !(op & opGenericFalse);
		}
		e->bad = true;
		return false;
	}
}

bool _SecRequirementEvaluate(SecRequirementRef req, const SecCodeContext *ctx)
{
	CFDataRef blob = ((Requirement *)req)->blob;
	Eval e = {ctx, CFDataGetBytePtr(blob) + 12, CFDataGetBytePtr(blob) + CFDataGetLength(blob), false};
	bool ok = evalExpr(&e);
	return ok && !e.bad;
}

/* ---- API ---- */

OSStatus SecRequirementCreateWithData(CFDataRef data, SecCSFlags flags, SecRequirementRef *requirement)
{
	if (!requirement)
		return errSecCSInvalidObjectRef;
	*requirement = NULL;
	if (!validBlob(data))
		return errSecCSReqInvalid;
	*requirement = _SecRequirementCreate(data);
	return 0;
}

OSStatus SecRequirementCreateWithStringAndErrors(CFStringRef text, SecCSFlags flags, CFErrorRef *errors,
    SecRequirementRef *requirement)
{
	if (errors)
		*errors = NULL;
	if (!requirement || !text || CFGetTypeID(text) != CFStringGetTypeID())
		return errSecCSInvalidObjectRef;
	*requirement = NULL;
	CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(text), kCFStringEncodingUTF8) + 1;
	char *s = malloc(max);
	CFStringGetCString(text, s, max, kCFStringEncodingUTF8);
	CFDataRef blob = compile(s);
	free(s);
	if (!blob) {
		if (errors)
			*errors = _SecCreateError(errSecCSReqInvalid, NULL);
		return errSecCSReqInvalid;
	}
	*requirement = _SecRequirementCreate(blob);
	CFRelease(blob);
	return 0;
}

OSStatus SecRequirementCreateWithString(CFStringRef text, SecCSFlags flags, SecRequirementRef *requirement)
{
	return SecRequirementCreateWithStringAndErrors(text, flags, NULL, requirement);
}

OSStatus SecRequirementCopyData(SecRequirementRef requirement, SecCSFlags flags, CFDataRef *data)
{
	if (!requirement || CFGetTypeID(requirement) != SecRequirementGetTypeID() || !data)
		return errSecCSInvalidObjectRef;
	*data = CFRetain(((Requirement *)requirement)->blob);
	return 0;
}

OSStatus SecRequirementCopyString(SecRequirementRef requirement, SecCSFlags flags, CFStringRef *text)
{
	if (!requirement || CFGetTypeID(requirement) != SecRequirementGetTypeID() || !text)
		return errSecCSInvalidObjectRef;
	*text = copyText(((Requirement *)requirement)->blob);
	return 0;
}
