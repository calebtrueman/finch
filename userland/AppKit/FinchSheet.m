/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Sheets (NSWindow's sheet API) without sheet animation, in Finch's own way
 * (docs/design/APPKIT.md): a sheet is a window-modal panel placed over its
 * parent, centred under the parent's title bar and kept above it as a child
 * window. While a window has a sheet, clicks and keys meant for it go to the
 * sheet instead (an event monitor), as with a real sheet; other windows
 * work as usual. The completion handler gets the code -endSheet:returnCode:
 * was given, after the sheet is ordered out.
 */
#import "FinchPanels.h"

static char sheets_key, parent_key;

@interface FinchSheetRecord : NSObject {
@public
    NSWindow *sheet;
    void (^handler)(NSModalResponse);
}
@end

@implementation FinchSheetRecord
- (void)dealloc
{
    [sheet release];
    [handler release];
    [super dealloc];
}
@end

static NSMutableArray *
sheet_records(NSWindow *w, BOOL create)
{
    NSMutableArray *a = objc_getAssociatedObject(w, &sheets_key);
    if (!a && create) {
        a = [NSMutableArray array];
        objc_setAssociatedObject(w, &sheets_key, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return a;
}

NSRect
FinchSheetFrame(NSWindow *sheet, NSWindow *parent)
{
    NSRect f = [sheet frame];
    NSRect content = [parent contentRectForFrameRect:[parent frame]];
    f.origin.x = floor(NSMidX([parent frame]) - f.size.width / 2);
    f.origin.y = NSMaxY(content) - f.size.height;
    return f;
}

/* Clicks and keys meant for a window with a sheet go to its sheet. */
static void
install_monitor(void)
{
    static BOOL done;
    if (done)
        return;
    done = YES;
    NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown |
                       NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged | NSEventMaskKeyDown | NSEventMaskKeyUp;
    [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                          handler:^NSEvent *(NSEvent *e) {
                                              NSWindow *w = [e window];
                                              if ([e type] == NSEventTypeKeyDown || [e type] == NSEventTypeKeyUp)
                                                  w = [NSApp keyWindow];
                                              NSWindow *sheet = [w attachedSheet];
                                              if (!sheet)
                                                  return e;
                                              while ([sheet attachedSheet])
                                                  sheet = [sheet attachedSheet];
                                              if ([e type] == NSEventTypeLeftMouseDown)
                                                  NSBeep();
                                              [sheet makeKeyAndOrderFront:nil];
                                              if ([e type] == NSEventTypeKeyDown || [e type] == NSEventTypeKeyUp) {
                                                  [sheet sendEvent:e];
                                              }
                                              return nil;
                                          }];
}

@implementation NSWindow (FinchSheets)

- (void)beginSheet:(NSWindow *)sheet completionHandler:(void (^)(NSModalResponse))handler
{
    if (!sheet || [sheet sheetParent])
        return;
    install_monitor();
    FinchSheetRecord *r = [[FinchSheetRecord alloc] init];
    r->sheet = [sheet retain];
    r->handler = [handler copy];
    [sheet_records(self, YES) addObject:r];
    [r release];
    objc_setAssociatedObject(sheet, &parent_key, self, OBJC_ASSOCIATION_ASSIGN);
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowWillBeginSheetNotification object:self];
    [sheet setFrame:FinchSheetFrame(sheet, self) display:NO];
    [self addChildWindow:sheet ordered:NSWindowAbove];
    [sheet makeKeyAndOrderFront:nil];
}

- (void)beginCriticalSheet:(NSWindow *)sheet completionHandler:(void (^)(NSModalResponse))handler
{
    [self beginSheet:sheet completionHandler:handler];
}

- (void)endSheet:(NSWindow *)sheet
{
    [self endSheet:sheet returnCode:NSModalResponseStop];
}

- (void)endSheet:(NSWindow *)sheet returnCode:(NSModalResponse)code
{
    NSMutableArray *a = sheet_records(self, NO);
    FinchSheetRecord *r = nil;
    for (FinchSheetRecord *x in a)
        if (x->sheet == sheet)
            r = x;
    if (!r)
        return;
    [r retain];
    [a removeObjectIdenticalTo:r];
    objc_setAssociatedObject(sheet, &parent_key, nil, OBJC_ASSOCIATION_ASSIGN);
    [self removeChildWindow:sheet];
    [sheet orderOut:nil];
    if ([self isVisible])
        [self makeKeyAndOrderFront:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidEndSheetNotification object:self];
    if (r->handler)
        r->handler(code);
    [r release];
}

- (NSWindow *)attachedSheet
{
    FinchSheetRecord *r = [sheet_records(self, NO) firstObject];
    return r ? r->sheet : nil;
}

- (NSArray<NSWindow *> *)sheets
{
    NSMutableArray *out = [NSMutableArray array];
    for (FinchSheetRecord *r in sheet_records(self, NO))
        [out addObject:r->sheet];
    return out;
}

- (NSWindow *)sheetParent
{
    return objc_getAssociatedObject(self, &parent_key);
}

@end
