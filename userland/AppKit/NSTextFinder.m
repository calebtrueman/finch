/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextFinder: the find bar and its actions, for any NSTextFinderClient,
 * and NSTextView's use of it (-performTextFinderAction:,
 * -performFindPanelAction:). The search string lives on the find pasteboard
 * as on macOS, so it's shared with other text views. Matching ignores case;
 * next and previous wrap around. The bar (Apple's class name,
 * NSTextFinderBarView) is a search field, previous/next buttons and Done,
 * with a replace row when asked for; the scroll view places it (NSScrollView.m).
 */
#import "NSView_Finch.h"
#import <objc/runtime.h>

static const CGFloat kFindRow = 32, kReplaceRow = 28;

@interface NSTextFinderBarView : NSView
@property (assign) NSTextFinder *finder;
@property (retain) NSSearchField *searchField;
@property (retain) NSTextField *replaceField;
@property BOOL showsReplace;
@end

@interface NSTextFinder ()
- (void)_finchSearchFieldChanged:(id)sender;
- (void)_finchPrevNext:(NSSegmentedControl *)sender;
- (void)_finchDone:(id)sender;
- (void)_finchReplace:(id)sender;
- (void)_finchReplaceAll:(id)sender;
@end

@implementation NSTextFinderBarView

- (instancetype)initWithFinder:(NSTextFinder *)finder
{
    self = [super initWithFrame:NSMakeRect(0, 0, 400, kFindRow)];
    if (self) {
        _finder = finder;
        _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, 5, 220, 22)];
        [_searchField setTarget:finder];
        [_searchField setAction:@selector(_finchSearchFieldChanged:)];
        [_searchField setAutoresizingMask:NSViewWidthSizable];
        [self addSubview:_searchField];
        NSSegmentedControl *nav = [NSSegmentedControl segmentedControlWithLabels:@[ @"‹", @"›" ]
                                                                    trackingMode:NSSegmentSwitchTrackingMomentary
                                                                          target:finder
                                                                          action:@selector(_finchPrevNext:)];
        [nav setFrame:NSMakeRect(236, 5, 52, 22)];
        [nav setAutoresizingMask:NSViewMinXMargin];
        [self addSubview:nav];
        NSButton *done = [NSButton buttonWithTitle:@"Done" target:finder action:@selector(_finchDone:)];
        [done setFrame:NSMakeRect(296, 4, 64, 24)];
        [done setAutoresizingMask:NSViewMinXMargin];
        [self addSubview:done];
    }
    return self;
}

- (void)dealloc
{
    [_searchField release];
    [_replaceField release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }

- (void)setShowsReplace:(BOOL)shows
{
    if (shows == _showsReplace)
        return;
    _showsReplace = shows;
    NSRect f = [self frame];
    f.size.height = shows ? kFindRow + kReplaceRow : kFindRow;
    [self setFrame:f];
    if (shows && !_replaceField) {
        _replaceField = [[NSTextField alloc] initWithFrame:NSMakeRect(8, kFindRow, 220, 22)];
        [_replaceField setPlaceholderString:@"Replace"];
        [_replaceField setAutoresizingMask:NSViewWidthSizable];
        [self addSubview:_replaceField];
        NSButton *one = [NSButton buttonWithTitle:@"Replace" target:_finder action:@selector(_finchReplace:)];
        [one setFrame:NSMakeRect(236, kFindRow - 1, 72, 24)];
        [one setTag:1001];
        [self addSubview:one];
        NSButton *all = [NSButton buttonWithTitle:@"All" target:_finder action:@selector(_finchReplaceAll:)];
        [all setFrame:NSMakeRect(312, kFindRow - 1, 48, 24)];
        [all setTag:1002];
        [self addSubview:all];
    }
    for (NSView *v in [self subviews])
        if (v == _replaceField || [v tag] == 1001 || [v tag] == 1002)
            [v setHidden:!shows];
}

- (void)drawRect:(NSRect)dirty
{
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirty);
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(0, NSHeight([self bounds]) - 1, NSWidth([self bounds]), 1));
}

