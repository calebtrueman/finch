/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Alias Manager (Aliases.h). Finch's alias records hold the target's
 * path: the AliasRecord header (user type, size, host order) then 'FnAl'
 * and the UTF-8 path. Records apps saved on macOS (version 2: a fixed
 * header, then tagged fields, the POSIX path being tag 18 and the volume's
 * mount point tag 19) resolve too. Alias files: a symbolic link resolves
 * to its target; Finder alias files (bookmark data) aren't read yet.
 */
#include "CarbonCore_Finch.h"
#include <errno.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

FINCH_HIDDEN OSErr _FinchRefPath(const FSRef *ref, char *out, size_t size);
FINCH_HIDDEN OSErr _FinchPathRef(const char *path, FSRef *ref, Boolean *isDirectory, bool follow);
FINCH_HIDDEN OSErr _FinchErrnoToOSErr(int e);
FINCH_HIDDEN void _FinchReadFinderInfo(const char *path, bool directory, UInt8 out[32]);

#define ALIAS_MAGIC 0x466e416cu /* 'FnAl' */

struct finch_alias {
    OSType userType;
    UInt16 aliasSize;
    UInt16 pad;
    uint32_t magic;
    char path[];
};

static OSErr
make_alias(const char *path, AliasHandle *out)
{
    size_t n = strlen(path) + 1;
    size_t size = sizeof(struct finch_alias) + n;
    if (size > 0xffff)
        return paramErr;
    Handle h = NewHandleClear(size);
    if (!h)
        return MemError();
    struct finch_alias *a = (struct finch_alias *)*h;
    a->aliasSize = (UInt16)size;
    a->magic = ALIAS_MAGIC;
    memcpy(a->path, path, n);
    *out = (AliasHandle)h;
    return noErr;
}

static uint16_t
be16(const unsigned char *p)
{
    return (uint16_t)(p[0] << 8 | p[1]);
}

/* The path an alias record names, Finch's or a version 2 record from macOS. */
static OSErr
alias_path(AliasHandle alias, char *out, size_t size)
{
    if (!alias || !*alias)
        return paramErr;
    Size n = GetHandleSize((Handle)alias);
    const unsigned char *p = (const unsigned char *)*alias;
    if (n >= (Size)sizeof(struct finch_alias) && ((const struct finch_alias *)p)->magic == ALIAS_MAGIC) {
        strlcpy(out, ((const struct finch_alias *)p)->path, size);
        return noErr;
    }
    if (n >= 150 && be16(p + 6) == 2) {
        char rel[PATH_MAX] = {0}, mount[PATH_MAX] = {0};
        Size at = 150;
        while (at + 4 <= n) {
            int16_t tag = (int16_t)be16(p + at);
            uint16_t len = be16(p + at + 2);
            if (tag == -1 || at + 4 + len > n)
                break;
            if (tag == 18 && len < sizeof rel)
                memcpy(rel, p + at + 4, len), rel[len] = 0;
            if (tag == 19 && len < sizeof mount)
                memcpy(mount, p + at + 4, len), mount[len] = 0;
            at += 4 + len + (len & 1);
        }
        if (rel[0]) {
            if (mount[0] && strcmp(mount, "/"))
                snprintf(out, size, "%s%s%s", mount, rel[0] == '/' ? "" : "/", rel);
            else
                snprintf(out, size, "%s%s", rel[0] == '/' ? "" : "/", rel);
            return noErr;
        }
    }
    return paramErr;
}

OSErr
FSNewAlias(const FSRef *fromFile, const FSRef *target, AliasHandle *inAlias)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(target, path, sizeof path);
    return e ? e : make_alias(path, inAlias);
}

OSErr
FSNewAliasMinimal(const FSRef *target, AliasHandle *inAlias)
{
    return FSNewAlias(NULL, target, inAlias);
}

static OSErr
unicode_target(const FSRef *parent, UniCharCount n, const UniChar *name, char *out, size_t size)
{
    char dir[PATH_MAX];
    OSErr e = _FinchRefPath(parent, dir, sizeof dir);
    if (e)
        return e;
    CFStringRef s = CFStringCreateWithCharacters(NULL, name, n);
    char fs[PATH_MAX];
    bool ok = s && CFStringGetFileSystemRepresentation(s, fs, sizeof fs);
    if (s)
        CFRelease(s);
    if (!ok)
        return bdNamErr;
    snprintf(out, size, "%s%s%s", dir, strcmp(dir, "/") ? "/" : "", fs);
    return noErr;
}

