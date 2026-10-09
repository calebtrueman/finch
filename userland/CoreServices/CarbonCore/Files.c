/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The File Manager's FSRef calls over POSIX (Files.h).
 *
 * An FSRef names a file by volume and file number, as macOS's do, so it
 * follows the file through moves and renames: Finch's holds a magic, the
 * volume's fsid and the inode, and is turned back into a path with
 * fsgetpath(2). Where the file system can't do that, the path the ref was
 * made from (kept per process) is used if it still names the same file.
 *
 * Catalog info comes from stat(2), the Finder info from the
 * com.apple.FinderInfo extended attribute (big-endian on disk, host order in
 * the structures) and resource fork sizes from com.apple.ResourceFork.
 * Forks are file descriptors (the resource fork is path/..namedfork/rsrc).
 */
#include "CarbonCore_Finch.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <pwd.h>
#include <sys/attr.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

#define REF_MAGIC 0x466e5266u /* 'FnRf' */

struct ref {
    uint32_t magic;
    uint32_t reserved;
    fsid_t fsid;
    uint64_t ino;
    uint8_t pad[80 - 24];
};
_Static_assert(sizeof(struct ref) == sizeof(FSRef), "FSRef layout");

FINCH_HIDDEN OSErr _FinchErrnoToOSErr(int e);

OSErr
_FinchErrnoToOSErr(int e)
{
    switch (e) {
    case 0: return noErr;
    case ENOENT: return fnfErr;
    case ENOTDIR: return dirNFErr;
    case EEXIST: return dupFNErr;
    case ENOTEMPTY: return fBsyErr;
    case EBUSY: return fBsyErr;
    case EACCES:
    case EPERM: return afpAccessDenied;
    case EROFS: return wPrErr;
    case ENOSPC: return dskFulErr;
    case ENAMETOOLONG: return bdNamErr;
    case EBADF: return rfNumErr;
    case EXDEV: return diffVolErr;
    case EINVAL: return paramErr;
    case ENOMEM: return memFullErr;
    case EIO: return ioErr;
    case ELOOP: return fnfErr;
    case ENOATTR: return eofErr;
    }
    return ioErr;
}

#pragma mark - Paths kept for file systems without fsgetpath

struct known {
    fsid_t fsid;
    uint64_t ino;
    char *path;
};
static struct known *known;
static long nknown;
static pthread_mutex_t known_lock = PTHREAD_MUTEX_INITIALIZER;

static void
remember(const struct ref *r, const char *path)
{
    pthread_mutex_lock(&known_lock);
    for (long i = 0; i < nknown; i++)
        if (known[i].ino == r->ino && !memcmp(&known[i].fsid, &r->fsid, sizeof r->fsid)) {
            if (strcmp(known[i].path, path)) {
                free(known[i].path);
                known[i].path = strdup(path);
            }
            pthread_mutex_unlock(&known_lock);
            return;
        }
    struct known *k = realloc(known, (nknown + 1) * sizeof *k);
    if (k) {
        known = k;
        known[nknown++] = (struct known){r->fsid, r->ino, strdup(path)};
    }
    pthread_mutex_unlock(&known_lock);
}

static bool
same_file(const char *path, const struct ref *r)
{
    struct stat st;
    struct statfs sf;
    return stat(path, &st) == 0 && (uint64_t)st.st_ino == r->ino && statfs(path, &sf) == 0 &&
           !memcmp(&sf.f_fsid, &r->fsid, sizeof r->fsid);
}

static void
canonical(const char *path, char *out, size_t size)
{
    char buf[PATH_MAX];
    if (realpath(path, buf))
        strlcpy(out, buf, size);
    else
        strlcpy(out, path, size);
}

/* The path of a ref's file, or an error (fnfErr once it's gone). */
FINCH_HIDDEN OSErr
_FinchRefPath(const FSRef *ref, char *out, size_t size)
{
    const struct ref *r = (const struct ref *)ref;
    if (!r || r->magic != REF_MAGIC)
        return paramErr;
    ssize_t n = fsgetpath(out, size, (fsid_t *)&r->fsid, r->ino);
    if (n > 0 && same_file(out, r))
        return noErr;
    OSErr e = fnfErr;
    pthread_mutex_lock(&known_lock);
    for (long i = 0; i < nknown; i++)
        if (known[i].ino == r->ino && !memcmp(&known[i].fsid, &r->fsid, sizeof r->fsid)) {
            if (same_file(known[i].path, r)) {
                strlcpy(out, known[i].path, size);
                e = noErr;
            }
            break;
        }
    pthread_mutex_unlock(&known_lock);
    return e;
}

/* A ref for a path (following a symlink at the end unless told not to). */
FINCH_HIDDEN OSErr
_FinchPathRef(const char *path, FSRef *ref, Boolean *isDirectory, bool follow)
{
    struct stat st;
    struct statfs sf;
    if ((follow ? stat(path, &st) : lstat(path, &st)) != 0)
        return _FinchErrnoToOSErr(errno);
    if (statfs(path, &sf) != 0)
        return _FinchErrnoToOSErr(errno);
    if (isDirectory)
        *isDirectory = S_ISDIR(st.st_mode);
    if (ref) {
        struct ref *r = (struct ref *)ref;
        memset(r, 0, sizeof *r);
        r->magic = REF_MAGIC;
        r->fsid = sf.f_fsid;
        r->ino = st.st_ino;
        char canon[PATH_MAX];
        canonical(path, canon, sizeof canon);
        remember(r, canon);
    }
    return noErr;
}

OSStatus
FSPathMakeRef(const UInt8 *path, FSRef *ref, Boolean *isDirectory)
{
    if (!path)
        return paramErr;
    return _FinchPathRef((const char *)path, ref, isDirectory, true);
}

OSStatus
FSPathMakeRefWithOptions(const UInt8 *path, OptionBits options, FSRef *ref, Boolean *isDirectory)
{
    if (!path)
        return paramErr;
    return _FinchPathRef((const char *)path, ref, isDirectory, !(options & kFSPathMakeRefDoNotFollowLeafSymlink));
}

