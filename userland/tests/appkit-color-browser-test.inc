/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Included by the containers comparison test. Call FinchColorBrowserTests(). */
@interface FinchBrowserItems : NSObject <NSBrowserDelegate>
@end
@implementation FinchBrowserItems
- (NSInteger)browser:(NSBrowser *)browser numberOfChildrenOfItem:(id)item
{
    return item ? ([item isEqual:@"Folder"] ? 2 : 0) : 3;
}
- (id)browser:(NSBrowser *)browser child:(NSInteger)row ofItem:(id)item
{
    return item ? @[ @"A", @"B" ][row] : @[ @"Folder", @"Leaf", @"Other" ][row];
}
- (BOOL)browser:(NSBrowser *)browser isLeafItem:(id)item
{
    return ![item isEqual:@"Folder"];
}
- (id)browser:(NSBrowser *)browser objectValueForItem:(id)item
{
    return item;
}
@end
@interface FinchBrowserPassive : NSObject <NSBrowserDelegate>
@end
@implementation FinchBrowserPassive
- (NSInteger)browser:(NSBrowser *)browser numberOfRowsInColumn:(NSInteger)column
{
    return column ? 2 : 3;
}
- (void)browser:(NSBrowser *)browser willDisplayCell:(NSBrowserCell *)cell atRow:(NSInteger)row column:(NSInteger)column
{
    cell.stringValue = column ? @[ @"A", @"B" ][row] : @[ @"Folder", @"Leaf", @"Other" ][row];
    cell.leaf = column || row;
}
@end
@interface FinchBrowserActive : NSObject <NSBrowserDelegate>
@end
@implementation FinchBrowserActive
- (void)browser:(NSBrowser *)browser createRowsForColumn:(NSInteger)column inMatrix:(NSMatrix *)matrix
{
    [matrix renewRows:2 columns:1];
    for (NSInteger row = 0; row < 2; row++) {
        NSBrowserCell *cell = [matrix cellAtRow:row column:0];
        cell.stringValue = row ? @"Second" : @"First";
        cell.leaf = YES;
    }
}
@end
@interface FinchColorTarget : NSObject
@property NSInteger actions;
@property NSInteger wellActions;
@end
@implementation FinchColorTarget
- (void)colorChanged:(id)sender
{
    if ([sender isKindOfClass:[NSColorPanel class]])
        self.actions++;
    else
        self.wellActions++;
}
@end
@interface FinchTestColorPicker : NSColorPicker <NSColorPickingCustom>
@end
@implementation FinchTestColorPicker
- (BOOL)supportsMode:(NSColorPanelMode)mode
{
    return mode == NSColorPanelModeRGB;
}
- (NSColorPanelMode)currentMode
{
    return NSColorPanelModeRGB;
}
- (NSView *)provideNewView:(BOOL)initial
{
    return [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 123, 87)] autorelease];
}
- (void)setColor:(NSColor *)color
{
}
@end
static void FinchColorBrowserTests(void)
{
    NSBrowser *browser = [[NSBrowser alloc] initWithFrame:NSMakeRect(0, 0, 400, 220)];
    printf("browser defaults %d %d %d %d %d %d %.0f %ld %d %d %d %d %d %lu %.0f\n", browser.isLoaded,
           browser.reusesColumns, browser.hasHorizontalScroller, browser.autohidesScroller, browser.separatesColumns,
           browser.isTitled, browser.minColumnWidth, (long)browser.maxVisibleColumns, browser.allowsMultipleSelection,
           browser.allowsBranchSelection, browser.allowsEmptySelection, browser.takesTitleFromPreviousColumn,
           browser.sendsActionOnArrowKeys, (unsigned long)browser.columnResizingType, browser.defaultColumnWidth);
    printf("browser initial %ld %ld %ld %ld %ld '%s'\n", (long)browser.lastColumn, (long)browser.selectedColumn,
           (long)browser.numberOfVisibleColumns, (long)browser.firstVisibleColumn, (long)browser.lastVisibleColumn,
           browser.path.UTF8String);
    NSBrowserCell *cell = [[NSBrowserCell alloc] initTextCell:@"Hello"];
    printf("browser cell %d %d %ld %d %d %d %.0f\n", cell.leaf, cell.loaded, (long)cell.state, cell.editable,
           cell.bordered, cell.bezeled, cell.font.pointSize);
    [cell set];
    printf("browser cell set %ld\n", (long)cell.state);
    cell.leaf = YES;
    [cell reset];
    printf("browser cell reset %d %d %ld\n", cell.leaf, cell.loaded, (long)cell.state);
    [cell release];
    FinchBrowserItems *items = [FinchBrowserItems new];
    browser.delegate = items;
    [browser loadColumnZero];
    printf("browser item load %ld %ld %ld %d '%s' %.0f\n", (long)browser.lastColumn, (long)browser.selectedColumn,
           (long)[browser selectedRowInColumn:0], [browser matrixInColumn:0] == nil,
           [[browser itemAtRow:0 inColumn:0] UTF8String], browser.rowHeight);
    [browser selectRow:0 inColumn:0];
    [browser selectRow:1 inColumn:1];
    printf("browser branch %ld %ld '%s' '%s' '%s' %lu\n", (long)browser.lastColumn, (long)browser.selectedColumn,
           browser.path.UTF8String, [[browser parentForItemsInColumn:1] UTF8String],
           [browser.selectedCell stringValue].UTF8String, (unsigned long)browser.selectionIndexPath.length);
    BOOL found = [browser setPath:@"/Folder/A"];
    printf("browser path %d '%s'\n", found, browser.path.UTF8String);
    printf("browser geometry %s %s %s %.0f %.0f\n", NSStringFromRect([browser frameOfColumn:0]).UTF8String,
           NSStringFromRect([browser frameOfInsideOfColumn:0]).UTF8String,
           NSStringFromRect([browser titleFrameOfColumn:0]).UTF8String, browser.titleHeight,
           [browser columnWidthForColumnContentWidth:100] + [browser columnContentWidthForColumnWidth:100]);
    browser.allowsMultipleSelection = YES;
    [browser selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] inColumn:1];
    printf("browser multiple %lu %lu %lu\n", (unsigned long)[browser selectedRowIndexesInColumn:1].count,
           (unsigned long)browser.selectedCells.count, (unsigned long)browser.selectionIndexPaths.count);
    browser.columnResizingType = NSBrowserUserColumnResizing;
    [browser setWidth:150 ofColumn:0];
    printf("browser resize %.0f\n", [browser widthOfColumn:0]);
    [browser release];
    [items release];
    browser = [[NSBrowser alloc] initWithFrame:NSMakeRect(0, 0, 400, 220)];
    FinchBrowserPassive *passive = [FinchBrowserPassive new];
    browser.delegate = passive;
    [browser loadColumnZero];
    NSMatrix *matrix = [browser matrixInColumn:0];
    printf("browser matrix %d %ld %ld %ld %ld '%s'\n", matrix != nil, (long)matrix.numberOfRows,
           (long)matrix.numberOfColumns, (long)matrix.selectedRow, (long)browser.selectedColumn,
           browser.path.UTF8String);
    [browser selectRow:0 inColumn:0];
    [browser selectRow:1 inColumn:1];
    [browser reloadColumn:0];
    printf("browser reload %ld %ld %ld '%s'\n", (long)browser.lastColumn, (long)browser.selectedColumn,
           (long)[browser selectedRowInColumn:0], browser.path.UTF8String);
    [browser release];
    [passive release];
    browser = [[NSBrowser alloc] initWithFrame:NSMakeRect(0, 0, 400, 220)];
    FinchBrowserActive *active = [FinchBrowserActive new];
    browser.delegate = active;
    [browser loadColumnZero];
    [browser selectRow:1 inColumn:0];
    printf("browser active %ld '%s'\n", (long)[browser matrixInColumn:0].numberOfRows,
           [browser.selectedCell stringValue].UTF8String);
    [browser release];
    [active release];
    [NSColorPanel setPickerMode:NSColorPanelModeRGB];
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    panel.mode = NSColorPanelModeRGB;
    panel.showsAlpha = YES;
    panel.continuous = YES;
    FinchColorTarget *target = [FinchColorTarget new];
    [panel setTarget:target];
    [panel setAction:@selector(colorChanged:)];
    panel.color = [NSColor whiteColor];
    target.actions = 0;
    __block NSInteger notes = 0;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSColorPanelColorDidChangeNotification
                                                                    object:panel
                                                                     queue:nil
                                                                usingBlock:^(NSNotification *note) {
                                                                  notes++;
                                                                }];
    panel.color = [NSColor redColor];
    panel.color = [NSColor redColor];
    printf("color change %ld %ld %ld %d %d %d %d %.0f\n", (long)target.actions, (long)notes, (long)panel.mode,
           panel.showsAlpha, panel.continuous, panel.worksWhenModal, panel.becomesKeyOnlyIfNeeded,
           panel.maximumLinearExposure);
    panel.continuous = NO;
    panel.color = [NSColor blueColor];
    printf("color programmatic %ld %ld\n", (long)target.actions, (long)notes);
    NSColorWell *first = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 24)],
                *second = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 24)];
    first.target = second.target = target;
    first.action = second.action = @selector(colorChanged:);
    first.color = [NSColor greenColor];
    second.color = [NSColor redColor];
    [first activate:YES];
    [second activate:NO];
    printf("color wells shared %d %d %d\n", first.active, second.active, [first.color isEqual:second.color]);
    [second activate:YES];
    panel.color = [NSColor blueColor];
    printf("color wells exclusive %d %d %ld %d\n", first.active, second.active, (long)target.wellActions,
           [second.color isEqual:panel.color]);
    [panel close];
    printf("color close %d %d\n", first.active, second.active);
    FinchTestColorPicker *picker =
        [[FinchTestColorPicker alloc] initWithPickerMask:NSColorPanelAllModesMask colorPanel:panel];
    printf("color picker %d %s '%s'\n", picker.colorPanel == panel, NSStringFromSize(picker.minContentSize).UTF8String,
           picker.buttonToolTip.UTF8String);
    [picker release];
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [panel setTarget:nil];
    [panel setAction:NULL];
    [first release];
    [second release];
    [target release];
}
static void FinchColorBrowserNibTest(NSString *path)
{
    NSNib *nib = [[NSNib alloc] initWithNibData:[NSData dataWithContentsOfFile:path] bundle:nil];
    NSArray *objects = nil;
    BOOL loaded = [nib instantiateWithOwner:nil topLevelObjects:&objects];
    NSBrowser *browser = nil;
    NSColorWell *well = nil;
    for (id object in objects)
        if ([object isKindOfClass:[NSView class]])
            for (NSView *view in [object subviews]) {
                if ([view isKindOfClass:[NSBrowser class]])
                    browser = (NSBrowser *)view;
                if ([view isKindOfClass:[NSColorWell class]])
                    well = (NSColorWell *)view;
            }
    printf("browser nib %d %d %.0f %ld %.0f %lu %d %d %d %d\n", loaded, browser != nil, browser.minColumnWidth,
           (long)browser.maxVisibleColumns, browser.defaultColumnWidth, (unsigned long)browser.columnResizingType,
           browser.hasHorizontalScroller, browser.isTitled, browser.allowsEmptySelection, well != nil);
    [nib release];
}
