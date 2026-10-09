/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSPopUpButtonCell: the cell of a pop-up or pull-down button, holding its
 * menu. Behaviour measured against Apple's (finch-appkit-menu-test):
 *
 * - Items made by the cell send _popUpItemAction: to it; choosing one
 *   selects it and sends the control's action.
 * - Pop-ups: the first item added is selected; the selected item is the
 *   one shown (and is "on" while altersStateOfSelectedItem); removing it
 *   selects the first item; -setTitle: selects the item with that title,
 *   adding one if there is none; adding a title already there moves it to
 *   the end.
 * - Pull-downs: the first item is the button's title and is hidden in the
 *   menu; selecting doesn't change it or any item's state; -setTitle:
 *   renames it.
 * - Nib keys: NSMenu, NSMenuItem (the selected item), NSPullDown,
 *   NSPreferredEdge, NSUsesItemFromMenu, NSAltersState, NSArrowPosition.
 *
 * Drawing and the pop-up itself are Finch's own: a rounded bezel with the
 * title and chevrons, and the menu opened over the button (pop-up, the
 * selected item over the title) or under it (pull-down).
 */
#import "NSMenu_Finch.h"
#import "NSControl_Finch.h"

NSNotificationName NSPopUpButtonCellWillPopUpNotification = @"NSPopUpButtonCellWillPopUpNotification";
NSNotificationName NSPopUpButtonWillPopUpNotification = @"NSPopUpButtonWillPopUpNotification";

@implementation NSPopUpButtonCell {
    NSMenu *_menu;
    NSMenuItem *_selected;  /* retained */
    NSMenuItem *_shown;     /* the item the button shows (-menuItem; not retained, it is in the menu) */
    NSRectEdge _edge;
    NSPopUpArrowPosition _arrow;
    struct {
        unsigned pullsDown : 1;
        unsigned notUsesItem : 1;
        unsigned notAlters : 1;
    } _p;
}

+ (BOOL)prefersTrackingUntilMouseUp { return YES; }

- (instancetype)init
{
    return [self initTextCell:@"" pullsDown:NO];
}

- (instancetype)initTextCell:(NSString *)string
{
    return [self initTextCell:string pullsDown:NO];
}

- (instancetype)initTextCell:(NSString *)string pullsDown:(BOOL)pullDown
{
    self = [super initTextCell:@""];
    if (!self)
        return nil;
    [self setBordered:YES];
    [self setBezelStyle:NSBezelStylePush];
    _menu = [[NSMenu alloc] initWithTitle:@""];
    _edge = NSRectEdgeMinY;
    _arrow = NSPopUpArrowAtBottom;
    _p.pullsDown = pullDown;
    if ([string length])
        [self addItemWithTitle:string];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    NSMenu *menu = [coder decodeObjectForKey:@"NSMenu"];
    _menu = [[menu isKindOfClass:[NSMenu class]] ? menu : [[[NSMenu alloc] initWithTitle:@""] autorelease] retain];
    _p.pullsDown = [coder decodeBoolForKey:@"NSPullDown"];
    _edge = (NSRectEdge)[coder decodeIntegerForKey:@"NSPreferredEdge"];
    _arrow = [coder containsValueForKey:@"NSArrowPosition"]
                 ? (NSPopUpArrowPosition)[coder decodeIntegerForKey:@"NSArrowPosition"]
                 : NSPopUpArrowAtBottom;
    _p.notUsesItem = [coder containsValueForKey:@"NSUsesItemFromMenu"] && ![coder decodeBoolForKey:@"NSUsesItemFromMenu"];
    _p.notAlters = [coder containsValueForKey:@"NSAltersState"] && ![coder decodeBoolForKey:@"NSAltersState"];
    NSMenuItem *selected = [coder decodeObjectForKey:@"NSMenuItem"];
    if ([selected isKindOfClass:[NSMenuItem class]] && [_menu indexOfItem:selected] >= 0)
        _selected = [selected retain];
    else if ([coder containsValueForKey:@"NSSelectedIndex"]) {
        NSInteger i = [coder decodeIntegerForKey:@"NSSelectedIndex"];
        if (i >= 0 && i < [_menu numberOfItems])
            _selected = [[_menu itemAtIndex:i] retain];
    }
    _shown = _selected;
    if (_p.pullsDown && !_shown && [_menu numberOfItems])
        _shown = [_menu itemAtIndex:0];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_menu forKey:@"NSMenu"];
    if ([self menuItem])
        [coder encodeObject:[self menuItem] forKey:@"NSMenuItem"];
    [coder encodeInteger:[self indexOfSelectedItem] forKey:@"NSSelectedIndex"];
    if (_p.pullsDown)
        [coder encodeBool:YES forKey:@"NSPullDown"];
    [coder encodeInteger:(NSInteger)_edge forKey:@"NSPreferredEdge"];
    [coder encodeBool:!_p.notUsesItem forKey:@"NSUsesItemFromMenu"];
    [coder encodeBool:!_p.notAlters forKey:@"NSAltersState"];
    [coder encodeInteger:(NSInteger)_arrow forKey:@"NSArrowPosition"];
}

