/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * TextKit 2's content: NSTextElement and NSTextParagraph, NSTextContentManager
 * (the abstract element provider and its text layout managers) and
 * NSTextContentStorage, which presents an NSTextStorage as paragraphs.
 *
 * As Apple's (macOS 26):
 * - Locations are NSCountableTextLocations, offsets into the text storage.
 * - A paragraph runs to and includes its separator (\n, \r, \r\n, U+2029); a
 *   final separator doesn't start an empty paragraph. Paragraphs are made when
 *   first enumerated (asking the delegate's -textContentStorage:textParagraphWithRange:)
 *   and kept until an edit touches them; later ones move with the edit.
 * - Enumerating forward from a location starts with the element holding it;
 *   backward, with the last element that starts before it. Forward, the result
 *   is the end of the last element passed to the block (the starting location
 *   if none); backward, the document's start.
 * - Setting attributedString lets the text storage go (textStorage is nil)
 *   and keeps a copy of the string as the content.
 * - -textElementsForRange: walks forward from the range's start while the
 *   elements start inside the range.
 * - The content storage observes its text storage (textStorageObserver), so
 *   edits made to the storage reach the text layout managers.
 */
#import "UIFTextKit2.h"

#pragma mark - Elements

@implementation NSTextElement {
    __weak NSTextContentManager *_tcm;
    NSTextRange *_elementRange;
}

- (instancetype)initWithTextContentManager:(NSTextContentManager *)textContentManager
{
    if ((self = [super init]))
        _tcm = textContentManager;
    return self;
}

- (instancetype)init { return [self initWithTextContentManager:nil]; }

- (void)dealloc
{
    [_elementRange release];
    [super dealloc];
}

- (NSTextContentManager *)textContentManager { return _tcm; }
- (void)setTextContentManager:(NSTextContentManager *)textContentManager { _tcm = textContentManager; }
- (NSTextRange *)elementRange { return _elementRange; }

- (void)setElementRange:(NSTextRange *)elementRange
{
    [elementRange retain];
    [_elementRange release];
    _elementRange = elementRange;
}

- (NSArray *)childElements { return @[]; }
- (NSTextElement *)parentElement { return nil; }
- (BOOL)isRepresentedElement { return YES; }

@end

static BOOL
is_separator(unichar c)
{
    return c == '\n' || c == '\r' || c == 0x2029;
}

/* The length of the separator ending s (0 if none). */
static NSUInteger
separator_length(NSString *s)
{
    NSUInteger n = s.length;
    if (!n || !is_separator([s characterAtIndex:n - 1]))
        return 0;
    if (n >= 2 && [s characterAtIndex:n - 1] == '\n' && [s characterAtIndex:n - 2] == '\r')
        return 2;
    return 1;
}

@implementation NSTextParagraph {
    NSAttributedString *_string;
}

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
{
    if ((self = [super initWithTextContentManager:nil]))
        _string = attributedString ? [attributedString copy] : [[NSAttributedString alloc] init];
    return self;
}

- (instancetype)initWithTextContentManager:(NSTextContentManager *)textContentManager
{
    if ((self = [self initWithAttributedString:nil]))
        self.textContentManager = textContentManager;
    return self;
}

- (void)dealloc
{
    [_string release];
    [super dealloc];
}

- (NSAttributedString *)attributedString { return _string; }

/* A location `offset` after `location`, through the element's content manager. */
static id<NSTextLocation>
advance(NSTextElement *e, id<NSTextLocation> location, NSInteger offset)
{
    NSTextContentManager *tcm = e.textContentManager;
    if ([tcm respondsToSelector:@selector(locationFromLocation:withOffset:)])
        return [tcm locationFromLocation:location withOffset:offset];
    NSInteger i = UIFLocationIndex(location);
    return i == NSNotFound ? nil : UIFLocation(i + offset);
}

- (NSTextRange *)paragraphContentRange
{
    NSTextRange *r = self.elementRange;
    if (!r)
        return nil;
    id<NSTextLocation> end = advance(self, r.location, (NSInteger)(_string.length - separator_length(_string.string)));
    return end ? [[[NSTextRange alloc] initWithLocation:r.location endLocation:end] autorelease] : nil;
}

- (NSTextRange *)paragraphSeparatorRange
{
    NSTextRange *r = self.elementRange;
    if (!r)
        return nil;
    id<NSTextLocation> start = advance(self, r.location, (NSInteger)(_string.length - separator_length(_string.string)));
    id<NSTextLocation> end = advance(self, r.location, (NSInteger)_string.length);
    return start && end ? [[[NSTextRange alloc] initWithLocation:start endLocation:end] autorelease] : nil;
}

- (NSString *)description { return [NSString stringWithFormat:@"<NSTextParagraph: %p \"%@\">", self, _string.string]; }

@end

#pragma mark - NSTextContentManager

@implementation NSTextContentManager {
    NSMutableArray *_layoutManagers;
    NSTextLayoutManager *_primary;
    __weak id<NSTextContentManagerDelegate> _delegate;
    NSInteger _transactions;
    BOOL _syncLayoutManagers, _syncBackingStore;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _layoutManagers = [NSMutableArray new];
        _syncLayoutManagers = YES;
    }
    return self;
}

