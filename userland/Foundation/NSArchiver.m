/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSArchiver and NSUnarchiver: the non-keyed archives in NeXT's typedstream
 * format, byte for byte as Apple's write them (docs/design/FOUNDATION.md,
 * "Typedstream"). Old Stickies databases, pasteboard attributed strings and
 * nibs from before keyed archiving are in it.
 *
 * The stream: a version byte (4), the signature as a counted string
 * ("streamtyped" little-endian, NeXT's "typedstream" big-endian), the system
 * version (1000), then groups: each call's type string, then its values.
 *
 *   integers   a byte for -110..127; else 0x81 + 2 bytes, 0x82 + 4, 0x87 + 8
 *   floats     as an integer when integral, else 0x83 + the raw float/double
 *   0x84       a new entry (shared string, object, class or C string)
 *   0x85       nil;  0x86 the end of an object
 *   0x92 + n   a reference to entry n (2- and 4-byte forms past 127)
 *
 * Two tables of references: shared strings (type strings, class names,
 * selectors, C strings' characters) and objects (objects, classes and C
 * string pointers, numbered as they are first written). An object is 0x84,
 * its class (0x84, name, version, superclass ..., 0x85), its own groups and
 * 0x86. chars, BOOLs and char arrays are raw bytes; arrays and structs are
 * their elements in order with no types of their own.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

enum {
    TAG_INT16 = 0x81,
    TAG_INT32 = 0x82,
    TAG_FLOAT = 0x83,
    TAG_NEW = 0x84,
    TAG_NIL = 0x85,
    TAG_END = 0x86,
    TAG_INT64 = 0x87,
};
#define REFERENCE_BASE (-110)   /* 0x92: entry 0 */
#define STREAMER_VERSION 4
#define SYSTEM_VERSION 1000

static NSString *const Inconsistency = @"NSArchiverArchiveInconsistency";

static NSMutableDictionary *global_encode_names;   /* true class name -> archived */
static NSMutableDictionary *global_decode_names;   /* archived -> class name */

static const char *
skip_qualifiers(const char *t)
{
    while (*t && strchr("rnNoORVA", *t)) t++;
    return t;
}

/* The end of the single type at `t`. */
static const char *
type_end(const char *t)
{
    t = skip_qualifiers(t);
    switch (*t) {
    case '[': {
        int depth = 0;
        do {
            if (*t == '[') depth++;
            else if (*t == ']') depth--;
            t++;
        } while (depth > 0 && *t);
        return t;
    }
    case '{': case '(': {
        char open = *t, close = open == '{' ? '}' : ')';
        int depth = 0;
        do {
            if (*t == open) depth++;
            else if (*t == close) depth--;
            t++;
        } while (depth > 0 && *t);
        return t;
    }
    case '^':
        return type_end(t + 1);
    case '@':
        t++;
        if (*t == '"') { t = strchr(t + 1, '"'); return t ? t + 1 : t; }
        if (*t == '?') t++;
        return t;
    case '\0':
        return t;
    default:
        t++;
        while (*t >= '0' && *t <= '9') t++;   /* bit-field widths */
        return t;
    }
}

static NSUInteger
type_size(const char *t, NSUInteger *align)
{
    NSUInteger size = 0, a = 1;
    NSGetSizeAndAlignment(t, &size, &a);
    if (align) *align = a ? a : 1;
    return size;
}

/* MARK: - NSArchiver */

@interface NSArchiver () {
    NSMutableData *_data;
    NSMapTable *_strings;        /* NSData of the bytes -> index */
    NSUInteger _stringCount;
    NSMapTable *_objects;        /* object, class or C string pointer -> index */
    NSUInteger _objectCount;
    NSMutableDictionary *_names; /* this archiver's class name map */
    NSMapTable *_replacements;
    NSHashTable *_unconditional; /* the root pass's unconditionally encoded objects */
    BOOL _inRoot, _noting;
}
@end

@implementation NSArchiver

+ (void)load
{
    /* Apple's string classes are at version 1 in archives */
    class_setVersion(objc_getClass("NSString"), 1);
    class_setVersion(objc_getClass("NSMutableString"), 1);
}

+ (NSData *)archivedDataWithRootObject:(id)rootObject
{
    NSMutableData *d = [NSMutableData data];
    NSArchiver *a = [[self alloc] initForWritingWithMutableData:d];
    [a encodeRootObject:rootObject];
    [a release];
    return d;
}

+ (BOOL)archiveRootObject:(id)rootObject toFile:(NSString *)path
{
    return [[self archivedDataWithRootObject:rootObject] writeToFile:path atomically:YES];
}

- (instancetype)initForWritingWithMutableData:(NSMutableData *)data
{
    self = [super init];
    if (self) {
        _data = [data retain];
        [self _reset];
        [self _writeHeader];
    }
    return self;
}

- (instancetype)init
{
    return [self initForWritingWithMutableData:[NSMutableData data]];
}

- (void)dealloc
{
    [_data release];
    [_strings release];
    [_objects release];
    [_names release];
    [_replacements release];
    [_unconditional release];
    [super dealloc];
}

- (void)_reset
{
    [_strings release];
    [_objects release];
    _strings = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsObjectPersonality | NSPointerFunctionsStrongMemory
                                         valueOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsIntegerPersonality capacity:0];
    _objects = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                         valueOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsIntegerPersonality capacity:0];
    _stringCount = _objectCount = 0;
}

