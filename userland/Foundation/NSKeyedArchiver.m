/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSKeyedArchiver and NSKeyedUnarchiver (docs/design/FOUNDATION.md), against
 * the SDK's <Foundation/NSKeyedArchiver.h>. The archive is Apple's:
 *
 *   { $archiver = NSKeyedArchiver; $version = 100000;
 *     $top = { root = UID 1 };
 *     $objects = ( "$null", <root>, ... ) }
 *
 * Objects are numbered as they are first met. Strings, numbers and data
 * (whose classForKeyedArchiver is exactly NSString, NSNumber or NSData) are
 * stored as plist values; anything else is a dictionary of what its
 * -encodeWithCoder: wrote plus "$class", a reference to { $classname,
 * $classes } that is appended after the object's contents and shared by
 * name. Objects are uniqued by identity. A conditional object that is never
 * encoded outright becomes $null. The C types of the unkeyed API go under
 * "$0", "$1", ...; structs are refused, as Apple's are.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

typedef const struct __CFKeyedArchiverUID *CFKeyedArchiverUIDRef;
CF_EXPORT CFTypeID _CFKeyedArchiverUIDGetTypeID(void);
CF_EXPORT CFKeyedArchiverUIDRef _CFKeyedArchiverUIDCreate(CFAllocatorRef allocator, uint32_t value);
CF_EXPORT uint32_t _CFKeyedArchiverUIDGetValue(CFKeyedArchiverUIDRef uid);

NSString *const NSKeyedArchiveRootObjectKey = @"root";

static id
uid(NSUInteger n)
{
    return [(id)_CFKeyedArchiverUIDCreate(NULL, (uint32_t)n) autorelease];
}

static BOOL
is_uid(id o)
{
    return o && CFGetTypeID((CFTypeRef)o) == _CFKeyedArchiverUIDGetTypeID();
}

static NSMutableDictionary *global_class_names;   /* NSKeyedArchiver: class name -> coded name */
static NSMutableDictionary *global_classes;       /* NSKeyedUnarchiver: coded name -> class */

/* An old-style C array from -encodeArrayOfObjCType:count:at:, as Apple's. */
@interface _NSKeyedCoderOldStyleArray : NSObject <NSSecureCoding> {
@public
    char _type;
    NSUInteger _count, _size;
    void *_bytes;
    BOOL _owned;
}
@end

/* MARK: - NSKeyedArchiver */

/* One object being encoded: its dictionary and its "$n" counter. */
@interface _FinchEncodingFrame : NSObject {
@public
    NSMutableDictionary *dict;
    NSUInteger next;
}
@end
@implementation _FinchEncodingFrame
- (void)dealloc { [dict release]; [super dealloc]; }
@end

@implementation NSKeyedArchiver {
    NSMutableArray *_objects;
    CFMutableDictionaryRef _uids;          /* object (identity, retained) -> UID index */
    NSMutableDictionary *_classUIDs;       /* coded class name -> UID index */
    NSMutableDictionary *_stringUIDs;      /* strings are shared by value, as Apple's are */
    NSMutableArray *_frames;
    NSMutableIndexSet *_reserved;          /* numbers given to conditional objects not yet encoded */
    NSMutableArray *_pending;              /* conditional references: (dict, key) */
    NSMutableDictionary *_classNames;
    NSMutableData *_output;
    NSData *_encoded;
    id<NSKeyedArchiverDelegate> _delegate;
    NSPropertyListFormat _format;
    BOOL _secure, _finished;
}

static CFDictionaryKeyCallBacks identity_keys = { 0, NULL, NULL, NULL, NULL, NULL };

- (instancetype)initRequiringSecureCoding:(BOOL)requiresSecureCoding
{
    if ((self = [super init])) {
        _objects = [[NSMutableArray alloc] initWithObjects:@"$null", nil];
        identity_keys.retain = kCFTypeDictionaryKeyCallBacks.retain;
        identity_keys.release = kCFTypeDictionaryKeyCallBacks.release;
        _uids = CFDictionaryCreateMutable(NULL, 0, &identity_keys, NULL);
        _classUIDs = [NSMutableDictionary new];
        _stringUIDs = [NSMutableDictionary new];
        _pending = [NSMutableArray new];
        _reserved = [NSMutableIndexSet new];
        _frames = [NSMutableArray new];
        _FinchEncodingFrame *top = [[_FinchEncodingFrame new] autorelease];
        top->dict = [NSMutableDictionary new];
        [_frames addObject:top];
        _format = NSPropertyListBinaryFormat_v1_0;
        _secure = requiresSecureCoding;
    }
    return self;
}

- (instancetype)init { return [self initRequiringSecureCoding:YES]; }

- (instancetype)initForWritingWithMutableData:(NSMutableData *)data
{
    if ((self = [self initRequiringSecureCoding:NO])) _output = [data retain];
    return self;
}

- (void)dealloc
{
    [_objects release];
    if (_uids) CFRelease(_uids);
    [_classUIDs release];
    [_stringUIDs release];
    [_frames release];
    [_pending release];
    [_reserved release];
    [_classNames release];
    [_output release];
    [_encoded release];
    [super dealloc];
}

+ (NSData *)archivedDataWithRootObject:(id)object requiringSecureCoding:(BOOL)requiresSecureCoding error:(NSError **)error
{
    NSKeyedArchiver *a = [[[self alloc] initRequiringSecureCoding:requiresSecureCoding] autorelease];
    @try {
        [a encodeObject:object forKey:NSKeyedArchiveRootObjectKey];
        [a finishEncoding];
    } @catch (NSException *e) {
        if (error) {
            NSString *desc = [NSString stringWithFormat:@"Caught exception during archival: %@", [e reason]];
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderInvalidValueError
                userInfo:@{ NSDebugDescriptionErrorKey: desc }];
        }
        return nil;
    }
    if (error) *error = nil;
    return [a encodedData];
}