- (void)dealloc
{
    for (NSTextLayoutManager *tlm in _layoutManagers)
        [tlm _uifSetTextContentManager:nil];
    [_layoutManagers release];
    [_primary release];
    [super dealloc];
}

- (id<NSTextContentManagerDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSTextContentManagerDelegate>)delegate { _delegate = delegate; }
- (NSArray *)textLayoutManagers { return [[_layoutManagers copy] autorelease]; }

- (void)addTextLayoutManager:(NSTextLayoutManager *)textLayoutManager
{
    if (!textLayoutManager || [_layoutManagers indexOfObjectIdenticalTo:textLayoutManager] != NSNotFound)
        return;
    NSTextContentManager *old = textLayoutManager.textContentManager;
    if (old && old != self)
        [old removeTextLayoutManager:textLayoutManager];
    [_layoutManagers addObject:textLayoutManager];
    [textLayoutManager _uifSetTextContentManager:self];
}

- (void)removeTextLayoutManager:(NSTextLayoutManager *)textLayoutManager
{
    NSUInteger i = [_layoutManagers indexOfObjectIdenticalTo:textLayoutManager];
    if (i == NSNotFound)
        return;
    [[textLayoutManager retain] autorelease];
    if (_primary == textLayoutManager) {
        [_primary release];
        _primary = nil;
    }
    [_layoutManagers removeObjectAtIndex:i];
    [textLayoutManager _uifSetTextContentManager:nil];
}

- (NSTextLayoutManager *)primaryTextLayoutManager { return _primary; }

- (void)setPrimaryTextLayoutManager:(NSTextLayoutManager *)primary
{
    if (primary && [_layoutManagers indexOfObjectIdenticalTo:primary] == NSNotFound)
        return;
    [primary retain];
    [_primary release];
    _primary = primary;
}

- (void)synchronizeTextLayoutManagers:(void (^)(NSError *))completionHandler
{
    if (completionHandler)
        completionHandler(nil);
}

- (NSArray *)textElementsForRange:(NSTextRange *)range
{
    NSMutableArray *a = [NSMutableArray array];
    [self enumerateTextElementsFromLocation:range.location
                                    options:0
                                 usingBlock:^BOOL(NSTextElement *element) {
                                   id<NSTextLocation> start = element.elementRange.location;
                                   if (!start || ![range containsLocation:start])
                                       return NO;
                                   [a addObject:element];
                                   return YES;
                                 }];
    return a;
}

- (BOOL)hasEditingTransaction { return _transactions > 0; }

