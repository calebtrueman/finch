/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Check requests and failure paths that the host's fixed SIP settings cannot
 * exercise. Only the four kernel-facing calls below are replaced for this test.
 */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/attr.h>
#include <unistd.h>

static int fake_csr(uint32_t);
static int fake_attr(const char *, void *, void *, size_t, unsigned long);
static int fake_fattr(int, void *, void *, size_t, unsigned long);
static int fake_mac(const char *, int, void *);
static int fake_csops(pid_t, unsigned int, void *, size_t);
#define csr_check fake_csr
#define getattrlist fake_attr
#define fgetattrlist fake_fattr
#define __sandbox_ms fake_mac
#define csops fake_csops
#include "../rootless.c"

static unsigned checks, mac_calls, attr_calls;
static bool sip_off, sealed, synthetic, attr_failure, extended_failure, mac_failure;
static uint64_t verdict;
static const char *expected_path, *expected_class;
static int expected_fd, expected_call;
static int codesign_error;
static uint32_t codesign_flags;

static void check(bool yes) { checks++; assert(yes); }
static int fake_csr(uint32_t flags) { check(flags == 2); return sip_off ? 0 : -1; }

static int attributes(void *attributes, void *buffer, size_t size, unsigned long options)
{
    attr_calls++;
    struct attrlist *a = attributes;
    check(a->bitmapcount == 5);
    if (a->volattr) {
        check(a->volattr == 0x80024000 && options == 0 && size == 40);
        if (attr_failure) { errno = EIO; return -1; }
        struct volume_attributes *v = buffer;
        v->mount_flags = sealed ? 0x4000 : 0;
        v->capabilities.capabilities[0] = sealed ? 0x2000000 : 0;
    } else {
        check(a->forkattr == 0x200 && options == 0x20 && size == 12);
        if (extended_failure) { errno = ENOTSUP; return -1; }
        ((struct file_attributes *)buffer)->flags = synthetic ? 0x20 : 0;
    }
    return 0;
}

static int fake_attr(const char *p, void *a, void *b, size_t s, unsigned long o)
{ check(p == expected_path); return attributes(a, b, s, o); }
static int fake_fattr(int fd, void *a, void *b, size_t s, unsigned long o)
{ check(fd == expected_fd); return attributes(a, b, s, o); }

static int fake_mac(const char *policy, int call, void *argument)
{
    mac_calls++;
    check(!strcmp(policy, "Sandbox"));
    check(call == expected_call);
    uint64_t *q = argument;
    uint64_t *result;
    if (call == 2) {
        result = (void *)q[0];
        check(q[1] == 1);
        check(!strcmp((const char *)q[2], "file-write-data"));
        check(q[3] == (expected_path ? 1 : 240));
        check(q[4] == (expected_path ? (uintptr_t)expected_path : (uint32_t)expected_fd));
        check(q[5] == 0x20000005 && q[6] == 0);
        check(q[7] == (uintptr_t)expected_class);
        for (int i = 8; i < 20; i++) check(q[i] == 0);
    } else {
        check(q[0] == (expected_path ? (uintptr_t)expected_path : (uint64_t)(int64_t)expected_fd));
        result = (void *)q[1];
    }
    check(*result == 0);
    *result = verdict;
    if (mac_failure) { errno = EPERM; return -1; }
    return 0;
}

static int fake_csops(pid_t pid, unsigned op, void *out, size_t size)
{
    check(pid == 0 && op == 0 && size == 4);
    *(uint32_t *)out = codesign_flags;
    if (codesign_error) { errno = codesign_error; return -1; }
    return 0;
}

int main(void)
{
    for (int by_fd = 0; by_fd < 2; by_fd++) {
        expected_path = by_fd ? NULL : "/example";
        expected_fd = -7;
        expected_class = "test-class";
        expected_call = 2;
        for (int mode = 0; mode < 5; mode++) {
            sip_off = mode == 0;
            sealed = mode == 1 || mode == 2 || mode == 4;
            synthetic = mode == 2;
            extended_failure = mode == 4;
            attr_failure = mode == 3;
            for (int v = 0; v < 3; v++) {
                for (int fail = 0; fail < 2; fail++) {
                    mac_calls = attr_calls = 0;
                    verdict = v; mac_failure = fail;
                    int r = trusted(expected_path, expected_fd, expected_class);
                    bool bypass = sip_off || (sealed && !synthetic);
                    check(r == (bypass ? 0 : fail ? -1 : v != 1));
                    check(mac_calls == (bypass ? 0u : 1u));
                    if (sip_off) check(attr_calls == 0);
                    if (!bypass && fail) check(errno == EPERM);
                }
            }
        }
    }
    for (int fd = 0; fd < 2; fd++) {
        expected_path = fd ? NULL : "/example";
        expected_fd = -7;
        expected_call = fd ? 0x104 : 0x103;
        for (int v = 0; v < 3; v++) {
            for (int fail = 0; fail < 2; fail++) {
                verdict = v; mac_failure = fail;
                int r = fd ? rootless_protected_volume_fd(expected_fd) : rootless_protected_volume(expected_path);
                check(r == (fail ? -1 : v != 0));
                if (fail) check(errno == EPERM);
            }
        }
    }
    for (unsigned flags = 0; flags < 16; flags++) {
        codesign_flags = flags;
        check(rootless_restricted_environment() == ((flags >> 3) & 1));
    }
    codesign_error = ESRCH;
    check(rootless_restricted_environment() == -1 && errno == ESRCH);
    printf("rootless requests: %u checks passed\n", checks);
    return 0;
}
