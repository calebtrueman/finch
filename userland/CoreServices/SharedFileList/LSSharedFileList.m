/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * LSSharedFileList (LSSharedFileList.h): the recent items, favorites and
 * login items lists. Finch keeps each list in the user's defaults
 * (org.finch.coreservices.SharedFileList, one array per list type, each item
 * a URL string, a display name and properties), and the lists' own
 * properties beside it. Nothing launches login items yet. Observers are
 * called when this process changes a list.
 */
#import <Foundation/Foundation.h>
#include "../CarbonCore/CarbonCore_Finch.h"

CFStringRef kLSSharedFileListFavoriteVolumes = CFSTR("com.apple.LSSharedFileList.FavoriteVolumes");
CFStringRef kLSSharedFileListFavoriteItems = CFSTR("com.apple.LSSharedFileList.FavoriteItems");
CFStringRef kLSSharedFileListRecentApplicationItems = CFSTR("com.apple.LSSharedFileList.RecentApplications");
CFStringRef kLSSharedFileListRecentDocumentItems = CFSTR("com.apple.LSSharedFileList.RecentDocuments");
CFStringRef kLSSharedFileListRecentServerItems = CFSTR("com.apple.LSSharedFileList.RecentServers");
CFStringRef kLSSharedFileListSessionLoginItems = CFSTR("com.apple.LSSharedFileList.SessionLoginItems");
CFStringRef kLSSharedFileListGlobalLoginItems = CFSTR("com.apple.LSSharedFileList.GlobalLoginItems");
CFStringRef kLSSharedFileListApplicationRecentDocuments = CFSTR("com.apple.LSSharedFileList.ApplicationRecentDocuments");
CFStringRef kLSSharedFileListRecentItemsMaxAmount = CFSTR("com.apple.LSSharedFileList.MaxAmount");
CFStringRef kLSSharedFileListVolumesComputerVisible = CFSTR("com.apple.LSSharedFileList.FavoriteVolumes.ComputerIsVisible");
CFStringRef kLSSharedFileListVolumesIDiskVisible = CFSTR("com.apple.LSSharedFileList.FavoriteVolumes.IDiskIsVisible");
CFStringRef kLSSharedFileListVolumesNetworkVisible = CFSTR("com.apple.LSSharedFileList.FavoriteVolumes.NetworkIsVisible");
CFStringRef kLSSharedFileListItemHidden = CFSTR("com.apple.LSSharedFileList.ItemIsHidden");
CFStringRef kLSSharedFileListLoginItemHidden = CFSTR("com.apple.loginitem.HideOnLaunch");
LSSharedFileListItemRef kLSSharedFileListItemBeforeFirst = (LSSharedFileListItemRef)1;
LSSharedFileListItemRef kLSSharedFileListItemLast = (LSSharedFileListItemRef)2;

/* The same, by the private names some apps use. */
FINCH_EXPORT CFStringRef _kLSSharedFileListRecentDocumentItems, _kLSSharedFileListRecentItemsMaxAmount;
FINCH_EXPORT LSSharedFileListItemRef _kLSSharedFileListItemBeforeFirst, _kLSSharedFileListItemLast;
CFStringRef _kLSSharedFileListRecentDocumentItems = CFSTR("com.apple.LSSharedFileList.RecentDocuments");
CFStringRef _kLSSharedFileListRecentItemsMaxAmount = CFSTR("com.apple.LSSharedFileList.MaxAmount");
LSSharedFileListItemRef _kLSSharedFileListItemBeforeFirst = (LSSharedFileListItemRef)1;
LSSharedFileListItemRef _kLSSharedFileListItemLast = (LSSharedFileListItemRef)2;

#define FINCH_SFL_DOMAIN @"org.finch.coreservices.SharedFileList"

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

struct __LSSharedFileList {
    uintptr_t isa;
    uint64_t info;
    CFStringRef type;
    CFMutableArrayRef observers;  /* CFData of struct observer */
};

struct __LSSharedFileListItem {
    uintptr_t isa;
    uint64_t info;
    CFStringRef listType;
    UInt32 identifier;
    CFURLRef url;
    CFStringRef name;
    CFDictionaryRef properties;
};

