/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * UniformTypeIdentifiers: UTType, the system's type identifiers and how
 * files, extensions and MIME types map to them.
 *
 * Declared types come from UTTypeTable.inc (the system's) and from the
 * main bundle's UTExportedTypeDeclarations and UTImportedTypeDeclarations.
 * A tag no declared type claims gets a dynamic type, whose identifier
 * ("dyn.a...") encodes its tag and conformance as macOS's do: the string
 * "?0=<conformance>:<tag class>=<tag>" (well-known types and tag classes as
 * short codes; ':', '=' and '\' escaped with '\'), five bits per letter,
 * most significant first, over the alphabet below. Worked out from macOS's
 * identifiers; the code is Finch's.
 */
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UTType.h>
#import <UniformTypeIdentifiers/UTTagClass.h>

NSString *const UTTagClassFilenameExtension = @"public.filename-extension";
NSString *const UTTagClassMIMEType = @"public.mime-type";

typedef struct {
    const char *identifier, *constant, *description, *parents, *extensions, *mimes;
} TypeEntry;

static const TypeEntry table[] = {
#include "UTTypeTable.inc"
};

/* A declared type's facts. */
@interface UTFinchDecl : NSObject
@property (copy) NSString *identifier, *summary;
@property (copy) NSArray<NSString *> *parents, *extensions, *mimes;
@end
@implementation UTFinchDecl
@end

@interface UTType ()
- (instancetype)_finchInitWithIdentifier:(NSString *)identifier decl:(UTFinchDecl *)decl dynamicTags:(NSDictionary *)tags
                             conformance:(NSString *)conformance;
@end

static NSMutableDictionary<NSString *, UTFinchDecl *> *decls;  /* lowercased identifier -> facts */
static NSMutableDictionary<NSString *, UTType *> *types;       /* lowercased identifier -> type */
static NSLock *lock;

static NSArray *
words(const char *s)
{
    NSString *str = s ? @(s) : @"";
    return [str length] ? [str componentsSeparatedByString:@" "] : @[];
}

static void
add_bundle_declarations(NSArray *list)
{
    if (![list isKindOfClass:[NSArray class]])
        return;
    for (NSDictionary *d in list) {
        if (![d isKindOfClass:[NSDictionary class]] || ![d[@"UTTypeIdentifier"] isKindOfClass:[NSString class]])
            continue;
        UTFinchDecl *x = [[UTFinchDecl new] autorelease];
        x.identifier = d[@"UTTypeIdentifier"];
        x.summary = d[@"UTTypeDescription"];
        id conforms = d[@"UTTypeConformsTo"];
        x.parents = [conforms isKindOfClass:[NSString class]] ? @[ conforms ] : ([conforms isKindOfClass:[NSArray class]] ? conforms : @[]);
        NSDictionary *tags = d[@"UTTypeTagSpecification"];
        id ext = tags[UTTagClassFilenameExtension], mime = tags[UTTagClassMIMEType];
        x.extensions = [ext isKindOfClass:[NSString class]] ? @[ ext ] : (ext ?: @[]);
        x.mimes = [mime isKindOfClass:[NSString class]] ? @[ mime ] : (mime ?: @[]);
        NSString *key = [x.identifier lowercaseString];
        if (!decls[key])
            decls[key] = x;
    }
}

static void
setup(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSLock alloc] init];
        decls = [[NSMutableDictionary alloc] init];
        types = [[NSMutableDictionary alloc] init];
        for (size_t i = 0; i < sizeof table / sizeof *table; i++) {
            UTFinchDecl *x = [[UTFinchDecl new] autorelease];
            x.identifier = @(table[i].identifier);
            x.summary = table[i].description ? @(table[i].description) : nil;
            x.parents = words(table[i].parents);
            x.extensions = words(table[i].extensions);
            x.mimes = words(table[i].mimes);
            decls[[x.identifier lowercaseString]] = x;
        }
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        add_bundle_declarations(info[@"UTExportedTypeDeclarations"]);
        add_bundle_declarations(info[@"UTImportedTypeDeclarations"]);
    });
}

#pragma mark - Dynamic identifiers

static NSString *const alphabet = @"abcdefghkmnpqrstuvwxyz0123456789";

/* Well-known types and tag classes have short codes in dynamic identifiers. */
static NSDictionary *
codes(void)
{
    static NSDictionary *c;
    if (!c)
        c = [@{
            @"public.filename-extension" : @"1", @"com.apple.ostype" : @"2", @"public.mime-type" : @"3",
            @"com.apple.nspboard-type" : @"4", @"public.data" : @"6", @"public.text" : @"7",
            @"public.plain-text" : @"8", @"public.utf16-plain-text" : @"9", @"public.image" : @"B",
            @"public.video" : @"C", @"public.audio" : @"D", @"public.directory" : @"E", @"public.folder" : @"F",
            @"com.apple.package" : @"10", @"public.url" : @"11", @"public.utf16-external-plain-text" : @"12",
            @"public.content" : @"13",
        } retain];
    return c;
}

