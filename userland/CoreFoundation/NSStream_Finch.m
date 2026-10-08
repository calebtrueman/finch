/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSStream, NSInputStream and NSOutputStream (docs/design/FOUNDATION.md),
 * in CoreFoundation as Apple's are, with __NSCFInputStream and
 * __NSCFOutputStream as the classes of CFReadStream and CFWriteStream.
 * Streams made from data, files, memory and buffers are CF's
 * (CFConcreteStreams.c); events reach the delegate through CF's client
 * callback. Also CFStreamCreateBoundPair, which swift-corelibs CF lacks: a
 * read stream fed by a write stream through a fixed-size buffer.
 */
#include "CFObjCClasses_Finch.h"
#include <CoreFoundation/CFStream.h>
#include <CoreFoundation/CFStreamAbstract.h>
#include <pthread.h>

/* The NSStream keys are CF's property names, defined with the other NS
 * constants (NSConstants_Finch.c, NSConstants.aliases). */

typedef NSUInteger NSStreamStatus;
typedef NSUInteger NSStreamEvent;

@interface NSObject (FinchStreamMessages)
- (void)stream:(id)stream handleEvent:(NSStreamEvent)event;
- (CFRunLoopRef)getCFRunLoop;
- (id)name;
@end

@interface NSStream ()
- (void)open;
- (void)close;
- (id)delegate;
- (void)setDelegate:(id)delegate;
- (id)propertyForKey:(id)key;
- (BOOL)setProperty:(id)property forKey:(id)key;
- (void)scheduleInRunLoop:(id)runLoop forMode:(id)mode;
- (void)removeFromRunLoop:(id)runLoop forMode:(id)mode;
- (NSStreamStatus)streamStatus;
- (id)streamError;
@end

@interface __NSCFInputStream : NSInputStream
@end
@interface __NSCFOutputStream : NSOutputStream
@end
@interface __NSPlaceholderInputStream : NSInputStream
@end
@interface __NSPlaceholderOutputStream : NSOutputStream
@end

static void __attribute__((noreturn))
abstract(id self, SEL _cmd)
{
    char kind = object_isClass(self) ? '+' : '-';
    __CFFinchRaise(NSInvalidArgumentException, "*** %c[%s %s]: method only defined for abstract class.  Define %c[%s %s]!",
        kind, object_getClassName(self), sel_getName(_cmd), kind, object_getClassName(self), sel_getName(_cmd));
}

/* MARK: - Delegates */

/* Each CF stream's delegate (not retained), by address. */
static pthread_mutex_t delegates_lock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef delegates;

static id
delegate_of(id stream)
{
    pthread_mutex_lock(&delegates_lock);
    id d = delegates ? (id)CFDictionaryGetValue(delegates, stream) : nil;
    pthread_mutex_unlock(&delegates_lock);
    return d;
}

static void
set_delegate(id stream, id delegate)
{
    pthread_mutex_lock(&delegates_lock);
    if (!delegates) delegates = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    if (delegate) CFDictionarySetValue(delegates, stream, delegate);
    else CFDictionaryRemoveValue(delegates, stream);
    pthread_mutex_unlock(&delegates_lock);
}

/* An empty context: a NULL one would remove the client (CFStream.c). */
static CFStreamClientContext no_context = { 0, NULL, NULL, NULL, NULL };

static const CFOptionFlags all_events = kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable | kCFStreamEventCanAcceptBytes |
    kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered;

static void
read_event(CFReadStreamRef stream, CFStreamEventType event, void *info)
{
    id d = delegate_of((id)stream);
    if (!d) d = (id)stream;
    if ([d respondsToSelector:@selector(stream:handleEvent:)]) [d stream:(id)stream handleEvent:event];
}

static void
write_event(CFWriteStreamRef stream, CFStreamEventType event, void *info)
{
    id d = delegate_of((id)stream);
    if (!d) d = (id)stream;
    if ([d respondsToSelector:@selector(stream:handleEvent:)]) [d stream:(id)stream handleEvent:event];
}

/* MARK: - NSStream */

@implementation NSStream

- (void)open { abstract(self, _cmd); }
- (void)close { abstract(self, _cmd); }
- (id)delegate { abstract(self, _cmd); }
- (void)setDelegate:(id)delegate { abstract(self, _cmd); }
- (id)propertyForKey:(id)key { abstract(self, _cmd); }
- (BOOL)setProperty:(id)property forKey:(id)key { abstract(self, _cmd); }
- (void)scheduleInRunLoop:(id)runLoop forMode:(id)mode { abstract(self, _cmd); }
- (void)removeFromRunLoop:(id)runLoop forMode:(id)mode { abstract(self, _cmd); }
- (NSStreamStatus)streamStatus { abstract(self, _cmd); }
- (id)streamError { abstract(self, _cmd); }

