/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSWorkspace, NSWorkspaceOpenConfiguration and NSRunningApplication, without
 * LaunchServices (docs/design/APPKIT.md). Apps are found by looking in the
 * application folders (/Applications, /System/Applications, ~/Applications
 * and their Utilities folders, /System/Library/CoreServices) and reading each
 * bundle's Info.plist: the bundle identifier, CFBundleDocumentTypes for the
 * files an app opens, CFBundleURLTypes for its URL schemes. An app is
 * launched by spawning its bundle's executable; the files it is asked to
 * open go on its command line (Finch has no Apple events yet). Other
 * processes are known by what the kernel says of them (proc_pidpath) and
 * their bundle's Info.plist: those inside an app bundle are "running
 * applications".
 *
 * The icons are Finch's own, drawn in code (FinchIconImage): a generic app,
 * folder, document and volume.
 */
#import "FinchPanels.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <sys/sysctl.h>

extern char **environ;

NSString *const NSWorkspaceApplicationKey = @"NSWorkspaceApplicationKey";
NSNotificationName NSWorkspaceWillLaunchApplicationNotification = @"NSWorkspaceWillLaunchApplicationNotification";
NSNotificationName NSWorkspaceDidLaunchApplicationNotification = @"NSWorkspaceDidLaunchApplicationNotification";
NSNotificationName NSWorkspaceDidTerminateApplicationNotification = @"NSWorkspaceDidTerminateApplicationNotification";
NSNotificationName const NSWorkspaceDidHideApplicationNotification = @"NSWorkspaceDidHideApplicationNotification";
NSNotificationName const NSWorkspaceDidUnhideApplicationNotification = @"NSWorkspaceDidUnhideApplicationNotification";
NSNotificationName const NSWorkspaceDidActivateApplicationNotification = @"NSWorkspaceDidActivateApplicationNotification";
NSNotificationName const NSWorkspaceDidDeactivateApplicationNotification =
    @"NSWorkspaceDidDeactivateApplicationNotification";
NSString *const NSWorkspaceVolumeLocalizedNameKey = @"NSWorkspaceVolumeLocalizedNameKey";
NSString *const NSWorkspaceVolumeURLKey = @"NSWorkspaceVolumeURLKey";
NSString *const NSWorkspaceVolumeOldLocalizedNameKey = @"NSWorkspaceVolumeOldLocalizedNameKey";
NSString *const NSWorkspaceVolumeOldURLKey = @"NSWorkspaceVolumeOldURLKey";
NSNotificationName NSWorkspaceDidMountNotification = @"NSWorkspaceDidMountNotification";
NSNotificationName NSWorkspaceDidUnmountNotification = @"NSWorkspaceDidUnmountNotification";
NSNotificationName NSWorkspaceWillUnmountNotification = @"NSWorkspaceWillUnmountNotification";
NSNotificationName const NSWorkspaceDidRenameVolumeNotification = @"NSWorkspaceDidRenameVolumeNotification";
NSNotificationName const NSWorkspaceWillPowerOffNotification = @"NSWorkspaceWillPowerOffNotification";
NSNotificationName NSWorkspaceWillSleepNotification = @"NSWorkspaceWillSleepNotification";
NSNotificationName NSWorkspaceDidWakeNotification = @"NSWorkspaceDidWakeNotification";
NSNotificationName const NSWorkspaceScreensDidSleepNotification = @"NSWorkspaceScreensDidSleepNotification";
NSNotificationName const NSWorkspaceScreensDidWakeNotification = @"NSWorkspaceScreensDidWakeNotification";
NSNotificationName NSWorkspaceSessionDidBecomeActiveNotification = @"NSWorkspaceSessionDidBecomeActiveNotification";
NSNotificationName NSWorkspaceSessionDidResignActiveNotification = @"NSWorkspaceSessionDidResignActiveNotification";
NSNotificationName const NSWorkspaceDidChangeFileLabelsNotification = @"NSWorkspaceDidChangeFileLabelsNotification";
NSNotificationName const NSWorkspaceActiveSpaceDidChangeNotification = @"NSWorkspaceActiveSpaceDidChangeNotification";
NSNotificationName const NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification =
    @"NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification";
NSNotificationName const NSWorkspaceAccessibilityFocusedElementDidChangeNotification =
    @"NSWorkspaceAccessibilityFocusedElementDidChangeNotification";
NSNotificationName const NSWorkspaceIconAppearanceConfigurationDidChangeNotification =
    @"NSWorkspaceIconAppearanceConfigurationDidChangeNotification";
NSNotificationName const NSWorkspaceMenuBarAppearanceDidChangeNotification =
    @"NSWorkspaceMenuBarAppearanceDidChangeNotification";
NSWorkspaceDesktopImageOptionKey const NSWorkspaceDesktopImageScalingKey = @"NSWorkspaceDesktopImageScalingKey";
NSWorkspaceDesktopImageOptionKey const NSWorkspaceDesktopImageAllowClippingKey =
    @"NSWorkspaceDesktopImageAllowClippingKey";
NSWorkspaceDesktopImageOptionKey const NSWorkspaceDesktopImageFillColorKey = @"NSWorkspaceDesktopImageFillColorKey";
NSString *const NSWorkspaceDesktopImageAllSpacesKey = @"NSWorkspaceDesktopImageAllSpacesKey";
NSWorkspaceLaunchConfigurationKey const NSWorkspaceLaunchConfigurationAppleEvent =
    @"NSWorkspaceLaunchConfigurationAppleEvent";
NSWorkspaceLaunchConfigurationKey const NSWorkspaceLaunchConfigurationArguments =
    @"NSWorkspaceLaunchConfigurationArguments";
NSWorkspaceLaunchConfigurationKey const NSWorkspaceLaunchConfigurationEnvironment =
    @"NSWorkspaceLaunchConfigurationEnvironment";
NSWorkspaceLaunchConfigurationKey const NSWorkspaceLaunchConfigurationArchitecture =
    @"NSWorkspaceLaunchConfigurationArchitecture";
NSWorkspaceFileOperationName NSWorkspaceMoveOperation = @"move";
NSWorkspaceFileOperationName NSWorkspaceCopyOperation = @"copy";
NSWorkspaceFileOperationName NSWorkspaceLinkOperation = @"link";
NSWorkspaceFileOperationName NSWorkspaceCompressOperation = @"compress";
NSWorkspaceFileOperationName NSWorkspaceDecompressOperation = @"decompress";
NSWorkspaceFileOperationName NSWorkspaceEncryptOperation = @"encrypt";
NSWorkspaceFileOperationName NSWorkspaceDecryptOperation = @"decrypt";
NSWorkspaceFileOperationName NSWorkspaceDestroyOperation = @"destroy";
NSWorkspaceFileOperationName NSWorkspaceRecycleOperation = @"recycle";
NSWorkspaceFileOperationName NSWorkspaceDuplicateOperation = @"duplicate";
NSNotificationName NSWorkspaceDidPerformFileOperationNotification = @"NSWorkspaceDidPerformFileOperationNotification";
NSString *NSPlainFileType = @"";
NSString *NSDirectoryFileType = @"NXDirectoryFileType";
NSString *NSApplicationFileType = @"app";
NSString *NSFilesystemFileType = @"NXFilesystemFileType";
NSString *NSShellCommandFileType = @"NXShellCommandFileType";

#pragma mark - Types and icons

Class
FinchUTTypeClass(void)
{
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_getClass("UTType");
        if (!cls) {
            dlopen("/System/Library/Frameworks/UniformTypeIdentifiers.framework/UniformTypeIdentifiers",
                   RTLD_LAZY | RTLD_GLOBAL);
            cls = objc_getClass("UTType");
        }
    });
    return cls;
}

static UTType *
type_named(NSString *identifier)
{
    return identifier ? [FinchUTTypeClass() typeWithIdentifier:identifier] : nil;
}

static UTType *
type_of_url(NSURL *url)
{
    FinchUTTypeClass();  /* NSURL's content type needs it loaded */
    UTType *t = nil;
    [url getResourceValue:&t forKey:NSURLContentTypeKey error:NULL];
    return t;
}

static void
fill_round_rect(NSRect r, CGFloat radius, NSColor *color)
{
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill];
}

static NSColor *
rgb(CGFloat r, CGFloat g, CGFloat b)
{
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1];
}

