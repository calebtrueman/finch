/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Date values, range limits and calendar drawing shared by date pickers. */
#import "NSControl_Finch.h"

@implementation NSDatePickerCell {
    NSDatePickerStyle _style;
    NSDatePickerMode _mode;
    NSDatePickerElementFlags _elements;
    NSCalendar *_calendar;
    NSLocale *_locale;
    NSTimeZone *_zone;
    NSDate *_date, *_minimum, *_maximum;
    NSColor *_background, *_text;
    id _delegate;
    NSTimeInterval _interval;
    BOOL _drawsBackground;
}
- (instancetype)init { return [self initTextCell:@""]; }
- (instancetype)initTextCell:(NSString *)s
{
    if (!(self = [super initTextCell:s])) return nil;
    _date = [[NSDate dateWithTimeIntervalSinceReferenceDate:0] copy];
    _elements = NSDatePickerElementFlagYearMonthDay | NSDatePickerElementFlagHourMinuteSecond;
    _background = [[NSColor controlBackgroundColor] retain]; _text = [[NSColor controlTextColor] retain];
    [self setBezeled:YES]; [self setEditable:NO]; [self setSelectable:NO];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder])) return nil;
    id value = [coder decodeObjectForKey:@"NSContents"];
    _date = [([value isKindOfClass:[NSDate class]] ? value : [NSDate dateWithTimeIntervalSinceReferenceDate:0]) copy];
    if ([coder decodeBoolForKey:@"NSDatePickerUseCurrentDateDuringDecoding"]) { [_date release]; _date = [[NSDate date] retain]; }
    _style = [coder decodeIntegerForKey:@"NSDatePickerStyle"];
    _mode = [coder decodeIntegerForKey:@"NSDatePickerMode"];
    _elements = [coder containsValueForKey:@"NSDatePickerElements"] ? [coder decodeIntegerForKey:@"NSDatePickerElements"] : 238;
    _interval = [coder decodeDoubleForKey:@"NSTimeInterval"];
    _minimum = [[coder decodeObjectForKey:@"NSMinDate"] copy]; _maximum = [[coder decodeObjectForKey:@"NSMaxDate"] copy];
    _calendar = [[coder decodeObjectForKey:@"NSCalendar"] copy]; _locale = [[coder decodeObjectForKey:@"NSLocale"] copy];
    _zone = [[coder decodeObjectForKey:@"NSTimeZone"] copy];
    _background = [[coder decodeObjectForKey:@"NSBackgroundColor"] copy] ?: [[NSColor controlBackgroundColor] retain];
    _text = [[coder decodeObjectForKey:@"NSTextColor"] copy] ?: [[NSColor controlTextColor] retain];
    _drawsBackground = [coder decodeBoolForKey:@"NSDrawsBackground"];
    _delegate = [coder decodeObjectForKey:@"NSDelegate"];
    [self setDateValue:_date]; return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder]; [coder encodeObject:_date forKey:@"NSContents"];
    [coder encodeInteger:_style forKey:@"NSDatePickerStyle"]; [coder encodeInteger:_mode forKey:@"NSDatePickerMode"];
    [coder encodeInteger:_elements forKey:@"NSDatePickerElements"]; [coder encodeDouble:_interval forKey:@"NSTimeInterval"];
    [coder encodeObject:_minimum forKey:@"NSMinDate"]; [coder encodeObject:_maximum forKey:@"NSMaxDate"];
    [coder encodeObject:_calendar forKey:@"NSCalendar"]; [coder encodeObject:_locale forKey:@"NSLocale"];
    [coder encodeObject:_zone forKey:@"NSTimeZone"]; [coder encodeObject:_background forKey:@"NSBackgroundColor"];
    [coder encodeObject:_text forKey:@"NSTextColor"]; [coder encodeBool:_drawsBackground forKey:@"NSDrawsBackground"];
    [coder encodeConditionalObject:_delegate forKey:@"NSDelegate"];
}
- (void)dealloc
{
    [_date release]; [_minimum release]; [_maximum release]; [_calendar release]; [_locale release];
    [_zone release]; [_background release]; [_text release]; [super dealloc];
}
- (id)copyWithZone:(NSZone *)zone
{
    NSDatePickerCell *c = [super copyWithZone:zone];
    [c->_date retain]; [c->_minimum retain]; [c->_maximum retain]; [c->_calendar retain]; [c->_locale retain];
    [c->_zone retain]; [c->_background retain]; [c->_text retain]; return c;
}
- (NSDatePickerStyle)datePickerStyle { return _style; }
- (void)setDatePickerStyle:(NSDatePickerStyle)s { _style = s; [self _finchChanged]; }
- (NSDatePickerMode)datePickerMode { return _mode; }
- (void)setDatePickerMode:(NSDatePickerMode)m { _mode = m; [self _finchChanged]; }
- (NSDatePickerElementFlags)datePickerElements { return _elements; }
- (void)setDatePickerElements:(NSDatePickerElementFlags)e { _elements = e; [self _finchChanged]; }
- (BOOL)drawsBackground { return _drawsBackground; }
- (void)setDrawsBackground:(BOOL)b { _drawsBackground = b; [self _finchChanged]; }
- (NSColor *)backgroundColor { return _background; }
- (void)setBackgroundColor:(NSColor *)c { NSColor *copy = [c copy]; [_background release]; _background = copy; [self _finchChanged]; }
- (NSColor *)textColor { return _text; }
- (void)setTextColor:(NSColor *)c { NSColor *copy = [c copy]; [_text release]; _text = copy; [self _finchChanged]; }
- (NSCalendar *)calendar { return _calendar; }
- (void)setCalendar:(NSCalendar *)c { NSCalendar *copy = [c copy]; [_calendar release]; _calendar = copy; [self _finchChanged]; }
- (NSLocale *)locale { return _locale; }
- (void)setLocale:(NSLocale *)l { NSLocale *copy = [l copy]; [_locale release]; _locale = copy; [self _finchChanged]; }
- (NSTimeZone *)timeZone { return _zone; }
- (void)setTimeZone:(NSTimeZone *)z { NSTimeZone *copy = [z copy]; [_zone release]; _zone = copy; [self _finchChanged]; }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (NSDate *)dateValue { return _date; }
- (void)setDateValue:(NSDate *)d
{
    if (![d isKindOfClass:[NSDate class]]) return;
    if ([_delegate respondsToSelector:@selector(datePickerCell:validateProposedDateValue:timeInterval:)])
        [_delegate datePickerCell:self validateProposedDateValue:&d timeInterval:&_interval];
    if (![d isKindOfClass:[NSDate class]]) return;
    if (_minimum && [d compare:_minimum] == NSOrderedAscending) d = _minimum;
    if (_maximum && [d compare:_maximum] == NSOrderedDescending) d = _maximum;
    if (_mode == NSDatePickerModeRange && _maximum && _interval > [_maximum timeIntervalSinceDate:d])
        _interval = [_maximum timeIntervalSinceDate:d];
    NSDate *copy = [d copy]; [_date release]; _date = copy; [self _finchChanged];
}
- (id)objectValue { return _date; }
- (void)setObjectValue:(id)o { if ([o isKindOfClass:[NSDate class]]) [self setDateValue:o]; }
- (NSTimeInterval)timeInterval { return _interval; }
- (void)setTimeInterval:(NSTimeInterval)t { _interval = t; [self _finchChanged]; }
- (NSDate *)minDate { return _minimum; }
- (void)setMinDate:(NSDate *)d { NSDate *copy = [d copy]; [_minimum release]; _minimum = copy; [self setDateValue:_date]; }
- (NSDate *)maxDate { return _maximum; }
- (void)setMaxDate:(NSDate *)d { NSDate *copy = [d copy]; [_maximum release]; _maximum = copy; [self setDateValue:_date]; }
- (NSCalendar *)_finchCalendar
{
    NSCalendar *calendar = [[(_calendar ?: [NSCalendar currentCalendar]) copy] autorelease];
    if (_zone) [calendar setTimeZone:_zone];
    return calendar;
}
- (NSDateFormatter *)_finchFormatter
{
    NSDateFormatter *f = [[[NSDateFormatter alloc] init] autorelease];
    if (_calendar) [f setCalendar:_calendar]; if (_locale) [f setLocale:_locale]; if (_zone) [f setTimeZone:_zone];
    return f;
}
- (NSString *)stringValue
{
    NSDateFormatter *f = [self _finchFormatter]; [f setDateStyle:NSDateFormatterFullStyle]; [f setTimeStyle:NSDateFormatterFullStyle];
    return [f stringFromDate:_date] ?: @"";
}
- (void)setStringValue:(NSString *)s
{
    NSDateFormatter *f = [self _finchFormatter]; [f setDateStyle:NSDateFormatterFullStyle]; [f setTimeStyle:NSDateFormatterFullStyle];
    NSDate *date = [f dateFromString:s]; if (date) [self setDateValue:date];
}
- (NSString *)_finchDisplayString
{
    NSMutableString *format = [NSMutableString string];
    if (_elements & NSDatePickerElementFlagYearMonth) [format appendString:(_elements & 0x20) ? @"yMd" : @"yM"];
    if (_elements & NSDatePickerElementFlagEra) [format appendString:@"G"];
    if (_elements & NSDatePickerElementFlagHourMinute) [format appendString:(_elements & 2) ? @"jms" : @"jm"];
    if (_elements & NSDatePickerElementFlagTimeZone) [format appendString:@"z"];
    NSDateFormatter *f = [self _finchFormatter];
    [f setDateFormat:[NSDateFormatter dateFormatFromTemplate:format options:0 locale:_locale ?: [NSLocale currentLocale]]];
    return [f stringFromDate:_date] ?: @"";
}
- (void)_finchSetUserDate:(NSDate *)date interval:(NSTimeInterval)interval
{
    [self setTimeInterval:interval]; if (date) [self setDateValue:date];
}
- (NSSize)cellSizeForBounds:(NSRect)r
{
    if (_style == NSDatePickerStyleClockAndCalendar) return NSMakeSize((_elements & 0xe0) ? ((_elements & 0xe) ? 276 : 196) : 80, 148);
    CGFloat height = [self controlSize] == NSControlSizeSmall ? 22 : [self controlSize] == NSControlSizeMini ? 19 : 26;
    NSSize text = [[self _finchDisplayString] sizeWithAttributes:@{NSFontAttributeName:[self font] ?: [NSFont systemFontOfSize:13]}];
    return NSMakeSize(text.width + (_style == NSDatePickerStyleTextFieldAndStepper ? 30 : 12), height);
}
- (NSRect)drawingRectForBounds:(NSRect)r { return [self isBezeled] || [self isBordered] ? NSInsetRect(r, 3, 3) : r; }
- (NSRect)titleRectForBounds:(NSRect)r { return [self drawingRectForBounds:r]; }
- (NSDictionary *)_finchTextAttributes
{
    NSMutableDictionary *a = [[[super _finchTextAttributes] mutableCopy] autorelease];
    a[NSForegroundColorAttributeName] = FinchDisabled(_text ?: [NSColor controlTextColor], [self isEnabled]); return a;
}
- (void)_finchDrawCalendar:(NSRect)r inView:(NSView *)view
{
    NSCalendar *calendar = [self _finchCalendar];
    NSDateComponents *parts = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:_date];
    NSInteger selectedDay = [parts day]; [parts setDay:1];
    NSDate *first = [calendar dateFromComponents:parts];
    NSInteger weekday = [calendar component:NSCalendarUnitWeekday fromDate:first];
    NSInteger offset = (weekday + 7 - [calendar firstWeekday]) % 7;
    NSInteger count = [calendar rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:first].length;
    NSDateFormatter *f = [self _finchFormatter]; [f setDateFormat:@"MMMM yyyy"];
    NSAttributedString *title = [[[NSAttributedString alloc] initWithString:[f stringFromDate:_date] attributes:[self _finchTextAttributes]] autorelease];
    FinchDrawCellText(title, NSMakeRect(r.origin.x + 20, r.origin.y + 3, r.size.width - 40, 22), [view isFlipped]);
    NSArray *days = [f veryShortStandaloneWeekdaySymbols];
    CGFloat width = r.size.width / 7, height = (r.size.height - 44) / 6;
    for (NSInteger column = 0; column < 7; column++) {
        NSString *day = [days objectAtIndex:(column + [calendar firstWeekday] - 1) % 7];
        NSAttributedString *text = [[[NSAttributedString alloc] initWithString:day attributes:[self _finchTextAttributes]] autorelease];
        FinchDrawCellText(text, NSMakeRect(r.origin.x + column * width + 6, r.origin.y + 25, width - 6, 18), [view isFlipped]);
    }
    for (NSInteger day = 1; day <= count; day++) {
        NSInteger index = day + offset - 1;
        NSRect box = NSMakeRect(r.origin.x + (index % 7) * width, r.origin.y + 44 + (index / 7) * height, width, height);
        if (day == selectedDay) FinchDrawBezel(NSInsetRect(box, 1, 1), 3, [FinchAccentColor() colorWithAlphaComponent:0.23], nil);
        NSAttributedString *text = [[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%ld", (long)day] attributes:[self _finchTextAttributes]] autorelease];
        FinchDrawCellText(text, NSInsetRect(box, 5, 0), [view isFlipped]);
    }
    [FinchDisabled(_text, [self isEnabled]) setStroke];
    for (NSInteger side = 0; side < 2; side++) {
        CGFloat x = side ? NSMaxX(r) - 11 : r.origin.x + 11, direction = side ? 1 : -1;
        NSBezierPath *p = [NSBezierPath bezierPath]; [p setLineWidth:1.4];
        [p moveToPoint:NSMakePoint(x - direction * 2, r.origin.y + 9)]; [p lineToPoint:NSMakePoint(x + direction * 2, r.origin.y + 13)];
        [p lineToPoint:NSMakePoint(x - direction * 2, r.origin.y + 17)]; [p stroke];
    }
}
- (void)drawWithFrame:(NSRect)r inView:(NSView *)view
{
    if ([self isBezeled] || [self isBordered]) FinchDrawBezel(r, 3, _background, FinchControlStroke());
    else if (_drawsBackground) { [_background setFill]; NSRectFill(r); }
    NSRect content = [self drawingRectForBounds:r];
    if (_style == NSDatePickerStyleClockAndCalendar) {
        if (_elements & 0xe0) { NSRect calendar = content; calendar.size.width = MIN(196, content.size.width); [self _finchDrawCalendar:calendar inView:view]; }
        if (_elements & 0xe) {
            NSRect clock = NSMakeRect(NSMaxX(content) - 68, content.origin.y + 35, 64, 64);
            [FinchControlStroke() setStroke]; [[NSBezierPath bezierPathWithOvalInRect:clock] stroke];
            NSCalendar *calendar = [self _finchCalendar]; CGFloat minute = [calendar component:NSCalendarUnitMinute fromDate:_date];
            CGFloat hour = [calendar component:NSCalendarUnitHour fromDate:_date];
            CGFloat angles[] = {(hour + minute / 60) * M_PI / 6 - M_PI_2, minute * M_PI / 30 - M_PI_2};
            [_text setStroke];
            for (int i = 0; i < 2; i++) {
                CGFloat length = i ? 25 : 18; NSBezierPath *hand = [NSBezierPath bezierPath]; [hand setLineWidth:i ? 1.2 : 2];
                [hand moveToPoint:NSMakePoint(NSMidX(clock), NSMidY(clock))];
                [hand lineToPoint:NSMakePoint(NSMidX(clock) + cos(angles[i]) * length, NSMidY(clock) + sin(angles[i]) * length)]; [hand stroke];
            }
        }
    } else {
        if (_style == NSDatePickerStyleTextFieldAndStepper) content.size.width = MAX(0, content.size.width - 18);
        NSAttributedString *text = [[[NSAttributedString alloc] initWithString:[self _finchDisplayString] attributes:[self _finchTextAttributes]] autorelease];
        FinchDrawCellText(text, content, [view isFlipped]);
        if (_style == NSDatePickerStyleTextFieldAndStepper) {
            NSRect step = NSMakeRect(NSMaxX(r) - 17, r.origin.y + 1, 16, r.size.height - 2);
            FinchDrawBezel(step, 3, FinchControlFill(NO), FinchControlStroke()); [_text setStroke];
            for (int i = 0; i < 2; i++) {
                CGFloat y = step.origin.y + step.size.height * (i ? 0.75 : 0.25), direction = i ? 1 : -1;
                NSBezierPath *p = [NSBezierPath bezierPath];
                [p moveToPoint:NSMakePoint(NSMidX(step) - 3, y - direction)]; [p lineToPoint:NSMakePoint(NSMidX(step), y + direction)];
                [p lineToPoint:NSMakePoint(NSMidX(step) + 3, y - direction)]; [p stroke];
            }
        }
    }
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return @"AXDateTimeArea"; }
- (NSString *)accessibilitySubrole { return nil; }
- (id)accessibilityValue { return _date; }
@end
