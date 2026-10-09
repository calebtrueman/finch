/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-tables-window-test: tables, outlines and collection views on
 * Finch's window server, end to end. Starts a headless server, shows a
 * window with a cell-based table, a view-based table, an outline view and a
 * collection view, clicks, drags and types at them through the server, and
 * checks selection (plain, Shift and Command clicks, arrow keys), sorting by
 * a header click, resizing a column by its header edge, editing a cell
 * (double click, type, Return), disclosure triangles, collection item
 * selection, and that they draw (sampling the composited screen).
 * Finch-only: compare with appkit-tables-window-test.expected.
 *
 *   finch-appkit-tables-window-test [path to finch-windowserver]
 */
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include "../WindowServer/FinchWSProtocol.h"

extern char **environ;
bool FWSConnect(void);
void FWSPostEvent(const FWSEvent *e);
CGImageRef FWSCopyScreenImage(void);
void FWSSetCursorVisible(bool v);

static NSMutableArray<NSString *> *log_;

static void
flush_log(const char *label)
{
    printf("%s: %s\n", label, [log_ componentsJoinedByString:@"; "].UTF8String);
    [log_ removeAllObjects];
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

#pragma mark - Data

@interface Data : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property NSMutableArray<NSMutableDictionary *> *rows;
@end

@implementation Data
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t
{
    return _rows.count;
}
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    return _rows[r][c.identifier];
}
- (void)tableView:(NSTableView *)t setObjectValue:(id)v forTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    [log_ addObject:[NSString stringWithFormat:@"set %@ row %ld '%@'", c.identifier, (long)r, v]];
    _rows[r][c.identifier] = v;
}
- (void)tableView:(NSTableView *)t sortDescriptorsDidChange:(NSArray *)old
{
    NSSortDescriptor *d = t.sortDescriptors.firstObject;
    [log_ addObject:[NSString stringWithFormat:@"sort %@ %s", d.key, d.ascending ? "ascending" : "descending"]];
    [_rows sortUsingDescriptors:t.sortDescriptors];
    [t reloadData];
}
- (void)tableViewSelectionDidChange:(NSNotification *)n
{
    [log_ addObject:[NSString stringWithFormat:@"selection %s", IX([n.object selectedRowIndexes])]];
}
- (void)tableViewColumnDidResize:(NSNotification *)n
{
    [log_ addObject:[NSString stringWithFormat:@"resized %@", [n.userInfo[@"NSTableColumn"] identifier]]];
}
- (void)clicked:(NSTableView *)t
{
    [log_ addObject:[NSString stringWithFormat:@"action row %ld column %ld", (long)t.clickedRow, (long)t.clickedColumn]];
}
- (void)doubleClicked:(NSTableView *)t
{
    [log_ addObject:[NSString stringWithFormat:@"double row %ld", (long)t.clickedRow]];
}
@end

@interface Views : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation Views
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t
{
    return 6;
}
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    return [NSString stringWithFormat:@"Item %ld", (long)r];
}
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    NSTableCellView *v = [t makeViewWithIdentifier:@"cell" owner:self];
    if (!v) {
        v = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 100, 24)];
        v.identifier = @"cell";
        NSTextField *f = [NSTextField labelWithString:@""];
        f.frame = NSMakeRect(2, 4, 100, 16);
        f.autoresizingMask = NSViewWidthSizable;
        [v addSubview:f];
        v.textField = f;
        [f bind:NSValueBinding toObject:v withKeyPath:@"objectValue" options:nil];
    }
    return v;
}
@end

@interface Node : NSObject
@property NSString *name;
@property NSArray *children;
@end
@implementation Node
@end

@interface Tree : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property NSArray<Node *> *roots;
@end

