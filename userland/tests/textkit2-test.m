/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-textkit2-test: TextKit 2 without a screen. Locations and ranges;
 * NSTextContentStorage's paragraphs, enumeration, delegates and editing;
 * NSTextLayoutManager's layout fragments and line fragments, text segments,
 * rendering attributes, the viewport controller and its delegate calls;
 * selections and NSTextSelectionNavigation's moves, deletions and clicks;
 * that TextKit 1 and 2 lay text out alike; and NSTextView on TextKit 2: which
 * text system each initializer, nibs, archives and the field editor use,
 * editing and geometry matching a TextKit 1 view, and the switch to TextKit 1
 * when its layoutManager is asked for.
 *
 * Prints everything; run it against Apple's frameworks and Finch's
 * (DYLD_FRAMEWORK_PATH, FINCH_FONT_DIRS) and diff all but the first line,
 * which is where NSTextLayoutManager came from. Text uses Roboto, registered
 * from a file, so both lay it out alike.
 *
 *   finch-textkit2-test [Roboto-Regular.ttf] [appkit-text-test.nib]
 */
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

static void out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
out(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", [s UTF8String]);
}

static NSFont *font;

static NSString *
R(CGRect r)
{
    return NSStringFromRect(NSRectFromCGRect(r));
}

static NSString *
P(CGPoint p)
{
    return NSStringFromPoint(NSPointFromCGPoint(p));
}

static NSString *
Rg(NSRange r)
{
    return NSStringFromRange(r);
}

/* A string with its line breaks visible. */
static NSString *
V(NSString *s)
{
    NSMutableString *m = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\n')
            [m appendString:@"\\n"];
        else if (c == '\r')
            [m appendString:@"\\r"];
        else
            [m appendFormat:@"%C", c];
    }
    return m;
}

/* Pointers out of descriptions. */
static NSString *
masked(NSString *s)
{
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-f]+" options:0 error:NULL];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"0x?"];
}

static NSString *
ranges(NSArray<NSTextRange *> *a)
{
    NSMutableArray *m = [NSMutableArray array];
    for (NSTextRange *r in a)
        [m addObject:r.description];
    return [NSString stringWithFormat:@"[%@]", [m componentsJoinedByString:@", "]];
}

static NSString *
sel(NSTextSelection *s)
{
    if (!s)
        return @"nil";
    return [NSString stringWithFormat:@"%@%@", ranges(s.textRanges), s.affinity == NSTextSelectionAffinityUpstream ? @"u" : @""];
}

/* A content storage and text layout manager over some text in a container. */
typedef struct {
    NSTextContentStorage *cs;
    NSTextLayoutManager *tlm;
    NSTextContainer *tc;
} TK2;

static TK2
make(NSString *text, CGFloat width, NSDictionary *attrs)
{
    TK2 k;
    k.cs = [NSTextContentStorage new];
    k.tlm = [NSTextLayoutManager new];
    [k.cs addTextLayoutManager:k.tlm];
    k.tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(width, 0)];
    k.tlm.textContainer = k.tc;
    [k.cs.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs ?: @{NSFontAttributeName : font}]];
    return k;
}

static id<NSTextLocation>
L(TK2 *k, NSInteger offset)
{
    return [k->cs locationFromLocation:k->cs.documentRange.location withOffset:offset];
}

static NSTextRange *
TR(TK2 *k, NSInteger a, NSInteger b)
{
    return [[NSTextRange alloc] initWithLocation:L(k, a) endLocation:L(k, b)];
}

static void
dump_fragments(TK2 *k, BOOL lines)
{
    [k->tlm enumerateTextLayoutFragmentsFromLocation:nil
                                             options:0
                                          usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                            out(@"  fragment %@ frame %@ state %ld element %@ lines %lu", f.rangeInElement,
                                                R(f.layoutFragmentFrame), (long)f.state, [f.textElement className],
                                                (unsigned long)f.textLineFragments.count);
                                            if (lines)
                                                for (NSTextLineFragment *l in f.textLineFragments)
                                                    out(@"    line %@ origin %@ chars %@ '%@' of %lu", R(l.typographicBounds),
                                                        P(l.glyphOrigin), Rg(l.characterRange),
                                                        V([l.attributedString.string substringWithRange:l.characterRange]),
                                                        (unsigned long)l.attributedString.length);
                                            return YES;
                                          }];
}

#pragma mark - Ranges

@interface Loc : NSObject <NSTextLocation>
@property NSInteger v;
@end

@implementation Loc
- (NSComparisonResult)compare:(Loc *)o
{
    return self.v < o.v ? NSOrderedAscending : self.v > o.v ? NSOrderedDescending : NSOrderedSame;
}
- (NSString *)description { return [NSString stringWithFormat:@"L%ld", (long)self.v]; }
@end

static Loc *
loc(NSInteger v)
{
    Loc *l = [Loc new];
    l.v = v;
    return l;
}

static void
test_ranges(void)
{
    out(@"[ranges]");
    NSTextRange *r = [[NSTextRange alloc] initWithLocation:loc(2) endLocation:loc(8)];
    out(@"range %@ empty %d location %@ end %@ class %@", r, r.isEmpty, r.location, r.endLocation, r.className);
    out(@"debug %@", masked(r.debugDescription));
    out(@"reversed %@", [[NSTextRange alloc] initWithLocation:loc(8) endLocation:loc(2)]);
    NSTextRange *e = [[NSTextRange alloc] initWithLocation:loc(5)];
    out(@"empty %@ %d end is location %d", e, e.isEmpty, e.endLocation == e.location);
    out(@"contains 2 %d 8 %d 5 %d 1 %d; empty contains 5 %d", [r containsLocation:loc(2)], [r containsLocation:loc(8)],
        [r containsLocation:loc(5)], [r containsLocation:loc(1)], [e containsLocation:loc(5)]);
    NSTextRange *r2 = [[NSTextRange alloc] initWithLocation:loc(6) endLocation:loc(12)];
    NSTextRange *r3 = [[NSTextRange alloc] initWithLocation:loc(8) endLocation:loc(12)];
    NSTextRange *r4 = [[NSTextRange alloc] initWithLocation:loc(10) endLocation:loc(12)];
    out(@"intersection %@ %@ %@ empty %@", [r textRangeByIntersectingWithTextRange:r2], [r textRangeByIntersectingWithTextRange:r3],
        [r textRangeByIntersectingWithTextRange:r4], [r textRangeByIntersectingWithTextRange:e]);
    out(@"union %@ %@ %@", [r textRangeByFormingUnionWithTextRange:r4], [r textRangeByFormingUnionWithTextRange:e],
        [e textRangeByFormingUnionWithTextRange:r2]);
    out(@"intersects %d %d %d %d", [r intersectsWithTextRange:r2], [r intersectsWithTextRange:r3], [r intersectsWithTextRange:r4],
        [r intersectsWithTextRange:e]);
    out(@"containsRange %d %d %d", [r containsRange:[[NSTextRange alloc] initWithLocation:loc(3) endLocation:loc(8)]],
        [r containsRange:r2], [r containsRange:e]);
    out(@"equal (locations compare equal, not isEqual) %d same %d", [r isEqualToTextRange:[[NSTextRange alloc] initWithLocation:loc(2)
                                                                                                                 endLocation:loc(8)]],
        [r isEqualToTextRange:r]);
    TK2 k = make(@"0123456789", 100, nil);
    NSTextRange *c1 = TR(&k, 2, 5), *c2 = TR(&k, 2, 5);
    out(@"countable equal %d isEqual %d hash %d", [c1 isEqualToTextRange:c2], [c1 isEqual:c2], c1.hash == c2.hash);
    id<NSTextLocation> l3 = L(&k, 3);
    out(@"location %@ (%@) debug %@ compare %ld %ld %ld equal %d", l3, [(id)l3 className], [(id)l3 debugDescription],
        (long)[l3 compare:L(&k, 3)], (long)[l3 compare:L(&k, 4)], (long)[l3 compare:L(&k, 1)], [(id)l3 isEqual:L(&k, 3)]);
}

#pragma mark - Content storage

@interface CSDelegate : NSObject <NSTextContentStorageDelegate>
@property NSMutableArray *log;
@property NSInteger reject;
@end

