/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CUICatalog and the named lookups (CUINamedImage, CUINamedColor,
 * CUINamedData, CUINamedVectorImage) over Finch's .car reader
 * (CUIPrivate.h), with Apple's lookup rules as measured on macOS 26:
 *
 * - a name's facet gives the rendition key's fixed attributes (element,
 *   part, identifier); the renditions sharing them differ in appearance,
 *   scale, idiom, gamut, direction, ...
 * - the appearance must match exactly: a name the catalog's APPEARANCEKEYS
 *   lists means its id, any other name (or none) the default, 0. So asking a
 *   catalog with dark variants for a dark colour it lacks gives nil, and
 *   AppKit falls back itself;
 * - scale: the exact one, else the largest below, else the smallest above;
 * - idiom, subtype and gamut: the requested value, else 0 (universal, sRGB);
 * - other attributes prefer 0.
 */
#import "CUICatalog.h"
#import "CUIPrivate.h"
#import <ImageIO/ImageIO.h>

@interface CUICatalog () {
@public
    cui_store *_store;
    NSMutableDictionary *_atlases;  /* decoded atlas images by rendition */
    NSLock *_lock;
}
@end

@interface CUINamedLookup () {
@public
    CUICatalog *_catalog;
    const cui_rendition *_rendition;
    cui_csi _csi;
}
- (instancetype)_initWithName:(NSString *)name catalog:(CUICatalog *)catalog rendition:(const cui_rendition *)r csi:(const cui_csi *)csi;
@end

CGImageRef FinchCUICreateImageFromCSI(const cui_csi *c);

/* MARK: - Helpers */

static CGColorSpaceRef
space_for_id(unsigned cs)
{
    CFStringRef name;
    switch (cs) {
    case 2: name = kCGColorSpaceGenericGrayGamma2_2; break;
    case 3: name = kCGColorSpaceDisplayP3; break;
    case 4: name = kCGColorSpaceExtendedSRGB; break;
    case 5: name = kCGColorSpaceExtendedLinearSRGB; break;
    case 6: name = kCGColorSpaceExtendedGray; break;
    default: name = kCGColorSpaceSRGB; break;
    }
    return CGColorSpaceCreateWithName(name);
}

static BOOL
is_bitmap_layout(unsigned layout)
{
    return (layout >= 10 && layout < 1000 && layout != CUI_LAYOUT_GRADIENT && layout != CUI_LAYOUT_EFFECT) ||
           layout == CUI_LAYOUT_INTERNAL_LINK;
}

typedef struct {
    double scale;
    long idiom, gamut, direction;
    unsigned long subtype;
    uint16_t appearance;
    int part;  /* -1: the facet's */
} query;

typedef enum { WANT_IMAGE, WANT_COLOR, WANT_DATA, WANT_VECTOR, WANT_ANY } want_kind;

static BOOL
layout_wanted(want_kind k, const cui_csi *c)
{
    switch (k) {
    case WANT_IMAGE: return is_bitmap_layout(c->layout) || (c->layout == CUI_LAYOUT_VECTOR && c->pixel_format == CUI_FOURCC('P', 'D', 'F', ' '));
    case WANT_COLOR: return c->layout == CUI_LAYOUT_COLOR;
    case WANT_DATA: return c->layout == CUI_LAYOUT_DATA;
    case WANT_VECTOR: return c->layout == CUI_LAYOUT_VECTOR && c->pixel_format == CUI_FOURCC('P', 'D', 'F', ' ');
    case WANT_ANY: return YES;
    }
    return NO;
}

/* Higher is better; 0 rejects. */
static int
pref(unsigned have, unsigned want)
{
    return have == want ? 2 : have == 0 ? 1 : 0;
}

static int
scale_score(unsigned have, double want)
{
    unsigned w = (unsigned)ceil(want);
    if (have == w)
        return 1000;
    if (have && have < w)
        return 500 + (int)have;
    if (!have)
        return 400;
    return 300 - (int)have;
}

#define NSCORES 12

static int
compare_scores(const int *a, const int *b)
{
    for (int j = 0; j < NSCORES; j++)
        if (a[j] != b[j])
            return a[j] > b[j] ? 1 : -1;
    return 0;
}

/* The best rendition for a name, or NULL; *csi gets it parsed. Images may come from any part under the
 * name's identifier (an app icon's sizes are their own part), the facet's own part first. */
