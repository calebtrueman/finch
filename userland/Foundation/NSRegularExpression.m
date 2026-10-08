/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSRegularExpression, NSTextCheckingResult and NSDataDetector
 * (docs/design/FOUNDATION.md), against the SDK's headers, over CF's ICU
 * regular expressions (CFRegularExpression.c). NSString's
 * NSRegularExpressionSearch option comes through here too.
 *
 * NSDataDetector finds links (URLs and email addresses) and phone numbers
 * with Finch's own patterns. Apple's detector is the closed DataDetectorsCore;
 * dates, addresses and transit information are not detected yet.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

typedef const struct ___CFRegularExpression *_CFRegularExpressionRef;
typedef void (*_CFRegularExpressionMatch)(void *context, CFRange *ranges, CFIndex count, CFOptionFlags flags, Boolean *stop);
CF_EXPORT CFStringRef _CFRegularExpressionCreateEscapedPattern(CFStringRef pattern);
CF_EXPORT _CFRegularExpressionRef _CFRegularExpressionCreate(CFAllocatorRef, CFStringRef, CFOptionFlags, CFErrorRef *);
CF_EXPORT CFIndex _CFRegularExpressionGetNumberOfCaptureGroups(_CFRegularExpressionRef);
CF_EXPORT CFIndex _CFRegularExpressionGetCaptureGroupNumberWithName(_CFRegularExpressionRef, CFStringRef);
CF_EXPORT void _CFRegularExpressionEnumerateMatchesInString(_CFRegularExpressionRef, CFStringRef, CFOptionFlags, CFRange, void *, _CFRegularExpressionMatch);

NSTextCheckingKey const NSTextCheckingNameKey = @"Name";
NSTextCheckingKey const NSTextCheckingJobTitleKey = @"JobTitle";
NSTextCheckingKey const NSTextCheckingOrganizationKey = @"Organization";
NSTextCheckingKey const NSTextCheckingStreetKey = @"Street";
NSTextCheckingKey const NSTextCheckingCityKey = @"City";
NSTextCheckingKey const NSTextCheckingStateKey = @"State";
NSTextCheckingKey const NSTextCheckingZIPKey = @"ZIP";
NSTextCheckingKey const NSTextCheckingCountryKey = @"Country";
NSTextCheckingKey const NSTextCheckingPhoneKey = @"Phone";
NSTextCheckingKey const NSTextCheckingAirlineKey = @"Airline";
NSTextCheckingKey const NSTextCheckingFlightKey = @"Flight";

@interface NSRegularExpression (FinchPrivate)
- (NSUInteger)_finchGroupNumberWithName:(NSString *)name;
@end

/* MARK: - NSTextCheckingResult */

/* Every kind of result, named as Apple's concrete classes are in
 * descriptions. */
@interface _NSConcreteTextCheckingResult : NSTextCheckingResult {
@public
    NSTextCheckingType _type;
    NSRange *_ranges;
    NSUInteger _count;
    NSRegularExpression *_regex;
    NSDate *_date;
    NSTimeZone *_timeZone;
    NSTimeInterval _duration;
    NSURL *_URL;
    NSString *_replacement, *_phoneNumber;
    NSArray *_alternatives, *_grammarDetails;
    NSDictionary *_components;
    NSOrthography *_orthography;
}
@end

/* Apple's class names for each kind of result. */
#define RESULT_CLASS(NAME) @interface NAME : _NSConcreteTextCheckingResult @end @implementation NAME @end
RESULT_CLASS(NSSimpleRegularExpressionCheckingResult)
RESULT_CLASS(NSLinkCheckingResult)
RESULT_CLASS(NSDateCheckingResult)
RESULT_CLASS(NSAddressCheckingResult)
RESULT_CLASS(NSPhoneNumberCheckingResult)
RESULT_CLASS(NSSpellCheckingResult)
RESULT_CLASS(NSGrammarCheckingResult)
RESULT_CLASS(NSOrthographyCheckingResult)
RESULT_CLASS(NSTransitInformationCheckingResult)
RESULT_CLASS(NSSubstitutionCheckingResult)

@implementation NSTextCheckingResult

