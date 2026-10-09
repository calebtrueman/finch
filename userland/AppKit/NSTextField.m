/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextField: labels and editable fields. Editing goes through the
 * window's field editor (-[NSWindow fieldEditor:forObject:]): the control
 * becomes the editor's delegate and NSControl turns its notifications into
 * the NSControlTextEditingDelegate ones. Without a field editor the field
 * still shows and keeps its value; it just can't be edited.
 */
#import "NSControl_Finch.h"

@interface NSControl (FinchEditing)
- (void)_finchBeganEditor:(NSText *)editor;
- (BOOL)textShouldBeginEditing:(NSText *)text;
- (BOOL)textShouldEndEditing:(NSText *)text;
- (void)textDidBeginEditing:(NSNotification *)note;
- (void)textDidEndEditing:(NSNotification *)note;
- (void)textDidChange:(NSNotification *)note;
@end

@implementation NSTextField {
    id _delegate; /* weak */
    CGFloat _preferredMaxLayoutWidth;
    NSInteger _maximumNumberOfLines;
    NSLineBreakStrategy _lineBreakStrategy;
    NSArray *_placeholderStrings, *_placeholderAttributedStrings;
    struct {
        unsigned tightening : 1;
        unsigned noCompletion : 1;
        unsigned characterPicker : 1;
        unsigned noWritingTools : 1;
        unsigned writingToolsAffordance : 1;
        unsigned resolvesNatural : 1;
    } _tf;
}

+ (Class)cellClass
{
    return [super cellClass] ?: [NSTextFieldCell class];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    NSTextFieldCell *c = [self cell];
    [c setStringValue:@""];
    [c setEditable:YES];
    [c setSelectable:YES];
    [c setBezeled:YES];
    if ([c respondsToSelector:@selector(setDrawsBackground:)])
        [c setDrawsBackground:YES];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    if ([coder containsValueForKey:@"NSTextFieldAutomaticTextCompletionDisabled"] ||
        [coder decodeBoolForKey:@"NSAutomaticTextCompletionDisabled"])
        _tf.noCompletion = YES;
    if ([coder containsValueForKey:@"NSPreferredMaxLayoutWidth"])
        _preferredMaxLayoutWidth = [coder decodeDoubleForKey:@"NSPreferredMaxLayoutWidth"];
    if ([coder containsValueForKey:@"NSMaximumNumberOfLines"])
        _maximumNumberOfLines = [coder decodeIntegerForKey:@"NSMaximumNumberOfLines"];
    return self;
}

- (void)dealloc
{
    [_placeholderStrings release];
    [_placeholderAttributedStrings release];
    [super dealloc];
}

static id
make_field(Class cls, NSString *string, BOOL editable)
{
    NSTextField *t = [[[cls alloc] initWithFrame:NSZeroRect] autorelease];
    NSTextFieldCell *c = [t cell];
    [c setStringValue:string ?: @""];
    [c setEditable:editable];
    [c setSelectable:editable];
    [c setBezeled:editable];
    [c setDrawsBackground:editable];
    [c setAlignment:NSTextAlignmentNatural];
    [c setLineBreakMode:NSLineBreakByClipping];
    if (editable) {
        [c setScrollable:YES];
        [c setSendsActionOnEndEditing:YES];
    } else {
        [c setTextColor:[NSColor labelColor]];
    }
    return t;
}

+ (instancetype)labelWithString:(NSString *)string
{
    NSTextField *t = make_field(self, string, NO);
    [t sizeToFit];
    return t;
}

+ (instancetype)labelWithAttributedString:(NSAttributedString *)string
{
    NSTextField *t = make_field(self, @"", NO);
    [t setAttributedStringValue:string];
    [t sizeToFit];
    return t;
}

+ (instancetype)wrappingLabelWithString:(NSString *)string
{
    NSTextField *t = make_field(self, string, NO);
    [[t cell] setSelectable:YES];
    [[t cell] setLineBreakMode:NSLineBreakByWordWrapping];
    [t sizeToFit];
    return t;
}

+ (instancetype)textFieldWithString:(NSString *)string
{
    NSTextField *t = make_field(self, string, YES);
    [t sizeToFit];
    return t;
}

#pragma mark Properties

