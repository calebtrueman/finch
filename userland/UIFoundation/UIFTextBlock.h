/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Text blocks' geometry for layout (NSTextBlock.m).
 */
#ifndef UIF_TEXT_BLOCK_H
#define UIF_TEXT_BLOCK_H

#import "UIFoundationInternal.h"

@interface NSTextBlock (FinchCopy)
- (void)_finchCopyFrom:(NSTextBlock *)other;
@end

/* The margin, border and padding on an edge, percentages being of `of`. */
UIF_HIDDEN CGFloat UIFTextBlockInset(NSTextBlock *b, NSRectEdge edge, CGFloat of);
/* The layers outside `layer` on an edge (the margin's and border's widths outside the padding, ...). */
UIF_HIDDEN CGFloat UIFTextBlockLayerInset(NSTextBlock *b, NSTextBlockLayer layer, NSRectEdge edge, CGFloat of);
UIF_HIDDEN CGFloat UIFTextBlockDimension(NSTextBlock *b, NSTextBlockDimension d, CGFloat of);

#endif
