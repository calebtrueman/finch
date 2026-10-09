/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Resource Manager (Resources.h) over resource files in either fork.
 * A file is read whole when it's opened (the documented format: a header
 * giving the data and map, the map's type list, reference lists and name
 * list) and written whole when it changed and is updated or closed. Open
 * files form a chain, the most recently opened on top; GetResource
 * searches down from the current file, Get1Resource only the current one.
 * A resource's handle stays the same while it's loaded; closing the file
 * disposes of it unless it was detached.
 */
#include "CarbonCore_Finch.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

FINCH_HIDDEN OSErr _FinchRefPath(const FSRef *ref, char *out, size_t size);
FINCH_HIDDEN OSErr _FinchPathRef(const char *path, FSRef *ref, Boolean *isDirectory, bool follow);
FINCH_HIDDEN OSErr _FinchErrnoToOSErr(int e);
FINCH_HIDDEN int _FinchForkKind(UniCharCount forkNameLength, const UniChar *forkName);

struct res {
    ResType type;
    ResID id;
    unsigned char name[256];  /* Pascal string; name[0] == 0: none */
    bool named;
    UInt8 attrs;
    unsigned char *data;
    Size size;
    Handle h;
};

struct rfile {
    ResFileRefNum ref;
    char path[PATH_MAX];
    int fork;  /* 0 data, 1 resource */
    bool writable, dirty;
    ResFileAttributes attrs;
    struct res *v;
    long n;
    ResType *types;  /* in file order */
    long ntypes;
    struct rfile *next;  /* opened before this one */
};

static struct rfile *top;
static ResFileRefNum current;
static ResFileRefNum next_ref = 4000;
static __thread OSErr res_err;
static Boolean res_load = 0xff;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

OSErr ResError(void) { return res_err; }
Boolean LMGetResLoad(void) { return res_load; }
void LMSetResLoad(Boolean value) { res_load = value ? 0xff : 0; }
void SetResLoad(Boolean load) { LMSetResLoad(load); }
SInt16 LMGetResErr(void) { return res_err; }
void LMSetResErr(SInt16 value) { res_err = value; }