- (NSMutableData *)archiverData { return _data; }

/* MARK: Writing */

- (void)_byte:(uint8_t)b { if (!_noting) [_data appendBytes:&b length:1]; }
- (void)_bytes:(const void *)p length:(NSUInteger)n { if (!_noting && n) [_data appendBytes:p length:n]; }

- (void)_int:(int64_t)v
{
    if (v >= REFERENCE_BASE && v <= 127) {
        [self _byte:(uint8_t)(int8_t)v];
    } else if (v >= INT16_MIN && v <= INT16_MAX) {
        int16_t s = OSSwapHostToLittleInt16((int16_t)v);
        [self _byte:TAG_INT16];
        [self _bytes:&s length:2];
    } else if (v >= INT32_MIN && v <= INT32_MAX) {
        int32_t s = OSSwapHostToLittleInt32((int32_t)v);
        [self _byte:TAG_INT32];
        [self _bytes:&s length:4];
    } else {
        int64_t s = OSSwapHostToLittleInt64(v);
        [self _byte:TAG_INT64];
        [self _bytes:&s length:8];
    }
}

- (void)_reference:(NSUInteger)index { [self _int:(int64_t)index + REFERENCE_BASE]; }

- (void)_unsharedString:(const char *)s length:(NSUInteger)n
{
    [self _int:(int64_t)n];
    [self _bytes:s length:n];
}

- (void)_sharedString:(const char *)s length:(NSUInteger)n
{
    if (!s) { [self _byte:TAG_NIL]; return; }
    NSData *key = [NSData dataWithBytes:s length:n];
    void *found = NSMapGet(_strings, key);
    if (found) { [self _reference:(NSUInteger)found - 1]; return; }
    NSMapInsert(_strings, key, (void *)(++_stringCount));
    [self _byte:TAG_NEW];
    [self _unsharedString:s length:n];
}

- (void)_sharedCString:(const char *)s { [self _sharedString:s length:s ? strlen(s) : 0]; }

- (void)_writeHeader
{
    [self _byte:STREAMER_VERSION];
    [self _unsharedString:"streamtyped" length:11];
    [self _int:SYSTEM_VERSION];
}

/* An entry in the object table: its reference if written already, else
 * TAG_NEW and YES (the caller writes it). */
- (BOOL)_newObjectEntry:(const void *)p
{
    void *found = NSMapGet(_objects, p);
    if (found) { [self _reference:(NSUInteger)found - 1]; return NO; }
    NSMapInsert(_objects, p, (void *)(++_objectCount));
    [self _byte:TAG_NEW];
    return YES;
}

