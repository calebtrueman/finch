/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSLocale, NSTimeZone, NSCalendar and NSDateComponents, which Apple's
 * CoreFoundation hosts (docs/design/FOUNDATION.md), with __NSCFLocale,
 * __NSCFTimeZone and __NSCFCalendar as the classes of CFLocale, CFTimeZone
 * and CFCalendar (Apple's are Swift now, _NSSwiftLocale and friends; the
 * behaviour is CF's, which is ICU's, as theirs is).
 *
 * The classes' +alloc returns a placeholder whose -init... make the CF
 * objects. A calendar is mutable (time zone, locale, first weekday) in
 * place, as NSCalendar is.
 */
#include "CFObjCClasses_Finch.h"
#include <math.h>
#include "CFDateFormatter.h"

typedef double NSTimeInterval;

@interface NSDate (FinchLocale)
+ (id)dateWithTimeIntervalSinceReferenceDate:(NSTimeInterval)ti;
+ (id)date;
- (NSTimeInterval)timeIntervalSinceReferenceDate;
@end
@interface NSNumber (FinchLocale)
+ (id)numberWithBool:(BOOL)b;
@end
@interface NSArray (FinchLocale)
+ (instancetype)arrayWithObjects:(const id *)objects count:(NSUInteger)count;
@end

static id
owned(CFTypeRef cf)
{
    return cf ? [(id)cf autorelease] : nil;
}

/* MARK: - NSLocale */

@interface __NSCFLocale : NSLocale
@end
@interface __NSPlaceholderLocale : NSLocale
@end

static __NSPlaceholderLocale *localePlaceholder;

@implementation NSLocale

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSLocale class] || self == [__NSCFLocale class]) return (id)localePlaceholder;
    return [super allocWithZone:zone];
}

+ (instancetype)localeWithLocaleIdentifier:(id)ident { return [[[self alloc] initWithLocaleIdentifier:ident] autorelease]; }
+ (id)currentLocale { return owned(CFLocaleCopyCurrent()); }
+ (id)autoupdatingCurrentLocale { return [self currentLocale]; }
+ (id)systemLocale { return (id)CFLocaleGetSystem(); }
+ (id)availableLocaleIdentifiers { return owned(CFLocaleCopyAvailableLocaleIdentifiers()); }
+ (id)ISOLanguageCodes { return owned(CFLocaleCopyISOLanguageCodes()); }
+ (id)ISOCountryCodes { return owned(CFLocaleCopyISOCountryCodes()); }
+ (id)ISOCurrencyCodes { return owned(CFLocaleCopyISOCurrencyCodes()); }
+ (id)commonISOCurrencyCodes { return owned(CFLocaleCopyCommonISOCurrencyCodes()); }
+ (id)preferredLanguages { return owned(CFLocaleCopyPreferredLanguages()); }
+ (id)canonicalLocaleIdentifierFromString:(id)s
{
    return owned(CFLocaleCreateCanonicalLocaleIdentifierFromString(NULL, (CFStringRef)s));
}
+ (id)canonicalLanguageIdentifierFromString:(id)s
{
    return owned(CFLocaleCreateCanonicalLanguageIdentifierFromString(NULL, (CFStringRef)s));
}
+ (id)componentsFromLocaleIdentifier:(id)s { return owned(CFLocaleCreateComponentsFromLocaleIdentifier(NULL, (CFStringRef)s)); }
+ (id)localeIdentifierFromComponents:(id)d
{
    return owned(CFLocaleCreateLocaleIdentifierFromComponents(NULL, (CFDictionaryRef)d));
}
+ (id)localeIdentifierFromWindowsLocaleCode:(uint32_t)code
{
    return owned(CFLocaleCreateLocaleIdentifierFromWindowsLocaleCode(NULL, code));
}
+ (uint32_t)windowsLocaleCodeFromLocaleIdentifier:(id)s { return CFLocaleGetWindowsLocaleCodeFromLocaleIdentifier((CFStringRef)s); }
+ (NSUInteger)characterDirectionForLanguage:(id)iso { return (NSUInteger)CFLocaleGetLanguageCharacterDirection((CFStringRef)iso); }
+ (NSUInteger)lineDirectionForLanguage:(id)iso { return (NSUInteger)CFLocaleGetLanguageLineDirection((CFStringRef)iso); }

- (CFTypeID)_cfTypeID { return CFLocaleGetTypeID(); }
- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }

