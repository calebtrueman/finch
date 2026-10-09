/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGDataProvider and CGDataConsumer: byte sources (memory, CFData, files,
 * sequential and direct callbacks) and sinks (callbacks, CFData, files).
 */
#include "CGInternal.h"
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

enum { PROVIDER_BYTES, PROVIDER_CFDATA, PROVIDER_SEQUENTIAL, PROVIDER_DIRECT, PROVIDER_MMAP };

struct CGDataProvider {
    CGRuntimeBase base;
    int kind;
    void *info;
    const void *bytes;
    size_t size;
    CGDataProviderReleaseDataCallback release_data;
    CFDataRef data;
    CGDataProviderSequentialCallbacks seq;
    CGDataProviderDirectCallbacks direct;
};

static void
provider_finalize(CFTypeRef cf)
{
    struct CGDataProvider *p = (struct CGDataProvider *)cf;
    switch (p->kind) {
    case PROVIDER_BYTES:
        if (p->release_data)
            p->release_data(p->info, p->bytes, p->size);
        break;
    case PROVIDER_CFDATA:
        break;
    case PROVIDER_SEQUENTIAL:
        if (p->seq.releaseInfo)
            p->seq.releaseInfo(p->info);
        break;
    case PROVIDER_DIRECT:
        if (p->direct.releaseInfo)
            p->direct.releaseInfo(p->info);
        break;
    case PROVIDER_MMAP:
        munmap((void *)p->bytes, p->size);
        break;
    }
    if (p->data)
        CFRelease(p->data);
}

static CFStringRef
provider_desc(CFTypeRef cf)
{
    return CGTypeCopyDescriptionPrefix(cf, "CGDataProvider");
}

static const CGRuntimeClass provider_class = {
    0, "CGDataProvider", NULL, NULL, provider_finalize, NULL, NULL, NULL, provider_desc, NULL, NULL, 0,
};
static CFTypeID provider_type;

CFTypeID
CGDataProviderGetTypeID(void)
{
    return CGTypeRegister(&provider_class, &provider_type);
}

static struct CGDataProvider *
provider_new(int kind, void *info)
{
    struct CGDataProvider *p = CGTypeCreateInstance(CGDataProviderGetTypeID(), sizeof(struct CGDataProvider));
    p->kind = kind;
    p->info = info;
    return p;
}

CGDataProviderRef
CGDataProviderCreateWithData(void *info, const void *data, size_t size, CGDataProviderReleaseDataCallback release)
{
    if (!data && size)
        return NULL;
    struct CGDataProvider *p = provider_new(PROVIDER_BYTES, info);
    p->bytes = data;
    p->size = size;
    p->release_data = release;
    return p;
}

CGDataProviderRef
CGDataProviderCreateWithCFData(CFDataRef data)
{
    if (!data)
        return NULL;
    struct CGDataProvider *p = provider_new(PROVIDER_CFDATA, NULL);
    p->data = CFDataCreateCopy(NULL, data);
    p->bytes = CFDataGetBytePtr(p->data);
    p->size = CFDataGetLength(p->data);
    return p;
}

CGDataProviderRef
CGDataProviderCreateSequential(void *info, const CGDataProviderSequentialCallbacks *callbacks)
{
    if (!callbacks || !callbacks->getBytes)
        return NULL;
    struct CGDataProvider *p = provider_new(PROVIDER_SEQUENTIAL, info);
    p->seq = *callbacks;
    return p;
}

CGDataProviderRef
CGDataProviderCreateDirect(void *info, off_t size, const CGDataProviderDirectCallbacks *callbacks)
{
    if (!callbacks || (!callbacks->getBytePointer && !callbacks->getBytesAtPosition) || size < 0)
        return NULL;
    struct CGDataProvider *p = provider_new(PROVIDER_DIRECT, info);
    p->direct = *callbacks;
    p->size = (size_t)size;
    return p;
}

CGDataProviderRef
CGDataProviderCreateWithFilename(const char *filename)
{
    if (!filename)
        return NULL;
    int fd = open(filename, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return NULL;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return NULL;
    }
    struct CGDataProvider *p;
    if (st.st_size == 0) {
        p = provider_new(PROVIDER_BYTES, NULL);
    } else {
        void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (map == MAP_FAILED) {
            close(fd);
            return NULL;
        }
        p = provider_new(PROVIDER_MMAP, NULL);
        p->bytes = map;
        p->size = (size_t)st.st_size;
    }
    close(fd);
    return p;
}

CGDataProviderRef
CGDataProviderCreateWithURL(CFURLRef url)
{
    char path[PATH_MAX];
    if (!url || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path))
        return NULL;
    return CGDataProviderCreateWithFilename(path);
}

CGDataProviderRef
CGDataProviderRetain(CGDataProviderRef p)
{
    return p ? (CGDataProviderRef)CFRetain(p) : NULL;
}

void
CGDataProviderRelease(CGDataProviderRef p)
{
    if (p)
        CFRelease(p);
}

void *
CGDataProviderGetInfo(CGDataProviderRef p)
{
    return p ? p->info : NULL;
}

