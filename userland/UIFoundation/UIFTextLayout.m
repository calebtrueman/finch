/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Text layout, shared by string drawing and NSLayoutManager: attributed
 * strings laid out as Apple's text system lays them out in a text container,
 * and drawn with CoreText into the current NSGraphicsContext's CGContext
 * (found at run time: UIFoundation doesn't link AppKit).
 *
 * Layout, as TextKit's:
 * - Paragraphs are broken into lines by CoreText's typesetter (word or
 *   character wrapping), or kept to one truncated or clipped line by the
 *   truncating and clipping line-break modes.
 * - A line is as tall as its tallest font's rounded ascent plus rounded
 *   descent (plus the font's leading with NSStringDrawingUsesFontLeading),
 *   scaled by lineHeightMultiple and held within the minimum and maximum
 *   line heights; lineSpacing follows every line but the last,
 *   paragraphSpacing every paragraph but the last.
 * - A line's used width includes its trailing whitespace, unless that hangs
 *   past the container's edge.
 * - A trailing newline adds an empty last line in the last character's font
 *   (NSLayoutManager's extra line fragment).
 * - Without NSStringDrawingUsesLineFragmentOrigin, only the first line is
 *   laid out, unwrapped, and the rectangle's origin is its baseline.
 * - Paragraphs in text blocks are laid out inside them: each block insets
 *   its content by its margin, border and padding (and may set its width).
 *   A table's cells (NSTextTableBlock) share its columns equally and stand
 *   side by side; a row is as tall as its tallest cell.
 */
#import "UIFTextLayout.h"
#import "UIFTextBlock.h"

static void
layout_add(UIFLayout *l, UIFLine line)
{
    if (l->count == l->capacity) {
        l->capacity = l->capacity ? l->capacity * 2 : 8;
        l->lines = realloc(l->lines, l->capacity * sizeof *l->lines);
    }
    l->lines[l->count++] = line;
}

void
UIFLayoutFree(UIFLayout *l)
{
    for (size_t i = 0; i < l->count; i++)
        if (l->lines[i].line)
            CFRelease(l->lines[i].line);
    free(l->lines);
    for (size_t i = 0; i < l->blockCount; i++)
        [l->blocks[i].block release];
    free(l->blocks);
}

static void
block_add(UIFLayout *l, NSTextBlock *b, NSRange range, CGRect frame, CGRect content)
{
    if (l->blockCount == l->blockCapacity) {
        l->blockCapacity = l->blockCapacity ? l->blockCapacity * 2 : 4;
        l->blocks = realloc(l->blocks, l->blockCapacity * sizeof *l->blocks);
    }
    l->blocks[l->blockCount++] = (UIFBlockFrame){[b retain], range, frame, content};
}

#pragma mark - Text blocks

/* An open block: where its frame starts and its content lies. */
typedef struct {
    NSTextBlock *block;
    NSUInteger start;
    CGFloat top, left, width;     /* its frame (margins included) */
    CGFloat contentLeft, contentWidth;
    CGFloat of;                   /* what its percentages are of */
} OpenBlock;

typedef struct {
    OpenBlock open[16];
    size_t depth;
    /* the table whose cells are open, and its current row */
    NSTextTable *table;
    size_t tableDepth;            /* the cell's place in `open` */
    NSUInteger tableStart;
    CGFloat tableTop, tableLeft, tableWidth, tableOf, tableContentLeft, tableContentWidth;
    NSInteger row;
    CGFloat rowTop, rowBottom;
    struct {
        NSTextTableBlock *cell;
        NSRange range;
        CGFloat left, width, contentLeft, contentWidth, top;
    } cells[64];
    size_t cellCount;
} BlockState;

static CGFloat
area_left(BlockState *bs) { return bs->depth ? bs->open[bs->depth - 1].contentLeft : 0; }

static CGFloat
area_width(BlockState *bs, CGFloat container)
{
    return bs->depth ? bs->open[bs->depth - 1].contentWidth : container;
}

/* The row's cells are as tall as the row. */
static void
end_row(UIFLayout *L, BlockState *bs)
{
    for (size_t i = 0; i < bs->cellCount; i++) {
        __typeof__(bs->cells[0]) *c = &bs->cells[i];
        CGFloat bottom = bs->rowBottom;
        CGRect frame = CGRectMake(c->left, c->top, c->width, bottom - c->top);
        CGFloat of = bs->tableContentWidth;
        CGRect content = CGRectMake(c->contentLeft, c->top + UIFTextBlockInset(c->cell, NSMinYEdge, of),
                                    c->contentWidth, 0);
        content.size.height = MAX(0, bottom - UIFTextBlockInset(c->cell, NSMaxYEdge, of) - content.origin.y);
        block_add(L, c->cell, c->range, frame, content);
    }
    bs->cellCount = 0;
}

static void
end_table(UIFLayout *L, BlockState *bs, NSUInteger at, CGFloat *y)
{
    end_row(L, bs);
    CGFloat bottom = bs->rowBottom + UIFTextBlockInset(bs->table, NSMaxYEdge, bs->tableOf);
    block_add(L, bs->table, NSMakeRange(bs->tableStart, at - bs->tableStart),
              CGRectMake(bs->tableLeft, bs->tableTop, bs->tableWidth, bottom - bs->tableTop),
              CGRectMake(bs->tableContentLeft, bs->tableTop + UIFTextBlockInset(bs->table, NSMinYEdge, bs->tableOf),
                         bs->tableContentWidth, 0));
    *y = bottom;
    bs->table = nil;
}

/* Close the open blocks from `keep` on (innermost first), at character `at`. */
static void
close_blocks(UIFLayout *L, BlockState *bs, size_t keep, NSUInteger at, CGFloat *y, NSArray *next)
{
    while (bs->depth > keep) {
        OpenBlock *o = &bs->open[--bs->depth];
        if ([o->block isKindOfClass:[NSTextTableBlock class]] && bs->table) {
            NSTextTableBlock *cell = (NSTextTableBlock *)o->block;
            CGFloat bottom = *y + UIFTextBlockInset(cell, NSMaxYEdge, o->of);
            CGFloat h = UIFTextBlockDimension(cell, NSTextBlockMinimumHeight, o->of);
            bottom = MAX(bottom, o->top + h);
            bs->rowBottom = MAX(bs->rowBottom, bottom);
            if (bs->cellCount < 64) {
                __typeof__(bs->cells[0]) *c = &bs->cells[bs->cellCount++];
                c->cell = cell;
                c->range = NSMakeRange(o->start, at - o->start);
                c->left = o->left;
                c->width = o->width;
                c->contentLeft = o->contentLeft;
                c->contentWidth = o->contentWidth;
                c->top = o->top;
            }
            /* another cell of the same table next: stay in the table */
            id following = bs->depth < next.count ? next[bs->depth] : nil;
            if (!([following isKindOfClass:[NSTextTableBlock class]] &&
                  ((NSTextTableBlock *)following).table == bs->table))
                end_table(L, bs, at, y);
            else
                *y = bs->rowTop;
            continue;
        }
        *y += UIFTextBlockInset(o->block, NSMaxYEdge, o->of);
        CGFloat h = MAX(UIFTextBlockDimension(o->block, NSTextBlockHeight, o->of),
                        UIFTextBlockDimension(o->block, NSTextBlockMinimumHeight, o->of));
        *y = MAX(*y, o->top + h);
        block_add(L, o->block, NSMakeRange(o->start, at - o->start), CGRectMake(o->left, o->top, o->width, *y - o->top),
                  CGRectMake(o->contentLeft, o->top + UIFTextBlockInset(o->block, NSMinYEdge, o->of), o->contentWidth,
                             0));
    }
}

/* Open a block for the paragraph at `at`. */
static void
open_block(UIFLayout *L, BlockState *bs, NSTextBlock *b, NSUInteger at, CGFloat *y, CGFloat container)
{
    if (bs->depth >= 16)
        return;
    CGFloat left = area_left(bs), width = area_width(bs, container);
    OpenBlock *o = &bs->open[bs->depth];
    o->block = b;
    o->start = at;
    if ([b isKindOfClass:[NSTextTableBlock class]]) {
        NSTextTableBlock *cell = (NSTextTableBlock *)b;
        NSTextTable *t = cell.table;
        if (t != bs->table) {
            if (bs->table)
                end_table(L, bs, at, y);
            bs->table = t;
            bs->tableDepth = bs->depth;
            bs->tableStart = at;
            bs->tableOf = width;
            bs->tableTop = *y;
            bs->tableLeft = left;
            bs->tableWidth = width;
            CGFloat tl = UIFTextBlockInset(t, NSMinXEdge, width), tr = UIFTextBlockInset(t, NSMaxXEdge, width);
            CGFloat tw = UIFTextBlockDimension(t, NSTextBlockWidth, width);
            bs->tableContentLeft = left + tl;
            bs->tableContentWidth = tw > 0 ? tw : MAX(0, width - tl - tr);
            bs->tableWidth = bs->tableContentWidth + tl + tr;
            bs->rowTop = bs->rowBottom = *y + UIFTextBlockInset(t, NSMinYEdge, width);
            bs->row = cell.startingRow;
        } else if (cell.startingRow != bs->row) {
            end_row(L, bs);
            bs->rowTop = bs->rowBottom;
            bs->row = cell.startingRow;
        }
        NSUInteger cols = MAX(t.numberOfColumns, (NSUInteger)1);
        CGFloat colWidth = bs->tableContentWidth / cols;
        NSInteger c = MIN(MAX(cell.startingColumn, 0), (NSInteger)cols - 1);
        NSInteger span = MAX(1, MIN(cell.columnSpan, (NSInteger)cols - c));
        CGFloat of = bs->tableContentWidth;
        o->of = of;
        o->top = bs->rowTop;
        o->left = bs->tableContentLeft + c * colWidth;
        o->width = span * colWidth;
        o->contentLeft = o->left + UIFTextBlockInset(cell, NSMinXEdge, of);
        o->contentWidth = MAX(0, o->width - UIFTextBlockInset(cell, NSMinXEdge, of) - UIFTextBlockInset(cell, NSMaxXEdge, of));
        *y = o->top + UIFTextBlockInset(cell, NSMinYEdge, of);
    } else {
        o->of = width;
        o->top = *y;
        o->left = left;
        CGFloat l = UIFTextBlockInset(b, NSMinXEdge, width), r = UIFTextBlockInset(b, NSMaxXEdge, width);
        CGFloat w = UIFTextBlockDimension(b, NSTextBlockWidth, width);
        CGFloat minW = UIFTextBlockDimension(b, NSTextBlockMinimumWidth, width),
                maxW = UIFTextBlockDimension(b, NSTextBlockMaximumWidth, width);
        if (w <= 0)
            w = MAX(0, width - l - r);
        if (minW > 0)
            w = MAX(w, minW);
        if (maxW > 0)
            w = MIN(w, maxW);
        o->contentLeft = left + l;
        o->contentWidth = w;
        o->width = w + l + r;
        *y += UIFTextBlockInset(b, NSMinYEdge, width);
    }
    bs->depth++;
}

/* The paragraph at `at` has these blocks: close the ones it leaves, open the ones it enters. */
static void
enter_blocks(UIFLayout *L, BlockState *bs, NSArray *blocks, NSUInteger at, CGFloat *y, CGFloat container)
{
    size_t keep = 0;
    while (keep < bs->depth && keep < blocks.count && bs->open[keep].block == blocks[keep])
        keep++;
    close_blocks(L, bs, keep, at, y, blocks);
    for (size_t i = keep; i < blocks.count; i++)
        open_block(L, bs, blocks[i], at, y, container);
}


#pragma mark - Attributes

NSFont *
UIFFontIn(NSDictionary *attrs)
{
    id f = attrs[NSFontAttributeName];
    return [f isKindOfClass:[NSFont class]] ? f : UIFDefaultFont();
}

NSParagraphStyle *
UIFStyleIn(NSDictionary *attrs)
{
    id p = attrs[NSParagraphStyleAttributeName];
    return [p isKindOfClass:[NSParagraphStyle class]] ? p : [NSParagraphStyle defaultParagraphStyle];
}

static CGColorRef
black(void)
{
    static CGColorRef c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        c = CGColorCreate(gray, (const CGFloat[]){0, 1});
        CGColorSpaceRelease(gray);
    });
    return c;
}