struct observer {
    CFRunLoopRef runloop;
    CFStringRef mode;
    LSSharedFileListChangedProcPtr callback;
    void *context;
};

static void
list_finalize(CFTypeRef cf)
{
    struct __LSSharedFileList *l = (struct __LSSharedFileList *)cf;
    CFRelease(l->type);
    CFRelease(l->observers);
}

static void
item_finalize(CFTypeRef cf)
{
    struct __LSSharedFileListItem *i = (struct __LSSharedFileListItem *)cf;
    CFRelease(i->listType);
    if (i->url)
        CFRelease(i->url);
    if (i->name)
        CFRelease(i->name);
    if (i->properties)
        CFRelease(i->properties);
}

static Boolean
item_equal(CFTypeRef a, CFTypeRef b)
{
    const struct __LSSharedFileListItem *x = a, *y = b;
    return x->identifier == y->identifier && CFEqual(x->listType, y->listType);
}

static const FinchCFRuntimeClass list_class = {0, "LSSharedFileList", NULL, NULL, list_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0};
static const FinchCFRuntimeClass item_class = {0, "LSSharedFileListItem", NULL, NULL, item_finalize, item_equal, NULL, NULL, NULL, NULL, NULL, 0};

CFTypeID
LSSharedFileListGetTypeID(void)
{
    static CFTypeID t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = _CFRuntimeRegisterClass(&list_class);
    });
    return t;
}

CFTypeID
LSSharedFileListItemGetTypeID(void)
{
    static CFTypeID t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = _CFRuntimeRegisterClass(&item_class);
    });
    return t;
}

static NSUserDefaults *
defaults(void)
{
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:FINCH_SFL_DOMAIN];
    });
    return d;
}

static NSArray *
stored(CFStringRef type)
{
    NSArray *a = [defaults() arrayForKey:(NSString *)type];
    return a ?: @[];
}

static void
store(LSSharedFileListRef list, NSArray *items)
{
    [defaults() setObject:items forKey:(NSString *)((struct __LSSharedFileList *)list)->type];
    [defaults() synchronize];
    struct __LSSharedFileList *l = (struct __LSSharedFileList *)list;
    for (CFIndex i = 0; i < CFArrayGetCount(l->observers); i++) {
        const struct observer *o = (const struct observer *)CFDataGetBytePtr(CFArrayGetValueAtIndex(l->observers, i));
        LSSharedFileListChangedProcPtr cb = o->callback;
        void *ctx = o->context;
        CFRetain(list);
        CFRunLoopPerformBlock(o->runloop, o->mode, ^{
            cb(list, ctx);
            CFRelease(list);
        });
        CFRunLoopWakeUp(o->runloop);
    }
}

LSSharedFileListRef
LSSharedFileListCreate(CFAllocatorRef inAllocator, CFStringRef inListType, CFTypeRef listOptions)
{
    if (!inListType)
        return NULL;
    struct __LSSharedFileList *l = (struct __LSSharedFileList *)_CFRuntimeCreateInstance(
        inAllocator, LSSharedFileListGetTypeID(), sizeof *l - 16, NULL);
    l->type = CFStringCreateCopy(NULL, inListType);
    l->observers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    return (LSSharedFileListRef)l;
}

OSStatus LSSharedFileListSetAuthorization(LSSharedFileListRef inList, AuthorizationRef inAuthorization) { return noErr; }

void
LSSharedFileListAddObserver(LSSharedFileListRef inList, CFRunLoopRef inRunloop, CFStringRef inRunloopMode,
                            LSSharedFileListChangedProcPtr callback, void *context)
{
    if (!inList || !inRunloop || !callback)
        return;
    struct observer o = {inRunloop, inRunloopMode ?: kCFRunLoopDefaultMode, callback, context};
    CFDataRef d = CFDataCreate(NULL, (const UInt8 *)&o, sizeof o);
    CFArrayAppendValue(((struct __LSSharedFileList *)inList)->observers, d);
    CFRelease(d);
}

