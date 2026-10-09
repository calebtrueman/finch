/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-textblock-test: NSTextBlock, NSTextTable and NSTextTableBlock: values and
 * their types, archives (Apple's keys), copying, the attributed string lookups,
 * and where a table's cells are laid out side by side (x and width; line heights
 * depend on the fonts installed). Run it against Apple's AppKit and Finch's
 * (DYLD_FRAMEWORK_PATH) and diff all but the first line.
 */
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <stdio.h>

static void
dump(NSTextBlock *b, const char *what)
{
    printf("%s: %s width %g/%ld valign %ld background %d\n", what, NSStringFromClass([b class]).UTF8String, b.contentWidth,
           (long)b.contentWidthValueType, (long)b.verticalAlignment, b.backgroundColor != nil);
    static const NSTextBlockDimension dims[] = {NSTextBlockWidth, NSTextBlockMinimumWidth, NSTextBlockMaximumWidth,
                                                NSTextBlockHeight, NSTextBlockMinimumHeight, NSTextBlockMaximumHeight};
    for (int d = 0; d < 6; d++)
        printf("  dimension %ld: %g/%ld\n", (long)dims[d], [b valueForDimension:dims[d]], (long)[b valueTypeForDimension:dims[d]]);
    for (int l = -1; l <= 1; l++)
        for (int e = 0; e < 4; e++)
            printf("  layer %d edge %d: %g/%ld border colour %d\n", l, e, [b widthForLayer:l edge:e],
                   (long)[b widthValueTypeForLayer:l edge:e], [b borderColorForEdge:e] != nil);
}

