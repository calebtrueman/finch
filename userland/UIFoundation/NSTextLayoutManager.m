/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * TextKit 2's layout: NSTextLayoutManager, NSTextLayoutFragment,
 * NSTextLineFragment and NSTextViewportLayoutController.
 *
 * The text is laid out by a layout engine, an NSLayoutManager of the layout
 * manager's own (UIFTextKit2.h), with UIFoundation's one layout
 * (UIFTextLayout.m), so TextKit 1 and 2 place every line alike. A layout
 * fragment is a paragraph's lines (one per element of the content manager);
 * as Apple's (macOS 26, measured):
 * - Its frame starts at the line fragment padding plus its leftmost line's
 *   start, and is as wide as its lines' used widths without the padding. It
 *   runs down to the next fragment, which starts after the paragraph spacing
 *   but before the line spacing that follows a paragraph's last line.
 * - A final paragraph separator's empty last line (TextKit 1's extra line
 *   fragment) is the last fragment's last line; an empty text has no
 *   fragments.
 * - Line fragments share their paragraph's attributed string; their
 *   character ranges are in it, their typographic bounds in the fragment,
 *   their glyph origin at the baseline. Line fragments made on their own
 *   aren't laid out (zero bounds), as Apple's.
 * - The rendering surface is the glyphs' font bounding boxes, rounded out.
 * - Drawing assumes a flipped context (y down), whatever the context's own.
 * - Fragments are made when first enumerated (asking the delegate), kept
 *   with their element, and report LayoutAvailable once laid out by
 *   -ensureLayoutFor..., enumeration with EnsuresLayout, or the viewport.
 */
#import "UIFTextKit2.h"
#import <objc/runtime.h>

@interface NSTextLineFragment () {
@public
    NSAttributedString *_string;
    NSRange _range;
    CGRect _bounds;
    CGPoint _origin;
    UIFLine _line; /* a copy of the engine's line, at (0, 0), with the range in _string */
    BOOL _laidOut;
}
@end

@interface NSTextLayoutFragment () {
@public
    __weak NSTextLayoutManager *_tlm;
    __weak NSTextElement *_element;
    NSTextRange *_range;
    BOOL _wholeElement; /* _range was the element's: follow the element's range */
    NSTextLayoutFragmentState _state;
    NSOperationQueue *_queue;
    /* Geometry, for the engine's layout generation _gen. */
    NSUInteger _gen;
    BOOL _cached;
    CGRect _frame, _rsb;
    NSArray *_lines;
}
@end

#pragma mark - NSTextLineFragment

@implementation NSTextLineFragment

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString range:(NSRange)range
{
    if ((self = [super init])) {
        _string = [attributedString copy];
        _range = range;
    }
    return self;
}

- (instancetype)initWithString:(NSString *)string attributes:(NSDictionary *)attributes range:(NSRange)range
{
    NSAttributedString *s = [[NSAttributedString alloc] initWithString:string ? string : @"" attributes:attributes];
    self = [self initWithAttributedString:s range:range];
    [s release];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSAttributedString *s = [coder decodeObjectForKey:@"NS.attributedString"];
    NSRange r = NSMakeRange((NSUInteger)[coder decodeIntegerForKey:@"NS.location"], (NSUInteger)[coder decodeIntegerForKey:@"NS.length"]);
    return [self initWithAttributedString:[s isKindOfClass:[NSAttributedString class]] ? s : nil range:r];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_string forKey:@"NS.attributedString"];
    [coder encodeInteger:(NSInteger)_range.location forKey:@"NS.location"];
    [coder encodeInteger:(NSInteger)_range.length forKey:@"NS.length"];
}

- (void)dealloc
{
    if (_line.line)
        CFRelease(_line.line);
    [_string release];
    [super dealloc];
}

- (NSAttributedString *)attributedString { return _string; }
- (NSRange)characterRange { return _range; }
- (CGRect)typographicBounds { return _bounds; }
- (CGPoint)glyphOrigin { return _origin; }

- (void)drawAtPoint:(CGPoint)point inContext:(CGContextRef)context
{
    if (!_laidOut || !_line.line || !context)
        return;
    UIFLayout L = {&_line, 1, 1, _line.height, NSMaxRange(_line.range), NO};
    UIFLayoutDrawLinesInContext(context, &L, 0, 1, point.x, point.y, YES);
}

/* The end of the line's characters, before a paragraph separator. */
static NSUInteger
content_end(NSTextLineFragment *self)
{
    NSUInteger end = NSMaxRange(self->_range);
    NSString *s = self->_string.string;
    if (end > self->_range.location && end <= s.length) {
        unichar c = [s characterAtIndex:end - 1];
        if (c == '\n' || c == '\r' || c == 0x2029) {
            end--;
            if (c == '\n' && end > self->_range.location && [s characterAtIndex:end - 1] == '\r')
                end--;
        }
    }
    return end;
}

- (CGPoint)locationForCharacterAtIndex:(NSInteger)index
{
    if (!_laidOut)
        return CGPointZero;
    NSUInteger i = (NSUInteger)MAX(index, (NSInteger)_range.location);
    return CGPointMake(UIFLineOffset(&_line, MIN(i, NSMaxRange(_range))), _origin.y);
}

/* The character under the point (its end past the line's end). */
- (NSInteger)characterIndexForPoint:(CGPoint)point
{
    if (!_laidOut || !_line.line)
        return (NSInteger)_range.location;
    NSUInteger end = content_end(self), at = _range.location;
    for (NSUInteger i = _range.location; i <= end; i++)
        if (point.x >= UIFLineOffset(&_line, i))
            at = i;
    return (NSInteger)at;
}

- (CGFloat)fractionOfDistanceThroughGlyphForPoint:(CGPoint)point
{
    if (!_laidOut || !_line.line)
        return 0;
    NSUInteger end = content_end(self);
    for (NSUInteger i = _range.location; i < end; i++) {
        CGFloat a = UIFLineOffset(&_line, i), b = UIFLineOffset(&_line, i + 1);
        if (point.x < b)
            return b > a ? MIN(MAX((point.x - a) / (b - a), 0), 1) : 0;
    }
    return 0;
}

