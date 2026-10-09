/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Opening things (LSOpen.h, LSOpenDeprecated.h). An item opens in its
 * default application, found in Finch's application database; a URL in the
 * handler of its scheme; an application by itself.
 *
 * Finch has no Apple event server yet, so items can't be sent to an app in
 * an 'odoc'/'GURL' event as macOS does. An app is launched with posix_spawn
 * with the items on its command line instead (file paths, other URLs as
 * strings), as AppKit's NSWorkspace does on Finch. An application that is
 * already running isn't told about the items: it's left as it is unless
 * kLSLaunchNewInstance asks for another copy.
 */
#import "LaunchServices_Finch.h"
#include <fcntl.h>
#include <spawn.h>

extern char **environ;

NSError *
_LSError(OSStatus status)
{
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}

/* Collects a launched child when it exits, so it doesn't linger as a zombie. */
static void
reap(pid_t pid)
{
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT,
                                                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(s, ^{
        int status;
        waitpid(pid, &status, WNOHANG);
        dispatch_source_cancel(s);
    });
    dispatch_source_set_cancel_handler(s, ^{
        dispatch_release(s);
    });
    dispatch_resume(s);
}

OSStatus
_LSLaunch(LSFinchApp *app, NSArray<NSURL *> *items, LSLaunchFlags flags, NSDictionary *environment, NSArray *arguments,
          pid_t *outPID)
{
    if (!app)
        return kLSApplicationNotFoundErr;
    NSString *exe = app.executablePath;
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:exe])
        return kLSNoExecutableErr;
    if (!(flags & kLSLaunchNewInstance)) {
        pid_t running = _LSRunningPIDForApplication(app.path);
        if (running > 0) {
            if (outPID)
                *outPID = running;
            return noErr;
        }
    }
    NSMutableArray *argv = [NSMutableArray arrayWithObject:exe];
    for (id a in arguments)
        if ([a isKindOfClass:[NSString class]])
            [argv addObject:a];
    for (NSURL *u in items)
        [argv addObject:u.isFileURL ? u.path : u.absoluteString];
    NSMutableDictionary *env = [[[[NSProcessInfo processInfo] environment] mutableCopy] autorelease];
    id lsenv = app.info[@"LSEnvironment"];
    if ([lsenv isKindOfClass:[NSDictionary class]])
        [env addEntriesFromDictionary:lsenv];
    if (environment)
        [env addEntriesFromDictionary:environment];
    size_t n = argv.count, m = env.count;
    char **cargv = calloc(n + 1, sizeof *cargv), **cenv = calloc(m + 1, sizeof *cenv);
    for (size_t i = 0; i < n; i++)
        cargv[i] = strdup([argv[i] fileSystemRepresentation]);
    size_t k = 0;
    for (NSString *key in env) {
        id v = env[key];
        if ([key isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]])
            cenv[k++] = strdup([[NSString stringWithFormat:@"%@=%@", key, v] UTF8String]);
    }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    pid_t pid = 0;
    int err = posix_spawn(&pid, cargv[0], &fa, &attr, cargv, cenv);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    for (size_t i = 0; i < n; i++)
        free(cargv[i]);
    for (size_t i = 0; i < k; i++)
        free(cenv[i]);
    free(cargv);
    free(cenv);
    if (err)
        return (err == EACCES || err == ENOEXEC) ? kLSNoExecutableErr : kLSUnknownErr;
    reap(pid);
    if (outPID)
        *outPID = pid;
    return noErr;
}

/* What opens a URL: the app itself, its default app, or an error. */
static OSStatus
handler_for(NSURL *url, LSRolesMask roles, LSFinchApp **out, BOOL *isApp)
{
    *isApp = NO;
    if (url.isFileURL) {
        NSString *path = [[url URLByStandardizingPath] path];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            return fnfErr;
        if (_LSIsApplicationBundle(path)) {
            *out = _LSApplicationAtPath(path);
            *isApp = YES;
            return *out ? noErr : kLSApplicationNotFoundErr;
        }
        BOOL dir = NO, pkg = NO;
        NSString *type = _LSTypeOfItem(path, &dir, &pkg);
        *out = _LSDefaultApplicationForType(type, dir && !pkg ? nil : [path pathExtension], roles);
        return *out ? noErr : kLSApplicationNotFoundErr;
    }
    *out = url.scheme ? _LSDefaultApplicationForScheme(url.scheme, roles) : nil;
    return *out ? noErr : kLSApplicationNotFoundErr;
}

OSStatus
LSOpenCFURLRef(CFURLRef inURL, CFURLRef *outLaunchedURL)
{
    if (!inURL)
        return paramErr;
    @autoreleasepool {
        LSFinchApp *app = nil;
        BOOL isApp = NO;
        OSStatus e = handler_for((NSURL *)inURL, kLSRolesAll, &app, &isApp);
        if (!e)
            e = _LSLaunch(app, isApp ? @[] : @[ (NSURL *)inURL ], kLSLaunchDefaults, nil, nil, NULL);
        if (!e && outLaunchedURL)
            *outLaunchedURL = (CFURLRef)[app.URL retain];
        return e;
    }
}