/* What CF asks of streams it didn't make (CFStream.c). */
- (CFStreamError)_cfStreamError
{
    CFStreamError e = { 0, 0 };
    id err = [self streamError];
    if (err) {
        e.error = (SInt32)CFErrorGetCode((CFErrorRef)err);
        e.domain = kCFStreamErrorDomainCustom;
    }
    return e;
}

+ (void)getBoundStreamsWithBufferSize:(NSUInteger)bufferSize inputStream:(NSInputStream **)inputStream outputStream:(NSOutputStream **)outputStream
{
    CFReadStreamRef r = NULL;
    CFWriteStreamRef w = NULL;
    CFStreamCreateBoundPair(NULL, &r, &w, (CFIndex)bufferSize);
    if (inputStream) *inputStream = [(id)r autorelease];
    else if (r) CFRelease(r);
    if (outputStream) *outputStream = [(id)w autorelease];
    else if (w) CFRelease(w);
}

+ (void)getStreamsToHostWithName:(id)hostname port:(NSInteger)port inputStream:(NSInputStream **)inputStream outputStream:(NSOutputStream **)outputStream
{
    CFReadStreamRef r = NULL;
    CFWriteStreamRef w = NULL;
    CFStreamCreatePairWithSocketToHost(NULL, (CFStringRef)hostname, (UInt32)port, &r, &w);
    if (inputStream) *inputStream = [(id)r autorelease];
    else if (r) CFRelease(r);
    if (outputStream) *outputStream = [(id)w autorelease];
    else if (w) CFRelease(w);
}

+ (void)getStreamsToHost:(id)host port:(NSInteger)port inputStream:(NSInputStream **)inputStream outputStream:(NSOutputStream **)outputStream
{
    [self getStreamsToHostWithName:[host name] port:port inputStream:inputStream outputStream:outputStream];
}

@end

/* MARK: - NSInputStream */

static id input_placeholder, output_placeholder;

@implementation NSInputStream

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSInputStream class]) {
        if (!input_placeholder) input_placeholder = class_createInstance([__NSPlaceholderInputStream class], 0);
        return input_placeholder;
    }
    return [super allocWithZone:zone];
}

- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)len { abstract(self, _cmd); }
- (BOOL)getBuffer:(uint8_t **)buffer length:(NSUInteger *)len { abstract(self, _cmd); }
- (BOOL)hasBytesAvailable { abstract(self, _cmd); }

- (instancetype)initWithData:(id)data { return [super init]; }
- (instancetype)initWithURL:(id)url { return [super init]; }
- (instancetype)initWithFileAtPath:(id)path { return [super init]; }

+ (instancetype)inputStreamWithData:(id)data { return [[[self alloc] initWithData:data] autorelease]; }
+ (instancetype)inputStreamWithFileAtPath:(id)path { return [[[self alloc] initWithFileAtPath:path] autorelease]; }
+ (instancetype)inputStreamWithURL:(id)url { return [[[self alloc] initWithURL:url] autorelease]; }

@end

@implementation __NSPlaceholderInputStream

FINCH_IMMORTAL_MEMORY

static id
new_read_stream(CFReadStreamRef s)
{
    if (s) set_delegate((id)s, nil);   /* a new stream at a reused address */
    return (id)s;
}

- (instancetype)initWithData:(id)data
{
    if (!data) __CFFinchRaise(NSInvalidArgumentException, "*** -[NSInputStream initWithData:]: nil argument");
    return new_read_stream(CFReadStreamCreateWithData(NULL, (CFDataRef)data));
}

- (instancetype)initWithURL:(id)url
{
    return url ? new_read_stream(CFReadStreamCreateWithFile(NULL, (CFURLRef)url)) : nil;
}

- (instancetype)initWithFileAtPath:(id)path
{
    if (!path) return nil;
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (CFStringRef)path, kCFURLPOSIXPathStyle, false);
    id s = new_read_stream(CFReadStreamCreateWithFile(NULL, url));
    CFRelease(url);
    return s;
}

@end

/* MARK: - NSOutputStream */

@implementation NSOutputStream

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSOutputStream class]) {
        if (!output_placeholder) output_placeholder = class_createInstance([__NSPlaceholderOutputStream class], 0);
        return output_placeholder;
    }
    return [super allocWithZone:zone];
}

