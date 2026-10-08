/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSFileWrapper (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSFileWrapper.h>: regular files, directories and symbolic
 * links, read from and written to disk. A directory's children are keyed
 * by preferred filename; a clashing name gets Apple's "1__#$!@%!#__name"
 * key, which is also the name written to disk, as Apple's is.
 *
 * serializedRepresentation is a keyed archive here; Apple's is the flat
 * RTFD format, which comes with AppKit's RTFD support.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"

typedef enum { KIND_FILE, KIND_DIRECTORY, KIND_LINK } Kind;

@interface NSFileWrapper () {
    Kind _kind;
    NSData *_contents;
    NSMutableDictionary *_children;
    NSURL *_destination;
    NSString *_preferred, *_filename;
    NSDictionary *_attributes;
    NSURL *_readFrom;
    NSFileWrapper *_parent;     /* not retained */
}
@end

@implementation NSFileWrapper

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initRegularFileWithContents:(NSData *)contents
{
    if ((self = [super init])) {
        _kind = KIND_FILE;
        _contents = [contents copy];
        _attributes = [[NSDictionary alloc] init];
    }
    return self;
}

- (instancetype)initDirectoryWithFileWrappers:(NSDictionary<NSString *, NSFileWrapper *> *)childrenByPreferredName
{
    if ((self = [super init])) {
        _kind = KIND_DIRECTORY;
        _children = [NSMutableDictionary new];
        _attributes = [[NSDictionary alloc] init];
        for (NSString *name in childrenByPreferredName) {
            NSFileWrapper *w = [childrenByPreferredName objectForKey:name];
            if (![w preferredFilename]) [w setPreferredFilename:name];
            [_children setObject:w forKey:name];
            w->_parent = self;
        }
    }
    return self;
}

- (instancetype)initSymbolicLinkWithDestinationURL:(NSURL *)url
{
    if ((self = [super init])) {
        _kind = KIND_LINK;
        _destination = [url copy];
        _attributes = [[NSDictionary alloc] init];
    }
    return self;
}

- (instancetype)init { return [self initDirectoryWithFileWrappers:@{}]; }

- (BOOL)loadFromURL:(NSURL *)url error:(NSError **)outError
{
    NSString *path = [url path];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:outError];
    if (!attrs) return NO;
    [_attributes release];
    _attributes = [attrs copy];
    NSString *type = [attrs fileType];
    [_contents release];
    _contents = nil;
    [_children release];
    _children = nil;
    [_destination release];
    _destination = nil;
    if ([type isEqualToString:NSFileTypeSymbolicLink]) {
        _kind = KIND_LINK;
        NSString *dest = [fm destinationOfSymbolicLinkAtPath:path error:outError];
        if (!dest) return NO;
        _destination = [[NSURL fileURLWithPath:dest] copy];
        if (![dest hasPrefix:@"/"]) {
            [_destination release];
            _destination = [[NSURL URLWithString:[dest stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]]] copy];
        }
    } else if ([type isEqualToString:NSFileTypeDirectory]) {
        _kind = KIND_DIRECTORY;
        _children = [NSMutableDictionary new];
        NSArray *names = [fm contentsOfDirectoryAtPath:path error:outError];
        if (!names) return NO;
        for (NSString *name in names) {
            NSFileWrapper *child = [[[NSFileWrapper alloc] initWithURL:[url URLByAppendingPathComponent:name] options:0 error:outError] autorelease];
            if (!child) return NO;
            [_children setObject:child forKey:name];
            child->_parent = self;
        }
    } else {
        _kind = KIND_FILE;
        _contents = [[NSData alloc] initWithContentsOfURL:url options:0 error:outError];
        if (!_contents) return NO;
    }
    [_filename release];
    _filename = [[url lastPathComponent] copy];
    if (!_preferred) _preferred = [_filename copy];
    [_readFrom release];
    _readFrom = [url copy];
    return YES;
}

- (instancetype)initWithURL:(NSURL *)url options:(NSFileWrapperReadingOptions)options error:(NSError **)outError
{
    if ((self = [super init])) {
        /* Without following a final symbolic link. */
        if (![[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:NULL]) {
            if (outError) *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError
                                                      userInfo:@{ NSFilePathErrorKey: [url path] ? [url path] : @"", NSURLErrorKey: url }];
            [self release];
            return nil;
        }
        if (![self loadFromURL:url error:outError]) {
            [self release];
            return nil;
        }
    }
    return self;
}

