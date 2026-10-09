/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSXPCConnection, NSXPCListener, NSXPCInterface, NSXPCListenerEndpoint and
 * NSXPCCoder (NSXPCEncoder, NSXPCDecoder), over Finch's libxpc
 * (docs/design/XPC.md, "NSXPC").
 *
 * A message sent to a remote object proxy becomes one xpc dictionary: the
 * selector, the number of the object it's for, and its arguments, each
 * encoded by the type the protocol's extended method encoding gives it
 * (scalars and structs by value, objects as secure-coded trees, proxies by
 * number). A reply block is the method's one block argument; the receiver
 * gets a block that forwards its call (libobjc's _objc_msgForward and an
 * NSInvocation) into an xpc reply, and the sender's reply block is called
 * with the reply's decoded arguments on the connection's serial queue.
 * Exported methods run on that queue too, with +currentConnection set.
 * The format is Finch's own; Finch talks NSXPC only to Finch.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <Block.h>
#include <os/lock.h>
#include <os/log.h>
#include <ptrauth.h>
#include <servers/bootstrap.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "Foundation_Finch.h"

/* libobjc: a protocol method's extended type encoding. */
const char *_protocol_getMethodTypeEncoding(Protocol *proto, SEL sel, BOOL isRequiredMethod, BOOL isInstanceMethod);
/* libxpc SPI. */
void xpc_connection_get_audit_token(xpc_connection_t connection, audit_token_t *token);
xpc_object_t xpc_connection_copy_entitlement_value(xpc_connection_t connection, const char *entitlement);
/* CoreFoundation SPI. */
CFTypeRef _CFXPCCreateCFObjectFromXPCObject(xpc_object_t object);
/* NSInvocation (CoreFoundation): call a function with the invocation's frame. */
@interface NSInvocation (FinchXPC)
- (void)invokeUsingIMP:(IMP)imp;
@end

NSString * const _NSXPCConnectionInvocationReplyToSelectorKey = @"_NSXPCConnectionInvocationReplyToSelectorKey";
NSString * const _NSXPCConnectionInvocationReplyUserInfoKey = @"_NSXPCConnectionInvocationReplyUserInfoKey";

/* MARK: - Wire format (docs/design/XPC.md) */

#define K_VERSION   "nsxpc"     /* uint64 1: an NSXPC message */
#define K_SELECTOR  "sel"       /* string */
#define K_PROXY     "proxy"     /* uint64: the target object (1: the exported object) */
#define K_ARGS      "args"      /* array: one value per argument */
#define K_REPLY     "reply"     /* bool: the sender waits for a reply */
#define K_RELEASE   "release"   /* uint64: a proxy number the receiver gives back */
#define K_COUNT     "count"     /* uint64: how many references it gives back */
#define K_CLASS     "$class"    /* string: the kind of an encoded object */

#define NSXPC_VERSION 1
#define ROOT_OBJECT 1

static os_log_t
xpc_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.apple.Foundation", "xpc"); });
    return log;
}

/* MARK: - Type encodings */

static const char *
skip_qualifiers(const char *t)
{
    while (*t && strchr("rnNoORVAj+", *t)) t++;
    return t;
}

static const char *
skip_balanced(const char *t, char open, char close)
{
    int depth = 0;
    while (*t) {
        if (*t == '"') {
            const char *q = strchr(t + 1, '"');
            t = q ? q + 1 : t + strlen(t);
            continue;
        }
        if (*t == open) depth++;
        else if (*t == close) depth--;
        t++;
        if (depth == 0) break;
    }
    return t;
}

/* The end of one (extended) type. */
static const char *
type_end(const char *t)
{
    t = skip_qualifiers(t);
    switch (*t) {
    case '\0':
        return t;
    case '@':
        t++;
        if (*t == '?') {
            t++;
            if (*t == '<') t = skip_balanced(t, '<', '>');
        } else if (*t == '"') {
            const char *q = strchr(t + 1, '"');
            t = q ? q + 1 : t + strlen(t);
        }
        return t;
    case '{': return skip_balanced(t, '{', '}');
    case '(': return skip_balanced(t, '(', ')');
    case '[': return skip_balanced(t, '[', ']');
    case '^': return type_end(t + 1);
    case 'b':
        t++;
        while (*t >= '0' && *t <= '9') t++;
        return t;
    default:
        return t + 1;
    }
}

/* [s, e) without class names, field names and block signatures. */
static char *
plain_copy(const char *s, const char *e)
{
    char *out = malloc((size_t)(e - s) + 1), *o = out;
    while (s < e) {
        if (*s == '"') {
            const char *q = memchr(s + 1, '"', (size_t)(e - s - 1));
            s = q ? q + 1 : e;
            continue;
        }
        if (*s == '<' && o - out >= 2 && o[-1] == '?' && o[-2] == '@') {
            s = skip_balanced(s, '<', '>');
            continue;
        }
        *o++ = *s++;
    }
    *o = 0;
    return out;
}

typedef struct {
    char *type;         /* plain encoding */
    char *className;    /* @"Name": Name (without protocols); NULL for id */
    char *block;        /* a block's extended signature (inside <>), or NULL */
    BOOL isBlock;
    BOOL isXPC;         /* declared as an xpc object (NSObject<OS_xpc_object>) */
} FinchXPCType;

static void
types_free(FinchXPCType *types, NSUInteger count)
{
    for (NSUInteger i = 0; i < count; i++) {
        free(types[i].type);
        free(types[i].className);
        free(types[i].block);
    }
    free(types);
}

/* Every type in an encoding, offsets skipped. */
static FinchXPCType *
types_parse(const char *enc, NSUInteger *count)
{
    NSUInteger n = 0, cap = 8;
    FinchXPCType *types = calloc(cap, sizeof(*types));
    const char *t = enc;
    while (*t) {
        const char *e = type_end(t);
        if (e == t) break;
        if (n == cap) {
            cap *= 2;
            types = realloc(types, cap * sizeof(*types));
        }
        FinchXPCType *ty = &types[n++];
        memset(ty, 0, sizeof(*ty));
        ty->type = plain_copy(t, e);
        const char *b = skip_qualifiers(t);
        if (b[0] == '@' && b[1] == '?') {
            ty->isBlock = YES;
            if (b[2] == '<') {
                const char *end = skip_balanced(b + 2, '<', '>');
                ty->block = strndup(b + 3, (size_t)(end - (b + 3) - 1));
            }
        } else if (b[0] == '@' && b[1] == '"') {
            const char *q = strchr(b + 2, '"');
            char *name = strndup(b + 2, q ? (size_t)(q - (b + 2)) : strlen(b + 2));
            if (strstr(name, "OS_xpc_object")) ty->isXPC = YES;
            char *lt = strchr(name, '<');
            if (lt) *lt = 0;
            if (*name) ty->className = name;
            else free(name);
        }
        t = e;
        while (*t == '-' || (*t >= '0' && *t <= '9')) t++;
    }
    *count = n;
    return types;
}

static NSMethodSignature *
signature_for(FinchXPCType *types, NSUInteger count)
{
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < count; i++) [s appendFormat:@"%s", types[i].type];
    return [NSMethodSignature signatureWithObjCTypes:s.UTF8String];
}

static NSSet *
plist_classes(void)
{
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [[NSSet alloc] initWithObjects:[NSArray class], [NSDictionary class], [NSSet class], [NSOrderedSet class],
            [NSString class], [NSNumber class], [NSData class], [NSDate class], [NSNull class], nil];
    });
    return set;
}

/* The classes an argument of this type accepts unless told otherwise, as
 * Apple's: the declared class, the property-list classes for collections
 * and id, nothing for anything that isn't an object. */
static NSSet *
default_classes(const FinchXPCType *ty)
{
    const char *t = skip_qualifiers(ty->type);
    if (t[0] != '@' || ty->isBlock) return [NSSet set];
    Class cls = ty->className ? objc_getClass(ty->className) : Nil;
    if (!cls) return plist_classes();
    for (Class c in @[[NSArray class], [NSDictionary class], [NSSet class], [NSOrderedSet class]])
        if ([cls isSubclassOfClass:c]) return plist_classes();
    return [NSSet setWithObject:cls];
}

/* MARK: - Methods of an interface */

__attribute__((visibility("hidden")))
@interface _NSXPCMethod : NSObject {
@public
    SEL _sel;
    NSMethodSignature *_signature;
    FinchXPCType *_types;               /* return, self, _cmd, arguments */
    NSUInteger _typeCount;
    NSUInteger _replyIndex;             /* argument number of the reply block, or NSNotFound */
    NSUInteger _blockCount;
    NSMethodSignature *_replySignature; /* the reply block's: argument 0 is the block */
    FinchXPCType *_replyTypes;          /* return, block, arguments */
    NSUInteger _replyTypeCount;
    NSMutableDictionary *_classes[2];   /* argument number -> NSSet; [1]: the reply's */
    NSMutableDictionary *_interfaces[2];
    NSMutableDictionary *_xpcTypes[2];
}
- (NSUInteger)argumentCount:(BOOL)ofReply;
- (FinchXPCType *)type:(NSUInteger)index ofReply:(BOOL)ofReply;
@end

@implementation _NSXPCMethod