static void
draw_icon(FinchIconKind kind, NSRect b)
{
    CGFloat s = b.size.width, x = b.origin.x, y = b.origin.y;
    switch (kind) {
    case FinchIconApplication: {
        /* a rounded tile in the accent blue, a white window on it */
        NSRect tile = NSMakeRect(x + s * 0.09, y + s * 0.09, s * 0.82, s * 0.82);
        NSGradient *g = [[NSGradient alloc] initWithStartingColor:rgb(0.36, 0.66, 1.0) endingColor:rgb(0.0, 0.40, 0.88)];
        [g drawInBezierPath:[NSBezierPath bezierPathWithRoundedRect:tile xRadius:s * 0.19 yRadius:s * 0.19] angle:-90];
        [g release];
        NSRect win = NSMakeRect(x + s * 0.25, y + s * 0.28, s * 0.50, s * 0.42);
        fill_round_rect(win, s * 0.05, [NSColor whiteColor]);
        fill_round_rect(NSMakeRect(win.origin.x, NSMaxY(win) - s * 0.09, win.size.width, s * 0.09), s * 0.04,
                        rgb(0.80, 0.88, 1.0));
        [rgb(0.0, 0.40, 0.88) setFill];
        NSRectFill(NSMakeRect(win.origin.x + s * 0.07, win.origin.y + s * 0.20, s * 0.30, s * 0.035));
        NSRectFill(NSMakeRect(win.origin.x + s * 0.07, win.origin.y + s * 0.12, s * 0.22, s * 0.035));
        break;
    }
    case FinchIconFolder:
        fill_round_rect(NSMakeRect(x + s * 0.08, y + s * 0.62, s * 0.36, s * 0.14), s * 0.04, rgb(0.42, 0.68, 0.95));
        fill_round_rect(NSMakeRect(x + s * 0.08, y + s * 0.16, s * 0.84, s * 0.54), s * 0.06, rgb(0.42, 0.68, 0.95));
        fill_round_rect(NSMakeRect(x + s * 0.08, y + s * 0.16, s * 0.84, s * 0.48), s * 0.06, rgb(0.55, 0.78, 0.99));
        break;
    case FinchIconDocument: {
        CGFloat l = x + s * 0.20, r = x + s * 0.80, t = y + s * 0.92, bt = y + s * 0.08, fold = s * 0.18;
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(l, bt)];
        [p lineToPoint:NSMakePoint(r, bt)];
        [p lineToPoint:NSMakePoint(r, t - fold)];
        [p lineToPoint:NSMakePoint(r - fold, t)];
        [p lineToPoint:NSMakePoint(l, t)];
        [p closePath];
        [[NSColor whiteColor] setFill];
        [p fill];
        [rgb(0.70, 0.72, 0.76) setStroke];
        [p setLineWidth:MAX(1, s / 64)];
        [p stroke];
        NSBezierPath *f = [NSBezierPath bezierPath];
        [f moveToPoint:NSMakePoint(r - fold, t)];
        [f lineToPoint:NSMakePoint(r - fold, t - fold)];
        [f lineToPoint:NSMakePoint(r, t - fold)];
        [f closePath];
        [rgb(0.86, 0.87, 0.90) setFill];
        [f fill];
        [f setLineWidth:MAX(1, s / 64)];
        [f stroke];
        [rgb(0.78, 0.80, 0.84) setFill];
        for (int i = 0; i < 5; i++)
            NSRectFill(NSMakeRect(l + s * 0.10, bt + s * (0.18 + 0.11 * i), s * (i == 4 ? 0.25 : 0.40), MAX(1, s * 0.03)));
        break;
    }
    case FinchIconVolume:
        fill_round_rect(NSMakeRect(x + s * 0.08, y + s * 0.28, s * 0.84, s * 0.44), s * 0.08, rgb(0.62, 0.65, 0.70));
        fill_round_rect(NSMakeRect(x + s * 0.08, y + s * 0.28, s * 0.84, s * 0.20), s * 0.08, rgb(0.50, 0.53, 0.58));
        fill_round_rect(NSMakeRect(x + s * 0.74, y + s * 0.34, s * 0.08, s * 0.08), s * 0.04, rgb(0.30, 0.85, 0.40));
        break;
    case FinchIconCaution: {
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(x + s * 0.5, y + s * 0.92)];
        [p lineToPoint:NSMakePoint(x + s * 0.96, y + s * 0.10)];
        [p lineToPoint:NSMakePoint(x + s * 0.04, y + s * 0.10)];
        [p closePath];
        [p setLineJoinStyle:NSLineJoinStyleRound];
        [p setLineWidth:s * 0.08];
        [rgb(1.0, 0.80, 0.0) set];
        [p fill];
        [p stroke];
        [rgb(0.15, 0.15, 0.15) setFill];
        fill_round_rect(NSMakeRect(x + s * 0.455, y + s * 0.38, s * 0.09, s * 0.36), s * 0.04, rgb(0.15, 0.15, 0.15));
        fill_round_rect(NSMakeRect(x + s * 0.45, y + s * 0.18, s * 0.10, s * 0.10), s * 0.05, rgb(0.15, 0.15, 0.15));
        break;
    }
    }
}

NSImage *
FinchIconImage(FinchIconKind kind, CGFloat size)
{
    return [NSImage imageWithSize:NSMakeSize(size, size) flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                       draw_icon(kind, r);
                       return YES;
                   }];
}

NSImage *
FinchApplicationIcon(void)
{
    NSImage *i = [NSApp applicationIconImage];
    if (!i)
        i = [NSImage imageNamed:NSImageNameApplicationIcon];
    if (!i)
        i = FinchIconImage(FinchIconApplication, 128);
    return i;
}

/* An image of another drawn at `size` (not a copy: NSCustomImageRep's copies share their handler). */
static NSImage *
sized(NSImage *i, CGFloat size)
{
    if (NSEqualSizes([i size], NSMakeSize(size, size)))
        return i;
    return [NSImage imageWithSize:NSMakeSize(size, size) flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                       [i drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
                       return YES;
                   }];
}

/* The icon an app bundle names in its Info.plist, if Finch can read it. */
static NSImage *
bundle_icon(NSURL *app, NSDictionary *info)
{
    NSString *name = info[@"CFBundleIconFile"];
    if (![name isKindOfClass:[NSString class]] || !name.length)
        return nil;
    NSURL *res = [app URLByAppendingPathComponent:@"Contents/Resources"];
    NSURL *u = [res URLByAppendingPathComponent:name];
    if (!name.pathExtension.length)
        u = [u URLByAppendingPathExtension:@"icns"];
    NSImage *i = [[[NSImage alloc] initWithContentsOfURL:u] autorelease];
    return [[i representations] count] ? i : nil;
}

#pragma mark - Apps on disk

static NSDictionary *
app_info(NSURL *app)
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"Contents/Info.plist"]];
    if (!d)
        d = [NSDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"Info.plist"]];
    return d;
}

static NSURL *
app_executable(NSURL *app, NSDictionary *info)
{
    NSString *exe = info[@"CFBundleExecutable"];
    if (![exe isKindOfClass:[NSString class]] || !exe.length)
        exe = [[app lastPathComponent] stringByDeletingPathExtension];
    NSURL *u = [app URLByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:exe]];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:[u path]]) {
        NSURL *flat = [app URLByAppendingPathComponent:exe];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:[flat path]])
            return flat;
    }
    return u;
}

static NSArray<NSURL *> *
app_folders(void)
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *p in @[ @"/Applications", @"/Applications/Utilities", @"/System/Applications",
                           @"/System/Applications/Utilities", @"/System/Library/CoreServices" ])
        [a addObject:[NSURL fileURLWithPath:p isDirectory:YES]];
    NSString *home = NSHomeDirectory();
    [a addObject:[NSURL fileURLWithPath:[home stringByAppendingPathComponent:@"Applications"] isDirectory:YES]];
    [a addObject:[NSURL fileURLWithPath:[home stringByAppendingPathComponent:@"Applications/Utilities"]
                            isDirectory:YES]];
    return a;
}

/* Every app bundle in the application folders, in search order. */
static NSArray<NSURL *> *
all_apps(void)
{
    NSMutableArray *a = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSURL *dir in app_folders()) {
        NSArray *items = [fm contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:NULL];
        items = [items sortedArrayUsingComparator:^NSComparisonResult(NSURL *x, NSURL *y) {
            return [[x lastPathComponent] compare:[y lastPathComponent]];
        }];
        for (NSURL *u in items)
            if ([[[u pathExtension] lowercaseString] isEqualToString:@"app"])
                [a addObject:u];
    }
    return a;
}

static NSArray<NSURL *> *
apps_with_identifier(NSString *identifier)
{
    NSMutableArray *a = [NSMutableArray array];
    if (!identifier.length)
        return a;
    NSBundle *main = [NSBundle mainBundle];
    if ([[main bundleIdentifier] caseInsensitiveCompare:identifier] == NSOrderedSame &&
        [[[main bundlePath] pathExtension] isEqualToString:@"app"])
        [a addObject:[main bundleURL]];
    for (NSURL *u in all_apps()) {
        NSString *bid = app_info(u)[@"CFBundleIdentifier"];
        if ([bid isKindOfClass:[NSString class]] && [bid caseInsensitiveCompare:identifier] == NSOrderedSame &&
            ![a containsObject:u])
            [a addObject:u];
    }
    return a;
}