- (void)dealloc
{
    [_menu release];
    [_selected release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSPopUpButtonCell *c = [super copyWithZone:zone];
    NSInteger i = [self indexOfSelectedItem];
    c->_menu = [_menu copy];
    c->_selected = i >= 0 ? [[c->_menu itemAtIndex:i] retain] : nil;
    for (NSMenuItem *item in [c->_menu itemArray])
        if ([item target] == self)
            [item setTarget:c];
    return c;
}

#pragma mark - Properties

- (NSMenu *)menu { return _menu; }

- (void)setMenu:(NSMenu *)menu
{
    if (menu == _menu)
        return;
    [_menu release];
    _menu = [menu retain];
    _shown = nil;
    [_selected release];
    _selected = nil;
    if (!_p.pullsDown && [_menu numberOfItems])
        [self selectItemAtIndex:0];
    else if ([_menu numberOfItems])
        _shown = [_menu itemAtIndex:0];
    [self _finchChanged];
}

- (BOOL)pullsDown { return _p.pullsDown; }

- (void)setPullsDown:(BOOL)flag
{
    _p.pullsDown = flag;
    if ([_menu numberOfItems])
        [[_menu itemAtIndex:0] setHidden:flag];
    if (flag)
        _shown = [_menu numberOfItems] ? [_menu itemAtIndex:0] : nil;
    [self _finchChanged];
}

- (BOOL)autoenablesItems { return [_menu autoenablesItems]; }
- (void)setAutoenablesItems:(BOOL)flag { [_menu setAutoenablesItems:flag]; }
- (NSRectEdge)preferredEdge { return _edge; }
- (void)setPreferredEdge:(NSRectEdge)edge { _edge = edge; }
- (BOOL)usesItemFromMenu { return !_p.notUsesItem; }
- (void)setUsesItemFromMenu:(BOOL)flag { _p.notUsesItem = !flag; [self _finchChanged]; }
- (BOOL)altersStateOfSelectedItem { return !_p.notAlters; }

- (void)setAltersStateOfSelectedItem:(BOOL)flag
{
    _p.notAlters = !flag;
    if (!_p.pullsDown)
        [_selected setState:flag ? NSControlStateValueOn : NSControlStateValueOff];
}

- (NSPopUpArrowPosition)arrowPosition { return _arrow; }
- (void)setArrowPosition:(NSPopUpArrowPosition)p { _arrow = p; [self _finchChanged]; }

/* The item the button shows: the selected one (pop-up), the first (pull-down). */
- (NSMenuItem *)menuItem
{
    return _shown;
}

- (void)setMenuItem:(NSMenuItem *)item
{
    [self selectItem:item];
}

- (id)objectValue { return @([self indexOfSelectedItem]); }

- (void)setObjectValue:(id)value
{
    if ([value respondsToSelector:@selector(integerValue)])
        [self selectItemAtIndex:[value integerValue]];
}

- (NSInteger)integerValue { return [self indexOfSelectedItem]; }
- (int)intValue { return (int)[self indexOfSelectedItem]; }
- (void)setIntegerValue:(NSInteger)v { [self selectItemAtIndex:v]; }
- (void)setIntValue:(int)v { [self selectItemAtIndex:v]; }

#pragma mark - Items

- (NSMenuItem *)_finchNewItem:(NSString *)title
{
    NSMenuItem *i = [[[NSMenuItem alloc] initWithTitle:title ?: @"" action:@selector(_popUpItemAction:)
                                         keyEquivalent:@""] autorelease];
    [i setTarget:self];
    return i;
}

- (void)_finchAdded:(NSMenuItem *)item
{
    if (_p.pullsDown) {
        if ([_menu indexOfItem:item] == 0) {
            [item setHidden:YES];
            _shown = item;
        }
    } else if (!_selected) {
        [self selectItem:item];
    }
    [self _finchChanged];
}

- (void)addItemWithTitle:(NSString *)title
{
    [self removeItemWithTitle:title];
    NSMenuItem *i = [self _finchNewItem:title];
    [_menu addItem:i];
    [self _finchAdded:i];
}

- (void)addItemsWithTitles:(NSArray<NSString *> *)titles
{
    for (NSString *t in titles)
        [self addItemWithTitle:t];
}

- (void)insertItemWithTitle:(NSString *)title atIndex:(NSInteger)index
{
    [self removeItemWithTitle:title];
    NSMenuItem *i = [self _finchNewItem:title];
    [_menu insertItem:i atIndex:MIN(MAX(index, 0), [_menu numberOfItems])];
    [self _finchAdded:i];
}

- (void)removeItemWithTitle:(NSString *)title
{
    NSInteger i = [_menu indexOfItemWithTitle:title];
    if (i >= 0)
        [self removeItemAtIndex:i];
}

- (void)removeItemAtIndex:(NSInteger)index
{
    if (index < 0 || index >= [_menu numberOfItems])
        return;
    NSMenuItem *item = [_menu itemAtIndex:index];
    BOOL wasSelected = item == _selected;
    if (item == _shown)
        _shown = nil;
    [_menu removeItemAtIndex:index];
    if (wasSelected) {
        [_selected release];
        _selected = nil;
        if (!_p.pullsDown && [_menu numberOfItems])
            [self selectItemAtIndex:0];
    }
    if (_p.pullsDown && !_shown && [_menu numberOfItems])
        _shown = [_menu itemAtIndex:0];
    [self _finchChanged];
}

- (void)removeAllItems
{
    [_menu removeAllItems];
    _shown = nil;
    [_selected release];
    _selected = nil;
    [self _finchChanged];
}

- (NSArray<NSMenuItem *> *)itemArray { return [_menu itemArray]; }
- (NSInteger)numberOfItems { return [_menu numberOfItems]; }
- (NSInteger)indexOfItem:(NSMenuItem *)item { return [_menu indexOfItem:item]; }
- (NSInteger)indexOfItemWithTitle:(NSString *)title { return [_menu indexOfItemWithTitle:title]; }
- (NSInteger)indexOfItemWithTag:(NSInteger)tag { return [_menu indexOfItemWithTag:tag]; }
- (NSInteger)indexOfItemWithRepresentedObject:(id)obj { return [_menu indexOfItemWithRepresentedObject:obj]; }
- (NSInteger)indexOfItemWithTarget:(id)t andAction:(SEL)a { return [_menu indexOfItemWithTarget:t andAction:a]; }

- (NSMenuItem *)itemAtIndex:(NSInteger)index
{
    return index >= 0 && index < [_menu numberOfItems] ? [_menu itemAtIndex:index] : nil;
}

- (NSMenuItem *)itemWithTitle:(NSString *)title { return [_menu itemWithTitle:title]; }
- (NSMenuItem *)lastItem { return [[_menu itemArray] lastObject]; }

- (NSString *)itemTitleAtIndex:(NSInteger)index
{
    return [[self itemAtIndex:index] title] ?: @"";
}

- (NSArray<NSString *> *)itemTitles
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSMenuItem *i in [_menu itemArray])
        [a addObject:[i title]];
    return a;
}

