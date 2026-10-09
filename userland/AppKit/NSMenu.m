/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSMenu: a list of NSMenuItems, the app's main menu, context and pop-up
 * menus. Finch draws the menu bar and the menus itself (FinchMenuWindow.m);
 * this file is the model: building menus, the notifications, validation,
 * key equivalents, archiving and the menus a nib names for NSApp.
 *
 * What Apple's does, measured with finch-appkit-menu-test:
 *
 * - Validation (-update, when autoenablesItems): separators are left
 *   alone, items with a submenu are enabled, and every other item (hidden
 *   ones too, and those without an action) asks
 *   [NSApp targetForAction:to:from:]; an item is enabled when that target
 *   responds to the action and to -validateMenuItem: (or
 *   -validateUserInterfaceItem:) says YES, or doesn't implement them.
 *   Delegates aren't asked to fill a menu in until it opens.
 * - Key equivalents (-performKeyEquivalent:, key-down events only): first
 *   every delegate in the menu tree that implements
 *   menuHasKeyEquivalent:forEvent:target:action: is asked, depth first;
 *   then each menu in turn asks its delegate again, validates its items and
 *   looks for one whose key equivalent is the event's
 *   charactersIgnoringModifiers, compared exactly, with the same Command,
 *   Option and Control (Shift and the rest don't count), then its
 *   submenus. A matching disabled item is consumed without an action;
 *   hidden items match.
 * - Actions go through [NSApp sendAction:to:from:] between
 *   NSMenuWillSendActionNotification and NSMenuDidSendActionNotification;
 *   disabled items do nothing.
 * - Adding and removing items post NSMenuDidAdd/RemoveItemNotification
 *   (removeAllItems and setItemArray:'s removals don't); item changes post
 *   NSMenuDidChangeItemNotification.
 */
#import "NSMenu_Finch.h"

FINCH_PRIVATE void FinchBindingsMenuItemChosen(NSMenuItem *item);

NSNotificationName NSMenuWillSendActionNotification = @"NSMenuWillSendActionNotification";
NSNotificationName NSMenuDidSendActionNotification = @"NSMenuDidSendActionNotification";
NSNotificationName NSMenuDidAddItemNotification = @"NSMenuDidAddItemNotification";
NSNotificationName NSMenuDidRemoveItemNotification = @"NSMenuDidRemoveItemNotification";
NSNotificationName NSMenuDidChangeItemNotification = @"NSMenuDidChangeItemNotification";
NSNotificationName NSMenuDidBeginTrackingNotification = @"NSMenuDidBeginTrackingNotification";
NSNotificationName NSMenuDidEndTrackingNotification = @"NSMenuDidEndTrackingNotification";

static BOOL menu_bar_visible = YES;

/* Command, Option and Control: what a key equivalent's modifiers are compared on. */
#define KE_COMPARED (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl)

@implementation NSMenu {
    NSString *_title;
    NSMutableArray<NSMenuItem *> *_items;
    NSMenu *_supermenu;       /* not retained */
    NSMenuItem *_parentItem;  /* not retained */
    __weak id<NSMenuDelegate> _delegate;
    NSString *_name;
    NSFont *_font;
    NSMenuItem *_highlighted;  /* not retained */
    NSUserInterfaceItemIdentifier _identifier;
    NSAppearance *_appearance;
    NSArray<NSMenuItem *> *_selectedItems;
    CGFloat _minimumWidth;
    NSUserInterfaceLayoutDirection _direction;
    NSMenuPresentationStyle _presentationStyle;
    NSMenuSelectionMode _selectionMode;
    struct {
        unsigned noAutoenable : 1;
        unsigned noStateColumn : 1;
        unsigned changedMessages : 1;
        unsigned noContextPlugIns : 1;
        unsigned noWritingTools : 1;
    } _m;
}

#pragma mark - Creating

- (instancetype)init
{
    return [self initWithTitle:@""];
}

- (instancetype)initWithTitle:(NSString *)title
{
    self = [super init];
    if (!self)
        return nil;
    _title = [title ?: @"" copy];
    _items = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc
{
    for (NSMenuItem *i in _items)
        if ([i menu] == self)
            [i setMenu:nil];
    [_title release];
    [_items release];
    [_name release];
    [_font release];
    [_identifier release];
    [_appearance release];
    [_selectedItems release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>\n\tTitle: %@\n\tSupermenu: %p (%@), autoenable: %@\n\tItems: %@",
                                      [self class], self, _title, _supermenu, [_supermenu title],
                                      _m.noAutoenable ? @"NO" : @"YES", _items];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSMenu *c = [[[self class] allocWithZone:zone] initWithTitle:_title];
    c->_name = [_name copy];
    c->_font = [_font retain];
    c->_minimumWidth = _minimumWidth;
    c->_direction = _direction;
    c->_m = _m;
    c->_delegate = _delegate;
    for (NSMenuItem *i in _items) {
        NSMenuItem *ci = [i copy];
        [c->_items addObject:ci];
        [ci setMenu:c];
        [ci release];
    }
    return c;
}

#pragma mark - Coding (Apple's keys)

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
        [NSException raise:NSInvalidArgumentException format:@"NSMenu only supports keyed coding"];
    [coder encodeObject:_title forKey:@"NSTitle"];
    [coder encodeObject:_items forKey:@"NSMenuItems"];
    if (_m.noAutoenable)
        [coder encodeBool:YES forKey:@"NSNoAutoenable"];
    if (_minimumWidth != 0)
        [coder encodeDouble:_minimumWidth forKey:@"NSMenuMinimumWidth"];
    if (_m.noStateColumn)
        [coder encodeBool:YES forKey:@"NSMenuExcludeMarkColumn"];
    if (_name)
        [coder encodeObject:_name forKey:@"NSName"];
    if (_identifier)
        [coder encodeObject:_identifier forKey:@"NSUserInterfaceItemIdentifier"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (!self)
        return nil;
    id title = [coder decodeObjectForKey:@"NSTitle"];
    _title = [[title isKindOfClass:[NSString class]] ? title : @"" copy];
    _items = [[NSMutableArray alloc] init];
    _m.noAutoenable = [coder decodeBoolForKey:@"NSNoAutoenable"];
    _m.noStateColumn = [coder decodeBoolForKey:@"NSMenuExcludeMarkColumn"];
    _minimumWidth = [coder decodeDoubleForKey:@"NSMenuMinimumWidth"];
    id name = [coder decodeObjectForKey:@"NSName"];
    if ([name isKindOfClass:[NSString class]])
        _name = [name copy];
    _identifier = [[coder decodeObjectForKey:@"NSUserInterfaceItemIdentifier"] copy];
    for (NSMenuItem *i in [coder decodeObjectForKey:@"NSMenuItems"]) {
        if (![i isKindOfClass:[NSMenuItem class]])
            continue;
        [_items addObject:i];
        [i setMenu:self];
    }
    return self;
}

/* The menus a nib names become NSApp's, as Apple's (whoever owns the nib). */
- (void)awakeFromNib
{
    NSApplication *app = NSApp;
    if (!_name || !app)
        return;
    if ([_name isEqualToString:@"_NSMainMenu"])
        [app setMainMenu:self];
    else if ([_name isEqualToString:@"_NSWindowsMenu"])
        [app setWindowsMenu:self];
    else if ([_name isEqualToString:@"_NSServicesMenu"])
        [app setServicesMenu:self];
    else if ([_name isEqualToString:@"_NSHelpMenu"])
        [app setHelpMenu:self];
}

- (NSString *)_finchName { return _name; }
- (void)_finchSetName:(NSString *)name { [_name autorelease]; _name = [name copy]; }
- (NSMenuItem *)_finchParentItem { return _parentItem; }
- (void)_finchSetParentItem:(NSMenuItem *)item { _parentItem = item; }

#pragma mark - Properties

- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)title { [_title autorelease]; _title = [title ?: @"" copy]; }
- (NSMenu *)supermenu { return _supermenu; }
- (void)setSupermenu:(NSMenu *)supermenu { _supermenu = supermenu; }
- (id<NSMenuDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSMenuDelegate>)delegate { _delegate = delegate; }
- (BOOL)autoenablesItems { return !_m.noAutoenable; }
- (void)setAutoenablesItems:(BOOL)flag { _m.noAutoenable = !flag; }
- (CGFloat)minimumWidth { return _minimumWidth; }
- (void)setMinimumWidth:(CGFloat)width { _minimumWidth = width; }
- (NSSize)size { return FinchMenuSize(self); }
- (NSFont *)font { return _font ?: [NSFont menuFontOfSize:0]; }
- (void)setFont:(NSFont *)font { [_font autorelease]; _font = [font retain]; }
- (BOOL)showsStateColumn { return !_m.noStateColumn; }
- (void)setShowsStateColumn:(BOOL)flag { _m.noStateColumn = !flag; }
- (BOOL)allowsContextMenuPlugIns { return !_m.noContextPlugIns; }
- (void)setAllowsContextMenuPlugIns:(BOOL)flag { _m.noContextPlugIns = !flag; }
- (BOOL)automaticallyInsertsWritingToolsItems { return !_m.noWritingTools; }
- (void)setAutomaticallyInsertsWritingToolsItems:(BOOL)flag { _m.noWritingTools = !flag; }
- (BOOL)menuChangedMessagesEnabled { return _m.changedMessages; }
- (void)setMenuChangedMessagesEnabled:(BOOL)flag { _m.changedMessages = flag; }
- (NSUserInterfaceLayoutDirection)userInterfaceLayoutDirection { return _direction; }
- (void)setUserInterfaceLayoutDirection:(NSUserInterfaceLayoutDirection)d { _direction = d; }
- (NSMenuItem *)highlightedItem { return _highlighted; }
- (NSUserInterfaceItemIdentifier)identifier { return _identifier; }
- (void)setIdentifier:(NSUserInterfaceItemIdentifier)identifier { [_identifier autorelease]; _identifier = [identifier copy]; }
- (NSAppearance *)appearance { return _appearance; }
- (void)setAppearance:(NSAppearance *)appearance { [_appearance autorelease]; _appearance = [appearance retain]; }
- (NSAppearance *)effectiveAppearance { return _appearance ?: [_supermenu effectiveAppearance] ?: [NSApp effectiveAppearance]; }
- (NSMenuPresentationStyle)presentationStyle { return _presentationStyle; }
- (void)setPresentationStyle:(NSMenuPresentationStyle)style { _presentationStyle = style; }
- (NSMenuSelectionMode)selectionMode { return _selectionMode; }
- (void)setSelectionMode:(NSMenuSelectionMode)mode { _selectionMode = mode; }
- (NSArray<NSMenuItem *> *)selectedItems { return _selectedItems ?: @[]; }
- (void)setSelectedItems:(NSArray<NSMenuItem *> *)items { [_selectedItems autorelease]; _selectedItems = [items copy]; }
- (NSMenuProperties)propertiesToUpdate { return 0x3f; }
- (BOOL)isTornOff { return NO; }
- (BOOL)isAttached { return NO; }
- (NSMenu *)attachedMenu { return nil; }
- (void)sizeToFit {}
- (void)submenuAction:(id)sender {}
- (void)helpRequested:(NSEvent *)event {}

- (CGFloat)menuBarHeight
{
    return self == [NSApp mainMenu] && menu_bar_visible ? 24 : 0;
}

+ (BOOL)menuBarVisible { return menu_bar_visible; }

+ (void)setMenuBarVisible:(BOOL)visible
{
    menu_bar_visible = visible;
    FinchMenuBarUpdate();
}

- (void)_finchSetHighlightedItem:(NSMenuItem *)item
{
    if (item == _highlighted)
        return;
    id d = _delegate;
    if ([d respondsToSelector:@selector(menu:willHighlightItem:)])
        [d menu:self willHighlightItem:item];
    [_highlighted _finchSetHighlighted:NO];
    _highlighted = item;
    [item _finchSetHighlighted:YES];
}

#pragma mark - Items

static void
post(NSMenu *menu, NSString *name, NSInteger index)
{
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:menu
                                                      userInfo:@{@"NSMenuItemIndex" : @(index)}];
}

