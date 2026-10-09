/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextView (TextKit 1): editing and showing an NSTextStorage laid out by
 * UIFoundation's NSLayoutManager in an NSTextContainer.
 *
 * Behaviour is as measured against macOS 26.4's AppKit:
 * - Editing goes -shouldChangeTextInRange:replacementString: (which begins
 *   editing: textShouldBeginEditing:, NSTextDidBeginEditingNotification),
 *   the change, the new selection, then -didChangeText
 *   (NSTextDidChangeNotification). A text view that isn't its window's
 *   first responder ends editing again right after each change.
 * - The selection: setting it asks the delegate, updates the typing
 *   attributes when it moves, and posts NSTextViewDidChangeSelection-
 *   Notification with the old range; while still selecting (a drag) none of
 *   that happens until the end.
 * - Movement: vertical moves keep a goal x; a caret at the end of a wrapped
 *   line belongs to that line (upstream affinity). Extending a selection
 *   moves one end: the end it last moved, else the end in the direction of
 *   travel; word and paragraph moves stop at the anchor rather than cross
 *   it; moves to a line, paragraph or document boundary extend the start
 *   (beginning moves) or the end (end moves).
 * - Kills (the delete-to-... actions) gather consecutive deletions into the
 *   kill buffer that -yank: inserts.
 * - Undo restores the replaced text and selects it; redo puts the caret
 *   after the text it puts back. Typing coalesces while editing goes on.
 * - The field editor ends editing on Return, Tab and Backtab with the
 *   matching NSTextMovement.
 *
 * Also here: -[NSWindow fieldEditor:forObject:] and -endEditingFor:, and
 * NSTextViewSharedData, which nibs archive a text view's settings in.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"

@interface NSTextViewSharedData : NSObject <NSCoding>
@end

@implementation NSTextViewSharedData {
@public
    uint32_t _flags, _moreFlags;
    NSColor *_background, *_insertion;
    NSDictionary *_selected, *_marked, *_link;
    NSParagraphStyle *_paragraphStyle;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _flags = (uint32_t)[coder decodeIntForKey:@"NSFlags"];
        _moreFlags = (uint32_t)[coder decodeIntForKey:@"NSMoreFlags"];
        _background = [[coder decodeObjectForKey:@"NSBackgroundColor"] retain];
        _insertion = [[coder decodeObjectForKey:@"NSInsertionColor"] retain];
        _selected = [[coder decodeObjectForKey:@"NSSelectedAttributes"] retain];
        /* NSMarkedAttributes and NSLinkAttributes (which holds an NSCursor) are left to the defaults. */
        _paragraphStyle = [[coder decodeObjectForKey:@"NSDefaultParagraphStyle"] retain];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:(int)_flags forKey:@"NSFlags"];
    [coder encodeInt:(int)_moreFlags forKey:@"NSMoreFlags"];
    if (_background)
        [coder encodeObject:_background forKey:@"NSBackgroundColor"];
    if (_insertion)
        [coder encodeObject:_insertion forKey:@"NSInsertionColor"];
    if (_selected)
        [coder encodeObject:_selected forKey:@"NSSelectedAttributes"];
    if (_marked)
        [coder encodeObject:_marked forKey:@"NSMarkedAttributes"];
    if (_link)
        [coder encodeObject:_link forKey:@"NSLinkAttributes"];
    if (_paragraphStyle)
        [coder encodeObject:_paragraphStyle forKey:@"NSDefaultParagraphStyle"];
}

- (void)dealloc
{
    [_background release];
    [_insertion release];
    [_selected release];
    [_marked release];
    [_link release];
    [_paragraphStyle release];
    [super dealloc];
}

@end

/* NSTextViewSharedData's NSFlags, as ibtool writes them. */
enum {
    TF_SELECTABLE = 1 << 0,
    TF_EDITABLE = 1 << 1,
    TF_RICH = 1 << 2,
    TF_IMPORTS_GRAPHICS = 1 << 3,
    TF_FIELD_EDITOR = 1 << 4,
    TF_RULER_VISIBLE = 1 << 5,
    TF_USES_RULER = 1 << 6,
    TF_CONTINUOUS_SPELLING = 1 << 7,
    TF_DRAWS_BACKGROUND = 1 << 8,
    TF_SMART_INSERT = 1 << 9,
    TF_ALLOWS_UNDO = 1 << 10,
    TF_USES_FONT_PANEL = 1 << 11,
    TF_USES_FIND_PANEL = 1 << 13,
    TF_DOCUMENT_BACKGROUND = 1 << 14,
    TF_GRAMMAR = 1 << 15,
    TF_IMAGE_EDITING = 1 << 16,
    TF_QUOTES = 1 << 17,
    TF_LINKS = 1 << 18,
    TF_DATA_DETECTION = 3 << 22,
    TF_DASHES = 1 << 24,
    TF_REPLACEMENT = 1 << 25,
    TF_SPELLING_CORRECTION = 1 << 26,
    TF_INCREMENTAL_SEARCH = 1 << 30,
    TF_INSPECTOR_BAR = 1u << 31,
};

/* NSTVFlags */
enum { TV_HORIZONTALLY_RESIZABLE = 1 << 0, TV_VERTICALLY_RESIZABLE = 1 << 1 };

/* An undoable replacement: the text now in `range` was `old`. */
@interface FinchTextUndo : NSObject {
@public
    NSRange _range;
    NSAttributedString *_old;
    BOOL _redo;  /* putting back what an undo took out: the caret goes after it */
}
@end

@implementation FinchTextUndo
- (void)dealloc
{
    [_old release];
    [super dealloc];
}
@end

/* Paragraphs and composed characters, by hand. */
static BOOL
is_paragraph_separator(unichar c)
{
    return c == '\n' || c == '\r' || c == 0x2029;
}

/* The paragraph (with its separator) holding a range. */
static NSRange
paragraph_range(NSString *s, NSRange r)
{
    NSUInteger n = [s length];
    NSUInteger a = MIN(r.location, n);
    while (a > 0 && !is_paragraph_separator([s characterAtIndex:a - 1]))
        a--;
    NSUInteger b = r.length ? NSMaxRange(r) - 1 : r.location;
    b = MIN(b, n);
    while (b < n && !is_paragraph_separator([s characterAtIndex:b]))
        b++;
    if (b < n) {
        if ([s characterAtIndex:b] == '\r' && b + 1 < n && [s characterAtIndex:b + 1] == '\n')
            b++;
        b++;
    }
    return NSMakeRange(a, b - a);
}

/* The end of i's paragraph, before its separator. */
static NSUInteger
paragraph_contents_end(NSString *s, NSUInteger i)
{
    NSUInteger n = [s length];
    i = MIN(i, n);
    while (i < n && !is_paragraph_separator([s characterAtIndex:i]))
        i++;
    return i;
}

/* A user-perceived character: a surrogate pair, and any combining marks after it. */
static NSRange
composed_range(NSString *s, NSUInteger i)
{
    NSUInteger n = [s length];
    if (i >= n)
        return NSMakeRange(n, 0);
    NSUInteger a = i;
    while (a > 0 && (CFStringIsSurrogateLowCharacter([s characterAtIndex:a]) ||
                     [[NSCharacterSet nonBaseCharacterSet] characterIsMember:[s characterAtIndex:a]]))
        a--;
    NSUInteger b = a + 1;
    if (b < n && CFStringIsSurrogateHighCharacter([s characterAtIndex:a]) && CFStringIsSurrogateLowCharacter([s characterAtIndex:b]))
        b++;
    while (b < n && [[NSCharacterSet nonBaseCharacterSet] characterIsMember:[s characterAtIndex:b]])
        b++;
    return NSMakeRange(a, b - a);
}

/* The kill buffer, shared by all text views as on macOS. */
static NSMutableString *kill_buffer;
static id kill_view;
static NSUInteger kill_generation;

enum { SIDE_UNKNOWN, SIDE_START, SIDE_END };

@interface NSTextView ()
- (void)_finchTextStorageEdited:(NSTextStorageEditActions)mask range:(NSRange)range changeInLength:(NSInteger)delta;
@end

@implementation NSTextView {
    NSTextStorage *_storage;
    NSLayoutManager *_lm;
    NSTextContainer *_container;
    id _delegate; /* not retained */
    NSRange _sel, _selBeforeDrag, _marked, _dragUnit;
    NSSelectionAffinity _affinity;
    NSSelectionGranularity _granularity;
    int _movingSide;
    CGFloat _goalX;
    NSDictionary *_typing;
    NSColor *_background, *_insertionColor;
    NSDictionary *_selectedAttributes, *_markedAttributes, *_linkAttributes;
    NSParagraphStyle *_defaultParagraphStyle;
    NSSize _minSize, _maxSize, _inset;
    NSTimer *_blink;
    FinchTextUndo *_typingUndo;
    NSUInteger _generation; /* bumped by every change of text or selection */
    NSUInteger _mark;
    struct {
        unsigned editable : 1, selectable : 1, rich : 1, imports : 1, fieldEditor : 1, drawsBackground : 1;
        unsigned allowsUndo : 1, usesFontPanel : 1, usesRuler : 1, rulerVisible : 1, hResizable : 1, vResizable : 1;
        unsigned smartInsert : 1, continuousSpelling : 1, grammar : 1, quotes : 1, dashes : 1, links : 1, data : 1;
        unsigned replacement : 1, spellingCorrection : 1, completion : 1, findBar : 1, incremental : 1;
        unsigned documentBackground : 1, imageEditing : 1, inspectorBar : 1, findPanel : 1;
        unsigned editing : 1, caretOn : 1, stillSelecting : 1, hasGoal : 1, selfEdit : 1, dragging : 1;
        unsigned smartCopyPaste : 1, writingTools : 1;
    } _t;
}

#pragma mark - Creating

static NSDictionary *
default_typing_attributes(void)
{
    return @{
        NSFontAttributeName : [NSFont fontWithName:@"Helvetica" size:12] ?: [NSFont userFontOfSize:12],
        NSForegroundColorAttributeName : [NSColor textColor]
    };
}

static void
tv_defaults(NSTextView *self)
{
    self->_t.editable = self->_t.selectable = self->_t.rich = YES;
    self->_t.drawsBackground = self->_t.usesFontPanel = self->_t.usesRuler = self->_t.smartInsert = YES;
    self->_t.completion = self->_t.smartCopyPaste = YES;
    self->_goalX = 0;
    self->_mark = NSNotFound;
    self->_marked = NSMakeRange(NSNotFound, 0);
    if (!self->_typing)
        self->_typing = [default_typing_attributes() retain];
}

/* Take a text container and the layout manager and text storage it is part of. */
static void
adopt(NSTextView *self, NSTextContainer *container)
{
    [container retain];
    [self->_container setTextView:nil];
    [self->_container release];
    self->_container = container;
    [container setTextView:self];
    NSLayoutManager *lm = [container layoutManager];
    [lm retain];
    [self->_lm release];
    self->_lm = lm;
    NSTextStorage *ts = [lm textStorage];
    [ts retain];
    [self->_storage release];
    self->_storage = ts;
}

- (instancetype)initWithFrame:(NSRect)frame textContainer:(NSTextContainer *)container
{
    if ((self = [super initWithFrame:frame])) {
        tv_defaults(self);
        _minSize = frame.size;
        _maxSize = frame.size;
        adopt(self, container);
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    NSTextStorage *ts = [[NSTextStorage alloc] init];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    [ts addLayoutManager:lm];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(frame.size.width, 10000000)];
    [tc setWidthTracksTextView:YES];
    [lm addTextContainer:tc];
    self = [self initWithFrame:frame textContainer:tc];
    if (self) {
        _t.vResizable = YES;
        _maxSize = NSMakeSize(frame.size.width, 10000000);
    }
    [tc release];
    [lm release];
    [ts release];
    return self;
}

- (instancetype)initUsingTextLayoutManager:(BOOL)usingTextLayoutManager
{
    return [self initWithFrame:NSZeroRect];
}

