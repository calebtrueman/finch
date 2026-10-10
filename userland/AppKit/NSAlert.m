/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSAlert (docs/design/APPKIT.md): Apple's API and state, measured on macOS
 * 26, drawn in Finch's own look. The panel is laid out as macOS's classic
 * alert: the icon at the top left, the message in bold beside it, the
 * informative text under it, then the accessory view and the suppression
 * checkbox, and the buttons along the bottom from the right (the first
 * rightmost), with the help button at the bottom left.
 *
 * As Apple's: a new alert has one implicit "OK" button (tag 0) until a
 * button is added; buttons get tags NSAlertFirstButtonReturn + n; a button
 * titled "Cancel" answers Escape, one titled "Don't Save" Command-D, and the
 * first button otherwise Return. -runModal runs the panel app-modally and
 * returns the pressed button's tag (NSAlertFirstButtonReturn for the
 * implicit OK). Finch has no sheet animation: -beginSheetModalForWindow:...
 * shows the panel window-modally over the parent (FinchSheet.m).
 */
#import "FinchPanels.h"

@interface FinchAlertPanel : NSPanel
@end

@implementation FinchAlertPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@implementation NSAlert {
    NSString *_messageText;
    NSString *_informativeText;
    NSImage *_icon;
    NSMutableArray<NSButton *> *_buttons;
    NSButton *_implicitOK;
    NSAlertStyle _style;
    BOOL _showsHelp, _showsSuppression, _laidOut, _modal;
    NSString *_helpAnchor;
    id<NSAlertDelegate> _delegate;
    NSView *_accessory;
    NSButton *_suppression;
    NSButton *_helpButton;
    FinchAlertPanel *_panel;
    NSImageView *_iconView;
    NSTextField *_messageField, *_informativeField;
    NSWindow *_sheetParent;
    void (^_sheetHandler)(NSModalResponse);
    id _legacyDelegate;
    SEL _legacyDidEnd;
    void *_legacyContext;
}

static const CGFloat kWidth = 420, kMargin = 20, kIcon = 64, kButtonHeight = 24, kButtonGap = 12, kMinButton = 82;

static NSButton *
make_button(NSString *title, NSAlert *target)
{
    NSButton *b = [NSButton buttonWithTitle:title target:target action:@selector(buttonPressed:)];
    [b setBezelStyle:NSBezelStylePush];
    return b;
}

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _messageText = @"";
    _informativeText = @"";
    _buttons = [[NSMutableArray alloc] init];
    _implicitOK = [make_button(@"OK", self) retain];
    [_implicitOK setKeyEquivalent:@"\r"];
    [_implicitOK setTag:0];
    _suppression = [[NSButton checkboxWithTitle:@"<Do not show this message again>" target:nil action:NULL] retain];
    _panel = [[FinchAlertPanel alloc] initWithContentRect:NSMakeRect(0, 0, kWidth, 150)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    [_panel setReleasedWhenClosed:NO];
    [_panel setHidesOnDeactivate:NO];
    [_panel setTitle:@""];
    /* no title bar to see, as Apple's: its content runs to the top */
    [_panel setTitlebarAppearsTransparent:YES];
    [_panel setTitleVisibility:NSWindowTitleHidden];
    _iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, kIcon, kIcon)];
    [_iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
    _messageField = [[NSTextField wrappingLabelWithString:@""] retain];
    [_messageField setFont:[NSFont boldSystemFontOfSize:13]];
    _informativeField = [[NSTextField wrappingLabelWithString:@""] retain];
    [_informativeField setFont:[NSFont systemFontOfSize:11]];
    /* the suppression checkbox lives in the panel from the start, as in Apple's nib */
    [_suppression setHidden:YES];
    [[_panel contentView] addSubview:_suppression];
    return self;
}

- (void)dealloc
{
    [_messageText release];
    [_informativeText release];
    [_icon release];
    [_buttons release];
    [_implicitOK release];
    [_helpAnchor release];
    [_accessory release];
    [_suppression release];
    [_helpButton release];
    [_panel release];
    [_iconView release];
    [_messageField release];
    [_informativeField release];
    [_sheetHandler release];
    [super dealloc];
}

#pragma mark Properties

- (NSString *)messageText { return _messageText; }

