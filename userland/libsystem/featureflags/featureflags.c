/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_featureflags: os_feature_enabled() and os_feature_enabled_simple()
 * (<os/feature_private.h>), Finch's replacement for Apple's closed library.
 *
 * A feature is looked up, first match wins, in:
 *   1. /Library/Preferences/FeatureFlags/Domain/<domain>.plist  (admin overrides)
 *   2. /System/Library/FeatureFlags/Global.plist                 ({domain: {feature: ...}})
 *   3. /System/Library/FeatureFlags/Domain/<domain>.plist
 *   4. /System/Library/FeatureFlags/Unified/Domain/<domain>.plist
 * Each feature entry is a dictionary: an "Enabled" boolean decides; otherwise
 * "DevelopmentPhase" = "FeatureComplete" means enabled, unless the entry names
 * a "DisclosureRequired" UUID that GlobalDisclosures.plist doesn't mark
 * "Disclosed". A feature found nowhere is disabled. Like Apple's,
 * os_feature_enabled_simple() also answers "disabled" for unknown features
 * whatever its third argument (checked against Apple's library on all 3,303
 * features in macOS 26.4's plists: tests/ff-compare.c).
 *
 * libmalloc asks while malloc itself is initializing, so nothing here
 * allocates: plists (XML or binary) are mapped and read in place.
 */

#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define FF_PATH_MAX 1024

bool _os_feature_enabled_impl(const char *domain, const char *feature);
bool _os_feature_enabled_simple_impl(const char *domain, const char *feature, bool fallback);

#pragma mark - Plist documents (XML or binary), read in place

struct doc {
	const uint8_t *base, *end;
	bool binary;
	/* bplist00 trailer */
	uint8_t offset_size, ref_size;
	uint64_t nobjects, top, offset_table;
};

/* A value: an XML element start, or a binary object index. NULL/UINT64_MAX = none. */
struct node {
	const char *xml;
	uint64_t obj;
};

static const struct node NONE = { NULL, UINT64_MAX };

static bool
present(struct node n)
{
	return n.xml != NULL || n.obj != UINT64_MAX;
}

#pragma mark XML

static bool
starts(const char *p, const char *end, const char *lit)
{
	size_t n = strlen(lit);
	return (size_t)(end - p) >= n && memcmp(p, lit, n) == 0;
}

/* Advance to the next '<' that opens an element (skipping comments, PIs, DOCTYPE). */
static const char *
next_tag(const char *p, const char *end)
{
	while (p < end) {
		p = memchr(p, '<', (size_t)(end - p));
		if (p == NULL) return end;
		if (starts(p, end, "<!--")) {
			const char *q = p + 4;
			while (q + 3 <= end && memcmp(q, "-->", 3) != 0) q++;
			p = q + 3;
		} else if (starts(p, end, "<?") || starts(p, end, "<!")) {
			const char *q = memchr(p, '>', (size_t)(end - p));
			p = q ? q + 1 : end;
		} else {
			return p;
		}
	}
	return end;
}

static size_t
tag_name(const char *p, const char *end, const char **name)
{
	const char *q = p + 1;
	if (q < end && *q == '/') q++;
	*name = q;
	while (q < end && *q != '>' && *q != ' ' && *q != '/' && *q != '\t' && *q != '\n') q++;
	return (size_t)(q - *name);
}

static bool
is_element(const char *p, const char *end, const char *name)
{
	const char *n;
	size_t len = tag_name(p, end, &n);
	return len == strlen(name) && memcmp(n, name, len) == 0;
}

/* p at '<' of an element: return the position just past the whole element. */
static const char *
skip_element(const char *p, const char *end)
{
	const char *gt = memchr(p, '>', (size_t)(end - p));
	if (gt == NULL) return end;
	if (gt > p && gt[-1] == '/') return gt + 1;   /* <true/> */
	int depth = 1;
	const char *q = gt + 1;
	while (depth > 0) {
		q = next_tag(q, end);
		if (q >= end) return end;
		const char *t = memchr(q, '>', (size_t)(end - q));
		if (t == NULL) return end;
		if (q[1] == '/') depth--;
		else if (t[-1] != '/') depth++;
		q = t + 1;
	}
	return q;
}

/* Text of <x>text</x> at p as [*s, *e). */
static bool
xml_text(const char *p, const char *end, const char **s, const char **e)
{
	const char *gt = memchr(p, '>', (size_t)(end - p));
	if (gt == NULL || gt[-1] == '/') return false;
	const char *lt = memchr(gt + 1, '<', (size_t)(end - gt - 1));
	if (lt == NULL) return false;
	*s = gt + 1;
	*e = lt;
	return true;
}

static const char *
xml_dict_get(const char *p, const char *end, const char *key)
{
	const char *name, *ks, *ke;
	size_t keylen = strlen(key);
	const char *gt = memchr(p, '>', (size_t)(end - p));
	if (gt == NULL || gt[-1] == '/') return NULL;   /* <dict/> */
	const char *q = gt + 1;
	for (;;) {
		q = next_tag(q, end);
		if (q >= end || q[1] == '/') return NULL;   /* </dict> */
		size_t n = tag_name(q, end, &name);
		if (n != 3 || memcmp(name, "key", 3) != 0) {
			q = skip_element(q, end);
			continue;
		}
		bool have = xml_text(q, end, &ks, &ke);
		q = skip_element(q, end);
		const char *value = next_tag(q, end);
		if (value >= end) return NULL;
		if (have && (size_t)(ke - ks) == keylen && memcmp(ks, key, keylen) == 0) {
			return value;
		}
		q = skip_element(value, end);
	}
}

#pragma mark Binary (bplist00)

static uint64_t
be(const uint8_t *p, unsigned n)
{
	uint64_t v = 0;
	while (n--) v = (v << 8) | *p++;
	return v;
}

/* Start of object `i`, or NULL. */
static const uint8_t *
bp_object(const struct doc *d, uint64_t i)
{
	if (i >= d->nobjects) return NULL;
	const uint8_t *entry = d->base + d->offset_table + i * d->offset_size;
	if (entry + d->offset_size > d->end) return NULL;
	uint64_t off = be(entry, d->offset_size);
	return off < (uint64_t)(d->end - d->base) ? d->base + off : NULL;
}

/* Count field of a marker byte (low nibble, or a following int when 0xF). */
static bool
bp_count(const struct doc *d, const uint8_t *o, uint64_t *count, const uint8_t **after)
{
	uint8_t low = o[0] & 0x0f;
	if (low != 0x0f) {
		*count = low;
		*after = o + 1;
		return true;
	}
	if (o + 2 > d->end || (o[1] & 0xf0) != 0x10) return false;
	unsigned n = 1u << (o[1] & 0x0f);
	if (n > 8 || o + 2 + n > d->end) return false;
	*count = be(o + 2, n);
	*after = o + 2 + n;
	return true;
}

/* Does object `i` equal the ASCII string `s`? (ASCII or UTF-16 strings) */
static bool
bp_string_is(const struct doc *d, uint64_t i, const char *s, size_t len)
{
	const uint8_t *o = bp_object(d, i), *chars;
	uint64_t n;
	if (o == NULL || !bp_count(d, o, &n, &chars) || n != len) return false;
	if ((o[0] & 0xf0) == 0x50) {   /* ASCII */
		return chars + n <= d->end && memcmp(chars, s, len) == 0;
	}
	if ((o[0] & 0xf0) == 0x60) {   /* UTF-16BE */
		if (chars + 2 * n > d->end) return false;
		for (uint64_t k = 0; k < n; k++) {
			if (chars[2 * k] != 0 || chars[2 * k + 1] != (uint8_t)s[k]) return false;
		}
		return true;
	}
	return false;
}

static uint64_t
bp_dict_get(const struct doc *d, uint64_t i, const char *key)
{
	const uint8_t *o = bp_object(d, i), *refs;
	uint64_t n;
	size_t keylen = strlen(key);
	if (o == NULL || (o[0] & 0xf0) != 0xd0 || !bp_count(d, o, &n, &refs)) return UINT64_MAX;
	if (refs + 2 * n * d->ref_size > d->end) return UINT64_MAX;
	for (uint64_t k = 0; k < n; k++) {
		if (bp_string_is(d, be(refs + k * d->ref_size, d->ref_size), key, keylen)) {
			return be(refs + (n + k) * d->ref_size, d->ref_size);
		}
	}
	return UINT64_MAX;
}

#pragma mark Common

static bool
doc_open(struct doc *d, const uint8_t *base, size_t size)
{
	d->base = base;
	d->end = base + size;
	d->binary = size >= 40 && memcmp(base, "bplist00", 8) == 0;
	if (d->binary) {
		const uint8_t *t = d->end - 32;
		d->offset_size = t[6];
		d->ref_size = t[7];
		d->nobjects = be(t + 8, 8);
		d->top = be(t + 16, 8);
		d->offset_table = be(t + 24, 8);
		if (d->offset_size < 1 || d->offset_size > 8 || d->ref_size < 1 || d->ref_size > 8 ||
		    d->offset_table >= size || d->nobjects > size) {
			return false;
		}
	}
	return true;
}

static bool
is_dict(const struct doc *d, struct node n)
{
	if (d->binary) {
		const uint8_t *o = bp_object(d, n.obj);
		return o != NULL && (o[0] & 0xf0) == 0xd0;
	}
	return n.xml != NULL && is_element(n.xml, (const char *)d->end, "dict");
}

static struct node
root(const struct doc *d)
{
	struct node n = NONE;
	if (d->binary) {
		n.obj = d->top;
	} else {
		const char *end = (const char *)d->end;
		for (const char *p = next_tag((const char *)d->base, end); p < end; p = next_tag(p + 1, end)) {
			if (is_element(p, end, "dict")) { n.xml = p; break; }
		}
	}
	return is_dict(d, n) ? n : NONE;
}

static struct node
get(const struct doc *d, struct node dict, const char *key)
{
	struct node n = NONE;
	if (!present(dict)) return n;
	if (d->binary) n.obj = bp_dict_get(d, dict.obj, key);
	else n.xml = xml_dict_get(dict.xml, (const char *)d->end, key);
	return n;
}

/* -1 not a boolean, else 0/1. */
static int
boolean(const struct doc *d, struct node n)
{
	if (!present(n)) return -1;
	if (d->binary) {
		const uint8_t *o = bp_object(d, n.obj);
		return o == NULL ? -1 : o[0] == 0x09 ? 1 : o[0] == 0x08 ? 0 : -1;
	}
	const char *end = (const char *)d->end;
	return is_element(n.xml, end, "true") ? 1 : is_element(n.xml, end, "false") ? 0 : -1;
}

/* Copy a string value into buf (ASCII only); false if not a string or too long. */
static bool
string(const struct doc *d, struct node n, char *buf, size_t size)
{
	if (!present(n)) return false;
	if (d->binary) {
		const uint8_t *o = bp_object(d, n.obj), *chars;
		uint64_t len;
		if (o == NULL || (o[0] & 0xf0) != 0x50 || !bp_count(d, o, &len, &chars) ||
		    len >= size || chars + len > d->end) {
			return false;
		}
		memcpy(buf, chars, (size_t)len);
		buf[len] = '\0';
		return true;
	}
	const char *s, *e, *end = (const char *)d->end;
	if (!is_element(n.xml, end, "string") || !xml_text(n.xml, end, &s, &e) || (size_t)(e - s) >= size) {
		return false;
	}
	memcpy(buf, s, (size_t)(e - s));
	buf[e - s] = '\0';
	return true;
}

#pragma mark - Files

#define DISCLOSURES "/System/Library/FeatureFlags/GlobalDisclosures.plist"

struct mapped { const uint8_t *base; size_t size; };

static bool
map_file(const char *path, struct mapped *m)
{
	struct stat st;
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	bool ok = false;

	if (fd < 0) return false;
	if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size < (64 << 20)) {
		void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
		if (p != MAP_FAILED) {
			m->base = p;
			m->size = (size_t)st.st_size;
			ok = true;
		}
	}
	close(fd);
	return ok;
}

