/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSColor, as Apple's: component colours in an NSColorSpace
 * (NSColorSpaceColor) or in one of the legacy named spaces (NSDeviceRGBColor,
 * NSCalibratedRGBColor, NSDeviceWhiteColor, NSCalibratedWhiteColor,
 * NSDeviceCMYKColor), catalog colours (the System catalog's dynamic colours),
 * and pattern colours.
 *
 * Apple's AppKit stores colours whose components fit in a few bits as tagged
 * pointers. They behave like the others but print without "hdrm(1)" and name
 * different methods when an accessor doesn't apply; Finch's colours carry a
 * flag for that rather than being tagged pointers.
 *
 * System colours are dynamic on macOS; Finch's resolve to the light
 * appearance's values, measured from Apple's in sRGB.
 */
#import "AppKitDrawing.h"
#include <math.h>

NSNotificationName NSSystemColorsDidChangeNotification = @"NSSystemColorsDidChangeNotification";
const CGFloat NSWhite = 1, NSLightGray = 2.0 / 3, NSDarkGray = 1.0 / 3, NSBlack = 0;

static BOOL ignores_alpha;

/* MARK: - Helpers */

/* Apple's tagged colours: what fits its encodings (k/255, or a multiple of 2^-20/200 for gray values). */
static BOOL
fits(CGFloat v, double k)
{
    double x = v * k;
    return isfinite(x) && x == round(x);
}

static BOOL gray_fits(CGFloat v) { return fits(v, 255) || fits(v, 209715200.0); }
static BOOL rgb_fits(CGFloat v) { return v >= 0 && v <= 1 && fits(v, 255); }

static NSString *
format_components(const CGFloat *c, NSInteger n)
{
    NSMutableString *s = [NSMutableString string];
    for (NSInteger i = 0; i < n; i++)
        [s appendFormat:i ? @" %g" : @"%g", c[i]];
    return s;
}

static CGFloat clamp01(CGFloat v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

/* HSB to RGB, as Apple's: a hue outside [0, 1] gives black. */
static void
hsb_to_rgb(CGFloat h, CGFloat s, CGFloat v, CGFloat *r, CGFloat *g, CGFloat *b)
{
    s = clamp01(s), v = clamp01(v);
    double hh = h * 6;
    int i = (int)floor(hh);
    double f = hh - i, p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
    if (i == 6)
        i = 0;
    switch (i) {
    case 0: *r = v, *g = t, *b = p; break;
    case 1: *r = q, *g = v, *b = p; break;
    case 2: *r = p, *g = v, *b = t; break;
    case 3: *r = p, *g = q, *b = v; break;
    case 4: *r = t, *g = p, *b = v; break;
    case 5: *r = v, *g = p, *b = q; break;
    default: *r = *g = *b = 0; break;
    }
}

static void
rgb_to_hsb(CGFloat r, CGFloat g, CGFloat b, CGFloat *h, CGFloat *s, CGFloat *v)
{
    CGFloat max = fmax(r, fmax(g, b)), min = fmin(r, fmin(g, b)), d = max - min;
    CGFloat hue = 0;
    if (d > 0) {
        if (max == r)
            hue = (g - b) / d;
        else if (max == g)
            hue = 2 + (b - r) / d;
        else
            hue = 4 + (r - g) / d;
        hue /= 6;
        if (hue <= 0)
            hue += 1;  /* Apple's: pure red is hue 1 */
    }
    if (h)
        *h = hue;
    if (s)
        *s = max > 0 ? d / max : 0;
    if (v)
        *v = max;
}

/* The exception Apple's raises for an accessor the colour has no answer for. */
static void __attribute__((noreturn))
not_valid(NSColor *c, NSString *method)
{
    FinchDrawRaise(NSInvalidArgumentException, @"*** -%@ not valid for the NSColor %@; need to first convert colorspace.",
                   method, c);
}

/* MARK: - Component colours */

typedef enum { KIND_SPACE, KIND_DEVICE_RGB, KIND_CAL_RGB, KIND_DEVICE_WHITE, KIND_CAL_WHITE, KIND_DEVICE_CMYK } Kind;

@interface NSComponentColor : NSColor {
@public
    Kind _kind;
    NSColorSpace *_space;  /* KIND_SPACE */
    CGFloat _c[6];         /* components, then alpha */
    NSInteger _n;          /* components with alpha */
    BOOL _tagged;
    CGColorRef _cg;
}
@end
@interface NSColorSpaceColor : NSComponentColor
@end
@interface NSDeviceRGBColor : NSComponentColor
@end
@interface NSCalibratedRGBColor : NSComponentColor
@end
@interface NSDeviceWhiteColor : NSComponentColor
@end
@interface NSCalibratedWhiteColor : NSComponentColor
@end
@interface NSDeviceCMYKColor : NSComponentColor
@end

@interface NSDynamicSystemColor : NSColor {
@public
    NSString *_catalog, *_name;
    NSColor *(^_provider)(NSAppearance *);
    CGFloat _r, _g, _b, _a;  /* the light appearance's value, sRGB */
}
- (NSColor *)_resolved;
@end

@interface NSPatternColor : NSColor {
@public
    NSImage *_image;
    CGColorRef _cg;
}
@end

static Class
class_for_kind(Kind k)
{
    switch (k) {
    case KIND_SPACE: return [NSColorSpaceColor class];
    case KIND_DEVICE_RGB: return [NSDeviceRGBColor class];
    case KIND_CAL_RGB: return [NSCalibratedRGBColor class];
    case KIND_DEVICE_WHITE: return [NSDeviceWhiteColor class];
    case KIND_CAL_WHITE: return [NSCalibratedWhiteColor class];
    case KIND_DEVICE_CMYK: return [NSDeviceCMYKColor class];
    }
    return Nil;
}

static NSColorSpaceModel
kind_model(Kind k)
{
    switch (k) {
    case KIND_DEVICE_RGB:
    case KIND_CAL_RGB: return NSColorSpaceModelRGB;
    case KIND_DEVICE_WHITE:
    case KIND_CAL_WHITE: return NSColorSpaceModelGray;
    case KIND_DEVICE_CMYK: return NSColorSpaceModelCMYK;
    default: return NSColorSpaceModelUnknown;
    }
}

static NSColorSpace *
kind_space(Kind k)
{
    switch (k) {
    case KIND_DEVICE_RGB: return [NSColorSpace deviceRGBColorSpace];
    case KIND_CAL_RGB: return [NSColorSpace genericRGBColorSpace];
    case KIND_DEVICE_WHITE: return [NSColorSpace deviceGrayColorSpace];
    case KIND_CAL_WHITE: return [NSColorSpace genericGrayColorSpace];
    case KIND_DEVICE_CMYK: return [NSColorSpace deviceCMYKColorSpace];
    default: return nil;
    }
}

static NSColorSpaceName
kind_name(Kind k)
{
    switch (k) {
    case KIND_DEVICE_RGB: return NSDeviceRGBColorSpace;
    case KIND_CAL_RGB: return NSCalibratedRGBColorSpace;
    case KIND_DEVICE_WHITE: return NSDeviceWhiteColorSpace;
    case KIND_CAL_WHITE: return NSCalibratedWhiteColorSpace;
    case KIND_DEVICE_CMYK: return NSDeviceCMYKColorSpace;
    default: return NSCustomColorSpace;
    }
}

/* The CG space a legacy colour's CGColor is in: Apple's tagged device colours use the device spaces, the
 * others sRGB and gray gamma 2.2. */
static CGColorSpaceRef
kind_cg_space(Kind k, BOOL tagged)
{
    switch (k) {
    case KIND_DEVICE_RGB: return tagged ? [NSColorSpace deviceRGBColorSpace].CGColorSpace : [NSColorSpace sRGBColorSpace].CGColorSpace;
    case KIND_DEVICE_WHITE:
        return tagged ? [NSColorSpace deviceGrayColorSpace].CGColorSpace : [NSColorSpace genericGamma22GrayColorSpace].CGColorSpace;
    default: return kind_space(k).CGColorSpace;
    }
}

static BOOL
compute_tagged(Kind kind, NSColorSpace *space, const CGFloat *c, NSInteger n)
{
    NSColorSpaceModel m = kind == KIND_SPACE ? space.colorSpaceModel : kind_model(kind);
    if (m == NSColorSpaceModelGray)
        return gray_fits(c[0]) && gray_fits(c[1]);
    if (m != NSColorSpaceModelRGB)
        return NO;
    if (c[0] == c[1] && c[1] == c[2])
        return gray_fits(c[0]) && ((c[0] == 0 || c[0] == 1) ? gray_fits(c[3]) : rgb_fits(c[3]));
    return rgb_fits(c[0]) && rgb_fits(c[1]) && rgb_fits(c[2]) && rgb_fits(c[3]);
}

static NSColor *
make_color(Kind kind, NSColorSpace *space, const CGFloat *c, NSInteger n)
{
    NSComponentColor *col = [[class_for_kind(kind) alloc] init];
    col->_kind = kind;
    col->_space = [space retain];
    col->_n = n > 6 ? 6 : n;
    memcpy(col->_c, c, sizeof(CGFloat) * (size_t)col->_n);
    col->_tagged = compute_tagged(kind, space, col->_c, col->_n);
    return [col autorelease];
}

static NSColor *
space_color(NSColorSpace *space, const CGFloat *c, NSInteger n)
{
    return make_color(KIND_SPACE, space, c, n);
}

/* Converted components come back at ColorSync's float precision, as Apple's do. */
/* Spaces that differ only in range convert by copying (sRGB and extended sRGB, gray 2.2 and extended gray). */
static BOOL
same_encoding(NSColorSpace *a, NSColorSpace *b)
{
    if (!a || !b)
        return NO;
    if ([a isEqual:b])
        return YES;
    NSColorSpace *srgb = [NSColorSpace sRGBColorSpace], *esrgb = [NSColorSpace extendedSRGBColorSpace];
    NSColorSpace *g22 = [NSColorSpace genericGamma22GrayColorSpace], *eg22 = [NSColorSpace extendedGenericGamma22GrayColorSpace];
    NSColorSpace *drgb = [NSColorSpace deviceRGBColorSpace], *dgray = [NSColorSpace deviceGrayColorSpace];
    /* (Apple's device spaces are sRGB and gray 2.2) */
    BOOL ra = [a isEqual:srgb] || [a isEqual:esrgb] || [a isEqual:drgb], rb = [b isEqual:srgb] || [b isEqual:esrgb] || [b isEqual:drgb];
    BOOL ga = [a isEqual:g22] || [a isEqual:eg22] || [a isEqual:dgray], gb = [b isEqual:g22] || [b isEqual:eg22] || [b isEqual:dgray];
    return (ra && rb) || (ga && gb);
}

static NSColor *
convert_to_space(NSColor *color, NSColorSpace *space, Kind kind)
{
    if ([color isKindOfClass:[NSComponentColor class]]) {
        NSComponentColor *cc = (NSComponentColor *)color;
        NSColorSpace *from = cc->_kind == KIND_SPACE ? cc->_space : kind_space(cc->_kind);
        if (same_encoding(from, space))
            return make_color(kind, kind == KIND_SPACE ? space : nil, cc->_c, cc->_n);
    }
    CGColorRef cg = [color _finchCGColor];
    if (!cg || !space.CGColorSpace)
        return nil;
    CGColorRef out = CGColorCreateCopyByMatchingToColorSpace(space.CGColorSpace, kCGRenderingIntentDefault, cg, NULL);
    if (!out)
        return nil;
    size_t n = CGColorGetNumberOfComponents(out);
    const CGFloat *oc = CGColorGetComponents(out);
    CGFloat c[6];
    for (size_t i = 0; i < n && i < 6; i++)
        c[i] = i + 1 == n ? oc[i] : (CGFloat)(float)oc[i];
    CGColorRelease(out);
    return make_color(kind, kind == KIND_SPACE ? space : nil, c, (NSInteger)n);
}

@implementation NSComponentColor

- (void)dealloc
{
    [_space release];
    CGColorRelease(_cg);
    [super dealloc];
}

- (NSColorType)type { return NSColorTypeComponentBased; }
- (NSColorSpaceName)colorSpaceName { return kind_name(_kind); }
- (NSColorSpace *)colorSpace { return _kind == KIND_SPACE ? _space : kind_space(_kind); }
- (NSColorSpaceModel)_model { return _kind == KIND_SPACE ? _space.colorSpaceModel : kind_model(_kind); }
- (NSInteger)numberOfComponents { return _n; }
- (CGFloat)alphaComponent { return _c[_n - 1]; }

- (void)getComponents:(CGFloat *)components
{
    memcpy(components, _c, sizeof(CGFloat) * (size_t)_n);
}

/* Which method Apple's names when an accessor doesn't apply. */
- (void)_invalid:(NSString *)accessor getter:(NSString *)getter cmyk:(BOOL)cmyk
{
    BOOL legacy = _kind != KIND_SPACE && !_tagged;
    if (legacy || (cmyk && _tagged))
        not_valid(self, accessor);
    not_valid(self, getter);
}

#define RGB_GETTER @"getRed:green:blue:alpha:"
#define HSB_GETTER @"getHue:saturation:brightness:alpha:"
#define WHITE_GETTER @"getWhite:alpha:"
#define CMYK_GETTER @"getCyan:magenta:yellow:black:alpha:"

- (CGFloat)_rgb:(int)i accessor:(NSString *)name
{
    if ([self _model] != NSColorSpaceModelRGB)
        [self _invalid:name getter:RGB_GETTER cmyk:NO];
    return _c[i];
}

- (CGFloat)redComponent { return [self _rgb:0 accessor:@"redComponent"]; }
- (CGFloat)greenComponent { return [self _rgb:1 accessor:@"greenComponent"]; }
- (CGFloat)blueComponent { return [self _rgb:2 accessor:@"blueComponent"]; }

- (void)getRed:(CGFloat *)red green:(CGFloat *)green blue:(CGFloat *)blue alpha:(CGFloat *)alpha
{
    if ([self _model] != NSColorSpaceModelRGB)
        not_valid(self, RGB_GETTER);
    if (red)
        *red = _c[0];
    if (green)
        *green = _c[1];
    if (blue)
        *blue = _c[2];
    if (alpha)
        *alpha = _c[3];
}

- (void)_hsb:(CGFloat *)hsb accessor:(NSString *)name
{
    if ([self _model] != NSColorSpaceModelRGB)
        [self _invalid:name getter:HSB_GETTER cmyk:NO];
    rgb_to_hsb(_c[0], _c[1], _c[2], &hsb[0], &hsb[1], &hsb[2]);
}

- (CGFloat)hueComponent { CGFloat v[3]; [self _hsb:v accessor:@"hueComponent"]; return v[0]; }
- (CGFloat)saturationComponent { CGFloat v[3]; [self _hsb:v accessor:@"saturationComponent"]; return v[1]; }
- (CGFloat)brightnessComponent { CGFloat v[3]; [self _hsb:v accessor:@"brightnessComponent"]; return v[2]; }

- (void)getHue:(CGFloat *)hue saturation:(CGFloat *)saturation brightness:(CGFloat *)brightness alpha:(CGFloat *)alpha
{
    CGFloat v[3];
    if ([self _model] != NSColorSpaceModelRGB)
        not_valid(self, HSB_GETTER);
    [self _hsb:v accessor:@"hueComponent"];
    if (hue)
        *hue = v[0];
    if (saturation)
        *saturation = v[1];
    if (brightness)
        *brightness = v[2];
    if (alpha)
        *alpha = _c[3];
}

- (CGFloat)whiteComponent
{
    if ([self _model] != NSColorSpaceModelGray)
        [self _invalid:@"whiteComponent" getter:WHITE_GETTER cmyk:NO];
    return _c[0];
}

- (void)getWhite:(CGFloat *)white alpha:(CGFloat *)alpha
{
    if ([self _model] != NSColorSpaceModelGray)
        not_valid(self, WHITE_GETTER);
    if (white)
        *white = _c[0];
    if (alpha)
        *alpha = _c[1];
}

- (CGFloat)_cmyk:(int)i accessor:(NSString *)name
{
    if ([self _model] != NSColorSpaceModelCMYK)
        [self _invalid:name getter:CMYK_GETTER cmyk:YES];
    return _c[i];
}

- (CGFloat)cyanComponent { return [self _cmyk:0 accessor:@"cyanComponent"]; }
- (CGFloat)magentaComponent { return [self _cmyk:1 accessor:@"magentaComponent"]; }
- (CGFloat)yellowComponent { return [self _cmyk:2 accessor:@"yellowComponent"]; }
- (CGFloat)blackComponent { return [self _cmyk:3 accessor:@"blackComponent"]; }

- (void)getCyan:(CGFloat *)cyan magenta:(CGFloat *)magenta yellow:(CGFloat *)yellow black:(CGFloat *)black alpha:(CGFloat *)alpha
{
    if ([self _model] != NSColorSpaceModelCMYK)
        not_valid(self, CMYK_GETTER);
    if (cyan)
        *cyan = _c[0];
    if (magenta)
        *magenta = _c[1];
    if (yellow)
        *yellow = _c[2];
    if (black)
        *black = _c[3];
    if (alpha)
        *alpha = _c[4];
}

- (CGColorRef)_finchCGColor
{
    if (!_cg) {
        CGColorSpaceRef cs = _kind == KIND_SPACE ? _space.CGColorSpace : kind_cg_space(_kind, _tagged);
        if (cs && CGColorSpaceGetNumberOfComponents(cs) + 1 == (size_t)_n) {
            /* CG clamps what its space can't hold: alpha always, components unless the space is extended */
            CGFloat c[6];
            BOOL extended = CGColorSpaceUsesExtendedRange(cs);
            for (NSInteger i = 0; i < _n; i++)
                c[i] = (i == _n - 1 || !extended) ? fmin(1, fmax(0, _c[i])) : _c[i];
            _cg = CGColorCreate(cs, c);
        }
    }
    return _cg;
}

- (CGColorRef)CGColor { return [self _finchCGColor]; }

- (NSString *)description
{
    NSString *comps = format_components(_c, _n);
    if (_kind != KIND_SPACE)
        return [NSString stringWithFormat:@"%@ %@", kind_name(_kind), comps];
    return [NSString stringWithFormat:@"%@%@ %@", _space, _tagged ? @"" : @" hdrm(1)", comps];
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSComponentColor class]])
        return NO;
    NSComponentColor *o = other;
    if (o->_kind != _kind || o->_n != _n)
        return NO;
    if (_kind == KIND_SPACE && ![_space isEqual:o->_space])
        return NO;
    for (NSInteger i = 0; i < _n; i++)
        if ((float)_c[i] != (float)o->_c[i])  /* Apple's compares at float precision */
            return NO;
    return YES;
}

