/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTabView, NSTabViewItem and NSTabViewController. A tab view shows its
 * selected item's view in its content rect: inset 10 points at the sides
 * and 13 at the bottom, below 33 points of tabs, for the bordered styles,
 * as Apple's; the whole bounds without tabs or border. Tabs are drawn in
 * Finch's own look, a segmented strip centred over the content.
 */
#import "NSView_Finch.h"
#import "FinchTheme.h"
#import "NSControl_Finch.h"
#import "NSKeyValueBinding_Finch.h"

@implementation NSTabViewItem {
    id _identifier;
    NSString *_label, *_toolTip;
    NSView *_view;
    NSView *_initialFirstResponder;
    NSTabView *_tabView;  /* not retained */
    NSViewController *_viewController;
    NSImage *_image;
    NSColor *_color;
}

+ (instancetype)tabViewItemWithViewController:(NSViewController *)viewController
{
    NSTabViewItem *item = [[[self alloc] initWithIdentifier:nil] autorelease];
    [item setViewController:viewController];
    [item setLabel:[viewController title] ?: @""];
    return item;
}

- (instancetype)init { return [self initWithIdentifier:nil]; }

- (instancetype)initWithIdentifier:(id)identifier
{
    self = [super init];
    if (self) {
        _identifier = [identifier retain];
        _label = @"";
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        _identifier = [[coder decodeObjectForKey:@"NSIdentifier"] retain];
        _label = [[coder decodeObjectForKey:@"NSLabel"] copy] ?: @"";
        _view = [[coder decodeObjectForKey:@"NSView"] retain];
        _tabView = [coder decodeObjectForKey:@"NSTabView"];
        _toolTip = [[coder decodeObjectForKey:@"NSToolTip"] copy];
        _initialFirstResponder = [coder decodeObjectForKey:@"NSFirstResponder"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

- (void)dealloc
{
    [_identifier release];
    [_label release];
    [_toolTip release];
    [_view release];
    [_viewController release];
    [_image release];
    [_color release];
    [super dealloc];
}

- (id)identifier { return _identifier; }
- (void)setIdentifier:(id)identifier { [_identifier autorelease]; _identifier = [identifier retain]; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { [_label autorelease]; _label = [label copy] ?: @""; [_tabView setNeedsDisplay:YES]; }
- (NSString *)toolTip { return _toolTip; }
- (void)setToolTip:(NSString *)t { [_toolTip autorelease]; _toolTip = [t copy]; }
- (NSImage *)image { return _image; }
- (void)setImage:(NSImage *)image { [_image autorelease]; _image = [image retain]; }
- (NSColor *)color { return _color ?: [NSColor controlColor]; }
- (void)setColor:(NSColor *)color { [_color autorelease]; _color = [color retain]; }
- (NSTabView *)tabView { return _tabView; }
- (void)_finchSetTabView:(NSTabView *)tabView { _tabView = tabView; }
- (NSTabState)tabState
{
    return [_tabView selectedTabViewItem] == self ? NSSelectedTab : NSBackgroundTab;
}
- (id)initialFirstResponder { return _initialFirstResponder; }
- (void)setInitialFirstResponder:(NSView *)view { _initialFirstResponder = view; }

- (NSView *)view
{
    if (!_view && _viewController)
        _view = [[_viewController view] retain];
    if (!_view)
        _view = [[NSView alloc] initWithFrame:NSZeroRect];
    return _view;
}

- (void)setView:(NSView *)view { [_view autorelease]; _view = [view retain]; }
- (NSViewController *)viewController { return _viewController; }
- (void)setViewController:(NSViewController *)c
{
    [_viewController autorelease];
    _viewController = [c retain];
    [_view release];
    _view = nil;
}

- (NSSize)sizeOfLabel:(BOOL)computeMin
{
    return [_label sizeWithAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:[NSFont systemFontSize]]}];
}

- (void)drawLabel:(BOOL)shouldTruncateLabel inRect:(NSRect)labelRect
{
    [_label drawInRect:labelRect withAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:[NSFont systemFontSize]]}];
}