/*
 * How well an app's CFBundleDocumentTypes take a type (or a file's extension):
 * 0 not at all; then, as LaunchServices ranks them, a claim on everything
 * ("*", public.item, public.data, public.content) below an "Alternate" one,
 * below "Default", below "Owner". LSHandlerRank "None" doesn't count.
 */
static int
app_rank(NSDictionary *info, UTType *type, NSString *ext)
{
    static NSSet *generic;
    if (!generic)
        generic = [[NSSet alloc] initWithObjects:@"public.item", @"public.data", @"public.content", @"*", nil];
    int best = 0;
    for (NSDictionary *d in info[@"CFBundleDocumentTypes"]) {
        if (![d isKindOfClass:[NSDictionary class]])
            continue;
        NSString *rank = d[@"LSHandlerRank"];
        if ([rank isEqual:@"None"])
            continue;
        int r = [rank isEqual:@"Owner"] ? 4 : [rank isEqual:@"Alternate"] ? 2 : 3;
        for (NSString *t in d[@"LSItemContentTypes"]) {
            if (![t isKindOfClass:[NSString class]])
                continue;
            UTType *ut = type_named(t);
            if (ut && type && [type conformsToType:ut])
                best = MAX(best, [generic containsObject:[t lowercaseString]] ? 1 : r);
        }
        for (NSString *e in d[@"CFBundleTypeExtensions"]) {
            if (![e isKindOfClass:[NSString class]])
                continue;
            if ([e isEqualToString:@"*"])
                best = MAX(best, 1);
            else if (ext.length && [e caseInsensitiveCompare:ext] == NSOrderedSame)
                best = MAX(best, r);
        }
    }
    return best;
}

static BOOL
app_handles_scheme(NSDictionary *info, NSString *scheme)
{
    for (NSDictionary *d in info[@"CFBundleURLTypes"])
        if ([d isKindOfClass:[NSDictionary class]])
            for (NSString *s in d[@"CFBundleURLSchemes"])
                if ([s isKindOfClass:[NSString class]] && [s caseInsensitiveCompare:scheme] == NSOrderedSame)
                    return YES;
    return NO;
}

/* Apps that open a type, best first; `specific` leaves out those that only claim everything. */
static NSArray<NSURL *> *
apps_for_type(UTType *type, NSString *ext, BOOL specific)
{
    NSMutableArray *a = [NSMutableArray array];
    if (!type && !ext)
        return a;
    NSMutableArray *ranks = [NSMutableArray array];
    for (NSURL *u in all_apps()) {
        int r = app_rank(app_info(u), type, ext);
        if (r > (specific ? 1 : 0)) {
            NSUInteger i = 0;
            while (i < ranks.count && [ranks[i] intValue] >= r)
                i++;
            [ranks insertObject:@(r) atIndex:i];
            [a insertObject:u atIndex:i];
        }
    }
    return a;
}

static NSArray<NSURL *> *
apps_for_url(NSURL *url, BOOL specific)
{
    if ([url isFileURL]) {
        NSNumber *pkg = nil;
        [url getResourceValue:&pkg forKey:NSURLIsApplicationKey error:NULL];
        if ([pkg boolValue])
            return @[];
        return apps_for_type(type_of_url(url), [url pathExtension], specific);
    }
    NSMutableArray *a = [NSMutableArray array];
    NSString *scheme = [url scheme];
    if (!scheme.length)
        return a;
    for (NSURL *u in all_apps())
        if (app_handles_scheme(app_info(u), scheme))
            [a addObject:u];
    return a;
}

static NSError *
ws_error(NSInteger code, NSURL *url, NSString *description)
{
    NSMutableDictionary *ui = [NSMutableDictionary dictionary];
    if (url)
        ui[NSURLErrorKey] = url;
    if (description)
        ui[NSLocalizedDescriptionKey] = description;
    return [NSError errorWithDomain:NSCocoaErrorDomain code:code userInfo:ui];
}

#pragma mark - NSRunningApplication

@interface NSRunningApplication ()
- (instancetype)_finchInitWithPID:(pid_t)pid;
- (instancetype)_finchInitWithPID:(pid_t)pid bundle:(NSString *)app executable:(NSString *)exe;
- (void)_finchSetTerminated;
@end

static NSString *
path_for_pid(pid_t pid)
{
    char buf[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, buf, sizeof buf) <= 0)
        return nil;
    return [[NSFileManager defaultManager] stringWithFileSystemRepresentation:buf length:strlen(buf)];
}

/* The app bundle an executable is in: .../X.app/Contents/MacOS/x. */
static NSString *
bundle_of_executable(NSString *path)
{
    NSString *macos = [path stringByDeletingLastPathComponent];
    NSString *contents = [macos stringByDeletingLastPathComponent];
    NSString *app = [contents stringByDeletingLastPathComponent];
    if ([[macos lastPathComponent] isEqualToString:@"MacOS"] && [[contents lastPathComponent] isEqualToString:@"Contents"] &&
        [[[app pathExtension] lowercaseString] isEqualToString:@"app"])
        return app;
    return nil;
}

static NSMutableDictionary *launched;  /* pid -> NSRunningApplication, for apps this process launched */

@implementation NSRunningApplication {
    pid_t _pid;
    NSString *_bundleIdentifier;
    NSURL *_bundleURL;
    NSURL *_executableURL;
    NSString *_localizedName;
    NSDate *_launchDate;
    NSApplicationActivationPolicy _policy;
    BOOL _terminated;
    BOOL _current;
}

- (instancetype)_finchInitWithPID:(pid_t)pid
{
    return [self _finchInitWithPID:pid bundle:nil executable:nil];
}

/* An app given its bundle and executable (as launched: a script's process is its interpreter's). */
- (instancetype)_finchInitWithPID:(pid_t)pid bundle:(NSString *)knownApp executable:(NSString *)knownExe
{
    if (!(self = [super init]))
        return nil;
    _pid = pid;
    _current = pid == getpid();
    NSString *exe = nil;
    NSDictionary *info = nil;
    if (_current) {
        NSBundle *main = [NSBundle mainBundle];
        exe = [[main executablePath] stringByResolvingSymlinksInPath] ?: path_for_pid(pid);
        info = [main infoDictionary];
        _bundleIdentifier = [[main bundleIdentifier] copy];
        if ([[[main bundlePath] pathExtension] isEqualToString:@"app"])
            _bundleURL = [[main bundleURL] retain];
        else if (exe)
            _bundleURL = [[NSURL fileURLWithPath:exe isDirectory:YES] retain];  /* as Apple's, for a tool */
        if (NSApp)
            _policy = [NSApp activationPolicy];
        else
            _policy = [info[@"LSBackgroundOnly"] boolValue] ? NSApplicationActivationPolicyProhibited
                      : [info[@"LSUIElement"] boolValue]    ? NSApplicationActivationPolicyAccessory
                                                            : NSApplicationActivationPolicyRegular;
    } else {
        exe = knownExe ?: path_for_pid(pid);
        NSString *app = knownApp ?: (exe ? bundle_of_executable(exe) : nil);
        if (!app) {
            [self release];
            return nil;
        }
        _bundleURL = [[NSURL fileURLWithPath:app isDirectory:YES] retain];
        info = app_info(_bundleURL);
        id bid = info[@"CFBundleIdentifier"];
        _bundleIdentifier = [bid isKindOfClass:[NSString class]] ? [bid copy] : nil;
        _policy = [info[@"LSBackgroundOnly"] boolValue] ? NSApplicationActivationPolicyProhibited
                  : [info[@"LSUIElement"] boolValue]    ? NSApplicationActivationPolicyAccessory
                                                        : NSApplicationActivationPolicyRegular;
    }
    if (exe)
        _executableURL = [[NSURL fileURLWithPath:exe isDirectory:NO] retain];
    id name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
    if (![name isKindOfClass:[NSString class]] || ![name length])
        name = _bundleURL && [[[_bundleURL path] pathExtension] isEqualToString:@"app"]
                   ? [[[_bundleURL path] lastPathComponent] stringByDeletingPathExtension]
                   : [exe lastPathComponent];
    _localizedName = [name copy];
    if ([[[_bundleURL path] pathExtension] isEqualToString:@"app"]) {
        struct proc_bsdinfo bi;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == sizeof bi)
            _launchDate = [[NSDate alloc] initWithTimeIntervalSince1970:bi.pbi_start_tvsec +
                                                                        bi.pbi_start_tvusec / 1e6];
    }
    return self;
}

