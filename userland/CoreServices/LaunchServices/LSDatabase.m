/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's application database. macOS keeps one in lsd; Finch builds it in
 * each process from the application folders (/Applications,
 * /System/Applications, /System/Library/CoreServices and the user's
 * ~/Applications, each with its Utilities folder, as AppKit's NSWorkspace
 * searches them), the bundles registered with LSRegisterURL and the main
 * bundle, reading each Info.plist: CFBundleDocumentTypes (content types,
 * extensions, OSTypes and MIME types, with role and rank), CFBundleURLTypes
 * and UTExported/UTImportedTypeDeclarations. It's rebuilt when a folder or
 * the registrations change.
 *
 * Registrations and the user's default handlers live in the user's
 * defaults, org.finch.LaunchServices: RegisteredApplications (paths) and
 * LSHandlers (as macOS's com.apple.launchservices.secure: a content type or
 * URL scheme, a role and a bundle identifier).
 *
 * Ranking, as LaunchServices: an app's claim on a type is Owner, Default
 * (when it gives none) or Alternate; a claim on everything ("*",
 * public.item, public.data, public.content) ranks below them all; None
 * doesn't count. The user's choice comes first, then rank, then search
 * order.
 */
#import "LaunchServices_Finch.h"
#include <pthread.h>
#include <sys/stat.h>

#define DEFAULTS_DOMAIN @"org.finch.LaunchServices"

@implementation LSFinchApp

- (NSURL *)URL
{
    return [NSURL fileURLWithPath:self.path isDirectory:YES];
}

- (NSString *)bundleIdentifier
{
    id b = self.info[@"CFBundleIdentifier"];
    return [b isKindOfClass:[NSString class]] ? b : nil;
}

- (NSString *)name
{
    NSBundle *bundle = [NSBundle bundleWithPath:self.path];
    NSString *missing = @"__FinchMissingLocalizedName__";
    NSString *localized = [bundle localizedStringForKey:@"CFBundleDisplayName" value:missing table:@"InfoPlist"];
    if (!localized.length || [localized isEqualToString:missing])
        localized = [bundle localizedStringForKey:@"CFBundleName" value:missing table:@"InfoPlist"];
    if (localized.length && ![localized isEqualToString:missing])
        return localized;
    /* Without a localized display name, LaunchServices uses the bundle filename. */
    return [[self.path lastPathComponent] stringByDeletingPathExtension];
}

- (NSString *)executablePath
{
    id exe = self.info[@"CFBundleExecutable"];
    if (![exe isKindOfClass:[NSString class]] || ![exe length])
        exe = [[self.path lastPathComponent] stringByDeletingPathExtension];
    NSString *p = [self.path stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:exe]];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:p]) {
        NSString *flat = [self.path stringByAppendingPathComponent:exe];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:flat])
            return flat;
    }
    return p;
}

- (void)dealloc
{
    [_path release];
    [_info release];
    [super dealloc];
}

@end

static NSDictionary *
info_of(NSString *app)
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
    if (!d)
        d = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

BOOL
_LSIsApplicationBundle(NSString *path)
{
    BOOL dir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir] || !dir)
        return NO;
    NSDictionary *info = info_of(path);
    NSString *type = info[@"CFBundlePackageType"];
    return [[[path pathExtension] lowercaseString] isEqualToString:@"app"] ||
           ([type isKindOfClass:[NSString class]] && [type isEqualToString:@"APPL"]);
}

static NSArray<NSString *> *
app_folders(void)
{
    NSString *home = NSHomeDirectory();
    return @[
        @"/Applications", @"/Applications/Utilities", @"/System/Applications", @"/System/Applications/Utilities",
        @"/System/Library/CoreServices", [home stringByAppendingPathComponent:@"Applications"],
        [home stringByAppendingPathComponent:@"Applications/Utilities"]
    ];
}

static NSUserDefaults *
defaults(void)
{
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:DEFAULTS_DOMAIN];
    });
    return d;
}

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static NSArray<LSFinchApp *> *apps;
static NSDictionary *typeDecls, *typeOwners;
static NSString *stamp;
static unsigned generation;

