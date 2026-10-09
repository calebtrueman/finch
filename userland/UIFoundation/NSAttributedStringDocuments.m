/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSAttributedString's document formats: RTF and RTFD read and written,
 * plain text in any encoding, and the NSAttributedString and
 * NSMutableAttributedString methods that load and save them
 * (-initWithData:options:documentAttributes:error:, -dataFromRange:...,
 * -fileWrapperFromRange:..., -RTFFromRange:..., and the rest).
 *
 * The RTF reader follows the RTF 1.9 specification and the Cocoa
 * extensions Apple's writer uses (\cocoartf, \expandedcolortbl, \pardirnatural,
 * \partightenfactor, \NeXTGraphic attachments). The writer produces RTF laid
 * out as Apple's does (header, font and colour tables, \pard with the default
 * tab stops, a line per font change), naming Apple's fonts for the fonts Finch
 * ships in their place, so documents read back on macOS as written.
 */
#import "UIFoundationInternal.h"
#import <objc/message.h>

#pragma mark - Reading RTF

/* Character properties, kept per group. */
typedef struct {
    int font;          /* \fN, -1 for none */
    int halfPoints;    /* \fsN */
    BOOL bold, italic, strike, outline, shadow;
    int underline;     /* NSUnderlineStyle */
    int fg, bg;        /* colour table indices (0: none) */
    int superscript;   /* \super 1, \sub -1 */
    int baselineHalf;  /* \upN/\dnN, half points */
    int expandTwips;   /* \expndtwN */
    BOOL kerning;
    int uc;            /* \ucN: fallback characters after \u */
} CharState;

typedef struct {
    NSTextAlignment alignment;
    int li, ri, fi, sb, sa, sl; /* twips */
    BOOL slmult;
    int slleading;
    NSWritingDirection direction;
    int tabCount;
    int tabs[64];
    NSTextAlignment tabAlign[64];
    NSTextAlignment pendingTab;
    BOOL specified; /* the document gave paragraph properties (\pard or any): only then is there a style */
    BOOL intbl;     /* \intbl: the paragraph is in a table's cell */
} ParaState;

/* A table row's definition (\trowd ... \cellxN per cell): the cells, and the table's borders. */
typedef struct {
    int right;               /* \cellx, twips */
    int pad[4];              /* \clpadl, t, r, b (NSRectEdge order: MinX, MinY, MaxX, MaxY) */
    int border[4], borderColor[4];
    int background;          /* \clcbpat */
    NSTextBlockVerticalAlignment valign;
} CellDef;

enum Dest {
    DestText, DestSkip, DestFontTable, DestColorTable, DestExpandedColors, DestInfo, DestInfoItem,
    DestFieldInstruction, DestFieldResult, DestAttachment, DestListText
};

typedef struct {
    CharState c;
    ParaState p;
    enum Dest dest;
    NSString *infoKey;  /* DestInfoItem */
} RTFState;

@interface UIFRTFReader : NSObject {
@public
    const uint8_t *_b;
    size_t _n, _i;
    NSMutableAttributedString *_out;
    NSMutableDictionary *_doc;
    NSMutableDictionary<NSNumber *, NSString *> *_fonts;
    NSMutableArray *_colors;          /* \colortbl, NSColor or NSNull */
    NSMutableArray *_expandedColors;  /* \expandedcolortbl, NSColor or NSNull */
    int _fontNumber;                  /* the font table entry being read */
    NSMutableString *_text;           /* text of a table entry or info item */
    int _red, _green, _blue;
    BOOL _colorHasValue;
    NSMutableString *_field;          /* \fldinst text */
    NSString *_link;
    NSStringEncoding _encoding;
    RTFState _stack[256];
    int _depth;
    RTFState _s;
    int _skipChars;                   /* left to skip after \u */
    NSDictionary *_attachments;       /* RTFD: file name -> NSFileWrapper */
    NSString *_attachmentName;
    NSMutableDictionary *_attrCache;
    BOOL _cacheValid;
    NSMutableString *_pending;        /* text not yet appended, with _pendingAttrs */
    NSDictionary *_pendingAttrs;
    /* tables */
    CellDef _cells[64], _cell;        /* the row's cells, and the one being defined */
    int _cellCount;
    int _tableBorder[4], _tableBorderColor[4];
    int *_borderWidth, *_borderColor; /* where \brdrw and \brdrcf go */
    NSTextTable *_table;              /* the table being read, or nil */
    NSMutableDictionary *_cellBlocks; /* "row,column" -> NSTextTableBlock */
    int _row, _column;
}
@end

static Class
color_class(void)
{
    return UIFClass("NSColor");
}

static id
srgb_color(double r, double g, double b, double a)
{
    Class c = color_class();
    return c ? ((id(*)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat))objc_msgSend)(
                   c, @selector(colorWithSRGBRed:green:blue:alpha:), r, g, b, a)
             : nil;
}

static id
generic_color(double r, double g, double b)
{
    Class c = color_class();
    return c ? ((id(*)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat))objc_msgSend)(
                   c, @selector(colorWithCalibratedRed:green:blue:alpha:), r, g, b, 1.0)
             : nil;
}

@implementation UIFRTFReader

- (instancetype)initWithData:(NSData *)data attachments:(NSDictionary *)attachments
{
    self = [super init];
    if (self) {
        _b = [data bytes];
        _n = [data length];
        _out = [[NSMutableAttributedString alloc] init];
        _doc = [[NSMutableDictionary alloc] init];
        _fonts = [[NSMutableDictionary alloc] init];
        _colors = [[NSMutableArray alloc] init];
        _expandedColors = [[NSMutableArray alloc] init];
        _text = [[NSMutableString alloc] init];
        _pending = [[NSMutableString alloc] init];
        _attrCache = [[NSMutableDictionary alloc] init];
        _encoding = NSWindowsCP1252StringEncoding;
        _attachments = [attachments retain];
        _cellBlocks = [[NSMutableDictionary alloc] init];
        [self _resetChar:&_s.c];
        [self _resetPara:&_s.p];
        _s.dest = DestText;
    }
    return self;
}

- (void)dealloc
{
    [_table release];
    [_cellBlocks release];
    [_out release];
    [_doc release];
    [_fonts release];
    [_colors release];
    [_expandedColors release];
    [_text release];
    [_field release];
    [_link release];
    [_attachments release];
    [_attachmentName release];
    [_attrCache release];
    [_pending release];
    [_pendingAttrs release];
    [super dealloc];
}

- (void)_resetChar:(CharState *)c
{
    memset(c, 0, sizeof *c);
    c->font = -1;
    c->halfPoints = 24;
    c->uc = 1;
}

- (void)_resetPara:(ParaState *)p
{
    memset(p, 0, sizeof *p);
    p->alignment = NSTextAlignmentLeft;
    p->direction = NSWritingDirectionNatural;
    p->pendingTab = NSTextAlignmentLeft;
}

#pragma mark Attributes

- (NSFont *)_font
{
    CharState *c = &_s.c;
    NSString *name = c->font >= 0 ? _fonts[@(c->font)] : nil;
    CGFloat size = c->halfPoints / 2.0;
    NSFont *font = name ? [NSFont fontWithName:name size:size] : nil;
    if (!font)
        font = [NSFont fontWithName:@"Helvetica" size:size];
    if (!font)
        return UIFDefaultFont();
    CTFontSymbolicTraits have = CTFontGetSymbolicTraits((CTFontRef)font);
    CTFontSymbolicTraits want = (c->bold ? kCTFontTraitBold : 0) | (c->italic ? kCTFontTraitItalic : 0);
    CTFontSymbolicTraits mask = kCTFontTraitBold | kCTFontTraitItalic;
    if ((have & mask) != want) {
        CTFontRef t = CTFontCreateCopyWithSymbolicTraits((CTFontRef)font, size, NULL, want, mask);
        if (t)
            font = [(NSFont *)t autorelease];
    }
    return font;
}

static id
color_at(NSArray *colors, NSArray *expanded, int i)
{
    if (i <= 0)
        return nil;
    id e = i < (int)[expanded count] ? expanded[(NSUInteger)i] : nil;
    if (e && e != [NSNull null])
        return e;
    id c = i < (int)[colors count] ? colors[(NSUInteger)i] : nil;
    return c == [NSNull null] ? nil : c;
}

- (NSParagraphStyle *)_paragraphStyle
{
    ParaState *p = &_s.p;
    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [ps setAlignment:p->alignment];
    [ps setHeadIndent:p->li / 20.0];
    [ps setFirstLineHeadIndent:(p->li + p->fi) / 20.0];
    /* as Apple's reader: a right indent becomes a tail indent from the leading margin, across the text width */
    if (p->ri) {
        NSSize paper = _doc[NSPaperSizeDocumentAttribute] ? [_doc[NSPaperSizeDocumentAttribute] sizeValue] : NSMakeSize(612, 792);
        CGFloat left = _doc[NSLeftMarginDocumentAttribute] ? [_doc[NSLeftMarginDocumentAttribute] doubleValue] : 90;
        CGFloat right = _doc[NSRightMarginDocumentAttribute] ? [_doc[NSRightMarginDocumentAttribute] doubleValue] : 90;
        [ps setTailIndent:paper.width - left - right - p->ri / 20.0];
    }
    [ps setParagraphSpacingBefore:p->sb / 20.0];
    [ps setParagraphSpacing:p->sa / 20.0];
    if (p->sl > 0 && p->slmult)
        [ps setLineHeightMultiple:p->sl / 240.0];
    else if (p->sl > 0)
        [ps setMinimumLineHeight:p->sl / 20.0];
    else if (p->sl < 0) {
        [ps setMinimumLineHeight:-p->sl / 20.0];
        [ps setMaximumLineHeight:-p->sl / 20.0];
    }
    if (p->slleading)
        [ps setLineSpacing:p->slleading / 20.0];
    [ps setBaseWritingDirection:p->direction];
    NSMutableArray *tabs = [NSMutableArray array];
    for (int i = 0; i < p->tabCount; i++)
        [tabs addObject:[[[NSTextTab alloc] initWithTextAlignment:p->tabAlign[i] location:p->tabs[i] / 20.0 options:@{}]
                            autorelease]];
    [ps setTabStops:tabs];
    if (p->intbl)
        [ps setTextBlocks:@[ [self _cellBlock] ]];
    return ps;
}

