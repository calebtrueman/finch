/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libcache: Finch's implementation of the <cache.h> caching API, written
 * from the SDK's documentation. Apple doesn't publish libcache.
 *
 * A cache maps keys to values. Values are reference counted by their users
 * (cache_get_and_retain / cache_release_value). A value nobody holds may be
 * made purgeable, and may be evicted when the cache is over its count or
 * cost hint or the system is under memory pressure.
 *
 * Private interfaces (cache_get, cache_retain/release, the hints,
 * cache_invoke, cache_remove_with_block, cache_get_info*, cache_print*,
 * cache_simulate_memory_warning_event) have the shapes macOS 26.4's
 * libcache gives them.
 */

#include <cache.h>
#include <cache_callbacks.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <malloc/malloc.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

uint64_t os_simple_hash(const void *buf, size_t len);
uint64_t os_simple_hash_string(const char *str);

/* A value and everyone holding it: users (refs) and keys (keys). */
struct value_rec {
	void *value;
	struct value_rec *next;          /* value hash chain */
	cache_cost_t cost;
	uint32_t refs;
	uint32_t keys;
	bool purgeable;                  /* made purgeable while unreferenced */
	uint64_t last_use;
};

struct entry {
	void *key;
	struct value_rec *vr;
	struct entry *next;              /* key hash chain */
	uint32_t accesses;
};

/* Per-key information returned by cache_get_info_for_key(s). */
typedef struct {
	uint8_t has_value;               /* key present with a live (unpurged) value */
	uint8_t state;                   /* recency: accesses, saturating */
} cache_key_info_t;

/* cache_get_info(). */
typedef struct {
	uint32_t version;                /* 1 */
	uint32_t keys;
	uint32_t values;
	uint32_t lookups;
	uint32_t hits;
	uint32_t reserved;
	uint64_t cost;
} cache_info_t;

struct cache_s {
	_Atomic int32_t refcount;
	os_unfair_lock lock;
	char *name;
	cache_attributes_t attrs;
	struct entry **keys;
	struct value_rec **values;
	size_t nbuckets;
	uint32_t nkeys, nvalues;
	uint64_t total_cost;
	size_t cost_hint;
	uint32_t count_hint;
	uint32_t min_values_hint;
	uint32_t lookups, hits;
	uint64_t clock;
	bool destroyed;                  /* cache_destroy'd with values still held */
	struct cache_s *next_cache;      /* global list, for memory pressure */
};

/* All caches, for memory-pressure purges. */
static os_unfair_lock g_caches_lock = OS_UNFAIR_LOCK_INIT;
static struct cache_s *g_caches;
static dispatch_source_t g_pressure;

/* ---- callbacks (cache_callbacks.h) ---- */

EXPORT uintptr_t cache_hash_byte_string(const char *data, size_t bytes)
{
	return (uintptr_t)os_simple_hash(data, bytes);
}

EXPORT uintptr_t cache_key_hash_cb_cstring(void *key, void *unused)
{
	(void)unused;
	return (uintptr_t)os_simple_hash_string(key);
}

EXPORT uintptr_t cache_key_hash_cb_integer(void *key, void *unused)
{
	(void)unused;
	uintptr_t k = (uintptr_t)key;
	return (uintptr_t)os_simple_hash(&k, sizeof(k));
}

EXPORT bool cache_key_is_equal_cb_cstring(void *key1, void *key2, void *unused)
{
	(void)unused;
	return strcmp(key1, key2) == 0;
}

EXPORT bool cache_key_is_equal_cb_integer(void *key1, void *key2, void *unused)
{
	(void)unused;
	return key1 == key2;
}

EXPORT void cache_release_cb_free(void *key_or_value, void *unused)
{
	(void)unused;
	free(key_or_value);
}

EXPORT void cache_value_make_purgeable_cb(void *value, void *unused)
{
	(void)unused;
	malloc_make_purgeable(value);
}

EXPORT bool cache_value_make_nonpurgeable_cb(void *value, void *unused)
{
	(void)unused;
	return malloc_make_nonpurgeable(value) == 0;
}

/* ---- internals (cache->lock held) ---- */

