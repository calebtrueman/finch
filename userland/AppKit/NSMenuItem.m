/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSMenuItem: one item of an NSMenu. Behaviour measured against Apple's
 * AppKit (finch-appkit-menu-test): -init makes an item titled "NSMenuItem";
 * states clamp to on, off and mixed; indentation levels clamp to 15 and
 * raise below 0; key-equivalent modifier masks keep the bits from Caps Lock
 * to Help (0x7f0000); a disabled parent item disables what is under it;
 * property changes post NSMenuDidChangeItemNotification through the menu.
 * Archives use Apple's keys (NSTitle, NSKeyEquiv, NSKeyEquivModMask,
 * NSIsDisabled, NSIsSeparator, ...). The state images are Finch's own
 * drawings under Apple's names (NSMenuCheckmark, NSMenuMixedState).
 */
#import "NSMenu_Finch.h"

NSUserInterfaceItemIdentifier const NSMenuItemImportFromDeviceIdentifier = @"NSMenuItemImportFromDeviceIdentifier";

/* Modifier bits an item's key equivalent keeps: Caps Lock to Help. */
#define KE_MASK 0x7f0000ul

static BOOL uses_user_key_equivalents = YES;

@implementation NSMenuItem {
    NSString *_title;
    NSAttributedString *_attributedTitle;
    NSString *_subtitle;
    NSString *_keyEquivalent;
    NSEventModifierFlags _mask;
    NSImage *_image, *_onImage, *_offImage, *_mixedImage;
    NSControlStateValue _state;
    NSInteger _indent;
    __weak id _target;
    SEL _action;
    NSInteger _tag;
    id _representedObject;
    NSMenu *_menu;  /* not retained */
    NSMenu *_submenu;
    NSView *_view;
    NSString *_toolTip;
    NSUserInterfaceItemIdentifier _identifier;
    NSMenuItemBadge *_badge;
    struct {
        unsigned disabled : 1;
        unsigned hidden : 1;
        unsigned alternate : 1;
        unsigned separator : 1;
        unsigned sectionHeader : 1;
        unsigned highlighted : 1;
        unsigned allowsWhenHidden : 1;
        unsigned noLocalization : 1;
        unsigned noMirroring : 1;
    } _f;
}

#pragma mark - The state images

static NSImage *
state_image(NSString *name, NSSize size, void (^draw)(NSRect))
{
    NSImage *i = [NSImage imageWithSize:size flipped:NO
                         drawingHandler:^BOOL(NSRect r) {
                             [[NSColor blackColor] set];
                             draw(r);
                             return YES;
                         }];
    [i setTemplate:YES];
    [i setName:name];
    return [i retain];
}

+ (NSImage *)_finchCheckmarkImage
{
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        image = state_image(@"NSMenuCheckmark", NSMakeSize(18, 17), ^(NSRect r) {
            NSBezierPath *p = [NSBezierPath bezierPath];
            [p moveToPoint:NSMakePoint(5, 8.5)];
            [p lineToPoint:NSMakePoint(8, 5)];
            [p lineToPoint:NSMakePoint(13.5, 12.5)];
            [p setLineWidth:1.8];
            [p setLineCapStyle:NSLineCapStyleRound];
            [p setLineJoinStyle:NSLineJoinStyleRound];
            [p stroke];
        });
    });
    return image;
}

+ (NSImage *)_finchMixedStateImage
{
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        image = state_image(@"NSMenuMixedState", NSMakeSize(18, 5), ^(NSRect r) {
            NSRectFill(NSMakeRect(5, 1.5, 8, 2));
        });
    });
    return image;
}

+ (void)initialize
{
    if (self == [NSMenuItem class]) {
        /* So nibs and archives naming them find them. */
        [self _finchCheckmarkImage];
        [self _finchMixedStateImage];
    }
}

#pragma mark - Creating

+ (BOOL)usesUserKeyEquivalents { return uses_user_key_equivalents; }
+ (void)setUsesUserKeyEquivalents:(BOOL)flag { uses_user_key_equivalents = flag; }

