/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSToolbar, NSToolbarItem and NSToolbarItemGroup. A window's visible
 * toolbar adds 34 points under its title bar, as macOS 26's windows grow
 * from 32 to 66 points of chrome; the items are laid out in that row, in
 * Finch's own look, flexible spaces taking what's left. Items come from the
 * delegate as on macOS, are validated against the responder chain when the
 * window updates, and send their actions through NSApp.
 */
#import "NSView_Finch.h"

NSToolbarItemIdentifier NSToolbarSeparatorItemIdentifier = @"NSToolbarSeparatorItem";
NSToolbarItemIdentifier NSToolbarSpaceItemIdentifier = @"NSToolbarSpaceItem";
NSToolbarItemIdentifier NSToolbarFlexibleSpaceItemIdentifier = @"NSToolbarFlexibleSpaceItem";
NSToolbarItemIdentifier NSToolbarShowColorsItemIdentifier = @"NSToolbarShowColorsItem";
NSToolbarItemIdentifier NSToolbarShowFontsItemIdentifier = @"NSToolbarShowFontsItem";
NSToolbarItemIdentifier NSToolbarCustomizeToolbarItemIdentifier = @"NSToolbarCustomizeToolbarItem";
NSToolbarItemIdentifier NSToolbarPrintItemIdentifier = @"NSToolbarPrintItem";
NSToolbarItemIdentifier NSToolbarToggleSidebarItemIdentifier = @"NSToolbarToggleSidebarItem";
NSToolbarItemIdentifier NSToolbarToggleInspectorItemIdentifier = @"NSToolbarToggleInspectorItem";
NSToolbarItemIdentifier NSToolbarCloudSharingItemIdentifier = @"NSToolbarCloudSharingItem";
NSToolbarItemIdentifier NSToolbarSidebarTrackingSeparatorItemIdentifier =
    @"NSToolbarSidebarTrackingSeparatorItemIdentifier";
NSToolbarItemIdentifier NSToolbarInspectorTrackingSeparatorItemIdentifier =
    @"NSToolbarInspectorTrackingSeparatorItemIdentifier";
NSToolbarItemIdentifier NSToolbarWritingToolsItemIdentifier = @"NSToolbarWritingToolsItem";
NSNotificationName NSToolbarWillAddItemNotification = @"NSToolbarWillAddItemNotification";
NSNotificationName NSToolbarDidRemoveItemNotification = @"NSToolbarDidRemoveItemNotification";

const CGFloat FinchToolbarHeight = 34;

#pragma mark - NSToolbarItem

@implementation NSToolbarItem {
    NSToolbarItemIdentifier _identifier;
    NSString *_label, *_paletteLabel, *_toolTip, *_title;
    NSImage *_image;
    NSView *_view;
    id _target;  /* not retained */
    SEL _action;
    NSInteger _tag;
    NSToolbar *_toolbar;  /* not retained */
    NSMenuItem *_menuForm;
    NSToolbarItemVisibilityPriority _priority;
    NSSize _minSize, _maxSize;
    BOOL _enabled, _autovalidates, _bordered, _navigational, _hidden;
    NSRect _frame;  /* in the toolbar's row, while laid out */
}

- (instancetype)initWithItemIdentifier:(NSToolbarItemIdentifier)identifier
{
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _label = @"";
        _paletteLabel = @"";
        _enabled = YES;
        _autovalidates = YES;
        _tag = -1;
    }
    return self;
}

- (instancetype)init
{
    return [self initWithItemIdentifier:@""];
}

