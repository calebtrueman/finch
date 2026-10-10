/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSPointerFunctions, NSHashTable, NSMapTable and NSPointerArray, with the C
 * functions of <Foundation/NSHashTable.h> and <Foundation/NSMapTable.h>, and
 * NSCache (docs/design/FOUNDATION.md), against the SDK's headers.
 *
 * Every table keeps its entries in malloc'd nodes, so weak slots never move
 * (objc_storeWeak/objc_loadWeak work on them in place) and entries whose
 * weak key or value has been reclaimed are purged as they are found. The
 * behaviour of an item comes from its pointer functions: memory (strong:
 * retained if an object; weak; opaque; malloc: freed), personality (object:
 * -hash/-isEqual:; pointer identity; C string; struct by size; integer) and
 * copy-in. The C API's callback structs drive the same tables.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

id objc_loadWeak(id *location);
id objc_storeWeak(id *location, id obj);

/* MARK: - Item behaviour */

typedef struct Funcs {
    NSPointerFunctionsOptions options;
    BOOL weak, copyIn;
    NSUInteger (*hash)(const void *, NSUInteger (*)(const void *));
    BOOL (*equal)(const void *, const void *, NSUInteger (*)(const void *));
    NSUInteger (*size)(const void *);
    NSString *(*describe)(const void *);
    void (*relinquish)(const void *, NSUInteger (*)(const void *));
    void *(*acquire)(const void *, NSUInteger (*)(const void *), BOOL);
    /* The C API's callbacks, called with the table. */
    BOOL legacy;
    NSUInteger (*lhash)(id, const void *);
    BOOL (*lequal)(id, const void *, const void *);
    void (*lretain)(id, const void *);
    void (*lrelease)(id, void *);
    NSString *(*ldescribe)(id, const void *);
} Funcs;

static NSUInteger object_hash(const void *p, NSUInteger (*s)(const void *)) { return [(id)p hash]; }
static BOOL object_equal(const void *a, const void *b, NSUInteger (*s)(const void *)) { return a == b || [(id)a isEqual:(id)b]; }
static NSString *object_describe(const void *p) { return [(id)p description]; }
static NSUInteger pointer_hash(const void *p, NSUInteger (*s)(const void *)) { return (NSUInteger)(uintptr_t)p >> 2; }
static BOOL pointer_equal(const void *a, const void *b, NSUInteger (*s)(const void *)) { return a == b; }
static NSString *pointer_describe(const void *p) { return [NSString stringWithFormat:@"%p", p]; }
static NSUInteger cstring_hash(const void *p, NSUInteger (*s)(const void *))
{
    NSUInteger h = 5381;
    for (const unsigned char *c = p; *c; c++) h = h * 33 + *c;
    return h;
}
static BOOL cstring_equal(const void *a, const void *b, NSUInteger (*s)(const void *)) { return a == b || (a && b && !strcmp(a, b)); }
static NSString *cstring_describe(const void *p) { return [NSString stringWithUTF8String:p]; }
static NSUInteger cstring_size(const void *p) { return strlen(p) + 1; }
static NSUInteger struct_hash(const void *p, NSUInteger (*s)(const void *))
{
    NSUInteger n = s ? s(p) : 0, h = 5381;
    for (NSUInteger i = 0; i < n; i++) h = h * 33 + ((const unsigned char *)p)[i];
    return h;
}
static BOOL struct_equal(const void *a, const void *b, NSUInteger (*s)(const void *))
{
    if (a == b) return YES;
    NSUInteger n = s ? s(a) : 0;
    return n == (s ? s(b) : 0) && !memcmp(a, b, n);
}
static NSString *struct_describe(const void *p) { return [NSString stringWithFormat:@"<struct %p>", p]; }
static NSUInteger integer_hash(const void *p, NSUInteger (*s)(const void *)) { return (NSUInteger)(uintptr_t)p; }
static NSString *integer_describe(const void *p) { return [NSString stringWithFormat:@"%ld", (long)(intptr_t)p]; }
static void release_object(const void *p, NSUInteger (*s)(const void *)) { [(id)p release]; }
static void free_memory(const void *p, NSUInteger (*s)(const void *)) { free((void *)p); }
static void *retain_object(const void *p, NSUInteger (*s)(const void *), BOOL copy)
{
    return copy ? (void *)[(id)p copy] : (void *)[(id)p retain];
}
static void *copy_memory(const void *p, NSUInteger (*s)(const void *), BOOL copy)
{
    if (!copy || !s) return (void *)p;
    NSUInteger n = s(p);
    void *m = malloc(n);
    memcpy(m, p, n);
    return m;
}

static Funcs
funcs_for(NSPointerFunctionsOptions options)
{
    Funcs f;
    memset(&f, 0, sizeof(f));
    f.options = options;
    NSUInteger memory = options & 0xFF, personality = options & 0xFF00;
    f.copyIn = (options & NSPointerFunctionsCopyIn) != 0;
    switch (personality) {
    case NSPointerFunctionsOpaquePersonality: f.hash = pointer_hash; f.equal = pointer_equal; f.describe = pointer_describe; break;
    case NSPointerFunctionsObjectPointerPersonality: f.hash = pointer_hash; f.equal = pointer_equal; f.describe = object_describe; break;
    case NSPointerFunctionsCStringPersonality: f.hash = cstring_hash; f.equal = cstring_equal; f.describe = cstring_describe; f.size = cstring_size; break;
    case NSPointerFunctionsStructPersonality: f.hash = struct_hash; f.equal = struct_equal; f.describe = struct_describe; break;
    case NSPointerFunctionsIntegerPersonality: f.hash = integer_hash; f.equal = pointer_equal; f.describe = integer_describe; break;
    default: f.hash = object_hash; f.equal = object_equal; f.describe = object_describe; break;
    }
    BOOL objects = personality == NSPointerFunctionsObjectPersonality || personality == NSPointerFunctionsObjectPointerPersonality;
    switch (memory) {
    case NSPointerFunctionsWeakMemory:
        f.weak = YES;
        break;
    case NSPointerFunctionsMallocMemory:
        f.relinquish = free_memory;
        f.acquire = copy_memory;
        break;
    case NSPointerFunctionsOpaqueMemory:
    case NSPointerFunctionsZeroingWeakMemory:
    case NSPointerFunctionsMachVirtualMemory:
        break;
    default:
        if (objects) {
            f.acquire = retain_object;
            f.relinquish = release_object;
        }
        break;
    }
    return f;
}

static NSUInteger
f_hash(Funcs *f, id table, const void *p)
{
    if (f->legacy) return f->lhash ? f->lhash(table, p) : (NSUInteger)(uintptr_t)p >> 2;
    return f->hash ? f->hash(p, f->size) : (NSUInteger)(uintptr_t)p >> 2;
}

static BOOL
f_equal(Funcs *f, id table, const void *a, const void *b)
{
    if (f->legacy) return f->lequal ? f->lequal(table, a, b) : a == b;
    return f->equal ? f->equal(a, b, f->size) : a == b;
}

