/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * MDItem (MDItem.h) over the file system. Finch has no Spotlight index:
 * an item's attributes are what the file system and LaunchServices know,
 * computed when asked: name and path, sizes, owners, dates, Finder flags,
 * content type (and its supertypes, depth first as macOS lists them), kind,
 * bundle identifier. Attributes only an importer would provide (titles,
 * authors, ...) are absent. MDItemRef is a CF type.
 */
#import <Foundation/Foundation.h>
#include "../CarbonCore/CarbonCore_Finch.h"
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/xattr.h>

#include "MDConstants.inc"

/* CF's runtime class interface (CFRuntime.h, private to CF). */
typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} FinchCFRuntimeClass;
extern CFTypeID _CFRuntimeRegisterClass(const FinchCFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes, unsigned char *category);

struct __MDItem {
    uintptr_t isa;
    uint64_t info;
    CFStringRef path;
};

static void
item_finalize(CFTypeRef cf)
{
    CFRelease(((struct __MDItem *)cf)->path);
}

static Boolean
item_equal(CFTypeRef a, CFTypeRef b)
{
    return CFEqual(((struct __MDItem *)a)->path, ((struct __MDItem *)b)->path);
}

static CFHashCode
item_hash(CFTypeRef cf)
{
    return CFHash(((struct __MDItem *)cf)->path);
}

static CFStringRef
item_description(CFTypeRef cf)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<MDItem %p [%p]> {kMDItemPath = %@}"), cf, CFGetAllocator(cf),
                                    ((struct __MDItem *)cf)->path);
}

static const FinchCFRuntimeClass item_class = {0, "MDItem", NULL, NULL, item_finalize, item_equal, item_hash, NULL,
                                               item_description, NULL, NULL, 0};

CFTypeID
MDItemGetTypeID(void)
{
    static CFTypeID t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = _CFRuntimeRegisterClass(&item_class);
    });
    return t;
}

MDItemRef
MDItemCreate(CFAllocatorRef allocator, CFStringRef path)
{
    char p[PATH_MAX];
    struct stat st;
    if (!path || !CFStringGetFileSystemRepresentation(path, p, sizeof p) || lstat(p, &st))
        return NULL;
    struct __MDItem *item = (struct __MDItem *)_CFRuntimeCreateInstance(
        allocator, MDItemGetTypeID(), sizeof(struct __MDItem) - 2 * sizeof(uint64_t), NULL);
    if (!item)
        return NULL;
    char real[PATH_MAX];
    item->path = realpath(p, real) ? CFStringCreateWithFileSystemRepresentation(NULL, real) : CFStringCreateCopy(NULL, path);
    return (MDItemRef)item;
}

MDItemRef
MDItemCreateWithURL(CFAllocatorRef allocator, CFURLRef url)
{
    if (!url)
        return NULL;
    CFURLRef abs = CFURLCopyAbsoluteURL(url);
    CFStringRef path = CFURLCopyFileSystemPath(abs, kCFURLPOSIXPathStyle);
    CFRelease(abs);
    if (!path)
        return NULL;
    MDItemRef item = MDItemCreate(allocator, path);
    CFRelease(path);
    return item;
}

CFArrayRef
MDItemsCreateWithURLs(CFAllocatorRef allocator, CFArrayRef urls)
{
    CFMutableArrayRef a = CFArrayCreateMutable(allocator, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; urls && i < CFArrayGetCount(urls); i++) {
        MDItemRef item = MDItemCreateWithURL(allocator, CFArrayGetValueAtIndex(urls, i));
        CFArrayAppendValue(a, item ? (CFTypeRef)item : kCFNull);
        if (item)
            CFRelease(item);
    }
    return a;
}

#pragma mark - Attributes

/* LaunchServices, found when first needed (it links Metadata, as on macOS). */
static void *
ls(const char *symbol)
{
    static void *h;
    if (!h)
        h = dlopen("/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
                   RTLD_LAZY);
    return h ? dlsym(h, symbol) : NULL;
}

static NSString *
content_type(NSString *path)
{
    CFStringRef (*type_of)(CFStringRef) = ls("_FinchLSCopyTypeOfItem");
    return type_of ? [(NSString *)type_of((CFStringRef)path) autorelease] : nil;
}

