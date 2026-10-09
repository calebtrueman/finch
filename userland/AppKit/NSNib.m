/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Nibs: loading the interface files Xcode compiles.
 *
 * A compiled nib is a NIBArchive (ibtool's output for macOS and iOS since
 * Xcode 4.something), or, in older apps, an NSKeyedArchiver archive. Both
 * hold the same object graph: an NSIBObjectData with the root object
 * (File's Owner), the objects and their parents, the connections, and the
 * windows to show. Finch reads NIBArchives with its own decoder,
 * FinchNibDecoder, an NSCoder over the archive's tables:
 *
 *   "NIBArchive", then ten little-endian uint32s: format version (1), coder
 *   version (10), and the count and offset of the objects, keys, values and
 *   class names. Numbers in the tables are varints: seven bits per byte,
 *   least significant first, the last byte marked by its top bit.
 *   - an object: class index, first value index, value count
 *   - a key: length, UTF-8 bytes
 *   - a value: key index, type, data (0-3: int8/16/32/64; 4: NO; 5: YES;
 *     6: float; 7: double; 8: bytes (varint length); 9: nil; 10: object
 *     index, uint32)
 *   - a class name: length, count of fallback classes, their indices
 *     (int32s), then the name, NUL-terminated
 *   Arrays and sets list their elements under the key
 *   "UINibEncoderEmptyKey"; strings, numbers and data have NS.bytes,
 *   NS.intval or NS.dblval. Geometry is in strings ("{{x, y}, {w, h}}").
 *
 * This layout was worked out from ibtool's output; the code is Finch's.
 */
#import "NSView_Finch.h"

NSString *NSNibOwner = @"NSNibOwner";
NSString *NSNibTopLevelObjects = @"NSNibTopLevelObjects";

#pragma mark - The decoder

typedef struct {
    uint32_t cls, first, count;
} NibObject;

typedef struct {
    uint32_t key;
    uint8_t type;
    union {
        int64_t i;
        double d;
        uint32_t object;
        struct {
            const uint8_t *bytes;
            uint32_t length;
        } data;
    };
} NibValue;

enum { V_INT8, V_INT16, V_INT32, V_INT64, V_FALSE, V_TRUE, V_FLOAT, V_DOUBLE, V_DATA, V_NIL, V_OBJECT };

@interface FinchNibDecoder : NSCoder
- (instancetype)initWithData:(NSData *)data;
- (id)rootObject;
@end

@implementation FinchNibDecoder {
    NSData *_data;
    NibObject *_objects;
    uint32_t _objectCount;
    NSMutableArray<NSString *> *_keys;
    NibValue *_values;
    uint32_t _valueCount;
    NSMutableArray<NSString *> *_classNames;
    NSMutableArray<NSArray<NSNumber *> *> *_fallbacks;
    id *_decoded;  /* by object index; retained */
    NSUInteger _current;  /* the object being decoded */
    NSUInteger _cursor;   /* for repeated keys (array elements): the next value to look at */
}

static bool
varint(const uint8_t **p, const uint8_t *end, uint32_t *out)
{
    uint32_t v = 0;
    for (int shift = 0; *p < end && shift < 35; shift += 7) {
        uint8_t b = *(*p)++;
        v |= (uint32_t)(b & 0x7f) << shift;
        if (b & 0x80) {
            *out = v;
            return true;
        }
    }
    return false;
}

- (instancetype)initWithData:(NSData *)data
{
    self = [super init];
    if (!self)
        return nil;
    _data = [data retain];
    const uint8_t *base = [data bytes], *end = base + [data length];
    if ([data length] < 50 || memcmp(base, "NIBArchive", 10)) {
        [self release];
        return nil;
    }
    uint32_t h[10];
    memcpy(h, base + 10, sizeof h);
    uint32_t nobj = h[2], oobj = h[3], nkey = h[4], okey = h[5], nval = h[6], oval = h[7], ncls = h[8], ocls = h[9];
    if (oobj > [data length] || okey > [data length] || oval > [data length] || ocls > [data length]) {
        [self release];
        return nil;
    }
    _keys = [[NSMutableArray alloc] initWithCapacity:nkey];
    const uint8_t *p = base + okey;
    for (uint32_t i = 0; i < nkey; i++) {
        uint32_t n;
        if (!varint(&p, end, &n) || p + n > end)
            goto bad;
        NSString *k = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding];
        [_keys addObject:k ?: @""];
        [k release];
        p += n;
    }
    _classNames = [[NSMutableArray alloc] initWithCapacity:ncls];
    _fallbacks = [[NSMutableArray alloc] initWithCapacity:ncls];
    p = base + ocls;
    for (uint32_t i = 0; i < ncls; i++) {
        uint32_t n, extra;
        if (!varint(&p, end, &n) || !varint(&p, end, &extra) || p + 4 * (size_t)extra + n > end)
            goto bad;
        NSMutableArray *fb = [NSMutableArray array];
        for (uint32_t k = 0; k < extra; k++) {
            int32_t v;
            memcpy(&v, p, 4);
            [fb addObject:@(v)];
            p += 4;
        }
        size_t len = strnlen((const char *)p, n);
        NSString *name = [[NSString alloc] initWithBytes:p length:len encoding:NSUTF8StringEncoding];
        [_classNames addObject:name ?: @"NSObject"];
        [name release];
        [_fallbacks addObject:fb];
        p += n;
    }
    _values = calloc(nval ?: 1, sizeof *_values);
    _valueCount = nval;
    p = base + oval;
    for (uint32_t i = 0; i < nval; i++) {
        NibValue *v = &_values[i];
        if (!varint(&p, end, &v->key) || p >= end || v->key >= nkey)
            goto bad;
        v->type = *p++;
        size_t need = 0;
        switch (v->type) {
        case V_INT8: need = 1; break;
        case V_INT16: need = 2; break;
        case V_INT32: case V_FLOAT: case V_OBJECT: need = 4; break;
        case V_INT64: case V_DOUBLE: need = 8; break;
        case V_FALSE: case V_TRUE: case V_NIL: break;
        case V_DATA: {
            uint32_t n;
            if (!varint(&p, end, &n) || p + n > end)
                goto bad;
            v->data.bytes = p;
            v->data.length = n;
            p += n;
            continue;
        }
        default:
            goto bad;
        }
        if (p + need > end)
            goto bad;
        switch (v->type) {
        case V_INT8: v->i = (int8_t)p[0]; break;
        case V_INT16: { int16_t x; memcpy(&x, p, 2); v->i = x; break; }
        case V_INT32: { int32_t x; memcpy(&x, p, 4); v->i = x; break; }
        case V_INT64: memcpy(&v->i, p, 8); break;
        case V_FLOAT: { float x; memcpy(&x, p, 4); v->d = x; break; }
        case V_DOUBLE: memcpy(&v->d, p, 8); break;
        case V_OBJECT: memcpy(&v->object, p, 4); break;
        }
        p += need;
    }
    _objects = calloc(nobj ?: 1, sizeof *_objects);
    _objectCount = nobj;
    p = base + oobj;
    for (uint32_t i = 0; i < nobj; i++) {
        NibObject *o = &_objects[i];
        if (!varint(&p, end, &o->cls) || !varint(&p, end, &o->first) || !varint(&p, end, &o->count) ||
            o->cls >= ncls || (uint64_t)o->first + o->count > nval)
            goto bad;
    }
    _decoded = calloc(nobj ?: 1, sizeof(id));
    return self;
bad:
    NSLog(@"Finch: malformed nib archive");
    [self release];
    return nil;
}

