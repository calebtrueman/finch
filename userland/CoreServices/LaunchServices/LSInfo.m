/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * LaunchServices' queries (LSInfo.h, LSInfoDeprecated.h) over Finch's
 * application database: which apps open an item, a type or a URL scheme,
 * the user's default handlers, item information and kind strings,
 * registration. Errors are Apple's: kLSApplicationNotFoundErr (-10814) in
 * NSOSStatusErrorDomain.
 */
#import "LaunchServices_Finch.h"
#include <sys/stat.h>
#include <sys/xattr.h>

const CFStringRef kLSItemContentType = CFSTR("LSItemContentType");
const CFStringRef kLSItemFileType = CFSTR("LSItemFileType");
const CFStringRef kLSItemFileCreator = CFSTR("LSItemFileCreator");
const CFStringRef kLSItemExtension = CFSTR("LSItemExtension");
const CFStringRef kLSItemDisplayName = CFSTR("LSItemDisplayName");
const CFStringRef kLSItemDisplayKind = CFSTR("LSItemDisplayKind");
const CFStringRef kLSItemRoleHandlerDisplayName = CFSTR("LSItemRoleHandlerDisplayName");
const CFStringRef kLSItemIsInvisible = CFSTR("LSItemIsInvisible");
const CFStringRef kLSItemExtensionIsHidden = CFSTR("LSItemExtensionIsHidden");
const CFStringRef kLSItemQuarantineProperties = CFSTR("LSItemQuarantineProperties");
const CFStringRef kLSQuarantineAgentNameKey = CFSTR("LSQuarantineAgentName");
const CFStringRef kLSQuarantineAgentBundleIdentifierKey = CFSTR("LSQuarantineAgentBundleIdentifier");
const CFStringRef kLSQuarantineTimeStampKey = CFSTR("LSQuarantineTimeStamp");
const CFStringRef kLSQuarantineTypeKey = CFSTR("LSQuarantineType");
const CFStringRef kLSQuarantineTypeWebDownload = CFSTR("LSQuarantineTypeWebDownload");
const CFStringRef kLSQuarantineTypeOtherDownload = CFSTR("LSQuarantineTypeOtherDownload");
const CFStringRef kLSQuarantineTypeEmailAttachment = CFSTR("LSQuarantineTypeEmailAttachment");
const CFStringRef kLSQuarantineTypeInstantMessageAttachment = CFSTR("LSQuarantineTypeInstantMessageAttachment");
const CFStringRef kLSQuarantineTypeCalendarEventAttachment = CFSTR("LSQuarantineTypeCalendarEventAttachment");
const CFStringRef kLSQuarantineTypeOtherAttachment = CFSTR("LSQuarantineTypeOtherAttachment");
const CFStringRef kLSQuarantineOriginURLKey = CFSTR("LSQuarantineOriginURL");
const CFStringRef kLSQuarantineDataURLKey = CFSTR("LSQuarantineDataURL");
const CFStringRef LSReferrerURLKey = CFSTR("ReferrerURL");

NSString *_UTFinchLocalizedDescription(NSString *identifier);

static NSString *
path_of(CFURLRef url)
{
    if (!url || ![(NSURL *)url isFileURL])
        return nil;
    return [[(NSURL *)url URLByStandardizingPath] path];
}

static CFErrorRef
cferror(OSStatus status)
{
    return (CFErrorRef)[_LSError(status) retain];
}

static CFArrayRef
copy_urls(NSArray<LSFinchApp *> *apps)
{
    NSMutableArray *a = [NSMutableArray array];
    for (LSFinchApp *app in apps)
        [a addObject:app.URL];
    return a.count ? (CFArrayRef)[a copy] : NULL;
}

/* The apps for a URL: by its file's type, or its scheme. */
static NSArray<LSFinchApp *> *
apps_for_url(CFURLRef url, LSRolesMask roles, BOOL generic, BOOL defaultOnly)
{
    NSURL *u = (NSURL *)url;
    if (!u)
        return @[];
    if (u.isFileURL) {
        NSString *path = path_of(url);
        BOOL dir = NO, pkg = NO;
        NSString *type = _LSTypeOfItem(path, &dir, &pkg);
        if (_LSIsApplicationBundle(path))
            return @[];
        NSString *ext = dir && !pkg ? nil : [path pathExtension];
        if (defaultOnly) {
            LSFinchApp *a = _LSDefaultApplicationForType(type, ext, roles);
            return a ? @[ a ] : @[];
        }
        return _LSApplicationsForType(type, ext, roles, generic);
    }
    NSString *scheme = u.scheme;
    if (defaultOnly) {
        LSFinchApp *a = _LSDefaultApplicationForScheme(scheme, roles);
        return a ? @[ a ] : @[];
    }
    return _LSApplicationsForScheme(scheme, roles);
}