- (void)dealloc
{
    [_identifier release];
    [_label release];
    [_paletteLabel release];
    [_toolTip release];
    [_title release];
    [_image release];
    [_view release];
    [_menuForm release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSToolbarItem *c = [[[self class] alloc] initWithItemIdentifier:_identifier];
    [c setLabel:_label];
    [c setPaletteLabel:_paletteLabel];
    [c setImage:_image];
    [c setTarget:_target];
    [c setAction:_action];
    [c setTag:_tag];
    [c setToolTip:_toolTip];
    return c;
}

- (NSToolbarItemIdentifier)itemIdentifier { return _identifier; }
- (NSToolbar *)toolbar { return _toolbar; }
- (void)_finchSetToolbar:(NSToolbar *)t { _toolbar = t; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { [_label autorelease]; _label = [l copy] ?: @""; [_toolbar _finchChanged]; }
- (NSString *)paletteLabel { return _paletteLabel; }
- (void)setPaletteLabel:(NSString *)l { [_paletteLabel autorelease]; _paletteLabel = [l copy] ?: @""; }
- (NSString *)title { return _title ?: @""; }
- (void)setTitle:(NSString *)t { [_title autorelease]; _title = [t copy]; [_toolbar _finchChanged]; }
- (NSString *)toolTip { return _toolTip; }
- (void)setToolTip:(NSString *)t { [_toolTip autorelease]; _toolTip = [t copy]; }
- (NSImage *)image { return _image; }
- (void)setImage:(NSImage *)i { [_image autorelease]; _image = [i retain]; [_toolbar _finchChanged]; }
- (NSView *)view { return _view; }
- (void)setView:(NSView *)v { [_view autorelease]; _view = [v retain]; [_toolbar _finchChanged]; }
- (id)target { return _target; }
- (void)setTarget:(id)t { _target = t; }
- (SEL)action { return _action; }
- (void)setAction:(SEL)a { _action = a; }
- (NSInteger)tag { return _tag; }
- (void)setTag:(NSInteger)t { _tag = t; }
- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)f { _enabled = f; [_toolbar _finchChanged]; }
- (BOOL)autovalidates { return _autovalidates; }
- (void)setAutovalidates:(BOOL)f { _autovalidates = f; }
- (BOOL)isBordered { return _bordered; }
- (void)setBordered:(BOOL)f { _bordered = f; }
- (BOOL)isNavigational { return _navigational; }
- (void)setNavigational:(BOOL)f { _navigational = f; }
- (BOOL)isHidden { return _hidden; }
- (void)setHidden:(BOOL)f { _hidden = f; [_toolbar _finchChanged]; }
- (BOOL)isVisible { return _toolbar && [_toolbar isVisible] && !_hidden; }
- (NSToolbarItemVisibilityPriority)visibilityPriority { return _priority; }
- (void)setVisibilityPriority:(NSToolbarItemVisibilityPriority)p { _priority = p; }
- (NSMenuItem *)menuFormRepresentation { return _menuForm; }
- (void)setMenuFormRepresentation:(NSMenuItem *)m { [_menuForm autorelease]; _menuForm = [m retain]; }
- (NSSize)minSize { return _minSize; }
- (void)setMinSize:(NSSize)s { _minSize = s; }
- (NSSize)maxSize { return _maxSize; }
- (void)setMaxSize:(NSSize)s { _maxSize = s; }
- (BOOL)allowsDuplicatesInToolbar { return NO; }
- (NSRect)_finchFrame { return _frame; }
- (void)_finchSetFrame:(NSRect)f { _frame = f; }

static BOOL
is_space(NSToolbarItem *i)
{
    return [i->_identifier isEqualToString:NSToolbarFlexibleSpaceItemIdentifier] ||
           [i->_identifier isEqualToString:NSToolbarSpaceItemIdentifier] ||
           [i->_identifier isEqualToString:NSToolbarSidebarTrackingSeparatorItemIdentifier] ||
           [i->_identifier isEqualToString:NSToolbarInspectorTrackingSeparatorItemIdentifier] ||
           [i->_identifier isEqualToString:NSToolbarSeparatorItemIdentifier];
}

/* The standard items act on the responder chain. */
- (SEL)_finchStandardAction
{
    if ([_identifier isEqualToString:NSToolbarPrintItemIdentifier])
        return @selector(printDocument:);
    if ([_identifier isEqualToString:NSToolbarShowFontsItemIdentifier])
        return @selector(orderFrontFontPanel:);
    if ([_identifier isEqualToString:NSToolbarShowColorsItemIdentifier])
        return @selector(orderFrontColorPanel:);
    if ([_identifier isEqualToString:NSToolbarToggleSidebarItemIdentifier])
        return @selector(toggleSidebar:);
    if ([_identifier isEqualToString:NSToolbarToggleInspectorItemIdentifier])
        return @selector(toggleInspector:);
    return NULL;
}

/* As Apple's: an item with a target that answers validateToolbarItem: asks it; otherwise it's enabled
 * when something on the responder chain takes its action. */
- (void)validate
{
    if (!_autovalidates || _view)
        return;
    SEL action = _action ?: [self _finchStandardAction];
    if (!action)
        return;
    id target = [NSApp targetForAction:action to:_target from:self];
    BOOL enabled = target != nil;
    if (target && [target respondsToSelector:@selector(validateToolbarItem:)])
        enabled = [target validateToolbarItem:self];
    else if (target && [target respondsToSelector:@selector(validateUserInterfaceItem:)])
        enabled = [target validateUserInterfaceItem:(id)self];
    if (enabled != _enabled) {
        _enabled = enabled;
        [_toolbar _finchChanged];
    }
}

- (void)_finchPerform
{
    SEL action = _action ?: [self _finchStandardAction];
    if (action && _enabled)
        [NSApp sendAction:action to:_target from:self];
}

/* Sizes are archived as NSValues, or as strings by ibtool. */
static NSSize
decode_size(NSCoder *coder, NSString *key)
{
    id v = [coder decodeObjectForKey:key];
    if ([v isKindOfClass:[NSString class]])
        return NSSizeFromString(v);
    if ([v isKindOfClass:[NSValue class]])
        return [v sizeValue];
    return NSZeroSize;
}

/* From a nib or storyboard, with Apple's keys. */
- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self initWithItemIdentifier:[coder decodeObjectForKey:@"NSToolbarItemIdentifier"] ?: @""];
    if (self) {
        [self setLabel:[coder decodeObjectForKey:@"NSToolbarItemLabel"]];
        [self setPaletteLabel:[coder decodeObjectForKey:@"NSToolbarItemPaletteLabel"]];
        _toolTip = [[coder decodeObjectForKey:@"NSToolbarItemToolTip"] copy];
        _title = [[coder decodeObjectForKey:@"NSToolbarItemTitle"] copy];
        _image = [[coder decodeObjectForKey:@"NSToolbarItemImage"] retain];
        _view = [[coder decodeObjectForKey:@"NSToolbarItemView"] retain];
        _menuForm = [[coder decodeObjectForKey:@"NSToolbarItemMenuFormRepresentation"] retain];
        _target = [coder decodeObjectForKey:@"NSToolbarItemTarget"];
        NSString *action = [coder decodeObjectForKey:@"NSToolbarItemAction"];
        if ([action isKindOfClass:[NSString class]])
            _action = NSSelectorFromString(action);
        if ([coder containsValueForKey:@"NSToolbarItemTag"])
            _tag = [coder decodeIntegerForKey:@"NSToolbarItemTag"];
        if ([coder containsValueForKey:@"NSToolbarItemEnabled"])
            _enabled = [coder decodeBoolForKey:@"NSToolbarItemEnabled"];
        if ([coder containsValueForKey:@"NSToolbarItemAutovalidates"])
            _autovalidates = [coder decodeBoolForKey:@"NSToolbarItemAutovalidates"];
        _bordered = [coder decodeBoolForKey:@"NSToolbarItemBordered"];
        _navigational = [coder decodeBoolForKey:@"NSToolbarItemNavigational"];
        _priority = [coder decodeIntegerForKey:@"NSToolbarItemVisibilityPriority"];
        _minSize = decode_size(coder, @"NSToolbarItemMinSize");
        _maxSize = decode_size(coder, @"NSToolbarItemMaxSize");
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {}

@end

/* The standard spaces and separator, as nibs archive them (Apple's private classes). */
@interface NSToolbarFlexibleSpaceItem : NSToolbarItem
@end
@implementation NSToolbarFlexibleSpaceItem
- (instancetype)initWithItemIdentifier:(NSToolbarItemIdentifier)identifier
{
    return [super initWithItemIdentifier:NSToolbarFlexibleSpaceItemIdentifier];
}
@end

@interface NSToolbarSpaceItem : NSToolbarItem
@end
@implementation NSToolbarSpaceItem
- (instancetype)initWithItemIdentifier:(NSToolbarItemIdentifier)identifier
{
    return [super initWithItemIdentifier:NSToolbarSpaceItemIdentifier];
}
@end

@interface NSToolbarSeparatorItem : NSToolbarItem
@end
@implementation NSToolbarSeparatorItem
- (instancetype)initWithItemIdentifier:(NSToolbarItemIdentifier)identifier
{
    return [super initWithItemIdentifier:NSToolbarSeparatorItemIdentifier];
}
@end

@implementation NSToolbarItemGroup {
    NSArray<NSToolbarItem *> *_subitems;
    NSToolbarItemGroupSelectionMode _selectionMode;
    NSToolbarItemGroupControlRepresentation _representation;
    NSInteger _selectedIndex;
}

+ (instancetype)groupWithItemIdentifier:(NSToolbarItemIdentifier)identifier titles:(NSArray<NSString *> *)titles
                          selectionMode:(NSToolbarItemGroupSelectionMode)mode labels:(NSArray<NSString *> *)labels
                                 target:(id)target action:(SEL)action
{
    NSToolbarItemGroup *g = [[[self alloc] initWithItemIdentifier:identifier] autorelease];
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < [titles count]; i++) {
        NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:[NSString stringWithFormat:@"%@.%lu", identifier, (unsigned long)i]] autorelease];
        [item setLabel:i < [labels count] ? labels[i] : titles[i]];
        [item setTitle:titles[i]];
        [item setTarget:target];
        [item setAction:action];
        [item setTag:(NSInteger)i];
        [items addObject:item];
    }
    [g setSubitems:items];
    g->_selectionMode = mode;
    g->_selectedIndex = -1;
    return g;
}

