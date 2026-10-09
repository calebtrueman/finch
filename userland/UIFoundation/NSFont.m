/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSFont over CoreText. As on macOS, an NSFont is a CTFont: CoreText's font
 * type is bridged to NSCTFont (a subclass of UIFont, a subclass of NSFont),
 * so CTFontCreateWithName returns an NSCTFont, and NSFont messages, CF calls
 * and CTFont calls all work on the same object.
 *
 * The system fonts are Finch's (Inter, through the font aliases in
 * userland/fonts), at Apple's sizes, and report Apple's descriptors (the
 * UI-usage attribute) and archive under Apple's names, so archives and nibs
 * made on macOS read back.
 */
#import "UIFoundationInternal.h"
#import <objc/runtime.h>
#import <pthread.h>

extern void _CFRuntimeBridgeTypeToClass(CFTypeID typeID, const void *cls);
extern CFTypeRef _CFTryRetain(CFTypeRef cf);
extern Boolean _CFIsDeallocating(CFTypeRef cf);

NSString *const UIFUIUsageAttribute = @"NSCTFontUIUsageAttribute";
NSString *const UIFSizeCategoryAttribute = @"NSCTFontSizeCategoryAttribute";

/* Sentinels, as Apple's: NULL for the identity matrix, all ones for a flipped one. */
const CGFloat *NSFontIdentityMatrix = NULL;
const CGFloat *NSFontFlippedMatrix = (const CGFloat *)~(uintptr_t)0;
NSUInteger NSUnderlineByWordMask = 0x8000;
NSUInteger NSUnderlineStrikethroughMask = 0x4000;
const NSUInteger NSUnderlineSpellingMask = 0x2000;

/* NSFont archive flags (NSfFlags), as Apple's: fonts without a matrix have 0x10; the
 * system font 0x400, the bold system font 0x800, the user's fixed-pitch font 0x200. */
enum {
    kFontFlagBase = 0x10,
    kFontFlagFixedPitchUser = 0x200,
    kFontFlagSystem = 0x400,
    kFontFlagBoldSystem = 0x800,
};

#pragma mark - The cache

/* NSFont caches its fonts, as Apple's does: asking twice for the same font
 * returns the same object. System fonts stay cached for the process's
 * lifetime, and the cache records what each one is (its Apple descriptor and
 * archive name), keyed by the font's address. */
@interface UIFSystemFontInfo : NSObject {
@public
    NSFontDescriptor *descriptor;
    NSString *archiveName;
    NSInteger flags;
}
@end
@implementation UIFSystemFontInfo
- (void)dealloc
{
    [descriptor release];
    [archiveName release];
    [super dealloc];
}
@end

static pthread_mutex_t cache_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *named_fonts;   /* key -> font */
static NSMutableDictionary *system_fonts;  /* key -> font, never evicted */
static CFMutableDictionaryRef system_info; /* font (unretained) -> UIFSystemFontInfo */

static void
make_caches(void)
{
    named_fonts = [NSMutableDictionary new];
    system_fonts = [NSMutableDictionary new];
    system_info = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
}

static id
cache_get(NSMutableDictionary *cache, NSString *key)
{
    pthread_mutex_lock(&cache_lock);
    id f = [[cache objectForKey:key] retain];
    pthread_mutex_unlock(&cache_lock);
    return [f autorelease];
}

/* Store `font` under `key` (or return the font already there). */
static NSFont *
cache_put(NSMutableDictionary *cache, NSString *key, NSFont *font, UIFSystemFontInfo *info)
{
    pthread_mutex_lock(&cache_lock);
    NSFont *have = [cache objectForKey:key];
    if (have) {
        font = have;
    } else {
        if (cache == named_fonts && named_fonts.count >= 256)
            [named_fonts removeAllObjects];
        [cache setObject:font forKey:key];
        if (info)
            CFDictionarySetValue(system_info, font, info);
    }
    [[font retain] autorelease];
    pthread_mutex_unlock(&cache_lock);
    return font;
}

static UIFSystemFontInfo *
system_font_info(NSFont *font)
{
    pthread_mutex_lock(&cache_lock);
    UIFSystemFontInfo *info = (id)CFDictionaryGetValue(system_info, font);
    pthread_mutex_unlock(&cache_lock);
    return info;
}

NSFontDescriptor *
UIFSystemFontDescriptor(NSFont *font)
{
    return system_font_info(font)->descriptor;
}

/* Matrices are interned so -matrix can return an inner pointer that outlives
 * any one font. */
