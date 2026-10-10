/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSString and NSMutableString (docs/design/FOUNDATION.md), implemented
 * against the SDK's declarations, so each method has Apple's signature.
 *
 * As in Apple's Foundation, the concrete strings are CFStrings: +alloc
 * returns NSPlaceholderString, whose -init... make CFStrings, whose class is
 * CoreFoundation's __NSCFString (a subclass of NSMutableString). The
 * abstract classes here serve subclasses that apps write: NSString's
 * primitives are -length and -characterAtIndex: (and -getCharacters:range:),
 * NSMutableString's is -replaceCharactersInRange:withString:.
 *
 * Most methods call CF on self: CF reads an ObjC string through the
 * primitives (CF_OBJC_FUNCDISPATCHV, with -getCharacters:range: behind its
 * inline buffers). The few messages CF itself sends to ObjC strings (-copy,
 * -mutableCopy, -_getCString:..., the -_cf... mutators) are implemented
 * here from the primitives, never by calling the CF function that sends
 * them, which would recurse.
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <sys/stat.h>

#include "Foundation_Finch.h"

CF_EXPORT Boolean __CFStringIsMutable(CFStringRef str);
CF_EXPORT CFHashCode CFStringHashCharacters(const UniChar *characters, CFIndex length);   /* CF SPI */

@interface NSPlaceholderString : NSString
@end
@interface NSPlaceholderMutableString : NSMutableString
@end

static NSPlaceholderString *placeholder;
static NSPlaceholderMutableString *mutablePlaceholder;


/* NSLocale is CoreFoundation's class; until Finch's CF hosts it, the
 * current locale is reached through CFLocale (they're toll-free bridged). */
static id
current_locale(void)
{
    return [(id)CFLocaleCopyCurrent() autorelease];
}

static CFStringEncoding
cf_encoding(NSStringEncoding enc)
{
    CFStringEncoding e = CFStringConvertNSStringEncodingToEncoding(enc);
    return e == kCFStringEncodingInvalidId ? kCFStringEncodingUTF8 : e;
}

/* A CFString with self's characters, for abstract subclasses (+1). */
static CFStringRef
cf_copy_of(NSString *s)
{
    NSUInteger n = [s length];
    unichar stackbuf[256], *buf = n <= 256 ? stackbuf : malloc(n * sizeof(unichar));
    [s getCharacters:buf range:NSMakeRange(0, n)];
    CFStringRef r = CFStringCreateWithCharacters(NULL, buf, (CFIndex)n);
    if (buf != stackbuf) free(buf);
    return r;
}

/* MARK: - NSString */

@implementation NSString

+ (void)initialize
{
    if (self == [NSString class]) {
        placeholder = class_createInstance([NSPlaceholderString class], 0);
        mutablePlaceholder = class_createInstance([NSPlaceholderMutableString class], 0);
    }
}

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSString class]) return (id)placeholder;
    if (self == [NSMutableString class]) return (id)mutablePlaceholder;
    return [super allocWithZone:zone];
}

- (NSUInteger)length
{
    FinchAbstract(self, _cmd);
    return 0;
}

- (unichar)characterAtIndex:(NSUInteger)index
{
    FinchAbstract(self, _cmd);
    return 0;
}

- (instancetype)init { return [super init]; }

+ (BOOL)supportsSecureCoding { return YES; }

- (id)copyWithZone:(NSZone *)zone { return (id)cf_copy_of(self); }

- (id)mutableCopyWithZone:(NSZone *)zone
{
    CFMutableStringRef m = CFStringCreateMutable(NULL, 0);
    CFStringRef c = cf_copy_of(self);
    CFStringAppend(m, c);
    CFRelease(c);
    return (id)m;
}

- (Class)classForCoder { return [NSString class]; }
- (CFTypeID)_cfTypeID { return CFStringGetTypeID(); }
- (BOOL)isNSString__ { return YES; }

/* What CF sends to strings it didn't make (CFString.c). */
- (const unichar *)_fastCharacterContents { return NULL; }
- (const char *)_fastCStringContents:(BOOL)nullTerminated { return NULL; }
- (CFStringEncoding)_fastestEncodingInCFStringEncoding { return kCFStringEncodingUnicode; }
- (CFStringEncoding)_smallestEncodingInCFStringEncoding
{
    CFStringRef c = cf_copy_of(self);
    CFStringEncoding e = CFStringGetSmallestEncoding(c);
    CFRelease(c);
    return e;
}
/* Whether CF must keep the string's characters as UTF-16 when it copies them into one of
 * its own (a mutable string's append and replace): anything beyond ASCII. */
- (BOOL)_encodingCantBeStoredInEightBitCFString
{
    NSUInteger length = [self length];
    unichar buf[256];
    for (NSUInteger at = 0; at < length; at += 256) {
        NSUInteger n = length - at < 256 ? length - at : 256;
        [self getCharacters:buf range:NSMakeRange(at, n)];
        for (NSUInteger i = 0; i < n; i++)
            if (buf[i] > 0x7f)
                return YES;
    }
    return NO;
}
- (BOOL)_getCString:(char *)buffer maxLength:(NSUInteger)max encoding:(CFStringEncoding)encoding
{
    CFStringRef c = cf_copy_of(self);
    BOOL ok = CFStringGetCString(c, buffer, (CFIndex)max + 1, encoding);
    CFRelease(c);
    return ok;
}
- (id)_createSubstringWithRange:(NSRange)range
{
    unichar stackbuf[256], *buf = range.length <= 256 ? stackbuf : malloc(range.length * sizeof(unichar));
    [self getCharacters:buf range:range];
    CFStringRef r = CFStringCreateWithCharacters(NULL, buf, (CFIndex)range.length);
    if (buf != stackbuf) free(buf);
    return (id)r;
}

@end

@implementation NSString (NSStringExtensionMethods)

+ (instancetype)string { return [[[self alloc] init] autorelease]; }
+ (instancetype)stringWithString:(NSString *)string { return [[[self alloc] initWithString:string] autorelease]; }
+ (instancetype)stringWithCharacters:(const unichar *)characters length:(NSUInteger)length
{
    return [[[self alloc] initWithCharacters:characters length:length] autorelease];
}
+ (instancetype)stringWithUTF8String:(const char *)nullTerminatedCString
{
    return [[[self alloc] initWithUTF8String:nullTerminatedCString] autorelease];
}
+ (instancetype)stringWithCString:(const char *)cString encoding:(NSStringEncoding)enc
{
    return [[[self alloc] initWithCString:cString encoding:enc] autorelease];
}
+ (instancetype)stringWithFormat:(NSString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    id s = [[[self alloc] initWithFormat:format arguments:ap] autorelease];
    va_end(ap);
    return s;
}
+ (instancetype)localizedStringWithFormat:(NSString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    id s = [[[self alloc] initWithFormat:format locale:current_locale() arguments:ap] autorelease];
    va_end(ap);
    return s;
}
+ (instancetype)stringWithContentsOfFile:(NSString *)path encoding:(NSStringEncoding)enc error:(NSError **)error
{
    return [[[self alloc] initWithContentsOfFile:path encoding:enc error:error] autorelease];
}