+ (BOOL)supportsSecureCoding { return YES; }
- (NSTextCheckingType)resultType { FinchAbstract(self, _cmd); }
- (NSRange)range { return [self rangeAtIndex:0]; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (void)encodeWithCoder:(NSCoder *)coder { }
- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }

- (NSOrthography *)orthography { return nil; }
- (NSArray *)grammarDetails { return nil; }
- (NSDate *)date { return nil; }
- (NSTimeZone *)timeZone { return nil; }
- (NSTimeInterval)duration { return 0; }
- (NSDictionary *)components { return nil; }
- (NSURL *)URL { return nil; }
- (NSString *)replacementString { return nil; }
- (NSArray *)alternativeStrings { return nil; }
- (NSRegularExpression *)regularExpression { return nil; }
- (NSString *)phoneNumber { return nil; }
- (NSUInteger)numberOfRanges { return 1; }
- (NSRange)rangeAtIndex:(NSUInteger)idx { FinchAbstract(self, _cmd); }
- (NSRange)rangeWithName:(NSString *)name { return NSMakeRange(NSNotFound, 0); }
- (NSDictionary *)addressComponents { return [self resultType] == NSTextCheckingTypeAddress ? [self components] : nil; }
- (NSTextCheckingResult *)resultByAdjustingRangesWithOffset:(NSInteger)offset { return self; }

static const char *class_name_for(NSTextCheckingType type);

static _NSConcreteTextCheckingResult *
result(NSTextCheckingType type, NSRange range)
{
    _NSConcreteTextCheckingResult *r = [[[objc_getClass(class_name_for(type)) alloc] init] autorelease];
    r->_type = type;
    r->_count = 1;
    r->_ranges = malloc(sizeof(NSRange));
    r->_ranges[0] = range;
    return r;
}

+ (NSTextCheckingResult *)orthographyCheckingResultWithRange:(NSRange)range orthography:(NSOrthography *)orthography
{
    _NSConcreteTextCheckingResult *r = result(NSTextCheckingTypeOrthography, range);
    r->_orthography = [orthography copy];
    return r;
}
+ (NSTextCheckingResult *)spellCheckingResultWithRange:(NSRange)range { return result(NSTextCheckingTypeSpelling, range); }
+ (NSTextCheckingResult *)grammarCheckingResultWithRange:(NSRange)range details:(NSArray *)details
{
    _NSConcreteTextCheckingResult *r = result(NSTextCheckingTypeGrammar, range);
    r->_grammarDetails = [details copy];
    return r;
}
+ (NSTextCheckingResult *)dateCheckingResultWithRange:(NSRange)range date:(NSDate *)date
{
    return [self dateCheckingResultWithRange:range date:date timeZone:(NSTimeZone *_Nonnull)(id)nil duration:0];
}
+ (NSTextCheckingResult *)dateCheckingResultWithRange:(NSRange)range date:(NSDate *)date timeZone:(NSTimeZone *)timeZone duration:(NSTimeInterval)duration
{
    _NSConcreteTextCheckingResult *r = result(NSTextCheckingTypeDate, range);
    r->_date = [date copy];
    r->_timeZone = [timeZone copy];
    r->_duration = duration;
    return r;
}
+ (NSTextCheckingResult *)addressCheckingResultWithRange:(NSRange)range components:(NSDictionary *)components
{
    _NSConcreteTextCheckingResult *r = result(NSTextCheckingTypeAddress, range);
    r->_components = [components copy];
    return r;
}
+ (NSTextCheckingResult *)linkCheckingResultWithRange:(NSRange)range URL:(NSURL *)url
{
    _NSConcreteTextCheckingResult *r = result(NSTextCheckingTypeLink, range);
    r->_URL = [url copy];
    return r;
}
static NSTextCheckingResult *
substitution(NSTextCheckingType type, NSRange range, NSString *replacement, NSArray *alternatives)
{
    _NSConcreteTextCheckingResult *r = result(type, range);
    r->_replacement = [replacement copy];
    r->_alternatives = [alternatives copy];
    return r;
}
+ (NSTextCheckingResult *)quoteCheckingResultWithRange:(NSRange)range replacementString:(NSString *)s { return substitution(NSTextCheckingTypeQuote, range, s, nil); }
+ (NSTextCheckingResult *)dashCheckingResultWithRange:(NSRange)range replacementString:(NSString *)s { return substitution(NSTextCheckingTypeDash, range, s, nil); }
+ (NSTextCheckingResult *)replacementCheckingResultWithRange:(NSRange)range replacementString:(NSString *)s { return substitution(NSTextCheckingTypeReplacement, range, s, nil); }
+ (NSTextCheckingResult *)correctionCheckingResultWithRange:(NSRange)range replacementString:(NSString *)s { return substitution(NSTextCheckingTypeCorrection, range, s, nil); }
+ (NSTextCheckingResult *)correctionCheckingResultWithRange:(NSRange)range replacementString:(NSString *)s alternativeStrings:(NSArray *)a
{
    return substitution(NSTextCheckingTypeCorrection, range, s, a);
}
+ (NSTextCheckingResult *)regularExpressionCheckingResultWithRanges:(NSRangePointer)ranges count:(NSUInteger)count regularExpression:(NSRegularExpression *)regex
{
    _NSConcreteTextCheckingResult *r = result(NSTextCheckingTypeRegularExpression, count ? ranges[0] : NSMakeRange(NSNotFound, 0));
    if (count > 1) {
        r->_ranges = realloc(r->_ranges, count * sizeof(NSRange));
        memcpy(r->_ranges, ranges, count * sizeof(NSRange));
    }
    r->_count = count ? count : 1;
    r->_regex = [regex retain];
    return r;
}
+ (NSTextCheckingResult *)phoneNumberCheckingResultWithRange:(NSRange)range phoneNumber:(NSString *)phoneNumber
{
    _NSConcreteTextCheckingResult *r = result(NSTextCheckingTypePhoneNumber, range);
    r->_phoneNumber = [phoneNumber copy];
    return r;
}
+ (NSTextCheckingResult *)transitInformationCheckingResultWithRange:(NSRange)range components:(NSDictionary *)components
{
    _NSConcreteTextCheckingResult *r = result(NSTextCheckingTypeTransitInformation, range);
    r->_components = [components copy];
    return r;
}

