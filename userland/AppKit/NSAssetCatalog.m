/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Asset catalogs in AppKit: named colours, images and data from a bundle's
 * compiled Assets.car, read through Finch's CoreUI (userland/CoreUI), as
 * Apple's AppKit does through its.
 *
 * - NSColor colorNamed: gives an NSCoreUICatalogColor (Apple's class name):
 *   a catalog colour named "#$assets-mainBundleID" (the main bundle) or
 *   "#$assets-<bundle identifier>", resolved each time it's used by the
 *   current drawing appearance (DarkAqua falls back to the default
 *   appearance, Vibrant to Aqua or DarkAqua) and the main screen's gamut;
 *   a colour the catalog marks as a system colour resolves to that one.
 *   Nibs archive these with the same catalog name (NSColorSpace 6).
 * - NSImage imageNamed: and NSBundle's imageForResource: find catalog images:
 *   an NSImage with an NSCoreUIImageRep per scale, each drawing the rendition
 *   for the current appearance; template from the catalog (or, for automatic
 *   rendering, a name ending in "Template", as Apple's).
 *   NSImageNameApplicationIcon is the CFBundleIconName image, if the app's
 *   catalog has it.
 * - NSDataAsset.
 */
#import "AppKitDrawing.h"
#import "CoreUI/CUICatalog.h"

NSColor *FinchCatalogColorNamed(NSColorName name, NSBundle *bundle);
NSColor *FinchCatalogColorWithCatalogName(NSColorListName catalog, NSColorName name);
NSImage *FinchCatalogImageNamed(NSString *name, NSBundle *bundle);

/* MARK: - Catalogs */

static CUICatalog *
catalog_for(NSBundle *bundle)
{
    return [CUICatalog defaultUICatalogForBundle:bundle ?: [NSBundle mainBundle]];
}

/* The catalog names Apple's AppKit gives a bundle's colours. */
static NSString *
catalog_name(NSBundle *bundle)
{
    if (!bundle || bundle == [NSBundle mainBundle])
        return @"#$assets-mainBundleID";
    return [@"#$assets-" stringByAppendingString:bundle.bundleIdentifier ?: bundle.bundlePath.lastPathComponent];
}

/* The catalog appearances to try for the current drawing appearance, best first: those the catalog lists
 * (a name it doesn't list would mean its default), then the default. */
static NSArray<NSString *> *
appearance_names(CUICatalog *cat)
{
    NSString *a = [[NSAppearance currentDrawingAppearance] name] ?: NSAppearanceNameAqua;
    NSArray *chain = @[ a ];
    if ([a isEqualToString:NSAppearanceNameVibrantDark])
        chain = @[ a, NSAppearanceNameDarkAqua ];
    else if ([a isEqualToString:NSAppearanceNameVibrantLight])
        chain = @[ a, NSAppearanceNameAqua ];
    NSArray *listed = [cat appearanceNames];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *n in chain)
        if ([listed containsObject:n])
            [names addObject:n];
    [names addObject:@"NSAppearanceNameSystem"];
    return names;
}

static NSInteger
display_gamut(void)
{
    return [[NSScreen mainScreen] canRepresentDisplayGamut:NSDisplayGamutP3] ? 1 : 0;
}

/* MARK: - Catalog colours */

@interface NSCoreUICatalogColor : NSColor {
    NSBundle *_bundle;
    NSString *_catalog, *_name;
}
@end

@implementation NSCoreUICatalogColor

- (instancetype)_initWithName:(NSString *)name bundle:(NSBundle *)bundle catalogName:(NSString *)catalog
{
    if ((self = [super init])) {
        _name = [name copy];
        _bundle = [bundle retain];
        _catalog = [catalog copy];
    }
    return self;
}

- (void)dealloc
{
    [_name release];
    [_bundle release];
    [_catalog release];
    [super dealloc];
}

/* The colour for the current appearance, as a component colour. */
- (NSColor *)_resolved
{
    CUICatalog *cat = catalog_for(_bundle);
    NSInteger gamut = display_gamut();
    for (NSString *a in appearance_names(cat)) {
        CUINamedColor *c = [cat colorWithName:_name displayGamut:gamut deviceIdiom:0 appearanceName:a];
        if (!c)
            continue;
        NSString *sys = c.systemColorName;
        if (sys.length && [NSColor respondsToSelector:NSSelectorFromString(sys)]) {
            NSColor *s = ((NSColor * (*)(id, SEL)) objc_msgSend)([NSColor class], NSSelectorFromString(sys));
            NSColor *r = [s colorUsingType:NSColorTypeComponentBased];
            if (r)
                return r;
        }
        if (c.cgColor)
            return [NSColor colorWithCGColor:c.cgColor];
    }
    return [NSColor clearColor];
}

- (NSColorType)type { return NSColorTypeCatalog; }
- (NSColorSpaceName)colorSpaceName { return NSNamedColorSpace; }
- (NSColorListName)catalogNameComponent { return _catalog; }
- (NSColorName)colorNameComponent { return _name; }
- (NSString *)localizedCatalogNameComponent { return _catalog; }
- (NSString *)localizedColorNameComponent { return _name; }
- (CGFloat)alphaComponent { return [[self _resolved] alphaComponent]; }
- (CGColorRef)_finchCGColor { return [[self _resolved] _finchCGColor]; }
- (CGColorRef)CGColor { return [self _finchCGColor]; }
- (NSString *)description { return [NSString stringWithFormat:@"Catalog color: %@ %@", _catalog, _name]; }
- (NSColor *)colorUsingColorSpace:(NSColorSpace *)space { return [[self _resolved] colorUsingColorSpace:space]; }
- (NSColor *)colorWithAlphaComponent:(CGFloat)alpha { return [[self _resolved] colorWithAlphaComponent:alpha]; }

- (NSColor *)colorUsingColorSpaceName:(NSColorSpaceName)name
{
    if (!name || [name isEqualToString:NSNamedColorSpace])
        return self;
    return [[self _resolved] colorUsingColorSpaceName:name];
}

- (NSColor *)blendedColorWithFraction:(CGFloat)fraction ofColor:(NSColor *)color
{
    return [[self _resolved] blendedColorWithFraction:fraction ofColor:color];
}

- (NSColor *)colorUsingType:(NSColorType)type
{
    if (type == NSColorTypeCatalog)
        return self;
    return type == NSColorTypeComponentBased ? [self _resolved] : nil;
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSCoreUICatalogColor class]])
        return NO;
    NSCoreUICatalogColor *o = other;
    return [o->_name isEqual:_name] && [o->_catalog isEqual:_catalog];
}