- (NSString *)description
{
    NSString *s = NSMaxRange(_range) <= _string.length ? [_string.string substringWithRange:_range] : @"";
    return [NSString stringWithFormat:@"<NSTextLineFragment: %p \"%@\">", self, s];
}

@end

#pragma mark - NSTextLayoutManager

@implementation NSTextLayoutManager {
    __weak NSTextContentManager *_tcm;
    NSTextContainer *_container;
    __weak id<NSTextLayoutManagerDelegate> _delegate;
    NSLayoutManager *_engine;
    NSTextStorage *_builtStorage; /* a content manager's text, when it isn't a text storage's */
    NSTextViewportLayoutController *_viewport;
    NSTextSelectionNavigation *_navigation;
    NSArray *_selections;
    NSMutableAttributedString *_rendering;
    id _validator;
    NSOperationQueue *_queue;
    BOOL _usesFontLeading, _limits, _hyphenation, _resolvesNatural, _laidOut;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _usesFontLeading = YES;
        _resolvesNatural = YES;
        _navigation = [[NSTextSelectionNavigation alloc] initWithDataSource:self];
    }
    return self;
}

- (void)dealloc
{
    if (_container.textLayoutManager == self)
        [_container _uifSetTextLayoutManager:nil];
    [_container release];
    [_engine release];
    [_builtStorage release];
    [_viewport release];
    [_navigation release];
    [_selections release];
    [_rendering release];
    [_validator release];
    [_queue release];
    [super dealloc];
}

#pragma mark The layout engine

static NSTextStorage *
storage(NSTextLayoutManager *self)
{
    NSTextContentManager *tcm = self->_tcm;
    if (!tcm)
        return nil;
    if ([tcm isKindOfClass:[NSTextContentStorage class]])
        return [tcm _uifTextStorage];
    if (!self->_builtStorage)
        self->_builtStorage = [[tcm _uifTextStorage] retain];
    return self->_builtStorage;
}

static NSLayoutManager *
engine(NSTextLayoutManager *self)
{
    if (!self->_engine)
        self->_engine = [[NSLayoutManager alloc] init];
    NSLayoutManager *e = self->_engine;
    [e _uifBecomeEngineWithTextContainer:self->_container];
    NSTextStorage *ts = storage(self);
    if (e.textStorage != ts)
        [e _uifSetTextStorage:ts];
    if (e.usesFontLeading != self->_usesFontLeading)
        e.usesFontLeading = self->_usesFontLeading;
    return e;
}

- (NSLayoutManager *)_uifLayoutEngine { return engine(self); }
- (NSLayoutManager *)_uifEngineIfAny { return _engine; }
- (NSString *)_uifString { return storage(self).string ?: @""; }

/* The engine's lines, with the padding and the container's width. */
static UIFLayout *
lines(NSTextLayoutManager *self, CGFloat *padding, CGFloat *width)
{
    if (!self->_container)
        return NULL;
    return UIFLayoutManagerLayout(engine(self), self->_container, padding, width);
}

static NSInteger
offset_of(NSTextLayoutManager *self, id<NSTextLocation> location)
{
    return UIFOffsetOf(self->_tcm, location);
}

static id<NSTextLocation>
location_at(NSTextLayoutManager *self, NSInteger offset)
{
    return UIFLocationAt(self->_tcm, offset);
}

static NSUInteger
text_length(NSTextLayoutManager *self)
{
    return storage(self).length;
}

- (void)_uifSetTextContentManager:(NSTextContentManager *)tcm
{
    _tcm = tcm;
    [_builtStorage release];
    _builtStorage = nil;
    if (_engine)
        [_engine _uifSetTextStorage:storage(self)];
    [_rendering release];
    _rendering = nil;
}

- (void)_uifTextStorageReplaced
{
    [_builtStorage release];
    _builtStorage = nil;
    [_rendering release];
    _rendering = nil;
    if (_engine) {
        [_engine _uifSetTextStorage:storage(self)];
        [_engine invalidate];
    }
}

- (void)_uifProcessEditing:(NSTextStorageEditActions)mask range:(NSRange)range changeInLength:(NSInteger)delta
{
    if (_rendering && (mask & NSTextStorageEditedCharacters)) {
        NSRange old = NSMakeRange(range.location, (NSUInteger)MAX((NSInteger)range.length - delta, 0));
        NSString *now = storage(self).string;
        if (NSMaxRange(old) <= _rendering.length && NSMaxRange(range) <= now.length)
            [_rendering replaceCharactersInRange:old withString:[now substringWithRange:range]];
        else {
            [_rendering release];
            _rendering = nil;
        }
    }
    if (!_engine)
        return;
    NSTextStorage *ts = storage(self);
    if (_engine.textStorage != ts)
        [_engine _uifSetTextStorage:ts];
    [_engine processEditingForTextStorage:ts edited:mask range:range changeInLength:delta invalidatedRange:range];
}

- (void)_uifTextContainerChanged { [_engine invalidate]; }

#pragma mark Properties

- (id<NSTextLayoutManagerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSTextLayoutManagerDelegate>)delegate { _delegate = delegate; }
- (BOOL)usesFontLeading { return _usesFontLeading; }
- (void)setUsesFontLeading:(BOOL)v
{
    _usesFontLeading = v;
    if (_engine)
        _engine.usesFontLeading = v;
}
- (BOOL)limitsLayoutForSuspiciousContents { return _limits; }
- (void)setLimitsLayoutForSuspiciousContents:(BOOL)v { _limits = v; }
- (BOOL)usesHyphenation { return _hyphenation; }
- (void)setUsesHyphenation:(BOOL)v { _hyphenation = v; }
- (BOOL)resolvesNaturalAlignmentWithBaseWritingDirection { return _resolvesNatural; }
- (void)setResolvesNaturalAlignmentWithBaseWritingDirection:(BOOL)v { _resolvesNatural = v; }
- (NSTextContentManager *)textContentManager { return _tcm; }
- (NSOperationQueue *)layoutQueue { return _queue; }
- (void)setLayoutQueue:(NSOperationQueue *)q
{
    [q retain];
    [_queue release];
    _queue = q;
}

