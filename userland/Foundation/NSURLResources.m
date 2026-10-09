/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSURL's resource values: a file's properties by key (name, kind, size,
 * dates, permissions, type identifier, ...), from lstat(2) and friends.
 * What each key returns for files, directories, packages, symbolic links
 * and missing files is as measured on macOS 26.4. Type identifiers and
 * their descriptions come from Finch's UniformTypeIdentifiers, loaded when
 * first asked for (Apple's Foundation asks LaunchServices).
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>

/* UniformTypeIdentifiers' private lookups (UTFinch.m there). */
typedef NSString *(*TypeForPath)(NSString *path, BOOL directory, BOOL package);
typedef NSString *(*TypeDescription)(NSString *identifier);

static TypeForPath type_for_path;
static TypeDescription type_description;

static void
load_types(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/UniformTypeIdentifiers.framework/UniformTypeIdentifiers",
                         RTLD_LAZY | RTLD_GLOBAL);
        if (h) {
            type_for_path = (TypeForPath)dlsym(h, "_UTFinchTypeIdentifierForPath");
            type_description = (TypeDescription)dlsym(h, "_UTFinchLocalizedDescription");
        }
    });
}

/* Directories with these extensions are packages (bundles) whatever they hold. */
static BOOL
package_extension(NSString *ext)
{
    static NSSet *set;
    if (!set)
        set = [[NSSet alloc] initWithObjects:@"app", @"bundle", @"framework", @"plugin", @"kext", @"rtfd", @"pkg",
                                             @"mpkg", @"xpc", @"appex", @"qlgenerator", @"mdimporter", @"prefPane",
                                             @"saver", @"dSYM", @"xcodeproj", @"xcworkspace", @"playground",
                                             @"photoslibrary", @"pages", @"numbers", @"key", @"docset", nil];
    return [set containsObject:ext];
}

static NSError *
no_such_file(NSURL *url)
{
    return [NSError errorWithDomain:NSCocoaErrorDomain
                               code:NSFileReadNoSuchFileError
                           userInfo:@{NSURLErrorKey : url, NSFilePathErrorKey : [url path] ?: @""}];
}

static NSDate *
date_of(struct timespec ts)
{
    return [NSDate dateWithTimeIntervalSince1970:(double)ts.tv_sec + ts.tv_nsec / 1e9];
}

@implementation NSURL (NSURLResources)

/* Keys that answer without the file existing: these, and keys this doesn't know. */
static BOOL
answers_without_file(NSString *key)
{
    static NSSet *needsFile;
    if (!needsFile)
        needsFile = [[NSSet alloc] initWithObjects:NSURLNameKey, NSURLLocalizedNameKey, NSURLIsRegularFileKey,
                        NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsAliasFileKey, NSURLIsVolumeKey,
                        NSURLIsPackageKey, NSURLIsApplicationKey, NSURLHasHiddenExtensionKey, NSURLIsHiddenKey,
                        NSURLIsReadableKey, NSURLIsWritableKey, NSURLIsExecutableKey, NSURLIsUserImmutableKey,
                        NSURLIsSystemImmutableKey, NSURLIsMountTriggerKey, NSURLLabelNumberKey, NSURLLinkCountKey,
                        NSURLFileSizeKey, NSURLTotalFileSizeKey, NSURLFileAllocatedSizeKey,
                        NSURLTotalFileAllocatedSizeKey, NSURLFileResourceTypeKey, NSURLParentDirectoryURLKey,
                        NSURLCanonicalPathKey, NSURLCreationDateKey, NSURLContentModificationDateKey,
                        NSURLAttributeModificationDateKey, NSURLContentAccessDateKey, NSURLFileResourceIdentifierKey,
                        NSURLFileIdentifierKey, NSURLGenerationIdentifierKey, NSURLPreferredIOBlockSizeKey,
                        NSURLVolumeURLKey, NSURLTypeIdentifierKey, NSURLLocalizedTypeDescriptionKey,
                        NSURLContentTypeKey, nil];
    return ![needsFile containsObject:key];
}

