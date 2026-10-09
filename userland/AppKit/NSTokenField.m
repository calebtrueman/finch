/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSTokenField_Finch.h"

@interface NSTextField (FinchTokenEditing)
- (void)textDidChange:(NSNotification *)note;
- (void)textDidEndEditing:(NSNotification *)note;
@end

@interface _FinchTokenEditor : NSTextView
@property (assign) NSTokenField *tokenField;
@end

@implementation _FinchTokenEditor
- (NSArray *)_finchCharacterRects
{
    NSMutableArray *rects = [NSMutableArray array]; NSAttributedString *storage = [self textStorage];
    NSTokenFieldCell *cell = [_tokenField cell]; CGFloat x = 2, y = 1, width = MAX(1, [self bounds].size.width - 4);
    for (NSUInteger i = 0; i < [storage length]; i++) {
        id object = [storage attribute:FinchTokenObjectAttribute atIndex:i effectiveRange:NULL];
        NSString *text = object ? [cell _finchDisplayString:object] : [[storage string] substringWithRange:NSMakeRange(i, 1)];
        CGFloat w = MAX(1, ceil([text sizeWithAttributes:[cell _finchTextAttributes]].width)) + (object ? 15 : 0);
        if (x > 2 && x + w > width) { x = 2; y += 21; }
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x, y, w, 19)]]; x += w;
    }
    [rects addObject:[NSValue valueWithRect:NSMakeRect(x, y, 1, 19)]]; return rects;
}
- (NSUInteger)characterIndexForInsertionAtPoint:(NSPoint)point
{
    NSArray *rects = [self _finchCharacterRects];
    for (NSUInteger i = 0; i + 1 < [rects count]; i++) {
        NSRect rect = [[rects objectAtIndex:i] rectValue];
        if (point.y < NSMaxY(rect) && point.x < NSMidX(rect)) return i;
        if (NSPointInRect(point, rect)) return i + 1;
    }
    return [[self string] length];
}
- (void)drawRect:(NSRect)dirty
{
    NSArray *rects = [self _finchCharacterRects]; NSTokenFieldCell *cell = [_tokenField cell];
    NSAttributedString *storage = [self textStorage]; NSRange selection = [self selectedRange];
    for (NSUInteger i = 0; i < [storage length]; i++) {
        NSRect rect = [[rects objectAtIndex:i] rectValue];
        id object = [storage attribute:FinchTokenObjectAttribute atIndex:i effectiveRange:NULL];
        NSString *s = object ? [cell _finchDisplayString:object] : [[storage string] substringWithRange:NSMakeRange(i, 1)];
        BOOL selected = NSLocationInRange(i, selection);
        NSTokenStyle style = object ? [cell _finchStyleForObject:object] : NSTokenStyleNone;
        if (selected || (object && style != NSTokenStyleNone && style != NSTokenStylePlainSquared))
            FinchDrawBezel(NSInsetRect(rect, 1, 0), object && style != NSTokenStyleSquared ? 8 : 1,
                           [FinchAccentColor() colorWithAlphaComponent:selected ? 0.4 : 0.18], nil);
        NSAttributedString *text = [[[NSAttributedString alloc] initWithString:s attributes:[cell _finchTextAttributes]] autorelease];
        FinchDrawCellText(text, object ? NSInsetRect(rect, 6, 0) : rect, YES);
    }
    if (!selection.length && [[self window] firstResponder] == self) {
        NSRect caret = [[rects objectAtIndex:MIN(selection.location, [rects count] - 1)] rectValue];
        caret.size.width = 1; [[NSColor textColor] setFill]; NSRectFill(caret);
    }
}
- (void)insertText:(id)string replacementRange:(NSRange)range
{
    [self setTypingAttributes:[[_tokenField cell] _finchTextAttributes]];
    [super insertText:string replacementRange:range];
}
- (void)mouseDown:(NSEvent *)event
{
    [super mouseDown:event];
    if ([event clickCount] > 1 && [self selectedRange].length == 1) {
        NSUInteger index = [self selectedRange].location;
        id object = [[self textStorage] attribute:FinchTokenObjectAttribute atIndex:index effectiveRange:NULL];
        if (object) [self insertText:[[_tokenField cell] _finchEditingString:object] replacementRange:[self selectedRange]];
    }
}
- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSUInteger index = [self characterIndexForInsertionAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]];
    if (index >= [[self textStorage] length] && index) index--;
    id object = index < [[self textStorage] length] ? [[self textStorage] attribute:FinchTokenObjectAttribute atIndex:index effectiveRange:NULL] : nil;
    return object ? [[_tokenField cell] _finchMenuForObject:object] : [super menuForEvent:event];
}
- (void)copy:(id)sender
{
    NSRange selection = [self selectedRange]; if (!selection.length) return;
    NSTokenFieldCell *cell = [_tokenField cell];
    NSArray *objects = [cell _finchObjectsFromString:[[self textStorage] attributedSubstringFromRange:selection]];
    NSMutableArray *strings = [NSMutableArray array]; for (id object in objects) [strings addObject:[cell _finchEditingString:object]];
    NSPasteboard *board = [NSPasteboard generalPasteboard]; [board clearContents];
    [board setString:[strings componentsJoinedByString:@","] forType:NSPasteboardTypeString];
    id delegate = [_tokenField delegate];
    if ([delegate respondsToSelector:@selector(tokenField:writeRepresentedObjects:toPasteboard:)])
        [delegate tokenField:_tokenField writeRepresentedObjects:objects toPasteboard:board];
    else if ([[cell delegate] respondsToSelector:@selector(tokenFieldCell:writeRepresentedObjects:toPasteboard:)])
        [[cell delegate] tokenFieldCell:cell writeRepresentedObjects:objects toPasteboard:board];
}
- (void)cut:(id)sender { if ([self isEditable]) { [self copy:sender]; [self delete:sender]; } }
- (void)paste:(id)sender
{
    if (![self isEditable]) return;
    NSPasteboard *board = [NSPasteboard generalPasteboard]; NSTokenFieldCell *cell = [_tokenField cell];
    NSArray *objects = nil; id delegate = [_tokenField delegate];
    if ([delegate respondsToSelector:@selector(tokenField:readFromPasteboard:)]) objects = [delegate tokenField:_tokenField readFromPasteboard:board];
    else if ([[cell delegate] respondsToSelector:@selector(tokenFieldCell:readFromPasteboard:)]) objects = [[cell delegate] tokenFieldCell:cell readFromPasteboard:board];
    if (objects) {
        NSArray *prefix = [cell _finchObjectsFromString:[[self textStorage] attributedSubstringFromRange:NSMakeRange(0, [self selectedRange].location)]];
        objects = [cell _finchShouldAdd:objects atIndex:[prefix count]];
        [self insertText:[cell _finchTokenString:objects] replacementRange:[self selectedRange]];
    } else [super paste:sender];
}
- (void)complete:(id)sender { [_tokenField _finchComplete:sender]; }
- (void)insertNewline:(id)sender
{
    if ([[_tokenField cell] _finchTokenizeEditor:self finish:YES]) [self didChangeText];
    else [super insertNewline:sender];
}
@end