/* What the database was built from: the folders' modification times and the registrations. */
static NSString *
current_stamp(void)
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"%u;", generation];
    for (NSString *f in app_folders()) {
        struct stat st;
        if (!stat(f.fileSystemRepresentation, &st))
            [s appendFormat:@"%ld.%ld;", (long)st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec];
        else
            [s appendString:@"-;"];
    }
    return s;
}

static void
add_decls(NSMutableDictionary *decls, NSMutableDictionary *owners, LSFinchApp *app, NSString *key)
{
    NSArray *list = app.info[key];
    if (![list isKindOfClass:[NSArray class]])
        return;
    for (NSDictionary *d in list) {
        if (![d isKindOfClass:[NSDictionary class]] || ![d[@"UTTypeIdentifier"] isKindOfClass:[NSString class]])
            continue;
        NSString *k = [d[@"UTTypeIdentifier"] lowercaseString];
        if (!decls[k]) {
            decls[k] = d;
            owners[k] = app.path;
        }
    }
}

static void
rebuild_locked(void)
{
    NSString *now = current_stamp();
    if (apps && [now isEqualToString:stamp])
        return;
    NSMutableArray *list = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *path) {
        NSString *real = [path stringByResolvingSymlinksInPath];
        if ([seen containsObject:real] || !_LSIsApplicationBundle(path))
            return;
        NSDictionary *info = info_of(path);
        if (!info)
            return;
        [seen addObject:real];
        LSFinchApp *a = [[LSFinchApp new] autorelease];
        a.path = path;
        a.info = info;
        [list addObject:a];
    };
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in app_folders()) {
        NSArray *items = [[fm contentsOfDirectoryAtPath:dir error:NULL] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *name in items)
            if ([[[name pathExtension] lowercaseString] isEqualToString:@"app"])
                add([dir stringByAppendingPathComponent:name]);
    }
    for (NSString *p in [defaults() arrayForKey:@"RegisteredApplications"])
        if ([p isKindOfClass:[NSString class]])
            add(p);
    NSString *main = [[NSBundle mainBundle] bundlePath];
    if ([[[main pathExtension] lowercaseString] isEqualToString:@"app"])
        add(main);
    NSMutableDictionary *decls = [NSMutableDictionary dictionary], *owners = [NSMutableDictionary dictionary];
    for (LSFinchApp *a in list)
        add_decls(decls, owners, a, @"UTExportedTypeDeclarations");
    for (LSFinchApp *a in list)
        add_decls(decls, owners, a, @"UTImportedTypeDeclarations");
    [apps release];
    [typeDecls release];
    [typeOwners release];
    [stamp release];
    apps = [list copy];
    typeDecls = [decls copy];
    typeOwners = [owners copy];
    stamp = [now copy];
}

NSArray<LSFinchApp *> *
_LSApplications(void)
{
    pthread_mutex_lock(&lock);
    rebuild_locked();
    NSArray *a = [[apps retain] autorelease];
    pthread_mutex_unlock(&lock);
    return a;
}

NSDictionary<NSString *, NSDictionary *> *
_LSApplicationTypeDeclarations(void)
{
    pthread_mutex_lock(&lock);
    rebuild_locked();
    NSDictionary *d = [[typeDecls retain] autorelease];
    pthread_mutex_unlock(&lock);
    return d;
}

NSString *
_LSDeclaringApplicationPath(NSString *uti)
{
    pthread_mutex_lock(&lock);
    rebuild_locked();
    NSString *p = [[[typeOwners objectForKey:[uti lowercaseString]] retain] autorelease];
    pthread_mutex_unlock(&lock);
    return p;
}

LSFinchApp *
_LSApplicationAtPath(NSString *path)
{
    NSString *real = [path stringByResolvingSymlinksInPath];
    for (LSFinchApp *a in _LSApplications())
        if ([[a.path stringByResolvingSymlinksInPath] isEqualToString:real])
            return a;
    if (!_LSIsApplicationBundle(path))
        return nil;
    NSDictionary *info = info_of(path);
    if (!info)
        return nil;
    LSFinchApp *a = [[LSFinchApp new] autorelease];
    a.path = path;
    a.info = info;
    return a;
}