- (void)dealloc
{
    [_bundleIdentifier release];
    [_bundleURL release];
    [_executableURL release];
    [_localizedName release];
    [_launchDate release];
    [super dealloc];
}

+ (instancetype)currentApplication
{
    return [[[self alloc] _finchInitWithPID:getpid()] autorelease];
}

+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid
{
    if (pid <= 0)
        return nil;
    @synchronized([NSRunningApplication class]) {
        NSRunningApplication *a = launched[@(pid)];
        if (a && !a->_terminated)
            return [[a retain] autorelease];
    }
    if (pid != getpid() && kill(pid, 0) != 0 && errno == ESRCH)
        return nil;
    return [[[self alloc] _finchInitWithPID:pid] autorelease];
}

+ (NSArray<NSRunningApplication *> *)_finchAll
{
    NSMutableArray *a = [NSMutableArray array];
    int n = proc_listallpids(NULL, 0);
    if (n <= 0)
        return @[ [self currentApplication] ];
    pid_t *pids = calloc(n + 64, sizeof *pids);
    n = proc_listallpids(pids, (int)((n + 64) * sizeof *pids));
    NSMutableArray *sorted = [NSMutableArray array];
    for (int i = 0; i < n; i++)
        [sorted addObject:@(pids[i])];
    free(pids);
    [sorted sortUsingSelector:@selector(compare:)];
    for (NSNumber *p in sorted) {
        NSRunningApplication *r = [self runningApplicationWithProcessIdentifier:[p intValue]];
        if (r)
            [a addObject:r];
    }
    return a;
}

+ (NSArray<NSRunningApplication *> *)runningApplicationsWithBundleIdentifier:(NSString *)bundleIdentifier
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSRunningApplication *r in [self _finchAll])
        if (r->_bundleIdentifier && [r->_bundleIdentifier caseInsensitiveCompare:bundleIdentifier] == NSOrderedSame)
            [a addObject:r];
    return a;
}

+ (void)terminateAutomaticallyTerminableApplications {}

- (BOOL)isEqual:(id)other
{
    return other == self || ([other isKindOfClass:[NSRunningApplication class]] &&
                             ((NSRunningApplication *)other)->_pid == _pid);
}

- (NSUInteger)hash { return (NSUInteger)_pid; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p (%@ - %d)>", [self className], self, _bundleIdentifier, _pid];
}

- (void)_finchSetTerminated
{
    [self willChangeValueForKey:@"terminated"];
    _terminated = YES;
    [self didChangeValueForKey:@"terminated"];
}

- (BOOL)isTerminated
{
    if (_terminated)
        return YES;
    if (_current)
        return NO;
    return kill(_pid, 0) != 0 && errno == ESRCH;
}

- (BOOL)isFinishedLaunching
{
    if (_current)
        return NSApp && [[[_bundleURL path] pathExtension] isEqualToString:@"app"];
    return ![self isTerminated];
}

- (BOOL)isHidden { return _current ? [NSApp isHidden] : NO; }
- (BOOL)isActive { return _current ? [NSApp isActive] : NO; }
- (BOOL)ownsMenuBar { return _current && [NSApp isActive] && [NSApp mainMenu] != nil; }
- (NSApplicationActivationPolicy)activationPolicy { return _current && NSApp ? [NSApp activationPolicy] : _policy; }
- (NSString *)localizedName { return _localizedName; }
- (NSString *)bundleIdentifier { return _bundleIdentifier; }
- (NSURL *)bundleURL { return _bundleURL; }
- (NSURL *)executableURL { return _executableURL; }
- (pid_t)processIdentifier { return _pid; }
- (NSDate *)launchDate { return _launchDate; }
- (NSInteger)executableArchitecture { return NSBundleExecutableArchitectureARM64; }

- (NSImage *)icon
{
    NSImage *i = nil;
    if (_current)
        i = FinchApplicationIcon();
    else if (_bundleURL)
        i = bundle_icon(_bundleURL, app_info(_bundleURL));
    return i ? sized(i, 32) : FinchIconImage(FinchIconApplication, 32);
}

- (BOOL)hide
{
    if (!_current)
        return NO;
    [NSApp hide:nil];
    return YES;
}

- (BOOL)unhide
{
    if (!_current)
        return NO;
    [NSApp unhide:nil];
    return YES;
}

- (BOOL)activateWithOptions:(NSApplicationActivationOptions)options
{
    if (!_current)
        return NO;
    [NSApp activateIgnoringOtherApps:YES];
    return YES;
}

- (BOOL)activateFromApplication:(NSRunningApplication *)application options:(NSApplicationActivationOptions)options
{
    return [self activateWithOptions:options];
}

- (BOOL)terminate
{
    if (_current) {
        [NSApp terminate:nil];
        return YES;
    }
    return ![self isTerminated] && kill(_pid, SIGTERM) == 0;
}

- (BOOL)forceTerminate
{
    if ([self isTerminated])
        return NO;
    return kill(_pid, SIGKILL) == 0;
}

@end

#pragma mark - NSWorkspaceOpenConfiguration

@implementation NSWorkspaceOpenConfiguration {
    BOOL _promptsUserIfNeeded, _addsToRecentItems, _activates, _hides, _hidesOthers, _forPrinting;
    BOOL _createsNewApplicationInstance, _allowsRunningApplicationSubstitution, _requiresUniversalLinks;
    NSArray *_arguments;
    NSDictionary *_environment;
    NSAppleEventDescriptor *_appleEvent;
    cpu_type_t _architecture;
}

+ (instancetype)configuration
{
    return [[[self alloc] init] autorelease];
}

- (instancetype)init
{
    if ((self = [super init])) {
        _promptsUserIfNeeded = _addsToRecentItems = _activates = _allowsRunningApplicationSubstitution = YES;
        _arguments = [@[] retain];
        _environment = [@{} retain];
        _architecture = -1;
    }
    return self;
}

- (void)dealloc
{
    [_arguments release];
    [_environment release];
    [_appleEvent release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSWorkspaceOpenConfiguration *c = [[[self class] alloc] init];
    c->_promptsUserIfNeeded = _promptsUserIfNeeded;
    c->_addsToRecentItems = _addsToRecentItems;
    c->_activates = _activates;
    c->_hides = _hides;
    c->_hidesOthers = _hidesOthers;
    c->_forPrinting = _forPrinting;
    c->_createsNewApplicationInstance = _createsNewApplicationInstance;
    c->_allowsRunningApplicationSubstitution = _allowsRunningApplicationSubstitution;
    c->_requiresUniversalLinks = _requiresUniversalLinks;
    [c setArguments:_arguments];
    [c setEnvironment:_environment];
    [c setAppleEvent:_appleEvent];
    c->_architecture = _architecture;
    return c;
}

- (BOOL)promptsUserIfNeeded { return _promptsUserIfNeeded; }
- (void)setPromptsUserIfNeeded:(BOOL)f { _promptsUserIfNeeded = f; }
- (BOOL)addsToRecentItems { return _addsToRecentItems; }
- (void)setAddsToRecentItems:(BOOL)f { _addsToRecentItems = f; }
- (BOOL)activates { return _activates; }
- (void)setActivates:(BOOL)f { _activates = f; }
- (BOOL)hides { return _hides; }
- (void)setHides:(BOOL)f { _hides = f; }
- (BOOL)hidesOthers { return _hidesOthers; }
- (void)setHidesOthers:(BOOL)f { _hidesOthers = f; }
- (BOOL)isForPrinting { return _forPrinting; }
- (void)setForPrinting:(BOOL)f { _forPrinting = f; }
- (BOOL)createsNewApplicationInstance { return _createsNewApplicationInstance; }
- (void)setCreatesNewApplicationInstance:(BOOL)f { _createsNewApplicationInstance = f; }
- (BOOL)allowsRunningApplicationSubstitution { return _allowsRunningApplicationSubstitution; }
- (void)setAllowsRunningApplicationSubstitution:(BOOL)f { _allowsRunningApplicationSubstitution = f; }
- (BOOL)requiresUniversalLinks { return _requiresUniversalLinks; }
- (void)setRequiresUniversalLinks:(BOOL)f { _requiresUniversalLinks = f; }
- (NSArray<NSString *> *)arguments { return _arguments; }
- (void)setArguments:(NSArray<NSString *> *)a { [_arguments autorelease]; _arguments = [(a ?: @[]) copy]; }
- (NSDictionary<NSString *, NSString *> *)environment { return _environment; }
- (void)setEnvironment:(NSDictionary<NSString *, NSString *> *)e { [_environment autorelease]; _environment = [(e ?: @{}) copy]; }
- (NSAppleEventDescriptor *)appleEvent { return _appleEvent; }
- (void)setAppleEvent:(NSAppleEventDescriptor *)e { [_appleEvent autorelease]; _appleEvent = [e retain]; }
- (cpu_type_t)architecture { return _architecture; }
- (void)setArchitecture:(cpu_type_t)a { _architecture = a; }

@end

#pragma mark - NSWorkspace

@implementation NSWorkspace {
    NSNotificationCenter *_center;
}

+ (NSWorkspace *)sharedWorkspace
{
    static NSWorkspace *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[NSWorkspace alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init]))
        _center = [[NSNotificationCenter alloc] init];
    return self;
}

