/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Key-value observing (docs/design/FOUNDATION.md), against the SDK's
 * declarations, as Apple's works:
 *
 *  - Observing a key of an object whose class notifies automatically moves
 *    the object to a subclass, NSKVONotifying_<Class>, whose setters (and
 *    indexed collection accessors) wrap the original ones in
 *    -willChangeValueForKey: / -didChangeValueForKey:. -class still answers the
 *    original class, and the object moves back when its last observer goes.
 *  - Change dictionaries carry kind, new, old (NSNull for nil), indexes and
 *    notificationIsPrior, as the options ask; NSKeyValueObservingOptionInitial
 *    sends one at registration.
 *  - Key paths with dots observe each step, moving to the new object when an
 *    intermediate value changes.
 *  - Dependent keys (+keyPathsForValuesAffectingValueForKey:, or
 *    +keyPathsForValuesAffecting<Key>) are notified, before the key's own
 *    observers, when what they depend on changes.
 *
 * Observers aren't retained, as on macOS.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <pthread.h>

#include "Foundation_Finch.h"

NSKeyValueChangeKey const NSKeyValueChangeKindKey = @"kind";
NSKeyValueChangeKey const NSKeyValueChangeNewKey = @"new";
NSKeyValueChangeKey const NSKeyValueChangeOldKey = @"old";
NSKeyValueChangeKey const NSKeyValueChangeIndexesKey = @"indexes";
NSKeyValueChangeKey const NSKeyValueChangeNotificationIsPriorKey = @"notificationIsPrior";

/* MARK: - Observation records */

@interface __NSKVOObservance : NSObject {
@public
    id _observer;                   /* not retained */
    NSString *_keyPath;
    NSKeyValueObservingOptions _options;
    void *_context;
    id _helper;                     /* for "a.b": a __NSKVOKeyPathHelper */
}
@end
@implementation __NSKVOObservance
- (void)dealloc { [_keyPath release]; [_helper release]; [super dealloc]; }
@end

/* What an observed object keeps: its observances, and the pending
 * changes (one stack per key, for will/did pairs that nest). */
@interface __NSKVOInfo : NSObject {
@public
    NSMutableArray *_observances;
    NSMutableDictionary *_pending;     /* key -> array of change dictionaries */
    NSMutableDictionary *_dependents;  /* key -> dependent keys registered */
    Class _original;
}
@end
@implementation __NSKVOInfo
- (instancetype)init
{
    if ((self = [super init])) {
        _observances = [[NSMutableArray alloc] init];
        _pending = [[NSMutableDictionary alloc] init];
        _dependents = [[NSMutableDictionary alloc] init];
    }
    return self;
}
- (void)dealloc { [_observances release]; [_pending release]; [_dependents release]; [super dealloc]; }
@end

static pthread_mutex_t kvoLock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
static char infoKey;

static __NSKVOInfo *
info_of(id obj, BOOL create)
{
    __NSKVOInfo *i = objc_getAssociatedObject(obj, &infoKey);
    if (!i && create) {
        i = [[[__NSKVOInfo alloc] init] autorelease];
        objc_setAssociatedObject(obj, &infoKey, i, OBJC_ASSOCIATION_RETAIN);
    }
    return i;
}

/* Keys whose automatic setter notification is suppressed on this thread
 * (the array proxy sends a collection change instead). */
static NSMutableSet *
suppressed(void)
{
    NSMutableDictionary *td = [[NSThread currentThread] threadDictionary];
    NSMutableSet *s = [td objectForKey:@"__FinchKVOSuppressed"];
    if (!s) {
        s = [NSMutableSet set];
        [td setObject:s forKey:@"__FinchKVOSuppressed"];
    }
    return s;
}

static NSString *
supp_key(id obj, NSString *key)
{
    return [NSString stringWithFormat:@"%p.%@", obj, key];
}

static NSString *
capitalized(NSString *key)
{
    if ([key length] == 0) return key;
    unichar c = [key characterAtIndex:0];
    if (c >= 'a' && c <= 'z') c = (unichar)(c - 'a' + 'A');
    return [[NSString stringWithCharacters:&c length:1] stringByAppendingString:[key substringFromIndex:1]];
}

/* MARK: - Delivering */

