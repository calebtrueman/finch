/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Storyboards' hooks in the controllers, nibs and NSApplicationMain (NSStoryboard.m). */
#ifndef NSSTORYBOARD_FINCH_H
#define NSSTORYBOARD_FINCH_H

#import "AppKit_Finch.h"

@interface NSStoryboard (Finch)
- (NSString *)_finchPath;
- (void)_finchLoadMainMenu;
@end

/* The storyboard keys of a controller's archive (segue templates, its view nib's external objects, a window template). */
FINCH_PRIVATE void FinchStoryboardDecodeController(id controller, NSCoder *coder);
/* -loadView for a storyboard's view controller; NO if it isn't one. */
FINCH_PRIVATE BOOL FinchStoryboardLoadView(NSViewController *controller);
/* NSApplicationMain's launch from NSMainStoryboardFile. */
FINCH_PRIVATE void FinchStoryboardLaunch(NSApplication *app, NSBundle *bundle);

#endif
