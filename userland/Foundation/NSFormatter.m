/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSFormatter, NSDateFormatter and NSNumberFormatter
 * (docs/design/FOUNDATION.md), against the SDK's declarations, over
 * CFDateFormatter and CFNumberFormatter (ICU underneath, as Apple's). A CF
 * formatter's style is fixed when it's made, so these keep their settings
 * and make the CF formatter again when the style or locale changes.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"

@implementation NSFormatter
- (NSString *)stringForObjectValue:(id)obj { FinchAbstract(self, _cmd); }
- (NSAttributedString *)attributedStringForObjectValue:(id)obj withDefaultAttributes:(NSDictionary *)attrs { return nil; }
- (NSString *)editingStringForObjectValue:(id)obj { return [self stringForObjectValue:obj]; }
- (BOOL)getObjectValue:(out id *)obj forString:(NSString *)string errorDescription:(out NSString **)error { FinchAbstract(self, _cmd); }
- (BOOL)isPartialStringValid:(NSString *)partial newEditingString:(NSString **)newString errorDescription:(NSString **)error { return YES; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (instancetype)initWithCoder:(NSCoder *)c { return [self init]; }
- (void)encodeWithCoder:(NSCoder *)c { }
@end

/* MARK: - NSDateFormatter */

@implementation NSDateFormatter {
    CFDateFormatterRef _f;
    NSLocale *_locale;
    NSTimeZone *_timeZone;
    NSCalendar *_calendar;
    NSString *_format;
    NSDateFormatterStyle _dateStyle, _timeStyle;
    BOOL _lenient, _relative;
    NSDate *_defaultDate;
    NSMutableDictionary *_properties;   /* CF property -> value, re-applied after remaking */
}

- (instancetype)init
{
    if ((self = [super init])) _properties = [[NSMutableDictionary alloc] init];
    return self;
}

- (void)dealloc
{
    if (_f) CFRelease(_f);
    [_locale release];
    [_timeZone release];
    [_calendar release];
    [_format release];
    [_defaultDate release];
    [_properties release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSDateFormatter *c = [[NSDateFormatter alloc] init];
    c->_locale = [_locale retain];
    c->_timeZone = [_timeZone retain];
    c->_calendar = [_calendar copy];
    c->_format = [_format copy];
    c->_dateStyle = _dateStyle;
    c->_timeStyle = _timeStyle;
    c->_lenient = _lenient;
    c->_defaultDate = [_defaultDate retain];
    [c->_properties addEntriesFromDictionary:_properties];
    return c;
}

- (void)_finchInvalidate
{
    if (_f) CFRelease(_f);
    _f = NULL;
}

- (CFDateFormatterRef)_finchFormatter
{
    if (_f) return _f;
    CFLocaleRef l = (CFLocaleRef)(_locale ? [_locale retain] : [[NSLocale currentLocale] retain]);
    _f = CFDateFormatterCreate(NULL, l, (CFDateFormatterStyle)_dateStyle, (CFDateFormatterStyle)_timeStyle);
    CFRelease(l);
    CFTimeZoneRef tz = (CFTimeZoneRef)(_timeZone ? _timeZone : [NSTimeZone defaultTimeZone]);
    CFDateFormatterSetProperty(_f, kCFDateFormatterTimeZone, tz);
    if (_calendar) CFDateFormatterSetProperty(_f, kCFDateFormatterCalendar, (CFCalendarRef)_calendar);
    if (_lenient) CFDateFormatterSetProperty(_f, kCFDateFormatterIsLenient, kCFBooleanTrue);
    for (NSString *k in _properties) CFDateFormatterSetProperty(_f, (CFStringRef)k, (CFTypeRef)[_properties objectForKey:k]);
    if (_format) CFDateFormatterSetFormat(_f, (CFStringRef)_format);
    return _f;
}

- (NSString *)stringFromDate:(NSDate *)date
{
    if (!date) return nil;
    return [(id)CFDateFormatterCreateStringWithDate(NULL, [self _finchFormatter], (CFDateRef)date) autorelease];
}

- (NSDate *)dateFromString:(NSString *)string
{
    if (!string) return nil;
    CFRange r = CFRangeMake(0, CFStringGetLength((CFStringRef)string));
    CFAbsoluteTime at;
    if (!CFDateFormatterGetAbsoluteTimeFromString([self _finchFormatter], (CFStringRef)string, &r, &at)) return nil;
    if (r.length != CFStringGetLength((CFStringRef)string)) return nil;   /* the whole string must parse */
    return [NSDate dateWithTimeIntervalSinceReferenceDate:at];
}

- (NSString *)stringForObjectValue:(id)obj { return [obj isKindOfClass:[NSDate class]] ? [self stringFromDate:obj] : nil; }
- (BOOL)getObjectValue:(out id *)obj forString:(NSString *)string errorDescription:(out NSString **)error
{
    NSDate *d = [self dateFromString:string];
    if (obj) *obj = d;
    if (!d && error) *error = @"Error";
    return d != nil;
}

- (BOOL)getObjectValue:(out id *)obj forString:(NSString *)string range:(inout NSRange *)rangep error:(out NSError **)error
{
    CFRange r = CFRangeMake((CFIndex)rangep->location, (CFIndex)rangep->length);
    CFAbsoluteTime at;
    if (!CFDateFormatterGetAbsoluteTimeFromString([self _finchFormatter], (CFStringRef)string, &r, &at)) return NO;
    *rangep = NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
    if (obj) *obj = [NSDate dateWithTimeIntervalSinceReferenceDate:at];
    return YES;
}

+ (NSString *)localizedStringFromDate:(NSDate *)date dateStyle:(NSDateFormatterStyle)ds timeStyle:(NSDateFormatterStyle)ts
{
    NSDateFormatter *f = [[[NSDateFormatter alloc] init] autorelease];
    [f setDateStyle:ds];
    [f setTimeStyle:ts];
    return [f stringFromDate:date];
}

+ (NSString *)dateFormatFromTemplate:(NSString *)tmplate options:(NSUInteger)opts locale:(NSLocale *)locale
{
    return [(id)CFDateFormatterCreateDateFormatFromTemplate(NULL, (CFStringRef)tmplate, opts, (CFLocaleRef)locale) autorelease];
}

- (void)setLocalizedDateFormatFromTemplate:(NSString *)tmplate
{
    [self setDateFormat:[NSDateFormatter dateFormatFromTemplate:tmplate options:0 locale:[self locale]]];
}

+ (NSDateFormatterBehavior)defaultFormatterBehavior { return NSDateFormatterBehavior10_4; }
+ (void)setDefaultFormatterBehavior:(NSDateFormatterBehavior)b { }
- (NSDateFormatterBehavior)formatterBehavior { return NSDateFormatterBehavior10_4; }
- (void)setFormatterBehavior:(NSDateFormatterBehavior)b { }

- (NSString *)dateFormat
{
    if (_format) return _format;
    return (NSString *)CFDateFormatterGetFormat([self _finchFormatter]);
}
- (void)setDateFormat:(NSString *)fmt
{
    NSString *o = _format;
    _format = [fmt copy];
    [o release];
    [self _finchInvalidate];
}

- (NSDateFormatterStyle)dateStyle { return _dateStyle; }
- (void)setDateStyle:(NSDateFormatterStyle)s
{
    _dateStyle = s;
    [_format release];
    _format = nil;
    [self _finchInvalidate];
}
- (NSDateFormatterStyle)timeStyle { return _timeStyle; }
- (void)setTimeStyle:(NSDateFormatterStyle)s
{
    _timeStyle = s;
    [_format release];
    _format = nil;
    [self _finchInvalidate];
}

- (NSLocale *)locale { return _locale ? _locale : [NSLocale currentLocale]; }
- (void)setLocale:(NSLocale *)l
{
    NSLocale *o = _locale;
    _locale = [l retain];
    [o release];
    [self _finchInvalidate];
}
- (NSTimeZone *)timeZone { return _timeZone ? _timeZone : [NSTimeZone defaultTimeZone]; }
- (void)setTimeZone:(NSTimeZone *)tz
{
    NSTimeZone *o = _timeZone;
    _timeZone = [tz retain];
    [o release];
    [self _finchInvalidate];
}
- (NSCalendar *)calendar { return _calendar ? _calendar : [(id)CFDateFormatterCopyProperty([self _finchFormatter], kCFDateFormatterCalendar) autorelease]; }
- (void)setCalendar:(NSCalendar *)c
{
    NSCalendar *o = _calendar;
    _calendar = [c copy];
    [o release];
    [self _finchInvalidate];
}
- (BOOL)isLenient { return _lenient; }
- (void)setLenient:(BOOL)b { _lenient = b; [self _finchInvalidate]; }
- (BOOL)doesRelativeDateFormatting { return _relative; }
- (void)setDoesRelativeDateFormatting:(BOOL)b { _relative = b; }
- (BOOL)generatesCalendarDates { return NO; }
- (void)setGeneratesCalendarDates:(BOOL)b { }
- (NSDate *)defaultDate { return _defaultDate; }
- (void)setDefaultDate:(NSDate *)d { NSDate *o = _defaultDate; _defaultDate = [d retain]; [o release]; }
- (NSDate *)twoDigitStartDate { return [(id)CFDateFormatterCopyProperty([self _finchFormatter], kCFDateFormatterTwoDigitStartDate) autorelease]; }
- (void)setTwoDigitStartDate:(NSDate *)d { [_properties setObject:d forKey:(id)kCFDateFormatterTwoDigitStartDate]; [self _finchInvalidate]; }

#define PROPERTY(get, Set, key) \
    - (id)get { return [(id)CFDateFormatterCopyProperty([self _finchFormatter], key) autorelease]; } \
    - (void)set##Set:(id)v { if (v) [_properties setObject:v forKey:(id)key]; else [_properties removeObjectForKey:(id)key]; [self _finchInvalidate]; }
PROPERTY(eraSymbols, EraSymbols, kCFDateFormatterEraSymbols)
PROPERTY(longEraSymbols, LongEraSymbols, kCFDateFormatterLongEraSymbols)
PROPERTY(monthSymbols, MonthSymbols, kCFDateFormatterMonthSymbols)
PROPERTY(shortMonthSymbols, ShortMonthSymbols, kCFDateFormatterShortMonthSymbols)
PROPERTY(veryShortMonthSymbols, VeryShortMonthSymbols, kCFDateFormatterVeryShortMonthSymbols)
PROPERTY(standaloneMonthSymbols, StandaloneMonthSymbols, kCFDateFormatterStandaloneMonthSymbols)
PROPERTY(shortStandaloneMonthSymbols, ShortStandaloneMonthSymbols, kCFDateFormatterShortStandaloneMonthSymbols)
PROPERTY(veryShortStandaloneMonthSymbols, VeryShortStandaloneMonthSymbols, kCFDateFormatterVeryShortStandaloneMonthSymbols)
PROPERTY(weekdaySymbols, WeekdaySymbols, kCFDateFormatterWeekdaySymbols)
PROPERTY(shortWeekdaySymbols, ShortWeekdaySymbols, kCFDateFormatterShortWeekdaySymbols)
PROPERTY(veryShortWeekdaySymbols, VeryShortWeekdaySymbols, kCFDateFormatterVeryShortWeekdaySymbols)
PROPERTY(standaloneWeekdaySymbols, StandaloneWeekdaySymbols, kCFDateFormatterStandaloneWeekdaySymbols)
PROPERTY(shortStandaloneWeekdaySymbols, ShortStandaloneWeekdaySymbols, kCFDateFormatterShortStandaloneWeekdaySymbols)
PROPERTY(veryShortStandaloneWeekdaySymbols, VeryShortStandaloneWeekdaySymbols, kCFDateFormatterVeryShortStandaloneWeekdaySymbols)
PROPERTY(quarterSymbols, QuarterSymbols, kCFDateFormatterQuarterSymbols)
PROPERTY(shortQuarterSymbols, ShortQuarterSymbols, kCFDateFormatterShortQuarterSymbols)
PROPERTY(standaloneQuarterSymbols, StandaloneQuarterSymbols, kCFDateFormatterStandaloneQuarterSymbols)
PROPERTY(shortStandaloneQuarterSymbols, ShortStandaloneQuarterSymbols, kCFDateFormatterShortStandaloneQuarterSymbols)
PROPERTY(AMSymbol, AMSymbol, kCFDateFormatterAMSymbol)
PROPERTY(PMSymbol, PMSymbol, kCFDateFormatterPMSymbol)
PROPERTY(gregorianStartDate, GregorianStartDate, kCFDateFormatterGregorianStartDate)
#undef PROPERTY

@end

/* MARK: - NSNumberFormatter */

@implementation NSNumberFormatter {
    CFNumberFormatterRef _f;
    NSLocale *_locale;
    NSNumberFormatterStyle _style;
    NSString *_positiveFormat, *_negativeFormat;
    NSMutableDictionary *_properties;
    NSNumber *_minimum, *_maximum;
    BOOL _allowsFloats, _generatesDecimal;
    NSString *_nilSymbol;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _properties = [[NSMutableDictionary alloc] init];
        _allowsFloats = YES;
    }
    return self;
}

- (void)dealloc
{
    if (_f) CFRelease(_f);
    [_locale release];
    [_positiveFormat release];
    [_negativeFormat release];
    [_properties release];
    [_minimum release];
    [_maximum release];
    [_nilSymbol release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSNumberFormatter *c = [[NSNumberFormatter alloc] init];
    c->_locale = [_locale retain];
    c->_style = _style;
    c->_positiveFormat = [_positiveFormat copy];
    c->_negativeFormat = [_negativeFormat copy];
    [c->_properties addEntriesFromDictionary:_properties];
    c->_minimum = [_minimum retain];
    c->_maximum = [_maximum retain];
    c->_allowsFloats = _allowsFloats;
    return c;
}

- (void)_finchInvalidate
{
    if (_f) CFRelease(_f);
    _f = NULL;
}

- (CFNumberFormatterRef)_finchFormatter
{
    if (_f) return _f;
    CFLocaleRef l = (CFLocaleRef)(_locale ? [_locale retain] : [[NSLocale currentLocale] retain]);
    _f = CFNumberFormatterCreate(NULL, l, (CFNumberFormatterStyle)_style);
    CFRelease(l);
    for (NSString *k in _properties) CFNumberFormatterSetProperty(_f, (CFStringRef)k, (CFTypeRef)[_properties objectForKey:k]);
    if (_positiveFormat || _negativeFormat) {
        NSString *fmt = _negativeFormat ? [NSString stringWithFormat:@"%@;%@", _positiveFormat ? _positiveFormat : (NSString *)CFNumberFormatterGetFormat(_f), _negativeFormat]
                                        : _positiveFormat;
        CFNumberFormatterSetFormat(_f, (CFStringRef)fmt);
    }
    return _f;
}

- (NSString *)stringFromNumber:(NSNumber *)number
{
    if (!number) return _nilSymbol;
    return [(id)CFNumberFormatterCreateStringWithNumber(NULL, [self _finchFormatter], (CFNumberRef)number) autorelease];
}

- (NSNumber *)numberFromString:(NSString *)string
{
    if (!string) return nil;
    CFRange r = CFRangeMake(0, CFStringGetLength((CFStringRef)string));
    CFNumberRef n = CFNumberFormatterCreateNumberFromString(NULL, [self _finchFormatter], (CFStringRef)string, &r,
        _allowsFloats ? 0 : kCFNumberFormatterParseIntegersOnly);
    if (!n) return nil;
    if (r.length != CFStringGetLength((CFStringRef)string)) { CFRelease(n); return nil; }
    NSNumber *num = [(id)n autorelease];
    if ((_minimum && [num compare:_minimum] == NSOrderedAscending) || (_maximum && [num compare:_maximum] == NSOrderedDescending)) return nil;
    return num;
}

- (NSString *)stringForObjectValue:(id)obj { return [obj isKindOfClass:[NSNumber class]] ? [self stringFromNumber:obj] : nil; }
- (BOOL)getObjectValue:(out id *)obj forString:(NSString *)string errorDescription:(out NSString **)error
{
    NSNumber *n = [self numberFromString:string];
    if (obj) *obj = n;
    if (!n && error) *error = @"Error";
    return n != nil;
}

+ (NSString *)localizedStringFromNumber:(NSNumber *)num numberStyle:(NSNumberFormatterStyle)nstyle
{
    NSNumberFormatter *f = [[[NSNumberFormatter alloc] init] autorelease];
    [f setNumberStyle:nstyle];
    [f setLocale:[NSLocale currentLocale]];
    return [f stringFromNumber:num];
}

+ (NSNumberFormatterBehavior)defaultFormatterBehavior { return NSNumberFormatterBehavior10_4; }
+ (void)setDefaultFormatterBehavior:(NSNumberFormatterBehavior)b { }
- (NSNumberFormatterBehavior)formatterBehavior { return NSNumberFormatterBehavior10_4; }
- (void)setFormatterBehavior:(NSNumberFormatterBehavior)b { }

- (NSNumberFormatterStyle)numberStyle { return _style; }
- (void)setNumberStyle:(NSNumberFormatterStyle)s
{
    _style = s;
    [_positiveFormat release];
    [_negativeFormat release];
    _positiveFormat = _negativeFormat = nil;
    [_properties removeAllObjects];
    [self _finchInvalidate];
}
- (NSLocale *)locale { return _locale ? _locale : [NSLocale currentLocale]; }
- (void)setLocale:(NSLocale *)l
{
    NSLocale *o = _locale;
    _locale = [l retain];
    [o release];
    [self _finchInvalidate];
}

- (NSString *)positiveFormat
{
    if (_positiveFormat) return _positiveFormat;
    NSString *f = (NSString *)CFNumberFormatterGetFormat([self _finchFormatter]);
    NSRange semi = [f rangeOfString:@";"];
    return semi.location == NSNotFound ? f : [f substringToIndex:semi.location];
}
- (void)setPositiveFormat:(NSString *)f { NSString *o = _positiveFormat; _positiveFormat = [f copy]; [o release]; [self _finchInvalidate]; }
- (NSString *)negativeFormat
{
    if (_negativeFormat) return _negativeFormat;
    NSString *f = (NSString *)CFNumberFormatterGetFormat([self _finchFormatter]);
    NSRange semi = [f rangeOfString:@";"];
    return semi.location == NSNotFound ? [@"-" stringByAppendingString:f] : [f substringFromIndex:semi.location + 1];
}
- (void)setNegativeFormat:(NSString *)f { NSString *o = _negativeFormat; _negativeFormat = [f copy]; [o release]; [self _finchInvalidate]; }

static id
get(NSNumberFormatter *self, CFStringRef key)
{
    return [(id)CFNumberFormatterCopyProperty([self _finchFormatter], key) autorelease];
}

static void
set(NSNumberFormatter *self, NSMutableDictionary *props, CFStringRef key, id value)
{
    if (value) [props setObject:value forKey:(id)key];
    else [props removeObjectForKey:(id)key];
    [self _finchInvalidate];
}

#define OBJ_PROPERTY(type, getter, Setter, key) \
    - (type)getter { return get(self, key); } \
    - (void)set##Setter:(type)v { set(self, _properties, key, v); }
OBJ_PROPERTY(NSString *, currencyCode, CurrencyCode, kCFNumberFormatterCurrencyCode)
OBJ_PROPERTY(NSString *, currencySymbol, CurrencySymbol, kCFNumberFormatterCurrencySymbol)
OBJ_PROPERTY(NSString *, internationalCurrencySymbol, InternationalCurrencySymbol, kCFNumberFormatterInternationalCurrencySymbol)
OBJ_PROPERTY(NSString *, decimalSeparator, DecimalSeparator, kCFNumberFormatterDecimalSeparator)
OBJ_PROPERTY(NSString *, currencyDecimalSeparator, CurrencyDecimalSeparator, kCFNumberFormatterCurrencyDecimalSeparator)
OBJ_PROPERTY(NSString *, groupingSeparator, GroupingSeparator, kCFNumberFormatterGroupingSeparator)
OBJ_PROPERTY(NSString *, currencyGroupingSeparator, CurrencyGroupingSeparator, kCFNumberFormatterCurrencyGroupingSeparator)
OBJ_PROPERTY(NSString *, percentSymbol, PercentSymbol, kCFNumberFormatterPercentSymbol)
OBJ_PROPERTY(NSString *, perMillSymbol, PerMillSymbol, kCFNumberFormatterPerMillSymbol)
OBJ_PROPERTY(NSString *, minusSign, MinusSign, kCFNumberFormatterMinusSign)
OBJ_PROPERTY(NSString *, plusSign, PlusSign, kCFNumberFormatterPlusSign)
OBJ_PROPERTY(NSString *, exponentSymbol, ExponentSymbol, kCFNumberFormatterExponentSymbol)
OBJ_PROPERTY(NSString *, zeroSymbol, ZeroSymbol, kCFNumberFormatterZeroSymbol)
OBJ_PROPERTY(NSString *, notANumberSymbol, NotANumberSymbol, kCFNumberFormatterNaNSymbol)
OBJ_PROPERTY(NSString *, positiveInfinitySymbol, PositiveInfinitySymbol, kCFNumberFormatterInfinitySymbol)
OBJ_PROPERTY(NSString *, negativePrefix, NegativePrefix, kCFNumberFormatterNegativePrefix)
OBJ_PROPERTY(NSString *, negativeSuffix, NegativeSuffix, kCFNumberFormatterNegativeSuffix)
OBJ_PROPERTY(NSString *, positivePrefix, PositivePrefix, kCFNumberFormatterPositivePrefix)
OBJ_PROPERTY(NSString *, positiveSuffix, PositiveSuffix, kCFNumberFormatterPositiveSuffix)
OBJ_PROPERTY(NSString *, paddingCharacter, PaddingCharacter, kCFNumberFormatterPaddingCharacter)
OBJ_PROPERTY(NSNumber *, multiplier, Multiplier, kCFNumberFormatterMultiplier)
OBJ_PROPERTY(NSNumber *, roundingIncrement, RoundingIncrement, kCFNumberFormatterRoundingIncrement)
#undef OBJ_PROPERTY

#define INT_PROPERTY(getter, Setter, key) \
    - (NSUInteger)getter { return [get(self, key) unsignedIntegerValue]; } \
    - (void)set##Setter:(NSUInteger)v { set(self, _properties, key, [NSNumber numberWithUnsignedInteger:v]); }
INT_PROPERTY(minimumIntegerDigits, MinimumIntegerDigits, kCFNumberFormatterMinIntegerDigits)
INT_PROPERTY(maximumIntegerDigits, MaximumIntegerDigits, kCFNumberFormatterMaxIntegerDigits)
INT_PROPERTY(minimumFractionDigits, MinimumFractionDigits, kCFNumberFormatterMinFractionDigits)
INT_PROPERTY(maximumFractionDigits, MaximumFractionDigits, kCFNumberFormatterMaxFractionDigits)
INT_PROPERTY(minimumSignificantDigits, MinimumSignificantDigits, kCFNumberFormatterMinSignificantDigits)
INT_PROPERTY(maximumSignificantDigits, MaximumSignificantDigits, kCFNumberFormatterMaxSignificantDigits)
INT_PROPERTY(formatWidth, FormatWidth, kCFNumberFormatterFormatWidth)
INT_PROPERTY(groupingSize, GroupingSize, kCFNumberFormatterGroupingSize)
INT_PROPERTY(secondaryGroupingSize, SecondaryGroupingSize, kCFNumberFormatterSecondaryGroupingSize)
#undef INT_PROPERTY

- (BOOL)usesGroupingSeparator { return [get(self, kCFNumberFormatterUseGroupingSeparator) boolValue]; }
- (void)setUsesGroupingSeparator:(BOOL)b { set(self, _properties, kCFNumberFormatterUseGroupingSeparator, b ? (id)kCFBooleanTrue : (id)kCFBooleanFalse); }
- (BOOL)usesSignificantDigits { return [get(self, kCFNumberFormatterUseSignificantDigits) boolValue]; }
- (void)setUsesSignificantDigits:(BOOL)b { set(self, _properties, kCFNumberFormatterUseSignificantDigits, b ? (id)kCFBooleanTrue : (id)kCFBooleanFalse); }
- (BOOL)alwaysShowsDecimalSeparator { return [get(self, kCFNumberFormatterAlwaysShowDecimalSeparator) boolValue]; }
- (void)setAlwaysShowsDecimalSeparator:(BOOL)b { set(self, _properties, kCFNumberFormatterAlwaysShowDecimalSeparator, b ? (id)kCFBooleanTrue : (id)kCFBooleanFalse); }
- (BOOL)isLenient { return [get(self, kCFNumberFormatterIsLenient) boolValue]; }
- (void)setLenient:(BOOL)b { set(self, _properties, kCFNumberFormatterIsLenient, b ? (id)kCFBooleanTrue : (id)kCFBooleanFalse); }
- (NSNumberFormatterRoundingMode)roundingMode { return (NSNumberFormatterRoundingMode)[get(self, kCFNumberFormatterRoundingMode) integerValue]; }
- (void)setRoundingMode:(NSNumberFormatterRoundingMode)m { set(self, _properties, kCFNumberFormatterRoundingMode, [NSNumber numberWithInteger:m]); }
- (NSNumberFormatterPadPosition)paddingPosition { return (NSNumberFormatterPadPosition)[get(self, kCFNumberFormatterPaddingPosition) integerValue]; }
- (void)setPaddingPosition:(NSNumberFormatterPadPosition)p { set(self, _properties, kCFNumberFormatterPaddingPosition, [NSNumber numberWithInteger:p]); }

- (BOOL)allowsFloats { return _allowsFloats; }
- (void)setAllowsFloats:(BOOL)b { _allowsFloats = b; }
- (BOOL)generatesDecimalNumbers { return _generatesDecimal; }
- (void)setGeneratesDecimalNumbers:(BOOL)b { _generatesDecimal = b; }
- (NSNumber *)minimum { return _minimum; }
- (void)setMinimum:(NSNumber *)n { NSNumber *o = _minimum; _minimum = [n retain]; [o release]; }
- (NSNumber *)maximum { return _maximum; }
- (void)setMaximum:(NSNumber *)n { NSNumber *o = _maximum; _maximum = [n retain]; [o release]; }
- (NSString *)nilSymbol { return _nilSymbol ? _nilSymbol : @""; }
- (void)setNilSymbol:(NSString *)s { NSString *o = _nilSymbol; _nilSymbol = [s copy]; [o release]; }

@end