@implementation Tree
- (NSInteger)outlineView:(NSOutlineView *)o numberOfChildrenOfItem:(Node *)item
{
    return item ? item.children.count : _roots.count;
}
- (id)outlineView:(NSOutlineView *)o child:(NSInteger)i ofItem:(Node *)item
{
    return item ? item.children[i] : _roots[i];
}
- (BOOL)outlineView:(NSOutlineView *)o isItemExpandable:(Node *)item
{
    return item.children.count > 0;
}
- (id)outlineView:(NSOutlineView *)o objectValueForTableColumn:(NSTableColumn *)c byItem:(Node *)item
{
    return item.name;
}
- (void)outlineViewItemDidExpand:(NSNotification *)n
{
    [log_ addObject:[NSString stringWithFormat:@"expanded %@", [n.userInfo[@"NSObject"] name]]];
}
- (void)outlineViewItemDidCollapse:(NSNotification *)n
{
    [log_ addObject:[NSString stringWithFormat:@"collapsed %@", [n.userInfo[@"NSObject"] name]]];
}
@end

static Node *
node(NSString *name, NSArray *children)
{
    Node *n = [Node new];
    n.name = name;
    n.children = children;
    return n;
}

@interface Tile : NSCollectionViewItem
@end
@implementation Tile
- (void)loadView
{
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 40, 40)];
}
@end

@interface Tiles : NSObject <NSCollectionViewDataSource, NSCollectionViewDelegate>
@end
@implementation Tiles
- (NSInteger)collectionView:(NSCollectionView *)cv numberOfItemsInSection:(NSInteger)s
{
    return 6;
}
- (NSCollectionViewItem *)collectionView:(NSCollectionView *)cv itemForRepresentedObjectAtIndexPath:(NSIndexPath *)p
{
    NSCollectionViewItem *it = [cv makeItemWithIdentifier:@"tile" forIndexPath:p];
    it.representedObject = @(p.item);
    return it;
}
- (void)collectionView:(NSCollectionView *)cv didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths
{
    [log_ addObject:[NSString stringWithFormat:@"collection selected %ld", (long)paths.anyObject.item]];
}
- (void)collectionView:(NSCollectionView *)cv didDeselectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)paths
{
    [log_ addObject:[NSString stringWithFormat:@"collection deselected %lu", (unsigned long)paths.count]];
}
@end

#pragma mark - The screen and events

static void
pump(double seconds)
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    for (;;) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
        if (!e)
            break;
        [NSApp sendEvent:e];
    }
    [NSApp updateWindows];
}

static CFDataRef screen;
static size_t screen_bpr;

static void
snapshot(void)
{
    if (screen)
        CFRelease(screen);
    CGImageRef im = FWSCopyScreenImage();
    screen = CGDataProviderCopyData(CGImageGetDataProvider(im));
    screen_bpr = CGImageGetBytesPerRow(im);
    CGImageRelease(im);
}

/* The window's content origin is at (100, 100) on an 800 by 600 screen: content (x, y) is (100 + x, 500 - y). */
static const uint8_t *
pixel(double x, double y)
{
    double sx = 100 + x, sy = 500 - y;
    return CFDataGetBytePtr(screen) + (size_t)(sy * 2) * screen_bpr + (size_t)(sx * 2) * 4;
}

/* Classify a pixel: accent (blue), light, dark, or other, so the expected output doesn't pin exact colours. */
static const char *
kind(const uint8_t *p)
{
    int r = p[2], g = p[1], b = p[0];
    if (b > 180 && r < 120 && g > 60 && g < 170)
        return "accent";
    if (r > 225 && g > 225 && b > 225)
        return "light";
    if (r < 90 && g < 90 && b < 90)
        return "dark";
    return "other";
}

static void
sample(const char *label, double x, double y)
{
    printf("%s: %s\n", label, kind(pixel(x, y)));
}

