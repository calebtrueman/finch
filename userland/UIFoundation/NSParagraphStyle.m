/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSParagraphStyle, NSMutableParagraphStyle, NSTextTab and NSTextList, with
 * Apple's defaults, descriptions and archive keys.
 *
 * Archives hold text alignments as macOS's original values (left 0, right 1,
 * centre 2, justified 3, natural 4), which Apple Silicon's NSTextAlignment
 * reorders (centre 1, right 2); writing directions are stored one higher
 * (natural -1 as 0).
 */
#import "UIFoundationInternal.h"

static NSInteger
alignment_to_archive(NSTextAlignment a)
{
    switch (a) {
    case NSTextAlignmentCenter: return 2;
    case NSTextAlignmentRight: return 1;
    default: return (NSInteger)a;
    }
}

static NSTextAlignment
alignment_from_archive(NSInteger a)
{
    switch (a) {
    case 2: return NSTextAlignmentCenter;
    case 1: return NSTextAlignmentRight;
    case 0: return NSTextAlignmentLeft;
    case 3: return NSTextAlignmentJustified;
    default: return NSTextAlignmentNatural;
    }
}

static BOOL
same_object(id a, id b)
{
    return a == b || [a isEqual:b];
}

#pragma mark - NSTextTab

@implementation NSTextTab {
    NSTextAlignment _alignment;
    NSTextTabType _type;
    CGFloat _location;
    NSDictionary *_options;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSCharacterSet *)columnTerminatorsForLocale:(NSLocale *)aLocale
{
    NSLocale *l = aLocale ? aLocale : [NSLocale systemLocale];
    NSString *sep = [l objectForKey:NSLocaleDecimalSeparator];
    return [NSCharacterSet characterSetWithCharactersInString:sep.length ? sep : @"."];
}

static NSTextTabType
type_for_alignment(NSTextAlignment a)
{
    switch (a) {
    case NSTextAlignmentCenter: return NSCenterTabStopType;
    case NSTextAlignmentRight: return NSRightTabStopType;
    default: return NSLeftTabStopType;
    }
}

- (instancetype)init
{
    return [self initWithTextAlignment:NSTextAlignmentLeft location:0 options:@{}];
}

- (instancetype)initWithTextAlignment:(NSTextAlignment)alignment location:(CGFloat)loc options:(NSDictionary *)options
{
    if ((self = [super init])) {
        _alignment = alignment;
        _type = type_for_alignment(alignment);
        _location = loc;
        _options = [(options ? options : @{}) copy];
    }
    return self;
}

- (instancetype)initWithType:(NSTextTabType)type location:(CGFloat)loc
{
    NSTextAlignment a = NSTextAlignmentLeft;
    NSDictionary *options = @{};
    switch (type) {
    case NSRightTabStopType: a = NSTextAlignmentRight; break;
    case NSCenterTabStopType: a = NSTextAlignmentCenter; break;
    case NSDecimalTabStopType:
        a = NSTextAlignmentNatural;
        options = @{NSTabColumnTerminatorsAttributeName : [NSTextTab columnTerminatorsForLocale:[NSLocale currentLocale]]};
        break;
    default: break;
    }
    if ((self = [self initWithTextAlignment:a location:loc options:options]))
        _type = type;
    return self;
}

- (void)dealloc
{
    [_options release];
    [super dealloc];
}

- (CGFloat)location { return _location; }
- (NSTextAlignment)alignment { return _alignment; }
- (NSDictionary *)options { return _options; }
- (NSTextTabType)tabStopType { return _type; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSTextTab class]])
        return NO;
    NSTextTab *t = other;
    return t->_location == _location && t->_alignment == _alignment && t->_type == _type &&
           same_object(t->_options, _options);
}

- (NSUInteger)hash { return (NSUInteger)_location ^ ((NSUInteger)_alignment << 16); }

- (NSComparisonResult)compare:(NSTextTab *)other
{
    return _location < other.location ? NSOrderedAscending : _location > other.location ? NSOrderedDescending : NSOrderedSame;
}