static NSTextFieldCell *
tcell(NSTextField *t)
{
    id c = [t cell];
    return [c isKindOfClass:[NSTextFieldCell class]] ? c : nil;
}

- (BOOL)isFlipped { return YES; }
- (id<NSTextFieldDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSTextFieldDelegate>)delegate { _delegate = delegate; }
- (NSString *)placeholderString { return [tcell(self) placeholderString]; }
- (void)setPlaceholderString:(NSString *)s { [tcell(self) setPlaceholderString:s]; }
- (NSAttributedString *)placeholderAttributedString { return [tcell(self) placeholderAttributedString]; }
- (void)setPlaceholderAttributedString:(NSAttributedString *)s { [tcell(self) setPlaceholderAttributedString:s]; }
- (NSColor *)backgroundColor { return [tcell(self) backgroundColor]; }
- (void)setBackgroundColor:(NSColor *)c { [tcell(self) setBackgroundColor:c]; }
- (BOOL)drawsBackground { return [tcell(self) drawsBackground]; }
- (void)setDrawsBackground:(BOOL)flag { [tcell(self) setDrawsBackground:flag]; }
- (NSColor *)textColor { return [tcell(self) textColor]; }

- (void)setTextColor:(NSColor *)c
{
    [tcell(self) setTextColor:c];
    [[self currentEditor] setTextColor:c];
}

- (BOOL)isBordered { return [[self cell] isBordered]; }
- (void)setBordered:(BOOL)flag { [[self cell] setBordered:flag]; [self setNeedsDisplay:YES]; }
- (BOOL)isBezeled { return [[self cell] isBezeled]; }
- (void)setBezeled:(BOOL)flag { [[self cell] setBezeled:flag]; [self setNeedsDisplay:YES]; }
- (BOOL)isEditable { return [[self cell] isEditable]; }

- (void)setEditable:(BOOL)flag
{
    if (!flag)
        [self abortEditing];
    [[self cell] setEditable:flag];
}

- (BOOL)isSelectable { return [[self cell] isSelectable]; }

- (void)setSelectable:(BOOL)flag
{
    if (!flag)
        [self abortEditing];
    [[self cell] setSelectable:flag];
}

- (NSTextFieldBezelStyle)bezelStyle { return [tcell(self) bezelStyle]; }
- (void)setBezelStyle:(NSTextFieldBezelStyle)s { [tcell(self) setBezelStyle:s]; [self setNeedsDisplay:YES]; }
- (CGFloat)preferredMaxLayoutWidth { return _preferredMaxLayoutWidth; }
- (void)setPreferredMaxLayoutWidth:(CGFloat)w { _preferredMaxLayoutWidth = w; }
- (NSInteger)maximumNumberOfLines { return _maximumNumberOfLines; }
- (void)setMaximumNumberOfLines:(NSInteger)n { _maximumNumberOfLines = n; }
- (BOOL)allowsDefaultTighteningForTruncation { return _tf.tightening; }
- (void)setAllowsDefaultTighteningForTruncation:(BOOL)flag { _tf.tightening = flag; }
- (NSLineBreakStrategy)lineBreakStrategy { return _lineBreakStrategy; }
- (void)setLineBreakStrategy:(NSLineBreakStrategy)s { _lineBreakStrategy = s; }
- (BOOL)allowsWritingTools { return !_tf.noWritingTools; }
- (void)setAllowsWritingTools:(BOOL)flag { _tf.noWritingTools = !flag; }
- (BOOL)allowsWritingToolsAffordance { return _tf.writingToolsAffordance; }
- (void)setAllowsWritingToolsAffordance:(BOOL)flag { _tf.writingToolsAffordance = flag; }
- (BOOL)resolvesNaturalAlignmentWithBaseWritingDirection { return _tf.resolvesNatural; }
- (void)setResolvesNaturalAlignmentWithBaseWritingDirection:(BOOL)flag { _tf.resolvesNatural = flag; }
- (NSArray<NSString *> *)placeholderStrings { return _placeholderStrings ?: @[]; }

- (void)setPlaceholderStrings:(NSArray<NSString *> *)a
{
    [_placeholderStrings release];
    _placeholderStrings = [a copy];
    [self setPlaceholderString:[a firstObject]];
}