#pragma mark - Selection

- (void)selectItem:(NSMenuItem *)item
{
    if (item && [_menu indexOfItem:item] < 0)
        return;
    if (!_p.pullsDown && !_p.notAlters && _selected != item) {
        [_selected setState:NSControlStateValueOff];
        [item setState:NSControlStateValueOn];
    }
    [item retain];
    [_selected release];
    _selected = item;
    if (!_p.pullsDown)
        _shown = item;
    [self _finchChanged];
}

- (void)selectItemAtIndex:(NSInteger)index
{
    [self selectItem:[self itemAtIndex:index]];
}

- (void)selectItemWithTitle:(NSString *)title
{
    [self selectItem:[_menu itemWithTitle:title]];
}

- (BOOL)selectItemWithTag:(NSInteger)tag
{
    NSInteger i = [_menu indexOfItemWithTag:tag];
    if (i < 0)
        return NO;
    [self selectItemAtIndex:i];
    return YES;
}

- (NSMenuItem *)selectedItem { return _selected; }
- (NSInteger)indexOfSelectedItem { return _selected ? [_menu indexOfItem:_selected] : -1; }
- (NSString *)titleOfSelectedItem { return [_selected title]; }
- (NSInteger)selectedTag { return _selected ? [_selected tag] : -1; }
- (void)synchronizeTitleAndSelectedItem { [self _finchChanged]; }

- (NSString *)title
{
    return [[self menuItem] title] ?: @"";
}

- (void)setTitle:(NSString *)title
{
    if (!title)
        title = @"";
    if (_p.pullsDown) {
        if ([_menu numberOfItems])
            [[_menu itemAtIndex:0] setTitle:title];
        else
            [self addItemWithTitle:title];
    } else {
        NSInteger i = [_menu indexOfItemWithTitle:title];
        if (i < 0) {
            [self addItemWithTitle:title];
            i = [_menu indexOfItemWithTitle:title];
        }
        [self selectItemAtIndex:i];
    }
    [self _finchChanged];
}

- (NSAttributedString *)attributedTitle
{
    return [[[NSAttributedString alloc] initWithString:[self title] attributes:[self _finchTextAttributes]] autorelease];
}