CFDataRef
CGDataProviderCopyData(CGDataProviderRef p)
{
    if (!p)
        return NULL;
    switch (p->kind) {
    case PROVIDER_CFDATA:
        return CFRetain(p->data);
    case PROVIDER_BYTES:
    case PROVIDER_MMAP:
        return CFDataCreate(NULL, p->bytes, (CFIndex)p->size);
    case PROVIDER_SEQUENTIAL: {
        CFMutableDataRef out = CFDataCreateMutable(NULL, 0);
        if (p->seq.rewind)
            p->seq.rewind(p->info);
        UInt8 buf[16384];
        size_t n;
        while ((n = p->seq.getBytes(p->info, buf, sizeof buf)) > 0)
            CFDataAppendBytes(out, buf, (CFIndex)n);
        return out;
    }
    case PROVIDER_DIRECT: {
        if (p->direct.getBytePointer) {
            const void *ptr = p->direct.getBytePointer(p->info);
            if (!ptr)
                return NULL;
            CFDataRef out = CFDataCreate(NULL, ptr, (CFIndex)p->size);
            if (p->direct.releaseBytePointer)
                p->direct.releaseBytePointer(p->info, ptr);
            return out;
        }
        CFMutableDataRef out = CFDataCreateMutable(NULL, (CFIndex)p->size);
        CFDataSetLength(out, (CFIndex)p->size);
        size_t got = 0;
        while (got < p->size) {
            size_t n = p->direct.getBytesAtPosition(p->info, CFDataGetMutableBytePtr(out) + got, (off_t)got,
                                                    p->size - got);
            if (n == 0)
                break;
            got += n;
        }
        CFDataSetLength(out, (CFIndex)got);
        return out;
    }
    }
    return NULL;
}

#pragma mark - Consumers

enum { CONSUMER_CALLBACKS, CONSUMER_CFDATA, CONSUMER_FILE };

struct CGDataConsumer {
    CGRuntimeBase base;
    int kind;
    void *info;
    CGDataConsumerCallbacks callbacks;
    CFMutableDataRef data;
    int fd;
};

static void
consumer_finalize(CFTypeRef cf)
{
    struct CGDataConsumer *c = (struct CGDataConsumer *)cf;
    if (c->kind == CONSUMER_CALLBACKS && c->callbacks.releaseConsumer)
        c->callbacks.releaseConsumer(c->info);
    if (c->data)
        CFRelease(c->data);
    if (c->kind == CONSUMER_FILE)
        close(c->fd);
}

static CFStringRef
consumer_desc(CFTypeRef cf)
{
    return CGTypeCopyDescriptionPrefix(cf, "CGDataConsumer");
}

static const CGRuntimeClass consumer_class = {
    0, "CGDataConsumer", NULL, NULL, consumer_finalize, NULL, NULL, NULL, consumer_desc, NULL, NULL, 0,
};
static CFTypeID consumer_type;

CFTypeID
CGDataConsumerGetTypeID(void)
{
    return CGTypeRegister(&consumer_class, &consumer_type);
}

static struct CGDataConsumer *
consumer_new(int kind)
{
    struct CGDataConsumer *c = CGTypeCreateInstance(CGDataConsumerGetTypeID(), sizeof(struct CGDataConsumer));
    c->kind = kind;
    c->fd = -1;
    return c;
}

CGDataConsumerRef
CGDataConsumerCreate(void *info, const CGDataConsumerCallbacks *callbacks)
{
    if (!callbacks || !callbacks->putBytes)
        return NULL;
    struct CGDataConsumer *c = consumer_new(CONSUMER_CALLBACKS);
    c->info = info;
    c->callbacks = *callbacks;
    return c;
}

CGDataConsumerRef
CGDataConsumerCreateWithCFData(CFMutableDataRef data)
{
    if (!data)
        return NULL;
    struct CGDataConsumer *c = consumer_new(CONSUMER_CFDATA);
    c->data = (CFMutableDataRef)CFRetain(data);
    return c;
}

CGDataConsumerRef
CGDataConsumerCreateWithURL(CFURLRef url)
{
    char path[PATH_MAX];
    if (!url || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path))
        return NULL;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0)
        return NULL;
    struct CGDataConsumer *c = consumer_new(CONSUMER_FILE);
    c->fd = fd;
    return c;
}

CGDataConsumerRef
CGDataConsumerRetain(CGDataConsumerRef c)
{
    return c ? (CGDataConsumerRef)CFRetain(c) : NULL;
}

void
CGDataConsumerRelease(CGDataConsumerRef c)
{
    if (c)
        CFRelease(c);
}

size_t
CGDataConsumerPutBytesInternal(CGDataConsumerRef c, const void *bytes, size_t count)
{
    switch (c->kind) {
    case CONSUMER_CALLBACKS:
        return c->callbacks.putBytes(c->info, bytes, count);
    case CONSUMER_CFDATA:
        CFDataAppendBytes(c->data, bytes, (CFIndex)count);
        return count;
    case CONSUMER_FILE: {
        size_t done = 0;
        while (done < count) {
            ssize_t n = write(c->fd, (const char *)bytes + done, count - done);
            if (n <= 0)
                break;
            done += (size_t)n;
        }
        return done;
    }
    }
    return 0;
}