- (void)_class:(Class)cls
{
    if (!cls) { [self _byte:TAG_NIL]; return; }
    if (![self _newObjectEntry:(__bridge const void *)cls]) return;
    NSString *name = [self classNameEncodedForTrueClassName:NSStringFromClass(cls)];
    [self _sharedCString:[name UTF8String]];
    [self _int:class_getVersion(cls)];
    [self _class:class_getSuperclass(cls)];
}

- (void)_object:(id)object
{
    id original = object;
    id replaced = _replacements ? NSMapGet(_replacements, (__bridge void *)object) : nil;
    if (replaced) object = replaced;
    if (object) object = [object replacementObjectForArchiver:self];
    if (!object) { [self _byte:TAG_NIL]; return; }
    void *found = NSMapGet(_objects, (__bridge void *)original);
    if (!found && object != original) found = NSMapGet(_objects, (__bridge void *)object);
    if (found) { [self _reference:(NSUInteger)found - 1]; return; }
    NSMapInsert(_objects, (__bridge void *)original, (void *)(++_objectCount));
    if (object != original) NSMapInsert(_objects, (__bridge void *)object, (void *)_objectCount);
    if (_noting) [_unconditional addObject:object];
    [self _byte:TAG_NEW];
    Class cls = [object classForArchiver];
    if (!cls) cls = [object class];
    [self _class:cls];
    [object encodeWithCoder:self];
    [self _byte:TAG_END];
}

/* The value of the single type at `t`, at `p`; returns the end of the type. */
- (const char *)_value:(const char *)type at:(const void *)p
{
    const char *t = skip_qualifiers(type);
    switch (*t) {
    case 'c': case 'C': case 'B':
        [self _bytes:p length:1];
        break;
    case 's': case 'S':
        [self _int:*(const int16_t *)p];
        break;
    case 'i': case 'I': case 'l': case 'L':
        [self _int:*(const int32_t *)p];
        break;
    case 'q': case 'Q':
        [self _int:*(const int64_t *)p];
        break;
    case 'f': {
        float f = *(const float *)p;
        if (f == (float)(int32_t)f && f >= -2147483648.0f && f < 2147483648.0f && !(f == 0 && signbit(f))) {
            [self _int:(int32_t)f];
        } else {
            uint32_t bits;
            memcpy(&bits, &f, 4);
            bits = OSSwapHostToLittleInt32(bits);
            [self _byte:TAG_FLOAT];
            [self _bytes:&bits length:4];
        }
        break;
    }
    case 'd': {
        double d = *(const double *)p;
        if (d >= -9.2e18 && d <= 9.2e18 && d == (double)(int64_t)d && !(d == 0 && signbit(d))) {
            [self _int:(int64_t)d];
        } else {
            uint64_t bits;
            memcpy(&bits, &d, 8);
            bits = OSSwapHostToLittleInt64(bits);
            [self _byte:TAG_FLOAT];
            [self _bytes:&bits length:8];
        }
        break;
    }
    case '*': {
        const char *s = *(const char *const *)p;
        if (!s) { [self _byte:TAG_NIL]; break; }
        if ([self _newObjectEntry:s]) [self _sharedCString:s];
        break;
    }
    case ':': {
        SEL sel = *(const SEL *)p;
        [self _sharedCString:sel ? sel_getName(sel) : NULL];
        break;
    }
    case '#':
        [self _class:*(const Class *)p];
        break;
    case '@':
        [self _object:*(const id *)p];
        break;
    case '[': {
        char *end;
        unsigned long n = strtoul(t + 1, &end, 10);
        const char *elem = skip_qualifiers(end);
        if (*elem == 'c' || *elem == 'C') {
            [self _bytes:p length:n];
        } else {
            NSUInteger size = type_size(elem, NULL);
            for (unsigned long i = 0; i < n; i++) [self _value:elem at:(const char *)p + i * size];
        }
        break;
    }
    case '{': {
        const char *f = strchr(t, '=');
        const char *end = type_end(t) - 1;   /* the closing brace */
        NSUInteger offset = 0;
        if (f) {
            for (f++; f < end; f = type_end(f)) {
                NSUInteger align, size = type_size(f, &align);
                offset = (offset + align - 1) / align * align;
                [self _value:f at:(const char *)p + offset];
                offset += size;
            }
        }
        break;
    }
    default:
        FinchRaise(NSInvalidArgumentException, "*** -[NSArchiver encodeValueOfObjCType:at:]: unsupported type '%s'", type);
    }
    return type_end(type);
}