/* Abstract-class initializers (for subclasses): build a CFString and let
 * the subclass's -initWithString: take it, or just -init. */
- (instancetype)initWithCharactersNoCopy:(unichar *)characters length:(NSUInteger)length freeWhenDone:(BOOL)freeBuffer
{
    id r = [self initWithCharacters:characters length:length];
    if (freeBuffer) free(characters);
    return r;
}
- (instancetype)initWithCharacters:(const unichar *)characters length:(NSUInteger)length
{
    CFStringRef s = CFStringCreateWithCharacters(NULL, characters, (CFIndex)length);
    id r = [self initWithString:(NSString *)s];
    CFRelease(s);
    return r;
}
- (instancetype)initWithUTF8String:(const char *)nullTerminatedCString
{
    return [self initWithCString:nullTerminatedCString encoding:NSUTF8StringEncoding];
}
- (instancetype)initWithCString:(const char *)cString encoding:(NSStringEncoding)enc
{
    if (!cString) {
        [self release];
        FinchRaise(NSInvalidArgumentException, "*** %s: NULL cString", sel_getName(_cmd));
    }
    CFStringRef s = CFStringCreateWithCString(NULL, cString, cf_encoding(enc));
    if (!s) { [self release]; return nil; }
    id r = [self initWithString:(NSString *)s];
    CFRelease(s);
    return r;
}
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)len encoding:(NSStringEncoding)enc
{
    CFStringRef s = CFStringCreateWithBytes(NULL, bytes, (CFIndex)len, cf_encoding(enc), false);
    if (!s) { [self release]; return nil; }
    id r = [self initWithString:(NSString *)s];
    CFRelease(s);
    return r;
}
- (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)len encoding:(NSStringEncoding)enc
                       freeWhenDone:(BOOL)freeBuffer
{
    id r = [self initWithBytes:bytes length:len encoding:enc];
    if (freeBuffer) free(bytes);
    return r;
}
- (instancetype)initWithData:(NSData *)data encoding:(NSStringEncoding)encoding
{
    return [self initWithBytes:[data bytes] length:[data length] encoding:encoding];
}
- (instancetype)initWithString:(NSString *)aString { return [self init]; }
- (instancetype)initWithFormat:(NSString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    id r = [self initWithFormat:format arguments:ap];
    va_end(ap);
    return r;
}
- (instancetype)initWithFormat:(NSString *)format arguments:(va_list)argList
{
    return [self initWithFormat:format locale:nil arguments:argList];
}
- (instancetype)initWithFormat:(NSString *)format locale:(id)locale arguments:(va_list)argList
{
    if (!format) {
        [self release];
        FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: nil argument", object_getClassName(self), sel_getName(_cmd));
    }
    CFStringRef s = FinchCreateWithFormat(FinchFormatOptions(locale), (CFStringRef)format, argList);
    id r = [self initWithString:(NSString *)s];
    CFRelease(s);
    return r;
}
- (instancetype)initWithContentsOfFile:(NSString *)path encoding:(NSStringEncoding)enc error:(NSError **)error
{
    NSData *d = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!d) { [self release]; return nil; }
    return [self initWithData:d encoding:enc];
}

- (void)getCharacters:(unichar *)buffer range:(NSRange)range
{
    for (NSUInteger i = 0; i < range.length; i++) buffer[i] = [self characterAtIndex:range.location + i];
}

- (NSString *)substringFromIndex:(NSUInteger)from { return [self substringWithRange:NSMakeRange(from, [self length] - from)]; }
- (NSString *)substringToIndex:(NSUInteger)to { return [self substringWithRange:NSMakeRange(0, to)]; }
- (NSString *)substringWithRange:(NSRange)range
{
    NSUInteger n = [self length];
    if (range.location > n || range.length > n - range.location)
        FinchRaise(NSRangeException, "-[%s %s]: Range {%lu, %lu} out of bounds; string length %lu", object_getClassName(self),
            sel_getName(_cmd), (unsigned long)range.location, (unsigned long)range.length, (unsigned long)n);
    return [(id)CFStringCreateWithSubstring(NULL, (CFStringRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length)) autorelease];
}

- (NSComparisonResult)compare:(NSString *)string { return [self compare:string options:0 range:NSMakeRange(0, [self length]) locale:nil]; }
- (NSComparisonResult)compare:(NSString *)string options:(NSStringCompareOptions)mask
{
    return [self compare:string options:mask range:NSMakeRange(0, [self length]) locale:nil];
}
- (NSComparisonResult)compare:(NSString *)string options:(NSStringCompareOptions)mask range:(NSRange)range
{
    return [self compare:string options:mask range:range locale:nil];
}
- (NSComparisonResult)compare:(NSString *)string options:(NSStringCompareOptions)mask range:(NSRange)range locale:(id)locale
{
    if (!string) return NSOrderedDescending;
    CFLocaleRef l = locale && CFGetTypeID((CFTypeRef)locale) == CFLocaleGetTypeID() ? (CFLocaleRef)locale
        : (locale ? CFLocaleCopyCurrent() : NULL);
    CFComparisonResult r = CFStringCompareWithOptionsAndLocale((CFStringRef)self, (CFStringRef)string,
        CFRangeMake((CFIndex)range.location, (CFIndex)range.length), (CFStringCompareFlags)mask, l);
    if (l && l != (CFLocaleRef)locale) CFRelease(l);
    return (NSComparisonResult)r;
}
- (NSComparisonResult)caseInsensitiveCompare:(NSString *)string { return [self compare:string options:NSCaseInsensitiveSearch]; }
- (NSComparisonResult)localizedCompare:(NSString *)string
{
    return [self compare:string options:0 range:NSMakeRange(0, [self length]) locale:current_locale()];
}
- (NSComparisonResult)localizedCaseInsensitiveCompare:(NSString *)string
{
    return [self compare:string options:NSCaseInsensitiveSearch range:NSMakeRange(0, [self length]) locale:current_locale()];
}
- (NSComparisonResult)localizedStandardCompare:(NSString *)string
{
    return [self compare:string options:NSCaseInsensitiveSearch | NSNumericSearch | NSWidthInsensitiveSearch | NSForcedOrderingSearch
        range:NSMakeRange(0, [self length]) locale:current_locale()];
}

