/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-tables-test: NSTableView (cell- and view-based), NSTableColumn, the header and
 * row views, NSOutlineView, NSCollectionView and its layouts, table bindings and a nib of them,
 * without a screen. Prints everything; run against Apple's AppKit and Finch's
 * (DYLD_FRAMEWORK_PATH) and diff all but the first line.
 *
 *   finch-appkit-tables-test [path to appkit-tables-test.nib]
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static const char *
S(NSRect r)
{
    return NSStringFromRect(r).UTF8String;
}

static const char *
Z(NSSize s)
{
    return NSStringFromSize(s).UTF8String;
}

static const char *
IX(NSIndexSet *s)
{
    NSMutableString *m = [NSMutableString stringWithString:@"["];
    [s enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        [m appendFormat:@"%s%lu", m.length > 1 ? " " : "", (unsigned long)i];
    }];
    [m appendString:@"]"];
    return m.UTF8String;
}

static const char *
D(id o)
{
    return o ? [[o description] UTF8String] : "(nil)";
}

static const char *
CN(id o)
{
    return o ? class_getName([o class]) : "nil";
}

#pragma mark - Data sources

@interface Rows : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property NSInteger count;
@property NSMutableArray *log;
@property BOOL logging, variableHeights, groups, refuseOdd, viewBased;
@property (copy) NSIndexSet * (^proposal)(NSIndexSet *);
@end

@implementation Rows
- (instancetype)init
{
    self = [super init];
    _log = [NSMutableArray array];
    return self;
}
- (void)note:(NSString *)s
{
    if (_logging)
        printf("    %s\n", s.UTF8String);
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t
{
    return _count;
}
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    return [NSString stringWithFormat:@"%@%ld", c.identifier, (long)r];
}
- (void)tableView:(NSTableView *)t setObjectValue:(id)v forTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    [self note:[NSString stringWithFormat:@"set %@ %@ %ld", v, c.identifier, (long)r]];
}
- (void)tableView:(NSTableView *)t sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old
{
    NSMutableString *m = [NSMutableString string];
    for (NSSortDescriptor *d in old)
        [m appendFormat:@" %@%c", d.key, d.ascending ? '+' : '-'];
    NSMutableString *n = [NSMutableString string];
    for (NSSortDescriptor *d in t.sortDescriptors)
        [n appendFormat:@" %@%c", d.key, d.ascending ? '+' : '-'];
    printf("    sortDescriptorsDidChange old [%s ] new [%s ]\n", m.UTF8String, n.UTF8String);
}
- (CGFloat)tableView:(NSTableView *)t heightOfRow:(NSInteger)r
{
    return _variableHeights ? 10 + 5 * r : t.rowHeight;
}
- (BOOL)tableView:(NSTableView *)t isGroupRow:(NSInteger)r
{
    return _groups && r % 3 == 0;
}
- (BOOL)tableView:(NSTableView *)t shouldSelectRow:(NSInteger)r
{
    [self note:[NSString stringWithFormat:@"shouldSelectRow %ld", (long)r]];
    return !(_refuseOdd && r % 2);
}
- (NSIndexSet *)tableView:(NSTableView *)t selectionIndexesForProposedSelection:(NSIndexSet *)p
{
    return _proposal ? _proposal(p) : p;
}
- (BOOL)selectionShouldChangeInTableView:(NSTableView *)t
{
    [self note:@"selectionShouldChange"];
    return YES;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n
{
    [self note:[NSString stringWithFormat:@"didChange %s", IX([n.object selectedRowIndexes])]];
}
- (void)tableViewSelectionIsChanging:(NSNotification *)n
{
    [self note:@"isChanging"];
}
- (void)tableViewColumnDidMove:(NSNotification *)n
{
    [self note:[NSString stringWithFormat:@"columnDidMove %@ -> %@", n.userInfo[@"NSOldColumn"],
                                          n.userInfo[@"NSNewColumn"]]];
}
- (void)tableViewColumnDidResize:(NSNotification *)n
{
    NSTableColumn *c = n.userInfo[@"NSTableColumn"];
    [self note:[NSString stringWithFormat:@"columnDidResize %@ old %@ now %g", c.identifier,
                                          n.userInfo[@"NSOldWidth"], c.width]];
}
- (BOOL)tableView:(NSTableView *)t shouldEditTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    return YES;
}
- (void)tableView:(NSTableView *)t willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    if ([cell isKindOfClass:[NSTextFieldCell class]] && r == 1)
        [cell setTextColor:[NSColor redColor]];
}
@end

#pragma mark - Columns

static void
columns(void)
{
    printf("== columns\n");
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"c"];
    printf("defaults: width %g min %g max %g mask %lu editable %d hidden %d title '%s' id %s table %p\n", c.width,
           c.minWidth, c.maxWidth, (unsigned long)c.resizingMask, c.isEditable, c.isHidden, c.title.UTF8String,
           c.identifier.UTF8String, c.tableView);
    printf("cells: header %s '%s' data %s editable %d selectable %d lbm %lu wraps %d scrollable %d bordered %d "
           "bezeled %d drawsBg %d\n",
           CN(c.headerCell), [c.headerCell stringValue].UTF8String, CN(c.dataCell), [c.dataCell isEditable],
           [c.dataCell isSelectable], (unsigned long)[c.dataCell lineBreakMode], [c.dataCell wraps],
           [c.dataCell isScrollable], [c.dataCell isBordered], [c.dataCell isBezeled], [c.dataCell drawsBackground]);
    printf("header cell: type %ld align %ld lbm %lu bordered %d bezeled %d editable %d\n", (long)[c.headerCell type],
           (long)[c.headerCell alignment], (unsigned long)[c.headerCell lineBreakMode], [c.headerCell isBordered],
           [c.headerCell isBezeled], [c.headerCell isEditable]);
    printf("dataCellForRow %d same %d\n", [c dataCellForRow:3] == c.dataCell, [c dataCellForRow:-1] == c.dataCell);
    c.title = @"Title";
    printf("title '%s' header '%s'\n", c.title.UTF8String, [c.headerCell stringValue].UTF8String);
    c.width = 5;
    printf("width 5 -> %g\n", c.width);
    c.width = 500;
    c.maxWidth = 300;
    printf("max 300 -> width %g\n", c.width);
    c.minWidth = 400;
    printf("min 400 -> width %g min %g max %g\n", c.width, c.minWidth, c.maxWidth);
    c.minWidth = 20;
    c.maxWidth = 1000;
    c.width = 80;
    c.resizingMask = NSTableColumnUserResizingMask;
    printf("mask %lu resizable %d\n", (unsigned long)c.resizingMask, [c isResizable]);
    [c setResizable:NO];
    printf("setResizable NO mask %lu\n", (unsigned long)c.resizingMask);
    [c setResizable:YES];
    printf("setResizable YES mask %lu\n", (unsigned long)c.resizingMask);
    c.headerToolTip = @"tip";
    c.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"k" ascending:NO];
    printf("tip %s proto %s\n", c.headerToolTip.UTF8String, D(c.sortDescriptorPrototype));
    c.identifier = @"c2";
    printf("identifier %s\n", c.identifier.UTF8String);
    NSTableColumn *d = [[NSTableColumn alloc] init];
    printf("init: identifier %s width %g\n", D(d.identifier), d.width);
    NSTableHeaderCell *hc = [[NSTableHeaderCell alloc] initTextCell:@"H"];
    printf("header cell init: type %ld '%s' align %ld lbm %lu\n", (long)hc.type, hc.stringValue.UTF8String,
           (long)hc.alignment, (unsigned long)hc.lineBreakMode);
}

#pragma mark - Geometry

static NSTableView *
make_table(NSTableViewStyle style, NSInteger rows, Rows **dsOut)
{
    NSTableView *t = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
    t.style = style;
    NSTableColumn *a = [[NSTableColumn alloc] initWithIdentifier:@"a"];
    NSTableColumn *b = [[NSTableColumn alloc] initWithIdentifier:@"b"];
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"c"];
    a.width = 100;
    b.width = 50;
    c.width = 30;
    [t addTableColumn:a];
    [t addTableColumn:b];
    [t addTableColumn:c];
    Rows *ds = [Rows new];
    ds.count = rows;
    t.dataSource = ds;
    t.delegate = ds;
    objc_setAssociatedObject(t, "ds", ds, OBJC_ASSOCIATION_RETAIN);
    if (dsOut)
        *dsOut = ds;
    return t;
}

static void
dump_geometry(NSTableView *t)
{
    printf("  frame %s rows %ld cols %ld\n", S(t.frame), (long)t.numberOfRows, (long)t.numberOfColumns);
    for (NSInteger i = 0; i < t.numberOfColumns; i++)
        printf("  col %ld %s w %g rect %s cell0 %s\n", (long)i, t.tableColumns[i].identifier.UTF8String,
               t.tableColumns[i].width, S([t rectOfColumn:i]), S([t frameOfCellAtColumn:i row:0]));
    for (NSInteger r = 0; r < MIN(t.numberOfRows, 4); r++)
        printf("  row %ld %s\n", (long)r, S([t rectOfRow:r]));
}