static const cui_rendition *
best_rendition(cui_store *s, const cui_facet *f, const query *q, want_kind kind, cui_csi *out)
{
    size_t first, n = cui_store_renditions_for_identifier(s, f->attrs.v[CUI_ATTR_IDENTIFIER], &first);
    const cui_rendition *best = NULL;
    int bscore[NSCORES] = {0};
    for (size_t i = first; i < first + n; i++) {
        const cui_rendition *r = &s->rends[i];
        const uint16_t *k = r->key.v;
        BOOL ok = YES;
        for (int a = 0; a < CUI_ATTR_MAX && ok; a++)
            if ((f->mask >> a) & 1) {
                if (a == CUI_ATTR_PART && q->part >= 0)
                    ok = k[a] == q->part;
                else if (a != CUI_ATTR_PART || kind != WANT_IMAGE)
                    ok = k[a] == f->attrs.v[a];
            }
        if (!ok || k[CUI_ATTR_APPEARANCE] != q->appearance)
            continue;
        int sc[NSCORES];
        sc[0] = k[CUI_ATTR_PART] == ((f->mask >> CUI_ATTR_PART) & 1 ? f->attrs.v[CUI_ATTR_PART] : 0);
        sc[1] = 2 * scale_score(k[CUI_ATTR_SCALE], q->scale);
        sc[2] = pref(k[CUI_ATTR_IDIOM], (unsigned)q->idiom);
        sc[3] = pref(k[CUI_ATTR_SUBTYPE], (unsigned)q->subtype);
        sc[4] = pref(k[CUI_ATTR_GAMUT], (unsigned)q->gamut);
        if (!sc[2] || !sc[3] || !sc[4])
            continue;
        sc[5] = k[CUI_ATTR_DIRECTION] == q->direction ? 2 : k[CUI_ATTR_DIRECTION] == 0 ? 1 : 0;
        sc[6] = k[CUI_ATTR_LOCALIZATION] == 0;
        sc[7] = k[CUI_ATTR_DEPLOYMENT];
        sc[8] = (k[CUI_ATTR_SIZE_CLASS_H] == 0) + (k[CUI_ATTR_SIZE_CLASS_V] == 0) + (k[CUI_ATTR_MEMORY_CLASS] == 0) +
                (k[CUI_ATTR_GRAPHICS_CLASS] == 0) + (k[CUI_ATTR_GLYPH_WEIGHT] == 0) + (k[CUI_ATTR_GLYPH_SIZE] == 0);
        sc[9] = (k[CUI_ATTR_STATE] == 0) + (k[CUI_ATTR_VALUE] == 0) + (k[CUI_ATTR_DIMENSION1] == 0) +
                (k[CUI_ATTR_LAYER] == 0) + (k[CUI_ATTR_PRESENTATION_STATE] == 0) + (k[CUI_ATTR_PREVIOUS_STATE] == 0) +
                (k[CUI_ATTR_PREVIOUS_VALUE] == 0) + (k[CUI_ATTR_SIZE] == 0);
        sc[10] = k[CUI_ATTR_DIMENSION2];  /* an icon's sizes: the largest */
        sc[11] = 1;
        if (compare_scores(sc, bscore) <= 0)
            continue;
        cui_csi c;
        if (!cui_csi_parse(r->csi, r->len, &c) || !layout_wanted(kind, &c))
            continue;
        if (kind == WANT_IMAGE && c.layout == CUI_LAYOUT_VECTOR) {  /* a bitmap of the same scale first */
            sc[1]--;
            if (compare_scores(sc, bscore) <= 0)
                continue;
        }
        best = r;
        *out = c;
        memcpy(bscore, sc, sizeof sc);
    }
    return best;
}

/* MARK: - CUICatalog */

@implementation CUICatalog

+ (BOOL)isValidAssetStorageWithURL:(NSURL *)url
{
    cui_store *s = url.isFileURL ? cui_store_open(url.fileSystemRepresentation) : NULL;
    cui_store_free(s);
    return s != NULL;
}

+ (instancetype)defaultUICatalogForBundle:(NSBundle *)bundle
{
    static NSMutableDictionary *cache;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSMutableDictionary alloc] init];
        lock = [[NSLock alloc] init];
    });
    NSString *path = [(bundle ?: [NSBundle mainBundle]) pathForResource:@"Assets" ofType:@"car"];
    if (!path)
        return nil;
    [lock lock];
    CUICatalog *c = [[cache objectForKey:path] retain];
    if (!c) {
        c = [[CUICatalog alloc] initWithURL:[NSURL fileURLWithPath:path] error:NULL];
        if (c)
            [cache setObject:c forKey:path];
    }
    [lock unlock];
    return [c autorelease];
}