- (NSUInteger)hash
{
    NSUInteger h = (NSUInteger)_kind * 31;
    for (NSInteger i = 0; i < _n; i++)
        h = h * 131 + (NSUInteger)llround((float)_c[i] * 4096.0f);
    return h;
}

- (NSColor *)colorWithAlphaComponent:(CGFloat)alpha
{
    CGFloat c[6];
    memcpy(c, _c, sizeof c);
    c[_n - 1] = alpha;
    switch (_kind) {
    case KIND_DEVICE_RGB:
    case KIND_DEVICE_CMYK: return make_color(_kind, nil, c, _n);
    case KIND_SPACE: return space_color(_space, c, _n);
    default: return space_color(kind_space(_kind), c, _n);
    }
}

- (NSColor *)colorUsingColorSpace:(NSColorSpace *)space
{
    if (!space)
        return nil;
    if ([space isEqual:[self colorSpace]])
        return self;
    return convert_to_space(self, space, KIND_SPACE);
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
        return;
    NSColorSpaceModel m = [self _model];
    int nsSpace;
    switch (_kind) {
    case KIND_CAL_RGB: nsSpace = 1; break;
    case KIND_DEVICE_RGB: nsSpace = 2; break;
    case KIND_CAL_WHITE: nsSpace = 3; break;
    case KIND_DEVICE_WHITE: nsSpace = 4; break;
    case KIND_DEVICE_CMYK: nsSpace = 5; break;
    default: nsSpace = m == NSColorSpaceModelGray ? 3 : m == NSColorSpaceModelCMYK ? 5 : 1; break;
    }
    [coder encodeInt:nsSpace forKey:@"NSColorSpace"];
    /* the components as the legacy space understands them (with alpha only if it isn't 1) */
    NSColor *legacy = self;
    if (_kind == KIND_SPACE)
        legacy = [self colorUsingColorSpaceName:nsSpace == 3 ? NSCalibratedWhiteColorSpace
                                                : nsSpace == 5 ? NSDeviceCMYKColorSpace : NSCalibratedRGBColorSpace];
    if ([legacy isKindOfClass:[NSComponentColor class]]) {
        NSComponentColor *l = (NSComponentColor *)legacy;
        NSMutableString *s = [NSMutableString string];
        for (NSInteger i = 0; i < l->_n; i++)
            if (i < l->_n - 1 || l->_c[i] != 1)
                [s appendFormat:i ? @" %.10g" : @"%.10g", l->_c[i]];
        NSMutableData *d = [[[s dataUsingEncoding:NSASCIIStringEncoding] mutableCopy] autorelease];
        [d appendBytes:"" length:1];
        NSString *key = nsSpace == 3 || nsSpace == 4 ? @"NSWhite" : nsSpace == 5 ? @"NSCMYK" : @"NSRGB";
        [coder encodeBytes:d.bytes length:d.length forKey:key];
    }
    if (_kind == KIND_SPACE) {
        NSInteger nsid = [_space _finchArchiveID];
        [coder encodeObject:_space forKey:@"NSCustomColorSpace"];
        if (nsid != 1 && nsid != 2) {
            NSMutableString *s = [NSMutableString string];
            for (NSInteger i = 0; i < _n; i++)
                [s appendFormat:i ? @" %.10g" : @"%.10g", _c[i]];
            NSData *d = [s dataUsingEncoding:NSASCIIStringEncoding];
            [coder encodeBytes:d.bytes length:d.length forKey:@"NSComponents"];
            [coder encodeBytes:(const uint8_t *)(_tagged ? "1" : "0") length:1 forKey:@"NSLinearExposure"];
        }
    }
}

