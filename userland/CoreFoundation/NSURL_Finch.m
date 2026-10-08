/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSURL, which Apple's CoreFoundation hosts (docs/design/FOUNDATION.md),
 * with __NSCFURL, the class of every CFURL (Apple's CFURLs are NSURL
 * itself; here the concrete class has its own name, as for the other
 * bridged types). +alloc returns a placeholder whose -init... make CFURLs;
 * the accessors are CF's, with NSURL's conventions on top: -path is the
 * decoded file-system path, -port an NSNumber, a description "relative --
 * base" when there's a base.
 */
#include "CFObjCClasses_Finch.h"
#include <sys/stat.h>
#include "CFURLComponents.h"

@interface NSURL (FinchDecls)
- (id)path;
@end
@interface NSNumber (FinchURL)
+ (id)numberWithInt:(int)v;
@end
@interface NSArray (FinchURL)
+ (instancetype)arrayWithObjects:(const id *)objects count:(NSUInteger)count;
@end

@interface __NSPlaceholderURL : NSURL
@end
@interface __NSCFURL : NSURL
@end

static __NSPlaceholderURL *placeholder;

CF_PRIVATE Class
__CFFinchInitializeURLClasses(void)
{
    placeholder = class_createInstance([__NSPlaceholderURL class], 0);
    return [__NSCFURL class];
}

static id
autoreleased(CFTypeRef cf)
{
    return cf ? [(id)cf autorelease] : nil;
}

static BOOL
is_directory(CFStringRef path)
{
    char buf[PATH_MAX];
    struct stat st;
    return CFStringGetFileSystemRepresentation(path, buf, sizeof(buf)) && stat(buf, &st) == 0 && S_ISDIR(st.st_mode);
}

@implementation NSURL

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSURL class] || self == [__NSCFURL class]) return (id)placeholder;
    return [super allocWithZone:zone];
}

+ (instancetype)URLWithString:(id)s { return [[[self alloc] initWithString:s] autorelease]; }
+ (instancetype)URLWithString:(id)s relativeToURL:(NSURL *)base { return [[[self alloc] initWithString:s relativeToURL:base] autorelease]; }
+ (instancetype)fileURLWithPath:(id)path { return [[[self alloc] initFileURLWithPath:path] autorelease]; }
+ (instancetype)fileURLWithPath:(id)path isDirectory:(BOOL)dir
{
    return [[[self alloc] initFileURLWithPath:path isDirectory:dir] autorelease];
}
+ (instancetype)fileURLWithPath:(id)path relativeToURL:(NSURL *)base
{
    return [[[self alloc] initFileURLWithPath:path relativeToURL:base] autorelease];
}
+ (instancetype)fileURLWithPath:(id)path isDirectory:(BOOL)dir relativeToURL:(NSURL *)base
{
    return [[[self alloc] initFileURLWithPath:path isDirectory:dir relativeToURL:base] autorelease];
}
+ (instancetype)fileURLWithFileSystemRepresentation:(const char *)path isDirectory:(BOOL)dir relativeToURL:(NSURL *)base
{
    return [[[self alloc] initFileURLWithFileSystemRepresentation:path isDirectory:dir relativeToURL:base] autorelease];
}
+ (instancetype)URLWithDataRepresentation:(id)data relativeToURL:(NSURL *)base
{
    return autoreleased(CFURLCreateWithBytes(NULL, CFDataGetBytePtr((CFDataRef)data), CFDataGetLength((CFDataRef)data),
        kCFStringEncodingUTF8, (CFURLRef)base));
}

- (CFURLRef)_cfurl { return (CFURLRef)self; }
- (CFTypeID)_cfTypeID { return CFURLGetTypeID(); }
- (BOOL)isNSURL__ { return YES; }
- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }

- (id)absoluteString
{
    CFURLRef abs = CFURLCopyAbsoluteURL((CFURLRef)self);
    if (!abs) return nil;
    CFStringRef s = CFRetain(CFURLGetString(abs));
    CFRelease(abs);
    return autoreleased(s);
}
- (id)relativeString { return (id)CFURLGetString((CFURLRef)self); }
- (NSURL *)baseURL { return (NSURL *)CFURLGetBaseURL((CFURLRef)self); }
- (NSURL *)absoluteURL
{
    if (!CFURLGetBaseURL((CFURLRef)self)) return self;
    return autoreleased(CFURLCopyAbsoluteURL((CFURLRef)self));
}
- (id)scheme { return autoreleased(CFURLCopyScheme((CFURLRef)self)); }
- (id)resourceSpecifier { return autoreleased(CFURLCopyResourceSpecifier((CFURLRef)self)); }
- (id)host { return autoreleased(CFURLCopyHostName((CFURLRef)self)); }
- (id)port
{
    SInt32 p = CFURLGetPortNumber((CFURLRef)self);
    return p < 0 ? nil : [NSNumber numberWithInt:p];
}
- (id)user { return autoreleased(CFURLCopyUserName((CFURLRef)self)); }
- (id)password { return autoreleased(CFURLCopyPassword((CFURLRef)self)); }
- (id)path
{
    CFURLRef abs = CFURLCopyAbsoluteURL((CFURLRef)self);
    CFStringRef p = abs ? CFURLCopyFileSystemPath(abs, kCFURLPOSIXPathStyle) : NULL;
    if (abs) CFRelease(abs);
    return autoreleased(p);
}
- (id)relativePath { return autoreleased(CFURLCopyFileSystemPath((CFURLRef)self, kCFURLPOSIXPathStyle)); }
- (id)query { return autoreleased(CFURLCopyQueryString((CFURLRef)self, NULL)); }
- (id)fragment { return autoreleased(CFURLCopyFragment((CFURLRef)self, NULL)); }
- (id)parameterString { return autoreleased(CFURLCopyParameterString((CFURLRef)self, NULL)); }
- (id)lastPathComponent { return autoreleased(CFURLCopyLastPathComponent((CFURLRef)self)); }
- (id)pathExtension
{
    CFStringRef e = CFURLCopyPathExtension((CFURLRef)self);
    return e ? autoreleased(e) : (id)CFSTR("");
}
- (BOOL)isFileURL
{
    CFStringRef s = CFURLCopyScheme((CFURLRef)self);
    BOOL file = s && CFStringCompare(s, CFSTR("file"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    if (s) CFRelease(s);
    return file;
}
- (BOOL)hasDirectoryPath { return CFURLHasDirectoryPath((CFURLRef)self); }

- (id)pathComponents
{
    id path = [self path];
    if (!path) return nil;
    CFArrayRef parts = CFStringCreateArrayBySeparatingStrings(NULL, (CFStringRef)path, CFSTR("/"));
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (CFStringHasPrefix((CFStringRef)path, CFSTR("/"))) CFArrayAppendValue(out, CFSTR("/"));
    for (CFIndex i = 0; i < CFArrayGetCount(parts); i++) {
        CFStringRef c = CFArrayGetValueAtIndex(parts, i);
        if (CFStringGetLength(c)) CFArrayAppendValue(out, c);
    }
    if (CFURLHasDirectoryPath((CFURLRef)self) && CFArrayGetCount(out) > 1) CFArrayAppendValue(out, CFSTR("/"));
    CFRelease(parts);
    return autoreleased(out);
}

- (const char *)fileSystemRepresentation
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, PATH_MAX);
    CFDataSetLength(d, PATH_MAX);
    if (!CFURLGetFileSystemRepresentation((CFURLRef)self, true, CFDataGetMutableBytePtr(d), PATH_MAX)) {
        CFRelease(d);
        return NULL;
    }
    [(id)d autorelease];
    return (const char *)CFDataGetBytePtr(d);
}

- (BOOL)getFileSystemRepresentation:(char *)buffer maxLength:(NSUInteger)max
{
    return CFURLGetFileSystemRepresentation((CFURLRef)self, true, (UInt8 *)buffer, (CFIndex)max);
}