NSArray<LSFinchApp *> *
_LSApplicationsWithIdentifier(NSString *bundleID)
{
    NSMutableArray *a = [NSMutableArray array];
    if (!bundleID.length)
        return a;
    for (LSFinchApp *app in _LSApplications())
        if (app.bundleIdentifier && [app.bundleIdentifier caseInsensitiveCompare:bundleID] == NSOrderedSame)
            [a addObject:app];
    return a;
}

OSStatus
_LSRegister(NSString *path)
{
    if (!_LSIsApplicationBundle(path) || !info_of(path))
        return kLSNoRegistrationInfoErr;
    NSString *real = [path stringByResolvingSymlinksInPath];
    NSMutableArray *reg = [[[defaults() arrayForKey:@"RegisteredApplications"] mutableCopy] autorelease] ?: [NSMutableArray array];
    if (![reg containsObject:real]) {
        [reg addObject:real];
        [defaults() setObject:reg forKey:@"RegisteredApplications"];
        [defaults() synchronize];
    }
    pthread_mutex_lock(&lock);
    generation++;
    pthread_mutex_unlock(&lock);
    return noErr;
}

#pragma mark - Claims

static NSArray *
strings(id v)
{
    if ([v isKindOfClass:[NSString class]])
        return @[ v ];
    if (![v isKindOfClass:[NSArray class]])
        return @[];
    NSMutableArray *a = [NSMutableArray array];
    for (id x in v)
        if ([x isKindOfClass:[NSString class]])
            [a addObject:x];
    return a;
}

static BOOL
role_matches(NSString *role, LSRolesMask roles)
{
    if (roles == kLSRolesAll || roles == 0)
        return YES;
    if (![role isKindOfClass:[NSString class]])
        role = @"Editor";
    if ([role isEqualToString:@"Editor"])
        return (roles & (kLSRolesEditor | kLSRolesViewer)) != 0;
    if ([role isEqualToString:@"Viewer"])
        return (roles & kLSRolesViewer) != 0;
    if ([role isEqualToString:@"Shell"])
        return (roles & kLSRolesShell) != 0;
    if ([role isEqualToString:@"None"])
        return (roles & kLSRolesNone) != 0;
    return NO;
}

/* How well an app claims a type: 0 none, 1 generic, 2 Alternate, 3 Default, 4 Owner. */
static int
rank(LSFinchApp *app, NSString *uti, NSString *ext, LSRolesMask roles, NSString **kind)
{
    static NSSet *generic;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        generic = [[NSSet alloc] initWithObjects:@"public.item", @"public.data", @"public.content", @"*", nil];
    });
    int best = 0;
    id docs = app.info[@"CFBundleDocumentTypes"];
    if (![docs isKindOfClass:[NSArray class]])
        return 0;
    for (NSDictionary *d in docs) {
        if (![d isKindOfClass:[NSDictionary class]])
            continue;
        NSString *r = d[@"LSHandlerRank"];
        if ([r isKindOfClass:[NSString class]] && [r isEqualToString:@"None"])
            continue;
        if (!role_matches(d[@"CFBundleTypeRole"], roles))
            continue;
        int value = [r isKindOfClass:[NSString class]] ? ([r isEqualToString:@"Owner"] ? 4 : [r isEqualToString:@"Alternate"] ? 2 : 3) : 3;
        int got = 0;
        for (NSString *t in strings(d[@"LSItemContentTypes"]))
            if (uti && _LSConforms(uti, t))
                got = MAX(got, [generic containsObject:[t lowercaseString]] ? 1 : value);
        for (NSString *e in strings(d[@"CFBundleTypeExtensions"])) {
            if ([e isEqualToString:@"*"])
                got = MAX(got, 1);
            else if (ext.length && [e caseInsensitiveCompare:ext] == NSOrderedSame)
                got = MAX(got, value);
        }
        if (got > best) {
            best = got;
            if (kind) {
                id n = d[@"CFBundleTypeName"];
                *kind = [n isKindOfClass:[NSString class]] ? n : nil;
            }
        }
    }
    return best;
}