- (void)dealloc
{
    for (uint32_t i = 0; _decoded && i < _objectCount; i++)
        [_decoded[i] release];
    free(_decoded);
    free(_objects);
    free(_values);
    [_keys release];
    [_classNames release];
    [_fallbacks release];
    [_data release];
    [super dealloc];
}

- (BOOL)allowsKeyedCoding { return YES; }
- (BOOL)requiresSecureCoding { return NO; }
- (NSInteger)versionForClassName:(NSString *)className { return 0; }
- (unsigned)systemVersion { return 1000; }

/* The current object's value for a key: the first one, or for repeated keys the next after the cursor. */
- (NibValue *)nibValueForKey:(NSString *)key
{
    if (_current >= _objectCount)
        return NULL;
    NibObject *o = &_objects[_current];
    for (uint32_t i = 0; i < o->count; i++) {
        NibValue *v = &_values[o->first + i];
        if ([_keys[v->key] isEqualToString:key])
            return v;
    }
    return NULL;
}

- (BOOL)containsValueForKey:(NSString *)key
{
    return [self nibValueForKey:key] != NULL;
}

static double
number(NibValue *v)
{
    switch (v->type) {
    case V_INT8: case V_INT16: case V_INT32: case V_INT64: return (double)v->i;
    case V_TRUE: return 1;
    case V_FALSE: return 0;
    case V_FLOAT: case V_DOUBLE: return v->d;
    default: return 0;
    }
}

static int64_t
integer(NibValue *v)
{
    switch (v->type) {
    case V_INT8: case V_INT16: case V_INT32: case V_INT64: return v->i;
    case V_TRUE: return 1;
    case V_FLOAT: case V_DOUBLE: return (int64_t)v->d;
    default: return 0;
    }
}

