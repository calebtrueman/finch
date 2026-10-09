/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSControl_Finch.h"
#import "NSKeyValueBinding_Finch.h"

@interface NSTextField (FinchSearchEditing)
- (void)textDidChange:(NSNotification *)note;
- (void)textDidEndEditing:(NSNotification *)note;
@end

@implementation NSSearchField {
    NSTimer *_searchTimer;
    NSButton *_searchHost, *_cancelHost;
    BOOL _searching, _ending, _continuedAfterReturn, _changedSinceReturn;
}

+ (Class)cellClass
{
    Class c = [super cellClass];
    return c == [NSTextFieldCell class] ? [NSSearchFieldCell class] : c;
}
- (instancetype)initWithFrame:(NSRect)r
{
    if (!(self = [super initWithFrame:r])) return nil;
    [self setAutomaticTextCompletionEnabled:NO];
    _searchHost = [[NSButton alloc] initWithFrame:NSZeroRect];
    _cancelHost = [[NSButton alloc] initWithFrame:NSZeroRect];
    [_searchHost setCell:[[self cell] searchButtonCell]];
    [_cancelHost setCell:[[self cell] cancelButtonCell]];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder])) return nil;
    [[[self cell] searchButtonCell] setControlView:self];
    [[[self cell] cancelButtonCell] setControlView:self];
    [self setAutomaticTextCompletionEnabled:NO];
    return self;
}
- (void)dealloc
{
    [_searchTimer invalidate]; [_searchTimer release];
    [_searchHost release]; [_cancelHost release]; [super dealloc];
}
- (NSArray *)recentSearches { return [[self cell] recentSearches]; }
- (void)setRecentSearches:(NSArray *)a { [[self cell] setRecentSearches:a]; }
- (NSString *)recentsAutosaveName { return [[self cell] recentsAutosaveName]; }
- (void)setRecentsAutosaveName:(NSString *)s { [[self cell] setRecentsAutosaveName:s]; }
- (NSInteger)maximumRecents { return [[self cell] maximumRecents]; }
- (void)setMaximumRecents:(NSInteger)n { [[self cell] setMaximumRecents:n]; }
- (NSMenu *)searchMenuTemplate { return [[self cell] searchMenuTemplate]; }
- (void)setSearchMenuTemplate:(NSMenu *)m { [[self cell] setSearchMenuTemplate:m]; }
- (BOOL)sendsWholeSearchString { return [[self cell] sendsWholeSearchString]; }
- (void)setSendsWholeSearchString:(BOOL)b { [[self cell] setSendsWholeSearchString:b]; }
- (BOOL)sendsSearchStringImmediately { return [[self cell] sendsSearchStringImmediately]; }
- (void)setSendsSearchStringImmediately:(BOOL)b { [[self cell] setSendsSearchStringImmediately:b]; }
- (BOOL)centersPlaceholder { return NO; }
- (void)setCentersPlaceholder:(BOOL)b {}
- (NSRect)searchTextBounds { return [[self cell] searchTextRectForBounds:[self bounds]]; }
- (NSRect)searchButtonBounds { return [[self cell] searchButtonRectForBounds:[self bounds]]; }
- (NSRect)cancelButtonBounds { return [[self cell] cancelButtonRectForBounds:[self bounds]]; }
- (NSRect)rectForSearchTextWhenCentered:(BOOL)b { return [self searchTextBounds]; }
- (NSRect)rectForSearchButtonWhenCentered:(BOOL)b { return [self searchButtonBounds]; }
- (NSRect)rectForCancelButtonWhenCentered:(BOOL)b { return [self cancelButtonBounds]; }
- (void)_finchSearchState
{
    BOOL searching = [[self stringValue] length] > 0;
    if (_searching == searching) return;
    _searching = searching;
    id d = [self delegate];
    if (searching && [d respondsToSelector:@selector(searchFieldDidStartSearching:)]) [d searchFieldDidStartSearching:self];
    if (!searching && [d respondsToSelector:@selector(searchFieldDidEndSearching:)]) [d searchFieldDidEndSearching:self];
}
- (void)_finchRememberSearch
{
    NSString *s = [self stringValue];
    if (![s length]) return;
    NSMutableArray *a = [[[self recentSearches] mutableCopy] autorelease];
    [a removeObject:s]; [a insertObject:s atIndex:0]; [self setRecentSearches:a];
    FinchBindingPush(self, @"recentSearches", [self recentSearches]);
}
- (void)_finchSearch:(BOOL)remember
{
    [_searchTimer invalidate]; [_searchTimer release]; _searchTimer = nil;
    [self validateEditing]; [self _finchSearchState];
    if (remember) [self _finchRememberSearch];
    [self sendAction:[self action] to:[self target]];
}
- (void)_finchCancelSearch
{
    [[self currentEditor] setString:@""];
    [[self cell] setStringValue:@""]; [self setNeedsDisplay:YES];
    [self _finchSearch:NO];
}
- (void)_finchSearchTimer:(NSTimer *)timer { [self _finchSearch:NO]; }
- (void)performClick:(id)sender { if ([self isEnabled]) [self _finchSearch:YES]; }
- (BOOL)sendAction:(SEL)action to:(id)target
{
    if (_ending) { [self _finchSearchState]; [self _finchRememberSearch]; }
    return [super sendAction:action to:target];
}
- (void)textDidChange:(NSNotification *)note
{
    _changedSinceReturn = YES;
    [_searchTimer invalidate]; [_searchTimer release]; _searchTimer = nil;
    if (![[[note object] string] length]) [self _finchSearch:NO];
    else if (![self sendsWholeSearchString])
        _searchTimer = [[NSTimer scheduledTimerWithTimeInterval:[self sendsSearchStringImmediately] ? 0 : 0.25
                                                       target:self selector:@selector(_finchSearchTimer:) userInfo:nil repeats:NO] retain];
    [super textDidChange:note];
}
- (void)textDidEndEditing:(NSNotification *)note
{
    [_searchTimer invalidate]; [_searchTimer release]; _searchTimer = nil;
    BOOL returned = [[[note userInfo] objectForKey:@"NSTextMovement"] integerValue] == NSTextMovementReturn;
    if (_continuedAfterReturn && !_changedSinceReturn && !returned && [self currentEditor]) {
        NSNotification *ended = [NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:self
                                                            userInfo:@{@"NSFieldEditor": [self currentEditor]}];
        if ([[self delegate] respondsToSelector:@selector(controlTextDidEndEditing:)]) [[self delegate] controlTextDidEndEditing:ended];
        [[NSNotificationCenter defaultCenter] postNotification:ended];
    }
    _ending = YES; [super textDidEndEditing:note]; _ending = NO;
    _continuedAfterReturn = returned; _changedSinceReturn = NO;
    if (returned) [(id)[self currentEditor] _finchContinueSearchEditing];
}
- (void)_finchChooseRecent:(NSMenuItem *)item { [self setStringValue:[item title]]; [self _finchSearch:YES]; }
- (void)_finchClearRecents:(id)sender { [self setRecentSearches:@[]]; }
- (void)_finchShowRecents:(NSEvent *)event
{
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Search"] autorelease];
    BOOL haveRecents = [[self recentSearches] count] > 0;
    for (NSMenuItem *source in [[self searchMenuTemplate] itemArray]) {
        NSInteger tag = [source tag];
        if (tag == NSSearchFieldRecentsMenuItemTag) {
            for (NSString *s in [self recentSearches]) {
                NSMenuItem *item = [menu addItemWithTitle:s action:@selector(_finchChooseRecent:) keyEquivalent:@""];
                [item setTarget:self];
            }
        } else {
            if ((!haveRecents && (tag == NSSearchFieldRecentsTitleMenuItemTag || tag == NSSearchFieldClearRecentsMenuItemTag)) ||
                (haveRecents && tag == NSSearchFieldNoRecentsMenuItemTag)) continue;
            NSMenuItem *item = [[source copy] autorelease];
            if (tag == NSSearchFieldClearRecentsMenuItemTag) { [item setTarget:self]; [item setAction:@selector(_finchClearRecents:)]; }
            [menu addItem:item];
        }
    }
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}
- (void)mouseDown:(NSEvent *)event
{
    if (![self isEnabled]) return;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    if (NSPointInRect(p, NSInsetRect([self cancelButtonBounds], -2, -4)) && [[self stringValue] length]) [self _finchCancelSearch];
    else if (NSPointInRect(p, NSInsetRect([self searchButtonBounds], -2, -4))) {
        if ([self searchMenuTemplate]) [self _finchShowRecents:event]; else [self _finchSearch:YES];
    } else [super mouseDown:event];
}
+ (NSArray *)_finchBuiltinBindings { return [[super _finchBuiltinBindings] arrayByAddingObject:@"recentSearches"]; }
- (void)_finchWillSendAction { FinchBindingPush(self, NSValueBinding, [self objectValue]); }
- (BOOL)isAccessibilityElement { return NO; }
- (NSString *)accessibilityRole { return NSAccessibilityUnknownRole; }
- (NSString *)accessibilitySubrole { return nil; }
@end