- (id)objectForKey:(id)key { return (id)CFLocaleGetValue((CFLocaleRef)self, (CFStringRef)key); }
- (id)displayNameForKey:(id)key value:(id)value
{
    return owned(CFLocaleCopyDisplayNameForPropertyValue((CFLocaleRef)self, (CFStringRef)key, (CFStringRef)value));
}
- (id)localeIdentifier { return (id)CFLocaleGetIdentifier((CFLocaleRef)self); }
- (id)languageCode { return [self objectForKey:(id)kCFLocaleLanguageCode]; }
- (id)countryCode { return [self objectForKey:(id)kCFLocaleCountryCode]; }
- (id)regionCode { return [self countryCode]; }
- (id)scriptCode { return [self objectForKey:(id)kCFLocaleScriptCode]; }
- (id)variantCode { return [self objectForKey:(id)kCFLocaleVariantCode]; }
- (id)exemplarCharacterSet { return [self objectForKey:(id)kCFLocaleExemplarCharacterSet]; }
- (id)calendarIdentifier { return [self objectForKey:(id)kCFLocaleCalendarIdentifier]; }
- (id)collationIdentifier { return [self objectForKey:(id)kCFLocaleCollationIdentifier]; }
- (BOOL)usesMetricSystem { return CFBooleanGetValue((CFBooleanRef)[self objectForKey:(id)kCFLocaleUsesMetricSystem]); }
- (id)decimalSeparator { return [self objectForKey:(id)kCFLocaleDecimalSeparator]; }
- (id)groupingSeparator { return [self objectForKey:(id)kCFLocaleGroupingSeparator]; }
- (id)currencySymbol { return [self objectForKey:(id)kCFLocaleCurrencySymbol]; }
- (id)currencyCode { return [self objectForKey:(id)kCFLocaleCurrencyCode]; }
- (id)collatorIdentifier { return [self objectForKey:(id)kCFLocaleCollatorIdentifier]; }
- (id)quotationBeginDelimiter { return [self objectForKey:(id)kCFLocaleQuotationBeginDelimiterKey]; }
- (id)quotationEndDelimiter { return [self objectForKey:(id)kCFLocaleQuotationEndDelimiterKey]; }
- (id)alternateQuotationBeginDelimiter { return [self objectForKey:(id)kCFLocaleAlternateQuotationBeginDelimiterKey]; }
- (id)alternateQuotationEndDelimiter { return [self objectForKey:(id)kCFLocaleAlternateQuotationEndDelimiterKey]; }

#define DISPLAY(sel, key) - (id)sel:(id)v { return [self displayNameForKey:(id)key value:v]; }
DISPLAY(localizedStringForLocaleIdentifier, kCFLocaleIdentifier)
DISPLAY(localizedStringForLanguageCode, kCFLocaleLanguageCode)
DISPLAY(localizedStringForCountryCode, kCFLocaleCountryCode)
DISPLAY(localizedStringForScriptCode, kCFLocaleScriptCode)
DISPLAY(localizedStringForVariantCode, kCFLocaleVariantCode)
DISPLAY(localizedStringForCalendarIdentifier, kCFLocaleCalendarIdentifier)
DISPLAY(localizedStringForCollationIdentifier, kCFLocaleCollationIdentifier)
DISPLAY(localizedStringForCurrencyCode, kCFLocaleCurrencyCode)
DISPLAY(localizedStringForCollatorIdentifier, kCFLocaleCollatorIdentifier)
#undef DISPLAY

- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }
- (id)description
{
    return owned(CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ (fixed)"), CFLocaleGetIdentifier((CFLocaleRef)self)));
}

@end

@implementation __NSPlaceholderLocale
FINCH_IMMORTAL_MEMORY
- (instancetype)initWithLocaleIdentifier:(id)ident
{
    return (id)CFLocaleCreate(NULL, ident ? (CFStringRef)ident : CFSTR(""));
}
@end

@implementation __NSCFLocale
FINCH_CF_OBJECT_MEMORY
@end

/* MARK: - NSTimeZone */

@interface __NSCFTimeZone : NSTimeZone
@end
@interface __NSPlaceholderTimeZone : NSTimeZone
@end

static __NSPlaceholderTimeZone *zonePlaceholder;
static id defaultZone;

@implementation NSTimeZone

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSTimeZone class] || self == [__NSCFTimeZone class]) return (id)zonePlaceholder;
    return [super allocWithZone:zone];
}

