/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSURL's bookmarks in Apple's binary bookmark format ("book"), so bookmarks apps saved on
 * macOS resolve on Finch and Finch's resolve on macOS. The format, as published by those
 * who have documented it: a header ("book", total size, version, header size), then a data
 * area of typed items (length, type, payload padded to 4 bytes) and a table of contents
 * mapping property keys to item offsets (offsets count from the data area's start).
 *
 * Finch writes the file's path components (0x1004), its properties (0x1010: file or
 * folder), its volume's path, URL and name (0x2002, 0x2005, 0x2010) and whether that is the
 * boot volume (0x2030: Apple's resolver needs the properties and this to find the file),
 * the creation options (0xd010), the name to show (0xf017),
 * and, for a relative bookmark, the path components relative to the base (0x1004 then
 * holds those, and 0xc001 how many components up the base is). Resolving reads the path
 * back; a bookmark is stale when its file isn't there.
 */
#import <Foundation/Foundation.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

enum {
    kTypeString = 0x0101,
    kTypeData = 0x0201,
    kTypeNumberSInt32 = 0x0303,
    kTypeNumberSInt64 = 0x0304,
    kTypeNumberFloat64 = 0x0306,
    kTypeDate = 0x0400,
    kTypeFalse = 0x0500,
    kTypeTrue = 0x0501,
    kTypeArray = 0x0601,
    kTypeDictionary = 0x0701,
    kTypeURL = 0x0901,
    kTypeURLRelative = 0x0902,
    kTypeNull = 0x0a01,
};

enum {
    kKeyPath = 0x1004,
    kKeyFileProperties = 0x1010,
    kKeyVolumePath = 0x2002,
    kKeyVolumeURL = 0x2005,
    kKeyVolumeName = 0x2010,
    kKeyVolumeIsBoot = 0x2030,
    kKeyParentCount = 0xc001,
    kKeyCreationOptions = 0xd010,
    kKeyDisplayName = 0xf017,
};

static const uint32_t kHeaderSize = 0x40;

#pragma mark - Writing

@interface _FinchBookmarkWriter : NSObject {
@public
    NSMutableData *data; /* the data area */
    NSMutableArray *keys, *offsets;
}
@end

@implementation _FinchBookmarkWriter
- (instancetype)init
{
    if ((self = [super init])) {
        data = [[NSMutableData alloc] init];
        keys = [[NSMutableArray alloc] init];
        offsets = [[NSMutableArray alloc] init];
        uint32_t toc = 0; /* the table of contents' offset, filled in at the end */
        [data appendBytes:&toc length:4];
    }
    return self;
}
- (void)dealloc
{
    [data release];
    [keys release];
    [offsets release];
    [super dealloc];
}
@end

static uint32_t
put_item(_FinchBookmarkWriter *w, uint32_t type, const void *bytes, uint32_t length)
{
    uint32_t at = (uint32_t)[w->data length];
    [w->data appendBytes:&length length:4];
    [w->data appendBytes:&type length:4];
    if (length)
        [w->data appendBytes:bytes length:length];
    while ([w->data length] % 4)
        [w->data appendBytes:"" length:1];
    return at;
}

static uint32_t
put_string(_FinchBookmarkWriter *w, NSString *s)
{
    const char *u = [s UTF8String];
    return put_item(w, kTypeString, u, (uint32_t)strlen(u));
}

static uint32_t
put_number(_FinchBookmarkWriter *w, int64_t v)
{
    if (v >= INT32_MIN && v <= INT32_MAX) {
        int32_t i = (int32_t)v;
        return put_item(w, kTypeNumberSInt32, &i, 4);
    }
    return put_item(w, kTypeNumberSInt64, &v, 8);
}

static uint32_t
put_array(_FinchBookmarkWriter *w, NSArray *itemOffsets)
{
    NSMutableData *d = [NSMutableData data];
    for (NSNumber *n in itemOffsets) {
        uint32_t o = [n unsignedIntValue];
        [d appendBytes:&o length:4];
    }
    return put_item(w, kTypeArray, [d bytes], (uint32_t)[d length]);
}

static void
put_key(_FinchBookmarkWriter *w, uint32_t key, uint32_t offset)
{
    [w->keys addObject:@(key)];
    [w->offsets addObject:@(offset)];
}

static NSData *
finish(_FinchBookmarkWriter *w)
{
    /* the table of contents: size, magic, identifier, next table, count, then entries */
    uint32_t tocAt = (uint32_t)[w->data length];
    uint32_t count = (uint32_t)[w->keys count];
    uint32_t head[5] = {12 + 12 * count, 0xfffffffe, 1, 0, count};
    [w->data appendBytes:head length:sizeof head];
    /* entries in key order, as Apple's are */
    NSArray *order = [[w->keys copy] autorelease];
    order = [order sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *k in order) {
        NSUInteger i = [w->keys indexOfObject:k];
        uint32_t entry[3] = {[k unsignedIntValue], [[w->offsets objectAtIndex:i] unsignedIntValue], 0};
        [w->data appendBytes:entry length:sizeof entry];
    }
    memcpy([w->data mutableBytes], &tocAt, 4);
    NSMutableData *out = [NSMutableData dataWithLength:kHeaderSize];
    uint8_t *h = [out mutableBytes];
    memcpy(h, "book", 4);
    uint32_t total = (uint32_t)(kHeaderSize + [w->data length]), version = 0x10050000;
    memcpy(h + 4, &total, 4);
    memcpy(h + 8, &version, 4);
    memcpy(h + 12, &kHeaderSize, 4);
    [out appendData:w->data];
    return out;
}

static NSString *
volume_path_for(NSString *path)
{
    /* the mount point holding the path: the deepest ancestor on another device's root */
    struct stat st;
    if (stat([path fileSystemRepresentation], &st) != 0)
        return @"/";
    dev_t dev = st.st_dev;
    NSString *at = path;
    while (![at isEqualToString:@"/"]) {
        NSString *up = [at stringByDeletingLastPathComponent];
        struct stat ust;
        if (stat([up fileSystemRepresentation], &ust) != 0 || ust.st_dev != dev)
            return at;
        at = up;
    }
    return @"/";
}

@implementation NSURL (FinchBookmarks)

- (NSData *)bookmarkDataWithOptions:(NSURLBookmarkCreationOptions)options
     includingResourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys
                      relativeToURL:(NSURL *)relativeURL
                              error:(NSError **)error
{
    if (![self isFileURL]) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnsupportedSchemeError
                                     userInfo:@{NSURLErrorKey : self}];
        return nil;
    }
    /* the real path, /private and all, as Apple's records it */
    char real[PATH_MAX];
    NSString *path = realpath([[self path] fileSystemRepresentation], real)
                         ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:real length:strlen(real)]
                         : [[self path] stringByStandardizingPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError
                                     userInfo:@{NSFilePathErrorKey : path, NSURLErrorKey : self}];
        return nil;
    }
    _FinchBookmarkWriter *w = [[[_FinchBookmarkWriter alloc] init] autorelease];
    put_key(w, kKeyCreationOptions, put_number(w, (int64_t)options));
    NSArray *components = [path pathComponents];
    NSUInteger up = 0;
    if (relativeURL && [relativeURL isFileURL]) {
        char rb[PATH_MAX];
        NSString *basePath = realpath([[relativeURL path] fileSystemRepresentation], rb)
                                 ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:rb length:strlen(rb)]
                                 : [[relativeURL path] stringByStandardizingPath];
        NSArray *base = [basePath pathComponents];
        NSUInteger common = 0;
        while (common < [base count] && common < [components count] &&
               [[base objectAtIndex:common] isEqualToString:[components objectAtIndex:common]])
            common++;
        up = [base count] - common;
        components = [components subarrayWithRange:NSMakeRange(common, [components count] - common)];
    } else if ([components count] && [[components objectAtIndex:0] isEqualToString:@"/"]) {
        components = [components subarrayWithRange:NSMakeRange(1, [components count] - 1)];
    }
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *c in components)
        [parts addObject:@(put_string(w, c))];
    put_key(w, kKeyPath, put_array(w, parts));
    /* the properties: flags (1 a file, 2 a folder), which flags are known, reserved */
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    uint64_t props[3] = {isDir ? 2 : 1, 0x0f, 0};
    put_key(w, kKeyFileProperties, put_item(w, kTypeData, props, sizeof props));
    if (relativeURL)
        put_key(w, kKeyParentCount, put_number(w, (int64_t)up));
    NSString *volume = volume_path_for(path);
    put_key(w, kKeyVolumePath, put_string(w, volume));
    if ([volume isEqualToString:@"/"])
        put_key(w, kKeyVolumeIsBoot, put_item(w, kTypeTrue, NULL, 0));
    NSString *volumeURL = [[NSURL fileURLWithPath:volume isDirectory:YES] absoluteString];
    const char *vu = [volumeURL UTF8String];
    put_key(w, kKeyVolumeURL, put_item(w, kTypeURL, vu, (uint32_t)strlen(vu)));
    NSString *volumeName = nil;
    [[NSURL fileURLWithPath:volume] getResourceValue:&volumeName forKey:NSURLVolumeNameKey error:NULL];
    put_key(w, kKeyVolumeName, put_string(w, volumeName ?: ([volume isEqualToString:@"/"] ? @"Finch" : [volume lastPathComponent])));
    if ([keys containsObject:NSURLLocalizedNameKey] || [keys containsObject:NSURLNameKey])
        put_key(w, kKeyDisplayName, put_string(w, [[NSFileManager defaultManager] displayNameAtPath:path]));
    return finish(w);
}

