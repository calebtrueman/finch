/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSFontManager: the fonts installed, grouped into families, and turning
 * one font into another (a trait, a weight, a size, another family or
 * face), for the Font menu and the font panel. Its action (changeFont:)
 * goes up the responder chain; the receiver asks -convertFont: what its
 * font becomes, which depends on what the user did (-currentFontAction).
 *
 * Fonts come from CoreText. A family's members are described as Apple's:
 * [PostScript name, face name, weight, traits], the face name from the font's
 * typographic subfamily (name ID 17, else 2), the weight on AppKit's 0-15
 * scale from the face name (UltraLight 2, Thin/ExtraLight/Light 3, Regular 5,
 * Medium 6, SemiBold 8, Bold 9, Heavy 10, ExtraBold 11, Black 14; otherwise
 * from OS/2's weight class), bold meaning a weight of SemiBold or more, and
 * the members listed regular weight first, then by weight, upright before
 * italic. Picking a member for a family, traits and weight takes the nearest
 * weight among those with the traits (a bold request asks for Bold or
 * heavier), a tie going to the one nearer Regular.
 *
 * As measured on macOS 26 (appkit-bindings-test.m): the trait actions reset
 * -currentFontAction once the action is sent; asking for Unbold or Unitalic
 * in -fontNamed:hasTraits: or -availableFontNamesWithTraits: matches nothing;
 * -convertFont:toFace: with an unknown face gives the font back.
 */
#import "AppKit_Finch.h"
#import <CoreText/CoreText.h>

/* A member of a family, as found. */
@interface _FinchFontMember : NSObject {
@public
    NSString *_name, *_face, *_family;
    NSInteger _weight, _weightClass;
    NSFontTraitMask _traits;
    CGFloat _width;
}
@end

@implementation _FinchFontMember
- (void)dealloc
{
    [_name release];
    [_face release];
    [_family release];
    [super dealloc];
}
@end

#pragma mark - Reading fonts

static uint16_t
be16(const uint8_t *p)
{
    return (uint16_t)(p[0] << 8 | p[1]);
}

/* A name from the 'name' table: Windows English (UTF-16BE) first, then Mac Roman. */
static NSString *
font_name(CTFontRef font, uint16_t nameID)
{
    CFDataRef table = CTFontCopyTable(font, kCTFontTableName, kCTFontTableOptionNoOptions);
    if (!table)
        return nil;
    const uint8_t *d = CFDataGetBytePtr(table);
    CFIndex len = CFDataGetLength(table);
    NSString *found = nil;
    if (len >= 6) {
        uint16_t count = be16(d + 2), strings = be16(d + 4);
        int best = 0;
        for (uint16_t i = 0; i < count && 6 + 12 * (CFIndex)(i + 1) <= len; i++) {
            const uint8_t *r = d + 6 + 12 * i;
            uint16_t platform = be16(r), encoding = be16(r + 2), lang = be16(r + 4), nid = be16(r + 6);
            uint16_t length = be16(r + 8), offset = be16(r + 10);
            if (nid != nameID || strings + offset + length > len)
                continue;
            int score = platform == 3 && (encoding == 1 || encoding == 10) ? (lang == 0x409 ? 3 : 2)
                        : platform == 0                                      ? 2
                        : platform == 1 && encoding == 0 && lang == 0        ? 1
                                                                             : 0;
            if (score <= best)
                continue;
            NSString *s = [[NSString alloc] initWithBytes:d + strings + offset length:length
                                                 encoding:platform == 1 ? NSMacOSRomanStringEncoding
                                                                        : NSUTF16BigEndianStringEncoding];
            if (s) {
                [found release];
                found = s;
                best = score;
            }
        }
    }
    CFRelease(table);
    return [found autorelease];
}

static uint16_t
weight_class(CTFontRef font)
{
    CFDataRef table = CTFontCopyTable(font, kCTFontTableOS2, kCTFontTableOptionNoOptions);
    uint16_t wc = 400;
    if (table && CFDataGetLength(table) >= 6)
        wc = be16(CFDataGetBytePtr(table) + 4);
    if (table)
        CFRelease(table);
    return wc;
}

/* AppKit's weight for a face name, or -1. */
static NSInteger
weight_for_face(NSString *face)
{
    NSString *f = [[[face lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""]
        stringByReplacingOccurrencesOfString:@"-"
                                  withString:@""];
    static const struct {
        const char *word;
        NSInteger weight;
    } words[] = {
        {"ultralight", 2}, {"extralight", 3}, {"thin", 3},      {"light", 3},     {"semibold", 8}, {"demibold", 8},
        {"extrabold", 11}, {"ultrabold", 11}, {"bold", 9},       {"heavy", 10},    {"black", 14},   {"medium", 6},
        {"book", 5},       {"regular", 5},    {"roman", 5},      {"plain", 5},     {"normal", 5},
    };
    for (size_t i = 0; i < sizeof words / sizeof *words; i++)
        if ([f rangeOfString:@(words[i].word)].location != NSNotFound)
            return words[i].weight;
    return -1;
}

static NSInteger
weight_for_class(uint16_t wc)
{
    if (wc <= 150)
        return 3;
    if (wc <= 350)
        return 3;
    if (wc <= 450)
        return 5;
    if (wc <= 550)
        return 6;
    if (wc <= 650)
        return 8;
    if (wc <= 750)
        return 9;
    if (wc <= 850)
        return 11;
    return 14;
}

static _FinchFontMember *
member_for_font(CTFontRef font)
{
    _FinchFontMember *m = [[[_FinchFontMember alloc] init] autorelease];
    m->_name = (NSString *)CTFontCopyPostScriptName(font);
    m->_family = (NSString *)CTFontCopyFamilyName(font);
    NSString *face = font_name(font, 17) ?: font_name(font, 2);
    if (!face)
        face = [(NSString *)CTFontCopyName(font, kCTFontStyleNameKey) autorelease];
    m->_face = [face ?: @"Regular" copy];
    m->_weightClass = weight_class(font);
    NSInteger w = weight_for_face(m->_face);
    m->_weight = w >= 0 ? w : weight_for_class((uint16_t)m->_weightClass);
    CTFontSymbolicTraits sym = CTFontGetSymbolicTraits(font);
    NSFontTraitMask t = 0;
    if (sym & kCTFontTraitItalic)
        t |= NSItalicFontMask;
    if (m->_weight >= 7)
        t |= NSBoldFontMask;
    if (sym & kCTFontTraitMonoSpace)
        t |= NSFixedPitchFontMask;
    if (sym & kCTFontTraitCondensed)
        t |= NSCondensedFontMask;
    if (sym & kCTFontTraitExpanded)
        t |= NSExpandedFontMask;
    if ([[m->_face lowercaseString] rangeOfString:@"thin"].location != NSNotFound)
        t |= 0x10000; /* as Apple's: thin faces carry an unnamed trait */
    m->_traits = t;
    NSDictionary *traits = [(NSDictionary *)CTFontCopyTraits(font) autorelease];
    m->_width = [[traits objectForKey:(id)kCTFontWidthTrait] doubleValue];
    return m;
}

#pragma mark - The catalogue

static NSMutableDictionary *families_cache; /* family -> sorted members */
static NSMutableDictionary *members_by_name;
static NSArray *names_cache;

static NSInteger
member_order(id x, id y, void *context)
{
    _FinchFontMember *a = x, *b = y;
    int ar = a->_weight != 5, br = b->_weight != 5;
    if (a->_width != b->_width)
        return a->_width < b->_width ? NSOrderedAscending : NSOrderedDescending;
    if (ar != br)
        return ar < br ? NSOrderedAscending : NSOrderedDescending;
    if (a->_weightClass != b->_weightClass)
        return a->_weightClass < b->_weightClass ? NSOrderedAscending : NSOrderedDescending;
    if (a->_weight != b->_weight)
        return a->_weight < b->_weight ? NSOrderedAscending : NSOrderedDescending;
    int ai = (a->_traits & NSItalicFontMask) != 0, bi = (b->_traits & NSItalicFontMask) != 0;
    if (ai != bi)
        return ai < bi ? NSOrderedAscending : NSOrderedDescending;
    return [a->_name compare:b->_name];
}

/* Build (again, when the fonts installed have changed) the families and their members. */
static void
load_catalogue(void)
{
    NSArray *names = [(NSArray *)CTFontManagerCopyAvailablePostScriptNames() autorelease];
    @synchronized([NSFontManager class]) {
        if (names_cache && [names_cache isEqualToArray:names])
            return;
        [names_cache release];
        names_cache = [names copy];
        [families_cache release];
        families_cache = [[NSMutableDictionary alloc] init];
        [members_by_name release];
        members_by_name = [[NSMutableDictionary alloc] init];
        for (NSString *n in names) {
            if ([n hasPrefix:@"."])
                continue;
            CTFontRef f = CTFontCreateWithName((CFStringRef)n, 12, NULL);
            if (!f)
                continue;
            _FinchFontMember *m = member_for_font(f);
            CFRelease(f);
            if (![m->_name isEqualToString:n] || !m->_family)
                continue;
            [members_by_name setObject:m forKey:n];
            NSMutableArray *fam = [families_cache objectForKey:m->_family];
            if (!fam) {
                fam = [NSMutableArray array];
                [families_cache setObject:fam forKey:m->_family];
            }
            [fam addObject:m];
        }
        for (NSMutableArray *fam in [families_cache allValues])
            [fam sortUsingFunction:member_order context:NULL];
    }
}

static NSArray *
family_members(NSString *family)
{
    load_catalogue();
    @synchronized([NSFontManager class]) {
        return [[[families_cache objectForKey:family] copy] autorelease];
    }
}

static _FinchFontMember *
member_named(NSString *name)
{
    load_catalogue();
    @synchronized([NSFontManager class]) {
        return [[[members_by_name objectForKey:name] retain] autorelease];
    }
}

static _FinchFontMember *
member_of(NSFont *font)
{
    if (!font)
        return nil;
    _FinchFontMember *m = member_named([font fontName]);
    return m ?: member_for_font((CTFontRef)font);
}

/* The family member with the traits, nearest the weight. */
static _FinchFontMember *
pick_member(NSString *family, NSFontTraitMask traits, NSInteger weight, BOOL raiseBold)
{
    NSArray *members = family_members(family);
    if (![members count])
        return nil;
    BOOL wantItalic = (traits & NSItalicFontMask) != 0, wantBold = (traits & NSBoldFontMask) != 0;
    NSFontTraitMask other = traits & (NSFixedPitchFontMask | NSCondensedFontMask | NSExpandedFontMask | NSNarrowFontMask);
    if (wantBold && raiseBold && weight < 9)
        weight = 9;
    _FinchFontMember *best = nil;
    NSInteger bestDistance = NSIntegerMax, bestFromRegular = NSIntegerMax;
    for (int pass = 0; pass < 2 && !best; pass++) {
        for (_FinchFontMember *m in members) {
            if (((m->_traits & NSItalicFontMask) != 0) != wantItalic)
                continue;
            if (wantBold && !(m->_traits & NSBoldFontMask))
                continue;
            if (pass == 0 && (m->_traits & other) != other)
                continue;
            NSInteger d = labs(m->_weight - weight), r = labs(m->_weight - 5);
            if (d < bestDistance || (d == bestDistance && r < bestFromRegular)) {
                best = m;
                bestDistance = d;
                bestFromRegular = r;
            }
        }
    }
    return best;
}

static NSFont *
font_for_member(_FinchFontMember *m, CGFloat size)
{
    return m ? [NSFont fontWithName:m->_name size:size] : nil;
}

#pragma mark - NSFontManager

static Class managerFactory, panelFactory;
static NSFontManager *sharedManager;

@implementation NSFontManager {
    NSFont *_selectedFont;
    BOOL _multiple, _disabled;
    SEL _action;
    id _target, _delegate;
    NSFontAction _currentAction;
    NSFontTraitMask _currentTrait;
    NSMenu *_fontMenu;
    NSMutableDictionary *_collections;
}

+ (void)setFontManagerFactory:(Class)factoryId { managerFactory = factoryId; }
+ (void)setFontPanelFactory:(Class)factoryId { panelFactory = factoryId; }
+ (Class)_finchFontPanelFactory { return panelFactory; }

+ (NSFontManager *)sharedFontManager
{
    @synchronized(self) {
        if (!sharedManager)
            sharedManager = [[(managerFactory ?: [NSFontManager class]) alloc] init];
    }
    return sharedManager;
}

- (instancetype)init
{
    self = [super init];
    if (self)
        _action = @selector(changeFont:);
    return self;
}

- (void)dealloc
{
    [_selectedFont release];
    [_fontMenu release];
    [_collections release];
    [super dealloc];
}

#pragma mark Selection and action

- (BOOL)isMultiple { return _multiple; }
- (NSFont *)selectedFont { return _selectedFont; }

- (void)setSelectedFont:(NSFont *)font isMultiple:(BOOL)flag
{
    [font retain];
    [_selectedFont release];
    _selectedFont = font;
    _multiple = flag;
    if ([NSFontPanel sharedFontPanelExists])
        [[NSFontPanel sharedFontPanel] setPanelFont:font isMultiple:flag];
}

- (void)setSelectedAttributes:(NSDictionary<NSString *, id> *)attributes isMultiple:(BOOL)flag
{
    NSFont *f = [attributes objectForKey:NSFontAttributeName];
    if (f)
        [self setSelectedFont:f isMultiple:flag];
}

- (BOOL)isEnabled { return !_disabled; }
- (void)setEnabled:(BOOL)flag
{
    _disabled = !flag;
    if ([NSFontPanel sharedFontPanelExists])
        [[NSFontPanel sharedFontPanel] setEnabled:flag];
}
- (SEL)action { return _action; }
- (void)setAction:(SEL)action { _action = action; }
- (id)target { return _target; }
- (void)setTarget:(id)target { _target = target; }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)delegate { _delegate = delegate; }
- (NSFontAction)currentFontAction { return _currentAction; }

- (BOOL)sendAction
{
    if (!_action)
        return NO;
    return [NSApp sendAction:_action to:_target from:self];
}

/* Send the action for one user action, then forget it (as Apple's). */
- (void)_finchSendAction:(NSFontAction)action trait:(NSFontTraitMask)trait
{
    _currentAction = action;
    _currentTrait = trait;
    [self sendAction];
    _currentAction = NSNoFontChangeAction;
    _currentTrait = 0;
}

- (void)addFontTrait:(id)sender
{
    [self _finchSendAction:NSAddTraitFontAction trait:(NSFontTraitMask)[sender tag]];
}

- (void)removeFontTrait:(id)sender
{
    [self _finchSendAction:NSRemoveTraitFontAction trait:(NSFontTraitMask)[sender tag]];
}

- (void)modifyFont:(id)sender
{
    [self _finchSendAction:(NSFontAction)[sender tag] trait:0];
}

- (void)modifyFontViaPanel:(id)sender
{
    [self _finchSendAction:NSViaPanelFontAction trait:0];
}

- (NSFontTraitMask)convertFontTraits:(NSFontTraitMask)traits
{
    return traits;
}

- (NSFont *)convertFont:(NSFont *)font
{
    if (!font)
        return nil;
    NSFont *f = font;
    switch (_currentAction) {
    case NSAddTraitFontAction:
        f = [self convertFont:font toHaveTrait:_currentTrait];
        break;
    case NSRemoveTraitFontAction:
        f = [self convertFont:font toNotHaveTrait:_currentTrait];
        break;
    case NSSizeUpFontAction:
        f = [self convertFont:font toSize:[font pointSize] + 1];
        break;
    case NSSizeDownFontAction:
        f = [self convertFont:font toSize:MAX(1, [font pointSize] - 1)];
        break;
    case NSHeavierFontAction:
        f = [self convertWeight:YES ofFont:font];
        break;
    case NSLighterFontAction:
        f = [self convertWeight:NO ofFont:font];
        break;
    case NSViaPanelFontAction:
        if ([NSFontPanel sharedFontPanelExists])
            f = [[NSFontPanel sharedFontPanel] panelConvertFont:font];
        break;
    default:
        break;
    }
    return f ?: font;
}

- (NSDictionary<NSString *, id> *)convertAttributes:(NSDictionary<NSString *, id> *)attributes
{
    NSMutableDictionary *d = [[attributes mutableCopy] autorelease];
    NSFont *f = [attributes objectForKey:NSFontAttributeName];
    if (f)
        [d setObject:[self convertFont:f] forKey:NSFontAttributeName];
    return d;
}

#pragma mark Fonts and families

- (NSArray<NSString *> *)availableFonts
{
    load_catalogue();
    @synchronized([NSFontManager class]) {
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *n in names_cache)
            if (![n hasPrefix:@"."] && [members_by_name objectForKey:n] &&
                (![_delegate respondsToSelector:@selector(fontManager:willIncludeFont:)] ||
                 [_delegate fontManager:self willIncludeFont:n]))
                [a addObject:n];
        return a;
    }
}