static uintptr_t key_hash(cache_t *c, void *key)
{
	if (c->attrs.key_hash_cb)
		return c->attrs.key_hash_cb(key, c->attrs.user_data);
	uintptr_t k = (uintptr_t)key;
	return (uintptr_t)os_simple_hash(&k, sizeof(k));
}

static bool key_equal(cache_t *c, void *a, void *b)
{
	if (c->attrs.key_is_equal_cb)
		return c->attrs.key_is_equal_cb(a, b, c->attrs.user_data);
	return a == b;
}

static size_t value_bucket(cache_t *c, void *value)
{
	uintptr_t v = (uintptr_t)value;
	return (size_t)(os_simple_hash(&v, sizeof(v)) % c->nbuckets);
}

static struct entry **find_entry(cache_t *c, void *key)
{
	struct entry **e = &c->keys[key_hash(c, key) % c->nbuckets];
	while (*e && !key_equal(c, (*e)->key, key))
		e = &(*e)->next;
	return e;
}

static struct value_rec *find_value(cache_t *c, void *value)
{
	struct value_rec *v = c->values[value_bucket(c, value)];
	while (v && v->value != value)
		v = v->next;
	return v;
}

/* The value has no users and no keys: forget it and release it. Releases
 * are collected and run after the lock is dropped. */
struct pending {
	void *items[64];
	bool is_key[64];
	int n;
};

static void flush_pending(cache_t *c, struct pending *p)
{
	for (int i = 0; i < p->n; i++) {
		cache_release_cb_t cb = p->is_key[i] ? c->attrs.key_release_cb : c->attrs.value_release_cb;
		if (cb)
			cb(p->items[i], c->attrs.user_data);
	}
	p->n = 0;
}

static void pend(cache_t *c, struct pending *p, void *item, bool is_key)
{
	if (p->n == 64) {
		/* Rare: release in place (callbacks must not call back into the cache). */
		cache_release_cb_t cb = is_key ? c->attrs.key_release_cb : c->attrs.value_release_cb;
		if (cb)
			cb(item, c->attrs.user_data);
		return;
	}
	p->items[p->n] = item;
	p->is_key[p->n] = is_key;
	p->n++;
}

static void drop_value_if_unused(cache_t *c, struct value_rec *vr, struct pending *p)
{
	if (vr->refs || vr->keys)
		return;
	struct value_rec **v = &c->values[value_bucket(c, vr->value)];
	while (*v != vr)
		v = &(*v)->next;
	*v = vr->next;
	c->nvalues--;
	c->total_cost -= vr->cost;
	pend(c, p, vr->value, false);
	free(vr);
}

static void unlink_entry(cache_t *c, struct entry **ep, struct pending *p)
{
	struct entry *e = *ep;
	*ep = e->next;
	c->nkeys--;
	pend(c, p, e->key, true);
	struct value_rec *vr = e->vr;
	free(e);
	vr->keys--;
	drop_value_if_unused(c, vr, p);
}

/* Remove every key of an unreferenced value (evicting it). */
static void evict_value(cache_t *c, struct value_rec *vr, struct pending *p)
{
	for (size_t b = 0; b < c->nbuckets && vr->keys; b++) {
		struct entry **e = &c->keys[b];
		while (*e) {
			if ((*e)->vr == vr) {
				vr->refs++;              /* keep vr alive while unlinking its keys */
				unlink_entry(c, e, p);
				vr->refs--;
			} else {
				e = &(*e)->next;
			}
		}
	}
	drop_value_if_unused(c, vr, p);
}

/* Evict least recently used unreferenced values while over the limits (or,
 * with `all`, every unreferenced value), keeping min_values_hint values. */
static void enforce_limits(cache_t *c, bool all, struct pending *p)
{
	for (;;) {
		bool over = all || (c->count_hint && c->nvalues > c->count_hint) ||
		            (c->cost_hint && c->total_cost > c->cost_hint);
		if (!over || c->nvalues <= c->min_values_hint)
			return;
		struct value_rec *oldest = NULL;
		for (size_t b = 0; b < c->nbuckets; b++)
			for (struct value_rec *v = c->values[b]; v; v = v->next)
				if (v->refs == 0 && (!oldest || v->last_use < oldest->last_use))
					oldest = v;
		if (!oldest)
			return;
		evict_value(c, oldest, p);
	}
}