static void *
f_acquire(Funcs *f, id table, const void *p)
{
    if (f->legacy) {
        if (f->lretain) f->lretain(table, p);
        return (void *)p;
    }
    return f->acquire ? f->acquire(p, f->size, f->copyIn) : (void *)p;
}

static void
f_relinquish(Funcs *f, id table, void *p)
{
    if (!p) return;
    if (f->legacy) {
        if (f->lrelease) f->lrelease(table, p);
        return;
    }
    if (f->relinquish) f->relinquish(p, f->size);
}

static NSString *
f_describe(Funcs *f, id table, const void *p)
{
    NSString *s = f->legacy ? (f->ldescribe ? f->ldescribe(table, p) : pointer_describe(p)) : (f->describe ? f->describe(p) : pointer_describe(p));
    return s ? s : @"(null)";
}

/* A slot holds an item, weakly if the functions say so. */
static void *
slot_get(Funcs *f, void **slot)
{
    return f->weak ? (void *)objc_loadWeak((id *)slot) : *slot;
}

static void
slot_set(Funcs *f, id table, void **slot, const void *p)
{
    if (f->weak) {
        objc_storeWeak((id *)slot, (id)p);
    } else {
        *slot = f_acquire(f, table, p);
    }
}

static void
slot_clear(Funcs *f, id table, void **slot)
{
    if (f->weak) {
        objc_storeWeak((id *)slot, nil);
    } else {
        void *old = *slot;
        *slot = NULL;
        f_relinquish(f, table, old);
    }
}

/* MARK: - NSPointerFunctions */

@interface NSPointerFunctions () {
@public
    Funcs _f;
}
@end

@implementation NSPointerFunctions

- (instancetype)initWithOptions:(NSPointerFunctionsOptions)options
{
    if ((self = [super init])) _f = funcs_for(options);
    return self;
}

- (instancetype)init { return [self initWithOptions:0]; }
+ (NSPointerFunctions *)pointerFunctionsWithOptions:(NSPointerFunctionsOptions)options { return [[[self alloc] initWithOptions:options] autorelease]; }

- (id)copyWithZone:(NSZone *)zone
{
    NSPointerFunctions *c = [[NSPointerFunctions allocWithZone:zone] initWithOptions:_f.options];
    c->_f = _f;
    return c;
}

- (NSUInteger (*)(const void *, NSUInteger (*)(const void *)))hashFunction { return _f.hash; }
- (void)setHashFunction:(NSUInteger (*)(const void *, NSUInteger (*)(const void *)))fn { _f.hash = fn; }
- (BOOL (*)(const void *, const void *, NSUInteger (*)(const void *)))isEqualFunction { return _f.equal; }
- (void)setIsEqualFunction:(BOOL (*)(const void *, const void *, NSUInteger (*)(const void *)))fn { _f.equal = fn; }
- (NSUInteger (*)(const void *))sizeFunction { return _f.size; }
- (void)setSizeFunction:(NSUInteger (*)(const void *))fn { _f.size = fn; }
- (NSString *(*)(const void *))descriptionFunction { return _f.describe; }
- (void)setDescriptionFunction:(NSString *(*)(const void *))fn { _f.describe = fn; }
- (void (*)(const void *, NSUInteger (*)(const void *)))relinquishFunction { return _f.relinquish; }
- (void)setRelinquishFunction:(void (*)(const void *, NSUInteger (*)(const void *)))fn { _f.relinquish = fn; }
- (void *(*)(const void *, NSUInteger (*)(const void *), BOOL))acquireFunction { return _f.acquire; }
- (void)setAcquireFunction:(void *(*)(const void *, NSUInteger (*)(const void *), BOOL))fn { _f.acquire = fn; }
- (BOOL)usesStrongWriteBarrier { return !_f.weak; }
- (void)setUsesStrongWriteBarrier:(BOOL)flag { }
- (BOOL)usesWeakReadAndWriteBarriers { return _f.weak; }
- (void)setUsesWeakReadAndWriteBarriers:(BOOL)flag { _f.weak = flag; }

@end

static NSPointerFunctions *
pointer_functions(Funcs f)
{
    NSPointerFunctions *p = [[[NSPointerFunctions alloc] initWithOptions:f.options] autorelease];
    p->_f = f;
    return p;
}

/* MARK: - The hash table under NSHashTable and NSMapTable */

typedef struct Node {
    struct Node *next;
    NSUInteger hash;
    void *key, *value;
} Node;

typedef struct {
    Node **buckets;
    NSUInteger capacity, count;
    unsigned long mutations;
} Table;

static void
table_init(Table *t, NSUInteger capacity)
{
    t->capacity = 8;
    while (t->capacity < capacity * 2) t->capacity *= 2;
    t->buckets = calloc(t->capacity, sizeof(Node *));
    t->count = 0;
}

static void
table_grow(Table *t)
{
    NSUInteger cap = t->capacity * 2;
    Node **b = calloc(cap, sizeof(Node *));
    for (NSUInteger i = 0; i < t->capacity; i++) {
        for (Node *n = t->buckets[i], *next; n; n = next) {
            next = n->next;
            n->next = b[n->hash & (cap - 1)];
            b[n->hash & (cap - 1)] = n;
        }
    }
    free(t->buckets);
    t->buckets = b;
    t->capacity = cap;
}

static void
node_free(Node *n, Funcs *kf, Funcs *vf, id table)
{
    slot_clear(kf, table, &n->key);
    if (vf) slot_clear(vf, table, &n->value);
    free(n);
}

/* Drop entries whose weak key or value is gone. */
static void
table_purge(Table *t, Funcs *kf, Funcs *vf, id table)
{
    if (!kf->weak && !(vf && vf->weak)) return;
    for (NSUInteger i = 0; i < t->capacity; i++) {
        for (Node **p = &t->buckets[i]; *p;) {
            Node *n = *p;
            BOOL dead = (kf->weak && !slot_get(kf, &n->key)) || (vf && vf->weak && !slot_get(vf, &n->value));
            if (dead) {
                *p = n->next;
                node_free(n, kf, vf, table);
                t->count--;
                t->mutations++;
            } else {
                p = &n->next;
            }
        }
    }
}

static Node *
table_find(Table *t, Funcs *kf, id table, const void *key, NSUInteger hash)
{
    for (Node *n = t->buckets[hash & (t->capacity - 1)]; n; n = n->next) {
        if (n->hash != hash) continue;
        void *k = slot_get(kf, &n->key);
        if (k && f_equal(kf, table, k, key)) return n;
    }
    return NULL;
}

static void
table_remove(Table *t, Funcs *kf, Funcs *vf, id table, const void *key)
{
    NSUInteger h = f_hash(kf, table, key);
    for (Node **p = &t->buckets[h & (t->capacity - 1)]; *p; p = &(*p)->next) {
        Node *n = *p;
        if (n->hash != h) continue;
        void *k = slot_get(kf, &n->key);
        if (k && f_equal(kf, table, k, key)) {
            *p = n->next;
            node_free(n, kf, vf, table);
            t->count--;
            t->mutations++;
            return;
        }
    }
}