@implementation CSDelegate
- (NSTextParagraph *)textContentStorage:(NSTextContentStorage *)cs textParagraphWithRange:(NSRange)range
{
    [self.log addObject:[NSString stringWithFormat:@"paragraph %@", Rg(range)]];
    return nil;
}
- (BOOL)textContentManager:(NSTextContentManager *)m shouldEnumerateTextElement:(NSTextElement *)e options:(NSTextContentManagerEnumerationOptions)o
{
    NSInteger start = [m offsetFromLocation:m.documentRange.location toLocation:e.elementRange.location];
    return start != self.reject;
}
@end

static NSString *
elements(NSArray<NSTextElement *> *a)
{
    NSMutableArray *m = [NSMutableArray array];
    for (NSTextElement *e in a)
        [m addObject:e.elementRange.description];
    return [NSString stringWithFormat:@"[%@]", [m componentsJoinedByString:@", "]];
}

static void
test_content_storage(void)
{
    out(@"[content storage]");
    NSTextContentStorage *cs = [NSTextContentStorage new];
    out(@"new: storage %@ attributedString is it %d document %@ observer is it %d transaction %d sync %d %d markers %d",
        cs.textStorage.className, cs.attributedString == cs.textStorage, cs.documentRange,
        cs.textStorage.textStorageObserver == cs, cs.hasEditingTransaction, cs.automaticallySynchronizesTextLayoutManagers,
        cs.automaticallySynchronizesToBackingStore, cs.includesTextListMarkers);
    NSTextStorage *oldStorage = cs.textStorage;
    cs.attributedString = [[NSAttributedString alloc] initWithString:@"ab\ncd\r\nef"];
    out(@"set attributedString: storage %@ old storage's observer %@ attributedString '%@' is a storage %d", cs.textStorage,
        [(id)oldStorage.textStorageObserver className], V(cs.attributedString.string), [cs.attributedString isKindOfClass:[NSTextStorage class]]);
    NSTextRange *d = cs.documentRange;
    out(@"document %@ location %@ end %@", d, [(id)d.location className], d.endLocation);
    out(@"offsets: +3 %@ -1 %@ +10 %@ +9 %@ end-to-start %ld", [cs locationFromLocation:d.location withOffset:3],
        [cs locationFromLocation:d.location withOffset:-1], [cs locationFromLocation:d.location withOffset:10],
        [cs locationFromLocation:d.location withOffset:9], (long)[cs offsetFromLocation:d.endLocation toLocation:d.location]);
    __block NSMutableArray *seen = [NSMutableArray array];
    id ret = [cs enumerateTextElementsFromLocation:nil
                                           options:0
                                        usingBlock:^BOOL(NSTextElement *e) {
                                          NSTextParagraph *p = (NSTextParagraph *)e;
                                          out(@"  %@ %@ '%@' content %@ separator %@ manager %d children %lu parent %@ represented %d",
                                              e.className, e.elementRange, V(p.attributedString.string),
                                              p.paragraphContentRange, p.paragraphSeparatorRange, e.textContentManager == cs,
                                              (unsigned long)e.childElements.count, e.parentElement, e.isRepresentedElement);
                                          out(@"    %@", masked(e.description));
                                          [seen addObject:e];
                                          return YES;
                                        }];
    out(@"enumeration returned %@", ret);
    NSTextElement *again = [[cs textElementsForRange:d] firstObject];
    out(@"elements are kept %d", again == seen.firstObject);
    TK2 k = {cs, nil, nil};
    for (NSNumber *n in @[ @0, @2, @3, @4, @7, @9 ]) {
        NSMutableArray *f = [NSMutableArray array], *b = [NSMutableArray array];
        id rf = [cs enumerateTextElementsFromLocation:L(&k, n.integerValue)
                                              options:0
                                           usingBlock:^BOOL(NSTextElement *e) {
                                             [f addObject:e];
                                             return YES;
                                           }];
        id rb = [cs enumerateTextElementsFromLocation:L(&k, n.integerValue)
                                              options:NSTextContentManagerEnumerationOptionsReverse
                                           usingBlock:^BOOL(NSTextElement *e) {
                                             [b addObject:e];
                                             return YES;
                                           }];
        out(@"from %@: forward %@ -> %@ reverse %@ -> %@", n, elements(f), rf, elements(b), rb);
    }
    id stop = [cs enumerateTextElementsFromLocation:nil
                                            options:0
                                         usingBlock:^BOOL(NSTextElement *e) {
                                           return NO;
                                         }];
    id rstop = [cs enumerateTextElementsFromLocation:nil
                                             options:NSTextContentManagerEnumerationOptionsReverse
                                          usingBlock:^BOOL(NSTextElement *e) {
                                            return NO;
                                          }];
    out(@"stopped at once: %@ reverse %@", stop, rstop);
    for (NSArray *rr in @[ @[ @0, @3 ], @[ @1, @4 ], @[ @0, @4 ], @[ @3, @9 ], @[ @2, @9 ], @[ @0, @9 ], @[ @3, @3 ] ])
        out(@"elements for %@: %@", TR(&k, [rr[0] integerValue], [rr[1] integerValue]),
            elements([cs textElementsForRange:TR(&k, [rr[0] integerValue], [rr[1] integerValue])]));
    out(@"adjusted %@ %@", [cs adjustedRangeFromRange:TR(&k, 1, 6) forEditingTextSelection:YES],
        [cs adjustedRangeFromRange:TR(&k, 6, 6) forEditingTextSelection:NO]);
    NSTextContentStorage *cs2 = [NSTextContentStorage new];
    [cs2.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@"a\U0001F600b"]];
    TK2 k2 = {cs2, nil, nil};
    out(@"adjusted inside a surrogate pair %@ %@", [cs2 adjustedRangeFromRange:TR(&k2, 2, 2) forEditingTextSelection:YES],
        [cs2 adjustedRangeFromRange:TR(&k2, 0, 2) forEditingTextSelection:NO]);
    NSTextParagraph *first = seen.firstObject;
    out(@"attributed string for element '%@' element for string %@ '%@' range %@", V([cs attributedStringForTextElement:first].string),
        [cs textElementForAttributedString:[[NSAttributedString alloc] initWithString:@"x"]].className,
        ((NSTextParagraph *)[cs textElementForAttributedString:[[NSAttributedString alloc] initWithString:@"x"]]).attributedString.string,
        [cs textElementForAttributedString:[[NSAttributedString alloc] initWithString:@"x"]].elementRange);
    NSTextParagraph *lone = [[NSTextParagraph alloc] initWithAttributedString:[[NSAttributedString alloc] initWithString:@"lone\n"]];
    out(@"lone paragraph range %@ content %@ separator %@ manager %@", lone.elementRange, lone.paragraphContentRange,
        lone.paragraphSeparatorRange, lone.textContentManager);

    /* Layout managers. */
    NSTextLayoutManager *a = [NSTextLayoutManager new], *b = [NSTextLayoutManager new];
    [cs addTextLayoutManager:a];
    out(@"added: managers %lu primary %d manager's content manager %d", (unsigned long)cs.textLayoutManagers.count,
        cs.primaryTextLayoutManager == a, a.textContentManager == cs);
    [cs addTextLayoutManager:b];
    cs.primaryTextLayoutManager = b;
    out(@"two: %lu primary b %d", (unsigned long)cs.textLayoutManagers.count, cs.primaryTextLayoutManager == b);
    [cs removeTextLayoutManager:b];
    out(@"removed b: %lu primary %@ b's content manager %@", (unsigned long)cs.textLayoutManagers.count, cs.primaryTextLayoutManager,
        b.textContentManager);
    __block BOOL inside = NO;
    [cs performEditingTransactionUsingBlock:^{
      inside = cs.hasEditingTransaction;
    }];
    out(@"transaction: inside %d after %d", inside, cs.hasEditingTransaction);

    /* The delegate, and paragraphs kept across edits. */
    CSDelegate *del = [CSDelegate new];
    del.log = [NSMutableArray array];
    del.reject = -1;
    NSTextContentStorage *c3 = [NSTextContentStorage new];
    NSTextLayoutManager *t3 = [NSTextLayoutManager new];
    [c3 addTextLayoutManager:t3];
    t3.textContainer = [[NSTextContainer alloc] initWithSize:NSMakeSize(200, 0)];
    c3.delegate = del;
    [c3.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@"one\ntwo\nthree\nfour"]];
    TK2 k3 = {c3, t3, t3.textContainer};
    [t3 ensureLayoutForRange:c3.documentRange];
    NSArray *before = [c3 textElementsForRange:c3.documentRange];
    out(@"delegate made %@", [del.log componentsJoinedByString:@"; "]);
    [del.log removeAllObjects];
    [c3.textStorage replaceCharactersInRange:NSMakeRange(5, 1) withString:@"W"];
    [t3 ensureLayoutForRange:c3.documentRange];
    NSArray *after = [c3 textElementsForRange:c3.documentRange];
    out(@"edit inside 'two': remade %@; kept %d %d %d %d; ranges %@", [del.log componentsJoinedByString:@"; "], before[0] == after[0],
        before[1] == after[1], before[2] == after[2], before[3] == after[3], elements(after));
    [del.log removeAllObjects];
    [c3.textStorage replaceCharactersInRange:NSMakeRange(0, 0) withString:@"zero\n"];
    [t3 ensureLayoutForRange:c3.documentRange];
    NSArray *after2 = [c3 textElementsForRange:c3.documentRange];
    out(@"insert a paragraph first: remade %@; old ones kept %d %d %d %d; ranges %@", [del.log componentsJoinedByString:@"; "],
        after2[1] == after[0], after2[2] == after[1], after2[3] == after[2], after2[4] == after[3], elements(after2));
    [del.log removeAllObjects];
    [c3.textStorage addAttribute:NSForegroundColorAttributeName value:NSColor.redColor range:NSMakeRange(9, 2)];
    [t3 ensureLayoutForRange:c3.documentRange];
    NSArray *after3 = [c3 textElementsForRange:c3.documentRange];
    out(@"attributes in 'two': remade %@; kept %d %d %d", [del.log componentsJoinedByString:@"; "], after3[0] == after2[0],
        after3[1] == after2[1], after3[3] == after2[3]);
    [del.log removeAllObjects];
    [c3.textStorage replaceCharactersInRange:NSMakeRange(8, 1) withString:@""];
    [t3 ensureLayoutForRange:c3.documentRange];
    out(@"join two paragraphs: remade %@; ranges %@", [del.log componentsJoinedByString:@"; "],
        elements([c3 textElementsForRange:c3.documentRange]));
    del.reject = 4;
    [del.log removeAllObjects];
    NSMutableArray *got = [NSMutableArray array];
    [c3 enumerateTextElementsFromLocation:nil
                                  options:0
                               usingBlock:^BOOL(NSTextElement *e) {
                                 [got addObject:e];
                                 return YES;
                               }];
    out(@"delegate skips the paragraph at 4: %@", elements(got));
    del.reject = -1;
    (void)k3;
}

