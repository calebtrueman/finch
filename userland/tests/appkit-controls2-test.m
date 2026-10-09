/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-controls2-test: more of AppKit's controls without a screen:
 * search fields (their buttons, geometry, recents and when they send their
 * action), combo boxes (the item list, a data source, completion), token
 * fields (tokenizing, the delegate, represented objects), date pickers
 * (styles, elements, ranges), path controls (items for URLs, both styles),
 * switches, combo buttons, matrices and forms, their bindings and
 * accessibility, and a nib of them all (appkit-controls2-test.xib,
 * compiled by ibtool). Prints everything; run it against Apple's AppKit
 * and Finch's (DYLD_FRAMEWORK_PATH) and diff all but the first line, which
 * is where NSSearchField came from. Widths that depend on the font (title
 * and text widths) are not printed.
 *
 *   finch-appkit-controls2-test [path to appkit-controls2-test.nib]
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

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

/* Print an expression's value, or the exception it raises. */
#define SHOW(fmt, expr)                                                         \
    do {                                                                        \
        @try {                                                                  \
            out(@"  %s: " fmt, #expr, expr);                                    \
        } @catch (NSException * e) {                                            \
            out(@"  %s: raises %@", #expr, e.name);                             \
        }                                                                       \
    } while (0)

#define DO(...)                                                                 \
    do {                                                                        \
        @try {                                                                  \
            __VA_ARGS__;                                                        \
        } @catch (NSException * e) {                                            \
            out(@"  %s: raises %@", #__VA_ARGS__, e.name);                      \
        }                                                                       \
    } while (0)

#define RECT(expr) SHOW(@"%@", NSStringFromRect(expr))
#define SIZE(expr) SHOW(@"%@", NSStringFromSize(expr))

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
flush_log(NSString *label)
{
    out(@"%@: %@", label, [log_ componentsJoinedByString:@"; "]);
    [log_ removeAllObjects];
}

static NSString *
color_desc(NSColor *c)
{
    if (!c)
        return @"nil";
    if (c.type == NSColorTypeCatalog)
        return [NSString stringWithFormat:@"%@/%@", c.catalogNameComponent, c.colorNameComponent];
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!s)
        return @"(no sRGB)";
    return [NSString stringWithFormat:@"rgba %.3f %.3f %.3f %.3f", s.redComponent, s.greenComponent, s.blueComponent,
                                      s.alphaComponent];
}

static NSString *
font_desc(NSFont *f)
{
    if (!f)
        return @"nil";
    /* Finch uses an open font; compare its role and size, not its name. */
    if ([f.fontName isEqual:[NSFont systemFontOfSize:f.pointSize].fontName])
        return [NSString stringWithFormat:@"system %g", f.pointSize];
    if ([f.fontName isEqual:[NSFont boldSystemFontOfSize:f.pointSize].fontName])
        return [NSString stringWithFormat:@"bold system %g", f.pointSize];
    return [NSString stringWithFormat:@"%@ %g", f.fontName, f.pointSize];
}

static NSString *
obj_desc(id o)
{
    if (!o)
        return @"nil";
    if ([o isKindOfClass:[NSString class]])
        return [NSString stringWithFormat:@"'%@' (string)", o];
    if ([o isKindOfClass:[NSNumber class]])
        return [NSString stringWithFormat:@"%@ (number)", o];
    if ([o isKindOfClass:[NSAttributedString class]])
        return [NSString stringWithFormat:@"'%@' (attributed)", [o string]];
    if ([o isKindOfClass:[NSImage class]])
        return [NSString stringWithFormat:@"image %@", NSStringFromSize([o size])];
    if ([o isKindOfClass:[NSDate class]])
        return [NSString stringWithFormat:@"date %.0f", [o timeIntervalSinceReferenceDate]];
    if ([o isKindOfClass:[NSURL class]])
        return [NSString stringWithFormat:@"url %@", [o absoluteString]];
    if ([o isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id e in o)
            [a addObject:obj_desc(e)];
        return [NSString stringWithFormat:@"[%@]", [a componentsJoinedByString:@", "]];
    }
    return [NSString stringWithFormat:@"a %@", [o class]];
}

static const char *
sel_name(SEL s)
{
    return s ? sel_getName(s) : "(null)";
}

static NSString *
cls(id o)
{
    return o ? NSStringFromClass([o class]) : @"nil";
}

/* Accessibility basics of an element. */
static void
dump_ax(id e)
{
    SHOW(@"%d", [e isAccessibilityElement]);
    SHOW(@"%@", [e accessibilityRole]);
    SHOW(@"%@", [e accessibilitySubrole]);
    SHOW(@"%@", NSAccessibilityRoleDescription([e accessibilityRole], [e accessibilitySubrole]));
}

#pragma mark - Targets

@interface Target : NSObject
@property (copy) NSString *name;
@end

@implementation Target
- (void)log:(SEL)sel sender:(id)sender
{
    NSString *what = @"";
    if ([sender respondsToSelector:@selector(objectValue)])
        what = obj_desc([sender objectValue]);
    note(@"%s from %@ %@", sel_getName(sel), [sender class], what);
}
- (void)act:(id)sender { [self log:_cmd sender:sender]; }
- (void)search:(id)sender { [self log:_cmd sender:sender]; }
- (void)combo:(id)sender { [self log:_cmd sender:sender]; }
- (void)token:(id)sender { [self log:_cmd sender:sender]; }
- (void)date:(id)sender { [self log:_cmd sender:sender]; }
- (void)path:(id)sender { [self log:_cmd sender:sender]; }
- (void)toggle:(id)sender { [self log:_cmd sender:sender]; }
- (void)matrix:(id)sender
{
    NSMatrix *m = sender;
    note(@"matrix: from %@ selected %ld,%ld tag %ld", [sender class], (long)[m selectedRow], (long)[m selectedColumn],
         (long)[[m selectedCell] tag]);
}
- (void)cellAction:(id)sender { note(@"cellAction: from %@", [sender class]); }
- (void)doubleAct:(id)sender { note(@"doubleAct: from %@", [sender class]); }
@end

@interface Owner : NSObject
@property (strong) NSWindow *window;
@end

@implementation Owner
@end

static NSWindow *
offscreen_window(NSView *view)
{
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 300) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:YES];
    w.releasedWhenClosed = NO;
    [w.contentView addSubview:view];
    return w;
}

