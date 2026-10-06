/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-libsystem-test: exercises the libSystem pieces Finch builds from
 * source (malloc, pthread, dispatch, platform string routines, JIT write
 * protection). Prints one line per check and exits non-zero on failure.
 */

#include <dispatch/dispatch.h>
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int failures;

#define CHECK(name, cond) do {                                   \
	bool _ok = (cond);                                       \
	printf("%-34s %s\n", name, _ok ? "ok" : "FAIL");         \
	if (!_ok) failures++;                                    \
} while (0)

static bool
test_malloc(void)
{
	/* Sizes spanning nano, tiny, small, medium and large allocations. */
	static const size_t sizes[] = { 1, 16, 128, 1024, 16384, 262144, 4u << 20 };
	for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
		unsigned char *p = malloc(sizes[i]);
		if (p == NULL) return false;
		memset(p, (int)i, sizes[i]);
		p = realloc(p, sizes[i] * 2);
		if (p == NULL || p[sizes[i] - 1] != (unsigned char)i) return false;
		free(p);
	}
	void *z = calloc(1000, 8);
	for (int i = 0; i < 8000; i++) if (((char *)z)[i]) return false;
	free(z);
	return true;
}

struct counter { pthread_mutex_t lock; pthread_cond_t cond; long value; int done; };

static void *
pthread_worker(void *arg)
{
	struct counter *c = arg;
	for (int i = 0; i < 10000; i++) {
		pthread_mutex_lock(&c->lock);
		c->value++;
		pthread_mutex_unlock(&c->lock);
	}
	pthread_mutex_lock(&c->lock);
	c->done++;
	pthread_cond_signal(&c->cond);
	pthread_mutex_unlock(&c->lock);
	return NULL;
}

static bool
test_pthread(void)
{
	struct counter c = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0 };
	pthread_t t[8];
	for (int i = 0; i < 8; i++) {
		if (pthread_create(&t[i], NULL, pthread_worker, &c) != 0) return false;
	}
	pthread_mutex_lock(&c.lock);
	while (c.done < 8) pthread_cond_wait(&c.cond, &c.lock);
	pthread_mutex_unlock(&c.lock);
	for (int i = 0; i < 8; i++) pthread_join(t[i], NULL);
	return c.value == 80000;
}

static bool
test_dispatch(void)
{
	__block _Atomic long sum = 0;
	dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
	dispatch_group_t g = dispatch_group_create();
	for (long i = 1; i <= 1000; i++) {
		dispatch_group_async(g, q, ^{ atomic_fetch_add(&sum, i); });
	}
	if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) return false;

	/* Serial queue ordering + semaphore handoff. */
	dispatch_queue_t serial = dispatch_queue_create("org.finch.test.serial", NULL);
	int order[4];
	int *orderp = order;
	__block int n = 0;
	for (int i = 0; i < 4; i++) dispatch_async(serial, ^{ orderp[n++] = i; });
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	dispatch_async(serial, ^{ dispatch_semaphore_signal(sem); });
	if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) return false;
	for (int i = 0; i < 4; i++) if (order[i] != i) return false;

	/* dispatch_apply across worker threads. */
	__block _Atomic long applied = 0;
	dispatch_apply(256, q, ^(size_t idx) { atomic_fetch_add(&applied, (long)idx); });
	return sum == 500500 && applied == 256 * 255 / 2;
}

static bool
test_strings(void)
{
	char a[64] = "hello, finch", b[64];
	memmove(a + 2, a, 12);                      /* overlapping */
	strlcpy(b, "abc", sizeof(b));
	return strcmp(a + 2, "hello, finch") == 0 && strlen(b) == 3 &&
	    ffs(0x10) == 5 && fls(0x10) == 5 && flsl(1L << 40) == 41;
}

/* JIT: write code while RW, execute after flipping to RX. */
static bool
test_jit(void)
{
	if (!pthread_jit_write_protect_supported_np()) {
		printf("%-34s %s\n", "  (JIT write protect unsupported)", "skip");
		return true;
	}
	size_t len = 16384;
	uint32_t *code = mmap(NULL, len, PROT_READ | PROT_WRITE | PROT_EXEC,
	    MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT, -1, 0);
	if (code == MAP_FAILED) {
		printf("  mmap(MAP_JIT) failed: %s\n", strerror(errno));
		return false;
	}
	pthread_jit_write_protect_np(0);
	code[0] = 0xd2800540;                      /* mov x0, #42 */
	code[1] = 0xd65f03c0;                      /* ret */
	pthread_jit_write_protect_np(1);
	sys_icache_invalidate(code, 8);
	int (*fn)(void) = (int (*)(void))code;
	int r = fn();
	munmap(code, len);
	return r == 42;
}

int
main(void)
{
	CHECK("malloc / realloc / calloc", test_malloc());
	CHECK("pthread mutex + condvar (8 thr)", test_pthread());
	CHECK("dispatch group/serial/apply", test_dispatch());
	CHECK("platform string + bit ops", test_strings());
	CHECK("JIT write protect (MAP_JIT)", test_jit());
	printf("%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures,
	    failures == 1 ? "" : "s");
	return failures ? 1 : 0;
}
