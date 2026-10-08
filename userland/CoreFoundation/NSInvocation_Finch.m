/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Objective-C message forwarding, which Apple's CoreFoundation provides
 * (docs/design/FOUNDATION.md): NSMethodSignature, NSInvocation,
 * NSGetSizeAndAlignment, libobjc's forward handler, and the NSObject
 * methods that go with them (-methodSignatureForSelector:,
 * -forwardInvocation:, -doesNotRecognizeSelector:, -description).
 *
 * A message nothing implements reaches __CFFinchForward with its registers
 * saved in a frame (NSForwarding_arm64.s). As Apple's does, it tries
 * -forwardingTargetForSelector:, then -methodSignatureForSelector: and
 * -forwardInvocation: with an NSInvocation over the frame, and finally
 * -doesNotRecognizeSelector:, which raises NSInvalidArgumentException.
 *
 * Frames follow Apple's arm64 layout, measured from its NSMethodSignature:
 * x0-x7 at 8*i, x8 at 64, v0-v7 at 80 + 16*i, stack arguments from 224.
 * Argument placement is Darwin's arm64 ABI: integers, pointers and
 * composites up to 16 bytes in x registers (composites whole or not at all),
 * floating point and homogeneous float aggregates (up to four float or
 * double members) in v registers, a member per register; larger composites
 * by reference; the rest on the stack at natural alignment (composites
 * rounded to 8 bytes). Arguments narrower than 32 bits are extended to 32
 * in registers, as callers must on Darwin.
 */
#include "CFObjCClasses_Finch.h"
#include <ctype.h>
#include <string.h>

#define FRAME_GPR(i)    ((i) * 8)
#define FRAME_X8        64
#define FRAME_FPR(i)    (80 + (i) * 16)
#define FRAME_STACK     224

extern void __CFFinchInvoke(void *frame, void *fn, const void *stack, size_t stackSize);
extern void __CFFinchForwardingEntry(void);
extern void objc_setForwardHandler(void *fwd, void *fwd_stret);

/* MARK: - Type encodings */

static const char *
skip_qualifiers(const char *t)
{
    while (*t && strchr("rnNoORVAj+", *t)) t++;
    return t;
}

static const char *
skip_offset(const char *t)
{
    if (*t == '-') t++;
    while (isdigit((unsigned char)*t)) t++;
    return t;
}

static const char *size_align(const char *t, NSUInteger *size, NSUInteger *align);

static const char *
skip_name(const char *t)
{
    if (*t == '"') {
        t++;
        while (*t && *t != '"') t++;
        if (*t) t++;
    }
    return t;
}

/* A struct or union body after its '{' or '(': "name=members}" or "name}". */
static const char *
aggregate(const char *t, char close, BOOL isUnion, NSUInteger *size, NSUInteger *align)
{
    while (*t && *t != '=' && *t != close) t++;
    NSUInteger s = 0, a = 1;
    if (*t == '=') {
        t++;
        while (*t && *t != close) {
            t = skip_name(t);
            NSUInteger ms, ma;
            t = size_align(t, &ms, &ma);
            if (ma > a) a = ma;
            if (isUnion) {
                if (ms > s) s = ms;
            } else {
                s = (s + ma - 1) / ma * ma + ms;
            }
        }
    }
    if (*t == close) t++;
    *size = (s + a - 1) / a * a;
    *align = a;
    return t;
}