- (instancetype)initWithSelector:(SEL)sel encoding:(const char *)enc
{
    if (!(self = [super init])) return nil;
    _sel = sel;
    _types = types_parse(enc, &_typeCount);
    _signature = [signature_for(_types, _typeCount) retain];
    _replyIndex = NSNotFound;
    for (NSUInteger i = 3; i < _typeCount; i++) {
        if (!_types[i].isBlock) continue;
        _blockCount++;
        if (_replyIndex == NSNotFound) _replyIndex = i - 3;
    }
    if (_replyIndex != NSNotFound && _types[_replyIndex + 3].block) {
        _replyTypes = types_parse(_types[_replyIndex + 3].block, &_replyTypeCount);
        _replySignature = [signature_for(_replyTypes, _replyTypeCount) retain];
    }
    for (int i = 0; i < 2; i++) {
        _classes[i] = [NSMutableDictionary new];
        _interfaces[i] = [NSMutableDictionary new];
        _xpcTypes[i] = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc
{
    types_free(_types, _typeCount);
    if (_replyTypes) types_free(_replyTypes, _replyTypeCount);
    [_signature release];
    [_replySignature release];
    for (int i = 0; i < 2; i++) {
        [_classes[i] release];
        [_interfaces[i] release];
        [_xpcTypes[i] release];
    }
    [super dealloc];
}

- (NSUInteger)argumentCount:(BOOL)ofReply
{
    if (ofReply) return _replyTypeCount >= 2 ? _replyTypeCount - 2 : 0;
    return _typeCount >= 3 ? _typeCount - 3 : 0;
}

- (FinchXPCType *)type:(NSUInteger)index ofReply:(BOOL)ofReply
{
    return ofReply ? &_replyTypes[index + 2] : &_types[index + 3];
}

@end

/* MARK: - NSXPCInterface */

@interface NSXPCInterface ()
- (_NSXPCMethod *)_methodForSelector:(SEL)sel;
- (NSSet *)_classesFor:(_NSXPCMethod *)m index:(NSUInteger)i ofReply:(BOOL)ofReply;
- (NSXPCInterface *)_interfaceFor:(_NSXPCMethod *)m index:(NSUInteger)i ofReply:(BOOL)ofReply;
- (xpc_type_t)_xpcTypeFor:(_NSXPCMethod *)m index:(NSUInteger)i ofReply:(BOOL)ofReply;
@end

@implementation NSXPCInterface {
    Protocol *_protocol;
    NSMutableDictionary *_methods;
    os_unfair_lock _lock;
}

+ (NSXPCInterface *)interfaceWithProtocol:(Protocol *)protocol
{
    NSXPCInterface *i = [[[self alloc] init] autorelease];
    i.protocol = protocol;
    return i;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _methods = [NSMutableDictionary new];
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc
{
    [_methods release];
    [super dealloc];
}

- (Protocol *)protocol { return _protocol; }

- (void)setProtocol:(Protocol *)protocol
{
    os_unfair_lock_lock(&_lock);
    _protocol = protocol;
    [_methods removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

/* nil when the selector isn't one of the protocol's instance methods. */
- (_NSXPCMethod *)_methodForSelector:(SEL)sel
{
    if (!_protocol || !sel) return nil;
    NSString *key = NSStringFromSelector(sel);
    os_unfair_lock_lock(&_lock);
    _NSXPCMethod *m = [[_methods objectForKey:key] retain];
    os_unfair_lock_unlock(&_lock);
    if (m) return [m autorelease];

    const char *enc = _protocol_getMethodTypeEncoding(_protocol, sel, YES, YES);
    if (!enc) enc = _protocol_getMethodTypeEncoding(_protocol, sel, NO, YES);
    if (!enc) {
        struct objc_method_description d = protocol_getMethodDescription(_protocol, sel, YES, YES);
        if (!d.types) d = protocol_getMethodDescription(_protocol, sel, NO, YES);
        enc = d.types;
    }
    if (!enc) return nil;
    m = [[_NSXPCMethod alloc] initWithSelector:sel encoding:enc];
    os_unfair_lock_lock(&_lock);
    _NSXPCMethod *existing = [_methods objectForKey:key];
    if (existing) {
        [m release];
        m = [existing retain];
    } else {
        [_methods setObject:m forKey:key];
    }
    os_unfair_lock_unlock(&_lock);
    return [m autorelease];
}

/* The method, or Apple's exception for a bad selector or index. */
- (_NSXPCMethod *)_checkedMethod:(SEL)sel index:(NSUInteger)arg ofReply:(BOOL)ofReply caller:(SEL)caller
{
    _NSXPCMethod *m = [self _methodForSelector:sel];
    if (!m)
        FinchRaise(NSInvalidArgumentException, "*** -[NSXPCInterface %s]: Selector '%s' is not in protocol '%s', or is not an instance method.",
            sel_getName(caller), sel ? sel_getName(sel) : "(null)", _protocol ? protocol_getName(_protocol) : "(null)");
    if (ofReply && m->_replyIndex == NSNotFound)
        FinchRaise(NSInvalidArgumentException, "*** -[NSXPCInterface %s]: Selector '%s' does not have a reply block.",
            sel_getName(caller), sel_getName(sel));
    NSUInteger count = [m argumentCount:ofReply];
    if (arg >= count)
        FinchRaise(NSInvalidArgumentException, "*** -[NSXPCInterface %s]: Argument index  '%lu' is out of range for selector %s. The maximum index is %lu.",
            sel_getName(caller), (unsigned long)arg, sel_getName(sel), (unsigned long)(count ? count - 1 : 0));
    return m;
}

- (void)setClasses:(NSSet *)classes forSelector:(SEL)sel argumentIndex:(NSUInteger)arg ofReply:(BOOL)ofReply
{
    _NSXPCMethod *m = [self _checkedMethod:sel index:arg ofReply:ofReply caller:_cmd];
    os_unfair_lock_lock(&_lock);
    [m->_classes[ofReply] setObject:[[classes copy] autorelease] forKey:@(arg)];
    os_unfair_lock_unlock(&_lock);
}

- (NSSet *)_classesFor:(_NSXPCMethod *)m index:(NSUInteger)i ofReply:(BOOL)ofReply
{
    os_unfair_lock_lock(&_lock);
    NSSet *set = [[m->_classes[ofReply] objectForKey:@(i)] retain];
    os_unfair_lock_unlock(&_lock);
    return set ? [set autorelease] : default_classes([m type:i ofReply:ofReply]);
}

- (NSSet *)classesForSelector:(SEL)sel argumentIndex:(NSUInteger)arg ofReply:(BOOL)ofReply
{
    _NSXPCMethod *m = [self _checkedMethod:sel index:arg ofReply:ofReply caller:_cmd];
    return [self _classesFor:m index:arg ofReply:ofReply];
}

- (void)setInterface:(NSXPCInterface *)ifc forSelector:(SEL)sel argumentIndex:(NSUInteger)arg ofReply:(BOOL)ofReply
{
    _NSXPCMethod *m = [self _checkedMethod:sel index:arg ofReply:ofReply caller:_cmd];
    os_unfair_lock_lock(&_lock);
    if (ifc) [m->_interfaces[ofReply] setObject:ifc forKey:@(arg)];
    else [m->_interfaces[ofReply] removeObjectForKey:@(arg)];
    os_unfair_lock_unlock(&_lock);
}

- (NSXPCInterface *)_interfaceFor:(_NSXPCMethod *)m index:(NSUInteger)i ofReply:(BOOL)ofReply
{
    os_unfair_lock_lock(&_lock);
    NSXPCInterface *ifc = [[m->_interfaces[ofReply] objectForKey:@(i)] retain];
    os_unfair_lock_unlock(&_lock);
    return [ifc autorelease];
}

- (NSXPCInterface *)interfaceForSelector:(SEL)sel argumentIndex:(NSUInteger)arg ofReply:(BOOL)ofReply
{
    _NSXPCMethod *m = [self _checkedMethod:sel index:arg ofReply:ofReply caller:_cmd];
    return [self _interfaceFor:m index:arg ofReply:ofReply];
}

- (void)setXPCType:(xpc_type_t)type forSelector:(SEL)sel argumentIndex:(NSUInteger)arg ofReply:(BOOL)ofReply
{
    _NSXPCMethod *m = [self _checkedMethod:sel index:arg ofReply:ofReply caller:_cmd];
    os_unfair_lock_lock(&_lock);
    if (type) [m->_xpcTypes[ofReply] setObject:[NSValue valueWithPointer:type] forKey:@(arg)];
    else [m->_xpcTypes[ofReply] removeObjectForKey:@(arg)];
    os_unfair_lock_unlock(&_lock);
}

- (xpc_type_t)_xpcTypeFor:(_NSXPCMethod *)m index:(NSUInteger)i ofReply:(BOOL)ofReply
{
    os_unfair_lock_lock(&_lock);
    xpc_type_t t = [[m->_xpcTypes[ofReply] objectForKey:@(i)] pointerValue];
    os_unfair_lock_unlock(&_lock);
    return t;
}

- (xpc_type_t)XPCTypeForSelector:(SEL)sel argumentIndex:(NSUInteger)arg ofReply:(BOOL)ofReply
{
    _NSXPCMethod *m = [self _checkedMethod:sel index:arg ofReply:ofReply caller:_cmd];
    return [self _xpcTypeFor:m index:arg ofReply:ofReply];
}

@end

/* MARK: - NSXPCCoder */

@implementation NSXPCCoder {
    id _userInfo;
}

- (void)dealloc
{
    [_userInfo release];
    [super dealloc];
}

- (id<NSObject>)userInfo { return _userInfo; }
- (void)setUserInfo:(id<NSObject>)userInfo
{
    [userInfo retain];
    [_userInfo release];
    _userInfo = userInfo;
}
- (NSXPCConnection *)connection { return nil; }
- (BOOL)allowsKeyedCoding { return YES; }
- (BOOL)requiresSecureCoding { return YES; }
- (void)encodeXPCObject:(xpc_object_t)xpcObject forKey:(NSString *)key { FinchAbstract(self, _cmd); }
- (xpc_object_t)decodeXPCObjectOfType:(xpc_type_t)type forKey:(NSString *)key { FinchAbstract(self, _cmd); }
- (xpc_object_t)decodeXPCObjectForKey:(NSString *)key { xpc_type_t any = NULL; return [self decodeXPCObjectOfType:any forKey:key]; }

@end

@class _NSXPCDistantObject;

@interface NSXPCConnection ()
- (xpc_object_t)_newProxyNumberForObject:(id)object interface:(NSXPCInterface *)iface;
- (id)_proxyForRemoteNumber:(uint64_t)number interface:(NSXPCInterface *)iface;
- (void)_sendInvocation:(NSInvocation *)inv method:(_NSXPCMethod *)m interface:(NSXPCInterface *)iface proxy:(_NSXPCDistantObject *)proxy;
- (void)_releaseRemoteNumber:(uint64_t)number;
- (xpc_object_t)_newArgumentsFrom:(NSInvocation *)inv method:(_NSXPCMethod *)m interface:(NSXPCInterface *)iface ofReply:(BOOL)ofReply;
- (void)_sendReply:(xpc_object_t)reply;
@end

/* MARK: - NSXPCEncoder */

@interface NSXPCEncoder : NSXPCCoder {
    NSXPCConnection *_connection;   /* not retained: lives for one message */
    xpc_object_t _dict;              /* the object being encoded */
    NSUInteger _sequence;            /* its next unkeyed value */
    NSUInteger _depth;
}
- (instancetype)_initWithConnection:(NSXPCConnection *)connection;
- (xpc_object_t)_newXPCObjectForObject:(id)object;
@end

static xpc_object_t
new_number(NSNumber *n)
{
    if (CFGetTypeID((CFTypeRef)n) == CFBooleanGetTypeID()) return xpc_bool_create([n boolValue]);
    switch (*[n objCType]) {
    case 'f': case 'd': case 'D':
        return xpc_double_create([n doubleValue]);
    case 'C': case 'S': case 'I': case 'L': case 'Q': {
        unsigned long long v = [n unsignedLongLongValue];
        return v > INT64_MAX ? xpc_uint64_create(v) : xpc_int64_create((int64_t)v);
    }
    default:
        return xpc_int64_create([n longLongValue]);
    }
}

static xpc_object_t
new_tagged(const char *tag)
{
    xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(d, K_CLASS, tag);
    return d;
}

@implementation NSXPCEncoder

- (instancetype)_initWithConnection:(NSXPCConnection *)connection
{
    if ((self = [super init])) _connection = connection;
    return self;
}

- (NSXPCConnection *)connection { return _connection; }

- (xpc_object_t)_newArrayOf:(id<NSFastEnumeration>)objects
{
    xpc_object_t a = xpc_array_create(NULL, 0);
    for (id o in objects) {
        xpc_object_t v = [self _newXPCObjectForObject:o];
        xpc_array_append_value(a, v);
        xpc_release(v);
    }
    return a;
}

/* An object's tree (+1). */
- (xpc_object_t)_newXPCObjectForObject:(id)object
{
    if (!object) return xpc_null_create();
    if ([object isKindOfClass:[NSString class]]) {
        const char *s = [object UTF8String];
        return xpc_string_create(s ? s : "");
    }
    if ([object isKindOfClass:[NSNumber class]] && ![object isKindOfClass:[NSDecimalNumber class]])
        return new_number(object);
    if ([object isKindOfClass:[NSData class]])
        return xpc_data_create([object bytes], [object length]);
    if ([object isKindOfClass:[NSArray class]])
        return [self _newArrayOf:object];
    if ((id)object == (id)kCFNull)
        return new_tagged("NSNull");
    if ([object isKindOfClass:[NSDate class]]) {
        xpc_object_t d = new_tagged("NSDate");
        xpc_dictionary_set_double(d, "time", [object timeIntervalSinceReferenceDate]);
        return d;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        xpc_object_t d = new_tagged("NSDictionary");
        xpc_object_t k = xpc_array_create(NULL, 0), v = xpc_array_create(NULL, 0);
        for (id key in object) {
            xpc_object_t ek = [self _newXPCObjectForObject:key], ev = [self _newXPCObjectForObject:[object objectForKey:key]];
            xpc_array_append_value(k, ek);
            xpc_array_append_value(v, ev);
            xpc_release(ek);
            xpc_release(ev);
        }
        xpc_dictionary_set_value(d, "keys", k);
        xpc_dictionary_set_value(d, "values", v);
        xpc_release(k);
        xpc_release(v);
        return d;
    }
    if ([object isKindOfClass:[NSSet class]] || [object isKindOfClass:[NSOrderedSet class]]) {
        xpc_object_t d = new_tagged([object isKindOfClass:[NSSet class]] ? "NSSet" : "NSOrderedSet");
        xpc_object_t o = [self _newArrayOf:object];
        xpc_dictionary_set_value(d, "objects", o);
        xpc_release(o);
        return d;
    }
    if ([object conformsToProtocol:@protocol(OS_xpc_object)]) {
        xpc_object_t d = new_tagged("$xpc");
        xpc_dictionary_set_value(d, "value", object);
        return d;
    }

    /* Anything else codes itself, keyed, into a dictionary of its own. */
    Class cls = [object classForCoder];
    if (!cls || ![cls respondsToSelector:@selector(supportsSecureCoding)] || ![(id)cls supportsSecureCoding] ||
        ![object respondsToSelector:@selector(encodeWithCoder:)])
        FinchRaise(NSInvalidArgumentException, "This coder only encodes objects that adopt NSSecureCoding (object is of class '%s').",
            cls ? class_getName(cls) : object_getClassName(object));
    if (_depth > 256)
        FinchRaise(NSInvalidArgumentException, "*** -[NSXPCEncoder encodeObject:forKey:]: object graph is too deep (a cycle?)");
    xpc_object_t d = new_tagged(class_getName(cls));
    xpc_object_t saved = _dict;
    NSUInteger savedSequence = _sequence;
    _dict = d;
    _sequence = 0;
    _depth++;
    @try {
        [object encodeWithCoder:self];
    } @catch (id e) {
        xpc_release(d);
        @throw;
    } @finally {
        _dict = saved;
        _sequence = savedSequence;
        _depth--;
    }
    return d;
}

- (void)_set:(xpc_object_t)value forKey:(NSString *)key
{
    if (!_dict)
        FinchRaise(NSInvalidArgumentException, "*** -[NSXPCEncoder %s]: no object is being encoded", sel_getName(_cmd));
    xpc_dictionary_set_value(_dict, key.UTF8String, value);
    xpc_release(value);
}

- (NSString *)_nextKey { return [NSString stringWithFormat:@"$%lu", (unsigned long)_sequence++]; }

- (void)encodeObject:(id)object forKey:(NSString *)key { if (object) [self _set:[self _newXPCObjectForObject:object] forKey:key]; }
- (void)encodeConditionalObject:(id)object forKey:(NSString *)key { [self encodeObject:object forKey:key]; }
- (void)encodeBool:(BOOL)value forKey:(NSString *)key { [self _set:xpc_bool_create(value) forKey:key]; }
- (void)encodeInt:(int)value forKey:(NSString *)key { [self _set:xpc_int64_create(value) forKey:key]; }
- (void)encodeInt32:(int32_t)value forKey:(NSString *)key { [self _set:xpc_int64_create(value) forKey:key]; }
- (void)encodeInt64:(int64_t)value forKey:(NSString *)key { [self _set:xpc_int64_create(value) forKey:key]; }
- (void)encodeInteger:(NSInteger)value forKey:(NSString *)key { [self _set:xpc_int64_create(value) forKey:key]; }
- (void)encodeFloat:(float)value forKey:(NSString *)key { [self _set:xpc_double_create(value) forKey:key]; }
- (void)encodeDouble:(double)value forKey:(NSString *)key { [self _set:xpc_double_create(value) forKey:key]; }
- (void)encodeBytes:(const uint8_t *)bytes length:(NSUInteger)length forKey:(NSString *)key
{
    [self _set:xpc_data_create(bytes, length) forKey:key];
}

- (void)encodeXPCObject:(xpc_object_t)xpcObject forKey:(NSString *)key
{
    if (!xpcObject) return;
    xpc_object_t d = new_tagged("$xpc");
    xpc_dictionary_set_value(d, "value", xpcObject);
    [self _set:d forKey:key];
}

/* Unkeyed coding, in order, under "$0", "$1"... */
- (void)encodeValueOfObjCType:(const char *)type at:(const void *)addr
{
    const char *t = skip_qualifiers(type);
    NSString *key = [self _nextKey];
    switch (*t) {
    case '@': case '#':
        if (*t == '#') [self encodeObject:*(Class *)addr ? NSStringFromClass(*(Class *)addr) : nil forKey:key];
        else [self encodeObject:*(id *)addr forKey:key];
        return;
    case 'c': [self encodeInt64:*(const signed char *)addr forKey:key]; return;
    case 'C': [self encodeInt64:*(const unsigned char *)addr forKey:key]; return;
    case 's': [self encodeInt64:*(const short *)addr forKey:key]; return;
    case 'S': [self encodeInt64:*(const unsigned short *)addr forKey:key]; return;
    case 'i': case 'l': [self encodeInt64:*(const int *)addr forKey:key]; return;
    case 'I': case 'L': [self encodeInt64:*(const unsigned int *)addr forKey:key]; return;
    case 'q': [self encodeInt64:*(const long long *)addr forKey:key]; return;
    case 'Q': [self _set:xpc_uint64_create(*(const unsigned long long *)addr) forKey:key]; return;
    case 'B': [self encodeBool:*(const bool *)addr forKey:key]; return;
    case 'f': [self encodeDouble:*(const float *)addr forKey:key]; return;
    case 'd': [self encodeDouble:*(const double *)addr forKey:key]; return;
    case '*': {
        const char *s = *(const char * const *)addr;
        [self encodeObject:s ? [NSString stringWithUTF8String:s] : nil forKey:key];
        return;
    }
    case ':': [self encodeObject:*(SEL *)addr ? NSStringFromSelector(*(SEL *)addr) : nil forKey:key]; return;
    default: {
        NSUInteger size = 0;
        NSGetSizeAndAlignment(t, &size, NULL);
        [self encodeBytes:addr length:size forKey:key];
        return;
    }
    }
}

- (void)encodeDataObject:(NSData *)data { [self encodeObject:data forKey:[self _nextKey]]; }
- (void)encodeObject:(id)object { [self encodeObject:object forKey:[self _nextKey]]; }
- (void)encodeBytes:(const void *)bytes length:(NSUInteger)length { [self encodeBytes:bytes length:length forKey:[self _nextKey]]; }
- (NSInteger)versionForClassName:(NSString *)className { return 0; }

@end

/* MARK: - NSXPCDecoder */

@interface NSXPCDecoder : NSXPCCoder {
    NSXPCConnection *_connection;   /* not retained */
    xpc_object_t _dict;
    NSUInteger _sequence;
    NSSet *_allowed;                 /* of the object being decoded */
    NSUInteger _depth;
}
- (instancetype)_initWithConnection:(NSXPCConnection *)connection;
- (id)_objectFromXPC:(xpc_object_t)x classes:(NSSet *)classes key:(NSString *)key;
@end

static BOOL
class_allowed(Class cls, NSSet *allowed)
{
    for (Class c in allowed) if ([cls isSubclassOfClass:c]) return YES;
    return NO;
}

static __attribute__((noreturn)) void
reject(Class cls, NSString *key, NSSet *allowed)
{
    NSMutableArray *names = [NSMutableArray array];
    for (Class c in allowed) [names addObject:[NSString stringWithFormat:@"'%@'", NSStringFromClass(c)]];
    [names sortUsingSelector:@selector(compare:)];
    FinchRaise(NSInvalidUnarchiveOperationException, "value for key '%s' was of unexpected class '%s'. Allowed classes are '{(%s)}'.",
        key.UTF8String, class_getName(cls), [names componentsJoinedByString:@", "].UTF8String);
}

static double
number_value(xpc_object_t v, int64_t *i, uint64_t *u)
{
    xpc_type_t t = v ? xpc_get_type(v) : NULL;
    double d = 0;
    int64_t si = 0;
    uint64_t ui = 0;
    if (t == XPC_TYPE_INT64) {
        si = xpc_int64_get_value(v); ui = (uint64_t)si; d = (double)si;
    } else if (t == XPC_TYPE_UINT64) {
        ui = xpc_uint64_get_value(v); si = (int64_t)ui; d = (double)ui;
    } else if (t == XPC_TYPE_BOOL) {
        si = xpc_bool_get_value(v); ui = (uint64_t)si; d = (double)si;
    } else if (t == XPC_TYPE_DOUBLE) {
        d = xpc_double_get_value(v); si = (int64_t)d; ui = (uint64_t)d;
    }
    if (i) *i = si;
    if (u) *u = ui;
    return d;
}

@implementation NSXPCDecoder

- (instancetype)_initWithConnection:(NSXPCConnection *)connection
{
    if ((self = [super init])) _connection = connection;
    return self;
}

- (NSXPCConnection *)connection { return _connection; }
- (NSSet *)allowedClasses { return _allowed; }
- (NSDecodingFailurePolicy)decodingFailurePolicy { return NSDecodingFailurePolicyRaiseException; }
- (void)failWithError:(NSError *)error
{
    FinchRaise(NSInvalidUnarchiveOperationException, "%s", [[error description] UTF8String]);
}

- (NSArray *)_arrayFrom:(xpc_object_t)a classes:(NSSet *)classes key:(NSString *)key
{
    if (!a || xpc_get_type(a) != XPC_TYPE_ARRAY)
        FinchRaise(NSInvalidUnarchiveOperationException, "*** NSXPCDecoder: malformed collection for key '%s'", key.UTF8String);
    size_t n = xpc_array_get_count(a);
    id *objects = n ? malloc(n * sizeof(id)) : NULL;
    @try {
        for (size_t i = 0; i < n; i++) {
            id o = [self _objectFromXPC:xpc_array_get_value(a, i) classes:classes key:key];
            objects[i] = o ? o : (id)kCFNull;
        }
        return [NSArray arrayWithObjects:objects count:n];
    } @finally {
        free(objects);
    }
}

/* An object from its tree, if its class is one of `classes`. */
- (id)_objectFromXPC:(xpc_object_t)x classes:(NSSet *)classes key:(NSString *)key
{
    xpc_type_t t = x ? xpc_get_type(x) : XPC_TYPE_NULL;
    Class cls = Nil;
    if (t == XPC_TYPE_NULL) return nil;
    if (t == XPC_TYPE_STRING) cls = [NSString class];
    else if (t == XPC_TYPE_INT64 || t == XPC_TYPE_UINT64 || t == XPC_TYPE_DOUBLE || t == XPC_TYPE_BOOL) cls = [NSNumber class];
    else if (t == XPC_TYPE_DATA) cls = [NSData class];
    else if (t == XPC_TYPE_ARRAY) cls = [NSArray class];
    if (cls) {
        if (!class_allowed(cls, classes)) reject(cls, key, classes);
        if (t == XPC_TYPE_STRING) return [NSString stringWithUTF8String:xpc_string_get_string_ptr(x)];
        if (t == XPC_TYPE_BOOL) return xpc_bool_get_value(x) ? (id)kCFBooleanTrue : (id)kCFBooleanFalse;
        if (t == XPC_TYPE_INT64) return [NSNumber numberWithLongLong:xpc_int64_get_value(x)];
        if (t == XPC_TYPE_UINT64) return [NSNumber numberWithUnsignedLongLong:xpc_uint64_get_value(x)];
        if (t == XPC_TYPE_DOUBLE) return [NSNumber numberWithDouble:xpc_double_get_value(x)];
        if (t == XPC_TYPE_DATA) return [NSData dataWithBytes:xpc_data_get_bytes_ptr(x) length:xpc_data_get_length(x)];
        return [self _arrayFrom:x classes:classes key:key];
    }
    if (t != XPC_TYPE_DICTIONARY) {
        /* A bare xpc object (an endpoint, a file descriptor...). */
        if (!class_allowed(object_getClass(x), classes)) reject(object_getClass(x), key, classes);
        return x;
    }

    const char *tag = xpc_dictionary_get_string(x, K_CLASS);
    if (!tag) FinchRaise(NSInvalidUnarchiveOperationException, "*** NSXPCDecoder: malformed object for key '%s'", key.UTF8String);
    if (strcmp(tag, "NSDictionary") == 0) {
        if (!class_allowed([NSDictionary class], classes)) reject([NSDictionary class], key, classes);
        NSArray *k = [self _arrayFrom:xpc_dictionary_get_value(x, "keys") classes:classes key:key];
        NSArray *v = [self _arrayFrom:xpc_dictionary_get_value(x, "values") classes:classes key:key];
        if (k.count != v.count) FinchRaise(NSInvalidUnarchiveOperationException, "*** NSXPCDecoder: malformed dictionary for key '%s'", key.UTF8String);
        return [NSDictionary dictionaryWithObjects:v forKeys:k];
    }
    if (strcmp(tag, "NSSet") == 0 || strcmp(tag, "NSOrderedSet") == 0) {
        Class c = tag[2] == 'S' ? [NSSet class] : [NSOrderedSet class];
        if (!class_allowed(c, classes)) reject(c, key, classes);
        NSArray *o = [self _arrayFrom:xpc_dictionary_get_value(x, "objects") classes:classes key:key];
        return c == [NSSet class] ? (id)[NSSet setWithArray:o] : (id)[NSOrderedSet orderedSetWithArray:o];
    }
    if (strcmp(tag, "NSDate") == 0) {
        if (!class_allowed([NSDate class], classes)) reject([NSDate class], key, classes);
        return [NSDate dateWithTimeIntervalSinceReferenceDate:xpc_dictionary_get_double(x, "time")];
    }
    if (strcmp(tag, "NSNull") == 0) {
        if (!class_allowed([NSNull class], classes)) reject([NSNull class], key, classes);
        return [NSNull null];
    }
    if (strcmp(tag, "$xpc") == 0) {
        xpc_object_t v = xpc_dictionary_get_value(x, "value");
        if (!v || !class_allowed(object_getClass(v), classes)) reject(v ? object_getClass(v) : [NSNull class], key, classes);
        return v;
    }
    if (tag[0] == '$')
        FinchRaise(NSInvalidUnarchiveOperationException, "*** NSXPCDecoder: unexpected '%s' for key '%s'", tag, key.UTF8String);

    cls = objc_getClass(tag);
    if (!cls)
        FinchRaise(NSInvalidUnarchiveOperationException, "*** NSXPCDecoder: class '%s' for key '%s' does not exist", tag, key.UTF8String);
    if (!class_allowed(cls, classes)) reject(cls, key, classes);
    if (![cls respondsToSelector:@selector(supportsSecureCoding)] || ![(id)cls supportsSecureCoding])
        FinchRaise(NSInvalidUnarchiveOperationException, "*** NSXPCDecoder: class '%s' does not adopt NSSecureCoding", tag);
    if (_depth > 256)
        FinchRaise(NSInvalidUnarchiveOperationException, "*** NSXPCDecoder: object graph is too deep");

    xpc_object_t savedDict = _dict;
    NSUInteger savedSequence = _sequence;
    NSSet *savedAllowed = _allowed;
    _dict = x;
    _sequence = 0;
    _allowed = classes;
    _depth++;
    id object = nil;
    @try {
        object = [[cls alloc] initWithCoder:self];
        id replacement = [object awakeAfterUsingCoder:self];
        if (replacement != object) {
            [replacement retain];
            [object release];
            object = replacement;
        }
    } @finally {
        _dict = savedDict;
        _sequence = savedSequence;
        _allowed = savedAllowed;
        _depth--;
    }
    return [object autorelease];
}

- (xpc_object_t)_get:(NSString *)key
{
    return _dict ? xpc_dictionary_get_value(_dict, key.UTF8String) : NULL;
}

- (BOOL)containsValueForKey:(NSString *)key { return [self _get:key] != NULL; }

- (id)decodeObjectOfClasses:(NSSet *)classes forKey:(NSString *)key
{
    return [self _objectFromXPC:[self _get:key] classes:classes key:key];
}

- (id)decodeObjectForKey:(NSString *)key
{
    return [self _objectFromXPC:[self _get:key] classes:_allowed key:key];
}

- (id)decodeTopLevelObjectForKey:(NSString *)key error:(NSError **)error { return [self decodeObjectForKey:key]; }
- (BOOL)decodeBoolForKey:(NSString *)key { int64_t i; number_value([self _get:key], &i, NULL); return i != 0; }
- (int)decodeIntForKey:(NSString *)key { int64_t i; number_value([self _get:key], &i, NULL); return (int)i; }
- (int32_t)decodeInt32ForKey:(NSString *)key { int64_t i; number_value([self _get:key], &i, NULL); return (int32_t)i; }
- (int64_t)decodeInt64ForKey:(NSString *)key { int64_t i; number_value([self _get:key], &i, NULL); return i; }
- (NSInteger)decodeIntegerForKey:(NSString *)key { int64_t i; number_value([self _get:key], &i, NULL); return (NSInteger)i; }
- (float)decodeFloatForKey:(NSString *)key { return (float)number_value([self _get:key], NULL, NULL); }
- (double)decodeDoubleForKey:(NSString *)key { return number_value([self _get:key], NULL, NULL); }

- (const uint8_t *)decodeBytesForKey:(NSString *)key returnedLength:(NSUInteger *)lengthp
{
    xpc_object_t v = [self _get:key];
    if (!v || xpc_get_type(v) != XPC_TYPE_DATA) {
        if (lengthp) *lengthp = 0;
        return NULL;
    }
    if (lengthp) *lengthp = xpc_data_get_length(v);
    return xpc_data_get_bytes_ptr(v);
}

- (xpc_object_t)decodeXPCObjectOfType:(xpc_type_t)type forKey:(NSString *)key
{
    xpc_object_t d = [self _get:key];
    if (!d || xpc_get_type(d) != XPC_TYPE_DICTIONARY) return NULL;
    const char *tag = xpc_dictionary_get_string(d, K_CLASS);
    if (!tag || strcmp(tag, "$xpc") != 0) return NULL;
    xpc_object_t v = xpc_dictionary_get_value(d, "value");
    if (type && v && xpc_get_type(v) != type) return NULL;
    return v;
}

- (NSString *)_nextKey { return [NSString stringWithFormat:@"$%lu", (unsigned long)_sequence++]; }

- (void)decodeValueOfObjCType:(const char *)type at:(void *)addr size:(NSUInteger)size
{
    const char *t = skip_qualifiers(type);
    NSString *key = [self _nextKey];
    xpc_object_t v = [self _get:key];
    int64_t i;
    uint64_t u;
    double d = number_value(v, &i, &u);
    switch (*t) {
    case '@': *(id *)addr = [[self decodeObjectForKey:key] retain]; return;   /* +1, as NSCoder's contract */
    case '#': *(Class *)addr = NSClassFromString([self decodeObjectOfClass:[NSString class] forKey:key]); return;
    case 'c': *(signed char *)addr = (signed char)i; return;
    case 'C': *(unsigned char *)addr = (unsigned char)u; return;
    case 's': *(short *)addr = (short)i; return;
    case 'S': *(unsigned short *)addr = (unsigned short)u; return;
    case 'i': case 'l': *(int *)addr = (int)i; return;
    case 'I': case 'L': *(unsigned int *)addr = (unsigned int)u; return;
    case 'q': *(long long *)addr = i; return;
    case 'Q': *(unsigned long long *)addr = u; return;
    case 'B': *(bool *)addr = i != 0; return;
    case 'f': *(float *)addr = (float)d; return;
    case 'd': *(double *)addr = d; return;
    case '*': *(const char **)addr = [[self decodeObjectOfClass:[NSString class] forKey:key] UTF8String]; return;
    case ':': *(SEL *)addr = NSSelectorFromString([self decodeObjectOfClass:[NSString class] forKey:key]); return;
    default: {
        NSUInteger len = 0;
        const uint8_t *bytes = [self decodeBytesForKey:key returnedLength:&len];
        NSUInteger want = size;
        if (!want) NSGetSizeAndAlignment(t, &want, NULL);
        memset(addr, 0, want);
        if (bytes) memcpy(addr, bytes, len < want ? len : want);
        return;
    }
    }
}

- (NSData *)decodeDataObject { return [self decodeObjectOfClass:[NSData class] forKey:[self _nextKey]]; }
- (id)decodeObject { return [self decodeObjectForKey:[self _nextKey]]; }
- (NSInteger)versionForClassName:(NSString *)className { return 0; }

@end

/* MARK: - NSXPCListenerEndpoint */

@implementation NSXPCListenerEndpoint {
    xpc_object_t _endpoint;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (void)dealloc
{
    if (_endpoint) xpc_release(_endpoint);
    [super dealloc];
}

- (xpc_object_t)_endpoint { return _endpoint; }

- (void)_setEndpoint:(xpc_object_t)endpoint
{
    if (endpoint) xpc_retain(endpoint);
    if (_endpoint) xpc_release(_endpoint);
    _endpoint = endpoint;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder isKindOfClass:[NSXPCCoder class]])
        FinchRaise(NSInvalidArgumentException, "*** -[NSXPCListenerEndpoint encodeWithCoder:]: This class may only be encoded by an NSXPCCoder.");
    [(NSXPCCoder *)coder encodeXPCObject:_endpoint forKey:@"ep"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (![coder isKindOfClass:[NSXPCCoder class]]) {
        [self release];
        FinchRaise(NSInvalidArgumentException, "*** -[NSXPCListenerEndpoint initWithCoder:]: This class may only be decoded by an NSXPCCoder.");
    }
    if ((self = [super init])) [self _setEndpoint:[(NSXPCCoder *)coder decodeXPCObjectOfType:XPC_TYPE_ENDPOINT forKey:@"ep"]];
    return self;
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSXPCListenerEndpoint class]]) return NO;
    xpc_object_t o = [other _endpoint];
    return _endpoint && o && xpc_equal(_endpoint, o);
}

- (NSUInteger)hash { return _endpoint ? xpc_hash(_endpoint) : 0; }

@end

/* MARK: - Remote object proxies */

@interface _NSXPCDistantObject : NSObject <NSXPCProxyCreating> {
@public
    NSXPCConnection *_connection;
    NSXPCInterface *_interface;      /* nil: the connection's remoteObjectInterface */
    uint64_t _number;                 /* the remote object (ROOT_OBJECT: its exported object) */
    id _errorHandler;
    BOOL _synchronous;
    BOOL _owner;                      /* gives _number back when deallocated */
    _NSXPCDistantObject *_parent;     /* the owner this proxy was made from */
}
@end

static Class
proxy_class(Protocol *protocol)
{
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    if (!protocol) return [_NSXPCDistantObject class];
    char name[512];
    snprintf(name, sizeof(name), "__NSXPCInterfaceProxy_%s", protocol_getName(protocol));
    os_unfair_lock_lock(&lock);
    Class cls = objc_getClass(name);
    if (!cls) {
        cls = objc_allocateClassPair([_NSXPCDistantObject class], name, 0);
        class_addProtocol(cls, protocol);
        objc_registerClassPair(cls);
    }
    os_unfair_lock_unlock(&lock);
    return cls;
}

static _NSXPCDistantObject *
new_proxy(NSXPCConnection *connection, NSXPCInterface *iface, uint64_t number, id errorHandler, BOOL synchronous)
{
    NSXPCInterface *protocolSource = iface ? iface : connection.remoteObjectInterface;
    _NSXPCDistantObject *p = [proxy_class(protocolSource.protocol) new];
    p->_connection = [connection retain];
    p->_interface = [iface retain];
    p->_number = number;
    p->_errorHandler = [errorHandler copy];
    p->_synchronous = synchronous;
    return p;
}

@implementation _NSXPCDistantObject

- (void)dealloc
{
    if (_owner) [_connection _releaseRemoteNumber:_number];
    [_connection release];
    [_interface release];
    [_errorHandler release];
    [_parent release];
    [super dealloc];
}

- (NSXPCInterface *)_interface { return _interface ? _interface : _connection.remoteObjectInterface; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    _NSXPCMethod *m = [[self _interface] _methodForSelector:sel];
    return m ? m->_signature : [super methodSignatureForSelector:sel];
}

- (BOOL)respondsToSelector:(SEL)sel
{
    return [[self _interface] _methodForSelector:sel] != nil || [super respondsToSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)inv
{
    NSXPCInterface *iface = [self _interface];
    _NSXPCMethod *m = [iface _methodForSelector:[inv selector]];
    if (!m) {
        [super forwardInvocation:inv];
        return;
    }
    [_connection _sendInvocation:inv method:m interface:iface proxy:self];
}

- (id)_proxyWithErrorHandler:(id)handler synchronous:(BOOL)synchronous
{
    _NSXPCDistantObject *p = new_proxy(_connection, _interface, _number, handler, synchronous);
    p->_parent = [(_owner ? self : _parent) retain];
    return [p autorelease];
}

- (id)remoteObjectProxy { return [self _proxyWithErrorHandler:nil synchronous:NO]; }
- (id)remoteObjectProxyWithErrorHandler:(void (^)(NSError *))handler { return [self _proxyWithErrorHandler:handler synchronous:NO]; }
- (id)synchronousRemoteObjectProxyWithErrorHandler:(void (^)(NSError *))handler { return [self _proxyWithErrorHandler:handler synchronous:YES]; }

@end

/* MARK: - Reply blocks
 *
 * The receiver of a message with a reply block gets a heap block whose
 * invoke function is _objc_msgForward: calling it with any arguments
 * reaches CoreFoundation's forwarding, which asks the block's class (a
 * subclass of __NSMallocBlock__) for a signature (the reply block's) and
 * hands it an NSInvocation, which becomes the reply. The block captures the
 * _NSXPCReplyForwarder that knows the request. */

struct finch_block {
    void *isa;
    volatile int32_t flags;
    int32_t reserved;
    void *invoke;
    void *descriptor;
    id captured;        /* the first captured variable */
};

__attribute__((visibility("hidden")))
@interface _NSXPCReplyForwarder : NSObject {
@public
    NSXPCConnection *_connection;
    xpc_object_t _request;          /* NULL when the sender doesn't wait for a reply */
    _NSXPCMethod *_method;
    NSXPCInterface *_interface;
    atomic_bool _sent;
}
@end

@implementation _NSXPCReplyForwarder

- (void)dealloc
{
    [_connection release];
    if (_request) xpc_release(_request);
    [_method release];
    [_interface release];
    [super dealloc];
}

- (void)sendReplyWithInvocation:(NSInvocation *)inv
{
    if (atomic_exchange(&_sent, true)) {
        os_log_fault(xpc_log(), "NSXPCConnection: the reply block for %{public}s was called more than once",
            sel_getName(_method->_sel));
        return;
    }
    if (!_request) return;
    xpc_object_t args = [_connection _newArgumentsFrom:inv method:_method interface:_interface ofReply:YES];
    xpc_object_t reply = xpc_dictionary_create_reply(_request);
    if (reply) {
        xpc_dictionary_set_uint64(reply, K_VERSION, NSXPC_VERSION);
        xpc_dictionary_set_value(reply, K_ARGS, args);
        [_connection _sendReply:reply];
        xpc_release(reply);
    }
    xpc_release(args);
}

@end

static _NSXPCReplyForwarder *
block_forwarder(id block)
{
    return ((struct finch_block *)block)->captured;
}

static NSMethodSignature *
reply_block_signature(id self, SEL _cmd, SEL sel)
{
    return block_forwarder(self)->_method->_replySignature;
}

static void
reply_block_forward(id self, SEL _cmd, NSInvocation *inv)
{
    [block_forwarder(self) sendReplyWithInvocation:inv];
}

static id
reply_block_target(id self, SEL _cmd, SEL sel)
{
    return nil;
}

static Class
reply_block_class(void)
{
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_allocateClassPair(objc_getClass("__NSMallocBlock__"), "__NSXPCReplyBlock", 0);
        class_addMethod(cls, @selector(methodSignatureForSelector:), (IMP)reply_block_signature, "@@::");
        class_addMethod(cls, @selector(forwardInvocation:), (IMP)reply_block_forward, "v@:@");
        class_addMethod(cls, @selector(forwardingTargetForSelector:), (IMP)reply_block_target, "@@::");
        objc_registerClassPair(cls);
    });
    return cls;
}

/* A reply block (+1) that sends its arguments as the reply. */
static id
new_reply_block(_NSXPCReplyForwarder *forwarder)
{
    void (^template)(void) = ^{ [forwarder self]; };
    struct finch_block *b = (struct finch_block *)Block_copy(template);   /* retains the forwarder */
    void *fn = (void *)_objc_msgForward;
#if __has_feature(ptrauth_calls)
    b->invoke = ptrauth_auth_and_resign(fn, ptrauth_key_function_pointer, 0, ptrauth_key_block_function, &b->invoke);
#else
    b->invoke = fn;
#endif
    object_setClass((id)b, reply_block_class());
    return (id)b;
}

/* A block's invoke function, signed as an ordinary function pointer. */
static IMP
block_function(id block)
{
    struct finch_block *b = (struct finch_block *)block;
#if __has_feature(ptrauth_calls)
    return (IMP)ptrauth_auth_and_resign(b->invoke, ptrauth_key_block_function, &b->invoke, ptrauth_key_function_pointer, 0);
#else
    return (IMP)b->invoke;
#endif
}

/* MARK: - NSXPCConnection */

typedef enum { FinchXPCNone, FinchXPCNamed, FinchXPCEndpoint, FinchXPCPeer } FinchXPCKind;

__attribute__((visibility("hidden")))
@interface _NSXPCPendingReply : NSObject {
@public
    id _block;
    id _errorHandler;
    _NSXPCMethod *_method;
    NSXPCInterface *_interface;
}
@end

@implementation _NSXPCPendingReply
- (void)dealloc
{
    [_block release];
    [_errorHandler release];
    [_method release];
    [_interface release];
    [super dealloc];
}
@end

/* An object this side exported by passing it as a proxy argument. */
__attribute__((visibility("hidden")))
@interface _NSXPCExport : NSObject {
@public
    id _object;
    NSXPCInterface *_interface;
    uint64_t _number;
    uint64_t _count;
}
@end

@implementation _NSXPCExport
- (void)dealloc
{
    [_object release];
    [_interface release];
    [super dealloc];
}
@end

static __thread NSXPCConnection *current_connection;

@implementation NSXPCConnection {
    xpc_connection_t _xconn;
    dispatch_queue_t _queue;
    FinchXPCKind _kind;
    NSString *_serviceName;
    NSString *_listenerName;           /* peers: the Mach service they came in on */
    NSXPCListenerEndpoint *_endpoint;
    uint64_t _flags;
    os_unfair_lock _lock;
    NSXPCInterface *_exportedInterface, *_remoteObjectInterface;
    id _exportedObject;
    void (^_interruptionHandler)(void);
    void (^_invalidationHandler)(void);
    id _userInfo;
    BOOL _activated, _invalid, _invalidatedHere, _lookupFailed, _handledInvalid;
    pid_t _stalePid;
    uint64_t _sequence;
    NSMutableDictionary *_pending;     /* sequence -> _NSXPCPendingReply */
    CFMutableDictionaryRef _exportsByObject;   /* object (by identity) -> _NSXPCExport */
    NSMutableDictionary *_exportsByNumber;     /* number -> _NSXPCExport */
    uint64_t _nextExport;
}

+ (NSXPCConnection *)currentConnection { return [[current_connection retain] autorelease]; }

- (void)_setUp:(NSString *)label
{
    _lock = OS_UNFAIR_LOCK_INIT;
    _pending = [NSMutableDictionary new];
    _exportsByNumber = [NSMutableDictionary new];
    _exportsByObject = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    _nextExport = ROOT_OBJECT + 1;
    _queue = dispatch_queue_create(label.UTF8String, DISPATCH_QUEUE_SERIAL);
}

/* Events come in on libxpc's queue (which targets ours) and are handled on
 * ours, in order. The handler keeps the connection alive until it's invalid. */
- (void)_installHandler
{
    if (!_xconn) return;
    xpc_connection_set_event_handler(_xconn, ^(xpc_object_t event) {
        dispatch_async(_queue, ^{ [self _handleEvent:event]; });
    });
}

- (instancetype)init
{
    if ((self = [super init])) {
        [self _setUp:@"com.apple.NSXPCConnection.user"];
        _invalid = YES;
    }
    return self;
}

- (instancetype)_initWithName:(NSString *)name flags:(uint64_t)flags mach:(BOOL)mach
{
    if (!(self = [super init])) return nil;
    _kind = FinchXPCNamed;
    _serviceName = [name copy];
    _flags = flags;
    [self _setUp:[@"com.apple.NSXPCConnection.user." stringByAppendingString:name ?: @""]];
    if (mach) _xconn = xpc_connection_create_mach_service(name.UTF8String, _queue, flags);
    else _xconn = xpc_connection_create(name.UTF8String, _queue);
    if (!_xconn) _invalid = YES;
    [self _installHandler];
    return self;
}

- (instancetype)initWithServiceName:(NSString *)serviceName
{
    if (!serviceName) FinchRaise(NSInvalidArgumentException, "*** -[NSXPCConnection initWithServiceName:]: service name must not be nil");
    return [self _initWithName:serviceName flags:0 mach:NO];
}

- (instancetype)initWithServiceName:(NSString *)serviceName options:(NSXPCConnectionOptions)options
{
    return [self initWithServiceName:serviceName];
}

- (instancetype)initWithMachServiceName:(NSString *)name options:(NSXPCConnectionOptions)options
{
    if (!name) FinchRaise(NSInvalidArgumentException, "*** -[NSXPCConnection initWithMachServiceName:options:]: service name must not be nil");
    return [self _initWithName:name flags:(options & NSXPCConnectionPrivileged) ? XPC_CONNECTION_MACH_SERVICE_PRIVILEGED : 0 mach:YES];
}

- (instancetype)initWithMachServiceName:(NSString *)name { return [self initWithMachServiceName:name options:0]; }

- (instancetype)initWithListenerEndpoint:(NSXPCListenerEndpoint *)endpoint
{
    if (!(self = [super init])) return nil;
    _kind = FinchXPCEndpoint;
    _endpoint = [endpoint retain];
    [self _setUp:@"com.apple.NSXPCConnection.user.endpoint"];
    xpc_object_t ep = [endpoint _endpoint];
    _xconn = ep ? xpc_connection_create_from_endpoint(ep) : NULL;
    if (_xconn) xpc_connection_set_target_queue(_xconn, _queue);
    else _invalid = YES;
    [self _installHandler];
    return self;
}

/* A peer from a listener, suspended until the delegate resumes it. */
- (instancetype)_initWithPeer:(xpc_connection_t)peer listenerName:(NSString *)listenerName
{
    if (!(self = [super init])) return nil;
    _kind = FinchXPCPeer;
    _listenerName = [listenerName copy];
    _xconn = (xpc_connection_t)xpc_retain(peer);
    pid_t pid = xpc_connection_get_pid(peer);
    [self _setUp:listenerName ? [NSString stringWithFormat:@"com.apple.NSXPCConnection.user.%@", listenerName]
                              : [NSString stringWithFormat:@"com.apple.NSXPCConnection.user.anonymous.%d", pid]];
    xpc_connection_set_target_queue(_xconn, _queue);
    [self _installHandler];
    return self;
}

- (void)dealloc
{
    if (_xconn) xpc_release(_xconn);
    if (_queue) dispatch_release(_queue);
    [_serviceName release];
    [_listenerName release];
    [_endpoint release];
    [_exportedInterface release];
    [_remoteObjectInterface release];
    [_exportedObject release];
    [_interruptionHandler release];
    [_invalidationHandler release];
    [_userInfo release];
    [_pending release];
    [_exportsByNumber release];
    if (_exportsByObject) CFRelease(_exportsByObject);
    [super dealloc];
}

/* MARK: Properties */

#define LOCKED_GETTER(type, name) \
    - (type)name { os_unfair_lock_lock(&_lock); type v = [[_##name retain] autorelease]; os_unfair_lock_unlock(&_lock); return v; }
#define LOCKED_SETTER(type, setter, name, how) \
    - (void)setter(type)value { value = [value how]; os_unfair_lock_lock(&_lock); type old = _##name; _##name = value; os_unfair_lock_unlock(&_lock); [old release]; }

LOCKED_GETTER(NSXPCInterface *, exportedInterface)
LOCKED_SETTER(NSXPCInterface *, setExportedInterface:, exportedInterface, retain)
LOCKED_GETTER(NSXPCInterface *, remoteObjectInterface)
LOCKED_SETTER(NSXPCInterface *, setRemoteObjectInterface:, remoteObjectInterface, retain)
LOCKED_GETTER(id, exportedObject)
LOCKED_SETTER(id, setExportedObject:, exportedObject, retain)
LOCKED_GETTER(id, userInfo)
LOCKED_SETTER(id, setUserInfo:, userInfo, retain)
typedef void (^FinchXPCHandler)(void);
LOCKED_GETTER(FinchXPCHandler, interruptionHandler)
LOCKED_SETTER(FinchXPCHandler, setInterruptionHandler:, interruptionHandler, copy)
LOCKED_GETTER(FinchXPCHandler, invalidationHandler)
LOCKED_SETTER(FinchXPCHandler, setInvalidationHandler:, invalidationHandler, copy)

- (NSString *)serviceName { return _serviceName; }
- (NSXPCListenerEndpoint *)endpoint { return _endpoint; }
- (xpc_connection_t)_xpcConnection { return _xconn; }
- (dispatch_queue_t)_queue { return _queue; }

- (void)_setQueue:(dispatch_queue_t)queue
{
    if (!queue) return;
    dispatch_retain(queue);
    dispatch_queue_t old = _queue;
    _queue = queue;
    if (_xconn) xpc_connection_set_target_queue(_xconn, queue);
    dispatch_release(old);
}

- (pid_t)processIdentifier
{
    pid_t pid = _xconn ? xpc_connection_get_pid(_xconn) : 0;
    return pid == _stalePid ? 0 : pid;
}

- (uid_t)effectiveUserIdentifier { return _xconn && [self processIdentifier] ? xpc_connection_get_euid(_xconn) : (uid_t)-1; }
- (gid_t)effectiveGroupIdentifier { return _xconn && [self processIdentifier] ? xpc_connection_get_egid(_xconn) : (gid_t)-1; }
- (au_asid_t)auditSessionIdentifier { return _xconn && [self processIdentifier] ? xpc_connection_get_asid(_xconn) : 0; }

- (audit_token_t)auditToken
{
    audit_token_t token;
    memset(&token, 0, sizeof(token));
    if (_xconn) xpc_connection_get_audit_token(_xconn, &token);
    return token;
}

- (id)valueForEntitlement:(NSString *)entitlement
{
    xpc_object_t v = _xconn ? xpc_connection_copy_entitlement_value(_xconn, entitlement.UTF8String) : NULL;
    if (!v) return nil;
    id o = (id)_CFXPCCreateCFObjectFromXPCObject(v);
    xpc_release(v);
    return [o autorelease];
}

/* "connection to service with pid 5 named org.example.service", as Apple's. */
- (NSString *)_connectionDescription
{
    pid_t pid = [self processIdentifier];
    switch (_kind) {
    case FinchXPCNamed:
        return pid ? [NSString stringWithFormat:@"connection to service with pid %d named %@", pid, _serviceName]
                   : [NSString stringWithFormat:@"connection to service named %@", _serviceName];
    case FinchXPCEndpoint:
        return pid ? [NSString stringWithFormat:@"connection to service with pid %d created from an endpoint", pid]
                   : @"connection to service created from an endpoint";
    case FinchXPCPeer:
        return _listenerName ? [NSString stringWithFormat:@"connection from pid %d on mach service named %@", pid, _listenerName]
                             : [NSString stringWithFormat:@"connection from pid %d on anonymousListener or serviceListener", pid];
    default:
        return @"connection";
    }
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s: %p> %@", object_getClassName(self), self, [self _connectionDescription]];
}

- (NSError *)_errorWithCode:(NSInteger)code
{
    NSString *d;
    if (code == NSXPCConnectionInterrupted) d = [self _connectionDescription];
    else if (code == NSXPCConnectionReplyInvalid) d = [NSString stringWithFormat:@"The reply from the %@ was invalid.", [self _connectionDescription]];
    else if (_lookupFailed) d = [NSString stringWithFormat:@"The %@ was invalidated: Connection init failed at lookup with error 3 - No such process.", [self _connectionDescription]];
    else if (_invalidatedHere) d = [NSString stringWithFormat:@"The %@ was invalidated from this process.", [self _connectionDescription]];
    else d = [NSString stringWithFormat:@"The %@ was invalidated.", [self _connectionDescription]];
    return [NSError errorWithDomain:NSCocoaErrorDomain code:code userInfo:@{NSDebugDescriptionErrorKey: d}];
}

/* MARK: Proxies */

- (id)remoteObjectProxy { return [new_proxy(self, nil, ROOT_OBJECT, nil, NO) autorelease]; }
- (id)remoteObjectProxyWithErrorHandler:(void (^)(NSError *))handler { return [new_proxy(self, nil, ROOT_OBJECT, handler, NO) autorelease]; }
- (id)synchronousRemoteObjectProxyWithErrorHandler:(void (^)(NSError *))handler { return [new_proxy(self, nil, ROOT_OBJECT, handler, YES) autorelease]; }
- (id)remoteObjectProxyWithUserInfo:(id)userInfo errorHandler:(void (^)(NSError *))handler { return [self remoteObjectProxyWithErrorHandler:handler]; }
- (id)remoteObjectProxyWithTimeout:(NSTimeInterval)timeout errorHandler:(void (^)(NSError *))handler { return [self remoteObjectProxyWithErrorHandler:handler]; }

/* An object passed as a proxy argument: its number, kept until the other
 * side gives back every reference. */
- (xpc_object_t)_newProxyNumberForObject:(id)object interface:(NSXPCInterface *)iface
{
    if (!object) return xpc_null_create();
    os_unfair_lock_lock(&_lock);
    _NSXPCExport *e = (_NSXPCExport *)CFDictionaryGetValue(_exportsByObject, object);
    if (!e) {
        e = [[_NSXPCExport new] autorelease];
        e->_object = [object retain];
        e->_interface = [iface retain];
        e->_number = _nextExport++;
        CFDictionarySetValue(_exportsByObject, object, e);
        [_exportsByNumber setObject:e forKey:@(e->_number)];
    }
    e->_count++;
    uint64_t number = e->_number;
    os_unfair_lock_unlock(&_lock);
    xpc_object_t d = new_tagged("$proxy");
    xpc_dictionary_set_uint64(d, "number", number);
    return d;
}

- (void)_releaseExport:(uint64_t)number count:(uint64_t)count
{
    os_unfair_lock_lock(&_lock);
    _NSXPCExport *e = [[_exportsByNumber objectForKey:@(number)] retain];
    if (e) {
        e->_count = count >= e->_count ? 0 : e->_count - count;
        if (e->_count == 0) {
            CFDictionaryRemoveValue(_exportsByObject, e->_object);
            [_exportsByNumber removeObjectForKey:@(number)];
        }
    }
    os_unfair_lock_unlock(&_lock);
    [e release];
}

- (id)_proxyForRemoteNumber:(uint64_t)number interface:(NSXPCInterface *)iface
{
    _NSXPCDistantObject *p = new_proxy(self, iface, number, nil, NO);
    p->_owner = YES;
    return [p autorelease];
}

- (void)_releaseRemoteNumber:(uint64_t)number
{
    if (_invalid || !_xconn) return;
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(m, K_VERSION, NSXPC_VERSION);
    xpc_dictionary_set_uint64(m, K_RELEASE, number);
    xpc_dictionary_set_uint64(m, K_COUNT, 1);
    xpc_connection_send_message(_xconn, m);
    xpc_release(m);
}

/* MARK: Arguments */

static __attribute__((noreturn)) void
unsupported(const char *type, SEL sel)
{
    FinchRaise(NSInvalidArgumentException, "NSXPCConnection: arguments of type '%s' can't be sent (%s)", type, sel_getName(sel));
}

/* One argument's value (+1). */
- (xpc_object_t)_newValueAt:(NSUInteger)i of:(NSInvocation *)inv type:(const char *)type method:(_NSXPCMethod *)m
    index:(NSUInteger)index interface:(NSXPCInterface *)iface ofReply:(BOOL)ofReply encoder:(NSXPCEncoder *)enc
{
    const char *t = skip_qualifiers(type);
    NSUInteger size = 0;
    NSGetSizeAndAlignment(t, &size, NULL);
    union { long long q; double d; void *p; unsigned char bytes[64]; } small;
    void *buf = size <= sizeof(small) ? &small : malloc(size);
    xpc_object_t v = NULL;
    @try {
        [inv getArgument:buf atIndex:(NSInteger)i];
        switch (*t) {
        case 'c': v = xpc_int64_create(*(signed char *)buf); break;
        case 'C': v = xpc_uint64_create(*(unsigned char *)buf); break;
        case 's': v = xpc_int64_create(*(short *)buf); break;
        case 'S': v = xpc_uint64_create(*(unsigned short *)buf); break;
        case 'i': case 'l': v = xpc_int64_create(*(int *)buf); break;
        case 'I': case 'L': v = xpc_uint64_create(*(unsigned int *)buf); break;
        case 'q': v = xpc_int64_create(*(long long *)buf); break;
        case 'Q': v = xpc_uint64_create(*(unsigned long long *)buf); break;
        case 'B': v = xpc_bool_create(*(bool *)buf); break;
        case 'f': v = xpc_double_create(*(float *)buf); break;
        case 'd': case 'D': v = xpc_double_create(*(double *)buf); break;
        case '*': {
            const char *s = *(const char **)buf;
            v = s ? xpc_string_create(s) : xpc_null_create();
            break;
        }
        case ':': v = *(SEL *)buf ? xpc_string_create(sel_getName(*(SEL *)buf)) : xpc_null_create(); break;
        case '#': v = *(Class *)buf ? xpc_string_create(class_getName(*(Class *)buf)) : xpc_null_create(); break;
        case '{': case '(': case '[': v = xpc_data_create(buf, size); break;
        case '@': {
            FinchXPCType *ty = [m type:index ofReply:ofReply];
            if (ty->isBlock) unsupported(type, m->_sel);
            id o = *(id *)buf;
            NSXPCInterface *proxyInterface = [iface _interfaceFor:m index:index ofReply:ofReply];
            xpc_type_t xt = [iface _xpcTypeFor:m index:index ofReply:ofReply];
            if (proxyInterface) {
                v = [self _newProxyNumberForObject:o interface:proxyInterface];
            } else if (xt || ty->isXPC) {
                if (o && xt && xpc_get_type(o) != xt)
                    FinchRaise(NSInvalidArgumentException, "NSXPCConnection: argument %lu of %s is not of the XPC type the interface gives it",
                        (unsigned long)index, sel_getName(m->_sel));
                v = o ? xpc_retain(o) : xpc_null_create();
            } else {
                v = [enc _newXPCObjectForObject:o];
            }
            break;
        }
        default:
            unsupported(type, m->_sel);
        }
    } @finally {
        if (buf != &small) free(buf);
    }
    return v;
}

- (xpc_object_t)_newArgumentsFrom:(NSInvocation *)inv method:(_NSXPCMethod *)m interface:(NSXPCInterface *)iface ofReply:(BOOL)ofReply
{
    NSMethodSignature *sig = ofReply ? m->_replySignature : m->_signature;
    NSUInteger first = ofReply ? 1 : 2, n = [sig numberOfArguments];
    xpc_object_t args = xpc_array_create(NULL, 0);
    NSXPCEncoder *enc = [[NSXPCEncoder alloc] _initWithConnection:self];
    @try {
        for (NSUInteger i = first; i < n; i++) {
            NSUInteger index = i - first;
            xpc_object_t v = (!ofReply && index == m->_replyIndex) ? xpc_null_create()
                : [self _newValueAt:i of:inv type:[sig getArgumentTypeAtIndex:i] method:m index:index interface:iface ofReply:ofReply encoder:enc];
            xpc_array_append_value(args, v);
            xpc_release(v);
        }
    } @catch (id e) {
        xpc_release(args);
        @throw;
    } @finally {
        [enc release];
    }
    return args;
}

/* Set an invocation's arguments from a message's. Objects are autoreleased. */
- (void)_decodeArguments:(xpc_object_t)args into:(NSInvocation *)inv method:(_NSXPCMethod *)m
    interface:(NSXPCInterface *)iface ofReply:(BOOL)ofReply
{
    NSMethodSignature *sig = ofReply ? m->_replySignature : m->_signature;
    NSUInteger first = ofReply ? 1 : 2, n = [sig numberOfArguments];
    if (!args || xpc_get_type(args) != XPC_TYPE_ARRAY || xpc_array_get_count(args) != n - first)
        FinchRaise(NSInvalidUnarchiveOperationException, "NSXPCConnection: the message for %s has the wrong number of arguments", sel_getName(m->_sel));
    NSXPCDecoder *dec = [[[NSXPCDecoder alloc] _initWithConnection:self] autorelease];
    for (NSUInteger i = first; i < n; i++) {
        NSUInteger index = i - first;
        if (!ofReply && index == m->_replyIndex) continue;
        xpc_object_t v = xpc_array_get_value(args, index);
        const char *type = [sig getArgumentTypeAtIndex:i], *t = skip_qualifiers(type);
        int64_t si;
        uint64_t ui;
        double d = number_value(v, &si, &ui);
        switch (*t) {
        case 'c': { signed char x = (signed char)si; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 'C': { unsigned char x = (unsigned char)ui; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 's': { short x = (short)si; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 'S': { unsigned short x = (unsigned short)ui; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 'i': case 'l': { int x = (int)si; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 'I': case 'L': { unsigned int x = (unsigned int)ui; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 'q': { long long x = si; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 'Q': { unsigned long long x = ui; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 'B': { bool x = si != 0; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 'f': { float x = (float)d; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case 'd': case 'D': { double x = d; [inv setArgument:&x atIndex:(NSInteger)i]; break; }
        case '*': case ':': case '#': {
            const char *s = xpc_get_type(v) == XPC_TYPE_STRING ? xpc_string_get_string_ptr(v) : NULL;
            if (*t == '*') {
                const char *x = s ? [[NSString stringWithUTF8String:s] UTF8String] : NULL;
                [inv setArgument:&x atIndex:(NSInteger)i];
            } else if (*t == ':') {
                SEL x = s ? sel_registerName(s) : NULL;
                [inv setArgument:&x atIndex:(NSInteger)i];
            } else {
                Class x = s ? objc_getClass(s) : Nil;
                [inv setArgument:&x atIndex:(NSInteger)i];
            }
            break;
        }
        case '{': case '(': case '[': {
            NSUInteger size = 0;
            NSGetSizeAndAlignment(t, &size, NULL);
            if (xpc_get_type(v) != XPC_TYPE_DATA || xpc_data_get_length(v) != size)
                FinchRaise(NSInvalidUnarchiveOperationException, "NSXPCConnection: argument %lu of %s has the wrong size",
                    (unsigned long)index, sel_getName(m->_sel));
            [inv setArgument:(void *)xpc_data_get_bytes_ptr(v) atIndex:(NSInteger)i];
            break;
        }
        case '@': {
            FinchXPCType *ty = [m type:index ofReply:ofReply];
            NSXPCInterface *proxyInterface = [iface _interfaceFor:m index:index ofReply:ofReply];
            xpc_type_t xt = [iface _xpcTypeFor:m index:index ofReply:ofReply];
            id o = nil;
            if (ty->isBlock) {
                unsupported(type, m->_sel);
            } else if (proxyInterface) {
                if (xpc_get_type(v) == XPC_TYPE_DICTIONARY) {
                    const char *tag = xpc_dictionary_get_string(v, K_CLASS);
                    if (!tag || strcmp(tag, "$proxy") != 0)
                        FinchRaise(NSInvalidUnarchiveOperationException, "NSXPCConnection: argument %lu of %s is not a proxy",
                            (unsigned long)index, sel_getName(m->_sel));
                    o = [self _proxyForRemoteNumber:xpc_dictionary_get_uint64(v, "number") interface:proxyInterface];
                }
            } else if (xt || ty->isXPC) {
                if (xpc_get_type(v) != XPC_TYPE_NULL) {
                    if (xt && xpc_get_type(v) != xt)
                        FinchRaise(NSInvalidUnarchiveOperationException, "NSXPCConnection: argument %lu of %s is not of the expected XPC type",
                            (unsigned long)index, sel_getName(m->_sel));
                    o = v;
                }
            } else {
                o = [dec _objectFromXPC:v classes:[iface _classesFor:m index:index ofReply:ofReply] key:@"root"];
            }
            [inv setArgument:&o atIndex:(NSInteger)i];
            break;
        }
        default:
            unsupported(type, m->_sel);
        }
    }
}

/* MARK: Sending */

- (void)_failPending:(_NSXPCPendingReply *)p code:(NSInteger)code
{
    if (p->_errorHandler) ((void (^)(NSError *))p->_errorHandler)([self _errorWithCode:code]);
}

- (void)_failAllPendingWithCode:(NSInteger)code
{
    os_unfair_lock_lock(&_lock);
    NSArray *keys = [[_pending allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *all = [NSMutableArray arrayWithCapacity:keys.count];
    for (id key in keys) [all addObject:[_pending objectForKey:key]];
    [_pending removeAllObjects];
    os_unfair_lock_unlock(&_lock);
    for (_NSXPCPendingReply *p in all) [self _failPending:p code:code];
}

/* Call a reply block with a reply's arguments. */
- (void)_callReplyBlock:(id)block reply:(xpc_object_t)reply method:(_NSXPCMethod *)m interface:(NSXPCInterface *)iface errorHandler:(id)errorHandler
{
    @autoreleasepool {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:m->_replySignature];
        [inv setArgument:&block atIndex:0];
        @try {
            if (xpc_dictionary_get_uint64(reply, K_VERSION) != NSXPC_VERSION)
                FinchRaise(NSInvalidUnarchiveOperationException, "NSXPCConnection: not an NSXPC reply");
            [self _decodeArguments:xpc_dictionary_get_value(reply, K_ARGS) into:inv method:m interface:iface ofReply:YES];
        } @catch (NSException *e) {
            os_log_error(xpc_log(), "NSXPCConnection: %{public}@: Exception caught during decoding of reply to message '%{public}s', dropping incoming message and calling failure block.\nException: %{public}@",
                self, sel_getName(m->_sel), e);
            if (errorHandler) ((void (^)(NSError *))errorHandler)([self _errorWithCode:NSXPCConnectionReplyInvalid]);
            return;
        }
        NSXPCConnection *saved = current_connection;
        current_connection = self;
        @try {
            [inv invokeUsingIMP:block_function(block)];
        } @finally {
            current_connection = saved;
        }
    }
}

- (void)_receivedReply:(xpc_object_t)reply sequence:(uint64_t)sequence
{
    os_unfair_lock_lock(&_lock);
    _NSXPCPendingReply *p = [[_pending objectForKey:@(sequence)] retain];
    [_pending removeObjectForKey:@(sequence)];
    os_unfair_lock_unlock(&_lock);
    if (!p) return;
    if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
        BOOL invalid = reply == XPC_ERROR_CONNECTION_INVALID;
        if (invalid) [self _becomeInvalid];
        [self _failPending:p code:invalid ? NSXPCConnectionInvalid : NSXPCConnectionInterrupted];
    } else {
        [self _callReplyBlock:p->_block reply:reply method:p->_method interface:p->_interface errorHandler:p->_errorHandler];
    }
    [p release];
}

/* The connection can't be used any more (the service doesn't exist): let
 * libxpc deliver the invalidation. */
- (void)_becomeInvalid
{
    os_unfair_lock_lock(&_lock);
    _invalid = YES;
    BOOL activate = !_activated;
    _activated = YES;
    os_unfair_lock_unlock(&_lock);
    if (_xconn) {
        if (activate) xpc_connection_resume(_xconn);
        xpc_connection_cancel(_xconn);
    }
}

- (void)_sendInvocation:(NSInvocation *)inv method:(_NSXPCMethod *)m interface:(NSXPCInterface *)iface proxy:(_NSXPCDistantObject *)proxy
{
    SEL sel = m->_sel;
    if (*skip_qualifiers([m->_signature methodReturnType]) != 'v')
        FinchRaise(NSInvalidArgumentException, "[NSXPCConnection sendInvocation]: Return type of methods sent over this proxy must be 'void' or 'NSProgress *' (%s)", sel_getName(sel));
    if (m->_blockCount > 1)
        FinchRaise(NSInvalidArgumentException, "[NSXPCConnection sendInvocation]: Only one reply block is allowed per message send. (%s)", sel_getName(sel));
    id block = nil;
    if (m->_replyIndex != NSNotFound) {
        if (!m->_replySignature)
            FinchRaise(NSInvalidArgumentException, "[NSXPCConnection sendInvocation]: the reply block of %s has no signature in its protocol", sel_getName(sel));
        [inv getArgument:&block atIndex:(NSInteger)m->_replyIndex + 2];
    }
    id errorHandler = proxy->_errorHandler;

    xpc_object_t args = [self _newArgumentsFrom:inv method:m interface:iface ofReply:NO];
    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(msg, K_VERSION, NSXPC_VERSION);
    xpc_dictionary_set_string(msg, K_SELECTOR, sel_getName(sel));
    xpc_dictionary_set_uint64(msg, K_PROXY, proxy->_number);
    xpc_dictionary_set_value(msg, K_ARGS, args);
    xpc_dictionary_set_bool(msg, K_REPLY, block != nil);
    xpc_release(args);

    os_unfair_lock_lock(&_lock);
    BOOL invalid = _invalid;
    os_unfair_lock_unlock(&_lock);
    if (invalid || !_xconn) {
        if (block && errorHandler) {
            NSError *e = [self _errorWithCode:NSXPCConnectionInvalid];
            if (proxy->_synchronous) ((void (^)(NSError *))errorHandler)(e);
            else {
                id h = [[errorHandler copy] autorelease];
                dispatch_async(_queue, ^{ ((void (^)(NSError *))h)(e); });
            }
        }
    } else if (!block) {
        xpc_connection_send_message(_xconn, msg);
    } else if (proxy->_synchronous) {
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(_xconn, msg);
        if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
            BOOL inval = reply == XPC_ERROR_CONNECTION_INVALID;
            if (inval) [self _becomeInvalid];
            if (errorHandler) ((void (^)(NSError *))errorHandler)([self _errorWithCode:inval ? NSXPCConnectionInvalid : NSXPCConnectionInterrupted]);
        } else {
            [self _callReplyBlock:block reply:reply method:m interface:iface errorHandler:errorHandler];
        }
        xpc_release(reply);
    } else {
        _NSXPCPendingReply *p = [[_NSXPCPendingReply new] autorelease];
        p->_block = [block copy];
        p->_errorHandler = [errorHandler copy];
        p->_method = [m retain];
        p->_interface = [iface retain];
        os_unfair_lock_lock(&_lock);
        uint64_t sequence = ++_sequence;
        [_pending setObject:p forKey:@(sequence)];
        os_unfair_lock_unlock(&_lock);
        xpc_connection_send_message_with_reply(_xconn, msg, _queue, ^(xpc_object_t reply) {
            [self _receivedReply:reply sequence:sequence];
        });
    }
    xpc_release(msg);
}

- (void)_sendReply:(xpc_object_t)reply
{
    if (_xconn && !_invalid) xpc_connection_send_message(_xconn, reply);
}

/* MARK: Receiving */

- (void)_handleEvent:(xpc_object_t)event
{
    xpc_type_t type = xpc_get_type(event);
    if (type == XPC_TYPE_DICTIONARY) {
        [self _handleMessage:event];
        return;
    }
    if (type != XPC_TYPE_ERROR) return;
    if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
        _stalePid = _xconn ? xpc_connection_get_pid(_xconn) : 0;
        if (!_stalePid) _stalePid = -1;
        [self _failAllPendingWithCode:NSXPCConnectionInterrupted];
        void (^h)(void) = [self interruptionHandler];
        if (h) h();
    } else if (event == XPC_ERROR_CONNECTION_INVALID) {
        if (_handledInvalid) return;
        _handledInvalid = YES;
        os_unfair_lock_lock(&_lock);
        _invalid = YES;
        NSArray *exports = [[_exportsByNumber allValues] retain];
        [_exportsByNumber removeAllObjects];
        CFDictionaryRemoveAllValues(_exportsByObject);
        os_unfair_lock_unlock(&_lock);
        [exports release];
        [self _failAllPendingWithCode:NSXPCConnectionInvalid];
        void (^h)(void) = [[self invalidationHandler] retain];
        self.interruptionHandler = nil;
        self.invalidationHandler = nil;
        if (h) h();
        [h release];
        /* Let go of the connection (the handler holds it). */
        xpc_connection_set_event_handler(_xconn, ^(xpc_object_t e) { });
    }
}

- (void)_handleMessage:(xpc_object_t)msg
{
    @autoreleasepool {
        if (xpc_dictionary_get_uint64(msg, K_VERSION) != NSXPC_VERSION) {
            os_log_error(xpc_log(), "NSXPCConnection: %{public}@: received a message that isn't an NSXPC message, dropping it", self);
            return;
        }
        uint64_t released = xpc_dictionary_get_uint64(msg, K_RELEASE);
        if (released) {
            [self _releaseExport:released count:xpc_dictionary_get_uint64(msg, K_COUNT)];
            return;
        }
        const char *selName = xpc_dictionary_get_string(msg, K_SELECTOR);
        uint64_t number = xpc_dictionary_get_uint64(msg, K_PROXY);
        id target = nil;
        NSXPCInterface *iface = nil;
        if (number == ROOT_OBJECT) {
            target = [self exportedObject];
            iface = [self exportedInterface];
        } else {
            os_unfair_lock_lock(&_lock);
            _NSXPCExport *e = [_exportsByNumber objectForKey:@(number)];
            target = [[e->_object retain] autorelease];
            iface = [[e->_interface retain] autorelease];
            os_unfair_lock_unlock(&_lock);
        }
        SEL sel = selName ? sel_registerName(selName) : NULL;
        _NSXPCMethod *m = [iface _methodForSelector:sel];
        if (!target || !m) {
            os_log_error(xpc_log(), "NSXPCConnection: %{public}@: received a message for selector '%{public}s' that %{public}s, dropping it",
                self, selName ?: "(null)", !target ? "no exported object handles" : "isn't in the exported interface");
            return;
        }
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:m->_signature];
        [inv setSelector:sel];
        @try {
            [self _decodeArguments:xpc_dictionary_get_value(msg, K_ARGS) into:inv method:m interface:iface ofReply:NO];
        } @catch (NSException *e) {
            os_log_error(xpc_log(), "NSXPCConnection: %{public}@: Exception caught during decoding of received selector %{public}s, dropping incoming message.\nException: %{public}@",
                self, selName, e);
            [self invalidate];
            return;
        }
        id replyBlock = nil;
        if (m->_replyIndex != NSNotFound) {
            _NSXPCReplyForwarder *f = [[_NSXPCReplyForwarder new] autorelease];
            f->_connection = [self retain];
            f->_request = xpc_dictionary_get_bool(msg, K_REPLY) ? xpc_retain(msg) : NULL;
            f->_method = [m retain];
            f->_interface = [iface retain];
            replyBlock = new_reply_block(f);
            [inv setArgument:&replyBlock atIndex:(NSInteger)m->_replyIndex + 2];
        }
        NSXPCConnection *saved = current_connection;
        current_connection = self;
        @try {
            [inv invokeWithTarget:target];
        } @catch (NSException *e) {
            os_log_error(xpc_log(), "NSXPCConnection: %{public}@: Exception caught during invocation of received message, dropping incoming message and invalidating the connection.\nException: %{public}@",
                self, e);
            [self invalidate];
        } @finally {
            current_connection = saved;
            if (replyBlock) Block_release(replyBlock);
        }
    }
}

/* MARK: Life cycle */

- (void)resume
{
    os_unfair_lock_lock(&_lock);
    BOOL first = !_activated;
    _activated = YES;
    os_unfair_lock_unlock(&_lock);
    if (!_xconn) return;
    if (first && _kind == FinchXPCNamed && !(_flags & XPC_CONNECTION_MACH_SERVICE_LISTENER)) {
        /* As Apple's, a service that can't be looked up invalidates the connection. */
        mach_port_t port = MACH_PORT_NULL;
        if (bootstrap_look_up(bootstrap_port, _serviceName.UTF8String, &port) != KERN_SUCCESS) {
            os_unfair_lock_lock(&_lock);
            _lookupFailed = YES;
            _invalid = YES;
            os_unfair_lock_unlock(&_lock);
        } else {
            mach_port_deallocate(mach_task_self(), port);
        }
    }
    xpc_connection_resume(_xconn);
    if (_lookupFailed && first) xpc_connection_cancel(_xconn);
}

- (void)activate
{
    if (!_activated) [self resume];
}

- (void)suspend
{
    if (_xconn) xpc_connection_suspend(_xconn);
}

- (void)invalidate
{
    os_unfair_lock_lock(&_lock);
    if (!_invalid) _invalidatedHere = YES;
    _invalid = YES;
    BOOL activate = !_activated;
    _activated = YES;
    os_unfair_lock_unlock(&_lock);
    if (!_xconn) return;
    if (activate) xpc_connection_resume(_xconn);
    xpc_connection_cancel(_xconn);
    [self retain];
    dispatch_async(_queue, ^{
        [self _failAllPendingWithCode:NSXPCConnectionInvalid];
        [self release];
    });
}

- (void)scheduleSendBarrierBlock:(void (^)(void))block
{
    if (_xconn) xpc_connection_send_barrier(_xconn, block);
    else dispatch_async(_queue, block);
}

- (void)addBarrierBlock:(void (^)(void))block { [self scheduleSendBarrierBlock:block]; }

- (void)setCodeSigningRequirement:(NSString *)requirement
{
    if (!requirement) FinchRaise(NSInvalidArgumentException, "*** -[NSXPCConnection setCodeSigningRequirement:]: requirement must not be nil");
    if (_xconn) (void)!xpc_connection_set_peer_code_signing_requirement(_xconn, requirement.UTF8String);
}

@end

/* MARK: - NSXPCListener */

typedef enum { FinchListenerAnonymous, FinchListenerMach, FinchListenerService } FinchListenerKind;

@implementation NSXPCListener {
    xpc_connection_t _xconn;
    dispatch_queue_t _queue;
    NSString *_serviceName;
    __weak id<NSXPCListenerDelegate> _delegate;
    FinchListenerKind _kind;
    NSString *_requirement;
}

static NSXPCListener *service_listener;

+ (NSXPCListener *)serviceListener
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        service_listener = [[NSXPCListener alloc] _initWithKind:FinchListenerService name:nil];
    });
    return service_listener;
}

+ (NSXPCListener *)anonymousListener
{
    return [[[self alloc] _initWithKind:FinchListenerAnonymous name:nil] autorelease];
}

- (instancetype)_initWithKind:(FinchListenerKind)kind name:(NSString *)name
{
    if (!(self = [super init])) return nil;
    _kind = kind;
    _serviceName = [name copy];
    _queue = dispatch_queue_create(kind == FinchListenerMach ? [@"com.apple.NSXPCListener.service." stringByAppendingString:name].UTF8String
        : "com.apple.NSXPCListener.main", DISPATCH_QUEUE_SERIAL);
    if (kind == FinchListenerAnonymous) _xconn = xpc_connection_create(NULL, _queue);
    else if (kind == FinchListenerMach) _xconn = xpc_connection_create_mach_service(name.UTF8String, _queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (_xconn) {
        xpc_connection_set_event_handler(_xconn, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_CONNECTION) [self _acceptPeer:event];
        });
    } else if (kind == FinchListenerMach) {
        os_log_error(xpc_log(), "NSXPCListener: can't check in Mach service %{public}@", name);
    }
    return self;
}

- (instancetype)initWithMachServiceName:(NSString *)name
{
    if (!name) FinchRaise(NSInvalidArgumentException, "*** -[NSXPCListener initWithMachServiceName:]: service name must not be nil");
    return [self _initWithKind:FinchListenerMach name:name];
}

- (instancetype)init
{
    return [self _initWithKind:FinchListenerAnonymous name:nil];
}

- (void)dealloc
{
    if (_xconn) xpc_release(_xconn);
    if (_queue) dispatch_release(_queue);
    [_serviceName release];
    [_requirement release];
    [super dealloc];
}

- (id<NSXPCListenerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSXPCListenerDelegate>)delegate { _delegate = delegate; }
- (NSString *)serviceName { return _serviceName; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s: %p> service: %@", object_getClassName(self), self, _serviceName];
}

- (NSXPCListenerEndpoint *)endpoint
{
    if (!_xconn || _kind == FinchListenerService) return nil;
    xpc_endpoint_t e = xpc_endpoint_create(_xconn);
    if (!e) return nil;
    NSXPCListenerEndpoint *ep = [[NSXPCListenerEndpoint new] autorelease];
    [ep _setEndpoint:e];
    xpc_release(e);
    return ep;
}

- (void)_acceptPeer:(xpc_connection_t)peer
{
    @autoreleasepool {
        if (_requirement) (void)!xpc_connection_set_peer_code_signing_requirement(peer, _requirement.UTF8String);
        NSXPCConnection *c = [[[NSXPCConnection alloc] _initWithPeer:peer listenerName:_kind == FinchListenerMach ? _serviceName : nil] autorelease];
        id<NSXPCListenerDelegate> d = self.delegate;
        BOOL accepted = d && [d respondsToSelector:@selector(listener:shouldAcceptNewConnection:)] &&
            [d listener:self shouldAcceptNewConnection:c];
        if (!accepted) [c invalidate];
    }
}

static void
service_peer(xpc_connection_t peer)
{
    [service_listener _acceptPeer:peer];
}

/* An XPC service's main loop, as Apple's: check in the service launchd (or
 * finch-init) started this process for and serve it forever, on the main
 * run loop when the bundle's XPCService RunLoopType asks for NSRunLoop. */
- (void)_runService __attribute__((noreturn))
{
    NSDictionary *info = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"XPCService"];
    BOOL runLoop = [info isKindOfClass:[NSDictionary class]] && [[info objectForKey:@"RunLoopType"] isEqual:@"NSRunLoop"];
    if (runLoop) {
        const char *name = getenv("XPC_SERVICE_NAME");
        xpc_connection_t l = name ? xpc_connection_create_mach_service(name, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER) : NULL;
        if (l) {
            xpc_connection_set_event_handler(l, ^(xpc_object_t event) {
                if (xpc_get_type(event) == XPC_TYPE_CONNECTION) service_peer(event);
            });
            xpc_connection_resume(l);
            for (;;) [[NSRunLoop currentRunLoop] run];
        }
    }
    xpc_main(service_peer);
}

- (void)resume
{
    if (_kind == FinchListenerService) [self _runService];
    if (_xconn) xpc_connection_resume(_xconn);
}

- (void)activate { [self resume]; }
- (void)suspend { if (_xconn) xpc_connection_suspend(_xconn); }
- (void)invalidate { if (_xconn) xpc_connection_cancel(_xconn); }

- (void)setConnectionCodeSigningRequirement:(NSString *)requirement
{
    if (!requirement) FinchRaise(NSInvalidArgumentException, "*** -[NSXPCListener setConnectionCodeSigningRequirement:]: requirement must not be nil");
    [_requirement release];
    _requirement = [requirement copy];
}

@end