static void
geometry(void)
{
    printf("== geometry\n");
    NSTableView *t = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
    printf("defaults: rowHeight %g spacing %s style %ld eff %ld rowSize %ld eff %ld cols %ld rows %ld\n", t.rowHeight,
           Z(t.intercellSpacing), (long)t.style, (long)t.effectiveStyle, (long)t.rowSizeStyle,
           (long)t.effectiveRowSizeStyle, (long)t.numberOfColumns, (long)t.numberOfRows);
    printf("header %s %s corner %s %s grid %lu gridColor %s bg %s alt %d hl %ld autoresizing %ld\n", CN(t.headerView),
           S(t.headerView.frame), CN(t.cornerView), S(t.cornerView.frame), (unsigned long)t.gridStyleMask,
           D(t.gridColor), D(t.backgroundColor), t.usesAlternatingRowBackgroundColors,
           (long)t.selectionHighlightStyle, (long)t.columnAutoresizingStyle);
    printf("flags: empty %d multiple %d colsel %d reorder %d resize %d typeSelect %d floats %d autosaveTC %d flipped %d "
           "opaque %d autoRowHeights %d static %d vertMotion %d\n",
           t.allowsEmptySelection, t.allowsMultipleSelection, t.allowsColumnSelection, t.allowsColumnReordering,
           t.allowsColumnResizing, t.allowsTypeSelect, t.floatsGroupRows, t.autosaveTableColumns, t.isFlipped,
           t.isOpaque, t.usesAutomaticRowHeights, t.usesStaticContents, t.verticalMotionCanBeginDrag);
    printf("cell %p cellClass %p selected %ld clicked %ld %ld edited %ld %ld focused %ld hlcol %p sort %lu "
           "draggingStyle %ld group %ld userInterfaceDirection %ld\n",
           t.cell, [NSTableView cellClass], (long)t.selectedRow, (long)t.clickedRow, (long)t.clickedColumn,
           (long)t.editedRow, (long)t.editedColumn, (long)t.focusedColumn, t.highlightedTableColumn,
           (unsigned long)t.sortDescriptors.count, (long)t.draggingDestinationFeedbackStyle,
           (long)[t rowSizeStyle], (long)t.userInterfaceLayoutDirection);
    printf("header: tableView %d flipped %d frame %s\n", t.headerView.tableView == t, t.headerView.isFlipped,
           S(t.headerView.frame));
    for (NSTableViewStyle style = NSTableViewStyleAutomatic; style <= NSTableViewStylePlain; style++) {
        NSTableView *s = make_table(style, 3, NULL);
        printf("style %ld eff %ld\n", (long)style, (long)s.effectiveStyle);
        dump_geometry(s);
        s.intercellSpacing = NSMakeSize(4, 3);
        s.rowHeight = 20;
        printf(" spacing 4x3 rowHeight 20\n");
        dump_geometry(s);
        printf("  rowAtPoint:");
        for (CGFloat y = -1; y < 80; y += 7)
            printf(" %g:%ld", y, (long)[s rowAtPoint:NSMakePoint(5, y)]);
        printf("\n  columnAtPoint:");
        for (CGFloat x = -1; x < 200; x += 9)
            printf(" %g:%ld", x, (long)[s columnAtPoint:NSMakePoint(x, 5)]);
        printf("\n");
        NSRange rr = [s rowsInRect:NSMakeRect(0, 10, 10, 30)];
        printf("  rowsInRect %lu %lu cols in rect %s %s\n", (unsigned long)rr.location, (unsigned long)rr.length,
               IX([s columnIndexesInRect:NSMakeRect(0, 0, 120, 10)]), IX([s columnIndexesInRect:NSMakeRect(115, 0, 1, 10)]));
        printf("  rectOfRow out of range %s %s rectOfColumn %s cell %s\n", S([s rectOfRow:3]), S([s rectOfRow:-1]),
               S([s rectOfColumn:3]), S([s frameOfCellAtColumn:5 row:9]));
    }

    printf("-- edits\n");
    Rows *ds;
    NSTableView *s = make_table(NSTableViewStyleFullWidth, 4, &ds);
    ds.logging = YES;
    [[NSNotificationCenter defaultCenter] addObserverForName:NSTableViewColumnDidResizeNotification object:s queue:nil
                                                  usingBlock:^(NSNotification *n) {
                                                      printf("    note resize %s\n", D(n.userInfo[@"NSOldWidth"]));
                                                  }];
    [s moveColumn:0 toColumn:2];
    dump_geometry(s);
    printf("  columnWithIdentifier a %ld z %ld tableColumnWithIdentifier b %s\n", (long)[s columnWithIdentifier:@"a"],
           (long)[s columnWithIdentifier:@"z"], [s tableColumnWithIdentifier:@"b"].identifier.UTF8String);
    [s tableColumnWithIdentifier:@"b"].width = 70;
    dump_geometry(s);
    [s tableColumnWithIdentifier:@"c"].hidden = YES;
    printf(" hidden c\n");
    dump_geometry(s);
    [s tableColumnWithIdentifier:@"c"].hidden = NO;
    [s removeTableColumn:[s tableColumnWithIdentifier:@"b"]];
    printf(" removed b\n");
    dump_geometry(s);
    s.rowHeight = 0.5;
    printf("rowHeight 0.5 -> %g\n", s.rowHeight);
    s.rowHeight = 18;
    ds.variableHeights = YES;
    [s noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 4)]];
    printf(" variable heights\n");
    dump_geometry(s);
    printf("  rowAtPoint 9 %ld 10 %ld 30 %ld 60 %ld 80 %ld\n", (long)[s rowAtPoint:NSMakePoint(5, 9)],
           (long)[s rowAtPoint:NSMakePoint(5, 10)], (long)[s rowAtPoint:NSMakePoint(5, 30)],
           (long)[s rowAtPoint:NSMakePoint(5, 60)], (long)[s rowAtPoint:NSMakePoint(5, 80)]);
    ds.variableHeights = NO;
    ds.groups = YES;
    [s noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 4)]];
    printf(" groups: cell 0,0 %s 1,0 %s 0,1 %s\n", S([s frameOfCellAtColumn:0 row:0]),
           S([s frameOfCellAtColumn:1 row:0]), S([s frameOfCellAtColumn:0 row:1]));
    ds.groups = NO;

    printf("-- autoresizing\n");
    for (NSTableViewColumnAutoresizingStyle st = NSTableViewNoColumnAutoresizing;
         st <= NSTableViewFirstColumnOnlyAutoresizingStyle; st++) {
        NSTableView *u = make_table(NSTableViewStyleFullWidth, 2, NULL);
        u.columnAutoresizingStyle = st;
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 250, 100)];
        sv.documentView = u;
        printf(" style %ld in scroll:", (long)st);
        for (NSTableColumn *c in u.tableColumns)
            printf(" %g", c.width);
        [sv setFrameSize:NSMakeSize(300, 100)];
        printf(" | 300:");
        for (NSTableColumn *c in u.tableColumns)
            printf(" %g", c.width);
        [sv setFrameSize:NSMakeSize(150, 100)];
        printf(" | 150:");
        for (NSTableColumn *c in u.tableColumns)
            printf(" %g", c.width);
        printf(" frame %s\n", S(u.frame));
        [u sizeToFit];
        printf("   sizeToFit:");
        for (NSTableColumn *c in u.tableColumns)
            printf(" %g", c.width);
        [u sizeLastColumnToFit];
        printf(" sizeLastColumnToFit:");
        for (NSTableColumn *c in u.tableColumns)
            printf(" %g", c.width);
        printf(" frame %s\n", S(u.frame));
    }

    printf("-- scroll view\n");
    NSTableView *v = make_table(NSTableViewStyleAutomatic, 3, &ds);
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 250, 150)];
    sv.documentView = v;
    printf("frame %s clip %s bounds %s insets %g header %s in %s %s corner super %s\n", S(v.frame),
           S(sv.contentView.frame), S(sv.contentView.bounds), sv.contentView.contentInsets.top, S(v.headerView.frame),
           CN(v.headerView.superview), S(v.headerView.superview.frame), CN(v.cornerView.superview));
    printf("header rects %s %s %s columnAtPoint %ld %ld\n", S([v.headerView headerRectOfColumn:0]),
           S([v.headerView headerRectOfColumn:1]), S([v.headerView headerRectOfColumn:2]),
           (long)[v.headerView columnAtPoint:NSMakePoint(50, 5)], (long)[v.headerView columnAtPoint:NSMakePoint(5, 5)]);
    ds.count = 30;
    [v reloadData];
    printf("30 rows: frame %s\n", S(v.frame));
    [v scrollRowToVisible:20];
    printf("scrolled to 20: bounds %s visible %s\n", S(sv.contentView.bounds), S(v.visibleRect));
    [v scrollRowToVisible:2];
    printf("scrolled to 2: bounds %s\n", S(sv.contentView.bounds));
    [v scrollColumnToVisible:2];
    printf("scrolled to column 2: bounds %s\n", S(sv.contentView.bounds));
    v.headerView = nil;
    printf("no header: insets %g bounds %s\n", sv.contentView.contentInsets.top, S(sv.contentView.bounds));
}

#pragma mark - Selection