static bool grow(cache_t *c)
{
	if (c->nkeys < c->nbuckets * 2)
		return true;
	size_t n = c->nbuckets * 4;
	struct entry **keys = calloc(n, sizeof(*keys));
	struct value_rec **values = calloc(n, sizeof(*values));
	if (!keys || !values) {
		free(keys);
		free(values);
		return false;
	}
	size_t old = c->nbuckets;
	c->nbuckets = n;
	for (size_t b = 0; b < old; b++) {
		for (struct entry *e = c->keys[b], *next; e; e = next) {
			next = e->next;
			struct entry **slot = &keys[key_hash(c, e->key) % n];
			e->next = *slot;
			*slot = e;
		}
		for (struct value_rec *v = c->values[b], *next; v; v = next) {
			next = v->next;
			uintptr_t pv = (uintptr_t)v->value;
			struct value_rec **slot = &values[os_simple_hash(&pv, sizeof(pv)) % n];
			v->next = *slot;
			*slot = v;
		}
	}
	free(c->keys);
	free(c->values);
	c->keys = keys;
	c->values = values;
	return true;
}

/* Look up a live value for key. A purgeable value is made nonpurgeable
 * first; if it was purged meanwhile, the key is removed. */
static struct entry **lookup(cache_t *c, void *key, struct pending *p)
{
	c->lookups++;
	struct entry **e = find_entry(c, key);
	if (!*e)
		return NULL;
	struct value_rec *vr = (*e)->vr;
	if (vr->purgeable) {
		if (c->attrs.value_make_nonpurgeable_cb &&
		    !c->attrs.value_make_nonpurgeable_cb(vr->value, c->attrs.user_data)) {
			unlink_entry(c, e, p);
			return NULL;
		}
		vr->purgeable = false;
	}
	c->hits++;
	(*e)->accesses++;
	vr->last_use = ++c->clock;
	return e;
}

static void purge(cache_t *c)
{
	struct pending p = { .n = 0 };
	os_unfair_lock_lock(&c->lock);
	enforce_limits(c, true, &p);
	os_unfair_lock_unlock(&c->lock);
	flush_pending(c, &p);
}

static void handle_memory_pressure(uintptr_t level)
{
	(void)level;
	os_unfair_lock_lock(&g_caches_lock);
	for (cache_t *c = g_caches; c; c = c->next_cache)
		purge(c);
	os_unfair_lock_unlock(&g_caches_lock);
}

static void register_pressure_handler(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		g_pressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
		    DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
		    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
		if (!g_pressure)
			return;
		dispatch_source_set_event_handler(g_pressure, ^{
			handle_memory_pressure(dispatch_source_get_data(g_pressure));
		});
		dispatch_activate(g_pressure);
	});
}

/* ---- public API ---- */

EXPORT int cache_create(const char *name, const cache_attributes_t *attrs, cache_t **cache_out)
{
	if (!name || !attrs || !cache_out)
		return EINVAL;
	if (attrs->version != CACHE_ATTRIBUTES_VERSION_1 && attrs->version != CACHE_ATTRIBUTES_VERSION_2)
		return EINVAL;
	cache_t *c = calloc(1, sizeof(*c));
	if (!c)
		return ENOMEM;
	c->nbuckets = 16;
	c->keys = calloc(c->nbuckets, sizeof(*c->keys));
	c->values = calloc(c->nbuckets, sizeof(*c->values));
	c->name = strdup(name);
	if (!c->keys || !c->values || !c->name) {
		free(c->keys);
		free(c->values);
		free(c->name);
		free(c);
		return ENOMEM;
	}
	c->attrs = *attrs;
	if (attrs->version < CACHE_ATTRIBUTES_VERSION_2)
		c->attrs.value_retain_cb = NULL;
	c->lock = OS_UNFAIR_LOCK_INIT;
	atomic_store(&c->refcount, 1);

	register_pressure_handler();
	os_unfair_lock_lock(&g_caches_lock);
	c->next_cache = g_caches;
	g_caches = c;
	os_unfair_lock_unlock(&g_caches_lock);
	*cache_out = c;
	return 0;
}