+ (instancetype)textViewUsingTextLayoutManager:(BOOL)usingTextLayoutManager
{
    return [[[self alloc] initWithFrame:NSZeroRect] autorelease];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_delegate)
        [self setDelegate:nil];
    [_blink invalidate];
    [_blink release];
    if (kill_view == self)
        kill_view = nil;
    [_container setTextView:nil];
    [_container release];
    [_lm release];
    [_storage release];
    [_typing release];
    [_background release];
    [_insertionColor release];
    [_selectedAttributes release];
    [_markedAttributes release];
    [_linkAttributes release];
    [_defaultParagraphStyle release];
    [_typingUndo release];
    [super dealloc];
}

#pragma mark - The text system

- (NSTextContainer *)textContainer { return _container; }
- (void)setTextContainer:(NSTextContainer *)container { adopt(self, container); }
- (void)replaceTextContainer:(NSTextContainer *)container
{
    [_container replaceLayoutManager:[container layoutManager] ?: _lm];
    adopt(self, container);
}
- (NSLayoutManager *)layoutManager { return _lm; }
- (NSTextStorage *)textStorage { return _storage; }
- (NSTextLayoutManager *)textLayoutManager { return nil; }
- (NSTextContentStorage *)textContentStorage { return nil; }

- (NSSize)textContainerInset { return _inset; }
- (void)setTextContainerInset:(NSSize)inset
{
    _inset = inset;
    [self setConstrainedFrameSize:[self frame].size];
    [self setNeedsDisplay:YES];
}
- (NSPoint)textContainerOrigin { return NSMakePoint(_inset.width, _inset.height); }
- (void)invalidateTextContainerOrigin {}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return _t.drawsBackground && [[self backgroundColor] alphaComponent] >= 1; }

#pragma mark - Settings

- (id<NSTextViewDelegate>)delegate { return _delegate; }

static void
observe(NSNotificationCenter *nc, id d, SEL sel, NSString *name, id object)
{
    if ([d respondsToSelector:sel])
        [nc addObserver:d selector:sel name:name object:object];
}

- (void)setDelegate:(id<NSTextViewDelegate>)delegate
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_delegate) {
        [nc removeObserver:_delegate name:NSTextDidBeginEditingNotification object:self];
        [nc removeObserver:_delegate name:NSTextDidEndEditingNotification object:self];
        [nc removeObserver:_delegate name:NSTextDidChangeNotification object:self];
        [nc removeObserver:_delegate name:NSTextViewDidChangeSelectionNotification object:self];
        [nc removeObserver:_delegate name:NSTextViewDidChangeTypingAttributesNotification object:self];
    }
    _delegate = delegate;
    if (delegate) {
        observe(nc, delegate, @selector(textDidBeginEditing:), NSTextDidBeginEditingNotification, self);
        observe(nc, delegate, @selector(textDidEndEditing:), NSTextDidEndEditingNotification, self);
        observe(nc, delegate, @selector(textDidChange:), NSTextDidChangeNotification, self);
        observe(nc, delegate, @selector(textViewDidChangeSelection:), NSTextViewDidChangeSelectionNotification, self);
        observe(nc, delegate, @selector(textViewDidChangeTypingAttributes:),
                NSTextViewDidChangeTypingAttributesNotification, self);
    }
}

#define FLAG(get, set, field)                 \
    -(BOOL)get { return _t.field; }           \
    -(void)set:(BOOL)flag { _t.field = flag; }

FLAG(importsGraphics, setImportsGraphics, imports)
FLAG(allowsUndo, setAllowsUndo, allowsUndo)
FLAG(usesFontPanel, setUsesFontPanel, usesFontPanel)
FLAG(usesRuler, setUsesRuler, usesRuler)
FLAG(isRulerVisible, setRulerVisible, rulerVisible)
FLAG(smartInsertDeleteEnabled, setSmartInsertDeleteEnabled, smartInsert)
FLAG(isContinuousSpellCheckingEnabled, setContinuousSpellCheckingEnabled, continuousSpelling)
FLAG(isGrammarCheckingEnabled, setGrammarCheckingEnabled, grammar)
FLAG(isAutomaticQuoteSubstitutionEnabled, setAutomaticQuoteSubstitutionEnabled, quotes)
FLAG(isAutomaticDashSubstitutionEnabled, setAutomaticDashSubstitutionEnabled, dashes)
FLAG(isAutomaticLinkDetectionEnabled, setAutomaticLinkDetectionEnabled, links)
FLAG(isAutomaticDataDetectionEnabled, setAutomaticDataDetectionEnabled, data)
FLAG(isAutomaticTextReplacementEnabled, setAutomaticTextReplacementEnabled, replacement)
FLAG(isAutomaticSpellingCorrectionEnabled, setAutomaticSpellingCorrectionEnabled, spellingCorrection)
FLAG(isAutomaticTextCompletionEnabled, setAutomaticTextCompletionEnabled, completion)
FLAG(usesFindBar, setUsesFindBar, findBar)
FLAG(usesFindPanel, setUsesFindPanel, findPanel)
FLAG(isIncrementalSearchingEnabled, setIncrementalSearchingEnabled, incremental)
FLAG(allowsDocumentBackgroundColorChange, setAllowsDocumentBackgroundColorChange, documentBackground)
FLAG(allowsImageEditing, setAllowsImageEditing, imageEditing)
FLAG(usesInspectorBar, setUsesInspectorBar, inspectorBar)
FLAG(smartCopyPasteEnabled, setSmartCopyPasteEnabled, smartCopyPaste)
#undef FLAG

- (BOOL)isEditable { return _t.editable; }
- (void)setEditable:(BOOL)flag
{
    _t.editable = flag;
    if (flag)
        _t.selectable = YES;
    [self setNeedsDisplay:YES];
}
- (BOOL)isSelectable { return _t.selectable; }
- (void)setSelectable:(BOOL)flag
{
    _t.selectable = flag;
    if (!flag)
        _t.editable = NO;
    [self setNeedsDisplay:YES];
}
- (BOOL)isRichText { return _t.rich; }
- (void)setRichText:(BOOL)flag
{
    _t.rich = flag;
    if (!flag)
        _t.imports = NO;
}
- (BOOL)isFieldEditor { return _t.fieldEditor; }
- (void)setFieldEditor:(BOOL)flag { _t.fieldEditor = flag; }
- (BOOL)drawsBackground { return _t.drawsBackground; }
- (void)setDrawsBackground:(BOOL)flag
{
    _t.drawsBackground = flag;
    [self setNeedsDisplay:YES];
}
- (NSColor *)backgroundColor { return _background ?: [NSColor textBackgroundColor]; }
- (void)setBackgroundColor:(NSColor *)color
{
    [_background autorelease];
    _background = [color retain];
    [self setNeedsDisplay:YES];
}
- (NSColor *)insertionPointColor { return _insertionColor ?: [NSColor textInsertionPointColor]; }
- (void)setInsertionPointColor:(NSColor *)color
{
    [_insertionColor autorelease];
    _insertionColor = [color retain];
}
- (NSDictionary *)selectedTextAttributes
{
    return _selectedAttributes ?: @{NSBackgroundColorAttributeName : [NSColor selectedTextBackgroundColor]};
}
- (void)setSelectedTextAttributes:(NSDictionary *)attrs
{
    [_selectedAttributes autorelease];
    _selectedAttributes = [attrs copy];
}
- (NSDictionary *)markedTextAttributes
{
    return _markedAttributes ?: @{NSUnderlineStyleAttributeName : @(NSUnderlineStyleSingle)};
}
- (void)setMarkedTextAttributes:(NSDictionary *)attrs
{
    [_markedAttributes autorelease];
    _markedAttributes = [attrs copy];
}
- (NSDictionary *)linkTextAttributes { return _linkAttributes; }
- (void)setLinkTextAttributes:(NSDictionary *)attrs
{
    [_linkAttributes autorelease];
    _linkAttributes = [attrs copy];
}
- (NSParagraphStyle *)defaultParagraphStyle { return _defaultParagraphStyle; }
- (void)setDefaultParagraphStyle:(NSParagraphStyle *)style
{
    [_defaultParagraphStyle autorelease];
    _defaultParagraphStyle = [style copy];
}
- (BOOL)isCoalescingUndo { return _typingUndo != nil; }
- (void)breakUndoCoalescing
{
    [_typingUndo release];
    _typingUndo = nil;
}
- (NSWritingDirection)baseWritingDirection { return NSWritingDirectionNatural; }
- (void)setBaseWritingDirection:(NSWritingDirection)direction {}
- (BOOL)displaysLinkToolTips { return YES; }
- (void)setDisplaysLinkToolTips:(BOOL)flag {}
- (BOOL)acceptsGlyphInfo { return NO; }
- (void)setAcceptsGlyphInfo:(BOOL)flag {}
- (NSTextCheckingTypes)enabledTextCheckingTypes { return 0; }
- (void)setEnabledTextCheckingTypes:(NSTextCheckingTypes)types {}
- (NSInteger)spellCheckerDocumentTag { return 0; }
- (BOOL)allowsCharacterPickerTouchBarItem { return YES; }
- (void)setAllowsCharacterPickerTouchBarItem:(BOOL)flag {}
- (NSWritingToolsBehavior)writingToolsBehavior { return NSWritingToolsBehaviorNone; }
- (void)setWritingToolsBehavior:(NSWritingToolsBehavior)behavior {}
- (BOOL)isWritingToolsActive { return NO; }
- (NSTextFinder *)textFinder { return nil; }
- (NSArray<NSString *> *)allowedInputSourceLocales { return nil; }
- (void)setAllowedInputSourceLocales:(NSArray<NSString *> *)locales {}

#pragma mark - Typing attributes and the whole text's font, colour, alignment

- (NSDictionary *)typingAttributes { return _typing; }

- (void)setTypingAttributes:(NSDictionary *)attrs
{
    attrs = attrs ?: @{};
    if ([attrs isEqualToDictionary:_typing])
        return;
    [_typing autorelease];
    _typing = [attrs copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSTextViewDidChangeTypingAttributesNotification
                                                        object:self];
}

static void
set_typing_value(NSTextView *self, NSString *key, id value)
{
    NSMutableDictionary *t = [[self->_typing mutableCopy] autorelease];
    if (value)
        t[key] = value;
    else
        [t removeObjectForKey:key];
    [self->_typing autorelease];
    self->_typing = [t copy];
}

/* Set or remove an attribute over a range of the storage, without undo or the delegate. */
static void
set_attribute(NSTextView *self, NSString *key, id value, NSRange range)
{
    if (!range.length)
        return;
    self->_t.selfEdit = YES;
    if (value)
        [self->_storage addAttribute:key value:value range:range];
    else
        [self->_storage removeAttribute:key range:range];
    self->_t.selfEdit = NO;
}

- (NSFont *)font
{
    if ([_storage length])
        return [_storage attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] ?: _typing[NSFontAttributeName];
    return _typing[NSFontAttributeName];
}

- (void)setFont:(NSFont *)font
{
    if (!font)
        return;
    set_attribute(self, NSFontAttributeName, font, NSMakeRange(0, [_storage length]));
    set_typing_value(self, NSFontAttributeName, font);
    [self _finchResize];
}

- (void)setFont:(NSFont *)font range:(NSRange)range
{
    if (!font)
        return;
    set_attribute(self, NSFontAttributeName, font, range);
    if (NSMaxRange(range) >= [_storage length] || ![_storage length])
        set_typing_value(self, NSFontAttributeName, font);
    [self _finchResize];
}