- (NSString *)description
{
    static const char letters[] = "LCRJN";
    char letter = _type == NSDecimalTabStopType ? 'D' : (_alignment <= 4 ? letters[_alignment] : '?');
    NSString *d = [NSString stringWithFormat:@"%g%c", _location, letter];
    return _options.count ? [d stringByAppendingString:_options.description] : d;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_location forKey:@"NSLocation"];
    [coder encodeObject:_options forKey:@"NSTabOptions"];
    [coder encodeInteger:alignment_to_archive(_alignment) forKey:@"NSTextAlignment"];
    [coder encodeInteger:(NSInteger)_type forKey:@"NSType"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSString class], [NSCharacterSet class], [NSNumber class], nil];
    NSDictionary *options = [coder decodeObjectOfClasses:classes forKey:@"NSTabOptions"];
    NSTextAlignment a = [coder containsValueForKey:@"NSTextAlignment"]
                            ? alignment_from_archive([coder decodeIntegerForKey:@"NSTextAlignment"])
                            : NSTextAlignmentLeft;
    if ((self = [self initWithTextAlignment:a location:[coder decodeDoubleForKey:@"NSLocation"] options:options])) {
        if ([coder containsValueForKey:@"NSType"])
            _type = (NSTextTabType)[coder decodeIntegerForKey:@"NSType"];
    }
    return self;
}

@end

#pragma mark - NSTextList

@implementation NSTextList {
    NSString *_markerFormat;
    NSTextListOptions _options;
    NSInteger _start;
}

+ (BOOL)supportsSecureCoding { return YES; }
+ (BOOL)includesTextListMarkers { return YES; }

- (instancetype)initWithMarkerFormat:(NSTextListMarkerFormat)markerFormat
                             options:(NSTextListOptions)options
                  startingItemNumber:(NSInteger)startingItemNumber
{
    if ((self = [super init])) {
        _markerFormat = [markerFormat copy];
        _options = options;
        _start = startingItemNumber;
    }
    return self;
}

- (instancetype)initWithMarkerFormat:(NSTextListMarkerFormat)markerFormat options:(NSUInteger)options
{
    return [self initWithMarkerFormat:markerFormat options:options startingItemNumber:1];
}

- (instancetype)init { return [self initWithMarkerFormat:NSTextListMarkerDisc options:0]; }

- (void)dealloc
{
    [_markerFormat release];
    [super dealloc];
}

- (NSTextListMarkerFormat)markerFormat { return _markerFormat; }
- (NSTextListOptions)listOptions { return _options; }
- (NSInteger)startingItemNumber { return _start; }
- (void)setStartingItemNumber:(NSInteger)n { _start = n; }
- (id)copyWithZone:(NSZone *)zone
{
    return [[NSTextList alloc] initWithMarkerFormat:_markerFormat options:_options startingItemNumber:_start];
}

static NSString *
roman(NSInteger n, BOOL upper)
{
    static const struct {
        NSInteger value;
        const char *s;
    } digits[] = {{1000, "m"}, {900, "cm"}, {500, "d"}, {400, "cd"}, {100, "c"}, {90, "xc"}, {50, "l"},
                  {40, "xl"},  {10, "x"},   {9, "ix"},  {5, "v"},    {4, "iv"},  {1, "i"}};
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < sizeof digits / sizeof digits[0]; i++)
        while (n >= digits[i].value) {
            [s appendFormat:@"%s", digits[i].s];
            n -= digits[i].value;
        }
    return upper ? s.uppercaseString : s;
}

