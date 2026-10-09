/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextContainer: the region text is laid out in (a rectangle; exclusion
 * paths are kept but not yet laid around), with Apple's defaults, archive
 * keys and description. A container belongs to an NSLayoutManager (TextKit 1)
 * or an NSTextLayoutManager (TextKit 2). Asking a TextKit 2 text view's
 * container for its layoutManager switches the view to TextKit 1, as on macOS.
 */
#import "UIFTextKit2.h"

/* A TextKit 2 text view (AppKit's NSTextView) switching to TextKit 1. */
@interface NSObject (UIFTextKit1Fallback)
- (void)_finchSwitchToTextKit1;
@end

@interface NSLayoutManager (UIFTextContainer)
- (void)textContainerChangedGeometry:(NSTextContainer *)container;
@end

@implementation NSTextContainer {
    CGSize _size;
    CGFloat _padding;
    NSLineBreakMode _lineBreakMode;
    NSUInteger _maximumNumberOfLines;
    NSArray *_exclusionPaths;
    NSLayoutManager *_layoutManager; /* not retained: it owns its containers */
    NSTextLayoutManager *_uifTLM; /* not retained: it owns its container */
    __weak id _textView;
    BOOL _widthTracksTextView, _heightTracksTextView;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithSize:(CGSize)size
{
    if ((self = [super init])) {
        _size = size;
        _padding = 5;
        _exclusionPaths = [@[] retain];
    }
    return self;
}

- (instancetype)init { return [self initWithSize:CGSizeMake(10000000, 10000000)]; }
- (instancetype)initWithContainerSize:(NSSize)size { return [self initWithSize:size]; }

- (void)dealloc
{
    [_exclusionPaths release];
    [super dealloc];
}

static void
changed(NSTextContainer *self, NSLayoutManager *lm)
{
    if ([lm respondsToSelector:@selector(textContainerChangedGeometry:)])
        [lm textContainerChangedGeometry:self];
    [self->_uifTLM _uifTextContainerChanged];
}


- (CGSize)size { return _size; }
- (void)setSize:(CGSize)size
{
    if (CGSizeEqualToSize(size, _size))
        return;
    _size = size;
    changed(self, _layoutManager);
}
- (NSSize)containerSize { return _size; }
- (void)setContainerSize:(NSSize)size { self.size = size; }
- (CGFloat)lineFragmentPadding { return _padding; }
- (void)setLineFragmentPadding:(CGFloat)p
{
    _padding = p;
    changed(self, _layoutManager);
}
- (NSLineBreakMode)lineBreakMode { return _lineBreakMode; }
- (void)setLineBreakMode:(NSLineBreakMode)m
{
    _lineBreakMode = m;
    changed(self, _layoutManager);
}
- (NSUInteger)maximumNumberOfLines { return _maximumNumberOfLines; }
- (void)setMaximumNumberOfLines:(NSUInteger)n
{
    _maximumNumberOfLines = n;
    changed(self, _layoutManager);
}
- (NSArray *)exclusionPaths { return _exclusionPaths; }
- (void)setExclusionPaths:(NSArray *)paths
{
    NSArray *old = _exclusionPaths;
    _exclusionPaths = [(paths ? paths : @[]) copy];
    [old release];
    changed(self, _layoutManager);
}
- (BOOL)isSimpleRectangularTextContainer { return _exclusionPaths.count == 0; }
- (NSTextLayoutOrientation)layoutOrientation { return NSTextLayoutOrientationHorizontal; }
- (BOOL)widthTracksTextView { return _widthTracksTextView; }
- (void)setWidthTracksTextView:(BOOL)v { _widthTracksTextView = v; }
- (BOOL)heightTracksTextView { return _heightTracksTextView; }
- (void)setHeightTracksTextView:(BOOL)v { _heightTracksTextView = v; }
- (NSLayoutManager *)layoutManager
{
    if (!_layoutManager && _uifTLM) {
        id tv = _textView;
        if ([tv respondsToSelector:@selector(_finchSwitchToTextKit1)])
            [tv _finchSwitchToTextKit1];
    }
    return _layoutManager;
}
- (void)setLayoutManager:(NSLayoutManager *)lm { _layoutManager = lm; }
- (NSTextLayoutManager *)textLayoutManager { return _uifTLM; }
- (void)_uifSetTextLayoutManager:(NSTextLayoutManager *)tlm { _uifTLM = tlm; }
- (NSTextView *)textView { return _textView; }
- (void)setTextView:(NSTextView *)textView { _textView = textView; }

- (void)replaceLayoutManager:(NSLayoutManager *)newLayoutManager
{
    NSLayoutManager *old = _layoutManager;
    if (old == newLayoutManager)
        return;
    [self retain];
    NSUInteger i = [old.textContainers indexOfObjectIdenticalTo:self];
    if (i != NSNotFound)
        [old removeTextContainerAtIndex:i];
    [newLayoutManager addTextContainer:self];
    [self release];
}

- (CGRect)lineFragmentRectForProposedRect:(CGRect)proposedRect
                                  atIndex:(NSUInteger)characterIndex
                         writingDirection:(NSWritingDirection)baseWritingDirection
                            remainingRect:(CGRect *)remainingRect
{
    if (remainingRect)
        *remainingRect = CGRectZero;
    CGRect bounds = CGRectMake(0, 0, _size.width, _size.height);
    CGRect r = CGRectIntersection(proposedRect, bounds);
    if (CGRectIsNull(r) || r.size.height < proposedRect.size.height)
        return CGRectZero;
    return r;
}

- (NSRect)lineFragmentRectForProposedRect:(NSRect)proposedRect
                           sweepDirection:(NSLineSweepDirection)sweepDirection
                        movementDirection:(NSLineMovementDirection)movementDirection
                            remainingRect:(NSRectPointer)remainingRect
{
    return [self lineFragmentRectForProposedRect:proposedRect atIndex:0 writingDirection:NSWritingDirectionNatural
                                   remainingRect:remainingRect];
}

- (BOOL)containsPoint:(NSPoint)point
{
    return NSPointInRect(point, NSMakeRect(0, 0, _size.width, _size.height));
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<NSTextContainer: %p size = (%f,%f); widthTracksTextView = %@; heightTracksTextView = %@>; "
                                      @"exclusionPaths = %p; lineBreakMode = %ld",
                                      self, _size.width, _size.height, _widthTracksTextView ? @"YES" : @"NO",
                                      _heightTracksTextView ? @"YES" : @"NO", _exclusionPaths, (long)_lineBreakMode];
}