- (NSArray<NSString *> *)availableFontFamilies
{
    load_catalogue();
    @synchronized([NSFontManager class]) {
        return [[families_cache allKeys] sortedArrayUsingSelector:@selector(compare:)];
    }
}

- (NSArray<NSArray *> *)availableMembersOfFontFamily:(NSString *)family
{
    NSArray *members = family_members(family);
    if (![members count])
        return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (_FinchFontMember *m in members)
        [out addObject:@[ m->_name, m->_face, @(m->_weight), @(m->_traits) ]];
    return out;
}

- (NSArray<NSString *> *)availableFontNamesWithTraits:(NSFontTraitMask)traits
{
    if (traits & (NSUnboldFontMask | NSUnitalicFontMask))
        return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *family in [self availableFontFamilies])
        for (_FinchFontMember *m in family_members(family))
            if ((m->_traits & traits) == traits)
                [out addObject:m->_name];
    return out;
}

- (BOOL)fontNamed:(NSString *)name hasTraits:(NSFontTraitMask)traits
{
    if (traits & (NSUnboldFontMask | NSUnitalicFontMask))
        return NO;
    _FinchFontMember *m = member_named(name);
    return m && (m->_traits & traits) == traits;
}

- (NSArray *)availableFontNamesMatchingFontDescriptor:(NSFontDescriptor *)descriptor
{
    CFArrayRef matches = CTFontDescriptorCreateMatchingFontDescriptors((CTFontDescriptorRef)descriptor, NULL);
    NSMutableArray *out = [NSMutableArray array];
    for (id d in (NSArray *)matches) {
        NSString *n = [(NSString *)CTFontDescriptorCopyAttribute((CTFontDescriptorRef)d, kCTFontNameAttribute) autorelease];
        if (n && ![out containsObject:n])
            [out addObject:n];
    }
    if (matches)
        CFRelease(matches);
    return out;
}