- (BOOL)decodeBoolForKey:(NSString *)key { NibValue *v = [self nibValueForKey:key]; return v ? integer(v) != 0 : NO; }
- (int)decodeIntForKey:(NSString *)key { NibValue *v = [self nibValueForKey:key]; return v ? (int)integer(v) : 0; }
- (int32_t)decodeInt32ForKey:(NSString *)key { NibValue *v = [self nibValueForKey:key]; return v ? (int32_t)integer(v) : 0; }
- (int64_t)decodeInt64ForKey:(NSString *)key { NibValue *v = [self nibValueForKey:key]; return v ? integer(v) : 0; }
- (NSInteger)decodeIntegerForKey:(NSString *)key { NibValue *v = [self nibValueForKey:key]; return v ? (NSInteger)integer(v) : 0; }
- (float)decodeFloatForKey:(NSString *)key { NibValue *v = [self nibValueForKey:key]; return v ? (float)number(v) : 0; }
- (double)decodeDoubleForKey:(NSString *)key { NibValue *v = [self nibValueForKey:key]; return v ? number(v) : 0; }

- (const uint8_t *)decodeBytesForKey:(NSString *)key returnedLength:(NSUInteger *)length
{
    NibValue *v = [self nibValueForKey:key];
    if (v && v->type == V_DATA) {
        if (length)
            *length = v->data.length;
        return v->data.bytes;
    }
    if (v && v->type == V_OBJECT) {
        id o = [self objectAtIndex:v->object];
        if ([o isKindOfClass:[NSData class]]) {
            if (length)
                *length = [o length];
            return [o bytes];
        }
    }
    if (length)
        *length = 0;
    return NULL;
}

/* Geometry is written as strings. */
- (NSString *)stringForKey:(NSString *)key
{
    id o = [self decodeObjectForKey:key];
    return [o isKindOfClass:[NSString class]] ? o : nil;
}

- (NSPoint)decodePointForKey:(NSString *)key { NSString *s = [self stringForKey:key]; return s ? NSPointFromString(s) : NSZeroPoint; }
- (NSSize)decodeSizeForKey:(NSString *)key { NSString *s = [self stringForKey:key]; return s ? NSSizeFromString(s) : NSZeroSize; }
- (NSRect)decodeRectForKey:(NSString *)key { NSString *s = [self stringForKey:key]; return s ? NSRectFromString(s) : NSZeroRect; }
- (CGPoint)decodeCGPointForKey:(NSString *)key { return NSPointToCGPoint([self decodePointForKey:key]); }
- (CGSize)decodeCGSizeForKey:(NSString *)key { return NSSizeToCGSize([self decodeSizeForKey:key]); }
- (CGRect)decodeCGRectForKey:(NSString *)key { return NSRectToCGRect([self decodeRectForKey:key]); }

- (id)decodeObjectForKey:(NSString *)key
{
    NibValue *v = [self nibValueForKey:key];
    if (!v)
        return nil;
    if (v->type == V_OBJECT)
        return [self objectAtIndex:v->object];
    if (v->type == V_DATA)
        return [NSData dataWithBytes:v->data.bytes length:v->data.length];
    if (v->type == V_NIL)
        return nil;
    return @(number(v));
}

- (id)decodeObjectOfClass:(Class)cls forKey:(NSString *)key { return [self decodeObjectForKey:key]; }
- (id)decodeObjectOfClasses:(NSSet<Class> *)classes forKey:(NSString *)key { return [self decodeObjectForKey:key]; }
- (id)decodeTopLevelObjectForKey:(NSString *)key error:(NSError **)error { return [self decodeObjectForKey:key]; }
- (id)decodeArrayOfObjectsOfClass:(Class)cls forKey:(NSString *)key { return [self decodeObjectForKey:key]; }
- (id)decodeArrayOfObjectsOfClasses:(NSSet<Class> *)classes forKey:(NSString *)key { return [self decodeObjectForKey:key]; }
- (id)decodeDictionaryWithKeysOfClass:(Class)k objectsOfClass:(Class)o forKey:(NSString *)key
{
    return [self decodeObjectForKey:key];
}
- (NSSet *)allowedClasses { return nil; }

/* The values an array, set or dictionary lists under the empty key. */
- (NSArray *)inlinedObjectsOf:(NSUInteger)index
{
    NibObject *o = &_objects[index];
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:o->count];
    for (uint32_t i = 0; i < o->count; i++) {
        NibValue *v = &_values[o->first + i];
        if (![_keys[v->key] isEqualToString:@"UINibEncoderEmptyKey"])
            continue;
        id element = v->type == V_OBJECT ? [self objectAtIndex:v->object] : nil;
        [a addObject:element ?: [NSNull null]];
    }
    return a;
}

