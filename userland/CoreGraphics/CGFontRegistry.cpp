/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The installed fonts, by PostScript name: the files under the system,
 * local and user font directories, indexed once on first use.
 */
#include "CGFontInternal.h"
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <map>
#include <string>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static std::map<std::string, std::string> *by_name;

static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

/* The PostScript name (name ID 6) of face 0 of a font file. */
static std::string
postscript_name(const uint8_t *d, size_t n)
{
    size_t base = n >= 16 && be32(d) == 'ttcf' ? be32(d + 12) : 0;
    if (base + 12 > n)
        return "";
    uint16_t count = be16(d + base + 4);
    for (uint16_t i = 0; i < count && base + 12 + 16 * (size_t)(i + 1) <= n; i++) {
        const uint8_t *rec = d + base + 12 + 16 * i;
        if (be32(rec) != 'name')
            continue;
        size_t off = be32(rec + 8), len = be32(rec + 12);
        if (off + len > n || len < 6)
            return "";
        const uint8_t *t = d + off;
        uint16_t records = be16(t + 2), storage = be16(t + 4);
        for (uint16_t r = 0; r < records && 6 + 12 * (size_t)(r + 1) <= len; r++) {
            const uint8_t *e = t + 6 + 12 * r;
            if (be16(e + 6) != 6)
                continue;
            size_t length = be16(e + 8), offset = be16(e + 10);
            if (storage + offset + length > len)
                continue;
            const uint8_t *s = t + storage + offset;
            std::string out;
            if (be16(e) == 3 || be16(e) == 0) {
                for (size_t k = 0; k + 1 < length; k += 2)
                    out += (char)s[k + 1];
            } else {
                out.assign((const char *)s, length);
            }
            return out;
        }
    }
    return "";
}

static void
scan(const std::string &dir, int depth)
{
    DIR *d = opendir(dir.c_str());
    if (!d)
        return;
    while (struct dirent *e = readdir(d)) {
        if (e->d_name[0] == '.')
            continue;
        std::string path = dir + "/" + e->d_name;
        struct stat st;
        if (stat(path.c_str(), &st))
            continue;
        if (S_ISDIR(st.st_mode)) {
            if (depth < 3)
                scan(path, depth + 1);
            continue;
        }
        const char *dot = strrchr(e->d_name, '.');
        if (!dot || (strcasecmp(dot, ".ttf") && strcasecmp(dot, ".otf") && strcasecmp(dot, ".ttc")))
            continue;
        int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        size_t want = st.st_size < 1 << 20 ? (size_t)st.st_size : 1 << 20;  /* the name table is near the front */
        uint8_t *buf = (uint8_t *)malloc(want);
        ssize_t got = read(fd, buf, want);
        close(fd);
        if (got > 0) {
            std::string ps = postscript_name(buf, (size_t)got);
            if (!ps.empty() && !by_name->count(ps))
                (*by_name)[ps] = path;
        }
        free(buf);
    }
    closedir(d);
}

static void
build(void)
{
    by_name = new std::map<std::string, std::string>();
    scan("/System/Library/Fonts", 0);
    scan("/Library/Fonts", 0);
    if (const char *home = getenv("HOME"))
        scan(std::string(home) + "/Library/Fonts", 0);
}

CFDataRef
CGFontRegistryCopyDataForName(CFStringRef name)
{
    char buf[512];
    if (!CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8))
        return NULL;
    pthread_once(&once, build);
    auto it = by_name->find(buf);
    if (it == by_name->end())
        return NULL;
    CGDataProviderRef p = CGDataProviderCreateWithFilename(it->second.c_str());
    CFDataRef data = p ? CGDataProviderCopyData(p) : NULL;
    if (p)
        CFRelease(p);
    return data;
}