/* The attributes drawn here rather than by CoreText (underlines,
 * strikethroughs, backgrounds, shadows, baseline offsets) ride along under a
 * key of their own, so CoreText splits runs where they change but ignores them. */
static NSString *const kDrawnHere = @"UIFoundationDrawnAttributes";

static NSDictionary *
drawn_here(NSDictionary *attrs)
{
    static NSString *const *keys[] = {
        &NSUnderlineStyleAttributeName, &NSUnderlineColorAttributeName, &NSStrikethroughStyleAttributeName,
        &NSStrikethroughColorAttributeName, &NSBackgroundColorAttributeName, &NSShadowAttributeName,
        &NSBaselineOffsetAttributeName, &NSForegroundColorAttributeName,
    };
    NSMutableDictionary *d = nil;
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        id v = attrs[*keys[i]];
        if (!v)
            continue;
        if (!d)
            d = [NSMutableDictionary dictionary];
        d[*keys[i]] = v;
    }
    return d;
}

/* For the layout being made: what text without a colour draws in (NULL: black). */
static __thread CGColorRef default_foreground;

/* The attributes CoreText lays out and draws with: fonts (Helvetica 12 where
 * there is none), kerning, ligatures, colours as CGColors. Paragraph styles
 * are applied here, so they are left out. */
