/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The UTType C API (UTType.h) and the kUTType constants. Types come from
 * the system's declarations (UTTypeTable.inc: macOS's, with their tags in
 * all four tag classes) and from applications' exported and imported
 * declarations (the application database). Undeclared tags get dynamic
 * identifiers, made and read by UniformTypeIdentifiers (Finch's UTType):
 * the C API adds no conformance unless asked, where UTType's class methods
 * default to public.data.
 *
 * A tag maps to the declared types that list it, those whose preferred tag
 * it is first, system declarations before applications'. Extensions and
 * MIME types match without regard to case; OSTypes and pasteboard types
 * exactly.
 */
#import "LaunchServices_Finch.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "UTConstants.inc"

NSString *_UTFinchDynamicIdentifier(NSString *tagClass, NSString *tag, NSString *conformsTo);

typedef struct {
    const char *identifier, *description, *parents, *extensions, *mimes, *ostypes, *pboards;
} TypeEntry;

static const TypeEntry table[] = {
#include "UTTypeTable.inc"
};

/* A declaration: identifier, description, parents, tags by class. */
@interface LSFinchType : NSObject
@property (copy) NSString *identifier, *summary;
@property (copy) NSArray<NSString *> *parents;
@property (copy) NSDictionary<NSString *, NSArray<NSString *> *> *tags;
@property BOOL system;
@end

@implementation LSFinchType
- (void)dealloc
{
    [_identifier release];
    [_summary release];
    [_parents release];
    [_tags release];
    [super dealloc];
}
@end

static NSArray *
words(const char *s)
{
    if (!s || !*s)
        return @[];
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *w in [@(s) componentsSeparatedByString:@" "])
        [a addObject:[w stringByReplacingOccurrencesOfString:@"\001" withString:@" "]];
    return a;
}

static NSArray<LSFinchType *> *system_types;
static NSDictionary<NSString *, LSFinchType *> *system_index;

static void
load_system(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        NSMutableDictionary *index = [NSMutableDictionary dictionary];
        for (size_t i = 0; i < sizeof table / sizeof *table; i++) {
            LSFinchType *t = [[LSFinchType new] autorelease];
            t.identifier = @(table[i].identifier);
            t.summary = table[i].description ? @(table[i].description) : nil;
            t.parents = words(table[i].parents);
            NSMutableDictionary *tags = [NSMutableDictionary dictionary];
            NSArray *e = words(table[i].extensions), *m = words(table[i].mimes), *o = words(table[i].ostypes),
                    *p = words(table[i].pboards);
            if (e.count) tags[(id)kUTTagClassFilenameExtension] = e;
            if (m.count) tags[(id)kUTTagClassMIMEType] = m;
            if (o.count) tags[(id)kUTTagClassOSType] = o;
            if (p.count) tags[(id)kUTTagClassNSPboardType] = p;
            t.tags = tags;
            t.system = YES;
            [list addObject:t];
            index[[t.identifier lowercaseString]] = t;
        }
        system_types = [list copy];
        system_index = [index copy];
    });
}

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

/* Applications' declarations (cached per database generation). */
static NSArray<LSFinchType *> *
app_types(void)
{
    static NSDictionary *source;
    static NSArray *cached;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSLock new];
    });
    NSDictionary *decls = _LSApplicationTypeDeclarations();
    [lock lock];
    if (decls != source) {
        NSMutableArray *list = [NSMutableArray array];
        for (NSString *k in decls) {
            NSDictionary *d = decls[k];
            LSFinchType *t = [[LSFinchType new] autorelease];
            t.identifier = d[@"UTTypeIdentifier"];
            id desc = d[@"UTTypeDescription"];
            t.summary = [desc isKindOfClass:[NSString class]] ? desc : nil;
            t.parents = strings(d[@"UTTypeConformsTo"]);
            NSMutableDictionary *tags = [NSMutableDictionary dictionary];
            NSDictionary *spec = d[@"UTTypeTagSpecification"];
            if ([spec isKindOfClass:[NSDictionary class]])
                for (NSString *cls in spec)
                    if ([cls isKindOfClass:[NSString class]] && strings(spec[cls]).count)
                        tags[cls] = strings(spec[cls]);
            t.tags = tags;
            [list addObject:t];
        }
        [list sortUsingComparator:^NSComparisonResult(LSFinchType *a, LSFinchType *b) {
            return [a.identifier compare:b.identifier];
        }];
        [source release];
        [cached release];
        source = [decls retain];
        cached = [list copy];
    }
    NSArray *r = [[cached retain] autorelease];
    [lock unlock];
    return r;
}

static LSFinchType *
declared(NSString *identifier)
{
    if (!identifier)
        return nil;
    load_system();
    NSString *k = [identifier lowercaseString];
    LSFinchType *t = system_index[k];
    if (t)
        return t;
    for (LSFinchType *a in app_types())
        if ([[a.identifier lowercaseString] isEqualToString:k])
            return a;
    return nil;
}