+ (instancetype)timeZoneWithName:(id)name { return [[[self alloc] initWithName:name] autorelease]; }
+ (instancetype)timeZoneWithName:(id)name data:(id)data { return [[[self alloc] initWithName:name data:data] autorelease]; }
+ (instancetype)timeZoneForSecondsFromGMT:(NSInteger)seconds
{
    return owned(CFTimeZoneCreateWithTimeIntervalFromGMT(NULL, (CFTimeInterval)seconds));
}
+ (instancetype)timeZoneWithAbbreviation:(id)abbr
{
    CFDictionaryRef d = CFTimeZoneCopyAbbreviationDictionary();
    CFStringRef name = d ? CFDictionaryGetValue(d, abbr) : NULL;
    id tz = name ? [self timeZoneWithName:(id)name] : nil;
    if (d) CFRelease(d);
    return tz;
}
+ (id)systemTimeZone { return owned(CFTimeZoneCopySystem()); }
+ (void)resetSystemTimeZone { CFTimeZoneResetSystem(); }
+ (id)localTimeZone { return [self defaultTimeZone]; }
+ (id)defaultTimeZone { return defaultZone ? defaultZone : owned(CFTimeZoneCopyDefault()); }
+ (void)setDefaultTimeZone:(id)tz
{
    CFTimeZoneSetDefault((CFTimeZoneRef)tz);
    id old = defaultZone;
    defaultZone = [tz retain];
    [old release];
}
+ (id)knownTimeZoneNames { return owned(CFTimeZoneCopyKnownNames()); }
+ (id)abbreviationDictionary { return owned(CFTimeZoneCopyAbbreviationDictionary()); }
+ (void)setAbbreviationDictionary:(id)d { CFTimeZoneSetAbbreviationDictionary((CFDictionaryRef)d); }
+ (id)timeZoneDataVersion { return (id)CFSTR("2025b"); }

- (CFTypeID)_cfTypeID { return CFTimeZoneGetTypeID(); }
- (BOOL)isNSTimeZone__ { return YES; }
- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }

- (id)name { return (id)CFTimeZoneGetName((CFTimeZoneRef)self); }
- (id)data { return (id)CFTimeZoneGetData((CFTimeZoneRef)self); }
- (NSInteger)secondsFromGMTForDate:(id)d
{
    return (NSInteger)CFTimeZoneGetSecondsFromGMT((CFTimeZoneRef)self, [d timeIntervalSinceReferenceDate]);
}
- (NSInteger)secondsFromGMT { return [self secondsFromGMTForDate:[NSDate date]]; }
- (id)abbreviationForDate:(id)d { return owned(CFTimeZoneCopyAbbreviation((CFTimeZoneRef)self, [d timeIntervalSinceReferenceDate])); }
- (id)abbreviation { return [self abbreviationForDate:[NSDate date]]; }
- (BOOL)isDaylightSavingTimeForDate:(id)d { return CFTimeZoneIsDaylightSavingTime((CFTimeZoneRef)self, [d timeIntervalSinceReferenceDate]); }
- (BOOL)isDaylightSavingTime { return [self isDaylightSavingTimeForDate:[NSDate date]]; }
- (NSTimeInterval)daylightSavingTimeOffsetForDate:(id)d
{
    return CFTimeZoneGetDaylightSavingTimeOffset((CFTimeZoneRef)self, [d timeIntervalSinceReferenceDate]);
}
- (NSTimeInterval)daylightSavingTimeOffset { return [self daylightSavingTimeOffsetForDate:[NSDate date]]; }
- (id)nextDaylightSavingTimeTransitionAfterDate:(id)d
{
    CFAbsoluteTime t = CFTimeZoneGetNextDaylightSavingTimeTransition((CFTimeZoneRef)self, [d timeIntervalSinceReferenceDate]);
    return t ? [NSDate dateWithTimeIntervalSinceReferenceDate:t] : nil;
}
- (id)nextDaylightSavingTimeTransition { return [self nextDaylightSavingTimeTransitionAfterDate:[NSDate date]]; }
- (id)localizedName:(NSInteger)style locale:(id)locale
{
    return owned(CFTimeZoneCopyLocalizedName((CFTimeZoneRef)self, (CFTimeZoneNameStyle)style, (CFLocaleRef)locale));
}
- (BOOL)isEqualToTimeZone:(id)tz { return tz && CFEqual((CFTypeRef)self, (CFTypeRef)tz); }
- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }
- (id)description
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFStringRef abbr = CFTimeZoneCopyAbbreviation((CFTimeZoneRef)self, now);
    id d = owned(CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ (%@) offset %ld%@"), CFTimeZoneGetName((CFTimeZoneRef)self), abbr,
        (long)CFTimeZoneGetSecondsFromGMT((CFTimeZoneRef)self, now),
        CFTimeZoneIsDaylightSavingTime((CFTimeZoneRef)self, now) ? CFSTR(" (Daylight)") : CFSTR("")));
    if (abbr) CFRelease(abbr);
    return d;
}

@end

@implementation __NSPlaceholderTimeZone
FINCH_IMMORTAL_MEMORY
- (instancetype)initWithName:(id)name
{
    return name ? (id)CFTimeZoneCreateWithName(NULL, (CFStringRef)name, true) : nil;
}
- (instancetype)initWithName:(id)name data:(id)data
{
    return data ? (id)CFTimeZoneCreate(NULL, (CFStringRef)name, (CFDataRef)data) : [self initWithName:name];
}
@end

@implementation __NSCFTimeZone
FINCH_CF_OBJECT_MEMORY
@end

