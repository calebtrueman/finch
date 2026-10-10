/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSShadow, NSStringDrawingContext and NSTextAttachment (its data, bounds
 * and attributed-string form; drawing attachments comes with the text system).
 */
#import <objc/message.h>
#import <objc/runtime.h>
#import "UIFoundationInternal.h"

#pragma mark - NSShadow

@implementation NSShadow {
    NSSize _offset;
    CGFloat _blur;
    id _color; /* NSColor, from AppKit */
}

+ (BOOL)supportsSecureCoding { return YES; }

- (void)dealloc
{
    [_color release];
    [super dealloc];
}

- (NSSize)shadowOffset { return _offset; }
- (void)setShadowOffset:(NSSize)offset { _offset = offset; }
- (CGFloat)shadowBlurRadius { return _blur; }
- (void)setShadowBlurRadius:(CGFloat)blur { _blur = blur; }

/* Unset, it is black at a third opacity (an NSColor made through AppKit, found at run time). */
- (NSColor *)shadowColor
{
    if (_color)
        return _color;
    Class c = UIFClass("NSColor");
    if ([c respondsToSelector:@selector(colorWithCalibratedRed:green:blue:alpha:)])
        return [c colorWithCalibratedRed:0 green:0 blue:0 alpha:1.0 / 3];
    return nil;
}

- (void)setShadowColor:(NSColor *)color
{
    id old = _color;
    _color = [color copy];
    [old release];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSShadow *s = [[NSShadow allocWithZone:zone] init];
    s->_offset = _offset;
    s->_blur = _blur;
    s->_color = [_color copy];
    return s;
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSShadow class]])
        return NO;
    NSShadow *s = other;
    return NSEqualSizes(s->_offset, _offset) && s->_blur == _blur && (s->_color == _color || [s->_color isEqual:_color]);
}

- (NSUInteger)hash { return (NSUInteger)(_offset.width * 31 + _offset.height * 17 + _blur * 7); }

- (NSString *)description
{
    NSMutableString *d = [NSMutableString stringWithFormat:@"NSShadow {%g, %g}", _offset.width, _offset.height];
    if (_blur != 0)
        [d appendFormat:@" blur = %g", _blur];
    if (_color)
        [d appendFormat:@" color = {%@}", _color];
    return d;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_blur != 0)
        [coder encodeDouble:_blur forKey:@"NSShadowBlurRadius"];
    if (_color)
        [coder encodeObject:_color forKey:@"NSShadowColor"];
    [coder encodeDouble:_offset.width forKey:@"NSShadowHoriz"];
    [coder encodeDouble:_offset.height forKey:@"NSShadowVert"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self init])) {
        _blur = [coder decodeDoubleForKey:@"NSShadowBlurRadius"];
        _offset = NSMakeSize([coder decodeDoubleForKey:@"NSShadowHoriz"], [coder decodeDoubleForKey:@"NSShadowVert"]);
        Class colorClass = UIFClass("NSColor");
        if (colorClass && [coder containsValueForKey:@"NSShadowColor"])
            _color = [[coder decodeObjectOfClass:colorClass forKey:@"NSShadowColor"] retain];
    }
    return self;
}

/* The shadow in the current context: offsets are in the context's default
 * (unflipped) space, so a flipped context's y is negated. */
- (void)set
{
    CGContextRef cg = UIFCurrentCGContext();
    if (!cg)
        return;
    CGFloat dy = UIFCurrentContextIsFlipped() ? -_offset.height : _offset.height;
    CGContextSetShadowWithColor(cg, CGSizeMake(_offset.width, dy), _blur, UIFCGColor(self.shadowColor));
}

@end

#pragma mark - NSStringDrawingContext

/*
 * Besides the public minimum scale factor and results, Apple's context carries private
 * options and results that SwiftUI's text uses: a line limit, and the baselines and line
 * count of the last layout. String drawing reads the options and sets the results
 * (NSStringDrawing.m).
 */