static const CGFloat *
interned_matrix(const CGFloat m[6])
{
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static CGFloat (*table)[6];
    static size_t count, capacity;
    pthread_mutex_lock(&lock);
    for (size_t i = 0; i < count; i++)
        if (!memcmp(table[i], m, sizeof table[i])) {
            pthread_mutex_unlock(&lock);
            return table[i];
        }
    if (count == capacity) {
        /* Old blocks stay allocated: pointers into them stay valid. */
        size_t ncap = capacity ? capacity * 2 : 16;
        CGFloat (*bigger)[6] = calloc(ncap, sizeof *bigger);
        memcpy(bigger, table, count * sizeof *table);
        table = bigger, capacity = ncap;
    }
    memcpy(table[count], m, sizeof table[count]);
    const CGFloat *r = table[count++];
    pthread_mutex_unlock(&lock);
    return r;
}

#pragma mark - Making fonts

static NSString *
matrix_key(const CGAffineTransform *m)
{
    if (!m || CGAffineTransformIsIdentity(*m))
        return @"";
    return [NSString stringWithFormat:@"[%g %g %g %g %g %g]", m->a, m->b, m->c, m->d, m->tx, m->ty];
}

/* Does `name` name this font (its PostScript, family or full name), or an
 * Apple font Finch stands it in for? */
static BOOL
font_answers_to(CTFontRef font, NSString *name)
{
    NSString *names[3] = {
        [(NSString *)CTFontCopyPostScriptName(font) autorelease],
        [(NSString *)CTFontCopyFamilyName(font) autorelease],
        [(NSString *)CTFontCopyFullName(font) autorelease],
    };
    for (int i = 0; i < 3; i++)
        if (names[i] && [names[i] caseInsensitiveCompare:name] == NSOrderedSame)
            return YES;
    NSString *alias = UIFFontAlias(name);
    return alias && [alias caseInsensitiveCompare:names[0]] == NSOrderedSame;
}

static NSFont *
font_named(NSString *name, CGFloat size, const CGAffineTransform *matrix)
{
    if (![name isKindOfClass:[NSString class]] || !name.length)
        return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%a|%@", name, size, matrix_key(matrix)];
    NSFont *f = cache_get(named_fonts, key);
    if (f)
        return f;
    CTFontRef ct = CTFontCreateWithName((CFStringRef)name, size, matrix);
    if (!ct)
        return nil;
    if (!font_answers_to(ct, name)) {
        CFRelease(ct);
        return nil;
    }
    return cache_put(named_fonts, key, [(NSFont *)ct autorelease], nil);
}

/* Apple's system-font usages, by weight, and the font names Finch's aliases
 * give them (Inter's faces). */
static const struct {
    CGFloat weight;
    NSString *usage, *name;
} system_weights[] = {
    {(CGFloat)-0.8f, @"CTFontUltraLightUsage", @".AppleSystemUIFontUltraLight"},
    {(CGFloat)-0.6f, @"CTFontThinUsage", @".AppleSystemUIFontThin"},
    {(CGFloat)-0.4f, @"CTFontLightUsage", @".AppleSystemUIFontLight"},
    {0, @"CTFontRegularUsage", @".AppleSystemUIFont"},
    {(CGFloat)0.23f, @"CTFontMediumUsage", @".AppleSystemUIFontMedium"},
    {(CGFloat)0.3f, @"CTFontDemiUsage", @".AppleSystemUIFontDemi"},
    {(CGFloat)0.4f, @"CTFontBoldUsage", @".AppleSystemUIFontBold"},
    {(CGFloat)0.56f, @"CTFontHeavyUsage", @".AppleSystemUIFontHeavy"},
    {(CGFloat)0.62f, @"CTFontBlackUsage", @".AppleSystemUIFontBlack"},
};
#define NWEIGHTS (sizeof system_weights / sizeof system_weights[0])

/* The standard weight a requested one rounds to: the first at or above it. */
static size_t
weight_index(CGFloat weight)
{
    for (size_t i = 0; i < NWEIGHTS; i++)
        if (weight <= system_weights[i].weight + 1e-6)
            return i;
    return NWEIGHTS - 1;
}

/* A system font: Finch's face for `fontName`, reporting Apple's descriptor
 * (`attributes` plus the size) and archived as `archiveName`. */
static NSFont *
system_font(NSString *fontName, CGFloat size, NSDictionary *attributes, NSString *archiveName, NSInteger flags)
{
    NSString *key = [NSString stringWithFormat:@"%@|%a|%@", fontName, size, attributes];
    NSFont *f = cache_get(system_fonts, key);
    if (f)
        return f;
    CTFontRef ct = CTFontCreateWithName((CFStringRef)fontName, size, NULL);
    if (!ct)
        return nil;
    UIFSystemFontInfo *info = [[UIFSystemFontInfo new] autorelease];
    NSMutableDictionary *a = [[attributes mutableCopy] autorelease];
    a[NSFontSizeAttribute] = @(size);
    info->descriptor = [[NSFontDescriptor fontDescriptorWithFontAttributes:a] retain];
    info->archiveName = [archiveName copy];
    info->flags = flags;
    return cache_put(system_fonts, key, [(NSFont *)ct autorelease], info);
}