static void
check_index(NSMenu *self, NSInteger index, NSUInteger limit)
{
    if (index < 0 || (NSUInteger)index >= limit)
        [NSException raise:NSInternalInconsistencyException
                    format:@"Invalid parameter not satisfying: index < [_itemArray count]"];
}

- (void)insertItem:(NSMenuItem *)item atIndex:(NSInteger)index
{
    if (!item)
        [NSException raise:NSInternalInconsistencyException format:@"Invalid parameter not satisfying: newItem != nil"];
    if ([item menu])
        [NSException raise:NSInternalInconsistencyException
                    format:@"Item to be inserted into menu already is in another menu"];
    check_index(self, index, [_items count] + 1);
    [_items insertObject:item atIndex:(NSUInteger)index];
    [item setMenu:self];
    post(self, NSMenuDidAddItemNotification, index);
}

- (void)addItem:(NSMenuItem *)item
{
    [self insertItem:item atIndex:(NSInteger)[_items count]];
}

- (NSMenuItem *)insertItemWithTitle:(NSString *)title action:(SEL)selector keyEquivalent:(NSString *)key
                            atIndex:(NSInteger)index
{
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:key];
    [self insertItem:i atIndex:index];
    return [i autorelease];
}

- (NSMenuItem *)addItemWithTitle:(NSString *)title action:(SEL)selector keyEquivalent:(NSString *)key
{
    return [self insertItemWithTitle:title action:selector keyEquivalent:key atIndex:(NSInteger)[_items count]];
}