@end

@implementation NSColorSpaceColor
@end
@implementation NSDeviceRGBColor
@end
@implementation NSCalibratedRGBColor
@end
@implementation NSDeviceWhiteColor
@end
@implementation NSCalibratedWhiteColor
@end
@implementation NSDeviceCMYKColor
@end

/* MARK: - Catalog colours */

typedef struct {
    NSString *name;
    CGFloat r, g, b, a;
} CatalogEntry;

#define F(k) ((CGFloat)(float)((k) / 255.0))
static const CatalogEntry catalog[] = {
    {@"labelColor", 0, 0, 0, 216 / 255.0},
    {@"secondaryLabelColor", 0, 0, 0, 127 / 255.0},
    {@"tertiaryLabelColor", 0, 0, 0, 66 / 255.0},
    {@"quaternaryLabelColor", 0, 0, 0, 25 / 255.0},
    {@"quinaryLabelColor", 0, 0, 0, 12 / 255.0},
    {@"linkColor", 0, 104 / 255.0, 218 / 255.0, 1},
    {@"placeholderTextColor", 0, 0, 0, 127 / 255.0},
    {@"windowFrameTextColor", 0, 0, 0, 216 / 255.0},
    {@"selectedMenuItemTextColor", 1, 1, 1, 1},
    {@"alternateSelectedControlTextColor", 1, 1, 1, 1},
    {@"headerTextColor", 0, 0, 0, 216 / 255.0},
    {@"separatorColor", 0, 0, 0, 25 / 255.0},
    {@"gridColor", 230 / 255.0, 230 / 255.0, 230 / 255.0, 1},
    {@"windowBackgroundColor", 1, 1, 1, 1},
    {@"underPageBackgroundColor", 150 / 255.0, 150 / 255.0, 150 / 255.0, 229 / 255.0},
    {@"controlBackgroundColor", 1, 1, 1, 1},
    {@"selectedContentBackgroundColor", F(0), F(100), F(225), F(255)},
    {@"unemphasizedSelectedContentBackgroundColor", 220 / 255.0, 220 / 255.0, 220 / 255.0, 1},
    {@"findHighlightColor", 1, 1, 0, 1},
    {@"textColor", 0, 0, 0, 1},
    {@"textBackgroundColor", 1, 1, 1, 1},
    {@"textInsertionPointColor", 0, 122 / 255.0, 1, 1},
    {@"selectedTextColor", 0, 0, 0, 1},
    {@"selectedTextBackgroundColor", F(179), F(215), F(255), F(255)},
    {@"unemphasizedSelectedTextBackgroundColor", 220 / 255.0, 220 / 255.0, 220 / 255.0, 1},
    {@"unemphasizedSelectedTextColor", 0, 0, 0, 1},
    {@"controlColor", 1, 1, 1, 1},
    {@"controlTextColor", 0, 0, 0, 216 / 255.0},
    {@"selectedControlColor", F(179), F(215), F(255), F(255)},
    {@"selectedControlTextColor", 0, 0, 0, 216 / 255.0},
    {@"disabledControlTextColor", 0, 0, 0, 63 / 255.0},
    {@"keyboardFocusIndicatorColor", F(0), F(103), F(244), F(127)},
    {@"systemRedColor", 1, 56 / 255.0, 60 / 255.0, 1},
    {@"systemGreenColor", 52 / 255.0, 199 / 255.0, 89 / 255.0, 1},
    {@"systemBlueColor", 0, 136 / 255.0, 1, 1},
    {@"systemOrangeColor", 1, 141 / 255.0, 40 / 255.0, 1},
    {@"systemYellowColor", 1, 204 / 255.0, 0, 1},
    {@"systemBrownColor", 172 / 255.0, 127 / 255.0, 94 / 255.0, 1},
    {@"systemPinkColor", 1, 45 / 255.0, 85 / 255.0, 1},
    {@"systemPurpleColor", 203 / 255.0, 48 / 255.0, 224 / 255.0, 1},
    {@"systemGrayColor", 142 / 255.0, 142 / 255.0, 147 / 255.0, 1},
    {@"systemTealColor", 0, 195 / 255.0, 208 / 255.0, 1},
    {@"systemIndigoColor", 97 / 255.0, 85 / 255.0, 245 / 255.0, 1},
    {@"systemMintColor", 0, 200 / 255.0, 179 / 255.0, 1},
    {@"systemCyanColor", 0, 192 / 255.0, 232 / 255.0, 1},
    {@"systemFillColor", 0, 0, 0, 25 / 255.0},
    {@"secondarySystemFillColor", 0, 0, 0, 20 / 255.0},
    {@"tertiarySystemFillColor", 0, 0, 0, 12 / 255.0},
    {@"quaternarySystemFillColor", 0, 0, 0, 7 / 255.0},
    {@"quinarySystemFillColor", 0, 0, 0, 2 / 255.0},
    {@"controlAccentColor", 0, 122 / 255.0, 1, 1},
    {@"highlightColor", 1, 1, 1, 1},
    {@"shadowColor", 0, 0, 0, 1},
    {@"controlHighlightColor", 1, 1, 1, 1},
    {@"controlLightHighlightColor", 1, 1, 1, 1},
    {@"controlShadowColor", 0, 0, 0, 68 / 255.0},
    {@"controlDarkShadowColor", 0, 0, 0, 1},
    {@"scrollBarColor", 170 / 255.0, 170 / 255.0, 170 / 255.0, 1},
    {@"knobColor", 153 / 255.0, 153 / 255.0, 187 / 255.0, 1},
    {@"selectedKnobColor", 102 / 255.0, 102 / 255.0, 153 / 255.0, 1},
    {@"windowFrameColor", 170 / 255.0, 170 / 255.0, 170 / 255.0, 1},
    {@"selectedMenuItemColor", 66 / 255.0, 119 / 255.0, 244 / 255.0, 1},
    {@"headerColor", 170 / 255.0, 170 / 255.0, 170 / 255.0, 1},
    {@"secondarySelectedControlColor", 220 / 255.0, 220 / 255.0, 220 / 255.0, 1},
    {@"alternateSelectedControlColor", F(0), F(100), F(225), F(255)},
    {@"alternatingContentBackgroundColor", 244 / 255.0, 245 / 255.0, 245 / 255.0, 1},
    {@"controlAlternatingRowColor", 244 / 255.0, 245 / 255.0, 245 / 255.0, 1},
};