static NSFont *
system_font_with_weight(CGFloat size, CGFloat weight, NSDictionary *extra)
{
    size_t i = weight_index(weight);
    NSMutableDictionary *a = [NSMutableDictionary dictionaryWithObject:system_weights[i].usage forKey:UIFUIUsageAttribute];
    if (extra)
        [a addEntriesFromDictionary:extra];
    NSInteger flags = kFontFlagBase;
    if (!extra && i == 3)
        flags |= kFontFlagSystem;
    else if (!extra && i == 6)
        flags |= kFontFlagBoldSystem;
    return system_font(system_weights[i].name, size, a, system_weights[i].name, flags);
}

NSFont *
UIFSystemFontForUsage(NSString *usage, CGFloat size)
{
    if (![usage isKindOfClass:[NSString class]])
        return nil;
    if (size <= 0)
        size = 13;
    for (size_t i = 0; i < NWEIGHTS; i++)
        if ([usage isEqualToString:system_weights[i].usage])
            return system_font_with_weight(size, system_weights[i].weight, nil);
    if ([usage isEqualToString:@"CTFontEmphasizedUsage"])
        return system_font(@".AppleSystemUIFontEmphasized", size,
                           @{UIFUIUsageAttribute : usage},
                           @".AppleSystemUIFontEmphasized", kFontFlagBase);
    if ([usage isEqualToString:@"UICTFontTextStyleHeadline"])
        return system_font(@".AppleSystemUIFontBold", size,
                           @{UIFSizeCategoryAttribute : @3, UIFUIUsageAttribute : usage}, @".AppleSystemUIFaceHeadline",
                           kFontFlagBase);
    if ([usage hasPrefix:@"UICTFontTextStyle"])
        return system_font(@".AppleSystemUIFont", size, @{UIFSizeCategoryAttribute : @3, UIFUIUsageAttribute : usage},
                           @".AppleSystemUIFont", kFontFlagBase);
    return nil;
}

NSFont *
UIFDefaultFont(void)
{
    return font_named(@"Helvetica", 12, NULL);
}

/* Fonts named in the user's defaults (NSFont, NSFixedPitchFont), as Apple's. */
static NSFont *
user_font(NSString *nameKey, NSString *sizeKey, NSString *defaultName, CGFloat defaultSize, CGFloat size)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (size <= 0) {
        id s = [d objectForKey:sizeKey];
        size = [s respondsToSelector:@selector(doubleValue)] && [s doubleValue] > 0 ? [s doubleValue] : defaultSize;
    }
    NSString *name = [d stringForKey:nameKey];
    NSFont *f = name ? font_named(name, size, NULL) : nil;
    return f ? f : font_named(defaultName, size, NULL);
}

#pragma mark - NSFont

/* [NSFont alloc] (an unarchiver's, say) gets this; its -init… methods return a real font. */
@interface NSFontPlaceholder : NSFont
@end

@implementation NSFont

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    static NSFontPlaceholder *placeholder;
    if (self == [NSFont class] || self == [UIFont class] || self == [NSCTFont class]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            placeholder = (NSFontPlaceholder *)class_createInstance([NSFontPlaceholder class], 0);
        });
        return placeholder;
    }
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSFont *)fontWithName:(NSString *)fontName size:(CGFloat)fontSize
{
    return font_named(fontName, fontSize > 0 ? fontSize : 12, NULL);
}

+ (NSFont *)fontWithName:(NSString *)fontName matrix:(const CGFloat *)m
{
    static const CGFloat identity[6] = {1, 0, 0, 1, 0, 0}, flipped[6] = {1, 0, 0, -1, 0, 0};
    if (m == NSFontIdentityMatrix)
        m = identity;
    else if (m == NSFontFlippedMatrix)
        m = flipped;
    /* NSFont's matrix is the point size times CoreText's font matrix. */
    CGFloat size = m[3] != 0 ? fabs(m[3]) : fabs(m[0]);
    if (size <= 0)
        return [self fontWithName:fontName size:12];
    CGAffineTransform t = CGAffineTransformMake(m[0] / size, m[1] / size, m[2] / size, m[3] / size, m[4], m[5]);
    return font_named(fontName, size, &t);
}

