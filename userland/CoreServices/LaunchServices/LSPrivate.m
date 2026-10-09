/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * LaunchServices SPI that apps call: application serial numbers (ASNs) and
 * the information LaunchServices keeps per running application, version
 * numbers, change notifications, and IconRefs (IconsCore.h).
 *
 * An ASN is a CFData of two 32-bit words (high 0, low the pid) — opaque to
 * callers, comparable with CFEqual. Application information comes from the
 * process and its bundle. _LSVersionNumber is four 64-bit words (major,
 * minor, bug fix, 0), as Apple's. Finch has no lsd to send change
 * notifications: scheduling one succeeds and nothing is delivered. IconRefs
 * are counted objects; Finch has no icon services yet to draw them.
 */
#import "LaunchServices_Finch.h"
#include <unistd.h>

const CFStringRef _kLSDisplayNameKey = CFSTR("LSDisplayName");
const CFStringRef _kLSApplicationTypeKey = CFSTR("ApplicationType");
const CFStringRef _kLSBundlePathKey = CFSTR("LSBundlePath");
const CFStringRef _kLSPIDKey = CFSTR("pid");
const CFStringRef _kLSParentASNKey = CFSTR("LSParentASN");
const CFStringRef _kLSApplicationForegroundTypeKey = CFSTR("Foreground");
const CFStringRef _kLSApplicationBackgroundOnlyTypeKey = CFSTR("BackgroundOnly");
const CFStringRef _kLSApplicationUIElementTypeKey = CFSTR("UIElement");
const CFStringRef _kLSApplicationTypeToRestoreKey = CFSTR("LSApplicationTypeToRestore");
const CFStringRef _kLSExecutablePathKey = CFSTR("CFBundleExecutablePath");
const CFStringRef _kLSApplicationIsHiddenKey = CFSTR("Hidden");
const CFStringRef _kLSLaunchTimeKey = CFSTR("LSLaunchTime");

typedef struct {
    uint64_t major, minor, bugfix, reserved;
} FinchLSVersionNumber;

#pragma mark - ASNs

FINCH_EXPORT CFTypeRef _LSASNCreateWithPid(CFAllocatorRef allocator, pid_t pid);
FINCH_EXPORT Boolean _LSASNExtractHighAndLowParts(CFTypeRef asn, UInt32 *high, UInt32 *low);
FINCH_EXPORT CFTypeRef _LSGetCurrentApplicationASN(void);
FINCH_EXPORT CFTypeRef _LSCopyFrontApplication(int sessionID);
FINCH_EXPORT CFArrayRef _LSCopyRunningApplicationArray(int sessionID);
FINCH_EXPORT CFArrayRef _LSCopyApplicationArray(int sessionID);
FINCH_EXPORT CFTypeRef _LSCopyApplicationInformationItem(int sessionID, CFTypeRef asn, CFStringRef key);
FINCH_EXPORT CFDictionaryRef _LSCopyApplicationInformation(int sessionID, CFTypeRef asn, CFArrayRef keys);
FINCH_EXPORT OSStatus _LSSetApplicationInformationItem(int sessionID, CFTypeRef asn, CFStringRef key, CFTypeRef value,
                                                       CFDictionaryRef *outInfo);

CFTypeRef
_LSASNCreateWithPid(CFAllocatorRef allocator, pid_t pid)
{
    if (pid <= 0)
        return NULL;
    UInt32 parts[2] = {0, (UInt32)pid};
    return CFDataCreate(allocator, (const UInt8 *)parts, sizeof parts);
}

Boolean
_LSASNExtractHighAndLowParts(CFTypeRef asn, UInt32 *high, UInt32 *low)
{
    UInt32 parts[2] = {0, 0};
    bool ok = asn && CFGetTypeID(asn) == CFDataGetTypeID() && CFDataGetLength(asn) == sizeof parts;
    if (ok)
        CFDataGetBytes(asn, CFRangeMake(0, sizeof parts), (UInt8 *)parts);
    if (high)
        *high = parts[0];
    if (low)
        *low = parts[1];
    return ok;
}

CFTypeRef
_LSGetCurrentApplicationASN(void)
{
    static CFTypeRef mine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mine = _LSASNCreateWithPid(NULL, getpid());
    });
    return mine;
}

static pid_t
pid_of(CFTypeRef asn)
{
    UInt32 high, low;
    return _LSASNExtractHighAndLowParts(asn, &high, &low) ? (pid_t)low : 0;
}

