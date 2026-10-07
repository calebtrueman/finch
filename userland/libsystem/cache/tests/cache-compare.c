/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * cache-compare: runs the same randomized operation sequences against
 * Apple's libcache and Finch's, logging every return code, fetched value and
 * callback (key/value retain and release), and compares the logs. Eviction
 * is disabled (no hints, no purgeable callbacks) so results are
 * deterministic.
 *
 *   cache-compare <path to Finch's libcache.dylib>
 */

#include <cache.h>
#include <cache_callbacks.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct api {
	int (*create)(const char *, const cache_attributes_t *, cache_t **);
	int (*set)(cache_t *, void *, void *, cache_cost_t);
	int (*get)(cache_t *, void *, void **);
	int (*release)(cache_t *, void *);
	int (*remove)(cache_t *, void *);
	int (*remove_all)(cache_t *);
	int (*destroy)(cache_t *);
	uintptr_t (*hash_cstring)(void *, void *);
	uintptr_t (*hash_integer)(void *, void *);
	uintptr_t (*hash_bytes)(const char *, size_t);
};

static char logbuf[1 << 22];
static size_t loglen;

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	size_t n = (size_t)vsnprintf(logbuf + loglen, sizeof(logbuf) - loglen, fmt, ap);
	va_end(ap);
	if (getenv("CACHE_COMPARE_TRACE"))
		fputs(logbuf + loglen, stderr);
	loglen += n;
}

static void key_retain(void *in, void **out, void *ud) { (void)ud; logf_("kret %lu\n", (unsigned long)(uintptr_t)in); *out = in; }
static void key_release(void *k, void *ud) { (void)ud; logf_("krel %lu\n", (unsigned long)(uintptr_t)k); }
static void value_release(void *v, void *ud) { (void)ud; logf_("vrel %lu\n", (unsigned long)(uintptr_t)v); }
static void value_retain(void *v, void *ud) { (void)ud; logf_("vret %lu\n", (unsigned long)(uintptr_t)v); }

static uint64_t seed;
static uint32_t rnd(void) { seed = seed * 6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(seed >> 33); }

static void run(const struct api *a, uint64_t s, int version)
{
	seed = s;
	loglen = 0;
	cache_attributes_t attrs = {
		.version = (uint32_t)version, .key_hash_cb = a->hash_integer, .key_is_equal_cb = cache_key_is_equal_cb_integer,
		.key_retain_cb = key_retain, .key_release_cb = key_release, .value_release_cb = value_release,
		.value_retain_cb = value_retain,
	};
	cache_t *c = NULL;
	logf_("create %d\n", a->create("org.finch.test", &attrs, &c));
	int held[64] = { 0 };
	for (int i = 0; i < 400; i++) {
		uintptr_t key = 1 + rnd() % 16, value = 1000 + rnd() % 24;
		void *out = NULL;
		int r;
		switch (rnd() % 6) {
		case 0: case 1:
			r = a->set(c, (void *)key, (void *)value, rnd() % 100);
			logf_("set %lu %lu = %d\n", (unsigned long)key, (unsigned long)value, r);
			if (r == 0) held[value - 1000]++;
			break;
		case 2:
			r = a->get(c, (void *)key, &out);
			logf_("get %lu = %d %lu\n", (unsigned long)key, r, (unsigned long)(uintptr_t)out);
			if (r == 0) held[(uintptr_t)out - 1000]++;
			break;
		case 3:
			if (held[value - 1000] > 0) {
				r = a->release(c, (void *)value);
				logf_("release %lu = %d\n", (unsigned long)value, r);
				if (r == 0) held[value - 1000]--;
			}
			break;
		case 4:
			logf_("remove %lu = %d\n", (unsigned long)key, a->remove(c, (void *)key));
			break;
		case 5:
			if (rnd() % 20 == 0) logf_("remove_all = %d\n", a->remove_all(c));
			break;
		}
	}
	/* Release what's still held, then destroy. (Apple's cache_destroy frees
	 * the cache even with values held; releasing afterwards crashes it.) */
	for (int v = 0; v < 24; v++)
		while (held[v]-- > 0)
			logf_("release %d = %d\n", 1000 + v, a->release(c, (void *)(uintptr_t)(1000 + v)));
	logf_("destroy = %d\n", a->destroy(c));
}

