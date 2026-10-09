/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSImageView: an NSControl over an NSImageCell. Not editable, animating
 * and allowing cut, copy and paste by default, as Apple's.
 */
#import "NSControl_Finch.h"

@interface NSImageCell (FinchImageView)
- (BOOL)_finchAnimates;
- (void)_finchSetAnimates:(BOOL)flag;
@end

@implementation NSImageView {
    NSImageSymbolConfiguration *_symbolConfiguration;
    NSColor *_contentTintColor;
    NSImageDynamicRange _preferredRange;
    struct {
        unsigned editable : 1;
        unsigned allowsCutCopyPaste : 1;
    } _iv;
}

static NSImageDynamicRange default_range = NSImageDynamicRangeUnspecified;

+ (Class)cellClass
{
    return [super cellClass] ?: [NSImageCell class];
}

+ (instancetype)imageViewWithImage:(NSImage *)image
{
    NSImageView *v = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [v setImage:image];
    return v;
}

+ (NSImageDynamicRange)defaultPreferredImageDynamicRange { return default_range; }
+ (void)setDefaultPreferredImageDynamicRange:(NSImageDynamicRange)r { default_range = r; }

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    _iv.allowsCutCopyPaste = YES;
    _preferredRange = default_range;
    [[self cell] _finchSetAnimates:YES];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _iv.editable = [coder containsValueForKey:@"NSEditable"] && [coder decodeBoolForKey:@"NSEditable"] &&
                   [[self cell] isEditable];
    _iv.allowsCutCopyPaste = [coder containsValueForKey:@"NSImageViewAllowsCutCopyPaste"]
                                 ? [coder decodeBoolForKey:@"NSImageViewAllowsCutCopyPaste"]
                                 : YES;
    _preferredRange = default_range;
    [[self cell] _finchSetAnimates:YES];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeBool:_iv.editable forKey:@"NSEditable"];
}

- (void)dealloc
{
    [_symbolConfiguration release];
    [_contentTintColor release];
    [super dealloc];
}

static NSImageCell *
icell(NSImageView *v)
{
    id c = [v cell];
    return [c isKindOfClass:[NSImageCell class]] ? c : nil;
}

- (NSImage *)image { return [[self cell] image]; }

- (void)setImage:(NSImage *)image
{
    [[self cell] setImage:image];
    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
}

- (BOOL)isEditable { return _iv.editable; }

- (void)setEditable:(BOOL)flag
{
    _iv.editable = flag;
    [[self cell] setEditable:flag];
}

- (NSImageAlignment)imageAlignment { return [icell(self) imageAlignment]; }
- (void)setImageAlignment:(NSImageAlignment)a { [icell(self) setImageAlignment:a]; }
- (NSImageScaling)imageScaling { return [icell(self) imageScaling]; }
- (void)setImageScaling:(NSImageScaling)s { [icell(self) setImageScaling:s]; }
- (NSImageFrameStyle)imageFrameStyle { return [icell(self) imageFrameStyle]; }
- (void)setImageFrameStyle:(NSImageFrameStyle)s { [icell(self) setImageFrameStyle:s]; }
- (BOOL)animates { return [icell(self) _finchAnimates]; }
- (void)setAnimates:(BOOL)flag { [icell(self) _finchSetAnimates:flag]; }
- (BOOL)allowsCutCopyPaste { return _iv.allowsCutCopyPaste; }
- (void)setAllowsCutCopyPaste:(BOOL)flag { _iv.allowsCutCopyPaste = flag; }
- (NSImageSymbolConfiguration *)symbolConfiguration { return _symbolConfiguration; }

- (void)setSymbolConfiguration:(NSImageSymbolConfiguration *)c
{
    [_symbolConfiguration release];
    _symbolConfiguration = [c copy];
}

- (NSColor *)contentTintColor { return _contentTintColor; }

- (void)setContentTintColor:(NSColor *)c
{
    [_contentTintColor release];
    _contentTintColor = [c copy];
    [self setNeedsDisplay:YES];
}

- (NSImageDynamicRange)preferredImageDynamicRange { return _preferredRange; }
- (void)setPreferredImageDynamicRange:(NSImageDynamicRange)r { _preferredRange = r; }
- (NSImageDynamicRange)imageDynamicRange { return NSImageDynamicRangeStandard; }

- (NSSize)intrinsicContentSize
{
    NSImage *i = [self image];
    return i ? [[self cell] cellSize] : NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

/* Not a tracking control: clicks go up the responder chain (dragging images in is not done yet). */
- (void)mouseDown:(NSEvent *)event
{
    [[self nextResponder] mouseDown:event];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item { return _iv.allowsCutCopyPaste && [self image] != nil; }

- (void)copy:(id)sender
{
    NSImage *i = [self image];
    if (!i || !_iv.allowsCutCopyPaste)
        return;
    id pb = [(id)FINCH_CLASS(NSPasteboard) generalPasteboard];
    [pb clearContents];
    [pb writeObjects:@[ i ]];
}

- (void)cut:(id)sender
{
    if (!_iv.editable)
        return;
    [self copy:sender];
    [self setImage:nil];
    [self sendAction:[self action] to:[self target]];
}

- (void)delete:(id)sender
{
    if (!_iv.editable)
        return;
    [self setImage:nil];
    [self sendAction:[self action] to:[self target]];
}

@end