- (void)replaceTextContentManager:(NSTextContentManager *)textContentManager
{
    NSTextContentManager *old = _tcm;
    if (old == textContentManager)
        return;
    NSArray *all = old ? old.textLayoutManagers : @[ self ];
    for (NSTextLayoutManager *tlm in all) {
        [old removeTextLayoutManager:tlm];
        [textContentManager addTextLayoutManager:tlm];
    }
}

- (NSTextContainer *)textContainer { return _container; }

- (void)setTextContainer:(NSTextContainer *)container
{
    if (container == _container)
        return;
    if (_container.textLayoutManager == self)
        [_container _uifSetTextLayoutManager:nil];
    NSTextLayoutManager *owner = container.textLayoutManager;
    if (owner && owner != self)
        owner.textContainer = nil;
    [container retain];
    [_container release];
    _container = container;
    [container _uifSetTextLayoutManager:self];
    if (container && !_viewport)
        _viewport = [[NSTextViewportLayoutController alloc] initWithTextLayoutManager:self];
    if (_engine)
        [_engine _uifBecomeEngineWithTextContainer:container];
}

- (NSTextViewportLayoutController *)textViewportLayoutController { return _viewport; }
- (NSArray *)textSelections { return _selections; }
- (void)setTextSelections:(NSArray *)selections
{
    NSArray *old = _selections;
    _selections = [selections copy];
    [old release];
}
- (NSTextSelectionNavigation *)textSelectionNavigation { return _navigation; }
- (void)setTextSelectionNavigation:(NSTextSelectionNavigation *)navigation
{
    [navigation retain];
    [_navigation release];
    _navigation = navigation;
}

#pragma mark Fragments

/* The layout fragment of an element, made when first asked for (by the delegate,
 * or as an NSTextLayoutFragment) and kept with the element (keyed by this
 * layout manager), so it goes when the content manager lets the element go. */
static NSTextLayoutFragment *
fragment_for(NSTextLayoutManager *self, NSTextElement *element)
{
    NSTextLayoutFragment *f = objc_getAssociatedObject(element, (const void *)self);
    if (f && f->_tlm == self)
        return f;
    id<NSTextLayoutManagerDelegate> d = self->_delegate;
    if ([d respondsToSelector:@selector(textLayoutManager:textLayoutFragmentForLocation:inTextElement:)])
        f = [d textLayoutManager:self textLayoutFragmentForLocation:element.elementRange.location inTextElement:element];
    if (!f)
        f = [[[NSTextLayoutFragment alloc] initWithTextElement:element range:element.elementRange] autorelease];
    f->_tlm = self;
    objc_setAssociatedObject(element, (const void *)self, f, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return f;
}

- (id<NSTextLocation>)enumerateTextLayoutFragmentsFromLocation:(id<NSTextLocation>)location
                                                       options:(NSTextLayoutFragmentEnumerationOptions)options
                                                    usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextLayoutFragment *))block
{
    NSTextContentManager *tcm = _tcm;
    if (!tcm)
        return nil;
    BOOL reverse = (options & NSTextLayoutFragmentEnumerationOptionsReverse) != 0;
    BOOL ensure = (options & NSTextLayoutFragmentEnumerationOptionsEnsuresLayout) != 0;
    if (ensure)
        _laidOut = YES;
    return [tcm enumerateTextElementsFromLocation:location
                                          options:reverse ? NSTextContentManagerEnumerationOptionsReverse : 0
                                       usingBlock:^BOOL(NSTextElement *element) {
                                         NSTextLayoutFragment *f = fragment_for(self, element);
                                         if (ensure)
                                             f->_state = NSTextLayoutFragmentStateLayoutAvailable;
                                         return block(f);
                                       }];
}

- (NSTextLayoutFragment *)textLayoutFragmentForLocation:(id<NSTextLocation>)location
{
    NSInteger at = offset_of(self, location);
    if (at == NSNotFound || at < 0 || (NSUInteger)at >= text_length(self))
        return nil;
    __block NSTextLayoutFragment *found = nil;
    [self enumerateTextLayoutFragmentsFromLocation:location
                                           options:0
                                        usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                          found = f;
                                          return NO;
                                        }];
    return found;
}

- (NSTextLayoutFragment *)textLayoutFragmentForPosition:(CGPoint)position
{
    __block NSTextLayoutFragment *found = nil;
    [self enumerateTextLayoutFragmentsFromLocation:nil
                                           options:0
                                        usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                          if (position.y < CGRectGetMaxY(f.layoutFragmentFrame)) {
                                              found = f;
                                              return NO;
                                          }
                                          return YES;
                                        }];
    return found;
}

- (void)ensureLayoutForRange:(NSTextRange *)range
{
    _laidOut = YES;
    NSInteger end = offset_of(self, range.endLocation);
    BOOL empty = range.isEmpty;
    [self enumerateTextLayoutFragmentsFromLocation:range.location
                                           options:0
                                        usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                          f->_state = NSTextLayoutFragmentStateLayoutAvailable;
                                          return !empty && offset_of(self, f.rangeInElement.endLocation) < end;
                                        }];
}

- (void)ensureLayoutForBounds:(CGRect)bounds
{
    _laidOut = YES;
    [self enumerateTextLayoutFragmentsFromLocation:nil
                                           options:0
                                        usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                          CGRect r = f.layoutFragmentFrame;
                                          if (CGRectGetMinY(r) >= CGRectGetMaxY(bounds))
                                              return NO;
                                          if (CGRectGetMaxY(r) > CGRectGetMinY(bounds))
                                              f->_state = NSTextLayoutFragmentStateLayoutAvailable;
                                          return YES;
                                        }];
}

- (void)invalidateLayoutForRange:(NSTextRange *)range
{
    [_engine invalidate];
    NSInteger a = offset_of(self, range.location), b = offset_of(self, range.endLocation);
    [self enumerateTextLayoutFragmentsFromLocation:range.location
                                           options:0
                                        usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                          NSInteger fa = offset_of(self, f.rangeInElement.location);
                                          if (fa >= b && b > a)
                                              return NO;
                                          f->_state = NSTextLayoutFragmentStateNone;
                                          return b > a;
                                        }];
}