- (NSColor *)textColor
{
    if ([_storage length])
        return [_storage attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
    return _typing[NSForegroundColorAttributeName];
}

- (void)setTextColor:(NSColor *)color
{
    set_attribute(self, NSForegroundColorAttributeName, color, NSMakeRange(0, [_storage length]));
    set_typing_value(self, NSForegroundColorAttributeName, color);
    [self setNeedsDisplay:YES];
}

- (void)setTextColor:(NSColor *)color range:(NSRange)range
{
    set_attribute(self, NSForegroundColorAttributeName, color, range);
    [self setNeedsDisplay:YES];
}

static NSParagraphStyle *
paragraph_style_at(NSTextView *self, NSUInteger i)
{
    NSParagraphStyle *ps = [self->_storage length] ? [self->_storage attribute:NSParagraphStyleAttributeName
                                                                       atIndex:MIN(i, [self->_storage length] - 1)
                                                                effectiveRange:NULL]
                                                   : nil;
    return ps ?: self->_typing[NSParagraphStyleAttributeName] ?: self->_defaultParagraphStyle
                                                            ?: [NSParagraphStyle defaultParagraphStyle];
}

static void
set_paragraph_value(NSTextView *self, NSRange range, void (^change)(NSMutableParagraphStyle *ps))
{
    NSUInteger len = [self->_storage length];
    self->_t.selfEdit = YES;
    [self->_storage beginEditing];
    NSUInteger i = range.location;
    while (i < NSMaxRange(range) && i < len) {
        NSRange r;
        NSParagraphStyle *ps = [self->_storage attribute:NSParagraphStyleAttributeName atIndex:i
                                   longestEffectiveRange:&r inRange:range];
        NSMutableParagraphStyle *m = [(ps ?: [NSParagraphStyle defaultParagraphStyle]) mutableCopy];
        change(m);
        [self->_storage addAttribute:NSParagraphStyleAttributeName value:m range:r];
        [m release];
        i = NSMaxRange(r);
    }
    [self->_storage endEditing];
    self->_t.selfEdit = NO;
    if (NSMaxRange(range) >= len) {
        NSMutableParagraphStyle *m = [paragraph_style_at(self, len) mutableCopy];
        change(m);
        set_typing_value(self, NSParagraphStyleAttributeName, m);
        [m release];
    }
    [self setNeedsDisplay:YES];
}

- (NSTextAlignment)alignment { return [paragraph_style_at(self, 0) alignment]; }
- (void)setAlignment:(NSTextAlignment)alignment
{
    set_paragraph_value(self, NSMakeRange(0, [_storage length]), ^(NSMutableParagraphStyle *ps) {
      [ps setAlignment:alignment];
    });
}
- (void)setAlignment:(NSTextAlignment)alignment range:(NSRange)range
{
    set_paragraph_value(self, paragraph_range([_storage string], range), ^(NSMutableParagraphStyle *ps) {
      [ps setAlignment:alignment];
    });
}
- (void)setBaseWritingDirection:(NSWritingDirection)direction range:(NSRange)range {}

- (void)alignLeft:(id)sender { [self setAlignment:NSTextAlignmentLeft range:_sel]; }
- (void)alignRight:(id)sender { [self setAlignment:NSTextAlignmentRight range:_sel]; }
- (void)alignCenter:(id)sender { [self setAlignment:NSTextAlignmentCenter range:_sel]; }
- (void)alignJustified:(id)sender { [self setAlignment:NSTextAlignmentJustified range:_sel]; }

#pragma mark - The string

- (NSString *)string { return [_storage string]; }

- (void)setString:(NSString *)string
{
    string = string ?: @"";
    NSDictionary *attrs = [_storage length] && _t.rich ? [_storage attributesAtIndex:0 effectiveRange:NULL] : _typing;
    NSAttributedString *a = [[NSAttributedString alloc] initWithString:string attributes:attrs];
    _t.selfEdit = YES;
    [_storage replaceCharactersInRange:NSMakeRange(0, [_storage length]) withAttributedString:a];
    _t.selfEdit = NO;
    [a release];
    [self breakUndoCoalescing];
    _marked = NSMakeRange(NSNotFound, 0);
    _generation++;
    [self _finchResize];
    [self setSelectedRange:NSMakeRange([string length], 0)];
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string
{
    [_storage replaceCharactersInRange:range withString:string ?: @""];
}

- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)string
{
    [_storage replaceCharactersInRange:range withAttributedString:string];
}

- (NSData *)RTFFromRange:(NSRange)range { return nil; }
- (NSData *)RTFDFromRange:(NSRange)range { return nil; }
- (BOOL)readRTFDFromFile:(NSString *)path { return NO; }
- (BOOL)writeRTFDToFile:(NSString *)path atomically:(BOOL)flag { return NO; }
- (void)replaceCharactersInRange:(NSRange)range withRTF:(NSData *)rtfData {}
- (void)replaceCharactersInRange:(NSRange)range withRTFD:(NSData *)rtfdData {}

/* The text storage was edited (from NSLayoutManager): follow it with the selection and the size. */
- (void)_finchTextStorageEdited:(NSTextStorageEditActions)mask range:(NSRange)range changeInLength:(NSInteger)delta
{
    if (!(mask & NSTextStorageEditedCharacters)) {
        [self setNeedsDisplay:YES];
        return;
    }
    _generation++;
    if (_t.selfEdit)
        return;
    NSUInteger oldEnd = NSMaxRange(range) - delta; /* where the edit ended before it */
    NSRange s = _sel;
    if (NSMaxRange(s) <= range.location && !(s.length == 0 && s.location == range.location && range.location < oldEnd))
        ;
    else if (s.location >= oldEnd)
        s.location = (NSUInteger)((NSInteger)s.location + delta);
    else
        s = NSMakeRange(NSMaxRange(range), 0);
    [self breakUndoCoalescing];
    [self _finchResize];
    if (!NSEqualRanges(s, _sel))
        [self setSelectedRange:s];
}

#pragma mark - Sizing

- (NSSize)minSize { return _minSize; }
- (void)setMinSize:(NSSize)size { _minSize = size; }
- (NSSize)maxSize { return _maxSize; }
- (void)setMaxSize:(NSSize)size { _maxSize = size; }
- (BOOL)isHorizontallyResizable { return _t.hResizable; }
- (void)setHorizontallyResizable:(BOOL)flag { _t.hResizable = flag; }
- (BOOL)isVerticallyResizable { return _t.vResizable; }
- (void)setVerticallyResizable:(BOOL)flag { _t.vResizable = flag; }

- (void)setConstrainedFrameSize:(NSSize)size
{
    NSSize s = [self frame].size;
    if (_t.hResizable)
        s.width = MAX(_minSize.width, MIN(_maxSize.width, size.width));
    if (_t.vResizable)
        s.height = MAX(_minSize.height, MIN(_maxSize.height, size.height));
    if (!NSEqualSizes(s, [self frame].size))
        [self setFrameSize:s];
    else
        [self _finchTrackContainer];
}

- (void)sizeToFit
{
    if (!_t.hResizable && !_t.vResizable)
        return;
    [_lm ensureLayoutForTextContainer:_container];
    NSRect used = [_lm usedRectForTextContainer:_container];
    NSRect extra = [_lm extraLineFragmentUsedRect];
    if (!NSIsEmptyRect(extra) && [_lm extraLineFragmentTextContainer] == _container)
        used = NSUnionRect(used, extra);
    NSSize s = NSMakeSize(ceil(NSMaxX(used)) + 2 * _inset.width, ceil(NSMaxY(used)) + 2 * _inset.height);
    [self setConstrainedFrameSize:s];
}

- (void)_finchResize
{
    if (_t.hResizable || _t.vResizable)
        [self sizeToFit];
    [self setNeedsDisplay:YES];
}

/* A container that tracks the view's size follows it. */
- (void)_finchTrackContainer
{
    NSSize c = [_container size], f = [self frame].size;
    if ([_container widthTracksTextView])
        c.width = MAX(0, f.width - 2 * _inset.width);
    if ([_container heightTracksTextView])
        c.height = MAX(0, f.height - 2 * _inset.height);
    if (!NSEqualSizes(c, [_container size]))
        [_container setSize:c];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self _finchTrackContainer];
}

- (void)viewDidMoveToSuperview
{
    [super viewDidMoveToSuperview];
}

#pragma mark - Geometry

/* The line holding the caret at `i` (an index at a wrapped line's end belongs to it when upstream). */
static NSRange
line_at(NSTextView *self, NSUInteger i, BOOL upstream, NSRect *rect)
{
    NSUInteger len = [self->_storage length];
    NSString *s = [self->_storage string];
    if (len == 0 || (i >= len && [[NSCharacterSet newlineCharacterSet] characterIsMember:[s characterAtIndex:len - 1]])) {
        if (rect)
            *rect = [self->_lm extraLineFragmentRect];
        return NSMakeRange(len, 0);
    }
    NSUInteger g = MIN(i, len - 1);
    NSRange r;
    NSRect lf = [self->_lm lineFragmentRectForGlyphAtIndex:g effectiveRange:&r];
    if (i < len && upstream && i > 0 && i == r.location) {
        NSRange prev;
        NSRect plf = [self->_lm lineFragmentRectForGlyphAtIndex:i - 1 effectiveRange:&prev];
        if (NSMaxRange(prev) == i) {
            r = prev;
            lf = plf;
        }
    }
    if (rect)
        *rect = lf;
    return r;
}

/* The caret's x for index i in a line (container coordinates). */
static CGFloat
x_in_line(NSTextView *self, NSUInteger i, NSRange line)
{
    CGFloat pad = [self->_container lineFragmentPadding];
    if (line.length == 0)
        return pad;
    if (i > line.location && i >= NSMaxRange(line)) {
        NSRect r = [self->_lm boundingRectForGlyphRange:NSMakeRange(NSMaxRange(line) - 1, 1) inTextContainer:self->_container];
        unichar c = [[self->_storage string] characterAtIndex:NSMaxRange(line) - 1];
        if ([[NSCharacterSet newlineCharacterSet] characterIsMember:c])
            return NSMinX(r);
        return NSMaxX(r);
    }
    return NSMinX([self->_lm boundingRectForGlyphRange:NSMakeRange(i, 0) inTextContainer:self->_container]);
}

/* The caret rectangle for an index, in view coordinates. */
static NSRect
caret_rect(NSTextView *self, NSUInteger i, BOOL upstream)
{
    NSRect lf;
    NSRange line = line_at(self, i, upstream, &lf);
    CGFloat x = x_in_line(self, i, line);
    NSPoint o = [self textContainerOrigin];
    if (NSIsEmptyRect(lf)) {
        NSFont *f = self->_typing[NSFontAttributeName] ?: [NSFont userFontOfSize:12];
        lf.size.height = [self->_lm defaultLineHeightForFont:f];
    }
    return NSMakeRect(o.x + x, o.y + NSMinY(lf), 1, NSHeight(lf));
}

/* The insertion index nearest x in a line. */
static NSUInteger
index_in_line(NSTextView *self, NSRange line, NSRect lf, CGFloat x, BOOL *upstream)
{
    NSUInteger len = [self->_storage length];
    if (upstream)
        *upstream = NO;
    if (line.length == 0)
        return line.location;
    CGFloat f = 0;
    NSUInteger i = [self->_lm characterIndexForPoint:NSMakePoint(x, NSMidY(lf)) inTextContainer:self->_container
                fractionOfDistanceBetweenInsertionPoints:&f];
    if (f > 0.5)
        i++;
    i = MAX(i, line.location);
    unichar last = [[self->_storage string] characterAtIndex:NSMaxRange(line) - 1];
    BOOL hard = [[NSCharacterSet newlineCharacterSet] characterIsMember:last];
    NSUInteger max = hard ? NSMaxRange(line) - 1 : NSMaxRange(line);
    if (i >= max) {
        i = max;
        if (!hard && i < len && upstream)
            *upstream = YES;
    }
    return i;
}