/* Each marker token, and what an item number becomes in it. */
static NSString *
marker_text(NSString *token, NSInteger n)
{
    if ([token isEqual:NSTextListMarkerDecimal])
        return [NSString stringWithFormat:@"%ld", (long)n];
    if ([token isEqual:NSTextListMarkerOctal])
        return [NSString stringWithFormat:@"%lo", (long)n];
    if ([token isEqual:NSTextListMarkerLowercaseHexadecimal])
        return [NSString stringWithFormat:@"%lx", (long)n];
    if ([token isEqual:NSTextListMarkerUppercaseHexadecimal])
        return [NSString stringWithFormat:@"%lX", (long)n];
    if ([token isEqual:NSTextListMarkerLowercaseRoman])
        return roman(n, NO);
    if ([token isEqual:NSTextListMarkerUppercaseRoman])
        return roman(n, YES);
    BOOL lowerAlpha = [token isEqual:NSTextListMarkerLowercaseAlpha] || [token isEqual:NSTextListMarkerLowercaseLatin];
    BOOL upperAlpha = [token isEqual:NSTextListMarkerUppercaseAlpha] || [token isEqual:NSTextListMarkerUppercaseLatin];
    if (lowerAlpha || upperAlpha) {
        unichar c = (unichar)((upperAlpha ? 'A' : 'a') + ((n - 1) % 26 + 26) % 26);
        return [NSString stringWithCharacters:&c length:1];
    }
    static const struct {
        NSString *const *token;
        unichar c;
    } bullets[] = {
        {&NSTextListMarkerDisc, 0x2022},   {&NSTextListMarkerCircle, 0x25E6}, {&NSTextListMarkerSquare, 0x25AA},
        {&NSTextListMarkerHyphen, 0x2043}, {&NSTextListMarkerDiamond, 0x25C6}, {&NSTextListMarkerBox, 0x25AB},
        {&NSTextListMarkerCheck, 0x2713},
    };
    for (size_t i = 0; i < sizeof bullets / sizeof bullets[0]; i++)
        if ([token isEqual:*bullets[i].token])
            return [NSString stringWithCharacters:&bullets[i].c length:1];
    return nil;
}

- (NSString *)markerForItemNumber:(NSInteger)itemNumber
{
    NSMutableString *out = [NSMutableString string];
    NSString *f = _markerFormat ? _markerFormat : @"";
    NSUInteger i = 0;
    while (i < f.length) {
        NSRange open = [f rangeOfString:@"{" options:0 range:NSMakeRange(i, f.length - i)];
        NSRange close = open.location == NSNotFound
                            ? open
                            : [f rangeOfString:@"}" options:0 range:NSMakeRange(open.location, f.length - open.location)];
        if (close.location == NSNotFound) {
            [out appendString:[f substringFromIndex:i]];
            break;
        }
        [out appendString:[f substringWithRange:NSMakeRange(i, open.location - i)]];
        NSString *token = [f substringWithRange:NSMakeRange(open.location, close.location + 1 - open.location)];
        NSString *t = marker_text(token, itemNumber);
        [out appendString:t ? t : token];
        i = close.location + 1;
    }
    return out;
}

- (BOOL)isOrdered
{
    NSString *tokens[] = {NSTextListMarkerDecimal, NSTextListMarkerOctal, NSTextListMarkerLowercaseHexadecimal,
                          NSTextListMarkerUppercaseHexadecimal, NSTextListMarkerLowercaseRoman,
                          NSTextListMarkerUppercaseRoman, NSTextListMarkerLowercaseAlpha, NSTextListMarkerUppercaseAlpha,
                          NSTextListMarkerLowercaseLatin, NSTextListMarkerUppercaseLatin};
    for (size_t i = 0; i < sizeof tokens / sizeof tokens[0]; i++)
        if ([_markerFormat rangeOfString:tokens[i]].location != NSNotFound)
            return YES;
    return NO;
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSTextList class]])
        return NO;
    NSTextList *l = other;
    return same_object(l->_markerFormat, _markerFormat) && l->_options == _options && l->_start == _start;
}

- (NSUInteger)hash { return _markerFormat.hash ^ _options; }