OSStatus
FSRefMakePath(const FSRef *ref, UInt8 *path, UInt32 pathBufferSize)
{
    if (!ref || !path)
        return paramErr;
    char buf[PATH_MAX];
    OSErr e = _FinchRefPath(ref, buf, sizeof buf);
    if (e)
        return e;
    if (strlen(buf) + 1 > pathBufferSize)
        return pathTooLongErr;
    memcpy(path, buf, strlen(buf) + 1);
    return noErr;
}

OSErr
FSCompareFSRefs(const FSRef *ref1, const FSRef *ref2)
{
    const struct ref *a = (const struct ref *)ref1, *b = (const struct ref *)ref2;
    if (!a || !b || a->magic != REF_MAGIC || b->magic != REF_MAGIC)
        return paramErr;
    if (memcmp(&a->fsid, &b->fsid, sizeof a->fsid))
        return diffVolErr;
    return a->ino == b->ino ? noErr : errFSRefsDifferent;
}

Boolean
FSIsFSRefValid(const FSRef *ref)
{
    char buf[PATH_MAX];
    return _FinchRefPath(ref, buf, sizeof buf) == noErr;
}

/* "dir/name" for a ref's directory and a UTF-16 name. */
static OSErr
child_path(const FSRef *parent, UniCharCount nameLength, const UniChar *name, char *out, size_t size)
{
    char dir[PATH_MAX];
    OSErr e = _FinchRefPath(parent, dir, sizeof dir);
    if (e)
        return e;
    CFStringRef s = CFStringCreateWithCharacters(NULL, name, nameLength);
    char n[NAME_MAX * 4 + 1];
    bool ok = s && CFStringGetFileSystemRepresentation(s, n, sizeof n);
    if (s)
        CFRelease(s);
    if (!ok || !n[0] || strchr(n, '/'))
        return bdNamErr;
    snprintf(out, size, "%s%s%s", dir, strcmp(dir, "/") ? "/" : "", n);
    return noErr;
}

static void
set_name(HFSUniStr255 *out, const char *path)
{
    const char *slash = strrchr(path, '/');
    const char *last = (slash && slash[1]) ? slash + 1 : path;
    if (!strcmp(path, "/"))
        last = "/";
    CFStringRef s = CFStringCreateWithFileSystemRepresentation(NULL, last);
    CFIndex len = s ? CFStringGetLength(s) : 0;
    if (len > 255)
        len = 255;
    out->length = (UInt16)len;
    if (s) {
        CFStringGetCharacters(s, CFRangeMake(0, len), out->unicode);
        CFRelease(s);
    }
}

OSErr
FSMakeFSRefUnicode(const FSRef *parentRef, UniCharCount nameLength, const UniChar *name, TextEncoding textEncodingHint,
                   FSRef *newRef)
{
    char path[PATH_MAX];
    OSErr e = child_path(parentRef, nameLength, name, path, sizeof path);
    return e ? e : _FinchPathRef(path, newRef, NULL, false);
}

#pragma mark - Catalog info

static void
utc(const struct timespec *ts, UTCDateTime *out)
{
    UInt64 s = (UInt64)(ts->tv_sec + FINCH_MAC_EPOCH_DELTA);
    out->highSeconds = (UInt16)(s >> 32);
    out->lowSeconds = (UInt32)s;
    out->fraction = (UInt16)(((UInt64)ts->tv_nsec << 16) / 1000000000ULL);
}

static void
from_utc(const UTCDateTime *in, struct timespec *ts)
{
    UInt64 s = ((UInt64)in->highSeconds << 32) | in->lowSeconds;
    ts->tv_sec = (time_t)((SInt64)s - FINCH_MAC_EPOCH_DELTA);
    ts->tv_nsec = (long)(((UInt64)in->fraction * 1000000000ULL) >> 16);
}

/* Finder info between disk (big-endian) and memory: the field widths of FileInfo/FolderInfo and their extensions. */
static void
swap_finder_info(UInt8 *p, bool directory)
{
    static const int file[] = {4, 4, 2, 2, 2, 2}, folder[] = {2, 2, 2, 2, 2, 2, 2, 2};
    static const int xfile[] = {2, 2, 2, 2, 2, 2, 4}, xfolder[] = {2, 2, 4, 2, 2, 4};
    const int *w = directory ? folder : file;
    int n = directory ? 8 : 6;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < n; i++) {
            if (w[i] == 4) {
                uint32_t v;
                memcpy(&v, p, 4);
                v = CFSwapInt32(v);
                memcpy(p, &v, 4);
            } else {
                uint16_t v;
                memcpy(&v, p, 2);
                v = CFSwapInt16(v);
                memcpy(p, &v, 2);
            }
            p += w[i];
        }
        w = directory ? xfolder : xfile;
        n = directory ? 6 : 7;
    }
}

FINCH_HIDDEN void
_FinchReadFinderInfo(const char *path, bool directory, UInt8 out[32])
{
    memset(out, 0, 32);
    if (getxattr(path, XATTR_FINDERINFO_NAME, out, 32, 0, XATTR_NOFOLLOW) == 32)
        swap_finder_info(out, directory);
}

static int
write_finder_info(const char *path, bool directory, const UInt8 in[32])
{
    UInt8 buf[32];
    memcpy(buf, in, 32);
    swap_finder_info(buf, directory);
    static const UInt8 zero[32];
    if (!memcmp(buf, zero, 32))
        return removexattr(path, XATTR_FINDERINFO_NAME, XATTR_NOFOLLOW) == 0 || errno == ENOATTR ? 0 : -1;
    return setxattr(path, XATTR_FINDERINFO_NAME, buf, 32, 0, XATTR_NOFOLLOW);
}

static FSVolumeRefNum
volume_refnum(const fsid_t *fsid)
{
    static fsid_t seen[64];
    static int n;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);
    int i;
    for (i = 0; i < n; i++)
        if (!memcmp(&seen[i], fsid, sizeof *fsid))
            break;
    if (i == n && n < 64)
        seen[n++] = *fsid;
    pthread_mutex_unlock(&lock);
    return (FSVolumeRefNum)(-100 - i);
}

FINCH_HIDDEN OSErr
_FinchVolumeRefNumForPath(const char *path, FSVolumeRefNum *out)
{
    struct statfs sf;
    if (statfs(path, &sf))
        return _FinchErrnoToOSErr(errno);
    *out = volume_refnum(&sf.f_fsid);
    return noErr;
}