static void
send(__NSKVOObservance *o, id object, NSDictionary *change)
{
    id observer = o->_observer;
    [observer observeValueForKeyPath:o->_keyPath ofObject:object change:change context:o->_context];
}

/* Observances of `key` itself (not key paths through it), copied out. */
static NSArray *
observances_for(id obj, NSString *key)
{
    pthread_mutex_lock(&kvoLock);
    __NSKVOInfo *info = info_of(obj, NO);
    NSMutableArray *out = [NSMutableArray array];
    for (__NSKVOObservance *o in info->_observances)
        if (!o->_helper && [o->_keyPath isEqualToString:key]) [out addObject:o];
    pthread_mutex_unlock(&kvoLock);
    return out;
}

static NSArray *
dependents_of(id obj, NSString *key)
{
    pthread_mutex_lock(&kvoLock);
    NSArray *d = [[[info_of(obj, NO)->_dependents objectForKey:key] allObjects] retain];
    pthread_mutex_unlock(&kvoLock);
    return [d autorelease];
}

static void
will_change(id obj, NSString *key, NSKeyValueChange kind, NSIndexSet *indexes)
{
    __NSKVOInfo *info = info_of(obj, NO);
    if (!info) return;
    NSArray *obs = observances_for(obj, key);
    BOOL needOld = NO;
    for (__NSKVOObservance *o in obs) needOld = needOld || (o->_options & NSKeyValueObservingOptionOld);
    NSMutableDictionary *change = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:kind]
                                                                     forKey:NSKeyValueChangeKindKey];
    if (indexes) [change setObject:indexes forKey:NSKeyValueChangeIndexesKey];
    if (needOld) {
        id old = [obj valueForKey:key];
        if (indexes && kind != NSKeyValueChangeInsertion) old = [old objectsAtIndexes:indexes];
        if (!indexes || kind != NSKeyValueChangeInsertion) [change setObject:old ? old : [NSNull null] forKey:NSKeyValueChangeOldKey];
    }
    pthread_mutex_lock(&kvoLock);
    NSMutableArray *stack = [info->_pending objectForKey:key];
    if (!stack) {
        stack = [NSMutableArray array];
        [info->_pending setObject:stack forKey:key];
    }
    [stack addObject:change];
    pthread_mutex_unlock(&kvoLock);
    for (__NSKVOObservance *o in obs) {
        if (!(o->_options & NSKeyValueObservingOptionPrior)) continue;
        NSMutableDictionary *prior = [NSMutableDictionary dictionaryWithObject:[change objectForKey:NSKeyValueChangeKindKey]
                                                                        forKey:NSKeyValueChangeKindKey];
        [prior setObject:(id)kCFBooleanTrue forKey:NSKeyValueChangeNotificationIsPriorKey];
        if ((o->_options & NSKeyValueObservingOptionOld) && [change objectForKey:NSKeyValueChangeOldKey])
            [prior setObject:[change objectForKey:NSKeyValueChangeOldKey] forKey:NSKeyValueChangeOldKey];
        if (indexes) [prior setObject:indexes forKey:NSKeyValueChangeIndexesKey];
        send(o, obj, prior);
    }
    for (NSString *d in dependents_of(obj, key)) [obj willChangeValueForKey:d];
}

static void
did_change(id obj, NSString *key)
{
    __NSKVOInfo *info = info_of(obj, NO);
    if (!info) return;
    pthread_mutex_lock(&kvoLock);
    NSMutableArray *stack = [info->_pending objectForKey:key];
    NSDictionary *pending = [[[stack lastObject] retain] autorelease];
    if (stack) [stack removeLastObject];
    pthread_mutex_unlock(&kvoLock);
    for (NSString *d in dependents_of(obj, key)) [obj didChangeValueForKey:d];
    if (!pending) return;
    NSKeyValueChange kind = [[pending objectForKey:NSKeyValueChangeKindKey] unsignedIntegerValue];
    NSIndexSet *indexes = [pending objectForKey:NSKeyValueChangeIndexesKey];
    id newValue = nil;
    BOOL haveNew = NO;
    for (__NSKVOObservance *o in observances_for(obj, key)) {
        NSMutableDictionary *change = [NSMutableDictionary dictionaryWithObject:[pending objectForKey:NSKeyValueChangeKindKey]
                                                                         forKey:NSKeyValueChangeKindKey];
        if (indexes) [change setObject:indexes forKey:NSKeyValueChangeIndexesKey];
        if ((o->_options & NSKeyValueObservingOptionOld) && [pending objectForKey:NSKeyValueChangeOldKey])
            [change setObject:[pending objectForKey:NSKeyValueChangeOldKey] forKey:NSKeyValueChangeOldKey];
        if (o->_options & NSKeyValueObservingOptionNew) {
            if (!haveNew) {
                newValue = [obj valueForKey:key];
                if (indexes) newValue = kind == NSKeyValueChangeRemoval ? nil : [newValue objectsAtIndexes:indexes];
                haveNew = YES;
            }
            if (!indexes || kind != NSKeyValueChangeRemoval) [change setObject:newValue ? newValue : [NSNull null] forKey:NSKeyValueChangeNewKey];
        }
        send(o, obj, change);
    }
}