- (NSString *)description
{
    NSMutableString *d = [NSMutableString stringWithFormat:@"NSTextList %p format <%@>", self, _markerFormat];
    if (_options)
        [d appendFormat:@" options 0x%lx", (unsigned long)_options];
    if (_start != 1)
        [d appendFormat:@" start at %ld", (long)_start];
    return d;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_markerFormat forKey:@"NSMarkerFormat"];
    [coder encodeObject:nil forKey:@"NSMarkerTextAttachment"];
    if (_options)
        [coder encodeInteger:(NSInteger)_options forKey:@"NSOptions"];
    if (_start != 1)
        [coder encodeInteger:_start forKey:@"NSStart"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *format = [coder decodeObjectOfClass:[NSString class] forKey:@"NSMarkerFormat"];
    NSInteger start = [coder containsValueForKey:@"NSStart"] ? [coder decodeIntegerForKey:@"NSStart"] : 1;
    return [self initWithMarkerFormat:format
                              options:(NSTextListOptions)[coder decodeIntegerForKey:@"NSOptions"]
                   startingItemNumber:start];
}

@end

#pragma mark - NSParagraphStyle

/* The ivars, shared by the immutable and mutable classes. */
@interface NSParagraphStyle () {
@public
    NSTextAlignment _alignment;
    CGFloat _lineSpacing, _paragraphSpacing, _paragraphSpacingBefore;
    CGFloat _headIndent, _tailIndent, _firstLineHeadIndent;
    CGFloat _minimumLineHeight, _maximumLineHeight, _lineHeightMultiple;
    NSLineBreakMode _lineBreakMode;
    NSWritingDirection _baseWritingDirection;
    float _hyphenationFactor, _tighteningFactor;
    BOOL _usesDefaultHyphenation, _allowsTightening;
    NSArray *_tabStops; /* nil: the default tabs */
    CGFloat _defaultTabInterval;
    NSArray *_textBlocks, *_textLists;
    NSInteger _headerLevel;
    NSLineBreakStrategy _lineBreakStrategy;
}
@end

static NSArray *
default_tabs(void)
{
    static NSArray *tabs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *a = [NSMutableArray array];
        for (int i = 1; i <= 12; i++)
            [a addObject:[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:28 * i options:@{}] autorelease]];
        tabs = [a copy];
    });
    return tabs;
}

static void
set_defaults(NSParagraphStyle *p)
{
    p->_alignment = NSTextAlignmentNatural;
    p->_lineBreakMode = NSLineBreakByWordWrapping;
    p->_baseWritingDirection = NSWritingDirectionNatural;
    p->_allowsTightening = YES;
    p->_tighteningFactor = 0.05f;
}

static void
copy_style(NSParagraphStyle *to, NSParagraphStyle *from)
{
    NSArray *tabs = to->_tabStops, *blocks = to->_textBlocks, *lists = to->_textLists;
    to->_alignment = from->_alignment;
    to->_lineSpacing = from->_lineSpacing;
    to->_paragraphSpacing = from->_paragraphSpacing;
    to->_paragraphSpacingBefore = from->_paragraphSpacingBefore;
    to->_headIndent = from->_headIndent;
    to->_tailIndent = from->_tailIndent;
    to->_firstLineHeadIndent = from->_firstLineHeadIndent;
    to->_minimumLineHeight = from->_minimumLineHeight;
    to->_maximumLineHeight = from->_maximumLineHeight;
    to->_lineHeightMultiple = from->_lineHeightMultiple;
    to->_lineBreakMode = from->_lineBreakMode;
    to->_baseWritingDirection = from->_baseWritingDirection;
    to->_hyphenationFactor = from->_hyphenationFactor;
    to->_tighteningFactor = from->_tighteningFactor;
    to->_usesDefaultHyphenation = from->_usesDefaultHyphenation;
    to->_allowsTightening = from->_allowsTightening;
    to->_tabStops = [from->_tabStops copy];
    to->_defaultTabInterval = from->_defaultTabInterval;
    to->_textBlocks = [from->_textBlocks copy];
    to->_textLists = [from->_textLists copy];
    to->_headerLevel = from->_headerLevel;
    to->_lineBreakStrategy = from->_lineBreakStrategy;
    [tabs release];
    [blocks release];
    [lists release];
}

@implementation NSParagraphStyle

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSParagraphStyle *)defaultParagraphStyle
{
    static NSParagraphStyle *style;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        style = [[NSParagraphStyle alloc] init];
    });
    return style;
}

