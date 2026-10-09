/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-menu-test: NSMenu and NSMenuItem without a screen: building
 * menus, indexes, submenus, item properties and states, notifications,
 * validation and autoenabling along the responder chain, key equivalents
 * (performKeyEquivalent: with synthesized key events), delegates,
 * archiving, and a main-menu nib compiled by ibtool (menu-test.xib).
 * Prints everything; run it against Apple's AppKit and Finch's
 * (DYLD_FRAMEWORK_PATH) and diff all but the first line, which says where
 * NSMenu came from.
 *
 *   finch-appkit-menu-test [path to menu-test.nib]
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>

/* CFKeyedArchiverUID is private; archives are read through these. */
typedef const struct __CFKeyedArchiverUID *CFKeyedArchiverUIDRef;
static CFTypeID (*CFKeyedArchiverUIDGetTypeID)(void);
static uint32_t (*CFKeyedArchiverUIDGetValue)(CFKeyedArchiverUIDRef uid);

static void out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
out(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", [s UTF8String]);
}

static NSMutableArray<NSString *> *log_;

static void
note(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
note(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    [log_ addObject:[[NSString alloc] initWithFormat:fmt arguments:ap]];
    va_end(ap);
}

static void
flush(NSString *label)
{
    out(@"%@: %@", label, log_.count ? [log_ componentsJoinedByString:@"; "] : @"-");
    [log_ removeAllObjects];
}

/* A string with its control characters escaped. */
static NSString *
esc(NSString *s)
{
    if (!s)
        return @"(nil)";
    NSMutableString *r = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < 0x20 || c >= 0x7f)
            [r appendFormat:@"\\u%04x", c];
        else
            [r appendFormat:@"%C", c];
    }
    return r;
}

static NSString *
title(NSMenuItem *i)
{
    return i ? (i.isSeparatorItem ? @"---" : i.title) : @"(nil)";
}

static NSString *
sender_name(id s)
{
    if ([s isKindOfClass:[NSMenuItem class]])
        return title(s);
    if ([s isKindOfClass:[NSMenu class]])
        return [NSString stringWithFormat:@"menu %@", [s title]];
    return s ? [s className] : @"nil";
}

static void
try_do(NSString *label, void (^block)(void))
{
    @try {
        block();
        out(@"%@: ok", label);
    } @catch (NSException *e) {
        out(@"%@: %@", label, e.name);
    }
}

#pragma mark - Targets

@interface Target : NSObject <NSMenuItemValidation>
@property (copy) NSString *name;
@property BOOL validates;   /* implements validateMenuItem: answering this */
@property BOOL answer;
@end

@implementation Target
- (void)alpha:(id)sender
{
    note(@"%@ alpha: from %@", self.name, sender_name(sender));
}
- (void)beta:(id)sender
{
    note(@"%@ beta: from %@", self.name, sender_name(sender));
}
- (BOOL)respondsToSelector:(SEL)sel
{
    if (sel == @selector(validateMenuItem:))
        return self.validates;
    return [super respondsToSelector:sel];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    note(@"%@ validate %@", self.name, title(item));
    return self.answer;
}
@end

/* Validates through NSUserInterfaceValidations only. */
@interface UITarget : NSObject <NSUserInterfaceValidations>
@end
@implementation UITarget
- (void)alpha:(id)sender
{
    note(@"uitarget alpha:");
}
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    note(@"uitarget validateUserInterfaceItem %@ tag %ld", NSStringFromSelector(item.action), (long)item.tag);
    return item.tag != 9;
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuItemValidation>
@end
@implementation AppDelegate
- (void)newThing:(id)sender
{
    note(@"delegate newThing: from %@", sender_name(sender));
}
- (void)saveThingAs:(id)sender
{
    note(@"delegate saveThingAs: from %@", sender_name(sender));
}
- (void)gamma:(id)sender
{
    note(@"delegate gamma: from %@", sender_name(sender));
}
- (void)fancy:(id)sender
{
    note(@"delegate fancy: from %@", sender_name(sender));
}
- (void)disabledAction:(id)sender
{
    note(@"delegate disabledAction: from %@", sender_name(sender));
}
- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    note(@"delegate validate %@", title(item));
    return item.action != @selector(disabledAction:);
}
@end

/* The app, logging how actions are resolved. */
@interface TestApp : NSApplication
@property BOOL logTargets;
@end
@implementation TestApp
- (id)targetForAction:(SEL)action to:(id)target from:(id)sender
{
    id t = [super targetForAction:action to:target from:sender];
    if (self.logTargets)
        note(@"targetForAction %@ to %@ from %@ -> %@", NSStringFromSelector(action), target ? [target className] : @"nil",
             sender_name(sender), t ? [t className] : @"nil");
    return t;
}
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender
{
    if (self.logTargets)
        note(@"sendAction %@ to %@", NSStringFromSelector(action), target ? [target className] : @"nil");
    return [super sendAction:action to:target from:sender];
}
@end

@interface MenuDelegate : NSObject <NSMenuDelegate>
@property (strong) NSMenu *recentMenu;
@property (strong) NSMenuItem *fancyItem;
@property (strong) NSPopUpButton *popUp, *pullDown;
@property NSInteger count;   /* items to have, via numberOfItemsInMenu: (-1: don't implement) */
@property BOOL keyEquivalents;  /* implement menuHasKeyEquivalent:... */
@end

