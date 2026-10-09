/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSecureTextField: a text field that shows bullets. Its cell's background
 * and input sources are Apple's defaults. While it is being edited the
 * field editor shows bullets too, through a secure layout of its own when
 * the field editor has one (Finch's shows the text; see docs/design/APPKIT.md).
 */
#import "NSControl_Finch.h"

@implementation NSSecureTextFieldCell {
    BOOL _plain;
}

- (instancetype)initTextCell:(NSString *)string
{
    self = [super initTextCell:string];
    if (self) {
        [self setBackgroundColor:[NSColor controlBackgroundColor]];
        [self setAllowedInputSourceLocales:@[ NSAllRomanInputSourcesLocaleIdentifier ]];
    }
    return self;
}

- (BOOL)echosBullets { return !_plain; }
- (void)setEchosBullets:(BOOL)flag { _plain = !flag; }

- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)controlView
{
    if ([self _finchIsEditing])
        return;
    NSString *s = [self stringValue];
    if (![s length]) {
        [super drawInteriorWithFrame:frame inView:controlView];
        return;
    }
    NSString *shown = _plain ? @"" : [NSCell _bulletStringForString:s bulletCharacter:0x2022];
    NSAttributedString *a = [[[NSAttributedString alloc] initWithString:shown attributes:[self _finchTextAttributes]]
        autorelease];
    FinchDrawCellText(a, NSInsetRect([self titleRectForBounds:frame], 2, 0), [controlView isFlipped]);
}

@end

@implementation NSSecureTextField

+ (Class)cellClass
{
    return [super cellClass] == [NSTextFieldCell class] || ![super cellClass] ? [NSSecureTextFieldCell class]
                                                                              : [super cellClass];
}

@end