EXPORT void cache_retain(cache_t *c)
{
	atomic_fetch_add(&c->refcount, 1);
}

EXPORT void cache_release(cache_t *c)
{
	if (atomic_fetch_sub(&c->refcount, 1) > 1)
		return;
	os_unfair_lock_lock(&g_caches_lock);
	for (cache_t **p = &g_caches; *p; p = &(*p)->next_cache) {
		if (*p == c) {
			*p = c->next_cache;
			break;
		}
	}
	os_unfair_lock_unlock(&g_caches_lock);
	cache_remove_all(c);
	free(c->keys);
	free(c->values);
	free(c->name);
	free(c);
}

EXPORT int cache_set_and_retain(cache_t *c, void *key, void *value, cache_cost_t cost)
{
	if (!c || !key)
		return EINVAL;
	void *k = key;
	if (c->attrs.key_retain_cb) {
		k = NULL;
		c->attrs.key_retain_cb(key, &k, c->attrs.user_data);
		if (!k)
			return EINVAL;
	}
	struct pending p = { .n = 0 };
	os_unfair_lock_lock(&c->lock);
	if (!grow(c)) {
		os_unfair_lock_unlock(&c->lock);
		return ENOMEM;
	}
	struct value_rec *vr = find_value(c, value);
	bool new_value = (vr == NULL);
	if (new_value) {
		vr = calloc(1, sizeof(*vr));
		if (!vr) {
			os_unfair_lock_unlock(&c->lock);
			return ENOMEM;
		}
		vr->value = value;
		vr->cost = cost;
		size_t b = value_bucket(c, value);
		vr->next = c->values[b];
		c->values[b] = vr;
		c->nvalues++;
		c->total_cost += cost;
	}
	vr->refs++;                      /* retained for the caller */
	vr->purgeable = false;
	vr->last_use = ++c->clock;

	struct entry **ep = find_entry(c, k);
	if (*ep)
		unlink_entry(c, ep, &p);     /* replaces the previous key and value */
	struct entry *e = calloc(1, sizeof(*e));
	if (!e) {
		vr->refs--;
		drop_value_if_unused(c, vr, &p);
		os_unfair_lock_unlock(&c->lock);
		flush_pending(c, &p);
		return ENOMEM;
	}
	e->key = k;
	e->vr = vr;
	size_t b = key_hash(c, k) % c->nbuckets;
	e->next = c->keys[b];
	c->keys[b] = e;
	c->nkeys++;
	vr->keys++;
	enforce_limits(c, false, &p);
	os_unfair_lock_unlock(&c->lock);
	if (new_value && c->attrs.value_retain_cb)
		c->attrs.value_retain_cb(value, c->attrs.user_data);
	flush_pending(c, &p);
	return 0;
}

EXPORT int cache_get_and_retain(cache_t *c, void *key, void **value_out)
{
	if (!c || !key || !value_out)
		return EINVAL;
	struct pending p = { .n = 0 };
	os_unfair_lock_lock(&c->lock);
	struct entry **e = lookup(c, key, &p);
	int ret = ENOENT;
	if (e) {
		(*e)->vr->refs++;
		*value_out = (*e)->vr->value;
		ret = 0;
	}
	os_unfair_lock_unlock(&c->lock);
	flush_pending(c, &p);
	return ret;
}

/* Like cache_get_and_retain, without retaining the value. */
EXPORT int cache_get(cache_t *c, void *key, void **value_out)
{
	if (!c || !key || !value_out)
		return EINVAL;
	struct pending p = { .n = 0 };
	os_unfair_lock_lock(&c->lock);
	struct entry **e = lookup(c, key, &p);
	int ret = ENOENT;
	if (e) {
		*value_out = (*e)->vr->value;
		ret = 0;
	}
	os_unfair_lock_unlock(&c->lock);
	flush_pending(c, &p);
	return ret;
}

