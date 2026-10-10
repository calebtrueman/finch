/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* What NSView, NSWindow and the drawing of view trees share (NSView.m, NSWindow.m). */
#ifndef NSVIEW_FINCH_H
#define NSVIEW_FINCH_H

#import "AppKit_Finch.h"

@interface NSView (Finch)
- (void)_finchDeliverGestureEvent:(NSEvent *)event selector:(SEL)selector;
- (void)_finchSetSuperview:(NSView *)superview;
- (void)_finchSetWindow:(NSWindow *)window;
- (id)_finchLayoutState;
- (void)_finchSetLayoutState:(id)state;
@end

@interface NSWindow (Finch)
- (void)_finchInvalidateRect:(NSRect)rectInWindow;
- (CGContextRef)_finchCGContext;
- (void)_finchFlushDrawing;
- (void)_finchResetFirstResponder;
@end

@interface NSWindow (FinchToolbar)
- (void)_finchToolbarChanged;
@end

@interface NSToolbar (Finch)
- (void)_finchSetWindow:(NSWindow *)window;
- (NSView *)_finchView;
- (void)_finchChanged;
@end

@interface NSToolbarItem (Finch)
- (void)_finchSetToolbar:(NSToolbar *)toolbar;
- (NSRect)_finchFrame;
- (void)_finchSetFrame:(NSRect)frame;
- (void)_finchPerform;
@end

@interface NSTrackingArea (Finch)
- (void)_finchSetView:(NSView *)view;
- (BOOL)_finchInside;
- (void)_finchSetInside:(BOOL)inside;
- (NSView *)_finchView;
@end

FINCH_PRIVATE CGFloat FinchDefaultBackingScale(void);
FINCH_PRIVATE NSViewController *FinchViewControllerOf(NSView *view);
FINCH_PRIVATE CGFloat FinchViewBackingScale(NSView *view);
FINCH_PRIVATE CGAffineTransform FinchViewToBase(NSView *view);
FINCH_PRIVATE NSRect FinchViewRectBeingDrawn(NSView *view);
FINCH_PRIVATE void FinchViewDrawTree(NSView *view, CGContextRef cg, NSRect rect, BOOL inViewSpace);

/* Auto Layout's hooks in NSView (NSViewLayout.m). */
FINCH_PRIVATE void FinchLayoutViewFrameDidChange(NSView *view);
FINCH_PRIVATE void FinchLayoutViewDidMoveToSuperview(NSView *view);
FINCH_PRIVATE void FinchLayoutViewWillLeaveSuperview(NSView *view, NSView *superview);
FINCH_PRIVATE void FinchLayoutViewDealloc(NSView *view);
FINCH_PRIVATE void FinchLayoutDecodeView(NSView *view, NSCoder *coder);

/* A class Finch's AppKit doesn't have yet, by name, so the build doesn't need it. */
#define FINCH_CLASS(name) ((Class)objc_getClass(#name))

/* A view's frame changed: geometry-in-window observers on it or above it are told (AppKitPrivate.m). */
FINCH_PRIVATE void FinchViewGeometryInWindowDidChange(NSView *view);

#endif