static OSErr
fill_info(const char *path, FSCatalogInfoBitmap which, FSCatalogInfo *info, HFSUniStr255 *outName, FSRef *parentRef)
{
    struct stat st;
    if (lstat(path, &st))
        return _FinchErrnoToOSErr(errno);
    if (S_ISLNK(st.st_mode)) {
        struct stat target;
        if (!stat(path, &target))
            st = target;
    }
    bool dir = S_ISDIR(st.st_mode);
    if (info && which) {
        if (which & kFSCatInfoNodeFlags) {
            info->nodeFlags = (dir ? kFSNodeIsDirectoryMask : 0) | ((st.st_flags & (UF_IMMUTABLE | SF_IMMUTABLE)) ? kFSNodeLockedMask : 0);
        }
        if (which & kFSCatInfoVolume) {
            struct statfs sf;
            info->volume = statfs(path, &sf) ? 0 : volume_refnum(&sf.f_fsid);
        }
        if (which & kFSCatInfoParentDirID) {
            char parent[PATH_MAX];
            strlcpy(parent, path, sizeof parent);
            char *slash = strrchr(parent, '/');
            if (slash == parent)
                slash[1] = 0;
            else if (slash)
                *slash = 0;
            struct stat ps;
            info->parentDirID = (!strcmp(path, "/")) ? 1 : (stat(parent, &ps) ? 0 : (UInt32)ps.st_ino);
        }
        if (which & kFSCatInfoNodeID)
            info->nodeID = (UInt32)st.st_ino;
        if (which & kFSCatInfoSharingFlags)
            info->sharingFlags = 0;
        if (which & kFSCatInfoUserPrivs)
            info->userPrivileges = 0;
        info->reserved1 = info->reserved2 = 0;
        if (which & kFSCatInfoCreateDate)
            utc(&st.st_birthtimespec, &info->createDate);
        if (which & kFSCatInfoContentMod)
            utc(&st.st_mtimespec, &info->contentModDate);
        if (which & kFSCatInfoAttrMod)
            utc(&st.st_ctimespec, &info->attributeModDate);
        if (which & kFSCatInfoAccessDate)
            utc(&st.st_atimespec, &info->accessDate);
        if (which & kFSCatInfoBackupDate)
            memset(&info->backupDate, 0, sizeof info->backupDate);
        if (which & kFSCatInfoPermissions) {
            FSPermissionInfo *p = (FSPermissionInfo *)&info->permissions;
            memset(p, 0, sizeof *p);
            p->userID = st.st_uid;
            p->groupID = st.st_gid;
            p->mode = st.st_mode;
        }
        if (which & (kFSCatInfoFinderInfo | kFSCatInfoFinderXInfo)) {
            UInt8 fi[32];
            _FinchReadFinderInfo(path, dir, fi);
            if (which & kFSCatInfoFinderInfo)
                memcpy(info->finderInfo, fi, 16);
            if (which & kFSCatInfoFinderXInfo)
                memcpy(info->extFinderInfo, fi + 16, 16);
        }
        if (which & kFSCatInfoDataSizes) {
            info->dataLogicalSize = dir ? 0 : (UInt64)st.st_size;
            info->dataPhysicalSize = dir ? 0 : (UInt64)st.st_blocks * 512;
        }
        if (which & kFSCatInfoRsrcSizes) {
            ssize_t n = dir ? -1 : getxattr(path, XATTR_RESOURCEFORK_NAME, NULL, 0, 0, 0);
            info->rsrcLogicalSize = n > 0 ? (UInt64)n : 0;
            info->rsrcPhysicalSize = n > 0 ? (((UInt64)n + 4095) & ~4095ULL) : 0;
        }
        if (which & kFSCatInfoValence) {
            info->valence = 0;
            DIR *d = dir ? opendir(path) : NULL;
            if (d) {
                struct dirent *de;
                while ((de = readdir(d)))
                    if (strcmp(de->d_name, ".") && strcmp(de->d_name, ".."))
                        info->valence++;
                closedir(d);
            }
        }
        if (which & kFSCatInfoTextEncoding)
            info->textEncodingHint = kTextEncodingMacUnicode;
    }
    if (outName)
        set_name(outName, path);
    if (parentRef) {
        char parent[PATH_MAX];
        strlcpy(parent, path, sizeof parent);
        char *slash = strrchr(parent, '/');
        if (slash == parent)
            slash[1] = 0;
        else if (slash)
            *slash = 0;
        OSErr e = _FinchPathRef(parent, parentRef, NULL, true);
        if (e)
            return e;
    }
    return noErr;
}

/* FSSpec as the 68K laid it out (the 64-bit SDK hides it). */
struct spec {
    SInt16 vRefNum;
    SInt32 parID;
    unsigned char name[64];
} __attribute__((packed, aligned(2)));
_Static_assert(sizeof(struct spec) == sizeof(FSSpec), "FSSpec layout");

static void
fill_spec(const char *path, FSSpecPtr fsspec)
{
    if (!fsspec)
        return;
    struct spec *spec = (struct spec *)fsspec;
    memset(spec, 0, sizeof *spec);
    struct statfs sf;
    if (!statfs(path, &sf))
        spec->vRefNum = volume_refnum(&sf.f_fsid);
    char parent[PATH_MAX];
    strlcpy(parent, path, sizeof parent);
    char *slash = strrchr(parent, '/');
    const char *name = slash ? slash + 1 : path;
    if (slash == parent)
        slash[1] = 0;
    else if (slash)
        *slash = 0;
    struct stat ps;
    if (!stat(parent, &ps))
        spec->parID = (SInt32)ps.st_ino;
    CFStringRef s = CFStringCreateWithFileSystemRepresentation(NULL, name);
    if (s) {
        CFStringGetPascalString(s, spec->name, 64, kCFStringEncodingMacRoman);
        CFRelease(s);
    }
}