@implementation MenuDelegate
- (BOOL)respondsToSelector:(SEL)sel
{
    if (sel == @selector(numberOfItemsInMenu:) || sel == @selector(menu:updateItem:atIndex:shouldCancel:))
        return self.count >= 0;
    if (sel == @selector(menuHasKeyEquivalent:forEvent:target:action:))
        return self.keyEquivalents;
    return [super respondsToSelector:sel];
}
- (void)menuNeedsUpdate:(NSMenu *)menu
{
    note(@"menuNeedsUpdate %@", menu.title);
}
- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu
{
    note(@"numberOfItemsInMenu %@", menu.title);
    return self.count;
}
- (BOOL)menu:(NSMenu *)menu updateItem:(NSMenuItem *)item atIndex:(NSInteger)index shouldCancel:(BOOL)shouldCancel
{
    note(@"updateItem %ld '%@' cancel %d", (long)index, item.title, shouldCancel);
    item.title = [NSString stringWithFormat:@"Dynamic %ld", (long)index];
    if (index == 0) {
        item.keyEquivalent = @"d";
        item.action = @selector(gamma:);
    }
    return index < 2;
}
- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(id *)target action:(SEL *)action
{
    note(@"menuHasKeyEquivalent %@ '%@'", menu.title, event.charactersIgnoringModifiers);
    if ([event.charactersIgnoringModifiers isEqualToString:@"k"]) {
        *target = nil;
        *action = @selector(gamma:);
        return YES;
    }
    return NO;
}
- (void)menuWillOpen:(NSMenu *)menu
{
    note(@"menuWillOpen %@", menu.title);
}
- (void)menuDidClose:(NSMenu *)menu
{
    note(@"menuDidClose %@", menu.title);
}
- (void)copyLink:(id)sender
{
    note(@"copyLink:");
}
- (void)popChanged:(id)sender
{
    note(@"popChanged: from %@ selected %ld", [sender className], (long)[sender indexOfSelectedItem]);
}
@end

static void popups(MenuDelegate *d);

#pragma mark - Dumping

static NSString *
mods(NSEventModifierFlags m)
{
    NSMutableString *s = [NSMutableString string];
    if (m & NSEventModifierFlagControl) [s appendString:@"^"];
    if (m & NSEventModifierFlagOption) [s appendString:@"~"];
    if (m & NSEventModifierFlagShift) [s appendString:@"$"];
    if (m & NSEventModifierFlagCommand) [s appendString:@"@"];
    if (m & NSEventModifierFlagFunction) [s appendString:@"fn"];
    [s appendFormat:@"(%lx)", (unsigned long)m];
    return s;
}

static NSString *
target_name(id t)
{
    if (!t)
        return @"nil";
    if ([t isKindOfClass:[NSMenu class]])
        return [NSString stringWithFormat:@"menu '%@'", [t title]];
    if (t == NSApp)
        return @"NSApp";
    return [t className];
}

static void
dump_menu(NSMenu *m, int depth)
{
    out(@"%*smenu '%@' items %ld autoenables %d supermenu '%@' delegate %@ minWidth %g states %d", depth * 2, "",
        m.title, (long)m.numberOfItems, m.autoenablesItems, m.supermenu.title ?: @"(nil)",
        [(id)m.delegate isKindOfClass:[MenuDelegate class]] ? @"MenuDelegate" : @"nil", m.minimumWidth, m.showsStateColumn);
    for (NSMenuItem *i in m.itemArray) {
        if (i.isSeparatorItem) {
            out(@"%*s  --- enabled %d menu ok %d", depth * 2, "", i.isEnabled, i.menu == m);
            continue;
        }
        out(@"%*s  '%@' key '%@' %@ state %ld tag %ld indent %ld enabled %d hidden %d alt %d action %@ target %@ "
            @"rep %@ tip %@ on %@ mixed %@ off %@ menu ok %d",
            depth * 2, "", i.title, esc(i.keyEquivalent), mods(i.keyEquivalentModifierMask), (long)i.state,
            (long)i.tag, (long)i.indentationLevel, i.isEnabled, i.isHidden, i.isAlternate,
            i.action ? NSStringFromSelector(i.action) : @"nil", target_name(i.target), i.representedObject ?: @"nil",
            i.toolTip ?: @"nil", i.onStateImage.name ?: @"nil", i.mixedStateImage.name ?: @"nil",
            i.offStateImage.name ?: @"nil", i.menu == m);
        if (i.submenu) {
            out(@"%*s    submenu parentItem ok %d supermenu ok %d", depth * 2, "", i.submenu.supermenu == m,
                [m indexOfItemWithSubmenu:i.submenu] == [m indexOfItem:i]);
            dump_menu(i.submenu, depth + 2);
        }
    }
}

static NSEvent *
key(NSString *chars, NSString *ignoring, NSEventModifierFlags flags, unsigned short code)
{
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
                        windowNumber:0 context:nil characters:chars charactersIgnoringModifiers:ignoring
                           isARepeat:NO keyCode:code];
}

#pragma mark - Sections

static void
observe(NSMenu *menu)
{
    static NSMutableArray *keep;  /* observed menus stay alive, so no other menu takes their address */
    if (!keep)
        keep = [NSMutableArray array];
    [keep addObject:menu];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[
             NSMenuDidAddItemNotification, NSMenuDidRemoveItemNotification, NSMenuDidChangeItemNotification,
             NSMenuWillSendActionNotification, NSMenuDidSendActionNotification, NSMenuDidBeginTrackingNotification,
             NSMenuDidEndTrackingNotification
         ]) {
        [nc addObserverForName:name object:menu queue:nil
                    usingBlock:^(NSNotification *n) {
                        NSMutableArray *keys = [NSMutableArray array];
                        for (NSString *k in [n.userInfo.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                            id v = n.userInfo[k];
                            [keys addObject:[NSString stringWithFormat:@"%@=%@", k,
                                                                       [v isKindOfClass:[NSMenuItem class]] ? title(v) : v]];
                        }
                        note(@"%@(%@)%@%@", [n.name stringByReplacingOccurrencesOfString:@"Notification" withString:@""],
                             [n.object title], keys.count ? @" " : @"", [keys componentsJoinedByString:@","]);
                    }];
    }
}

