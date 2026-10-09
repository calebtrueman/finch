/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSLayoutManager (TextKit 1): lays its text storage out in its text
 * containers, one after another, with the layout string drawing uses
 * (UIFTextLayout.m), and answers geometry questions and draws.
 *
 * As Apple's, in container coordinates (y down): line fragments span the
 * container's width; text starts after the container's line fragment
 * padding; used rectangles include the padding on both sides; a final
 * paragraph break (or empty text) gets the extra line fragment.
 *
 * Glyphs are one per character (characters with no glyph in their font get
 * glyph 0), so glyph and character indexes are the same.
 */
#import "UIFTextLayout.h"

typedef struct {
    UIFLayout layout;
    CGFloat padding, width;
    NSRange range; /* the characters laid out in it */
} ContainerLayout;

@interface NSTextContainer (UIFLayoutManager)
- (void)setLayoutManager:(NSLayoutManager *)lm;
@end

@interface NSLayoutManager () {
    NSTextStorage *_textStorage; /* not retained: the text storage owns its layout managers */
    NSMutableArray *_containers;
    __weak id<NSLayoutManagerDelegate> _delegate;
    ContainerLayout *_layouts;
    size_t _layoutCount;
    BOOL _valid;
    BOOL _showsInvisibles, _showsControls, _usesDefaultHyphenation, _usesFontLeading, _allowsNonContiguous;
    BOOL _limitsSuspicious, _backgroundLayout, _usesScreenFonts;
    float _hyphenationFactor;
    NSTypesetterBehavior _typesetterBehavior;
    NSImageScaling _attachmentScaling;
    NSMutableAttributedString *_temporary;
    NSRect *_rectArray;
    NSUInteger _rectCapacity;
    NSUInteger _generation; /* bumped whenever the layout is discarded */
    BOOL _engine;           /* NSTextLayoutManager's layout (UIFTextKit2.h) */
}
@end

/* A text view hearing about edits to its storage (AppKit's NSTextView). */
@interface NSObject (UIFTextViewEditing)
- (void)_finchTextStorageEdited:(NSTextStorageEditActions)mask range:(NSRange)range changeInLength:(NSInteger)delta;
@end

@implementation NSLayoutManager

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _containers = [NSMutableArray new];
        _usesFontLeading = YES;
        _limitsSuspicious = YES;
        _backgroundLayout = YES;
        _usesScreenFonts = NO;
        _typesetterBehavior = NSTypesetterLatestBehavior;
        _attachmentScaling = NSImageScaleProportionallyDown;
    }
    return self;
}

static void
discard_layout(NSLayoutManager *self)
{
    for (size_t i = 0; i < self->_layoutCount; i++)
        UIFLayoutFree(&self->_layouts[i].layout);
    free(self->_layouts);
    self->_layouts = NULL;
    self->_layoutCount = 0;
    self->_valid = NO;
    self->_generation++;
}

- (void)dealloc
{
    discard_layout(self);
    if (!_engine)
        for (NSTextContainer *c in _containers)
            [c setLayoutManager:nil];
    [_containers release];
    [_temporary release];
    free(_rectArray);
    [super dealloc];
}

#pragma mark Archiving

/* As Apple archives it (in nibs): the text storage, the containers, NSLMFlags, the delegate. */
enum { LM_ALLOWS_NONCONTIGUOUS = 1 << 7 };

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self init]))
        return nil;
    int flags = [coder decodeIntForKey:@"NSLMFlags"];
    _allowsNonContiguous = (flags & LM_ALLOWS_NONCONTIGUOUS) != 0;
    _delegate = [coder decodeObjectForKey:@"NSDelegate"];
    NSArray *containers = [coder decodeObjectForKey:@"NSTextContainers"];
    for (NSTextContainer *c in containers)
        if ([c isKindOfClass:[NSTextContainer class]] && [_containers indexOfObjectIdenticalTo:c] == NSNotFound)
            [self addTextContainer:c];
    NSTextStorage *ts = [coder decodeObjectForKey:@"NSTextStorage"];
    if ([ts isKindOfClass:[NSTextStorage class]])
        [ts addLayoutManager:self];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_engine ? nil : _textStorage forKey:@"NSTextStorage"];
    [coder encodeObject:_containers forKey:@"NSTextContainers"];
    [coder encodeInt:0x66 | (_allowsNonContiguous ? LM_ALLOWS_NONCONTIGUOUS : 0) forKey:@"NSLMFlags"];
    if (_delegate)
        [coder encodeConditionalObject:_delegate forKey:@"NSDelegate"];
}

#pragma mark Text storage and containers

- (NSTextStorage *)textStorage { return _textStorage; }

- (void)setTextStorage:(NSTextStorage *)textStorage
{
    _textStorage = textStorage;
    [_temporary release];
    _temporary = nil;
    [self invalidate];
}

/* From NSTextStorage's -addLayoutManager: and -removeLayoutManager:. */
- (void)_uifSetTextStorage:(NSTextStorage *)textStorage { self.textStorage = textStorage; }

- (void)replaceTextStorage:(NSTextStorage *)newTextStorage
{
    NSTextStorage *old = _textStorage;
    if (old == newTextStorage)
        return;
    [self retain];
    [old removeLayoutManager:self];
    [newTextStorage addLayoutManager:self];
    [self release];
}

- (NSArray *)textContainers { return [[_containers copy] autorelease]; }

- (void)addTextContainer:(NSTextContainer *)container
{
    [self insertTextContainer:container atIndex:_containers.count];
}

- (void)insertTextContainer:(NSTextContainer *)container atIndex:(NSUInteger)index
{
    if (!container)
        return;
    [_containers insertObject:container atIndex:MIN(index, _containers.count)];
    [container setLayoutManager:self];
    [self invalidate];
}

- (void)removeTextContainerAtIndex:(NSUInteger)index
{
    if (index >= _containers.count)
        return;
    [_containers[index] setLayoutManager:nil];
    [_containers removeObjectAtIndex:index];
    [self invalidate];
}

- (void)textContainerChangedGeometry:(NSTextContainer *)container { [self invalidate]; }
- (void)textContainerChangedTextView:(NSTextContainer *)container { }

- (id<NSLayoutManagerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSLayoutManagerDelegate>)delegate { _delegate = delegate; }