OSErr
FSGetCatalogInfo(const FSRef *ref, FSCatalogInfoBitmap whichInfo, FSCatalogInfo *catalogInfo, HFSUniStr255 *outName,
                 FSSpecPtr fsSpec, FSRef *parentRef)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(ref, path, sizeof path);
    if (e)
        return e;
    fill_spec(path, fsSpec);
    return fill_info(path, whichInfo, catalogInfo, outName, parentRef);
}

static OSErr
apply_info(const char *path, FSCatalogInfoBitmap which, const FSCatalogInfo *info)
{
    if (!info || !which)
        return noErr;
    struct stat st;
    if (lstat(path, &st))
        return _FinchErrnoToOSErr(errno);
    bool dir = S_ISDIR(st.st_mode);
    if (which & (kFSCatInfoFinderInfo | kFSCatInfoFinderXInfo)) {
        UInt8 fi[32];
        _FinchReadFinderInfo(path, dir, fi);
        if (which & kFSCatInfoFinderInfo)
            memcpy(fi, info->finderInfo, 16);
        if (which & kFSCatInfoFinderXInfo)
            memcpy(fi + 16, info->extFinderInfo, 16);
        if (write_finder_info(path, dir, fi))
            return _FinchErrnoToOSErr(errno);
    }
    if (which & kFSCatInfoPermissions) {
        const FSPermissionInfo *p = (const FSPermissionInfo *)&info->permissions;
        if ((p->mode & 07777) != (st.st_mode & 07777) && chmod(path, p->mode & 07777))
            return _FinchErrnoToOSErr(errno);
        if ((p->userID != st.st_uid || p->groupID != st.st_gid) && chown(path, p->userID, p->groupID))
            return _FinchErrnoToOSErr(errno);
    }
    if (which & (kFSCatInfoContentMod | kFSCatInfoAccessDate)) {
        struct timespec ts[2] = {st.st_atimespec, st.st_mtimespec};
        if (which & kFSCatInfoAccessDate)
            from_utc(&info->accessDate, &ts[0]);
        if (which & kFSCatInfoContentMod)
            from_utc(&info->contentModDate, &ts[1]);
        if (utimensat(AT_FDCWD, path, ts, AT_SYMLINK_NOFOLLOW))
            return _FinchErrnoToOSErr(errno);
    }
    if (which & kFSCatInfoCreateDate) {
        struct attrlist al = {.bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = ATTR_CMN_CRTIME};
        struct timespec ts;
        from_utc(&info->createDate, &ts);
        if (setattrlist(path, &al, &ts, sizeof ts, FSOPT_NOFOLLOW))
            return _FinchErrnoToOSErr(errno);
    }
    if (which & kFSCatInfoNodeFlags) {
        bool lock = info->nodeFlags & kFSNodeLockedMask;
        bool locked = st.st_flags & UF_IMMUTABLE;
        if (lock != locked && chflags(path, lock ? (st.st_flags | UF_IMMUTABLE) : (st.st_flags & ~UF_IMMUTABLE)))
            return _FinchErrnoToOSErr(errno);
    }
    return noErr;
}

OSErr
FSSetCatalogInfo(const FSRef *ref, FSCatalogInfoBitmap whichInfo, const FSCatalogInfo *catalogInfo)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(ref, path, sizeof path);
    return e ? e : apply_info(path, whichInfo, catalogInfo);
}

#pragma mark - Creating, deleting, moving

OSErr
FSCreateFileUnicode(const FSRef *parentRef, UniCharCount nameLength, const UniChar *name, FSCatalogInfoBitmap whichInfo,
                    const FSCatalogInfo *catalogInfo, FSRef *newRef, FSSpecPtr newSpec)
{
    char path[PATH_MAX];
    OSErr e = child_path(parentRef, nameLength, name, path, sizeof path);
    if (e)
        return e;
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd < 0)
        return _FinchErrnoToOSErr(errno);
    close(fd);
    if ((e = apply_info(path, whichInfo, catalogInfo)))
        return e;
    fill_spec(path, newSpec);
    return newRef ? _FinchPathRef(path, newRef, NULL, false) : noErr;
}

OSErr
FSCreateDirectoryUnicode(const FSRef *parentRef, UniCharCount nameLength, const UniChar *name,
                         FSCatalogInfoBitmap whichInfo, const FSCatalogInfo *catalogInfo, FSRef *newRef,
                         FSSpecPtr newSpec, UInt32 *newDirID)
{
    char path[PATH_MAX];
    OSErr e = child_path(parentRef, nameLength, name, path, sizeof path);
    if (e)
        return e;
    if (mkdir(path, 0755))
        return _FinchErrnoToOSErr(errno);
    if ((e = apply_info(path, whichInfo, catalogInfo)))
        return e;
    fill_spec(path, newSpec);
    if (newDirID) {
        struct stat st;
        *newDirID = stat(path, &st) ? 0 : (UInt32)st.st_ino;
    }
    return newRef ? _FinchPathRef(path, newRef, NULL, false) : noErr;
}

OSErr
FSDeleteObject(const FSRef *ref)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(ref, path, sizeof path);
    if (e)
        return e;
    struct stat st;
    if (lstat(path, &st))
        return _FinchErrnoToOSErr(errno);
    if (S_ISDIR(st.st_mode) ? rmdir(path) : unlink(path))
        return _FinchErrnoToOSErr(errno);
    return noErr;
}

OSErr
FSUnlinkObject(const FSRef *ref)
{
    return FSDeleteObject(ref);
}

OSErr
FSMoveObject(const FSRef *ref, const FSRef *destDirectory, FSRef *newRef)
{
    char from[PATH_MAX], dir[PATH_MAX], to[PATH_MAX];
    OSErr e = _FinchRefPath(ref, from, sizeof from);
    if (e || (e = _FinchRefPath(destDirectory, dir, sizeof dir)))
        return e;
    const char *slash = strrchr(from, '/');
    snprintf(to, sizeof to, "%s/%s", dir, slash ? slash + 1 : from);
    if (!access(to, F_OK))
        return dupFNErr;
    if (rename(from, to))
        return _FinchErrnoToOSErr(errno);
    FSRef moved;
    return _FinchPathRef(to, newRef ? newRef : &moved, NULL, false);
}