EXPORT int cache_release_value(cache_t *c, void *value)
{
	if (!c)
		return EINVAL;
	struct pending p = { .n = 0 };
	bool make_purgeable = false;
	os_unfair_lock_lock(&c->lock);
	struct value_rec *vr = find_value(c, value);
	if (!vr || vr->refs == 0) {
		os_unfair_lock_unlock(&c->lock);
		return EINVAL;
	}
	if (--vr->refs == 0) {
		if (vr->keys == 0) {
			drop_value_if_unused(c, vr, &p);
		} else if (c->attrs.value_make_purgeable_cb) {
			vr->purgeable = true;
			make_purgeable = true;
		}
		enforce_limits(c, false, &p);
	}
	bool last = c->destroyed && c->nvalues == 0;
	os_unfair_lock_unlock(&c->lock);
	if (make_purgeable)
		c->attrs.value_make_purgeable_cb(value, c->attrs.user_data);
	flush_pending(c, &p);
	if (last)
		cache_release(c);        /* deferred from cache_destroy */
	return 0;
}

EXPORT int cache_remove(cache_t *c, void *key)
{
	if (!c || !key)
		return EINVAL;
	struct pending p = { .n = 0 };
	os_unfair_lock_lock(&c->lock);
	struct entry **e = find_entry(c, key);
	int ret = ENOENT;
	if (*e) {
		unlink_entry(c, e, &p);
		ret = 0;
	}
	os_unfair_lock_unlock(&c->lock);
	flush_pending(c, &p);
	return ret;
}

EXPORT int cache_remove_with_block(cache_t *c, bool (^block)(void *key, void *value))
{
	if (!c || !block)
		return EINVAL;
	struct pending p = { .n = 0 };
	cache_retain(c);
	os_unfair_lock_lock(&c->lock);
	for (size_t b = 0; b < c->nbuckets; b++) {
		struct entry **e = &c->keys[b];
		while (*e) {
			if (block((*e)->key, (*e)->vr->value)) {
				unlink_entry(c, e, &p);
				if (p.n > 48) {
					os_unfair_lock_unlock(&c->lock);
					flush_pending(c, &p);
					os_unfair_lock_lock(&c->lock);
					e = &c->keys[b];     /* restart this bucket */
				}
			} else {
				e = &(*e)->next;
			}
		}
	}
	os_unfair_lock_unlock(&c->lock);
	flush_pending(c, &p);
	cache_release(c);
	return 0;
}

EXPORT int cache_remove_all(cache_t *c)
{
	if (!c)
		return EINVAL;
	struct pending p = { .n = 0 };
	os_unfair_lock_lock(&c->lock);
	for (size_t b = 0; b < c->nbuckets; b++) {
		while (c->keys[b]) {
			unlink_entry(c, &c->keys[b], &p);
			if (p.n > 48) {
				os_unfair_lock_unlock(&c->lock);
				flush_pending(c, &p);
				os_unfair_lock_lock(&c->lock);
			}
		}
	}
	os_unfair_lock_unlock(&c->lock);
	flush_pending(c, &p);
	return 0;
}

/*
 * <cache.h> documents EAGAIN when values are still held, but macOS 26.4's
 * libcache returns 0 and frees the cache (a later cache_release_value then
 * crashes). Finch returns 0 too, and keeps the cache until the last held
 * value is released.
 */
EXPORT int cache_destroy(cache_t *c)
{
	if (!c)
		return EINVAL;
	cache_remove_all(c);
	os_unfair_lock_lock(&c->lock);
	bool held = c->nvalues != 0;     /* only values users still hold remain */
	c->destroyed = held;
	os_unfair_lock_unlock(&c->lock);
	if (!held)
		cache_release(c);
	return 0;
}

/* Calls fn(key, value, context) for every key with a live value. */
EXPORT int cache_invoke(cache_t *c, void (*fn)(void *key, void *value, void *context), void *context)
{
	if (!c || !fn)
		return EINVAL;
	os_unfair_lock_lock(&c->lock);
	for (size_t b = 0; b < c->nbuckets; b++)
		for (struct entry *e = c->keys[b]; e; e = e->next)
			if (!e->vr->purgeable)
				fn(e->key, e->vr->value, context);
	os_unfair_lock_unlock(&c->lock);
	return 0;
}