static void
building(void)
{
    out(@"== building");
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Test"];
    observe(m);
    out(@"new: title '%@' items %ld autoenables %d minWidth %g states %d changed %d direction %ld highlighted %@ "
        @"supermenu %@ delegate %@ fontSize %g",
        m.title, (long)m.numberOfItems, m.autoenablesItems, m.minimumWidth, m.showsStateColumn,
        m.menuChangedMessagesEnabled, (long)m.userInterfaceLayoutDirection, m.highlightedItem, m.supermenu, m.delegate,
        m.font.pointSize);
    NSMenuItem *a = [m addItemWithTitle:@"Alpha" action:@selector(alpha:) keyEquivalent:@"a"];
    NSMenuItem *b = [m insertItemWithTitle:@"Beta" action:@selector(beta:) keyEquivalent:@"" atIndex:0];
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *c = [[NSMenuItem alloc] initWithTitle:@"Gamma" action:NULL keyEquivalent:@"G"];
    c.tag = 42;
    c.representedObject = @"rep";
    [m insertItem:c atIndex:1];
    flush(@"notes");
    out(@"items %ld: %@ %@ %@ %@", (long)m.numberOfItems, title([m itemAtIndex:0]), title([m itemAtIndex:1]),
        title([m itemAtIndex:2]), title([m itemAtIndex:3]));
    out(@"indexOfItem a %ld b %ld c %ld title Gamma %ld tag 42 %ld rep %ld target/action %ld submenu nil %ld",
        (long)[m indexOfItem:a], (long)[m indexOfItem:b], (long)[m indexOfItem:c], (long)[m indexOfItemWithTitle:@"Gamma"],
        (long)[m indexOfItemWithTag:42], (long)[m indexOfItemWithRepresentedObject:@"rep"],
        (long)[m indexOfItemWithTarget:nil andAction:@selector(beta:)], (long)[m indexOfItemWithSubmenu:nil]);
    out(@"missing: title %ld tag %ld rep %ld item %ld", (long)[m indexOfItemWithTitle:@"Nope"],
        (long)[m indexOfItemWithTag:7], (long)[m indexOfItemWithRepresentedObject:@"x"],
        (long)[m indexOfItem:[NSMenuItem new]]);
    out(@"itemWithTitle %@ itemWithTag %@", title([m itemWithTitle:@"Alpha"]), title([m itemWithTag:42]));
    try_do(@"itemAtIndex 9", ^{
        [m itemAtIndex:9];
    });
    try_do(@"itemAtIndex -1", ^{
        [m itemAtIndex:-1];
    });
    out(@"item.menu ok %d %d", a.menu == m, c.menu == m);
    out(@"c key '%@' mask %@", c.keyEquivalent, mods(c.keyEquivalentModifierMask));

    /* submenus */
    NSMenu *sub = [[NSMenu alloc] initWithTitle:@"Sub"];
    [sub addItemWithTitle:@"Inner" action:@selector(alpha:) keyEquivalent:@"i"];
    [m setSubmenu:sub forItem:b];
    flush(@"notes");
    out(@"b hasSubmenu %d submenu '%@' supermenu '%@' action %@ target is sub %d parentItem '%@' indexOfItemWithSubmenu %ld",
        b.hasSubmenu, b.submenu.title, sub.supermenu.title, NSStringFromSelector(b.action), b.target == sub,
        title([sub.itemArray[0] parentItem]), (long)[m indexOfItemWithSubmenu:sub]);
    out(@"inner parentItem %@ b parentItem %@", title([sub itemAtIndex:0].parentItem), title(b.parentItem));
    NSMenuItem *d = [[NSMenuItem alloc] initWithTitle:@"Delta" action:NULL keyEquivalent:@""];
    NSMenu *sub2 = [[NSMenu alloc] initWithTitle:@"Sub2"];
    d.submenu = sub2;
    out(@"d.submenu set directly: action %@ target %@ supermenu %@", d.action ? NSStringFromSelector(d.action) : @"nil",
        target_name(d.target), sub2.supermenu.title ?: @"(nil)");
    [m addItem:d];
    out(@"after add: supermenu '%@'", sub2.supermenu.title ?: @"(nil)");
    flush(@"notes");
    try_do(@"add item already in a menu", ^{
        [sub addItem:a];
    });
    try_do(@"submenu already elsewhere", ^{
        NSMenuItem *e = [[NSMenuItem alloc] initWithTitle:@"E" action:NULL keyEquivalent:@""];
        e.submenu = sub;
    });
    try_do(@"insert out of range", ^{
        [m insertItemWithTitle:@"X" action:NULL keyEquivalent:@"" atIndex:99];
    });
    try_do(@"remove out of range", ^{
        [m removeItemAtIndex:99];
    });
    flush(@"notes");

    /* changes */
    a.title = @"Alpha2";
    flush(@"title");
    a.title = @"Alpha2";
    flush(@"same title");
    a.state = NSControlStateValueOn;
    flush(@"state");
    a.state = NSControlStateValueOn;
    flush(@"same state");
    a.enabled = NO;
    flush(@"enabled");
    a.keyEquivalent = @"b";
    flush(@"keyEquivalent");
    a.keyEquivalentModifierMask = NSEventModifierFlagOption;
    flush(@"mask");
    a.tag = 3;
    flush(@"tag");
    a.hidden = YES;
    flush(@"hidden");
    a.image = nil;
    flush(@"image");
    a.toolTip = @"tip";
    flush(@"toolTip");
    a.indentationLevel = 2;
    flush(@"indent");
    a.action = @selector(cut:);
    flush(@"action");
    a.target = a;
    flush(@"target");
    a.representedObject = @"r";
    flush(@"representedObject");
    a.alternate = YES;
    flush(@"alternate");
    a.alternate = NO;
    flush(@"alternate off");
    a.attributedTitle = [[NSAttributedString alloc] initWithString:@"Att"];
    flush(@"attributedTitle");
    a.title = @"Alpha2";
    flush(@"title back");
    a.onStateImage = nil;
    flush(@"onStateImage");
    a.submenu = nil;
    flush(@"submenu nil");
    a.target = nil;
    a.action = @selector(alpha:);
    a.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [log_ removeAllObjects];
    [m itemChanged:a];
    flush(@"itemChanged");
    a.hidden = NO;
    a.enabled = YES;
    [log_ removeAllObjects];

    /* removal */
    [m removeItem:c];
    flush(@"remove notes");
    out(@"c.menu %@", c.menu);
    [m removeItemAtIndex:0];
    out(@"after removing b: sub supermenu %@ b.menu %@", sub.supermenu.title ?: @"(nil)", b.menu);
    flush(@"notes");
    NSArray *items = m.itemArray;
    out(@"itemArray %ld", (long)items.count);
    NSMenuItem *x = [[NSMenuItem alloc] initWithTitle:@"X" action:NULL keyEquivalent:@""];
    m.itemArray = @[ x, a ];
    out(@"after setItemArray: %ld '%@' '%@' x.menu ok %d", (long)m.numberOfItems, title([m itemAtIndex:0]),
        title([m itemAtIndex:1]), x.menu == m);
    flush(@"notes");
    [m removeAllItems];
    out(@"after removeAllItems: %ld a.menu %@", (long)m.numberOfItems, a.menu);
    flush(@"notes");
    m.title = @"Renamed";
    flush(@"rename notes");
}

