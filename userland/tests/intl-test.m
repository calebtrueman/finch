/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-intl-test: NSLocale, NSTimeZone, NSCalendar, NSDateComponents,
 * NSDateFormatter, NSNumberFormatter and NSUserDefaults, one result per
 * line so runs against Apple's Foundation and Finch's can be diffed. Every
 * locale and time zone is named explicitly; nothing depends on the
 * machine's settings or the clock.
 */
#import <Foundation/Foundation.h>

static NSDate *
at(NSTimeInterval t)
{
    return [NSDate dateWithTimeIntervalSince1970:t];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        /* Locales */
        NSLocale *fr = [NSLocale localeWithLocaleIdentifier:@"fr_CA"];
        printf("bridged: %d\n", CFGetTypeID((__bridge CFTypeRef)fr) == CFLocaleGetTypeID());
        printf("locale: %s %s %s\n", fr.localeIdentifier.UTF8String, fr.languageCode.UTF8String, fr.countryCode.UTF8String);
        printf("display: %s | %s | %s\n", [fr displayNameForKey:NSLocaleIdentifier value:@"de_DE"].UTF8String,
            [[NSLocale localeWithLocaleIdentifier:@"en_US"] localizedStringForLanguageCode:@"ja"].UTF8String,
            [[NSLocale localeWithLocaleIdentifier:@"en_US"] localizedStringForCountryCode:@"NZ"].UTF8String);
        printf("separators: %s %s currency %s %s metric %d\n", [fr objectForKey:NSLocaleDecimalSeparator] ? [[fr objectForKey:NSLocaleDecimalSeparator] UTF8String] : "-",
            fr.groupingSeparator.UTF8String, fr.currencyCode.UTF8String, fr.currencySymbol.UTF8String, fr.usesMetricSystem);
        printf("canonical: %s %s\n", [NSLocale canonicalLocaleIdentifierFromString:@"en-us"].UTF8String,
            [NSLocale canonicalLanguageIdentifierFromString:@"zh-hant-tw"].UTF8String);
        NSDictionary *comps = [NSLocale componentsFromLocaleIdentifier:@"sr_Latn_RS"];
        printf("components: %s %s %s\n", [comps[NSLocaleLanguageCode] UTF8String], [comps[NSLocaleScriptCode] UTF8String], [comps[NSLocaleCountryCode] UTF8String]);
        printf("direction: %lu %lu\n", (unsigned long)[NSLocale characterDirectionForLanguage:@"ar"], (unsigned long)[NSLocale characterDirectionForLanguage:@"en"]);
        printf("ISO lists: %d %d %d\n", [NSLocale.ISOLanguageCodes containsObject:@"fr"], [NSLocale.ISOCountryCodes containsObject:@"CA"],
            [NSLocale.ISOCurrencyCodes containsObject:@"EUR"]);
        printf("equal: %d %d\n", [fr isEqual:[NSLocale localeWithLocaleIdentifier:@"fr_CA"]], [fr isEqual:[NSLocale localeWithLocaleIdentifier:@"fr_FR"]]);

        /* Time zones */
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:@"America/Toronto"];
        printf("zone: %s bridged %d\n", tz.name.UTF8String, CFGetTypeID((__bridge CFTypeRef)tz) == CFTimeZoneGetTypeID());
        printf("winter: %s %ld dst %d\n", [tz abbreviationForDate:at(0)].UTF8String, (long)[tz secondsFromGMTForDate:at(0)], [tz isDaylightSavingTimeForDate:at(0)]);
        printf("summer: %s %ld dst %d offset %.0f\n", [tz abbreviationForDate:at(1690000000)].UTF8String, (long)[tz secondsFromGMTForDate:at(1690000000)],
            [tz isDaylightSavingTimeForDate:at(1690000000)], [tz daylightSavingTimeOffsetForDate:at(1690000000)]);
        printf("next transition: %.0f\n", [tz nextDaylightSavingTimeTransitionAfterDate:at(1700000000)].timeIntervalSince1970);
        printf("fixed: %s %s %ld\n", [NSTimeZone timeZoneForSecondsFromGMT:0].name.UTF8String, [NSTimeZone timeZoneForSecondsFromGMT:-18000].name.UTF8String,
            (long)[NSTimeZone timeZoneForSecondsFromGMT:19800].secondsFromGMT);
        printf("abbreviation: %s %s\n", [NSTimeZone timeZoneWithAbbreviation:@"PST"].name.UTF8String, [NSTimeZone timeZoneWithAbbreviation:@"JST"].name.UTF8String);
        printf("bad name: %s\n", [NSTimeZone timeZoneWithName:@"Not/AZone"] ? "zone" : "nil");
        printf("known names include Tokyo: %d\n", [NSTimeZone.knownTimeZoneNames containsObject:@"Asia/Tokyo"]);
        printf("localized: %s\n", [tz localizedName:NSTimeZoneNameStyleStandard locale:[NSLocale localeWithLocaleIdentifier:@"en_US"]].UTF8String);
        printf("zone equal: %d\n", [tz isEqualToTimeZone:[NSTimeZone timeZoneWithName:@"America/Toronto"]]);

        /* Calendars */
        NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        cal.timeZone = tz;
        cal.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        printf("calendar: %s first weekday %lu min days %lu\n", cal.calendarIdentifier.UTF8String, (unsigned long)cal.firstWeekday, (unsigned long)cal.minimumDaysInFirstWeek);
        NSDateComponents *c = [cal components:NSCalendarUnitEra | NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour |
            NSCalendarUnitMinute | NSCalendarUnitSecond | NSCalendarUnitWeekday | NSCalendarUnitWeekOfYear | NSCalendarUnitQuarter fromDate:at(1700000000)];
        printf("components: era %ld %ld-%ld-%ld %ld:%ld:%ld weekday %ld week %ld\n", (long)c.era, (long)c.year, (long)c.month, (long)c.day,
            (long)c.hour, (long)c.minute, (long)c.second, (long)c.weekday, (long)c.weekOfYear);
        printf("undefined month in day-only: %d\n", [cal components:NSCalendarUnitDay fromDate:at(0)].month == NSDateComponentUndefined);
        NSDateComponents *make = [[NSDateComponents alloc] init];
        make.year = 2024; make.month = 2; make.day = 29; make.hour = 13; make.minute = 30;
        printf("dateFromComponents: %.0f\n", [cal dateFromComponents:make].timeIntervalSince1970);
        NSDateComponents *add = [[NSDateComponents alloc] init];
        add.month = 1; add.day = 1;
        printf("dateByAddingComponents (Feb 29 + 1m1d): %.0f\n", [cal dateByAddingComponents:add toDate:[cal dateFromComponents:make] options:0].timeIntervalSince1970);
        printf("dateByAddingUnit year: %.0f\n", [cal dateByAddingUnit:NSCalendarUnitYear value:1 toDate:[cal dateFromComponents:make] options:0].timeIntervalSince1970);
        NSDateComponents *diff = [cal components:NSCalendarUnitDay | NSCalendarUnitHour fromDate:at(1700000000) toDate:at(1700000000 + 3 * 86400 + 7200) options:0];
        printf("difference: %ld days %ld hours\n", (long)diff.day, (long)diff.hour);
        NSRange days = [cal rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:[cal dateFromComponents:make]];
        printf("days in Feb 2024: %lu-%lu\n", (unsigned long)days.location, (unsigned long)(days.location + days.length - 1));
        printf("ordinality of day in year: %lu\n", (unsigned long)[cal ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitYear forDate:[cal dateFromComponents:make]]);
        printf("start of day: %.0f\n", [cal startOfDayForDate:at(1700000000)].timeIntervalSince1970);
        printf("same day: %d %d\n", [cal isDate:at(1700000000) inSameDayAsDate:at(1700000000 + 600)], [cal isDate:at(1700000000) inSameDayAsDate:at(1700000000 + 86400)]);
        printf("weekend: %d\n", [cal isDateInWeekend:at(1700000000 + 4 * 86400)]);
        printf("set hour: %.0f\n", [cal dateBySettingHour:9 minute:0 second:0 ofDate:at(1700000000) options:0].timeIntervalSince1970);
        printf("month symbols: %s ... %s\n", [cal.monthSymbols.firstObject UTF8String], [cal.shortWeekdaySymbols.lastObject UTF8String]);
        NSCalendar *japanese = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierJapanese];
        japanese.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        NSDateComponents *jc = [japanese components:NSCalendarUnitEra | NSCalendarUnitYear fromDate:at(1700000000)];
        printf("japanese: era %ld year %ld\n", (long)jc.era, (long)jc.year);

        /* Date formatters */
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
        printf("ISO: %s\n", [f stringFromDate:at(1700000000)].UTF8String);
        printf("parse: %.0f %s\n", [f dateFromString:@"2020-02-29T12:00:00Z"].timeIntervalSince1970, [f dateFromString:@"garbage"] ? "date" : "nil");
        f.dateFormat = @"EEEE, d MMMM yyyy h:mm a";
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        printf("custom: %s\n", [f stringFromDate:at(1700000000)].UTF8String);
        f.locale = [NSLocale localeWithLocaleIdentifier:@"de_DE"];
        printf("custom de: %s\n", [f stringFromDate:at(1700000000)].UTF8String);
        NSDateFormatter *s = [[NSDateFormatter alloc] init];
        s.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        s.timeZone = tz;
        s.dateStyle = NSDateFormatterLongStyle;
        s.timeStyle = NSDateFormatterShortStyle;
        printf("styled: %s\n", [s stringFromDate:at(1700000000)].UTF8String);
        s.dateStyle = NSDateFormatterShortStyle;
        s.timeStyle = NSDateFormatterNoStyle;
        printf("short: %s format %s\n", [s stringFromDate:at(1700000000)].UTF8String, s.dateFormat.UTF8String);
        s.locale = [NSLocale localeWithLocaleIdentifier:@"ja_JP"];
        s.dateStyle = NSDateFormatterFullStyle;
        printf("japanese full: %s\n", [s stringFromDate:at(1700000000)].UTF8String);
        printf("template: %s\n", [NSDateFormatter dateFormatFromTemplate:@"yMMMd" options:0 locale:[NSLocale localeWithLocaleIdentifier:@"en_GB"]].UTF8String);
        printf("symbols: %s %s %s\n", [f.monthSymbols[2] UTF8String], f.AMSymbol.UTF8String, [f.weekdaySymbols.firstObject UTF8String]);

        /* Number formatters */
        NSNumberFormatter *n = [[NSNumberFormatter alloc] init];
        n.locale = [NSLocale localeWithLocaleIdentifier:@"de_DE"];
        n.numberStyle = NSNumberFormatterDecimalStyle;
        printf("decimal: %s\n", [n stringFromNumber:@1234567.891].UTF8String);
        n.numberStyle = NSNumberFormatterCurrencyStyle;
        printf("currency: %s\n", [n stringFromNumber:@12.5].UTF8String);
        n.numberStyle = NSNumberFormatterPercentStyle;
        printf("percent: %s\n", [n stringFromNumber:@0.256].UTF8String);
        n.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        n.numberStyle = NSNumberFormatterScientificStyle;
        printf("scientific: %s\n", [n stringFromNumber:@12345.678].UTF8String);
        n.numberStyle = NSNumberFormatterSpellOutStyle;
        printf("spell out: %s\n", [n stringFromNumber:@42].UTF8String);
        n.numberStyle = NSNumberFormatterOrdinalStyle;
        printf("ordinal: %s\n", [n stringFromNumber:@3].UTF8String);
        n.numberStyle = NSNumberFormatterDecimalStyle;
        n.minimumFractionDigits = 2;
        n.maximumFractionDigits = 2;
        printf("fraction digits: %s %s\n", [n stringFromNumber:@3].UTF8String, [n stringFromNumber:@3.14159].UTF8String);
        n.usesGroupingSeparator = NO;
        printf("no grouping: %s\n", [n stringFromNumber:@1234567].UTF8String);
        NSNumberFormatter *p = [[NSNumberFormatter alloc] init];
        p.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        p.numberStyle = NSNumberFormatterDecimalStyle;
        printf("parse: %s %s %s\n", [p numberFromString:@"1,234.5"].description.UTF8String, [p numberFromString:@"abc"] ? "number" : "nil",
            [p numberFromString:@"-7"].description.UTF8String);
        printf("localized: %s\n", [NSNumberFormatter localizedStringFromNumber:@0 numberStyle:NSNumberFormatterNoStyle].UTF8String);

        /* Defaults */
        NSString *suite = @"org.finch.test.intl-defaults";
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [d removePersistentDomainForName:suite];
        [d registerDefaults:@{ @"registered": @"from registration", @"i": @1 }];
        printf("registered: %s %ld\n", [d stringForKey:@"registered"].UTF8String, (long)[d integerForKey:@"i"]);
        [d setObject:@"v" forKey:@"k"];
        [d setInteger:7 forKey:@"i"];
        [d setBool:YES forKey:@"b"];
        [d setDouble:2.5 forKey:@"dbl"];
        [d setObject:@[ @"x", @"y" ] forKey:@"list"];
        [d setObject:@"12" forKey:@"numeric string"];
        printf("values: %s %ld %d %.1f %lu %s\n", [d stringForKey:@"k"].UTF8String, (long)[d integerForKey:@"i"], [d boolForKey:@"b"], [d doubleForKey:@"dbl"],
            (unsigned long)[d stringArrayForKey:@"list"].count, [d objectForKey:@"none"] ? "x" : "nil");
        printf("conversions: %ld %s %d %s\n", (long)[d integerForKey:@"numeric string"], [d stringForKey:@"i"].UTF8String, [d boolForKey:@"k"],
            [d arrayForKey:@"k"] ? "array" : "nil");
        [d removeObjectForKey:@"i"];
        printf("removed falls back to registration: %ld\n", (long)[d integerForKey:@"i"]);
        [d synchronize];
        NSDictionary *persisted = [d persistentDomainForName:suite];
        printf("persistent domain keys: %s\n", [[persisted.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
        [d removePersistentDomainForName:suite];
        printf("after removing domain: %s\n", [d stringForKey:@"k"] ? [d stringForKey:@"k"].UTF8String : "nil");
    }
    printf("done\n");
    return 0;
}