- (id)dataRepresentation
{
    CFIndex n = CFURLGetBytes((CFURLRef)self, NULL, 0);
    CFMutableDataRef d = CFDataCreateMutable(NULL, n);
    CFDataSetLength(d, n);
    CFURLGetBytes((CFURLRef)self, CFDataGetMutableBytePtr(d), n);
    return autoreleased(d);
}

- (NSURL *)URLByAppendingPathComponent:(id)component
{
    BOOL dir = NO;
    if ([self isFileURL]) {
        NSURL *probe = autoreleased(CFURLCreateCopyAppendingPathComponent(NULL, (CFURLRef)self, (CFStringRef)component, false));
        id p = [probe path];
        dir = p && is_directory((CFStringRef)p);
    }
    return [self URLByAppendingPathComponent:component isDirectory:dir];
}
- (NSURL *)URLByAppendingPathComponent:(id)component isDirectory:(BOOL)dir
{
    return autoreleased(CFURLCreateCopyAppendingPathComponent(NULL, (CFURLRef)self, (CFStringRef)component, dir));
}
- (NSURL *)URLByDeletingLastPathComponent { return autoreleased(CFURLCreateCopyDeletingLastPathComponent(NULL, (CFURLRef)self)); }
- (NSURL *)URLByAppendingPathExtension:(id)ext { return autoreleased(CFURLCreateCopyAppendingPathExtension(NULL, (CFURLRef)self, (CFStringRef)ext)); }
- (NSURL *)URLByDeletingPathExtension { return autoreleased(CFURLCreateCopyDeletingPathExtension(NULL, (CFURLRef)self)); }

/* RFC 3986's remove_dot_segments on the (percent-encoded) path. */
static CFStringRef
remove_dot_segments(CFStringRef path)
{
    CFArrayRef parts = CFStringCreateArrayBySeparatingStrings(NULL, path, CFSTR("/"));
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFIndex n = CFArrayGetCount(parts);
    for (CFIndex i = 0; i < n; i++) {
        CFStringRef c = CFArrayGetValueAtIndex(parts, i);
        BOOL last = i == n - 1;
        if (CFEqual(c, CFSTR("."))) {
            if (last) CFArrayAppendValue(out, CFSTR(""));
        } else if (CFEqual(c, CFSTR(".."))) {
            if (CFArrayGetCount(out) > 1) CFArrayRemoveValueAtIndex(out, CFArrayGetCount(out) - 1);
            if (last) CFArrayAppendValue(out, CFSTR(""));
        } else {
            CFArrayAppendValue(out, c);
        }
    }
    CFStringRef r = CFStringCreateByCombiningStrings(NULL, out, CFSTR("/"));
    CFRelease(parts);
    CFRelease(out);
    return r;
}

- (NSURL *)standardizedURL
{
    CFURLRef abs = CFURLCopyAbsoluteURL((CFURLRef)self);
    CFURLComponentsRef c = abs ? _CFURLComponentsCreateWithURL(NULL, abs, true) : NULL;
    if (abs) CFRelease(abs);
    if (!c) return self;
    CFStringRef p = _CFURLComponentsCopyPercentEncodedPath(c);
    if (p) {
        CFStringRef clean = remove_dot_segments(p);
        _CFURLComponentsSetPercentEncodedPath(c, clean);
        CFRelease(clean);
        CFRelease(p);
    }
    CFURLRef u = _CFURLComponentsCopyURL(c);
    CFRelease(c);
    return u ? autoreleased(u) : self;
}

- (NSURL *)URLByStandardizingPath
{
    if (![self isFileURL]) return self;
    CFStringRef p = (CFStringRef)[self path];
    CFArrayRef parts = CFStringCreateArrayBySeparatingStrings(NULL, p, CFSTR("/"));
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(parts); i++) {
        CFStringRef c = CFArrayGetValueAtIndex(parts, i);
        if (CFStringGetLength(c) == 0 || CFEqual(c, CFSTR("."))) continue;
        if (CFEqual(c, CFSTR("..")) && CFArrayGetCount(out)) { CFArrayRemoveValueAtIndex(out, CFArrayGetCount(out) - 1); continue; }
        CFArrayAppendValue(out, c);
    }
    CFStringRef joined = CFStringCreateByCombiningStrings(NULL, out, CFSTR("/"));
    CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/%@"), joined);
    NSURL *u = autoreleased(CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, CFURLHasDirectoryPath((CFURLRef)self)));
    CFRelease(parts); CFRelease(out); CFRelease(joined); CFRelease(path);
    return u;
}