/* NSTCFlags: bit 0 widthTracksTextView, bit 1 heightTracksTextView. */
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_size.width forKey:@"NSWidth"];
    [coder encodeDouble:_size.height forKey:@"NSHeight"];
    [coder encodeDouble:_padding forKey:@"NSPadding"];
    [coder encodeDouble:15 forKey:@"NSMinWidth"];
    [coder encodeInteger:(_widthTracksTextView ? 1 : 0) | (_heightTracksTextView ? 2 : 0) forKey:@"NSTCFlags"];
    /* Unconditionally, as Apple's: a text view's archive holds its text system through its container. */
    [coder encodeObject:_layoutManager forKey:@"NSLayoutManager"];
    if (_uifTLM)
        [coder encodeObject:_uifTLM forKey:@"NSTextLayoutManager"];
    else
        [coder encodeConditionalObject:nil forKey:@"NSTextLayoutManager"];
    [coder encodeConditionalObject:_textView forKey:@"NSTextView"];
    if (_exclusionPaths.count)
        [coder encodeObject:_exclusionPaths forKey:@"NSExclusionPaths"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    /* ibtool leaves out a height (or width) that is the default, 10000000 */
    CGSize size = CGSizeMake([coder containsValueForKey:@"NSWidth"] ? [coder decodeDoubleForKey:@"NSWidth"] : 10000000,
                             [coder containsValueForKey:@"NSHeight"] ? [coder decodeDoubleForKey:@"NSHeight"] : 10000000);
    if ([coder containsValueForKey:@"NSSize"])
        size = [coder decodeSizeForKey:@"NSSize"];
    if ((self = [self initWithSize:size])) {
        if ([coder containsValueForKey:@"NSPadding"])
            _padding = [coder decodeDoubleForKey:@"NSPadding"];
        NSInteger flags = [coder decodeIntegerForKey:@"NSTCFlags"];
        _widthTracksTextView = (flags & 1) != 0;
        _heightTracksTextView = (flags & 2) != 0;
        _textView = [coder decodeObjectForKey:@"NSTextView"];
        NSArray *paths = [coder decodeObjectForKey:@"NSExclusionPaths"];
        if ([paths isKindOfClass:[NSArray class]])
            self.exclusionPaths = paths;
        NSLayoutManager *lm = [coder decodeObjectForKey:@"NSLayoutManager"];
        if (lm && [lm.textContainers indexOfObjectIdenticalTo:self] == NSNotFound)
            _layoutManager = lm;
        NSTextLayoutManager *tlm = [coder decodeObjectForKey:@"NSTextLayoutManager"];
        if ([tlm isKindOfClass:[NSTextLayoutManager class]] && !_layoutManager)
            tlm.textContainer = self;
    }
    return self;
}

@end