/* MARK: - NSDateComponents */

#define NSDateComponentUndefined NSIntegerMax

enum {
    U_ERA = 1 << 1, U_YEAR = 1 << 2, U_MONTH = 1 << 3, U_DAY = 1 << 4, U_HOUR = 1 << 5, U_MINUTE = 1 << 6,
    U_SECOND = 1 << 7, U_WEEKDAY = 1 << 9, U_WEEKDAY_ORDINAL = 1 << 10, U_QUARTER = 1 << 11,
    U_WEEK_OF_MONTH = 1 << 12, U_WEEK_OF_YEAR = 1 << 13, U_YEAR_FOR_WEEK = 1 << 14, U_NANOSECOND = 1 << 15,
    U_CALENDAR = 1 << 20, U_TIME_ZONE = 1 << 21,
};

@interface NSDateComponents : NSObject <NSCopying> {
@public
    NSInteger _era, _year, _month, _day, _hour, _minute, _second, _nanosecond, _weekday, _weekdayOrdinal,
        _quarter, _weekOfMonth, _weekOfYear, _yearForWeekOfYear, _week;
    BOOL _leapMonth, _leapMonthSet;
    id _calendar, _timeZone;
}
@end

@implementation NSDateComponents

- (instancetype)init
{
    if ((self = [super init])) {
        _era = _year = _month = _day = _hour = _minute = _second = _nanosecond = _weekday = _weekdayOrdinal = _quarter =
            _weekOfMonth = _weekOfYear = _yearForWeekOfYear = _week = NSDateComponentUndefined;
    }
    return self;
}

- (void)dealloc { [_calendar release]; [_timeZone release]; [super dealloc]; }

#define PROP(get, Set, ivar) - (NSInteger)get { return ivar; } - (void)set##Set:(NSInteger)v { ivar = v; }
PROP(era, Era, _era)
PROP(year, Year, _year)
PROP(month, Month, _month)
PROP(day, Day, _day)
PROP(hour, Hour, _hour)
PROP(minute, Minute, _minute)
PROP(second, Second, _second)
PROP(nanosecond, Nanosecond, _nanosecond)
PROP(weekday, Weekday, _weekday)
PROP(weekdayOrdinal, WeekdayOrdinal, _weekdayOrdinal)
PROP(quarter, Quarter, _quarter)
PROP(weekOfMonth, WeekOfMonth, _weekOfMonth)
PROP(weekOfYear, WeekOfYear, _weekOfYear)
PROP(yearForWeekOfYear, YearForWeekOfYear, _yearForWeekOfYear)
PROP(week, Week, _week)
#undef PROP
- (BOOL)isLeapMonth { return _leapMonth; }
- (void)setLeapMonth:(BOOL)b { _leapMonth = b; _leapMonthSet = YES; }
- (id)calendar { return _calendar; }
- (void)setCalendar:(id)c { id o = _calendar; _calendar = [c copy]; [o release]; }
- (id)timeZone { return _timeZone; }
- (void)setTimeZone:(id)tz { id o = _timeZone; _timeZone = [tz retain]; [o release]; }

static NSInteger *
slot(NSDateComponents *c, NSUInteger unit)
{
    switch (unit) {
    case U_ERA: return &c->_era;
    case U_YEAR: return &c->_year;
    case U_MONTH: return &c->_month;
    case U_DAY: return &c->_day;
    case U_HOUR: return &c->_hour;
    case U_MINUTE: return &c->_minute;
    case U_SECOND: return &c->_second;
    case U_NANOSECOND: return &c->_nanosecond;
    case U_WEEKDAY: return &c->_weekday;
    case U_WEEKDAY_ORDINAL: return &c->_weekdayOrdinal;
    case U_QUARTER: return &c->_quarter;
    case U_WEEK_OF_MONTH: return &c->_weekOfMonth;
    case U_WEEK_OF_YEAR: return &c->_weekOfYear;
    case U_YEAR_FOR_WEEK: return &c->_yearForWeekOfYear;
    default: return NULL;
    }
}

- (NSInteger)valueForComponent:(NSUInteger)unit { NSInteger *p = slot(self, unit); return p ? *p : NSDateComponentUndefined; }
- (void)setValue:(NSInteger)value forComponent:(NSUInteger)unit { NSInteger *p = slot(self, unit); if (p) *p = value; }

- (id)date
{
    if (!_calendar) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(_calendar, sel_registerName("dateFromComponents:"), self);
}

- (BOOL)isValidDate { return [self date] != nil; }
- (BOOL)isValidDateInCalendar:(id)calendar
{
    return ((id (*)(id, SEL, id))objc_msgSend)(calendar, sel_registerName("dateFromComponents:"), self) != nil;
}

