/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The compiled asset catalog container. A .car file is a BOM store (the
 * "Bill of Materials" format of installer receipts): a big-endian header,
 * an index of blocks (offset, length) and named variables pointing at
 * blocks. Some variables are B+ trees ("tree" blocks over pages of
 * value/key block pairs, leaves chained left to right). The catalog's:
 *
 *   CARHEADER       "RATC": CoreUI and storage versions, rendition count,
 *                   version strings, schema, colour space (little-endian)
 *   KEYFORMAT       "tmfk": the rendition key's attributes, in key order
 *   RENDITIONS      tree: key = one u16 per KEYFORMAT attribute, value = a
 *                   CSI rendition (CUIRendition.c)
 *   FACETKEYS       tree: key = a name, value = its key token (hot spot,
 *                   count, then attribute/value u16 pairs)
 *   APPEARANCEKEYS  tree: key = an appearance name, value = its u16 id
 *   BITMAPKEYS, EXTENDED_METADATA, ...  not needed to look things up
 *
 * docs/design/ASSETS.md has the details.
 */
#include "CUIPrivate.h"
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

typedef struct {
	const uint8_t *d;
	size_t size;
	uint32_t index_off, nblocks;
	uint32_t vars_off, vars_len;
} bom;

static bool
bom_block(const bom *b, uint32_t i, const uint8_t **p, uint32_t *len)
{
	if (i >= b->nblocks)
		return false;
	const uint8_t *e = b->d + b->index_off + 4 + 8 * (size_t)i;
	uint32_t a = be32(e), l = be32(e + 4);
	if ((size_t)a > b->size || (size_t)l > b->size - a)
		return false;
	*p = b->d + a, *len = l;
	return true;
}

static bool
bom_var(const bom *b, const char *name, const uint8_t **p, uint32_t *len)
{
	const uint8_t *v = b->d + b->vars_off, *end = v + b->vars_len;
	if (b->vars_len < 4)
		return false;
	uint32_t n = be32(v);
	v += 4;
	size_t nl = strlen(name);
	for (uint32_t i = 0; i < n && v + 5 <= end; i++) {
		uint32_t block = be32(v);
		uint8_t l = v[4];
		if (v + 5 + l > end)
			break;
		if (l == nl && memcmp(v + 5, name, nl) == 0)
			return bom_block(b, block, p, len);
		v += 5 + l;
	}
	return false;
}

typedef void (*tree_fn)(void *ctx, const uint8_t *key, uint32_t klen, uint32_t inline_key, const uint8_t *val, uint32_t vlen);

/* Walk a BOM tree's leaves in order; keys are blocks unless inline (then the u32 is passed). */
static bool
bom_tree(const bom *b, const char *name, bool inline_keys, tree_fn fn, void *ctx)
{
	const uint8_t *t;
	uint32_t tl;
	if (!bom_var(b, name, &t, &tl) || tl < 21 || memcmp(t, "tree", 4) != 0)
		return false;
	const uint8_t *p;
	uint32_t pl;
	if (!bom_block(b, be32(t + 8), &p, &pl) || pl < 12)
		return false;
	for (int depth = 0; !be16(p); depth++) {  /* down the leftmost branch */
		if (depth > 64 || be16(p + 2) == 0 || pl < 20 || !bom_block(b, be32(p + 12), &p, &pl) || pl < 12)
			return false;
	}
	for (int pages = 0; pages < 1 << 20; pages++) {
		uint16_t n = be16(p + 2);
		if (12 + 8 * (size_t)n > pl)
			return false;
		for (uint16_t i = 0; i < n; i++) {
			const uint8_t *e = p + 12 + 8 * (size_t)i, *val, *key = NULL;
			uint32_t vl, kl = 0;
			if (!bom_block(b, be32(e), &val, &vl))
				continue;
			if (!inline_keys && !bom_block(b, be32(e + 4), &key, &kl))
				continue;
			fn(ctx, key, kl, be32(e + 4), val, vl);
		}
		uint32_t next = be32(p + 4);
		if (!next || !bom_block(b, next, &p, &pl) || pl < 12)
			break;
	}
	return true;
}

/* MARK: - Catalog trees */

typedef struct {
	cui_store *s;
	size_t cap;
} grow_ctx;

