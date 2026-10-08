/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Decimal arithmetic (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSDecimal.h> and <Foundation/NSDecimalNumber.h>: the
 * NSDecimal functions, NSDecimalNumber, NSDecimalNumberHandler and
 * NSNumber's -decimalValue.
 *
 * An NSDecimal is a 128-bit mantissa (eight 16-bit words, least
 * significant first) times ten to a signed 8-bit exponent. The work is
 * done on wider integers (Big, 1024 bits, enough to line up any two
 * exponents) and brought back to 128 bits by dropping digits, rounded as
 * the caller asks. Results are compacted (no trailing zeros in the
 * mantissa), as Apple's are. Division scales the dividend to 39 digits
 * and truncates the quotient, which is how Apple's gets 1/3 =
 * 0.33333333333333333333333333333333333333.
 */
#import <Foundation/Foundation.h>
#include <math.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

NSExceptionName const NSDecimalNumberExactnessException = @"NSDecimalNumberExactnessException";
NSExceptionName const NSDecimalNumberOverflowException = @"NSDecimalNumberOverflowException";
NSExceptionName const NSDecimalNumberUnderflowException = @"NSDecimalNumberUnderflowException";
NSExceptionName const NSDecimalNumberDivideByZeroException = @"NSDecimalNumberDivideByZeroException";
NSString *const NSDecimalSeparator = @"NSDecimalSeparator";

/* MARK: - Wide integers */

#define LIMBS 32

typedef struct {
    uint32_t w[LIMBS];   /* least significant first */
} Big;

static void
big_set128(Big *b, unsigned __int128 v)
{
    memset(b, 0, sizeof(*b));
    for (int i = 0; i < 4; i++) { b->w[i] = (uint32_t)v; v >>= 32; }
}

static BOOL
big_is_zero(const Big *b)
{
    for (int i = 0; i < LIMBS; i++) if (b->w[i]) return NO;
    return YES;
}

static BOOL
big_fits128(const Big *b)
{
    for (int i = 4; i < LIMBS; i++) if (b->w[i]) return NO;
    return YES;
}

static unsigned __int128
big_get128(const Big *b)
{
    unsigned __int128 v = 0;
    for (int i = 3; i >= 0; i--) v = (v << 32) | b->w[i];
    return v;
}

/* NO on overflow. */
static BOOL
big_mul_small(Big *b, uint32_t k)
{
    uint64_t carry = 0;
    for (int i = 0; i < LIMBS; i++) {
        uint64_t p = (uint64_t)b->w[i] * k + carry;
        b->w[i] = (uint32_t)p;
        carry = p >> 32;
    }
    return carry == 0;
}

static uint32_t
big_divmod_small(Big *b, uint32_t k)
{
    uint64_t rem = 0;
    for (int i = LIMBS - 1; i >= 0; i--) {
        uint64_t cur = (rem << 32) | b->w[i];
        b->w[i] = (uint32_t)(cur / k);
        rem = cur % k;
    }
    return (uint32_t)rem;
}

static int
big_cmp(const Big *a, const Big *b)
{
    for (int i = LIMBS - 1; i >= 0; i--)
        if (a->w[i] != b->w[i]) return a->w[i] < b->w[i] ? -1 : 1;
    return 0;
}

static void
big_add(Big *r, const Big *a, const Big *b)
{
    uint64_t carry = 0;
    for (int i = 0; i < LIMBS; i++) {
        uint64_t s = (uint64_t)a->w[i] + b->w[i] + carry;
        r->w[i] = (uint32_t)s;
        carry = s >> 32;
    }
}

/* a >= b */
static void
big_sub(Big *r, const Big *a, const Big *b)
{
    int64_t borrow = 0;
    for (int i = 0; i < LIMBS; i++) {
        int64_t d = (int64_t)a->w[i] - b->w[i] - borrow;
        borrow = d < 0;
        r->w[i] = (uint32_t)(d + (borrow ? ((int64_t)1 << 32) : 0));
    }
}

static void
big_mul(Big *r, const Big *a, const Big *b)
{
    Big t;
    memset(&t, 0, sizeof(t));
    for (int i = 0; i < LIMBS; i++) {
        if (!a->w[i]) continue;
        uint64_t carry = 0;
        for (int j = 0; i + j < LIMBS; j++) {
            uint64_t p = (uint64_t)a->w[i] * b->w[j] + t.w[i + j] + carry;
            t.w[i + j] = (uint32_t)p;
            carry = p >> 32;
        }
    }
    *r = t;
}

static int
big_bits(const Big *b)
{
    for (int i = LIMBS - 1; i >= 0; i--)
        if (b->w[i]) return i * 32 + (32 - __builtin_clz(b->w[i]));
    return 0;
}

/* q = a / b, by shift and subtract. */
static void
big_div(Big *q, const Big *a, const Big *b)
{
    Big rem, quo;
    memset(&rem, 0, sizeof(rem));
    memset(&quo, 0, sizeof(quo));
    for (int bit = big_bits(a) - 1; bit >= 0; bit--) {
        for (int i = LIMBS - 1; i > 0; i--) rem.w[i] = (rem.w[i] << 1) | (rem.w[i - 1] >> 31);
        rem.w[0] = (rem.w[0] << 1) | ((a->w[bit / 32] >> (bit % 32)) & 1);
        if (big_cmp(&rem, b) >= 0) {
            big_sub(&rem, &rem, b);
            quo.w[bit / 32] |= 1u << (bit % 32);
        }
    }
    *q = quo;
}

static int
big_digits(const Big *b)
{
    Big t = *b;
    int n = 0;
    while (!big_is_zero(&t)) { big_divmod_small(&t, 10); n++; }
    return n;
}

/* MARK: - Values */

typedef struct {
    Big m;
    int exp;
    BOOL neg;
    BOOL nan;
} Value;

static Value
from_decimal(const NSDecimal *d)
{
    Value v;
    memset(&v, 0, sizeof(v));
    if (NSDecimalIsNotANumber(d)) { v.nan = YES; return v; }
    unsigned __int128 m = 0;
    for (int i = (int)d->_length - 1; i >= 0; i--) m = (m << 16) | d->_mantissa[i];
    big_set128(&v.m, m);
    v.exp = d->_exponent;
    v.neg = d->_isNegative && m != 0;
    return v;
}

static void
set_nan(NSDecimal *d)
{
    memset(d, 0, sizeof(*d));
    d->_isNegative = 1;
}

static void
set_zero(NSDecimal *d)
{
    memset(d, 0, sizeof(*d));
    d->_isCompact = 1;
}

/* Divide by ten `n` times, rounding the dropped digits as `mode` asks. */
static void
drop_digits(Big *m, int n, BOOL neg, NSRoundingMode mode, BOOL *inexact)
{
    if (n <= 0) return;
    uint32_t last = 0;
    BOOL sticky = NO;
    for (int i = 0; i < n; i++) {
        if (last) sticky = YES;
        last = big_divmod_small(m, 10);
    }
    if (!last && !sticky) return;
    if (inexact) *inexact = YES;
    BOOL up;
    switch (mode) {
    case NSRoundDown: up = neg; break;
    case NSRoundUp: up = !neg; break;
    case NSRoundBankers: up = last > 5 || (last == 5 && (sticky || (m->w[0] & 1))); break;
    case NSRoundPlain:
    default: up = last >= 5; break;
    }
    if (up) {
        Big one;
        big_set128(&one, 1);
        big_add(m, m, &one);
    }
}

/* Bring a value back to an NSDecimal: at most 128 bits of mantissa, the
 * exponent in -128...127, compacted. */
static NSCalculationError
to_decimal(NSDecimal *d, Value v, NSRoundingMode mode)
{
    if (v.nan) { set_nan(d); return NSCalculationNoError; }
    BOOL inexact = NO;
    while (!big_fits128(&v.m)) {
        drop_digits(&v.m, 1, v.neg, mode, &inexact);
        v.exp++;
    }
    if (v.exp < -128) {
        drop_digits(&v.m, -128 - v.exp, v.neg, mode, &inexact);
        v.exp = -128;
        if (big_is_zero(&v.m)) { set_zero(d); return NSCalculationUnderflow; }
    }
    if (big_is_zero(&v.m)) { set_zero(d); return inexact ? NSCalculationLossOfPrecision : NSCalculationNoError; }
    /* Compact: no trailing zeros. */
    for (;;) {
        Big t = v.m;
        if (v.exp >= 127 || big_divmod_small(&t, 10) != 0) break;
        v.m = t;
        v.exp++;
    }
    while (v.exp > 127) {
        Big t = v.m;
        if (!big_mul_small(&t, 10) || !big_fits128(&t)) { set_nan(d); return NSCalculationOverflow; }
        v.m = t;
        v.exp--;
    }
    unsigned __int128 m = big_get128(&v.m);
    memset(d, 0, sizeof(*d));
    int len = 0;
    while (m) { d->_mantissa[len++] = (unsigned short)m; m >>= 16; }
    d->_length = (unsigned)len;
    d->_exponent = v.exp;
    d->_isNegative = v.neg;
    d->_isCompact = 1;
    return inexact ? NSCalculationLossOfPrecision : NSCalculationNoError;
}

/* Line up two values on the smaller exponent (the Big has room for any
 * difference an NSDecimal can have). */
static void
align(Value *a, Value *b)
{
    while (a->exp > b->exp) { big_mul_small(&a->m, 10); a->exp--; }
    while (b->exp > a->exp) { big_mul_small(&b->m, 10); b->exp--; }
}

/* MARK: - The functions */

void
NSDecimalCopy(NSDecimal *dst, const NSDecimal *src)
{
    *dst = *src;
}

void
NSDecimalCompact(NSDecimal *number)
{
    if (NSDecimalIsNotANumber(number)) return;
    to_decimal(number, from_decimal(number), NSRoundPlain);
}

NSComparisonResult
NSDecimalCompare(const NSDecimal *l, const NSDecimal *r)
{
    Value a = from_decimal(l), b = from_decimal(r);
    if (a.nan || b.nan) return a.nan && b.nan ? NSOrderedSame : a.nan ? NSOrderedAscending : NSOrderedDescending;
    if (big_is_zero(&a.m)) a.neg = NO;
    if (big_is_zero(&b.m)) b.neg = NO;
    if (a.neg != b.neg) return a.neg ? NSOrderedAscending : NSOrderedDescending;
    align(&a, &b);
    int c = big_cmp(&a.m, &b.m);
    if (a.neg) c = -c;
    return c < 0 ? NSOrderedAscending : c > 0 ? NSOrderedDescending : NSOrderedSame;
}

void
NSDecimalRound(NSDecimal *result, const NSDecimal *number, NSInteger scale, NSRoundingMode mode)
{
    Value v = from_decimal(number);
    if (v.nan) { set_nan(result); return; }
    if (scale != NSDecimalNoScale && v.exp < -scale) {
        drop_digits(&v.m, (int)(-scale - v.exp), v.neg, mode, NULL);
        v.exp = (int)-scale;
    }
    to_decimal(result, v, mode);
}

NSCalculationError
NSDecimalNormalize(NSDecimal *n1, NSDecimal *n2, NSRoundingMode mode)
{
    Value a = from_decimal(n1), b = from_decimal(n2);
    if (a.nan || b.nan) return NSCalculationNoError;
    NSCalculationError err = NSCalculationNoError;
    /* Lower the larger exponent while the mantissa fits, then raise the
     * smaller one, losing digits. */
    Value *hi = a.exp > b.exp ? &a : &b, *lo = hi == &a ? &b : &a;
    while (hi->exp > lo->exp) {
        Big t = hi->m;
        if (!big_mul_small(&t, 10) || !big_fits128(&t)) break;
        hi->m = t;
        hi->exp--;
    }
    if (hi->exp > lo->exp) {
        BOOL inexact = NO;
        drop_digits(&lo->m, hi->exp - lo->exp, lo->neg, mode, &inexact);
        lo->exp = hi->exp;
        if (inexact) err = NSCalculationLossOfPrecision;
    }
    /* Write them back without compacting. */
    NSDecimal *outs[2] = { n1, n2 };
    Value *vals[2] = { &a, &b };
    for (int i = 0; i < 2; i++) {
        unsigned __int128 m = big_get128(&vals[i]->m);
        NSDecimal *d = outs[i];
        memset(d, 0, sizeof(*d));
        int len = 0;
        while (m) { d->_mantissa[len++] = (unsigned short)m; m >>= 16; }
        d->_length = (unsigned)len;
        d->_exponent = vals[i]->exp;
        d->_isNegative = vals[i]->neg;
    }
    return err;
}

static NSCalculationError
add(NSDecimal *result, Value a, Value b, NSRoundingMode mode)
{
    if (a.nan || b.nan) { set_nan(result); return NSCalculationNoError; }
    align(&a, &b);
    Value r;
    memset(&r, 0, sizeof(r));
    r.exp = a.exp;
    if (a.neg == b.neg) {
        big_add(&r.m, &a.m, &b.m);
        r.neg = a.neg;
    } else if (big_cmp(&a.m, &b.m) >= 0) {
        big_sub(&r.m, &a.m, &b.m);
        r.neg = a.neg;
    } else {
        big_sub(&r.m, &b.m, &a.m);
        r.neg = b.neg;
    }
    if (big_is_zero(&r.m)) r.neg = NO;
    return to_decimal(result, r, mode);
}

NSCalculationError
NSDecimalAdd(NSDecimal *result, const NSDecimal *l, const NSDecimal *r, NSRoundingMode mode)
{
    return add(result, from_decimal(l), from_decimal(r), mode);
}

NSCalculationError
NSDecimalSubtract(NSDecimal *result, const NSDecimal *l, const NSDecimal *r, NSRoundingMode mode)
{
    Value b = from_decimal(r);
    b.neg = !b.neg;
    return add(result, from_decimal(l), b, mode);
}

NSCalculationError
NSDecimalMultiply(NSDecimal *result, const NSDecimal *l, const NSDecimal *r, NSRoundingMode mode)
{
    Value a = from_decimal(l), b = from_decimal(r);
    if (a.nan || b.nan) { set_nan(result); return NSCalculationNoError; }
    Value p;
    memset(&p, 0, sizeof(p));
    big_mul(&p.m, &a.m, &b.m);
    p.exp = a.exp + b.exp;
    p.neg = a.neg != b.neg && !big_is_zero(&p.m);
    return to_decimal(result, p, mode);
}

NSCalculationError
NSDecimalDivide(NSDecimal *result, const NSDecimal *l, const NSDecimal *r, NSRoundingMode mode)
{
    Value a = from_decimal(l), b = from_decimal(r);
    if (a.nan || b.nan) { set_nan(result); return NSCalculationNoError; }
    if (big_is_zero(&b.m)) { set_nan(result); return NSCalculationDivideByZero; }
    if (big_is_zero(&a.m)) { set_zero(result); return NSCalculationNoError; }
    int k = 39 - big_digits(&a.m);
    if (k < 0) k = 0;
    for (int i = 0; i < k; i++) big_mul_small(&a.m, 10);
    Value q;
    memset(&q, 0, sizeof(q));
    big_div(&q.m, &a.m, &b.m);
    q.exp = a.exp - k - b.exp;
    q.neg = a.neg != b.neg;
    return to_decimal(result, q, mode);
}

NSCalculationError
NSDecimalPower(NSDecimal *result, const NSDecimal *number, NSUInteger power, NSRoundingMode mode)
{
    if (NSDecimalIsNotANumber(number)) { set_nan(result); return NSCalculationNoError; }
    NSDecimal acc, base = *number;
    Value one;
    memset(&one, 0, sizeof(one));
    big_set128(&one.m, 1);
    to_decimal(&acc, one, mode);
    NSCalculationError err = NSCalculationNoError;
    while (power) {
        if (power & 1) {
            NSCalculationError e = NSDecimalMultiply(&acc, &acc, &base, mode);
            if (e) err = e;
            if (e == NSCalculationOverflow) break;
        }
        power >>= 1;
        if (power) {
            NSCalculationError e = NSDecimalMultiply(&base, &base, &base, mode);
            if (e == NSCalculationOverflow) { set_nan(&acc); err = e; break; }
        }
    }
    *result = acc;
    return err;
}

NSCalculationError
NSDecimalMultiplyByPowerOf10(NSDecimal *result, const NSDecimal *number, short power, NSRoundingMode mode)
{
    Value v = from_decimal(number);
    if (v.nan) { set_nan(result); return NSCalculationNoError; }
    v.exp += power;
    return to_decimal(result, v, mode);
}

static NSString *
separator(id locale)
{
    id sep = nil;
    if ([locale isKindOfClass:[NSLocale class]]) sep = [locale objectForKey:NSLocaleDecimalSeparator];
    else if ([locale isKindOfClass:[NSDictionary class]]) sep = [locale objectForKey:NSDecimalSeparator];
    return [sep isKindOfClass:[NSString class]] && [sep length] ? sep : @".";
}

NSString *
NSDecimalString(const NSDecimal *dcm, id locale)
{
    if (NSDecimalIsNotANumber(dcm)) return @"NaN";
    Value v = from_decimal(dcm);
    if (big_is_zero(&v.m)) return @"0";
    char digits[200], *p = digits + sizeof(digits);
    *--p = 0;
    Big t = v.m;
    while (!big_is_zero(&t)) *--p = (char)('0' + big_divmod_small(&t, 10));
    NSMutableString *s = [NSMutableString string];
    if (v.neg) [s appendString:@"-"];
    int n = (int)strlen(p);
    if (v.exp >= 0) {
        [s appendFormat:@"%s", p];
        for (int i = 0; i < v.exp; i++) [s appendString:@"0"];
    } else if (-v.exp >= n) {
        [s appendFormat:@"0%@", separator(locale)];
        for (int i = 0; i < -v.exp - n; i++) [s appendString:@"0"];
        [s appendFormat:@"%s", p];
    } else {
        [s appendFormat:@"%.*s%@%s", n + v.exp, p, separator(locale), p + n + v.exp];
    }
    return s;
}

/* Parse a decimal at `start`: [+-]digits[sep digits][e[+-]digits]. The
 * index after it, or NSNotFound without digits. Digits past the 128-bit
 * mantissa are dropped, as Apple's are. */
NSUInteger
FinchScanDecimal(NSString *s, NSUInteger start, NSString *sep, NSDecimal *out)
{
    NSUInteger len = [s length], i = start;
    unichar sepc = [sep length] ? [sep characterAtIndex:0] : '.';
    Value v;
    memset(&v, 0, sizeof(v));
    if (i < len && ([s characterAtIndex:i] == '-' || [s characterAtIndex:i] == '+')) {
        v.neg = [s characterAtIndex:i] == '-';
        i++;
    }
    BOOL any = NO, full = NO, frac = NO;
    for (; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == sepc && !frac) { frac = YES; continue; }
        if (c < '0' || c > '9') break;
        any = YES;
        if (!full) {
            Big t = v.m;
            if (big_mul_small(&t, 10)) {
                Big d;
                big_set128(&d, c - '0');
                big_add(&t, &t, &d);
            }
            if (big_fits128(&t)) {
                v.m = t;
                if (frac) v.exp--;
                continue;
            }
            full = YES;
        }
        if (!frac) v.exp++;
    }
    if (!any) return NSNotFound;
    if (i < len && ([s characterAtIndex:i] == 'e' || [s characterAtIndex:i] == 'E')) {
        NSUInteger j = i + 1;
        BOOL eneg = NO;
        if (j < len && ([s characterAtIndex:j] == '-' || [s characterAtIndex:j] == '+')) eneg = [s characterAtIndex:j++] == '-';
        if (j < len && [s characterAtIndex:j] >= '0' && [s characterAtIndex:j] <= '9') {
            int e = 0;
            for (; j < len && [s characterAtIndex:j] >= '0' && [s characterAtIndex:j] <= '9'; j++)
                if (e < 10000) e = e * 10 + ([s characterAtIndex:j] - '0');
            v.exp += eneg ? -e : e;
            i = j;
        }
    }
    if (big_is_zero(&v.m)) v.neg = NO;
    if (out && to_decimal(out, v, NSRoundPlain) == NSCalculationOverflow) set_nan(out);
    return i;
}

