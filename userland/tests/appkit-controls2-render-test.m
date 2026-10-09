/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch drawing and direct input check. Argument: output PNG path. */
#import <AppKit/AppKit.h>
#include <assert.h>
#include <stdio.h>

@interface ControlsCanvas : NSView
@end
@implementation ControlsCanvas
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect { [[NSColor whiteColor] setFill]; NSRectFill(rect); }
@end

@interface ControlsActions : NSObject
@property NSInteger calls;
@property BOOL clickedPathItem;
@end
@implementation ControlsActions
- (void)changed:(id)sender
{
    self.calls++;
    if ([sender isKindOfClass:[NSPathControl class]]) self.clickedPathItem = [(NSPathControl *)sender clickedPathItem] != nil;
}
@end

static void label(NSView *canvas, NSString *title, CGFloat x, CGFloat y)
{
    NSTextField *field = [NSTextField labelWithString:title];
    field.frame = NSMakeRect(x, y, 290, 20); field.font = [NSFont boldSystemFontOfSize:13];
    [canvas addSubview:field];
}

static NSEvent *key(unichar character)
{
    NSString *s = [NSString stringWithCharacters:&character length:1];
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                          timestamp:0 windowNumber:0 context:nil characters:s
        charactersIgnoringModifiers:s isARepeat:NO keyCode:0];
}

