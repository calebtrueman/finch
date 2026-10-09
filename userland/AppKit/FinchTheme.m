/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The theme: a property list of tokens AppKit draws with (docs/design/FIELDWORK.md).
 * colors maps system colour names to {day, night} hex values (#RRGGBB or
 * #RRGGBBAA), palette holds the theme's own named colours, and metrics its
 * sizes. Anything a theme leaves out is Classic's, AppKit's Aqua-compatible
 * values. The theme is chosen by FINCH_THEME in the environment, then the
 * FinchTheme default (the app's, then the global one), then Fieldwork; a
 * theme is found in ~/Library/Themes, then AppKit's Resources/Themes. Night
 * is the theme's values for a dark appearance, which apps still see by its
 * Aqua name (NSAppearanceNameDarkAqua).
 */
#import "FinchTheme.h"

static NSString *theme_name;
static NSDictionary *theme;

static void
load_theme(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      const char *env = getenv("FINCH_THEME");
      NSString *name = env && *env ? [NSString stringWithUTF8String:env] : nil;
      if (!name.length)
          name = [[NSUserDefaults standardUserDefaults] stringForKey:@"FinchTheme"];
      if (!name.length)
          name = @"Fieldwork";
      theme_name = [name copy];
      if ([name caseInsensitiveCompare:@"Classic"] == NSOrderedSame)
          return;
      NSString *file = [name stringByAppendingPathExtension:@"plist"];
      NSMutableArray *dirs = [NSMutableArray arrayWithObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Themes"]];
      NSString *res = [[NSBundle bundleForClass:[NSColor class]] resourcePath];
      if (res)
          [dirs addObject:[res stringByAppendingPathComponent:@"Themes"]];
      for (NSString *d in dirs) {
          NSDictionary *t = [NSDictionary dictionaryWithContentsOfFile:[d stringByAppendingPathComponent:file]];
          if ([t isKindOfClass:[NSDictionary class]]) {
              theme = [t retain];
              break;
          }
      }
    });
}

NSString *
FinchThemeName(void)
{
    load_theme();
    return theme ? theme_name : @"Classic";
}

BOOL
FinchThemeIsClassic(void)
{
    load_theme();
    return theme == nil;
}

BOOL
FinchThemeIsNight(void)
{
    NSAppearance *a = [NSAppearance currentDrawingAppearance];
    return [a.name rangeOfString:@"Dark"].location != NSNotFound;
}

static BOOL
parse_hex(id value, CGFloat rgba[4])
{
    if (![value isKindOfClass:[NSString class]])
        return NO;
    NSString *s = value;
    if ([s hasPrefix:@"#"])
        s = [s substringFromIndex:1];
    if (s.length != 6 && s.length != 8)
        return NO;
    unsigned long long v = 0;
    if (![[NSScanner scannerWithString:s] scanHexLongLong:&v])
        return NO;
    if (s.length == 6)
        v = v << 8 | 0xff;
    rgba[0] = (CGFloat)(v >> 24 & 0xff) / 255;
    rgba[1] = (CGFloat)(v >> 16 & 0xff) / 255;
    rgba[2] = (CGFloat)(v >> 8 & 0xff) / 255;
    rgba[3] = (CGFloat)(v & 0xff) / 255;
    return YES;
}

static BOOL
lookup(NSString *table, NSString *name, CGFloat rgba[4])
{
    load_theme();
    NSDictionary *entry = theme[table][name];
    if (![entry isKindOfClass:[NSDictionary class]])
        return parse_hex(entry, rgba);
    BOOL night = FinchThemeIsNight();
    return parse_hex(entry[night ? @"night" : @"day"], rgba) || parse_hex(entry[@"day"], rgba);
}

BOOL
FinchThemeColorComponents(NSString *name, CGFloat rgba[4])
{
    return lookup(@"colors", name, rgba);
}

NSColor *
FinchThemePaletteColor(NSString *name)
{
    CGFloat c[4];
    if (!lookup(@"palette", name, c))
        return nil;
    return [NSColor colorWithSRGBRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
}

CGFloat
FinchThemeMetric(NSString *name, CGFloat fallback)
{
    load_theme();
    id v = theme[@"metrics"][name];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : fallback;
}