/* MARK: - NSDecimalNumberHandler */

@implementation NSDecimalNumberHandler

static NSDecimalNumberHandler *default_handler;

+ (NSDecimalNumberHandler *)defaultDecimalNumberHandler
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        default_handler = [[NSDecimalNumberHandler alloc] initWithRoundingMode:NSRoundPlain scale:NSDecimalNoScale
            raiseOnExactness:NO raiseOnOverflow:YES raiseOnUnderflow:YES raiseOnDivideByZero:YES];
    });
    return default_handler;
}

- (instancetype)init
{
    return [self initWithRoundingMode:NSRoundPlain scale:NSDecimalNoScale raiseOnExactness:NO raiseOnOverflow:YES
        raiseOnUnderflow:YES raiseOnDivideByZero:YES];
}

- (instancetype)initWithRoundingMode:(NSRoundingMode)roundingMode scale:(short)scale raiseOnExactness:(BOOL)exact
    raiseOnOverflow:(BOOL)overflow raiseOnUnderflow:(BOOL)underflow raiseOnDivideByZero:(BOOL)divideByZero
{
    if ((self = [super init])) {
        _roundingMode = (unsigned)roundingMode;
        _scale = scale;
        _raiseOnExactness = exact;
        _raiseOnOverflow = overflow;
        _raiseOnUnderflow = underflow;
        _raiseOnDivideByZero = divideByZero;
    }
    return self;
}