- (void)setMessageText:(NSString *)text
{
    if (!text)
        [NSException raise:NSInvalidArgumentException format:@"NSConcreteAttributedString initWithString:: nil value"];
    [_messageText autorelease];
    _messageText = [text copy];
    _laidOut = NO;
}

- (NSString *)informativeText { return _informativeText; }

- (void)setInformativeText:(NSString *)text
{
    if (!text)
        [NSException raise:NSInvalidArgumentException format:@"NSConcreteAttributedString initWithString:: nil value"];
    [_informativeText autorelease];
    _informativeText = [text copy];
    _laidOut = NO;
}

- (NSImage *)icon { return _icon ?: FinchApplicationIcon(); }

- (void)setIcon:(NSImage *)icon
{
    [_icon autorelease];
    _icon = [icon retain];
    _laidOut = NO;
}

- (NSAlertStyle)alertStyle { return _style; }
- (void)setAlertStyle:(NSAlertStyle)style { _style = style; _laidOut = NO; }
- (BOOL)showsHelp { return _showsHelp; }
- (void)setShowsHelp:(BOOL)flag { _showsHelp = flag; _laidOut = NO; }
- (NSHelpAnchorName)helpAnchor { return _helpAnchor; }
- (void)setHelpAnchor:(NSHelpAnchorName)anchor { [_helpAnchor autorelease]; _helpAnchor = [anchor copy]; }
- (id<NSAlertDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSAlertDelegate>)delegate { _delegate = delegate; }
- (NSView *)accessoryView { return _accessory; }

- (void)setAccessoryView:(NSView *)view
{
    [_accessory removeFromSuperview];
    [_accessory autorelease];
    _accessory = [view retain];
    _laidOut = NO;
}

- (BOOL)showsSuppressionButton { return _showsSuppression; }
- (void)setShowsSuppressionButton:(BOOL)flag { _showsSuppression = flag; _laidOut = NO; }
- (NSButton *)suppressionButton { return _suppression; }
- (NSWindow *)window { return _panel; }

- (NSArray<NSButton *> *)buttons
{
    return _buttons.count ? [[_buttons copy] autorelease] : @[ _implicitOK ];
}

/* Apple's key equivalents by title; the first button answers Return otherwise. */
- (NSButton *)addButtonWithTitle:(NSString *)title
{
    NSButton *b = make_button(title ?: @"", self);
    NSUInteger n = _buttons.count;
    [b setTag:NSAlertFirstButtonReturn + n];
    if ([title isEqualToString:@"Cancel"])
        [b setKeyEquivalent:@"\033"];
    else if ([title isEqualToString:@"Don't Save"] || [title isEqualToString:@"Don’t Save"]) {
        [b setKeyEquivalent:@"d"];
        [b setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    } else if (n == 0)
        [b setKeyEquivalent:@"\r"];
    [_buttons addObject:b];
    _laidOut = NO;
    return b;
}

#pragma mark Making alerts

+ (NSAlert *)alertWithError:(NSError *)error
{
    NSAlert *a = [[[self alloc] init] autorelease];
    [a setAlertStyle:NSAlertStyleCritical];
    [a setMessageText:[error localizedDescription] ?: @""];
    [a setInformativeText:[error localizedRecoverySuggestion] ?: @""];
    for (NSString *option in [error localizedRecoveryOptions])
        [a addButtonWithTitle:option];
    NSString *anchor = [error userInfo][NSHelpAnchorErrorKey];
    if (anchor) {
        [a setHelpAnchor:anchor];
        [a setShowsHelp:YES];
    }
    return a;
}

+ (NSAlert *)alertWithMessageText:(NSString *)message defaultButton:(NSString *)defaultButton
                  alternateButton:(NSString *)alternateButton otherButton:(NSString *)otherButton
        informativeTextWithFormat:(NSString *)format, ...
{
    NSAlert *a = [[[self alloc] init] autorelease];
    [a setMessageText:message ?: @""];
    if (format) {
        va_list ap;
        va_start(ap, format);
        NSString *s = [[NSString alloc] initWithFormat:format arguments:ap];
        va_end(ap);
        [a setInformativeText:s];
        [s release];
    }
    /* Apple's order: default, other, alternate, tagged with the old return codes */
    [[a addButtonWithTitle:defaultButton ?: @"OK"] setTag:NSAlertDefaultReturn];
    if (otherButton)
        [[a addButtonWithTitle:otherButton] setTag:NSAlertOtherReturn];
    if (alternateButton)
        [[a addButtonWithTitle:alternateButton] setTag:NSAlertAlternateReturn];
    return a;
}

#pragma mark Layout

static CGFloat
text_height(NSString *s, NSFont *font, CGFloat width)
{
    if (!s.length)
        return 0;
    NSRect r = [s boundingRectWithSize:NSMakeSize(width, 10000)
                               options:NSStringDrawingUsesLineFragmentOrigin
                            attributes:@{NSFontAttributeName : font}];
    return ceil(r.size.height);
}

static CGFloat
button_width(NSButton *b)
{
    NSFont *f = [b font] ?: [NSFont systemFontOfSize:13];
    CGFloat w = ceil([[b title] sizeWithAttributes:@{NSFontAttributeName : f}].width) + 32;
    return MAX(kMinButton, w);
}

- (NSImage *)_finchIconToShow
{
    NSImage *icon = [self icon];
    if (_style != NSAlertStyleCritical)
        return icon;
    /* critical: Finch's caution sign, the app's icon as a badge */
    return [NSImage imageWithSize:NSMakeSize(kIcon, kIcon) flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                       [FinchIconImage(FinchIconCaution, kIcon) drawInRect:r];
                       [icon drawInRect:NSMakeRect(NSMaxX(r) - 30, r.origin.y, 30, 30) fromRect:NSZeroRect
                              operation:NSCompositingOperationSourceOver fraction:1];
                       return YES;
                   }];
}