/* Text in a content rect: dark pixels (or light ones on a selection). */
static void
has_ink(const char *label, NSRect r, BOOL light)
{
    int n = 0;
    for (double y = r.origin.y; y < NSMaxY(r); y += 0.5)
        for (double x = r.origin.x; x < NSMaxX(r); x += 0.5) {
            const uint8_t *p = pixel(x, y);
            if (light ? (p[0] > 235 && p[1] > 235 && p[2] > 235) : (p[0] < 110 && p[1] < 110 && p[2] < 110))
                n++;
        }
    printf("%s: %s\n", label, n > 4 ? "ink" : "blank");
}

/* FINCH_TWT_PNG=path writes the screen as a PNG, to look at. */
static void
save_png(void)
{
    const char *path = getenv("FINCH_TWT_PNG");
    if (!path)
        return;
    CGImageRef im = FWSCopyScreenImage();
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (d) {
        CGImageDestinationAddImage(d, im, NULL);
        CGImageDestinationFinalize(d);
        CFRelease(d);
    }
    CFRelease(url);
    CGImageRelease(im);
}

enum { SHIFT = 0x20000, COMMAND = 0x100000 };

static void
post(uint32_t type, double x, double y, unichar c, uint32_t code, uint64_t flags)
{
    FWSEvent e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.screen_x = 100 + x, e.screen_y = 500 - y;
    e.modifiers = flags;
    e.key_code = code;
    if (c) {
        e.characters[0] = e.unmodified[0] = c;
        e.length = 1;
    }
    FWSPostEvent(&e);
}

static void
click_with(double x, double y, uint64_t flags)
{
    post(FWS_EVENT_LEFT_DOWN, x, y, 0, 0, flags);
    post(FWS_EVENT_LEFT_UP, x, y, 0, 0, flags);
    pump(0.3);
}

static void
click(double x, double y)
{
    click_with(x, y, 0);
}

static void
key(unichar c, uint32_t code)
{
    post(FWS_EVENT_KEY_DOWN, 0, 0, c, code, 0);
    post(FWS_EVENT_KEY_UP, 0, 0, c, code, 0);
}

/* A point in a view, in the window's content (y up). */
static NSPoint
in_content(NSView *v, NSPoint p)
{
    return [v convertPoint:p toView:v.window.contentView];
}

