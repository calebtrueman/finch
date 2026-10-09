/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Coercion: the handlers apps install (AEInstallCoercionHandler) and the
 * built-in ones, with the results macOS gives (worked out by running
 * Apple's AE on every pairing of the common types; the code is Finch's):
 *
 *  - numbers convert among shor, long, comp, magn, doub and sing when the
 *    value fits (reals round half to even; a negative real is never magn);
 *  - numbers, booleans, type codes and enumerations become text; reals
 *    print with 16 significant digits (8 for sing), switching to an
 *    exponent, with a space in the sign's place, at 10^16 (10^8) and below
 *    10^-6;
 *  - TEXT (UTF-8 on macOS today) parses as a number, as a boolean
 *    (true/false/yes/no) and, four bytes long, as a type or enumeration;
 *    utxt and utf8 don't;
 *  - booleans, true and fals are 1 and 0 as integers, but as comp or magn
 *    they come out typed 'long' (a quirk kept for fidelity);
 *  - any descriptor becomes a one-item list; a one-item list coerces as
 *    its item; a record can take any type but list and aevt (it stays a
 *    record); an Apple event becomes a record of its parameters.
 */
#include "AE_Finch.h"
#include <math.h>
#include <pthread.h>
#include <sys/stat.h>

FINCH_HIDDEN bool ae_same(const AEDesc *a, const AEDesc *b);

#pragma mark - Installed handlers

struct coercion {
    DescType from, to;
    AECoercionHandlerUPP handler;
    SRefCon refcon;
    Boolean fromIsDesc;
};

static struct {
    struct coercion *v;
    long count;
} tables[2];  /* application, system */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static struct coercion *
find_exact(int sys, DescType from, DescType to)
{
    for (long i = 0; i < tables[sys].count; i++)
        if (tables[sys].v[i].from == from && tables[sys].v[i].to == to)
            return &tables[sys].v[i];
    return NULL;
}

OSErr
AEInstallCoercionHandler(DescType fromType, DescType toType, AECoercionHandlerUPP handler, SRefCon handlerRefcon,
                         Boolean fromTypeIsDesc, Boolean isSysHandler)
{
    if (!handler)
        return paramErr;
    int sys = isSysHandler ? 1 : 0;
    pthread_mutex_lock(&lock);
    struct coercion *c = find_exact(sys, fromType, toType);
    if (!c) {
        struct coercion *v = realloc(tables[sys].v, (tables[sys].count + 1) * sizeof *v);
        if (!v) {
            pthread_mutex_unlock(&lock);
            return memFullErr;
        }
        tables[sys].v = v;
        c = &v[tables[sys].count++];
    }
    *c = (struct coercion){fromType, toType, handler, handlerRefcon, fromTypeIsDesc};
    pthread_mutex_unlock(&lock);
    return noErr;
}

OSErr
AERemoveCoercionHandler(DescType fromType, DescType toType, AECoercionHandlerUPP handler, Boolean isSysHandler)
{
    int sys = isSysHandler ? 1 : 0;
    pthread_mutex_lock(&lock);
    struct coercion *c = find_exact(sys, fromType, toType);
    OSErr e = errAEHandlerNotFound;
    if (c && (!handler || c->handler == handler)) {
        long i = c - tables[sys].v;
        memmove(c, c + 1, (tables[sys].count - i - 1) * sizeof *c);
        tables[sys].count--;
        e = noErr;
    }
    pthread_mutex_unlock(&lock);
    return e;
}

OSErr
AEGetCoercionHandler(DescType fromType, DescType toType, AECoercionHandlerUPP *handler, SRefCon *handlerRefcon,
                     Boolean *fromTypeIsDesc, Boolean isSysHandler)
{
    pthread_mutex_lock(&lock);
    struct coercion *c = find_exact(isSysHandler ? 1 : 0, fromType, toType);
    if (c) {
        if (handler)
            *handler = c->handler;
        if (handlerRefcon)
            *handlerRefcon = c->refcon;
        if (fromTypeIsDesc)
            *fromTypeIsDesc = c->fromIsDesc;
    }
    pthread_mutex_unlock(&lock);
    return c ? noErr : errAEHandlerNotFound;
}