static NSColor *
system_color(NSString *name)
{
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });
    @synchronized(cache) {
        NSColor *c = cache[name];
        if (c)
            return c;
        for (unsigned i = 0; i < sizeof catalog / sizeof catalog[0]; i++)
            if ([catalog[i].name isEqualToString:name]) {
                NSDynamicSystemColor *d = [[NSDynamicSystemColor alloc] init];
                d->_catalog = @"System";
                d->_name = [name copy];
                d->_r = catalog[i].r, d->_g = catalog[i].g, d->_b = catalog[i].b, d->_a = catalog[i].a;
                cache[name] = d;
                [d release];
                return d;
            }
    }
    return nil;
}

@implementation NSDynamicSystemColor

- (void)dealloc
{
    [_catalog release];
    [_name release];
    [_provider release];
    [super dealloc];
}

- (NSColor *)_resolved
{
    if (_provider) {
        Class ap = NSClassFromString(@"NSAppearance");
        NSAppearance *a = [ap respondsToSelector:@selector(currentDrawingAppearance)] ? [ap currentDrawingAppearance] : nil;
        NSColor *c = _provider(a);
        return [c isKindOfClass:[NSDynamicSystemColor class]] ? [(NSDynamicSystemColor *)c _resolved] : c;
    }
    CGFloat c[4] = {_r, _g, _b, _a};
    return space_color([NSColorSpace sRGBColorSpace], c, 4);
}

