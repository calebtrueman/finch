/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Search fields use their own buttons and keep a bounded list of past searches. */
#import "NSControl_Finch.h"

@interface NSSearchField (FinchSearch)
- (void)_finchSearch:(BOOL)remember;
- (void)_finchCancelSearch;
@end

@implementation NSSearchFieldCell {
    NSButtonCell *_searchButton, *_cancelButton;
    NSMenu *_searchMenu;
    NSArray *_recents;
    NSString *_autosave;
    NSInteger _maximumRecents;
    BOOL _whole, _immediate;
}

- (instancetype)initTextCell:(NSString *)string
{
    if (!(self = [super initTextCell:string])) return nil;
    _maximumRecents = -1;
    _recents = [@[] retain];
    [self setBezeled:YES];
    [self setEditable:YES];
    [self setSelectable:YES];
    [self setBezelStyle:NSTextFieldRoundedBezel];
    [self setLineBreakMode:NSLineBreakByClipping];
    [self setUsesSingleLineMode:YES];
    [self resetSearchButtonCell];
    [self resetCancelButtonCell];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder])) return nil;
    _maximumRecents = [coder containsValueForKey:@"NSMaximumRecents"] ? [coder decodeIntegerForKey:@"NSMaximumRecents"] : -1;
    _recents = [[coder decodeObjectForKey:@"NSRecentSearches"] copy] ?: [@[] retain];
    _autosave = [[coder decodeObjectForKey:@"NSRecentsAutosaveName"] copy];
    _searchMenu = [[coder decodeObjectForKey:@"NSSearchMenuTemplate"] retain];
    _whole = [coder decodeBoolForKey:@"NSSendsWholeSearchString"];
    _immediate = [coder decodeBoolForKey:@"NSSendsSearchStringImmediately"];
    NSData *flags = [coder decodeObjectForKey:@"NSSearchFieldFlags"];
    if ([flags isKindOfClass:[NSData class]] && [flags length])
        _immediate = (((const uint8_t *)[flags bytes])[0] & 8) != 0;
    _searchButton = [[coder decodeObjectForKey:@"NSSearchButtonCell"] retain];
    _cancelButton = [[coder decodeObjectForKey:@"NSCancelButtonCell"] retain];
    if (!_searchButton) [self resetSearchButtonCell];
    if (!_cancelButton) [self resetCancelButtonCell];
    [_searchButton setTarget:self]; [_searchButton setAction:@selector(_searchFieldSearch:)];
    [_cancelButton setTarget:self]; [_cancelButton setAction:@selector(_searchFieldCancel:)];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeInteger:_maximumRecents forKey:@"NSMaximumRecents"];
    [coder encodeObject:_autosave forKey:@"NSRecentsAutosaveName"];
    [coder encodeObject:_recents forKey:@"NSRecentSearches"];
    [coder encodeObject:_searchMenu forKey:@"NSSearchMenuTemplate"];
    [coder encodeBool:_whole forKey:@"NSSendsWholeSearchString"];
    [coder encodeBool:_immediate forKey:@"NSSendsSearchStringImmediately"];
    [coder encodeObject:_searchButton forKey:@"NSSearchButtonCell"];
    [coder encodeObject:_cancelButton forKey:@"NSCancelButtonCell"];
}