static void
spin(double seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

#pragma mark - Search fields

@interface SearchDelegate : NSObject <NSSearchFieldDelegate>
@end

@implementation SearchDelegate
- (void)searchFieldDidStartSearching:(NSSearchField *)sender { note(@"didStartSearching '%@'", sender.stringValue); }
- (void)searchFieldDidEndSearching:(NSSearchField *)sender { note(@"didEndSearching '%@'", sender.stringValue); }
- (void)controlTextDidBeginEditing:(NSNotification *)n { note(@"controlTextDidBeginEditing"); }
- (void)controlTextDidChange:(NSNotification *)n { note(@"controlTextDidChange"); }
- (void)controlTextDidEndEditing:(NSNotification *)n { note(@"controlTextDidEndEditing"); }
@end

static void
dump_button_cell(NSString *label, NSButtonCell *b)
{
    out(@"  %@: %@", label, cls(b));
    if (!b)
        return;
    SHOW(@"%s", sel_name([b action]));
    SHOW(@"%@", cls([b target]));
    SHOW(@"%ld", (long)[b bezelStyle]);
    SHOW(@"%d", [b isBordered]);
    SHOW(@"%ld", (long)[b imagePosition]);
    SHOW(@"%ld", (long)[b imageScaling]);
    SHOW(@"%ld", (long)[b highlightsBy]);
    SHOW(@"%ld", (long)[b showsStateBy]);
    SHOW(@"%d", [b isEnabled]);
    SHOW(@"%d", [b image] != nil);
    SHOW(@"'%@'", [b title]);
    SHOW(@"%@", cls([b controlView]));
}

/*
 * The search button is as wide as its image, which Apple's AppKit renders for the main screen:
 * 15 points on a 2x screen, 16 on a 1x one, and small and mini fields start their text after
 * it. Print the geometry as on a 2x main screen, whichever the host has.
 */
static CGFloat search_extra; /* 1 on a 1x main screen */

static NSRect
at_2x(NSRect r, NSSearchFieldCell *c, BOOL search, BOOL text)
{
    if (!search_extra)
        return r;
    if (search) {
        r.size.width -= search_extra;
        NSRect t = [c searchTextRectForBounds:[[c controlView] bounds]];
        if (t.size.width <= 4 && r.origin.x != 6)
            r.origin.x += search_extra;
    }
    if (text && ([c controlSize] == NSControlSizeSmall || [c controlSize] == NSControlSizeMini) && [c searchButtonCell]) {
        r.origin.x -= search_extra;
        r.size.width += search_extra;
    }
    return r;
}

static void
dump_search_geometry(NSSearchField *f)
{
    NSSearchFieldCell *c = f.cell;
    NSRect b = f.bounds;
    RECT(at_2x([c searchTextRectForBounds:b], c, NO, YES));
    RECT(at_2x([c searchButtonRectForBounds:b], c, YES, NO));
    RECT([c cancelButtonRectForBounds:b]);
    RECT(at_2x(f.searchTextBounds, c, NO, YES));
    RECT(at_2x(f.searchButtonBounds, c, YES, NO));
    RECT(f.cancelButtonBounds);
    RECT(at_2x([c drawingRectForBounds:b], c, NO, YES));
    RECT(at_2x([c titleRectForBounds:b], c, NO, YES));
}

static void
test_search_field(void)
{
    out(@"== NSSearchField");
    SHOW(@"%@", [NSSearchField cellClass]);
    NSSearchField *f = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 0, 200, 22)];
    NSSearchFieldCell *c = f.cell;
    search_extra = [c searchButtonRectForBounds:f.bounds].size.width - 15;
    SHOW(@"%@", cls(c));
    SHOW(@"%d", f.isEditable);
    SHOW(@"%d", f.isSelectable);
    SHOW(@"%d", f.isBezeled);
    SHOW(@"%d", f.isBordered);
    SHOW(@"%ld", (long)f.bezelStyle);
    SHOW(@"%d", f.drawsBackground);
    SHOW(@"%d", [c isScrollable]);
    SHOW(@"%d", [c wraps]);
    SHOW(@"%ld", (long)[c lineBreakMode]);
    SHOW(@"%d", [c usesSingleLineMode]);
    SHOW(@"%d", [c sendsActionOnEndEditing]);
    SHOW(@"%d", f.isContinuous);
    SHOW(@"%ld", (long)f.alignment);
    SHOW(@"'%@'", f.placeholderString);
    SHOW(@"%@", obj_desc(f.recentSearches));
    SHOW(@"%@", f.recentsAutosaveName);
    SHOW(@"%ld", (long)f.maximumRecents);
    SHOW(@"%d", f.sendsSearchStringImmediately);
    SHOW(@"%d", f.sendsWholeSearchString);
    SHOW(@"%d", f.centersPlaceholder);
    SHOW(@"%@", cls(f.searchMenuTemplate));
    SHOW(@"%@", cls(f.delegate));
    SHOW(@"%@", color_desc(f.textColor));
    SHOW(@"%@", color_desc(f.backgroundColor));
    SHOW(@"%@", font_desc(f.font));
    SHOW(@"%d", f.acceptsFirstResponder);
    SHOW(@"%d", [c isOpaque]);
    SHOW(@"%ld", (long)[c focusRingType]);
    SHOW(@"%d", f.isAutomaticTextCompletionEnabled);
    SIZE(f.intrinsicContentSize);
    SHOW(@"%g", [c cellSize].height);
    dump_button_cell(@"search button", [c searchButtonCell]);
    dump_button_cell(@"cancel button", [c cancelButtonCell]);
    dump_ax(f);

    out(@"-- geometry");
    dump_search_geometry(f);
    [f setFrameSize:NSMakeSize(120, 30)];
    dump_search_geometry(f);
    [f setFrameSize:NSMakeSize(30, 22)];
    dump_search_geometry(f);
    [f setFrameSize:NSMakeSize(200, 22)];
    f.stringValue = @"text";
    dump_search_geometry(f);
    f.controlSize = NSControlSizeSmall;
    dump_search_geometry(f);
    f.controlSize = NSControlSizeMini;
    dump_search_geometry(f);
    f.controlSize = NSControlSizeLarge;
    dump_search_geometry(f);
    f.controlSize = NSControlSizeRegular;
    f.centersPlaceholder = NO;
    f.stringValue = @"";
    RECT([c searchTextRectForBounds:f.bounds]);
    RECT([f rectForSearchTextWhenCentered:YES]);
    RECT([f rectForSearchTextWhenCentered:NO]);
    RECT(at_2x([f rectForSearchButtonWhenCentered:YES], c, YES, NO));
    RECT(at_2x([f rectForSearchButtonWhenCentered:NO], c, YES, NO));
    RECT([f rectForCancelButtonWhenCentered:YES]);
    RECT([f rectForCancelButtonWhenCentered:NO]);
    DO([c setSearchButtonCell:nil]);
    RECT([c searchTextRectForBounds:f.bounds]);
    DO([c setCancelButtonCell:nil]);
    RECT([c searchTextRectForBounds:f.bounds]);
    DO([c resetSearchButtonCell]);
    DO([c resetCancelButtonCell]);
    dump_button_cell(@"reset search button", [c searchButtonCell]);
    dump_button_cell(@"reset cancel button", [c cancelButtonCell]);
    RECT([c searchTextRectForBounds:f.bounds]);

    out(@"-- properties");
    DO(f.maximumRecents = 300);
    SHOW(@"%ld", (long)f.maximumRecents);
    DO(f.maximumRecents = -3);
    SHOW(@"%ld", (long)f.maximumRecents);
    DO(f.maximumRecents = 3);
    DO(f.recentSearches = (@[ @"a", @"b", @"c", @"d", @"e" ]));
    SHOW(@"%@", obj_desc(f.recentSearches));
    DO(f.recentSearches = @[]);
    SHOW(@"%@", obj_desc(f.recentSearches));
    DO(f.sendsSearchStringImmediately = YES);
    SHOW(@"%d", [c sendsSearchStringImmediately]);
    DO(f.sendsWholeSearchString = YES);
    SHOW(@"%d", [c sendsWholeSearchString]);

    out(@"-- actions");
    Target *t = [Target new];
    SearchDelegate *d = [SearchDelegate new];
    NSSearchField *s = [[NSSearchField alloc] initWithFrame:NSMakeRect(10, 10, 200, 22)];
    s.target = t;
    s.action = @selector(search:);
    s.delegate = d;
    DO(s.stringValue = @"abc");
    flush_log(@"set string");
    DO([s performClick:nil]);
    flush_log(@"performClick");
    DO([s sendAction:s.action to:s.target]);
    flush_log(@"sendAction");
    SHOW(@"%@", obj_desc(s.recentSearches));
    DO([[[s cell] cancelButtonCell] performClick:s]);
    flush_log(@"cancel button performClick");
    SHOW(@"'%@'", s.stringValue);
    DO(s.stringValue = @"xyz");
    DO([[[s cell] searchButtonCell] performClick:s]);
    flush_log(@"search button performClick");
    SHOW(@"'%@'", s.stringValue);

    NSWindow *w = offscreen_window(s);
    DO([w makeFirstResponder:s]);
    flush_log(@"made first responder");
    NSText *ed = s.currentEditor;
    SHOW(@"%d", ed != nil);
    DO([ed insertText:@"q"]);
    flush_log(@"typed (not immediate)");
    spin(0.6);
    flush_log(@"after a while");
    s.sendsSearchStringImmediately = YES;
    DO([ed insertText:@"r"]);
    flush_log(@"typed (immediate)");
    spin(0.6);
    flush_log(@"after a while (immediate)");
    s.sendsSearchStringImmediately = NO;
    s.sendsWholeSearchString = YES;
    DO([ed insertText:@"s"]);
    spin(0.6);
    flush_log(@"typed (whole string)");
    DO([ed selectAll:nil]);
    DO([ed delete:nil]);
    spin(0.6);
    flush_log(@"deleted (whole string)");
    DO([ed insertText:@"done"]);
    DO([ed insertNewline:nil]);
    spin(0.1);
    flush_log(@"return (whole string)");
    SHOW(@"%@", obj_desc(s.recentSearches));
    s.sendsWholeSearchString = NO;
    DO([w makeFirstResponder:nil]);
    spin(0.1);
    flush_log(@"resigned");
    [w close];

    out(@"-- recents");
    NSSearchField *r = [[NSSearchField alloc] initWithFrame:NSMakeRect(10, 10, 200, 22)];
    NSMenu *tmpl = [[NSMenu alloc] initWithTitle:@"Recents"];
    NSMenuItem *it = [tmpl addItemWithTitle:@"Recent Searches" action:NULL keyEquivalent:@""];
    it.tag = NSSearchFieldRecentsTitleMenuItemTag;
    it = [tmpl addItemWithTitle:@"Item" action:NULL keyEquivalent:@""];
    it.tag = NSSearchFieldRecentsMenuItemTag;
    it = [tmpl addItemWithTitle:@"No Recent Searches" action:NULL keyEquivalent:@""];
    it.tag = NSSearchFieldNoRecentsMenuItemTag;
    [tmpl addItem:[NSMenuItem separatorItem]];
    it = [tmpl addItemWithTitle:@"Clear" action:NULL keyEquivalent:@""];
    it.tag = NSSearchFieldClearRecentsMenuItemTag;
    DO(r.searchMenuTemplate = tmpl);
    SHOW(@"%d", r.searchMenuTemplate == tmpl);
    SHOW(@"%ld", (long)r.searchMenuTemplate.numberOfItems);
    r.target = t;
    r.action = @selector(search:);
    r.stringValue = @"first";
    [r sendAction:r.action to:r.target];
    r.stringValue = @"second";
    [r sendAction:r.action to:r.target];
    r.stringValue = @"first";
    [r sendAction:r.action to:r.target];
    r.stringValue = @"";
    [r sendAction:r.action to:r.target];
    flush_log(@"recents actions");
    SHOW(@"%@", obj_desc(r.recentSearches));
    NSSearchField *r2 = [[NSSearchField alloc] initWithFrame:NSMakeRect(10, 10, 200, 22)];
    r2.stringValue = @"third";
    [r2 sendAction:@selector(search:) to:t];
    SHOW(@"%@", obj_desc(r2.recentSearches));
    [log_ removeAllObjects];

    out(@"-- archive");
    NSSearchField *a = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 0, 150, 22)];
    a.placeholderString = @"Look";
    a.maximumRecents = 4;
    a.recentsAutosaveName = @"archived";
    a.sendsWholeSearchString = YES;
    a.centersPlaceholder = NO;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:a requiringSecureCoding:NO error:NULL];
    NSSearchField *b = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSSearchField class] fromData:data error:NULL];
    if (!b)
        b = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    SHOW(@"%@", cls(b));
    SHOW(@"'%@'", b.placeholderString);
    SHOW(@"%ld", (long)b.maximumRecents);
    SHOW(@"%@", b.recentsAutosaveName);
    SHOW(@"%d", b.sendsWholeSearchString);
    SHOW(@"%d", b.sendsSearchStringImmediately);
    SHOW(@"%d", b.centersPlaceholder);
    dump_button_cell(@"archived search button", [b.cell searchButtonCell]);

    out(@"-- toolbar item");
    NSSearchToolbarItem *ti = [[NSSearchToolbarItem alloc] initWithItemIdentifier:@"search"];
    SHOW(@"%@", cls(ti.searchField));
    SHOW(@"%d", [(NSToolbarItem *)ti view] == ti.searchField);
    SHOW(@"'%@'", ti.label);
    SHOW(@"%g", ti.preferredWidthForSearchField);
    SHOW(@"%d", ti.resignsFirstResponderWithCancel);
    SHOW(@"%ld", (long)ti.visibilityPriority);
    SHOW(@"%@", NSStringFromSize(ti.minSize));
    SHOW(@"%@", NSStringFromSize(ti.maxSize));
    NSSearchField *own = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 0, 100, 22)];
    DO(ti.searchField = own);
    SHOW(@"%d", ti.searchField == own);
    SHOW(@"%d", [(NSToolbarItem *)ti view] == own);
    DO(ti.preferredWidthForSearchField = 180);
    SHOW(@"%g", ti.preferredWidthForSearchField);
}

