/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSBundle (docs/design/FOUNDATION.md), against the SDK's declaration, over
 * CFBundle. NSBundle and CFBundle aren't toll-free bridged; an NSBundle holds
 * its CFBundle, and there is one NSBundle per bundle (asking twice for the
 * same path gives the same object, as on macOS). +bundleForClass: finds the
 * image the class lives in and the bundle around it.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

#include "Foundation_Finch.h"

NSNotificationName const NSBundleDidLoadNotification = @"NSBundleDidLoadNotification";
NSString *const NSLoadedClasses = @"NSLoadedClasses";

@implementation NSBundle {
    CFBundleRef _cf;
    NSString *_path;
}

static NSMutableDictionary *bundles;   /* path -> NSBundle */
static NSLock *bundlesLock;

+ (void)initialize
{
    if (self == [NSBundle class]) {
        bundles = [[NSMutableDictionary alloc] init];
        bundlesLock = [[NSLock alloc] init];
    }
}

/* The NSBundle for a CFBundle, made once. */
+ (NSBundle *)_finchBundleForCFBundle:(CFBundleRef)cf
{
    if (!cf) return nil;
    CFURLRef url = CFBundleCopyBundleURL(cf);
    NSString *path = [(NSURL *)url path];
    [bundlesLock lock];
    NSBundle *b = [bundles objectForKey:path];
    if (!b) {
        b = [[[NSBundle alloc] _finchInitWithCFBundle:cf path:path] autorelease];
        if (b) [bundles setObject:b forKey:path];
    }
    [bundlesLock unlock];
    CFRelease(url);
    return b;
}

- (instancetype)_finchInitWithCFBundle:(CFBundleRef)cf path:(NSString *)path
{
    if ((self = [super init])) {
        _cf = (CFBundleRef)CFRetain(cf);
        _path = [path copy];
    }
    return self;
}

+ (NSBundle *)mainBundle { return [self _finchBundleForCFBundle:CFBundleGetMainBundle()]; }

+ (instancetype)bundleWithPath:(NSString *)path { return [[[self alloc] initWithPath:path] autorelease]; }
+ (instancetype)bundleWithURL:(NSURL *)url { return [[[self alloc] initWithURL:url] autorelease]; }

- (instancetype)initWithPath:(NSString *)path
{
    if (!path) { [self release]; return nil; }
    NSString *std = [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
    [bundlesLock lock];
    NSBundle *known = [[bundles objectForKey:std] retain];
    [bundlesLock unlock];
    if (known) { [self release]; return known; }
    BOOL dir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:std isDirectory:&dir] || !dir) { [self release]; return nil; }
    NSURL *url = [NSURL fileURLWithPath:std isDirectory:YES];
    CFBundleRef cf = CFBundleCreate(NULL, (CFURLRef)url);
    if (!cf) { [self release]; return nil; }
    [self release];
    NSBundle *b = [[NSBundle _finchBundleForCFBundle:cf] retain];
    CFRelease(cf);
    return b;
}

- (instancetype)initWithURL:(NSURL *)url { return [self initWithPath:[url path]]; }

+ (NSBundle *)bundleWithIdentifier:(NSString *)identifier
{
    return [self _finchBundleForCFBundle:CFBundleGetBundleWithIdentifier((CFStringRef)identifier)];
}

/* The bundle around the image a class is in: the framework or app the
 * binary sits inside, else the main bundle. */
+ (NSBundle *)bundleForClass:(Class)aClass
{
    const char *image = aClass ? class_getImageName(aClass) : NULL;
    if (!image) return [self mainBundle];
    NSString *path = [NSString stringWithUTF8String:image];
    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) == 0 && [[[NSString stringWithUTF8String:exe] stringByResolvingSymlinksInPath]
            isEqualToString:[path stringByResolvingSymlinksInPath]])
        return [self mainBundle];
    for (NSString *dir = [path stringByDeletingLastPathComponent]; [dir length] > 1; dir = [dir stringByDeletingLastPathComponent]) {
        NSString *ext = [dir pathExtension];
        if ([ext isEqualToString:@"framework"] || [ext isEqualToString:@"bundle"] || [ext isEqualToString:@"app"] ||
            [ext isEqualToString:@"plugin"] || [ext isEqualToString:@"appex"]) {
            NSBundle *b = [self bundleWithPath:dir];
            if (b) return b;
        }
    }
    return [self mainBundle];
}

