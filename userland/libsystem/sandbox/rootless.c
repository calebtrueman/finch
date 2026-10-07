/* SPDX-License-Identifier: MIT OR Apache-2.0
 * File trust queries, based on the call layouts in Sandbox-2680.100.174.
 * The kernel supplies the answers. A failed query must not grant trust.
 */
#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <fts.h>
#include <libgen.h>
#include <limits.h>
#include <pthread.h>
#include <pwd.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/xattr.h>
#include <unistd.h>
#include "internal.h"

extern int csr_check(uint32_t);
extern int csops(pid_t, unsigned int, void *, size_t);

/* These packed results have a four-byte length before the requested data. */
struct volume_attributes {
    uint32_t length, mount_flags;
    vol_capabilities_attr_t capabilities;
} __attribute__((packed));
struct file_attributes {
    uint32_t length;
    uint64_t flags;
} __attribute__((packed));
_Static_assert(sizeof(struct volume_attributes) == 40, "volume attributes");
_Static_assert(sizeof(struct file_attributes) == 12, "file attributes");

static bool authenticated_root(const char *path, int fd)
{
    struct attrlist request = { .bitmapcount = ATTR_BIT_MAP_COUNT,
        .volattr = ATTR_VOL_INFO | ATTR_VOL_MOUNTFLAGS | ATTR_VOL_CAPABILITIES };
    struct volume_attributes volume = {0};
    int r = path ? getattrlist(path, &request, &volume, sizeof(volume), 0)
                 : fgetattrlist(fd, &request, &volume, sizeof(volume), 0);
    if (r || !(volume.mount_flags & 0x4000) ||
        !(volume.capabilities.capabilities[0] & 0x2000000)) return false;

    request = (struct attrlist){ .bitmapcount = ATTR_BIT_MAP_COUNT,
        .forkattr = 0x200 }; /* ATTR_CMNEXT_EXT_FLAGS */
    struct file_attributes file = {0};
    r = path ? getattrlist(path, &request, &file, sizeof(file), FSOPT_ATTR_CMN_EXTENDED)
             : fgetattrlist(fd, &request, &file, sizeof(file), FSOPT_ATTR_CMN_EXTENDED);
    /* Apple's older-volume fallback accepts a volume without extended flags. */
    return r != 0 || !(file.flags & 0x20); /* EF_IS_SYNTHETIC */
}

static int trusted(const char *path, int fd, const char *storage_class)
{
    if (csr_check(2) == 0 || authenticated_root(path, fd)) return 0;
    uint64_t result = 0;
    struct {
        uint64_t *result;
        int64_t pid;
        const char *operation;
        uint64_t filter, argument, flags, target;
        const char *storage_class;
        uint64_t reserved[12];
    } request = { .result = &result, .pid = 1,
        .operation = "file-write-data", .filter = path ? 1 : 240,
        .argument = path ? (uint64_t)path : (uint32_t)fd,
        .flags = 0x20000005, .storage_class = storage_class };
    _Static_assert(sizeof(request) == 160, "trust request");
    if (__sandbox_ms("Sandbox", 2, &request) != 0) return -1;
    return result != 1;
}

EXPORT int rootless_check_trusted(const char *path) { return trusted(path, -1, NULL); }
EXPORT int rootless_check_trusted_fd(int fd) { return trusted(NULL, fd, NULL); }
EXPORT int rootless_check_trusted_class(const char *path, const char *name)
{ return trusted(path, -1, name); }

static int protected_flag(const char *path, const char *name, uint32_t flag)
{
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    if (flag == SF_RESTRICTED && authenticated_root(path, -1)) st.st_flags |= flag;
    if (!(st.st_flags & flag)) return 1;
    if (!name) return 0;
    char value[128];
    ssize_t n = getxattr(path, "com.apple.rootless", value, sizeof(value), 0, 0);
    if (n < 1 || (size_t)n != strlen(name)) return 1;
    return memcmp(name, value, (size_t)n) != 0;
}

EXPORT int rootless_check_datavault_flag(const char *path, const char *name)
{ return protected_flag(path, name, 0x80); }
EXPORT int rootless_check_restricted_flag(const char *path, const char *name)
{ return protected_flag(path, name, SF_RESTRICTED); }

EXPORT int rootless_restricted_environment(void)
{
    uint32_t flags = 0;
    if (csops(0, 0, &flags, sizeof(flags)) != 0) return -1;
    return (flags >> 3) & 1;
}

EXPORT int rootless_protected_volume(const char *path)
{
    uint64_t result = 0;
    struct { const char *path; uint64_t *result; } request = {path, &result};
    if (__sandbox_ms("Sandbox", 0x103, &request) != 0) return -1;
    return result != 0;
}

