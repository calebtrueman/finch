/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * xpc_create_from_plist(): property lists (binary "bplist00" or XML) to XPC
 * objects. Used by much of libSystem (feature flags, configuration, bundles,
 * entitlements). Mapping: dict -> dictionary, array -> array, string ->
 * string, integer -> int64, real -> double, bool -> bool, date -> date
 * (ns since 1970), data -> data, UID -> uint64.
 *
 * Input may come from anywhere on disk: every offset and count is
 * bounds-checked, object references can't form cycles, and depth is limited.
 */

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "internal.h"

#define PLIST_MAX_DEPTH 256
#define APPLE_EPOCH_OFFSET 978307200.0   /* 2001-01-01 minus 1970-01-01, in seconds */

static xpc_object_t
_date_from_seconds_since_2001(double s)
{
	return xpc_date_create((int64_t)((s + APPLE_EPOCH_OFFSET) * 1e9));
}

#pragma mark - UTF-16 -> UTF-8

static xpc_object_t
_string_from_utf16be(const uint8_t *p, size_t units)
{
	char *out = malloc(units * 3 + 1), *o = out;
	xpc_object_t s;

	if (out == NULL) {
		abort();
	}
	for (size_t i = 0; i < units; i++) {
		uint32_t c = (uint32_t)p[2 * i] << 8 | p[2 * i + 1];
		if (c >= 0xd800 && c <= 0xdbff && i + 1 < units) {
			uint32_t lo = (uint32_t)p[2 * i + 2] << 8 | p[2 * i + 3];
			if (lo >= 0xdc00 && lo <= 0xdfff) {
				c = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
				i++;
			}
		}
		if (c < 0x80) {
			*o++ = (char)c;
		} else if (c < 0x800) {
			*o++ = (char)(0xc0 | c >> 6);
			*o++ = (char)(0x80 | (c & 0x3f));
		} else if (c < 0x10000) {
			*o++ = (char)(0xe0 | c >> 12);
			*o++ = (char)(0x80 | ((c >> 6) & 0x3f));
			*o++ = (char)(0x80 | (c & 0x3f));
		} else {
			*o++ = (char)(0xf0 | c >> 18);
			*o++ = (char)(0x80 | ((c >> 12) & 0x3f));
			*o++ = (char)(0x80 | ((c >> 6) & 0x3f));
			*o++ = (char)(0x80 | (c & 0x3f));
		}
	}
	s = _xpc_string_create_with_length(out, (size_t)(o - out));
	free(out);
	return s;
}

#pragma mark - Binary plist

struct bplist {
	const uint8_t *p;
	size_t len;
	uint8_t offset_size, ref_size;
	uint64_t num_objects, top, table;
	uint8_t *visiting;          /* cycle detection, one flag per object */
};

static bool
_be_uint(const uint8_t *p, size_t n, uint64_t *out)
{
	uint64_t v = 0;

	if (n == 0 || n > 8) {
		return false;
	}
	for (size_t i = 0; i < n; i++) {
		v = v << 8 | p[i];
	}
	*out = v;
	return true;
}

static bool
_bp_offset(struct bplist *bp, uint64_t obj, uint64_t *off)
{
	uint64_t at;

	if (obj >= bp->num_objects) {
		return false;
	}
	at = bp->table + obj * bp->offset_size;
	if (at + bp->offset_size > bp->len - 32 || !_be_uint(bp->p + at, bp->offset_size, off)) {
		return false;
	}
	return *off < bp->table;
}

/* Object count for a marker: low nibble, or 0xF followed by an int object. */
static bool
_bp_count(struct bplist *bp, uint64_t off, uint64_t *count, uint64_t *data_off)
{
	uint8_t nib = bp->p[off] & 0x0f;

	if (nib != 0x0f) {
		*count = nib;
		*data_off = off + 1;
		return true;
	}
	if (off + 2 > bp->table || (bp->p[off + 1] & 0xf0) != 0x10) {
		return false;
	}
	size_t isz = (size_t)1 << (bp->p[off + 1] & 0x0f);
	if (isz > 8 || off + 2 + isz > bp->table || !_be_uint(bp->p + off + 2, isz, count)) {
		return false;
	}
	*data_off = off + 2 + isz;
	return true;
}