- (BOOL)isEqualToString:(NSString *)aString
{
    if (aString == self) return YES;
    if (!aString) return NO;
    return CFStringCompare((CFStringRef)self, (CFStringRef)aString, 0) == kCFCompareEqualTo;
}

- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    return object && [object isKindOfClass:[NSString class]] && [self isEqualToString:object];
}

/* The same hash as CF's for equal strings, so mixed keys work. */
- (NSUInteger)hash
{
    NSUInteger n = [self length];
    unichar stackbuf[256], *buf = n <= 256 ? stackbuf : malloc(n * sizeof(unichar));
    [self getCharacters:buf range:NSMakeRange(0, n)];
    CFHashCode h = CFStringHashCharacters(buf, (CFIndex)n);
    if (buf != stackbuf) free(buf);
    return h;
}

- (BOOL)hasPrefix:(NSString *)str { return str && CFStringHasPrefix((CFStringRef)self, (CFStringRef)str); }
- (BOOL)hasSuffix:(NSString *)str { return str && CFStringHasSuffix((CFStringRef)self, (CFStringRef)str); }

- (NSString *)commonPrefixWithString:(NSString *)str options:(NSStringCompareOptions)mask
{
    NSUInteger n = MIN([self length], [str length]), i = 0;
    while (i < n && [[self substringWithRange:NSMakeRange(i, 1)] compare:[str substringWithRange:NSMakeRange(i, 1)] options:mask] == NSOrderedSame) i++;
    return [self substringToIndex:i];
}

- (BOOL)containsString:(NSString *)str { return [self rangeOfString:str].location != NSNotFound; }
- (BOOL)localizedCaseInsensitiveContainsString:(NSString *)str
{
    return [self rangeOfString:str options:NSCaseInsensitiveSearch range:NSMakeRange(0, [self length]) locale:current_locale()].location != NSNotFound;
}

- (NSRange)rangeOfString:(NSString *)searchString { return [self rangeOfString:searchString options:0]; }
- (NSRange)rangeOfString:(NSString *)searchString options:(NSStringCompareOptions)mask
{
    return [self rangeOfString:searchString options:mask range:NSMakeRange(0, [self length]) locale:nil];
}
- (NSRange)rangeOfString:(NSString *)searchString options:(NSStringCompareOptions)mask range:(NSRange)range
{
    return [self rangeOfString:searchString options:mask range:range locale:nil];
}
- (NSRange)rangeOfString:(NSString *)searchString options:(NSStringCompareOptions)mask range:(NSRange)range locale:(NSLocale *)locale
{
    if (!searchString)
        FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: nil argument", object_getClassName(self), sel_getName(_cmd));
    CFRange found;
    if (mask & NSRegularExpressionSearch) return FinchRegexRange(self, searchString, mask, range);
    if ([searchString length] == 0 || [self length] == 0) return NSMakeRange(NSNotFound, 0);
    if (CFStringFindWithOptionsAndLocale((CFStringRef)self, (CFStringRef)searchString,
            CFRangeMake((CFIndex)range.location, (CFIndex)range.length), (CFStringCompareFlags)mask, (CFLocaleRef)locale, &found))
        return NSMakeRange((NSUInteger)found.location, (NSUInteger)found.length);
    return NSMakeRange(NSNotFound, 0);
}

- (NSRange)rangeOfCharacterFromSet:(NSCharacterSet *)searchSet { return [self rangeOfCharacterFromSet:searchSet options:0]; }
- (NSRange)rangeOfCharacterFromSet:(NSCharacterSet *)searchSet options:(NSStringCompareOptions)mask
{
    return [self rangeOfCharacterFromSet:searchSet options:mask range:NSMakeRange(0, [self length])];
}
- (NSRange)rangeOfCharacterFromSet:(NSCharacterSet *)searchSet options:(NSStringCompareOptions)mask range:(NSRange)range
{
    CFRange found;
    if (CFStringFindCharacterFromSet((CFStringRef)self, (CFCharacterSetRef)searchSet,
            CFRangeMake((CFIndex)range.location, (CFIndex)range.length), (CFStringCompareFlags)mask, &found))
        return NSMakeRange((NSUInteger)found.location, (NSUInteger)found.length);
    return NSMakeRange(NSNotFound, 0);
}

- (NSString *)stringByAppendingString:(NSString *)aString
{
    if (!aString)
        FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: nil argument", object_getClassName(self), sel_getName(_cmd));
    CFMutableStringRef m = CFStringCreateMutableCopy(NULL, 0, (CFStringRef)self);
    CFStringAppend(m, (CFStringRef)aString);
    CFStringRef r = CFStringCreateCopy(NULL, m);
    CFRelease(m);
    return [(id)r autorelease];
}

- (NSString *)stringByAppendingFormat:(NSString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    CFStringRef s = FinchCreateWithFormat(NULL, (CFStringRef)format, ap);
    va_end(ap);
    NSString *r = [self stringByAppendingString:(NSString *)s];
    CFRelease(s);
    return r;
}

- (NSString *)stringByPaddingToLength:(NSUInteger)newLength withString:(NSString *)padString startingAtIndex:(NSUInteger)padIndex
{
    CFMutableStringRef m = CFStringCreateMutableCopy(NULL, 0, (CFStringRef)self);
    CFStringPad(m, (CFStringRef)padString, (CFIndex)newLength, (CFIndex)padIndex);
    return [(id)m autorelease];
}

static NSString *
transformed(NSString *self, void (*fn)(CFMutableStringRef, CFLocaleRef), CFLocaleRef locale)
{
    CFMutableStringRef m = CFStringCreateMutableCopy(NULL, 0, (CFStringRef)self);
    fn(m, locale);
    CFStringRef r = CFStringCreateCopy(NULL, m);
    CFRelease(m);
    return [(id)r autorelease];
}