#pragma mark Settings

- (BOOL)showsInvisibleCharacters { return _showsInvisibles; }
- (void)setShowsInvisibleCharacters:(BOOL)v { _showsInvisibles = v; }
- (BOOL)showsControlCharacters { return _showsControls; }
- (void)setShowsControlCharacters:(BOOL)v { _showsControls = v; }
- (BOOL)usesDefaultHyphenation { return _usesDefaultHyphenation; }
- (void)setUsesDefaultHyphenation:(BOOL)v { _usesDefaultHyphenation = v; }
- (BOOL)usesFontLeading { return _usesFontLeading; }
- (void)setUsesFontLeading:(BOOL)v
{
    _usesFontLeading = v;
    [self invalidate];
}
- (BOOL)allowsNonContiguousLayout { return _allowsNonContiguous; }
- (void)setAllowsNonContiguousLayout:(BOOL)v { _allowsNonContiguous = v; }
- (BOOL)hasNonContiguousLayout { return NO; }
- (BOOL)limitsLayoutForSuspiciousContents { return _limitsSuspicious; }
- (void)setLimitsLayoutForSuspiciousContents:(BOOL)v { _limitsSuspicious = v; }
- (BOOL)backgroundLayoutEnabled { return _backgroundLayout; }
- (void)setBackgroundLayoutEnabled:(BOOL)v { _backgroundLayout = v; }
- (BOOL)usesScreenFonts { return _usesScreenFonts; }
- (void)setUsesScreenFonts:(BOOL)v { _usesScreenFonts = v; }
- (float)hyphenationFactor { return _hyphenationFactor; }
- (void)setHyphenationFactor:(float)v { _hyphenationFactor = v; }
- (NSTypesetterBehavior)typesetterBehavior { return _typesetterBehavior; }
- (void)setTypesetterBehavior:(NSTypesetterBehavior)v { _typesetterBehavior = v; }
- (NSImageScaling)defaultAttachmentScaling { return _attachmentScaling; }
- (void)setDefaultAttachmentScaling:(NSImageScaling)v { _attachmentScaling = v; }
- (NSTextLayoutOrientation)layoutOrientation { return NSTextLayoutOrientationHorizontal; }
- (NSFont *)substituteFontForFont:(NSFont *)originalFont { return originalFont; }

- (NSTextView *)firstTextView
{
    for (NSTextContainer *c in _containers)
        if (c.textView)
            return c.textView;
    return nil;
}

- (NSTextView *)textViewForBeginningOfSelection { return self.firstTextView; }
- (BOOL)layoutManagerOwnsFirstResponderInWindow:(NSWindow *)window { return NO; }

#pragma mark Invalidation

- (void)invalidate
{
    BOOL was = _valid;
    discard_layout(self);
    if (was) {
        id<NSLayoutManagerDelegate> d = _delegate;
        if ([d respondsToSelector:@selector(layoutManagerDidInvalidateLayout:)])
            [d layoutManagerDidInvalidateLayout:self];
    }
}

- (void)invalidateGlyphsForCharacterRange:(NSRange)charRange
                           changeInLength:(NSInteger)delta
                     actualCharacterRange:(NSRangePointer)actualCharRange
{
    if (actualCharRange)
        *actualCharRange = charRange;
    [self invalidate];
}

- (void)invalidateLayoutForCharacterRange:(NSRange)charRange actualCharacterRange:(NSRangePointer)actualCharRange
{
    if (actualCharRange)
        *actualCharRange = charRange;
    [self invalidate];
}

- (void)invalidateLayoutForCharacterRange:(NSRange)charRange isSoft:(BOOL)flag actualCharacterRange:(NSRangePointer)actualCharRange
{
    [self invalidateLayoutForCharacterRange:charRange actualCharacterRange:actualCharRange];
}

static void
redisplay(NSLayoutManager *self)
{
    for (NSTextContainer *c in self->_containers) {
        id tv = c.textView;
        if ([tv respondsToSelector:@selector(setNeedsDisplay:)])
            [tv setNeedsDisplay:YES];
    }
}

- (void)invalidateDisplayForCharacterRange:(NSRange)charRange { redisplay(self); }
- (void)invalidateDisplayForGlyphRange:(NSRange)glyphRange { redisplay(self); }
- (void)invalidateGlyphsOnLayoutInvalidationForGlyphRange:(NSRange)glyphRange { }

- (void)processEditingForTextStorage:(NSTextStorage *)textStorage
                              edited:(NSTextStorageEditActions)editMask
                               range:(NSRange)newCharRange
                      changeInLength:(NSInteger)delta
                    invalidatedRange:(NSRange)invalidatedCharRange
{
    if (_temporary && (editMask & NSTextStorageEditedCharacters)) {
        NSRange old = NSMakeRange(newCharRange.location, (NSUInteger)MAX((NSInteger)newCharRange.length - delta, 0));
        if (NSMaxRange(old) <= _temporary.length)
            [_temporary replaceCharactersInRange:old withString:[textStorage.string substringWithRange:newCharRange]];
        else {
            [_temporary release];
            _temporary = nil;
        }
    }
    [self invalidate];
    redisplay(self);
    /* Text views follow edits made to the storage (their selection, their size). */
    for (NSTextContainer *c in [[_containers copy] autorelease]) {
        id tv = c.textView;
        if ([tv respondsToSelector:@selector(_finchTextStorageEdited:range:changeInLength:)])
            [tv _finchTextStorageEdited:editMask range:newCharRange changeInLength:delta];
    }
}

- (void)textStorage:(NSTextStorage *)str
                edited:(NSTextStorageEditedOptions)editedMask
                 range:(NSRange)newCharRange
        changeInLength:(NSInteger)delta
      invalidatedRange:(NSRange)invalidatedCharRange
{
    [self processEditingForTextStorage:str edited:editedMask range:newCharRange changeInLength:delta
                      invalidatedRange:invalidatedCharRange];
}

#pragma mark Layout