@end

@implementation NSTextFinder {
    id<NSTextFinderClient> _client;                 /* weak */
    id<NSTextFinderBarContainer> _container;        /* weak */
    BOOL _incremental, _dim;
    NSTextFinderBarView *_bar;
}

- (instancetype)init
{
    return [super init];
}

- (instancetype)initWithCoder:(NSCoder *)coder { return [self init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}

- (void)dealloc
{
    [_bar release];
    [super dealloc];
}

- (id<NSTextFinderClient>)client { return _client; }
- (void)setClient:(id<NSTextFinderClient>)c { _client = c; }
- (id<NSTextFinderBarContainer>)findBarContainer { return _container; }
- (void)setFindBarContainer:(id<NSTextFinderBarContainer>)c { _container = c; }
- (BOOL)isIncrementalSearchingEnabled { return _incremental; }
- (void)setIncrementalSearchingEnabled:(BOOL)f { _incremental = f; }
- (BOOL)incrementalSearchingShouldDimContentView { return _dim; }
- (void)setIncrementalSearchingShouldDimContentView:(BOOL)f { _dim = f; }
- (NSArray<NSValue *> *)incrementalMatchRanges { return @[]; }
- (void)cancelFindIndicator {}
- (void)noteClientStringWillChange {}

+ (void)drawIncrementalMatchHighlightInRect:(NSRect)rect
{
    [[NSColor findHighlightColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:3 yRadius:3] fill];
}

#pragma mark The client

- (NSString *)_string
{
    if ([(id)_client respondsToSelector:@selector(string)])
        return [_client string];
    return @"";
}

- (NSRange)_selection
{
    if ([(id)_client respondsToSelector:@selector(firstSelectedRange)])
        return [_client firstSelectedRange];
    if ([(id)_client respondsToSelector:@selector(selectedRanges)])
        return [[[_client selectedRanges] firstObject] rangeValue];
    return NSMakeRange(0, 0);
}

- (void)_select:(NSRange)r
{
    if ([(id)_client respondsToSelector:@selector(setSelectedRanges:)])
        [_client setSelectedRanges:@[ [NSValue valueWithRange:r] ]];
    if ([(id)_client respondsToSelector:@selector(scrollRangeToVisible:)])
        [_client scrollRangeToVisible:r];
}

static NSPasteboard *
find_pasteboard(void)
{
    return [NSPasteboard pasteboardWithName:NSPasteboardNameFind];
}

- (NSString *)_searchString
{
    NSString *field = [[_bar searchField] stringValue];
    if ([field length])
        return field;
    return [find_pasteboard() stringForType:NSPasteboardTypeString] ?: @"";
}

- (void)_setSearchString:(NSString *)s
{
    NSPasteboard *pb = find_pasteboard();
    [pb clearContents];
    [pb setString:s forType:NSPasteboardTypeString];
    [[_bar searchField] setStringValue:s];
}

#pragma mark The bar

- (NSTextFinderBarView *)_finchBar
{
    if (!_bar)
        _bar = [[NSTextFinderBarView alloc] initWithFinder:self];
    return _bar;
}

- (void)_showBar:(BOOL)replace
{
    NSTextFinderBarView *bar = [self _finchBar];
    [bar setShowsReplace:replace];
    NSString *s = [find_pasteboard() stringForType:NSPasteboardTypeString];
    if (s && ![[[bar searchField] stringValue] length])
        [[bar searchField] setStringValue:s];
    [_container setFindBarView:bar];
    [_container setFindBarVisible:YES];
    [_container findBarViewDidChangeHeight];
    [[bar window] makeFirstResponder:[bar searchField]];
}

- (void)_hideBar
{
    [_container setFindBarVisible:NO];
    NSView *content = [_container respondsToSelector:@selector(contentView)] ? [(id)_container contentView] : nil;
    if ([_client isKindOfClass:[NSView class]])
        [[(NSView *)_client window] makeFirstResponder:(NSView *)_client];
    (void)content;
}

#pragma mark Finding

- (BOOL)_findForward:(BOOL)forward
{
    NSString *needle = [self _searchString], *hay = [self _string];
    if (![needle length] || ![hay length])
        return NO;
    NSRange sel = [self _selection];
    NSRange r;
    if (forward) {
        NSUInteger from = MIN(NSMaxRange(sel), [hay length]);
        r = [hay rangeOfString:needle options:NSCaseInsensitiveSearch range:NSMakeRange(from, [hay length] - from)];
        if (r.location == NSNotFound)
            r = [hay rangeOfString:needle options:NSCaseInsensitiveSearch range:NSMakeRange(0, [hay length])];
    } else {
        NSUInteger to = MIN(sel.location, [hay length]);
        r = [hay rangeOfString:needle options:NSCaseInsensitiveSearch | NSBackwardsSearch range:NSMakeRange(0, to)];
        if (r.location == NSNotFound)
            r = [hay rangeOfString:needle options:NSCaseInsensitiveSearch | NSBackwardsSearch
                             range:NSMakeRange(0, [hay length])];
    }
    if (r.location == NSNotFound) {
        NSBeep();
        return NO;
    }
    [self _select:r];
    return YES;
}

- (BOOL)_editable
{
    return ![(id)_client respondsToSelector:@selector(isEditable)] || [_client isEditable];
}

- (void)_replaceRange:(NSRange)r with:(NSString *)with
{
    if ([(id)_client respondsToSelector:@selector(shouldReplaceCharactersInRanges:withStrings:)] &&
        ![_client shouldReplaceCharactersInRanges:@[ [NSValue valueWithRange:r] ] withStrings:@[ with ]])
        return;
    if ([(id)_client respondsToSelector:@selector(replaceCharactersInRange:withString:)])
        [_client replaceCharactersInRange:r withString:with];
    if ([(id)_client respondsToSelector:@selector(didReplaceCharacters)])
        [_client didReplaceCharacters];
}

- (NSUInteger)_replaceAllIn:(NSRange)scope
{
    NSString *needle = [self _searchString], *with = [[_bar replaceField] stringValue] ?: @"";
    if (![needle length] || ![self _editable])
        return 0;
    NSUInteger count = 0;
    NSString *hay = [self _string];
    NSRange r = [hay rangeOfString:needle options:NSCaseInsensitiveSearch | NSBackwardsSearch range:scope];
    while (r.location != NSNotFound) {
        [self _replaceRange:r with:with];
        count++;
        hay = [self _string];
        if (r.location == scope.location)
            break;
        r = [hay rangeOfString:needle options:NSCaseInsensitiveSearch | NSBackwardsSearch
                         range:NSMakeRange(scope.location, r.location - scope.location)];
    }
    return count;
}

- (void)_selectAllIn:(NSRange)scope
{
    NSString *needle = [self _searchString], *hay = [self _string];
    if (![needle length])
        return;
    NSMutableArray *ranges = [NSMutableArray array];
    NSRange r = [hay rangeOfString:needle options:NSCaseInsensitiveSearch range:scope];
    while (r.location != NSNotFound) {
        [ranges addObject:[NSValue valueWithRange:r]];
        NSUInteger from = NSMaxRange(r);
        if (from >= NSMaxRange(scope))
            break;
        r = [hay rangeOfString:needle options:NSCaseInsensitiveSearch range:NSMakeRange(from, NSMaxRange(scope) - from)];
    }
    if ([ranges count] && [(id)_client respondsToSelector:@selector(setSelectedRanges:)])
        [_client setSelectedRanges:ranges];
}

- (void)performAction:(NSTextFinderAction)op
{
    NSString *string = [self _string];
    switch (op) {
    case NSTextFinderActionShowFindInterface: [self _showBar:[_bar showsReplace]]; break;
    case NSTextFinderActionShowReplaceInterface: [self _showBar:YES]; break;
    case NSTextFinderActionHideReplaceInterface: [[self _finchBar] setShowsReplace:NO]; [_container findBarViewDidChangeHeight]; break;
    case NSTextFinderActionHideFindInterface: [self _hideBar]; break;
    case NSTextFinderActionNextMatch: [self _findForward:YES]; break;
    case NSTextFinderActionPreviousMatch: [self _findForward:NO]; break;
    case NSTextFinderActionSetSearchString: {
        NSRange sel = [self _selection];
        if (sel.length && NSMaxRange(sel) <= [string length])
            [self _setSearchString:[string substringWithRange:sel]];
        break;
    }
    case NSTextFinderActionReplace:
    case NSTextFinderActionReplaceAndFind: {
        NSRange sel = [self _selection];
        if (sel.length && [self _editable] && NSMaxRange(sel) <= [string length] &&
            [[string substringWithRange:sel] compare:[self _searchString] options:NSCaseInsensitiveSearch] == NSOrderedSame)
            [self _replaceRange:sel with:[[_bar replaceField] stringValue] ?: @""];
        if (op == NSTextFinderActionReplaceAndFind)
            [self _findForward:YES];
        break;
    }
    case NSTextFinderActionReplaceAll: [self _replaceAllIn:NSMakeRange(0, [string length])]; break;
    case NSTextFinderActionReplaceAllInSelection: [self _replaceAllIn:[self _selection]]; break;
    case NSTextFinderActionSelectAll: [self _selectAllIn:NSMakeRange(0, [string length])]; break;
    case NSTextFinderActionSelectAllInSelection: [self _selectAllIn:[self _selection]]; break;
    default: break;
    }
}

/* As Apple's: every action is offered. */
- (BOOL)validateAction:(NSTextFinderAction)op { return op >= 1 && op <= 13; }

#pragma mark The bar's controls

- (void)_finchSearchFieldChanged:(id)sender
{
    NSString *s = [sender stringValue];
    NSPasteboard *pb = find_pasteboard();
    [pb clearContents];
    [pb setString:s forType:NSPasteboardTypeString];
    if ([s length])
        [self _findForward:YES];
}

- (void)_finchPrevNext:(NSSegmentedControl *)sender
{
    [self _findForward:[sender selectedSegment] == 1];
}

- (void)_finchDone:(id)sender { [self _hideBar]; }
- (void)_finchReplace:(id)sender { [self performAction:NSTextFinderActionReplaceAndFind]; }
- (void)_finchReplaceAll:(id)sender { [self performAction:NSTextFinderActionReplaceAll]; }

@end

#pragma mark - NSTextView

@implementation NSTextView (FinchTextFinder)

static const void *kFinder = &kFinder;

- (NSTextFinder *)_finchTextFinder
{
    NSTextFinder *f = objc_getAssociatedObject(self, kFinder);
    if (!f) {
        f = [[[NSTextFinder alloc] init] autorelease];
        [f setClient:(id<NSTextFinderClient>)self];
        objc_setAssociatedObject(self, kFinder, f, OBJC_ASSOCIATION_RETAIN);
    }
    [f setFindBarContainer:[self enclosingScrollView]];
    return f;
}

- (IBAction)performTextFinderAction:(id)sender
{
    [[self _finchTextFinder] performAction:(NSTextFinderAction)[sender tag]];
}

/* The older find panel actions have the same numbers as the text finder's. */
- (IBAction)performFindPanelAction:(id)sender
{
    [[self _finchTextFinder] performAction:(NSTextFinderAction)[sender tag]];
}

- (NSRange)firstSelectedRange { return [self selectedRange]; }

- (NSArray<NSValue *> *)visibleCharacterRanges
{
    return @[ [NSValue valueWithRange:NSMakeRange(0, [[self string] length])] ];
}

- (void)didReplaceCharacters {}

- (BOOL)shouldReplaceCharactersInRanges:(NSArray<NSValue *> *)ranges withStrings:(NSArray<NSString *> *)strings
{
    return [self shouldChangeTextInRanges:ranges replacementStrings:strings];
}

@end