@interface NSStringDrawingContext () {
@public
    CGFloat _minimumScaleFactor, _actualScaleFactor;
    CGRect _totalBounds;
    CGFloat _baselineOffset, _firstBaselineOffset, _scaledLineHeight, _scaledBaselineOffset;
    BOOL _wrapsForTruncationMode, _wantsBaselineOffset, _wantsScaledLineHeight, _wantsScaledBaselineOffset;
    BOOL _cachesLayout, _wantsNumberOfLineFragments, _hasTruncatedRanges;
    NSInteger _maximumNumberOfLines, _numberOfLineFragments;
    NSUInteger _activeRenderers;
    id _layout;
    id _linkTextAttributesProvider;
}
@end

@implementation NSStringDrawingContext

- (void)dealloc
{
    [_layout release];
    [_linkTextAttributesProvider release];
    [super dealloc];
}

- (CGFloat)minimumScaleFactor { return _minimumScaleFactor; }
- (void)setMinimumScaleFactor:(CGFloat)f { _minimumScaleFactor = f; }
- (CGFloat)actualScaleFactor { return _actualScaleFactor; }
- (CGRect)totalBounds { return _totalBounds; }

- (CGFloat)baselineOffset { return _baselineOffset; }
- (void)setBaselineOffset:(CGFloat)v { _baselineOffset = v; }
- (CGFloat)firstBaselineOffset { return _firstBaselineOffset; }
- (void)setFirstBaselineOffset:(CGFloat)v { _firstBaselineOffset = v; }
- (CGFloat)scaledLineHeight { return _scaledLineHeight; }
- (void)setScaledLineHeight:(CGFloat)v { _scaledLineHeight = v; }
- (CGFloat)scaledBaselineOffset { return _scaledBaselineOffset; }
- (void)setScaledBaselineOffset:(CGFloat)v { _scaledBaselineOffset = v; }
- (BOOL)wrapsForTruncationMode { return _wrapsForTruncationMode; }
- (void)setWrapsForTruncationMode:(BOOL)v { _wrapsForTruncationMode = v; }
- (BOOL)wantsBaselineOffset { return _wantsBaselineOffset; }
- (void)setWantsBaselineOffset:(BOOL)v { _wantsBaselineOffset = v; }
- (BOOL)wantsScaledLineHeight { return _wantsScaledLineHeight; }
- (void)setWantsScaledLineHeight:(BOOL)v { _wantsScaledLineHeight = v; }
- (BOOL)wantsScaledBaselineOffset { return _wantsScaledBaselineOffset; }
- (void)setWantsScaledBaselineOffset:(BOOL)v { _wantsScaledBaselineOffset = v; }
- (BOOL)cachesLayout { return _cachesLayout; }
- (void)setCachesLayout:(BOOL)v { _cachesLayout = v; }
- (NSInteger)maximumNumberOfLines { return _maximumNumberOfLines; }
- (void)setMaximumNumberOfLines:(NSInteger)v { _maximumNumberOfLines = v; }
- (BOOL)wantsNumberOfLineFragments { return _wantsNumberOfLineFragments; }
- (void)setWantsNumberOfLineFragments:(BOOL)v { _wantsNumberOfLineFragments = v; }
- (NSUInteger)activeRenderers { return _activeRenderers; }
- (void)setActiveRenderers:(NSUInteger)v { _activeRenderers = v; }
- (id)layout { return _layout; }
- (void)setLayout:(id)v
{
    [_layout autorelease];
    _layout = [v retain];
}
- (NSInteger)numberOfLineFragments { return _numberOfLineFragments; }
- (BOOL)hasTruncatedRanges { return _hasTruncatedRanges; }
- (id)linkTextAttributesProvider { return _linkTextAttributesProvider; }
- (void)setLinkTextAttributesProvider:(id)v
{
    [_linkTextAttributesProvider autorelease];
    _linkTextAttributesProvider = [v copy];
}

@end

__attribute__((visibility("default"))) void
_NSStringDrawingContextSetBaselineOffset(NSStringDrawingContext *c, CGFloat offset)
{
    if (c)
        c->_baselineOffset = offset;
}