- (id)copyWithZone:(struct _NSZone *)zone
{
    NSDateComponents *c = [[NSDateComponents alloc] init];
    memcpy(&c->_era, &_era, (char *)&_leapMonthSet + sizeof(_leapMonthSet) - (char *)&_era);
    c->_calendar = [_calendar copy];
    c->_timeZone = [_timeZone retain];
    return c;
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSDateComponents class]]) return NO;
    NSDateComponents *o = other;
    return memcmp(&_era, &o->_era, (char *)&_leapMonthSet + sizeof(_leapMonthSet) - (char *)&_era) == 0;
}

- (NSUInteger)hash { return (NSUInteger)(_year * 372 + _month * 31 + _day); }

@end

/* MARK: - NSCalendar */

@interface __NSCFCalendar : NSCalendar
@end
@interface __NSPlaceholderCalendar : NSCalendar
@end

static __NSPlaceholderCalendar *calendarPlaceholder;

/* The CFCalendar unit for each NSCalendarUnit bit, and its format letter for
 * CFCalendarDecompose/ComposeAbsoluteTime. */
static const struct { NSUInteger unit; CFCalendarUnit cf; char letter; } units[] = {
    { U_ERA, kCFCalendarUnitEra, 'G' }, { U_YEAR, kCFCalendarUnitYear, 'y' }, { U_MONTH, kCFCalendarUnitMonth, 'M' },
    { U_DAY, kCFCalendarUnitDay, 'd' }, { U_HOUR, kCFCalendarUnitHour, 'H' }, { U_MINUTE, kCFCalendarUnitMinute, 'm' },
    { U_SECOND, kCFCalendarUnitSecond, 's' }, { U_WEEKDAY, kCFCalendarUnitWeekday, 'E' },
    { U_WEEKDAY_ORDINAL, kCFCalendarUnitWeekdayOrdinal, 'F' }, { U_QUARTER, kCFCalendarUnitQuarter, 'Q' },
    { U_WEEK_OF_MONTH, kCFCalendarUnitWeekOfMonth, 'W' }, { U_WEEK_OF_YEAR, kCFCalendarUnitWeekOfYear, 'w' },
    { U_YEAR_FOR_WEEK, kCFCalendarUnitYearForWeekOfYear, 'Y' },
};
#define NUNITS (sizeof(units) / sizeof(units[0]))

static CFCalendarUnit
cf_unit(NSUInteger u)
{
    for (size_t i = 0; i < NUNITS; i++)
        if (units[i].unit == u) return units[i].cf;
    return (CFCalendarUnit)u;
}

@implementation NSCalendar

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSCalendar class] || self == [__NSCFCalendar class]) return (id)calendarPlaceholder;
    return [super allocWithZone:zone];
}

+ (id)calendarWithIdentifier:(id)ident { return [[[self alloc] initWithCalendarIdentifier:ident] autorelease]; }
+ (id)currentCalendar { return owned(CFCalendarCopyCurrent()); }
+ (id)autoupdatingCurrentCalendar { return [self currentCalendar]; }

- (CFTypeID)_cfTypeID { return CFCalendarGetTypeID(); }

- (id)copyWithZone:(struct _NSZone *)zone
{
    CFCalendarRef c = CFCalendarCreateWithIdentifier(NULL, CFCalendarGetIdentifier((CFCalendarRef)self));
    CFTimeZoneRef tz = CFCalendarCopyTimeZone((CFCalendarRef)self);
    CFLocaleRef l = CFCalendarCopyLocale((CFCalendarRef)self);
    CFCalendarSetTimeZone(c, tz);
    CFCalendarSetLocale(c, l);
    CFCalendarSetFirstWeekday(c, CFCalendarGetFirstWeekday((CFCalendarRef)self));
    CFCalendarSetMinimumDaysInFirstWeek(c, CFCalendarGetMinimumDaysInFirstWeek((CFCalendarRef)self));
    if (tz) CFRelease(tz);
    if (l) CFRelease(l);
    return (id)c;
}

- (id)calendarIdentifier { return (id)CFCalendarGetIdentifier((CFCalendarRef)self); }
- (id)locale { return owned(CFCalendarCopyLocale((CFCalendarRef)self)); }
- (void)setLocale:(id)l { CFCalendarSetLocale((CFCalendarRef)self, (CFLocaleRef)l); }
- (id)timeZone { return owned(CFCalendarCopyTimeZone((CFCalendarRef)self)); }
- (void)setTimeZone:(id)tz { CFCalendarSetTimeZone((CFCalendarRef)self, (CFTimeZoneRef)tz); }
- (NSUInteger)firstWeekday { return (NSUInteger)CFCalendarGetFirstWeekday((CFCalendarRef)self); }
- (void)setFirstWeekday:(NSUInteger)d { CFCalendarSetFirstWeekday((CFCalendarRef)self, (CFIndex)d); }
- (NSUInteger)minimumDaysInFirstWeek { return (NSUInteger)CFCalendarGetMinimumDaysInFirstWeek((CFCalendarRef)self); }
- (void)setMinimumDaysInFirstWeek:(NSUInteger)d { CFCalendarSetMinimumDaysInFirstWeek((CFCalendarRef)self, (CFIndex)d); }

