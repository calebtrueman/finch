/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Text layout (UIFTextLayout.m), shared by string drawing and the text system.
 */
#ifndef UIF_TEXT_LAYOUT_H
#define UIF_TEXT_LAYOUT_H

#import "UIFoundationInternal.h"

/* A line fragment. Positions are from the container's top-left, in points. */
typedef struct {
    CTLineRef line;       /* retained; NULL for an empty line */
    NSRange range;        /* its characters, with the paragraph break that ends it */
    CGFloat x;            /* where its text starts (indents, alignment) */
    CGFloat top;          /* the fragment's top */
    CGFloat height;       /* the fragment's height, without lineSpacing */
    CGFloat baseline;     /* from the fragment's top */
    CGFloat width;        /* used width */
    CGFloat spacingAfter; /* lineSpacing (and paragraph spacing) below it */
    BOOL extra;           /* the empty line after a final paragraph break */
    CGFloat fragX;        /* in a text block: its content's left edge */
    CGFloat fragWidth;    /* in a text block: its content's width (0: the container's) */
} UIFLine;

/* A text block's frame (margin included), for drawing and NSLayoutManager's block rects. */
typedef struct {
    NSTextBlock *block;   /* retained */
    NSRange range;        /* its characters */
    CGRect frame;         /* its bounds, margins included */
    CGRect content;       /* where its text is laid out */
} UIFBlockFrame;

typedef struct {
    UIFLine *lines;
    size_t count, capacity;
    CGFloat height;   /* to the bottom of the last line */
    NSUInteger end;   /* the first character not laid out */
    BOOL truncated;
    UIFBlockFrame *blocks;
    size_t blockCount, blockCapacity;
} UIFLayout;

typedef struct {
    CGFloat width;  /* the container's; 0: unbounded */
    CGFloat height; /* 0: unbounded */
    NSStringDrawingOptions options;
    NSUInteger start;    /* the first character to lay out */
    BOOL mayBeEmpty;     /* NO: the first line is kept even when it is too tall */
    BOOL roundLeading;   /* fonts' leading in whole points (NSLayoutManager's) */
    NSUInteger maximumLines; /* 0: no limit */
    BOOL inTextView;     /* text without a colour is textColor (a text view's), not black */
} UIFLayoutParams;

UIF_HIDDEN UIFLayout UIFLayoutString(NSAttributedString *s, NSDictionary *typing, UIFLayoutParams p);
UIF_HIDDEN void UIFLayoutFree(UIFLayout *l);
/* Draw the backgrounds and borders of the blocks among these characters (origin: the text area's). */
UIF_HIDDEN void UIFLayoutDrawBlocks(UIFLayout *L, NSRange chars, CGFloat left, CGFloat top, id layoutManager);
/* The rectangle a layout uses. */
UIF_HIDDEN CGRect UIFLayoutUsedRect(UIFLayout *L, UIFLayoutParams p);
/* Draw it with its first line's top at `top` (y grows down when flipped). */
UIF_HIDDEN void UIFLayoutDraw(UIFLayout *L, CGFloat left, CGFloat top, BOOL flipped);
UIF_HIDDEN void UIFLayoutDrawLines(UIFLayout *L, size_t first, size_t count, CGFloat left, CGFloat top, BOOL flipped);
UIF_HIDDEN void UIFLayoutDrawLinesInContext(CGContextRef cg, UIFLayout *L, size_t first, size_t count, CGFloat left,
                                            CGFloat top, BOOL flipped);

UIF_HIDDEN NSFont *UIFFontIn(NSDictionary *attrs);
UIF_HIDDEN NSParagraphStyle *UIFStyleIn(NSDictionary *attrs);

#endif
