/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSControl_Finch.h"
#import "NSKeyValueBinding_Finch.h"

@interface NSDatePickerCell (FinchDatePicker)
- (NSCalendar *)_finchCalendar;
- (void)_finchSetUserDate:(NSDate *)date interval:(NSTimeInterval)interval;
@end

@interface NSDatePicker (FinchCalendarOverlay)
- (void)_finchHideCalendar;
@end

@interface _FinchDateCalendarPanel : NSPanel
@property(assign) NSDatePicker *datePicker;
@end
@implementation _FinchDateCalendarPanel
- (void)keyDown:(NSEvent *)event
{
    if ([[event charactersIgnoringModifiers] isEqual:@"\033"]) [_datePicker _finchHideCalendar];
    else [super keyDown:event];
}
@end

@implementation NSDatePicker {
    BOOL _calendarOverlay;
    NSInteger _selectedPart;
    NSString *_digits;
    _FinchDateCalendarPanel *_calendarPanel;
    BOOL _calendarNavigation;
}
+ (Class)cellClass { return [super cellClass] ?: [NSDatePickerCell class]; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) _calendarOverlay = [coder decodeBoolForKey:@"presentsCalendarOverlay"];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder { [super encodeWithCoder:coder]; [coder encodeBool:_calendarOverlay forKey:@"presentsCalendarOverlay"]; }
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self _finchHideCalendar]; [_calendarPanel setDatePicker:nil]; [_calendarPanel release];
    [_digits release]; [super dealloc];
}
- (NSDatePickerStyle)datePickerStyle { return [[self cell] datePickerStyle]; }
- (void)setDatePickerStyle:(NSDatePickerStyle)s { [[self cell] setDatePickerStyle:s]; [self invalidateIntrinsicContentSize]; }
- (NSDatePickerMode)datePickerMode { return [[self cell] datePickerMode]; }
- (void)setDatePickerMode:(NSDatePickerMode)m { [[self cell] setDatePickerMode:m]; }
- (NSDatePickerElementFlags)datePickerElements { return [[self cell] datePickerElements]; }
- (void)setDatePickerElements:(NSDatePickerElementFlags)e { [[self cell] setDatePickerElements:e]; [self invalidateIntrinsicContentSize]; }
- (BOOL)isBezeled { return [[self cell] isBezeled]; }
- (void)setBezeled:(BOOL)b { [[self cell] setBezeled:b]; }
- (BOOL)isBordered { return [[self cell] isBordered]; }
- (void)setBordered:(BOOL)b { [[self cell] setBordered:b]; }
- (BOOL)drawsBackground { return [[self cell] drawsBackground]; }
- (void)setDrawsBackground:(BOOL)b { [[self cell] setDrawsBackground:b]; }
- (NSColor *)backgroundColor { return [[self cell] backgroundColor]; }
- (void)setBackgroundColor:(NSColor *)c { [[self cell] setBackgroundColor:c]; }
- (NSColor *)textColor { return [[self cell] textColor]; }
- (void)setTextColor:(NSColor *)c { [[self cell] setTextColor:c]; }
- (NSCalendar *)calendar { return [[self cell] calendar]; }
- (void)setCalendar:(NSCalendar *)c { [[self cell] setCalendar:c]; }
- (NSLocale *)locale { return [[self cell] locale]; }
- (void)setLocale:(NSLocale *)l { [[self cell] setLocale:l]; }
- (NSTimeZone *)timeZone { return [[self cell] timeZone]; }
- (void)setTimeZone:(NSTimeZone *)z { [[self cell] setTimeZone:z]; }
- (NSDate *)dateValue { return [[self cell] dateValue]; }
- (void)setDateValue:(NSDate *)d { [[self cell] setDateValue:d]; }
- (NSTimeInterval)timeInterval { return [[self cell] timeInterval]; }
- (void)setTimeInterval:(NSTimeInterval)t { [[self cell] setTimeInterval:t]; }
- (NSDate *)minDate { return [[self cell] minDate]; }
- (void)setMinDate:(NSDate *)d { [[self cell] setMinDate:d]; }
- (NSDate *)maxDate { return [[self cell] maxDate]; }
- (void)setMaxDate:(NSDate *)d { [[self cell] setMaxDate:d]; }
- (id)delegate { return [[self cell] delegate]; }
- (void)setDelegate:(id)d { [[self cell] setDelegate:d]; }
- (BOOL)presentsCalendarOverlay { return _calendarOverlay; }
- (void)setPresentsCalendarOverlay:(BOOL)b
{
    _calendarOverlay = b; if (!b) [self _finchHideCalendar]; [self setNeedsDisplay:YES];
}
- (void)_finchHideCalendar
{
    [[_calendarPanel parentWindow] removeChildWindow:_calendarPanel]; [_calendarPanel orderOut:nil];
}
- (void)_finchOverlayResigned:(NSNotification *)note { [self _finchHideCalendar]; }
- (void)_finchOverlayChanged:(NSDatePicker *)picker
{
    if (picker->_calendarNavigation) return;
    [self _finchChooseDate:[picker dateValue] interval:[picker timeInterval]];
    [self _finchHideCalendar]; [[self window] makeFirstResponder:self];
}
- (void)_finchShowCalendar
{
    if (!_calendarPanel) {
        _calendarPanel = [[_FinchDateCalendarPanel alloc] initWithContentRect:NSMakeRect(0, 0, 202, 154)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        [_calendarPanel setReleasedWhenClosed:NO]; [_calendarPanel setHidesOnDeactivate:YES];
        [_calendarPanel setDatePicker:self];
        NSDatePicker *picker = [[[NSDatePicker alloc] initWithFrame:NSMakeRect(0, 0, 202, 154)] autorelease];
        [picker setDatePickerStyle:NSDatePickerStyleClockAndCalendar];
        [picker setDatePickerElements:NSDatePickerElementFlagYearMonthDay];
        [picker setTarget:self]; [picker setAction:@selector(_finchOverlayChanged:)];
        [_calendarPanel setContentView:picker];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_finchOverlayResigned:)
            name:NSWindowDidResignKeyNotification object:_calendarPanel];
    }
    NSDatePicker *picker = (id)[_calendarPanel contentView];
    [picker setCalendar:[self calendar]]; [picker setLocale:[self locale]]; [picker setTimeZone:[self timeZone]];
    [picker setMinDate:[self minDate]]; [picker setMaxDate:[self maxDate]];
    [picker setDatePickerMode:[self datePickerMode]]; [picker setDateValue:[self dateValue]];
    [picker setTimeInterval:[self timeInterval]];
    NSRect anchor = [[self window] convertRectToScreen:[self convertRect:[self bounds] toView:nil]];
    [_calendarPanel setFrameOrigin:NSMakePoint(anchor.origin.x, anchor.origin.y - 158)];
    [[self window] addChildWindow:_calendarPanel ordered:NSWindowAbove];
    [_calendarPanel makeKeyAndOrderFront:nil]; [_calendarPanel makeFirstResponder:picker];
}
- (void)drawRect:(NSRect)dirtyRect
{
    if (!_calendarOverlay || [self datePickerStyle] == NSDatePickerStyleClockAndCalendar) { [super drawRect:dirtyRect]; return; }
    NSRect r = [self bounds]; r.size.width = MAX(0, r.size.width - 20);
    [[self cell] drawWithFrame:r inView:self];
    NSRect button = NSMakeRect(NSMaxX(r), r.origin.y, 20, r.size.height);
    FinchDrawBezel(button, 3, FinchControlFill(NO), FinchControlStroke());
    [FinchDisabled([NSColor controlTextColor], [self isEnabled]) setStroke];
    NSRect icon = NSMakeRect(button.origin.x + 4, NSMidY(button) - 5, 12, 10);
    [[NSBezierPath bezierPathWithRect:icon] stroke];
    NSBezierPath *line = [NSBezierPath bezierPath];
    [line moveToPoint:NSMakePoint(icon.origin.x, icon.origin.y + 3)];
    [line lineToPoint:NSMakePoint(NSMaxX(icon), icon.origin.y + 3)]; [line stroke];
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return [self isEnabled] && ![self refusesFirstResponder]; }
- (NSArray *)_finchDateParts
{
    NSMutableArray *a = [NSMutableArray array]; NSDatePickerElementFlags e = [self datePickerElements];
    if (e & 0xc0) { [a addObject:@(NSCalendarUnitMonth)]; if (e & 0x20) [a addObject:@(NSCalendarUnitDay)]; [a addObject:@(NSCalendarUnitYear)]; }
    if (e & 0xc) { [a addObject:@(NSCalendarUnitHour)]; [a addObject:@(NSCalendarUnitMinute)]; if (e & 2) [a addObject:@(NSCalendarUnitSecond)]; }
    return a;
}
- (NSCalendarUnit)_finchSelectedUnit
{
    NSArray *parts = [self _finchDateParts]; return [parts count] ? [[parts objectAtIndex:MIN(MAX(0, _selectedPart), (NSInteger)[parts count] - 1)] unsignedIntegerValue] : NSCalendarUnitDay;
}
- (void)_finchChooseDate:(NSDate *)date interval:(NSTimeInterval)interval
{
    if (![self isEnabled] || !date) return;
    [[self cell] _finchSetUserDate:date interval:interval]; [self sendAction:[self action] to:[self target]]; [self setNeedsDisplay:YES];
}
- (void)_finchStep:(NSInteger)amount unit:(NSCalendarUnit)unit
{
    NSCalendar *calendar = [[self cell] _finchCalendar];
    NSDate *date = [calendar dateByAddingUnit:unit value:amount toDate:[self dateValue] options:0];
    [self _finchChooseDate:date interval:[self timeInterval]];
}
- (void)keyDown:(NSEvent *)event
{
    if (![self isEnabled]) return;
    NSString *characters = [event charactersIgnoringModifiers]; if (![characters length]) return;
    unichar key = [characters characterAtIndex:0];
    if (key == 27 && [[self window] isKindOfClass:[_FinchDateCalendarPanel class]]) {
        [[(_FinchDateCalendarPanel *)[self window] datePicker] _finchHideCalendar]; return;
    }
    if (_calendarOverlay && key == NSDownArrowFunctionKey && ([event modifierFlags] & NSEventModifierFlagOption)) {
        [self _finchShowCalendar]; return;
    }
    if (key == NSUpArrowFunctionKey || key == NSDownArrowFunctionKey) {
        [self _finchStep:key == NSUpArrowFunctionKey ? 1 : -1 unit:[self _finchSelectedUnit]];
        [_digits release]; _digits = nil;
    } else if (key == NSLeftArrowFunctionKey || key == NSRightArrowFunctionKey || key == '/' || key == ':') {
        NSInteger count = MAX(1, [[self _finchDateParts] count]);
        _selectedPart = (_selectedPart + count + (key == NSLeftArrowFunctionKey ? -1 : 1)) % count;
        [_digits release]; _digits = nil; [self setNeedsDisplay:YES];
    } else if (key >= '0' && key <= '9') {
        NSString *digits = [(_digits ?: @"") stringByAppendingString:characters];
        NSUInteger max = [self _finchSelectedUnit] == NSCalendarUnitYear ? 4 : 2;
        if ([digits length] > max) digits = characters;
        [digits retain]; [_digits release]; _digits = digits;
        NSCalendar *calendar = [[self cell] _finchCalendar];
        NSDateComponents *parts = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:[self dateValue]];
        [parts setValue:[digits integerValue] forComponent:[self _finchSelectedUnit]];
        NSDate *date = [calendar dateFromComponents:parts]; if (date) [self _finchChooseDate:date interval:[self timeInterval]];
    } else if (key == '\r' || key == ' ') [self sendAction:[self action] to:[self target]];
    else [super keyDown:event];
}
- (void)mouseDown:(NSEvent *)event
{
    if (![self isEnabled]) return;
    [[self window] makeFirstResponder:self]; [_digits release]; _digits = nil;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil]; NSRect r = [self bounds];
    if (_calendarOverlay && [self datePickerStyle] != NSDatePickerStyleClockAndCalendar) {
        if (p.x >= NSMaxX(r) - 20) { [self _finchShowCalendar]; return; }
        r.size.width = MAX(0, r.size.width - 20);
    }
    if ([self datePickerStyle] == NSDatePickerStyleClockAndCalendar && ([self datePickerElements] & 0xe)) {
        NSRect content = [[self cell] drawingRectForBounds:r];
        NSRect clock = NSMakeRect(NSMaxX(content) - 68, content.origin.y + 35, 64, 64);
        if (NSPointInRect(p, clock)) {
            CGFloat dx = p.x - NSMidX(clock), dy = p.y - NSMidY(clock);
            CGFloat angle = atan2(dy, dx) + M_PI_2; if (angle < 0) angle += 2 * M_PI;
            NSCalendar *calendar = [[self cell] _finchCalendar];
            NSDateComponents *parts = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:[self dateValue]];
            if (hypot(dx, dy) < 20) [parts setHour:((NSInteger)llround(angle * 6 / M_PI) % 12) + ([parts hour] >= 12 ? 12 : 0)];
            else [parts setMinute:(NSInteger)llround(angle * 30 / M_PI) % 60];
            [self _finchChooseDate:[calendar dateFromComponents:parts] interval:[self timeInterval]]; return;
        }
    }
    if ([self datePickerStyle] == NSDatePickerStyleClockAndCalendar && ([self datePickerElements] & 0xe0)) {
        NSRect content = [[self cell] drawingRectForBounds:r]; content.size.width = MIN(196, content.size.width);
        if (p.y < content.origin.y + 25) {
            _calendarNavigation = YES;
            if (p.x < content.origin.x + 22) [self _finchStep:-1 unit:NSCalendarUnitMonth];
            else if (p.x > NSMaxX(content) - 22) [self _finchStep:1 unit:NSCalendarUnitMonth];
            _calendarNavigation = NO;
        } else if (p.y >= content.origin.y + 44 && NSPointInRect(p, content)) {
            NSCalendar *calendar = [[self cell] _finchCalendar];
            NSDateComponents *parts = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:[self dateValue]];
            [parts setDay:1]; NSDate *first = [calendar dateFromComponents:parts];
            NSInteger offset = ([calendar component:NSCalendarUnitWeekday fromDate:first] + 7 - [calendar firstWeekday]) % 7;
            NSInteger day = (NSInteger)((p.y - content.origin.y - 44) / ((content.size.height - 44) / 6)) * 7 + (NSInteger)((p.x - content.origin.x) / (content.size.width / 7)) - offset + 1;
            if (day >= 1 && day <= [calendar rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:first].length) {
                [parts setDay:day]; NSDate *date = [calendar dateFromComponents:parts];
                if ([self datePickerMode] == NSDatePickerModeRange && ([event modifierFlags] & NSEventModifierFlagShift))
                    [self _finchChooseDate:[self dateValue] interval:[date timeIntervalSinceDate:[self dateValue]]];
                else [self _finchChooseDate:date interval:[self timeInterval]];
            }
        }
    } else if ([self datePickerStyle] == NSDatePickerStyleTextFieldAndStepper && p.x >= NSMaxX(r) - 18) {
        [self _finchStep:p.y < NSMidY(r) ? 1 : -1 unit:[self _finchSelectedUnit]];
    } else {
        NSInteger count = [[self _finchDateParts] count];
        _selectedPart = MIN(MAX(0, count - 1), MAX(0, (NSInteger)((p.x - r.origin.x) * count / MAX(1, r.size.width - 18))));
        [self setNeedsDisplay:YES];
    }
}
- (NSSize)intrinsicContentSize
{
    NSSize size = [[self cell] cellSize];
    if ([self datePickerStyle] != NSDatePickerStyleClockAndCalendar) {
        size.width = ceil(size.width); size.height -= [self datePickerStyle] == NSDatePickerStyleTextField ? 5 : 4;
    }
    return size;
}
- (BOOL)isAccessibilityElement { return NO; }
- (NSString *)accessibilityRole { return NSAccessibilityUnknownRole; }
- (NSString *)accessibilitySubrole { return nil; }
- (BOOL)accessibilityPerformIncrement { if (![self isEnabled]) return NO; [self _finchStep:1 unit:[self _finchSelectedUnit]]; return YES; }
- (BOOL)accessibilityPerformDecrement { if (![self isEnabled]) return NO; [self _finchStep:-1 unit:[self _finchSelectedUnit]]; return YES; }
+ (NSArray *)_finchBuiltinBindings { return [[super _finchBuiltinBindings] arrayByAddingObjectsFromArray:@[NSMinValueBinding, NSMaxValueBinding]]; }
- (void)_finchBindingChanged:(_FinchBinding *)b
{
    if ([b->_name isEqual:NSMinValueBinding]) [self setMinDate:[b rawValue]];
    else if ([b->_name isEqual:NSMaxValueBinding]) [self setMaxDate:[b rawValue]];
    else [super _finchBindingChanged:b];
}
@end