static void
items(void)
{
    out(@"== items");
    NSMenuItem *i = [[NSMenuItem alloc] init];
    out(@"init: title '%@' key '%@' mask %@ state %ld enabled %d hidden %d alt %d indent %ld tag %ld action %@ target %@ "
        @"image %@ attributed %@ tip %@ view %@ highlighted %d sep %d submenu %@ user '%@' whenHidden %d localization %d "
        @"mirroring %d",
        i.title, i.keyEquivalent, mods(i.keyEquivalentModifierMask), (long)i.state, i.isEnabled, i.isHidden,
        i.isAlternate, (long)i.indentationLevel, (long)i.tag, i.action ? NSStringFromSelector(i.action) : @"nil",
        i.target, i.image, i.attributedTitle, i.toolTip, i.view, i.isHighlighted, i.isSeparatorItem, i.submenu,
        i.userKeyEquivalent, i.allowsKeyEquivalentWhenHidden, i.allowsAutomaticKeyEquivalentLocalization,
        i.allowsAutomaticKeyEquivalentMirroring);
    out(@"images: on %@ %@ mixed %@ %@ off %@", i.onStateImage.name, NSStringFromSize(i.onStateImage.size),
        i.mixedStateImage.name, NSStringFromSize(i.mixedStateImage.size), i.offStateImage);
    out(@"same images across items %d", i.onStateImage == [[NSMenuItem alloc] init].onStateImage);
    i.onStateImage = nil;
    i.mixedStateImage = nil;
    out(@"reset images: on %@ mixed %@", i.onStateImage.name, i.mixedStateImage.name);
    NSMenuItem *s = [NSMenuItem separatorItem];
    out(@"separator: title '%@' sep %d enabled %d key '%@' mask %@ action %@ same %d", s.title, s.isSeparatorItem,
        s.isEnabled, s.keyEquivalent, mods(s.keyEquivalentModifierMask), s.action ? NSStringFromSelector(s.action) : @"nil",
        s == [NSMenuItem separatorItem]);
    s.enabled = YES;
    s.title = @"Not a title";
    out(@"separator set enabled/title: enabled %d title '%@'", s.isEnabled, s.title);
    NSMenuItem *h = [NSMenuItem sectionHeaderWithTitle:@"Section"];
    out(@"section header: title '%@' header %d enabled %d sep %d", h.title, h.isSectionHeader, h.isEnabled,
        h.isSeparatorItem);

    for (NSNumber *n in @[ @-1, @0, @1, @2, @5, @-3 ]) {
        i.state = n.integerValue;
        out(@"state %@ -> %ld", n, (long)i.state);
    }
    for (NSNumber *n in @[ @-1, @3, @15, @16, @100 ]) {
        try_do([NSString stringWithFormat:@"indent %@", n], ^{
            i.indentationLevel = n.integerValue;
        });
        out(@"  -> %ld", (long)i.indentationLevel);
    }
    for (NSNumber *n in @[ @0, @(NSEventModifierFlagShift), @(0xffffffffu), @(NSEventModifierFlagCapsLock) ]) {
        i.keyEquivalentModifierMask = n.unsignedIntegerValue;
        out(@"mask %lx -> %@", n.unsignedLongValue, mods(i.keyEquivalentModifierMask));
    }
    NSString *nothing = nil;
    try_do(@"keyEquivalent nil", ^{
        i.keyEquivalent = nothing;
    });
    out(@"keyEquivalent nil -> '%@'", i.keyEquivalent);
    i.keyEquivalent = @"Ab";
    out(@"keyEquivalent Ab -> '%@'", i.keyEquivalent);

    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:@"Bold"
                                                                           attributes:@{NSForegroundColorAttributeName : NSColor.redColor}];
    i.attributedTitle = as;
    out(@"attributed: title '%@' attributed '%@' attributes %ld", i.title, i.attributedTitle.string,
        (long)[i.attributedTitle attributesAtIndex:0 effectiveRange:NULL].count);
    i.title = @"Plain";
    out(@"title after attributed: '%@' attributed %@", i.title, i.attributedTitle ? i.attributedTitle.string : @"nil");

    NSMenu *m = [[NSMenu alloc] initWithTitle:@"H"];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:@"HS"];
    NSMenuItem *parent = [m addItemWithTitle:@"Parent" action:NULL keyEquivalent:@""];
    [m setSubmenu:sub forItem:parent];
    NSMenuItem *child = [sub addItemWithTitle:@"Child" action:NULL keyEquivalent:@""];
    parent.hidden = YES;
    out(@"hidden ancestor: child hidden %d hiddenOrAncestor %d parent %d", child.isHidden,
        child.isHiddenOrHasHiddenAncestor, parent.isHiddenOrHasHiddenAncestor);

    /* copying */
    NSMenuItem *o = [[NSMenuItem alloc] initWithTitle:@"Orig" action:@selector(alpha:) keyEquivalent:@"o"];
    o.tag = 5;
    o.state = NSControlStateValueMixed;
    o.representedObject = @"r";
    o.toolTip = @"t";
    o.indentationLevel = 3;
    Target *t = [Target new];
    o.target = t;
    NSMenu *om = [[NSMenu alloc] initWithTitle:@"OM"];
    [om addItem:o];
    NSMenu *osub = [[NSMenu alloc] initWithTitle:@"OS"];
    [osub addItemWithTitle:@"In" action:NULL keyEquivalent:@""];
    [om setSubmenu:osub forItem:o];
    NSMenuItem *cp = [o copy];
    out(@"copy: title '%@' key '%@' tag %ld state %ld rep %@ tip %@ indent %ld target same %d action %@ menu %@ "
        @"submenu '%@' same %d items %ld supermenu %@",
        cp.title, cp.keyEquivalent, (long)cp.tag, (long)cp.state, cp.representedObject, cp.toolTip,
        (long)cp.indentationLevel, cp.target == o.target, NSStringFromSelector(cp.action), cp.menu.title,
        cp.submenu.title, cp.submenu == o.submenu, (long)cp.submenu.numberOfItems, cp.submenu.supermenu.title);
    NSMenu *mc = [om copy];
    out(@"menu copy: title '%@' items %ld item same %d item.menu is copy %d submenu same %d supermenu is copy %d",
        mc.title, (long)mc.numberOfItems, [mc itemAtIndex:0] == o, [mc itemAtIndex:0].menu == mc,
        [mc itemAtIndex:0].submenu == osub, [mc itemAtIndex:0].submenu.supermenu == mc);
    out(@"descriptions equal format %d", [[o description] containsString:@"Orig"]);
}