/* MARK: - Key paths through other objects */

/* Observes the first key of "first.rest" on the root and "rest" on its
 * value, reporting changes to the original observer as changes of the
 * whole key path. */
@interface __NSKVOKeyPathHelper : NSObject {
@public
    id _root;                       /* not retained: the observed object */
    NSString *_first, *_rest, *_full;
    __NSKVOObservance *_observance; /* the original registration (not retained) */
    id _child;
    id _oldValue;
}
@end

@implementation __NSKVOKeyPathHelper

- (void)dealloc
{
    [_first release];
    [_rest release];
    [_full release];
    [_child release];
    [_oldValue release];
    [super dealloc];
}

- (void)_finchAttach
{
    [_child release];
    _child = [[_root valueForKey:_first] retain];
    /* old values only when the observer wants them: reading one can raise for a key the
       object only notifies about, which Apple's never reads unasked */
    NSKeyValueObservingOptions opts = NSKeyValueObservingOptionPrior;
    if (_observance && (_observance->_options & NSKeyValueObservingOptionOld))
        opts |= NSKeyValueObservingOptionOld;
    [_child addObserver:self forKeyPath:_rest options:opts context:NULL];
}

- (void)_finchDetach
{
    [_child removeObserver:self forKeyPath:_rest context:NULL];
    [_child release];
    _child = nil;
}

- (void)_finchReport:(NSDictionary *)prior
{
    __NSKVOObservance *o = _observance;
    if (prior) {
        [_oldValue release];
        _oldValue = (o->_options & NSKeyValueObservingOptionOld) ? [[_root valueForKeyPath:_full] retain] : nil;
        if (o->_options & NSKeyValueObservingOptionPrior) {
            NSMutableDictionary *c = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:NSKeyValueChangeSetting]
                                                                         forKey:NSKeyValueChangeKindKey];
            [c setObject:(id)kCFBooleanTrue forKey:NSKeyValueChangeNotificationIsPriorKey];
            if (o->_options & NSKeyValueObservingOptionOld) [c setObject:_oldValue ? _oldValue : [NSNull null] forKey:NSKeyValueChangeOldKey];
            send(o, _root, c);
        }
        return;
    }
    NSMutableDictionary *c = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:NSKeyValueChangeSetting]
                                                                 forKey:NSKeyValueChangeKindKey];
    if (o->_options & NSKeyValueObservingOptionOld) [c setObject:_oldValue ? _oldValue : [NSNull null] forKey:NSKeyValueChangeOldKey];
    if (o->_options & NSKeyValueObservingOptionNew) {
        id v = [_root valueForKeyPath:_full];
        [c setObject:v ? v : [NSNull null] forKey:NSKeyValueChangeNewKey];
    }
    send(o, _root, c);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    BOOL prior = [[change objectForKey:NSKeyValueChangeNotificationIsPriorKey] boolValue];
    if (object == _root) {      /* the first step changed: move to the new value */
        if (prior) {
            [self _finchReport:change];
            [self _finchDetach];
        } else {
            [self _finchAttach];
            [self _finchReport:nil];
        }
        return;
    }
    [self _finchReport:prior ? change : nil];
}

@end

/* MARK: - The notifying subclass */

static Class
original_class(id self)
{
    __NSKVOInfo *info = info_of(self, NO);
    return info && info->_original ? info->_original : object_getClass(self);
}

static NSMutableDictionary *setterKeys;      /* "Class|selector" -> key */