- (NSData *)bookmarkDataWithAliasRecord:(NSData *)aliasRecord { return nil; }

#pragma mark - Reading

typedef struct {
    const uint8_t *bytes;
    NSUInteger length;  /* of the data area */
} book;

static BOOL
open_book(NSData *d, book *b)
{
    const uint8_t *p = [d bytes];
    NSUInteger n = [d length];
    if (n < 16 || memcmp(p, "book", 4))
        return NO;
    uint32_t header;
    memcpy(&header, p + 12, 4);
    if (header < 16 || header >= n)
        return NO;
    b->bytes = p + header;
    b->length = n - header;
    return YES;
}

static BOOL
item_at(const book *b, uint32_t offset, uint32_t *type, const uint8_t **payload, uint32_t *length)
{
    if ((NSUInteger)offset + 8 > b->length)
        return NO;
    memcpy(length, b->bytes + offset, 4);
    memcpy(type, b->bytes + offset + 4, 4);
    if ((NSUInteger)offset + 8 + *length > b->length)
        return NO;
    *payload = b->bytes + offset + 8;
    return YES;
}

/* The item a key names, from the first table of contents. */
static BOOL
item_for_key(const book *b, uint32_t key, uint32_t *type, const uint8_t **payload, uint32_t *length)
{
    if (b->length < 4)
        return NO;
    uint32_t toc;
    memcpy(&toc, b->bytes, 4);
    for (int hop = 0; toc && hop < 8; hop++) {
        if ((NSUInteger)toc + 20 > b->length)
            return NO;
        uint32_t head[5];
        memcpy(head, b->bytes + toc, sizeof head);
        if (head[1] != 0xfffffffe)
            return NO;
        for (uint32_t i = 0; i < head[4] && (NSUInteger)toc + 20 + 12 * (i + 1) <= b->length; i++) {
            uint32_t e[3];
            memcpy(e, b->bytes + toc + 20 + 12 * i, sizeof e);
            if (e[0] == key)
                return item_at(b, e[1], type, payload, length);
        }
        toc = head[3];
    }
    return NO;
}