#pragma mark Tables

static id
color_at(NSArray *colors, NSArray *expanded, int i);

/* The block for the cell being read: one per cell, made from the row's definition. */
- (NSTextTableBlock *)_cellBlock
{
    if (!_table) {
        _table = [[NSTextTable alloc] init];
        _row = _column = 0;
        [_cellBlocks removeAllObjects];
    }
    /* the table's borders are spread over its rows (the top in the first, the bottom in the last) */
    for (int e = 0; e < 4; e++) {
        if (_tableBorder[e] > 0) {
            [_table setWidth:_tableBorder[e] / 20.0 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder
                        edge:(NSRectEdge)e];
            id c = color_at(_colors, _expandedColors, _tableBorderColor[e]);
            if (c)
                [_table setBorderColor:c forEdge:(NSRectEdge)e];
        }
    }
    [_table setNumberOfColumns:MAX([_table numberOfColumns], (NSUInteger)MAX(_cellCount, _column + 1))];
    NSString *key = [NSString stringWithFormat:@"%d,%d", _row, _column];
    NSTextTableBlock *b = _cellBlocks[key];
    if (b)
        return b;
    b = [[[NSTextTableBlock alloc] initWithTable:_table startingRow:_row rowSpan:1 startingColumn:_column columnSpan:1]
        autorelease];
    if (_column < _cellCount) {
        CellDef *d = &_cells[_column];
        for (int e = 0; e < 4; e++) {
            [b setWidth:d->pad[e] / 20.0 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:(NSRectEdge)e];
            if (d->border[e] > 0) {
                [b setWidth:d->border[e] / 20.0 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder
                       edge:(NSRectEdge)e];
                id c = color_at(_colors, _expandedColors, d->borderColor[e]);
                if (c)
                    [b setBorderColor:c forEdge:(NSRectEdge)e];
            }
        }
        [b setVerticalAlignment:d->valign];
        id bg = d->background ? color_at(_colors, _expandedColors, d->background) : nil;
        if (bg)
            [b setBackgroundColor:bg];
    }
    _cellBlocks[key] = b;
    return b;
}

/* Words of a row's definition and its cells; YES if the word was one. */
- (BOOL)_tableWord:(const char *)w param:(int)param
{
    static const char *edges[4] = {"l", "t", "r", "b"};
    if (is_word(w, "trowd")) {
        _cellCount = 0;
        memset(&_cell, 0, sizeof _cell);
        memset(_tableBorder, 0, sizeof _tableBorder);
        memset(_tableBorderColor, 0, sizeof _tableBorderColor);
        _borderWidth = _borderColor = NULL;
        return YES;
    }
    for (int e = 0; e < 4; e++) {
        char name[16];
        snprintf(name, sizeof name, "trbrdr%s", edges[e]);
        if (is_word(w, name)) {
            _borderWidth = &_tableBorder[e == 0 ? NSMinXEdge : e == 1 ? NSMinYEdge : e == 2 ? NSMaxXEdge : NSMaxYEdge];
            _borderColor = &_tableBorderColor[e == 0 ? NSMinXEdge : e == 1 ? NSMinYEdge : e == 2 ? NSMaxXEdge : NSMaxYEdge];
            return YES;
        }
        snprintf(name, sizeof name, "clbrdr%s", edges[e]);
        if (is_word(w, name)) {
            int edge = e == 0 ? NSMinXEdge : e == 1 ? NSMinYEdge : e == 2 ? NSMaxXEdge : NSMaxYEdge;
            _borderWidth = &_cell.border[edge];
            _borderColor = &_cell.borderColor[edge];
            return YES;
        }
        snprintf(name, sizeof name, "clpad%s", edges[e]);
        if (is_word(w, name)) {
            _cell.pad[e == 0 ? NSMinXEdge : e == 1 ? NSMinYEdge : e == 2 ? NSMaxXEdge : NSMaxYEdge] = param;
            return YES;
        }
    }
    if (is_word(w, "brdrw")) {
        if (_borderWidth)
            *_borderWidth = param;
        return YES;
    }
    if (is_word(w, "brdrcf")) {
        if (_borderColor)
            *_borderColor = param;
        return YES;
    }
    if (is_word(w, "brdrnil") || is_word(w, "brdrnone")) {
        if (_borderWidth)
            *_borderWidth = 0;
        return YES;
    }
    if (is_word(w, "brdrs") || is_word(w, "brdrth") || is_word(w, "brdrdb") || is_word(w, "brdrdot") ||
        is_word(w, "brdrdash")) {
        if (_borderWidth && !*_borderWidth)
            *_borderWidth = 15; /* a single line until \brdrw says */
        return YES;
    }
    if (is_word(w, "clvertalt")) { _cell.valign = NSTextBlockTopAlignment; return YES; }
    if (is_word(w, "clvertalc")) { _cell.valign = NSTextBlockMiddleAlignment; return YES; }
    if (is_word(w, "clvertalb")) { _cell.valign = NSTextBlockBottomAlignment; return YES; }
    if (is_word(w, "clcbpat")) { _cell.background = param; return YES; }
    if (is_word(w, "clshdrawnil")) { _cell.background = 0; return YES; } /* no shading: no background */
    if (is_word(w, "cellx")) {
        _cell.right = param;
        if (_cellCount < 64)
            _cells[_cellCount++] = _cell;
        memset(&_cell, 0, sizeof _cell);
        _borderWidth = _borderColor = NULL;
        return YES;
    }
    if (is_word(w, "intbl")) { _s.p.intbl = YES; _s.p.specified = YES; return YES; }
    if (is_word(w, "cell")) {
        [self _emitCharacter:'\n'];
        _column++;
        return YES;
    }
    if (is_word(w, "row")) {
        _row++;
        _column = 0;
        return YES;
    }
    if (is_word(w, "itap") || is_word(w, "lastrow") || is_word(w, "taflags") || is_word(w, "trgaph") ||
        is_word(w, "trleft") || is_word(w, "gaph") || is_word(w, "trql") ||
        is_word(w, "trqc") || is_word(w, "trqr") || is_word(w, "clpadft") || is_word(w, "clpadfl") ||
        is_word(w, "clpadfb") || is_word(w, "clpadfr") || is_word(w, "nestcell") || is_word(w, "nestrow"))
        return YES;
    return NO;
}

- (NSDictionary *)_attributes
{
    CharState *c = &_s.c;
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[NSFontAttributeName] = [self _font];
    if (_s.p.specified)
        a[NSParagraphStyleAttributeName] = [self _paragraphStyle];
    id fg = color_at(_colors, _expandedColors, c->fg);
    if (fg)
        a[NSForegroundColorAttributeName] = fg;
    id bg = color_at(_colors, _expandedColors, c->bg);
    if (bg)
        a[NSBackgroundColorAttributeName] = bg;
    if (c->underline)
        a[NSUnderlineStyleAttributeName] = @(c->underline);
    if (c->strike)
        a[NSStrikethroughStyleAttributeName] = @1;
    if (c->superscript)
        a[NSSuperscriptAttributeName] = @(c->superscript);
    if (c->baselineHalf)
        a[NSBaselineOffsetAttributeName] = @(c->baselineHalf / 2.0);
    if (c->expandTwips)
        a[NSKernAttributeName] = @(c->expandTwips / 20.0);
    if (c->outline)
        a[NSStrokeWidthAttributeName] = @3;
    if (c->shadow) {
        NSShadow *sh = [[[NSShadow alloc] init] autorelease];
        [sh setShadowOffset:NSMakeSize(1, -1)];
        a[NSShadowAttributeName] = sh;
    }
    if (_link && _s.dest == DestFieldResult)
        a[NSLinkAttributeName] = [NSURL URLWithString:_link] ?: _link;
    return a;
}

- (void)_flush
{
    if (![_pending length])
        return;
    NSAttributedString *s = [[NSAttributedString alloc] initWithString:_pending attributes:_pendingAttrs];
    [_out appendAttributedString:s];
    [s release];
    [_pending setString:@""];
}

/* Text goes out in runs: a run ends where the attributes change. */
- (void)_emit:(NSString *)text
{
    if (![text length])
        return;
    if (_s.dest == DestFontTable || _s.dest == DestInfoItem || _s.dest == DestFieldInstruction) {
        [(_s.dest == DestFieldInstruction ? _field : _text) appendString:text];
        return;
    }
    if (_s.dest != DestText && _s.dest != DestFieldResult && _s.dest != DestListText)
        return;
    if (_table && !_s.p.intbl) {
        [_table release];
        _table = nil;
    }
    NSDictionary *a = [self _attributes];
    if (!_pendingAttrs || ![a isEqualToDictionary:_pendingAttrs]) {
        [self _flush];
        [_pendingAttrs release];
        _pendingAttrs = [a copy];
    }
    [_pending appendString:text];
}

- (void)_emitCharacter:(unichar)ch
{
    [self _emit:[NSString stringWithCharacters:&ch length:1]];
}

#pragma mark Control words

static BOOL
is_word(const char *w, const char *name)
{
    return !strcmp(w, name);
}