static NSString *
key_for_setter(id self, SEL _cmd)
{
    pthread_mutex_lock(&kvoLock);
    NSString *k = [[setterKeys objectForKey:[NSString stringWithFormat:@"%s|%s", class_getName(object_getClass(self)), sel_getName(_cmd)]] retain];
    pthread_mutex_unlock(&kvoLock);
    return [k autorelease];
}

#define NOTIFYING_SETTER(name, T) \
    static void name(id self, SEL _cmd, T v) \
    { \
        NSString *key = key_for_setter(self, _cmd); \
        BOOL quiet = [suppressed() containsObject:supp_key(self, key)]; \
        if (!quiet) [self willChangeValueForKey:key]; \
        ((void (*)(id, SEL, T))class_getMethodImplementation(original_class(self), _cmd))(self, _cmd, v); \
        if (!quiet) [self didChangeValueForKey:key]; \
    }
NOTIFYING_SETTER(set_long, long)
NOTIFYING_SETTER(set_float, float)
NOTIFYING_SETTER(set_double, double)
typedef struct { long a, b; } two_long;
typedef struct { double a, b; } two_double;
typedef struct { double a, b, c, d; } four_double;
typedef struct { float a, b; } two_float;
typedef struct { float a, b, c, d; } four_float;
NOTIFYING_SETTER(set_two_long, two_long)
NOTIFYING_SETTER(set_two_double, two_double)
NOTIFYING_SETTER(set_four_double, four_double)
NOTIFYING_SETTER(set_two_float, two_float)
NOTIFYING_SETTER(set_four_float, four_float)

/* The indexed accessors send collection changes. */
static void
insert_at(id self, SEL _cmd, id obj, NSUInteger i)
{
    NSString *key = key_for_setter(self, _cmd);
    NSIndexSet *idx = [NSIndexSet indexSetWithIndex:i];
    [self willChange:NSKeyValueChangeInsertion valuesAtIndexes:idx forKey:key];
    ((void (*)(id, SEL, id, NSUInteger))class_getMethodImplementation(original_class(self), _cmd))(self, _cmd, obj, i);
    [self didChange:NSKeyValueChangeInsertion valuesAtIndexes:idx forKey:key];
}

static void
remove_at(id self, SEL _cmd, NSUInteger i)
{
    NSString *key = key_for_setter(self, _cmd);
    NSIndexSet *idx = [NSIndexSet indexSetWithIndex:i];
    [self willChange:NSKeyValueChangeRemoval valuesAtIndexes:idx forKey:key];
    ((void (*)(id, SEL, NSUInteger))class_getMethodImplementation(original_class(self), _cmd))(self, _cmd, i);
    [self didChange:NSKeyValueChangeRemoval valuesAtIndexes:idx forKey:key];
}

static void
replace_at(id self, SEL _cmd, NSUInteger i, id obj)
{
    NSString *key = key_for_setter(self, _cmd);
    NSIndexSet *idx = [NSIndexSet indexSetWithIndex:i];
    [self willChange:NSKeyValueChangeReplacement valuesAtIndexes:idx forKey:key];
    ((void (*)(id, SEL, NSUInteger, id))class_getMethodImplementation(original_class(self), _cmd))(self, _cmd, i, obj);
    [self didChange:NSKeyValueChangeReplacement valuesAtIndexes:idx forKey:key];
}

static Class
kvo_class_class(id self, SEL _cmd)
{
    return original_class(self);
}

static BOOL
kvo_is_kvoa(id self, SEL _cmd)
{
    return YES;
}

/* Count a struct encoding's scalar members by kind, skipping the names
 * ("{CGPoint=dd}" is two doubles). */
static void
leaves(const char *t, int *nd, int *nf, int *other)
{
    for (; *t; t++) {
        if (*t == '{' || *t == '(') {
            while (*t && *t != '=' && *t != '}' && *t != ')') t++;
            if (*t != '=') return;
            continue;
        }
        if (*t == '}' || *t == ')') continue;
        if (*t == '"') { t = strchr(t + 1, '"'); if (!t) return; continue; }
        if (*t == 'd') (*nd)++;
        else if (*t == 'f') (*nf)++;
        else if (strchr("cCsSiIlLqQB*:#@^", *t)) {
            (*other)++;
            if (*t == '^') { t++; if (*t == '{') { int depth = 0; do { if (*t == '{') depth++; if (*t == '}') depth--; t++; } while (*t && depth); t--; } }
        }
    }
}

