/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * What Finch's table classes share (NSTableView.m, NSTableColumn.m,
 * NSTableHeaderView.m, NSTableRowView.m, NSOutlineView.m): the table's
 * geometry and hooks, the header's place in a scroll view, and the look.
 */
#ifndef NSTABLEVIEW_FINCH_H
#define NSTABLEVIEW_FINCH_H

#import "NSControl_Finch.h"

/* NSTvFlags, as ibtool writes them (worked out from its output). */
enum {
    TV_COLUMN_RESIZING = 0x80000000u,
    TV_COLUMN_REORDERING = 0x40000000u,
    TV_EMPTY_SELECTION = 0x10000000u,
    TV_MULTIPLE_SELECTION = 0x08000000u,
    TV_COLUMN_SELECTION = 0x04000000u,
    TV_AUTOSAVE_COLUMNS = 0x01000000u,
    TV_ALTERNATING_ROWS = 0x00800000u,
};

@interface NSTableView (FinchTable)
/* A column's width, visibility or title changed. */
- (void)_finchColumnChanged:(NSTableColumn *)column oldWidth:(CGFloat)oldWidth;
- (void)_finchColumnVisibilityChanged:(NSTableColumn *)column;
/* The style the geometry follows (automatic resolved). */
- (NSTableViewStyle)_finchStyle;
/* Header clicks and drags (NSTableHeaderView.m). */
- (void)_finchHeaderClickedColumn:(NSInteger)column event:(NSEvent *)event;
- (void)_finchResizeColumn:(NSInteger)column toWidth:(CGFloat)width;
/* The view-based machinery: the row view for a row, if made. */
- (NSTableRowView *)_finchRowViewIfAny:(NSInteger)row;
/* Content from bindings: the row's object, or nil. */
- (id)_finchContentObjectAtRow:(NSInteger)row;
/* Drawing a cell-based row's cells (NSOutlineView adds the disclosure triangles). */
- (void)_finchDrawRow:(NSInteger)row clipRect:(NSRect)clip;
/* The number of rows from the data source or the content binding. */
- (NSInteger)_finchCountRows;
/* Expose the cell frame before the outline view's indentation. */
- (NSRect)_finchPlainFrameOfCellAtColumn:(NSInteger)column row:(NSInteger)row;
- (void)_finchRowsChanged;
@end

@interface NSTableColumn (FinchTable)
- (void)_finchSetTableView:(NSTableView *)table;
/* Set the width without telling anyone (column autoresizing tells once). */
- (void)_finchSetWidthQuietly:(CGFloat)width;
@end

@interface NSTableHeaderView (FinchTable)
/* The column being pressed (drawn highlighted), or -1. */
- (void)_finchSetPressedColumn:(NSInteger)column;
@end

@interface NSTableRowView (FinchTable)
- (void)_finchSetTableView:(NSTableView *)table row:(NSInteger)row;
- (void)_finchSetCellViews:(NSArray *)views;
- (NSArray *)_finchCellViews;
- (NSInteger)_finchRow;
- (void)_finchSetRow:(NSInteger)row;
@end

/* NSScrollView's hooks for a document view with a header (NSTableHeaderView.m): put the header in its
   clip view above the content, and keep it scrolled with the content horizontally. */
FINCH_PRIVATE void FinchScrollViewTileHeader(NSScrollView *scrollView, NSRect inner, NSEdgeInsets rulers, BOOL setInsets);
FINCH_PRIVATE void FinchScrollViewReflectHeader(NSScrollView *scrollView);

/* The visible rect as Apple's tables and collection views see it (NSView's, through clip views). */
FINCH_PRIVATE NSRect FinchClippedVisibleRect(NSView *view);

/* The look: the selection colour (emphasized or not), the header and grid colours. */
FINCH_PRIVATE NSColor *FinchTableSelectionColor(BOOL emphasized);
FINCH_PRIVATE void FinchTableDrawDisclosure(NSRect frame, BOOL expanded, BOOL flipped, NSColor *color);

#endif