static const char *
size_align(const char *t, NSUInteger *size, NSUInteger *align)
{
    t = skip_qualifiers(t);
    NSUInteger s = 0, a = 1;
    switch (*t++) {
    case 'c': case 'C': case 'B': s = a = 1; break;
    case 's': case 'S': s = a = 2; break;
    case 'i': case 'I': case 'f': s = a = 4; break;
    case 'l': case 'L': case 'q': case 'Q': case 'd': case 'D': s = a = 8; break;
    case 't': case 'T': s = a = 16; break;
    case 'v': s = 0; a = 1; break;
    case '*': case '#': case ':': case '?': s = a = 8; break;
    case '@':
        s = a = 8;
        if (*t == '?') t++;                             /* block */
        else if (*t == '"') t = skip_name(t);           /* @"Class" */
        break;
    case '^': {
        NSUInteger ps, pa;
        t = size_align(t, &ps, &pa);
        s = a = 8;
        break;
    }
    case '[': {
        NSUInteger n = 0, es, ea;
        while (isdigit((unsigned char)*t)) n = n * 10 + (NSUInteger)(*t++ - '0');
        t = size_align(t, &es, &ea);
        if (*t == ']') t++;
        s = n * es;
        a = ea;
        break;
    }
    case '{': t = aggregate(t, '}', NO, &s, &a); break;
    case '(': t = aggregate(t, ')', YES, &s, &a); break;
    case 'b': {                                         /* bitfield: bits, as bytes */
        NSUInteger bits = 0;
        while (isdigit((unsigned char)*t)) bits = bits * 10 + (NSUInteger)(*t++ - '0');
        s = (bits + 7) / 8;
        a = 1;
        break;
    }
    default:
        break;
    }
    *size = s;
    *align = a ? a : 1;
    return t;
}

/* <Foundation/NSObjCRuntime.h>; Apple's CoreFoundation exports it. */
const char *
NSGetSizeAndAlignment(const char *typePtr, NSUInteger *sizep, NSUInteger *alignp)
{
    NSUInteger s, a;
    const char *end = size_align(typePtr, &s, &a);
    if (sizep) *sizep = s;
    if (alignp) *alignp = a;
    return end;
}

/* The floating-point leaves of a type, if it is a homogeneous float
 * aggregate (or a lone float/double): returns their count and sets the
 * leaf size, else 0. */
static int
hfa_leaves(const char *t, char *leaf)
{
    t = skip_qualifiers(t);
    switch (*t) {
    case 'f': case 'd': case 'D': {
        char k = *t == 'f' ? 'f' : 'd';
        if (*leaf && *leaf != k) return -100;
        *leaf = k;
        return 1;
    }
    case '[': {
        t++;
        int n = 0;
        while (isdigit((unsigned char)*t)) n = n * 10 + (*t++ - '0');
        int e = hfa_leaves(t, leaf);
        return e < 0 ? -100 : n * e;
    }
    case '{': {
        while (*t && *t != '=' && *t != '}') t++;
        if (*t != '=') return -100;
        t++;
        int n = 0;
        while (*t && *t != '}') {
            t = skip_name(t);
            int e = hfa_leaves(t, leaf);
            if (e < 0) return -100;
            n += e;
            NSUInteger s, a;
            t = size_align(t, &s, &a);
        }
        return n;
    }
    default:
        return -100;
    }
}

static int
hfa_count(const char *t, NSUInteger *leafSize)
{
    char leaf = 0;
    int n = hfa_leaves(t, &leaf);
    if (n < 1 || n > 4) return 0;
    *leafSize = leaf == 'f' ? 4 : 8;
    return n;
}

/* MARK: - NSMethodSignature */

enum { LOC_NONE, LOC_GPR, LOC_FPR, LOC_STACK };

typedef struct {
    char *type;                 /* this argument's encoding, offsets removed */
    NSUInteger size, align;
    int loc;                    /* where the value (or, if indirect, its address) is */
    unsigned offset;            /* frame offset of the first register or stack slot */
    int hfa;                    /* members, one per v register (LOC_FPR) */
    NSUInteger leafSize;
    BOOL indirect;              /* passed or returned by reference */
    BOOL isSigned, isObject, isBlock, isCString;
} ArgInfo;

@interface NSMethodSignature : NSObject {
    char *_types;
    NSUInteger _count;
    ArgInfo *_args;
    ArgInfo _ret;
    NSUInteger _frameLength;
    BOOL _oneway;
}
+ (instancetype)signatureWithObjCTypes:(const char *)types;
- (NSUInteger)numberOfArguments;
- (const char *)getArgumentTypeAtIndex:(NSUInteger)idx;
- (NSUInteger)frameLength;
- (BOOL)isOneway;
- (const char *)methodReturnType;
- (NSUInteger)methodReturnLength;
@end