static void
validation(AppDelegate *delegate)
{
    out(@"== validation");
    TestApp *app = (TestApp *)NSApp;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"V"];
    Target *yes = [Target new], *no = [Target new], *plain = [Target new];
    yes.name = @"yes", yes.validates = YES, yes.answer = YES;
    no.name = @"no", no.validates = YES, no.answer = NO;
    plain.name = @"plain";
    NSMenuItem *i0 = [m addItemWithTitle:@"to yes" action:@selector(alpha:) keyEquivalent:@""];
    i0.target = yes;
    NSMenuItem *i1 = [m addItemWithTitle:@"to no" action:@selector(alpha:) keyEquivalent:@""];
    i1.target = no;
    NSMenuItem *i2 = [m addItemWithTitle:@"to plain" action:@selector(alpha:) keyEquivalent:@""];
    i2.target = plain;
    NSMenuItem *i3 = [m addItemWithTitle:@"plain missing" action:@selector(gamma:) keyEquivalent:@""];
    i3.target = plain;
    [m addItemWithTitle:@"chain delegate" action:@selector(newThing:) keyEquivalent:@""];
    [m addItemWithTitle:@"chain disabled" action:@selector(disabledAction:) keyEquivalent:@""];
    [m addItemWithTitle:@"chain app" action:@selector(terminate:) keyEquivalent:@""];
    [m addItemWithTitle:@"chain nobody" action:@selector(nobody:) keyEquivalent:@""];
    [m addItemWithTitle:@"no action" action:NULL keyEquivalent:@""];
    NSMenuItem *sub = [m addItemWithTitle:@"with submenu" action:NULL keyEquivalent:@""];
    NSMenu *sm = [[NSMenu alloc] initWithTitle:@"VS"];
    [sm addItemWithTitle:@"inner nobody" action:@selector(nobody:) keyEquivalent:@""];
    [m setSubmenu:sm forItem:sub];
    UITarget *ui = [UITarget new];
    NSMenuItem *u1 = [m addItemWithTitle:@"ui ok" action:@selector(alpha:) keyEquivalent:@""];
    u1.target = ui;
    NSMenuItem *u2 = [m addItemWithTitle:@"ui tag 9" action:@selector(alpha:) keyEquivalent:@""];
    u2.target = ui;
    u2.tag = 9;
    NSMenuItem *hid = [m addItemWithTitle:@"hidden" action:@selector(nobody:) keyEquivalent:@""];
    hid.hidden = YES;
    [m addItem:[NSMenuItem separatorItem]];
    app.logTargets = YES;
    [m update];
    app.logTargets = NO;
    flush(@"update");
    for (NSMenuItem *i in m.itemArray)
        out(@"  %@ enabled %d", title(i), i.isEnabled);
    out(@"submenu inner enabled %d (not updated with the parent)", [sm itemAtIndex:0].isEnabled);
    [sm update];
    out(@"submenu inner after update %d", [sm itemAtIndex:0].isEnabled);
    [log_ removeAllObjects];

    /* without autoenabling, items keep their state */
    m.autoenablesItems = NO;
    i1.enabled = YES;
    [m itemAtIndex:7].enabled = YES;
    [m update];
    flush(@"update without autoenable");
    out(@"  to no %d chain nobody %d", i1.isEnabled, [m itemAtIndex:7].isEnabled);
    m.autoenablesItems = YES;
    [log_ removeAllObjects];

    /* enabled set by hand is overridden by the next update */
    i1.enabled = YES;
    [m update];
    out(@"to no after manual enable + update: %d", i1.isEnabled);
    [log_ removeAllObjects];
    (void)delegate;
}