- (NSNotificationCenter *)notificationCenter { return _center; }

#pragma mark Launching

static NSDictionary *
launch_user_info(NSRunningApplication *app)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[NSWorkspaceApplicationKey] = app;
    if ([app localizedName])
        d[@"NSApplicationName"] = [app localizedName];
    if ([[app executableURL] path])
        d[@"NSApplicationPath"] = [[app bundleURL] path] ?: [[app executableURL] path];
    d[@"NSApplicationProcessIdentifier"] = @([app processIdentifier]);
    d[@"NSApplicationProcessSerialNumberHigh"] = @0;
    d[@"NSApplicationProcessSerialNumberLow"] = @([app processIdentifier]);
    if ([app bundleIdentifier])
        d[@"NSApplicationBundleIdentifier"] = [app bundleIdentifier];
    return d;
}

static void
post_on_main(NSNotificationCenter *center, NSString *name, NSRunningApplication *app)
{
    dispatch_block_t b = ^{
        [center postNotificationName:name object:[NSWorkspace sharedWorkspace] userInfo:launch_user_info(app)];
    };
    if ([NSThread isMainThread])
        b();
    else
        dispatch_async(dispatch_get_main_queue(), b);
}

/* Spawn an app bundle's executable; the result is reaped and its exit posted. */
- (NSRunningApplication *)_finchLaunchApp:(NSURL *)app files:(NSArray<NSURL *> *)files
                            configuration:(NSWorkspaceOpenConfiguration *)config error:(NSError **)error
{
    NSDictionary *info = app_info(app);
    if (!info && ![[NSFileManager defaultManager] fileExistsAtPath:[app path]]) {
        if (error)
            *error = ws_error(NSFileReadNoSuchFileError, app,
                              [NSString stringWithFormat:@"The application “%@” can’t be opened.",
                                                         [[app lastPathComponent] stringByDeletingPathExtension]]);
        return nil;
    }
    NSString *bid = info[@"CFBundleIdentifier"];
    if (![config createsNewApplicationInstance] && [bid isKindOfClass:[NSString class]]) {
        for (NSRunningApplication *r in [NSRunningApplication runningApplicationsWithBundleIdentifier:bid])
            if ([[[r bundleURL] URLByStandardizingPath] isEqual:[app URLByStandardizingPath]] ||
                [[[r bundleURL] path] isEqualToString:[app path]]) {
                if ([config activates])
                    [r activateWithOptions:0];
                return r;
            }
    }
    NSURL *exe = app_executable(app, info);
    const char *path = [exe fileSystemRepresentation];
    if (access(path, X_OK) != 0) {
        if (error)
            *error = ws_error(NSFileReadUnknownError, app,
                              [NSString stringWithFormat:@"The application “%@” can’t be opened.",
                                                         [[app lastPathComponent] stringByDeletingPathExtension]]);
        return nil;
    }
    NSMutableArray *argv = [NSMutableArray arrayWithObject:[exe path]];
    [argv addObjectsFromArray:[config arguments] ?: @[]];
    for (NSURL *f in files)
        [argv addObject:[f isFileURL] ? [f path] : [f absoluteString]];
    NSMutableDictionary *env = [[[[NSProcessInfo processInfo] environment] mutableCopy] autorelease];
    [env addEntriesFromDictionary:[config environment] ?: @{}];
    size_t n = [argv count];
    char **cargv = calloc(n + 1, sizeof *cargv);
    for (size_t i = 0; i < n; i++)
        cargv[i] = strdup([argv[i] UTF8String]);
    NSArray *keys = [env allKeys];
    char **cenv = calloc([keys count] + 1, sizeof *cenv);
    for (size_t i = 0; i < [keys count]; i++)
        cenv[i] = strdup([[NSString stringWithFormat:@"%@=%@", keys[i], env[keys[i]]] UTF8String]);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    pid_t pid = 0;
    int err = posix_spawn(&pid, path, NULL, &attr, cargv, cenv);
    posix_spawnattr_destroy(&attr);
    for (size_t i = 0; i < n; i++)
        free(cargv[i]);
    free(cargv);
    for (size_t i = 0; cenv[i]; i++)
        free(cenv[i]);
    free(cenv);
    if (err) {
        if (error)
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:@{NSURLErrorKey : app}];
        return nil;
    }
    NSRunningApplication *r = [[[NSRunningApplication alloc] _finchInitWithPID:pid bundle:[app path]
                                                                    executable:[exe path]] autorelease];
    @synchronized([NSRunningApplication class]) {
        if (!launched)
            launched = [[NSMutableDictionary alloc] init];
        launched[@(pid)] = r;
    }
    post_on_main(_center, NSWorkspaceWillLaunchApplicationNotification, r);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT,
                                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    NSNotificationCenter *center = _center;
    [r retain];
    dispatch_source_set_event_handler(src, ^{
        int status;
        waitpid(pid, &status, WNOHANG);
        [r _finchSetTerminated];
        @synchronized([NSRunningApplication class]) {
            [launched removeObjectForKey:@(pid)];
        }
        post_on_main(center, NSWorkspaceDidTerminateApplicationNotification, r);
        [r release];
        dispatch_source_cancel(src);
        dispatch_release(src);
    });
    dispatch_resume(src);
    post_on_main(_center, NSWorkspaceDidLaunchApplicationNotification, r);
    return r;
}

static void
finish(void (^handler)(NSRunningApplication *, NSError *), NSRunningApplication *app, NSError *error)
{
    if (!handler)
        return;
    handler = [[handler copy] autorelease];
    [app retain];
    [error retain];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        handler(app, error);
        [app release];
        [error release];
    });
}

- (void)openApplicationAtURL:(NSURL *)applicationURL configuration:(NSWorkspaceOpenConfiguration *)configuration
           completionHandler:(void (^)(NSRunningApplication *, NSError *))completionHandler
{
    NSError *e = nil;
    NSRunningApplication *r = [self _finchLaunchApp:applicationURL files:nil
                                      configuration:configuration ?: [NSWorkspaceOpenConfiguration configuration]
                                              error:&e];
    finish(completionHandler, r, e);
}

- (void)openURLs:(NSArray<NSURL *> *)urls withApplicationAtURL:(NSURL *)applicationURL
        configuration:(NSWorkspaceOpenConfiguration *)configuration
    completionHandler:(void (^)(NSRunningApplication *, NSError *))completionHandler
{
    NSError *e = nil;
    NSRunningApplication *r = [self _finchLaunchApp:applicationURL files:urls
                                      configuration:configuration ?: [NSWorkspaceOpenConfiguration configuration]
                                              error:&e];
    finish(completionHandler, r, e);
}