@interface NSMethodSignature (FinchFrame)
- (ArgInfo *)_finchArgument:(NSUInteger)idx;
- (ArgInfo *)_finchReturn;
@end

static char *
copy_type(const char *start, const char *end)
{
    size_t n = (size_t)(end - start);
    char *s = malloc(n + 1);
    memcpy(s, start, n);
    s[n] = 0;
    return s;
}

static void
classify(ArgInfo *a, const char *t)
{
    t = skip_qualifiers(t);
    a->isSigned = strchr("csilq", *t) != NULL;
    a->isObject = *t == '@';
    a->isBlock = t[0] == '@' && t[1] == '?';
    a->isCString = *t == '*';
}

@implementation NSMethodSignature

+ (instancetype)signatureWithObjCTypes:(const char *)types
{
    if (!types)
        __CFFinchRaise(NSInvalidArgumentException, "+[NSMethodSignature signatureWithObjCTypes:]: type signature is empty.");
    NSMethodSignature *sig = [[[self alloc] init] autorelease];
    sig->_types = strdup(types);

    /* Split into return and argument types. */
    const char *t = types;
    const char *q = t;
    while (*q && strchr("rnNoORVAj+", *q)) {
        if (*q == 'V') sig->_oneway = YES;
        q++;
    }
    NSUInteger s, al;
    const char *e = size_align(t, &s, &al);
    sig->_ret.type = copy_type(t, e);
    sig->_ret.size = s;
    sig->_ret.align = al;
    classify(&sig->_ret, sig->_ret.type);
    t = skip_offset(e);

    NSUInteger cap = 8;
    sig->_args = calloc(cap, sizeof(ArgInfo));
    while (*t) {
        if (sig->_count == cap) {
            cap *= 2;
            sig->_args = realloc(sig->_args, cap * sizeof(ArgInfo));
            memset(sig->_args + sig->_count, 0, (cap - sig->_count) * sizeof(ArgInfo));
        }
        ArgInfo *a = &sig->_args[sig->_count++];
        e = size_align(t, &s, &al);
        a->type = copy_type(t, e);
        a->size = s;
        a->align = al;
        classify(a, a->type);
        t = skip_offset(e);
    }

    /* Placement, per Darwin's arm64 ABI. */
    unsigned ngrn = 0, nsrn = 0, nsaa = 0;
    for (NSUInteger i = 0; i < sig->_count; i++) {
        ArgInfo *a = &sig->_args[i];
        const char *at = skip_qualifiers(a->type);
        NSUInteger leaf;
        int hfa = (*at == '{' || *at == '[' || *at == 'f' || *at == 'd' || *at == 'D') ? hfa_count(at, &leaf) : 0;
        BOOL composite = *at == '{' || *at == '(' || *at == '[';
        if (hfa) {
            a->leafSize = leaf;
            if (nsrn + (unsigned)hfa <= 8) {
                a->loc = LOC_FPR;
                a->hfa = hfa;
                a->offset = FRAME_FPR(nsrn);
                nsrn += (unsigned)hfa;
                continue;
            }
            nsrn = 8;
            NSUInteger sa = composite ? a->align : a->size;
            nsaa = (unsigned)((nsaa + sa - 1) / sa * sa);
            a->loc = LOC_STACK;
            a->offset = FRAME_STACK + nsaa;
            nsaa += (unsigned)(composite ? (a->size + 7) / 8 * 8 : a->size);
            continue;
        }
        NSUInteger size = a->size;
        if (composite && size > 16) {
            a->indirect = YES;
            size = 8;
        }
        unsigned regs = (unsigned)((size + 7) / 8);
        if (regs == 0) regs = 1;
        if (a->align == 16 && (ngrn & 1)) ngrn++;
        if (ngrn + regs <= 8) {
            a->loc = LOC_GPR;
            a->offset = FRAME_GPR(ngrn);
            ngrn += regs;
            continue;
        }
        ngrn = 8;
        NSUInteger sa = a->indirect ? 8 : (a->align ? a->align : 1);
        NSUInteger ss = a->indirect ? 8 : composite ? (size + 7) / 8 * 8 : size;
        nsaa = (unsigned)((nsaa + sa - 1) / sa * sa);
        a->loc = LOC_STACK;
        a->offset = FRAME_STACK + nsaa;
        nsaa += (unsigned)ss;
    }
    sig->_frameLength = FRAME_STACK + (nsaa + 7) / 8 * 8;

    /* The return value. */
    ArgInfo *r = &sig->_ret;
    const char *rt = skip_qualifiers(r->type);
    NSUInteger leaf;
    int hfa = (*rt == '{' || *rt == '[' || *rt == 'f' || *rt == 'd' || *rt == 'D') ? hfa_count(rt, &leaf) : 0;
    if (*rt == 'v') {
        r->loc = LOC_NONE;
    } else if (hfa) {
        r->loc = LOC_FPR;
        r->hfa = hfa;
        r->leafSize = leaf;
        r->offset = FRAME_FPR(0);
    } else if ((*rt == '{' || *rt == '(' || *rt == '[') && r->size > 16) {
        r->loc = LOC_GPR;
        r->indirect = YES;
        r->offset = FRAME_X8;
    } else {
        r->loc = LOC_GPR;
        r->offset = FRAME_GPR(0);
    }
    return sig;
}