static void
selection(void)
{
    printf("== selection\n");
    Rows *ds;
    NSTableView *t = make_table(NSTableViewStyleFullWidth, 6, &ds);
    __block int notes = 0;
    id obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSTableViewSelectionDidChangeNotification object:t queue:nil
                usingBlock:^(NSNotification *n) {
                    notes++;
                }];
    ds.logging = YES;
    printf("select 2\n");
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    printf(" selected %ld %s count %ld isSelected %d\n", (long)t.selectedRow, IX(t.selectedRowIndexes),
           (long)t.numberOfSelectedRows, [t isRowSelected:2]);
    printf("select 4 extending (single selection)\n");
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:4] byExtendingSelection:YES];
    printf(" selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    t.allowsMultipleSelection = YES;
    printf("select 1 extending (multiple)\n");
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:YES];
    printf(" selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    printf("select 2-4 not extending\n");
    [t selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 3)] byExtendingSelection:NO];
    printf(" selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    printf("same again\n");
    [t selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 3)] byExtendingSelection:NO];
    printf("deselect 3\n");
    [t deselectRow:3];
    printf(" selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    printf("deselect 1 (not selected)\n");
    [t deselectRow:1];
    printf("selectAll\n");
    [t selectAll:nil];
    printf(" selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    printf("deselectAll\n");
    [t deselectAll:nil];
    printf(" selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    printf("select out of range 9\n");
    @try {
        [t selectRowIndexes:[NSIndexSet indexSetWithIndex:9] byExtendingSelection:NO];
        printf(" selected %s\n", IX(t.selectedRowIndexes));
        NSMutableIndexSet *m = [NSMutableIndexSet indexSetWithIndex:2];
        [m addIndex:9];
        [t selectRowIndexes:m byExtendingSelection:NO];
        printf(" 2 and 9: selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    } @catch (NSException *e) {
        printf(" exception %s\n", e.name.UTF8String);
    }
    printf("delegate refuses odd rows: select 1-4\n");
    ds.refuseOdd = YES;
    [t selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 4)] byExtendingSelection:NO];
    printf(" selected %ld %s (programmatic ignores the delegate)\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    ds.refuseOdd = NO;
    printf("allowsEmptySelection NO, deselectAll\n");
    t.allowsEmptySelection = NO;
    [t deselectAll:nil];
    printf(" selected %s\n", IX(t.selectedRowIndexes));
    [t deselectRow:t.selectedRow];
    printf(" after deselectRow selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    t.allowsEmptySelection = YES;
    [t selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 4)] byExtendingSelection:NO];
    printf("rows 6 -> 3 (noteNumberOfRowsChanged)\n");
    ds.count = 3;
    [t noteNumberOfRowsChanged];
    printf(" selected %ld %s rows %ld\n", (long)t.selectedRow, IX(t.selectedRowIndexes), (long)t.numberOfRows);
    printf("rows 3 -> 8, reloadData\n");
    ds.count = 8;
    [t reloadData];
    printf(" selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    printf("insert rows 0,2\n");
    NSMutableIndexSet *ins = [NSMutableIndexSet indexSetWithIndex:0];
    [ins addIndex:2];
    ds.count = 10;
    @try {
        [t insertRowsAtIndexes:ins withAnimation:NSTableViewAnimationEffectNone];
    } @catch (NSException *e) {
        printf(" outside beginUpdates: %s\n", e.name.UTF8String);
    }
    [t beginUpdates];
    [t insertRowsAtIndexes:ins withAnimation:NSTableViewAnimationEffectNone];
    printf(" inside: rows %ld selected %s\n", (long)t.numberOfRows, IX(t.selectedRowIndexes));
    [t endUpdates];
    printf(" selected %ld %s rows %ld\n", (long)t.selectedRow, IX(t.selectedRowIndexes), (long)t.numberOfRows);
    printf("remove rows 3,4\n");
    ds.count = 8;
    [t beginUpdates];
    [t removeRowsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(3, 2)]
             withAnimation:NSTableViewAnimationEffectNone];
    [t endUpdates];
    printf(" selected %ld %s rows %ld\n", (long)t.selectedRow, IX(t.selectedRowIndexes), (long)t.numberOfRows);
    printf("move row 1 -> 5\n");
    [t beginUpdates];
    [t moveRowAtIndex:1 toIndex:5];
    [t endUpdates];
    printf(" selected %ld %s\n", (long)t.selectedRow, IX(t.selectedRowIndexes));
    printf("columns: allowsColumnSelection %d\n", t.allowsColumnSelection);
    [t selectColumnIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    printf(" cols %s selectedColumn %ld rows %s\n", IX(t.selectedColumnIndexes), (long)t.selectedColumn,
           IX(t.selectedRowIndexes));
    t.allowsColumnSelection = YES;
    [t selectColumnIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    printf(" cols %s selectedColumn %ld rows %s isColumnSelected %d count %ld\n", IX(t.selectedColumnIndexes),
           (long)t.selectedColumn, IX(t.selectedRowIndexes), [t isColumnSelected:1], (long)t.numberOfSelectedColumns);
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    printf(" after row select cols %s rows %s\n", IX(t.selectedColumnIndexes), IX(t.selectedRowIndexes));
    [t selectColumnIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:YES];
    [t deselectColumn:2];
    printf(" after deselectColumn cols %s rows %s\n", IX(t.selectedColumnIndexes), IX(t.selectedRowIndexes));
    printf("notifications %d\n", notes);
    [[NSNotificationCenter defaultCenter] removeObserver:obs];

    printf("-- sorting\n");
    t.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"a" ascending:YES] ];
    t.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"a" ascending:YES] ];
    t.sortDescriptors = @[];
    printf(" sortDescriptors %lu\n", (unsigned long)t.sortDescriptors.count);
    NSTableColumn *a = [t tableColumnWithIdentifier:@"a"];
    [t setIndicatorImage:[[NSImage alloc] initWithSize:NSMakeSize(8, 8)] inTableColumn:a];
    printf(" indicator %d other %d\n", [t indicatorImageInTableColumn:a] != nil,
           [t indicatorImageInTableColumn:[t tableColumnWithIdentifier:@"b"]] != nil);
    t.highlightedTableColumn = a;
    printf(" highlighted %s\n", t.highlightedTableColumn.identifier.UTF8String);

    printf("-- cells\n");
    NSCell *cell = [t preparedCellAtColumn:0 row:1];
    printf(" prepared %s value %s color %s same as dataCell %d\n", CN(cell), D(cell.objectValue),
           D([(NSTextFieldCell *)cell textColor]), cell == [t.tableColumns[0] dataCell]);
    cell = [t preparedCellAtColumn:1 row:2];
    printf(" prepared %s value %s highlighted %d\n", CN(cell), D(cell.objectValue), cell.isHighlighted);
    @try {
        printf(" preparedCell out of range %s\n", CN([t preparedCellAtColumn:7 row:1]));
    } @catch (NSException *e) {
        printf(" preparedCell out of range: %s\n", e.name.UTF8String);
    }
    cell = [t preparedCellAtColumn:0 row:9];
    printf(" prepared row 9: value %s\n", D(cell.objectValue));
}


#pragma mark - View-based tables

@interface MyRowView : NSTableRowView
@end
@implementation MyRowView
@end

@interface Views : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property NSInteger count;
@property BOOL logging, groups, customRows;
@end

@implementation Views
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t
{
    return _count;
}
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    if (_logging)
        printf("    objectValue %s %ld\n", c ? c.identifier.UTF8String : "nil", (long)r);
    return [NSString stringWithFormat:@"%@%ld", c.identifier ?: @"group", (long)r];
}
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    NSString *ident = c ? c.identifier : @"group";
    NSTableCellView *v = [t makeViewWithIdentifier:ident owner:self];
    if (_logging)
        printf("    viewFor %s %ld reused %d\n", c ? c.identifier.UTF8String : "nil", (long)r, v != nil);
    if (!v) {
        v = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 40, 17)];
        v.identifier = ident;
        NSTextField *f = [NSTextField labelWithString:@""];
        f.frame = NSMakeRect(0, 0, 40, 17);
        [v addSubview:f];
        v.textField = f;
    }
    return v;
}
- (NSTableRowView *)tableView:(NSTableView *)t rowViewForRow:(NSInteger)r
{
    if (_logging)
        printf("    rowViewFor %ld\n", (long)r);
    return _customRows ? [[MyRowView alloc] initWithFrame:NSZeroRect] : nil;
}
- (void)tableView:(NSTableView *)t didAddRowView:(NSTableRowView *)rv forRow:(NSInteger)r
{
    if (_logging)
        printf("    didAdd %ld %s %s\n", (long)r, CN(rv), S(rv.frame));
}
- (void)tableView:(NSTableView *)t didRemoveRowView:(NSTableRowView *)rv forRow:(NSInteger)r
{
    if (_logging)
        printf("    didRemove %ld\n", (long)r);
}
- (BOOL)tableView:(NSTableView *)t isGroupRow:(NSInteger)r
{
    return _groups && r == 0;
}
@end

static void
dump_views(NSTableView *t)
{
    [t enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rv, NSInteger row) {
        printf("  row %ld %s %s sel %d group %d cols %ld rowForView %ld bgStyle %ld\n", (long)row, CN(rv), S(rv.frame),
               rv.isSelected, rv.isGroupRowStyle, (long)rv.numberOfColumns, (long)[t rowForView:rv],
               (long)rv.interiorBackgroundStyle);
        for (NSInteger c = 0; c < rv.numberOfColumns; c++) {
            NSTableCellView *v = [rv viewAtColumn:c];
            printf("    col %ld %s %s obj %s bg %ld text '%s' row %ld col %ld same %d\n", (long)c, CN(v), S(v.frame),
                   D([v respondsToSelector:@selector(objectValue)] ? v.objectValue : nil),
                   (long)([v respondsToSelector:@selector(backgroundStyle)] ? v.backgroundStyle : -1),
                   [v respondsToSelector:@selector(textField)] ? v.textField.stringValue.UTF8String : "",
                   (long)[t rowForView:v.textField ?: v], (long)[t columnForView:v],
                   v == [t viewAtColumn:c row:row makeIfNecessary:NO]);
        }
    }];
}