__attribute__((visibility("default"))) void
_NSStringDrawingContextSetFirstBaselineOffset(NSStringDrawingContext *c, CGFloat offset)
{
    if (c)
        c->_firstBaselineOffset = offset;
}

/* The context's line limit, for a layout's parameters. */
UIF_HIDDEN NSUInteger
UIFStringDrawingContextMaximumLines(NSStringDrawingContext *c)
{
    return c && c->_maximumNumberOfLines > 0 ? (NSUInteger)c->_maximumNumberOfLines : 0;
}

/* Set by string drawing (NSStringDrawing.m): the scale, bounds, baselines and line count. */
UIF_HIDDEN void
UIFStringDrawingContextSetResult(NSStringDrawingContext *c, CGFloat scale, CGRect bounds, CGFloat firstBaseline,
                                 CGFloat lastBaselineFromBottom, NSInteger lines, BOOL truncated)
{
    if (!c)
        return;
    c->_actualScaleFactor = scale;
    c->_totalBounds = bounds;
    c->_firstBaselineOffset = firstBaseline;
    c->_baselineOffset = lastBaselineFromBottom;
    c->_scaledBaselineOffset = lastBaselineFromBottom;
    c->_scaledLineHeight = lines ? bounds.size.height / lines : 0;
    c->_numberOfLineFragments = lines;
    c->_hasTruncatedRanges = truncated;
}

#pragma mark - NSTextAttachment

@implementation NSTextAttachment {
    NSData *_contents;
    NSString *_fileType;
    id _image;
    CGRect _bounds;
    NSFileWrapper *_fileWrapper;
    id _attachmentCell;
    CGFloat _lineLayoutPadding;
    BOOL _allowsTextAttachmentView;
    id _derivedImage;   /* from the contents or file wrapper, when no image was set */
}

+ (BOOL)supportsSecureCoding { return YES; }

static NSMutableDictionary *view_provider_classes;

+ (Class)textAttachmentViewProviderClassForFileType:(NSString *)fileType
{
    @synchronized(self) {
        return fileType ? view_provider_classes[fileType] : nil;
    }
}

+ (void)registerTextAttachmentViewProviderClass:(Class)cls forFileType:(NSString *)fileType
{
    @synchronized(self) {
        if (!view_provider_classes)
            view_provider_classes = [NSMutableDictionary new];
        if (fileType && cls)
            view_provider_classes[fileType] = cls;
    }
}

- (instancetype)init { return [self initWithData:nil ofType:nil]; }

- (instancetype)initWithData:(NSData *)contentData ofType:(NSString *)uti
{
    if ((self = [super init])) {
        _contents = [contentData copy];
        _fileType = [uti copy];
        _allowsTextAttachmentView = YES;
    }
    return self;
}

- (instancetype)initWithFileWrapper:(NSFileWrapper *)fileWrapper
{
    if ((self = [self initWithData:nil ofType:nil]))
        _fileWrapper = [fileWrapper retain];
    return self;
}

- (void)dealloc
{
    [_contents release];
    [_fileType release];
    [_image release];
    [_fileWrapper release];
    [_attachmentCell release];
    [_derivedImage release];
    [super dealloc];
}

/* The image shown: the one set, else (as Apple's) one made from the contents or the
 * file wrapper's file, when AppKit is there to make it. */
- (id)_finchDisplayImage
{
    if (_image)
        return _image;
    if (!_derivedImage) {
        Class imageClass = objc_getClass("NSImage");
        NSData *data = _contents;
        if (!data && [_fileWrapper isRegularFile])
            data = [_fileWrapper regularFileContents];
        if (imageClass && data)
            _derivedImage = ((id(*)(id, SEL, NSData *))objc_msgSend)([imageClass alloc], @selector(initWithData:), data);
    }
    return _derivedImage;
}

