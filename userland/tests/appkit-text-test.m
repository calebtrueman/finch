/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-text-test: text editing and scrolling without a screen.
 * NSTextView (TextKit 1) editing, movement and selection actions, undo,
 * delegate calls and notifications in order, the field editor, cut, copy
 * and paste; NSScrollView and NSClipView geometry, scrolling, constraining,
 * magnification; and a scroll view holding a text view loaded from a nib
 * ibtool compiles (appkit-text-test.xib). Prints everything; run it against
 * Apple's AppKit and Finch's (DYLD_FRAMEWORK_PATH) and diff all but the
 * first line, which is where NSTextView came from.
 *
 * Text uses Roboto (registered from a file) so both systems lay it out
 * alike. Action methods are called directly: Apple's AppKit needs a real
 * input session to interpret arrow and Escape keys.
 *
 *   finch-appkit-text-test [path to appkit-text-test.nib] [Roboto-Regular.ttf]
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

static NSString *
R(NSRect r)
{
    return NSStringFromRect(r);
}

static NSString *
Rg(NSRange r)
{
    return NSStringFromRange(r);
}

/* A string with its control characters visible. */
static NSString *
V(NSString *s)
{
    NSMutableString *m = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\n')
            [m appendString:@"\\n"];
        else if (c == '\t')
            [m appendString:@"\\t"];
        else if (c == 0x2028)
            [m appendString:@"\\L"];
        else if (c == 0x2029)
            [m appendString:@"\\P"];
        else if (c < 0x20 || c > 0x7e)
            [m appendFormat:@"\\u%04x", c];
        else
            [m appendFormat:@"%C", c];
    }
    return m;
}

static NSMutableArray<NSString *> *log_;

static void
flush_log(NSString *label)
{
    out(@"%@: %@", label, log_.count ? [log_ componentsJoinedByString:@"; "] : @"-");
    [log_ removeAllObjects];
}

static NSFont *roboto;

static NSFont *
load_roboto(const char *path)
{
    const char *paths[] = {path, "/usr/local/share/finch/test-fonts/Roboto-Regular.ttf",
                           "build/src/skia/resources/fonts/Roboto-Regular.ttf"};
    for (size_t i = 0; i < 3; i++) {
        if (!paths[i] || access(paths[i], R_OK))
            continue;
        NSURL *u = [NSURL fileURLWithPath:@(paths[i])];
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)u, kCTFontManagerScopeProcess, NULL);
        return [NSFont fontWithName:@"Roboto-Regular" size:12];
    }
    return nil;
}

#pragma mark - A delegate that logs

@interface Watcher : NSObject <NSTextViewDelegate>
@property NSUndoManager *undo;
@property BOOL refuse;  /* refuse changes */
@property BOOL claimCommands;
@property BOOL quiet;
@end

@implementation Watcher
- (void)note:(NSString *)s
{
    if (!self.quiet)
        [log_ addObject:s];
}
- (BOOL)textShouldBeginEditing:(NSText *)t
{
    [self note:@"shouldBegin"];
    return YES;
}
- (BOOL)textShouldEndEditing:(NSText *)t
{
    [self note:@"shouldEnd"];
    return YES;
}
- (void)textDidBeginEditing:(NSNotification *)n
{
    [self note:@"didBegin"];
}
- (void)textDidEndEditing:(NSNotification *)n
{
    id movement = n.userInfo[@"NSTextMovement"];
    [self note:[NSString stringWithFormat:@"didEnd movement %@", movement ?: @"none"]];
}
- (void)textDidChange:(NSNotification *)n
{
    [self note:[NSString stringWithFormat:@"didChange '%@'", V([n.object string])]];
}
- (BOOL)textView:(NSTextView *)tv shouldChangeTextInRange:(NSRange)r replacementString:(NSString *)s
{
    [self note:[NSString stringWithFormat:@"shouldChange %@ '%@'", Rg(r), s ? V(s) : @"(nil)"]];
    return !self.refuse;
}
- (NSRange)textView:(NSTextView *)tv willChangeSelectionFromCharacterRange:(NSRange)a toCharacterRange:(NSRange)b
{
    [self note:[NSString stringWithFormat:@"willSelect %@->%@", Rg(a), Rg(b)]];
    return b;
}
- (void)textViewDidChangeSelection:(NSNotification *)n
{
    [self note:[NSString stringWithFormat:@"didSelect %@ (old %@)", Rg([n.object selectedRange]),
                                               n.userInfo[@"NSOldSelectedCharacterRange"]
                                                   ? Rg([n.userInfo[@"NSOldSelectedCharacterRange"] rangeValue])
                                                   : @"-"]];
}
- (BOOL)textView:(NSTextView *)tv doCommandBySelector:(SEL)sel
{
    [self note:[NSString stringWithFormat:@"command %@", NSStringFromSelector(sel)]];
    return self.claimCommands;
}
- (NSUndoManager *)undoManagerForTextView:(NSTextView *)view
{
    return self.undo;
}
@end

#pragma mark - Text views

/* A TextKit 1 text view of a given size, over its own storage, in Roboto 12. */
static NSTextView *
make_text_view(NSRect frame)
{
    NSTextStorage *storage = [[NSTextStorage alloc] init];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    [storage addLayoutManager:lm];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(frame.size.width, 1e7)];
    tc.widthTracksTextView = YES;
    [lm addTextContainer:tc];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:frame textContainer:tc];
    tv.font = roboto;
    tv.richText = NO;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled = NO;
    tv.automaticTextReplacementEnabled = NO;
    tv.automaticSpellingCorrectionEnabled = NO;
    tv.continuousSpellCheckingEnabled = NO;
    tv.smartInsertDeleteEnabled = NO;
    tv.automaticLinkDetectionEnabled = NO;
    tv.automaticDataDetectionEnabled = NO;
    tv.automaticTextCompletionEnabled = NO;
    return tv;
}

static void
show(NSTextView *tv, NSString *label)
{
    out(@"  %@: '%@' sel %@", label, V(tv.string), Rg(tv.selectedRange));
}