static uint32_t
be32(const unsigned char *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static uint16_t
be16(const unsigned char *p)
{
    return (uint16_t)(p[0] << 8 | p[1]);
}

static struct rfile *
file_of(ResFileRefNum ref)
{
    for (struct rfile *f = top; f; f = f->next)
        if (f->ref == ref)
            return f;
    return NULL;
}

static struct res *
res_of(Handle h, struct rfile **file)
{
    if (!h)
        return NULL;
    for (struct rfile *f = top; f; f = f->next)
        for (long i = 0; i < f->n; i++)
            if (f->v[i].h == h) {
                if (file)
                    *file = f;
                return &f->v[i];
            }
    return NULL;
}

static void
add_type(struct rfile *f, ResType t)
{
    for (long i = 0; i < f->ntypes; i++)
        if (f->types[i] == t)
            return;
    f->types = realloc(f->types, (f->ntypes + 1) * sizeof *f->types);
    f->types[f->ntypes++] = t;
}

static OSErr
parse(struct rfile *f, const unsigned char *p, size_t size)
{
    if (size < 16)
        return eofErr;
    uint32_t dataOff = be32(p), mapOff = be32(p + 4), dataLen = be32(p + 8), mapLen = be32(p + 12);
    if ((uint64_t)dataOff + dataLen > size || (uint64_t)mapOff + mapLen > size || mapLen < 30)
        return mapReadErr;
    const unsigned char *map = p + mapOff;
    f->attrs = be16(map + 22);
    uint16_t typeListOff = be16(map + 24), nameListOff = be16(map + 26);
    if (typeListOff + 2u > mapLen)
        return mapReadErr;
    const unsigned char *tl = map + typeListOff;
    int ntypes = (uint16_t)(be16(tl) + 1);
    for (int i = 0; i < ntypes; i++) {
        if (typeListOff + 2u + 8u * (i + 1) > mapLen)
            return mapReadErr;
        const unsigned char *te = tl + 2 + 8 * i;
        ResType type = be32(te);
        int count = be16(te + 4) + 1;
        add_type(f, type);
        for (int j = 0; j < count; j++) {
            size_t at = typeListOff + be16(te + 6) + 12u * j;
            if (at + 12 > mapLen)
                return mapReadErr;
            const unsigned char *r = map + at;
            struct res x = {.type = type, .id = (ResID)be16(r), .attrs = r[4]};
            uint16_t nameOff = be16(r + 2);
            uint32_t off = be32(r + 4) & 0xffffff;
            if (nameOff != 0xffff && nameListOff + nameOff < mapLen) {
                const unsigned char *nm = map + nameListOff + nameOff;
                if (nameListOff + nameOff + 1u + nm[0] <= mapLen) {
                    memcpy(x.name, nm, 1 + nm[0]);
                    x.named = true;
                }
            }
            if ((uint64_t)dataOff + off + 4 > size)
                return mapReadErr;
            x.size = be32(p + dataOff + off);
            if ((uint64_t)dataOff + off + 4 + x.size > size)
                return mapReadErr;
            x.data = malloc(x.size ? x.size : 1);
            memcpy(x.data, p + dataOff + off + 4, x.size);
            f->v = realloc(f->v, (f->n + 1) * sizeof *f->v);
            f->v[f->n++] = x;
        }
    }
    return noErr;
}

static void
put32(unsigned char **p, uint32_t v)
{
    (*p)[0] = v >> 24, (*p)[1] = v >> 16, (*p)[2] = v >> 8, (*p)[3] = v;
    *p += 4;
}

static void
put16(unsigned char **p, uint16_t v)
{
    (*p)[0] = v >> 8, (*p)[1] = v;
    *p += 2;
}

/* The file's bytes in resource file format (malloc'd). */
static unsigned char *
serialize(struct rfile *f, size_t *outSize)
{
    size_t dataLen = 0, nameLen = 0;
    for (long i = 0; i < f->n; i++) {
        struct res *r = &f->v[i];
        if (r->h && *r->h) {  /* a loaded resource's handle holds its current data */
            Size n = GetHandleSize(r->h);
            if (n != r->size || memcmp(*r->h, r->data, n)) {
                free(r->data);
                r->data = malloc(n ? n : 1);
                memcpy(r->data, *r->h, n);
                r->size = n;
            }
        }
        dataLen += 4 + r->size;
        if (r->named)
            nameLen += 1 + r->name[0];
    }
    long ntypes = 0;
    for (long t = 0; t < f->ntypes; t++)
        for (long i = 0; i < f->n; i++)
            if (f->v[i].type == f->types[t]) {
                ntypes++;
                break;
            }
    size_t typeList = 2 + 8 * ntypes, refList = 12 * f->n;
    size_t mapLen = 28 + typeList + refList + nameLen;
    size_t total = 256 + dataLen + mapLen;
    unsigned char *buf = calloc(1, total), *p = buf;
    put32(&p, 256);
    put32(&p, (uint32_t)(256 + dataLen));
    put32(&p, (uint32_t)dataLen);
    put32(&p, (uint32_t)mapLen);
    unsigned char *data = buf + 256, *map = buf + 256 + dataLen;
    memcpy(map, buf, 16);
    unsigned char *m = map + 22;
    put16(&m, f->attrs & ~mapChanged);
    put16(&m, 28);
    put16(&m, (uint16_t)(28 + typeList + refList));
    unsigned char *tl = map + 28, *te = tl;
    put16(&te, (uint16_t)(ntypes - 1));
    unsigned char *refs = tl + typeList, *names = map + 28 + typeList + refList;
    uint32_t dataAt = 0, nameAt = 0;
    for (long t = 0; t < f->ntypes; t++) {
        int count = 0;
        for (long i = 0; i < f->n; i++)
            count += f->v[i].type == f->types[t];
        if (!count)
            continue;
        put32(&te, f->types[t]);
        put16(&te, (uint16_t)(count - 1));
        put16(&te, (uint16_t)(refs - tl));
        for (long i = 0; i < f->n; i++) {
            struct res *r = &f->v[i];
            if (r->type != f->types[t])
                continue;
            put16(&refs, (uint16_t)r->id);
            if (r->named) {
                put16(&refs, (uint16_t)nameAt);
                memcpy(names + nameAt, r->name, 1 + r->name[0]);
                nameAt += 1 + r->name[0];
            } else {
                put16(&refs, 0xffff);
            }
            r->attrs &= ~resChanged;
            put32(&refs, ((uint32_t)r->attrs << 24) | dataAt);
            put32(&refs, 0);
            unsigned char *d = data + dataAt;
            put32(&d, (uint32_t)r->size);
            memcpy(d, r->data, r->size);
            dataAt += 4 + (uint32_t)r->size;
        }
    }
    *outSize = total;
    return buf;
}

static OSErr
write_file(struct rfile *f)
{
    size_t n;
    unsigned char *buf = serialize(f, &n);
    int rc;
    if (f->fork == 1) {
        rc = setxattr(f->path, XATTR_RESOURCEFORK_NAME, buf, n, 0, 0);
    } else {
        int fd = open(f->path, O_WRONLY | O_TRUNC);
        rc = fd < 0 ? -1 : (write(fd, buf, n) == (ssize_t)n ? 0 : -1);
        if (fd >= 0)
            close(fd);
    }
    free(buf);
    if (rc)
        return _FinchErrnoToOSErr(errno);
    f->dirty = false;
    return noErr;
}

static OSErr
read_fork(const char *path, int fork, unsigned char **out, size_t *size)
{
    if (fork == 1) {
        ssize_t n = getxattr(path, XATTR_RESOURCEFORK_NAME, NULL, 0, 0, 0);
        if (n <= 0)
            return eofErr;
        *out = malloc(n);
        n = getxattr(path, XATTR_RESOURCEFORK_NAME, *out, n, 0, 0);
        if (n < 0) {
            free(*out);
            return eofErr;
        }
        *size = n;
        return noErr;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return _FinchErrnoToOSErr(errno);
    struct stat st;
    fstat(fd, &st);
    *out = malloc(st.st_size ? st.st_size : 1);
    ssize_t n = read(fd, *out, st.st_size);
    close(fd);
    *size = n > 0 ? n : 0;
    return noErr;
}

static OSErr
open_file(const char *path, int fork, SInt8 permissions, ResFileRefNum *refNum)
{
    for (struct rfile *f = top; f; f = f->next)
        if (f->fork == fork && !strcmp(f->path, path)) {
            current = f->ref;
            *refNum = f->ref;
            return noErr;
        }
    unsigned char *buf = NULL;
    size_t size = 0;
    OSErr e = read_fork(path, fork, &buf, &size);
    if (e)
        return e;
    struct rfile *f = calloc(1, sizeof *f);
    strlcpy(f->path, path, sizeof f->path);
    f->fork = fork;
    e = parse(f, buf, size);
    free(buf);
    if (e) {
        for (long i = 0; i < f->n; i++)
            free(f->v[i].data);
        free(f->v);
        free(f->types);
        free(f);
        return e;
    }
    bool wantWrite = (permissions & 3) == fsWrPerm || (permissions & 3) == fsRdWrPerm ||
                     (permissions & 3) == fsRdWrShPerm || permissions == fsCurPerm;
    f->writable = wantWrite && access(path, W_OK) == 0;
    if (wantWrite && !f->writable && permissions != fsCurPerm) {
        free(f->v);
        free(f->types);
        free(f);
        return permErr;
    }
    f->ref = next_ref++;
    f->next = top;
    top = f;
    current = f->ref;
    *refNum = f->ref;
    return noErr;
}

OSErr
FSOpenResourceFile(const FSRef *ref, UniCharCount forkNameLength, const UniChar *forkName, SInt8 permissions,
                   ResFileRefNum *refNum)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(ref, path, sizeof path);
    if (!e) {
        int kind = _FinchForkKind(forkNameLength, forkName);
        pthread_mutex_lock(&lock);
        e = kind < 0 ? errFSForkNotFound : open_file(path, kind, permissions, refNum);
        pthread_mutex_unlock(&lock);
    }
    res_err = e;
    return e;
}

ResFileRefNum
FSOpenResFile(const FSRef *ref, SInt8 permission)
{
    ResFileRefNum r = -1;
    HFSUniStr255 rsrc;
    FSGetResourceForkName(&rsrc);
    return FSOpenResourceFile(ref, rsrc.length, rsrc.unicode, permission, &r) ? -1 : r;
}

static const unsigned char empty_map[30] = {0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 30,
                                            0, 0, 0, 0, 0, 0, 0, 0, 0, 28, 0, 30, 0xff, 0xff};

static OSErr
write_empty(const char *path, int fork)
{
    unsigned char buf[286] = {0};
    buf[2] = 1;  /* data at 256 */
    buf[6] = 1;  /* map at 256 */
    buf[15] = 30;
    memcpy(buf + 256, empty_map, 30);
    if (fork == 1)
        return setxattr(path, XATTR_RESOURCEFORK_NAME, buf, sizeof buf, 0, 0) ? _FinchErrnoToOSErr(errno) : noErr;
    int fd = open(path, O_WRONLY | O_TRUNC);
    if (fd < 0)
        return _FinchErrnoToOSErr(errno);
    ssize_t n = write(fd, buf, sizeof buf);
    close(fd);
    return n == sizeof buf ? noErr : ioErr;
}

OSErr
FSCreateResourceFile(const FSRef *parentRef, UniCharCount nameLength, const UniChar *name, FSCatalogInfoBitmap whichInfo,
                     const FSCatalogInfo *catalogInfo, UniCharCount forkNameLength, const UniChar *forkName,
                     FSRef *newRef, FSSpecPtr newSpec)
{
    FSRef created;
    OSErr e = FSCreateFileUnicode(parentRef, nameLength, name, whichInfo, catalogInfo, &created, newSpec);
    char path[PATH_MAX];
    if (!e && !(e = _FinchRefPath(&created, path, sizeof path))) {
        int kind = _FinchForkKind(forkNameLength, forkName);
        e = kind < 0 ? errFSForkNotFound : write_empty(path, kind);
    }
    if (!e && newRef)
        *newRef = created;
    res_err = e;
    return e;
}

void
FSCreateResFile(const FSRef *parentRef, UniCharCount nameLength, const UniChar *name, FSCatalogInfoBitmap whichInfo,
                const FSCatalogInfo *catalogInfo, FSRef *newRef, FSSpecPtr newSpec)
{
    HFSUniStr255 rsrc;
    FSGetResourceForkName(&rsrc);
    FSCreateResourceFile(parentRef, nameLength, name, whichInfo, catalogInfo, rsrc.length, rsrc.unicode, newRef, newSpec);
}

OSErr
FSCreateResourceFork(const FSRef *ref, UniCharCount forkNameLength, const UniChar *forkName, UInt32 flags)
{
    char path[PATH_MAX];
    OSErr e = _FinchRefPath(ref, path, sizeof path);
    if (!e) {
        int kind = _FinchForkKind(forkNameLength, forkName);
        e = kind < 0 ? errFSForkNotFound : write_empty(path, kind);
    }
    res_err = e;
    return e;
}

static void
close_file(struct rfile *f)
{
    if (f->dirty && f->writable)
        res_err = write_file(f);
    for (long i = 0; i < f->n; i++) {
        if (f->v[i].h)
            DisposeHandle(f->v[i].h);
        free(f->v[i].data);
    }
    free(f->v);
    free(f->types);
    struct rfile **pp = &top;
    while (*pp && *pp != f)
        pp = &(*pp)->next;
    if (*pp)
        *pp = f->next;
    if (current == f->ref)
        current = f->next ? f->next->ref : (top ? top->ref : 0);
    free(f);
}

void
CloseResFile(ResFileRefNum refNum)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = file_of(refNum);
    res_err = noErr;
    if (f)
        close_file(f);
    else
        res_err = resFNotFound;
    pthread_mutex_unlock(&lock);
}