- (instancetype)initWithSerializedRepresentation:(NSData *)serializeRepresentation
{
    [self release];
    return [[NSKeyedUnarchiver unarchivedObjectOfClass:[NSFileWrapper class] fromData:serializeRepresentation error:NULL] retain];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _kind = (Kind)[coder decodeIntForKey:@"NSFileWrapperKind"];
        _contents = [[coder decodeObjectOfClass:[NSData class] forKey:@"NSFileWrapperContents"] copy];
        _destination = [[coder decodeObjectOfClass:[NSURL class] forKey:@"NSFileWrapperLink"] copy];
        _preferred = [[coder decodeObjectOfClass:[NSString class] forKey:@"NSFileWrapperPreferredName"] copy];
        _filename = [[coder decodeObjectOfClass:[NSString class] forKey:@"NSFileWrapperFilename"] copy];
        _attributes = [[NSDictionary alloc] init];
        NSDictionary *children = [coder decodeObjectOfClasses:[NSSet setWithObjects:[NSDictionary class], [NSString class], [NSFileWrapper class], nil]
                                                       forKey:@"NSFileWrapperChildren"];
        if (_kind == KIND_DIRECTORY) {
            _children = [children mutableCopy];
            for (NSFileWrapper *w in [_children allValues]) w->_parent = self;
            if (!_children) _children = [NSMutableDictionary new];
        }
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:_kind forKey:@"NSFileWrapperKind"];
    if (_contents) [coder encodeObject:_contents forKey:@"NSFileWrapperContents"];
    if (_destination) [coder encodeObject:_destination forKey:@"NSFileWrapperLink"];
    if (_preferred) [coder encodeObject:_preferred forKey:@"NSFileWrapperPreferredName"];
    if (_filename) [coder encodeObject:_filename forKey:@"NSFileWrapperFilename"];
    if (_children) [coder encodeObject:_children forKey:@"NSFileWrapperChildren"];
}

- (void)dealloc
{
    for (NSFileWrapper *w in [_children allValues]) w->_parent = nil;
    [_contents release];
    [_children release];
    [_destination release];
    [_preferred release];
    [_filename release];
    [_attributes release];
    [_readFrom release];
    [super dealloc];
}

- (BOOL)isDirectory { return _kind == KIND_DIRECTORY; }
- (BOOL)isRegularFile { return _kind == KIND_FILE; }
- (BOOL)isSymbolicLink { return _kind == KIND_LINK; }

- (NSString *)preferredFilename { return _preferred; }
- (void)setPreferredFilename:(NSString *)name { [_preferred release]; _preferred = [name copy]; }
- (NSString *)filename { return _filename; }
- (void)setFilename:(NSString *)name { [_filename release]; _filename = [name copy]; }
- (NSDictionary *)fileAttributes { return _attributes; }
- (void)setFileAttributes:(NSDictionary *)attrs { [_attributes release]; _attributes = [attrs copy]; }

- (void)requireKind:(Kind)kind cmd:(SEL)cmd
{
    if (_kind != kind)
        FinchRaise(NSInternalInconsistencyException, "-[NSFileWrapper %s] tried to %s on a file wrapper that isn't a %s.", sel_getName(cmd),
            kind == KIND_DIRECTORY ? "get the children" : kind == KIND_FILE ? "get the contents" : "get the destination",
            kind == KIND_DIRECTORY ? "directory" : kind == KIND_FILE ? "regular file" : "symbolic link");
}

- (NSData *)regularFileContents { [self requireKind:KIND_FILE cmd:_cmd]; return _contents; }
- (NSURL *)symbolicLinkDestinationURL { [self requireKind:KIND_LINK cmd:_cmd]; return _destination; }
- (NSDictionary<NSString *, NSFileWrapper *> *)fileWrappers { [self requireKind:KIND_DIRECTORY cmd:_cmd]; return [[_children copy] autorelease]; }

/* A free key for `name`: the name, else Apple's numbered form. */
- (NSString *)keyFor:(NSString *)name
{
    if (![_children objectForKey:name]) return name;
    for (NSUInteger i = 1;; i++) {
        NSString *k = [NSString stringWithFormat:@"%lu__#$!@%%!#__%@", (unsigned long)i, name];
        if (![_children objectForKey:k]) return k;
    }
}