#pragma mark - Layout

static void
test_layout(void)
{
    out(@"[layout]");
    NSString *text = @"Hello world, this is a test of wrapping text in TextKit two.\nSecond para\n\nFourth\n";
    TK2 k = make(text, 200, nil);
    out(@"container %@ padding %g text layout manager %d viewport %@", NSStringFromSize(k.tc.size), k.tc.lineFragmentPadding,
        k.tc.textLayoutManager == k.tlm, k.tlm.textViewportLayoutController.className);
    out(@"defaults: font leading %d hyphenation %d suspicious %d natural %d queue %@ delegate %@ selections %@ navigation %@ source %d",
        k.tlm.usesFontLeading, k.tlm.usesHyphenation, k.tlm.limitsLayoutForSuspiciousContents,
        k.tlm.resolvesNaturalAlignmentWithBaseWritingDirection, k.tlm.layoutQueue, k.tlm.delegate, k.tlm.textSelections,
        k.tlm.textSelectionNavigation.className, k.tlm.textSelectionNavigation.textSelectionDataSource == k.tlm);
    out(@"link attributes %@", [[NSTextLayoutManager.linkRenderingAttributes allKeys] sortedArrayUsingSelector:@selector(compare:)]);
    out(@"usage before layout %@", R(k.tlm.usageBoundsForTextContainer));
    out(@"not laid out:");
    [k.tlm enumerateTextLayoutFragmentsFromLocation:nil
                                            options:0
                                         usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                           out(@"  fragment %@ state %ld", f.rangeInElement, (long)f.state);
                                           return YES;
                                         }];
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    out(@"usage %@", R(k.tlm.usageBoundsForTextContainer));
    dump_fragments(&k, YES);
    NSTextLayoutFragment *second = [k.tlm textLayoutFragmentForLocation:L(&k, 65)];
    out(@"description %@", masked(second.description));
    out(@"surface of a one-line fragment %@ of an empty paragraph %@", R(second.renderingSurfaceBounds),
        R([k.tlm textLayoutFragmentForLocation:L(&k, 73)].renderingSurfaceBounds));
    out(@"fragment manager %d element %d margins %g %g %g %g providers %lu", second.textLayoutManager == k.tlm,
        second.textElement != nil, second.leadingPadding, second.trailingPadding, second.topMargin, second.bottomMargin,
        (unsigned long)second.textAttachmentViewProviders.count);
    NSMutableArray *rev = [NSMutableArray array];
    id r1 = [k.tlm enumerateTextLayoutFragmentsFromLocation:k.cs.documentRange.endLocation
                                                    options:NSTextLayoutFragmentEnumerationOptionsReverse
                                                 usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                                   [rev addObject:f.rangeInElement.description];
                                                   return YES;
                                                 }];
    out(@"reverse %@ returned %@", [rev componentsJoinedByString:@" "], r1);
    for (NSNumber *n in @[ @0, @65, @73, @74 ]) {
        NSMutableArray *f = [NSMutableArray array], *b = [NSMutableArray array];
        id rf = [k.tlm enumerateTextLayoutFragmentsFromLocation:L(&k, n.integerValue)
                                                        options:0
                                                     usingBlock:^BOOL(NSTextLayoutFragment *x) {
                                                       [f addObject:x.rangeInElement.description];
                                                       return YES;
                                                     }];
        id rb = [k.tlm enumerateTextLayoutFragmentsFromLocation:L(&k, n.integerValue)
                                                        options:NSTextLayoutFragmentEnumerationOptionsReverse
                                                     usingBlock:^BOOL(NSTextLayoutFragment *x) {
                                                       [b addObject:x.rangeInElement.description];
                                                       return YES;
                                                     }];
        out(@"from %@: %@ -> %@; reverse %@ -> %@", n, [f componentsJoinedByString:@" "], rf, [b componentsJoinedByString:@" "], rb);
    }
    id first = [k.tlm enumerateTextLayoutFragmentsFromLocation:nil
                                                       options:0
                                                    usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                                      return NO;
                                                    }];
    out(@"stopped at once %@", first);
    for (int y = -5; y < 120; y += 10)
        out(@"at y %d: %@", y, [k.tlm textLayoutFragmentForPosition:CGPointMake(10, y)].rangeInElement);
    for (NSNumber *n in @[ @0, @60, @61, @73, @80, @81 ])
        out(@"for location %@: %@", n, [k.tlm textLayoutFragmentForLocation:L(&k, n.integerValue)].rangeInElement);
    NSTextLayoutFragment *f0 = [k.tlm textLayoutFragmentForLocation:L(&k, 0)];
    out(@"line for offset 20 %@ exact 40 %@ near 40 %@", Rg([f0 textLineFragmentForVerticalOffset:20 requiresExactMatch:YES].characterRange),
        [f0 textLineFragmentForVerticalOffset:40 requiresExactMatch:YES],
        Rg([f0 textLineFragmentForVerticalOffset:40 requiresExactMatch:NO].characterRange));
    out(@"line for location 31 %@ upstream %@", Rg([f0 textLineFragmentForTextLocation:L(&k, 31) isUpstreamAffinity:NO].characterRange),
        Rg([f0 textLineFragmentForTextLocation:L(&k, 31) isUpstreamAffinity:YES].characterRange));

    /* Line fragments. */
    NSTextLineFragment *l0 = f0.textLineFragments[0], *l1 = f0.textLineFragments[1];
    out(@"line %@", masked(l0.description));
    for (NSInteger i = 0; i <= 10; i += 2)
        out(@"location of %ld: %@", (long)i, P([l0 locationForCharacterAtIndex:i]));
    for (int x = -5; x < 190; x += 15)
        out(@"index at x %d: %ld fraction %.3f", x, (long)[l0 characterIndexForPoint:CGPointMake(x, 5)],
            [l0 fractionOfDistanceThroughGlyphForPoint:CGPointMake(x, 5)]);
    out(@"second line: location of 31 %@ index at 0 %ld at 300 %ld", P([l1 locationForCharacterAtIndex:31]),
        (long)[l1 characterIndexForPoint:CGPointMake(0, 5)], (long)[l1 characterIndexForPoint:CGPointMake(300, 5)]);
    NSTextLineFragment *lone = [[NSTextLineFragment alloc] initWithString:@"Hello" attributes:@{NSFontAttributeName : font}
                                                                    range:NSMakeRange(0, 5)];
    NSTextLineFragment *lone2 = [[NSTextLineFragment alloc]
        initWithAttributedString:[[NSAttributedString alloc] initWithString:@"Hello world" attributes:@{NSFontAttributeName : font}]
                           range:NSMakeRange(6, 5)];
    out(@"made alone: %@ %@ '%@' %@; %@ %@ location %@ index %ld", R(lone.typographicBounds), P(lone.glyphOrigin),
        lone.attributedString.string, Rg(lone.characterRange), R(lone2.typographicBounds), Rg(lone2.characterRange),
        P([lone2 locationForCharacterAtIndex:8]), (long)[lone2 characterIndexForPoint:CGPointMake(20, 5)]);

    /* Paragraph styles. */
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    ps.paragraphSpacing = 7;
    ps.lineSpacing = 3;
    TK2 c = make(@"center me please and wrap this long line\nnext", 150,
                 @{NSFontAttributeName : font, NSParagraphStyleAttributeName : ps});
    [c.tlm ensureLayoutForRange:c.cs.documentRange];
    out(@"centered, spaced: usage %@", R(c.tlm.usageBoundsForTextContainer));
    dump_fragments(&c, YES);

    /* Empty texts. */
    TK2 e = make(@"", 300, nil);
    [e.tlm ensureLayoutForRange:e.cs.documentRange];
    out(@"empty:");
    dump_fragments(&e, YES);
    NSMutableString *m = [NSMutableString string];
    [e.tlm enumerateTextSegmentsInRange:e.cs.documentRange
                                   type:NSTextLayoutManagerSegmentTypeStandard
                                options:0
                             usingBlock:^BOOL(NSTextRange *r, CGRect frame, CGFloat baseline, NSTextContainer *tc) {
                               [m appendFormat:@" %@ %@ %g", r, R(frame), baseline];
                               return YES;
                             }];
    out(@"empty: usage %@ segment%@", R(e.tlm.usageBoundsForTextContainer), m);
}