+ (instancetype)decimalNumberHandlerWithRoundingMode:(NSRoundingMode)roundingMode scale:(short)scale raiseOnExactness:(BOOL)exact
    raiseOnOverflow:(BOOL)overflow raiseOnUnderflow:(BOOL)underflow raiseOnDivideByZero:(BOOL)divideByZero
{
    return [[[self alloc] initWithRoundingMode:roundingMode scale:scale raiseOnExactness:exact raiseOnOverflow:overflow
        raiseOnUnderflow:underflow raiseOnDivideByZero:divideByZero] autorelease];
}

- (NSRoundingMode)roundingMode { return _roundingMode; }
- (short)scale { return (short)_scale; }

- (NSDecimalNumber *)exceptionDuringOperation:(SEL)operation error:(NSCalculationError)error
    leftOperand:(NSDecimalNumber *)leftOperand rightOperand:(NSDecimalNumber *)rightOperand
{
    switch (error) {
    case NSCalculationLossOfPrecision:
        if (_raiseOnExactness) FinchRaise(NSDecimalNumberExactnessException, "NSDecimalNumber exactness exception");
        break;
    case NSCalculationOverflow:
        if (_raiseOnOverflow) FinchRaise(NSDecimalNumberOverflowException, "NSDecimalNumber overflow exception");
        break;
    case NSCalculationUnderflow:
        if (_raiseOnUnderflow) FinchRaise(NSDecimalNumberUnderflowException, "NSDecimalNumber underflow exception");
        break;
    case NSCalculationDivideByZero:
        if (_raiseOnDivideByZero) FinchRaise(NSDecimalNumberDivideByZeroException, "NSDecimalNumber divide by zero exception");
        break;
    default:
        break;
    }
    return nil;
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)coder { }