OSStatus
LSOpenFromURLSpec(const LSLaunchURLSpec *inLaunchSpec, CFURLRef *outLaunchedURL)
{
    if (!inLaunchSpec || (!inLaunchSpec->appURL && !inLaunchSpec->itemURLs))
        return paramErr;
    @autoreleasepool {
        LSLaunchFlags flags = inLaunchSpec->launchFlags;
        NSArray *items = (NSArray *)inLaunchSpec->itemURLs ?: @[];
        if (inLaunchSpec->appURL) {
            NSURL *u = (NSURL *)inLaunchSpec->appURL;
            LSFinchApp *app = _LSApplicationAtPath([[u URLByStandardizingPath] path]);
            if (!app)
                return [[NSFileManager defaultManager] fileExistsAtPath:u.path] ? kLSApplicationNotFoundErr : fnfErr;
            OSStatus e = _LSLaunch(app, items, flags, nil, nil, NULL);
            if (!e && outLaunchedURL)
                *outLaunchedURL = (CFURLRef)[app.URL retain];
            return e;
        }
        /* each item in its own app, items for the same app together */
        NSMutableArray *apps = [NSMutableArray array], *groups = [NSMutableArray array];
        for (NSURL *u in items) {
            LSFinchApp *app = nil;
            BOOL isApp = NO;
            OSStatus e = handler_for(u, kLSRolesAll, &app, &isApp);
            if (e)
                return e;
            NSUInteger i = [apps indexOfObjectPassingTest:^BOOL(LSFinchApp *a, NSUInteger idx, BOOL *stop) {
                return [a.path isEqualToString:app.path];
            }];
            if (i == NSNotFound) {
                [apps addObject:app];
                [groups addObject:[NSMutableArray array]];
                i = apps.count - 1;
            }
            if (!isApp)
                [groups[i] addObject:u];
        }
        OSStatus result = noErr;
        for (NSUInteger i = 0; i < apps.count; i++) {
            OSStatus e = _LSLaunch(apps[i], groups[i], flags, nil, nil, NULL);
            if (e && !result)
                result = e;
        }
        if (!result && outLaunchedURL && apps.count)
            *outLaunchedURL = (CFURLRef)[[apps.lastObject URL] retain];
        return result;
    }
}

OSStatus
LSOpenFSRef(const FSRef *inRef, FSRef *outLaunchedRef)
{
    CFURLRef u = CFURLCreateFromFSRef(NULL, inRef);
    if (!u)
        return fnfErr;
    CFURLRef launched = NULL;
    OSStatus e = LSOpenCFURLRef(u, &launched);
    CFRelease(u);
    if (!e && launched && outLaunchedRef)
        CFURLGetFSRef(launched, outLaunchedRef);
    if (launched)
        CFRelease(launched);
    return e;
}

OSStatus
LSOpenFromRefSpec(const LSLaunchFSRefSpec *inLaunchSpec, FSRef *outLaunchedRef)
{
    if (!inLaunchSpec)
        return paramErr;
    NSMutableArray *items = [NSMutableArray array];
    for (ItemCount i = 0; i < inLaunchSpec->numDocs; i++) {
        CFURLRef u = CFURLCreateFromFSRef(NULL, &inLaunchSpec->itemRefs[i]);
        if (u) {
            [items addObject:(NSURL *)u];
            CFRelease(u);
        }
    }
    CFURLRef app = inLaunchSpec->appRef ? CFURLCreateFromFSRef(NULL, inLaunchSpec->appRef) : NULL;
    LSLaunchURLSpec spec = {app, (CFArrayRef)items, inLaunchSpec->passThruParams, inLaunchSpec->launchFlags,
                            inLaunchSpec->asyncRefCon};
    CFURLRef launched = NULL;
    OSStatus e = LSOpenFromURLSpec(&spec, &launched);
    if (app)
        CFRelease(app);
    if (!e && launched && outLaunchedRef)
        CFURLGetFSRef(launched, outLaunchedRef);
    if (launched)
        CFRelease(launched);
    return e;
}

OSStatus
LSOpenApplication(const LSApplicationParameters *appParams, ProcessSerialNumber *outPSN)
{
    if (!appParams || !appParams->application)
        return paramErr;
    @autoreleasepool {
        CFURLRef u = CFURLCreateFromFSRef(NULL, appParams->application);
        if (!u)
            return fnfErr;
        LSFinchApp *app = _LSApplicationAtPath([(NSURL *)u path]);
        CFRelease(u);
        pid_t pid = 0;
        OSStatus e = _LSLaunch(app, @[], appParams->flags, (NSDictionary *)appParams->environment,
                               (NSArray *)appParams->argv, &pid);
        if (!e && outPSN) {
            outPSN->highLongOfPSN = 0;
            outPSN->lowLongOfPSN = (UInt32)pid;
        }
        return e;
    }
}

OSStatus
LSOpenItemsWithRole(const FSRef *inItems, CFIndex inItemCount, LSRolesMask inRole, const AEKeyDesc *inAEParam,
                    const LSApplicationParameters *inAppParams, ProcessSerialNumber *outPSNs, CFIndex inMaxPSNCount)
{
    for (CFIndex i = 0; i < inItemCount; i++) {
        OSStatus e = LSOpenFSRef(&inItems[i], NULL);
        if (e)
            return e;
    }
    return noErr;
}

OSStatus
LSOpenURLsWithRole(CFArrayRef inURLs, LSRolesMask inRole, const AEKeyDesc *inAEParam, const LSApplicationParameters *inAppParams,
                   ProcessSerialNumber *outPSNs, CFIndex inMaxPSNCount)
{
    for (NSURL *u in (NSArray *)inURLs) {
        OSStatus e = LSOpenCFURLRef((CFURLRef)u, NULL);
        if (e)
            return e;
    }
    return noErr;
}
