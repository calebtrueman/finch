/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* What NSView, NSWindow and the drawing of view trees share (NSView.m, NSWindow.m). */
#ifndef NSVIEW_FINCH_H
#define NSVIEW_FINCH_H

#import "AppKit_Finch.h"

@interface NSView (Finch)
- (void)_finchSetSuperview:(NSView *)superview;
- (void)_finchSetWindow:(NSWindow *)window;
@end

@interface NSWindow (Finch)
- (void)_finchInvalidateRect:(NSRect)rectInWindow;
- (CGContextRef)_finchCGContext;
- (void)_finchFlushDrawing;
- (void)_finchResetFirstResponder;
@end

@interface NSTrackingArea (Finch)
- (void)_finchSetView:(NSView *)view;
- (NSView *)_finchView;
@end

FINCH_PRIVATE CGFloat FinchDefaultBackingScale(void);
FINCH_PRIVATE CGFloat FinchViewBackingScale(NSView *view);
FINCH_PRIVATE CGAffineTransform FinchViewToBase(NSView *view);
FINCH_PRIVATE NSRect FinchViewRectBeingDrawn(NSView *view);
FINCH_PRIVATE void FinchViewDrawTree(NSView *view, CGContextRef cg, NSRect rect, BOOL inViewSpace);

/* A class Finch's AppKit doesn't have yet, by name, so the build doesn't need it. */
#define FINCH_CLASS(name) ((Class)objc_getClass(#name))

#endif