static NSDictionary *
ct_attributes(NSDictionary *attrs)
{
    NSMutableDictionary *a = [NSMutableDictionary dictionaryWithCapacity:6];
    NSDictionary *here = drawn_here(attrs);
    if (here)
        a[kDrawnHere] = here;
    a[(id)kCTFontAttributeName] = UIFFontIn(attrs);
    id kern = attrs[NSKernAttributeName];
    if ([kern isKindOfClass:[NSNumber class]])
        a[(id)kCTKernAttributeName] = kern;
    id lig = attrs[NSLigatureAttributeName];
    if ([lig isKindOfClass:[NSNumber class]])
        a[(id)kCTLigatureAttributeName] = lig;
    CGColorRef fg = UIFCGColor(attrs[NSForegroundColorAttributeName]);
    a[(id)kCTForegroundColorAttributeName] = (id)(fg ? fg : default_foreground ? default_foreground : black());
    id stroke = attrs[NSStrokeWidthAttributeName];
    if ([stroke isKindOfClass:[NSNumber class]] && [stroke doubleValue] != 0) {
        a[(id)kCTStrokeWidthAttributeName] = stroke;
        CGColorRef sc = UIFCGColor(attrs[NSStrokeColorAttributeName]);
        if (sc)
            a[(id)kCTStrokeColorAttributeName] = (id)sc;
    }
    return a;
}