/* Lay everything out, container by container. */
- (void)layout
{
    if (_valid)
        return;
    discard_layout(self);
    NSAttributedString *s = _textStorage ? _textStorage : [[[NSAttributedString alloc] init] autorelease];
    NSUInteger len = s.length;
    _layouts = calloc(_containers.count ? _containers.count : 1, sizeof *_layouts);
    NSUInteger start = 0;
    BOOL done = NO;
    for (NSTextContainer *c in _containers) {
        ContainerLayout *cl = &_layouts[_layoutCount++];
        cl->padding = c.lineFragmentPadding;
        cl->width = c.size.width;
        cl->range = NSMakeRange(start, 0);
        if (done)
            continue;
        UIFLayoutParams p = {MAX(c.size.width - 2 * cl->padding, 0), c.size.height,
                             NSStringDrawingUsesLineFragmentOrigin | (_usesFontLeading ? NSStringDrawingUsesFontLeading : 0),
                             start, YES, YES, c.maximumNumberOfLines, c.textView != nil};
        /* An empty text has the typing font: the end of the text's, or Helvetica 12. */
        NSDictionary *typing = len ? [s attributesAtIndex:len - 1 effectiveRange:NULL] : @{};
        if (!len && [c.textView respondsToSelector:@selector(typingAttributes)])
            typing = [(id)c.textView typingAttributes] ?: typing;
        cl->layout = UIFLayoutString(s, typing, p);
        if (!len && cl->layout.count) {
            cl->layout.lines[0].extra = YES;
            cl->layout.lines[0].range = NSMakeRange(0, 0);
        }
        cl->range = NSMakeRange(start, cl->layout.end - start);
        start = cl->layout.end;
        BOOL atEnd = start >= len && (cl->layout.count == 0 ? len == 0 : YES);
        if (start >= len) {
            /* The extra line fragment, if the text ends with a paragraph break, fits here. */
            BOOL needsExtra = len == 0 || [[NSCharacterSet newlineCharacterSet] characterIsMember:[s.string characterAtIndex:len - 1]];
            BOOL hasExtra = cl->layout.count && cl->layout.lines[cl->layout.count - 1].extra;
            done = !needsExtra || hasExtra;
        }
        id<NSLayoutManagerDelegate> d = _delegate;
        if ([d respondsToSelector:@selector(layoutManager:didCompleteLayoutForTextContainer:atEnd:)])
            [d layoutManager:self didCompleteLayoutForTextContainer:c atEnd:atEnd && done];
    }
    _valid = YES;
}

- (void)ensureGlyphsForCharacterRange:(NSRange)charRange { }
- (void)ensureGlyphsForGlyphRange:(NSRange)glyphRange { }
- (void)ensureLayoutForCharacterRange:(NSRange)charRange { [self layout]; }
- (void)ensureLayoutForGlyphRange:(NSRange)glyphRange { [self layout]; }
- (void)ensureLayoutForTextContainer:(NSTextContainer *)container { [self layout]; }
- (void)ensureLayoutForBoundingRect:(NSRect)bounds inTextContainer:(NSTextContainer *)container { [self layout]; }

- (void)getFirstUnlaidCharacterIndex:(NSUInteger *)charIndex glyphIndex:(NSUInteger *)glyphIndex
{
    NSUInteger i = self.firstUnlaidCharacterIndex;
    if (charIndex)
        *charIndex = i;
    if (glyphIndex)
        *glyphIndex = i;
}

- (NSUInteger)firstUnlaidCharacterIndex
{
    [self layout];
    NSUInteger end = 0;
    for (size_t i = 0; i < _layoutCount; i++)
        end = MAX(end, NSMaxRange(_layouts[i].range));
    return end;
}

- (NSUInteger)firstUnlaidGlyphIndex { return self.firstUnlaidCharacterIndex; }

static ContainerLayout *
layout_for(NSLayoutManager *self, NSTextContainer *container)
{
    [self layout];
    NSUInteger i = [self->_containers indexOfObjectIdenticalTo:container];
    return i != NSNotFound && i < self->_layoutCount ? &self->_layouts[i] : NULL;
}

/* The line holding a character (a final index finds the line it ends). */
static BOOL
find_line(NSLayoutManager *self, NSUInteger index, ContainerLayout **clOut, size_t *lineOut)
{
    [self layout];
    for (size_t c = 0; c < self->_layoutCount; c++) {
        ContainerLayout *cl = &self->_layouts[c];
        for (size_t i = 0; i < cl->layout.count; i++) {
            UIFLine *ln = &cl->layout.lines[i];
            if (ln->extra)
                continue;
            if (NSLocationInRange(index, ln->range) || (ln->range.length == 0 && index == ln->range.location)) {
                *clOut = cl;
                *lineOut = i;
                return YES;
            }
        }
    }
    return NO;
}

/* A line fragment's rectangle: the container's width, down to the next line. */
static NSRect
fragment_rect(ContainerLayout *cl, size_t i)
{
    UIFLine *ln = &cl->layout.lines[i];
    CGFloat h = ln->height + ln->spacingAfter;
    /* down to the next line, when it follows in the same column (a table's cells stand side by side) */
    if (i + 1 < cl->layout.count) {
        UIFLine *n = &cl->layout.lines[i + 1];
        if (n->top > ln->top && n->fragX == ln->fragX && n->fragWidth == ln->fragWidth)
            h = n->top - ln->top;
    }
    if (ln->fragWidth > 0)
        return NSMakeRect(ln->fragX, ln->top, ln->fragWidth + 2 * cl->padding, h);
    return NSMakeRect(0, ln->top, cl->width, h);
}

static NSRect
used_rect(ContainerLayout *cl, size_t i)
{
    UIFLine *ln = &cl->layout.lines[i];
    NSRect f = fragment_rect(cl, i);
    return NSMakeRect(ln->x, f.origin.y, ln->width + 2 * cl->padding, f.size.height);
}

/* The x of a character's start within its line (from the text's start): its
 * glyph's position, as TextKit places it (kerning moves the glyph, not the
 * caret between), or CoreText's caret inside a ligature. */