OSErr
FSNewAliasUnicode(const FSRef *fromFile, const FSRef *targetParentRef, UniCharCount targetNameLength,
                  const UniChar *targetName, AliasHandle *inAlias, Boolean *isDirectory)
{
    char path[PATH_MAX];
    OSErr e = unicode_target(targetParentRef, targetNameLength, targetName, path, sizeof path);
    if (e)
        return e;
    struct stat st;
    bool exists = !stat(path, &st);
    if (isDirectory)
        *isDirectory = exists && S_ISDIR(st.st_mode);
    e = make_alias(path, inAlias);
    return e ? e : (exists ? noErr : fnfErr);
}

OSErr
FSNewAliasMinimalUnicode(const FSRef *targetParentRef, UniCharCount targetNameLength, const UniChar *targetName,
                         AliasHandle *inAlias, Boolean *isDirectory)
{
    return FSNewAliasUnicode(NULL, targetParentRef, targetNameLength, targetName, inAlias, isDirectory);
}

OSStatus
FSNewAliasFromPath(const char *fromFilePath, const char *targetPath, OptionBits flags, AliasHandle *inAlias,
                   Boolean *isDirectory)
{
    if (!targetPath)
        return paramErr;
    struct stat st;
    bool exists = !stat(targetPath, &st);
    if (isDirectory)
        *isDirectory = exists && S_ISDIR(st.st_mode);
    char real[PATH_MAX];
    OSErr e = make_alias(exists && realpath(targetPath, real) ? real : targetPath, inAlias);
    return e ? e : (exists ? noErr : fnfErr);
}

OSErr
FSResolveAliasWithMountFlags(const FSRef *fromFile, AliasHandle inAlias, FSRef *target, Boolean *wasChanged,
                             unsigned long mountFlags)
{
    char path[PATH_MAX];
    OSErr e = alias_path(inAlias, path, sizeof path);
    if (e)
        return e;
    if (wasChanged)
        *wasChanged = true;  /* as macOS reports for a record with no "from" file */
    return _FinchPathRef(path, target, NULL, true);
}

OSErr
FSResolveAlias(const FSRef *fromFile, AliasHandle alias, FSRef *target, Boolean *wasChanged)
{
    return FSResolveAliasWithMountFlags(fromFile, alias, target, wasChanged, 0);
}

OSErr
FSUpdateAlias(const FSRef *fromFile, const FSRef *target, AliasHandle alias, Boolean *wasChanged)
{
    char path[PATH_MAX], old[PATH_MAX];
    OSErr e = _FinchRefPath(target, path, sizeof path);
    if (e)
        return e;
    bool same = !alias_path(alias, old, sizeof old) && !strcmp(old, path);
    if (wasChanged)
        *wasChanged = !same;
    if (same)
        return noErr;
    AliasHandle fresh;
    if ((e = make_alias(path, &fresh)))
        return e;
    OSType type = ((struct finch_alias *)*alias)->userType;
    Size n = GetHandleSize((Handle)fresh);
    SetHandleSize((Handle)alias, n);
    if ((e = MemError())) {
        DisposeHandle((Handle)fresh);
        return e;
    }
    memcpy(*alias, *fresh, n);
    ((struct finch_alias *)*alias)->userType = type;
    DisposeHandle((Handle)fresh);
    return noErr;
}

OSStatus
FSMatchAliasBulk(const FSRef *fromFile, unsigned long rulesMask, AliasHandle inAlias, short *aliasCount,
                 FSRef *aliasList, Boolean *needsUpdate, FSAliasFilterProcPtr aliasFilter, void *yourDataPtr)
{
    if (!aliasCount || *aliasCount < 1 || !aliasList ||
        !(rulesMask & (kARMMountVol | kARMSearch | kARMSearchMore | kARMSearchRelFirst | kARMTryFileIDFirst)))
        return paramErr;
    char path[PATH_MAX];
    OSErr e = alias_path(inAlias, path, sizeof path);
    if (!e)
        e = _FinchPathRef(path, &aliasList[0], NULL, true);
    *aliasCount = e ? 0 : 1;
    if (needsUpdate)
        *needsUpdate = false;
    return e;
}

