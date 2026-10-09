/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSScreen: the window server's display. Finch's server has one display;
 * its menu bar is AppKit's, 24 points at the top, which visibleFrame leaves
 * out.
 */
#import "NSView_Finch.h"

NSNotificationName const NSScreenColorSpaceDidChangeNotification = @"NSScreenColorSpaceDidChangeNotification";

static const CGFloat menu_bar_height = 24;

/* Without a window server (tests on the host), views align as on a 2x display. */
CGFloat
FinchDefaultBackingScale(void)
{
    NSScreen *s = [NSScreen mainScreen];
    return s ? [s backingScaleFactor] : 2;
}

@implementation NSScreen {
    FWSDisplayInfo _info;
}

static NSScreen *main_screen;

+ (NSArray<NSScreen *> *)screens
{
    NSScreen *s = [self mainScreen];
    return s ? @[ s ] : @[];
}

+ (NSScreen *)mainScreen
{
    FWSDisplayInfo info;
    if (!FWSGetDisplayInfo(&info))
        return nil;
    if (!main_screen || main_screen->_info.width != info.width || main_screen->_info.height != info.height ||
        main_screen->_info.scale != info.scale) {
        [main_screen release];
        main_screen = [[NSScreen alloc] init];
        main_screen->_info = info;
    }
    return main_screen;
}

+ (NSScreen *)deepestScreen
{
    return [self mainScreen];
}

+ (BOOL)screensHaveSeparateSpaces
{
    return NO;
}

- (NSWindowDepth)depth { return NSWindowDepthTwentyfourBitRGB; }
- (NSRect)frame { return NSMakeRect(0, 0, _info.width, _info.height); }

- (NSRect)visibleFrame
{
    return NSMakeRect(0, 0, _info.width, _info.height - menu_bar_height);
}

- (NSDictionary<NSDeviceDescriptionKey, id> *)deviceDescription
{
    CGFloat dpi = 72 * _info.scale;
    return @{
        NSDeviceBitsPerSample : @8,
        NSDeviceColorSpaceName : NSCalibratedRGBColorSpace,
        NSDeviceIsScreen : @"YES",
        NSDeviceResolution : [NSValue valueWithSize:NSMakeSize(dpi, dpi)],
        NSDeviceSize : [NSValue valueWithSize:NSMakeSize(_info.width, _info.height)],
        @"NSScreenNumber" : @(_info.display),
    };
}

- (NSColorSpace *)colorSpace
{
    id cls = FINCH_CLASS(NSColorSpace);
    return [cls respondsToSelector:@selector(sRGBColorSpace)] ? [cls sRGBColorSpace] : nil;
}

- (const NSWindowDepth *)supportedWindowDepths
{
    static const NSWindowDepth depths[] = {NSWindowDepthTwentyfourBitRGB, 0};
    return depths;
}

- (BOOL)canRepresentDisplayGamut:(NSDisplayGamut)gamut { return gamut == NSDisplayGamutSRGB; }
- (CGFloat)backingScaleFactor { return _info.scale; }
- (CGFloat)userSpaceScaleFactor { return 1; }
- (NSString *)localizedName { return @"Finch Display"; }
- (NSEdgeInsets)safeAreaInsets { return NSEdgeInsetsMake(0, 0, 0, 0); }
- (NSRect)auxiliaryTopLeftArea { return NSZeroRect; }
- (NSRect)auxiliaryTopRightArea { return NSZeroRect; }
- (CGDirectDisplayID)CGDirectDisplayID { return _info.display; }
- (NSInteger)maximumFramesPerSecond { return (NSInteger)(_info.refresh ?: 60); }
- (NSTimeInterval)minimumRefreshInterval { return 1 / (_info.refresh ?: 60); }
- (NSTimeInterval)maximumRefreshInterval { return 1 / (_info.refresh ?: 60); }
- (NSTimeInterval)displayUpdateGranularity { return 0; }
- (NSTimeInterval)lastDisplayUpdateTimestamp { return 0; }
- (CGFloat)maximumExtendedDynamicRangeColorComponentValue { return 1; }
- (CGFloat)maximumPotentialExtendedDynamicRangeColorComponentValue { return 1; }
- (CGFloat)maximumReferenceExtendedDynamicRangeColorComponentValue { return 0; }

- (NSRect)convertRectToBacking:(NSRect)r
{
    CGFloat s = _info.scale;
    return NSMakeRect(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s);
}

- (NSRect)convertRectFromBacking:(NSRect)r
{
    CGFloat s = _info.scale;
    return NSMakeRect(r.origin.x / s, r.origin.y / s, r.size.width / s, r.size.height / s);
}

- (NSRect)backingAlignedRect:(NSRect)rect options:(NSAlignmentOptions)options
{
    return [self convertRectFromBacking:NSIntegralRectWithOptions([self convertRectToBacking:rect], options)];
}

@end