@end

@implementation _NSConcreteTextCheckingResult

- (void)dealloc
{
    free(_ranges);
    [_regex release];
    [_date release];
    [_timeZone release];
    [_URL release];
    [_replacement release];
    [_phoneNumber release];
    [_alternatives release];
    [_grammarDetails release];
    [_components release];
    [_orthography release];
    [super dealloc];
}

- (NSTextCheckingType)resultType { return _type; }
- (NSRange)range { return _ranges[0]; }
- (NSUInteger)numberOfRanges { return _count; }
- (NSRange)rangeAtIndex:(NSUInteger)idx
{
    if (idx >= _count)
        FinchRaise(NSRangeException, "-[%s rangeAtIndex:]: index %lu out of bounds", object_getClassName(self), (unsigned long)idx);
    return _ranges[idx];
}
- (NSRange)rangeWithName:(NSString *)name
{
    if (!_regex) return NSMakeRange(NSNotFound, 0);
    NSUInteger group = [_regex _finchGroupNumberWithName:name];
    return group < _count ? _ranges[group] : NSMakeRange(NSNotFound, 0);
}
- (NSRegularExpression *)regularExpression { return _regex; }
- (NSDate *)date { return _date; }
- (NSTimeZone *)timeZone { return _timeZone; }
- (NSTimeInterval)duration { return _duration; }
- (NSURL *)URL { return _URL; }
- (NSString *)replacementString { return _replacement; }
- (NSString *)phoneNumber { return _phoneNumber; }
- (NSArray *)alternativeStrings { return _alternatives; }
- (NSArray *)grammarDetails { return _grammarDetails; }
- (NSDictionary *)components { return _components; }
- (NSOrthography *)orthography { return _orthography; }