static void
rendition_fn(void *ctx, const uint8_t *key, uint32_t klen, uint32_t ik, const uint8_t *val, uint32_t vlen)
{
	grow_ctx *g = ctx;
	cui_store *s = g->s;
	if (klen < 2 * s->nattrs)
		return;
	if (s->nrends == g->cap) {
		g->cap = g->cap ? 2 * g->cap : 256;
		cui_rendition *r = realloc(s->rends, g->cap * sizeof *r);
		if (!r)
			return;
		s->rends = r;
	}
	cui_rendition *r = &s->rends[s->nrends++];
	memset(r, 0, sizeof *r);
	for (uint32_t i = 0; i < s->nattrs; i++)
		if (s->attrs[i] < CUI_ATTR_MAX)
			r->key.v[s->attrs[i]] = le16(key + 2 * i);
	r->csi = val, r->len = vlen, r->index = (uint32_t)(s->nrends - 1);
}

static void
facet_fn(void *ctx, const uint8_t *key, uint32_t klen, uint32_t ik, const uint8_t *val, uint32_t vlen)
{
	grow_ctx *g = ctx;
	cui_store *s = g->s;
	if (vlen < 6)
		return;
	if (s->nfacets == g->cap) {
		g->cap = g->cap ? 2 * g->cap : 64;
		cui_facet *f = realloc(s->facets, g->cap * sizeof *f);
		if (!f)
			return;
		s->facets = f;
	}
	cui_facet *f = &s->facets[s->nfacets];
	memset(f, 0, sizeof *f);
	f->name = strndup((const char *)key, klen);
	if (!f->name)
		return;
	uint16_t n = le16(val + 4);
	for (uint16_t i = 0; i < n && 6 + 4 * (size_t)i + 4 <= vlen; i++) {
		uint16_t a = le16(val + 6 + 4 * i), v = le16(val + 8 + 4 * i);
		if (a < CUI_ATTR_MAX)
			f->attrs.v[a] = v, f->mask |= 1u << a;
	}
	s->nfacets++;
}

static void
appearance_fn(void *ctx, const uint8_t *key, uint32_t klen, uint32_t ik, const uint8_t *val, uint32_t vlen)
{
	grow_ctx *g = ctx;
	cui_store *s = g->s;
	if (vlen < 2)
		return;
	if (s->napps == g->cap) {
		g->cap = g->cap ? 2 * g->cap : 8;
		cui_appearance *a = realloc(s->apps, g->cap * sizeof *a);
		if (!a)
			return;
		s->apps = a;
	}
	cui_appearance *a = &s->apps[s->napps];
	a->name = strndup((const char *)key, klen);
	a->id = le16(val);
	if (a->name)
		s->napps++;
}

static int
rend_cmp(const void *a, const void *b)
{
	const cui_rendition *x = a, *y = b;
	if (x->key.v[CUI_ATTR_IDENTIFIER] != y->key.v[CUI_ATTR_IDENTIFIER])
		return x->key.v[CUI_ATTR_IDENTIFIER] < y->key.v[CUI_ATTR_IDENTIFIER] ? -1 : 1;
	return x->index < y->index ? -1 : x->index > y->index;
}

static int
facet_cmp(const void *a, const void *b)
{
	return strcmp(((const cui_facet *)a)->name, ((const cui_facet *)b)->name);
}

static bool
load(cui_store *s)
{
	bom b = {.d = s->data, .size = s->size};
	if (s->size < 32 || memcmp(s->data, "BOMStore", 8) != 0)
		return false;
	b.index_off = be32(s->data + 16);
	uint32_t index_len = be32(s->data + 20);
	b.vars_off = be32(s->data + 24), b.vars_len = be32(s->data + 28);
	if ((size_t)b.index_off + 4 > s->size || (size_t)index_len > s->size - b.index_off ||
	    (size_t)b.vars_off > s->size || (size_t)b.vars_len > s->size - b.vars_off)
		return false;
	b.nblocks = be32(s->data + b.index_off);
	if ((size_t)b.nblocks * 8 + 4 > index_len)
		b.nblocks = (index_len - 4) / 8;

	const uint8_t *p;
	uint32_t l;
	if (!bom_var(&b, "CARHEADER", &p, &l) || l < 436 || memcmp(p, "RATC", 4) != 0)
		return false;
	s->coreui_version = le32(p + 4), s->storage_version = le32(p + 8), s->timestamp = le32(p + 12);
	s->rendition_count = le32(p + 16);
	memcpy(s->main_version, p + 20, 128);
	memcpy(s->version_string, p + 148, 256);
	s->schema = le32(p + 424), s->colorspace = le32(p + 428), s->key_semantics = le32(p + 432);

	if (bom_var(&b, "KEYFORMAT", &p, &l) && l >= 12 && memcmp(p, "tmfk", 4) == 0) {
		uint32_t n = le32(p + 8);
		if (n > CUI_ATTR_MAX || 12 + 4 * (size_t)n > l)
			return false;
		s->nattrs = n;
		for (uint32_t i = 0; i < n; i++)
			s->attrs[i] = le32(p + 12 + 4 * i);
	} else
		return false;  /* every catalog actool has written since 10.9 has one */

	grow_ctx g = {s, 0};
	if (!bom_tree(&b, "RENDITIONS", false, rendition_fn, &g))
		return false;
	g.cap = 0;
	bom_tree(&b, "FACETKEYS", false, facet_fn, &g);
	g.cap = 0;
	bom_tree(&b, "APPEARANCEKEYS", false, appearance_fn, &g);
	if (s->nrends)
		qsort(s->rends, s->nrends, sizeof *s->rends, rend_cmp);
	if (s->nfacets)
		qsort(s->facets, s->nfacets, sizeof *s->facets, facet_cmp);
	return true;
}