static bool
_bp_span(struct bplist *bp, uint64_t off, uint64_t n)
{
	return off <= bp->table && n <= bp->table - off;
}

static xpc_object_t _bp_object(struct bplist *bp, uint64_t obj, int depth);

static xpc_object_t
_bp_object(struct bplist *bp, uint64_t obj, int depth)
{
	uint64_t off, count, data;
	xpc_object_t result = NULL;

	if (depth > PLIST_MAX_DEPTH || !_bp_offset(bp, obj, &off) || bp->visiting[obj]) {
		return NULL;
	}
	uint8_t marker = bp->p[off];
	switch (marker >> 4) {
	case 0x0:
		if (marker == 0x08) return xpc_bool_create(false);
		if (marker == 0x09) return xpc_bool_create(true);
		if (marker == 0x00) return xpc_null_create();
		return NULL;
	case 0x1: {
		size_t n = (size_t)1 << (marker & 0x0f);
		uint64_t v;
		if (n > 16 || !_bp_span(bp, off + 1, n)) return NULL;
		if (n == 16) {   /* 128-bit ints: keep the low 64 bits */
			return _be_uint(bp->p + off + 9, 8, &v) ? xpc_int64_create((int64_t)v) : NULL;
		}
		return _be_uint(bp->p + off + 1, n, &v) ? xpc_int64_create((int64_t)v) : NULL;
	}
	case 0x2: {
		size_t n = (size_t)1 << (marker & 0x0f);
		uint64_t bits;
		if ((n != 4 && n != 8) || !_bp_span(bp, off + 1, n) || !_be_uint(bp->p + off + 1, n, &bits)) {
			return NULL;
		}
		if (n == 4) {
			uint32_t b32 = (uint32_t)bits;
			float f;
			memcpy(&f, &b32, 4);
			return xpc_double_create(f);
		}
		double d;
		memcpy(&d, &bits, 8);
		return xpc_double_create(d);
	}
	case 0x3: {
		uint64_t bits;
		double d;
		if (marker != 0x33 || !_bp_span(bp, off + 1, 8) || !_be_uint(bp->p + off + 1, 8, &bits)) {
			return NULL;
		}
		memcpy(&d, &bits, 8);
		return _date_from_seconds_since_2001(d);
	}
	case 0x4:
		if (!_bp_count(bp, off, &count, &data) || !_bp_span(bp, data, count)) return NULL;
		return xpc_data_create(bp->p + data, (size_t)count);
	case 0x5:
		if (!_bp_count(bp, off, &count, &data) || !_bp_span(bp, data, count)) return NULL;
		return _xpc_string_create_with_length((const char *)bp->p + data, (size_t)count);
	case 0x6:
		if (!_bp_count(bp, off, &count, &data) || count > SIZE_MAX / 2 ||
		    !_bp_span(bp, data, count * 2)) {
			return NULL;
		}
		return _string_from_utf16be(bp->p + data, (size_t)count);
	case 0x8: {
		uint64_t v;
		size_t n = (size_t)(marker & 0x0f) + 1;
		if (!_bp_span(bp, off + 1, n) || !_be_uint(bp->p + off + 1, n, &v)) return NULL;
		return xpc_uint64_create(v);
	}
	case 0xa:
	case 0xd: {
		bool is_dict = (marker >> 4) == 0xd;
		uint64_t refs;
		if (!_bp_count(bp, off, &count, &data) || count > bp->num_objects) return NULL;
		refs = is_dict ? count * 2 : count;
		if (!_bp_span(bp, data, refs * bp->ref_size)) return NULL;
		bp->visiting[obj] = 1;
		result = is_dict ? xpc_dictionary_create(NULL, NULL, 0) : xpc_array_create(NULL, 0);
		for (uint64_t i = 0; i < count; i++) {
			uint64_t vref, kref;
			const uint8_t *vp = bp->p + data + (is_dict ? count + i : i) * bp->ref_size;
			if (!_be_uint(vp, bp->ref_size, &vref)) goto fail;
			xpc_object_t v = _bp_object(bp, vref, depth + 1);
			if (v == NULL) goto fail;
			if (is_dict) {
				if (!_be_uint(bp->p + data + i * bp->ref_size, bp->ref_size, &kref)) {
					xpc_release(v);
					goto fail;
				}
				xpc_object_t k = _bp_object(bp, kref, depth + 1);
				if (k == NULL || xpc_get_type(k) != XPC_TYPE_STRING) {
					if (k) xpc_release(k);
					xpc_release(v);
					goto fail;
				}
				xpc_dictionary_set_value(result, xpc_string_get_string_ptr(k), v);
				xpc_release(k);
			} else {
				xpc_array_append_value(result, v);
			}
			xpc_release(v);
		}
		bp->visiting[obj] = 0;
		return result;
	fail:
		bp->visiting[obj] = 0;
		xpc_release(result);
		return NULL;
	}
	default:
		return NULL;   /* sets (0xc), unknown markers */
	}
}