- (NSTextCheckingResult *)resultByAdjustingRangesWithOffset:(NSInteger)offset
{
    _NSConcreteTextCheckingResult *r = [[[[self class] alloc] init] autorelease];
    r->_type = _type;
    r->_count = _count;
    r->_ranges = malloc(_count * sizeof(NSRange));
    for (NSUInteger i = 0; i < _count; i++) {
        NSRange g = _ranges[i];
        if (g.location != NSNotFound) {
            if (offset < 0 && (NSUInteger)-offset > g.location)
                FinchRaise(NSInvalidArgumentException, "-[%s resultByAdjustingRangesWithOffset:]: offset %ld invalid for range {%lu, %lu}",
                    object_getClassName(self), (long)offset, (unsigned long)g.location, (unsigned long)g.length);
            g.location = (NSUInteger)((NSInteger)g.location + offset);
        }
        r->_ranges[i] = g;
    }
    r->_regex = [_regex retain];
    r->_date = [_date copy];
    r->_timeZone = [_timeZone copy];
    r->_duration = _duration;
    r->_URL = [_URL copy];
    r->_replacement = [_replacement copy];
    r->_phoneNumber = [_phoneNumber copy];
    r->_alternatives = [_alternatives copy];
    r->_grammarDetails = [_grammarDetails copy];
    r->_components = [_components copy];
    r->_orthography = [_orthography copy];
    return r;
}

static const char *
class_name_for(NSTextCheckingType type)
{
    switch (type) {
    case NSTextCheckingTypeRegularExpression: return "NSSimpleRegularExpressionCheckingResult";
    case NSTextCheckingTypeLink: return "NSLinkCheckingResult";
    case NSTextCheckingTypeDate: return "NSDateCheckingResult";
    case NSTextCheckingTypeAddress: return "NSAddressCheckingResult";
    case NSTextCheckingTypePhoneNumber: return "NSPhoneNumberCheckingResult";
    case NSTextCheckingTypeSpelling: return "NSSpellCheckingResult";
    case NSTextCheckingTypeGrammar: return "NSGrammarCheckingResult";
    case NSTextCheckingTypeOrthography: return "NSOrthographyCheckingResult";
    case NSTextCheckingTypeTransitInformation: return "NSTransitInformationCheckingResult";
    default: return "NSSubstitutionCheckingResult";
    }
}

/* Apple's: "<NSSimpleRegularExpressionCheckingResult: 0x...>{5, 8}{<regex>}". */
- (NSString *)description
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"<%s: %p>{%lu, %lu}", class_name_for(_type), self,
        (unsigned long)_ranges[0].location, (unsigned long)_ranges[0].length];
    id detail = _regex ? (id)_regex : _URL ? (id)_URL : _replacement ? (id)_replacement : _phoneNumber ? (id)_phoneNumber :
        _date ? (id)_date : _components;
    if (detail) [s appendFormat:@"{%@}", detail];
    return s;
}

@end

/* MARK: - NSRegularExpression */

static NSError *
invalid(NSString *pattern)
{
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFormattingError userInfo:@{ @"NSInvalidValue": pattern ? pattern : @"" }];
}

@implementation NSRegularExpression

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSRegularExpression *)regularExpressionWithPattern:(NSString *)pattern options:(NSRegularExpressionOptions)options error:(NSError **)error
{
    return [[[self alloc] initWithPattern:pattern options:options error:error] autorelease];
}

- (instancetype)init { return [self initWithPattern:@"" options:0 error:NULL]; }

- (instancetype)initWithPattern:(NSString *)pattern options:(NSRegularExpressionOptions)options error:(NSError **)error
{
    if (!pattern) FinchRaise(NSInvalidArgumentException, "*** -[NSRegularExpression initWithPattern:options:error:]: nil argument");
    if ((self = [super init])) {
        CFErrorRef cfError = NULL;
        _internal = (void *)_CFRegularExpressionCreate(NULL, (CFStringRef)pattern, (CFOptionFlags)options, &cfError);
        if (cfError) CFRelease(cfError);
        if (!_internal) {
            if (error) *error = invalid(pattern);
            [self release];
            return nil;
        }
        _pattern = [pattern copy];
        _options = options;
    }
    return self;
}

- (void)dealloc
{
    if (_internal) CFRelease((CFTypeRef)_internal);   /* a CF object */
    [_pattern release];
    [super dealloc];
}