static void click(NSView *view, NSPoint point)
{
    NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                      location:[view convertPoint:point toView:nil]
                                 modifierFlags:0 timestamp:0 windowNumber:view.window.windowNumber
                                       context:nil eventNumber:0 clickCount:1 pressure:0];
    [view mouseDown:event];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        assert(argc == 2); [NSApplication sharedApplication];
        ControlsCanvas *canvas = [[ControlsCanvas alloc] initWithFrame:NSMakeRect(0, 0, 690, 540)];
        ControlsActions *actions = [ControlsActions new];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:canvas.frame styleMask:NSWindowStyleMaskTitled
                                                       backing:NSBackingStoreBuffered defer:NO];
        window.contentView = canvas;

        label(canvas, @"Search and completion", 20, 15);
        NSSearchField *search = [[NSSearchField alloc] initWithFrame:NSMakeRect(20, 42, 300, 26)];
        search.stringValue = @"Finch controls"; [canvas addSubview:search];
        NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSMakeRect(20, 82, 300, 26)];
        [combo addItemsWithObjectValues:@[@"First choice", @"Second choice", @"Third choice"]];
        [combo selectItemAtIndex:1]; [canvas addSubview:combo];

        label(canvas, @"Tokens", 20, 127);
        NSTokenField *tokens = [[NSTokenField alloc] initWithFrame:NSMakeRect(20, 153, 300, 29)];
        tokens.objectValue = @[@"Personal", @"Project", @"Shared"]; [canvas addSubview:tokens];
        [tokens selectText:nil]; NSTextView *editor = (NSTextView *)tokens.currentEditor;
        assert(editor); [editor selectAll:nil]; [editor insertText:@"One,Two,"];
        assert(([tokens.objectValue isEqual:@[@"One", @"Two"]]));
        [editor deleteBackward:nil]; assert([tokens.objectValue isEqual:@[@"One"]]);
        [window makeFirstResponder:nil];
        tokens.objectValue = @[@"Personal", @"Project", @"Shared"];

        label(canvas, @"Switch and split button", 20, 201);
        NSSwitch *toggle = [[NSSwitch alloc] initWithFrame:NSMakeRect(20, 230, 54, 24)];
        toggle.target = actions; toggle.action = @selector(changed:); [toggle performClick:nil];
        assert(toggle.state == NSControlStateValueOn && actions.calls == 1); [canvas addSubview:toggle];
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Save"];
        [menu addItemWithTitle:@"Save a copy" action:NULL keyEquivalent:@""];
        NSComboButton *button = [NSComboButton comboButtonWithTitle:@"Save" menu:menu target:actions action:@selector(changed:)];
        button.frame = NSMakeRect(125, 227, 140, 30); [canvas addSubview:button];
        [button performClick:nil]; assert(actions.calls == 2);

        label(canvas, @"Path", 20, 279);
        NSPathControl *path = [[NSPathControl alloc] initWithFrame:NSMakeRect(20, 307, 300, 25)];
        path.URL = [NSURL fileURLWithPath:@"/Users/example/Documents/report.txt"];
        path.target = actions; path.action = @selector(changed:); [canvas addSubview:path];
        [path performClick:nil]; assert(actions.calls == 3 && actions.clickedPathItem && !path.clickedPathItem);

        label(canvas, @"Date and calendar", 360, 15);
        NSDatePicker *date = [[NSDatePicker alloc] initWithFrame:NSMakeRect(360, 42, 270, 27)];
        date.datePickerElements = NSDatePickerElementFlagYearMonthDay;
        date.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
        date.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        date.dateValue = [NSDate dateWithTimeIntervalSince1970:1791504000];
        date.target = actions; date.action = @selector(changed:); [canvas addSubview:date];
        NSDate *before = date.dateValue; [date keyDown:key(NSUpArrowFunctionKey)];
        assert([date.dateValue compare:before] == NSOrderedDescending && actions.calls == 4);
        [date keyDown:key(NSDownArrowFunctionKey)]; assert([date.dateValue isEqualToDate:before]);
        date.presentsCalendarOverlay = YES;
        click(date, NSMakePoint(date.bounds.size.width - 5, 12)); assert(window.childWindows.count == 1);
        NSWindow *overlay = window.childWindows.lastObject; NSDatePicker *overlayPicker = (id)overlay.contentView;
        click(overlayPicker, NSMakePoint(10, 10)); assert(window.childWindows.count == 1);
        [overlayPicker keyDown:key(NSUpArrowFunctionKey)]; assert(window.childWindows.count == 0);
        date.dateValue = before;
        NSDatePicker *calendar = [[NSDatePicker alloc] initWithFrame:NSMakeRect(360, 84, 280, 150)];
        calendar.datePickerStyle = NSDatePickerStyleClockAndCalendar;
        calendar.datePickerElements = NSDatePickerElementFlagYearMonthDay | NSDatePickerElementFlagHourMinute;
        calendar.dateValue = date.dateValue; calendar.timeZone = date.timeZone; calendar.locale = date.locale; [canvas addSubview:calendar];
        click(calendar, NSMakePoint(263, 70));
        assert([[[NSCalendar currentCalendar] components:NSCalendarUnitMinute fromDate:calendar.dateValue] minute] == 15);

        label(canvas, @"Radio matrix", 360, 258);
        NSButtonCell *radio = [[NSButtonCell alloc] initTextCell:@"Choice"];
        [radio setButtonType:NSButtonTypeRadio];
        NSMatrix *matrix = [[NSMatrix alloc] initWithFrame:NSMakeRect(360, 286, 265, 85)
                                                    mode:NSRadioModeMatrix prototype:radio numberOfRows:3 numberOfColumns:1];
        matrix.cellSize = NSMakeSize(265, 25);
        NSInteger row = 0; for (NSCell *cell in matrix.cells) cell.title = [NSString stringWithFormat:@"Choice %ld", (long)++row];
        [matrix selectCellAtRow:1 column:0]; [canvas addSubview:matrix];

        label(canvas, @"Form", 20, 371);
        NSForm *form = [[NSForm alloc] initWithFrame:NSMakeRect(20, 399, 620, 100)];
        [form addEntry:@"Name:"].stringValue = @"Finch";
        [form addEntry:@"Folder:"].stringValue = @"Documents";
        [form addEntry:@"Notes:"].stringValue = @"Keyboard and mouse controls";
        form.cellSize = NSMakeSize(620, 28); [canvas addSubview:form];

        NSBitmapImageRep *rep = [canvas bitmapImageRepForCachingDisplayInRect:canvas.bounds]; assert(rep);
        [canvas cacheDisplayInRect:canvas.bounds toBitmapImageRep:rep];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        assert(png.length > 100 && [png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]);
        puts("controls2-render: PASS (token typing/deletion, actions, date keys/overlay/clock, drawing)");
    }
    return 0;
}