EXPORT int rootless_protected_volume_fd(int fd)
{
    uint64_t result = 0;
    struct { int64_t fd; uint64_t *result; } request = {fd, &result};
    if (__sandbox_ms("Sandbox", 0x104, &request) != 0) return -1;
    return result != 0;
}

/* Return a newly allocated candidate name. The caller creates the file.
 * The kernel's sentinel is cached once, including when callers race.
 */
EXPORT char *_amkrtemp(const char *prefix)
{
    static _Atomic(char *) sentinel;
    char *suffix = atomic_load(&sentinel);
    if (!suffix) {
        size_t size = 0;
        if (sysctlbyname("security.mac.sandbox.sentinel", NULL, &size, NULL, 0)) return NULL;
        char *fresh = malloc(size);
        if (!fresh) return NULL;
        if (sysctlbyname("security.mac.sandbox.sentinel", fresh, &size, NULL, 0)) {
            int error = errno;
            free(fresh);
            errno = error;
            return NULL;
        }
        char *expected = NULL;
        if (!atomic_compare_exchange_strong(&sentinel, &expected, fresh)) free(fresh);
        suffix = atomic_load(&sentinel);
    }
    char *path = NULL;
    if (asprintf(&path, "%s%s-XXXXXX", prefix, suffix) < 0) return NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    /* This API returns a name without creating a file, as its callers expect. */
    if (!mktemp(path)) { free(path); return NULL; }
#pragma clang diagnostic pop
    return path;
}

/* Open the parent first, then work relative to that open directory. After
 * applying protection, reopen the child and check that it is still the
 * same directory and carries every requested flag.
 */
static bool internal_home_path(const char *path)
{
    bool (*diagnostics)(const char *) = dlsym(RTLD_DEFAULT, "os_variant_has_internal_diagnostics");
    if (!diagnostics || !diagnostics("com.apple.sandbox")) return false;
    int (*lookup)(uid_t, struct passwd *, char *, size_t, struct passwd **) =
        dlsym(RTLD_DEFAULT, "getpwuid_r");
    if (!lookup) return false;
    long size = sysconf(_SC_GETPW_R_SIZE_MAX);
    if (size < 0) return false;
    char *buffer = malloc((size_t)size);
    if (!buffer) return false;
    struct passwd entry, *found = NULL;
    bool inside = false;
    if (!lookup(geteuid(), &entry, buffer, (size_t)size, &found) && found && found->pw_dir) {
        char *home = realpath(found->pw_dir, NULL);
        char *resolved = realpath(path, NULL);
        if (!resolved && errno == ENOENT) {
            char parent[PATH_MAX], leaf[NAME_MAX + 1];
            if (dirname_r(path, parent) && basename_r(path, leaf)) {
                char *base = realpath(parent, NULL);
                if (base) { if (asprintf(&resolved, "%s/%s", base, leaf) < 0) resolved = NULL; free(base); }
            }
        }
        if (home && resolved && !strncasecmp(home, "/Users", 6)) {
            size_t n = strlen(home);
            inside = !strncasecmp(home, resolved, n) && (resolved[n] == '/' || resolved[n] == 0);
        }
        free(resolved);
        free(home);
    }
    free(buffer);
    return inside;
}

static int mkdir_protected(const char *path, mode_t mode, const char *name, uint32_t flags)
{
    if (internal_home_path(path)) { errno = EINVAL; return -1; }
    char parent[PATH_MAX], leaf[NAME_MAX + 1];
    if (!dirname_r(path, parent)) return -1;
    int parent_fd = open(parent, O_SEARCH);
    if (parent_fd < 0) return -1;
    int child_fd = -1, created = 0;
    struct stat parent_st, child_st, after;
    if (fstat(parent_fd, &parent_st) || !basename_r(path, leaf)) goto fail;
    if (mkdirat(parent_fd, leaf, mode)) {
        if (flags != SF_NOUNLINK || errno != EEXIST) goto fail;
    } else {
        created = 1;
    }
    child_fd = openat(parent_fd, leaf, O_SEARCH | O_NOFOLLOW_ANY);
    if (child_fd < 0 || fstat(child_fd, &child_st)) goto fail;
    if (parent_st.st_dev != child_st.st_dev) { errno = ECANCELED; goto fail; }
    struct { uint64_t fd; const char *name; } request = {
        (uint32_t)child_fd, name ? name : ""
    };
    if (__sandbox_ms("Sandbox", 0x105, &request) || fchflags(child_fd, flags)) goto fail;
    close(child_fd);
    child_fd = openat(parent_fd, leaf, O_SEARCH | O_NOFOLLOW_ANY);
    if (child_fd < 0 || fstat(child_fd, &after)) goto fail;
    if (child_st.st_dev != after.st_dev || child_st.st_ino != after.st_ino ||
        (after.st_flags & flags) != flags) { errno = ECANCELED; goto fail; }
    close(child_fd);
    close(parent_fd);
    return 0;
fail:;
    int error = errno;
    if (created) unlinkat(parent_fd, leaf, AT_REMOVEDIR | AT_SYMLINK_NOFOLLOW_ANY);
    if (child_fd >= 0) close(child_fd);
    close(parent_fd);
    errno = error;
    return -1;
}

