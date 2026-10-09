/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextBlock, NSTextTable and NSTextTableBlock: the boxes a paragraph's
 * style can put it in (NSParagraphStyle's textBlocks, outermost first), and
 * NSAttributedString's lookups for blocks, tables and lists.
 *
 * A block keeps twenty values, each absolute or a percentage of the width
 * it's laid out in: the dimensions (indexed as NSTextBlockDimension, 0-6)
 * and the widths of its padding, border and margin on each edge (8 + 4 per
 * layer + the edge). Archives use Apple's keys: NSParam<n> for the values
 * that are set, NSValueTypes with a bit per percentage and the vertical
 * alignment in its top two bits, NSBackgroundColor and NSBorderColors (a
 * table's: NSNumCols and NSTableFlags; a cell's: NSTable, NSRowNum,
 * NSRowSpan, NSColNum, NSColSpan). Blocks are equal only to themselves, as
 * Apple's are. Layout is NSLayoutManager's (UIFTextLayout.m), which asks
 * blocks for their insets through the functions at the end of this file.
 */
#import "UIFoundationInternal.h"
#import "UIFTextBlock.h"

enum { kParams = 20, kWidthBase = 8 };

static int
width_index(NSTextBlockLayer layer, NSRectEdge edge)
{
    if (layer < NSTextBlockPadding || layer > NSTextBlockMargin || edge > NSMaxYEdge)
        return -1;
    return kWidthBase + (int)(layer + 1) * 4 + (int)edge;
}

@implementation NSTextBlock {
  @public
    CGFloat _value[kParams];
    uint32_t _percent; /* a bit per value */
    NSTextBlockVerticalAlignment _valign;
    id _background;
    id _border[4];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init { return [super init]; }

- (void)dealloc
{
    [_background release];
    for (int i = 0; i < 4; i++)
        [_border[i] release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSTextBlock *b = [[[self class] allocWithZone:zone] init];
    [b _finchCopyFrom:self];
    return b;
}

- (void)_finchCopyFrom:(NSTextBlock *)o
{
    memcpy(_value, o->_value, sizeof _value);
    _percent = o->_percent;
    _valign = o->_valign;
    _background = [o->_background retain];
    for (int i = 0; i < 4; i++)
        _border[i] = [o->_border[i] retain];
}

#pragma mark Values

- (void)_finchSet:(int)i value:(CGFloat)v type:(NSTextBlockValueType)type
{
    if (i < 0 || i >= kParams)
        return;
    _value[i] = v;
    if (type == NSTextBlockPercentageValueType)
        _percent |= 1u << i;
    else
        _percent &= ~(1u << i);
}

- (void)setValue:(CGFloat)val type:(NSTextBlockValueType)type forDimension:(NSTextBlockDimension)dimension
{
    if ((int)dimension <= NSTextBlockMaximumHeight && dimension != 3)
        [self _finchSet:(int)dimension value:val type:type];
}
- (CGFloat)valueForDimension:(NSTextBlockDimension)dimension
{
    return (int)dimension <= NSTextBlockMaximumHeight ? _value[dimension] : 0;
}
- (NSTextBlockValueType)valueTypeForDimension:(NSTextBlockDimension)dimension
{
    return (int)dimension <= NSTextBlockMaximumHeight && (_percent >> dimension & 1) ? NSTextBlockPercentageValueType
                                                                                      : NSTextBlockAbsoluteValueType;
}

- (CGFloat)contentWidth { return [self valueForDimension:NSTextBlockWidth]; }
- (NSTextBlockValueType)contentWidthValueType { return [self valueTypeForDimension:NSTextBlockWidth]; }
- (void)setContentWidth:(CGFloat)val type:(NSTextBlockValueType)type
{
    [self setValue:val type:type forDimension:NSTextBlockWidth];
}

- (void)setWidth:(CGFloat)val type:(NSTextBlockValueType)type forLayer:(NSTextBlockLayer)layer edge:(NSRectEdge)edge
{
    [self _finchSet:width_index(layer, edge) value:val type:type];
}
- (void)setWidth:(CGFloat)val type:(NSTextBlockValueType)type forLayer:(NSTextBlockLayer)layer
{
    for (NSRectEdge e = NSMinXEdge; e <= NSMaxYEdge; e++)
        [self setWidth:val type:type forLayer:layer edge:e];
}
- (CGFloat)widthForLayer:(NSTextBlockLayer)layer edge:(NSRectEdge)edge
{
    int i = width_index(layer, edge);
    return i < 0 ? 0 : _value[i];
}
- (NSTextBlockValueType)widthValueTypeForLayer:(NSTextBlockLayer)layer edge:(NSRectEdge)edge
{
    int i = width_index(layer, edge);
    return i >= 0 && (_percent >> i & 1) ? NSTextBlockPercentageValueType : NSTextBlockAbsoluteValueType;
}

- (NSTextBlockVerticalAlignment)verticalAlignment { return _valign; }
- (void)setVerticalAlignment:(NSTextBlockVerticalAlignment)a { _valign = a; }
- (id)backgroundColor { return _background; }
- (void)setBackgroundColor:(id)c
{
    [_background autorelease];
    _background = [c retain];
}
- (void)setBorderColor:(id)color forEdge:(NSRectEdge)edge
{
    if (edge > NSMaxYEdge)
        return;
    [_border[edge] autorelease];
    _border[edge] = [color retain];
}
- (void)setBorderColor:(id)color
{
    for (NSRectEdge e = NSMinXEdge; e <= NSMaxYEdge; e++)
        [self setBorderColor:color forEdge:e];
}
- (id)borderColorForEdge:(NSRectEdge)edge { return edge <= NSMaxYEdge ? _border[edge] : nil; }

#pragma mark Geometry

/* A value in points, percentages being of `of`. */
static CGFloat
resolve(NSTextBlock *b, int i, CGFloat of)
{
    return (b->_percent >> i & 1) ? b->_value[i] * of / 100 : b->_value[i];
}

CGFloat
UIFTextBlockInset(NSTextBlock *b, NSRectEdge edge, CGFloat of)
{
    CGFloat sum = 0;
    for (NSTextBlockLayer l = NSTextBlockPadding; l <= NSTextBlockMargin; l++)
        sum += resolve(b, width_index(l, edge), of);
    return sum;
}

CGFloat
UIFTextBlockLayerInset(NSTextBlock *b, NSTextBlockLayer upTo, NSRectEdge edge, CGFloat of)
{
    /* the widths outside the given layer: the margin, then the border */
    CGFloat sum = 0;
    for (NSTextBlockLayer l = NSTextBlockMargin; l > upTo; l--)
        sum += resolve(b, width_index(l, edge), of);
    return sum;
}

CGFloat
UIFTextBlockDimension(NSTextBlock *b, NSTextBlockDimension d, CGFloat of)
{
    return resolve(b, (int)d, of);
}

- (NSRect)rectForLayoutAtPoint:(NSPoint)start
                        inRect:(NSRect)rect
                 textContainer:(NSTextContainer *)container
                characterRange:(NSRange)range
{
    CGFloat of = NSWidth(rect);
    CGFloat left = UIFTextBlockInset(self, NSMinXEdge, of), right = UIFTextBlockInset(self, NSMaxXEdge, of);
    CGFloat top = UIFTextBlockInset(self, NSMinYEdge, of);
    CGFloat width = UIFTextBlockDimension(self, NSTextBlockWidth, of);
    if (width <= 0)
        width = MAX(0, NSMaxX(rect) - start.x - left - right);
    CGFloat minW = UIFTextBlockDimension(self, NSTextBlockMinimumWidth, of),
            maxW = UIFTextBlockDimension(self, NSTextBlockMaximumWidth, of);
    if (minW > 0)
        width = MAX(width, minW);
    if (maxW > 0)
        width = MIN(width, maxW);
    return NSMakeRect(start.x + left, start.y + top, width, MAX(0, NSMaxY(rect) - start.y - top));
}

- (NSRect)boundsRectForContentRect:(NSRect)content
                            inRect:(NSRect)rect
                     textContainer:(NSTextContainer *)container
                    characterRange:(NSRange)range
{
    CGFloat of = NSWidth(rect);
    CGFloat left = UIFTextBlockInset(self, NSMinXEdge, of), right = UIFTextBlockInset(self, NSMaxXEdge, of);
    CGFloat top = UIFTextBlockInset(self, NSMinYEdge, of), bottom = UIFTextBlockInset(self, NSMaxYEdge, of);
    CGFloat h = NSHeight(content);
    CGFloat minH = UIFTextBlockDimension(self, NSTextBlockMinimumHeight, of),
            height = UIFTextBlockDimension(self, NSTextBlockHeight, of);
    h = MAX(h, MAX(minH, height));
    return NSMakeRect(NSMinX(content) - left, NSMinY(content) - top, NSWidth(content) + left + right, h + top + bottom);
}

/* The background inside the border, then the border, inside the margin. */
- (void)drawBackgroundWithFrame:(NSRect)frame
                         inView:(id)view
                 characterRange:(NSRange)range
                  layoutManager:(id)lm
{
    CGContextRef cg = UIFCurrentCGContext();
    if (!cg)
        return;
    CGFloat of = NSWidth(frame);
    NSRect border = frame;
    border.origin.x += UIFTextBlockLayerInset(self, NSTextBlockBorder, NSMinXEdge, of);
    border.origin.y += UIFTextBlockLayerInset(self, NSTextBlockBorder, NSMinYEdge, of);
    border.size.width -= UIFTextBlockLayerInset(self, NSTextBlockBorder, NSMinXEdge, of) +
                         UIFTextBlockLayerInset(self, NSTextBlockBorder, NSMaxXEdge, of);
    border.size.height -= UIFTextBlockLayerInset(self, NSTextBlockBorder, NSMinYEdge, of) +
                          UIFTextBlockLayerInset(self, NSTextBlockBorder, NSMaxYEdge, of);
    CGFloat bw[4];
    for (int e = 0; e < 4; e++)
        bw[e] = resolve(self, width_index(NSTextBlockBorder, e), of);
    BOOL flipped = UIFCurrentContextIsFlipped();
    if (_background) {
        CGRect inner = CGRectMake(NSMinX(border) + bw[NSMinXEdge], NSMinY(border) + bw[NSMinYEdge],
                                  NSWidth(border) - bw[NSMinXEdge] - bw[NSMaxXEdge],
                                  NSHeight(border) - bw[NSMinYEdge] - bw[NSMaxYEdge]);
        CGContextSetFillColorWithColor(cg, UIFCGColor(_background));
        CGContextFillRect(cg, inner);
    }
    for (int e = 0; e < 4; e++) {
        if (bw[e] <= 0)
            continue;
        id color = _border[e] ?: [UIFClass("NSColor") performSelector:@selector(blackColor)];
        CGRect r;
        /* MinY is the top in the (flipped) text view */
        switch (e) {
        case NSMinXEdge: r = CGRectMake(NSMinX(border), NSMinY(border), bw[e], NSHeight(border)); break;
        case NSMaxXEdge: r = CGRectMake(NSMaxX(border) - bw[e], NSMinY(border), bw[e], NSHeight(border)); break;
        case NSMinYEdge:
            r = flipped ? CGRectMake(NSMinX(border), NSMinY(border), NSWidth(border), bw[e])
                        : CGRectMake(NSMinX(border), NSMaxY(border) - bw[e], NSWidth(border), bw[e]);
            break;
        default:
            r = flipped ? CGRectMake(NSMinX(border), NSMaxY(border) - bw[e], NSWidth(border), bw[e])
                        : CGRectMake(NSMinX(border), NSMinY(border), NSWidth(border), bw[e]);
            break;
        }
        CGContextSetFillColorWithColor(cg, UIFCGColor(color));
        CGContextFillRect(cg, r);
    }
}

#pragma mark Archiving

- (void)encodeWithCoder:(NSCoder *)coder
{
    for (int i = 0; i < kParams; i++)
        if (_value[i] != 0)
            [coder encodeDouble:_value[i] forKey:[NSString stringWithFormat:@"NSParam%d", i]];
    uint32_t types = _percent | (uint32_t)_valign << 30;
    if (types)
        [coder encodeInt64:types forKey:@"NSValueTypes"];
    if (_background)
        [coder encodeObject:_background forKey:@"NSBackgroundColor"];
    if (_border[0] || _border[1] || _border[2] || _border[3]) {
        id null = [NSNull null];
        [coder encodeObject:[NSMutableArray arrayWithObjects:_border[0] ?: null, _border[1] ?: null, _border[2] ?: null,
                                                             _border[3] ?: null, nil]
                     forKey:@"NSBorderColors"];
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        for (int i = 0; i < kParams; i++) {
            NSString *k = [NSString stringWithFormat:@"NSParam%d", i];
            if ([coder containsValueForKey:k])
                _value[i] = [coder decodeDoubleForKey:k];
        }
        uint32_t types = (uint32_t)[coder decodeInt64ForKey:@"NSValueTypes"];
        _percent = types & ((1u << kParams) - 1);
        _valign = (NSTextBlockVerticalAlignment)(types >> 30);
        Class color = UIFClass("NSColor");
        NSSet *classes = [NSSet setWithObjects:[NSArray class], [NSNull class], color, nil];
        _background = [[coder decodeObjectOfClass:color forKey:@"NSBackgroundColor"] retain];
        NSArray *borders = [coder decodeObjectOfClasses:classes forKey:@"NSBorderColors"];
        for (NSUInteger i = 0; i < 4 && i < borders.count; i++)
            if (borders[i] != [NSNull null])
                _border[i] = [borders[i] retain];
    }
    return self;
}

@end

#pragma mark - NSTextTable

@implementation NSTextTable {
    NSUInteger _columns;
    NSTextTableLayoutAlgorithm _algorithm;
    BOOL _collapses, _hides;
}

- (void)_finchCopyFrom:(NSTextBlock *)o
{
    [super _finchCopyFrom:o];
    NSTextTable *t = (NSTextTable *)o;
    _columns = t->_columns;
    _algorithm = t->_algorithm;
    _collapses = t->_collapses;
    _hides = t->_hides;
}

- (NSUInteger)numberOfColumns { return _columns; }
- (void)setNumberOfColumns:(NSUInteger)n { _columns = n; }
- (NSTextTableLayoutAlgorithm)layoutAlgorithm { return _algorithm; }
- (void)setLayoutAlgorithm:(NSTextTableLayoutAlgorithm)a { _algorithm = a; }
- (BOOL)collapsesBorders { return _collapses; }
- (void)setCollapsesBorders:(BOOL)f { _collapses = f; }
- (BOOL)hidesEmptyCells { return _hides; }
- (void)setHidesEmptyCells:(BOOL)f { _hides = f; }

/* Columns share the table's content width equally. */
- (NSRect)rectForBlock:(NSTextTableBlock *)block
            layoutAtPoint:(NSPoint)start
                   inRect:(NSRect)rect
            textContainer:(NSTextContainer *)container
           characterRange:(NSRange)range
{
    NSRect table = [self rectForLayoutAtPoint:NSMakePoint(NSMinX(rect), start.y) inRect:rect textContainer:container
                               characterRange:range];
    NSUInteger cols = MAX(_columns, 1);
    CGFloat colWidth = NSWidth(table) / cols;
    NSInteger c = MIN((NSUInteger)MAX(block.startingColumn, 0), cols - 1);
    NSInteger span = MAX(1, MIN(block.columnSpan, (NSInteger)(cols - c)));
    NSRect cell = NSMakeRect(NSMinX(table) + c * colWidth, start.y, span * colWidth, NSMaxY(rect) - start.y);
    return [block rectForLayoutAtPoint:cell.origin inRect:cell textContainer:container characterRange:range];
}

- (NSRect)boundsRectForBlock:(NSTextTableBlock *)block
                 contentRect:(NSRect)content
                      inRect:(NSRect)rect
               textContainer:(NSTextContainer *)container
              characterRange:(NSRange)range
{
    return [block boundsRectForContentRect:content inRect:rect textContainer:container characterRange:range];
}

- (void)drawBackgroundForBlock:(NSTextTableBlock *)block
                     withFrame:(NSRect)frame
                        inView:(id)view
                characterRange:(NSRange)range
                 layoutManager:(id)lm
{
    [block drawBackgroundWithFrame:frame inView:view characterRange:range layoutManager:lm];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeInteger:(NSInteger)_columns forKey:@"NSNumCols"];
    NSInteger flags = (_collapses ? 1 : 0) | (_hides ? 2 : 0) | (NSInteger)_algorithm << 2;
    if (flags)
        [coder encodeInteger:flags forKey:@"NSTableFlags"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _columns = (NSUInteger)[coder decodeIntegerForKey:@"NSNumCols"];
        NSInteger flags = [coder decodeIntegerForKey:@"NSTableFlags"];
        _collapses = (flags & 1) != 0;
        _hides = (flags & 2) != 0;
        _algorithm = (NSTextTableLayoutAlgorithm)(flags >> 2 & 1);
    }
    return self;
}

@end

#pragma mark - NSTextTableBlock

@implementation NSTextTableBlock {
    NSTextTable *_table;
    NSInteger _row, _rowSpan, _col, _colSpan;
}

- (instancetype)initWithTable:(NSTextTable *)table
                  startingRow:(NSInteger)row
                      rowSpan:(NSInteger)rowSpan
               startingColumn:(NSInteger)col
                   columnSpan:(NSInteger)colSpan
{
    if ((self = [super init])) {
        _table = [table retain];
        _row = row;
        _rowSpan = rowSpan;
        _col = col;
        _colSpan = colSpan;
    }
    return self;
}

- (void)dealloc
{
    [_table release];
    [super dealloc];
}

- (void)_finchCopyFrom:(NSTextBlock *)o
{
    [super _finchCopyFrom:o];
    NSTextTableBlock *b = (NSTextTableBlock *)o;
    _table = [b->_table retain];
    _row = b->_row;
    _rowSpan = b->_rowSpan;
    _col = b->_col;
    _colSpan = b->_colSpan;
}

- (NSTextTable *)table { return _table; }
- (NSInteger)startingRow { return _row; }
- (NSInteger)rowSpan { return _rowSpan; }
- (NSInteger)startingColumn { return _col; }
- (NSInteger)columnSpan { return _colSpan; }

- (NSRect)rectForLayoutAtPoint:(NSPoint)start
                        inRect:(NSRect)rect
                 textContainer:(NSTextContainer *)container
                characterRange:(NSRange)range
{
    return [super rectForLayoutAtPoint:start inRect:rect textContainer:container characterRange:range];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:_table forKey:@"NSTable"];
    [coder encodeInteger:_row forKey:@"NSRowNum"];
    [coder encodeInteger:_rowSpan forKey:@"NSRowSpan"];
    [coder encodeInteger:_col forKey:@"NSColNum"];
    [coder encodeInteger:_colSpan forKey:@"NSColSpan"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        _table = [[coder decodeObjectOfClass:[NSTextTable class] forKey:@"NSTable"] retain];
        _row = [coder decodeIntegerForKey:@"NSRowNum"];
        _rowSpan = [coder decodeIntegerForKey:@"NSRowSpan"];
        _col = [coder decodeIntegerForKey:@"NSColNum"];
        _colSpan = [coder decodeIntegerForKey:@"NSColSpan"];
    }
    return self;
}

@end

#pragma mark - NSAttributedString

/* The paragraphs around `index` whose style holds `thing` in `key` (textBlocks, textLists). */
static NSRange
range_holding(NSAttributedString *s, id thing, NSUInteger index, BOOL (^holds)(NSParagraphStyle *ps, id thing))
{
    NSUInteger len = s.length;
    if (index >= len || !thing)
        return NSMakeRange(NSNotFound, 0);
    NSRange r;
    NSParagraphStyle *ps = [s attribute:NSParagraphStyleAttributeName atIndex:index effectiveRange:&r];
    if (!holds(ps, thing))
        return NSMakeRange(NSNotFound, 0);
    NSUInteger lo = r.location, hi = NSMaxRange(r);
    while (lo > 0) {
        NSRange p;
        NSParagraphStyle *q = [s attribute:NSParagraphStyleAttributeName atIndex:lo - 1 effectiveRange:&p];
        if (!holds(q, thing))
            break;
        lo = p.location;
    }
    while (hi < len) {
        NSRange p;
        NSParagraphStyle *q = [s attribute:NSParagraphStyleAttributeName atIndex:hi effectiveRange:&p];
        if (!holds(q, thing))
            break;
        hi = NSMaxRange(p);
    }
    return NSMakeRange(lo, hi - lo);
}

@implementation NSAttributedString (FinchTextBlocks)

- (NSRange)rangeOfTextBlock:(NSTextBlock *)block atIndex:(NSUInteger)location
{
    return range_holding(self, block, location, ^BOOL(NSParagraphStyle *ps, id b) {
      return ps && [ps.textBlocks indexOfObjectIdenticalTo:b] != NSNotFound;
    });
}

- (NSRange)rangeOfTextTable:(NSTextTable *)table atIndex:(NSUInteger)location
{
    return range_holding(self, table, location, ^BOOL(NSParagraphStyle *ps, id t) {
      for (NSTextBlock *b in ps.textBlocks)
          if ([b isKindOfClass:[NSTextTableBlock class]] && ((NSTextTableBlock *)b).table == t)
              return YES;
      return NO;
    });
}

- (NSRange)rangeOfTextList:(NSTextList *)list atIndex:(NSUInteger)location
{
    return range_holding(self, list, location, ^BOOL(NSParagraphStyle *ps, id l) {
      return ps && [ps.textLists indexOfObjectIdenticalTo:l] != NSNotFound;
    });
}

/* Items are the list's paragraphs at its own level (not those of lists nested in it). */
- (NSInteger)itemNumberInTextList:(NSTextList *)list atIndex:(NSUInteger)location
{
    NSRange r = [self rangeOfTextList:list atIndex:location];
    if (r.location == NSNotFound)
        return 0;
    NSString *str = self.string;
    NSInteger n = list.startingItemNumber;
    NSUInteger i = r.location;
    while (i < NSMaxRange(r)) {
        NSUInteger start, end;
        [str getParagraphStart:&start end:&end contentsEnd:NULL forRange:NSMakeRange(i, 0)];
        if (location >= start && location < MAX(end, start + 1))
            return n;
        NSParagraphStyle *ps = [self attribute:NSParagraphStyleAttributeName atIndex:start effectiveRange:NULL];
        if (ps.textLists.lastObject == list)
            n++;
        i = end > i ? end : i + 1;
    }
    return n;
}

@end
