/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSAppearance: the named appearances. Finch draws in the light (Aqua)
 * appearance for now; dark appearances exist as names, so apps that ask
 * for them get an object that says so.
 */
#import "NSView_Finch.h"

NSAppearanceName const NSAppearanceNameAqua = @"NSAppearanceNameAqua";
NSAppearanceName const NSAppearanceNameDarkAqua = @"NSAppearanceNameDarkAqua";
NSAppearanceName const NSAppearanceNameLightContent = @"NSAppearanceNameLightContent";
NSAppearanceName const NSAppearanceNameVibrantDark = @"NSAppearanceNameVibrantDark";
NSAppearanceName const NSAppearanceNameVibrantLight = @"NSAppearanceNameVibrantLight";
NSAppearanceName const NSAppearanceNameAccessibilityHighContrastAqua = @"NSAppearanceNameAccessibilityAqua";
NSAppearanceName const NSAppearanceNameAccessibilityHighContrastDarkAqua = @"NSAppearanceNameAccessibilityDarkAqua";
NSAppearanceName const NSAppearanceNameAccessibilityHighContrastVibrantLight =
    @"NSAppearanceNameAccessibilityVibrantLight";
NSAppearanceName const NSAppearanceNameAccessibilityHighContrastVibrantDark =
    @"NSAppearanceNameAccessibilityVibrantDark";

@implementation NSAppearance {
    NSAppearanceName _name;
}

static NSAppearance *current;

static BOOL
known(NSAppearanceName name)
{
    return [name isEqualToString:NSAppearanceNameAqua] || [name isEqualToString:NSAppearanceNameDarkAqua] ||
           [name isEqualToString:NSAppearanceNameVibrantDark] || [name isEqualToString:NSAppearanceNameVibrantLight] ||
           [name isEqualToString:NSAppearanceNameAccessibilityHighContrastAqua] ||
           [name isEqualToString:NSAppearanceNameAccessibilityHighContrastDarkAqua] ||
           [name isEqualToString:NSAppearanceNameAccessibilityHighContrastVibrantLight] ||
           [name isEqualToString:NSAppearanceNameAccessibilityHighContrastVibrantDark];
}

+ (NSAppearance *)appearanceNamed:(NSAppearanceName)name
{
    /* Light content is Aqua; the high-contrast names are their plain ones while high contrast is off. */
    if ([name isEqualToString:NSAppearanceNameLightContent] ||
        [name isEqualToString:NSAppearanceNameAccessibilityHighContrastAqua])
        name = NSAppearanceNameAqua;
    else if ([name isEqualToString:NSAppearanceNameAccessibilityHighContrastDarkAqua])
        name = NSAppearanceNameDarkAqua;
    else if ([name isEqualToString:NSAppearanceNameAccessibilityHighContrastVibrantLight])
        name = NSAppearanceNameVibrantLight;
    else if ([name isEqualToString:NSAppearanceNameAccessibilityHighContrastVibrantDark])
        name = NSAppearanceNameVibrantDark;
    if (!known(name))
        return nil;
    static NSMutableDictionary *cache;
    if (!cache)
        cache = [[NSMutableDictionary alloc] init];
    NSAppearance *a = cache[name];
    if (!a) {
        a = [[[self alloc] initWithAppearanceNamed:name bundle:nil] autorelease];
        if (a)
            cache[name] = a;
    }
    return a;
}

- (instancetype)initWithAppearanceNamed:(NSAppearanceName)name bundle:(NSBundle *)bundle
{
    self = [super init];
    if (self)
        _name = [name copy];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *name = [coder decodeObjectForKey:@"NSAppearanceName"];
    if (!known(name)) {
        [self release];
        return [[NSAppearance appearanceNamed:NSAppearanceNameAqua] retain];
    }
    return [self initWithAppearanceNamed:name bundle:nil];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_name forKey:@"NSAppearanceName"];
}

+ (BOOL)supportsSecureCoding { return YES; }

- (void)dealloc
{
    [_name release];
    [super dealloc];
}

- (NSAppearanceName)name { return _name; }

- (BOOL)allowsVibrancy
{
    return [_name hasPrefix:@"NSAppearanceNameVibrant"] || [_name hasPrefix:@"NSAppearanceNameAccessibilityVibrant"];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> %@", [self class], self, _name];
}

+ (NSAppearance *)currentAppearance
{
    return [self currentDrawingAppearance];
}

+ (void)setCurrentAppearance:(NSAppearance *)appearance
{
    [current autorelease];
    current = [appearance retain];
}

+ (NSAppearance *)currentDrawingAppearance
{
    return current ?: [self appearanceNamed:NSAppearanceNameAqua];
}

- (void)performAsCurrentDrawingAppearance:(void (NS_NOESCAPE ^)(void))block
{
    NSAppearance *saved = [current retain];
    [NSAppearance setCurrentAppearance:self];
    @try {
        block();
    } @finally {
        [NSAppearance setCurrentAppearance:saved];
        [saved release];
    }
}

- (NSAppearanceName)bestMatchFromAppearancesWithNames:(NSArray<NSAppearanceName> *)names
{
    BOOL dark = [_name rangeOfString:@"Dark"].location != NSNotFound;
    for (NSAppearanceName n in names)
        if ([n isEqualToString:_name])
            return n;
    for (NSAppearanceName n in names)
        if (([n rangeOfString:@"Dark"].location != NSNotFound) == dark)
            return n;
    return nil;
}

@end