- (void)removeItemAtIndex:(NSInteger)index
{
    check_index(self, index, [_items count]);
    NSMenuItem *i = [_items[(NSUInteger)index] retain];
    if (_highlighted == i)
        _highlighted = nil;
    [_items removeObjectAtIndex:(NSUInteger)index];
    [i setMenu:nil];
    post(self, NSMenuDidRemoveItemNotification, index);
    [i release];
}

- (void)removeItem:(NSMenuItem *)item
{
    NSUInteger i = [_items indexOfObjectIdenticalTo:item];
    if (i != NSNotFound)
        [self removeItemAtIndex:(NSInteger)i];
}

- (void)removeAllItems
{
    NSArray *old = [_items copy];
    [_items removeAllObjects];
    _highlighted = nil;
    for (NSMenuItem *i in old)
        [i setMenu:nil];
    [old release];
}

- (NSArray<NSMenuItem *> *)itemArray { return [[_items copy] autorelease]; }

- (void)setItemArray:(NSArray<NSMenuItem *> *)items
{
    items = [[items copy] autorelease];
    [self removeAllItems];
    for (NSMenuItem *i in items)
        [self addItem:i];
}

- (NSInteger)numberOfItems { return (NSInteger)[_items count]; }

- (NSMenuItem *)itemAtIndex:(NSInteger)index
{
    check_index(self, index, [_items count]);
    return _items[(NSUInteger)index];
}