- (NSString *)lowercaseString { return transformed(self, CFStringLowercase, NULL); }
- (NSString *)uppercaseString { return transformed(self, CFStringUppercase, NULL); }
- (NSString *)capitalizedString { return transformed(self, CFStringCapitalize, NULL); }
- (NSString *)lowercaseStringWithLocale:(NSLocale *)locale { return transformed(self, CFStringLowercase, (CFLocaleRef)locale); }
- (NSString *)uppercaseStringWithLocale:(NSLocale *)locale { return transformed(self, CFStringUppercase, (CFLocaleRef)locale); }
- (NSString *)capitalizedStringWithLocale:(NSLocale *)locale { return transformed(self, CFStringCapitalize, (CFLocaleRef)locale); }
- (NSString *)localizedLowercaseString { return [self lowercaseStringWithLocale:current_locale()]; }
- (NSString *)localizedUppercaseString { return [self uppercaseStringWithLocale:current_locale()]; }
- (NSString *)localizedCapitalizedString { return [self capitalizedStringWithLocale:current_locale()]; }

- (NSString *)stringByTrimmingCharactersInSet:(NSCharacterSet *)set
{
    NSUInteger n = [self length], start = 0, end = n;
    while (start < n && CFCharacterSetIsCharacterMember((CFCharacterSetRef)set, [self characterAtIndex:start])) start++;
    while (end > start && CFCharacterSetIsCharacterMember((CFCharacterSetRef)set, [self characterAtIndex:end - 1])) end--;
    return [self substringWithRange:NSMakeRange(start, end - start)];
}

- (NSArray<NSString *> *)componentsSeparatedByString:(NSString *)separator
{
    CFArrayRef a = CFStringCreateArrayBySeparatingStrings(NULL, (CFStringRef)self, (CFStringRef)separator);
    return [(id)a autorelease];
}

- (NSArray<NSString *> *)componentsSeparatedByCharactersInSet:(NSCharacterSet *)separator
{
    NSMutableArray *parts = [NSMutableArray array];
    NSUInteger n = [self length], start = 0;
    for (NSUInteger i = 0; i < n; i++) {
        if (CFCharacterSetIsCharacterMember((CFCharacterSetRef)separator, [self characterAtIndex:i])) {
            [parts addObject:[self substringWithRange:NSMakeRange(start, i - start)]];
            start = i + 1;
        }
    }
    [parts addObject:[self substringFromIndex:start]];
    return parts;
}

- (NSString *)stringByReplacingOccurrencesOfString:(NSString *)target withString:(NSString *)replacement
                                            options:(NSStringCompareOptions)options range:(NSRange)searchRange
{
    NSMutableString *m = [[self mutableCopy] autorelease];
    [m replaceOccurrencesOfString:target withString:replacement options:options range:searchRange];
    return [NSString stringWithString:m];
}

- (NSString *)stringByReplacingOccurrencesOfString:(NSString *)target withString:(NSString *)replacement
{
    return [self stringByReplacingOccurrencesOfString:target withString:replacement options:0 range:NSMakeRange(0, [self length])];
}

- (NSString *)stringByReplacingCharactersInRange:(NSRange)range withString:(NSString *)replacement
{
    NSMutableString *m = [[self mutableCopy] autorelease];
    [m replaceCharactersInRange:range withString:replacement];
    return [NSString stringWithString:m];
}

- (double)doubleValue { return CFStringGetDoubleValue((CFStringRef)self); }
- (float)floatValue { return (float)CFStringGetDoubleValue((CFStringRef)self); }
- (int)intValue { return (int)[self longLongValue]; }
- (NSInteger)integerValue { return (NSInteger)[self longLongValue]; }

/* Leading whitespace, an optional sign, then digits; saturating, as Apple's. */
- (long long)longLongValue
{
    NSUInteger n = [self length], i = 0;
    while (i < n && CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetWhitespaceAndNewline), [self characterAtIndex:i])) i++;
    BOOL neg = NO;
    if (i < n && ([self characterAtIndex:i] == '-' || [self characterAtIndex:i] == '+')) neg = [self characterAtIndex:i++] == '-';
    unsigned long long v = 0;
    BOOL overflow = NO;
    for (; i < n; i++) {
        unichar c = [self characterAtIndex:i];
        if (c < '0' || c > '9') break;
        if (v > (ULLONG_MAX - (unsigned)(c - '0')) / 10) overflow = YES;
        else v = v * 10 + (unsigned)(c - '0');
    }
    if (neg) return overflow || v > (unsigned long long)LLONG_MAX + 1 ? LLONG_MIN : -(long long)v;
    return overflow || v > LLONG_MAX ? LLONG_MAX : (long long)v;
}

- (BOOL)boolValue
{
    NSUInteger n = [self length], i = 0;
    while (i < n && CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetWhitespaceAndNewline), [self characterAtIndex:i])) i++;
    if (i < n && ([self characterAtIndex:i] == '+' || [self characterAtIndex:i] == '-')) i++;
    while (i < n && [self characterAtIndex:i] == '0') i++;
    if (i >= n) return NO;
    unichar c = [self characterAtIndex:i];
    return c == 'Y' || c == 'y' || c == 'T' || c == 't' || (c >= '1' && c <= '9');
}

- (NSString *)description { return self; }

- (const char *)UTF8String { return [self cStringUsingEncoding:NSUTF8StringEncoding]; }

- (const char *)cStringUsingEncoding:(NSStringEncoding)encoding
{
    CFStringEncoding e = cf_encoding(encoding);
    const char *fast = CFStringGetCStringPtr((CFStringRef)self, e);
    if (fast) return fast;
    CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength((CFStringRef)self), e) + 1;
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)max];
    if (!CFStringGetCString((CFStringRef)self, [d mutableBytes], max, e)) return NULL;
    return [d mutableBytes];
}

- (BOOL)getCString:(char *)buffer maxLength:(NSUInteger)maxBufferCount encoding:(NSStringEncoding)encoding
{
    return CFStringGetCString((CFStringRef)self, buffer, (CFIndex)maxBufferCount, cf_encoding(encoding));
}

- (BOOL)getBytes:(void *)buffer maxLength:(NSUInteger)maxBufferCount usedLength:(NSUInteger *)usedBufferCount
        encoding:(NSStringEncoding)encoding options:(NSStringEncodingConversionOptions)options
           range:(NSRange)range remainingRange:(NSRangePointer)leftover
{
    NSUInteger length = [self length];
    if (range.location > length || range.length > length - range.location)
        FinchRaise(NSRangeException, "-[%s %s]: Range out of bounds", object_getClassName(self), sel_getName(_cmd));
    CFStringRef string = cf_copy_of(self);
    CFIndex used = 0;
    CFIndex converted = CFStringGetBytes(string, CFRangeMake((CFIndex)range.location, (CFIndex)range.length),
        cf_encoding(encoding), options & NSStringEncodingConversionAllowLossy ? '?' : 0,
        (options & NSStringEncodingConversionExternalRepresentation) != 0,
        maxBufferCount ? buffer : NULL, (CFIndex)maxBufferCount, &used);
    CFRelease(string);
    if (usedBufferCount) *usedBufferCount = (NSUInteger)used;
    if (leftover) *leftover = NSMakeRange(range.location + (NSUInteger)converted, range.length - (NSUInteger)converted);
    return converted > 0 || range.length == 0;
}