/* The string with CoreText's attributes. */
static NSAttributedString *
ct_string(NSAttributedString *s)
{
    NSMutableAttributedString *out = [[[NSMutableAttributedString alloc] initWithString:s.string] autorelease];
    [s enumerateAttributesInRange:NSMakeRange(0, s.length)
                          options:0
                       usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
                         [out setAttributes:ct_attributes(attrs) range:range];
                       }];
    return out;
}

#pragma mark - Layout

static BOOL
is_paragraph_break(unichar c)
{
    return c == '\n' || c == '\r' || c == 0x2029 || c == 0x85;
}

/* The rounded height and baseline of a line's fonts. */
static void
line_metrics(CTLineRef line, NSAttributedString *source, NSDictionary *typing, CFRange range, BOOL fontLeading, BOOL roundLeading,
             CGFloat *height, CGFloat *ascent, CGFloat *descent)
{
    CGFloat asc = 0, desc = 0, lead = 0;
    CFArrayRef runs = line ? CTLineGetGlyphRuns(line) : NULL;
    CFIndex n = runs ? CFArrayGetCount(runs) : 0;
    for (CFIndex i = 0; i < n; i++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, i);
        CTFontRef f = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        if (!f)
            continue;
        asc = MAX(asc, round(CTFontGetAscent(f)));
        desc = MAX(desc, round(CTFontGetDescent(f)));
        lead = MAX(lead, CTFontGetLeading(f));
    }
    if (!n) {
        /* An empty line: the font at its start. */
        NSUInteger at = range.location < (CFIndex)source.length ? (NSUInteger)range.location
                        : source.length                         ? source.length - 1
                                                                : 0;
        NSFont *f = UIFFontIn(source.length ? [source attributesAtIndex:at effectiveRange:NULL] : typing);
        asc = round(f.ascender);
        desc = round(-f.descender);
        lead = f.leading;
    }
    *ascent = asc;
    *descent = desc;
    *height = asc + desc + (fontLeading ? (roundLeading ? round(lead) : lead) : 0);
}

static CTLineRef
truncated(CTLineRef line, NSAttributedString *ct, CFRange range, CGFloat width, CTLineTruncationType type)
{
    NSUInteger last = range.location + range.length > 0 ? (NSUInteger)(range.location + range.length - 1) : 0;
    NSDictionary *a = ct.length ? [ct attributesAtIndex:MIN(last, ct.length - 1) effectiveRange:NULL] : @{};
    NSAttributedString *e = [[[NSAttributedString alloc] initWithString:@"…" attributes:a] autorelease];
    CTLineRef token = CTLineCreateWithAttributedString((CFAttributedStringRef)e);
    CTLineRef t = CTLineCreateTruncatedLine(line, width, type, token);
    CFRelease(token);
    return t ? t : (CTLineRef)CFRetain(line);
}

/* A line's used width: with its trailing whitespace, as TextKit's, unless
 * that whitespace hangs past the available width. */
static CGFloat
line_width(CTLineRef line, CGFloat avail)
{
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    if (w > avail) {
        double ink = w - CTLineGetTrailingWhitespaceWidth(line);
        w = MAX(ink, (double)avail);
    }
    return (CGFloat)MAX(w, 0);
}

