/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSFileManager, NSDirectoryEnumerator, the file-attribute keys and
 * NSSearchPathForDirectoriesInDomains (docs/design/FOUNDATION.md), against
 * the SDK's declarations, over POSIX. Errors are NSCocoaErrorDomain with
 * Apple's codes, carrying the path and the POSIX error underneath.
 */
#import <Foundation/Foundation.h>
#include <copyfile.h>
#include <dirent.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <sys/mount.h>
#include <sysdir.h>
#include <sys/stat.h>
#include <unistd.h>

#include "Foundation_Finch.h"

NSFileAttributeKey const NSFileType = @"NSFileType";
NSFileAttributeType const NSFileTypeDirectory = @"NSFileTypeDirectory";
NSFileAttributeType const NSFileTypeRegular = @"NSFileTypeRegular";
NSFileAttributeType const NSFileTypeSymbolicLink = @"NSFileTypeSymbolicLink";
NSFileAttributeType const NSFileTypeSocket = @"NSFileTypeSocket";
NSFileAttributeType const NSFileTypeCharacterSpecial = @"NSFileTypeCharacterSpecial";
NSFileAttributeType const NSFileTypeBlockSpecial = @"NSFileTypeBlockSpecial";
NSFileAttributeType const NSFileTypeUnknown = @"NSFileTypeUnknown";
NSFileAttributeKey const NSFileSize = @"NSFileSize";
NSFileAttributeKey const NSFileModificationDate = @"NSFileModificationDate";
NSFileAttributeKey const NSFileReferenceCount = @"NSFileReferenceCount";
NSFileAttributeKey const NSFileDeviceIdentifier = @"NSFileDeviceIdentifier";
NSFileAttributeKey const NSFileOwnerAccountName = @"NSFileOwnerAccountName";
NSFileAttributeKey const NSFileGroupOwnerAccountName = @"NSFileGroupOwnerAccountName";
NSFileAttributeKey const NSFilePosixPermissions = @"NSFilePosixPermissions";
NSFileAttributeKey const NSFileSystemNumber = @"NSFileSystemNumber";
NSFileAttributeKey const NSFileSystemFileNumber = @"NSFileSystemFileNumber";
NSFileAttributeKey const NSFileExtensionHidden = @"NSFileExtensionHidden";
NSFileAttributeKey const NSFileHFSCreatorCode = @"NSFileHFSCreatorCode";
NSFileAttributeKey const NSFileHFSTypeCode = @"NSFileHFSTypeCode";
NSFileAttributeKey const NSFileImmutable = @"NSFileImmutable";
NSFileAttributeKey const NSFileAppendOnly = @"NSFileAppendOnly";
NSFileAttributeKey const NSFileCreationDate = @"NSFileCreationDate";
NSFileAttributeKey const NSFileOwnerAccountID = @"NSFileOwnerAccountID";
NSFileAttributeKey const NSFileGroupOwnerAccountID = @"NSFileGroupOwnerAccountID";
NSFileAttributeKey const NSFileBusy = @"NSFileBusy";
NSFileAttributeKey const NSFileProtectionKey = @"NSFileProtectionKey";
NSFileAttributeKey const NSFileSystemSize = @"NSFileSystemSize";
NSFileAttributeKey const NSFileSystemFreeSize = @"NSFileSystemFreeSize";
NSFileAttributeKey const NSFileSystemNodes = @"NSFileSystemNodes";
NSFileAttributeKey const NSFileSystemFreeNodes = @"NSFileSystemFreeNodes";