- (NSString *)pattern { return _pattern; }
- (NSRegularExpressionOptions)options { return _options; }
- (NSUInteger)numberOfCaptureGroups { return (NSUInteger)_CFRegularExpressionGetNumberOfCaptureGroups((_CFRegularExpressionRef)_internal); }

- (NSUInteger)_finchGroupNumberWithName:(NSString *)name
{
    CFIndex n = _CFRegularExpressionGetCaptureGroupNumberWithName((_CFRegularExpressionRef)_internal, (CFStringRef)name);
    return n < 0 ? NSNotFound : (NSUInteger)n;
}

+ (NSString *)escapedPatternForString:(NSString *)string
{
    return [(NSString *)_CFRegularExpressionCreateEscapedPattern((CFStringRef)string) autorelease];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (BOOL)isEqual:(id)object
{
    if (object == self) return YES;
    if (![object isKindOfClass:[NSRegularExpression class]]) return NO;
    return [_pattern isEqualToString:[object pattern]] && _options == [object options];
}
- (NSUInteger)hash { return [_pattern hash] ^ _options; }

/* Apple's: "<NSRegularExpression: 0x...> pattern 0x<options>". */
- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s: %p> %@ 0x%lx", object_getClassName(self), self, _pattern, (unsigned long)_options];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_pattern forKey:@"NSPattern"];
    [coder encodeInt64:(int64_t)_options forKey:@"NSOptions"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *pattern = [coder decodeObjectOfClass:[NSString class] forKey:@"NSPattern"];
    if (!pattern) { [self release]; return nil; }
    return [self initWithPattern:pattern options:(NSRegularExpressionOptions)[coder decodeInt64ForKey:@"NSOptions"] error:NULL];
}

@end

typedef struct {
    NSRegularExpression *regex;
    void (^block)(NSTextCheckingResult *, NSMatchingFlags, BOOL *);
} MatchContext;

static void
on_match(void *context, CFRange *ranges, CFIndex count, CFOptionFlags flags, Boolean *stop)
{
    MatchContext *m = context;
    NSTextCheckingResult *r = nil;
    if (ranges && count > 0) {
        NSRange *nr = malloc((size_t)count * sizeof(NSRange));
        for (CFIndex i = 0; i < count; i++)
            nr[i] = ranges[i].location == kCFNotFound ? NSMakeRange(NSNotFound, 0) : NSMakeRange((NSUInteger)ranges[i].location, (NSUInteger)ranges[i].length);
        r = [NSTextCheckingResult regularExpressionCheckingResultWithRanges:nr count:(NSUInteger)count regularExpression:m->regex];
        free(nr);
    }
    BOOL s = NO;
    @autoreleasepool {
        m->block(r, (NSMatchingFlags)flags, &s);
    }
    if (s) *stop = true;
}

@implementation NSRegularExpression (NSMatching)

static void
check_string_range(id self, SEL _cmd, NSString *string, NSRange range)
{
    if (!string) FinchRaise(NSInvalidArgumentException, "*** -[%s %s]: nil argument", object_getClassName(self), sel_getName(_cmd));
    if (range.location > [string length] || range.length > [string length] - range.location)
        FinchRaise(NSRangeException, "*** -[%s %s]: Range or index out of bounds", object_getClassName(self), sel_getName(_cmd));
}

- (void)enumerateMatchesInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range
                      usingBlock:(void (NS_NOESCAPE ^)(NSTextCheckingResult *, NSMatchingFlags, BOOL *))block
{
    check_string_range(self, _cmd, string, range);
    MatchContext m = { self, block };
    _CFRegularExpressionEnumerateMatchesInString((_CFRegularExpressionRef)_internal, (CFStringRef)string, (CFOptionFlags)options,
        CFRangeMake((CFIndex)range.location, (CFIndex)range.length), &m, on_match);
}

- (NSArray *)matchesInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range
{
    NSMutableArray *a = [NSMutableArray array];
    [self enumerateMatchesInString:string options:options & ~(NSMatchingReportProgress | NSMatchingReportCompletion) range:range
                        usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags flags, BOOL *stop) { if (r) [a addObject:r]; }];
    return a;
}

- (NSUInteger)numberOfMatchesInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range
{
    __block NSUInteger n = 0;
    [self enumerateMatchesInString:string options:options & ~(NSMatchingReportProgress | NSMatchingReportCompletion) range:range
                        usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags flags, BOOL *stop) { if (r) n++; }];
    return n;
}