#pragma mark - Combo boxes

@interface ComboSource : NSObject <NSComboBoxDataSource, NSComboBoxDelegate>
@property (strong) NSArray *items;
@end

@implementation ComboSource
- (NSInteger)numberOfItemsInComboBox:(NSComboBox *)c
{
    note(@"numberOfItems");
    return (NSInteger)self.items.count;
}
- (id)comboBox:(NSComboBox *)c objectValueForItemAtIndex:(NSInteger)i
{
    note(@"objectValueForItemAtIndex %ld", (long)i);
    return i >= 0 && i < (NSInteger)self.items.count ? self.items[i] : nil;
}
- (NSUInteger)comboBox:(NSComboBox *)c indexOfItemWithStringValue:(NSString *)s
{
    note(@"indexOfItemWithStringValue '%@'", s);
    NSUInteger i = [self.items indexOfObject:s];
    return i;
}
- (NSString *)comboBox:(NSComboBox *)c completedString:(NSString *)s
{
    note(@"completedString '%@'", s);
    for (NSString *item in self.items)
        if ([item.lowercaseString hasPrefix:s.lowercaseString])
            return item;
    return nil;
}
- (void)comboBoxWillPopUp:(NSNotification *)n { note(@"willPopUp"); }
- (void)comboBoxWillDismiss:(NSNotification *)n { note(@"willDismiss"); }
- (void)comboBoxSelectionDidChange:(NSNotification *)n
{
    note(@"selectionDidChange %ld", (long)[n.object indexOfSelectedItem]);
}
- (void)comboBoxSelectionIsChanging:(NSNotification *)n
{
    note(@"selectionIsChanging %ld", (long)[n.object indexOfSelectedItem]);
}
@end

