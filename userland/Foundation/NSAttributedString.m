/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSAttributedString and NSMutableAttributedString (docs/design/FOUNDATION.md),
 * against the SDK's <Foundation/NSAttributedString.h>.
 *
 * The abstract classes have two primitives each (-string and
 * -attributesAtIndex:effectiveRange:; -replaceCharactersInRange:withString:
 * and -setAttributes:range:) and build the rest on them, so subclasses such
 * as AppKit's NSTextStorage need only those. +alloc gives placeholders that
 * make CFAttributedStrings, whose class is CF's __NSCFAttributedString.
 *
 * Archives use Apple's keys: NSString, then NSAttributes (one dictionary
 * for a single run, else the distinct dictionaries) and NSAttributeInfo
 * (LEB128 pairs of run length and dictionary index).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

@interface NSPlaceholderAttributedString : NSMutableAttributedString
@end

static id placeholder, mutable_placeholder;

static void
check_range(id self, SEL _cmd, NSRange r)
{
    if (r.location > [self length] || r.length > [self length] - r.location)
        FinchRaise(NSRangeException, "%s %s: Out of bounds", object_getClassName(self), sel_getName(_cmd));
}

/* MARK: - NSAttributedString */

@implementation NSAttributedString

+ (void)initialize
{
    if (self == [NSAttributedString class]) {
        placeholder = class_createInstance([NSPlaceholderAttributedString class], 0);
        mutable_placeholder = class_createInstance([NSPlaceholderAttributedString class], 0);
    }
}

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSAttributedString class]) return placeholder;
    if (self == [NSMutableAttributedString class]) return mutable_placeholder;
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (NSString *)string { FinchAbstract(self, _cmd); }
- (NSDictionary *)attributesAtIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range { FinchAbstract(self, _cmd); }

- (instancetype)initWithFormat:(NSAttributedString *)format options:(NSAttributedStringFormattingOptions)options
                        locale:(NSLocale *)locale, ...
{
    va_list ap;
    va_start(ap, locale);
    self = [self initWithFormat:format options:options locale:locale arguments:ap];
    va_end(ap);
    return self;
}

/* Finch has no formatting contexts yet (they choose grammatical forms); the context is unused. */
- (instancetype)initWithFormat:(NSAttributedString *)format options:(NSAttributedStringFormattingOptions)options
                        locale:(NSLocale *)locale
                       context:(NSDictionary *)context, ...
{
    va_list ap;
    va_start(ap, context);
    self = [self initWithFormat:format options:options locale:locale arguments:ap];
    va_end(ap);
    return self;
}

- (instancetype)initWithFormat:(NSAttributedString *)format options:(NSAttributedStringFormattingOptions)options
                        locale:(NSLocale *)locale
                       context:(NSDictionary *)context
                     arguments:(va_list)arguments
{
    return [self initWithFormat:format options:options locale:locale arguments:arguments];
}

+ (instancetype)localizedAttributedStringWithFormat:(NSAttributedString *)format, ...
{
    va_list ap;
    va_start(ap, format);
    id s = [[[self alloc] initWithFormat:format options:0 locale:[NSLocale currentLocale] arguments:ap] autorelease];
    va_end(ap);
    return s;
}

+ (instancetype)localizedAttributedStringWithFormat:(NSAttributedString *)format options:(NSAttributedStringFormattingOptions)options, ...
{
    va_list ap;
    va_start(ap, options);
    id s = [[[self alloc] initWithFormat:format options:options locale:[NSLocale currentLocale] arguments:ap] autorelease];
    va_end(ap);
    return s;
}

- (instancetype)initWithString:(NSString *)str { return [self init]; }
- (instancetype)initWithString:(NSString *)str attributes:(NSDictionary *)attrs { return [self init]; }
- (instancetype)initWithAttributedString:(NSAttributedString *)attrStr { return [self init]; }

- (NSUInteger)length { return [[self string] length]; }

- (id)attribute:(NSAttributedStringKey)attrName atIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range
{
    return [[self attributesAtIndex:location effectiveRange:range] objectForKey:attrName];
}

