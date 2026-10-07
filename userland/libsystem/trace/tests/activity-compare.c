/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
extern char __dso_handle;
extern void os_release(void *);
struct api {
	void *none, *current, *log, *disabled;
	void *(*create)(void *, const char *, void *, unsigned);
	uint64_t (*id)(void *, uint64_t *);
	void (*enter)(void *, void *);
	void (*leave)(void *);
	void (*apply)(void *, void (^)(void));
	void (*initiate)(void *, const char *, unsigned, void (^)(void));
	unsigned (*active)(uint64_t *, unsigned *);
	bool (*enabled)(void *);
	uint64_t (*generate)(void *);
	uint64_t (*pointer)(void *, const void *);
};
static unsigned checks, failed;
#define C(X)                                                                                       \
	do {                                                                                       \
		checks++;                                                                          \
		if (!(X)) {                                                                        \
			if (failed++ < 20)                                                         \
				fprintf(stderr, "line %d: %s\n", __LINE__, #X);                    \
		}                                                                                  \
	} while (0)
static void bind(struct api *a, void *h)
{
#define B(F, S)                                                                                    \
	do {                                                                                       \
		*(void **)(&a->F) = dlsym(h, S);                                                   \
		if (!a->F) {                                                                       \
			fprintf(stderr, "missing %s\n", S);                                        \
			exit(2);                                                                   \
		}                                                                                  \
	} while (0)
	B(none, "_os_activity_none");
	B(current, "_os_activity_current");
	B(log, "_os_log_default");
	B(disabled, "_os_log_disabled");
	B(create, "_os_activity_create");
	B(id, "os_activity_get_identifier");
	B(enter, "os_activity_scope_enter");
	B(leave, "os_activity_scope_leave");
	B(apply, "os_activity_apply");
	B(initiate, "_os_activity_initiate");
	B(active, "os_activity_get_active");
	B(enabled, "os_signpost_enabled");
	B(generate, "os_signpost_id_generate");
	B(pointer, "os_signpost_id_make_with_pointer");
}
int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	static struct api a[2];
	bind(a, dlopen("/usr/lib/system/libsystem_trace.dylib", 2));
	bind(a + 1, dlopen(argv[1], 2));
	for (int k = 0; k < 2; k++) {
		C(a[k].id(a[k].none, NULL) == 0);
		C(a[k].enabled(a[k].disabled) == false);
		C(a[k].generate(a[k].disabled) == 0);
		C(a[k].pointer(a[k].disabled, (void *)17) == 0);
		C(a[k].enabled(a[k].log) == a[1 - k].enabled(a[1 - k].log));
		uint64_t id1 = a[k].generate(a[k].log), id2 = a[k].generate(a[k].log);
		C(id1 != 0 && id2 > id1);
		C(a[k].pointer(a[k].log, (void *)25) - a[k].pointer(a[k].log, (void *)17) == 8);
		void *parent = a[k].create(&__dso_handle, "Finch parent", a[k].none, 0);
		C(parent != NULL);
		uint64_t parentid = a[k].id(parent, NULL);
		C(parentid != 0);
		C(a[1 - k].id(parent, NULL) == parentid);
		uint64_t scope[2] = {0};
		a[k].enter(parent, scope);
		C(a[k].id(a[k].current, NULL) == parentid);
		C(a[1 - k].id(a[1 - k].current, NULL) == parentid);
		void *child = a[k].create(&__dso_handle, "Finch child", a[k].current, 0);
		C(child != NULL);
		uint64_t p = 0, childid = a[k].id(child, &p);
		C(childid != 0 && childid != parentid);
		C(p == parentid);
		a[1 - k].apply(child, ^{
		  uint64_t cp = 0;
		  C(a[k].id(a[k].current, &cp) == childid);
		  C(cp == parentid);
		  for (unsigned cap = 0; cap < 4; cap++) {
			  uint64_t ids[2][4];
			  memset(ids, 0xa5, sizeof(ids));
			  unsigned n[2] = {cap, cap};
			  unsigned r[2];
			  r[0] = a[0].active(ids[0], n);
			  r[1] = a[1].active(ids[1], n + 1);
			  C(r[0] == r[1]);
			  C(n[0] == n[1]);
			  C(!memcmp(ids[0], ids[1], sizeof(ids[0])));
		  }
		});
		C(a[k].id(a[k].current, NULL) == parentid);
		void *reuse = a[k].create(&__dso_handle, "reuse", a[k].current, 2);
		C(a[k].id(reuse, NULL) == parentid);
		os_release(reuse);
		a[1 - k].leave(scope);
		C(scope[0] == 0 && scope[1] == 0);
		os_release(child);
		os_release(parent);
		a[k].initiate(&__dso_handle, "initiate", 1, ^{
		  C(a[k].id(a[k].current, NULL) != 0);
		});
	}
	printf("activities and signposts: %u checks, %u failures\n", checks, failed);
	return failed ? 1 : 0;
}