static void
view_based(void)
{
    printf("== view-based\n");
    NSTableRowView *rv = [[NSTableRowView alloc] initWithFrame:NSMakeRect(0, 0, 100, 20)];
    printf("row view defaults: sel %d emph %d group %d floating %d target %d nextSel %d prevSel %d style %ld drag %ld "
           "bg %s cols %ld bgStyle %ld flipped %d opaque %d\n",
           rv.isSelected, rv.isEmphasized, rv.isGroupRowStyle, rv.isFloating, rv.isTargetForDropOperation,
           rv.isNextRowSelected, rv.isPreviousRowSelected, (long)rv.selectionHighlightStyle,
           (long)rv.draggingDestinationFeedbackStyle, D(rv.backgroundColor), (long)rv.numberOfColumns,
           (long)rv.interiorBackgroundStyle, rv.isFlipped, rv.isOpaque);
    rv.selected = YES;
    printf("selected: bgStyle %ld emph %d\n", (long)rv.interiorBackgroundStyle, rv.isEmphasized);
    rv.emphasized = NO;
    printf("not emphasized: bgStyle %ld\n", (long)rv.interiorBackgroundStyle);
    rv.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    printf("style none: bgStyle %ld\n", (long)rv.interiorBackgroundStyle);
    NSTableCellView *cv = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 50, 17)];
    printf("cell view defaults: obj %s text %p image %p bg %ld size %ld flipped %d\n", D(cv.objectValue), cv.textField,
           cv.imageView, (long)cv.backgroundStyle, (long)cv.rowSizeStyle, cv.isFlipped);
    cv.objectValue = @"x";
    printf("objectValue %s\n", D(cv.objectValue));

    NSTableView *t = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
    t.style = NSTableViewStyleFullWidth;
    for (NSString *ident in @[ @"a", @"b" ]) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:ident];
        c.width = 60;
        [t addTableColumn:c];
    }
    Views *ds = [Views new];
    ds.count = 4;
    ds.logging = YES;
    t.delegate = ds;
    t.dataSource = ds;
    printf("rows %ld nomake %p %p\n", (long)t.numberOfRows, [t viewAtColumn:0 row:1 makeIfNecessary:NO],
           [t rowViewAtRow:1 makeIfNecessary:NO]);
    printf("make view 0,1\n");
    NSView *made = [t viewAtColumn:0 row:1 makeIfNecessary:YES];
    printf(" made %s super %s subviews %lu\n", CN(made), CN(made.superview), (unsigned long)t.subviews.count);
    dump_views(t);
    printf("makeViewWithIdentifier unknown %p registered %lu\n", [t makeViewWithIdentifier:@"zz" owner:nil],
           (unsigned long)t.registeredNibsByIdentifier.count);
    printf("select 1-2\n");
    t.allowsMultipleSelection = YES;
    [t selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)] byExtendingSelection:NO];
    dump_views(t);
    printf("reloadDataForRowIndexes 2\n");
    [t reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:2] columnIndexes:[NSIndexSet indexSetWithIndex:1]];
    printf("insert row 1\n");
    ds.count = 5;
    [t insertRowsAtIndexes:[NSIndexSet indexSetWithIndex:1] withAnimation:NSTableViewAnimationSlideDown];
    printf(" selected %s\n", IX(t.selectedRowIndexes));
    dump_views(t);
    printf("remove rows 0,3\n");
    ds.count = 3;
    NSMutableIndexSet *rm = [NSMutableIndexSet indexSetWithIndex:0];
    [rm addIndex:3];
    [t removeRowsAtIndexes:rm withAnimation:NSTableViewAnimationEffectFade];
    printf(" selected %s\n", IX(t.selectedRowIndexes));
    dump_views(t);
    printf("reloadData\n");
    [t reloadData];
    printf(" subviews %lu rowView 0 %p\n", (unsigned long)t.subviews.count, [t rowViewAtRow:0 makeIfNecessary:NO]);
    printf("custom row views, group row 0\n");
    ds.customRows = YES;
    ds.groups = YES;
    [t rowViewAtRow:0 makeIfNecessary:YES];
    dump_views(t);
    printf(" group cell frame %s\n", S([t frameOfCellAtColumn:1 row:0]));
    printf("in a scroll view and window\n");
    ds.logging = NO;
    ds.groups = NO;
    ds.customRows = NO;
    ds.count = 20;
    [t reloadData];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    sv.documentView = t;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 200) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:YES];
    w.releasedWhenClosed = NO;
    [w.contentView addSubview:sv];
    ds.logging = YES;
    [w layoutIfNeeded];
    ds.logging = NO;
    __block NSInteger n = 0;
    [t enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *r, NSInteger row) {
        n++;
    }];
    printf(" row views %ld visible rows %s\n", (long)n, NSStringFromRange([t rowsInRect:t.visibleRect]).UTF8String);
    [t scrollRowToVisible:15];
    [w layoutIfNeeded];
    NSMutableString *rows = [NSMutableString string];
    [t enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *r, NSInteger row) {
        [rows appendFormat:@" %ld", (long)row];
    }];
    printf(" after scrolling to 15: visible %s, rows with views include 15 %d\n",
           NSStringFromRange([t rowsInRect:t.visibleRect]).UTF8String, [t rowViewAtRow:15 makeIfNecessary:NO] != nil);
    [w close];
}


#pragma mark - Outline views

@interface Node : NSObject
@property (copy) NSString *name;
@property NSMutableArray<Node *> *children;
@end
@implementation Node
+ (Node *)name:(NSString *)n children:(NSArray *)c
{
    Node *x = [Node new];
    x.name = n;
    x.children = c ? [c mutableCopy] : nil;
    return x;
}
- (NSString *)description
{
    return _name;
}
@end

@interface Tree : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property Node *root;
@property BOOL logging, refuse;
@end

@implementation Tree
- (NSInteger)outlineView:(NSOutlineView *)o numberOfChildrenOfItem:(id)item
{
    Node *n = item ?: _root;
    return n.children.count;
}
- (id)outlineView:(NSOutlineView *)o child:(NSInteger)i ofItem:(id)item
{
    Node *n = item ?: _root;
    return n.children[i];
}
- (BOOL)outlineView:(NSOutlineView *)o isItemExpandable:(id)item
{
    return [(Node *)item children] != nil;
}
- (id)outlineView:(NSOutlineView *)o objectValueForTableColumn:(NSTableColumn *)c byItem:(id)item
{
    return [NSString stringWithFormat:@"%@/%@", [item name], c.identifier];
}
- (BOOL)outlineView:(NSOutlineView *)o shouldExpandItem:(id)item
{
    if (_logging)
        printf("    shouldExpand %s\n", D(item));
    return !(_refuse && [[item name] isEqualToString:@"b"]);
}
- (BOOL)outlineView:(NSOutlineView *)o shouldCollapseItem:(id)item
{
    if (_logging)
        printf("    shouldCollapse %s\n", D(item));
    return YES;
}
- (void)outlineViewItemWillExpand:(NSNotification *)n
{
    if (_logging)
        printf("    willExpand %s\n", D(n.userInfo[@"NSObject"]));
}
- (void)outlineViewItemDidExpand:(NSNotification *)n
{
    if (_logging)
        printf("    didExpand %s\n", D(n.userInfo[@"NSObject"]));
}
- (void)outlineViewItemWillCollapse:(NSNotification *)n
{
    if (_logging)
        printf("    willCollapse %s\n", D(n.userInfo[@"NSObject"]));
}
- (void)outlineViewItemDidCollapse:(NSNotification *)n
{
    if (_logging)
        printf("    didCollapse %s\n", D(n.userInfo[@"NSObject"]));
}
- (void)outlineViewSelectionDidChange:(NSNotification *)n
{
    if (_logging)
        printf("    selectionDidChange %s\n", IX([n.object selectedRowIndexes]));
}
@end

static void
dump_outline(NSOutlineView *o)
{
    printf("  widths %g %g frame %s rows %ld:", o.tableColumns[0].width, o.tableColumns[1].width, S(o.frame),
           (long)o.numberOfRows);
    for (NSInteger r = 0; r < o.numberOfRows; r++) {
        id item = [o itemAtRow:r];
        printf(" %s(L%ld%s%s p=%s ci=%ld)", D(item), (long)[o levelForRow:r], [o isItemExpanded:item] ? " +" : "",
               [o isExpandable:item] ? " e" : "", D([o parentForItem:item]), (long)[o childIndexForItem:item]);
    }
    printf("\n");
}

