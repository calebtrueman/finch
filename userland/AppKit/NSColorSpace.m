/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSColorSpace: a CGColorSpace, with AppKit's names for it. The named spaces
 * are singletons, and -initWithCGColorSpace: and -initWithICCProfileData:
 * return them for their CG spaces, as Apple's do.
 *
 * Archives use Apple's keys: NSID for the spaces older systems knew (1-9),
 * NSSpaceID for newer named ones, NSICC for the profile, NSModel for a
 * non-RGB model.
 */
#import "AppKitDrawing.h"

NSColorSpaceName NSCalibratedWhiteColorSpace = @"NSCalibratedWhiteColorSpace";
NSColorSpaceName NSCalibratedBlackColorSpace = @"NSCalibratedBlackColorSpace";
NSColorSpaceName NSCalibratedRGBColorSpace = @"NSCalibratedRGBColorSpace";
NSColorSpaceName NSDeviceWhiteColorSpace = @"NSDeviceWhiteColorSpace";
NSColorSpaceName NSDeviceBlackColorSpace = @"NSDeviceBlackColorSpace";
NSColorSpaceName NSDeviceRGBColorSpace = @"NSDeviceRGBColorSpace";
NSColorSpaceName NSDeviceCMYKColorSpace = @"NSDeviceCMYKColorSpace";
NSColorSpaceName NSNamedColorSpace = @"NSNamedColorSpace";
NSColorSpaceName NSPatternColorSpace = @"NSPatternColorSpace";
NSColorSpaceName NSCustomColorSpace = @"NSCustomColorSpace";

/* What Apple's AppKit calls the CG spaces, and how it archives them. */
typedef struct {
    const CFStringRef *cgName;
    const char *name;
    BOOL extended;
    int archiveID;  /* NSID */
    int spaceID;    /* NSSpaceID */
} SpaceInfo;

static const SpaceInfo spaces[] = {
    {&kCGColorSpaceGenericRGB, "Generic RGB", NO, 1, 0},
    {&kCGColorSpaceGenericGray, "Generic Gray", NO, 2, 0},
    {&kCGColorSpaceGenericCMYK, "Generic CMYK", NO, 3, 0},
    {NULL, "Device RGB", NO, 4, 0},
    {NULL, "Device Gray", NO, 5, 0},
    {NULL, "Device CMYK", NO, 6, 0},
    {&kCGColorSpaceSRGB, "sRGB IEC61966-2.1", NO, 7, 0},
    {&kCGColorSpaceAdobeRGB1998, "Adobe RGB (1998)", NO, 8, 0},
    {&kCGColorSpaceGenericGrayGamma2_2, "Generic Gray Gamma 2.2 Profile", NO, 9, 0},
    {&kCGColorSpaceDisplayP3, "Display P3", NO, 0, 12},
    {&kCGColorSpaceDCIP3, "SMPTE RP 431-2-2007 DCI (P3)", NO, 0, 13},
    {&kCGColorSpaceExtendedSRGB, "sRGB IEC61966-2.1", YES, 0, 14},
    {&kCGColorSpaceExtendedGray, "Generic Gray Gamma 2.2 Profile", YES, 0, 15},
    {&kCGColorSpaceLinearSRGB, "sRGB IEC61966-2.1 Linear", NO, 0, 16},
    {&kCGColorSpaceExtendedLinearSRGB, "sRGB IEC61966-2.1 Linear", YES, 0, 17},
    {&kCGColorSpaceITUR_709, "Rec. ITU-R BT.709-5", NO, 0, 0},
    {&kCGColorSpaceITUR_2020, "Rec. ITU-R BT.2020-1", NO, 0, 0},
    {&kCGColorSpaceROMMRGB, "ROMM RGB: ISO 22028-2:2013", NO, 0, 0},
    {&kCGColorSpaceGenericLab, "Generic Lab Profile", NO, 0, 0},
    {&kCGColorSpaceLinearGray, "Linear Gray", NO, 0, 0},
    {&kCGColorSpaceGenericRGBLinear, "Generic RGB Linear Profile", NO, 0, 0},
    {&kCGColorSpaceExtendedDisplayP3, "Display P3", YES, 0, 0},
    {&kCGColorSpaceACESCGLinear, "ACES CG Linear (Academy Color Encoding System AP1)", NO, 0, 0},
    {&kCGColorSpaceLinearDisplayP3, "Display P3 Linear", NO, 0, 0},
};
#define NSPACES (sizeof spaces / sizeof spaces[0])
#define NSINGLETONS 15  /* the spaces with an NSID or NSSpaceID are shared instances */

static NSColorSpace *singletons[NSPACES];