CFURLRef
LSCopyDefaultApplicationURLForURL(CFURLRef inURL, LSRolesMask inRoleMask, CFErrorRef *outError)
{
    @autoreleasepool {
        LSFinchApp *a = [apps_for_url(inURL, inRoleMask, YES, YES) firstObject];
        if (!a) {
            if (outError)
                *outError = cferror(kLSApplicationNotFoundErr);
            return NULL;
        }
        return (CFURLRef)[a.URL retain];
    }
}

CFURLRef
LSCopyDefaultApplicationURLForContentType(CFStringRef inContentType, LSRolesMask inRoleMask, CFErrorRef *outError)
{
    @autoreleasepool {
        LSFinchApp *a = inContentType ? _LSDefaultApplicationForType((NSString *)inContentType, nil, inRoleMask) : nil;
        if (!a) {
            if (outError)
                *outError = cferror(kLSApplicationNotFoundErr);
            return NULL;
        }
        return (CFURLRef)[a.URL retain];
    }
}

CFArrayRef
LSCopyApplicationURLsForBundleIdentifier(CFStringRef inBundleIdentifier, CFErrorRef *outError)
{
    @autoreleasepool {
        CFArrayRef a = copy_urls(_LSApplicationsWithIdentifier((NSString *)inBundleIdentifier));
        if (!a && outError)
            *outError = cferror(kLSApplicationNotFoundErr);
        return a;
    }
}

CFArrayRef
LSCopyApplicationURLsForURL(CFURLRef inURL, LSRolesMask inRoleMask)
{
    @autoreleasepool {
        return copy_urls(apps_for_url(inURL, inRoleMask, NO, NO));
    }
}

OSStatus
LSCanURLAcceptURL(CFURLRef inItemURL, CFURLRef inTargetURL, LSRolesMask inRoleMask, LSAcceptanceFlags inFlags,
                  Boolean *outAcceptsItem)
{
    if (!inItemURL || !inTargetURL || !outAcceptsItem)
        return paramErr;
    @autoreleasepool {
        NSString *target = path_of(inTargetURL);
        *outAcceptsItem = false;
        if (!target || ![[NSFileManager defaultManager] fileExistsAtPath:target])
            return fnfErr;
        NSString *real = [target stringByResolvingSymlinksInPath];
        for (LSFinchApp *a in apps_for_url(inItemURL, inRoleMask, YES, NO))
            if ([[a.path stringByResolvingSymlinksInPath] isEqualToString:real])
                *outAcceptsItem = true;
        return noErr;
    }
}

OSStatus
LSCanRefAcceptItem(const FSRef *inItemFSRef, const FSRef *inTargetRef, LSRolesMask inRoleMask, LSAcceptanceFlags inFlags,
                   Boolean *outAcceptsItem)
{
    CFURLRef a = CFURLCreateFromFSRef(NULL, inItemFSRef), b = CFURLCreateFromFSRef(NULL, inTargetRef);
    OSStatus e = (a && b) ? LSCanURLAcceptURL(a, b, inRoleMask, inFlags, outAcceptsItem) : fnfErr;
    if (a)
        CFRelease(a);
    if (b)
        CFRelease(b);
    return e;
}

OSStatus
LSRegisterURL(CFURLRef inURL, Boolean inUpdate)
{
    @autoreleasepool {
        NSString *path = path_of(inURL);
        if (!path)
            return paramErr;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            return fnfErr;
        return _LSRegister(path);
    }
}

OSStatus
LSRegisterFSRef(const FSRef *inRef, Boolean inUpdate)
{
    CFURLRef u = CFURLCreateFromFSRef(NULL, inRef);
    if (!u)
        return fnfErr;
    OSStatus e = LSRegisterURL(u, inUpdate);
    CFRelease(u);
    return e;
}

#pragma mark - Handlers

