/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextStorage (the text system's attributed string: edit tracking,
 * delegate calls and notifications, its layout managers) and
 * NSConcreteTextStorage, the class [NSTextStorage alloc] makes, as Apple's.
 * Apps subclass NSTextStorage and implement the four primitives
 * (-string, -attributesAtIndex:effectiveRange:,
 * -replaceCharactersInRange:withString:, -setAttributes:range:), calling
 * -edited:range:changeInLength: from the mutating two.
 */
#import "UIFoundationInternal.h"

@interface NSConcreteTextStorage : NSTextStorage
@end

@interface NSLayoutManager (UIFTextStorage)
- (void)_uifSetTextStorage:(NSTextStorage *)textStorage;
@end

@interface NSTextStorage () {
    NSMutableArray *_layoutManagers;
    NSTextStorageEditActions _editedMask;
    NSRange _editedRange;
    NSInteger _changeInLength;
    NSInteger _editingDepth;
    __weak id<NSTextStorageDelegate> _delegate;
    __weak id<NSTextStorageObserving> _observer;
    BOOL _processing;
}
@end

@implementation NSTextStorage

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSTextStorage class])
        return [NSConcreteTextStorage allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)init
{
    if ((self = [super init])) {
        _layoutManagers = [NSMutableArray new];
        _editedRange = NSMakeRange(NSNotFound, 0);
    }
    return self;
}

- (void)dealloc
{
    for (NSLayoutManager *lm in _layoutManagers)
        [lm _uifSetTextStorage:nil];
    [_layoutManagers release];
    [super dealloc];
}

- (NSArray *)layoutManagers { return [[_layoutManagers copy] autorelease]; }

- (void)addLayoutManager:(NSLayoutManager *)lm
{
    if (!lm || [_layoutManagers indexOfObjectIdenticalTo:lm] != NSNotFound)
        return;
    [lm.textStorage removeLayoutManager:lm];
    [_layoutManagers addObject:lm];
    [lm _uifSetTextStorage:self];
}

- (void)removeLayoutManager:(NSLayoutManager *)lm
{
    NSUInteger i = [_layoutManagers indexOfObjectIdenticalTo:lm];
    if (i == NSNotFound)
        return;
    [[lm retain] autorelease];
    [lm _uifSetTextStorage:nil];
    [_layoutManagers removeObjectAtIndex:i];
}

- (NSTextStorageEditActions)editedMask { return _editedMask; }
- (NSRange)editedRange { return _editedRange; }
- (NSInteger)changeInLength { return _changeInLength; }
- (id<NSTextStorageDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSTextStorageDelegate>)delegate { _delegate = delegate; }
- (id<NSTextStorageObserving>)textStorageObserver { return _observer; }
- (void)setTextStorageObserver:(id<NSTextStorageObserving>)observer { _observer = observer; }
- (BOOL)fixesAttributesLazily { return YES; } /* as Apple's says; Finch fixes as it processes each edit */
- (void)invalidateAttributesInRange:(NSRange)range { }
- (void)ensureAttributesAreFixedInRange:(NSRange)range { }

- (void)edited:(NSTextStorageEditActions)mask range:(NSRange)range changeInLength:(NSInteger)delta
{
    /* The range in the text as it is after this edit, merged with the
     * earlier edits' (moved by this one's change in length). */
    NSRange now = NSMakeRange(range.location, (NSUInteger)MAX((NSInteger)range.length + delta, 0));
    if (!_editedMask || _editedRange.location == NSNotFound) {
        _editedRange = now;
        _changeInLength = delta;
    } else {
        NSRange old = _editedRange;
        if (NSMaxRange(old) > range.location)
            old.length = (NSUInteger)MAX((NSInteger)old.length + delta, 0);
        _editedRange = NSUnionRange(old, now);
        _changeInLength += delta;
    }
    _editedMask |= mask;
    if (_editingDepth == 0)
        [self processEditing];
}

- (void)beginEditing { _editingDepth++; }

- (void)endEditing
{
    if (_editingDepth > 0 && --_editingDepth == 0 && _editedMask)
        [self processEditing];
}

/* A subclass's own storage can't be reached without edits; it's left as it is. */
- (void)_uifFixAttributesQuietlyInRange:(NSRange)range {}

