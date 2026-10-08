/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Foundation's functions, exception names, NSAutoreleasePool, and its
 * categories on the classes CoreFoundation hosts (docs/design/FOUNDATION.md),
 * against the SDK's declarations.
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <os/log.h>
#include <pthread.h>
#import <objc/message.h>
#include <pwd.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include "Foundation_Finch.h"

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);

NSExceptionName const NSCharacterConversionException = @"NSCharacterConversionException";
NSExceptionName const NSParseErrorException = @"NSParseErrorException";
NSExceptionName const NSDestinationInvalidException = @"NSDestinationInvalidException";
NSExceptionName const NSInvalidArchiveOperationException = @"NSInvalidArchiveOperationException";
NSExceptionName const NSInvalidUnarchiveOperationException = @"NSInvalidUnarchiveOperationException";
NSNotificationName const NSUserDefaultsDidChangeNotification = @"NSUserDefaultsDidChangeNotification";
NSNotificationName const NSUserDefaultsSizeLimitExceededNotification = @"NSUserDefaultsSizeLimitExceededNotification";
NSString *const NSArgumentDomain = @"NSArgumentDomain";
NSString *const NSGlobalDomain = @"NSGlobalDomain";
NSString *const NSRegistrationDomain = @"NSRegistrationDomain";
NSErrorDomain const NSCocoaErrorDomain = @"NSCocoaErrorDomain";
NSErrorDomain const NSPOSIXErrorDomain = @"NSPOSIXErrorDomain";
NSErrorDomain const NSOSStatusErrorDomain = @"NSOSStatusErrorDomain";
NSErrorUserInfoKey const NSFilePathErrorKey = @"NSFilePath";
NSErrorUserInfoKey const NSUnderlyingErrorKey = @"NSUnderlyingError";
NSErrorUserInfoKey const NSLocalizedDescriptionKey = @"NSLocalizedDescription";

/* MARK: - Helpers (Foundation_Finch.h) */

void
FinchRaise(NSString *name, const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    CFStringRef f = CFStringCreateWithCString(NULL, format, kCFStringEncodingUTF8);
    CFStringRef r = CFStringCreateWithFormatAndArguments(NULL, NULL, f, ap);
    va_end(ap);
    CFRelease(f);
    NSException *e = [NSException exceptionWithName:name reason:(NSString *)r userInfo:nil];
    CFRelease(r);
    [e raise];
    __builtin_unreachable();
}

void
FinchAbstract(id self, SEL _cmd)
{
    char kind = object_isClass(self) ? '+' : '-';
    FinchRaise(NSInvalidArgumentException, "*** %c[%s %s]: method only defined for abstract class.  Define %c[%s %s]!",
        kind, object_getClassName(self), sel_getName(_cmd), kind, object_getClassName(self), sel_getName(_cmd));
}

CFDictionaryRef
FinchFormatOptions(id locale)
{
    return NULL;
}

/* MARK: - Functions */

NSString *
NSStringFromClass(Class aClass)
{
    return aClass ? [NSString stringWithUTF8String:class_getName(aClass)] : nil;
}

Class
NSClassFromString(NSString *aClassName)
{
    return aClassName ? objc_getClass([aClassName UTF8String]) : Nil;
}

NSString *
NSStringFromSelector(SEL aSelector)
{
    return aSelector ? [NSString stringWithUTF8String:sel_getName(aSelector)] : nil;
}

SEL
NSSelectorFromString(NSString *aSelectorName)
{
    return aSelectorName ? sel_registerName([aSelectorName UTF8String]) : NULL;
}

NSString *
NSStringFromProtocol(Protocol *proto)
{
    return proto ? [NSString stringWithUTF8String:protocol_getName(proto)] : nil;
}

Protocol *
NSProtocolFromString(NSString *namestr)
{
    return namestr ? objc_getProtocol([namestr UTF8String]) : nil;
}

NSString *
NSStringFromRange(NSRange range)
{
    return [NSString stringWithFormat:@"{%lu, %lu}", (unsigned long)range.location, (unsigned long)range.length];
}

NSString *
NSUserName(void)
{
    struct passwd *pw = getpwuid(getuid());
    return pw ? [NSString stringWithUTF8String:pw->pw_name] : @"";
}

