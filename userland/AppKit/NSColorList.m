/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSColorList: named, ordered lists of colors. The system's lists are Apple's four,
 * with their colors (Apple's and the crayons measured on macOS, in sRGB; the web-safe
 * colors as calibrated RGB, as Apple's are; System's as catalog colors), read-only.
 * Others are the user's, in ~/Library/Colors as .clr files: keyed archives of the list
 * (NSName, NSKeys, NSColors), as Apple's are, so lists move between the two.
 */
#import "AppKit_Finch.h"

NSNotificationName NSColorListDidChangeNotification = @"NSColorListDidChangeNotification";

struct list_color {
    const char *name;
    CGFloat r, g, b;
};

/* Web Safe Colors, in the color list's order */
static const char *const kWebSafe[216] = {
"FFFFFF", "CCCCCC", "999999", "666666", "333333", "000000", "FFCCCC", "CC9999", "996666", "663333", "330000", "FF9999", 
"CC6666", "CC3333", "993333", "660000", "FF6666", "FF3333", "FF0000", "CC0000", "990000", "FF9966", "FF6633", "FF3300", 
"CC3300", "993300", "FFCC99", "CC9966", "CC6633", "996633", "663300", "FF9933", "FF6600", "FF9900", "CC6600", "CC9933", 
"FFCC66", "FFCC33", "FFCC00", "CC9900", "996600", "FFFFCC", "CCCC99", "999966", "666633", "333300", "FFFF99", "CCCC66", 
"CCCC33", "999933", "666600", "FFFF66", "FFFF33", "FFFF00", "CCCC00", "999900", "CCFF66", "CCFF33", "CCFF00", "99CC00", 
"669900", "CCFF99", "99CC66", "99CC33", "669933", "336600", "99FF33", "99FF00", "66FF00", "66CC00", "66CC33", "99FF66", 
"66FF33", "33FF00", "33CC00", "339900", "CCFFCC", "99CC99", "669966", "336633", "003300", "99FF99", "66CC66", "33CC33", 
"339933", "006600", "66FF66", "33FF33", "00FF00", "00CC00", "009900", "66FF99", "33FF66", "00FF33", "00CC33", "009933", 
"99FFCC", "66CC99", "33CC66", "339966", "006633", "33FF99", "00FF66", "00FF99", "00CC66", "33CC99", "66FFCC", "33FFCC", 
"00FFCC", "00CC99", "009966", "CCFFFF", "99CCCC", "669999", "336666", "003333", "99FFFF", "66CCCC", "33CCCC", "339999", 
"006666", "66FFFF", "33FFFF", "00FFFF", "00CCCC", "009999", "66CCFF", "33CCFF", "00CCFF", "0099CC", "006699", "99CCFF", 
"6699CC", "3399CC", "336699", "003366", "3399FF", "0099FF", "0066FF", "0066CC", "3366CC", "6699FF", "3366FF", "0033FF", 
"0033CC", "003399", "CCCCFF", "9999CC", "666699", "333366", "000033", "9999FF", "6666CC", "3333CC", "333399", "000066", 
"6666FF", "3333FF", "0000FF", "0000CC", "000099", "9966FF", "6633FF", "3300FF", "3300CC", "330099", "CC99FF", "9966CC", 
"6633CC", "663399", "330066", "9933FF", "6600FF", "9900FF", "6600CC", "9933CC", "CC66FF", "CC33FF", "CC00FF", "9900CC", 
"660099", "FFCCFF", "CC99CC", "996699", "663366", "330033", "FF99FF", "CC66CC", "CC33CC", "993399", "660066", "FF66FF", 
"FF33FF", "FF00FF", "CC00CC", "990099", "FF66CC", "FF33CC", "FF00CC", "CC0099", "990066", "FF99CC", "CC6699", "CC3399", 
"993366", "660033", "FF3399", "FF0099", "FF0066", "CC0066", "CC3366", "FF6699", "FF3366", "FF0033", "CC0033", "990033", 
};