/* An NSCocoaErrorDomain error for a failed POSIX call (errno). */
static NSError *
file_error(NSInteger readOrWrite, int err, NSString *path)
{
    NSInteger code;
    switch (err) {
    case ENOENT: code = readOrWrite ? NSFileNoSuchFileError : NSFileReadNoSuchFileError; break;
    case EEXIST: code = NSFileWriteFileExistsError; break;
    case EACCES: case EPERM: code = readOrWrite ? NSFileWriteNoPermissionError : NSFileReadNoPermissionError; break;
    case ENOSPC: code = NSFileWriteOutOfSpaceError; break;
    case EROFS: code = NSFileWriteVolumeReadOnlyError; break;
    case ENAMETOOLONG: code = NSFileReadInvalidFileNameError; break;
    default: code = readOrWrite ? NSFileWriteUnknownError : NSFileReadUnknownError; break;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (path) [info setObject:path forKey:NSFilePathErrorKey];
    [info setObject:[NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil] forKey:NSUnderlyingErrorKey];
    return [NSError errorWithDomain:NSCocoaErrorDomain code:code userInfo:info];
}

#define FAIL(rw, path) do { if (error) *error = file_error((rw), errno, (path)); return NO; } while (0)

static NSDictionary *
attributes_of(struct stat *st)
{
    NSString *type;
    switch (st->st_mode & S_IFMT) {
    case S_IFDIR: type = NSFileTypeDirectory; break;
    case S_IFREG: type = NSFileTypeRegular; break;
    case S_IFLNK: type = NSFileTypeSymbolicLink; break;
    case S_IFSOCK: type = NSFileTypeSocket; break;
    case S_IFCHR: type = NSFileTypeCharacterSpecial; break;
    case S_IFBLK: type = NSFileTypeBlockSpecial; break;
    default: type = NSFileTypeUnknown; break;
    }
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    [a setObject:type forKey:NSFileType];
    [a setObject:[NSNumber numberWithUnsignedLongLong:(unsigned long long)st->st_size] forKey:NSFileSize];
    [a setObject:[NSDate dateWithTimeIntervalSince1970:st->st_mtimespec.tv_sec + st->st_mtimespec.tv_nsec / 1e9] forKey:NSFileModificationDate];
    [a setObject:[NSDate dateWithTimeIntervalSince1970:st->st_birthtimespec.tv_sec + st->st_birthtimespec.tv_nsec / 1e9] forKey:NSFileCreationDate];
    [a setObject:[NSNumber numberWithUnsignedLong:st->st_nlink] forKey:NSFileReferenceCount];
    [a setObject:[NSNumber numberWithInt:st->st_rdev] forKey:NSFileDeviceIdentifier];
    [a setObject:[NSNumber numberWithUnsignedShort:st->st_mode & 07777] forKey:NSFilePosixPermissions];
    [a setObject:[NSNumber numberWithInt:st->st_dev] forKey:NSFileSystemNumber];
    [a setObject:[NSNumber numberWithUnsignedLongLong:st->st_ino] forKey:NSFileSystemFileNumber];
    [a setObject:[NSNumber numberWithUnsignedInt:st->st_uid] forKey:NSFileOwnerAccountID];
    [a setObject:[NSNumber numberWithUnsignedInt:st->st_gid] forKey:NSFileGroupOwnerAccountID];
    [a setObject:[NSNumber numberWithBool:(st->st_flags & (UF_IMMUTABLE | SF_IMMUTABLE)) != 0] forKey:NSFileImmutable];
    [a setObject:[NSNumber numberWithBool:(st->st_flags & (UF_APPEND | SF_APPEND)) != 0] forKey:NSFileAppendOnly];
    [a setObject:[NSNumber numberWithBool:NO] forKey:NSFileExtensionHidden];
    struct passwd *pw = getpwuid(st->st_uid);
    if (pw) [a setObject:[NSString stringWithUTF8String:pw->pw_name] forKey:NSFileOwnerAccountName];
    struct group *gr = getgrgid(st->st_gid);
    if (gr) [a setObject:[NSString stringWithUTF8String:gr->gr_name] forKey:NSFileGroupOwnerAccountName];
    return a;
}

/* MARK: - NSDirectoryEnumerator */

@interface __NSDirectoryEnumerator : NSDirectoryEnumerator {
@public
    NSString *_root;
    NSMutableArray *_stack;             /* arrays of remaining names, per level */
    NSMutableArray *_prefixes;          /* relative path of each level */
    NSString *_current;
    NSDictionary *_currentAttributes;
    BOOL _skipDescendants, _skipHidden, _noRecursion, _urls;
    NSURL *_rootURL;
}
@end

static NSArray *
entries(NSString *dir)
{
    DIR *d = opendir([dir fileSystemRepresentation]);
    if (!d) return nil;
    NSMutableArray *names = [NSMutableArray array];
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        [names addObject:[NSString stringWithUTF8String:e->d_name]];
    }
    closedir(d);
    return names;
}