- (void)dealloc
{
    free(_types);
    for (NSUInteger i = 0; i < _count; i++) free(_args[i].type);
    free(_args);
    free(_ret.type);
    [super dealloc];
}

- (NSUInteger)numberOfArguments { return _count; }

- (const char *)getArgumentTypeAtIndex:(NSUInteger)idx
{
    if (idx >= _count)
        __CFFinchRaise(NSInvalidArgumentException, FINCH_METHOD_FMT ": index (%lu) out of bounds [0, %ld]",
            FINCH_METHOD_ARGS, (unsigned long)idx, (long)_count - 1);
    return _args[idx].type;
}

- (NSUInteger)frameLength { return _frameLength; }
- (BOOL)isOneway { return _oneway; }
- (const char *)methodReturnType { return _ret.type; }
- (NSUInteger)methodReturnLength { return _ret.size; }
- (const char *)_typeString { return _types; }
- (ArgInfo *)_finchArgument:(NSUInteger)idx { return &_args[idx]; }
- (ArgInfo *)_finchReturn { return &_ret; }

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSMethodSignature class]]) return NO;
    NSMethodSignature *o = other;
    if (o->_count != _count || strcmp(o->_ret.type, _ret.type)) return NO;
    for (NSUInteger i = 0; i < _count; i++)
        if (strcmp(o->_args[i].type, _args[i].type)) return NO;
    return YES;
}

- (NSUInteger)hash { return _count; }

@end

/* MARK: - Values in frames */

/* Copy an argument or return value between a frame and a plain buffer. */
static void
frame_get(const ArgInfo *a, const unsigned char *frame, void *value)
{
    if (a->loc == LOC_NONE || a->size == 0) return;
    const unsigned char *src = frame + a->offset;
    if (a->indirect) {
        memcpy(value, *(void *const *)src, a->size);
    } else if (a->loc == LOC_FPR) {
        for (int i = 0; i < a->hfa; i++)
            memcpy((char *)value + (size_t)i * a->leafSize, src + 16 * i, a->leafSize);
    } else {
        memcpy(value, src, a->size);
    }
}

static void
frame_set(const ArgInfo *a, unsigned char *frame, const void *value, void *indirectStorage)
{
    if (a->loc == LOC_NONE || a->size == 0) return;
    unsigned char *dst = frame + a->offset;
    if (a->indirect) {
        memcpy(indirectStorage, value, a->size);
        *(void **)dst = indirectStorage;
    } else if (a->loc == LOC_FPR) {
        for (int i = 0; i < a->hfa; i++) {
            memset(dst + 16 * i, 0, 16);
            memcpy(dst + 16 * i, (const char *)value + (size_t)i * a->leafSize, a->leafSize);
        }
    } else if (a->loc == LOC_GPR && a->size < 4) {
        /* Darwin: the caller extends sub-32-bit arguments to 32 bits. */
        int64_t v = 0;
        switch (a->size) {
        case 1: v = a->isSigned ? (int64_t)*(const int8_t *)value : (int64_t)*(const uint8_t *)value; break;
        case 2: v = a->isSigned ? (int64_t)*(const int16_t *)value : (int64_t)*(const uint16_t *)value; break;
        default: memcpy(&v, value, a->size); break;
        }
        uint32_t w = (uint32_t)v;
        memset(dst, 0, 8);
        memcpy(dst, &w, 4);
    } else {
        memcpy(dst, value, a->size);
    }
}