- (NSString *)addFileWrapper:(NSFileWrapper *)child
{
    [self requireKind:KIND_DIRECTORY cmd:_cmd];
    NSString *name = [child preferredFilename];
    if (!name) FinchRaise(NSInvalidArgumentException, "-[NSFileWrapper addFileWrapper:] called with a file wrapper that has no preferred filename");
    NSString *key = [self keyFor:name];
    [_children setObject:child forKey:key];
    child->_parent = self;
    return key;
}

- (NSString *)addRegularFileWithContents:(NSData *)data preferredFilename:(NSString *)fileName
{
    NSFileWrapper *w = [[[NSFileWrapper alloc] initRegularFileWithContents:data] autorelease];
    w.preferredFilename = fileName;
    return [self addFileWrapper:w];
}

- (void)removeFileWrapper:(NSFileWrapper *)child
{
    [self requireKind:KIND_DIRECTORY cmd:_cmd];
    NSString *key = [self keyForFileWrapper:child];
    if (key) {
        child->_parent = nil;
        [_children removeObjectForKey:key];
    }
}

- (NSString *)keyForFileWrapper:(NSFileWrapper *)child
{
    for (NSString *k in _children) if ([_children objectForKey:k] == child) return k;
    return nil;
}

- (BOOL)writeToURL:(NSURL *)url options:(NSFileWrapperWritingOptions)options originalContentsURL:(NSURL *)originalContentsURL error:(NSError **)outError
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [url path];
    switch (_kind) {
    case KIND_FILE:
        if (![_contents writeToURL:url options:(options & NSFileWrapperWritingAtomic) ? NSDataWritingAtomic : 0 error:outError]) return NO;
        break;
    case KIND_LINK:
        [fm removeItemAtPath:path error:NULL];
        /* A relative destination stays relative, as Apple's does. */
        if (![fm createSymbolicLinkAtPath:path withDestinationPath:[_destination baseURL] || ![_destination isFileURL] ? [_destination relativePath] : [_destination path]
                                    error:outError])
            return NO;
        break;
    case KIND_DIRECTORY:
        if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:outError]) return NO;
        for (NSString *key in _children) {
            NSFileWrapper *child = [_children objectForKey:key];
            if (![child writeToURL:[url URLByAppendingPathComponent:key] options:options originalContentsURL:nil error:outError]) return NO;
        }
        break;
    }
    if (options & NSFileWrapperWritingWithNameUpdating) [self setFilename:[url lastPathComponent]];
    return YES;
}

- (BOOL)readFromURL:(NSURL *)url options:(NSFileWrapperReadingOptions)options error:(NSError **)outError { return [self loadFromURL:url error:outError]; }

- (BOOL)matchesContentsOfURL:(NSURL *)url
{
    NSFileWrapper *other = [[[NSFileWrapper alloc] initWithURL:url options:0 error:NULL] autorelease];
    if (!other || other->_kind != _kind) return NO;
    switch (_kind) {
    case KIND_FILE: return [_contents isEqualToData:other->_contents];
    case KIND_LINK: return [[_destination relativeString] isEqualToString:[other->_destination relativeString]];
    case KIND_DIRECTORY:
        if (![[NSSet setWithArray:[_children allKeys]] isEqualToSet:[NSSet setWithArray:[other->_children allKeys]]]) return NO;
        for (NSString *k in _children)
            if (![[_children objectForKey:k] matchesContentsOfURL:[url URLByAppendingPathComponent:k]]) return NO;
        return YES;
    }
    return NO;
}

- (BOOL)needsToBeUpdatedFromURL:(NSURL *)url { return ![self matchesContentsOfURL:url]; }

- (NSData *)serializedRepresentation
{
    return [NSKeyedArchiver archivedDataWithRootObject:self requiringSecureCoding:YES error:NULL];
}

- (NSString *)description
{
    const char *kind = _kind == KIND_DIRECTORY ? "directory" : _kind == KIND_FILE ? "regular file" : "symbolic link";
    return [NSString stringWithFormat:@"<%s: %p> (%s %@)", object_getClassName(self), self, kind, _preferred ? _preferred : @""];
}

@end