static NSArray *
type_tree(NSString *type)
{
    CFDictionaryRef (*decl)(CFStringRef) = ls("UTTypeCopyDeclaration");
    NSMutableArray *tree = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:type];
    while (stack.count) {
        NSString *t = [stack lastObject];
        [stack removeLastObject];
        if ([tree containsObject:t])
            continue;
        [tree addObject:t];
        NSDictionary *d = decl ? [(NSDictionary *)decl((CFStringRef)t) autorelease] : nil;
        id conf = d[@"UTTypeConformsTo"];
        NSArray *parents = [conf isKindOfClass:[NSString class]] ? @[ conf ] : ([conf isKindOfClass:[NSArray class]] ? conf : @[]);
        for (NSString *p in [parents reverseObjectEnumerator])
            [stack addObject:p];
    }
    return tree;
}

static NSString *
kind(NSString *path)
{
    NSURL *url = [NSURL fileURLWithPath:path];
    NSString *localized = nil;
    if ([url getResourceValue:&localized forKey:NSURLLocalizedTypeDescriptionKey error:NULL] && localized)
        return localized;
    OSStatus (*copy_kind)(CFURLRef, CFStringRef *) = ls("LSCopyKindStringForURL");
    CFStringRef k = NULL;
    if (copy_kind)
        copy_kind((CFURLRef)[NSURL fileURLWithPath:path], &k);
    return [(NSString *)k autorelease];
}

static NSDate *
date(struct timespec ts)
{
    return [NSDate dateWithTimeIntervalSince1970:ts.tv_sec + ts.tv_nsec / 1e9];
}

static id
attribute(NSString *path, NSString *name)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st))
        return nil;
    if (S_ISLNK(st.st_mode))
        stat(path.fileSystemRepresentation, &st);
    BOOL dir = S_ISDIR(st.st_mode);
    unsigned char fi[32] = {0};
    BOOL hasFinderInfo = getxattr(path.fileSystemRepresentation, XATTR_FINDERINFO_NAME, fi, 32, 0, 0) == 32;
    UInt16 finderFlags = (UInt16)(fi[8] << 8 | fi[9]);
    if ([name isEqualToString:(id)kMDItemPath])
        return path;
    if ([name isEqualToString:(id)kMDItemFSName])
        return [path lastPathComponent];
    if ([name isEqualToString:(id)kMDItemDisplayName]) {
        NSString *type = content_type(path);
        return [type isEqualToString:@"com.apple.application-bundle"] ? [[path lastPathComponent] stringByDeletingPathExtension]
                                                                      : [path lastPathComponent];
    }
    if ([name isEqualToString:(id)kMDItemFSSize])
        return dir ? nil : @((long long)st.st_size);
    if ([name isEqualToString:(id)kMDItemFSCreationDate] || [name isEqualToString:(id)kMDItemContentCreationDate])
        return date(st.st_birthtimespec);
    if ([name isEqualToString:(id)kMDItemFSContentChangeDate] || [name isEqualToString:(id)kMDItemContentModificationDate])
        return date(st.st_mtimespec);
    if ([name isEqualToString:(id)kMDItemFSOwnerUserID])
        return @((int)st.st_uid);
    if ([name isEqualToString:(id)kMDItemFSOwnerGroupID])
        return @((int)st.st_gid);
    if ([name isEqualToString:(id)kMDItemFSInvisible])
        return @(([[path lastPathComponent] hasPrefix:@"."] || (finderFlags & kIsInvisible)) ? 1 : 0);
    if ([name isEqualToString:(id)kMDItemFSLabel])
        return @((finderFlags >> 1) & 7);
    if ([name isEqualToString:(id)kMDItemFSIsExtensionHidden])
        return @([content_type(path) isEqualToString:@"com.apple.application-bundle"] ? 1 : 0);
    if ([name isEqualToString:(id)kMDItemFSNodeCount]) {
        if (!dir)
            return nil;
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
        return @((int)items.count);
    }
    if ([name isEqualToString:(id)kMDItemFSTypeCode] || [name isEqualToString:(id)kMDItemFSCreatorCode]) {
        if (!hasFinderInfo || dir)
            return nil;
        int at = [name isEqualToString:(id)kMDItemFSTypeCode] ? 0 : 4;
        return @((unsigned)(fi[at] << 24 | fi[at + 1] << 16 | fi[at + 2] << 8 | fi[at + 3]));
    }
    if ([name isEqualToString:(id)kMDItemFSFinderFlags])
        return hasFinderInfo ? @(finderFlags) : nil;
    if ([name isEqualToString:(id)kMDItemContentType])
        return content_type(path);
    if ([name isEqualToString:(id)kMDItemContentTypeTree]) {
        NSString *t = content_type(path);
        return t ? type_tree(t) : nil;
    }
    if ([name isEqualToString:(id)kMDItemKind])
        return kind(path);
    if ([name isEqualToString:(id)kMDItemCFBundleIdentifier] || [name isEqualToString:(id)kMDItemVersion]) {
        if (!dir)
            return nil;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
        id v = info[[name isEqualToString:(id)kMDItemCFBundleIdentifier] ? @"CFBundleIdentifier" : @"CFBundleShortVersionString"];
        return [v isKindOfClass:[NSString class]] ? v : nil;
    }
    return nil;
}

