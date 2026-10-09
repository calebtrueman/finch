/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * UIFoundation internals shared between its files.
 */
#ifndef UIFOUNDATION_INTERNAL_H
#define UIFOUNDATION_INTERNAL_H

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>

#ifdef __cplusplus
#define UIF_HIDDEN extern "C" __attribute__((visibility("hidden")))
#else
#define UIF_HIDDEN __attribute__((visibility("hidden")))
#endif

/* The concrete classes: Apple's names, as apps see them in class names and
 * descriptions. NSFont and NSFontDescriptor instances are CTFont and
 * CTFontDescriptor objects (toll-free bridged, as on macOS). */
@interface UIFont : NSFont
@end
@interface NSCTFont : UIFont
@end
@interface UIFontDescriptor : NSFontDescriptor
@end
@interface NSCTFontDescriptor : UIFontDescriptor
@end

/* The PostScript name Finch ships in place of an Apple font name, or nil
 * (userland/fonts/FinchFonts.h). */
UIF_HIDDEN NSString *UIFFontAlias(NSString *name);

/* AppKit's classes, found at run time: UIFoundation doesn't link AppKit
 * (AppKit links it). */
UIF_HIDDEN Class UIFClass(const char *name);
/* The current NSGraphicsContext's CGContext, or NULL. */
UIF_HIDDEN CGContextRef UIFCurrentCGContext(void);
/* Whether the current NSGraphicsContext is flipped. */
UIF_HIDDEN BOOL UIFCurrentContextIsFlipped(void);
/* A CGColor (not retained) for an NSColor (or a CGColor passed as one). */
UIF_HIDDEN CGColorRef UIFCGColor(id color);

/* The font NSFont uses for a descriptor with Apple's UI-usage attribute
 * (NSCTFontUIUsageAttribute), or nil. */
UIF_HIDDEN NSFont *UIFSystemFontForUsage(NSString *usage, CGFloat size);
/* The descriptor a system font reports (Apple's usage keys), or nil for
 * other fonts. */
UIF_HIDDEN NSFontDescriptor *UIFSystemFontDescriptor(NSFont *font);

extern NSString *const UIFUIUsageAttribute;     /* NSCTFontUIUsageAttribute */
extern NSString *const UIFSizeCategoryAttribute; /* NSCTFontSizeCategoryAttribute */

/* The default font for text without one: Helvetica 12. */
UIF_HIDDEN NSFont *UIFDefaultFont(void);

#endif