+ (NSFont *)fontWithDescriptor:(NSFontDescriptor *)descriptor size:(CGFloat)fontSize
{
    if (!descriptor)
        return nil;
    NSDictionary *attrs = descriptor.fontAttributes;
    if (fontSize <= 0)
        fontSize = [attrs[NSFontSizeAttribute] doubleValue];
    if (fontSize <= 0)
        fontSize = 12;
    NSString *usage = attrs[UIFUIUsageAttribute];
    if (usage) {
        NSFont *f = UIFSystemFontForUsage(usage, fontSize);
        if (f)
            return f;
    }
    NSDictionary *traits = attrs[NSFontTraitsAttribute];
    NSString *name = attrs[NSFontNameAttribute];
    if (!name && [traits isKindOfClass:[NSDictionary class]] && traits[@"NSCTFontUIFontDesignTrait"] && !attrs[NSFontFamilyAttribute]) {
        /* A system design: Finch's serif and monospaced stand-ins, or the system font. */
        NSString *design = traits[@"NSCTFontUIFontDesignTrait"];
        CGFloat weight = [traits[NSFontWeightTrait] doubleValue];
        if ([design isEqual:NSFontDescriptorSystemDesignSerif])
            return font_named(weight >= 0.3 ? @"Times-Bold" : @"Times-Roman", fontSize, NULL);
        if ([design isEqual:NSFontDescriptorSystemDesignMonospaced])
            return [self monospacedSystemFontOfSize:fontSize weight:weight];
        return [self systemFontOfSize:fontSize weight:weight];
    }
    if (name) {
        NSFont *f = font_named(name, fontSize, NULL);
        if (f)
            return f;
    }
    NSFontDescriptor *d = [descriptor fontDescriptorWithSize:fontSize];
    CTFontRef ct = CTFontCreateWithFontDescriptor((CTFontDescriptorRef)d, fontSize, NULL);
    if (!ct)
        return nil;
    NSString *ps = [(NSString *)CTFontCopyPostScriptName(ct) autorelease];
    CFRelease(ct);
    NSFont *f = font_named(ps, fontSize, NULL);
    NSNumber *sym = [traits isKindOfClass:[NSDictionary class]] ? traits[NSFontSymbolicTrait] : nil;
    if (f && sym) {
        CTFontSymbolicTraits want = (CTFontSymbolicTraits)sym.unsignedIntValue & (kCTFontTraitBold | kCTFontTraitItalic);
        if (want && (CTFontGetSymbolicTraits((CTFontRef)f) & want) != want) {
            CTFontRef t = CTFontCreateCopyWithSymbolicTraits((CTFontRef)f, fontSize, NULL, want, want);
            if (t) {
                NSString *tn = [(NSString *)CTFontCopyPostScriptName(t) autorelease];
                CFRelease(t);
                NSFont *tf = font_named(tn, fontSize, NULL);
                if (tf)
                    f = tf;
            }
        }
    }
    return f;
}

+ (NSFont *)fontWithDescriptor:(NSFontDescriptor *)descriptor textTransform:(NSAffineTransform *)textTransform
{
    if (!textTransform)
        return [self fontWithDescriptor:descriptor size:0];
    NSAffineTransformStruct t = textTransform.transformStruct;
    CGFloat m[6] = {t.m11, t.m12, t.m21, t.m22, t.tX, t.tY};
    NSString *name = [descriptor objectForKey:NSFontNameAttribute];
    if (!name)
        name = [[self fontWithDescriptor:descriptor size:0] fontName];
    return [self fontWithName:name matrix:m];
}

+ (NSFont *)userFontOfSize:(CGFloat)fontSize
{
    return user_font(@"NSFont", @"NSFontSize", @"Helvetica", 12, fontSize);
}

+ (NSFont *)userFixedPitchFontOfSize:(CGFloat)fontSize
{
    return user_font(@"NSFixedPitchFont", @"NSFixedPitchFontSize", @"Menlo-Regular", 11, fontSize);
}

static void
set_user_font(NSFont *font, NSString *nameKey, NSString *sizeKey)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (font) {
        [d setObject:font.fontName forKey:nameKey];
        [d setObject:@(font.pointSize) forKey:sizeKey];
    } else {
        [d removeObjectForKey:nameKey];
        [d removeObjectForKey:sizeKey];
    }
}

+ (void)setUserFont:(NSFont *)font { set_user_font(font, @"NSFont", @"NSFontSize"); }
+ (void)setUserFixedPitchFont:(NSFont *)font { set_user_font(font, @"NSFixedPitchFont", @"NSFixedPitchFontSize"); }

