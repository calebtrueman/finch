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

CF_EXPORT CFStringRef _CFStringCreateWithFormatAndArgumentsAux2(CFAllocatorRef, CFStringRef (*)(void *, const void *),
    CFStringRef (*)(void *, const void *, const void *, bool, bool *), CFDictionaryRef, CFStringRef, va_list);

/* MARK: - Helpers (Foundation_Finch.h) */

void
FinchRaise(NSString *name, const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    CFStringRef f = CFStringCreateWithCString(NULL, format, kCFStringEncodingUTF8);
    CFStringRef r = FinchCreateWithFormat(NULL, f, ap);
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

static CFStringRef
copy_description(void *object, const void *options)
{
    NSString *d = [(id)object description];
    return d ? CFRetain((CFStringRef)d) : CFSTR("(null)");
}

CFStringRef
FinchCreateWithFormat(CFDictionaryRef options, CFStringRef format, va_list args)
{
    return _CFStringCreateWithFormatAndArgumentsAux2(NULL, copy_description, NULL, options, format, args);
}

/* MARK: - Functions */

/* NSObject.h's allocation functions. Zones are gone; the extra reference
 * counts live in a side table for classes that count their own. */
id
NSAllocateObject(Class aClass, NSUInteger extraBytes, NSZone *zone)
{
    return class_createInstance(aClass, extraBytes);
}

void
NSDeallocateObject(id object)
{
    object_dispose(object);
}

id
NSCopyObject(id object, NSUInteger extraBytes, NSZone *zone)
{
    return object_copy(object, class_getInstanceSize(object_getClass(object)) + extraBytes);
}

BOOL
NSShouldRetainWithZone(id anObject, NSZone *requestedZone)
{
    return YES;
}

static pthread_mutex_t extra_lock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef extra_counts;

void
NSIncrementExtraRefCount(id object)
{
    pthread_mutex_lock(&extra_lock);
    if (!extra_counts) extra_counts = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    uintptr_t n = (uintptr_t)CFDictionaryGetValue(extra_counts, object);
    CFDictionarySetValue(extra_counts, object, (const void *)(n + 1));
    pthread_mutex_unlock(&extra_lock);
}

BOOL
NSDecrementExtraRefCountWasZero(id object)
{
    pthread_mutex_lock(&extra_lock);
    uintptr_t n = extra_counts ? (uintptr_t)CFDictionaryGetValue(extra_counts, object) : 0;
    if (n > 1) CFDictionarySetValue(extra_counts, object, (const void *)(n - 1));
    else if (n == 1) CFDictionaryRemoveValue(extra_counts, object);
    pthread_mutex_unlock(&extra_lock);
    return n == 0;
}

NSUInteger
NSExtraRefCount(id object)
{
    pthread_mutex_lock(&extra_lock);
    uintptr_t n = extra_counts ? (uintptr_t)CFDictionaryGetValue(extra_counts, object) : 0;
    pthread_mutex_unlock(&extra_lock);
    return n;
}

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

NSRange
NSUnionRange(NSRange a, NSRange b)
{
    NSUInteger start = MIN(a.location, b.location), end = MAX(NSMaxRange(a), NSMaxRange(b));
    return NSMakeRange(start, end - start);
}

NSRange
NSIntersectionRange(NSRange a, NSRange b)
{
    NSUInteger start = MAX(a.location, b.location), end = MIN(NSMaxRange(a), NSMaxRange(b));
    return end > start ? NSMakeRange(start, end - start) : NSMakeRange(0, 0);
}

/* "{3, 4}" or any text with two numbers in it, as Apple's. */
NSRange
NSRangeFromString(NSString *s)
{
    NSUInteger v[2] = { 0, 0 }, n = 0, len = [s length];
    for (NSUInteger i = 0; i < len && n < 2;) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') {
            NSUInteger x = 0;
            while (i < len && (c = [s characterAtIndex:i]) >= '0' && c <= '9') { x = x * 10 + (c - '0'); i++; }
            v[n++] = x;
        } else {
            i++;
        }
    }
    return NSMakeRange(v[0], v[1]);
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
    CFStringRef msg = FinchCreateWithFormat(NULL, (CFStringRef)format, args);
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

- (NSArray *)sortedArrayWithOptions:(NSSortOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmptr
{
    return [self sortedArrayUsingComparator:cmptr];
}

- (NSArray *)sortedArrayUsingFunction:(NSInteger (NS_NOESCAPE *)(id, id, void *))comparator context:(void *)context
{
    NSMutableArray *m = [[self mutableCopy] autorelease];
    [m sortUsingFunction:comparator context:context];
    return [NSArray arrayWithArray:m];
}

- (NSArray *)sortedArrayUsingFunction:(NSInteger (NS_NOESCAPE *)(id, id, void *))comparator context:(void *)context hint:(NSData *)hint
{
    return [self sortedArrayUsingFunction:comparator context:context];
}

- (NSData *)sortedArrayHint { return [NSData data]; }

/* Binary search, as Apple's: the range must be sorted by `cmp`. */
- (NSUInteger)indexOfObject:(id)obj inSortedRange:(NSRange)r options:(NSBinarySearchingOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmp
{
    if (NSMaxRange(r) > [self count])
        FinchRaise(NSRangeException, "*** -[NSArray indexOfObject:inSortedRange:options:usingComparator:]: range {%lu, %lu} extends beyond bounds [0 .. %lu]",
            (unsigned long)r.location, (unsigned long)r.length, (unsigned long)([self count] ? [self count] - 1 : 0));
    BOOL first = (opts & NSBinarySearchingFirstEqual) != 0, last = (opts & NSBinarySearchingLastEqual) != 0;
    BOOL insert = (opts & NSBinarySearchingInsertionIndex) != 0;
    NSUInteger lo = r.location, hi = NSMaxRange(r), found = NSNotFound;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        NSComparisonResult c = cmp([self objectAtIndex:mid], obj);
        if (c == NSOrderedSame) {
            found = mid;
            if (first || (insert && !last)) hi = mid;
            else if (last) lo = mid + 1;
            else break;
        } else if (c == NSOrderedAscending) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (insert) return found != NSNotFound && !last && !first ? found : (last && found != NSNotFound ? found + 1 : lo);
    return found;
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
- (void)sortWithOptions:(NSSortOptions)opts usingComparator:(NSComparator NS_NOESCAPE)cmptr { sort(self, block_compare, cmptr); }

typedef struct {
    NSInteger (*fn)(id, id, void *);
    void *context;
} FunctionComparison;

static CFComparisonResult
function_compare(const void *a, const void *b, void *context)
{
    FunctionComparison *f = context;
    return (CFComparisonResult)f->fn((id)a, (id)b, f->context);
}

- (void)sortUsingFunction:(NSInteger (NS_NOESCAPE *)(id, id, void *))compare context:(void *)context
{
    FunctionComparison f = { compare, context };
    sort(self, function_compare, &f);
}

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