OSErr
FSRenameUnicode(const FSRef *ref, UniCharCount nameLength, const UniChar *name, TextEncoding textEncodingHint,
                FSRef *newRef)
{
    char from[PATH_MAX], to[PATH_MAX], parent[PATH_MAX];
    OSErr e = _FinchRefPath(ref, from, sizeof from);
    if (e)
        return e;
    strlcpy(parent, from, sizeof parent);
    char *slash = strrchr(parent, '/');
    if (slash == parent)
        slash[1] = 0;
    else if (slash)
        *slash = 0;
    FSRef pref;
    if ((e = _FinchPathRef(parent, &pref, NULL, true)) || (e = child_path(&pref, nameLength, name, to, sizeof to)))
        return e;
    if (strcasecmp(from, to) && !access(to, F_OK))
        return dupFNErr;
    if (rename(from, to))
        return _FinchErrnoToOSErr(errno);
    FSRef renamed;
    return _FinchPathRef(to, newRef ? newRef : &renamed, NULL, false);
}

OSErr
FSExchangeObjects(const FSRef *ref, const FSRef *destRef)
{
    char a[PATH_MAX], b[PATH_MAX];
    OSErr e = _FinchRefPath(ref, a, sizeof a);
    if (e || (e = _FinchRefPath(destRef, b, sizeof b)))
        return e;
    if (renamex_np(a, b, RENAME_SWAP))
        return _FinchErrnoToOSErr(errno);
    return noErr;
}

#pragma mark - Forks

static HFSUniStr255 data_fork = {0, {0}};
static HFSUniStr255 rsrc_fork = {13, {'R', 'E', 'S', 'O', 'U', 'R', 'C', 'E', '_', 'F', 'O', 'R', 'K'}};

OSErr
FSGetDataForkName(HFSUniStr255 *dataForkName)
{
    if (dataForkName)
        *dataForkName = data_fork;
    return noErr;
}

OSErr
FSGetResourceForkName(HFSUniStr255 *resourceForkName)
{
    if (resourceForkName)
        *resourceForkName = rsrc_fork;
    return noErr;
}

/* 0 data fork, 1 resource fork, -1 another named fork (not supported). */
FINCH_HIDDEN int
_FinchForkKind(UniCharCount forkNameLength, const UniChar *forkName)
{
    if (!forkNameLength)
        return 0;
    if (forkNameLength == rsrc_fork.length && !memcmp(forkName, rsrc_fork.unicode, forkNameLength * sizeof(UniChar)))
        return 1;
    return -1;
}

#define MAX_FORKS 256
#define FORK_BASE 3000
static struct fork {
    int fd;
    SInt64 mark;
    FSRef ref;
    int kind;
} forks[MAX_FORKS];
static pthread_mutex_t forks_lock = PTHREAD_MUTEX_INITIALIZER;

static struct fork *
fork_of(FSIORefNum refNum)
{
    int i = refNum - FORK_BASE;
    return (i >= 0 && i < MAX_FORKS && forks[i].fd > 0) ? &forks[i] : NULL;
}

OSErr
FSOpenFork(const FSRef *ref, UniCharCount forkNameLength, const UniChar *forkName, SInt8 permissions,
           FSIORefNum *forkRefNum)
{
    char path[PATH_MAX], fpath[PATH_MAX + 32];
    OSErr e = _FinchRefPath(ref, path, sizeof path);
    if (e)
        return e;
    int kind = _FinchForkKind(forkNameLength, forkName);
    if (kind < 0)
        return errFSForkNotFound;
    bool write = (permissions & 3) == fsWrPerm || (permissions & 3) == fsRdWrPerm || permissions == fsCurPerm ||
                 (permissions & 3) == fsRdWrShPerm;
    if (kind == 1) {
        snprintf(fpath, sizeof fpath, "%s/..namedfork/rsrc", path);
        if (!write && getxattr(path, XATTR_RESOURCEFORK_NAME, NULL, 0, 0, 0) <= 0)
            return eofErr;
    } else {
        strlcpy(fpath, path, sizeof fpath);
    }
    int fd = open(fpath, (write ? O_RDWR : O_RDONLY) | (kind == 1 && write ? O_CREAT : 0), 0644);
    if (fd < 0 && write && permissions == fsCurPerm)
        fd = open(fpath, O_RDONLY);
    if (fd < 0)
        return _FinchErrnoToOSErr(errno);
    pthread_mutex_lock(&forks_lock);
    int i;
    for (i = 0; i < MAX_FORKS && forks[i].fd > 0; i++)
        ;
    if (i == MAX_FORKS) {
        pthread_mutex_unlock(&forks_lock);
        close(fd);
        return tmfoErr;
    }
    forks[i] = (struct fork){fd, 0, *ref, kind};
    pthread_mutex_unlock(&forks_lock);
    if (forkRefNum)
        *forkRefNum = (FSIORefNum)(FORK_BASE + i);
    return noErr;
}

OSErr
FSCloseFork(FSIORefNum forkRefNum)
{
    pthread_mutex_lock(&forks_lock);
    struct fork *f = fork_of(forkRefNum);
    int fd = f ? f->fd : -1;
    if (f)
        f->fd = 0;
    pthread_mutex_unlock(&forks_lock);
    if (!f)
        return fnOpnErr;
    close(fd);
    return noErr;
}

static OSErr
position(struct fork *f, UInt16 mode, SInt64 offset, SInt64 *out)
{
    struct stat st;
    switch (mode & 3) {
    case fsAtMark: *out = f->mark; break;
    case fsFromStart: *out = offset; break;
    case fsFromLEOF:
        if (fstat(f->fd, &st))
            return _FinchErrnoToOSErr(errno);
        *out = st.st_size + offset;
        break;
    case fsFromMark: *out = f->mark + offset; break;
    }
    return *out < 0 ? posErr : noErr;
}

OSErr
FSReadFork(FSIORefNum forkRefNum, UInt16 positionMode, SInt64 positionOffset, ByteCount requestCount, void *buffer,
           ByteCount *actualCount)
{
    struct fork *f = fork_of(forkRefNum);
    if (actualCount)
        *actualCount = 0;
    if (!f)
        return rfNumErr;
    SInt64 at;
    OSErr e = position(f, positionMode, positionOffset, &at);
    if (e)
        return e;
    ssize_t n = pread(f->fd, buffer, requestCount, at);
    if (n < 0)
        return _FinchErrnoToOSErr(errno);
    f->mark = at + n;
    if (actualCount)
        *actualCount = n;
    return (ByteCount)n < requestCount ? eofErr : noErr;
}