+ (NSData *)archivedDataWithRootObject:(id)rootObject
{
    NSKeyedArchiver *a = [[[self alloc] initRequiringSecureCoding:NO] autorelease];
    [a encodeObject:rootObject forKey:NSKeyedArchiveRootObjectKey];
    [a finishEncoding];
    return [a encodedData];
}

+ (BOOL)archiveRootObject:(id)rootObject toFile:(NSString *)path
{
    return [[self archivedDataWithRootObject:rootObject] writeToFile:path atomically:YES];
}

- (BOOL)allowsKeyedCoding { return YES; }
- (BOOL)requiresSecureCoding { return _secure; }
- (void)setRequiresSecureCoding:(BOOL)flag { _secure = flag; }
- (id<NSKeyedArchiverDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSKeyedArchiverDelegate>)delegate { _delegate = delegate; }
- (NSPropertyListFormat)outputFormat { return _format; }
- (void)setOutputFormat:(NSPropertyListFormat)format { _format = format; }
- (unsigned int)systemVersion { return 2000; }
- (NSInteger)versionForClassName:(NSString *)className { return [NSClassFromString(className) version]; }

+ (void)setClassName:(NSString *)codedName forClass:(Class)cls
{
    @synchronized ([NSKeyedArchiver class]) {
        if (!global_class_names) global_class_names = [NSMutableDictionary new];
        if (codedName) [global_class_names setObject:codedName forKey:NSStringFromClass(cls)];
        else [global_class_names removeObjectForKey:NSStringFromClass(cls)];
    }
}

+ (NSString *)classNameForClass:(Class)cls
{
    @synchronized ([NSKeyedArchiver class]) {
        return [[[global_class_names objectForKey:NSStringFromClass(cls)] retain] autorelease];
    }
}

- (void)setClassName:(NSString *)codedName forClass:(Class)cls
{
    if (!_classNames) _classNames = [NSMutableDictionary new];
    if (codedName) [_classNames setObject:codedName forKey:NSStringFromClass(cls)];
    else [_classNames removeObjectForKey:NSStringFromClass(cls)];
}

- (NSString *)classNameForClass:(Class)cls { return [_classNames objectForKey:NSStringFromClass(cls)]; }

- (NSString *)codedNameForClass:(Class)cls
{
    NSString *n = [self classNameForClass:cls];
    if (!n) n = [NSKeyedArchiver classNameForClass:cls];
    return n ? n : NSStringFromClass(cls);
}

- (NSMutableDictionary *)currentDict { return ((_FinchEncodingFrame *)[_frames lastObject])->dict; }

- (void)checkFinished
{
    if (_finished)
        FinchRaise(NSInvalidArgumentException, "*** -[NSKeyedArchiver encodeObject:forKey:]: archive already finished, cannot encode anything more");
}

/* The plist value for a string, number or data stored in place. */
static id
inline_value(id object, Class cls)
{
    if (cls == [NSString class] && [object isKindOfClass:[NSString class]]) return [[object copy] autorelease];
    if (cls == [NSData class] && [object isKindOfClass:[NSData class]]) return [NSData dataWithData:object];
    if (cls == [NSNumber class] && [object isKindOfClass:[NSNumber class]]) {
        if (object == (id)kCFBooleanTrue || object == (id)kCFBooleanFalse) return object;
        const char *t = [object objCType];
        if (*t == 'f' || *t == 'd') return [NSNumber numberWithDouble:[object doubleValue]];
        if (*t == 'Q') return [NSNumber numberWithUnsignedLongLong:[object unsignedLongLongValue]];
        return [NSNumber numberWithLongLong:[object longLongValue]];
    }
    return nil;
}

- (NSUInteger)classUIDFor:(Class)cls
{
    NSString *name = [self codedNameForClass:cls];
    NSNumber *existing = [_classUIDs objectForKey:name];
    if (existing) return [existing unsignedIntegerValue];
    NSMutableArray *chain = [NSMutableArray array];
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (c != cls && !strcmp(class_getName(c), "__NSCFType")) continue;   /* CF's bridge class, not Apple's hierarchy */
        [chain addObject:c == cls ? name : [self codedNameForClass:c]];
    }
    NSArray *fallbacks = [cls classFallbacksForKeyedArchiver];
    if (fallbacks) [chain addObjectsFromArray:fallbacks];
    NSUInteger n = [_objects count];
    [_objects addObject:@{ @"$classname": name, @"$classes": chain }];
    [_classUIDs setObject:@(n) forKey:name];
    return n;
}