static NSString *
string_item(const book *b, uint32_t key)
{
    uint32_t type, len;
    const uint8_t *p;
    if (!item_for_key(b, key, &type, &p, &len) || (type != kTypeString && type != kTypeURL))
        return nil;
    return [[[NSString alloc] initWithBytes:p length:len encoding:NSUTF8StringEncoding] autorelease];
}

static int64_t
number_item(const book *b, uint32_t key, int64_t fallback)
{
    uint32_t type, len;
    const uint8_t *p;
    if (!item_for_key(b, key, &type, &p, &len))
        return fallback;
    if (type == kTypeNumberSInt32 && len >= 4) {
        int32_t v;
        memcpy(&v, p, 4);
        return v;
    }
    if (type == kTypeNumberSInt64 && len >= 8) {
        int64_t v;
        memcpy(&v, p, 8);
        return v;
    }
    return fallback;
}

static NSArray *
path_components(const book *b)
{
    uint32_t type, len;
    const uint8_t *p;
    if (!item_for_key(b, kKeyPath, &type, &p, &len) || type != kTypeArray)
        return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (uint32_t i = 0; i + 4 <= len; i += 4) {
        uint32_t off, t, l;
        const uint8_t *q;
        memcpy(&off, p + i, 4);
        if (!item_at(b, off, &t, &q, &l) || t != kTypeString)
            return nil;
        NSString *s = [[[NSString alloc] initWithBytes:q length:l encoding:NSUTF8StringEncoding] autorelease];
        if (!s)
            return nil;
        [out addObject:s];
    }
    return out;
}

