/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-textfinder-test: NSTextFinder through NSTextView: the find bar in its
 * scroll view, the find pasteboard, next and previous (wrapping), validation.
 * Run it against Apple's AppKit and Finch's (DYLD_FRAMEWORK_PATH) and diff all
 * but the first line.
 */
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <stdio.h>
int
main(void)
{
    @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info dl;
    dladdr((__bridge void *)[NSTextFinder class], &dl);
    printf("%s\n", dl.dli_fname);
 [NSApplication sharedApplication];
 NSTextFinder *f=[NSTextFinder new]; printf("client %p container %p incremental %d dim %d ranges %s\n", f.client, f.findBarContainer, f.isIncrementalSearchingEnabled, f.incrementalSearchingShouldDimContentView, [[f.incrementalMatchRanges description] UTF8String]);
 NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 NSScrollView *sv=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,400,300)]; NSTextView *tv=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,400,300)]; sv.documentView=tv; w.contentView=sv;
 [tv setString:@"one two one three one"];
 printf("usesFindBar %d usesFindPanel %d incremental %d sv findBarPosition %ld visible %d findBarView %p\n", tv.usesFindBar, tv.usesFindPanel, tv.isIncrementalSearchingEnabled, (long)sv.findBarPosition, sv.isFindBarVisible, sv.findBarView);
 tv.usesFindBar=YES;
 NSMenuItem *mi=[[NSMenuItem alloc] initWithTitle:@"Find" action:@selector(performTextFinderAction:) keyEquivalent:@""]; mi.tag=NSTextFinderActionShowFindInterface;
 printf("validate show %d\n", [tv validateMenuItem:mi]);
 [tv performTextFinderAction:mi]; printf("after show: visible %d findBarView %s frame %s\n", sv.isFindBarVisible, NSStringFromClass([sv.findBarView class]).UTF8String, NSStringFromRect(sv.findBarView.frame).UTF8String);
 [tv setSelectedRange:NSMakeRange(0,3)]; mi.tag=NSTextFinderActionSetSearchString; [tv performTextFinderAction:mi];
 printf("find pboard: %s\n", [[[NSPasteboard pasteboardWithName:NSPasteboardNameFind] stringForType:NSPasteboardTypeString] UTF8String]);
 mi.tag=NSTextFinderActionNextMatch; [tv performTextFinderAction:mi]; printf("next sel %s\n", NSStringFromRange(tv.selectedRange).UTF8String);
 [tv performTextFinderAction:mi]; printf("next sel %s\n", NSStringFromRange(tv.selectedRange).UTF8String);
 [tv performTextFinderAction:mi]; printf("next (wrap) sel %s\n", NSStringFromRange(tv.selectedRange).UTF8String);
 mi.tag=NSTextFinderActionPreviousMatch; [tv performTextFinderAction:mi]; printf("prev sel %s\n", NSStringFromRange(tv.selectedRange).UTF8String);
 mi.tag=NSTextFinderActionHideFindInterface; [tv performTextFinderAction:mi]; printf("hidden visible %d\n", sv.isFindBarVisible);
 for (int t=1;t<=13;t++){ mi.tag=t; printf("validate %d: %d\n", t, [tv validateMenuItem:mi]); }
    }
    return 0;
}