/* Run an action, then show the text and selection. */
static void
act(NSTextView *tv, SEL sel)
{
    @try {
        void (*imp)(id, SEL, id) = (void (*)(id, SEL, id))[tv methodForSelector:sel];
        imp(tv, sel, nil);
    } @catch (NSException *e) {
        out(@"  %@ raised %@", NSStringFromSelector(sel), e.name);
    }
    show(tv, NSStringFromSelector(sel));
}

static void
test_defaults(void)
{
    out(@"[defaults]");
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    (void)tv.layoutManager;  /* TextKit 1 */
    out(@"  editable %d selectable %d rich %d fieldEditor %d drawsBackground %d importsGraphics %d", tv.editable,
        tv.selectable, tv.richText, tv.fieldEditor, tv.drawsBackground, tv.importsGraphics);
    out(@"  allowsUndo %d hResizable %d vResizable %d usesFontPanel %d usesRuler %d smartInsert %d", tv.allowsUndo,
        tv.horizontallyResizable, tv.verticallyResizable, tv.usesFontPanel, tv.usesRuler, tv.smartInsertDeleteEnabled);
    out(@"  minSize %@ maxSize %@ inset %@ origin %@", NSStringFromSize(tv.minSize), NSStringFromSize(tv.maxSize),
        NSStringFromSize(tv.textContainerInset), NSStringFromPoint(tv.textContainerOrigin));
    NSTextContainer *tc = tv.textContainer;
    out(@"  container %@ tracks w %d h %d padding %g textView %d", NSStringFromSize(tc.size), tc.widthTracksTextView,
        tc.heightTracksTextView, tc.lineFragmentPadding, tc.textView == tv);
    out(@"  storage %d layout managers %lu containers %lu", tv.textStorage != nil,
        (unsigned long)tv.textStorage.layoutManagers.count, (unsigned long)tv.layoutManager.textContainers.count);
    out(@"  string '%@' sel %@ alignment %ld flipped %d opaque %d accepts first responder %d", tv.string,
        Rg(tv.selectedRange), (long)tv.alignment, tv.isFlipped, tv.isOpaque, tv.acceptsFirstResponder);
    out(@"  typing attribute keys %@",
        [[tv.typingAttributes.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]);
    out(@"  selection granularity %ld affinity %ld insertion point visible %d", (long)tv.selectionGranularity,
        (long)tv.selectionAffinity, tv.shouldDrawInsertionPoint);
    NSText *plain = [[NSText alloc] initWithFrame:NSMakeRect(0, 0, 50, 50)];
    out(@"  [NSText alloc] is a %@", [plain isKindOfClass:[NSTextView class]] ? @"NSTextView" : @"NSText");

    NSTextView *k1 = make_text_view(NSMakeRect(0, 0, 200, 100));
    out(@"  initWithFrame:textContainer: frame %@ container %@ origin %@", R(k1.frame),
        NSStringFromSize(k1.textContainer.size), NSStringFromPoint(k1.textContainerOrigin));
    out(@"  resizable h %d v %d min %@ max %@ rich %d editable %d", k1.horizontallyResizable, k1.verticallyResizable,
        NSStringFromSize(k1.minSize), NSStringFromSize(k1.maxSize), k1.richText, k1.editable);
    k1.textContainerInset = NSMakeSize(4, 6);
    out(@"  inset 4,6 origin %@", NSStringFromPoint(k1.textContainerOrigin));
    k1.string = @"abc";
    out(@"  font %@ %g color set %d", k1.font.fontName, k1.font.pointSize, k1.textColor != nil);
    k1.textColor = [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1];
    NSColor *c = [k1.textStorage attribute:NSForegroundColorAttributeName atIndex:1 effectiveRange:NULL];
    out(@"  textColor applied %d", [c isEqual:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1]]);
    k1.alignment = NSTextAlignmentCenter;
    NSParagraphStyle *ps = [k1.textStorage attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL];
    out(@"  alignment applied %ld", (long)ps.alignment);
}