- (NSInteger)write:(const uint8_t *)buffer maxLength:(NSUInteger)len { abstract(self, _cmd); }
- (BOOL)hasSpaceAvailable { abstract(self, _cmd); }

- (instancetype)initToMemory { return [super init]; }
- (instancetype)initToBuffer:(uint8_t *)buffer capacity:(NSUInteger)capacity { return [super init]; }
- (instancetype)initWithURL:(id)url append:(BOOL)shouldAppend { return [super init]; }
- (instancetype)initToFileAtPath:(id)path append:(BOOL)shouldAppend { return [super init]; }

+ (instancetype)outputStreamToMemory { return [[[self alloc] initToMemory] autorelease]; }
+ (instancetype)outputStreamToBuffer:(uint8_t *)buffer capacity:(NSUInteger)capacity
{
    return [[[self alloc] initToBuffer:buffer capacity:capacity] autorelease];
}
+ (instancetype)outputStreamToFileAtPath:(id)path append:(BOOL)shouldAppend
{
    return [[[self alloc] initToFileAtPath:path append:shouldAppend] autorelease];
}
+ (instancetype)outputStreamWithURL:(id)url append:(BOOL)shouldAppend
{
    return [[[self alloc] initWithURL:url append:shouldAppend] autorelease];
}

@end

@implementation __NSPlaceholderOutputStream

FINCH_IMMORTAL_MEMORY

static id
new_write_stream(CFWriteStreamRef s)
{
    if (s) set_delegate((id)s, nil);
    return (id)s;
}

- (instancetype)initToMemory { return new_write_stream(CFWriteStreamCreateWithAllocatedBuffers(NULL, NULL)); }

- (instancetype)initToBuffer:(uint8_t *)buffer capacity:(NSUInteger)capacity
{
    return new_write_stream(CFWriteStreamCreateWithBuffer(NULL, buffer, (CFIndex)capacity));
}

- (instancetype)initWithURL:(id)url append:(BOOL)shouldAppend
{
    if (!url) return nil;
    CFWriteStreamRef s = CFWriteStreamCreateWithFile(NULL, (CFURLRef)url);
    if (s && shouldAppend) CFWriteStreamSetProperty(s, kCFStreamPropertyAppendToFile, kCFBooleanTrue);
    return new_write_stream(s);
}

- (instancetype)initToFileAtPath:(id)path append:(BOOL)shouldAppend
{
    if (!path) return nil;
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (CFStringRef)path, kCFURLPOSIXPathStyle, false);
    id s = [self initWithURL:(id)url append:shouldAppend];
    CFRelease(url);
    return s;
}

@end

/* MARK: - CF's streams */

@implementation __NSCFInputStream

FINCH_CF_OBJECT_MEMORY

- (void)open { CFReadStreamOpen((CFReadStreamRef)self); }
- (void)close { CFReadStreamClose((CFReadStreamRef)self); }
- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)len { return CFReadStreamRead((CFReadStreamRef)self, buffer, (CFIndex)len); }

- (BOOL)getBuffer:(uint8_t **)buffer length:(NSUInteger *)len
{
    CFIndex n = 0;
    const UInt8 *b = CFReadStreamGetBuffer((CFReadStreamRef)self, 0, &n);
    if (!b || n <= 0) return NO;
    if (buffer) *buffer = (uint8_t *)b;
    if (len) *len = (NSUInteger)n;
    return YES;
}

- (BOOL)hasBytesAvailable { return CFReadStreamHasBytesAvailable((CFReadStreamRef)self); }
- (NSStreamStatus)streamStatus { return (NSStreamStatus)CFReadStreamGetStatus((CFReadStreamRef)self); }
- (id)streamError { return [(id)CFReadStreamCopyError((CFReadStreamRef)self) autorelease]; }
- (id)propertyForKey:(id)key { return [(id)CFReadStreamCopyProperty((CFReadStreamRef)self, (CFStringRef)key) autorelease]; }
- (BOOL)setProperty:(id)property forKey:(id)key { return CFReadStreamSetProperty((CFReadStreamRef)self, (CFStringRef)key, property); }
- (id)delegate { return delegate_of(self); }

- (void)setDelegate:(id)delegate
{
    set_delegate(self, delegate == self ? nil : delegate);
    CFReadStreamSetClient((CFReadStreamRef)self, all_events, read_event, &no_context);
}