- (NSUInteger)lengthOfBytesUsingEncoding:(NSStringEncoding)enc
{
    CFIndex used = 0, n = CFStringGetLength((CFStringRef)self);
    if (CFStringGetBytes((CFStringRef)self, CFRangeMake(0, n), cf_encoding(enc), 0, false, NULL, 0, &used) != n) return 0;
    return (NSUInteger)used;
}

- (NSUInteger)maximumLengthOfBytesUsingEncoding:(NSStringEncoding)enc
{
    return (NSUInteger)CFStringGetMaximumSizeForEncoding(CFStringGetLength((CFStringRef)self), cf_encoding(enc));
}

- (NSData *)dataUsingEncoding:(NSStringEncoding)encoding allowLossyConversion:(BOOL)lossy
{
    CFDataRef d = CFStringCreateExternalRepresentation(NULL, (CFStringRef)self, cf_encoding(encoding), lossy ? '?' : 0);
    if (d && (encoding == NSUnicodeStringEncoding || encoding == NSUTF16StringEncoding)) return [(id)d autorelease];
    return [(id)d autorelease];
}
- (NSData *)dataUsingEncoding:(NSStringEncoding)encoding { return [self dataUsingEncoding:encoding allowLossyConversion:NO]; }

- (BOOL)canBeConvertedToEncoding:(NSStringEncoding)encoding { return [self dataUsingEncoding:encoding] != nil; }
- (NSStringEncoding)fastestEncoding
{
    return CFStringConvertEncodingToNSStringEncoding(CFStringGetFastestEncoding((CFStringRef)self));
}
- (NSStringEncoding)smallestEncoding
{
    return CFStringConvertEncodingToNSStringEncoding(CFStringGetSmallestEncoding((CFStringRef)self));
}

- (void)getLineStart:(NSUInteger *)startPtr end:(NSUInteger *)lineEndPtr contentsEnd:(NSUInteger *)contentsEndPtr forRange:(NSRange)range
{
    CFIndex s, e, c;
    CFStringGetLineBounds((CFStringRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length), &s, &e, &c);
    if (startPtr) *startPtr = (NSUInteger)s;
    if (lineEndPtr) *lineEndPtr = (NSUInteger)e;
    if (contentsEndPtr) *contentsEndPtr = (NSUInteger)c;
}

- (NSRange)lineRangeForRange:(NSRange)range
{
    NSUInteger start, end;
    [self getLineStart:&start end:&end contentsEnd:NULL forRange:range];
    return NSMakeRange(start, end - start);
}

- (void)getParagraphStart:(NSUInteger *)startPtr end:(NSUInteger *)parEndPtr contentsEnd:(NSUInteger *)contentsEndPtr
                 forRange:(NSRange)range
{
    CFIndex s, e, c;
    CFStringGetParagraphBounds((CFStringRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length), &s, &e, &c);
    if (startPtr) *startPtr = (NSUInteger)s;
    if (parEndPtr) *parEndPtr = (NSUInteger)e;
    if (contentsEndPtr) *contentsEndPtr = (NSUInteger)c;
}

- (NSRange)paragraphRangeForRange:(NSRange)range
{
    NSUInteger start, end;
    [self getParagraphStart:&start end:&end contentsEnd:NULL forRange:range];
    return NSMakeRange(start, end - start);
}

- (NSRange)rangeOfComposedCharacterSequenceAtIndex:(NSUInteger)index
{
    CFRange r = CFStringGetRangeOfComposedCharactersAtIndex((CFStringRef)self, (CFIndex)index);
    return NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
}

- (NSRange)rangeOfComposedCharacterSequencesForRange:(NSRange)range
{
    if (![self length])
        return NSMakeRange(0, 0);
    NSRange first = [self rangeOfComposedCharacterSequenceAtIndex:range.location];
    if (!range.length)
        return NSMakeRange(first.location, 0);
    NSRange last = [self rangeOfComposedCharacterSequenceAtIndex:NSMaxRange(range) - 1];
    return NSMakeRange(first.location, NSMaxRange(last) - first.location);
}

- (void)enumerateLinesUsingBlock:(void (^)(NSString *line, BOOL *stop))block
{
    NSUInteger n = [self length], start = 0;
    BOOL stop = NO;
    while (start < n && !stop) {
        NSUInteger end, contentsEnd;
        [self getLineStart:NULL end:&end contentsEnd:&contentsEnd forRange:NSMakeRange(start, 0)];
        block([self substringWithRange:NSMakeRange(start, contentsEnd - start)], &stop);
        start = end;
    }
}

- (void)getCharacters:(unichar *)buffer
{
    [self getCharacters:buffer range:NSMakeRange(0, [self length])];
}

/* The pieces of a range, as Apple's gives them: each piece's range (a line or paragraph
   without its terminator, a word, a sentence with the spaces after it, a composed
   character) and its enclosing range (the terminator, or the gap to the next word, too).
   The enclosing ranges cover the range. */