- (void)processEditing
{
    if (_processing)
        return;
    _processing = YES;
    id<NSTextStorageDelegate> d = _delegate;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if ([d respondsToSelector:@selector(textStorage:willProcessEditing:range:changeInLength:)])
        [d textStorage:self willProcessEditing:_editedMask range:_editedRange changeInLength:_changeInLength];
    [nc postNotificationName:NSTextStorageWillProcessEditingNotification object:self];
    /* fix the edited paragraphs, out of sight: Apple's fixes lazily, so they aren't edits anyone sees */
    if (_editedRange.location != NSNotFound && self.length) {
        NSUInteger len = self.length;
        NSRange r = NSMakeRange(MIN(_editedRange.location, len - 1), 0);
        r.length = MIN(NSMaxRange(_editedRange), len) - r.location;
        [self _uifFixAttributesQuietlyInRange:[self.string paragraphRangeForRange:r]];
    }
    if ([d respondsToSelector:@selector(textStorage:didProcessEditing:range:changeInLength:)])
        [d textStorage:self didProcessEditing:_editedMask range:_editedRange changeInLength:_changeInLength];
    [nc postNotificationName:NSTextStorageDidProcessEditingNotification object:self];
    NSTextStorageEditActions mask = _editedMask;
    NSRange range = _editedRange;
    NSInteger delta = _changeInLength;
    _editedMask = 0;
    _editedRange.location = NSNotFound;
    _changeInLength = 0;
    _processing = NO;
    NSRange invalid = range;
    for (NSLayoutManager *lm in [[_layoutManagers copy] autorelease])
        [lm processEditingForTextStorage:self edited:mask range:range changeInLength:delta invalidatedRange:invalid];
    [_observer processEditingForTextStorage:self edited:mask range:range changeInLength:delta invalidatedRange:invalid];
}

- (Class)classForCoder { return [NSTextStorage class]; }

#pragma mark Archiving

/*
 * As Apple archives text storages (in nibs): NSString, then NSAttributes,
 * one dictionary when the text has one run of attributes, else an array of
 * them with NSAttributeInfo, varint pairs of a run's length and its
 * dictionary's index.
 */
static BOOL
read_varint(const uint8_t **p, const uint8_t *end, NSUInteger *out)
{
    NSUInteger v = 0;
    for (int shift = 0; *p < end && shift < 63; shift += 7) {
        uint8_t b = *(*p)++;
        v |= (NSUInteger)(b & 0x7f) << shift;
        if (!(b & 0x80)) {
            *out = v;
            return YES;
        }
    }
    return NO;
}

static void
write_varint(NSMutableData *d, NSUInteger v)
{
    do {
        uint8_t b = v & 0x7f;
        v >>= 7;
        if (v)
            b |= 0x80;
        [d appendBytes:&b length:1];
    } while (v);
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self init]))
        return nil;
    NSString *string = [coder decodeObjectForKey:@"NSString"];
    if (![string isKindOfClass:[NSString class]])
        string = @"";
    id attrs = [coder decodeObjectForKey:@"NSAttributes"];
    NSData *info = [coder decodeObjectForKey:@"NSAttributeInfo"];
    _delegate = [coder decodeObjectForKey:@"NSDelegate"];
    [self beginEditing];
    [self replaceCharactersInRange:NSMakeRange(0, 0) withString:string];
    NSUInteger len = string.length;
    if ([attrs isKindOfClass:[NSDictionary class]]) {
        if (len)
            [self setAttributes:attrs range:NSMakeRange(0, len)];
    } else if ([attrs isKindOfClass:[NSArray class]] && [info isKindOfClass:[NSData class]]) {
        const uint8_t *p = info.bytes, *end = p + info.length;
        NSUInteger at = 0, run, index;
        while (at < len && read_varint(&p, end, &run) && read_varint(&p, end, &index)) {
            run = MIN(run, len - at);
            id a = index < [attrs count] ? attrs[index] : nil;
            if ([a isKindOfClass:[NSDictionary class]] && run)
                [self setAttributes:a range:NSMakeRange(at, run)];
            at += run;
        }
    }
    [self endEditing];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSUInteger len = self.length;
    [coder encodeObject:[[self.string mutableCopy] autorelease] forKey:@"NSString"];
    NSMutableArray *dicts = [NSMutableArray array];
    NSMutableData *info = [NSMutableData data];
    for (NSUInteger at = 0; at < len;) {
        NSRange r;
        NSDictionary *a = [self attributesAtIndex:at effectiveRange:&r];
        NSUInteger i = [dicts indexOfObject:a];
        if (i == NSNotFound) {
            i = dicts.count;
            [dicts addObject:a];
        }
        write_varint(info, NSMaxRange(r) - at);
        write_varint(info, i);
        at = NSMaxRange(r);
    }
    if (dicts.count == 1) {
        [coder encodeObject:dicts[0] forKey:@"NSAttributes"];
    } else if (dicts.count > 1) {
        [coder encodeObject:dicts forKey:@"NSAttributes"];
        [coder encodeObject:info forKey:@"NSAttributeInfo"];
    }
    if (_delegate)
        [coder encodeConditionalObject:_delegate forKey:@"NSDelegate"];
}

