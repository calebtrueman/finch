/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch-only: draw the containers and send clicks and keys through their real
 * controls/event queue. Argument: an existing output folder. */
#import <AppKit/AppKit.h>
#include <assert.h>
#include <stdio.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);

@interface ContainerCanvas : NSView
@end
@implementation ContainerCanvas
- (void)drawRect:(NSRect)dirty
{
    [[NSColor whiteColor] setFill];
    NSRectFill(self.bounds);
}
@end

static void saveView(NSView *view, NSString *path)
{
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    assert(rep);
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    assert(png.length > 100 && [png writeToFile:path atomically:YES]);
}
static void mouseEvent(NSWindow *window)
{
    NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                    location:NSMakePoint(10, 10)
                               modifierFlags:0
                                   timestamp:1
                                windowNumber:window.windowNumber
                                     context:nil
                                 eventNumber:1
                                  clickCount:1
                                    pressure:0];
    [NSApp postEvent:e atStart:YES];
    [NSApp nextEventMatchingMask:NSEventMaskLeftMouseDown
                       untilDate:[NSDate date]
                          inMode:NSDefaultRunLoopMode
                         dequeue:YES];
}
int main(int argc, char **argv)
{
    @autoreleasepool {
        assert(argc >= 2);
        const char *server = argc > 2 ? argv[2] : "/usr/libexec/finch-windowserver";
        char socketPath[64];
        snprintf(socketPath, sizeof socketPath, "/tmp/finch-containers2.%d", getpid());
        setenv(FWS_SOCKET_ENV, socketPath, 1);
        pid_t serverPID;
        char *args[] = {(char *)server, "--headless", "--size", "1000x800", "--scale", "2", NULL};
        assert(posix_spawn(&serverPID, server, NULL, NULL, args, environ) == 0);
        for (int i = 0; i < 100 && !FWSConnect(); i++)
            usleep(20000);
        assert(FWSConnect());
        [NSApplication sharedApplication];
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        NSGridView *grid = [NSGridView gridViewWithViews:@[
            @[ [NSTextField labelWithString:@"Project"], [NSTextField textFieldWithString:@"Finch containers"] ],
            @[
                [NSTextField labelWithString:@"Status"], [NSButton checkboxWithTitle:@"Ready to review"
                                                                              target:nil
                                                                              action:NULL]
            ],
            @[ [NSTextField labelWithString:@"These rows share the same column widths."] ]
        ]];
        [grid mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(2, 1)];
        grid.rowSpacing = 12;
        [grid columnAtIndex:0].leadingPadding = 16;
        [grid columnAtIndex:1].trailingPadding = 16;
        [grid rowAtIndex:0].topPadding = 16;
        [grid rowAtIndex:2].bottomPadding = 16;
        grid.frame = NSMakeRect(0, 0, 420, 140);
        ContainerCanvas *canvas = [[[ContainerCanvas alloc] initWithFrame:grid.frame] autorelease];
        [canvas addSubview:grid];
        [canvas layoutSubtreeIfNeeded];
        saveView(canvas, [folder stringByAppendingPathComponent:@"grid.png"]);

        NSPredicateEditorRowTemplate *name = [[[NSPredicateEditorRowTemplate alloc]
                 initWithLeftExpressions:@[ [NSExpression expressionForKeyPath:@"name"] ]
            rightExpressionAttributeType:NSStringAttributeType
                                modifier:NSDirectPredicateModifier
                               operators:@[ @(NSEqualToPredicateOperatorType), @(NSContainsPredicateOperatorType) ]
                                 options:0] autorelease];
        NSPredicateEditor *editor = [[[NSPredicateEditor alloc] initWithFrame:NSMakeRect(0, 0, 600, 150)] autorelease];
        editor.rowTemplates = [editor.rowTemplates arrayByAddingObject:name];
        editor.objectValue = [NSPredicate predicateWithFormat:@"name CONTAINS 'Finch' AND name == 'AppKit'"];
        assert(editor.numberOfRows == 3);
        NSButton *add = nil;
        for (NSView *view in editor.subviews)
            if ([view isKindOfClass:[NSButton class]] && [(NSButton *)view tag] == 1 &&
                [[(NSButton *)view title] isEqual:@"+"])
                add = (NSButton *)view;
        assert(add);
        [add performClick:nil];
        assert(editor.numberOfRows == 4 && editor.predicate != nil);
        saveView(editor, [folder stringByAppendingPathComponent:@"predicate-editor.png"]);

        NSWindow *parent = [[[NSWindow alloc] initWithContentRect:NSMakeRect(250, 250, 420, 240)
                                                        styleMask:NSWindowStyleMaskTitled
                                                          backing:NSBackingStoreBuffered
                                                            defer:YES] autorelease];
        parent.releasedWhenClosed = NO;
        NSView *anchor = [[[NSView alloc] initWithFrame:NSMakeRect(140, 120, 100, 30)] autorelease];
        [parent.contentView addSubview:anchor];
        [parent orderFront:nil];
        NSViewController *controller = [[[NSViewController alloc] init] autorelease];
        controller.view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 220, 90)] autorelease];
        NSTextField *label = [NSTextField labelWithString:@"A Finch popover"];
        label.frame = NSMakeRect(16, 42, 180, 24);
        [controller.view addSubview:label];
        NSPopover *popover = [[[NSPopover alloc] init] autorelease];
        popover.animates = NO;
        popover.contentViewController = controller;
        popover.behavior = NSPopoverBehaviorApplicationDefined;
        [popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSMaxYEdge];
        assert(popover.shown && controller.view.window.parentWindow == parent);
        saveView(controller.view.superview, [folder stringByAppendingPathComponent:@"popover.png"]);
        mouseEvent(parent);
        assert(popover.shown);
        popover.behavior = NSPopoverBehaviorTransient;
        mouseEvent(parent);
        assert(!popover.shown);
        /* semitransient: a click in another window leaves it, one in the anchor's window closes it */
        popover.behavior = NSPopoverBehaviorSemitransient;
        [popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSMinYEdge];
        NSWindow *other = [[[NSWindow alloc] initWithContentRect:NSMakeRect(20, 20, 80, 80)
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered
                                                           defer:YES] autorelease];
        other.releasedWhenClosed = NO;
        [other orderFront:nil];
        mouseEvent(other);
        assert(popover.shown);
        mouseEvent(parent);
        assert(!popover.shown);
        popover.behavior = NSPopoverBehaviorTransient;
        [popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSMinYEdge];
        NSEvent *escape = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                           location:NSZeroPoint
                                      modifierFlags:0
                                          timestamp:2
                                       windowNumber:controller.view.window.windowNumber
                                            context:nil
                                         characters:@"\033"
                        charactersIgnoringModifiers:@"\033"
                                          isARepeat:NO
                                            keyCode:53];
        [NSApp postEvent:escape atStart:YES];
        [NSApp nextEventMatchingMask:NSEventMaskKeyDown
                           untilDate:[NSDate date]
                              inMode:NSDefaultRunLoopMode
                             dequeue:YES];
        assert(!popover.shown);
        [parent close];
        [other close];
        kill(serverPID, SIGTERM);
        waitpid(serverPID, NULL, 0);
        unlink(socketPath);
        puts("containers2-render: PASS (three PNGs, row button, popover mouse and Escape)");
    }
    return 0;
}