static NSArray *
names(void)
{
    return @[
        (id)kMDItemPath, (id)kMDItemFSName, (id)kMDItemDisplayName, (id)kMDItemFSSize, (id)kMDItemFSCreationDate,
        (id)kMDItemFSContentChangeDate, (id)kMDItemContentCreationDate, (id)kMDItemContentModificationDate,
        (id)kMDItemFSOwnerUserID, (id)kMDItemFSOwnerGroupID, (id)kMDItemFSInvisible, (id)kMDItemFSLabel,
        (id)kMDItemFSIsExtensionHidden, (id)kMDItemFSNodeCount, (id)kMDItemFSTypeCode, (id)kMDItemFSCreatorCode,
        (id)kMDItemFSFinderFlags, (id)kMDItemContentType, (id)kMDItemContentTypeTree, (id)kMDItemKind,
        (id)kMDItemCFBundleIdentifier, (id)kMDItemVersion
    ];
}

CFTypeRef
MDItemCopyAttribute(MDItemRef item, CFStringRef name)
{
    if (!item || !name)
        return NULL;
    @autoreleasepool {
        return (CFTypeRef)[attribute((NSString *)((struct __MDItem *)item)->path, (NSString *)name) retain];
    }
}

CFDictionaryRef
MDItemCopyAttributes(MDItemRef item, CFArrayRef attrNames)
{
    if (!item || !attrNames)
        return NULL;
    @autoreleasepool {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSString *n in (NSArray *)attrNames) {
            id v = attribute((NSString *)((struct __MDItem *)item)->path, n);
            if (v)
                d[n] = v;
        }
        return (CFDictionaryRef)[d copy];
    }
}

CFDictionaryRef __MDItemCopyAttributesEllipsis1(MDItemRef item, ...);
CFDictionaryRef
__MDItemCopyAttributesEllipsis1(MDItemRef item, ...)
{
    NSMutableArray *list = [NSMutableArray array];
    va_list ap;
    va_start(ap, item);
    CFStringRef n;
    while ((n = va_arg(ap, CFStringRef)))
        [list addObject:(NSString *)n];
    va_end(ap);
    return MDItemCopyAttributes(item, (CFArrayRef)list);
}

CFArrayRef
MDItemCopyAttributeNames(MDItemRef item)
{
    if (!item)
        return NULL;
    @autoreleasepool {
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *n in names())
            if (attribute((NSString *)((struct __MDItem *)item)->path, n))
                [a addObject:n];
        return (CFArrayRef)[a copy];
    }
}

CFArrayRef
MDItemsCopyAttributes(CFArrayRef items, CFArrayRef attrNames)
{
    CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; items && i < CFArrayGetCount(items); i++) {
        CFMutableArrayRef row = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        MDItemRef item = (MDItemRef)CFArrayGetValueAtIndex(items, i);
        for (CFIndex j = 0; attrNames && j < CFArrayGetCount(attrNames); j++) {
            CFTypeRef v = CFGetTypeID(item) == MDItemGetTypeID() ? MDItemCopyAttribute(item, CFArrayGetValueAtIndex(attrNames, j)) : NULL;
            CFArrayAppendValue(row, v ? v : kCFNull);
            if (v)
                CFRelease(v);
        }
        CFArrayAppendValue(out, row);
        CFRelease(row);
    }
    return out;
}

#pragma mark - SPI apps call (nothing to record without an index)

FINCH_EXPORT Boolean _MDItemMarkAsUsedWithURL(CFURLRef url);
FINCH_EXPORT Boolean _MDItemMarkAsDownloaded(CFURLRef url, CFDictionaryRef info);
FINCH_EXPORT Boolean _MDItemSetPrivateAttributes(MDItemRef item, CFDictionaryRef attributes);
FINCH_EXPORT void _MDRegisterMailClient(void);

Boolean _MDItemMarkAsUsedWithURL(CFURLRef url) { return url != NULL; }
Boolean _MDItemMarkAsDownloaded(CFURLRef url, CFDictionaryRef info) { return url != NULL; }
Boolean _MDItemSetPrivateAttributes(MDItemRef item, CFDictionaryRef attributes) { return item != NULL; }
void _MDRegisterMailClient(void) {}