/* Lay `s` (NS attributes) out. `typing` gives the font for an empty string. */
UIFLayout
UIFLayoutString(NSAttributedString *s, NSDictionary *typing, UIFLayoutParams p)
{
    UIFLayout L = {0};
    /* as Apple's text views: uncoloured text is textColor, in the appearance being drawn */
    default_foreground = p.inTextView ? UIFCGColor([UIFClass("NSColor") performSelector:@selector(textColor)]) : NULL;
    NSAttributedString *ct = ct_string(s);
    default_foreground = NULL;
    NSString *str = s.string;
    NSUInteger len = str.length;
    BOOL multi = (p.options & NSStringDrawingUsesLineFragmentOrigin) != 0;
    BOOL fontLeading = (p.options & NSStringDrawingUsesFontLeading) != 0;
    CGFloat containerWidth = multi && p.width > 0 ? p.width : CGFLOAT_MAX;
    CGFloat y = 0;
    /* Starting inside a paragraph (a container after the one it began in):
     * from its start, skipping what's laid out. */
    NSUInteger start = MIN(p.start, len), skip = 0;
    while (start > 0 && !is_paragraph_break([str characterAtIndex:start - 1])) {
        start--;
        skip++;
    }
    L.end = MIN(p.start, len);
    BOOL stop = NO;
    BOOL firstParagraph = YES;
    BlockState bs = {0};
    BOOL blocksOn = multi && containerWidth != CGFLOAT_MAX;
    CGFloat fullWidth = containerWidth;
    while (!stop) {
        /* One paragraph: [start, end), then its break. */
        NSUInteger end = start;
        while (end < len && !is_paragraph_break([str characterAtIndex:end]))
            end++;
        NSUInteger next = end;
        if (end < len) {
            next = end + 1;
            if ([str characterAtIndex:end] == '\r' && next < len && [str characterAtIndex:next] == '\n')
                next++;
        }
        NSDictionary *pa = len ? [s attributesAtIndex:MIN(start, len - 1) effectiveRange:NULL] : typing;
        NSParagraphStyle *ps = UIFStyleIn(len ? pa : typing);
        NSLineBreakMode mode = ps.lineBreakMode;
        BOOL wraps = multi && (mode == NSLineBreakByWordWrapping || mode == NSLineBreakByCharWrapping);
        CTLineTruncationType trunc = mode == NSLineBreakByTruncatingHead     ? kCTLineTruncationStart
                                     : mode == NSLineBreakByTruncatingMiddle ? kCTLineTruncationMiddle
                                                                             : kCTLineTruncationEnd;
        BOOL truncates = mode == NSLineBreakByTruncatingHead || mode == NSLineBreakByTruncatingTail ||
                         mode == NSLineBreakByTruncatingMiddle;
        /* its text blocks: where its content goes */
        CGFloat blockLeft = 0, blockWidth = 0;
        if (blocksOn) {
            if (skip == 0)
                enter_blocks(&L, &bs, ps.textBlocks, start, &y, fullWidth);
            if (bs.depth) {
                blockLeft = area_left(&bs);
                blockWidth = area_width(&bs, fullWidth);
            }
            containerWidth = bs.depth ? blockWidth : fullWidth;
        }
        if (!firstParagraph && multi)
            y += ps.paragraphSpacingBefore;
        firstParagraph = NO;

        NSAttributedString *para = [ct attributedSubstringFromRange:NSMakeRange(start, end - start)];
        CTTypesetterRef ts = para.length ? CTTypesetterCreateWithAttributedString((CFAttributedStringRef)para) : NULL;
        CFIndex pos = (CFIndex)skip, plen = (CFIndex)para.length;
        BOOL firstLine = skip == 0;
        skip = 0;
        do {
            CGFloat indent = firstLine ? ps.firstLineHeadIndent : ps.headIndent;
            CGFloat tail = ps.tailIndent;
            CGFloat right = containerWidth == CGFLOAT_MAX ? CGFLOAT_MAX
                            : tail > 0                   ? tail
                                                         : containerWidth + tail;
            CGFloat avail = right == CGFLOAT_MAX ? CGFLOAT_MAX : MAX(right - indent, 0);
            CFIndex count = plen - pos;
            if (ts && wraps && avail != CGFLOAT_MAX) {
                count = mode == NSLineBreakByCharWrapping ? CTTypesetterSuggestClusterBreak(ts, pos, avail)
                                                          : CTTypesetterSuggestLineBreak(ts, pos, avail);
                if (count <= 0)
                    count = 1;
            }
            CTLineRef line = ts ? CTTypesetterCreateLine(ts, CFRangeMake(pos, count)) : NULL;
            BOOL lastInParagraph = pos + count >= plen;
            CGFloat h, asc, desc;
            line_metrics(line, s, typing, CFRangeMake((CFIndex)start + pos, count), fontLeading, p.roundLeading, &h, &asc, &desc);
            if (ps.lineHeightMultiple > 0)
                h *= ps.lineHeightMultiple;
            if (h < ps.minimumLineHeight)
                h = ps.minimumLineHeight;
            if (ps.maximumLineHeight > 0 && h > ps.maximumLineHeight)
                h = ps.maximumLineHeight;
            BOOL lastText = lastInParagraph && next >= len && !(next > end && end < len);
            /* Would the line fit the height? */
            if ((multi && p.height > 0 && (L.count > 0 || p.mayBeEmpty) && y + h > p.height + 0.001) ||
                (p.maximumLines && L.count >= p.maximumLines)) {
                if (line)
                    CFRelease(line);
                stop = YES;
                L.truncated = YES;
                break;
            }
            /* The last line that fits, with more text after it, is truncated if asked. */
            BOOL nextFits = YES;
            if (multi && p.height > 0) {
                CGFloat after = y + h + ps.lineSpacing;
                nextFits = after + h <= p.height + 0.001;
            }
            BOOL moreText = !lastInParagraph || next < len;
            if (line && (p.options & NSStringDrawingTruncatesLastVisibleLine) && multi && !nextFits && moreText &&
                avail != CGFLOAT_MAX) {
                CTLineRef whole = CTTypesetterCreateLine(ts, CFRangeMake(pos, plen - pos));
                CTLineRef t = truncated(whole, ct, CFRangeMake((CFIndex)start + pos, plen - pos), avail, kCTLineTruncationEnd);
                CFRelease(whole);
                CFRelease(line);
                line = t;
                stop = YES;
            } else if (line && truncates && avail != CGFLOAT_MAX && multi) {
                CTLineRef t = truncated(line, ct, CFRangeMake((CFIndex)start + pos, count), avail, trunc);
                CFRelease(line);
                line = t;
            }
            CGFloat w = line ? line_width(line, avail) : 0;
            CGFloat x = indent;
            NSTextAlignment align = ps.alignment;
            if (align == NSTextAlignmentNatural || align == NSTextAlignmentJustified)
                align = ps.baseWritingDirection == NSWritingDirectionRightToLeft ? NSTextAlignmentRight : NSTextAlignmentLeft;
            /* Centred and right-aligned lines are placed by their text without
             * trailing whitespace, which may then hang up to the right edge. */
            CGFloat placed = w;
            if (line && align != NSTextAlignmentLeft)
                placed = MAX(0, w - (CGFloat)CTLineGetTrailingWhitespaceWidth(line));
            CGFloat room = (right == CGFLOAT_MAX ? placed + indent : right) - indent - placed;
            if (room > 0 && containerWidth != CGFLOAT_MAX) {
                if (align == NSTextAlignmentCenter)
                    x += room / 2;
                else if (align == NSTextAlignmentRight)
                    x += room;
                if (right != CGFLOAT_MAX && x + w > right)
                    w = MAX(right - x, placed);
            }
            /* Its characters: the paragraph break goes with the paragraph's last line. */
            NSUInteger lineEnd = lastInParagraph ? next : start + (NSUInteger)(pos + count);
            if (stop)
                lineEnd = next; /* a truncated last line stands for the rest of its paragraph */
            UIFLine ln = {line, NSMakeRange(start + (NSUInteger)pos, lineEnd - (start + (NSUInteger)pos)), blockLeft + x, y, h, h - desc, w, 0, NO,
                          blockLeft, blockWidth};
            layout_add(&L, ln);
            L.end = lineEnd;
            y += h;
            if (!multi) {
                stop = YES;
                break;
            }
            if (!lastText) {
                L.lines[L.count - 1].spacingAfter = ps.lineSpacing;
                y += ps.lineSpacing;
            }
            pos += count;
            firstLine = NO;
            (void)lastText;
        } while (pos < plen && !stop);
        if (ts)
            CFRelease(ts);
        if (stop)
            break;
        if (next > end && end < len) {
            /* A paragraph break: paragraph spacing, then the next paragraph
             * (an empty last line when the break ends the string). */
            y += ps.paragraphSpacing;
            start = next;
            if (start >= len) {
                if (blocksOn && bs.depth) {
                    close_blocks(&L, &bs, 0, len, &y, @[]);
                    containerWidth = fullWidth;
                }
                if (L.count && L.lines[L.count - 1].spacingAfter == 0) {
                    L.lines[L.count - 1].spacingAfter = ps.lineSpacing;
                    y += ps.lineSpacing;
                }
                CGFloat h, asc, desc;
                line_metrics(NULL, s, typing, CFRangeMake((CFIndex)len, 0), fontLeading, p.roundLeading, &h, &asc, &desc);
                if (p.height > 0 && y + h > p.height + 0.001)
                    break;
                UIFLine ln = {NULL, NSMakeRange(len, 0), ps.firstLineHeadIndent, y, h, h - desc, 0, 0, YES, 0, 0};
                layout_add(&L, ln);
                y += h;
                break;
            }
        } else {
            break;
        }
    }
    if (blocksOn && bs.depth)
        close_blocks(&L, &bs, 0, L.end, &y, @[]);
    /* Trailing spacing isn't part of the height (a block's bottom is). */
    if (L.count) {
        UIFLine *last = &L.lines[L.count - 1];
        L.height = last->top + last->height;
        for (size_t i = 0; i < L.blockCount; i++)
            L.height = MAX(L.height, CGRectGetMaxY(L.blocks[i].frame));
    }
    return L;
}

