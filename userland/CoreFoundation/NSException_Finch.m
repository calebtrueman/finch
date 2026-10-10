/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSException and the standard exception names, which Apple's CoreFoundation
 * hosts and exports (docs/design/FOUNDATION.md). The ivars are Apple's
 * (name, reason, userInfo, reserved: 40-byte instances). Raising throws
 * through libobjc. An exception nothing catches is reported as Apple's is
 * ("*** Terminating app due to uncaught exception ...") before abort().
 */
#include "CFObjCClasses_Finch.h"
#include <execinfo.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

extern void objc_exception_throw(id exception) __attribute__((noreturn));
typedef void (*objc_uncaught_exception_handler)(id exception);
extern objc_uncaught_exception_handler objc_setUncaughtExceptionHandler(objc_uncaught_exception_handler fn);
typedef id (*objc_exception_preprocessor)(id exception);
extern objc_exception_preprocessor objc_setExceptionPreprocessor(objc_exception_preprocessor fn);

NSExceptionName const NSGenericException = (NSString *)CFSTR("NSGenericException");
NSExceptionName const NSRangeException = (NSString *)CFSTR("NSRangeException");
NSExceptionName const NSInvalidArgumentException = (NSString *)CFSTR("NSInvalidArgumentException");
NSExceptionName const NSInternalInconsistencyException = (NSString *)CFSTR("NSInternalInconsistencyException");
NSExceptionName const NSMallocException = (NSString *)CFSTR("NSMallocException");

__attribute__((objc_exception))   /* exports OBJC_EHTYPE_$_NSException, for @catch (NSException *) */
@interface NSException : NSObject <NSCopying> {
    NSString *name;
    NSString *reason;
    NSDictionary *userInfo;
    id reserved;
}
+ (instancetype)exceptionWithName:(NSString *)name reason:(NSString *)reason userInfo:(NSDictionary *)userInfo;
- (instancetype)initWithName:(NSString *)name reason:(NSString *)reason userInfo:(NSDictionary *)userInfo;
+ (void)raise:(NSString *)name format:(NSString *)format, ...;
+ (void)raise:(NSString *)name format:(NSString *)format arguments:(va_list)args;
- (void)raise;
- (NSString *)name;
- (NSString *)reason;
- (NSDictionary *)userInfo;
@end

@implementation NSException

+ (instancetype)exceptionWithName:(NSString *)n reason:(NSString *)r userInfo:(NSDictionary *)u
{
    return [[[self alloc] initWithName:n reason:r userInfo:u] autorelease];
}

- (instancetype)initWithName:(NSString *)n reason:(NSString *)r userInfo:(NSDictionary *)u
{
    if ((self = [super init])) {
        name = [n copy];
        reason = [r copy];
        userInfo = [(id)u copy];
    }
    return self;
}

/* %@ as Foundation formats it: the object's -description. */
static CFStringRef
copy_description(void *object, const void *options)
{
    NSString *d = [(id)object description];
    return d ? CFRetain((CFStringRef)d) : CFSTR("(null)");
}

static CFStringRef
create_reason(CFStringRef format, va_list args)
{
    return _CFStringCreateWithFormatAndArgumentsAux2(NULL, copy_description, NULL, NULL, format, args);
}

+ (void)raise:(NSString *)n format:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    [self raise:n format:format arguments:args];
    va_end(args);
}

+ (void)raise:(NSString *)n format:(NSString *)format arguments:(va_list)args
{
    CFStringRef r = create_reason((CFStringRef)format, args);
    NSException *e = [self exceptionWithName:n reason:(NSString *)r userInfo:nil];
    CFRelease(r);
    [e raise];
}

- (void)raise { objc_exception_throw(self); }
- (NSString *)name { return name; }
- (NSString *)reason { return reason; }
- (NSDictionary *)userInfo { return userInfo; }
- (NSString *)description { return reason ? reason : name; }
/* The stack where the exception was first thrown (reserved holds the return addresses,
   recorded by the throw preprocessor below), as Apple's records it. */
- (NSArray *)callStackReturnAddresses { return [reserved isKindOfClass:[NSArray class]] ? reserved : nil; }