- (NSUInteger)characterIndexForInsertionAtPoint:(NSPoint)point
{
    NSUInteger len = [_storage length];
    if (!len)
        return 0;
    NSPoint o = [self textContainerOrigin];
    NSPoint p = NSMakePoint(point.x - o.x, point.y - o.y);
    if (p.y < 0)
        return 0;
    NSRect extra = [_lm extraLineFragmentRect];
    if (!NSIsEmptyRect(extra) && p.y >= NSMinY(extra))
        return len;
    NSRange last;
    NSRect lastRect = [_lm lineFragmentRectForGlyphAtIndex:len - 1 effectiveRange:&last];
    if (p.y >= NSMaxY(lastRect))
        return len;
    NSUInteger g = [_lm glyphIndexForPoint:p inTextContainer:_container];
    NSRange line;
    NSRect lf = [_lm lineFragmentRectForGlyphAtIndex:g effectiveRange:&line];
    return index_in_line(self, line, lf, p.x, NULL);
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual
{
    NSUInteger len = [_storage length];
    range.location = MIN(range.location, len);
    range.length = MIN(range.length, len - range.location);
    NSRect r;
    if (!range.length) {
        r = caret_rect(self, range.location, NO);
        r.size.width = 0;
    } else {
        NSRange line = line_at(self, range.location, NO, NULL);
        NSRange first = NSIntersectionRange(range, line);
        if (!first.length)
            first = range;
        r = [_lm boundingRectForGlyphRange:first inTextContainer:_container];
        NSPoint o = [self textContainerOrigin];
        r = NSOffsetRect(r, o.x, o.y);
        range = first;
    }
    if (actual)
        *actual = range;
    r = [self convertRect:r toView:nil];
    return [self window] ? [[self window] convertRectToScreen:r] : r;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
    NSPoint p = point;
    if ([self window])
        p = [[self window] convertPointFromScreen:point];
    return [self characterIndexForInsertionAtPoint:[self convertPoint:p fromView:nil]];
}

#pragma mark - Selection

- (NSRange)selectedRange { return _sel; }
- (NSArray<NSValue *> *)selectedRanges { return @[ [NSValue valueWithRange:_sel] ]; }
- (NSSelectionAffinity)selectionAffinity { return _affinity; }
- (NSSelectionGranularity)selectionGranularity { return _granularity; }
- (void)setSelectionGranularity:(NSSelectionGranularity)granularity { _granularity = granularity; }

static NSRange
clamp_range(NSTextView *self, NSRange r)
{
    NSUInteger len = [self->_storage length];
    NSUInteger loc = MIN(r.location, len);
    return NSMakeRange(loc, MIN(r.length, len - loc));
}

static void
update_typing_from_text(NSTextView *self)
{
    NSUInteger len = [self->_storage length];
    if (!len)
        return;
    NSUInteger i = self->_sel.location > 0 ? self->_sel.location - 1 : 0;
    NSDictionary *a = [self->_storage attributesAtIndex:MIN(i, len - 1) effectiveRange:NULL];
    [self->_typing autorelease];
    self->_typing = [a copy];
}

- (void)setSelectedRange:(NSRange)range affinity:(NSSelectionAffinity)affinity stillSelecting:(BOOL)still
{
    range = clamp_range(self, range);
    if (still) {
        if (!_t.stillSelecting) {
            _selBeforeDrag = _sel;
            _t.stillSelecting = YES;
        }
        _sel = range;
        _affinity = affinity;
        [self setNeedsDisplay:YES];
        return;
    }
    NSRange old = _t.stillSelecting ? _selBeforeDrag : _sel;
    _t.stillSelecting = NO;
    if ([_delegate respondsToSelector:@selector(textView:willChangeSelectionFromCharacterRange:toCharacterRange:)])
        range = clamp_range(self, [_delegate textView:self willChangeSelectionFromCharacterRange:old toCharacterRange:range]);
    BOOL moved = !NSEqualRanges(range, _sel);
    _sel = range;
    _affinity = affinity;
    _generation++;
    if (moved && !_t.selfEdit) {
        update_typing_from_text(self);
        [self breakUndoCoalescing];
    }
    _t.caretOn = YES;
    [self setNeedsDisplay:YES];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSTextViewDidChangeSelectionNotification
                      object:self
                    userInfo:@{@"NSOldSelectedCharacterRange" : [NSValue valueWithRange:old]}];
}

- (void)setSelectedRange:(NSRange)range
{
    _t.hasGoal = NO;
    _movingSide = SIDE_UNKNOWN;
    [self setSelectedRange:range affinity:NSSelectionAffinityDownstream stillSelecting:NO];
}

- (void)setSelectedRanges:(NSArray<NSValue *> *)ranges affinity:(NSSelectionAffinity)affinity stillSelecting:(BOOL)still
{
    if ([ranges count])
        [self setSelectedRange:[ranges[0] rangeValue] affinity:affinity stillSelecting:still];
}

- (void)setSelectedRanges:(NSArray<NSValue *> *)ranges
{
    if ([ranges count])
        [self setSelectedRange:[ranges[0] rangeValue]];
}

/* Move the selection from an action: keeps the goal x when asked, and scrolls to it. */
static void
select_range(NSTextView *self, NSRange r, BOOL upstream, BOOL keepGoal)
{
    BOOL goal = self->_t.hasGoal;
    CGFloat gx = self->_goalX;
    int side = self->_movingSide;
    [self setSelectedRange:r affinity:upstream ? NSSelectionAffinityUpstream : NSSelectionAffinityDownstream
            stillSelecting:NO];
    self->_t.hasGoal = keepGoal && goal;
    self->_goalX = gx;
    self->_movingSide = side;
    [self scrollRangeToVisible:NSMakeRange(r.location + r.length, 0)];
}

static BOOL
is_word_char(unichar c)
{
    static NSCharacterSet *word;
    if (!word) {
        NSMutableCharacterSet *s = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
        [s addCharactersInString:@"_"];
        word = s;
    }
    return [word characterIsMember:c];
}

static NSUInteger
word_end(NSString *s, NSUInteger i)
{
    NSUInteger n = [s length];
    while (i < n && !is_word_char([s characterAtIndex:i]))
        i++;
    while (i < n && (is_word_char([s characterAtIndex:i]) ||
                     ([s characterAtIndex:i] == '\'' && i + 1 < n && is_word_char([s characterAtIndex:i + 1]) && i > 0 &&
                      is_word_char([s characterAtIndex:i - 1]))))
        i++;
    return i;
}

static NSUInteger
word_start(NSString *s, NSUInteger i)
{
    while (i > 0 && !is_word_char([s characterAtIndex:i - 1]))
        i--;
    while (i > 0 && (is_word_char([s characterAtIndex:i - 1]) ||
                     ([s characterAtIndex:i - 1] == '\'' && i > 1 && is_word_char([s characterAtIndex:i - 2]) &&
                      i < [s length] && is_word_char([s characterAtIndex:i]))))
        i--;
    return i;
}

static NSRange
word_range_at(NSString *s, NSUInteger i)
{
    NSUInteger n = [s length];
    if (!n)
        return NSMakeRange(0, 0);
    if (i >= n || (!is_word_char([s characterAtIndex:i]) && i > 0 && is_word_char([s characterAtIndex:i - 1])))
        i = i > 0 ? i - 1 : 0;
    i = MIN(i, n - 1);
    unichar c = [s characterAtIndex:i];
    if (is_word_char(c)) {
        NSUInteger a = word_start(s, i + 1), b = word_end(s, i);
        return NSMakeRange(a, b - a);
    }
    /* a run of the same kind of non-word character (spaces, or one punctuation mark) */
    BOOL space = [[NSCharacterSet whitespaceCharacterSet] characterIsMember:c];
    if (!space)
        return composed_range(s, i);
    NSUInteger a = i, b = i + 1;
    while (a > 0 && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[s characterAtIndex:a - 1]])
        a--;
    while (b < n && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[s characterAtIndex:b]])
        b++;
    return NSMakeRange(a, b - a);
}

- (NSRange)selectionRangeForProposedRange:(NSRange)range granularity:(NSSelectionGranularity)granularity
{
    NSString *s = [_storage string];
    range = clamp_range(self, range);
    switch (granularity) {
    case NSSelectByWord: {
        NSRange a = word_range_at(s, range.location);
        if (!range.length)
            return a;
        NSRange b = word_range_at(s, NSMaxRange(range) - 1);
        return NSUnionRange(a, b);
    }
    case NSSelectByParagraph:
        return paragraph_range(s, range);
    default:
        return range;
    }
}

- (NSRange)rangeForUserTextChange { return _t.editable ? _sel : NSMakeRange(NSNotFound, 0); }
- (NSRange)rangeForUserCharacterAttributeChange { return _t.editable ? _sel : NSMakeRange(NSNotFound, 0); }
- (NSRange)rangeForUserParagraphAttributeChange
{
    return _t.editable ? paragraph_range([_storage string], _sel) : NSMakeRange(NSNotFound, 0);
}

#pragma mark - Editing

static void
post(NSTextView *self, NSString *name, NSDictionary *info)
{
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:self userInfo:info];
}

static BOOL
is_first_responder(NSTextView *self)
{
    return [[self window] firstResponder] == self;
}

- (BOOL)shouldChangeTextInRange:(NSRange)range replacementString:(NSString *)string
{
    if (!_t.editable)
        return NO;
    if (!_t.editing) {
        if ([_delegate respondsToSelector:@selector(textShouldBeginEditing:)] && ![_delegate textShouldBeginEditing:self])
            return NO;
        _t.editing = YES;
        post(self, NSTextDidBeginEditingNotification, nil);
    }
    if ([_delegate respondsToSelector:@selector(textView:shouldChangeTextInRange:replacementString:)])
        return [_delegate textView:self shouldChangeTextInRange:range replacementString:string];
    return YES;
}

- (BOOL)shouldChangeTextInRanges:(NSArray<NSValue *> *)ranges replacementStrings:(NSArray<NSString *> *)strings
{
    if (![ranges count])
        return [self shouldChangeTextInRange:_sel replacementString:nil];
    return [self shouldChangeTextInRange:[ranges[0] rangeValue] replacementString:[strings count] ? strings[0] : nil];
}

- (NSArray<NSValue *> *)rangesForUserTextChange { return _t.editable ? [self selectedRanges] : nil; }
- (NSArray<NSValue *> *)rangesForUserCharacterAttributeChange { return [self rangesForUserTextChange]; }
- (NSArray<NSValue *> *)rangesForUserParagraphAttributeChange { return [self rangesForUserTextChange]; }

/* End editing: the delegate may refuse; then the end is posted with a movement. */
static BOOL
end_editing(NSTextView *self, NSInteger movement, BOOL always)
{
    if (self->_t.editing) {
        if ([self->_delegate respondsToSelector:@selector(textShouldEndEditing:)] &&
            ![self->_delegate textShouldEndEditing:self])
            return NO;
        self->_t.editing = NO;
    } else if (!always) {
        return YES;
    }
    [self breakUndoCoalescing];
    post(self, NSTextDidEndEditingNotification, @{NSTextMovementUserInfoKey : @(movement)});
    return YES;
}

- (void)didChangeText
{
    post(self, NSTextDidChangeNotification, nil);
    if (!is_first_responder(self))
        end_editing(self, NSTextMovementOther, NO);
}

- (NSUndoManager *)undoManager
{
    if ([_delegate respondsToSelector:@selector(undoManagerForTextView:)])
        return [_delegate undoManagerForTextView:self];
    return [super undoManager];
}

static void
register_undo(NSTextView *self, NSRange range, NSUInteger newLength, NSString *name, BOOL redo)
{
    NSUndoManager *um = self->_t.allowsUndo ? [self undoManager] : nil;
    if (!um || ![um isUndoRegistrationEnabled])
        return;
    FinchTextUndo *u = [[FinchTextUndo alloc] init];
    u->_range = NSMakeRange(range.location, newLength);
    u->_old = [[self->_storage attributedSubstringFromRange:range] retain];
    u->_redo = redo;
    [um registerUndoWithTarget:self selector:@selector(_finchUndo:) object:u];
    if (name && ![um isUndoing] && ![um isRedoing])
        [um setActionName:name];
    if ([name isEqualToString:@"Typing"] && ![um isUndoing] && ![um isRedoing]) {
        [self->_typingUndo release];
        self->_typingUndo = [u retain];
    }
    [u release];
}

/*
 * Replace a range with text (the typing attributes unless attributed), as
 * the user did it: undo, then the change, then the new selection. The
 * caller asked -shouldChangeTextInRange: and calls -didChangeText.
 */
static void
replace(NSTextView *self, NSRange range, id text, NSString *undoName, NSRange newSel)
{
    NSAttributedString *a = [text isKindOfClass:[NSAttributedString class]]
                                ? text
                                : [[[NSAttributedString alloc] initWithString:text ?: @"" attributes:self->_typing]
                                      autorelease];
    NSUInteger n = [a length];
    /* typing just after the previous typing extends its undo */
    FinchTextUndo *t = self->_typingUndo;
    BOOL coalesce = t && [undoName isEqualToString:@"Typing"] && range.length == 0 && n &&
                    range.location == NSMaxRange(t->_range) && self->_t.editing;
    if (coalesce)
        t->_range.length += n;
    else {
        [self breakUndoCoalescing];
        if (undoName)
            register_undo(self, range, n, undoName, NO);
    }
    self->_t.selfEdit = YES;
    [self->_storage replaceCharactersInRange:range withAttributedString:a];
    self->_t.selfEdit = NO;
    self->_marked = NSMakeRange(NSNotFound, 0);
    [self _finchResize];
    NSDictionary *typing = [[self->_typing retain] autorelease];
    self->_t.selfEdit = YES;
    select_range(self, newSel, NO, NO);
    self->_t.selfEdit = NO;
    /* the typing attributes stay what they were for the text just typed */
    if (![self->_typing isEqual:typing]) {
        [self->_typing release];
        self->_typing = [typing copy];
    }
}