/* MARK: - NSInvocation */

@interface NSInvocation : NSObject {
    NSMethodSignature *_signature;
    unsigned char *_frame;
    void *_retdata;
    void **_indirect;           /* per argument: storage for by-reference values */
    BOOL _retainedArgs;
    void *_reserved;
}
+ (NSInvocation *)invocationWithMethodSignature:(NSMethodSignature *)sig;
- (NSMethodSignature *)methodSignature;
- (void)retainArguments;
- (BOOL)argumentsRetained;
- (id)target;
- (void)setTarget:(id)target;
- (SEL)selector;
- (void)setSelector:(SEL)sel;
- (void)getReturnValue:(void *)value;
- (void)setReturnValue:(void *)value;
- (void)getArgument:(void *)value atIndex:(NSInteger)idx;
- (void)setArgument:(void *)value atIndex:(NSInteger)idx;
- (void)invoke;
- (void)invokeWithTarget:(id)target;
- (void)invokeUsingIMP:(IMP)imp;
@end

@implementation NSInvocation

+ (NSInvocation *)invocationWithMethodSignature:(NSMethodSignature *)sig
{
    if (!sig)
        __CFFinchRaise(NSInvalidArgumentException, "+[NSInvocation invocationWithMethodSignature:]: method signature argument cannot be nil");
    NSInvocation *inv = [[[self alloc] init] autorelease];
    inv->_signature = [sig retain];
    inv->_frame = calloc(1, [sig frameLength]);
    NSUInteger rl = [sig methodReturnLength];
    inv->_retdata = calloc(1, rl > 32 ? rl : 32);
    inv->_indirect = calloc([sig numberOfArguments] + 1, sizeof(void *));
    for (NSUInteger i = 0; i < [sig numberOfArguments]; i++) {
        ArgInfo *a = [sig _finchArgument:i];
        if (a->indirect) {
            inv->_indirect[i] = calloc(1, a->size);
            *(void **)(inv->_frame + a->offset) = inv->_indirect[i];
        }
    }
    return inv;
}

/* An invocation over a forwarded message's registers and stack arguments. */
+ (NSInvocation *)_finchInvocationWithSignature:(NSMethodSignature *)sig frame:(const void *)frame stack:(const void *)stack
{
    NSInvocation *inv = [self invocationWithMethodSignature:sig];
    memcpy(inv->_frame, frame, FRAME_STACK);
    memcpy(inv->_frame + FRAME_STACK, stack, [sig frameLength] - FRAME_STACK);
    for (NSUInteger i = 0; i < [sig numberOfArguments]; i++) {
        ArgInfo *a = [sig _finchArgument:i];
        if (a->indirect) {   /* copy the caller's value: the invocation owns its arguments */
            memcpy(inv->_indirect[i], *(void **)(inv->_frame + a->offset), a->size);
            *(void **)(inv->_frame + a->offset) = inv->_indirect[i];
        }
    }
    return inv;
}

- (void)dealloc
{
    NSUInteger n = [_signature numberOfArguments];
    if (_retainedArgs) {
        for (NSUInteger i = 0; i < n; i++) {
            ArgInfo *a = [_signature _finchArgument:i];
            void *p = NULL;
            if (!(a->isObject || a->isCString)) continue;
            frame_get(a, _frame, &p);
            if (a->isCString) free(p);
            else [(id)p release];
        }
        ArgInfo *r = [_signature _finchReturn];
        if (r->isObject) [*(id *)_retdata release];
    }
    for (NSUInteger i = 0; i < n; i++) free(_indirect[i]);
    free(_indirect);
    free(_frame);
    free(_retdata);
    [_signature release];
    [super dealloc];
}