/* The most specific installed handler (application table first), copied out. */
static bool
lookup(DescType from, DescType to, struct coercion *out)
{
    DescType froms[] = {from, from, typeWildCard, typeWildCard};
    DescType tos[] = {to, typeWildCard, to, typeWildCard};
    bool found = false;
    pthread_mutex_lock(&lock);
    for (int sys = 0; sys < 2 && !found; sys++)
        for (int i = 0; i < 4 && !found; i++) {
            struct coercion *c = find_exact(sys, froms[i], tos[i]);
            if (c) {
                *out = *c;
                found = true;
            }
        }
    pthread_mutex_unlock(&lock);
    return found;
}

AECoerceDescUPP (NewAECoerceDescUPP)(AECoerceDescProcPtr userRoutine) { return userRoutine; }
AECoercePtrUPP (NewAECoercePtrUPP)(AECoercePtrProcPtr userRoutine) { return userRoutine; }
void (DisposeAECoerceDescUPP)(AECoerceDescUPP userUPP) {}
void (DisposeAECoercePtrUPP)(AECoercePtrUPP userUPP) {}
OSErr (InvokeAECoerceDescUPP)(const AEDesc *fromDesc, DescType toType, SRefCon handlerRefcon, AEDesc *toDesc,
                            AECoerceDescUPP userUPP)
{
    return userUPP(fromDesc, toType, handlerRefcon, toDesc);
}
OSErr (InvokeAECoercePtrUPP)(DescType typeCode, const void *dataPtr, Size dataSize, DescType toType,
                           SRefCon handlerRefcon, AEDesc *result, AECoercePtrUPP userUPP)
{
    return userUPP(typeCode, dataPtr, dataSize, toType, handlerRefcon, result);
}

#pragma mark - Numbers and text

enum numkind { N_NONE, N_INT, N_UINT, N_REAL, N_BOOL };

struct num {
    enum numkind kind;
    int64_t i;
    uint64_t u;
    double f;
    bool single;  /* a sing: printed with 8 digits */
};

static bool
is_text(DescType t)
{
    return t == typeChar || t == typeUnicodeText || t == typeUTF8Text || t == typeUTF16ExternalRepresentation;
}

/* Text of any of the text types, as UTF-8 (malloc'd, NUL-terminated). */
static char *
text_utf8(DescType type, const void *p, Size n)
{
    CFStringRef s = NULL;
    switch (type) {
    case typeChar:
        s = CFStringCreateWithBytes(NULL, p, n, kCFStringEncodingUTF8, false);
        if (!s)
            s = CFStringCreateWithBytes(NULL, p, n, kCFStringEncodingMacRoman, false);
        break;
    case typeUTF8Text: s = CFStringCreateWithBytes(NULL, p, n, kCFStringEncodingUTF8, false); break;
    case typeUnicodeText: s = CFStringCreateWithBytes(NULL, p, n & ~1, kCFStringEncodingUTF16LE, false); break;
    case typeUTF16ExternalRepresentation: s = CFStringCreateWithBytes(NULL, p, n & ~1, kCFStringEncodingUTF16, true); break;
    }
    if (!s)
        return NULL;
    CFIndex len = CFStringGetLength(s), max = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
    char *out = malloc(max);
    CFIndex used = 0;
    CFStringGetBytes(s, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false, (UInt8 *)out, max - 1, &used);
    out[used] = 0;
    CFRelease(s);
    return out;
}