- (void)setSubmenu:(NSMenu *)menu forItem:(NSMenuItem *)item
{
    [item setSubmenu:menu];
    [self itemChanged:item];
}

- (void)itemChanged:(NSMenuItem *)item
{
    NSUInteger i = [_items indexOfObjectIdenticalTo:item];
    if (i != NSNotFound)
        post(self, NSMenuDidChangeItemNotification, (NSInteger)i);
}

#pragma mark - Finding items

static NSInteger
find(NSMenu *self, BOOL (^match)(NSMenuItem *))
{
    NSUInteger n = [self->_items count];
    for (NSUInteger i = 0; i < n; i++)
        if (match(self->_items[i]))
            return (NSInteger)i;
    return -1;
}

- (NSInteger)indexOfItem:(NSMenuItem *)item
{
    NSUInteger i = [_items indexOfObjectIdenticalTo:item];
    return i == NSNotFound ? -1 : (NSInteger)i;
}

- (NSInteger)indexOfItemWithTitle:(NSString *)title
{
    return find(self, ^BOOL(NSMenuItem *i) { return [[i title] isEqualToString:title]; });
}

- (NSInteger)indexOfItemWithTag:(NSInteger)tag
{
    return find(self, ^BOOL(NSMenuItem *i) { return [i tag] == tag; });
}

- (NSInteger)indexOfItemWithRepresentedObject:(id)object
{
    return find(self, ^BOOL(NSMenuItem *i) {
        id r = [i representedObject];
        return r == object || [r isEqual:object];
    });
}

- (NSInteger)indexOfItemWithSubmenu:(NSMenu *)submenu
{
    return find(self, ^BOOL(NSMenuItem *i) { return [i submenu] == submenu; });
}

- (NSInteger)indexOfItemWithTarget:(id)target andAction:(SEL)action
{
    return find(self, ^BOOL(NSMenuItem *i) { return [i target] == target && (!action || [i action] == action); });
}

- (NSMenuItem *)itemWithTitle:(NSString *)title
{
    NSInteger i = [self indexOfItemWithTitle:title];
    return i < 0 ? nil : _items[(NSUInteger)i];
}

