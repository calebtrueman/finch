/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * UIFoundation (docs/design/APPKIT.md): the half of AppKit Apple shares with
 * UIKit. Its classes live in the other files here; this one has its version
 * and its run-time links to AppKit, which it can't link (AppKit links it).
 */
#import "UIFoundationInternal.h"
#import <objc/message.h>
#import <objc/runtime.h>

const double UIFoundationVersionNumber = 1018.1;

Class
UIFClass(const char *name)
{
    return objc_getClass(name);
}

static id
current_graphics_context(void)
{
    Class c = UIFClass("NSGraphicsContext");
    return c && [c respondsToSelector:@selector(currentContext)] ? [c currentContext] : nil;
}

CGContextRef
UIFCurrentCGContext(void)
{
    id ctx = current_graphics_context();
    if ([ctx respondsToSelector:@selector(CGContext)])
        return [ctx CGContext];
    if ([ctx respondsToSelector:@selector(graphicsPort)])
        return (CGContextRef)[ctx graphicsPort];
    return NULL;
}

BOOL
UIFCurrentContextIsFlipped(void)
{
    id ctx = current_graphics_context();
    return [ctx respondsToSelector:@selector(isFlipped)] ? [ctx isFlipped] : NO;
}

CGColorRef
UIFCGColor(id color)
{
    if (!color)
        return NULL;
    if ([color respondsToSelector:@selector(CGColor)])
        return [color CGColor];
    if ([color respondsToSelector:@selector(_cfTypeID)] && CFGetTypeID((CFTypeRef)color) == CGColorGetTypeID())
        return (CGColorRef)color;
    return NULL;
}