- (void)performEditingTransactionUsingBlock:(void (NS_NOESCAPE ^)(void))transaction
{
    _transactions++;
    @try {
        if (transaction)
            transaction();
    } @finally {
        _transactions--;
    }
}

- (void)recordEditActionInRange:(NSTextRange *)originalTextRange newTextRange:(NSTextRange *)newTextRange
{
    /* A subclass's content changed: lay the text out again. */
    for (NSTextLayoutManager *tlm in [[_layoutManagers copy] autorelease])
        [tlm _uifTextStorageReplaced];
}

- (BOOL)automaticallySynchronizesTextLayoutManagers { return _syncLayoutManagers; }
- (void)setAutomaticallySynchronizesTextLayoutManagers:(BOOL)v { _syncLayoutManagers = v; }
- (BOOL)automaticallySynchronizesToBackingStore { return _syncBackingStore; }
- (void)setAutomaticallySynchronizesToBackingStore:(BOOL)v { _syncBackingStore = v; }

/* NSTextElementProvider, for subclasses. */
- (NSTextRange *)documentRange { return nil; }

- (id<NSTextLocation>)enumerateTextElementsFromLocation:(id<NSTextLocation>)textLocation
                                                options:(NSTextContentManagerEnumerationOptions)options
                                             usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextElement *))block
{
    return nil;
}

- (void)replaceContentsInRange:(NSTextRange *)range withTextElements:(NSArray *)textElements {}

- (void)synchronizeToBackingStore:(void (^)(NSError *))completionHandler
{
    if (completionHandler)
        completionHandler(nil);
}

/*
 * The text a subclass's elements make, for its layout managers: its
 * paragraphs' strings, one after another. NSTextContentStorage returns its
 * text storage.
 */
- (NSTextStorage *)_uifTextStorage
{
    NSTextStorage *ts = [[[NSTextStorage alloc] init] autorelease];
    [ts beginEditing];
    [self enumerateTextElementsFromLocation:nil
                                    options:0
                                 usingBlock:^BOOL(NSTextElement *e) {
                                   if ([e isKindOfClass:[NSTextParagraph class]])
                                       [ts appendAttributedString:((NSTextParagraph *)e).attributedString];
                                   return YES;
                                 }];
    [ts endEditing];
    return ts;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_layoutManagers forKey:@"NS.textLayoutManagers"];
    [coder encodeInteger:1 forKey:@"NS.flags"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self init]))
        return nil;
    NSArray *tlms = [coder decodeObjectForKey:@"NS.textLayoutManagers"];
    if ([tlms isKindOfClass:[NSArray class]])
        for (NSTextLayoutManager *tlm in tlms)
            if ([tlm isKindOfClass:[NSTextLayoutManager class]])
                [self addTextLayoutManager:tlm];
    return self;
}

@end

#pragma mark - NSTextContentStorage

typedef struct {
    NSRange range;
    NSTextParagraph *paragraph; /* retained; nil until enumerated */
} Paragraph;

@implementation NSTextContentStorage {
    NSTextStorage *_storage;        /* the text storage, or nil after attributedString was set */
    NSAttributedString *_contents;  /* the attributedString set instead */
    NSTextStorage *_layoutStorage;  /* that string, for the layout managers */
    Paragraph *_paras;
    size_t _count, _capacity;
    BOOL _valid; /* _paras matches the text */
    BOOL _includesListMarkers;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _storage = [[NSTextStorage alloc] init];
        _storage.textStorageObserver = self;
    }
    return self;
}

static void
drop_paragraphs(NSTextContentStorage *self)
{
    for (size_t i = 0; i < self->_count; i++)
        [self->_paras[i].paragraph release];
    self->_count = 0;
    self->_valid = NO;
}

- (void)dealloc
{
    drop_paragraphs(self);
    free(_paras);
    if (_storage.textStorageObserver == self)
        _storage.textStorageObserver = nil;
    /* Kept until the layout managers have let go of it (NSTextContentManager's -dealloc). */
    [_storage autorelease];
    [_contents release];
    [_layoutStorage autorelease];
    [super dealloc];
}