- (NSArray<NSAttributedString *> *)placeholderAttributedStrings { return _placeholderAttributedStrings ?: @[]; }

- (void)setPlaceholderAttributedStrings:(NSArray<NSAttributedString *> *)a
{
    [_placeholderAttributedStrings release];
    _placeholderAttributedStrings = [a copy];
    [self setPlaceholderAttributedString:[a firstObject]];
}

- (BOOL)isAutomaticTextCompletionEnabled { return !_tf.noCompletion; }
- (void)setAutomaticTextCompletionEnabled:(BOOL)flag { _tf.noCompletion = !flag; }
- (BOOL)allowsCharacterPickerTouchBarItem { return _tf.characterPicker; }
- (void)setAllowsCharacterPickerTouchBarItem:(BOOL)flag { _tf.characterPicker = flag; }
- (BOOL)allowsEditingTextAttributes { return [[self cell] allowsEditingTextAttributes]; }
- (void)setAllowsEditingTextAttributes:(BOOL)flag { [[self cell] setAllowsEditingTextAttributes:flag]; }
- (BOOL)importsGraphics { return [[self cell] importsGraphics]; }
- (void)setImportsGraphics:(BOOL)flag { [[self cell] setImportsGraphics:flag]; }

#pragma mark Size

- (NSSize)intrinsicContentSize
{
    NSCell *c = [self cell];
    if (!c)
        return [super intrinsicContentSize];
    if ([c isEditable] || [c isScrollable])
        return NSMakeSize(NSViewNoIntrinsicMetric, [c cellSize].height);
    if ([c wraps] && _preferredMaxLayoutWidth > 0)
        return [c cellSizeForBounds:NSMakeRect(0, 0, _preferredMaxLayoutWidth, 1e7)];
    return [c cellSize];
}

#pragma mark Editing

- (BOOL)acceptsFirstResponder { return [[self cell] acceptsFirstResponder]; }
- (BOOL)_finchBecomesFirstResponderOnClick { return YES; }

- (NSText *)_finchFieldEditor
{
    NSWindow *w = [self window];
    if (!w || ![w respondsToSelector:@selector(fieldEditor:forObject:)])
        return nil;
    return [w fieldEditor:YES forObject:self];
}

- (BOOL)becomeFirstResponder
{
    if ([self isSelectable] && ![self currentEditor])
        [self selectText:self];
    return YES;
}

- (void)selectText:(id)sender
{
    if (![self isSelectable] || ![self window])
        return;
    NSText *ed = [self currentEditor];
    if (ed) {
        [ed selectAll:self];
        return;
    }
    ed = [self _finchFieldEditor];
    if (!ed)
        return;
    [self validateEditing];
    [self selectWithFrame:[self bounds] editor:ed delegate:self start:0 length:(NSInteger)[[[self cell] stringValue] length]];
}

- (void)mouseDown:(NSEvent *)event
{
    if (![self isEnabled])
        return;
    if (![self isSelectable]) {
        [[self nextResponder] mouseDown:event];
        return;
    }
    NSText *ed = [self currentEditor];
    if (ed) {
        [ed mouseDown:event];
        return;
    }
    ed = [self _finchFieldEditor];
    if (!ed)
        return;
    [self editWithFrame:[self bounds] editor:ed delegate:self event:event];
}

- (BOOL)textShouldBeginEditing:(NSText *)text
{
    if (![self isEditable])
        return NO;
    return [super textShouldBeginEditing:text];
}

- (BOOL)textShouldEndEditing:(NSText *)text { return [super textShouldEndEditing:text]; }
- (void)textDidBeginEditing:(NSNotification *)note { [super textDidBeginEditing:note]; }
- (void)textDidEndEditing:(NSNotification *)note { [super textDidEndEditing:note]; }
- (void)textDidChange:(NSNotification *)note { [super textDidChange:note]; }

- (void)resetCursorRects
{
    id cursor = [(id)FINCH_CLASS(NSCursor) respondsToSelector:@selector(IBeamCursor)] ? [(id)FINCH_CLASS(NSCursor) IBeamCursor] : nil;
    if ([self isSelectable] && cursor)
        [self addCursorRect:[self bounds] cursor:cursor];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item { return YES; }

@end