- (NSString *)localizedNameForFamily:(NSString *)family face:(NSString *)faceKey
{
    return faceKey ?: family;
}

- (NSFontTraitMask)traitsOfFont:(NSFont *)font
{
    _FinchFontMember *m = member_of(font);
    return m ? m->_traits : 0;
}

- (NSInteger)weightOfFont:(NSFont *)font
{
    _FinchFontMember *m = member_of(font);
    return m ? m->_weight : 5;
}

- (NSFont *)fontWithFamily:(NSString *)family traits:(NSFontTraitMask)traits weight:(NSInteger)weight size:(CGFloat)size
{
    return font_for_member(pick_member(family, traits, weight, YES), size);
}

#pragma mark Converting

- (NSFont *)convertFont:(NSFont *)font toSize:(CGFloat)size
{
    return [font fontWithSize:size] ?: font;
}

- (NSFont *)convertFont:(NSFont *)font toFace:(NSString *)typeface
{
    NSFont *f = [NSFont fontWithName:typeface size:[font pointSize]];
    if (f && [[f fontName] isEqualToString:typeface])
        return f;
    /* a face name of the font's family */
    _FinchFontMember *m = member_of(font);
    for (_FinchFontMember *o in m ? family_members(m->_family) : nil)
        if ([o->_face isEqualToString:typeface])
            return font_for_member(o, [font pointSize]);
    return font;
}