/* The setter IMP for an argument type, by how the arm64 ABI passes it. */
static IMP
setter_imp(const char *type)
{
    while (*type && strchr("rnNoORV", *type)) type++;
    if (*type == 'f') return (IMP)set_float;
    if (*type == 'd') return (IMP)set_double;
    if (*type == '{') {
        NSUInteger size;
        NSGetSizeAndAlignment(type, &size, NULL);
        int nd = 0, nf = 0, other = 0;
        leaves(type, &nd, &nf, &other);
        BOOL allDouble = nd && !nf && !other, allFloat = nf && !nd && !other;
        int members = nd + nf + other;
        if (allDouble && members == 2) return (IMP)set_two_double;
        if (allDouble && members == 4) return (IMP)set_four_double;
        if (allFloat && members == 2) return (IMP)set_two_float;
        if (allFloat && members == 4) return (IMP)set_four_float;
        if (size <= 8) return (IMP)set_long;
        if (size <= 16) return (IMP)set_two_long;
        return NULL;                /* larger structs: not observed automatically */
    }
    return (IMP)set_long;           /* integers, pointers, objects: one x register */
}

static Class
notifying_class(Class original)
{
    const char *name = class_getName(original);
    char kvoName[512];
    snprintf(kvoName, sizeof(kvoName), "NSKVONotifying_%s", name);
    Class k = objc_getClass(kvoName);
    if (k) return k;
    k = objc_allocateClassPair(original, kvoName, 0);
    class_addMethod(k, @selector(class), (IMP)kvo_class_class, "#16@0:8");
    class_addMethod(k, sel_registerName("_isKVOA"), (IMP)kvo_is_kvoa, "B16@0:8");
    objc_registerClassPair(k);
    return k;
}

static void
override(Class kvo, SEL sel, IMP imp, const char *types, NSString *key)
{
    pthread_mutex_lock(&kvoLock);
    if (!setterKeys) setterKeys = [[NSMutableDictionary alloc] init];
    [setterKeys setObject:key forKey:[NSString stringWithFormat:@"%s|%s", class_getName(kvo), sel_getName(sel)]];
    pthread_mutex_unlock(&kvoLock);
    class_addMethod(kvo, sel, imp, types);
}

/* Make `obj` notify for `key` automatically. */
static void
install_notifying(id obj, NSString *key)
{
    Class original = original_class(obj);
    if (![original automaticallyNotifiesObserversForKey:key]) return;
    Class kvo = notifying_class(original);
    NSString *cap = capitalized(key);
    SEL setters[] = { NSSelectorFromString([NSString stringWithFormat:@"set%@:", cap]),
                      NSSelectorFromString([NSString stringWithFormat:@"_set%@:", cap]) };
    for (int i = 0; i < 2; i++) {
        Method m = class_getInstanceMethod(original, setters[i]);
        if (!m) continue;
        char arg[256];
        method_getArgumentType(m, 2, arg, sizeof(arg));
        IMP imp = setter_imp(arg);
        if (imp) override(kvo, setters[i], imp, method_getTypeEncoding(m), key);
    }
    struct { NSString *fmt; IMP imp; } indexed[] = {
        { @"insertObject:in%@AtIndex:", (IMP)insert_at },
        { @"removeObjectFrom%@AtIndex:", (IMP)remove_at },
        { @"replaceObjectIn%@AtIndex:withObject:", (IMP)replace_at },
    };
    for (int i = 0; i < 3; i++) {
        SEL s = NSSelectorFromString([NSString stringWithFormat:indexed[i].fmt, cap]);
        Method m = class_getInstanceMethod(original, s);
        if (m) override(kvo, s, indexed[i].imp, method_getTypeEncoding(m), key);
    }
    if (object_getClass(obj) != kvo) {
        __NSKVOInfo *info = info_of(obj, YES);
        info->_original = original;
        object_setClass(obj, kvo);
    }
}

/* MARK: - NSObject */

@implementation NSObject (NSKeyValueObserving)

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context
{
    FinchRaise(NSInternalInconsistencyException, "%@: An -observeValueForKeyPath:ofObject:change:context: message was received but not handled.\nKey path: %@\nObserved object: %@\nChange: %@\nContext: %p",
        self, keyPath, object, change, context);
}