- (NSColorType)type { return NSColorTypeCatalog; }
- (NSColorSpaceName)colorSpaceName { return NSNamedColorSpace; }
- (NSColorListName)catalogNameComponent { return _catalog; }
- (NSColorName)colorNameComponent { return _name; }
- (NSString *)localizedCatalogNameComponent { return [_catalog isEqualToString:@"System"] ? @"Developer" : _catalog; }
- (NSString *)localizedColorNameComponent { return _name; }
- (CGFloat)alphaComponent { return [[self _resolved] alphaComponent]; }
- (CGColorRef)_finchCGColor { return [[self _resolved] _finchCGColor]; }
- (CGColorRef)CGColor { return [self _finchCGColor]; }

- (NSString *)description
{
    if (_provider)
        return [NSString stringWithFormat:@"Catalog color: #$customDynamic %@", _name];
    return [NSString stringWithFormat:@"Catalog color: %@ %@", _catalog, _name];
}

- (NSColor *)colorUsingColorSpace:(NSColorSpace *)space { return [[self _resolved] colorUsingColorSpace:space]; }
- (NSColor *)colorWithAlphaComponent:(CGFloat)alpha { return [[self _resolved] colorWithAlphaComponent:alpha]; }

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
    if (![other isKindOfClass:[NSDynamicSystemColor class]])
        return NO;
    NSDynamicSystemColor *o = other;
    return [o->_catalog isEqual:_catalog] && [o->_name isEqual:_name] && o->_provider == _provider;
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

/* MARK: - Pattern colours */

static void
draw_pattern_cell(void *info, CGContextRef c)
{
    CGImageRef im = (CGImageRef)info;
    CGContextDrawImage(c, CGRectMake(0, 0, CGImageGetWidth(im), CGImageGetHeight(im)), im);
}

static void
release_pattern_image(void *info)
{
    CGImageRelease((CGImageRef)info);
}

@implementation NSPatternColor

- (void)dealloc
{
    [_image release];
    CGColorRelease(_cg);
    [super dealloc];
}

- (NSColorType)type { return NSColorTypePattern; }
- (NSColorSpaceName)colorSpaceName { return NSPatternColorSpace; }
- (NSImage *)patternImage { return _image; }
- (CGFloat)alphaComponent { return 1; }
- (NSString *)description { return [NSString stringWithFormat:@"Pattern color: %@", _image]; }
- (NSColor *)colorUsingColorSpace:(NSColorSpace *)space { return nil; }
- (NSColor *)colorWithAlphaComponent:(CGFloat)alpha { return self; }
- (NSColor *)colorUsingType:(NSColorType)type { return type == NSColorTypePattern ? self : nil; }

- (CGColorRef)_finchCGColor
{
    if (!_cg) {
        CGImageRef im = [_image _finchCGImage];
        if (!im)
            return NULL;
        NSSize size = [_image size];
        CGPatternCallbacks cb = {0, draw_pattern_cell, release_pattern_image};
        CGAffineTransform t = CGAffineTransformMakeScale(size.width / CGImageGetWidth(im), size.height / CGImageGetHeight(im));
        CGPatternRef p = CGPatternCreate((void *)CGImageRetain(im), CGRectMake(0, 0, CGImageGetWidth(im), CGImageGetHeight(im)), t,
                                         CGImageGetWidth(im), CGImageGetHeight(im), kCGPatternTilingConstantSpacing, true, &cb);
        CGFloat alpha = 1;
        CGColorSpaceRef ps = CGColorSpaceCreatePattern(NULL);
        _cg = CGColorCreateWithPattern(ps, p, &alpha);
        CGColorSpaceRelease(ps);
        CGPatternRelease(p);
    }
    return _cg;
}

- (CGColorRef)CGColor { return [self _finchCGColor]; }

/* Set as a pattern in the context's pattern colour space (what CG draws patterns from). */
- (void)_setPatternFill:(BOOL)fill stroke:(BOOL)stroke
{
    CGContextRef c = FinchCurrentCGContext();
    CGColorRef cg = [self _finchCGColor];
    if (!c || !cg)
        return;
    CGColorSpaceRef ps = CGColorSpaceCreatePattern(NULL);
    CGFloat alpha = 1;
    if (fill) {
        CGContextSetFillColorSpace(c, ps);
        CGContextSetFillPattern(c, CGColorGetPattern(cg), &alpha);
    }
    if (stroke) {
        CGContextSetStrokeColorSpace(c, ps);
        CGContextSetStrokePattern(c, CGColorGetPattern(cg), &alpha);
    }
    CGColorSpaceRelease(ps);
}

- (void)set { [self _setPatternFill:YES stroke:YES]; }
- (void)setFill { [self _setPatternFill:YES stroke:NO]; }
- (void)setStroke { [self _setPatternFill:NO stroke:YES]; }

- (BOOL)isEqual:(id)other
{
    return other == self || ([other isKindOfClass:[NSPatternColor class]] && [((NSPatternColor *)other)->_image isEqual:_image]);
}

- (NSUInteger)hash { return [_image hash]; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:10 forKey:@"NSColorSpace"];
    [coder encodeObject:_image forKey:@"NSImage"];
}

@end

/* MARK: - NSColor */

@implementation NSColor

- (instancetype)init { return [super init]; }

/* MARK: Constructors */

+ (NSColor *)colorWithColorSpace:(NSColorSpace *)space components:(const CGFloat *)components count:(NSInteger)numberOfComponents
{
    if (!space || numberOfComponents < 1)
        return nil;
    return space_color(space, components, numberOfComponents);
}

static NSColor *
rgb_in(NSColorSpace *space, CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    CGFloat c[4] = {r, g, b, a};
    return space_color(space, c, 4);
}

static NSColor *
gray_in(NSColorSpace *space, CGFloat w, CGFloat a)
{
    CGFloat c[2] = {w, a};
    return space_color(space, c, 2);
}

+ (NSColor *)colorWithSRGBRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha
{
    return rgb_in([NSColorSpace sRGBColorSpace], red, green, blue, alpha);
}

