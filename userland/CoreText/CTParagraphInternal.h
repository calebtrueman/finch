/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CTParagraphStyle's representation, shared with the typesetter. */
#ifndef CT_PARAGRAPH_INTERNAL_H
#define CT_PARAGRAPH_INTERNAL_H

#include "CTInternal.h"

struct CTParagraphValues {
    CTTextAlignment alignment;
    CTLineBreakMode line_break;
    CTWritingDirection direction;
    CGFloat first_indent, head_indent, tail_indent, tab_interval;
    CGFloat line_height_multiple, max_line_height, min_line_height, line_spacing;
    CGFloat paragraph_spacing, paragraph_spacing_before, max_line_spacing, min_line_spacing;
    CGFloat line_spacing_adjustment;
    CTLineBoundsOptions bounds_options;
};

struct __CTParagraphStyle {
    CTRuntimeBase base;
    CTParagraphValues values;
    CFArrayRef tabs;
};

#endif
