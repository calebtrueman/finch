/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Public container behavior, compared with the same binary on Apple and Finch.
 * argv[1] is the directory containing the two compiled test nibs (by default the
 * executable's, or /usr/local/share/finch in the VM). --windows
 * additionally exercises visible popovers, dismissal and drawers. */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#import "appkit-color-browser-test.inc"

static const char *srect(NSRect r)
{
    return NSStringFromRect(r).UTF8String;
}
static const char *ssize(NSSize s)
{
    return NSStringFromSize(s).UTF8String;
}
static void pump(double seconds)
{
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}
static NSView *box(CGFloat w, CGFloat h)
{
    NSView *v = [[[NSView alloc] initWithFrame:NSZeroRect] autorelease];
    if (w >= 0)
        [[v.widthAnchor constraintEqualToConstant:w] setActive:YES];
    if (h >= 0)
        [[v.heightAnchor constraintEqualToConstant:h] setActive:YES];
    return v;
}
static void grids(void)
{
    NSGridView *g = [NSGridView new];
    printf("grid defaults %ld %ld %ld %ld %ld %.0f %.0f %d %d %.0f %.0f %.0f %.0f %s\n", g.numberOfRows,
           g.numberOfColumns, g.xPlacement, g.yPlacement, g.rowAlignment, g.rowSpacing, g.columnSpacing,
           g.translatesAutoresizingMaskIntoConstraints, g.flipped, [g contentHuggingPriorityForOrientation:0],
           [g contentHuggingPriorityForOrientation:1], [g contentCompressionResistancePriorityForOrientation:0],
           [g contentCompressionResistancePriorityForOrientation:1], ssize(g.intrinsicContentSize));
    [g release];
    for (int test = 0; test < 10; test++) {
        NSView *a = box(test == 3 ? 80 : 40, test == 3 ? 30 : 20), *b = box(60, 30), *c = box(80, 10),
               *d = box(-1, test == 4 ? 10 : -1);
        g = [NSGridView gridViewWithViews:@[ @[ a, b ], @[ c, d ] ]];
        if (test == 0) {
            NSGridRow *r = [g rowAtIndex:0];
            NSGridColumn *col = [g columnAtIndex:0];
            NSGridCell *cell = [g cellForView:a];
            printf("grid row/cell %ld %ld %d %d %ld %ld %d %d %ld %ld %ld %lu %d\n", r.numberOfCells, r.yPlacement,
                   r.height == NSGridViewSizeForContent, r.gridView == g, col.numberOfCells, col.xPlacement,
                   col.width == NSGridViewSizeForContent, col.gridView == g, cell.xPlacement, cell.yPlacement,
                   cell.rowAlignment, cell.customPlacementConstraints.count, cell.row == r && cell.column == col);
        }
        if (test == 1) {
            [g columnAtIndex:0].leadingPadding = 5;
            [g columnAtIndex:1].trailingPadding = 7;
            [g rowAtIndex:0].topPadding = 3;
            [g rowAtIndex:1].bottomPadding = 4;
        }
        if (test == 2) {
            g.xPlacement = NSGridCellPlacementCenter;
            g.yPlacement = NSGridCellPlacementBottom;
        }
        if (test == 3) {
            g.xPlacement = NSGridCellPlacementFill;
            g.yPlacement = NSGridCellPlacementFill;
        }
        if (test == 4) {
            [g columnAtIndex:0].width = 100;
            [g rowAtIndex:1].height = 50;
        }
        NSView *host = nil;
        if (test == 5) {
            host = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)] autorelease];
            g.translatesAutoresizingMaskIntoConstraints = NO;
            [host addSubview:g];
            [NSLayoutConstraint activateConstraints:@[
                [g.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
                [g.topAnchor constraintEqualToAnchor:host.topAnchor], [g.widthAnchor constraintEqualToConstant:300],
                [g.heightAnchor constraintEqualToConstant:200]
            ]];
            [host layoutSubtreeIfNeeded];
        }
        if (test == 6) {
            [g addRowWithViews:@[ box(150, 15) ]];
            [g mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(2, 1)];
        }
        if (test == 7)
            [g rowAtIndex:0].hidden = YES;
        if (test == 8) {
            [g columnAtIndex:0].width = 100;
            [g cellForView:a].xPlacement = NSGridCellPlacementNone;
            [g cellForView:a].customPlacementConstraints = @[ [a.leadingAnchor constraintEqualToAnchor:g.leadingAnchor
                                                                                              constant:10] ];
        }
        if (test == 9) {
            g.rowSpacing = 0;
            g.columnSpacing = 10;
            [g columnAtIndex:1].xPlacement = NSGridCellPlacementTrailing;
            [g cellForView:a].xPlacement = NSGridCellPlacementCenter;
        }
        [g layoutSubtreeIfNeeded];
        printf("grid %d %s %s %s %s %s %s hidden %d %d\n", test, srect(g.frame), ssize(g.fittingSize), srect(a.frame),
               srect(b.frame), srect(c.frame), srect(d.frame), a.hidden, b.hidden);
    }
    g = [NSGridView gridViewWithNumberOfColumns:2 rows:2];
    NSView *a = box(20, 10);
    [g cellAtColumnIndex:0 rowIndex:0].contentView = a;
    [g insertRowAtIndex:1 withViews:@[]];
    [g moveRowAtIndex:0 toIndex:2];
    [g moveColumnAtIndex:0 toIndex:1];
    printf("grid move %ld %ld %ld %ld\n", g.numberOfRows, g.numberOfColumns, [g indexOfRow:[g cellForView:a].row],
           [g indexOfColumn:[g cellForView:a].column]);
    [g removeRowAtIndex:0];
    [g removeColumnAtIndex:0];
    printf("grid remove %ld %ld found %d\n", g.numberOfRows, g.numberOfColumns, [g cellForView:a] != nil);
}
@interface RuleDelegate : NSObject <NSRuleEditorDelegate>
@end
@implementation RuleDelegate
- (NSInteger)ruleEditor:(NSRuleEditor *)e numberOfChildrenForCriterion:(id)c withRowType:(NSRuleEditorRowType)t
{
    return c ? 0 : t == NSRuleEditorRowTypeCompound ? 1 : 2;
}
- (id)ruleEditor:(NSRuleEditor *)e child:(NSInteger)i forCriterion:(id)c withRowType:(NSRuleEditorRowType)t
{
    return t == NSRuleEditorRowTypeCompound ? @"All" : @[ @"Name", @"Age" ][i];
}
- (id)ruleEditor:(NSRuleEditor *)e displayValueForCriterion:(id)c inRow:(NSInteger)r
{
    return c;
}
- (NSDictionary *)ruleEditor:(NSRuleEditor *)e
    predicatePartsForCriterion:(id)c
              withDisplayValue:(id)v
                         inRow:(NSInteger)r
{
    return [c isEqual:@"All"] ? @{NSRuleEditorPredicateCompoundType : @(NSAndPredicateType)} : @{
        NSRuleEditorPredicateLeftExpression :
            [NSExpression expressionForKeyPath:[c isEqual:@"Name"] ? @"name" : @"age"],
        NSRuleEditorPredicateRightExpression :
            [NSExpression expressionForConstantValue:[c isEqual:@"Name"] ? @"fox" : @12],
        NSRuleEditorPredicateOperatorType : @(NSEqualToPredicateOperatorType)
    };
}
@end
static void rules(void)
{
    NSRuleEditor *r = [[[NSRuleEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)] autorelease];
    printf("rule defaults %ld %lu %.0f %d %d %lu %d %s %s %s %s %s %s\n", r.numberOfRows, r.nestingMode, r.rowHeight,
           r.editable, r.canRemoveAllRows, r.selectedRowIndexes.count, r.formattingDictionary != nil,
           NSStringFromClass(r.rowClass).UTF8String, r.rowTypeKeyPath.UTF8String, r.subrowsKeyPath.UTF8String,
           r.criteriaKeyPath.UTF8String, r.displayValuesKeyPath.UTF8String, srect(r.frame));
    RuleDelegate *d = [[[RuleDelegate alloc] init] autorelease];
    r.delegate = d;
    [r insertRowAtIndex:0 withType:NSRuleEditorRowTypeCompound asSubrowOfRow:-1 animate:NO];
    [r insertRowAtIndex:1 withType:NSRuleEditorRowTypeSimple asSubrowOfRow:0 animate:NO];
    [r insertRowAtIndex:2 withType:NSRuleEditorRowTypeSimple asSubrowOfRow:0 animate:NO];
    [r setCriteria:@[ @"Age" ] andDisplayValues:@[ @"Age" ] forRowAtIndex:2];
    [r selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [r selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:YES];
    printf("rule rows %ld children %lu parent %ld criteria %s valueRow %ld selected %lu frame %s predicate %s\n",
           r.numberOfRows, [r subrowIndexesForRow:0].count, [r parentRowForRow:2],
           [[r criteriaForRow:2].firstObject UTF8String], [r rowForDisplayValue:[r displayValuesForRow:2].firstObject],
           r.selectedRowIndexes.count, srect(r.frame), r.predicate.predicateFormat.UTF8String);
    [r removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:0] includeSubrows:NO];
    printf("rule adopted %ld roots %lu parents %ld %ld predicate %s\n", r.numberOfRows,
           [r subrowIndexesForRow:-1].count, [r parentRowForRow:0], [r parentRowForRow:1],
           r.predicate.predicateFormat.UTF8String);
    [r removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:0] includeSubrows:YES];
    printf("rule removed %ld predicate %s\n", r.numberOfRows, r.predicate.predicateFormat.UTF8String);
    @try {
        [r subrowIndexesForRow:50];
    } @catch (NSException *e) {
        printf("rule invalid %s\n", e.name.UTF8String);
    }
    NSPredicateEditorRowTemplate *t =
        [[[NSPredicateEditorRowTemplate alloc] initWithLeftExpressions:@[ [NSExpression expressionForKeyPath:@"name"] ]
                                          rightExpressionAttributeType:NSStringAttributeType
                                                              modifier:NSDirectPredicateModifier
                                                             operators:@[ @4, @99 ]
                                                               options:NSCaseInsensitivePredicateOption] autorelease];
    printf("template defaults %lu %lu %lu %lu %lu %lu %lu %lu\n", t.leftExpressions.count, t.rightExpressions.count,
           t.rightExpressionAttributeType, t.modifier, t.operators.count, t.options, t.compoundTypes.count,
           t.templateViews.count);
    for (NSString *s in
         @[ @"name == 'x'", @"name CONTAINS[c] 'x'", @"age == 5", @"name == 5", @"name CONTAINS[cd] 'x'" ])
        printf("template match %.3f\n", [t matchForPredicate:[NSPredicate predicateWithFormat:s]]);
    [t setPredicate:[NSPredicate predicateWithFormat:@"name CONTAINS[c] 'fox'"]];
    printf("template predicate %s\n", [t predicateWithSubpredicates:nil].predicateFormat.UTF8String);
    NSPredicateEditorRowTemplate *copy = [[t copy] autorelease];
    printf("template copy %d %s\n", copy != t, [copy predicateWithSubpredicates:nil].predicateFormat.UTF8String);
    NSPredicateEditor *editor = [[[NSPredicateEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)] autorelease];
    printf("predicate defaults %ld %lu\n", editor.numberOfRows, editor.rowTemplates.count);
    editor.rowTemplates = [editor.rowTemplates arrayByAddingObject:t];
    editor.objectValue = [NSPredicate predicateWithFormat:@"name CONTAINS[c] 'fox' AND name ==[c] 'owl'"];
    printf("predicate rows %ld roots %lu subrows %lu value %s\n", editor.numberOfRows,
           [editor subrowIndexesForRow:-1].count, [editor subrowIndexesForRow:0].count,
           [editor.objectValue predicateFormat].UTF8String);
    [editor removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:1] includeSubrows:YES];
    printf("predicate removed %ld value %s\n", editor.numberOfRows, [editor.objectValue predicateFormat].UTF8String);
}
@interface PageDelegate : NSObject <NSPageControllerDelegate>
@end
@implementation PageDelegate
- (NSString *)pageController:(NSPageController *)p identifierForObject:(id)o
{
    return o;
}
- (NSViewController *)pageController:(NSPageController *)p viewControllerForIdentifier:(NSString *)i
{
    NSViewController *v = [[[NSViewController alloc] init] autorelease];
    v.view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 80, 60)] autorelease];
    return v;
}
- (void)pageController:(NSPageController *)p prepareViewController:(NSViewController *)v withObject:(id)o
{
    v.representedObject = o;
}
@end
static void pages(void)
{
    NSPageController *p = [[[NSPageController alloc] init] autorelease];
    printf("page defaults %ld %ld %lu %d %d\n", p.transitionStyle, p.selectedIndex, p.arrangedObjects.count,
           p.selectedViewController != nil, p.viewLoaded);
    p.arrangedObjects = @[ @"A", @"B" ];
    printf("page objects %ld %d\n", p.selectedIndex, p.selectedViewController != nil);
    @try {
        p.selectedIndex = 4;
    } @catch (NSException *e) {
        printf("page invalid %s\n", e.name.UTF8String);
    }
    PageDelegate *d = [[[PageDelegate alloc] init] autorelease];
    p.delegate = d;
    p.view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 180)] autorelease];
    p.selectedIndex = 1;
    printf("page selected %ld %s %s\n", p.selectedIndex, [[p.selectedViewController representedObject] UTF8String],
           srect(p.selectedViewController.view.frame));
    p.selectedIndex = 0;
    printf("page back %ld\n", p.selectedIndex);
    NSPageController *history = [[[NSPageController alloc] init] autorelease];
    history.arrangedObjects = @[ @"A", @"B" ];
    history.selectedIndex = 1;
    [history navigateBack:nil];
    [history navigateForwardToObject:@"C"];
    printf("page append %ld %lu %s\n", history.selectedIndex, history.arrangedObjects.count,
           [[history.arrangedObjects lastObject] UTF8String]);
}
@interface PopDelegate : NSObject <NSPopoverDelegate>
@property BOOL allow;
@property(retain) NSMutableString *events;
@end
@implementation PopDelegate
- (BOOL)popoverShouldClose:(NSPopover *)p
{
    [_events appendString:@"?"];
    return _allow;
}
- (void)popoverWillShow:(NSNotification *)n
{
    [_events appendString:@"W"];
}
- (void)popoverDidShow:(NSNotification *)n
{
    [_events appendString:@"D"];
}
- (void)popoverWillClose:(NSNotification *)n
{
    [_events appendString:@"w"];
}
- (void)popoverDidClose:(NSNotification *)n
{
    [_events appendString:@"d"];
}
- (void)dealloc
{
    [_events release];
    [super dealloc];
}
@end
static void popovers(BOOL windows)
{
    NSPopover *p = [[[NSPopover alloc] init] autorelease];
    printf("popover defaults %ld %d %d %d %s %s %d %d\n", p.behavior, p.animates, p.shown, p.detached,
           ssize(p.contentSize), srect(p.positioningRect), p.contentViewController != nil, p.hasFullSizeContent);
    NSViewController *v = [[[NSViewController alloc] init] autorelease];
    v.view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 120, 60)] autorelease];
    p.contentViewController = v;
    p.animates = NO;
    NSWindow *w = [[[NSWindow alloc] initWithContentRect:NSMakeRect(300, 300, 400, 200)
                                               styleMask:NSWindowStyleMaskTitled
                                                 backing:NSBackingStoreBuffered
                                                   defer:YES] autorelease];
    w.releasedWhenClosed = NO;
    NSView *anchor = [[[NSView alloc] initWithFrame:NSMakeRect(50, 50, 100, 30)] autorelease];
    [w.contentView addSubview:anchor];
    [p showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSMinYEdge];
    printf("popover hidden parent %d %s\n", p.shown, ssize(p.contentSize));
    @try {
        [p showRelativeToRect:NSZeroRect ofView:[[[NSView alloc] init] autorelease] preferredEdge:0];
    } @catch (NSException *e) {
        printf("popover invalid %s\n", e.name.UTF8String);
    }
    NSDrawer *d = [[[NSDrawer alloc] initWithContentSize:NSMakeSize(120, 80) preferredEdge:NSMinXEdge] autorelease];
    printf("drawer defaults %s %s %d %.0f %.0f %lu %ld %d\n", ssize(d.contentSize), ssize(d.minContentSize),
           d.maxContentSize.width > 1e30, d.leadingOffset, d.trailingOffset, d.edge, d.state, d.contentView != nil);
    [d open];
    printf("drawer no parent %ld\n", d.state);
    if (windows) {
        p = [[[NSPopover alloc] init] autorelease];
        p.contentViewController = v;
        p.animates = NO;
        [w orderFront:nil];
        PopDelegate *delegate = [[[PopDelegate alloc] init] autorelease];
        delegate.allow = YES;
        delegate.events = [NSMutableString string];
        p.delegate = delegate;
        for (NSRectEdge edge = 0; edge < 4; edge++) {
            [delegate.events setString:@""];
            NSRect rect = NSMakeRect(10, 5, 20, 10);
            [p showRelativeToRect:rect ofView:anchor preferredEdge:edge];
            NSWindow *pw = v.view.window;
            NSRect screen = [w convertRectToScreen:[anchor convertRect:rect toView:nil]], frame = pw.frame;
            printf("popover edge %lu shown %d offset %.0f %.0f size %s view %s parent %d events %s\n", edge, p.shown,
                   frame.origin.x - screen.origin.x, frame.origin.y - screen.origin.y, ssize(frame.size),
                   srect(v.view.frame), pw.parentWindow == w, delegate.events.UTF8String);
            [p close];
            printf("popover closed %d events %s\n", p.shown, delegate.events.UTF8String);
        }
        [p showRelativeToRect:NSZeroRect ofView:anchor preferredEdge:NSMinYEdge];
        p.contentSize = NSMakeSize(150, 80);
        printf("popover resize %s %s\n", ssize(p.contentSize), ssize(v.view.frame.size));
        delegate.allow = NO;
        [p performClose:nil];
        printf("popover refuse %d\n", p.shown);
        delegate.allow = YES;
        [p performClose:nil];
        printf("popover allow %d\n", p.shown);
        v.preferredContentSize = NSMakeSize(90, 40);
        [p showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSMaxXEdge];
        printf("popover preferred %s %s\n", ssize(p.contentSize), ssize(v.view.window.frame.size));
        [p close];
        v.preferredContentSize = NSZeroSize;
        d.parentWindow = w;
        [d openOnEdge:NSMinXEdge];
        pump(0.4);
        printf("drawer open %ld %lu count %lu\n", d.state, d.edge, w.drawers.count);
        [d close];
        pump(0.4);
        printf("drawer close %ld\n", d.state);
        d.parentWindow = nil;
        [w close];
    }
}
static void containerNib(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        printf("container nib missing\n");
        return;
    }
    NSNib *nib = [[[NSNib alloc] initWithNibData:data bundle:nil] autorelease];
    NSArray *top = nil;
    BOOL ok = [nib instantiateWithOwner:nil topLevelObjects:&top];
    NSGridView *g = nil;
    NSPopover *p = nil;
    NSPageController *page = nil;
    NSRuleEditor *r = nil;
    NSPredicateEditor *pred = nil;
    NSDrawer *drawer = nil;
    for (id o in top) {
        if ([o isKindOfClass:[NSGridView class]])
            g = o;
        else if ([o isKindOfClass:[NSPopover class]])
            p = o;
        else if ([o isKindOfClass:[NSPageController class]])
            page = o;
        else if ([o isKindOfClass:[NSPredicateEditor class]])
            pred = o;
        else if ([o isKindOfClass:[NSRuleEditor class]])
            r = o;
        else if ([o isKindOfClass:[NSDrawer class]])
            drawer = o;
    }
    printf("container nib %d grid %ld %ld %.0f %.0f %.0f pop %ld %d %s page %ld rule %lu %.0f pred %lu drawer %s %.0f "
           "%.0f\n",
           ok, g.numberOfRows, g.numberOfColumns, g.rowSpacing, g.columnSpacing, [g columnAtIndex:0].width, p.behavior,
           p.animates, ssize(p.contentViewController.view.frame.size), page.transitionStyle, r.nestingMode, r.rowHeight,
           pred.rowTemplates.count, ssize(drawer.contentSize), drawer.leadingOffset, drawer.trailingOffset);
}
int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSGridView class]));
        [NSApplication sharedApplication];
        BOOL windows = NO;
        NSString *dir = nil;
        for (int i = 1; i < argc; i++)
            if (!strcmp(argv[i], "--windows"))
                windows = YES;
            else
                dir = [NSString stringWithUTF8String:argv[i]];
        /* the nibs: the directory given, next to the executable (the build directory), or where the VM installs them */
        if (!dir) {
            dir = [[NSProcessInfo processInfo].arguments[0] stringByDeletingLastPathComponent];
            if (![[NSFileManager defaultManager]
                    fileExistsAtPath:[dir stringByAppendingPathComponent:@"appkit-containers2-test.nib"]])
                dir = @"/usr/local/share/finch";
        }
        grids();
        rules();
        pages();
        popovers(windows);
        FinchColorBrowserTests();
        if (dir) {
            containerNib([dir stringByAppendingPathComponent:@"appkit-containers2-test.nib"]);
            FinchColorBrowserNibTest([dir stringByAppendingPathComponent:@"appkit-color-browser-test.nib"]);
        }
        printf("containers2 done\n");
    }
    return 0;
}