- (NSUInteger)hash { return [_name hash]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:6 forKey:@"NSColorSpace"];
    [coder encodeObject:_catalog forKey:@"NSCatalogName"];
    [coder encodeObject:_name forKey:@"NSColorName"];
    [coder encodeObject:[self _resolved] forKey:@"NSColor"];
}

@end

NSColor *
FinchCatalogColorNamed(NSColorName name, NSBundle *bundle)
{
    if (!name.length)
        return nil;
    bundle = bundle ?: [NSBundle mainBundle];
    CUICatalog *cat = catalog_for(bundle);
    if (!cat || ![cat colorWithName:name displayGamut:0 deviceIdiom:0 appearanceName:nil])
        return nil;
    return [[[NSCoreUICatalogColor alloc] _initWithName:name bundle:bundle catalogName:catalog_name(bundle)] autorelease];
}

/* An archived catalog colour: "#$assets-mainBundleID" or "#$assets-<bundle identifier>". */
NSColor *
FinchCatalogColorWithCatalogName(NSColorListName catalog, NSColorName name)
{
    if (![catalog hasPrefix:@"#$assets"])
        return nil;
    NSString *ident = catalog.length > 9 ? [catalog substringFromIndex:9] : nil;
    NSBundle *b = !ident || [ident isEqualToString:@"mainBundleID"] ? [NSBundle mainBundle] : [NSBundle bundleWithIdentifier:ident];
    return b ? FinchCatalogColorNamed(name, b) : nil;
}

/* MARK: - Catalog images */

@interface NSCoreUIImageRep : NSImageRep {
    CUICatalog *_catalog;
    NSString *_name;
    CGFloat _scale;
}
@end