static void
dump_combo(NSComboBox *c)
{
    SHOW(@"%ld", (long)c.numberOfItems);
    SHOW(@"%ld", (long)c.indexOfSelectedItem);
    SHOW(@"'%@'", c.stringValue);
    SHOW(@"%@", obj_desc(c.objectValue));
    if (!c.usesDataSource) {
        SHOW(@"%@", obj_desc(c.objectValueOfSelectedItem));
        SHOW(@"%@", obj_desc(c.objectValues));
    }
}

static void
test_combo_box(void)
{
    out(@"== NSComboBox");
    SHOW(@"%@", [NSComboBox cellClass]);
    NSComboBox *c = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 150, 26)];
    NSComboBoxCell *cell = c.cell;
    SHOW(@"%@", cls(cell));
    SHOW(@"%d", c.hasVerticalScroller);
    SHOW(@"%@", NSStringFromSize(c.intercellSpacing));
    SHOW(@"%g", c.itemHeight);
    SHOW(@"%ld", (long)c.numberOfVisibleItems);
    SHOW(@"%d", c.isButtonBordered);
    SHOW(@"%d", c.usesDataSource);
    SHOW(@"%d", c.completes);
    SHOW(@"%@", cls(c.dataSource));
    SHOW(@"%@", cls(c.delegate));
    SHOW(@"%d", c.isEditable);
    SHOW(@"%d", c.isSelectable);
    SHOW(@"%d", c.isBezeled);
    SHOW(@"%d", c.isBordered);
    SHOW(@"%d", c.drawsBackground);
    SHOW(@"%ld", (long)c.bezelStyle);
    SHOW(@"%d", [cell isScrollable]);
    SHOW(@"%d", [cell sendsActionOnEndEditing]);
    SHOW(@"%ld", (long)[cell lineBreakMode]);
    SHOW(@"%d", [cell usesSingleLineMode]);
    SHOW(@"%@", font_desc(c.font));
    SHOW(@"%@", color_desc(c.backgroundColor));
    SHOW(@"%d", c.acceptsFirstResponder);
    SHOW(@"%ld", (long)[cell focusRingType]);
    SIZE(c.intrinsicContentSize);
    SHOW(@"%g", [cell cellSize].height);
    for (NSControlSize s = NSControlSizeRegular; s <= NSControlSizeLarge; s++) {
        c.controlSize = s;
        out(@"  size %ld: height %g intrinsic height %g", (long)s, [cell cellSize].height, c.intrinsicContentSize.height);
    }
    c.controlSize = NSControlSizeRegular;
    RECT([cell drawingRectForBounds:c.bounds]);
    RECT([cell titleRectForBounds:c.bounds]);
    dump_ax(c);
    dump_ax(cell);
    dump_combo(c);

    out(@"-- items");
    DO([c addItemWithObjectValue:@"Apple"]);
    DO([c addItemsWithObjectValues:@[ @"Banana", @"Cherry", @"apricot" ]]);
    DO([c insertItemWithObjectValue:@"Avocado" atIndex:1]);
    dump_combo(c);
    SHOW(@"%@", obj_desc([c itemObjectValueAtIndex:2]));
    SHOW(@"%@", obj_desc([c itemObjectValueAtIndex:10]));
    SHOW(@"%ld", (long)[c indexOfItemWithObjectValue:@"Cherry"]);
    SHOW(@"%ld", (long)[c indexOfItemWithObjectValue:@"cherry"]);
    DO([c selectItemAtIndex:2]);
    dump_combo(c);
    DO([c selectItemAtIndex:-1]);
    dump_combo(c);
    DO([c selectItemWithObjectValue:@"Cherry"]);
    dump_combo(c);
    DO([c selectItemWithObjectValue:@"Nope"]);
    dump_combo(c);
    DO([c selectItemAtIndex:1]);
    DO([c deselectItemAtIndex:0]);
    SHOW(@"%ld", (long)c.indexOfSelectedItem);
    DO([c deselectItemAtIndex:1]);
    dump_combo(c);
    DO([c selectItemAtIndex:7]);
    dump_combo(c);
    DO(c.stringValue = @"Banana");
    dump_combo(c);
    DO([c removeItemAtIndex:0]);
    DO([c removeItemWithObjectValue:@"Cherry"]);
    DO([c removeItemWithObjectValue:@"Nope"]);
    dump_combo(c);
    DO([c removeItemAtIndex:9]);
    DO([c insertItemWithObjectValue:@"Z" atIndex:9]);
    dump_combo(c);
    DO([c addItemWithObjectValue:@3]);
    SHOW(@"%ld", (long)[c indexOfItemWithObjectValue:@3]);
    DO([c selectItemAtIndex:c.numberOfItems - 1]);
    dump_combo(c);
    DO([c removeAllItems]);
    dump_combo(c);
    DO([c scrollItemAtIndexToTop:0]);
    DO([c scrollItemAtIndexToVisible:0]);
    DO([c noteNumberOfItemsChanged]);
    DO([c reloadData]);
    DO(c.itemHeight = 20);
    SHOW(@"%g", c.itemHeight);
    DO(c.numberOfVisibleItems = 3);
    SHOW(@"%ld", (long)c.numberOfVisibleItems);
    DO(c.intercellSpacing = NSMakeSize(1, 1));
    SHOW(@"%@", NSStringFromSize(c.intercellSpacing));
    DO(c.buttonBordered = NO);
    SHOW(@"%d", c.isButtonBordered);
    DO(c.hasVerticalScroller = NO);
    SHOW(@"%d", c.hasVerticalScroller);

    out(@"-- delegate notifications");
    ComboSource *src = [ComboSource new];
    src.items = @[ @"Red", @"Green", @"Blue", @"Black" ];
    NSComboBox *n = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 150, 26)];
    n.delegate = src;
    [n addItemsWithObjectValues:src.items];
    [log_ removeAllObjects];
    DO([n selectItemAtIndex:1]);
    flush_log(@"selectItemAtIndex");
    DO([n selectItemAtIndex:1]);
    flush_log(@"same again");
    DO([n deselectItemAtIndex:1]);
    flush_log(@"deselect");
    DO([n selectItemWithObjectValue:@"Blue"]);
    flush_log(@"selectItemWithObjectValue");
    DO(n.stringValue = @"Red");
    flush_log(@"setStringValue");
    SHOW(@"%ld", (long)n.indexOfSelectedItem);

    out(@"-- data source");
    NSComboBox *d = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 150, 26)];
    DO(d.usesDataSource = YES);
    DO(d.dataSource = src);
    flush_log(@"set data source");
    SHOW(@"%ld", (long)d.numberOfItems);
    flush_log(@"numberOfItems");
    SHOW(@"%@", obj_desc([d itemObjectValueAtIndex:2]));
    flush_log(@"itemObjectValueAtIndex");
    DO([d selectItemAtIndex:3]);
    flush_log(@"selectItemAtIndex");
    SHOW(@"'%@'", d.stringValue);
    SHOW(@"%ld", (long)d.indexOfSelectedItem);
    SHOW(@"%@", obj_desc(d.objectValueOfSelectedItem));
    flush_log(@"objectValueOfSelectedItem");
    DO([d addItemWithObjectValue:@"x"]);
    DO([d indexOfItemWithObjectValue:@"Blue"]);
    DO([d objectValues]);
    DO([d selectItemWithObjectValue:@"Green"]);
    [log_ removeAllObjects];
    SHOW(@"%@", [[d cell] completedString:@"gr"]);
    flush_log(@"completedString with data source");
    SHOW(@"%@", [[c cell] completedString:@"b"]);
    NSComboBox *e = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 150, 26)];
    [e addItemsWithObjectValues:@[ @"Alpha", @"beta", @"Beta2", @"gamma" ]];
    SHOW(@"%@", [[e cell] completedString:@"b"]);
    SHOW(@"%@", [[e cell] completedString:@"B"]);
    SHOW(@"%@", [[e cell] completedString:@"Al"]);
    SHOW(@"%@", [[e cell] completedString:@"x"]);
    SHOW(@"%@", [[e cell] completedString:@""]);

    out(@"-- completion while typing");
    e.completes = YES;
    Target *et = [Target new];
    e.target = et;
    e.action = @selector(combo:);
    NSWindow *w = offscreen_window(e);
    [w makeFirstResponder:e];
    NSText *ed = e.currentEditor;
    [ed insertText:@"g"];
    SHOW(@"'%@'", ed.string);
    SHOW(@"%@", NSStringFromRange(ed.selectedRange));
    [ed insertText:@"a"];
    SHOW(@"'%@'", ed.string);
    SHOW(@"%@", NSStringFromRange(ed.selectedRange));
    [ed deleteBackward:nil];
    SHOW(@"'%@'", ed.string);
    SHOW(@"%@", NSStringFromRange(ed.selectedRange));
    [ed insertNewline:nil];
    flush_log(@"return");
    SHOW(@"'%@'", e.stringValue);
    SHOW(@"%ld", (long)e.indexOfSelectedItem);
    [w close];

    out(@"-- archive");
    NSComboBox *a = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 150, 26)];
    [a addItemsWithObjectValues:@[ @"One", @"Two" ]];
    a.numberOfVisibleItems = 7;
    a.completes = YES;
    a.itemHeight = 19;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:a requiringSecureCoding:NO error:NULL];
    NSComboBox *b = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    SHOW(@"%@", cls(b));
    dump_combo(b);
    SHOW(@"%ld", (long)b.numberOfVisibleItems);
    SHOW(@"%d", b.completes);
    SHOW(@"%g", b.itemHeight);
}