- (void)_finchUndo:(FinchTextUndo *)u
{
    NSRange r = clamp_range(self, u->_range);
    NSAttributedString *now = [_storage attributedSubstringFromRange:r];
    if (![self shouldChangeTextInRange:r replacementString:[u->_old string]])
        return;
    [self breakUndoCoalescing];
    register_undo(self, r, [u->_old length], nil, !u->_redo);
    (void)now;
    _t.selfEdit = YES;
    [_storage replaceCharactersInRange:r withAttributedString:u->_old];
    _t.selfEdit = NO;
    [self _finchResize];
    NSRange sel = u->_redo ? NSMakeRange(r.location + [u->_old length], 0) : NSMakeRange(r.location, [u->_old length]);
    _t.selfEdit = YES;
    select_range(self, sel, NO, NO);
    _t.selfEdit = NO;
    [self didChangeText];
}

/* Insert text over a range as typing (or a paste), with the delegate's say. */
static BOOL
insert(NSTextView *self, id text, NSRange range, NSString *undoName)
{
    NSString *plain = [text isKindOfClass:[NSAttributedString class]] ? [text string] : text;
    if (![self shouldChangeTextInRange:range replacementString:plain])
        return NO;
    NSUInteger n = [plain length];
    replace(self, range, self->_t.rich && [text isKindOfClass:[NSAttributedString class]] && ![undoName isEqual:@"Typing"]
                             ? text
                             : plain,
            undoName, NSMakeRange(range.location + n, 0));
    [self didChangeText];
    return YES;
}

/* Delete a range, as the user did it. */
static BOOL
delete_range(NSTextView *self, NSRange range, NSString *undoName)
{
    range = clamp_range(self, range);
    if (!range.length || !self->_t.editable)
        return NO;
    if (![self shouldChangeTextInRange:range replacementString:@""])
        return NO;
    replace(self, range, @"", undoName, NSMakeRange(range.location, 0));
    [self didChangeText];
    return YES;
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    if (!_t.editable) {
        NSBeep();
        return;
    }
    NSRange r = replacementRange.location != NSNotFound ? clamp_range(self, replacementRange)
                : _marked.location != NSNotFound           ? _marked
                                                           : _sel;
    if (replacementRange.location != NSNotFound && !NSEqualRanges(r, _sel)) {
        /* elsewhere than the selection: the selection stays, moved by the change */
        NSString *plain = [string isKindOfClass:[NSAttributedString class]] ? [string string] : string;
        if (![self shouldChangeTextInRange:r replacementString:plain])
            return;
        NSInteger delta = (NSInteger)[plain length] - (NSInteger)r.length;
        NSRange s = _sel;
        if (s.location >= NSMaxRange(r))
            s.location = (NSUInteger)((NSInteger)s.location + delta);
        else if (NSMaxRange(s) > r.location)
            s = NSMakeRange(r.location + [plain length], 0);
        replace(self, r, plain, @"Typing", s);
        [self didChangeText];
        return;
    }
    insert(self, string, r, @"Typing");
}

