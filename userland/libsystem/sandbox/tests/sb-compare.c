/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Compare read-only calls and caller-owned buffers with the host library.
 * This test never enters a sandbox or grants or revokes access.
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned checks, failures;
static void equal(const char *name, long a, long b)
{
    checks++;
    if (a != b) {
        failures++;
        fprintf(stderr, "%s: Apple %ld, Finch %ld\n", name, a, b);
    }
}

static void *symbol(void *h, const char *name)
{
    void *p = dlsym(h, name);
    if (!p) { fprintf(stderr, "missing %s: %s\n", name, dlerror()); exit(2); }
    return p;
}

struct attrs {
    uint32_t version, size, profile_length, container_length;
    char profile[64], container[1024];
};

static void data(void *a, void *b)
{
    const char *words[] = {
        "SANDBOX_CHECK_NO_REPORT", "SANDBOX_CHECK_CANONICAL",
        "SANDBOX_CHECK_NOFOLLOW", "SANDBOX_CHECK_ALLOW_APPROVAL",
        "SANDBOX_CHECK_POSIX_READABLE", "SANDBOX_CHECK_POSIX_WRITEABLE",
        "SANDBOX_CHECK_NO_APPROVAL", "SANDBOX_EXTENSION_DEFAULT",
        "SANDBOX_EXTENSION_CANONICAL", "SANDBOX_EXTENSION_NOFOLLOW_ANY",
        "SANDBOX_EXTENSION_PREFIXMATCH", "SANDBOX_EXTENSION_NO_REPORT",
        "SANDBOX_EXTENSION_NOFOLLOW", "SANDBOX_EXTENSION_NO_STORAGE_CLASS",
        "SANDBOX_EXTENSION_USER_INTENT", "SANDBOX_EXTENSION_MACL_LEARNING",
        "SANDBOX_PROFILE_TYPE_PLATFORM", "SANDBOX_PROFILE_TYPE_BASTION",
        "SANDBOX_PROFILE_TYPE_PROCESS", "SANDBOX_PROFILE_TYPE_AUTOBOX",
        "SANDBOX_PROFILE_TYPE_GLOBAL_OVERRIDE"
    };
    for (size_t i = 0; i < sizeof(words)/sizeof(*words); i++)
        equal(words[i], *(uint32_t *)symbol(a, words[i]), *(uint32_t *)symbol(b, words[i]));
    const char *wide[] = {
        "SANDBOX_STORAGE_CLASS_GROUP_ANY",
        "SANDBOX_STORAGE_CLASS_PROPERTY_READ_RESTRICTED",
        "SANDBOX_STORAGE_CLASS_PROPERTY_WRITE_RESTRICTED",
        "SANDBOX_STORAGE_CLASS_PROPERTY_REPLACEMENT_RESTRICTED",
        "SANDBOX_STORAGE_CLASS_PROPERTY_ACCEPTS_USER_APPROVAL"
    };
    for (size_t i = 0; i < sizeof(wide)/sizeof(*wide); i++)
        equal(wide[i], *(uint64_t *)symbol(a, wide[i]), *(uint64_t *)symbol(b, wide[i]));
    const char *strings[] = { "APP_SANDBOX_READ", "APP_SANDBOX_READ_WRITE",
        "APP_SANDBOX_MACH", "APP_SANDBOX_IOKIT_CLIENT", "IOS_SANDBOX_CONTAINER",
        "IOS_SANDBOX_APPLICATION_GROUP" };
    for (size_t i = 0; i < sizeof(strings)/sizeof(*strings); i++)
        equal(strings[i], 0, strcmp(*(char **)symbol(a, strings[i]), *(char **)symbol(b, strings[i])));
}