- (void)encodeValueOfObjCType:(const char *)type at:(const void *)addr
{
    if (!type || !*type) FinchRaise(NSInvalidArgumentException, "*** -[NSArchiver encodeValueOfObjCType:at:]: null type");
    [self _sharedCString:type];
    [self _value:type at:addr];
}

- (void)encodeValuesOfObjCTypes:(const char *)types, ...
{
    va_list ap;
    [self _sharedCString:types];
    va_start(ap, types);
    for (const char *t = types; *t;) t = [self _value:t at:va_arg(ap, void *)];
    va_end(ap);
}

- (void)encodeArrayOfObjCType:(const char *)type count:(NSUInteger)count at:(const void *)array
{
    char *array_type = NULL;
    asprintf(&array_type, "[%lu%s]", (unsigned long)count, type);
    [self encodeValueOfObjCType:array_type at:array];
    free(array_type);
}

- (void)encodeBytes:(const void *)byteaddr length:(NSUInteger)length
{
    [self _sharedCString:"+"];
    [self _int:(int64_t)length];
    [self _bytes:byteaddr length:length];
}

- (void)encodeDataObject:(NSData *)data
{
    int n = (int)[data length];
    [self encodeValueOfObjCType:"i" at:&n];
    [self encodeArrayOfObjCType:"c" count:(NSUInteger)n at:[data bytes]];
}

- (void)encodeObject:(id)object { [self encodeValueOfObjCType:"@" at:&object]; }

- (void)encodeRootObject:(id)rootObject
{
    if (_inRoot) FinchRaise(NSInvalidArgumentException, "*** -[NSArchiver encodeRootObject:]: called recursively");
    /* A first pass notes what is encoded unconditionally; conditional objects
     * are written only if they are among them. */
    NSMapTable *strings = [_strings retain], *objects = [_objects retain];
    NSUInteger stringCount = _stringCount, objectCount = _objectCount;
    [_unconditional release];
    _unconditional = [[NSHashTable alloc] initWithOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory capacity:0];
    _inRoot = YES;
    _noting = YES;
    _strings = [strings copy];
    _objects = [objects copy];
    @try {
        [self encodeObject:rootObject];
    } @finally {
        _noting = NO;
        [_strings release];
        [_objects release];
        _strings = strings;
        _objects = objects;
        _stringCount = stringCount;
        _objectCount = objectCount;
    }
    @try {
        [self encodeObject:rootObject];
    } @finally {
        _inRoot = NO;
        [_unconditional release];
        _unconditional = nil;
    }
}

- (void)encodeConditionalObject:(id)object
{
    if (_noting) {
        id none = nil;
        [self encodeValueOfObjCType:"@" at:&none];
        return;
    }
    if (_inRoot && object && ![_unconditional containsObject:object] && !NSMapGet(_objects, (__bridge void *)object)) object = nil;
    [self encodeObject:object];
}

- (NSInteger)versionForClassName:(NSString *)className
{
    Class c = NSClassFromString(className);
    return c ? class_getVersion(c) : NSNotFound;
}

/* MARK: Class names and replacements */

+ (void)encodeClassName:(NSString *)trueName intoClassName:(NSString *)inArchiveName
{
    @synchronized (self) {
        if (!global_encode_names) global_encode_names = [[NSMutableDictionary alloc] init];
        [global_encode_names setObject:inArchiveName forKey:trueName];
    }
}