static void
unmap_file(struct mapped *m)
{
	munmap((void *)m->base, m->size);
}

/* Has the disclosure `uuid` been made (GlobalDisclosures.plist: {uuid: {Disclosed: true}})? */
static bool
disclosed(const char *uuid)
{
	struct mapped m;
	struct doc d;
	bool yes = false;

	if (!map_file(DISCLOSURES, &m)) return false;
	if (doc_open(&d, m.base, m.size)) {
		yes = boolean(&d, get(&d, get(&d, root(&d), uuid), "Disclosed")) == 1;
	}
	unmap_file(&m);
	return yes;
}

/* -1: no decision; 0/1: disabled/enabled. */
static int
evaluate(const struct doc *d, struct node entry)
{
	char buf[128];
	int b;

	if (!is_dict(d, entry)) return -1;
	if ((b = boolean(d, get(d, entry, "Enabled"))) >= 0) return b;
	if (string(d, get(d, entry, "DevelopmentPhase"), buf, sizeof(buf))) {
		if (strcmp(buf, "FeatureComplete") != 0) return 0;
		struct node req = get(d, entry, "DisclosureRequired");
		if (!present(req)) return 1;
		if ((b = boolean(d, req)) >= 0) return !b;
		return string(d, req, buf, sizeof(buf)) && disclosed(buf);
	}
	return -1;
}