static void
key_equivalents(void)
{
    out(@"== key equivalents");
    TestApp *app = (TestApp *)NSApp;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"K"];
    observe(m);
    [m addItemWithTitle:@"New" action:@selector(newThing:) keyEquivalent:@"n"];
    [m addItemWithTitle:@"Save As" action:@selector(saveThingAs:) keyEquivalent:@"S"];
    NSMenuItem *opt = [m addItemWithTitle:@"Option G" action:@selector(gamma:) keyEquivalent:@"g"];
    opt.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    NSMenuItem *shifted = [m addItemWithTitle:@"Shift T" action:@selector(gamma:) keyEquivalent:@"t"];
    shifted.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSMenuItem *ctl = [m addItemWithTitle:@"Control Delete" action:@selector(fancy:) keyEquivalent:@"\b"];
    ctl.keyEquivalentModifierMask = NSEventModifierFlagControl;
    NSMenuItem *bare = [m addItemWithTitle:@"Bare F5" action:@selector(fancy:)
                             keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey]];
    bare.keyEquivalentModifierMask = 0;
    [m addItemWithTitle:@"Disabled" action:@selector(disabledAction:) keyEquivalent:@"e"];
    NSMenuItem *hidden = [m addItemWithTitle:@"Hidden" action:@selector(gamma:) keyEquivalent:@"h"];
    hidden.hidden = YES;
    NSMenuItem *hidden2 = [m addItemWithTitle:@"Hidden allowed" action:@selector(gamma:) keyEquivalent:@"j"];
    hidden2.hidden = YES;
    hidden2.allowsKeyEquivalentWhenHidden = YES;
    NSMenuItem *manual = [m addItemWithTitle:@"Manual off" action:@selector(gamma:) keyEquivalent:@"m"];
    NSMenuItem *targeted = [m addItemWithTitle:@"Targeted" action:@selector(beta:) keyEquivalent:@"y"];
    Target *t = [Target new];
    t.name = @"t";
    targeted.target = t;
    NSMenuItem *subItem = [m addItemWithTitle:@"Sub" action:NULL keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:@"KS"];
    observe(sub);
    [sub addItemWithTitle:@"Deep" action:@selector(gamma:) keyEquivalent:@"p"];
    [m setSubmenu:sub forItem:subItem];
    NSMenuItem *dynItem = [m addItemWithTitle:@"Dyn" action:NULL keyEquivalent:@""];
    NSMenu *dyn = [[NSMenu alloc] initWithTitle:@"Dyn"];
    MenuDelegate *md = [MenuDelegate new];
    md.count = 3;
    dyn.delegate = md;
    [m setSubmenu:dyn forItem:dynItem];
    NSMenuItem *kItem = [m addItemWithTitle:@"KE" action:NULL keyEquivalent:@""];
    NSMenu *kmenu = [[NSMenu alloc] initWithTitle:@"KE"];
    MenuDelegate *kd = [MenuDelegate new];
    kd.count = -1;
    kd.keyEquivalents = YES;
    kmenu.delegate = kd;
    [kmenu addItemWithTitle:@"KE item" action:@selector(gamma:) keyEquivalent:@"u"];
    [m setSubmenu:kmenu forItem:kItem];
    [log_ removeAllObjects];

    struct {
        NSString *label, *chars, *ignoring;
        NSEventModifierFlags flags;
        unsigned short code;
    } keys[] = {
        {@"cmd-n", @"n", @"n", NSEventModifierFlagCommand, 45},
        {@"n", @"n", @"n", 0, 45},
        {@"cmd-shift-n", @"N", @"N", NSEventModifierFlagCommand | NSEventModifierFlagShift, 45},
        {@"cmd-shift-s", @"S", @"S", NSEventModifierFlagCommand | NSEventModifierFlagShift, 1},
        {@"cmd-s", @"s", @"s", NSEventModifierFlagCommand, 1},
        {@"cmd-opt-g", @"©", @"g", NSEventModifierFlagCommand | NSEventModifierFlagOption, 5},
        {@"cmd-g", @"g", @"g", NSEventModifierFlagCommand, 5},
        {@"cmd-shift-t", @"T", @"T", NSEventModifierFlagCommand | NSEventModifierFlagShift, 17},
        {@"cmd-t", @"t", @"t", NSEventModifierFlagCommand, 17},
        {@"ctrl-delete", @"\b", @"\b", NSEventModifierFlagControl, 51},
        {@"f5", [NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey],
         [NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey], NSEventModifierFlagFunction, 96},
        {@"cmd-e (disabled)", @"e", @"e", NSEventModifierFlagCommand, 14},
        {@"cmd-h (hidden)", @"h", @"h", NSEventModifierFlagCommand, 4},
        {@"cmd-j (hidden, allowed)", @"j", @"j", NSEventModifierFlagCommand, 38},
        {@"cmd-y (target)", @"y", @"y", NSEventModifierFlagCommand, 16},
        {@"cmd-p (submenu)", @"p", @"p", NSEventModifierFlagCommand, 35},
        {@"cmd-d (dynamic)", @"d", @"d", NSEventModifierFlagCommand, 2},
        {@"cmd-k (delegate)", @"k", @"k", NSEventModifierFlagCommand, 40},
        {@"cmd-u (delegate menu)", @"u", @"u", NSEventModifierFlagCommand, 32},
        {@"cmd-capslock-n", @"n", @"n", NSEventModifierFlagCommand | NSEventModifierFlagCapsLock, 45},
        {@"cmd-z (none)", @"z", @"z", NSEventModifierFlagCommand, 6},
    };
    for (size_t k = 0; k < sizeof keys / sizeof *keys; k++) {
        if (k == 11)
            manual.enabled = NO;
        BOOL r = [m performKeyEquivalent:key(keys[k].chars, keys[k].ignoring, keys[k].flags, keys[k].code)];
        flush([NSString stringWithFormat:@"%@ -> %d", keys[k].label, r]);
    }
    /* a disabled item that autoenabling would enable; and with autoenabling off */
    m.autoenablesItems = NO;
    manual.enabled = NO;
    BOOL r = [m performKeyEquivalent:key(@"m", @"m", NSEventModifierFlagCommand, 46)];
    flush([NSString stringWithFormat:@"cmd-m (no autoenable, disabled) -> %d", r]);
    manual.enabled = YES;
    r = [m performKeyEquivalent:key(@"m", @"m", NSEventModifierFlagCommand, 46)];
    flush([NSString stringWithFormat:@"cmd-m (no autoenable, enabled) -> %d", r]);
    r = [m performKeyEquivalent:[NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint
                                            modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0
                                                  context:nil characters:@"n" charactersIgnoringModifiers:@"n"
                                                isARepeat:NO keyCode:45]];
    flush([NSString stringWithFormat:@"key up cmd-n -> %d", r]);
    out(@"dyn after: items %ld", (long)dyn.numberOfItems);
    (void)app;
}

static void
actions(void)
{
    out(@"== performActionForItemAtIndex");
    TestApp *app = (TestApp *)NSApp;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"P"];
    observe(m);
    Target *t = [Target new];
    t.name = @"t";
    NSMenuItem *a = [m addItemWithTitle:@"A" action:@selector(alpha:) keyEquivalent:@""];
    a.target = t;
    [m addItemWithTitle:@"B" action:@selector(newThing:) keyEquivalent:@""];
    NSMenuItem *c = [m addItemWithTitle:@"C" action:@selector(alpha:) keyEquivalent:@""];
    c.target = t;
    c.enabled = NO;
    [m addItemWithTitle:@"D" action:@selector(nobody:) keyEquivalent:@""];
    [log_ removeAllObjects];
    app.logTargets = YES;
    for (NSInteger i = 0; i < m.numberOfItems; i++) {
        [m performActionForItemAtIndex:i];
        flush([NSString stringWithFormat:@"perform %ld", (long)i]);
    }
    app.logTargets = NO;
}