+ (NSString *)classNameEncodedForTrueClassName:(NSString *)trueName
{
    @synchronized (self) {
        return [[[global_encode_names objectForKey:trueName] retain] autorelease];
    }
}

- (void)encodeClassName:(NSString *)trueName intoClassName:(NSString *)inArchiveName
{
    if (!_names) _names = [[NSMutableDictionary alloc] init];
    [_names setObject:inArchiveName forKey:trueName];
}

- (NSString *)classNameEncodedForTrueClassName:(NSString *)trueName
{
    NSString *n = [_names objectForKey:trueName];
    if (!n) n = [[self class] classNameEncodedForTrueClassName:trueName];
    return n ? n : trueName;
}

- (void)replaceObject:(id)object withObject:(id)newObject
{
    if (!_replacements) _replacements = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                                                  valueOptions:NSPointerFunctionsStrongMemory capacity:0];
    NSMapInsert(_replacements, (__bridge void *)object, (__bridge void *)newObject);
}

@end

/* MARK: - NSUnarchiver */

@interface NSUnarchiver () {
    NSData *_data;
    const uint8_t *_bytes;
    NSUInteger _length, _pos;
    BOOL _bigEndian;
    unsigned _systemVersion;
    NSMutableArray *_strings;           /* NSData, NUL-terminated */
    NSMutableArray *_objects;           /* objects, classes, and NSData for C strings */
    NSMutableDictionary *_versions;     /* class name -> version */
    NSMutableDictionary *_names;        /* archived -> class name */
    NSZone *_zone;
}
@end

@implementation NSUnarchiver

+ (id)unarchiveObjectWithData:(NSData *)data
{
    NSUnarchiver *u = [[self alloc] initForReadingWithData:data];
    if (!u) return nil;
    id o = nil;
    @try {
        o = [[u decodeObject] retain];
    } @finally {
        [u release];
    }
    return [o autorelease];
}

+ (id)unarchiveObjectWithFile:(NSString *)path
{
    NSData *d = [NSData dataWithContentsOfFile:path];
    return d ? [self unarchiveObjectWithData:d] : nil;
}

- (instancetype)initForReadingWithData:(NSData *)data
{
    if (!data) {
        [self release];
        FinchRaise(NSInvalidArgumentException, "*** -[NSUnarchiver initForReadingWithData:]: nil argument");
    }
    self = [super init];
    if (!self) return nil;
    _data = [data copy];
    _bytes = [_data bytes];
    _length = [_data length];
    _strings = [[NSMutableArray alloc] init];
    _objects = [[NSMutableArray alloc] init];
    _versions = [[NSMutableDictionary alloc] init];
    @try {
        [self _readHeader];
    } @catch (NSException *e) {
        [self release];
        return nil;
    }
    return self;
}

- (void)dealloc
{
    [_data release];
    [_strings release];
    [_objects release];
    [_versions release];
    [_names release];
    [super dealloc];
}

- (void)_inconsistent:(const char *)what
{
    FinchRaise(Inconsistency, "*** -[NSUnarchiver decode]: %s (at %lu of %lu)", what, (unsigned long)_pos, (unsigned long)_length);
}

/* MARK: Reading */

- (uint8_t)_byte
{
    if (_pos >= _length) [self _inconsistent:"past the end of the archive"];
    return _bytes[_pos++];
}

- (const uint8_t *)_bytes:(NSUInteger)n
{
    if (n > _length - _pos) [self _inconsistent:"past the end of the archive"];
    const uint8_t *p = _bytes + _pos;
    _pos += n;
    return p;
}

- (uint64_t)_raw:(NSUInteger)n
{
    const uint8_t *p = [self _bytes:n];
    uint64_t v = 0;
    for (NSUInteger i = 0; i < n; i++) v |= (uint64_t)p[_bigEndian ? n - 1 - i : i] << (8 * i);
    return v;
}

