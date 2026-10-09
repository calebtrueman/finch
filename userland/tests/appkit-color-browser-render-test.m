/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch-only drawing and direct event check. Argument: existing output folder. */
#import <AppKit/AppKit.h>
#include <assert.h>
#include <stdio.h>
#include "appkit-color-browser-test.inc"
static void saveView(NSView *view, NSString *path)
{
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    assert(rep);
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    assert(png.length > 100 && [png writeToFile:path atomically:YES]);
}
int main(int argc, char **argv)
{
    @autoreleasepool {
        assert(argc == 2);
        [NSApplication sharedApplication];
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        NSBrowser *browser = [[NSBrowser alloc] initWithFrame:NSMakeRect(0, 0, 400, 220)];
        FinchBrowserItems *items = [FinchBrowserItems new];
        browser.delegate = items;
        [browser loadColumnZero];
        NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                            location:NSMakePoint(40, 185)
                                       modifierFlags:0
                                           timestamp:1
                                        windowNumber:0
                                             context:nil
                                         eventNumber:1
                                          clickCount:1
                                            pressure:0];
        [[browser hitTest:NSMakePoint(40, 185)] mouseDown:event];
        assert(browser.lastColumn == 1 && browser.selectedColumn == 0);
        event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                   location:NSMakePoint(180, 161)
                              modifierFlags:0
                                  timestamp:2
                               windowNumber:0
                                    context:nil
                                eventNumber:2
                                 clickCount:1
                                   pressure:0];
        [[browser hitTest:NSMakePoint(180, 161)] mouseDown:event];
        assert([browser.path isEqual:@"/Folder/B"]);
        saveView(browser, [folder stringByAppendingPathComponent:@"browser.png"]);
        NSColorPanel *panel = [NSColorPanel sharedColorPanel];
        panel.mode = NSColorPanelModeWheel;
        panel.color = [NSColor colorWithSRGBRed:0.3 green:0.6 blue:0.9 alpha:0.7];
        saveView(panel.contentView, [folder stringByAppendingPathComponent:@"color-wheel.png"]);
        panel.mode = NSColorPanelModeColorList;
        saveView(panel.contentView, [folder stringByAppendingPathComponent:@"color-palette.png"]);
        panel.mode = NSColorPanelModeRGB;
        saveView(panel.contentView, [folder stringByAppendingPathComponent:@"color-rgb.png"]);
        [browser release];
        [items release];
        puts("color-browser-render: PASS (mouse path and four PNGs)");
    }
    return 0;
}