static void
delegates(void)
{
    out(@"== delegate");
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"D"];
    MenuDelegate *d = [MenuDelegate new];
    d.count = 3;
    m.delegate = d;
    [m addItemWithTitle:@"Old" action:NULL keyEquivalent:@""];
    [log_ removeAllObjects];
    [m update];
    flush(@"update");
    out(@"items %ld", (long)m.numberOfItems);
    for (NSMenuItem *i in m.itemArray)
        out(@"  '%@' key '%@' action %@", i.title, i.keyEquivalent, i.action ? NSStringFromSelector(i.action) : @"nil");
    out(@"delegate is d %d", m.delegate == d);
}

static void
dump_archive(NSData *data)
{
    CFKeyedArchiverUIDGetTypeID = (CFTypeID(*)(void))dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetTypeID");
    CFKeyedArchiverUIDGetValue = (uint32_t(*)(CFKeyedArchiverUIDRef))dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetValue");
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    NSArray *objects = plist[@"$objects"];
    for (NSDictionary *o in objects) {
        if (![o isKindOfClass:[NSDictionary class]] || !o[@"$class"])
            continue;
        id clsDict = objects[(NSUInteger)CFKeyedArchiverUIDGetValue((__bridge CFKeyedArchiverUIDRef)o[@"$class"])];
        NSString *name = clsDict[@"$classname"];
        if (![name hasPrefix:@"NSMenu"])
            continue;
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in [o.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if ([k isEqualToString:@"$class"])
                continue;
            id v = o[k];
            if (CFGetTypeID((__bridge CFTypeRef)v) == CFKeyedArchiverUIDGetTypeID()) {
                id target = objects[(NSUInteger)CFKeyedArchiverUIDGetValue((__bridge CFKeyedArchiverUIDRef)v)];
                if ([target isKindOfClass:[NSString class]])
                    [parts addObject:[NSString stringWithFormat:@"%@='%@'", k, esc(target)]];
                else
                    [parts addObject:[NSString stringWithFormat:@"%@=@", k]];
            } else {
                [parts addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
            }
        }
        out(@"  %@ %@", name, [parts componentsJoinedByString:@" "]);
    }
}

static void
archiving(void)
{
    out(@"== archiving");
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Top"];
    NSMenuItem *a = [m addItemWithTitle:@"Alpha" action:@selector(copy:) keyEquivalent:@"a"];
    a.tag = 3;
    a.state = NSControlStateValueOn;
    a.indentationLevel = 1;
    a.toolTip = @"tip";
    a.representedObject = @"rep";
    a.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *b = [m addItemWithTitle:@"Beta" action:NULL keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:@"Sub"];
    sub.autoenablesItems = NO;
    [sub addItemWithTitle:@"Inner" action:@selector(paste:) keyEquivalent:@"v"];
    b.submenu = sub;
    b.hidden = YES;
    b.enabled = NO;
    b.alternate = YES;
    NSMenuItem *c = [m addItemWithTitle:@"Gamma" action:@selector(cut:) keyEquivalent:@""];
    c.state = NSControlStateValueMixed;
    c.keyEquivalentModifierMask = 0;
    c.allowsKeyEquivalentWhenHidden = YES;
    c.allowsAutomaticKeyEquivalentMirroring = NO;
    m.minimumWidth = 200;
    m.showsStateColumn = NO;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:m requiringSecureCoding:NO error:NULL];
    dump_archive(data);
    NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL];
    u.requiresSecureCoding = NO;
    NSMenu *back = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    out(@"decoded:");
    dump_menu(back, 1);
    NSMenuItem *bc = [back itemAtIndex:3];
    out(@"  gamma whenHidden %d mirroring %d localization %d", bc.allowsKeyEquivalentWhenHidden,
        bc.allowsAutomaticKeyEquivalentMirroring, bc.allowsAutomaticKeyEquivalentLocalization);
}

static void
nib(NSString *path, AppDelegate *appDelegate)
{
    out(@"== nib");
    NSNib *nib = [[NSNib alloc] initWithNibData:[NSData dataWithContentsOfFile:path] bundle:nil];
    NSArray *top = nil;
    id oldDelegate = NSApp.delegate;
    BOOL ok = [nib instantiateWithOwner:NSApp topLevelObjects:&top];
    out(@"instantiated %d", ok);
    MenuDelegate *d = (MenuDelegate *)NSApp.delegate;
    out(@"app delegate is MenuDelegate %d", [d isKindOfClass:[MenuDelegate class]]);
    NSMutableArray *names = [NSMutableArray array];
    for (id o in top)
        if (o != NSApp)  /* Finch's NSNib leaves out the owner (NSApp here) */
            [names addObject:[o isKindOfClass:[NSMenu class]] ? [NSString stringWithFormat:@"NSMenu '%@'", [o title]]
                                                           : NSStringFromClass([o class])];
    [names sortUsingSelector:@selector(compare:)];
    out(@"top level: %@", [names componentsJoinedByString:@", "]);
    NSMenu *main = NSApp.mainMenu;
    out(@"mainMenu '%@' windowsMenu '%@' servicesMenu '%@' helpMenu '%@'", main.title ?: @"(nil)",
        NSApp.windowsMenu.title ?: @"(nil)", NSApp.servicesMenu.title ?: @"(nil)", NSApp.helpMenu.title ?: @"(nil)");
    out(@"outlets: recentMenu '%@' fancyItem '%@' tip '%@'", d.recentMenu.title, d.fancyItem.title, d.fancyItem.toolTip);
    if ([main.title isEqualToString:@"Main Menu"])
        dump_menu(main, 0);
    for (id o in top)
        if ([o isKindOfClass:[NSMenu class]] && ![[o title] isEqualToString:@"Main Menu"]) {
            dump_menu(o, 0);
            NSMenuItem *i = [o itemAtIndex:0];
            out(@"context target is delegate %d", i.target == d);
            [o performActionForItemAtIndex:0];
            flush(@"context perform");
        }

    /* the nib's key equivalents through the main menu, as NSApp's sendEvent: does */
    NSApp.delegate = oldDelegate;
    [main update];
    [log_ removeAllObjects];
    BOOL r = [main performKeyEquivalent:key(@"n", @"n", NSEventModifierFlagCommand, 45)];
    flush([NSString stringWithFormat:@"main cmd-n -> %d", r]);
    r = [main performKeyEquivalent:key(@"S", @"S", NSEventModifierFlagCommand | NSEventModifierFlagShift, 1)];
    flush([NSString stringWithFormat:@"main cmd-shift-s -> %d", r]);
    r = [main performKeyEquivalent:key(@"\b", @"\b", NSEventModifierFlagControl | NSEventModifierFlagShift, 51)];
    flush([NSString stringWithFormat:@"main ctrl-shift-delete -> %d", r]);
    out(@"after update:");
    for (NSMenuItem *i in [main itemAtIndex:0].submenu.itemArray)  /* the app menu (File's depend on NSDocumentController) */
        out(@"  %@ enabled %d", title(i), i.isEnabled);
    popups(d);
    (void)appDelegate;
}