ResFileRefNum CurResFile(void) { res_err = noErr; return current; }

void
UseResFile(ResFileRefNum refNum)
{
    pthread_mutex_lock(&lock);
    if (refNum == 0 || file_of(refNum)) {
        current = refNum;
        res_err = noErr;
    } else {
        res_err = resFNotFound;
    }
    pthread_mutex_unlock(&lock);
}

void
UpdateResFile(ResFileRefNum refNum)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = file_of(refNum);
    res_err = !f ? resFNotFound : (f->dirty && f->writable) ? write_file(f) : noErr;
    pthread_mutex_unlock(&lock);
}

ResFileRefNum
HomeResFile(Handle theResource)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = NULL;
    struct res *r = res_of(theResource, &f);
    res_err = r ? noErr : resNotFound;
    pthread_mutex_unlock(&lock);
    return r ? f->ref : -1;
}

static Handle
load(struct res *r)
{
    if (!r->h) {
        r->h = res_load ? NewHandle(r->size) : NewEmptyHandle();
        if (r->h && res_load)
            memcpy(*r->h, r->data, r->size);
        if (r->h)
            HSetRBit(r->h);
    }
    res_err = noErr;
    return r->h;
}

/* The files a search covers: the current one and, unless only1, those opened before it. */
static struct rfile *
search_start(void)
{
    return file_of(current);
}