/* Insert or replace; returns the node. */
static Node *
table_set(Table *t, Funcs *kf, Funcs *vf, id table, const void *key, const void *value, BOOL replaceKey)
{
    NSUInteger h = f_hash(kf, table, key);
    Node *n = table_find(t, kf, table, key, h);
    if (n) {
        if (vf) {
            void *old = vf->weak ? NULL : n->value;
            if (vf->weak) slot_set(vf, table, &n->value, value);
            else {
                n->value = f_acquire(vf, table, value);
                f_relinquish(vf, table, old);
            }
        }
        if (replaceKey) {
            slot_clear(kf, table, &n->key);
            slot_set(kf, table, &n->key, key);
        }
        t->mutations++;
        return n;
    }
    if (t->count + 1 > t->capacity * 3 / 4) table_grow(t);
    n = calloc(1, sizeof(Node));
    n->hash = h;
    slot_set(kf, table, &n->key, key);
    if (vf) slot_set(vf, table, &n->value, value);
    n->next = t->buckets[h & (t->capacity - 1)];
    t->buckets[h & (t->capacity - 1)] = n;
    t->count++;
    t->mutations++;
    return n;
}

static void
table_clear(Table *t, Funcs *kf, Funcs *vf, id table)
{
    for (NSUInteger i = 0; i < t->capacity; i++) {
        for (Node *n = t->buckets[i], *next; n; n = next) {
            next = n->next;
            node_free(n, kf, vf, table);
        }
        t->buckets[i] = NULL;
    }
    t->count = 0;
    t->mutations++;
}

/* Each live entry's key and value, with its bucket. */
static void
table_each(Table *t, Funcs *kf, Funcs *vf, void (^fn)(NSUInteger bucket, void *key, void *value, BOOL *stop))
{
    BOOL stop = NO;
    for (NSUInteger i = 0; i < t->capacity && !stop; i++) {
        for (Node *n = t->buckets[i]; n && !stop; n = n->next) {
            void *k = slot_get(kf, &n->key);
            void *v = vf ? slot_get(vf, &n->value) : NULL;
            if (!k || (vf && vf->weak && !v)) continue;
            fn(i, k, v, &stop);
        }
    }
}

/* Fast enumeration over a snapshot kept alive by the autorelease pool. */
static NSUInteger
enumerate_snapshot(NSFastEnumerationState *state, id __unsafe_unretained buffer[], NSUInteger len, NSPointerArray *(^snapshot)(void))
{
    if (state->state == 0) {
        NSMutableData *d = [NSMutableData data];
        for (id o in [snapshot() allObjects]) [d appendBytes:&o length:sizeof(o)];
        /* autoreleased: it lasts the enumeration, as the loop runs in this pool */
        state->extra[1] = (unsigned long)(uintptr_t)d;
        state->mutationsPtr = &state->extra[0];
        state->state = 1;
        state->extra[2] = 0;
    }
    NSData *d = (NSData *)(uintptr_t)state->extra[1];
    NSUInteger total = [d length] / sizeof(id), at = state->extra[2], k = 0;
    const id *items = [d bytes];
    for (; at < total && k < len; at++, k++) buffer[k] = items[at];
    state->extra[2] = at;
    state->itemsPtr = buffer;
    return k;
}

/* MARK: - NSHashTable */

@interface NSConcreteHashTable : NSHashTable {
@public
    Funcs _f;
    Table _t;
}
@end

@implementation NSHashTable

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSHashTable class]) return [NSConcreteHashTable allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (NSHashTable *)hashTableWithOptions:(NSPointerFunctionsOptions)options { return [[[self alloc] initWithOptions:options capacity:0] autorelease]; }
+ (id)hashTableWithWeakObjects { return [self hashTableWithOptions:NSPointerFunctionsWeakMemory]; }
+ (NSHashTable *)weakObjectsHashTable { return [self hashTableWithOptions:NSPointerFunctionsWeakMemory]; }
+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init { return [self initWithOptions:0 capacity:0]; }
- (instancetype)initWithOptions:(NSPointerFunctionsOptions)options capacity:(NSUInteger)initialCapacity { return [super init]; }
- (instancetype)initWithPointerFunctions:(NSPointerFunctions *)functions capacity:(NSUInteger)initialCapacity { return [super init]; }

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:[self allObjects] forKey:@"NS.objects"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSArray *a = [coder decodeObjectOfClass:[NSArray class] forKey:@"NS.objects"];
    if ((self = [self initWithOptions:0 capacity:[a count]])) for (id o in a) [self addObject:o];
    return self;
}

@end

@implementation NSConcreteHashTable

- (instancetype)initWithOptions:(NSPointerFunctionsOptions)options capacity:(NSUInteger)initialCapacity
{
    if ((self = [super initWithOptions:options capacity:initialCapacity])) {
        _f = funcs_for(options);
        table_init(&_t, initialCapacity);
    }
    return self;
}

- (instancetype)initWithPointerFunctions:(NSPointerFunctions *)functions capacity:(NSUInteger)initialCapacity
{
    if ((self = [super initWithOptions:0 capacity:initialCapacity])) {
        _f = functions->_f;
        table_init(&_t, initialCapacity);
    }
    return self;
}

- (void)dealloc
{
    table_clear(&_t, &_f, NULL, self);
    free(_t.buckets);
    [super dealloc];
}

- (NSPointerFunctions *)pointerFunctions { return pointer_functions(_f); }
- (NSUInteger)count { table_purge(&_t, &_f, NULL, self); return _t.count; }

- (id)member:(id)object
{
    if (!object) return nil;
    Node *n = table_find(&_t, &_f, self, object, f_hash(&_f, self, object));
    return n ? (id)slot_get(&_f, &n->key) : nil;
}

- (void)addObject:(id)object { if (object) table_set(&_t, &_f, NULL, self, object, NULL, NO); }
- (void)removeObject:(id)object { if (object) table_remove(&_t, &_f, NULL, self, object); }
- (void)removeAllObjects { table_clear(&_t, &_f, NULL, self); }
- (BOOL)containsObject:(id)anObject { return [self member:anObject] != nil; }

- (NSArray *)allObjects
{
    NSMutableArray *a = [NSMutableArray array];
    table_each(&_t, &_f, NULL, ^(NSUInteger b, void *k, void *v, BOOL *stop) { [a addObject:(id)k]; });
    return a;
}

- (id)anyObject
{
    __block id any = nil;
    table_each(&_t, &_f, NULL, ^(NSUInteger b, void *k, void *v, BOOL *stop) { any = (id)k; *stop = YES; });
    return any;
}

- (NSEnumerator *)objectEnumerator { return [[self allObjects] objectEnumerator]; }
- (NSSet *)setRepresentation { return [NSSet setWithArray:[self allObjects]]; }

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    return enumerate_snapshot(state, buffer, len, ^NSPointerArray *(void) {
        NSPointerArray *p = [NSPointerArray pointerArrayWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality];
        table_each(&_t, &_f, NULL, ^(NSUInteger b, void *k, void *v, BOOL *stop) { [p addPointer:k]; });
        return p;
    });
}

