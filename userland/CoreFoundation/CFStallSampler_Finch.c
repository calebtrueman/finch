/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * A debugging aid: where a process's main thread is, seen from inside it, for apps that
 * don't let a debugger in (Apple's, in the VM, where DYLD_* variables are ignored).
 * With FINCH_SAMPLE_MAIN set to the process's name (or "*"), CoreFoundation's start-up
 * starts a thread that waits FINCH_SAMPLE_DELAY seconds (default 10), then
 * FINCH_SAMPLE_COUNT times (default 3), FINCH_SAMPLE_INTERVAL seconds apart (default 2),
 * suspends the main thread, walks its frame pointers and prints the frames, symbolized
 * where dladdr can, as "sample:" lines on stderr. Unset, it costs one getenv.
 */
#include "CFInternal.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <ptrauth.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static thread_act_t main_thread;

static double
env_number(const char *name, double fallback)
{
    const char *v = getenv(name);
    return v && *v ? atof(v) : fallback;
}

static void
print_frame(int n, uintptr_t pc)
{
    pc = (uintptr_t)ptrauth_strip((void *)pc, ptrauth_key_return_address);
    Dl_info info;
    if (dladdr((void *)pc, &info) && info.dli_fname) {
        const char *image = info.dli_fname;
        for (const char *p = image; *p; p++)
            if (*p == '/')
                image = p + 1;
        fprintf(stderr, "sample: %2d %-28s %#lx %s + %lu\n", n, image, (unsigned long)pc,
                info.dli_sname ? info.dli_sname : "?",
                (unsigned long)(pc - (uintptr_t)(info.dli_saddr ? info.dli_saddr : info.dli_fbase)));
    } else {
        fprintf(stderr, "sample: %2d ? %#lx\n", n, (unsigned long)pc);
    }
}

/* The frames are read while the thread is stopped; a frame pointer outside the stack ends the walk. */
static void
sample_once(int which)
{
    if (thread_suspend(main_thread) != KERN_SUCCESS)
        return;
    arm_thread_state64_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(main_thread, ARM_THREAD_STATE64, (thread_state_t)&st, &count) == KERN_SUCCESS) {
        fprintf(stderr, "sample: --- main thread, sample %d ---\n", which);
        uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(st), lr = (uintptr_t)arm_thread_state64_get_lr(st);
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st), sp = (uintptr_t)arm_thread_state64_get_sp(st);
        print_frame(0, pc);
        print_frame(1, lr);
        for (int n = 2; n < 64 && fp > sp && fp < sp + (64u << 20) && !(fp & 7); n++) {
            uintptr_t *frame = (uintptr_t *)fp;
            if (!frame[1])
                break;
            print_frame(n, frame[1]);
            if (frame[0] <= fp)
                break;
            fp = frame[0];
        }
    }
    thread_resume(main_thread);
}

static void *
sampler(void *arg __attribute__((unused)))
{
    usleep((useconds_t)(env_number("FINCH_SAMPLE_DELAY", 10) * 1e6));
    int count = (int)env_number("FINCH_SAMPLE_COUNT", 3);
    for (int i = 0; i < count; i++) {
        sample_once(i);
        usleep((useconds_t)(env_number("FINCH_SAMPLE_INTERVAL", 2) * 1e6));
    }
    return NULL;
}

CF_PRIVATE void
__CFFinchStartStallSampler(void)
{
    const char *only = getenv("FINCH_SAMPLE_MAIN");
    if (!only || !*only || (strcmp(only, "*") && strcmp(only, getprogname())))
        return;
    main_thread = mach_thread_self();
    pthread_t t;
    pthread_create(&t, NULL, sampler, NULL);
    pthread_detach(t);
}