- (void)scheduleInRunLoop:(id)runLoop forMode:(id)mode
{
    CFReadStreamSetClient((CFReadStreamRef)self, all_events, read_event, &no_context);
    CFReadStreamScheduleWithRunLoop((CFReadStreamRef)self, [runLoop getCFRunLoop], (CFStringRef)mode);
}

- (void)removeFromRunLoop:(id)runLoop forMode:(id)mode
{
    CFReadStreamUnscheduleFromRunLoop((CFReadStreamRef)self, [runLoop getCFRunLoop], (CFStringRef)mode);
}

@end

@implementation __NSCFOutputStream

FINCH_CF_OBJECT_MEMORY

- (void)open { CFWriteStreamOpen((CFWriteStreamRef)self); }
- (void)close { CFWriteStreamClose((CFWriteStreamRef)self); }
- (NSInteger)write:(const uint8_t *)buffer maxLength:(NSUInteger)len { return CFWriteStreamWrite((CFWriteStreamRef)self, buffer, (CFIndex)len); }
- (BOOL)hasSpaceAvailable { return CFWriteStreamCanAcceptBytes((CFWriteStreamRef)self); }
- (NSStreamStatus)streamStatus { return (NSStreamStatus)CFWriteStreamGetStatus((CFWriteStreamRef)self); }
- (id)streamError { return [(id)CFWriteStreamCopyError((CFWriteStreamRef)self) autorelease]; }
- (id)propertyForKey:(id)key { return [(id)CFWriteStreamCopyProperty((CFWriteStreamRef)self, (CFStringRef)key) autorelease]; }
- (BOOL)setProperty:(id)property forKey:(id)key { return CFWriteStreamSetProperty((CFWriteStreamRef)self, (CFStringRef)key, property); }
- (id)delegate { return delegate_of(self); }

- (void)setDelegate:(id)delegate
{
    set_delegate(self, delegate == self ? nil : delegate);
    CFWriteStreamSetClient((CFWriteStreamRef)self, all_events, write_event, &no_context);
}

- (void)scheduleInRunLoop:(id)runLoop forMode:(id)mode
{
    CFWriteStreamSetClient((CFWriteStreamRef)self, all_events, write_event, &no_context);
    CFWriteStreamScheduleWithRunLoop((CFWriteStreamRef)self, [runLoop getCFRunLoop], (CFStringRef)mode);
}

- (void)removeFromRunLoop:(id)runLoop forMode:(id)mode
{
    CFWriteStreamUnscheduleFromRunLoop((CFWriteStreamRef)self, [runLoop getCFRunLoop], (CFStringRef)mode);
}

@end

/* MARK: - Bound pairs */

typedef struct {
    pthread_mutex_t lock;
    uint8_t *buf;
    CFIndex cap, start, len;
    Boolean writerClosed, readerClosed;
    int refs;
    CFReadStreamRef reader;
    CFWriteStreamRef writer;
} BoundPair;

static void
pair_release(BoundPair *p)
{
    pthread_mutex_lock(&p->lock);
    int refs = --p->refs;
    pthread_mutex_unlock(&p->lock);
    if (refs) return;
    pthread_mutex_destroy(&p->lock);
    free(p->buf);
    free(p);
}

static void *pair_create(void *stream, void *info) { return info; }

static void
pair_read_finalize(CFReadStreamRef stream, void *info)
{
    BoundPair *p = info;
    pthread_mutex_lock(&p->lock);
    p->reader = NULL;
    p->readerClosed = true;
    pthread_mutex_unlock(&p->lock);
    pair_release(p);
}

static void
pair_write_finalize(CFWriteStreamRef stream, void *info)
{
    BoundPair *p = info;
    pthread_mutex_lock(&p->lock);
    p->writer = NULL;
    p->writerClosed = true;
    CFReadStreamRef reader = p->reader;
    if (reader) CFRetain(reader);
    pthread_mutex_unlock(&p->lock);
    if (reader) {
        CFReadStreamSignalEvent(reader, kCFStreamEventEndEncountered, NULL);
        CFRelease(reader);
    }
    pair_release(p);
}

static Boolean pair_read_open(CFReadStreamRef s, CFErrorRef *e, Boolean *done, void *info) { *done = true; return true; }
static Boolean pair_write_open(CFWriteStreamRef s, CFErrorRef *e, Boolean *done, void *info) { *done = true; return true; }