static void
test_editing(void)
{
    out(@"[editing]");
    NSTextView *tv = make_text_view(NSMakeRect(0, 0, 300, 200));
    [tv insertText:@"Hello world" replacementRange:NSMakeRange(NSNotFound, 0)];
    show(tv, @"insertText");
    [tv insertText:@"big " replacementRange:NSMakeRange(6, 0)];
    show(tv, @"insertText at 6");
    [tv insertText:@"X" replacementRange:NSMakeRange(0, 5)];
    show(tv, @"replace 0-5");
    tv.selectedRange = NSMakeRange(2, 3);
    [tv insertText:@"ZZ"];
    show(tv, @"insertText over selection");
    tv.string = @"one two three";
    show(tv, @"setString");
    tv.selectedRange = NSMakeRange(4, 0);
    act(tv, @selector(deleteBackward:));
    act(tv, @selector(deleteForward:));
    act(tv, @selector(deleteWordForward:));
    act(tv, @selector(deleteWordBackward:));
    tv.string = @"alpha beta gamma";
    tv.selectedRange = NSMakeRange(8, 0);
    act(tv, @selector(deleteToBeginningOfLine:));
    act(tv, @selector(yank:));
    tv.selectedRange = NSMakeRange(3, 0);
    act(tv, @selector(deleteToEndOfLine:));
    act(tv, @selector(yank:));
    tv.string = @"first para\nsecond para";
    tv.selectedRange = NSMakeRange(14, 0);
    act(tv, @selector(deleteToBeginningOfParagraph:));
    tv.selectedRange = NSMakeRange(3, 0);
    act(tv, @selector(deleteToEndOfParagraph:));
    act(tv, @selector(deleteToEndOfParagraph:));
    act(tv, @selector(yank:));
    tv.string = @"abcd";
    tv.selectedRange = NSMakeRange(2, 0);
    act(tv, @selector(transpose:));
    tv.selectedRange = NSMakeRange(4, 0);
    act(tv, @selector(transpose:));
    tv.selectedRange = NSMakeRange(0, 0);
    act(tv, @selector(transpose:));
    tv.selectedRange = NSMakeRange(1, 2);
    act(tv, @selector(transpose:));
    tv.string = @"ab";
    tv.selectedRange = NSMakeRange(1, 0);
    act(tv, @selector(insertNewline:));
    act(tv, @selector(insertTab:));
    act(tv, @selector(insertBacktab:));
    act(tv, @selector(insertLineBreak:));
    act(tv, @selector(insertParagraphSeparator:));
    act(tv, @selector(insertNewlineIgnoringFieldEditor:));
    act(tv, @selector(insertTabIgnoringFieldEditor:));
    act(tv, @selector(deleteBackward:));
    tv.selectedRange = NSMakeRange(0, 3);
    act(tv, @selector(delete:));
    tv.string = @"hello big World";
    tv.selectedRange = NSMakeRange(7, 0);
    act(tv, @selector(uppercaseWord:));
    tv.selectedRange = NSMakeRange(0, 9);
    act(tv, @selector(capitalizeWord:));
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(lowercaseWord:));
    act(tv, @selector(selectAll:));
    tv.selectedRange = NSMakeRange(7, 0);
    act(tv, @selector(selectWord:));
    tv.string = @"line one\nline two\nline three";
    tv.selectedRange = NSMakeRange(12, 0);
    act(tv, @selector(selectParagraph:));
    tv.selectedRange = NSMakeRange(12, 0);
    act(tv, @selector(selectLine:));

    /* not editable: actions do nothing; not selectable */
    tv.string = @"fixed";
    tv.editable = NO;
    tv.selectedRange = NSMakeRange(5, 0);
    [tv insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
    act(tv, @selector(deleteBackward:));
    act(tv, @selector(moveLeft:));
    out(@"  selectable after editable NO %d", tv.selectable);
    tv.selectable = NO;
    out(@"  editable after selectable NO %d", tv.editable);
    tv.editable = YES;
    out(@"  selectable after editable YES %d", tv.selectable);

    /* rich text: typing attributes carry over */
    NSTextView *rich = make_text_view(NSMakeRect(0, 0, 300, 200));
    rich.richText = YES;
    NSFont *big = [NSFont fontWithName:@"Roboto-Regular" size:20];
    [rich insertText:@"ab" replacementRange:NSMakeRange(NSNotFound, 0)];
    rich.typingAttributes = @{NSFontAttributeName : big};
    [rich insertText:@"cd" replacementRange:NSMakeRange(NSNotFound, 0)];
    NSRange er;
    NSFont *f = [rich.textStorage attribute:NSFontAttributeName atIndex:2 effectiveRange:&er];
    out(@"  rich: '%@' font at 2 %g range %@", rich.string, f.pointSize, Rg(er));
    rich.selectedRange = NSMakeRange(1, 0);
    out(@"  typing font after moving to 1: %g", [rich.typingAttributes[NSFontAttributeName] pointSize]);
    [rich insertText:[[NSAttributedString alloc] initWithString:@"Q" attributes:@{NSFontAttributeName : big}]
        replacementRange:NSMakeRange(NSNotFound, 0)];
    f = [rich.textStorage attribute:NSFontAttributeName atIndex:1 effectiveRange:&er];
    out(@"  rich insert attributed: '%@' font at 1 %g", rich.string, f.pointSize);
    /* plain text: one font throughout */
    NSTextView *plain = make_text_view(NSMakeRect(0, 0, 300, 200));
    plain.string = @"abc";
    plain.typingAttributes = @{NSFontAttributeName : big};
    plain.selectedRange = NSMakeRange(3, 0);
    [plain insertText:@"d" replacementRange:NSMakeRange(NSNotFound, 0)];
    f = [plain.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:&er];
    out(@"  plain: '%@' font %g over %@", plain.string, f.pointSize, Rg(er));
    [plain setFont:[NSFont fontWithName:@"Roboto-Regular" size:9] range:NSMakeRange(0, 1)];
    f = [plain.textStorage attribute:NSFontAttributeName atIndex:3 effectiveRange:&er];
    out(@"  plain setFont:range: font %g over %@", f.pointSize, Rg(er));
    [plain replaceCharactersInRange:NSMakeRange(1, 1) withString:@"XY"];
    show(plain, @"replaceCharactersInRange");
    out(@"  NSText string is copied %d", plain.string != plain.textStorage.string);
}