static NSString *
resolved_path(NSData *bookmarkData, NSURL *relativeURL)
{
    book b;
    if (!open_book(bookmarkData, &b))
        return nil;
    NSArray *parts = path_components(&b);
    if (!parts)
        return nil;
    int64_t up = number_item(&b, kKeyParentCount, -1);
    if (up >= 0 && relativeURL) {
        NSString *base = [[relativeURL path] stringByStandardizingPath];
        for (int64_t i = 0; i < up; i++)
            base = [base stringByDeletingLastPathComponent];
        return [base stringByAppendingPathComponent:[NSString pathWithComponents:[parts count] ? parts : @[@""]]];
    }
    return [@"/" stringByAppendingString:[parts componentsJoinedByString:@"/"]];
}

- (instancetype)initByResolvingBookmarkData:(NSData *)bookmarkData options:(NSURLBookmarkResolutionOptions)options
                              relativeToURL:(NSURL *)relativeURL bookmarkDataIsStale:(BOOL *)isStale error:(NSError **)error
{
    if (isStale)
        *isStale = NO;
    NSString *path = bookmarkData ? resolved_path(bookmarkData, relativeURL) : nil;
    if (!path) {
        [self release];
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        return nil;
    }
    BOOL dir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir]) {
        [self release];
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError
                                     userInfo:@{NSFilePathErrorKey : path}];
        return nil;
    }
    return [self initFileURLWithPath:path isDirectory:dir];
}

+ (instancetype)URLByResolvingBookmarkData:(NSData *)bookmarkData options:(NSURLBookmarkResolutionOptions)options
                             relativeToURL:(NSURL *)relativeURL bookmarkDataIsStale:(BOOL *)isStale error:(NSError **)error
{
    return [[[self alloc] initByResolvingBookmarkData:bookmarkData options:options relativeToURL:relativeURL
                                  bookmarkDataIsStale:isStale error:error] autorelease];
}

+ (NSDictionary<NSURLResourceKey, id> *)resourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys fromBookmarkData:(NSData *)bookmarkData
{
    book b;
    if (!bookmarkData || !open_book(bookmarkData, &b))
        return nil;
    NSString *path = resolved_path(bookmarkData, nil);
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *name = [path lastPathComponent];
    if (path)
        [out setObject:path forKey:@"_NSURLPathKey"];
    if (name && [keys containsObject:NSURLNameKey])
        [out setObject:name forKey:NSURLNameKey];
    if ([keys containsObject:NSURLLocalizedNameKey]) {
        NSString *shown = string_item(&b, kKeyDisplayName) ?: name;
        if (shown)
            [out setObject:shown forKey:NSURLLocalizedNameKey];
    }
    if ([keys containsObject:NSURLVolumeNameKey]) {
        NSString *v = string_item(&b, kKeyVolumeName);
        if (v)
            [out setObject:v forKey:NSURLVolumeNameKey];
    }
    return out;
}

/* An alias file holds bookmark data. */
+ (NSData *)bookmarkDataWithContentsOfURL:(NSURL *)bookmarkFileURL error:(NSError **)error
{
    NSData *d = [NSData dataWithContentsOfURL:bookmarkFileURL options:0 error:error];
    book b;
    if (d && !open_book(d, &b)) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError
                                     userInfo:@{NSURLErrorKey : bookmarkFileURL}];
        return nil;
    }
    return d;
}

+ (BOOL)writeBookmarkData:(NSData *)bookmarkData toURL:(NSURL *)bookmarkFileURL
                  options:(NSURLBookmarkFileCreationOptions)options error:(NSError **)error
{
    return [bookmarkData writeToURL:bookmarkFileURL options:NSDataWritingAtomic error:error];
}

@end