static OSErr
make_text(DescType to, const char *utf8, AEDesc *out)
{
    size_t n = strlen(utf8);
    if (to == typeChar || to == typeUTF8Text)
        return ae_make_data(to, utf8, n, out);
    CFStringRef s = CFStringCreateWithBytes(NULL, (const UInt8 *)utf8, n, kCFStringEncodingUTF8, false);
    if (!s)
        return errAECoercionFail;
    CFIndex len = CFStringGetLength(s);
    bool external = to == typeUTF16ExternalRepresentation;
    UniChar *u = malloc((len + 1) * sizeof *u);
    CFStringGetCharacters(s, CFRangeMake(0, len), external ? u + 1 : u);
    CFRelease(s);
    if (external)
        u[0] = 0xfeff;
    OSErr e = ae_make_data(to, u, (len + (external ? 1 : 0)) * sizeof *u, out);
    free(u);
    return e;
}

/* A real as Apple's AE writes it (see the comment at the top). */
static void
format_real(double v, int precision, char *out, size_t size)
{
    if (isnan(v)) {
        snprintf(out, size, "NAN(000)");
        return;
    }
    if (isinf(v)) {
        snprintf(out, size, v < 0 ? "-INF" : "INF");
        return;
    }
    if (v == 0) {
        snprintf(out, size, "0");
        return;
    }
    char e[64];
    snprintf(e, sizeof e, "%.*e", precision - 1, v);
    bool neg = e[0] == '-';
    char digits[40];
    int nd = 0;
    const char *p = e + (neg ? 1 : 0);
    for (; *p && *p != 'e'; p++)
        if (*p >= '0' && *p <= '9')
            digits[nd++] = *p;
    int x = atoi(p + 1);
    while (nd > 1 && digits[nd - 1] == '0')
        nd--;
    digits[nd] = 0;
    char *o = out;
    char *end = out + size - 1;
#define PUT(c) do { if (o < end) *o++ = (c); } while (0)
    if (x >= precision || x < -6) {
        PUT(neg ? '-' : ' ');
        PUT(digits[0]);
        if (nd > 1) {
            PUT('.');
            for (int i = 1; i < nd; i++)
                PUT(digits[i]);
        }
        o += snprintf(o, end - o + 1, "e%c%d", x < 0 ? '-' : '+', x < 0 ? -x : x);
    } else {
        if (neg)
            PUT('-');
        if (x >= 0) {
            for (int i = 0; i <= x; i++)
                PUT(i < nd ? digits[i] : '0');
            if (nd > x + 1) {
                PUT('.');
                for (int i = x + 1; i < nd; i++)
                    PUT(digits[i]);
            }
        } else {
            PUT('0');
            PUT('.');
            for (int i = 0; i < -x - 1; i++)
                PUT('0');
            for (int i = 0; i < nd; i++)
                PUT(digits[i]);
        }
    }
#undef PUT
    *o = 0;
}

/* TEXT as a number: optional leading spaces, a decimal (or inf/nan), nothing after. */
static bool
parse_number(const char *s, double *out)
{
    while (*s == ' ' || *s == '\t')
        s++;
    if (!*s) {
        *out = 0;
        return true;
    }
    const char *q = s + (*s == '-' || *s == '+');
    if (q[0] == '0' && (q[1] == 'x' || q[1] == 'X'))
        return false;
    char *end;
    *out = strtod(s, &end);
    return end != s && !*end;
}

static bool
get_num(const AEDesc *d, struct num *n)
{
    Size size;
    const unsigned char *p = ae_bytes(d, &size);
    memset(n, 0, sizeof *n);
    switch (d->descriptorType) {
    case typeSInt16:
        if (size < 2) return false;
        n->kind = N_INT, n->i = *(const SInt16 *)p;
        return true;
    case typeSInt32:
        if (size < 4) return false;
        n->kind = N_INT, n->i = *(const SInt32 *)p;
        return true;
    case typeSInt64:
        if (size < 8) return false;
        n->kind = N_INT, n->i = *(const SInt64 *)p;
        return true;
    case typeUInt16:
        if (size < 2) return false;
        n->kind = N_UINT, n->u = *(const UInt16 *)p;
        return true;
    case typeUInt32:
        if (size < 4) return false;
        n->kind = N_UINT, n->u = *(const UInt32 *)p;
        return true;
    case typeUInt64:
        if (size < 8) return false;
        n->kind = N_UINT, n->u = *(const UInt64 *)p;
        return true;
    case typeIEEE64BitFloatingPoint:
        if (size < 8) return false;
        n->kind = N_REAL, n->f = *(const double *)p;
        return true;
    case typeIEEE32BitFloatingPoint:
        if (size < 4) return false;
        n->kind = N_REAL, n->f = *(const float *)p, n->single = true;
        return true;
    case typeBoolean:
        if (size < 1) return false;
        n->kind = N_BOOL, n->i = p[0] != 0;
        return true;
    case typeTrue:
        n->kind = N_BOOL, n->i = 1;
        return true;
    case typeFalse:
        n->kind = N_BOOL, n->i = 0;
        return true;
    }
    return false;
}