- (BOOL)intersectsHashTable:(NSHashTable *)other
{
    for (id o in [self allObjects]) if ([other containsObject:o]) return YES;
    return NO;
}
- (BOOL)isEqualToHashTable:(NSHashTable *)other { return [self count] == [other count] && [self isSubsetOfHashTable:other]; }
- (BOOL)isSubsetOfHashTable:(NSHashTable *)other
{
    for (id o in [self allObjects]) if (![other containsObject:o]) return NO;
    return YES;
}
- (void)intersectHashTable:(NSHashTable *)other { for (id o in [self allObjects]) if (![other containsObject:o]) [self removeObject:o]; }
- (void)unionHashTable:(NSHashTable *)other { for (id o in [other allObjects]) [self addObject:o]; }
- (void)minusHashTable:(NSHashTable *)other { for (id o in [other allObjects]) [self removeObject:o]; }
- (BOOL)isEqual:(id)object { return object == self || ([object isKindOfClass:[NSHashTable class]] && [self isEqualToHashTable:object]); }
- (NSUInteger)hash { return [self count]; }

- (id)copyWithZone:(NSZone *)zone
{
    NSConcreteHashTable *c = [[NSConcreteHashTable allocWithZone:zone] initWithPointerFunctions:[self pointerFunctions] capacity:_t.count];
    table_each(&_t, &_f, NULL, ^(NSUInteger b, void *k, void *v, BOOL *stop) { table_set(&c->_t, &c->_f, NULL, c, k, NULL, NO); });
    return c;
}

/* Apple's: "NSHashTable {\n[bucket] item\n}\n". */
- (NSString *)description
{
    NSMutableString *s = [NSMutableString stringWithString:@"NSHashTable {\n"];
    table_each(&_t, &_f, NULL, ^(NSUInteger b, void *k, void *v, BOOL *stop) {
        [s appendFormat:@"[%lu] %@\n", (unsigned long)b, f_describe(&_f, self, k)];
    });
    [s appendString:@"}\n"];
    return s;
}

@end

/* MARK: - NSMapTable */

@interface NSConcreteMapTable : NSMapTable {
@public
    Funcs _kf, _vf;
    Table _t;
}
@end

@implementation NSMapTable

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSMapTable class]) return [NSConcreteMapTable allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSMapTable *)mapTableWithKeyOptions:(NSPointerFunctionsOptions)k valueOptions:(NSPointerFunctionsOptions)v
{
    return [[[self alloc] initWithKeyOptions:k valueOptions:v capacity:0] autorelease];
}
+ (id)mapTableWithStrongToStrongObjects { return [self mapTableWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory]; }
+ (id)mapTableWithWeakToStrongObjects { return [self mapTableWithKeyOptions:NSPointerFunctionsWeakMemory valueOptions:NSPointerFunctionsStrongMemory]; }
+ (id)mapTableWithStrongToWeakObjects { return [self mapTableWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory]; }
+ (id)mapTableWithWeakToWeakObjects { return [self mapTableWithKeyOptions:NSPointerFunctionsWeakMemory valueOptions:NSPointerFunctionsWeakMemory]; }
+ (NSMapTable *)strongToStrongObjectsMapTable { return [self mapTableWithStrongToStrongObjects]; }
+ (NSMapTable *)weakToStrongObjectsMapTable { return [self mapTableWithWeakToStrongObjects]; }
+ (NSMapTable *)strongToWeakObjectsMapTable { return [self mapTableWithStrongToWeakObjects]; }
+ (NSMapTable *)weakToWeakObjectsMapTable { return [self mapTableWithWeakToWeakObjects]; }

- (instancetype)init { return [self initWithKeyOptions:0 valueOptions:0 capacity:0]; }
- (instancetype)initWithKeyOptions:(NSPointerFunctionsOptions)k valueOptions:(NSPointerFunctionsOptions)v capacity:(NSUInteger)c { return [super init]; }
- (instancetype)initWithKeyPointerFunctions:(NSPointerFunctions *)k valuePointerFunctions:(NSPointerFunctions *)v capacity:(NSUInteger)c { return [super init]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSDictionary *d = [self dictionaryRepresentation];
    [coder encodeObject:[d allKeys] forKey:@"NS.keys"];
    [coder encodeObject:[d allValues] forKey:@"NS.objects"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSArray *k = [coder decodeObjectOfClass:[NSArray class] forKey:@"NS.keys"];
    NSArray *v = [coder decodeObjectOfClass:[NSArray class] forKey:@"NS.objects"];
    if ((self = [self initWithKeyOptions:0 valueOptions:0 capacity:[k count]]))
        for (NSUInteger i = 0; i < [k count] && i < [v count]; i++) [self setObject:[v objectAtIndex:i] forKey:[k objectAtIndex:i]];
    return self;
}

@end

@implementation NSConcreteMapTable

- (instancetype)initWithKeyOptions:(NSPointerFunctionsOptions)k valueOptions:(NSPointerFunctionsOptions)v capacity:(NSUInteger)c
{
    if ((self = [super initWithKeyOptions:k valueOptions:v capacity:c])) {
        _kf = funcs_for(k);
        _vf = funcs_for(v);
        table_init(&_t, c);
    }
    return self;
}

- (instancetype)initWithKeyPointerFunctions:(NSPointerFunctions *)k valuePointerFunctions:(NSPointerFunctions *)v capacity:(NSUInteger)c
{
    if ((self = [super initWithKeyOptions:0 valueOptions:0 capacity:c])) {
        _kf = k->_f;
        _vf = v->_f;
        table_init(&_t, c);
    }
    return self;
}

- (void)dealloc
{
    table_clear(&_t, &_kf, &_vf, self);
    free(_t.buckets);
    [super dealloc];
}

- (NSPointerFunctions *)keyPointerFunctions { return pointer_functions(_kf); }
- (NSPointerFunctions *)valuePointerFunctions { return pointer_functions(_vf); }
- (NSUInteger)count { table_purge(&_t, &_kf, &_vf, self); return _t.count; }

- (id)objectForKey:(id)aKey
{
    if (!aKey) return nil;
    Node *n = table_find(&_t, &_kf, self, aKey, f_hash(&_kf, self, aKey));
    return n ? (id)slot_get(&_vf, &n->value) : nil;
}

- (void)setObject:(id)anObject forKey:(id)aKey
{
    if (!aKey) return;
    if (!anObject) { [self removeObjectForKey:aKey]; return; }
    table_set(&_t, &_kf, &_vf, self, aKey, anObject, NO);
}

- (void)removeObjectForKey:(id)aKey { if (aKey) table_remove(&_t, &_kf, &_vf, self, aKey); }
- (void)removeAllObjects { table_clear(&_t, &_kf, &_vf, self); }

- (NSArray *)allKeys
{
    NSMutableArray *a = [NSMutableArray array];
    table_each(&_t, &_kf, &_vf, ^(NSUInteger b, void *k, void *v, BOOL *stop) { [a addObject:(id)k]; });
    return a;
}

- (NSArray *)allValues
{
    NSMutableArray *a = [NSMutableArray array];
    table_each(&_t, &_kf, &_vf, ^(NSUInteger b, void *k, void *v, BOOL *stop) { [a addObject:(id)v]; });
    return a;
}

- (NSEnumerator *)keyEnumerator { return [[self allKeys] objectEnumerator]; }
- (NSEnumerator *)objectEnumerator { return [[self allValues] objectEnumerator]; }

- (NSDictionary *)dictionaryRepresentation
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    table_each(&_t, &_kf, &_vf, ^(NSUInteger b, void *k, void *v, BOOL *stop) { [d setObject:(id)v forKey:(id)k]; });
    return d;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    return enumerate_snapshot(state, buffer, len, ^NSPointerArray *(void) {
        NSPointerArray *p = [NSPointerArray pointerArrayWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality];
        table_each(&_t, &_kf, &_vf, ^(NSUInteger b, void *k, void *v, BOOL *stop) { [p addPointer:k]; });
        return p;
    });
}