+ (instancetype)groupWithItemIdentifier:(NSToolbarItemIdentifier)identifier images:(NSArray<NSImage *> *)images
                          selectionMode:(NSToolbarItemGroupSelectionMode)mode labels:(NSArray<NSString *> *)labels
                                 target:(id)target action:(SEL)action
{
    NSMutableArray *titles = [NSMutableArray array];
    for (NSUInteger i = 0; i < [images count]; i++)
        [titles addObject:i < [labels count] ? labels[i] : @""];
    NSToolbarItemGroup *g = [self groupWithItemIdentifier:identifier titles:titles selectionMode:mode labels:labels
                                                   target:target action:action];
    for (NSUInteger i = 0; i < [images count]; i++)
        [g->_subitems[i] setImage:images[i]];
    return g;
}

- (void)dealloc
{
    [_subitems release];
    [super dealloc];
}

- (NSArray<NSToolbarItem *> *)subitems { return _subitems ?: @[]; }
- (void)setSubitems:(NSArray<NSToolbarItem *> *)items { [_subitems autorelease]; _subitems = [items copy]; }
- (NSToolbarItemGroupSelectionMode)selectionMode { return _selectionMode; }
- (void)setSelectionMode:(NSToolbarItemGroupSelectionMode)m { _selectionMode = m; }
- (NSToolbarItemGroupControlRepresentation)controlRepresentation { return _representation; }
- (void)setControlRepresentation:(NSToolbarItemGroupControlRepresentation)r { _representation = r; }
- (NSInteger)selectedIndex { return _selectedIndex; }
- (void)setSelectedIndex:(NSInteger)i { _selectedIndex = i; }
- (void)setSelected:(BOOL)selected atIndex:(NSInteger)index { if (selected) _selectedIndex = index; }
- (BOOL)isSelectedAtIndex:(NSInteger)index { return _selectedIndex == index; }