static OSErr
put_int(DescType to, int64_t v, bool fits, AEDesc *out)
{
    if (!fits)
        return errAECoercionFail;
    switch (to) {
    case typeSInt16: { SInt16 x = (SInt16)v; return ae_make_data(to, &x, 2, out); }
    case typeSInt32: { SInt32 x = (SInt32)v; return ae_make_data(to, &x, 4, out); }
    case typeSInt64: { SInt64 x = v; return ae_make_data(to, &x, 8, out); }
    case typeUInt16: { UInt16 x = (UInt16)v; return ae_make_data(to, &x, 2, out); }
    case typeUInt32: { UInt32 x = (UInt32)v; return ae_make_data(to, &x, 4, out); }
    case typeUInt64: { UInt64 x = (UInt64)v; return ae_make_data(to, &x, 8, out); }
    }
    return errAECoercionFail;
}

static void
range_of(DescType t, double *lo, double *hi)
{
    switch (t) {
    case typeSInt16: *lo = INT16_MIN, *hi = INT16_MAX; break;
    case typeSInt32: *lo = INT32_MIN, *hi = INT32_MAX; break;
    case typeSInt64: *lo = -9223372036854775808.0, *hi = 9223372036854775807.0; break;
    case typeUInt16: *lo = 0, *hi = UINT16_MAX; break;
    case typeUInt32: *lo = 0, *hi = UINT32_MAX; break;
    default: *lo = 0, *hi = 18446744073709551615.0; break;
    }
}

static bool
is_integer_type(DescType t)
{
    return t == typeSInt16 || t == typeSInt32 || t == typeSInt64 || t == typeUInt16 || t == typeUInt32 || t == typeUInt64;
}