/* The abstract class (Foundation exports it); the concrete one follows. */
@implementation NSDirectoryEnumerator
- (NSDictionary<NSFileAttributeKey, id> *)fileAttributes { return nil; }
- (NSDictionary<NSFileAttributeKey, id> *)directoryAttributes { return nil; }
- (NSUInteger)level { return 0; }
- (void)skipDescendents { }
- (void)skipDescendants { }
- (BOOL)isEnumeratingDirectoryPostOrder { return NO; }
@end

@implementation __NSDirectoryEnumerator

- (void)dealloc
{
    [_root release];
    [_stack release];
    [_prefixes release];
    [_current release];
    [_currentAttributes release];
    [_rootURL release];
    [super dealloc];
}

- (id)nextObject
{
    /* Descend into the last directory returned, unless told not to. */
    if (_current && !_skipDescendants && !_noRecursion &&
        [[_currentAttributes objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory]) {
        NSArray *names = entries([_root stringByAppendingPathComponent:_current]);
        if (names) {
            [_stack addObject:[[names mutableCopy] autorelease]];
            [_prefixes addObject:_current];
        }
    }
    _skipDescendants = NO;
    for (;;) {
        NSMutableArray *level = [_stack lastObject];
        if (!level) {
            [_current release];
            _current = nil;
            return nil;
        }
        if ([level count] == 0) {
            [_stack removeLastObject];
            [_prefixes removeLastObject];
            continue;
        }
        NSString *name = [[[level objectAtIndex:0] retain] autorelease];
        [level removeObjectAtIndex:0];
        if (_skipHidden && [name hasPrefix:@"."]) continue;
        NSString *prefix = [_prefixes lastObject];
        NSString *rel = [prefix length] ? [prefix stringByAppendingPathComponent:name] : name;
        struct stat st;
        NSString *full = [_root stringByAppendingPathComponent:rel];
        [_currentAttributes release];
        _currentAttributes = lstat([full fileSystemRepresentation], &st) == 0 ? [attributes_of(&st) retain] : nil;
        [_current release];
        _current = [rel retain];
        if (_urls) return [NSURL fileURLWithPath:full isDirectory:[[_currentAttributes objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory]];
        return rel;
    }
}

/* One entry at a time, so -skipDescendants applies to the entry the loop
 * body is looking at (fast enumeration would otherwise read ahead). */
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    static unsigned long never_mutated;
    id o = [self nextObject];
    state->state = 1;
    state->itemsPtr = buffer;
    state->mutationsPtr = &never_mutated;
    if (!o) return 0;
    buffer[0] = o;
    return 1;
}

- (NSDictionary<NSFileAttributeKey, id> *)fileAttributes { return _currentAttributes; }
- (NSDictionary<NSFileAttributeKey, id> *)directoryAttributes
{
    struct stat st;
    return lstat([_root fileSystemRepresentation], &st) == 0 ? attributes_of(&st) : nil;
}
- (NSUInteger)level { return [_stack count]; }
- (void)skipDescendents { _skipDescendants = YES; }
- (void)skipDescendants { _skipDescendants = YES; }
- (BOOL)isEnumeratingDirectoryPostOrder { return NO; }

@end

/* MARK: - NSFileManager */

@implementation NSFileManager

+ (NSFileManager *)defaultManager
{
    static NSFileManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[NSFileManager alloc] init]; });
    return m;
}