static void
outlines(void)
{
    printf("== outline\n");
    NSOutlineView *o = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
    printf("defaults: indentation %g follows %d outlineColumn %p autoresizes %d autosaveExpanded %d stronglyRefs %d "
           "rowHeight %g style %ld\n",
           o.indentationPerLevel, o.indentationMarkerFollowsCell, o.outlineTableColumn, o.autoresizesOutlineColumn,
           o.autosaveExpandedItems, o.stronglyReferencesItems, o.rowHeight, (long)o.style);
    o.style = NSTableViewStyleFullWidth;
    NSTableColumn *a = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    NSTableColumn *b = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    a.width = 150;
    b.width = 50;
    [o addTableColumn:a];
    [o addTableColumn:b];
    printf("outlineTableColumn after adding %s\n", D(o.outlineTableColumn.identifier));
    o.outlineTableColumn = a;
    Tree *tree = [Tree new];
    Node *a1 = [Node name:@"a1" children:nil];
    Node *b1 = [Node name:@"b1" children:@[ [Node name:@"b1x" children:nil] ]];
    Node *b2 = [Node name:@"b2" children:@[]];
    Node *na = [Node name:@"a" children:@[ a1, [Node name:@"a2" children:nil] ]];
    Node *nb = [Node name:@"b" children:@[ b1, b2 ]];
    Node *nc = [Node name:@"c" children:nil];
    tree.root = [Node name:@"root" children:@[ na, nb, nc ]];
    o.dataSource = tree;
    o.delegate = tree;
    dump_outline(o);
    printf("row for b %ld for a1 %ld; item at row 9 %s level of a1 %ld\n", (long)[o rowForItem:nb],
           (long)[o rowForItem:a1], D([o itemAtRow:9]), (long)[o levelForItem:a1]);
    tree.logging = YES;
    printf("expand a\n");
    [o expandItem:na];
    dump_outline(o);
    printf("select b, expand b with children\n");
    [o selectRowIndexes:[NSIndexSet indexSetWithIndex:[o rowForItem:nb]] byExtendingSelection:NO];
    [o expandItem:nb expandChildren:YES];
    dump_outline(o);
    printf(" selected %s item %s\n", IX(o.selectedRowIndexes), D([o itemAtRow:o.selectedRow]));
    printf(" frames: cell 0,row(b1x) %s outline cell %s rect %s; cell 1,row(b1x) %s; level0 cell %s outline cell %s\n",
           S([o frameOfCellAtColumn:0 row:[o rowForItem:b1.children[0]]]),
           S([o frameOfOutlineCellAtRow:[o rowForItem:b1.children[0]]]), S([o rectOfRow:[o rowForItem:b1.children[0]]]),
           S([o frameOfCellAtColumn:1 row:[o rowForItem:b1.children[0]]]), S([o frameOfCellAtColumn:0 row:0]),
           S([o frameOfOutlineCellAtRow:0]));
    printf(" outline cell of a leaf %s\n", S([o frameOfOutlineCellAtRow:[o rowForItem:a1]]));
    printf("select b1x, collapse b\n");
    [o selectRowIndexes:[NSIndexSet indexSetWithIndex:[o rowForItem:b1.children[0]]] byExtendingSelection:NO];
    [o collapseItem:nb];
    dump_outline(o);
    printf(" selected %s; b1 still expanded %d\n", IX(o.selectedRowIndexes), [o isItemExpanded:b1]);
    printf("expand b again\n");
    [o expandItem:nb];
    dump_outline(o);
    printf("collapse b with children\n");
    [o collapseItem:nb collapseChildren:YES];
    printf(" b1 expanded %d\n", [o isItemExpanded:b1]);
    printf("expand b alone\n");
    [o expandItem:nb];
    dump_outline(o);
    printf("expand nil (all)\n");
    [o expandItem:nil expandChildren:YES];
    dump_outline(o);
    printf("collapse nil\n");
    [o collapseItem:nil collapseChildren:NO];
    dump_outline(o);
    printf("refused expand of b\n");
    tree.refuse = YES;
    [o expandItem:nb];
    printf(" b expanded %d\n", [o isItemExpanded:nb]);
    tree.refuse = NO;
    tree.logging = NO;
    printf("indentation 20, not following\n");
    [o expandItem:nil expandChildren:YES];
    o.indentationPerLevel = 20;
    printf(" b1x cell %s b1 cell %s outline %s\n", S([o frameOfCellAtColumn:0 row:[o rowForItem:b1.children[0]]]),
           S([o frameOfCellAtColumn:0 row:[o rowForItem:b1]]), S([o frameOfOutlineCellAtRow:[o rowForItem:b1]]));
    o.indentationMarkerFollowsCell = NO;
    printf(" b1x cell %s b1 cell %s outline %s\n", S([o frameOfCellAtColumn:0 row:[o rowForItem:b1.children[0]]]),
           S([o frameOfCellAtColumn:0 row:[o rowForItem:b1]]), S([o frameOfOutlineCellAtRow:[o rowForItem:b1]]));
    o.indentationMarkerFollowsCell = YES;
    o.autoresizesOutlineColumn = NO;
    printf("tree API: children of nil %ld child 1 of b %s\n", (long)[o numberOfChildrenOfItem:nil],
           D([o child:1 ofItem:nb]));
    printf("insert under a at 1\n");
    [na.children insertObject:[Node name:@"aNew" children:nil] atIndex:1];
    [o beginUpdates];
    [o insertItemsAtIndexes:[NSIndexSet indexSetWithIndex:1] inParent:na withAnimation:0];
    [o endUpdates];
    dump_outline(o);
    printf("remove b's child 0\n");
    [o selectRowIndexes:[NSIndexSet indexSetWithIndex:[o rowForItem:b2]] byExtendingSelection:NO];
    [nb.children removeObjectAtIndex:0];
    [o beginUpdates];
    [o removeItemsAtIndexes:[NSIndexSet indexSetWithIndex:0] inParent:nb withAnimation:0];
    [o endUpdates];
    dump_outline(o);
    printf(" selected %s %s\n", IX(o.selectedRowIndexes), D([o itemAtRow:o.selectedRow]));
    printf("move c into a at 0\n");
    [tree.root.children removeObject:nc];
    [na.children insertObject:nc atIndex:0];
    [o beginUpdates];
    [o moveItemAtIndex:2 inParent:nil toIndex:0 inParent:na];
    [o endUpdates];
    dump_outline(o);
    printf("reloadItem a with children after changes\n");
    [na.children removeLastObject];
    [o reloadItem:na reloadChildren:YES];
    dump_outline(o);
    printf("reloadData\n");
    [o reloadData];
    dump_outline(o);
}


#pragma mark - Collection views

@interface Item : NSCollectionViewItem
@end
@implementation Item
- (void)loadView
{
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
}
@end

@interface Header : NSView <NSCollectionViewElement>
@end
@implementation Header
@end

@interface Items : NSObject <NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout>
@property NSMutableArray<NSNumber *> *counts;
@property BOOL logging, sizes, headers;
@end

@implementation Items
- (NSInteger)numberOfSectionsInCollectionView:(NSCollectionView *)cv
{
    return _counts.count;
}
- (NSInteger)collectionView:(NSCollectionView *)cv numberOfItemsInSection:(NSInteger)s
{
    return _counts[s].integerValue;
}
- (NSCollectionViewItem *)collectionView:(NSCollectionView *)cv itemForRepresentedObjectAtIndexPath:(NSIndexPath *)p
{
    NSCollectionViewItem *it = [cv makeItemWithIdentifier:@"item" forIndexPath:p];
    if (_logging)
        printf("    item for %ld.%ld %s\n", (long)p.section, (long)p.item, CN(it));
    it.representedObject = [NSString stringWithFormat:@"%ld.%ld", (long)p.section, (long)p.item];
    return it;
}
- (NSView *)collectionView:(NSCollectionView *)cv viewForSupplementaryElementOfKind:(NSString *)kind
               atIndexPath:(NSIndexPath *)p
{
    NSView *v = [cv makeSupplementaryViewOfKind:kind withIdentifier:@"header" forIndexPath:p];
    if (_logging)
        printf("    supplementary %s %ld %s\n", kind.UTF8String, (long)p.section, CN(v));
    return v;
}
- (NSSize)collectionView:(NSCollectionView *)cv layout:(NSCollectionViewLayout *)l sizeForItemAtIndexPath:(NSIndexPath *)p
{
    return _sizes ? NSMakeSize(30 + 10 * p.item, 20 + 5 * (p.item % 3)) : [(NSCollectionViewFlowLayout *)l itemSize];
}
- (NSSize)collectionView:(NSCollectionView *)cv layout:(NSCollectionViewLayout *)l referenceSizeForHeaderInSection:(NSInteger)s
{
    return _headers ? NSMakeSize(0, 20 + s) : NSZeroSize;
}
- (void)collectionView:(NSCollectionView *)cv didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths
{
    if (_logging)
        printf("    didSelect %lu\n", (unsigned long)paths.count);
}
- (void)collectionView:(NSCollectionView *)cv didDeselectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths
{
    if (_logging)
        printf("    didDeselect %lu\n", (unsigned long)paths.count);
}
@end

static const char *
IP(NSIndexPath *p)
{
    return p ? [NSString stringWithFormat:@"%ld.%ld", (long)p.section, (long)p.item].UTF8String : "nil";
}

static const char *
IPS(NSSet<NSIndexPath *> *set)
{
    NSMutableString *m = [NSMutableString stringWithString:@"{"];
    for (NSIndexPath *p in [[set allObjects] sortedArrayUsingSelector:@selector(compare:)])
        [m appendFormat:@" %s", IP(p)];
    [m appendString:@" }"];
    return m.UTF8String;
}

static NSWindow *layout_window;