static void spawnattrs(void *a, void *b)
{
    void (*init[2])(struct attrs *) = { symbol(a, "sandbox_spawnattrs_init"), symbol(b, "sandbox_spawnattrs_init") };
    const char *names[] = { "sandbox_spawnattrs_setprofilename", "sandbox_spawnattrs_setcontainer" };
    const char *getters[] = { "sandbox_spawnattrs_getprofilename", "sandbox_spawnattrs_getcontainer" };
    const size_t lengths[] = { 0, 1, 62, 63, 64, 65, 1022, 1023, 1024, 1025 };
    char text[1026];
    for (size_t n = 0; n < sizeof(lengths)/sizeof(*lengths); n++) {
        memset(text, 'a', lengths[n]); text[lengths[n]] = 0;
        for (int kind = 0; kind < 2; kind++) {
            struct attrs x[2];
            int result[2], error[2];
            for (int j = 0; j < 2; j++) {
                memset(&x[j], 0xa5, sizeof(x[j]));
                init[j](&x[j]);
                int (*set)(struct attrs *, const char *) = symbol(j ? b : a, names[kind]);
                errno = 0;
                result[j] = set(&x[j], text); error[j] = errno;
            }
            equal(names[kind], result[0], result[1]);
            equal("spawn error", error[0], error[1]);
            equal("spawn buffer", 0, memcmp(&x[0], &x[1], sizeof(x[0])));
            for (int j = 0; j < 2; j++) {
                int (*get)(struct attrs *, const char **) = symbol(j ? b : a, getters[kind]);
                const char *out = NULL;
                equal("getter result", 0, get(&x[j], &out));
                equal("getter address", 1, out == (kind ? x[j].container : x[j].profile));
            }
        }
    }
}

static void queries(void *a, void *b)
{
    int (*check[2])(pid_t, const char *, uint32_t, ...) = { symbol(a, "sandbox_check"), symbol(b, "sandbox_check") };
    const char *operations[] = { NULL, "file-read-data", "file-write-data", "mach-lookup", "finch-nonexistent-operation" };
    const uint32_t filters[] = { 0, 1, 0x40000001, 0x20000001, 0x10000001, 20, 0x01ffffff };
    for (size_t op = 0; op < sizeof(operations)/sizeof(*operations); op++) {
        for (size_t f = 0; f < sizeof(filters)/sizeof(*filters); f++) {
            int r[2], e[2];
            for (int j = 0; j < 2; j++) {
                errno = 0;
                r[j] = check[j](getpid(), operations[op], filters[f], "/tmp"); e[j] = errno;
            }
            equal("sandbox_check result", r[0], r[1]);
            equal("sandbox_check error", e[0], e[1]);
        }
    }
    bool (*domain[2])(const char *) = {
        symbol(a, "sandbox_requests_integrity_protection_for_preference_domain"),
        symbol(b, "sandbox_requests_integrity_protection_for_preference_domain")
    };
    const char *domains[] = { "", "com.apple.universalaccess", "COM.APPLE.UNIVERSALACCESS",
        "com.apple.networkserviceproxy", "com.apple.inputsources", "org.finch.test" };
    for (size_t i = 0; i < sizeof(domains)/sizeof(*domains); i++)
        equal(domains[i], domain[0](domains[i]), domain[1](domains[i]));
}

static void rootless(void *a, void *b)
{
    const char *paths[] = { "/", "/System", "/usr/bin/true", "/tmp", "/dev/null",
        "/private/tmp/finch-sandbox-comparison-does-not-exist" };
    const char *names[] = { "rootless_check_trusted", "rootless_protected_volume" };
    const char *class_names[] = { "rootless_check_trusted_class", "rootless_check_datavault_flag",
        "rootless_check_restricted_flag" };
    const char *classes[] = { NULL, "", "KernelExtensionManagement", "finch-nonexistent-class" };
    for (size_t p = 0; p < sizeof(paths)/sizeof(*paths); p++) {
        for (size_t n = 0; n < sizeof(names)/sizeof(*names); n++) {
            int (*fa)(const char *) = symbol(a, names[n]);
            int (*fb)(const char *) = symbol(b, names[n]);
            errno = 0; int ra = fa(paths[p]), ea = errno;
            errno = 0; int rb = fb(paths[p]), eb = errno;
            equal(names[n], ra, rb);
            if (ra < 0) equal("rootless error", ea, eb);
        }
        for (size_t n = 0; n < sizeof(class_names)/sizeof(*class_names); n++) {
            int (*fa)(const char *, const char *) = symbol(a, class_names[n]);
            int (*fb)(const char *, const char *) = symbol(b, class_names[n]);
            for (size_t c = 0; c < sizeof(classes)/sizeof(*classes); c++) {
                errno = 0; int ra = fa(paths[p], classes[c]), ea = errno;
                errno = 0; int rb = fb(paths[p], classes[c]), eb = errno;
                equal(class_names[n], ra, rb);
                if (ra < 0) equal("rootless class error", ea, eb);
            }
        }
        int fd = open(paths[p], O_RDONLY);
        const char *fd_names[] = { "rootless_check_trusted_fd", "rootless_protected_volume_fd" };
        for (size_t n = 0; n < sizeof(fd_names)/sizeof(*fd_names); n++) {
            int (*fa)(int) = symbol(a, fd_names[n]);
            int (*fb)(int) = symbol(b, fd_names[n]);
            errno = 0; int ra = fa(fd), ea = errno;
            errno = 0; int rb = fb(fd), eb = errno;
            equal(fd_names[n], ra, rb);
            if (ra < 0) equal("rootless fd error", ea, eb);
        }
        if (fd >= 0) close(fd);
    }
    int (*fa)(void) = symbol(a, "rootless_restricted_environment");
    int (*fb)(void) = symbol(b, "rootless_restricted_environment");
    equal("restricted environment", fa(), fb());
}

