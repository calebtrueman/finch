/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Running applications, as the kernel knows them: a process whose
 * executable is inside X.app/Contents/MacOS is an application, identified
 * by its bundle's Info.plist (as AppKit's NSRunningApplication does).
 */
#import "LaunchServices_Finch.h"
#include <libproc.h>

NSString *
_LSBundlePathForExecutable(NSString *path)
{
    NSString *macos = [path stringByDeletingLastPathComponent];
    NSString *contents = [macos stringByDeletingLastPathComponent];
    NSString *app = [contents stringByDeletingLastPathComponent];
    if ([[macos lastPathComponent] isEqualToString:@"MacOS"] && [[contents lastPathComponent] isEqualToString:@"Contents"])
        return app;
    return nil;
}

NSString *
_LSBundlePathForPID(pid_t pid)
{
    char buf[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, buf, sizeof buf) <= 0)
        return nil;
    return _LSBundlePathForExecutable([[NSFileManager defaultManager] stringWithFileSystemRepresentation:buf length:strlen(buf)]);
}

NSArray<NSNumber *> *
_LSRunningApplicationPIDs(void)
{
    int n = proc_listallpids(NULL, 0);
    if (n <= 0)
        return @[];
    pid_t *pids = calloc(n + 64, sizeof *pids);
    n = proc_listallpids(pids, (n + 64) * (int)sizeof *pids);
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < n; i++)
        if (pids[i] > 0 && _LSBundlePathForPID(pids[i]))
            [a addObject:@(pids[i])];
    free(pids);
    [a sortUsingSelector:@selector(compare:)];
    return a;
}

pid_t
_LSRunningPIDForApplication(NSString *path)
{
    NSString *real = [path stringByResolvingSymlinksInPath];
    for (NSNumber *pid in _LSRunningApplicationPIDs())
        if ([[_LSBundlePathForPID(pid.intValue) stringByResolvingSymlinksInPath] isEqualToString:real])
            return pid.intValue;
    return 0;
}

/* For AE: whether an application with this identifier runs (its pid, or 0). */
FINCH_EXPORT pid_t
_FinchLSPIDForBundleIdentifier(CFStringRef bundleID)
{
    @autoreleasepool {
        for (NSNumber *pid in _LSRunningApplicationPIDs()) {
            NSString *app = _LSBundlePathForPID(pid.intValue);
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
            NSString *bid = info[@"CFBundleIdentifier"];
            if ([bid isKindOfClass:[NSString class]] && [bid caseInsensitiveCompare:(NSString *)bundleID] == NSOrderedSame)
                return pid.intValue;
        }
    }
    return 0;
}