+ (NSFont *)systemFontOfSize:(CGFloat)fontSize
{
    return system_font_with_weight(fontSize > 0 ? fontSize : 13, 0, nil);
}

+ (NSFont *)boldSystemFontOfSize:(CGFloat)fontSize
{
    return system_font_with_weight(fontSize > 0 ? fontSize : 13, (CGFloat)0.4f, nil);
}

+ (NSFont *)systemFontOfSize:(CGFloat)fontSize weight:(NSFontWeight)weight
{
    return system_font_with_weight(fontSize > 0 ? fontSize : 13, weight, nil);
}

+ (NSFont *)systemFontOfSize:(CGFloat)fontSize weight:(NSFontWeight)weight width:(NSFontWidth)width
{
    NSDictionary *extra = @{NSFontTraitsAttribute : @{NSFontWidthTrait : @(width)}};
    return system_font_with_weight(fontSize > 0 ? fontSize : 13, weight, extra);
}

+ (NSFont *)monospacedDigitSystemFontOfSize:(CGFloat)fontSize weight:(NSFontWeight)weight
{
    NSDictionary *extra = @{NSFontFeatureSettingsAttribute :
                                @[ @{NSFontFeatureSelectorIdentifierKey : @0, NSFontFeatureTypeIdentifierKey : @6} ]};
    return system_font_with_weight(fontSize > 0 ? fontSize : 13, weight, extra);
}

+ (NSFont *)monospacedSystemFontOfSize:(CGFloat)fontSize weight:(NSFontWeight)weight
{
    /* SF Mono's place is taken by Menlo's (DejaVu Sans Mono on Finch). */
    size_t i = weight_index(weight);
    return font_named(i >= 5 ? @"Menlo-Bold" : @"Menlo-Regular", fontSize > 0 ? fontSize : 13, NULL);
}

+ (NSFont *)labelFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize > 0 ? fontSize : 10]; }
+ (NSFont *)titleBarFontOfSize:(CGFloat)fontSize
{
    return UIFSystemFontForUsage(@"UICTFontTextStyleHeadline", fontSize > 0 ? fontSize : 13);
}
+ (NSFont *)menuFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize > 0 ? fontSize : 13]; }
+ (NSFont *)menuBarFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize > 0 ? fontSize : 13]; }
+ (NSFont *)messageFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize > 0 ? fontSize : 13]; }
+ (NSFont *)paletteFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize > 0 ? fontSize : 11]; }
+ (NSFont *)toolTipsFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize > 0 ? fontSize : 11]; }
+ (NSFont *)controlContentFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize > 0 ? fontSize : 12]; }

+ (CGFloat)systemFontSize { return 13; }
+ (CGFloat)smallSystemFontSize { return 11; }
+ (CGFloat)labelFontSize { return 10; }

+ (CGFloat)systemFontSizeForControlSize:(NSControlSize)controlSize
{
    switch (controlSize) {
    case NSControlSizeMini: return 9;
    case NSControlSizeSmall: return 11;
    default: return 13;
    }
}

+ (NSFont *)preferredFontForTextStyle:(NSFontTextStyle)style options:(NSDictionary *)options
{
    NSFontDescriptor *d = [NSFontDescriptor preferredFontDescriptorForTextStyle:style options:options];
    return [self fontWithDescriptor:d size:0];
}

/* Abstract: an app's NSFont subclass overrides what it needs. */
- (CTFontRef)_ctFont { return (CTFontRef)self; }

- (NSString *)fontName { return [(NSString *)CTFontCopyPostScriptName(self._ctFont) autorelease]; }
- (CGFloat)pointSize { return CTFontGetSize(self._ctFont); }

- (const CGFloat *)matrix
{
    CGFloat s = self.pointSize;
    CGAffineTransform t = CTFontGetMatrix(self._ctFont);
    CGFloat m[6] = {t.a * s, t.b * s, t.c * s, t.d * s, t.tx, t.ty};
    return interned_matrix(m);
}

- (NSString *)familyName { return [(NSString *)CTFontCopyFamilyName(self._ctFont) autorelease]; }
- (NSString *)displayName { return [(NSString *)CTFontCopyDisplayName(self._ctFont) autorelease]; }

- (NSFontDescriptor *)fontDescriptor
{
    NSFontDescriptor *d = system_font_info(self) ? UIFSystemFontDescriptor(self) : nil;
    return d ? d : [(NSFontDescriptor *)CTFontCopyFontDescriptor(self._ctFont) autorelease];
}