@end

@implementation NSTabView {
    NSMutableArray<NSTabViewItem *> *_items;
    NSTabViewItem *_selected;
    NSTabViewType _type;
    NSTabPosition _position;
    NSTabViewBorderType _border;
    BOOL _drawsBackground, _allowsTruncatedLabels;
    NSFont *_font;
    NSControlSize _controlSize;
    id<NSTabViewDelegate> _delegate;  /* not retained */
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _items = [[NSMutableArray alloc] init];
        _type = NSTopTabsBezelBorder;
        _drawsBackground = YES;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        _items = [[NSMutableArray alloc] init];
        for (NSTabViewItem *item in [coder decodeObjectForKey:@"NSTabViewItems"]) {
            [item _finchSetTabView:self];
            [_items addObject:item];
        }
        _type = [coder containsValueForKey:@"NSTvFlags"] ? ([coder decodeIntForKey:@"NSTvFlags"] & 7) : NSTopTabsBezelBorder;
        _drawsBackground = [coder containsValueForKey:@"NSDrawsBackground"] ? [coder decodeBoolForKey:@"NSDrawsBackground"] : YES;
        _font = [[coder decodeObjectForKey:@"NSFont"] retain];
        _delegate = [coder decodeObjectForKey:@"NSDelegate"];
        NSTabViewItem *selected = [coder decodeObjectForKey:@"NSSelectedTabViewItem"];
        for (NSView *v in [[[self subviews] copy] autorelease])
            [v removeFromSuperviewWithoutNeedingDisplay];
        [self selectTabViewItem:selected ?: [_items firstObject]];
    }
    return self;
}

