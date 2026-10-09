/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * TextKit 2 internals shared between UIFoundation's files (NSTextRange.m,
 * NSTextContentManager.m, NSTextLayoutManager.m, NSTextSelection.m) and the
 * TextKit 1 classes they meet (NSTextContainer, NSLayoutManager).
 *
 * NSTextLayoutManager lays text out with an NSLayoutManager of its own (its
 * "layout engine"), which holds the text storage without being one of its
 * layout managers and the container without being the container's layout
 * manager, so TextKit 1 and TextKit 2 lay text out identically (as Apple's
 * do for plain paragraphs). Layout fragments are its lines, grouped by the
 * content manager's paragraphs.
 */
#ifndef UIF_TEXTKIT2_H
#define UIF_TEXTKIT2_H

#import "UIFTextLayout.h"

/* Apple's location class for NSTextContentStorage: an offset into the text. */
@interface NSCountableTextLocation : NSObject <NSTextLocation, NSCopying, NSSecureCoding>
- (instancetype)initWithIndex:(NSInteger)index;
@property (readonly) NSInteger index;
@end

/* An autoreleased countable location, and a range of them. */
UIF_HIDDEN NSCountableTextLocation *UIFLocation(NSInteger index);
UIF_HIDDEN NSTextRange *UIFRange(NSInteger start, NSInteger end);
/* A countable location's offset, or NSNotFound. */
UIF_HIDDEN NSInteger UIFLocationIndex(id<NSTextLocation> location);

/* Offsets through a content manager (any NSTextElementProvider), from its
 * document's start; NSNotFound when it can't say. */
UIF_HIDDEN NSInteger UIFOffsetOf(NSTextContentManager *tcm, id<NSTextLocation> location);
UIF_HIDDEN id<NSTextLocation> UIFLocationAt(NSTextContentManager *tcm, NSInteger offset);

@interface NSTextContainer (UIFTextKit2)
- (void)_uifSetTextLayoutManager:(NSTextLayoutManager *)textLayoutManager;
@end

@interface NSLayoutManager (UIFTextKit2)
- (void)_uifBecomeEngineWithTextContainer:(NSTextContainer *)container;
- (void)_uifSetTextStorage:(NSTextStorage *)textStorage;
- (void)invalidate;
@end

/* The layout engine's lines for its container (laid out if needed), with
 * the container's line fragment padding and width; NULL without one. */
UIF_HIDDEN UIFLayout *UIFLayoutManagerLayout(NSLayoutManager *lm, NSTextContainer *container, CGFloat *padding,
                                             CGFloat *width);
/* Changes whenever the layout manager's layout is discarded. */
UIF_HIDDEN NSUInteger UIFLayoutManagerGeneration(NSLayoutManager *lm);
/* The x of a character index's caret within a line, from the line's text start. */
UIF_HIDDEN CGFloat UIFLineOffset(UIFLine *ln, NSUInteger index);

@interface NSTextContentManager (UIFTextKit2)
/* The text the layout managers lay out (an NSTextContentStorage's text storage). */
- (NSTextStorage *)_uifTextStorage;
@end

@interface NSTextLayoutManager (UIFTextKit2)
- (void)_uifSetTextContentManager:(NSTextContentManager *)textContentManager;
/* The content manager's text changed (a text storage edit, or a new storage). */
- (void)_uifProcessEditing:(NSTextStorageEditActions)mask range:(NSRange)range changeInLength:(NSInteger)delta;
- (void)_uifTextStorageReplaced;
/* The container's geometry changed. */
- (void)_uifTextContainerChanged;
/* The layout engine (an NSLayoutManager): AppKit's NSTextView asks it TextKit 1's
 * geometry questions, so both text systems answer alike. */
- (NSLayoutManager *)_uifLayoutEngine;
- (NSLayoutManager *)_uifEngineIfAny;
/* The text, for selection navigation. */
- (NSString *)_uifString;
@end

#endif