static void
test_movement(void)
{
    out(@"[movement]");
    NSTextView *tv = make_text_view(NSMakeRect(0, 0, 120, 300));
    /* wraps at 120 points less padding: several lines per paragraph */
    tv.string = @"The quick brown fox jumps over the lazy dog.\nSecond paragraph, short.\n\nFourth after an empty one";
    NSLayoutManager *lm = tv.layoutManager;
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < tv.string.length; n++) {
        NSRange r;
        NSRect lf = [lm lineFragmentRectForGlyphAtIndex:i effectiveRange:&r];
        out(@"  line %lu %@ %@", (unsigned long)n, Rg(r), R(lf));
        i = NSMaxRange(r);
    }
    SEL moves[] = {@selector(moveRight:), @selector(moveRight:), @selector(moveWordRight:), @selector(moveWordRight:),
                   @selector(moveWordLeft:), @selector(moveDown:), @selector(moveDown:), @selector(moveUp:),
                   @selector(moveToEndOfLine:), @selector(moveToBeginningOfLine:), @selector(moveToEndOfParagraph:),
                   @selector(moveRight:), @selector(moveToEndOfParagraph:), @selector(moveToBeginningOfParagraph:),
                   @selector(moveParagraphForwardAndModifySelection:), @selector(moveDown:), @selector(moveDown:),
                   @selector(moveDown:), @selector(moveDown:), @selector(moveUp:), @selector(moveToEndOfDocument:),
                   @selector(moveDown:), @selector(moveUp:), @selector(moveToBeginningOfDocument:),
                   @selector(moveUp:), @selector(moveForward:), @selector(moveBackward:), @selector(moveWordForward:),
                   @selector(moveWordBackward:), @selector(moveToRightEndOfLine:), @selector(moveToLeftEndOfLine:),
                   @selector(moveWordRight:), @selector(moveWordRight:), @selector(moveWordRight:),
                   @selector(moveWordRight:), @selector(moveWordRight:), @selector(moveWordRight:),
                   @selector(moveWordRight:), @selector(moveWordRight:), @selector(moveWordRight:),
                   @selector(moveWordRight:), @selector(moveWordRight:), @selector(moveWordRight:),
                   @selector(moveWordLeft:), @selector(moveWordLeft:), @selector(moveWordLeft:),
                   @selector(moveWordLeft:), @selector(moveWordLeft:), @selector(moveWordLeft:),
                   @selector(moveWordLeft:), @selector(moveWordLeft:), @selector(moveWordLeft:),
                   @selector(moveWordLeft:), @selector(moveWordLeft:), @selector(moveWordLeft:)};
    tv.selectedRange = NSMakeRange(0, 0);
    for (size_t i = 0; i < sizeof moves / sizeof *moves; i++)
        act(tv, moves[i]);

    out(@"[selection]");
    tv.selectedRange = NSMakeRange(10, 0);
    SEL ext[] = {@selector(moveRightAndModifySelection:), @selector(moveRightAndModifySelection:),
                 @selector(moveWordRightAndModifySelection:), @selector(moveLeftAndModifySelection:),
                 @selector(moveWordLeftAndModifySelection:), @selector(moveWordLeftAndModifySelection:),
                 @selector(moveLeftAndModifySelection:), @selector(moveRightAndModifySelection:),
                 @selector(moveDownAndModifySelection:), @selector(moveDownAndModifySelection:),
                 @selector(moveUpAndModifySelection:), @selector(moveToEndOfLineAndModifySelection:),
                 @selector(moveToBeginningOfLineAndModifySelection:),
                 @selector(moveToEndOfParagraphAndModifySelection:),
                 @selector(moveToBeginningOfDocumentAndModifySelection:),
                 @selector(moveToEndOfDocumentAndModifySelection:), @selector(moveLeft:),
                 @selector(moveForwardAndModifySelection:), @selector(moveBackwardAndModifySelection:),
                 @selector(moveBackwardAndModifySelection:), @selector(moveWordForwardAndModifySelection:),
                 @selector(moveParagraphBackwardAndModifySelection:), @selector(moveRight:),
                 @selector(moveToLeftEndOfLineAndModifySelection:), @selector(moveToRightEndOfLineAndModifySelection:),
                 @selector(moveParagraphForwardAndModifySelection:), @selector(moveParagraphForwardAndModifySelection:)};
    for (size_t i = 0; i < sizeof ext / sizeof *ext; i++)
        act(tv, ext[i]);
    /* a selection made by setSelectedRange, then extended either way */
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(moveRightAndModifySelection:));
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(moveLeftAndModifySelection:));
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(moveLeft:));
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(moveRight:));
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(moveUp:));
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(moveDown:));
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(moveWordLeft:));
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(moveWordRight:));
    tv.selectedRange = NSMakeRange(10, 5);
    act(tv, @selector(deleteBackward:));
    tv.selectedRange = NSMakeRange(200, 0);
    show(tv, @"select past the end");

    out(@"[geometry]");
    tv.string = @"Hello world, a second line wraps here.";
    for (NSUInteger i = 0; i <= tv.string.length; i += 7) {
        NSRect r = [lm boundingRectForGlyphRange:NSMakeRange(i, 0) inTextContainer:tv.textContainer];
        out(@"  insertion at %lu: %@", (unsigned long)i, R(r));
    }
    NSPoint pts[] = {{0, 0}, {30, 5}, {33, 5}, {80, 20}, {500, 8}, {10, 500}, {-5, 18}};
    for (size_t i = 0; i < sizeof pts / sizeof *pts; i++)
        out(@"  index for insertion at %@: %lu", NSStringFromPoint(pts[i]),
            (unsigned long)[tv characterIndexForInsertionAtPoint:pts[i]]);
    out(@"  frame %@", R(tv.frame));
    [tv sizeToFit];
    out(@"  after sizeToFit, not resizable %@", R(tv.frame));
    tv.verticallyResizable = YES;
    tv.maxSize = NSMakeSize(1e7, 1e7);
    [tv sizeToFit];
    out(@"  after sizeToFit %@", R(tv.frame));
    tv.string = @"x\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx\nx";
    [tv sizeToFit];
    out(@"  after long text %@", R(tv.frame));
    tv.string = @"short";
    [tv sizeToFit];
    out(@"  after short text %@", R(tv.frame));
    tv.minSize = NSMakeSize(0, 0);
    tv.string = @"x";
    [tv sizeToFit];
    out(@"  minSize 0 %@", R(tv.frame));
    tv.textContainerInset = NSMakeSize(3, 4);
    [tv sizeToFit];
    out(@"  inset 3,4 %@", R(tv.frame));
    tv.textContainerInset = NSZeroSize;
    tv.horizontallyResizable = YES;
    tv.textContainer.widthTracksTextView = NO;
    tv.textContainer.size = NSMakeSize(1e7, 1e7);
    tv.maxSize = NSMakeSize(1e7, 1e7);
    tv.string = @"a much wider line than one hundred and twenty";
    [tv sizeToFit];
    out(@"  horizontally resizable %@", R(tv.frame));
    tv.maxSize = NSMakeSize(150, 1e7);
    [tv sizeToFit];
    out(@"  maxSize 150 %@", R(tv.frame));
}

static void
test_delegate(void)
{
    out(@"[delegate]");
    NSTextView *tv = make_text_view(NSMakeRect(0, 0, 200, 100));
    Watcher *w = [Watcher new];
    tv.delegate = w;
    NSMutableArray *names = [NSMutableArray array];
    id obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:nil object:tv queue:nil usingBlock:^(NSNotification *n) {
          if (![n.name hasPrefix:@"NSViewFrame"] && ![n.name hasPrefix:@"NSViewBounds"] &&
              ![n.name hasPrefix:@"_"])
              [log_ addObject:[@"note " stringByAppendingString:n.name]];
        }];
    (void)names;
    [tv insertText:@"ab" replacementRange:NSMakeRange(NSNotFound, 0)];
    flush_log(@"insert");
    [tv insertText:@"c" replacementRange:NSMakeRange(NSNotFound, 0)];
    flush_log(@"insert again");
    tv.selectedRange = NSMakeRange(1, 0);
    flush_log(@"select");
    [tv moveRight:nil];
    flush_log(@"moveRight");
    [tv deleteBackward:nil];
    flush_log(@"deleteBackward");
    tv.string = @"set";
    flush_log(@"setString");
    w.refuse = YES;
    [tv insertText:@"no" replacementRange:NSMakeRange(NSNotFound, 0)];
    flush_log(@"refused");
    show(tv, @"after refusal");
    w.refuse = NO;
    [tv doCommandBySelector:@selector(moveLeft:)];
    flush_log(@"doCommandBySelector moveLeft:");
    w.claimCommands = YES;
    [tv doCommandBySelector:@selector(moveLeft:)];
    flush_log(@"claimed moveLeft:");
    show(tv, @"after claimed");
    w.claimCommands = NO;
    [tv doCommandBySelector:@selector(noSuchAction:)];
    flush_log(@"unknown command");
    [tv setSelectedRange:NSMakeRange(0, 1) affinity:NSSelectionAffinityDownstream stillSelecting:YES];
    flush_log(@"still selecting");
    [tv setSelectedRange:NSMakeRange(0, 2) affinity:NSSelectionAffinityDownstream stillSelecting:NO];
    flush_log(@"done selecting");
    [tv shouldChangeTextInRange:NSMakeRange(0, 1) replacementString:@"z"];
    [tv.textStorage replaceCharactersInRange:NSMakeRange(0, 1) withString:@"z"];
    [tv didChangeText];
    flush_log(@"manual change");
    [[NSNotificationCenter defaultCenter] removeObserver:obs];
}