- (NSAffineTransform *)textTransform
{
    /* The identity for a font made with only a size; its matrix for one made with a matrix. */
    NSAffineTransform *t = [NSAffineTransform transform];
    if (CGAffineTransformIsIdentity(CTFontGetMatrix(self._ctFont)))
        return t;
    const CGFloat *m = self.matrix;
    t.transformStruct = (NSAffineTransformStruct){m[0], m[1], m[2], m[3], m[4], m[5]};
    return t;
}

- (NSUInteger)numberOfGlyphs { return (NSUInteger)CTFontGetGlyphCount(self._ctFont); }
- (NSStringEncoding)mostCompatibleStringEncoding { return NSMacOSRomanStringEncoding; }
- (NSCharacterSet *)coveredCharacterSet { return [(NSCharacterSet *)CTFontCopyCharacterSet(self._ctFont) autorelease]; }

- (NSRect)boundingRectForFont { return NSRectFromCGRect(CTFontGetBoundingBox(self._ctFont)); }

- (NSSize)maximumAdvancement
{
    /* hhea's advanceWidthMax, in points. */
    CFDataRef hhea = CTFontCopyTable(self._ctFont, kCTFontTableHhea, 0);
    CGFloat w = 0;
    if (hhea && CFDataGetLength(hhea) >= 12) {
        const UInt8 *p = CFDataGetBytePtr(hhea);
        w = (CGFloat)(p[10] << 8 | p[11]) * self.pointSize / CTFontGetUnitsPerEm(self._ctFont);
    }
    if (hhea)
        CFRelease(hhea);
    return NSMakeSize(w, 0);
}

- (CGFloat)ascender { return CTFontGetAscent(self._ctFont); }
- (CGFloat)descender { return -CTFontGetDescent(self._ctFont); }
- (CGFloat)leading { return CTFontGetLeading(self._ctFont); }
- (CGFloat)underlinePosition { return CTFontGetUnderlinePosition(self._ctFont); }
- (CGFloat)underlineThickness { return CTFontGetUnderlineThickness(self._ctFont); }
- (CGFloat)italicAngle { return CTFontGetSlantAngle(self._ctFont); }
- (CGFloat)capHeight { return CTFontGetCapHeight(self._ctFont); }
- (CGFloat)xHeight { return CTFontGetXHeight(self._ctFont); }
- (BOOL)isFixedPitch { return (CTFontGetSymbolicTraits(self._ctFont) & kCTFontTraitMonoSpace) != 0; }

- (NSRect)boundingRectForCGGlyph:(CGGlyph)glyph
{
    CGRect r;
    CTFontGetBoundingRectsForGlyphs(self._ctFont, kCTFontOrientationDefault, &glyph, &r, 1);
    return NSRectFromCGRect(r);
}

- (NSSize)advancementForCGGlyph:(CGGlyph)glyph
{
    CGSize s;
    CTFontGetAdvancesForGlyphs(self._ctFont, kCTFontOrientationDefault, &glyph, &s, 1);
    return NSMakeSize(s.width, 0);
}

- (void)getBoundingRects:(NSRectArray)bounds forCGGlyphs:(const CGGlyph *)glyphs count:(NSUInteger)glyphCount
{
    CTFontGetBoundingRectsForGlyphs(self._ctFont, kCTFontOrientationDefault, glyphs, (CGRect *)bounds, (CFIndex)glyphCount);
}

- (void)getAdvancements:(NSSizeArray)advancements forCGGlyphs:(const CGGlyph *)glyphs count:(NSUInteger)glyphCount
{
    CTFontGetAdvancesForGlyphs(self._ctFont, kCTFontOrientationDefault, glyphs, (CGSize *)advancements, (CFIndex)glyphCount);
    for (NSUInteger i = 0; i < glyphCount; i++)
        advancements[i].height = 0;
}

- (NSGlyph)glyphWithName:(NSString *)name { return CTFontGetGlyphWithName(self._ctFont, (CFStringRef)name); }
- (NSRect)boundingRectForGlyph:(NSGlyph)glyph { return [self boundingRectForCGGlyph:(CGGlyph)glyph]; }
- (NSSize)advancementForGlyph:(NSGlyph)glyph { return [self advancementForCGGlyph:(CGGlyph)glyph]; }

- (void)getBoundingRects:(NSRectArray)bounds forGlyphs:(const NSGlyph *)glyphs count:(NSUInteger)glyphCount
{
    for (NSUInteger i = 0; i < glyphCount; i++)
        bounds[i] = [self boundingRectForCGGlyph:(CGGlyph)glyphs[i]];
}

- (void)getAdvancements:(NSSizeArray)advancements forGlyphs:(const NSGlyph *)glyphs count:(NSUInteger)glyphCount
{
    for (NSUInteger i = 0; i < glyphCount; i++)
        advancements[i] = [self advancementForCGGlyph:(CGGlyph)glyphs[i]];
}