/* A number to another number type, or to text, a boolean or an enumeration. */
static OSErr
from_num(const struct num *n, DescType to, AEDesc *out)
{
    if (is_integer_type(to)) {
        double lo, hi;
        range_of(to, &lo, &hi);
        switch (n->kind) {
        case N_INT: return put_int(to, n->i, n->i >= lo && (double)n->i <= hi, out);
        case N_UINT: return put_int(to, (int64_t)n->u, (double)n->u <= hi, out);
        case N_REAL: {
            if (isnan(n->f) || ((to == typeUInt16 || to == typeUInt32 || to == typeUInt64) && n->f < 0))
                return errAECoercionFail;
            double r = rint(n->f);
            if (r < lo || r > hi || (to == typeSInt64 && r >= 9223372036854775807.0))
                return errAECoercionFail;
            if (to == typeUInt64)
                return put_int(to, (int64_t)(uint64_t)r, true, out);
            return put_int(to, (int64_t)r, true, out);
        }
        case N_BOOL:
            /* Apple's: as comp and magn a boolean comes out typed 'long' */
            if (to == typeSInt64) {
                SInt64 x = n->i;
                return ae_make_data(typeSInt32, &x, 8, out);
            }
            if (to == typeUInt32) {
                SInt32 x = (SInt32)n->i;
                return ae_make_data(typeSInt32, &x, 4, out);
            }
            return put_int(to, n->i, true, out);
        default: return errAECoercionFail;
        }
    }
    if (to == typeIEEE64BitFloatingPoint || to == typeIEEE32BitFloatingPoint) {
        double v;
        switch (n->kind) {
        case N_INT: v = (double)n->i; break;
        case N_UINT: v = (double)n->u; break;
        case N_REAL: v = n->f; break;
        default: return errAECoercionFail;
        }
        if (to == typeIEEE32BitFloatingPoint) {
            float f = (float)v;
            return ae_make_data(to, &f, 4, out);
        }
        return ae_make_data(to, &v, 8, out);
    }
    if (is_text(to)) {
        char buf[64];
        switch (n->kind) {
        case N_INT: snprintf(buf, sizeof buf, "%lld", (long long)n->i); break;
        case N_UINT: snprintf(buf, sizeof buf, "%llu", (unsigned long long)n->u); break;
        case N_REAL: format_real(n->f, n->single ? 8 : 16, buf, sizeof buf); break;
        case N_BOOL: snprintf(buf, sizeof buf, "%s", n->i ? "true" : "false"); break;
        default: return errAECoercionFail;
        }
        return make_text(to, buf, out);
    }
    bool zero_or_one = (n->kind == N_INT && (n->i == 0 || n->i == 1)) || (n->kind == N_UINT && n->u <= 1) ||
                       n->kind == N_BOOL;
    int64_t v = n->kind == N_UINT ? (int64_t)n->u : n->i;
    if (to == typeBoolean) {
        if (!zero_or_one)
            return errAECoercionFail;
        Boolean b = v != 0;
        return ae_make_data(to, &b, 1, out);
    }
    if (to == typeEnumerated) {
        if (!zero_or_one)
            return errAECoercionFail;
        OSType t = v ? 'true' : 'fals';
        return ae_make_data(to, &t, 4, out);
    }
    if (to == typeTrue && n->kind == N_BOOL && v)
        return ae_make_data(typeTrue, NULL, 0, out);
    if (to == typeFalse && n->kind == N_BOOL && !v)
        return ae_make_data(typeFalse, NULL, 0, out);
    return errAECoercionFail;
}

/* TEXT parsed as what it names. */
static OSErr
from_TEXT(const AEDesc *d, DescType to, AEDesc *out)
{
    Size size;
    const char *p = ae_bytes(d, &size);
    if ((to == typeType || to == typeEnumerated) && size == 4) {
        OSType t = ((OSType)(unsigned char)p[0] << 24) | ((OSType)(unsigned char)p[1] << 16) |
                   ((OSType)(unsigned char)p[2] << 8) | (unsigned char)p[3];
        return ae_make_data(to, &t, 4, out);
    }
    if (to == typeTrue)
        return ae_make_data(typeTrue, NULL, 0, out);
    char *s = malloc(size + 1);
    memcpy(s, p, size);
    s[size] = 0;
    OSErr e = errAECoercionFail;
    if (to == typeBoolean) {
        int b = -1;
        if (!strcasecmp(s, "true") || !strcasecmp(s, "yes"))
            b = 1;
        else if (!strcasecmp(s, "false") || !strcasecmp(s, "no"))
            b = 0;
        if (b >= 0) {
            Boolean v = b;
            e = ae_make_data(to, &v, 1, out);
        }
    } else if (is_integer_type(to) || to == typeIEEE64BitFloatingPoint || to == typeIEEE32BitFloatingPoint) {
        double v;
        if (parse_number(s, &v)) {
            switch (to) {
            case typeIEEE64BitFloatingPoint: e = ae_make_data(to, &v, 8, out); break;
            case typeIEEE32BitFloatingPoint: { float f = (float)v; e = ae_make_data(to, &f, 4, out); break; }
            case typeUInt32: case typeUInt16: case typeUInt64: {
                if (isnan(v) || v < 0)
                    break;
                double hi, lo;
                range_of(to, &lo, &hi);
                double t = trunc(v);
                e = put_int(to, t > hi ? (int64_t)(uint64_t)hi : (int64_t)(uint64_t)t, true, out);
                break;
            }
            case typeSInt64: {
                SInt64 x = isnan(v) ? 0 : v >= 9223372036854775807.0 ? INT64_MAX : v <= -9223372036854775808.0 ? INT64_MIN : (SInt64)rint(v);
                e = ae_make_data(to, &x, 8, out);
                break;
            }
            default: {
                double lo, hi;
                range_of(to, &lo, &hi);
                double r = rint(v);
                int64_t x = (isnan(v) || r < lo || r > hi) ? (int64_t)lo : (int64_t)r;
                e = put_int(to, x, true, out);
            }
            }
        }
    }
    free(s);
    return e;
}

