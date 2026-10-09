/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Tokens store the delegate's objects while drawing their display strings. */
#import "NSTokenField_Finch.h"

NSString *const FinchTokenObjectAttribute = @"FinchTokenObject";

@implementation NSTokenFieldCell {
    NSArray *_objects;
    NSCharacterSet *_tokenizing;
    id _delegate;
    NSTokenStyle _tokenStyle;
    NSTimeInterval _completionDelay;
}
+ (NSCharacterSet *)defaultTokenizingCharacterSet { return [NSCharacterSet characterSetWithCharactersInString:@","]; }
+ (NSTimeInterval)defaultCompletionDelay { return 0; }
- (instancetype)initTextCell:(NSString *)s
{
    if (!(self = [super initTextCell:@""])) return nil;
    _tokenizing = [[[self class] defaultTokenizingCharacterSet] copy]; _objects = [@[] retain];
    [self setEditable:YES]; [self setSelectable:YES]; [self setBezeled:YES]; [self setDrawsBackground:YES];
    [self setWraps:YES]; [self setAllowsEditingTextAttributes:YES]; [self setStringValue:s]; return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder])) return nil;
    _objects = [[coder decodeObjectForKey:@"NS.representedObjects"] copy];
    if (![_objects count]) { [_objects release]; _objects = nil; }
    _tokenizing = [[coder decodeObjectForKey:@"NSTokenizingCharacterSet"] copy] ?: [[[self class] defaultTokenizingCharacterSet] copy];
    _completionDelay = [coder decodeDoubleForKey:@"NSCompletionDelay"];
    _tokenStyle = [coder decodeIntegerForKey:@"NSTokenStyle"]; _delegate = [coder decodeObjectForKey:@"NSDelegate"];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder]; [coder encodeObject:_objects forKey:@"NS.representedObjects"];
    [coder encodeObject:_tokenizing forKey:@"NSTokenizingCharacterSet"]; [coder encodeDouble:_completionDelay forKey:@"NSCompletionDelay"];
    [coder encodeInteger:_tokenStyle forKey:@"NSTokenStyle"]; [coder encodeConditionalObject:_delegate forKey:@"NSDelegate"];
}
- (void)dealloc { [_objects release]; [_tokenizing release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone
{
    NSTokenFieldCell *c = [super copyWithZone:zone]; [c->_objects retain]; [c->_tokenizing retain]; return c;
}
- (NSTokenStyle)tokenStyle { return _tokenStyle; }
- (void)setTokenStyle:(NSTokenStyle)s { _tokenStyle = s; [self _finchChanged]; }
- (NSTimeInterval)completionDelay { return _completionDelay; }
- (void)setCompletionDelay:(NSTimeInterval)t { _completionDelay = t; }
- (NSCharacterSet *)tokenizingCharacterSet { return _tokenizing ?: [[self class] defaultTokenizingCharacterSet]; }
- (void)setTokenizingCharacterSet:(NSCharacterSet *)set
{
    NSCharacterSet *copy = [set copy] ?: [[[self class] defaultTokenizingCharacterSet] copy]; [_tokenizing release]; _tokenizing = copy;
}
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; [self _finchChanged]; }
- (id)_finchControlDelegate
{
    id view = [self controlView]; return [view isKindOfClass:[NSTokenField class]] ? [view delegate] : nil;
}
- (NSString *)_finchDisplayString:(id)object
{
    id d = [self _finchControlDelegate]; NSString *s = nil;
    if ([d respondsToSelector:@selector(tokenField:displayStringForRepresentedObject:)]) s = [d tokenField:(id)[self controlView] displayStringForRepresentedObject:object];
    else if ([_delegate respondsToSelector:@selector(tokenFieldCell:displayStringForRepresentedObject:)]) s = [_delegate tokenFieldCell:self displayStringForRepresentedObject:object];
    return s ?: ([object isKindOfClass:[NSString class]] ? object : [object description]) ?: @"";
}
- (NSString *)_finchEditingString:(id)object
{
    id d = [self _finchControlDelegate]; NSString *s = nil;
    if ([d respondsToSelector:@selector(tokenField:editingStringForRepresentedObject:)]) s = [d tokenField:(id)[self controlView] editingStringForRepresentedObject:object];
    else if ([_delegate respondsToSelector:@selector(tokenFieldCell:editingStringForRepresentedObject:)]) s = [_delegate tokenFieldCell:self editingStringForRepresentedObject:object];
    return s ?: [self _finchDisplayString:object];
}
- (id)_finchRepresentedObject:(NSString *)string
{
    id d = [self _finchControlDelegate]; id object = nil;
    if ([d respondsToSelector:@selector(tokenField:representedObjectForEditingString:)]) object = [d tokenField:(id)[self controlView] representedObjectForEditingString:string];
    else if ([_delegate respondsToSelector:@selector(tokenFieldCell:representedObjectForEditingString:)]) object = [_delegate tokenFieldCell:self representedObjectForEditingString:string];
    return object ?: string;
}
- (NSArray *)_finchShouldAdd:(NSArray *)objects atIndex:(NSUInteger)index
{
    id d = [self _finchControlDelegate]; NSArray *result = objects;
    if ([d respondsToSelector:@selector(tokenField:shouldAddObjects:atIndex:)]) result = [d tokenField:(id)[self controlView] shouldAddObjects:objects atIndex:index];
    else if ([_delegate respondsToSelector:@selector(tokenFieldCell:shouldAddObjects:atIndex:)]) result = [_delegate tokenFieldCell:self shouldAddObjects:objects atIndex:index];
    return [result isKindOfClass:[NSArray class]] ? result : @[];
}
- (NSTokenStyle)_finchStyleForObject:(id)object
{
    id d = [self _finchControlDelegate];
    if ([d respondsToSelector:@selector(tokenField:styleForRepresentedObject:)]) return [d tokenField:(id)[self controlView] styleForRepresentedObject:object];
    if ([_delegate respondsToSelector:@selector(tokenFieldCell:styleForRepresentedObject:)]) return [_delegate tokenFieldCell:self styleForRepresentedObject:object];
    return _tokenStyle;
}
- (NSMenu *)_finchMenuForObject:(id)object
{
    id d = [self _finchControlDelegate];
    if ([d respondsToSelector:@selector(tokenField:hasMenuForRepresentedObject:)] && ![d tokenField:(id)[self controlView] hasMenuForRepresentedObject:object]) return nil;
    if ([d respondsToSelector:@selector(tokenField:menuForRepresentedObject:)]) return [d tokenField:(id)[self controlView] menuForRepresentedObject:object];
    if ([_delegate respondsToSelector:@selector(tokenFieldCell:hasMenuForRepresentedObject:)] && ![_delegate tokenFieldCell:self hasMenuForRepresentedObject:object]) return nil;
    if ([_delegate respondsToSelector:@selector(tokenFieldCell:menuForRepresentedObject:)]) return [_delegate tokenFieldCell:self menuForRepresentedObject:object];
    return nil;
}
- (NSArray *)_finchCompletions:(NSString *)string index:(NSInteger)index selected:(NSInteger *)selected
{
    id d = [self _finchControlDelegate];
    if ([d respondsToSelector:@selector(tokenField:completionsForSubstring:indexOfToken:indexOfSelectedItem:)])
        return [d tokenField:(id)[self controlView] completionsForSubstring:string indexOfToken:index indexOfSelectedItem:selected];
    if ([_delegate respondsToSelector:@selector(tokenFieldCell:completionsForSubstring:indexOfToken:indexOfSelectedItem:)])
        return [_delegate tokenFieldCell:self completionsForSubstring:string indexOfToken:index indexOfSelectedItem:selected];
    return nil;
}
- (id)objectValue { return _objects; }
- (void)setObjectValue:(id)object
{
    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSAttributedString class]]) {
        [self setStringValue:[object isKindOfClass:[NSString class]] ? object : [object string]]; return;
    }
    NSArray *copy = [([object isKindOfClass:[NSArray class]] ? object : object ? @[object] : @[]) copy];
    [_objects release]; _objects = copy; [self _finchChanged];
}
- (NSString *)stringValue
{
    NSMutableArray *strings = [NSMutableArray array];
    for (id object in _objects) [strings addObject:[self _finchDisplayString:object]];
    unichar separator = ',';
    if (![[self tokenizingCharacterSet] characterIsMember:separator])
        for (NSUInteger i = 0; i <= UINT16_MAX; i++) if ([[self tokenizingCharacterSet] characterIsMember:i]) { separator = i; break; }
    return [strings componentsJoinedByString:[NSString stringWithCharacters:&separator length:1]];
}
- (void)setStringValue:(NSString *)string
{
    NSMutableArray *objects = [NSMutableArray array];
    for (NSString *part in [(string ?: @"") componentsSeparatedByCharactersInSet:[self tokenizingCharacterSet]]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed length]) [objects addObject:[self _finchRepresentedObject:trimmed]];
    }
    NSArray *copy = [objects copy]; [_objects release]; _objects = copy; [self _finchChanged];
}
- (NSAttributedString *)attributedStringValue
{
    return [[[NSAttributedString alloc] initWithString:[self stringValue] attributes:[self _finchTextAttributes]] autorelease];
}
- (NSAttributedString *)_finchTokenString:(NSArray *)objects
{
    NSMutableAttributedString *result = [[[NSMutableAttributedString alloc] initWithString:@""] autorelease];
    for (id object in objects) {
        NSMutableDictionary *attributes = [[[self _finchTextAttributes] mutableCopy] autorelease];
        attributes[FinchTokenObjectAttribute] = object;
        [result appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\ufffc" attributes:attributes] autorelease]];
    }
    return result;
}
- (NSArray *)_finchObjectsFromString:(NSAttributedString *)string
{
    NSMutableArray *result = [NSMutableArray array]; NSMutableString *plain = [NSMutableString string];
    for (NSUInteger i = 0; i <= [string length]; i++) {
        id object = i < [string length] ? [string attribute:FinchTokenObjectAttribute atIndex:i effectiveRange:NULL] : nil;
        unichar character = i < [string length] ? [[string string] characterAtIndex:i] : ',';
        if (object || i == [string length] || [[self tokenizingCharacterSet] characterIsMember:character]) {
            NSString *trimmed = [plain stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([trimmed length]) [result addObject:[self _finchRepresentedObject:trimmed]];
            [plain setString:@""]; if (object) [result addObject:object];
        } else [plain appendString:[NSString stringWithCharacters:&character length:1]];
    }
    return result;
}
- (BOOL)_finchTokenizeEditor:(NSTextView *)editor finish:(BOOL)finish
{
    NSAttributedString *source = [[[editor textStorage] copy] autorelease];
    NSMutableAttributedString *result = [[[NSMutableAttributedString alloc] initWithString:@""] autorelease];
    NSMutableString *plain = [NSMutableString string]; NSUInteger tokenIndex = 0, selection = [editor selectedRange].location;
    BOOL changed = NO;
    for (NSUInteger i = 0; i <= [source length]; i++) {
        id object = i < [source length] ? [source attribute:FinchTokenObjectAttribute atIndex:i effectiveRange:NULL] : nil;
        unichar character = i < [source length] ? [[source string] characterAtIndex:i] : ',';
        BOOL delimiter = i < [source length] && [[self tokenizingCharacterSet] characterIsMember:character];
        if (object || delimiter || i == [source length]) {
            NSString *trimmed = [plain stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([trimmed length] && (finish || delimiter || object)) {
                NSArray *objects = [self _finchShouldAdd:@[[self _finchRepresentedObject:trimmed]] atIndex:tokenIndex];
                [result appendAttributedString:[self _finchTokenString:objects]]; tokenIndex += [objects count]; changed = YES;
            } else if ([plain length]) [result appendAttributedString:[[[NSAttributedString alloc] initWithString:plain attributes:[self _finchTextAttributes]] autorelease]];
            if (delimiter) changed = YES;
            [plain setString:@""];
            if (object) { [result appendAttributedString:[source attributedSubstringFromRange:NSMakeRange(i, 1)]]; tokenIndex++; }
            if (i < [editor selectedRange].location) selection = [result length];
        } else [plain appendString:[NSString stringWithCharacters:&character length:1]];
    }
    if (changed) {
        [[editor textStorage] setAttributedString:result];
        [editor setSelectedRange:NSMakeRange(MIN(selection, [result length]), 0)];
        [editor setTypingAttributes:[self _finchTextAttributes]]; [editor setNeedsDisplay:YES];
    }
    return changed;
}
- (void)selectWithFrame:(NSRect)rect inView:(NSView *)view editor:(NSText *)editor delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length
{
    [super selectWithFrame:rect inView:view editor:editor delegate:delegate start:start length:length];
    if ([editor isKindOfClass:[NSTextView class]]) {
        [[(NSTextView *)editor textStorage] setAttributedString:[self _finchTokenString:_objects]];
        [(NSTextView *)editor setTypingAttributes:[self _finchTextAttributes]];
        [editor setSelectedRange:NSMakeRange(0, [[editor string] length])];
    }
}
- (void)editWithFrame:(NSRect)rect inView:(NSView *)view editor:(NSText *)editor delegate:(id)delegate event:(NSEvent *)event
{
    [self selectWithFrame:rect inView:view editor:editor delegate:delegate start:0 length:0];
    if (event) [editor mouseDown:event];
}
- (NSSize)cellSizeForBounds:(NSRect)r
{
    CGFloat width = 16;
    for (id object in _objects) width += [[self _finchDisplayString:object] sizeWithAttributes:[self _finchTextAttributes]].width + 14;
    return NSMakeSize(ceil(width), 24);
}
- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view
{
    if ([self _finchIsEditing]) return;
    if (![_objects count]) { [super drawInteriorWithFrame:frame inView:view]; return; }
    NSRect r = NSInsetRect(frame, 5, 3); CGFloat x = r.origin.x, y = r.origin.y;
    for (id object in _objects) {
        NSString *s = [self _finchDisplayString:object];
        CGFloat width = ceil([s sizeWithAttributes:[self _finchTextAttributes]].width) + 12;
        if (x > r.origin.x && x + width > NSMaxX(r)) { x = r.origin.x; y += 21; }
        NSRect token = NSMakeRect(x, y, MIN(width, r.size.width), 18);
        NSTokenStyle style = [self _finchStyleForObject:object];
        if (style != NSTokenStyleNone && style != NSTokenStylePlainSquared)
            FinchDrawBezel(token, style == NSTokenStyleSquared ? 2 : 8, [FinchAccentColor() colorWithAlphaComponent:0.18], nil);
        NSAttributedString *text = [[[NSAttributedString alloc] initWithString:s attributes:[self _finchTextAttributes]] autorelease];
        FinchDrawCellText(text, NSInsetRect(token, 6, 0), [view isFlipped]); x += width + 3;
    }
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityTextFieldRole; }
- (NSString *)accessibilitySubrole { return nil; }
- (id)accessibilityValue { return [self stringValue]; }
@end