- (NSTextCheckingResult *)firstMatchInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range
{
    __block NSTextCheckingResult *first = nil;
    [self enumerateMatchesInString:string options:options & ~(NSMatchingReportProgress | NSMatchingReportCompletion) range:range
                        usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags flags, BOOL *stop) {
        if (r) { first = [r retain]; *stop = YES; }
    }];
    return [first autorelease];
}

- (NSRange)rangeOfFirstMatchInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range
{
    NSTextCheckingResult *r = [self firstMatchInString:string options:options range:range];
    return r ? [r range] : NSMakeRange(NSNotFound, 0);
}

@end

@implementation NSRegularExpression (NSReplacement)

/* $0-$99 for capture groups (as many digits as name a group), \ to escape. */
- (NSString *)replacementStringForResult:(NSTextCheckingResult *)result inString:(NSString *)string offset:(NSInteger)offset template:(NSString *)templ
{
    NSMutableString *out = [NSMutableString string];
    NSUInteger n = [templ length], groups = [result numberOfRanges];
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [templ characterAtIndex:i];
        if (c == '\\' && i + 1 < n) {
            [out appendFormat:@"%C", [templ characterAtIndex:++i]];
        } else if (c == '$' && i + 1 < n && [templ characterAtIndex:i + 1] >= '0' && [templ characterAtIndex:i + 1] <= '9') {
            NSUInteger group = (NSUInteger)([templ characterAtIndex:++i] - '0');
            while (i + 1 < n && [templ characterAtIndex:i + 1] >= '0' && [templ characterAtIndex:i + 1] <= '9') {
                NSUInteger more = group * 10 + (NSUInteger)([templ characterAtIndex:i + 1] - '0');
                if (more >= groups) break;
                group = more;
                i++;
            }
            if (group < groups) {
                NSRange r = [result rangeAtIndex:group];
                if (r.location != NSNotFound) {
                    r.location = (NSUInteger)((NSInteger)r.location + offset);
                    [out appendString:[string substringWithRange:r]];
                }
            }
        } else {
            [out appendFormat:@"%C", c];
        }
    }
    return out;
}

- (NSUInteger)replaceMatchesInString:(NSMutableString *)string options:(NSMatchingOptions)options range:(NSRange)range withTemplate:(NSString *)templ
{
    NSArray *matches = [self matchesInString:string options:options range:range];
    NSInteger offset = 0;
    NSString *original = [[string copy] autorelease];
    for (NSTextCheckingResult *r in matches) {
        NSString *rep = [self replacementStringForResult:r inString:original offset:0 template:templ];
        NSRange at = [r range];
        at.location = (NSUInteger)((NSInteger)at.location + offset);
        [string replaceCharactersInRange:at withString:rep];
        offset += (NSInteger)[rep length] - (NSInteger)[r range].length;
    }
    return [matches count];
}

- (NSString *)stringByReplacingMatchesInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range withTemplate:(NSString *)templ
{
    NSMutableString *m = [[string mutableCopy] autorelease];
    [self replaceMatchesInString:m options:options range:range withTemplate:templ];
    return [NSString stringWithString:m];
}

+ (NSString *)escapedTemplateForString:(NSString *)string
{
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < [string length]; i++) {
        unichar c = [string characterAtIndex:i];
        if (c == '$' || c == '\\') [out appendString:@"\\"];
        [out appendFormat:@"%C", c];
    }
    return out;
}

@end

/* MARK: - NSDataDetector */

@implementation NSDataDetector

static NSString *
detector_pattern(NSTextCheckingTypes types)
{
    NSMutableArray *alts = [NSMutableArray array];
    if (types & NSTextCheckingTypeLink) {
        [alts addObject:@"(?<email>[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,})"];
        [alts addObject:@"(?<url>(?:[A-Za-z][A-Za-z0-9+.-]*://|www\\.)[^\\s<>\"]+[^\\s<>\".,;:!?)\\]'])"];
    }
    if (types & NSTextCheckingTypePhoneNumber)
        [alts addObject:@"(?<phone>(?:\\+\\d{1,3}[\\s.-]?)?(?:\\(\\d{2,4}\\)|\\d{2,4})[\\s.-]?\\d{3}[\\s.-]?\\d{3,4})"];
    return [alts count] ? [alts componentsJoinedByString:@"|"] : @"(?!)";
}