- (CGRect)usageBoundsForTextContainer
{
    if (!_laidOut)
        return CGRectZero;
    CGFloat pad;
    UIFLayout *L = lines(self, &pad, NULL);
    if (!L || !L->count)
        return CGRectZero;
    CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX;
    for (size_t i = 0; i < L->count; i++) {
        UIFLine *ln = &L->lines[i];
        if (ln->extra && L->count > 1)
            continue;
        minX = MIN(minX, ln->x);
        maxX = MAX(maxX, ln->x + ln->width);
    }
    UIFLine *lastLine = &L->lines[L->count - 1];
    return CGRectMake(pad + minX, 0, maxX - minX, lastLine->top + lastLine->height);
}

#pragma mark Text segments

static BOOL
ends_paragraph(NSString *s, UIFLine *ln)
{
    NSUInteger e = NSMaxRange(ln->range);
    if (!ln->range.length || e > s.length)
        return NO;
    unichar c = [s characterAtIndex:e - 1];
    return c == '\n' || c == '\r' || c == 0x2029 || c == 0x85;
}

/* The line an insertion point at `at` is drawn on: the line holding it, or
 * (upstream, or at a text's end without a final separator) the line it ends. */
static UIFLine *
caret_line(UIFLayout *L, NSString *s, NSUInteger at, BOOL upstream)
{
    UIFLine *found = NULL, *lastText = NULL;
    for (size_t i = 0; i < L->count; i++) {
        UIFLine *ln = &L->lines[i];
        if (ln->extra) {
            if (at == ln->range.location)
                found = ln;
            continue;
        }
        lastText = ln;
        if (NSLocationInRange(at, ln->range)) {
            found = ln;
            if (upstream && i > 0 && at == ln->range.location && !L->lines[i - 1].extra &&
                NSMaxRange(L->lines[i - 1].range) == at && !ends_paragraph(s, &L->lines[i - 1]))
                found = &L->lines[i - 1];
            break;
        }
    }
    if (!found && lastText && at == NSMaxRange(lastText->range))
        found = lastText;
    return found;
}

- (void)enumerateTextSegmentsInRange:(NSTextRange *)textRange
                                type:(NSTextLayoutManagerSegmentType)type
                             options:(NSTextLayoutManagerSegmentOptions)options
                          usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextRange *, CGRect, CGFloat, NSTextContainer *))block
{
    CGFloat pad, width;
    UIFLayout *L = lines(self, &pad, &width);
    NSInteger a = offset_of(self, textRange.location), b = offset_of(self, textRange.endLocation);
    if (!L || a == NSNotFound || b == NSNotFound || b < a)
        return;
    _laidOut = YES;
    NSString *s = storage(self).string;
    BOOL wantRange = !(options & NSTextLayoutManagerSegmentOptionsRangeNotRequired);
    if (a == b) {
        UIFLine *ln = caret_line(L, s, (NSUInteger)a, (options & NSTextLayoutManagerSegmentOptionsUpstreamAffinity) != 0);
        if (!ln)
            return;
        CGFloat x = pad + ln->x + (ln->extra ? 0 : UIFLineOffset(ln, (NSUInteger)a));
        block(wantRange ? textRange : nil, CGRectMake(x, ln->top, 0, ln->height), ln->baseline, _container);
        return;
    }
    size_t first = SIZE_MAX, last = 0;
    for (size_t i = 0; i < L->count; i++) {
        UIFLine *ln = &L->lines[i];
        if (ln->extra || (NSInteger)ln->range.location >= b || (NSInteger)NSMaxRange(ln->range) <= a)
            continue;
        first = MIN(first, i);
        last = i;
    }
    if (first == SIZE_MAX)
        return;
    BOOL extends = type == NSTextLayoutManagerSegmentTypeSelection || type == NSTextLayoutManagerSegmentTypeHighlight;
    for (size_t i = first; i <= last; i++) {
        if ((options & NSTextLayoutManagerSegmentOptionsMiddleFragmentsExcluded) && i != first && i != last)
            continue;
        UIFLine *ln = &L->lines[i];
        NSUInteger s0 = MAX((NSUInteger)a, ln->range.location), s1 = MIN((NSUInteger)b, NSMaxRange(ln->range));
        CGFloat x0 = pad + ln->x + UIFLineOffset(ln, s0), x1 = pad + ln->x + UIFLineOffset(ln, s1);
        BOOL past = (NSUInteger)b > NSMaxRange(ln->range) || ((NSUInteger)b == NSMaxRange(ln->range) && ends_paragraph(s, ln));
        if ((extends && past) || ((options & NSTextLayoutManagerSegmentOptionsTailSegmentExtended) && i == last))
            x1 = MAX(x1, width - pad);
        if ((options & NSTextLayoutManagerSegmentOptionsHeadSegmentExtended) && i == first)
            x0 = MIN(x0, pad);
        NSTextRange *r = wantRange ? [[[NSTextRange alloc] initWithLocation:location_at(self, (NSInteger)s0)
                                                                endLocation:location_at(self, (NSInteger)s1)] autorelease]
                                   : nil;
        if (!block(r, CGRectMake(x0, ln->top, x1 - x0, ln->height), ln->baseline, _container))
            return;
    }
}

#pragma mark Rendering attributes

static NSMutableAttributedString *
rendering(NSTextLayoutManager *self)
{
    if (!self->_rendering)
        self->_rendering = [[NSMutableAttributedString alloc] initWithString:storage(self).string ?: @""];
    return self->_rendering;
}

static NSRange
rendering_range(NSTextLayoutManager *self, NSTextRange *r)
{
    NSInteger a = offset_of(self, r.location), b = offset_of(self, r.endLocation);
    NSUInteger len = rendering(self).length;
    if (a == NSNotFound || b == NSNotFound || b < a)
        return NSMakeRange(0, 0);
    NSUInteger loc = MIN((NSUInteger)a, len);
    return NSMakeRange(loc, MIN((NSUInteger)(b - a), len - loc));
}

static void
redisplay(NSTextLayoutManager *self)
{
    id tv = self->_container.textView;
    if ([tv respondsToSelector:@selector(setNeedsDisplay:)])
        [tv setNeedsDisplay:YES];
}