- (NSDictionary *)attributesAtIndex:(NSUInteger)location longestEffectiveRange:(NSRangePointer)range inRange:(NSRange)limit
{
    NSRange r;
    NSDictionary *attrs = [self attributesAtIndex:location effectiveRange:&r];
    if (range) {
        NSUInteger start = r.location, end = NSMaxRange(r);
        while (start > limit.location) {
            NSRange prev;
            if (![[self attributesAtIndex:start - 1 effectiveRange:&prev] isEqualToDictionary:attrs]) break;
            start = prev.location;
        }
        while (end < NSMaxRange(limit)) {
            NSRange next;
            if (![[self attributesAtIndex:end effectiveRange:&next] isEqualToDictionary:attrs]) break;
            end = NSMaxRange(next);
        }
        start = MAX(start, limit.location);
        end = MIN(end, NSMaxRange(limit));
        *range = NSMakeRange(start, end - start);
    }
    return attrs;
}

static BOOL
same(id a, id b)
{
    return a == b || [a isEqual:b];
}

- (id)attribute:(NSAttributedStringKey)attrName atIndex:(NSUInteger)location longestEffectiveRange:(NSRangePointer)range inRange:(NSRange)limit
{
    NSRange r;
    id value = [self attribute:attrName atIndex:location effectiveRange:&r];
    if (range) {
        NSUInteger start = r.location, end = NSMaxRange(r);
        while (start > limit.location) {
            NSRange prev;
            if (!same([self attribute:attrName atIndex:start - 1 effectiveRange:&prev], value)) break;
            start = prev.location;
        }
        while (end < NSMaxRange(limit)) {
            NSRange next;
            if (!same([self attribute:attrName atIndex:end effectiveRange:&next], value)) break;
            end = NSMaxRange(next);
        }
        start = MAX(start, limit.location);
        end = MIN(end, NSMaxRange(limit));
        *range = NSMakeRange(start, end - start);
    }
    return value;
}

- (NSAttributedString *)attributedSubstringFromRange:(NSRange)range
{
    check_range(self, _cmd, range);
    NSMutableAttributedString *m = [[[NSMutableAttributedString alloc] initWithString:[[self string] substringWithRange:range]] autorelease];
    for (NSUInteger i = range.location; i < NSMaxRange(range);) {
        NSRange r;
        NSDictionary *attrs = [self attributesAtIndex:i effectiveRange:&r];
        NSUInteger end = MIN(NSMaxRange(r), NSMaxRange(range));
        [m setAttributes:attrs range:NSMakeRange(i - range.location, end - i)];
        i = end;
    }
    return [[m copy] autorelease];
}

- (BOOL)isEqualToAttributedString:(NSAttributedString *)other
{
    if (other == self) return YES;
    if (!other || ![[self string] isEqualToString:[other string]]) return NO;
    NSUInteger len = [self length];
    for (NSUInteger i = 0; i < len;) {
        NSRange a, b;
        NSDictionary *x = [self attributesAtIndex:i effectiveRange:&a];
        NSDictionary *y = [other attributesAtIndex:i effectiveRange:&b];
        if (![x isEqualToDictionary:y]) return NO;
        i = MIN(NSMaxRange(a), NSMaxRange(b));
    }
    return YES;
}

- (BOOL)isEqual:(id)object
{
    return object == self || ([object isKindOfClass:[NSAttributedString class]] && [self isEqualToAttributedString:object]);
}

- (NSUInteger)hash { return [[self string] hash]; }

- (id)copyWithZone:(NSZone *)zone { return [[NSAttributedString allocWithZone:zone] initWithAttributedString:self]; }
- (id)mutableCopyWithZone:(NSZone *)zone { return [[NSMutableAttributedString allocWithZone:zone] initWithAttributedString:self]; }

/* Apple's: each run's text followed by its attributes. */
- (NSString *)description
{
    NSMutableString *s = [NSMutableString string];
    NSString *str = [self string];
    NSUInteger len = [self length];
    for (NSUInteger i = 0; i < len;) {
        NSRange r;
        NSDictionary *attrs = [self attributesAtIndex:i effectiveRange:&r];
        NSUInteger end = MIN(NSMaxRange(r), len);
        [s appendString:[str substringWithRange:NSMakeRange(i, end - i)]];
        [s appendString:[attrs count] ? [attrs description] : @"{\n}"];
        i = end;
    }
    return s;
}

