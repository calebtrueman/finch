/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What Finch's menu classes share (NSMenu.m, NSMenuItem.m, FinchMenuWindow.m,
 * NSPopUpButtonCell.m): the menus' private state, and the menu bar and the
 * pop-up menu windows, which Finch draws itself.
 */
#ifndef NSMENU_FINCH_H
#define NSMENU_FINCH_H

#import "NSView_Finch.h"

@interface NSMenu (Finch)
/* The name a nib gives the menu ("_NSMainMenu", "_NSWindowsMenu", ...). */
- (NSString *)_finchName;
- (void)_finchSetName:(NSString *)name;
/* The item whose submenu this is (not retained). */
- (NSMenuItem *)_finchParentItem;
- (void)_finchSetParentItem:(NSMenuItem *)item;
- (void)_finchSetHighlightedItem:(NSMenuItem *)item;
/* Before the menu opens: the delegate fills it in (menuNeedsUpdate:, numberOfItemsInMenu:...), then -update. */
- (void)_finchPrepareToOpen;
/* Sends the item's action with the will/did-send notifications; NO if the item is disabled. */
- (BOOL)_finchSendActionForItem:(NSMenuItem *)item;
@end

@interface NSMenuItem (Finch)
/* Enabled, ignoring the ancestors (isEnabled answers NO under a disabled parent item, as Apple's). */
- (BOOL)_finchOwnEnabled;
/* Set while tracking; no notification. */
- (void)_finchSetHighlighted:(BOOL)flag;
/* -setEnabled: as validation sets it (posts NSMenuDidChangeItemNotification when it changes). */
- (void)_finchSetEnabled:(BOOL)flag;
/* The default state images (Finch's own drawings, named as Apple's: NSMenuCheckmark, NSMenuMixedState). */
+ (NSImage *)_finchCheckmarkImage;
+ (NSImage *)_finchMixedStateImage;
@end

@interface NSPopUpButtonCell (Finch)
- (NSInteger)selectedTag;  /* the selected item's tag, -1 without one */
@end

/* The key equivalent as the menu shows it: the modifier glyphs (⌃⌥⇧⌘) and the key. */
FINCH_PRIVATE NSString *FinchMenuKeyEquivalentString(NSMenuItem *item);

/* The size a menu draws at (FinchMenuWindow.m). */
FINCH_PRIVATE NSSize FinchMenuSize(NSMenu *menu);
/* Ends the menu tracking going on, if any (FinchMenuWindow.m). */
FINCH_PRIVATE void FinchMenuCancelTracking(BOOL animate);

/* The menu bar (FinchMenuWindow.m): shows NSApp's main menu once the app has launched, and redraws it. */
FINCH_PRIVATE void FinchMenuBarUpdate(void);
/* Called by -[NSApplication finishLaunching]: from now on the menu bar shows. */
FINCH_PRIVATE void FinchMenuBarDidLaunch(void);

/*
 * Pops up a menu (FinchMenuWindow.m) with its top left at a screen point
 * (AppKit coordinates), or with an item's top left there, and tracks it
 * until the user chooses or cancels. Returns the chosen item (its action
 * has been sent unless sendAction is NO), or nil.
 */
FINCH_PRIVATE NSMenuItem *FinchMenuPopUp(NSMenu *menu, NSMenuItem *positioningItem, NSPoint screenPoint,
                                         NSView *view, NSEvent *event, CGFloat minimumWidth, NSFont *font,
                                         BOOL sendAction);

#endif