/* Apple's layouts settle in the window's layout pass: invalidate, lay out, then read the attributes. */
static void
dump_layout(NSCollectionView *cv)
{
    NSCollectionViewLayout *l = cv.collectionViewLayout;
    [l invalidateLayout];
    [layout_window layoutIfNeeded];
    [layout_window displayIfNeeded];
    printf("  content %s frame %s\n", Z(l.collectionViewContentSize), S(cv.frame));
    for (NSInteger s = 0; s < cv.numberOfSections; s++) {
        printf("  section %ld:", (long)s);
        for (NSInteger i = 0; i < [cv numberOfItemsInSection:s]; i++)
            printf(" %s", S([l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:s]].frame));
        NSCollectionViewLayoutAttributes *h =
            [l layoutAttributesForSupplementaryViewOfKind:NSCollectionElementKindSectionHeader
                                              atIndexPath:[NSIndexPath indexPathForItem:0 inSection:s]];
        if (h && h.frame.size.height > 0)
            printf(" header %s", S(h.frame));
        printf("\n");
    }
}

static NSCollectionView *
make_collection(NSCollectionViewLayout *layout, id<NSCollectionViewDataSource> ds, CGFloat width)
{
    NSCollectionView *cv = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, width, 150)];
    cv.collectionViewLayout = layout;
    [cv registerClass:[Item class] forItemWithIdentifier:@"item"];
    [cv registerClass:[Header class] forSupplementaryViewOfKind:NSCollectionElementKindSectionHeader
               withIdentifier:@"header"];
    cv.dataSource = ds;
    if ([ds conformsToProtocol:@protocol(NSCollectionViewDelegate)])
        cv.delegate = (id)ds;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, 150)];
    sv.documentView = cv;
    [layout_window.contentView addSubview:sv];
    return cv;
}

static void
collections(void)
{
    printf("== collection\n");
    layout_window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 400) styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered defer:YES];
    layout_window.releasedWhenClosed = NO;
    NSCollectionViewFlowLayout *fl = [[NSCollectionViewFlowLayout alloc] init];
    printf("flow defaults: item %s estimated %s line %g interitem %g inset %g %g %g %g dir %ld header %s footer %s pin %d %d\n",
           Z(fl.itemSize), Z(fl.estimatedItemSize), fl.minimumLineSpacing, fl.minimumInteritemSpacing,
           fl.sectionInset.top, fl.sectionInset.left, fl.sectionInset.bottom, fl.sectionInset.right,
           (long)fl.scrollDirection, Z(fl.headerReferenceSize), Z(fl.footerReferenceSize),
           fl.sectionHeadersPinToVisibleBounds, fl.sectionFootersPinToVisibleBounds);
    NSCollectionViewGridLayout *gl = [[NSCollectionViewGridLayout alloc] init];
    printf("grid defaults: margins %g %g %g %g interitem %g line %g rows %lu cols %lu min %s max %s colors %lu\n",
           gl.margins.top, gl.margins.left, gl.margins.bottom, gl.margins.right, gl.minimumInteritemSpacing,
           gl.minimumLineSpacing, (unsigned long)gl.maximumNumberOfRows, (unsigned long)gl.maximumNumberOfColumns,
           Z(gl.minimumItemSize), Z(gl.maximumItemSize), (unsigned long)gl.backgroundColors.count);
    NSCollectionView *bare = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 238, 148)];
    printf("view defaults: layout %s selectable %d multiple %d empty %d sections %ld colors %lu first %d content %lu "
           "maxRows %lu maxCols %lu min %s max %s flipped %d\n",
           CN(bare.collectionViewLayout), bare.isSelectable, bare.allowsMultipleSelection, bare.allowsEmptySelection,
           (long)bare.numberOfSections, (unsigned long)bare.backgroundColors.count, bare.acceptsFirstResponder,
           (unsigned long)bare.content.count, (unsigned long)bare.maxNumberOfRows, (unsigned long)bare.maxNumberOfColumns,
           Z(bare.minItemSize), Z(bare.maxItemSize), bare.isFlipped);
    NSCollectionViewLayoutAttributes *la =
        [NSCollectionViewLayoutAttributes layoutAttributesForItemWithIndexPath:[NSIndexPath indexPathForItem:2 inSection:1]];
    printf("attributes: frame %s size %s alpha %g z %ld hidden %d category %ld kind %s path %s\n", S(la.frame), Z(la.size),
           la.alpha, (long)la.zIndex, la.isHidden, (long)la.representedElementCategory,
           D(la.representedElementKind), IP(la.indexPath));
    la.frame = NSMakeRect(1, 2, 3, 4);
    NSCollectionViewLayoutAttributes *lb = [la copy];
    printf(" copy equal %d frame %s\n", [la isEqual:lb], S(lb.frame));
    la = [NSCollectionViewLayoutAttributes
        layoutAttributesForSupplementaryViewOfKind:NSCollectionElementKindSectionHeader
                                     withIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
    printf(" supplementary category %ld kind %s\n", (long)la.representedElementCategory, D(la.representedElementKind));

    Items *ds = [Items new];
    ds.counts = [@[ @7, @3 ] mutableCopy];
    NSCollectionView *cv = make_collection(fl, ds, 240);
    printf("flow, 7 and 3 items, defaults\n");
    printf(" sections %ld items %ld %ld\n", (long)cv.numberOfSections, (long)[cv numberOfItemsInSection:0],
           (long)[cv numberOfItemsInSection:1]);
    dump_layout(cv);
    fl.itemSize = NSMakeSize(60, 40);
    fl.minimumInteritemSpacing = 6;
    fl.minimumLineSpacing = 8;
    fl.sectionInset = NSEdgeInsetsMake(2, 4, 2, 4);
    printf("60x40, spacing 6/8, inset 2,4\n");
    dump_layout(cv);
    printf("width 300\n");
    [cv.enclosingScrollView setFrameSize:NSMakeSize(300, 150)];
    dump_layout(cv);
    printf("sizes from the delegate, headers\n");
    ds.sizes = YES;
    ds.headers = YES;
    dump_layout(cv);
    printf("horizontal\n");
    fl.scrollDirection = NSCollectionViewScrollDirectionHorizontal;
    dump_layout(cv);
    ds.sizes = NO;
    ds.headers = NO;
    dump_layout(cv);
    fl.scrollDirection = NSCollectionViewScrollDirectionVertical;
    printf("header reference size 0x15\n");
    fl.headerReferenceSize = NSMakeSize(0, 15);
    dump_layout(cv);
    fl.headerReferenceSize = NSZeroSize;
    dump_layout(cv);

    printf("items\n");
    ds.logging = YES;
    [layout_window layoutIfNeeded];
    ds.logging = NO;
    printf(" visible %lu\n", (unsigned long)cv.visibleItems.count);
    NSCollectionViewItem *it = [cv itemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]];
    printf(" item 0.1 %s obj %s view %s super %s selected %d path %s cv %d\n", CN(it), D(it.representedObject),
           S(it.view.frame), CN(it.view.superview), it.isSelected, IP([cv indexPathForItem:it]), it.collectionView == cv);
    printf(" at point %s %s %s\n", IP([cv indexPathForItemAtPoint:NSMakePoint(110, 5)]),
           IP([cv indexPathForItemAtPoint:NSMakePoint(66, 5)]), IP([cv indexPathForItemAtPoint:NSMakePoint(10, 100)]));
    printf("select\n");
    ds.logging = YES;
    [cv selectItemsAtIndexPaths:[NSSet setWithObject:[NSIndexPath indexPathForItem:1 inSection:0]]
                 scrollPosition:NSCollectionViewScrollPositionNone];
    printf(" not selectable: %s\n", IPS(cv.selectionIndexPaths));
    cv.selectable = YES;
    [cv selectItemsAtIndexPaths:[NSSet setWithObject:[NSIndexPath indexPathForItem:1 inSection:0]]
                 scrollPosition:NSCollectionViewScrollPositionNone];
    printf(" %s item selected %d indexes %s\n", IPS(cv.selectionIndexPaths), it.isSelected, IX(cv.selectionIndexes));
    [cv selectItemsAtIndexPaths:[NSSet setWithObject:[NSIndexPath indexPathForItem:2 inSection:1]]
                 scrollPosition:NSCollectionViewScrollPositionNone];
    printf(" add 1.2 (single): %s\n", IPS(cv.selectionIndexPaths));
    cv.allowsMultipleSelection = YES;
    [cv selectItemsAtIndexPaths:[NSSet setWithObject:[NSIndexPath indexPathForItem:0 inSection:0]]
                 scrollPosition:NSCollectionViewScrollPositionNone];
    printf(" add 0.0 (multiple): %s\n", IPS(cv.selectionIndexPaths));
    [cv deselectItemsAtIndexPaths:[NSSet setWithObject:[NSIndexPath indexPathForItem:0 inSection:0]]];
    printf(" deselect 0.0: %s\n", IPS(cv.selectionIndexPaths));
    [cv selectAll:nil];
    printf(" selectAll: %lu\n", (unsigned long)cv.selectionIndexPaths.count);
    [cv deselectAll:nil];
    printf(" deselectAll: %s\n", IPS(cv.selectionIndexPaths));
    cv.selectionIndexPaths = [NSSet setWithObject:[NSIndexPath indexPathForItem:3 inSection:0]];
    printf(" set paths: %s indexes %s\n", IPS(cv.selectionIndexPaths), IX(cv.selectionIndexes));
    ds.logging = NO;
    printf("reloadData\n");
    ds.counts[0] = @8;
    [cv reloadData];
    [layout_window layoutIfNeeded];
    printf(" items %ld selection %s visible %lu\n", (long)[cv numberOfItemsInSection:0], IPS(cv.selectionIndexPaths),
           (unsigned long)cv.visibleItems.count);

    printf("grid\n");
    gl.minimumItemSize = NSMakeSize(40, 30);
    gl.maximumItemSize = NSMakeSize(70, 50);
    gl.minimumInteritemSpacing = 5;
    gl.minimumLineSpacing = 4;
    gl.margins = NSEdgeInsetsMake(5, 5, 5, 5);
    Items *gds = [Items new];
    gds.counts = [@[ @9 ] mutableCopy];
    NSCollectionView *g = make_collection(gl, gds, 240);
    dump_layout(g);
    gl.maximumNumberOfColumns = 3;
    printf(" 3 columns\n");
    dump_layout(g);
    gl.maximumNumberOfColumns = 0;
    gl.maximumNumberOfRows = 1;
    printf(" 1 row\n");
    dump_layout(g);

    printf("legacy content\n");
    NSCollectionView *lc = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 238, 148)];
    Item *proto = [[Item alloc] init];
    proto.view.frame = NSMakeRect(0, 0, 50, 30);
    lc.itemPrototype = proto;
    lc.content = @[ @"a", @"b", @"c", @"d", @"e", @"f", @"g" ];
    printf(" layout %s sections %ld items %ld\n", CN(lc.collectionViewLayout), (long)lc.numberOfSections,
           (long)[lc numberOfItemsInSection:0]);
    for (NSUInteger i = 0; i < 7; i++)
        printf(" %s", S([lc frameForItemAtIndex:i]));
    printf("\n");
    lc.maxNumberOfColumns = 2;
    lc.minItemSize = NSMakeSize(60, 30);
    for (NSUInteger i = 0; i < 7; i++)
        printf(" %s", S([lc frameForItemAtIndex:i]));
    printf("\n item 3 %s obj %s\n", CN([lc itemAtIndex:3]), D([lc itemAtIndex:3].representedObject));
    lc.selectable = YES;
    lc.selectionIndexes = [NSIndexSet indexSetWithIndex:4];
    printf(" selectionIndexes %s item selected %d\n", IX(lc.selectionIndexes), [lc itemAtIndex:4].isSelected);
    printf(" frameForItemAtIndex:withNumberOfItems: %s\n", S([lc frameForItemAtIndex:1 withNumberOfItems:3]));
    [layout_window close];
}