- (id<NSTextContentStorageDelegate>)delegate { return (id<NSTextContentStorageDelegate>)[super delegate]; }
- (void)setDelegate:(id<NSTextContentStorageDelegate>)delegate { [super setDelegate:delegate]; }
- (BOOL)includesTextListMarkers { return _includesListMarkers; }
- (void)setIncludesTextListMarkers:(BOOL)v { _includesListMarkers = v; }

- (NSTextStorage *)textStorage { return _storage; }

- (void)setTextStorage:(NSTextStorage *)textStorage
{
    if (textStorage == _storage)
        return;
    if (_storage.textStorageObserver == self)
        _storage.textStorageObserver = nil;
    [textStorage retain];
    [_storage release];
    _storage = textStorage;
    _storage.textStorageObserver = self;
    [_contents release];
    _contents = nil;
    [_layoutStorage autorelease];
    _layoutStorage = nil;
    drop_paragraphs(self);
    for (NSTextLayoutManager *tlm in self.textLayoutManagers)
        [tlm _uifTextStorageReplaced];
}

- (NSTextStorage *)_uifTextStorage
{
    if (_storage)
        return _storage;
    if (!_layoutStorage)
        _layoutStorage = [[NSTextStorage alloc] initWithAttributedString:_contents ?: [[[NSAttributedString alloc] init] autorelease]];
    return _layoutStorage;
}

/* The text: the text storage, or the attributed string set in its place. */
static NSAttributedString *
contents(NSTextContentStorage *self)
{
    return self->_storage ? (NSAttributedString *)self->_storage : self->_contents;
}

- (NSAttributedString *)attributedString { return contents(self); }

- (void)setAttributedString:(NSAttributedString *)attributedString
{
    /* As Apple's, the storage let go still names this as its observer (its edits are ignored). */
    [_storage autorelease];
    _storage = nil;
    NSAttributedString *old = _contents;
    _contents = [attributedString copy];
    [old release];
    [_layoutStorage autorelease];
    _layoutStorage = nil;
    drop_paragraphs(self);
    for (NSTextLayoutManager *tlm in self.textLayoutManagers)
        [tlm _uifTextStorageReplaced];
}

#pragma mark Paragraphs

static void
add_paragraph(NSTextContentStorage *self, NSRange r)
{
    if (self->_count == self->_capacity) {
        self->_capacity = self->_capacity ? self->_capacity * 2 : 16;
        self->_paras = realloc(self->_paras, self->_capacity * sizeof *self->_paras);
    }
    self->_paras[self->_count++] = (Paragraph){r, nil};
}

/* The text's paragraph ranges. */
static void
split(NSTextContentStorage *self)
{
    if (self->_valid)
        return;
    drop_paragraphs(self);
    NSString *s = contents(self).string;
    NSUInteger n = s.length, start = 0;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (!is_separator(c))
            continue;
        if (c == '\r' && i + 1 < n && [s characterAtIndex:i + 1] == '\n')
            i++;
        add_paragraph(self, NSMakeRange(start, i + 1 - start));
        start = i + 1;
    }
    if (start < n)
        add_paragraph(self, NSMakeRange(start, n - start));
    self->_valid = YES;
}

/* Paragraph i's element, made (with the delegate's help) when first asked for. */
static NSTextParagraph *
paragraph_at(NSTextContentStorage *self, size_t i)
{
    Paragraph *p = &self->_paras[i];
    if (p->paragraph)
        return p->paragraph;
    NSRange r = p->range;
    NSTextParagraph *para = nil;
    id<NSTextContentStorageDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(textContentStorage:textParagraphWithRange:)])
        para = [d textContentStorage:self textParagraphWithRange:r];
    if (!para)
        para = [[[NSTextParagraph alloc] initWithAttributedString:[contents(self) attributedSubstringFromRange:r]] autorelease];
    /* The delegate may have returned a paragraph it keeps (and asked for in the meantime). */
    p = &self->_paras[i];
    if (p->paragraph)
        return p->paragraph;
    para.textContentManager = self;
    para.elementRange = UIFRange((NSInteger)r.location, (NSInteger)NSMaxRange(r));
    p->paragraph = [para retain];
    return para;
}