@implementation NSCoreUIImageRep

- (instancetype)_initWithCatalog:(CUICatalog *)catalog name:(NSString *)name image:(CUINamedImage *)image
{
    if ((self = [super init])) {
        _catalog = [catalog retain];
        _name = [name copy];
        _scale = image.scale;
        CGImageRef cg = image.image;
        [self setSize:image.size];
        [self setPixelsWide:cg ? (NSInteger)CGImageGetWidth(cg) : 0];
        [self setPixelsHigh:cg ? (NSInteger)CGImageGetHeight(cg) : 0];
        [self setBitsPerSample:cg ? (NSInteger)CGImageGetBitsPerComponent(cg) : 8];
        CGImageAlphaInfo ai = cg ? CGImageGetAlphaInfo(cg) : kCGImageAlphaNone;
        BOOL alpha = ai != kCGImageAlphaNone && ai != kCGImageAlphaNoneSkipLast && ai != kCGImageAlphaNoneSkipFirst;
        [self setAlpha:alpha];
        [self setOpaque:!alpha];
        BOOL gray = cg && CGColorSpaceGetModel(CGImageGetColorSpace(cg)) == kCGColorSpaceModelMonochrome;
        [self setColorSpaceName:gray ? NSCalibratedWhiteColorSpace : NSCalibratedRGBColorSpace];
    }
    return self;
}