- (BOOL)fileExistsAtPath:(NSString *)path
{
    struct stat st;
    return path && stat([path fileSystemRepresentation], &st) == 0;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory
{
    struct stat st;
    if (!path || stat([path fileSystemRepresentation], &st) != 0) return NO;
    if (isDirectory) *isDirectory = S_ISDIR(st.st_mode);
    return YES;
}

- (BOOL)isReadableFileAtPath:(NSString *)path { return path && access([path fileSystemRepresentation], R_OK) == 0; }
- (BOOL)isWritableFileAtPath:(NSString *)path { return path && access([path fileSystemRepresentation], W_OK) == 0; }
- (BOOL)isExecutableFileAtPath:(NSString *)path { return path && access([path fileSystemRepresentation], X_OK) == 0; }
- (BOOL)isDeletableFileAtPath:(NSString *)path
{
    NSString *parent = [path stringByDeletingLastPathComponent];
    return path && access([([parent length] ? parent : @".") fileSystemRepresentation], W_OK) == 0;
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error
{
    NSArray *names = entries(path);
    if (!names && error) *error = file_error(0, errno, path);
    return names;
}

- (NSArray<NSURL *> *)contentsOfDirectoryAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys
                                       options:(NSDirectoryEnumerationOptions)mask error:(NSError **)error
{
    NSArray *names = [self contentsOfDirectoryAtPath:[url path] error:error];
    if (!names) return nil;
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *n in names) {
        if ((mask & NSDirectoryEnumerationSkipsHiddenFiles) && [n hasPrefix:@"."]) continue;
        NSString *full = [[url path] stringByAppendingPathComponent:n];
        BOOL dir = NO;
        [self fileExistsAtPath:full isDirectory:&dir];
        [urls addObject:[NSURL fileURLWithPath:full isDirectory:dir]];
    }
    return urls;
}

- (NSDirectoryEnumerator<NSString *> *)enumeratorAtPath:(NSString *)path
{
    BOOL dir = NO;
    if (![self fileExistsAtPath:path isDirectory:&dir] || !dir) return nil;
    __NSDirectoryEnumerator *e = [[[__NSDirectoryEnumerator alloc] init] autorelease];
    e->_root = [path copy];
    e->_stack = [[NSMutableArray alloc] initWithObjects:[[entries(path) mutableCopy] autorelease], nil];
    e->_prefixes = [[NSMutableArray alloc] initWithObjects:@"", nil];
    return e;
}

- (NSDirectoryEnumerator<NSURL *> *)enumeratorAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys
                                            options:(NSDirectoryEnumerationOptions)mask
                                       errorHandler:(BOOL (^)(NSURL *url, NSError *error))handler
{
    __NSDirectoryEnumerator *e = (__NSDirectoryEnumerator *)[self enumeratorAtPath:[url path]];
    e->_urls = YES;
    e->_skipHidden = (mask & NSDirectoryEnumerationSkipsHiddenFiles) != 0;
    e->_noRecursion = (mask & NSDirectoryEnumerationSkipsSubdirectoryDescendants) != 0;
    return (NSDirectoryEnumerator *)e;
}

- (NSArray<NSString *> *)subpathsOfDirectoryAtPath:(NSString *)path error:(NSError **)error
{
    NSDirectoryEnumerator *e = [self enumeratorAtPath:path];
    if (!e) {
        if (error) *error = file_error(0, ENOENT, path);
        return nil;
    }
    return [e allObjects];
}

- (NSArray<NSString *> *)subpathsAtPath:(NSString *)path { return [self subpathsOfDirectoryAtPath:path error:NULL]; }

- (BOOL)createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates
                   attributes:(NSDictionary<NSFileAttributeKey, id> *)attributes error:(NSError **)error
{
    mode_t mode = [attributes objectForKey:NSFilePosixPermissions] ? [[attributes objectForKey:NSFilePosixPermissions] unsignedShortValue] : 0777;
    if (createIntermediates) {
        BOOL dir = NO;
        if ([self fileExistsAtPath:path isDirectory:&dir]) {
            if (dir) return YES;
            errno = EEXIST;
            FAIL(1, path);
        }
        NSString *parent = [path stringByDeletingLastPathComponent];
        if ([parent length] && ![parent isEqualToString:path] &&
            ![self createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:attributes error:error])
            return NO;
    }
    if (mkdir([path fileSystemRepresentation], mode) != 0) {
        if (createIntermediates && errno == EEXIST) return YES;
        FAIL(1, path);
    }
    return YES;
}

- (BOOL)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)ci attributes:(NSDictionary *)a error:(NSError **)error
{
    return [self createDirectoryAtPath:[url path] withIntermediateDirectories:ci attributes:a error:error];
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary<NSFileAttributeKey, id> *)attr
{
    if (![(data ? data : [NSData data]) writeToFile:path atomically:YES]) return NO;
    if ([attr objectForKey:NSFilePosixPermissions])
        chmod([path fileSystemRepresentation], [[attr objectForKey:NSFilePosixPermissions] unsignedShortValue]);
    return YES;
}