#pragma mark - Editing and invalidation

@interface TLMDelegate : NSObject <NSTextLayoutManagerDelegate>
@property NSMutableArray *log;
@end

@implementation TLMDelegate
- (NSTextLayoutFragment *)textLayoutManager:(NSTextLayoutManager *)m
              textLayoutFragmentForLocation:(id<NSTextLocation>)location
                              inTextElement:(NSTextElement *)element
{
    [self.log addObject:[NSString stringWithFormat:@"fragment for %@ in %@", location, element.elementRange]];
    return [[NSTextLayoutFragment alloc] initWithTextElement:element range:element.elementRange];
}
@end

static NSString *
states(TK2 *k)
{
    NSMutableArray *a = [NSMutableArray array];
    [k->tlm enumerateTextLayoutFragmentsFromLocation:nil
                                             options:0
                                          usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                            [a addObject:[NSString stringWithFormat:@"%@:%ld", f.rangeInElement, (long)f.state]];
                                            return YES;
                                          }];
    return [a componentsJoinedByString:@" "];
}

static void
test_editing(void)
{
    out(@"[editing]");
    TK2 k = make(@"One two three four\nfive\nsix seven eight nine\n", 120, nil);
    TLMDelegate *d = [TLMDelegate new];
    d.log = [NSMutableArray array];
    k.tlm.delegate = d;
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    out(@"made: %@", [d.log componentsJoinedByString:@"; "]);
    out(@"states %@", states(&k));
    NSTextLayoutFragment *third = [k.tlm textLayoutFragmentForLocation:L(&k, 30)];
    [d.log removeAllObjects];
    [k.cs performEditingTransactionUsingBlock:^{
      [k.cs.textStorage replaceCharactersInRange:NSMakeRange(0, 3) withString:@"ONE"];
    }];
    out(@"replaced in a transaction: states %@ made %@", states(&k), [d.log componentsJoinedByString:@"; "]);
    [d.log removeAllObjects];
    [k.cs.textStorage replaceCharactersInRange:NSMakeRange(19, 4) withString:@"FIVE"];
    out(@"replaced outside one: states %@ made %@", states(&k), [d.log componentsJoinedByString:@"; "]);
    [k.tlm ensureLayoutForBounds:CGRectMake(0, 0, 100, 20)];
    out(@"ensured bounds 0-20: %@", states(&k));
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    out(@"ensured all: %@", states(&k));
    [k.tlm invalidateLayoutForRange:TR(&k, 0, 3)];
    out(@"invalidated 0-3: %@", states(&k));
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    out(@"third fragment kept %d", [k.tlm textLayoutFragmentForLocation:L(&k, 30)] == third);
    [d.log removeAllObjects];
    [k.cs.textStorage replaceCharactersInRange:NSMakeRange(19, 5) withString:@"5\nand a longer six\n"];
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    out(@"inserted lines: made %@ third kept %d", [d.log componentsJoinedByString:@"; "],
        [k.tlm textLayoutFragmentForLocation:L(&k, 43)] == third);
    dump_fragments(&k, NO);
    k.tc.size = NSMakeSize(60, 0);
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    out(@"narrower container:");
    dump_fragments(&k, NO);
    k.tlm.delegate = nil;

    /* Rendering attributes. */
    TK2 r = make(@"Ag\nBj", 200, nil);
    [r.tlm addRenderingAttribute:NSForegroundColorAttributeName value:NSColor.redColor forTextRange:TR(&r, 1, 4)];
    [r.tlm addRenderingAttribute:NSBackgroundColorAttributeName value:NSColor.blueColor forTextRange:TR(&r, 3, 5)];
    NSMutableArray *a = [NSMutableArray array];
    [r.tlm enumerateRenderingAttributesFromLocation:r.cs.documentRange.location
                                            reverse:NO
                                         usingBlock:^BOOL(NSTextLayoutManager *m, NSDictionary *attrs, NSTextRange *range) {
                                           [a addObject:[NSString stringWithFormat:@"%@ %@", range,
                                                                                   [[attrs.allKeys sortedArrayUsingSelector:@selector(compare:)]
                                                                                       componentsJoinedByString:@","]]];
                                           return YES;
                                         }];
    out(@"rendering attributes: %@", [a componentsJoinedByString:@"; "]);
    [r.tlm removeRenderingAttribute:NSForegroundColorAttributeName forTextRange:r.cs.documentRange];
    [a removeAllObjects];
    [r.tlm enumerateRenderingAttributesFromLocation:r.cs.documentRange.location
                                            reverse:NO
                                         usingBlock:^BOOL(NSTextLayoutManager *m, NSDictionary *attrs, NSTextRange *range) {
                                           [a addObject:[NSString stringWithFormat:@"%@ %lu", range, (unsigned long)attrs.count]];
                                           return YES;
                                         }];
    out(@"after removing the colour: %@", [a componentsJoinedByString:@"; "]);
}

#pragma mark - Segments

