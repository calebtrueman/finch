/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSProcessInfo (docs/design/FOUNDATION.md), against the SDK's declaration:
 * the process's arguments, environment, name and identity, the system's
 * version (from kern.osproductversion and kern.osversion, which finch-init
 * publishes), hardware, uptime, and the activity and termination calls
 * (recorded; Finch doesn't nap or terminate idle processes).
 */
#import <Foundation/Foundation.h>
#include <crt_externs.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <uuid/uuid.h>

#include "Foundation_Finch.h"

NSNotificationName const NSProcessInfoThermalStateDidChangeNotification = @"NSProcessInfoThermalStateDidChangeNotification";
NSNotificationName const NSProcessInfoPowerStateDidChangeNotification = @"NSProcessInfoPowerStateDidChangeNotification";

static NSString *
sysctl_string(const char *name)
{
    char buf[256];
    size_t len = sizeof(buf);
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0 || len == 0) return nil;
    return [NSString stringWithUTF8String:buf];
}

static unsigned long long
sysctl_number(const char *name)
{
    unsigned long long v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return 0;
    if (len == sizeof(int)) return (unsigned long long)*(unsigned int *)&v;
    return v;
}

@interface __NSActivity : NSObject {
@public
    NSActivityOptions options;
    NSString *reason;
}
@end
@implementation __NSActivity
- (void)dealloc { [reason release]; [super dealloc]; }
- (NSString *)description { return [NSString stringWithFormat:@"<%s %p : %@>", object_getClassName(self), self, reason]; }
@end

@implementation NSProcessInfo {
    NSString *_name;
    NSArray *_arguments;
    NSInteger _suddenTerminationDisabled;
    BOOL _automaticTermination;
}

+ (NSProcessInfo *)processInfo
{
    static NSProcessInfo *info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ info = [[NSProcessInfo alloc] init]; });
    return info;
}

- (NSDictionary<NSString *, NSString *> *)environment
{
    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    for (char **e = *_NSGetEnviron(); e && *e; e++) {
        const char *eq = strchr(*e, '=');
        if (!eq) continue;
        NSString *k = [[[NSString alloc] initWithBytes:*e length:(NSUInteger)(eq - *e) encoding:NSUTF8StringEncoding] autorelease];
        NSString *v = [NSString stringWithUTF8String:eq + 1];
        if (k && v && ![env objectForKey:k]) [env setObject:v forKey:k];
    }
    return [NSDictionary dictionaryWithDictionary:env];
}

- (NSArray<NSString *> *)arguments
{
    if (!_arguments) {
        int argc = *_NSGetArgc();
        char **argv = *_NSGetArgv();
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
        for (int i = 0; i < argc; i++) {
            NSString *s = [NSString stringWithUTF8String:argv[i]];
            [a addObject:s ? s : @""];
        }
        _arguments = [a copy];
    }
    return _arguments;
}

- (NSString *)hostName
{
    char buf[256];
    if (gethostname(buf, sizeof(buf)) != 0) return @"localhost";
    buf[sizeof(buf) - 1] = 0;
    return [NSString stringWithUTF8String:buf];
}

- (NSString *)processName
{
    if (!_name) {
        const char *p = getprogname();
        _name = [[NSString alloc] initWithUTF8String:p ? p : ""];
    }
    return _name;
}

- (void)setProcessName:(NSString *)newName
{
    NSString *old = _name;
    _name = [newName copy];
    [old release];
}

- (int)processIdentifier { return getpid(); }

/* Apple's form: a UUID, the pid, and a per-call counter, all in hex. */
- (NSString *)globallyUniqueString
{
    static uint64_t counter;
    uuid_t u;
    uuid_string_t s;
    uuid_generate_random(u);
    uuid_unparse_upper(u, s);
    return [NSString stringWithFormat:@"%s-%d-%016llX", s, getpid(),
        (unsigned long long)__atomic_add_fetch(&counter, 1, __ATOMIC_RELAXED)];
}

