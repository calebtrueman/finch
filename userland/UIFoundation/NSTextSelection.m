/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * TextKit 2's selections: NSTextSelection, and NSTextSelectionNavigation,
 * which moves, extends and deletes them through an NSTextSelectionDataSource
 * (NSTextLayoutManager is one): the text, its locations, and its lines'
 * caret offsets.
 *
 * As Apple's (macOS 26, measured):
 * - Forward and right, backward and left are the same (left-to-right text);
 *   up and down move a line only for the character destination, and are
 *   backward and forward for the others. Up from the first line goes to the
 *   text's start; down from the last, to its end.
 * - Words: forward skips non-word characters, then the word; backward the
 *   same in reverse. Lines: forward to the line's end before any paragraph
 *   separator, with upstream affinity; backward to its start, or from a
 *   line's start to the previous line's. Sentences end after their closing
 *   punctuation and spaces, or with their paragraph (separator included).
 *   Paragraphs: forward to the end before the separator (from there, to the
 *   next paragraph's); backward to the start (from there, the previous one's).
 * - Moving a selection without extending it collapses it to the end it moves
 *   toward; extending moves its head (its end, unless it has a secondary
 *   (anchor) location) and keeps its anchor.
 * - Deleting backward to a line's start from its start deletes nothing.
 * - A click resolves to the nearest insertion point on the line at its
 *   height (upstream past a line's end), with that caret's x as the anchor
 *   position offset; extending from an anchor selection keeps the anchor.
 */
#import "UIFTextKit2.h"

#pragma mark - NSTextSelection

@interface NSTextSelection (UIFAnchor)
- (id<NSTextLocation>)_uifAnchor;
- (void)_uifSetAnchor:(id<NSTextLocation>)location;
- (void)_uifSetTransient:(BOOL)v;
@end

@implementation NSTextSelection {
    NSArray *_ranges;
    NSTextSelectionGranularity _granularity;
    NSTextSelectionAffinity _affinity;
    BOOL _transient, _logical;
    CGFloat _anchorOffset;
    id<NSTextLocation> _secondary;
    id<NSTextLocation> _anchor; /* where an extended selection is anchored */
    NSDictionary *_typing;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithRanges:(NSArray *)textRanges
                      affinity:(NSTextSelectionAffinity)affinity
                   granularity:(NSTextSelectionGranularity)granularity
{
    if ((self = [super init])) {
        _ranges = [(textRanges ? textRanges : @[]) copy];
        _affinity = affinity;
        _granularity = granularity;
    }
    return self;
}

- (instancetype)initWithRange:(NSTextRange *)range
                     affinity:(NSTextSelectionAffinity)affinity
                  granularity:(NSTextSelectionGranularity)granularity
{
    return [self initWithRanges:range ? @[ range ] : @[] affinity:affinity granularity:granularity];
}

- (instancetype)initWithLocation:(id<NSTextLocation>)location affinity:(NSTextSelectionAffinity)affinity
{
    NSTextRange *r = [[[NSTextRange alloc] initWithLocation:location] autorelease];
    return [self initWithRange:r affinity:affinity granularity:NSTextSelectionGranularityCharacter];
}

- (void)dealloc
{
    [_ranges release];
    [(id)_secondary release];
    [(id)_anchor release];
    [_typing release];
    [super dealloc];
}

- (NSArray *)textRanges { return _ranges; }
- (NSTextSelectionGranularity)granularity { return _granularity; }
- (NSTextSelectionAffinity)affinity { return _affinity; }
- (BOOL)isTransient { return _transient; }
- (void)_uifSetTransient:(BOOL)v { _transient = v; }
- (CGFloat)anchorPositionOffset { return _anchorOffset; }
- (void)setAnchorPositionOffset:(CGFloat)v { _anchorOffset = v; }
- (BOOL)isLogical { return _logical; }
- (void)setLogical:(BOOL)v { _logical = v; }
- (id<NSTextLocation>)secondarySelectionLocation { return _secondary; }
- (void)setSecondarySelectionLocation:(id<NSTextLocation>)location
{
    [(id)location retain];
    [(id)_secondary release];
    _secondary = location;
}
- (id<NSTextLocation>)_uifAnchor { return _anchor; }
- (void)_uifSetAnchor:(id<NSTextLocation>)location
{
    [(id)location retain];
    [(id)_anchor release];
    _anchor = location;
}
- (NSDictionary *)typingAttributes { return _typing; }
- (void)setTypingAttributes:(NSDictionary *)attrs
{
    NSDictionary *old = _typing;
    _typing = [attrs copy];
    [old release];
}

- (NSTextSelection *)textSelectionWithTextRanges:(NSArray *)textRanges
{
    NSTextSelection *s = [[[NSTextSelection alloc] initWithRanges:textRanges affinity:_affinity granularity:_granularity] autorelease];
    s->_transient = _transient;
    s->_logical = _logical;
    s->_anchorOffset = _anchorOffset;
    s.typingAttributes = _typing;
    return s;
}

- (NSString *)description
{
    static NSString *const granularities[] = {@"character", @"word", @"paragraph", @"line", @"sentence"};
    NSMutableString *d = [NSMutableString stringWithFormat:@"NSTextSelection:<%p> granularity=%@, affinity=%@, ", self,
                                                           (NSUInteger)_granularity < 5 ? granularities[_granularity] : @"?",
                                                           _affinity == NSTextSelectionAffinityUpstream ? @"upstream" : @"downstream"];
    if (_transient)
        [d appendString:@"transient, "];
    if (_anchorOffset != 0)
        [d appendFormat:@"anchor position offset=%f, ", _anchorOffset];
    if (_anchor)
        [d appendFormat:@"anchor location %@, ", _anchor];
    [d appendString:@"textRanges=(\n"];
    for (NSUInteger i = 0; i < _ranges.count; i++)
        [d appendFormat:@"    \"%@\"%@\n", _ranges[i], i + 1 < _ranges.count ? @"," : @""];
    [d appendString:@")"];
    return d;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_ranges forKey:@"NS.textRanges"];
    [coder encodeInteger:_affinity forKey:@"NS.affinity"];
    [coder encodeInteger:_granularity forKey:@"NS.granularity"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSArray *ranges = [coder decodeObjectForKey:@"NS.textRanges"];
    return [self initWithRanges:[ranges isKindOfClass:[NSArray class]] ? ranges : @[]
                       affinity:[coder decodeIntegerForKey:@"NS.affinity"]
                    granularity:[coder decodeIntegerForKey:@"NS.granularity"]];
}

@end

#pragma mark - NSTextSelectionNavigation

@implementation NSTextSelectionNavigation {
    __weak id<NSTextSelectionDataSource> _dataSource;
    BOOL _allowsNonContiguous, _rotates;
}

- (instancetype)initWithDataSource:(id<NSTextSelectionDataSource>)dataSource
{
    if ((self = [super init])) {
        _dataSource = dataSource;
        _allowsNonContiguous = YES;
    }
    return self;
}

- (id<NSTextSelectionDataSource>)textSelectionDataSource { return _dataSource; }
- (BOOL)allowsNonContiguousRanges { return _allowsNonContiguous; }
- (void)setAllowsNonContiguousRanges:(BOOL)v { _allowsNonContiguous = v; }
- (BOOL)rotatesCoordinateSystemForLayoutOrientation { return _rotates; }
- (void)setRotatesCoordinateSystemForLayoutOrientation:(BOOL)v { _rotates = v; }
- (void)flushLayoutCache {}

/* What a navigation works with: the data source's text as offsets. */
typedef struct {
    id<NSTextSelectionDataSource> ds;
    id<NSTextLocation> start; /* the document's */
    NSString *s;
    NSUInteger len;
} Nav;

static Nav
nav_for(NSTextSelectionNavigation *self)
{
    Nav n = {self->_dataSource, nil, @"", 0};
    n.start = n.ds.documentRange.location;
    if ([(id)n.ds isKindOfClass:[NSTextLayoutManager class]]) {
        n.s = [(NSTextLayoutManager *)n.ds _uifString];
    } else if (n.start) {
        NSMutableString *m = [NSMutableString string];
        [n.ds enumerateSubstringsFromLocation:n.start
                                      options:NSStringEnumerationByComposedCharacterSequences
                                   usingBlock:^(NSString *sub, NSTextRange *r, NSTextRange *e, BOOL *stop) {
                                     if (sub)
                                         [m appendString:sub];
                                   }];
        n.s = m;
    }
    n.len = n.s.length;
    return n;
}

static NSInteger
off(Nav *n, id<NSTextLocation> location)
{
    if (!location || !n->start)
        return NSNotFound;
    NSInteger i = [n->ds offsetFromLocation:n->start toLocation:location];
    return MAX(0, MIN(i, (NSInteger)n->len));
}

static id<NSTextLocation>
loc(Nav *n, NSUInteger i)
{
    return n->start ? [n->ds locationFromLocation:n->start withOffset:(NSInteger)MIN(i, n->len)] : nil;
}

static NSTextRange *
range(Nav *n, NSUInteger a, NSUInteger b)
{
    return [[[NSTextRange alloc] initWithLocation:loc(n, MIN(a, b)) endLocation:loc(n, MAX(a, b))] autorelease];
}

static BOOL
is_separator(unichar c)
{
    return c == '\n' || c == '\r' || c == 0x2029;
}

/* A user-perceived character: a surrogate pair, a base and its combining marks, or \r\n. */
static NSRange
composed(Nav *n, NSUInteger i)
{
    NSString *s = n->s;
    NSUInteger len = n->len;
    if (i >= len)
        return NSMakeRange(len, 0);
    NSCharacterSet *marks = [NSCharacterSet nonBaseCharacterSet];
    NSUInteger a = i;
    while (a > 0 && (CFStringIsSurrogateLowCharacter([s characterAtIndex:a]) || [marks characterIsMember:[s characterAtIndex:a]] ||
                     ([s characterAtIndex:a] == '\n' && [s characterAtIndex:a - 1] == '\r')))
        a--;
    NSUInteger b = a + 1;
    unichar c = [s characterAtIndex:a];
    if (b < len && ((CFStringIsSurrogateHighCharacter(c) && CFStringIsSurrogateLowCharacter([s characterAtIndex:b])) ||
                    (c == '\r' && [s characterAtIndex:b] == '\n')))
        b++;
    while (b < len && [marks characterIsMember:[s characterAtIndex:b]])
        b++;
    return NSMakeRange(a, b - a);
}

static BOOL
is_word(unichar c)
{
    return [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c];
}

/* Lines, through the data source's caret offsets. */
typedef struct {
    NSUInteger start, end; /* the insertion points: end is before any separator */
    NSUInteger next;       /* after the separator (the next line's start) */
    CGFloat *xs;           /* xs[i - start] for start <= i <= end */
} Line;

static BOOL
line_at(Nav *n, NSUInteger at, Line *line)
{
    __block NSUInteger lo = NSUIntegerMax, hi = 0;
    NSMutableDictionary *xs = [NSMutableDictionary dictionary];
    id<NSTextLocation> l = loc(n, at);
    if (!l)
        return NO;
    [n->ds enumerateCaretOffsetsInLineFragmentAtLocation:l
                                              usingBlock:^(CGFloat x, id<NSTextLocation> where, BOOL leading, BOOL *stop) {
                                                NSInteger i = off(n, where);
                                                if (i == NSNotFound)
                                                    return;
                                                lo = MIN(lo, (NSUInteger)i);
                                                hi = MAX(hi, (NSUInteger)i);
                                                if (!xs[@(i)] || leading)
                                                    xs[@(i)] = @(x);
                                              }];
    if (lo == NSUIntegerMax)
        return NO;
    line->start = lo;
    line->end = hi;
    line->next = hi;
    if (hi < n->len && is_separator([n->s characterAtIndex:hi])) {
        line->next = hi + 1;
        if ([n->s characterAtIndex:hi] == '\r' && hi + 1 < n->len && [n->s characterAtIndex:hi + 1] == '\n')
            line->next++;
    }
    line->xs = malloc((hi - lo + 1) * sizeof(CGFloat));
    CGFloat last = 0;
    for (NSUInteger i = lo; i <= hi; i++) {
        NSNumber *x = xs[@(i)];
        line->xs[i - lo] = x ? x.doubleValue : last;
        last = line->xs[i - lo];
    }
    return YES;
}

/* The insertion point nearest x on a line; upstream when past the line's end. */
static NSUInteger
nearest(Nav *n, Line *line, CGFloat x, BOOL *upstream)
{
    NSUInteger best = line->start;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSUInteger i = line->start; i <= line->end; i++) {
        CGFloat d = fabs(line->xs[i - line->start] - x);
        if (d < bestDistance) {
            bestDistance = d;
            best = i;
        }
    }
    if (upstream)
        *upstream = best == line->end && line->end > line->start && x > line->xs[line->end - line->start] &&
                    best < n->len;
    return best;
}

static CGFloat
caret_x(Nav *n, NSUInteger at)
{
    Line line;
    if (!line_at(n, at, &line))
        return 0;
    CGFloat x = line.xs[MIN(MAX(at, line.start), line.end) - line.start];
    free(line.xs);
    return x;
}

/* The paragraph holding character i (with its separator). */
static NSRange
paragraph(Nav *n, NSUInteger i)
{
    NSString *s = n->s;
    NSUInteger a = MIN(i, n->len), b = a;
    while (a > 0 && !is_separator([s characterAtIndex:a - 1]))
        a--;
    while (b < n->len && !is_separator([s characterAtIndex:b]))
        b++;
    if (b < n->len) {
        if ([s characterAtIndex:b] == '\r' && b + 1 < n->len && [s characterAtIndex:b + 1] == '\n')
            b++;
        b++;
    }
    return NSMakeRange(a, b - a);
}

static NSUInteger
content_end(Nav *n, NSRange p)
{
    NSUInteger e = NSMaxRange(p);
    if (e > p.location && is_separator([n->s characterAtIndex:e - 1])) {
        e--;
        if (e > p.location && [n->s characterAtIndex:e] == '\n' && [n->s characterAtIndex:e - 1] == '\r')
            e--;
    }
    return e;
}

/* The sentence holding character i: closing punctuation and the spaces after
 * it end one, as does the paragraph. */
static NSRange
sentence(Nav *n, NSUInteger i)
{
    NSRange p = paragraph(n, i);
    NSString *s = n->s;
    NSUInteger start = p.location, end = NSMaxRange(p), k = start;
    while (k < end) {
        unichar c = [s characterAtIndex:k];
        if (c == '.' || c == '!' || c == '?') {
            NSUInteger j = k + 1;
            while (j < end && ([s characterAtIndex:j] == '.' || [s characterAtIndex:j] == '!' || [s characterAtIndex:j] == '?'))
                j++;
            if (j < end && ([s characterAtIndex:j] == ' ' || [s characterAtIndex:j] == '\t')) {
                while (j < end && ([s characterAtIndex:j] == ' ' || [s characterAtIndex:j] == '\t'))
                    j++;
                if (j < content_end(n, p)) {
                    if (i < j)
                        return NSMakeRange(start, j - start);
                    start = j;
                }
            }
            k = j;
            continue;
        }
        k++;
    }
    return NSMakeRange(start, end - start);
}

/* A run of word characters, of spaces, or a single other character, at i. */
static NSRange
word_run(Nav *n, NSUInteger i)
{
    NSString *s = n->s;
    if (i >= n->len)
        return NSMakeRange(n->len, 0);
    unichar c = [s characterAtIndex:i];
    BOOL (^same)(unichar) = is_word(c)                ? ^BOOL(unichar d) { return is_word(d); }
                            : (c == ' ' || c == '\t') ? ^BOOL(unichar d) { return d == ' ' || d == '\t'; }
                                                      : nil;
    if (!same)
        return composed(n, i);
    NSUInteger a = i, b = i + 1;
    while (a > 0 && same([s characterAtIndex:a - 1]))
        a--;
    while (b < n->len && same([s characterAtIndex:b]))
        b++;
    return NSMakeRange(a, b - a);
}

enum { FORWARD, BACKWARD };

/* Where a caret at h goes; `deleting` keeps a line's start where it is. */
static NSUInteger
move(Nav *n, NSUInteger h, int dir, NSTextSelectionNavigationDestination dest, BOOL deleting, BOOL *upstream)
{
    NSString *s = n->s;
    NSUInteger len = n->len;
    *upstream = NO;
    switch (dest) {
    case NSTextSelectionNavigationDestinationCharacter:
        if (dir == FORWARD)
            return h < len ? NSMaxRange(composed(n, h)) : len;
        return h > 0 ? composed(n, h - 1).location : 0;
    case NSTextSelectionNavigationDestinationWord: {
        NSUInteger i = h;
        if (dir == FORWARD) {
            while (i < len && !is_word([s characterAtIndex:i]))
                i++;
            while (i < len && is_word([s characterAtIndex:i]))
                i++;
        } else {
            while (i > 0 && !is_word([s characterAtIndex:i - 1]))
                i--;
            while (i > 0 && is_word([s characterAtIndex:i - 1]))
                i--;
        }
        return i;
    }
    case NSTextSelectionNavigationDestinationLine: {
        Line line;
        if (!line_at(n, h, &line))
            return h;
        free(line.xs);
        if (dir == FORWARD) {
            /* At a line's end: deleting stops; moving goes on to the next line's end. */
            if (h == line.end && h < len) {
                if (deleting)
                    return h;
                Line next;
                if (!line_at(n, line.next, &next))
                    return h;
                free(next.xs);
                *upstream = YES;
                return next.end;
            }
            *upstream = line.end < len || line.end > line.start;
            if (line.end == len && line.end == line.start)
                *upstream = NO;
            return line.end;
        }
        if (h > line.start || deleting || line.start == 0)
            return line.start;
        Line prev;
        if (!line_at(n, line.start - 1, &prev))
            return line.start;
        free(prev.xs);
        return prev.start;
    }
    case NSTextSelectionNavigationDestinationSentence:
        if (dir == FORWARD)
            return h < len ? NSMaxRange(sentence(n, h)) : len;
        return h > 0 ? sentence(n, h - 1).location : 0;
    case NSTextSelectionNavigationDestinationParagraph: {
        if (dir == FORWARD) {
            if (h >= len)
                return len;
            NSRange p = paragraph(n, h);
            NSUInteger e = content_end(n, p);
            if (h < e)
                return e;
            return NSMaxRange(p) < len ? content_end(n, paragraph(n, NSMaxRange(p))) : len;
        }
        if (h == 0)
            return 0;
        NSRange p = paragraph(n, MIN(h, len - 1));
        if (h > p.location)
            return p.location;
        return paragraph(n, h - 1).location;
    }
    case NSTextSelectionNavigationDestinationContainer:
    case NSTextSelectionNavigationDestinationDocument:
    default:
        return dir == FORWARD ? len : 0;
    }
}

/* A caret at h moved a line up or down, keeping x. */
static NSUInteger
move_vertically(Nav *n, NSUInteger h, BOOL down, CGFloat x, BOOL *upstream)
{
    *upstream = NO;
    Line line;
    if (!line_at(n, h, &line))
        return h;
    free(line.xs);
    NSUInteger target;
    if (down) {
        if (line.next > n->len || (line.next == line.end && line.next >= n->len))
            return n->len;
        target = line.next;
    } else {
        if (line.start == 0)
            return 0;
        target = line.start - 1;
    }
    Line other;
    if (!line_at(n, target, &other) || other.start == line.start)
        return down ? n->len : 0;
    NSUInteger i = nearest(n, &other, x, upstream);
    free(other.xs);
    return i;
}

- (NSTextSelection *)destinationSelectionForTextSelection:(NSTextSelection *)textSelection
                                               direction:(NSTextSelectionNavigationDirection)direction
                                             destination:(NSTextSelectionNavigationDestination)destination
                                               extending:(BOOL)extending
                                                confined:(BOOL)confined
{
    Nav n = nav_for(self);
    NSTextRange *r = textSelection.textRanges.firstObject;
    if (!r || !n.start)
        return nil;
    NSUInteger a = (NSUInteger)off(&n, r.location), b = (NSUInteger)off(&n, r.endLocation);
    BOOL vertical = direction == NSTextSelectionNavigationDirectionUp || direction == NSTextSelectionNavigationDirectionDown;
    BOOL down = direction == NSTextSelectionNavigationDirectionDown;
    int dir = (direction == NSTextSelectionNavigationDirectionForward || direction == NSTextSelectionNavigationDirectionRight ||
               direction == NSTextSelectionNavigationDirectionDown)
                  ? FORWARD
                  : BACKWARD;
    BOOL lineMove = vertical && destination == NSTextSelectionNavigationDestinationCharacter;
    /* The anchor stays; the head moves. */
    NSUInteger anchor = a, head = b;
    NSInteger anchored = off(&n, [textSelection _uifAnchor]);
    if (anchored != NSNotFound && (NSUInteger)anchored == b) {
        anchor = b;
        head = a;
    }
    if (!extending && a != b) {
        if (!lineMove && destination == NSTextSelectionNavigationDestinationCharacter)
            return [[[NSTextSelection alloc] initWithRange:range(&n, dir == FORWARD ? b : a, dir == FORWARD ? b : a)
                                                  affinity:NSTextSelectionAffinityDownstream
                                               granularity:NSTextSelectionGranularityCharacter] autorelease];
        head = dir == FORWARD ? b : a;
    }
    BOOL upstream = NO;
    NSUInteger to;
    if (lineMove) {
        CGFloat x = textSelection.anchorPositionOffset > 0 ? textSelection.anchorPositionOffset : caret_x(&n, head);
        to = move_vertically(&n, head, down, x, &upstream);
    } else {
        to = move(&n, head, dir, destination, NO, &upstream);
    }
    NSTextSelection *out;
    if (extending) {
        out = [[[NSTextSelection alloc] initWithRange:range(&n, anchor, to)
                                             affinity:to < anchor ? NSTextSelectionAffinityUpstream : NSTextSelectionAffinityDownstream
                                          granularity:NSTextSelectionGranularityCharacter] autorelease];
        if (to != anchor)
            [out _uifSetAnchor:loc(&n, anchor)];
    } else {
        out = [[[NSTextSelection alloc] initWithRange:range(&n, to, to)
                                             affinity:upstream ? NSTextSelectionAffinityUpstream : NSTextSelectionAffinityDownstream
                                          granularity:NSTextSelectionGranularityCharacter] autorelease];
    }
    return out;
}

- (NSArray *)textSelectionsInteractingAtPoint:(CGPoint)point
                        inContainerAtLocation:(id<NSTextLocation>)containerLocation
                                      anchors:(NSArray *)anchors
                                    modifiers:(NSTextSelectionNavigationModifier)modifiers
                                    selecting:(BOOL)selecting
                                       bounds:(CGRect)bounds
{
    Nav n = nav_for(self);
    if (!n.start)
        return @[];
    NSTextRange *lineRange = [n.ds lineFragmentRangeForPoint:point inContainerAtLocation:containerLocation];
    NSUInteger at = 0;
    BOOL upstream = NO;
    CGFloat x = 0;
    Line line;
    if (lineRange && line_at(&n, (NSUInteger)off(&n, lineRange.location), &line)) {
        at = nearest(&n, &line, point.x, &upstream);
        x = line.xs[at - line.start];
        free(line.xs);
    }
    NSTextSelection *anchorSelection = anchors.firstObject;
    NSTextRange *ar = anchorSelection.textRanges.firstObject;
    NSTextSelection *out;
    if ((modifiers & NSTextSelectionNavigationModifierExtend) && ar) {
        NSInteger anchor = off(&n, [anchorSelection _uifAnchor]);
        if (anchor == NSNotFound) {
            NSUInteger a = (NSUInteger)off(&n, ar.location), b = (NSUInteger)off(&n, ar.endLocation);
            anchor = (NSInteger)(at >= a ? a : b);
        }
        out = [[[NSTextSelection alloc] initWithRange:range(&n, (NSUInteger)anchor, at)
                                             affinity:upstream ? NSTextSelectionAffinityUpstream : NSTextSelectionAffinityDownstream
                                          granularity:NSTextSelectionGranularityCharacter] autorelease];
        [out _uifSetAnchor:loc(&n, (NSUInteger)anchor)];
        out.anchorPositionOffset = caret_x(&n, (NSUInteger)anchor);
    } else {
        out = [[[NSTextSelection alloc] initWithRange:range(&n, at, at)
                                             affinity:upstream ? NSTextSelectionAffinityUpstream : NSTextSelectionAffinityDownstream
                                          granularity:NSTextSelectionGranularityCharacter] autorelease];
        out.anchorPositionOffset = x;
    }
    [out _uifSetTransient:selecting];
    return @[ out ];
}

static NSRange
granular_range(Nav *n, NSTextSelectionGranularity granularity, NSUInteger at)
{
    NSUInteger last = n->len ? n->len - 1 : 0;
    switch (granularity) {
    case NSTextSelectionGranularityWord:
        return word_run(n, MIN(at, last));
    case NSTextSelectionGranularityParagraph:
        return paragraph(n, MIN(at, last));
    case NSTextSelectionGranularitySentence:
        return n->len ? sentence(n, MIN(at, last)) : NSMakeRange(0, 0);
    case NSTextSelectionGranularityCharacter:
        return composed(n, at);
    default:
        return NSMakeRange(at, 0);
    }
}

/*
 * As Apple's: a caret's character, word, sentence or paragraph; a line
 * only when it ends a paragraph (with its separator; a wrapped line's caret,
 * like a selected range, stays as it is); nothing to extend at the text's end.
 */
- (NSTextSelection *)textSelectionForSelectionGranularity:(NSTextSelectionGranularity)granularity
                                   enclosingTextSelection:(NSTextSelection *)textSelection
{
    Nav n = nav_for(self);
    NSTextRange *r = textSelection.textRanges.firstObject;
    if (!r || !n.start)
        return textSelection;
    NSUInteger a = (NSUInteger)off(&n, r.location), b = (NSUInteger)off(&n, r.endLocation);
    NSRange g;
    if (granularity == NSTextSelectionGranularityLine) {
        Line line;
        if (b > a || !line_at(&n, a, &line))
            return textSelection;
        free(line.xs);
        if (line.next == line.end)
            return textSelection;
        g = NSMakeRange(line.start, line.next - line.start);
    } else if (granularity == NSTextSelectionGranularityCharacter && b > a) {
        g = NSMakeRange(a, b - a);
    } else {
        if (a >= n.len && granularity == NSTextSelectionGranularitySentence)
            return textSelection;
        g = a >= n.len ? NSMakeRange(n.len, 0) : granular_range(&n, granularity, a);
        if (b > a)
            g = NSUnionRange(g, granular_range(&n, granularity, b - 1));
    }
    return [[[NSTextSelection alloc] initWithRange:range(&n, g.location, NSMaxRange(g))
                                          affinity:textSelection.affinity
                                       granularity:granularity] autorelease];
}

- (NSTextSelection *)textSelectionForSelectionGranularity:(NSTextSelectionGranularity)granularity
                                           enclosingPoint:(CGPoint)point
                                    inContainerAtLocation:(id<NSTextLocation>)location
{
    Nav n = nav_for(self);
    if (!n.start)
        return nil;
    NSTextRange *lineRange = [n.ds lineFragmentRangeForPoint:point inContainerAtLocation:location];
    Line line;
    if (!lineRange || !line_at(&n, (NSUInteger)off(&n, lineRange.location), &line))
        return nil;
    /* The character under the point. */
    NSUInteger at = line.start;
    for (NSUInteger i = line.start; i < line.end; i++)
        if (point.x >= line.xs[i - line.start])
            at = i;
    free(line.xs);
    NSRange g = granularity == NSTextSelectionGranularityWord ? word_run(&n, at)
                : granularity == NSTextSelectionGranularityCharacter
                    ? composed(&n, at)
                    : granular_range(&n, granularity, at);
    return [[[NSTextSelection alloc] initWithRange:range(&n, g.location, NSMaxRange(g))
                                          affinity:NSTextSelectionAffinityDownstream
                                       granularity:granularity] autorelease];
}

- (id<NSTextLocation>)resolvedInsertionLocationForTextSelection:(NSTextSelection *)textSelection
                                               writingDirection:(NSTextSelectionNavigationWritingDirection)writingDirection
{
    NSTextRange *r = textSelection.textRanges.firstObject;
    return writingDirection == NSTextSelectionNavigationWritingDirectionRightToLeft ? r.endLocation : r.location;
}

- (NSArray *)deletionRangesForTextSelection:(NSTextSelection *)textSelection
                                  direction:(NSTextSelectionNavigationDirection)direction
                                destination:(NSTextSelectionNavigationDestination)destination
                        allowsDecomposition:(BOOL)allowsDecomposition
{
    Nav n = nav_for(self);
    NSMutableArray *out = [NSMutableArray array];
    for (NSTextRange *r in textSelection.textRanges) {
        if (!r.isEmpty || !n.start) {
            [out addObject:r];
            continue;
        }
        NSUInteger h = (NSUInteger)off(&n, r.location);
        int dir = (direction == NSTextSelectionNavigationDirectionForward || direction == NSTextSelectionNavigationDirectionRight ||
                   direction == NSTextSelectionNavigationDirectionDown)
                      ? FORWARD
                      : BACKWARD;
        BOOL upstream;
        NSUInteger to = move(&n, h, dir, destination, YES, &upstream);
        if (allowsDecomposition && destination == NSTextSelectionNavigationDestinationCharacter && dir == BACKWARD && h > 0)
            to = h - 1;
        [out addObject:range(&n, h, to)];
    }
    return out;
}

@end