static xpc_object_t
_xpc_create_from_bplist(const uint8_t *p, size_t len)
{
	struct bplist bp = { .p = p, .len = len };
	const uint8_t *t;
	xpc_object_t o;

	if (len < 8 + 32) {
		return NULL;
	}
	t = p + len - 32;
	bp.offset_size = t[6];
	bp.ref_size = t[7];
	if (!_be_uint(t + 8, 8, &bp.num_objects) || !_be_uint(t + 16, 8, &bp.top) ||
	    !_be_uint(t + 24, 8, &bp.table)) {
		return NULL;
	}
	if (bp.offset_size < 1 || bp.offset_size > 8 || bp.ref_size < 1 || bp.ref_size > 8 ||
	    bp.table < 8 || bp.table >= len - 32 || bp.num_objects == 0 ||
	    bp.num_objects > (len - 32 - bp.table) / bp.offset_size || bp.top >= bp.num_objects) {
		return NULL;
	}
	bp.visiting = calloc((size_t)bp.num_objects, 1);
	if (bp.visiting == NULL) {
		return NULL;
	}
	o = _bp_object(&bp, bp.top, 0);
	free(bp.visiting);
	return o;
}

#pragma mark - XML plist

struct xml {
	const char *p, *end;
};

static void
_xml_skip_misc(struct xml *x)
{
	for (;;) {
		while (x->p < x->end && (*x->p == ' ' || *x->p == '\t' || *x->p == '\n' || *x->p == '\r')) {
			x->p++;
		}
		if (x->end - x->p >= 4 && memcmp(x->p, "<!--", 4) == 0) {
			const char *e = memmem(x->p + 4, (size_t)(x->end - x->p - 4), "-->", 3);
			x->p = e ? e + 3 : x->end;
		} else if (x->end - x->p >= 2 && (memcmp(x->p, "<?", 2) == 0 || memcmp(x->p, "<!", 2) == 0)) {
			const char *e = memchr(x->p, '>', (size_t)(x->end - x->p));
			x->p = e ? e + 1 : x->end;
		} else {
			return;
		}
	}
}

/* Reads "<name>" / "<name/>" / "</name>". */
static bool
_xml_tag(struct xml *x, char *name, size_t cap, bool *closing, bool *empty)
{
	const char *s;
	size_t n = 0;

	_xml_skip_misc(x);
	if (x->p >= x->end || *x->p != '<') {
		return false;
	}
	x->p++;
	*closing = x->p < x->end && *x->p == '/';
	if (*closing) x->p++;
	s = x->p;
	while (x->p < x->end && *x->p != '>' && *x->p != '/' && *x->p != ' ' && n + 1 < cap) {
		name[n++] = *x->p++;
	}
	name[n] = '\0';
	(void)s;
	while (x->p < x->end && *x->p != '>' && *x->p != '/') x->p++;   /* attributes */
	*empty = x->p < x->end && *x->p == '/';
	if (*empty) x->p++;
	if (x->p >= x->end || *x->p != '>') {
		return false;
	}
	x->p++;
	return n > 0;
}

