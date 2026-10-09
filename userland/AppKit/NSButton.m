/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSButton: an NSControl over an NSButtonCell. The factories set the type,
 * bezel and line break mode as Apple's do and size the button to fit;
 * radio buttons sharing a superview and an action form a group (in
 * NSButtonCell's -setState:).
 */
#import "NSControl_Finch.h"

@interface NSButtonCell (FinchButton)
- (void)_finchSetImageHugsTitle:(BOOL)flag;
- (BOOL)_finchImageHugsTitle;
@end

@implementation NSButton {
    NSColor *_bezelColor, *_contentTintColor;
    NSImageSymbolConfiguration *_symbolConfiguration;
    NSInteger _maxAcceleratorLevel;
    NSTintProminence _tintProminence;
    NSControlBorderShape _borderShape;
    struct {
        unsigned destructive : 1;
        unsigned springLoaded : 1;
    } _bt;
}

+ (Class)cellClass
{
    return [super cellClass] ?: [NSButtonCell class];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
        [self setTag:-1];
    return self;
}

- (void)dealloc
{
    [_bezelColor release];
    [_contentTintColor release];
    [_symbolConfiguration release];
    [super dealloc];
}

static NSButtonCell *
cell_of(NSButton *b)
{
    id c = [b cell];
    return [c isKindOfClass:[NSButtonCell class]] ? c : nil;
}

#pragma mark Factories

+ (instancetype)buttonWithTitle:(NSString *)title target:(id)target action:(SEL)action
{
    NSButton *b = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [b setTitle:title];
    [b setImageScaling:NSImageScaleProportionallyDown];
    [b setLineBreakMode:NSLineBreakByTruncatingTail];
    [b setTarget:target];
    [b setAction:action];
    [b sizeToFit];
    return b;
}

+ (instancetype)buttonWithImage:(NSImage *)image target:(id)target action:(SEL)action
{
    NSButton *b = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [b setImage:image];
    [b setImagePosition:NSImageOnly];
    [b setImageScaling:NSImageScaleProportionallyDown];
    [b setLineBreakMode:NSLineBreakByTruncatingTail];
    [b setTarget:target];
    [b setAction:action];
    [b sizeToFit];
    return b;
}

+ (instancetype)buttonWithTitle:(NSString *)title image:(NSImage *)image target:(id)target action:(SEL)action
{
    NSButton *b = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [b setTitle:title];
    [b setImage:image];
    [b setImagePosition:NSImageLeading];
    [b setImageScaling:NSImageScaleProportionallyDown];
    [b setLineBreakMode:NSLineBreakByTruncatingTail];
    [b setTarget:target];
    [b setAction:action];
    [b sizeToFit];
    return b;
}

static NSButton *
switch_button(Class cls, NSButtonType type, NSString *title, id target, SEL action)
{
    NSButton *b = [[[cls alloc] initWithFrame:NSZeroRect] autorelease];
    [b setButtonType:type];
    [b setTitle:title];
    [b setBezelStyle:NSBezelStyleFlexiblePush];
    [b setAlignment:NSTextAlignmentNatural];
    [b setImageScaling:NSImageScaleProportionallyDown];
    [b setLineBreakMode:NSLineBreakByTruncatingTail];
    [b setTarget:target];
    [b setAction:action];
    [b sizeToFit];
    return b;
}

+ (instancetype)checkboxWithTitle:(NSString *)title target:(id)target action:(SEL)action
{
    return switch_button(self, NSButtonTypeSwitch, title, target, action);
}

+ (instancetype)radioButtonWithTitle:(NSString *)title target:(id)target action:(SEL)action
{
    return switch_button(self, NSButtonTypeRadio, title, target, action);
}

#pragma mark Forwarding to the cell

- (BOOL)isFlipped { return YES; }
- (void)setButtonType:(NSButtonType)type { [cell_of(self) setButtonType:type]; [self setNeedsDisplay:YES]; }
- (NSString *)title { return [cell_of(self) title]; }
- (void)setTitle:(NSString *)title { [cell_of(self) setTitle:title]; [self setNeedsDisplay:YES]; }
- (NSAttributedString *)attributedTitle { return [cell_of(self) attributedTitle]; }
- (void)setAttributedTitle:(NSAttributedString *)t { [cell_of(self) setAttributedTitle:t]; [self setNeedsDisplay:YES]; }
- (NSString *)alternateTitle { return [cell_of(self) alternateTitle]; }
- (void)setAlternateTitle:(NSString *)t { [cell_of(self) setAlternateTitle:t]; }
- (NSAttributedString *)attributedAlternateTitle { return [cell_of(self) attributedAlternateTitle]; }
- (void)setAttributedAlternateTitle:(NSAttributedString *)t { [cell_of(self) setAttributedAlternateTitle:t]; }
- (NSSound *)sound { return [cell_of(self) sound]; }
- (void)setSound:(NSSound *)sound { [cell_of(self) setSound:sound]; }
- (void)setPeriodicDelay:(float)d interval:(float)i { [cell_of(self) setPeriodicDelay:d interval:i]; }
- (void)getPeriodicDelay:(float *)d interval:(float *)i { [cell_of(self) getPeriodicDelay:d interval:i]; }
- (NSBezelStyle)bezelStyle { return [cell_of(self) bezelStyle]; }
- (void)setBezelStyle:(NSBezelStyle)s { [cell_of(self) setBezelStyle:s]; }
- (BOOL)isBordered { return [[self cell] isBordered]; }
- (void)setBordered:(BOOL)flag { [[self cell] setBordered:flag]; }
- (BOOL)isTransparent { return [cell_of(self) isTransparent]; }
- (void)setTransparent:(BOOL)flag { [cell_of(self) setTransparent:flag]; }
- (BOOL)showsBorderOnlyWhileMouseInside { return [cell_of(self) showsBorderOnlyWhileMouseInside]; }
- (void)setShowsBorderOnlyWhileMouseInside:(BOOL)f { [cell_of(self) setShowsBorderOnlyWhileMouseInside:f]; }
- (NSImage *)image { return [[self cell] image]; }

- (void)setImage:(NSImage *)image
{
    NSButtonCell *c = cell_of(self);
    if (image && [c imagePosition] == NSNoImage)
        [c setImagePosition:NSImageOnly];
    [[self cell] setImage:image];
    [self setNeedsDisplay:YES];
}

- (NSImage *)alternateImage { return [cell_of(self) alternateImage]; }
- (void)setAlternateImage:(NSImage *)image { [cell_of(self) setAlternateImage:image]; }
- (NSCellImagePosition)imagePosition { return [cell_of(self) imagePosition]; }
- (void)setImagePosition:(NSCellImagePosition)p { [cell_of(self) setImagePosition:p]; }
- (NSImageScaling)imageScaling { return [cell_of(self) imageScaling]; }
- (void)setImageScaling:(NSImageScaling)s { [cell_of(self) setImageScaling:s]; }
- (BOOL)imageHugsTitle { return [cell_of(self) _finchImageHugsTitle]; }
- (void)setImageHugsTitle:(BOOL)flag { [cell_of(self) _finchSetImageHugsTitle:flag]; }
- (NSControlStateValue)state { return [[self cell] state]; }
- (void)setState:(NSControlStateValue)state { [[self cell] setState:state]; }
- (BOOL)allowsMixedState { return [[self cell] allowsMixedState]; }
- (void)setAllowsMixedState:(BOOL)flag { [[self cell] setAllowsMixedState:flag]; }
- (void)setNextState { [[self cell] setNextState]; }
- (void)highlight:(BOOL)flag { [[self cell] highlight:flag withFrame:[self bounds] inView:self]; }
- (NSString *)keyEquivalent { return [[self cell] keyEquivalent]; }
- (void)setKeyEquivalent:(NSString *)key { [cell_of(self) setKeyEquivalent:key]; [self setNeedsDisplay:YES]; }
- (NSEventModifierFlags)keyEquivalentModifierMask { return [cell_of(self) keyEquivalentModifierMask]; }
- (void)setKeyEquivalentModifierMask:(NSEventModifierFlags)m { [cell_of(self) setKeyEquivalentModifierMask:m]; }

#pragma mark Button state of its own

- (BOOL)hasDestructiveAction { return _bt.destructive; }
- (void)setHasDestructiveAction:(BOOL)flag { _bt.destructive = flag; }
- (BOOL)isSpringLoaded { return _bt.springLoaded; }
- (void)setSpringLoaded:(BOOL)flag { _bt.springLoaded = flag; }
- (NSInteger)maxAcceleratorLevel { return _maxAcceleratorLevel; }
- (void)setMaxAcceleratorLevel:(NSInteger)level { _maxAcceleratorLevel = level; }
- (NSColor *)bezelColor { return _bezelColor; }

- (void)setBezelColor:(NSColor *)color
{
    [_bezelColor release];
    _bezelColor = [color copy];
    [cell_of(self) setBackgroundColor:color];
    [self setNeedsDisplay:YES];
}

- (NSColor *)contentTintColor { return _contentTintColor; }

- (void)setContentTintColor:(NSColor *)color
{
    [_contentTintColor release];
    _contentTintColor = [color copy];
    [self setNeedsDisplay:YES];
}

- (NSImageSymbolConfiguration *)symbolConfiguration { return _symbolConfiguration; }

- (void)setSymbolConfiguration:(NSImageSymbolConfiguration *)c
{
    [_symbolConfiguration release];
    _symbolConfiguration = [c copy];
}

- (NSTintProminence)tintProminence { return _tintProminence; }
- (void)setTintProminence:(NSTintProminence)p { _tintProminence = p; }
- (NSControlBorderShape)borderShape { return _borderShape; }
- (void)setBorderShape:(NSControlBorderShape)s { _borderShape = s; }

#pragma mark Keys

static NSEventModifierFlags
key_modifiers(NSEventModifierFlags f)
{
    return f & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption |
                NSEventModifierFlagCommand);
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    NSString *key = [self keyEquivalent];
    if (![self isEnabled] || ![key length] || [event type] != NSEventTypeKeyDown)
        return [super performKeyEquivalent:event];
    NSEventModifierFlags mask = key_modifiers([self keyEquivalentModifierMask]);
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars isEqualToString:key] && key_modifiers([event modifierFlags]) == mask) {
        [self performClick:self];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (BOOL)performMnemonic:(NSString *)string { return NO; }

- (void)keyDown:(NSEvent *)event
{
    NSString *c = [event charactersIgnoringModifiers];
    if ([c isEqualToString:@" "] && [self isEnabled]) {
        [self performClick:self];
        return;
    }
    [super keyDown:event];
}

/* A click doesn't take the focus from (say) a text field being edited, as on macOS. */
- (BOOL)_finchBecomesFirstResponderOnClick { return NO; }

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
}

#pragma mark Compression (layout API; nothing to compress yet)

- (void)compressWithPrioritizedCompressionOptions:(NSArray<NSUserInterfaceCompressionOptions *> *)options {}

- (NSSize)minimumSizeWithPrioritizedCompressionOptions:(NSArray<NSUserInterfaceCompressionOptions *> *)options
{
    return [self intrinsicContentSize];
}

- (NSUserInterfaceCompressionOptions *)activeCompressionOptions
{
    return [[[FINCH_CLASS(NSUserInterfaceCompressionOptions) alloc] init] autorelease];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item { return YES; }

@end