/* The rectangle a layout uses: from the top-left of its first line
 * fragment, or (without NSStringDrawingUsesLineFragmentOrigin) from the
 * first baseline. */
CGRect
UIFLayoutUsedRect(UIFLayout *L, UIFLayoutParams p)
{
    CGFloat minX = CGFLOAT_MAX, maxX = 0;
    for (size_t i = 0; i < L->count; i++) {
        UIFLine *ln = &L->lines[i];
        if (ln->width <= 0 && L->count > 1)
            continue;
        minX = MIN(minX, ln->x);
        maxX = MAX(maxX, ln->x + ln->width);
    }
    if (minX == CGFLOAT_MAX)
        minX = 0;
    BOOL multi = (p.options & NSStringDrawingUsesLineFragmentOrigin) != 0;
    if (!multi) {
        UIFLine *ln = L->count ? &L->lines[0] : NULL;
        CGFloat w = ln ? ln->width : 0;
        if (p.width > 0 && w > p.width)
            w = p.width;
        CGFloat h = ln ? ln->height : 0, desc = ln ? ln->height - ln->baseline : 0;
        return CGRectMake(0, -desc, w, h);
    }
    for (size_t i = 0; i < L->blockCount; i++)
        maxX = MAX(maxX, CGRectGetMaxX(L->blocks[i].frame));
    if (minX > 0 && maxX <= minX)
        maxX = minX;
    return CGRectMake(0, 0, maxX, L->height);
}