- (void)enumerateSubstringsInRange:(NSRange)range options:(NSStringEnumerationOptions)opts
                        usingBlock:(void (^)(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop))block
{
    NSUInteger kind = opts & 0xFF, end = NSMaxRange(range);
    NSMutableArray *pieces = [NSMutableArray array]; /* pairs of NSValue ranges */
    if (kind == NSStringEnumerationByLines || kind == NSStringEnumerationByParagraphs) {
        NSUInteger at = range.location;
        while (at < end) {
            NSUInteger e, c;
            if (kind == NSStringEnumerationByLines)
                [self getLineStart:NULL end:&e contentsEnd:&c forRange:NSMakeRange(at, 0)];
            else
                [self getParagraphStart:NULL end:&e contentsEnd:&c forRange:NSMakeRange(at, 0)];
            e = MIN(e, end), c = MIN(c, end);
            [pieces addObject:@[ [NSValue valueWithRange:NSMakeRange(at, c - at)], [NSValue valueWithRange:NSMakeRange(at, e - at)] ]];
            if (e <= at)
                break;
            at = e;
        }
    } else if (kind == NSStringEnumerationByWords || kind == NSStringEnumerationBySentences) {
        CFLocaleRef locale = (opts & NSStringEnumerationLocalized) ? CFLocaleCopyCurrent() : NULL;
        CFStringTokenizerRef t = CFStringTokenizerCreate(NULL, (CFStringRef)self, CFRangeMake((CFIndex)range.location, (CFIndex)range.length),
                                                         kind == NSStringEnumerationByWords ? kCFStringTokenizerUnitWordBoundary
                                                                                            : kCFStringTokenizerUnitSentence,
                                                         locale);
        if (locale)
            CFRelease(locale);
        NSMutableArray *found = [NSMutableArray array];
        for (CFStringTokenizerTokenType type; (type = CFStringTokenizerAdvanceToNextToken(t)) != kCFStringTokenizerTokenNone;) {
            CFRange r = CFStringTokenizerGetCurrentTokenRange(t);
            NSRange token = NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
            if (kind == NSStringEnumerationByWords) {
                /* word boundaries give the gaps too: a word has a letter, digit or symbol */
                NSString *piece = [self substringWithRange:token];
                if ([piece rangeOfCharacterFromSet:[NSCharacterSet alphanumericCharacterSet]].location == NSNotFound &&
                    [piece rangeOfCharacterFromSet:[NSCharacterSet symbolCharacterSet]].location == NSNotFound)
                    continue;
            }
            [found addObject:[NSValue valueWithRange:token]];
        }
        CFRelease(t);
        for (NSUInteger i = 0; i < [found count]; i++) {
            NSRange r = [[found objectAtIndex:i] rangeValue];
            NSUInteger from = i == 0 ? range.location : r.location;
            NSUInteger to = i + 1 < [found count] ? [[found objectAtIndex:i + 1] rangeValue].location : end;
            [pieces addObject:@[ [NSValue valueWithRange:r], [NSValue valueWithRange:NSMakeRange(from, to - from)] ]];
        }
    } else {
        NSUInteger at = range.location;
        while (at < end) {
            NSRange r = [self rangeOfComposedCharacterSequenceAtIndex:at];
            r = NSIntersectionRange(r, NSMakeRange(at, end - at));
            if (!r.length)
                r.length = 1;
            [pieces addObject:@[ [NSValue valueWithRange:r], [NSValue valueWithRange:r] ]];
            at = NSMaxRange(r);
        }
    }
    BOOL stop = NO;
    NSEnumerator *e = (opts & NSStringEnumerationReverse) ? [pieces reverseObjectEnumerator] : [pieces objectEnumerator];
    for (NSArray *pair in e) {
        NSRange sub = [[pair objectAtIndex:0] rangeValue], enclosing = [[pair objectAtIndex:1] rangeValue];
        NSString *str = (opts & NSStringEnumerationSubstringNotRequired) ? nil : [self substringWithRange:sub];
        block(str, sub, enclosing, &stop);
        if (stop)
            break;
    }
}

- (NSString *)decomposedStringWithCanonicalMapping { return [self _finchNormalized:kCFStringNormalizationFormD]; }
- (NSString *)precomposedStringWithCanonicalMapping { return [self _finchNormalized:kCFStringNormalizationFormC]; }
- (NSString *)decomposedStringWithCompatibilityMapping { return [self _finchNormalized:kCFStringNormalizationFormKD]; }
- (NSString *)precomposedStringWithCompatibilityMapping { return [self _finchNormalized:kCFStringNormalizationFormKC]; }
- (NSString *)_finchNormalized:(CFStringNormalizationForm)form
{
    CFMutableStringRef m = CFStringCreateMutableCopy(NULL, 0, (CFStringRef)self);
    CFStringNormalize(m, form);
    return [(id)m autorelease];
}

@end

/* MARK: - Paths */

@implementation NSString (NSStringPathExtensions)

+ (NSString *)pathWithComponents:(NSArray<NSString *> *)components
{
    NSMutableString *p = [NSMutableString string];
    NSUInteger i = 0;
    for (NSString *c in components) {
        if (i++ && !([p hasSuffix:@"/"])) [p appendString:@"/"];
        [p appendString:c];
    }
    return [NSString stringWithString:p];
}

- (NSArray<NSString *> *)pathComponents
{
    NSMutableArray *parts = [NSMutableArray array];
    if ([self hasPrefix:@"/"]) [parts addObject:@"/"];
    for (NSString *c in [self componentsSeparatedByString:@"/"])
        if ([c length]) [parts addObject:c];
    if ([self length] > 1 && [self hasSuffix:@"/"]) [parts addObject:@"/"];
    return parts;
}

- (BOOL)isAbsolutePath { return [self hasPrefix:@"/"] || [self hasPrefix:@"~"]; }

/* Without trailing slashes (but "/" stays "/"). */
static NSString *
trimmed(NSString *s)
{
    NSUInteger n = [s length];
    while (n > 1 && [s characterAtIndex:n - 1] == '/') n--;
    return [s substringToIndex:n];
}

- (NSString *)lastPathComponent
{
    NSString *s = trimmed(self);
    if ([s isEqualToString:@"/"]) return s;
    NSRange r = [s rangeOfString:@"/" options:NSBackwardsSearch];
    return r.location == NSNotFound ? s : [s substringFromIndex:r.location + 1];
}

- (NSString *)stringByDeletingLastPathComponent
{
    NSString *s = trimmed(self);
    NSRange r = [s rangeOfString:@"/" options:NSBackwardsSearch];
    if (r.location == NSNotFound) return @"";
    if (r.location == 0) return [s length] > 1 ? @"/" : @"/";
    return trimmed([s substringToIndex:r.location]);
}

- (NSString *)stringByAppendingPathComponent:(NSString *)str
{
    if ([self length] == 0) return [NSString stringWithString:str];
    if ([str length] == 0) return trimmed(self);
    NSString *base = [self hasSuffix:@"/"] ? trimmed(self) : self;
    if ([base isEqualToString:@"/"]) base = @"";
    NSString *rest = str;
    while ([rest hasPrefix:@"/"]) rest = [rest substringFromIndex:1];
    return trimmed([NSString stringWithFormat:@"%@/%@", base, rest]);
}

- (NSString *)pathExtension
{
    NSString *last = [self lastPathComponent];
    NSRange r = [last rangeOfString:@"." options:NSBackwardsSearch];
    if (r.location == NSNotFound || r.location == 0) return @"";
    return [last substringFromIndex:r.location + 1];
}