static void
dump_popup(NSString *label, NSPopUpButton *p)
{
    NSPopUpButtonCell *c = p.cell;
    NSMutableArray *items = [NSMutableArray array];
    for (NSMenuItem *i in p.itemArray)
        [items addObject:[NSString stringWithFormat:@"%@%@%@%@", i.isSeparatorItem ? @"---" : i.title,
                                                    i.state == NSControlStateValueOn ? @"*" : @"",
                                                    i.isEnabled ? @"" : @"(off)", i.isHidden ? @"(hidden)" : @""]];
    out(@"%@: pullsDown %d items [%@] selected %ld '%@' title '%@' tag %ld cell class %@ edge %lu arrow %lu usesItem %d "
        @"alters %d autoenables %d menu ok %d",
        label, p.pullsDown, [items componentsJoinedByString:@", "], (long)p.indexOfSelectedItem,
        p.titleOfSelectedItem ?: @"(nil)", p.title ?: @"(nil)", (long)p.selectedTag, [c className],
        (unsigned long)p.preferredEdge, (unsigned long)c.arrowPosition, c.usesItemFromMenu, c.altersStateOfSelectedItem,
        p.autoenablesItems, p.menu == c.menu);
    NSMenuItem *first = p.itemArray.firstObject;
    if (first)
        out(@"  item action %@ target is cell %d; cell menuItem '%@'", first.action ? NSStringFromSelector(first.action) : @"nil",
            first.target == c, c.menuItem.title ?: @"(nil)");
}

static void
popups(MenuDelegate *d)
{
    out(@"== pop-up buttons");
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 120, 24) pullsDown:NO];
    dump_popup(@"new", p);
    [p addItemWithTitle:@"A"];
    dump_popup(@"add A", p);
    [p addItemsWithTitles:@[ @"B", @"C", @"D" ]];
    [p addItemWithTitle:@"B"];
    dump_popup(@"add B C D B", p);
    [p insertItemWithTitle:@"Z" atIndex:0];
    [p removeItemWithTitle:@"C"];
    [p removeItemAtIndex:1];
    dump_popup(@"insert Z, remove C, remove 1", p);
    [p itemAtIndex:1].tag = 7;
    [p selectItemAtIndex:1];
    dump_popup(@"select 1", p);
    [p selectItemWithTitle:@"B"];
    dump_popup(@"select B", p);
    out(@"selectItemWithTag 7 %d, 99 %d", [p selectItemWithTag:7], [p selectItemWithTag:99]);
    dump_popup(@"after tags", p);
    out(@"indexOfItemWithTitle B %ld tag 7 %ld; itemTitleAtIndex 0 '%@'; titles %@; lastItem '%@'; itemWithTitle Z %d",
        (long)[p indexOfItemWithTitle:@"B"], (long)[p indexOfItemWithTag:7], [p itemTitleAtIndex:0],
        [p.itemTitles componentsJoinedByString:@","], p.lastItem.title, [p itemWithTitle:@"Z"] != nil);
    [p setTitle:@"Z"];
    dump_popup(@"setTitle Z", p);
    [p setTitle:@"New"];
    dump_popup(@"setTitle New", p);
    [p selectItem:nil];
    dump_popup(@"selectItem nil", p);
    [p selectItemAtIndex:0];
    p.target = d;
    p.action = @selector(popChanged:);
    [log_ removeAllObjects];
    [p.menu performActionForItemAtIndex:2];
    flush(@"choose 2 through the menu");
    dump_popup(@"after choosing", p);
    ((NSPopUpButtonCell *)p.cell).altersStateOfSelectedItem = NO;
    [p selectItemAtIndex:1];
    dump_popup(@"no state altering, select 1", p);
    [p removeAllItems];
    dump_popup(@"removeAllItems", p);

    NSPopUpButton *q = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 120, 24) pullsDown:YES];
    [q addItemsWithTitles:@[ @"Title", @"One", @"Two" ]];
    dump_popup(@"pull-down", q);
    [q selectItemAtIndex:2];
    dump_popup(@"pull-down select 2", q);
    q.title = @"Other";
    dump_popup(@"pull-down setTitle", q);
    q.pullsDown = NO;
    dump_popup(@"pull-down -> pop-up", q);
    NSPopUpButtonCell *cell = [[NSPopUpButtonCell alloc] initTextCell:@"X" pullsDown:NO];
    out(@"cell initTextCell: items %ld title '%@' selected %ld", (long)cell.numberOfItems, cell.title,
        (long)cell.indexOfSelectedItem);

    out(@"nib pop-up:");
    dump_popup(@"  popUp", d.popUp);
    out(@"  tag %ld target is delegate %d action %@ frame %@", (long)d.popUp.tag, d.popUp.target == d,
        NSStringFromSelector(d.popUp.action), NSStringFromRect(d.popUp.frame));
    [log_ removeAllObjects];
    [d.popUp.menu performActionForItemAtIndex:2];
    flush(@"  choose Gamma");
    dump_popup(@"  after", d.popUp);
    dump_popup(@"  pullDown", d.pullDown);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSMenu class]));
        log_ = [NSMutableArray array];
        [TestApp sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        NSApp.delegate = delegate;
        out(@"app class %@ mainMenu %@ menuBarVisible %d", [NSApp className], NSApp.mainMenu, [NSMenu menuBarVisible]);
        building();
        items();
        validation(delegate);
        key_equivalents();
        actions();
        delegates();
        archiving();
        nib(argc > 1 ? @(argv[1]) : @"/usr/local/share/finch/menu-test.nib", delegate);
    }
    return 0;
}