- (void)_endTableEntry
{
    {
        NSString *name = [_text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([name hasSuffix:@";"])
            name = [name substringToIndex:[name length] - 1];
        if ([name length] && _fontNumber >= 0)
            _fonts[@(_fontNumber)] = name;
        [_text setString:@""];
    }
}

- (void)_word:(const char *)w param:(int)param has:(BOOL)has
{
    CharState *c = &_s.c;
    ParaState *p = &_s.p;
    int v = has ? param : 1;
    /* destinations */
    if (is_word(w, "fonttbl")) { _s.dest = DestFontTable; _fontNumber = -1; return; }
    if (is_word(w, "colortbl")) { _s.dest = DestColorTable; _colorHasValue = NO; _red = _green = _blue = 0; return; }
    if (is_word(w, "expandedcolortbl")) { _s.dest = DestExpandedColors; return; }
    if (is_word(w, "info")) { _s.dest = DestInfo; return; }
    if (_s.dest == DestInfo) {
        static NSDictionary *keys;
        if (!keys)
            keys = [@{@"title" : NSTitleDocumentAttribute, @"author" : NSAuthorDocumentAttribute,
                      @"subject" : NSSubjectDocumentAttribute, @"keywords" : NSKeywordsDocumentAttribute,
                      @"doccomm" : NSCommentDocumentAttribute, @"company" : NSCompanyDocumentAttribute,
                      @"copyright" : NSCopyrightDocumentAttribute, @"editor" : NSEditorDocumentAttribute} retain];
        NSString *k = keys[@(w)];
        if (k) {
            _s.dest = DestInfoItem;
            _s.infoKey = k;
            [_text setString:@""];
            return;
        }
        _s.dest = DestSkip;
        return;
    }
    if (is_word(w, "stylesheet") || is_word(w, "header") || is_word(w, "footer") || is_word(w, "pict") ||
        is_word(w, "listtable") || is_word(w, "listoverridetable") || is_word(w, "generator") ||
        is_word(w, "headerl") || is_word(w, "headerr") || is_word(w, "footerl") || is_word(w, "footerr") ||
        is_word(w, "footnote") || is_word(w, "object") || is_word(w, "xmlnstbl") || is_word(w, "themedata") ||
        is_word(w, "latentstyles") || is_word(w, "rsidtbl") || is_word(w, "datastore") || is_word(w, "colorschememapping")) {
        _s.dest = DestSkip;
        return;
    }
    if (is_word(w, "fldinst")) {
        _s.dest = DestFieldInstruction;
        [_field release];
        _field = [[NSMutableString alloc] init];
        return;
    }
    if (is_word(w, "fldrslt")) {
        [_link release];
        _link = nil;
        NSRange r = [_field rangeOfString:@"HYPERLINK"];
        if (r.location != NSNotFound) {
            NSString *rest = [_field substringFromIndex:NSMaxRange(r)];
            NSRange q1 = [rest rangeOfString:@"\""];
            if (q1.location != NSNotFound) {
                NSRange q2 = [rest rangeOfString:@"\"" options:0
                                           range:NSMakeRange(NSMaxRange(q1), [rest length] - NSMaxRange(q1))];
                if (q2.location != NSNotFound)
                    _link = [[rest substringWithRange:NSMakeRange(NSMaxRange(q1), q2.location - NSMaxRange(q1))] copy];
            }
        }
        _s.dest = DestFieldResult;
        return;
    }
    if (is_word(w, "NeXTGraphic")) {
        _s.dest = DestAttachment;
        [_text setString:@""];
        return;
    }
    if (is_word(w, "listtext")) {
        _s.dest = DestListText;
        return;
    }
    /* font table entries */
    if (_s.dest == DestFontTable) {
        if (is_word(w, "f")) {
            [self _endTableEntry];
            _fontNumber = param;
        }
        return;
    }
    if (_s.dest == DestColorTable) {
        if (is_word(w, "red")) { _red = param; _colorHasValue = YES; }
        else if (is_word(w, "green")) { _green = param; _colorHasValue = YES; }
        else if (is_word(w, "blue")) { _blue = param; _colorHasValue = YES; }
        return;
    }
    if (_s.dest == DestExpandedColors) {
        /* \cssrgb\cR\cG\cB (sRGB, hundred-thousandths), \csgray\cW, \cgenericrgb, \cname... */
        if (is_word(w, "cssrgb") || is_word(w, "csgray") || is_word(w, "cgenericrgb") || is_word(w, "csgenericrgb") ||
            is_word(w, "cname") || is_word(w, "cspthree")) {
            [_text setString:@(w)];
            _red = _green = _blue = -1;
        } else if (is_word(w, "c")) {
            if (_red < 0) _red = param;
            else if (_green < 0) _green = param;
            else if (_blue < 0) _blue = param;
        }
        return;
    }
    /* document */
    if (is_word(w, "ansicpg")) {
        CFStringEncoding e = CFStringConvertWindowsCodepageToEncoding((UInt32)param);
        if (e != kCFStringEncodingInvalidId)
            _encoding = CFStringConvertEncodingToNSStringEncoding(e);
        return;
    }
    if (is_word(w, "mac")) { _encoding = NSMacOSRomanStringEncoding; return; }
    if (is_word(w, "paperw")) { [self _setPaperWidth:param]; return; }
    if (is_word(w, "paperh")) { [self _setPaperHeight:param]; return; }
    if (is_word(w, "margl")) { _doc[NSLeftMarginDocumentAttribute] = @(param / 20.0); return; }
    if (is_word(w, "margr")) { _doc[NSRightMarginDocumentAttribute] = @(param / 20.0); return; }
    if (is_word(w, "margt")) { _doc[NSTopMarginDocumentAttribute] = @(param / 20.0); return; }
    if (is_word(w, "margb")) { _doc[NSBottomMarginDocumentAttribute] = @(param / 20.0); return; }
    if (is_word(w, "vieww") || is_word(w, "viewh")) {
        NSSize sz = [_doc[NSViewSizeDocumentAttribute] sizeValue];
        if (is_word(w, "vieww")) sz.width = param / 20.0;
        else sz.height = param / 20.0;
        _doc[NSViewSizeDocumentAttribute] = [NSValue valueWithSize:sz];
        return;
    }
    if (is_word(w, "viewkind")) { _doc[NSViewModeDocumentAttribute] = @(param); return; }
    if (is_word(w, "viewscale")) { _doc[NSViewZoomDocumentAttribute] = @(param); return; }
    if (is_word(w, "readonlydoc")) { _doc[NSReadOnlyDocumentAttribute] = @(param); return; }
    if (is_word(w, "hyphfactor")) { _doc[NSHyphenationFactorDocumentAttribute] = @(param / 100.0); return; }
    if (is_word(w, "deftab")) { _doc[NSDefaultTabIntervalDocumentAttribute] = @(param / 20.0); return; }
    if (is_word(w, "cocoatextscaling")) { _doc[NSTextScalingDocumentAttribute] = @(param); return; }
    if (is_word(w, "cocoaplatform")) return;
    if (is_word(w, "cocoartf")) { _doc[@"CocoaRTFVersion"] = @(param); return; }
    /* special characters */
    if (is_word(w, "par") || is_word(w, "sect")) { [self _emitCharacter:'\n']; return; }
    if (is_word(w, "line")) { [self _emitCharacter:0x2028]; return; }
    if (is_word(w, "page")) { [self _emitCharacter:'\f']; return; }
    if (is_word(w, "tab")) { [self _emitCharacter:'\t']; return; }
    if (is_word(w, "emdash")) { [self _emitCharacter:0x2014]; return; }
    if (is_word(w, "endash")) { [self _emitCharacter:0x2013]; return; }
    if (is_word(w, "bullet")) { [self _emitCharacter:0x2022]; return; }
    if (is_word(w, "lquote")) { [self _emitCharacter:0x2018]; return; }
    if (is_word(w, "rquote")) { [self _emitCharacter:0x2019]; return; }
    if (is_word(w, "ldblquote")) { [self _emitCharacter:0x201C]; return; }
    if (is_word(w, "rdblquote")) { [self _emitCharacter:0x201D]; return; }
    if (is_word(w, "uc")) { c->uc = param; return; }
    if (is_word(w, "u")) {
        int u = param < 0 ? param + 65536 : param;
        [self _emitCharacter:(unichar)u];
        _skipChars = c->uc;
        return;
    }
    /* character formatting */
    if (is_word(w, "plain")) {
        int uc = c->uc;
        [self _resetChar:c];
        c->uc = uc;
        return;
    }
    if (is_word(w, "f")) { c->font = param; return; }
    if (is_word(w, "fs")) { c->halfPoints = param > 0 ? param : 24; return; }
    if (is_word(w, "b")) { c->bold = v != 0; return; }
    if (is_word(w, "i")) { c->italic = v != 0; return; }
    if (is_word(w, "ul")) { c->underline = v ? NSUnderlineStyleSingle : 0; return; }
    if (is_word(w, "uld")) { c->underline = NSUnderlineStyleSingle | NSUnderlinePatternDot; return; }
    if (is_word(w, "uldb")) { c->underline = NSUnderlineStyleDouble; return; }
    if (is_word(w, "ulth")) { c->underline = NSUnderlineStyleThick; return; }
    if (is_word(w, "ulw")) { c->underline = NSUnderlineStyleSingle | NSUnderlineByWord; return; }
    if (is_word(w, "ulnone")) { c->underline = 0; return; }
    if (is_word(w, "strike")) { c->strike = v != 0; return; }
    if (is_word(w, "striked")) { c->strike = v != 0; return; }
    if (is_word(w, "outl")) { c->outline = v != 0; return; }
    if (is_word(w, "shad")) { c->shadow = v != 0; return; }
    if (is_word(w, "cf")) { c->fg = param; return; }
    /* Apple's writer ends a background with \cb1, the table's white */
    if (is_word(w, "cb") || is_word(w, "highlight") || is_word(w, "chcbpat")) { c->bg = param == 1 ? 0 : param; return; }
    if (is_word(w, "super")) { c->superscript = 1; return; }
    if (is_word(w, "sub")) { c->superscript = -1; return; }
    if (is_word(w, "nosupersub")) { c->superscript = 0; return; }
    if (is_word(w, "up")) { c->baselineHalf = has ? param : 6; return; }
    if (is_word(w, "dn")) { c->baselineHalf = -(has ? param : 6); return; }
    if (is_word(w, "expndtw")) { c->expandTwips = param; return; }
    if (is_word(w, "expnd")) { c->expandTwips = param * 5; return; } /* quarter points */
    if (is_word(w, "kerning")) { c->kerning = v != 0; return; }
    if (_s.dest == DestText && [self _tableWord:w param:param])
        return;
    /* paragraph formatting */
    if (is_word(w, "pard")) { [self _resetPara:p]; p->specified = YES; return; }
    static const char *paragraphWords[] = {"ql", "qr", "qc", "qj", "qnatural", "li", "ri", "fi", "sb", "sa", "sl",
                                           "slmult", "slleading", "rtlpar", "ltrpar", "tx", "tqr", "tqc", "tqdec"};
    for (size_t k = 0; k < sizeof paragraphWords / sizeof paragraphWords[0]; k++)
        if (is_word(w, paragraphWords[k]))
            p->specified = YES;
    if (is_word(w, "ql")) { p->alignment = NSTextAlignmentLeft; return; }
    if (is_word(w, "qr")) { p->alignment = NSTextAlignmentRight; return; }
    if (is_word(w, "qc")) { p->alignment = NSTextAlignmentCenter; return; }
    if (is_word(w, "qj")) { p->alignment = NSTextAlignmentJustified; return; }
    if (is_word(w, "qnatural")) { p->alignment = NSTextAlignmentNatural; return; }
    if (is_word(w, "pardirnatural")) { p->direction = NSWritingDirectionNatural; return; }
    if (is_word(w, "li")) { p->li = param; return; }
    if (is_word(w, "ri")) { p->ri = param; return; }
    if (is_word(w, "fi")) { p->fi = param; return; }
    if (is_word(w, "sb")) { p->sb = param; return; }
    if (is_word(w, "sa")) { p->sa = param; return; }
    if (is_word(w, "sl")) { p->sl = param; return; }
    if (is_word(w, "slmult")) { p->slmult = param != 0; return; }
    if (is_word(w, "slleading")) { p->slleading = param; return; }
    if (is_word(w, "rtlpar")) { p->direction = NSWritingDirectionRightToLeft; return; }
    if (is_word(w, "ltrpar")) { p->direction = NSWritingDirectionLeftToRight; return; }
    if (is_word(w, "tqr")) { p->pendingTab = NSTextAlignmentRight; return; }
    if (is_word(w, "tqc")) { p->pendingTab = NSTextAlignmentCenter; return; }
    if (is_word(w, "tqdec")) { p->pendingTab = NSTextAlignmentRight; return; }
    if (is_word(w, "tx")) {
        if (p->tabCount < 64) {
            p->tabs[p->tabCount] = param;
            p->tabAlign[p->tabCount++] = p->pendingTab;
        }
        p->pendingTab = NSTextAlignmentLeft;
        return;
    }
    /* attachments (RTFD): \width and \height of the \NeXTGraphic group */
}

- (void)_setPaperWidth:(int)twips
{
    NSSize s = [_doc[NSPaperSizeDocumentAttribute] sizeValue];
    s.width = twips / 20.0;
    _doc[NSPaperSizeDocumentAttribute] = [NSValue valueWithSize:s];
}

- (void)_setPaperHeight:(int)twips
{
    NSSize s = [_doc[NSPaperSizeDocumentAttribute] sizeValue];
    s.height = twips / 20.0;
    _doc[NSPaperSizeDocumentAttribute] = [NSValue valueWithSize:s];
}

/* A group ends: table entries and info items are complete, and an attachment group places its character. */
- (void)_endGroup:(RTFState *)ending
{
    if (ending->dest == DestInfoItem && ending->infoKey) {
        _doc[ending->infoKey] = [[_text copy] autorelease];
        [_text setString:@""];
    }
    if (ending->dest == DestFontTable && _s.dest != DestFontTable)
        [self _endTableEntry];
    if (ending->dest == DestAttachment && _s.dest != DestAttachment) {
        NSString *name = [[_text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            copy];
        NSFileWrapper *w = name ? _attachments[name] : nil;
        Class attachmentClass = [NSTextAttachment class];
        NSTextAttachment *a = [[attachmentClass alloc] initWithFileWrapper:w];
        [self _flush];
        NSDictionary *attrs = [self _attributes];
        NSMutableDictionary *m = [[attrs mutableCopy] autorelease];
        m[NSAttachmentAttributeName] = a;
        unichar ch = NSAttachmentCharacter;
        NSAttributedString *s = [[NSAttributedString alloc] initWithString:[NSString stringWithCharacters:&ch length:1]
                                                                attributes:m];
        [_out appendAttributedString:s];
        [s release];
        [a release];
        [name release];
        [_text setString:@""];
        _skipChars = 1; /* the attachment character Apple writes after the group */
    }
    if (ending->dest == DestFieldResult && _s.dest != DestFieldResult) {
        [self _flush];
        [_pendingAttrs release];
        _pendingAttrs = nil;
        [_link release];
        _link = nil;
    }
}

- (void)_colorEntryEnd
{
    if (_s.dest == DestColorTable) {
        [_colors addObject:_colorHasValue ? (generic_color(_red / 255.0, _green / 255.0, _blue / 255.0) ?: [NSNull null])
                                          : [NSNull null]];
        _colorHasValue = NO;
        _red = _green = _blue = 0;
    } else if (_s.dest == DestExpandedColors) {
        id color = [NSNull null];
        if ([_text isEqualToString:@"cssrgb"] && _blue >= 0)
            color = srgb_color(_red / 100000.0, _green / 100000.0, _blue / 100000.0, 1) ?: color;
        else if ([_text isEqualToString:@"csgray"] && _red >= 0)
            color = srgb_color(_red / 100000.0, _red / 100000.0, _red / 100000.0, 1) ?: color;
        else if ([_text isEqualToString:@"cgenericrgb"] && _blue >= 0)
            color = generic_color(_red / 100000.0, _green / 100000.0, _blue / 100000.0) ?: color;
        [_expandedColors addObject:color];
        [_text setString:@""];
        _red = _green = _blue = -1;
    }
}

#pragma mark The scanner

- (BOOL)parse
{
    if (_n < 5 || memcmp(_b, "{\\rtf", 5))
        return NO;
    _depth = 0;
    while (_i < _n) {
        uint8_t ch = _b[_i++];
        if (ch == '{') {
            if (_depth < 255)
                _stack[_depth++] = _s;
            continue;
        }
        if (ch == '}') {
            if (_depth == 0)
                break;
            RTFState ending = _s;
            _s = _stack[--_depth];
            [self _endGroup:&ending];
            continue;
        }
        if (ch == '\\') {
            if (_i >= _n)
                break;
            uint8_t c2 = _b[_i];
            if (isalpha(c2)) {
                char word[64];
                size_t k = 0;
                while (_i < _n && isalpha(_b[_i]) && k < sizeof word - 1)
                    word[k++] = (char)_b[_i++];
                word[k] = 0;
                BOOL has = NO, neg = NO;
                int param = 0;
                if (_i < _n && _b[_i] == '-') {
                    neg = YES;
                    _i++;
                }
                while (_i < _n && isdigit(_b[_i])) {
                    has = YES;
                    param = param * 10 + (_b[_i++] - '0');
                }
                if (neg)
                    param = -param;
                if (_i < _n && _b[_i] == ' ')
                    _i++;
                if (_skipChars > 0 && !is_word(word, "u")) {
                    /* a control word counts as one fallback character */
                    _skipChars--;
                    continue;
                }
                [self _word:word param:param has:has];
                continue;
            }
            _i++;
            switch (c2) {
            case '\\':
            case '{':
            case '}':
                if (_skipChars > 0) {
                    _skipChars--;
                    break;
                }
                [self _emitCharacter:c2];
                break;
            case '\'': {
                if (_i + 2 > _n)
                    break;
                char hex[3] = {(char)_b[_i], (char)_b[_i + 1], 0};
                _i += 2;
                if (_skipChars > 0) {
                    _skipChars--;
                    break;
                }
                uint8_t byte = (uint8_t)strtol(hex, NULL, 16);
                NSString *s = [[NSString alloc] initWithBytes:&byte length:1 encoding:_encoding];
                [self _emit:s];
                [s release];
                break;
            }
            case '*':
                /* an ignorable destination: skipped unless it's one we know */
                if (_i < _n && _b[_i] == '\\') {
                    size_t save = _i + 1, k = 0;
                    char word[64];
                    while (save < _n && isalpha(_b[save]) && k < sizeof word - 1)
                        word[k++] = (char)_b[save++];
                    word[k] = 0;
                    if (!is_word(word, "expandedcolortbl") && !is_word(word, "fldinst"))
                        _s.dest = DestSkip;
                }
                break;
            case '\n':
            case '\r':
                [self _emitCharacter:'\n'];
                break;
            case '~':
                [self _emitCharacter:0x00A0];
                break;
            case '-':
                [self _emitCharacter:0x00AD];
                break;
            case '_':
                [self _emitCharacter:0x2011];
                break;
            case '\t':
                [self _emitCharacter:'\t'];
                break;
            default:
                break;
            }
            continue;
        }
        if (ch == '\r' || ch == '\n')
            continue;
        if (ch == ';' && (_s.dest == DestColorTable || _s.dest == DestExpandedColors)) {
            [self _colorEntryEnd];
            continue;
        }
        if (_skipChars > 0) {
            _skipChars--;
            continue;
        }
        if (_s.dest == DestSkip || _s.dest == DestColorTable || _s.dest == DestExpandedColors || _s.dest == DestInfo)
            continue;
        if (_s.dest == DestAttachment) {
            [_text appendFormat:@"%c", ch];
            continue;
        }
        /* a run of plain bytes, in the document's encoding (UTF-8 is accepted as Apple's reader does) */
        size_t start = _i - 1;
        while (_i < _n && _b[_i] != '\\' && _b[_i] != '{' && _b[_i] != '}' && _b[_i] != '\r' && _b[_i] != '\n' &&
               !(_b[_i] == ';' && 0))
            _i++;
        NSString *s = [[NSString alloc] initWithBytes:_b + start length:_i - start encoding:_encoding];
        if (!s)
            s = [[NSString alloc] initWithBytes:_b + start length:_i - start encoding:NSISOLatin1StringEncoding];
        [self _emit:s];
        [s release];
    }
    [self _flush];
    return YES;
}

@end

#pragma mark - Writing RTF

typedef struct {
    NSMutableString *out;
    NSMutableArray<NSString *> *fontNames;
    NSMutableArray *colors;        /* NSColor, in table order (index + 2: 0 is auto, 1 white) */
    NSStringEncoding encoding;
} RTFWriter;

/* The name a document should use for a font: Apple's, for the fonts Finch ships in their place. */
static NSString *
document_font_name(NSFont *font)
{
    if (!font)
        return @"Helvetica";
    if (UIFSystemFontDescriptor(font)) {
        BOOL bold = (CTFontGetSymbolicTraits((CTFontRef)font) & kCTFontTraitBold) != 0;
        return bold ? @"HelveticaNeue-Bold" : @"HelveticaNeue";
    }
    NSString *name = [font fontName];
    return UIFAppleFontName(name) ?: name;
}

/* \fswiss, \froman, \fmodern or \fnil, as Apple's writer classifies families. */
static NSString *
font_family_class(NSString *name)
{
    static NSDictionary *classes;
    if (!classes)
        classes = [@{@"Helvetica" : @"fswiss", @"Arial" : @"fswiss", @"Times" : @"froman", @"Times New Roman" : @"froman",
                     @"Georgia" : @"froman", @"Palatino" : @"froman", @"Courier" : @"fmodern",
                     @"Courier New" : @"fmodern", @"Charter" : @"froman"} retain];
    NSString *family = [[name componentsSeparatedByString:@"-"] firstObject];
    if ([family isEqualToString:@"TimesNewRomanPSMT"] || [family isEqualToString:@"TimesNewRomanPS"])
        family = @"Times New Roman";
    if ([family isEqualToString:@"ArialMT"])
        family = @"Arial";
    return classes[family] ?: @"fnil";
}

static NSUInteger
font_index(RTFWriter *w, NSString *name)
{
    NSUInteger i = [w->fontNames indexOfObject:name];
    if (i == NSNotFound) {
        [w->fontNames addObject:name];
        i = [w->fontNames count] - 1;
    }
    return i;
}

/* sRGB components of a colour (NSColor or CGColor), 0...1. */
static BOOL
components_in(id color, CFStringRef spaceName, CGFloat rgba[4])
{
    CGColorRef cg = UIFCGColor(color);
    if (!cg)
        return NO;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(spaceName);
    CGColorRef c = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, cg, NULL);
    CGColorSpaceRelease(srgb);
    if (!c)
        return NO;
    const CGFloat *comp = CGColorGetComponents(c);
    size_t n = CGColorGetNumberOfComponents(c);
    rgba[0] = comp[0];
    rgba[1] = n > 2 ? comp[1] : comp[0];
    rgba[2] = n > 2 ? comp[2] : comp[0];
    rgba[3] = comp[n - 1];
    CGColorRelease(c);
    return YES;
}

static BOOL
srgb_components(id color, CGFloat rgba[4])
{
    return components_in(color, kCGColorSpaceSRGB, rgba);
}

/* \colortbl's values are Generic RGB, as Apple's writer gives them (\expandedcolortbl has the sRGB ones). */
static BOOL
generic_components(id color, CGFloat rgba[4])
{
    return components_in(color, kCGColorSpaceGenericRGB, rgba);
}

static NSUInteger
color_index(RTFWriter *w, id color)
{
    CGFloat c[4];
    if (!color || !srgb_components(color, c))
        return 0;
    for (NSUInteger i = 0; i < [w->colors count]; i++) {
        CGFloat d[4];
        srgb_components(w->colors[i], d);
        if (fabs(c[0] - d[0]) < 1e-5 && fabs(c[1] - d[1]) < 1e-5 && fabs(c[2] - d[2]) < 1e-5)
            return i + 2;
    }
    [w->colors addObject:color];
    return [w->colors count] + 1;
}

static void
append_text(RTFWriter *w, NSString *s, BOOL *ucWritten)
{
    NSUInteger n = [s length];
    unichar *buf = malloc(n * sizeof(unichar) + 1);
    [s getCharacters:buf range:NSMakeRange(0, n)];
    for (NSUInteger i = 0; i < n; i++) {
        unichar ch = buf[i];
        if (ch == '\\' || ch == '{' || ch == '}')
            [w->out appendFormat:@"\\%C", ch];
        else if (ch == '\n' || ch == 0x2029)
            [w->out appendString:@"\\\n"];
        else if (ch == '\f')
            [w->out appendString:@"\\page "];
        else if (ch == '\t' || (ch >= 0x20 && ch < 0x7f))
            [w->out appendFormat:@"%C", ch];
        else if (ch == NSAttachmentCharacter)
            ;
        else {
            /* the document's code page when it has the character, else \u */
            NSString *one = [NSString stringWithCharacters:&ch length:1];
            NSData *d = ch < 0xD800 || ch > 0xDFFF ? [one dataUsingEncoding:w->encoding allowLossyConversion:NO] : nil;
            if (d && [d length] == 1) {
                [w->out appendFormat:@"\\'%02x", ((const uint8_t *)[d bytes])[0]];
            } else {
                if (!*ucWritten) {
                    [w->out appendString:@"\\uc0"];
                    *ucWritten = YES;
                }
                [w->out appendFormat:@"\\u%u ", (unsigned)ch];
            }
        }
    }
    free(buf);
}

static NSString *
paragraph_rtf(NSParagraphStyle *ps, BOOL inTable)
{
    NSMutableString *s = [NSMutableString stringWithString:inTable ? @"\\pard\\intbl\\itap1" : @"\\pard"];
    if (!ps)
        ps = [NSParagraphStyle defaultParagraphStyle];
    int li = (int)lround([ps headIndent] * 20), fi = (int)lround(([ps firstLineHeadIndent] - [ps headIndent]) * 20);
    if (li)
        [s appendFormat:@"\\li%d", li];
    if (fi)
        [s appendFormat:@"\\fi%d", fi];
    if ([ps tailIndent] < 0)
        [s appendFormat:@"\\ri%d", (int)lround(-[ps tailIndent] * 20)];
    else if ([ps tailIndent] > 0)
        [s appendFormat:@"\\ri%d", (int)lround((432 - [ps tailIndent]) * 20)];
    for (NSTextTab *t in [ps tabStops]) {
        NSTextAlignment a = [t alignment];
        if (a == NSTextAlignmentRight)
            [s appendString:@"\\tqr"];
        else if (a == NSTextAlignmentCenter)
            [s appendString:@"\\tqc"];
        [s appendFormat:@"\\tx%d", (int)lround([t location] * 20)];
    }
    if ([ps lineHeightMultiple] > 0)
        [s appendFormat:@"\\sl%d\\slmult1", (int)lround([ps lineHeightMultiple] * 240)];
    else if ([ps minimumLineHeight] > 0 && [ps minimumLineHeight] == [ps maximumLineHeight])
        [s appendFormat:@"\\sl-%d", (int)lround([ps minimumLineHeight] * 20)];
    else if ([ps minimumLineHeight] > 0)
        [s appendFormat:@"\\sl%d", (int)lround([ps minimumLineHeight] * 20)];
    if ([ps lineSpacing] > 0)
        [s appendFormat:@"\\slleading%d", (int)lround([ps lineSpacing] * 20)];
    if ([ps paragraphSpacingBefore] > 0)
        [s appendFormat:@"\\sb%d", (int)lround([ps paragraphSpacingBefore] * 20)];
    if ([ps paragraphSpacing] > 0)
        [s appendFormat:@"\\sa%d", (int)lround([ps paragraphSpacing] * 20)];
    [s appendString:@"\\pardirnatural"];
    switch ([ps alignment]) {
    case NSTextAlignmentLeft: [s appendString:@"\\ql"]; break;
    case NSTextAlignmentRight: [s appendString:@"\\qr"]; break;
    case NSTextAlignmentCenter: [s appendString:@"\\qc"]; break;
    case NSTextAlignmentJustified: [s appendString:@"\\qj"]; break;
    default: break;
    }
    [s appendString:@"\\partightenfactor0\n"];
    return s;
}

/* The table cell a paragraph is in, if any. */
static NSTextTableBlock *
table_block(NSParagraphStyle *ps)
{
    for (NSTextBlock *b in [ps textBlocks])
        if ([b isKindOfClass:[NSTextTableBlock class]])
            return (NSTextTableBlock *)b;
    return nil;
}

static NSString *
border_rtf(const char *prefix, const char *edge, NSTextBlock *b, NSRectEdge e, RTFWriter *w, BOOL omitNone)
{
    CGFloat width = [b widthForLayer:NSTextBlockBorder edge:e];
    if (width <= 0)
        return omitNone ? @"" : [NSString stringWithFormat:@"\\%s%s\\brdrnil ", prefix, edge];
    id color = [b borderColorForEdge:e];
    NSString *cf = color ? [NSString stringWithFormat:@"%lu", (unsigned long)color_index(w, color)] : @"nil";
    return [NSString stringWithFormat:@"\\%s%s\\brdrs\\brdrw%d\\brdrcf%@ ", prefix, edge, (int)lround(width * 20), cf];
}

/* A table row's definition, as Apple's writer lays it out: the table's borders (its top on the first
 * row, its bottom on the last), then each cell's alignment, background, borders, padding and edge. */
static NSString *
row_rtf(NSArray<NSTextTableBlock *> *cells, BOOL firstRow, BOOL lastRow, RTFWriter *w)
{
    NSTextTable *t = [cells.firstObject table];
    NSMutableString *s = [NSMutableString stringWithString:@"\n\\itap1\\trowd \\taflags0 \\trgaph108\\trleft-108 "];
    if (firstRow)
        [s appendString:border_rtf("trbrdr", "t", t, NSMinYEdge, w, YES)];
    [s appendString:border_rtf("trbrdr", "l", t, NSMinXEdge, w, YES)];
    if (lastRow)
        [s appendString:border_rtf("trbrdr", "b", t, NSMaxYEdge, w, YES)];
    [s appendString:border_rtf("trbrdr", "r", t, NSMaxXEdge, w, YES)];
    [s appendString:@"\n"];
    NSUInteger cols = MAX([t numberOfColumns], (NSUInteger)1);
    for (NSTextTableBlock *c in cells) {
        NSTextBlockVerticalAlignment v = [c verticalAlignment];
        [s appendString:v == NSTextBlockMiddleAlignment ? @"\\clvertalc " : v == NSTextBlockBottomAlignment ? @"\\clvertalb " : @"\\clvertalt "];
        if ([c backgroundColor])
            [s appendFormat:@"\\clcbpat%lu ", (unsigned long)color_index(w, [c backgroundColor])];
        else
            [s appendString:@"\\clshdrawnil "];
        [s appendString:border_rtf("clbrdr", "t", c, NSMinYEdge, w, NO)];
        [s appendString:border_rtf("clbrdr", "l", c, NSMinXEdge, w, NO)];
        [s appendString:border_rtf("clbrdr", "b", c, NSMaxYEdge, w, NO)];
        [s appendString:border_rtf("clbrdr", "r", c, NSMaxXEdge, w, NO)];
        [s appendFormat:@"\\clpadt%d \\clpadl%d \\clpadb%d \\clpadr%d \\gaph\\cellx%d\n",
                        (int)lround([c widthForLayer:NSTextBlockPadding edge:NSMinYEdge] * 20),
                        (int)lround([c widthForLayer:NSTextBlockPadding edge:NSMinXEdge] * 20),
                        (int)lround([c widthForLayer:NSTextBlockPadding edge:NSMaxYEdge] * 20),
                        (int)lround([c widthForLayer:NSTextBlockPadding edge:NSMaxXEdge] * 20),
                        (int)(8640 * (NSUInteger)MIN([c startingColumn] + MAX([c columnSpan], 1), (NSInteger)cols) / cols)];
    }
    return s;
}

UIF_HIDDEN NSData *
UIFRTFData(NSAttributedString *str, NSRange range, NSDictionary *docAttrs, NSArray<NSString *> **attachmentNames)
{
    RTFWriter w = {[NSMutableString string], [NSMutableArray array], [NSMutableArray array], NSWindowsCP1252StringEncoding};
    NSMutableString *body = [NSMutableString string];
    RTFWriter b = w;
    b.out = body;
    NSMutableArray *names = [NSMutableArray array];

    /* body first: it fills the font and colour tables */
    NSParagraphStyle *lastPara = nil;
    BOOL first = YES, ucWritten = NO;
    NSUInteger lastFont = NSNotFound;
    int lastSize = -1;
    BOOL lastBold = NO, lastItalic = NO;
    NSUInteger lastFg = 0, lastBg = 0;
    NSInteger lastUl = 0, lastStrike = 0, lastSuper = 0;
    double lastBase = 0, lastKern = 0;
    NSUInteger pos = range.location, end = NSMaxRange(range);
    NSString *string = [str string];
    NSTextTable *rowTable = nil;
    NSInteger rowNumber = -1;
    while (pos < end) {
        NSRange pr = [string paragraphRangeForRange:NSMakeRange(pos, 0)];
        NSParagraphStyle *ps = [str attribute:NSParagraphStyleAttributeName atIndex:pos effectiveRange:NULL];
        /* tables: a row's definition before its first paragraph; where each cell and row ends */
        NSTextTableBlock *cell = table_block(ps);
        BOOL cellEnd = NO, rowEnd = NO, lastRow = NO;
        if (cell) {
            if ([cell table] != rowTable || [cell startingRow] != rowNumber) {
                NSMutableArray *cells = [NSMutableArray array];
                NSUInteger q = pos;
                BOOL last = YES;
                while (q < end) {
                    NSTextTableBlock *c = table_block([str attribute:NSParagraphStyleAttributeName atIndex:q effectiveRange:NULL]);
                    if (!c || [c table] != [cell table])
                        break;
                    if ([c startingRow] != [cell startingRow]) {
                        last = NO;
                        break;
                    }
                    if ([cells indexOfObjectIdenticalTo:c] == NSNotFound)
                        [cells addObject:c];
                    q = NSMaxRange([string paragraphRangeForRange:NSMakeRange(q, 0)]);
                }
                [body appendString:row_rtf(cells, [cell table] != rowTable, last, &b)];
                rowTable = [cell table];
                rowNumber = [cell startingRow];
            }
            NSUInteger next = NSMaxRange(pr);
            NSTextTableBlock *following = next < [string length]
                                              ? table_block([str attribute:NSParagraphStyleAttributeName atIndex:next effectiveRange:NULL])
                                              : nil;
            cellEnd = following != cell;
            rowEnd = cellEnd && !(following && [following table] == [cell table] && [following startingRow] == [cell startingRow]);
            lastRow = rowEnd && !(following && [following table] == [cell table]);
        } else {
            rowTable = nil;
            rowNumber = -1;
        }
        if (first || !(ps == lastPara || [ps isEqual:lastPara])) {
            [body appendString:paragraph_rtf(ps, cell != nil)];
            if (first)
                [body appendString:@"\n"];
            else
                [body appendFormat:@"\\cf%lu ", (unsigned long)lastFg];
            lastPara = ps;
        }
        NSUInteger pend = MIN(NSMaxRange(pr), end);
        while (pos < pend) {
            NSRange r;
            NSDictionary *a = [str attributesAtIndex:pos longestEffectiveRange:&r inRange:NSMakeRange(pos, pend - pos)];
            NSFont *font = a[NSFontAttributeName] ?: [NSFont fontWithName:@"Helvetica" size:12];
            NSString *fname = document_font_name(font);
            NSUInteger fi = font_index(&b, fname);
            int size = (int)lround([font pointSize] * 2);
            CTFontSymbolicTraits traits = CTFontGetSymbolicTraits((CTFontRef)font);
            BOOL bold = (traits & kCTFontTraitBold) != 0, italic = (traits & kCTFontTraitItalic) != 0;
            NSMutableString *ctl = [NSMutableString string];
            if (fi != lastFont || size != lastSize || bold != lastBold || italic != lastItalic) {
                if (!first)
                    [ctl appendString:@"\n"];
                if (fi != lastFont)
                    [ctl appendFormat:@"\\f%lu", (unsigned long)fi];
                if (bold != lastBold)
                    [ctl appendString:bold ? @"\\b" : @"\\b0"];
                if (italic != lastItalic)
                    [ctl appendString:italic ? @"\\i" : @"\\i0"];
                if (size != lastSize)
                    [ctl appendFormat:@"\\fs%d", size];
                [ctl appendString:@" "];
                lastFont = fi, lastSize = size, lastBold = bold, lastItalic = italic;
            }
            NSUInteger fg = color_index(&b, a[NSForegroundColorAttributeName]);
            if (first || fg != lastFg) {
                [ctl appendFormat:@"\\cf%lu ", (unsigned long)fg];
                lastFg = fg;
            }
            id bgColor = a[NSBackgroundColorAttributeName];
            NSUInteger bg = bgColor ? color_index(&b, bgColor) : 0;
            if (bg != lastBg) {
                [ctl appendFormat:@"\\cb%lu ", (unsigned long)(bg ? bg : 1)];
                lastBg = bg;
            }
            NSInteger ul = [a[NSUnderlineStyleAttributeName] integerValue];
            if (ul != lastUl) {
                [ctl appendString:ul ? @"\\ul \\ulc0 " : @"\\ulnone "];
                lastUl = ul;
            }
            NSInteger strike = [a[NSStrikethroughStyleAttributeName] integerValue];
            if (strike != lastStrike) {
                [ctl appendString:strike ? @"\\strike \\strikec0 " : @"\\strike0\\striked0 "];
                lastStrike = strike;
            }
            NSInteger sup = [a[NSSuperscriptAttributeName] integerValue];
            if (sup != lastSuper) {
                [ctl appendString:sup > 0 ? @"\\super " : sup < 0 ? @"\\sub " : @"\\nosupersub "];
                lastSuper = sup;
            }
            double base = [a[NSBaselineOffsetAttributeName] doubleValue];
            if (base != lastBase) {
                if (base > 0)
                    [ctl appendFormat:@"\\up%d ", (int)lround(base * 2)];
                else if (base < 0)
                    [ctl appendFormat:@"\\dn%d ", (int)lround(-base * 2)];
                else
                    [ctl appendString:@"\\up0 "];
                lastBase = base;
            }
            double kern = [a[NSKernAttributeName] doubleValue];
            if (kern != lastKern) {
                [ctl appendFormat:@"\\kerning1\\expnd%d\\expndtw%d\n", (int)lround(kern * 4), (int)lround(kern * 20)];
                lastKern = kern;
            }
            [body appendString:ctl];
            first = NO;
            NSString *text = [string substringWithRange:r];
            id link = a[NSLinkAttributeName];
            NSTextAttachment *att = a[NSAttachmentAttributeName];
            if (att) {
                NSFileWrapper *fw = [att fileWrapper];
                NSString *name = [fw preferredFilename] ?: [fw filename] ?: @"Attachment";
                [names addObject:name];
                [body appendFormat:@"{{\\NeXTGraphic %@ \\width%d \\height%d \\appleattachmentpadding0 \\appleembedtype0 "
                                    @"\\appleaqc\n}\xc2\xac}",
                                   name, (int)lround([att bounds].size.width * 20),
                                   (int)lround([att bounds].size.height * 20)];
            } else if (link) {
                NSString *url = [link isKindOfClass:[NSURL class]] ? [link absoluteString] : [link description];
                [body appendFormat:@"{\\field{\\*\\fldinst{HYPERLINK \"%@\"}}{\\fldrslt ", url];
                append_text(&b, text, &ucWritten);
                [body appendString:@"}}"];
            } else {
                /* a cell's last paragraph ends with \cell (and its row's last with \row), not a newline */
                BOOL ends = cellEnd && NSMaxRange(r) == pend && [text length] && [text characterAtIndex:[text length] - 1] == '\n';
                append_text(&b, ends ? [text substringToIndex:[text length] - 1] : text, &ucWritten);
                if (ends)
                    [body appendString:rowEnd ? (lastRow ? @"\\cell \\lastrow\\row\n" : @"\\cell \\row\n") : @"\\cell \n"];
            }
            pos = NSMaxRange(r);
        }
    }

    /* header and tables */
    NSMutableString *out = w.out;
    [out appendString:@"{\\rtf1\\ansi\\ansicpg1252\\cocoartf2869\n"];
    if ([docAttrs[NSReadOnlyDocumentAttribute] integerValue] > 0)
        [out appendString:@"\\readonlydoc1"];
    [out appendFormat:@"\\cocoatextscaling%ld\\cocoaplatform%ld{\\fonttbl",
                      (long)[docAttrs[NSTextScalingDocumentAttribute] integerValue],
                      (long)[docAttrs[NSSourceTextScalingDocumentAttribute] integerValue]];
    for (NSUInteger i = 0; i < [b.fontNames count]; i++) {
        if (i && i % 3 == 0)
            [out appendString:@"\n"];
        [out appendFormat:@"\\f%lu\\%@\\fcharset0 %@;", (unsigned long)i, font_family_class(b.fontNames[i]), b.fontNames[i]];
    }
    if ([b.fontNames count] && [b.fontNames count] % 3 == 0)
        [out appendString:@"\n"];
    [out appendString:@"}\n{\\colortbl;\\red255\\green255\\blue255;"];
    for (id color in b.colors) {
        CGFloat c[4];
        generic_components(color, c);
        [out appendFormat:@"\\red%d\\green%d\\blue%d;", (int)lround(c[0] * 255), (int)lround(c[1] * 255),
                          (int)lround(c[2] * 255)];
    }
    [out appendString:@"}\n{\\*\\expandedcolortbl;;"];
    for (id color in b.colors) {
        CGFloat c[4];
        srgb_components(color, c);
        [out appendFormat:@"\\cssrgb\\c%d\\c%d\\c%d;", (int)lround(c[0] * 100000), (int)lround(c[1] * 100000),
                          (int)lround(c[2] * 100000)];
    }
    [out appendString:@"}\n"];
    static const struct {
        NSString *const *key;
        const char *word;
    } info[] = {{&NSTitleDocumentAttribute, "title"},       {&NSAuthorDocumentAttribute, "author"},
                {&NSSubjectDocumentAttribute, "subject"},   {&NSKeywordsDocumentAttribute, "keywords"},
                {&NSCommentDocumentAttribute, "doccomm"},   {&NSCompanyDocumentAttribute, "company"},
                {&NSCopyrightDocumentAttribute, "copyright"}};
    NSMutableString *infoGroup = [NSMutableString string];
    for (size_t i = 0; i < sizeof info / sizeof info[0]; i++) {
        id v = docAttrs[*info[i].key];
        if ([v isKindOfClass:[NSArray class]])
            v = [v componentsJoinedByString:@", "];
        if ([v length])
            [infoGroup appendFormat:@"\n{\\%s %@}", info[i].word, v];
    }
    if ([infoGroup length])
        [out appendFormat:@"{\\info%@}", infoGroup];
    NSMutableString *layout = [NSMutableString string];
    if (docAttrs[NSLeftMarginDocumentAttribute])
        [layout appendFormat:@"\\margl%d", (int)lround([docAttrs[NSLeftMarginDocumentAttribute] doubleValue] * 20)];
    if (docAttrs[NSRightMarginDocumentAttribute])
        [layout appendFormat:@"\\margr%d", (int)lround([docAttrs[NSRightMarginDocumentAttribute] doubleValue] * 20)];
    if (docAttrs[NSViewSizeDocumentAttribute]) {
        NSSize v = [docAttrs[NSViewSizeDocumentAttribute] sizeValue];
        [layout appendFormat:@"\\vieww%d\\viewh%d", (int)lround(v.width * 20), (int)lround(v.height * 20)];
    }
    if (docAttrs[NSViewModeDocumentAttribute])
        [layout appendFormat:@"\\viewkind%ld", (long)[docAttrs[NSViewModeDocumentAttribute] integerValue]];
    if ([docAttrs[NSViewZoomDocumentAttribute] doubleValue] > 0)
        [layout appendFormat:@"\\viewscale%ld", (long)[docAttrs[NSViewZoomDocumentAttribute] integerValue]];
    if ([layout length])
        [out appendFormat:@"%@\n", layout];
    if (docAttrs[NSHyphenationFactorDocumentAttribute])
        [out appendFormat:@"\\hyphauto1\\hyphfactor%d\n",
                          (int)lround([docAttrs[NSHyphenationFactorDocumentAttribute] doubleValue] * 100)];
    if (docAttrs[NSDefaultTabIntervalDocumentAttribute])
        [out appendFormat:@"\\deftab%d\n", (int)lround([docAttrs[NSDefaultTabIntervalDocumentAttribute] doubleValue] * 20)];
    [out appendString:body];
    [out appendString:@"}"];
    if (attachmentNames)
        *attachmentNames = names;
    return [out dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
}

#pragma mark - The NSAttributedString API

static NSString *
sniff_type(NSData *data)
{
    const char *p = [data bytes];
    NSUInteger n = [data length];
    if (n >= 5 && !memcmp(p, "{\\rtf", 5))
        return NSRTFTextDocumentType;
    if (n >= 4 && !memcmp(p, "rtfd", 4))
        return NSRTFDTextDocumentType;
    return NSPlainTextDocumentType;
}

/* The text of a plain-text document, decoded as asked, else by its byte-order mark, UTF-8 or the default. */
static NSString *
decode_plain(NSData *data, NSDictionary *options, NSStringEncoding *used)
{
    NSNumber *enc = options[NSCharacterEncodingDocumentOption];
    NSString *s = nil;
    if (enc) {
        s = [[[NSString alloc] initWithData:data encoding:[enc unsignedIntegerValue]] autorelease];
        *used = [enc unsignedIntegerValue];
    }
    if (!s && [data length] >= 2) {
        const uint8_t *b = [data bytes];
        if ((b[0] == 0xFE && b[1] == 0xFF) || (b[0] == 0xFF && b[1] == 0xFE)) {
            s = [[[NSString alloc] initWithData:data encoding:NSUnicodeStringEncoding] autorelease];
            *used = NSUnicodeStringEncoding;
        }
    }
    if (!s) {
        s = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        *used = NSUTF8StringEncoding;
    }
    if (!s) {
        s = [[[NSString alloc] initWithData:data encoding:NSMacOSRomanStringEncoding] autorelease];
        *used = NSMacOSRomanStringEncoding;
    }
    return s;
}

/* Reads a document into an attributed string (nil on failure) and its document attributes. */
static NSAttributedString *
read_document(NSData *data, NSDictionary *wrappers, NSDictionary *options, NSDictionary **docAttrs, NSError **error)
{
    NSString *type = options[NSDocumentTypeDocumentOption] ?: sniff_type(data);
    if ([type isEqualToString:NSRTFDTextDocumentType] && !wrappers) {
        NSFileWrapper *w = [[[NSFileWrapper alloc] initWithSerializedRepresentation:data] autorelease];
        NSDictionary *files = [w isDirectory] ? [w fileWrappers] : nil;
        NSData *rtf = [files[@"TXT.rtf"] regularFileContents];
        if (!rtf)
            goto fail;
        return read_document(rtf, files, @{NSDocumentTypeDocumentOption : NSRTFDTextDocumentType}, docAttrs, error);
    }
    if ([type isEqualToString:NSRTFTextDocumentType] || [type isEqualToString:NSRTFDTextDocumentType]) {
        UIFRTFReader *r = [[[UIFRTFReader alloc] initWithData:data attachments:wrappers] autorelease];
        if (![r parse])
            goto fail;
        NSMutableDictionary *d = r->_doc;
        d[NSDocumentTypeDocumentAttribute] = type;
        if (!d[NSPaperSizeDocumentAttribute])
            d[NSPaperSizeDocumentAttribute] = [NSValue valueWithSize:NSMakeSize(612, 792)];
        for (NSString *k in @[ NSLeftMarginDocumentAttribute, NSRightMarginDocumentAttribute ])
            if (!d[k])
                d[k] = @90;
        for (NSString *k in @[ NSTopMarginDocumentAttribute, NSBottomMarginDocumentAttribute ])
            if (!d[k])
                d[k] = @72;
        BOOL cocoa = d[@"CocoaRTFVersion"] != nil;
        if (!cocoa)
            d[@"CocoaRTFVersion"] = @80;
        if (!d[NSDefaultTabIntervalDocumentAttribute])
            d[NSDefaultTabIntervalDocumentAttribute] = cocoa ? @0 : @36;
        if (!d[NSHyphenationFactorDocumentAttribute])
            d[NSHyphenationFactorDocumentAttribute] = @0;
        if (!d[NSTextScalingDocumentAttribute])
            d[NSTextScalingDocumentAttribute] = @0;
        d[@"UsesScreenFonts"] = @0;
        d[@"UTI"] = [type isEqualToString:NSRTFDTextDocumentType] ? @"com.apple.rtfd" : @"public.rtf";
        if (docAttrs)
            *docAttrs = d;
        return r->_out;
    }
    if ([type isEqualToString:NSPlainTextDocumentType]) {
        NSStringEncoding used = 0;
        NSString *s = decode_plain(data, options, &used);
        if (!s)
            goto fail;
        NSDictionary *attrs = options[NSDefaultAttributesDocumentOption] ?: @{NSFontAttributeName : UIFDefaultFont()};
        if (docAttrs)
            *docAttrs = @{NSDocumentTypeDocumentAttribute : NSPlainTextDocumentType,
                          NSCharacterEncodingDocumentAttribute : @(used), @"UTI" : @"public.plain-text"};
        return [[[NSAttributedString alloc] initWithString:s attributes:attrs] autorelease];
    }
fail:
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
    return nil;
}

@implementation NSAttributedString (NSAttributedStringDocumentFormats)

- (instancetype)initWithData:(NSData *)data options:(NSDictionary<NSAttributedStringDocumentReadingOptionKey, id> *)options
          documentAttributes:(NSDictionary<NSAttributedStringDocumentAttributeKey, id> **)dict
                       error:(NSError **)error
{
    NSAttributedString *s = data ? read_document(data, nil, options, dict, error) : nil;
    if (!s) {
        [self release];
        return nil;
    }
    return [self initWithAttributedString:s];
}

- (instancetype)initWithURL:(NSURL *)url options:(NSDictionary<NSAttributedStringDocumentReadingOptionKey, id> *)options
         documentAttributes:(NSDictionary<NSAttributedStringDocumentAttributeKey, id> **)dict
                      error:(NSError **)error
{
    NSFileWrapper *w = [[[NSFileWrapper alloc] initWithURL:url options:0 error:error] autorelease];
    NSAttributedString *s = nil;
    if ([w isDirectory]) {
        NSData *rtf = [[w fileWrappers][@"TXT.rtf"] regularFileContents];
        if (rtf)
            s = read_document(rtf, [w fileWrappers], @{NSDocumentTypeDocumentOption : NSRTFDTextDocumentType}, dict, error);
    } else if (w) {
        s = read_document([w regularFileContents], nil, options, dict, error);
    }
    if (!s) {
        [self release];
        return nil;
    }
    return [self initWithAttributedString:s];
}

- (instancetype)initWithRTF:(NSData *)data documentAttributes:(NSDictionary **)dict
{
    return [self initWithData:data options:@{NSDocumentTypeDocumentOption : NSRTFTextDocumentType} documentAttributes:dict
                        error:NULL];
}

- (instancetype)initWithRTFD:(NSData *)data documentAttributes:(NSDictionary **)dict
{
    return [self initWithData:data options:@{NSDocumentTypeDocumentOption : NSRTFDTextDocumentType} documentAttributes:dict
                        error:NULL];
}

- (instancetype)initWithRTFDFileWrapper:(NSFileWrapper *)wrapper documentAttributes:(NSDictionary **)dict
{
    NSData *rtf = [[wrapper fileWrappers][@"TXT.rtf"] regularFileContents];
    NSAttributedString *s = rtf ? read_document(rtf, [wrapper fileWrappers],
                                                @{NSDocumentTypeDocumentOption : NSRTFDTextDocumentType}, dict, NULL)
                                : nil;
    if (!s) {
        [self release];
        return nil;
    }
    return [self initWithAttributedString:s];
}

- (NSData *)RTFFromRange:(NSRange)range documentAttributes:(NSDictionary *)dict
{
    return UIFRTFData(self, range, dict, NULL);
}

- (NSFileWrapper *)RTFDFileWrapperFromRange:(NSRange)range documentAttributes:(NSDictionary *)dict
{
    NSArray *names = nil;
    NSData *rtf = UIFRTFData(self, range, dict, &names);
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    files[@"TXT.rtf"] = [[[NSFileWrapper alloc] initRegularFileWithContents:rtf] autorelease];
    [self enumerateAttribute:NSAttachmentAttributeName inRange:range options:0
                  usingBlock:^(NSTextAttachment *a, NSRange r, BOOL *stop) {
                      NSFileWrapper *fw = [a fileWrapper];
                      NSString *name = [fw preferredFilename] ?: [fw filename];
                      if (fw && name && !files[name])
                          files[name] = fw;
                  }];
    return [[[NSFileWrapper alloc] initDirectoryWithFileWrappers:files] autorelease];
}

- (NSData *)RTFDFromRange:(NSRange)range documentAttributes:(NSDictionary *)dict
{
    return [[self RTFDFileWrapperFromRange:range documentAttributes:dict] serializedRepresentation];
}

- (NSData *)dataFromRange:(NSRange)range documentAttributes:(NSDictionary<NSAttributedStringDocumentAttributeKey, id> *)dict
                    error:(NSError **)error
{
    NSString *type = dict[NSDocumentTypeDocumentAttribute];
    if ([type isEqualToString:NSRTFTextDocumentType])
        return [self RTFFromRange:range documentAttributes:dict];
    if ([type isEqualToString:NSRTFDTextDocumentType])
        return [self RTFDFromRange:range documentAttributes:dict];
    if ([type isEqualToString:NSPlainTextDocumentType]) {
        NSStringEncoding enc = dict[NSCharacterEncodingDocumentAttribute] ? [dict[NSCharacterEncodingDocumentAttribute]
                                                                                 unsignedIntegerValue]
                                                                           : NSUTF8StringEncoding;
        NSData *d = [[[self string] substringWithRange:range] dataUsingEncoding:enc allowLossyConversion:NO];
        if (!d && error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError
                                     userInfo:nil];
        return d;
    }
    if (error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil];
    return nil;
}

- (NSFileWrapper *)fileWrapperFromRange:(NSRange)range
                     documentAttributes:(NSDictionary<NSAttributedStringDocumentAttributeKey, id> *)dict
                                  error:(NSError **)error
{
    if ([dict[NSDocumentTypeDocumentAttribute] isEqualToString:NSRTFDTextDocumentType])
        return [self RTFDFileWrapperFromRange:range documentAttributes:dict];
    NSData *d = [self dataFromRange:range documentAttributes:dict error:error];
    return d ? [[[NSFileWrapper alloc] initRegularFileWithContents:d] autorelease] : nil;
}

- (NSData *)docFormatFromRange:(NSRange)range documentAttributes:(NSDictionary *)dict { return nil; }

- (BOOL)containsAttachments
{
    return [self containsAttachmentsInRange:NSMakeRange(0, [self length])];
}

- (BOOL)containsAttachmentsInRange:(NSRange)range
{
    __block BOOL found = NO;
    [self enumerateAttribute:NSAttachmentAttributeName inRange:range options:0
                  usingBlock:^(id a, NSRange r, BOOL *stop) {
                      if (a) {
                          found = YES;
                          *stop = YES;
                      }
                  }];
    return found;
}

+ (NSArray<NSString *> *)textTypes
{
    return @[ @"public.rtf", @"com.apple.rtfd", @"com.apple.flat-rtfd", @"public.plain-text", @"public.text" ];
}

+ (NSArray<NSString *> *)textUnfilteredTypes { return [self textTypes]; }

@end

@implementation NSMutableAttributedString (NSAttributedStringDocumentFormats)

- (BOOL)readFromURL:(NSURL *)url options:(NSDictionary<NSAttributedStringDocumentReadingOptionKey, id> *)opts
    documentAttributes:(NSDictionary<NSAttributedStringDocumentAttributeKey, id> **)dict
                 error:(NSError **)error
{
    NSAttributedString *s = [[[NSAttributedString alloc] initWithURL:url options:opts documentAttributes:dict
                                                                error:error] autorelease];
    if (!s)
        return NO;
    [self setAttributedString:s];
    return YES;
}

- (BOOL)readFromData:(NSData *)data options:(NSDictionary<NSAttributedStringDocumentReadingOptionKey, id> *)opts
    documentAttributes:(NSDictionary<NSAttributedStringDocumentAttributeKey, id> **)dict
                 error:(NSError **)error
{
    NSAttributedString *s = [[[NSAttributedString alloc] initWithData:data options:opts documentAttributes:dict
                                                                 error:error] autorelease];
    if (!s)
        return NO;
    [self setAttributedString:s];
    return YES;
}

/* The paragraphs in the range take the writing direction. */
- (void)setBaseWritingDirection:(NSWritingDirection)direction range:(NSRange)range
{
    NSRange pr = [[self string] paragraphRangeForRange:range];
    [self enumerateAttribute:NSParagraphStyleAttributeName inRange:pr options:0
                  usingBlock:^(NSParagraphStyle *ps, NSRange r, BOOL *stop) {
                      NSMutableParagraphStyle *m = [[(ps ?: [NSParagraphStyle defaultParagraphStyle]) mutableCopy]
                          autorelease];
                      [m setBaseWritingDirection:direction];
                      [self addAttribute:NSParagraphStyleAttributeName value:m range:r];
                  }];
}

@end