static void
test_segments(void)
{
    out(@"[segments]");
    TK2 k = make(@"One two three four\nfive\nsix seven eight nine\n", 120, nil);
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    dump_fragments(&k, YES);
    NSArray *cases = @[ @[ @2, @6 ], @[ @2, @22 ], @[ @5, @5 ], @[ @0, @44 ], @[ @44, @44 ], @[ @14, @14 ], @[ @0, @19 ], @[ @45, @45 ], @[ @2, @14 ] ];
    for (NSArray *c in cases) {
        NSTextRange *x = TR(&k, [c[0] integerValue], [c[1] integerValue]);
        for (NSInteger type = 0; type < 3; type++) {
            NSMutableString *s = [NSMutableString string];
            [k.tlm enumerateTextSegmentsInRange:x
                                           type:type
                                        options:0
                                     usingBlock:^BOOL(NSTextRange *r, CGRect f, CGFloat bp, NSTextContainer *tc) {
                                       [s appendFormat:@" [%@ %@ %g%@]", r, R(f), bp, tc == k.tc ? @"" : @" other container"];
                                       return YES;
                                     }];
            out(@"%@ type %ld:%@", x, (long)type, s);
        }
        NSArray *opts = @[ @(NSTextLayoutManagerSegmentOptionsRangeNotRequired), @(NSTextLayoutManagerSegmentOptionsUpstreamAffinity),
                           @(NSTextLayoutManagerSegmentOptionsMiddleFragmentsExcluded) ];
        for (NSNumber *o in opts) {
            NSMutableString *s = [NSMutableString string];
            [k.tlm enumerateTextSegmentsInRange:x
                                           type:NSTextLayoutManagerSegmentTypeStandard
                                        options:o.unsignedIntegerValue
                                     usingBlock:^BOOL(NSTextRange *r, CGRect f, CGFloat bp, NSTextContainer *tc) {
                                       [s appendFormat:@" [%@ %@]", r, R(f)];
                                       return YES;
                                     }];
            out(@"  options %@:%@", o, s);
        }
    }
    __block int n = 0;
    [k.tlm enumerateTextSegmentsInRange:TR(&k, 0, 44)
                                   type:NSTextLayoutManagerSegmentTypeStandard
                                options:0
                             usingBlock:^BOOL(NSTextRange *r, CGRect f, CGFloat bp, NSTextContainer *tc) {
                               return ++n < 2;
                             }];
    out(@"stopping after two: %d", n);
}

#pragma mark - The viewport

@interface VPDelegate : NSObject <NSTextViewportLayoutControllerDelegate>
@property NSMutableArray *log;
@property CGRect bounds;
@end

@implementation VPDelegate
- (CGRect)viewportBoundsForTextViewportLayoutController:(NSTextViewportLayoutController *)c
{
    [self.log addObject:@"bounds"];
    return self.bounds;
}
- (void)textViewportLayoutControllerWillLayout:(NSTextViewportLayoutController *)c { [self.log addObject:@"will"]; }
- (void)textViewportLayoutController:(NSTextViewportLayoutController *)c configureRenderingSurfaceForTextLayoutFragment:(NSTextLayoutFragment *)f
{
    [self.log addObject:[NSString stringWithFormat:@"configure %@ %@ state %ld", f.rangeInElement, R(f.layoutFragmentFrame), (long)f.state]];
}
- (void)textViewportLayoutControllerDidLayout:(NSTextViewportLayoutController *)c
{
    [self.log addObject:[NSString stringWithFormat:@"did %@ %@", c.viewportRange, R(c.viewportBounds)]];
}
@end

static void
test_viewport(void)
{
    out(@"[viewport]");
    NSTextLayoutManager *bare = [NSTextLayoutManager new];
    out(@"without a container: %@", bare.textViewportLayoutController);
    TK2 k = make(@"One two three four\nfive\nsix seven eight nine\nten\neleven\n", 120, nil);
    NSTextViewportLayoutController *vp = k.tlm.textViewportLayoutController;
    out(@"before: bounds %@ range %@ manager %d delegate %@", R(vp.viewportBounds), vp.viewportRange, vp.textLayoutManager == k.tlm,
        vp.delegate);
    VPDelegate *d = [VPDelegate new];
    d.log = [NSMutableArray array];
    d.bounds = CGRectMake(0, 0, 200, 40);
    vp.delegate = d;
    [vp layoutViewport];
    out(@"layout 0-40: %@", [d.log componentsJoinedByString:@"; "]);
    out(@"after: bounds %@ range %@ states %@", R(vp.viewportBounds), vp.viewportRange, states(&k));
    [d.log removeAllObjects];
    d.bounds = CGRectMake(0, 50, 200, 30);
    [vp layoutViewport];
    out(@"layout 50-80: %@", [d.log componentsJoinedByString:@"; "]);
    [d.log removeAllObjects];
    d.bounds = CGRectMake(0, 500, 200, 30);
    [vp layoutViewport];
    out(@"layout below the text: %@", [d.log componentsJoinedByString:@"; "]);
}

#pragma mark - Selections and navigation

