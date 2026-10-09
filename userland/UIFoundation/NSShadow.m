/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSShadow, NSStringDrawingContext and NSTextAttachment (its data, bounds
 * and attributed-string form; drawing attachments comes with the text system).
 */
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

@interface NSStringDrawingContext () {
@public
    CGFloat _minimumScaleFactor, _actualScaleFactor;
    CGRect _totalBounds;
}
@end

@implementation NSStringDrawingContext

- (CGFloat)minimumScaleFactor { return _minimumScaleFactor; }
- (void)setMinimumScaleFactor:(CGFloat)f { _minimumScaleFactor = f; }
- (CGFloat)actualScaleFactor { return _actualScaleFactor; }
- (CGRect)totalBounds { return _totalBounds; }

@end

/* Set by string drawing (NSStringDrawing.m). */
UIF_HIDDEN void
UIFStringDrawingContextSetResult(NSStringDrawingContext *c, CGFloat scale, CGRect bounds)
{
    if (!c)
        return;
    c->_actualScaleFactor = scale;
    c->_totalBounds = bounds;
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
    [super dealloc];
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
    id image = _image;
    if ([image respondsToSelector:@selector(size)])
        return CGRectMake(0, 0, [image size].width, [image size].height);
    return CGRectZero;
}

- (NSImage *)imageForBounds:(CGRect)imageBounds textContainer:(NSTextContainer *)textContainer characterIndex:(NSUInteger)charIndex
{
    return _image;
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