#pragma mark - Switches and combo buttons

static void test_switch_and_combo_button(void)
{
    out(@"== NSSwitch");
    NSSwitch *s = [[NSSwitch alloc] initWithFrame:NSMakeRect(0, 0, 80, 30)];
    Target *target = [Target new]; s.target = target; s.action = @selector(toggle:);
    SHOW(@"%@", cls(s.cell)); SHOW(@"%ld", (long)s.state); SHOW(@"%@", obj_desc(s.objectValue));
    SHOW(@"'%@'", s.stringValue); SHOW(@"%d", s.enabled); SHOW(@"%d", s.acceptsFirstResponder); SIZE(s.intrinsicContentSize);
    dump_ax(s); SHOW(@"%@", obj_desc(s.accessibilityValue));
    for (NSInteger size = 0; size < 4; size++) { s.controlSize = size; SIZE(s.intrinsicContentSize); }
    s.state = NSControlStateValueMixed; SHOW(@"%ld", (long)s.state); SHOW(@"%@", obj_desc(s.objectValue));
    s.objectValue = @2; SHOW(@"%ld", (long)s.state); s.stringValue = @""; SHOW(@"%ld", (long)s.state);
    [s performClick:nil]; [s performClick:nil]; flush_log(@"click twice");
    s.enabled = NO; [s performClick:nil]; flush_log(@"disabled click"); s.enabled = YES;
    s.state = NSControlStateValueOn;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:s requiringSecureCoding:NO error:NULL];
    NSSwitch *copy = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    SHOW(@"%@", cls(copy)); SHOW(@"%ld", (long)copy.state);

    out(@"== NSComboButton");
    NSComboButton *b = [[NSComboButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 25)];
    SHOW(@"%@", cls(b.cell)); SHOW(@"'%@'", b.title); SHOW(@"%ld", (long)b.style); SHOW(@"%ld", (long)b.imageScaling);
    SHOW(@"%@", cls(b.menu)); SHOW(@"%ld", (long)b.menu.numberOfItems); SIZE(b.intrinsicContentSize); dump_ax(b);
    b.title = @"Choose"; b.target = target; b.action = @selector(act:); [b performClick:nil]; flush_log(@"primary click");
    for (NSInteger size = 0; size < 4; size++) { b.controlSize = size; SHOW(@"%g", b.intrinsicContentSize.height); }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Extra"];
    [menu addItemWithTitle:@"Other" action:NULL keyEquivalent:@""]; b.menu = menu; b.style = NSComboButtonStyleUnified;
    SHOW(@"%d", b.menu == menu); SHOW(@"%ld", (long)b.style);
    data = [NSKeyedArchiver archivedDataWithRootObject:b requiringSecureCoding:NO error:NULL];
    NSComboButton *bc = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    SHOW(@"'%@'", bc.title); SHOW(@"%ld", (long)bc.style); SHOW(@"%ld", (long)bc.menu.numberOfItems);
}

#pragma mark - Token fields

@interface TokenDelegate : NSObject <NSTokenFieldDelegate>
@end
@implementation TokenDelegate
- (id)tokenField:(NSTokenField *)field representedObjectForEditingString:(NSString *)s { return [@"object:" stringByAppendingString:s]; }
- (NSString *)tokenField:(NSTokenField *)field displayStringForRepresentedObject:(id)object { return [[object description] stringByReplacingOccurrencesOfString:@"object:" withString:@""]; }
- (NSString *)tokenField:(NSTokenField *)field editingStringForRepresentedObject:(id)object { return [[object description] stringByReplacingOccurrencesOfString:@"object:" withString:@""]; }
- (NSArray *)tokenField:(NSTokenField *)field shouldAddObjects:(NSArray *)objects atIndex:(NSUInteger)index
{
    note(@"shouldAdd %@ at %lu", obj_desc(objects), (unsigned long)index);
    NSMutableArray *accepted = [NSMutableArray array];
    for (id object in objects) if (![object isEqual:@"object:skip"]) [accepted addObject:object];
    return accepted;
}
@end

