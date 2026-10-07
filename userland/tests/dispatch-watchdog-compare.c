/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Compare Finch's queue-thread query with the host function using live
 * host queues. This checks the caller's queue layout as well as results.
 */
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (*query_fn)(dispatch_queue_t, uint64_t *);
static query_fn apple, finch;
static unsigned checks, failures;

static void check(const char *name, dispatch_queue_t queue, int expected, uint64_t thread)
{
    uint64_t a = UINT64_MAX, b = UINT64_MAX;
    int ra = apple(queue, &a), rb = finch(queue, &b);
    checks++;
    if (ra != rb || a != b || rb != expected || b != thread) {
        failures++;
        fprintf(stderr, "%s: Apple %d/%llu, Finch %d/%llu, expected %d/%llu\n",
            name, ra, a, rb, b, expected, thread);
    }
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    void *a = dlopen("/usr/lib/system/libdispatch.dylib", RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    void *b = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (!a || !b) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    apple = (query_fn)dlsym(a, "dispatch_queue_get_threadid_4wdt");
    finch = (query_fn)dlsym(b, "dispatch_queue_get_threadid_4wdt");
    if (!apple || !finch || apple == finch) { fprintf(stderr, "missing distinct functions\n"); return 2; }
    uint64_t main_id = 0;
    pthread_threadid_np(NULL, &main_id);
    check("main", dispatch_get_main_queue(), 0, main_id);
    check("global", dispatch_get_global_queue(0, 0), EINVAL, 0);
    dispatch_queue_t serial = dispatch_queue_create("finch.watchdog.serial", NULL);
    dispatch_queue_t concurrent = dispatch_queue_create("finch.watchdog.concurrent", DISPATCH_QUEUE_CONCURRENT);
    check("idle serial", serial, ESRCH, 0);
    check("concurrent", concurrent, EINVAL, 0);
    dispatch_sync(serial, ^{ check("sync serial", serial, 0, main_id); });
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(serial, ^{
        uint64_t worker_id = 0;
        pthread_threadid_np(NULL, &worker_id);
        check("worker serial", serial, 0, worker_id);
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
        fprintf(stderr, "worker timed out\n"); return 2;
    }
    dispatch_sync(serial, ^{});
    dispatch_release(done);
    dispatch_release(serial);
    dispatch_release(concurrent);
    printf("dispatch watchdog: %u checks, %u failures\n", checks, failures);
    return failures ? 1 : 0;
}