CFStringRef
LSCopyDefaultRoleHandlerForContentType(CFStringRef inContentType, LSRolesMask inRole)
{
    @autoreleasepool {
        LSFinchApp *a = inContentType ? _LSDefaultApplicationForType((NSString *)inContentType, nil, inRole) : nil;
        return (CFStringRef)[a.bundleIdentifier copy];
    }
}

CFArrayRef
LSCopyAllRoleHandlersForContentType(CFStringRef inContentType, LSRolesMask inRole)
{
    @autoreleasepool {
        NSMutableArray *ids = [NSMutableArray array];
        for (LSFinchApp *a in _LSApplicationsForType((NSString *)inContentType, nil, inRole, NO))
            if (a.bundleIdentifier && ![ids containsObject:a.bundleIdentifier])
                [ids addObject:a.bundleIdentifier];
        return ids.count ? (CFArrayRef)[ids copy] : NULL;
    }
}

OSStatus
LSSetDefaultRoleHandlerForContentType(CFStringRef inContentType, LSRolesMask inRole, CFStringRef inHandlerBundleID)
{
    if (!inContentType || !inHandlerBundleID)
        return paramErr;
    @autoreleasepool {
        _LSSetHandler(@"LSHandlerContentType", (NSString *)inContentType, (NSString *)inHandlerBundleID);
    }
    return noErr;
}

CFStringRef
LSCopyDefaultHandlerForURLScheme(CFStringRef inURLScheme)
{
    @autoreleasepool {
        LSFinchApp *a = inURLScheme ? _LSDefaultApplicationForScheme((NSString *)inURLScheme, kLSRolesAll) : nil;
        return (CFStringRef)[a.bundleIdentifier copy];
    }
}

CFArrayRef
LSCopyAllHandlersForURLScheme(CFStringRef inURLScheme)
{
    @autoreleasepool {
        NSMutableArray *ids = [NSMutableArray array];
        for (LSFinchApp *a in _LSApplicationsForScheme((NSString *)inURLScheme, kLSRolesAll))
            if (a.bundleIdentifier && ![ids containsObject:a.bundleIdentifier])
                [ids addObject:a.bundleIdentifier];
        return ids.count ? (CFArrayRef)[ids copy] : NULL;
    }
}

OSStatus
LSSetDefaultHandlerForURLScheme(CFStringRef inURLScheme, CFStringRef inHandlerBundleID)
{
    if (!inURLScheme || !inHandlerBundleID)
        return paramErr;
    @autoreleasepool {
        _LSSetHandler(@"LSHandlerURLScheme", [(NSString *)inURLScheme lowercaseString], (NSString *)inHandlerBundleID);
    }
    return noErr;
}

/* Private: the default app for a scheme by the app's URL. */
FINCH_EXPORT OSStatus _LSSetDefaultSchemeHandlerURL(CFStringRef scheme, CFURLRef appURL);
OSStatus
_LSSetDefaultSchemeHandlerURL(CFStringRef scheme, CFURLRef appURL)
{
    @autoreleasepool {
        LSFinchApp *a = _LSApplicationAtPath(path_of(appURL));
        if (!a.bundleIdentifier)
            return kLSApplicationNotFoundErr;
        return LSSetDefaultHandlerForURLScheme(scheme, (CFStringRef)a.bundleIdentifier);
    }
}

LSHandlerOptions LSGetHandlerOptionsForContentType(CFStringRef inContentType) { return kLSHandlerOptionsDefault; }
OSStatus LSSetHandlerOptionsForContentType(CFStringRef inContentType, LSHandlerOptions inOptions) { return noErr; }

#pragma mark - Items

static bool
finder_flags(NSString *path, bool dir, UInt16 *flags, OSType *type, OSType *creator, UInt16 *xflags)
{
    unsigned char fi[32];
    if (getxattr(path.fileSystemRepresentation, XATTR_FINDERINFO_NAME, fi, 32, 0, 0) != 32)
        return false;
    if (!dir) {
        *type = (OSType)fi[0] << 24 | fi[1] << 16 | fi[2] << 8 | fi[3];
        *creator = (OSType)fi[4] << 24 | fi[5] << 16 | fi[6] << 8 | fi[7];
    }
    *flags = (UInt16)(fi[8] << 8 | fi[9]);
    *xflags = (UInt16)(fi[24] << 8 | fi[25]);
    return true;
}