static void
archive_keys(id o, const char *what)
{
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:o requiringSecureCoding:NO error:nil];
    NSDictionary *pl = [NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil];
    for (id x in pl[@"$objects"]) {
        if (![x isKindOfClass:[NSDictionary class]] || x[@"$classes"] || !(x[@"NSValueTypes"] || x[@"NSNumCols"] || x[@"NSRowNum"]))
            continue;
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in [[x allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            id v = x[k];
            [parts addObject:[NSString stringWithFormat:@"%@=%@", k, [v isKindOfClass:[NSNumber class]] ? v : @"(object)"]];
        }
        printf("%s archive: %s\n", what, [parts componentsJoinedByString:@" "].UTF8String);
    }
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        Dl_info dl;
        dladdr((__bridge void *)[NSTextBlock class], &dl);
        printf("%s\n", dl.dli_fname);
        [NSApplication sharedApplication];
        NSTextBlock *b = [NSTextBlock new];
        dump(b, "new");
        [b setWidth:3 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
        [b setWidth:10 type:NSTextBlockPercentageValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
        [b setValue:5 type:NSTextBlockAbsoluteValueType forDimension:NSTextBlockMaximumHeight];
        [b setBorderColor:NSColor.redColor forEdge:NSMaxYEdge];
        b.backgroundColor = NSColor.blueColor;
        b.verticalAlignment = NSTextBlockBottomAlignment;
        [b setContentWidth:50 type:NSTextBlockPercentageValueType];
        dump(b, "set");
        archive_keys(b, "block");
        NSTextBlock *c = [b copy];
        printf("copy: equal %d same values %d\n", [c isEqual:b], [c widthForLayer:NSTextBlockPadding edge:NSMaxXEdge] == 3);
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:b requiringSecureCoding:YES error:nil];
        NSTextBlock *u = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSTextBlock class] fromData:data error:nil];
        printf("unarchived: width %g/%ld valign %ld margin %g/%ld background %d border %d\n", u.contentWidth,
               (long)u.contentWidthValueType, (long)u.verticalAlignment,
               [u widthForLayer:NSTextBlockMargin edge:NSMinXEdge], (long)[u widthValueTypeForLayer:NSTextBlockMargin edge:NSMinXEdge],
               u.backgroundColor != nil, [u borderColorForEdge:NSMaxYEdge] != nil);

        NSTextTable *t = [NSTextTable new];
        printf("table: columns %lu algorithm %ld collapses %d hides %d\n", (unsigned long)t.numberOfColumns,
               (long)t.layoutAlgorithm, t.collapsesBorders, t.hidesEmptyCells);
        t.numberOfColumns = 2;
        t.collapsesBorders = YES;
        t.layoutAlgorithm = NSTextTableFixedLayoutAlgorithm;
        NSTextTableBlock *tb = [[NSTextTableBlock alloc] initWithTable:t startingRow:1 rowSpan:2 startingColumn:1 columnSpan:1];
        printf("cell: row %ld/%ld column %ld/%ld table %d\n", (long)tb.startingRow, (long)tb.rowSpan, (long)tb.startingColumn,
               (long)tb.columnSpan, tb.table == t);
        archive_keys(t, "table");
        archive_keys(tb, "cell");

        NSTextTableBlock *c00 = [[NSTextTableBlock alloc] initWithTable:t startingRow:0 rowSpan:1 startingColumn:0 columnSpan:1];
        NSTextTableBlock *c01 = [[NSTextTableBlock alloc] initWithTable:t startingRow:0 rowSpan:1 startingColumn:1 columnSpan:1];
        [c00 setWidth:2 type:0 forLayer:NSTextBlockPadding];
        [c01 setWidth:2 type:0 forLayer:NSTextBlockPadding];
        [t setWidth:1 type:0 forLayer:NSTextBlockBorder];
        NSMutableParagraphStyle *p0 = [NSMutableParagraphStyle new], *p1 = [NSMutableParagraphStyle new];
        p0.textBlocks = @[ c00 ];
        p1.textBlocks = @[ c01 ];
        NSFont *font = [NSFont systemFontOfSize:12];
        NSMutableAttributedString *s = [NSMutableAttributedString new];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"A\n" attributes:@{NSParagraphStyleAttributeName : p0, NSFontAttributeName : font}]];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"BB\n" attributes:@{NSParagraphStyleAttributeName : p1, NSFontAttributeName : font}]];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"after\n" attributes:@{NSFontAttributeName : font}]];
        printf("rangeOfTextBlock %s rangeOfTextTable %s none %s\n", NSStringFromRange([s rangeOfTextBlock:c01 atIndex:3]).UTF8String,
               NSStringFromRange([s rangeOfTextTable:t atIndex:0]).UTF8String,
               [s rangeOfTextTable:t atIndex:6].location == NSNotFound ? "not found" : "found");
        NSTextStorage *st = [[NSTextStorage alloc] initWithAttributedString:s];
        NSLayoutManager *lm = [NSLayoutManager new];
        NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(500, 1e7)];
        [st addLayoutManager:lm];
        [lm addTextContainer:tc];
        [lm ensureLayoutForTextContainer:tc];
        for (NSUInteger i = 0; i < s.length;) {
            NSRange g;
            NSRect f = [lm lineFragmentRectForGlyphAtIndex:i effectiveRange:&g];
            NSRect used = [lm lineFragmentUsedRectForGlyphAtIndex:i effectiveRange:NULL];
            /* whole points: Apple's places lines on half points on a 1x display */
            printf("fragment %s x %g width %g used x %g%s\n", NSStringFromRange(g).UTF8String, floor(f.origin.x), f.size.width,
                   floor(used.origin.x), f.size.width < 500 ? " (in a cell)" : "");
            i = NSMaxRange(g);
        }
        NSRect l0 = [lm layoutRectForTextBlock:c00 glyphRange:NSMakeRange(0, 2)], b0 = [lm boundsRectForTextBlock:c00 glyphRange:NSMakeRange(0, 2)];
        NSRect l1 = [lm layoutRectForTextBlock:c01 glyphRange:NSMakeRange(2, 3)], b1 = [lm boundsRectForTextBlock:c01 glyphRange:NSMakeRange(2, 3)];
        printf("cell 0: layout x %g y %g width %g; bounds x %g y %g width %g\n", floor(l0.origin.x), floor(l0.origin.y),
               l0.size.width, floor(b0.origin.x), floor(b0.origin.y), b0.size.width);
        printf("cell 1: layout x %g y %g width %g; bounds x %g y %g width %g\n", floor(l1.origin.x), floor(l1.origin.y),
               l1.size.width, floor(b1.origin.x), floor(b1.origin.y), b1.size.width);
    }
    return 0;
}