static void private_directories(void *a, void *b)
{
    char directory[] = "/private/tmp/finch-sandbox-XXXXXX";
    if (!mkdtemp(directory)) { perror("mkdtemp"); exit(2); }
    const char *names[] = { "rootless_mkdir_restricted", "rootless_mkdir_datavault", "rootless_mkdir_nounlink" };
    for (size_t n = 0; n < sizeof(names)/sizeof(*names); n++) {
        for (int existing = 0; existing < 3; existing++) {
            int results[2], errors[2], remains[2];
            for (int j = 0; j < 2; j++) {
                char path[1024];
                snprintf(path, sizeof(path), "%s/%zu-%d-%d", directory, n, existing, j);
                if (existing == 1 && mkdir(path, 0700)) { perror("mkdir"); exit(2); }
                if (existing == 2 && symlink("missing", path)) { perror("symlink"); exit(2); }
                int (*make)(const char *, mode_t, const char *) = symbol(j ? b : a, names[n]);
                errno = 0;
                results[j] = make(path, 0700, NULL); errors[j] = errno;
                struct stat st;
                remains[j] = lstat(path, &st) == 0;
                if (remains[j]) {
                    if (S_ISLNK(st.st_mode)) { if (unlink(path)) { perror("unlink"); exit(2); } }
                    else if (rmdir(path)) { perror("rmdir (test directory)"); exit(2); }
                }
            }
            equal(names[n], results[0], results[1]);
            if (results[0] < 0) equal("mkdir error", errors[0], errors[1]);
            equal("mkdir rollback", remains[0], remains[1]);
        }
    }
    const char *remove_names[] = { "rootless_remove_datavault_in_favor_of_static_storage_class",
        "rootless_remove_restricted_in_favor_of_static_storage_class" };
    for (size_t n = 0; n < sizeof(remove_names)/sizeof(*remove_names); n++) {
        int (*fa)(const char *) = symbol(a, remove_names[n]);
        int (*fb)(const char *) = symbol(b, remove_names[n]);
        errno = 0; int ra = fa(directory), ea = errno;
        errno = 0; int rb = fb(directory), eb = errno;
        equal(remove_names[n], ra, rb);
        if (ra < 0) equal("remove class error", ea, eb);
    }
    char *(*temp_a)(const char *) = symbol(a, "_amkrtemp");
    char *(*temp_b)(const char *) = symbol(b, "_amkrtemp");
    char prefix[1024];
    snprintf(prefix, sizeof(prefix), "%s/name-", directory);
    errno = 0; char *pa = temp_a(prefix); int ea = errno;
    errno = 0; char *pb = temp_b(prefix); int eb = errno;
    equal("temporary name available", pa != NULL, pb != NULL);
    if (!pa) equal("temporary name error", ea, eb);
    if (pa && pb) {
        equal("temporary name length", strlen(pa), strlen(pb));
        size_t len = strlen(pa);
        equal("temporary name prefix", 0, strncmp(pa, pb, len > 6 ? len - 6 : len));
        equal("temporary name not created", -1, access(pb, F_OK));
    }
    free(pa); free(pb);
    if (rmdir(directory)) { perror("rmdir"); exit(2); }
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    void *a = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    void *b = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (!a || !b) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    data(a, b);
    spawnattrs(a, b);
    queries(a, b);
    rootless(a, b);
    private_directories(a, b);
    printf("sandbox: %u checks, %u failures\n", checks, failures);
    return failures ? 1 : 0;
}