- (NSFont *)convertFont:(NSFont *)font toFamily:(NSString *)family
{
    _FinchFontMember *m = member_of(font);
    if (!m)
        return font;
    _FinchFontMember *o = pick_member(family, m->_traits & ~0x10000u, m->_weight, NO);
    return font_for_member(o, [font pointSize]) ?: font;
}

- (NSFont *)convertFont:(NSFont *)font toHaveTrait:(NSFontTraitMask)trait
{
    _FinchFontMember *m = member_of(font);
    if (!m)
        return font;
    NSFontTraitMask t = m->_traits & ~0x10000u;
    NSInteger weight = m->_weight;
    if (trait & NSUnboldFontMask) {
        t &= ~NSBoldFontMask;
        if (m->_traits & NSBoldFontMask)
            weight = 5;
    }
    if (trait & NSUnitalicFontMask)
        t &= ~NSItalicFontMask;
    trait &= ~(NSUnboldFontMask | NSUnitalicFontMask);
    if ((m->_traits & trait) == trait && t == (m->_traits & ~0x10000u))
        return font;
    BOOL addsBold = (trait & NSBoldFontMask) && !(m->_traits & NSBoldFontMask);
    t |= trait;
    return font_for_member(pick_member(m->_family, t, weight, addsBold), [font pointSize]) ?: font;
}