static void
test_undo(void)
{
    out(@"[undo]");
    NSTextView *tv = make_text_view(NSMakeRect(0, 0, 200, 100));
    Watcher *w = [Watcher new];
    w.undo = [NSUndoManager new];
    w.undo.groupsByEvent = NO;
    w.quiet = YES;
    tv.delegate = w;
    tv.allowsUndo = YES;
    out(@"  undoManager is the delegate's %d", tv.undoManager == w.undo);
    [w.undo beginUndoGrouping];
    [tv insertText:@"one" replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.undo endUndoGrouping];
    [w.undo beginUndoGrouping];
    [tv insertText:@" two" replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.undo endUndoGrouping];
    show(tv, @"typed");
    out(@"  canUndo %d action name '%@'", w.undo.canUndo, w.undo.undoActionName);
    [w.undo undo];
    show(tv, @"undo");
    [w.undo undo];
    show(tv, @"undo");
    out(@"  canUndo %d canRedo %d redo name '%@'", w.undo.canUndo, w.undo.canRedo, w.undo.redoActionName);
    [w.undo redo];
    show(tv, @"redo");
    [w.undo redo];
    show(tv, @"redo");
    tv.selectedRange = NSMakeRange(3, 4);
    [w.undo beginUndoGrouping];
    [tv deleteBackward:nil];
    [w.undo endUndoGrouping];
    show(tv, @"delete");
    out(@"  action name '%@'", w.undo.undoActionName);
    [w.undo undo];
    show(tv, @"undo delete");
    tv.selectedRange = NSMakeRange(0, 3);
    [w.undo beginUndoGrouping];
    [tv insertText:@"ONE" replacementRange:NSMakeRange(NSNotFound, 0)];
    [w.undo endUndoGrouping];
    show(tv, @"replace");
    [w.undo undo];
    show(tv, @"undo replace");
}

static void
test_pasteboard(void)
{
    out(@"[pasteboard]");
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:@"org.finch.text-test"];
    out(@"  name %@", pb.name);
    [pb clearContents];
    [pb setString:@"pasted" forType:NSPasteboardTypeString];
    out(@"  types %@ string %@", [pb.types componentsJoinedByString:@","], [pb stringForType:NSPasteboardTypeString]);
    out(@"  general is %@", NSPasteboard.generalPasteboard.name);
    NSTextView *tv = make_text_view(NSMakeRect(0, 0, 200, 100));
    tv.string = @"copy me please";
    tv.selectedRange = NSMakeRange(5, 2);
    tv.selectedRange = NSMakeRange(0, 0);
    [tv readSelectionFromPasteboard:pb type:NSPasteboardTypeString];
    show(tv, @"read");
    /* The general pasteboard is the user's on the host: keep what was there and put it back. */
    NSPasteboard *general = NSPasteboard.generalPasteboard;
    NSMutableArray *saved = [NSMutableArray array];
    for (NSPasteboardItem *item in general.pasteboardItems) {
        NSPasteboardItem *copy = [NSPasteboardItem new];
        for (NSPasteboardType t in item.types) {
            NSData *d = [item dataForType:t];
            if (d)
                [copy setData:d forType:t];
        }
        [saved addObject:copy];
    }
    tv.selectedRange = NSMakeRange(0, 2);
    [tv copy:nil];
    out(@"  copy: '%@'", [general stringForType:NSPasteboardTypeString]);
    [tv cut:nil];
    show(tv, @"cut");
    out(@"  cut: '%@'", [general stringForType:NSPasteboardTypeString]);
    tv.selectedRange = NSMakeRange(tv.string.length, 0);
    [tv paste:nil];
    show(tv, @"paste");
    [tv pasteAsPlainText:nil];
    show(tv, @"pasteAsPlainText");
    [general clearContents];
    if (saved.count)
        [general writeObjects:saved];
}