/* Booleans named by type codes and enumerations (Apple's: a 'fals' type isn't one). */
static OSErr
code_to_bool(const AEDesc *d, AEDesc *out)
{
    Size size;
    const OSType *p = ae_bytes(d, &size);
    if (size < 4)
        return errAECoercionFail;
    int b = -1;
    switch (*p) {
    case 'true': case 'yes ': b = 1; break;
    case 'no  ': b = 0; break;
    case 'fals': b = d->descriptorType == typeEnumerated ? 0 : -1; break;
    }
    if (b < 0)
        return errAECoercionFail;
    Boolean v = b;
    return ae_make_data(typeBoolean, &v, 1, out);
}

#pragma mark - Files

FINCH_HIDDEN OSErr ae_file_coerce(const AEDesc *from, DescType to, AEDesc *out);

OSErr
ae_file_coerce(const AEDesc *from, DescType to, AEDesc *out)
{
    Size size;
    const void *p = ae_bytes(from, &size);
    char path[PATH_MAX];
    if (from->descriptorType == typeFileURL) {
        CFURLRef u = CFURLCreateWithBytes(NULL, p, size, kCFStringEncodingUTF8, NULL);
        bool ok = u && CFURLGetFileSystemRepresentation(u, true, (UInt8 *)path, sizeof path);
        if (u)
            CFRelease(u);
        if (!ok)
            return errAECoercionFail;
    } else if (from->descriptorType == typeFSRef) {
        if (size < (Size)sizeof(FSRef) || FSRefMakePath(p, (UInt8 *)path, sizeof path))
            return errAECoercionFail;
    } else if (from->descriptorType == typeAlias) {
        Handle h = NULL;
        if (PtrToHand(p, &h, size))
            return errAECoercionFail;
        FSRef ref;
        Boolean changed;
        OSErr e = FSResolveAlias(NULL, (AliasHandle)h, &ref, &changed);
        DisposeHandle(h);
        if (e || FSRefMakePath(&ref, (UInt8 *)path, sizeof path))
            return errAECoercionFail;
    } else {
        return errAECoercionFail;
    }
    if (to == typeFileURL) {
        struct stat st;
        bool dir = stat(path, &st) == 0 && S_ISDIR(st.st_mode);
        CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), dir);
        CFStringRef s = CFURLGetString(u);
        CFIndex len = CFStringGetLength(s);
        char buf[PATH_MAX * 3];
        CFIndex used = 0;
        CFStringGetBytes(s, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false, (UInt8 *)buf, sizeof buf, &used);
        CFRelease(u);
        return ae_make_data(to, buf, used, out);
    }
    if (to == typeFSRef) {
        FSRef ref;
        if (FSPathMakeRef((const UInt8 *)path, &ref, NULL))
            return errAECoercionFail;
        return ae_make_data(to, &ref, sizeof ref, out);
    }
    if (to == typeAlias) {
        FSRef ref;
        AliasHandle a = NULL;
        if (FSPathMakeRef((const UInt8 *)path, &ref, NULL) || FSNewAlias(NULL, &ref, &a))
            return errAECoercionFail;
        OSErr e = ae_make_data(to, *a, GetHandleSize((Handle)a), out);
        DisposeHandle((Handle)a);
        return e;
    }
    return errAECoercionFail;
}

#pragma mark - Coercing