+ (NSWritingDirection)defaultWritingDirectionForLanguage:(NSString *)languageName
{
    if (!languageName)
        return NSWritingDirectionLeftToRight;
    return [NSLocale characterDirectionForLanguage:languageName] == NSLocaleLanguageDirectionRightToLeft
               ? NSWritingDirectionRightToLeft
               : NSWritingDirectionLeftToRight;
}

- (instancetype)init
{
    if ((self = [super init]))
        set_defaults(self);
    return self;
}

- (void)dealloc
{
    [_tabStops release];
    [_textBlocks release];
    [_textLists release];
    [super dealloc];
}

- (NSTextAlignment)alignment { return _alignment; }
- (CGFloat)lineSpacing { return _lineSpacing; }
- (CGFloat)paragraphSpacing { return _paragraphSpacing; }
- (CGFloat)paragraphSpacingBefore { return _paragraphSpacingBefore; }
- (CGFloat)headIndent { return _headIndent; }
- (CGFloat)tailIndent { return _tailIndent; }
- (CGFloat)firstLineHeadIndent { return _firstLineHeadIndent; }
- (CGFloat)minimumLineHeight { return _minimumLineHeight; }
- (CGFloat)maximumLineHeight { return _maximumLineHeight; }
- (CGFloat)lineHeightMultiple { return _lineHeightMultiple; }
- (NSLineBreakMode)lineBreakMode { return _lineBreakMode; }
- (NSWritingDirection)baseWritingDirection { return _baseWritingDirection; }
- (float)hyphenationFactor { return _hyphenationFactor; }
- (float)tighteningFactorForTruncation { return _tighteningFactor; }
- (BOOL)usesDefaultHyphenation { return _usesDefaultHyphenation; }
- (BOOL)allowsDefaultTighteningForTruncation { return _allowsTightening; }
- (NSArray *)tabStops { return _tabStops ? _tabStops : default_tabs(); }
- (CGFloat)defaultTabInterval { return _defaultTabInterval; }
- (NSArray *)textBlocks { return _textBlocks ? _textBlocks : @[]; }
- (NSArray *)textLists { return _textLists ? _textLists : @[]; }
- (NSInteger)headerLevel { return _headerLevel; }
- (NSLineBreakStrategy)lineBreakStrategy { return _lineBreakStrategy; }

- (id)copyWithZone:(NSZone *)zone
{
    if ([self class] == [NSParagraphStyle class])
        return [self retain];
    NSParagraphStyle *p = [[NSParagraphStyle allocWithZone:zone] init];
    copy_style(p, self);
    return p;
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
    NSMutableParagraphStyle *p = [[NSMutableParagraphStyle allocWithZone:zone] init];
    copy_style(p, self);
    return p;
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSParagraphStyle class]])
        return NO;
    NSParagraphStyle *o = other;
    return o->_alignment == _alignment && o->_lineSpacing == _lineSpacing && o->_paragraphSpacing == _paragraphSpacing &&
           o->_paragraphSpacingBefore == _paragraphSpacingBefore && o->_headIndent == _headIndent &&
           o->_tailIndent == _tailIndent && o->_firstLineHeadIndent == _firstLineHeadIndent &&
           o->_minimumLineHeight == _minimumLineHeight && o->_maximumLineHeight == _maximumLineHeight &&
           o->_lineHeightMultiple == _lineHeightMultiple && o->_lineBreakMode == _lineBreakMode &&
           o->_baseWritingDirection == _baseWritingDirection && o->_hyphenationFactor == _hyphenationFactor &&
           o->_tighteningFactor == _tighteningFactor && o->_usesDefaultHyphenation == _usesDefaultHyphenation &&
           o->_allowsTightening == _allowsTightening && same_object(o.tabStops, self.tabStops) &&
           o->_defaultTabInterval == _defaultTabInterval && same_object(o.textBlocks, self.textBlocks) &&
           same_object(o.textLists, self.textLists) && o->_headerLevel == _headerLevel &&
           o->_lineBreakStrategy == _lineBreakStrategy;
}