static void
test_field_editor(void)
{
    out(@"[field editor]");
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 200) styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered defer:YES];
    win.releasedWhenClosed = NO;
    NSText *fe = [win fieldEditor:NO forObject:nil];
    out(@"  without create: %@", fe ? @"one" : @"nil");
    fe = [win fieldEditor:YES forObject:nil];
    out(@"  class %@ fieldEditor %d same again %d", [fe isKindOfClass:[NSTextView class]] ? @"NSTextView" : @"other",
        fe.fieldEditor, fe == [win fieldEditor:YES forObject:nil]);
    NSTextView *tv = (NSTextView *)fe;
    out(@"  rich %d vResizable %d hResizable %d drawsBackground %d selectable %d editable %d undo %d", tv.richText,
        tv.verticallyResizable, tv.horizontallyResizable, tv.drawsBackground, tv.selectable, tv.editable, tv.allowsUndo);
    out(@"  container tracks w %d h %d size %@", tv.textContainer.widthTracksTextView,
        tv.textContainer.heightTracksTextView, NSStringFromSize(tv.textContainer.size));
    Watcher *w = [Watcher new];
    tv.font = roboto;
    tv.string = @"field";
    tv.frame = NSMakeRect(10, 10, 200, 20);
    [win.contentView addSubview:tv];
    tv.delegate = w;
    out(@"  first responder %d", [win makeFirstResponder:tv]);
    flush_log(@"made first responder");
    tv.selectedRange = NSMakeRange(5, 0);
    [tv insertText:@"!" replacementRange:NSMakeRange(NSNotFound, 0)];
    flush_log(@"type");
    [tv insertText:@"?" replacementRange:NSMakeRange(NSNotFound, 0)];
    flush_log(@"type again");
    [tv insertNewline:nil];
    flush_log(@"Return");
    out(@"  first responder is the field editor %d", win.firstResponder == tv);
    [tv insertText:@"." replacementRange:NSMakeRange(NSNotFound, 0)];
    flush_log(@"type after Return");
    [tv insertTab:nil];
    flush_log(@"Tab");
    [tv insertText:@"." replacementRange:NSMakeRange(NSNotFound, 0)];
    flush_log(@"type after Tab");
    [tv insertBacktab:nil];
    flush_log(@"Backtab");
    [tv insertNewlineIgnoringFieldEditor:nil];
    flush_log(@"newline ignoring field editor");
    [tv insertTabIgnoringFieldEditor:nil];
    flush_log(@"tab ignoring field editor");
    show(tv, @"field editor text");
    [tv moveUp:nil];
    show(tv, @"moveUp");
    [tv moveDown:nil];
    show(tv, @"moveDown");
    [tv insertLineBreak:nil];
    flush_log(@"line break");
    show(tv, @"after line break");
    tv.fieldEditor = NO;
    [tv insertNewline:nil];
    flush_log(@"not a field editor: Return");
    show(tv, @"after");
    [win makeFirstResponder:nil];
    flush_log(@"resign");
    tv.fieldEditor = YES;
    [tv removeFromSuperview];
    [win close];
}

#pragma mark - Scrolling

@interface Doc : NSView
@property BOOL flip;
@end
@implementation Doc
- (BOOL)isFlipped
{
    return self.flip;
}
@end

static void
show_scroll(NSScrollView *sv, NSString *label)
{
    NSClipView *cv = sv.contentView;
    out(@"  %@: clip frame %@ bounds %@ visible %@", label, R(cv.frame), R(cv.bounds), R(sv.documentVisibleRect));
}