- (NSFont *)convertFont:(NSFont *)font toNotHaveTrait:(NSFontTraitMask)trait
{
    _FinchFontMember *m = member_of(font);
    if (!m || !(m->_traits & trait))
        return font;
    NSFontTraitMask t = m->_traits & ~0x10000u & ~trait;
    NSInteger weight = (trait & NSBoldFontMask) ? 5 : m->_weight;
    return font_for_member(pick_member(m->_family, t, weight, NO), [font pointSize]) ?: font;
}

/* The next heavier or lighter member, upright or italic as the font is. */
- (NSFont *)convertWeight:(BOOL)up ofFont:(NSFont *)font
{
    _FinchFontMember *m = member_of(font);
    if (!m)
        return font;
    /* as Apple's: nothing lighter than a regular weight */
    if (!up && m->_weight <= 5)
        return font;
    BOOL italic = (m->_traits & NSItalicFontMask) != 0;
    _FinchFontMember *best = nil, *any = nil;
    for (_FinchFontMember *o in family_members(m->_family)) {
        if (up ? o->_weight <= m->_weight : o->_weight >= m->_weight)
            continue;
        BOOL closer = !any || (up ? o->_weight < any->_weight : o->_weight > any->_weight);
        if (closer)
            any = o;
        if (((o->_traits & NSItalicFontMask) != 0) == italic &&
            (!best || (up ? o->_weight < best->_weight : o->_weight > best->_weight)))
            best = o;
    }
    if (best && any && best->_weight != any->_weight)
        best = nil; /* the nearest weight has no face of this kind */
    return font_for_member(best ?: any, [font pointSize]) ?: font;
}