- (NSUInteger)hash
{
    return self.tabStops.count ^ ((NSUInteger)_alignment << 8) ^ ((NSUInteger)_lineBreakMode << 12) ^
           (NSUInteger)(_lineSpacing * 16) ^ ((NSUInteger)(_headIndent * 16) << 4);
}

static NSString *
alignment_name(NSTextAlignment a)
{
    switch (a) {
    case NSTextAlignmentLeft: return @"Left";
    case NSTextAlignmentCenter: return @"Center";
    case NSTextAlignmentRight: return @"Right";
    case NSTextAlignmentJustified: return @"Justified";
    case NSTextAlignmentNatural: return @"Natural";
    }
    return @"Unknown";
}

static NSString *
line_break_name(NSLineBreakMode m)
{
    switch (m) {
    case NSLineBreakByWordWrapping: return @"WordWrapping";
    case NSLineBreakByCharWrapping: return @"CharWrapping";
    case NSLineBreakByClipping: return @"Clipping";
    case NSLineBreakByTruncatingHead: return @"TruncatingHead";
    case NSLineBreakByTruncatingTail: return @"TruncatingTail";
    case NSLineBreakByTruncatingMiddle: return @"TruncatingMiddle";
    }
    return @"Unknown";
}

static NSString *
direction_name(NSWritingDirection d)
{
    switch (d) {
    case NSWritingDirectionLeftToRight: return @"LeftToRight";
    case NSWritingDirectionRightToLeft: return @"RightToLeft";
    default: return @"Natural";
    }
}

- (NSString *)description
{
    return [NSString
        stringWithFormat:@"Alignment %@, LineSpacing %g, ParagraphSpacing %g, ParagraphSpacingBefore %g, HeadIndent %g, "
                         @"TailIndent %g, FirstLineHeadIndent %g, LineHeight %g/%g, LineHeightMultiple %g LineBreakMode "
                         @"%@, Tabs %@, DefaultTabInterval %g, Blocks %@, Lists %@, BaseWritingDirection %@, "
                         @"HyphenationFactor %g, TighteningForTruncation %@, HeaderLevel %ld LineBreakStrategy %lu%@ "
                         @"PresentationIntents (\n) ListIntentOrdinal 0 CodeBlockIntentLanguageHint ''",
                         alignment_name(_alignment), _lineSpacing, _paragraphSpacing, _paragraphSpacingBefore,
                         _headIndent, _tailIndent, _firstLineHeadIndent, _minimumLineHeight, _maximumLineHeight,
                         _lineHeightMultiple, line_break_name(_lineBreakMode), self.tabStops, _defaultTabInterval,
                         self.textBlocks, self.textLists, direction_name(_baseWritingDirection), _hyphenationFactor,
                         _allowsTightening ? @"YES" : @"NO", (long)_headerLevel, (unsigned long)_lineBreakStrategy,
                         _usesDefaultHyphenation ? @", UsesDefaultHyphenation YES" : @""];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:alignment_to_archive(_alignment) forKey:@"NSAlignment"];
    if (_allowsTightening)
        [coder encodeInteger:1 forKey:@"NSAllowsTighteningForTruncation"];
    [coder encodeObject:_tabStops forKey:@"NSTabStops"];
#define ENCODE_D(ivar, key) \
    if (ivar != 0)          \
        [coder encodeDouble:ivar forKey:key];
    ENCODE_D(_defaultTabInterval, @"NSDefaultTabInterval")
    ENCODE_D(_firstLineHeadIndent, @"NSFirstLineHeadIndent")
    ENCODE_D(_headIndent, @"NSHeadIndent")
    ENCODE_D((double)_headerLevel, @"NSHeaderLevel")
    ENCODE_D((double)_hyphenationFactor, @"NSHyphenationFactor")
    ENCODE_D(_lineHeightMultiple, @"NSLineHeightMultiple")
    ENCODE_D(_lineSpacing, @"NSLineSpacing")
    ENCODE_D(_maximumLineHeight, @"NSMaxLineHeight")
    ENCODE_D(_minimumLineHeight, @"NSMinLineHeight")
    ENCODE_D(_paragraphSpacing, @"NSParagraphSpacing")
    ENCODE_D(_paragraphSpacingBefore, @"NSParagraphSpacingBefore")
    ENCODE_D(_tailIndent, @"NSTailIndent")