static id
value_for_key(NSURL *url, NSString *key, const struct stat *st, BOOL exists)
{
    NSString *path = [url path];
    NSString *name = [path lastPathComponent];
    if ([key isEqualToString:NSURLPathKey])
        return path;
    if ([key isEqualToString:NSURLIsExcludedFromBackupKey])
        return @NO;
    if ([key isEqualToString:NSURLIsUbiquitousItemKey])
        return nil;
    if (!exists)
        return nil;
    mode_t fmt = st->st_mode & S_IFMT;
    BOOL dir = fmt == S_IFDIR, link = fmt == S_IFLNK;
    BOOL package = dir && package_extension([path pathExtension]);
    if ([key isEqualToString:NSURLNameKey] || [key isEqualToString:NSURLLocalizedNameKey])
        return name;
    if ([key isEqualToString:NSURLIsRegularFileKey])
        return @(fmt == S_IFREG);
    if ([key isEqualToString:NSURLIsDirectoryKey])
        return @(dir);
    if ([key isEqualToString:NSURLIsSymbolicLinkKey])
        return @(link);
    if ([key isEqualToString:NSURLIsAliasFileKey])
        return @(link);
    if ([key isEqualToString:NSURLIsVolumeKey])
        return @([path isEqualToString:@"/"]);
    if ([key isEqualToString:NSURLIsPackageKey])
        return @(package);
    if ([key isEqualToString:NSURLIsApplicationKey])
        return @(package && [[path pathExtension] isEqualToString:@"app"]);
    if ([key isEqualToString:NSURLHasHiddenExtensionKey])
        return @(package && [[path pathExtension] isEqualToString:@"app"]);
    if ([key isEqualToString:NSURLIsHiddenKey])
        return @([name hasPrefix:@"."] || (st->st_flags & UF_HIDDEN) != 0);
    if ([key isEqualToString:NSURLIsReadableKey])
        return @(faccessat(AT_FDCWD, [path fileSystemRepresentation], R_OK, AT_SYMLINK_NOFOLLOW) == 0);
    if ([key isEqualToString:NSURLIsWritableKey])
        return @(faccessat(AT_FDCWD, [path fileSystemRepresentation], W_OK, AT_SYMLINK_NOFOLLOW) == 0);
    if ([key isEqualToString:NSURLIsExecutableKey])
        return @(faccessat(AT_FDCWD, [path fileSystemRepresentation], X_OK, AT_SYMLINK_NOFOLLOW) == 0);
    if ([key isEqualToString:NSURLIsUserImmutableKey])
        return @((st->st_flags & UF_IMMUTABLE) != 0);
    if ([key isEqualToString:NSURLIsSystemImmutableKey])
        return @((st->st_flags & SF_IMMUTABLE) != 0);
    if ([key isEqualToString:NSURLIsMountTriggerKey])
        return @NO;
    if ([key isEqualToString:NSURLLabelNumberKey])
        return @0;
    if ([key isEqualToString:NSURLLinkCountKey])
        return @(dir ? 1 : st->st_nlink);
    if ([key isEqualToString:NSURLFileSizeKey] || [key isEqualToString:NSURLTotalFileSizeKey])
        return dir ? nil : @(st->st_size);
    if ([key isEqualToString:NSURLFileAllocatedSizeKey] || [key isEqualToString:NSURLTotalFileAllocatedSizeKey])
        return dir ? nil : @(st->st_blocks * 512);
    if ([key isEqualToString:NSURLFileResourceTypeKey]) {
        switch (fmt) {
        case S_IFREG: return NSURLFileResourceTypeRegular;
        case S_IFDIR: return NSURLFileResourceTypeDirectory;
        case S_IFLNK: return NSURLFileResourceTypeSymbolicLink;
        case S_IFIFO: return NSURLFileResourceTypeNamedPipe;
        case S_IFCHR: return NSURLFileResourceTypeCharacterSpecial;
        case S_IFBLK: return NSURLFileResourceTypeBlockSpecial;
        case S_IFSOCK: return NSURLFileResourceTypeSocket;
        default: return NSURLFileResourceTypeUnknown;
        }
    }
    if ([key isEqualToString:NSURLParentDirectoryURLKey]) {
        /* the parent's real path, symbolic links resolved */
        char buf[PATH_MAX];
        NSString *parent = [path stringByDeletingLastPathComponent];
        if (realpath([parent fileSystemRepresentation], buf))
            parent = @(buf);
        return [NSURL fileURLWithPath:parent isDirectory:YES];
    }
    if ([key isEqualToString:NSURLCanonicalPathKey]) {
        char buf[PATH_MAX];
        NSString *parent = [path stringByDeletingLastPathComponent];
        if (realpath([parent fileSystemRepresentation], buf))
            return [@(buf) stringByAppendingPathComponent:name];
        return path;
    }
    if ([key isEqualToString:NSURLCreationDateKey])
        return date_of(st->st_birthtimespec);
    if ([key isEqualToString:NSURLContentModificationDateKey])
        return date_of(st->st_mtimespec);
    if ([key isEqualToString:NSURLAttributeModificationDateKey])
        return date_of(st->st_ctimespec);
    if ([key isEqualToString:NSURLContentAccessDateKey])
        return date_of(st->st_atimespec);
    if ([key isEqualToString:NSURLFileResourceIdentifierKey] || [key isEqualToString:NSURLFileIdentifierKey]) {
        uint64_t ident[2] = {(uint64_t)st->st_dev, (uint64_t)st->st_ino};
        return [key isEqualToString:NSURLFileIdentifierKey] ? (id)@(st->st_ino)
                                                             : [NSData dataWithBytes:ident length:sizeof ident];
    }
    if ([key isEqualToString:NSURLGenerationIdentifierKey])
        return [NSData dataWithBytes:&st->st_gen length:sizeof st->st_gen];
    if ([key isEqualToString:NSURLPreferredIOBlockSizeKey])
        return @(st->st_blksize);
    if ([key isEqualToString:NSURLVolumeURLKey])
        return [NSURL fileURLWithPath:@"/" isDirectory:YES];
    if ([key isEqualToString:NSURLTypeIdentifierKey] || [key isEqualToString:NSURLLocalizedTypeDescriptionKey]) {
        load_types();
        NSString *uti = nil;
        if (link)
            uti = @"public.symlink";
        else if (type_for_path)
            uti = type_for_path(path, dir, package);
        else
            uti = dir ? (package ? @"com.apple.package" : @"public.folder") : @"public.data";
        if ([key isEqualToString:NSURLTypeIdentifierKey])
            return uti;
        if (link)
            return @"Alias";
        return type_description ? type_description(uti) : nil;
    }
    if ([key isEqualToString:NSURLContentTypeKey]) {
        load_types();
        Class ut = NSClassFromString(@"UTType");
        NSString *uti = value_for_key(url, NSURLTypeIdentifierKey, st, exists);
        return uti && ut ? [ut typeWithIdentifier:uti] : nil;
    }
    return nil;
}