/* An integer whose first byte is `head`. */
- (int64_t)_intWithHead:(uint8_t)head
{
    switch (head) {
    case TAG_INT16: return (int16_t)[self _raw:2];
    case TAG_INT32: return (int32_t)[self _raw:4];
    case TAG_INT64: return (int64_t)[self _raw:8];
    default: return (int8_t)head;
    }
}

- (int64_t)_int { return [self _intWithHead:[self _byte]]; }

- (NSUInteger)_referenceWithHead:(uint8_t)head
{
    int64_t v = [self _intWithHead:head] - REFERENCE_BASE;
    if (v < 0) [self _inconsistent:"bad reference"];
    return (NSUInteger)v;
}

- (NSData *)_unsharedString
{
    int64_t n = [self _int];
    if (n < 0) [self _inconsistent:"bad string length"];
    NSMutableData *d = [NSMutableData dataWithBytes:[self _bytes:(NSUInteger)n] length:(NSUInteger)n];
    [d appendBytes:"" length:1];
    return d;
}

/* A shared string (NUL-terminated NSData), or nil. */
- (NSData *)_sharedString
{
    uint8_t head = [self _byte];
    if (head == TAG_NIL) return nil;
    if (head == TAG_NEW) {
        NSData *s = [self _unsharedString];
        [_strings addObject:s];
        return s;
    }
    NSUInteger i = [self _referenceWithHead:head];
    if (i >= [_strings count]) [self _inconsistent:"reference to a string not yet read"];
    return [_strings objectAtIndex:i];
}

- (void)_readHeader
{
    uint8_t version = [self _byte];
    int64_t n = [self _int];
    if (n != 11 || version < 3 || version > STREAMER_VERSION) [self _inconsistent:"not a typedstream"];
    const uint8_t *sig = [self _bytes:11];
    if (!memcmp(sig, "typedstream", 11)) _bigEndian = YES;
    else if (memcmp(sig, "streamtyped", 11)) [self _inconsistent:"not a typedstream"];
    _systemVersion = (unsigned)[self _int];
}

- (id)_entry:(NSUInteger)i
{
    if (i >= [_objects count]) [self _inconsistent:"reference to an object not yet read"];
    id o = [_objects objectAtIndex:i];
    return o == (id)kCFNull ? nil : o;
}

- (Class)_class
{
    uint8_t head = [self _byte];
    if (head == TAG_NIL) return Nil;
    if (head != TAG_NEW) {
        id c = [self _entry:[self _referenceWithHead:head]];
        if (c && !object_isClass(c)) [self _inconsistent:"reference to a class is to an object"];
        return c;
    }
    NSUInteger index = [_objects count];
    [_objects addObject:(id)kCFNull];
    NSData *nameData = [self _sharedString];
    if (!nameData) [self _inconsistent:"class without a name"];
    NSString *archived = [NSString stringWithUTF8String:[nameData bytes]];
    NSInteger version = (NSInteger)[self _int];
    [self _class];   /* the superclass chain, read and kept as entries */
    [_versions setObject:@(version) forKey:archived];
    NSString *name = [self classNameDecodedForArchiveClassName:archived];
    Class cls = NSClassFromString(name);
    if (!cls) FinchRaise(Inconsistency, "*** class error for '%s': class not loaded", [archived UTF8String]);
    [_objects replaceObjectAtIndex:index withObject:cls];
    return cls;
}

/* An object, retained (decodeValueOfObjCType:"@" hands it over owned). */
- (id)_object
{
    uint8_t head = [self _byte];
    if (head == TAG_NIL) return nil;
    if (head != TAG_NEW) return [[self _entry:[self _referenceWithHead:head]] retain];
    NSUInteger index = [_objects count];
    [_objects addObject:(id)kCFNull];
    Class cls = [self _class];
    if (!cls) [self _inconsistent:"object without a class"];
    id o = [cls allocWithZone:_zone];   /* ours (+1), handed to init; the table keeps its own */
    [_objects replaceObjectAtIndex:index withObject:o];
    id decoded = [o initWithCoder:self];
    if (decoded != o && decoded) [_objects replaceObjectAtIndex:index withObject:decoded];
    if (!decoded) { [_objects replaceObjectAtIndex:index withObject:(id)kCFNull]; }
    if (decoded) {
        id awake = [decoded awakeAfterUsingCoder:self];
        if (awake != decoded) {
            [awake retain];
            [decoded release];
            decoded = awake;
            [_objects replaceObjectAtIndex:index withObject:awake ? awake : (id)kCFNull];
        }
    }
    if ([self _byte] != TAG_END) {
        [decoded release];
        [self _inconsistent:"object's data doesn't end where it should"];
    }
    return decoded;
}