#pragma mark - Bindings

@interface Person : NSObject
@property (copy) NSString *name;
@property NSInteger age;
@end
@implementation Person
+ (Person *)name:(NSString *)n age:(NSInteger)a
{
    Person *p = [Person new];
    p.name = n;
    p.age = a;
    return p;
}
- (NSString *)description
{
    return _name;
}
@end

@interface BoundViews : NSObject <NSTableViewDelegate>
@end
@implementation BoundViews
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    NSTableCellView *v = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 60, 17)];
    NSTextField *f = [NSTextField labelWithString:@""];
    [v addSubview:f];
    v.textField = f;
    [f bind:NSValueBinding toObject:v withKeyPath:[@"objectValue." stringByAppendingString:c.identifier] options:nil];
    return v;
}
@end

static void
binding_info(id o, NSString *b)
{
    NSDictionary *i = [o infoForBinding:b];
    printf("  %s: %s %s\n", b.UTF8String, CN(i[NSObservedObjectKey]), D(i[NSObservedKeyPathKey]));
}

static void
dump_bound(NSTableView *t)
{
    printf("  rows %ld:", (long)t.numberOfRows);
    for (NSInteger r = 0; r < t.numberOfRows; r++) {
        printf(" [");
        for (NSInteger c = 0; c < t.numberOfColumns; c++)
            printf("%s%s", c ? " " : "", D([t preparedCellAtColumn:c row:r].objectValue));
        printf("]");
    }
    printf(" selected %s\n", IX(t.selectedRowIndexes));
}

static void
bindings(void)
{
    printf("== bindings\n");
    NSTableView *t = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
    NSTableColumn *cn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    NSTableColumn *ca = [[NSTableColumn alloc] initWithIdentifier:@"age"];
    [t addTableColumn:cn];
    [t addTableColumn:ca];
    NSMutableArray *ex = [[t exposedBindings] mutableCopy];
    [ex sortUsingSelector:@selector(compare:)];
    printf("table exposed %s\n", [[ex componentsJoinedByString:@" "] UTF8String]);
    ex = [[cn exposedBindings] mutableCopy];
    [ex sortUsingSelector:@selector(compare:)];
    printf("column exposed %s\n", [[ex componentsJoinedByString:@" "] UTF8String]);
    printf("value class %s\n", CN([cn valueClassForBinding:NSValueBinding]));
    NSArrayController *ac = [[NSArrayController alloc] init];
    ac.content = [@[ [Person name:@"Cy" age:30], [Person name:@"Al" age:50], [Person name:@"Bo" age:40] ] mutableCopy];
    [cn bind:NSValueBinding toObject:ac withKeyPath:@"arrangedObjects.name" options:nil];
    [ca bind:NSValueBinding toObject:ac withKeyPath:@"arrangedObjects.age" options:nil];
    printf("columns bound\n");
    binding_info(cn, NSValueBinding);
    binding_info(t, NSContentBinding);
    binding_info(t, NSSelectionIndexesBinding);
    binding_info(t, NSSortDescriptorsBinding);
    dump_bound(t);
    printf("controller selects 1\n");
    ac.selectionIndexes = [NSIndexSet indexSetWithIndex:1];
    dump_bound(t);
    printf("table selects 2\n");
    [t selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    printf("  controller %s\n", IX(ac.selectionIndexes));
    printf("controller adds Di\n");
    [ac addObject:[Person name:@"Di" age:20]];
    dump_bound(t);
    printf("table sorts by name\n");
    t.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
    printf("  controller sort %lu\n", (unsigned long)ac.sortDescriptors.count);
    dump_bound(t);
    printf("controller sorts by age descending\n");
    ac.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"age" ascending:NO] ];
    printf("  table sort %s\n", D(t.sortDescriptors.firstObject.key));
    dump_bound(t);
    printf("a person changes name\n");
    [(Person *)ac.arrangedObjects[0] setName:@"Ed"];
    dump_bound(t);
    printf("column prototypes from the binding: %s\n", D(cn.sortDescriptorPrototype));
    printf("unbind name\n");
    [cn unbind:NSValueBinding];
    binding_info(t, NSContentBinding);
    dump_bound(t);

    printf("explicit table bindings, view-based\n");
    NSTableView *v = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
    NSTableColumn *vn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [v addTableColumn:vn];
    BoundViews *bv = [BoundViews new];
    v.delegate = bv;
    NSArrayController *ac2 = [[NSArrayController alloc] init];
    ac2.content = [@[ [Person name:@"Fa" age:1], [Person name:@"Go" age:2] ] mutableCopy];
    [v bind:NSContentBinding toObject:ac2 withKeyPath:@"arrangedObjects" options:nil];
    [v bind:NSSelectionIndexesBinding toObject:ac2 withKeyPath:@"selectionIndexes" options:nil];
    [v bind:NSSortDescriptorsBinding toObject:ac2 withKeyPath:@"sortDescriptors" options:nil];
    printf("  rows %ld selected %s\n", (long)v.numberOfRows, IX(v.selectedRowIndexes));
    for (NSInteger r = 0; r < v.numberOfRows; r++) {
        NSTableCellView *cell = [v viewAtColumn:0 row:r makeIfNecessary:YES];
        printf("  row %ld obj %s text '%s'\n", (long)r, D(cell.objectValue), cell.textField.stringValue.UTF8String);
    }
    [ac2 addObject:[Person name:@"Ha" age:3]];
    printf("  after add rows %ld selected %s ac %s\n", (long)v.numberOfRows, IX(v.selectedRowIndexes),
           IX(ac2.selectionIndexes));
    [(Person *)[ac2.arrangedObjects objectAtIndex:0] setName:@"Fz"];
    NSTableCellView *cell0 = [v viewAtColumn:0 row:0 makeIfNecessary:YES];
    printf("  row 0 text '%s'\n", cell0.textField.stringValue.UTF8String);
    [v selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    printf("  table selects 0: ac %s\n", IX(ac2.selectionIndexes));
    v.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:NO] ];
    printf("  sorted: ac %s first %s selected %s\n", D(ac2.sortDescriptors.firstObject.key),
           D([ac2.arrangedObjects firstObject]), IX(v.selectedRowIndexes));
    cell0 = [v viewAtColumn:0 row:0 makeIfNecessary:YES];
    printf("  row 0 obj %s text '%s'\n", D(cell0.objectValue), cell0.textField.stringValue.UTF8String);
}


#pragma mark - A nib

@interface TablesOwner : NSObject
@property IBOutlet NSTableView *cellTable, *viewTable, *boundTable;
@property IBOutlet NSOutlineView *outline;
@property IBOutlet NSCollectionView *collection;
@property IBOutlet NSArrayController *arrayController;
@property IBOutlet NSView *root;
@property NSMutableArray *people;
@end
@implementation TablesOwner
@end