static NSPoint
row_point(NSTableView *t, NSInteger row, NSInteger column)
{
    NSRect r = NSIntersectionRect([t rectOfRow:row], [t rectOfColumn:column]);
    return in_content(t, NSMakePoint(NSMidX(r), NSMidY(r)));
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *server = argc > 1 ? argv[1] : "/usr/libexec/finch-windowserver";
        char sock[64];
        snprintf(sock, sizeof sock, "/tmp/finch-atwt.%d", getpid());
        setenv(FWS_SOCKET_ENV, sock, 1);
        pid_t pid;
        char *args[] = {(char *)server, "--headless", "--size", "800x600", "--scale", "2", NULL};
        if (posix_spawn(&pid, server, NULL, NULL, args, environ)) {
            printf("can't start %s\n", server);
            return 1;
        }
        for (int i = 0; i < 100 && !FWSConnect(); i++)
            usleep(20000);
        FWSSetCursorVisible(false);
        log_ = [NSMutableArray array];
        [NSApplication sharedApplication];
        [NSApp finishLaunching];

        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 600, 400)
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:YES];
        w.releasedWhenClosed = NO;
        w.title = @"Tables";
        NSView *content = w.contentView;

        /* a cell-based table with a header, grid and alternating rows */
        Data *data = [Data new];
        data.rows = [NSMutableArray array];
        NSArray *names = @[ @"Pear", @"Apple", @"Fig", @"Kiwi", @"Lime", @"Date", @"Plum", @"Yuzu" ];
        for (NSUInteger i = 0; i < names.count; i++)
            [data.rows addObject:[@{@"name" : names[i], @"count" : @(10 + i)} mutableCopy]];
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 170, 280, 220)];
        sv.borderType = NSNoBorder;
        NSTableView *t = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 280, 220)];
        t.style = NSTableViewStyleFullWidth;
        t.rowHeight = 20;
        t.usesAlternatingRowBackgroundColors = YES;
        t.gridStyleMask = NSTableViewSolidVerticalGridLineMask;
        t.allowsMultipleSelection = YES;
        NSTableColumn *cn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
        cn.title = @"Name";
        cn.width = 140;
        cn.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];
        NSTableColumn *cc = [[NSTableColumn alloc] initWithIdentifier:@"count"];
        cc.title = @"Count";
        cc.width = 80;
        cc.editable = NO;
        [t addTableColumn:cn];
        [t addTableColumn:cc];
        t.dataSource = data;
        t.delegate = data;
        t.target = data;
        t.action = @selector(clicked:);
        t.doubleAction = @selector(doubleClicked:);
        sv.documentView = t;
        [content addSubview:sv];

        /* a view-based table */
        Views *views = [Views new];
        NSScrollView *sv2 = [[NSScrollView alloc] initWithFrame:NSMakeRect(300, 170, 140, 220)];
        NSTableView *vt = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 140, 220)];
        vt.headerView = nil;
        NSTableColumn *vc = [[NSTableColumn alloc] initWithIdentifier:@"v"];
        vc.width = 100;
        [vt addTableColumn:vc];
        vt.dataSource = views;
        vt.delegate = views;
        sv2.documentView = vt;
        [content addSubview:sv2];

        /* an outline view */
        Tree *tree = [Tree new];
        tree.roots = @[ node(@"Fruit", @[ node(@"Apple", nil), node(@"Pear", nil) ]), node(@"Nuts", @[ node(@"Pecan", nil) ]),
                        node(@"Herbs", nil) ];
        NSScrollView *sv3 = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 10, 280, 150)];
        NSOutlineView *ov = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 280, 150)];
        ov.style = NSTableViewStylePlain;
        ov.rowHeight = 20;
        NSTableColumn *oc = [[NSTableColumn alloc] initWithIdentifier:@"o"];
        oc.width = 200;
        [ov addTableColumn:oc];
        ov.outlineTableColumn = oc;
        ov.headerView = nil;
        ov.dataSource = tree;
        ov.delegate = tree;
        sv3.documentView = ov;
        [content addSubview:sv3];

        /* a collection view */
        Tiles *tiles = [Tiles new];
        NSScrollView *sv4 = [[NSScrollView alloc] initWithFrame:NSMakeRect(300, 10, 290, 150)];
        NSCollectionView *cv = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 290, 150)];
        NSCollectionViewFlowLayout *fl = [NSCollectionViewFlowLayout new];
        fl.itemSize = NSMakeSize(60, 50);
        fl.minimumInteritemSpacing = 10;
        fl.minimumLineSpacing = 10;
        fl.sectionInset = NSEdgeInsetsMake(10, 10, 10, 10);
        cv.collectionViewLayout = fl;
        [cv registerClass:[Tile class] forItemWithIdentifier:@"tile"];
        cv.dataSource = tiles;
        cv.delegate = tiles;
        cv.selectable = YES;
        sv4.documentView = cv;
        [content addSubview:sv4];

        [w makeKeyAndOrderFront:nil];
        pump(0.3);

        printf("table frame %s header %s rows %ld\n", NSStringFromRect(t.frame).UTF8String,
               NSStringFromRect([t.headerView convertRect:t.headerView.bounds toView:content]).UTF8String,
               (long)t.numberOfRows);
        snapshot();
        save_png();
        NSPoint hp = [t.headerView convertPoint:NSMakePoint(60, 14) toView:content];
        sample("header background", hp.x, hp.y);
        NSRect title = [t.headerView convertRect:NSMakeRect(8, 7, 40, 14) toView:content];
        has_ink("header title", title, NO);
        NSPoint r0 = row_point(t, 0, 0), r1 = row_point(t, 1, 0);
        sample("row 0 background", r0.x + 60, r0.y);
        sample("row 1 background", r1.x + 60, r1.y);
        printf("rows alternate: %d\n", memcmp(pixel(r0.x + 60, r0.y), pixel(r1.x + 60, r1.y), 3) != 0);
        NSRect cell0 = [t convertRect:[t frameOfCellAtColumn:0 row:0] toView:content];
        has_ink("row 0 text", NSMakeRect(cell0.origin.x, cell0.origin.y, 40, cell0.size.height), NO);
        NSRect grid = [t convertRect:[t rectOfColumn:0] toView:content];
        int gridLine = 0;
        for (double x = NSMaxX(grid) - 1.5; x <= NSMaxX(grid) + 0.5; x += 0.5) {
            const uint8_t *p = pixel(x, r0.y + 30);
            if (p[0] < 225)
                gridLine = 1;
        }
        printf("grid line: %s\n", gridLine ? "drawn" : "missing");

        /* selection by clicks */
        NSPoint p2 = row_point(t, 2, 0);
        click(p2.x, p2.y);
        flush_log("click row 2");
        printf("first responder is the table %d\n", w.firstResponder == t);
        snapshot();
        sample("selected row", p2.x + 50, p2.y);
        has_ink("selected row text", NSMakeRect(cell0.origin.x, p2.y - 7, 40, 14), YES);
        NSPoint p4 = row_point(t, 4, 1);
        click_with(p4.x, p4.y, SHIFT);
        flush_log("shift-click row 4");
        NSPoint p3 = row_point(t, 3, 0);
        click_with(p3.x, p3.y, COMMAND);
        flush_log("command-click row 3");
        click(p4.x, p4.y);
        flush_log("click row 4");
        key(NSDownArrowFunctionKey, 125);
        pump(0.3);
        flush_log("down arrow");
        key(NSUpArrowFunctionKey, 126);
        key(NSUpArrowFunctionKey, 126);
        pump(0.3);
        flush_log("up arrow twice");

        /* sorting by the header */
        click(hp.x, hp.y);
        flush_log("click name header");
        printf("first row %s\n", [data.rows[0][@"name"] UTF8String]);
        click(hp.x, hp.y);
        flush_log("click name header again");
        printf("first row %s\n", [data.rows[0][@"name"] UTF8String]);
        snapshot();
        sample("header after sorting", hp.x, hp.y);

        /* resizing the name column by its header edge */
        NSPoint edge = [t.headerView convertPoint:NSMakePoint(NSMaxX([t.headerView headerRectOfColumn:0]) - 1, 14)
                                           toView:content];
        post(FWS_EVENT_LEFT_DOWN, edge.x, edge.y, 0, 0, 0);
        post(FWS_EVENT_LEFT_DRAGGED, edge.x + 10, edge.y, 0, 0, 0);
        post(FWS_EVENT_LEFT_DRAGGED, edge.x + 20, edge.y, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, edge.x + 20, edge.y, 0, 0, 0);
        pump(0.3);
        printf("name width %g\n", cn.width);
        [log_ removeAllObjects];

        /* editing a cell: double click, type, Return */
        NSPoint e1 = row_point(t, 1, 0);
        post(FWS_EVENT_LEFT_DOWN, e1.x, e1.y, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, e1.x, e1.y, 0, 0, 0);
        post(FWS_EVENT_LEFT_DOWN, e1.x, e1.y, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, e1.x, e1.y, 0, 0, 0);
        pump(0.3);
        printf("editing row %ld column %ld editor %d\n", (long)t.editedRow, (long)t.editedColumn,
               t.currentEditor != nil);
        [t.currentEditor selectAll:nil];
        key('z', 6);
        key('z', 6);
        key('\r', 36);
        pump(0.3);
        flush_log("edited");
        printf("editing after return %d row 1 '%s'\n", t.currentEditor != nil, [data.rows[1][@"name"] UTF8String]);
        /* a double click on a column that isn't editable sends the double action */
        NSPoint d1 = row_point(t, 5, 1);
        post(FWS_EVENT_LEFT_DOWN, d1.x, d1.y, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, d1.x, d1.y, 0, 0, 0);
        post(FWS_EVENT_LEFT_DOWN, d1.x, d1.y, 0, 0, 0);
        post(FWS_EVENT_LEFT_UP, d1.x, d1.y, 0, 0, 0);
        pump(0.3);
        flush_log("double click count");

        /* the view-based table */
        printf("view-based rows with views %ld\n", (long)vt.subviews.count);
        NSPoint v2 = row_point(vt, 2, 0);
        click(v2.x, v2.y);
        printf("view-based selected %s row view selected %d emphasized %d text %s\n", IX(vt.selectedRowIndexes),
               [vt rowViewAtRow:2 makeIfNecessary:NO].selected, [vt rowViewAtRow:2 makeIfNecessary:NO].emphasized,
               [[[vt viewAtColumn:0 row:2 makeIfNecessary:NO] textField] stringValue].UTF8String);
        snapshot();
        sample("view-based selection", v2.x + 40, v2.y);
        sample("view-based other row", v2.x + 40, row_point(vt, 4, 0).y);

        /* the outline view: disclosure triangles */
        printf("outline rows %ld\n", (long)ov.numberOfRows);
        snapshot();
        NSRect tri = [ov convertRect:[ov frameOfOutlineCellAtRow:0] toView:content];
        int marks = 0;
        for (double y = NSMinY(tri); y < NSMaxY(tri); y += 0.5)
            for (double x = NSMinX(tri); x < NSMaxX(tri); x += 0.5)
                if (pixel(x, y)[1] < 200)
                    marks++;
        printf("disclosure triangle: %s\n", marks > 4 ? "drawn" : "blank");
        click(NSMidX(tri), NSMidY(tri));
        flush_log("click triangle of Fruit");
        printf("outline rows %ld row 1 %s level %ld\n", (long)ov.numberOfRows, [[ov itemAtRow:1] name].UTF8String,
               (long)[ov levelForRow:1]);
        NSRect tri3 = [ov convertRect:[ov frameOfOutlineCellAtRow:3] toView:content];
        click(NSMidX(tri3), NSMidY(tri3));
        flush_log("click triangle of Nuts");
        printf("outline rows %ld\n", (long)ov.numberOfRows);
        click(NSMidX(tri), NSMidY(tri));
        flush_log("click triangle of Fruit again");
        printf("outline rows %ld selected %s\n", (long)ov.numberOfRows, IX(ov.selectedRowIndexes));
        NSPoint o1 = row_point(ov, 0, 0);
        click(o1.x + 40, o1.y);
        printf("outline selected %s %s\n", IX(ov.selectedRowIndexes), [[ov itemAtRow:ov.selectedRow] name].UTF8String);
        key(NSRightArrowFunctionKey, 124);
        pump(0.3);
        flush_log("right arrow");
        printf("outline rows %ld\n", (long)ov.numberOfRows);

        /* the collection view */
        printf("collection items %lu\n", (unsigned long)cv.visibleItems.count);
        NSCollectionViewItem *it1 = [cv itemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]];
        NSPoint c1 = in_content(cv, NSMakePoint(NSMidX(it1.view.frame), NSMidY(it1.view.frame)));
        click(c1.x, c1.y);
        flush_log("click item 1");
        printf("item 1 selected %d selection %lu\n", it1.isSelected, (unsigned long)cv.selectionIndexPaths.count);
        click(5 + in_content(cv, NSZeroPoint).x, c1.y);
        flush_log("click between items");
        const char *png2 = getenv("FINCH_TWT_PNG2");
        if (png2) {
            setenv("FINCH_TWT_PNG", png2, 1);
            save_png();
        }

        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        unlink(sock);
    }
    return 0;
}