- (NSData *)contentsAtPath:(NSString *)path { return [NSData dataWithContentsOfFile:path]; }

- (BOOL)contentsEqualAtPath:(NSString *)path1 andPath:(NSString *)path2
{
    NSData *a = [self contentsAtPath:path1], *b = [self contentsAtPath:path2];
    return a && b && [a isEqualToData:b];
}

static int
remove_tree(const char *path)
{
    struct stat st;
    if (lstat(path, &st) != 0) return -1;
    if (!S_ISDIR(st.st_mode)) return unlink(path);
    DIR *d = opendir(path);
    if (!d) return -1;
    struct dirent *e;
    int rc = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char child[PATH_MAX];
        snprintf(child, sizeof(child), "%s/%s", path, e->d_name);
        if (remove_tree(child) != 0) rc = -1;
    }
    int saved = errno;
    closedir(d);
    errno = saved;
    return rc == 0 ? rmdir(path) : -1;
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error
{
    if (!path) FinchRaise(NSInvalidArgumentException, "*** -[NSFileManager removeItemAtPath:error:]: path is nil");
    if (remove_tree([path fileSystemRepresentation]) != 0) FAIL(1, path);
    return YES;
}

- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error { return [self removeItemAtPath:[url path] error:error]; }

- (BOOL)moveItemAtPath:(NSString *)src toPath:(NSString *)dst error:(NSError **)error
{
    if ([self fileExistsAtPath:dst]) {
        errno = EEXIST;
        FAIL(1, dst);
    }
    if (rename([src fileSystemRepresentation], [dst fileSystemRepresentation]) == 0) return YES;
    if (errno != EXDEV) FAIL(1, src);
    if (![self copyItemAtPath:src toPath:dst error:error]) return NO;
    return [self removeItemAtPath:src error:error];
}

- (BOOL)moveItemAtURL:(NSURL *)src toURL:(NSURL *)dst error:(NSError **)error
{
    return [self moveItemAtPath:[src path] toPath:[dst path] error:error];
}

- (BOOL)copyItemAtPath:(NSString *)src toPath:(NSString *)dst error:(NSError **)error
{
    if ([self fileExistsAtPath:dst]) {
        errno = EEXIST;
        FAIL(1, dst);
    }
    if (copyfile([src fileSystemRepresentation], [dst fileSystemRepresentation], NULL, COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC) != 0)
        FAIL(0, src);
    return YES;
}

- (BOOL)copyItemAtURL:(NSURL *)src toURL:(NSURL *)dst error:(NSError **)error
{
    return [self copyItemAtPath:[src path] toPath:[dst path] error:error];
}

- (BOOL)linkItemAtPath:(NSString *)src toPath:(NSString *)dst error:(NSError **)error
{
    if (link([src fileSystemRepresentation], [dst fileSystemRepresentation]) != 0) FAIL(1, dst);
    return YES;
}

- (BOOL)createSymbolicLinkAtPath:(NSString *)path withDestinationPath:(NSString *)destPath error:(NSError **)error
{
    if (symlink([destPath fileSystemRepresentation], [path fileSystemRepresentation]) != 0) FAIL(1, path);
    return YES;
}

- (BOOL)createSymbolicLinkAtURL:(NSURL *)url withDestinationURL:(NSURL *)destURL error:(NSError **)error
{
    return [self createSymbolicLinkAtPath:[url path] withDestinationPath:[destURL isFileURL] ? [destURL path] : [destURL relativeString] error:error];
}