- (NSRunningApplication *)_finchOpenURL:(NSURL *)url configuration:(NSWorkspaceOpenConfiguration *)config
                                   error:(NSError **)error
{
    if (!url)
        return nil;
    if ([url isFileURL]) {
        NSNumber *isApp = nil;
        [url getResourceValue:&isApp forKey:NSURLIsApplicationKey error:NULL];
        if ([isApp boolValue])
            return [self _finchLaunchApp:url files:nil configuration:config error:error];
        if (![[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
            if (error)
                *error = ws_error(NSFileReadNoSuchFileError, url,
                                  [NSString stringWithFormat:@"The file “%@” couldn’t be opened because there is no such file.",
                                                             [url lastPathComponent]]);
            return nil;
        }
    }
    NSURL *app = [self URLForApplicationToOpenURL:url];
    if (!app) {
        if (error)
            *error = ws_error(NSFileReadUnknownError, url,
                              [NSString stringWithFormat:@"There is no application set to open “%@”.",
                                                         [url isFileURL] ? [url lastPathComponent] : [url absoluteString]]);
        return nil;
    }
    return [self _finchLaunchApp:app files:@[ url ] configuration:config error:error];
}

- (BOOL)openURL:(NSURL *)url
{
    return [self _finchOpenURL:url configuration:[NSWorkspaceOpenConfiguration configuration] error:NULL] != nil;
}

- (void)openURL:(NSURL *)url configuration:(NSWorkspaceOpenConfiguration *)configuration
    completionHandler:(void (^)(NSRunningApplication *, NSError *))completionHandler
{
    NSError *e = nil;
    NSRunningApplication *r = [self _finchOpenURL:url
                                    configuration:configuration ?: [NSWorkspaceOpenConfiguration configuration]
                                            error:&e];
    finish(completionHandler, r, e);
}

static NSWorkspaceOpenConfiguration *
config_from(NSDictionary *d, NSWorkspaceLaunchOptions options)
{
    NSWorkspaceOpenConfiguration *c = [NSWorkspaceOpenConfiguration configuration];
    if (d[NSWorkspaceLaunchConfigurationArguments])
        [c setArguments:d[NSWorkspaceLaunchConfigurationArguments]];
    if (d[NSWorkspaceLaunchConfigurationEnvironment])
        [c setEnvironment:d[NSWorkspaceLaunchConfigurationEnvironment]];
    [c setCreatesNewApplicationInstance:(options & NSWorkspaceLaunchNewInstance) != 0];
    [c setActivates:(options & NSWorkspaceLaunchWithoutActivation) == 0];
    [c setHides:(options & NSWorkspaceLaunchAndHide) != 0];
    return c;
}

- (NSRunningApplication *)launchApplicationAtURL:(NSURL *)url options:(NSWorkspaceLaunchOptions)options
                                   configuration:(NSDictionary<NSWorkspaceLaunchConfigurationKey, id> *)configuration
                                           error:(NSError **)error
{
    return [self _finchLaunchApp:url files:nil configuration:config_from(configuration, options) error:error];
}

- (NSRunningApplication *)openURL:(NSURL *)url options:(NSWorkspaceLaunchOptions)options
                    configuration:(NSDictionary<NSWorkspaceLaunchConfigurationKey, id> *)configuration
                            error:(NSError **)error
{
    return [self _finchOpenURL:url configuration:config_from(configuration, options) error:error];
}

- (NSRunningApplication *)openURLs:(NSArray<NSURL *> *)urls withApplicationAtURL:(NSURL *)applicationURL
                           options:(NSWorkspaceLaunchOptions)options
                     configuration:(NSDictionary<NSWorkspaceLaunchConfigurationKey, id> *)configuration
                             error:(NSError **)error
{
    return [self _finchLaunchApp:applicationURL files:urls configuration:config_from(configuration, options)
                           error:error];
}

- (BOOL)openURLs:(NSArray<NSURL *> *)urls withAppBundleIdentifier:(NSString *)bundleIdentifier
                                    options:(NSWorkspaceLaunchOptions)options
             additionalEventParamDescriptor:(NSAppleEventDescriptor *)descriptor
                          launchIdentifiers:(NSArray<NSNumber *> **)identifiers
{
    if (identifiers)
        *identifiers = nil;
    if (!bundleIdentifier) {
        BOOL ok = YES;
        for (NSURL *u in urls)
            ok &= [self openURL:u];
        return ok;
    }
    NSURL *app = [self URLForApplicationWithBundleIdentifier:bundleIdentifier];
    return app && [self _finchLaunchApp:app files:urls configuration:config_from(nil, options) error:NULL] != nil;
}

- (BOOL)launchAppWithBundleIdentifier:(NSString *)bundleIdentifier options:(NSWorkspaceLaunchOptions)options
       additionalEventParamDescriptor:(NSAppleEventDescriptor *)descriptor
                     launchIdentifier:(NSNumber **)identifier
{
    if (identifier)
        *identifier = nil;
    NSURL *app = [self URLForApplicationWithBundleIdentifier:bundleIdentifier];
    return app && [self _finchLaunchApp:app files:nil configuration:config_from(nil, options) error:NULL] != nil;
}

- (BOOL)openFile:(NSString *)fullPath
{
    return fullPath && [self openURL:[NSURL fileURLWithPath:fullPath]];
}

- (BOOL)openFile:(NSString *)fullPath withApplication:(NSString *)appName
{
    return [self openFile:fullPath withApplication:appName andDeactivate:YES];
}

- (BOOL)openFile:(NSString *)fullPath withApplication:(NSString *)appName andDeactivate:(BOOL)flag
{
    if (!appName)
        return [self openFile:fullPath];
    NSString *app = [self fullPathForApplication:appName];
    if (!app || !fullPath)
        return NO;
    return [self _finchLaunchApp:[NSURL fileURLWithPath:app] files:@[ [NSURL fileURLWithPath:fullPath] ]
                   configuration:[NSWorkspaceOpenConfiguration configuration] error:NULL] != nil;
}

- (BOOL)openFile:(NSString *)fullPath fromImage:(NSImage *)image at:(NSPoint)point inView:(NSView *)view
{
    return [self openFile:fullPath];
}

- (BOOL)openTempFile:(NSString *)fullPath { return [self openFile:fullPath]; }

- (BOOL)launchApplication:(NSString *)appName
{
    return [self launchApplication:appName showIcon:YES autolaunch:NO];
}

- (BOOL)launchApplication:(NSString *)appName showIcon:(BOOL)showIcon autolaunch:(BOOL)autolaunch
{
    NSString *app = [self fullPathForApplication:appName];
    return app && [self _finchLaunchApp:[NSURL fileURLWithPath:app] files:nil
                          configuration:[NSWorkspaceOpenConfiguration configuration] error:NULL] != nil;
}

#pragma mark Finding apps

- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)bundleIdentifier
{
    return [apps_with_identifier(bundleIdentifier) firstObject];
}

- (NSArray<NSURL *> *)URLsForApplicationsWithBundleIdentifier:(NSString *)bundleIdentifier
{
    return apps_with_identifier(bundleIdentifier);
}

- (NSURL *)URLForApplicationToOpenURL:(NSURL *)url { return [apps_for_url(url, YES) firstObject]; }
- (NSArray<NSURL *> *)URLsForApplicationsToOpenURL:(NSURL *)url { return apps_for_url(url, NO); }
- (NSURL *)URLForApplicationToOpenContentType:(UTType *)contentType { return [apps_for_type(contentType, nil, YES) firstObject]; }
- (NSArray<NSURL *> *)URLsForApplicationsToOpenContentType:(UTType *)contentType { return apps_for_type(contentType, nil, NO); }

static void
unsupported(void (^handler)(NSError *))
{
    if (handler) {
        handler = [[handler copy] autorelease];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            handler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
        });
    }
}

- (void)setDefaultApplicationAtURL:(NSURL *)applicationURL toOpenContentTypeOfFileAtURL:(NSURL *)url
                 completionHandler:(void (^)(NSError *))completionHandler
{
    unsupported(completionHandler);
}

- (void)setDefaultApplicationAtURL:(NSURL *)applicationURL toOpenURLsWithScheme:(NSString *)urlScheme
                 completionHandler:(void (^)(NSError *))completionHandler
{
    unsupported(completionHandler);
}

- (void)setDefaultApplicationAtURL:(NSURL *)applicationURL toOpenFileAtURL:(NSURL *)url
                 completionHandler:(void (^)(NSError *))completionHandler
{
    unsupported(completionHandler);
}

- (void)setDefaultApplicationAtURL:(NSURL *)applicationURL toOpenContentType:(UTType *)contentType
                 completionHandler:(void (^)(NSError *))completionHandler
{
    unsupported(completionHandler);
}

- (NSString *)fullPathForApplication:(NSString *)appName
{
    if (!appName.length)
        return nil;
    if ([appName isAbsolutePath])
        return [[NSFileManager defaultManager] fileExistsAtPath:appName] ? appName : nil;
    NSString *want = [[appName pathExtension] isEqualToString:@"app"] ? appName
                                                                       : [appName stringByAppendingPathExtension:@"app"];
    for (NSURL *u in all_apps())
        if ([[u lastPathComponent] caseInsensitiveCompare:want] == NSOrderedSame)
            return [u path];
    return nil;
}

- (NSString *)absolutePathForAppBundleWithIdentifier:(NSString *)bundleIdentifier
{
    return [[self URLForApplicationWithBundleIdentifier:bundleIdentifier] path];
}

#pragma mark Running apps

- (NSArray<NSRunningApplication *> *)runningApplications
{
    return [NSRunningApplication _finchAll];
}

- (NSRunningApplication *)frontmostApplication
{
    return [NSApp isActive] ? [NSRunningApplication currentApplication] : nil;
}

- (NSRunningApplication *)menuBarOwningApplication
{
    return [NSApp isActive] && [NSApp mainMenu] ? [NSRunningApplication currentApplication] : nil;
}

- (NSDictionary *)activeApplication
{
    NSRunningApplication *r = [self frontmostApplication];
    if (!r)
        return nil;
    NSMutableDictionary *d = [[launch_user_info(r) mutableCopy] autorelease];
    [d removeObjectForKey:NSWorkspaceApplicationKey];
    return d;
}