static CGFloat
offset_in_line(UIFLine *ln, NSUInteger index)
{
    if (!ln->line)
        return 0;
    CFRange lr = CTLineGetStringRange(ln->line);
    NSUInteger textEnd = ln->range.location + (NSUInteger)lr.length;
    if (index >= textEnd)
        return (CGFloat)CTLineGetTypographicBounds(ln->line, NULL, NULL, NULL);
    CFIndex i = lr.location + (CFIndex)(index - ln->range.location);
    CFArrayRef runs = CTLineGetGlyphRuns(ln->line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, r);
        CFRange rr = CTRunGetStringRange(run);
        if (i < rr.location || i >= rr.location + rr.length)
            continue;
        CFIndex n = CTRunGetGlyphCount(run);
        for (CFIndex g = 0; g < n; g++) {
            CFIndex si;
            CTRunGetStringIndices(run, CFRangeMake(g, 1), &si);
            if (si == i) {
                CGPoint p;
                CTRunGetPositions(run, CFRangeMake(g, 1), &p);
                return p.x;
            }
        }
        break;
    }
    return CTLineGetOffsetForStringIndex(ln->line, i, NULL);
}

- (NSTextContainer *)textContainerForGlyphAtIndex:(NSUInteger)glyphIndex effectiveRange:(NSRangePointer)effectiveGlyphRange
{
    [self layout];
    for (size_t c = 0; c < _layoutCount; c++)
        if (NSLocationInRange(glyphIndex, _layouts[c].range)) {
            if (effectiveGlyphRange)
                *effectiveGlyphRange = _layouts[c].range;
            return _containers[c];
        }
    return nil;
}

- (NSTextContainer *)textContainerForGlyphAtIndex:(NSUInteger)glyphIndex
                                   effectiveRange:(NSRangePointer)effectiveGlyphRange
                          withoutAdditionalLayout:(BOOL)flag
{
    return [self textContainerForGlyphAtIndex:glyphIndex effectiveRange:effectiveGlyphRange];
}

- (NSRange)glyphRangeForTextContainer:(NSTextContainer *)container
{
    ContainerLayout *cl = layout_for(self, container);
    return cl ? cl->range : NSMakeRange(NSNotFound, 0);
}

- (NSRect)usedRectForTextContainer:(NSTextContainer *)container
{
    ContainerLayout *cl = layout_for(self, container);
    if (!cl || !cl->layout.count)
        return NSZeroRect;
    NSRect r = NSZeroRect;
    for (size_t i = 0; i < cl->layout.count; i++) {
        NSRect u = used_rect(cl, i);
        if (cl->layout.lines[i].extra)
            u.size.width = 2 * cl->padding;
        r = i == 0 ? u : NSUnionRect(r, u);
    }
    return r;
}

- (NSRect)lineFragmentRectForGlyphAtIndex:(NSUInteger)glyphIndex effectiveRange:(NSRangePointer)effectiveGlyphRange
{
    ContainerLayout *cl;
    size_t i;
    if (!find_line(self, glyphIndex, &cl, &i)) {
        if (effectiveGlyphRange)
            *effectiveGlyphRange = NSMakeRange(NSNotFound, 0);
        return NSZeroRect;
    }
    if (effectiveGlyphRange)
        *effectiveGlyphRange = cl->layout.lines[i].range;
    return fragment_rect(cl, i);
}

- (NSRect)lineFragmentRectForGlyphAtIndex:(NSUInteger)glyphIndex
                           effectiveRange:(NSRangePointer)effectiveGlyphRange
                  withoutAdditionalLayout:(BOOL)flag
{
    return [self lineFragmentRectForGlyphAtIndex:glyphIndex effectiveRange:effectiveGlyphRange];
}

- (NSRect)lineFragmentUsedRectForGlyphAtIndex:(NSUInteger)glyphIndex effectiveRange:(NSRangePointer)effectiveGlyphRange
{
    ContainerLayout *cl;
    size_t i;
    if (!find_line(self, glyphIndex, &cl, &i)) {
        if (effectiveGlyphRange)
            *effectiveGlyphRange = NSMakeRange(NSNotFound, 0);
        return NSZeroRect;
    }
    if (effectiveGlyphRange)
        *effectiveGlyphRange = cl->layout.lines[i].range;
    return used_rect(cl, i);
}

- (NSRect)lineFragmentUsedRectForGlyphAtIndex:(NSUInteger)glyphIndex
                               effectiveRange:(NSRangePointer)effectiveGlyphRange
                      withoutAdditionalLayout:(BOOL)flag
{
    return [self lineFragmentUsedRectForGlyphAtIndex:glyphIndex effectiveRange:effectiveGlyphRange];
}

static BOOL
extra_line(NSLayoutManager *self, ContainerLayout **clOut, size_t *lineOut)
{
    [self layout];
    for (size_t c = 0; c < self->_layoutCount; c++) {
        ContainerLayout *cl = &self->_layouts[c];
        if (cl->layout.count && cl->layout.lines[cl->layout.count - 1].extra) {
            *clOut = cl;
            *lineOut = cl->layout.count - 1;
            return YES;
        }
    }
    return NO;
}

- (NSRect)extraLineFragmentRect
{
    ContainerLayout *cl;
    size_t i;
    return extra_line(self, &cl, &i) ? fragment_rect(cl, i) : NSZeroRect;
}

- (NSRect)extraLineFragmentUsedRect
{
    ContainerLayout *cl;
    size_t i;
    if (!extra_line(self, &cl, &i))
        return NSZeroRect;
    NSRect u = used_rect(cl, i);
    u.size.width = 2 * cl->padding;
    return u;
}

- (NSTextContainer *)extraLineFragmentTextContainer
{
    ContainerLayout *cl;
    size_t i;
    return extra_line(self, &cl, &i) ? _containers[(NSUInteger)(cl - _layouts)] : nil;
}

- (NSPoint)locationForGlyphAtIndex:(NSUInteger)glyphIndex
{
    ContainerLayout *cl;
    size_t i;
    if (!find_line(self, glyphIndex, &cl, &i))
        return NSZeroPoint;
    UIFLine *ln = &cl->layout.lines[i];
    return NSMakePoint(cl->padding + ln->x + offset_in_line(ln, glyphIndex), ln->baseline);
}

- (BOOL)notShownAttributeForGlyphAtIndex:(NSUInteger)glyphIndex
{
    unichar c = glyphIndex < _textStorage.length ? [_textStorage.string characterAtIndex:glyphIndex] : 0;
    return c == '\n' || c == '\r' || c == '\t' || c == 0x2028 || c == 0x2029;
}