@implementation NSTokenField {
    _FinchTokenEditor *_tokenEditor;
    NSTimer *_completionTimer;
    NSArray *_completions;
    NSRange _completionRange;
    NSInteger _selectedCompletion;
    BOOL _tokenizing;
}
+ (Class)cellClass
{
    Class c = [super cellClass]; return c == [NSTextFieldCell class] ? [NSTokenFieldCell class] : c;
}
+ (NSTimeInterval)defaultCompletionDelay { return [NSTokenFieldCell defaultCompletionDelay]; }
+ (NSCharacterSet *)defaultTokenizingCharacterSet { return [NSTokenFieldCell defaultTokenizingCharacterSet]; }
- (void)dealloc
{
    [_completionTimer invalidate]; [_completionTimer release]; [_completions release];
    [_tokenEditor setTokenField:nil]; [_tokenEditor release]; [super dealloc];
}
- (NSTokenStyle)tokenStyle { return [[self cell] tokenStyle]; }
- (void)setTokenStyle:(NSTokenStyle)s { [[self cell] setTokenStyle:s]; }
- (NSTimeInterval)completionDelay { return [[self cell] completionDelay]; }
- (void)setCompletionDelay:(NSTimeInterval)t { [[self cell] setCompletionDelay:t]; }
- (NSCharacterSet *)tokenizingCharacterSet { return [[self cell] tokenizingCharacterSet]; }
- (void)setTokenizingCharacterSet:(NSCharacterSet *)s { [[self cell] setTokenizingCharacterSet:s]; }
- (NSText *)_finchFieldEditor
{
    if (!_tokenEditor) {
        _tokenEditor = [[_FinchTokenEditor alloc] initWithFrame:[self bounds]];
        [_tokenEditor setFieldEditor:YES]; [_tokenEditor setTokenField:self];
    }
    return _tokenEditor;
}
- (void)validateEditing
{
    NSTextView *editor = (NSTextView *)[self currentEditor];
    if (editor) [[self cell] setObjectValue:[[self cell] _finchObjectsFromString:[editor textStorage]]];
}
- (void)textDidChange:(NSNotification *)note
{
    if (_tokenizing) return;
    _tokenizing = YES;
    BOOL changed = [[self cell] _finchTokenizeEditor:[note object] finish:NO];
    _tokenizing = NO;
    [super textDidChange:note]; if (changed) [super textDidChange:note];
    [_completionTimer invalidate]; [_completionTimer release]; _completionTimer = nil;
    if ([self completionDelay] >= 0)
        _completionTimer = [[NSTimer scheduledTimerWithTimeInterval:[self completionDelay] target:self
                                                         selector:@selector(_finchCompletionTimer:) userInfo:nil repeats:NO] retain];
}
- (void)textDidEndEditing:(NSNotification *)note
{
    _tokenizing = YES;
    BOOL changed = [[self cell] _finchTokenizeEditor:[note object] finish:YES];
    _tokenizing = NO;
    if (changed) [super textDidChange:note];
    [_completionTimer invalidate]; [_completionTimer release]; _completionTimer = nil;
    [super textDidEndEditing:note];
}
- (void)_finchCompletionTimer:(NSTimer *)timer
{
    [_completionTimer release]; _completionTimer = nil; [self _finchRequestCompletions];
}
- (void)_finchRequestCompletions
{
    NSTextView *editor = (NSTextView *)[self currentEditor]; if (!editor) return;
    NSAttributedString *storage = [editor textStorage]; NSUInteger end = MIN([editor selectedRange].location, [storage length]), start = end;
    while (start && ![storage attribute:FinchTokenObjectAttribute atIndex:start - 1 effectiveRange:NULL] &&
           ![[self tokenizingCharacterSet] characterIsMember:[[storage string] characterAtIndex:start - 1]]) start--;
    _completionRange = NSMakeRange(start, end - start); _selectedCompletion = -1;
    NSInteger index = [[[self cell] _finchObjectsFromString:[storage attributedSubstringFromRange:NSMakeRange(0, start)]] count];
    NSArray *completions = [[self cell] _finchCompletions:[[storage string] substringWithRange:_completionRange] index:index selected:&_selectedCompletion];
    [completions retain]; [_completions release]; _completions = completions;
}
- (void)_finchChooseCompletion:(NSMenuItem *)item
{
    [(NSTextView *)[self currentEditor] insertText:[item title] replacementRange:_completionRange];
}
- (void)_finchComplete:(id)sender
{
    [self _finchRequestCompletions]; if (![_completions count]) return;
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    for (id completion in _completions) {
        NSMenuItem *item = [menu addItemWithTitle:[completion description] action:@selector(_finchChooseCompletion:) keyEquivalent:@""];
        [item setTarget:self];
    }
    NSMenuItem *selected = _selectedCompletion >= 0 && _selectedCompletion < [menu numberOfItems] ? [menu itemAtIndex:_selectedCompletion] : nil;
    [menu popUpMenuPositioningItem:selected atLocation:NSMakePoint(0, NSMaxY([self bounds])) inView:self];
}
- (NSArray *)textView:(NSTextView *)view completions:(NSArray *)words forPartialWordRange:(NSRange)range indexOfSelectedItem:(NSInteger *)selected
{
    NSInteger index = [[[self cell] _finchObjectsFromString:[[view textStorage] attributedSubstringFromRange:NSMakeRange(0, range.location)]] count];
    return [[self cell] _finchCompletions:[[view string] substringWithRange:range] index:index selected:selected] ?: @[];
}
- (BOOL)isAccessibilityElement { return NO; }
- (NSString *)accessibilityRole { return NSAccessibilityUnknownRole; }
- (NSString *)accessibilitySubrole { return nil; }
@end