static Class
nib_class(FinchNibDecoder *self, NSUInteger clsIndex)
{
    NSString *name = self->_classNames[clsIndex];
    Class c = NSClassFromString(name);
    if (c)
        return c;
    for (NSNumber *fb in self->_fallbacks[clsIndex]) {
        NSUInteger i = [fb unsignedIntegerValue];
        if (i < [self->_classNames count] && (c = NSClassFromString(self->_classNames[i])))
            return c;
    }
    NSLog(@"Finch: no class %@ for a nib object; using NSObject", name);
    return [NSObject class];
}

- (id)objectAtIndex:(NSUInteger)index
{
    if (index >= _objectCount)
        return nil;
    if (_decoded[index])
        return _decoded[index] == (id)[NSNull null] && ![_classNames[_objects[index].cls] isEqualToString:@"NSNull"]
                   ? nil
                   : _decoded[index];
    NSString *name = _classNames[_objects[index].cls];
    NSUInteger saved = _current;
    _current = index;
    id result = nil;
    /* Foundation's value classes are read directly. */
    if ([name isEqualToString:@"NSString"] || [name isEqualToString:@"NSMutableString"] ||
        [name isEqualToString:@"NSLocalizableString"]) {
        NibValue *v = [self nibValueForKey:@"NS.bytes"];
        NSString *s = v && v->type == V_DATA ? [[NSString alloc] initWithBytes:v->data.bytes length:v->data.length
                                                                       encoding:NSUTF8StringEncoding]
                                             : [[NSString alloc] init];
        result = [name isEqualToString:@"NSMutableString"] ? [s mutableCopy] : [s retain];
        [s release];
    } else if ([name isEqualToString:@"NSNumber"]) {
        NibValue *v = [self nibValueForKey:@"NS.intval"] ?: [self nibValueForKey:@"NS.dblval"];
        if (!v)
            result = [@0 retain];
        else if (v->type == V_FLOAT || v->type == V_DOUBLE)
            result = [@(v->d) retain];
        else if (v->type == V_TRUE || v->type == V_FALSE)
            result = [@(v->type == V_TRUE) retain];
        else
            result = [@(v->i) retain];
    } else if ([name isEqualToString:@"NSData"] || [name isEqualToString:@"NSMutableData"]) {
        NibValue *v = [self nibValueForKey:@"NS.bytes"];
        NSData *d = v && v->type == V_DATA ? [NSData dataWithBytes:v->data.bytes length:v->data.length] : [NSData data];
        result = [name isEqualToString:@"NSMutableData"] ? [d mutableCopy] : [d retain];
    } else if ([name isEqualToString:@"NSNull"]) {
        result = [[NSNull null] retain];
    } else if ([name isEqualToString:@"NSArray"] || [name isEqualToString:@"NSMutableArray"] ||
               [name isEqualToString:@"NSSet"] || [name isEqualToString:@"NSMutableSet"] ||
               [name isEqualToString:@"NSOrderedSet"] || [name isEqualToString:@"NSMutableOrderedSet"] ||
               [name isEqualToString:@"NSDictionary"] || [name isEqualToString:@"NSMutableDictionary"]) {
        /* placeholder while the elements decode, in case of a cycle */
        _decoded[index] = [[NSNull null] retain];
        NSArray *items = [self inlinedObjectsOf:index];
        _current = index;
        if ([name hasSuffix:@"Dictionary"]) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            if ([self nibValueForKey:@"NS.keys"]) {
                NSArray *ks = [self decodeObjectForKey:@"NS.keys"], *os = [self decodeObjectForKey:@"NS.objects"];
                for (NSUInteger i = 0; i < MIN([ks count], [os count]); i++)
                    d[ks[i]] = os[i];
            } else {
                for (NSUInteger i = 0; i + 1 < [items count]; i += 2)
                    d[items[i]] = items[i + 1];
            }
            result = [name hasPrefix:@"NSMutable"] ? [d retain] : [d copy];
        } else if ([name hasSuffix:@"OrderedSet"]) {
            result = [[NSMutableOrderedSet alloc] initWithArray:items];
        } else if ([name hasSuffix:@"Set"]) {
            result = [name hasPrefix:@"NSMutable"] ? [[NSMutableSet alloc] initWithArray:items]
                                                   : [[NSSet alloc] initWithArray:items];
        } else {
            result = [name hasPrefix:@"NSMutable"] ? [items mutableCopy] : [items copy];
        }
        [_decoded[index] release];
        _decoded[index] = nil;
    } else {
        Class c = nib_class(self, _objects[index].cls);
        id obj = [c alloc];
        _decoded[index] = [obj retain];  /* so references back to it while it decodes find it */
        id inited = [obj initWithCoder:self];
        _current = index;
        if (inited && [inited respondsToSelector:@selector(awakeAfterUsingCoder:)])
            inited = [inited awakeAfterUsingCoder:self];
        [_decoded[index] release];
        _decoded[index] = nil;
        result = inited;  /* initWithCoder returned it +1 */
    }
    _current = saved;
    _decoded[index] = result ?: [[NSNull null] retain];
    return result;
}