@implementation NSColorSpace {
    CGColorSpaceRef _cg;
    int _info;  /* index into spaces, or -1 */
    NSData *_icc;
    NSString *_name;
}

static CGColorSpaceRef
create_cg(int i)
{
    switch (i) {
    case 3: return CGColorSpaceCreateDeviceRGB();
    case 4: return CGColorSpaceCreateDeviceGray();
    case 5: return CGColorSpaceCreateDeviceCMYK();
    default: return CGColorSpaceCreateWithName(*spaces[i].cgName);
    }
}

/* Which table entry a CG space is, by its name (the device spaces have theirs). */
static BOOL
same_space(CGColorSpaceRef a, CGColorSpaceRef (*make)(void))
{
    CGColorSpaceRef b = make();
    BOOL same = CFEqual(a, b);
    CGColorSpaceRelease(b);
    return same;
}

/* Which table entry a CG space is: the device spaces by equality, others by name. */
static int
info_for_cg(CGColorSpaceRef cg)
{
    if (same_space(cg, CGColorSpaceCreateDeviceRGB))
        return 3;
    if (same_space(cg, CGColorSpaceCreateDeviceGray))
        return 4;
    if (same_space(cg, CGColorSpaceCreateDeviceCMYK))
        return 5;
    CFStringRef name = CGColorSpaceGetName(cg);
    if (!name)
        return -1;
    for (unsigned i = 0; i < NSPACES; i++)
        if (spaces[i].cgName && CFEqual(name, *spaces[i].cgName))
            return (int)i;
    return -1;
}

- (instancetype)_initWithCG:(CGColorSpaceRef)cg info:(int)info
{
    if ((self = [super init])) {
        _cg = CGColorSpaceRetain(cg);
        _info = info;
    }
    return self;
}

static NSColorSpace *
singleton(int i)
{
    static dispatch_once_t once[NSINGLETONS];
    dispatch_once(&once[i], ^{
        CGColorSpaceRef cg = create_cg(i);
        singletons[i] = [[NSColorSpace alloc] _initWithCG:cg info:i];
        CGColorSpaceRelease(cg);
    });
    return singletons[i];
}

+ (NSColorSpace *)genericRGBColorSpace { return singleton(0); }
+ (NSColorSpace *)genericGrayColorSpace { return singleton(1); }
+ (NSColorSpace *)genericCMYKColorSpace { return singleton(2); }
+ (NSColorSpace *)deviceRGBColorSpace { return singleton(3); }
+ (NSColorSpace *)deviceGrayColorSpace { return singleton(4); }
+ (NSColorSpace *)deviceCMYKColorSpace { return singleton(5); }
+ (NSColorSpace *)sRGBColorSpace { return singleton(6); }
+ (NSColorSpace *)adobeRGB1998ColorSpace { return singleton(7); }
+ (NSColorSpace *)genericGamma22GrayColorSpace { return singleton(8); }
+ (NSColorSpace *)displayP3ColorSpace { return singleton(9); }
+ (NSColorSpace *)extendedSRGBColorSpace { return singleton(11); }
+ (NSColorSpace *)extendedGenericGamma22GrayColorSpace { return singleton(12); }

+ (NSArray<NSColorSpace *> *)availableColorSpacesWithModel:(NSColorSpaceModel)model
{
    NSMutableArray *a = [NSMutableArray array];
    static const int order[] = {4, 1, 8, 3, 0, 6, 7, 9, 5, 2};
    for (unsigned k = 0; k < sizeof order / sizeof order[0]; k++) {
        NSColorSpace *s = singleton(order[k]);
        if (model == NSColorSpaceModelUnknown || s.colorSpaceModel == model)
            [a addObject:s];
    }
    return a;
}

- (instancetype)init
{
    return [self _initWithCG:NULL info:-1];
}

- (instancetype)initWithCGColorSpace:(CGColorSpaceRef)cgColorSpace
{
    if (!cgColorSpace || CGColorSpaceGetModel(cgColorSpace) == kCGColorSpaceModelUnknown) {
        [self release];
        return nil;
    }
    int i = info_for_cg(cgColorSpace);
    if (i >= 0 && i < NSINGLETONS) {
        [self release];
        return [singleton(i) retain];
    }
    return [self _initWithCG:cgColorSpace info:i];
}

- (instancetype)initWithICCProfileData:(NSData *)iccData
{
    for (int i = 0; i < NSINGLETONS; i++) {
        NSData *d = [singleton(i) ICCProfileData];
        if (d && [d isEqualToData:iccData] && !spaces[i].extended) {
            [self release];
            return [singleton(i) retain];
        }
    }
    CGColorSpaceRef cg = CGColorSpaceCreateWithICCData((CFDataRef)iccData);
    if (!cg) {
        /* Apple's keeps the data and reports an unknown model */
        self = [self _initWithCG:NULL info:-1];
        _icc = [iccData copy];
        return self;
    }
    self = [self initWithCGColorSpace:cg];
    CGColorSpaceRelease(cg);
    if (self && !_icc && _info < 0)
        _icc = [iccData copy];
    return self;
}