- (void)dealloc
{
    [_catalog release];
    [_name release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

/* The rendition for the current appearance at this rep's scale. */
- (CGImageRef)_image
{
    for (NSString *a in appearance_names(_catalog)) {
        CUINamedImage *i = [_catalog imageWithName:_name scaleFactor:_scale displayGamut:display_gamut() layoutDirection:0
                                    appearanceName:a];
        if (i.image)
            return i.image;
    }
    return NULL;
}

- (BOOL)draw
{
    NSSize s = [self size];
    return [self drawInRect:NSMakeRect(0, 0, s.width, s.height)];
}

- (BOOL)drawInRect:(NSRect)rect
{
    CGContextRef c = FinchCurrentCGContext();
    CGImageRef im = [self _image];
    if (!c || !im)
        return NO;
    CGContextSaveGState(c);
    CGContextSetCompositeOperation(c, 1);
    CGContextDrawImage(c, NSRectToCGRect(rect), im);
    CGContextRestoreGState(c);
    return YES;
}

- (BOOL)drawInRect:(NSRect)dstSpacePortionRect fromRect:(NSRect)srcSpacePortionRect operation:(NSCompositingOperation)op
          fraction:(CGFloat)requestedAlpha respectFlipped:(BOOL)respectContextIsFlipped hints:(NSDictionary *)hints
{
    return FinchDrawCGImage([self _image], [self size], dstSpacePortionRect, srcSpacePortionRect, op, requestedAlpha,
                            respectContextIsFlipped, hints);
}

- (CGImageRef)CGImageForProposedRect:(NSRect *)proposedDestRect context:(NSGraphicsContext *)context hints:(NSDictionary *)hints
{
    return [self _image];
}

@end

static NSImage *
image_from_catalog(CUICatalog *cat, NSString *name)
{
    NSMutableDictionary *byScale = [NSMutableDictionary dictionary];
    CUINamedImage *any = nil;
    for (id l in [cat imagesWithName:name]) {
        if (![l isKindOfClass:[CUINamedImage class]])
            continue;
        CUINamedImage *i = l;
        if (i.appearanceIdentifier != 0 || i.displayGamut != 0 || i.idiom != 0)
            continue;
        NSNumber *k = @(i.scale);
        if (!byScale[k])
            byScale[k] = i;
        any = any ?: i;
    }
    if (!any)
        return nil;
    NSImage *image = [[[NSImage alloc] initWithSize:any.size] autorelease];
    for (NSNumber *k in [[byScale allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        CUINamedImage *i = [cat imageWithName:name scaleFactor:k.doubleValue displayGamut:0 layoutDirection:0 appearanceName:nil] ?: byScale[k];
        NSCoreUIImageRep *r = [[NSCoreUIImageRep alloc] _initWithCatalog:cat name:name image:i];
        [image addRepresentation:r];
        [r release];
    }
    NSInteger mode = any.templateRenderingMode;
    [image setTemplate:mode == 1 || (mode != 3 && [name hasSuffix:@"Template"])];
    return image;
}

/* The app's icon, from its catalog: every size of the CFBundleIconName image, 128 points as Apple's. */
static NSImage *
app_icon(void)
{
    NSString *icon = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIconName"];
    CUICatalog *cat = [icon isKindOfClass:[NSString class]] ? catalog_for(nil) : nil;
    if (!cat)
        return nil;
    NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(128, 128)] autorelease];
    for (id l in [cat imagesWithName:icon]) {
        if (![l isKindOfClass:[CUINamedImage class]] || [l displayGamut] != 0 || [l appearanceIdentifier] != 0)
            continue;
        CGImageRef cg = [(CUINamedImage *)l image];
        if (!cg)
            continue;
        NSBitmapImageRep *r = [[NSBitmapImageRep alloc] initWithCGImage:cg];
        [r setSize:[(CUINamedImage *)l size]];
        [image addRepresentation:r];
        [r release];
    }
    return image.representations.count ? image : nil;
}

NSImage *
FinchCatalogImageNamed(NSString *name, NSBundle *bundle)
{
    if (!name.length)
        return nil;
    if (!bundle && [name isEqualToString:NSImageNameApplicationIcon])
        return app_icon();
    CUICatalog *cat = catalog_for(bundle);
    return cat ? image_from_catalog(cat, name) : nil;
}

@implementation NSBundle (NSBundleImageExtension)

- (NSImage *)imageForResource:(NSImageName)name
{
    NSImage *i = FinchCatalogImageNamed(name, self);
    if (i)
        return i;
    NSString *path = [self pathForImageResource:name];
    if (!path)
        return nil;
    NSImage *image = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
    /* as Apple's: name@2x beside it is the same image at twice the pixels */
    NSString *ext = path.pathExtension, *stem = path.stringByDeletingPathExtension;
    if (image && ![stem hasSuffix:@"@2x"]) {
        NSString *hi = [[stem stringByAppendingString:@"@2x"] stringByAppendingPathExtension:ext];
        NSImageRep *rep = [[NSFileManager defaultManager] fileExistsAtPath:hi] ? [NSImageRep imageRepWithContentsOfFile:hi] : nil;
        if (rep) {
            [rep setSize:[image size]];
            [image addRepresentation:rep];
        }
    }
    return image;
}

- (NSString *)pathForImageResource:(NSImageName)name
{
    if (!name.length)
        return nil;
    if (name.pathExtension.length)
        return [self pathForResource:name.stringByDeletingPathExtension ofType:name.pathExtension];
    for (NSString *ext in @[ @"png", @"tiff", @"tif", @"jpg", @"jpeg", @"gif", @"bmp", @"heic", @"icns", @"pdf" ]) {
        NSString *p = [self pathForResource:name ofType:ext];
        if (p)
            return p;
    }
    return nil;
}

- (NSURL *)URLForImageResource:(NSImageName)name
{
    NSString *p = [self pathForImageResource:name];
    return p ? [NSURL fileURLWithPath:p] : nil;
}

@end

/* MARK: - Data assets */

@implementation NSDataAsset {
    NSString *_name;
    NSData *_data;
    NSString *_type;
}

- (instancetype)initWithName:(NSDataAssetName)name bundle:(NSBundle *)bundle
{
    CUINamedData *d = name ? [catalog_for(bundle) dataWithName:name] : nil;
    NSData *data = d.data;
    if (!data) {
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        _name = [name copy];
        _data = [data copy];
        _type = [d.utiType copy];
    }
    return self;
}

- (instancetype)initWithName:(NSDataAssetName)name { return [self initWithName:name bundle:[NSBundle mainBundle]]; }

- (instancetype)init
{
    [self release];
    return nil;
}

- (void)dealloc
{
    [_name release];
    [_data release];
    [_type release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (NSDataAssetName)name { return _name; }
- (NSData *)data { return _data; }
- (NSString *)typeIdentifier { return _type; }

@end
