/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CFURLCreateFromFSRef and CFURLGetFSRef (CFURL.h on macOS; swift-corelibs
 * leaves them out). An FSRef is CarbonCore's (userland/CoreServices), so CF
 * looks up CarbonCore's FSPathMakeRef/FSRefMakePath when first asked, as
 * Apple's CF soft-links CarbonCore, and CF stays below CoreServices.
 */
#include <CoreFoundation/CFURL.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>

struct FSRef;
typedef int32_t (*path_make_ref_fn)(const uint8_t *, struct FSRef *, uint8_t *);
typedef int32_t (*ref_make_path_fn)(const struct FSRef *, uint8_t *, uint32_t);

#define CARBONCORE "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/CarbonCore.framework/Versions/A/CarbonCore"

static void *
carboncore(const char *symbol)
{
    void *h = dlopen(CARBONCORE, RTLD_LAZY | RTLD_NOLOAD);
    if (!h)
        h = dlopen(CARBONCORE, RTLD_LAZY);
    return h ? dlsym(h, symbol) : NULL;
}

CF_EXPORT CFURLRef
CFURLCreateFromFSRef(CFAllocatorRef allocator, const struct FSRef *fsRef)
{
    static ref_make_path_fn make_path;
    if (!make_path)
        make_path = (ref_make_path_fn)carboncore("FSRefMakePath");
    char path[PATH_MAX];
    if (!fsRef || !make_path || make_path(fsRef, (uint8_t *)path, sizeof path) != 0)
        return NULL;
    struct stat st;
    Boolean dir = stat(path, &st) == 0 && S_ISDIR(st.st_mode);
    return CFURLCreateFromFileSystemRepresentation(allocator, (const UInt8 *)path, strlen(path), dir);
}

CF_EXPORT Boolean
CFURLGetFSRef(CFURLRef url, struct FSRef *fsRef)
{
    static path_make_ref_fn make_ref;
    if (!make_ref)
        make_ref = (path_make_ref_fn)carboncore("FSPathMakeRef");
    char path[PATH_MAX];
    if (!url || !fsRef || !make_ref)
        return false;
    CFURLRef abs = CFURLCopyAbsoluteURL(url);
    CFStringRef scheme = abs ? CFURLCopyScheme(abs) : NULL;
    Boolean file = scheme && CFStringCompare(scheme, CFSTR("file"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    if (scheme)
        CFRelease(scheme);
    if (abs)
        CFRelease(abs);
    if (!file || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path))
        return false;
    return make_ref((const uint8_t *)path, fsRef, NULL) == 0;
}