+ (NSDataDetector *)dataDetectorWithTypes:(NSTextCheckingTypes)checkingTypes error:(NSError **)error
{
    return [[[self alloc] initWithTypes:checkingTypes error:error] autorelease];
}

- (instancetype)initWithTypes:(NSTextCheckingTypes)checkingTypes error:(NSError **)error
{
    if ((self = [super initWithPattern:detector_pattern(checkingTypes) options:0 error:error])) _types = checkingTypes;
    return self;
}

- (instancetype)initWithPattern:(NSString *)pattern options:(NSRegularExpressionOptions)options error:(NSError **)error
{
    return [super initWithPattern:pattern options:options error:error];
}

- (NSTextCheckingTypes)checkingTypes { return _types; }

- (void)enumerateMatchesInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range
                      usingBlock:(void (NS_NOESCAPE ^)(NSTextCheckingResult *, NSMatchingFlags, BOOL *))block
{
    NSUInteger email = [self _finchGroupNumberWithName:@"email"], url = [self _finchGroupNumberWithName:@"url"];
    NSUInteger phone = [self _finchGroupNumberWithName:@"phone"];
    [super enumerateMatchesInString:string options:options range:range usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags flags, BOOL *stop) {
        NSTextCheckingResult *out = nil;
        if (r) {
            NSUInteger groups = [r numberOfRanges];
            NSString *text = [string substringWithRange:[r range]];
            if (email != NSNotFound && email < groups && [r rangeAtIndex:email].location != NSNotFound) {
                out = [NSTextCheckingResult linkCheckingResultWithRange:[r range] URL:[NSURL URLWithString:[@"mailto:" stringByAppendingString:text]]];
            } else if (url != NSNotFound && url < groups && [r rangeAtIndex:url].location != NSNotFound) {
                NSString *u = [text hasPrefix:@"www."] ? [@"http://" stringByAppendingString:text] : text;
                out = [NSTextCheckingResult linkCheckingResultWithRange:[r range] URL:[NSURL URLWithString:u]];
            } else if (phone != NSNotFound && phone < groups && [r rangeAtIndex:phone].location != NSNotFound) {
                out = [NSTextCheckingResult phoneNumberCheckingResultWithRange:[r range] phoneNumber:text];
            }
        }
        if (out || !r) block(out, flags, stop);
    }];
}

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeInt64:(int64_t)_types forKey:@"NSTypes"]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithTypes:(NSTextCheckingTypes)[coder decodeInt64ForKey:@"NSTypes"] error:NULL]; }

@end

/* MARK: - NSString's regular-expression search */

NSRange
FinchRegexRange(NSString *string, NSString *pattern, NSStringCompareOptions mask, NSRange range)
{
    NSRegularExpressionOptions opts = (mask & NSCaseInsensitiveSearch) ? NSRegularExpressionCaseInsensitive : 0;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:opts error:NULL];
    if (!re) return NSMakeRange(NSNotFound, 0);
    NSMatchingOptions m = (mask & NSAnchoredSearch) ? NSMatchingAnchored : 0;
    if (mask & NSBackwardsSearch) {
        NSArray *all = [re matchesInString:string options:m range:range];
        return [all count] ? [[all lastObject] range] : NSMakeRange(NSNotFound, 0);
    }
    return [re rangeOfFirstMatchInString:string options:m range:range];
}

NSUInteger
FinchRegexReplace(NSMutableString *string, NSString *pattern, NSString *templ, NSStringCompareOptions mask, NSRange range)
{
    NSRegularExpressionOptions opts = (mask & NSCaseInsensitiveSearch) ? NSRegularExpressionCaseInsensitive : 0;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:opts error:NULL];
    if (!re) return 0;
    return [re replaceMatchesInString:string options:(mask & NSAnchoredSearch) ? NSMatchingAnchored : 0 range:range withTemplate:templ];
}