- (void)dealloc
{
    [_searchButton release]; [_cancelButton release]; [_searchMenu release];
    [_recents release]; [_autosave release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSSearchFieldCell *c = [super copyWithZone:zone];
    c->_searchButton = [_searchButton copy]; c->_cancelButton = [_cancelButton copy];
    [c->_searchButton setTarget:c]; [c->_cancelButton setTarget:c];
    [c->_searchMenu retain]; [c->_recents retain]; [c->_autosave retain];
    return c;
}

static NSButtonCell *search_button(id target, BOOL cancel)
{
    NSButtonCell *b = [[[NSButtonCell alloc] initTextCell:cancel ? @"" : @"search"] autorelease];
    [b setTarget:target];
    [b setAction:cancel ? @selector(_searchFieldCancel:) : @selector(_searchFieldSearch:)];
    [b setBordered:NO]; [b setBezelStyle:0]; [b setImagePosition:NSImageOnly];
    [b setImageScaling:NSImageScaleNone];
    [b setHighlightsBy:NSContentsCellMask]; [b setShowsStateBy:0];
    [b setImage:[NSImage imageWithSize:NSMakeSize(15, 9) flipped:YES drawingHandler:^BOOL(NSRect r) {
        [[NSColor secondaryLabelColor] setStroke];
        NSBezierPath *p = [NSBezierPath bezierPath]; [p setLineWidth:1.4];
        if (cancel) {
            [p moveToPoint:NSMakePoint(4, 1)]; [p lineToPoint:NSMakePoint(11, 8)];
            [p moveToPoint:NSMakePoint(11, 1)]; [p lineToPoint:NSMakePoint(4, 8)];
        } else {
            [p appendBezierPathWithOvalInRect:NSMakeRect(2, 0.5, 6, 6)];
            [p moveToPoint:NSMakePoint(7, 6)]; [p lineToPoint:NSMakePoint(10.5, 9)];
        }
        [p stroke]; return YES;
    }]];
    return b;
}

- (NSButtonCell *)searchButtonCell { return _searchButton; }
- (void)setSearchButtonCell:(NSButtonCell *)b { [b retain]; [_searchButton release]; _searchButton = b; [self _finchChanged]; }
- (NSButtonCell *)cancelButtonCell { return _cancelButton; }
- (void)setCancelButtonCell:(NSButtonCell *)b { [b retain]; [_cancelButton release]; _cancelButton = b; [self _finchChanged]; }
- (void)resetSearchButtonCell { [self setSearchButtonCell:search_button(self, NO)]; }
- (void)resetCancelButtonCell { [self setCancelButtonCell:search_button(self, YES)]; }
- (NSMenu *)searchMenuTemplate { return _searchMenu; }
- (void)setSearchMenuTemplate:(NSMenu *)m { [m retain]; [_searchMenu release]; _searchMenu = m; }
- (BOOL)sendsWholeSearchString { return _whole; }
- (void)setSendsWholeSearchString:(BOOL)b { _whole = b; }
- (BOOL)sendsSearchStringImmediately { return _immediate; }
- (void)setSendsSearchStringImmediately:(BOOL)b { _immediate = b; }
- (NSInteger)maximumRecents { return _maximumRecents; }
- (void)setMaximumRecents:(NSInteger)n { _maximumRecents = n < 0 ? -1 : MIN(n, 254); [self setRecentSearches:_recents]; }
- (NSArray *)recentSearches { return _recents; }
- (void)setRecentSearches:(NSArray *)a
{
    NSUInteger limit = _maximumRecents < 0 ? 10 : (NSUInteger)_maximumRecents;
    NSArray *copy = [([a count] > limit ? [a subarrayWithRange:NSMakeRange(0, limit)] : a ?: @[]) copy];
    [_recents release]; _recents = copy;
    if ([_autosave length]) [[NSUserDefaults standardUserDefaults] setObject:_recents forKey:[@"NSSearchFieldRecents " stringByAppendingString:_autosave]];
}
- (NSString *)recentsAutosaveName { return _autosave; }
- (void)setRecentsAutosaveName:(NSString *)s
{
    NSString *copy = [s copy]; [_autosave release]; _autosave = copy;
    if ([_autosave length]) {
        id saved = [[NSUserDefaults standardUserDefaults] objectForKey:[@"NSSearchFieldRecents " stringByAppendingString:_autosave]];
        if ([saved isKindOfClass:[NSArray class]]) [self setRecentSearches:saved];
    }
}
- (void)_searchFieldSearch:(id)sender { [(NSSearchField *)[self controlView] _finchSearch:YES]; }
- (void)_searchFieldCancel:(id)sender { [(NSSearchField *)[self controlView] _finchCancelSearch]; }

/*
 * Geometry as measured on macOS 26 (appkit-controls2-test): a bezeled field puts the search
 * button (its image's width, 15 points on a 2x main screen and 16 on a 1x one, 9 high) and
 * the cancel button (15 by 9) at fixed insets per control size, centred on the line the text
 * sits on; the text fills what is between them, at least 4 wide; a field too narrow for that
 * moves the buttons outward by the shortfall, the larger half on the left. Without a bezel
 * the buttons are the older 25- and 22-point wide full-height ones.
 */
static CGFloat
search_button_width(void)
{
    NSScreen *s = [NSScreen mainScreen];
    return s && [s backingScaleFactor] <= 1 ? 16 : 15;
}

typedef struct {
    NSRect text, search, cancel;
} SearchLayout;

static SearchLayout
search_layout(NSSearchFieldCell *self, NSRect r, BOOL hasSearch, BOOL hasCancel)
{
    SearchLayout l;
    CGFloat w = r.size.width, h = r.size.height;
    if (![self isBezeled]) {
        CGFloat ty = [self isBordered] ? 3 : 0, th = [self isBordered] ? h - 5 : h;
        CGFloat x = hasSearch ? 26 : 4, right = hasCancel ? 24 : 4;
        l.search = NSMakeRect(2, 0, 25, h);
        l.cancel = NSMakeRect(w - 26, 0, 22, h);
        l.text = NSMakeRect(x, ty, MAX(0, w - x - right), th);
    } else {
        NSControlSize s = [self controlSize];
        CGFloat bw = search_button_width();
        CGFloat sx = s == NSControlSizeLarge ? 8 : s == NSControlSizeRegular ? 6 : 4;
        CGFloat x = s == NSControlSizeLarge ? 26 : s == NSControlSizeRegular ? 22 : 3 + bw;
        CGFloat right = s == NSControlSizeLarge ? 27 : s == NSControlSizeRegular ? 25 : s == NSControlSizeSmall ? 23 : 22;
        CGFloat cright = s == NSControlSizeLarge ? 21 : s == NSControlSizeRegular ? 19 : s == NSControlSizeSmall ? 17 : 16;
        CGFloat dy = s == NSControlSizeSmall ? -1 : s == NSControlSizeMini ? -2 : 0;
        CGFloat th = s == NSControlSizeLarge ? 20 : s == NSControlSizeMini ? 12 : 16;
        NSFont *f = [self font];
        if (f && s != NSControlSizeMini) {
            /* a larger font takes a taller line, up to 20 */
            CGFloat lh = round([f ascender] - [f descender] + [f leading]);
            th = MAX(th, MIN(lh, 20));
        }
        if (!hasSearch)
            x = 4;
        if (!hasCancel)
            right = 10;
        CGFloat by = floor((h - 8) / 2) + dy;
        CGFloat tw = w - x - right, left = 0, rightShift = 0;
        if (tw < 4) {
            CGFloat d = 4 - tw;
            left = ceil(d / 2);
            rightShift = d - left;
            tw = 4;
        }
        l.text = NSMakeRect(x - left, ceil((h - 16) / 2) + dy, tw, th);
        l.search = NSMakeRect(left > 0 ? l.text.origin.x - bw : sx, by, bw, 9);
        l.cancel = NSMakeRect(w - cright + rightShift, by, 15, 9);
    }
    l.text.origin.x += r.origin.x, l.text.origin.y += r.origin.y;
    l.search.origin.x += r.origin.x, l.search.origin.y += r.origin.y;
    l.cancel.origin.x += r.origin.x, l.cancel.origin.y += r.origin.y;
    return l;
}

- (NSRect)searchTextRectForBounds:(NSRect)r
{
    return search_layout(self, r, _searchButton != nil, _cancelButton != nil).text;
}

- (NSRect)searchButtonRectForBounds:(NSRect)r
{
    if (!_searchButton) return NSZeroRect;
    return search_layout(self, r, YES, _cancelButton != nil).search;
}

- (NSRect)cancelButtonRectForBounds:(NSRect)r
{
    if (!_cancelButton) return NSZeroRect;
    return search_layout(self, r, _searchButton != nil, YES).cancel;
}
- (NSRect)drawingRectForBounds:(NSRect)r { return [self searchTextRectForBounds:r]; }
- (NSRect)titleRectForBounds:(NSRect)r { return [self searchTextRectForBounds:r]; }
- (NSSize)cellSizeForBounds:(NSRect)r
{
    NSSize size = [super cellSizeForBounds:r];
    size.width += 35;
    size.height = [self controlSize] == NSControlSizeLarge ? 28 : [self controlSize] == NSControlSizeSmall ? 20 : [self controlSize] == NSControlSizeMini ? 16 : 24;
    return size;
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    [super drawWithFrame:frame inView:view];
    [_searchButton drawWithFrame:[self searchButtonRectForBounds:frame] inView:view];
    if ([[self stringValue] length]) [_cancelButton drawWithFrame:[self cancelButtonRectForBounds:frame] inView:view];
}
@end