- (void)dealloc
{
    [_items release];
    [_font release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (id<NSTabViewDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSTabViewDelegate>)delegate { _delegate = delegate; }
- (NSTabViewType)tabViewType { return _type; }
- (void)setTabViewType:(NSTabViewType)type { _type = type; [self _finchPlace]; }
- (NSTabPosition)tabPosition { return _position; }
- (void)setTabPosition:(NSTabPosition)p { _position = p; }
- (NSTabViewBorderType)tabViewBorderType { return _border; }
- (void)setTabViewBorderType:(NSTabViewBorderType)b { _border = b; }
- (BOOL)drawsBackground { return _drawsBackground; }
- (void)setDrawsBackground:(BOOL)f { _drawsBackground = f; }
- (BOOL)allowsTruncatedLabels { return _allowsTruncatedLabels; }
- (void)setAllowsTruncatedLabels:(BOOL)f { _allowsTruncatedLabels = f; }
- (NSFont *)font { return _font ?: [NSFont systemFontOfSize:[NSFont systemFontSize]]; }
- (void)setFont:(NSFont *)font { [_font autorelease]; _font = [font retain]; }
- (NSControlSize)controlSize { return _controlSize; }
- (void)setControlSize:(NSControlSize)s { _controlSize = s; }
- (NSArray<NSTabViewItem *> *)tabViewItems { return [[_items copy] autorelease]; }
- (void)setTabViewItems:(NSArray<NSTabViewItem *> *)items
{
    for (NSTabViewItem *i in [self tabViewItems])
        [self removeTabViewItem:i];
    for (NSTabViewItem *i in items)
        [self addTabViewItem:i];
}
- (NSInteger)numberOfTabViewItems { return (NSInteger)[_items count]; }
- (NSTabViewItem *)selectedTabViewItem { return _selected; }
- (NSInteger)indexOfTabViewItem:(NSTabViewItem *)item
{
    NSUInteger i = [_items indexOfObjectIdenticalTo:item];
    return i == NSNotFound ? NSNotFound : (NSInteger)i;
}
- (NSInteger)indexOfTabViewItemWithIdentifier:(id)identifier
{
    for (NSUInteger i = 0; i < [_items count]; i++)
        if ([[_items[i] identifier] isEqual:identifier])
            return (NSInteger)i;
    return NSNotFound;
}
- (NSTabViewItem *)tabViewItemAtIndex:(NSInteger)index { return _items[(NSUInteger)index]; }

- (NSRect)contentRect
{
    NSRect b = [self bounds];
    switch (_type) {
    case NSNoTabsNoBorder:
        return b;
    case NSNoTabsLineBorder:
    case NSNoTabsBezelBorder:
        return NSInsetRect(b, 10, 10);
    default:
        return NSMakeRect(NSMinX(b) + 10, NSMinY(b) + 33, MAX(0, b.size.width - 20), MAX(0, b.size.height - 46));
    }
}

- (NSSize)minimumSize { return _type == NSNoTabsNoBorder ? NSZeroSize : NSMakeSize(114, 36); }

- (void)_finchPlace
{
    NSView *v = [_selected view];
    if (v && [v superview] == self)
        [v setFrame:[self contentRect]];
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self _finchPlace];
}

- (void)addTabViewItem:(NSTabViewItem *)item
{
    [self insertTabViewItem:item atIndex:(NSInteger)[_items count]];
}

- (void)insertTabViewItem:(NSTabViewItem *)item atIndex:(NSInteger)index
{
    [_items insertObject:item atIndex:(NSUInteger)index];
    [item _finchSetTabView:self];
    if ([(id)_delegate respondsToSelector:@selector(tabViewDidChangeNumberOfTabViewItems:)])
        [_delegate tabViewDidChangeNumberOfTabViewItems:self];
    if (!_selected)
        [self selectTabViewItem:item];
    [self setNeedsDisplay:YES];
}

- (void)removeTabViewItem:(NSTabViewItem *)item
{
    NSUInteger i = [_items indexOfObjectIdenticalTo:item];
    if (i == NSNotFound)
        return;
    [[item retain] autorelease];
    if (item == _selected) {
        [[item view] removeFromSuperview];
        _selected = nil;
    }
    [_items removeObjectAtIndex:i];
    [item _finchSetTabView:nil];
    if (!_selected && [_items count])
        [self selectTabViewItem:_items[MIN(i, [_items count] - 1)]];
    if ([(id)_delegate respondsToSelector:@selector(tabViewDidChangeNumberOfTabViewItems:)])
        [_delegate tabViewDidChangeNumberOfTabViewItems:self];
}

- (void)selectTabViewItem:(NSTabViewItem *)item
{
    if (!item || item == _selected)
        return;
    if ([(id)_delegate respondsToSelector:@selector(tabView:shouldSelectTabViewItem:)] &&
        ![_delegate tabView:self shouldSelectTabViewItem:item])
        return;
    if ([(id)_delegate respondsToSelector:@selector(tabView:willSelectTabViewItem:)])
        [_delegate tabView:self willSelectTabViewItem:item];
    [[_selected view] removeFromSuperview];
    _selected = item;
    NSView *v = [item view];
    [v setFrame:[self contentRect]];
    [self addSubview:v];
    if ([item initialFirstResponder])
        [[self window] makeFirstResponder:[item initialFirstResponder]];
    [self setNeedsDisplay:YES];
    if ([(id)_delegate respondsToSelector:@selector(tabView:didSelectTabViewItem:)])
        [_delegate tabView:self didSelectTabViewItem:item];
    /* the selection bindings take the new selection */
    FinchBindingPush(self, NSSelectedIndexBinding, @([_items indexOfObject:item]));
    FinchBindingPush(self, NSSelectedIdentifierBinding, [item identifier]);
    FinchBindingPush(self, NSSelectedLabelBinding, [item label]);
}

#pragma mark Bindings

/* As Apple's: selectedIndex, selectedIdentifier and selectedLabel pick the tab; no value
   or a marker leaves the selection as it is. */
+ (NSArray *)_finchBuiltinBindings
{
    return [[super _finchBuiltinBindings]
        arrayByAddingObjectsFromArray:@[NSSelectedIndexBinding, NSSelectedIdentifierBinding, NSSelectedLabelBinding]];
}

- (BOOL)_finchHandlesBinding:(NSString *)binding
{
    return [binding isEqual:NSSelectedIndexBinding] || [binding isEqual:NSSelectedIdentifierBinding] ||
           [binding isEqual:NSSelectedLabelBinding] || [super _finchHandlesBinding:binding];
}

- (void)_finchBindingChanged:(_FinchBinding *)b
{
    NSString *name = b->_name;
    if (![self _finchHandlesBinding:name] || ![name hasPrefix:@"selected"]) {
        [super _finchBindingChanged:b];
        return;
    }
    id v = [b valueWithKind:NULL];
    if (!v || NSIsControllerMarker(v))
        return;
    if ([name isEqual:NSSelectedIndexBinding]) {
        NSInteger i = [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : -1;
        if (i >= 0 && i < (NSInteger)[_items count])
            [self selectTabViewItem:_items[(NSUInteger)i]];
    } else if ([name isEqual:NSSelectedIdentifierBinding]) {
        [self selectTabViewItemWithIdentifier:v];
    } else {
        for (NSTabViewItem *item in _items)
            if ([[item label] isEqual:v]) {
                [self selectTabViewItem:item];
                break;
            }
    }
}

- (void)selectTabViewItemAtIndex:(NSInteger)index { [self selectTabViewItem:_items[(NSUInteger)index]]; }
- (void)selectTabViewItemWithIdentifier:(id)identifier
{
    NSInteger i = [self indexOfTabViewItemWithIdentifier:identifier];
    if (i != NSNotFound)
        [self selectTabViewItemAtIndex:i];
}
- (IBAction)takeSelectedTabViewItemFromSender:(id)sender
{
    if ([sender respondsToSelector:@selector(indexOfSelectedItem)])
        [self selectTabViewItemAtIndex:[sender indexOfSelectedItem]];
}
- (IBAction)selectFirstTabViewItem:(id)sender { if ([_items count]) [self selectTabViewItemAtIndex:0]; }
- (IBAction)selectLastTabViewItem:(id)sender { if ([_items count]) [self selectTabViewItemAtIndex:(NSInteger)[_items count] - 1]; }
- (IBAction)selectNextTabViewItem:(id)sender
{
    NSInteger i = [self indexOfTabViewItem:_selected];
    if (i != NSNotFound && i + 1 < (NSInteger)[_items count])
        [self selectTabViewItemAtIndex:i + 1];
}
- (IBAction)selectPreviousTabViewItem:(id)sender
{
    NSInteger i = [self indexOfTabViewItem:_selected];
    if (i != NSNotFound && i > 0)
        [self selectTabViewItemAtIndex:i - 1];
}

/* Finch's tabs: a segmented strip centred at the top, the selected tab in the accent colour. */
- (NSRect)_finchTabRect:(NSUInteger)i
{
    NSDictionary *a = @{NSFontAttributeName : [self font]};
    CGFloat total = 0;
    NSMutableArray *widths = [NSMutableArray array];
    for (NSTabViewItem *item in _items) {
        CGFloat w = ceil([[item label] sizeWithAttributes:a].width) + 24;
        [widths addObject:@(w)];
        total += w;
    }
    CGFloat x = floor(NSMidX([self bounds]) - total / 2);
    for (NSUInteger k = 0; k < i; k++)
        x += [widths[k] doubleValue];
    return NSMakeRect(x, 10, [widths[i] doubleValue], 22);
}

- (void)drawRect:(NSRect)dirty
{
    if (_type == NSNoTabsNoBorder)
        return;
    if (!FinchThemeIsClassic()) {
        [self _finchDrawFieldworkTabs];
        return;
    }
    NSRect content = [self contentRect];
    [[NSColor colorWithWhite:0 alpha:0.03] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(content, -1, -1) xRadius:6 yRadius:6] fill];
    [[NSColor separatorColor] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(content, -0.5, -0.5) xRadius:6 yRadius:6] stroke];
    if (_type > NSRightTabsBezelBorder)
        return;
    for (NSUInteger i = 0; i < [_items count]; i++) {
        NSRect r = [self _finchTabRect:i];
        BOOL sel = _items[i] == _selected;
        [(sel ? [NSColor controlAccentColor] : [NSColor controlColor]) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:5 yRadius:5] fill];
        NSDictionary *a = @{NSFontAttributeName : [self font],
                            NSForegroundColorAttributeName : sel ? FinchOnAccentColor() : [NSColor controlTextColor]};
        NSSize s = [[_items[i] label] sizeWithAttributes:a];
        [[_items[i] label] drawAtPoint:NSMakePoint(NSMidX(r) - s.width / 2, NSMidY(r) - s.height / 2) withAttributes:a];
    }
}