- (void)enumerateAttributesInRange:(NSRange)enumerationRange options:(NSAttributedStringEnumerationOptions)opts
                        usingBlock:(void (NS_NOESCAPE ^)(NSDictionary<NSAttributedStringKey, id> *, NSRange, BOOL *))block
{
    check_range(self, _cmd, enumerationRange);
    BOOL longest = !(opts & NSAttributedStringEnumerationLongestEffectiveRangeNotRequired);
    NSMutableArray *runs = [NSMutableArray array];
    for (NSUInteger i = enumerationRange.location; i < NSMaxRange(enumerationRange);) {
        NSRange r;
        NSDictionary *attrs = longest ? [self attributesAtIndex:i longestEffectiveRange:&r inRange:enumerationRange]
                                      : [self attributesAtIndex:i effectiveRange:&r];
        NSUInteger end = MIN(NSMaxRange(r), NSMaxRange(enumerationRange));
        [runs addObject:@[ attrs ? attrs : @{}, [NSValue valueWithRange:NSMakeRange(i, end - i)] ]];
        i = end;
    }
    NSEnumerator *e = (opts & NSAttributedStringEnumerationReverse) ? [runs reverseObjectEnumerator] : [runs objectEnumerator];
    BOOL stop = NO;
    for (NSArray *run in e) {
        block([run objectAtIndex:0], [[run objectAtIndex:1] rangeValue], &stop);
        if (stop) break;
    }
}

- (void)enumerateAttribute:(NSAttributedStringKey)attrName inRange:(NSRange)enumerationRange options:(NSAttributedStringEnumerationOptions)opts
                usingBlock:(void (NS_NOESCAPE ^)(id, NSRange, BOOL *))block
{
    check_range(self, _cmd, enumerationRange);
    BOOL longest = !(opts & NSAttributedStringEnumerationLongestEffectiveRangeNotRequired);
    NSMutableArray *runs = [NSMutableArray array];
    for (NSUInteger i = enumerationRange.location; i < NSMaxRange(enumerationRange);) {
        NSRange r;
        id v = longest ? [self attribute:attrName atIndex:i longestEffectiveRange:&r inRange:enumerationRange]
                       : [self attribute:attrName atIndex:i effectiveRange:&r];
        NSUInteger end = MIN(NSMaxRange(r), NSMaxRange(enumerationRange));
        [runs addObject:@[ v ? v : [NSNull null], [NSValue valueWithRange:NSMakeRange(i, end - i)] ]];
        i = end;
    }
    NSEnumerator *e = (opts & NSAttributedStringEnumerationReverse) ? [runs reverseObjectEnumerator] : [runs objectEnumerator];
    BOOL stop = NO;
    for (NSArray *run in e) {
        id v = [run objectAtIndex:0];
        block(v == [NSNull null] ? nil : v, [[run objectAtIndex:1] rangeValue], &stop);
        if (stop) break;
    }
}

/* MARK: Coding */

- (Class)classForCoder { return [NSAttributedString class]; }

static void
leb128(NSMutableData *d, NSUInteger v)
{
    do {
        uint8_t b = v & 0x7F;
        v >>= 7;
        if (v) b |= 0x80;
        [d appendBytes:&b length:1];
    } while (v);
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
        FinchRaise(NSInvalidArgumentException, "*** -[NSAttributedString encodeWithCoder:]: only keyed coders are supported");
    [coder encodeObject:[self string] forKey:@"NSString"];
    NSMutableArray *dicts = [NSMutableArray array];
    NSMutableData *info = [NSMutableData data];
    NSUInteger len = [self length], runs = 0;
    for (NSUInteger i = 0; i < len; runs++) {
        NSRange r;
        NSDictionary *attrs = [[[self attributesAtIndex:i effectiveRange:&r] copy] autorelease];
        if (!attrs) attrs = @{};
        NSUInteger index = [dicts indexOfObject:attrs];
        if (index == NSNotFound) { index = [dicts count]; [dicts addObject:attrs]; }
        NSUInteger end = MIN(NSMaxRange(r), len);
        leb128(info, end - i);
        leb128(info, index);
        i = end;
    }
    if (runs == 1) {
        [coder encodeObject:[dicts objectAtIndex:0] forKey:@"NSAttributes"];
    } else if (runs > 1) {
        [coder encodeObject:dicts forKey:@"NSAttributes"];
        [coder encodeObject:info forKey:@"NSAttributeInfo"];
    }
}