static void
test_navigation(void)
{
    out(@"[selection]");
    TK2 k = make(@"One two three four\nfive\nsix seven eight nine\n", 120, nil);
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    NSTextSelection *s = [[NSTextSelection alloc] initWithRange:TR(&k, 5, 5) affinity:NSTextSelectionAffinityDownstream
                                                    granularity:NSTextSelectionGranularityCharacter];
    out(@"selection %@ granularity %ld transient %d anchor offset %g logical %d secondary %@ typing %@", sel(s), (long)s.granularity,
        s.isTransient, s.anchorPositionOffset, s.isLogical, s.secondarySelectionLocation, s.typingAttributes);
    out(@"description %@", masked(s.description));
    NSTextSelection *s2 = [[NSTextSelection alloc] initWithLocation:L(&k, 3) affinity:NSTextSelectionAffinityUpstream];
    NSTextSelection *s3 = [[NSTextSelection alloc] initWithRanges:@[ TR(&k, 1, 2), TR(&k, 4, 6) ] affinity:NSTextSelectionAffinityDownstream
                                                      granularity:NSTextSelectionGranularityWord];
    out(@"at a location %@ granularity %ld; two ranges %@ granularity %ld; with ranges %@ granularity %ld", sel(s2),
        (long)s2.granularity, sel(s3), (long)s3.granularity, sel([s3 textSelectionWithTextRanges:@[ TR(&k, 7, 9) ]]),
        (long)[s3 textSelectionWithTextRanges:@[ TR(&k, 7, 9) ]].granularity);
    NSTextSelectionNavigation *nav = k.tlm.textSelectionNavigation;
    out(@"navigation: non-contiguous %d rotates %d", nav.allowsNonContiguousRanges, nav.rotatesCoordinateSystemForLayoutOrientation);
    NSArray *dirs = @[ @"forward", @"backward", @"right", @"left", @"up", @"down" ];
    NSArray *dests = @[ @"char", @"word", @"line", @"sentence", @"para", @"container", @"doc" ];
    out(@"[navigation]");
    for (NSNumber *start in @[ @0, @5, @10, @14, @16, @18, @19, @23, @24, @40, @44, @45 ])
        for (NSInteger dir = 0; dir < 6; dir++) {
            NSMutableString *m = [NSMutableString string];
            for (NSInteger dest = 0; dest < 7; dest++) {
                NSTextSelection *x = [[NSTextSelection alloc] initWithRange:TR(&k, start.integerValue, start.integerValue)
                                                                   affinity:NSTextSelectionAffinityDownstream
                                                                granularity:NSTextSelectionGranularityCharacter];
                NSTextSelection *y = [nav destinationSelectionForTextSelection:x direction:dir destination:dest extending:NO confined:NO];
                NSTextSelection *z = [nav destinationSelectionForTextSelection:x direction:dir destination:dest extending:YES confined:NO];
                [m appendFormat:@" %@ %@ %@;", dests[dest], sel(y), ranges(z.textRanges)];
            }
            out(@"%@ %@:%@", start, dirs[dir], m);
        }
    NSTextSelection *rs = [[NSTextSelection alloc] initWithRange:TR(&k, 2, 8) affinity:NSTextSelectionAffinityDownstream
                                                     granularity:NSTextSelectionGranularityCharacter];
    for (NSInteger dir = 0; dir < 6; dir++) {
        NSTextSelection *z = [nav destinationSelectionForTextSelection:rs direction:dir destination:0 extending:YES confined:NO];
        NSString *y = dir == 5 ? @"-" : sel([nav destinationSelectionForTextSelection:rs direction:dir destination:0 extending:NO confined:NO]);
        out(@"2-8 %@: %@ extending %@", dirs[dir], y, ranges(z.textRanges));
    }
    NSTextSelection *ext = [nav destinationSelectionForTextSelection:s direction:1 destination:0 extending:YES confined:NO];
    ext = [nav destinationSelectionForTextSelection:ext direction:1 destination:0 extending:YES confined:NO];
    out(@"extending backward twice from 5: %@", ranges(ext.textRanges));
    out(@"[clicks]");
    for (NSValue *v in @[ [NSValue valueWithPoint:NSMakePoint(30, 5)], [NSValue valueWithPoint:NSMakePoint(200, 20)],
                          [NSValue valueWithPoint:NSMakePoint(10, 70)], [NSValue valueWithPoint:NSMakePoint(0, 40)],
                          [NSValue valueWithPoint:NSMakePoint(60, 50)] ]) {
        NSArray *a = [nav textSelectionsInteractingAtPoint:v.pointValue inContainerAtLocation:k.cs.documentRange.location anchors:@[]
                                                 modifiers:0 selecting:YES bounds:CGRectZero];
        NSArray *b = [nav textSelectionsInteractingAtPoint:v.pointValue inContainerAtLocation:k.cs.documentRange.location anchors:@[ rs ]
                                                 modifiers:NSTextSelectionNavigationModifierExtend selecting:YES bounds:CGRectZero];
        NSTextSelection *x = a.firstObject, *y = b.firstObject;
        out(@"%@: %lu %@ transient %d offset %.3f; extending %@ anchor %@ offset %.3f", NSStringFromPoint(v.pointValue),
            (unsigned long)a.count, sel(x), x.isTransient, x.anchorPositionOffset, ranges(y.textRanges), y.secondarySelectionLocation,
            y.anchorPositionOffset);
    }
    NSTextSelection *notSelecting = [nav textSelectionsInteractingAtPoint:CGPointMake(30, 5)
                                                    inContainerAtLocation:k.cs.documentRange.location
                                                                  anchors:@[]
                                                                modifiers:0
                                                                selecting:NO
                                                                   bounds:CGRectZero]
                                        .firstObject;
    out(@"not selecting: transient %d", notSelecting.isTransient);
    out(@"[deletion]");
    for (NSNumber *st in @[ @0, @5, @14, @18, @19, @23, @24, @45 ])
        for (NSInteger dir = 0; dir < 2; dir++) {
            NSMutableString *m = [NSMutableString string];
            for (NSInteger dest = 0; dest < 5; dest++) {
                NSTextSelection *x = [[NSTextSelection alloc] initWithRange:TR(&k, st.integerValue, st.integerValue)
                                                                   affinity:NSTextSelectionAffinityDownstream
                                                                granularity:NSTextSelectionGranularityCharacter];
                [m appendFormat:@" %@ %@", dests[dest], ranges([nav deletionRangesForTextSelection:x direction:dir destination:dest
                                                                              allowsDecomposition:NO])];
            }
            out(@"%@ %@:%@", st, dirs[dir], m);
        }
    out(@"a range: %@", ranges([nav deletionRangesForTextSelection:rs direction:0 destination:0 allowsDecomposition:NO]));
    out(@"[granularity]");
    for (NSNumber *at in @[ @0, @3, @5, @14, @18, @19, @30, @44, @45 ]) {
        NSTextSelection *x = [[NSTextSelection alloc] initWithRange:TR(&k, at.integerValue, at.integerValue)
                                                           affinity:NSTextSelectionAffinityDownstream
                                                        granularity:NSTextSelectionGranularityCharacter];
        NSTextSelection *line = [nav textSelectionForSelectionGranularity:NSTextSelectionGranularityLine enclosingTextSelection:x];
        NSTextSelection *ch = [nav textSelectionForSelectionGranularity:NSTextSelectionGranularityCharacter enclosingTextSelection:x];
        NSTextSelection *sen = [nav textSelectionForSelectionGranularity:NSTextSelectionGranularitySentence enclosingTextSelection:x];
        out(@"%@: word %@ paragraph %@ sentence %@ line %@ (granularity %ld, the same %d) character %@", at,
            sel([nav textSelectionForSelectionGranularity:NSTextSelectionGranularityWord enclosingTextSelection:x]),
            sel([nav textSelectionForSelectionGranularity:NSTextSelectionGranularityParagraph enclosingTextSelection:x]), sel(sen),
            sel(line), (long)line.granularity, line == x, sel(ch));
    }
    out(@"word granularity keeps %ld", (long)[nav textSelectionForSelectionGranularity:NSTextSelectionGranularityWord enclosingTextSelection:s].granularity);
    NSTextSelection *span = [[NSTextSelection alloc] initWithRange:TR(&k, 5, 21) affinity:NSTextSelectionAffinityDownstream
                                                       granularity:NSTextSelectionGranularityCharacter];
    out(@"5-21: word %@ line %@ character %@", sel([nav textSelectionForSelectionGranularity:NSTextSelectionGranularityWord enclosingTextSelection:span]),
        sel([nav textSelectionForSelectionGranularity:NSTextSelectionGranularityLine enclosingTextSelection:span]),
        sel([nav textSelectionForSelectionGranularity:NSTextSelectionGranularityCharacter enclosingTextSelection:span]));
    for (NSValue *v in @[ [NSValue valueWithPoint:NSMakePoint(30, 5)], [NSValue valueWithPoint:NSMakePoint(12, 5)],
                          [NSValue valueWithPoint:NSMakePoint(20, 40)] ])
        out(@"word at %@: %@ paragraph %@", NSStringFromPoint(v.pointValue),
            sel([nav textSelectionForSelectionGranularity:NSTextSelectionGranularityWord enclosingPoint:v.pointValue
                                    inContainerAtLocation:k.cs.documentRange.location]),
            sel([nav textSelectionForSelectionGranularity:NSTextSelectionGranularityParagraph enclosingPoint:v.pointValue
                                    inContainerAtLocation:k.cs.documentRange.location]));
    out(@"insertion location %@", [nav resolvedInsertionLocationForTextSelection:s
                                                               writingDirection:NSTextSelectionNavigationWritingDirectionLeftToRight]);
}

#pragma mark - TextKit 1 and 2 alike

static void
compare_layout(NSString *text, CGFloat width, NSDictionary *attrs)
{
    TK2 k = make(text, width, attrs);
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    NSTextStorage *ts = [[NSTextStorage alloc] initWithString:text attributes:attrs];
    NSLayoutManager *lm = [NSLayoutManager new];
    [ts addLayoutManager:lm];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(width, 1e7)];
    [lm addTextContainer:tc];
    NSMutableArray *one = [NSMutableArray array], *two = [NSMutableArray array];
    [lm enumerateLineFragmentsForGlyphRange:NSMakeRange(0, lm.numberOfGlyphs)
                                 usingBlock:^(NSRect rect, NSRect used, NSTextContainer *c, NSRange g, BOOL *stop) {
                                   [one addObject:[NSString stringWithFormat:@"%@ %@", R(NSMakeRect(used.origin.x + 5, rect.origin.y,
                                                                                                    used.size.width - 10, 0)),
                                                                             Rg(g)]];
                                 }];
    if (!NSIsEmptyRect(lm.extraLineFragmentRect))
        [one addObject:[NSString stringWithFormat:@"%@ extra", R(NSMakeRect(lm.extraLineFragmentUsedRect.origin.x + 5,
                                                                            lm.extraLineFragmentRect.origin.y, 0, 0))]];
    [k.tlm enumerateTextLayoutFragmentsFromLocation:nil
                                            options:0
                                         usingBlock:^BOOL(NSTextLayoutFragment *f) {
                                           NSInteger start = [k.cs offsetFromLocation:k.cs.documentRange.location
                                                                           toLocation:f.rangeInElement.location];
                                           for (NSTextLineFragment *l in f.textLineFragments) {
                                               CGRect b = l.typographicBounds;
                                               NSRange r = l.characterRange;
                                               if (!r.length && NSMaxRange(r) == l.attributedString.length && r.location)
                                                   [two addObject:[NSString stringWithFormat:@"%@ extra",
                                                                                             R(CGRectMake(f.layoutFragmentFrame.origin.x + b.origin.x,
                                                                                                          f.layoutFragmentFrame.origin.y + b.origin.y,
                                                                                                          0, 0))]];
                                               else
                                                   [two addObject:[NSString stringWithFormat:@"%@ %@",
                                                                                             R(CGRectMake(f.layoutFragmentFrame.origin.x + b.origin.x,
                                                                                                          f.layoutFragmentFrame.origin.y + b.origin.y,
                                                                                                          b.size.width, 0)),
                                                                                             Rg(NSMakeRange(r.location + (NSUInteger)start, r.length))]];
                                           }
                                           return YES;
                                         }];
    BOOL same = [one isEqualToArray:two];
    out(@"%lu lines, TextKit 1 and 2 %@; usage %@ used %@", (unsigned long)one.count, same ? @"alike" : @"differ",
        R(k.tlm.usageBoundsForTextContainer), R([lm usedRectForTextContainer:tc]));
    if (!same)
        out(@"  1: %@\n  2: %@", [one componentsJoinedByString:@" | "], [two componentsJoinedByString:@" | "]);
}

