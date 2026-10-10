/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSTextInputContext: a text input client's link to the system's input methods. Finch
 * has no input methods yet (input sources beyond the U.S. keyboard layout, marked-text
 * composition), so a key event goes straight through the client's key bindings
 * (-interpretKeyEvents:, which inserts text or runs commands), as Apple's context does
 * when no input method takes the event. A view that adopts NSTextInputClient gets one
 * from -inputContext, as on macOS.
 */
#import "AppKit_Finch.h"
#include <objc/runtime.h>

NSNotificationName NSTextInputContextKeyboardSelectionDidChangeNotification =
    @"NSTextInputContextKeyboardSelectionDidChangeNotification";

static NSString *const kUSLayout = @"com.apple.keylayout.US";

@implementation NSTextInputContext {
    __unsafe_unretained id<NSTextInputClient> _client;
    BOOL _acceptsGlyphInfo;
    NSArray *_allowedLocales;
    NSString *_selectedSource;
}

static NSTextInputContext *active_context;

+ (NSTextInputContext *)currentInputContext
{
    NSResponder *r = [[NSApp keyWindow] firstResponder];
    return [r respondsToSelector:@selector(inputContext)] ? [(NSView *)r inputContext] : nil;
}

/* Apple's answers nil for a keyboard layout's identifier, as here. */
+ (NSString *)localizedNameForInputSource:(NSTextInputSourceIdentifier)inputSourceIdentifier
{
    return nil;
}

- (instancetype)initWithClient:(id<NSTextInputClient>)client
{
    if ((self = [super init])) {
        _client = client;
        _selectedSource = [kUSLayout copy];
    }
    return self;
}

- (instancetype)init
{
    [self release];
    return nil; /* NS_UNAVAILABLE: a context needs a client */
}

- (void)dealloc
{
    if (active_context == self)
        active_context = nil;
    [_allowedLocales release];
    [_selectedSource release];
    [super dealloc];
}

- (id<NSTextInputClient>)client { return _client; }
- (BOOL)acceptsGlyphInfo { return _acceptsGlyphInfo; }
- (void)setAcceptsGlyphInfo:(BOOL)flag { _acceptsGlyphInfo = flag; }
- (NSArray<NSString *> *)allowedInputSourceLocales { return _allowedLocales; }
- (void)setAllowedInputSourceLocales:(NSArray<NSString *> *)locales
{
    [_allowedLocales autorelease];
    _allowedLocales = [locales copy];
}

- (void)activate { active_context = self; }
- (void)deactivate
{
    if (active_context == self)
        active_context = nil;
}

/* Key presses go through the client's key bindings; anything else (mouse events, modifier
   changes) is left to the caller, as no input method wants it. */
- (BOOL)handleEvent:(NSEvent *)event
{
    if ([event type] != NSEventTypeKeyDown)
        return NO;
    if ([(id)_client respondsToSelector:@selector(interpretKeyEvents:)]) {
        [(NSResponder *)_client interpretKeyEvents:@[ event ]];
        return YES;
    }
    return NO;
}

- (void)discardMarkedText
{
    if ([(id)_client respondsToSelector:@selector(hasMarkedText)] && [_client hasMarkedText] &&
        [(id)_client respondsToSelector:@selector(unmarkText)])
        [_client unmarkText];
}

- (void)invalidateCharacterCoordinates {}
- (void)textInputClientWillStartScrollingOrZooming {}
- (void)textInputClientDidEndScrollingOrZooming {}
- (void)textInputClientDidUpdateSelection {}
- (void)textInputClientDidScroll {}

- (NSArray<NSTextInputSourceIdentifier> *)keyboardInputSources { return @[ kUSLayout ]; }
- (NSTextInputSourceIdentifier)selectedKeyboardInputSource { return _selectedSource; }

- (void)setSelectedKeyboardInputSource:(NSTextInputSourceIdentifier)source
{
    if (!source || ![[self keyboardInputSources] containsObject:source] || [source isEqualToString:_selectedSource])
        return;
    [_selectedSource autorelease];
    _selectedSource = [source copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSTextInputContextKeyboardSelectionDidChangeNotification
                                                        object:self];
}

@end

static char input_context_key;

@implementation NSView (FinchTextInputContext)

/* A view that adopts NSTextInputClient has a context of its own; others have none. */
- (NSTextInputContext *)inputContext
{
    if (![self conformsToProtocol:@protocol(NSTextInputClient)])
        return nil;
    NSTextInputContext *c = objc_getAssociatedObject(self, &input_context_key);
    if (!c) {
        c = [[[NSTextInputContext alloc] initWithClient:(id<NSTextInputClient>)self] autorelease];
        objc_setAssociatedObject(self, &input_context_key, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return c;
}

@end