static void
test_scroll_view(void)
{
    out(@"[scroll view]");
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    out(@"  defaults: hasV %d hasH %d autohides %d border %ld drawsBackground %d lines %g,%g pages %g,%g", sv.hasVerticalScroller,
        sv.hasHorizontalScroller, sv.autohidesScrollers, (long)sv.borderType, sv.drawsBackground, sv.horizontalLineScroll,
        sv.verticalLineScroll, sv.horizontalPageScroll, sv.verticalPageScroll);
    out(@"  scrollers %d %d content view %@ document %@ copiesOnScroll %d", sv.verticalScroller != nil,
        sv.horizontalScroller != nil, [sv.contentView className], sv.documentView, sv.contentView.copiesOnScroll);
    out(@"  magnification %g allows %d min %g max %g", sv.magnification, sv.allowsMagnification, sv.minMagnification,
        sv.maxMagnification);
    out(@"  rulers %d %d ruler visible %d", sv.hasHorizontalRuler, sv.hasVerticalRuler, sv.rulersVisible);
    sv.scrollerStyle = NSScrollerStyleOverlay;
    sv.automaticallyAdjustsContentInsets = NO;
    show_scroll(sv, @"empty");
    sv.hasVerticalScroller = YES;
    sv.hasHorizontalScroller = YES;
    out(@"  scroller classes %@ %@", [sv.verticalScroller className], [sv.horizontalScroller className]);
    Doc *doc = [[Doc alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    doc.flip = YES;
    sv.documentView = doc;
    out(@"  document superview is clip %d next responder is clip %d", doc.superview == sv.contentView,
        doc.nextResponder == sv.contentView);
    show_scroll(sv, @"flipped doc");
    out(@"  clip is flipped %d documentRect %@ documentVisibleRect %@", sv.contentView.isFlipped,
        R(sv.contentView.documentRect), R(sv.contentView.documentVisibleRect));
    [sv.contentView scrollToPoint:NSMakePoint(50, 60)];
    show_scroll(sv, @"scrollToPoint 50,60");
    [sv reflectScrolledClipView:sv.contentView];
    out(@"  scrollers: v %.4f %.4f h %.4f %.4f", sv.verticalScroller.doubleValue, sv.verticalScroller.knobProportion,
        sv.horizontalScroller.doubleValue, sv.horizontalScroller.knobProportion);
    [sv.contentView scrollToPoint:NSMakePoint(1000, -50)];
    show_scroll(sv, @"scrollToPoint 1000,-50");
    NSRect c = [sv.contentView constrainBoundsRect:NSMakeRect(1000, 1000, 200, 100)];
    out(@"  constrain 1000,1000: %@", R(c));
    c = [sv.contentView constrainBoundsRect:NSMakeRect(-30, -30, 200, 100)];
    out(@"  constrain -30,-30: %@", R(c));
    c = [sv.contentView constrainBoundsRect:NSMakeRect(10, 10, 500, 500)];
    out(@"  constrain larger than the document: %@", R(c));
    [doc scrollPoint:NSMakePoint(30, 40)];
    show_scroll(sv, @"doc scrollPoint 30,40");
    BOOL moved = [doc scrollRectToVisible:NSMakeRect(350, 250, 20, 20)];
    show_scroll(sv, [NSString stringWithFormat:@"scrollRectToVisible far corner (%d)", moved]);
    moved = [doc scrollRectToVisible:NSMakeRect(350, 250, 20, 20)];
    out(@"  again: %d", moved);
    moved = [doc scrollRectToVisible:NSMakeRect(10, 10, 20, 20)];
    show_scroll(sv, [NSString stringWithFormat:@"scrollRectToVisible origin (%d)", moved]);
    [sv.contentView scrollToPoint:NSMakePoint(100, 100)];
    [sv reflectScrolledClipView:sv.contentView];
    out(@"  scrollers at 100,100: v %.4f %.4f h %.4f %.4f", sv.verticalScroller.doubleValue,
        sv.verticalScroller.knobProportion, sv.horizontalScroller.doubleValue, sv.horizontalScroller.knobProportion);
    [sv tile];
    show_scroll(sv, @"tile");
    [sv setFrameSize:NSMakeSize(300, 150)];
    show_scroll(sv, @"resized scroll view");
    [doc setFrameSize:NSMakeSize(100, 100)];
    show_scroll(sv, @"document shrunk");
    [doc setFrameSize:NSMakeSize(400, 300)];
    [sv.contentView scrollToPoint:NSMakePoint(0, 0)];

    out(@"  [lines and pages]");
    sv.verticalLineScroll = 15;
    sv.lineScroll = 12;
    out(@"  line %g h %g v %g", sv.lineScroll, sv.horizontalLineScroll, sv.verticalLineScroll);
    sv.pageScroll = 20;
    out(@"  page %g h %g v %g", sv.pageScroll, sv.horizontalPageScroll, sv.verticalPageScroll);
    NSTextView *tv = make_text_view(NSMakeRect(0, 0, 300, 150));
    (void)tv;

    out(@"  [unflipped document]");
    NSScrollView *sv2 = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    sv2.scrollerStyle = NSScrollerStyleOverlay;
    sv2.automaticallyAdjustsContentInsets = NO;
    sv2.hasVerticalScroller = YES;
    Doc *doc2 = [[Doc alloc] initWithFrame:NSMakeRect(0, 0, 150, 300)];
    sv2.documentView = doc2;
    show_scroll(sv2, @"unflipped doc");
    out(@"  clip is flipped %d", sv2.contentView.isFlipped);
    [doc2 scrollRectToVisible:NSMakeRect(0, 280, 10, 10)];
    show_scroll(sv2, @"to the top");
    [sv2 reflectScrolledClipView:sv2.contentView];
    out(@"  vertical scroller %.4f %.4f", sv2.verticalScroller.doubleValue, sv2.verticalScroller.knobProportion);
    [sv2.contentView scrollToPoint:NSMakePoint(0, 0)];
    [sv2 reflectScrolledClipView:sv2.contentView];
    out(@"  vertical scroller at 0: %.4f", sv2.verticalScroller.doubleValue);

    out(@"  [insets]");
    sv.contentInsets = NSEdgeInsetsMake(10, 5, 0, 0);
    show_scroll(sv, @"insets 10,5");
    out(@"  clip insets %g %g %g %g", sv.contentView.contentInsets.top, sv.contentView.contentInsets.left,
        sv.contentView.contentInsets.bottom, sv.contentView.contentInsets.right);
    sv.contentInsets = NSEdgeInsetsMake(0, 0, 0, 0);
    [sv.contentView scrollToPoint:NSMakePoint(0, 0)];

    out(@"  [magnification]");
    sv.allowsMagnification = YES;
    sv.magnification = 2;
    show_scroll(sv, @"magnification 2");
    out(@"  magnification %g", sv.magnification);
    sv.magnification = 10;
    out(@"  clamped to %g", sv.magnification);
    [sv setMagnification:2 centeredAtPoint:NSMakePoint(200, 150)];
    show_scroll(sv, @"2 centred at 200,150");
    [sv magnifyToFitRect:NSMakeRect(0, 0, 400, 200)];
    show_scroll(sv, @"fit 400x200");
    out(@"  magnification %g", sv.magnification);
    sv.magnification = 1;
    show_scroll(sv, @"back to 1");

    out(@"  [rulers and misc]");
    sv.borderType = NSBezelBorder;
    out(@"  border %ld", (long)sv.borderType);
    out(@"  content size for frame 200x100 (overlay) %@",
        NSStringFromSize([NSScrollView contentSizeForFrameSize:NSMakeSize(200, 100) horizontalScrollerClass:[NSScroller class]
                                         verticalScrollerClass:[NSScroller class] borderType:NSNoBorder
                                                   controlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleOverlay]));
    out(@"  frame size for content 200x100 bezel (overlay) %@",
        NSStringFromSize([NSScrollView frameSizeForContentSize:NSMakeSize(200, 100) horizontalScrollerClass:nil
                                         verticalScrollerClass:nil borderType:NSBezelBorder
                                                   controlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleOverlay]));
    out(@"  line border frame %@",
        NSStringFromSize([NSScrollView frameSizeForContentSize:NSMakeSize(200, 100) horizontalScrollerClass:nil
                                         verticalScrollerClass:nil borderType:NSLineBorder
                                                   controlSize:NSControlSizeRegular scrollerStyle:NSScrollerStyleOverlay]));
    sv.borderType = NSLineBorder;
    show_scroll(sv, @"line border");
    sv.borderType = NSNoBorder;
    sv.hasVerticalScroller = NO;
    out(@"  hasVerticalScroller NO: scroller kept %d hidden %d", sv.verticalScroller != nil, sv.verticalScroller.isHidden);
    NSScroller *s = [[NSScroller alloc] initWithFrame:NSMakeRect(0, 0, 15, 100)];
    out(@"  scroller: value %g proportion %g enabled %d usable parts %lu", s.doubleValue, s.knobProportion,
        s.enabled, (unsigned long)s.usableParts);
    s.knobProportion = 0.25;
    s.doubleValue = 0.5;
    out(@"  after set: %g %g", s.doubleValue, s.knobProportion);
    s.doubleValue = 3;
    out(@"  clamped %g", s.doubleValue);
}

static void
test_clip_view(void)
{
    out(@"[clip view]");
    NSClipView *cv = [[NSClipView alloc] initWithFrame:NSMakeRect(0, 0, 100, 50)];
    out(@"  drawsBackground %d copiesOnScroll %d flipped %d documentView %@ documentRect %@", cv.drawsBackground,
        cv.copiesOnScroll, cv.isFlipped, cv.documentView, R(cv.documentRect));
    Doc *d = [[Doc alloc] initWithFrame:NSMakeRect(5, 5, 300, 200)];
    cv.documentView = d;
    out(@"  doc frame %@ clip bounds %@ documentRect %@ visible %@", R(d.frame), R(cv.bounds), R(cv.documentRect),
        R(cv.documentVisibleRect));
    [cv scrollToPoint:NSMakePoint(400, 400)];
    out(@"  after scrollToPoint 400,400: %@", R(cv.bounds));
    [cv setBoundsOrigin:NSMakePoint(400, 400)];
    out(@"  setBoundsOrigin constrains: %@", R(cv.bounds));
    NSMutableArray *got = [NSMutableArray array];
    id obs = [[NSNotificationCenter defaultCenter] addObserverForName:NSViewBoundsDidChangeNotification object:cv
                                                                queue:nil usingBlock:^(NSNotification *n) {
                                                                  [got addObject:R(cv.bounds)];
                                                                }];
    cv.postsBoundsChangedNotifications = YES;
    [cv scrollToPoint:NSMakePoint(10, 20)];
    out(@"  bounds notifications %@", [got componentsJoinedByString:@" "]);
    [[NSNotificationCenter defaultCenter] removeObserver:obs];
    cv.documentView = nil;
    out(@"  documentView removed: subviews %lu", (unsigned long)cv.subviews.count);
}

static void
test_nib(const char *path)
{
    out(@"[nib]");
    NSData *data = [NSData dataWithContentsOfFile:@(path)];
    NSNib *nib = data ? [[NSNib alloc] initWithNibData:data bundle:nil] : nil;
    NSArray *top = nil;
    if (![nib instantiateWithOwner:nil topLevelObjects:&top]) {
        out(@"  can't load %s", path);
        return;
    }
    NSMutableArray *views = [NSMutableArray array];
    for (id o in top)
        if ([o isKindOfClass:[NSScrollView class]])
            [views addObject:o];
    [views sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
      return [@(b.frame.size.width) compare:@(a.frame.size.width)];
    }];
    for (NSScrollView *sv in views) {
        out(@"  scroll view %@ frame %@ hasV %d hasH %d autohides %d border %ld", sv.className, R(sv.frame),
            sv.hasVerticalScroller, sv.hasHorizontalScroller, sv.autohidesScrollers, (long)sv.borderType);
        out(@"    lines %g,%g pages %g,%g magnification %g allows %d min %g max %g", sv.horizontalLineScroll,
            sv.verticalLineScroll, sv.horizontalPageScroll, sv.verticalPageScroll, sv.magnification,
            sv.allowsMagnification, sv.minMagnification, sv.maxMagnification);
        out(@"    predominant axis %d elasticity %ld %ld", sv.usesPredominantAxisScrolling,
            (long)sv.horizontalScrollElasticity, (long)sv.verticalScrollElasticity);
        NSClipView *cv = sv.contentView;
        out(@"    clip %@ frame %@ bounds %@ drawsBackground %d copiesOnScroll %d", cv.className, R(cv.frame),
            R(cv.bounds), cv.drawsBackground, cv.copiesOnScroll);
        out(@"    scrollers %@ %@ hidden %d %d", sv.verticalScroller.className, sv.horizontalScroller.className,
            sv.verticalScroller.isHidden, sv.horizontalScroller.isHidden);
        id doc = sv.documentView;
        out(@"    document %@ frame %@ superview is clip %d", [doc className], R([doc frame]), [doc superview] == cv);
        if ([doc isKindOfClass:[NSTextView class]]) {
            NSTextView *tv = doc;
            out(@"    text '%@' editable %d selectable %d rich %d fieldEditor %d drawsBackground %d imports %d undo %d",
                tv.string, tv.editable, tv.selectable, tv.richText, tv.fieldEditor, tv.drawsBackground,
                tv.importsGraphics, tv.allowsUndo);
            out(@"    resizable h %d v %d min %@ max %@ font is the system font %d, %g", tv.horizontallyResizable,
                tv.verticallyResizable, NSStringFromSize(tv.minSize), NSStringFromSize(tv.maxSize),
                [tv.font isEqual:[NSFont systemFontOfSize:13]], tv.font.pointSize);
            out(@"    container %@ tracks %d %d padding %g lm %d storage %d same tv %d", NSStringFromSize(tv.textContainer.size),
                tv.textContainer.widthTracksTextView, tv.textContainer.heightTracksTextView,
                tv.textContainer.lineFragmentPadding, tv.layoutManager != nil, tv.textStorage != nil,
                tv.textContainer.textView == tv);
            out(@"    smart insert %d continuous spelling %d uses ruler %d", tv.smartInsertDeleteEnabled,
                tv.continuousSpellCheckingEnabled, tv.usesRuler);
            NSRange er;
            NSFont *f = [tv.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:&er];
            out(@"    first run %@ size %g", Rg(er), f.pointSize);
            [tv insertText:@" more" replacementRange:NSMakeRange(tv.string.length, 0)];
            out(@"    after typing '%@'", tv.string);
        }
    }
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("AppKit: %s\n", class_getImageName([NSTextView class]));
        const char *nib = "/usr/local/share/finch/appkit-text-test.nib", *font = NULL;
        for (int i = 1; i < argc; i++) {
            if (strstr(argv[i], ".ttf"))
                font = argv[i];
            else
                nib = argv[i];
        }
        [NSApplication sharedApplication];
        log_ = [NSMutableArray array];
        roboto = load_roboto(font);
        if (!roboto) {
            out(@"no Roboto");
            return 1;
        }
        out(@"[constants]");
        out(@"  %@ %@ %@ %@", NSTextDidBeginEditingNotification, NSTextDidEndEditingNotification,
            NSTextDidChangeNotification, NSTextMovementUserInfoKey);
        out(@"  %@ %@ %@", NSTextViewDidChangeSelectionNotification, NSTextViewDidChangeTypingAttributesNotification,
            NSTextViewWillChangeNotifyingTextViewNotification);
        out(@"  movements %ld %ld %ld %ld %ld %ld %ld", (long)NSTextMovementReturn, (long)NSTextMovementTab,
            (long)NSTextMovementBacktab, (long)NSTextMovementLeft, (long)NSTextMovementCancel,
            (long)NSTextMovementOther, (long)NSIllegalTextMovement);
        out(@"  %@ %@ %@ %@ %@", NSPasteboardNameGeneral, NSPasteboardNameFind, NSPasteboardTypeString,
            NSPasteboardTypeRTF, NSStringPboardType);
        test_defaults();
        test_editing();
        test_movement();
        test_delegate();
        test_undo();
        test_pasteboard();
        test_field_editor();
        test_clip_view();
        test_scroll_view();
        test_nib(nib);
    }
    return 0;
}
