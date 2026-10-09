/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Internal declarations shared by AppKit's drawing classes: NSGraphicsContext,
 * NSColor and NSColorSpace, NSBezierPath, NSGradient, NSImage and its image
 * reps, and the NSGraphics.h functions.
 */
#ifndef APPKIT_DRAWING_H
#define APPKIT_DRAWING_H

#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

/* CoreGraphics' private exports AppKit reads its graphics state through (Apple's have the same names). */
CG_EXTERN CGBlendMode CGContextGetBlendMode(CGContextRef c);
CG_EXTERN int CGContextGetCompositeOperation(CGContextRef c);
CG_EXTERN void CGContextSetCompositeOperation(CGContextRef c, int op);
CG_EXTERN bool CGContextGetShouldAntialias(CGContextRef c);
CG_EXTERN CGColorRenderingIntent CGContextGetRenderingIntent(CGContextRef c);
CG_EXTERN CGSize CGContextGetPatternPhase(CGContextRef c);

#define FINCH_HIDDEN __attribute__((visibility("hidden")))

/* The current NSGraphicsContext's CGContext, or NULL. */
FINCH_HIDDEN CGContextRef FinchCurrentCGContext(void);

/* NSCompositingOperation to CG's composite operation (-1 for an invalid one). */
FINCH_HIDDEN int FinchCompositeOperation(NSCompositingOperation op);

/* Draw src (in a rep of size repSize; empty for all of it) of a CGImage into dst in the current context. */
FINCH_HIDDEN BOOL FinchDrawCGImage(CGImageRef image, NSSize repSize, NSRect dst, NSRect src, NSCompositingOperation op,
                                   CGFloat fraction, BOOL respectFlipped, NSDictionary *hints);

/* A component colour as NSGradient interpolates them. */
FINCH_HIDDEN NSColor *FinchGradientColor(NSColorSpace *space, const CGFloat *c, NSInteger n);

/* Raise NSInvalidArgumentException etc. with a printf-style reason. */
FINCH_HIDDEN void FinchDrawRaise(NSString *name, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3) __attribute__((noreturn));

@interface NSBitmapImageRep (FinchDrawing)
/* A bitmap context drawing into the rep's own buffer, or NULL if CG can't draw into its format. */
- (CGContextRef)_finchCreateCGContext CF_RETURNS_RETAINED;
/* The rep's pixels changed: drop any cached CGImage. */
- (void)_finchInvalidateImage;
@end

@interface NSColorSpace (FinchDrawing)
/* The archive's NSID for a named space, 0 for others. */
- (NSInteger)_finchArchiveID;
@end

@interface NSColor (FinchDrawing)
/* The colour as a CGColor in the given context, resolving catalog and pattern colours. */
- (CGColorRef)_finchCGColor;
@end

@interface NSImage (FinchDrawing)
/* A CGImage of the image at its size (pattern colours, template drawing). */
- (CGImageRef)_finchCGImage;
@end

#endif