static const struct list_color kApple[] = {
    {"Black", 0.000000, 0.000000, 0.000000},
    {"Blue", 0.016804, 0.198351, 1.000000},
    {"Brown", 0.667998, 0.475121, 0.258601},
    {"Cyan", 0.000000, 0.991439, 1.000000},
    {"Green", 0.000000, 0.976805, 0.000000},
    {"Magenta", 1.000000, 0.252792, 1.000000},
    {"Orange", 1.000000, 0.576372, 0.000000},
    {"Purple", 0.579194, 0.128014, 0.572686},
    {"Red", 1.000000, 0.149131, 0.000000},
    {"Yellow", 0.999424, 0.985554, 0.000000},
    {"White", 0.999996, 1.000000, 1.000000},
};

static const struct list_color kCrayons[] = {
    {"Licorice", 0.000000, 0.000000, 0.000000},
    {"Lead", 0.129842, 0.129846, 0.129844},
    {"Tungsten", 0.260517, 0.260524, 0.260521},
    {"Iron", 0.370555, 0.370565, 0.370560},
    {"Steel", 0.475635, 0.475647, 0.475640},
    {"Tin", 0.570459, 0.570472, 0.570465},
    {"Nickel", 0.574149, 0.574162, 0.574155},
    {"Aluminum", 0.664224, 0.664240, 0.664232},
    {"Magnesium", 0.754069, 0.754087, 0.754077},
    {"Silver", 0.837418, 0.837438, 0.837427},
    {"Mercury", 0.921431, 0.921453, 0.921441},
    {"Snow", 0.999996, 1.000000, 1.000000},
    {"Cayenne", 0.580723, 0.066734, 0.000000},
    {"Mocha", 0.578747, 0.321520, 0.000000},
    {"Asparagus", 0.573807, 0.565536, 0.000000},
    {"Fern", 0.308401, 0.561823, 0.000000},
    {"Clover", 0.000000, 0.560318, 0.000000},
    {"Moss", 0.000000, 0.562842, 0.318817},
    {"Teal", 0.000000, 0.569046, 0.574617},
    {"Ocean", 0.000000, 0.328521, 0.574885},
    {"Midnight", 0.004860, 0.096086, 0.574993},
    {"Eggplant", 0.323698, 0.106358, 0.574860},
    {"Plum", 0.581058, 0.128552, 0.574531},
    {"Maroon", 0.580819, 0.088428, 0.318639},
    {"Maraschino", 1.000000, 0.149131, 0.000000},
    {"Tangerine", 1.000000, 0.578105, 0.000000},
    {"Lemon", 0.999424, 0.985554, 0.000000},
    {"Lime", 0.556343, 0.979346, 0.000000},
    {"Spring", 0.000000, 0.976805, 0.000000},
    {"Sea Foam", 0.000000, 0.981067, 0.573691},
    {"Turquoise", 0.000000, 0.991439, 1.000000},
    {"Aqua", 0.000000, 0.589801, 1.000000},
    {"Blueberry", 0.016804, 0.198351, 1.000000},
    {"Grape", 0.581883, 0.215692, 1.000000},
    {"Magenta", 1.000000, 0.252792, 1.000000},
    {"Strawberry", 1.000000, 0.185739, 0.573395},
    {"Salmon", 1.000000, 0.493272, 0.473998},
    {"Cantaloupe", 1.000000, 0.832346, 0.473206},
    {"Banana", 0.999534, 0.988356, 0.472655},
    {"Honeydew", 0.832170, 0.985484, 0.473331},
    {"Flora", 0.450094, 0.981323, 0.474303},
    {"Spindrift", 0.450858, 0.988297, 0.837630},
    {"Ice", 0.451387, 0.993096, 1.000000},
    {"Sky", 0.462023, 0.838284, 1.000000},
    {"Orchid", 0.476842, 0.504808, 1.000000},
    {"Lavender", 0.844656, 0.514571, 1.000000},
    {"Bubblegum", 1.000000, 0.521205, 1.000000},
    {"Carnation", 1.000000, 0.540976, 0.847314},
};