OSErr
FSWriteFork(FSIORefNum forkRefNum, UInt16 positionMode, SInt64 positionOffset, ByteCount requestCount,
            const void *buffer, ByteCount *actualCount)
{
    struct fork *f = fork_of(forkRefNum);
    if (actualCount)
        *actualCount = 0;
    if (!f)
        return rfNumErr;
    SInt64 at;
    OSErr e = position(f, positionMode, positionOffset, &at);
    if (e)
        return e;
    ssize_t n = pwrite(f->fd, buffer, requestCount, at);
    if (n < 0)
        return errno == EBADF ? wrPermErr : _FinchErrnoToOSErr(errno);
    f->mark = at + n;
    if (actualCount)
        *actualCount = n;
    return noErr;
}

OSErr
FSGetForkPosition(FSIORefNum forkRefNum, SInt64 *position)
{
    struct fork *f = fork_of(forkRefNum);
    if (!f)
        return rfNumErr;
    *position = f->mark;
    return noErr;
}

OSErr
FSSetForkPosition(FSIORefNum forkRefNum, UInt16 positionMode, SInt64 positionOffset)
{
    struct fork *f = fork_of(forkRefNum);
    if (!f)
        return rfNumErr;
    SInt64 at;
    OSErr e = position(f, positionMode, positionOffset, &at);
    if (!e)
        f->mark = at;
    return e;
}

OSErr
FSGetForkSize(FSIORefNum forkRefNum, SInt64 *forkSize)
{
    struct fork *f = fork_of(forkRefNum);
    struct stat st;
    if (!f)
        return rfNumErr;
    if (fstat(f->fd, &st))
        return _FinchErrnoToOSErr(errno);
    *forkSize = st.st_size;
    return noErr;
}

OSErr
FSSetForkSize(FSIORefNum forkRefNum, UInt16 positionMode, SInt64 positionOffset)
{
    struct fork *f = fork_of(forkRefNum);
    if (!f)
        return rfNumErr;
    SInt64 at;
    OSErr e = position(f, positionMode, positionOffset, &at);
    if (e)
        return e;
    if (ftruncate(f->fd, at))
        return _FinchErrnoToOSErr(errno);
    if (f->mark > at)
        f->mark = at;
    return noErr;
}

OSErr
FSAllocateFork(FSIORefNum forkRefNum, FSAllocationFlags flags, UInt16 positionMode, SInt64 positionOffset,
               UInt64 requestCount, UInt64 *actualCount)
{
    if (!fork_of(forkRefNum))
        return rfNumErr;
    if (actualCount)
        *actualCount = requestCount;
    return noErr;
}

OSErr
FSFlushFork(FSIORefNum forkRefNum)
{
    struct fork *f = fork_of(forkRefNum);
    if (!f)
        return rfNumErr;
    fsync(f->fd);
    return noErr;
}

OSErr
FSCreateFork(const FSRef *ref, UniCharCount forkNameLength, const UniChar *forkName)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(ref, path, sizeof path);
    if (e)
        return e;
    int kind = _FinchForkKind(forkNameLength, forkName);
    if (kind == 0)
        return errFSForkExists;
    if (kind < 0)
        return errFSForkNotFound;
    if (getxattr(path, XATTR_RESOURCEFORK_NAME, NULL, 0, 0, 0) >= 0)
        return errFSForkExists;
    return setxattr(path, XATTR_RESOURCEFORK_NAME, "", 0, 0, 0) ? _FinchErrnoToOSErr(errno) : noErr;
}

OSErr
FSDeleteFork(const FSRef *ref, UniCharCount forkNameLength, const UniChar *forkName)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(ref, path, sizeof path);
    if (e)
        return e;
    int kind = _FinchForkKind(forkNameLength, forkName);
    if (kind == 0)
        return truncate(path, 0) ? _FinchErrnoToOSErr(errno) : noErr;
    if (kind < 0)
        return errFSForkNotFound;
    return removexattr(path, XATTR_RESOURCEFORK_NAME, 0) ? errFSForkNotFound : noErr;
}

#pragma mark - Iterating

struct iterator {
    DIR *dir;
    char path[PATH_MAX];
};

OSErr
FSOpenIterator(const FSRef *container, FSIteratorFlags iteratorFlags, FSIterator *iterator)
{
    if (iteratorFlags & kFSIterateSubtree)
        return paramErr;  /* subtree iteration was never supported for bulk info either */
    struct iterator *it = calloc(1, sizeof *it);
    OSErr e = _FinchRefPath(container, it->path, sizeof it->path);
    if (!e && !(it->dir = opendir(it->path)))
        e = _FinchErrnoToOSErr(errno);
    if (e) {
        free(it);
        return e;
    }
    *iterator = (FSIterator)it;
    return noErr;
}

OSErr
FSCloseIterator(FSIterator iterator)
{
    struct iterator *it = (struct iterator *)iterator;
    if (!it)
        return paramErr;
    closedir(it->dir);
    free(it);
    return noErr;
}

OSErr
FSGetCatalogInfoBulk(FSIterator iterator, ItemCount maximumObjects, ItemCount *actualObjects, Boolean *containerChanged,
                     FSCatalogInfoBitmap whichInfo, FSCatalogInfo *catalogInfos, FSRef *refs, FSSpecPtr specs,
                     HFSUniStr255 *names)
{
    struct iterator *it = (struct iterator *)iterator;
    if (!it)
        return paramErr;
    if (containerChanged)
        *containerChanged = false;
    ItemCount n = 0;
    struct dirent *de = NULL;
    while (n < maximumObjects && (de = readdir(it->dir))) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
            continue;
        char path[PATH_MAX];
        snprintf(path, sizeof path, "%s%s%s", it->path, strcmp(it->path, "/") ? "/" : "", de->d_name);
        if (fill_info(path, whichInfo, catalogInfos ? &catalogInfos[n] : NULL, names ? &names[n] : NULL, NULL))
            continue;
        if (refs)
            _FinchPathRef(path, &refs[n], NULL, false);
        if (specs)
            fill_spec(path, &specs[n]);
        n++;
    }
    if (actualObjects)
        *actualObjects = n;
    return (n < maximumObjects) ? errFSNoMoreItems : noErr;
}