/* The UID for an object, encoding it if this is its first appearance. */
- (NSUInteger)referenceFor:(id)object
{
    if (!object) return 0;
    const void *known;
    NSUInteger reservedSlot = NSNotFound;
    if (CFDictionaryGetValueIfPresent(_uids, object, &known)) {
        if (![_reserved containsIndex:(NSUInteger)(uintptr_t)known]) return (NSUInteger)(uintptr_t)known;
        reservedSlot = (NSUInteger)(uintptr_t)known;
        [_reserved removeIndex:reservedSlot];
    }

    id original = object;
    if (_delegate && [_delegate respondsToSelector:@selector(archiver:willEncodeObject:)]) {
        object = [_delegate archiver:self willEncodeObject:object];
        if (!object) return 0;
    }
    id replacement = [object replacementObjectForKeyedArchiver:self];
    if (replacement != object && _delegate && [_delegate respondsToSelector:@selector(archiver:willReplaceObject:withObject:)])
        [_delegate archiver:self willReplaceObject:object withObject:replacement];
    object = replacement;
    if (!object) return 0;
    if (object != original && CFDictionaryGetValueIfPresent(_uids, object, &known)) {
        CFDictionarySetValue(_uids, original, known);
        return (NSUInteger)(uintptr_t)known;
    }

    Class cls = [object classForKeyedArchiver];
    if (_secure && !([cls respondsToSelector:@selector(supportsSecureCoding)] && [(id)cls supportsSecureCoding]) && !inline_value(object, cls))
        FinchRaise(NSInvalidArchiveOperationException,
            "This coder requires that coded objects conform to NSSecureCoding. Object of class '%s' does not.", object_getClassName(object));

    NSUInteger n = reservedSlot != NSNotFound ? reservedSlot : [_objects count];
    CFDictionarySetValue(_uids, original, (const void *)(uintptr_t)n);
    if (object != original) CFDictionarySetValue(_uids, object, (const void *)(uintptr_t)n);

    id value = inline_value(object, cls);
    if ([value isKindOfClass:[NSString class]]) {
        NSNumber *same = [_stringUIDs objectForKey:value];
        if (same) {
            CFDictionarySetValue(_uids, original, (const void *)(uintptr_t)[same unsignedIntegerValue]);
            return [same unsignedIntegerValue];
        }
        [_stringUIDs setObject:@(n) forKey:value];
    }
    if (reservedSlot == NSNotFound) [_objects addObject:[NSNull null]];   /* placeholder until encoded */
    if (value) {
        [_objects replaceObjectAtIndex:n withObject:value];
    } else {
        _FinchEncodingFrame *f = [[_FinchEncodingFrame new] autorelease];
        f->dict = [NSMutableDictionary new];
        [_frames addObject:f];
        [object encodeWithCoder:self];
        [_frames removeLastObject];
        [f->dict setObject:uid([self classUIDFor:cls]) forKey:@"$class"];
        [_objects replaceObjectAtIndex:n withObject:f->dict];
    }
    if (_delegate && [_delegate respondsToSelector:@selector(archiver:didEncodeObject:)]) [_delegate archiver:self didEncodeObject:object];

    return n;
}

- (void)encodeObject:(id)object forKey:(NSString *)key
{
    [self checkFinished];
    NSMutableDictionary *d = [self currentDict];
    [d setObject:uid([self referenceFor:object]) forKey:key];
}

/* Apple's: a conditional object is numbered when first referred to; if it
 * is never encoded outright, the references become $null. */
- (void)encodeConditionalObject:(id)object forKey:(NSString *)key
{
    [self checkFinished];
    NSMutableDictionary *d = [self currentDict];
    const void *known;
    if (!object) {
        [d setObject:uid(0) forKey:key];
        return;
    }
    if (!CFDictionaryGetValueIfPresent(_uids, object, &known)) {
        known = (const void *)(uintptr_t)[_objects count];
        [_objects addObject:@"$null"];
        [_reserved addIndex:(NSUInteger)(uintptr_t)known];
        CFDictionarySetValue(_uids, object, known);
    }
    [d setObject:uid((NSUInteger)(uintptr_t)known) forKey:key];
    [_pending addObject:@[ d, key ]];
}

- (void)encodeBool:(BOOL)value forKey:(NSString *)key { [[self currentDict] setObject:(id)(value ? kCFBooleanTrue : kCFBooleanFalse) forKey:key]; }
- (void)encodeInt:(int)value forKey:(NSString *)key { [[self currentDict] setObject:[NSNumber numberWithLongLong:value] forKey:key]; }
- (void)encodeInt32:(int32_t)value forKey:(NSString *)key { [[self currentDict] setObject:[NSNumber numberWithLongLong:value] forKey:key]; }
- (void)encodeInt64:(int64_t)value forKey:(NSString *)key { [[self currentDict] setObject:[NSNumber numberWithLongLong:value] forKey:key]; }
- (void)encodeInteger:(NSInteger)value forKey:(NSString *)key { [[self currentDict] setObject:[NSNumber numberWithLongLong:value] forKey:key]; }
- (void)encodeFloat:(float)value forKey:(NSString *)key { [[self currentDict] setObject:[NSNumber numberWithFloat:value] forKey:key]; }
- (void)encodeDouble:(double)value forKey:(NSString *)key { [[self currentDict] setObject:[NSNumber numberWithDouble:value] forKey:key]; }
- (void)encodeBytes:(const uint8_t *)bytes length:(NSUInteger)length forKey:(NSString *)key
{
    [[self currentDict] setObject:[NSData dataWithBytes:bytes length:length] forKey:key];
}

- (void)_finchEncodePlist:(id)value forKey:(NSString *)key { [[self currentDict] setObject:value forKey:key]; }

- (void)_finchEncodeArrayOfObjects:(NSArray *)objects forKey:(NSString *)key
{
    NSMutableDictionary *d = [self currentDict];
    NSMutableArray *refs = [NSMutableArray arrayWithCapacity:[objects count]];
    for (id o in objects) [refs addObject:uid([self referenceFor:o])];
    [d setObject:refs forKey:key];
}

/* MARK: The unkeyed API, under "$n" */