static NSString *
code_for(NSString *s)
{
    return codes()[s] ?: s;
}

static NSString *
name_for_code(NSString *s)
{
    for (NSString *k in codes())
        if ([codes()[k] isEqualToString:s])
            return k;
    return s;
}

static NSString *
escape(NSString *s)
{
    NSMutableString *m = [NSMutableString string];
    for (NSUInteger i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == ':' || c == '=' || c == '\\')
            [m appendString:@"\\"];
        [m appendFormat:@"%C", c];
    }
    return m;
}

static NSString *
encode(NSString *payload)
{
    NSData *d = [payload dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = [d bytes];
    NSMutableString *out = [NSMutableString stringWithString:@"dyn.a"];
    unsigned acc = 0;
    int bits = 0;
    for (NSUInteger i = 0; i < [d length]; i++) {
        acc = (acc << 8) | b[i];
        bits += 8;
        while (bits >= 5) {
            [out appendFormat:@"%C", [alphabet characterAtIndex:(acc >> (bits - 5)) & 31]];
            bits -= 5;
        }
    }
    if (bits)
        [out appendFormat:@"%C", [alphabet characterAtIndex:(acc << (5 - bits)) & 31]];
    return out;
}

static NSString *
decode(NSString *identifier)
{
    if (![identifier hasPrefix:@"dyn.a"])
        return nil;
    NSMutableData *d = [NSMutableData data];
    unsigned acc = 0;
    int bits = 0;
    for (NSUInteger i = 5; i < [identifier length]; i++) {
        NSUInteger v = [alphabet rangeOfString:[identifier substringWithRange:NSMakeRange(i, 1)]].location;
        if (v == NSNotFound)
            return nil;
        acc = (acc << 5) | (unsigned)v;
        bits += 5;
        if (bits >= 8) {
            uint8_t byte = (acc >> (bits - 8)) & 0xff;
            [d appendBytes:&byte length:1];
            bits -= 8;
        }
    }
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease];
}

/* "?0=6:1=txt" -> conformance and tags; splitting on unescaped ':' and '='. */
static void
parse_payload(NSString *p, NSString **conformance, NSMutableDictionary *tags)
{
    BOOL hasConformance = [p hasPrefix:@"?"];
    if (hasConformance)
        p = [p substringFromIndex:1];
    NSMutableArray *parts = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    for (NSUInteger i = 0; i < [p length]; i++) {
        unichar c = [p characterAtIndex:i];
        if (c == '\\' && i + 1 < [p length]) {
            [cur appendFormat:@"%C", [p characterAtIndex:++i]];
        } else if (c == ':') {
            [parts addObject:[[cur copy] autorelease]];
            [cur setString:@""];
        } else {
            [cur appendFormat:@"%C", (unichar)(c == '=' ? 0x1 : c)];
        }
    }
    [parts addObject:cur];
    for (NSString *part in parts) {
        NSRange eq = [part rangeOfString:@"\x01"];
        if (eq.location == NSNotFound)
            continue;
        NSString *k = [part substringToIndex:eq.location], *v = [part substringFromIndex:NSMaxRange(eq)];
        if (hasConformance && [k isEqualToString:@"0"])
            *conformance = name_for_code(v);
        else {
            NSString *cls = name_for_code(k);
            tags[cls] = [(tags[cls] ?: @[]) arrayByAddingObject:v];
        }
    }
}

#pragma mark - UTType

@implementation UTType {
    NSString *_identifier;
    UTFinchDecl *_decl;
    NSDictionary *_dynamicTags;
    NSString *_conformance;  /* a dynamic type's */
}

static UTType *
type_for(NSString *identifier)
{
    setup();
    NSString *key = [identifier lowercaseString];
    [lock lock];
    UTType *t = types[key];
    if (!t) {
        UTFinchDecl *d = decls[key];
        if (d) {
            t = [[[UTType alloc] _finchInitWithIdentifier:d.identifier decl:d dynamicTags:nil conformance:nil]
                autorelease];
        } else {
            NSString *payload = decode(identifier);
            if (payload) {
                NSString *conf = nil;
                NSMutableDictionary *tags = [NSMutableDictionary dictionary];
                parse_payload(payload, &conf, tags);
                t = [[[UTType alloc] _finchInitWithIdentifier:identifier decl:nil dynamicTags:tags conformance:conf]
                    autorelease];
            }
        }
        if (t)
            types[key] = t;
    }
    [lock unlock];
    return t;
}