NSString *
NSFullUserName(void)
{
    struct passwd *pw = getpwuid(getuid());
    return pw && pw->pw_gecos ? [NSString stringWithUTF8String:pw->pw_gecos] : NSUserName();
}

NSString *
NSHomeDirectoryForUser(NSString *userName)
{
    struct passwd *pw = userName ? getpwnam([userName UTF8String]) : getpwuid(getuid());
    return pw && pw->pw_dir ? [NSString stringWithUTF8String:pw->pw_dir] : nil;
}

NSString *
NSHomeDirectory(void)
{
    const char *home = getenv("HOME");
    if (home && *home) return [NSString stringWithUTF8String:home];
    return NSHomeDirectoryForUser(nil);
}

NSString *
NSTemporaryDirectory(void)
{
    const char *t = getenv("TMPDIR");
    NSString *dir = [NSString stringWithUTF8String:t && *t ? t : "/tmp/"];
    return [dir hasSuffix:@"/"] ? dir : [dir stringByAppendingString:@"/"];
}

NSString *
NSOpenStepRootDirectory(void)
{
    return @"/";
}

/* NSLog: "<date> <process>[<pid>:<thread>] <message>" on stderr, as
 * Apple's does for a terminal; and the message to os_log. */
void
NSLogv(NSString *format, va_list args)
{
    CFStringRef msg = CFStringCreateWithFormatAndArguments(NULL, NULL, (CFStringRef)format, args);
    const char *utf8 = [(NSString *)msg UTF8String];
    os_log(OS_LOG_DEFAULT, "%{public}s", utf8);
    char when[64];
    struct timespec ts;
    struct tm tm;
    clock_gettime(CLOCK_REALTIME, &ts);
    localtime_r(&ts.tv_sec, &tm);
    size_t n = strftime(when, sizeof(when), "%Y-%m-%d %H:%M:%S", &tm);
    snprintf(when + n, sizeof(when) - n, ".%03ld", ts.tv_nsec / 1000000);
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    const char *prog = getprogname();
    size_t len = strlen(utf8);
    fprintf(stderr, "%s %s[%d:%llx] %s%s", when, prog ? prog : "?", getpid(), (unsigned long long)tid, utf8,
        len && utf8[len - 1] == '\n' ? "" : "\n");
    CFRelease(msg);
}

void
NSLog(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSLogv(format, ap);
    va_end(ap);
}

/* MARK: - NSAutoreleasePool */

@implementation NSAutoreleasePool

+ (void)addObject:(id)anObject { [anObject autorelease]; }
- (void)addObject:(id)anObject { [anObject autorelease]; }

- (instancetype)init
{
    if ((self = [super init])) _token = objc_autoreleasePoolPush();
    return self;
}

- (void)drain { [self release]; }

- (oneway void)release
{
    void *token = _token;
    _token = NULL;
    if (token) objc_autoreleasePoolPop(token);
    [self dealloc];
}

- (instancetype)retain
{
    FinchRaise(NSInvalidArgumentException, "*** -[NSAutoreleasePool retain]: Cannot retain an autorelease pool");
}

- (instancetype)autorelease
{
    FinchRaise(NSInvalidArgumentException, "*** -[NSAutoreleasePool autorelease]: Cannot autorelease an autorelease pool");
}

@end

/* MARK: - Foundation's categories on CoreFoundation's classes */

@implementation NSArray (FinchFoundation)

- (NSString *)componentsJoinedByString:(NSString *)separator
{
    NSMutableString *s = [NSMutableString string];
    NSUInteger i = 0;
    for (id o in self) {
        if (i++ && separator) [s appendString:separator];
        [s appendString:[o description]];
    }
    return [NSString stringWithString:s];
}

- (NSArray *)sortedArrayUsingSelector:(SEL)comparator
{
    NSMutableArray *m = [[self mutableCopy] autorelease];
    [m sortUsingSelector:comparator];
    return [NSArray arrayWithArray:m];
}

- (NSArray *)sortedArrayUsingComparator:(NSComparator NS_NOESCAPE)cmptr
{
    NSMutableArray *m = [[self mutableCopy] autorelease];
    [m sortUsingComparator:cmptr];
    return [NSArray arrayWithArray:m];
}

@end

/* CoreFoundation's NSMutableArray has this (CF sends it to ObjC arrays). */
@interface NSMutableArray (FinchCFPrimitives)
- (void)replaceObjectsInRange:(NSRange)range withObjects:(const id *)objects count:(NSUInteger)count;
@end