void
UIFLayoutDrawBlocks(UIFLayout *L, NSRange chars, CGFloat left, CGFloat top, id lm)
{
    id view = [lm respondsToSelector:@selector(firstTextView)] ? [lm firstTextView] : nil;
    for (size_t i = 0; i < L->blockCount; i++) {
        UIFBlockFrame *b = &L->blocks[i];
        if (chars.length && !NSIntersectionRange(b->range, chars).length && b->range.length)
            continue;
        NSRect frame = NSOffsetRect(NSRectFromCGRect(b->frame), left, top);
        if ([b->block isKindOfClass:[NSTextTableBlock class]]) {
            NSTextTableBlock *cell = (NSTextTableBlock *)b->block;
            [cell.table drawBackgroundForBlock:cell withFrame:frame inView:(id _Nonnull)view characterRange:b->range layoutManager:lm];
        } else {
            [b->block drawBackgroundWithFrame:frame inView:(id _Nonnull)view characterRange:b->range layoutManager:lm];
        }
    }
}

#pragma mark - Drawing

static void
fill_rect(CGContextRef cg, CGRect r, CGColorRef color)
{
    CGContextSaveGState(cg);
    CGContextSetFillColorWithColor(cg, color ? color : black());
    CGContextFillRect(cg, r);
    CGContextRestoreGState(cg);
}

/* Device pixels per point vertically and horizontally, for snapping lines to pixels. */
static CGSize
device_scale(CGContextRef cg)
{
    CGAffineTransform t = CGContextGetUserSpaceToDeviceSpaceTransform(cg);
    CGFloat sx = sqrt(t.a * t.a + t.b * t.b), sy = sqrt(t.c * t.c + t.d * t.d);
    return CGSizeMake(sx > 0 ? sx : 1, sy > 0 ? sy : 1);
}

/* An underline or strikethrough, as TextKit draws them: the font's
 * thickness rounded up to whole device pixels (twice that for thick),
 * edges on pixel boundaries. Underlines sit one thickness below the
 * baseline; strikethroughs are centred at half the x-height. */
static void
decoration(CGContextRef cg, NSInteger style, CGFloat x0, CGFloat x1, CGFloat baseline, NSFont *font, BOOL strike,
           BOOL flipped, CGColorRef color)
{
    if (!(style & 0xff) || x1 <= x0)
        return;
    CGSize scale = device_scale(cg);
    CGFloat t = ceil(font.underlineThickness * ((style & 0xff) == NSUnderlineStyleThick ? 2 : 1) * scale.height - 0.001);
    if (t < 1)
        t = 1;
    t /= scale.height;
    int lines = (style & 0xff) == NSUnderlineStyleDouble ? 2 : 1;
    for (int k = 0; k < lines; k++) {
        /* The edge nearer the baseline, in points above it (negative: below). */
        CGFloat edge = strike ? round((font.xHeight / 2 + t / 2) * scale.height) / scale.height : -t - 2 * k * t;
        if (strike)
            edge -= 2 * k * t;
        CGFloat y0 = baseline + (flipped ? -edge : edge - t);
        CGFloat left = floor(x0 * scale.width) / scale.width, right = ceil(x1 * scale.width) / scale.width;
        fill_rect(cg, CGRectMake(left, y0, right - left, t), color);
    }
}