static BOOL
read_leb128(const uint8_t **p, const uint8_t *end, NSUInteger *out)
{
    NSUInteger v = 0;
    for (int shift = 0; *p < end && shift < 64; shift += 7) {
        uint8_t b = *(*p)++;
        v |= (NSUInteger)(b & 0x7F) << shift;
        if (!(b & 0x80)) { *out = v; return YES; }
    }
    return NO;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSet *values = [coder allowedClasses];
    NSSet *plist = [NSSet setWithObjects:[NSArray class], [NSDictionary class], [NSString class], [NSNumber class], [NSDate class],
        [NSData class], [NSURL class], [NSValue class], nil];
    NSSet *allowed = values ? [values setByAddingObjectsFromSet:plist] : plist;
    NSString *str = [coder decodeObjectOfClass:[NSString class] forKey:@"NSString"];
    id attrs = [coder decodeObjectOfClasses:allowed forKey:@"NSAttributes"];
    NSData *info = [coder decodeObjectOfClass:[NSData class] forKey:@"NSAttributeInfo"];
    if (!str) { [self release]; return nil; }
    NSMutableAttributedString *m = [[[NSMutableAttributedString alloc] initWithString:str] autorelease];
    if ([attrs isKindOfClass:[NSDictionary class]]) {
        [m setAttributes:attrs range:NSMakeRange(0, [str length])];
    } else if ([attrs isKindOfClass:[NSArray class]] && info) {
        const uint8_t *p = [info bytes], *end = p + [info length];
        NSUInteger at = 0;
        while (p < end) {
            NSUInteger n, index;
            if (!read_leb128(&p, end, &n) || !read_leb128(&p, end, &index) || index >= [attrs count] || at + n > [str length]) {
                [self release];
                return nil;
            }
            [m setAttributes:[attrs objectAtIndex:index] range:NSMakeRange(at, n)];
            at += n;
        }
    }
    return [self initWithAttributedString:m];
}

@end

/* MARK: - NSMutableAttributedString */

/* -mutableString: edits go through the attributed string. */
@interface NSMutableStringProxyForMutableAttributedString : NSMutableString {
    NSMutableAttributedString *_owner;
}
- (instancetype)initWithAttributedString:(NSMutableAttributedString *)owner;
@end

@implementation NSMutableStringProxyForMutableAttributedString
- (instancetype)initWithAttributedString:(NSMutableAttributedString *)owner
{
    if ((self = [super init])) _owner = [owner retain];
    return self;
}
- (void)dealloc { [_owner release]; [super dealloc]; }
- (NSUInteger)length { return [[_owner string] length]; }
- (unichar)characterAtIndex:(NSUInteger)index { return [[_owner string] characterAtIndex:index]; }
- (void)getCharacters:(unichar *)buffer range:(NSRange)range { [[_owner string] getCharacters:buffer range:range]; }
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)aString { [_owner replaceCharactersInRange:range withString:aString]; }
@end

@implementation NSMutableAttributedString

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)str { FinchAbstract(self, _cmd); }
- (void)setAttributes:(NSDictionary *)attrs range:(NSRange)range { FinchAbstract(self, _cmd); }

- (Class)classForCoder { return [NSMutableAttributedString class]; }

- (instancetype)initWithString:(NSString *)str
{
    return [self initWithString:str attributes:nil];
}

- (instancetype)initWithString:(NSString *)str attributes:(NSDictionary *)attrs
{
    if ((self = [self init])) {
        [self replaceCharactersInRange:NSMakeRange(0, 0) withString:str];
        if (attrs) [self setAttributes:attrs range:NSMakeRange(0, [str length])];
    }
    return self;
}

- (instancetype)initWithAttributedString:(NSAttributedString *)attrStr
{
    if ((self = [self init])) [self setAttributedString:attrStr];
    return self;
}

- (NSMutableString *)mutableString
{
    return [[[NSMutableStringProxyForMutableAttributedString alloc] initWithAttributedString:self] autorelease];
}