static void test_token_field(void)
{
    out(@"== NSTokenField");
    NSTokenField *f = [[NSTokenField alloc] initWithFrame:NSMakeRect(0, 0, 250, 30)]; NSTokenFieldCell *c = f.cell;
    SHOW(@"%@", cls(c)); SHOW(@"%ld", (long)f.tokenStyle); SHOW(@"%g", f.completionDelay);
    SHOW(@"%d", [f.tokenizingCharacterSet characterIsMember:',']); SHOW(@"%d", [f.tokenizingCharacterSet characterIsMember:';']);
    SHOW(@"%d", [f.tokenizingCharacterSet characterIsMember:'\n']); SHOW(@"%@", obj_desc(f.objectValue)); SHOW(@"'%@'", f.stringValue);
    SHOW(@"%d", c.wraps); SHOW(@"%d", c.scrollable); SHOW(@"%d", c.allowsEditingTextAttributes); SIZE(f.intrinsicContentSize); SIZE(c.cellSize);
    dump_ax(f); dump_ax(c);
    f.stringValue = @" a, b,, c, "; SHOW(@"%@", obj_desc(f.objectValue)); SHOW(@"'%@'", f.stringValue);
    f.objectValue = @[@"one", @"two"]; SHOW(@"%@", obj_desc(f.objectValue)); SHOW(@"'%@'", f.stringValue);
    f.objectValue = @"Hello"; SHOW(@"%@", obj_desc(f.objectValue));
    f.tokenizingCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@";"];
    f.stringValue = @"red; green; blue"; SHOW(@"%@", obj_desc(f.objectValue)); SHOW(@"'%@'", f.stringValue);
    f.tokenizingCharacterSet = nil; f.tokenStyle = NSTokenStyleSquared; f.completionDelay = -1;
    TokenDelegate *delegate = [TokenDelegate new]; f.delegate = delegate;
    f.stringValue = @"first,second"; SHOW(@"%@", obj_desc(f.objectValue)); SHOW(@"'%@'", f.stringValue);
    Target *target = [Target new]; f.target = target; f.action = @selector(token:);
    NSWindow *w = offscreen_window(f); [w makeFirstResponder:f]; NSText *editor = f.currentEditor;
    SHOW(@"%@", [editor.string stringByReplacingOccurrencesOfString:@"\ufffc" withString:@"<token>"]);
    [editor selectAll:nil]; [editor insertText:@"one"]; SHOW(@"%@", obj_desc(f.objectValue));
    [editor insertText:@","]; flush_log(@"token separator");
    SHOW(@"%@", [editor.string stringByReplacingOccurrencesOfString:@"\ufffc" withString:@"<token>"]);
    [editor insertText:@"skip"]; [editor insertText:@","]; flush_log(@"rejected token"); SHOW(@"%@", obj_desc(f.objectValue));
    [editor insertText:@"two"]; [editor insertNewline:nil]; flush_log(@"token return");
    SHOW(@"%@", obj_desc(f.objectValue)); SHOW(@"'%@'", f.stringValue); [w close];
    f.delegate = nil; f.objectValue = @[@"saved", @"values"];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:f requiringSecureCoding:NO error:NULL];
    NSTokenField *copy = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    SHOW(@"%@", obj_desc(copy.objectValue)); SHOW(@"%ld", (long)copy.tokenStyle); SHOW(@"%g", copy.completionDelay);
}

#pragma mark - Date pickers

@interface DateDelegate : NSObject <NSDatePickerCellDelegate>
@end
@implementation DateDelegate
- (void)datePickerCell:(NSDatePickerCell *)cell validateProposedDateValue:(NSDate **)date timeInterval:(NSTimeInterval *)interval
{
    note(@"validate %.0f", [*date timeIntervalSinceReferenceDate]);
}
@end

static void test_date_picker(void)
{
    out(@"== NSDatePicker");
    NSDatePicker *d = [[NSDatePicker alloc] initWithFrame:NSMakeRect(0, 0, 180, 30)]; NSDatePickerCell *c = d.cell;
    SHOW(@"%@", cls(c)); SHOW(@"%ld", (long)d.datePickerStyle); SHOW(@"%ld", (long)d.datePickerMode);
    SHOW(@"%lu", (unsigned long)d.datePickerElements); SHOW(@"%d", d.bezeled); SHOW(@"%d", d.bordered); SHOW(@"%d", d.drawsBackground);
    SHOW(@"%@", color_desc(d.backgroundColor)); SHOW(@"%@", color_desc(d.textColor)); SHOW(@"%@", obj_desc(d.dateValue));
    SHOW(@"%@", cls(d.calendar)); SHOW(@"%@", cls(d.locale)); SHOW(@"%@", cls(d.timeZone)); SHOW(@"%@", obj_desc(d.minDate)); SHOW(@"%@", obj_desc(d.maxDate));
    SHOW(@"%g", d.timeInterval); SHOW(@"%d", d.presentsCalendarOverlay); SHOW(@"%d", c.editable); SHOW(@"%d", c.selectable);
    RECT([c drawingRectForBounds:d.bounds]); RECT([c titleRectForBounds:d.bounds]); dump_ax(d); dump_ax(c);
    d.dateValue = [NSDate dateWithTimeIntervalSinceReferenceDate:1000];
    d.minDate = [NSDate dateWithTimeIntervalSinceReferenceDate:2000]; SHOW(@"%@", obj_desc(d.dateValue));
    d.dateValue = [NSDate dateWithTimeIntervalSinceReferenceDate:500]; SHOW(@"%@", obj_desc(d.dateValue));
    d.maxDate = [NSDate dateWithTimeIntervalSinceReferenceDate:3000]; d.dateValue = [NSDate dateWithTimeIntervalSinceReferenceDate:5000]; SHOW(@"%@", obj_desc(d.dateValue));
    d.timeInterval = -42; SHOW(@"%g", d.timeInterval); d.datePickerMode = NSDatePickerModeRange; d.timeInterval = 86400; SHOW(@"%g", d.timeInterval);
    for (NSInteger style = 0; style < 3; style++) { d.datePickerStyle = style; SHOW(@"%ld", (long)d.datePickerStyle); SHOW(@"%ld", (long)d.datePickerMode); SHOW(@"%g", d.intrinsicContentSize.height); }
    d.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; d.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    d.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]; d.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    SHOW(@"%@", d.locale.localeIdentifier); SHOW(@"%@", d.timeZone.name); SHOW(@"%@", d.calendar.calendarIdentifier);
    DateDelegate *delegate = [DateDelegate new]; d.delegate = delegate;
    d.dateValue = [NSDate dateWithTimeIntervalSinceReferenceDate:2400]; flush_log(@"programmatic date");
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:d requiringSecureCoding:NO error:NULL];
    NSDatePicker *copy = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    SHOW(@"%@", obj_desc(copy.dateValue)); SHOW(@"%@", obj_desc(copy.minDate)); SHOW(@"%@", obj_desc(copy.maxDate));
    SHOW(@"%ld", (long)copy.datePickerStyle); SHOW(@"%ld", (long)copy.datePickerMode); SHOW(@"%lu", (unsigned long)copy.datePickerElements); SHOW(@"%g", copy.timeInterval);
}

#pragma mark - Path controls

static void dump_path(NSPathControl *path)
{
    SHOW(@"%@", obj_desc(path.URL)); SHOW(@"%@", obj_desc(path.objectValue)); SHOW(@"'%@'", path.stringValue);
    SHOW(@"%lu", (unsigned long)path.pathItems.count);
    for (NSPathControlItem *item in path.pathItems) {
        /* The root volume's name depends on the machine. */
        NSString *title = [item.URL.path isEqual:@"/"] ? @"<root>" : item.title;
        out(@"  item '%@' url %@ image %d", title, item.URL.absoluteString, item.image != nil);
    }
}