#pragma mark - Volumes

OSErr
FSGetVolumeInfo(FSVolumeRefNum volume, ItemCount volumeIndex, FSVolumeRefNum *actualVolume, FSVolumeInfoBitmap whichInfo,
                FSVolumeInfo *info, HFSUniStr255 *volumeName, FSRef *rootDirectory)
{
    struct statfs *mounts;
    int n = getmntinfo(&mounts, MNT_NOWAIT);
    struct statfs *m = NULL;
    if (volumeIndex > 0) {
        /* only local, browsable volumes are counted, as the Carbon File Manager does */
        ItemCount k = 0;
        for (int i = 0; i < n && !m; i++)
            if ((mounts[i].f_flags & MNT_LOCAL) && !(mounts[i].f_flags & MNT_DONTBROWSE) && ++k == volumeIndex)
                m = &mounts[i];
        if (!m)
            return nsvErr;
    } else {
        for (int i = 0; i < n && !m; i++)
            if (volume_refnum(&mounts[i].f_fsid) == volume)
                m = &mounts[i];
        if (!m)
            return nsvErr;
    }
    if (actualVolume)
        *actualVolume = volume_refnum(&m->f_fsid);
    if (info && whichInfo) {
        memset(info, 0, sizeof *info);
        info->blockSize = (UInt32)m->f_bsize;
        info->totalBlocks = (UInt32)MIN(m->f_blocks, 0xffffffffULL);
        info->freeBlocks = (UInt32)MIN(m->f_bavail, 0xffffffffULL);
        info->totalBytes = m->f_blocks * m->f_bsize;
        info->freeBytes = m->f_bavail * m->f_bsize;
        info->fileCount = (UInt32)MIN(m->f_files - m->f_ffree, 0xffffffffULL);
        info->filesystemID = 0;
        info->signature = !strcmp(m->f_fstypename, "hfs") ? kHFSPlusSigWord : 0x4244;
        info->flags = (m->f_flags & MNT_RDONLY) ? kFSVolFlagSoftwareLockedMask : 0;
        info->driveNumber = 0;
        info->driverRefNum = 0;
    }
    if (volumeName) {
        CFStringRef s = NULL;
        if (!strcmp(m->f_mntonname, "/")) {
            /* the boot volume's name is the root directory's display name */
            s = CFSTR("Macintosh HD");
            CFRetain(s);
        } else {
            const char *slash = strrchr(m->f_mntonname, '/');
            s = CFStringCreateWithFileSystemRepresentation(NULL, slash ? slash + 1 : m->f_mntonname);
        }
        CFIndex len = s ? MIN(CFStringGetLength(s), 255) : 0;
        volumeName->length = (UInt16)len;
        if (s) {
            CFStringGetCharacters(s, CFRangeMake(0, len), volumeName->unicode);
            CFRelease(s);
        }
    }
    if (rootDirectory)
        return _FinchPathRef(m->f_mntonname, rootDirectory, NULL, true);
    return noErr;
}

OSStatus
FSUnmountVolumeSync(FSVolumeRefNum vRefNum, OptionBits flags, pid_t *dissenter)
{
    if (dissenter)
        *dissenter = 0;
    struct statfs *mounts;
    int n = getmntinfo(&mounts, MNT_NOWAIT);
    for (int i = 0; i < n; i++)
        if (volume_refnum(&mounts[i].f_fsid) == vRefNum)
            return unmount(mounts[i].f_mntonname, 0)
                       ? _FinchErrnoToOSErr(errno)
                       : noErr;
    return nsvErr;
}

OSStatus
FSEjectVolumeSync(FSVolumeRefNum vRefNum, OptionBits flags, pid_t *dissenter)
{
    return FSUnmountVolumeSync(vRefNum, flags, dissenter);
}

OSStatus
FSCopyURLForVolume(FSVolumeRefNum vRefNum, CFURLRef *url)
{
    struct statfs *mounts;
    int n = getmntinfo(&mounts, MNT_NOWAIT);
    for (int i = 0; i < n; i++)
        if (volume_refnum(&mounts[i].f_fsid) == vRefNum) {
            *url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)mounts[i].f_mntonname,
                                                           strlen(mounts[i].f_mntonname), true);
            return noErr;
        }
    return nsvErr;
}

#pragma mark - Folders

static const char *
home(void)
{
    const char *h = getenv("HOME");
    if (h && *h)
        return h;
    struct passwd *pw = getpwuid(getuid());
    return pw ? pw->pw_dir : "/";
}