- (void)layout
{
    NSArray<NSButton *> *buttons = [self buttons];
    CGFloat buttonsWidth = 0;
    for (NSButton *b in buttons)
        buttonsWidth += button_width(b) + (buttonsWidth > 0 ? kButtonGap : 0);
    CGFloat helpWidth = _showsHelp ? 24 + kButtonGap * 2 : 0;
    CGFloat width = MAX(kWidth, buttonsWidth + helpWidth + kMargin * 2);
    CGFloat textX = kMargin + kIcon + 16, textW = width - textX - kMargin;

    /* as Apple's: the nib's placeholder title until laid out, then a shorter one beside two or more buttons */
    NSString *st = [_suppression title];
    if (_showsSuppression && ([st isEqualToString:@"<Do not show this message again>"] ||
                              [st isEqualToString:@"Do not show this message again"] ||
                              [st isEqualToString:@"Don\u2019t ask again"]))
        [_suppression setTitle:buttons.count > 1 ? @"Don\u2019t ask again" : @"Do not show this message again"];

    /* top-down heights */
    CGFloat mh = MAX(text_height(_messageText, [_messageField font], textW), 16);
    CGFloat ih = text_height(_informativeText, [_informativeField font], textW);
    CGFloat textBlock = mh + (ih ? 8 + ih : 0);
    if (_accessory)
        textBlock += 12 + [_accessory frame].size.height;
    if (_showsSuppression)
        textBlock += 12 + 18;
    CGFloat upper = MAX(textBlock, kIcon);
    CGFloat height = 20 + upper + 20 + kButtonHeight + 18;

    NSView *content = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)] autorelease];
    CGFloat top = height - 20;
    [_iconView setFrame:NSMakeRect(kMargin, top - kIcon, kIcon, kIcon)];
    [_iconView setImage:[self _finchIconToShow]];
    [content addSubview:_iconView];
    [_messageField setStringValue:_messageText];
    [_messageField setFrame:NSMakeRect(textX, top - mh, textW, mh)];
    [content addSubview:_messageField];
    CGFloat y = top - mh;
    if (ih) {
        [_informativeField setStringValue:_informativeText];
        [_informativeField setFrame:NSMakeRect(textX, y - 8 - ih, textW, ih)];
        [content addSubview:_informativeField];
        y -= 8 + ih;
    }
    if (_accessory) {
        NSRect f = [_accessory frame];
        y -= 12 + f.size.height;
        [_accessory setFrameOrigin:NSMakePoint(textX, y)];
        [content addSubview:_accessory];
    }
    [_suppression setHidden:!_showsSuppression];
    [content addSubview:_suppression];
    if (_showsSuppression) {
        y -= 12 + 18;
        [_suppression setFrame:NSMakeRect(textX, y, textW, 18)];
        [content addSubview:_suppression];
    }
    CGFloat x = width - kMargin;
    for (NSButton *b in buttons) {
        CGFloat w = button_width(b);
        x -= w;
        [b setFrame:NSMakeRect(x, 18, w, kButtonHeight)];
        [content addSubview:b];
        x -= kButtonGap;
    }
    if (_showsHelp) {
        if (!_helpButton) {
            _helpButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 24, 24)];
            [_helpButton setBezelStyle:NSBezelStyleHelpButton];
            [_helpButton setTitle:@"?"];
            [_helpButton setTarget:self];
            [_helpButton setAction:@selector(_finchHelp:)];
        }
        [_helpButton setFrame:NSMakeRect(kMargin, 18, 24, 24)];
        [content addSubview:_helpButton];
    }
    NSRect frame = [_panel frameRectForContentRect:NSMakeRect(0, 0, width, height)];
    NSRect old = [_panel frame];
    frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
    [_panel setFrame:frame display:NO];
    [_panel setContentView:content];
    [_panel setInitialFirstResponder:nil];
    _laidOut = YES;
}