- (void)_popUpItemAction:(id)sender
{
    if ([sender isKindOfClass:[NSMenuItem class]])
        [self selectItem:sender];
    [self _finchSendAction];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    return YES;
}

#pragma mark - Popping up

- (void)attachPopUpWithFrame:(NSRect)frame inView:(NSView *)view
{
    [[NSNotificationCenter defaultCenter] postNotificationName:NSPopUpButtonCellWillPopUpNotification object:self];
    if ([view isKindOfClass:[NSPopUpButton class]])
        [[NSNotificationCenter defaultCenter] postNotificationName:NSPopUpButtonWillPopUpNotification object:view];
    NSWindow *w = [view window];
    NSRect inWindow = [view convertRect:frame toView:nil];
    NSRect r = w ? [w convertRectToScreen:inWindow] : inWindow;
    NSMenuItem *item = _p.pullsDown ? nil : _selected;
    /* The selected item over the title (its row is 22 points); a pull-down's menu under the button. */
    NSPoint p = _p.pullsDown ? NSMakePoint(NSMinX(r), NSMinY(r))
                             : NSMakePoint(NSMinX(r), item ? NSMaxY(r) - floor((r.size.height - 22) / 2) : NSMinY(r));
    FinchMenuPopUp(_menu, item, p, view, [NSApp currentEvent], r.size.width, [self font], YES);
}

- (void)dismissPopUp
{
    [_menu cancelTracking];
}

- (void)performClickWithFrame:(NSRect)frame inView:(NSView *)view
{
    [self attachPopUpWithFrame:frame inView:view];
}

- (BOOL)trackMouse:(NSEvent *)event inRect:(NSRect)frame ofView:(NSView *)view untilMouseUp:(BOOL)untilUp
{
    if (![self isEnabled])
        return NO;
    [self setHighlighted:YES];
    [view setNeedsDisplay:YES];
    [[view window] displayIfNeeded];
    [self attachPopUpWithFrame:frame inView:view];
    [self setHighlighted:NO];
    [view setNeedsDisplay:YES];
    return YES;
}

#pragma mark - Drawing (Finch's look)

- (NSSize)cellSizeForBounds:(NSRect)rect
{
    NSDictionary *a = [self _finchTextAttributes];
    CGFloat w = 0;
    for (NSMenuItem *i in [_menu itemArray])
        w = MAX(w, ceil([[i title] sizeWithAttributes:a].width));
    return NSMakeSize(w + 46, 24);
}

static void
chevron(CGFloat x, CGFloat y, CGFloat dir, NSColor *color)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x - 3, y)];
    [p lineToPoint:NSMakePoint(x, y + 3 * dir)];
    [p lineToPoint:NSMakePoint(x + 3, y)];
    [p setLineWidth:1.5];
    [p setLineCapStyle:NSLineCapStyleRound];
    [p setLineJoinStyle:NSLineJoinStyleRound];
    [color setStroke];
    [p stroke];
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    BOOL enabled = [self _finchDrawsEnabled];
    NSRect body = NSInsetRect(frame, 2, MAX(0, floor((frame.size.height - 21) / 2)));
    if ([self isBordered])
        FinchDrawBezel(body, 5, FinchControlFill([self isHighlighted]), FinchControlStroke());
    [self drawInteriorWithFrame:frame inView:view];
    if (_arrow != NSPopUpNoArrow) {
        BOOL flipped = [view isFlipped];
        CGFloat x = NSMaxX(body) - 11, mid = NSMidY(body), up = flipped ? -1 : 1;
        NSColor *c = FinchDisabled(FinchControlGlyphColor(), enabled);
        if (_p.pullsDown)
            chevron(x, mid + 1.5 * up, -up, c);
        else {
            chevron(x, mid + 1.5 * up, up, c);
            chevron(x, mid - 1.5 * up, -up, c);
        }
    }
}

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view
{
    NSMutableDictionary *a = [[[self _finchTextAttributes] mutableCopy] autorelease];
    a[NSForegroundColorAttributeName] =
        FinchDisabled(FinchControlTextColor(), [self _finchDrawsEnabled]);
    NSAttributedString *t = [[[NSAttributedString alloc] initWithString:[self title] attributes:a] autorelease];
    NSRect tr = NSMakeRect(NSMinX(frame) + 11, NSMinY(frame), MAX(0, frame.size.width - 11 - 24), frame.size.height);
    NSImage *image = [[self menuItem] image];
    if (image) {
        FinchDrawImageInRect(image, NSMakeRect(NSMinX(tr), NSMidY(frame) - 8, 16, 16), NSImageScaleProportionallyDown,
                             NSImageAlignCenter, [view isFlipped], 1);
        tr.origin.x += 20;
        tr.size.width -= 20;
    }
    FinchDrawCellText(t, tr, [view isFlipped]);
}

@end