- (id)rootObject
{
    _current = 0;
    return [self objectAtIndex:0];
}

/* The nib's object data: the root object's IB.objectdata. */
- (id)objectData
{
    _current = 0;
    if (![_classNames[_objects[0].cls] isEqualToString:@"NSObject"])
        return [self objectAtIndex:0];
    return [self decodeObjectForKey:@"IB.objectdata"];
}

@end

#pragma mark - Placeholders and templates

/* An object of the nib's own: File's Owner, First Responder, the app, or an instance of a class the app names. */
@interface NSCustomObject : NSObject <NSCoding>
@property (copy) NSString *className;
@end

@implementation NSCustomObject {
    NSString *_className;
}
@synthesize className = _className;

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    _className = [[coder decodeObjectForKey:@"NSClassName"] copy];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_className forKey:@"NSClassName"];
}

- (void)dealloc
{
    [_className release];
    [super dealloc];
}

/* Placeholders stay until the nib is instantiated; anything else becomes an instance of its class. */
- (id)_finchRealize
{
    if ([_className isEqualToString:@"FirstResponder"])
        return nil;
    Class c = NSClassFromString(_className);
    if (!c)
        NSLog(@"Unknown class '%@', using 'NSObject' instead. Encountered in Interface Builder file.", _className);
    if ([c isSubclassOfClass:[NSApplication class]])
        return [c sharedApplication];
    return [[[(c ?: [NSObject class]) alloc] init] autorelease];
}

@end

/* A view of a class Interface Builder didn't know: decoded as NSView, then made as the app's class. */
@interface NSCustomView : NSView
@end

@implementation NSCustomView {
    NSString *_className;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *name = [coder decodeObjectForKey:@"NSClassName"];
    Class c = NSClassFromString(name);
    if (c && c != [NSCustomView class] && [c isSubclassOfClass:[NSView class]]) {
        [self release];
        /* As Apple's: the app's class is made with initWithFrame:, then given the archived subviews. */
        NSView *v = [[c alloc] initWithFrame:[coder decodeRectForKey:@"NSFrame"]];
        NSRect frame = [coder containsValueForKey:@"NSFrame"]
                           ? [coder decodeRectForKey:@"NSFrame"]
                           : NSMakeRect(0, 0, [coder decodeSizeForKey:@"NSFrameSize"].width,
                                        [coder decodeSizeForKey:@"NSFrameSize"].height);
        [v setFrame:frame];
        int flags = [coder decodeIntForKey:@"NSvFlags"];
        [v setAutoresizingMask:flags & 0x3f];
        if ([coder containsValueForKey:@"NSvFlags"])
            [v setAutoresizesSubviews:(flags & 0x100) != 0];
        [v setHidden:(flags & 0x80000000) != 0];
        for (NSView *sub in [coder decodeObjectForKey:@"NSSubviews"])
            [v addSubview:sub];
        return (id)v;
    }
    if (name && !c)
        NSLog(@"Unknown class '%@', using 'NSView' instead. Encountered in Interface Builder file.", name);
    return [super initWithCoder:coder];
}

@end

/* An object of the app's class: made with -init (custom objects) or -initWithCoder: (views and the like). */
@interface NSClassSwapper : NSObject <NSCoding>
@end

@implementation NSClassSwapper