static OSStatus
item_info(NSString *path, LSRequestedInfo which, LSItemInfoRecord *out)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st))
        return fnfErr;
    memset(out, 0, sizeof *out);
    bool link = S_ISLNK(st.st_mode);
    if (link)
        stat(path.fileSystemRepresentation, &st);
    bool dir = S_ISDIR(st.st_mode);
    BOOL isDir = NO, pkg = NO;
    _LSTypeOfItem(path, &isDir, &pkg);
    bool app = dir && _LSIsApplicationBundle(path);
    UInt16 flags = 0, xflags = 0;
    OSType type = 0, creator = 0;
    finder_flags(path, dir, &flags, &type, &creator, &xflags);
    LSItemInfoFlags f = 0;
    if (!dir)
        f |= kLSItemInfoIsPlainFile;
    if (dir)
        f |= kLSItemInfoIsContainer;
    if (pkg || app)
        f |= kLSItemInfoIsPackage;
    if (app)
        f |= kLSItemInfoIsApplication | kLSItemInfoIsNativeApp | kLSItemInfoExtensionIsHidden;
    if (link)
        f |= kLSItemInfoIsSymlink;
    if (flags & kIsAlias)
        f |= kLSItemInfoIsAliasFile;
    if ((flags & kIsInvisible) || [[path lastPathComponent] hasPrefix:@"."])
        f |= kLSItemInfoIsInvisible;
    if ([path isEqualToString:@"/"])
        f |= kLSItemInfoIsVolume;
    if (which & (kLSRequestBasicFlagsOnly | kLSRequestAppTypeFlags | kLSRequestAllFlags))
        out->flags = f;
    if (which & kLSRequestTypeCreator) {
        if (app) {
            NSDictionary *info = _LSApplicationAtPath(path).info;
            NSString *t = info[@"CFBundlePackageType"], *c = info[@"CFBundleSignature"];
            out->filetype = [t isKindOfClass:[NSString class]] ? UTGetOSTypeFromString((CFStringRef)t) : 'APPL';
            out->creator = [c isKindOfClass:[NSString class]] ? UTGetOSTypeFromString((CFStringRef)c) : kLSUnknownCreator;
        } else {
            out->filetype = type;
            out->creator = creator;
        }
    }
    if ((which & kLSRequestExtension) && [path pathExtension].length)
        out->extension = (CFStringRef)[[path pathExtension] copy];
    return noErr;
}

OSStatus
LSCopyItemInfoForURL(CFURLRef inURL, LSRequestedInfo inWhichInfo, LSItemInfoRecord *outItemInfo)
{
    if (!inURL || !outItemInfo)
        return paramErr;
    @autoreleasepool {
        NSString *path = path_of(inURL);
        return path ? item_info(path, inWhichInfo, outItemInfo) : paramErr;
    }
}

OSStatus
LSCopyItemInfoForRef(const FSRef *inItemRef, LSRequestedInfo inWhichInfo, LSItemInfoRecord *outItemInfo)
{
    CFURLRef u = CFURLCreateFromFSRef(NULL, inItemRef);
    if (!u)
        return fnfErr;
    OSStatus e = LSCopyItemInfoForURL(u, inWhichInfo, outItemInfo);
    CFRelease(u);
    return e;
}

static NSString *
kind_for_path(NSString *path)
{
    BOOL dir = NO, pkg = NO;
    NSString *type = _LSTypeOfItem(path, &dir, &pkg);
    if (!type)
        return nil;
    if ([type isEqualToString:@"com.apple.application-bundle"])
        return @"Application";
    if (dir && !pkg)
        return @"Folder";
    NSString *k = _LSDocumentKindForType(type, [path pathExtension]);
    return k ?: _UTFinchLocalizedDescription(type);
}

OSStatus
LSCopyKindStringForURL(CFURLRef inURL, CFStringRef *outKindString)
{
    if (!inURL || !outKindString)
        return paramErr;
    @autoreleasepool {
        NSString *k = kind_for_path(path_of(inURL));
        if (!k)
            return fnfErr;
        *outKindString = (CFStringRef)[k copy];
        return noErr;
    }
}

OSStatus
LSCopyKindStringForRef(const FSRef *inFSRef, CFStringRef *outKindString)
{
    CFURLRef u = CFURLCreateFromFSRef(NULL, inFSRef);
    if (!u)
        return fnfErr;
    OSStatus e = LSCopyKindStringForURL(u, outKindString);
    CFRelease(u);
    return e;
}

