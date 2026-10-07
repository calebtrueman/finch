/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
struct api {
	void *(*parse)(const void **, size_t *);
	void *(*pcs)(void *const *, int);
	void *(*bytes)(void *, size_t *);
	char *(*description)(void *);
	void (*destroy)(void *);
	int (*count)(void *);
	void *(*frames)(void *);
};
static struct api load(void *h)
{
	struct api a;
#define GET(field, name)                                                                           \
	*(void **)&a.field = dlsym(h, "os_log_backtrace_" name);                                   \
	assert(a.field)
	GET(parse, "create_from_buffer");
	GET(pcs, "create_from_pcs");
	GET(bytes, "copy_serialized_buffer");
	GET(description, "copy_description");
	GET(destroy, "destroy");
	GET(count, "get_length");
	GET(frames, "get_frames");
	return a;
}
static unsigned checks;
static void compare(struct api *a, struct api *b, void *x, void *y)
{
	assert(a->count(x) == b->count(y));
	assert(!memcmp(a->frames(x), b->frames(y), 20 * a->count(x)));
	size_t nx = 0, ny = 0;
	void *px = a->bytes(x, &nx), *py = b->bytes(y, &ny);
	if (nx != ny || memcmp(px, py, nx)) {
		fprintf(stderr, "bytes count=%d len=%zu/%zu\n", a->count(x), nx, ny);
		abort();
	}
	char *sx = a->description(x), *sy = b->description(y);
	if (a->count(x) && strcmp(sx, sy)) {
		fprintf(stderr, "description count=%d len=%zu/%zu tail=[%s]\n", a->count(x),
		    strlen(sx), strlen(sy), sx + (strlen(sx) > 60 ? strlen(sx) - 60 : 0));
		abort();
	}
	free(px);
	free(py);
	free(sx);
	free(sy);
	a->destroy(x);
	b->destroy(y);
	checks++;
}
int main(int argc, char **argv)
{
	assert(argc == 2);
	void *h = dlopen("/usr/lib/system/libsystem_trace.dylib", RTLD_NOW | RTLD_LOCAL),
	     *l = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!l) {
		puts(dlerror());
		return 1;
	}
	struct api a = load(h), b = load(l);
	for (unsigned n = 0; n < 300; n++) {
		unsigned u = n < 255 ? n : 255;
		size_t len = 4 + 16 * u + 4 * n + ((n + 3) & ~3u);
		uint8_t *p = calloc(1, len + 7);
		p[0] = 18;
		p[1] = u;
		uint16_t nn = n;
		memcpy(p + 2, &nn, 2);
		for (unsigned j = 0; j < u; j++) {
			p[4 + 16 * j] = j + 1;
			p[4 + 16 * j + 1] = j ^ 123;
		}
		for (unsigned i = 0; i < n; i++) {
			uint32_t off = i * 381237;
			memcpy(p + 4 + 16 * u + 4 * i, &off, 4);
			p[4 + 16 * u + 4 * n + i] = i % 7 == 0 ? 255 : (i * 19) % u;
		}
		const void *pa = p, *pb = p;
		size_t na = len + 7, nb = na;
		void *x = a.parse(&pa, &na), *y = b.parse(&pb, &nb);
		assert(x && y && pa == pb && na == nb);
		compare(&a, &b, x, y);
		for (size_t cut = 0; cut < len; cut += 1 + len / 11) {
			pa = pb = p;
			na = nb = cut;
			x = a.parse(&pa, &na);
			y = b.parse(&pb, &nb);
			assert(!x && !y && pa == p && pb == p && na == cut && nb == cut);
			checks++;
		}
		free(p);
	}
	void *pcs[] = {main, malloc, printf, (void *)1, NULL};
	compare(&a, &b, a.pcs(pcs, 5), b.pcs(pcs, 5));
	printf("backtrace: %u comparisons passed\n", checks);
}