static void
dump_table_config(NSTableView *t)
{
    printf(" %s style %ld rowHeight %g spacing %s grid %lu alt %d multiple %d empty %d colsel %d reorder %d resize %d "
           "autoresizing %ld hl %ld rowSize %ld floats %d typeSelect %d autosave %d\n",
           CN(t), (long)t.style, t.rowHeight, Z(t.intercellSpacing), (unsigned long)t.gridStyleMask,
           t.usesAlternatingRowBackgroundColors, t.allowsMultipleSelection, t.allowsEmptySelection,
           t.allowsColumnSelection, t.allowsColumnReordering, t.allowsColumnResizing, (long)t.columnAutoresizingStyle,
           (long)t.selectionHighlightStyle, (long)t.rowSizeStyle, t.floatsGroupRows, t.allowsTypeSelect,
           t.autosaveTableColumns);
    printf("  frame %s header %s %s corner %s colors %s %s\n", S(t.frame), CN(t.headerView), S(t.headerView.frame),
           CN(t.cornerView), D(t.backgroundColor), D(t.gridColor));
    for (NSTableColumn *c in t.tableColumns)
        printf("  column %s width %g min %g max %g mask %lu editable %d hidden %d title '%s' align %ld tip %s proto %s "
               "data %s table %d\n",
               c.identifier.UTF8String, c.width, c.minWidth, c.maxWidth, (unsigned long)c.resizingMask, c.isEditable,
               c.isHidden, c.title.UTF8String, (long)[c.headerCell alignment], D(c.headerToolTip),
               D(c.sortDescriptorPrototype), CN(c.dataCell), c.tableView == t);
    NSScrollView *sv = t.enclosingScrollView;
    printf("  scroll %s clip %s bounds %s header in %s %s\n", S(sv.frame), S(sv.contentView.frame),
           S(sv.contentView.bounds), CN(t.headerView.superview), S(t.headerView.superview.frame));
}

/* The nib: the path given, next to the executable (the build directory), or where the VM installs it. */
static void
nib(const char *given)
{
    printf("== nib\n");
    NSString *path = given ? @(given)
                           : [[[NSProcessInfo processInfo].arguments[0] stringByDeletingLastPathComponent]
                                 stringByAppendingPathComponent:@"appkit-tables-test.nib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        path = @"/usr/local/share/finch/appkit-tables-test.nib";
    NSNib *n = [[NSNib alloc] initWithNibData:[NSData dataWithContentsOfFile:path] bundle:nil];
    TablesOwner *owner = [TablesOwner new];
    owner.people = [@[ [Person name:@"Jo" age:7], [Person name:@"Ki" age:8] ] mutableCopy];
    NSArray *top = nil;
    BOOL ok = [n instantiateWithOwner:owner topLevelObjects:&top];
    printf("loaded %d top %lu\n", ok, (unsigned long)top.count);
    dump_table_config(owner.cellTable);
    Rows *ds = [Rows new];
    ds.count = 3;
    owner.cellTable.dataSource = ds;
    printf("  rows %ld row 1 %s cell %s\n", (long)owner.cellTable.numberOfRows, S([owner.cellTable rectOfRow:1]),
           S([owner.cellTable frameOfCellAtColumn:1 row:1]));

    NSTableView *vt = owner.viewTable;
    dump_table_config(vt);
    NSMutableArray *keys = [[vt.registeredNibsByIdentifier allKeys] mutableCopy];
    [keys sortUsingSelector:@selector(compare:)];
    printf("  registered %s\n", [[keys componentsJoinedByString:@" "] UTF8String]);
    NSTableCellView *cell = [vt makeViewWithIdentifier:@"NameCell" owner:owner];
    printf("  made %s id %s frame %s text %s '%s' subviews %lu\n", CN(cell), cell.identifier.UTF8String, S(cell.frame),
           CN(cell.textField), cell.textField.stringValue.UTF8String, (unsigned long)cell.subviews.count);
    cell.objectValue = [Person name:@"Lu" age:9];
    printf("  objectValue set: text '%s'\n", cell.textField.stringValue.UTF8String);
    NSTableCellView *other = [vt makeViewWithIdentifier:@"OtherCell" owner:nil];
    printf("  other %s id %s distinct %d\n", CN(other), other.identifier.UTF8String,
           [vt makeViewWithIdentifier:@"NameCell" owner:owner] != cell);
    printf("  by column identifier %s\n", CN([vt makeViewWithIdentifier:@"main" owner:nil]));

    NSOutlineView *o = owner.outline;
    dump_table_config(o);
    printf("  indentation %g outline column %s autoresizes %d follows %d\n", o.indentationPerLevel,
           D(o.outlineTableColumn.identifier), o.autoresizesOutlineColumn, o.indentationMarkerFollowsCell);

    NSCollectionView *cv = owner.collection;
    NSCollectionViewFlowLayout *fl = (NSCollectionViewFlowLayout *)cv.collectionViewLayout;
    printf(" collection %s layout %s item %s line %g interitem %g inset %g %g %g %g selectable %d multiple %d colors %lu\n",
           S(cv.frame), CN(fl), Z(fl.itemSize), fl.minimumLineSpacing, fl.minimumInteritemSpacing, fl.sectionInset.top,
           fl.sectionInset.left, fl.sectionInset.bottom, fl.sectionInset.right, cv.isSelectable,
           cv.allowsMultipleSelection, (unsigned long)cv.backgroundColors.count);

    NSTableView *bt = owner.boundTable;
    dump_table_config(bt);
    binding_info(bt, NSContentBinding);
    binding_info(bt.tableColumns[0], NSValueBinding);
    dump_bound(bt);
    [owner.arrayController addObject:[Person name:@"Mo" age:10]];
    dump_bound(bt);
}


#pragma mark - Scroll views under a full-size content window's title bar

@interface FSToolbar : NSObject <NSToolbarDelegate>
@end
@implementation FSToolbar
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)t
{
    return @[ @"a" ];
}
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)t
{
    return @[ @"a" ];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)t itemForItemIdentifier:(NSString *)i willBeInsertedIntoToolbar:(BOOL)f
{
    NSToolbarItem *x = [[NSToolbarItem alloc] initWithItemIdentifier:i];
    x.label = @"A";
    return x;
}
@end

static void
dump_insets(const char *label, NSScrollView *sv)
{
    NSEdgeInsets a = sv.contentInsets, c = sv.contentView.contentInsets;
    printf("  %s: layout %s frame %s insets %g %g %g %g auto %d clip insets %g %g bounds %s visible %s\n", label,
           S(sv.window.contentLayoutRect), S(sv.frame), a.top, a.left, a.bottom, a.right,
           sv.automaticallyAdjustsContentInsets, c.top, c.bottom, S(sv.contentView.bounds), S(sv.documentVisibleRect));
}

static void
full_size(void)
{
    printf("== full-size content\n");
    FSToolbar *td = [FSToolbar new];
    for (int variant = 0; variant < 4; variant++) {
        NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable |
                                 (variant != 3 ? NSWindowStyleMaskFullSizeContentView : 0);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 400, 300) styleMask:mask
                                                    backing:NSBackingStoreBuffered defer:YES];
        w.releasedWhenClosed = NO;
        if (variant == 0 || variant == 2) {
            NSToolbar *t = [[NSToolbar alloc] initWithIdentifier:@"fs"];
            t.delegate = td;
            w.toolbar = t;
        }
        NSView *cv = w.contentView;
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:variant == 2 ? NSMakeRect(0, 0, 200, 150) : cv.bounds];
        sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSTableView *tv = make_table(NSTableViewStyleFullWidth, 30, NULL);
        sv.documentView = tv;
        printf(" %s%s, scroll view %s\n", variant == 3 ? "titled" : "full-size content",
               variant == 0 || variant == 2 ? " with a toolbar" : "", variant == 2 ? "at the bottom" : "filling the content");
        [cv addSubview:sv];
        dump_insets("added", sv);
        [w layoutIfNeeded];
        dump_insets("laid out", sv);
        sv.automaticallyAdjustsContentInsets = NO;
        dump_insets("not adjusting", sv);
        sv.automaticallyAdjustsContentInsets = YES;
        sv.contentInsets = NSEdgeInsetsMake(10, 0, 5, 0);
        dump_insets("set 10, 5", sv);
        [w layoutIfNeeded];
        dump_insets("laid out", sv);
        sv.automaticallyAdjustsContentInsets = NO;
        sv.contentInsets = NSEdgeInsetsMake(3, 0, 0, 0);
        [w layoutIfNeeded];
        dump_insets("not adjusting, set 3, laid out", sv);
        sv.automaticallyAdjustsContentInsets = YES;
        [w layoutIfNeeded];
        dump_insets("adjusting, laid out", sv);
        [sv setFrame:NSMakeRect(0, 0, 400, 250)];
        [w layoutIfNeeded];
        dump_insets("250 tall", sv);
        [sv setFrame:NSMakeRect(0, 20, 400, 200)];
        [w layoutIfNeeded];
        dump_insets("below the bar", sv);
        [w close];
    }
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 400, 300)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:YES];
    w.releasedWhenClosed = NO;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:[w.contentView bounds]];
    sv.documentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 1000)];
    [w.contentView addSubview:sv];
    [w layoutIfNeeded];
    printf(" an unflipped document\n");
    dump_insets("laid out", sv);
    [w close];
}

#pragma mark - main

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSTableView class]));
        [NSApplication sharedApplication];
        columns();
        geometry();
        selection();
        view_based();
        outlines();
        collections();
        bindings();
        nib(argc > 1 ? argv[1] : NULL);
        full_size();
    }
    return 0;
}