- (void)getAdvancements:(NSSizeArray)advancements forPackedGlyphs:(const void *)packedGlyphs length:(NSUInteger)length
{
    const unsigned char *p = packedGlyphs;
    for (NSUInteger i = 0; i + 1 < length; i += 2)
        advancements[i / 2] = [self advancementForCGGlyph:(CGGlyph)(p[i] << 8 | p[i + 1])];
}

/* The font in a CG context: AppKit's NSGraphicsContext, found at run time. */
static void
set_in_cgcontext(NSFont *font, CGContextRef cg)
{
    if (!cg)
        return;
    CGFontRef g = CTFontCopyGraphicsFont(font._ctFont, NULL);
    CGContextSetFont(cg, g);
    CGContextSetFontSize(cg, font.pointSize);
    CGFontRelease(g);
}

- (void)set { set_in_cgcontext(self, UIFCurrentCGContext()); }

- (void)setInContext:(NSGraphicsContext *)graphicsContext
{
    id ctx = graphicsContext;
    set_in_cgcontext(self, [ctx respondsToSelector:@selector(CGContext)] ? [ctx CGContext] : NULL);
}

- (NSFont *)verticalFont { return self; }
- (BOOL)isVertical { return NO; }
- (NSFont *)printerFont { return self; }
- (NSFont *)screenFont { return self; }
- (NSFont *)screenFontWithRenderingMode:(NSFontRenderingMode)renderingMode { return self; }
- (NSFontRenderingMode)renderingMode { return NSFontAntialiasedRenderingMode; }

- (NSFont *)fontWithSize:(CGFloat)fontSize
{
    if (fontSize <= 0)
        fontSize = 12;
    UIFSystemFontInfo *info = system_font_info(self);
    if (info) {
        NSMutableDictionary *a = [[info->descriptor.fontAttributes mutableCopy] autorelease];
        [a removeObjectForKey:NSFontSizeAttribute];
        NSString *usage = a[UIFUIUsageAttribute];
        [a removeObjectForKey:UIFUIUsageAttribute];
        for (size_t i = 0; i < NWEIGHTS; i++)
            if ([usage isEqual:system_weights[i].usage])
                return system_font_with_weight(fontSize, system_weights[i].weight, a.count ? a : nil);
        NSFont *f = UIFSystemFontForUsage(usage, fontSize);
        if (f)
            return f;
    }
    CGAffineTransform t = CTFontGetMatrix(self._ctFont);
    NSFont *f = font_named(self.fontName, fontSize, &t);
    return f ? f : self;
}

#pragma mark Copying, coding, equality, description

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (Class)classForCoder { return [NSFont class]; }
- (Class)classForKeyedArchiver { return [NSFont class]; }
- (id)replacementObjectForKeyedArchiver:(NSKeyedArchiver *)archiver { return self; }
- (id)replacementObjectForCoder:(NSCoder *)coder { return self; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    UIFSystemFontInfo *info = system_font_info(self);
    NSString *name = info ? info->archiveName : self.fontName;
    const CGFloat *m = self.matrix;
    CGFloat s = self.pointSize;
    BOOL plain = m[0] == s && m[1] == 0 && m[2] == 0 && m[3] == s && m[4] == 0 && m[5] == 0;
    /* (0x10 marks a font with no matrix of its own.) */
    NSInteger flags = info ? info->flags : plain ? kFontFlagBase : 0;
    if (coder.allowsKeyedCoding) {
        [coder encodeObject:name forKey:@"NSName"];
        [coder encodeDouble:s forKey:@"NSSize"];
        [coder encodeInteger:flags forKey:@"NSfFlags"];
        if (!plain) {
            float f[6];
            for (int i = 0; i < 6; i++)
                f[i] = (float)m[i];
            /* Big-endian floats, as Apple's archives hold them. */
            uint32_t be[6];
            for (int i = 0; i < 6; i++) {
                uint32_t u;
                memcpy(&u, &f[i], 4);
                be[i] = CFSwapInt32HostToBig(u);
            }
            [coder encodeObject:[NSData dataWithBytes:be length:sizeof be] forKey:@"NSMatrix"];
        }
    } else {
        float size = (float)s;
        int iflags = (int)flags;
        [coder encodeObject:name];
        [coder encodeValueOfObjCType:@encode(float) at:&size];
        [coder encodeValueOfObjCType:@encode(int) at:&iflags];
    }
}