/* Change the attributes of each run in `range` with `edit`. */
static void
edit_runs(NSMutableAttributedString *self, NSRange range, void (^edit)(NSMutableDictionary *))
{
    [self beginEditing];
    for (NSUInteger i = range.location; i < NSMaxRange(range);) {
        NSRange r;
        NSMutableDictionary *attrs = [[[self attributesAtIndex:i effectiveRange:&r] mutableCopy] autorelease];
        if (!attrs) attrs = [NSMutableDictionary dictionary];
        NSUInteger end = MIN(NSMaxRange(r), NSMaxRange(range));
        edit(attrs);
        [self setAttributes:attrs range:NSMakeRange(i, end - i)];
        i = end;
    }
    [self endEditing];
}

- (void)addAttribute:(NSAttributedStringKey)name value:(id)value range:(NSRange)range
{
    if (!value) FinchRaise(NSInvalidArgumentException, "NSConcreteMutableAttributedString addAttribute:value:range: nil value");
    check_range(self, _cmd, range);
    edit_runs(self, range, ^(NSMutableDictionary *d) { [d setObject:value forKey:name]; });
}

- (void)addAttributes:(NSDictionary *)attrs range:(NSRange)range
{
    check_range(self, _cmd, range);
    edit_runs(self, range, ^(NSMutableDictionary *d) { [d addEntriesFromDictionary:attrs]; });
}

- (void)removeAttribute:(NSAttributedStringKey)name range:(NSRange)range
{
    check_range(self, _cmd, range);
    edit_runs(self, range, ^(NSMutableDictionary *d) { [d removeObjectForKey:name]; });
}

- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)attrString
{
    check_range(self, _cmd, range);
    [self beginEditing];
    [self replaceCharactersInRange:range withString:[attrString string]];
    NSUInteger len = [attrString length];
    for (NSUInteger i = 0; i < len;) {
        NSRange r;
        NSDictionary *attrs = [attrString attributesAtIndex:i effectiveRange:&r];
        NSUInteger end = MIN(NSMaxRange(r), len);
        [self setAttributes:attrs range:NSMakeRange(range.location + i, end - i)];
        i = end;
    }
    [self endEditing];
}

- (void)insertAttributedString:(NSAttributedString *)attrString atIndex:(NSUInteger)loc
{
    [self replaceCharactersInRange:NSMakeRange(loc, 0) withAttributedString:attrString];
}

- (void)appendAttributedString:(NSAttributedString *)attrString
{
    [self replaceCharactersInRange:NSMakeRange([self length], 0) withAttributedString:attrString];
}

- (void)deleteCharactersInRange:(NSRange)range
{
    [self replaceCharactersInRange:range withString:@""];
}

- (void)setAttributedString:(NSAttributedString *)attrString
{
    [self replaceCharactersInRange:NSMakeRange(0, [self length]) withAttributedString:attrString];
}

- (void)beginEditing { }
- (void)endEditing { }

@end

/* MARK: - Placeholders */

@implementation NSPlaceholderAttributedString

- (instancetype)retain { return self; }
- (oneway void)release { }
- (instancetype)autorelease { return self; }
- (NSUInteger)retainCount { return NSUIntegerMax; }
- (void)dealloc { FINCH_NO_SUPER_DEALLOC }

- (BOOL)isMutablePlaceholder { return self == mutable_placeholder; }

- (instancetype)init { return [self initWithString:@"" attributes:nil]; }
- (instancetype)initWithString:(NSString *)str { return [self initWithString:str attributes:nil]; }

- (instancetype)initWithString:(NSString *)str attributes:(NSDictionary *)attrs
{
    if (!str) FinchRaise(NSInvalidArgumentException, "NSConcreteAttributedString initWithString:: nil value");
    if (![self isMutablePlaceholder])
        return (id)CFAttributedStringCreate(NULL, (CFStringRef)str, (CFDictionaryRef)(attrs ? attrs : @{}));
    CFMutableAttributedStringRef m = CFAttributedStringCreateMutable(NULL, 0);
    CFAttributedStringReplaceString(m, CFRangeMake(0, 0), (CFStringRef)str);
    if (attrs) CFAttributedStringSetAttributes(m, CFRangeMake(0, (CFIndex)[str length]), (CFDictionaryRef)attrs, true);
    return (id)m;
}