#pragma mark Panel and menu

- (NSFontPanel *)fontPanel:(BOOL)create
{
    if (create || [NSFontPanel sharedFontPanelExists])
        return [NSFontPanel sharedFontPanel];
    return nil;
}

- (void)orderFrontFontPanel:(id)sender
{
    NSFontPanel *p = [self fontPanel:YES];
    [p setPanelFont:_selectedFont isMultiple:_multiple];
    [p orderFront:sender];
}

- (void)orderFrontStylesPanel:(id)sender
{
}

- (void)setFontMenu:(NSMenu *)menu
{
    [menu retain];
    [_fontMenu release];
    _fontMenu = menu;
}

static NSMenuItem *
menu_item(NSMenu *menu, NSString *title, SEL action, NSString *key, NSEventModifierFlags mask, NSInteger tag, id target)
{
    NSMenuItem *i = [menu addItemWithTitle:title action:action keyEquivalent:key];
    [i setKeyEquivalentModifierMask:mask];
    [i setTag:tag];
    [i setTarget:target];
    return i;
}

static NSMenu *
submenu(NSMenu *menu, NSString *title, NSArray *items)
{
    NSMenuItem *it = [menu addItemWithTitle:title action:NULL keyEquivalent:@""];
    NSMenu *sub = [[[NSMenu alloc] initWithTitle:title] autorelease];
    for (NSUInteger i = 0; i + 1 < [items count]; i += 2)
        [sub addItemWithTitle:[items objectAtIndex:i] action:NSSelectorFromString([items objectAtIndex:i + 1]) keyEquivalent:@""];
    [it setSubmenu:sub];
    return sub;
}