#undef ENCODE_D
    if (_lineBreakMode != NSLineBreakByWordWrapping)
        [coder encodeInteger:(NSInteger)_lineBreakMode forKey:@"NSLineBreakMode"];
    if (_lineBreakStrategy)
        [coder encodeInteger:(NSInteger)_lineBreakStrategy forKey:@"NSLineBreakStrategy"];
    if (_usesDefaultHyphenation)
        [coder encodeBool:YES forKey:@"NSUsesDefaultHyphenation"];
    if (_baseWritingDirection != NSWritingDirectionNatural)
        [coder encodeInteger:(NSInteger)_baseWritingDirection + 1 forKey:@"NSWritingDirection"];
    if (_textBlocks.count)
        [coder encodeObject:_textBlocks forKey:@"NSTextBlocks"];
    if (_textLists.count)
        [coder encodeObject:_textLists forKey:@"NSTextLists"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self init]))
        return nil;
    if ([coder containsValueForKey:@"NSAlignment"])
        _alignment = alignment_from_archive([coder decodeIntegerForKey:@"NSAlignment"]);
    _allowsTightening = [coder decodeIntegerForKey:@"NSAllowsTighteningForTruncation"] != 0;
    NSSet *tabClasses = [NSSet setWithObjects:[NSArray class], [NSTextTab class], nil];
    _tabStops = [[coder decodeObjectOfClasses:tabClasses forKey:@"NSTabStops"] copy];
    _defaultTabInterval = [coder decodeDoubleForKey:@"NSDefaultTabInterval"];
    _firstLineHeadIndent = [coder decodeDoubleForKey:@"NSFirstLineHeadIndent"];
    _headIndent = [coder decodeDoubleForKey:@"NSHeadIndent"];
    _headerLevel = (NSInteger)[coder decodeDoubleForKey:@"NSHeaderLevel"];
    _hyphenationFactor = (float)[coder decodeDoubleForKey:@"NSHyphenationFactor"];
    _lineHeightMultiple = [coder decodeDoubleForKey:@"NSLineHeightMultiple"];
    _lineSpacing = [coder decodeDoubleForKey:@"NSLineSpacing"];
    _maximumLineHeight = [coder decodeDoubleForKey:@"NSMaxLineHeight"];
    _minimumLineHeight = [coder decodeDoubleForKey:@"NSMinLineHeight"];
    _paragraphSpacing = [coder decodeDoubleForKey:@"NSParagraphSpacing"];
    _paragraphSpacingBefore = [coder decodeDoubleForKey:@"NSParagraphSpacingBefore"];
    _tailIndent = [coder decodeDoubleForKey:@"NSTailIndent"];
    _lineBreakMode = (NSLineBreakMode)[coder decodeIntegerForKey:@"NSLineBreakMode"];
    _lineBreakStrategy = (NSLineBreakStrategy)[coder decodeIntegerForKey:@"NSLineBreakStrategy"];
    _usesDefaultHyphenation = [coder decodeBoolForKey:@"NSUsesDefaultHyphenation"];
    if ([coder containsValueForKey:@"NSWritingDirection"])
        _baseWritingDirection = (NSWritingDirection)([coder decodeIntegerForKey:@"NSWritingDirection"] - 1);
    NSSet *any = [NSSet setWithObjects:[NSArray class], [NSObject class], nil];
    _textBlocks = [[coder decodeObjectOfClasses:any forKey:@"NSTextBlocks"] copy];
    _textLists = [[coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSTextList class], nil]
                                        forKey:@"NSTextLists"] copy];
    return self;
}

@end

@implementation NSMutableParagraphStyle