- (void)setRenderingAttributes:(NSDictionary *)attrs forTextRange:(NSTextRange *)textRange
{
    [rendering(self) setAttributes:attrs range:rendering_range(self, textRange)];
    redisplay(self);
}

- (void)addRenderingAttribute:(NSAttributedStringKey)name value:(id)value forTextRange:(NSTextRange *)textRange
{
    if (value)
        [rendering(self) addAttribute:name value:value range:rendering_range(self, textRange)];
    else
        [rendering(self) removeAttribute:name range:rendering_range(self, textRange)];
    redisplay(self);
}

- (void)removeRenderingAttribute:(NSAttributedStringKey)name forTextRange:(NSTextRange *)textRange
{
    [rendering(self) removeAttribute:name range:rendering_range(self, textRange)];
    redisplay(self);
}

- (void)invalidateRenderingAttributesForTextRange:(NSTextRange *)textRange { redisplay(self); }

- (void)enumerateRenderingAttributesFromLocation:(id<NSTextLocation>)location
                                         reverse:(BOOL)reverse
                                      usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextLayoutManager *, NSDictionary<NSAttributedStringKey, id> *, NSTextRange *))block
{
    NSMutableAttributedString *r = rendering(self);
    NSInteger at = offset_of(self, location);
    NSUInteger len = r.length;
    if (at == NSNotFound || at < 0 || (NSUInteger)at > len)
        return;
    NSRange limit = reverse ? NSMakeRange(0, (NSUInteger)at) : NSMakeRange((NSUInteger)at, len - (NSUInteger)at);
    __block BOOL go = YES;
    [r enumerateAttributesInRange:limit
                          options:reverse ? NSAttributedStringEnumerationReverse : 0
                       usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
                         if (!attrs.count)
                             return;
                         NSTextRange *tr = [[[NSTextRange alloc] initWithLocation:location_at(self, (NSInteger)range.location)
                                                                      endLocation:location_at(self, (NSInteger)NSMaxRange(range))]
                             autorelease];
                         go = block(self, attrs, tr);
                         if (!go)
                             *stop = YES;
                       }];
}

- (void (^)(NSTextLayoutManager *, NSTextLayoutFragment *))renderingAttributesValidator { return _validator; }
- (void)setRenderingAttributesValidator:(void (^)(NSTextLayoutManager *, NSTextLayoutFragment *))validator
{
    id old = _validator;
    _validator = [validator copy];
    [old release];
}

+ (NSDictionary *)linkRenderingAttributes
{
    Class color = UIFClass("NSColor");
    id link = [color respondsToSelector:@selector(linkColor)] ? [color linkColor] : nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@(NSUnderlineStyleSingle)
                                                                forKey:NSUnderlineStyleAttributeName];
    if (link)
        d[NSForegroundColorAttributeName] = link;
    return d;
}

- (NSDictionary *)renderingAttributesForLink:(id)link atLocation:(id<NSTextLocation>)location
{
    NSDictionary *attrs = [[self class] linkRenderingAttributes];
    id<NSTextLayoutManagerDelegate> d = _delegate;
    if ([d respondsToSelector:@selector(textLayoutManager:renderingAttributesForLink:atLocation:defaultAttributes:)])
        attrs = [d textLayoutManager:self renderingAttributesForLink:link atLocation:location defaultAttributes:attrs];
    return attrs ?: @{};
}

#pragma mark Editing through the content manager

- (void)replaceContentsInRange:(NSTextRange *)range withTextElements:(NSArray *)textElements
{
    [_tcm replaceContentsInRange:range withTextElements:textElements];
}

- (void)replaceContentsInRange:(NSTextRange *)range withAttributedString:(NSAttributedString *)attributedString
{
    NSTextStorage *ts = storage(self);
    NSInteger a = offset_of(self, range.location), b = offset_of(self, range.endLocation);
    if (!ts || a == NSNotFound || b == NSNotFound || b < a)
        return;
    [ts replaceCharactersInRange:NSMakeRange((NSUInteger)a, (NSUInteger)(b - a))
            withAttributedString:attributedString ?: [[[NSAttributedString alloc] init] autorelease]];
}

#pragma mark NSTextSelectionDataSource

- (NSTextRange *)documentRange
{
    NSTextRange *r = _tcm.documentRange;
    return r ? r : UIFRange(0, 0);
}

- (void)enumerateSubstringsFromLocation:(id<NSTextLocation>)location
                                options:(NSStringEnumerationOptions)options
                             usingBlock:(void (NS_NOESCAPE ^)(NSString *, NSTextRange *, NSTextRange *, BOOL *))block
{
    NSString *s = [self _uifString];
    NSInteger at = offset_of(self, location);
    if (at == NSNotFound || at < 0 || (NSUInteger)at > s.length)
        return;
    BOOL reverse = (options & NSStringEnumerationReverse) != 0;
    NSRange limit = reverse ? NSMakeRange(0, (NSUInteger)at) : NSMakeRange((NSUInteger)at, s.length - (NSUInteger)at);
    [s enumerateSubstringsInRange:limit
                          options:options
                       usingBlock:^(NSString *sub, NSRange r, NSRange enclosing, BOOL *stop) {
                         NSTextRange *tr = [[[NSTextRange alloc] initWithLocation:location_at(self, (NSInteger)r.location)
                                                                      endLocation:location_at(self, (NSInteger)NSMaxRange(r))]
                             autorelease];
                         NSTextRange *te = [[[NSTextRange alloc]
                             initWithLocation:location_at(self, (NSInteger)enclosing.location)
                                  endLocation:location_at(self, (NSInteger)NSMaxRange(enclosing))] autorelease];
                         block(sub, tr, te, stop);
                       }];
}

- (NSTextRange *)textRangeForSelectionGranularity:(NSTextSelectionGranularity)granularity
                                enclosingLocation:(id<NSTextLocation>)location
{
    NSTextSelection *s = [[[NSTextSelection alloc] initWithLocation:location affinity:NSTextSelectionAffinityDownstream] autorelease];
    return [_navigation textSelectionForSelectionGranularity:granularity enclosingTextSelection:s].textRanges.firstObject;
}

