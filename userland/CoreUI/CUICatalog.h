/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's CoreUI: the part of Apple's private CoreUI API that reads compiled
 * asset catalogs (.car files), with Apple's class and selector names, as
 * AppKit and apps that call CoreUI directly use it. Values follow Apple's:
 * display gamut 0 sRGB, 1 Display P3; idiom 0 universal; appearance names as
 * the catalog lists them ("NSAppearanceNameSystem", "NSAppearanceNameDarkAqua",
 * ...), a name the catalog doesn't list meaning the default appearance.
 */
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class CUINamedImage, CUINamedColor, CUINamedData, CUINamedVectorImage, CUINamedLookup;

@interface CUICatalog : NSObject
+ (nullable instancetype)defaultUICatalogForBundle:(nullable NSBundle *)bundle;
+ (BOOL)isValidAssetStorageWithURL:(NSURL *)url;
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (nullable instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle;
- (nullable instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error;
- (nullable instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length error:(NSError **)error;

- (NSArray<NSString *> *)allImageNames;
- (NSArray<NSString *> *)appearanceNames;
- (BOOL)containsLookupForName:(NSString *)name;
- (BOOL)imageExistsWithName:(NSString *)name;
- (BOOL)imageExistsWithName:(NSString *)name scaleFactor:(CGFloat)scale;
- (NSArray<CUINamedLookup *> *)imagesWithName:(NSString *)name;
- (void)enumerateNamedLookupsUsingBlock:(void (^)(CUINamedLookup *lookup))block;

- (nullable CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale;
- (nullable CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale appearanceName:(nullable NSString *)appearance;
- (nullable CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale deviceIdiom:(NSInteger)idiom;
- (nullable CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale deviceIdiom:(NSInteger)idiom
                           appearanceName:(nullable NSString *)appearance;
- (nullable CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut
                          layoutDirection:(NSInteger)direction;
- (nullable CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut
                          layoutDirection:(NSInteger)direction appearanceName:(nullable NSString *)appearance;
- (nullable CUINamedImage *)imageWithName:(NSString *)name scaleFactor:(CGFloat)scale displayGamut:(NSInteger)gamut
                          layoutDirection:(NSInteger)direction appearanceName:(nullable NSString *)appearance
                                   locale:(nullable NSLocale *)locale;

- (nullable CUINamedColor *)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut;
- (nullable CUINamedColor *)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut appearanceName:(nullable NSString *)appearance;
- (nullable CUINamedColor *)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut deviceIdiom:(NSInteger)idiom;
- (nullable CUINamedColor *)colorWithName:(NSString *)name displayGamut:(NSInteger)gamut deviceIdiom:(NSInteger)idiom
                           appearanceName:(nullable NSString *)appearance;

- (nullable CUINamedData *)dataWithName:(NSString *)name;
- (nullable CUINamedData *)dataWithName:(NSString *)name appearanceName:(nullable NSString *)appearance;

- (nullable CUINamedVectorImage *)namedVectorImageWithName:(NSString *)name scaleFactor:(CGFloat)scale
                                              displayGamut:(NSInteger)gamut layoutDirection:(NSInteger)direction
                                            appearanceName:(nullable NSString *)appearance;
- (nullable CGPDFDocumentRef)pdfDocumentWithName:(NSString *)name;
- (nullable CGPDFDocumentRef)pdfDocumentWithName:(NSString *)name appearanceName:(nullable NSString *)appearance;
@end

@interface CUINamedLookup : NSObject
@property (nonatomic, copy) NSString *name;
@property (readonly) NSString *renditionName;
@property (readonly) NSString *appearance;
@property (readonly) NSInteger appearanceIdentifier;
@property (readonly) CGFloat scale;
@property (readonly) NSInteger idiom;
@property (readonly) NSUInteger subtype;
@property (readonly) NSInteger displayGamut;
@property (readonly) NSInteger layoutDirection;
@property (readonly) NSInteger localization;
@property (readonly) NSInteger sizeClassHorizontal;
@property (readonly) NSInteger sizeClassVertical;
@property (readonly) NSInteger memoryClass;
@property (readonly) NSInteger graphicsClass;
@property (readonly) NSString *keySignature;
@end

@interface CUINamedImage : CUINamedLookup
@property (readonly, nullable) CGImageRef image;
@property (readonly) CGSize size;
@property (readonly) BOOL isTemplate;
@property (readonly) NSInteger templateRenderingMode;  /* 1 template, 2 automatic, 3 original */
@property (readonly) BOOL isVectorBased;
@property (readonly) BOOL preservedVectorRepresentation;
@property (readonly) NSInteger imageType;
@property (readonly) NSInteger resizingMode;
@property (readonly) double opacity;
@property (readonly) int blendMode;
@property (readonly) int exifOrientation;
@property (readonly) BOOL isFlippable;
@property (readonly) BOOL hasSliceInformation;
@property (readonly) BOOL hasAlignmentInformation;
@property (readonly) BOOL isAlphaCropped;
@property (readonly) BOOL isStructured;
- (nullable CGImageRef)createImageFromPDFRenditionWithScale:(CGFloat)scale CF_RETURNS_RETAINED;
@end

@interface CUINamedColor : CUINamedLookup
@property (readonly, nullable) CGColorRef cgColor;
@property (readonly, nullable) NSString *systemColorName;
@property (readonly) BOOL substituteWithSystemColor;
@end

@interface CUINamedData : CUINamedLookup
@property (readonly, copy, nullable) NSData *data;
@property (readonly, copy, nullable) NSString *utiType;
@end

@interface CUINamedVectorImage : CUINamedLookup
@property (readonly, nullable) CGPDFDocumentRef pdfDocument;
- (nullable CGImageRef)rasterizeImageUsingScaleFactor:(CGFloat)scale forTargetSize:(CGSize)size CF_RETURNS_NOT_RETAINED;
@end

/* What namedVectorImageWithName: gives for a PDF, as Apple's. */
@interface CUINamedVectorPDFImage : CUINamedVectorImage
@end

NS_ASSUME_NONNULL_END