- (instancetype)_initWithStore:(cui_store *)s error:(NSError **)error
{
    if (!s) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        [self release];
        return nil;
    }
    if ((self = [super init])) {
        _store = s;
        _atlases = [[NSMutableDictionary alloc] init];
        _lock = [[NSLock alloc] init];
    } else
        cui_store_free(s);
    return self;
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error
{
    if (!url.isFileURL) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        [self release];
        return nil;
    }
    return [self _initWithStore:cui_store_open(url.fileSystemRepresentation) error:error];
}

- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length error:(NSError **)error
{
    return [self _initWithStore:bytes ? cui_store_open_bytes(bytes, length) : NULL error:error];
}

- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error
{
    NSString *path = [bundle pathForResource:name ofType:@"car"];
    if (!path) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        [self release];
        return nil;
    }
    return [self initWithURL:[NSURL fileURLWithPath:path] error:error];
}

- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle
{
    return [self initWithName:name fromBundle:bundle error:NULL];
}

- (instancetype)init
{
    [self release];
    return nil;
}

- (void)dealloc
{
    cui_store_free(_store);
    [_atlases release];
    [_lock release];
    [super dealloc];
}

- (NSString *)debugDescription
{
    return [NSString stringWithFormat:@"<%@: %p> %zu renditions, %zu names", [self class], self, _store->nrends, _store->nfacets];
}

- (NSArray<NSString *> *)allImageNames
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:_store->nfacets];
    for (size_t i = 0; i < _store->nfacets; i++) {
        NSString *n = [NSString stringWithUTF8String:_store->facets[i].name];
        if (n)
            [a addObject:n];
    }
    return a;
}

- (NSArray<NSString *> *)appearanceNames
{
    NSMutableArray *a = [NSMutableArray array];
    for (size_t i = 0; i < _store->napps; i++) {
        NSString *n = [NSString stringWithUTF8String:_store->apps[i].name];
        if (n)
            [a addObject:n];
    }
    return a;
}

- (const cui_facet *)_facet:(NSString *)name
{
    const char *n = name.UTF8String;
    return n ? cui_store_facet(_store, n) : NULL;
}

- (BOOL)containsLookupForName:(NSString *)name { return [self _facet:name] != NULL; }

- (uint16_t)_appearanceID:(NSString *)name
{
    uint16_t id = 0;
    return name && cui_store_appearance(_store, name.UTF8String, &id) ? id : 0;
}

static Class
lookup_class(const cui_csi *c)
{
    if (c->layout == CUI_LAYOUT_COLOR)
        return [CUINamedColor class];
    if (c->layout == CUI_LAYOUT_DATA)
        return [CUINamedData class];
    if (is_bitmap_layout(c->layout) || c->layout == CUI_LAYOUT_VECTOR)
        return [CUINamedImage class];
    return [CUINamedLookup class];
}

- (id)_lookup:(NSString *)name query:(query)q kind:(want_kind)kind
{
    const cui_facet *f = [self _facet:name];
    if (!f)
        return nil;
    cui_csi c;
    const cui_rendition *r = best_rendition(_store, f, &q, kind, &c);
    if (!r)
        return nil;
    Class cls = kind == WANT_VECTOR ? [CUINamedVectorImage class] : lookup_class(&c);
    return [[[cls alloc] _initWithName:name catalog:self rendition:r csi:&c] autorelease];
}

static query
make_query(double scale, long idiom, long gamut, long direction, uint16_t appearance)
{
    query q = {.scale = scale > 0 ? scale : 1, .idiom = idiom, .gamut = gamut, .direction = direction, .appearance = appearance, .part = -1};
    return q;
}

- (NSArray *)imagesWithName:(NSString *)name
{
    const cui_facet *f = [self _facet:name];
    if (!f)
        return @[];
    NSMutableArray *a = [NSMutableArray array];
    size_t first, n = cui_store_renditions_for_identifier(_store, f->attrs.v[CUI_ATTR_IDENTIFIER], &first);
    for (size_t i = first; i < first + n; i++) {
        const cui_rendition *r = &_store->rends[i];
        BOOL ok = YES;  /* every part under the name's identifier: icon sizes, vectors, ... */
        for (int at = 0; at < CUI_ATTR_MAX && ok; at++)
            if (((f->mask >> at) & 1) && at != CUI_ATTR_PART)
                ok = r->key.v[at] == f->attrs.v[at];
        cui_csi c;
        if (!ok || !cui_csi_parse(r->csi, r->len, &c))
            continue;
        Class cls = lookup_class(&c);  /* bitmaps and data, as Apple's */
        if ((cls != [CUINamedImage class] && cls != [CUINamedData class]) || c.layout == CUI_LAYOUT_VECTOR)
            continue;
        CUINamedLookup *l = [[cls alloc] _initWithName:name catalog:self rendition:r csi:&c];
        [a addObject:l];
        [l release];
    }
    return a;
}