static OSErr
builtin(const AEDesc *from, DescType to, AEDesc *out)
{
    DescType ft = from->descriptorType;
    struct num n;
    if (get_num(from, &n))
        return from_num(&n, to, out);
    if (ft == typeChar && !is_text(to))
        return from_TEXT(from, to, out);
    if (is_text(ft) && is_text(to)) {
        Size size;
        const void *p = ae_bytes(from, &size);
        char *s = text_utf8(ft, p, size);
        if (!s)
            return errAECoercionFail;
        OSErr e = make_text(to, s, out);
        free(s);
        return e;
    }
    if ((ft == typeType || ft == typeEnumerated) && is_text(to)) {
        Size size;
        const unsigned char *p = ae_bytes(from, &size);
        if (size < 4)
            return errAECoercionFail;
        OSType t = *(const OSType *)p;
        char s[5] = {(char)(t >> 24), (char)(t >> 16), (char)(t >> 8), (char)t, 0};
        return to == typeChar || to == typeUTF8Text ? ae_make_data(to, s, 4, out) : make_text(to, s, out);
    }
    if ((ft == typeType || ft == typeEnumerated) && to == typeBoolean)
        return code_to_bool(from, out);
    if ((ft == typeFileURL || ft == typeFSRef || ft == typeAlias) && (to == typeFileURL || to == typeFSRef || to == typeAlias))
        return ae_file_coerce(from, to, out);
    return errAECoercionFail;
}

static OSErr
call_handler(const struct coercion *c, const AEDesc *from, DescType to, AEDesc *out)
{
    AEInitializeDesc(out);
    if (c->fromIsDesc)
        return ((AECoerceDescUPP)c->handler)(from, to, c->refcon, out);
    Size size;
    const void *p = ae_bytes(from, &size);
    return ((AECoercePtrUPP)(void *)c->handler)(from->descriptorType, p, size, to, c->refcon, out);
}

OSErr
ae_coerce(const AEDesc *from, DescType to, AEDesc *out)
{
    if (!from || !out)
        return paramErr;
    if (to == typeWildCard || to == from->descriptorType)
        return AEDuplicateDesc(from, out);
    struct coercion c;
    if (lookup(from->descriptorType, to, &c))
        return call_handler(&c, from, to, out);
    struct ae_store *s = ae_store(from);
    if (to == typeAEList) {
        AEDescList l;
        OSErr e = ae_make_container(typeAEList, AE_LIST, &l);
        if (!e && (e = AEPutDesc(&l, 0, from)))
            AEDisposeDesc(&l);
        if (!e)
            *out = l;
        return e;
    }
    if (s && s->kind == AE_LIST) {
        if (s->items.count != 1)
            return errAECoercionFail;
        return ae_coerce(&s->items.v[0].desc, to, out);
    }
    if (s && s->kind == AE_RECORD) {
        if (to == typeAppleEvent)
            return errAECoercionFail;
        OSErr e = AEDuplicateDesc(from, out);
        if (!e)
            out->descriptorType = to;
        return e;
    }
    if (s && s->kind == AE_EVENT) {
        if (to != typeAERecord)
            return errAECoercionFail;
        OSErr e = ae_make_container(typeAERecord, AE_RECORD, out);
        if (!e && (e = ae_copy_items(&s->items, &ae_store(out)->items)))
            AEDisposeDesc(out);
        return e;
    }
    AEInitializeDesc(out);
    return builtin(from, to, out);
}

OSErr
AECoerceDesc(const AEDesc *theAEDesc, DescType toType, AEDesc *result)
{
    AEDesc r;
    OSErr e = ae_coerce(theAEDesc, toType, &r);
    if (result)
        *result = e ? (AEDesc){typeNull, NULL} : r;
    return e;
}

OSErr
AECoercePtr(DescType typeCode, const void *dataPtr, Size dataSize, DescType toType, AEDesc *result)
{
    AEDesc d;
    OSErr e = ae_make_data(typeCode, dataPtr, dataSize, &d);
    if (e)
        return e;
    e = AECoerceDesc(&d, toType, result);
    AEDisposeDesc(&d);
    return e;
}
