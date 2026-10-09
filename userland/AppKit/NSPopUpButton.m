/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSPopUpButton: a button showing a menu, the pop-up or pull-down kind; its
 * NSPopUpButtonCell holds the menu and does the work.
 */
#import "NSMenu_Finch.h"

@implementation NSPopUpButton

+ (Class)cellClass
{
    return [NSPopUpButtonCell class];
}

static NSPopUpButtonCell *
cell_of(NSPopUpButton *b)
{
    id c = [b cell];
    return [c isKindOfClass:[NSPopUpButtonCell class]] ? c : nil;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    return [self initWithFrame:frame pullsDown:NO];
}

- (instancetype)initWithFrame:(NSRect)frame pullsDown:(BOOL)flag
{
    self = [super initWithFrame:frame];
    if (self) {
        if (![cell_of(self) isKindOfClass:[NSPopUpButtonCell class]]) {
            NSPopUpButtonCell *c = [[NSPopUpButtonCell alloc] initTextCell:@"" pullsDown:flag];
            [self setCell:c];
            [c release];
        }
        [cell_of(self) setPullsDown:flag];
    }
    return self;
}

+ (instancetype)popUpButtonWithMenu:(NSMenu *)menu target:(id)target action:(SEL)action
{
    NSPopUpButton *b = [[[self alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
    [b setMenu:menu];
    [b setTarget:target];
    [b setAction:action];
    [b sizeToFit];
    return b;
}

+ (instancetype)pullDownButtonWithTitle:(NSString *)title image:(NSImage *)image menu:(NSMenu *)menu
{
    NSPopUpButton *b = [[[self alloc] initWithFrame:NSZeroRect pullsDown:YES] autorelease];
    NSMenuItem *first = [[NSMenuItem alloc] initWithTitle:title ?: @"" action:NULL keyEquivalent:@""];
    [first setImage:image];
    [first setHidden:YES];
    [menu insertItem:first atIndex:0];
    [first release];
    [b setMenu:menu];
    [b setUsesItemFromMenu:NO];
    [b sizeToFit];
    return b;
}

+ (instancetype)pullDownButtonWithTitle:(NSString *)title menu:(NSMenu *)menu
{
    NSImage *none = nil;
    return [self pullDownButtonWithTitle:title image:none menu:menu];
}

+ (instancetype)pullDownButtonWithImage:(NSImage *)image menu:(NSMenu *)menu
{
    return [self pullDownButtonWithTitle:@"" image:image menu:menu];
}

/* The button's menu is its cell's (not a contextual menu). */
- (NSMenu *)menu { return [cell_of(self) menu]; }
- (void)setMenu:(NSMenu *)menu { [cell_of(self) setMenu:menu]; [self setNeedsDisplay:YES]; }
- (NSMenu *)menuForEvent:(NSEvent *)event { return nil; }

- (BOOL)pullsDown { return [cell_of(self) pullsDown]; }
- (void)setPullsDown:(BOOL)flag { [cell_of(self) setPullsDown:flag]; [self setNeedsDisplay:YES]; }
- (BOOL)autoenablesItems { return [cell_of(self) autoenablesItems]; }
- (void)setAutoenablesItems:(BOOL)flag { [cell_of(self) setAutoenablesItems:flag]; }
- (NSRectEdge)preferredEdge { return [cell_of(self) preferredEdge]; }
- (void)setPreferredEdge:(NSRectEdge)edge { [cell_of(self) setPreferredEdge:edge]; }
- (BOOL)usesItemFromMenu { return [cell_of(self) usesItemFromMenu]; }
- (void)setUsesItemFromMenu:(BOOL)flag { [cell_of(self) setUsesItemFromMenu:flag]; }
- (BOOL)altersStateOfSelectedItem { return [cell_of(self) altersStateOfSelectedItem]; }
- (void)setAltersStateOfSelectedItem:(BOOL)flag { [cell_of(self) setAltersStateOfSelectedItem:flag]; }

- (void)addItemWithTitle:(NSString *)title { [cell_of(self) addItemWithTitle:title]; [self setNeedsDisplay:YES]; }
- (void)addItemsWithTitles:(NSArray<NSString *> *)titles { [cell_of(self) addItemsWithTitles:titles]; [self setNeedsDisplay:YES]; }

- (void)insertItemWithTitle:(NSString *)title atIndex:(NSInteger)index
{
    [cell_of(self) insertItemWithTitle:title atIndex:index];
    [self setNeedsDisplay:YES];
}

- (void)removeItemWithTitle:(NSString *)title { [cell_of(self) removeItemWithTitle:title]; [self setNeedsDisplay:YES]; }
- (void)removeItemAtIndex:(NSInteger)index { [cell_of(self) removeItemAtIndex:index]; [self setNeedsDisplay:YES]; }
- (void)removeAllItems { [cell_of(self) removeAllItems]; [self setNeedsDisplay:YES]; }
- (NSArray<NSMenuItem *> *)itemArray { return [cell_of(self) itemArray]; }
- (NSInteger)numberOfItems { return [cell_of(self) numberOfItems]; }
- (NSInteger)indexOfItem:(NSMenuItem *)item { return [cell_of(self) indexOfItem:item]; }
- (NSInteger)indexOfItemWithTitle:(NSString *)title { return [cell_of(self) indexOfItemWithTitle:title]; }
- (NSInteger)indexOfItemWithTag:(NSInteger)tag { return [cell_of(self) indexOfItemWithTag:tag]; }
- (NSInteger)indexOfItemWithRepresentedObject:(id)obj { return [cell_of(self) indexOfItemWithRepresentedObject:obj]; }
- (NSInteger)indexOfItemWithTarget:(id)t andAction:(SEL)a { return [cell_of(self) indexOfItemWithTarget:t andAction:a]; }
- (NSMenuItem *)itemAtIndex:(NSInteger)index { return [cell_of(self) itemAtIndex:index]; }
- (NSMenuItem *)itemWithTitle:(NSString *)title { return [cell_of(self) itemWithTitle:title]; }
- (NSMenuItem *)lastItem { return [cell_of(self) lastItem]; }
- (void)selectItem:(NSMenuItem *)item { [cell_of(self) selectItem:item]; [self setNeedsDisplay:YES]; }
- (void)selectItemAtIndex:(NSInteger)index { [cell_of(self) selectItemAtIndex:index]; [self setNeedsDisplay:YES]; }
- (void)selectItemWithTitle:(NSString *)title { [cell_of(self) selectItemWithTitle:title]; [self setNeedsDisplay:YES]; }

- (BOOL)selectItemWithTag:(NSInteger)tag
{
    BOOL ok = [cell_of(self) selectItemWithTag:tag];
    [self setNeedsDisplay:YES];
    return ok;
}

- (NSString *)title { return [cell_of(self) title]; }
- (void)setTitle:(NSString *)title { [cell_of(self) setTitle:title]; [self setNeedsDisplay:YES]; }
- (NSMenuItem *)selectedItem { return [cell_of(self) selectedItem]; }
- (NSInteger)indexOfSelectedItem { return [cell_of(self) indexOfSelectedItem]; }
- (NSInteger)selectedTag { return [cell_of(self) selectedTag]; }
- (void)synchronizeTitleAndSelectedItem { [cell_of(self) synchronizeTitleAndSelectedItem]; [self setNeedsDisplay:YES]; }
- (NSString *)itemTitleAtIndex:(NSInteger)index { return [cell_of(self) itemTitleAtIndex:index]; }
- (NSArray<NSString *> *)itemTitles { return [cell_of(self) itemTitles]; }
- (NSString *)titleOfSelectedItem { return [cell_of(self) titleOfSelectedItem]; }

- (void)mouseDown:(NSEvent *)event
{
    NSPopUpButtonCell *c = cell_of(self);
    if (!c || ![self isEnabled])
        return;
    [c trackMouse:event inRect:[self bounds] ofView:self untilMouseUp:YES];
}

- (void)performClick:(id)sender
{
    [cell_of(self) performClickWithFrame:[self bounds] inView:self];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if ([self isEnabled] && [[self menu] performKeyEquivalent:event])
        return YES;
    return [super performKeyEquivalent:event];
}

@end