OSStatus
LSCopyKindStringForTypeInfo(OSType inType, OSType inCreator, CFStringRef inExtension, CFStringRef *outKindString)
{
    if (!outKindString)
        return paramErr;
    @autoreleasepool {
        NSString *type = nil;
        if (inExtension)
            type = CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, inExtension, kUTTypeData));
        else if (inType && inType != kLSUnknownType)
            type = CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassOSType, (CFStringRef)CFBridgingRelease(UTCreateStringForOSType(inType)), NULL));
        if (!type)
            return kLSApplicationNotFoundErr;
        NSString *k = _LSDocumentKindForType(type, (NSString *)inExtension) ?: _UTFinchLocalizedDescription(type);
        *outKindString = (CFStringRef)[k copy];
        return noErr;
    }
}

OSStatus
LSCopyKindStringForMIMEType(CFStringRef inMIMEType, CFStringRef *outKindString)
{
    if (!inMIMEType || !outKindString)
        return paramErr;
    @autoreleasepool {
        NSString *type = CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, inMIMEType, NULL));
        *outKindString = (CFStringRef)[(_LSDocumentKindForType(type, nil) ?: _UTFinchLocalizedDescription(type)) copy];
        return noErr;
    }
}

OSStatus
LSCopyDisplayNameForURL(CFURLRef inURL, CFStringRef *outDisplayName)
{
    if (!inURL || !outDisplayName)
        return paramErr;
    @autoreleasepool {
        NSString *path = path_of(inURL);
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            return fnfErr;
        NSString *name = [path lastPathComponent];
        if (_LSIsApplicationBundle(path))
            name = [name stringByDeletingPathExtension];
        *outDisplayName = (CFStringRef)[name copy];
        return noErr;
    }
}

OSStatus
LSCopyDisplayNameForRef(const FSRef *inRef, CFStringRef *outDisplayName)
{
    CFURLRef u = CFURLCreateFromFSRef(NULL, inRef);
    if (!u)
        return fnfErr;
    OSStatus e = LSCopyDisplayNameForURL(u, outDisplayName);
    CFRelease(u);
    return e;
}

OSStatus
LSGetExtensionInfo(UniCharCount inNameLen, const UniChar *inNameBuffer, UniCharCount *outExtStartIndex)
{
    if (!inNameBuffer || !outExtStartIndex)
        return paramErr;
    *outExtStartIndex = kLSInvalidExtensionIndex;
    for (UniCharCount i = inNameLen; i > 1; i--)
        if (inNameBuffer[i - 1] == '.') {
            if (i < inNameLen)
                *outExtStartIndex = i;
            break;
        }
    return noErr;
}

OSStatus
LSCopyItemAttribute(const FSRef *inItem, LSRolesMask inRoles, CFStringRef inAttributeName, CFTypeRef *outValue)
{
    if (!inItem || !inAttributeName || !outValue)
        return paramErr;
    @autoreleasepool {
        CFURLRef u = CFURLCreateFromFSRef(NULL, inItem);
        if (!u)
            return fnfErr;
        NSString *path = path_of(u);
        CFRelease(u);
        NSString *name = (NSString *)inAttributeName;
        id v = nil;
        if ([name isEqualToString:(id)kLSItemContentType])
            v = _LSTypeOfItem(path, NULL, NULL);
        else if ([name isEqualToString:(id)kLSItemExtension])
            v = [path pathExtension];
        else if ([name isEqualToString:(id)kLSItemDisplayName])
            v = _LSIsApplicationBundle(path) ? [[path lastPathComponent] stringByDeletingPathExtension] : [path lastPathComponent];
        else if ([name isEqualToString:(id)kLSItemDisplayKind])
            v = kind_for_path(path);
        else if ([name isEqualToString:(id)kLSItemIsInvisible])
            v = @([[path lastPathComponent] hasPrefix:@"."]);
        else if ([name isEqualToString:(id)kLSItemExtensionIsHidden])
            v = @(_LSIsApplicationBundle(path));
        if (!v)
            return kLSAttributeNotFoundErr;
        *outValue = (CFTypeRef)[v retain];
        return noErr;
    }
}