OSStatus
FSCopyAliasInfo(AliasHandle inAlias, HFSUniStr255 *targetName, HFSUniStr255 *volumeName, CFStringRef *pathString,
                FSAliasInfoBitmap *whichInfo, FSAliasInfo *info)
{
    char path[PATH_MAX];
    OSErr e = alias_path(inAlias, path, sizeof path);
    if (e)
        return e;
    if (targetName) {
        const char *slash = strrchr(path, '/');
        CFStringRef s = CFStringCreateWithFileSystemRepresentation(NULL, slash && slash[1] ? slash + 1 : path);
        CFIndex len = s ? MIN(CFStringGetLength(s), 255) : 0;
        targetName->length = (UInt16)len;
        if (s) {
            CFStringGetCharacters(s, CFRangeMake(0, len), targetName->unicode);
            CFRelease(s);
        }
    }
    if (volumeName) {
        static const UniChar hd[] = {'M', 'a', 'c', 'i', 'n', 't', 'o', 's', 'h', ' ', 'H', 'D'};
        volumeName->length = 12;
        memcpy(volumeName->unicode, hd, sizeof hd);
    }
    if (pathString)
        *pathString = CFStringCreateWithFileSystemRepresentation(NULL, path);
    if (whichInfo)
        *whichInfo = kFSAliasInfoNone;
    if (info) {
        memset(info, 0, sizeof *info);
        struct stat st;
        if (!stat(path, &st)) {
            if (whichInfo)
                *whichInfo = kFSAliasInfoIsDirectory | kFSAliasInfoIDs;
            info->isDirectory = S_ISDIR(st.st_mode);
            info->nodeID = (UInt32)st.st_ino;
        }
    }
    return noErr;
}

OSErr
FSIsAliasFile(const FSRef *fileRef, Boolean *aliasFileFlag, Boolean *folderFlag)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(fileRef, path, sizeof path);
    if (e)
        return e;
    struct stat st;
    if (lstat(path, &st))
        return _FinchErrnoToOSErr(errno);
    UInt8 fi[32];
    _FinchReadFinderInfo(path, S_ISDIR(st.st_mode), fi);
    bool alias = S_ISLNK(st.st_mode) || (!S_ISDIR(st.st_mode) && (((FileInfo *)fi)->finderFlags & kIsAlias));
    if (aliasFileFlag)
        *aliasFileFlag = alias;
    if (folderFlag)
        *folderFlag = S_ISDIR(st.st_mode);
    return noErr;
}

OSErr
FSResolveAliasFileWithMountFlags(FSRef *theRef, Boolean resolveAliasChains, Boolean *targetIsFolder,
                                 Boolean *wasAliased, unsigned long mountFlags)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(theRef, path, sizeof path);
    if (e)
        return e;
    struct stat st;
    if (lstat(path, &st))
        return _FinchErrnoToOSErr(errno);
    bool aliased = false;
    if (S_ISLNK(st.st_mode)) {
        char real[PATH_MAX];
        if (!realpath(path, real))
            return fnfErr;
        if ((e = _FinchPathRef(real, theRef, NULL, true)))
            return e;
        stat(real, &st);
        aliased = true;
    } else if (!S_ISDIR(st.st_mode)) {
        UInt8 fi[32];
        _FinchReadFinderInfo(path, false, fi);
        if (((FileInfo *)fi)->finderFlags & kIsAlias)
            return fnfErr;  /* a Finder alias file: bookmark data Finch can't resolve yet */
    }
    if (targetIsFolder)
        *targetIsFolder = S_ISDIR(st.st_mode);
    if (wasAliased)
        *wasAliased = aliased;
    return noErr;
}

OSErr
FSResolveAliasFile(FSRef *theRef, Boolean resolveAliasChains, Boolean *targetIsFolder, Boolean *wasAliased)
{
    return FSResolveAliasFileWithMountFlags(theRef, resolveAliasChains, targetIsFolder, wasAliased, 0);
}

OSErr
FSFollowFinderAlias(FSRef *fromFile, AliasHandle alias, Boolean logon, FSRef *target, Boolean *wasChanged)
{
    return FSResolveAlias(fromFile, alias, target, wasChanged);
}

/* The AliasRecord header, whatever the SDK shows of it: user type, then size. */
struct header {
    OSType userType;
    UInt16 aliasSize;
};

OSType GetAliasUserType(AliasHandle alias) { return alias && *alias ? ((struct header *)*alias)->userType : 0; }
void SetAliasUserType(AliasHandle alias, OSType userType) { if (alias && *alias) ((struct header *)*alias)->userType = userType; }
Size GetAliasSize(AliasHandle alias) { return alias && *alias ? (Size)((struct header *)*alias)->aliasSize : 0; }
Size GetAliasSizeFromPtr(const AliasRecord *alias) { return alias ? (Size)((const struct header *)alias)->aliasSize : 0; }
OSType GetAliasUserTypeFromPtr(const AliasRecord *alias) { return alias ? ((const struct header *)alias)->userType : 0; }
void SetAliasUserTypeWithPtr(AliasPtr alias, OSType userType) { if (alias) ((struct header *)alias)->userType = userType; }