+ (NSArray<NSBundle *> *)allBundles
{
    NSMutableArray *a = [NSMutableArray array];
    for (id cf in (NSArray *)CFBundleGetAllBundles()) {
        NSBundle *b = [self _finchBundleForCFBundle:(CFBundleRef)cf];
        if (b && ![[b bundlePath] hasSuffix:@".framework"]) [a addObject:b];
    }
    return a;
}

+ (NSArray<NSBundle *> *)allFrameworks
{
    NSMutableArray *a = [NSMutableArray array];
    for (id cf in (NSArray *)CFBundleGetAllBundles()) {
        NSBundle *b = [self _finchBundleForCFBundle:(CFBundleRef)cf];
        if ([[b bundlePath] hasSuffix:@".framework"]) [a addObject:b];
    }
    return a;
}

- (void)dealloc
{
    if (_cf) CFRelease(_cf);
    [_path release];
    [super dealloc];
}

- (BOOL)load { return [self loadAndReturnError:NULL]; }

- (BOOL)loadAndReturnError:(NSError **)error
{
    if (CFBundleIsExecutableLoaded(_cf)) return YES;
    CFErrorRef err = NULL;
    Boolean ok = CFBundleLoadExecutableAndReturnError(_cf, &err);
    if (!ok && error) *error = [(id)err autorelease];
    else if (err) CFRelease(err);
    if (ok) [[NSNotificationCenter defaultCenter] postNotificationName:NSBundleDidLoadNotification object:self];
    return ok;
}

- (BOOL)isLoaded { return CFBundleIsExecutableLoaded(_cf); }
- (BOOL)unload { CFBundleUnloadExecutable(_cf); return YES; }
- (BOOL)preflightAndReturnError:(NSError **)error { return YES; }

- (NSURL *)bundleURL { return [NSURL fileURLWithPath:_path isDirectory:YES]; }
- (NSString *)bundlePath { return _path; }

static NSURL *
owned_url(CFURLRef u)
{
    if (!u) return nil;
    CFURLRef abs = CFURLCopyAbsoluteURL(u);
    CFRelease(u);
    return [(id)abs autorelease];
}

- (NSURL *)resourceURL { return owned_url(CFBundleCopyResourcesDirectoryURL(_cf)); }
- (NSString *)resourcePath { return [[self resourceURL] path]; }
- (NSURL *)executableURL { return owned_url(CFBundleCopyExecutableURL(_cf)); }
- (NSString *)executablePath { return [[self executableURL] path]; }
- (NSURL *)privateFrameworksURL { return owned_url(CFBundleCopyPrivateFrameworksURL(_cf)); }
- (NSString *)privateFrameworksPath { return [[self privateFrameworksURL] path]; }
- (NSURL *)sharedFrameworksURL { return owned_url(CFBundleCopySharedFrameworksURL(_cf)); }
- (NSString *)sharedFrameworksPath { return [[self sharedFrameworksURL] path]; }
- (NSURL *)sharedSupportURL { return owned_url(CFBundleCopySharedSupportURL(_cf)); }
- (NSString *)sharedSupportPath { return [[self sharedSupportURL] path]; }
- (NSURL *)builtInPlugInsURL { return owned_url(CFBundleCopyBuiltInPlugInsURL(_cf)); }
- (NSString *)builtInPlugInsPath { return [[self builtInPlugInsURL] path]; }
- (NSURL *)appStoreReceiptURL { return [[self bundleURL] URLByAppendingPathComponent:@"Contents/_MASReceipt/receipt"]; }

- (NSURL *)URLForAuxiliaryExecutable:(NSString *)name { return owned_url(CFBundleCopyAuxiliaryExecutableURL(_cf, (CFStringRef)name)); }
- (NSString *)pathForAuxiliaryExecutable:(NSString *)name { return [[self URLForAuxiliaryExecutable:name] path]; }

- (NSString *)bundleIdentifier { return (NSString *)CFBundleGetIdentifier(_cf); }
- (NSDictionary<NSString *, id> *)infoDictionary { return (NSDictionary *)CFBundleGetInfoDictionary(_cf); }
- (NSDictionary<NSString *, id> *)localizedInfoDictionary
{
    NSDictionary *d = (NSDictionary *)CFBundleGetLocalInfoDictionary(_cf);
    return d ? d : [self infoDictionary];
}
- (id)objectForInfoDictionaryKey:(NSString *)key { return (id)CFBundleGetValueForInfoDictionaryKey(_cf, (CFStringRef)key); }

- (Class)classNamed:(NSString *)className { return [self load] ? NSClassFromString(className) : Nil; }