@end

@implementation NSConcreteTextStorage {
    NSMutableAttributedString *_contents;
}

- (instancetype)init
{
    if ((self = [super init]))
        _contents = [NSMutableAttributedString new];
    return self;
}

- (void)dealloc
{
    [_contents release];
    [super dealloc];
}

- (NSString *)string { return _contents.string; }
- (NSUInteger)length { return _contents.length; }

- (NSDictionary *)attributesAtIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range
{
    return [_contents attributesAtIndex:location effectiveRange:range];
}

- (id)attribute:(NSAttributedStringKey)name atIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range
{
    return [_contents attribute:name atIndex:location effectiveRange:range];
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)str
{
    NSUInteger before = _contents.length;
    [_contents replaceCharactersInRange:range withString:str ? str : @""];
    [self edited:NSTextStorageEditedCharacters range:range changeInLength:(NSInteger)_contents.length - (NSInteger)before];
}

- (void)setAttributes:(NSDictionary *)attrs range:(NSRange)range
{
    [_contents setAttributes:attrs range:range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}

- (void)_uifFixAttributesQuietlyInRange:(NSRange)range { [_contents fixAttributesInRange:range]; }

@end

#pragma mark - Attribute fixing

/*
 * As Apple's: text without a font gets the default (Helvetica 12), characters
 * its font can't show get a font that can (CoreText's fallback, the same size),
 * and each paragraph takes the paragraph style of its first character.
 * NSTextStorage fixes the edited paragraphs as it processes an edit.
 */
static BOOL
needs_glyph(unichar c)
{
    return c >= 0x20 && c != 0x2028 && c != 0x2029 && c != 0x85 && !(c >= 0x7f && c < 0xa0) && c != 0xfffc;
}

@implementation NSMutableAttributedString (UIFAttributeFixing)

- (void)fixFontAttributeInRange:(NSRange)range
{
    NSUInteger len = self.length;
    if (NSMaxRange(range) > len)
        range.length = len > range.location ? len - range.location : 0;
    if (!range.length)
        return;
    NSString *str = self.string;
    [self beginEditing];
    NSUInteger i = range.location;
    while (i < NSMaxRange(range)) {
        NSRange run;
        NSFont *font = [self attribute:NSFontAttributeName atIndex:i longestEffectiveRange:&run inRange:range];
        if (!font) {
            font = UIFDefaultFont();
            [self addAttribute:NSFontAttributeName value:font range:run];
        }
        /* the characters this font has no glyphs for, a stretch at a time */
        CTFontRef ct = (CTFontRef)font;
        NSUInteger j = run.location;
        while (j < NSMaxRange(run)) {
            NSRange seq = [str rangeOfComposedCharacterSequenceAtIndex:j];
            unichar buf[8];
            NSUInteger n = MIN(seq.length, (NSUInteger)8);
            [str getCharacters:buf range:NSMakeRange(seq.location, n)];
            CGGlyph glyphs[8];
            BOOL missing = needs_glyph(buf[0]) && !CTFontGetGlyphsForCharacters(ct, buf, glyphs, (CFIndex)n);
            if (!missing) {
                j = NSMaxRange(seq);
                continue;
            }
            NSUInteger end = NSMaxRange(seq);
            while (end < NSMaxRange(run)) {
                NSRange s2 = [str rangeOfComposedCharacterSequenceAtIndex:end];
                unichar b2[8];
                NSUInteger n2 = MIN(s2.length, (NSUInteger)8);
                [str getCharacters:b2 range:NSMakeRange(s2.location, n2)];
                if (!needs_glyph(b2[0]) || CTFontGetGlyphsForCharacters(ct, b2, glyphs, (CFIndex)n2))
                    break;
                end = NSMaxRange(s2);
            }
            NSRange gap = NSMakeRange(j, end - j);
            CTFontRef fallback = CTFontCreateForString(ct, (CFStringRef)[str substringWithRange:gap], CFRangeMake(0, (CFIndex)gap.length));
            if (fallback) {
                if (!CFEqual(fallback, ct))
                    [self addAttribute:NSFontAttributeName value:(id)fallback range:gap];
                CFRelease(fallback);
            }
            j = end;
        }
        i = NSMaxRange(run);
    }
    [self endEditing];
}

/* As Apple's, the first paragraph takes the style at the range's start, from where that style begins. */
- (void)fixParagraphStyleAttributeInRange:(NSRange)range
{
    NSString *str = self.string;
    NSUInteger len = str.length;
    if (range.location >= len)
        return;
    NSRange all = [str paragraphRangeForRange:NSMakeRange(range.location, MIN(range.length, len - range.location))];
    [self beginEditing];
    NSUInteger i = all.location;
    BOOL first = YES;
    while (i < NSMaxRange(all)) {
        NSRange para = [str paragraphRangeForRange:NSMakeRange(i, 0)];
        if (!para.length)
            break;
        NSUInteger from = first ? range.location : para.location;
        NSRange run;
        id style = [self attribute:NSParagraphStyleAttributeName atIndex:from effectiveRange:&run];
        NSRange span = para;
        if (first) {
            NSUInteger begin = MAX(run.location, para.location);
            span = NSMakeRange(begin, NSMaxRange(para) - begin);
        }
        first = NO;
        if (NSMaxRange(run) < NSMaxRange(span) || run.location > span.location) {
            if (style)
                [self addAttribute:NSParagraphStyleAttributeName value:style range:span];
            else
                [self removeAttribute:NSParagraphStyleAttributeName range:span];
        }
        i = NSMaxRange(para);
    }
    [self endEditing];
}

/* An attachment belongs only on the attachment character. */
- (void)fixAttachmentAttributeInRange:(NSRange)range
{
    NSUInteger len = self.length;
    if (NSMaxRange(range) > len)
        range.length = len > range.location ? len - range.location : 0;
    NSString *str = self.string;
    NSMutableArray *strip = [NSMutableArray array];
    [self enumerateAttribute:NSAttachmentAttributeName inRange:range options:0
                  usingBlock:^(id value, NSRange r, BOOL *stop) {
                    if (!value)
                        return;
                    for (NSUInteger k = r.location; k < NSMaxRange(r); k++)
                        if ([str characterAtIndex:k] != NSAttachmentCharacter)
                            [strip addObject:[NSValue valueWithRange:NSMakeRange(k, 1)]];
                  }];
    for (NSValue *v in strip)
        [self removeAttribute:NSAttachmentAttributeName range:v.rangeValue];
}

- (void)fixAttributesInRange:(NSRange)range
{
    [self fixFontAttributeInRange:range];
    [self fixParagraphStyleAttributeInRange:range];
    [self fixAttachmentAttributeInRange:range];
}

@end

/* The scripting view of a text storage (NSTextStorageScripting.h): its font and colour
   are the first character's, and setting them sets the whole text's. */
@implementation NSTextStorage (FinchScripting)

- (NSFont *)font { return [self length] ? [self attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] : nil; }

- (void)setFont:(NSFont *)font
{
    if (font)
        [self addAttribute:NSFontAttributeName value:font range:NSMakeRange(0, [self length])];
}

- (NSColor *)foregroundColor
{
    return [self length] ? [self attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] : nil;
}

- (void)setForegroundColor:(NSColor *)color
{
    if (color)
        [self addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, [self length])];
}

@end