@end

/* MARK: - NSDecimalNumber */

@implementation NSDecimalNumber

static id<NSDecimalNumberBehaviors> default_behavior;

/* The mantissa words follow the object. */
+ (instancetype)allocWithZone:(NSZone *)zone
{
    return NSAllocateObject(self, NSDecimalMaxSize * sizeof(unsigned short), zone);
}

+ (id<NSDecimalNumberBehaviors>)defaultBehavior
{
    return default_behavior ? default_behavior : [NSDecimalNumberHandler defaultDecimalNumberHandler];
}

+ (void)setDefaultBehavior:(id<NSDecimalNumberBehaviors>)behavior
{
    id old = default_behavior;
    default_behavior = [(id)behavior retain];
    [old release];
}

- (instancetype)initWithDecimal:(NSDecimal)dcm
{
    if ((self = [super init])) {
        NSDecimalCompact(&dcm);
        _exponent = dcm._exponent;
        _length = dcm._length;
        _isNegative = dcm._isNegative;
        _isCompact = 1;
        memcpy(_mantissa, dcm._mantissa, sizeof(dcm._mantissa));
    }
    return self;
}

- (instancetype)initWithMantissa:(unsigned long long)mantissa exponent:(short)exponent isNegative:(BOOL)flag
{
    Value v;
    memset(&v, 0, sizeof(v));
    big_set128(&v.m, mantissa);
    v.exp = exponent;
    v.neg = flag && mantissa;
    NSDecimal d;
    to_decimal(&d, v, NSRoundPlain);
    return [self initWithDecimal:d];
}