- (instancetype)initWithColorSyncProfile:(void *)prof
{
    [self release];
    return nil;
}

- (void)dealloc
{
    CGColorSpaceRelease(_cg);
    [_icc release];
    [_name release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }

- (CGColorSpaceRef)CGColorSpace { return _cg; }
- (void *)colorSyncProfile { return NULL; }

- (NSData *)ICCProfileData
{
    if (_icc)
        return _icc;
    if (!_cg || (_info >= 3 && _info <= 5))
        return nil;
    CFDataRef d = CGColorSpaceCopyICCData(_cg);
    _icc = (NSData *)d;
    return _icc;
}

- (NSColorSpaceModel)colorSpaceModel
{
    if (!_cg)
        return NSColorSpaceModelUnknown;
    switch (CGColorSpaceGetModel(_cg)) {
    case kCGColorSpaceModelMonochrome: return NSColorSpaceModelGray;
    case kCGColorSpaceModelRGB: return NSColorSpaceModelRGB;
    case kCGColorSpaceModelCMYK: return NSColorSpaceModelCMYK;
    case kCGColorSpaceModelLab: return NSColorSpaceModelLAB;
    case kCGColorSpaceModelDeviceN: return NSColorSpaceModelDeviceN;
    case kCGColorSpaceModelIndexed: return NSColorSpaceModelIndexed;
    case kCGColorSpaceModelPattern: return NSColorSpaceModelPatterned;
    default: return NSColorSpaceModelUnknown;
    }
}

- (NSInteger)numberOfColorComponents
{
    return _cg ? (NSInteger)CGColorSpaceGetNumberOfComponents(_cg) : 0;
}

- (NSString *)localizedName
{
    if (_info >= 0)
        return @(spaces[_info].name);
    if (!_name && _cg) {
        CFStringRef n = CGColorSpaceCopyName(_cg);
        _name = n ? [(NSString *)n copy] : nil;
        if (n)
            CFRelease(n);
    }
    return _name;
}

- (BOOL)_isExtended
{
    return _info >= 0 ? spaces[_info].extended : (_cg && CGColorSpaceUsesExtendedRange(_cg));
}

- (NSString *)description
{
    NSString *name = [self localizedName];
    if (!name)
        return [NSString stringWithFormat:@"Colorspace %p", self];
    return [NSString stringWithFormat:@"%@%@ colorspace", name, [self _isExtended] ? @" (extended)" : @""];
}

- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSColorSpace class]])
        return NO;
    NSColorSpace *o = other;
    if (_info >= 0 || o->_info >= 0)
        return _info == o->_info;
    if (_cg && o->_cg && CFEqual(_cg, o->_cg))
        return YES;
    NSData *a = [self ICCProfileData], *b = [o ICCProfileData];
    return a && b && [a isEqualToData:b];
}

- (NSUInteger)hash
{
    return _info >= 0 ? (NSUInteger)_info + 1 : [[self ICCProfileData] hash];
}

- (NSInteger)_finchArchiveID
{
    return _info >= 0 ? spaces[_info].archiveID : 0;
}

/* MARK: NSCoding */

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    int nsid = _info >= 0 ? spaces[_info].archiveID : 0, spaceID = _info >= 0 ? spaces[_info].spaceID : 0;
    if (nsid)
        [coder encodeInt:nsid forKey:@"NSID"];
    if (spaceID)
        [coder encodeInt:spaceID forKey:@"NSSpaceID"];
    if (nsid < 1 || nsid > 6) {
        NSData *icc = [self ICCProfileData];
        if (icc)
            [coder encodeObject:icc forKey:@"NSICC"];
        NSColorSpaceModel m = [self colorSpaceModel];
        if (m != NSColorSpaceModelRGB)
            [coder encodeInt:(int)m forKey:@"NSModel"];
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    int nsid = [coder decodeIntForKey:@"NSID"], spaceID = [coder decodeIntForKey:@"NSSpaceID"];
    for (int i = 0; i < NSINGLETONS; i++)
        if ((nsid && spaces[i].archiveID == nsid) || (spaceID && spaces[i].spaceID == spaceID)) {
            [self release];
            return [singleton(i) retain];
        }
    NSData *icc = [coder decodeObjectOfClass:[NSData class] forKey:@"NSICC"];
    if (icc)
        return [self initWithICCProfileData:icc];
    [self release];
    return nil;
}

@end