/*
 * Fieldwork's tabs (docs/design/FIELDWORK.md): folder tabs. The content is a slate panel with
 * an outline; the selected tab is a slate card joined to it, its outline open at the bottom;
 * the others are just their labels, in graphite.
 */
- (void)_finchDrawFieldworkTabs
{
    NSRect content = NSInsetRect([self contentRect], -1, -1);
    NSColor *slate = FinchThemePaletteColor(@"slate") ?: [NSColor controlBackgroundColor];
    NSColor *outline = FinchThemePaletteColor(@"outline") ?: [NSColor separatorColor];
    NSBezierPath *panel = [NSBezierPath bezierPathWithRoundedRect:content xRadius:3 yRadius:3];
    [slate setFill];
    [panel fill];
    [outline setStroke];
    [panel setLineWidth:1];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(content, 0.5, 0.5) xRadius:3 yRadius:3] stroke];
    if (_type > NSRightTabsBezelBorder)
        return;
    BOOL flipped = [self isFlipped];
    for (NSUInteger i = 0; i < [_items count]; i++) {
        NSRect r = [self _finchTabRect:i];
        BOOL sel = _items[i] == _selected;
        if (sel) {
            /* the card: down to the panel's edge, over its outline */
            NSRect card = r;
            if (flipped)
                card.size.height = NSMinY(content) - NSMinY(r) + 1;
            else {
                card.origin.y = NSMaxY(content) - 1;
                card.size.height = NSMaxY(r) - card.origin.y;
            }
            NSBezierPath *tab = [NSBezierPath bezierPath];
            CGFloat top = flipped ? NSMinY(card) + 0.5 : NSMaxY(card) - 0.5, base = flipped ? NSMaxY(card) : NSMinY(card);
            [tab moveToPoint:NSMakePoint(NSMinX(card) + 0.5, base)];
            [tab lineToPoint:NSMakePoint(NSMinX(card) + 0.5, top)];
            [tab lineToPoint:NSMakePoint(NSMaxX(card) - 0.5, top)];
            [tab lineToPoint:NSMakePoint(NSMaxX(card) - 0.5, base)];
            [slate setFill];
            NSRectFill(card);
            [outline setStroke];
            [tab setLineWidth:1];
            [tab stroke];
            [[NSColor controlAccentColor] setFill];
            NSRectFill(NSMakeRect(NSMinX(card) + 1, flipped ? NSMinY(card) : NSMaxY(card) - 2, NSWidth(card) - 2, 2));
        }
        NSDictionary *a = @{NSFontAttributeName : [self font],
                            NSForegroundColorAttributeName : sel ? [NSColor labelColor] : [NSColor secondaryLabelColor]};
        NSSize s = [[_items[i] label] sizeWithAttributes:a];
        [[_items[i] label] drawAtPoint:NSMakePoint(NSMidX(r) - s.width / 2, NSMidY(r) - s.height / 2) withAttributes:a];
    }
}