- (BOOL)drawsOutsideLineFragmentForGlyphAtIndex:(NSUInteger)glyphIndex { return NO; }
- (NSSize)attachmentSizeForGlyphAtIndex:(NSUInteger)glyphIndex { return NSMakeSize(-1, -1); }
- (NSRange)truncatedGlyphRangeInLineFragmentForGlyphAtIndex:(NSUInteger)glyphIndex { return NSMakeRange(NSNotFound, 0); }

#pragma mark Glyphs (one per character)

- (NSUInteger)numberOfGlyphs { return _textStorage.length; }
- (BOOL)isValidGlyphIndex:(NSUInteger)glyphIndex { return glyphIndex < _textStorage.length; }

- (CGGlyph)CGGlyphAtIndex:(NSUInteger)glyphIndex isValidIndex:(BOOL *)isValidIndex
{
    BOOL valid = glyphIndex < _textStorage.length;
    if (isValidIndex)
        *isValidIndex = valid;
    if (!valid)
        return 0;
    NSFont *f = UIFFontIn([_textStorage attributesAtIndex:glyphIndex effectiveRange:NULL]);
    unichar c = [_textStorage.string characterAtIndex:glyphIndex];
    CGGlyph g = 0;
    CTFontGetGlyphsForCharacters((CTFontRef)f, &c, &g, 1);
    return g;
}

- (CGGlyph)CGGlyphAtIndex:(NSUInteger)glyphIndex { return [self CGGlyphAtIndex:glyphIndex isValidIndex:NULL]; }
- (NSGlyph)glyphAtIndex:(NSUInteger)glyphIndex isValidIndex:(BOOL *)isValidIndex
{
    return [self CGGlyphAtIndex:glyphIndex isValidIndex:isValidIndex];
}
- (NSGlyph)glyphAtIndex:(NSUInteger)glyphIndex { return [self CGGlyphAtIndex:glyphIndex isValidIndex:NULL]; }

- (NSGlyphProperty)propertyForGlyphAtIndex:(NSUInteger)glyphIndex
{
    return [self notShownAttributeForGlyphAtIndex:glyphIndex] ? NSGlyphPropertyControlCharacter : 0;
}

- (NSUInteger)characterIndexForGlyphAtIndex:(NSUInteger)glyphIndex { return glyphIndex; }
- (NSUInteger)glyphIndexForCharacterAtIndex:(NSUInteger)charIndex { return charIndex; }

- (NSRange)glyphRangeForCharacterRange:(NSRange)charRange actualCharacterRange:(NSRangePointer)actualCharRange
{
    if (actualCharRange)
        *actualCharRange = charRange;
    return charRange;
}

- (NSRange)characterRangeForGlyphRange:(NSRange)glyphRange actualGlyphRange:(NSRangePointer)actualGlyphRange
{
    if (actualGlyphRange)
        *actualGlyphRange = glyphRange;
    return glyphRange;
}

- (NSUInteger)getGlyphsInRange:(NSRange)glyphRange
                        glyphs:(CGGlyph *)glyphBuffer
                    properties:(NSGlyphProperty *)props
              characterIndexes:(NSUInteger *)charIndexBuffer
                    bidiLevels:(unsigned char *)bidiLevelBuffer
{
    NSUInteger n = 0;
    for (NSUInteger g = glyphRange.location; g < NSMaxRange(glyphRange) && g < _textStorage.length; g++, n++) {
        if (glyphBuffer)
            glyphBuffer[n] = [self CGGlyphAtIndex:g];
        if (props)
            props[n] = [self propertyForGlyphAtIndex:g];
        if (charIndexBuffer)
            charIndexBuffer[n] = g;
        if (bidiLevelBuffer)
            bidiLevelBuffer[n] = 0;
    }
    return n;
}

- (NSUInteger)getGlyphs:(NSGlyph *)glyphArray range:(NSRange)glyphRange
{
    NSUInteger n = 0;
    for (NSUInteger g = glyphRange.location; g < NSMaxRange(glyphRange) && g < _textStorage.length; g++)
        if (![self notShownAttributeForGlyphAtIndex:g])
            glyphArray[n++] = [self CGGlyphAtIndex:g];
    return n;
}

- (NSRange)rangeOfNominallySpacedGlyphsContainingIndex:(NSUInteger)glyphIndex
{
    NSRange r;
    [self lineFragmentRectForGlyphAtIndex:glyphIndex effectiveRange:&r];
    return r;
}

#pragma mark Geometry

/* The rectangle of the characters `range` covers in line `i`: from the
 * text's start if the range began on an earlier line, to the container's
 * right edge if it goes on to a later one. */
static NSRect
range_rect_in_line(ContainerLayout *cl, size_t i, NSRange range)
{
    UIFLine *ln = &cl->layout.lines[i];
    NSRect f = fragment_rect(cl, i);
    CGFloat x0 = range.location <= ln->range.location ? cl->padding
                                                       : cl->padding + ln->x + offset_in_line(ln, range.location);
    CGFloat x1 = NSMaxRange(range) > NSMaxRange(ln->range) ? cl->width - cl->padding
                                                           : cl->padding + ln->x + offset_in_line(ln, NSMaxRange(range));
    return NSMakeRect(x0, f.origin.y, MAX(x1 - x0, 0), f.size.height);
}

- (NSRect)boundingRectForGlyphRange:(NSRange)glyphRange inTextContainer:(NSTextContainer *)container
{
    ContainerLayout *cl = layout_for(self, container);
    if (!cl)
        return NSZeroRect;
    NSRect r = NSZeroRect;
    BOOL any = NO;
    /* An empty range: the insertion point there, zero wide (the extra line's at the very end). */
    if (!glyphRange.length) {
        NSUInteger loc = glyphRange.location;
        for (size_t i = 0; i < cl->layout.count; i++) {
            UIFLine *ln = &cl->layout.lines[i];
            BOOL last = i + 1 == cl->layout.count || cl->layout.lines[i + 1].extra;
            if (ln->extra ? loc == ln->range.location
                          : (NSLocationInRange(loc, ln->range) || (last && loc == NSMaxRange(ln->range)))) {
                NSRect f = fragment_rect(cl, i);
                CGFloat x = ln->extra ? cl->padding + ln->x : cl->padding + ln->x + offset_in_line(ln, loc);
                return NSMakeRect(x, f.origin.y, 0, f.size.height);
            }
        }
        return NSZeroRect;
    }
    for (size_t i = 0; i < cl->layout.count; i++) {
        UIFLine *ln = &cl->layout.lines[i];
        if (ln->extra || !NSIntersectionRange(ln->range, glyphRange).length)
            continue;
        NSRect lr = range_rect_in_line(cl, i, glyphRange);
        r = any ? NSUnionRect(r, lr) : lr;
        any = YES;
    }
    return r;
}

