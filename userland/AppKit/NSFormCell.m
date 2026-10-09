/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* A form cell draws a title beside its editable value. */
#import "NSControl_Finch.h"

@implementation NSFormCell {
    NSCell *_titleCell;
    id _placeholder;
    CGFloat _titleWidth, _sharedTitleWidth, _preferredWidth;
}
- (instancetype)init { return [self initTextCell:@"Field:"]; }
- (instancetype)initTextCell:(NSString *)title
{
    if (!(self = [super initTextCell:@""])) return nil;
    _titleCell = [[NSCell alloc] initTextCell:title ?: @""]; [_titleCell setAlignment:NSTextAlignmentRight];
    _titleWidth = -1; _preferredWidth = -1;
    [self setEditable:YES]; [self setSelectable:YES]; [self setBezeled:YES]; [self setWraps:YES]; [self setFont:nil];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super initWithCoder:coder])) return nil;
    _titleCell = [[coder decodeObjectForKey:@"NSTitleCell"] retain] ?: [[NSCell alloc] initTextCell:@"Field:"];
    _titleWidth = [coder containsValueForKey:@"NSTitleWidth"] ? [coder decodeDoubleForKey:@"NSTitleWidth"] : -1;
    _preferredWidth = [coder containsValueForKey:@"NSPreferredTextFieldWidth"] ? [coder decodeDoubleForKey:@"NSPreferredTextFieldWidth"] : -1;
    _placeholder = [[coder decodeObjectForKey:@"NSPlaceholderString"] copy]; return self;
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder]; [coder encodeObject:_titleCell forKey:@"NSTitleCell"];
    [coder encodeDouble:_titleWidth forKey:@"NSTitleWidth"]; [coder encodeDouble:_preferredWidth forKey:@"NSPreferredTextFieldWidth"];
    [coder encodeObject:_placeholder forKey:@"NSPlaceholderString"];
}
- (void)dealloc { [_titleCell release]; [_placeholder release]; [super dealloc]; }
- (id)copyWithZone:(NSZone *)zone
{
    NSFormCell *c = [super copyWithZone:zone]; c->_titleCell = [_titleCell copy]; [c->_placeholder retain]; return c;
}
- (NSString *)title { return [_titleCell stringValue]; }
- (void)setTitle:(NSString *)s { [_titleCell setStringValue:s ?: @""]; [self _finchChanged]; }
- (NSAttributedString *)attributedTitle { return [_titleCell attributedStringValue]; }
- (void)setAttributedTitle:(NSAttributedString *)s { [_titleCell setAttributedStringValue:s]; [self _finchChanged]; }
- (NSFont *)titleFont { return [_titleCell font]; }
- (void)setTitleFont:(NSFont *)font { [_titleCell setFont:font]; [self _finchChanged]; }
- (NSTextAlignment)titleAlignment { return [_titleCell alignment]; }
- (void)setTitleAlignment:(NSTextAlignment)a { [_titleCell setAlignment:a]; [self _finchChanged]; }
- (NSWritingDirection)titleBaseWritingDirection { return [_titleCell baseWritingDirection]; }
- (void)setTitleBaseWritingDirection:(NSWritingDirection)d { [_titleCell setBaseWritingDirection:d]; [self _finchChanged]; }
- (CGFloat)_finchNaturalTitleWidth
{
    return _titleWidth >= 0 ? _titleWidth : [[_titleCell attributedStringValue] size].width + 7;
}
- (void)_finchSetSharedTitleWidth:(CGFloat)width { _sharedTitleWidth = width; }
- (CGFloat)titleWidth { return MAX([self _finchNaturalTitleWidth], _sharedTitleWidth); }
- (CGFloat)titleWidth:(NSSize)size { return [self titleWidth]; }
- (void)setTitleWidth:(CGFloat)width { _titleWidth = width; [self _finchChanged]; }
- (CGFloat)preferredTextFieldWidth { return _preferredWidth; }
- (void)setPreferredTextFieldWidth:(CGFloat)width { _preferredWidth = width; [self _finchChanged]; }
- (NSString *)placeholderString { return [_placeholder isKindOfClass:[NSString class]] ? _placeholder : nil; }
- (void)setPlaceholderString:(NSString *)s { id copy = [s copy]; [_placeholder release]; _placeholder = copy; [self _finchChanged]; }
- (NSAttributedString *)placeholderAttributedString { return [_placeholder isKindOfClass:[NSAttributedString class]] ? _placeholder : nil; }
- (void)setPlaceholderAttributedString:(NSAttributedString *)s { id copy = [s copy]; [_placeholder release]; _placeholder = copy; [self _finchChanged]; }
- (void)setTitleWithMnemonic:(NSString *)s { [self setTitle:[s stringByReplacingOccurrencesOfString:@"&" withString:@""]]; }
- (BOOL)isOpaque { return NO; }
- (NSRect)drawingRectForBounds:(NSRect)r { return NSMakeRect(r.origin.x + 2, r.origin.y + 3, MAX(0, r.size.width - 4), MAX(0, r.size.height - 5)); }
- (NSRect)titleRectForBounds:(NSRect)r { return NSInsetRect(r, 3, 3); }
- (NSSize)cellSizeForBounds:(NSRect)r
{
    CGFloat textWidth = _preferredWidth >= 0 ? _preferredWidth : [[self attributedStringValue] size].width;
    CGFloat height = MAX(19, [[_titleCell attributedStringValue] size].height + 3);
    return NSMakeSize([self titleWidth] + textWidth + 12, ceil(height));
}
- (void)drawWithFrame:(NSRect)r inView:(NSView *)view
{
    CGFloat width = MIN([self titleWidth], r.size.width);
    NSRect title = NSMakeRect(r.origin.x, r.origin.y, MAX(0, width - 4), r.size.height);
    FinchDrawCellText([_titleCell attributedStringValue], title, [view isFlipped]);
    NSRect field = NSMakeRect(r.origin.x + width, r.origin.y, MAX(0, r.size.width - width), r.size.height);
    if ([self isBezeled] || [self isBordered]) FinchDrawBezel(field, 2, [NSColor textBackgroundColor], FinchControlStroke());
    if ([self _finchIsEditing]) return;
    NSAttributedString *text = [self attributedStringValue];
    if (![[self stringValue] length] && _placeholder) {
        if ([_placeholder isKindOfClass:[NSAttributedString class]]) text = _placeholder;
        else {
            NSMutableDictionary *attributes = [[[self _finchTextAttributes] mutableCopy] autorelease]; attributes[NSForegroundColorAttributeName] = [NSColor placeholderTextColor];
            text = [[[NSAttributedString alloc] initWithString:_placeholder attributes:attributes] autorelease];
        }
    }
    FinchDrawCellText(text, NSInsetRect(field, 4, 1), [view isFlipped]);
}
- (void)selectWithFrame:(NSRect)r inView:(NSView *)view editor:(NSText *)editor delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length
{
    CGFloat width = MIN([self titleWidth], r.size.width); r.origin.x += width; r.size.width -= width;
    [super selectWithFrame:r inView:view editor:editor delegate:delegate start:start length:length];
}
- (void)editWithFrame:(NSRect)r inView:(NSView *)view editor:(NSText *)editor delegate:(id)delegate event:(NSEvent *)event
{
    CGFloat width = MIN([self titleWidth], r.size.width); r.origin.x += width; r.size.width -= width;
    [super editWithFrame:r inView:view editor:editor delegate:delegate event:event];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityTextFieldRole; }
- (NSString *)accessibilitySubrole { return nil; }
- (NSString *)accessibilityLabel { return [self title]; }
@end