- (NSString *)nextKey
{
    _FinchEncodingFrame *f = [_frames lastObject];
    return [NSString stringWithFormat:@"$%lu", (unsigned long)f->next++];
}

- (void)encodeValueOfObjCType:(const char *)type at:(const void *)addr
{
    while (*type && strchr("rnNoORV", *type)) type++;
    switch (*type) {
    case '@': case '#': [self encodeObject:*(id *)addr forKey:[self nextKey]]; return;
    case '*': {
        const char *s = *(const char **)addr;
        [self encodeObject:s ? [NSString stringWithUTF8String:s] : nil forKey:[self nextKey]];
        return;
    }
    case ':': {
        SEL s = *(SEL *)addr;
        [self encodeObject:s ? NSStringFromSelector(s) : nil forKey:[self nextKey]];
        return;
    }
    case 'c': [self encodeInt64:*(char *)addr forKey:[self nextKey]]; return;
    case 'C': [self encodeInt64:*(unsigned char *)addr forKey:[self nextKey]]; return;
    case 'B': [self encodeBool:*(bool *)addr forKey:[self nextKey]]; return;
    case 's': [self encodeInt64:*(short *)addr forKey:[self nextKey]]; return;
    case 'S': [self encodeInt64:*(unsigned short *)addr forKey:[self nextKey]]; return;
    case 'i': [self encodeInt64:*(int *)addr forKey:[self nextKey]]; return;
    case 'I': [self encodeInt64:*(unsigned int *)addr forKey:[self nextKey]]; return;
    case 'l': case 'q': [self encodeInt64:*(long long *)addr forKey:[self nextKey]]; return;
    case 'L': case 'Q': [self encodeInt64:(int64_t)*(unsigned long long *)addr forKey:[self nextKey]]; return;
    case 'f': [self encodeFloat:*(float *)addr forKey:[self nextKey]]; return;
    case 'd': [self encodeDouble:*(double *)addr forKey:[self nextKey]]; return;
    case '[': {
        char *end;
        unsigned long count = strtoul(type + 1, &end, 10);
        char elem[64];
        size_t len = strlen(end);
        snprintf(elem, sizeof(elem), "%.*s", (int)(len ? len - 1 : 0), end);
        [self encodeArrayOfObjCType:elem count:count at:addr];
        return;
    }
    case '{':
        FinchRaise(NSInvalidArgumentException, "*** -[NSKeyedArchiver encodeValueOfObjCType:at:]: this archiver cannot encode structs");
    default:
        FinchRaise(NSInvalidArgumentException, "*** -[NSKeyedArchiver encodeValueOfObjCType:at:]: unknown type encoding ('%c')", *type);
    }
}

- (void)encodeArrayOfObjCType:(const char *)type count:(NSUInteger)count at:(const void *)array
{
    _NSKeyedCoderOldStyleArray *a = [[_NSKeyedCoderOldStyleArray new] autorelease];
    a->_type = *type;
    a->_count = count;
    NSGetSizeAndAlignment(type, &a->_size, NULL);
    a->_bytes = (void *)array;
    [self encodeObject:a forKey:[self nextKey]];
}

- (void)encodeBytes:(const void *)byteaddr length:(NSUInteger)length
{
    [[self currentDict] setObject:[NSData dataWithBytes:byteaddr length:length] forKey:[self nextKey]];
}

- (void)encodeDataObject:(NSData *)data { [self encodeObject:data forKey:[self nextKey]]; }
- (void)encodeObject:(id)object { [self encodeObject:object forKey:[self nextKey]]; }
- (void)encodeConditionalObject:(id)object { [self encodeConditionalObject:object forKey:[self nextKey]]; }

/* MARK: Finishing */

- (void)finishEncoding
{
    if (_finished) return;
    if (_delegate && [_delegate respondsToSelector:@selector(archiverWillFinish:)]) [_delegate archiverWillFinish:self];
    _finished = YES;
    for (NSArray *p in _pending) {
        NSMutableDictionary *d = [p objectAtIndex:0];
        id ref = [d objectForKey:[p objectAtIndex:1]];
        if ([_reserved containsIndex:_CFKeyedArchiverUIDGetValue((CFKeyedArchiverUIDRef)ref)]) [d setObject:uid(0) forKey:[p objectAtIndex:1]];
    }
    [_pending removeAllObjects];
    NSDictionary *plist = @{
        @"$archiver": @"NSKeyedArchiver",
        @"$version": @100000,
        @"$top": ((_FinchEncodingFrame *)[_frames objectAtIndex:0])->dict,
        @"$objects": _objects,
    };
    CFErrorRef err = NULL;
    CFDataRef data = CFPropertyListCreateData(NULL, (CFPropertyListRef)plist, (CFPropertyListFormat)_format, 0, &err);
    if (err) CFRelease(err);
    _encoded = data ? (NSData *)data : [[NSData alloc] init];
    if (_output) [_output setData:_encoded];
    if (_delegate && [_delegate respondsToSelector:@selector(archiverDidFinish:)]) [_delegate archiverDidFinish:self];
}

- (NSData *)encodedData
{
    if (!_finished) [self finishEncoding];
    return _encoded;
}

@end

/* MARK: - NSKeyedUnarchiver */

/* One object being decoded: its dictionary, its "$n" counter, and the
 * classes its contents may be. */
@interface _FinchDecodingFrame : NSObject {
@public
    NSDictionary *dict;
    NSUInteger next;
    NSSet *allowed;
}
@end
@implementation _FinchDecodingFrame
- (void)dealloc { [dict release]; [allowed release]; [super dealloc]; }
@end

