/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What Finch's alerts, open and save panels and NSWorkspace share
 * (NSAlert.m, NSSavePanel.m, NSWorkspace.m, FinchSheet.m): the generic
 * icons, drawn in code in Finch's own look, and sheets.
 */
#ifndef FINCH_PANELS_H
#define FINCH_PANELS_H

#import "AppKit_Finch.h"

typedef NS_ENUM(NSInteger, FinchIconKind) {
    FinchIconApplication,  /* an app with no icon of its own */
    FinchIconFolder,
    FinchIconDocument,
    FinchIconVolume,
    FinchIconCaution,      /* NSAlertStyleCritical's badge */
};

/* A new image of the generic icon, `size` points square. */
FINCH_PRIVATE NSImage *FinchIconImage(FinchIconKind kind, CGFloat size);

/* The app's icon: NSApp's, the bundle's, or Finch's generic one. */
FINCH_PRIVATE NSImage *FinchApplicationIcon(void);

/*
 * Finch has no sheet animation: a sheet is a window-modal panel placed over
 * its parent, centred under the parent's title bar, kept above it as a child
 * window; clicks and keys meant for the parent go to the sheet (FinchSheet.m).
 */
FINCH_PRIVATE NSRect FinchSheetFrame(NSWindow *sheet, NSWindow *parent);

/* UniformTypeIdentifiers, loaded when first needed (AppKit doesn't link it). */
FINCH_PRIVATE Class FinchUTTypeClass(void);

#endif