- (Class)principalClass
{
    NSString *name = [self objectForInfoDictionaryKey:@"NSPrincipalClass"];
    if (![self load]) return Nil;
    return name ? NSClassFromString(name) : Nil;
}

- (NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)ext subdirectory:(NSString *)subpath localization:(NSString *)loc
{
    if (loc)
        return owned_url(CFBundleCopyResourceURLForLocalization(_cf, (CFStringRef)name, (CFStringRef)ext, (CFStringRef)subpath, (CFStringRef)loc));
    return owned_url(CFBundleCopyResourceURL(_cf, (CFStringRef)name, (CFStringRef)ext, (CFStringRef)subpath));
}
- (NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)ext subdirectory:(NSString *)subpath
{
    return [self URLForResource:name withExtension:ext subdirectory:subpath localization:nil];
}
- (NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)ext
{
    return [self URLForResource:name withExtension:ext subdirectory:nil localization:nil];
}
- (NSArray<NSURL *> *)URLsForResourcesWithExtension:(NSString *)ext subdirectory:(NSString *)subpath
{
    CFArrayRef a = CFBundleCopyResourceURLsOfType(_cf, (CFStringRef)ext, (CFStringRef)subpath);
    NSMutableArray *out = [NSMutableArray array];
    for (NSURL *u in (NSArray *)a) [out addObject:[u absoluteURL]];
    if (a) CFRelease(a);
    return out;
}
- (NSArray<NSURL *> *)URLsForResourcesWithExtension:(NSString *)ext subdirectory:(NSString *)subpath localization:(NSString *)loc
{
    CFArrayRef a = CFBundleCopyResourceURLsOfTypeForLocalization(_cf, (CFStringRef)ext, (CFStringRef)subpath, (CFStringRef)loc);
    NSMutableArray *out = [NSMutableArray array];
    for (NSURL *u in (NSArray *)a) [out addObject:[u absoluteURL]];
    if (a) CFRelease(a);
    return out;
}

- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext { return [[self URLForResource:name withExtension:ext] path]; }
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext inDirectory:(NSString *)subpath
{
    return [[self URLForResource:name withExtension:ext subdirectory:subpath] path];
}
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext inDirectory:(NSString *)subpath forLocalization:(NSString *)loc
{
    return [[self URLForResource:name withExtension:ext subdirectory:subpath localization:loc] path];
}
- (NSArray<NSString *> *)pathsForResourcesOfType:(NSString *)ext inDirectory:(NSString *)subpath
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSURL *u in [self URLsForResourcesWithExtension:ext subdirectory:subpath]) [out addObject:[u path]];
    return out;
}
+ (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext inDirectory:(NSString *)bundlePath
{
    return [[NSBundle bundleWithPath:bundlePath] pathForResource:name ofType:ext];
}

extern NSAttributedString *_FinchAttributedStringFromInlineMarkdown(NSString *string) NS_RETURNS_RETAINED;

/* The localized string read as inline Markdown, as Apple's does; plain text if it doesn't parse. */
- (NSAttributedString *)localizedAttributedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)tableName
{
    NSString *s = [self localizedStringForKey:key value:value table:tableName];
    NSAttributedString *a = _FinchAttributedStringFromInlineMarkdown(s);
    return a ? [a autorelease] : [[[NSAttributedString alloc] initWithString:s] autorelease];
}

- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)tableName
{
    if (!key) return value ? value : @"";
    return [(id)CFBundleCopyLocalizedString(_cf, (CFStringRef)key, (CFStringRef)value, (CFStringRef)tableName) autorelease];
}

- (NSArray<NSString *> *)localizations { return [(id)CFBundleCopyBundleLocalizations(_cf) autorelease]; }
- (NSArray<NSString *> *)preferredLocalizations
{
    return [(id)CFBundleCopyPreferredLocalizationsFromArray((CFArrayRef)[self localizations]) autorelease];
}
- (NSString *)developmentLocalization { return (NSString *)CFBundleGetDevelopmentRegion(_cf); }
+ (NSArray<NSString *> *)preferredLocalizationsFromArray:(NSArray<NSString *> *)localizationsArray
{
    return [(id)CFBundleCopyPreferredLocalizationsFromArray((CFArrayRef)localizationsArray) autorelease];
}

- (NSArray<NSNumber *> *)executableArchitectures { return [(id)CFBundleCopyExecutableArchitectures(_cf) autorelease]; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"NSBundle <%@> (%@)", _path, [self isLoaded] ? @"loaded" : @"not yet loaded"];
}

@end
