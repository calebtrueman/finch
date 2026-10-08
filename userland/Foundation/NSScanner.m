/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSScanner (docs/design/FOUNDATION.md), against the SDK's
 * <Foundation/NSScanner.h>. NSScanner is the abstract class (string,
 * location, skipped characters, case sensitivity, locale); NSConcreteScanner
 * is what +alloc gives, as Apple's. The scanning methods work through those
 * primitives, so subclasses get them too.
 *
 * As Apple's: each scan first skips charactersToBeSkipped; a failed scan
 * leaves the location where it was; integers that overflow scan as the
 * type's limit with every digit consumed; hex scans take an optional 0x.
 */
#import <Foundation/Foundation.h>
#include <math.h>

#include "Foundation_Finch.h"

@interface NSConcreteScanner : NSScanner {
    NSString *_string;
    NSUInteger _location;
    NSCharacterSet *_skip;
    BOOL _caseSensitive;
    id _locale;
}
@end

@implementation NSScanner

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSScanner class]) return [NSConcreteScanner allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (instancetype)scannerWithString:(NSString *)string { return [[[self alloc] initWithString:string] autorelease]; }

+ (id)localizedScannerWithString:(NSString *)string
{
    NSScanner *s = [self scannerWithString:string];
    [s setLocale:[NSLocale currentLocale]];
    return s;
}

- (instancetype)initWithString:(NSString *)string { FinchAbstract(self, _cmd); }
- (NSString *)string { FinchAbstract(self, _cmd); }
- (NSUInteger)scanLocation { FinchAbstract(self, _cmd); }
- (void)setScanLocation:(NSUInteger)location { FinchAbstract(self, _cmd); }
- (NSCharacterSet *)charactersToBeSkipped { FinchAbstract(self, _cmd); }
- (void)setCharactersToBeSkipped:(NSCharacterSet *)set { FinchAbstract(self, _cmd); }
- (BOOL)caseSensitive { FinchAbstract(self, _cmd); }
- (void)setCaseSensitive:(BOOL)flag { FinchAbstract(self, _cmd); }
- (id)locale { FinchAbstract(self, _cmd); }
- (void)setLocale:(id)locale { FinchAbstract(self, _cmd); }

- (id)copyWithZone:(NSZone *)zone
{
    NSScanner *s = [[NSScanner allocWithZone:zone] initWithString:[self string]];
    [s setScanLocation:[self scanLocation]];
    [s setCharactersToBeSkipped:[self charactersToBeSkipped]];
    [s setCaseSensitive:[self caseSensitive]];
    [s setLocale:[self locale]];
    return s;
}

@end

@implementation NSConcreteScanner

- (instancetype)initWithString:(NSString *)string
{
    if ((self = [super init])) {
        _string = [string copy];
        _skip = [[NSCharacterSet whitespaceAndNewlineCharacterSet] retain];
    }
    return self;
}

- (NSString *)string { return _string; }
- (NSUInteger)scanLocation { return _location; }
- (void)setScanLocation:(NSUInteger)location
{
    if (location > [_string length])
        FinchRaise(NSRangeException, "*** -[NSConcreteScanner setScanLocation:]: Range or index out of bounds");
    _location = location;
}
- (NSCharacterSet *)charactersToBeSkipped { return _skip; }
- (void)setCharactersToBeSkipped:(NSCharacterSet *)set
{
    if (set == _skip) return;
    [_skip release];
    _skip = [set copy];
}
- (BOOL)caseSensitive { return _caseSensitive; }
- (void)setCaseSensitive:(BOOL)flag { _caseSensitive = flag; }
- (id)locale { return _locale; }
- (void)setLocale:(id)locale
{
    if (locale == _locale) return;
    [_locale release];
    _locale = [locale retain];
}

- (void)dealloc
{
    [_string release];
    [_skip release];
    [_locale release];
    [super dealloc];
}

@end

/* MARK: - Scanning */

/* Skip charactersToBeSkipped from the scan location: the index after. */
static NSUInteger
skipped(NSScanner *self)
{
    NSString *s = [self string];
    NSUInteger i = [self scanLocation], len = [s length];
    NSCharacterSet *skip = [self charactersToBeSkipped];
    if (skip)
        while (i < len && [skip characterIsMember:[s characterAtIndex:i]]) i++;
    return i;
}

static NSString *
decimal_separator(NSScanner *self)
{
    id locale = [self locale], sep = nil;
    if ([locale isKindOfClass:[NSLocale class]]) sep = [locale objectForKey:NSLocaleDecimalSeparator];
    else if ([locale isKindOfClass:[NSDictionary class]]) sep = [locale objectForKey:NSDecimalSeparator];
    return [sep isKindOfClass:[NSString class]] && [sep length] ? sep : @".";
}

static BOOL
is_digit(unichar c)
{
    return c >= '0' && c <= '9';
}

static int
hex_value(unichar c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* [+-]digits, clamped to [min, max]. */
static BOOL
scan_integer(NSScanner *self, long long min, long long max, long long *out)
{
    NSString *s = [self string];
    NSUInteger i = skipped(self), len = [s length];
    BOOL neg = NO;
    if (i < len && ([s characterAtIndex:i] == '-' || [s characterAtIndex:i] == '+')) neg = [s characterAtIndex:i++] == '-';
    if (i >= len || !is_digit([s characterAtIndex:i])) return NO;
    unsigned long long v = 0;
    BOOL over = NO;
    for (; i < len && is_digit([s characterAtIndex:i]); i++) {
        unsigned d = [s characterAtIndex:i] - '0';
        if (v > (ULLONG_MAX - d) / 10) over = YES;
        else v = v * 10 + d;
    }
    long long r;
    if (neg) {
        unsigned long long limit = (unsigned long long)(-(min + 1)) + 1;
        r = over || v >= limit ? min : -(long long)v;
    } else {
        r = over || v > (unsigned long long)max ? max : (long long)v;
    }
    [self setScanLocation:i];
    if (out) *out = r;
    return YES;
}

static BOOL
scan_unsigned(NSScanner *self, unsigned long long *out)
{
    NSString *s = [self string];
    NSUInteger i = skipped(self), len = [s length];
    if (i < len && [s characterAtIndex:i] == '+') i++;
    if (i >= len || !is_digit([s characterAtIndex:i])) return NO;
    unsigned long long v = 0;
    BOOL over = NO;
    for (; i < len && is_digit([s characterAtIndex:i]); i++) {
        unsigned d = [s characterAtIndex:i] - '0';
        if (v > (ULLONG_MAX - d) / 10) over = YES;
        else v = v * 10 + d;
    }
    [self setScanLocation:i];
    if (out) *out = over ? ULLONG_MAX : v;
    return YES;
}

static BOOL
scan_hex(NSScanner *self, unsigned long long max, unsigned long long *out)
{
    NSString *s = [self string];
    NSUInteger i = skipped(self), len = [s length];
    if (i + 1 < len && [s characterAtIndex:i] == '0' && ([s characterAtIndex:i + 1] == 'x' || [s characterAtIndex:i + 1] == 'X') &&
        i + 2 < len && hex_value([s characterAtIndex:i + 2]) >= 0)
        i += 2;
    if (i >= len || hex_value([s characterAtIndex:i]) < 0) return NO;
    unsigned long long v = 0;
    BOOL over = NO;
    for (int d; i < len && (d = hex_value([s characterAtIndex:i])) >= 0; i++) {
        if (v > (max - (unsigned)d) / 16) over = YES;
        else v = v * 16 + (unsigned)d;
    }
    [self setScanLocation:i];
    if (out) *out = over ? max : v;
    return YES;
}

/* [+-]digits[sep digits][e[+-]digits], or with hex, C's hex float form. */
static BOOL
scan_double(NSScanner *self, BOOL hex, double *out)
{
    NSString *s = [self string];
    NSUInteger i = skipped(self), len = [s length];
    unichar sep = [decimal_separator(self) characterAtIndex:0];
    NSMutableData *buf = [NSMutableData data];
    char c;
    if (i < len && ([s characterAtIndex:i] == '-' || [s characterAtIndex:i] == '+')) {
        c = (char)[s characterAtIndex:i++];
        [buf appendBytes:&c length:1];
    }
    if (hex) {
        if (!(i + 1 < len && [s characterAtIndex:i] == '0' && ([s characterAtIndex:i + 1] == 'x' || [s characterAtIndex:i + 1] == 'X')))
            return NO;
        [buf appendBytes:"0x" length:2];
        i += 2;
    }
    BOOL digits = NO, dot = NO;
    for (; i < len; i++) {
        unichar u = [s characterAtIndex:i];
        if (hex ? hex_value(u) >= 0 : is_digit(u)) { digits = YES; c = (char)u; [buf appendBytes:&c length:1]; continue; }
        if (u == sep && !dot) { dot = YES; [buf appendBytes:"." length:1]; continue; }
        break;
    }
    if (!digits) return NO;
    unichar e1 = hex ? 'p' : 'e', e2 = hex ? 'P' : 'E';
    if (i < len && ([s characterAtIndex:i] == e1 || [s characterAtIndex:i] == e2)) {
        NSUInteger j = i + 1;
        if (j < len && ([s characterAtIndex:j] == '-' || [s characterAtIndex:j] == '+')) j++;
        if (j < len && is_digit([s characterAtIndex:j])) {
            for (NSUInteger k = i; k < j; k++) { c = (char)[s characterAtIndex:k]; [buf appendBytes:&c length:1]; }
            for (; j < len && is_digit([s characterAtIndex:j]); j++) { c = (char)[s characterAtIndex:j]; [buf appendBytes:&c length:1]; }
            i = j;
        }
    }
    [buf appendBytes:"" length:1];
    [self setScanLocation:i];
    if (out) *out = strtod([buf bytes], NULL);
    return YES;
}

@implementation NSScanner (NSExtendedScanner)

- (BOOL)scanInt:(int *)result
{
    long long v;
    if (!scan_integer(self, INT_MIN, INT_MAX, &v)) return NO;
    if (result) *result = (int)v;
    return YES;
}

- (BOOL)scanInteger:(NSInteger *)result
{
    long long v;
    if (!scan_integer(self, NSIntegerMin, NSIntegerMax, &v)) return NO;
    if (result) *result = (NSInteger)v;
    return YES;
}

- (BOOL)scanLongLong:(long long *)result { return scan_integer(self, LLONG_MIN, LLONG_MAX, result); }
- (BOOL)scanUnsignedLongLong:(unsigned long long *)result { return scan_unsigned(self, result); }

- (BOOL)scanHexInt:(unsigned *)result
{
    unsigned long long v;
    if (!scan_hex(self, UINT_MAX, &v)) return NO;
    if (result) *result = (unsigned)v;
    return YES;
}

- (BOOL)scanHexLongLong:(unsigned long long *)result { return scan_hex(self, ULLONG_MAX, result); }

- (BOOL)scanFloat:(float *)result
{
    double d;
    if (!scan_double(self, NO, &d)) return NO;
    if (result) *result = (float)d;
    return YES;
}

- (BOOL)scanDouble:(double *)result { return scan_double(self, NO, result); }

- (BOOL)scanHexFloat:(float *)result
{
    double d;
    if (!scan_double(self, YES, &d)) return NO;
    if (result) *result = (float)d;
    return YES;
}

- (BOOL)scanHexDouble:(double *)result { return scan_double(self, YES, result); }

- (BOOL)scanString:(NSString *)string intoString:(NSString **)result
{
    NSString *s = [self string];
    NSUInteger i = skipped(self), n = [string length];
    if (!n || i + n > [s length]) return NO;
    NSStringCompareOptions opts = [self caseSensitive] ? NSLiteralSearch : NSCaseInsensitiveSearch;
    if ([s compare:string options:opts range:NSMakeRange(i, n)] != NSOrderedSame) return NO;
    if (result) *result = [s substringWithRange:NSMakeRange(i, n)];
    [self setScanLocation:i + n];
    return YES;
}

- (BOOL)scanCharactersFromSet:(NSCharacterSet *)set intoString:(NSString **)result
{
    NSString *s = [self string];
    NSUInteger start = skipped(self), i = start, len = [s length];
    while (i < len && [set characterIsMember:[s characterAtIndex:i]]) i++;
    if (i == start) return NO;
    if (result) *result = [s substringWithRange:NSMakeRange(start, i - start)];
    [self setScanLocation:i];
    return YES;
}

- (BOOL)scanUpToString:(NSString *)string intoString:(NSString **)result
{
    NSString *s = [self string];
    NSUInteger start = skipped(self), len = [s length];
    if (start >= len) return NO;
    NSStringCompareOptions opts = [self caseSensitive] ? NSLiteralSearch : NSCaseInsensitiveSearch;
    NSRange found = [s rangeOfString:string options:opts range:NSMakeRange(start, len - start)];
    NSUInteger end = found.location == NSNotFound ? len : found.location;
    if (end == start) return NO;
    if (result) *result = [s substringWithRange:NSMakeRange(start, end - start)];
    [self setScanLocation:end];
    return YES;
}

- (BOOL)scanUpToCharactersFromSet:(NSCharacterSet *)set intoString:(NSString **)result
{
    NSString *s = [self string];
    NSUInteger start = skipped(self), i = start, len = [s length];
    while (i < len && ![set characterIsMember:[s characterAtIndex:i]]) i++;
    if (i == start) return NO;
    if (result) *result = [s substringWithRange:NSMakeRange(start, i - start)];
    [self setScanLocation:i];
    return YES;
}

- (BOOL)isAtEnd { return skipped(self) >= [[self string] length]; }

@end

@implementation NSScanner (NSDecimalNumberScanning)

- (BOOL)scanDecimal:(NSDecimal *)dcm
{
    NSString *s = [self string];
    NSUInteger end = FinchScanDecimal(s, skipped(self), decimal_separator(self), dcm);
    if (end == NSNotFound) return NO;
    [self setScanLocation:end];
    return YES;
}

@end