- (instancetype)initWithString:(NSString *)numberValue { return [self initWithString:numberValue locale:nil]; }

- (instancetype)initWithString:(NSString *)numberValue locale:(id)locale
{
    NSDecimal d;
    NSUInteger start = 0, len = [numberValue length];
    while (start < len && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[numberValue characterAtIndex:start]]) start++;
    if (!numberValue || FinchScanDecimal(numberValue, start, separator(locale), &d) == NSNotFound) set_nan(&d);
    return [self initWithDecimal:d];
}

/* NSNumber's initializers, through the value's decimal form. */
#define INIT(NAME, FACTORY, TYPE) \
    - (NSNumber *)NAME:(TYPE)value { return [self initWithDecimal:[[NSNumber FACTORY:value] decimalValue]]; }
INIT(initWithChar, numberWithChar, char)
INIT(initWithUnsignedChar, numberWithUnsignedChar, unsigned char)
INIT(initWithShort, numberWithShort, short)
INIT(initWithUnsignedShort, numberWithUnsignedShort, unsigned short)
INIT(initWithInt, numberWithInt, int)
INIT(initWithUnsignedInt, numberWithUnsignedInt, unsigned int)
INIT(initWithLong, numberWithLong, long)
INIT(initWithUnsignedLong, numberWithUnsignedLong, unsigned long)
INIT(initWithLongLong, numberWithLongLong, long long)
INIT(initWithUnsignedLongLong, numberWithUnsignedLongLong, unsigned long long)
INIT(initWithFloat, numberWithFloat, float)
INIT(initWithDouble, numberWithDouble, double)
INIT(initWithBool, numberWithBool, BOOL)
INIT(initWithInteger, numberWithInteger, NSInteger)
INIT(initWithUnsignedInteger, numberWithUnsignedInteger, NSUInteger)
#undef INIT

