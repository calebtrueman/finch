/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "NSControl_Finch.h"

@implementation NSSearchToolbarItem {
    NSSearchField *_searchField;
    CGFloat _preferredWidth;
    BOOL _resignsWithCancel;
}
- (instancetype)initWithItemIdentifier:(NSToolbarItemIdentifier)identifier
{
    if (!(self = [super initWithItemIdentifier:identifier])) return nil;
    _preferredWidth = 240; _resignsWithCancel = YES;
    [self setLabel:@"Search"]; [self setVisibilityPriority:1001];
    [self setMinSize:NSMakeSize(33, 24)]; [self setMaxSize:NSMakeSize(325, 24)];
    NSView *container = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)] autorelease];
    [super setView:container];
    [self setSearchField:[[[NSSearchField alloc] initWithFrame:[container bounds]] autorelease]];
    return self;
}
- (void)dealloc { [_searchField release]; [super dealloc]; }
- (NSSearchField *)searchField { return _searchField; }
- (void)setSearchField:(NSSearchField *)field
{
    if (_searchField == field) return;
    [_searchField removeFromSuperview]; [field retain]; [_searchField release]; _searchField = field;
    [_searchField setFrame:[[self view] bounds]];
    [_searchField setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [[self view] addSubview:_searchField];
}
- (CGFloat)preferredWidthForSearchField { return _preferredWidth; }
- (void)setPreferredWidthForSearchField:(CGFloat)width
{
    _preferredWidth = width;
    [[self view] setFrameSize:NSMakeSize(width, [[self view] frame].size.height)];
}
- (BOOL)resignsFirstResponderWithCancel { return _resignsWithCancel; }
- (void)setResignsFirstResponderWithCancel:(BOOL)b { _resignsWithCancel = b; }
- (void)beginSearchInteraction { [[_searchField window] makeFirstResponder:_searchField]; }
- (void)endSearchInteraction { if (_resignsWithCancel) [[_searchField window] makeFirstResponder:nil]; }
@end