- (id)copyWithZone:(NSZone *)zone
{
    NSConcreteMapTable *c = [[NSConcreteMapTable allocWithZone:zone] initWithKeyPointerFunctions:[self keyPointerFunctions]
                                                                           valuePointerFunctions:[self valuePointerFunctions] capacity:_t.count];
    table_each(&_t, &_kf, &_vf, ^(NSUInteger b, void *k, void *v, BOOL *stop) { table_set(&c->_t, &c->_kf, &c->_vf, c, k, v, NO); });
    return c;
}

/* Apple's: "NSMapTable {\n[bucket] key -> value\n}\n". */
- (NSString *)description
{
    NSMutableString *s = [NSMutableString stringWithString:@"NSMapTable {\n"];
    table_each(&_t, &_kf, &_vf, ^(NSUInteger b, void *k, void *v, BOOL *stop) {
        [s appendFormat:@"[%lu] %@ -> %@\n", (unsigned long)b, f_describe(&_kf, self, k), f_describe(&_vf, self, v)];
    });
    [s appendString:@"}\n"];
    return s;
}

@end

/* MARK: - NSPointerArray */

@interface NSConcretePointerArray : NSPointerArray {
@public
    Funcs _f;
    void ***_cells;   /* each a malloc'd slot, so weak slots never move */
    NSUInteger _n, _cap;
    unsigned long _mutations;
}
@end

@implementation NSPointerArray

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSPointerArray class]) return [NSConcretePointerArray allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return YES; }
+ (NSPointerArray *)pointerArrayWithOptions:(NSPointerFunctionsOptions)options { return [[[self alloc] initWithOptions:options] autorelease]; }
+ (NSPointerArray *)pointerArrayWithPointerFunctions:(NSPointerFunctions *)functions { return [[[self alloc] initWithPointerFunctions:functions] autorelease]; }
+ (id)pointerArrayWithStrongObjects { return [self pointerArrayWithOptions:NSPointerFunctionsStrongMemory]; }
+ (id)pointerArrayWithWeakObjects { return [self pointerArrayWithOptions:NSPointerFunctionsWeakMemory]; }
+ (NSPointerArray *)strongObjectsPointerArray { return [self pointerArrayWithOptions:NSPointerFunctionsStrongMemory]; }
+ (NSPointerArray *)weakObjectsPointerArray { return [self pointerArrayWithOptions:NSPointerFunctionsWeakMemory]; }

- (instancetype)init { return [self initWithOptions:0]; }
- (instancetype)initWithOptions:(NSPointerFunctionsOptions)options { return [super init]; }
- (instancetype)initWithPointerFunctions:(NSPointerFunctions *)functions { return [super init]; }

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:[self allObjects] forKey:@"NS.objects"]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSArray *a = [coder decodeObjectOfClass:[NSArray class] forKey:@"NS.objects"];
    if ((self = [self initWithOptions:0])) for (id o in a) [self addPointer:o];
    return self;
}

@end

@implementation NSConcretePointerArray

- (instancetype)initWithOptions:(NSPointerFunctionsOptions)options
{
    if ((self = [super initWithOptions:options])) _f = funcs_for(options);
    return self;
}

- (instancetype)initWithPointerFunctions:(NSPointerFunctions *)functions
{
    if ((self = [super initWithOptions:0])) _f = functions->_f;
    return self;
}

- (void)dealloc
{
    for (NSUInteger i = 0; i < _n; i++) {
        slot_clear(&_f, self, (void **)_cells[i]);
        free(_cells[i]);
    }
    free(_cells);
    [super dealloc];
}

- (NSPointerFunctions *)pointerFunctions { return pointer_functions(_f); }
- (NSUInteger)count { return _n; }

static void
check_pa_index(NSConcretePointerArray *self, SEL _cmd, NSUInteger index, NSUInteger limit)
{
    if (index >= limit)
        FinchRaise(NSRangeException, "*** -[NSConcretePointerArray %s]: attempt to access pointer at index %lu beyond bounds %lu",
            sel_getName(_cmd), (unsigned long)index, (unsigned long)limit);
}

- (void *)pointerAtIndex:(NSUInteger)index
{
    check_pa_index(self, _cmd, index, _n);
    return slot_get(&_f, (void **)_cells[index]);
}

- (void)insertPointer:(void *)item atIndex:(NSUInteger)index
{
    check_pa_index(self, _cmd, index, _n + 1);
    if (_n == _cap) {
        _cap = _cap ? _cap * 2 : 8;
        _cells = realloc(_cells, _cap * sizeof(void **));
    }
    memmove(_cells + index + 1, _cells + index, (_n - index) * sizeof(void **));
    _cells[index] = calloc(1, sizeof(void *));
    if (item) slot_set(&_f, self, (void **)_cells[index], item);
    _n++;
    _mutations++;
}

- (void)addPointer:(void *)pointer { [self insertPointer:pointer atIndex:_n]; }

- (void)removePointerAtIndex:(NSUInteger)index
{
    check_pa_index(self, _cmd, index, _n);
    slot_clear(&_f, self, (void **)_cells[index]);
    free(_cells[index]);
    memmove(_cells + index, _cells + index + 1, (_n - index - 1) * sizeof(void **));
    _n--;
    _mutations++;
}

- (void)replacePointerAtIndex:(NSUInteger)index withPointer:(void *)item
{
    check_pa_index(self, _cmd, index, _n);
    void **slot = (void **)_cells[index];
    if (_f.weak) {
        objc_storeWeak((id *)slot, (id)item);
    } else {
        void *old = *slot;
        *slot = item ? f_acquire(&_f, self, item) : NULL;
        f_relinquish(&_f, self, old);
    }
    _mutations++;
}

- (void)compact
{
    for (NSUInteger i = _n; i > 0; i--)
        if (!slot_get(&_f, (void **)_cells[i - 1])) [self removePointerAtIndex:i - 1];
}

- (void)setCount:(NSUInteger)count
{
    while (_n > count) [self removePointerAtIndex:_n - 1];
    while (_n < count) [self addPointer:NULL];
}