void
LSSharedFileListRemoveObserver(LSSharedFileListRef inList, CFRunLoopRef inRunloop, CFStringRef inRunloopMode,
                               LSSharedFileListChangedProcPtr callback, void *context)
{
    if (!inList)
        return;
    CFMutableArrayRef obs = ((struct __LSSharedFileList *)inList)->observers;
    for (CFIndex i = CFArrayGetCount(obs) - 1; i >= 0; i--) {
        const struct observer *o = (const struct observer *)CFDataGetBytePtr(CFArrayGetValueAtIndex(obs, i));
        if (o->runloop == inRunloop && o->callback == callback && o->context == context)
            CFArrayRemoveValueAtIndex(obs, i);
    }
}

UInt32
LSSharedFileListGetSeedValue(LSSharedFileListRef inList)
{
    if (!inList)
        return 0;
    return (UInt32)[[defaults() objectForKey:[@"seed." stringByAppendingString:(NSString *)((struct __LSSharedFileList *)inList)->type]] unsignedIntValue];
}

static NSString *
property_key(LSSharedFileListRef list, CFStringRef name)
{
    return [NSString stringWithFormat:@"%@.property.%@", ((struct __LSSharedFileList *)list)->type, name];
}

CFTypeRef
LSSharedFileListCopyProperty(LSSharedFileListRef inList, CFStringRef inPropertyName)
{
    if (!inList || !inPropertyName)
        return NULL;
    return (CFTypeRef)[[defaults() objectForKey:property_key(inList, inPropertyName)] retain];
}

OSStatus
LSSharedFileListSetProperty(LSSharedFileListRef inList, CFStringRef inPropertyName, CFTypeRef inPropertyData)
{
    if (!inList || !inPropertyName)
        return paramErr;
    if (inPropertyData)
        [defaults() setObject:(id)inPropertyData forKey:property_key(inList, inPropertyName)];
    else
        [defaults() removeObjectForKey:property_key(inList, inPropertyName)];
    return noErr;
}

static LSSharedFileListItemRef
make_item(CFStringRef type, NSDictionary *d)
{
    struct __LSSharedFileListItem *i = (struct __LSSharedFileListItem *)_CFRuntimeCreateInstance(
        NULL, LSSharedFileListItemGetTypeID(), sizeof *i - 16, NULL);
    i->listType = CFStringCreateCopy(NULL, type);
    i->identifier = [d[@"id"] unsignedIntValue];
    NSString *u = d[@"URL"];
    i->url = [u isKindOfClass:[NSString class]] ? (CFURLRef)[[NSURL URLWithString:u] retain] : NULL;
    NSString *n = d[@"name"];
    i->name = [n isKindOfClass:[NSString class]] ? (CFStringRef)[n copy] : NULL;
    NSDictionary *p = d[@"properties"];
    i->properties = [p isKindOfClass:[NSDictionary class]] ? (CFDictionaryRef)[p copy] : NULL;
    return (LSSharedFileListItemRef)i;
}

CFArrayRef
LSSharedFileListCopySnapshot(LSSharedFileListRef inList, UInt32 *outSnapshotSeed)
{
    if (!inList)
        return NULL;
    @autoreleasepool {
        CFStringRef type = ((struct __LSSharedFileList *)inList)->type;
        CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (NSDictionary *d in stored(type)) {
            if (![d isKindOfClass:[NSDictionary class]])
                continue;
            LSSharedFileListItemRef i = make_item(type, d);
            CFArrayAppendValue(a, i);
            CFRelease(i);
        }
        if (outSnapshotSeed)
            *outSnapshotSeed = LSSharedFileListGetSeedValue(inList);
        return a;
    }
}

static void
bump_seed(LSSharedFileListRef list)
{
    NSString *k = [@"seed." stringByAppendingString:(NSString *)((struct __LSSharedFileList *)list)->type];
    [defaults() setObject:@([[defaults() objectForKey:k] unsignedIntValue] + 1) forKey:k];
}