CFTypeRef
_LSCopyFrontApplication(int sessionID)
{
    /* no window server notion of "front" here: the newest running application */
    @autoreleasepool {
        NSNumber *pid = [_LSRunningApplicationPIDs() lastObject];
        return pid ? _LSASNCreateWithPid(NULL, pid.intValue) : NULL;
    }
}

CFArrayRef
_LSCopyRunningApplicationArray(int sessionID)
{
    @autoreleasepool {
        NSMutableArray *a = [NSMutableArray array];
        for (NSNumber *pid in _LSRunningApplicationPIDs()) {
            CFTypeRef asn = _LSASNCreateWithPid(NULL, pid.intValue);
            [a addObject:(id)asn];
            CFRelease(asn);
        }
        return (CFArrayRef)[a copy];
    }
}

CFArrayRef
_LSCopyApplicationArray(int sessionID)
{
    return _LSCopyRunningApplicationArray(sessionID);
}

static NSMutableDictionary *
extra_info(void)
{
    static NSMutableDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [NSMutableDictionary new];
    });
    return d;
}

static NSDictionary *
information(pid_t pid)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *path = _LSBundlePathForPID(pid);
    NSDictionary *info = path ? [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]] : nil;
    if (pid == getpid() && !info)
        info = [[NSBundle mainBundle] infoDictionary];
    d[(id)_kLSPIDKey] = @(pid);
    if (path)
        d[(id)_kLSBundlePathKey] = path;
    NSString *name = info[@"CFBundleName"];
    if (![name isKindOfClass:[NSString class]])
        name = [[path lastPathComponent] stringByDeletingPathExtension] ?: [[NSProcessInfo processInfo] processName];
    d[(id)_kLSDisplayNameKey] = name;
    BOOL ui = [info[@"LSUIElement"] boolValue], bg = [info[@"LSBackgroundOnly"] boolValue];
    d[(id)_kLSApplicationTypeKey] = bg ? (id)_kLSApplicationBackgroundOnlyTypeKey : ui ? (id)_kLSApplicationUIElementTypeKey
                                                                                     : (id)_kLSApplicationForegroundTypeKey;
    if ([info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]])
        d[(id)kCFBundleIdentifierKey] = info[@"CFBundleIdentifier"];
    @synchronized(extra_info()) {
        [d addEntriesFromDictionary:extra_info()[@(pid)]];
    }
    return d;
}

CFTypeRef
_LSCopyApplicationInformationItem(int sessionID, CFTypeRef asn, CFStringRef key)
{
    pid_t pid = pid_of(asn);
    if (!pid || !key)
        return NULL;
    @autoreleasepool {
        return (CFTypeRef)[information(pid)[(NSString *)key] retain];
    }
}

CFDictionaryRef
_LSCopyApplicationInformation(int sessionID, CFTypeRef asn, CFArrayRef keys)
{
    pid_t pid = pid_of(asn);
    if (!pid)
        return NULL;
    @autoreleasepool {
        NSDictionary *all = information(pid);
        if (!keys)
            return (CFDictionaryRef)[all copy];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSString *k in (NSArray *)keys)
            if (all[k])
                d[k] = all[k];
        return (CFDictionaryRef)[d copy];
    }
}

OSStatus
_LSSetApplicationInformationItem(int sessionID, CFTypeRef asn, CFStringRef key, CFTypeRef value, CFDictionaryRef *outInfo)
{
    pid_t pid = pid_of(asn);
    if (!pid || !key)
        return paramErr;
    @synchronized(extra_info()) {
        NSMutableDictionary *d = extra_info()[@(pid)];
        if (!d)
            extra_info()[@(pid)] = d = [NSMutableDictionary dictionary];
        if (value)
            d[(NSString *)key] = (id)value;
        else
            [d removeObjectForKey:(NSString *)key];
    }
    if (outInfo)
        *outInfo = NULL;
    return noErr;
}

#pragma mark - Version numbers

FINCH_EXPORT FinchLSVersionNumber _LSMakeVersionNumber(uint64_t major, uint64_t minor, uint64_t bugfix);
FINCH_EXPORT FinchLSVersionNumber _LSVersionNumberMakeWithString(CFStringRef string);
FINCH_EXPORT CFComparisonResult _LSVersionNumberCompare(const FinchLSVersionNumber *a, const FinchLSVersionNumber *b);
FINCH_EXPORT uint64_t _LSVersionNumberGetMajorComponent(const FinchLSVersionNumber *v);
FINCH_EXPORT uint64_t _LSVersionNumberGetMinorComponent(const FinchLSVersionNumber *v);
FINCH_EXPORT uint64_t _LSVersionNumberGetBugFixComponent(const FinchLSVersionNumber *v);