- (instancetype)initWithCoder:(NSCoder *)coder
{
    [self release];
    NSString *name = [coder decodeObjectForKey:@"NSClassName"];
    NSString *original = [coder decodeObjectForKey:@"NSOriginalClassName"];
    Class c = NSClassFromString(name);
    if (!c) {
        NSLog(@"Unknown class '%@', using '%@' instead. Encountered in Interface Builder file.", name, original);
        c = NSClassFromString(original) ?: [NSObject class];
    }
    if ([coder decodeBoolForKey:@"NSInitializeWithInit"])
        return [[c alloc] init];
    return [[c alloc] initWithCoder:coder];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

@end

/* A window as the nib describes it; becomes the window itself. */
@interface NSWindowTemplate : NSObject <NSCoding>
@end

enum {
    WT_HIDES_ON_DEACTIVATE = 1u << 31,
    WT_NOT_RELEASED_ON_CLOSE = 1u << 30,
    WT_DEFERRED = 1u << 29,
    WT_ONE_SHOT = 1u << 28,
    WT_NOT_SHADOWED = 1u << 12,
    WT_AUTORECALCULATES_KEY_VIEW_LOOP = 1u << 11,
};

@implementation NSWindowTemplate

- (instancetype)initWithCoder:(NSCoder *)coder
{
    [self release];
    NSString *className = [coder decodeObjectForKey:@"NSWindowClass"];
    Class c = NSClassFromString(className);
    if (!c || ![c isSubclassOfClass:[NSWindow class]])
        c = [NSWindow class];
    NSRect rect = [coder decodeRectForKey:@"NSWindowRect"];
    NSWindowStyleMask style = (NSWindowStyleMask)[coder decodeIntegerForKey:@"NSWindowStyleMask"];
    NSBackingStoreType backing = (NSBackingStoreType)[coder decodeIntegerForKey:@"NSWindowBacking"];
    unsigned flags = (unsigned)[coder decodeIntForKey:@"NSWTFlags"];
    /* The rect is where it was on Interface Builder's screen: keep its distance from the top on this one. */
    NSRect designScreen = [coder decodeRectForKey:@"NSScreenRect"];
    NSScreen *screen = [NSScreen mainScreen];
    if (screen && !NSIsEmptyRect(designScreen)) {
        CGFloat fromTop = NSMaxY(designScreen) - NSMaxY(rect);
        rect.origin.y = NSMaxY([screen frame]) - fromTop - rect.size.height;
    }
    NSWindow *w = [[c alloc] initWithContentRect:rect styleMask:style backing:backing ?: NSBackingStoreBuffered
                                           defer:(flags & WT_DEFERRED) != 0];
    NSString *title = [coder decodeObjectForKey:@"NSWindowTitle"];
    if (title)
        [w setTitle:title];
    NSView *content = [coder decodeObjectForKey:@"NSWindowView"];
    if (content)
        [w setContentView:content];
    [w setReleasedWhenClosed:!(flags & WT_NOT_RELEASED_ON_CLOSE)];
    [w setHidesOnDeactivate:(flags & WT_HIDES_ON_DEACTIVATE) != 0];
    [w setOneShot:(flags & WT_ONE_SHOT) != 0];
    [w setHasShadow:!(flags & WT_NOT_SHADOWED)];
    if ([coder containsValueForKey:@"NSMinSize"])
        [w setMinSize:[coder decodeSizeForKey:@"NSMinSize"]];
    if ([coder containsValueForKey:@"NSMaxSize"])
        [w setMaxSize:[coder decodeSizeForKey:@"NSMaxSize"]];
    if ([coder containsValueForKey:@"NSWindowContentMinSize"])
        [w setContentMinSize:[coder decodeSizeForKey:@"NSWindowContentMinSize"]];
    if ([coder containsValueForKey:@"NSWindowContentMaxSize"])
        [w setContentMaxSize:[coder decodeSizeForKey:@"NSWindowContentMaxSize"]];
    NSString *autosave = [coder decodeObjectForKey:@"NSFrameAutosaveName"];
    if ([autosave length]) {
        [w setFrameUsingName:autosave];
        [w setFrameAutosaveName:autosave];
    }
    NSString *identifier = [coder decodeObjectForKey:@"NSUserInterfaceItemIdentifier"];
    if (identifier)
        [w setIdentifier:identifier];
    if ([coder containsValueForKey:@"NSWindowIsRestorable"])
        [w setRestorable:[coder decodeBoolForKey:@"NSWindowIsRestorable"]];
    return (id)w;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

@end

/* Connections: an outlet, or a control's target and action. */
@interface NSNibConnector : NSObject <NSCoding>
@property (assign) id source, destination;
@property (copy) NSString *label;
- (void)establishConnection;
- (void)replaceObject:(id)old withObject:(id)new;
@end

@implementation NSNibConnector {
    id _source, _destination;
    NSString *_label;
}
@synthesize source = _source, destination = _destination, label = _label;

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    _source = [[coder decodeObjectForKey:@"NSSource"] retain];
    _destination = [[coder decodeObjectForKey:@"NSDestination"] retain];
    _label = [[coder decodeObjectForKey:@"NSLabel"] copy];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

- (void)dealloc
{
    [_source release];
    [_destination release];
    [_label release];
    [super dealloc];
}

- (void)replaceObject:(id)old withObject:(id)new
{
    if (_source == old) {
        [new retain];
        [_source release];
        _source = new;
    }
    if (_destination == old) {
        [new retain];
        [_destination release];
        _destination = new;
    }
}

- (void)establishConnection
{
}

@end

@interface NSNibOutletConnector : NSNibConnector
@end

@implementation NSNibOutletConnector

- (void)establishConnection
{
    id source = [self source];
    NSString *label = [self label];
    if (!source || !label)
        return;
    @try {
        [source setValue:[self destination] forKey:label];
    } @catch (NSException *e) {
        NSLog(@"Failed to connect (%@) outlet from (%@) to (%@): %@", label, source, [self destination], [e reason]);
    }
}

@end

@interface NSNibControlConnector : NSNibConnector
@end

@implementation NSNibControlConnector

- (void)establishConnection
{
    id source = [self source];
    if ([source respondsToSelector:@selector(setTarget:)])
        [source setTarget:[self destination]];
    if ([source respondsToSelector:@selector(setAction:)])
        [source setAction:NSSelectorFromString([self label])];
}

@end

@interface NSNibAuxiliaryActionConnector : NSNibControlConnector
@end
@implementation NSNibAuxiliaryActionConnector
@end

@interface NSNibBindingConnector : NSNibConnector
@end

@implementation NSNibBindingConnector

- (void)establishConnection
{
    /* Cocoa bindings come with NSKeyValueBinding. */
}

@end

#pragma mark - NSIBObjectData

@interface NSIBObjectData : NSObject <NSCoding>
- (BOOL)instantiateWithOwner:(id)owner topLevelObjects:(NSArray **)topLevel;
@end

@implementation NSIBObjectData {
    id _root;
    NSSet *_visibleWindows;
    NSArray *_connections;
    NSArray *_objectsKeys, *_objectsValues;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    _root = [[coder decodeObjectForKey:@"NSRoot"] retain];
    _visibleWindows = [[coder decodeObjectForKey:@"NSVisibleWindows"] retain];
    _connections = [[coder decodeObjectForKey:@"NSConnections"] retain];
    _objectsKeys = [[coder decodeObjectForKey:@"NSObjectsKeys"] retain];
    _objectsValues = [[coder decodeObjectForKey:@"NSObjectsValues"] retain];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

- (void)dealloc
{
    [_root release];
    [_visibleWindows release];
    [_connections release];
    [_objectsKeys release];
    [_objectsValues release];
    [super dealloc];
}

/*
 * As Apple's: placeholders become the real objects (the owner for File's
 * Owner, NSApp for the application, nil for First Responder, a new instance
 * for any other custom object), the connections are made, every object that
 * wants it gets -awakeFromNib, and the windows marked visible are shown.
 */
- (BOOL)instantiateWithOwner:(id)owner topLevelObjects:(NSArray **)topLevel
{
    NSMapTable *real = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory |
                                                          NSPointerFunctionsOpaquePersonality
                                             valueOptions:NSPointerFunctionsStrongMemory];
    NSMutableArray *objects = [NSMutableArray array];
    for (id o in _objectsKeys) {
        id r = o;
        if (o == _root)
            r = owner;
        else if ([o isKindOfClass:[NSCustomObject class]])
            r = [(NSCustomObject *)o _finchRealize];
        if (r != o)
            [real setObject:r ?: [NSNull null] forKey:o];
        if (r)
            [objects addObject:r];
    }
    if (![_objectsKeys containsObject:_root])
        [real setObject:owner ?: [NSNull null] forKey:_root];
    for (NSNibConnector *c in _connections) {
        for (id o in @[ [c source] ?: [NSNull null], [c destination] ?: [NSNull null] ]) {
            id r = [real objectForKey:o];
            if (r)
                [c replaceObject:o withObject:r == [NSNull null] ? nil : r];
        }
    }
    for (NSNibConnector *c in _connections)
        [c establishConnection];
    /* top-level objects: those whose parent is File's Owner */
    NSMutableArray *top = [NSMutableArray array];
    for (NSUInteger i = 0; i < MIN([_objectsKeys count], [_objectsValues count]); i++) {
        id o = _objectsKeys[i];
        if (_objectsValues[i] == _root && o != _root) {
            id r = [real objectForKey:o] ?: o;
            if (r != [NSNull null] && r != owner)
                [top addObject:r];
        }
    }
    for (id o in objects)
        if (o != owner && [o respondsToSelector:@selector(awakeFromNib)])
            [o awakeFromNib];
    if ([owner respondsToSelector:@selector(awakeFromNib)])
        [owner awakeFromNib];
    BOOL first = YES;
    for (NSWindow *w in _visibleWindows) {
        if (![w isKindOfClass:[NSWindow class]])
            continue;
        if (first && [w canBecomeKeyWindow])
            [w makeKeyAndOrderFront:nil];
        else
            [w orderFront:nil];
        first = NO;
    }
    if (topLevel)
        *topLevel = top;
    /* Top-level objects are the caller's to keep, as with -instantiateWithOwner:topLevelObjects:. */
    return YES;
}

@end

#pragma mark - NSNib

@implementation NSNib {
    NSData *_data;
    NSBundle *_bundle;
}

/* A compiled nib: a file, or a directory holding keyedobjects*.nib. */
static NSData *
nib_data_at(NSString *path)
{
    BOOL dir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir])
        return nil;
    if (!dir)
        return [NSData dataWithContentsOfFile:path];
    NSArray *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *n in [names reverseObjectEnumerator])
        if ([n hasPrefix:@"keyedobjects"] && [n hasSuffix:@".nib"])
            return [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:n]];
    return nil;
}