- (id<NSTextLocation>)locationFromLocation:(id<NSTextLocation>)location withOffset:(NSInteger)offset
{
    NSTextContentManager *tcm = _tcm;
    if ([tcm respondsToSelector:@selector(locationFromLocation:withOffset:)])
        return [tcm locationFromLocation:location withOffset:offset];
    NSInteger i = UIFLocationIndex(location);
    return i == NSNotFound ? nil : UIFLocation(i + offset);
}

- (NSInteger)offsetFromLocation:(id<NSTextLocation>)from toLocation:(id<NSTextLocation>)to
{
    NSTextContentManager *tcm = _tcm;
    if ([tcm respondsToSelector:@selector(offsetFromLocation:toLocation:)])
        return [tcm offsetFromLocation:from toLocation:to];
    return UIFLocationIndex(to) - UIFLocationIndex(from);
}

- (NSTextSelectionNavigationWritingDirection)baseWritingDirectionAtLocation:(id<NSTextLocation>)location
{
    return NSTextSelectionNavigationWritingDirectionLeftToRight;
}

/* The insertion points of the line holding a location (container
 * coordinates), from its start to its end before any paragraph separator. */
- (void)enumerateCaretOffsetsInLineFragmentAtLocation:(id<NSTextLocation>)location
                                           usingBlock:(void (NS_NOESCAPE ^)(CGFloat, id<NSTextLocation>, BOOL, BOOL *))block
{
    CGFloat pad;
    UIFLayout *L = lines(self, &pad, NULL);
    NSInteger at = offset_of(self, location);
    if (!L || at == NSNotFound || at < 0)
        return;
    NSString *s = storage(self).string;
    UIFLine *ln = caret_line(L, s, (NSUInteger)at, NO);
    if (!ln)
        return;
    NSUInteger end = NSMaxRange(ln->range);
    if (ends_paragraph(s, ln)) {
        end--;
        if (end > ln->range.location && [s characterAtIndex:end] == '\n' && [s characterAtIndex:end - 1] == '\r')
            end--;
    }
    BOOL stop = NO;
    for (NSUInteger i = ln->range.location; i <= end && !stop; i++)
        block(pad + ln->x + (ln->extra ? 0 : UIFLineOffset(ln, i)), location_at(self, (NSInteger)i), YES, &stop);
}

/* The characters of the line at a point's height (the nearest line above or below it). */
- (NSTextRange *)lineFragmentRangeForPoint:(CGPoint)point inContainerAtLocation:(id<NSTextLocation>)location
{
    UIFLayout *L = lines(self, NULL, NULL);
    if (!L || !L->count)
        return nil;
    size_t pick = 0;
    for (size_t i = 0; i < L->count; i++) {
        pick = i;
        UIFLine *ln = &L->lines[i];
        CGFloat bottom = i + 1 < L->count ? L->lines[i + 1].top : ln->top + ln->height;
        if (point.y < bottom)
            break;
    }
    UIFLine *ln = &L->lines[pick];
    return [[[NSTextRange alloc] initWithLocation:location_at(self, (NSInteger)ln->range.location)
                                      endLocation:location_at(self, (NSInteger)NSMaxRange(ln->range))] autorelease];
}

- (void)enumerateContainerBoundariesFromLocation:(id<NSTextLocation>)location
                                         reverse:(BOOL)reverse
                                      usingBlock:(void (NS_NOESCAPE ^)(id<NSTextLocation>, BOOL *))block
{
    BOOL stop = NO;
    NSTextRange *d = self.documentRange;
    block(reverse ? d.location : d.endLocation, &stop);
}

- (NSTextSelectionNavigationLayoutOrientation)textLayoutOrientationAtLocation:(id<NSTextLocation>)location
{
    return NSTextSelectionNavigationLayoutOrientationHorizontal;
}

#pragma mark Archiving

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeConditionalObject:_container forKey:@"NS.firstTextContainer"];
    [coder encodeObject:_tcm forKey:@"NS.textContentManager"];
    [coder encodeInteger:_usesFontLeading ? 1 : 0 forKey:@"NS.flags"];
    [coder encodeBool:_resolvesNatural forKey:@"NS.resolvesNaturalAlignmentWithBaseWritingDirection"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self init]))
        return nil;
    if ([coder containsValueForKey:@"NS.flags"])
        _usesFontLeading = ([coder decodeIntegerForKey:@"NS.flags"] & 1) != 0;
    if ([coder containsValueForKey:@"NS.resolvesNaturalAlignmentWithBaseWritingDirection"])
        _resolvesNatural = [coder decodeBoolForKey:@"NS.resolvesNaturalAlignmentWithBaseWritingDirection"];
    NSTextContentManager *tcm = [coder decodeObjectForKey:@"NS.textContentManager"];
    if ([tcm isKindOfClass:[NSTextContentManager class]] && _tcm != tcm)
        [tcm addTextLayoutManager:self];
    return self;
}

@end

#pragma mark - NSTextLayoutFragment