/* Draw a layout whose first line's top is at `top` (in the context's
 * coordinates: y grows down when flipped), lines starting at `left`. */
void
UIFLayoutDrawLines(UIFLayout *L, size_t first, size_t count, CGFloat left, CGFloat top, BOOL flipped)
{
    UIFLayoutDrawLinesInContext(UIFCurrentCGContext(), L, first, count, left, top, flipped);
}

void
UIFLayoutDrawLinesInContext(CGContextRef cg, UIFLayout *L, size_t first, size_t count, CGFloat left, CGFloat top, BOOL flipped)
{
    if (!cg)
        return;
    CGAffineTransform savedTM = CGContextGetTextMatrix(cg);
    CGContextSetTextMatrix(cg, flipped ? CGAffineTransformMakeScale(1, -1) : CGAffineTransformIdentity);
    for (size_t i = first; i < first + count && i < L->count; i++) {
        UIFLine *ln = &L->lines[i];
        if (!ln->line)
            continue;
        CGFloat x = left + ln->x;
        CGFloat baseline = flipped ? top + ln->top + ln->baseline : top - ln->top - ln->baseline;
        CFArrayRef runs = CTLineGetGlyphRuns(ln->line);
        CFIndex nruns = CFArrayGetCount(runs);
        /* Backgrounds first, behind the line fragment. */
        for (CFIndex r = 0; r < nruns; r++) {
            CTRunRef run = CFArrayGetValueAtIndex(runs, r);
            NSDictionary *a = ((NSDictionary *)CTRunGetAttributes(run))[kDrawnHere];
            CGColorRef bg = UIFCGColor(a[NSBackgroundColorAttributeName]);
            if (!bg || !CTRunGetGlyphCount(run))
                continue;
            CGPoint p0;
            CTRunGetPositions(run, CFRangeMake(0, 1), &p0);
            double w = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), NULL, NULL, NULL);
            CGFloat rtop = flipped ? top + ln->top : top - ln->top - ln->height;
            fill_rect(cg, CGRectMake(x + p0.x, rtop, w, ln->height), bg);
        }
        for (CFIndex r = 0; r < nruns; r++) {
            CTRunRef run = CFArrayGetValueAtIndex(runs, r);
            NSDictionary *ra = (NSDictionary *)CTRunGetAttributes(run);
            NSDictionary *a = ra[kDrawnHere];
            CGFloat offset = [a[NSBaselineOffsetAttributeName] doubleValue];
            CGFloat by = flipped ? baseline - offset : baseline + offset;
            NSShadow *shadow = a[NSShadowAttributeName];
            CGContextSaveGState(cg);
            if ([shadow isKindOfClass:[NSShadow class]])
                [shadow set];
            CGContextSetTextPosition(cg, x, by);
            CTRunDraw(run, cg, CFRangeMake(0, 0));
            /* Underline and strikethrough, from the run's start to its end. */
            CFIndex gc = CTRunGetGlyphCount(run);
            NSInteger ul = [a[NSUnderlineStyleAttributeName] integerValue];
            NSInteger st = [a[NSStrikethroughStyleAttributeName] integerValue];
            if (gc > 0 && (ul || st)) {
                NSFont *f = ra[(id)kCTFontAttributeName];
                CGPoint p0;
                CTRunGetPositions(run, CFRangeMake(0, 1), &p0);
                double w = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), NULL, NULL, NULL);
                /* Not under whitespace that ends the line. */
                if (r == nruns - 1)
                    w = MAX(0, w - CTLineGetTrailingWhitespaceWidth(ln->line));
                CGFloat x0 = x + p0.x, x1 = x0 + w;
                CGColorRef fg = UIFCGColor(a[NSForegroundColorAttributeName]);
                if (ul) {
                    CGColorRef uc = UIFCGColor(a[NSUnderlineColorAttributeName]);
                    decoration(cg, ul, x0, x1, by, f, NO, flipped, uc ? uc : fg);
                }
                if (st) {
                    CGColorRef sc = UIFCGColor(a[NSStrikethroughColorAttributeName]);
                    decoration(cg, st, x0, x1, by, f, YES, flipped, sc ? sc : fg);
                }
            }
            CGContextRestoreGState(cg);
        }
    }
    CGContextSetTextMatrix(cg, savedTM);
}

void
UIFLayoutDraw(UIFLayout *L, CGFloat left, CGFloat top, BOOL flipped)
{
    UIFLayoutDrawLines(L, 0, L->count, left, top, flipped);
}