- (NSMenuItem *)itemWithTag:(NSInteger)tag
{
    NSInteger i = [self indexOfItemWithTag:tag];
    return i < 0 ? nil : _items[(NSUInteger)i];
}

#pragma mark - Validation

static BOOL
validate(NSMenuItem *item)
{
    if ([item hasSubmenu])
        return YES;
    SEL action = [item action];
    id t = NSApp ? [NSApp targetForAction:action to:[item target] from:item] : [item target];
    if (!t || !action || ![t respondsToSelector:action])
        return NO;
    if ([t respondsToSelector:@selector(validateMenuItem:)])
        return [t validateMenuItem:item];
    if ([t respondsToSelector:@selector(validateUserInterfaceItem:)])
        return [t validateUserInterfaceItem:item];
    return YES;
}

- (void)update
{
    if (_m.noAutoenable)
        return;
    NSArray *items = [[_items copy] autorelease];
    for (NSMenuItem *i in items)
        if (![i isSeparatorItem])
            [i _finchSetEnabled:validate(i)];
}

#pragma mark - Actions and key equivalents

- (BOOL)_finchSendActionForItem:(NSMenuItem *)item
{
    if (![item isEnabled])
        return NO;
    [item retain];
    FinchBindingsMenuItemChosen(item);  /* NSKeyValueBinding.m */
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSDictionary *info = @{@"MenuItem" : item};
    [nc postNotificationName:NSMenuWillSendActionNotification object:self userInfo:info];
    if ([item action])
        [NSApp sendAction:[item action] to:[item target] from:item];
    [nc postNotificationName:NSMenuDidSendActionNotification object:self userInfo:info];
    [item release];
    return YES;
}

- (void)performActionForItemAtIndex:(NSInteger)index
{
    [self _finchSendActionForItem:[self itemAtIndex:index]];
}

/* The delegate's own key equivalent, if it has one. */
static BOOL
delegate_key_equivalent(NSMenu *menu, NSEvent *event)
{
    id d = menu->_delegate;
    if (![d respondsToSelector:@selector(menuHasKeyEquivalent:forEvent:target:action:)])
        return NO;
    id target = nil;
    SEL action = NULL;
    if (![d menuHasKeyEquivalent:menu forEvent:event target:&target action:&action])
        return NO;
    if (action)
        [NSApp sendAction:action to:target from:menu];
    return YES;
}

static BOOL
delegates_pass(NSMenu *menu, NSEvent *event)
{
    if (delegate_key_equivalent(menu, event))
        return YES;
    for (NSMenuItem *i in [[menu->_items copy] autorelease])
        if ([i submenu] && delegates_pass([i submenu], event))
            return YES;
    return NO;
}

static BOOL
matches(NSMenuItem *item, NSString *chars, NSEventModifierFlags flags)
{
    NSString *key = [item keyEquivalent];
    return ![item isSeparatorItem] && [key length] && [key isEqualToString:chars] &&
           ([item keyEquivalentModifierMask] & KE_COMPARED) == (flags & KE_COMPARED);
}

- (BOOL)_finchKeyEquivalent:(NSEvent *)event
{
    if (delegate_key_equivalent(self, event))
        return YES;
    [self update];
    NSString *chars = [event charactersIgnoringModifiers];
    NSEventModifierFlags flags = [event modifierFlags];
    NSArray *items = [[_items copy] autorelease];
    for (NSMenuItem *i in items) {
        if (matches(i, chars, flags)) {
            [self _finchSendActionForItem:i];
            return YES;
        }
    }
    for (NSMenuItem *i in items)
        if ([i submenu] && [[i submenu] _finchKeyEquivalent:event])
            return YES;
    return NO;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if ([event type] != NSEventTypeKeyDown)
        return NO;
    if (delegates_pass(self, event))
        return YES;
    return [self _finchKeyEquivalent:event];
}

#pragma mark - Opening

/* The Windows menu lists the app's windows after its own items. */
static NSString *const windows_item_id = @"_FinchWindowsMenuItem";