- (const char *)_value:(const char *)type at:(void *)p
{
    const char *t = skip_qualifiers(type);
    switch (*t) {
    case 'c': case 'C': case 'B':
        *(uint8_t *)p = [self _byte];
        break;
    case 's': case 'S':
        *(int16_t *)p = (int16_t)[self _int];
        break;
    case 'i': case 'I': case 'l': case 'L':
        *(int32_t *)p = (int32_t)[self _int];
        break;
    case 'q': case 'Q':
        *(int64_t *)p = [self _int];
        break;
    case 'f': {
        uint8_t head = [self _byte];
        if (head == TAG_FLOAT) {
            uint32_t bits = (uint32_t)[self _raw:4];
            memcpy(p, &bits, 4);
        } else {
            *(float *)p = (float)[self _intWithHead:head];
        }
        break;
    }
    case 'd': {
        uint8_t head = [self _byte];
        if (head == TAG_FLOAT) {
            uint64_t bits = [self _raw:8];
            memcpy(p, &bits, 8);
        } else {
            *(double *)p = (double)[self _intWithHead:head];
        }
        break;
    }
    case '*': {
        uint8_t head = [self _byte];
        NSData *s = nil;
        if (head == TAG_NEW) {
            NSUInteger index = [_objects count];
            [_objects addObject:(id)kCFNull];
            s = [self _sharedString];
            if (s) [_objects replaceObjectAtIndex:index withObject:s];
        } else if (head != TAG_NIL) {
            s = [self _entry:[self _referenceWithHead:head]];
            if (s && ![s isKindOfClass:[NSData class]]) [self _inconsistent:"reference to a C string is to an object"];
        }
        *(const char **)p = s ? [s bytes] : NULL;
        break;
    }
    case ':': {
        NSData *s = [self _sharedString];
        *(SEL *)p = s ? sel_registerName([s bytes]) : NULL;
        break;
    }
    case '#':
        *(Class *)p = [self _class];
        break;
    case '@':
        *(id *)p = [self _object];
        break;
    case '[': {
        char *end;
        unsigned long n = strtoul(t + 1, &end, 10);
        const char *elem = skip_qualifiers(end);
        if (*elem == 'c' || *elem == 'C') {
            memcpy(p, [self _bytes:n], n);
        } else {
            NSUInteger size = type_size(elem, NULL);
            for (unsigned long i = 0; i < n; i++) [self _value:elem at:(char *)p + i * size];
        }
        break;
    }
    case '{': {
        const char *f = strchr(t, '=');
        const char *end = type_end(t) - 1;
        NSUInteger offset = 0;
        if (f) {
            for (f++; f < end; f = type_end(f)) {
                NSUInteger align, size = type_size(f, &align);
                offset = (offset + align - 1) / align * align;
                [self _value:f at:(char *)p + offset];
                offset += size;
            }
        }
        break;
    }
    default:
        FinchRaise(NSInvalidArgumentException, "*** -[NSUnarchiver decodeValueOfObjCType:at:]: unsupported type '%s'", type);
    }
    return type_end(type);
}

/* The group's type string, which must be the one asked for. */
- (void)_expectType:(const char *)type
{
    NSData *s = [self _sharedString];
    if (!s || strcmp([s bytes], type) != 0) {
        FinchRaise(Inconsistency, "*** -[NSUnarchiver decodeValueOfObjCType:at:]: mismatch between encoded ('%s') and decoded ('%s') types",
            s ? (const char *)[s bytes] : "nil", type);
    }
}