- (NSMenu *)fontMenu:(BOOL)create
{
    if (_fontMenu || !create)
        return _fontMenu;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Font"];
    NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    menu_item(m, @"Show Fonts", @selector(orderFrontFontPanel:), @"t", cmd, 0, self);
    menu_item(m, @"Bold", @selector(addFontTrait:), @"b", cmd, NSBoldFontMask, self);
    menu_item(m, @"Italic", @selector(addFontTrait:), @"i", cmd, NSItalicFontMask, self);
    menu_item(m, @"Underline", NSSelectorFromString(@"underline:"), @"u", cmd, 0, nil);
    menu_item(m, @"Outline", NSSelectorFromString(@"outline:"), @"", cmd, 0, nil);
    menu_item(m, @"Styles…", @selector(orderFrontStylesPanel:), @"", cmd, 0, self);
    [m addItem:[NSMenuItem separatorItem]];
    menu_item(m, @"Larger", @selector(modifyFont:), @"+", cmd, NSSizeUpFontAction, self);
    menu_item(m, @"Smaller", @selector(modifyFont:), @"-", cmd, NSSizeDownFontAction, self);
    [m addItem:[NSMenuItem separatorItem]];
    submenu(m, @"Kern", @[ @"Use Default", @"useStandardKerning:", @"Use None", @"turnOffKerning:", @"Tighten",
                           @"tightenKerning:", @"Loosen", @"loosenKerning:" ]);
    submenu(m, @"Ligature", @[ @"Use Default", @"useStandardLigatures:", @"Use None", @"turnOffLigatures:", @"Use All",
                               @"useAllLigatures:" ]);
    submenu(m, @"Baseline", @[ @"Use Default", @"unscript:", @"Superscript", @"superscript:", @"Subscript", @"subscript:",
                               @"Raise", @"raiseBaseline:", @"Lower", @"lowerBaseline:" ]);
    [m addItem:[NSMenuItem separatorItem]];
    menu_item(m, @"Show Colors", NSSelectorFromString(@"orderFrontColorPanel:"), @"c", cmd | NSEventModifierFlagShift, 0, nil);
    [m addItem:[NSMenuItem separatorItem]];
    menu_item(m, @"Copy Style", NSSelectorFromString(@"copyFont:"), @"c", cmd | NSEventModifierFlagOption, 0, nil);
    menu_item(m, @"Paste Style", NSSelectorFromString(@"pasteFont:"), @"v", cmd | NSEventModifierFlagOption, 0, nil);
    _fontMenu = m;
    return _fontMenu;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    return [self isEnabled];
}

#pragma mark Collections (kept in memory)

- (NSArray *)collectionNames { return [[_collections allKeys] sortedArrayUsingSelector:@selector(compare:)] ?: @[]; }

- (BOOL)addCollection:(NSString *)name options:(NSFontCollectionOptions)options
{
    if (!_collections)
        _collections = [[NSMutableDictionary alloc] init];
    if ([_collections objectForKey:name])
        return NO;
    [_collections setObject:[NSMutableArray array] forKey:name];
    return YES;
}

- (BOOL)removeCollection:(NSString *)name
{
    if (![_collections objectForKey:name])
        return NO;
    [_collections removeObjectForKey:name];
    return YES;
}

- (NSArray *)fontDescriptorsInCollection:(NSString *)name { return [[[_collections objectForKey:name] copy] autorelease]; }

- (void)addFontDescriptors:(NSArray *)descriptors toCollection:(NSString *)name
{
    [[_collections objectForKey:name] addObjectsFromArray:descriptors];
}

- (void)removeFontDescriptor:(NSFontDescriptor *)descriptor fromCollection:(NSString *)name
{
    [[_collections objectForKey:name] removeObject:descriptor];
}

@end

/* For the font panel (NSFontPanel.m). */
FINCH_PRIVATE NSArray *
FinchFontFaces(NSString *family)
{
    NSMutableArray *out = [NSMutableArray array];
    for (_FinchFontMember *m in family_members(family))
        [out addObject:@[ m->_face, m->_name ]];
    return out;
}

FINCH_PRIVATE NSString *
FinchFontFaceOf(NSFont *font)
{
    _FinchFontMember *m = member_of(font);
    return m ? m->_face : nil;
}