static void
test_alike(void)
{
    out(@"[TextKit 1 and 2]");
    NSDictionary *plain = @{NSFontAttributeName : font};
    compare_layout(@"Hello world, this is a test of wrapping text in TextKit two.\nSecond para\n\nFourth\n", 200, plain);
    compare_layout(@"The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.", 130, plain);
    compare_layout(@"one\ntwo\nthree", 300, plain);
    NSFont *big = [NSFont fontWithName:@"Roboto-Regular" size:24];
    NSMutableAttributedString *mixed = [[NSMutableAttributedString alloc] initWithString:@"small then BIG words wrap around here\nand on"
                                                                              attributes:plain];
    [mixed addAttribute:NSFontAttributeName value:big range:NSMakeRange(11, 3)];
    TK2 k = make(@"", 160, nil);
    [k.cs.textStorage setAttributedString:mixed];
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    out(@"mixed sizes:");
    dump_fragments(&k, YES);
}

#pragma mark - Drawing

static NSString *
ink(uint8_t *px, int w, int h)
{
    int minr = h, maxr = -1, minc = w, maxc = -1;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            if (px[y * w + x] < 128) {
                minr = MIN(minr, y);
                maxr = MAX(maxr, y);
                minc = MIN(minc, x);
                maxc = MAX(maxc, x);
            }
    if (maxr < 0)
        return @"no ink";
    return [NSString stringWithFormat:@"ink rows %d-%d columns %d-%d", minr, maxr, minc, maxc];
}