- (NSDateComponents *)components:(NSUInteger)unitFlags fromDate:(id)date
{
    NSDateComponents *c = [[[NSDateComponents alloc] init] autorelease];
    CFAbsoluteTime at = [date timeIntervalSinceReferenceDate];
    char fmt[NUNITS + 1];
    int vals[NUNITS];
    size_t n = 0, which[NUNITS];
    for (size_t i = 0; i < NUNITS; i++)
        if (unitFlags & units[i].unit) { fmt[n] = units[i].letter; which[n] = i; n++; }
    fmt[n] = 0;
    if (n) {
        int *p[NUNITS];
        for (size_t i = 0; i < n; i++) p[i] = &vals[i];
        Boolean ok;
        switch (n) {   /* CFCalendarDecomposeAbsoluteTime is variadic: one pointer per letter */
#define P(k) p[k]
        case 1: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0)); break;
        case 2: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1)); break;
        case 3: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2)); break;
        case 4: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3)); break;
        case 5: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3), P(4)); break;
        case 6: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3), P(4), P(5)); break;
        case 7: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3), P(4), P(5), P(6)); break;
        case 8: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3), P(4), P(5), P(6), P(7)); break;
        case 9: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3), P(4), P(5), P(6), P(7), P(8)); break;
        case 10: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3), P(4), P(5), P(6), P(7), P(8), P(9)); break;
        case 11: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3), P(4), P(5), P(6), P(7), P(8), P(9), P(10)); break;
        case 12: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3), P(4), P(5), P(6), P(7), P(8), P(9), P(10), P(11)); break;
        default: ok = CFCalendarDecomposeAbsoluteTime((CFCalendarRef)self, at, fmt, P(0), P(1), P(2), P(3), P(4), P(5), P(6), P(7), P(8), P(9), P(10), P(11), P(12)); break;
#undef P
        }
        if (ok)
            for (size_t i = 0; i < n; i++) [c setValue:vals[i] forComponent:units[which[i]].unit];
    }
    if (unitFlags & U_NANOSECOND) {
        double whole = floor(at);
        c->_nanosecond = (NSInteger)llround((at - whole) * 1e9);
    }
    if (unitFlags & U_CALENDAR) [c setCalendar:self];
    if (unitFlags & U_TIME_ZONE) [c setTimeZone:[self timeZone]];
    return c;
}

- (NSInteger)component:(NSUInteger)unit fromDate:(id)date
{
    return [[self components:unit fromDate:date] valueForComponent:unit];
}

- (NSDateComponents *)componentsInTimeZone:(id)tz fromDate:(id)date
{
    NSCalendar *c = [[self copy] autorelease];
    [c setTimeZone:tz];
    NSDateComponents *dc = [c components:0x3FFFFE | U_CALENDAR | U_TIME_ZONE fromDate:date];
    return dc;
}

/* Undefined components default as Apple's do: year 1, month 1, day 1, 0:00. */
- (id)dateFromComponents:(NSDateComponents *)c
{
    int era = c->_era == NSDateComponentUndefined ? -1 : (int)c->_era;
    int y = c->_year == NSDateComponentUndefined ? 1 : (int)c->_year;
    int M = c->_month == NSDateComponentUndefined ? 1 : (int)c->_month;
    int d = c->_day == NSDateComponentUndefined ? 1 : (int)c->_day;
    int H = c->_hour == NSDateComponentUndefined ? 0 : (int)c->_hour;
    int m = c->_minute == NSDateComponentUndefined ? 0 : (int)c->_minute;
    int s = c->_second == NSDateComponentUndefined ? 0 : (int)c->_second;
    CFCalendarRef cal = (CFCalendarRef)self;
    CFCalendarRef zoned = NULL;
    if (c->_timeZone) {
        zoned = (CFCalendarRef)[self copy];
        CFCalendarSetTimeZone(zoned, (CFTimeZoneRef)c->_timeZone);
        cal = zoned;
    }
    CFAbsoluteTime at;
    Boolean ok;
    if (c->_weekOfYear != NSDateComponentUndefined && c->_yearForWeekOfYear != NSDateComponentUndefined) {
        int w = (int)c->_weekOfYear, Y = (int)c->_yearForWeekOfYear, E = c->_weekday == NSDateComponentUndefined ? (int)CFCalendarGetFirstWeekday(cal) : (int)c->_weekday;
        ok = CFCalendarComposeAbsoluteTime(cal, &at, "YwEHms", Y, w, E, H, m, s);
    } else if (era >= 0) {
        ok = CFCalendarComposeAbsoluteTime(cal, &at, "GyMdHms", era, y, M, d, H, m, s);
    } else {
        ok = CFCalendarComposeAbsoluteTime(cal, &at, "yMdHms", y, M, d, H, m, s);
    }
    if (zoned) CFRelease(zoned);
    if (!ok) return nil;
    if (c->_nanosecond != NSDateComponentUndefined) at += c->_nanosecond / 1e9;
    return [NSDate dateWithTimeIntervalSinceReferenceDate:at];
}