- (NSMethodSignature *)methodSignature { return _signature; }
- (BOOL)argumentsRetained { return _retainedArgs; }

static void
check_index(NSInvocation *self, SEL _cmd, NSInteger idx, NSMethodSignature *sig)
{
    if (idx < 0 || (NSUInteger)idx >= [sig numberOfArguments])
        __CFFinchRaise(NSInvalidArgumentException, FINCH_METHOD_FMT ": index (%ld) out of bounds [-1, %ld]",
            FINCH_METHOD_ARGS, (long)idx, (long)[sig numberOfArguments] - 1);
}

- (void)retainArguments
{
    if (_retainedArgs) return;
    _retainedArgs = YES;
    for (NSUInteger i = 0; i < [_signature numberOfArguments]; i++) {
        ArgInfo *a = [_signature _finchArgument:i];
        void *p = NULL;
        if (!(a->isObject || a->isCString)) continue;
        frame_get(a, _frame, &p);
        if (a->isCString) p = p ? strdup(p) : NULL;
        else if (a->isBlock) p = [(id)p copy];
        else [(id)p retain];
        frame_set(a, _frame, &p, _indirect[i]);
    }
    ArgInfo *r = [_signature _finchReturn];
    if (r->isObject) [*(id *)_retdata retain];
}

- (void)getArgument:(void *)value atIndex:(NSInteger)idx
{
    check_index(self, _cmd, idx, _signature);
    frame_get([_signature _finchArgument:(NSUInteger)idx], _frame, value);
}

- (void)setArgument:(void *)value atIndex:(NSInteger)idx
{
    check_index(self, _cmd, idx, _signature);
    ArgInfo *a = [_signature _finchArgument:(NSUInteger)idx];
    if (_retainedArgs && (a->isObject || a->isCString)) {
        void *old = NULL, *new = *(void **)value;
        frame_get(a, _frame, &old);
        if (a->isCString) new = new ? strdup(new) : NULL;
        else if (a->isBlock) new = [(id)new copy];
        else [(id)new retain];
        frame_set(a, _frame, &new, _indirect[idx]);
        if (a->isCString) free(old);
        else [(id)old release];
        return;
    }
    frame_set(a, _frame, value, _indirect[idx]);
}

- (id)target { id t = nil; [self getArgument:&t atIndex:0]; return t; }
- (void)setTarget:(id)target { [self setArgument:&target atIndex:0]; }
- (SEL)selector { SEL s = NULL; [self getArgument:&s atIndex:1]; return s; }
- (void)setSelector:(SEL)sel { [self setArgument:&sel atIndex:1]; }

- (void)getReturnValue:(void *)value
{
    memcpy(value, _retdata, [_signature methodReturnLength]);
}

- (void)setReturnValue:(void *)value
{
    ArgInfo *r = [_signature _finchReturn];
    if (_retainedArgs && r->isObject) {
        [*(id *)value retain];
        [*(id *)_retdata release];
    }
    memcpy(_retdata, value, r->size);
}

- (void)invokeUsingIMP:(IMP)imp
{
    ArgInfo *r = [_signature _finchReturn];
    if (r->indirect) *(void **)(_frame + FRAME_X8) = _retdata;
    id old = (_retainedArgs && r->isObject) ? *(id *)_retdata : nil;
    __CFFinchInvoke(_frame, (void *)imp, _frame + FRAME_STACK, [_signature frameLength] - FRAME_STACK);
    if (!r->indirect) frame_get(r, _frame, _retdata);
    if (_retainedArgs && r->isObject) {
        [*(id *)_retdata retain];
        [old release];
    }
}

- (void)invoke
{
    if (![self target]) {               /* messaging nil: a zero result */
        memset(_retdata, 0, [_signature methodReturnLength]);
        return;
    }
    [self invokeUsingIMP:(IMP)objc_msgSend];
}

- (void)invokeWithTarget:(id)target
{
    [self setTarget:target];
    [self invoke];
}