- (NSArray *)allObjects
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSUInteger i = 0; i < _n; i++) {
        void *p = slot_get(&_f, (void **)_cells[i]);
        if (p) [a addObject:(id)p];
    }
    return a;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    if (state->state == 0) state->mutationsPtr = &_mutations;
    NSUInteger i = state->state, k = 0;
    for (; i < _n && k < len; i++, k++) buffer[k] = (id)slot_get(&_f, (void **)_cells[i]);
    state->state = i;
    state->itemsPtr = buffer;
    return k;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSConcretePointerArray *c = [[NSConcretePointerArray allocWithZone:zone] initWithPointerFunctions:[self pointerFunctions]];
    for (NSUInteger i = 0; i < _n; i++) [c addPointer:slot_get(&_f, (void **)_cells[i])];
    return c;
}

@end

/* MARK: - The C API */

/* The table the C API made, with its callbacks. */
static NSMapTable *
legacy_map(NSMapTableKeyCallBacks k, NSMapTableValueCallBacks v, NSUInteger capacity)
{
    NSConcreteMapTable *t = [[NSConcreteMapTable alloc] initWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                                              valueOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality capacity:capacity];
    t->_kf.legacy = YES;
    t->_kf.lhash = (NSUInteger (*)(id, const void *))(void *)k.hash;
    t->_kf.lequal = (BOOL (*)(id, const void *, const void *))(void *)k.isEqual;
    t->_kf.lretain = (void (*)(id, const void *))(void *)k.retain;
    t->_kf.lrelease = (void (*)(id, void *))(void *)k.release;
    t->_kf.ldescribe = (NSString *(*)(id, const void *))(void *)k.describe;
    t->_vf.legacy = YES;
    t->_vf.lretain = (void (*)(id, const void *))(void *)v.retain;
    t->_vf.lrelease = (void (*)(id, void *))(void *)v.release;
    t->_vf.ldescribe = (NSString *(*)(id, const void *))(void *)v.describe;
    return t;
}

NSMapTable *NSCreateMapTable(NSMapTableKeyCallBacks k, NSMapTableValueCallBacks v, NSUInteger capacity) { return legacy_map(k, v, capacity); }
NSMapTable *NSCreateMapTableWithZone(NSMapTableKeyCallBacks k, NSMapTableValueCallBacks v, NSUInteger capacity, NSZone *zone)
{
    return legacy_map(k, v, capacity);
}
void NSFreeMapTable(NSMapTable *table) { [table release]; }
void NSResetMapTable(NSMapTable *table) { [table removeAllObjects]; }
BOOL NSCompareMapTables(NSMapTable *a, NSMapTable *b) { return [[a dictionaryRepresentation] isEqual:[b dictionaryRepresentation]]; }
NSMapTable *NSCopyMapTableWithZone(NSMapTable *table, NSZone *zone) { return [table copy]; }
NSUInteger NSCountMapTable(NSMapTable *table) { return [table count]; }

void *
NSMapGet(NSMapTable *table, const void *key)
{
    NSConcreteMapTable *t = (NSConcreteMapTable *)table;
    Node *n = table_find(&t->_t, &t->_kf, t, key, f_hash(&t->_kf, t, key));
    return n ? slot_get(&t->_vf, &n->value) : NULL;
}

BOOL
NSMapMember(NSMapTable *table, const void *key, void **originalKey, void **value)
{
    NSConcreteMapTable *t = (NSConcreteMapTable *)table;
    Node *n = table_find(&t->_t, &t->_kf, t, key, f_hash(&t->_kf, t, key));
    if (!n) return NO;
    if (originalKey) *originalKey = slot_get(&t->_kf, &n->key);
    if (value) *value = slot_get(&t->_vf, &n->value);
    return YES;
}

void
NSMapInsert(NSMapTable *table, const void *key, const void *value)
{
    NSConcreteMapTable *t = (NSConcreteMapTable *)table;
    table_set(&t->_t, &t->_kf, &t->_vf, t, key, value, YES);
}

void NSMapInsertKnownAbsent(NSMapTable *table, const void *key, const void *value) { NSMapInsert(table, key, value); }

void *
NSMapInsertIfAbsent(NSMapTable *table, const void *key, const void *value)
{
    void *original = NULL;
    if (NSMapMember(table, key, &original, NULL)) return original;
    NSMapInsert(table, key, value);
    return NULL;
}

void
NSMapRemove(NSMapTable *table, const void *key)
{
    NSConcreteMapTable *t = (NSConcreteMapTable *)table;
    table_remove(&t->_t, &t->_kf, &t->_vf, t, key);
}

/* Enumerators walk a snapshot: _bs holds key/value pairs, _si the next, _pi the count. */
NSMapEnumerator
NSEnumerateMapTable(NSMapTable *table)
{
    NSConcreteMapTable *t = (NSConcreteMapTable *)table;
    NSMapEnumerator e = { 0, 0, NULL };
    void **pairs = malloc((t->_t.count + 1) * 2 * sizeof(void *));
    __block NSUInteger n = 0;
    table_each(&t->_t, &t->_kf, &t->_vf, ^(NSUInteger b, void *k, void *v, BOOL *stop) { pairs[2 * n] = k; pairs[2 * n + 1] = v; n++; });
    e._pi = n;
    e._bs = pairs;
    return e;
}

BOOL
NSNextMapEnumeratorPair(NSMapEnumerator *e, void **key, void **value)
{
    if (!e->_bs || e->_si >= e->_pi) return NO;
    void **pairs = e->_bs;
    if (key) *key = pairs[2 * e->_si];
    if (value) *value = pairs[2 * e->_si + 1];
    e->_si++;
    return YES;
}

void NSEndMapTableEnumeration(NSMapEnumerator *e) { free(e->_bs); e->_bs = NULL; }
NSString *NSStringFromMapTable(NSMapTable *table) { return [table description]; }

NSArray *
NSAllMapTableKeys(NSMapTable *table)
{
    NSMutableArray *a = [NSMutableArray array];
    NSMapEnumerator e = NSEnumerateMapTable(table);
    void *k;
    while (NSNextMapEnumeratorPair(&e, &k, NULL)) [a addObject:(id)k];
    NSEndMapTableEnumeration(&e);
    return a;
}

NSArray *
NSAllMapTableValues(NSMapTable *table)
{
    NSMutableArray *a = [NSMutableArray array];
    NSMapEnumerator e = NSEnumerateMapTable(table);
    void *v;
    while (NSNextMapEnumeratorPair(&e, NULL, &v)) [a addObject:(id)v];
    NSEndMapTableEnumeration(&e);
    return a;
}

static NSHashTable *
legacy_hash(NSHashTableCallBacks cb, NSUInteger capacity)
{
    NSConcreteHashTable *t = [[NSConcreteHashTable alloc] initWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality capacity:capacity];
    t->_f.legacy = YES;
    t->_f.lhash = (NSUInteger (*)(id, const void *))(void *)cb.hash;
    t->_f.lequal = (BOOL (*)(id, const void *, const void *))(void *)cb.isEqual;
    t->_f.lretain = (void (*)(id, const void *))(void *)cb.retain;
    t->_f.lrelease = (void (*)(id, void *))(void *)cb.release;
    t->_f.ldescribe = (NSString *(*)(id, const void *))(void *)cb.describe;
    return t;
}