/* Look `feature` up in one plist; a non-NULL `domain` means {domain: {feature: ...}}. */
static int
lookup_file(const char *path, const char *domain, const char *feature)
{
	struct mapped m;
	struct doc d;
	int result = -1;

	if (!map_file(path, &m)) return -1;
	if (doc_open(&d, m.base, m.size)) {
		struct node dict = root(&d);
		if (domain != NULL) {
			dict = get(&d, dict, domain);
			if (!is_dict(&d, dict)) dict = NONE;
		}
		struct node entry = get(&d, dict, feature);
		if (present(entry)) result = evaluate(&d, entry);
	}
	unmap_file(&m);
	return result;
}

static bool
safe_name(const char *s)
{
	if (s == NULL || *s == '\0' || strlen(s) > 200) return false;
	for (; *s; s++) {
		if (*s == '/' || (*s == '.' && s[1] == '.')) return false;
	}
	return true;
}

static void
domain_path(char *buf, const char *dir, const char *domain)
{
	strlcpy(buf, dir, FF_PATH_MAX);
	strlcat(buf, domain, FF_PATH_MAX);
	strlcat(buf, ".plist", FF_PATH_MAX);
}

static int
lookup(const char *domain, const char *feature)
{
	char path[FF_PATH_MAX];
	int r;

	if (!safe_name(domain) || !safe_name(feature)) return -1;
	domain_path(path, "/Library/Preferences/FeatureFlags/Domain/", domain);
	if ((r = lookup_file(path, NULL, feature)) >= 0) return r;
	if ((r = lookup_file("/System/Library/FeatureFlags/Global.plist", domain, feature)) >= 0) return r;
	domain_path(path, "/System/Library/FeatureFlags/Domain/", domain);
	if ((r = lookup_file(path, NULL, feature)) >= 0) return r;
	domain_path(path, "/System/Library/FeatureFlags/Unified/Domain/", domain);
	return lookup_file(path, NULL, feature);
}

bool
_os_feature_enabled_impl(const char *domain, const char *feature)
{
	return lookup(domain, feature) == 1;
}

/* Apple's answers "disabled" for unknown features whatever `fallback` says. */
bool
_os_feature_enabled_simple_impl(const char *domain, const char *feature, bool fallback)
{
	(void)fallback;
	return lookup(domain, feature) == 1;
}