LSSharedFileListItemRef
LSSharedFileListInsertItemURL(LSSharedFileListRef inList, LSSharedFileListItemRef insertAfterThisItem, CFStringRef inDisplayName,
                              IconRef inIconRef, CFURLRef inURL, CFDictionaryRef inPropertiesToSet, CFArrayRef inPropertiesToClear)
{
    if (!inList || !inURL)
        return NULL;
    @autoreleasepool {
        CFStringRef type = ((struct __LSSharedFileList *)inList)->type;
        NSMutableArray *items = [[stored(type) mutableCopy] autorelease];
        NSString *url = [(NSURL *)inURL absoluteString];
        UInt32 nextID = 1;
        for (NSDictionary *d in items)
            nextID = MAX(nextID, [d[@"id"] unsignedIntValue] + 1);
        NSMutableDictionary *props = [NSMutableDictionary dictionary];
        NSUInteger at = NSNotFound;
        for (NSUInteger i = 0; i < items.count; i++)
            if ([items[i][@"URL"] isEqual:url]) {
                [props addEntriesFromDictionary:items[i][@"properties"]];
                nextID = [items[i][@"id"] unsignedIntValue];
                [items removeObjectAtIndex:i];
                break;
            }
        if (inPropertiesToSet)
            [props addEntriesFromDictionary:(NSDictionary *)inPropertiesToSet];
        for (NSString *k in (NSArray *)inPropertiesToClear)
            [props removeObjectForKey:k];
        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:url, @"URL", @(nextID), @"id", props, @"properties", nil];
        entry[@"name"] = inDisplayName ? (NSString *)inDisplayName : [[(NSURL *)inURL path] lastPathComponent] ?: url;
        if (insertAfterThisItem == kLSSharedFileListItemBeforeFirst)
            at = 0;
        else if (insertAfterThisItem && insertAfterThisItem != kLSSharedFileListItemLast)
            for (NSUInteger i = 0; i < items.count; i++)
                if ([items[i][@"id"] unsignedIntValue] == ((struct __LSSharedFileListItem *)insertAfterThisItem)->identifier)
                    at = i + 1;
        [items insertObject:entry atIndex:at == NSNotFound ? items.count : at];
        NSNumber *max = [defaults() objectForKey:property_key(inList, kLSSharedFileListRecentItemsMaxAmount)];
        if ([max isKindOfClass:[NSNumber class]] && max.integerValue > 0)
            while ((NSInteger)items.count > max.integerValue)
                [items removeObjectAtIndex:at == 0 ? items.count - 1 : 0];
        bump_seed(inList);
        store(inList, items);
        return make_item(type, entry);
    }
}

LSSharedFileListItemRef
LSSharedFileListInsertItemFSRef(LSSharedFileListRef inList, LSSharedFileListItemRef insertAfterThisItem, CFStringRef inDisplayName,
                                IconRef inIconRef, const FSRef *inFSRef, CFDictionaryRef inPropertiesToSet, CFArrayRef inPropertiesToClear)
{
    CFURLRef u = CFURLCreateFromFSRef(NULL, inFSRef);
    if (!u)
        return NULL;
    LSSharedFileListItemRef i = LSSharedFileListInsertItemURL(inList, insertAfterThisItem, inDisplayName, inIconRef, u,
                                                              inPropertiesToSet, inPropertiesToClear);
    CFRelease(u);
    return i;
}

static OSStatus
edit(LSSharedFileListRef list, LSSharedFileListItemRef item, LSSharedFileListItemRef moveAfter, bool remove)
{
    if (!list || !item)
        return paramErr;
    @autoreleasepool {
        CFStringRef type = ((struct __LSSharedFileList *)list)->type;
        NSMutableArray *items = [[stored(type) mutableCopy] autorelease];
        UInt32 want = ((struct __LSSharedFileListItem *)item)->identifier;
        NSUInteger at = NSNotFound;
        for (NSUInteger i = 0; i < items.count; i++)
            if ([items[i][@"id"] unsignedIntValue] == want)
                at = i;
        if (at == NSNotFound)
            return fnfErr;
        NSDictionary *entry = [[items[at] retain] autorelease];
        [items removeObjectAtIndex:at];
        if (!remove) {
            NSUInteger to = items.count;
            if (moveAfter == kLSSharedFileListItemBeforeFirst)
                to = 0;
            else if (moveAfter && moveAfter != kLSSharedFileListItemLast)
                for (NSUInteger i = 0; i < items.count; i++)
                    if ([items[i][@"id"] unsignedIntValue] == ((struct __LSSharedFileListItem *)moveAfter)->identifier)
                        to = i + 1;
            [items insertObject:entry atIndex:to];
        }
        bump_seed(list);
        store(list, items);
        return noErr;
    }
}