- (NSData *)contents { return _contents; }
- (void)setContents:(NSData *)contents
{
    NSData *old = _contents;
    _contents = [contents copy];
    [old release];
}
- (NSString *)fileType { return _fileType; }
- (void)setFileType:(NSString *)fileType
{
    NSString *old = _fileType;
    _fileType = [fileType copy];
    [old release];
}
- (NSImage *)image { return _image; }
- (void)setImage:(NSImage *)image
{
    id old = _image;
    _image = [image retain];
    [old release];
}
- (CGRect)bounds { return _bounds; }
- (void)setBounds:(CGRect)bounds { _bounds = bounds; }
- (NSFileWrapper *)fileWrapper { return _fileWrapper; }
- (void)setFileWrapper:(NSFileWrapper *)fileWrapper
{
    id old = _fileWrapper;
    _fileWrapper = [fileWrapper retain];
    [old release];
}
- (id<NSTextAttachmentCell>)attachmentCell { return _attachmentCell; }
- (void)setAttachmentCell:(id<NSTextAttachmentCell>)cell
{
    id old = _attachmentCell;
    _attachmentCell = [cell retain];
    [old release];
    if ([cell respondsToSelector:@selector(setAttachment:)])
        [cell setAttachment:self];
}
- (CGFloat)lineLayoutPadding { return _lineLayoutPadding; }
- (void)setLineLayoutPadding:(CGFloat)p { _lineLayoutPadding = p; }
- (BOOL)allowsTextAttachmentView { return _allowsTextAttachmentView; }
- (void)setAllowsTextAttachmentView:(BOOL)v { _allowsTextAttachmentView = v; }
- (BOOL)usesTextAttachmentView { return NO; }

- (CGRect)attachmentBoundsForTextContainer:(NSTextContainer *)textContainer
                      proposedLineFragment:(CGRect)lineFrag
                             glyphPosition:(CGPoint)position
                            characterIndex:(NSUInteger)charIndex
{
    if (!CGRectIsEmpty(_bounds))
        return _bounds;
    id image = [self _finchDisplayImage];
    if ([image respondsToSelector:@selector(size)]) {
        CGSize size = ((CGSize(*)(id, SEL))objc_msgSend)(image, @selector(size));
        return CGRectMake(0, 0, size.width, size.height);
    }
    return CGRectZero;
}

- (NSImage *)imageForBounds:(CGRect)imageBounds textContainer:(NSTextContainer *)textContainer characterIndex:(NSUInteger)charIndex
{
    return [self _finchDisplayImage];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (_fileWrapper)
        [coder encodeObject:_fileWrapper forKey:@"NSFileWrapper"];
    if (_contents)
        [coder encodeObject:_contents forKey:@"NSContents"];
    if (_fileType)
        [coder encodeObject:_fileType forKey:@"NSFileType"];
    if (!CGRectIsEmpty(_bounds))
        [coder encodeRect:NSRectFromCGRect(_bounds) forKey:@"NSBounds"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self initWithData:[coder decodeObjectOfClass:[NSData class] forKey:@"NSContents"]
                            ofType:[coder decodeObjectOfClass:[NSString class] forKey:@"NSFileType"]])) {
        _fileWrapper = [[coder decodeObjectOfClass:[NSFileWrapper class] forKey:@"NSFileWrapper"] retain];
        if ([coder containsValueForKey:@"NSBounds"])
            _bounds = NSRectToCGRect([coder decodeRectForKey:@"NSBounds"]);
    }
    return self;
}

@end

@implementation NSAttributedString (NSAttributedStringAttachmentConveniences)

+ (NSAttributedString *)attributedStringWithAttachment:(NSTextAttachment *)attachment
{
    return [self attributedStringWithAttachment:attachment attributes:@{}];
}

+ (instancetype)attributedStringWithAttachment:(NSTextAttachment *)attachment attributes:(NSDictionary *)attributes
{
    unichar c = NSAttachmentCharacter;
    NSMutableDictionary *a = [[attributes mutableCopy] autorelease];
    if (!a)
        a = [NSMutableDictionary dictionary];
    if (attachment)
        a[NSAttachmentAttributeName] = attachment;
    return [[[self alloc] initWithString:[NSString stringWithCharacters:&c length:1] attributes:a] autorelease];
}

@end