- (NSString *)stringByDeletingPathExtension
{
    NSString *s = trimmed(self);
    NSString *ext = [s pathExtension];
    if ([ext length] == 0) return s;
    return [s substringToIndex:[s length] - [ext length] - 1];
}

- (NSString *)stringByAppendingPathExtension:(NSString *)str
{
    return [NSString stringWithFormat:@"%@.%@", trimmed(self), str];
}

- (NSString *)stringByExpandingTildeInPath
{
    if (![self hasPrefix:@"~"]) return self;
    NSRange slash = [self rangeOfString:@"/"];
    NSString *user = slash.location == NSNotFound ? [self substringFromIndex:1] : [self substringWithRange:NSMakeRange(1, slash.location - 1)];
    NSString *rest = slash.location == NSNotFound ? @"" : [self substringFromIndex:slash.location];
    NSString *home = [user length] ? NSHomeDirectoryForUser(user) : NSHomeDirectory();
    return home ? [home stringByAppendingString:rest] : self;
}

/* The home folder at the start of a path written as "~", as Apple's: the path standardized
   when it is under home, untouched otherwise. */
- (NSString *)stringByAbbreviatingWithTildeInPath
{
    NSString *home = [NSHomeDirectory() stringByStandardizingPath];
    if (![home length] || ![self hasPrefix:home])
        return self;
    NSString *s = [self stringByStandardizingPath];
    if ([s isEqualToString:home])
        return @"~";
    if ([s hasPrefix:[home stringByAppendingString:@"/"]])
        return [@"~" stringByAppendingString:[s substringFromIndex:[home length]]];
    return self;
}

- (NSString *)stringByStandardizingPath
{
    NSString *s = [self stringByExpandingTildeInPath];
    NSMutableArray *out = [NSMutableArray array];
    BOOL abs = [s hasPrefix:@"/"];
    for (NSString *c in [s componentsSeparatedByString:@"/"]) {
        if ([c length] == 0 || [c isEqualToString:@"."]) continue;
        if ([c isEqualToString:@".."] && abs && [out count]) { [out removeLastObject]; continue; }
        [out addObject:c];
    }
    NSString *joined = [out componentsJoinedByString:@"/"];
    return abs ? [@"/" stringByAppendingString:joined] : ([joined length] ? joined : @"");
}

/* realpath(3) when the path exists, without a leading /private when the
 * rest names the same file (as Apple's), else standardized. */
- (NSString *)stringByResolvingSymlinksInPath
{
    NSString *s = [self stringByExpandingTildeInPath];
    char buf[PATH_MAX];
    if (![s isAbsolutePath] || !realpath([s fileSystemRepresentation], buf)) return [s stringByStandardizingPath];
    NSString *r = [NSString stringWithUTF8String:buf];
    if ([r hasPrefix:@"/private/"]) {
        NSString *without = [r substringFromIndex:8];
        struct stat a, b;
        if (stat([without fileSystemRepresentation], &a) == 0 && stat(buf, &b) == 0 && a.st_ino == b.st_ino) r = without;
    }
    return r;
}

- (const char *)fileSystemRepresentation
{
    NSUInteger max = [self maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
    NSMutableData *d = [NSMutableData dataWithLength:max];
    if (![self getFileSystemRepresentation:[d mutableBytes] maxLength:max])
        FinchRaise(NSCharacterConversionException, "*** -[%s %s]: conversion failed", object_getClassName(self), sel_getName(_cmd));
    return [d mutableBytes];
}

- (BOOL)getFileSystemRepresentation:(char *)cname maxLength:(NSUInteger)max
{
    return CFStringGetFileSystemRepresentation((CFStringRef)self, cname, (CFIndex)max);
}

@end

/* MARK: - NSMutableString */

@implementation NSMutableString

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)aString { FinchAbstract(self, _cmd); }

- (id)copyWithZone:(NSZone *)zone { return (id)cf_copy_of(self); }

/* What CF sends to mutable strings it didn't make. */
- (void)_cfAppendCString:(const unsigned char *)cStr length:(NSInteger)length
{
    CFStringRef s = CFStringCreateWithBytes(NULL, cStr, (CFIndex)length, kCFStringEncodingISOLatin1, false);
    [self appendString:(NSString *)s];
    CFRelease(s);
}

/* The CF transformations (lowercase, trim, ...): applied to a CF copy,
 * then put back. */
static void
cf_apply(NSMutableString *self, void (^op)(CFMutableStringRef))
{
    CFMutableStringRef m = CFStringCreateMutable(NULL, 0);
    CFStringRef c = cf_copy_of(self);
    CFStringAppend(m, c);
    CFRelease(c);
    op(m);
    [self setString:(NSString *)m];
    CFRelease(m);
}

- (void)_cfLowercase:(const void *)locale { cf_apply(self, ^(CFMutableStringRef m) { CFStringLowercase(m, locale); }); }
- (void)_cfUppercase:(const void *)locale { cf_apply(self, ^(CFMutableStringRef m) { CFStringUppercase(m, locale); }); }
- (void)_cfCapitalize:(const void *)locale { cf_apply(self, ^(CFMutableStringRef m) { CFStringCapitalize(m, locale); }); }
- (void)_cfNormalize:(CFStringNormalizationForm)form { cf_apply(self, ^(CFMutableStringRef m) { CFStringNormalize(m, form); }); }
- (void)_cfTrimWS { cf_apply(self, ^(CFMutableStringRef m) { CFStringTrimWhitespace(m); }); }
- (void)_cfTrim:(CFStringRef)trim { cf_apply(self, ^(CFMutableStringRef m) { CFStringTrim(m, trim); }); }
- (void)_cfPad:(CFStringRef)pad length:(uint32_t)length padIndex:(uint32_t)index
{
    cf_apply(self, ^(CFMutableStringRef m) { CFStringPad(m, pad, (CFIndex)length, (CFIndex)index); });
}

@end

@implementation NSMutableString (NSMutableStringExtensionMethods)

+ (NSMutableString *)stringWithCapacity:(NSUInteger)capacity { return [[[self alloc] initWithCapacity:capacity] autorelease]; }
- (NSMutableString *)initWithCapacity:(NSUInteger)capacity { return [self init]; }

- (void)insertString:(NSString *)aString atIndex:(NSUInteger)loc { [self replaceCharactersInRange:NSMakeRange(loc, 0) withString:aString]; }
- (void)deleteCharactersInRange:(NSRange)range { [self replaceCharactersInRange:range withString:@""]; }
- (void)appendString:(NSString *)aString { [self replaceCharactersInRange:NSMakeRange([self length], 0) withString:aString]; }
- (void)setString:(NSString *)aString { [self replaceCharactersInRange:NSMakeRange(0, [self length]) withString:aString]; }