static void
sync_windows_menu(NSMenu *menu)
{
    for (NSInteger i = [menu numberOfItems] - 1; i >= 0; i--)
        if ([[[menu itemAtIndex:i] identifier] isEqualToString:windows_item_id])
            [menu removeItemAtIndex:i];
    BOOL first = YES;
    for (NSWindow *w in [NSApp windows]) {
        if (![w isVisible] || [w isExcludedFromWindowsMenu] || ![[w title] length] ||
            !([w styleMask] & NSWindowStyleMaskTitled))
            continue;
        if (first && [menu numberOfItems]) {
            NSMenuItem *sep = [NSMenuItem separatorItem];
            [sep setIdentifier:windows_item_id];
            [menu addItem:sep];
        }
        first = NO;
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:[w title] action:@selector(makeKeyAndOrderFront:)
                                            keyEquivalent:@""];
        [i setTarget:w];
        [i setIdentifier:windows_item_id];
        [i setState:[w isMainWindow] || [w isKeyWindow] ? NSControlStateValueOn : NSControlStateValueOff];
        [menu addItem:i];
        [i release];
    }
}

- (void)_finchPrepareToOpen
{
    id d = _delegate;
    if ([d respondsToSelector:@selector(menuNeedsUpdate:)])
        [d menuNeedsUpdate:self];
    if ([d respondsToSelector:@selector(numberOfItemsInMenu:)]) {
        NSInteger n = [d numberOfItemsInMenu:self];
        if (n >= 0) {
            while ([self numberOfItems] < n)
                [self addItemWithTitle:@"" action:NULL keyEquivalent:@""];
            while ([self numberOfItems] > n)
                [self removeItemAtIndex:[self numberOfItems] - 1];
            if ([d respondsToSelector:@selector(menu:updateItem:atIndex:shouldCancel:)])
                for (NSInteger i = 0; i < n; i++)
                    if (![d menu:self updateItem:[self itemAtIndex:i] atIndex:i shouldCancel:NO])
                        break;
        }
    }
    if (self == [NSApp windowsMenu])
        sync_windows_menu(self);
    [self update];
}

- (void)cancelTracking
{
    FinchMenuCancelTracking(YES);
}

- (void)cancelTrackingWithoutAnimation
{
    FinchMenuCancelTracking(NO);
}

+ (void)popUpContextMenu:(NSMenu *)menu withEvent:(NSEvent *)event forView:(NSView *)view
{
    [self popUpContextMenu:menu withEvent:event forView:view withFont:nil];
}

+ (void)popUpContextMenu:(NSMenu *)menu withEvent:(NSEvent *)event forView:(NSView *)view withFont:(NSFont *)font
{
    if (!menu)
        return;
    NSPoint p = event ? FinchEventScreenLocation(event) : [NSEvent mouseLocation];
    [view willOpenMenu:menu withEvent:event];
    FinchMenuPopUp(menu, nil, p, view, event, 0, font, YES);
    [view didCloseMenu:menu withEvent:event];
}

- (BOOL)popUpMenuPositioningItem:(NSMenuItem *)item atLocation:(NSPoint)location inView:(NSView *)view
{
    NSPoint p = location;
    if (view) {
        p = [view convertPoint:location toView:nil];
        p = [[view window] convertPointToScreen:p];
    }
    return FinchMenuPopUp(self, item, p, view, [NSApp currentEvent], 0, nil, YES) != nil;
}

#pragma mark - Palettes

+ (instancetype)paletteMenuWithColors:(NSArray<NSColor *> *)colors titles:(NSArray<NSString *> *)titles
                     selectionHandler:(void (^)(NSMenu *))handler
{
    NSMenu *m = [[[self alloc] initWithTitle:@""] autorelease];
    m->_presentationStyle = NSMenuPresentationStylePalette;
    for (NSString *t in titles)
        [m addItemWithTitle:t action:NULL keyEquivalent:@""];
    return m;
}

+ (instancetype)paletteMenuWithColors:(NSArray<NSColor *> *)colors titles:(NSArray<NSString *> *)titles
                        templateImage:(NSImage *)image selectionHandler:(void (^)(NSMenu *))handler
{
    return [self paletteMenuWithColors:colors titles:titles selectionHandler:handler];
}

@end

/* The app's own menu items, validated as Apple's are: Hide while the app is active, Show All when another app
 * is hidden (Finch doesn't hide other apps yet). */
@implementation NSApplication (FinchMenuValidation)

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL action = [item action];
    if (action == @selector(hide:))
        return [self isActive] && ![self isHidden];
    if (action == @selector(unhideAllApplications:))
        return NO;
    return YES;
}

@end