@implementation NSTextLayoutFragment

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithTextElement:(NSTextElement *)textElement range:(NSTextRange *)rangeInElement
{
    if ((self = [super init])) {
        _element = textElement;
        _range = [(rangeInElement ? rangeInElement : textElement.elementRange) retain];
        _wholeElement = !rangeInElement || [rangeInElement isEqualToTextRange:textElement.elementRange];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}

- (void)dealloc
{
    [_range release];
    [_queue release];
    [_lines release];
    [super dealloc];
}

- (NSTextLayoutManager *)textLayoutManager { return _tlm; }
- (NSTextElement *)textElement { return _element; }

- (NSTextRange *)rangeInElement
{
    NSTextRange *r = _wholeElement ? _element.elementRange : nil;
    return r ? r : _range;
}

- (NSOperationQueue *)layoutQueue { return _queue; }
- (void)setLayoutQueue:(NSOperationQueue *)q
{
    [q retain];
    [_queue release];
    _queue = q;
}
- (NSTextLayoutFragmentState)state { return _state; }
- (void)invalidateLayout { _state = NSTextLayoutFragmentStateNone; }
- (CGFloat)leadingPadding { return 0; }
- (CGFloat)trailingPadding { return 0; }
- (CGFloat)topMargin { return 0; }
- (CGFloat)bottomMargin { return 0; }
- (NSArray *)textAttachmentViewProviders { return @[]; }
- (CGRect)frameForTextAttachmentAtLocation:(id<NSTextLocation>)location { return CGRectZero; }

/* The first line at or after character `at`. */
static size_t
first_line_from(UIFLayout *L, NSUInteger at)
{
    size_t lo = 0, hi = L->count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (L->lines[mid].range.location < at)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

/* Rounded out to whole points. */
static CGRect
round_out(CGRect r)
{
    CGFloat x0 = floor(CGRectGetMinX(r)), y0 = floor(CGRectGetMinY(r));
    return CGRectMake(x0, y0, ceil(CGRectGetMaxX(r)) - x0, ceil(CGRectGetMaxY(r)) - y0);
}

/* The glyphs' font bounding boxes, in the fragment; CGRectNull without ink. */
static CGRect
ink_bounds(NSTextLineFragment *lf)
{
    CGRect r = CGRectNull;
    CTLineRef line = lf->_line.line;
    if (!line)
        return r;
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex k = 0; k < CFArrayGetCount(runs); k++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, k);
        CTFontRef font = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CFIndex n = CTRunGetGlyphCount(run);
        if (!font || n <= 0)
            continue;
        CGGlyph *glyphs = malloc((size_t)n * sizeof *glyphs);
        CGPoint *pos = malloc((size_t)n * sizeof *pos);
        CGRect *ink = malloc((size_t)n * sizeof *ink);
        CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
        CTRunGetPositions(run, CFRangeMake(0, 0), pos);
        CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault, glyphs, ink, n);
        CGRect box = CTFontGetBoundingBox(font);
        for (CFIndex g = 0; g < n; g++) {
            if (CGRectIsEmpty(ink[g]))
                continue;
            CGFloat x = lf->_bounds.origin.x + pos[g].x, base = lf->_bounds.origin.y + lf->_origin.y;
            CGRect gr = CGRectMake(x + CGRectGetMinX(box), base - CGRectGetMaxY(box), box.size.width, box.size.height);
            r = CGRectUnion(r, gr);
        }
        free(glyphs);
        free(pos);
        free(ink);
    }
    return r;
}

/* Lay the fragment out from the engine's lines (again, if they changed). */
static void
fragment_geometry(NSTextLayoutFragment *self)
{
    NSTextLayoutManager *tlm = self->_tlm;
    NSTextElement *element = self->_element;
    CGFloat pad;
    UIFLayout *L = tlm ? lines(tlm, &pad, NULL) : NULL;
    NSUInteger gen = tlm ? UIFLayoutManagerGeneration([tlm _uifEngineIfAny]) : 0;
    if (self->_cached && L && gen == self->_gen)
        return;
    self->_cached = YES;
    self->_gen = gen;
    self->_frame = self->_rsb = CGRectZero;
    [self->_lines release];
    self->_lines = [@[] retain];
    if (!L || !L->count)
        return;
    NSTextRange *range = self.rangeInElement;
    NSInteger a = offset_of(tlm, range.location), b = offset_of(tlm, range.endLocation);
    if (a == NSNotFound || b == NSNotFound || b < a)
        return;
    NSUInteger len = text_length(tlm);
    size_t first = first_line_from(L, (NSUInteger)a), end = first;
    while (end < L->count) {
        UIFLine *ln = &L->lines[end];
        if (ln->extra ? ((NSUInteger)b != len || ln->range.location != len) : (NSInteger)ln->range.location >= b)
            break;
        end++;
    }
    if (end == first)
        return;
    CGFloat top = L->lines[first].top - (first > 0 ? L->lines[first - 1].spacingAfter : 0);
    UIFLine *lastLn = &L->lines[end - 1];
    CGFloat bottom = end < L->count ? L->lines[end].top - lastLn->spacingAfter : lastLn->top + lastLn->height;
    CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX;
    for (size_t i = first; i < end; i++) {
        UIFLine *ln = &L->lines[i];
        if (ln->extra && i > first)
            continue;
        minX = MIN(minX, ln->x);
        maxX = MAX(maxX, ln->x + ln->width);
    }
    self->_frame = CGRectMake(pad + minX, top, maxX - minX, bottom - top);
    NSAttributedString *paragraph = [element isKindOfClass:[NSTextParagraph class]]
                                        ? ((NSTextParagraph *)element).attributedString
                                        : [storage(tlm) attributedSubstringFromRange:NSMakeRange((NSUInteger)a, (NSUInteger)(b - a))];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:end - first];
    CGRect ink = CGRectNull;
    for (size_t i = first; i < end; i++) {
        UIFLine *ln = &L->lines[i];
        NSRange local = ln->extra ? NSMakeRange((NSUInteger)(b - a), 0)
                                  : NSMakeRange(ln->range.location - (NSUInteger)a, ln->range.length);
        NSTextLineFragment *lf = [[NSTextLineFragment alloc] initWithAttributedString:paragraph range:local];
        lf->_laidOut = YES;
        lf->_bounds = CGRectMake(ln->x - minX, ln->top - top, ln->width, ln->height);
        lf->_origin = CGPointMake(0, ln->baseline);
        lf->_line = *ln;
        lf->_line.range = local;
        lf->_line.x = 0;
        lf->_line.top = 0;
        if (lf->_line.line)
            CFRetain(lf->_line.line);
        ink = CGRectUnion(ink, ink_bounds(lf));
        [out addObject:lf];
        [lf release];
    }
    [self->_lines release];
    self->_lines = [out copy];
    CGRect typographic = CGRectMake(0, 0, self->_frame.size.width, self->_frame.size.height);
    self->_rsb = CGRectIsNull(ink) ? typographic : round_out(CGRectUnion(ink, typographic));
}

- (NSArray *)textLineFragments
{
    fragment_geometry(self);
    return _lines;
}

- (CGRect)layoutFragmentFrame
{
    fragment_geometry(self);
    return _frame;
}

- (CGRect)renderingSurfaceBounds
{
    fragment_geometry(self);
    return _rsb;
}