- (void)enumerateNamedLookupsUsingBlock:(void (^)(CUINamedLookup *))block
{
    for (NSString *n in [self allImageNames])
        for (CUINamedLookup *l in [self imagesWithName:n])
            block(l);
}

/* Any image or data rendition under the name, as Apple's answers. */
- (BOOL)imageExistsWithName:(NSString *)name { return [self imagesWithName:name].count > 0; }

- (BOOL)imageExistsWithName:(NSString *)name scaleFactor:(CGFloat)scale
{
    for (CUINamedLookup *l in [self imagesWithName:name])
        if (![l isKindOfClass:[CUINamedImage class]] || l.scale == scale)
            return YES;
    return NO;
}

- (CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut
                 layoutDirection:(NSInteger)direction appearanceName:(NSString *)appearance locale:(NSLocale *)locale
{
    return [self _lookup:name query:make_query(scale, 0, gamut, direction, [self _appearanceID:appearance]) kind:WANT_IMAGE];
}

- (CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut
                 layoutDirection:(NSInteger)direction appearanceName:(NSString *)appearance
{
    return [self imageWithName:name scaleFactor:scale displayGamut:gamut layoutDirection:direction appearanceName:appearance locale:nil];
}

- (CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut layoutDirection:(NSInteger)direction
{
    return [self imageWithName:name scaleFactor:scale displayGamut:gamut layoutDirection:direction appearanceName:nil];
}

- (CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale
{
    return [self imageWithName:name scaleFactor:scale displayGamut:0 layoutDirection:0 appearanceName:nil];
}

- (CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale appearanceName:(NSString *)appearance
{
    return [self imageWithName:name scaleFactor:scale displayGamut:0 layoutDirection:0 appearanceName:appearance];
}

- (CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale deviceIdiom:(NSInteger)idiom appearanceName:(NSString *)appearance
{
    return [self _lookup:name query:make_query(scale, idiom, 0, 0, [self _appearanceID:appearance]) kind:WANT_IMAGE];
}

- (CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale deviceIdiom:(NSInteger)idiom
{
    return [self imageWithName:name scaleFactor:scale deviceIdiom:idiom appearanceName:nil];
}

- (CUINamedColor *)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut deviceIdiom:(NSInteger)idiom appearanceName:(NSString *)appearance
{
    return [self _lookup:name query:make_query(1, idiom, gamut, 0, [self _appearanceID:appearance]) kind:WANT_COLOR];
}

- (CUINamedColor *)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut deviceIdiom:(NSInteger)idiom
{
    return [self colorWithName:name displayGamut:gamut deviceIdiom:idiom appearanceName:nil];
}

- (CUINamedColor *)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut appearanceName:(NSString *)appearance
{
    return [self colorWithName:name displayGamut:gamut deviceIdiom:0 appearanceName:appearance];
}

- (CUINamedColor *)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut
{
    return [self colorWithName:name displayGamut:gamut deviceIdiom:0 appearanceName:nil];
}

/* Apple's: the appearance, then its fallbacks, down to the default. */
- (CUINamedColor *)_appearancefallback_colorWithName:(NSString *)name displayGamut:(NSInteger)gamut deviceIdiom:(NSInteger)idiom
                                      appearanceName:(NSString *)appearance
{
    CUINamedColor *c = [self colorWithName:name displayGamut:gamut deviceIdiom:idiom appearanceName:appearance];
    if (!c && [appearance hasPrefix:@"NSAppearanceNameAccessibility"]) {
        NSString *base = [@"NSAppearanceName" stringByAppendingString:[appearance substringFromIndex:29]];
        c = [self colorWithName:name displayGamut:gamut deviceIdiom:idiom appearanceName:base];
    }
    if (!c && [appearance rangeOfString:@"Dark"].location != NSNotFound)
        c = [self colorWithName:name displayGamut:gamut deviceIdiom:idiom appearanceName:@"NSAppearanceNameDarkAqua"];
    if (!c)
        c = [self colorWithName:name displayGamut:gamut deviceIdiom:idiom appearanceName:@"NSAppearanceNameSystem"];
    return c;
}

- (CUINamedData *)dataWithName:(NSString *)name appearanceName:(NSString *)appearance
{
    return [self _lookup:name query:make_query(1, 0, 0, 0, [self _appearanceID:appearance]) kind:WANT_DATA];
}

- (CUINamedData *)dataWithName:(NSString *)name { return [self dataWithName:name appearanceName:nil]; }

- (CUINamedVectorImage *)namedVectorImageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut
                                  layoutDirection:(NSInteger)direction appearanceName:(NSString *)appearance locale:(NSLocale *)locale
{
    const cui_facet *f = [self _facet:name];
    if (!f)
        return nil;
    query q = make_query(scale, 0, gamut, direction, [self _appearanceID:appearance]);
    q.part = 42;  /* the vector beside an image's bitmaps, under its own part */
    cui_csi c;
    const cui_rendition *r = best_rendition(_store, f, &q, WANT_VECTOR, &c);
    return r ? [[[CUINamedVectorPDFImage alloc] _initWithName:name catalog:self rendition:r csi:&c] autorelease] : nil;
}

- (CUINamedVectorImage *)namedVectorImageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut
                                  layoutDirection:(NSInteger)direction appearanceName:(NSString *)appearance
{
    return [self namedVectorImageWithName:name scaleFactor:scale displayGamut:gamut layoutDirection:direction appearanceName:appearance locale:nil];
}

/* A PDF rendition under the name's own part (older catalogs keep them there; newer ones under part 42, which
 * namedVectorImageWithName: finds). */
- (CGPDFDocumentRef)pdfDocumentWithName:(NSString *)name appearanceName:(NSString *)appearance
{
    const cui_facet *f = [self _facet:name];
    query q = make_query(1, 0, 0, 0, [self _appearanceID:appearance]);
    cui_csi c;
    const cui_rendition *r = f ? best_rendition(_store, f, &q, WANT_VECTOR, &c) : NULL;
    CGPDFDocumentRef doc = r ? [[[[CUINamedVectorPDFImage alloc] _initWithName:name catalog:self rendition:r csi:&c] autorelease] pdfDocument] : NULL;
    return doc ? (CGPDFDocumentRef)[[(id)doc retain] autorelease] : NULL;
}

- (CGPDFDocumentRef)pdfDocumentWithName:(NSString *)name { return [self pdfDocumentWithName:name appearanceName:nil]; }

/* An atlas's decoded image, kept for the catalog's life. */
- (CGImageRef)_atlasImageForKey:(const cui_key *)key
{
    const cui_rendition *r = cui_store_rendition_with_key(_store, key);
    if (!r)
        return NULL;
    NSValue *k = [NSValue valueWithPointer:r];
    [_lock lock];
    id im = [_atlases objectForKey:k];
    [_lock unlock];
    if (im)
        return (CGImageRef)im;
    cui_csi c;
    if (!cui_csi_parse(r->csi, r->len, &c))
        return NULL;
    CGImageRef cg = FinchCUICreateImageFromCSI(&c);
    if (!cg)
        return NULL;
    [_lock lock];
    if (![_atlases objectForKey:k])
        [_atlases setObject:(id)cg forKey:k];
    im = [_atlases objectForKey:k];
    [_lock unlock];
    CGImageRelease(cg);
    return (CGImageRef)im;
}

@end

/* MARK: - Images from renditions */

static void
release_pixels(void *info, const void *data, size_t size)
{
    free((void *)data);
}

/* A CGImage of a bitmap rendition, as Apple's CoreUI makes it: RGBA (or gray and alpha), premultiplied,
 * the alpha skipped when the rendition says it's opaque. */
CGImageRef
FinchCUICreateImageFromCSI(const cui_csi *c)
{
    if (c->pixel_format == CUI_FOURCC('J', 'P', 'E', 'G') || c->pixel_format == CUI_FOURCC('H', 'E', 'I', 'F')) {
        size_t len;
        uint8_t *raw = cui_csi_raw_data(c, &len);
        if (!raw)
            return NULL;
        CFDataRef d = CFDataCreateWithBytesNoCopy(NULL, raw, (CFIndex)len, kCFAllocatorMalloc);
        CGImageSourceRef src = CGImageSourceCreateWithData(d, NULL);
        CGImageRef im = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        if (src)
            CFRelease(src);
        CFRelease(d);
        return im;
    }
    cui_bitmap b;
    if (!cui_csi_decode_bitmap(c, &b))
        return NULL;
    CGColorSpaceRef cs;
    CGBitmapInfo info;
    size_t bpc, bpp;
    if (b.format == CUI_FOURCC('A', 'R', 'G', 'B') && b.native) {
        cs = space_for_id(c->colorspace ?: 1);
        info = kCGBitmapByteOrder32Little | (b.opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst);
        bpc = 8, bpp = 32;
    } else if (b.format == CUI_FOURCC('A', 'R', 'G', 'B')) {
        for (size_t y = 0; y < b.height; y++)
            for (uint8_t *p = b.pixels + y * b.rowbytes, *e = p + 4 * b.width; p < e; p += 4) {
                uint8_t t = p[0];
                p[0] = p[2], p[2] = t;
            }
        cs = space_for_id(c->colorspace ?: 1);
        info = (CGBitmapInfo)(b.opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast);
        bpc = 8, bpp = 32;
    } else if (b.format == CUI_FOURCC('G', 'A', '8', ' ')) {
        cs = space_for_id(c->colorspace ?: 2);
        info = (CGBitmapInfo)(b.opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast);
        bpc = 8, bpp = 16;
    } else if (b.format == CUI_FOURCC('G', 'A', '1', '6')) {
        cs = space_for_id(c->colorspace ?: 6);
        info = kCGBitmapFloatComponents | kCGBitmapByteOrder16Little |
               (b.opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast);
        bpc = 16, bpp = 32;
    } else if (b.format == CUI_FOURCC('R', 'G', 'B', 'W')) {
        cs = space_for_id(c->colorspace ?: 4);
        info = kCGBitmapFloatComponents | kCGBitmapByteOrder16Little |
               (b.opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast);
        bpc = 16, bpp = 64;
    } else {
        free(b.pixels);
        return NULL;
    }
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, b.pixels, b.rowbytes * b.height, release_pixels);
    CGImageRef im = CGImageCreate(b.width, b.height, bpc, bpp, b.rowbytes, cs, info, dp, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return im;
}

static CGPDFDocumentRef
create_pdf(const cui_csi *c)
{
    if (c->pixel_format != CUI_FOURCC('P', 'D', 'F', ' '))
        return NULL;
    size_t len;
    uint8_t *raw = cui_csi_raw_data(c, &len);
    if (!raw)
        return NULL;
    CFDataRef d = CFDataCreateWithBytesNoCopy(NULL, raw, (CFIndex)len, kCFAllocatorMalloc);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData(d);
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithProvider(dp);
    CGDataProviderRelease(dp);
    CFRelease(d);
    return doc;
}

/* A PDF's first page drawn at a scale into an RGBA image, as CoreUI rasterizes vectors. */
static CGImageRef
rasterize_pdf(CGPDFDocumentRef doc, CGFloat scale, CGSize target)
{
    CGPDFPageRef page = doc ? CGPDFDocumentGetPage(doc, 1) : NULL;
    if (!page)
        return NULL;
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    CGSize size = target.width > 0 && target.height > 0 ? target : box.size;
    size_t w = (size_t)ceil(size.width * scale), h = (size_t)ceil(size.height * scale);
    if (!w || !h)
        return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 4 * w, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx)
        return NULL;
    CGContextScaleCTM(ctx, (CGFloat)w / box.size.width, (CGFloat)h / box.size.height);
    CGContextTranslateCTM(ctx, -box.origin.x, -box.origin.y);
    CGContextDrawPDFPage(ctx, page);
    CGImageRef im = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return im;
}

/* MARK: - Named lookups */

@implementation CUINamedLookup {
    NSString *_name;
}

- (instancetype)_initWithName:(NSString *)name catalog:(CUICatalog *)catalog rendition:(const cui_rendition *)r csi:(const cui_csi *)csi
{
    if ((self = [super init])) {
        _name = [name copy];
        _catalog = [catalog retain];
        _rendition = r;
        _csi = *csi;
    }
    return self;
}

- (void)dealloc
{
    [_name release];
    [_catalog release];
    [super dealloc];
}

- (NSString *)name { return _name; }

- (void)setName:(NSString *)name
{
    name = [name copy];
    [_name release];
    _name = name;
}

- (uint16_t)_attr:(int)a { return _rendition->key.v[a]; }
- (NSString *)renditionName { return [NSString stringWithUTF8String:_csi.name] ?: @""; }

- (NSString *)appearance
{
    const char *n = cui_store_appearance_name(_catalog->_store, [self _attr:CUI_ATTR_APPEARANCE]);
    return n ? [NSString stringWithUTF8String:n] : nil;
}

- (NSInteger)appearanceIdentifier { return [self _attr:CUI_ATTR_APPEARANCE]; }
- (CGFloat)scale { return _csi.scale100 ? _csi.scale100 / 100.0 : ([self _attr:CUI_ATTR_SCALE] ?: 1); }
- (NSInteger)idiom { return [self _attr:CUI_ATTR_IDIOM]; }
- (NSUInteger)subtype { return [self _attr:CUI_ATTR_SUBTYPE]; }
- (NSInteger)displayGamut { return [self _attr:CUI_ATTR_GAMUT]; }
- (NSInteger)layoutDirection { return [self _attr:CUI_ATTR_DIRECTION]; }
- (NSInteger)localization { return [self _attr:CUI_ATTR_LOCALIZATION]; }
- (NSInteger)sizeClassHorizontal { return [self _attr:CUI_ATTR_SIZE_CLASS_H]; }
- (NSInteger)sizeClassVertical { return [self _attr:CUI_ATTR_SIZE_CLASS_V]; }
- (NSInteger)memoryClass { return [self _attr:CUI_ATTR_MEMORY_CLASS]; }
- (NSInteger)graphicsClass { return [self _attr:CUI_ATTR_GRAPHICS_CLASS]; }

- (NSString *)keySignature
{
    NSMutableString *s = [NSMutableString string];
    for (uint32_t i = 0; i < _catalog->_store->nattrs; i++)
        if (_catalog->_store->attrs[i] < CUI_ATTR_MAX)
            [s appendFormat:@"%s%u", i ? "|" : "", _rendition->key.v[_catalog->_store->attrs[i]]];
    return s;
}

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[CUINamedLookup class]] && ((CUINamedLookup *)other)->_rendition == _rendition &&
           [((CUINamedLookup *)other)->_name isEqual:_name];
}

- (NSUInteger)hash { return [_name hash] ^ (NSUInteger)_rendition; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> name=%@ rendition=%s", [self class], self, _name, _csi.name];
}

@end

@implementation CUINamedImage {
    CGImageRef _image;
    BOOL _tried;
}

- (void)dealloc
{
    CGImageRelease(_image);
    [super dealloc];
}

- (CGImageRef)image
{
    @synchronized(self) {
        if (!_tried) {
            _tried = YES;
            if (_csi.layout == CUI_LAYOUT_INTERNAL_LINK) {
                cui_key key;
                uint32_t frame[4];
                if (cui_csi_link(&_csi, &key, frame, NULL)) {
                    CGImageRef atlas = [_catalog _atlasImageForKey:&key];
                    if (atlas)
                        /* the frame's origin is the atlas's bottom left */
                        _image = CGImageCreateWithImageInRect(
                            atlas, CGRectMake(frame[0], (CGFloat)CGImageGetHeight(atlas) - frame[1] - frame[3], frame[2], frame[3]));
                }
            } else if (_csi.layout == CUI_LAYOUT_VECTOR) {
                CGPDFDocumentRef doc = create_pdf(&_csi);
                _image = rasterize_pdf(doc, [self scale], CGSizeZero);
                CGPDFDocumentRelease(doc);
            } else
                _image = FinchCUICreateImageFromCSI(&_csi);
        }
    }
    return _image;
}

- (CGImageRef)croppedImage { return [self image]; }

- (CGImageRef)createImageFromPDFRenditionWithScale:(CGFloat)scale
{
    CGPDFDocumentRef doc = create_pdf(&_csi);
    CGImageRef im = rasterize_pdf(doc, scale, CGSizeZero);
    CGPDFDocumentRelease(doc);
    return im;
}

- (CGSize)size
{
    CGFloat s = [self scale];
    if (_csi.layout == CUI_LAYOUT_VECTOR && (!_csi.width || !_csi.height)) {
        CGPDFDocumentRef doc = create_pdf(&_csi);
        CGPDFPageRef page = doc ? CGPDFDocumentGetPage(doc, 1) : NULL;
        CGSize sz = page ? CGPDFPageGetBoxRect(page, kCGPDFMediaBox).size : CGSizeZero;
        CGPDFDocumentRelease(doc);
        return sz;
    }
    if (!_csi.width || !_csi.height) {  /* JPEG and HEIF renditions: the image's */
        CGImageRef im = [self image];
        return im ? CGSizeMake(CGImageGetWidth(im) / s, CGImageGetHeight(im) / s) : CGSizeZero;
    }
    return CGSizeMake(_csi.width / s, _csi.height / s);
}

- (CGSize)originalUncroppedSize { return [self size]; }
- (NSInteger)templateRenderingMode { return cui_csi_template_mode(&_csi); }
- (BOOL)isTemplate { return cui_csi_template_mode(&_csi) == 1; }
- (BOOL)isVectorBased { return cui_csi_is_vector(&_csi); }
- (BOOL)preservedVectorRepresentation { return cui_csi_is_vector(&_csi); }
/* Apple's image types from the layouts: one part, three part horizontal, three part vertical, nine part */
- (NSInteger)imageType
{
    unsigned l = cui_csi_image_layout(&_csi);
    return l >= 20 && l <= 22 ? 1 : l >= 23 && l <= 25 ? 2 : l >= 30 && l <= 39 ? 3 : 0;
}
- (NSInteger)resizingMode { return 0; }
- (BOOL)isFlippable { return [self _attr:CUI_ATTR_DIRECTION] != 0; }
- (BOOL)hasSliceInformation { return NO; }
- (BOOL)hasAlignmentInformation { return NO; }
- (BOOL)isAlphaCropped { return NO; }
- (BOOL)isStructured { return NO; }

- (double)opacity
{
    uint32_t l;
    const uint8_t *p = cui_csi_tlv(&_csi, CUI_TLV_BLEND, &l);
    float f = 1;
    if (p && l >= 8)
        memcpy(&f, p + 4, 4);
    return f;
}

- (int)blendMode
{
    uint32_t l;
    const uint8_t *p = cui_csi_tlv(&_csi, CUI_TLV_BLEND, &l);
    return p && l >= 4 ? (int)(p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24) : 0;
}

- (int)exifOrientation
{
    uint32_t l;
    const uint8_t *p = cui_csi_tlv(&_csi, CUI_TLV_EXIF, &l);
    return p && l >= 4 ? (int)(p[0] | p[1] << 8) : 1;
}

@end

@implementation CUINamedColor {
    CGColorRef _color;
    NSString *_system;
    BOOL _tried;
}

- (void)dealloc
{
    CGColorRelease(_color);
    [_system release];
    [super dealloc];
}

- (void)_load
{
    @synchronized(self) {
        if (_tried)
            return;
        _tried = YES;
        unsigned space, n;
        double comps[8];
        char sys[128];
        if (!cui_csi_color(&_csi, &space, comps, &n, sys, sizeof sys))
            return;
        CGColorSpaceRef cs = space_for_id(space);
        if (CGColorSpaceGetNumberOfComponents(cs) + 1 == n) {
            CGFloat c[8];
            for (unsigned i = 0; i < n; i++)
                c[i] = comps[i];
            _color = CGColorCreate(cs, c);
        }
        CGColorSpaceRelease(cs);
        if (sys[0])
            _system = [[NSString alloc] initWithUTF8String:sys];
    }
}

- (CGColorRef)cgColor
{
    [self _load];
    return _color;
}

- (NSString *)systemColorName
{
    [self _load];
    return _system;
}

- (BOOL)substituteWithSystemColor { return [self systemColorName] != nil; }

@end

@implementation CUINamedData

- (NSData *)data
{
    size_t len;
    uint8_t *raw = cui_csi_raw_data(&_csi, &len);
    return raw ? [NSData dataWithBytesNoCopy:raw length:len freeWhenDone:YES] : nil;
}

- (NSString *)utiType
{
    uint32_t l;
    const uint8_t *p = cui_csi_tlv(&_csi, CUI_TLV_UTI, &l);
    if (!p || l < 8)
        return nil;
    uint32_t n = p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
    if (n > l - 8)
        n = l - 8;
    return [[[NSString alloc] initWithBytes:p + 8 length:strnlen((const char *)p + 8, n) encoding:NSUTF8StringEncoding] autorelease];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> name=%@ type=%@", [self class], self, self.name, self.utiType];
}

@end

@implementation CUINamedVectorPDFImage
@end

@implementation CUINamedVectorImage {
    CGPDFDocumentRef _doc;
    NSMutableDictionary *_rasters;
}

- (void)dealloc
{
    CGPDFDocumentRelease(_doc);
    [_rasters release];
    [super dealloc];
}

- (CGPDFDocumentRef)pdfDocument
{
    @synchronized(self) {
        if (!_doc)
            _doc = create_pdf(&_csi);
    }
    return _doc;
}

- (CGImageRef)rasterizeImageUsingScaleFactor:(CGFloat)scale forTargetSize:(CGSize)size
{
    CGImageRef im = rasterize_pdf([self pdfDocument], scale, size);
    if (!im)
        return NULL;
    @synchronized(self) {
        if (!_rasters)
            _rasters = [[NSMutableDictionary alloc] init];
        [_rasters setObject:(id)im forKey:[NSString stringWithFormat:@"%g %g %g", scale, size.width, size.height]];
    }
    CGImageRelease(im);
    return im;
}

@end