- (void)appendFormat:(NSString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    CFStringRef s = FinchCreateWithFormat(NULL, (CFStringRef)format, ap);
    va_end(ap);
    [self appendString:(NSString *)s];
    CFRelease(s);
}

- (void)appendCharacters:(const unichar *)characters length:(NSUInteger)length
{
    CFStringRef s = CFStringCreateWithCharacters(NULL, characters, (CFIndex)length);
    [self appendString:(NSString *)s];
    CFRelease(s);
}

- (NSUInteger)replaceOccurrencesOfString:(NSString *)target withString:(NSString *)replacement
                                 options:(NSStringCompareOptions)options range:(NSRange)searchRange
{
    if (!target || !replacement)
        FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: nil argument", object_getClassName(self), sel_getName(_cmd));
    if (options & NSRegularExpressionSearch) return FinchRegexReplace(self, target, replacement, options, searchRange);
    NSUInteger count = 0;
    NSRange r = searchRange;
    BOOL backwards = (options & NSBackwardsSearch) != 0;
    for (;;) {
        NSRange f = [self rangeOfString:target options:options range:r];
        if (f.location == NSNotFound) break;
        [self replaceCharactersInRange:f withString:replacement];
        count++;
        if (backwards) {
            r = NSMakeRange(r.location, f.location - r.location);
        } else {
            NSUInteger next = f.location + [replacement length];
            NSUInteger end = r.location + r.length + [replacement length] - f.length;
            r = NSMakeRange(next, end - next);
            searchRange = r;
        }
        if (options & NSAnchoredSearch) break;
    }
    return count;
}

@end

/* MARK: - Placeholders */

/* What +[NSString alloc] returns: each initializer makes an (immutable or
 * mutable) CFString. */
#define PLACEHOLDER_IMPL(MUTABLE) \
    - (instancetype)retain { return self; } \
    - (oneway void)release { } \
    - (instancetype)autorelease { return self; } \
    - (NSUInteger)retainCount { return NSUIntegerMax; } \
    - (void)dealloc { FINCH_NO_SUPER_DEALLOC } \
    \
    static id finish_##MUTABLE(CFStringRef s) \
    { \
        if (!s) return nil; \
        if (!(MUTABLE)) return (id)s; \
        CFMutableStringRef m = CFStringCreateMutableCopy(NULL, 0, s); \
        CFRelease(s); \
        return (id)m; \
    } \
    - (instancetype)init { return finish_##MUTABLE(CFStringCreateWithCharacters(NULL, NULL, 0)); } \
    - (instancetype)initWithString:(NSString *)aString \
    { \
        if (!aString) FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: nil argument", object_getClassName(self), sel_getName(_cmd)); \
        return finish_##MUTABLE(CFStringCreateCopy(NULL, (CFStringRef)aString)); \
    } \
    - (instancetype)initWithCharacters:(const unichar *)characters length:(NSUInteger)length \
    { \
        return finish_##MUTABLE(CFStringCreateWithCharacters(NULL, characters, (CFIndex)length)); \
    } \
    - (instancetype)initWithCharactersNoCopy:(unichar *)characters length:(NSUInteger)length freeWhenDone:(BOOL)f \
    { \
        if (MUTABLE || !f) { id r = [self initWithCharacters:characters length:length]; if (f) free(characters); return r; } \
        return (id)CFStringCreateWithCharactersNoCopy(NULL, characters, (CFIndex)length, kCFAllocatorMalloc); \
    } \
    - (instancetype)initWithCString:(const char *)cString encoding:(NSStringEncoding)enc \
    { \
        if (!cString) FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: NULL cString", object_getClassName(self), sel_getName(_cmd)); \
        return finish_##MUTABLE(CFStringCreateWithCString(NULL, cString, cf_encoding(enc))); \
    } \
    - (instancetype)initWithUTF8String:(const char *)s \
    { \
        if (!s) FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: NULL cString", object_getClassName(self), sel_getName(_cmd)); \
        return finish_##MUTABLE(CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8)); \
    } \
    - (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)len encoding:(NSStringEncoding)enc \
    { \
        return finish_##MUTABLE(CFStringCreateWithBytes(NULL, bytes, (CFIndex)len, cf_encoding(enc), \
            enc == NSUnicodeStringEncoding || enc == NSUTF16StringEncoding)); \
    } \
    - (instancetype)initWithFormat:(NSString *)format locale:(id)locale arguments:(va_list)argList \
    { \
        if (!format) FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: nil argument", object_getClassName(self), sel_getName(_cmd)); \
        return finish_##MUTABLE(FinchCreateWithFormat(FinchFormatOptions(locale), (CFStringRef)format, argList)); \
    }

@implementation NSPlaceholderString
PLACEHOLDER_IMPL(0)
@end

@implementation NSPlaceholderMutableString
PLACEHOLDER_IMPL(1)
- (NSMutableString *)initWithCapacity:(NSUInteger)capacity { return (id)CFStringCreateMutable(NULL, 0); }
@end

#pragma mark - Encodings

/* The encodings, as Apple's: CoreFoundation's, as NSStringEncodings. */
@implementation NSString (FinchEncodings)

+ (NSStringEncoding)defaultCStringEncoding
{
    return CFStringConvertEncodingToNSStringEncoding(CFStringGetSystemEncoding());
}

+ (const NSStringEncoding *)availableStringEncodings
{
    static NSStringEncoding *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      const CFStringEncoding *cf = CFStringGetListOfAvailableEncodings();
      size_t n = 0;
      while (cf[n] != kCFStringEncodingInvalidId)
          n++;
      list = calloc(n + 1, sizeof *list);
      size_t k = 0;
      for (size_t i = 0; i < n; i++) {
          NSStringEncoding e = CFStringConvertEncodingToNSStringEncoding(cf[i]);
          BOOL seen = NO;
          for (size_t j = 0; j < k && !seen; j++)
              seen = list[j] == e;
          if (!seen && e != kCFStringEncodingInvalidId)
              list[k++] = e;
      }
      list[k] = 0;
    });
    return list;
}

+ (NSString *)localizedNameOfStringEncoding:(NSStringEncoding)encoding
{
    CFStringRef name = CFStringGetNameOfEncoding(CFStringConvertNSStringEncodingToEncoding(encoding));
    return name ? (__bridge NSString *)name : @"";
}

@end