static Handle
get(ResType type, ResID id, const unsigned char *name, bool only1)
{
    pthread_mutex_lock(&lock);
    Handle h = NULL;
    res_err = noErr;
    for (struct rfile *f = search_start(); f && !h; f = only1 ? NULL : f->next)
        for (long i = 0; i < f->n; i++) {
            struct res *r = &f->v[i];
            if (r->type == type &&
                (name ? (r->named && r->name[0] == name[0] && !memcmp(r->name + 1, name + 1, name[0])) : r->id == id)) {
                h = load(r);
                break;
            }
        }
    pthread_mutex_unlock(&lock);
    return h;
}

Handle Get1Resource(ResType theType, ResID theID) { return get(theType, theID, NULL, true); }
Handle GetResource(ResType theType, ResID theID) { return get(theType, theID, NULL, false); }
Handle Get1NamedResource(ResType theType, ConstStr255Param name) { return get(theType, 0, name, true); }
Handle GetNamedResource(ResType theType, ConstStr255Param name) { return get(theType, 0, name, false); }

static ResourceCount
count(ResType type, bool only1)
{
    pthread_mutex_lock(&lock);
    ResourceCount n = 0;
    for (struct rfile *f = search_start(); f; f = only1 ? NULL : f->next)
        for (long i = 0; i < f->n; i++)
            n += f->v[i].type == type;
    res_err = noErr;
    pthread_mutex_unlock(&lock);
    return n;
}