- (void)setAlignment:(NSTextAlignment)v { _alignment = v; }
- (void)setLineSpacing:(CGFloat)v { _lineSpacing = v; }
- (void)setParagraphSpacing:(CGFloat)v { _paragraphSpacing = v; }
- (void)setParagraphSpacingBefore:(CGFloat)v { _paragraphSpacingBefore = v; }
- (void)setHeadIndent:(CGFloat)v { _headIndent = v; }
- (void)setTailIndent:(CGFloat)v { _tailIndent = v; }
- (void)setFirstLineHeadIndent:(CGFloat)v { _firstLineHeadIndent = v; }
- (void)setMinimumLineHeight:(CGFloat)v { _minimumLineHeight = v < 0 ? 0 : v; }
- (void)setMaximumLineHeight:(CGFloat)v { _maximumLineHeight = v < 0 ? 0 : v; }
- (void)setLineHeightMultiple:(CGFloat)v { _lineHeightMultiple = v; }
- (void)setLineBreakMode:(NSLineBreakMode)v { _lineBreakMode = v; }
- (void)setBaseWritingDirection:(NSWritingDirection)v { _baseWritingDirection = v; }
- (void)setHyphenationFactor:(float)v { _hyphenationFactor = v; }
- (void)setTighteningFactorForTruncation:(float)v { _tighteningFactor = v; }
- (void)setUsesDefaultHyphenation:(BOOL)v { _usesDefaultHyphenation = v; }
- (void)setAllowsDefaultTighteningForTruncation:(BOOL)v { _allowsTightening = v; }
- (void)setDefaultTabInterval:(CGFloat)v { _defaultTabInterval = v; }
- (void)setHeaderLevel:(NSInteger)v { _headerLevel = v; }
- (void)setLineBreakStrategy:(NSLineBreakStrategy)v { _lineBreakStrategy = v; }

- (void)setTabStops:(NSArray *)tabs
{
    /* null_resettable: nil brings back the default tabs. */
    NSArray *old = _tabStops;
    _tabStops = tabs ? [[tabs sortedArrayUsingSelector:@selector(compare:)] retain] : nil;
    [old release];
}

- (void)setTextBlocks:(NSArray *)blocks
{
    NSArray *old = _textBlocks;
    _textBlocks = [blocks copy];
    [old release];
}

- (void)setTextLists:(NSArray *)lists
{
    NSArray *old = _textLists;
    _textLists = [lists copy];
    [old release];
}

- (void)addTabStop:(NSTextTab *)tab
{
    if (tab)
        self.tabStops = [self.tabStops arrayByAddingObject:tab];
}

- (void)removeTabStop:(NSTextTab *)tab
{
    NSMutableArray *a = [[self.tabStops mutableCopy] autorelease];
    NSUInteger i = [a indexOfObject:tab];
    if (i != NSNotFound) {
        [a removeObjectAtIndex:i];
        self.tabStops = a;
    }
}

- (void)setParagraphStyle:(NSParagraphStyle *)obj
{
    if (obj)
        copy_style(self, obj);
}

- (Class)classForCoder { return [NSMutableParagraphStyle class]; }

@end

/* NSTextAlignment and CoreText's CTTextAlignment order centre and right differently. */
CTTextAlignment
NSTextAlignmentToCTTextAlignment(NSTextAlignment a)
{
    switch (a) {
    case NSTextAlignmentCenter: return kCTTextAlignmentCenter;
    case NSTextAlignmentRight: return kCTTextAlignmentRight;
    case NSTextAlignmentLeft: return kCTTextAlignmentLeft;
    case NSTextAlignmentJustified: return kCTTextAlignmentJustified;
    default: return kCTTextAlignmentNatural;
    }
}

NSTextAlignment
NSTextAlignmentFromCTTextAlignment(CTTextAlignment a)
{
    switch (a) {
    case kCTTextAlignmentCenter: return NSTextAlignmentCenter;
    case kCTTextAlignmentRight: return NSTextAlignmentRight;
    case kCTTextAlignmentLeft: return NSTextAlignmentLeft;
    case kCTTextAlignmentJustified: return NSTextAlignmentJustified;
    default: return NSTextAlignmentNatural;
    }
}