static BOOL
is_dynamic(NSString *identifier)
{
    return [[identifier lowercaseString] hasPrefix:@"dyn."] && ![[UTType typeWithIdentifier:identifier] isDeclared] &&
           [UTType typeWithIdentifier:identifier] != nil;
}

static NSArray<NSString *> *
parents_of(NSString *identifier)
{
    LSFinchType *t = declared(identifier);
    if (t)
        return t.parents;
    if (is_dynamic(identifier)) {
        NSMutableArray *a = [NSMutableArray array];
        for (UTType *s in [[UTType typeWithIdentifier:identifier] supertypes])
            [a addObject:s.identifier];
        return a;
    }
    return @[];
}

BOOL
_LSConforms(NSString *type, NSString *to)
{
    if (!type || !to)
        return NO;
    if ([type caseInsensitiveCompare:to] == NSOrderedSame)
        return YES;
    NSString *want = [to lowercaseString];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *todo = [[parents_of(type) mutableCopy] autorelease];
    while (todo.count) {
        NSString *p = [todo lastObject];
        [todo removeLastObject];
        NSString *k = [p lowercaseString];
        if ([k isEqualToString:want])
            return YES;
        if ([seen containsObject:k])
            continue;
        [seen addObject:k];
        [todo addObjectsFromArray:parents_of(p)];
    }
    return NO;
}

NSString *
_LSTypeDescription(NSString *type)
{
    return declared(type).summary;
}

static NSDictionary *
dynamic_tags(NSString *identifier)
{
    return is_dynamic(identifier) ? [[UTType typeWithIdentifier:identifier] tags] : nil;
}

static BOOL
tag_equal(NSString *cls, NSString *a, NSString *b)
{
    if ([cls isEqualToString:(id)kUTTagClassFilenameExtension] || [cls isEqualToString:(id)kUTTagClassMIMEType])
        return [a caseInsensitiveCompare:b] == NSOrderedSame;
    return [a isEqualToString:b];
}

/* Declared types with the tag (preferred-tag holders first, system before apps), conforming to a type if given. */
static NSArray<NSString *> *
types_for_tag(NSString *cls, NSString *tag, NSString *conforming)
{
    load_system();
    NSMutableArray *first = [NSMutableArray array], *rest = [NSMutableArray array];
    NSArray *all = [system_types arrayByAddingObjectsFromArray:app_types()];
    NSMutableSet *seen = [NSMutableSet set];
    for (LSFinchType *t in all) {
        NSArray *list = t.tags[cls];
        for (NSUInteger i = 0; i < list.count; i++)
            if (tag_equal(cls, list[i], tag)) {
                NSString *k = [t.identifier lowercaseString];
                if (![seen containsObject:k] && (!conforming || _LSConforms(t.identifier, conforming))) {
                    [seen addObject:k];
                    [(i == 0 ? first : rest) addObject:t.identifier];
                }
                break;
            }
    }
    return [first arrayByAddingObjectsFromArray:rest];
}

CFStringRef
UTTypeCreatePreferredIdentifierForTag(CFStringRef inTagClass, CFStringRef inTag, CFStringRef inConformingToUTI)
{
    if (!inTagClass || !inTag)
        return NULL;
    @autoreleasepool {
        NSString *t = [types_for_tag((NSString *)inTagClass, (NSString *)inTag, (NSString *)inConformingToUTI) firstObject];
        if (!t)
            t = _UTFinchDynamicIdentifier((NSString *)inTagClass, (NSString *)inTag, (NSString *)inConformingToUTI);
        return (CFStringRef)[t copy];
    }
}

CFArrayRef
UTTypeCreateAllIdentifiersForTag(CFStringRef inTagClass, CFStringRef inTag, CFStringRef inConformingToUTI)
{
    if (!inTagClass || !inTag)
        return NULL;
    @autoreleasepool {
        NSArray *a = types_for_tag((NSString *)inTagClass, (NSString *)inTag, (NSString *)inConformingToUTI);
        if (!a.count) {
            NSString *d = _UTFinchDynamicIdentifier((NSString *)inTagClass, (NSString *)inTag, (NSString *)inConformingToUTI);
            a = d ? @[ d ] : @[];
        }
        return (CFArrayRef)[a copy];
    }
}

static NSArray *
tags_of(NSString *uti, NSString *cls)
{
    LSFinchType *t = declared(uti);
    NSArray *a = t ? t.tags[cls] : dynamic_tags(uti)[cls];
    return a.count ? a : nil;
}

CFStringRef
UTTypeCopyPreferredTagWithClass(CFStringRef inUTI, CFStringRef inTagClass)
{
    if (!inUTI || !inTagClass)
        return NULL;
    @autoreleasepool {
        return (CFStringRef)[[tags_of((NSString *)inUTI, (NSString *)inTagClass) firstObject] copy];
    }
}