- (instancetype)initWithNibNamed:(NSNibName)name bundle:(NSBundle *)bundle
{
    self = [super init];
    if (!self)
        return nil;
    if (!bundle)
        bundle = [NSBundle mainBundle];
    NSString *path = [name isAbsolutePath] ? name : [bundle pathForResource:name ofType:@"nib"];
    if (!path && [name hasSuffix:@".nib"])
        path = [bundle pathForResource:[name stringByDeletingPathExtension] ofType:@"nib"];
    _data = [nib_data_at(path) retain];
    _bundle = [bundle retain];
    if (!_data) {
        [self release];
        return nil;
    }
    return self;
}

- (instancetype)initWithNibData:(NSData *)data bundle:(NSBundle *)bundle
{
    self = [super init];
    if (self) {
        _data = [data copy];
        _bundle = [bundle retain];
    }
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url
{
    [NSException raise:NSInternalInconsistencyException format:@"Deprecated in 10.8."];
    return nil;
}

- (void)dealloc
{
    [_data release];
    [_bundle release];
    [super dealloc];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    _data = [[coder decodeObjectForKey:@"NSNibFileData"] retain];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_data forKey:@"NSNibFileData"];
}

- (BOOL)instantiateWithOwner:(id)owner topLevelObjects:(NSArray **)topLevelObjects
{
    NSIBObjectData *objectData = nil;
    if ([_data length] >= 10 && !memcmp([_data bytes], "NIBArchive", 10)) {
        FinchNibDecoder *decoder = [[FinchNibDecoder alloc] initWithData:_data];
        objectData = [[[decoder objectData] retain] autorelease];
        [decoder release];
    } else {
        NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:_data error:NULL];
        [u setRequiresSecureCoding:NO];
        objectData = [u decodeObjectForKey:@"IB.objectdata"];
        [u finishDecoding];
        [u release];
    }
    if (![objectData isKindOfClass:[NSIBObjectData class]])
        return NO;
    NSArray *top = nil;
    BOOL ok = [objectData instantiateWithOwner:owner topLevelObjects:&top];
    if (topLevelObjects)
        *topLevelObjects = top;
    else
        [top makeObjectsPerformSelector:@selector(retain)];  /* the old API: the owner keeps them */
    return ok;
}