- (id)dateByAddingComponents:(NSDateComponents *)c toDate:(id)date options:(NSUInteger)opts
{
    CFAbsoluteTime at = [date timeIntervalSinceReferenceDate];
    int y = c->_year == NSDateComponentUndefined ? 0 : (int)c->_year, M = c->_month == NSDateComponentUndefined ? 0 : (int)c->_month,
        d = c->_day == NSDateComponentUndefined ? 0 : (int)c->_day, H = c->_hour == NSDateComponentUndefined ? 0 : (int)c->_hour,
        m = c->_minute == NSDateComponentUndefined ? 0 : (int)c->_minute, s = c->_second == NSDateComponentUndefined ? 0 : (int)c->_second,
        w = c->_weekOfYear == NSDateComponentUndefined ? (c->_week == NSDateComponentUndefined ? 0 : (int)c->_week) : (int)c->_weekOfYear;
    if (!CFCalendarAddComponents((CFCalendarRef)self, &at, (CFOptionFlags)opts, "yMdHmsw", y, M, d, H, m, s, w)) return nil;
    if (c->_nanosecond != NSDateComponentUndefined) at += c->_nanosecond / 1e9;
    return [NSDate dateWithTimeIntervalSinceReferenceDate:at];
}

- (id)dateByAddingUnit:(NSUInteger)unit value:(NSInteger)value toDate:(id)date options:(NSUInteger)opts
{
    NSDateComponents *c = [[[NSDateComponents alloc] init] autorelease];
    [c setValue:value forComponent:unit];
    return [self dateByAddingComponents:c toDate:date options:opts];
}

- (NSDateComponents *)components:(NSUInteger)unitFlags fromDate:(id)start toDate:(id)end options:(NSUInteger)opts
{
    NSDateComponents *c = [[[NSDateComponents alloc] init] autorelease];
    int y = 0, M = 0, d = 0, H = 0, m = 0, s = 0, w = 0;
    char fmt[8];
    int *ptrs[7], n = 0;
    NSUInteger ws[7];
    struct { NSUInteger unit; char letter; int *p; } order[] = {
        { U_YEAR, 'y', &y }, { U_MONTH, 'M', &M }, { U_WEEK_OF_YEAR, 'w', &w }, { U_DAY, 'd', &d },
        { U_HOUR, 'H', &H }, { U_MINUTE, 'm', &m }, { U_SECOND, 's', &s },
    };
    for (int i = 0; i < 7; i++)
        if (unitFlags & order[i].unit) { fmt[n] = order[i].letter; ptrs[n] = order[i].p; ws[n] = order[i].unit; n++; }
    fmt[n] = 0;
    CFAbsoluteTime a = [start timeIntervalSinceReferenceDate], b = [end timeIntervalSinceReferenceDate];
    Boolean ok = n == 0 || CFCalendarGetComponentDifference((CFCalendarRef)self, a, b, (CFOptionFlags)opts, fmt,
        ptrs[0], n > 1 ? ptrs[1] : NULL, n > 2 ? ptrs[2] : NULL, n > 3 ? ptrs[3] : NULL, n > 4 ? ptrs[4] : NULL,
        n > 5 ? ptrs[5] : NULL, n > 6 ? ptrs[6] : NULL);
    if (ok)
        for (int i = 0; i < n; i++) [c setValue:*ptrs[i] forComponent:ws[i]];
    return c;
}