/* Text up to "</tag>", with entities decoded. Caller frees. */
static char *
_xml_text(struct xml *x, const char *tag, size_t *len)
{
	char close[64];
	const char *e;
	char *out, *o;

	snprintf(close, sizeof(close), "</%s>", tag);
	e = memmem(x->p, (size_t)(x->end - x->p), close, strlen(close));
	if (e == NULL) {
		return NULL;
	}
	out = malloc((size_t)(e - x->p) + 1);
	if (out == NULL) {
		abort();
	}
	o = out;
	for (const char *s = x->p; s < e;) {
		if (*s != '&') {
			*o++ = *s++;
			continue;
		}
		const char *semi = memchr(s, ';', (size_t)(e - s));
		if (semi == NULL) {
			*o++ = *s++;
			continue;
		}
		size_t n = (size_t)(semi - s - 1);
		if (n == 2 && memcmp(s + 1, "lt", 2) == 0) *o++ = '<';
		else if (n == 2 && memcmp(s + 1, "gt", 2) == 0) *o++ = '>';
		else if (n == 3 && memcmp(s + 1, "amp", 3) == 0) *o++ = '&';
		else if (n == 4 && memcmp(s + 1, "quot", 4) == 0) *o++ = '"';
		else if (n == 4 && memcmp(s + 1, "apos", 4) == 0) *o++ = '\'';
		else if (n >= 2 && s[1] == '#') {
			unsigned long c = s[2] == 'x' ? strtoul(s + 3, NULL, 16) : strtoul(s + 2, NULL, 10);
			if (c < 0x80) *o++ = (char)c;
			else if (c < 0x800) { *o++ = (char)(0xc0 | c >> 6); *o++ = (char)(0x80 | (c & 0x3f)); }
			else if (c < 0x10000) { *o++ = (char)(0xe0 | c >> 12); *o++ = (char)(0x80 | ((c >> 6) & 0x3f)); *o++ = (char)(0x80 | (c & 0x3f)); }
			else { *o++ = (char)(0xf0 | c >> 18); *o++ = (char)(0x80 | ((c >> 12) & 0x3f)); *o++ = (char)(0x80 | ((c >> 6) & 0x3f)); *o++ = (char)(0x80 | (c & 0x3f)); }
		} else {
			memcpy(o, s, n + 2);   /* unknown entity: keep verbatim */
			o += n + 2;
		}
		s = semi + 1;
	}
	*o = '\0';
	*len = (size_t)(o - out);
	x->p = e + strlen(close);
	return out;
}

static xpc_object_t
_xml_base64(const char *s, size_t len)
{
	uint8_t *out = malloc(len / 4 * 3 + 3), *o = out;
	uint32_t acc = 0;
	int bits = 0;
	xpc_object_t d;

	if (out == NULL) {
		abort();
	}
	for (size_t i = 0; i < len; i++) {
		int v;
		char c = s[i];
		if (c >= 'A' && c <= 'Z') v = c - 'A';
		else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
		else if (c >= '0' && c <= '9') v = c - '0' + 52;
		else if (c == '+') v = 62;
		else if (c == '/') v = 63;
		else continue;   /* whitespace, '=' */
		acc = acc << 6 | (uint32_t)v;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			*o++ = (uint8_t)(acc >> bits);
		}
	}
	d = xpc_data_create(out, (size_t)(o - out));
	free(out);
	return d;
}

static xpc_object_t _xml_value(struct xml *x, const char *tag, bool empty, int depth);

static xpc_object_t
_xml_next_value(struct xml *x, int depth, bool *end_of_container, const char *container)
{
	char tag[32];
	bool closing, empty;

	*end_of_container = false;
	if (!_xml_tag(x, tag, sizeof(tag), &closing, &empty)) {
		return NULL;
	}
	if (closing) {
		*end_of_container = strcmp(tag, container) == 0;
		return NULL;
	}
	return _xml_value(x, tag, empty, depth);
}