EXPORT size_t cache_get_cost_hint(cache_t *c) { return c->cost_hint; }
EXPORT uint32_t cache_get_count_hint(cache_t *c) { return c->count_hint; }
EXPORT uint32_t cache_get_minimum_values_hint(cache_t *c) { return c->min_values_hint; }
EXPORT const char *cache_get_name(cache_t *c) { return c->name; }
EXPORT void cache_set_minimum_values_hint(cache_t *c, uint32_t count) { c->min_values_hint = count; }

static void set_limit(cache_t *c, void (^set)(void))
{
	struct pending p = { .n = 0 };
	cache_retain(c);
	os_unfair_lock_lock(&c->lock);
	set();
	enforce_limits(c, false, &p);
	os_unfair_lock_unlock(&c->lock);
	flush_pending(c, &p);
	cache_release(c);
}

EXPORT void cache_set_cost_hint(cache_t *c, size_t cost)
{
	set_limit(c, ^{ c->cost_hint = cost; });
}

EXPORT void cache_set_count_hint(cache_t *c, uint32_t count)
{
	set_limit(c, ^{ c->count_hint = count; });
}

EXPORT void cache_set_name(cache_t *c, const char *name)
{
	char *copy = name ? strdup(name) : NULL;
	os_unfair_lock_lock(&c->lock);
	char *old = c->name;
	c->name = copy;
	os_unfair_lock_unlock(&c->lock);
	free(old);
}

EXPORT int cache_get_info(cache_t *c, cache_info_t *info)
{
	if (!c || !info)
		return EINVAL;
	os_unfair_lock_lock(&c->lock);
	info->version = 1;
	info->keys = c->nkeys;
	info->values = c->nvalues;
	info->lookups = c->lookups;
	info->hits = c->hits;
	info->cost = c->total_cost;
	os_unfair_lock_unlock(&c->lock);
	return 0;
}

static void key_info(cache_t *c, void *key, cache_key_info_t *info)
{
	struct entry *e = *find_entry(c, key);
	info->has_value = e && !e->vr->purgeable;
	info->state = e ? (uint8_t)(e->accesses > 255 ? 255 : e->accesses) : 0;
}

EXPORT int cache_get_info_for_key(cache_t *c, void *key, cache_key_info_t *info)
{
	if (!c || !key || !info)
		return EINVAL;
	os_unfair_lock_lock(&c->lock);
	key_info(c, key, info);
	os_unfair_lock_unlock(&c->lock);
	return 0;
}

EXPORT int cache_get_info_for_keys(cache_t *c, size_t count, void **keys, cache_key_info_t *infos)
{
	if (!c || (count && (!keys || !infos)))
		return EINVAL;
	os_unfair_lock_lock(&c->lock);
	for (size_t i = 0; i < count; i++)
		key_info(c, keys[i], &infos[i]);
	os_unfair_lock_unlock(&c->lock);
	return 0;
}

EXPORT void cache_print_stats(cache_t *c)
{
	if (!c)
		return;
	os_unfair_lock_lock(&c->lock);
	printf("Hits: %u/%u (%2d%%)\n", c->hits, c->lookups, c->lookups ? (int)(100ull * c->hits / c->lookups) : 0);
	printf("Keys: %u / Values: %u / Cost: %llu\n", c->nkeys, c->nvalues, (unsigned long long)c->total_cost);
	os_unfair_lock_unlock(&c->lock);
}

EXPORT void cache_print(cache_t *c)
{
	if (!c)
		return;
	printf("cache %p \"%s\"\n", (void *)c, c->name ? c->name : "");
	cache_print_stats(c);
	os_unfair_lock_lock(&c->lock);
	for (size_t b = 0; b < c->nbuckets; b++)
		for (struct entry *e = c->keys[b]; e; e = e->next)
			printf("    key %p value %p refs %u cost %zu%s\n", e->key, e->vr->value, e->vr->refs,
			    e->vr->cost, e->vr->purgeable ? " purgeable" : "");
	os_unfair_lock_unlock(&c->lock);
}

/* As if the system reported memory pressure: every cache evicts the values
 * no one holds (down to its minimum-values hint). */
EXPORT void cache_simulate_memory_warning_event(uintptr_t level)
{
	dispatch_async_and_wait(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		handle_memory_pressure(level);
	});
}