FinchLSVersionNumber
_LSMakeVersionNumber(uint64_t major, uint64_t minor, uint64_t bugfix)
{
    return (FinchLSVersionNumber){major, minor, bugfix, 0};
}

FinchLSVersionNumber
_LSVersionNumberMakeWithString(CFStringRef string)
{
    FinchLSVersionNumber v = {0, 0, 0, 0};
    char s[128];
    if (string && CFStringGetCString(string, s, sizeof s, kCFStringEncodingUTF8)) {
        unsigned long long p[3] = {0, 0, 0};
        sscanf(s, "%llu.%llu.%llu", &p[0], &p[1], &p[2]);
        v.major = p[0], v.minor = p[1], v.bugfix = p[2];
    }
    return v;
}

CFComparisonResult
_LSVersionNumberCompare(const FinchLSVersionNumber *a, const FinchLSVersionNumber *b)
{
    uint64_t x[3] = {a->major, a->minor, a->bugfix}, y[3] = {b->major, b->minor, b->bugfix};
    for (int i = 0; i < 3; i++)
        if (x[i] != y[i])
            return x[i] < y[i] ? kCFCompareLessThan : kCFCompareGreaterThan;
    return kCFCompareEqualTo;
}

uint64_t _LSVersionNumberGetMajorComponent(const FinchLSVersionNumber *v) { return v->major; }
uint64_t _LSVersionNumberGetMinorComponent(const FinchLSVersionNumber *v) { return v->minor; }
uint64_t _LSVersionNumberGetBugFixComponent(const FinchLSVersionNumber *v) { return v->bugfix; }

#pragma mark - Notifications

FINCH_EXPORT CFTypeRef _LSScheduleNotificationFunctionOnQueue_f(int sessionID, void *observer, dispatch_queue_t queue,
                                                                 void *context, void *function);
FINCH_EXPORT OSStatus _LSUnscheduleNotificationFunction(CFTypeRef notificationID);
FINCH_EXPORT OSStatus _LSModifyNotification(CFTypeRef notificationID, int count, const int *add, int removeCount,
                                            const int *remove, void *a, void *b);

CFTypeRef
_LSScheduleNotificationFunctionOnQueue_f(int sessionID, void *observer, dispatch_queue_t queue, void *context, void *function)
{
    static int64_t next;
    int64_t id = __sync_add_and_fetch(&next, 1);
    return CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
}

OSStatus _LSUnscheduleNotificationFunction(CFTypeRef notificationID) { return noErr; }
OSStatus _LSModifyNotification(CFTypeRef notificationID, int count, const int *add, int removeCount, const int *remove, void *a,
                               void *b)
{
    return noErr;
}

#pragma mark - IconRefs

struct icon {
    OSType creator, type;
    UInt16 refcount;
};

OSErr
GetIconRef(SInt16 vRefNum, OSType creator, OSType iconType, IconRef *theIconRef)
{
    if (!theIconRef)
        return paramErr;
    struct icon *i = calloc(1, sizeof *i);
    i->creator = creator;
    i->type = iconType;
    i->refcount = 1;
    *theIconRef = (IconRef)i;
    return noErr;
}

OSErr
AcquireIconRef(IconRef theIconRef)
{
    if (!theIconRef)
        return paramErr;
    ((struct icon *)theIconRef)->refcount++;
    return noErr;
}

OSErr
ReleaseIconRef(IconRef theIconRef)
{
    if (!theIconRef)
        return paramErr;
    struct icon *i = (struct icon *)theIconRef;
    if (--i->refcount == 0)
        free(i);
    return noErr;
}

OSErr
GetIconRefOwners(IconRef theIconRef, UInt16 *owners)
{
    if (!theIconRef || !owners)
        return paramErr;
    *owners = ((struct icon *)theIconRef)->refcount;
    return noErr;
}

OSErr
UnregisterIconRef(OSType creator, OSType iconType)
{
    return noErr;
}

Boolean
IsValidIconRef(IconRef theIconRef)
{
    return theIconRef != NULL;
}
