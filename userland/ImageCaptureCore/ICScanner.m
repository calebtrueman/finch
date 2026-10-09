/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * A scanner's parts: functional units (flatbed, transparency adapters,
 * document feeder), their features, band data, and ICScannerImageRep (the
 * private class Apple's draws overview scans into). Properties are the
 * headers' own, synthesized; nothing creates these until Finch has scanner
 * support.
 */
#import <ImageCaptureCore/ImageCaptureCore.h>

#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@implementation ICScannerFeature
@end
@implementation ICScannerFeatureEnumeration
@end
@implementation ICScannerFeatureRange
@end
@implementation ICScannerFeatureBoolean
@end
@implementation ICScannerFeatureTemplate
@end
@implementation ICScannerFunctionalUnit
@end
@implementation ICScannerFunctionalUnitFlatbed
@end
@implementation ICScannerFunctionalUnitPositiveTransparency
@end
@implementation ICScannerFunctionalUnitNegativeTransparency
@end
@implementation ICScannerFunctionalUnitDocumentFeeder
@end
@implementation ICScannerBandData
@end

@interface ICScannerImageRep : NSObject
@end
@implementation ICScannerImageRep
@end