/* Where a folder type lives under a domain's Library (or, for some, the domain's top). */
static const struct {
    OSType type;
    const char *user, *local, *system;
} folders[] = {
    {kDomainLibraryFolderType, "Library", "/Library", "/System/Library"},
    {kPreferencesFolderType, "Library/Preferences", "/Library/Preferences", "/System/Library/Preferences"},
    {kApplicationSupportFolderType, "Library/Application Support", "/Library/Application Support", "/System/Library/Application Support"},
    {kCachedDataFolderType, "Library/Caches", "/Library/Caches", "/System/Library/Caches"},
    {kFontsFolderType, "Library/Fonts", "/Library/Fonts", "/System/Library/Fonts"},
    {kDesktopFolderType, "Desktop", NULL, NULL},
    {kDocumentsFolderType, "Documents", NULL, NULL},
    {kDownloadsFolderType, "Downloads", NULL, NULL},
    {kMovieDocumentsFolderType, "Movies", NULL, NULL},
    {kMusicDocumentsFolderType, "Music", NULL, NULL},
    {kPictureDocumentsFolderType, "Pictures", NULL, NULL},
    {kPublicFolderType, "Public", NULL, NULL},
    {kCurrentUserFolderType, "", NULL, NULL},
    {kApplicationsFolderType, "Applications", "/Applications", "/Applications"},
    {kTrashFolderType, ".Trash", NULL, NULL},
    {kLogsFolderType, "Library/Logs", "/Library/Logs", "/System/Library/Logs"},
    {kFrameworksFolderType, "Library/Frameworks", "/Library/Frameworks", "/System/Library/Frameworks"},
    {kPreferencePanesFolderType, "Library/PreferencePanes", "/Library/PreferencePanes", "/System/Library/PreferencePanes"},
    {kInternetPlugInFolderType, "Library/Internet Plug-Ins", "/Library/Internet Plug-Ins", "/System/Library/Internet Plug-Ins"},
    {kAudioComponentsFolderType, "Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/Components", "/System/Library/Components"},
    {kColorSyncProfilesFolderType, "Library/ColorSync/Profiles", "/Library/ColorSync/Profiles", "/System/Library/ColorSync/Profiles"},
    {kKeyboardLayoutsFolderType, "Library/Keyboard Layouts", "/Library/Keyboard Layouts", "/System/Library/Keyboard Layouts"},
    {kScriptsFolderType, "Library/Scripts", "/Library/Scripts", "/System/Library/Scripts"},
    {kServicesFolderType, "Library/Services", "/Library/Services", "/System/Library/Services"},
    {kSharedUserDataFolderType, NULL, "/Users/Shared", "/Users/Shared"},
    {kUsersFolderType, NULL, "/Users", "/Users"},
    {kSystemFolderType, NULL, "/System", "/System"},
    {kCoreServicesFolderType, NULL, "/System/Library/CoreServices", "/System/Library/CoreServices"},
    {kUtilitiesFolderType, "Applications/Utilities", "/Applications/Utilities", "/Applications/Utilities"},
};

OSErr
FSFindFolder(FSVolumeRefNum vRefNum, OSType folderType, Boolean createFolder, FSRef *foundRef)
{
    short domain = vRefNum;
    if (domain == kOnAppropriateDisk || domain == kOnSystemDisk || domain >= 0)
        domain = (folderType == kTemporaryFolderType || folderType == kChewableItemsFolderType) ? kUserDomain : kSystemDomain;
    char path[PATH_MAX] = {0};
    if (folderType == kTemporaryFolderType || folderType == kChewableItemsFolderType ||
        folderType == kTemporaryItemsInCacheDataFolderType) {
        char tmp[PATH_MAX];
        size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, tmp, sizeof tmp);
        snprintf(path, sizeof path, "%s%sTemporaryItems", n ? tmp : "/tmp/", n && tmp[n - 2] == '/' ? "" : (n ? "/" : ""));
    } else {
        for (size_t i = 0; i < sizeof folders / sizeof *folders; i++) {
            if (folders[i].type != folderType)
                continue;
            const char *p = domain == kUserDomain ? folders[i].user : domain == kLocalDomain ? folders[i].local
                                                                    : domain == kSystemDomain ? folders[i].system
                                                                                              : NULL;
            if (!p)
                return fnfErr;
            if (domain == kUserDomain)
                snprintf(path, sizeof path, "%s%s%s", home(), *p ? "/" : "", p);
            else
                strlcpy(path, p, sizeof path);
            break;
        }
        if (!path[0])
            return fnfErr;
    }
    struct stat st;
    if (stat(path, &st)) {
        if (!createFolder)
            return fnfErr;
        char partial[PATH_MAX];
        for (char *s = path + 1; ; s++) {
            if (*s == '/' || !*s) {
                strlcpy(partial, path, s - path + 1);
                mkdir(partial, 0755);
                if (!*s)
                    break;
            }
        }
    }
    return _FinchPathRef(path, foundRef, NULL, true);
}

OSErr
FSFindFolderExtended(FSVolumeRefNum vRefNum, OSType folderType, Boolean createFolder, UInt32 flags, void *data,
                     FSRef *foundRef)
{
    return FSFindFolder(vRefNum, folderType, createFolder, foundRef);
}

#pragma mark - Change notification (in-process)

struct subscription {
    char path[PATH_MAX];
    FNSubscriptionProcPtr proc;
    void *refcon;
};

OSStatus
FNNotify(const FSRef *ref, FNMessage message, OptionBits flags)
{
    char path[PATH_MAX];
    return _FinchRefPath(ref, path, sizeof path) ? fnfErr : noErr;
}

OSStatus
FNNotifyByPath(const UInt8 *path, FNMessage message, OptionBits flags)
{
    return path ? noErr : paramErr;
}

OSStatus
FNNotifyAll(FNMessage message, OptionBits flags)
{
    return noErr;
}

OSStatus
FNSubscribe(const FSRef *directoryRef, FNSubscriptionUPP callback, void *refcon, OptionBits flags,
            FNSubscriptionRef *subscription)
{
    struct subscription *s = calloc(1, sizeof *s);
    OSErr e = _FinchRefPath(directoryRef, s->path, sizeof s->path);
    if (e) {
        free(s);
        return e;
    }
    s->proc = callback;
    s->refcon = refcon;
    *subscription = (FNSubscriptionRef)s;
    return noErr;
}

OSStatus
FNSubscribeByPath(const UInt8 *directoryPath, FNSubscriptionUPP callback, void *refcon, OptionBits flags,
                  FNSubscriptionRef *subscription)
{
    FSRef ref;
    OSErr e = FSPathMakeRef(directoryPath, &ref, NULL);
    return e ? e : FNSubscribe(&ref, callback, refcon, flags, subscription);
}

OSStatus
FNUnsubscribe(FNSubscriptionRef subscription)
{
    free(subscription);
    return noErr;
}

OSStatus
FNGetDirectoryForSubscription(FNSubscriptionRef subscription, FSRef *ref)
{
    struct subscription *s = (struct subscription *)subscription;
    return s ? FSPathMakeRef((const UInt8 *)s->path, ref, NULL) : paramErr;
}

FNSubscriptionUPP (NewFNSubscriptionUPP)(FNSubscriptionProcPtr userRoutine) { return userRoutine; }
void (DisposeFNSubscriptionUPP)(FNSubscriptionUPP userUPP) {}
void (InvokeFNSubscriptionUPP)(FNMessage message, OptionBits flags, void *refcon, FNSubscriptionRef subscription,
                             FNSubscriptionUPP userUPP)
{
    userUPP(message, flags, refcon, subscription);
}