- (NSArray *)launchedApplications
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSRunningApplication *r in [self runningApplications])
        if ([r activationPolicy] == NSApplicationActivationPolicyRegular) {
            NSMutableDictionary *d = [[launch_user_info(r) mutableCopy] autorelease];
            [d removeObjectForKey:NSWorkspaceApplicationKey];
            [a addObject:d];
        }
    return a;
}

- (void)hideOtherApplications {}
- (NSInteger)extendPowerOffBy:(NSInteger)requested { return 0; }

#pragma mark The file viewer

/* Finch has no Finder: an app that says it opens folders is the file viewer. */
- (NSURL *)_finchFileViewer
{
    return [apps_for_type(type_named(@"public.folder"), nil, YES) firstObject];
}

- (BOOL)selectFile:(NSString *)fullPath inFileViewerRootedAtPath:(NSString *)rootFullPath
{
    NSURL *viewer = [self _finchFileViewer];
    if (!viewer)
        return NO;
    NSString *target = fullPath.length ? fullPath : rootFullPath;
    if (!target.length)
        return NO;
    return [self _finchLaunchApp:viewer files:@[ [NSURL fileURLWithPath:target] ]
                   configuration:[NSWorkspaceOpenConfiguration configuration] error:NULL] != nil;
}

- (void)activateFileViewerSelectingURLs:(NSArray<NSURL *> *)fileURLs
{
    NSURL *viewer = [self _finchFileViewer];
    if (viewer && fileURLs.count)
        [self _finchLaunchApp:viewer files:fileURLs configuration:[NSWorkspaceOpenConfiguration configuration]
                        error:NULL];
}

- (BOOL)showSearchResultsForQueryString:(NSString *)queryString { return NO; }
- (void)noteFileSystemChanged:(NSString *)path {}
- (void)noteFileSystemChanged {}
- (BOOL)fileSystemChanged { return NO; }
- (void)noteUserDefaultsChanged {}
- (BOOL)userDefaultsChanged { return NO; }
- (void)findApplications {}
- (void)checkForRemovableMedia {}
- (NSArray *)mountNewRemovableMedia { return @[]; }
- (void)slideImage:(NSImage *)image from:(NSPoint)fromPoint to:(NSPoint)toPoint {}

#pragma mark Files

- (BOOL)isFilePackageAtPath:(NSString *)fullPath
{
    if (!fullPath)
        return NO;
    NSNumber *pkg = nil;
    [[NSURL fileURLWithPath:fullPath] getResourceValue:&pkg forKey:NSURLIsPackageKey error:NULL];
    return [pkg boolValue];
}

- (NSImage *)iconForFile:(NSString *)fullPath
{
    NSURL *u = [NSURL fileURLWithPath:fullPath ?: @"/"];
    NSDictionary *v = [u resourceValuesForKeys:@[ NSURLIsDirectoryKey, NSURLIsApplicationKey, NSURLIsPackageKey ]
                                         error:NULL];
    if ([v[NSURLIsApplicationKey] boolValue])
        return sized(bundle_icon(u, app_info(u)) ?: FinchIconImage(FinchIconApplication, 32), 32);
    if ([fullPath isEqualToString:@"/"])
        return FinchIconImage(FinchIconVolume, 32);
    if ([v[NSURLIsDirectoryKey] boolValue] && ![v[NSURLIsPackageKey] boolValue])
        return FinchIconImage(FinchIconFolder, 32);
    return FinchIconImage(FinchIconDocument, 32);
}

- (NSImage *)iconForFiles:(NSArray<NSString *> *)fullPaths
{
    if (fullPaths.count == 1)
        return [self iconForFile:fullPaths[0]];
    return fullPaths.count ? FinchIconImage(FinchIconDocument, 32) : nil;
}

- (NSImage *)iconForContentType:(UTType *)contentType
{
    UTType *(^t)(NSString *) = ^UTType *(NSString *s) { return type_named(s); };
    if ([contentType conformsToType:t(@"com.apple.application-bundle")] || [contentType conformsToType:t(@"com.apple.application")])
        return FinchIconImage(FinchIconApplication, 32);
    if ([contentType conformsToType:t(@"public.volume")])
        return FinchIconImage(FinchIconVolume, 32);
    if ([contentType conformsToType:t(@"public.folder")] || [contentType conformsToType:t(@"public.directory")])
        if (![contentType conformsToType:t(@"com.apple.package")])
            return FinchIconImage(FinchIconFolder, 32);
    return FinchIconImage(FinchIconDocument, 32);
}

- (NSImage *)iconForFileType:(NSString *)fileType
{
    Class ut = FinchUTTypeClass();
    UTType *t = nil;
    if ([fileType isEqualToString:NSDirectoryFileType])
        t = type_named(@"public.folder");
    else if ([fileType containsString:@"."])
        t = [ut typeWithIdentifier:fileType];
    if (!t && fileType.length)
        t = [ut typeWithFilenameExtension:fileType];
    return [self iconForContentType:t ?: type_named(@"public.data")];
}

- (BOOL)setIcon:(NSImage *)image forFile:(NSString *)fullPath options:(NSWorkspaceIconCreationOptions)options
{
    return NO;  /* Finch keeps no custom icons yet */
}

- (NSArray<NSString *> *)fileLabels
{
    return @[ @"None", @"Gray", @"Green", @"Purple", @"Blue", @"Yellow", @"Red", @"Orange" ];
}

- (NSArray<NSColor *> *)fileLabelColors
{
    return @[
        [NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:1],
        [NSColor colorWithCalibratedRed:0.65626 green:0.65626 blue:0.65626 alpha:1],
        [NSColor colorWithCalibratedRed:0.699229 green:0.83595 blue:0.265629 alpha:1],
        [NSColor colorWithCalibratedRed:0.746105 green:0.546883 blue:0.843763 alpha:1],
        [NSColor colorWithCalibratedRed:0.339849 green:0.628916 blue:0.996109 alpha:1],
        [NSColor colorWithCalibratedRed:0.933608 green:0.851575 blue:0.265629 alpha:1],
        [NSColor colorWithCalibratedRed:0.980484 green:0.382818 blue:0.347662 alpha:1],
        [NSColor colorWithCalibratedRed:0.960952 green:0.660166 blue:0.25391 alpha:1],
    ];
}

- (NSString *)typeOfFile:(NSString *)absoluteFilePath error:(NSError **)outError
{
    FinchUTTypeClass();
    NSString *t = nil;
    NSURL *u = [NSURL fileURLWithPath:absoluteFilePath];
    if (![u getResourceValue:&t forKey:NSURLTypeIdentifierKey error:outError])
        return nil;
    return t;
}

- (NSString *)localizedDescriptionForType:(NSString *)typeName
{
    return [type_named(typeName) localizedDescription];
}

- (NSString *)preferredFilenameExtensionForType:(NSString *)typeName
{
    return [type_named(typeName) preferredFilenameExtension];
}

- (BOOL)filenameExtension:(NSString *)filenameExtension isValidForType:(NSString *)typeName
{
    NSArray *exts = [type_named(typeName) tags][@"public.filename-extension"];
    for (NSString *e in exts)
        if ([e caseInsensitiveCompare:filenameExtension] == NSOrderedSame)
            return YES;
    return NO;
}

- (BOOL)type:(NSString *)firstTypeName conformsToType:(NSString *)secondTypeName
{
    UTType *a = type_named(firstTypeName), *b = type_named(secondTypeName);
    return a && b && [a conformsToType:b];
}

- (BOOL)getInfoForFile:(NSString *)fullPath application:(NSString **)appName type:(NSString **)type
{
    BOOL dir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&dir])
        return NO;
    if (type) {
        if ([self isFilePackageAtPath:fullPath])
            *type = [[fullPath pathExtension] isEqualToString:@"app"] ? NSApplicationFileType : [fullPath pathExtension];
        else if (dir)
            *type = [fullPath isEqualToString:@"/"] ? NSFilesystemFileType : NSDirectoryFileType;
        else
            *type = [fullPath pathExtension].length ? [fullPath pathExtension] : NSPlainFileType;
    }
    if (appName)
        *appName = [[self URLForApplicationToOpenURL:[NSURL fileURLWithPath:fullPath]] path];
    return YES;
}