+ (NSColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha
{
    return rgb_in([NSColorSpace sRGBColorSpace], red, green, blue, alpha);
}

+ (NSColor *)colorWithDisplayP3Red:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha
{
    return rgb_in([NSColorSpace displayP3ColorSpace], red, green, blue, alpha);
}

+ (NSColor *)colorWithGenericGamma22White:(CGFloat)white alpha:(CGFloat)alpha
{
    BOOL extended = white < 0 || white > 1;
    return gray_in(extended ? [NSColorSpace extendedGenericGamma22GrayColorSpace] : [NSColorSpace genericGamma22GrayColorSpace],
                   white, alpha);
}

+ (NSColor *)colorWithWhite:(CGFloat)white alpha:(CGFloat)alpha
{
    return [self colorWithGenericGamma22White:white alpha:alpha];
}

+ (NSColor *)colorWithHue:(CGFloat)hue saturation:(CGFloat)saturation brightness:(CGFloat)brightness alpha:(CGFloat)alpha
{
    return [self colorWithColorSpace:[NSColorSpace sRGBColorSpace] hue:hue saturation:saturation brightness:brightness alpha:alpha];
}

+ (NSColor *)colorWithColorSpace:(NSColorSpace *)space hue:(CGFloat)hue saturation:(CGFloat)saturation brightness:(CGFloat)brightness alpha:(CGFloat)alpha
{
    if (space.colorSpaceModel != NSColorSpaceModelRGB)
        FinchDrawRaise(NSInvalidArgumentException,
                       @"*** Invalid color space argument %@ in colorWithColorSpace:hue:saturation:brightness:alpha:.", space);
    CGFloat r, g, b;
    hsb_to_rgb(hue, saturation, brightness, &r, &g, &b);
    return rgb_in(space, r, g, b, alpha);
}

static NSColor *
legacy_rgb(Kind kind, CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    CGFloat c[4] = {clamp01(r), clamp01(g), clamp01(b), clamp01(a)};
    return make_color(kind, nil, c, 4);
}

static NSColor *
legacy_white(Kind kind, CGFloat w, CGFloat a)
{
    CGFloat c[2] = {clamp01(w), clamp01(a)};
    return make_color(kind, nil, c, 2);
}

+ (NSColor *)colorWithDeviceWhite:(CGFloat)white alpha:(CGFloat)alpha { return legacy_white(KIND_DEVICE_WHITE, white, alpha); }
+ (NSColor *)colorWithCalibratedWhite:(CGFloat)white alpha:(CGFloat)alpha { return legacy_white(KIND_CAL_WHITE, white, alpha); }

+ (NSColor *)colorWithDeviceRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha
{
    return legacy_rgb(KIND_DEVICE_RGB, red, green, blue, alpha);
}

+ (NSColor *)colorWithCalibratedRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha
{
    return legacy_rgb(KIND_CAL_RGB, red, green, blue, alpha);
}

+ (NSColor *)colorWithDeviceHue:(CGFloat)hue saturation:(CGFloat)saturation brightness:(CGFloat)brightness alpha:(CGFloat)alpha
{
    CGFloat r, g, b;
    hsb_to_rgb(hue, saturation, brightness, &r, &g, &b);
    return legacy_rgb(KIND_DEVICE_RGB, r, g, b, alpha);
}

+ (NSColor *)colorWithCalibratedHue:(CGFloat)hue saturation:(CGFloat)saturation brightness:(CGFloat)brightness alpha:(CGFloat)alpha
{
    CGFloat r, g, b;
    hsb_to_rgb(hue, saturation, brightness, &r, &g, &b);
    return legacy_rgb(KIND_CAL_RGB, r, g, b, alpha);
}

+ (NSColor *)colorWithDeviceCyan:(CGFloat)cyan magenta:(CGFloat)magenta yellow:(CGFloat)yellow black:(CGFloat)black alpha:(CGFloat)alpha
{
    CGFloat c[5] = {clamp01(cyan), clamp01(magenta), clamp01(yellow), clamp01(black), clamp01(alpha)};
    return make_color(KIND_DEVICE_CMYK, nil, c, 5);
}

+ (NSColor *)colorWithCGColor:(CGColorRef)cgColor
{
    if (!cgColor)
        return nil;
    CGColorSpaceRef cs = CGColorGetColorSpace(cgColor);
    if (CGColorGetPattern(cgColor) || !cs)
        return nil;
    NSColorSpace *space = [[[NSColorSpace alloc] initWithCGColorSpace:cs] autorelease];
    if (!space)
        return nil;
    return space_color(space, CGColorGetComponents(cgColor), (NSInteger)CGColorGetNumberOfComponents(cgColor));
}

+ (NSColor *)colorWithPatternImage:(NSImage *)image
{
    if (!image)
        return nil;
    NSPatternColor *c = [[NSPatternColor alloc] init];
    c->_image = [image copy];  /* Apple's keeps a copy */
    return [c autorelease];
}

+ (NSColor *)colorWithCatalogName:(NSColorListName)listName colorName:(NSColorName)colorName
{
    if (![listName isEqualToString:@"System"])
        return nil;
    return system_color(colorName);
}

+ (NSColor *)colorNamed:(NSColorName)name bundle:(NSBundle *)bundle { return nil; }
+ (NSColor *)colorNamed:(NSColorName)name { return nil; }

+ (NSColor *)colorWithName:(NSColorName)colorName dynamicProvider:(NSColor * (^)(NSAppearance *))dynamicProvider
{
    NSDynamicSystemColor *d = [[NSDynamicSystemColor alloc] init];
    d->_catalog = @"System";
    d->_name = [colorName copy];
    d->_provider = [dynamicProvider copy];
    return [d autorelease];
}

+ (NSColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha exposure:(CGFloat)exposure
{
    CGFloat k = pow(2, exposure);
    return rgb_in([NSColorSpace extendedSRGBColorSpace], red * k, green * k, blue * k, alpha);
}

+ (NSColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha linearExposure:(CGFloat)linearExposure
{
    return rgb_in([NSColorSpace extendedSRGBColorSpace], red * linearExposure, green * linearExposure,
                  blue * linearExposure, alpha);
}

/* MARK: Standard colours */

+ (NSColor *)blackColor { return gray_in([NSColorSpace genericGamma22GrayColorSpace], 0, 1); }
+ (NSColor *)darkGrayColor { return gray_in([NSColorSpace genericGamma22GrayColorSpace], 1.0 / 3, 1); }
+ (NSColor *)lightGrayColor { return gray_in([NSColorSpace genericGamma22GrayColorSpace], 2.0 / 3, 1); }
+ (NSColor *)whiteColor { return gray_in([NSColorSpace genericGamma22GrayColorSpace], 1, 1); }
+ (NSColor *)grayColor { return gray_in([NSColorSpace genericGamma22GrayColorSpace], 0.5, 1); }
+ (NSColor *)clearColor { return gray_in([NSColorSpace genericGamma22GrayColorSpace], 0, 0); }
+ (NSColor *)redColor { return rgb_in([NSColorSpace sRGBColorSpace], 1, 0, 0, 1); }
+ (NSColor *)greenColor { return rgb_in([NSColorSpace sRGBColorSpace], 0, 1, 0, 1); }
+ (NSColor *)blueColor { return rgb_in([NSColorSpace sRGBColorSpace], 0, 0, 1, 1); }
+ (NSColor *)cyanColor { return rgb_in([NSColorSpace sRGBColorSpace], 0, 1, 1, 1); }
+ (NSColor *)yellowColor { return rgb_in([NSColorSpace sRGBColorSpace], 1, 1, 0, 1); }
+ (NSColor *)magentaColor { return rgb_in([NSColorSpace sRGBColorSpace], 1, 0, 1, 1); }
+ (NSColor *)orangeColor { return rgb_in([NSColorSpace sRGBColorSpace], 1, 0.5, 0, 1); }
+ (NSColor *)purpleColor { return rgb_in([NSColorSpace sRGBColorSpace], 0.5, 0, 0.5, 1); }
+ (NSColor *)brownColor { return rgb_in([NSColorSpace sRGBColorSpace], 0.6, 0.4, 0.2, 1); }

#define SYSTEM(sel) \
    +(NSColor *)sel { return system_color(@#sel); }
SYSTEM(labelColor)
SYSTEM(secondaryLabelColor)
SYSTEM(tertiaryLabelColor)
SYSTEM(quaternaryLabelColor)
SYSTEM(quinaryLabelColor)
SYSTEM(linkColor)
SYSTEM(placeholderTextColor)
SYSTEM(windowFrameTextColor)
SYSTEM(selectedMenuItemTextColor)
SYSTEM(alternateSelectedControlTextColor)
SYSTEM(headerTextColor)
SYSTEM(separatorColor)
SYSTEM(gridColor)
SYSTEM(windowBackgroundColor)
SYSTEM(underPageBackgroundColor)
SYSTEM(controlBackgroundColor)
SYSTEM(selectedContentBackgroundColor)
SYSTEM(unemphasizedSelectedContentBackgroundColor)
SYSTEM(findHighlightColor)
SYSTEM(textColor)
SYSTEM(textBackgroundColor)
SYSTEM(textInsertionPointColor)
SYSTEM(selectedTextColor)
SYSTEM(selectedTextBackgroundColor)
SYSTEM(unemphasizedSelectedTextBackgroundColor)
SYSTEM(unemphasizedSelectedTextColor)
SYSTEM(controlColor)
SYSTEM(controlTextColor)
SYSTEM(selectedControlColor)
SYSTEM(selectedControlTextColor)
SYSTEM(disabledControlTextColor)
SYSTEM(keyboardFocusIndicatorColor)
SYSTEM(systemRedColor)
SYSTEM(systemGreenColor)
SYSTEM(systemBlueColor)
SYSTEM(systemOrangeColor)
SYSTEM(systemYellowColor)
SYSTEM(systemBrownColor)
SYSTEM(systemPinkColor)
SYSTEM(systemPurpleColor)
SYSTEM(systemGrayColor)
SYSTEM(systemTealColor)
SYSTEM(systemIndigoColor)
SYSTEM(systemMintColor)
SYSTEM(systemCyanColor)
SYSTEM(systemFillColor)
SYSTEM(secondarySystemFillColor)
SYSTEM(tertiarySystemFillColor)
SYSTEM(quaternarySystemFillColor)
SYSTEM(quinarySystemFillColor)
SYSTEM(controlAccentColor)
SYSTEM(highlightColor)
SYSTEM(shadowColor)
SYSTEM(controlHighlightColor)
SYSTEM(controlLightHighlightColor)
SYSTEM(controlShadowColor)
SYSTEM(controlDarkShadowColor)
SYSTEM(scrollBarColor)
SYSTEM(knobColor)
SYSTEM(selectedKnobColor)
SYSTEM(windowFrameColor)
SYSTEM(selectedMenuItemColor)
SYSTEM(headerColor)
SYSTEM(secondarySelectedControlColor)
SYSTEM(alternateSelectedControlColor)

+ (NSColor *)scrubberTexturedBackgroundColor { return [self controlColor]; }

+ (NSArray<NSColor *> *)alternatingContentBackgroundColors
{
    return @[ system_color(@"controlBackgroundColor"), system_color(@"alternatingContentBackgroundColor") ];
}

+ (NSArray<NSColor *> *)controlAlternatingRowBackgroundColors
{
    return @[ system_color(@"controlBackgroundColor"), system_color(@"controlAlternatingRowColor") ];
}

+ (NSControlTint)currentControlTint { return NSBlueControlTint; }

+ (NSColor *)colorForControlTint:(NSControlTint)controlTint
{
    return controlTint == NSGraphiteControlTint ? [self colorWithCalibratedRed:0.5 green:0.55 blue:0.6 alpha:1]
                                                : [self colorWithCalibratedRed:0.2 green:0.5 blue:0.95 alpha:1];
}

+ (BOOL)ignoresAlpha { return ignores_alpha; }
+ (void)setIgnoresAlpha:(BOOL)flag { ignores_alpha = flag; }

/* MARK: Accessors (each subclass answers what applies to it) */

- (NSColorType)type { return NSColorTypeComponentBased; }
- (NSColorSpaceName)colorSpaceName { return NSCustomColorSpace; }
- (NSColorSpace *)colorSpace { not_valid(self, @"colorSpace"); }
- (NSInteger)numberOfComponents { not_valid(self, @"numberOfComponents"); }
- (void)getComponents:(CGFloat *)components { not_valid(self, @"getComponents:"); }
- (CGFloat)redComponent { not_valid(self, @"redComponent"); }
- (CGFloat)greenComponent { not_valid(self, @"greenComponent"); }
- (CGFloat)blueComponent { not_valid(self, @"blueComponent"); }
- (CGFloat)hueComponent { not_valid(self, @"hueComponent"); }
- (CGFloat)saturationComponent { not_valid(self, @"saturationComponent"); }
- (CGFloat)brightnessComponent { not_valid(self, @"brightnessComponent"); }
- (CGFloat)whiteComponent { not_valid(self, @"whiteComponent"); }
- (CGFloat)cyanComponent { not_valid(self, @"cyanComponent"); }
- (CGFloat)magentaComponent { not_valid(self, @"magentaComponent"); }
- (CGFloat)yellowComponent { not_valid(self, @"yellowComponent"); }
- (CGFloat)blackComponent { not_valid(self, @"blackComponent"); }
- (NSColorListName)catalogNameComponent { not_valid(self, @"catalogNameComponent"); }
- (NSColorName)colorNameComponent { not_valid(self, @"colorNameComponent"); }
- (NSString *)localizedCatalogNameComponent { not_valid(self, @"localizedCatalogNameComponent"); }
- (NSString *)localizedColorNameComponent { not_valid(self, @"localizedColorNameComponent"); }
- (NSImage *)patternImage { not_valid(self, @"patternImage"); }
- (CGFloat)alphaComponent { return 1; }
- (CGFloat)linearExposure { return 1; }
- (NSColor *)standardDynamicRangeColor { return self; }
- (NSColor *)colorByApplyingContentHeadroom:(CGFloat)contentHeadroom { return self; }
- (NSColor *)colorWithSystemEffect:(NSColorSystemEffect)systemEffect { return self; }

- (void)getRed:(CGFloat *)red green:(CGFloat *)green blue:(CGFloat *)blue alpha:(CGFloat *)alpha { not_valid(self, @"getRed:green:blue:alpha:"); }
- (void)getHue:(CGFloat *)hue saturation:(CGFloat *)saturation brightness:(CGFloat *)brightness alpha:(CGFloat *)alpha { not_valid(self, @"getHue:saturation:brightness:alpha:"); }
- (void)getWhite:(CGFloat *)white alpha:(CGFloat *)alpha { not_valid(self, @"getWhite:alpha:"); }
- (void)getCyan:(CGFloat *)cyan magenta:(CGFloat *)magenta yellow:(CGFloat *)yellow black:(CGFloat *)black alpha:(CGFloat *)alpha { not_valid(self, @"getCyan:magenta:yellow:black:alpha:"); }

- (CGColorRef)_finchCGColor { return NULL; }
- (CGColorRef)CGColor { return [self _finchCGColor]; }

/* MARK: Conversion */

- (NSColor *)colorUsingType:(NSColorType)type
{
    return type == NSColorTypeComponentBased ? self : nil;
}

- (NSColor *)colorUsingColorSpace:(NSColorSpace *)space { return nil; }

- (NSColor *)colorUsingColorSpaceName:(NSColorSpaceName)name device:(NSDictionary *)deviceDescription
{
    return [self colorUsingColorSpaceName:name];
}

- (NSColor *)colorUsingColorSpaceName:(NSColorSpaceName)name
{
    if (!name || [name isEqualToString:[self colorSpaceName]])
        return self;
    if ([name isEqualToString:NSNamedColorSpace] || [name isEqualToString:NSPatternColorSpace])
        return nil;
    NSColor *c = [self isKindOfClass:[NSDynamicSystemColor class]] ? [(NSDynamicSystemColor *)self _resolved] : self;
    if (![c isKindOfClass:[NSComponentColor class]])
        return nil;
    if ([name isEqualToString:NSCustomColorSpace])
        return c;
    Kind kind;
    NSColorSpace *target;
    if ([name isEqualToString:NSDeviceRGBColorSpace])
        kind = KIND_DEVICE_RGB, target = [NSColorSpace sRGBColorSpace];
    else if ([name isEqualToString:NSCalibratedRGBColorSpace])
        kind = KIND_CAL_RGB, target = [NSColorSpace genericRGBColorSpace];
    else if ([name isEqualToString:NSDeviceWhiteColorSpace])
        kind = KIND_DEVICE_WHITE, target = [NSColorSpace genericGamma22GrayColorSpace];
    else if ([name isEqualToString:NSCalibratedWhiteColorSpace])
        kind = KIND_CAL_WHITE, target = [NSColorSpace genericGrayColorSpace];
    else if ([name isEqualToString:NSDeviceCMYKColorSpace])
        kind = KIND_DEVICE_CMYK, target = [NSColorSpace deviceCMYKColorSpace];
    else
        return nil;
    if ([c colorSpaceName] == kind_name(kind))
        return c;
    return convert_to_space(c, target, kind);
}

/* MARK: Derived colours */

- (NSColor *)colorWithAlphaComponent:(CGFloat)alpha { return self; }

/* As Apple's: blending a colour with an equal one gives it back; anything else blends in calibrated RGB. */
- (NSColor *)blendedColorWithFraction:(CGFloat)fraction ofColor:(NSColor *)color
{
    if ([self isEqual:color])
        return self;
    fraction = clamp01(fraction);
    NSComponentColor *a = (NSComponentColor *)[self colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    NSComponentColor *b = (NSComponentColor *)[color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    if (![a isKindOfClass:[NSComponentColor class]] || ![b isKindOfClass:[NSComponentColor class]])
        return nil;
    CGFloat c[6];
    for (NSInteger i = 0; i < a->_n; i++)
        c[i] = a->_c[i] * (1 - fraction) + b->_c[i] * fraction;
    return make_color(KIND_CAL_RGB, nil, c, a->_n);
}

- (NSColor *)highlightWithLevel:(CGFloat)val
{
    return [self blendedColorWithFraction:val ofColor:[NSColor highlightColor]];
}

- (NSColor *)shadowWithLevel:(CGFloat)val
{
    return [self blendedColorWithFraction:val ofColor:[NSColor shadowColor]];
}

/* MARK: Drawing */

- (void)set
{
    CGContextRef c = FinchCurrentCGContext();
    CGColorRef cg = [self _finchCGColor];
    if (!c || !cg)
        return;
    CGContextSetFillColorWithColor(c, cg);
    CGContextSetStrokeColorWithColor(c, cg);
}

- (void)setFill
{
    CGContextRef c = FinchCurrentCGContext();
    CGColorRef cg = [self _finchCGColor];
    if (c && cg)
        CGContextSetFillColorWithColor(c, cg);
}

- (void)setStroke
{
    CGContextRef c = FinchCurrentCGContext();
    CGColorRef cg = [self _finchCGColor];
    if (c && cg)
        CGContextSetStrokeColorWithColor(c, cg);
}

- (void)drawSwatchInRect:(NSRect)rect
{
    CGContextRef c = FinchCurrentCGContext();
    CGColorRef cg = [self _finchCGColor];
    if (!c || !cg)
        return;
    CGContextSaveGState(c);
    CGContextSetFillColorWithColor(c, cg);
    CGContextFillRect(c, NSRectToCGRect(rect));
    CGContextRestoreGState(c);
}

/* MARK: NSObject, NSCopying, NSCoding */

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder
{
}

static BOOL
parse_floats(NSCoder *coder, NSString *key, CGFloat *out, int max, int *count)
{
    NSUInteger len = 0;
    const uint8_t *bytes = [coder decodeBytesForKey:key returnedLength:&len];
    if (!bytes)
        return NO;
    char buf[512];
    len = len < sizeof buf - 1 ? len : sizeof buf - 1;
    memcpy(buf, bytes, len);
    buf[len] = 0;
    int n = 0;
    char *p = buf, *end;
    while (n < max) {
        double v = strtod(p, &end);
        if (end == p)
            break;
        out[n++] = v;
        p = end;
    }
    *count = n;
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    [self release];
    if (![coder allowsKeyedCoding])
        return nil;
    int space = [coder decodeIntForKey:@"NSColorSpace"];
    CGFloat c[6] = {0, 0, 0, 0, 0, 0};
    int n = 0;
    NSColor *result = nil;
    NSColorSpace *custom = [coder decodeObjectOfClass:[NSColorSpace class] forKey:@"NSCustomColorSpace"];
    if (custom && parse_floats(coder, @"NSComponents", c, 6, &n) && n == custom.numberOfColorComponents + 1) {
        result = space_color(custom, c, n);
        ((NSComponentColor *)result)->_tagged = NO;
        return [result retain];
    }
    switch (space) {
    case 1:
    case 2:
        if (parse_floats(coder, @"NSRGB", c, 4, &n) && n >= 3) {
            if (n == 3)
                c[3] = 1;
            result = custom ? space_color(custom, c, 4) : make_color(space == 1 ? KIND_CAL_RGB : KIND_DEVICE_RGB, nil, c, 4);
        }
        break;
    case 3:
    case 4:
        if (parse_floats(coder, @"NSWhite", c, 2, &n) && n >= 1) {
            if (n == 1)
                c[1] = 1;
            result = custom ? space_color(custom, c, 2) : make_color(space == 3 ? KIND_CAL_WHITE : KIND_DEVICE_WHITE, nil, c, 2);
        }
        break;
    case 5:
        if (parse_floats(coder, @"NSCMYK", c, 5, &n) && n >= 4) {
            if (n == 4)
                c[4] = 1;
            result = make_color(KIND_DEVICE_CMYK, nil, c, 5);
        }
        break;
    case 6: {
        NSString *cat = [coder decodeObjectOfClass:[NSString class] forKey:@"NSCatalogName"];
        NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:@"NSColorName"];
        result = [NSColor colorWithCatalogName:cat colorName:name];
        if (!result)
            result = [coder decodeObjectOfClass:[NSColor class] forKey:@"NSColor"];
        break;
    }
    case 10: {
        NSImage *image = [coder decodeObjectOfClass:[NSImage class] forKey:@"NSImage"];
        result = image ? [NSColor colorWithPatternImage:image] : nil;
        break;
    }
    }
    if (result && [result isKindOfClass:[NSComponentColor class]])
        ((NSComponentColor *)result)->_tagged = NO;
    return [result retain];
}

@end

/* Gradients' interpolated colours: Apple's never come back tagged in RGB spaces. */
NSColor *
FinchGradientColor(NSColorSpace *space, const CGFloat *c, NSInteger n)
{
    NSComponentColor *col = (NSComponentColor *)space_color(space, c, n);
    if (space.colorSpaceModel == NSColorSpaceModelRGB)
        col->_tagged = NO;
    return col;
}