#pragma mark Running

- (void)_finchHelp:(id)sender
{
    if ([(id)_delegate respondsToSelector:@selector(alertShowHelp:)] && [_delegate alertShowHelp:self])
        return;
    NSHelpManager *hm = [(id)objc_getClass("NSHelpManager") sharedHelpManager];
    if (_helpAnchor && hm)
        [hm openHelpAnchor:_helpAnchor inBook:nil];
}

- (void)buttonPressed:(id)sender
{
    NSModalResponse code = sender == _implicitOK ? NSAlertFirstButtonReturn : [sender tag];
    if (_sheetParent) {
        [_sheetParent endSheet:_panel returnCode:code];
        return;
    }
    if (_modal)
        [NSApp stopModalWithCode:code];
}

- (NSModalResponse)runModal
{
    if (!_laidOut)
        [self layout];
    [_panel center];
    [_panel setLevel:NSModalPanelWindowLevel];
    _modal = YES;
    NSModalResponse r = [NSApp runModalForWindow:_panel];
    _modal = NO;
    [_panel orderOut:nil];
    return r;
}

- (void)beginSheetModalForWindow:(NSWindow *)sheetWindow completionHandler:(void (^)(NSModalResponse))handler
{
    if (!sheetWindow) {
        NSModalResponse r = [self runModal];
        if (handler)
            handler(r);
        if (_legacyDelegate && _legacyDidEnd)
            ((void (*)(id, SEL, NSAlert *, NSInteger, void *))objc_msgSend)(_legacyDelegate, _legacyDidEnd, self, r,
                                                                             _legacyContext);
        _legacyDelegate = nil;
        _legacyDidEnd = NULL;
        return;
    }
    if (!_laidOut)
        [self layout];
    [_panel setLevel:NSNormalWindowLevel];
    _sheetParent = sheetWindow;
    [self retain];  /* until the sheet ends, as Apple's */
    [_sheetHandler release];
    _sheetHandler = [handler copy];
    [sheetWindow beginSheet:_panel
          completionHandler:^(NSModalResponse r) {
              _sheetParent = nil;
              void (^h)(NSModalResponse) = _sheetHandler;
              _sheetHandler = nil;
              if (h)
                  h(r);
              [h release];
              if (_legacyDelegate && _legacyDidEnd)
                  ((void (*)(id, SEL, NSAlert *, NSInteger, void *))objc_msgSend)(_legacyDelegate, _legacyDidEnd, self, r,
                                                                                   _legacyContext);
              _legacyDelegate = nil;
              _legacyDidEnd = NULL;
              [self autorelease];
          }];
}

- (void)beginSheetModalForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)didEndSelector
                     contextInfo:(void *)contextInfo
{
    _legacyDelegate = delegate;
    _legacyDidEnd = didEndSelector;
    _legacyContext = contextInfo;
    [self beginSheetModalForWindow:window completionHandler:nil];
}

@end