@implementation NSKeyedUnarchiver {
    NSArray *_objects;
    CFMutableDictionaryRef _decoded;       /* UID index -> object (retained) */
    NSMutableArray *_frames;
    NSMutableDictionary *_classes;
    id<NSKeyedUnarchiverDelegate> _delegate;
    NSError *_error;
    NSDecodingFailurePolicy _policy;
    BOOL _secure;
}

static NSError *
corrupt(NSString *debug)
{
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError
        userInfo:@{ NSDebugDescriptionErrorKey: debug }];
}

- (BOOL)loadArchive:(NSData *)data error:(NSError **)error
{
    id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    NSArray *objects = [plist isKindOfClass:[NSDictionary class]] ? [plist objectForKey:@"$objects"] : nil;
    NSDictionary *top = [plist isKindOfClass:[NSDictionary class]] ? [plist objectForKey:@"$top"] : nil;
    if (![objects isKindOfClass:[NSArray class]] || ![top isKindOfClass:[NSDictionary class]]) {
        if (error) *error = corrupt(@"data is not in a format that NSKeyedUnarchiver can read");
        return NO;
    }
    _objects = [objects retain];
    _FinchDecodingFrame *f = [[_FinchDecodingFrame new] autorelease];
    f->dict = [top retain];
    [_frames addObject:f];
    return YES;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _decoded = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
        _frames = [NSMutableArray new];
        _objects = [[NSArray alloc] initWithObjects:@"$null", nil];
        _FinchDecodingFrame *f = [[_FinchDecodingFrame new] autorelease];
        f->dict = [NSDictionary new];
        [_frames addObject:f];
        _secure = YES;
        _policy = NSDecodingFailurePolicySetErrorAndReturn;
    }
    return self;
}

- (instancetype)initForReadingFromData:(NSData *)data error:(NSError **)error
{
    if ((self = [self init])) {
        [_frames removeAllObjects];
        [_objects release];
        _objects = nil;
        if (![self loadArchive:data error:error]) { [self release]; return nil; }
        if (error) *error = nil;
    }
    return self;
}

- (instancetype)initForReadingWithData:(NSData *)data
{
    if ((self = [self init])) {
        [_frames removeAllObjects];
        [_objects release];
        _objects = nil;
        _secure = NO;
        _policy = NSDecodingFailurePolicyRaiseException;
        if (![self loadArchive:data error:NULL]) {
            [self release];
            FinchRaise(NSInvalidArgumentException, "*** -[NSKeyedUnarchiver initForReadingWithData:]: incomprehensible archive (0x%lx, 0x%lx, 0x%lx, 0x%lx, 0x%lx, 0x%lx, 0x%lx, 0x%lx)",
                0ul, 0ul, 0ul, 0ul, 0ul, 0ul, 0ul, 0ul);
        }
    }
    return self;
}

- (void)dealloc
{
    [_objects release];
    if (_decoded) CFRelease(_decoded);
    [_frames release];
    [_classes release];
    [_error release];
    [super dealloc];
}

static id
decode_root(NSData *data, NSSet *classes, BOOL secure, NSError **error)
{
    NSError *e = nil;
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&e] autorelease];
    if (!u) { if (error) *error = e; return nil; }
    u.requiresSecureCoding = secure;
    id o = classes ? [u decodeObjectOfClasses:classes forKey:NSKeyedArchiveRootObjectKey] : [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [u finishDecoding];
    if (error) *error = o ? nil : [u error];
    return o;
}

+ (id)unarchivedObjectOfClass:(Class)cls fromData:(NSData *)data error:(NSError **)error
{
    return decode_root(data, [NSSet setWithObject:cls], YES, error);
}

+ (id)unarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error
{
    return decode_root(data, classes, YES, error);
}

+ (NSArray *)unarchivedArrayOfObjectsOfClass:(Class)cls fromData:(NSData *)data error:(NSError **)error
{
    return [self unarchivedArrayOfObjectsOfClasses:[NSSet setWithObject:cls] fromData:data error:error];
}

+ (NSArray *)unarchivedArrayOfObjectsOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error
{
    NSError *e = nil;
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&e] autorelease];
    if (!u) { if (error) *error = e; return nil; }
    NSArray *a = [u decodeArrayOfObjectsOfClasses:classes forKey:NSKeyedArchiveRootObjectKey];
    [u finishDecoding];
    if (error) *error = a ? nil : [u error];
    return a;
}

+ (NSDictionary *)unarchivedDictionaryWithKeysOfClass:(Class)keyCls objectsOfClass:(Class)valueCls fromData:(NSData *)data error:(NSError **)error
{
    return [self unarchivedDictionaryWithKeysOfClasses:[NSSet setWithObject:keyCls] objectsOfClasses:[NSSet setWithObject:valueCls] fromData:data error:error];
}

+ (NSDictionary *)unarchivedDictionaryWithKeysOfClasses:(NSSet *)keyClasses objectsOfClasses:(NSSet *)valueClasses fromData:(NSData *)data error:(NSError **)error
{
    NSError *e = nil;
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&e] autorelease];
    if (!u) { if (error) *error = e; return nil; }
    NSDictionary *d = [u decodeDictionaryWithKeysOfClasses:keyClasses objectsOfClasses:valueClasses forKey:NSKeyedArchiveRootObjectKey];
    [u finishDecoding];
    if (error) *error = d ? nil : [u error];
    return d;
}