static NSString *const kSystemKeys[] = {
    @"labelColor", @"secondaryLabelColor", @"tertiaryLabelColor", @"quaternaryLabelColor", @"quinaryLabelColor",
    @"systemRedColor", @"systemGreenColor", @"systemBlueColor", @"systemOrangeColor", @"systemYellowColor",
    @"systemBrownColor", @"systemPinkColor", @"systemPurpleColor", @"systemTealColor", @"systemIndigoColor",
    @"systemMintColor", @"systemCyanColor", @"systemGrayColor", @"linkColor", @"placeholderTextColor",
    @"windowFrameTextColor", @"selectedMenuItemTextColor", @"alternateSelectedControlTextColor", @"headerTextColor",
    @"separatorColor", @"gridColor", @"textColor", @"textBackgroundColor", @"selectedTextColor",
    @"selectedTextBackgroundColor", @"unemphasizedSelectedTextBackgroundColor", @"unemphasizedSelectedTextColor",
    @"systemFillColor", @"secondarySystemFillColor", @"tertiarySystemFillColor", @"quaternarySystemFillColor",
    @"quinarySystemFillColor", @"windowBackgroundColor", @"underPageBackgroundColor", @"controlBackgroundColor",
    @"selectedContentBackgroundColor", @"unemphasizedSelectedContentBackgroundColor",
    @"alternatingContentBackgroundColor", @"findHighlightColor", @"controlColor", @"controlTextColor",
    @"selectedControlColor", @"selectedControlTextColor", @"disabledControlTextColor", @"keyboardFocusIndicatorColor",
    @"controlAccentColor",
};

static CGFloat
hex_component(const char *s)
{
    unsigned v = 0;
    sscanf(s, "%2x", &v);
    return v / 255.0;
}

@implementation NSColorList {
    NSString *_name;
    NSMutableArray<NSString *> *_keys;
    NSMutableDictionary<NSString *, NSColor *> *_colors;
    NSString *_path;
    BOOL _editable;
}

+ (BOOL)supportsSecureCoding { return YES; }

static NSString *
user_colors_directory(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Colors"];
}

static NSColorList *
system_list(NSString *name)
{
    NSColorList *l = [[[NSColorList alloc] initWithName:name] autorelease];
    if ([name isEqualToString:@"Apple"] || [name isEqualToString:@"Crayons"]) {
        BOOL apple = [name isEqualToString:@"Apple"];
        const struct list_color *c = apple ? kApple : kCrayons;
        size_t n = apple ? sizeof kApple / sizeof *kApple : sizeof kCrayons / sizeof *kCrayons;
        for (size_t i = 0; i < n; i++)
            [l setColor:[NSColor colorWithSRGBRed:c[i].r green:c[i].g blue:c[i].b alpha:1] forKey:@(c[i].name)];
    } else if ([name isEqualToString:@"Web Safe Colors"]) {
        for (size_t i = 0; i < 216; i++)
            [l setColor:[NSColor colorWithCalibratedRed:hex_component(kWebSafe[i]) green:hex_component(kWebSafe[i] + 2)
                                                   blue:hex_component(kWebSafe[i] + 4) alpha:1]
                 forKey:@(kWebSafe[i])];
    } else {
        for (size_t i = 0; i < sizeof kSystemKeys / sizeof *kSystemKeys; i++) {
            NSColor *c = [NSColor colorWithCatalogName:@"System" colorName:kSystemKeys[i]];
            if (c)
                [l setColor:c forKey:kSystemKeys[i]];
        }
    }
    l->_editable = NO;
    return l;
}

static NSMutableArray *available;

+ (NSArray<NSColorList *> *)availableColorLists
{
    @synchronized(self) {
        if (!available) {
            available = [[NSMutableArray alloc] init];
            for (NSString *n in @[@"Apple", @"System", @"Crayons", @"Web Safe Colors"])
                [available addObject:system_list(n)];
            NSString *dir = user_colors_directory();
            for (NSString *file in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]
                                       sortedArrayUsingSelector:@selector(compare:)]) {
                if (![[file pathExtension] isEqualToString:@"clr"])
                    continue;
                NSColorList *l = [[[NSColorList alloc] initWithName:[file stringByDeletingPathExtension]
                                                           fromFile:[dir stringByAppendingPathComponent:file]] autorelease];
                if (l)
                    [available addObject:l];
            }
        }
        return [[available copy] autorelease];
    }
}

+ (NSColorList *)colorListNamed:(NSColorListName)name
{
    for (NSColorList *l in [self availableColorLists])
        if ([[l name] isEqualToString:name])
            return l;
    return nil;
}

- (instancetype)initWithName:(NSColorListName)name
{
    if ((self = [super init])) {
        _name = [name copy];
        _keys = [[NSMutableArray alloc] init];
        _colors = [[NSMutableDictionary alloc] init];
        _editable = YES;
    }
    return self;
}