+ (NSMenuItem *)separatorItem
{
    NSMenuItem *i = [[self alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
    i->_f.separator = YES;
    i->_f.disabled = YES;
    return [i autorelease];
}

+ (instancetype)sectionHeaderWithTitle:(NSString *)title
{
    NSMenuItem *i = [[self alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    i->_f.sectionHeader = YES;
    return [i autorelease];
}

+ (NSArray<NSMenuItem *> *)writingToolsItems { return @[]; }

- (instancetype)init
{
    return [self initWithTitle:@"NSMenuItem" action:NULL keyEquivalent:@""];
}

- (instancetype)initWithTitle:(NSString *)string action:(SEL)selector keyEquivalent:(NSString *)charCode
{
    self = [super init];
    if (!self)
        return nil;
    _title = [string ?: @"" copy];
    _action = selector;
    _keyEquivalent = [charCode ?: @"" copy];
    _mask = NSEventModifierFlagCommand;
    _onImage = [[NSMenuItem _finchCheckmarkImage] retain];
    _mixedImage = [[NSMenuItem _finchMixedStateImage] retain];
    return self;
}

- (void)dealloc
{
    [_submenu _finchSetParentItem:nil];
    [_title release];
    [_attributedTitle release];
    [_subtitle release];
    [_keyEquivalent release];
    [_image release];
    [_onImage release];
    [_offImage release];
    [_mixedImage release];
    [_representedObject release];
    [_submenu release];
    [_view release];
    [_toolTip release];
    [_identifier release];
    [_badge release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p %@>", [self class], self, _f.separator ? @"Separator" : _title];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSMenuItem *c = [[[self class] allocWithZone:zone] initWithTitle:_title action:_action keyEquivalent:_keyEquivalent];
    c->_attributedTitle = [_attributedTitle copy];
    c->_subtitle = [_subtitle copy];
    c->_mask = _mask;
    c->_image = [_image retain];
    [c->_onImage release];
    c->_onImage = [_onImage retain];
    c->_offImage = [_offImage retain];
    [c->_mixedImage release];
    c->_mixedImage = [_mixedImage retain];
    c->_state = _state;
    c->_indent = _indent;
    c->_target = _target;
    c->_tag = _tag;
    c->_representedObject = [_representedObject retain];
    c->_toolTip = [_toolTip copy];
    c->_identifier = [_identifier copy];
    c->_badge = [_badge copy];
    c->_f = _f;
    c->_f.highlighted = NO;
    if (_submenu) {
        NSMenu *sub = [_submenu copy];
        c->_submenu = sub;
        [sub _finchSetParentItem:c];
        if (_target == _submenu)
            c->_target = sub;
    }
    if (_view)
        c->_view = [[NSKeyedUnarchiver unarchivedObjectOfClass:[NSView class]
                                                      fromData:[NSKeyedArchiver archivedDataWithRootObject:_view
                                                                                     requiringSecureCoding:NO
                                                                                                     error:NULL]
                                                         error:NULL] retain];
    return c;
}

/* A property changed: the menu tells its observers. */
static void
changed(NSMenuItem *self)
{
    [self->_menu itemChanged:self];
}

#pragma mark - Menus and submenus

- (NSMenu *)menu { return _menu; }

- (void)setMenu:(NSMenu *)menu
{
    _menu = menu;
    if (_submenu)
        [_submenu setSupermenu:menu];
}

- (BOOL)hasSubmenu { return _submenu != nil; }
- (NSMenu *)submenu { return _submenu; }

- (void)setSubmenu:(NSMenu *)submenu
{
    if (submenu == _submenu)
        return;
    NSMenuItem *other = [submenu _finchParentItem];
    if (other && other != self)
        [NSException raise:NSInternalInconsistencyException
                    format:@"Can't assign submenu to menu item %@ because submenu %@ is already assigned to %@", self,
                           submenu, other];
    NSMenu *old = _submenu;
    if (old) {
        [old _finchSetParentItem:nil];
        [old setSupermenu:nil];
        if (_action == @selector(submenuAction:) && _target == old) {
            _action = NULL;
            _target = nil;
        }
    }
    _submenu = [submenu retain];
    if (submenu) {
        [submenu _finchSetParentItem:self];
        if (_menu)
            [submenu setSupermenu:_menu];
        if (!_action) {
            _action = @selector(submenuAction:);
            _target = submenu;
        }
    }
    [old release];
}

- (NSMenuItem *)parentItem
{
    return [_menu _finchParentItem];
}

#pragma mark - Titles

- (NSString *)title { return _title; }

- (void)setTitle:(NSString *)title
{
    if (!title)
        title = @"";
    if ([title isEqualToString:_title])
        return;
    [_title release];
    _title = [title copy];
    changed(self);
}

- (NSAttributedString *)attributedTitle { return _attributedTitle; }

- (void)setAttributedTitle:(NSAttributedString *)title
{
    [_attributedTitle release];
    _attributedTitle = [title copy];
    changed(self);
    if (title)
        [self setTitle:[title string]];
}

- (NSString *)subtitle { return _subtitle; }

- (void)setSubtitle:(NSString *)subtitle
{
    if (subtitle == _subtitle || [subtitle isEqualToString:_subtitle])
        return;
    [_subtitle release];
    _subtitle = [subtitle copy];
    changed(self);
}

- (BOOL)isSeparatorItem { return _f.separator; }
- (BOOL)isSectionHeader { return _f.sectionHeader; }

- (void)setTitleWithMnemonic:(NSString *)string
{
    [self setTitle:[string stringByReplacingOccurrencesOfString:@"&" withString:@""]];
}

- (void)setMnemonicLocation:(NSUInteger)location {}
- (NSUInteger)mnemonicLocation { return NSNotFound; }
- (NSString *)mnemonic { return @""; }

#pragma mark - Key equivalents

- (NSString *)keyEquivalent { return _keyEquivalent; }

- (void)setKeyEquivalent:(NSString *)key
{
    if (!key)
        [NSException raise:NSInternalInconsistencyException format:@"Invalid parameter not satisfying: aKeyEquivalent != nil"];
    if ([key isEqualToString:_keyEquivalent])
        return;
    [_keyEquivalent release];
    _keyEquivalent = [key copy];
    changed(self);
}

- (NSEventModifierFlags)keyEquivalentModifierMask { return _mask; }

- (void)setKeyEquivalentModifierMask:(NSEventModifierFlags)mask
{
    mask &= KE_MASK;
    if (mask == _mask)
        return;
    _mask = mask;
    changed(self);
}

- (NSString *)userKeyEquivalent { return @""; }
- (BOOL)allowsKeyEquivalentWhenHidden { return _f.allowsWhenHidden; }
- (void)setAllowsKeyEquivalentWhenHidden:(BOOL)flag { _f.allowsWhenHidden = flag; }
- (BOOL)allowsAutomaticKeyEquivalentLocalization { return !_f.noLocalization; }
- (void)setAllowsAutomaticKeyEquivalentLocalization:(BOOL)flag { _f.noLocalization = !flag; }
- (BOOL)allowsAutomaticKeyEquivalentMirroring { return !_f.noMirroring; }
- (void)setAllowsAutomaticKeyEquivalentMirroring:(BOOL)flag { _f.noMirroring = !flag; }

#pragma mark - Images and state

- (NSImage *)image { return _image; }

- (void)setImage:(NSImage *)image
{
    if (image == _image)
        return;
    [_image release];
    _image = [image retain];
    changed(self);
}

- (NSControlStateValue)state { return _state; }

- (void)setState:(NSControlStateValue)state
{
    state = state > 0 ? NSControlStateValueOn : state < 0 ? NSControlStateValueMixed : NSControlStateValueOff;
    if (state == _state)
        return;
    _state = state;
    changed(self);
}

- (NSImage *)onStateImage { return _onImage; }

- (void)setOnStateImage:(NSImage *)image
{
    [_onImage release];
    _onImage = [image retain];  /* nil stays nil, as Apple's */
    changed(self);
}

- (NSImage *)offStateImage { return _offImage; }

- (void)setOffStateImage:(NSImage *)image
{
    [_offImage release];
    _offImage = [image retain];
    changed(self);
}

- (NSImage *)mixedStateImage { return _mixedImage; }

- (void)setMixedStateImage:(NSImage *)image
{
    [_mixedImage release];
    _mixedImage = [image retain];
    changed(self);
}

- (NSMenuItemBadge *)badge { return _badge; }
- (void)setBadge:(NSMenuItemBadge *)badge { [_badge autorelease]; _badge = [badge copy]; changed(self); }

#pragma mark - Enabling, hiding

- (BOOL)isEnabled
{
    if (_f.disabled)
        return NO;
    NSMenuItem *parent = [_menu _finchParentItem];
    return parent ? [parent isEnabled] : YES;
}

- (BOOL)_finchOwnEnabled { return !_f.disabled; }

- (void)setEnabled:(BOOL)flag
{
    if (_f.disabled == !flag)
        return;
    _f.disabled = !flag;
    changed(self);
}

- (void)_finchSetEnabled:(BOOL)flag
{
    [self setEnabled:flag];
}

- (BOOL)isHidden { return _f.hidden; }

- (void)setHidden:(BOOL)flag
{
    if (_f.hidden == (unsigned)flag)
        return;
    _f.hidden = flag;
    changed(self);
}

- (BOOL)isHiddenOrHasHiddenAncestor
{
    for (NSMenuItem *i = self; i; i = [i parentItem])
        if ([i isHidden])
            return YES;
    return NO;
}

- (BOOL)isAlternate { return _f.alternate; }

- (void)setAlternate:(BOOL)flag
{
    if (_f.alternate == (unsigned)flag)
        return;
    _f.alternate = flag;
    changed(self);
}

- (BOOL)isHighlighted { return _f.highlighted; }
- (void)_finchSetHighlighted:(BOOL)flag { _f.highlighted = flag; }

- (NSInteger)indentationLevel { return _indent; }

- (void)setIndentationLevel:(NSInteger)level
{
    if (level < 0)
        [NSException raise:NSInvalidArgumentException format:@"Invalid indentation level %ld for menu item %@",
                                                             (long)level, self];
    level = MIN(level, 15);
    if (level == _indent)
        return;
    _indent = level;
    changed(self);
}

#pragma mark - Target, action and the rest

- (id)target { return _target; }
- (void)setTarget:(id)target { _target = target; }
- (SEL)action { return _action; }
- (void)setAction:(SEL)action { _action = action; }
- (NSInteger)tag { return _tag; }
- (void)setTag:(NSInteger)tag { _tag = tag; }
- (id)representedObject { return _representedObject; }
- (void)setRepresentedObject:(id)object { [_representedObject autorelease]; _representedObject = [object retain]; }
- (NSUserInterfaceItemIdentifier)identifier { return _identifier; }
- (void)setIdentifier:(NSUserInterfaceItemIdentifier)identifier { [_identifier autorelease]; _identifier = [identifier copy]; }

- (NSString *)toolTip { return _toolTip; }

- (void)setToolTip:(NSString *)toolTip
{
    if (toolTip == _toolTip || [toolTip isEqualToString:_toolTip])
        return;
    [_toolTip release];
    _toolTip = [toolTip copy];
    changed(self);
}

static char enclosing_key;

- (NSView *)view { return _view; }

- (void)setView:(NSView *)view
{
    if (view == _view)
        return;
    if (_view)
        objc_setAssociatedObject(_view, &enclosing_key, nil, OBJC_ASSOCIATION_ASSIGN);
    [_view release];
    _view = [view retain];
    if (view)
        objc_setAssociatedObject(view, &enclosing_key, self, OBJC_ASSOCIATION_ASSIGN);
    changed(self);
}

#pragma mark - Coding (Apple's keys)

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
        [NSException raise:NSInvalidArgumentException format:@"NSMenuItem only supports keyed coding"];
    [coder encodeConditionalObject:_menu forKey:@"NSMenu"];
    if (_f.disabled)
        [coder encodeBool:YES forKey:@"NSIsDisabled"];
    if (_f.separator)
        [coder encodeBool:YES forKey:@"NSIsSeparator"];
    if (_f.sectionHeader)
        [coder encodeBool:YES forKey:@"NSIsSectionHeader"];
    if (_f.hidden)
        [coder encodeBool:YES forKey:@"NSIsHidden"];
    if (_f.alternate)
        [coder encodeBool:YES forKey:@"NSIsAlternate"];
    if (_f.allowsWhenHidden)
        [coder encodeBool:YES forKey:@"NSKEAllowedWhenHidden"];
    [coder encodeBool:!_f.noLocalization forKey:@"NSAllowsKeyEquivalentLocalization"];
    [coder encodeBool:!_f.noMirroring forKey:@"NSAllowsKeyEquivalentMirroring"];
    [coder encodeObject:_title forKey:@"NSTitle"];
    if (_attributedTitle)
        [coder encodeObject:_attributedTitle forKey:@"NSAttributedTitle"];
    if (_subtitle)
        [coder encodeObject:_subtitle forKey:@"NSSubtitle"];
    [coder encodeObject:_keyEquivalent forKey:@"NSKeyEquiv"];
    if (_mask)
        [coder encodeInteger:(NSInteger)_mask forKey:@"NSKeyEquivModMask"];
    [coder encodeInteger:0x7fffffff forKey:@"NSMnemonicLoc"];
    if (_state)
        [coder encodeInteger:_state forKey:@"NSState"];
    if (_indent)
        [coder encodeInteger:_indent forKey:@"NSIndent"];
    if (_image)
        [coder encodeObject:_image forKey:@"NSImage"];
    if (_onImage)
        [coder encodeObject:_onImage forKey:@"NSOnImage"];
    if (_offImage)
        [coder encodeObject:_offImage forKey:@"NSOffImage"];
    if (_mixedImage)
        [coder encodeObject:_mixedImage forKey:@"NSMixedImage"];
    if (_action)
        [coder encodeObject:NSStringFromSelector(_action) forKey:@"NSAction"];
    if (_target)
        [coder encodeConditionalObject:_target forKey:@"NSTarget"];
    if (_tag)
        [coder encodeInteger:_tag forKey:@"NSTag"];
    if (_representedObject)
        [coder encodeObject:_representedObject forKey:@"NSRepObject"];
    if (_submenu)
        [coder encodeObject:_submenu forKey:@"NSSubmenu"];
    if (_toolTip)
        [coder encodeObject:_toolTip forKey:@"NSToolTip"];
    if (_view)
        [coder encodeObject:_view forKey:@"NSView"];
    if (_identifier)
        [coder encodeObject:_identifier forKey:@"NSUserInterfaceItemIdentifier"];
    [coder encodeBool:NO forKey:@"NSHiddenInRepresentation"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (!self)
        return nil;
    _menu = [coder decodeObjectForKey:@"NSMenu"];
    _f.disabled = [coder decodeBoolForKey:@"NSIsDisabled"];
    _f.separator = [coder decodeBoolForKey:@"NSIsSeparator"];
    _f.sectionHeader = [coder decodeBoolForKey:@"NSIsSectionHeader"];
    _f.hidden = [coder decodeBoolForKey:@"NSIsHidden"];
    _f.alternate = [coder decodeBoolForKey:@"NSIsAlternate"];
    _f.allowsWhenHidden = [coder decodeBoolForKey:@"NSKEAllowedWhenHidden"];
    if ([coder containsValueForKey:@"NSAllowsKeyEquivalentLocalization"])
        _f.noLocalization = ![coder decodeBoolForKey:@"NSAllowsKeyEquivalentLocalization"];
    if ([coder containsValueForKey:@"NSAllowsKeyEquivalentMirroring"])
        _f.noMirroring = ![coder decodeBoolForKey:@"NSAllowsKeyEquivalentMirroring"];
    id title = [coder decodeObjectForKey:@"NSTitle"];
    _title = [[title isKindOfClass:[NSString class]] ? title : @"" copy];
    id attributed = [coder decodeObjectForKey:@"NSAttributedTitle"];
    if ([attributed isKindOfClass:[NSAttributedString class]])
        _attributedTitle = [attributed copy];
    _subtitle = [[coder decodeObjectForKey:@"NSSubtitle"] copy];
    id key = [coder decodeObjectForKey:@"NSKeyEquiv"];
    _keyEquivalent = [[key isKindOfClass:[NSString class]] ? key : @"" copy];
    _mask = (NSEventModifierFlags)[coder decodeIntegerForKey:@"NSKeyEquivModMask"] & KE_MASK;
    NSInteger state = [coder decodeIntegerForKey:@"NSState"];
    _state = state > 0 ? 1 : state < 0 ? -1 : 0;
    _indent = MAX(0, MIN(15, [coder decodeIntegerForKey:@"NSIndent"]));
    id image = [coder decodeObjectForKey:@"NSImage"];
    _image = [image isKindOfClass:[NSImage class]] ? [image retain] : nil;
    image = [coder decodeObjectForKey:@"NSOnImage"];
    _onImage = [[image isKindOfClass:[NSImage class]] ? image : [NSMenuItem _finchCheckmarkImage] retain];
    image = [coder decodeObjectForKey:@"NSOffImage"];
    _offImage = [image isKindOfClass:[NSImage class]] ? [image retain] : nil;
    image = [coder decodeObjectForKey:@"NSMixedImage"];
    _mixedImage = [[image isKindOfClass:[NSImage class]] ? image : [NSMenuItem _finchMixedStateImage] retain];
    NSString *action = [coder decodeObjectForKey:@"NSAction"];
    if ([action isKindOfClass:[NSString class]])
        _action = NSSelectorFromString(action);
    _target = [coder decodeObjectForKey:@"NSTarget"];
    _tag = [coder decodeIntegerForKey:@"NSTag"];
    _representedObject = [[coder decodeObjectForKey:@"NSRepObject"] retain];
    NSMenu *sub = [coder decodeObjectForKey:@"NSSubmenu"];
    if ([sub isKindOfClass:[NSMenu class]]) {
        _submenu = [sub retain];
        [sub _finchSetParentItem:self];
        if (_menu)
            [sub setSupermenu:_menu];
    }
    _toolTip = [[coder decodeObjectForKey:@"NSToolTip"] copy];
    id view = [coder decodeObjectForKey:@"NSView"];
    if ([view isKindOfClass:[NSView class]])
        [self setView:view];
    _identifier = [[coder decodeObjectForKey:@"NSUserInterfaceItemIdentifier"] copy];
    return self;
}

@end

@implementation NSView (NSViewEnclosingMenuItem)

- (NSMenuItem *)enclosingMenuItem
{
    for (NSView *v = self; v; v = [v superview]) {
        NSMenuItem *i = objc_getAssociatedObject(v, &enclosing_key);
        if (i)
            return i;
    }
    return nil;
}

@end

#pragma mark - Key equivalents as shown

static NSString *
key_name(unichar c)
{
    switch (c) {
    case '\r': case 3: return @"↩";
    case '\t': return @"⇥";
    case 0x19: return @"⇤";
    case '\b': case 0x7f: return @"⌫";
    case 0x1b: return @"⎋";
    case ' ': return @"Space";
    case NSDeleteFunctionKey: return @"⌦";
    case NSLeftArrowFunctionKey: return @"←";
    case NSUpArrowFunctionKey: return @"↑";
    case NSRightArrowFunctionKey: return @"→";
    case NSDownArrowFunctionKey: return @"↓";
    case NSPageUpFunctionKey: return @"⇞";
    case NSPageDownFunctionKey: return @"⇟";
    case NSHomeFunctionKey: return @"↖";
    case NSEndFunctionKey: return @"↘";
    case NSClearLineFunctionKey: return @"⌧";
    case NSHelpFunctionKey: return @"Help";
    default:
        if (c >= NSF1FunctionKey && c <= NSF35FunctionKey)
            return [NSString stringWithFormat:@"F%d", c - NSF1FunctionKey + 1];
        return nil;
    }
}

NSString *
FinchMenuKeyEquivalentString(NSMenuItem *item)
{
    NSString *key = [item keyEquivalent];
    if (![key length])
        return @"";
    NSEventModifierFlags m = [item keyEquivalentModifierMask];
    unichar c = [key characterAtIndex:0];
    NSString *shown = [key length] == 1 ? key_name(c) : nil;
    if (!shown) {
        shown = [key uppercaseString];
        /* An upper-case letter means Shift. */
        if (![key isEqualToString:[key lowercaseString]])
            m |= NSEventModifierFlagShift;
    }
    NSMutableString *s = [NSMutableString string];
    if (m & NSEventModifierFlagControl)
        [s appendString:@"⌃"];
    if (m & NSEventModifierFlagOption)
        [s appendString:@"⌥"];
    if (m & NSEventModifierFlagShift)
        [s appendString:@"⇧"];
    if (m & NSEventModifierFlagCommand)
        [s appendString:@"⌘"];
    [s appendString:shown];
    return s;
}