- (void)enumerateEnclosingRectsForGlyphRange:(NSRange)glyphRange
                    withinSelectedGlyphRange:(NSRange)selectedRange
                             inTextContainer:(NSTextContainer *)textContainer
                                  usingBlock:(void (^)(NSRect rect, BOOL *stop))block
{
    ContainerLayout *cl = layout_for(self, textContainer);
    if (!cl)
        return;
    BOOL stop = NO;
    for (size_t i = 0; i < cl->layout.count && !stop; i++) {
        UIFLine *ln = &cl->layout.lines[i];
        if (ln->extra)
            continue;
        if (glyphRange.length ? !NSIntersectionRange(ln->range, glyphRange).length
                              : !NSLocationInRange(glyphRange.location, ln->range))
            continue;
        block(range_rect_in_line(cl, i, glyphRange), &stop);
    }
}

- (NSRectArray)rectArrayForGlyphRange:(NSRange)glyphRange
             withinSelectedGlyphRange:(NSRange)selGlyphRange
                      inTextContainer:(NSTextContainer *)container
                            rectCount:(NSUInteger *)rectCount
{
    __block NSUInteger n = 0;
    [self enumerateEnclosingRectsForGlyphRange:glyphRange
                      withinSelectedGlyphRange:selGlyphRange
                               inTextContainer:container
                                    usingBlock:^(NSRect rect, BOOL *stop) {
                                      if (n == self->_rectCapacity) {
                                          self->_rectCapacity = self->_rectCapacity ? self->_rectCapacity * 2 : 8;
                                          self->_rectArray = realloc(self->_rectArray, self->_rectCapacity * sizeof(NSRect));
                                      }
                                      self->_rectArray[n++] = rect;
                                    }];
    if (rectCount)
        *rectCount = n;
    return n ? _rectArray : NULL;
}

- (NSRectArray)rectArrayForCharacterRange:(NSRange)charRange
             withinSelectedCharacterRange:(NSRange)selCharRange
                          inTextContainer:(NSTextContainer *)container
                                rectCount:(NSUInteger *)rectCount
{
    return [self rectArrayForGlyphRange:charRange withinSelectedGlyphRange:selCharRange inTextContainer:container
                              rectCount:rectCount];
}

- (NSRange)glyphRangeForBoundingRect:(NSRect)bounds inTextContainer:(NSTextContainer *)container
{
    ContainerLayout *cl = layout_for(self, container);
    if (!cl)
        return NSMakeRange(0, 0);
    NSRange r = NSMakeRange(NSNotFound, 0);
    for (size_t i = 0; i < cl->layout.count; i++) {
        UIFLine *ln = &cl->layout.lines[i];
        NSRect f = fragment_rect(cl, i);
        if (ln->extra || NSMaxY(f) <= NSMinY(bounds) || NSMinY(f) >= NSMaxY(bounds))
            continue;
        r = r.location == NSNotFound ? ln->range : NSUnionRange(r, ln->range);
    }
    return r.location == NSNotFound ? NSMakeRange(cl->range.location, 0) : r;
}

- (NSRange)glyphRangeForBoundingRectWithoutAdditionalLayout:(NSRect)bounds inTextContainer:(NSTextContainer *)container
{
    return [self glyphRangeForBoundingRect:bounds inTextContainer:container];
}

/* The glyph under a point (or nearest it), and how far through it the point is. */
static NSUInteger
glyph_at_point(NSLayoutManager *self, NSPoint point, NSTextContainer *container, CGFloat *fraction)
{
    if (fraction)
        *fraction = 0;
    ContainerLayout *cl = layout_for(self, container);
    if (!cl || !cl->layout.count)
        return 0;
    /* The line at that height, or the nearest one (a line in a table cell, if the point is in its fragment). */
    size_t pick = SIZE_MAX;
    for (size_t i = 0; i < cl->layout.count && cl->layout.blockCount; i++)
        if (!cl->layout.lines[i].extra && cl->layout.lines[i].fragWidth > 0 &&
            NSPointInRect(point, fragment_rect(cl, i))) {
            pick = i;
            break;
        }
    BOOL found = pick != SIZE_MAX;
    for (size_t i = 0; i < cl->layout.count && !found; i++) {
        if (cl->layout.lines[i].extra)
            continue;
        pick = i;
        if (point.y < NSMaxY(fragment_rect(cl, i)))
            break;
    }
    if (pick == SIZE_MAX)
        return self->_textStorage.length ? self->_textStorage.length - 1 : 0;
    UIFLine *ln = &cl->layout.lines[pick];
    CGFloat x = point.x - cl->padding - ln->x;
    NSUInteger first = ln->range.location, end = NSMaxRange(ln->range);
    if (end == first)
        return first;
    if (x <= 0)
        return first;
    for (NSUInteger c = first; c < end; c++) {
        CGFloat a = offset_in_line(ln, c), b = offset_in_line(ln, c + 1);
        if (x < b || c + 1 == end) {
            if (fraction)
                *fraction = b > a ? MIN(MAX((x - a) / (b - a), 0), 1) : 0;
            return c;
        }
    }
    return end - 1;
}

- (NSUInteger)glyphIndexForPoint:(NSPoint)point
                 inTextContainer:(NSTextContainer *)container
  fractionOfDistanceThroughGlyph:(CGFloat *)partialFraction
{
    return glyph_at_point(self, point, container, partialFraction);
}

- (NSUInteger)glyphIndexForPoint:(NSPoint)point inTextContainer:(NSTextContainer *)container
{
    return glyph_at_point(self, point, container, NULL);
}