/* The paragraph holding offset i (the last one for the text's end), or -1. */
static ssize_t
paragraph_index(NSTextContentStorage *self, NSUInteger i)
{
    split(self);
    if (!self->_count)
        return -1;
    size_t lo = 0, hi = self->_count;
    while (lo + 1 < hi) {
        size_t mid = (lo + hi) / 2;
        if (self->_paras[mid].range.location <= i)
            lo = mid;
        else
            hi = mid;
    }
    return (ssize_t)lo;
}

- (NSTextRange *)documentRange { return UIFRange(0, (NSInteger)contents(self).length); }

- (id<NSTextLocation>)enumerateTextElementsFromLocation:(id<NSTextLocation>)textLocation
                                                options:(NSTextContentManagerEnumerationOptions)options
                                             usingBlock:(BOOL (NS_NOESCAPE ^)(NSTextElement *))block
{
    split(self);
    BOOL reverse = (options & NSTextContentManagerEnumerationOptionsReverse) != 0;
    NSUInteger len = contents(self).length;
    NSInteger at = textLocation ? UIFLocationIndex(textLocation) : (reverse ? (NSInteger)len : 0);
    if (at == NSNotFound || at < 0 || (NSUInteger)at > len)
        return nil;
    ssize_t i;
    if (reverse) {
        /* The last paragraph starting before the location. */
        i = (ssize_t)_count - 1;
        while (i >= 0 && _paras[i].range.location >= (NSUInteger)at)
            i--;
    } else {
        i = paragraph_index(self, (NSUInteger)at);
        if (i >= 0 && (NSUInteger)at >= NSMaxRange(_paras[i].range))
            i = (ssize_t)_count; /* at the very end: nothing follows */
    }
    id<NSTextContentManagerDelegate> d = self.delegate;
    BOOL asks = [d respondsToSelector:@selector(textContentManager:shouldEnumerateTextElement:options:)];
    id<NSTextLocation> last = reverse ? UIFLocation(0) : UIFLocation(at);
    while (i >= 0 && (size_t)i < _count) {
        NSTextParagraph *p = [[paragraph_at(self, (size_t)i) retain] autorelease];
        BOOL go = YES;
        if (!asks || [d textContentManager:self shouldEnumerateTextElement:p options:options]) {
            if (!reverse)
                last = p.elementRange.endLocation;
            go = block(p);
        }
        if (!go)
            break;
        /* The block may have edited the text. */
        split(self);
        i += reverse ? -1 : 1;
    }
    return last;
}

- (NSArray *)textElementsForRange:(NSTextRange *)range { return [super textElementsForRange:range]; }

- (id<NSTextLocation>)locationFromLocation:(id<NSTextLocation>)location withOffset:(NSInteger)offset
{
    NSInteger i = UIFLocationIndex(location);
    if (i == NSNotFound)
        return nil;
    i += offset;
    return i < 0 || (NSUInteger)i > contents(self).length ? nil : UIFLocation(i);
}

- (NSInteger)offsetFromLocation:(id<NSTextLocation>)from toLocation:(id<NSTextLocation>)to
{
    NSInteger a = UIFLocationIndex(from), b = UIFLocationIndex(to);
    return a == NSNotFound || b == NSNotFound ? 0 : b - a;
}

/* Plain text needs no adjusting (Apple's adjusts nothing here either). */
- (NSTextRange *)adjustedRangeFromRange:(NSTextRange *)textRange forEditingTextSelection:(BOOL)forEditingTextSelection
{
    return nil;
}