+ (NSDecimalNumber *)decimalNumberWithMantissa:(unsigned long long)mantissa exponent:(short)exponent isNegative:(BOOL)flag
{
    return [[[self alloc] initWithMantissa:mantissa exponent:exponent isNegative:flag] autorelease];
}
+ (NSDecimalNumber *)decimalNumberWithDecimal:(NSDecimal)dcm { return [[[self alloc] initWithDecimal:dcm] autorelease]; }
+ (NSDecimalNumber *)decimalNumberWithString:(NSString *)numberValue { return [[[self alloc] initWithString:numberValue] autorelease]; }
+ (NSDecimalNumber *)decimalNumberWithString:(NSString *)numberValue locale:(id)locale
{
    return [[[self alloc] initWithString:numberValue locale:locale] autorelease];
}

#define CONSTANT(NAME, ...) \
    + (NSDecimalNumber *)NAME \
    { \
        static NSDecimalNumber *n; \
        static dispatch_once_t once; \
        dispatch_once(&once, ^{ __VA_ARGS__ }); \
        return n; \
    }
CONSTANT(zero, n = [[NSDecimalNumber alloc] initWithMantissa:0 exponent:0 isNegative:NO];)
CONSTANT(one, n = [[NSDecimalNumber alloc] initWithMantissa:1 exponent:0 isNegative:NO];)
CONSTANT(notANumber, NSDecimal d; set_nan(&d); n = [[NSDecimalNumber alloc] initWithDecimal:d];)
CONSTANT(maximumDecimalNumber,
    NSDecimal d; memset(&d, 0, sizeof(d)); d._length = 8; d._exponent = 127; d._isCompact = 1;
    for (int i = 0; i < 8; i++) d._mantissa[i] = 0xffff;
    n = [[NSDecimalNumber alloc] initWithDecimal:d];)
CONSTANT(minimumDecimalNumber,
    NSDecimal d; memset(&d, 0, sizeof(d)); d._length = 8; d._exponent = 127; d._isNegative = 1; d._isCompact = 1;
    for (int i = 0; i < 8; i++) d._mantissa[i] = 0xffff;
    n = [[NSDecimalNumber alloc] initWithDecimal:d];)

- (NSDecimal)decimalValue
{
    NSDecimal d;
    memset(&d, 0, sizeof(d));
    d._exponent = _exponent;
    d._length = _length;
    d._isNegative = _isNegative;
    d._isCompact = _isCompact;
    memcpy(d._mantissa, _mantissa, sizeof(d._mantissa));
    return d;
}