/*
 * A format's literal text keeps its attributes; each value takes the attributes at its
 * specifier. Finch maps the text before the first specifier and after the last; between
 * them the result takes the attributes at the first specifier.
 */
- (instancetype)initWithFormat:(NSAttributedString *)format options:(NSAttributedStringFormattingOptions)options
                        locale:(NSLocale *)locale arguments:(va_list)arguments
{
    NSString *f = [format string];
    NSString *out = [[[NSString alloc] initWithFormat:f locale:locale arguments:arguments] autorelease];
    NSRange first = [f rangeOfString:@"%"];
    while (first.location != NSNotFound && first.location + 1 < [f length] && [f characterAtIndex:first.location + 1] == '%')
        first = [f rangeOfString:@"%" options:0 range:NSMakeRange(first.location + 2, [f length] - first.location - 2)];
    CFMutableAttributedStringRef m = CFAttributedStringCreateMutable(NULL, 0);
    CFAttributedStringReplaceString(m, CFRangeMake(0, 0), (CFStringRef)out);
    NSUInteger flen = [f length], olen = [out length];
    if (flen && olen) {
        NSUInteger prefix = first.location == NSNotFound ? MIN(flen, olen) : MIN(first.location, olen);
        /* the literal suffix after the last specifier: as long as format and result agree from the end */
        NSUInteger suffix = 0;
        while (suffix < flen - prefix && suffix < olen - prefix &&
               [f characterAtIndex:flen - 1 - suffix] == [out characterAtIndex:olen - 1 - suffix] &&
               [f characterAtIndex:flen - 1 - suffix] != '%')
            suffix++;
        NSDictionary *middle = [format attributesAtIndex:MIN(prefix, flen - 1) effectiveRange:NULL] ?: @{};
        CFAttributedStringSetAttributes(m, CFRangeMake(0, (CFIndex)olen), (CFDictionaryRef)middle, true);
        for (NSUInteger i = 0; i < prefix;) {
            NSRange r;
            NSDictionary *a = [format attributesAtIndex:i effectiveRange:&r];
            NSUInteger end = MIN(NSMaxRange(r), prefix);
            CFAttributedStringSetAttributes(m, CFRangeMake((CFIndex)i, (CFIndex)(end - i)), (CFDictionaryRef)(a ?: @{}), true);
            i = end;
        }
        for (NSUInteger k = 0; k < suffix;) {
            NSRange r;
            NSUInteger fi = flen - suffix + k;
            NSDictionary *a = [format attributesAtIndex:fi effectiveRange:&r];
            NSUInteger n = MIN(NSMaxRange(r), flen) - fi;
            CFAttributedStringSetAttributes(m, CFRangeMake((CFIndex)(olen - suffix + k), (CFIndex)n), (CFDictionaryRef)(a ?: @{}), true);
            k += n;
        }
    }
    if ([self isMutablePlaceholder]) return (id)m;
    CFAttributedStringRef copy = CFAttributedStringCreateCopy(NULL, m);
    CFRelease(m);
    return (id)copy;
}

- (instancetype)initWithAttributedString:(NSAttributedString *)attrStr
{
    CFMutableAttributedStringRef m = CFAttributedStringCreateMutable(NULL, 0);
    CFAttributedStringReplaceString(m, CFRangeMake(0, 0), (CFStringRef)[attrStr string]);
    NSUInteger len = [attrStr length];
    for (NSUInteger i = 0; i < len;) {
        NSRange r;
        NSDictionary *attrs = [attrStr attributesAtIndex:i effectiveRange:&r];
        NSUInteger end = MIN(NSMaxRange(r), len);
        CFAttributedStringSetAttributes(m, CFRangeMake((CFIndex)i, (CFIndex)(end - i)), (CFDictionaryRef)(attrs ? attrs : @{}), true);
        i = end;
    }
    if ([self isMutablePlaceholder]) return (id)m;
    CFAttributedStringRef copy = CFAttributedStringCreateCopy(NULL, m);
    CFRelease(m);
    return (id)copy;
}

@end