- (NSTabViewItem *)tabViewItemAtPoint:(NSPoint)point
{
    for (NSUInteger i = 0; i < [_items count]; i++)
        if (NSPointInRect(point, [self _finchTabRect:i]))
            return _items[i];
    return nil;
}

- (void)mouseDown:(NSEvent *)event
{
    NSTabViewItem *item = [self tabViewItemAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]];
    if (item)
        [self selectTabViewItem:item];
    else
        [super mouseDown:event];
}

@end

@implementation NSTabViewController {
    NSTabView *_tabView;
    NSMutableArray<NSTabViewItem *> *_items;
    NSTabViewControllerTabStyle _style;
    NSInteger _selected;
}

- (instancetype)initWithNibName:(NSNibName)name bundle:(NSBundle *)bundle
{
    self = [super initWithNibName:name bundle:bundle];
    if (self) {
        _items = [[NSMutableArray alloc] init];
        _selected = -1;
    }
    return self;
}

- (void)dealloc
{
    [_tabView release];
    [_items release];
    [super dealloc];
}

- (NSTabView *)tabView
{
    if (!_tabView) {
        _tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        [_tabView setDelegate:self];
    }
    return _tabView;
}

- (void)setTabView:(NSTabView *)tv
{
    [_tabView autorelease];
    _tabView = [tv retain];
    [tv setDelegate:self];
}