cui_store *
cui_store_open(const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return NULL;
	struct stat st;
	cui_store *s = NULL;
	if (fstat(fd, &st) == 0 && st.st_size >= 32) {
		void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
		if (m != MAP_FAILED && (s = calloc(1, sizeof *s))) {
			s->map = m, s->size = (size_t)st.st_size, s->mapped = true, s->data = m;
			if (!load(s)) {
				cui_store_free(s);
				s = NULL;
			}
		} else if (m != MAP_FAILED)
			munmap(m, (size_t)st.st_size);
	}
	close(fd);
	return s;
}

cui_store *
cui_store_open_bytes(const void *bytes, size_t len)
{
	cui_store *s = calloc(1, sizeof *s);
	void *copy = malloc(len ? len : 1);
	if (!s || !copy) {
		free(s);
		free(copy);
		return NULL;
	}
	memcpy(copy, bytes, len);
	s->map = copy, s->size = len, s->data = copy;
	if (!load(s)) {
		cui_store_free(s);
		return NULL;
	}
	return s;
}

void
cui_store_free(cui_store *s)
{
	if (!s)
		return;
	for (size_t i = 0; i < s->nfacets; i++)
		free(s->facets[i].name);
	for (size_t i = 0; i < s->napps; i++)
		free(s->apps[i].name);
	free(s->facets);
	free(s->apps);
	free(s->rends);
	if (s->mapped)
		munmap(s->map, s->size);
	else
		free(s->map);
	free(s);
}

const cui_facet *
cui_store_facet(const cui_store *s, const char *name)
{
	cui_facet k = {.name = (char *)name};
	return s->nfacets ? bsearch(&k, s->facets, s->nfacets, sizeof k, facet_cmp) : NULL;
}

bool
cui_store_appearance(const cui_store *s, const char *name, uint16_t *id)
{
	for (size_t i = 0; name && i < s->napps; i++)
		if (strcmp(s->apps[i].name, name) == 0) {
			*id = s->apps[i].id;
			return true;
		}
	return false;
}

const char *
cui_store_appearance_name(const cui_store *s, uint16_t id)
{
	for (size_t i = 0; i < s->napps; i++)
		if (s->apps[i].id == id)
			return s->apps[i].name;
	return id == 0 ? "NSAppearanceNameSystem" : NULL;
}

size_t
cui_store_renditions_for_identifier(const cui_store *s, uint16_t ident, size_t *first)
{
	size_t lo = 0, hi = s->nrends;
	while (lo < hi) {
		size_t mid = (lo + hi) / 2;
		if (s->rends[mid].key.v[CUI_ATTR_IDENTIFIER] < ident)
			lo = mid + 1;
		else
			hi = mid;
	}
	size_t end = lo;
	while (end < s->nrends && s->rends[end].key.v[CUI_ATTR_IDENTIFIER] == ident)
		end++;
	*first = lo;
	return end - lo;
}

const cui_rendition *
cui_store_rendition_with_key(const cui_store *s, const cui_key *key)
{
	size_t first, n = cui_store_renditions_for_identifier(s, key->v[CUI_ATTR_IDENTIFIER], &first);
	for (size_t i = first; i < first + n; i++) {
		bool same = true;
		for (uint32_t a = 0; a < s->nattrs && same; a++)
			if (s->attrs[a] < CUI_ATTR_MAX)
				same = s->rends[i].key.v[s->attrs[a]] == key->v[s->attrs[a]];
		if (same)
			return &s->rends[i];
	}
	return NULL;
}