NSHashTable *NSCreateHashTable(NSHashTableCallBacks cb, NSUInteger capacity) { return legacy_hash(cb, capacity); }
NSHashTable *NSCreateHashTableWithZone(NSHashTableCallBacks cb, NSUInteger capacity, NSZone *zone) { return legacy_hash(cb, capacity); }
void NSFreeHashTable(NSHashTable *table) { [table release]; }
void NSResetHashTable(NSHashTable *table) { [table removeAllObjects]; }
BOOL NSCompareHashTables(NSHashTable *a, NSHashTable *b) { return [a isEqualToHashTable:b]; }
NSHashTable *NSCopyHashTableWithZone(NSHashTable *table, NSZone *zone) { return [table copy]; }
NSUInteger NSCountHashTable(NSHashTable *table) { return [table count]; }

void *
NSHashGet(NSHashTable *table, const void *pointer)
{
    NSConcreteHashTable *t = (NSConcreteHashTable *)table;
    Node *n = table_find(&t->_t, &t->_f, t, pointer, f_hash(&t->_f, t, pointer));
    return n ? slot_get(&t->_f, &n->key) : NULL;
}

void
NSHashInsert(NSHashTable *table, const void *pointer)
{
    NSConcreteHashTable *t = (NSConcreteHashTable *)table;
    table_set(&t->_t, &t->_f, NULL, t, pointer, NULL, YES);
}

void NSHashInsertKnownAbsent(NSHashTable *table, const void *pointer) { NSHashInsert(table, pointer); }

void *
NSHashInsertIfAbsent(NSHashTable *table, const void *pointer)
{
    void *existing = NSHashGet(table, pointer);
    if (existing) return existing;
    NSHashInsert(table, pointer);
    return NULL;
}

void
NSHashRemove(NSHashTable *table, const void *pointer)
{
    NSConcreteHashTable *t = (NSConcreteHashTable *)table;
    table_remove(&t->_t, &t->_f, NULL, t, pointer);
}

NSHashEnumerator
NSEnumerateHashTable(NSHashTable *table)
{
    NSConcreteHashTable *t = (NSConcreteHashTable *)table;
    NSHashEnumerator e = { 0, 0, NULL };
    void **items = malloc((t->_t.count + 1) * sizeof(void *));
    __block NSUInteger n = 0;
    table_each(&t->_t, &t->_f, NULL, ^(NSUInteger b, void *k, void *v, BOOL *stop) { items[n++] = k; });
    e._pi = n;
    e._bs = items;
    return e;
}

void *
NSNextHashEnumeratorItem(NSHashEnumerator *e)
{
    if (!e->_bs || e->_si >= e->_pi) return NULL;
    return ((void **)e->_bs)[e->_si++];
}

void NSEndHashTableEnumeration(NSHashEnumerator *e) { free(e->_bs); e->_bs = NULL; }
NSString *NSStringFromHashTable(NSHashTable *table) { return [table description]; }

NSArray *
NSAllHashTableObjects(NSHashTable *table)
{
    NSMutableArray *a = [NSMutableArray array];
    NSHashEnumerator e = NSEnumerateHashTable(table);
    void *p;
    while ((p = NSNextHashEnumeratorItem(&e))) [a addObject:(id)p];
    NSEndHashTableEnumeration(&e);
    return a;
}

/* The callback sets. */
static NSUInteger cb_object_hash(id t, const void *p) { return [(id)p hash]; }
static BOOL cb_object_equal(id t, const void *a, const void *b) { return a == b || [(id)a isEqual:(id)b]; }
static void cb_object_retain(id t, const void *p) { [(id)p retain]; }
static void cb_object_release(id t, void *p) { [(id)p release]; }
static NSString *cb_object_describe(id t, const void *p) { return [(id)p description]; }
static NSUInteger cb_pointer_hash(id t, const void *p) { return (NSUInteger)(uintptr_t)p >> 2; }
static BOOL cb_pointer_equal(id t, const void *a, const void *b) { return a == b; }
static NSString *cb_pointer_describe(id t, const void *p) { return [NSString stringWithFormat:@"%p", p]; }
static void cb_free(id t, void *p) { free(p); }
static NSUInteger cb_int_hash(id t, const void *p) { return (NSUInteger)(uintptr_t)p; }
static NSString *cb_int_describe(id t, const void *p) { return [NSString stringWithFormat:@"%ld", (long)(intptr_t)p]; }
static NSUInteger cb_struct_hash(id t, const void *p) { return (NSUInteger)*(const int *)p; }
static BOOL cb_struct_equal(id t, const void *a, const void *b) { return *(const int *)a == *(const int *)b; }

#define KEYS(H, E, R, L, D, M) { (NSUInteger (*)(NSMapTable *, const void *))(void *)(H), (BOOL (*)(NSMapTable *, const void *, const void *))(void *)(E), \
    (void (*)(NSMapTable *, const void *))(void *)(R), (void (*)(NSMapTable *, void *))(void *)(L), (NSString *(*)(NSMapTable *, const void *))(void *)(D), (const void *)(M) }
#define VALUES(R, L, D) { (void (*)(NSMapTable *, const void *))(void *)(R), (void (*)(NSMapTable *, void *))(void *)(L), (NSString *(*)(NSMapTable *, const void *))(void *)(D) }
#define HASH(H, E, R, L, D) { (NSUInteger (*)(NSHashTable *, const void *))(void *)(H), (BOOL (*)(NSHashTable *, const void *, const void *))(void *)(E), \
    (void (*)(NSHashTable *, const void *))(void *)(R), (void (*)(NSHashTable *, void *))(void *)(L), (NSString *(*)(NSHashTable *, const void *))(void *)(D) }