- (NSArray *)callStackSymbols
{
    NSArray *addrs = [self callStackReturnAddresses];
    NSUInteger n = [addrs count];
    if (!n) return nil;
    void **frames = malloc(sizeof(void *) * n);
    for (NSUInteger i = 0; i < n; i++)
        frames[i] = (void *)[[addrs objectAtIndex:i] unsignedLongValue];
    char **syms = backtrace_symbols(frames, (int)n);
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, (CFIndex)n, &kCFTypeArrayCallBacks);
    for (NSUInteger i = 0; syms && i < n; i++) {
        CFStringRef str = CFStringCreateWithCString(NULL, syms[i], kCFStringEncodingUTF8);
        if (str) {
            CFArrayAppendValue(out, str);
            CFRelease(str);
        }
    }
    free(syms);
    free(frames);
    return [(NSArray *)out autorelease];
}

- (void)_finchRecordCallStack:(void *const *)frames count:(int)count
{
    if (reserved) return;
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (int i = 0; i < count; i++) {
        unsigned long v = (unsigned long)frames[i];
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberLongType, &v);
        CFArrayAppendValue(a, num);
        CFRelease(num);
    }
    reserved = (id)a;
}
- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (!other || !object_isClass(object_getClass(other)) || ![other isKindOfClass:[NSException class]]) return NO;
    NSException *o = other;
    return CFEqual((CFTypeRef)name, (CFTypeRef)o->name) &&
        (reason == o->reason || (reason && o->reason && CFEqual((CFTypeRef)reason, (CFTypeRef)o->reason)));
}

- (void)dealloc
{
    [name release];
    [reason release];
    [(id)userInfo release];
    [reserved release];
    [super dealloc];
}

@end

void
__CFFinchRaise(NSString *n, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    CFStringRef f = CFStringCreateWithCString(NULL, format, kCFStringEncodingUTF8);
    CFStringRef r = create_reason(f, args);
    va_end(args);
    CFRelease(f);
    NSException *e = [[NSException alloc] initWithName:n reason:(NSString *)r userInfo:nil];
    CFRelease(r);
    [[e autorelease] raise];
    __builtin_unreachable();
}

/* NSSetUncaughtExceptionHandler's (Foundation's API; CF holds it, as
 * Foundation re-exports CF). It runs first, then the default report. */
typedef void NSUncaughtExceptionHandler(NSException *exception);
static NSUncaughtExceptionHandler *user_handler;

CF_EXPORT NSUncaughtExceptionHandler *NSGetUncaughtExceptionHandler(void) { return user_handler; }
CF_EXPORT void NSSetUncaughtExceptionHandler(NSUncaughtExceptionHandler *handler) { user_handler = handler; }

/* Every throw: an NSException records where it was first thrown. */
static id
preprocess(id exception)
{
    if ([exception isKindOfClass:[NSException class]]) {
        void *frames[128];
        int n = backtrace(frames, 128);
        /* leave out this function and objc_exception_throw */
        int skip = n > 2 ? 2 : 0;
        [(NSException *)exception _finchRecordCallStack:frames + skip count:n - skip];
    }
    return exception;
}

static void
uncaught(id exception)
{
    if (user_handler && [exception isKindOfClass:[NSException class]]) user_handler(exception);
    char n[256] = "", r[1024] = "";
    if ([exception isKindOfClass:[NSException class]]) {
        NSException *e = exception;
        if ([e name]) CFStringGetCString((CFStringRef)[e name], n, sizeof(n), kCFStringEncodingUTF8);
        if ([e reason]) CFStringGetCString((CFStringRef)[e reason], r, sizeof(r), kCFStringEncodingUTF8);
        fprintf(stderr, "*** Terminating app due to uncaught exception '%s', reason: '%s'\n", n, r);
        NSArray *stack = [e callStackSymbols];
        if ([stack count]) {
            fprintf(stderr, "*** First throw call stack:\n(\n");
            for (NSString *line in stack)
                fprintf(stderr, "\t%s\n", [line UTF8String]);
            fprintf(stderr, ")\n");
        }
    } else {
        fprintf(stderr, "*** Terminating app due to uncaught exception of class '%s'\n", object_getClassName(exception));
    }
}

CF_PRIVATE void
__CFFinchInstallExceptionHandler(void)
{
    objc_setUncaughtExceptionHandler(uncaught);
    objc_setExceptionPreprocessor(preprocess);
}