static void test_path_control(void)
{
    out(@"== NSPathControl");
    NSPathControl *p = [[NSPathControl alloc] initWithFrame:NSMakeRect(0, 0, 300, 25)]; NSPathCell *c = p.cell;
    SHOW(@"%@", cls(c)); SHOW(@"%ld", (long)p.pathStyle); SHOW(@"%d", p.editable); SHOW(@"%d", c.selectable);
    SHOW(@"%@", obj_desc(p.URL)); SHOW(@"%@", obj_desc(p.allowedTypes)); SHOW(@"%@", p.placeholderString); SHOW(@"%@", color_desc(p.backgroundColor));
    SIZE(p.intrinsicContentSize); dump_ax(p); dump_ax(c);
    p.URL = [NSURL fileURLWithPath:@"/Users/example/Documents/report.txt"]; dump_path(p);
    p.pathStyle = NSPathStylePopUp; SHOW(@"%ld", (long)p.pathStyle); SHOW(@"%g", p.intrinsicContentSize.height);
    p.URL = [NSURL URLWithString:@"https://example.com/docs/start?x=1"]; dump_path(p);
    NSPathControlItem *item = [NSPathControlItem new]; item.title = @"Custom";
    p.pathItems = @[item]; SHOW(@"%d", p.pathItems.firstObject == item); SHOW(@"%@", obj_desc(p.URL)); SHOW(@"'%@'", p.pathItems.firstObject.title);
    item.title = @"Changed"; SHOW(@"'%@'", p.pathComponentCells.firstObject.stringValue);
    p.URL = nil; p.placeholderString = @"Pick a folder"; SHOW(@"'%@'", p.placeholderString); SHOW(@"%lu", (unsigned long)p.pathItems.count);
    p.URL = [NSURL fileURLWithPath:@"/example/folders/"]; p.allowedTypes = @[@"public.folder"];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:p requiringSecureCoding:NO error:NULL];
    NSPathControl *copy = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    SHOW(@"%@", obj_desc(copy.URL)); SHOW(@"%ld", (long)copy.pathStyle); SHOW(@"%@", obj_desc(copy.allowedTypes)); SHOW(@"%lu", (unsigned long)copy.pathItems.count);
}

#pragma mark - Matrices and forms

static void dump_matrix_selection(NSMatrix *m)
{
    NSMutableArray *states = [NSMutableArray array]; for (NSCell *cell in m.cells) [states addObject:@(cell.state)];
    out(@"  matrix %ldx%ld selected %ld,%ld count %lu states %@", (long)m.numberOfRows, (long)m.numberOfColumns,
        (long)m.selectedRow, (long)m.selectedColumn, (unsigned long)m.selectedCells.count, obj_desc(states));
}