@end

@implementation NSObject (NSKeyValueObserverRegistration)

- (void)addObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options context:(void *)context
{
    __NSKVOObservance *o = [[[__NSKVOObservance alloc] init] autorelease];
    o->_observer = observer;
    o->_keyPath = [keyPath copy];
    o->_options = options;
    o->_context = context;
    NSRange dot = [keyPath rangeOfString:@"."];
    if (dot.location != NSNotFound) {
        __NSKVOKeyPathHelper *h = [[__NSKVOKeyPathHelper alloc] init];
        h->_root = self;
        h->_first = [[keyPath substringToIndex:dot.location] copy];
        h->_rest = [[keyPath substringFromIndex:dot.location + 1] copy];
        h->_full = [keyPath copy];
        h->_observance = o;
        o->_helper = h;
        pthread_mutex_lock(&kvoLock);
        [info_of(self, YES)->_observances addObject:o];
        pthread_mutex_unlock(&kvoLock);
        [self addObserver:h forKeyPath:h->_first options:NSKeyValueObservingOptionPrior context:NULL];
        [h _finchAttach];
    } else {
        pthread_mutex_lock(&kvoLock);
        [info_of(self, YES)->_observances addObject:o];
        pthread_mutex_unlock(&kvoLock);
        install_notifying(self, keyPath);
        /* Dependent keys: register for what affects this key, once. */
        for (NSString *affecting in [[self class] keyPathsForValuesAffectingValueForKey:keyPath]) {
            pthread_mutex_lock(&kvoLock);
            __NSKVOInfo *info = info_of(self, YES);
            NSMutableSet *deps = [info->_dependents objectForKey:affecting];
            BOOL first = !deps;
            if (!deps) {
                deps = [NSMutableSet set];
                [info->_dependents setObject:deps forKey:affecting];
            }
            [deps addObject:keyPath];
            pthread_mutex_unlock(&kvoLock);
            if (first) install_notifying(self, affecting);
        }
    }
    if (options & NSKeyValueObservingOptionInitial) {
        NSMutableDictionary *c = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:NSKeyValueChangeSetting]
                                                                     forKey:NSKeyValueChangeKindKey];
        if (options & NSKeyValueObservingOptionNew) {
            id v = [self valueForKeyPath:keyPath];
            [c setObject:v ? v : [NSNull null] forKey:NSKeyValueChangeNewKey];
        }
        send(o, self, c);
    }
}