OSStatus LSSharedFileListItemMove(LSSharedFileListRef inList, LSSharedFileListItemRef inItem, LSSharedFileListItemRef inMoveAfterItem)
{
    return edit(inList, inItem, inMoveAfterItem, false);
}

OSStatus LSSharedFileListItemRemove(LSSharedFileListRef inList, LSSharedFileListItemRef inItem)
{
    return edit(inList, inItem, NULL, true);
}

OSStatus
LSSharedFileListRemoveAllItems(LSSharedFileListRef inList)
{
    if (!inList)
        return paramErr;
    bump_seed(inList);
    store(inList, @[]);
    return noErr;
}

UInt32 LSSharedFileListItemGetID(LSSharedFileListItemRef inItem) { return inItem ? ((struct __LSSharedFileListItem *)inItem)->identifier : 0; }

IconRef
LSSharedFileListItemCopyIconRef(LSSharedFileListItemRef inItem)
{
    IconRef icon = NULL;
    GetIconRef(kOnSystemDisk, kSystemIconsCreator, kGenericDocumentIcon, &icon);
    return icon;
}

CFStringRef
LSSharedFileListItemCopyDisplayName(LSSharedFileListItemRef inItem)
{
    CFStringRef n = inItem ? ((struct __LSSharedFileListItem *)inItem)->name : NULL;
    return n ? (CFStringRef)CFRetain(n) : CFSTR("");
}

OSStatus
LSSharedFileListItemResolve(LSSharedFileListItemRef inItem, LSSharedFileListResolutionFlags inFlags, CFURLRef *outURL, FSRef *outRef)
{
    CFURLRef u = inItem ? ((struct __LSSharedFileListItem *)inItem)->url : NULL;
    if (!u)
        return fnfErr;
    if (outURL)
        *outURL = (CFURLRef)CFRetain(u);
    if (outRef && !CFURLGetFSRef(u, outRef))
        return fnfErr;
    return noErr;
}

CFURLRef
LSSharedFileListItemCopyResolvedURL(LSSharedFileListItemRef inItem, LSSharedFileListResolutionFlags inFlags, CFErrorRef *outError)
{
    CFURLRef u = inItem ? ((struct __LSSharedFileListItem *)inItem)->url : NULL;
    if (!u) {
        if (outError)
            *outError = CFErrorCreate(NULL, kCFErrorDomainOSStatus, fnfErr, NULL);
        return NULL;
    }
    return (CFURLRef)CFRetain(u);
}

CFTypeRef
LSSharedFileListItemCopyProperty(LSSharedFileListItemRef inItem, CFStringRef inPropertyName)
{
    CFDictionaryRef p = inItem ? ((struct __LSSharedFileListItem *)inItem)->properties : NULL;
    CFTypeRef v = p && inPropertyName ? CFDictionaryGetValue(p, inPropertyName) : NULL;
    return v ? CFRetain(v) : NULL;
}

OSStatus
LSSharedFileListItemSetProperty(LSSharedFileListItemRef inItem, CFStringRef inPropertyName, CFTypeRef inPropertyData)
{
    if (!inItem || !inPropertyName)
        return paramErr;
    struct __LSSharedFileListItem *i = (struct __LSSharedFileListItem *)inItem;
    CFMutableDictionaryRef d = i->properties ? CFDictionaryCreateMutableCopy(NULL, 0, i->properties)
                                             : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (inPropertyData)
        CFDictionarySetValue(d, inPropertyName, inPropertyData);
    else
        CFDictionaryRemoveValue(d, inPropertyName);
    if (i->properties)
        CFRelease(i->properties);
    i->properties = d;
    return noErr;
}