static void test_matrix_and_form(void)
{
    out(@"== NSMatrix");
    NSMatrix *m = [[NSMatrix alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    SHOW(@"%ld", (long)m.mode); SHOW(@"%ld", (long)m.numberOfRows); SHOW(@"%ld", (long)m.numberOfColumns); SIZE(m.cellSize); SIZE(m.intercellSpacing);
    SHOW(@"%d", m.allowsEmptySelection); SHOW(@"%d", m.autosizesCells); SHOW(@"%d", m.drawsBackground); SHOW(@"%d", m.drawsCellBackground);
    SHOW(@"%d", m.isSelectionByRect); SHOW(@"%d", m.tabKeyTraversesCells); SHOW(@"%d", m.isAutoscroll); SHOW(@"%@", m.cellClass); SHOW(@"%@", cls(m.prototype));
    dump_ax(m);
    for (NSInteger mode = 0; mode < 4; mode++) {
        m = [[NSMatrix alloc] initWithFrame:NSMakeRect(0, 0, 200, 100) mode:mode cellClass:[NSButtonCell class] numberOfRows:2 numberOfColumns:2];
        dump_matrix_selection(m); [m selectCellAtRow:1 column:1]; dump_matrix_selection(m); [m selectCellAtRow:0 column:1]; dump_matrix_selection(m);
        m.allowsEmptySelection = YES; [m deselectAllCells]; dump_matrix_selection(m);
    }
    m = [[NSMatrix alloc] initWithFrame:NSMakeRect(0, 0, 300, 100) mode:NSRadioModeMatrix cellClass:[NSButtonCell class] numberOfRows:2 numberOfColumns:3];
    NSInteger tag = 10; for (NSCell *cell in m.cells) cell.tag = tag++;
    Target *target = [Target new]; m.target = target; m.action = @selector(matrix:); m.doubleAction = @selector(doubleAct:);
    [m selectCellWithTag:14]; [m sendAction]; [m sendDoubleAction]; flush_log(@"matrix actions");
    RECT([m cellFrameAtRow:1 column:2]); NSInteger row = -1, column = -1;
    SHOW(@"%d", [m getRow:&row column:&column forPoint:NSMakePoint(205, 20)]); out(@"  hit %ld,%ld", (long)row, (long)column);
    SHOW(@"%d", [m getRow:&row column:&column forPoint:NSMakePoint(100.5, 20)]);
    [m insertRow:1]; SHOW(@"%ld", (long)m.numberOfRows); SHOW(@"%ld", (long)m.selectedRow);
    [m removeRow:1]; SHOW(@"%ld", (long)m.selectedRow); [m insertColumn:1]; SHOW(@"%ld", (long)m.selectedColumn);
    [m removeColumn:1]; SHOW(@"%ld", (long)m.selectedColumn); SHOW(@"%ld", (long)m.selectedCell.tag);
    m.allowsEmptySelection = YES; [m deselectAllCells]; [m renewRows:3 columns:2]; [m sizeToCells]; SIZE(m.frame.size);
    NSMatrix *list = [[NSMatrix alloc] initWithFrame:NSZeroRect mode:NSListModeMatrix cellClass:[NSButtonCell class] numberOfRows:2 numberOfColumns:3];
    [list selectAll:nil]; dump_matrix_selection(list); [list deselectAllCells]; [list setSelectionFrom:0 to:4 anchor:0 highlight:YES]; dump_matrix_selection(list);
    m.cellSize = NSMakeSize(50, 18); m.intercellSpacing = NSMakeSize(2, 3); [m selectCellAtRow:2 column:1];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:m requiringSecureCoding:NO error:NULL];
    NSMatrix *copy = [NSKeyedUnarchiver unarchiveObjectWithData:data]; dump_matrix_selection(copy); SIZE(copy.cellSize); SIZE(copy.intercellSpacing);

    out(@"== NSForm");
    NSForm *f = [[NSForm alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)];
    SHOW(@"%ld", (long)f.mode); SHOW(@"%ld", (long)f.numberOfRows); SHOW(@"%ld", (long)f.numberOfColumns); SIZE(f.cellSize); SHOW(@"%@", f.cellClass);
    NSFormCell *entry = [f addEntry:@"Name:"]; entry.tag = 10;
    SHOW(@"'%@'", entry.title); SHOW(@"'%@'", entry.stringValue); SHOW(@"%ld", (long)entry.titleAlignment); SHOW(@"%ld", (long)entry.alignment);
    SHOW(@"%@", font_desc(entry.titleFont)); SHOW(@"%@", font_desc(entry.font)); SHOW(@"%d", entry.bezeled); SHOW(@"%d", entry.editable); SHOW(@"%d", entry.selectable);
    SHOW(@"%d", entry.wraps); SHOW(@"%d", entry.scrollable); SHOW(@"%g", entry.preferredTextFieldWidth); SHOW(@"%g", entry.cellSize.height);
    RECT([entry titleRectForBounds:NSMakeRect(0, 0, 200, 30)]); RECT([entry drawingRectForBounds:NSMakeRect(0, 0, 200, 30)]);
    NSFormCell *second = [f addEntry:@"Email:"]; second.tag = 20; [f insertEntry:@"Middle:" atIndex:1];
    SHOW(@"%ld", (long)f.numberOfRows); SHOW(@"%ld", (long)[f indexOfCellWithTag:20]); [f removeEntryAtIndex:1];
    SHOW(@"%ld", (long)[f indexOfCellWithTag:20]); [f setEntryWidth:260]; [f setInterlineSpacing:5]; SIZE(f.cellSize); SIZE(f.intercellSpacing);
    [f setPreferredTextFieldWidth:120]; SHOW(@"%g", f.preferredTextFieldWidth); SHOW(@"%g", second.preferredTextFieldWidth);
    entry.stringValue = @"Ada"; entry.placeholderString = @"Your name"; entry.titleWidth = 60;
    data = [NSKeyedArchiver archivedDataWithRootObject:f requiringSecureCoding:NO error:NULL];
    NSForm *fc = [NSKeyedUnarchiver unarchiveObjectWithData:data]; NSFormCell *ec = [fc cellAtIndex:0];
    SHOW(@"%ld", (long)fc.numberOfRows); SHOW(@"'%@'", ec.title); SHOW(@"'%@'", ec.stringValue); SHOW(@"'%@'", ec.placeholderString); SHOW(@"%g", ec.titleWidth);
}

#pragma mark - Bindings and nibs

@interface ControlsModel : NSObject
@property (strong) id value;
@property (copy) NSArray *items;
@property NSInteger selection;
@end
@implementation ControlsModel
@end

static void test_more_bindings(void)
{
    out(@"== control bindings");
    ControlsModel *model = [ControlsModel new]; model.value = @1;
    NSSwitch *s = [NSSwitch new]; [s bind:NSValueBinding toObject:model withKeyPath:@"value" options:nil];
    SHOW(@"%ld", (long)s.state); [s performClick:nil]; SHOW(@"%@", obj_desc(model.value)); [s unbind:NSValueBinding];
    model.value = [NSDate dateWithTimeIntervalSinceReferenceDate:1200]; NSDatePicker *d = [NSDatePicker new];
    [d bind:NSValueBinding toObject:model withKeyPath:@"value" options:nil]; SHOW(@"%@", obj_desc(d.dateValue));
    model.value = [NSDate dateWithTimeIntervalSinceReferenceDate:2400]; SHOW(@"%@", obj_desc(d.dateValue)); [d unbind:NSValueBinding];
    model.value = [NSURL URLWithString:@"https://example.com/a/b"]; NSPathControl *p = [NSPathControl new];
    [p bind:NSValueBinding toObject:model withKeyPath:@"value" options:nil]; SHOW(@"%@", obj_desc(p.URL)); [p unbind:NSValueBinding];
    model.value = @[@"one", @"two"]; NSTokenField *tokens = [NSTokenField new];
    [tokens bind:NSValueBinding toObject:model withKeyPath:@"value" options:nil]; SHOW(@"%@", obj_desc(tokens.objectValue)); [tokens unbind:NSValueBinding];
    NSComboBox *combo = [NSComboBox new]; model.items = @[@"red", @"green", @"blue"]; model.value = @"green";
    [combo bind:NSContentValuesBinding toObject:model withKeyPath:@"items" options:nil];
    [combo bind:NSValueBinding toObject:model withKeyPath:@"value" options:nil];
    SHOW(@"%ld", (long)combo.numberOfItems); SHOW(@"%ld", (long)combo.indexOfSelectedItem); SHOW(@"'%@'", combo.stringValue);
    [combo selectItemAtIndex:2]; [combo sendAction:combo.action to:combo.target]; SHOW(@"%@", obj_desc(model.value));
    [combo unbind:NSValueBinding]; [combo unbind:NSContentValuesBinding];
    NSMatrix *matrix = [[NSMatrix alloc] initWithFrame:NSZeroRect mode:NSRadioModeMatrix cellClass:[NSButtonCell class] numberOfRows:2 numberOfColumns:1];
    [matrix cellAtRow:0 column:0].tag = 10; [matrix cellAtRow:1 column:0].tag = 20; model.selection = 20;
    [matrix bind:NSSelectedTagBinding toObject:model withKeyPath:@"selection" options:nil]; SHOW(@"%ld", (long)matrix.selectedCell.tag);
    [matrix selectCellAtRow:0 column:0]; [matrix sendAction]; SHOW(@"%ld", (long)model.selection); [matrix unbind:NSSelectedTagBinding];
}

static void test_controls_nib(NSString *path)
{
    out(@"== controls nib");
    NSNib *nib = [[NSNib alloc] initWithNibData:[NSData dataWithContentsOfFile:path] bundle:nil]; NSArray *objects = nil;
    Owner *owner = [Owner new]; BOOL loaded = [nib instantiateWithOwner:owner topLevelObjects:&objects]; SHOW(@"%d", loaded);
    NSWindow *window = nil; for (id object in objects) if ([object isKindOfClass:[NSWindow class]]) window = object;
    for (NSView *view in window.contentView.subviews) {
        out(@"  %@", cls(view));
        if ([view isKindOfClass:[NSSearchField class]]) {
            NSSearchField *s = (id)view; SHOW(@"'%@'", s.placeholderString); SHOW(@"%ld", (long)s.maximumRecents); SHOW(@"%d", s.sendsWholeSearchString); SHOW(@"%d", s.sendsSearchStringImmediately);
        } else if ([view isKindOfClass:[NSComboBox class]]) {
            NSComboBox *c = (id)view; SHOW(@"%@", obj_desc(c.objectValues)); SHOW(@"'%@'", c.stringValue); SHOW(@"%ld", (long)c.numberOfVisibleItems); SHOW(@"%g", c.itemHeight); SIZE(c.intercellSpacing);
        } else if ([view isKindOfClass:[NSTokenField class]]) {
            NSTokenField *t = (id)view; SHOW(@"%@", obj_desc(t.objectValue)); SHOW(@"%ld", (long)t.tokenStyle); SHOW(@"%g", t.completionDelay);
        } else if ([view isKindOfClass:[NSDatePicker class]]) {
            NSDatePicker *d = (id)view; SHOW(@"%@", obj_desc(d.dateValue)); SHOW(@"%@", obj_desc(d.minDate)); SHOW(@"%lu", (unsigned long)d.datePickerElements);
        } else if ([view isKindOfClass:[NSPathControl class]]) {
            NSPathControl *p = (id)view; SHOW(@"%@", obj_desc(p.URL)); SHOW(@"%ld", (long)p.pathStyle); SHOW(@"%lu", (unsigned long)p.pathItems.count);
        } else if ([view isKindOfClass:[NSSwitch class]]) SHOW(@"%ld", (long)[(NSSwitch *)view state]);
        else if ([view isKindOfClass:[NSForm class]]) {
            NSForm *f = (id)view; SHOW(@"%ld", (long)f.numberOfRows); SHOW(@"'%@'", [(NSFormCell *)[f cellAtIndex:0] title]); SHOW(@"'%@'", [(NSFormCell *)[f cellAtIndex:1] title]);
        } else if ([view isKindOfClass:[NSMatrix class]]) {
            NSMatrix *m = (id)view; SHOW(@"%ld", (long)m.mode); SHOW(@"%ld", (long)m.numberOfRows); SHOW(@"%ld", (long)m.selectedRow); SHOW(@"%ld", (long)m.selectedCell.tag); SIZE(m.intercellSpacing);
        }
    }
    [window close];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSSearchField class]));
        [NSApplication sharedApplication];
        log_ = [NSMutableArray array];
        test_search_field();
        test_combo_box();
        test_switch_and_combo_button();
        test_token_field();
        test_date_picker();
        test_path_control();
        test_matrix_and_form();
        test_more_bindings();
        if (argc > 1) test_controls_nib([NSString stringWithUTF8String:argv[1]]);
    }
    return 0;
}