- (NSURL *)URLByResolvingSymlinksInPath
{
    char real[PATH_MAX];
    const char *fs = [self fileSystemRepresentation];
    if (!fs || !realpath(fs, real)) return [self URLByStandardizingPath];
    return autoreleased(CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)real, (CFIndex)strlen(real),
        CFURLHasDirectoryPath((CFURLRef)self)));
}

- (NSURL *)filePathURL { return [self isFileURL] ? self : nil; }
- (NSURL *)fileReferenceURL { return [self isFileURL] ? self : nil; }
- (BOOL)isFileReferenceURL { return NO; }

- (BOOL)checkResourceIsReachableAndReturnError:(id *)error
{
    struct stat st;
    const char *fs = [self isFileURL] ? [self fileSystemRepresentation] : NULL;
    if (fs && stat(fs, &st) == 0) return YES;
    if (error) *error = nil;
    return NO;
}

- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }

- (id)description
{
    CFURLRef base = CFURLGetBaseURL((CFURLRef)self);
    if (!base) return (id)CFURLGetString((CFURLRef)self);
    return autoreleased(CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ -- %@"), CFURLGetString((CFURLRef)self), [(id)base description]));
}

@end

@implementation __NSPlaceholderURL

FINCH_IMMORTAL_MEMORY

- (instancetype)initWithString:(id)s { return [self initWithString:s relativeToURL:nil]; }
- (instancetype)initWithString:(id)s relativeToURL:(NSURL *)base
{
    if (!s) __CFFinchRaise(NSInvalidArgumentException, "*** -[NSURL initWithString:relativeToURL:]: nil string parameter");
    return (id)CFURLCreateWithString(NULL, (CFStringRef)s, (CFURLRef)base);
}
- (instancetype)initFileURLWithPath:(id)path
{
    return [self initFileURLWithPath:path isDirectory:CFStringHasSuffix((CFStringRef)path, CFSTR("/")) || is_directory((CFStringRef)path)
        relativeToURL:nil];
}
- (instancetype)initFileURLWithPath:(id)path isDirectory:(BOOL)dir { return [self initFileURLWithPath:path isDirectory:dir relativeToURL:nil]; }
- (instancetype)initFileURLWithPath:(id)path relativeToURL:(NSURL *)base
{
    return [self initFileURLWithPath:path isDirectory:is_directory((CFStringRef)path) relativeToURL:base];
}
- (instancetype)initFileURLWithPath:(id)path isDirectory:(BOOL)dir relativeToURL:(NSURL *)base
{
    if (!path) __CFFinchRaise(NSInvalidArgumentException, "*** -[NSURL initFileURLWithPath:]: nil string parameter");
    if (!base && !CFStringHasPrefix((CFStringRef)path, CFSTR("/"))) {
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd))) {
            CFURLRef cwdURL = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)cwd, (CFIndex)strlen(cwd), true);
            id r = (id)CFURLCreateWithFileSystemPathRelativeToBase(NULL, (CFStringRef)path, kCFURLPOSIXPathStyle, dir, cwdURL);
            CFRelease(cwdURL);
            return r;
        }
    }
    return (id)CFURLCreateWithFileSystemPathRelativeToBase(NULL, (CFStringRef)path, kCFURLPOSIXPathStyle, dir, (CFURLRef)base);
}
- (instancetype)initFileURLWithFileSystemRepresentation:(const char *)path isDirectory:(BOOL)dir relativeToURL:(NSURL *)base
{
    return (id)CFURLCreateFromFileSystemRepresentationRelativeToBase(NULL, (const UInt8 *)path, (CFIndex)strlen(path), dir, (CFURLRef)base);
}

@end

@implementation __NSCFURL
FINCH_CF_OBJECT_MEMORY
@end