- (instancetype)initWithName:(NSColorListName)name fromFile:(NSString *)path
{
    if (!(self = [self initWithName:name]))
        return nil;
    if (path) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSKeyedUnarchiver *u = data ? [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL] autorelease] : nil;
        u.requiresSecureCoding = NO;
        NSArray *keys = [u decodeObjectForKey:@"NSKeys"], *colors = [u decodeObjectForKey:@"NSColors"];
        if (!keys) {
            /* the archive's root is the list */
            NSColorList *root = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
            if ([root isKindOfClass:[NSColorList class]]) {
                keys = root->_keys;
                colors = [root->_colors objectsForKeys:root->_keys notFoundMarker:(id)[NSNull null]];
            }
        }
        for (NSUInteger i = 0; i < MIN([keys count], [colors count]); i++)
            if ([[colors objectAtIndex:i] isKindOfClass:[NSColor class]])
                [self setColor:[colors objectAtIndex:i] forKey:[keys objectAtIndex:i]];
        _path = [path copy];
        _editable = [[NSFileManager defaultManager] isWritableFileAtPath:path];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [self initWithName:[coder decodeObjectOfClass:[NSString class] forKey:@"NSName"]]))
        return nil;
    NSSet *classes = [NSSet setWithObjects:[NSArray class], [NSString class], [NSColor class], nil];
    NSArray *keys = [coder decodeObjectOfClasses:classes forKey:@"NSKeys"];
    NSArray *colors = [coder decodeObjectOfClasses:classes forKey:@"NSColors"];
    for (NSUInteger i = 0; i < MIN([keys count], [colors count]); i++)
        [self setColor:[colors objectAtIndex:i] forKey:[keys objectAtIndex:i]];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_name forKey:@"NSName"];
    [coder encodeObject:[[_keys mutableCopy] autorelease] forKey:@"NSKeys"];
    [coder encodeObject:[[[_colors objectsForKeys:_keys notFoundMarker:(id)[NSNull null]] mutableCopy] autorelease]
                 forKey:@"NSColors"];
}

- (void)dealloc
{
    [_name release];
    [_keys release];
    [_colors release];
    [_path release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"NSColorList %p name:%@ device:(null) file:%@ loaded:1", self, _name, _path];
}

- (NSColorListName)name { return _name; }
- (BOOL)isEditable { return _editable; }
- (NSArray<NSColorName> *)allKeys { return [[_keys copy] autorelease]; }
- (NSColor *)colorWithKey:(NSColorName)key { return key ? [_colors objectForKey:key] : nil; }

- (void)_changed
{
    [[NSNotificationCenter defaultCenter] postNotificationName:NSColorListDidChangeNotification object:self];
}

- (void)setColor:(NSColor *)color forKey:(NSColorName)key
{
    if (!color || !key)
        return;
    if (![_colors objectForKey:key])
        [_keys addObject:key];
    [_colors setObject:color forKey:key];
    [self _changed];
}

- (void)insertColor:(NSColor *)color key:(NSColorName)key atIndex:(NSUInteger)loc
{
    if (!color || !key)
        return;
    [_keys removeObject:key];
    [_keys insertObject:key atIndex:MIN(loc, [_keys count])];
    [_colors setObject:color forKey:key];
    [self _changed];
}

- (void)removeColorWithKey:(NSColorName)key
{
    if (!key || ![_colors objectForKey:key])
        return;
    [_keys removeObject:key];
    [_colors removeObjectForKey:key];
    [self _changed];
}

- (BOOL)writeToURL:(NSURL *)url error:(NSError **)errPtr
{
    NSString *path = url ? [url path]
                         : [user_colors_directory() stringByAppendingPathComponent:[_name stringByAppendingPathExtension:@"clr"]];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self requiringSecureCoding:NO error:errPtr];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:errPtr])
        return NO;
    if (!url) {
        [_path release];
        _path = [path copy];
        @synchronized([NSColorList class]) {
            if (available && ![available containsObject:self])
                [available addObject:self];
        }
    }
    return YES;
}

- (BOOL)writeToFile:(NSString *)path
{
    return [self writeToURL:path ? [NSURL fileURLWithPath:path] : nil error:NULL];
}

- (void)removeFile
{
    if (_path)
        [[NSFileManager defaultManager] removeItemAtPath:_path error:NULL];
    @synchronized([NSColorList class]) {
        [available removeObject:self];
    }
    [_path release];
    _path = nil;
}

@end