static void
remove_observance(id self, NSObject *observer, NSString *keyPath, BOOL anyContext, void *context)
{
    pthread_mutex_lock(&kvoLock);
    __NSKVOInfo *info = info_of(self, NO);
    __NSKVOObservance *found = nil;
    for (NSInteger i = (NSInteger)[info->_observances count] - 1; i >= 0; i--) {
        __NSKVOObservance *o = [info->_observances objectAtIndex:(NSUInteger)i];
        if (o->_observer == observer && [o->_keyPath isEqualToString:keyPath] && (anyContext || o->_context == context)) {
            found = [[o retain] autorelease];
            [info->_observances removeObjectAtIndex:(NSUInteger)i];
            break;
        }
    }
    BOOL empty = info && [info->_observances count] == 0;
    pthread_mutex_unlock(&kvoLock);
    if (!found) {
        [NSException raise:NSRangeException
                    format:@"Cannot remove an observer <%@ %p> for the key path \"%@\" from <%@ %p> because it is not registered as an observer.",
                           [observer class], observer, keyPath, [self class], self];
    }
    if (found->_helper) {
        __NSKVOKeyPathHelper *h = found->_helper;
        [h _finchDetach];
        [self removeObserver:h forKeyPath:h->_first context:NULL];
        return;
    }
    if (empty && object_getClass(self) != info->_original && info->_original) {
        object_setClass(self, info->_original);
        pthread_mutex_lock(&kvoLock);
        [info->_dependents removeAllObjects];
        pthread_mutex_unlock(&kvoLock);
    }
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context
{
    remove_observance(self, observer, keyPath, NO, context);
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath
{
    remove_observance(self, observer, keyPath, YES, NULL);
}

@end

@implementation NSObject (NSKeyValueObserverNotification)

- (void)willChangeValueForKey:(NSString *)key { will_change(self, key, NSKeyValueChangeSetting, nil); }
- (void)didChangeValueForKey:(NSString *)key { did_change(self, key); }
- (void)willChange:(NSKeyValueChange)changeKind valuesAtIndexes:(NSIndexSet *)indexes forKey:(NSString *)key
{
    will_change(self, key, changeKind, indexes);
}
- (void)didChange:(NSKeyValueChange)changeKind valuesAtIndexes:(NSIndexSet *)indexes forKey:(NSString *)key { did_change(self, key); }
- (void)willChangeValueForKey:(NSString *)key withSetMutation:(NSKeyValueSetMutationKind)m usingObjects:(NSSet *)objects
{
    will_change(self, key, m == NSKeyValueUnionSetMutation ? NSKeyValueChangeInsertion : m == NSKeyValueMinusSetMutation ? NSKeyValueChangeRemoval : NSKeyValueChangeReplacement, nil);
}
- (void)didChangeValueForKey:(NSString *)key withSetMutation:(NSKeyValueSetMutationKind)m usingObjects:(NSSet *)objects { did_change(self, key); }

@end

@implementation NSObject (NSKeyValueObservingCustomization)

+ (NSSet<NSString *> *)keyPathsForValuesAffectingValueForKey:(NSString *)key
{
    SEL s = NSSelectorFromString([@"keyPathsForValuesAffecting" stringByAppendingString:capitalized(key)]);
    if ([self respondsToSelector:s]) return ((id (*)(id, SEL))objc_msgSend)(self, s);
    return [NSSet set];
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    SEL s = NSSelectorFromString([@"automaticallyNotifiesObserversOf" stringByAppendingString:capitalized(key)]);
    if ([self respondsToSelector:s]) return ((BOOL (*)(id, SEL))objc_msgSend)(self, s);
    return YES;
}

- (void *)observationInfo { return info_of(self, NO); }
- (void)setObservationInfo:(void *)observationInfo { }

@end

/* Collections can't be observed as a whole, as on macOS. */
#define UNSUPPORTED(cls) \
    @implementation cls (FinchKVO) \
    - (void)addObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options context:(void *)context \
    { \
        [NSException raise:NSInvalidArgumentException format:@"[<%s %p> addObserver:forKeyPath:options:context:] is not supported. Key path: %@", \
            object_getClassName(self), self, keyPath]; \
    } \
    - (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context \
    { \
        [NSException raise:NSInvalidArgumentException format:@"[<%s %p> removeObserver:forKeyPath:context:] is not supported. Key path: %@", \
            object_getClassName(self), self, keyPath]; \
    } \
    - (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath { [self removeObserver:observer forKeyPath:keyPath context:NULL]; } \
    @end
UNSUPPORTED(NSArray)
UNSUPPORTED(NSSet)

@implementation NSArray (NSKeyValueObserverRegistration)
- (void)addObserver:(NSObject *)observer toObjectsAtIndexes:(NSIndexSet *)indexes forKeyPath:(NSString *)keyPath
            options:(NSKeyValueObservingOptions)options context:(void *)context
{
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [[self objectAtIndex:idx] addObserver:observer forKeyPath:keyPath options:options context:context];
    }];
}
- (void)removeObserver:(NSObject *)observer fromObjectsAtIndexes:(NSIndexSet *)indexes forKeyPath:(NSString *)keyPath context:(void *)context
{
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [[self objectAtIndex:idx] removeObserver:observer forKeyPath:keyPath context:context];
    }];
}
- (void)removeObserver:(NSObject *)observer fromObjectsAtIndexes:(NSIndexSet *)indexes forKeyPath:(NSString *)keyPath
{
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [[self objectAtIndex:idx] removeObserver:observer forKeyPath:keyPath];
    }];
}
@end

/* For the array proxy (NSKeyValueCoding.m): run `body` with the object's
 * automatic setter notification for `key` off. */
__attribute__((visibility("hidden"))) void
FinchKVOQuietly(id obj, NSString *key, void (^body)(void))
{
    NSString *k = supp_key(obj, key);
    [suppressed() addObject:k];
    @try {
        body();
    } @finally {
        [suppressed() removeObject:k];
    }
}