static xpc_object_t
_xml_value(struct xml *x, const char *tag, bool empty, int depth)
{
	char *text;
	size_t len = 0;
	xpc_object_t o = NULL;
	bool end;

	if (depth > PLIST_MAX_DEPTH) {
		return NULL;
	}
	if (strcmp(tag, "true") == 0 || strcmp(tag, "false") == 0) {
		if (!empty) {   /* <true></true> */
			char *t = _xml_text(x, tag, &len);
			free(t);
		}
		return xpc_bool_create(tag[0] == 't');
	}
	if (strcmp(tag, "dict") == 0 || strcmp(tag, "array") == 0) {
		bool is_dict = tag[0] == 'd';
		o = is_dict ? xpc_dictionary_create(NULL, NULL, 0) : xpc_array_create(NULL, 0);
		if (empty) {
			return o;
		}
		for (;;) {
			if (is_dict) {
				char ktag[32];
				bool closing, kempty;
				if (!_xml_tag(x, ktag, sizeof(ktag), &closing, &kempty)) goto fail;
				if (closing && strcmp(ktag, "dict") == 0) return o;
				if (closing || strcmp(ktag, "key") != 0) goto fail;
				char *key = kempty ? strdup("") : _xml_text(x, "key", &len);
				if (key == NULL) goto fail;
				xpc_object_t v = _xml_next_value(x, depth + 1, &end, "dict");
				if (v == NULL) {
					free(key);
					goto fail;
				}
				xpc_dictionary_set_value(o, key, v);
				xpc_release(v);
				free(key);
			} else {
				xpc_object_t v = _xml_next_value(x, depth + 1, &end, "array");
				if (v == NULL) {
					if (end) return o;
					goto fail;
				}
				xpc_array_append_value(o, v);
				xpc_release(v);
			}
		}
	fail:
		xpc_release(o);
		return NULL;
	}
	if (empty) {
		if (strcmp(tag, "string") == 0) return xpc_string_create("");
		if (strcmp(tag, "data") == 0) return xpc_data_create(NULL, 0);
		return NULL;
	}
	text = _xml_text(x, tag, &len);
	if (text == NULL) {
		return NULL;
	}
	if (strcmp(tag, "string") == 0) {
		o = _xpc_string_create_with_length(text, len);
	} else if (strcmp(tag, "integer") == 0) {
		char *endp;
		const char *t = text;
		while (*t == ' ' || *t == '\n' || *t == '\t') t++;
		/* Decimal only, like Apple's libxpc: "0x0100000c" parses as 0 (launchd
		 * reads its plists through this function, so match it exactly). */
		o = (*t == '-') ? xpc_int64_create(strtoll(t, &endp, 10))
		                : xpc_int64_create((int64_t)strtoull(t, &endp, 10));
	} else if (strcmp(tag, "real") == 0) {
		o = xpc_double_create(strtod(text, NULL));
	} else if (strcmp(tag, "data") == 0) {
		o = _xml_base64(text, len);
	} else if (strcmp(tag, "date") == 0) {
		struct tm tm = { 0 };
		if (strptime(text, "%Y-%m-%dT%H:%M:%SZ", &tm) != NULL) {
			o = xpc_date_create((int64_t)timegm(&tm) * 1000000000LL);
		}
	}
	free(text);
	return o;
}

static xpc_object_t
_xpc_create_from_xml_plist(const char *p, size_t len)
{
	struct xml x = { p, p + len };
	char tag[32];
	bool closing, empty, end;
	xpc_object_t o;

	if (!_xml_tag(&x, tag, sizeof(tag), &closing, &empty) || closing) {
		return NULL;
	}
	if (strcmp(tag, "plist") != 0) {
		return _xml_value(&x, tag, empty, 0);   /* bare value, no <plist> wrapper */
	}
	if (empty) {
		return NULL;
	}
	o = _xml_next_value(&x, 0, &end, "plist");
	return o;
}

#pragma mark - Entry point

xpc_object_t
xpc_create_from_plist(const void *data, size_t length)
{
	if (data == NULL || length < 8) {
		return NULL;
	}
	if (memcmp(data, "bplist00", 8) == 0) {
		return _xpc_create_from_bplist(data, length);
	}
	return _xpc_create_from_xml_plist(data, length);
}