+ (id)unarchiveObjectWithData:(NSData *)data
{
    NSKeyedUnarchiver *u = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease];
    if (!u) return nil;
    u.requiresSecureCoding = NO;
    u.decodingFailurePolicy = NSDecodingFailurePolicyRaiseException;
    id o = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [u finishDecoding];
    return o;
}

+ (id)unarchiveTopLevelObjectWithData:(NSData *)data error:(NSError **)error
{
    return decode_root(data, nil, NO, error);
}

+ (id)unarchiveObjectWithFile:(NSString *)path
{
    NSData *d = [NSData dataWithContentsOfFile:path];
    return d ? [self unarchiveObjectWithData:d] : nil;
}

- (BOOL)allowsKeyedCoding { return YES; }
- (BOOL)requiresSecureCoding { return _secure; }
- (void)setRequiresSecureCoding:(BOOL)flag { _secure = flag; }
- (NSDecodingFailurePolicy)decodingFailurePolicy { return _policy; }
- (void)setDecodingFailurePolicy:(NSDecodingFailurePolicy)policy { _policy = policy; }
- (NSError *)error { return _error; }
- (id<NSKeyedUnarchiverDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSKeyedUnarchiverDelegate>)delegate { _delegate = delegate; }
- (unsigned int)systemVersion { return 2000; }
- (NSInteger)versionForClassName:(NSString *)className { return [NSClassFromString(className) version]; }
- (NSSet *)allowedClasses { return ((_FinchDecodingFrame *)[_frames lastObject])->allowed; }

- (void)finishDecoding
{
    if (_delegate && [_delegate respondsToSelector:@selector(unarchiverWillFinish:)]) [_delegate unarchiverWillFinish:self];
    if (_delegate && [_delegate respondsToSelector:@selector(unarchiverDidFinish:)]) [_delegate unarchiverDidFinish:self];
}

+ (void)setClass:(Class)cls forClassName:(NSString *)codedName
{
    @synchronized ([NSKeyedUnarchiver class]) {
        if (!global_classes) global_classes = [NSMutableDictionary new];
        if (cls) [global_classes setObject:cls forKey:codedName];
        else [global_classes removeObjectForKey:codedName];
    }
}

+ (Class)classForClassName:(NSString *)codedName
{
    @synchronized ([NSKeyedUnarchiver class]) {
        return [global_classes objectForKey:codedName];
    }
}

- (void)setClass:(Class)cls forClassName:(NSString *)codedName
{
    if (!_classes) _classes = [NSMutableDictionary new];
    if (cls) [_classes setObject:cls forKey:codedName];
    else [_classes removeObjectForKey:codedName];
}

- (Class)classForClassName:(NSString *)codedName { return [_classes objectForKey:codedName]; }

- (void)failWithError:(NSError *)error
{
    if (_policy == NSDecodingFailurePolicyRaiseException) {
        NSString *reason = [[error userInfo] objectForKey:NSDebugDescriptionErrorKey];
        FinchRaise(NSInvalidUnarchiveOperationException, "%s", [(reason ? reason : [error description]) UTF8String]);
    }
    if (!_error) _error = [error retain];
}

- (NSDictionary *)currentDict { return ((_FinchDecodingFrame *)[_frames lastObject])->dict; }

- (BOOL)containsValueForKey:(NSString *)key { return [[self currentDict] objectForKey:key] != nil; }

static BOOL
class_allowed(Class cls, NSSet *allowed)
{
    for (Class c in allowed) if ([cls isSubclassOfClass:c]) return YES;
    return NO;
}

- (BOOL)checkClass:(Class)cls forKey:(NSString *)key allowed:(NSSet *)allowed
{
    if (!_secure) return YES;
    if (allowed && class_allowed(cls, allowed) &&
        (([cls respondsToSelector:@selector(supportsSecureCoding)] && [(id)cls supportsSecureCoding]) ||
         cls == [NSString class] || cls == [NSNumber class] || cls == [NSData class]))
        return YES;
    NSMutableArray *names = [NSMutableArray array];
    for (Class c in allowed) [names addObject:[NSString stringWithFormat:@"'%@'", NSStringFromClass(c)]];
    [names sortUsingSelector:@selector(compare:)];
    [self failWithError:corrupt([NSString stringWithFormat:@"value for key '%@' was of unexpected class '%@'. Allowed classes are '{(%@)}'.",
        key, NSStringFromClass(cls), [names componentsJoinedByString:@", "]])];
    return NO;
}

/* The class an archived class description names: this unarchiver's map,
 * the global map, the class itself, then its $classes in order. */
- (Class)classForDescription:(NSDictionary *)desc
{
    NSString *name = [desc objectForKey:@"$classname"];
    NSArray *names = [desc objectForKey:@"$classes"];
    if (![names isKindOfClass:[NSArray class]]) names = name ? @[ name ] : @[];
    for (NSString *n in names) {
        Class c = [self classForClassName:n];
        if (!c) c = [NSKeyedUnarchiver classForClassName:n];
        if (!c) c = NSClassFromString(n);
        if (c) return c;
    }
    if (_delegate && [_delegate respondsToSelector:@selector(unarchiver:cannotDecodeObjectOfClassName:originalClasses:)])
        return [_delegate unarchiver:self cannotDecodeObjectOfClassName:name originalClasses:names];
    return Nil;
}

/* The object a value in a dictionary stands for: a reference, or a plist
 * value stored in place. */