- (void)decodeValueOfObjCType:(const char *)type at:(void *)data size:(NSUInteger)size
{
    [self _expectType:type];
    [self _value:type at:data];
}

- (void)decodeValueOfObjCType:(const char *)type at:(void *)data
{
    [self _expectType:type];
    [self _value:type at:data];
}

- (void)decodeValuesOfObjCTypes:(const char *)types, ...
{
    va_list ap;
    [self _expectType:types];
    va_start(ap, types);
    for (const char *t = types; *t;) t = [self _value:t at:va_arg(ap, void *)];
    va_end(ap);
}

- (void)decodeArrayOfObjCType:(const char *)itemType count:(NSUInteger)count at:(void *)array
{
    char *array_type = NULL;
    asprintf(&array_type, "[%lu%s]", (unsigned long)count, itemType);
    @try {
        [self decodeValueOfObjCType:array_type at:array];
    } @finally {
        free(array_type);
    }
}

- (void *)decodeBytesWithReturnedLength:(NSUInteger *)lengthp
{
    [self _expectType:"+"];
    int64_t n = [self _int];
    if (n < 0) [self _inconsistent:"bad byte count"];
    NSData *d = [NSData dataWithBytes:[self _bytes:(NSUInteger)n] length:(NSUInteger)n];
    if (lengthp) *lengthp = (NSUInteger)n;
    return (void *)[d bytes];
}

- (NSData *)decodeDataObject
{
    int n = 0;
    [self decodeValueOfObjCType:"i" at:&n];
    if (n < 0) [self _inconsistent:"bad data length"];
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)n];
    [self decodeArrayOfObjCType:"c" count:(NSUInteger)n at:[d mutableBytes]];
    return d;
}

- (BOOL)isAtEnd { return _pos >= _length; }
- (unsigned int)systemVersion { return _systemVersion; }
- (NSZone *)objectZone { return _zone; }
- (void)setObjectZone:(NSZone *)zone { _zone = zone; }

- (NSInteger)versionForClassName:(NSString *)className
{
    NSNumber *v = [_versions objectForKey:className];
    return v ? [v integerValue] : NSNotFound;
}

/* MARK: Class names and replacements */

+ (void)decodeClassName:(NSString *)inArchiveName asClassName:(NSString *)trueName
{
    @synchronized (self) {
        if (!global_decode_names) global_decode_names = [[NSMutableDictionary alloc] init];
        [global_decode_names setObject:trueName forKey:inArchiveName];
    }
}

+ (NSString *)classNameDecodedForArchiveClassName:(NSString *)inArchiveName
{
    @synchronized (self) {
        NSString *n = [global_decode_names objectForKey:inArchiveName];
        return n ? [[n retain] autorelease] : inArchiveName;
    }
}

- (void)decodeClassName:(NSString *)inArchiveName asClassName:(NSString *)trueName
{
    if (!_names) _names = [[NSMutableDictionary alloc] init];
    [_names setObject:trueName forKey:inArchiveName];
}

- (NSString *)classNameDecodedForArchiveClassName:(NSString *)inArchiveName
{
    NSString *n = [_names objectForKey:inArchiveName];
    return n ? n : [[self class] classNameDecodedForArchiveClassName:inArchiveName];
}

- (void)replaceObject:(id)object withObject:(id)newObject
{
    NSUInteger i = [_objects indexOfObjectIdenticalTo:object];
    if (i != NSNotFound) [_objects replaceObjectAtIndex:i withObject:newObject ? newObject : (id)kCFNull];
}

@end

/* MARK: - NSObject */

@implementation NSObject (FinchArchiverCallbacks)
- (Class)classForArchiver { return [self classForCoder]; }
- (id)replacementObjectForArchiver:(NSArchiver *)archiver { return [self replacementObjectForCoder:archiver]; }
@end
