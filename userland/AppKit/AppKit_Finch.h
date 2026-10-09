/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch AppKit's internal declarations (docs/design/APPKIT.md): the window
 * server client in CoreGraphics, and what AppKit's classes share.
 */
#ifndef APPKIT_FINCH_H
#define APPKIT_FINCH_H

#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include "WindowServer/FinchWSProtocol.h"

#define FINCH_PRIVATE __attribute__((visibility("hidden")))

/* CoreGraphics' window-server client (CGWindowServer.cpp) */
__BEGIN_DECLS
bool FWSConnect(void);
int FWSConnectionFileDescriptor(void);
bool FWSGetDisplayInfo(FWSDisplayInfo *out);
uint32_t FWSCreateWindow(FWSRect frame, int32_t level, uint32_t flags);
void *FWSWindowBuffer(uint32_t window, uint32_t *pixel_width, uint32_t *pixel_height, uint32_t *bytes_per_row);
CGContextRef FWSCreateWindowContext(uint32_t window);
void FWSSetWindowFrame(uint32_t window, FWSRect frame);
void FWSDestroyWindow(uint32_t window);
void FWSOrderWindow(uint32_t window, int32_t mode, uint32_t relative_to);
void FWSSetWindowLevel(uint32_t window, int32_t level);
void FWSSetWindowAlpha(uint32_t window, double alpha);
void FWSSetWindowFlags(uint32_t window, uint32_t flags);
void FWSSetWindowTitle(uint32_t window, const char *title);
void FWSFlushWindow(uint32_t window, FWSRect rect);
void FWSMakeKeyWindow(uint32_t window);
void FWSWarpCursor(double x, double y);
void FWSSetCursorVisible(bool visible);
void FWSSetCursorShape(int32_t shape);
void FWSPostEvent(const FWSEvent *event);
bool FWSIsActive(void);
bool FWSNextEvent(FWSEvent *out, bool wait);
bool FWSSetEventHandler(void (*callback)(const FWSEvent *event, void *info), void *info);
FWSWindowInfo *FWSCopyWindowList(uint32_t *count);
__END_DECLS

/* Key bindings (NSKeyBindings.m): the standard Cocoa bindings for one key event. */
FINCH_PRIVATE void FinchInterpretKeyEvent(NSResponder *responder, NSEvent *event);

/* NSEvent (NSEvent.m) */
FINCH_PRIVATE NSEvent *FinchEventFromServer(const FWSEvent *e, NSWindow *window);
FINCH_PRIVATE NSPoint FinchEventScreenLocation(NSEvent *event);
FINCH_PRIVATE void FinchEventNoteModifiers(NSEventModifierFlags flags, NSPoint mouse, NSUInteger buttons);

/* NSApplication (NSApplication.m) */
FINCH_PRIVATE void FinchApplicationNeedsDisplay(void);
FINCH_PRIVATE void FinchApplicationWindowOrderedOut(NSWindow *window);
FINCH_PRIVATE void FinchApplicationSetKeyWindow(NSWindow *window);
FINCH_PRIVATE void FinchApplicationSetMainWindow(NSWindow *window);
FINCH_PRIVATE NSEvent *FinchEventApplyLocalMonitors(NSEvent *event);

/* NSWindow (NSWindow.m) */
FINCH_PRIVATE NSArray *FinchAllWindows(void);
FINCH_PRIVATE NSWindow *FinchWindowForNumber(NSInteger number);
FINCH_PRIVATE void FinchWindowServerEvent(const FWSEvent *e);

#endif