- (NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path error:(NSError **)error
{
    char buf[PATH_MAX];
    ssize_t n = readlink([path fileSystemRepresentation], buf, sizeof(buf) - 1);
    if (n < 0) {
        if (error) *error = file_error(0, errno, path);
        return nil;
    }
    buf[n] = 0;
    return [NSString stringWithUTF8String:buf];
}

- (NSDictionary<NSFileAttributeKey, id> *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error
{
    struct stat st;
    if (!path || lstat([path fileSystemRepresentation], &st) != 0) {
        if (error) *error = file_error(0, errno, path);
        return nil;
    }
    return attributes_of(&st);
}

- (NSDictionary<NSFileAttributeKey, id> *)attributesOfFileSystemForPath:(NSString *)path error:(NSError **)error
{
    struct statfs sf;
    if (statfs([path fileSystemRepresentation], &sf) != 0) {
        if (error) *error = file_error(0, errno, path);
        return nil;
    }
    return @{
        NSFileSystemSize: [NSNumber numberWithUnsignedLongLong:(unsigned long long)sf.f_blocks * sf.f_bsize],
        NSFileSystemFreeSize: [NSNumber numberWithUnsignedLongLong:(unsigned long long)sf.f_bavail * sf.f_bsize],
        NSFileSystemNodes: [NSNumber numberWithUnsignedLongLong:sf.f_files],
        NSFileSystemFreeNodes: [NSNumber numberWithUnsignedLongLong:sf.f_ffree],
        NSFileSystemNumber: [NSNumber numberWithInt:sf.f_fsid.val[0]],
    };
}

- (BOOL)setAttributes:(NSDictionary<NSFileAttributeKey, id> *)attributes ofItemAtPath:(NSString *)path error:(NSError **)error
{
    const char *p = [path fileSystemRepresentation];
    NSNumber *perm = [attributes objectForKey:NSFilePosixPermissions];
    if (perm && chmod(p, [perm unsignedShortValue]) != 0) FAIL(1, path);
    NSDate *mod = [attributes objectForKey:NSFileModificationDate];
    if (mod) {
        NSTimeInterval t = [mod timeIntervalSince1970];
        struct timespec ts[2] = { { 0, UTIME_OMIT }, { (time_t)t, (long)((t - (time_t)t) * 1e9) } };
        if (utimensat(AT_FDCWD, p, ts, 0) != 0) FAIL(1, path);
    }
    NSNumber *uid = [attributes objectForKey:NSFileOwnerAccountID], *gid = [attributes objectForKey:NSFileGroupOwnerAccountID];
    if ((uid || gid) && chown(p, uid ? [uid unsignedIntValue] : (uid_t)-1, gid ? [gid unsignedIntValue] : (gid_t)-1) != 0) FAIL(1, path);
    return YES;
}

- (NSString *)currentDirectoryPath
{
    char buf[PATH_MAX];
    return getcwd(buf, sizeof(buf)) ? [NSString stringWithUTF8String:buf] : nil;
}

- (BOOL)changeCurrentDirectoryPath:(NSString *)path { return chdir([path fileSystemRepresentation]) == 0; }

- (NSString *)displayNameAtPath:(NSString *)path { return [path lastPathComponent]; }

- (const char *)fileSystemRepresentationWithPath:(NSString *)path { return [path fileSystemRepresentation]; }

- (NSString *)stringWithFileSystemRepresentation:(const char *)str length:(NSUInteger)len
{
    return [[[NSString alloc] initWithBytes:str length:len encoding:NSUTF8StringEncoding] autorelease];
}

- (NSURL *)homeDirectoryForCurrentUser { return [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES]; }
- (NSURL *)homeDirectoryForUser:(NSString *)user
{
    NSString *h = NSHomeDirectoryForUser(user);
    return h ? [NSURL fileURLWithPath:h isDirectory:YES] : nil;
}
- (NSURL *)temporaryDirectory { return [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]; }

- (NSArray<NSURL *> *)URLsForDirectory:(NSSearchPathDirectory)directory inDomains:(NSSearchPathDomainMask)domainMask
{
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *p in NSSearchPathForDirectoriesInDomains(directory, domainMask, YES))
        [urls addObject:[NSURL fileURLWithPath:p isDirectory:YES]];
    return urls;
}

- (NSURL *)URLForDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domain
         appropriateForURL:(NSURL *)url create:(BOOL)shouldCreate error:(NSError **)error
{
    if (directory == NSItemReplacementDirectory) {
        NSString *t = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"(A Document Being Saved By %@)", [[NSProcessInfo processInfo] processName]]];
        if (![self createDirectoryAtPath:t withIntermediateDirectories:YES attributes:nil error:error]) return nil;
        return [NSURL fileURLWithPath:t isDirectory:YES];
    }
    NSURL *u = [[self URLsForDirectory:directory inDomains:domain] firstObject];
    if (u && shouldCreate && ![self createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return u;
}

@end

/* MARK: - Search paths */

/* Libc's sysdir, as Apple's Foundation uses: the same directories in the
 * same order. Application Scripts are per app (the bundle identifier, or
 * the process name). */
NSArray<NSString *> *
NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory directory, NSSearchPathDomainMask domainMask, BOOL expandTilde)
{
    NSMutableArray *paths = [NSMutableArray array];
    char path[PATH_MAX];
    sysdir_search_path_enumeration_state st =
        sysdir_start_search_path_enumeration((sysdir_search_path_directory_t)directory, (sysdir_search_path_domain_mask_t)domainMask);
    while ((st = sysdir_get_next_search_path_enumeration(st, path)) != 0) {
        NSString *p = [NSString stringWithUTF8String:path];
        if (directory == NSApplicationScriptsDirectory) {
            NSString *app = [[NSBundle mainBundle] bundleIdentifier];
            p = [p stringByAppendingPathComponent:app ? app : [[NSProcessInfo processInfo] processName]];
        }
        if (expandTilde) p = [p stringByExpandingTildeInPath];
        if (![paths containsObject:p]) [paths addObject:p];
    }
    /* For every domain, Apple's lists a system path after its cryptexes'
     * (the App and OS cryptexes), not before as sysdir does. */
    if (domainMask == NSAllDomainsMask) {
        for (NSUInteger i = 0; i < [paths count]; i++) {
            NSString *base = [paths objectAtIndex:i];
            NSString *app = [@"/System/Cryptexes/App" stringByAppendingString:base];
            NSUInteger j = [base hasPrefix:@"/System/"] ? [paths indexOfObject:app] : NSNotFound;
            if (j == NSNotFound || j < i) continue;
            [paths removeObjectAtIndex:j];
            [paths insertObject:app atIndex:i];
            [paths insertObject:[@"/System/Cryptexes/OS" stringByAppendingString:base] atIndex:i + 1];
            i += 2;
        }
    }
    return paths;
}