- (instancetype)_finchInitWithIdentifier:(NSString *)identifier decl:(UTFinchDecl *)decl dynamicTags:(NSDictionary *)tags
                             conformance:(NSString *)conformance
{
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _decl = [decl retain];
        _dynamicTags = [tags copy];
        _conformance = [conformance copy];
    }
    return self;
}

- (void)dealloc
{
    [_identifier release];
    [_decl release];
    [_dynamicTags release];
    [_conformance release];
    [super dealloc];
}

+ (instancetype)typeWithIdentifier:(NSString *)identifier
{
    return identifier ? type_for(identifier) : nil;
}

static UTType *
for_tag(NSString *tag, NSString *tagClass, UTType *supertype, BOOL all, NSMutableArray *matches)
{
    setup();
    if (!tag || !tagClass)
        return nil;
    BOOL ext = [tagClass isEqualToString:UTTagClassFilenameExtension];
    BOOL mime = [tagClass isEqualToString:UTTagClassMIMEType];
    /* as Apple's: extensions and MIME types name data unless asked otherwise */
    if (!supertype && (ext || mime))
        supertype = type_for(@"public.data");
    NSString *want = [tag lowercaseString];
    NSArray *keys = [[decls allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *k in keys) {
        UTFinchDecl *d = decls[k];
        NSArray *list = ext ? d.extensions : mime ? d.mimes : nil;
        for (NSString *v in list) {
            if ([[v lowercaseString] isEqualToString:want]) {
                UTType *t = type_for(d.identifier);
                if (!supertype || [t conformsToType:supertype]) {
                    if (!all)
                        return t;
                    [matches addObject:t];
                }
                break;
            }
        }
    }
    if (all && [matches count])
        return [matches firstObject];
    /* none declared: a dynamic type, conforming to public.data unless told otherwise (not for pasteboard types) */
    NSString *conformance = supertype ? [supertype identifier] : nil;
    NSString *payload = [NSString stringWithFormat:@"%@%@=%@",
                                                   conformance ? [NSString stringWithFormat:@"?0=%@:", escape(code_for(conformance))] : @"",
                                                   escape(code_for(tagClass)), escape(tag)];
    UTType *t = type_for(encode(payload));
    if (all && t)
        [matches addObject:t];
    return t;
}

+ (instancetype)typeWithFilenameExtension:(NSString *)ext
{
    return for_tag(ext, UTTagClassFilenameExtension, nil, NO, nil);
}

+ (instancetype)typeWithFilenameExtension:(NSString *)ext conformingToType:(UTType *)supertype
{
    return for_tag(ext, UTTagClassFilenameExtension, supertype, NO, nil);
}

+ (instancetype)typeWithMIMEType:(NSString *)mime
{
    return for_tag(mime, UTTagClassMIMEType, nil, NO, nil);
}

+ (instancetype)typeWithMIMEType:(NSString *)mime conformingToType:(UTType *)supertype
{
    return for_tag(mime, UTTagClassMIMEType, supertype, NO, nil);
}

+ (instancetype)typeWithTag:(NSString *)tag tagClass:(NSString *)tagClass conformingToType:(UTType *)supertype
{
    return for_tag(tag, tagClass, supertype, NO, nil);
}

+ (NSArray<UTType *> *)typesWithTag:(NSString *)tag tagClass:(NSString *)tagClass conformingToType:(UTType *)supertype
{
    NSMutableArray *a = [NSMutableArray array];
    for_tag(tag, tagClass, supertype, YES, a);
    return a;
}

+ (UTType *)exportedTypeWithIdentifier:(NSString *)identifier
{
    return [self exportedTypeWithIdentifier:identifier conformingToType:[UTType typeWithIdentifier:@"public.data"]];
}

+ (UTType *)exportedTypeWithIdentifier:(NSString *)identifier conformingToType:(UTType *)parentType
{
    UTType *t = [self typeWithIdentifier:identifier];
    if (t)
        return t;
    /* undeclared in Info.plist: a type of that identifier anyway, as Apple's returns (with a runtime warning) */
    UTFinchDecl *d = [[UTFinchDecl new] autorelease];
    d.identifier = identifier;
    d.parents = parentType ? @[ [parentType identifier] ] : @[];
    return [[[UTType alloc] _finchInitWithIdentifier:identifier decl:d dynamicTags:nil conformance:nil] autorelease];
}

+ (UTType *)importedTypeWithIdentifier:(NSString *)identifier
{
    return [self exportedTypeWithIdentifier:identifier];
}

+ (UTType *)importedTypeWithIdentifier:(NSString *)identifier conformingToType:(UTType *)parentType
{
    return [self exportedTypeWithIdentifier:identifier conformingToType:parentType];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *identifier = [coder decodeObjectOfClass:[NSString class] forKey:@"identifier"];
    [self release];
    return [type_for(identifier) retain];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"identifier"];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (NSString *)identifier { return _identifier; }
- (BOOL)isDynamic { return _decl == nil; }
- (BOOL)isDeclared { return _decl != nil && [decls objectForKey:[_identifier lowercaseString]] == _decl; }
- (BOOL)isPublicType { return [_identifier hasPrefix:@"public."]; }
- (NSNumber *)version { return nil; }
- (NSURL *)referenceURL { return nil; }
- (NSString *)localizedDescription { return _decl.summary; }
- (NSString *)description { return _identifier; }

- (NSString *)debugDescription
{
    return [NSString stringWithFormat:@"<%@ %p> %@ (%@dynamic, %@declared)", [self class], self, _identifier,
                                      [self isDynamic] ? @"" : @"not ", [self isDeclared] ? @"" : @"not "];
}

- (BOOL)isEqual:(id)other
{
    return other == self ||
           ([other isKindOfClass:[UTType class]] &&
            [_identifier caseInsensitiveCompare:[(UTType *)other identifier]] == NSOrderedSame);
}

- (NSUInteger)hash { return [[_identifier lowercaseString] hash]; }

- (NSDictionary<NSString *, NSArray<NSString *> *> *)tags
{
    if (_dynamicTags)
        return _dynamicTags;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if ([_decl.extensions count])
        d[UTTagClassFilenameExtension] = _decl.extensions;
    if ([_decl.mimes count])
        d[UTTagClassMIMEType] = _decl.mimes;
    return d;
}

- (NSString *)preferredFilenameExtension { return [[self tags][UTTagClassFilenameExtension] firstObject]; }
- (NSString *)preferredMIMEType { return [[self tags][UTTagClassMIMEType] firstObject]; }

- (NSArray<NSString *> *)_finchParents
{
    if (_decl)
        return _decl.parents;
    return _conformance ? @[ _conformance ] : @[];
}

- (NSSet<UTType *> *)supertypes
{
    NSMutableSet *set = [NSMutableSet set];
    NSMutableArray *todo = [[[self _finchParents] mutableCopy] autorelease];
    while ([todo count]) {
        NSString *p = [todo lastObject];
        [todo removeLastObject];
        UTType *t = type_for(p);
        if (!t || [set containsObject:t])
            continue;
        [set addObject:t];
        [todo addObjectsFromArray:[t _finchParents]];
    }
    return set;
}

- (BOOL)conformsToType:(UTType *)type
{
    return [self isEqual:type] || [[self supertypes] containsObject:type];
}

- (BOOL)isSupertypeOfType:(UTType *)type { return ![self isEqual:type] && [type conformsToType:self]; }
- (BOOL)isSubtypeOfType:(UTType *)type { return ![self isEqual:type] && [self conformsToType:type]; }

@end

#pragma mark - For Foundation (NSURL's resource values)

/* The type of the file at a path, as NSURLTypeIdentifierKey reports it. */
__attribute__((visibility("default"))) NSString *
_UTFinchTypeIdentifierForPath(NSString *path, BOOL directory, BOOL package)
{
    NSString *ext = [path pathExtension];
    if (directory) {
        if ([path isEqualToString:@"/"])
            return @"public.volume";
        if (package) {
            UTType *t = [ext length] ? [UTType typeWithFilenameExtension:ext
                                                        conformingToType:[UTType typeWithIdentifier:@"com.apple.package"]]
                                     : nil;
            return t && ![t isDynamic] ? [t identifier] : @"com.apple.package";
        }
        return @"public.folder";
    }
    if (![ext length])
        return @"public.data";
    return [[UTType typeWithFilenameExtension:ext] identifier];
}

/* The kind of document a type is, as NSURLLocalizedTypeDescriptionKey reports it. */
__attribute__((visibility("default"))) NSString *
_UTFinchLocalizedDescription(NSString *identifier)
{
    static NSDictionary *kinds;
    if (!kinds)
        kinds = [@{
            @"public.folder" : @"Folder", @"com.apple.application-bundle" : @"Application",
            @"public.plain-text" : @"Plain Text Document", @"public.rtf" : @"Rich Text Document",
            @"com.apple.rtfd" : @"Rich Text Document with Attachments", @"public.volume" : @"Volume",
            @"public.data" : @"Document", @"com.apple.package" : @"Package",
        } retain];
    NSString *k = kinds[identifier];
    if (k)
        return k;
    UTType *t = [UTType typeWithIdentifier:identifier];
    NSString *d = [t localizedDescription];
    if ([d length])
        return [[[d substringToIndex:1] uppercaseString] stringByAppendingString:[d substringFromIndex:1]];
    return @"Document";
}