- (NSRange)minimumRangeOfUnit:(NSUInteger)unit
{
    CFRange r = CFCalendarGetMinimumRangeOfUnit((CFCalendarRef)self, cf_unit(unit));
    return NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
}
- (NSRange)maximumRangeOfUnit:(NSUInteger)unit
{
    CFRange r = CFCalendarGetMaximumRangeOfUnit((CFCalendarRef)self, cf_unit(unit));
    return NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
}
- (NSRange)rangeOfUnit:(NSUInteger)smaller inUnit:(NSUInteger)larger forDate:(id)date
{
    CFRange r = CFCalendarGetRangeOfUnit((CFCalendarRef)self, cf_unit(smaller), cf_unit(larger), [date timeIntervalSinceReferenceDate]);
    return NSMakeRange(r.location == kCFNotFound ? NSNotFound : (NSUInteger)r.location, (NSUInteger)r.length);
}
- (NSUInteger)ordinalityOfUnit:(NSUInteger)smaller inUnit:(NSUInteger)larger forDate:(id)date
{
    CFIndex o = CFCalendarGetOrdinalityOfUnit((CFCalendarRef)self, cf_unit(smaller), cf_unit(larger), [date timeIntervalSinceReferenceDate]);
    return o == kCFNotFound ? NSNotFound : (NSUInteger)o;
}
- (BOOL)rangeOfUnit:(NSUInteger)unit startDate:(id *)start interval:(NSTimeInterval *)interval forDate:(id)date
{
    CFAbsoluteTime s;
    CFTimeInterval i;
    if (!CFCalendarGetTimeRangeOfUnit((CFCalendarRef)self, cf_unit(unit), [date timeIntervalSinceReferenceDate], &s, &i)) return NO;
    if (start) *start = [NSDate dateWithTimeIntervalSinceReferenceDate:s];
    if (interval) *interval = i;
    return YES;
}

- (id)startOfDayForDate:(id)date
{
    id start = nil;
    [self rangeOfUnit:U_DAY startDate:&start interval:NULL forDate:date];
    return start;
}

- (BOOL)isDate:(id)a inSameDayAsDate:(id)b
{
    return [[self startOfDayForDate:a] timeIntervalSinceReferenceDate] == [[self startOfDayForDate:b] timeIntervalSinceReferenceDate];
}
- (BOOL)isDateInToday:(id)date { return [self isDate:date inSameDayAsDate:[NSDate date]]; }
- (BOOL)isDateInWeekend:(id)date
{
    NSInteger wd = [self component:U_WEEKDAY fromDate:date];
    return wd == 1 || wd == 7;
}

- (id)dateBySettingHour:(NSInteger)h minute:(NSInteger)m second:(NSInteger)s ofDate:(id)date options:(NSUInteger)opts
{
    NSDateComponents *c = [self components:U_ERA | U_YEAR | U_MONTH | U_DAY fromDate:date];
    c->_hour = h;
    c->_minute = m;
    c->_second = s;
    return [self dateFromComponents:c];
}

- (id)dateWithEra:(NSInteger)era year:(NSInteger)y month:(NSInteger)M day:(NSInteger)d hour:(NSInteger)H minute:(NSInteger)m
           second:(NSInteger)s nanosecond:(NSInteger)ns
{
    NSDateComponents *c = [[[NSDateComponents alloc] init] autorelease];
    c->_era = era; c->_year = y; c->_month = M; c->_day = d; c->_hour = H; c->_minute = m; c->_second = s; c->_nanosecond = ns;
    return [self dateFromComponents:c];
}

#define SYMBOLS(sel, key) - (id)sel { \
        CFLocaleRef l = CFCalendarCopyLocale((CFCalendarRef)self); \
        CFDateFormatterRef f = CFDateFormatterCreate(NULL, l, kCFDateFormatterNoStyle, kCFDateFormatterNoStyle); \
        id v = owned(CFDateFormatterCopyProperty(f, key)); CFRelease(f); if (l) CFRelease(l); return v; }
SYMBOLS(monthSymbols, kCFDateFormatterMonthSymbols)
SYMBOLS(shortMonthSymbols, kCFDateFormatterShortMonthSymbols)
SYMBOLS(weekdaySymbols, kCFDateFormatterWeekdaySymbols)
SYMBOLS(shortWeekdaySymbols, kCFDateFormatterShortWeekdaySymbols)
SYMBOLS(AMSymbol, kCFDateFormatterAMSymbol)
SYMBOLS(PMSymbol, kCFDateFormatterPMSymbol)
SYMBOLS(eraSymbols, kCFDateFormatterEraSymbols)
#undef SYMBOLS

- (BOOL)isEqual:(id)other { return other == self || (other && CFEqual((CFTypeRef)self, (CFTypeRef)other)); }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }

@end

@implementation __NSPlaceholderCalendar
FINCH_IMMORTAL_MEMORY
- (instancetype)initWithCalendarIdentifier:(id)ident
{
    return ident ? (id)CFCalendarCreateWithIdentifier(NULL, (CFStringRef)ident) : nil;
}
@end

@implementation __NSCFCalendar
FINCH_CF_OBJECT_MEMORY
@end

CF_PRIVATE void
__CFFinchInitializeLocaleClasses(Class *locale, Class *zone, Class *calendar)
{
    localePlaceholder = class_createInstance([__NSPlaceholderLocale class], 0);
    zonePlaceholder = class_createInstance([__NSPlaceholderTimeZone class], 0);
    calendarPlaceholder = class_createInstance([__NSPlaceholderCalendar class], 0);
    *locale = [__NSCFLocale class];
    *zone = [__NSCFTimeZone class];
    *calendar = [__NSCFCalendar class];
}