- (id)objectForValue:(id)value key:(NSString *)key allowed:(NSSet *)allowed
{
    if (_error) return nil;
    if (!value) return nil;
    if (!is_uid(value)) return value;
    NSUInteger n = _CFKeyedArchiverUIDGetValue((CFKeyedArchiverUIDRef)value);
    if (n == 0) return nil;
    if (n >= [_objects count]) {
        [self failWithError:corrupt(@"Object reference out of range")];
        return nil;
    }
    id cached = (id)CFDictionaryGetValue(_decoded, (const void *)(uintptr_t)n);
    if (cached) {
        id stored = [_objects objectAtIndex:n];
        BOOL inPlace = !([stored isKindOfClass:[NSDictionary class]] && is_uid([stored objectForKey:@"$class"]));
        if (_secure && !inPlace && ![self checkClass:[cached classForCoder] forKey:key allowed:allowed]) return nil;
        return cached;
    }

    id stored = [_objects objectAtIndex:n];
    NSDictionary *classRef = [stored isKindOfClass:[NSDictionary class]] ? [stored objectForKey:@"$class"] : nil;
    if (!is_uid(classRef)) {
        /* A string, number or data in place: allowed whatever the classes
         * asked for, as Apple's are. */
        CFDictionarySetValue(_decoded, (const void *)(uintptr_t)n, stored);
        return stored;
    }
    NSUInteger cn = _CFKeyedArchiverUIDGetValue((CFKeyedArchiverUIDRef)classRef);
    NSDictionary *desc = cn < [_objects count] ? [_objects objectAtIndex:cn] : nil;
    Class cls = [desc isKindOfClass:[NSDictionary class]] ? [self classForDescription:desc] : Nil;
    if (!cls) {
        NSString *name = [desc isKindOfClass:[NSDictionary class]] ? [desc objectForKey:@"$classname"] : @"?";
        NSString *msg = [NSString stringWithFormat:@"*** -[NSKeyedUnarchiver decodeObjectForKey:]: cannot decode object of class (%@) for key (%@); the class may be defined in source code or a library that is not linked", name, key];
        if (_policy == NSDecodingFailurePolicyRaiseException) FinchRaise(NSInvalidUnarchiveOperationException, "%s", [msg UTF8String]);
        [self failWithError:corrupt(msg)];
        return nil;
    }
    if (![self checkClass:cls forKey:key allowed:allowed]) return nil;
    cls = [cls classForKeyedUnarchiver];

    _FinchDecodingFrame *f = [[_FinchDecodingFrame new] autorelease];
    f->dict = [stored retain];
    f->allowed = [allowed retain];
    id obj = [cls allocWithZone:NULL];
    CFDictionarySetValue(_decoded, (const void *)(uintptr_t)n, obj);   /* for references back to it while it's decoded */
    [_frames addObject:f];
    id result;
    @try {
        result = [obj initWithCoder:self];
    } @finally {
        [_frames removeLastObject];
    }
    if (!result) {
        CFDictionaryRemoveValue(_decoded, (const void *)(uintptr_t)n);
        return nil;
    }
    id awake = [result awakeAfterUsingCoder:self];
    if (awake != result) {
        if (_delegate && [_delegate respondsToSelector:@selector(unarchiver:willReplaceObject:withObject:)])
            [_delegate unarchiver:self willReplaceObject:result withObject:awake];
        [awake retain];
        [result release];
        result = awake;
    }
    if (_delegate && [_delegate respondsToSelector:@selector(unarchiver:didDecodeObject:)]) {
        id d = [_delegate unarchiver:self didDecodeObject:result];
        if (d != result) result = d;
    }
    CFDictionarySetValue(_decoded, (const void *)(uintptr_t)n, result);
    [result release];   /* -initWithCoder: returned it +1; the table holds it */
    return result;
}

- (id)decodeObjectOfClasses:(NSSet *)classes forKey:(NSString *)key
{
    id value = [[self currentDict] objectForKey:key];
    return [[[self objectForValue:value key:key allowed:classes] retain] autorelease];
}

- (id)decodeObjectForKey:(NSString *)key
{
    return [self decodeObjectOfClasses:[self allowedClasses] forKey:key];
}

- (NSArray *)_finchDecodeArrayOfObjectsForKey:(NSString *)key
{
    id refs = [[self currentDict] objectForKey:key];
    if (![refs isKindOfClass:[NSArray class]]) return is_uid(refs) ? [self decodeObjectForKey:key] : nil;
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:[refs count]];
    NSSet *allowed = [self allowedClasses];
    for (id r in refs) {
        id o = [self objectForValue:r key:key allowed:allowed];
        if (!o) return nil;
        [a addObject:o];
    }
    return a;
}

static NSNumber *
number_for(NSKeyedUnarchiver *self, NSString *key)
{
    id v = [[self currentDict] objectForKey:key];
    return [v isKindOfClass:[NSNumber class]] ? v : nil;
}

- (BOOL)decodeBoolForKey:(NSString *)key { return [number_for(self, key) boolValue]; }
- (int64_t)decodeInt64ForKey:(NSString *)key { return [number_for(self, key) longLongValue]; }
- (double)decodeDoubleForKey:(NSString *)key { return [number_for(self, key) doubleValue]; }
- (float)decodeFloatForKey:(NSString *)key { return [number_for(self, key) floatValue]; }

- (int)decodeIntForKey:(NSString *)key
{
    int64_t v = [self decodeInt64ForKey:key];
    if (v < INT_MIN || v > INT_MAX)
        FinchRaise(NSRangeException, "*** -[NSKeyedUnarchiver decodeIntForKey:]: value (%lld) for key (%s) too large to fit in 32-bit integer",
            (long long)v, [key UTF8String]);
    return (int)v;
}