NSArray<LSFinchApp *> *
_LSApplicationsForType(NSString *uti, NSString *ext, LSRolesMask roles, BOOL generic)
{
    NSMutableArray *a = [NSMutableArray array], *ranks = [NSMutableArray array];
    if (!uti && !ext)
        return a;
    for (LSFinchApp *app in _LSApplications()) {
        int r = rank(app, uti, ext, roles, NULL);
        if (r > (generic ? 0 : 1)) {
            NSUInteger i = 0;
            while (i < ranks.count && [ranks[i] intValue] >= r)
                i++;
            [ranks insertObject:@(r) atIndex:i];
            [a insertObject:app atIndex:i];
        }
    }
    return a;
}

NSString *
_LSDocumentKindForType(NSString *uti, NSString *ext)
{
    NSString *kind = nil;
    int best = 0;
    for (LSFinchApp *app in _LSApplications()) {
        NSString *k = nil;
        int r = rank(app, uti, ext, kLSRolesAll, &k);
        if (r > best && k) {
            best = r;
            kind = k;
        }
    }
    return best > 1 ? kind : nil;
}

NSArray<LSFinchApp *> *
_LSApplicationsForScheme(NSString *scheme, LSRolesMask roles)
{
    NSMutableArray *a = [NSMutableArray array];
    if (!scheme.length)
        return a;
    for (LSFinchApp *app in _LSApplications())
        for (NSDictionary *d in app.info[@"CFBundleURLTypes"]) {
            if (![d isKindOfClass:[NSDictionary class]])
                continue;
            BOOL match = NO;
            for (NSString *s in strings(d[@"CFBundleURLSchemes"]))
                if ([s caseInsensitiveCompare:scheme] == NSOrderedSame)
                    match = YES;
            if (match) {
                [a addObject:app];
                break;
            }
        }
    return a;
}

#pragma mark - The user's choices

NSString *
_LSHandler(NSString *key, NSString *value)
{
    for (NSDictionary *h in [defaults() arrayForKey:@"LSHandlers"])
        if ([h isKindOfClass:[NSDictionary class]] && [h[key] isKindOfClass:[NSString class]] &&
            [h[key] caseInsensitiveCompare:value] == NSOrderedSame) {
            id b = h[@"LSHandlerRoleAll"];
            return [b isKindOfClass:[NSString class]] ? b : nil;
        }
    return nil;
}

void
_LSSetHandler(NSString *key, NSString *value, NSString *bundleID)
{
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *h in [defaults() arrayForKey:@"LSHandlers"])
        if ([h isKindOfClass:[NSDictionary class]] &&
            !([h[key] isKindOfClass:[NSString class]] && [h[key] caseInsensitiveCompare:value] == NSOrderedSame))
            [list addObject:h];
    if (bundleID)
        [list addObject:@{key : value, @"LSHandlerRoleAll" : bundleID}];
    [defaults() setObject:list forKey:@"LSHandlers"];
    [defaults() synchronize];
}

LSFinchApp *
_LSDefaultApplicationForType(NSString *uti, NSString *ext, LSRolesMask roles)
{
    NSString *chosen = uti ? _LSHandler(@"LSHandlerContentType", uti) : nil;
    if (chosen) {
        LSFinchApp *a = [_LSApplicationsWithIdentifier(chosen) firstObject];
        if (a)
            return a;
    }
    return [_LSApplicationsForType(uti, ext, roles, NO) firstObject];
}

LSFinchApp *
_LSDefaultApplicationForScheme(NSString *scheme, LSRolesMask roles)
{
    NSString *chosen = _LSHandler(@"LSHandlerURLScheme", scheme);
    if (chosen) {
        LSFinchApp *a = [_LSApplicationsWithIdentifier(chosen) firstObject];
        if (a)
            return a;
    }
    return [_LSApplicationsForScheme(scheme, roles) firstObject];
}
