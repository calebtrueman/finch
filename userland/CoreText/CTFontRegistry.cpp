/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The fonts CoreText knows: those registered in this process (CTFontManager,
 * and fonts made from CGFonts), and the installed ones under the system,
 * local and user font directories (or FINCH_FONT_DIRS), indexed once by
 * PostScript, full and family name. Apple's font names that match no font
 * resolve to the open fonts Finch ships (../fonts/FinchFonts.h).
 */
#include "CTRegistry.h"
#include "../fonts/FinchFonts.h"
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
static std::map<std::string, std::string> *registered_full, *registered_family; /* name -> PostScript name */
static std::vector<CTInstalledFont> *installed;

static std::string
utf8(CFStringRef s)
{
    char buf[512];
    return s && CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8) ? buf : "";
}

/* A string from a font's name table (Windows or Unicode first, then Mac Roman). */
static std::string
name_from_table(const uint8_t *t, size_t len, uint16_t want)
{
    if (len < 6)
        return "";
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
        return name_from_table(d + off, len, want);
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
    for (const std::string &dir : finch_font_dirs())
        scan(dir, 0);
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
    /* Its full and family names too, as installed fonts are found by them. */
    std::string full, family;
    if (CFDataRef t = CGFontCopyTableForTag(font, 'name')) {
        full = name_from_table(CFDataGetBytePtr(t), (size_t)CFDataGetLength(t), 4);
        family = name_from_table(CFDataGetBytePtr(t), (size_t)CFDataGetLength(t), 16);
        if (family.empty())
            family = name_from_table(CFDataGetBytePtr(t), (size_t)CFDataGetLength(t), 1);
        CFRelease(t);
    }
    pthread_mutex_lock(&lock);
    if (!registered) {
        registered = new std::map<std::string, CGFontRef>();
        registered_full = new std::map<std::string, std::string>();
        registered_family = new std::map<std::string, std::string>();
    }
    if (!registered->count(name))
        (*registered)[name] = (CGFontRef)CFRetain(font);
    if (!full.empty() && !registered_full->count(full))
        (*registered_full)[full] = name;
    if (!family.empty() && !registered_family->count(family))
        (*registered_family)[family] = name;
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

/* A registered or installed font by PostScript, full or family name. */
static CGFontRef
copy_named(const std::string &n)
{
    pthread_mutex_lock(&lock);
    CGFontRef found = NULL;
    if (registered) {
        auto it = registered->find(n);
        if (it == registered->end()) {
            for (auto *names : {registered_full, registered_family}) {
                auto by = names->find(n);
                if (by != names->end() && (it = registered->find(by->second)) != registered->end())
                    break;
            }
        }
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

CGFontRef
CTFontRegistryCopyGraphicsFont(CFStringRef name)
{
    std::string n = utf8(name);
    if (n.empty())
        return NULL;
    CGFontRef f = copy_named(n);
    if (!f) {
        if (const char *alias = finch_font_alias(n.c_str()))
            f = copy_named(alias);
    }
    return f;
}

/* Is a style name (name ID 17 or 2) the face with these traits, at the family's regular width and weight? */
static bool
style_is(const std::string &style, bool bold, bool italic)
{
    static const char *plain[] = {"Regular", "Book", "Roman", "Normal", "Plain"};
    static const char *bolds[] = {"Bold"};
    static const char *italics[] = {"Italic", "Oblique"};
    static const char *bold_italics[] = {"Bold Italic", "Bold Oblique", "BoldItalic", "BoldOblique"};
    const char **list = bold && italic ? bold_italics : bold ? bolds : italic ? italics : plain;
    size_t count = bold && italic ? 4 : bold ? 1 : italic ? 2 : 5;
    for (size_t i = 0; i < count; i++)
        if (!strcasecmp(style.c_str(), list[i]))
            return true;
    return false;
}

CGFontRef
CTFontRegistryCopyFamilyFace(CFStringRef family, bool bold, bool italic)
{
    std::string fam = utf8(family);
    for (auto &f : CTInstalledFonts())
        if (f.family == fam && style_is(f.style, bold, italic))
            return font_at(f.path);
    return NULL;
}