- (NSOperatingSystemVersion)operatingSystemVersion
{
    NSOperatingSystemVersion v = { 0, 0, 0 };
    NSString *s = sysctl_string("kern.osproductversion");
    NSArray *parts = [s componentsSeparatedByString:@"."];
    if ([parts count] > 0) v.majorVersion = [[parts objectAtIndex:0] integerValue];
    if ([parts count] > 1) v.minorVersion = [[parts objectAtIndex:1] integerValue];
    if ([parts count] > 2) v.patchVersion = [[parts objectAtIndex:2] integerValue];
    return v;
}

- (NSString *)operatingSystemVersionString
{
    NSOperatingSystemVersion v = [self operatingSystemVersion];
    NSString *build = sysctl_string("kern.osversion");
    NSString *version = v.patchVersion
        ? [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion]
        : [NSString stringWithFormat:@"%ld.%ld", (long)v.majorVersion, (long)v.minorVersion];
    return build ? [NSString stringWithFormat:@"Version %@ (Build %@)", version, build] : [NSString stringWithFormat:@"Version %@", version];
}

- (BOOL)isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)want
{
    NSOperatingSystemVersion v = [self operatingSystemVersion];
    if (v.majorVersion != want.majorVersion) return v.majorVersion > want.majorVersion;
    if (v.minorVersion != want.minorVersion) return v.minorVersion > want.minorVersion;
    return v.patchVersion >= want.patchVersion;
}

- (NSUInteger)operatingSystem { return 5; /* NSMACHOperatingSystem */ }
- (NSString *)operatingSystemName { return @"NSMACHOperatingSystem"; }

- (NSUInteger)processorCount { return (NSUInteger)sysctl_number("hw.ncpu"); }
- (NSUInteger)activeProcessorCount { return (NSUInteger)sysctl_number("hw.activecpu"); }
- (unsigned long long)physicalMemory { return sysctl_number("hw.memsize"); }

- (NSTimeInterval)systemUptime
{
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (NSTimeInterval)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

- (NSProcessInfoThermalState)thermalState { return NSProcessInfoThermalStateNominal; }
- (BOOL)isLowPowerModeEnabled { return NO; }
- (BOOL)isMacCatalystApp { return NO; }
- (BOOL)isiOSAppOnMac { return NO; }

- (NSString *)userName { return NSUserName(); }
- (NSString *)fullUserName { return NSFullUserName(); }

- (id<NSObject>)beginActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason
{
    __NSActivity *a = [[[__NSActivity alloc] init] autorelease];
    a->options = options;
    a->reason = [reason copy];
    if (options & NSActivitySuddenTerminationDisabled) [self disableSuddenTermination];
    return a;
}

- (void)endActivity:(id<NSObject>)activity
{
    __NSActivity *a = (__NSActivity *)activity;
    if ([a isKindOfClass:[__NSActivity class]] && (a->options & NSActivitySuddenTerminationDisabled)) [self enableSuddenTermination];
}

- (void)performActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason usingBlock:(void (^)(void))block
{
    id a = [self beginActivityWithOptions:options reason:reason];
    block();
    [self endActivity:a];
}

- (void)performExpiringActivityWithReason:(NSString *)reason usingBlock:(void (^)(BOOL expired))block
{
    block(NO);
}

- (void)disableSuddenTermination { __atomic_add_fetch(&_suddenTerminationDisabled, 1, __ATOMIC_RELAXED); }
- (void)enableSuddenTermination { __atomic_sub_fetch(&_suddenTerminationDisabled, 1, __ATOMIC_RELAXED); }
- (void)disableAutomaticTermination:(NSString *)reason { }
- (void)enableAutomaticTermination:(NSString *)reason { }
- (BOOL)automaticTerminationSupportEnabled { return _automaticTermination; }
- (void)setAutomaticTerminationSupportEnabled:(BOOL)flag { _automaticTermination = flag; }

@end