static void load(void *h, struct api *a)
{
	a->create = dlsym(h, "cache_create"); a->set = dlsym(h, "cache_set_and_retain");
	a->get = dlsym(h, "cache_get_and_retain"); a->release = dlsym(h, "cache_release_value");
	a->remove = dlsym(h, "cache_remove"); a->remove_all = dlsym(h, "cache_remove_all");
	a->destroy = dlsym(h, "cache_destroy"); a->hash_cstring = dlsym(h, "cache_key_hash_cb_cstring");
	a->hash_integer = dlsym(h, "cache_key_hash_cb_integer"); a->hash_bytes = dlsym(h, "cache_hash_byte_string");
}

/* Sort a log's lines: callbacks may run in a different order within one call. */
static int cmpline(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static char *normalize(const char *log)
{
	char *copy = strdup(log), *lines[200000];
	int n = 0;
	for (char *l = strtok(copy, "\n"); l; l = strtok(NULL, "\n")) lines[n++] = l;
	/* Sort within each operation: an op's callback lines precede its result line. */
	char *out = calloc(1, strlen(log) + 2);
	int start = 0;
	for (int i = 0; i < n; i++) {
		if (strncmp(lines[i], "kre", 3) && strncmp(lines[i], "vre", 3)) {
			qsort(lines + start, (size_t)(i - start), sizeof(char *), cmpline);
			for (int j = start; j <= i; j++) { strcat(out, lines[j]); strcat(out, "\n"); }
			start = i + 1;
		}
	}
	free(copy);
	return out;
}

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: cache-compare <finch libcache.dylib>\n"); return 2; }
	void *ha = dlopen("/usr/lib/system/libcache.dylib", RTLD_NOW | RTLD_LOCAL);
	void *hf = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!ha || !hf || ha == hf) { fprintf(stderr, "cache-compare: %s\n", dlerror()); return 2; }
	struct api apple, finch;
	load(ha, &apple);
	load(hf, &finch);
	unsigned long checks = 0, failures = 0;

	/* Hash callbacks: identical values. */
	for (int i = 0; i < 100000; i++) {
		char buf[32];
		snprintf(buf, sizeof(buf), "key-%d-%x", i, i * 2654435761u);
		checks += 3;
		if (apple.hash_cstring(buf, NULL) != finch.hash_cstring(buf, NULL)) failures++;
		if (apple.hash_integer((void *)(uintptr_t)(i * 7919), NULL) != finch.hash_integer((void *)(uintptr_t)(i * 7919), NULL)) failures++;
		if (apple.hash_bytes(buf, (size_t)(i % 20)) != finch.hash_bytes(buf, (size_t)(i % 20))) failures++;
	}

	for (uint64_t s = 1; s <= 300; s++) {
		for (int version = 1; version <= 2; version++) {
			run(&apple, s, version);
			char *la = normalize(logbuf);
			run(&finch, s, version);
			char *lf = normalize(logbuf);
			checks++;
			if (strcmp(la, lf)) {
				if (failures++ < 3) {
					fprintf(stderr, "FAIL seed %llu v%d\n", (unsigned long long)s, version);
					const char *pa = la, *pf = lf;
					while (*pa && *pa == *pf) pa++, pf++;
					while (pa > la && pa[-1] != '\n') pa--, pf--;
					fprintf(stderr, "  apple: %.120s\n  finch: %.120s\n", pa, pf);
				}
			}
			free(la);
			free(lf);
		}
	}
	printf("cache-compare: %lu checks, %lu failures\n", checks, failures);
	return failures != 0;
}