- (NSString *)descriptionWithLocale:(id)locale
{
    NSDecimal d = [self decimalValue];
    return NSDecimalString(&d, locale);
}
- (NSString *)description { return [self descriptionWithLocale:nil]; }
- (NSString *)stringValue { return [self descriptionWithLocale:nil]; }

- (const char *)objCType { return "d"; }

- (double)doubleValue
{
    NSDecimal d = [self decimalValue];
    if (NSDecimalIsNotANumber(&d)) return NAN;
    return strtod([NSDecimalString(&d, nil) UTF8String], NULL);
}

- (void)getValue:(void *)value
{
    double d = [self doubleValue];
    memcpy(value, &d, sizeof(d));
}
- (void)getValue:(void *)value size:(NSUInteger)size
{
    double d = [self doubleValue];
    memcpy(value, &d, MIN(size, sizeof(d)));
}

- (NSComparisonResult)compare:(NSNumber *)other
{
    NSDecimal a = [self decimalValue], b = [other decimalValue];
    return NSDecimalCompare(&a, &b);
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

/* Apple archives NSDecimalNumber under NSDecimalNumberPlaceholder. */
+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForCoder { return objc_getClass("NSDecimalNumberPlaceholder"); }

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSDecimal d = [self decimalValue];
    [coder encodeInt:d._exponent forKey:@"NS.exponent"];
    [coder encodeInt:(int)d._length forKey:@"NS.length"];
    [coder encodeBool:d._isNegative forKey:@"NS.negative"];
    [coder encodeBool:d._isCompact forKey:@"NS.compact"];
    [coder encodeInt:1 forKey:@"NS.mantissa.bo"];
    uint8_t bytes[16];
    for (int i = 0; i < 8; i++) { bytes[2 * i] = (uint8_t)d._mantissa[i]; bytes[2 * i + 1] = (uint8_t)(d._mantissa[i] >> 8); }
    [coder encodeBytes:bytes length:sizeof(bytes) forKey:@"NS.mantissa"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSDecimal d;
    memset(&d, 0, sizeof(d));
    d._exponent = [coder decodeIntForKey:@"NS.exponent"];
    d._length = (unsigned)[coder decodeIntForKey:@"NS.length"] & 0xF;
    d._isNegative = [coder decodeBoolForKey:@"NS.negative"];
    d._isCompact = [coder decodeBoolForKey:@"NS.compact"];
    BOOL big = [coder containsValueForKey:@"NS.mantissa.bo"] && [coder decodeIntForKey:@"NS.mantissa.bo"] != 1;
    NSUInteger n = 0;
    const uint8_t *b = [coder decodeBytesForKey:@"NS.mantissa" returnedLength:&n];
    for (NSUInteger i = 0; i < 8 && 2 * i + 1 < n; i++)
        d._mantissa[i] = big ? (unsigned short)(b[2 * i] << 8 | b[2 * i + 1]) : (unsigned short)(b[2 * i] | b[2 * i + 1] << 8);
    if (d._length > 8) d._length = 8;
    return [self initWithDecimal:d];
}

typedef NSCalculationError (*BinaryOp)(NSDecimal *, const NSDecimal *, const NSDecimal *, NSRoundingMode);

/* An operation's result under a behavior: its errors to the behavior,
 * then rounded to its scale. */
static NSDecimalNumber *
finish(NSDecimal r, NSCalculationError err, SEL op, NSDecimalNumber *l, NSDecimalNumber *rhs, id<NSDecimalNumberBehaviors> b)
{
    if (!b) b = [NSDecimalNumber defaultBehavior];
    if (err != NSCalculationNoError) {
        NSDecimalNumber *alt = [b exceptionDuringOperation:op error:err leftOperand:l rightOperand:rhs];
        if (alt) return alt;
        if (err == NSCalculationOverflow || err == NSCalculationDivideByZero) return [NSDecimalNumber notANumber];
        if (err == NSCalculationUnderflow) return [NSDecimalNumber zero];
    }
    short scale = [b scale];
    if (scale != NSDecimalNoScale) NSDecimalRound(&r, &r, scale, [b roundingMode]);
    return [NSDecimalNumber decimalNumberWithDecimal:r];
}

static NSDecimalNumber *
binary(NSDecimalNumber *self, SEL _cmd, NSDecimalNumber *other, id<NSDecimalNumberBehaviors> behavior, BinaryOp op)
{
    id<NSDecimalNumberBehaviors> b = behavior ? behavior : [NSDecimalNumber defaultBehavior];
    NSDecimal l = [self decimalValue], r = [other decimalValue], result;
    NSCalculationError err = op(&result, &l, &r, [b roundingMode]);
    return finish(result, err, _cmd, self, other, b);
}

- (NSDecimalNumber *)decimalNumberByAdding:(NSDecimalNumber *)n { return [self decimalNumberByAdding:n withBehavior:nil]; }
- (NSDecimalNumber *)decimalNumberByAdding:(NSDecimalNumber *)n withBehavior:(id<NSDecimalNumberBehaviors>)b
{
    return binary(self, _cmd, n, b, NSDecimalAdd);
}
- (NSDecimalNumber *)decimalNumberBySubtracting:(NSDecimalNumber *)n { return [self decimalNumberBySubtracting:n withBehavior:nil]; }
- (NSDecimalNumber *)decimalNumberBySubtracting:(NSDecimalNumber *)n withBehavior:(id<NSDecimalNumberBehaviors>)b
{
    return binary(self, _cmd, n, b, NSDecimalSubtract);
}
- (NSDecimalNumber *)decimalNumberByMultiplyingBy:(NSDecimalNumber *)n { return [self decimalNumberByMultiplyingBy:n withBehavior:nil]; }
- (NSDecimalNumber *)decimalNumberByMultiplyingBy:(NSDecimalNumber *)n withBehavior:(id<NSDecimalNumberBehaviors>)b
{
    return binary(self, _cmd, n, b, NSDecimalMultiply);
}
- (NSDecimalNumber *)decimalNumberByDividingBy:(NSDecimalNumber *)n { return [self decimalNumberByDividingBy:n withBehavior:nil]; }
- (NSDecimalNumber *)decimalNumberByDividingBy:(NSDecimalNumber *)n withBehavior:(id<NSDecimalNumberBehaviors>)b
{
    return binary(self, _cmd, n, b, NSDecimalDivide);
}

- (NSDecimalNumber *)decimalNumberByRaisingToPower:(NSUInteger)power { return [self decimalNumberByRaisingToPower:power withBehavior:nil]; }
- (NSDecimalNumber *)decimalNumberByRaisingToPower:(NSUInteger)power withBehavior:(id<NSDecimalNumberBehaviors>)behavior
{
    id<NSDecimalNumberBehaviors> b = behavior ? behavior : [NSDecimalNumber defaultBehavior];
    NSDecimal d = [self decimalValue], r;
    NSCalculationError err = NSDecimalPower(&r, &d, power, [b roundingMode]);
    return finish(r, err, _cmd, self, nil, b);
}

- (NSDecimalNumber *)decimalNumberByMultiplyingByPowerOf10:(short)power { return [self decimalNumberByMultiplyingByPowerOf10:power withBehavior:nil]; }
- (NSDecimalNumber *)decimalNumberByMultiplyingByPowerOf10:(short)power withBehavior:(id<NSDecimalNumberBehaviors>)behavior
{
    id<NSDecimalNumberBehaviors> b = behavior ? behavior : [NSDecimalNumber defaultBehavior];
    NSDecimal d = [self decimalValue], r;
    NSCalculationError err = NSDecimalMultiplyByPowerOf10(&r, &d, power, [b roundingMode]);
    return finish(r, err, _cmd, self, nil, b);
}

- (NSDecimalNumber *)decimalNumberByRoundingAccordingToBehavior:(id<NSDecimalNumberBehaviors>)behavior
{
    id<NSDecimalNumberBehaviors> b = behavior ? behavior : [NSDecimalNumber defaultBehavior];
    NSDecimal d = [self decimalValue], r;
    NSDecimalRound(&r, &d, [b scale], [b roundingMode]);
    return [NSDecimalNumber decimalNumberWithDecimal:r];
}

@end

/* The name Apple's archives give NSDecimalNumber; decoding it gives an
 * NSDecimalNumber. */
@interface NSDecimalNumberPlaceholder : NSDecimalNumber
@end
@implementation NSDecimalNumberPlaceholder
+ (Class)classForKeyedUnarchiver { return [NSDecimalNumber class]; }
@end

/* MARK: - NSNumber's decimal value */

@implementation NSNumber (NSDecimalNumberExtensions)

/* Integers exactly; floating-point values by their shortest round-trip
 * form (0.1 is 0.1, as Apple's is). */
- (NSDecimal)decimalValue
{
    NSDecimal d;
    const char *t = [self objCType];
    if (*t == 'f' || *t == 'd') {
        double v = [self doubleValue];
        if (isnan(v) || isinf(v)) { set_nan(&d); return d; }
        char buf[40];
        for (int prec = *t == 'f' ? 7 : 15; prec <= 17; prec++) {
            snprintf(buf, sizeof(buf), "%.*g", prec, v);
            if (*t == 'f' ? (float)strtod(buf, NULL) == (float)v : strtod(buf, NULL) == v) break;
        }
        FinchScanDecimal([NSString stringWithUTF8String:buf], 0, @".", &d);
        return d;
    }
    Value v;
    memset(&v, 0, sizeof(v));
    if (strchr("CSILQ", *t)) {
        big_set128(&v.m, [self unsignedLongLongValue]);
    } else {
        long long s = [self longLongValue];
        v.neg = s < 0;
        big_set128(&v.m, s < 0 ? (unsigned long long)0 - (unsigned long long)s : (unsigned long long)s);
    }
    to_decimal(&d, v, NSRoundPlain);
    return d;
}

@end