- (int32_t)decodeInt32ForKey:(NSString *)key { return [self decodeIntForKey:key]; }

- (const uint8_t *)decodeBytesForKey:(NSString *)key returnedLength:(NSUInteger *)lengthp
{
    id v = [[self currentDict] objectForKey:key];
    if (is_uid(v)) v = [self objectForValue:v key:key allowed:nil];
    if (![v isKindOfClass:[NSData class]]) { if (lengthp) *lengthp = 0; return NULL; }
    if (lengthp) *lengthp = [v length];
    return [v bytes];
}

/* MARK: The unkeyed API, from "$n" */

- (NSString *)nextKey
{
    _FinchDecodingFrame *f = [_frames lastObject];
    return [NSString stringWithFormat:@"$%lu", (unsigned long)f->next++];
}

- (void)decodeValueOfObjCType:(const char *)type at:(void *)data size:(NSUInteger)size
{
    while (*type && strchr("rnNoORV", *type)) type++;
    NSString *key;
    switch (*type) {
    case '@': case '#': *(id *)data = [[self decodeObjectForKey:[self nextKey]] retain]; return;
    case '*': {
        NSString *s = [self decodeObjectForKey:[self nextKey]];
        *(const char **)data = s ? [[NSData dataWithBytes:[s UTF8String] length:strlen([s UTF8String]) + 1] bytes] : NULL;
        return;
    }
    case ':': {
        NSString *s = [self decodeObjectForKey:[self nextKey]];
        *(SEL *)data = s ? NSSelectorFromString(s) : NULL;
        return;
    }
    case '[': {
        char *end;
        unsigned long count = strtoul(type + 1, &end, 10);
        char elem[64];
        size_t len = strlen(end);
        snprintf(elem, sizeof(elem), "%.*s", (int)(len ? len - 1 : 0), end);
        [self decodeArrayOfObjCType:elem count:count at:data];
        return;
    }
    case '{':
        FinchRaise(NSInvalidArgumentException, "*** -[NSKeyedUnarchiver decodeValueOfObjCType:at:]: this unarchiver cannot decode structs");
    }
    key = [self nextKey];
    NSNumber *n = number_for(self, key);
    switch (*type) {
    case 'c': *(char *)data = (char)[n longLongValue]; break;
    case 'C': *(unsigned char *)data = (unsigned char)[n longLongValue]; break;
    case 'B': *(bool *)data = [n boolValue]; break;
    case 's': *(short *)data = (short)[n longLongValue]; break;
    case 'S': *(unsigned short *)data = (unsigned short)[n longLongValue]; break;
    case 'i': *(int *)data = (int)[n longLongValue]; break;
    case 'I': *(unsigned int *)data = (unsigned int)[n longLongValue]; break;
    case 'l': case 'q': *(long long *)data = [n longLongValue]; break;
    case 'L': case 'Q': *(unsigned long long *)data = [n unsignedLongLongValue]; break;
    case 'f': *(float *)data = [n floatValue]; break;
    case 'd': *(double *)data = [n doubleValue]; break;
    default:
        FinchRaise(NSInvalidArgumentException, "*** -[NSKeyedUnarchiver decodeValueOfObjCType:at:]: unknown type encoding ('%c')", *type);
    }
}

- (void)decodeArrayOfObjCType:(const char *)itemType count:(NSUInteger)count at:(void *)array
{
    _NSKeyedCoderOldStyleArray *a = [self decodeObjectForKey:[self nextKey]];
    if (![a isKindOfClass:[_NSKeyedCoderOldStyleArray class]] || a->_count != count || a->_type != *itemType)
        FinchRaise(NSInvalidUnarchiveOperationException, "*** -[NSKeyedUnarchiver decodeArrayOfObjCType:count:at:]: mismatch in count or type of array");
    memcpy(array, a->_bytes, count * a->_size);
}

- (void *)decodeBytesWithReturnedLength:(NSUInteger *)lengthp
{
    NSData *d = [[self currentDict] objectForKey:[self nextKey]];
    if (![d isKindOfClass:[NSData class]]) { if (lengthp) *lengthp = 0; return NULL; }
    if (lengthp) *lengthp = [d length];
    return (void *)[d bytes];
}

- (NSData *)decodeDataObject { return [self decodeObjectForKey:[self nextKey]]; }
- (id)decodeObject { return [self decodeObjectForKey:[self nextKey]]; }

@end

/* MARK: - Old-style arrays */

@implementation _NSKeyedCoderOldStyleArray

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:(int)_count forKey:@"NS.count"];
    [coder encodeInt:(int)_size forKey:@"NS.size"];
    [coder encodeInt:_type forKey:@"NS.type"];
    char type[2] = { _type, 0 };
    for (NSUInteger i = 0; i < _count; i++) [coder encodeValueOfObjCType:type at:(char *)_bytes + i * _size];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _count = (NSUInteger)[coder decodeIntForKey:@"NS.count"];
        _size = (NSUInteger)[coder decodeIntForKey:@"NS.size"];
        _type = (char)[coder decodeIntForKey:@"NS.type"];
        if (_size > 16 || _count > (1u << 24)) { [self release]; return nil; }
        _bytes = calloc(_count ? _count : 1, _size ? _size : 1);
        _owned = YES;
        char type[2] = { _type, 0 };
        for (NSUInteger i = 0; i < _count; i++) [coder decodeValueOfObjCType:type at:(char *)_bytes + i * _size size:_size];
    }
    return self;
}

- (void)dealloc
{
    if (_owned) free(_bytes);
    [super dealloc];
}

@end