- (BOOL)instantiateNibWithOwner:(id)owner topLevelObjects:(NSArray **)topLevelObjects
{
    BOOL ok = [self instantiateWithOwner:owner topLevelObjects:topLevelObjects];
    [*topLevelObjects makeObjectsPerformSelector:@selector(retain)];
    return ok;
}

- (BOOL)instantiateNibWithExternalNameTable:(NSDictionary *)table
{
    NSArray *top = nil;
    BOOL ok = [self instantiateWithOwner:table[NSNibOwner] topLevelObjects:&top];
    id holder = table[NSNibTopLevelObjects];
    if ([holder isKindOfClass:[NSMutableArray class]])
        [holder addObjectsFromArray:top];
    else
        [top makeObjectsPerformSelector:@selector(retain)];
    return ok;
}

@end

@implementation NSBundle (NSNibLoading)

- (BOOL)loadNibNamed:(NSNibName)name owner:(id)owner topLevelObjects:(NSArray **)topLevelObjects
{
    NSNib *nib = [[[NSNib alloc] initWithNibNamed:name bundle:self] autorelease];
    if (!nib)
        return NO;
    return [nib instantiateWithOwner:owner topLevelObjects:topLevelObjects];
}

+ (BOOL)loadNibNamed:(NSString *)name owner:(id)owner
{
    NSBundle *b = [owner isKindOfClass:[NSObject class]] ? [NSBundle bundleForClass:[owner class]] : nil;
    if (!b || ![b pathForResource:name ofType:@"nib"])
        b = [NSBundle mainBundle];
    return [b loadNibNamed:name owner:owner topLevelObjects:NULL];
}

+ (BOOL)loadNibFile:(NSString *)fileName externalNameTable:(NSDictionary *)context withZone:(NSZone *)zone
{
    NSNib *nib = [[[NSNib alloc] initWithNibNamed:fileName bundle:nil] autorelease];
    return nib ? [nib instantiateNibWithExternalNameTable:context] : NO;
}

- (BOOL)loadNibFile:(NSString *)fileName externalNameTable:(NSDictionary *)context withZone:(NSZone *)zone
{
    NSNib *nib = [[[NSNib alloc] initWithNibNamed:fileName bundle:self] autorelease];
    return nib ? [nib instantiateNibWithExternalNameTable:context] : NO;
}

@end