@end

#pragma mark - The toolbar's row

@interface FinchToolbarView : NSView
@property (assign) NSToolbar *toolbar;
@end

#pragma mark - NSToolbar

@implementation NSToolbar {
    NSToolbarIdentifier _identifier;
    id<NSToolbarDelegate> _delegate;  /* not retained */
    NSMutableArray<NSToolbarItem *> *_items;
    NSToolbarDisplayMode _displayMode;
    NSToolbarSizeMode _sizeMode;
    BOOL _visible, _allowsUserCustomization, _autosaves, _showsBaseline, _allowsExtensionItems, _loaded;
    NSDictionary *_ibItems;  /* the nib's items by identifier, for the delegate's identifiers */
    NSToolbarItemIdentifier _selected;
    NSWindow *_window;  /* not retained */
    FinchToolbarView *_view;
}

- (instancetype)initWithIdentifier:(NSToolbarIdentifier)identifier
{
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _items = [[NSMutableArray alloc] init];
        _displayMode = NSToolbarDisplayModeIconAndLabel;
        _sizeMode = NSToolbarSizeModeRegular;
    }
    return self;
}

- (instancetype)init
{
    return [self initWithIdentifier:@""];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [self initWithIdentifier:[coder decodeObjectForKey:@"NSToolbarIdentifier"] ?: @""];
    if (self) {
        _delegate = [coder decodeObjectForKey:@"NSToolbarDelegate"];
        _displayMode = [coder decodeIntegerForKey:@"NSToolbarDisplayMode"];
        _sizeMode = [coder decodeIntegerForKey:@"NSToolbarSizeMode"];
        _allowsUserCustomization = [coder decodeBoolForKey:@"NSToolbarAllowsUserCustomization"];
        _autosaves = [coder decodeBoolForKey:@"NSToolbarAutosavesConfiguration"];
        _visible = ![coder containsValueForKey:@"NSToolbarPrefersToBeShown"] || [coder decodeBoolForKey:@"NSToolbarPrefersToBeShown"];
        NSDictionary *byID = [coder decodeObjectForKey:@"NSToolbarIBIdentifiedItems"];
        if ([byID isKindOfClass:[NSDictionary class]])
            _ibItems = [byID copy];
        for (NSString *ident in [coder decodeObjectForKey:@"NSToolbarIBDefaultItems"]) {
            NSToolbarItem *item = [byID[ident] isKindOfClass:[NSToolbarItem class]] ? byID[ident] : nil;
            if (item) {
                [item _finchSetToolbar:self];
                [_items addObject:item];
            }
        }
        _loaded = [_items count] > 0;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {}

- (void)dealloc
{
    [_identifier release];
    [_items release];
    [_ibItems release];
    [_selected release];
    [_view release];
    [super dealloc];
}

- (NSToolbarIdentifier)identifier { return _identifier; }
- (id<NSToolbarDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSToolbarDelegate>)delegate
{
    _delegate = delegate;
    /* a toolbar with nothing in it yet asks its new delegate when next shown */
    if (![_items count] && _loaded) {
        _loaded = NO;
        [self _finchChanged];
    }
}
- (NSToolbarDisplayMode)displayMode { return _displayMode; }
- (void)setDisplayMode:(NSToolbarDisplayMode)m { _displayMode = m; [self _finchChanged]; }
- (NSToolbarSizeMode)sizeMode { return _sizeMode; }
- (void)setSizeMode:(NSToolbarSizeMode)m { _sizeMode = m; }
- (BOOL)allowsUserCustomization { return _allowsUserCustomization; }
- (void)setAllowsUserCustomization:(BOOL)f { _allowsUserCustomization = f; }
- (BOOL)allowsExtensionItems { return _allowsExtensionItems; }
- (void)setAllowsExtensionItems:(BOOL)f { _allowsExtensionItems = f; }
- (BOOL)autosavesConfiguration { return _autosaves; }
- (void)setAutosavesConfiguration:(BOOL)f { _autosaves = f; }
- (BOOL)showsBaselineSeparator { return _showsBaseline; }
- (void)setShowsBaselineSeparator:(BOOL)f { _showsBaseline = f; }
- (BOOL)customizationPaletteIsRunning { return NO; }
- (IBAction)runCustomizationPalette:(id)sender {}
- (NSDictionary<NSString *, id> *)configurationDictionary
{
    NSMutableArray *ids = [NSMutableArray array];
    for (NSToolbarItem *i in _items)
        [ids addObject:[i itemIdentifier]];
    return @{@"TB Item Identifiers" : ids, @"TB Is Shown" : @(_visible), @"TB Display Mode" : @(_displayMode)};
}
- (void)setConfigurationFromDictionary:(NSDictionary<NSString *, id> *)dict
{
    NSArray *ids = dict[@"TB Item Identifiers"];
    if ([ids isKindOfClass:[NSArray class]]) {
        while ([_items count])
            [self removeItemAtIndex:0];
        for (NSString *i in ids)
            [self insertItemWithItemIdentifier:i atIndex:(NSInteger)[_items count]];
    }
}
- (NSToolbarItemIdentifier)selectedItemIdentifier { return _selected; }
- (void)setSelectedItemIdentifier:(NSToolbarItemIdentifier)i { [_selected autorelease]; _selected = [i copy]; [self _finchChanged]; }
- (NSWindow *)_finchWindow { return _window; }

- (NSToolbarItem *)_finchMakeItem:(NSToolbarItemIdentifier)identifier
{
    NSToolbarItem *item = nil;
    /* As Apple's: the standard items are made by the toolbar, not the delegate. */
    if ([identifier hasPrefix:@"NSToolbar"])
        return [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
    /* an item the nib defines is used as it is, the first time it's placed */
    NSToolbarItem *ib = _ibItems[identifier];
    if ([ib isKindOfClass:[NSToolbarItem class]] && ![_items containsObject:ib])
        return ib;
    if ([(id)_delegate respondsToSelector:@selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:)])
        item = [_delegate toolbar:self itemForItemIdentifier:identifier willBeInsertedIntoToolbar:YES];
    if (!item && ([identifier hasPrefix:@"NSToolbar"]))
        item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
    return item;
}

/* The delegate's default items, made when the toolbar is first shown or used. */
- (void)_finchLoad
{
    if (_loaded)
        return;
    _loaded = YES;
    if (![(id)_delegate respondsToSelector:@selector(toolbarDefaultItemIdentifiers:)])
        return;
    for (NSToolbarItemIdentifier i in [_delegate toolbarDefaultItemIdentifiers:self])
        [self insertItemWithItemIdentifier:i atIndex:(NSInteger)[_items count]];
}

- (NSArray<__kindof NSToolbarItem *> *)items
{
    [self _finchLoad];
    return [[_items copy] autorelease];
}

- (NSArray<__kindof NSToolbarItem *> *)visibleItems
{
    if (!_visible)
        return nil;
    NSMutableArray *a = [NSMutableArray array];
    for (NSToolbarItem *i in [self items])
        if (![i isHidden])
            [a addObject:i];
    return a;
}

- (NSSet<NSToolbarItemIdentifier> *)centeredItemIdentifiers { return [NSSet set]; }
- (void)setCenteredItemIdentifiers:(NSSet<NSToolbarItemIdentifier> *)s {}

- (void)insertItemWithItemIdentifier:(NSToolbarItemIdentifier)identifier atIndex:(NSInteger)index
{
    NSToolbarItem *item = [self _finchMakeItem:identifier];
    if (!item)
        return;
    [[NSNotificationCenter defaultCenter] postNotificationName:NSToolbarWillAddItemNotification
                                                        object:self
                                                      userInfo:@{@"item" : item}];
    [item _finchSetToolbar:self];
    [_items insertObject:item atIndex:(NSUInteger)MIN(MAX(index, 0), (NSInteger)[_items count])];
    [self _finchChanged];
}

- (void)removeItemAtIndex:(NSInteger)index
{
    NSToolbarItem *item = [[_items[(NSUInteger)index] retain] autorelease];
    [_items removeObjectAtIndex:(NSUInteger)index];
    [item _finchSetToolbar:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSToolbarDidRemoveItemNotification
                                                        object:self
                                                      userInfo:@{@"item" : item}];
    [self _finchChanged];
}

- (void)validateVisibleItems
{
    for (NSToolbarItem *i in [self visibleItems])
        [i validate];
}

- (BOOL)isVisible { return _visible; }

- (void)setVisible:(BOOL)visible
{
    if (visible == _visible)
        return;
    _visible = visible;
    [self _finchLoad];
    [_window _finchToolbarChanged];
}

- (void)_finchSetWindow:(NSWindow *)window
{
    _window = window;
    if (window && !_visible && !_loaded) {
        _visible = YES;  /* a toolbar given to a window is shown, as Apple's */
        [self _finchLoad];
    }
}

- (FinchToolbarView *)_finchView
{
    if (!_view) {
        _view = [[FinchToolbarView alloc] initWithFrame:NSZeroRect];
        [_view setToolbar:self];
    }
    return _view;
}

- (void)_finchChanged
{
    [_view setNeedsDisplay:YES];
}

@end

#pragma mark - FinchToolbarView

@implementation FinchToolbarView

- (BOOL)isFlipped { return YES; }

static NSDictionary *
label_attributes(BOOL enabled)
{
    return @{NSFontAttributeName : [NSFont systemFontOfSize:11],
             NSForegroundColorAttributeName : enabled ? [NSColor labelColor] : [NSColor tertiaryLabelColor]};
}

static NSDictionary *
title_attributes(BOOL enabled)
{
    return @{NSFontAttributeName : [NSFont systemFontOfSize:13],
             NSForegroundColorAttributeName : enabled ? [NSColor labelColor] : [NSColor tertiaryLabelColor]};
}

static CGFloat
natural_width(NSToolbarItem *i)
{
    if ([[i itemIdentifier] isEqualToString:NSToolbarSpaceItemIdentifier])
        return 16;
    if ([[i itemIdentifier] isEqualToString:NSToolbarFlexibleSpaceItemIdentifier] || [[i itemIdentifier] hasSuffix:@"TrackingSeparatorItemIdentifier"])
        return 0;
    if ([i view])
        return [[i view] frame].size.width;
    NSString *text = [[i title] length] ? [i title] : [i label];
    CGFloat w = ceil([text sizeWithAttributes:title_attributes(YES)].width) + 20;
    return MAX(w, 32);
}

- (void)layout
{
    NSArray *items = [_toolbar visibleItems];
    CGFloat fixed = 0;
    NSInteger flexible = 0;
    for (NSToolbarItem *i in items) {
        fixed += natural_width(i) + 8;
        if ([[i itemIdentifier] isEqualToString:NSToolbarFlexibleSpaceItemIdentifier])
            flexible++;
    }
    CGFloat spare = MAX(0, [self bounds].size.width - 16 - fixed);
    CGFloat x = 8;
    for (NSToolbarItem *i in items) {
        CGFloat w = natural_width(i);
        if ([[i itemIdentifier] isEqualToString:NSToolbarFlexibleSpaceItemIdentifier] && flexible)
            w = floor(spare / flexible);
        NSRect r = NSMakeRect(x, 4, w, [self bounds].size.height - 8);
        [i _finchSetFrame:r];
        if ([i view]) {
            if ([[i view] superview] != self)
                [self addSubview:[i view]];
            NSRect vf = [[i view] frame];
            [[i view] setFrame:NSMakeRect(x, floor(NSMidY(r) - vf.size.height / 2), w, vf.size.height)];
        }
        x += w + 8;
    }
    [super layout];
}

- (void)drawRect:(NSRect)dirty
{
    [self layout];
    for (NSToolbarItem *i in [_toolbar visibleItems]) {
        if (is_space(i) || [i view])
            continue;
        NSRect r = [i _finchFrame];
        BOOL enabled = [i isEnabled];
        BOOL selected = [[_toolbar selectedItemIdentifier] isEqualToString:[i itemIdentifier]];
        if ([i isBordered] || selected) {
            [(selected ? [NSColor colorWithWhite:0 alpha:0.1] : [NSColor controlColor]) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0, 1) xRadius:6 yRadius:6] fill];
        }
        NSString *text = [[i title] length] ? [i title] : [i label];
        if ([i image] && [_toolbar displayMode] != NSToolbarDisplayModeLabelOnly) {
            NSRect ir = NSMakeRect(NSMidX(r) - 9, NSMidY(r) - 9, 18, 18);
            [[i image] drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                         fraction:enabled ? 1 : 0.4 respectFlipped:YES hints:nil];
        } else if ([text length]) {
            NSSize s = [text sizeWithAttributes:title_attributes(enabled)];
            [text drawAtPoint:NSMakePoint(floor(NSMidX(r) - s.width / 2), floor(NSMidY(r) - s.height / 2))
               withAttributes:title_attributes(enabled)];
        }
        (void)label_attributes;
    }
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    for (NSToolbarItem *i in [_toolbar visibleItems]) {
        if (is_space(i) || [i view] || !NSPointInRect(p, [i _finchFrame]))
            continue;
        NSEvent *e;
        while ((e = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged]))
            if ([e type] == NSEventTypeLeftMouseUp)
                break;
        if (NSPointInRect([self convertPoint:[e locationInWindow] fromView:nil], [i _finchFrame]))
            [i _finchPerform];
        return;
    }
    [super mouseDown:event];
}

@end
