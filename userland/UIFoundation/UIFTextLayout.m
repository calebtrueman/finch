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
 */
#import "UIFTextLayout.h"

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
    a[(id)kCTForegroundColorAttributeName] = (id)(fg ? fg : black());
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
    NSAttributedString *ct = ct_string(s);
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
            CGFloat room = (right == CGFLOAT_MAX ? w + indent : right) - indent - w;
            NSTextAlignment align = ps.alignment;
            if (align == NSTextAlignmentNatural || align == NSTextAlignmentJustified)
                align = ps.baseWritingDirection == NSWritingDirectionRightToLeft ? NSTextAlignmentRight : NSTextAlignmentLeft;
            if (room > 0 && containerWidth != CGFLOAT_MAX) {
                if (align == NSTextAlignmentCenter)
                    x += room / 2;
                else if (align == NSTextAlignmentRight)
                    x += room;
            }
            /* Its characters: the paragraph break goes with the paragraph's last line. */
            NSUInteger lineEnd = lastInParagraph ? next : start + (NSUInteger)(pos + count);
            if (stop)
                lineEnd = next; /* a truncated last line stands for the rest of its paragraph */
            UIFLine ln = {line, NSMakeRange(start + (NSUInteger)pos, lineEnd - (start + (NSUInteger)pos)), x, y, h, h - desc, w, 0, NO};
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
                if (L.count && L.lines[L.count - 1].spacingAfter == 0) {
                    L.lines[L.count - 1].spacingAfter = ps.lineSpacing;
                    y += ps.lineSpacing;
                }
                CGFloat h, asc, desc;
                line_metrics(NULL, s, typing, CFRangeMake((CFIndex)len, 0), fontLeading, p.roundLeading, &h, &asc, &desc);
                if (p.height > 0 && y + h > p.height + 0.001)
                    break;
                UIFLine ln = {NULL, NSMakeRange(len, 0), ps.firstLineHeadIndent, y, h, h - desc, 0, 0, YES};
                layout_add(&L, ln);
                y += h;
                break;
            }
        } else {
            break;
        }
    }
    /* Trailing spacing isn't part of the height. */
    if (L.count) {
        UIFLine *last = &L.lines[L.count - 1];
        L.height = last->top + last->height;
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
    if (minX > 0 && maxX <= minX)
        maxX = minX;
    return CGRectMake(0, 0, maxX, L->height);
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
    CGContextRef cg = UIFCurrentCGContext();
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