ResourceCount Count1Resources(ResType theType) { return count(theType, true); }
ResourceCount CountResources(ResType theType) { return count(theType, false); }

static Handle
get_ind(ResType type, ResourceIndex index, bool only1)
{
    pthread_mutex_lock(&lock);
    Handle h = NULL;
    ResourceIndex k = 0;
    for (struct rfile *f = search_start(); f && !h; f = only1 ? NULL : f->next)
        for (long i = 0; i < f->n && !h; i++)
            if (f->v[i].type == type && ++k == index)
                h = load(&f->v[i]);
    if (!h)
        res_err = resNotFound;
    pthread_mutex_unlock(&lock);
    return h;
}

Handle Get1IndResource(ResType theType, ResourceIndex index) { return get_ind(theType, index, true); }
Handle GetIndResource(ResType theType, ResourceIndex index) { return get_ind(theType, index, false); }

static ResourceCount
count_types(bool only1)
{
    pthread_mutex_lock(&lock);
    ResourceCount n = 0;
    for (struct rfile *f = search_start(); f; f = only1 ? NULL : f->next)
        for (long t = 0; t < f->ntypes; t++)
            for (long i = 0; i < f->n; i++)
                if (f->v[i].type == f->types[t]) {
                    n++;
                    break;
                }
    res_err = noErr;
    pthread_mutex_unlock(&lock);
    return n;
}

ResourceCount Count1Types(void) { return count_types(true); }
ResourceCount CountTypes(void) { return count_types(false); }

static void
ind_type(ResType *theType, ResourceIndex index, bool only1)
{
    pthread_mutex_lock(&lock);
    ResourceIndex k = 0;
    *theType = 0;
    res_err = resNotFound;
    for (struct rfile *f = search_start(); f && res_err; f = only1 ? NULL : f->next)
        for (long t = 0; t < f->ntypes && res_err; t++)
            for (long i = 0; i < f->n; i++)
                if (f->v[i].type == f->types[t]) {
                    if (++k == index) {
                        *theType = f->types[t];
                        res_err = noErr;
                    }
                    break;
                }
    pthread_mutex_unlock(&lock);
}

void Get1IndType(ResType *theType, ResourceIndex index) { ind_type(theType, index, true); }
void GetIndType(ResType *theType, ResourceIndex index) { ind_type(theType, index, false); }

void
GetResInfo(Handle theResource, ResID *theID, ResType *theType, Str255 name)
{
    pthread_mutex_lock(&lock);
    struct res *r = res_of(theResource, NULL);
    if (r) {
        if (theID)
            *theID = r->id;
        if (theType)
            *theType = r->type;
        if (name)
            memcpy(name, r->name, 1 + r->name[0]);
    }
    res_err = r ? noErr : resNotFound;
    pthread_mutex_unlock(&lock);
}