/* The font an archive names. */
static NSFont *
decoded_font(NSString *name, CGFloat size, NSInteger flags, NSData *matrix)
{
    if (flags & kFontFlagSystem)
        return [NSFont systemFontOfSize:size];
    if (flags & kFontFlagBoldSystem)
        return [NSFont boldSystemFontOfSize:size];
    if ([name isEqual:@".AppleSystemUIFaceHeadline"])
        return [NSFont titleBarFontOfSize:size];
    NSFont *f = nil;
    if ([matrix isKindOfClass:[NSData class]] && matrix.length == 24) {
        uint32_t be[6];
        memcpy(be, matrix.bytes, sizeof be);
        CGFloat m[6];
        for (int i = 0; i < 6; i++) {
            uint32_t u = CFSwapInt32BigToHost(be[i]);
            float fl;
            memcpy(&fl, &u, 4);
            m[i] = fl;
        }
        f = [NSFont fontWithName:name matrix:m];
    }
    if (!f)
        f = [NSFont fontWithName:name size:size];
    if (!f && (flags & kFontFlagFixedPitchUser))
        f = [NSFont userFixedPitchFontOfSize:size];
    if (!f)
        f = [NSFont userFontOfSize:size];
    return f;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSFont *f;
    if (coder.allowsKeyedCoding) {
        NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:@"NSName"];
        f = decoded_font(name, [coder decodeDoubleForKey:@"NSSize"], [coder decodeIntegerForKey:@"NSfFlags"],
                         [coder decodeObjectOfClass:[NSData class] forKey:@"NSMatrix"]);
    } else {
        NSString *name = [coder decodeObject];
        float size = 0;
        int flags = 0;
        [coder decodeValueOfObjCType:@encode(float) at:&size size:sizeof size];
        [coder decodeValueOfObjCType:@encode(int) at:&flags size:sizeof flags];
        f = decoded_font(name, size, flags, nil);
    }
    if (f != self)
        [self release];
    return [f retain];
}

- (NSString *)description
{
    const CGFloat *m = self.matrix;
    CGFloat s = self.pointSize;
    NSString *matrix = @"";
    if (!(m[0] == s && m[1] == 0 && m[2] == 0 && m[3] == s && m[4] == 0 && m[5] == 0))
        matrix = [NSString stringWithFormat:@"%.1f %.1f %.1f %.1f %.1f %.1f", m[0], m[1], m[2], m[3], m[4], m[5]];
    UniChar space = ' ';
    CGGlyph g = 0;
    CGSize adv = CGSizeZero;
    if (CTFontGetGlyphsForCharacters(self._ctFont, &space, &g, 1))
        CTFontGetAdvancesForGlyphs(self._ctFont, kCTFontOrientationDefault, &g, &adv, 1);
    CGFontRef cg = CTFontCopyGraphicsFont(self._ctFont, NULL);
    NSString *d = [NSString stringWithFormat:@"\"%@ %.2f pt. P [%@] (%p) fobj=%p, spc=%.2f\"", self.fontName, s, matrix,
                                             self, system_font_info(self) ? (void *)self : (void *)cg, adv.width];
    CGFontRelease(cg);
    return d;
}

@end

@implementation NSFontPlaceholder
- (instancetype)retain { return self; }
- (oneway void)release { }
- (instancetype)autorelease { return self; }
- (NSUInteger)retainCount { return NSUIntegerMax; }
- (void)dealloc { }
- (instancetype)init { return nil; }
@end

@implementation UIFont
@end

/* CTFont's class. Memory, equality and hashing are CoreFoundation's. */
@implementation NSCTFont

+ (void)load
{
    /* Before any font is made: a CTFont's class is fixed when it is created. */
    _CFRuntimeBridgeTypeToClass(CTFontGetTypeID(), (const void *)self);
    make_caches();
}

- (instancetype)retain { return (id)CFRetain((CFTypeRef)self); }
- (oneway void)release { CFRelease((CFTypeRef)self); }
- (NSUInteger)retainCount { return (NSUInteger)CFGetRetainCount((CFTypeRef)self); }
- (BOOL)_tryRetain { return _CFTryRetain((CFTypeRef)self) != NULL; }
- (BOOL)_isDeallocating { return _CFIsDeallocating((CFTypeRef)self); }
- (BOOL)allowsWeakReference { return !_CFIsDeallocating((CFTypeRef)self); }
- (BOOL)retainWeakReference { return _CFTryRetain((CFTypeRef)self) != NULL; }
- (CFTypeID)_cfTypeID { return CFGetTypeID((CFTypeRef)self); }
- (void)dealloc { }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }
- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSCTFont class]])
        return NO;
    return CFEqual((CFTypeRef)self, (CFTypeRef)other);
}

@end