/* Put the return value where the forwarded message's caller expects it. */
- (void)_finchStoreReturnInFrame:(unsigned char *)frame
{
    ArgInfo *r = [_signature _finchReturn];
    if (r->loc == LOC_NONE) return;
    if (r->indirect) {
        memcpy(*(void **)(frame + FRAME_X8), _retdata, r->size);
        return;
    }
    frame_set(r, frame, _retdata, NULL);
}

@end

/* MARK: - Forwarding */

static void
unrecognized(id self, SEL sel)
{
    BOOL isClass = object_isClass(self);
    __CFFinchRaise(NSInvalidArgumentException, "%c[%s %s]: unrecognized selector sent to %s %p",
        isClass ? '+' : '-', object_getClassName(self), sel_getName(sel), isClass ? "class" : "instance", self);
}

/* From ___CFFinchForwardingEntry: 1 means "x0 now holds a new receiver, send
 * the message again", 0 that the frame holds the result. */
CF_PRIVATE int
__CFFinchForward(unsigned char *frame, const void *stack)
{
    id receiver = *(id *)(frame + FRAME_GPR(0));
    SEL sel = *(SEL *)(frame + FRAME_GPR(1));
    Class cls = object_getClass(receiver);

    if (class_respondsToSelector(cls, @selector(forwardingTargetForSelector:))) {
        id target = ((id (*)(id, SEL, SEL))objc_msgSend)(receiver, @selector(forwardingTargetForSelector:), sel);
        if (target && target != receiver) {
            *(id *)(frame + FRAME_GPR(0)) = target;
            return 1;
        }
    }
    if (class_respondsToSelector(cls, @selector(methodSignatureForSelector:))) {
        NSMethodSignature *sig = ((id (*)(id, SEL, SEL))objc_msgSend)(receiver, @selector(methodSignatureForSelector:), sel);
        if (sig) {
            if (class_respondsToSelector(cls, @selector(forwardInvocation:))) {
                NSInvocation *inv = [NSInvocation _finchInvocationWithSignature:sig frame:frame stack:stack];
                ((void (*)(id, SEL, id))objc_msgSend)(receiver, @selector(forwardInvocation:), inv);
                [inv _finchStoreReturnInFrame:frame];
                return 0;
            }
        }
    }
    if (class_respondsToSelector(cls, @selector(doesNotRecognizeSelector:))) {
        ((void (*)(id, SEL, SEL))objc_msgSend)(receiver, @selector(doesNotRecognizeSelector:), sel);
    }
    unrecognized(receiver, sel);
    __builtin_unreachable();
}

CF_PRIVATE void
__CFFinchInstallForwardHandler(void)
{
    objc_setForwardHandler((void *)__CFFinchForwardingEntry, (void *)__CFFinchForwardingEntry);
}

/* MARK: - NSObject */

/* The NSObject methods Apple's CoreFoundation provides: libobjc's versions
 * abort ("not available without CoreFoundation") or return nil. */
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation NSObject (FinchForwarding)

+ (NSMethodSignature *)instanceMethodSignatureForSelector:(SEL)sel
{
    Method m = sel ? class_getInstanceMethod(self, sel) : NULL;
    return m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
}

+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    Method m = sel ? class_getClassMethod(self, sel) : NULL;
    return m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    Method m = sel ? class_getInstanceMethod(object_getClass(self), sel) : NULL;
    return m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
}

- (void)forwardInvocation:(NSInvocation *)inv { [self doesNotRecognizeSelector:[inv selector]]; }
+ (void)forwardInvocation:(NSInvocation *)inv { [self doesNotRecognizeSelector:[inv selector]]; }

- (void)doesNotRecognizeSelector:(SEL)sel { unrecognized(self, sel); }
+ (void)doesNotRecognizeSelector:(SEL)sel { unrecognized(self, sel); }

- (id)description
{
    return [(id)CFStringCreateWithFormat(NULL, NULL, CFSTR("<%s: %p>"), object_getClassName(self), self) autorelease];
}

+ (id)description
{
    return [(id)CFStringCreateWithCString(NULL, class_getName(self), kCFStringEncodingUTF8) autorelease];
}

- (id)debugDescription { return [self description]; }
+ (id)debugDescription { return [self description]; }

@end