- (CGFloat)fractionOfDistanceThroughGlyphForPoint:(NSPoint)point inTextContainer:(NSTextContainer *)container
{
    CGFloat f;
    glyph_at_point(self, point, container, &f);
    return f;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
                     inTextContainer:(NSTextContainer *)container
fractionOfDistanceBetweenInsertionPoints:(CGFloat *)partialFraction
{
    return glyph_at_point(self, point, container, partialFraction);
}

- (NSUInteger)getLineFragmentInsertionPointsForCharacterAtIndex:(NSUInteger)charIndex
                                             alternatePositions:(BOOL)aFlag
                                                 inDisplayOrder:(BOOL)dFlag
                                                      positions:(CGFloat *)positions
                                               characterIndexes:(NSUInteger *)charIndexes
{
    ContainerLayout *cl;
    size_t i;
    if (!find_line(self, charIndex, &cl, &i))
        return 0;
    UIFLine *ln = &cl->layout.lines[i];
    NSUInteger textLen = ln->line ? (NSUInteger)CTLineGetStringRange(ln->line).length : 0;
    NSUInteger n = 0;
    for (NSUInteger c = ln->range.location; c <= ln->range.location + textLen; c++, n++) {
        if (positions)
            positions[n] = cl->padding + ln->x + offset_in_line(ln, c);
        if (charIndexes)
            charIndexes[n] = c;
    }
    return n;
}

- (void)enumerateLineFragmentsForGlyphRange:(NSRange)glyphRange
                                 usingBlock:(void (^)(NSRect rect, NSRect usedRect, NSTextContainer *textContainer,
                                                      NSRange glyphRange, BOOL *stop))block
{
    [self layout];
    BOOL stop = NO;
    for (size_t c = 0; c < _layoutCount && !stop; c++) {
        ContainerLayout *cl = &_layouts[c];
        for (size_t i = 0; i < cl->layout.count && !stop; i++) {
            UIFLine *ln = &cl->layout.lines[i];
            if (ln->extra)
                continue;
            if (!NSIntersectionRange(ln->range, glyphRange).length &&
                !(glyphRange.length == 0 && NSLocationInRange(glyphRange.location, ln->range)))
                continue;
            block(fragment_rect(cl, i), used_rect(cl, i), _containers[c], ln->range, &stop);
        }
    }
}

- (CGFloat)defaultLineHeightForFont:(NSFont *)font
{
    return round(font.ascender) + round(-font.descender) + (_usesFontLeading ? round(font.leading) : 0);
}

- (CGFloat)defaultBaselineOffsetForFont:(NSFont *)font { return round(font.ascender); }

#pragma mark Drawing

/* Draw the lines holding these glyphs, with their container's origin at
 * `origin` (TextKit draws in flipped coordinates, as NSTextView is). */
- (void)drawGlyphsForGlyphRange:(NSRange)glyphsToShow atPoint:(NSPoint)origin
{
    [self layout];
    BOOL flipped = UIFCurrentContextIsFlipped();
    for (size_t c = 0; c < _layoutCount; c++) {
        ContainerLayout *cl = &_layouts[c];
        size_t first = SIZE_MAX, last = 0;
        for (size_t i = 0; i < cl->layout.count; i++) {
            UIFLine *ln = &cl->layout.lines[i];
            if (ln->extra || !NSIntersectionRange(ln->range, glyphsToShow).length)
                continue;
            first = MIN(first, i);
            last = i;
        }
        if (first == SIZE_MAX)
            continue;
        UIFLayoutDrawLines(&cl->layout, first, last - first + 1, origin.x + cl->padding, origin.y, flipped);
    }
}

/* Text blocks' backgrounds and borders; text backgrounds are drawn with the glyphs. */
- (void)drawBackgroundForGlyphRange:(NSRange)glyphsToShow atPoint:(NSPoint)origin
{
    [self layout];
    for (size_t c = 0; c < _layoutCount; c++)
        if (_layouts[c].layout.blockCount)
            UIFLayoutDrawBlocks(&_layouts[c].layout, glyphsToShow, origin.x + _layouts[c].padding, origin.y, self);
}

#pragma mark Text blocks

static UIFBlockFrame *
block_frame(NSLayoutManager *self, NSTextBlock *block, NSRange range, ContainerLayout **clOut)
{
    [self layout];
    for (size_t c = 0; c < self->_layoutCount; c++) {
        ContainerLayout *cl = &self->_layouts[c];
        for (size_t i = 0; i < cl->layout.blockCount; i++) {
            UIFBlockFrame *b = &cl->layout.blocks[i];
            if (b->block == block && (NSLocationInRange(range.location, b->range) || NSEqualRanges(range, b->range))) {
                if (clOut)
                    *clOut = cl;
                return b;
            }
        }
    }
    return NULL;
}

- (NSRect)layoutRectForTextBlock:(NSTextBlock *)block glyphRange:(NSRange)glyphRange
{
    ContainerLayout *cl;
    UIFBlockFrame *b = block_frame(self, block, glyphRange, &cl);
    return b ? NSOffsetRect(NSRectFromCGRect(b->content), cl->padding, 0) : NSZeroRect;
}

- (NSRect)boundsRectForTextBlock:(NSTextBlock *)block glyphRange:(NSRange)glyphRange
{
    ContainerLayout *cl;
    UIFBlockFrame *b = block_frame(self, block, glyphRange, &cl);
    return b ? NSOffsetRect(NSRectFromCGRect(b->frame), cl->padding, 0) : NSZeroRect;
}

- (NSRect)layoutRectForTextBlock:(NSTextBlock *)block atIndex:(NSUInteger)glyphIndex effectiveRange:(NSRangePointer)r
{
    ContainerLayout *cl;
    UIFBlockFrame *b = block_frame(self, block, NSMakeRange(glyphIndex, 0), &cl);
    if (r)
        *r = b ? b->range : NSMakeRange(NSNotFound, 0);
    return b ? NSOffsetRect(NSRectFromCGRect(b->content), cl->padding, 0) : NSZeroRect;
}

- (NSRect)boundsRectForTextBlock:(NSTextBlock *)block atIndex:(NSUInteger)glyphIndex effectiveRange:(NSRangePointer)r
{
    ContainerLayout *cl;
    UIFBlockFrame *b = block_frame(self, block, NSMakeRange(glyphIndex, 0), &cl);
    if (r)
        *r = b ? b->range : NSMakeRange(NSNotFound, 0);
    return b ? NSOffsetRect(NSRectFromCGRect(b->frame), cl->padding, 0) : NSZeroRect;
}

/* Layout places blocks itself. */
- (void)setLayoutRect:(NSRect)rect forTextBlock:(NSTextBlock *)block glyphRange:(NSRange)glyphRange {}
- (void)setBoundsRect:(NSRect)rect forTextBlock:(NSTextBlock *)block glyphRange:(NSRange)glyphRange {}

- (void)fillBackgroundRectArray:(const NSRect *)rectArray
                          count:(NSUInteger)rectCount
              forCharacterRange:(NSRange)charRange
                          color:(NSColor *)color
{
    CGContextRef cg = UIFCurrentCGContext();
    CGColorRef c = UIFCGColor(color);
    if (!cg || !c)
        return;
    CGContextSaveGState(cg);
    CGContextSetFillColorWithColor(cg, c);
    CGContextFillRects(cg, (const CGRect *)rectArray, rectCount);
    CGContextRestoreGState(cg);
}

- (void)showCGGlyphs:(const CGGlyph *)glyphs
           positions:(const CGPoint *)positions
               count:(NSInteger)glyphCount
                font:(NSFont *)font
          textMatrix:(CGAffineTransform)textMatrix
          attributes:(NSDictionary *)attributes
           inContext:(CGContextRef)CGContext
{
    if (!CGContext || glyphCount <= 0)
        return;
    CGContextSaveGState(CGContext);
    CGColorRef fg = UIFCGColor(attributes[NSForegroundColorAttributeName]);
    if (fg)
        CGContextSetFillColorWithColor(CGContext, fg);
    CGContextSetTextMatrix(CGContext, textMatrix);
    CTFontDrawGlyphs((CTFontRef)font, glyphs, positions, (size_t)glyphCount, CGContext);
    CGContextRestoreGState(CGContext);
}

#pragma mark Temporary attributes

static NSMutableAttributedString *
temporary(NSLayoutManager *self)
{
    if (!self->_temporary)
        self->_temporary = [[NSMutableAttributedString alloc] initWithString:self->_textStorage.string ? self->_textStorage.string : @""];
    return self->_temporary;
}

static NSRange
clamp(NSLayoutManager *self, NSRange r)
{
    NSUInteger len = temporary(self).length;
    NSUInteger loc = MIN(r.location, len);
    return NSMakeRange(loc, MIN(r.length, len - loc));
}

- (NSDictionary *)temporaryAttributesAtCharacterIndex:(NSUInteger)charIndex effectiveRange:(NSRangePointer)range
{
    NSMutableAttributedString *t = temporary(self);
    if (charIndex >= t.length) {
        if (range)
            *range = NSMakeRange(charIndex, 0);
        return @{};
    }
    return [t attributesAtIndex:charIndex effectiveRange:range];
}

- (void)setTemporaryAttributes:(NSDictionary *)attrs forCharacterRange:(NSRange)charRange
{
    [temporary(self) setAttributes:attrs range:clamp(self, charRange)];
    redisplay(self);
}

- (void)addTemporaryAttributes:(NSDictionary *)attrs forCharacterRange:(NSRange)charRange
{
    [temporary(self) addAttributes:attrs range:clamp(self, charRange)];
    redisplay(self);
}

- (void)addTemporaryAttribute:(NSAttributedStringKey)attrName value:(id)value forCharacterRange:(NSRange)charRange
{
    [temporary(self) addAttribute:attrName value:value range:clamp(self, charRange)];
    redisplay(self);
}

- (void)removeTemporaryAttribute:(NSAttributedStringKey)attrName forCharacterRange:(NSRange)charRange
{
    [temporary(self) removeAttribute:attrName range:clamp(self, charRange)];
    redisplay(self);
}

- (id)temporaryAttribute:(NSAttributedStringKey)attrName atCharacterIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range
{
    return [self temporaryAttributesAtCharacterIndex:location effectiveRange:range][attrName];
}

- (id)temporaryAttribute:(NSAttributedStringKey)attrName
        atCharacterIndex:(NSUInteger)location
   longestEffectiveRange:(NSRangePointer)range
                 inRange:(NSRange)rangeLimit
{
    NSMutableAttributedString *t = temporary(self);
    if (location >= t.length)
        return nil;
    return [t attribute:attrName atIndex:location longestEffectiveRange:range inRange:clamp(self, rangeLimit)];
}

- (NSDictionary *)temporaryAttributesAtCharacterIndex:(NSUInteger)location
                                longestEffectiveRange:(NSRangePointer)range
                                              inRange:(NSRange)rangeLimit
{
    NSMutableAttributedString *t = temporary(self);
    if (location >= t.length)
        return @{};
    return [t attributesAtIndex:location longestEffectiveRange:range inRange:clamp(self, rangeLimit)];
}

#pragma mark TextKit 2's layout

/*
 * NSTextLayoutManager lays text out with a layout manager of its own that no
 * one else sees (UIFTextKit2.h): it holds the text storage without being one
 * of its layout managers, and the container without being the container's
 * layout manager, so TextKit 1 and 2 lay out alike.
 */
- (void)_uifBecomeEngineWithTextContainer:(NSTextContainer *)container
{
    _engine = YES;
    if (_containers.count == 1 && _containers[0] == container)
        return;
    [_containers removeAllObjects];
    if (container)
        [_containers addObject:container];
    [self invalidate];
}

UIFLayout *
UIFLayoutManagerLayout(NSLayoutManager *lm, NSTextContainer *container, CGFloat *padding, CGFloat *width)
{
    ContainerLayout *cl = lm ? layout_for(lm, container) : NULL;
    if (!cl)
        return NULL;
    if (padding)
        *padding = cl->padding;
    if (width)
        *width = cl->width;
    return &cl->layout;
}

NSUInteger
UIFLayoutManagerGeneration(NSLayoutManager *lm)
{
    return lm ? lm->_generation : 0;
}

CGFloat
UIFLineOffset(UIFLine *ln, NSUInteger index)
{
    return offset_in_line(ln, index);
}

@end