static void
test_drawing(void)
{
    out(@"[drawing]");
    NSFont *big = [NSFont fontWithName:@"Roboto-Regular" size:24];
    TK2 k = make(@"Hi", 200, @{NSFontAttributeName : big});
    [k.tlm ensureLayoutForRange:k.cs.documentRange];
    NSTextLayoutFragment *f = [k.tlm textLayoutFragmentForLocation:k.cs.documentRange.location];
    for (int flipped = 0; flipped < 2; flipped++) {
        CGColorSpaceRef g = CGColorSpaceCreateDeviceGray();
        CGContextRef c = CGBitmapContextCreate(NULL, 60, 40, 8, 60, g, (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(g);
        CGContextSetGrayFillColor(c, 1, 1);
        CGContextFillRect(c, CGRectMake(0, 0, 60, 40));
        if (flipped) {
            CGContextTranslateCTM(c, 0, 40);
            CGContextScaleCTM(c, 1, -1);
        }
        [f drawAtPoint:CGPointMake(4, 4) inContext:c];
        uint8_t *px = CGBitmapContextGetData(c);
        /* Rows from the top of the image; in the unflipped context TextKit 2 still draws y-down. */
        uint8_t top = 255, bottom = 255;
        for (int y = 0; y < 20; y++)
            for (int x = 0; x < 60; x++) {
                top = MIN(top, px[y * 60 + x]);
                bottom = MIN(bottom, px[(39 - y) * 60 + x]);
            }
        out(@"%@ context: ink in the top half %d bottom half %d", flipped ? @"flipped" : @"unflipped", top < 128, bottom < 128);
        (void)ink;
        CGContextRelease(c);
    }
}

#pragma mark - NSTextView

@interface Switches : NSObject
@property NSMutableArray *log;
@end

@implementation Switches
- (void)note:(NSNotification *)n
{
    NSTextView *tv = n.object;
    [self.log addObject:[NSString stringWithFormat:@"%@ (text layout manager %d)", n.name, tv.textLayoutManager != nil]];
}
@end

static void
describe_view_geometry(NSString *name, NSTextView *tv, BOOL geometry)
{
    NSTextContainer *tc = tv.textContainer;
    out(@"%@: text layout manager %@ content storage %@ storage %@ same storage %d layout managers %lu observer is content %d",
        name, tv.textLayoutManager.className, tv.textContentStorage.className, tv.textStorage.className,
        tv.textContentStorage.textStorage == tv.textStorage, (unsigned long)tv.textStorage.layoutManagers.count,
        tv.textStorage.textStorageObserver == (id)tv.textContentStorage && tv.textContentStorage);
    if (tv.textLayoutManager && geometry)
        out(@"  container's %d manager's container %d viewport delegate is view %d primary %d frame %@ container %@ tracks %d",
            tc.textLayoutManager == tv.textLayoutManager, tv.textLayoutManager.textContainer == tc,
            tv.textLayoutManager.textViewportLayoutController.delegate == (id)tv,
            tv.textContentStorage.primaryTextLayoutManager == tv.textLayoutManager, NSStringFromRect(tv.frame),
            NSStringFromSize(tc.size), tc.widthTracksTextView);
}

static void
describe_view(NSString *name, NSTextView *tv)
{
    describe_view_geometry(name, tv, YES);
}

static void
geometry(NSTextView *tv, NSMutableArray *log)
{
    tv.string = @"The quick brown fox jumps over the lazy dog.\nPack my box\nwith five dozen liquor jugs.";
    tv.font = font;
    [tv sizeToFit];
    [log addObject:NSStringFromRect(tv.frame)];
    for (int y = 2; y < 120; y += 13)
        [log addObject:[NSString stringWithFormat:@"%lu", (unsigned long)[tv characterIndexForInsertionAtPoint:NSMakePoint(40, y)]]];
    tv.selectedRange = NSMakeRange(3, 0);
    [tv moveDown:nil];
    [tv moveDown:nil];
    [tv moveToEndOfLine:nil];
    [tv moveWordRight:nil];
    [tv moveDown:nil];
    [log addObject:NSStringFromRange(tv.selectedRange)];
    [tv insertText:@"XYZ " replacementRange:tv.selectedRange];
    [tv moveUp:nil];
    [tv moveToBeginningOfParagraph:nil];
    [tv moveForwardAndModifySelection:nil];
    [tv deleteBackward:nil];
    [log addObject:[NSString stringWithFormat:@"%@ %@", V(tv.string), NSStringFromRange(tv.selectedRange)]];
    [tv sizeToFit];
    [log addObject:NSStringFromRect(tv.frame)];
}

static void
test_text_view(const char *nibPath)
{
    out(@"[text view]");
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    describe_view(@"initWithFrame:", tv);
    describe_view(@"using text layout manager", [NSTextView textViewUsingTextLayoutManager:YES]);
    describe_view(@"not using text layout manager", [NSTextView textViewUsingTextLayoutManager:NO]);
    describe_view(@"initUsingTextLayoutManager:NO", [[NSTextView alloc] initUsingTextLayoutManager:NO]);
    describe_view_geometry(@"scrollableTextView", [NSTextView scrollableTextView].documentView, NO);
    NSTextContainer *bare = [[NSTextContainer alloc] initWithSize:NSMakeSize(100, 100)];
    describe_view(@"bare container", [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) textContainer:bare]);
    TK2 k = make(@"given", 100, nil);
    NSTextView *given = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) textContainer:k.tc];
    describe_view(@"TextKit 2 container", given);
    out(@"  it's the given network %d %d, string '%@'", given.textLayoutManager == k.tlm, given.textContentStorage == k.cs, given.string);
    NSTextStorage *ts1 = [[NSTextStorage alloc] initWithString:@"one"];
    NSLayoutManager *lm1 = [NSLayoutManager new];
    [ts1 addLayoutManager:lm1];
    NSTextContainer *tc1 = [[NSTextContainer alloc] initWithSize:NSMakeSize(100, 100)];
    [lm1 addTextContainer:tc1];
    describe_view(@"TextKit 1 container", [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) textContainer:tc1]);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:YES];
    NSTextView *fe = (NSTextView *)[w fieldEditor:YES forObject:nil];
    describe_view(@"field editor", fe);
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, 100, 24)];
    [w.contentView addSubview:field];
    [w makeFirstResponder:field];
    NSTextView *editing = (NSTextView *)field.currentEditor;
    out(@"editing a field: the field editor %d, text layout manager %d", editing == fe, editing.textLayoutManager != nil);
    [editing insertText:@"typed" replacementRange:editing.selectedRange];
    [w makeFirstResponder:nil];
    out(@"field value '%@' field editor still TextKit 2 %d", field.stringValue, fe.textLayoutManager != nil);

    /* Editing and selections. */
    tv.string = @"Hello there\nworld";
    tv.selectedRange = NSMakeRange(2, 3);
    NSTextSelection *ts = tv.textLayoutManager.textSelections.firstObject;
    out(@"selection %@ -> %lu selections %@ granularity %ld anchor offset %g", NSStringFromRange(tv.selectedRange),
        (unsigned long)tv.textLayoutManager.textSelections.count, sel(ts), (long)ts.granularity, ts.anchorPositionOffset);
    [tv setSelectedRange:NSMakeRange(6, 0) affinity:NSSelectionAffinityUpstream stillSelecting:NO];
    out(@"upstream caret %@", sel(tv.textLayoutManager.textSelections.firstObject));
    [tv insertText:@"big " replacementRange:NSMakeRange(6, 0)];
    out(@"inserted: '%@' selection %@ text selection %@ document %@", V(tv.string), NSStringFromRange(tv.selectedRange),
        ranges(tv.textLayoutManager.textSelections.firstObject.textRanges), tv.textContentStorage.documentRange);
    [tv.textLayoutManager ensureLayoutForRange:tv.textContentStorage.documentRange];
    TK2 vk = {tv.textContentStorage, tv.textLayoutManager, tv.textContainer};
    dump_fragments(&vk, YES);
    [tv.textStorage replaceCharactersInRange:NSMakeRange(0, 5) withString:@"Howdy"];
    out(@"storage edited directly: '%@' selection %@", V(tv.string), NSStringFromRange(tv.selectedRange));

    /* The same text and actions on TextKit 1 and 2. */
    NSMutableArray *g1 = [NSMutableArray array], *g2 = [NSMutableArray array];
    NSTextView *v1 = [NSTextView textViewUsingTextLayoutManager:NO], *v2 = [NSTextView textViewUsingTextLayoutManager:YES];
    v1.frame = v2.frame = NSMakeRect(0, 0, 150, 40);
    v1.textContainer.size = v2.textContainer.size = NSMakeSize(150, 1e7);
    geometry(v1, g1);
    geometry(v2, g2);
    out(@"TextKit 1 and 2 views alike %d; still TextKit 2 %d", [g1 isEqualToArray:g2], v2.textLayoutManager != nil);
    out(@"  %@", [g2 componentsJoinedByString:@" "]);
    if (![g1 isEqualToArray:g2])
        out(@"  TextKit 1: %@", [g1 componentsJoinedByString:@" "]);

    /* Switching to TextKit 1. */
    Switches *sw = [Switches new];
    sw.log = [NSMutableArray array];
    [[NSNotificationCenter defaultCenter] addObserver:sw selector:@selector(note:) name:NSTextViewWillSwitchToNSLayoutManagerNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:sw selector:@selector(note:) name:NSTextViewDidSwitchToNSLayoutManagerNotification object:nil];
    NSTextContainer *tc = tv.textContainer;
    NSTextStorage *storage = tv.textStorage;
    tv.selectedRange = NSMakeRange(4, 2);
    NSLayoutManager *lm = tv.layoutManager;
    out(@"asked for layoutManager: %@", [sw.log componentsJoinedByString:@"; "]);
    out(@"  now %@ same container %d storage %d string '%@' selection %@ container's layout manager %d text layout manager %@ "
        @"layout managers %lu observer %@",
        lm.className, tv.textContainer == tc, tv.textStorage == storage, V(tv.string), NSStringFromRange(tv.selectedRange),
        tc.layoutManager == lm, tc.textLayoutManager, (unsigned long)storage.layoutManagers.count, storage.textStorageObserver);
    describe_view(@"  after", tv);
    [sw.log removeAllObjects];
    (void)tv.layoutManager;
    out(@"asked again: %lu notifications", (unsigned long)sw.log.count);
    [tv insertText:@"!" replacementRange:NSMakeRange(0, 0)];
    out(@"edits after: '%@' lines %lu", V(tv.string), (unsigned long)[lm numberOfGlyphs]);
    NSTextView *other = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    [sw.log removeAllObjects];
    NSLayoutManager *viaContainer = other.textContainer.layoutManager;
    out(@"container asked: %@ -> %@ view's %d", [sw.log componentsJoinedByString:@"; "], viaContainer.className,
        other.layoutManager == viaContainer);
    NSTextContainer *loose = [[NSTextContainer alloc] initWithSize:NSMakeSize(10, 10)];
    TK2 lk = make(@"x", 10, nil);
    out(@"a container without a view: layout manager %@ text layout manager %d", lk.tc.layoutManager, lk.tc.textLayoutManager == lk.tlm);
    (void)loose;
    [[NSNotificationCenter defaultCenter] removeObserver:sw];

    /* Archives. */
    NSTextView *a2 = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 50)];
    a2.string = @"archived";
    NSData *d2 = [NSKeyedArchiver archivedDataWithRootObject:a2 requiringSecureCoding:NO error:NULL];
    NSKeyedUnarchiver *u2 = [[NSKeyedUnarchiver alloc] initForReadingFromData:d2 error:NULL];
    u2.requiresSecureCoding = NO;
    NSTextView *b2 = [u2 decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    describe_view_geometry(@"TextKit 2 view unarchived", b2, NO);
    out(@"  string '%@'", b2.string);
    NSData *d1 = [NSKeyedArchiver archivedDataWithRootObject:tv requiringSecureCoding:NO error:NULL];
    NSKeyedUnarchiver *u1 = [[NSKeyedUnarchiver alloc] initForReadingFromData:d1 error:NULL];
    u1.requiresSecureCoding = NO;
    NSTextView *b1 = [u1 decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    describe_view(@"TextKit 1 view unarchived", b1);
    out(@"  string '%@'", V(b1.string));

    /* A nib. */
    NSData *nibData = nibPath ? [NSData dataWithContentsOfFile:@(nibPath)] : nil;
    NSNib *nib = nibData ? [[NSNib alloc] initWithNibData:nibData bundle:nil] : nil;
    NSArray *top = nil;
    if (![nib instantiateWithOwner:nil topLevelObjects:&top]) {
        out(@"no nib");
        return;
    }
    for (id o in top)
        if ([o isKindOfClass:[NSScrollView class]] && [[o documentView] isKindOfClass:[NSTextView class]]) {
            NSTextView *nv = [o documentView];
            describe_view(@"from a nib", nv);
            out(@"  string '%@' container %@ font size %g", nv.string, NSStringFromSize(nv.textContainer.size), nv.font.pointSize);
        }
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        out(@"NSTextLayoutManager: %s", class_getImageName([NSTextLayoutManager class]));
        const char *fontPath = NULL, *nib = NULL;
        for (int i = 1; i < argc; i++) {
            if (strstr(argv[i], ".ttf"))
                fontPath = argv[i];
            else
                nib = argv[i];
        }
        const char *fonts[] = {fontPath, "/usr/local/share/finch/test-fonts/Roboto-Regular.ttf",
                               "build/src/skia/resources/fonts/Roboto-Regular.ttf"};
        for (size_t i = 0; i < 3 && !font; i++)
            if (fonts[i] && !access(fonts[i], R_OK)) {
                CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(fonts[i])], kCTFontManagerScopeProcess, NULL);
                font = [NSFont fontWithName:@"Roboto-Regular" size:14];
            }
        if (!font) {
            out(@"no Roboto");
            return 1;
        }
        const char *nibs[] = {nib, "/usr/local/share/finch/appkit-text-test.nib", "build/userland/appkit-text-test.nib"};
        nib = NULL;
        for (size_t i = 0; i < 3 && !nib; i++)
            if (nibs[i] && !access(nibs[i], R_OK))
                nib = nibs[i];
        [NSApplication sharedApplication];
        test_ranges();
        test_content_storage();
        test_layout();
        test_editing();
        test_segments();
        test_viewport();
        test_navigation();
        test_alike();
        test_drawing();
        test_text_view(nib);
        out(@"done");
    }
    return 0;
}