- (void)insertText:(id)string
{
    [self insertText:string replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)doCommandBySelector:(SEL)selector
{
    if ([_delegate respondsToSelector:@selector(textView:doCommandBySelector:)] &&
        [_delegate textView:self doCommandBySelector:selector])
        return;
    if ([self respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, nil);
        return;
    }
    [super doCommandBySelector:selector];
}

#pragma mark - Newlines and tabs (and the field editor's movements)

static void
type_text(NSTextView *self, NSString *s)
{
    [self insertText:s replacementRange:NSMakeRange(NSNotFound, 0)];
}

/* The field editor ends editing; the delegate (a control) takes it from there. */
static void
field_editor_end(NSTextView *self, NSInteger movement)
{
    if (self->_t.editing && [self->_delegate respondsToSelector:@selector(textShouldEndEditing:)] &&
        ![self->_delegate textShouldEndEditing:self])
        return;
    self->_t.editing = NO;
    NSWindow *w = [self window];
    if ([w firstResponder] == self)
        [w makeFirstResponder:w];
    end_editing(self, movement, YES);
}

- (void)insertNewline:(id)sender
{
    if (_t.fieldEditor)
        field_editor_end(self, NSTextMovementReturn);
    else
        type_text(self, @"\n");
}

- (void)insertTab:(id)sender
{
    if (_t.fieldEditor)
        field_editor_end(self, NSTextMovementTab);
    else
        type_text(self, @"\t");
}

- (void)insertBacktab:(id)sender
{
    if (_t.fieldEditor)
        field_editor_end(self, NSTextMovementBacktab);
}

- (void)insertNewlineIgnoringFieldEditor:(id)sender { type_text(self, @"\n"); }
- (void)insertTabIgnoringFieldEditor:(id)sender { type_text(self, @"\t"); }
- (void)insertLineBreak:(id)sender { type_text(self, @" "); }
- (void)insertParagraphSeparator:(id)sender { type_text(self, @" "); }
- (void)insertContainerBreak:(id)sender { type_text(self, @"\f"); }
- (void)insertSingleQuoteIgnoringSubstitution:(id)sender { type_text(self, @"'"); }
- (void)insertDoubleQuoteIgnoringSubstitution:(id)sender { type_text(self, @"\""); }

#pragma mark - Deleting

/* Deleting to a boundary kills: the text joins the kill buffer when kills follow each other. */
static void
kill_text(NSTextView *self, NSRange range, BOOL backward)
{
    range = clamp_range(self, range);
    if (!range.length || !self->_t.editable)
        return;
    NSString *s = [[self->_storage string] substringWithRange:range];
    BOOL append = kill_view == self && kill_generation == self->_generation;
    if (!delete_range(self, range, @"Typing"))
        return;
    if (!kill_buffer)
        kill_buffer = [[NSMutableString alloc] init];
    if (!append)
        [kill_buffer setString:s];
    else if (backward)
        [kill_buffer insertString:s atIndex:0];
    else
        [kill_buffer appendString:s];
    kill_view = self;
    kill_generation = self->_generation;
}

static NSRange
composed(NSTextView *self, NSUInteger i)
{
    return composed_range([self->_storage string], i);
}

- (void)deleteBackward:(id)sender
{
    if (_sel.length)
        delete_range(self, _sel, @"Typing");
    else if (_sel.location > 0)
        delete_range(self, composed(self, _sel.location - 1), @"Typing");
}

- (void)deleteForward:(id)sender
{
    if (_sel.length)
        delete_range(self, _sel, @"Typing");
    else if (_sel.location < [_storage length])
        delete_range(self, composed(self, _sel.location), @"Typing");
}

- (void)deleteBackwardByDecomposingPreviousCharacter:(id)sender
{
    if (_sel.length)
        delete_range(self, _sel, @"Typing");
    else if (_sel.location > 0)
        delete_range(self, NSMakeRange(_sel.location - 1, 1), @"Typing");
}

- (void)deleteWordBackward:(id)sender
{
    if (_sel.length) {
        delete_range(self, _sel, @"Typing");
        return;
    }
    NSUInteger a = word_start([_storage string], _sel.location);
    delete_range(self, NSMakeRange(a, _sel.location - a), @"Typing");
}

- (void)deleteWordForward:(id)sender
{
    if (_sel.length) {
        delete_range(self, _sel, @"Typing");
        return;
    }
    NSUInteger b = word_end([_storage string], _sel.location);
    delete_range(self, NSMakeRange(_sel.location, b - _sel.location), @"Typing");
}

static NSUInteger
line_start(NSTextView *self, NSUInteger i, BOOL upstream)
{
    return line_at(self, i, upstream, NULL).location;
}

/* The end of the line holding i: before its newline, or at its end (upstream) when it wraps. */
static NSUInteger
line_end(NSTextView *self, NSUInteger i, BOOL upstream, BOOL *isUpstream)
{
    NSRange line = line_at(self, i, upstream, NULL);
    if (isUpstream)
        *isUpstream = NO;
    if (!line.length)
        return line.location;
    unichar c = [[self->_storage string] characterAtIndex:NSMaxRange(line) - 1];
    if ([[NSCharacterSet newlineCharacterSet] characterIsMember:c])
        return NSMaxRange(line) - 1;
    if (isUpstream && NSMaxRange(line) < [self->_storage length])
        *isUpstream = YES;
    return NSMaxRange(line);
}

static NSUInteger
paragraph_start(NSTextView *self, NSUInteger i)
{
    return paragraph_range([self->_storage string], NSMakeRange(i, 0)).location;
}

/* The end of i's paragraph, before its terminator. */
static NSUInteger
paragraph_end(NSTextView *self, NSUInteger i)
{
    return paragraph_contents_end([self->_storage string], i);
}

- (void)deleteToBeginningOfLine:(id)sender
{
    if (_sel.length) {
        kill_text(self, _sel, YES);
        return;
    }
    NSUInteger a = line_start(self, _sel.location, _affinity == NSSelectionAffinityUpstream);
    if (a == _sel.location && a > 0)
        a--;
    kill_text(self, NSMakeRange(a, _sel.location - a), YES);
}

- (void)deleteToEndOfLine:(id)sender
{
    if (_sel.length) {
        kill_text(self, _sel, NO);
        return;
    }
    NSUInteger b = line_end(self, _sel.location, _affinity == NSSelectionAffinityUpstream, NULL);
    if (b == _sel.location && b < [_storage length])
        b++;
    kill_text(self, NSMakeRange(_sel.location, b - _sel.location), NO);
}

- (void)deleteToBeginningOfParagraph:(id)sender
{
    if (_sel.length) {
        kill_text(self, _sel, YES);
        return;
    }
    NSUInteger a = paragraph_start(self, _sel.location);
    if (a == _sel.location && a > 0)
        a--;
    kill_text(self, NSMakeRange(a, _sel.location - a), YES);
}

- (void)deleteToEndOfParagraph:(id)sender
{
    if (_sel.length) {
        kill_text(self, _sel, NO);
        return;
    }
    NSUInteger b = paragraph_end(self, _sel.location);
    if (b == _sel.location && b < [_storage length])
        b = NSMaxRange(composed(self, b));
    kill_text(self, NSMakeRange(_sel.location, b - _sel.location), NO);
}

- (void)yank:(id)sender
{
    if (!_t.editable || ![kill_buffer length])
        return;
    insert(self, [[kill_buffer copy] autorelease], _sel, @"Typing");
}

- (void)delete:(id)sender
{
    if (_sel.length)
        delete_range(self, _sel, @"Delete");
}

- (void)setMark:(id)sender { _mark = _sel.location; }
- (void)deleteToMark:(id)sender
{
    if (_mark == NSNotFound)
        return;
    NSUInteger a = MIN(_mark, _sel.location), b = MAX(_mark, _sel.location);
    kill_text(self, NSMakeRange(a, b - a), _mark < _sel.location);
}
- (void)selectToMark:(id)sender
{
    if (_mark == NSNotFound)
        return;
    NSUInteger a = MIN(_mark, _sel.location), b = MAX(_mark, NSMaxRange(_sel));
    select_range(self, NSMakeRange(a, b - a), NO, NO);
}
- (void)swapWithMark:(id)sender
{
    if (_mark == NSNotFound)
        return;
    NSUInteger m = MIN(_mark, [_storage length]);
    _mark = _sel.location;
    select_range(self, NSMakeRange(m, 0), NO, NO);
}

#pragma mark - Transposing and changing case

- (void)transpose:(id)sender
{
    NSUInteger len = [_storage length];
    if (_sel.length || _sel.location == 0 || len < 2 || !_t.editable)
        return;
    NSUInteger i = _sel.location == len ? len - 1 : _sel.location;
    NSRange r = NSMakeRange(i - 1, 2);
    NSString *s = [[_storage string] substringWithRange:r];
    NSString *swapped = [NSString stringWithFormat:@"%C%C", [s characterAtIndex:1], [s characterAtIndex:0]];
    if (![self shouldChangeTextInRange:r replacementString:swapped])
        return;
    NSMutableAttributedString *a = [[[_storage attributedSubstringFromRange:r] mutableCopy] autorelease];
    [a replaceCharactersInRange:NSMakeRange(0, 2) withString:swapped];
    replace(self, r, a, @"Typing", NSMakeRange(i + 1, 0));
    [self didChangeText];
}

- (void)transposeWords:(id)sender {}

static void
change_case(NSTextView *self, NSString * (^change)(NSString *))
{
    NSRange r = self->_sel.length ? self->_sel : word_range_at([self->_storage string], self->_sel.location);
    if (!r.length || !self->_t.editable)
        return;
    NSString *now = [[self->_storage string] substringWithRange:r];
    NSString *s = change(now);
    if (![self shouldChangeTextInRange:r replacementString:s])
        return;
    NSMutableAttributedString *a = [[[self->_storage attributedSubstringFromRange:r] mutableCopy] autorelease];
    [a replaceCharactersInRange:NSMakeRange(0, [a length]) withString:s];
    replace(self, r, a, @"Typing", NSMakeRange(r.location, [s length]));
    [self didChangeText];
}

- (void)uppercaseWord:(id)sender
{
    change_case(self, ^NSString *(NSString *s) { return [s uppercaseString]; });
}
- (void)lowercaseWord:(id)sender
{
    change_case(self, ^NSString *(NSString *s) { return [s lowercaseString]; });
}
- (void)capitalizeWord:(id)sender
{
    change_case(self, ^NSString *(NSString *s) { return [s capitalizedString]; });
}

#pragma mark - Selecting

- (void)selectAll:(id)sender
{
    if (_t.selectable)
        select_range(self, NSMakeRange(0, [_storage length]), NO, NO);
}

- (void)selectWord:(id)sender
{
    select_range(self, [self selectionRangeForProposedRange:_sel granularity:NSSelectByWord], NO, NO);
}

- (void)selectParagraph:(id)sender
{
    select_range(self, [self selectionRangeForProposedRange:_sel granularity:NSSelectByParagraph], NO, NO);
}

- (void)selectLine:(id)sender
{
    NSRange a = line_at(self, _sel.location, NO, NULL);
    NSRange b = _sel.length ? line_at(self, NSMaxRange(_sel) - 1, NO, NULL) : a;
    select_range(self, NSUnionRange(a, b), NO, NO);
}

#pragma mark - Moving

/* Where a vertical move from i lands (dir -1 up, +1 down), keeping the goal x. */
static NSUInteger
vertical(NSTextView *self, NSUInteger i, BOOL upstream, int dir, BOOL *landedUpstream)
{
    NSUInteger len = [self->_storage length];
    *landedUpstream = NO;
    NSRect lf;
    NSRange line = line_at(self, i, upstream, &lf);
    if (!self->_t.hasGoal) {
        self->_goalX = x_in_line(self, i, line);
        self->_t.hasGoal = YES;
    }
    NSRect target;
    NSRange tl;
    if (dir < 0) {
        if (line.location == 0)
            return 0;
        tl = line_at(self, line.location - 1, NO, &target);
        if (NSMaxRange(tl) > line.location) /* a hard break: the line before ends at the newline */
            tl = line_at(self, line.location - 1, NO, &target);
    } else {
        NSUInteger next = NSMaxRange(line);
        if (line.length == 0 || next >= len) {
            if (next >= len && line.length && [[NSCharacterSet newlineCharacterSet] characterIsMember:[[self->_storage string] characterAtIndex:len - 1]])
                return len; /* onto the extra line */
            return len;
        }
        tl = line_at(self, next, NO, &target);
    }
    return index_in_line(self, tl, target, self->_goalX, landedUpstream);
}

/* The page's height for page moves: the visible part of the view. */
static CGFloat
page_height(NSTextView *self)
{
    NSRect v = [self visibleRect];
    CGFloat h = NSHeight(v);
    if (h <= 0 || h > 1e6)
        h = NSHeight([self bounds]);
    return MAX(h, 1);
}

static NSUInteger
page(NSTextView *self, NSUInteger i, BOOL upstream, int dir, BOOL *landedUpstream)
{
    NSRect c = caret_rect(self, i, upstream);
    if (!self->_t.hasGoal) {
        self->_goalX = NSMinX(c) - [self textContainerOrigin].x;
        self->_t.hasGoal = YES;
    }
    *landedUpstream = NO;
    CGFloat y = NSMidY(c) + dir * page_height(self);
    NSPoint o = [self textContainerOrigin];
    NSUInteger r = [self characterIndexForInsertionAtPoint:NSMakePoint(self->_goalX + o.x, y)];
    if (y < 0)
        return 0;
    return r;
}

typedef NS_ENUM(int, MoveKind) {
    M_LEFT, M_RIGHT, M_UP, M_DOWN, M_WORD_LEFT, M_WORD_RIGHT, M_LINE_START, M_LINE_END, M_PARA_START, M_PARA_END,
    M_DOC_START, M_DOC_END, M_PARA_BACK, M_PARA_FORWARD, M_PAGE_UP, M_PAGE_DOWN,
};

/* One step of a move from index i (relative kinds) or the boundary (the others). */
static NSUInteger
step(NSTextView *self, MoveKind kind, NSUInteger i, BOOL upstream, BOOL *landedUpstream)
{
    NSString *s = [self->_storage string];
    NSUInteger len = [s length];
    *landedUpstream = NO;
    switch (kind) {
    case M_LEFT:
        return i > 0 ? composed(self, i - 1).location : 0;
    case M_RIGHT:
        return i < len ? NSMaxRange(composed(self, i)) : len;
    case M_UP:
        return vertical(self, i, upstream, -1, landedUpstream);
    case M_DOWN:
        return vertical(self, i, upstream, 1, landedUpstream);
    case M_PAGE_UP:
        return page(self, i, upstream, -1, landedUpstream);
    case M_PAGE_DOWN:
        return page(self, i, upstream, 1, landedUpstream);
    case M_WORD_LEFT:
        return word_start(s, i);
    case M_WORD_RIGHT:
        return word_end(s, i);
    case M_LINE_START:
        return line_start(self, i, upstream);
    case M_LINE_END:
        return line_end(self, i, upstream, landedUpstream);
    case M_PARA_START:
        return paragraph_start(self, i);
    case M_PARA_END:
        return paragraph_end(self, i);
    case M_PARA_BACK: {
        NSUInteger a = paragraph_start(self, i);
        if (a == i && i > 0)
            a = paragraph_start(self, i - 1);
        return a;
    }
    case M_PARA_FORWARD:
        return i >= len ? len : NSMaxRange(paragraph_range(s, NSMakeRange(i, 0)));
    case M_DOC_START:
        return 0;
    case M_DOC_END:
        return len;
    }
    return i;
}

static BOOL
is_vertical(MoveKind k)
{
    return k == M_UP || k == M_DOWN || k == M_PAGE_UP || k == M_PAGE_DOWN;
}

static BOOL
is_backward(MoveKind k)
{
    return k == M_LEFT || k == M_UP || k == M_WORD_LEFT || k == M_LINE_START || k == M_PARA_START || k == M_DOC_START ||
           k == M_PARA_BACK || k == M_PAGE_UP;
}

static BOOL
is_boundary(MoveKind k)
{
    return k == M_LINE_START || k == M_LINE_END || k == M_PARA_START || k == M_PARA_END || k == M_DOC_START ||
           k == M_DOC_END;
}

/* A plain move: the caret goes, the selection collapses. */
static void
move_caret(NSTextView *self, MoveKind kind)
{
    if (!self->_t.selectable)
        return;
    NSRange sel = self->_sel;
    BOOL upstream = self->_affinity == NSSelectionAffinityUpstream, landed = NO;
    NSUInteger to;
    BOOL keepGoal = is_vertical(kind);
    if (!keepGoal)
        self->_t.hasGoal = NO;
    if (sel.length && (kind == M_LEFT || kind == M_RIGHT)) {
        to = kind == M_LEFT ? sel.location : NSMaxRange(sel);
    } else if (sel.length && is_vertical(kind)) {
        /* from the start's x, on the start's line (up) or the line the selection ends on (down) */
        BOOL back = is_backward(kind);
        NSRange line = line_at(self, sel.location, NO, NULL);
        self->_goalX = x_in_line(self, sel.location, line);
        self->_t.hasGoal = YES;
        to = step(self, kind, back ? sel.location : NSMaxRange(sel), !back, &landed);
        keepGoal = NO;
    } else if (sel.length) {
        BOOL back = is_backward(kind);
        NSUInteger from = back ? sel.location : NSMaxRange(sel);
        /* the end of a selection belongs to the line its last character is on */
        to = step(self, kind, from, !back, &landed);
    } else {
        to = step(self, kind, sel.location, upstream, &landed);
    }
    self->_movingSide = SIDE_UNKNOWN;
    select_range(self, NSMakeRange(to, 0), landed, keepGoal);
}

/* Extending the selection: see the comment at the top. */
static void
extend_selection(NSTextView *self, MoveKind kind)
{
    if (!self->_t.selectable)
        return;
    NSRange sel = self->_sel;
    BOOL keepGoal = is_vertical(kind), landed = NO;
    if (!keepGoal)
        self->_t.hasGoal = NO;
    BOOL back = is_backward(kind);
    if (is_boundary(kind)) {
        NSRange r;
        int side = self->_movingSide;
        if (back) {
            NSUInteger a = step(self, kind, sel.location, NO, &landed);
            a = MIN(a, sel.location);
            r = NSMakeRange(a, NSMaxRange(sel) - a);
            if (!sel.length)
                side = SIDE_START;
        } else {
            NSUInteger b = step(self, kind, NSMaxRange(sel), sel.length > 0, &landed);
            b = MAX(b, NSMaxRange(sel));
            r = NSMakeRange(sel.location, b - sel.location);
            if (!sel.length)
                side = SIDE_END;
        }
        self->_movingSide = side;
        select_range(self, r, landed, NO);
        self->_movingSide = side;
        return;
    }
    NSUInteger anchor, moving;
    if (!sel.length) {
        anchor = moving = sel.location;
    } else if (self->_movingSide == SIDE_END || (self->_movingSide == SIDE_UNKNOWN && !back)) {
        anchor = sel.location;
        moving = NSMaxRange(sel);
    } else {
        anchor = NSMaxRange(sel);
        moving = sel.location;
    }
    BOOL upstream = sel.length ? (moving == NSMaxRange(sel)) : self->_affinity == NSSelectionAffinityUpstream;
    NSUInteger to = step(self, kind, moving, upstream, &landed);
    BOOL stops = kind == M_WORD_LEFT || kind == M_WORD_RIGHT || kind == M_PARA_BACK || kind == M_PARA_FORWARD;
    if (stops && ((moving < anchor && to > anchor) || (moving > anchor && to < anchor)))
        to = anchor;
    int side = to < anchor ? SIDE_START : to > anchor ? SIDE_END : SIDE_UNKNOWN;
    NSRange r = to < anchor ? NSMakeRange(to, anchor - to) : NSMakeRange(anchor, to - anchor);
    self->_movingSide = side;
    select_range(self, r, landed, keepGoal);
    self->_movingSide = side;
}

#define MOVES(name, kind)                                         \
    -(void)name:(id)sender { move_caret(self, kind); }                 \
    -(void)name##AndModifySelection:(id)sender { extend_selection(self, kind); }

MOVES(moveLeft, M_LEFT)
MOVES(moveRight, M_RIGHT)
MOVES(moveBackward, M_LEFT)
MOVES(moveForward, M_RIGHT)
MOVES(moveUp, M_UP)
MOVES(moveDown, M_DOWN)
MOVES(moveWordLeft, M_WORD_LEFT)
MOVES(moveWordRight, M_WORD_RIGHT)
MOVES(moveWordBackward, M_WORD_LEFT)
MOVES(moveWordForward, M_WORD_RIGHT)
MOVES(moveToBeginningOfLine, M_LINE_START)
MOVES(moveToEndOfLine, M_LINE_END)
MOVES(moveToLeftEndOfLine, M_LINE_START)
MOVES(moveToRightEndOfLine, M_LINE_END)
MOVES(moveToBeginningOfParagraph, M_PARA_START)
MOVES(moveToEndOfParagraph, M_PARA_END)
MOVES(moveToBeginningOfDocument, M_DOC_START)
MOVES(moveToEndOfDocument, M_DOC_END)
MOVES(moveParagraphBackward, M_PARA_BACK)
MOVES(moveParagraphForward, M_PARA_FORWARD)
MOVES(pageUp, M_PAGE_UP)
MOVES(pageDown, M_PAGE_DOWN)
#undef MOVES

#pragma mark - Scrolling

- (void)scrollRangeToVisible:(NSRange)range
{
    range = clamp_range(self, range);
    NSRect r;
    if (!range.length) {
        r = caret_rect(self, range.location, _affinity == NSSelectionAffinityUpstream);
    } else {
        r = [_lm boundingRectForGlyphRange:range inTextContainer:_container];
        NSPoint o = [self textContainerOrigin];
        r = NSOffsetRect(r, o.x, o.y);
    }
    r.size.width = MAX(r.size.width, 1);
    [self scrollRectToVisible:r];
}

static NSScrollView *
scroll_view(NSTextView *self)
{
    return [self enclosingScrollView];
}

- (void)scrollPageUp:(id)sender { [scroll_view(self) scrollPageUp:sender]; }
- (void)scrollPageDown:(id)sender { [scroll_view(self) scrollPageDown:sender]; }
- (void)scrollLineUp:(id)sender { [scroll_view(self) scrollLineUp:sender]; }
- (void)scrollLineDown:(id)sender { [scroll_view(self) scrollLineDown:sender]; }
- (void)scrollToBeginningOfDocument:(id)sender { [self scrollRectToVisible:NSMakeRect(0, 0, 1, 1)]; }
- (void)scrollToEndOfDocument:(id)sender
{
    NSRect b = [self bounds];
    [self scrollRectToVisible:NSMakeRect(0, NSMaxY(b) - 1, 1, 1)];
}

- (void)centerSelectionInVisibleArea:(id)sender
{
    NSClipView *clip = (NSClipView *)[self superview];
    if (![clip isKindOfClass:[NSClipView class]])
        return;
    NSRect c = caret_rect(self, _sel.location, _affinity == NSSelectionAffinityUpstream);
    NSRect v = [clip bounds];
    NSPoint p = [clip convertPoint:NSMakePoint(NSMidX(c), NSMidY(c)) fromView:self];
    NSPoint o = NSMakePoint(v.origin.x, p.y - NSHeight(v) / 2);
    [clip scrollToPoint:[clip constrainScrollPoint:o]];
}

#pragma mark - Drawing

- (void)drawViewBackgroundInRect:(NSRect)rect
{
    if (!_t.drawsBackground)
        return;
    [[self backgroundColor] setFill];
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
}

- (void)drawInsertionPointInRect:(NSRect)rect color:(NSColor *)color turnedOn:(BOOL)flag
{
    if (!flag)
        return;
    [color setFill];
    NSRectFill(rect);
}

- (BOOL)shouldDrawInsertionPoint
{
    return _t.selectable && _t.editable;
}

static BOOL
is_active(NSTextView *self)
{
    NSWindow *w = [self window];
    return w && [w firstResponder] == self && [w isKeyWindow];
}

- (void)drawRect:(NSRect)rect
{
    [self drawViewBackgroundInRect:rect];
    NSPoint o = [self textContainerOrigin];
    NSRect inContainer = NSOffsetRect(rect, -o.x, -o.y);
    if (_sel.length && _t.selectable) {
        NSUInteger n = 0;
        NSRectArray rects = [_lm rectArrayForCharacterRange:_sel withinSelectedCharacterRange:_sel
                                            inTextContainer:_container rectCount:&n];
        NSColor *c = is_active(self) ? ([self selectedTextAttributes][NSBackgroundColorAttributeName]
                                            ?: [NSColor selectedTextBackgroundColor])
                                     : [NSColor unemphasizedSelectedTextBackgroundColor];
        [c setFill];
        for (NSUInteger i = 0; i < n; i++)
            NSRectFillUsingOperation(NSOffsetRect(rects[i], o.x, o.y), NSCompositingOperationSourceOver);
    }
    NSRange glyphs = [_lm glyphRangeForBoundingRect:inContainer inTextContainer:_container];
    if (glyphs.length) {
        [_lm drawBackgroundForGlyphRange:glyphs atPoint:o];
        [_lm drawGlyphsForGlyphRange:glyphs atPoint:o];
    }
    if (!_sel.length && [self shouldDrawInsertionPoint] && is_active(self) && _t.caretOn) {
        NSRect c = caret_rect(self, _sel.location, _affinity == NSSelectionAffinityUpstream);
        if (NSIntersectsRect(c, rect))
            [self drawInsertionPointInRect:c color:[self insertionPointColor] turnedOn:YES];
    }
}

#pragma mark - The insertion point's blinking

- (void)_finchBlink:(NSTimer *)timer
{
    _t.caretOn = !_t.caretOn;
    if (!_sel.length)
        [self setNeedsDisplayInRect:NSInsetRect(caret_rect(self, _sel.location, _affinity == NSSelectionAffinityUpstream),
                                                -1, 0)];
}

static void
stop_blinking(NSTextView *self)
{
    [self->_blink invalidate];
    [self->_blink release];
    self->_blink = nil;
}

static void
start_blinking(NSTextView *self)
{
    stop_blinking(self);
    self->_t.caretOn = YES;
    if (![self window])
        return;
    self->_blink = [[NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(_finchBlink:) userInfo:nil
                                           repeats:YES] retain];
    [[NSRunLoop currentRunLoop] addTimer:self->_blink forMode:NSRunLoopCommonModes];
}

- (void)updateInsertionPointStateAndRestartTimer:(BOOL)restart
{
    _t.caretOn = YES;
    if (restart && is_first_responder(self))
        start_blinking(self);
    [self setNeedsDisplay:YES];
}

- (void)viewWillMoveToWindow:(NSWindow *)window
{
    if (!window)
        stop_blinking(self);
    [super viewWillMoveToWindow:window];
}

#pragma mark - First responder

- (BOOL)acceptsFirstResponder { return _t.selectable; }
- (BOOL)needsPanelToBecomeKey { return _t.editable; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (BOOL)becomeFirstResponder
{
    if (!_t.selectable)
        return NO;
    if (_t.editable)
        start_blinking(self);
    [self setNeedsDisplay:YES];
    return YES;
}

- (BOOL)resignFirstResponder
{
    if (!end_editing(self, NSTextMovementOther, NO))
        return NO;
    stop_blinking(self);
    [self setNeedsDisplay:YES];
    return YES;
}

#pragma mark - Mouse and keys

- (void)mouseDown:(NSEvent *)event
{
    if (!_t.selectable) {
        [super mouseDown:event];
        return;
    }
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSUInteger i = [self characterIndexForInsertionAtPoint:p];
    NSInteger clicks = [event clickCount];
    _granularity = clicks >= 3 ? NSSelectByParagraph : clicks == 2 ? NSSelectByWord : NSSelectByCharacter;
    NSRange unit = [self selectionRangeForProposedRange:NSMakeRange(i, 0) granularity:_granularity];
    if (([event modifierFlags] & NSEventModifierFlagShift) && clicks == 1) {
        /* extend from the far end of the selection */
        NSUInteger a = i < _sel.location ? NSMaxRange(_sel) : _sel.location;
        unit = NSMakeRange(a, 0);
    }
    _dragUnit = unit;
    _t.dragging = YES;
    _t.hasGoal = NO;
    _movingSide = SIDE_UNKNOWN;
    NSRange r = NSUnionRange(unit, [self selectionRangeForProposedRange:NSMakeRange(i, 0) granularity:_granularity]);
    if (_granularity == NSSelectByCharacter)
        r = i < unit.location ? NSMakeRange(i, unit.location - i) : NSMakeRange(unit.location, i - unit.location);
    [self setSelectedRange:r affinity:NSSelectionAffinityDownstream stillSelecting:YES];
    _t.caretOn = YES;
}

- (void)mouseDragged:(NSEvent *)event
{
    if (!_t.dragging)
        return;
    [self autoscroll:event];
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSUInteger i = [self characterIndexForInsertionAtPoint:p];
    NSRange r;
    if (_granularity == NSSelectByCharacter) {
        NSUInteger a = _dragUnit.location;
        r = i < a ? NSMakeRange(i, a - i) : NSMakeRange(a, i - a);
    } else {
        NSRange u = [self selectionRangeForProposedRange:NSMakeRange(i, 0) granularity:_granularity];
        r = NSUnionRange(_dragUnit, u);
    }
    [self setSelectedRange:r affinity:NSSelectionAffinityDownstream stillSelecting:YES];
}

- (void)mouseUp:(NSEvent *)event
{
    if (!_t.dragging)
        return;
    _t.dragging = NO;
    [self setSelectedRange:_sel affinity:_affinity stillSelecting:NO];
    if (is_first_responder(self) && _t.editable)
        start_blinking(self);
}

- (void)keyDown:(NSEvent *)event
{
    if (!_t.selectable) {
        [super keyDown:event];
        return;
    }
    [self interpretKeyEvents:@[ event ]];
    if (is_first_responder(self) && _t.editable)
        start_blinking(self);
}

/* With no menu to give them, the standard editing equivalents. */
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if (!is_first_responder(self) || [[NSApp mainMenu] performKeyEquivalent:event])
        return [super performKeyEquivalent:event];
    NSEventModifierFlags m = [event modifierFlags] & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                                      NSEventModifierFlagOption | NSEventModifierFlagControl);
    NSString *k = [event charactersIgnoringModifiers];
    if (!(m & NSEventModifierFlagCommand) || [k length] != 1)
        return [super performKeyEquivalent:event];
    unichar c = [[k lowercaseString] characterAtIndex:0];
    BOOL shift = (m & NSEventModifierFlagShift) != 0;
    if (m & (NSEventModifierFlagOption | NSEventModifierFlagControl))
        return [super performKeyEquivalent:event];
    switch (c) {
    case 'x':
        [self cut:self];
        return YES;
    case 'c':
        [self copy:self];
        return YES;
    case 'v':
        [self paste:self];
        return YES;
    case 'a':
        [self selectAll:self];
        return YES;
    case 'z':
        if (shift)
            [[self undoManager] redo];
        else
            [[self undoManager] undo];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    SEL a = [item action];
    if (a == @selector(cut:) || a == @selector(delete:))
        return _t.editable && _sel.length;
    if (a == @selector(copy:))
        return _sel.length > 0;
    if (a == @selector(paste:) || a == @selector(pasteAsPlainText:) || a == @selector(pasteAsRichText:))
        return _t.editable && [[NSPasteboard generalPasteboard] availableTypeFromArray:[self readablePasteboardTypes]];
    if (a == @selector(undo:))
        return [[self undoManager] canUndo];
    if (a == @selector(redo:))
        return [[self undoManager] canRedo];
    return [self respondsToSelector:a];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item { return [self validateUserInterfaceItem:(id)item]; }

#pragma mark - The pasteboard

- (NSArray<NSPasteboardType> *)writablePasteboardTypes { return @[ NSPasteboardTypeString ]; }
- (NSArray<NSPasteboardType> *)readablePasteboardTypes { return @[ NSPasteboardTypeString, NSStringPboardType ]; }
- (NSPasteboardType)preferredPasteboardTypeFromArray:(NSArray<NSPasteboardType> *)availableTypes
                         restrictedToTypesFromArray:(NSArray<NSPasteboardType> *)allowedTypes
{
    for (NSString *t in [self readablePasteboardTypes])
        if ([availableTypes containsObject:t] && (!allowedTypes || [allowedTypes containsObject:t]))
            return t;
    return nil;
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard type:(NSPasteboardType)type
{
    if (!_sel.length)
        return NO;
    if (![type isEqualToString:NSPasteboardTypeString] && ![type isEqualToString:NSStringPboardType])
        return NO;
    if (![[pboard types] containsObject:type])
        return NO;
    return [pboard setString:[[_storage string] substringWithRange:_sel] forType:NSPasteboardTypeString];
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard types:(NSArray<NSPasteboardType> *)types
{
    if (!_sel.length)
        return NO;
    [pboard declareTypes:types owner:nil];
    for (NSString *t in types)
        if ([t isEqualToString:NSPasteboardTypeString] || [t isEqualToString:NSStringPboardType])
            return [pboard setString:[[_storage string] substringWithRange:_sel] forType:NSPasteboardTypeString];
    return NO;
}

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard type:(NSPasteboardType)type
{
    NSString *s = [pboard stringForType:type];
    if (!s || !_t.editable)
        return NO;
    return insert(self, s, _sel, @"Paste");
}

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard
{
    NSString *t = [pboard availableTypeFromArray:[self readablePasteboardTypes]];
    return t ? [self readSelectionFromPasteboard:pboard type:t] : NO;
}

- (void)copy:(id)sender
{
    if (!_sel.length)
        return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[[_storage string] substringWithRange:_sel] forType:NSPasteboardTypeString];
}

- (void)cut:(id)sender
{
    if (!_sel.length || !_t.editable)
        return;
    [self copy:sender];
    delete_range(self, _sel, @"Cut");
}

- (void)paste:(id)sender { [self readSelectionFromPasteboard:[NSPasteboard generalPasteboard]]; }
- (void)pasteAsPlainText:(id)sender { [self readSelectionFromPasteboard:[NSPasteboard generalPasteboard]]; }
- (void)pasteAsRichText:(id)sender { [self readSelectionFromPasteboard:[NSPasteboard generalPasteboard]]; }

- (id)validRequestorForSendType:(NSPasteboardType)sendType returnType:(NSPasteboardType)returnType
{
    return [super validRequestorForSendType:sendType returnType:returnType];
}

#pragma mark - NSTextInputClient

- (BOOL)hasMarkedText { return _marked.location != NSNotFound && _marked.length > 0; }
- (NSRange)markedRange { return [self hasMarkedText] ? _marked : NSMakeRange(NSNotFound, 0); }

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange
{
    if (!_t.editable)
        return;
    NSString *plain = [string isKindOfClass:[NSAttributedString class]] ? [string string] : string;
    NSRange r = replacementRange.location != NSNotFound ? clamp_range(self, replacementRange)
                : [self hasMarkedText]                     ? _marked
                                                           : _sel;
    if (![self shouldChangeTextInRange:r replacementString:plain])
        return;
    NSMutableDictionary *attrs = [[_typing mutableCopy] autorelease];
    [attrs addEntriesFromDictionary:[self markedTextAttributes]];
    NSAttributedString *a = [[[NSAttributedString alloc] initWithString:plain ?: @"" attributes:attrs] autorelease];
    NSRange sel = NSMakeRange(r.location + MIN(selectedRange.location, [plain length]), selectedRange.length);
    replace(self, r, a, @"Typing", sel);
    _marked = [plain length] ? NSMakeRange(r.location, [plain length]) : NSMakeRange(NSNotFound, 0);
    [self didChangeText];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange
{
    [self setMarkedText:string selectedRange:selectedRange replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)unmarkText
{
    if ([self hasMarkedText]) {
        NSRange m = clamp_range(self, _marked);
        _t.selfEdit = YES;
        for (NSString *k in [self markedTextAttributes])
            if (!_typing[k])
                [_storage removeAttribute:k range:m];
        _t.selfEdit = NO;
    }
    _marked = NSMakeRange(NSNotFound, 0);
    [self setNeedsDisplay:YES];
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual
{
    range = clamp_range(self, range);
    if (actual)
        *actual = range;
    return [_storage attributedSubstringFromRange:range];
}

- (NSAttributedString *)attributedString { return _storage; }
- (CGFloat)baselineDeltaForCharacterAtIndex:(NSUInteger)index
{
    NSFont *f = [_storage length] ? [_storage attribute:NSFontAttributeName atIndex:MIN(index, [_storage length] - 1)
                                         effectiveRange:NULL]
                                  : nil;
    return [f ?: _typing[NSFontAttributeName] ascender];
}
- (NSInteger)windowLevel { return [[self window] level]; }
- (BOOL)drawsVerticallyForCharacterAtIndex:(NSUInteger)index { return NO; }

#pragma mark - Misc actions

- (void)complete:(id)sender {}
- (void)toggleContinuousSpellChecking:(id)sender { _t.continuousSpelling = !_t.continuousSpelling; }
- (void)toggleRuler:(id)sender { _t.rulerVisible = !_t.rulerVisible; }
- (void)checkSpelling:(id)sender {}
- (void)showGuessPanel:(id)sender {}
- (void)changeFont:(id)sender {}
- (void)changeColor:(id)sender {}
- (void)changeAttributes:(id)sender {}
- (void)changeDocumentBackgroundColor:(id)sender {}
- (void)orderFrontSpellingPanel:(id)sender {}
- (void)performFindPanelAction:(id)sender {}
- (void)performTextFinderAction:(id)sender {}

- (void)showFindIndicatorForRange:(NSRange)range {}
- (void)setNeedsDisplayInRect:(NSRect)rect avoidAdditionalLayout:(BOOL)flag { [self setNeedsDisplayInRect:rect]; }

#pragma mark - Archiving

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    tv_defaults(self);
    NSTextContainer *tc = [coder decodeObjectForKey:@"NSTextContainer"];
    if (tc)
        adopt(self, tc);
    else
        adopt(self, [[[NSTextContainer alloc] initWithSize:NSMakeSize(NSWidth([self frame]), 10000000)] autorelease]);
    unsigned tv = (unsigned)[coder decodeIntForKey:@"NSTVFlags"];
    _t.hResizable = (tv & TV_HORIZONTALLY_RESIZABLE) != 0;
    _t.vResizable = (tv & TV_VERTICALLY_RESIZABLE) != 0;
    _minSize = [coder containsValueForKey:@"NSMinize"]   ? [coder decodeSizeForKey:@"NSMinize"]
               : [coder containsValueForKey:@"NSMinSize"] ? [coder decodeSizeForKey:@"NSMinSize"]
                                                          : [self frame].size;
    _maxSize = [coder containsValueForKey:@"NSMaxSize"] ? [coder decodeSizeForKey:@"NSMaxSize"] : [self frame].size;
    if ([coder containsValueForKey:@"NSTextContainerInset"])
        _inset = [coder decodeSizeForKey:@"NSTextContainerInset"];
    NSTextViewSharedData *shared = [coder decodeObjectForKey:@"NSSharedData"];
    if ([shared isKindOfClass:[NSTextViewSharedData class]]) {
        uint32_t f = shared->_flags;
        _t.selectable = (f & TF_SELECTABLE) != 0;
        _t.editable = (f & TF_EDITABLE) != 0;
        _t.rich = (f & TF_RICH) != 0;
        _t.imports = (f & TF_IMPORTS_GRAPHICS) != 0;
        _t.fieldEditor = (f & TF_FIELD_EDITOR) != 0;
        _t.rulerVisible = (f & TF_RULER_VISIBLE) != 0;
        _t.usesRuler = (f & TF_USES_RULER) != 0;
        _t.continuousSpelling = (f & TF_CONTINUOUS_SPELLING) != 0;
        _t.drawsBackground = (f & TF_DRAWS_BACKGROUND) != 0;
        _t.smartInsert = (f & TF_SMART_INSERT) != 0;
        _t.allowsUndo = (f & TF_ALLOWS_UNDO) != 0;
        _t.usesFontPanel = (f & TF_USES_FONT_PANEL) != 0;
        _t.findPanel = (f & TF_USES_FIND_PANEL) != 0;
        _t.documentBackground = (f & TF_DOCUMENT_BACKGROUND) != 0;
        _t.grammar = (f & TF_GRAMMAR) != 0;
        _t.imageEditing = (f & TF_IMAGE_EDITING) != 0;
        _t.quotes = (f & TF_QUOTES) != 0;
        _t.links = (f & TF_LINKS) != 0;
        _t.data = (f & TF_DATA_DETECTION) != 0;
        _t.dashes = (f & TF_DASHES) != 0;
        _t.replacement = (f & TF_REPLACEMENT) != 0;
        _t.spellingCorrection = (f & TF_SPELLING_CORRECTION) != 0;
        _t.incremental = (f & TF_INCREMENTAL_SEARCH) != 0;
        _t.inspectorBar = (f & TF_INSPECTOR_BAR) != 0;
        _background = [shared->_background retain];
        _insertionColor = [shared->_insertion retain];
        _selectedAttributes = [shared->_selected copy];
        _markedAttributes = [shared->_marked copy];
        _linkAttributes = [shared->_link copy];
        _defaultParagraphStyle = [shared->_paragraphStyle copy];
    }
    if ([_storage length]) {
        [_typing release];
        _typing = [[_storage attributesAtIndex:[_storage length] - 1 effectiveRange:NULL] copy];
    }
    _sel = NSMakeRange(0, 0);
    [self setDelegate:[coder decodeObjectForKey:@"NSDelegate"]];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_container)
        [coder encodeObject:_container forKey:@"NSTextContainer"];
    unsigned tv = (_t.hResizable ? TV_HORIZONTALLY_RESIZABLE : 0) | (_t.vResizable ? TV_VERTICALLY_RESIZABLE : 0);
    [coder encodeInt:(int)tv forKey:@"NSTVFlags"];
    [coder encodeSize:_minSize forKey:@"NSMinize"];
    [coder encodeSize:_maxSize forKey:@"NSMaxSize"];
    if (!NSEqualSizes(_inset, NSZeroSize))
        [coder encodeSize:_inset forKey:@"NSTextContainerInset"];
    NSTextViewSharedData *shared = [[NSTextViewSharedData alloc] init];
    shared->_flags = (_t.selectable ? TF_SELECTABLE : 0) | (_t.editable ? TF_EDITABLE : 0) | (_t.rich ? TF_RICH : 0) |
                     (_t.imports ? TF_IMPORTS_GRAPHICS : 0) | (_t.fieldEditor ? TF_FIELD_EDITOR : 0) |
                     (_t.rulerVisible ? TF_RULER_VISIBLE : 0) | (_t.usesRuler ? TF_USES_RULER : 0) |
                     (_t.continuousSpelling ? TF_CONTINUOUS_SPELLING : 0) |
                     (_t.drawsBackground ? TF_DRAWS_BACKGROUND : 0) | (_t.smartInsert ? TF_SMART_INSERT : 0) |
                     (_t.allowsUndo ? TF_ALLOWS_UNDO : 0) | (_t.usesFontPanel ? TF_USES_FONT_PANEL : 0);
    shared->_background = [_background retain];
    shared->_insertion = [_insertionColor retain];
    shared->_selected = [_selectedAttributes copy];
    shared->_marked = [_markedAttributes copy];
    shared->_link = [_linkAttributes copy];
    shared->_paragraphStyle = [_defaultParagraphStyle copy];
    [coder encodeObject:shared forKey:@"NSSharedData"];
    [shared release];
    if (_delegate)
        [coder encodeConditionalObject:_delegate forKey:@"NSDelegate"];
}

@end

#pragma mark - The field editor

@implementation NSWindow (FinchFieldEditor)

static const void *field_editor_key = &field_editor_key;

- (NSText *)fieldEditor:(BOOL)createFlag forObject:(id)object
{
    id d = [self delegate];
    if ([d respondsToSelector:@selector(windowWillReturnFieldEditor:toObject:)]) {
        id fe = [d windowWillReturnFieldEditor:self toObject:object];
        if (fe)
            return fe;
    }
    NSTextView *fe = objc_getAssociatedObject(self, field_editor_key);
    if (!fe && createFlag) {
        fe = [[NSTextView alloc] initWithFrame:NSZeroRect];
        [fe setFieldEditor:YES];
        [fe setHorizontallyResizable:NO];
        [fe setVerticallyResizable:YES];
        [[fe textContainer] setWidthTracksTextView:NO];
        [[fe textContainer] setHeightTracksTextView:NO];
        [[fe textContainer] setSize:NSMakeSize(9000000, 9000000)];
        objc_setAssociatedObject(self, field_editor_key, fe, OBJC_ASSOCIATION_RETAIN);
        [fe release];
    }
    return fe;
}

- (void)endEditingFor:(id)object
{
    NSTextView *fe = objc_getAssociatedObject(self, field_editor_key);
    if (fe && [self firstResponder] == fe)
        [self makeFirstResponder:self];
}

@end
