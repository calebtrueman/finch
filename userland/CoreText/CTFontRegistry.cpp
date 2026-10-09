/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The fonts CoreText knows: those registered in this process (CTFontManager,
 * and fonts made from CGFonts), and the installed ones under the system,
 * local and user font directories, indexed once by PostScript, full and
 * family name.
 */
#include "CTRegistry.h"
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <map>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static std::map<std::string, CGFontRef> *registered;  /* PostScript name -> font */
static std::vector<CTInstalledFont> *installed;

static std::string
utf8(CFStringRef s)
{
    char buf[512];
    return s && CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8) ? buf : "";
}

/* A name-table string of face 0 of a font file's bytes. */
static std::string
name_from_bytes(const uint8_t *d, size_t n, uint16_t want)
{
    size_t base = n >= 16 && ct_be32(d) == 'ttcf' ? ct_be32(d + 12) : 0;
    if (base + 12 > n)
        return "";
    uint16_t count = ct_be16(d + base + 4);
    for (uint16_t i = 0; i < count && base + 12 + 16 * (size_t)(i + 1) <= n; i++) {
        const uint8_t *rec = d + base + 12 + 16 * i;
        if (ct_be32(rec) != 'name')
            continue;
        size_t off = ct_be32(rec + 8), len = ct_be32(rec + 12);
        if (off + len > n || len < 6)
            return "";
        const uint8_t *t = d + off;
        uint16_t records = ct_be16(t + 2), storage = ct_be16(t + 4);
        std::string mac;
        for (uint16_t r = 0; r < records && 6 + 12 * (size_t)(r + 1) <= len; r++) {
            const uint8_t *e = t + 6 + 12 * r;
            if (ct_be16(e + 6) != want)
                continue;
            size_t length = ct_be16(e + 8), offset = ct_be16(e + 10);
            if (storage + offset + length > len)
                continue;
            const uint8_t *s = t + storage + offset;
            if (ct_be16(e) == 3 || ct_be16(e) == 0) {
                std::string out;
                for (size_t k = 0; k + 1 < length; k += 2)
                    out += s[k] ? '?' : (char)s[k + 1];
                return out;
            }
            if (ct_be16(e) == 1 && mac.empty())
                mac.assign((const char *)s, length);
        }
        return mac;
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
        size_t want = st.st_size < (1 << 20) ? (size_t)st.st_size : (size_t)1 << 20;
        uint8_t *buf = (uint8_t *)malloc(want);
        ssize_t got = read(fd, buf, want);
        close(fd);
        if (got > 0) {
            CTInstalledFont f;
            f.path = path;
            f.postscript = name_from_bytes(buf, (size_t)got, 6);
            f.full = name_from_bytes(buf, (size_t)got, 4);
            f.family = name_from_bytes(buf, (size_t)got, 16);
            if (f.family.empty())
                f.family = name_from_bytes(buf, (size_t)got, 1);
            f.style = name_from_bytes(buf, (size_t)got, 17);
            if (f.style.empty())
                f.style = name_from_bytes(buf, (size_t)got, 2);
            if (!f.postscript.empty())
                installed->push_back(f);
        }
        free(buf);
    }
    closedir(d);
}

static void
index_installed(void)
{
    installed = new std::vector<CTInstalledFont>();
    scan("/System/Library/Fonts", 0);
    scan("/Library/Fonts", 0);
    if (const char *home = getenv("HOME"))
        scan(std::string(home) + "/Library/Fonts", 0);
}

const std::vector<CTInstalledFont> &
CTInstalledFonts(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, index_installed);
    return *installed;
}

void
CTFontRegistryAddGraphicsFont(CGFontRef font)
{
    CFStringRef ps = CGFontCopyPostScriptName(font);
    std::string name = utf8(ps);
    if (ps)
        CFRelease(ps);
    if (name.empty())
        return;
    pthread_mutex_lock(&lock);
    if (!registered)
        registered = new std::map<std::string, CGFontRef>();
    if (!registered->count(name))
        (*registered)[name] = (CGFontRef)CFRetain(font);
    pthread_mutex_unlock(&lock);
}

bool
CTFontRegistryRemoveGraphicsFont(CGFontRef font)
{
    CFStringRef ps = CGFontCopyPostScriptName(font);
    std::string name = utf8(ps);
    if (ps)
        CFRelease(ps);
    pthread_mutex_lock(&lock);
    bool found = false;
    if (registered) {
        auto it = registered->find(name);
        if (it != registered->end()) {
            CFRelease(it->second);
            registered->erase(it);
            found = true;
        }
    }
    pthread_mutex_unlock(&lock);
    return found;
}

std::vector<std::string>
CTFontRegistryRegisteredNames(void)
{
    std::vector<std::string> out;
    pthread_mutex_lock(&lock);
    if (registered)
        for (auto &kv : *registered)
            out.push_back(kv.first);
    pthread_mutex_unlock(&lock);
    return out;
}

static CGFontRef
font_at(const std::string &path)
{
    CGDataProviderRef p = CGDataProviderCreateWithFilename(path.c_str());
    CGFontRef f = p ? CGFontCreateWithDataProvider(p) : NULL;
    if (p)
        CFRelease(p);
    return f;
}

CGFontRef
CTFontRegistryCopyGraphicsFont(CFStringRef name)
{
    std::string n = utf8(name);
    if (n.empty())
        return NULL;
    pthread_mutex_lock(&lock);
    CGFontRef found = NULL;
    if (registered) {
        auto it = registered->find(n);
        if (it != registered->end())
            found = (CGFontRef)CFRetain(it->second);
    }
    pthread_mutex_unlock(&lock);
    if (found)
        return found;
    const std::vector<CTInstalledFont> &all = CTInstalledFonts();
    for (auto &f : all)
        if (f.postscript == n)
            return font_at(f.path);
    for (auto &f : all)
        if (f.full == n)
            return font_at(f.path);
    /* a family: its regular face if it has one */
    const CTInstalledFont *pick = NULL;
    for (auto &f : all)
        if (f.family == n && (!pick || f.style == "Regular"))
            pick = &f;
    return pick ? font_at(pick->path) : NULL;
}