- (void)loadView
{
    NSTabView *tv = [self tabView];
    for (NSTabViewItem *i in _items)
        if ([tv indexOfTabViewItem:i] == NSNotFound)
            [tv addTabViewItem:i];
    [self setView:tv];
}

- (NSTabViewControllerTabStyle)tabStyle { return _style; }
- (void)setTabStyle:(NSTabViewControllerTabStyle)style
{
    _style = style;
    [[self tabView] setTabViewType:style == NSTabViewControllerTabStyleUnspecified ? NSNoTabsNoBorder : NSTopTabsBezelBorder];
}
- (NSArray<NSTabViewItem *> *)tabViewItems { return [[_items copy] autorelease]; }
- (void)setTabViewItems:(NSArray<NSTabViewItem *> *)items
{
    for (NSTabViewItem *i in [self tabViewItems])
        [self removeTabViewItem:i];
    for (NSTabViewItem *i in items)
        [self addTabViewItem:i];
}
- (void)addTabViewItem:(NSTabViewItem *)item { [self insertTabViewItem:item atIndex:(NSInteger)[_items count]]; }
- (void)insertTabViewItem:(NSTabViewItem *)item atIndex:(NSInteger)index
{
    [_items insertObject:item atIndex:(NSUInteger)index];
    if ([item viewController])
        [self addChildViewController:[item viewController]];
    if ([self isViewLoaded])
        [_tabView insertTabViewItem:item atIndex:index];
    if (_selected < 0)
        _selected = 0;
}
- (void)removeTabViewItem:(NSTabViewItem *)item
{
    if ([self isViewLoaded])
        [_tabView removeTabViewItem:item];
    [[item viewController] removeFromParentViewController];
    [_items removeObjectIdenticalTo:item];
}
- (NSTabViewItem *)tabViewItemForViewController:(NSViewController *)viewController
{
    for (NSTabViewItem *i in _items)
        if ([i viewController] == viewController)
            return i;
    return nil;
}
- (NSInteger)selectedTabViewItemIndex { return _selected; }
- (void)setSelectedTabViewItemIndex:(NSInteger)index
{
    _selected = index;
    if ([self isViewLoaded] && index >= 0 && index < (NSInteger)[_items count])
        [_tabView selectTabViewItemAtIndex:index];
}
- (BOOL)tabView:(NSTabView *)tabView shouldSelectTabViewItem:(NSTabViewItem *)item { return YES; }
- (void)tabView:(NSTabView *)tabView willSelectTabViewItem:(NSTabViewItem *)item {}
- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)item
{
    _selected = [tabView indexOfTabViewItem:item];
}

@end