void
SetResInfo(Handle theResource, ResID theID, ConstStr255Param name)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = NULL;
    struct res *r = res_of(theResource, &f);
    if (!r) {
        res_err = resNotFound;
    } else if (!f->writable) {
        res_err = resAttrErr;
    } else {
        r->id = theID;
        if (name) {
            memcpy(r->name, name, 1 + name[0]);
            r->named = true;
        }
        f->dirty = true;
        res_err = noErr;
    }
    pthread_mutex_unlock(&lock);
}

ResAttributes
GetResAttrs(Handle theResource)
{
    pthread_mutex_lock(&lock);
    struct res *r = res_of(theResource, NULL);
    res_err = r ? noErr : resNotFound;
    ResAttributes a = r ? r->attrs : 0;
    pthread_mutex_unlock(&lock);
    return a;
}

void
SetResAttrs(Handle theResource, ResAttributes attrs)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = NULL;
    struct res *r = res_of(theResource, &f);
    if (r) {
        r->attrs = attrs;
        f->dirty = true;
    }
    res_err = r ? noErr : resNotFound;
    pthread_mutex_unlock(&lock);
}

long
GetResourceSizeOnDisk(Handle theResource)
{
    pthread_mutex_lock(&lock);
    struct res *r = res_of(theResource, NULL);
    res_err = r ? noErr : resNotFound;
    long n = r ? (long)r->size : -1;
    pthread_mutex_unlock(&lock);
    return n;
}

long GetMaxResourceSize(Handle theResource) { return GetResourceSizeOnDisk(theResource); }

void
LoadResource(Handle theResource)
{
    pthread_mutex_lock(&lock);
    struct res *r = res_of(theResource, NULL);
    if (r && !*theResource) {
        ReallocateHandle(theResource, r->size);
        if (*theResource)
            memcpy(*theResource, r->data, r->size);
    }
    res_err = r ? noErr : resNotFound;
    pthread_mutex_unlock(&lock);
}

void
ReleaseResource(Handle theResource)
{
    pthread_mutex_lock(&lock);
    struct res *r = res_of(theResource, NULL);
    if (r) {
        DisposeHandle(r->h);
        r->h = NULL;
    }
    res_err = r ? noErr : resNotFound;
    pthread_mutex_unlock(&lock);
}

void
DetachResource(Handle theResource)
{
    pthread_mutex_lock(&lock);
    struct res *r = res_of(theResource, NULL);
    if (r) {
        HClrRBit(r->h);
        r->h = NULL;
    }
    res_err = r ? noErr : resNotFound;
    pthread_mutex_unlock(&lock);
}

void
ChangedResource(Handle theResource)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = NULL;
    struct res *r = res_of(theResource, &f);
    if (!r) {
        res_err = resNotFound;
    } else if (!f->writable) {
        res_err = resAttrErr;
    } else {
        r->attrs |= resChanged;
        f->dirty = true;
        res_err = noErr;
    }
    pthread_mutex_unlock(&lock);
}

void
WriteResource(Handle theResource)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = NULL;
    struct res *r = res_of(theResource, &f);
    res_err = !r ? resNotFound : (f->dirty && f->writable) ? write_file(f) : noErr;
    pthread_mutex_unlock(&lock);
}

void
AddResource(Handle theData, ResType theType, ResID theID, ConstStr255Param name)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = file_of(current);
    if (!theData || res_of(theData, NULL)) {
        res_err = addResFailed;
    } else if (!f) {
        res_err = resFNotFound;
    } else if (!f->writable) {
        res_err = wrPermErr;
    } else {
        struct res x = {.type = theType, .id = theID, .attrs = resChanged, .h = theData};
        if (name && name[0]) {
            memcpy(x.name, name, 1 + name[0]);
            x.named = true;
        }
        x.size = GetHandleSize(theData);
        x.data = malloc(x.size ? x.size : 1);
        if (*theData)
            memcpy(x.data, *theData, x.size);
        HSetRBit(theData);
        f->v = realloc(f->v, (f->n + 1) * sizeof *f->v);
        f->v[f->n++] = x;
        add_type(f, theType);
        f->dirty = true;
        res_err = noErr;
    }
    pthread_mutex_unlock(&lock);
}