/* MARK: - The attribute accessors */

@implementation NSDictionary (NSFileAttributes)
- (unsigned long long)fileSize { return [[self objectForKey:NSFileSize] unsignedLongLongValue]; }
- (NSDate *)fileModificationDate { return [self objectForKey:NSFileModificationDate]; }
- (NSDate *)fileCreationDate { return [self objectForKey:NSFileCreationDate]; }
- (NSString *)fileType { return [self objectForKey:NSFileType]; }
- (NSUInteger)filePosixPermissions { return [[self objectForKey:NSFilePosixPermissions] unsignedIntegerValue]; }
- (NSString *)fileOwnerAccountName { return [self objectForKey:NSFileOwnerAccountName]; }
- (NSString *)fileGroupOwnerAccountName { return [self objectForKey:NSFileGroupOwnerAccountName]; }
- (NSNumber *)fileOwnerAccountID { return [self objectForKey:NSFileOwnerAccountID]; }
- (NSNumber *)fileGroupOwnerAccountID { return [self objectForKey:NSFileGroupOwnerAccountID]; }
- (NSInteger)fileSystemNumber { return [[self objectForKey:NSFileSystemNumber] integerValue]; }
- (NSUInteger)fileSystemFileNumber { return [[self objectForKey:NSFileSystemFileNumber] unsignedIntegerValue]; }
- (BOOL)fileExtensionHidden { return [[self objectForKey:NSFileExtensionHidden] boolValue]; }
- (BOOL)fileIsImmutable { return [[self objectForKey:NSFileImmutable] boolValue]; }
- (BOOL)fileIsAppendOnly { return [[self objectForKey:NSFileAppendOnly] boolValue]; }
- (OSType)fileHFSCreatorCode { return 0; }
- (OSType)fileHFSTypeCode { return 0; }
@end