CFArrayRef
UTTypeCopyAllTagsWithClass(CFStringRef inUTI, CFStringRef inTagClass)
{
    if (!inUTI || !inTagClass)
        return NULL;
    @autoreleasepool {
        return (CFArrayRef)[tags_of((NSString *)inUTI, (NSString *)inTagClass) copy];
    }
}

Boolean
UTTypeEqual(CFStringRef inUTI1, CFStringRef inUTI2)
{
    if (!inUTI1 || !inUTI2)
        return false;
    return CFStringCompare(inUTI1, inUTI2, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
}

Boolean
UTTypeConformsTo(CFStringRef inUTI, CFStringRef inConformsToUTI)
{
    @autoreleasepool {
        return _LSConforms((NSString *)inUTI, (NSString *)inConformsToUTI);
    }
}

CFStringRef
UTTypeCopyDescription(CFStringRef inUTI)
{
    @autoreleasepool {
        return (CFStringRef)[_LSTypeDescription((NSString *)inUTI) copy];
    }
}

Boolean
UTTypeIsDeclared(CFStringRef inUTI)
{
    @autoreleasepool {
        return declared((NSString *)inUTI) != nil;
    }
}

Boolean
UTTypeIsDynamic(CFStringRef inUTI)
{
    @autoreleasepool {
        return inUTI && is_dynamic((NSString *)inUTI);
    }
}

CFDictionaryRef
UTTypeCopyDeclaration(CFStringRef inUTI)
{
    @autoreleasepool {
        LSFinchType *t = declared((NSString *)inUTI);
        if (!t)
            return NULL;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[(id)kUTTypeIdentifierKey] = t.identifier;
        if (t.parents.count)
            d[(id)kUTTypeConformsToKey] = t.parents;
        if (t.summary)
            d[(id)kUTTypeDescriptionKey] = t.summary;
        if (t.tags.count)
            d[(id)kUTTypeTagSpecificationKey] = t.tags;
        return (CFDictionaryRef)[d copy];
    }
}

CFURLRef
UTTypeCopyDeclaringBundleURL(CFStringRef inUTI)
{
    @autoreleasepool {
        LSFinchType *t = declared((NSString *)inUTI);
        if (!t)
            return NULL;
        NSString *path = t.system ? @"/System/Library/CoreServices/CoreTypes.bundle" : _LSDeclaringApplicationPath(t.identifier);
        return path ? (CFURLRef)[[NSURL fileURLWithPath:path isDirectory:YES] retain] : NULL;
    }
}

CFStringRef
UTCreateStringForOSType(OSType inOSType)
{
    unsigned char b[4] = {(unsigned char)(inOSType >> 24), (unsigned char)(inOSType >> 16), (unsigned char)(inOSType >> 8),
                          (unsigned char)inOSType};
    if (!inOSType)
        return CFSTR("");
    CFStringRef s = CFStringCreateWithBytes(NULL, b, 4, kCFStringEncodingMacRoman, false);
    return s ? s : CFSTR("");
}

OSType
UTGetOSTypeFromString(CFStringRef inString)
{
    if (!inString)
        return 0;
    UInt8 b[4] = {0};
    CFIndex used = 0;
    CFStringGetBytes(inString, CFRangeMake(0, MIN(CFStringGetLength(inString), 4)), kCFStringEncodingMacRoman, '?', false, b, 4, &used);
    return (OSType)b[0] << 24 | (OSType)b[1] << 16 | (OSType)b[2] << 8 | b[3];
}

#pragma mark - Items

NSString *
_LSTypeOfItem(NSString *path, BOOL *isDirectory, BOOL *isPackage)
{
    BOOL dir = NO;
    if (isPackage)
        *isPackage = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir])
        return nil;
    if (isDirectory)
        *isDirectory = dir;
    NSString *ext = [path pathExtension];
    if (dir) {
        if ([path isEqualToString:@"/"])
            return @"public.volume";
        if (ext.length) {
            NSString *t = [types_for_tag((id)kUTTagClassFilenameExtension, ext, @"com.apple.package") firstObject];
            if (t) {
                if (isPackage)
                    *isPackage = YES;
                return t;
            }
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingPathComponent:@"Contents/Info.plist"]] &&
            _LSIsApplicationBundle(path)) {
            if (isPackage)
                *isPackage = YES;
            return @"com.apple.application-bundle";
        }
        return @"public.folder";
    }
    if (!ext.length)
        return @"public.data";
    NSString *t = [types_for_tag((id)kUTTagClassFilenameExtension, ext, @"public.data") firstObject];
    return t ?: _UTFinchDynamicIdentifier((id)kUTTagClassFilenameExtension, ext, @"public.data");
}

/* For Metadata: an item's content type (Metadata finds LaunchServices at run time; LaunchServices links it). */
FINCH_EXPORT CFStringRef
_FinchLSCopyTypeOfItem(CFStringRef path)
{
    @autoreleasepool {
        return (CFStringRef)[_LSTypeOfItem((NSString *)path, NULL, NULL) copy];
    }
}