@implementation NSMutableArray (FinchFoundation)

static CFComparisonResult
selector_compare(const void *a, const void *b, void *context)
{
    NSComparisonResult (*send)(id, SEL, id) = (NSComparisonResult (*)(id, SEL, id))(void *)objc_msgSend;
    return (CFComparisonResult)send((id)a, (SEL)context, (id)b);
}

static CFComparisonResult
block_compare(const void *a, const void *b, void *context)
{
    return (CFComparisonResult)((NSComparator)context)((id)a, (id)b);
}

/* Through a CFArray copy (sorted stably by CF's merge sort), then back. */
static void
sort(NSMutableArray *self, CFComparatorFunction fn, void *context)
{
    CFMutableArrayRef a = CFArrayCreateMutableCopy(NULL, 0, (CFArrayRef)self);
    CFArraySortValues(a, CFRangeMake(0, CFArrayGetCount(a)), fn, context);
    NSUInteger n = (NSUInteger)CFArrayGetCount(a);
    id *objects = malloc((n + 1) * sizeof(id));
    CFArrayGetValues(a, CFRangeMake(0, (CFIndex)n), (const void **)objects);
    [self replaceObjectsInRange:NSMakeRange(0, n) withObjects:objects count:n];
    free(objects);
    CFRelease(a);
}

- (void)sortUsingSelector:(SEL)comparator { sort(self, selector_compare, comparator); }
- (void)sortUsingComparator:(NSComparator NS_NOESCAPE)cmptr { sort(self, block_compare, cmptr); }

@end

@implementation NSData (FinchFoundation)

+ (instancetype)dataWithContentsOfFile:(NSString *)path options:(NSDataReadingOptions)readOptionsMask error:(NSError **)errorPtr
{
    return [[[self alloc] initWithContentsOfFile:path options:readOptionsMask error:errorPtr] autorelease];
}

+ (instancetype)dataWithContentsOfFile:(NSString *)path { return [self dataWithContentsOfFile:path options:0 error:NULL]; }

- (instancetype)initWithContentsOfFile:(NSString *)path options:(NSDataReadingOptions)readOptionsMask error:(NSError **)errorPtr
{
    int fd = path ? open([path fileSystemRepresentation], O_RDONLY | O_CLOEXEC) : -1;
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) {
        int err = errno;
        if (fd >= 0) close(fd);
        if (errorPtr)
            *errorPtr = [NSError errorWithDomain:NSCocoaErrorDomain code:err == ENOENT ? NSFileReadNoSuchFileError : NSFileReadUnknownError
                userInfo:path ? @{ NSFilePathErrorKey: path, NSUnderlyingErrorKey: [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil] } : nil];
        [self release];
        return nil;
    }
    NSMutableData *d = [NSMutableData dataWithCapacity:(NSUInteger)st.st_size];
    char buf[65536];
    ssize_t r;
    while ((r = read(fd, buf, sizeof(buf))) > 0) [d appendBytes:buf length:(NSUInteger)r];
    close(fd);
    return [self initWithData:d];
}

- (instancetype)initWithContentsOfFile:(NSString *)path { return [self initWithContentsOfFile:path options:0 error:NULL]; }

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)useAuxiliaryFile
{
    return [self writeToFile:path options:useAuxiliaryFile ? NSDataWritingAtomic : 0 error:NULL];
}

- (BOOL)writeToFile:(NSString *)path options:(NSDataWritingOptions)writeOptionsMask error:(NSError **)errorPtr
{
    NSString *target = (writeOptionsMask & NSDataWritingAtomic) ? [path stringByAppendingFormat:@".%d.tmp", getpid()] : path;
    int fd = open([target fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
    BOOL ok = fd >= 0;
    if (ok) {
        const char *p = [self bytes];
        NSUInteger left = [self length];
        while (ok && left) {
            ssize_t w = write(fd, p, left);
            if (w < 0) ok = errno == EINTR;
            else { p += w; left -= (NSUInteger)w; }
        }
        ok = close(fd) == 0 && ok;
    }
    if (ok && target != path) ok = rename([target fileSystemRepresentation], [path fileSystemRepresentation]) == 0;
    if (!ok && errorPtr)
        *errorPtr = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{ NSFilePathErrorKey: path }];
    return ok;
}

@end