void
RemoveResource(Handle theResource)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = NULL;
    struct res *r = res_of(theResource, &f);
    if (!r) {
        res_err = rmvResFailed;
    } else if (!f->writable) {
        res_err = wrPermErr;
    } else {
        HClrRBit(r->h);
        free(r->data);
        long i = r - f->v;
        memmove(r, r + 1, (f->n - i - 1) * sizeof *r);
        f->n--;
        f->dirty = true;
        res_err = noErr;
    }
    pthread_mutex_unlock(&lock);
}

static ResID
unique(ResType type, bool only1)
{
    pthread_mutex_lock(&lock);
    ResID id = 128;
    for (;; id++) {
        bool used = false;
        for (struct rfile *f = search_start(); f && !used; f = only1 ? NULL : f->next)
            for (long i = 0; i < f->n && !used; i++)
                used = f->v[i].type == type && f->v[i].id == id;
        if (!used)
            break;
    }
    res_err = noErr;
    pthread_mutex_unlock(&lock);
    return id;
}

ResID Unique1ID(ResType theType) { return unique(theType, true); }
ResID UniqueID(ResType theType) { return unique(theType, false); }

ResFileAttributes
GetResFileAttrs(ResFileRefNum refNum)
{
    struct rfile *f = file_of(refNum);
    res_err = f ? noErr : resFNotFound;
    return f ? f->attrs : 0;
}

void
SetResFileAttrs(ResFileRefNum refNum, ResFileAttributes attrs)
{
    struct rfile *f = file_of(refNum);
    if (f) {
        f->attrs = attrs;
        f->dirty = true;
    }
    res_err = f ? noErr : resFNotFound;
}

void SetResPurge(Boolean install) { res_err = noErr; }

void
ReadPartialResource(Handle theResource, long offset, void *buffer, long count)
{
    pthread_mutex_lock(&lock);
    struct res *r = res_of(theResource, NULL);
    if (!r)
        res_err = resNotFound;
    else if (offset < 0 || offset + count > r->size)
        res_err = inputOutOfBounds;
    else {
        memcpy(buffer, r->data + offset, count);
        res_err = noErr;
    }
    pthread_mutex_unlock(&lock);
}

void
WritePartialResource(Handle theResource, long offset, const void *buffer, long count)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = NULL;
    struct res *r = res_of(theResource, &f);
    if (!r) {
        res_err = resNotFound;
    } else if (!f->writable) {
        res_err = wrPermErr;
    } else {
        if (offset + count > r->size) {
            r->data = realloc(r->data, offset + count);
            r->size = offset + count;
        }
        memcpy(r->data + offset, buffer, count);
        if (r->h && *r->h && GetHandleSize(r->h) >= offset + count)
            memcpy(*r->h + offset, buffer, count);
        f->dirty = true;
        res_err = write_file(f);
    }
    pthread_mutex_unlock(&lock);
}

void
SetResourceSize(Handle theResource, long newSize)
{
    pthread_mutex_lock(&lock);
    struct rfile *f = NULL;
    struct res *r = res_of(theResource, &f);
    if (r) {
        r->data = realloc(r->data, newSize ? newSize : 1);
        if (newSize > r->size)
            memset(r->data + r->size, 0, newSize - r->size);
        r->size = newSize;
        f->dirty = true;
    }
    res_err = r ? noErr : resNotFound;
    pthread_mutex_unlock(&lock);
}

OSErr
GetTopResourceFile(ResFileRefNum *refNum)
{
    *refNum = top ? top->ref : 0;
    return res_err = top ? noErr : resFNotFound;
}

OSErr
GetNextResourceFile(ResFileRefNum curRefNum, ResFileRefNum *nextRefNum)
{
    struct rfile *f = file_of(curRefNum);
    if (!f)
        return res_err = resFNotFound;
    *nextRefNum = f->next ? f->next->ref : 0;
    return res_err = f->next ? noErr : resFNotFound;
}

Boolean
FSResourceFileAlreadyOpen(const FSRef *resourceFileRef, Boolean *inChain, ResFileRefNum *refNum)
{
    char path[PATH_MAX];
    if (_FinchRefPath(resourceFileRef, path, sizeof path))
        return false;
    for (struct rfile *f = top; f; f = f->next)
        if (!strcmp(f->path, path)) {
            if (inChain)
                *inChain = true;
            if (refNum)
                *refNum = f->ref;
            return true;
        }
    if (inChain)
        *inChain = false;
    return false;
}