- (BOOL)getFileSystemInfoForPath:(NSString *)fullPath isRemovable:(BOOL *)removableFlag isWritable:(BOOL *)writableFlag
                   isUnmountable:(BOOL *)unmountableFlag description:(NSString **)description
                            type:(NSString **)fileSystemType
{
    struct statfs sf;
    if (!fullPath || statfs([fullPath fileSystemRepresentation], &sf) != 0)
        return NO;
    if (removableFlag)
        *removableFlag = NO;
    if (writableFlag)
        *writableFlag = (sf.f_flags & MNT_RDONLY) == 0;
    if (unmountableFlag)
        *unmountableFlag = (sf.f_flags & MNT_ROOTFS) == 0;
    if (description)
        *description = @"hard";
    if (fileSystemType)
        *fileSystemType = [NSString stringWithUTF8String:sf.f_fstypename];
    return YES;
}

- (NSArray *)mountedLocalVolumePaths
{
    NSMutableArray *a = [NSMutableArray array];
    struct statfs *m;
    int n = getmntinfo(&m, MNT_NOWAIT);
    for (int i = 0; i < n; i++)
        if (m[i].f_flags & MNT_LOCAL)
            [a addObject:[NSString stringWithUTF8String:m[i].f_mntonname]];
    return a;
}

- (NSArray *)mountedRemovableMedia { return @[]; }
- (BOOL)unmountAndEjectDeviceAtPath:(NSString *)path { return NO; }

- (BOOL)unmountAndEjectDeviceAtURL:(NSURL *)url error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil];
    return NO;
}

/* Finder's names for copies: "a copy.txt", then "a copy 2.txt"; a name already a copy counts on. */
static NSURL *
duplicate_url(NSURL *u)
{
    NSString *name = [u lastPathComponent], *ext = [name pathExtension];
    NSString *stem = [name stringByDeletingPathExtension];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@" copy( [0-9]+)?$" options:0
                                                                          error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:stem options:0 range:NSMakeRange(0, stem.length)];
    int start = 1;
    if (m) {
        NSRange n = [m rangeAtIndex:1];
        start = n.location == NSNotFound ? 2 : [[stem substringWithRange:n] intValue] + 1;
        stem = [stem substringToIndex:m.range.location];
    }
    NSURL *dir = [u URLByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (int i = start;; i++) {
        NSString *n = i == 1 ? [stem stringByAppendingString:@" copy"] : [NSString stringWithFormat:@"%@ copy %d", stem, i];
        if (ext.length)
            n = [n stringByAppendingPathExtension:ext];
        NSURL *c = [dir URLByAppendingPathComponent:n];
        if (![fm fileExistsAtPath:[c path]])
            return c;
    }
}

static NSError *
file_op_error(NSArray *errors, NSString *verb)
{
    if (!errors.count)
        return nil;
    NSError *first = errors[0];
    NSString *name = [[first userInfo][NSFilePathErrorKey] lastPathComponent] ?: @"";
    NSString *desc = first.code == NSFileReadNoSuchFileError || first.code == NSFileNoSuchFileError
                         ? [NSString stringWithFormat:@"The file “%@” could not be %@ because it was not found.", name, verb]
                         : [NSString stringWithFormat:@"The file “%@” could not be %@.", name, verb];
    return [NSError errorWithDomain:NSCocoaErrorDomain
                               code:first.code
                           userInfo:@{NSLocalizedDescriptionKey : desc, @"NSUnderlyingErrors" : errors}];
}

static void
file_operation(NSArray<NSURL *> *urls, NSString *verb, NSURL *(^destination)(NSURL *),
               BOOL (^perform)(NSURL *, NSURL *, NSError **),
               void (^handler)(NSDictionary<NSURL *, NSURL *> *, NSError *))
{
    urls = [[urls copy] autorelease];
    handler = [[handler copy] autorelease];
    destination = [[destination copy] autorelease];
    perform = [[perform copy] autorelease];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *done = [NSMutableDictionary dictionary];
        NSMutableArray *errors = [NSMutableArray array];
        for (NSURL *u in urls) {
            NSError *e = nil;
            NSURL *to = destination(u);
            if (to && perform(u, to, &e))
                done[u] = to;
            else if (e)
                [errors addObject:e];
        }
        NSError *err = file_op_error(errors, verb);
        if (handler)
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(done, err);
            });
    });
}

- (void)duplicateURLs:(NSArray<NSURL *> *)URLs
    completionHandler:(void (^)(NSDictionary<NSURL *, NSURL *> *, NSError *))handler
{
    file_operation(URLs, @"duplicated", ^NSURL *(NSURL *u) { return duplicate_url(u); },
                   ^BOOL(NSURL *from, NSURL *to, NSError **e) {
                       return [[NSFileManager defaultManager] copyItemAtURL:from toURL:to error:e];
                   },
                   handler);
}

- (void)recycleURLs:(NSArray<NSURL *> *)URLs
    completionHandler:(void (^)(NSDictionary<NSURL *, NSURL *> *, NSError *))handler
{
    NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
    file_operation(URLs, @"moved to the Trash",
                   ^NSURL *(NSURL *u) {
                       NSFileManager *fm = [NSFileManager defaultManager];
                       [fm createDirectoryAtPath:trash withIntermediateDirectories:YES attributes:nil error:NULL];
                       NSString *name = [u lastPathComponent], *ext = [name pathExtension];
                       NSString *stem = [name stringByDeletingPathExtension];
                       NSString *p = [trash stringByAppendingPathComponent:name];
                       for (int i = 2; [fm fileExistsAtPath:p]; i++) {
                           NSString *n = [NSString stringWithFormat:@"%@ %d", stem, i];
                           p = [trash stringByAppendingPathComponent:ext.length ? [n stringByAppendingPathExtension:ext] : n];
                       }
                       return [NSURL fileURLWithPath:p];
                   },
                   ^BOOL(NSURL *from, NSURL *to, NSError **e) {
                       return [[NSFileManager defaultManager] moveItemAtURL:from toURL:to error:e];
                   },
                   handler);
}

- (BOOL)performFileOperation:(NSWorkspaceFileOperationName)operation source:(NSString *)source
                 destination:(NSString *)destination files:(NSArray *)files tag:(NSInteger *)tag
{
    if (tag)
        *tag = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL ok = YES;
    for (NSString *f in files) {
        NSString *from = [source stringByAppendingPathComponent:f];
        NSString *to = [destination stringByAppendingPathComponent:f];
        if ([operation isEqualToString:NSWorkspaceMoveOperation])
            ok &= [fm moveItemAtPath:from toPath:to error:NULL];
        else if ([operation isEqualToString:NSWorkspaceCopyOperation])
            ok &= [fm copyItemAtPath:from toPath:to error:NULL];
        else if ([operation isEqualToString:NSWorkspaceLinkOperation])
            ok &= [fm createSymbolicLinkAtPath:to withDestinationPath:from error:NULL];
        else if ([operation isEqualToString:NSWorkspaceDestroyOperation])
            ok &= [fm removeItemAtPath:from error:NULL];
        else if ([operation isEqualToString:NSWorkspaceDuplicateOperation])
            ok &= [fm copyItemAtURL:[NSURL fileURLWithPath:from] toURL:duplicate_url([NSURL fileURLWithPath:from])
                              error:NULL];
        else if ([operation isEqualToString:NSWorkspaceRecycleOperation]) {
            NSString *t = [[NSHomeDirectory() stringByAppendingPathComponent:@".Trash"] stringByAppendingPathComponent:f];
            ok &= [fm moveItemAtPath:from toPath:t error:NULL];
        } else
            ok = NO;
    }
    return ok;
}

#pragma mark Accessibility, desktop, authorization

- (BOOL)accessibilityDisplayShouldIncreaseContrast { return NO; }
- (BOOL)accessibilityDisplayShouldDifferentiateWithoutColor { return NO; }
- (BOOL)accessibilityDisplayShouldReduceTransparency { return NO; }
- (BOOL)accessibilityDisplayShouldReduceMotion { return NO; }
- (BOOL)accessibilityDisplayShouldInvertColors { return NO; }
- (BOOL)isVoiceOverEnabled { return NO; }
- (BOOL)isSwitchControlEnabled { return NO; }

- (BOOL)setDesktopImageURL:(NSURL *)url forScreen:(NSScreen *)screen
                   options:(NSDictionary<NSWorkspaceDesktopImageOptionKey, id> *)options
                     error:(NSError **)error
{
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil];
    return NO;
}

- (NSURL *)desktopImageURLForScreen:(NSScreen *)screen { return nil; }
- (NSDictionary<NSWorkspaceDesktopImageOptionKey, id> *)desktopImageOptionsForScreen:(NSScreen *)screen { return nil; }

- (void)requestAuthorizationOfType:(NSWorkspaceAuthorizationType)type
                 completionHandler:(void (^)(NSWorkspaceAuthorization *, NSError *))completionHandler
{
    if (completionHandler) {
        void (^h)(NSWorkspaceAuthorization *, NSError *) = [[completionHandler copy] autorelease];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            h(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
        });
    }
}

@end