const NSMapTableKeyCallBacks NSIntegerMapKeyCallBacks = KEYS(cb_int_hash, cb_pointer_equal, NULL, NULL, cb_int_describe, -1);
const NSMapTableKeyCallBacks NSIntMapKeyCallBacks = KEYS(cb_int_hash, cb_pointer_equal, NULL, NULL, cb_int_describe, -1);
const NSMapTableKeyCallBacks NSNonOwnedPointerMapKeyCallBacks = KEYS(cb_pointer_hash, cb_pointer_equal, NULL, NULL, cb_pointer_describe, NULL);
const NSMapTableKeyCallBacks NSNonOwnedPointerOrNullMapKeyCallBacks = KEYS(cb_pointer_hash, cb_pointer_equal, NULL, NULL, cb_pointer_describe, -1);
const NSMapTableKeyCallBacks NSNonRetainedObjectMapKeyCallBacks = KEYS(cb_object_hash, cb_object_equal, NULL, NULL, cb_object_describe, NULL);
const NSMapTableKeyCallBacks NSObjectMapKeyCallBacks = KEYS(cb_object_hash, cb_object_equal, cb_object_retain, cb_object_release, cb_object_describe, NULL);
const NSMapTableKeyCallBacks NSOwnedPointerMapKeyCallBacks = KEYS(cb_pointer_hash, cb_pointer_equal, NULL, cb_free, cb_pointer_describe, NULL);
const NSMapTableValueCallBacks NSIntegerMapValueCallBacks = VALUES(NULL, NULL, cb_int_describe);
const NSMapTableValueCallBacks NSIntMapValueCallBacks = VALUES(NULL, NULL, cb_int_describe);
const NSMapTableValueCallBacks NSNonOwnedPointerMapValueCallBacks = VALUES(NULL, NULL, cb_pointer_describe);
const NSMapTableValueCallBacks NSObjectMapValueCallBacks = VALUES(cb_object_retain, cb_object_release, cb_object_describe);
const NSMapTableValueCallBacks NSNonRetainedObjectMapValueCallBacks = VALUES(NULL, NULL, cb_object_describe);
const NSMapTableValueCallBacks NSOwnedPointerMapValueCallBacks = VALUES(NULL, cb_free, cb_pointer_describe);
const NSHashTableCallBacks NSIntegerHashCallBacks = HASH(cb_int_hash, cb_pointer_equal, NULL, NULL, cb_int_describe);
const NSHashTableCallBacks NSIntHashCallBacks = HASH(cb_int_hash, cb_pointer_equal, NULL, NULL, cb_int_describe);
const NSHashTableCallBacks NSNonOwnedPointerHashCallBacks = HASH(cb_pointer_hash, cb_pointer_equal, NULL, NULL, cb_pointer_describe);
const NSHashTableCallBacks NSNonRetainedObjectHashCallBacks = HASH(cb_object_hash, cb_object_equal, NULL, NULL, cb_object_describe);
const NSHashTableCallBacks NSObjectHashCallBacks = HASH(cb_object_hash, cb_object_equal, cb_object_retain, cb_object_release, cb_object_describe);
const NSHashTableCallBacks NSOwnedObjectIdentityHashCallBacks = HASH(cb_pointer_hash, cb_pointer_equal, cb_object_retain, cb_object_release, cb_object_describe);
const NSHashTableCallBacks NSOwnedPointerHashCallBacks = HASH(cb_pointer_hash, cb_pointer_equal, NULL, cb_free, cb_pointer_describe);
const NSHashTableCallBacks NSPointerToStructHashCallBacks = HASH(cb_struct_hash, cb_struct_equal, NULL, cb_free, cb_pointer_describe);

/* MARK: - NSCountedSet */

/* A set that counts: each distinct object once, with how many times it was
 * added, kept in a CFBag. */
@implementation NSCountedSet {
    CFMutableBagRef _bag;
}

- (instancetype)initWithCapacity:(NSUInteger)numItems
{
    if ((self = [super init])) _bag = CFBagCreateMutable(NULL, 0, &kCFTypeBagCallBacks);
    return self;
}

- (instancetype)init { return [self initWithCapacity:0]; }

- (instancetype)initWithObjects:(const id [])objects count:(NSUInteger)cnt
{
    if ((self = [self initWithCapacity:cnt])) for (NSUInteger i = 0; i < cnt; i++) [self addObject:objects[i]];
    return self;
}

- (instancetype)initWithArray:(NSArray *)array
{
    if ((self = [self initWithCapacity:[array count]])) for (id o in array) [self addObject:o];
    return self;
}

- (instancetype)initWithSet:(NSSet *)set
{
    if ((self = [self initWithCapacity:[set count]])) for (id o in set) [self addObject:o];
    return self;
}

- (void)dealloc
{
    if (_bag) CFRelease(_bag);
    [super dealloc];
}

- (NSUInteger)countForObject:(id)object { return object ? (NSUInteger)CFBagGetCountOfValue(_bag, object) : 0; }

/* The distinct objects. */
- (NSArray *)_finchObjects
{
    CFIndex n = CFBagGetCount(_bag);
    const void **v = malloc(((size_t)n + 1) * sizeof(void *));
    CFBagGetValues(_bag, v);
    NSMutableArray *a = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (CFIndex i = 0; i < n; i++) {
        if ([seen containsObject:(id)v[i]]) continue;
        [seen addObject:(id)v[i]];
        [a addObject:(id)v[i]];
    }
    free(v);
    return a;
}

- (NSUInteger)count { return [[self _finchObjects] count]; }

- (id)member:(id)object
{
    const void *v = NULL;
    return object && CFBagGetValueIfPresent(_bag, object, &v) ? (id)v : nil;
}

- (NSEnumerator *)objectEnumerator { return [[self _finchObjects] objectEnumerator]; }
- (NSArray *)allObjects { return [self _finchObjects]; }
- (void)addObject:(id)object
{
    if (!object) FinchRaise(NSInvalidArgumentException, "*** -[NSCountedSet addObject:]: attempt to insert nil");
    CFBagAddValue(_bag, object);
}
- (void)removeObject:(id)object { if (object) CFBagRemoveValue(_bag, object); }
- (void)removeAllObjects { CFBagRemoveAllValues(_bag); }

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len
{
    return [[self _finchObjects] countByEnumeratingWithState:state objects:buffer count:len];
}

- (id)copyWithZone:(NSZone *)zone { return [[NSCountedSet allocWithZone:zone] initWithArray:[self _finchBagContents]]; }
- (id)mutableCopyWithZone:(NSZone *)zone { return [self copyWithZone:zone]; }

/* Every object as many times as it was added. */
- (NSArray *)_finchBagContents
{
    CFIndex n = CFBagGetCount(_bag);
    const void **v = malloc(((size_t)n + 1) * sizeof(void *));
    CFBagGetValues(_bag, v);
    NSArray *a = [NSArray arrayWithObjects:(id *)v count:(NSUInteger)n];
    free(v);
    return a;
}

/* Apple's: "<NSCountedSet: 0x...> (a [2], b [1])". */
- (NSString *)description
{
    NSMutableArray *parts = [NSMutableArray array];
    for (id o in [self _finchObjects]) [parts addObject:[NSString stringWithFormat:@"%@ [%lu]", o, (unsigned long)[self countForObject:o]]];
    return [NSString stringWithFormat:@"<%s: %p> (%@)", object_getClassName(self), self, [parts componentsJoinedByString:@", "]];
}

- (Class)classForCoder { return [NSCountedSet class]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSArray *objs = [self _finchObjects];
    [coder encodeInt64:(int64_t)[objs count] forKey:@"NS.count"];
    NSUInteger i = 0;
    for (id o in objs) {
        [coder encodeObject:o forKey:[NSString stringWithFormat:@"NS.object%lu", (unsigned long)i]];
        [coder encodeInt64:(int64_t)[self countForObject:o] forKey:[NSString stringWithFormat:@"NS.count%lu", (unsigned long)i]];
        i++;
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self initWithCapacity:0])) return nil;
    int64_t n = [coder decodeInt64ForKey:@"NS.count"];
    for (int64_t i = 0; i < n; i++) {
        id o = [coder decodeObjectForKey:[NSString stringWithFormat:@"NS.object%lld", i]];
        int64_t c = [coder decodeInt64ForKey:[NSString stringWithFormat:@"NS.count%lld", i]];
        for (int64_t k = 0; o && k < c; k++) [self addObject:o];
    }
    return self;
}

@end