- (BOOL)getResourceValue:(out id *)value forKey:(NSURLResourceKey)key error:(out NSError **)error
{
    if (value)
        *value = nil;
    if (![self isFileURL])
        return YES;
    struct stat st;
    BOOL exists = lstat([self fileSystemRepresentation], &st) == 0;
    if (!exists && !answers_without_file(key)) {
        if (error)
            *error = no_such_file(self);
        return NO;
    }
    if (value)
        *value = value_for_key(self, key, &st, exists);
    return YES;
}

- (NSDictionary<NSURLResourceKey, id> *)resourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys
                                                        error:(NSError **)error
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSURLResourceKey k in keys) {
        id v = nil;
        if (![self getResourceValue:&v forKey:k error:error])
            return nil;
        if (v)
            d[k] = v;
    }
    return d;
}

- (BOOL)setResourceValue:(id)value forKey:(NSURLResourceKey)key error:(NSError **)error
{
    if (![self isFileURL])
        return NO;
    const char *p = [self fileSystemRepresentation];
    struct stat st;
    if (lstat(p, &st) != 0) {
        if (error)
            *error = no_such_file(self);
        return NO;
    }
    if ([key isEqualToString:NSURLIsHiddenKey]) {
        u_int flags = [value boolValue] ? st.st_flags | UF_HIDDEN : st.st_flags & ~UF_HIDDEN;
        return lchflags(p, flags) == 0;
    }
    if ([key isEqualToString:NSURLIsUserImmutableKey]) {
        u_int flags = [value boolValue] ? st.st_flags | UF_IMMUTABLE : st.st_flags & ~UF_IMMUTABLE;
        return lchflags(p, flags) == 0;
    }
    if ([key isEqualToString:NSURLContentModificationDateKey] || [key isEqualToString:NSURLContentAccessDateKey]) {
        NSTimeInterval t = [value timeIntervalSince1970];
        struct timespec ts[2] = {st.st_atimespec, st.st_mtimespec};
        struct timespec now = {(time_t)t, (long)((t - floor(t)) * 1e9)};
        ts[[key isEqualToString:NSURLContentModificationDateKey] ? 1 : 0] = now;
        return utimensat(AT_FDCWD, p, ts, AT_SYMLINK_NOFOLLOW) == 0;
    }
    /* Names change by moving; the rest (backup exclusion, labels, tags) have nowhere to go yet. */
    if ([key isEqualToString:NSURLNameKey]) {
        NSString *to = [[[self path] stringByDeletingLastPathComponent] stringByAppendingPathComponent:value];
        return rename(p, [to fileSystemRepresentation]) == 0;
    }
    return YES;
}

- (BOOL)setResourceValues:(NSDictionary<NSURLResourceKey, id> *)values error:(NSError **)error
{
    for (NSURLResourceKey k in values)
        if (![self setResourceValue:values[k] forKey:k error:error])
            return NO;
    return YES;
}

- (void)removeCachedResourceValueForKey:(NSURLResourceKey)key {}
- (void)removeAllCachedResourceValues {}
- (void)setTemporaryResourceValue:(id)value forKey:(NSURLResourceKey)key {}

- (BOOL)checkPromisedItemIsReachableAndReturnError:(NSError **)error
{
    return [self checkResourceIsReachableAndReturnError:error];
}

- (BOOL)getPromisedItemResourceValue:(id *)value forKey:(NSURLResourceKey)key error:(NSError **)error
{
    return [self getResourceValue:value forKey:key error:error];
}

- (NSDictionary *)promisedItemResourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys error:(NSError **)error
{
    return [self resourceValuesForKeys:keys error:error];
}

@end