static CFIndex
pair_read(CFReadStreamRef stream, UInt8 *buffer, CFIndex length, CFErrorRef *error, Boolean *atEOF, void *info)
{
    BoundPair *p = info;
    pthread_mutex_lock(&p->lock);
    CFIndex n = 0;
    while (n < length && p->len > 0) {
        buffer[n++] = p->buf[p->start];
        p->start = (p->start + 1) % p->cap;
        p->len--;
    }
    *atEOF = p->len == 0 && p->writerClosed;
    CFWriteStreamRef writer = n && p->writer ? (CFWriteStreamRef)CFRetain(p->writer) : NULL;
    pthread_mutex_unlock(&p->lock);
    if (writer) {
        CFWriteStreamSignalEvent(writer, kCFStreamEventCanAcceptBytes, NULL);
        CFRelease(writer);
    }
    return n;
}

static Boolean
pair_can_read(CFReadStreamRef stream, CFErrorRef *error, void *info)
{
    BoundPair *p = info;
    pthread_mutex_lock(&p->lock);
    Boolean r = p->len > 0 || p->writerClosed;
    pthread_mutex_unlock(&p->lock);
    return r;
}

static void
pair_read_close(CFReadStreamRef stream, void *info)
{
    BoundPair *p = info;
    pthread_mutex_lock(&p->lock);
    p->readerClosed = true;
    pthread_mutex_unlock(&p->lock);
}

static CFIndex
pair_write(CFWriteStreamRef stream, const UInt8 *buffer, CFIndex length, CFErrorRef *error, void *info)
{
    BoundPair *p = info;
    pthread_mutex_lock(&p->lock);
    if (p->readerClosed) {
        pthread_mutex_unlock(&p->lock);
        return -1;
    }
    CFIndex n = 0;
    while (n < length && p->len < p->cap) {
        p->buf[(p->start + p->len) % p->cap] = buffer[n++];
        p->len++;
    }
    CFReadStreamRef reader = n && p->reader ? (CFReadStreamRef)CFRetain(p->reader) : NULL;
    pthread_mutex_unlock(&p->lock);
    if (reader) {
        CFReadStreamSignalEvent(reader, kCFStreamEventHasBytesAvailable, NULL);
        CFRelease(reader);
    }
    return n;
}

static Boolean
pair_can_write(CFWriteStreamRef stream, CFErrorRef *error, void *info)
{
    BoundPair *p = info;
    pthread_mutex_lock(&p->lock);
    Boolean r = p->len < p->cap && !p->readerClosed;
    pthread_mutex_unlock(&p->lock);
    return r;
}

static void
pair_write_close(CFWriteStreamRef stream, void *info)
{
    BoundPair *p = info;
    pthread_mutex_lock(&p->lock);
    p->writerClosed = true;
    CFReadStreamRef reader = p->reader ? (CFReadStreamRef)CFRetain(p->reader) : NULL;
    pthread_mutex_unlock(&p->lock);
    if (reader) {
        CFReadStreamSignalEvent(reader, kCFStreamEventEndEncountered, NULL);
        CFRelease(reader);
    }
}

CF_EXPORT void
CFStreamCreateBoundPair(CFAllocatorRef alloc, CFReadStreamRef *readStream, CFWriteStreamRef *writeStream, CFIndex transferBufferSize)
{
    BoundPair *p = calloc(1, sizeof(BoundPair));
    pthread_mutex_init(&p->lock, NULL);
    p->cap = transferBufferSize > 0 ? transferBufferSize : 1;
    p->buf = malloc((size_t)p->cap);
    p->refs = 2;
    CFReadStreamCallBacks rcb = { 2, (void *(*)(CFReadStreamRef, void *))pair_create, pair_read_finalize, NULL, pair_read_open, NULL,
        pair_read, NULL, pair_can_read, pair_read_close, NULL, NULL, NULL, NULL, NULL };
    CFWriteStreamCallBacks wcb = { 2, (void *(*)(CFWriteStreamRef, void *))pair_create, pair_write_finalize, NULL, pair_write_open, NULL,
        pair_write, pair_can_write, pair_write_close, NULL, NULL, NULL, NULL, NULL };
    p->reader = CFReadStreamCreate(alloc, &rcb, p);
    p->writer = CFWriteStreamCreate(alloc, &wcb, p);
    if (readStream) *readStream = p->reader;
    else CFRelease(p->reader);
    if (writeStream) *writeStream = p->writer;
    else CFRelease(p->writer);
}

/* MARK: - Registration */

CF_PRIVATE void
__CFFinchStreamClasses(Class *input, Class *output)
{
    *input = [__NSCFInputStream class];
    *output = [__NSCFOutputStream class];
}