OSStatus
LSCopyItemAttributes(const FSRef *inItem, LSRolesMask inRoles, CFArrayRef inAttributeNames, CFDictionaryRef *outValues)
{
    if (!inAttributeNames || !outValues)
        return paramErr;
    NSMutableDictionary *d = [[NSMutableDictionary alloc] init];
    for (NSString *n in (NSArray *)inAttributeNames) {
        CFTypeRef v = NULL;
        if (!LSCopyItemAttribute(inItem, inRoles, (CFStringRef)n, &v)) {
            d[n] = (id)v;
            CFRelease(v);
        }
    }
    *outValues = (CFDictionaryRef)d;
    return noErr;
}

#pragma mark - Finding applications

static void
give(LSFinchApp *a, FSRef *outRef, CFURLRef *outURL)
{
    if (outRef)
        FSPathMakeRef((const UInt8 *)a.path.fileSystemRepresentation, outRef, NULL);
    if (outURL)
        *outURL = (CFURLRef)[a.URL retain];
}

OSStatus
LSFindApplicationForInfo(OSType inCreator, CFStringRef inBundleID, CFStringRef inName, FSRef *outAppRef, CFURLRef *outAppURL)
{
    @autoreleasepool {
        for (LSFinchApp *a in _LSApplications()) {
            if (inBundleID && !(a.bundleIdentifier && [a.bundleIdentifier caseInsensitiveCompare:(NSString *)inBundleID] == NSOrderedSame))
                continue;
            if (inName) {
                NSString *n = (NSString *)inName, *file = [a.path lastPathComponent];
                if ([file caseInsensitiveCompare:n] != NSOrderedSame &&
                    [[file stringByDeletingPathExtension] caseInsensitiveCompare:n] != NSOrderedSame)
                    continue;
            }
            if (inCreator != kLSUnknownCreator) {
                NSString *sig = a.info[@"CFBundleSignature"];
                if (![sig isKindOfClass:[NSString class]] || UTGetOSTypeFromString((CFStringRef)sig) != inCreator)
                    continue;
            }
            if (!inBundleID && !inName && inCreator == kLSUnknownCreator)
                return paramErr;
            give(a, outAppRef, outAppURL);
            return noErr;
        }
        return kLSApplicationNotFoundErr;
    }
}

OSStatus
LSGetApplicationForURL(CFURLRef inURL, LSRolesMask inRoleMask, FSRef *outAppRef, CFURLRef *outAppURL)
{
    @autoreleasepool {
        LSFinchApp *a = [apps_for_url(inURL, inRoleMask, YES, YES) firstObject];
        if (!a)
            return kLSApplicationNotFoundErr;
        give(a, outAppRef, outAppURL);
        return noErr;
    }
}

OSStatus
LSGetApplicationForItem(const FSRef *inItemRef, LSRolesMask inRoleMask, FSRef *outAppRef, CFURLRef *outAppURL)
{
    CFURLRef u = CFURLCreateFromFSRef(NULL, inItemRef);
    if (!u)
        return fnfErr;
    OSStatus e = LSGetApplicationForURL(u, inRoleMask, outAppRef, outAppURL);
    CFRelease(u);
    return e;
}

OSStatus
LSGetApplicationForInfo(OSType inType, OSType inCreator, CFStringRef inExtension, LSRolesMask inRoleMask, FSRef *outAppRef,
                        CFURLRef *outAppURL)
{
    @autoreleasepool {
        if (inCreator != kLSUnknownCreator && !LSFindApplicationForInfo(inCreator, NULL, NULL, outAppRef, outAppURL))
            return noErr;
        NSString *type = nil;
        if (inExtension)
            type = CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, inExtension, kUTTypeData));
        else if (inType != kLSUnknownType)
            type = CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassOSType, (CFStringRef)CFBridgingRelease(UTCreateStringForOSType(inType)), NULL));
        LSFinchApp *a = (type || inExtension) ? _LSDefaultApplicationForType(type, (NSString *)inExtension, inRoleMask) : nil;
        if (!a)
            return kLSApplicationNotFoundErr;
        give(a, outAppRef, outAppURL);
        return noErr;
    }
}

OSStatus
LSCopyApplicationForMIMEType(CFStringRef inMIMEType, LSRolesMask inRoleMask, CFURLRef *outAppURL)
{
    @autoreleasepool {
        NSString *type = inMIMEType ? CFBridgingRelease(UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, inMIMEType, NULL)) : nil;
        LSFinchApp *a = type ? _LSDefaultApplicationForType(type, nil, inRoleMask) : nil;
        if (!a)
            return kLSApplicationNotFoundErr;
        give(a, NULL, outAppURL);
        return noErr;
    }
}