- (NSTextLineFragment *)textLineFragmentForVerticalOffset:(CGFloat)verticalOffset requiresExactMatch:(BOOL)exact
{
    NSArray *ls = self.textLineFragments;
    NSTextLineFragment *nearest = nil;
    CGFloat best = CGFLOAT_MAX;
    if (verticalOffset < 0 || verticalOffset >= CGRectGetHeight(self.layoutFragmentFrame))
        return nil;
    for (NSTextLineFragment *lf in ls) {
        CGRect r = lf.typographicBounds;
        if (verticalOffset >= CGRectGetMinY(r) && verticalOffset < CGRectGetMaxY(r))
            return lf;
        CGFloat d = MIN(fabs(verticalOffset - CGRectGetMinY(r)), fabs(verticalOffset - CGRectGetMaxY(r)));
        if (d < best) {
            best = d;
            nearest = lf;
        }
    }
    return exact ? nil : nearest;
}

- (NSTextLineFragment *)textLineFragmentForTextLocation:(id<NSTextLocation>)textLocation isUpstreamAffinity:(BOOL)upstream
{
    NSTextLayoutManager *tlm = _tlm;
    if (!tlm)
        return nil;
    NSInteger at = offset_of(tlm, textLocation), a = offset_of(tlm, self.rangeInElement.location);
    if (at == NSNotFound || a == NSNotFound)
        return nil;
    NSUInteger local = (NSUInteger)(at - a);
    NSArray *ls = self.textLineFragments;
    for (NSUInteger i = 0; i < ls.count; i++) {
        NSRange r = [ls[i] characterRange];
        if (upstream && local == r.location && i > 0 && NSMaxRange([ls[i - 1] characterRange]) == local)
            return ls[i - 1];
        if (NSLocationInRange(local, r) || (local == r.location && !r.length))
            return ls[i];
    }
    return ls.lastObject;
}

- (void)drawAtPoint:(CGPoint)point inContext:(CGContextRef)context
{
    for (NSTextLineFragment *lf in self.textLineFragments) {
        CGRect r = lf.typographicBounds;
        [lf drawAtPoint:CGPointMake(point.x + r.origin.x, point.y + r.origin.y) inContext:context];
    }
}

- (NSString *)description
{
    static NSString *const names[] = {@"None", @"EstimatedUsageBounds", @"CalculatedUsageBounds", @"LaidOut"};
    CGRect f = self.layoutFragmentFrame;
    return [NSString stringWithFormat:@"NSTextLayoutFragment: %p range=%@ layoutState=%@ frame=%@", self, self.rangeInElement,
                                      _state <= 3 ? names[_state] : @"?", NSStringFromRect(NSRectFromCGRect(f))];
}

@end

#pragma mark - NSTextViewportLayoutController

/*
 * -layoutViewport, as Apple's: the delegate's -textViewportLayoutControllerWillLayout:,
 * its viewport bounds, -configureRenderingSurfaceForTextLayoutFragment: for each
 * laid-out fragment in the viewport, top to bottom, then
 * -textViewportLayoutControllerDidLayout:. The viewport range covers those fragments.
 */
@implementation NSTextViewportLayoutController {
    __weak id<NSTextViewportLayoutControllerDelegate> _delegate;
    __weak NSTextLayoutManager *_tlm;
    CGRect _bounds;
    NSTextRange *_range;
}

- (instancetype)initWithTextLayoutManager:(NSTextLayoutManager *)textLayoutManager
{
    if ((self = [super init]))
        _tlm = textLayoutManager;
    return self;
}

- (void)dealloc
{
    [_range release];
    [super dealloc];
}

- (id<NSTextViewportLayoutControllerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSTextViewportLayoutControllerDelegate>)delegate { _delegate = delegate; }
- (NSTextLayoutManager *)textLayoutManager { return _tlm; }
- (CGRect)viewportBounds { return _bounds; }
- (NSTextRange *)viewportRange { return _range; }

- (void)layoutViewport
{
    id<NSTextViewportLayoutControllerDelegate> d = _delegate;
    NSTextLayoutManager *tlm = _tlm;
    if ([d respondsToSelector:@selector(textViewportLayoutControllerWillLayout:)])
        [d textViewportLayoutControllerWillLayout:self];
    if ([d respondsToSelector:@selector(viewportBoundsForTextViewportLayoutController:)])
        _bounds = [d viewportBoundsForTextViewportLayoutController:self];
    CGRect b = _bounds;
    __block NSTextRange *range = nil;
    NSTextLayoutFragment *start = [tlm textLayoutFragmentForPosition:b.origin];
    if (!start)
        _bounds = CGRectZero; /* nothing in view (past the text's end) */
    if (start)
        [tlm enumerateTextLayoutFragmentsFromLocation:start.rangeInElement.location
                                          options:NSTextLayoutFragmentEnumerationOptionsEnsuresLayout
                                       usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                         CGRect fr = f.layoutFragmentFrame;
                                         if (CGRectGetMinY(fr) >= CGRectGetMaxY(b) && range)
                                             return NO;
                                         if (CGRectGetMaxY(fr) > CGRectGetMinY(b) || !range) {
                                             if ([d respondsToSelector:@selector(textViewportLayoutController:
                                                                           configureRenderingSurfaceForTextLayoutFragment:)])
                                                 [d textViewportLayoutController:self configureRenderingSurfaceForTextLayoutFragment:f];
                                             range = range ? [range textRangeByFormingUnionWithTextRange:f.rangeInElement]
                                                           : f.rangeInElement;
                                         }
                                         return CGRectGetMaxY(fr) < CGRectGetMaxY(b);
                                       }];
    [range retain];
    [_range release];
    _range = range;
    if ([d respondsToSelector:@selector(textViewportLayoutControllerDidLayout:)])
        [d textViewportLayoutControllerDidLayout:self];
}

- (CGFloat)relocateViewportToTextLocation:(id<NSTextLocation>)textLocation
{
    NSTextLayoutFragment *f = [_tlm textLayoutFragmentForLocation:textLocation];
    CGFloat y = f ? CGRectGetMinY(f.layoutFragmentFrame) : 0;
    _bounds.origin.y = y;
    return y;
}

- (void)adjustViewportByVerticalOffset:(CGFloat)verticalOffset { _bounds.origin.y += verticalOffset; }

@end