- (NSAttributedString *)attributedStringForTextElement:(NSTextElement *)textElement
{
    if ([textElement isKindOfClass:[NSTextParagraph class]])
        return ((NSTextParagraph *)textElement).attributedString;
    return nil;
}

- (NSTextElement *)textElementForAttributedString:(NSAttributedString *)attributedString
{
    NSTextParagraph *p = [[[NSTextParagraph alloc] initWithAttributedString:attributedString] autorelease];
    p.textContentManager = self;
    return p;
}

- (void)replaceContentsInRange:(NSTextRange *)range withTextElements:(NSArray *)textElements
{
    NSInteger a = UIFLocationIndex(range.location), b = UIFLocationIndex(range.endLocation);
    if (a == NSNotFound || b == NSNotFound)
        return;
    NSMutableAttributedString *s = [[[NSMutableAttributedString alloc] init] autorelease];
    for (NSTextElement *e in textElements) {
        NSAttributedString *part = [self attributedStringForTextElement:e];
        if (part)
            [s appendAttributedString:part];
    }
    [_storage replaceCharactersInRange:NSMakeRange((NSUInteger)a, (NSUInteger)(b - a)) withAttributedString:s];
}

#pragma mark Edits (NSTextStorageObserving)

- (void)performEditingTransactionForTextStorage:(NSTextStorage *)textStorage usingBlock:(void (NS_NOESCAPE ^)(void))transaction
{
    [self performEditingTransactionUsingBlock:transaction];
}

/*
 * The storage was edited. Paragraphs wholly before the edit stay; those after
 * it stay and move; the rest are made again when next enumerated.
 */
- (void)processEditingForTextStorage:(NSTextStorage *)textStorage
                              edited:(NSTextStorageEditActions)editMask
                               range:(NSRange)newCharRange
                      changeInLength:(NSInteger)delta
                    invalidatedRange:(NSRange)invalidatedCharRange
{
    if (textStorage != _storage)
        return;
    if (_valid) {
        Paragraph *old = _paras;
        size_t oldCount = _count;
        _paras = NULL;
        _count = _capacity = 0;
        _valid = NO;
        split(self);
        NSUInteger editStart = newCharRange.location, newEnd = NSMaxRange(newCharRange);
        BOOL chars = (editMask & NSTextStorageEditedCharacters) != 0;
        size_t j = 0;
        for (size_t i = 0; i < _count; i++) {
            NSRange r = _paras[i].range, was;
            if (!chars)
                was = NSIntersectionRange(r, newCharRange).length ? NSMakeRange(NSNotFound, 0) : r;
            else if (NSMaxRange(r) <= editStart)
                was = r;
            else if (r.location > newEnd)
                was = NSMakeRange((NSUInteger)((NSInteger)r.location - delta), r.length);
            else
                was = NSMakeRange(NSNotFound, 0);
            if (was.location == NSNotFound)
                continue;
            while (j < oldCount && old[j].range.location < was.location)
                j++;
            if (j < oldCount && NSEqualRanges(old[j].range, was) && old[j].paragraph) {
                _paras[i].paragraph = old[j].paragraph;
                old[j].paragraph = nil;
                if (!NSEqualRanges(r, was))
                    _paras[i].paragraph.elementRange = UIFRange((NSInteger)r.location, (NSInteger)NSMaxRange(r));
            }
        }
        for (size_t k = 0; k < oldCount; k++)
            [old[k].paragraph release];
        free(old);
    }
    for (NSTextLayoutManager *tlm in self.textLayoutManagers)
        [tlm _uifProcessEditing:editMask range:newCharRange changeInLength:delta];
}

#pragma mark Archiving

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_storage forKey:@"NS.textStorage"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder]))
        return nil;
    NSTextStorage *ts = [coder decodeObjectForKey:@"NS.textStorage"];
    if ([ts isKindOfClass:[NSTextStorage class]])
        self.textStorage = ts;
    return self;
}

@end