EXPORT int rootless_mkdir_restricted(const char *path, mode_t mode, const char *name)
{ return mkdir_protected(path, mode, name, SF_RESTRICTED); }
EXPORT int rootless_mkdir_datavault(const char *path, mode_t mode, const char *name)
{ return mkdir_protected(path, mode, name, 0x80); }
EXPORT int rootless_mkdir_nounlink(const char *path, mode_t mode, const char *name)
{ return mkdir_protected(path, mode, name, SF_NOUNLINK); }

static int remove_storage_class(const char *path, uint32_t flags)
{
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct { int64_t fd; uint64_t flags; } request = {fd, flags};
    FTS *tree = NULL;
    if (__sandbox_ms("Sandbox", 0x107, &request)) goto fail;
    char *paths[] = {(char *)path, NULL};
    tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!tree) goto fail;
    FTSENT *entry;
    errno = 0;
    while ((entry = fts_read(tree))) {
        switch (entry->fts_info) {
        case FTS_D: break; /* Children first. */
        case FTS_DNR: case FTS_ERR: case FTS_NS:
            errno = entry->fts_errno ? entry->fts_errno : EIO;
            goto fail;
        default:
            if ((entry->fts_statp->st_flags & flags) &&
                lchflags(entry->fts_accpath, entry->fts_statp->st_flags & ~flags)) goto fail;
        }
        errno = 0;
    }
    if (errno) goto fail;
    int64_t handle = fd;
    if (__sandbox_ms("Sandbox", 0x106, &handle)) goto fail;
    fts_close(tree);
    close(fd);
    return 0;
fail:;
    int error = errno;
    if (tree) fts_close(tree);
    close(fd);
    errno = error;
    return -1;
}

EXPORT int rootless_remove_datavault_in_favor_of_static_storage_class(const char *path)
{ return remove_storage_class(path, 0x80); }
EXPORT int rootless_remove_restricted_in_favor_of_static_storage_class(const char *path)
{ return remove_storage_class(path, SF_RESTRICTED); }

/* These two legacy entry points are also constants in the host library. */
EXPORT int rootless_allows_task_for_pid(void) { return 1; }
EXPORT int rootless_suspend(void) { return 0; }

/* Registrations name the storage classes accepted by the token helper.
 * Tokens always have bit 31 set; a trust failure leaves every grant bit clear.
 */
struct storage_class {
    struct storage_class *next;
    unsigned index;
    char name[];
};
static struct storage_class *classes;
static pthread_mutex_t class_lock = PTHREAD_MUTEX_INITIALIZER;

EXPORT void rootless_register_trusted_storage_class(const char *name, unsigned index)
{
    pthread_mutex_lock(&class_lock);
    for (struct storage_class *p = classes; p; p = p->next) {
        if (p->index == index && !strcmp(p->name, name)) {
            pthread_mutex_unlock(&class_lock);
            return;
        }
    }
    size_t size = strlen(name) + 1;
    struct storage_class *p = malloc(sizeof(*p) + size);
    if (!p) abort();
    p->index = index;
    memcpy(p->name, name, size);
    p->next = classes;
    classes = p;
    pthread_mutex_unlock(&class_lock);
}

EXPORT uint32_t rootless_trusted_by_self_token(int fd, unsigned index)
{
    uint32_t token = 0x80000000u;
    pthread_mutex_lock(&class_lock);
    if (!classes) {
        if (!trusted(NULL, fd, NULL)) token |= 1u << (index & 31);
    } else {
        for (struct storage_class *p = classes; p; p = p->next) {
            if (p->index == index && !trusted(NULL, fd, p->name)) {
                token |= 1u << (index & 31);
                break;
            }
        }
    }
    pthread_mutex_unlock(&class_lock);
    return token;
}

EXPORT bool rootless_verify_trusted_by_self_token(uint32_t token, unsigned index)
{
    if (!(token & 0x80000000u)) abort();
    return (token >> (index & 31)) & 1;
}
