/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What Finch's controls and cells share (NSCell.m, NSControl.m, NSButtonCell.m,
 * NSTextFieldCell.m, NSSliderCell.m, ...): the archive flags Interface
 * Builder writes, the cells' private hooks, and Finch's own control look.
 *
 * Archive flags, worked out from ibtool's output (see NSCell.m):
 *   NSCellFlags:  0x80000000 state on, 0x40000000 highlighted, 0x20000000
 *                 disabled, 0x10000000 editable, 0x0c000000 type, 0x00800000
 *                 bordered, 0x00400000 bezeled, 0x00200000 selectable,
 *                 0x00100000 scrollable, 0x00080000 continuous
 *   NSCellFlags2: 0x40000000 allows editing text attributes, 0x20000000 imports
 *                 graphics, 0x1c000000 alignment (archive values: left, right,
 *                 center, justified, natural), 0x02000000 refuses first
 *                 responder, 0x01000000 allows mixed state, 0x00800000 mixed
 *                 (with the state bit), 0x00400000 sends action on end editing,
 *                 0x000e0000 control size, 0x00018000 focus ring type,
 *                 0x00006000 writing direction + 1, 0x00001000 no undo,
 *                 0x00000e00 line break mode, 0x00000100 truncates last
 *                 visible line, 0x00000040 single line mode
 */
#ifndef NSCONTROL_FINCH_H
#define NSCONTROL_FINCH_H

#import "NSView_Finch.h"

enum {
    CF1_STATE = 0x80000000u,
    CF1_HIGHLIGHTED = 0x40000000u,
    CF1_DISABLED = 0x20000000u,
    CF1_EDITABLE = 0x10000000u,
    CF1_TYPE_SHIFT = 26,
    CF1_BORDERED = 0x00800000u,
    CF1_BEZELED = 0x00400000u,
    CF1_SELECTABLE = 0x00200000u,
    CF1_SCROLLABLE = 0x00100000u,
    CF1_CONTINUOUS = 0x00080000u,

    CF2_EDITS_ATTRIBUTES = 0x40000000u,
    CF2_IMPORTS_GRAPHICS = 0x20000000u,
    CF2_ALIGNMENT_SHIFT = 26,
    CF2_REFUSES_FIRST_RESPONDER = 0x02000000u,
    CF2_ALLOWS_MIXED = 0x01000000u,
    CF2_MIXED = 0x00800000u,
    CF2_ACTION_ON_END_EDITING = 0x00400000u,
    CF2_CONTROL_SIZE_SHIFT = 17,
    CF2_FOCUS_RING_SHIFT = 15,
    CF2_WRITING_DIRECTION_SHIFT = 13,
    CF2_NO_UNDO = 0x00001000u,
    CF2_LINE_BREAK_SHIFT = 9,
    CF2_TRUNCATES_LAST_LINE = 0x00000100u,
    CF2_SINGLE_LINE = 0x00000040u,
};

/* NSTextAlignment from and to the archive's values. */
FINCH_PRIVATE NSTextAlignment FinchAlignmentFromArchive(unsigned v);
FINCH_PRIVATE unsigned FinchAlignmentToArchive(NSTextAlignment a);

@interface NSCell (FinchControls)
/* The cell's mask from -sendActionOn: (without changing it). */
- (NSEventMask)_finchActionMask;
/* The field editor is editing the cell: its text isn't drawn. */
- (BOOL)_finchIsEditing;
/* Redraw the control showing the cell. */
- (void)_finchChanged;
/* Whether a click (performClick:, a tracked mouse up) advances the state. */
- (BOOL)_finchClickChangesState;
/* The attributes the cell draws its text with (font, colour, paragraph style). */
- (NSDictionary *)_finchTextAttributes;
/* The control view's enabled appearance: the cell's, and the window's key state. */
- (BOOL)_finchDrawsEnabled;
/* Send the cell's action from its control (or from the cell, without one). */
- (BOOL)_finchSendAction;
@end

@interface NSControl (FinchControls)
/* The cell, decoded from a nib, wants the control's archived action mask etc. */
- (void)_finchTextDidEndEditing:(NSNotification *)note;
@end

/* Finch's control look: flat, rounded, the accent colour for "on". */
FINCH_PRIVATE NSColor *FinchAccentColor(void);
FINCH_PRIVATE NSColor *FinchControlFill(BOOL pressed);
FINCH_PRIVATE NSColor *FinchControlStroke(void);
FINCH_PRIVATE NSColor *FinchOnAccentColor(void);
FINCH_PRIVATE NSColor *FinchControlTextColor(void);
FINCH_PRIVATE NSColor *FinchControlGlyphColor(void);
FINCH_PRIVATE NSColor *FinchKnobColor(void);
FINCH_PRIVATE NSColor *FinchDisabled(NSColor *color, BOOL enabled);
/* A rounded control body with a hairline border, inset by half a point so the line lands on pixels. */
FINCH_PRIVATE void FinchDrawBezel(NSRect rect, CGFloat radius, NSColor *fill, NSColor *stroke);
/* The checkbox and radio button glyphs (16 by 16 in a flipped or unflipped rect). */
FINCH_PRIVATE void FinchDrawCheckbox(NSRect box, NSControlStateValue state, BOOL pressed, BOOL enabled);
FINCH_PRIVATE void FinchDrawRadio(NSRect box, NSControlStateValue state, BOOL pressed, BOOL enabled);
/* Text centred vertically in a rect, as a cell draws its title. */
FINCH_PRIVATE void FinchDrawCellText(NSAttributedString *text, NSRect rect, BOOL flipped);
/* The size of text as a cell draws it (one line when it doesn't wrap). */
FINCH_PRIVATE NSSize FinchCellTextSize(NSAttributedString *text, CGFloat width);
/* Draw an image into rect (scaled, aligned), respecting the view's flippedness. */
FINCH_PRIVATE void FinchDrawImageInRect(NSImage *image, NSRect rect, NSImageScaling scaling, NSImageAlignment align,
                                        BOOL flipped, CGFloat alpha);

#endif
